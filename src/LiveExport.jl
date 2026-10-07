#=
Export of the changed poses
=#

"""
    _rotation_axis_angle(R)

Returns the `axis` and `angle` of the rotation matrix `R` such that `rotate3d(axis, angle) ≈ R`.
Unlike `_axis_angle_from_rotmatrix`, which is based on the trace of `R`, it is accurate to the
precision of `Float64` for all angles, including small ones.
"""
function _rotation_axis_angle(R::AbstractMatrix)
    # sin(angle) * axis
    v = [R[3, 2] - R[2, 3], R[1, 3] - R[3, 1], R[2, 1] - R[1, 2]] ./ 2
    s, c = norm(v), (tr(R) - 1) / 2
    angle = atan(s, c)
    iszero(s) && c > 0 && return [0.0, 0.0, 1.0], 0.0
    c > -0.5 && return v ./ s, angle
    # Close to π, where sin(angle) is inaccurate: (R + R') / 2 = c I + (1 - c) axis axis'
    B = (R + R') ./ 2 - c * I
    axis = normalize(B[:, argmax(diag(B))])
    dot(axis, v) < 0 && (axis = -axis)
    return axis, angle
end

"""Sets the pose of `obj` like `_set_pose!`, but with the accurate `_rotation_axis_angle`."""
function _set_pose_exact!(@nospecialize(obj), P, R)
    axis, angle = _rotation_axis_angle(R * _pose(obj)[2]')
    angle > 0 && rotate3d!(obj, axis, angle)
    translate_to3d!(obj, P)
    return nothing
end

"""Returns `true` if `s` can be used as the name of a variable."""
_is_variable_name(s) = Base.isidentifier(s) && try
    Meta.parse(s) isa Symbol
catch
    false
end

# The names of Base that the exported code calls
const _CODE_BASE_NAMES = ("Dict", "push!", "delete!")

"""
    _is_taken_name(s) -> Bool

Returns `true` if the exported code can not use `s` as the variable of an object, since it uses
the name otherwise: a name exported by BeamletOptics or this package, e.g. `Detector` or
`live_view`, a name of Base that it calls (`Dict`, `push!`, `delete!`), or one of its own variables,
`system`, `system1`, … and `gui`. Other names of Base, e.g. `first`, are free: the variable hides
the function of Base in the script, which does not call it.
"""
function _is_taken_name(s::AbstractString)
    (s == "gui" || occursin(r"^system\d*$", s) || s in _CODE_BASE_NAMES) && return true
    sym = Symbol(s)
    return Base.isexported(BMO, sym) || Base.isexported(@__MODULE__, sym)
end

"""
    _export_names(gui, objects)

Returns the variable names of the `objects` in the code of `export_changes`: the label of an
object if it is a valid, unique variable name that the code does not take otherwise (see
`_is_taken_name`), else the label in lowercase if that is one, e.g. `detector` for the label
`Detector`, otherwise `obj1`, `obj2`, … by the position `k` of the object in `objects`, i.e. in
the component menu.
"""
function _export_names(gui::LiveView, objects)
    names = IdDict{Any, String}()
    used = Set{String}()
    for (k, obj) in enumerate(objects)
        label = get(gui.labels, obj, "")
        candidates = (label, lowercase(label))
        i = findfirst(c -> _is_variable_name(c) && !_is_taken_name(c) && !(c in used), candidates)
        name = isnothing(i) ? "obj$k" : candidates[i]
        while name in used
            name *= "_"
        end
        push!(used, name)
        names[obj] = name
    end
    return names
end

"""Formats the vector `v` as Julia code with full precision."""
_vector_code(v) = "[" * join((repr(Float64(x)) for x in v), ", ") * "]"

"""
    _initial_copy(ctrl, group)

Returns a copy of the `group` in which the group and all its objects are reset to their initial
poses of the controls `ctrl`, from the outside in.
"""
function _initial_copy(ctrl::KinematicController, group)
    copy = deepcopy(group)
    for (obj, c) in zip(_descendants(group), _descendants(copy))
        haskey(ctrl.init_poses, obj) && _set_pose_exact!(c, ctrl.init_poses[obj]...)
    end
    return copy
end

"""
    _export_system_names(gui, used) -> IdDict

Returns the variable names of the systems of the `gui` in the code of `export_changes`: the label
of a system if it is a valid variable name that is not among the `used` names (of the objects)
and not taken otherwise (see `_is_taken_name`),
otherwise `system`, or `system1`, `system2`, … by the position of the system if the view shows
several systems.
"""
function _export_system_names(gui::LiveView, used)
    names = IdDict{Any, String}()
    used = Set{String}(used)
    several = length(gui.system_handles) > 1
    for (i, h) in enumerate(gui.system_handles)
        sys = rendered(h)
        label = get(gui.labels, sys, "")
        free = _is_variable_name(label) && !_is_taken_name(label) && !(label in used)
        name = free ? label : several ? "system$i" : "system"
        while name in used
            name *= "_"
        end
        push!(used, name)
        names[sys] = name
    end
    return names
end

"""
    _export_pose_lines!(lines, gui, names, top; base = nothing, heading = true) -> n

Appends the changes of the poses of the top-level object `top` of the `gui` and of the objects of
its group to the `lines` of `export_changes` and returns the number `n` of changed objects. Since
moving a group moves its objects as well, the changes of a group and its objects are replayed on an
`_initial_copy` of the group, such that the change of each object of the group is relative to its
pose after the preceding lines.

The changes are relative to the initial poses of the controls, or, with `base`, to the pose `base`
of `top` (and the poses of the objects of its group in that pose of the group), e.g. the pose of an
added component as constructed. Without `heading`, the change of `top` itself gets no comment and
is not counted, see `_export_code`.
"""
function _export_pose_lines!(lines, gui::LiveView, names, top; base = nothing, heading::Bool = true)
    ctrl = gui.controls
    objs = _descendants(top)
    copies = top isa BMO.AbstractObjectGroup ? _descendants(_initial_copy(ctrl, top)) : nothing
    # The objects of a group follow the group back to the pose `base`
    isnothing(base) || isnothing(copies) || _set_pose_exact!(copies[1], base...)
    n = 0
    for (i, obj) in enumerate(objs)
        own = i == 1 && !isnothing(base)
        (own || haskey(ctrl.init_poses, obj)) || continue
        P, R = _pose(obj)
        P0, R0 = !isnothing(copies) ? _pose(copies[i]) : own ? base : ctrl.init_poses[obj]
        (norm(P - P0) > 1e-15 || norm(R - R0) > 1e-15) || continue
        axis, angle = _rotation_axis_angle(R * R0')
        name = names[obj]
        if heading || i > 1
            type = string(nameof(typeof(obj)))
            label = get(gui.labels, obj, nothing)
            push!(lines, "", isnothing(label) ? "# $type" : "# $label ($type)")
            n += 1
        end
        angle > 0 && push!(lines, "rotate3d!($name, $(_vector_code(axis)), $(repr(angle)))")
        push!(lines, "translate_to3d!($name, $(_vector_code(P)))")
        isnothing(copies) || _set_pose_exact!(copies[i], P, R)
    end
    return n
end

"""
    _export_removed_lines!(lines, gui, systems, used, obj)

Appends the lines of `export_changes` for `obj`, which the `gui` started with and which was removed
at runtime: a component is a `delete!` from its system (named by `systems`, see
`_export_system_names`), or a comment if its label is no variable name or one of the `used` names;
a source is a comment, since the script that traces it is not known.
"""
function _export_removed_lines!(lines, gui::LiveView, systems, used, @nospecialize(obj))
    comp = gui.components
    type = string(nameof(typeof(obj)))
    label = _label(gui, obj)
    push!(lines, "", "# $label ($type), removed")
    named = haskey(gui.labels, obj) && _is_variable_name(label) && !(label in used)
    # the systems that held it at the start, an object of several systems is deleted from each
    held = Any[s for s in get(comp.start_systems, obj, Any[get(comp.system, obj, nothing)])
               if haskey(systems, s)]
    isempty(held) && push!(lines, "# $label was in no system")
    for s in held
        push!(lines, named ? "delete!($(systems[s]), $label)" :
            "# delete!($(systems[s]), …) with the variable of $label")
    end
    return nothing
end

function _export_removed_lines!(lines, gui::LiveView, systems, used,
        src::Union{BMO.AbstractBeam, BMO.AbstractBeamGroup})
    type = string(nameof(typeof(src)))
    label = _label(gui, src)
    traced = join((systems[sys] for sys in gui.components.source_systems[src] if haskey(systems, sys)), ", ")
    push!(lines, "", "# $label ($type), removed",
        isempty(traced) ? "# $label was not traced" : "# do not trace $label through $traced any more")
    return nothing
end

"""
    _export_added_lines!(lines, gui, names, system, obj, base) -> n

Appends the lines of `export_changes` that follow the constructor of `obj`, which was added to the
`gui` at runtime, and returns the number `n` of changed objects of its group: a component is pushed
to its `system` (the name of its variable) and moved from its pose `base` as constructed to its
current pose, see `_export_pose_lines!`; a source is moved and then traced through the `system`.
"""
function _export_added_lines!(lines, gui::LiveView, names, systems, @nospecialize(obj), base)
    # an object of several systems is pushed to each, one without a system is not traced
    held = String[systems[s] for s in _member_systems(gui, obj) if haskey(systems, s)]
    isempty(held) && push!(lines, "# $(names[obj]) is in no system, i.e. not traced")
    foreach(system -> push!(lines, "push!($system, $(names[obj]))"), held)
    return _export_pose_lines!(lines, gui, names, obj; base, heading = false)
end

function _export_added_lines!(lines, gui::LiveView, names, systems,
        src::Union{BMO.AbstractBeam, BMO.AbstractBeamGroup}, base)
    n = _export_pose_lines!(lines, gui, names, src; base, heading = false)
    sys = _system_of_source(gui, src)
    push!(lines, haskey(systems, sys) ? "solve_system!($(systems[sys]), $(names[src]))" :
        "# $(names[src]) has no system, i.e. it is not traced")
    return n
end

"""
    _export_member_lines!(lines, gui, names, systems) -> n

Appends the lines of `export_changes` for the systems that were added to and removed from the `gui`
at runtime (see `add_system!` and `remove_system!`) and for the objects and sources that the view
started with and that changed their systems since (see `_add_member!` and `_set_source_system!`):
a `push!` to or a `delete!` from a system per object, a comment per source. Returns the number `n`
of changes.
"""
function _export_member_lines!(lines, gui::LiveView, names, systems)
    comp = gui.components
    n = 0
    shown = _systems(gui)
    for sys in shown
        _has(comp.systems0, sys) && continue
        push!(lines, "", "# $(_label(gui, sys)), added", "$(systems[sys]) = System()")
        n += 1
    end
    for sys in comp.systems0
        _has(shown, sys) && continue
        push!(lines, "", "# $(_label(gui, sys)), removed from the view")
        n += 1
    end
    tops = unique(objectid, Any[(obj for sys in shown for obj in sys.objects)..., rendered(gui.extras).objects...])
    for obj in tops
        (haskey(comp.start_systems, obj) && !_has(comp.added, obj)) || continue
        start = comp.start_systems[obj]
        now = _member_systems(gui, obj)
        joined = Any[s for s in now if !_has(start, s) && haskey(systems, s)]
        left = Any[s for s in start if !_has(now, s) && haskey(systems, s)]
        (isempty(joined) && isempty(left)) && continue
        label = _label(gui, obj)
        name = get(names, obj, nothing)
        push!(lines, "", "# $label ($(nameof(typeof(obj)))), systems changed")
        for (verb, list) in (("push!", joined), ("delete!", left)), s in list
            push!(lines, isnothing(name) ? "# $verb($(systems[s]), …) with the variable of $label" :
                "$verb($(systems[s]), $name)")
        end
        n += 1
    end
    for src in _sources(gui)
        (haskey(comp.start_systems, src) && !_has(comp.added, src)) || continue
        start = only(comp.start_systems[src])
        now = _system_of_source(gui, src)
        start === now && continue
        label = _label(gui, src)
        push!(lines, "", "# $label ($(nameof(typeof(src)))), system changed",
            haskey(systems, now) ? "# trace $label through $(systems[now]) instead" :
            "# do not trace $label any more, it has no system")
        n += 1
    end
    return n
end

"""
    _export_code(gui) -> (code, n)

Returns the Julia code of `export_changes` and the number `n` of changes: the components that were
removed from and added to the systems at runtime (see `remove_component!` and `add_component!`),
each in the order of the calls, then the changed poses of the other objects in the order of the
component menu, see `_export_pose_lines!`.

A removed component is a `delete!` from its system (see `_export_system_names`), or a comment if
its label is no variable name. An added component is its constructor call (the `code` of its
`origin`, see `_ComponentState`; without one, a comment that it is to be constructed there), a
`push!` to its system and its change of pose since it was constructed (without `origin`: since it
was added); together they count as one change. Sources are added and removed like components: a
removed source is a comment, an added one its constructor call, its change of pose and the
`solve_system!` that traces it, see `_export_removed_lines!` and `_export_added_lines!`.
"""
function _export_code(gui::LiveView)
    ctrl = gui.controls
    comp = gui.components
    entries = _menu_entries(ctrl)
    names = _export_names(gui, first.(entries))
    used = Set{String}(values(names))
    # Added components that the menu does not list, i.e. static ones
    for (k, obj) in enumerate(comp.added)
        haskey(names, obj) && continue
        label = get(gui.labels, obj, "")
        name = _is_variable_name(label) && !(label in used) ? label : "added$k"
        while name in used
            name *= "_"
        end
        push!(used, name)
        names[obj] = name
    end
    systems = _export_system_names(gui, used)
    lines = String[
        "# Changed poses of the live view, apply to the objects in their initial poses.",
        "# Each rotation is about the position of the object, groups are moved before their objects."]
    n = 0
    for obj in comp.removed
        _export_removed_lines!(lines, gui, systems, used, obj)
        n += 1
    end
    added = Base.IdSet{Any}(comp.added)
    for obj in comp.added
        type = string(nameof(typeof(obj)))
        label = get(gui.labels, obj, nothing)
        name = names[obj]
        origin = get(comp.origin, obj, nothing)
        push!(lines, "", (isnothing(label) ? "# $type" : "# $label ($type)") * ", added")
        push!(lines, isnothing(origin) ? "# construct `$name` here, in its pose when it was added" :
            "$name = $(origin.code)")
        base = isnothing(origin) ? nothing : origin.pose0
        n += 1 + _export_added_lines!(lines, gui, names, systems, obj, base)
    end
    n += _export_member_lines!(lines, gui, names, systems)
    for top in ctrl.movable
        (top isa LiveClipPlane || top in added) && continue
        n += _export_pose_lines!(lines, gui, names, top)
    end
    n == 0 && push!(lines, "", "# no changes")
    return join(lines, "\n") * "\n", n
end

"""Copies `code` to the clipboard, returns `false` if there is no clipboard, e.g. headless."""
function _copy_to_clipboard(code::String)
    try
        InteractiveUtils.clipboard(code)
        return true
    catch e
        e isa InterruptException && rethrow()
        return false
    end
end

"""
    export_changes(gui::LiveView; io = stdout, clipboard = false) -> String

Returns the changes of the poses in the `gui` as Julia code, which is printed to `io` and copied to
the clipboard if `clipboard` is `true` and a clipboard is available. The "Export" button of the
`gui` prints the code and copies it to the clipboard.

For each object whose pose differs from its initial pose, i.e. its pose when the window was
opened, the code contains a `rotate3d!` about the position of the object (skipped if the object
was only moved) followed by a `translate_to3d!` to its absolute position [m], with the full
precision of `Float64`. Applied to the objects in their initial poses, e.g. in the script that
created the system, the code reproduces the current poses. The objects of a group are listed after
the group, their changes are relative to the pose after moving the group. Clip planes are not
exported.

Components that were removed and added at runtime (see [`remove_component!`](@ref) and
[`add_component!`](@ref)) come first. A removed component is a `delete!(system, name)`, or a comment
if its label is no valid variable name. An added component is its constructor call (for a component
of the catalog, see [`component_catalog`](@ref), and for one added with its `code`, see
[`add_component!`](@ref); otherwise a comment marks where to construct it),
a `push!(system, name)` and the `rotate3d!` and `translate_to3d!` from its pose as constructed
(otherwise: from its pose when it was added) to its current pose. The system is named after its
label if that is a valid variable name, otherwise `system`, or `system1`, `system2`, … if the view
shows several systems. An added source is its constructor call, its `rotate3d!` and
`translate_to3d!` and the `solve_system!(system, name)` that traces it; a removed source that the
view started with is a comment, since the script that traces it is not known.

The variables are named after the `labels` of [`live_view`](@ref) if they are valid variable names
that the code does not use otherwise, i.e. no name exported by BeamletOptics or this package, such as
`Detector` or `live_view`, and not `system` or `gui`; then after the label in lowercase if that is
free, e.g. `detector`, otherwise `obj1`, `obj2`, … by the position of the object in the component menu. A comment above
each change names the label and the type of the object.

```julia
gui = live_view(system, beam; labels = Dict(m1 => "m1", lens => "lens"))
# move the objects, then
code = export_changes(gui)
```
"""
function export_changes(gui::LiveView; io::IO = stdout, clipboard::Bool = false)
    code, _ = _export_code(gui)
    print(io, code)
    clipboard && _copy_to_clipboard(code)
    return code
end

"""Prints the changed poses to `stdout` and copies them to the clipboard, see `export_changes`."""
function _export!(gui::LiveView)
    code, n = _export_code(gui)
    print(stdout, code)
    copied = gui.export_clipboard && _copy_to_clipboard(code)
    gui.status.text[] = "exported $n change$(n == 1 ? "" : "s")" * (copied ? " (copied)" : "")
    return nothing
end

#=
Export of the whole setup as a script
=#

# The comment line that starts the section of the script of `export_script` that opens the view
const _SCRIPT_VIEW_HEADING = "# Live view"

"""
    _export_script_names(gui, tops) -> IdDict

Returns the variable names of the top-level objects and sources `tops` of the `gui` and of the
objects of their groups in the code of `export_script`, see `_export_names`: `obj1`, `obj2`, … count
the `tops` first, then the objects of their groups. The objects of a group whose constructor is
known (see the `origin` of `_ComponentState`) are no variables of the script; they are named by
their place in the group, e.g. `BeamletOptics.shape(pair)[1]`.
"""
function _export_script_names(gui::LiveView, tops)
    seen = Base.IdSet{Any}(tops)
    all = Any[tops...]
    for top in tops, obj in _descendants(top)
        obj in seen && continue
        push!(seen, obj)
        push!(all, obj)
    end
    names = _export_names(gui, all)
    function name_children!(obj)
        for (i, c) in enumerate(_children(obj))
            names[c] = "BeamletOptics.shape($(names[obj]))[$i]"
            name_children!(c)
        end
        return nothing
    end
    for top in tops
        isnothing(get(gui.components.origin, top, nothing)) || name_children!(top)
    end
    return names
end

"""Turns the `line` of code into a comment; empty lines and comments are kept."""
_commented(line::AbstractString) = isempty(line) || startswith(line, "#") ? String(line) : "# " * line

"""
    _export_construct_lines!(lines, gui, names, obj) -> Bool

Appends the lines of `export_script` that construct the top-level object or source `obj` of the
`gui` in its current pose, and returns whether the script defines its variable.

With an `origin` (see `_ComponentState`) these are its constructor call and the change of its pose
since it was constructed, see `_export_pose_lines!`. Without one, the constructor is not known: a
comment with its type and position marks where to construct it, and the change of its pose since
the view got it is commented out.
"""
function _export_construct_lines!(lines, gui::LiveView, names, @nospecialize(obj))
    type = string(nameof(typeof(obj)))
    label = get(gui.labels, obj, nothing)
    name = names[obj]
    origin = get(gui.components.origin, obj, nothing)
    push!(lines, "")
    if isnothing(origin)
        push!(lines, "# $name = … ($type) at $(_vector_code(_pose(obj)[1])), construct it here")
        pose = String[]
        _export_pose_lines!(pose, gui, names, obj; heading = false)
        append!(lines, (_commented(line) for line in pose))
        return false
    end
    push!(lines, isnothing(label) ? "# $type" : "# $label ($type)")
    push!(lines, "$name = $(origin.code)")
    _export_pose_lines!(lines, gui, names, obj; base = origin.pose0, heading = false)
    return true
end

"""
    _export_view_lines!(lines, args, labels)

Appends the call of `live_view` to the `lines` of `export_script`. `args` and `labels` are pairs
`code => active` of its arguments and of the entries of its `labels`; those that are not active,
since the script does not define their variables, are commented out. Without an active argument the
whole call is commented out.
"""
function _export_view_lines!(lines, args, labels)
    call = String["gui = live_view("]
    last_active = findlast(last, args)
    for (i, (code, active)) in enumerate(args)
        tail = i != last_active ? "," : isempty(labels) ? "" : ";"
        push!(call, active ? "    $code$tail" : "    # $code,")
    end
    if !isempty(labels)
        push!(call, "    labels = Dict(")
        append!(call, (active ? "        $code," : "        # $code," for (code, active) in labels))
        push!(call, "    )")
    end
    push!(call, ")")
    append!(lines, isnothing(last_active) ? (_commented(line) for line in call) : call)
    return nothing
end

"""
    _export_script_code(gui) -> String

Returns the Julia code of `export_script`: the objects of each system of the `gui` (see
`_export_construct_lines!`) and the system, the sources, a `solve_system!` per pair of the view,
and, after the line `_SCRIPT_VIEW_HEADING`, the call of `live_view`, see `_export_view_lines!`.

The lines that use a variable which the script does not define are commented out: an object without
a known constructor is added to its `System` by a `push!` in a comment, a system of another type
with such an object is a comment as a whole, and so are the `solve_system!`, the arguments and the
labels of `live_view` with it.
"""
function _export_script_code(gui::LiveView)
    systems = _systems(gui)
    sources = _sources(gui)
    # The components that were added without a system or taken out of their last one; the extras
    # of the `extras` kwarg are not part of the script
    start = gui.components.start_systems
    free = Any[obj for obj in rendered(gui.extras).objects if !isempty(get(start, obj, Any[nothing]))]
    tops = unique(objectid, Any[(obj for sys in systems for obj in sys.objects)..., free..., sources...])
    names = _export_script_names(gui, tops)
    system_names = _export_system_names(gui, Set{String}(values(names)))
    defined = Base.IdSet{Any}()
    done = Base.IdSet{Any}()
    lines = String[
        "# Script of the live view: its systems, its sources and the view itself.",
        "# An object without a known constructor is a comment: construct it there, in its pose when",
        "# the view got it, and uncomment the lines that use it.",
        "using BeamletOptics"]
    for sys in systems
        name = system_names[sys]
        members, pending = String[], String[]
        for obj in sys.objects
            if !(obj in done)
                push!(done, obj)
                _export_construct_lines!(lines, gui, names, obj) && push!(defined, obj)
            end
            push!(obj in defined ? members : pending, names[obj])
        end
        type = string(nameof(typeof(sys)))
        push!(lines, "")
        if sys isa BMO.System
            push!(lines, isempty(members) ? "$name = $type()" : "$name = $type([$(join(members, ", "))])")
            append!(lines, ("# push!($name, $m)" for m in pending))
            push!(defined, sys)
        elseif isempty(pending) && !isempty(members)
            push!(lines, "$name = $type([$(join(members, ", "))])")
            push!(defined, sys)
        else
            # objects can not be added to it afterwards
            push!(lines, "# $name = $type([$(join((names[obj] for obj in sys.objects), ", "))])")
        end
    end
    for obj in free
        _export_construct_lines!(lines, gui, names, obj) && push!(defined, obj)
    end
    for src in sources
        _export_construct_lines!(lines, gui, names, src) && push!(defined, src)
    end
    # A source without a system is not traced
    traced = Pair{BMO.AbstractSystem, Any}[p for p in gui.pairs if !(p.second in gui.beams.unassigned)]
    isempty(traced) || push!(lines, "")
    for (sys, src) in traced
        line = "solve_system!($(system_names[sys]), $(names[src]))"
        push!(lines, sys in defined && src in defined ? line : _commented(line))
    end

    push!(lines, "", _SCRIPT_VIEW_HEADING, "using BeamletOpticsGUI, GLMakie")
    args = Pair{String, Bool}[]
    for sys in systems
        name = system_names[sys]
        mine = Any[p.second for p in traced if p.first === sys]
        for src in mine
            push!(args, "$name => $(names[src])" => sys in defined && src in defined)
        end
        # A system without a source, or whose sources the script does not define, is shown alone
        any(src -> src in defined, mine) || push!(args, name => sys in defined)
    end
    labels = Pair{String, Bool}[]
    for sys in systems
        haskey(gui.labels, sys) &&
            push!(labels, "$(system_names[sys]) => $(repr(gui.labels[sys]))" => sys in defined)
    end
    for top in tops, obj in _descendants(top)
        haskey(gui.labels, obj) &&
            push!(labels, "$(names[obj]) => $(repr(gui.labels[obj]))" => top in defined)
    end
    unique!(first, labels)
    _export_view_lines!(lines, args, labels)
    # What belongs to no system is added to the view afterwards: it is shown, but not traced
    loose = Any[free..., (src for src in sources if src in gui.beams.unassigned)...]
    isempty(loose) || push!(lines, "")
    for obj in loose
        line = "add_component!(gui, $(names[obj]); system = :none)"
        push!(lines, obj in defined ? line : _commented(line))
    end
    return join(lines, "\n") * "\n"
end

"""
    export_script(gui::LiveView; io = stdout, clipboard = false) -> String

Returns the setup of the `gui` as a complete Julia script, which is printed to `io` and copied to
the clipboard if `clipboard` is `true` and a clipboard is available. The "Script" button of the
`gui` prints the script and copies it to the clipboard. Unlike [`export_changes`](@ref), which
lists the changes to apply in the script that created the view, the script stands on its own.

The script consists of, in this order:

1. `using BeamletOptics`
2. per system its top-level objects, then the system itself, e.g. `system = System([lens, m1])`
3. the sources
4. a `solve_system!(system, source)` per pair of the view
5. after the comment line `# Live view`: `using BeamletOpticsGUI, GLMakie` and the call
   `gui = live_view(…)` with the pairs `system => source`, the systems without a source and the
   `labels`. The lines above it run without a window.

An object or source of the catalog (see [`component_catalog`](@ref)), or one that was added with
its `code` (see [`add_component!`](@ref)), is its constructor call
followed by the `rotate3d!` about its position and the `translate_to3d!` from its pose as
constructed to its current pose, with the full precision of `Float64`. The constructor of any other object, e.g. of one that the view started
with, is not known: a comment with its variable, type and position [m] marks where to construct it,
in its pose when the view got it, and the lines that use its variable are commented out (the change
of its pose since then, its `push!` to its system, its `solve_system!`, its entries in `live_view`).
A `StaticSystem` with such an object is a comment as a whole.

The variables are named after the `labels` of [`live_view`](@ref) if they are valid variable names
that the code does not use otherwise, i.e. no name exported by BeamletOptics or this package, such as
`Detector` or `live_view`, and not `system` or `gui`; then after the label in lowercase if that is
free, e.g. `detector`, otherwise `obj1`, `obj2`, …, and the systems `system`, or `system1`, `system2`, … if the view shows
several. Components that were removed are not part of the script. Neither are the looks (colors,
opacity, hidden objects), the clip planes, the extras and the other keyword arguments of
`live_view`.

```julia
gui = live_view(System())
# add components and sources from the catalog, or with `add_component!(...; code)`, move them, then
code = export_script(gui)
```
"""
function export_script(gui::LiveView; io::IO = stdout, clipboard::Bool = false)
    code = _export_script_code(gui)
    print(io, code)
    clipboard && _copy_to_clipboard(code)
    return code
end

"""Prints the script of the `gui` to `stdout` and copies it to the clipboard, see `export_script`."""
function _export_script!(gui::LiveView)
    code = _export_script_code(gui)
    print(stdout, code)
    copied = gui.export_clipboard && _copy_to_clipboard(code)
    gui.status.text[] = "script exported" * (copied ? " (copied)" : "")
    return nothing
end

