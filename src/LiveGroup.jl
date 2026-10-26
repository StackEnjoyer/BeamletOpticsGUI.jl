#=
Groups made in the window: a selection of several objects becomes an `ObjectGroup` (`Ctrl+G`),
which is ungrouped again (`Ctrl+Shift+G`), see `_group!` and `_ungroup!`
=#

"""
    _WindowGroup(members, pivot, poses, replaces = nothing)

The record of an `ObjectGroup` that was made in the window from a selection of several objects,
see `_group!`: its `members` in their order, the `pivot` [m] that it got (`set_pivot3d!`, the mean
of the positions of the members) and the `poses` `(P, R)` of the members when it was made, from
which `export_script` writes the members and then the group, see `gui.components.groups`. A group
that was made anew from a group of the script, when a subgroup was made inside it or a group inside
it was dissolved (see `_remake!`), `replaces` that group of the script, which `export_changes`
deletes from its systems.
"""
struct _WindowGroup
    members::Vector{Any}
    pivot::Vector{Float64}
    poses::IdDict{Any, Tuple{Point3{Float64}, Matrix{Float64}}}
    replaces::Any
end
_WindowGroup(members, pivot, poses) = _WindowGroup(members, pivot, poses, nothing)

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
    _remake_reason(gui, chain) -> Union{Nothing, String}

Why the groups `chain` (from the top-level one down, see `_group_chain`) can not be made anew (see
`_remake!`), or `nothing`: each is an `ObjectGroup`, of the script or made in the window (not an
assembly of its own type or a component with parts), and the top-level one can be moved and is a
member of no `StaticSystem`, see `_member_reason`.
"""
function _remake_reason(gui, chain::Vector{Any})
    for p in chain
        p isa BMO.ObjectGroup && continue
        return "$(_label(gui, p)) is a $(nameof(typeof(p))), its parts can not be regrouped"
    end
    return _member_reason(gui, first(chain))
end

"""
    _subgroup_reason(gui, objs, parent) -> Union{Nothing, String}

Why the parts `objs` of the group `parent` can not be made a group inside it (see `_subgroup!`), or
`nothing`: several of its parts, not all of them, and `parent` and the groups that hold it can be
made anew, see `_remake_reason`.
"""
function _subgroup_reason(gui, objs, @nospecialize(parent))
    length(objs) < length(BMO.objects(parent)) ||
        return "all parts of $(_label(gui, parent)) are selected, it is their group already"
    return _remake_reason(gui, _group_chain(gui, parent))
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
    return isnothing(parent) ? nothing : _remake_reason(gui, _group_chain(gui, parent))
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
    isnothing(parent) || return _dissolve!(gui, g, _group_chain(gui, parent))
    rec = gui.components.groups[g]
    label = get(gui.labels, g, nothing)
    _unrecorded(() -> _do_ungroup!(gui, g), gui)
    _record_grouping!(gui, g, rec, false, label)
    return true
end

"""
    _dissolve!(gui, g, chain) -> Bool

Ungroups the group `g` made in the window of the `gui` that is part of the groups `chain`, from the
top-level one down to the one that holds `g` (see `_group_chain`): its members take its place in
that group, which is made anew with the groups above it, see `_remake!`. The new top-level group is
selected. One action of the undo history.
"""
function _dissolve!(gui, @nospecialize(g), chain::Vector{Any})
    rec = gui.components.groups[g]
    label = Ref{Any}(nothing)
    bottom = Any[]
    for o in BMO.objects(last(chain))
        o === g ? append!(bottom, BMO.objects(g)) : push!(bottom, o)
    end
    function inner!(forward::Bool)
        if forward
            label[] = get(gui.labels, g, nothing)
            _do_ungroup!(gui, g)
        else
            _do_group!(gui, g, rec; label = label[])
        end
        return nothing
    end
    done(news) = (gui.status.text[] = "$(_label(gui, g)) ungrouped into $(_label(gui, first(news)))")
    _remake!(gui, chain, bottom, inner!, done)
    return true
end

"""
    _subgroup!(gui, objs, parent) -> BMO.ObjectGroup

Makes the parts `objs` of the group `parent` of the `gui` a group inside it, like `Ctrl+G` on a
selection of several of its parts: a new `ObjectGroup` of them in the order of `parent`, at the
place of the first of them, with the mean of their positions as its pivot and the axes of the
world. `parent` and the groups that hold it are made anew, see `_remake!`. The new group is
selected. One action of the undo history. Returns the new group.
"""
function _subgroup!(gui, objs, @nospecialize(parent))
    ordered = Any[o for o in BMO.objects(parent) if _has(objs, o)]
    s = BMO.ObjectGroup(ordered)
    pivot = sum(o -> Vector{Float64}(position(o)), ordered) ./ length(ordered)
    BMO.set_pivot3d!(s, pivot)
    poses = IdDict{Any, Tuple{Point3{Float64}, Matrix{Float64}}}()
    foreach(o -> (poses[o] = _pose(o)), ordered)
    rec = _WindowGroup(ordered, pivot, poses)
    bottom = Any[]
    for o in BMO.objects(parent)
        o === first(ordered) ? push!(bottom, s) : (_has(ordered, o) || push!(bottom, o))
    end
    label = Ref{Any}(nothing)
    function inner!(forward::Bool)
        if forward
            _do_group!(gui, s, rec; label = label[])
        else
            label[] = get(gui.labels, s, nothing)
            _do_ungroup!(gui, s)
        end
        return nothing
    end
    function done(news)
        ctrl = gui.controls
        if !ctrl.spectator[]
            ctrl.selected[] = s
            _update_selection_box!(ctrl)
        end
        gui.status.text[] = "$(length(ordered)) objects grouped as $(_label(gui, s)) in $(_label(gui, first(news)))"
        return nothing
    end
    _remake!(gui, _group_chain(gui, parent), bottom, inner!, done)
    return s
end

# The record of the group of the script `p`, with which `_do_group!` groups it again, see `_remake!`
function _script_record(@nospecialize(p))
    members = collect(Any, BMO.objects(p))
    poses = IdDict{Any, Tuple{Point3{Float64}, Matrix{Float64}}}()
    foreach(o -> (poses[o] = _pose(o)), members)
    return _WindowGroup(members, Vector{Float64}(position(p)), poses)
end

"""
    _remake!(gui, chain, bottom, inner!, done) -> Vector{Any}

Makes the groups `chain` of the `gui` (from the top-level one down, see `_group_chain`) anew, since
an `ObjectGroup` does not change its objects: the one at the bottom with the objects `bottom`, each
one above with the new one below in place of the old one. Each new group has the name, label and
pivot of the old one and the axes of the world, like a group made with `Ctrl+G`, and is a group made
in the window, also for a group of the script, which it `replaces` (see `_WindowGroup`).

The old groups are ungrouped from the top down, then `inner!(true)` changes the objects below the
bottom one (it dissolves a group or makes one of parts, see `_dissolve!` and `_subgroup!`), then the
new groups are grouped from the bottom up and `done(news)` runs, e.g. selects. One action of the
undo history: undo ungroups the new groups, calls `inner!(false)` and groups the old ones again, a
group of the script as such (see `_do_group!`) with its initial pose and constraint; redo makes the
same new groups again. Returns the new groups from the bottom up.
"""
function _remake!(gui, chain::Vector{Any}, bottom::Vector{Any}, inner!, done)
    ctrl = gui.controls
    comp = gui.components
    m = length(chain)
    script = Bool[!_is_window_group(gui, p) for p in chain]
    # what ungrouping forgets of the old groups: the records of those made in the window, the
    # initial poses and constraints of those of the script
    old_recs = _WindowGroup[script[i] ? _script_record(chain[i]) : comp.groups[chain[i]] for i in 1:m]
    kept = Any[(get(ctrl.init_poses, p, nothing), get(ctrl.constraints, p, nothing)) for p in chain]
    old_labels = Any[get(gui.labels, p, nothing) for p in chain]
    # the new groups from the bottom up
    news = Any[]
    new_recs = _WindowGroup[]
    for i in m:-1:1
        p = chain[i]
        members = i == m ? bottom : Any[o === chain[i + 1] ? last(news) : o for o in BMO.objects(p)]
        n = BMO.ObjectGroup(members)
        pivot = Vector{Float64}(position(p))
        BMO.set_pivot3d!(n, pivot)
        poses = IdDict{Any, Tuple{Point3{Float64}, Matrix{Float64}}}()
        foreach(o -> (poses[o] = _pose(o)), members)
        push!(news, n)
        push!(new_recs, _WindowGroup(members, pivot, poses, script[i] ? p : old_recs[i].replaces))
        haskey(gui.objects.names, p) && (gui.objects.names[n] = gui.objects.names[p])
    end
    # the labels, taken when the groups are ungrouped, given back when they are grouped
    new_labels = Any[old_labels[m - k + 1] for k in 1:m]
    function forward()
        for i in 1:m
            old_labels[i] = get(gui.labels, chain[i], nothing)
            _do_ungroup!(gui, chain[i]; check = false)
        end
        inner!(true)
        for k in 1:m
            _do_group!(gui, news[k], new_recs[k]; label = new_labels[k], check = false)
        end
        done(news)
        return nothing
    end
    function backward()
        for k in m:-1:1
            new_labels[k] = get(gui.labels, news[k], nothing)
            _do_ungroup!(gui, news[k]; check = false)
        end
        inner!(false)
        for i in m:-1:1
            p = chain[i]
            _do_group!(gui, p, old_recs[i]; label = old_labels[i], check = false, script = script[i])
            script[i] || continue
            init, constraint = kept[i]
            isnothing(init) || (ctrl.init_poses[p] = init)
            isnothing(constraint) || (ctrl.constraints[p] = constraint)
        end
        return nothing
    end
    _unrecorded(forward, gui)
    comp.recording &&
        _push_action!(ctrl, last(news), () -> _unrecorded(backward, gui), () -> _unrecorded(forward, gui))
    return news
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
    _do_group!(gui, g, rec; label = nothing, check = true, script = false)

The group `g` of the members of `rec` (a `_WindowGroup`) takes their place in the `gui`: in their
systems (or among the objects without a system), in the view (see `_show_group!`) and in the linked
views, with the `label`; `g` is selected and the systems are solved. Throws an `ArgumentError` with
the `_group_reason` if the members can not be grouped, e.g. by an entry of the undo history that no
longer applies; without `check` for the groups that `_remake!` makes anew, which may have a single
member. A group of the `script` is shown again as such, see `_show_group!`.
"""
function _do_group!(gui, @nospecialize(g), rec::_WindowGroup; label = nothing, check::Bool = true,
        script::Bool = false)
    ctrl = gui.controls
    members = rec.members
    if check
        reason = length(members) < 2 ? "a group needs several objects" :
                 _group_reason(gui, _MultiSelection(members))
        isnothing(reason) || throw(ArgumentError(reason))
    end
    systems = _member_systems(gui, first(members))
    # Stops a solve in the background, which traces the objects of the systems
    _change!(ctrl, nothing) do
        for sys in systems
            foreach(m -> delete!(sys, m), members)
            push!(sys, g)
        end
    end
    _show_group!(gui, g, rec, systems; label, script)
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
    _do_ungroup!(gui, g; check = true)

The members of the group `g` made in the window take its place in the `gui`, at their current
poses: in its systems (or among the objects without a system), in the view (see `_unshow_group!`)
and in the linked views; those that are not hidden are selected and the systems are solved. Throws
an `ArgumentError` with the reason if `g` can not be ungrouped, see `_ungroup!`; without `check`
also a group of the script, for `_remake!`. A `g` that is part of another group is never ungrouped
here.
"""
function _do_ungroup!(gui, @nospecialize(g); check::Bool = true)
    ctrl = gui.controls
    if check
        reason = _ungroup_reason(gui, g)
        isnothing(reason) || throw(ArgumentError(reason))
    end
    # a group inside another one is dissolved into it by making that one again, see `_dissolve!`
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
`_record_units`. A group of the `script` that `_remake!` groups again is neither recorded in
`gui.components.groups` nor as added: it is an object of the script again. Also for a view that
follows a linked one, see `_follow_groups!`.
"""
function _show_group!(gui, @nospecialize(g), rec::_WindowGroup, systems; label = nothing,
        script::Bool = false)
    state = _kept_state(gui, rec.members)
    foreach(m -> _unshow!(gui, m), rec.members)
    # before `_attach!`, which would name them anew
    _restore_kept_names!(gui, state)
    script || (gui.components.groups[g] = rec)
    targets = isempty(systems) ? Any[nothing] : collect(Any, systems)
    for (k, sys) in enumerate(targets)
        _attach!(gui, g, sys; label = k == 1 ? label : nothing, record = false)
    end
    if !script
        # `g` is added like a component without code, its members keep what is recorded of them
        comp = gui.components
        _has(comp.added, g) || push!(comp.added, g)
        comp.origin[g] = nothing
        comp.system[g] = first(targets)
    end
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
