#=
Selections of several objects: moved, rotated, hidden and removed as one, see `_MultiSelection`
=#

"""
    _MultiSelection(objects)

The selection of several `objects` of the controls, e.g. after `Ctrl`+click (`Cmd` on macOS) in the 3D view or in
the object tree: `ctrl.selected[]` holds it instead of a single object. The controls move and
rotate it like one object, about `pos`, the mean of the positions of the `objects` when it was
made, in the frame `dir`, the axes of the world when it was made: translating it translates all
`objects`, rotating it rotates all of them about `pos`. It has neither a card of its own type nor a
system; the parts of the GUI that show it list its `objects`, see `_selection_objects`.

A selection of other objects is a new value, `objects` does not change, such that an entry of the
undo history that moved it (see `_push_history!`) moves the same objects again. Its objects are at
least two, no clip plane, and none of them is a part of another one, see `_with_toggled`.
"""
mutable struct _MultiSelection
    objects::Vector{Any}
    pos::Point3{Float64}
    dir::Matrix{Float64}
end

function _MultiSelection(objects)
    objs = collect(Any, objects)
    length(objs) >= 2 || throw(ArgumentError("a selection of several objects needs at least two, got $(length(objs))"))
    pos = Point3{Float64}(sum(o -> Vector{Float64}(position(o)), objs) ./ length(objs))
    return _MultiSelection(objs, pos, Matrix{Float64}(I, 3, 3))
end

function Base.show(io::IO, s::_MultiSelection)
    print(io, "_MultiSelection(", length(s.objects), " objects)")
end

BMO.kinematic_trait_of(::_MultiSelection) = BMO.Movable(BMO.Oriented())
Base.position(s::_MultiSelection) = s.pos
BMO.orientation(s::_MultiSelection) = s.dir

function BMO.translate3d!(::BMO.Movable, s::_MultiSelection, offset)
    for obj in s.objects
        translate3d!(obj, offset)
    end
    s.pos = s.pos + Point3{Float64}(collect(offset))
    return nothing
end

function BMO.rotate3d!(::BMO.Movable, s::_MultiSelection, R::AbstractMatrix)
    pivot = Vector{Float64}(s.pos)
    for obj in s.objects
        rotate3d!(obj, R, pivot)
    end
    # the nearest orthonormal frame, such that the rounding errors of many steps of a drag do not
    # add up, see `_axis_angle_from_rotmatrix`
    F = svd(Matrix{Float64}(R * s.dir))
    s.dir = F.U * F.Vt
    return nothing
end

"""
    _selection_objects(sel) -> Vector{Any}

The objects of the selection `sel` of the controls (`ctrl.selected[]`): none for `nothing`, the
`objects` of a `_MultiSelection`, else `[sel]`.
"""
_selection_objects(::Nothing) = Any[]
_selection_objects(s::_MultiSelection) = copy(s.objects)
_selection_objects(@nospecialize(sel)) = Any[sel]

"""Returns whether `obj` is one of the objects of the selection `sel`, see `_selection_objects`."""
_in_selection(@nospecialize(sel), @nospecialize(obj)) = _has(_selection_objects(sel), obj)

"""Returns whether `sel` is a selection of several objects, see `_MultiSelection`."""
_is_multi(@nospecialize(sel)) = false
_is_multi(::_MultiSelection) = true

"""
Returns whether `obj` can be one of the objects of a selection of several: clip planes can not,
they are selected on their own.
"""
_multi_selectable(@nospecialize(obj)) = true

"""
    _selection_of(objs)

The value of `ctrl.selected[]` that selects the objects `objs`: `nothing` for none, the object for
one, else a `_MultiSelection` of them.
"""
function _selection_of(objs)
    isempty(objs) && return nothing
    length(objs) == 1 && return only(objs)
    return _MultiSelection(objs)
end

"""Returns whether one of the objects `a` and `b` is a part of the other one (or both are the same)."""
_related(@nospecialize(a), @nospecialize(b)) = _has(_descendants(a), b) || _has(_descendants(b), a)

"""
    _with_toggled(sel, obj)

The selection after `obj` was added to the selection `sel` of the controls, or removed from it if
it is one of its objects (see `_selection_objects`); see `_selection_of` for the value. An object
that `obj` is a part of, or that is a part of `obj`, is replaced by `obj`, e.g. a group by one of
its lenses, such that no object is moved twice. A clip plane is selected on its own, and is
dropped from `sel` when another object is added.
"""
function _with_toggled(@nospecialize(sel), @nospecialize(obj))
    _multi_selectable(obj) || return obj
    objs = Any[]
    found = false
    for o in _selection_objects(sel)
        _multi_selectable(o) || continue
        if o === obj
            found = true
        elseif !_related(o, obj)
            push!(objs, o)
        end
    end
    found || push!(objs, obj)
    return _selection_of(objs)
end

"""
    _without(sel, objs)

The selection `sel` of the controls without the objects `objs` and without the objects that are a
part of one of them, e.g. after they were removed from the view; `sel` itself if it holds none of
them.
"""
function _without(@nospecialize(sel), objs)
    kept = Any[]
    for o in _selection_objects(sel)
        dropped = false
        for x in objs
            (o === x || _has(_descendants(x), o)) && (dropped = true; break)
        end
        dropped || push!(kept, o)
    end
    length(kept) == length(_selection_objects(sel)) && return sel
    return _selection_of(kept)
end

# The rendered objects of a selection of several, e.g. its plots and its selection box, see
# `_object_plots`
function _leaves(s::_MultiSelection)
    leaves = _LiveMovable[]
    for obj in s.objects
        append!(leaves, _leaves(obj))
    end
    return leaves
end

# `_is_movable`, `_allowed_axes` and the snapping of a selection of several are in
# `LiveInteraction.jl`, its name (`_label`) in `LiveSelection.jl`, beside the methods for one object

"""
    _toggle_select!(gui, obj)

Adds the movable `obj` to the selection of the `gui` or removes it from it, like `Ctrl`+click in
the 3D view, see `_with_toggled`, and shows the pose of the selection in the status line. Nothing is
selected in the spectator mode; while the members of a system are picked, `obj` is picked instead,
see `_select!`.
"""
function _toggle_select!(gui, @nospecialize(obj))
    ctrl = gui.controls
    _pick_shown!(gui, obj) && return nothing
    if ctrl.spectator[]
        gui.status.text[] = "spectator mode, press v to select components"
        return nothing
    end
    sel = _with_toggled(ctrl.selected[], obj)
    ctrl.selected[] === sel || (ctrl.selected[] = sel)
    _update_selection_box!(ctrl)
    isnothing(sel) || (gui.status.text[] = _pose_string(gui, sel))
    return nothing
end
