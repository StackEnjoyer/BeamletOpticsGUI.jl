#=
Splitters of the layouts: the edge of a collapsible part towards the rest of the window is dragged
with the mouse to resize the part, e.g. a sidebar or the dock of the app layout, see `_Splitter`
=#

using Makie: Scene, Fixed, Rect2f, Point2f, Mouse, Consume, Observable, lines!, on

# Half of the width of the strip around the edge of a part that takes the mouse [px]
const _SPLITTER_HALF = 3.0f0
# Distance from the press from which a drag resizes the part [px]: a click and the two presses of a
# double click do not
const _SPLITTER_DRAG_MIN = 3.0
# Seconds within which a second press on a splitter is a double click
const _SPLITTER_DOUBLE_CLICK = 0.4
# Priority of the listeners of the splitters: before the progress window (270), the overlay (260),
# the cards (250), the controls and the camera (200) and the widgets of the parts themselves, e.g.
# the object tree and the tabs of the dock (300)
const _SPLITTER_PRIORITY = 310
# z translation of the line of the splitters: over the parts and the 3D view, under the overlay of
# the layout (`_OVERLAY_Z`) and the cards
const _SPLITTER_Z = 9400.0f0
const _SPLITTER_LINEWIDTH = 2.0f0

"""
    _Splitter(part, axis, sign, limits; active = () -> true, on_resize = () -> nothing,
        on_end = () -> nothing)

The splitter of the collapsible `part` of a layout (a `_LayoutPart`), with which the mouse resizes
it: an invisible strip of `2 * _SPLITTER_HALF` pixels around one edge of the box of the part, taken
from its computed bounding box, i.e. the layout gets no column or row for it.

- `axis`: `1` for a part whose width is changed, e.g. a sidebar, `2` for one whose height is
  changed, e.g. a dock
- `sign`: `1` if the edge is the one with the larger coordinate (the right edge, the upper edge),
  such that moving the mouse along the axis makes the part larger, `-1` for the other edge
- `limits() -> (lo, hi)`: the smallest and the largest size [px], asked for at every move
- `active() -> Bool`: whether the splitter takes the mouse; a part that is not shown never does
- `on_resize()`: called after the size of the part was changed, at most once per frame while it is
  dragged; `on_end()`: called once the drag ended or a double click restored the size, e.g. to lay
  out content again that does not follow the size on its own

A drag sets `part.size` to a `Fixed` size and calls `part.resize`, see `_Splitters`; a part that is
collapsed afterwards comes back with that size, see `_set_shown!`. `start` is the size of the part
when the splitter was made, which a double click restores, e.g. a `Relative` one. `pending` is the
size [px] that the next frame applies.
"""
mutable struct _Splitter
    const part::_LayoutPart
    const axis::Int
    const sign::Int
    const start::Any
    const limits::Function
    const active::Function
    const on_resize::Function
    const on_end::Function
    pending::Union{Nothing, Float64}
end

function _Splitter(part::_LayoutPart, axis::Int, sign::Int, limits::Function;
        active::Function = () -> true, on_resize::Function = () -> nothing,
        on_end::Function = () -> nothing)
    (axis in (1, 2) && sign in (-1, 1)) ||
        throw(ArgumentError("axis must be 1 or 2 and sign 1 or -1, got $axis and $sign"))
    return _Splitter(part, axis, sign, part.size, limits, active, on_resize, on_end, nothing)
end

"""Whether the splitter `s` takes the mouse: its part is shown and it is active."""
_splitter_active(s::_Splitter) = s.part.shown && s.active()::Bool

_splitter_rect(s::_Splitter) = Rect2f(s.part.box.layoutobservables.computedbbox[])

"""The coordinate [figure px] of the edge of the splitter `s` along its axis."""
function _splitter_edge(s::_Splitter)
    r = _splitter_rect(s)
    return Float64((s.sign > 0 ? maximum(r) : minimum(r))[s.axis])
end

"""The two ends [figure px] of the edge of the splitter `s`."""
function _splitter_ends(s::_Splitter)
    r = _splitter_rect(s)
    e = Float32(_splitter_edge(s))
    lo, hi = minimum(r), maximum(r)
    return s.axis == 1 ? (Point2f(e, lo[2]), Point2f(e, hi[2])) : (Point2f(lo[1], e), Point2f(hi[1], e))
end

"""Whether the point `p` [figure px] is on the strip of the splitter `s`, see `_Splitter`."""
function _over_splitter(s::_Splitter, p::Point2f)
    _splitter_active(s) || return false
    a, b = _splitter_ends(s)
    other = 3 - s.axis
    return abs(p[s.axis] - a[s.axis]) <= _SPLITTER_HALF && a[other] <= p[other] <= b[other]
end

"""
The size [px] of the part of the splitter `s`: its `Fixed` size, otherwise, e.g. for a `Relative`
one, the size of its box as it is laid out.
"""
_splitter_size(s::_Splitter) = _splitter_size(s, s.part.size)
_splitter_size(::_Splitter, size::Fixed) = Float64(size.x)
_splitter_size(s::_Splitter, _) = Float64(Makie.widths(_splitter_rect(s))[s.axis])

"""The size `px` within the limits of the splitter `s`, in whole pixels."""
function _splitter_clamp(s::_Splitter, px::Real)
    lo, hi = s.limits()
    return Float64(round(clamp(px, lo, max(lo, hi))))
end

"""
    _set_splitter_size!(s, size) -> Bool

Sets the size of the part of the splitter `s`, e.g. `Fixed(320)`, and resizes it if it is shown;
`on_resize` is called. Returns `false` for the size that the part has.
"""
function _set_splitter_size!(s::_Splitter, size)
    part = s.part
    part.size == size && return false
    part.size = size
    part.shown && part.resize(size)
    s.on_resize()
    return true
end

# Applies the size that a drag asked for since the last frame
function _flush_splitter!(s::_Splitter)
    px = s.pending
    isnothing(px) && return false
    s.pending = nothing
    return _set_splitter_size!(s, Fixed(px))
end

"""
    _restore_splitter!(s)

Restores the size that the part of the splitter `s` started with, see `_Splitter`; `on_end` is
called.
"""
function _restore_splitter!(s::_Splitter)
    s.pending = nothing
    _set_splitter_size!(s, s.start)
    s.on_end()
    return nothing
end

# A drag of a splitter: the mouse and the size [px] of the part at the press, and whether the mouse
# moved far enough to resize the part since
mutable struct _SplitterDrag
    const splitter::_Splitter
    const from::Point2f
    const size::Float64
    moved::Bool
end

"""
    _Splitters(figscene, splitters; color)

The `splitters` of a layout in the figure scene `figscene` and their mouse handling, see
`_connect_splitters!`:

- While the mouse is over a splitter (`hovered`) or drags it (`drag`), a line in the `color` is
  drawn along its edge, in a `scene` over the parts and the 3D view. GLMakie offers no declared way
  to change the cursor.
- A press of the left button on a splitter starts a drag and is consumed, such that neither the
  camera nor the controls of the 3D view nor a widget below the strip gets it. Once the mouse moved
  by `_SPLITTER_DRAG_MIN` pixels, the size of the part follows it within the limits of the
  splitter, in whole pixels: the size is set at most once per frame (tick) and when the button is
  released, which also calls `on_end` of the splitter.
- A second press on the same splitter within `_SPLITTER_DOUBLE_CLICK` seconds, without a drag in
  between (`last` holds the splitter and the time of the press), restores the size that the part
  started with, see `_restore_splitter!`; its release is consumed as well (`swallow`).

A splitter that is not active, e.g. of a collapsed part, takes no mouse and shows no line; a drag
ends when its splitter becomes inactive.
"""
mutable struct _Splitters
    const scene::Scene
    const splitters::Vector{_Splitter}
    const line::Observable{Vector{Point2f}}
    hovered::Union{Nothing, _Splitter}
    drag::Union{Nothing, _SplitterDrag}
    last::Union{Nothing, Tuple{_Splitter, Float64}}
    swallow::Bool
end

const _SPLITTER_NO_LINE = [Point2f(NaN), Point2f(NaN)]

function _Splitters(figscene::Scene, splitters::Vector{_Splitter}; color)
    scene = Scene(figscene; camera = Makie.campixel!, clear = false)
    translate!(scene, 0, 0, _SPLITTER_Z)
    line = Observable(copy(_SPLITTER_NO_LINE))
    lines!(scene, line; color, linewidth = _SPLITTER_LINEWIDTH, inspectable = false)
    return _Splitters(scene, splitters, line, nothing, nothing, nothing, false)
end

"""The splitter of `sp` under the point `p` [figure px], `nothing` beside all of them."""
function _splitter_at(sp::_Splitters, p::Point2f)
    i = findfirst(s -> _over_splitter(s, p), sp.splitters)
    return isnothing(i) ? nothing : sp.splitters[i]
end

"""Whether a splitter of `sp` is being dragged."""
_dragging(sp::_Splitters) = !isnothing(sp.drag)

# The splitter whose edge is marked: the dragged one, otherwise the one under the mouse
_marked_splitter(sp::_Splitters) = isnothing(sp.drag) ? sp.hovered : sp.drag.splitter

"""Draws the line along the edge of the dragged or hovered splitter of `sp`, or none."""
function _update_splitter_line!(sp::_Splitters)
    s = _marked_splitter(sp)
    points = (isnothing(s) || !_splitter_active(s)) ? _SPLITTER_NO_LINE : collect(_splitter_ends(s))
    isequal(sp.line[], points) || (sp.line[] = copy(points))
    return nothing
end

# The left button was pressed on the splitter `s` at `p`: the second press of a double click
# restores its size, any other one starts a drag
function _press_splitter!(sp::_Splitters, s::_Splitter, p::Point2f)
    now = time()
    last = sp.last
    if !isnothing(last) && last[1] === s && now - last[2] <= _SPLITTER_DOUBLE_CLICK
        sp.last = nothing
        sp.swallow = true
        _restore_splitter!(s)
    else
        sp.last = (s, now)
        sp.drag = _SplitterDrag(s, p, _splitter_size(s), false)
    end
    sp.hovered = s
    _update_splitter_line!(sp)
    return nothing
end

# The mouse moved to `p` while a splitter is dragged: the size that the next frame applies
function _drag_splitter!(sp::_Splitters, p::Point2f)
    d = sp.drag
    s = d.splitter
    delta = s.sign * Float64(p[s.axis] - d.from[s.axis])
    if !d.moved
        abs(delta) >= _SPLITTER_DRAG_MIN || return nothing
        d.moved = true
        # no double click with the next press
        sp.last = nothing
    end
    s.pending = _splitter_clamp(s, d.size + delta)
    return nothing
end

# The button was released at `p`: the last size is applied, the drag ends
function _end_splitter_drag!(sp::_Splitters, p::Point2f)
    d = sp.drag
    s = d.splitter
    sp.drag = nothing
    _flush_splitter!(s)
    d.moved && s.on_end()
    sp.hovered = _splitter_at(sp, p)
    _update_splitter_line!(sp)
    return nothing
end

# Every frame: the size of the dragged part follows the mouse, the line follows the edge; a drag
# of a splitter that is no longer active ends, e.g. of a part that was collapsed by a key
function _tick_splitters!(sp::_Splitters)
    d = sp.drag
    if !isnothing(d)
        s = d.splitter
        if _splitter_active(s)
            _flush_splitter!(s)
        else
            s.pending = nothing
            sp.drag = nothing
            sp.swallow = true
        end
    end
    _update_splitter_line!(sp)
    return nothing
end

"""
    _connect_splitters!(sp::_Splitters, events) -> listeners

Connects the splitters `sp` to the `events` of their figure scene, see `_Splitters`, with listeners
of the priority `_SPLITTER_PRIORITY`, which are returned; their owner removes them, e.g. with those
of the controls of a live view.
"""
function _connect_splitters!(sp::_Splitters, ev)
    return Any[
        on(ev.mousebutton; priority = _SPLITTER_PRIORITY) do event
            event.button == Mouse.left || return Consume(false)
            p = Point2f(ev.mouseposition[])
            if event.action == Mouse.press
                sp.swallow = false
                s = _splitter_at(sp, p)
                if isnothing(s)
                    sp.last = nothing
                    return Consume(false)
                end
                _press_splitter!(sp, s, p)
                return Consume(true)
            elseif event.action == Mouse.release
                if sp.swallow
                    sp.swallow = false
                    return Consume(true)
                end
                _dragging(sp) || return Consume(false)
                _end_splitter_drag!(sp, p)
                return Consume(true)
            end
            return Consume(false)
        end,
        on(ev.mouseposition; priority = _SPLITTER_PRIORITY) do xy
            p = Point2f(xy)
            if _dragging(sp)
                _drag_splitter!(sp, p)
                return Consume(true)
            end
            # not while something else is dragged over the edge, e.g. the camera
            sp.hovered = isempty(ev.mousebuttonstate) ? _splitter_at(sp, p) : nothing
            _update_splitter_line!(sp)
            return Consume(false)
        end,
        on(ev.entered_window) do inside
            (inside || _dragging(sp)) || (sp.hovered = nothing)
            _update_splitter_line!(sp)
            return Consume(false)
        end,
        on(_ -> _tick_splitters!(sp), ev.tick)]
end
