#=
The timeline of the activity of the others at the bottom of the 3D view, see `LiveActivity.jl` and
`plans/activity-cues.md` (W3).
=#

"""Builds the timeline strip of the `gui`, hidden until an other participant was there."""
_timeline!(gui::LiveView) = nothing

"""Updates the timeline strip of the `gui` at the time `now`: lanes, marks, ages, tooltip."""
_update_timeline!(gui::LiveView, now::Real) = nothing

"""Expands (`true`) or collapses the timeline strip of the `gui`."""
_set_expanded!(gui::LiveView, on::Bool) = (_activity(gui).expanded = on; nothing)
