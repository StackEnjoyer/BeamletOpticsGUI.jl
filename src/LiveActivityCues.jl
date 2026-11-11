#=
The cues of the activity of the others in the 3D view, see `LiveActivity.jl` and
`plans/activity-cues.md` (W2).
=#

"""Draws the `cues` (episode, age) of the `gui` at the time `now`, see `_activity_step!`."""
_draw_cues!(gui::LiveView, cues, now::Real) = nothing

"""Draws ghost frames of the objects at the `poses` (see `_poses_at`); `nothing` clears them."""
_draw_scrub!(gui::LiveView, poses) = nothing

"""Deletes the plots of the cues of the `gui`."""
_clear_cues!(gui::LiveView) = nothing

"""The colour of the presence (box and name) of the participant `who` in the `gui`."""
_presence_color(gui::LiveView, who::AbstractString) = _activity_color(gui, who)
