#=
Groups made in the window: a selection of several objects becomes an `ObjectGroup` (`Ctrl+G`),
which is ungrouped again (`Ctrl+Shift+G`), see `_group!` and `_ungroup!`
=#

"""
    _WindowGroup(members, pivot, poses)

The record of an `ObjectGroup` that was made in the window from a selection of several objects,
see `_group!`: its `members` in their order, the `pivot` [m] that it got (`set_pivot3d!`, the mean
of the positions of the members) and the `poses` `(P, R)` of the members when it was made, from
which `export_script` writes the members and then the group, see `gui.components.groups`. When its
parts are changed in place (see `_regroup!`), the record is made anew from the group as it is then,
see `_current_record`.
"""
struct _WindowGroup
    members::Vector{Any}
    pivot::Vector{Float64}
    poses::IdDict{Any, Tuple{Point3{Float64}, Matrix{Float64}}}
end

"""Returns whether `g` is a group made in the window of the `gui`, see `_group!`."""
_is_window_group(gui, @nospecialize(g)) = haskey(gui.components.groups, g)

"""
    _current_record(g) -> _WindowGroup

The record of the group `g` made in the window as it is now: its objects, its position as the pivot
and the poses of its objects as if `g` had the axes of the world, i.e. rotated back by the
orientation of `g` about its position. The group of these objects with the axes of the world and
this pivot, rotated by the orientation of `g`, is `g`, see `_export_group_lines!`.
"""
function _current_record(@nospecialize(g))
    members = collect(Any, BMO.objects(g))
    pivot = Vector{Float64}(position(g))
    Rg = Matrix{Float64}(BMO.orientation(g))
    poses = IdDict{Any, Tuple{Point3{Float64}, Matrix{Float64}}}()
    for m in members
        P, R = _pose(m)
        poses[m] = (Point3{Float64}(pivot .+ Rg' * (Vector{Float64}(P) .- pivot)), Rg' * R)
    end
    return _WindowGroup(members, pivot, poses)
end

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
the same systems (or none), no source, clip plane or static object; or several, not all, parts of
the same group, see `_subgroup_reason`.
"""
function _group_reason(gui, @nospecialize(sel))
    _is_multi(sel) || return "select several objects to group them"
    objs = sel.objects
    length(objs) >= 2 || return "select several objects to group them"
    parent = _part_parent(gui, first(objs))
    for obj in objs
        _part_parent(gui, obj) === parent && continue
        return "$(_label(gui, first(objs))) and $(_label(gui, obj)) are not parts of the same group, " *
               "only parts of one group or top-level objects are grouped"
    end
    isnothing(parent) || return _subgroup_reason(gui, objs, parent)
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
    _group_chain(gui, parent) -> Vector{Any}

The groups that hold the part `parent` and `parent` itself, from the top-level one down to `parent`,
see `_part_parent`.
"""
function _group_chain(gui, @nospecialize(parent))
    chain = Any[parent]
    p = _part_parent(gui, parent)
    while !isnothing(p)
        pushfirst!(chain, p)
        p = _part_parent(gui, p)
    end
    return chain
end

"""
    _regroup_reason(gui, parent) -> Union{Nothing, String}

Why the parts of the group `parent` of the `gui` can not be changed in place (see `_regroup!`), or
`nothing`: `parent` and the groups that hold it (see `_group_chain`) are `ObjectGroup`s (not
assemblies of their own type or components with parts) whose code is not known to the view (an
added component with code is built by it, see `_ComponentState`), and the top-level one can be
moved and is a member of no `StaticSystem`, see `_member_reason`.
"""
function _regroup_reason(gui, @nospecialize(parent))
    chain = _group_chain(gui, parent)
    for p in chain
        p isa BMO.ObjectGroup ||
            return "$(_label(gui, p)) is a $(nameof(typeof(p))), its parts can not be regrouped"
        isnothing(get(gui.components.origin, p, nothing)) ||
            return "$(_label(gui, p)) is built by its code, its parts can not be regrouped"
    end
    return _member_reason(gui, first(chain))
end

"""
    _subgroup_reason(gui, objs, parent) -> Union{Nothing, String}

Why the parts `objs` of the group `parent` can not be made a group inside it (see `_subgroup!`), or
`nothing`: several of its parts, not all of them, and the parts of `parent` can be changed, see
`_regroup_reason`.
"""
function _subgroup_reason(gui, objs, @nospecialize(parent))
    length(objs) < length(BMO.objects(parent)) ||
        return "all parts of $(_label(gui, parent)) are selected, it is their group already"
    return _regroup_reason(gui, parent)
end

"""
    _group!(gui, sel) -> Union{Nothing, BMO.ObjectGroup}

Makes the selection of several objects `sel` of the `gui` an `ObjectGroup`, like `Ctrl+G`: the
systems of its objects hold the group instead of them, the group is selected and moved, rotated,
hidden and browsed like a group of the script. Several parts of one group become a group inside
it, see `_subgroup!`. One action of the undo history. Returns the group, or `nothing` with the
reason in the status line, see `_group_reason`.
"""
function _group!(gui, @nospecialize(sel))
    reason = _group_reason(gui, sel)
    if !isnothing(reason)
        gui.status.text[] = reason
        return nothing
    end
    parent = _part_parent(gui, first(sel.objects))
    isnothing(parent) || return _subgroup!(gui, sel.objects, parent)
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
    parent = _part_parent(gui, g)
    return isnothing(parent) ? nothing : _regroup_reason(gui, parent)
end

"""
    _ungroup!(gui, g) -> Bool

Ungroups the group `g` that was made in the window of the `gui` (see `_group!`), like
`Ctrl+Shift+G`: its systems hold its members again, at their current poses, which are selected as a
selection of several; a `g` that is part of another group is dissolved into that one, see
`_dissolve!`. One action of the undo history. Returns `false` with a status line if `g` is not a
group made in the window.
"""
function _ungroup!(gui, @nospecialize(g))
    reason = _ungroup_reason(gui, g)
    if !isnothing(reason)
        gui.status.text[] = reason
        return false
    end
    parent = _part_parent(gui, g)
    isnothing(parent) || return _dissolve!(gui, g, parent)
    rec = gui.components.groups[g]
    label = get(gui.labels, g, nothing)
    _unrecorded(() -> _do_ungroup!(gui, g), gui)
    _record_grouping!(gui, g, rec, false, label)
    return true
end

"""
    _dissolve!(gui, g, parent) -> Bool

Ungroups the group `g` made in the window of the `gui` that is a part of the group `parent`: its
members take its place in `parent`, which is changed in place, see `_regroup!`. The members are
selected. One action of the undo history.
"""
function _dissolve!(gui, @nospecialize(g), @nospecialize(parent))
    rec = gui.components.groups[g]
    members = collect(Any, BMO.objects(g))
    after = Any[]
    for o in BMO.objects(parent)
        o === g ? append!(after, members) : push!(after, o)
    end
    label = Ref{Any}(nothing)
    function inner!(forward::Bool)
        if forward
            label[] = get(gui.labels, g, nothing)
            delete!(gui.components.groups, g)
            return Any[g]
        end
        gui.components.groups[g] = rec
        isnothing(label[]) || (gui.labels[g] = label[])
        return Any[]
    end
    function done(forward::Bool)
        ctrl = gui.controls
        if !ctrl.spectator[]
            ctrl.selected[] = forward ? _selection_of(Any[m for m in members if !_all_hidden(gui, m)]) : g
            _update_selection_box!(ctrl)
        end
        gui.status.text[] = forward ? "$(_label(gui, g)) ungrouped into $(_label(gui, parent))" :
                            "$(length(members)) objects grouped as $(_label(gui, g)) in $(_label(gui, parent))"
        return nothing
    end
    _regroup!(gui, parent, after, inner!, done)
    return true
end

"""
    _subgroup!(gui, objs, parent) -> BMO.ObjectGroup

Makes the parts `objs` of the group `parent` of the `gui` a group inside it, like `Ctrl+G` on a
selection of several of its parts: a new `ObjectGroup` of them in the order of `parent`, at the
place of the first of them, with the mean of their positions as its pivot and the axes of the
world. `parent` is changed in place, see `_regroup!`. The new group is selected. One action of the
undo history. Returns the new group.
"""
function _subgroup!(gui, objs, @nospecialize(parent))
    ordered = Any[o for o in BMO.objects(parent) if _has(objs, o)]
    s = BMO.ObjectGroup(ordered)
    pivot = sum(o -> Vector{Float64}(position(o)), ordered) ./ length(ordered)
    BMO.set_pivot3d!(s, pivot)
    poses = IdDict{Any, Tuple{Point3{Float64}, Matrix{Float64}}}()
    foreach(o -> (poses[o] = _pose(o)), ordered)
    rec = _WindowGroup(ordered, pivot, poses)
    after = Any[]
    for o in BMO.objects(parent)
        o === first(ordered) ? push!(after, s) : (_has(ordered, o) || push!(after, o))
    end
    label = Ref{Any}(nothing)
    function inner!(forward::Bool)
        if forward
            gui.components.groups[s] = rec
            isnothing(label[]) || (gui.labels[s] = label[])
            return Any[]
        end
        label[] = get(gui.labels, s, nothing)
        delete!(gui.components.groups, s)
        return Any[s]
    end
    function done(forward::Bool)
        ctrl = gui.controls
        if !ctrl.spectator[]
            ctrl.selected[] = forward ? s : _selection_of(Any[o for o in ordered if !_all_hidden(gui, o)])
            _update_selection_box!(ctrl)
        end
        gui.status.text[] = forward ?
            "$(length(ordered)) objects grouped as $(_label(gui, s)) in $(_label(gui, parent))" :
            "$(_label(gui, s)) ungrouped into $(_label(gui, parent))"
        return nothing
    end
    _regroup!(gui, parent, after, inner!, done)
    return s
end

"""
    _set_parts!(group, parts)

Changes the objects of the `ObjectGroup` `group` in place to `parts`, in this order: all are
deleted and the `parts` are pushed again, since `push!` appends. The poses do not change.
"""
function _set_parts!(@nospecialize(group), parts)
    foreach(o -> delete!(group, o), collect(Any, BMO.objects(group)))
    push!(group, parts...)
    return nothing
end

"""
    _regroup!(gui, parent, after, inner!, done)

Changes the parts of the group `parent` of the `gui` in place to `after`, e.g. a new group of some
of them at the place of the first one (see `_subgroup!`) or the members of a group in its place
(see `_dissolve!`): `parent` and the groups that hold it stay the same objects with their poses, in
the same systems, which are solved. `inner!(forward)` changes what the `gui` records of the groups
that come or go (their records in `gui.components.groups` and labels) and returns the groups that
are no parts any more; `done(forward)` selects and sets the status line. A group of the script
keeps its parts at the start for `export_changes`, see `gui.components.start_parts`; the record of
a group made in the window is made anew, see `_current_record`.

One action of the undo history: undo gives `parent` its parts as before, in their order, and calls
`inner!(false)` and `done(false)`; redo does the same again with the same groups. Both throw an
`ArgumentError` before they change anything if `parent` no longer has the parts that they expect,
e.g. after a linked view changed them, such that the history drops the entry, see `_history_step!`.
"""
function _regroup!(gui, @nospecialize(parent), after::Vector{Any}, inner!, done)
    ctrl = gui.controls
    comp = gui.components
    before = collect(Any, BMO.objects(parent))
    window = _is_window_group(gui, parent)
    old_rec = window ? comp.groups[parent] : nothing
    window || get!(() -> copy(before), comp.start_parts, parent)
    function apply(forward::Bool)
        expected = forward ? before : after
        parts = BMO.objects(parent)
        # the top-level object now, e.g. after it was grouped
        top = _component_top(gui, parent)
        (_shown_top(gui, top) && length(parts) == length(expected) &&
         all(i -> parts[i] === expected[i], eachindex(expected))) ||
            throw(ArgumentError("the parts of $(_label(gui, parent)) were changed meanwhile"))
        systems = _member_systems(gui, top)
        gone = inner!(forward)
        # Stops a solve in the background, which traces the objects of the systems
        _change!(() -> _set_parts!(parent, forward ? after : before), ctrl, nothing)
        window && (comp.groups[parent] = forward ? _current_record(parent) : old_rec)
        _restructured!(gui, top, gone)
        # The linked views follow before the solve, see `_follow_groups!`
        _sync_structure!(gui)
        done(forward)
        isempty(systems) || _on_systems_change!(gui, systems)
        return nothing
    end
    _unrecorded(() -> apply(true), gui)
    comp.recording &&
        _push_action!(ctrl, parent, () -> _unrecorded(() -> apply(false), gui),
            () -> _unrecorded(() -> apply(true), gui))
    return nothing
end

"""
    _restructured!(gui, top, gone)

The `gui` shows the top-level object `top`, the parts of whose groups were changed in place (see
`_regroup!`), as it is now, without rendering it again: the groups `gone`, which are no parts any
more, lose what the `gui` knows of them (see `_forget_part!`), the new parts are mapped and named
(see `_map_parts!`) and get their initial poses, those of before if they were parts already (see
`gui.components.forgotten`), and the groups made in the window among the parts
of `top` are recorded as added, like a component without code, see `_record_units`. Also for a view
that follows a linked one, see `_follow_groups!`.
"""
function _restructured!(gui, @nospecialize(top), gone)
    ctrl = gui.controls
    comp = gui.components
    _end_browse!(gui)
    foreach(g -> _forget_part!(gui, g), gone)
    _map_parts!(gui)
    systems = _member_systems(gui, top)
    for d in _descendants(top)
        if haskey(comp.forgotten, d)
            init, constraint = pop!(comp.forgotten, d)
            isnothing(init) || (ctrl.init_poses[d] = init)
            isnothing(constraint) || (ctrl.constraints[d] = constraint)
        end
        haskey(ctrl.init_poses, d) || (ctrl.init_poses[d] = _pose(d))
        (haskey(comp.groups, d) && !_has(comp.added, d)) || continue
        push!(comp.added, d)
        comp.origin[d] = nothing
        comp.system[d] = isempty(systems) ? nothing : first(systems)
    end
    _refresh_menu_options!(gui, gui.widgets.menu)
    _on_components_changed!(gui)
    return nothing
end

"""
    _forget_part!(gui, g)

Lets go of the group `g` of the `gui`, which is no part of its group any more (see `_dissolve!`)
while its objects stay in the view: like `_release!` of `g` alone, but it keeps its name for the
undo, and its initial pose, from which `export_changes` counts, and its constraint are kept in
`gui.components.forgotten`, from which `_restructured!` gives them back. Its own opacity is taken
from the plots of its objects, which keep their own, and it is no longer recorded as added.
"""
function _forget_part!(gui, @nospecialize(g))
    ctrl = gui.controls
    st = gui.objects
    comp = gui.components
    st.inspected === g && _end_inspection!(gui)
    sel = ctrl.selected[]
    kept = sel === g ? nothing : _without(sel, Any[g])
    kept === sel || (ctrl.selected[] = kept; _update_selection_box!(ctrl))
    _unpin!(gui, g)
    any(m -> m.obj === g, gui.measure.points) && _clear_measurement!(gui)
    _drop_opacity!(gui, g)
    delete!(st.parents, g)
    delete!(gui.labels, g)
    comp.forgotten[g] = (pop!(ctrl.init_poses, g, nothing), pop!(ctrl.constraints, g, nothing))
    i = _index(comp.added, g)
    isnothing(i) || deleteat!(comp.added, i)
    delete!(comp.origin, g)
    delete!(comp.system, g)
    !isnothing(ctrl.last_key_step) && ctrl.last_key_step.obj === g && (ctrl.last_key_step = nothing)
    return nothing
end

# The plots of the objects of `g` without the opacity of `g` itself, with their own, see
# `_set_opacity!`
function _drop_opacity!(gui, @nospecialize(g))
    st = gui.objects
    rec = get(st.opacity, g, nothing)
    isnothing(rec) && return nothing
    delete!(st.opacity, g)
    for (plot, base) in rec.base
        _apply_opacity!(plot, base..., 1.0)
    end
    for p in _component_parts(g)
        own = get(st.opacity, p, nothing)
        (p === g || isnothing(own)) && continue
        s = own.initial > 0 ? own.value / own.initial : own.value
        for plot in _object_plots(gui.controls.h, p)
            _apply_opacity!(plot, get!(() -> _plot_base(plot), own.base, plot)..., s)
        end
    end
    return nothing
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

The members of the top-level group `g` made in the window take its place in the `gui`, at their
current poses: in its systems (or among the objects without a system), in the view (see
`_unshow_group!`) and in the linked views; those that are not hidden are selected and the systems
are solved. Throws an `ArgumentError` with the reason if `g` can not be ungrouped, see `_ungroup!`;
a `g` that is part of another group is dissolved into it by `_dissolve!` instead.
"""
function _do_ungroup!(gui, @nospecialize(g))
    ctrl = gui.controls
    reason = _ungroup_reason(gui, g)
    isnothing(reason) || throw(ArgumentError(reason))
    _shown_top(gui, g) || throw(ArgumentError("$(_label(gui, g)) is part of $(_label(gui, _component_top(gui, g)))"))
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
and what `gui.components` records of it as added, and keeps its name, for the undo. Also for a view
that follows a linked one, see `_follow_groups!`.
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
    # the members are top-level again, no parts of `g`, see `_component_top`
    for m in members
        get(gui.objects.parents, m, nothing) === g && delete!(gui.objects.parents, m)
    end
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
