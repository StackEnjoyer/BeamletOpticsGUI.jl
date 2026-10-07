#=
Tracing per system: each system of a live view has its own auto tracing and is traced on its own,
see `_system_auto`, `_set_system_auto!` and `_trace_system!`
=#

"""
Whether the system `sys` of the `gui` is traced after each change: while the auto tracing of the
view is on and the one of `sys` is not switched off on its own, see `_set_system_auto!`.
"""
_system_auto(gui::LiveView, sys::BMO.AbstractSystem) = gui.trace.auto[] && !(sys in gui.trace.manual)

"""Whether the beams of the system `sys` of the `gui` are outdated, i.e. dimmed until it is traced."""
_system_stale(gui::LiveView, sys::BMO.AbstractSystem) = gui.trace.stale

"""
    _set_system_auto!(gui, sys, on)

Switches the auto tracing of the system `sys` of the `gui` on or off; the other systems keep theirs.
"""
function _set_system_auto!(gui::LiveView, sys::BMO.AbstractSystem, on::Bool)
    on ? delete!(gui.trace.manual, sys) : push!(gui.trace.manual, sys)
    return nothing
end

"""Traces the system `sys` of the `gui` on request, like its button "Trace"."""
_trace_system!(gui::LiveView, sys::BMO.AbstractSystem) = _trace!(gui)

"""
    _on_systems_change!(gui, systems)

Called after the members or the sources of the `systems` of the `gui` changed: they are traced
again, or marked as outdated, like after a change of one of their objects, see `_on_change!`.
"""
_on_systems_change!(gui::LiveView, systems) = _on_change!(gui, nothing)
