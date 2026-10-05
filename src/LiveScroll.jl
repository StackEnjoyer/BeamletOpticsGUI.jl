#=
Scroll areas of the layouts: a column of blocks that may be higher than its place in the window and
is scrolled with the mouse wheel, e.g. a sidebar of the app layout, see `_ScrollArea`
=#

using Makie: Scene, GridLayout, Outside, Fixed, Auto, Rect2f, Point2f, Vec2f, Mouse, Consume, events, lift,
             on, rowsize!

# Depth of the content of a scroll area: behind the other parts of the window, which cover what is
# scrolled out of its region; its background lies behind it
const _SCROLL_Z = -5000.0f0
const _SCROLL_BACKGROUND_Z = -6000.0f0
# Pixels per step of the mouse wheel
const _SCROLL_STEP = 40.0
# Priority of the listeners that pass the mouse on to the blocks of a scroll area, and of its wheel:
# before the camera and the kinematic controls of the 3D view (200), like the object tree
const _SCROLL_PRIORITY = 50
const _SCROLL_WHEEL_PRIORITY = 290
# Width of the scroll bar and its distance from the right edge of the region [px]
const _SCROLLBAR_WIDTH = 4.0f0
const _SCROLLBAR_INSET = 3.0f0
# Where the mouse is for the blocks of a scroll area while it is outside of its region: not where
# collapsed parts are laid out (`_OFFSCREEN`), whose blocks would take the presses
const _SCROLL_NOWHERE = (-1.0e6, -1.0e6)

"""
    _ScrollArea

A column of blocks that scrolls within the `region` [figure px] of the window, e.g. a sidebar of
the app layout. Makie has no scroll container and GLMakie does not clip plots, hence:

- The blocks are placed in the `layout`, a `GridLayout` that is not part of the layout of the
  figure: its bounding box has the width of the region and the `height` of its content, its top at
  the top of the region, and is moved up by the `offset` [px], see `_set_offset!`. Blocks are added
  to it as to any layout, e.g. `Label(area.layout[1, 1], ...)`.
- Their parent is the `scene`, which is pushed back in depth (`_SCROLL_Z`): what is scrolled out of
  the region is covered by the parts of the window above and below it, which must be opaque, e.g.
  the toolbar and the status bar of the app layout. A background of the region belongs behind it,
  at `_SCROLL_BACKGROUND_Z`.
- The scene has `events` of its own, see `_gated_events`: the blocks see the mouse only while it is
  in the region, such that a block that is scrolled below the toolbar does not take a click on the
  toolbar. Code that compares the mouse position with the bounding box of a block of the area must
  use these events as well, or `_in_area`.

The mouse wheel in the region scrolls by `_SCROLL_STEP` pixels per step, unless a block of the area
takes it, e.g. an open menu or the object tree; a scroll bar at the right edge shows the position
while the content is higher than the region.

One row of the layout may be `elastic` (see `_set_elastic!`): it takes the height that the other
rows leave free in the region, at least `min_elastic`, e.g. the object tree or the filler below the
sections of a sidebar; `elastic_size` is its current height. The other rows must tell their height
(`Auto()` or `Fixed`), otherwise the area does not scroll and has the height of the region. A
hidden area (`shown = false`, see `_set_area_shown!`) is laid out off-screen.
"""
mutable struct _ScrollArea
    const scene::Scene
    const layout::GridLayout
    const region::Observable{Rect2f}
    const offset::Observable{Float64}
    const height::Observable{Float64}
    const visible::Observable{Bool}
    const events::Makie.Events
    const listeners::Vector{Any}
    elastic::Int
    min_elastic::Float64
    elastic_size::Float64
    fitting::Bool
end

"""
    _gated_events(src::Makie.Events, inside; priority) -> (events, scroll, listeners)

Events for the blocks of a scroll area: the observables of `src`, except those of the mouse. The
position of the mouse is passed on while `inside(position)` holds, or while a button is held that
was pressed inside, e.g. during the drag of a slider; otherwise the mouse is far outside of the
window for the blocks (`_SCROLL_NOWHERE`). Presses and releases are always passed on, such that a
press elsewhere takes the focus from a textbox and closes a menu. The wheel is not passed on: the
owner sets and notifies the returned `scroll`, see `_ScrollArea`. An event that a block consumes is
consumed in `src`.
"""
function _gated_events(src::Makie.Events, inside; priority::Int = _SCROLL_PRIORITY)
    button = Observable(src.mousebutton[])
    position = Observable(src.mouseposition[])
    scroll = Observable(src.scroll[])
    own = (; mousebutton = button, mouseposition = position, scroll)
    ev = Makie.Events((get(own, f, getfield(src, f)) for f in fieldnames(Makie.Events))...)
    captured = Ref(false)
    function forward(p)
        q = (captured[] || inside(p)) ? p : _SCROLL_NOWHERE
        (q == position[] && q == _SCROLL_NOWHERE) && return false
        position.val = q
        return notify(position)
    end
    listeners = Any[
        on(p -> Consume(forward(p)), src.mouseposition; priority),
        on(src.mousebutton; priority) do event
            event.action == Mouse.press && (captured[] = inside(src.mouseposition[]))
            button.val = event
            consumed = notify(button)
            if event.action == Mouse.release && isempty(src.mousebuttonstate)
                captured[] = false
                forward(src.mouseposition[])
            end
            return Consume(consumed)
        end]
    return ev, scroll, listeners
end

"""
    _ScrollArea(figscene::Scene, region::Observable{Rect2f}; padding = 0, layout_kwargs...)

Creates a scroll area in the `region` [px] of the figure scene `figscene`, see `_ScrollArea`:
`padding` is the distance of its blocks from the edges of the region, `layout_kwargs` are passed to
its `GridLayout`.
"""
function _ScrollArea(figscene::Scene, region::Observable{Rect2f}; padding = 0, layout_kwargs...)
    src = events(figscene)
    visible = Observable(true)
    inside(p) = visible[] && Point2f(p[1], p[2]) in region[]
    ev, wheel, listeners = _gated_events(src, inside)
    scene = Scene(figscene; camera = Makie.campixel!, events = ev, clear = false)
    translate!(scene, 0, 0, _SCROLL_Z)
    offset, height = Observable(0.0), Observable(0.0)
    bbox = lift(scene, region, offset, height, visible) do r, o, h, v
        w, hr = Makie.widths(r)
        # before the first fit: the height of the region
        h > 0 || (h = Float64(hr))
        v || return Rect2f(_OFFSCREEN, Vec2f(w, h))
        x0, y0 = Makie.origin(r)
        return Rect2f(x0, y0 + hr + o - h, w, h)
    end
    layout = GridLayout(; bbox, alignmode = Outside(padding), layout_kwargs...)
    layout.parent = scene
    area = _ScrollArea(scene, layout, region, offset, height, visible, ev, listeners, 0, 0.0, 0.0, false)
    # The wheel: first the blocks of the area, e.g. the list of an open menu, then the area
    push!(listeners, on(src.scroll; priority = _SCROLL_WHEEL_PRIORITY) do s
        inside(src.mouseposition[]) || return Consume(false)
        wheel.val = s
        notify(wheel) && return Consume(true)
        _max_offset(area) > 0 || return Consume(false)
        _set_offset!(area, area.offset[] - _SCROLL_STEP * s[2])
        return Consume(true)
    end)
    # The height follows the content and the window
    push!(listeners, on(_ -> _fit_area!(area), _GLB.autosizeobservable(layout)))
    push!(listeners, on(_ -> _fit_area!(area), region))
    _scrollbar!(area)
    return area
end

"""The largest offset of the scroll `area` [px]: how far its content is higher than its region."""
_max_offset(a::_ScrollArea) = max(0.0, a.height[] - Float64(Makie.widths(a.region[])[2]))

"""
    _set_offset!(area, offset)

Scrolls the `area` such that its content is moved up by `offset` [px], within 0 (its top at the
top of the region) and `_max_offset`.
"""
function _set_offset!(a::_ScrollArea, offset::Real)
    o = clamp(Float64(offset), 0.0, _max_offset(a))
    a.offset[] == o || (a.offset[] = o)
    return nothing
end

"""Whether the point `p` [figure px] is in the region of the scroll `area` while it is shown."""
_in_area(a::_ScrollArea, p) = a.visible[] && Point2f(p[1], p[2]) in a.region[]

"""
    _set_elastic!(area, row::Int, min_height = 0)

Makes the `row` of the layout of the scroll `area` its elastic row, see `_ScrollArea`: it takes the
free height of the region, at least `min_height` [px]. The row that was elastic before tells its
height again (`Auto()`). `row = 0`: none, e.g. while the rows of the layout are rearranged, which
must not set the size of the elastic row themselves.
"""
function _set_elastic!(a::_ScrollArea, row::Int, min_height::Real = 0)
    old = a.elastic
    a.elastic, a.min_elastic = 0, Float64(min_height)
    (0 < old <= _GLB.nrows(a.layout) && old != row) && rowsize!(a.layout, old, Auto())
    a.elastic = row
    row > 0 && rowsize!(a.layout, row, Fixed(a.elastic_size))
    _fit_area!(a)
    return nothing
end

"""
    _fit_area!(area)

Sets the height of the content of the scroll `area` to that of its rows after the content or the region changed: the elastic row gets the height that the others
leave free, at least its smallest one, see `_set_elastic!`; the offset stays within its limits. If
a row does not tell its height, the content has the height of the region, i.e. it does not scroll.
"""
function _fit_area!(a::_ScrollArea)
    a.fitting && return nothing
    a.fitting = true
    try
        hr = Float64(Makie.widths(a.region[])[2])
        total = _GLB.determinedirsize(a.layout, _GLB.Row())
        h = hr
        if !isnothing(total)
            if 0 < a.elastic <= _GLB.nrows(a.layout)
                rest = Float64(total) - a.elastic_size
                x = max(a.min_elastic, hr - rest)
                if abs(x - a.elastic_size) > 0.25
                    a.elastic_size = x
                    rowsize!(a.layout, a.elastic, Fixed(x))
                end
                h = rest + x
            else
                h = Float64(total)
            end
        end
        abs(a.height[] - h) > 0.25 && (a.height[] = h)
        _set_offset!(a, a.offset[])
    finally
        a.fitting = false
    end
    return nothing
end

"""
    _set_area_shown!(area, shown::Bool)

Shows the scroll `area` or lays it out off-screen, where its blocks take no mouse events, e.g. of a
collapsed sidebar, see `_set_shown!`. The blocks themselves are hidden by the caller.
"""
function _set_area_shown!(a::_ScrollArea, shown::Bool)
    a.visible[] == shown || (a.visible[] = shown)
    return nothing
end

# The scroll bar of the area: a line at the right edge of its region, over its content
function _scrollbar!(a::_ScrollArea)
    points = lift(a.scene, a.region, a.offset, a.height, a.visible) do r, o, h, v
        hr = Float64(Makie.widths(r)[2])
        (v && h > hr + 0.5) || return [Point2f(NaN), Point2f(NaN)]
        x = maximum(r)[1] - _SCROLLBAR_INSET - _SCROLLBAR_WIDTH / 2
        track = hr - 2 * _SCROLLBAR_INSET
        len = max(track * hr / h, min(20.0, track))
        y = maximum(r)[2] - _SCROLLBAR_INSET - (track - len) * o / (h - hr)
        return [Point2f(x, y), Point2f(x, y - len)]
    end
    bar = lines!(a.scene, points; color = RGBAf(0.5, 0.52, 0.55, 0.5), linewidth = _SCROLLBAR_WIDTH,
        linecap = :round, inspectable = false)
    # over the blocks of the area, below the parts that cover it
    translate!(bar, 0, 0, 100)
    return bar
end
