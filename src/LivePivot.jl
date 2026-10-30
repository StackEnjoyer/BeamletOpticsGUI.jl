#=
The pivot of a group or a selection of several: the point about which it is rotated, shown as a
dot in the 3D view and set by numbers, by a click on one of its parts or by dragging the dot, see
`_set_pivot!`
=#

# Priority of the listeners of the dot and of the pick of the pivot: before the pick of members
# (205) and the controls (200), which would select what is clicked or move the camera; after the
# placement (210) and the cards (250), which cover the 3D view; `Esc` before its other meanings
const _PIVOT_PRIORITY = 207
const _PIVOT_KEY_PRIORITY = 219

# The radius [px] around the dot of the pivot in which a press drags it, see `_pivot_hit`
const _PIVOT_GRAB_RADIUS = 8.0

# The help of the dot, see `_connect_pivot!`
const _PIVOT_HELP = _HelpSection["Edit" => [_HelpEntry([:mouse => "drag"], "the dot of a pivot: move it")]]

"""Whether the selection `sel` has a pivot of its own that can be set: a group or a selection of several."""
_has_pivot(@nospecialize(sel)) = false
_has_pivot(::BMO.AbstractObjectGroup) = true
_has_pivot(::_MultiSelection) = true

"""The parts of the selection `sel` whose positions the pivot can be set to: of a group its parts at
all depths, of a selection of several its objects and their parts, see `_pick_pivot!`."""
_pivot_parts(@nospecialize(g::BMO.AbstractObjectGroup)) = _descendants(g)[2:end]
_pivot_parts(s::_MultiSelection) = _LiveMovable[d for o in s.objects for d in _descendants(o)]

"""
    _pivot_reason(gui, sel) -> Union{Nothing, String}

Why the pivot of the selection `sel` of the `gui` can not be set, for the status line, or `nothing`:
only groups and selections of several have one, and only of movable objects of the view.
"""
function _pivot_reason(gui::LiveView, @nospecialize(sel))
    isnothing(sel) && return "select a group or several objects to set their pivot"
    name = _label(gui, sel)
    _has_pivot(sel) || return "$name has no pivot of its own, only groups and selections of several have one"
    _is_static(sel) && return "$name is static, its pivot can not be changed"
    _is_movable(gui.controls, sel) || return "$name can not be moved, its pivot can not be changed"
    return nothing
end

#=
Setting the pivot
=#

"""
    _set_pivot!(gui, sel, p) -> Bool

Moves the pivot of the selection `sel` of the `gui`, a group or a selection of several, to the point
`p` [m] without moving any of its objects (`set_pivot3d!` of BeamletOptics for a group), as one
action of the undo history, see `_shift_pivot!`. The axes of `sel` stay as they are. What can not
be done only shows a message in the status line, see `_pivot_reason`. Returns whether it was done.
"""
function _set_pivot!(gui::LiveView, @nospecialize(sel), p)
    reason = _pivot_reason(gui, sel)
    if !isnothing(reason)
        gui.status.text[] = reason
        return false
    end
    P = Vector{Float64}(position(sel))
    δ = Matrix{Float64}(BMO.orientation(sel))' * (Vector{Float64}(p) .- P)
    norm(δ) > 1e-15 || return true
    _shift_pivot!(gui, sel, δ)
    _record_pivot!(gui, sel, δ)
    gui.status.text[] = "pivot of $(_label(gui, sel)) at $(_position_string(sel))"
    return true
end

"""
    _record_pivot!(gui, sel, δ)

Records the shift `δ` [m] of the pivot of the selection `sel` of the `gui` in its frame (see
`_shift_pivot!`) as one action of the undo history: undo shifts it back by `-δ` and redo by `δ`
again, and both select `sel`. The shift is in the frame of `sel`, such that it holds after `sel`
was moved, e.g. by a linked view. An action on a group that is no longer an object of the view is
dropped, see `_history_step!`.
"""
function _record_pivot!(gui::LiveView, @nospecialize(sel), δ)
    ctrl = gui.controls
    gui.components.recording || return nothing
    function step!(d)
        _is_movable(ctrl, sel) || throw(ArgumentError("$(_label(gui, sel)) is no longer an object of the view"))
        _shift_pivot!(gui, sel, d)
        ctrl.selected[] === sel || (ctrl.selected[] = sel)
        _update_selection_box!(ctrl)
        return nothing
    end
    _push_action!(ctrl, sel, () -> step!(-δ), () -> step!(δ))
    return nothing
end

"""
    _shift_pivot!(gui, sel, δ)

Shifts the pivot of the selection `sel` of the `gui` by `δ` [m] in the frame of `sel`, i.e. by
`orientation(sel) * δ` in the world, without moving any of its objects and without an entry of the
undo history (see `_record_pivot!`).

The pose of a group is the pose of its pivot. What the view stores of the pose of a group `g` is
therefore shifted with it, such that the parts of `g` stay where they are, see
`_shift_pivot_records!`: its initial pose of the controls (for the reset and the export), the record
of a group made in the window (see `_WindowGroup`) and the pose of `g` in the record of a group made
in the window that holds it; for any other group the shift is added up in `gui.components.pivots`,
from which `export_changes` writes `set_pivot3d!`. The views that are linked with the `gui` shift
the same records of their own and their entries of the history of `g`, see `_follow_pivot!`. The
entries of the history of the `gui` itself stay: they are undone after the shift, which undoes it.
"""
function _shift_pivot!(gui::LiveView, s::_MultiSelection, δ)
    s.pos = s.pos + Point3{Float64}(s.dir * Vector{Float64}(δ))
    _pivot_moved!(gui)
    return nothing
end

function _shift_pivot!(gui::LiveView, @nospecialize(g::BMO.AbstractObjectGroup), δ)
    d = Vector{Float64}(δ)
    _change!(gui.controls, g) do
        BMO.set_pivot3d!(g, Vector{Float64}(position(g)) .+ Matrix{Float64}(BMO.orientation(g)) * d)
    end
    records = _shift_pivot_records!(gui, g, d)
    _each_linked(view -> _follow_pivot!(view, g, d, records), gui)
    _pivot_moved!(gui)
    return nothing
end

# The pose `(P, R)` of a group with its pivot shifted by `δ` in its frame
_shifted_pose((P, R), δ) = (Point3{Float64}(Vector{Float64}(P) .+ Matrix{Float64}(R) * δ), R)

"""
    _shift_pivot_records!(gui, g, δ) -> IdDict

Shifts what the `gui` stores of the pose of the group `g` by the shift `δ` of its pivot, see
`_shift_pivot!`, and returns the new records of the groups made in the window (`group => record`):
of `g`, whose pivot was its pose when it was made with the axes of the world, i.e. in its frame,
and of the groups made in the window that hold `g`.
"""
function _shift_pivot_records!(gui::LiveView, @nospecialize(g), δ)
    comp = gui.components
    init = gui.controls.init_poses
    haskey(init, g) && (init[g] = _shifted_pose(init[g], δ))
    records = IdDict{Any, Any}()
    rec = get(comp.groups, g, nothing)
    if isnothing(rec)
        shift = get(comp.pivots, g, zeros(3)) .+ δ
        norm(shift) > 1e-15 ? (comp.pivots[g] = shift) : delete!(comp.pivots, g)
    else
        records[g] = _WindowGroup(rec.members, rec.pivot .+ δ, rec.poses)
    end
    for (k, r) in collect(comp.groups)
        haskey(r.poses, g) || continue
        poses = copy(r.poses)
        poses[g] = _shifted_pose(poses[g], δ)
        records[k] = _WindowGroup(r.members, get(records, k, r).pivot, poses)
    end
    for (k, r) in records
        comp.groups[k] = r
    end
    return records
end

"""
    _follow_pivot!(view, g, δ, records)

The linked `view` follows the shift `δ` of the pivot of the group `g` in another view (see
`_shift_pivot!`), whose new records of the groups made in the window are `records`: it shifts its
initial pose of `g`, takes the same records, adds up the shift of a group that is not made in the
window and shifts the poses of `g` in the entries of its undo history, which do not undo the shift.
"""
function _follow_pivot!(view::LiveView, @nospecialize(g), δ, records)
    comp = view.components
    ctrl = view.controls
    init = ctrl.init_poses
    haskey(init, g) || return nothing
    init[g] = _shifted_pose(init[g], δ)
    if !haskey(comp.groups, g)
        shift = get(comp.pivots, g, zeros(3)) .+ δ
        norm(shift) > 1e-15 ? (comp.pivots[g] = shift) : delete!(comp.pivots, g)
    end
    for (k, r) in records
        haskey(comp.groups, k) && (comp.groups[k] = r)
    end
    for stack in (ctrl.undo_stack, ctrl.redo_stack), (i, e) in enumerate(stack)
        (e isa _HistoryEntry && e.obj === g) || continue
        (P0, R0), (P1, R1) = _shifted_pose((e.P0, e.R0), δ), _shifted_pose((e.P1, e.R1), δ)
        stack[i] = _HistoryEntry(g, P0, R0, P1, R1)
    end
    _pivot_moved!(view)
    return nothing
end

# The selection box, the gizmo and the cards of the `gui` after a pivot moved
function _pivot_moved!(gui::LiveView)
    _update_selection_box!(gui.controls)
    _update_inspector!(gui; force = true)
    return nothing
end

"""Moves the pivot of the selection `sel` of the `gui` to the center of its bounding box, the box
that is drawn around it while it is selected, see `_selection_bbox`."""
function _center_pivot!(gui::LiveView, @nospecialize(sel))
    reason = _pivot_reason(gui, sel)
    if !isnothing(reason)
        gui.status.text[] = reason
        return false
    end
    ctrl = gui.controls
    bb = _selection_bbox(ctrl, sel, _object_plots(ctrl.h, sel))
    return _set_pivot!(gui, sel, Vector{Float64}(minimum(bb) .+ GeometryBasics.widths(bb) ./ 2))
end

"""
    _apply_pivot_input!(gui, sel, k, s)

Applies the input `s` of the box `k` (x, y or z [mm]) of the row "pivot" of the card of the
selection `sel`, see `_pivot_rows`: moves its pivot to that coordinate, see `_set_pivot!`. An
invalid input only shows a message in the status line.
"""
function _apply_pivot_input!(gui::LiveView, @nospecialize(sel), k::Int, s)
    x = isnothing(s) ? nothing : tryparse(Float64, strip(s))
    if isnothing(x) || !isfinite(x)
        gui.status.text[] = "invalid input \"$(something(s, ""))\" for the pivot, enter a number [mm]"
    elseif _has_pivot(sel)
        p = Vector{Float64}(position(sel))
        p[k] = x / 1e3
        _set_pivot!(gui, sel, p)
    end
    _update_inspector!(gui; force = true)
    return nothing
end

#=
The row "pivot" of the cards of groups and selections of several
=#

# The boxes x, y and z of the pivot [mm], like those of the pose, see `pose_card_rows`
_pivot_box(k::Int) = CardWidget(Textbox; name = Symbol(:pivot_, _CARD_POSE_NAMES[k]), placeholder = " ",
    width = 76, value = (gui, obj) -> string(round(1e3 * position(obj)[k], digits = 6)),
    on = (gui, obj, s) -> _apply_pivot_input!(gui, obj, k, s))

"""
    _pivot_rows()

The rows of the pivot on the card of a group or a selection of several: the label "pivot" with the
buttons "pick" (the next click on a part sets the pivot to its position, see
`_start_pivot_pick!`) and "center" (the center of its bounding box, see `_center_pivot!`), then the boxes x,
y and z [mm] of the pivot, see `_apply_pivot_input!`.
"""
function _pivot_rows()
    pick = CardWidget(Button; name = :pivot_pick, label = "pick",
        value = (gui, o) -> _GroupButton(gui.components.pivot_pick === o ? "Esc" : "pick", true),
        on = (gui, o, _) -> _start_pivot_pick!(gui, o))
    center = CardWidget(Button; name = :pivot_center, label = "center",
        on = (gui, o, _) -> _center_pivot!(gui, o))
    boxes = Iterators.flatten((_pose_label(k), _pivot_box(k)) for k in 1:3)
    return (CardRow(CardWidget(Label; text = "pivot", width = 40, halign = :left), pick, center),
        CardRow(boxes..., "mm"))
end

#=
The pick of the pivot with the mouse
=#

"""
    _start_pivot_pick!(gui, sel)

Starts picking the pivot of the selection `sel` of the `gui` with the mouse, or ends it if it is
going on, like a second click on the button "pick": the next click on one of its parts in the 3D
view or in the object tree sets the pivot to the position of that part (also of a part inside a
subgroup, see `_pick_pivot!`), and neither selects nor deselects. A click beside its parts, `Esc`,
another selection and the spectator mode end the pick without a change. A pick of members ends.
"""
function _start_pivot_pick!(gui::LiveView, @nospecialize(sel))
    gui.components.pivot_pick === sel && return _end_pivot_pick!(gui)
    reason = _pivot_reason(gui, sel)
    if !isnothing(reason)
        gui.status.text[] = reason
        return nothing
    end
    _end_member_pick!(gui)
    gui.components.pivot_pick = sel
    _show_pick_chip!(gui, "pivot of " * _label(gui, sel))
    gui.status.text[] = "pivot of $(_label(gui, sel)): click one of its parts, Esc ends"
    _update_inspector!(gui; force = true)
    return nothing
end

"""Ends the pick of the pivot of the `gui`, if it is going on, see `_start_pivot_pick!`."""
function _end_pivot_pick!(gui::LiveView; text = "pivot: picking ended")
    isnothing(gui.components.pivot_pick) && return nothing
    gui.components.pivot_pick = nothing
    _show_pick_chip!(gui, nothing)
    isnothing(text) || (gui.status.text[] = text)
    _update_inspector!(gui; force = true)
    return nothing
end

"""
    _pick_pivot!(gui, obj) -> Bool

Applies the pick of the pivot of the `gui` to `obj`, which was clicked: if it is one of the parts of
the selection of the pick (see `_pivot_parts`), its position is the new pivot, see `_set_pivot!`.
The pick ends either way. Returns whether `obj` was a part.
"""
function _pick_pivot!(gui::LiveView, @nospecialize(obj))
    sel = gui.components.pivot_pick
    isnothing(sel) && return false
    part = !isnothing(obj) && _has(_pivot_parts(sel), obj)
    _end_pivot_pick!(gui; text = nothing)
    if part
        _set_pivot!(gui, sel, position(obj))
    else
        gui.status.text[] = "pivot of $(_label(gui, sel)): no part clicked, picking ended"
    end
    return part
end

"""
    _pivot_pick_shown!(gui, obj) -> Bool

What `obj`, which is about to be selected in the `gui`, e.g. from the object tree, means while the
pivot is picked (see `_start_pivot_pick!`): a part of the selection of the pick sets the pivot and
is not selected, for which it returns `true`. Anything else ends the pick and is selected as usual.
"""
function _pivot_pick_shown!(gui::LiveView, @nospecialize(obj))
    isnothing(gui.components.pivot_pick) && return false
    return _pick_pivot!(gui, obj)
end

#=
The dot of the pivot in the 3D view
=#

"""
    _PivotMarker

The marker of the pivot of the selection of a live view, see `_draw_selection_pivot!`: the `dot` at
the pivot and the dashed `line` from it to the gizmo, in a scene of pixels over the 3D view, and the
drag of the dot (`drag`: the selection, the point of the pivot at the press, the normal of the plane
in which it moves and the offset of the cursor from the dot), `nothing` without one.
"""
mutable struct _PivotMarker
    dot::Any
    line::Any
    drag::Any
end

"""
    _draw_selection_pivot!(gui)

Draws the hidden marker of the pivot of the selection of the `gui`, see `_update_selection_pivot!`:
a dot in the accent color, outlined in the color of the background of the 3D view, and a thin
dashed line in the accent color from it to the gizmo. Like the marker of the pivot of the camera
(see `_draw_pivot!`), in a scene of pixels over the 3D view, which beams in the 3D view do not
cover, made before the cards, which therefore cover it.
"""
function _draw_selection_pivot!(gui::LiveView)
    scene = Scene(gui.fig.scene; camera = Makie.campixel!, clear = false)
    accent, outline = gui.layout.theme.accent, _pivot_outline(gui, 1.0)
    common = (; visible = false, inspectable = false)
    line = lines!(scene, Point2f[(0, 0), (0, 0)]; color = accent, linewidth = 1.2, linestyle = :dash, common...)
    dot = scatter!(scene, [Point2f(0, 0)]; marker = :circle, markersize = 8, color = accent,
        strokecolor = outline, strokewidth = 1.5, common...)
    gui.components.pivot_marker = _PivotMarker(dot, line, nothing)
    return nothing
end

# The pixel of the window at the point `p` [m] of the 3D view of the `gui`, `nothing` if it is behind
# the camera or outside of the 3D view
function _view_px(gui::LiveView, p)
    scene = gui.ax.scene
    cam = cameracontrols(scene)
    if cam isa Makie.Camera3D && cam.settings.projectiontype[] == Makie.Perspective
        dot(Vector{Float64}(p) .- Vector{Float64}(cam.eyeposition[]), _view_direction(scene)) > 0 || return nothing
    end
    vp = Makie.viewport(scene)[]
    px = Makie.project(scene, Point3f(p))
    all(isfinite, px) || return nothing
    (0 <= px[1] <= Makie.widths(vp)[1] && 0 <= px[2] <= Makie.widths(vp)[2]) || return nothing
    return Point2f(px .+ Makie.origin(vp))
end

"""Whether the marker of the pivot of the `gui` is shown for its selection, see `_update_selection_pivot!`."""
function _pivot_shown(gui::LiveView)
    ctrl = gui.controls
    sel = ctrl.selected[]
    return !ctrl.spectator[] && _has_pivot(sel) && ctrl.gizmo_visible[]
end

"""
    _update_selection_pivot!(gui)

Shows the marker of the pivot of the selection of the `gui` at its pivot, with the line to the
origin of the gizmo, while a group or a selection of several is selected and the gizmo is shown,
otherwise hides it. Hidden in the spectator mode and if the pivot is not in the 3D view. The dot is
larger under the cursor and while it is dragged. Called every frame; attributes are only set when
they change.
"""
function _update_selection_pivot!(gui::LiveView)
    m = gui.components.pivot_marker
    isnothing(m) && return nothing
    at = _pivot_shown(gui) ? _view_px(gui, position(gui.controls.selected[])) : nothing
    gizmo = isnothing(at) ? nothing : _view_px(gui, gui.controls.gizmo_origin)
    if !isnothing(at)
        Makie.translation(m.dot)[] == Vec3f(at..., 0) || translate!(m.dot, Vec3f(at..., 0))
        hover = !isnothing(m.drag) || hypot((_cursor_px(gui) .- at)...) <= _PIVOT_GRAB_RADIUS
        _update_attr!(m.dot.markersize, hover ? 11 : 8)
        _update_attr!(m.dot.color, gui.layout.theme.accent)
        _update_attr!(m.dot.strokecolor, _pivot_outline(gui, 1.0))
    end
    _update_attr!(m.dot.visible, !isnothing(at))
    if !isnothing(gizmo)
        pts = Point2f[at, gizmo]
        m.line[1][] == pts || (m.line[1][] = pts)
        _update_attr!(m.line.color, gui.layout.theme.accent)
    end
    _update_attr!(m.line.visible, !isnothing(gizmo))
    return nothing
end

# The pixel of the cursor in the window, like `_view_px`; `_px` is in the 3D view of the `gui`
_cursor_px(gui::LiveView) = _px(gui.ax.scene) .+ Tuple(Float64.(Makie.origin(Makie.viewport(gui.ax.scene)[])))

"""Whether the cursor is on the dot of the pivot of the `gui`, see `_PIVOT_GRAB_RADIUS`."""
function _pivot_hit(gui::LiveView)
    _pivot_shown(gui) || return false
    at = _view_px(gui, position(gui.controls.selected[]))
    isnothing(at) && return false
    cur = _px(gui.ax.scene) .+ Tuple(Float64.(Makie.origin(Makie.viewport(gui.ax.scene)[])))
    return hypot((cur .- at)...) <= _PIVOT_GRAB_RADIUS
end

"""
    _start_pivot_drag!(gui)

A press on the dot of the pivot of the `gui`: the dot follows the mouse in the plane of the view
through the pivot, see `_pivot_drag_step!`, and the release records the shift as one action of the
undo history, see `_end_pivot_drag!`.
"""
function _start_pivot_drag!(gui::LiveView)
    scene = gui.ax.scene
    sel = gui.controls.selected[]
    P = Vector{Float64}(position(sel))
    n = _view_direction(scene)
    origin, dir = _cursor_ray(scene)
    hit = _ray_plane_intersect(origin, dir, P, n)
    grab = isnothing(hit) ? zeros(3) : P .- hit
    gui.components.pivot_marker.drag = (; sel, start = P, normal = n, grab)
    return nothing
end

function _pivot_drag_step!(gui::LiveView)
    drag = gui.components.pivot_marker.drag
    origin, dir = _cursor_ray(gui.ax.scene)
    hit = _ray_plane_intersect(origin, dir, drag.start, drag.normal)
    isnothing(hit) && return nothing
    sel = drag.sel
    δ = Matrix{Float64}(BMO.orientation(sel))' * (hit .+ drag.grab .- Vector{Float64}(position(sel)))
    norm(δ) > 1e-15 && _shift_pivot!(gui, sel, δ)
    gui.status.text[] = "pivot of $(_label(gui, sel)) at $(_position_string(sel))"
    return nothing
end

function _end_pivot_drag!(gui::LiveView)
    m = gui.components.pivot_marker
    drag = m.drag
    m.drag = nothing
    sel = drag.sel
    δ = Matrix{Float64}(BMO.orientation(sel))' * (Vector{Float64}(position(sel)) .- drag.start)
    norm(δ) > 1e-15 && _record_pivot!(gui, sel, δ)
    return nothing
end

"""
Connects the pivot of the selection of the `gui`: its marker (see `_draw_selection_pivot!`), which
follows every frame and is dragged with the mouse, and the pick of the pivot with the mouse (see
`_start_pivot_pick!`), which a click on a part, `Esc`, another selection, the spectator mode and the
closed window end.
"""
function _connect_pivot!(gui::LiveView)
    ctrl = gui.controls
    ev = events(gui.ax.scene)
    listeners = ctrl.listeners
    _draw_selection_pivot!(gui)
    marker = gui.components.pivot_marker
    # The pixel and the object of a press while the pivot is picked, see `_pick_press`
    press = Ref{Any}(nothing)
    push!(listeners, on(ev.mousebutton; priority = _PIVOT_PRIORITY) do event
        event.button == Mouse.left || return Consume(false)
        try
            if event.action == Mouse.press
                (ctrl.spectator[] || ctrl.ignore_mouse() || _placing(gui) || _aiming(gui)) &&
                    return Consume(false)
                if _pivot_hit(gui)
                    _start_pivot_drag!(gui)
                    return Consume(true)
                end
                isnothing(gui.components.pivot_pick) ||
                    (press[] = (_px(gui.ax.scene), _member_under_cursor(gui)))
            elseif event.action == Mouse.release
                if !isnothing(marker.drag)
                    _end_pivot_drag!(gui)
                    return Consume(true)
                end
                isnothing(press[]) && return Consume(false)
                p0, leaf = press[]
                press[] = nothing
                _pivot_release!(gui, p0, leaf)
            end
        catch e
            marker.drag = nothing
            gui.last_error = _log_once(gui, e, gui.last_error, "the pivot")
        end
        return Consume(false)
    end)
    push!(listeners, on(ev.mouseposition; priority = _PIVOT_PRIORITY) do _
        isnothing(marker.drag) && return Consume(false)
        try
            _pivot_drag_step!(gui)
        catch e
            marker.drag = nothing
            gui.last_error = _log_once(gui, e, gui.last_error, "dragging the pivot")
        end
        return Consume(true)
    end)
    push!(listeners, on(ev.keyboardbutton; priority = _PIVOT_KEY_PRIORITY) do event
        (event.action == Keyboard.press && event.key == Keyboard.escape) || return Consume(false)
        (isnothing(gui.components.pivot_pick) || ctrl.ignore_keys()) && return Consume(false)
        _end_pivot_pick!(gui)
        return Consume(true)
    end)
    push!(listeners, on(ctrl.selected) do sel
        pick = gui.components.pivot_pick
        (isnothing(pick) || pick === sel) || _end_pivot_pick!(gui)
        return nothing
    end)
    push!(listeners, on(v -> v && _end_pivot_pick!(gui), ctrl.spectator))
    push!(listeners, on(open -> open || _end_pivot_pick!(gui), ev.window_open))
    push!(listeners, on(ev.tick) do _
        try
            _update_selection_pivot!(gui)
        catch e
            gui.last_error = _log_once(gui, e, gui.last_error, "the marker of the pivot")
        end
        return nothing
    end)
    append!(ctrl.help_extra, _PIVOT_HELP)
    _update_help!(ctrl)
    return nothing
end

"""
    _pivot_release!(gui, p0, leaf)

The release of a press at the pixel `p0` on `leaf` while the pivot of the `gui` is picked, like
`_pick_release!` of the members: a click sets the pivot to the position of `leaf` if it is a part
of the selection of the pick (see `_pick_pivot!`), otherwise it ends the pick, and the controls
neither select nor deselect. A drag is left to the controls and the camera.
"""
function _pivot_release!(gui::LiveView, p0, @nospecialize(leaf))
    ctrl = gui.controls
    isnothing(gui.components.pivot_pick) && return nothing
    (ctrl.dragging || ctrl.press_pos != p0) && return nothing
    ctrl.press_kind in (:pending_select, :pending_drag, :background) || return nothing
    hypot((_px(gui.ax.scene) .- p0)...) < ctrl.drag_threshold || return nothing
    ctrl.press_kind, ctrl.press_leaf, ctrl.press_pos = :none, nothing, nothing
    ctrl.press_toggle = false
    _pick_pivot!(gui, leaf)
    return nothing
end
