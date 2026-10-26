#=
The saved views in the debug mode (see `_Debug` in `src/LiveDebug.jl`): a camera per view, as in
Blender, which shows where the views menu would take the camera, see `_DebugViews`
=#

# z translation of the plots in their pixel scene, see `_RAYS_Z`: below the ends of the beams
const _VIEWS_Z = 8990.0f0
# The depth of the frustum of a camera as a fraction of the radius of the scene, see `_scene_bounds`
const _VIEWS_SIZE = 0.15
# The distance of the mouse to the lines of a camera that highlights it [px]
const _VIEWS_HOVER_PX = 8.0f0
# The opacity of the frustum of the highlighted camera up to the plane of its pivot
const _VIEWS_FULL_ALPHA = 0.35f0

"""
    _DebugViews <: _DebugLayer

The layer `:views` of the debug mode: a camera per saved view of the views menu and of the home
view (`views`, `name => (eye, lookat, up)`, the home view gray and named "home"), drawn like the
cameras of Blender: the frustum, a pyramid from the eye to a rectangle `_VIEWS_SIZE` of the radius
of the scene ahead with the field of view and the aspect of the 3D view (a box in the orthographic
projection), the up triangle above it, the dashed sight line to the pivot of the view (`lookat`)
and its name. A view whose eye is the eye of the camera is not drawn, the window looks through it.

The camera under the mouse (`hover`, an index of `views` or 0) is highlighted, i.e. drawn thicker
with its frustum up to the plane of its pivot, which is the area the view frames there, and its
label gives its eye and pivot (see `_view_label`); it is not clickable. `key` is the views and
the home view that `views` was made from, compared at each tick (see `_layer_tick!`), such that a
view saved while the mode is on appears.

Like the diagnostics of the rays (see `_DebugRays`), the plots lie in a child scene of the 3D scene
with a pixel camera (`hud`), at the projections of the 3D points, and are not inspectable, clipped
or fitted. They are shown while the mode is (`on`).
"""
mutable struct _DebugViews <: _DebugLayer
    const scene::Makie.Scene
    const hud::Makie.Scene
    const views::Vector{Pair{String, NTuple{3, Vector{Float64}}}}
    const plots::Dict{Symbol, AbstractPlot}
    key::UInt
    hover::Int
    on::Bool
end

function _new_layer(gui::LiveView, ::Val{:views})
    scene = gui.ax.scene
    hud = Makie.campixel(scene)
    common = (; visible = false, inspectable = false, transparency = false, clip_planes = Plane3f[])
    none = RGBAf[]
    plots = Dict{Symbol, AbstractPlot}()
    plots[:full] = linesegments!(hud, Point2f[]; common..., color = none, linewidth = 1)
    plots[:sights] = linesegments!(hud, Point2f[]; common..., color = none, linewidth = 1,
        linestyle = :dash)
    plots[:frames] = linesegments!(hud, Point2f[]; common..., color = none, linewidth = 1.5)
    plots[:highlight] = linesegments!(hud, Point2f[]; common..., color = none, linewidth = 2.5)
    plots[:pivots] = scatter!(hud, Point2f[]; common..., color = none, markersize = 6,
        strokecolor = :white, strokewidth = 1)
    plots[:labels] = text!(hud, Point2f[]; common..., text = String[], color = none, fontsize = 12,
        font = :bold, offset = Vec2f(-6, 4), align = (:right, :bottom), glowwidth = 3,
        glowcolor = (:white, 0.9))
    # In this order: the frustum to the pivot and the sight lines below the cameras, the names on top
    for (k, name) in enumerate((:full, :sights, :frames, :highlight, :pivots, :labels))
        translate!(plots[name], 0, 0, _VIEWS_Z + k)
    end
    v = _DebugViews(scene, hud, Pair{String, NTuple{3, Vector{Float64}}}[], plots, UInt(0), 0, false)
    # The projections follow the camera and the size of the view while they are shown
    Makie.onany(Makie.camera(scene).projectionview, Makie.viewport(scene)) do _, _
        v.on && _project_views!(gui, v)
        return nothing
    end
    # The camera under the mouse; the events are passed on
    on(events(scene).mouseposition; priority = -1) do _
        v.on && _hover_view!(gui, v)
        return Consume(false)
    end
    return v
end

function _layer_show!(gui::LiveView, v::_DebugViews, on::Bool)
    v.on = on
    on && _collect_views!(gui, v)
    on || _set_view_hover!(gui, v, 0)
    on && _project_views!(gui, v)
    foreach(p -> p.visible[] == on || (p.visible = on), values(v.plots))
    return nothing
end

# A new saved view or a new home view is drawn at the next tick
function _layer_tick!(gui::LiveView, v::_DebugViews, _)
    v.on || return nothing
    hash(_view_key(gui)) == v.key && return nothing
    _collect_views!(gui, v)
    _project_views!(gui, v)
    return nothing
end

_view_key(gui::LiveView) = (gui.camera.home_set, gui.camera.home, gui.camera.views)

# The views of the cameras of `v`: the home view, once the window has set it, and the saved views
function _collect_views!(gui::LiveView, v::_DebugViews)
    c = gui.camera
    empty!(v.views)
    c.home_set && push!(v.views, "home" => c.home)
    append!(v.views, c.views)
    v.key = hash(_view_key(gui))
    v.hover = min(v.hover, length(v.views))
    return nothing
end

"""
    _view_glyph(view, s, fov, aspect, ortho; full = false) -> (frame, sight)

The 3D lines of the camera of the `view` `(eye, lookat, up)` in pairs of start and end [m]: the
frustum with a rectangle `s` ahead of the eye (up to the plane of the pivot with `full`), whose
half height is its distance times `tan(fov / 2)` [°] and whose width is `aspect` times its height,
and the up triangle above it (`frame`), and the sight line from the eye to the pivot (`sight`).
In the orthographic projection (`ortho`), the frustum is a box of the size of the rectangle.
"""
function _view_glyph(view, s, fov, aspect, ortho::Bool; full::Bool = false)
    eye, lookat, up = view
    d = lookat .- eye
    dist = norm(d)
    d = d ./ dist
    r = normalize(cross(d, up))
    u = cross(r, d)
    depth = full ? dist : s
    h = depth * tand(fov / 2)
    w = aspect * h
    c = eye .+ depth .* d
    corner(x, y, at) = Point3f(at .+ x * w .* r .+ y * h .* u)
    far = [corner(1, 1, c), corner(-1, 1, c), corner(-1, -1, c), corner(1, -1, c)]
    near = ortho ? [corner(1, 1, eye), corner(-1, 1, eye), corner(-1, -1, eye), corner(1, -1, eye)] :
           fill(Point3f(eye), 4)
    frame = Point3f[]
    for k in 1:4
        push!(frame, near[k], far[k], far[k], far[mod1(k + 1, 4)])
        ortho && push!(frame, near[k], near[mod1(k + 1, 4)])
    end
    if !full
        top = [corner(0.6, 1.15, c), corner(-0.6, 1.15, c), corner(0, 1.75, c)]
        push!(frame, top[1], top[2], top[2], top[3], top[3], top[1])
    end
    return frame, Point3f[Point3f(eye), Point3f(lookat)]
end

"""
    _project_views!(gui, v::_DebugViews)

Draws the cameras of `v` (see `_DebugViews`) with the current camera of the `gui`: the projections
of their 3D lines into the pixel scene, the views of the home view in the color `muted` of the
theme, the others in its `accent`. Points behind the camera are `NaN`, which is not drawn.
"""
function _project_views!(gui::LiveView, v::_DebugViews)
    t = gui.layout.theme
    cam = cameracontrols(v.scene)
    pv = Makie.camera(v.scene).projectionview[]
    wh = Makie.widths(Makie.viewport(v.scene)[])
    fov = Float64(cam.fov[])
    aspect = wh[1] / max(wh[2], 1)
    ortho = cam.settings.projectiontype[] != Makie.Perspective
    s = _VIEWS_SIZE * _scene_bounds(gui)[2]
    eye = Vector{Float64}(cam.eyeposition[])
    frames, highlight, full, sights = Point2f[], Point2f[], Point2f[], Point2f[]
    frame_colors, highlight_colors, full_colors, sight_colors = RGBAf[], RGBAf[], RGBAf[], RGBAf[]
    pivots, pivot_colors, labels, texts, label_colors = Point2f[], RGBAf[], Point2f[], String[], RGBAf[]
    for (i, (name, view)) in enumerate(v.views)
        _view_drawn(view, eye, s) || continue
        color = RGBAf(_is_home(gui, i) ? t.muted : t.accent)
        frame, sight = _view_glyph(view, s, fov, aspect, ortho)
        lines, colors = i == v.hover ? (highlight, highlight_colors) : (frames, frame_colors)
        append!(lines, _rays_px(pv, wh, frame))
        append!(colors, fill(color, length(frame)))
        append!(sights, _rays_px(pv, wh, sight))
        append!(sight_colors, fill(color, 2))
        if i == v.hover
            whole, _ = _view_glyph(view, s, fov, aspect, ortho; full = true)
            append!(full, _rays_px(pv, wh, whole))
            append!(full_colors, fill(RGBAf(RGBf(color), _VIEWS_FULL_ALPHA), length(whole)))
        end
        push!(pivots, only(_rays_px(pv, wh, [Point3f(view[2])])))
        push!(pivot_colors, color)
        push!(labels, only(_rays_px(pv, wh, [Point3f(view[1])])))
        push!(texts, _view_label(name, view, i == v.hover))
        push!(label_colors, color)
    end
    p = v.plots
    Makie.update!(p[:frames], frames; color = frame_colors)
    Makie.update!(p[:highlight], highlight; color = highlight_colors)
    Makie.update!(p[:full], full; color = full_colors)
    Makie.update!(p[:sights], sights; color = sight_colors)
    Makie.update!(p[:pivots], pivots; color = pivot_colors)
    Makie.update!(p[:labels], labels; text = texts, color = label_colors)
    return nothing
end

# Whether the view `i` of the layer of the `gui` is the home view, see `_collect_views!`
_is_home(gui::LiveView, i::Int) = i == 1 && gui.camera.home_set

# Whether the camera of the `view` is drawn: not if its eye is the `eye` of the window (within a
# hundredth of the size `s` of a camera), which looks through it
_view_drawn(view, eye, s) = norm(view[1] .- eye) > 0.01 * s

"""
    _hover_view!(gui, v::_DebugViews)

Highlights the camera of `v` whose lines are nearest to the mouse, within `_VIEWS_HOVER_PX`, while
the mouse is in the 3D view and not over its widgets (see `ignore_mouse` of the controls); none
otherwise.
"""
function _hover_view!(gui::LiveView, v::_DebugViews)
    scene = v.scene
    i = 0
    if Makie.is_mouseinside(scene) && !gui.controls.ignore_mouse()
        m = Point2f(events(scene).mouseposition[]) .- Point2f(Makie.origin(Makie.viewport(scene)[]))
        i = _view_at(gui, v, m)
    end
    _set_view_hover!(gui, v, i)
    return nothing
end

# The index of the camera of `v` whose frame is nearest to the pixel `m` of the 3D view, within
# `_VIEWS_HOVER_PX`, or 0
function _view_at(gui::LiveView, v::_DebugViews, m::Point2f)
    cam = cameracontrols(v.scene)
    pv = Makie.camera(v.scene).projectionview[]
    wh = Makie.widths(Makie.viewport(v.scene)[])
    ortho = cam.settings.projectiontype[] != Makie.Perspective
    s = _VIEWS_SIZE * _scene_bounds(gui)[2]
    eye = Vector{Float64}(cam.eyeposition[])
    best, nearest = 0, _VIEWS_HOVER_PX
    for (i, (_, view)) in enumerate(v.views)
        _view_drawn(view, eye, s) || continue
        frame, _ = _view_glyph(view, s, Float64(cam.fov[]), wh[1] / max(wh[2], 1), ortho)
        ps = _rays_px(pv, wh, frame)
        for k in 1:2:length(ps)
            dist = _segment_distance(m, ps[k], ps[k + 1])
            dist < nearest && ((best, nearest) = (i, dist))
        end
    end
    return best
end

# The distance [px] of the point `m` to the segment from `a` to `b`, `Inf` if it is not drawn
function _segment_distance(m::Point2f, a::Point2f, b::Point2f)
    (all(isfinite, a) && all(isfinite, b)) || return Inf32
    ab = b - a
    l2 = dot(ab, ab)
    t = l2 > 0 ? clamp(dot(m - a, ab) / l2, 0, 1) : 0.0f0
    return norm(m - (a + t * ab))
end

"""
    _set_view_hover!(gui, v::_DebugViews, i)

Highlights the camera `i` of `v`, 0 for none, see `_DebugViews`.
"""
function _set_view_hover!(gui::LiveView, v::_DebugViews, i::Int)
    i == v.hover && return nothing
    v.hover = i
    v.on && _project_views!(gui, v)
    return nothing
end

# The label of the camera of the `view` named `name`: with its eye and pivot [mm] if it is
# `highlighted`. Not a tooltip of the window: that lies in its root scene, and GLMakie draws the
# transparent beams of the 3D view over it
function _view_label(name, view, highlighted::Bool)
    highlighted || return name
    return "$name\neye $(_mm_point(view[1]))\npivot $(_mm_point(view[2]))"
end

# A point [m] in mm, e.g. "(250.0, 150.0, 70.0) mm"
_mm_point(p) = "(" * join((string(round(1e3 * x; digits = 1)) for x in p), ", ") * ") mm"
