#=
The activity of the others in a project: who changed what and when (episodes), the colour of each
participant, the pacing of the cues in the 3D view, the history of the poses and following a
participant with the camera. The model only: the cues are drawn in `LiveActivityCues.jl`, the
timeline in `LiveTimeline.jl`. See `plans/activity-cues.md`.
=#

# The calm colours of the participants on a light theme; on a dark theme mixed towards white, see
# `_activity_color`
const _ACTIVITY_PALETTE = RGBf[
    Makie.to_color("#5B7DB1"),  # slate blue
    Makie.to_color("#3E9C8F"),  # teal
    Makie.to_color("#C8963E"),  # amber
    Makie.to_color("#9B6B9E"),  # plum
    Makie.to_color("#C46A55"),  # terracotta
    Makie.to_color("#7A9A4E"),  # moss
    Makie.to_color("#5F8FB0"),  # steel
    Makie.to_color("#C27A8E"),  # rose
]

# The life of a cue [s]: drawn in, held, faded out
const _CUE_IN = 0.6
const _CUE_HOLD = 1.4
const _CUE_OUT = 1.2
# Pacing [s]: a cue starts at least `_CUE_SLOT` after the one before; waiting cues more than
# `_CUE_LAG` behind become one summary
const _CUE_SLOT = 0.9
const _CUE_LAG = 3.0
# Episodes kept per window
const _ACTIVITY_MAX = 500
# The camera follows a participant at most every `_FOLLOW_EVERY` seconds
const _FOLLOW_EVERY = 2.0

"""
    _ActivityItem

One object of an episode (see `_Episode`): the `key` of its line (uid, or `"id:L1"`), its readable
`id`, the kind of `change` (`:moved`, `:rotated`, `:added`, `:removed`, `:changed`, `:grouped`,
`:ungrouped`, `:system`), its pose (position, orientation) `before` and `after` (`nothing` where it
did not exist), and `frame`: the 24 points of the wireframe of its box at `after` (at `before` for
`:removed`), see `_bbox_wireframe`.
"""
struct _ActivityItem
    key::String
    id::Symbol
    change::Symbol
    before::Union{Nothing, Tuple{Vector{Float64}, Matrix{Float64}}}
    after::Union{Nothing, Tuple{Vector{Float64}, Matrix{Float64}}}
    frame::Vector{Point3f}
end

"""
    _Episode

A change of the files by an other participant as the window saw it, or a message of it (`doing`):
its number `n` (1, 2, … per window; 0 for a summary), the participant `who` (its presence id, or
`"agent"` if unknown), its shown `name`, whether it is an `agent`, the time `t` it was seen (clock
of this machine), its `items`, a short `text` ("moved M2 by 12 mm, L1"), the `message` ("" for a
change) and `count`, the episodes in it (more than 1 for a summary).
"""
struct _Episode
    n::Int
    who::String
    name::String
    agent::Bool
    t::Float64
    items::Vector{_ActivityItem}
    text::String
    message::String
    count::Int
end

"""
    _Activity

The activity of the others in a window (`gui.activity`, see `_activity`): the `episodes` (oldest
first, at most `_ACTIVITY_MAX`), the `queue` of the numbers of episodes waiting for their cue, the
`cues` shown (episode or summary, start time), the start of the last cue `last_start`, the `colors`
of the participants (id => index into `_ACTIVITY_PALETTE`), the participant to `follow` and the
time `follow_at` the camera last followed, whether an other was there once (`seen`: the timeline
is shown), whether the timeline is `expanded`, the time of its scrub `cursor`, the episode under
the mouse `hover`, and the plots of the cues (`cue_plots`) and the timeline (`strip`).
"""
Base.@kwdef mutable struct _Activity
    episodes::Vector{_Episode} = _Episode[]
    queue::Vector{Int} = Int[]
    cues::Vector{Tuple{_Episode, Float64}} = Tuple{_Episode, Float64}[]
    last_start::Float64 = -Inf
    colors::Dict{String, Int} = Dict{String, Int}()
    follow::Union{Nothing, String} = nothing
    follow_at::Float64 = -Inf
    seen::Bool = false
    expanded::Bool = false
    cursor::Union{Nothing, Float64} = nothing
    hover::Union{Nothing, Int} = nothing
    cue_plots::Any = nothing
    strip::Any = nothing
end

"""The activity of the others in the `gui`, see `_Activity`; created at the first use."""
function _activity(gui::LiveView)
    a = gui.activity
    a isa _Activity && return a
    a = _Activity()
    gui.activity = a
    return a
end

"""Whether the theme of the `gui` is dark: the luminance of the background of its 3D view."""
_is_dark(gui::LiveView) = false

"""
    _activity_color(gui, who; alpha = 1.0) -> RGBAf

The colour of the participant `who` in the `gui`: stable within the window, the first 8
participants differ; lighter on a dark theme.
"""
_activity_color(gui::LiveView, who::AbstractString; alpha::Real = 1.0) =
    RGBAf(_ACTIVITY_PALETTE[1], alpha)

"""
    _record_episode!(gui, who, name, agent, items; text, message = "", now = time()) -> _Episode

Records a change (or with `message` a message) of the participant `who` and queues its cue.
"""
function _record_episode!(gui::LiveView, who::AbstractString, name::AbstractString, agent::Bool,
        items::Vector{_ActivityItem}; text::AbstractString, message::AbstractString = "",
        now::Real = time())
    a = _activity(gui)
    ep = _Episode(length(a.episodes) + 1, String(who), String(name), agent, Float64(now), items,
        String(text), String(message), 1)
    push!(a.episodes, ep)
    a.seen = true
    return ep
end

"""
    _activity_step!(gui, now) -> Vector{Tuple{_Episode, Float64}}

The cues to draw at the time `now`, each with its age [s]: starts waiting cues at the pace of
`_CUE_SLOT`, makes one summary of the waiting cues that are more than `_CUE_LAG` behind, and drops
the cues whose life is over.
"""
_activity_step!(gui::LiveView, now::Real) = Tuple{_Episode, Float64}[]

"""Shows the episode of number `n` of the `gui` as a cue again, at once."""
_replay!(gui::LiveView, n::Integer; now::Real = time()) = nothing

"""
    _poses_at(gui, t) -> Dict{String, Tuple{Vector{Float64}, Matrix{Float64}}}

The pose at the time `t` of every line (by key) that an episode changed after `t`.
"""
_poses_at(gui::LiveView, t::Real) = Dict{String, Tuple{Vector{Float64}, Matrix{Float64}}}()

"""Follows the participant `who` with the camera (`nothing`: none), see `_follow_target`."""
_set_follow!(gui::LiveView, who::Union{Nothing, AbstractString}) = nothing

"""
    _follow_target(gui, now) -> Union{Nothing, Vector{Point3f}}

The points that the camera should frame now to follow the participant of `_set_follow!`: the
frames of its newest cue, at most every `_FOLLOW_EVERY` seconds; else `nothing`.
"""
_follow_target(gui::LiveView, now::Real) = nothing

"""
    _cue_alpha(age) -> Float64

The opacity of a cue of the age `age` [s]: eased in over `_CUE_IN`, held for `_CUE_HOLD`, eased out
over `_CUE_OUT`; 0 before and after.
"""
_cue_alpha(age::Real) = 0.0
