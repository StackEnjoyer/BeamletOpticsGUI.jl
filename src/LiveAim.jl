#=
Aiming a source with the mouse: "aim" on its card, then a click on what it shall point at, see
`_start_aim!`
=#

"""
    _Aim

The source `src` of a `LiveView` that is being aimed, see `_start_aim!`: the `ignore_mouse` of the
controls, which ignore all presses meanwhile; the `line` from the source to the point under the
mouse and its `plot`; the mouse position of the `press` that may become the click that aims it.
"""
mutable struct _Aim
    const src::_Source
    const ignore_mouse::Function
    const line::Observable{Vector{Point3f}}
    const plot::AbstractPlot
    press::Union{Nothing, NTuple{2, Float64}}
end

"""Returns `true` while a source of the `gui` is being aimed (`src`: this one), see `_start_aim!`."""
_aiming(gui::LiveView) = !isnothing(gui.components.aim)
_aiming(gui::LiveView, src) = _aiming(gui) && gui.components.aim.src === src

"""
The point [m] of the component or source `leaf` of the controls `ctrl` that a source is aimed at: of
a component the center of the bounding box of its plots, of a source its position.
"""
function _aim_point(ctrl::KinematicController, leaf::BMO.AbstractObject)
    bb = _selection_bbox(ctrl, leaf, _object_plots(ctrl.h, leaf))
    return Vector{Float64}(minimum(bb)) .+ Vector{Float64}(GeometryBasics.widths(bb)) ./ 2
end
_aim_point(::KinematicController, leaf) = Vector{Float64}(position(leaf))

"""
    _aim_target(gui, a::_Aim) -> Union{Nothing, NamedTuple}

What the source `a.src` of the `gui` is aimed at for the current mouse position, as
`(; point, obj)`: the component or other source `obj` under the cursor (see `_ray_pick`) with its
`_aim_point`; elsewhere (`obj = nothing`) the point where the camera ray through the cursor meets
the plane through the source on which components are placed (see `_placement_normal`), i.e. the
plane of the table, such that the beam stays in it, snapped onto the grid of the controls, if any, e.g. a hole of
the table. `nothing` if the ray does not meet the plane in front of the camera.
"""
function _aim_target(gui::LiveView, a::_Aim)
    ctrl = gui.controls
    scene = gui.ax.scene
    leaf, _ = _ray_pick(ctrl, scene)
    if !isnothing(leaf) && leaf !== a.src && !(leaf isa LiveClipPlane)
        return (; point = _aim_point(ctrl, leaf), obj = leaf)
    end
    origin, dir = _cursor_ray(scene)
    hit = _ray_plane_intersect(origin, dir, Vector{Float64}(position(a.src)), _placement_normal(scene, ctrl))
    (isnothing(hit) || norm(hit .- origin) <= 1e-9) && return nothing
    point = Vector{Float64}(hit)
    grid = ctrl.snap_grid(a.src, point)
    isnothing(grid) || (point = Vector{Float64}(grid.point))
    return (; point, obj = nothing)
end

"""
    _aim!(gui, src, point) -> Bool

Turns the source `src` of the `gui` about its position such that it points at the `point` [m], by
the smallest rotation (a half turn about the rotation axis of the controls). One gesture of the
undo history, solved like a move. Returns whether it turned; otherwise the status line tells why
not: a source that is not movable or whose rotation is constrained, and a point at its position.
"""
function _aim!(gui::LiveView, src::_Source, point)
    ctrl = gui.controls
    name = _label(gui, src)
    if !_is_movable(ctrl, src)
        gui.status.text[] = "$name is not movable, it can not be aimed"
        return false
    end
    if Set(_allowed_axes(ctrl, src, :rotate)) != Set(_GIZMO_AXES)
        gui.status.text[] = "$name can not rotate freely, see the constraints"
        return false
    end
    P0, R0 = _pose(src)
    d = Vector{Float64}(point) .- Vector{Float64}(P0)
    if norm(d) < 1e-12
        gui.status.text[] = "$name is at this point, it can not be aimed at it"
        return false
    end
    Q = _align_rotation(Vector{Float64}(BMO.direction(src)), d, ctrl.rotation_axis)
    axis, angle = _axis_angle_from_rotmatrix(Q)
    angle > 1e-12 && _change!(() -> rotate3d!(src, axis, angle), ctrl, src)
    _commit_pose!(gui, src, P0, R0)
    return true
end

"""Whether the mouse of the `gui` is in its 3D view and not over a card or a part of the layout."""
_aim_mouse_in_view(gui::LiveView, a::_Aim) = Makie.is_mouseinside(gui.ax.scene) && !a.ignore_mouse()

# The source that is being aimed is still a source of the view, e.g. not removed by `Delete`
_aim_valid(gui::LiveView, a::_Aim) = any(p -> p.second === a.src, gui.pairs)

"""Draws the line of the aim of the `gui` from its source to the point under the mouse."""
function _update_aim!(gui::LiveView)
    a = gui.components.aim
    isnothing(a) && return nothing
    _aim_valid(gui, a) || return _cancel_aim!(gui)
    p = Point3f(position(a.src))
    target = _aim_mouse_in_view(gui, a) ? _aim_target(gui, a) : nothing
    a.line[] = [p, isnothing(target) ? p : Point3f(target.point)]
    return nothing
end

"""
    _start_aim!(gui, src)

Starts aiming the source `src` of the `gui` with the mouse: a dashed line follows the mouse from the
source to the point that it would point at (see `_aim_target`), until a left click turns the source
to it, see `_aim!`. `Esc`, the spectator mode and "aim" again cancel it; a component that is being
placed is cancelled first. A drag still moves the camera, and presses on cards and on the layout
keep their meaning. The controls ignore the mouse meanwhile: nothing is selected or dragged.
"""
function _start_aim!(gui::LiveView, src::_Source)
    ctrl = gui.controls
    _cancel_placement!(gui)
    _cancel_aim!(gui)
    name = _label(gui, src)
    if ctrl.spectator[]
        gui.status.text[] = "spectator mode, press v to aim sources"
        return nothing
    end
    if !_is_movable(ctrl, src)
        gui.status.text[] = "$name is not movable, it can not be aimed"
        return nothing
    end
    p = Point3f(position(src))
    line = Observable([p, p])
    plot = lines!(gui.ax, line; color = :orange, linestyle = :dash, linewidth = 2, overdraw = true,
        clip_planes = Plane3f[])
    gui.components.aim = _Aim(src, ctrl.ignore_mouse, line, plot, nothing)
    # The camera still gets the presses, e.g. to rotate the view
    ctrl.ignore_mouse = () -> true
    _update_aim!(gui)
    # the button "aim" of its card reads "cancel" now
    _update_inspector!(gui)
    gui.status.text[] = "aiming $name: click a component or a point, Esc to cancel"
    return nothing
end
_start_aim!(gui::LiveView, obj) =
    (gui.status.text[] = "$(_label(gui, obj)) is no source, only sources are aimed"; nothing)

"""Ends the aim of the `gui`: removes its line and gives the mouse back to the controls."""
function _end_aim!(gui::LiveView)
    a = gui.components.aim
    isnothing(a) && return nothing
    gui.components.aim = nothing
    gui.controls.ignore_mouse = a.ignore_mouse
    delete!(gui.ax, a.plot)
    _update_inspector!(gui)
    return a
end

"""Cancels the aim of a source of the `gui`, nothing without one, see `_start_aim!`."""
function _cancel_aim!(gui::LiveView)
    isnothing(_end_aim!(gui)) || (gui.status.text[] = "aiming cancelled")
    return nothing
end

"""The button "aim" of the card of the source `src`: starts aiming it, or cancels it."""
_toggle_aim!(gui::LiveView, src) = _aiming(gui, src) ? _cancel_aim!(gui) : _start_aim!(gui, src)

"""Aims the source of the aim of the `gui` at what is under the mouse, see `_aim_target`."""
function _drop_aim!(gui::LiveView)
    a = gui.components.aim
    isnothing(a) && return nothing
    target = _aim_target(gui, a)
    isnothing(target) && return nothing
    _end_aim!(gui)
    _aim!(gui, a.src, target.point) || return nothing
    at = isnothing(target.obj) ? _point_string(target.point) : _label(gui, target.obj)
    gui.status.text[] = "$(_label(gui, a.src)) aimed at $at"
    return nothing
end

"""
A left click into the 3D view of the `gui`, i.e. a press and a release less than the
`drag_threshold` of the controls apart, aims the source that is being aimed; a drag is left to the
camera. The events are passed on.
"""
function _aim_click!(gui::LiveView, event)
    a = gui.components.aim
    (isnothing(a) || event.button != Mouse.left) && return nothing
    scene = gui.ax.scene
    if event.action == Mouse.press
        a.press = _aim_mouse_in_view(gui, a) ? _px(scene) : nothing
    elseif event.action == Mouse.release
        press = a.press
        a.press = nothing
        isnothing(press) && return nothing
        hypot((_px(scene) .- press)...) < gui.controls.drag_threshold && _drop_aim!(gui)
    end
    return nothing
end

"""
Connects aiming the sources of the `gui`, see `_start_aim!`: the mouse moves the line, a click
aims, `Esc` and the spectator mode cancel. The listeners run before the controls (200) and do
nothing while no source is being aimed.
"""
function _connect_aim!(gui::LiveView)
    ev = events(gui.ax.scene)
    listeners = gui.controls.listeners
    push!(listeners, on(ev.mouseposition; priority = 210) do _
        _update_aim!(gui)
        return Consume(false)
    end)
    push!(listeners, on(ev.mousebutton; priority = 210) do event
        _aim_click!(gui, event)
        return Consume(false)
    end)
    push!(listeners, on(ev.keyboardbutton; priority = 210) do event
        (_aiming(gui) && event.action == Keyboard.press && event.key == Keyboard.escape) ||
            return Consume(false)
        gui.controls.ignore_keys() && return Consume(false)
        _cancel_aim!(gui)
        return Consume(true)
    end)
    push!(listeners, on(v -> v && _cancel_aim!(gui), gui.controls.spectator))
    return nothing
end

"""
The last row of the card of a source, below its other rows (see `_card_rows`): "aim" starts aiming
it with the mouse, or cancels it (see `_start_aim!`), "remove" removes it from the view, see
`_remove_selected!`.
"""
_source_row() = CardRow(
    CardWidget(Button; name = :aim, label = "aim", value = (gui, o) -> _aiming(gui, o) ? "cancel" : "aim",
        on = (gui, o, _) -> _toggle_aim!(gui, o)),
    _remove_button())
