#=
Placing a new component with the mouse, see `_start_placement!`
=#

# Screen-space radius within which a component that is being placed snaps onto a beam [px]
const _SNAP_RADIUS = 12.0

# Opacity of a component while it is being placed, relative to its opacity as rendered
const _GHOST_OPACITY = 0.5

"""
    _Placement

A component or source of a `LiveView` that follows the mouse until a click drops it, see
`_start_placement!`: the object or source `obj` and its `ghost`, i.e. its render handle while it is
not part of the view (of a source: its marker); the `system` that gets it and its `origin` (see
`_ComponentState`); its orientation
`R0` as constructed, which it has off the beams; the `plane_point` of the plane it moves on; the
`ignore_mouse` of the controls, which ignore all presses meanwhile; the mouse position of the
`press` that may become the click that drops it; `snapped` is `true` while it sits on a beam.
"""
mutable struct _Placement
    const obj::Union{BMO.AbstractObject, _Source}
    const ghost::AbstractObjectRenderHandle
    const system::BMO.AbstractSystem
    const origin::Any
    const R0::Matrix{Float64}
    const plane_point::Vector{Float64}
    const ignore_mouse::Function
    press::Union{Nothing, NTuple{2, Float64}}
    snapped::Bool
end

"""Returns `true` while a component of the `gui` is being placed, see `_start_placement!`."""
_placing(gui::LiveView) = !isnothing(gui.components.placement)

"""Returns the matrix of the rotation by `angle` about the unit vector `axis`."""
function _rotation_matrix(axis, angle)
    K = [0 -axis[3] axis[2]; axis[3] 0 -axis[1]; -axis[2] axis[1] 0]
    return Matrix{Float64}(I, 3, 3) + sin(angle) * K + (1 - cos(angle)) * K * K
end

"""
    _align_rotation(y, d, half_turn_axis)

Returns the smallest rotation that turns the direction `y` onto the direction `d`. If they are
antiparallel (`y·d < −1 + 10⁻⁹`), the half turn about the part of `half_turn_axis` that is
perpendicular to `y`.
"""
function _align_rotation(y, d, half_turn_axis)
    y, d = normalize(Vector{Float64}(y)), normalize(Vector{Float64}(d))
    c = dot(y, d)
    if c < -1 + 1e-9
        axis = Vector{Float64}(half_turn_axis) .- dot(half_turn_axis, y) .* y
        # the axis is parallel to `y`: any perpendicular axis
        norm(axis) < 1e-9 && (axis = cross(y, abs(y[3]) < 0.9 ? [0.0, 0, 1] : [1.0, 0, 0]))
        return _rotation_matrix(normalize(axis), π)
    end
    axis = cross(y, d)
    s = norm(axis)
    s < 1e-12 && return Matrix{Float64}(I, 3, 3)
    return _rotation_matrix(axis ./ s, atan(s, c))
end

"""
The point of the plane on which a component for the system `sys` of the `gui` is placed (see
`_placement_pose`): the position of the first source that is traced through `sys`, such that the
component lies at the height of its beam in a view from above, and at its depth in a view from the
front; or the `lookat` point of the camera without one.
"""
function _placement_plane_point(gui::LiveView, sys::BMO.AbstractSystem)
    for (s, beam) in gui.pairs
        s === sys && return Vector{Float64}(position(beam))
    end
    return Vector{Float64}(cameracontrols(gui.ax.scene).lookat[])
end

"""
    _placement_pose(gui, p::_Placement) -> (P, R, snapped)

The pose of the component `p` for the current mouse position. Within `_SNAP_RADIUS` of a rendered
beam, it snaps onto the beam: the position is the point of the beam under the cursor (see
`_inspect_beam`) and the local y-axis, the optical axis as constructed, points along the beam. Of
a beam group, only the central beam takes part, and of a Gaussian beamlet its chief ray, such that
the component sits on the axis of the source and not on one of its outer rays. The
component is not traced while it is placed, hence the beams it snaps onto do not change. A source
does not snap, see `_snaps`. Elsewhere, the position is where the camera ray through the cursor meets the plane through `p.plane_point`
in which the mouse moves objects (see `_drag_normal`: the plane of the view, or the one with the
`plane_normal` of the controls), in the orientation `p.R0` as constructed; the position is kept if
the ray does not meet the plane in front of the camera. There, a component or source snaps onto
the grid of the controls, if any, e.g. the holes of the table (see `_table_snap`).
"""
function _placement_pose(gui::LiveView, p::_Placement)
    ctrl = gui.controls
    info = _snaps(p.obj) ? _inspect_beam(gui; radius = _SNAP_RADIUS, central = true) : nothing
    if !isnothing(info)
        R = _align_rotation(p.R0[:, 2], info.direction, ctrl.rotation_axis) * p.R0
        return Point3{Float64}(info.point), R, true
    end
    origin, dir = _cursor_ray(gui.ax.scene)
    hit = _ray_plane_intersect(origin, dir, p.plane_point, _drag_normal(gui.ax.scene, ctrl))
    # A camera in the plane meets it at the eye with every ray, which is no place for a component
    met = !isnothing(hit) && norm(hit .- origin) > 1e-9
    P = met ? Point3{Float64}(hit) : _pose(p.obj)[1]
    # beside the beams: onto the grid, e.g. the holes of the table
    grid = ctrl.snap_grid(p.obj, Vector{Float64}(P))
    isnothing(grid) || (P = Point3{Float64}(grid.point))
    return P, p.R0, false
end

"""Whether the mouse of the `gui` is in its 3D view and not over a card or a part of the layout."""
_placement_mouse_in_view(gui::LiveView, p::_Placement) =
    Makie.is_mouseinside(gui.ax.scene) && !p.ignore_mouse()

"""Moves the component that is being placed in the `gui` to the mouse, see `_placement_pose`."""
function _update_placement!(gui::LiveView)
    p = gui.components.placement
    (isnothing(p) || !_placement_mouse_in_view(gui, p)) && return nothing
    P, R, snapped = _placement_pose(gui, p)
    # Not traced, hence no solve is cancelled, see `_change!`
    _set_pose_exact!(p.obj, P, R)
    p.snapped = snapped
    update_render!(p.ghost)
    return nothing
end

"""
The look of a component while it is being placed: the colors of the theme of the layout, like the
objects of the systems, and half of its opacity, such that it reads as not yet part of the setup.
"""
function _ghost_style!(gui::LiveView, sys::BMO.System, ghost::AbstractObjectRenderHandle)
    _theme_render!(gui.layout,
        LiveSystemHandle(sys, AbstractObjectRenderHandle[ghost], AbstractSystemRenderHandle[]))
    for plot in render_plots(ghost)
        _apply_opacity!(plot, _plot_base(plot)..., _GHOST_OPACITY)
    end
    return nothing
end

"""
The system that gets `obj` when it is placed in the `gui` without a `system`: of a component the
`_target_system`, of a source the `_source_system`.
"""
_placement_system(gui::LiveView, ::BMO.AbstractObject) = _target_system(gui)
_placement_system(gui::LiveView, ::_Source) = _source_system(gui, nothing)

# A component changes its system, hence it needs a `System`; a source is traced through any system
_check_placement_system(::BMO.AbstractObject, system) = system isa BMO.System ||
    throw(ArgumentError("the live view has no `System` that a component can be placed in"))
_check_placement_system(::_Source, system) = system isa BMO.AbstractSystem ||
    throw(ArgumentError("`system` must be a system of the live view, got a $(typeof(system))"))

"""
    _ghost!(gui, obj, system) -> AbstractObjectRenderHandle

Renders `obj` while it is being placed in the `gui`, i.e. while it is not part of the view: a
component for the `system` as its objects are rendered and in the look of `_ghost_style!`, a source
as its marker (see `_live_render_source!`), whose beam is drawn when it is dropped.
"""
function _ghost!(gui::LiveView, obj::BMO.AbstractObject, system)
    ghost = live_render!(gui.ax, obj; gui.components.render_kwargs...)
    _ghost_style!(gui, system, ghost)
    return ghost
end
_ghost!(gui::LiveView, src::_Source, _) = _live_render_source!(gui.ax, src;
    size = gui.beams.marker_size[], strokecolor = _marker_stroke(gui.layout))

"""
    _start_placement!(gui, obj; origin = nothing, system = _placement_system(gui, obj))

Attaches the new component or source `obj` to the mouse in the 3D view of the `gui`: it is rendered
in its pose (see `_ghost!`) without being part of the view and follows the mouse, see
`_placement_pose`, until a left click drops it, which adds it to the `system` via
[`add_component!`](@ref) with its `origin` (see `_ComponentState`). `Esc` and the spectator mode
cancel the placement, see `_cancel_placement!`; a component that is being placed already is
cancelled first. A drag still moves the camera, and presses on cards and on the layout keep their
meaning, e.g. another "Place" of the catalog. The controls ignore the mouse meanwhile: nothing is
selected or dragged.

Before the mouse enters the 3D view, the component is shown at the point of its plane (see
`_placement_plane_point`) closest to the `lookat` point of the camera. A static `obj` can not
follow the mouse and is added where it is. A source is placed by its marker, hence the markers of
the sources are shown if they were hidden.
"""
function _start_placement!(gui::LiveView, obj::Union{BMO.AbstractObject, _Source};
        origin = nothing, system = _placement_system(gui, obj))
    ctrl = gui.controls
    _check_placement_system(obj, system)
    _cancel_placement!(gui)
    # the controls ignore the mouse for one of them at a time
    _cancel_aim!(gui)
    if ctrl.spectator[]
        gui.status.text[] = "spectator mode, press v to place components"
        return nothing
    end
    if BMO.is_static(obj)
        add_component!(gui, obj; system, origin)
        return nothing
    end
    plane_point = _placement_plane_point(gui, system)
    n = _drag_normal(gui.ax.scene, ctrl)
    lookat = Vector{Float64}(cameracontrols(gui.ax.scene).lookat[])
    R0 = _pose(obj)[2]
    _set_pose_exact!(obj, lookat .- dot(lookat .- plane_point, n) .* n, R0)
    _show_placed_markers!(gui, obj)
    ghost = _ghost!(gui, obj, system)
    gui.components.placement = _Placement(obj, ghost, system, origin, R0, plane_point,
        ctrl.ignore_mouse, nothing, false)
    # The camera still gets the presses, e.g. to rotate the view
    ctrl.ignore_mouse = () -> true
    _update_placement!(gui)
    gui.status.text[] = "placing $(nameof(typeof(obj))): click to drop it, Esc to cancel"
    return nothing
end

# The markers of the sources are shown while a source is placed, which is placed by its marker
_show_placed_markers!(::LiveView, ::BMO.AbstractObject) = nothing
function _show_placed_markers!(gui::LiveView, ::_Source)
    toggle = gui.widgets.sources_toggle.active
    toggle[] || (toggle[] = true)
    return nothing
end

"""Ends the placement of the `gui`: removes the ghost and gives the mouse back to the controls."""
function _end_placement!(gui::LiveView)
    p = gui.components.placement
    isnothing(p) && return nothing
    gui.components.placement = nothing
    gui.controls.ignore_mouse = p.ignore_mouse
    remove_render!(p.ghost)
    return p
end

"""Cancels the placement of a component of the `gui`, nothing without one, see `_start_placement!`."""
function _cancel_placement!(gui::LiveView)
    isnothing(_end_placement!(gui)) || (gui.status.text[] = "placement cancelled")
    return nothing
end

"""
Adds the component that is being placed in the `gui` to its system in its current pose. The window
of the catalog closes then, unless it is pinned, see `_close_unpinned_catalog!`.
"""
function _drop_placement!(gui::LiveView)
    p = _end_placement!(gui)
    isnothing(p) && return nothing
    add_component!(gui, p.obj; system = p.system, origin = p.origin)
    _close_unpinned_catalog!(gui)
    return nothing
end

"""
A left click into the 3D view of the `gui`, i.e. a press and a release less than the
`drag_threshold` of the controls apart, drops the component that is being placed; a drag is left
to the camera. The events are passed on.
"""
function _placement_click!(gui::LiveView, event)
    p = gui.components.placement
    (isnothing(p) || event.button != Mouse.left) && return nothing
    scene = gui.ax.scene
    if event.action == Mouse.press
        p.press = _placement_mouse_in_view(gui, p) ? _px(scene) : nothing
    elseif event.action == Mouse.release
        press = p.press
        p.press = nothing
        isnothing(press) && return nothing
        hypot((_px(scene) .- press)...) < gui.controls.drag_threshold && _drop_placement!(gui)
    end
    return nothing
end

"""
Connects the placement of new components of the `gui`, see `_start_placement!`: the mouse moves
the component, a click drops it, `Esc` and the spectator mode cancel it. The listeners run before
the controls (200) and do nothing while no component is being placed.
"""
function _connect_placement!(gui::LiveView)
    ev = events(gui.ax.scene)
    listeners = gui.controls.listeners
    push!(listeners, on(ev.mouseposition; priority = 210) do _
        _update_placement!(gui)
        return Consume(false)
    end)
    push!(listeners, on(ev.mousebutton; priority = 210) do event
        _placement_click!(gui, event)
        return Consume(false)
    end)
    push!(listeners, on(ev.keyboardbutton; priority = 210) do event
        (_placing(gui) && event.action == Keyboard.press && event.key == Keyboard.escape) ||
            return Consume(false)
        gui.controls.ignore_keys() && return Consume(false)
        _cancel_placement!(gui)
        return Consume(true)
    end)
    push!(listeners, on(v -> v && _cancel_placement!(gui), gui.controls.spectator))
    return nothing
end
