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
function _set_pose_exact!(obj, P, R)
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

"""
    _export_names(gui, objects)

Returns the variable names of the `objects` in the code of `export_changes`: the label of an
object if it is a valid, unique variable name, otherwise `obj1`, `obj2`, … by the position `k`
of the object in `objects`, i.e. in the component menu.
"""
function _export_names(gui::LiveView, objects)
    names = IdDict{Any, String}()
    used = Set{String}()
    for (k, obj) in enumerate(objects)
        label = get(gui.labels, obj, "")
        name = _is_variable_name(label) && !(label in used) ? label : "obj$k"
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
of a system if it is a valid variable name that is not among the `used` names (of the objects),
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
        name = _is_variable_name(label) && !(label in used) ? label : several ? "system$i" : "system"
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
    _export_code(gui) -> (code, n)

Returns the Julia code of `export_changes` and the number `n` of changes: the components that were
removed from and added to the systems at runtime (see `remove_component!` and `add_component!`),
each in the order of the calls, then the changed poses of the other objects in the order of the
component menu, see `_export_pose_lines!`.

A removed component is a `delete!` from its system (see `_export_system_names`), or a comment if
its label is no variable name. An added component is its constructor call (the `code` of its
`origin`, see `_ComponentState`; without one, a comment that it is to be constructed there), a
`push!` to its system and its change of pose since it was constructed (without `origin`: since it
was added); together they count as one change.
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
        type = string(nameof(typeof(obj)))
        label = _label(gui, obj)
        system = systems[comp.system[obj]]
        push!(lines, "", "# $label ($type), removed")
        named = haskey(gui.labels, obj) && _is_variable_name(label) && !(label in used)
        push!(lines, named ? "delete!($system, $label)" :
            "# delete!($system, …) with the variable of $label")
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
        push!(lines, "push!($(systems[comp.system[obj]]), $name)")
        base = isnothing(origin) ? nothing : origin.pose0
        n += 1 + _export_pose_lines!(lines, gui, names, obj; base, heading = false)
    end
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
of the catalog, see [`component_catalog`](@ref); otherwise a comment marks where to construct it),
a `push!(system, name)` and the `rotate3d!` and `translate_to3d!` from its pose as constructed
(otherwise: from its pose when it was added) to its current pose. The system is named after its
label if that is a valid variable name, otherwise `system`, or `system1`, `system2`, … if the view
shows several systems.

The variables are named after the `labels` of [`live_view`](@ref) if they are valid variable names,
otherwise `obj1`, `obj2`, … by the position of the object in the component menu. A comment above
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

