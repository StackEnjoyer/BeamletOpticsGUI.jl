#=
Tracing per system: each system of a live view has its own auto tracing and is traced on its own,
see `_system_auto`, `_set_system_auto!` and `_trace_system!`. The switch of the view switches all
its systems, and the trace button and the key `t` trace all of them, see `_trace!`
=#

"""
Whether the system `sys` of the `gui` is traced after each change: while the auto tracing of the
view is on and the one of `sys` is not switched off on its own, see `_set_system_auto!`.
"""
_system_auto(gui::LiveView, sys::BMO.AbstractSystem) = gui.trace.auto[] && !(sys in gui.trace.manual)

"""The systems of the `gui` that are traced after each change, see `_system_auto`."""
_auto_systems(gui::LiveView) = BMO.AbstractSystem[s for s in _systems(gui) if _system_auto(gui, s)]

"""
Whether the beams of the system `sys` of the `gui` are outdated, i.e. dimmed until it is traced:
its objects or sources changed since its last solve, see `_note_stale!`.
"""
function _system_stale(gui::LiveView, sys::BMO.AbstractSystem)
    trace = gui.trace
    return trace.stale && (trace.stale_all || trace.link_stale || _has(trace.stale_systems, sys))
end

"""
    _affected_systems(gui, obj) -> Union{Nothing, Vector}

The systems of the `gui` that a change of `obj` affects: those that hold it, of a source the one
it is traced through. `nothing` if they are not known, i.e. all of them, e.g. after a slider.
"""
_affected_systems(::LiveView, ::Nothing) = nothing
function _affected_systems(gui::LiveView, @nospecialize(obj))
    systems = _systems_of(gui, obj)
    return isempty(systems) ? nothing : systems
end

# The systems `affected` (all for `nothing`) of the `gui` with and without auto tracing
function _split_auto(gui::LiveView, affected)
    systems = isnothing(affected) ? _systems(gui) : affected
    auto = BMO.AbstractSystem[s for s in systems if _system_auto(gui, s)]
    manual = BMO.AbstractSystem[s for s in systems if !_system_auto(gui, s)]
    return auto, manual
end

"""
The systems that a solve of the `gui` after a change traces if the systems `auto` are to be traced:
`nothing`, i.e. all systems, unless the auto tracing of a system is switched off on its own, such
that a view whose systems are all traced automatically solves as a whole.
"""
_solved_systems(gui::LiveView, auto) = isempty(gui.trace.manual) ? nothing : auto

"""
    _trace_set(gui, systems) -> Vector{AbstractSystem}

The systems of the `gui` that are traced when the `systems` are: these and, repeatedly, every system
that shares a `Detector` with one of them. A detector is emptied as a whole before a solve, hence
all beams that hit it are traced again.
"""
function _trace_set(gui::LiveView, systems)
    all = _systems(gui)
    set = BMO.AbstractSystem[s for s in all if _has(systems, s)]
    grown = true
    while grown
        grown = false
        used = Base.IdSet{Any}(_find_detectors(set))
        for s in all
            (_has(set, s) || !any(pd -> pd in used, _find_detectors(BMO.AbstractSystem[s]))) && continue
            push!(set, s)
            grown = true
        end
    end
    return set
end

# The pairs of the `gui` that are traced through the systems `traced` (all for `nothing`), and
# their beam render handles
function _traced_pairs(gui::LiveView, traced)
    isnothing(traced) && return gui.pairs, gui.beam_handles
    keep = [_has(traced, p.first) for p in gui.pairs]
    return gui.pairs[keep], gui.beam_handles[keep]
end

"""
    _set_system_auto!(gui, sys, on)

Switches the auto tracing of the system `sys` of the `gui` on or off; the other systems keep
theirs. The switch of the view follows: it is on while any system is traced automatically, and
switching it switches all systems. A system that is switched on while it is outdated is traced.
"""
function _set_system_auto!(gui::LiveView, sys::BMO.AbstractSystem, on::Bool)
    trace = gui.trace
    _system_auto(gui, sys) == on && return nothing
    if on
        if !trace.auto[]
            # only this system, the other ones stay as they are
            foreach(s -> s === sys || push!(trace.manual, s), _systems(gui))
            _sync_auto!(gui, true)
        end
        delete!(trace.manual, sys)
        _system_stale(gui, sys) && _trace_system!(gui, sys)
    else
        push!(trace.manual, sys)
        if isempty(_auto_systems(gui))
            empty!(trace.manual)
            _sync_auto!(gui, false)
        end
    end
    gui.status.text[] = "$(_label(gui, sys)) is traced " * (on ? "after each change" : "on request")
    _update_inspector!(gui)
    _update_cards!(gui)
    return nothing
end

# Sets the switch of the view without switching its systems, see `_connect_trace!`
function _sync_auto!(gui::LiveView, active::Bool)
    trace = gui.trace
    trace.auto[] == active && return nothing
    trace.auto_sync = true
    try
        trace.auto[] = active
    finally
        trace.auto_sync = false
    end
    return nothing
end

"""
    _trace_system!(gui, sys)

Traces the system `sys` of the `gui` on request, like its button "Trace": only its beams, and those
of the systems that share a detector with it (see `_trace_set`). The other systems stay as they
are, e.g. outdated. Ignored while a solve runs in the background.
"""
function _trace_system!(gui::LiveView, sys::BMO.AbstractSystem)
    _running(gui) && return nothing
    _solve!(gui, nothing; systems = BMO.AbstractSystem[sys]) &&
        (gui.status.text[] = "$(_label(gui, sys)) traced")
    _update_cards!(gui)
    return nothing
end

"""
    _on_systems_change!(gui, systems)

Called after the members or the sources of the `systems` of the `gui` changed: they are traced
again, or marked as outdated, like after a change of one of their objects, see `_on_change!`.
"""
_on_systems_change!(gui::LiveView, systems) = _on_change!(gui, nothing; systems)
