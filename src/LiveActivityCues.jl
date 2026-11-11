#=
The cues of the activity of the others in the 3D view, see `LiveActivity.jl` and
`plans/activity-cues.md` (W2).

A cue shows an episode (or a summary of several) for the life of `_CUE_IN + _CUE_HOLD + _CUE_OUT`
seconds: frames (boxes) of the objects in the colour of the participant, a dashed ghost frame at
the old place of a moved, rotated or removed object, a soft arc from the old to the new place (or
around the object for a rotation) that is drawn out during `_CUE_IN`, and a chip with the name and
the text, or the bubble of a message. All are overlays: the GUI never draws a component here. The
3D parts are plots of `gui.ax`, the chips and bubbles plots of a child scene with a pixel camera
(`_CuePlots.hud`), placed every frame at the projection of their object, like the progress window
(see `_ProgressOverlay`). A cue creates its plots when it starts and deletes them when it ends; per
frame only the colours, the positions of the chips and, while it is drawn in, the arcs change.
=#

# The width of the lines of a frame, a ghost frame and an arc [px]
const _CUE_FRAME_WIDTH = 1.5f0
const _CUE_GHOST_WIDTH = 1.25f0
const _CUE_ARC_WIDTH = 2.0f0
# The alpha of a ghost frame relative to the cue, and of all 3D parts of a summary
const _CUE_GHOST_ALPHA = 0.5
const _CUE_SUMMARY_ALPHA = 0.6
# The alpha of the ghost frames of a scrub
const _SCRUB_ALPHA = 0.85
# Points of an arc; its lift towards the camera's up vector, relative to the distance, and at least [m]
const _CUE_ARC_POINTS = 32
const _CUE_ARC_LIFT = 0.15
const _CUE_ARC_MIN_LIFT = 0.002
# A frame that is added settles from this size to 1 while the cue is drawn in
const _CUE_ADDED_SCALE = 1.1
# Size of the arrowhead and of the × of a removed object [px]
const _CUE_HEAD_SIZE = 9.0f0
const _CUE_CROSS_SIZE = 10.0f0
# Chips and bubbles [px]: font size, line height, padding, corner radius, the dot of the colour
const _CHIP_FONTSIZE = 12.0f0
const _CHIP_LINEHEIGHT = 1.3f0
const _CHIP_PAD = Vec2f(6, 3)
const _CHIP_CORNER = 6.0f0
const _CHIP_DOT = 6.0f0
const _CHIP_DOT_GAP = 5.0f0
# The alpha of the background of a chip (the theme's `view`)
const _CHIP_BACKGROUND_ALPHA = 0.92
# Distance of a chip from the top of its object, between stacked chips and from the edges of the view
const _CHIP_GAP = 8.0f0
const _CHIP_STACK = 4.0f0
const _CHIP_MARGIN = 6.0f0
# At most this many characters of the text of a chip
const _CHIP_CHARS = 56
# A bubble: the bar of the colour at its left edge, its padding, the wrap of the message
const _BUBBLE_BAR = 3.0f0
const _BUBBLE_PAD = Vec2f(8, 5)
const _BUBBLE_WRAP = 40
const _BUBBLE_LINES = 3
# z translation of the chips and bubbles: after the 3D scene and in front of it, below the cards
# (see `_CARD_Z0`) and the progress window; a newer chip over an older one
const _CHIP_Z = 9000.0f0

"""
    _CueDrawn

The plots of a cue that is shown: its `episode`, its `start` time, the `plots` of its parts by name
(`:frames`, `:ghosts`, `:arcs`, `:heads`, `:crosses` in `gui.ax`; `:background`, `:dot`, `:bar`,
`:name`, `:text` of the chip or bubble in the pixel scene), the full `arcs` (the points of each), the
frames that are `added` (centre and points at full size), the corners of the box of the object of
the chip `anchor` (empty: at the presence of the participant or the corner of the view), the size
of the chip `size`, its place in a stack of chips at one object `slot`, its position `pos` [px],
the `progress` of the arcs drawn last, and whether it is a `summary` or a `bubble`.
"""
mutable struct _CueDrawn
    episode::_Episode
    start::Float64
    plots::Dict{Symbol, Makie.AbstractPlot}
    arcs::Vector{Vector{Point3f}}
    added::Vector{Tuple{Point3f, Vector{Point3f}}}
    static::Vector{Point3f}
    anchor::Vector{Point3f}
    size::Vec2f
    slot::Int
    pos::Observable{Point2f}
    progress::Float64
    summary::Bool
    bubble::Bool
end

"""
    _CuePlots

The plots of the cues of a window (`gui.activity.cue_plots`): the child scene with a pixel camera of
the chips and bubbles `hud`, the cues `drawn`, the plot of the ghost frames of a scrub `scrub`
(`nothing` if none) with the keys it shows `scrub_keys`, the fonts and the caches of the widths of
texts, and a counter of the chips for their order (`z`).
"""
mutable struct _CuePlots
    hud::Makie.Scene
    drawn::Vector{_CueDrawn}
    scrub::Union{Nothing, Makie.AbstractPlot}
    scrub_keys::Vector{String}
    regular::Any
    bold::Any
    widths::Dict{String, Float32}
    bold_widths::Dict{String, Float32}
    z::Int
end

# The plots of the cues of the `gui`, created at the first use
function _cue_plots(gui::LiveView)
    a = _activity(gui)
    c = a.cue_plots
    c isa _CuePlots && return c
    hud = Makie.campixel(gui.ax.scene)
    c = _CuePlots(hud, _CueDrawn[], nothing, String[], _tree_font(hud, :regular), _tree_font(hud, :bold),
        Dict{String, Float32}(), Dict{String, Float32}(), 0)
    a.cue_plots = c
    return c
end

# The life of a cue [s]
_cue_life() = _CUE_IN + _CUE_HOLD + _CUE_OUT

# Eases `x` in 0..1 in and out
_cue_ease(x::Real) = (x = clamp(Float64(x), 0.0, 1.0); x * x * (3 - 2x))

# The common attributes of the overlays: never clipped, never picked
const _CUE_3D = (; clip_planes = Plane3f[], inspectable = false, transparency = true)
const _CUE_2D = (; clip_planes = Plane3f[], inspectable = false, transparency = false, markerspace = :pixel)

"""
    _draw_cues!(gui, cues, now)

Draws the `cues` (episode, age [s]) of the `gui` at the time `now`, see `_activity_step!`: creates
the plots of a cue that starts, updates those of the cues shown (their alpha follows `_cue_alpha`,
the arcs are drawn out during `_CUE_IN`, the chips follow their objects on the screen) and deletes
the plots of a cue that is not in `cues` any more or whose life is over. The chips and bubbles are
hidden in the spectator mode, the frames and arcs stay.
"""
function _draw_cues!(gui::LiveView, cues, now::Real)
    c = _cue_plots(gui)
    life = _cue_life()
    keep = falses(length(c.drawn))
    for (ep, age) in cues
        age = Float64(age)
        start = Float64(now) - age
        k = findfirst(i -> !keep[i] && c.drawn[i].episode === ep && abs(c.drawn[i].start - start) < 0.05,
            eachindex(c.drawn))
        age >= life && continue
        if isnothing(k)
            push!(c.drawn, _new_cue(gui, c, ep, start))
            push!(keep, true)
            k = length(c.drawn)
        else
            keep[k] = true
        end
        _update_cue!(gui, c, c.drawn[k], age)
    end
    for i in reverse(eachindex(c.drawn))
        keep[i] && continue
        _delete_cue!(gui, c, c.drawn[i])
        deleteat!(c.drawn, i)
    end
    return nothing
end

"""Deletes the plots of the cues of the `gui` and the ghost frames of a scrub."""
function _clear_cues!(gui::LiveView)
    a = gui.activity
    a isa _Activity || return nothing
    c = a.cue_plots
    c isa _CuePlots || return nothing
    foreach(d -> _delete_cue!(gui, c, d), c.drawn)
    empty!(c.drawn)
    _draw_scrub!(gui, nothing)
    return nothing
end

"""The colour of the presence (box and name) of the participant `who` in the `gui`, see `_activity_color`."""
_presence_color(gui::LiveView, who::AbstractString) = _activity_color(gui, who)

# The colour of the participant of the episode `ep` with `alpha`: muted for a summary of several
function _cue_color(gui::LiveView, ep::_Episode, alpha::Real)
    ep.who == "several" && return RGBAf(Makie.to_color(gui.layout.theme.muted), alpha)
    return _activity_color(gui, ep.who; alpha)
end

#=
Geometry
=#

# The points `pts` of an object at the pose `from` (position, orientation) moved with it to the pose `to`
function _move_points(pts::AbstractVector{Point3f}, from, to)
    (pa, Ra), (pb, Rb) = from, to
    M = Rb * transpose(Ra)
    return Point3f[Point3f(M * (Vector{Float64}(p) .- pa) .+ pb) for p in pts]
end

# The corners of the box of the points `pts`, `(lo, hi)`
_frame_box(pts) = (reduce((a, b) -> min.(a, b), pts), reduce((a, b) -> max.(a, b), pts))
_frame_center(pts) = (b = _frame_box(pts); (b[1] + b[2]) / 2)

# The 8 corners of the box of the points `pts`
function _frame_corners(pts)
    lo, hi = _frame_box(pts)
    return Point3f[Point3f(x, y, z) for x in (lo[1], hi[1]), y in (lo[2], hi[2]), z in (lo[3], hi[3])][:]
end

# The camera's up vector of the 3D view of the `gui`
_cue_up(gui::LiveView) = Vector{Float64}(Makie.cameracontrols(gui.ax.scene).upvector[])

"""
    _move_arc(a, b, up) -> Vector{Point3f}

The arc of a move from `a` to `b`: a quadratic Bézier curve of `_CUE_ARC_POINTS` points whose
middle is lifted by `_CUE_ARC_LIFT` of the distance (at least `_CUE_ARC_MIN_LIFT`) towards `up`
(the part of it across the move). Empty if `a` and `b` coincide.
"""
function _move_arc(a, b, up)
    a, b = Vector{Float64}(a), Vector{Float64}(b)
    d = norm(b - a)
    d > 1e-9 || return Point3f[]
    dir = (b - a) / d
    n = up - dot(up, dir) * dir
    if norm(n) < 1e-6
        n = cross(dir, abs(dir[3]) < 0.9 ? [0.0, 0.0, 1.0] : [1.0, 0.0, 0.0])
    end
    n = normalize(n)
    # the middle of a quadratic Bézier curve lies half way to its control point
    c = (a + b) / 2 + 2 * max(_CUE_ARC_LIFT * d, _CUE_ARC_MIN_LIFT) * n
    return Point3f[Point3f((1 - t)^2 * a + 2 * (1 - t) * t * c + t^2 * b)
                   for t in range(0, 1; length = _CUE_ARC_POINTS)]
end

"""
    _turn_arc(center, radius, from, to, up) -> Vector{Point3f}

A short arc around `center` of the rotation from the orientation `from` to `to`: in the plane across
the axis of the rotation, of the angle of the rotation (at least 30°, at most 300°), starting at the
side towards `up`. Empty if the orientations coincide.
"""
function _turn_arc(center, radius::Real, from, to, up)
    axis, angle = _rotation_axis_angle(Matrix{Float64}(to * transpose(from)))
    abs(angle) > 1e-6 || return Point3f[]
    u = up - dot(up, axis) * axis
    norm(u) < 1e-6 && (u = cross(axis, abs(axis[3]) < 0.9 ? [0.0, 0.0, 1.0] : [1.0, 0.0, 0.0]))
    u = normalize(u)
    v = cross(axis, u)
    φ = sign(angle) * clamp(abs(angle), deg2rad(30), deg2rad(300))
    c = Vector{Float64}(center)
    return Point3f[Point3f(c + radius * (cos(t) * u + sin(t) * v)) for t in range(0, φ; length = _CUE_ARC_POINTS)]
end

# The first `f` (0..1) of the polyline `pts`, the last point interpolated
function _partial_line(pts::Vector{Point3f}, f::Real)
    n = length(pts)
    n < 2 && return copy(pts)
    s = clamp(Float64(f), 0.0, 1.0) * (n - 1)
    k = floor(Int, s)
    k >= n - 1 && return copy(pts)
    out = pts[1:(k + 1)]
    push!(out, pts[k + 1] + Float32(s - k) * (pts[k + 2] - pts[k + 1]))
    return out
end

# The frame `pts` scaled by `s` about `center`
_scale_frame(center::Point3f, pts::Vector{Point3f}, s::Real) = Point3f[center + Float32(s) * (p - center) for p in pts]

#=
Plots of a cue
=#

"""
    _new_cue(gui, c, ep, start) -> _CueDrawn

Creates the plots of the cue of the episode `ep` that started at `start`: its frames, ghosts, arcs,
arrowheads and crosses in `gui.ax` (only those it needs, all items in a few plots) and its chip, or
the bubble of a message.
"""
function _new_cue(gui::LiveView, c::_CuePlots, ep::_Episode, start::Float64)
    up = _cue_up(gui)
    static, ghosts, crosses = Point3f[], Point3f[], Point3f[]
    arcs = Vector{Point3f}[]
    added = Tuple{Point3f, Vector{Point3f}}[]
    anchor = Point3f[]
    for it in ep.items
        isempty(it.frame) && continue
        isempty(anchor) && (anchor = _frame_corners(it.frame))
        if it.change === :removed
            append!(ghosts, it.frame)
            push!(crosses, Point3f(_frame_center(it.frame)))
        elseif it.change === :added
            push!(added, (Point3f(_frame_center(it.frame)), it.frame))
        else
            append!(static, it.frame)
            if it.change in (:moved, :rotated) && !isnothing(it.before) && !isnothing(it.after)
                old = _move_points(it.frame, it.after, it.before)
                append!(ghosts, old)
                if it.change === :moved
                    arc = _move_arc(_frame_center(old), _frame_center(it.frame), up)
                else
                    lo, hi = _frame_box(it.frame)
                    arc = _turn_arc(_frame_center(it.frame), 0.6 * norm(hi - lo), it.before[2], it.after[2], up)
                end
                isempty(arc) || push!(arcs, arc)
            end
        end
    end
    plots = Dict{Symbol, Makie.AbstractPlot}()
    color = _cue_color(gui, ep, 0)
    if !isempty(static) || !isempty(added)
        plots[:frames] = linesegments!(gui.ax, _frame_points(static, added, 0.0); _CUE_3D..., color,
            linewidth = _CUE_FRAME_WIDTH)
    end
    isempty(ghosts) || (plots[:ghosts] = linesegments!(gui.ax, ghosts; _CUE_3D..., color,
        linewidth = _CUE_GHOST_WIDTH, linestyle = :dash))
    if !isempty(arcs)
        plots[:arcs] = lines!(gui.ax, Point3f[]; _CUE_3D..., color, linewidth = _CUE_ARC_WIDTH)
        plots[:heads] = scatter!(gui.ax, Point3f[]; _CUE_3D..., color, marker = :utriangle,
            markersize = _CUE_HEAD_SIZE, markerspace = :pixel, rotation = Float32[])
    end
    isempty(crosses) || (plots[:crosses] = scatter!(gui.ax, crosses; _CUE_3D..., color, marker = :xcross,
        markersize = _CUE_CROSS_SIZE, markerspace = :pixel))
    bubble = !isempty(ep.message)
    if isempty(anchor) && bubble
        anchor = _presence_anchor(gui, ep.who)
    end
    pos = Observable(Point2f(NaN))
    d = _CueDrawn(ep, start, plots, arcs, added, static, anchor, Vec2f(0), 0, pos, -1.0, ep.n == 0 || ep.count > 1, bubble)
    bubble ? _new_bubble!(gui, c, d) : _new_chip!(gui, c, d)
    d.slot = _free_slot(gui, c, d)
    return d
end

# The points of the frames: the `static` ones and the `added` ones scaled for the progress `f` (0..1)
function _frame_points(static::Vector{Point3f}, added, f::Real)
    isempty(added) && return static
    s = _CUE_ADDED_SCALE + (1 - _CUE_ADDED_SCALE) * _cue_ease(f)
    pts = copy(static)
    for (center, frame) in added
        append!(pts, _scale_frame(center, frame, s))
    end
    return pts
end

# The corners of the box of the object that the participant `who` of the `gui` works on (its
# presence box), empty if none
function _presence_anchor(gui::LiveView, who::AbstractString)
    o = get(gui.sync.others, who, nothing)
    isnothing(o) && return Point3f[]
    for obj in _objects_of_other(gui, o)
        bb = _part_box(gui, obj)
        isnothing(bb) || return _frame_corners(_bbox_wireframe(bb))
    end
    return Point3f[]
end

# The width of the text `s` [px] in the regular or `bold` font of the chips
_chip_width(c::_CuePlots, s::AbstractString; bold::Bool = false) =
    bold ? _text_width(c.bold_widths, c.bold, _CHIP_FONTSIZE, s) : _text_width(c.widths, c.regular, _CHIP_FONTSIZE, s)

# `s` with at most `n` characters, else cut with "…"
_clip_text(s::AbstractString, n::Integer) = length(s) <= n ? String(s) : rstrip(first(s, n - 1)) * "…"

"""
    _wrap_text(s, width = _BUBBLE_WRAP, lines = _BUBBLE_LINES) -> Vector{String}

The text `s` in lines of at most `width` characters, broken between words (a longer word is cut),
at most `lines` lines; the last of them ends with "…" if text is left over.
"""
function _wrap_text(s::AbstractString, width::Integer = _BUBBLE_WRAP, lines::Integer = _BUBBLE_LINES)
    rows = String[]
    line = ""
    for word in split(strip(s))
        w = String(word)
        # a word longer than a line is cut
        while length(w) > width
            isempty(line) || (push!(rows, line); line = "")
            push!(rows, first(w, width))
            w = w[nextind(w, 0, width + 1):end]
        end
        isempty(w) && continue
        if isempty(line)
            line = w
        elseif length(line) + 1 + length(w) <= width
            line *= " " * w
        else
            push!(rows, line)
            line = w
        end
    end
    isempty(line) || push!(rows, line)
    length(rows) <= lines && return rows
    out = rows[1:lines]
    out[end] = (length(out[end]) < width ? out[end] : rstrip(first(out[end], width - 1))) * "…"
    return out
end

# Adds the plots of a chip of the cue `d` to the pixel scene: background, the dot of the colour,
# the name in bold and the text, e.g. "● Claude · moved M2"
function _new_chip!(gui::LiveView, c::_CuePlots, d::_CueDrawn)
    ep = d.episode
    t = gui.layout.theme
    name = _clip_text(ep.name, 24)
    text = " · " * _clip_text(ep.text, _CHIP_CHARS)
    wn, wt = _chip_width(c, name; bold = true), _chip_width(c, text)
    H = round(_CHIP_FONTSIZE * _CHIP_LINEHEIGHT + 2 * _CHIP_PAD[2])
    W = round(2 * _CHIP_PAD[1] + _CHIP_DOT + _CHIP_DOT_GAP + wn + wt)
    d.size = Vec2f(W, H)
    x0 = _CHIP_PAD[1] + _CHIP_DOT + _CHIP_DOT_GAP
    _chip_plots!(gui, c, d, t)
    d.plots[:dot] = scatter!(c.hud, d.pos; _CUE_2D..., marker = :circle, markersize = _CHIP_DOT,
        color = _cue_color(gui, ep, 0), marker_offset = Vec2f(_CHIP_PAD[1] + _CHIP_DOT / 2, H / 2))
    d.plots[:name] = text!(c.hud, d.pos; _CUE_2D..., text = name, font = c.bold, fontsize = _CHIP_FONTSIZE,
        color = RGBAf(Makie.to_color(t.text), 0), align = (:left, :center), offset = Vec2f(x0, H / 2))
    d.plots[:text] = text!(c.hud, d.pos; _CUE_2D..., text, font = c.regular, fontsize = _CHIP_FONTSIZE,
        color = RGBAf(Makie.to_color(t.text), 0), align = (:left, :center), offset = Vec2f(x0 + wn, H / 2))
    _order_chip!(c, d)
    return d
end

# Adds the plots of the bubble of the message of the cue `d`: a rounded box with the colour of the
# participant as a bar at its left edge, the name in bold and the message below, wrapped
function _new_bubble!(gui::LiveView, c::_CuePlots, d::_CueDrawn)
    ep = d.episode
    t = gui.layout.theme
    name = _clip_text(ep.name, 24)
    lines = _wrap_text(ep.message)
    lh = _CHIP_FONTSIZE * _CHIP_LINEHEIGHT
    w = max(_chip_width(c, name; bold = true), maximum((_chip_width(c, l) for l in lines); init = 0.0f0))
    H = round(2 * _BUBBLE_PAD[2] + (1 + length(lines)) * lh)
    W = round(2 * _BUBBLE_PAD[1] + _BUBBLE_BAR + w)
    d.size = Vec2f(W, H)
    x0 = _BUBBLE_PAD[1] + _BUBBLE_BAR
    _chip_plots!(gui, c, d, t)
    d.plots[:bar] = scatter!(c.hud, d.pos; _CUE_2D...,
        marker = _rounded_rect_marker(1, (H - 8) / _BUBBLE_BAR, _BUBBLE_BAR / 2 / _BUBBLE_BAR), markersize = _BUBBLE_BAR,
        color = _cue_color(gui, ep, 0), marker_offset = Vec2f(4 + _BUBBLE_BAR / 2, H / 2))
    d.plots[:name] = text!(c.hud, d.pos; _CUE_2D..., text = name, font = c.bold, fontsize = _CHIP_FONTSIZE,
        color = RGBAf(Makie.to_color(t.text), 0), align = (:left, :center), offset = Vec2f(x0, H - _BUBBLE_PAD[2] - lh / 2))
    d.plots[:text] = text!(c.hud, d.pos; _CUE_2D..., text = join(lines, "\n"), font = c.regular,
        fontsize = _CHIP_FONTSIZE, lineheight = _CHIP_LINEHEIGHT, color = RGBAf(Makie.to_color(t.text), 0),
        align = (:left, :top), offset = Vec2f(x0, H - _BUBBLE_PAD[2] - lh - (lh - _CHIP_FONTSIZE) / 2))
    _order_chip!(c, d)
    return d
end

# The background of a chip or bubble of the size `d.size`: the rounded box in the theme's `view`
# with a border
function _chip_plots!(gui::LiveView, c::_CuePlots, d::_CueDrawn, t)
    W, H = d.size
    d.plots[:background] = scatter!(c.hud, d.pos; _CUE_2D...,
        marker = _rounded_rect_marker(1, H / W, _CHIP_CORNER / W), markersize = W,
        color = RGBAf(Makie.to_color(t.view), 0), strokecolor = RGBAf(Makie.to_color(t.border), 0),
        strokewidth = 1, marker_offset = Vec2f(W / 2, H / 2))
    return nothing
end

# The plots of the chip of `d` in front of the 3D scene and of older chips
function _order_chip!(c::_CuePlots, d::_CueDrawn)
    c.z += 1
    z = _CHIP_Z + 5 * mod(c.z, 100)
    for (k, s) in enumerate((:background, :bar, :dot, :name, :text))
        haskey(d.plots, s) && translate!(d.plots[s], 0, 0, z + k)
    end
    return nothing
end

#=
Placing a chip
=#

# The point [px of the 3D view] above the box of the anchor of the cue `d` (its top, centred), or
# `nothing` if it is behind the camera; without an anchor the upper left corner of the view
function _chip_anchor(gui::LiveView, d::_CueDrawn)
    scene = gui.ax.scene
    if isempty(d.anchor)
        h = Makie.widths(Makie.viewport(scene)[])[2]
        return Point2f(_CHIP_MARGIN + d.size[1] / 2, h - _CHIP_MARGIN - d.size[2] - _CHIP_GAP)
    end
    lo, hi = Vec2f(Inf), Vec2f(-Inf)
    for p in d.anchor
        _behind(scene, p) && continue
        q = Makie.project(scene, :data, :pixel, p)
        all(isfinite, q) || continue
        lo, hi = min.(lo, Vec2f(q[1], q[2])), max.(hi, Vec2f(q[1], q[2]))
    end
    all(isfinite, lo) || return nothing
    return Point2f((lo[1] + hi[1]) / 2, hi[2])
end

# The lower left corner of the chip of `d` at the `anchor` [px], within the view
function _chip_position(gui::LiveView, d::_CueDrawn, anchor::Point2f)
    w, h = Makie.widths(Makie.viewport(gui.ax.scene)[])
    W, H = d.size
    x = anchor[1] - W / 2
    y = anchor[2] + _CHIP_GAP + d.slot * (H + _CHIP_STACK)
    x = clamp(x, _CHIP_MARGIN, max(_CHIP_MARGIN, w - W - _CHIP_MARGIN))
    y = clamp(y, _CHIP_MARGIN, max(_CHIP_MARGIN, h - H - _CHIP_MARGIN))
    return Point2f(x, y)
end

# The lowest place of the chip of `d` above its object where it does not cover a chip shown (see
# `_chip_position`), kept while the cue is shown so that the chips do not jump
function _free_slot(gui::LiveView, c::_CuePlots, d::_CueDrawn)
    a = _chip_anchor(gui, d)
    isnothing(a) && return 0
    taken = Makie.Rect2f[]
    for e in c.drawn
        (e === d || !all(isfinite, e.pos[])) && continue
        push!(taken, Makie.Rect2f(e.pos[], e.size))
    end
    for s in 0:7
        d.slot = s
        r = Makie.Rect2f(_chip_position(gui, d, a), d.size)
        any(t -> _chips_overlap(r, t), taken) || return s
    end
    return 0
end

# Whether the rectangles `a` and `b` [px] overlap or are closer than `_CHIP_STACK`
function _chips_overlap(a, b)
    alo, ahi, blo, bhi = minimum(a), maximum(a), minimum(b), maximum(b)
    return all(alo .< bhi .+ _CHIP_STACK) && all(blo .< ahi .+ _CHIP_STACK)
end

#=
Per frame
=#

# Sets the observable `obs` to `value` if it differs
_set_if!(obs, value) = (obs[] == value || (obs[] = value); nothing)

"""
    _update_cue!(gui, c, d, age)

Updates the plots of the cue `d` at its `age` [s]: the alpha of all parts follows `_cue_alpha`
(the ghosts at `_CUE_GHOST_ALPHA`, the 3D parts of a summary at `_CUE_SUMMARY_ALPHA`), the arcs and
the frames that are added are drawn out during `_CUE_IN`, the arrowheads point along the arcs on
the screen and the chip follows its object; the chip is hidden in the spectator mode.
"""
function _update_cue!(gui::LiveView, c::_CuePlots, d::_CueDrawn, age::Float64)
    ep, p = d.episode, d.plots
    t = gui.layout.theme
    a = _cue_alpha(age)
    k = d.summary ? _CUE_SUMMARY_ALPHA : 1.0
    color = _cue_color(gui, ep, a * k)
    f = _cue_ease(age / _CUE_IN)
    haskey(p, :frames) && _set_if!(p[:frames].color, color)
    haskey(p, :ghosts) && _set_if!(p[:ghosts].color, _cue_color(gui, ep, a * k * _CUE_GHOST_ALPHA))
    haskey(p, :crosses) && _set_if!(p[:crosses].color, color)
    if f != d.progress
        haskey(p, :frames) && !isempty(d.added) && _set_if!(p[:frames][1], _frame_points(d.static, d.added, f))
        if haskey(p, :arcs)
            parts = [_partial_line(arc, f) for arc in d.arcs]
            pts = Point3f[]
            for (i, q) in enumerate(parts)
                i > 1 && push!(pts, Point3f(NaN))
                append!(pts, q)
            end
            p[:arcs][1] = pts
        end
        d.progress = f
    end
    if haskey(p, :arcs)
        _set_if!(p[:arcs].color, color)
        _update_heads!(gui, d, color)
    end
    # the chip or bubble
    visible = !gui.controls.spectator[]
    anchor = visible ? _chip_anchor(gui, d) : nothing
    shown = visible && !isnothing(anchor)
    shown && _set_if!(d.pos, _chip_position(gui, d, anchor))
    for s in (:background, :bar, :dot, :name, :text)
        haskey(p, s) && _set_if!(p[s].visible, shown)
    end
    shown || return nothing
    _set_if!(p[:background].color, RGBAf(Makie.to_color(t.view), _CHIP_BACKGROUND_ALPHA * a))
    _set_if!(p[:background].strokecolor, RGBAf(Makie.to_color(t.border), a))
    s = haskey(p, :dot) ? :dot : :bar
    _set_if!(p[s].color, _cue_color(gui, ep, a))
    _set_if!(p[:name].color, RGBAf(Makie.to_color(t.text), a))
    _set_if!(p[:text].color, RGBAf(Makie.to_color(t.text), a))
    return nothing
end

# The arrowheads at the ends of the arcs drawn so far of the cue `d`, turned along their direction
# on the screen
function _update_heads!(gui::LiveView, d::_CueDrawn, color)
    scene = gui.ax.scene
    tips, angles = Point3f[], Float32[]
    for arc in d.arcs
        q = _partial_line(arc, d.progress)
        length(q) < 2 && continue
        tip, prev = q[end], q[end - 1]
        if norm(tip - prev) < 1e-12
            length(q) < 3 && continue
            prev = q[end - 2]
        end
        a = Makie.project(scene, :data, :pixel, tip)
        b = Makie.project(scene, :data, :pixel, prev)
        dx, dy = a[1] - b[1], a[2] - b[2]
        (isfinite(dx) && isfinite(dy)) || continue
        push!(tips, tip)
        # `:utriangle` points up (+y) without rotation
        push!(angles, Float32(atan(dy, dx) - π / 2))
    end
    h = d.plots[:heads]
    (h[1][] == tips && h.rotation[] == angles) || Makie.update!(h; arg1 = tips, rotation = angles)
    _set_if!(h.color, color)
    return nothing
end

function _delete_cue!(gui::LiveView, c::_CuePlots, d::_CueDrawn)
    for (s, p) in d.plots
        try
            s in (:background, :bar, :dot, :name, :text) ? delete!(c.hud, p) : delete!(gui.ax, p)
        catch
        end
    end
    empty!(d.plots)
    return nothing
end

#=
Scrub
=#

"""
    _draw_scrub!(gui, poses)

Draws a dashed ghost frame of each object of the `gui` at its pose of `poses` (key => (position,
orientation), see `_poses_at`) that differs from its pose now, in the colour of the participant
who changed it first after the time of the scrub (`activity.cursor`); a key of an object that is
not in the view any more takes the frame of its latest episode. `nothing` clears them. One plot
for all ghosts; the keys it shows are `cue_plots.scrub_keys`.
"""
function _draw_scrub!(gui::LiveView, poses)
    if isnothing(poses)
        a = gui.activity
        a isa _Activity || return nothing
        c = a.cue_plots
        c isa _CuePlots || return nothing
        if !isnothing(c.scrub)
            try
                delete!(gui.ax, c.scrub)
            catch
            end
            c.scrub = nothing
        end
        empty!(c.scrub_keys)
        return nothing
    end
    c = _cue_plots(gui)
    pts, colors, keys_ = Point3f[], RGBAf[], String[]
    for key in sort!(collect(keys(poses)))
        old = poses[key]
        frame = _scrub_frame(gui, key, old)
        isnothing(frame) && continue
        color = _scrub_color(gui, key)
        append!(pts, frame)
        append!(colors, fill(color, length(frame)))
        push!(keys_, key)
    end
    c.scrub_keys = keys_
    if isnothing(c.scrub)
        c.scrub = linesegments!(gui.ax, pts; _CUE_3D..., color = colors, linewidth = _CUE_GHOST_WIDTH,
            linestyle = :dash)
    else
        Makie.update!(c.scrub; arg1 = pts, color = colors)
    end
    return nothing
end

# The ghost frame of the line `key` at the pose `old`, `nothing` if it is where it is now
function _scrub_frame(gui::LiveView, key::String, old)
    pos, R = Vector{Float64}(old[1]), Matrix{Float64}(old[2])
    obj = _object_of_key(gui, key)
    if !isnothing(obj) && !(obj isa BMO.AbstractSystem)
        bb = _part_box(gui, obj)
        now = _cue_pose(obj)
        if !isnothing(bb) && !isnothing(now)
            _same_pose(now, (pos, R)) && return nothing
            return _move_points(_bbox_wireframe(bb), now, (pos, R))
        end
    end
    # not in the view (any more): the frame of its latest item
    a = _activity(gui)
    for ep in Iterators.reverse(a.episodes), it in ep.items
        (it.key == key && !isempty(it.frame)) || continue
        ref = it.change === :removed ? it.before : it.after
        isnothing(ref) && return nothing
        _same_pose(ref, (pos, R)) && it.change !== :removed && return nothing
        return _move_points(it.frame, ref, (pos, R))
    end
    return nothing
end

# The pose (position, orientation) of the object `obj`, `nothing` if it has none
function _cue_pose(@nospecialize(obj))
    try
        return (Vector{Float64}(position(obj)), Matrix{Float64}(BMO.orientation(obj)))
    catch
        return nothing
    end
end

_same_pose(a, b) = maximum(abs, a[1] - b[1]) < 1e-9 && maximum(abs, a[2] - b[2]) < 1e-9

# The colour of the ghost of the line `key` in a scrub: of the participant who changed it first
# after the cursor
function _scrub_color(gui::LiveView, key::String)
    a = _activity(gui)
    t = something(a.cursor, -Inf)
    for ep in a.episodes
        ep.t > t || continue
        any(it -> it.key == key, ep.items) && return _activity_color(gui, ep.who; alpha = _SCRUB_ALPHA)
    end
    return RGBAf(Makie.to_color(gui.layout.theme.muted), _SCRUB_ALPHA)
end
