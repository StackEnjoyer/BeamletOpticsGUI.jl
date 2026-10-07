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
        (sys === obj || _has(sys.objects, top)) && return sys
    end
    for (sys, beam) in gui.pairs
        # a source without a system is paired with the system of the extras
        beam === obj && sys isa BMO.System && sys !== rendered(gui.extras) && return sys
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
# `:none`: the component belongs to no system, i.e. it is shown, but not traced
_add_system(::LiveView, s::Symbol) = s === :none ? nothing :
                                    throw(ArgumentError("`system` must be a `System` of the live view or `:none`, got :$s"))
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
# pose as constructed, e.g. of a component of the catalog, see `_ComponentState` and `_export_code`.
# The public keyword `code` gives one with the pose of `obj` when it is added, see `_code_origin`
function add_component!(gui::LiveView, @nospecialize(obj::BMO.AbstractObject); system = nothing,
        select::Bool = true, label = nothing, code = nothing, origin = _code_origin(obj, code))
    ctrl = gui.controls
    # Selecting it would be taken as a click of a pick of members, see `_pick_member!`
    select && _end_member_pick!(gui)
    # An object that the view shows becomes a member of a further system
    if system isa BMO.AbstractSystem && _shown_top(gui, obj)
        _add_member!(gui, obj, _add_system(gui, system))
        select && (_is_movable(ctrl, obj) ? _select!(gui, obj) : _inspect!(gui, obj))
        return obj
    end
    sys = _add_system(gui, system)
    for leaf in _leaves(obj)
        isnothing(_child_handle(ctrl.h, leaf)) || throw(ArgumentError(
            "the $(nameof(typeof(leaf))) is already shown in the live view, as an object of a system or as an extra"))
    end
    # Stops a solve in the background, which traces the objects of the system
    isnothing(sys) || _change!(() -> push!(sys, obj), ctrl, nothing)
    try
        _attach!(gui, obj, sys; label, origin)
    catch
        # e.g. render kwargs that the object does not take: the system stays as it was
        isnothing(sys) || delete!(sys, obj)
        rethrow()
    end
    # The linked views show it before the solve, see `_sync_structure!`
    _sync_structure!(gui)
    if select
        _is_movable(ctrl, obj) ? _select!(gui, obj) : _inspect!(gui, obj)
    end
    if isnothing(sys)
        # An object without a system is not traced
        gui.status.text[] = "$(_label(gui, obj)) added without a system, it is not traced"
    else
        _on_change!(gui, obj)
    end
    _record_added!(gui, obj)
    return obj
end

#=
Members: an object of the view belongs to any number of its systems, also to none
=#

"""The systems of the `gui` that hold `obj` at their top level, in the order of the view."""
_member_systems(gui::LiveView, @nospecialize(obj)) =
    BMO.AbstractSystem[rendered(h) for h in gui.system_handles if _has(rendered(h).objects, obj)]

"""
Whether `obj` is a top-level object that the `gui` shows: an object of one of its systems, or one
without a system, see `_live_render_extras!`.
"""
_shown_top(gui::LiveView, @nospecialize(obj)) =
    _has(rendered(gui.extras).objects, obj) || !isempty(_member_systems(gui, obj))

# The handle that holds the object handles of the members of `sys`: of no system, the extras
_member_handle(gui::LiveView, sys::BMO.AbstractSystem) = _system_handle(gui, sys)
_member_handle(gui::LiveView, ::Nothing) = gui.extras

# The object handles of `obj` (of the objects of a group) in the pool of the `gui`
function _pool_handles(gui::LiveView, @nospecialize(obj))
    ohs = AbstractObjectRenderHandle[]
    for leaf in _leaves(obj)
        oh = _child_handle(gui.pool, leaf)
        isnothing(oh) || push!(ohs, oh)
    end
    return ohs
end

"""
    _add_member!(gui, obj, sys)

The object `obj`, which the `gui` shows, becomes a member of its `System` `sys` as well: it is
pushed to `sys`, which is traced again, and stays one object with one pose, one card and one set of
plots. Recorded in the undo history. Throws an `ArgumentError` for an `obj` that the view does not
show at its top level, or that is in `sys` already.
"""
function _add_member!(gui::LiveView, @nospecialize(obj::BMO.AbstractObject), sys::BMO.System)
    isnothing(_system_handle(gui, sys)) && throw(ArgumentError("the system is not shown in the live view"))
    _shown_top(gui, obj) || throw(ArgumentError(
        "$(_label(gui, obj)) is not a top-level object of the live view, e.g. it is part of a group"))
    _has(sys.objects, obj) &&
        throw(ArgumentError("$(_label(gui, obj)) is already in $(_label(gui, sys))"))
    # Stops a solve in the background, which traces the objects of the system
    _change!(() -> push!(sys, obj), gui.controls, nothing)
    _attach!(gui, obj, sys)
    _sync_structure!(gui)
    gui.status.text[] = "$(_label(gui, obj)) added to $(_label(gui, sys))"
    _on_systems_change!(gui, BMO.AbstractSystem[sys])
    _record_member!(gui, obj, sys, true)
    return nothing
end

"""
    _remove_member!(gui, obj, sys)

Takes the object `obj` out of the `System` `sys` of the `gui`: it is deleted from `sys`, which is
traced again, and stays in the view, as a member of its other systems or without a system, see
`_detach!`. Recorded in the undo history. Throws an `ArgumentError` for an `obj` that is not in `sys`.
"""
function _remove_member!(gui::LiveView, @nospecialize(obj::BMO.AbstractObject), sys::BMO.System)
    isnothing(_system_handle(gui, sys)) && throw(ArgumentError("the system is not shown in the live view"))
    _has(sys.objects, obj) || throw(ArgumentError("$(_label(gui, obj)) is not in $(_label(gui, sys))"))
    _change!(() -> delete!(sys, obj), gui.controls, nothing)
    _detach!(gui, obj, sys; keep = true)
    _sync_structure!(gui)
    gui.status.text[] = "$(_label(gui, obj)) removed from $(_label(gui, sys))" *
                        (_is_extra(gui, obj) ? ", it is in no system now" : "")
    _on_systems_change!(gui, BMO.AbstractSystem[sys])
    _record_member!(gui, obj, sys, false)
    return nothing
end

# A membership that was `added` or removed, in the undo history, unless the history itself did it
function _record_member!(gui::LiveView, @nospecialize(obj), sys::BMO.System, added::Bool)
    gui.components.recording || return nothing
    add() = _unrecorded(() -> _add_member!(gui, obj, sys), gui)
    remove() = _unrecorded(() -> _remove_member!(gui, obj, sys), gui)
    _push_action!(gui.controls, obj, added ? remove : add, added ? add : remove)
    return nothing
end

"""
Records the systems of every top-level object and source that the `gui` starts with, see
`_ComponentState`.
"""
function _record_start_systems!(gui::LiveView)
    start = gui.components.start_systems
    append!(gui.components.systems0, _systems(gui))
    for h in gui.system_handles, obj in rendered(h).objects
        push!(get!(() -> Any[], start, obj), rendered(h))
    end
    foreach(obj -> get!(() -> Any[], start, obj), rendered(gui.extras).objects)
    for (sys, src) in gui.pairs
        start[src] = Any[sys]
    end
    return nothing
end

"""
    _code_origin(x, code) -> Union{NamedTuple, Nothing}

The `origin` of the component or source `x` for the keyword `code` of [`add_component!`](@ref):
`code`, the constructor call of `x`, with the pose of `x` now, in which `code` constructs it; `nothing`
without `code`. Throws an `ArgumentError` unless `code` is one Julia expression, see `_check_code`.
"""
function _code_origin(@nospecialize(x), code::AbstractString)
    _check_code(code)
    return (; code = String(code), pose0 = _pose(x))
end
_code_origin(@nospecialize(x), ::Nothing) = nothing

"""
    _check_code(code)

Throws an `ArgumentError` unless `code` is one Julia expression: [`export_script`](@ref) writes it as
`name = code`, such that a typing error, an empty string or several statements would give a script
that does not run. What the expression evaluates to is not checked, since that would run it.
"""
function _check_code(code::AbstractString)
    ex = Meta.parse(code; raise = false)
    reason = isnothing(ex) ? "it is empty" :
             !(ex isa Expr) ? nothing :
             ex.head === :toplevel ? "it has several statements" :
             ex.head in (:error, :incomplete) ? "it does not parse as a single expression" : nothing
    isnothing(reason) || throw(ArgumentError(
        "`code` must be one Julia expression that constructs the object, but $reason: $(repr(code))"))
    return nothing
end

"""
    _attach!(gui, obj, sys; label = nothing, origin = nothing)

Shows the component `obj` of the `System` `sys` in the `gui`: the part of [`add_component!`](@ref)
that does not change the system, i.e. its plots, the controls, its name and what the `gui` records
of it (see `_ComponentState`). Also for a view that follows a linked one, in which `obj` was added,
see `_follow_structure!`. Throws what `live_render!` throws, before the view changes.
"""
function _attach!(gui::LiveView, @nospecialize(obj::BMO.AbstractObject),
        sys::Union{Nothing, BMO.AbstractSystem}; label = nothing, origin = nothing)
    ctrl = gui.controls
    comp = gui.components
    # An object that the view shows is not rendered again, it only becomes a member of `sys`
    new = isempty(_pool_handles(gui, obj))
    ohs = _pool_handles!(gui.pool, obj, comp.render_kwargs)
    h = _member_handle(gui, sys)
    foreach(oh -> _has(render_children(h), oh) || push!(h, oh), ohs)
    extras = rendered(gui.extras)
    if isnothing(sys)
        _has(extras.objects, obj) || push!(extras, obj)
    elseif _has(extras.objects, obj)
        # no longer without a system
        delete!(extras, obj)
        foreach(oh -> delete!(gui.extras, oh), ohs)
    end
    if new
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
        i = _index(comp.removed, obj)
        if isnothing(i)
            _has(comp.added, obj) || push!(comp.added, obj)
            comp.system[obj] = sys
            comp.origin[obj] = origin
        else
            deleteat!(comp.removed, i)
            delete!(comp.system, obj)
        end
        _table_include!(gui, obj)
    end
    _refresh_menu_options!(gui, gui.widgets.menu)
    _on_components_changed!(gui)
    return nothing
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
function _snapshot(gui::LiveView, @nospecialize(obj::BMO.AbstractObject))
    ctrl = gui.controls
    parts = _component_parts(obj)
    return (; systems = _member_systems(gui, obj), label = get(gui.labels, obj, nothing),
        origin = get(gui.components.origin, obj, nothing),
        names = Pair{Any, String}[p => gui.objects.names[p] for p in parts if haskey(gui.objects.names, p)],
        init_poses = Pair{Any, Any}[p => ctrl.init_poses[p] for p in parts if haskey(ctrl.init_poses, p)])
end

"""
    _restore!(gui, obj, snap)

Adds the component or source `obj` to the `gui` again as its `snap` describes it, see `_snapshot`,
without recording it in the undo history.
"""
function _restore!(gui::LiveView, @nospecialize(obj::BMO.AbstractObject), snap)
    _unrecorded(gui) do
        system = isempty(snap.systems) ? :none : first(snap.systems)
        add_component!(gui, obj; system, label = snap.label, origin = snap.origin)
        # an object of several systems
        foreach(sys -> _add_member!(gui, obj, sys), snap.systems[2:end])
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
    # The linked views share the names, see `_ViewLinks`
    _refresh_links!(gui)
    return nothing
end

# Removes `obj` from the `gui` without recording it and returns its snapshot
function _remove_unrecorded!(gui::LiveView, @nospecialize(obj))
    snap = _snapshot(gui, obj)
    _unrecorded(() -> remove_component!(gui, obj), gui)
    return snap
end

"""
Records that `obj` was added to the `gui` in the undo history, unless the history itself added it,
see `_unrecorded`: undo removes it, redo adds it again as it was.
"""
function _record_added!(gui::LiveView, @nospecialize(obj))
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
function _record_removed!(gui::LiveView, @nospecialize(obj), snap)
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
function _component_system(gui::LiveView, @nospecialize(obj))
    for sys in _mutable_systems(gui)
        _has(sys.objects, obj) && return sys
    end
    return nothing
end

"""
Returns the top-level object that `obj` belongs to in the `gui`: the outermost group, or the object
that it is a part of, see `_part_parent`.
"""
function _component_top(gui::LiveView, @nospecialize(obj))
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
_removal_reason(::LiveView, ::BMO.AbstractSystem) = "a system is removed with remove_system!"
function _removal_reason(gui::LiveView, @nospecialize(obj))
    name = _label(gui, obj)
    for sys in _member_systems(gui, obj)
        sys isa BMO.System ||
            return "$name is an object of a $(nameof(typeof(sys))), which can not be changed"
    end
    # also an object without a system, e.g. an extra
    _shown_top(gui, obj) && return nothing
    top = _component_top(gui, obj)
    top === obj || return "$name is part of $(_label(gui, top)), remove $(_label(gui, top)) instead"
    return "$name is not a component of the live view"
end

"""Returns `obj`, the objects of its groups and their parts (recursively), see `_part_children`."""
function _component_parts(@nospecialize(obj))
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

function remove_component!(gui::LiveView, @nospecialize(obj); system = nothing)
    if !isnothing(system)
        # Only out of this system, the object stays in the view
        system isa BMO.System || throw(ArgumentError(
            "`system` must be a `System` of the live view, got a $(nameof(typeof(system)))"))
        obj isa BMO.AbstractObject ||
            throw(ArgumentError("a $(nameof(typeof(obj))) is not a component of a system"))
        _remove_member!(gui, obj, system)
        return obj
    end
    reason = _removal_reason(gui, obj)
    isnothing(reason) || throw(ArgumentError(reason))
    systems = _member_systems(gui, obj)
    name = _label(gui, obj)
    snap = _snapshot(gui, obj)
    # Stops a solve in the background, which traces the objects of the systems
    _change!(() -> foreach(sys -> delete!(sys, obj), systems), gui.controls, nothing)
    _drop!(gui, obj, isempty(systems) ? nothing : first(systems))
    # The linked views let go of it before the solve, see `_sync_structure!`
    _sync_structure!(gui)
    gui.status.text[] = "$name removed"
    # An object without a system was not traced
    isempty(systems) || _on_change!(gui, nothing)
    _record_removed!(gui, obj, snap)
    return obj
end

"""
    _detach!(gui, obj, sys; keep = false)

The component `obj` is no longer a member of the system `sys` of the `gui` (of no system for
`nothing`), from which the caller has deleted it: the part of taking it out that does not change
the system. An object of another system of the view stays as it is. One that is in no system
afterwards stays in the view without a system with `keep`, see `_live_render_extras!`; otherwise
the view lets go of it, see `_drop!`. Also for a view that follows a linked one, in which `obj` was
removed, see `_follow_structure!`.
"""
function _detach!(gui::LiveView, @nospecialize(obj::BMO.AbstractObject),
        sys::Union{Nothing, BMO.AbstractSystem}; keep::Bool = false)
    ohs = _pool_handles(gui, obj)
    h = _member_handle(gui, sys)
    isnothing(h) || foreach(oh -> delete!(h, oh), ohs)
    extras = rendered(gui.extras)
    if isempty(_member_systems(gui, obj))
        (keep && !isnothing(sys)) || return _drop!(gui, obj, sys)
        # without a system now
        _has(extras.objects, obj) || push!(extras, obj)
        foreach(oh -> _has(render_children(gui.extras), oh) || push!(gui.extras, oh), ohs)
    end
    _refresh_menu_options!(gui, gui.widgets.menu)
    _on_components_changed!(gui)
    return nothing
end

"""
    _drop!(gui, obj, sys)

Lets go of the component `obj` in the `gui`, which no system of the view holds any more: its
plots, the controls, its name and what the `gui` records of it (see `_release!` and
`_ComponentState`, with `sys` as the system that it was removed from, `nothing` for none).
"""
function _drop!(gui::LiveView, @nospecialize(obj::BMO.AbstractObject), sys)
    ctrl = gui.controls
    comp = gui.components
    parts = _component_parts(obj)
    leaves = _leaves(obj)
    # A component the view started with is listed by `export_changes` as removed, under its name
    added = _index(comp.added, obj)
    _release!(gui, obj, parts; keep_name = isnothing(added))
    ohs = _pool_handles(gui, obj)
    for h in (gui.system_handles..., gui.extras)
        foreach(oh -> delete!(h, oh), ohs)
    end
    extras = rendered(gui.extras)
    _has(extras.objects, obj) && delete!(extras, obj)
    remove_render!(gui.pool, obj)
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
    return nothing
end

"""
    _remove_selected!(gui, obj) -> Bool

Removes `obj` from the `gui` like `remove_component!`, after "remove" on its card or the key
`Delete`. An object that can not be removed is kept, and the status line names the reason, see
`_removal_reason`. Returns whether `obj` was removed.
"""
function _remove_selected!(gui::LiveView, @nospecialize(obj))
    reason = _removal_reason(gui, obj)
    if !isnothing(reason)
        gui.status.text[] = reason
        return false
    end
    remove_component!(gui, obj)
    return true
end
