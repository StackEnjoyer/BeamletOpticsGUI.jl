#=
Groups made in the window: a selection of several objects becomes an `ObjectGroup` (`Ctrl+G`),
which is ungrouped again (`Ctrl+Shift+G`), see `_group!` and `_ungroup!`
=#

"""
    _WindowGroup(members, pivot, poses)

The record of an `ObjectGroup` that was made in the window from a selection of several objects,
see `_group!`: its `members` in their order, the `pivot` [m] that it got (`set_pivot3d!`, the mean
of the positions of the members) and the `poses` `(P, R)` of the members when it was made, from
which `export_script` writes the members and then the group, see `gui.components.groups`.
"""
struct _WindowGroup
    members::Vector{Any}
    pivot::Vector{Float64}
    poses::IdDict{Any, Tuple{Point3{Float64}, Matrix{Float64}}}
end

"""Returns whether `g` is a group made in the window of the `gui`, see `_group!`."""
_is_window_group(gui, @nospecialize(g)) = haskey(gui.components.groups, g)

# Whether `obj` can be a member of an `ObjectGroup`: objects and groups, no sources or clip planes
_groupable(@nospecialize(obj::BMO.ObjectOrGroup)) = true
_groupable(_) = false

# Why the object `obj` of a selection of several can not be a member of a group, see `_group_reason`
_member_reason(gui, ::LiveClipPlane) = "a clip plane can not be grouped"
function _member_reason(gui, @nospecialize(obj))
    name = _label(gui, obj)
    _is_source(obj) && return "$name is a source, sources can not be grouped"
    _groupable(obj) || return "$name is not a component, it can not be grouped"
    BMO.is_static(obj) && return "$name is static, it can not be grouped"
    if !_shown_top(gui, obj)
        top = _component_top(gui, obj)
        top === obj && return "$name is not a component of the live view"
        return "$name is part of $(_label(gui, top)), it can not be grouped on its own"
    end
    for sys in _member_systems(gui, obj)
        sys isa BMO.System ||
            return "$name is an object of a $(nameof(typeof(sys))), which can not be changed"
    end
    _is_movable(gui.controls, obj) || return "$name can not be moved, it can not be grouped"
    return nothing
end

# Whether the systems `a` and `b` are the same, in any order
_same_systems(a, b) = length(a) == length(b) && all(sys -> _has(b, sys), a)

"""
    _group_reason(gui, sel) -> Union{Nothing, String}

Why the selection `sel` of the controls of the `gui` can not be made a group (see `_group!`), for
the status line, or `nothing` if it can: a selection of several movable top-level components with
the same systems (or none), no source, clip plane or static object.
"""
function _group_reason(gui, @nospecialize(sel))
    _is_multi(sel) || return "select several objects to group them"
    objs = sel.objects
    length(objs) >= 2 || return "select several objects to group them"
    for obj in objs
        reason = _member_reason(gui, obj)
        isnothing(reason) || return reason
    end
    systems = _member_systems(gui, first(objs))
    for obj in objs
        _same_systems(systems, _member_systems(gui, obj)) && continue
        return "$(_label(gui, first(objs))) and $(_label(gui, obj)) belong to different systems, " *
               "only objects of the same systems are grouped"
    end
    return nothing
end

"""
    _group!(gui, sel) -> Union{Nothing, BMO.ObjectGroup}

Makes the selection of several objects `sel` of the `gui` an `ObjectGroup`, like `Ctrl+G`: the
systems of its objects hold the group instead of them, the group is selected and moved, rotated,
hidden and browsed like a group of the script. One action of the undo history. Returns the group,
or `nothing` with the reason in the status line, see `_group_reason`.
"""
function _group!(gui, @nospecialize(sel))
    reason = _group_reason(gui, sel)
    if !isnothing(reason)
        gui.status.text[] = reason
        return nothing
    end
    members = collect(Any, sel.objects)
    g = BMO.ObjectGroup(members)
    # the mean of the positions of the members, axes of the world, like the selection of several
    pivot = sum(m -> Vector{Float64}(position(m)), members) ./ length(members)
    BMO.set_pivot3d!(g, pivot)
    poses = IdDict{Any, Tuple{Point3{Float64}, Matrix{Float64}}}()
    foreach(m -> (poses[m] = _pose(m)), members)
    rec = _WindowGroup(members, pivot, poses)
    _unrecorded(() -> _do_group!(gui, g, rec), gui)
    _record_grouping!(gui, g, rec, true, nothing)
    return g
end

# Why the group `g` can not be ungrouped, see `_ungroup!`
function _ungroup_reason(gui, @nospecialize(g))
    g isa BMO.AbstractObjectGroup || return "select a group made in the window to ungroup it"
    _is_window_group(gui, g) ||
        return "$(_label(gui, g)) is a group of the script, only groups made in the window are ungrouped"
    _shown_top(gui, g) ||
        return "$(_label(gui, g)) is part of $(_label(gui, _component_top(gui, g))), ungroup that first"
    return nothing
end

"""
    _ungroup!(gui, g) -> Bool

Ungroups the group `g` that was made in the window of the `gui` (see `_group!`), like
`Ctrl+Shift+G`: its systems hold its members again, at their current poses, which are selected as a
selection of several. One action of the undo history. Returns `false` with a status line if `g` is
not a group made in the window.
"""
function _ungroup!(gui, @nospecialize(g))
    reason = _ungroup_reason(gui, g)
    if !isnothing(reason)
        gui.status.text[] = reason
        return false
    end
    rec = gui.components.groups[g]
    label = get(gui.labels, g, nothing)
    _unrecorded(() -> _do_ungroup!(gui, g), gui)
    _record_grouping!(gui, g, rec, false, label)
    return true
end

"""
    _record_grouping!(gui, g, rec, grouped, label)

Records in the undo history that the group `g` with the record `rec` (a `_WindowGroup`) was made
(`grouped`) or ungrouped in the `gui`, unless the history itself did it: undo does the other one,
redo the same again, with the same `g`, such that the later entries of the history on it still
apply. Ungrouping drops the `label` of `g`; grouping it again by the history gives it back.
"""
function _record_grouping!(gui, @nospecialize(g), rec::_WindowGroup, grouped::Bool, label)
    gui.components.recording || return nothing
    kept = Ref{Any}(label)
    group() = _unrecorded(() -> _do_group!(gui, g, rec; label = kept[]), gui)
    function ungroup()
        kept[] = get(gui.labels, g, nothing)
        _unrecorded(() -> _do_ungroup!(gui, g), gui)
    end
    _push_action!(gui.controls, g, grouped ? ungroup : group, grouped ? group : ungroup)
    return nothing
end

"""
    _do_group!(gui, g, rec; label = nothing)

The group `g` of the members of `rec` (a `_WindowGroup`) takes their place in the `gui`: in their
systems (or among the objects without a system), in the view (see `_show_group!`) and in the linked
views, with the `label`; `g` is selected and the systems are solved. Throws an `ArgumentError` with
the `_group_reason` if the members can not be grouped, e.g. by an entry of the undo history that no
longer applies.
"""
function _do_group!(gui, @nospecialize(g), rec::_WindowGroup; label = nothing)
    ctrl = gui.controls
    members = rec.members
    reason = length(members) < 2 ? "a group needs several objects" :
             _group_reason(gui, _MultiSelection(members))
    isnothing(reason) || throw(ArgumentError(reason))
    systems = _member_systems(gui, first(members))
    # Stops a solve in the background, which traces the objects of the systems
    _change!(ctrl, nothing) do
        for sys in systems
            foreach(m -> delete!(sys, m), members)
            push!(sys, g)
        end
    end
    _show_group!(gui, g, rec, systems; label)
    # The linked views group them before the solve, see `_follow_groups!`
    _sync_structure!(gui)
    if !ctrl.spectator[]
        ctrl.selected[] = g
        _update_selection_box!(ctrl)
    end
    gui.status.text[] = "$(length(members)) objects grouped as $(_label(gui, g))"
    isempty(systems) || _on_systems_change!(gui, systems)
    return nothing
end

"""
    _do_ungroup!(gui, g)

The members of the group `g` made in the window take its place in the `gui`, at their current
poses: in its systems (or among the objects without a system), in the view (see `_unshow_group!`)
and in the linked views; those that are not hidden are selected and the systems are solved. Throws
an `ArgumentError` with the reason if `g` can not be ungrouped, see `_ungroup!`.
"""
function _do_ungroup!(gui, @nospecialize(g))
    ctrl = gui.controls
    reason = _ungroup_reason(gui, g)
    isnothing(reason) || throw(ArgumentError(reason))
    name = _label(gui, g)
    members = collect(Any, BMO.objects(g))
    systems = _member_systems(gui, g)
    # Stops a solve in the background, which traces the objects of the systems
    _change!(ctrl, nothing) do
        for sys in systems
            delete!(sys, g)
            foreach(m -> push!(sys, m), members)
        end
    end
    _unshow_group!(gui, g, systems)
    # The linked views ungroup it before the solve, see `_follow_groups!`
    _sync_structure!(gui)
    if !ctrl.spectator[]
        shown = Any[m for m in members if !_all_hidden(gui, m)]
        ctrl.selected[] = _selection_of(shown)
        _update_selection_box!(ctrl)
    end
    gui.status.text[] = "$name ungrouped into $(length(members)) objects"
    isempty(systems) || _on_systems_change!(gui, systems)
    return nothing
end

"""
    _show_group!(gui, g, rec, systems; label = nothing)

The part of grouping that does not change the systems: the `gui` shows the group `g` of the members
of `rec` (a `_WindowGroup`) as a member of the `systems` (without a system if there are none)
instead of its members, which it renders again as the parts of `g` (see `_unshow!` and `_attach!`),
and records `g` in `gui.components.groups`. The members keep their names, labels, hidden state,
opacity, constraints and initial poses, see `_kept_state`, and what `gui.components` records of
them (no removal); `g` is recorded as added without an origin, like a component without code, see
`_record_units`. Also for a view that follows a linked one, see `_follow_groups!`.
"""
function _show_group!(gui, @nospecialize(g), rec::_WindowGroup, systems; label = nothing)
    state = _kept_state(gui, rec.members)
    foreach(m -> _unshow!(gui, m), rec.members)
    # before `_attach!`, which would name them anew
    _restore_kept_names!(gui, state)
    gui.components.groups[g] = rec
    targets = isempty(systems) ? Any[nothing] : collect(Any, systems)
    for (k, sys) in enumerate(targets)
        _attach!(gui, g, sys; label = k == 1 ? label : nothing, record = false)
    end
    # `g` is added like a component without code, its members keep what is recorded of them
    comp = gui.components
    _has(comp.added, g) || push!(comp.added, g)
    comp.origin[g] = nothing
    comp.system[g] = first(targets)
    _restore_kept_plots!(gui, state)
    return nothing
end

"""
    _unshow_group!(gui, g, systems)

The part of ungrouping that does not change the systems: the `gui` shows the members of the group
`g` made in the window as members of the `systems` (without a system if there are none) instead of
`g`, see `_show_group!`. The members keep their names, labels, hidden state, opacity, constraints
and initial poses; `g` loses its label, its own opacity, its record in `gui.components.groups`
and what `gui.components` records of it as added, and keeps its name, for the undo. Also for a view that follows a linked one, see
`_follow_groups!`.
"""
function _unshow_group!(gui, @nospecialize(g), systems)
    members = collect(Any, BMO.objects(g))
    state = _kept_state(gui, Any[g]; own = g)
    _unshow!(gui, g)
    comp = gui.components
    delete!(comp.groups, g)
    i = _index(comp.added, g)
    isnothing(i) || deleteat!(comp.added, i)
    delete!(comp.origin, g)
    delete!(comp.system, g)
    _restore_kept_names!(gui, state)
    targets = isempty(systems) ? Any[nothing] : collect(Any, systems)
    for m in members, sys in targets
        _attach!(gui, m, sys; record = false)
    end
    _restore_kept_plots!(gui, state)
    return nothing
end

"""
    _kept_state(gui, objs; own = nothing) -> NamedTuple

What the `gui` forgets of the top-level objects `objs` and their parts when they are taken out of
the view (see `_release!`) and keeps when they are grouped or ungrouped: their names, labels,
constraints, parents of parts, initial poses, opacity and the hidden ones of their rendered
objects. Of the group `own` itself, only its name, see `_unshow_group!`.
"""
function _kept_state(gui, objs; own = nothing)
    ctrl = gui.controls
    st = gui.objects
    parts = Any[]
    for obj in objs, p in _component_parts(obj)
        (p === own || _has(parts, p)) || push!(parts, p)
    end
    function kept(d)
        out = Pair{Any, Any}[]
        foreach(p -> haskey(d, p) && push!(out, p => d[p]), parts)
        return out
    end
    names = kept(st.names)
    (!isnothing(own) && haskey(st.names, own)) && push!(names, own => st.names[own])
    opacity = Pair{Any, Any}[]
    foreach(p -> haskey(st.opacity, p) && push!(opacity, p => st.opacity[p].value), parts)
    hidden = Any[]
    for obj in objs, leaf in _leaves(obj)
        leaf in st.hidden && push!(hidden, leaf)
    end
    return (; names, labels = kept(gui.labels), constraints = kept(ctrl.constraints),
        parents = kept(st.parents), init_poses = kept(ctrl.init_poses), opacity, hidden)
end

# The names, labels, constraints and parents of parts of a `_kept_state`
function _restore_kept_names!(gui, state)
    foreach(((p, v),) -> (gui.objects.names[p] = v), state.names)
    foreach(((p, v),) -> (gui.labels[p] = v), state.labels)
    foreach(((p, v),) -> (gui.controls.constraints[p] = v), state.constraints)
    foreach(((p, v),) -> (gui.objects.parents[p] = v), state.parents)
    return nothing
end

# The initial poses, the opacity and the hidden objects of a `_kept_state`, after the objects were
# rendered again, see `_set_opacity!` and `_set_hidden!`
function _restore_kept_plots!(gui, state)
    foreach(((p, v),) -> (gui.controls.init_poses[p] = v), state.init_poses)
    for (p, value) in state.opacity
        plots = _object_plots(gui.controls.h, p)
        rec = _Opacity(value, _rendered_opacity(plots), IdDict{AbstractPlot, _PlotBase}())
        gui.objects.opacity[p] = rec
        s = rec.initial > 0 ? value / rec.initial : value
        for plot in plots
            _apply_opacity!(plot, get!(() -> _plot_base(plot), rec.base, plot)..., s)
        end
    end
    foreach(leaf -> _set_hidden!(gui, leaf, true), state.hidden)
    isempty(state.hidden) || _on_hidden!(gui)
    return nothing
end
