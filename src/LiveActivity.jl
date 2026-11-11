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

# The relative luminance of the colour `c` (WCAG, linear sRGB), 0 (black) … 1 (white)
function _rel_luminance(c)
    lin(x) = x <= 0.04045 ? x / 12.92 : ((x + 0.055) / 1.055)^2.4
    rgb = RGBf(c)
    return 0.2126 * lin(Float64(rgb.r)) + 0.7152 * lin(Float64(rgb.g)) +
           0.0722 * lin(Float64(rgb.b))
end

"""Whether the theme of the `gui` is dark: the luminance of the background of its 3D view."""
_is_dark(gui::LiveView) = _rel_luminance(gui.layout.theme.view) < 0.4

# The index into `_ACTIVITY_PALETTE` of the participant `who`, assigned at its first use: the
# smallest index not used yet (cyclic once all are used)
function _color_index!(a::_Activity, who::AbstractString)
    i = get(a.colors, who, 0)
    i > 0 && return i
    n = length(_ACTIVITY_PALETTE)
    used = Set(values(a.colors))
    free = findfirst(j -> !(j in used), 1:n)
    i = free === nothing ? mod(length(a.colors), n) + 1 : free
    a.colors[String(who)] = i
    return i
end

"""
    _activity_color(gui, who; alpha = 1.0) -> RGBAf

The colour of the participant `who` in the `gui`: stable within the window, the first 8
participants differ; lighter on a dark theme.
"""
function _activity_color(gui::LiveView, who::AbstractString; alpha::Real = 1.0)
    c = _ACTIVITY_PALETTE[_color_index!(_activity(gui), who)]
    if _is_dark(gui)
        # mixed 30 % towards white
        c = RGBf(c.r + 0.3f0 * (1 - c.r), c.g + 0.3f0 * (1 - c.g), c.b + 0.3f0 * (1 - c.b))
    end
    return RGBAf(c, alpha)
end

# The index in `a.episodes` of the episode of number `n`, `nothing` if it is not kept (any more)
function _episode_index(a::_Activity, n::Integer)
    isempty(a.episodes) && return nothing
    i = n - a.episodes[1].n + 1
    return 1 <= i <= length(a.episodes) && a.episodes[i].n == n ? i : nothing
end

"""
    _record_episode!(gui, who, name, agent, items; text, message = "", now = time()) -> _Episode

Records a change (or with `message` a message) of the participant `who` and queues its cue.
"""
function _record_episode!(gui::LiveView, who::AbstractString, name::AbstractString, agent::Bool,
        items::Vector{_ActivityItem}; text::AbstractString, message::AbstractString = "",
        now::Real = time())
    a = _activity(gui)
    n = isempty(a.episodes) ? 1 : a.episodes[end].n + 1
    ep = _Episode(n, String(who), String(name), agent, Float64(now), items,
        String(text), String(message), 1)
    _color_index!(a, who)
    push!(a.episodes, ep)
    push!(a.queue, n)
    # the latest `_ACTIVITY_MAX` are kept; the waiting cues of the others go with them
    if length(a.episodes) > _ACTIVITY_MAX
        k = length(a.episodes) - _ACTIVITY_MAX
        first_kept = a.episodes[k + 1].n
        deleteat!(a.episodes, 1:k)
        filter!(>=(first_kept), a.queue)
    end
    a.seen = true
    return ep
end

# One summary of the waiting episodes `eps` (oldest first), see `_activity_step!`: the latest item
# per key (in the order of their first change), with its pose `before` from the first and `after`
# from the last episode that changed it
function _summary(eps::Vector{_Episode})
    keys = String[]
    items = Dict{String, _ActivityItem}()
    for ep in eps, it in ep.items
        prev = get(items, it.key, nothing)
        if prev === nothing
            push!(keys, it.key)
            items[it.key] = it
        else
            items[it.key] = _ActivityItem(it.key, it.id, it.change, prev.before, it.after, it.frame)
        end
    end
    count = sum(ep -> ep.count, eps; init = 0)
    who = eps[1].who
    one = all(ep -> ep.who == who, eps)
    return _Episode(0, one ? who : "several", one ? eps[end].name : "several",
        all(ep -> ep.agent, eps), eps[end].t, _ActivityItem[items[k] for k in keys],
        "$(count) changes ($(length(keys)) objects)", "", count)
end

"""
    _activity_step!(gui, now) -> Vector{Tuple{_Episode, Float64}}

The cues to draw at the time `now`, each with its age [s]: starts waiting cues at the pace of
`_CUE_SLOT`, makes one summary of the waiting cues that are more than `_CUE_LAG` behind, and drops
the cues whose life is over.
"""
function _activity_step!(gui::LiveView, now::Real)
    a = _activity(gui)
    now = Float64(now)
    life = _CUE_IN + _CUE_HOLD + _CUE_OUT
    filter!(c -> now - c[2] < life, a.cues)
    if !isempty(a.queue)
        oldest = a.episodes[_episode_index(a, a.queue[1])]
        if now - oldest.t > _CUE_LAG
            # all waiting cues at once; a single one stays itself
            eps = _Episode[a.episodes[_episode_index(a, n)] for n in a.queue]
            empty!(a.queue)
            push!(a.cues, (length(eps) == 1 ? eps[1] : _summary(eps), now))
            a.last_start = now
        elseif now - a.last_start >= _CUE_SLOT
            n = popfirst!(a.queue)
            push!(a.cues, (a.episodes[_episode_index(a, n)], now))
            a.last_start = now
        end
    end
    return Tuple{_Episode, Float64}[(ep, now - t0) for (ep, t0) in a.cues]
end

"""Shows the episode of number `n` of the `gui` as a cue again, at once."""
function _replay!(gui::LiveView, n::Integer; now::Real = time())
    a = _activity(gui)
    i = _episode_index(a, n)
    i === nothing && return nothing
    now = Float64(now)
    # a cue of it that is still shown starts again instead of being shown twice
    filter!(c -> c[1].n != n, a.cues)
    push!(a.cues, (a.episodes[i], now))
    # the waiting cues keep their pace after it
    a.last_start = max(a.last_start, now)
    return nothing
end

"""
    _poses_at(gui, t) -> Dict{String, Tuple{Vector{Float64}, Matrix{Float64}}}

The pose at the time `t` of every line (by key) that an episode changed after `t`.
"""
function _poses_at(gui::LiveView, t::Real)
    poses = Dict{String, Tuple{Vector{Float64}, Matrix{Float64}}}()
    done = Set{String}()
    for ep in _activity(gui).episodes
        ep.t > t || continue
        for it in ep.items
            it.key in done && continue
            push!(done, it.key)
            # a line added after `t` had no pose at `t`
            it.before === nothing || (poses[it.key] = it.before)
        end
    end
    return poses
end

"""Follows the participant `who` with the camera (`nothing`: none), see `_follow_target`."""
function _set_follow!(gui::LiveView, who::Union{Nothing, AbstractString})
    a = _activity(gui)
    a.follow = who === nothing ? nothing : String(who)
    a.follow_at = -Inf
    return nothing
end

"""
    _follow_target(gui, now) -> Union{Nothing, Vector{Point3f}}

The points that the camera should frame now to follow the participant of `_set_follow!`: the
frames of its newest cue, at most every `_FOLLOW_EVERY` seconds; else `nothing`.
"""
function _follow_target(gui::LiveView, now::Real)
    a = _activity(gui)
    who = a.follow
    who === nothing && return nothing
    now - a.follow_at >= _FOLLOW_EVERY || return nothing
    # the cues are in the order of their start
    for k in length(a.cues):-1:1
        ep, t0 = a.cues[k]
        t0 > a.follow_at || break
        ep.who == who || continue
        pts = Point3f[p for it in ep.items for p in it.frame]
        isempty(pts) && continue
        a.follow_at = Float64(now)
        return pts
    end
    return nothing
end

# Eased in and out (smoothstep) on 0 … 1
_ease(x::Float64) = (x = clamp(x, 0.0, 1.0); x * x * (3 - 2x))

"""
    _cue_alpha(age) -> Float64

The opacity of a cue of the age `age` [s]: eased in over `_CUE_IN`, held for `_CUE_HOLD`, eased out
over `_CUE_OUT`; 0 before and after.
"""
function _cue_alpha(age::Real)
    age = Float64(age)
    age <= 0 && return 0.0
    age < _CUE_IN && return _ease(age / _CUE_IN)
    age <= _CUE_IN + _CUE_HOLD && return 1.0
    return 1.0 - _ease((age - _CUE_IN - _CUE_HOLD) / _CUE_OUT)
end
