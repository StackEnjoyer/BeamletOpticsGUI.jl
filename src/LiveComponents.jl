#=
Components that are added to and removed from the systems of the live view at runtime, see
`add_component!` and `remove_component!`
=#

"""The systems of the `gui` whose objects can be changed at runtime, i.e. its `System`s."""
_mutable_systems(gui::LiveView) =
    BMO.System[rendered(h) for h in gui.system_handles if rendered(h) isa BMO.System]

"""Returns the system handle of the system `sys` in the `gui`, or `nothing`."""
function _system_handle(gui::LiveView, sys::BMO.AbstractSystem)
    i = findfirst(h -> rendered(h) === sys, gui.system_handles)
    return isnothing(i) ? nothing : gui.system_handles[i]
end

"""
    _target_system(gui) -> Union{System, Nothing}

The system that gets a component added to the `gui` without a `system`, e.g. from the catalog: the
inspected `System`, else the `System` of the selected or inspected object (of a source: the first
one it is paired with), else the first `System` of the view; `nothing` without a `System`.
"""
function _target_system(gui::LiveView)
    systems = _mutable_systems(gui)
    isempty(systems) && return nothing
    obj = _shown_object(gui)
    isnothing(obj) && return first(systems)
    top = _top_level(gui.controls.h, obj)
    for sys in systems
        (sys === obj || any(o -> o === top, sys.objects)) && return sys
    end
    for (sys, beam) in gui.pairs
        beam === obj && sys isa BMO.System && return sys
    end
    return first(systems)
end

"""
    _add_system(gui, system) -> System

The system that `add_component!` adds to: the given `system`, which must be a `System` shown in the
`gui`, or, for `nothing`, the `_target_system`. Throws an `ArgumentError` otherwise.
"""
function _add_system(gui::LiveView, ::Nothing)
    sys = _target_system(gui)
    isnothing(sys) && throw(ArgumentError(
        "the live view has no `System` to add components to, a `StaticSystem` can not be changed"))
    return sys
end
function _add_system(gui::LiveView, sys::BMO.System)
    isnothing(_system_handle(gui, sys)) &&
        throw(ArgumentError("the system is not shown in the live view"))
    return sys
end
_add_system(::LiveView, sys::BMO.AbstractSystem) = throw(ArgumentError(
    "a $(nameof(typeof(sys))) can not be changed, components are added to a `System`"))
_add_system(::LiveView, x) =
    throw(ArgumentError("`system` must be a `System` of the live view, got a $(typeof(x))"))

# A detector that is added gets the state of its view when its card first shows the page "Results",
# see `_detector_state`. A removed one is no longer emptied by the solves: it keeps no hits, and
# the view forgets it; its cards were unpinned before, see `remove_component!`
function _forget_detector!(gui::LiveView, pd::BMO.Detector)
    empty!(pd)
    delete!(gui.detectors.states, pd)
    filter!(((p, _),) -> p !== pd, gui.detectors.registered)
    return nothing
end
_forget_detector!(::LiveView, _) = nothing

# `origin` is `nothing` or `(; code, pose0)`: the constructor call of `obj` as Julia code and its
# pose as constructed, e.g. of a component of the catalog, see `_ComponentState` and `_export_code`
function add_component!(gui::LiveView, obj::BMO.AbstractObject; system = nothing,
        select::Bool = true, label = nothing, origin = nothing)
    ctrl = gui.controls
    comp = gui.components
    sys = _add_system(gui, system)
    h_sys = _system_handle(gui, sys)
    for leaf in _leaves(obj)
        isnothing(_child_handle(ctrl.h, leaf)) || throw(ArgumentError(
            "the $(nameof(typeof(leaf))) is already shown in the live view, as an object of a system or as an extra"))
    end
    # Stops a solve in the background, which traces the objects of the system
    _change!(() -> push!(sys, obj), ctrl, nothing)
    ohs = try
        live_render!(h_sys, obj; comp.render_kwargs...)
    catch
        # e.g. render kwargs that the object does not take: the system stays as it was
        delete!(sys, obj)
        rethrow()
    end
    foreach(oh -> push!(ctrl.h, oh), ohs)
    _theme_render!(gui.layout, ctrl.h)
    _apply_clip_planes!(gui)
    if !BMO.is_static(obj)
        push!(ctrl.movable, obj)
        for o in _descendants(obj)
            ctrl.init_poses[o] = _pose(o)
        end
    end
    isnothing(label) || (gui.labels[obj] = String(label))
    _name_objects!(gui)
    _map_parts!(gui)
    # A component the view started with, removed and added again, is no change
    i = findfirst(o -> o === obj, comp.removed)
    if isnothing(i)
        push!(comp.added, obj)
        comp.system[obj] = sys
        comp.origin[obj] = origin
    else
        deleteat!(comp.removed, i)
        delete!(comp.system, obj)
    end
    _on_components_changed!(gui)
    if select
        _is_movable(ctrl, obj) ? _select!(gui, obj) : _inspect!(gui, obj)
    end
    _on_change!(gui, obj)
    _record_added!(gui, obj)
    return obj
end

#=
Adding and removing in the undo history of the controls, see `_push_action!`
=#

"""
    _unrecorded(f, gui)

Calls `f()` without recording what it adds to or removes from the `gui` in the undo history: the
actions of the history themselves, and a change that is one action, e.g. replacing a component.
"""
function _unrecorded(f, gui::LiveView)
    comp = gui.components
    recording = comp.recording
    comp.recording = false
    try
        return f()
    finally
        comp.recording = recording
    end
end

"""
    _snapshot(gui, obj) -> NamedTuple

What the `gui` knows of the component or source `obj` and forgets when it is removed, such that
`_restore!` adds it again as it was: its system, its label and the names of its parts, its `origin`
and the initial poses of the controls, from which [`export_changes`](@ref) counts.
"""
function _snapshot(gui::LiveView, obj::BMO.AbstractObject)
    ctrl = gui.controls
    parts = _component_parts(obj)
    return (; system = _component_system(gui, obj), label = get(gui.labels, obj, nothing),
        origin = get(gui.components.origin, obj, nothing),
        names = Pair{Any, String}[p => gui.objects.names[p] for p in parts if haskey(gui.objects.names, p)],
        init_poses = Pair{Any, Any}[p => ctrl.init_poses[p] for p in parts if haskey(ctrl.init_poses, p)])
end

"""
    _restore!(gui, obj, snap)

Adds the component or source `obj` to the `gui` again as its `snap` describes it, see `_snapshot`,
without recording it in the undo history.
"""
function _restore!(gui::LiveView, obj::BMO.AbstractObject, snap)
    _unrecorded(gui) do
        add_component!(gui, obj; system = snap.system, label = snap.label, origin = snap.origin)
    end
    _restore_names!(gui, snap)
    return nothing
end

# The names and the initial poses of a snapshot, which adding gave anew
function _restore_names!(gui::LiveView, snap)
    for (p, name) in snap.names
        gui.objects.names[p] = name
    end
    for (p, pose) in snap.init_poses
        gui.controls.init_poses[p] = pose
    end
    _refresh_menu_options!(gui, gui.widgets.menu)
    _on_components_changed!(gui)
    return nothing
end

# Removes `obj` from the `gui` without recording it and returns its snapshot
function _remove_unrecorded!(gui::LiveView, obj)
    snap = _snapshot(gui, obj)
    _unrecorded(() -> remove_component!(gui, obj), gui)
    return snap
end

"""
Records that `obj` was added to the `gui` in the undo history, unless the history itself added it,
see `_unrecorded`: undo removes it, redo adds it again as it was.
"""
function _record_added!(gui::LiveView, obj)
    gui.components.recording || return nothing
    snap = Ref{Any}(nothing)
    _push_action!(gui.controls, obj, () -> (snap[] = _remove_unrecorded!(gui, obj)),
        () -> _restore!(gui, obj, snap[]))
    return nothing
end

"""
Records that `obj`, which had the snapshot `snap`, was removed from the `gui` in the undo history,
unless the history itself removed it: undo adds it again as it was, redo removes it.
"""
function _record_removed!(gui::LiveView, obj, snap)
    gui.components.recording || return nothing
    state = Ref{Any}(snap)
    _push_action!(gui.controls, obj, () -> _restore!(gui, obj, state[]),
        () -> (state[] = _remove_unrecorded!(gui, obj)))
    return nothing
end

"""
    _component_system(gui, obj) -> Union{System, Nothing}

The `System` of the `gui` that holds `obj` at its top level, i.e. from which `remove_component!` can
remove it, or `nothing`.
"""
function _component_system(gui::LiveView, obj)
    for sys in _mutable_systems(gui)
        any(o -> o === obj, sys.objects) && return sys
    end
    return nothing
end

"""
Returns the top-level object that `obj` belongs to in the `gui`: the outermost group, or the object
that it is a part of, see `_part_parent`.
"""
function _component_top(gui::LiveView, obj)
    top = _top_level(gui.controls.h, obj)
    parent = _part_parent(gui, top)
    while !isnothing(parent)
        top = parent
        parent = _part_parent(gui, top)
    end
    return top
end

"""
    _removal_reason(gui, obj) -> Union{Nothing, String}

Why `obj` can not be removed from the `gui` via `remove_component!`, for its `ArgumentError` and
the status line, or `nothing` if it can: only the top-level objects of the `System`s and the
sources of the view are removed.
"""
_removal_reason(::LiveView, ::LiveClipPlane) = "a clip plane is not a component of a system"
_removal_reason(gui::LiveView, src::Union{BMO.AbstractBeam, BMO.AbstractBeamGroup}) =
    any(p -> p.second === src, gui.pairs) ? nothing :
    "the $(nameof(typeof(src))) is not a source of the live view"
_removal_reason(::LiveView, ::BMO.AbstractSystem) = "a system can not be removed"
function _removal_reason(gui::LiveView, obj)
    isnothing(_component_system(gui, obj)) || return nothing
    name = _label(gui, obj)
    _is_extra(gui, obj) && return "$name is an extra, not a component of a system"
    top = _component_top(gui, obj)
    top === obj || return "$name is part of $(_label(gui, top)), remove $(_label(gui, top)) instead"
    for h in gui.system_handles
        any(o -> o === obj, rendered(h).objects) &&
            return "$name is an object of a $(nameof(typeof(rendered(h)))), which can not be changed"
    end
    return "$name is not a component of the live view"
end

"""Returns `obj`, the objects of its groups and their parts (recursively), see `_part_children`."""
function _component_parts(obj)
    parts = Base.IdSet{Any}()
    function walk!(x)
        x in parts && return nothing
        push!(parts, x)
        foreach(walk!, _children(x))
        foreach(walk!, _part_children(x))
        return nothing
    end
    walk!(obj)
    return parts
end

"""
    _release!(gui, top, parts; keep_name = false)

Lets go of the top-level object `top` of the `gui` and its `parts` (which include `top`) before
they are removed from the view: ends browsing, their inspection, their drag and their selection,
unpins their cards, clears a measurement with one of them, and forgets that they are movable, their
hidden state, opacity, parents, constraints, initial poses and names.
With `keep_name`, `top` keeps its name and label, e.g. for the code of `export_changes`.
"""
function _release!(gui::LiveView, top, parts; keep_name::Bool = false)
    ctrl = gui.controls
    _end_browse!(gui)
    gui.objects.inspected in parts && _end_inspection!(gui)
    if ctrl.press_leaf in parts || ctrl.selected[] in parts
        ctrl.dragging = false
        ctrl.drag_start = nothing
        ctrl.press_kind = :none
        ctrl.press_leaf = nothing
    end
    if ctrl.selected[] in parts
        ctrl.selected[] = nothing
        _update_selection_box!(ctrl)
    end
    foreach(p -> _unpin!(gui, p), parts)
    any(m -> m.obj in parts, gui.measure.points) && _clear_measurement!(gui)
    filter!(o -> o !== top, ctrl.movable)
    for p in parts
        delete!(gui.objects.hidden, p)
        delete!(gui.objects.opacity, p)
        delete!(gui.objects.parents, p)
        delete!(ctrl.constraints, p)
        delete!(ctrl.init_poses, p)
        (p === top && keep_name) && continue
        delete!(gui.objects.names, p)
        delete!(gui.labels, p)
    end
    # The entries of the undo history stay: undoing the removal brings the object back, see
    # `_record_removed!`
    !isnothing(ctrl.last_key_step) && ctrl.last_key_step.obj in parts && (ctrl.last_key_step = nothing)
    return nothing
end

function remove_component!(gui::LiveView, obj)
    reason = _removal_reason(gui, obj)
    isnothing(reason) || throw(ArgumentError(reason))
    ctrl = gui.controls
    comp = gui.components
    sys = _component_system(gui, obj)
    h_sys = _system_handle(gui, sys)
    name = _label(gui, obj)
    parts = _component_parts(obj)
    leaves = _leaves(obj)
    snap = _snapshot(gui, obj)
    # Stops a solve in the background, which traces the objects of the system
    _change!(() -> delete!(sys, obj), ctrl, nothing)
    # A component the view started with is listed by `export_changes` as removed, under its name
    added = findfirst(o -> o === obj, comp.added)
    _release!(gui, obj, parts; keep_name = isnothing(added))
    # The handles in the combined handle of the controls, before the system handle forgets them
    ohs = filter(!isnothing, [_child_handle(ctrl.h, leaf) for leaf in leaves])
    remove_render!(h_sys, obj)
    foreach(oh -> delete!(ctrl.h, oh), ohs)
    foreach(leaf -> _forget_detector!(gui, leaf), leaves)
    if isnothing(added)
        push!(comp.removed, obj)
        comp.system[obj] = sys
    else
        deleteat!(comp.added, added)
        delete!(comp.origin, obj)
        delete!(comp.system, obj)
    end
    _refresh_menu_options!(gui, gui.widgets.menu)
    _on_components_changed!(gui)
    gui.status.text[] = "$name removed"
    _on_change!(gui, nothing)
    _record_removed!(gui, obj, snap)
    return obj
end

"""
    _remove_selected!(gui, obj) -> Bool

Removes `obj` from the `gui` like `remove_component!`, after "remove" on its card or the key
`Delete`. An object that can not be removed is kept, and the status line names the reason, see
`_removal_reason`. Returns whether `obj` was removed.
"""
function _remove_selected!(gui::LiveView, obj)
    reason = _removal_reason(gui, obj)
    if !isnothing(reason)
        gui.status.text[] = reason
        return false
    end
    remove_component!(gui, obj)
    return true
end
