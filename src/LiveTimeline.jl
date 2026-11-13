#=
The timeline of the activity of the others at the bottom of the 3D view, see `LiveActivity.jl` and
`plans/activity-cues.md` (W3).
=#

# z translation of the scene of the strip: over the 3D view, under the overlay of the compact
# layout (`_OVERLAY_Z`) and the cards; its tooltip lies over the cards, see `_TL_TIP_Z`
const _TL_Z = _OVERLAY_Z - 100.0f0
const _TL_TIP_Z = _CARD_Z + 60.0f0 - _TL_Z
# Distance from the edges of the 3D view, largest width, heights [px]
const _TL_MARGIN = 12.0f0
const _TL_MAX_WIDTH = 760.0f0
const _TL_COLLAPSED = 26.0f0
const _TL_EXPANDED = 110.0f0
# Expanded: the head (chevron, title, span), the height of a lane, the foot (the labels of the time
# axis), the column of the lanes' names, the lanes shown at most
const _TL_HEAD = 24.0f0
const _TL_LANE = 22.0f0
const _TL_FOOT = 18.0f0
const _TL_LABELS = 150.0f0
const _TL_MAX_LANES = 6
# Horizontal padding inside the strip, corner radius, opacity of the background
const _TL_PAD = 10.0f0
const _TL_CORNER = 8.0f0
const _TL_ALPHA = 0.92
const _TL_FONTSIZE = 12.0f0
const _TL_SMALL = 10.5f0
# Collapsed: the participants shown at most, the gap between them [px]
const _TL_SHOWN = 4
const _TL_GAP = 22.0f0
# Marks: their size, while hovered, and the distance [px] below which marks of a lane become a pill
const _TL_MARK = 8.0f0
const _TL_MARK_HOVER = 12.0f0
const _TL_CLUSTER = 7.0f0
const _TL_PILL = 13.0f0
# Before the placement (210), the controls (200) and the camera (0), after the cards, which end the
# input into their textboxes (250), and the splitters, the help and the view cube (≥ 300)
const _TL_PRIORITY = 240
# The time span of the expanded strip [s]: default, bounds of the wheel, factor per step
const _TL_SPAN = 300.0
const _TL_SPAN_MIN = 60.0
const _TL_SPAN_MAX = 3600.0
const _TL_ZOOM = 1.25
# Distance [px] after which a press in the lanes scrubs, pause [s] of a double click
const _TL_DRAG_MIN = 3.0f0
const _TL_DOUBLE_CLICK = 0.4

# The glyphs of the strip: a dot (a person), a small diamond (an agent), a speech bubble (a message)
const _TL_DOT = Makie.BezierCircle
const _TL_DIAMOND = Makie.BezierPath([Makie.MoveTo(Point2d(0, 0.5)), Makie.LineTo(Point2d(0.4, 0)),
    Makie.LineTo(Point2d(0, -0.5)), Makie.LineTo(Point2d(-0.4, 0)), Makie.ClosePath()])
const _TL_SPEECH = _svg_path("M120-120v-680q0-33 23.5-56.5T200-880h560q33 0 56.5 23.5T840-800v440q0 33-23.5 56.5T760-280H280L120-120Z")

"""
    _Timeline

The strip of the timeline of the `gui` (`gui.activity.strip`, see `_timeline!`): plain plots in its
own `scene`, a scene with a pixel camera over the whole figure, translated to `_TL_Z`, in the
color tokens `theme`; the plots are kept and updated, see `_draw_timeline!`.

`rect` is its rectangle [figure px], `shown` whether it is shown (an other was there, not in the
spectator mode), `span` the time span of the expanded strip [s] (the wheel changes it), `now` the
time of the last update. `hits` are the regions that take the mouse: `(rect, kind, data)` with the
kinds `:toggle`, `:eye` (participant id), `:mark` (episode numbers, the last one is shown) and
`:lanes`; `axis` the x range of the time axis. `pressed` is the press on the strip (kind, data,
mouse, scrubbing, button) or `nothing`, `click` the episode and time of the last click on a mark (the
double click), `hover_own` whether the strip set `activity.hover`, `sig` what the plots show,
such that unchanged frames cost nothing, `widths` the measured texts.
"""
mutable struct _Timeline
    const scene::Scene
    const theme::NamedTuple
    const font::Any
    const bold::Any
    const plots::NamedTuple
    rect::Rect2f
    shown::Bool
    span::Float64
    now::Float64
    hits::Vector{Tuple{Rect2f, Symbol, Any}}
    axis::Tuple{Float32, Float32}
    pressed::Any
    click::Tuple{Int, Float64}
    hover_own::Bool
    sig::Any
    const widths::Dict{Tuple{String, Bool, Float32}, Float32}
end

"""
    _timeline!(gui) -> _Timeline

Builds the timeline strip of the `gui` (see `_Timeline`) at the bottom of its 3D view, hidden until
an other participant was there (`activity.seen`), and connects the mouse, see
`_connect_timeline!`. Returns the strip that exists already if called again.
"""
function _timeline!(gui::LiveView)
    a = _activity(gui)
    a.strip isa _Timeline && return a.strip
    t = gui.layout.theme
    scene = Scene(gui.fig.scene; camera = Makie.campixel!, clear = false)
    translate!(scene, 0, 0, _TL_Z)
    common = (; inspectable = false, space = :pixel)
    # GLMakie can not draw an empty vector of markers: every vector holds one hidden entry at least
    away = [Point2f(-100, -100)]
    none = RGBAf[_TRANSPARENT]
    box = _rounded_rect(Rect2f(0, 0, 1, 1), 0)
    panel = poly!(scene, box; common..., color = _rgba(t.view, _TL_ALPHA), strokecolor = t.border,
        strokewidth = 1)
    grid = linesegments!(scene, [away; away]; common..., color = none, linewidth = 1)
    chevron = lines!(scene, [away; away; away]; common..., color = t.muted, linewidth = 1.5)
    pills = poly!(scene, [Makie.Polygon(box)]; common..., color = none, strokecolor = none,
        strokewidth = 1)
    marks = scatter!(scene, away; common..., marker = [_TL_DOT], markersize = [_TL_MARK], color = none,
        strokewidth = 0, markerspace = :pixel)
    dots = scatter!(scene, away; common..., marker = [_TL_DOT], markersize = [_TL_MARK], color = none,
        markerspace = :pixel)
    eyes = scatter!(scene, away; common..., marker = [_icon(:eye)], markersize = [15.0f0], color = none,
        markerspace = :pixel)
    text_kw = (; common..., markerspace = :pixel, align = (:left, :center))
    names = text!(scene, Point2f[]; text_kw..., text = String[], color = RGBAf[], font = :bold,
        fontsize = _TL_FONTSIZE)
    details = text!(scene, Point2f[]; text_kw..., text = String[], color = t.muted,
        fontsize = _TL_FONTSIZE)
    labels = text!(scene, Point2f[]; text_kw..., text = String[], color = RGBAf[],
        fontsize = _TL_SMALL)
    cursor = linesegments!(scene, [away; away]; common..., color = t.accent, linewidth = 1.5,
        visible = false)
    tip_box = poly!(scene, box; common..., color = t.tooltip, strokewidth = 0, visible = false)
    tip_text = text!(scene, Point2f(0); text_kw..., text = "", color = t.tooltip_text,
        fontsize = _TL_FONTSIZE, visible = false)
    # The lines and pills over the background, the marks over them, the texts on top
    foreach(p -> translate!(p, 0, 0, 1), (grid, pills))
    foreach(p -> translate!(p, 0, 0, 2), (marks, dots, eyes, chevron, cursor))
    foreach(p -> translate!(p, 0, 0, 3), (names, details, labels))
    translate!(tip_box, 0, 0, _TL_TIP_Z)
    translate!(tip_text, 0, 0, _TL_TIP_Z + 1)
    scene.visible[] = false
    plots = (; panel, grid, chevron, pills, marks, dots, eyes, names, details, labels, cursor,
        tip_box, tip_text)
    tl = _Timeline(scene, t, _tree_font(scene, :regular), _tree_font(scene, :bold), plots,
        Rect2f(0, 0, 0, 0), false, _TL_SPAN, time(), Tuple{Rect2f, Symbol, Any}[], (0.0f0, 0.0f0),
        nothing, (0, -Inf), false, nothing, Dict{Tuple{String, Bool, Float32}, Float32}())
    a.strip = tl
    _connect_timeline!(gui, tl)
    _update_timeline!(gui, time())
    return tl
end

"""The strip of the timeline of the `gui`, `nothing` before `_timeline!`."""
function _timeline(gui::LiveView)
    s = _activity(gui).strip
    return s isa _Timeline ? s : nothing
end

"""
    _update_timeline!(gui, now)

Updates the timeline strip of the `gui` at the time `now` [s, see `time`]: shows it once an other
was there (hidden in the spectator mode), places it at the bottom of the 3D view and redraws its
lanes, marks, ages and tooltip if any of them changed, see `_draw_timeline!`. Called every frame.
"""
function _update_timeline!(gui::LiveView, now::Real)
    tl = _timeline(gui)
    isnothing(tl) && return nothing
    a = _activity(gui)
    tl.now = Float64(now)
    shown = a.seen && !gui.controls.spectator[] && !isempty(a.episodes)
    rect = shown ? _tl_rect(gui, a) : nothing
    shown = shown && !isnothing(rect)
    if !shown
        tl.shown && _hide_timeline!(gui, tl)
        return nothing
    end
    tl.shown = true
    tl.scene.visible[] = true
    tl.rect = rect
    # what the plots show: the ages and the time axis move with `now`, by the second or the pixel
    tick = a.expanded ? floor(Int, now / (tl.span / max(_tl_axis_width(rect), 1))) : floor(Int, now / 1)
    last = a.episodes[end]
    sig = (rect, a.expanded, length(a.episodes), last.n, tl.span, tick, a.hover, a.cursor, a.follow,
        length(a.colors))
    sig == tl.sig && return nothing
    tl.sig = sig
    _draw_timeline!(gui, tl, a)
    return nothing
end

"""Expands (`true`) or collapses the timeline strip of the `gui`."""
function _set_expanded!(gui::LiveView, on::Bool)
    a = _activity(gui)
    a.expanded = on
    tl = _timeline(gui)
    isnothing(tl) || _update_timeline!(gui, tl.now)
    return nothing
end

# Hides the strip, and its hover and scrub
function _hide_timeline!(gui::LiveView, tl::_Timeline)
    a = _activity(gui)
    tl.shown = false
    tl.scene.visible[] = false
    tl.sig = nothing
    tl.pressed = nothing
    a.cursor = nothing
    _tl_set_hover!(gui, tl, nothing)
    empty!(tl.hits)
    return nothing
end

#=
Geometry
=#

# The width of the time axis of the strip with the rectangle `r`
_tl_axis_width(r::Rect2f) = Makie.widths(r)[1] - _TL_LABELS - 2 * _TL_PAD - 6

# The height of the expanded strip with `n` lanes: at least the one of two lanes, at most of
# `_TL_MAX_LANES`, about `_TL_EXPANDED` with three
_tl_expanded_height(n::Int) = _TL_HEAD + _TL_FOOT + 6 + clamp(n, 2, _TL_MAX_LANES) * _TL_LANE

"""
    _tl_rect(gui, a) -> Union{Rect2f, Nothing}

The rectangle [figure px] of the timeline strip of the `gui`: at the bottom of the 3D view, inset by
`_TL_MARGIN`, at most `_TL_MAX_WIDTH` wide and centered, right of (or left of) the parts of the
layout at the bottom corners of the view (see `_layout_obstacles`), e.g. the button "⋯" of the
compact layout. `nothing` if the view is too small.
"""
function _tl_rect(gui::LiveView, a::_Activity)
    vp = Rect2f(gui.ax.scene.viewport[])
    lo, hi = minimum(vp), maximum(vp)
    m = _TL_MARGIN
    left, right = lo[1] + m, hi[1] - m
    bottom = lo[2] + m
    band = bottom + _TL_COLLAPSED
    mid = (lo[1] + hi[1]) / 2
    for r in _layout_obstacles(gui)
        rl, rh = minimum(r), maximum(r)
        # only the parts at the bottom edge, not e.g. the tool rail above "⋯"
        (rl[2] < band && rh[2] > bottom && rh[1] > left && rl[1] < right) || continue
        if (rl[1] + rh[1]) / 2 < mid
            left = max(left, rh[1] + _OVERLAY_GAP)
        else
            right = min(right, rl[1] - _OVERLAY_GAP)
        end
    end
    w = min(right - left, _TL_MAX_WIDTH)
    h = a.expanded ? _tl_expanded_height(length(_tl_participants(a))) : _TL_COLLAPSED
    h = min(h, hi[2] - lo[2] - 2m)
    (w < 160 || h < _TL_COLLAPSED) && return nothing
    x = clamp(mid - w / 2, left, right - w)
    return Rect2f(x, bottom, w, h)
end

"""
    _tl_participants(a) -> Vector

The participants of the episodes of the activity `a`, in the order in which they were first seen:
each `(; who, name, agent, first, last, episodes)` with the index of its first episode, its last
episode and the indices of its episodes in `a.episodes`.
"""
function _tl_participants(a::_Activity)
    index = Dict{String, Int}()
    ps = NamedTuple{(:who, :name, :agent, :first, :last, :episodes),
        Tuple{String, String, Bool, Int, _Episode, Vector{Int}}}[]
    for (i, ep) in enumerate(a.episodes)
        k = get(index, ep.who, 0)
        if k == 0
            push!(ps, (; who = ep.who, name = ep.name, agent = ep.agent, first = i, last = ep,
                episodes = [i]))
            index[ep.who] = length(ps)
        else
            p = ps[k]
            push!(p.episodes, i)
            ps[k] = (; p..., name = ep.name, agent = ep.agent, last = ep)
        end
    end
    return ps
end

# The lanes of the expanded strip: the participants that were active last, at most
# `_TL_MAX_LANES`, in the order in which they were first seen
function _tl_lanes(a::_Activity)
    ps = _tl_participants(a)
    length(ps) <= _TL_MAX_LANES && return ps
    keep = sort(sortperm(ps; by = p -> p.last.t, rev = true)[1:_TL_MAX_LANES])
    return ps[keep]
end

#=
Texts
=#

"""The age `dt` [s] of an episode as the strip shows it: "now", "12 s", "3 min", "1 h"."""
function _tl_age(dt::Real)
    dt < 5 && return "now"
    dt < 60 && return "$(floor(Int, dt)) s"
    dt < 3600 && return "$(floor(Int, dt / 60)) min"
    return "$(floor(Int, dt / 3600)) h"
end

"""The time `t` [s, see `time`] as `HH:MM:SS` of the local clock."""
_tl_clock(t::Real) = Libc.strftime("%H:%M:%S", t)

# The span of the time axis `span` [s] in its head: "90 s", "5 min", "1 h"
function _tl_span_label(span::Real)
    span < 120 && return "$(round(Int, span)) s"
    span < 3600 - 30 && return "$(round(Int, span / 60)) min"
    return "1 h"
end

# The label of a tick of the time axis `dt` [s] before now
function _tl_tick_label(dt::Integer)
    dt == 0 && return "now"
    dt % 3600 == 0 && return "$(dt ÷ 3600) h"
    dt % 60 == 0 && return "$(dt ÷ 60) min"
    return "$(dt) s"
end

# What an episode says: its text, or its message in quotes
_tl_text(ep::_Episode) = isempty(ep.message) ? ep.text : "“" * ep.message * "”"

# The width [px] of the text `s` in the regular or `bold` font, measured once
function _tl_width(tl::_Timeline, s::String, bold::Bool = false, size::Float32 = _TL_FONTSIZE)
    length(tl.widths) > 2000 && empty!(tl.widths)
    return get!(tl.widths, (s, bold, size)) do
        Float32(Makie.widths(Makie.text_bb(s, bold ? tl.bold : tl.font, size))[1])
    end
end

"""The text `s`, shortened with "…" such that it is at most `w` [px] wide; "" if not even "…" fits."""
function _tl_fit(tl::_Timeline, s::String, w::Real, bold::Bool = false)
    _tl_width(tl, s, bold) <= w && return s
    _tl_width(tl, "…", bold) > w && return ""
    chars = collect(s)
    lo, hi = 0, length(chars)
    while lo < hi
        k = (lo + hi + 1) ÷ 2
        if _tl_width(tl, rstrip(String(chars[1:k])) * "…", bold) <= w
            lo = k
        else
            hi = k - 1
        end
    end
    return rstrip(String(chars[1:lo])) * "…"
end

# The tooltip of a mark of the episodes `ns` of the activity `a`
function _tl_tooltip(a::_Activity, ns::Vector{Int})
    eps = [ep for ep in a.episodes if ep.n in ns]
    isempty(eps) && return ""
    ep = last(eps)
    length(eps) == 1 && return "$(ep.name) · $(_tl_clock(ep.t)) · $(_tl_text(ep))"
    count = sum(e -> e.count, eps)
    return "$(ep.name) · $(_tl_clock(first(eps).t))–$(_tl_clock(ep.t)) · $count changes, last: $(_tl_text(ep))"
end

#=
Drawing
=#

# The color of the participant `who` of the `gui` with the opacity `alpha`
_tl_color(gui::LiveView, who::String, alpha::Real = 1.0) = RGBAf(_activity_color(gui, who; alpha))

"""
    _draw_timeline!(gui, tl, a)

Draws the strip `tl` of the `gui` in its rectangle: the panel, then the collapsed line or the
expanded lanes (see `_draw_collapsed!`, `_draw_expanded!`), the scrub cursor and the tooltip of the
hovered mark, and collects the regions that take the mouse in `tl.hits`.
"""
function _draw_timeline!(gui::LiveView, tl::_Timeline, a::_Activity)
    r = tl.rect
    p = tl.plots
    Makie.update!(p.panel; arg1 = _rounded_rect(r, _TL_CORNER))
    empty!(tl.hits)
    # the chevron at the left of the line or of the head: up to expand, down to collapse
    x, y = minimum(r)[1] + _TL_PAD + 5, maximum(r)[2] - (a.expanded ? _TL_HEAD : _TL_COLLAPSED) / 2
    s = a.expanded ? -1 : 1
    Makie.update!(p.chevron;
        arg1 = Point2f[(x - 4, y - 2s), (x, y + 2s), (x + 4, y - 2s)])
    a.expanded ? _draw_expanded!(gui, tl, a) : _draw_collapsed!(gui, tl, a)
    _draw_tooltip!(gui, tl, a)
    return nothing
end

"""
Draws the collapsed line of the strip `tl`: per participant of the `_TL_SHOWN` that were active
last (as many as fit), its dot (a diamond for an agent), its name, its last text and its age. A
click on the line expands the strip; the mouse over a participant shows its last episode.
"""
function _draw_collapsed!(gui::LiveView, tl::_Timeline, a::_Activity)
    t, r, p = tl.theme, tl.rect, tl.plots
    ps = sort(_tl_participants(a); by = q -> q.last.t, rev = true)
    ps = ps[1:min(length(ps), _TL_SHOWN)]
    x0 = minimum(r)[1] + _TL_PAD + 18
    avail = maximum(r)[1] - _TL_PAD - x0
    y = minimum(r)[2] + _TL_COLLAPSED / 2
    # the fixed part of a participant: its dot, its name (at most 120 px) and the age
    fixed(q) = 12 + min(_tl_width(tl, q.name, true), 120) + 6 +
               _tl_width(tl, " · " * _tl_age(tl.now - q.last.t))
    k = length(ps)
    while k > 1 && sum(fixed, ps[1:k]) + (k - 1) * _TL_GAP + k * 40 > avail
        k -= 1
    end
    ps = ps[1:k]
    # the widths: those that need less than an equal share get what they need, the others share
    # the rest equally
    need = [fixed(q) + _tl_width(tl, _tl_text(q.last)) + 1 for q in ps]
    budgets = fill(0.0f0, k)
    open = collect(1:k)
    space = Float32(avail - (k - 1) * _TL_GAP)
    while !isempty(open)
        share = space / length(open)
        small = filter(i -> need[i] <= share, open)
        if isempty(small)
            budgets[open] .= share
            break
        end
        for i in small
            budgets[i] = need[i]
            space -= need[i]
        end
        filter!(i -> !(i in small), open)
    end
    dots, dot_markers, dot_colors = Point2f[], Makie.BezierPath[], RGBAf[]
    name_pos, name_text, name_colors = Point2f[], String[], RGBAf[]
    det_pos, det_text = Point2f[], String[]
    x = x0
    for (q, budget) in zip(ps, budgets)
        name = _tl_fit(tl, q.name, min(120, budget - 12), true)
        wn = _tl_width(tl, name, true)
        age = " · " * _tl_age(tl.now - q.last.t)
        rest = budget - 12 - wn - 6
        text = _tl_text(q.last)
        detail = _tl_fit(tl, text, rest - _tl_width(tl, age))
        detail = isempty(detail) ? lstrip(age, [' ', '·']) : detail * age
        w = 12 + wn + 6 + _tl_width(tl, String(detail))
        push!(dots, Point2f(x + 4, y))
        push!(dot_markers, q.agent ? _TL_DIAMOND : _TL_DOT)
        push!(dot_colors, _tl_color(gui, q.who))
        push!(name_pos, Point2f(x + 12, y))
        push!(name_text, name)
        push!(name_colors, _rgba(t.text))
        push!(det_pos, Point2f(x + 12 + wn + 6, y))
        push!(det_text, String(detail))
        push!(tl.hits, (Rect2f(x - 4, minimum(r)[2], w + 8, _TL_COLLAPSED), :mark, [q.last.n]))
        x += w + _TL_GAP
    end
    # the whole line expands the strip
    push!(tl.hits, (r, :toggle, nothing))
    _tl_scatter!(p.dots, dots, dot_markers, dot_colors, _TL_MARK + 1)
    Makie.update!(p.names; arg1 = name_pos, text = name_text, color = name_colors)
    Makie.update!(p.details; arg1 = det_pos, text = det_text)
    _tl_hide!(p.grid, p.pills, p.marks, p.eyes, p.labels)
    _tl_draw_cursor!(gui, tl, a)
    return nothing
end

"""
Draws the expanded strip `tl`: the head (the chevron, "Activity", the span or the time of the scrub
cursor), one lane per participant (see `_tl_lanes`) with its eye (follow), its dot and name, and
the marks of its episodes on the time axis of the last `tl.span` seconds ("now" at the right edge):
a dot per change, a speech bubble per message, a pill with the count where marks lie closer than
`_TL_CLUSTER`; ticks at the bottom.
"""
function _draw_expanded!(gui::LiveView, tl::_Timeline, a::_Activity)
    t, r, p = tl.theme, tl.rect, tl.plots
    lanes = _tl_lanes(a)
    (x0, y0), (W, H) = minimum(r), Makie.widths(r)
    top = y0 + H
    left = x0 + _TL_PAD
    ax0, ax1 = left + _TL_LABELS, x0 + W - _TL_PAD - 6
    tl.axis = (Float32(ax0), Float32(ax1))
    now, span = tl.now, tl.span
    xt(time) = Float32(ax1 - (now - time) / span * (ax1 - ax0))
    # the lanes: centered in the area between the head and the foot
    n = length(lanes)
    area_top, area_bottom = top - _TL_HEAD, y0 + _TL_FOOT + 6
    lane_h = min(_TL_LANE, (area_top - area_bottom) / max(n, 1))
    first_y = (area_top + area_bottom) / 2 + (n - 1) * lane_h / 2
    lane_y(i) = Float32(first_y - (i - 1) * lane_h)
    muted, border = _rgba(t.muted), _rgba(t.border)
    # head
    labels_pos, labels_text, labels_color = Point2f[], String[], RGBAf[]
    # a small text, aligned at the left, center or right of `pos`
    function label!(pos, s, c, align)
        w = _tl_width(tl, s, false, _TL_SMALL)
        dx = align === :left ? 0.0f0 : align === :center ? w / 2 : w
        push!(labels_pos, pos - Point2f(dx, 0))
        push!(labels_text, s)
        push!(labels_color, c)
        return nothing
    end
    hy = Float32(top - _TL_HEAD / 2)
    label!(Point2f(left + 18, hy), "Activity", muted, :left)
    if isnothing(a.cursor)
        label!(Point2f(ax1, hy), "last " * _tl_span_label(span), muted, :right)
    else
        label!(Point2f(ax1, hy), _tl_clock(a.cursor), _rgba(t.accent), :right)
    end
    push!(tl.hits, (Rect2f(x0, top - _TL_HEAD, W, _TL_HEAD), :toggle, nothing))
    # the grid: the baselines of the lanes and a faint line per tick
    segs, seg_colors = Point2f[], RGBAf[]
    step = _tl_tick_step(span, ax1 - ax0)
    k = 0
    while k * step <= span + 1.0e-6
        x = Float32(ax1 - k * step / span * (ax1 - ax0))
        push!(segs, Point2f(x, area_bottom - 3), Point2f(x, area_top + 2))
        push!(seg_colors, RGBAf(border.r, border.g, border.b, 0.55), RGBAf(border.r, border.g, border.b, 0.55))
        s = _tl_tick_label(k * step)
        # no label that would reach into the names of the lanes
        (k == 0 || x - _tl_width(tl, s, false, _TL_SMALL) / 2 >= ax0 - 4) &&
            label!(Point2f(x, y0 + _TL_FOOT / 2 + 2), s, muted, k == 0 ? :right : :center)
        k += 1
    end
    for i in 1:n
        y = lane_y(i)
        push!(segs, Point2f(ax0, y), Point2f(ax1, y))
        push!(seg_colors, border, border)
    end
    Makie.update!(p.grid; arg1 = segs, color = seg_colors)
    # the labels of the lanes: eye, dot, name
    eye_pos, eye_markers, eye_colors = Point2f[], Makie.BezierPath[], RGBAf[]
    dots, dot_markers, dot_colors = Point2f[], Makie.BezierPath[], RGBAf[]
    name_pos, name_text, name_colors = Point2f[], String[], RGBAf[]
    for (i, q) in enumerate(lanes)
        y = lane_y(i)
        following = a.follow == q.who
        push!(eye_pos, Point2f(left + 7, y))
        push!(eye_markers, _icon(following ? :eye : :eye_off))
        push!(eye_colors, following ? _rgba(t.accent) : RGBAf(muted.r, muted.g, muted.b, 0.7))
        push!(tl.hits, (Rect2f(left - 3, y - lane_h / 2, 20, lane_h), :eye, q.who))
        push!(dots, Point2f(left + 25, y))
        push!(dot_markers, q.agent ? _TL_DIAMOND : _TL_DOT)
        push!(dot_colors, _tl_color(gui, q.who))
        push!(name_pos, Point2f(left + 34, y))
        push!(name_text, _tl_fit(tl, q.name, _TL_LABELS - 44, true))
        push!(name_colors, _rgba(t.text))
    end
    _tl_scatter!(p.eyes, eye_pos, eye_markers, eye_colors, 15)
    _tl_scatter!(p.dots, dots, dot_markers, dot_colors, _TL_MARK + 1)
    Makie.update!(p.names; arg1 = name_pos, text = name_text, color = name_colors)
    Makie.update!(p.details; arg1 = Point2f[], text = String[])
    # the marks
    mark_pos, mark_markers, mark_colors, mark_sizes = Point2f[], Makie.BezierPath[], RGBAf[],
        Float32[]
    pills, pill_colors, pill_strokes = Makie.Polygon[], RGBAf[], RGBAf[]
    for (i, q) in enumerate(lanes)
        y = lane_y(i)
        for cluster in _tl_clusters(a, q.episodes, xt, ax0, ax1)
            ns = [a.episodes[j].n for j in cluster]
            eps = a.episodes[cluster]
            xs = [xt(ep.t) for ep in eps]
            hovered = !isnothing(a.hover) && a.hover in ns
            c = _tl_color(gui, q.who)
            if length(cluster) == 1 && only(eps).count == 1
                ep = only(eps)
                message = !isempty(ep.message)
                size = (message ? _TL_MARK + 3 : _TL_MARK) * (hovered ? _TL_MARK_HOVER / _TL_MARK : 1)
                push!(mark_pos, Point2f(only(xs), y))
                push!(mark_markers, message ? _TL_SPEECH : _TL_DOT)
                push!(mark_colors, c)
                push!(mark_sizes, size)
                h = max(size, 12)
                push!(tl.hits, (Rect2f(only(xs) - h / 2, y - lane_h / 2, h, lane_h), :mark, ns))
            else
                count = sum(ep -> ep.count, eps)
                label = string(count)
                wl = _tl_width(tl, label, false, _TL_SMALL)
                xa, xb = minimum(xs), maximum(xs)
                w = max(xb - xa + _TL_PILL, wl + 12)
                xm = clamp((xa + xb) / 2, ax0 + w / 2, ax1 + 3 - w / 2)
                pr = Rect2f(xm - w / 2, y - _TL_PILL / 2, w, _TL_PILL)
                push!(pills, Makie.Polygon(_rounded_rect(pr, _TL_PILL / 2)))
                push!(pill_colors, _tl_color(gui, q.who, hovered ? 0.42 : 0.22))
                push!(pill_strokes, _tl_color(gui, q.who, hovered ? 1.0 : 0.8))
                label!(Point2f(xm, y), label, _rgba(t.text), :center)
                push!(tl.hits, (Rect2f(minimum(pr)[1], y - lane_h / 2, w, lane_h), :mark, ns))
            end
        end
    end
    _tl_scatter!(p.marks, mark_pos, mark_markers, mark_colors, mark_sizes)
    if isempty(pills)
        Makie.update!(p.pills; visible = false)
    else
        Makie.update!(p.pills; arg1 = pills, color = pill_colors, strokecolor = pill_strokes,
            visible = true)
    end
    Makie.update!(p.labels; arg1 = labels_pos, text = labels_text, color = labels_color)
    push!(tl.hits, (Rect2f(ax0 - 4, area_bottom - 4, ax1 - ax0 + 8, area_top - area_bottom + 6), :lanes, nothing))
    _tl_draw_cursor!(gui, tl, a)
    return nothing
end

"""
    _tl_clusters(a, indices, xt, ax0, ax1) -> Vector{Vector{Int}}

The episodes `indices` (in `a.episodes`, oldest first) of a lane that lie on the time axis from
`ax0` to `ax1` (`xt` maps a time to x), grouped such that each group holds the marks that follow
each other closer than `_TL_CLUSTER` [px]; a group of one is a mark, a larger one a pill.
"""
function _tl_clusters(a::_Activity, indices::Vector{Int}, xt, ax0::Real, ax1::Real)
    groups = Vector{Int}[]
    lastx = -Inf32
    for j in indices
        x = xt(a.episodes[j].t)
        (ax0 - 2 <= x <= ax1 + 2) || continue
        if !isempty(groups) && x - lastx < _TL_CLUSTER
            push!(last(groups), j)
        else
            push!(groups, [j])
        end
        lastx = x
    end
    return groups
end

# The step [s] of the ticks of a time axis of `span` seconds over `w` pixels: about 70 px apart
function _tl_tick_step(span::Real, w::Real)
    for s in (10, 15, 30, 60, 120, 300, 600, 900, 1800)
        s / span * w >= 70 && return s
    end
    return 3600
end

# Sets the points, markers, colors and sizes of a scatter, with a hidden entry if there are none; the
# sizes are a vector always, a plot can not switch from a scalar to a vector
function _tl_scatter!(plot, pos::Vector{Point2f}, markers::Vector{<:Makie.BezierPath},
        colors::Vector{RGBAf}, size)
    if isempty(pos)
        Makie.update!(plot; arg1 = [Point2f(-100, -100)], marker = [_TL_DOT],
            color = RGBAf[_TRANSPARENT], markersize = [1.0f0])
    else
        n = length(pos)
        Makie.update!(plot; arg1 = pos, marker = markers, color = colors,
            markersize = size isa AbstractVector ? Float32.(size) : fill(Float32(size), n))
    end
    return nothing
end

# Hides the parts of the expanded strip, e.g. while it is collapsed
function _tl_hide!(grid, pills, marks, eyes, labels)
    away = Point2f(-100, -100)
    Makie.update!(grid; arg1 = [away, away], color = RGBAf[_TRANSPARENT, _TRANSPARENT])
    Makie.update!(pills; visible = false)
    for s in (marks, eyes)
        _tl_scatter!(s, Point2f[], Makie.BezierPath[], RGBAf[], 1.0f0)
    end
    Makie.update!(labels; arg1 = Point2f[], text = String[], color = RGBAf[])
    return nothing
end

# The scrub cursor: a line in the accent color across the lanes at `a.cursor`
function _tl_draw_cursor!(gui::LiveView, tl::_Timeline, a::_Activity)
    c = tl.plots.cursor
    if !a.expanded || isnothing(a.cursor)
        c.visible[] && Makie.update!(c; visible = false)
        return nothing
    end
    r = tl.rect
    ax0, ax1 = tl.axis
    x = Float32(clamp(ax1 - (tl.now - a.cursor) / tl.span * (ax1 - ax0), ax0, ax1))
    Makie.update!(c; arg1 = [Point2f(x, minimum(r)[2] + _TL_FOOT + 2),
        Point2f(x, maximum(r)[2] - _TL_HEAD + 2)], visible = true)
    return nothing
end

"""
Draws the tooltip of the hovered mark of the strip `tl` above the strip, e.g.
`Claude · 23:41:07 · moved M2 by 12 mm`, in the colors of the tooltips of the theme; hidden
without a hovered mark of the strip and while scrubbing.
"""
function _draw_tooltip!(gui::LiveView, tl::_Timeline, a::_Activity)
    p = tl.plots
    i = findfirst(h -> h[2] === :mark && !isnothing(a.hover) && a.hover in h[3], tl.hits)
    if isnothing(i) || !tl.hover_own || !isnothing(a.cursor)
        p.tip_box.visible[] && (Makie.update!(p.tip_box; visible = false);
                                Makie.update!(p.tip_text; visible = false))
        return nothing
    end
    rect, _, ns = tl.hits[i]
    vp = Rect2f(gui.ax.scene.viewport[])
    text = _tl_tooltip(a, ns)
    maxw = Makie.widths(vp)[1] - 2 * _TL_MARGIN - 20
    text = _tl_fit(tl, text, maxw)
    w, h = _tl_width(tl, text) + 20, 24.0f0
    cx = minimum(rect)[1] + Makie.widths(rect)[1] / 2
    x = clamp(cx - w / 2, minimum(vp)[1] + _TL_MARGIN, maximum(vp)[1] - _TL_MARGIN - w)
    y = maximum(tl.rect)[2] + 6
    Makie.update!(p.tip_box; arg1 = _rounded_rect(Rect2f(x, y, w, h), 6), visible = true)
    Makie.update!(p.tip_text; arg1 = Point2f(x + 10, y + h / 2), text, visible = true)
    return nothing
end

#=
Mouse
=#

# The region of the strip at the point `p` [figure px]: the first hit of the `kinds`, else `nothing`
function _tl_hit(tl::_Timeline, p::Point2f, kinds::Symbol...)
    for k in kinds, h in tl.hits
        h[2] === k && p in h[1] && return h
    end
    return nothing
end

# Whether something over the strip takes the mouse: a card, the selection card, the catalog, a part
# of the layout (e.g. the tool rail of the compact layout), the debug card
function _tl_covered(gui::LiveView)
    ev = events(gui.ax.scene)
    return any(c -> _over_card(c, ev), gui.cards.all) || _over_browse_card(gui) ||
           _over_catalog(gui) || _over_layout(gui) || _over_debug(gui)
end

# Whether the mouse at `p` is over the shown strip `tl` and nothing covers it there
_tl_over(gui::LiveView, tl::_Timeline, p::Point2f) = tl.shown && p in tl.rect && !_tl_covered(gui)

# Sets `activity.hover` to the episode `n` (`nothing`: none), as the strip's own
function _tl_set_hover!(gui::LiveView, tl::_Timeline, n::Union{Nothing, Int})
    a = _activity(gui)
    if isnothing(n)
        # the strip only clears a hover that it set
        tl.hover_own || return nothing
        tl.hover_own = false
        a.hover = nothing
    else
        tl.hover_own = true
        a.hover = n
    end
    return nothing
end

# The time [s] at the x position `x` [figure px] of the time axis of the strip
function _tl_time_at(tl::_Timeline, x::Real)
    ax0, ax1 = tl.axis
    x = clamp(x, ax0, ax1)
    return tl.now - (ax1 - x) / max(ax1 - ax0, 1) * tl.span
end

"""
    _frame_points!(gui, pts)

Moves the camera of the `gui`, animated, such that the bounding sphere of the points `pts` fills the
view, along the current view direction, like `_zoom_to_selection!`; nothing without points.
"""
function _frame_points!(gui::LiveView, pts::AbstractVector{<:Point3})
    pts = [p for p in pts if all(isfinite, p)]
    isempty(pts) && return nothing
    bb = GeometryBasics.Rect3d(pts)
    center = Vector{Float64}(minimum(bb) .+ GeometryBasics.widths(bb) ./ 2)
    # a single point or a flat box: at least 2 cm
    d = max(norm(Vector{Float64}(GeometryBasics.widths(bb))), 0.02)
    cam = cameracontrols(gui.ax.scene)
    dist = cam.settings.projectiontype[] == Makie.Perspective ? (d / 2) / sind(cam.fov[] / 2) : d / 2
    eye, lookat, up = _current_view(gui)
    o = norm(eye .- lookat) > 0 ? normalize(eye .- lookat) : [0.0, 0.0, 1.0]
    _animate_camera!(gui, center .+ dist .* o, center, up)
    return nothing
end

# The points of the objects of the episode `n` of the activity `a`: their frames, else their poses
function _tl_points(a::_Activity, n::Int)
    i = findfirst(ep -> ep.n == n, a.episodes)
    isnothing(i) && return Point3f[]
    pts = Point3f[]
    for it in a.episodes[i].items
        if !isempty(it.frame)
            append!(pts, it.frame)
        else
            for pose in (it.before, it.after)
                isnothing(pose) || push!(pts, Point3f(pose[1]...))
            end
        end
    end
    return pts
end

"""
    _connect_timeline!(gui, tl)

Connects the mouse to the strip `tl` of the `gui`, before the controls of the 3D view and the camera
(`_TL_PRIORITY`), which get nothing of what happens over the strip:

- the mouse over a mark (or a participant of the collapsed line) sets `activity.hover` and shows
  its tooltip;
- a click on the collapsed line or on the head of the expanded strip expands or collapses it; on
  the eye of a lane follows its participant or stops following (`_set_follow!`); on a mark plays its
  cue again (`_replay!`), a double click frames its objects (`_frame_points!`);
- a drag in the lanes moves the scrub cursor (`activity.cursor`), releasing ends it;
- the wheel zooms the time axis of the expanded strip from 1 min to 1 h.
"""
function _connect_timeline!(gui::LiveView, tl::_Timeline)
    ev = events(gui.ax.scene)
    listeners = gui.controls.listeners
    a = _activity(gui)
    push!(listeners, on(ev.mousebutton; priority = _TL_PRIORITY) do event
        p = Point2f(ev.mouseposition[])
        if event.action == Mouse.press
            isnothing(tl.pressed) || return Consume(true)
            _tl_over(gui, tl, p) || return Consume(false)
            # the other buttons do nothing, but their drags do not reach the camera either
            h = if event.button != Mouse.left
                nothing
            elseif a.expanded
                _tl_hit(tl, p, :toggle, :eye, :mark, :lanes)
            else
                # the collapsed line takes the click as a whole
                _tl_hit(tl, p, :toggle)
            end
            tl.pressed = isnothing(h) ? (:panel, nothing, p, false, event.button) :
                         (h[2], h[3], p, false, event.button)
            return Consume(true)
        elseif event.action == Mouse.release && !isnothing(tl.pressed)
            kind, data, _, scrubbing, button = tl.pressed
            event.button == button || return Consume(true)
            tl.pressed = nothing
            if scrubbing
                a.cursor = nothing
                _update_timeline!(gui, tl.now)
                return Consume(true)
            end
            # the release must be over what was pressed
            h = tl.shown ? _tl_hit(tl, p, kind) : nothing
            (isnothing(h) || h[3] != data) && return Consume(true)
            if kind === :toggle
                _set_expanded!(gui, !a.expanded)
            elseif kind === :eye
                _set_follow!(gui, a.follow == data ? nothing : data)
                _update_timeline!(gui, tl.now)
            elseif kind === :mark
                n = last(data)
                prev, t0 = tl.click
                if prev == n && time() - t0 < _TL_DOUBLE_CLICK
                    tl.click = (0, -Inf)
                    _frame_points!(gui, reduce(vcat, (_tl_points(a, m) for m in data); init = Point3f[]))
                else
                    tl.click = (n, time())
                    _replay!(gui, n; now = tl.now)
                end
            end
            return Consume(true)
        end
        return Consume(false)
    end)
    push!(listeners, on(ev.mouseposition; priority = _TL_PRIORITY) do xy
        p = Point2f(xy)
        if !isnothing(tl.pressed)
            kind, data, p0, scrubbing, button = tl.pressed
            if a.expanded && kind in (:mark, :lanes) && (scrubbing || maximum(abs, p - p0) >= _TL_DRAG_MIN)
                scrubbing || (tl.pressed = (kind, data, p0, true, button))
                a.cursor = _tl_time_at(tl, p[1])
                _tl_set_hover!(gui, tl, nothing)
                _update_timeline!(gui, tl.now)
            end
            return Consume(true)
        end
        if !_tl_over(gui, tl, p)
            if tl.hover_own
                _tl_set_hover!(gui, tl, nothing)
                _update_timeline!(gui, tl.now)
            end
            return Consume(false)
        end
        h = _tl_hit(tl, p, :mark)
        n = isnothing(h) ? nothing : last(h[3])
        if n != a.hover || (!isnothing(n) && !tl.hover_own)
            _tl_set_hover!(gui, tl, n)
            _update_timeline!(gui, tl.now)
        end
        # the controls do not hover the objects behind the strip, unless a drag of the 3D view goes on
        return Consume(isempty(ev.mousebuttonstate))
    end)
    push!(listeners, on(ev.scroll; priority = _TL_PRIORITY) do (_, dy)
        _tl_over(gui, tl, Point2f(ev.mouseposition[])) || return Consume(false)
        if a.expanded && dy != 0
            tl.span = clamp(tl.span * _TL_ZOOM^(-sign(dy)), _TL_SPAN_MIN, _TL_SPAN_MAX)
            _update_timeline!(gui, tl.now)
        end
        return Consume(true)
    end)
    push!(listeners, on(_ -> _update_timeline!(gui, tl.now), gui.ax.scene.viewport))
    return nothing
end
