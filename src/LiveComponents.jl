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

# Panels of the detectors among the rendered objects of a component, see `_add_detector_panel!`
_add_panel_of!(gui::LiveView, pd::BMO.Detector) = _add_detector_panel!(gui, pd)
_add_panel_of!(::LiveView, _) = nothing
# A removed detector is no longer emptied by the solves: it keeps no hits, such that a panel it has
# shows none
_remove_panel_of!(gui::LiveView, pd::BMO.Detector) = (empty!(pd); _remove_detector_panel!(gui, pd))
_remove_panel_of!(::LiveView, _) = nothing

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
    foreach(leaf -> _add_panel_of!(gui, leaf), _leaves(obj))
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
    return obj
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
the status line, or `nothing` if it can: only the top-level objects of the `System`s are removed.
"""
_removal_reason(::LiveView, ::LiveClipPlane) = "a clip plane is not a component of a system"
_removal_reason(gui::LiveView, src::Union{BMO.AbstractBeam, BMO.AbstractBeamGroup}) =
    "$(_label(gui, src)) is a source, sources can not be removed"
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
    # Stops a solve in the background, which traces the objects of the system
    _change!(() -> delete!(sys, obj), ctrl, nothing)
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
    # A component the view started with is listed by `export_changes` as removed, under its name
    added = findfirst(o -> o === obj, comp.added)
    filter!(o -> o !== obj, ctrl.movable)
    for p in parts
        delete!(gui.objects.hidden, p)
        delete!(gui.objects.opacity, p)
        delete!(gui.objects.parents, p)
        delete!(ctrl.constraints, p)
        delete!(ctrl.init_poses, p)
        (p === obj && isnothing(added)) && continue
        delete!(gui.objects.names, p)
        delete!(gui.labels, p)
    end
    filter!(e -> !(e.obj in parts), ctrl.undo_stack)
    filter!(e -> !(e.obj in parts), ctrl.redo_stack)
    !isnothing(ctrl.last_key_step) && ctrl.last_key_step.obj in parts && (ctrl.last_key_step = nothing)
    # The handles in the combined handle of the controls, before the system handle forgets them
    ohs = filter(!isnothing, [_child_handle(ctrl.h, leaf) for leaf in leaves])
    remove_render!(h_sys, obj)
    foreach(oh -> delete!(ctrl.h, oh), ohs)
    foreach(leaf -> _remove_panel_of!(gui, leaf), leaves)
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
