#=
Camera tools
=#

const _CAMERA_HELP = _HelpSection[
    "Select" => [_HelpEntry(["G"], "zoom to the selection")],
    "Trace" => [
        _HelpEntry(["T"], "trace now"),
        _HelpEntry([:mouse => "click"], "Cancel in the progress window: stop a long trace"),
        _HelpEntry([:mouse => "click"], "on a beam: inspect it")]]

"""
    _CameraAnimation

State of the animated transition of the camera of a `LiveView` to a new view, see
`_animate_camera!`. Like `_CubeAnimation`, the direction from `lookat` to the eye is rotated by
`angle` about `axis` and the up vector is rolled by `roll`, while `lookat` and the distance `dist`
of the eye are interpolated linearly.
"""
mutable struct _CameraAnimation
    lookat0::Vector{Float64}
    dist0::Float64
    o0::Vector{Float64}
    u0::Vector{Float64}
    # target view, applied as given at the end
    eye1::Vector{Float64}
    lookat1::Vector{Float64}
    up1::Vector{Float64}
    dist1::Float64
    axis::Vector{Float64}
    angle::Float64
    roll::Float64
    duration::Float64
    elapsed::Float64
end

"""Returns the current view `(eye, lookat, up)` of the 3D view of the `gui`."""
function _current_view(gui::LiveView)
    cam = cameracontrols(gui.ax.scene)
    return (Vector{Float64}(cam.eyeposition[]), Vector{Float64}(cam.lookat[]),
        Vector{Float64}(cam.upvector[]))
end

"""Applies the frame at the fraction `t` of the animation `a` to the camera of the `gui`."""
function _apply_camera_frame!(gui::LiveView, a::_CameraAnimation, t)
    if t >= 1
        set_view(gui.ax, a.eye1, a.lookat1, a.up1)
        return nothing
    end
    # Smooth start and stop
    τ = t^2 * (3 - 2t)
    o = normalize(_rotate(a.o0, a.axis, τ * a.angle))
    up = normalize(_rotate(_rotate(a.u0, a.axis, τ * a.angle), o, τ * a.roll))
    lookat = a.lookat0 .+ τ .* (a.lookat1 .- a.lookat0)
    dist = a.dist0 + τ * (a.dist1 - a.dist0)
    set_view(gui.ax, lookat .+ dist .* o, lookat, up)
    return nothing
end

"""Advances the camera animation of the `gui` by `dt` [s]. A new animation of the view cube wins."""
function _step_camera!(gui::LiveView, dt)
    a = gui.camera.animation
    isnothing(a) && return nothing
    if !isnothing(gui.widgets.view_cube) && !isnothing(gui.widgets.view_cube.anim)
        gui.camera.animation = nothing
        return nothing
    end
    a.elapsed += dt
    t = a.duration > 0 ? min(a.elapsed / a.duration, 1.0) : 1.0
    t >= 1 && (gui.camera.animation = nothing)
    _apply_camera_frame!(gui, a, t)
    return nothing
end

# The marker of the pivot is opaque for `_PIVOT_HOLD` [s] after the last move of the camera, then
# fades within `_PIVOT_FADE` [s]
const _PIVOT_HOLD = 0.3
const _PIVOT_FADE = 0.4

# The gestures that have arrows next to the marker of the pivot, see `_pivot_gesture`
const _PIVOT_GESTURES = (:rotate, :pan, :zoom_in, :zoom_out)

"""
    _PivotGlyph

The arrows of a gesture next to the marker of the pivot, see `_draw_pivot!`: the `halo` lines in
the color of the background of the 3D view below the lines and heads `fg` in the accent color.
"""
struct _PivotGlyph
    halo::Vector{AbstractPlot}
    fg::Vector{AbstractPlot}
end

"""
    _step_pivot!(gui, dt)

Advances the marker of the pivot of the camera of the `gui` by `dt` [s]: a dot at the `lookat`
point, the point `Camera3D` turns about, with a small camera beside it, shown while the view
changes (drags, scroll, keys, `g`, the view cube, home, the views menu, scripts) and faded shortly
after it stops, see `_PIVOT_HOLD` and `_PIVOT_FADE`. Arrows about it show the gesture of the last
move, see `_pivot_gesture`.
Like the other overlays, it is never selected or traced.
"""
function _step_pivot!(gui::LiveView, dt)
    c = gui.camera
    view = c.pivot_moved ? _current_view(gui) : c.pivot_view
    gesture = c.pivot_moved ? _pivot_gesture(c.pivot_view, view) : :still
    c.pivot_moved = false
    # `Camera3D` sets the view again when a drag ends, which is no move
    if gesture === :still
        isfinite(c.pivot_idle) && (c.pivot_idle += dt)
    else
        c.pivot_idle = 0.0
        c.pivot_gesture = gesture
        c.pivot_view = view
    end
    _update_pivot!(gui)
    return nothing
end

"""
    _pivot_gesture(v0, v1) -> Symbol

Returns the gesture that changed the view `v0` to `v1` (each `(eye, lookat, up)`): `:still` if it
did not change, `:zoom_in` or `:zoom_out` if only the distance of the eye to `lookat` changed (the
scroll zoom of `Camera3D` also shifts both by the same vector), `:pan` if both were shifted by the
same vector, `:rotate` if `lookat` and the distance were kept, and `:none` otherwise, e.g. for
the animation of `g`. The tolerance is relative to the coordinates as well, since a view set by
`set_view` is rounded to `Float32`.
"""
function _pivot_gesture(v0, v1)
    (e0, l0, u0), (e1, l1, u1) = v0, v1
    d0, d1 = e0 .- l0, e1 .- l1
    n0, n1 = norm(d0), norm(d1)
    tol = 1e-5 * max(n0, norm(e0), norm(l0), eps())
    shifted = norm(l1 .- l0) > tol
    !shifted && norm(e1 .- e0) <= tol && norm(u1 .- u0) <= 1e-5 * max(norm(u0), eps()) && return :still
    if n0 > tol && n1 > tol && abs(n1 - n0) > tol && norm(d1 ./ n1 .- d0 ./ n0) <= tol / n0
        return n1 < n0 ? :zoom_in : :zoom_out
    end
    norm(d1 .- d0) <= tol && return shifted ? :pan : :rotate
    !shifted && abs(n1 - n0) <= tol && return :rotate
    return :none
end

"""Returns the opacity of the marker of the pivot of the `gui`, see `_step_pivot!`."""
_pivot_alpha(gui::LiveView) = clamp(1 - (gui.camera.pivot_idle - _PIVOT_HOLD) / _PIVOT_FADE, 0.0, 1.0)

"""
    _pivot_arrows(gesture) -> (lines, heads)

Returns the arrows of the `gesture` (see `_PIVOT_GESTURES`) next to the marker of the pivot, in
pixels about its center: the `lines`, separated by `NaN`, and the `heads` as pairs of position and
direction [rad]. Two arcs for `:rotate`, four arrows for `:pan`, four diagonal arrows outwards for
`:zoom_in` and inwards for `:zoom_out`.
"""
function _pivot_arrows(gesture::Symbol)
    lines, heads = Point2f[], Tuple{Point2f, Float64}[]
    # straight from `a` to `b` along `d`, the head at `b`
    function arrow!(d, a, b)
        u = normalize(Makie.Vec2f(d...))
        append!(lines, (Point2f(a .* u), Point2f(b .* u), Point2f(NaN, NaN)))
        t = (b - a) .* u
        push!(heads, (Point2f(b .* u), atan(t[2], t[1])))
    end
    # counterclockwise from `φ0` to `φ1`, the head at `φ1`
    function arc!(φ0, φ1; r = 15)
        append!(lines, (Point2f(r * cos(φ), r * sin(φ)) for φ in range(φ0, φ1, 16)))
        push!(lines, Point2f(NaN, NaN))
        push!(heads, (Point2f(r * cos(φ1), r * sin(φ1)), φ1 + π / 2))
    end
    axes, diagonals = ((1, 0), (0, 1), (-1, 0), (0, -1)), ((1, 1), (-1, 1), (-1, -1), (1, -1))
    if gesture === :rotate
        arc!(π / 6, 5π / 6)
        arc!(7π / 6, 11π / 6)
    elseif gesture === :pan
        foreach(d -> arrow!(d, 10, 18), axes)
    elseif gesture === :zoom_in
        foreach(d -> arrow!(d, 10, 18), diagonals)
    elseif gesture === :zoom_out
        foreach(d -> arrow!(d, 18, 10), diagonals)
    end
    return lines, heads
end

"""
    _draw_pivot!(gui)

Draws the hidden marker of the pivot of the `gui`, see `_step_pivot!`: a dot at the pivot, a small
camera (the icon of the views) up right of it and the arrows of each gesture about it
(`_PivotGlyph`, see `_pivot_arrows`) in the accent color, outlined in the color of the background
of the 3D view, such that they stand out from beams and objects. Their data are about the pivot,
they are moved to it with `translate!`. They are
in a scene of pixels over the 3D view, like the cards: GLMakie draws the transparent plots of the
3D view, e.g. the beams, after all opaque ones, even after those with `overdraw`, so a beam
through the pivot would cover a marker in the 3D view. The scene is made before the cards, which
therefore cover it.
"""
function _draw_pivot!(gui::LiveView)
    scene = Scene(gui.fig.scene; camera = Makie.campixel!, clear = false)
    accent, outline = gui.layout.theme.accent, _pivot_outline(gui, 1.0)
    common = (; visible = false, inspectable = false)
    for gesture in _PIVOT_GESTURES
        lines, heads = _pivot_arrows(gesture)
        halo = lines!(scene, lines; color = outline, linewidth = 3.5, common...)
        line = lines!(scene, lines; color = accent, linewidth = 1.5, common...)
        tips = scatter!(scene, first.(heads); marker = :utriangle, rotation = last.(heads) .- π / 2,
            markersize = 7, color = accent, strokecolor = outline, strokewidth = 1, common...)
        gui.camera.pivot_glyphs[gesture] = _PivotGlyph(AbstractPlot[halo], AbstractPlot[line, tips])
    end
    # The icon is an outline, a beam behind it would show through its lens
    badge = Point2f(11, 11)
    gui.camera.pivot_backdrop = scatter!(scene, [badge]; marker = :rect, markersize = Vec2f(10, 8),
        color = outline, common...)
    gui.camera.pivot_camera = scatter!(scene, [badge]; marker = _icon(:views), markersize = 13,
        color = accent, strokecolor = outline, strokewidth = 1, common...)
    gui.camera.pivot = scatter!(scene, [Point2f(0, 0)]; marker = :circle, markersize = 6,
        color = accent, strokecolor = outline, strokewidth = 1.5, common...)
    return nothing
end

# The outline of the marker of the pivot of the `gui` at the opacity `alpha`; the `alpha` of a
# scatter only applies to its `color`
_pivot_outline(gui::LiveView, alpha) = RGBAf(RGBf(Makie.to_color(gui.ax.scene.backgroundcolor[])), alpha)

# The pixel of the window at the `lookat` point of the camera of the `gui`, i.e. the center of
# its 3D view
function _pivot_px(gui::LiveView)
    scene = gui.ax.scene
    px = Makie.project(scene, Point3f(cameracontrols(scene).lookat[]))
    return Point2f(px .+ Makie.origin(Makie.viewport(scene)[]))
end

"""
    _update_pivot!(gui)

Applies the opacity and the position of the marker of the pivot of the `gui` and shows the arrows
of its gesture, see `_step_pivot!`. Hidden in the spectator mode. Attributes are only set when
they change, such that a still view is not redrawn.
"""
function _update_pivot!(gui::LiveView)
    c = gui.camera
    isnothing(c.pivot) && return nothing
    alpha = gui.controls.spectator[] ? 0.0 : _pivot_alpha(gui)
    shown = alpha > 0
    at = shown ? Vec3f(_pivot_px(gui)..., 0) : Vec3f(0)
    _set_pivot_plot!(gui, c.pivot_backdrop, shown, alpha, at, true)
    _set_pivot_plot!(gui, c.pivot_camera, shown, alpha, at, false)
    _set_pivot_plot!(gui, c.pivot, shown, alpha, at, false)
    for (gesture, glyph) in c.pivot_glyphs
        on = shown && gesture === c.pivot_gesture
        foreach(p -> _set_pivot_plot!(gui, p, on, alpha, at, true), glyph.halo)
        foreach(p -> _set_pivot_plot!(gui, p, on, alpha, at, false), glyph.fg)
    end
    return nothing
end

# Shows the plot `p` of the marker of the pivot of the `gui` at the pixel `at` with the opacity
# `alpha`, or hides it; a `halo` has the color of the background, the others the accent color and,
# if they are scatters, the background as stroke
function _set_pivot_plot!(gui::LiveView, p::AbstractPlot, shown::Bool, alpha, at, halo::Bool)
    if shown
        Makie.translation(p)[] == at || translate!(p, at)
        outline = _pivot_outline(gui, alpha)
        if halo
            _update_attr!(p.color, outline)
        else
            _update_attr!(p.color, gui.layout.theme.accent)
            p isa Makie.Scatter && _update_attr!(p.strokecolor, outline)
        end
    end
    halo || _update_attr!(p.alpha, alpha)
    _update_attr!(p.visible, shown)
    return nothing
end

# Sets the attribute `x` of a plot to `value` if it differs, see `_update!` for observables
_update_attr!(x, value) = (x[] == value || (x[] = value); nothing)

"""
    _animate_camera!(gui, eye, lookat, up)

Moves the camera of the `gui` to the view `eye`, `lookat`, `up`, animated over the duration of the
view cube (0.3 s without a view cube), driven by `tick` events.
"""
function _animate_camera!(gui::LiveView, eye, lookat, up)
    eye0, lookat0, up0 = _current_view(gui)
    d0, d1 = eye0 .- lookat0, Vector{Float64}(eye) .- Vector{Float64}(lookat)
    dist0, dist1 = norm(d0), norm(d1)
    o0 = dist0 > 0 ? d0 ./ dist0 : [0.0, 0.0, 1.0]
    o1 = dist1 > 0 ? d1 ./ dist1 : o0
    u0 = something(_orthogonalize(up0, o0), _perp(o0))
    u1 = something(_orthogonalize(Vector{Float64}(up), o1), _perp(o1))
    axis, angle = _rotation_between(o0, o1, cross(o0, u0))
    ur = _rotate(u0, axis, angle)
    roll = atan(dot(cross(ur, u1), o1), dot(ur, u1))
    duration = isnothing(gui.widgets.view_cube) ? 0.3 : gui.widgets.view_cube.duration
    isnothing(gui.widgets.view_cube) || (gui.widgets.view_cube.anim = nothing)
    gui.camera.animation = _CameraAnimation(lookat0, dist0, o0, u0, Vector{Float64}(eye),
        Vector{Float64}(lookat), Vector{Float64}(up), dist1, axis, angle, roll, duration, 0.0)
    duration > 0 || _step_camera!(gui, 0.0)
    return nothing
end

"""
    _zoom_box(gui)

Returns the bounding box of the plots of the selected object of the `gui`, or of all systems and
the visible extras if nothing is selected, or `nothing` if there are no visible plots.
"""
function _zoom_box(gui::LiveView)
    ctrl = gui.controls
    obj = ctrl.selected[]
    isnothing(obj) || return _selection_bbox(ctrl, obj, _object_plots(ctrl.h, obj))
    return _visible_bbox((gui.system_handles..., gui.extras))
end

"""
    _visible_bbox(handles) -> Union{Rect3d, Nothing}

Returns the bounding box of the visible plots of the objects of the `handles` (system handles,
e.g. of the systems and the extras of a live view), or `nothing` if there are none.
"""
function _visible_bbox(handles)
    bbs = [Makie.boundingbox(p) for h in handles for p in render_plots(h) if p.visible[]]
    filter!(_is_finite_box, bbs)
    return isempty(bbs) ? nothing : reduce(GeometryBasics.union, bbs)
end

"""
Size of the scene of the `handles` (see `_visible_bbox`): the largest edge of its bounding box, or
0.125 m for an empty scene. Sets the size of the source markers and of new clip planes.
"""
function _scene_extent(handles)
    bb = _visible_bbox(handles)
    return isnothing(bb) ? 0.125 : Float64(maximum(GeometryBasics.widths(bb)))
end

# The size [m] of the part of an empty view around the origin that the camera shows
const _EMPTY_VIEW_SIZE = 0.4

"""Whether the `gui` shows nothing yet: no object of a system, no extra and no source."""
_view_empty(gui::LiveView) = isempty(gui.pairs) &&
    all(h -> isempty(render_children(h)), (gui.system_handles..., gui.extras))

"""
    _show_origin!(gui)

Points the camera of an empty view (see `_view_empty`) at the origin, from its direction and at the
distance at which `_EMPTY_VIEW_SIZE` fills the view; nothing for a view with content. Makie centers
the camera on the content of the scene when the window is shown, which without content is no place
of the setup, whereas the first component or source is placed at the origin, see `_start_placement!`.
"""
function _show_origin!(gui::LiveView)
    _view_empty(gui) || return nothing
    cam = cameracontrols(gui.ax.scene)
    eye, lookat, up = _current_view(gui)
    o = norm(eye .- lookat) > 0 ? normalize(eye .- lookat) : normalize([1.0, -1.0, 1.0])
    d = _EMPTY_VIEW_SIZE
    dist = cam.settings.projectiontype[] == Makie.Perspective ? (d / 2) / sind(cam.fov[] / 2) : d / 2
    set_view(gui.ax, dist .* o, zeros(3), up)
    return nothing
end

"""
    _zoom_to_selection!(gui)

Moves the camera of the `gui` such that the bounding sphere of the selected object, or of all
systems and the visible extras if nothing is selected (see `_zoom_box`), fills the view: `lookat`
is set to the center of the bounding box, the eye to the distance `(d/2) / sin(fov/2)`
(orthographic: `d/2`) along the current view direction, where `d` is the diagonal of the box.
"""
function _zoom_to_selection!(gui::LiveView)
    bb = _zoom_box(gui)
    if isnothing(bb)
        gui.status.text[] = "nothing to zoom to"
        return nothing
    end
    center = Vector{Float64}(minimum(bb) .+ GeometryBasics.widths(bb) ./ 2)
    d = max(norm(Vector{Float64}(GeometryBasics.widths(bb))), 1e-6)
    cam = cameracontrols(gui.ax.scene)
    # The orthographic view is scaled by the distance of the eye, which is its half height
    dist = cam.settings.projectiontype[] == Makie.Perspective ? (d / 2) / sind(cam.fov[] / 2) : d / 2
    eye, lookat, up = _current_view(gui)
    o = norm(eye .- lookat) > 0 ? normalize(eye .- lookat) : [0.0, 0.0, 1.0]
    _animate_camera!(gui, center .+ dist .* o, center, up)
    return nothing
end

"""Validates the `views` kwarg of `live_view` and returns a vector of `name => (eye, lookat, up)`."""
function _view_specs(views)
    specs = Pair{String, NTuple{3, Vector{Float64}}}[]
    for v in views
        ok = v isa Pair && v.second isa Tuple && length(v.second) == 3 &&
             all(x -> x isa AbstractVector{<:Real} && length(x) == 3, v.second)
        ok || throw(ArgumentError("invalid view $v, use \"name\" => (eye, lookat, up)"))
        push!(specs, string(v.first) => Tuple(Vector{Float64}.(v.second)))
    end
    return specs
end

"""Returns the options of the views menu, the option `i` sets `views[i]`."""
function _views_options(views)
    isempty(views) && return [("no views", 0)]
    return [(name, i) for (i, (name, _)) in enumerate(views)]
end

"""Sets the camera of the `gui` to the saved view `i`, see `views`."""
function _set_saved_view!(gui::LiveView, i)
    1 <= i <= length(gui.camera.views) || return nothing
    name, (eye, lookat, up) = gui.camera.views[i]
    _animate_camera!(gui, eye, lookat, up)
    gui.status.text[] = "view \"$name\""
    return nothing
end

"""
    _save_view!(gui; io = stdout)

Appends the current view of the `gui` as `"view n"` to the saved views and prints it as the Julia
code of an entry of the `views` kwarg of `live_view` to `io`. Returns the code.
"""
function _save_view!(gui::LiveView; io::IO = stdout)
    n = length(gui.camera.views) + 1
    names = Set(first.(gui.camera.views))
    while "view $n" in names
        n += 1
    end
    name = "view $n"
    view = _current_view(gui)
    push!(gui.camera.views, name => view)
    gui.widgets.views_menu.options[] = _views_options(gui.camera.views)
    code = "$(repr(name)) => ($(join(_vector_code.(view), ", ")))"
    println(io, code)
    gui.status.text[] = "saved $(repr(name)), printed as code"
    return code
end

"""Restores the home view of the `gui`, i.e. the view when the window was shown."""
function _go_home!(gui::LiveView)
    _animate_camera!(gui, gui.camera.home...)
    gui.status.text[] = "home view"
    return nothing
end

"""
    _keep_camera!(gui)

Keeps the view of the `gui` when plots are added to the open window, e.g. an overlay of a beam, a
clip plane or a measurement: Makie's `plot!` into the `LScene` then calls `reset_limits!`, whose
`center!` would move the camera to fit the scene. Called once the window is shown, after the view
was fitted to the scene; `center!` then only updates the bounds of the camera (and its depth
range). The reset key of `Camera3D` (Ctrl + left click) is taken by the selection, see
[`kinematic_controls!`](@ref); the home button fits the view.
"""
_keep_camera!(gui::LiveView) = (cameracontrols(gui.ax.scene).settings.center[] = false; nothing)

"""
Connects the camera tools of the `gui`: the key `g` (zoom to the selection), the home button, the
views menu and the save view button, and the animation and the home view via `tick`.
"""
function _connect_camera!(gui::LiveView)
    listeners = gui.controls.listeners
    scene = gui.ax.scene
    push!(listeners, on(events(scene).keyboardbutton, priority = 200) do event
        (event.action == Keyboard.press && event.key == Keyboard.g) || return Consume(false)
        # Ctrl+G groups the selection, see `_connect_group_keys!`
        _modifier_held(scene, _CTRL_OR_CMD_KEYS) && return Consume(false)
        gui.controls.ignore_keys() && return Consume(false)
        _zoom_to_selection!(gui)
        return Consume(true)
    end)
    push!(listeners, on(events(scene).tick) do tick
        # The home view is the view when the window is shown, e.g. after `set_view`
        if !gui.camera.home_set
            # An empty view has nothing that Makie could center the camera on
            _show_origin!(gui)
            gui.camera.home = _current_view(gui)
            gui.camera.home_set = true
            _keep_camera!(gui)
            # Fitting the view is no move of the user
            gui.camera.pivot_moved = false
            gui.camera.pivot_view = gui.camera.home
        end
        _step_camera!(gui, tick.delta_time)
        _step_pivot!(gui, tick.delta_time)
        return nothing
    end)
    # Camera3D sets these one after the other, the next tick shows the marker of the pivot
    cam = cameracontrols(scene)
    for obs in (cam.lookat, cam.eyeposition, cam.upvector)
        push!(listeners, on(_ -> (gui.camera.pivot_moved = gui.camera.home_set; nothing), obs))
    end
    _draw_pivot!(gui)
    # The textboxes of the cards are connected with their cards, see `_connect_card!`, those of the
    # layout (see `_layout_boxes`) by the layout
    for obs in (cameracontrols(scene).selected, _open_observable(gui.widgets.menu), gui.widgets.views_menu.is_open)
        _listen!(listeners, _ -> _keep_keyboard!(gui), obs)
    end
    _keep_keyboard!(gui)
    push!(listeners, on(_ -> _go_home!(gui), gui.widgets.home_button.clicks))
    push!(listeners, on(i -> _set_saved_view!(gui, something(i, 0)), gui.widgets.views_menu.i_selected))
    push!(listeners, on(_ -> _save_view!(gui), gui.widgets.save_view_button.clicks))
    append!(gui.controls.help_extra, _CAMERA_HELP)
    _update_help!(gui.controls)
    return nothing
end

"""
    _connect_projection!(gui, orthographic)

Connects the orthographic toggle of the `gui` and sets the initial projection.

The orthographic `Camera3D` scales the view with the distance between eye and `lookat` and clips
the scene at `near`/`far` in front of the eye. Zooming in, or moving along the view direction, then
moves the eye into the scene: the near plane cuts through it like a clip plane, while the view
itself stays the same. In orthographic mode the depth range is therefore static and reaches from
behind the eye (negative `near`) past the far side of the scene, updated whenever the eye moves.
The scene bounds are taken when switching to orthographic, with a margin of one radius for later
moves of objects. Makie's `center!`, called e.g. by `reset_limits!` when a plot is added to the
open window or by `save` without `update = false`, replaces the depth range with a positive one;
it is restored, with new scene bounds, before the camera applies it.

Moving along the view direction does not change an orthographic view at all, so the keys for it
(`W`/`S` of `Camera3D`) zoom there, like the zoom keys (`U`/`O`).
"""
function _connect_projection!(gui::LiveView, orthographic::Bool)
    cam = cameracontrols(gui.ax.scene)
    settings, controls = cam.settings, cam.controls
    perspective_depth = (settings.clipping_mode[], cam.near[], cam.far[])
    walk_keys = (controls.forward_key[], controls.backward_key[], controls.zoom_in_key[],
        controls.zoom_out_key[])
    bounds = Ref((zeros(3), 1.0))
    is_ortho() = settings.projectiontype[] != Makie.Perspective
    # Silent updates: every camera move calls `update_cam!` after setting the eye position
    function set_depth!()
        center, radius = bounds[]
        d = norm(Vector{Float64}(cam.eyeposition[]) .- center) + 2 * radius
        cam.near.val = -d
        cam.far.val = d
        return nothing
    end
    # `false` is a key binding that is never pressed
    function set_keys!(ortho::Bool)
        forward, backward, zoom_in, zoom_out = walk_keys
        controls.forward_key[] = ortho ? false : forward
        controls.backward_key[] = ortho ? false : backward
        controls.zoom_in_key[] = ortho ? zoom_in | forward : zoom_in
        controls.zoom_out_key[] = ortho ? zoom_out | backward : zoom_out
        return nothing
    end
    function set_projection!(ortho::Bool)
        if ortho
            bounds[] = _scene_bounds(gui)
            settings.clipping_mode.val = :static
            set_depth!()
        else
            mode, near, far = perspective_depth
            settings.clipping_mode.val = mode
            cam.near.val = near
            cam.far.val = far
        end
        set_keys!(ortho)
        settings.projectiontype[] = ortho ? Makie.Orthographic : Makie.Perspective
        return nothing
    end
    listeners = gui.controls.listeners
    push!(listeners, on(set_projection!, gui.widgets.orthographic_toggle.active))
    push!(listeners, on(cam.eyeposition) do _
        is_ortho() && set_depth!()
        return nothing
    end)
    # Before the listener of the camera, which applies `near` and `far`
    for depth in (cam.near, cam.far)
        push!(listeners, on(depth; priority = 1) do _
            if is_ortho()
                bounds[] = _scene_bounds(gui)
                set_depth!()
            end
            return nothing
        end)
    end
    set_projection!(orthographic)
    return nothing
end

"""Returns the center and radius of the bounding sphere of the plots of the 3D view of the `gui`."""
function _scene_bounds(gui::LiveView)
    bb = Makie.data_limits(gui.ax.scene)
    _is_finite_box(bb) || return (zeros(3), 1.0)
    w = Vector{Float64}(GeometryBasics.widths(bb))
    return Vector{Float64}(minimum(bb)) .+ w ./ 2, max(norm(w) / 2, 1e-6)
end
