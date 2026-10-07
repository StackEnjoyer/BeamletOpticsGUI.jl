#=
Aligning a component to the beams from its card: onto the nearest beam (`_center_on_beam!`) and
with its optical axis along it (`_face_beam!`), see `_component_row`
=#

"""
    _nearest_line(lines, point) -> Union{Nothing, NamedTuple}

Of the `lines` (see `_snap_lines`) the one closest to the `point` [m] in space, as
`(; point, direction, distance)`: its point closest to the `point`, its direction and their
distance [m]. `nothing` without lines.
"""
function _nearest_line(lines, point)
    p = Vector{Float64}(point)
    best = nothing
    for line in lines
        u = line.b .- line.a
        uu = dot(u, u)
        s = uu > 0 ? clamp(dot(p .- line.a, u) / uu, 0.0, 1.0) : 0.0
        q = line.a .+ s .* u
        d = norm(p .- q)
        (isnothing(best) || d < best.distance) &&
            (best = (; point = q, direction = line.direction, distance = d))
    end
    return best
end

"""
    _align_line(gui, obj) -> Union{Nothing, NamedTuple}

The beam that the component `obj` of the `gui` is aligned to: of the central beams that are switched
on, as far as they do not depend on `obj` (see `_snap_lines`), the one closest to its position, see
`_nearest_line`. `nothing` with the reason in the status line: for an object that is not movable,
while a solve in the background traces the beams, and without a beam.
"""
function _align_line(gui::LiveView, @nospecialize(obj))
    name = _label(gui, obj)
    if !_is_movable(gui.controls, obj)
        gui.status.text[] = "$name is not movable, it can not be aligned"
        return nothing
    end
    if _running(gui)
        gui.status.text[] = "the beams are being traced, align $name afterwards"
        return nothing
    end
    line = _nearest_line(_snap_lines(gui, obj), position(obj))
    isnothing(line) && (gui.status.text[] = "no beam to align $name to")
    return line
end

"""
    _commit_pose!(gui, obj, P0, R0)

Finishes a change of the pose of `obj` of the `gui` from `(P0, R0)` that an action made, e.g. of its
card: records it in the undo history as one gesture, renders the objects, moves the box of the
selection and solves like after a move, see `_on_moved!`. Unlike `_request_update!` of the
controls, also for an object that is not selected, e.g. on a pinned card.
"""
function _commit_pose!(gui::LiveView, @nospecialize(obj), P0, R0)
    ctrl = gui.controls
    P1, R1 = _pose(obj)
    ctrl.last_key_step = nothing
    _push_history!(ctrl, obj, P0, R0, P1, R1)
    update_render!(ctrl.h)
    _update_debug!(gui)
    _update_selection_box!(ctrl)
    ctrl.on_change(obj)
    return nothing
end

"""
    _center_on_beam!(gui, obj) -> Bool

Moves the component `obj` of the `gui` onto the nearest beam (see `_align_line`): to the point of
the beam closest to its position, along the axes that its constraints allow. One gesture of the undo
history. Returns whether it moved; otherwise the status line tells why not.
"""
function _center_on_beam!(gui::LiveView, @nospecialize(obj))
    ctrl = gui.controls
    line = _align_line(gui, obj)
    isnothing(line) && return false
    name = _label(gui, obj)
    allowed = _allowed_axes(ctrl, obj, :move)
    if isempty(allowed)
        gui.status.text[] = "$name can not move, see the constraints"
        return false
    end
    P0, R0 = _pose(obj)
    A = hcat(_axis_vectors(ctrl, obj, allowed)...)
    Δ = A * (pinv(A) * (line.point .- Vector{Float64}(P0)))
    if norm(Δ) < 1e-12
        gui.status.text[] = "$name is on the beam already"
        return false
    end
    _change!(() -> translate3d!(obj, Δ), ctrl, obj)
    _commit_pose!(gui, obj, P0, R0)
    gui.status.text[] = "$name moved onto the beam, by $(_length_string(norm(Δ)))"
    return true
end

"""
    _face_beam!(gui, obj) -> Bool

Turns the component `obj` of the `gui` such that its optical axis (the local y-axis) points along
the nearest beam (see `_align_line`), in its direction or against it, whichever is closer, e.g. a
lens straight in the beam or a mirror that sends it back. Its position is kept. One gesture of the
undo history. Returns whether it turned; otherwise the status line tells why not, e.g. for an
object whose rotation is constrained.
"""
function _face_beam!(gui::LiveView, @nospecialize(obj))
    ctrl = gui.controls
    line = _align_line(gui, obj)
    isnothing(line) && return false
    name = _label(gui, obj)
    if Set(_allowed_axes(ctrl, obj, :rotate)) != Set(_GIZMO_AXES)
        gui.status.text[] = "$name can not rotate freely, see the constraints"
        return false
    end
    P0, R0 = _pose(obj)
    y = R0[:, 2]
    d = Vector{Float64}(line.direction)
    dot(y, d) < 0 && (d = -d)
    R = _align_rotation(y, d, ctrl.rotation_axis) * R0
    angle = acos(clamp(dot(normalize(y), normalize(d)), -1, 1))
    if angle < 1e-12
        gui.status.text[] = "$name faces the beam already"
        return false
    end
    _change!(() -> _set_pose!(obj, P0, R), ctrl, obj)
    _commit_pose!(gui, obj, P0, R0)
    gui.status.text[] = "$name faces the beam, turned by $(_angle_string(angle))"
    return true
end

"""
The last row of the card of a component, below its other rows (see `_card_rows`): "onto beam" and
"face beam" align it to the nearest beam (see `_center_on_beam!` and `_face_beam!`), "remove"
removes it from the view, see `_remove_selected!`.
"""
_component_row() = CardRow(
    CardWidget(Button; name = :center, label = "onto beam", on = (gui, o, _) -> _center_on_beam!(gui, o)),
    CardWidget(Button; name = :face, label = "face beam", on = (gui, o, _) -> _face_beam!(gui, o)),
    _remove_button())
