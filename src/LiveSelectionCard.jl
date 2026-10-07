#=
Selection card: a click on a group opens a small menu under the cursor (see `_open_menu!`), whose
entry "More" browses the parts of the group level by level, see `_browse!`
=#

using Makie: Scene, Point2f, Vec2f, Rect2f, poly!, events, on, Consume, Mouse, Keyboard

# Geometry of the selection card [px]: the height of the head, of the first entry and of the other
# entries, the width of the card at least, the width of a label at most (longer ones are
# ellipsized), the indent of the texts in their rows and the size of the icons
const _BROWSE_HEAD = 22.0f0
const _BROWSE_FIRST = 26.0f0
const _BROWSE_ROW = 22.0f0
const _BROWSE_MIN_WIDTH = 200.0f0
const _BROWSE_MAX_LABEL = 320.0f0
const _BROWSE_INDENT = 8.0f0
const _BROWSE_ICON = 16.0f0
# Radius of the corners of the boxes of the entries [px]
const _BROWSE_CORNER = 4
# Above the other cards, see `_card_z`, plus the offsets of its plots within the clip range
const _BROWSE_Z = _CARD_Z + 20
# The small text right in the head
const _BROWSE_KIND = "Selection"
# What a click does in the live view, in the help of the controls, see `_help_sections`
const _BROWSE_CLICK_HELP = "select; on a group: click again, or More for its parts"
# The text of the entry of the small menu that opens the selection card
const _BROWSE_MORE = "More ›"
# Parts shown at once: a longer list scrolls, see `_set_scroll!`; width of its scroll bar [px]
const _BROWSE_MAX_PARTS = 5
const _BROWSE_SCROLLBAR = 3.0f0
# Distance [px] of the cursor from the left edge of the first entry of a card opened at the cursor
const _BROWSE_CURSOR = 24.0f0
"""
Seconds after the entries of the open selection card changed (e.g. after "More") during which a
click on it chooses nothing: the new entries appear under the cursor, where the second click of an
accidental double click would choose one. A `Ref`, such that tests can set it to 0.
"""
const _BROWSE_GUARD = Ref(0.3)

"""
    _BrowseCard(fig::Figure, theme::NamedTuple)

The selection card of the live view (see `_browse!`): a floating card over the 3D view for the
browsed group or `MultiShape` object (`gui.objects.browsed`), like a context menu, in the color
tokens `theme` of the live view. While `compact`, it is the small menu of a click on a group, with
the entries "Select <group>" and "More" only, see `_open_menu!`. Drawn with plots in its own `scene` (a scene with a pixel camera
over the whole figure, translated to `_BROWSE_Z`), without blocks: the `background`, the box of the
first entry (`first_box`, in the accent color) and of the hovered entry (`hover_box`), the icon of
the kind of the object (`head_icon`, see `_tree_kind`), its `title` and the small text `kind` in the
head, the icon of the first entry (`entry_icon`) and the `texts` of the entries.

`entries` are the entries `(kind, obj)` of the card (see `_browse_entries`), `labels` their texts;
`visible` the indices of the entries that are shown (all, or with more than `_BROWSE_MAX_PARTS`
parts the entries before the parts and the parts from `scroll` on, see `_set_scroll!`, with the
`scrollbar`), `rects` the rectangles of the shown entries and `size` the size of the card, relative
to its top left corner `origin` [figure px] (`nothing` until it is placed, see
`_update_browse_card!`). The card is placed at `spot`, its top left corner at the cursor when it
was opened (see `_cursor_spot`), or with `spot = nothing` next to the bounding box of the browsed
object with the `corners`. `hovered` is the marked entry, under the mouse or chosen with the arrow
keys (or `nothing`), `pressed` the entry of a press on the card (0 on no entry, `nothing` without a
press on the card), `changed` the time of the last change of the entries of the open card (see
`_BROWSE_GUARD`) and `preview` the box of the browsed object in the 3D view while "Select" is
marked, see `_preview_box!`. The texts are measured once in the caches `widths` of the `font` and
`bold_widths` of the `bold` font.

A drag at the card beside its entries, i.e. at its head and its rim, moves it (see `_drag_browse!`),
e.g. off the parts that it covers: `drag` holds the mouse and the top left corner of the card at the
press and whether the mouse moved it, `nothing` without such a press. The card stays at its new
`spot` on the other levels until it is closed.
"""
mutable struct _BrowseCard
    scene::Scene
    theme::NamedTuple
    background::AbstractPlot
    first_box::AbstractPlot
    hover_box::AbstractPlot
    head_icon::AbstractPlot
    title::AbstractPlot
    kind::AbstractPlot
    entry_icon::AbstractPlot
    texts::AbstractPlot
    scrollbar::AbstractPlot
    font::Any
    bold::Any
    widths::Dict{String, Float32}
    bold_widths::Dict{String, Float32}
    entries::Vector{Tuple{Symbol, Any}}
    labels::Vector{String}
    rects::Vector{Rect2f}
    size::Vec2f
    origin::Union{Nothing, Point2f}
    corners::Vector{Point3f}
    hovered::Union{Nothing, Int}
    pressed::Union{Nothing, Int}
    visible::Vector{Int}
    scroll::Int
    compact::Bool
    spot::Union{Nothing, Point2f}
    changed::Float64
    preview::Union{Nothing, AbstractPlot}
    drag::Union{Nothing, Tuple{Point2f, Point2f, Bool}}
end

function _BrowseCard(fig::Figure, theme::NamedTuple)
    t = theme
    scene = Scene(fig.scene; camera = Makie.campixel!, clear = false)
    translate!(scene, 0, 0, _BROWSE_Z)
    box = _rounded_rect(Rect2f(0, 0, 1, 1), 0)
    background = poly!(scene, box; color = t.sidebar, strokecolor = t.border, strokewidth = 1,
        inspectable = false)
    first_box = poly!(scene, box; color = t.accent_soft, strokewidth = 0, inspectable = false)
    hover_box = poly!(scene, box; color = t.hover, strokecolor = t.accent, strokewidth = 1.5,
        inspectable = false, visible = false)
    text_kw = (; inspectable = false, markerspace = :pixel, align = (:left, :center))
    head_icon = scatter!(scene, [Point2f(0)]; marker = _icon(:group), markersize = _CARD_ICON,
        color = t.muted, markerspace = :pixel, inspectable = false)
    title = text!(scene, Point2f(0); text = "", font = :bold, fontsize = _CARD_TITLE_FONTSIZE,
        color = t.text, text_kw...)
    kind = text!(scene, Point2f(0); text = _BROWSE_KIND, fontsize = 11, color = t.muted,
        text_kw..., align = (:right, :center))
    entry_icon = scatter!(scene, [Point2f(0)]; marker = _icon(:panel_right), markersize = _BROWSE_ICON,
        color = t.accent, markerspace = :pixel, inspectable = false)
    texts = text!(scene, Point2f[]; text = String[], color = RGBAf[], fontsize = _CARD_FONTSIZE, text_kw...)
    muted = RGBAf(Makie.to_color(t.muted))
    scrollbar = poly!(scene, box; color = RGBAf(muted.r, muted.g, muted.b, 0.45), strokewidth = 0,
        inspectable = false, visible = false)
    # The boxes over the background, the texts and icons over the boxes
    foreach(p -> translate!(p, 0, 0, 1), (first_box, hover_box, scrollbar))
    foreach(p -> translate!(p, 0, 0, 2), (head_icon, title, kind, entry_icon, texts))
    scene.visible[] = false
    return _BrowseCard(scene, t, background, first_box, hover_box, head_icon, title, kind, entry_icon,
        texts, scrollbar, _tree_font(scene, :regular), _tree_font(scene, :bold), Dict{String, Float32}(),
        Dict{String, Float32}(), Tuple{Symbol, Any}[], String[], Rect2f[], Vec2f(0), nothing, Point3f[],
        nothing, nothing, Int[], 0, false, nothing, 0.0, nothing, nothing)
end

"""Returns the corners of the rectangle `r` with corners rounded by `radius` [px], for `poly!`."""
function _rounded_rect(r::Rect2f, radius::Real; n::Int = 4)
    (x0, y0), (w, h) = Makie.origin(r), Makie.widths(r)
    ρ = Float32(min(radius, w / 2, h / 2))
    pts = Point2f[]
    for (cx, cy, a0) in ((x0 + w - ρ, y0 + ρ, -π / 2), (x0 + w - ρ, y0 + h - ρ, 0.0),
            (x0 + ρ, y0 + h - ρ, π / 2), (x0 + ρ, y0 + ρ, π))
        for k in 0:n
            a = a0 + k * (π / 2) / n
            push!(pts, Point2f(cx + ρ * cos(a), cy + ρ * sin(a)))
        end
    end
    return pts
end

#=
Entries
=#

"""
    _browse_entries(gui, x) -> Vector{Tuple{Symbol, Any}}

The entries `(kind, obj)` of the selection card of `x` in the `gui`: first `(:select, x)`, which
selects `x` itself, then `(:parent, parent)` if `x` is a part of another object (see `_part_parent`),
then `(:part, p)` per direct part `p` of `x` that is not hidden, in the order of
`BeamletOptics.shape`, see `_part_children`.
"""
function _browse_entries(gui::LiveView, x)
    entries = Tuple{Symbol, Any}[(:select, x)]
    parent = _part_parent(gui, x)
    isnothing(parent) || push!(entries, (:parent, parent))
    for p in _part_children(x)
        _all_hidden(gui, p) || push!(entries, (:part, p))
    end
    return entries
end

"""
The text of the entry `(kind, obj)`: "Select <label>", "‹ <label>", "More ›" (the small menu, see
`_open_menu!`) or the label, " ›" for parts with parts.
"""
_entry_text(gui::LiveView, kind::Symbol, @nospecialize(obj)) = kind === :select ? "Select $(_label(gui, obj))" :
    kind === :parent ? "‹ $(_label(gui, obj))" : kind === :more ? _BROWSE_MORE :
    _label(gui, obj) * (isempty(_part_children(obj)) ? "" : " ›")

"""Returns the parts of the entries of the selection card `c`, see `_browse_entries`."""
_browse_parts(c::_BrowseCard) = Any[obj for (kind, obj) in c.entries if kind === :part]

# The indices of the entries of the parts of the card `c`; the other entries come before them
_part_entries(c::_BrowseCard) = findall(e -> e[1] === :part, c.entries)
# More parts than are shown at once: the list of the parts scrolls
_scrollable(c::_BrowseCard) = length(_part_entries(c)) > _BROWSE_MAX_PARTS
_max_scroll(c::_BrowseCard) = max(0, length(_part_entries(c)) - _BROWSE_MAX_PARTS)

"""
    _set_scroll!(c, scroll) -> Bool

Scrolls the parts of the selection card `c`, such that the part `scroll + 1` is the first one shown
(clamped), and sets the shown entries `c.visible`: all entries, or with more than
`_BROWSE_MAX_PARTS` parts the entries before the parts and `_BROWSE_MAX_PARTS` parts. Returns `true`
if the shown entries changed.
"""
function _set_scroll!(c::_BrowseCard, scroll::Integer)
    parts = _part_entries(c)
    c.scroll = clamp(scroll, 0, _max_scroll(c))
    shown = _scrollable(c) ? parts[(c.scroll + 1):(c.scroll + _BROWSE_MAX_PARTS)] : parts
    visible = [setdiff(eachindex(c.entries), parts); shown]
    visible == c.visible && return false
    c.visible = visible
    return true
end

#=
Layout and drawing
=#

"""
    _layout_browse!(gui, c)

Measures the texts of the entries of the selection card `c` of the `gui` and sets their `labels`,
the rectangles `rects` of the shown entries (see `_set_scroll!`) and the `size` of the card,
relative to its top left corner: the head (the icon of the kind of the browsed object, its label
and the text "Selection"), the first entry in a box, then the other shown entries one per row. The
width fits all entries, such that it does not change while the parts scroll.
"""
function _layout_browse!(gui::LiveView, c::_BrowseCard)
    x = gui.objects.browsed
    P = _CARD_PADDING
    fit(s) = _fit_text(c.widths, c.font, _CARD_FONTSIZE, s, _BROWSE_MAX_LABEL)
    width(s) = _text_width(c.widths, c.font, _CARD_FONTSIZE, s)
    c.labels = [fit(_entry_text(gui, kind, obj)) for (kind, obj) in c.entries]
    title = _fit_text(c.bold_widths, c.bold, _CARD_TITLE_FONTSIZE, _label(gui, x), _BROWSE_MAX_LABEL)
    w = _CARD_ICON + 6 + _text_width(c.bold_widths, c.bold, _CARD_TITLE_FONTSIZE, title) + 16 +
        _text_width(c.widths, c.font, 11, _BROWSE_KIND)
    for (i, s) in enumerate(c.labels)
        w = max(w, (i == 1 ? 2 * _BROWSE_INDENT + _BROWSE_ICON + 6 : 2 * _BROWSE_INDENT) + width(s))
    end
    W = max(_BROWSE_MIN_WIDTH, w + 2P)
    y = -P - _BROWSE_HEAD - 4
    rects = Rect2f[]
    for i in eachindex(c.visible)
        h = i == 1 ? _BROWSE_FIRST : _BROWSE_ROW
        push!(rects, Rect2f(P, y - h, W - 2P, h))
        y -= i == 1 ? h + 6 : h
    end
    c.rects = rects
    c.size = Vec2f(W, -y + P)
    Makie.update!(c.title; text = title)
    kind = _tree_kind(x)
    Makie.update!(c.head_icon; marker = _icon(kind), color = RGBAf(Makie.to_color(_tree_marker_color(c.theme, kind))))
    return nothing
end

# The rectangle `r` relative to the top left corner `o`, in figure px
_at(r::Rect2f, o::Point2f) = Rect2f(Makie.origin(r) .+ o, Makie.widths(r))
_center_left(r::Rect2f) = Point2f(minimum(r)[1], minimum(r)[2] + Makie.widths(r)[2] / 2)

"""Draws the selection card `c` of the `gui` with its top left corner at `c.origin`, see `_layout_browse!`."""
function _draw_browse!(gui::LiveView, c::_BrowseCard)
    o, t = c.origin, c.theme
    W, H = c.size
    Makie.update!(c.background; arg1 = _rounded_rect(Rect2f(o[1], o[2] - H, W, H), _CARD_CORNER))
    head = o[2] - _CARD_PADDING - _BROWSE_HEAD / 2
    Makie.update!(c.head_icon; arg1 = [Point2f(o[1] + _CARD_PADDING + _CARD_ICON / 2, head)])
    Makie.update!(c.title; arg1 = Point2f(o[1] + _CARD_PADDING + _CARD_ICON + 6, head))
    Makie.update!(c.kind; arg1 = Point2f(o[1] + W - _CARD_PADDING, head))
    rects = [_at(r, o) for r in c.rects]
    Makie.update!(c.first_box; arg1 = _rounded_rect(first(rects), _BROWSE_CORNER))
    p1 = _center_left(first(rects))
    Makie.update!(c.entry_icon; arg1 = [p1 + Point2f(_BROWSE_INDENT + _BROWSE_ICON / 2, 0)])
    pos = [_center_left(r) + Point2f(i == 1 ? 2 * _BROWSE_INDENT + _BROWSE_ICON - 2 : _BROWSE_INDENT, 0)
           for (i, r) in enumerate(rects)]
    colors = [RGBAf(Makie.to_color(kind === :select ? t.accent : kind === :parent ? t.muted : t.text))
              for (kind, _) in c.entries[c.visible]]
    Makie.update!(c.texts; arg1 = pos, text = c.labels[c.visible], color = colors)
    _draw_scrollbar!(c, rects)
    _draw_hover!(gui, c)
    return nothing
end

# The scroll bar right of the shown parts (the last `_BROWSE_MAX_PARTS` of the `rects` [figure px]):
# its thumb covers the share of the parts that is shown, at the place of the first one shown
function _draw_scrollbar!(c::_BrowseCard, rects::Vector{Rect2f})
    if !_scrollable(c)
        c.scrollbar.visible[] && Makie.update!(c.scrollbar; visible = false)
        return nothing
    end
    n = length(_part_entries(c))
    area = rects[(end - _BROWSE_MAX_PARTS + 1):end]
    top, bottom = maximum(first(area))[2], minimum(last(area))[2]
    h = (top - bottom) * _BROWSE_MAX_PARTS / n
    y = top - (top - bottom) * c.scroll / n
    x = maximum(first(area))[1] + 2
    Makie.update!(c.scrollbar; arg1 = _rounded_rect(Rect2f(x, y - h, _BROWSE_SCROLLBAR, h), 1.5),
        visible = true)
    return nothing
end

"""Draws the box of the hovered entry of the selection card `c`, outlined in the color of the selection box."""
function _draw_hover!(gui::LiveView, c::_BrowseCard)
    # The row of the marked entry, if it is shown
    k = isnothing(c.hovered) ? nothing : findfirst(==(c.hovered), c.visible)
    if isnothing(k) || isnothing(c.origin)
        c.hover_box.visible[] && Makie.update!(c.hover_box; visible = false)
        return nothing
    end
    Makie.update!(c.hover_box; arg1 = _rounded_rect(_at(c.rects[k], c.origin), _BROWSE_CORNER),
        strokecolor = _selection_box_color(gui), visible = true)
    return nothing
end

# The color of the selection box of the controls, see `kinematic_controls!`
_selection_box_color(gui::LiveView) = RGBAf(Makie.to_color(first(gui.controls.plots).color[]))

"""
    _update_browse_card!(gui, menu, obstacles)

Shows the selection card of the `gui` at its `spot`, where the cursor was when it was opened,
shifted into the 3D view (see `_spot_origin`), or without a spot next to the bounding box of the
browsed object (see `_card_position`), off the `obstacles` (see `_avoid`); it adds its rectangle to
the `obstacles`. Hides it while nothing is browsed or a `menu` is open. Called by `_update_cards!`
every frame; only a new position draws the card again.
"""
function _update_browse_card!(gui::LiveView, menu::Bool, obstacles::Vector{Rect2f})
    c = gui.cards.browse
    isnothing(c) && return nothing
    x = gui.objects.browsed
    if isnothing(x) || menu
        _update!(c.scene.visible, false)
        return nothing
    end
    scene = gui.ax.scene
    view = Rect2f(Makie.viewport(scene)[])
    p = if isnothing(c.spot)
        sel = _screen_rect(scene, c.corners, x)
        _avoid(_card_position(sel, c.size, view), c.size, view, obstacles)
    else
        _spot_origin(c.spot, c.size, view)
    end
    push!(obstacles, _card_rect(p, c.size))
    if c.origin != p
        c.origin = p
        _draw_browse!(gui, c)
    end
    _update!(c.scene.visible, true)
    return nothing
end

"""
    _cursor_spot(gui, c) -> Union{Nothing, Point2f}

The top left corner [figure px] of the selection card `c` of the `gui` for which the cursor lies on
its first entry, `_BROWSE_CURSOR` from its left edge; `nothing` if the cursor is not in the 3D
view, e.g. on a button of the sidebar of the app layout, then the card is placed next to its object.
"""
function _cursor_spot(gui::LiveView, c::_BrowseCard)
    m = Point2f(events(gui.ax.scene).mouseposition[])
    m in Rect2f(Makie.viewport(gui.ax.scene)[]) || return nothing
    return Point2f(m[1] - _CARD_PADDING - _BROWSE_CURSOR,
        m[2] + _CARD_PADDING + _BROWSE_HEAD + 4 + _BROWSE_FIRST / 2)
end

# The top left corner of a card of the `size` at the `spot`, shifted into the `view` with the margin
# of the cards, e.g. a list that does not fit below the cursor
function _spot_origin(spot::Point2f, size::Vec2f, view::Rect2f)
    lo, hi = minimum(view) .+ _CARD_MARGIN, maximum(view) .- _CARD_MARGIN
    return Point2f(clamp(spot[1], lo[1], max(lo[1], hi[1] - size[1])),
        clamp(spot[2], min(hi[2], lo[2] + size[2]), hi[2]))
end

"""Returns `true` if the selection card of the `gui` is shown and the mouse is over it."""
function _over_browse_card(gui::LiveView)
    c = gui.cards.browse
    (isnothing(c) || isnothing(c.origin) || !c.scene.visible[]) && return false
    return Point2f(events(gui.ax.scene).mouseposition[]) in _card_rect(c.origin, c.size)
end

"""The index of the entry of the selection card `c` at the figure pixel `p`, 0 for none."""
function _browse_entry_at(c::_BrowseCard, p::Point2f)
    isnothing(c.origin) && return 0
    k = findfirst(r -> p in _at(r, c.origin), c.rects)
    return isnothing(k) ? 0 : c.visible[k]
end

"""Marks the entry of the selection card of the `gui` under the cursor, without a mouse move."""
function _hover_at_cursor!(gui::LiveView)
    c = gui.cards.browse
    p = Point2f(events(gui.ax.scene).mouseposition[])
    _hover_browse!(gui, _over_browse_card(gui) ? _browse_entry_at(c, p) : nothing; force = true)
    return nothing
end

#=
Browsing
=#

"""
    _open_menu!(gui, x)

Opens the small menu of the group or `MultiShape` object `x` of the `gui` under the cursor: the
selection card with the entries "Select <x>", which lies under the cursor, and "More" only. A
second click without moving the mouse thus selects `x`; "More" opens its selection card at the
same place, see `_browse!`. Nothing changes in the 3D view until then, except the box of `x` while
"Select" is marked (see `_preview_box!`): `x` is not see-through, and the selection is kept. A click
beside the menu and `Esc` close it.
"""
function _open_menu!(gui::LiveView, x)
    _end_browse!(gui)
    c = gui.cards.browse
    gui.objects.browsed = x
    c.compact = true
    c.entries = Tuple{Symbol, Any}[(:select, x), (:more, x)]
    _show_entries!(gui, c, x)
    c.spot = _cursor_spot(gui, c)
    gui.status.text[] = "$(_label(gui, x)): click again to select it, More shows its parts"
    _update_cards!(gui)
    _hover_at_cursor!(gui)
    return nothing
end

# Lays out the new `entries` of the card `c` of the browsed object `x`, from its first part on
function _show_entries!(gui::LiveView, c::_BrowseCard, x)
    c.hovered, c.pressed, c.origin = nothing, nothing, nothing
    c.corners = _box_corners(_card_bbox(gui.controls, something(_plotted_part(gui, x), x)))
    empty!(c.visible)
    _set_scroll!(c, 0)
    _layout_browse!(gui, c)
    return nothing
end

"""
    _browse!(gui, x)

Opens the selection card of the group or `MultiShape` object `x` in the `gui`, or shows the level of
`x` on the open card: its entries are "Select <x>", "‹ <parent>" (below the top level) and the
direct parts of `x`, see `_browse_entries` and `_choose_entry!`; more than `_BROWSE_MAX_PARTS` parts
scroll, see `_set_scroll!`. Nothing is selected or inspected while browsing; the group is
see-through with a box per part, see `_browse_highlight!`. The card stays where it is (e.g. after
"More" of the small menu, see `_open_menu!`), or is opened at the cursor, see `_cursor_spot`. `Esc`
goes up one level (see `_browse_back!`), a click beside the parts closes the card, and so does any
selected or inspected object, see `_end_browse!`.
"""
function _browse!(gui::LiveView, x)
    ctrl = gui.controls
    c = gui.cards.browse
    open = !isnothing(gui.objects.browsed)
    if !isnothing(ctrl.selected[])
        ctrl.selected[] = nothing
        _update_selection_box!(ctrl)
    end
    _end_inspection!(gui)
    _preview_box!(gui, c, nothing)
    gui.objects.browsed = x
    c.compact = false
    c.entries = _browse_entries(gui, x)
    _show_entries!(gui, c, x)
    # New entries under the cursor: see `_BROWSE_GUARD`
    open ? (c.changed = time()) : (c.spot = _cursor_spot(gui, c))
    _browse_highlight!(gui, x, _browse_parts(c))
    gui.status.text[] = "$(_label(gui, x)): choose a part or select it, Esc goes up, drag the head to move the card"
    _update_cards!(gui)
    _hover_at_cursor!(gui)
    return nothing
end

"""
    _end_browse!(gui)

Closes the selection card of the `gui` (see `_browse!`) and restores the look of the browsed
object, see `_end_highlight!`; nothing while it is closed.
"""
function _end_browse!(gui::LiveView)
    isnothing(gui.objects.browsed) && return nothing
    gui.objects.browsed = nothing
    c = gui.cards.browse
    c.hovered, c.pressed, c.origin, c.spot, c.drag = nothing, nothing, nothing, nothing, nothing
    c.compact, c.scroll = false, 0
    empty!(c.entries)
    empty!(c.visible)
    _update!(c.scene.visible, false)
    _preview_box!(gui, c, nothing)
    _end_highlight!(gui)
    return nothing
end

"""
Goes up one level on the selection card of the `gui` (`Esc`), closes it at the top level; closes the
small menu (see `_open_menu!`).
"""
function _browse_back!(gui::LiveView)
    x = gui.objects.browsed
    isnothing(x) && return nothing
    parent = gui.cards.browse.compact ? nothing : _part_parent(gui, x)
    isnothing(parent) ? _end_browse!(gui) : _browse!(gui, parent)
    return nothing
end

"""
Opens the selection card of the object that `obj` is a part of, from the button "‹" in the head of
the card of `obj`; nothing for a top-level object.
"""
function _browse_parent!(gui::LiveView, @nospecialize(obj))
    parent = isnothing(obj) ? nothing : _part_parent(gui, obj)
    isnothing(parent) || _browse!(gui, parent)
    return nothing
end

"""
    _choose_entry!(gui, i::Integer)
    _choose_entry!(gui, obj)

Chooses the entry `i` (or the entry of `obj`) of the open selection card of the `gui`, like a click
on it: "Select <x>" selects the browsed object, "More" of the small menu opens its selection card,
"‹ <parent>" browses the parent, a part with parts browses it, any other part is selected. An object that can not be moved on its own, e.g. a lens of
a doublet, is shown on its card without being selected (see `_inspect!`), at the bounding box of the
nearest object with plots, see `_anchor_part_card!`. Selecting or inspecting closes the card.
"""
function _choose_entry!(gui::LiveView, i::Integer)
    entries = _open_entries(gui)
    1 <= i <= length(entries) || throw(ArgumentError("no entry $i on the selection card"))
    return _run_entry!(gui, entries[i]...)
end
function _choose_entry!(gui::LiveView, @nospecialize(obj))
    entries = _open_entries(gui)
    i = findfirst(e -> e[2] === obj, entries)
    isnothing(i) && throw(ArgumentError("$(_label(gui, obj)) is no entry of the selection card"))
    return _run_entry!(gui, entries[i]...)
end

function _open_entries(gui::LiveView)
    isnothing(gui.objects.browsed) && throw(ArgumentError("the selection card is not open"))
    return gui.cards.browse.entries
end

function _run_entry!(gui::LiveView, kind::Symbol, @nospecialize(obj))
    if kind in (:parent, :more) || (kind === :part && !isempty(_part_children(obj)))
        _browse!(gui, obj)
    else
        _take_part!(gui, obj)
    end
    return nothing
end

"""Closes the selection card and selects `obj`, or inspects it if it is not movable, see `_choose_entry!`."""
function _take_part!(gui::LiveView, @nospecialize(obj))
    _end_browse!(gui)
    if _is_movable(gui.controls, obj)
        _select!(gui, obj)
    else
        _inspect!(gui, obj)
        _anchor_part_card!(gui, obj)
    end
    return nothing
end

"""
    _hover_browse!(gui, i; force = false)

Marks the entry `i` (0 or `nothing`: none) of the selection card of the `gui`, under the mouse or
chosen with the arrow keys, and highlights what it stands for in the 3D view: the box of its part
(see `_hover_highlight!`), or for "Select" the box of the browsed object, see `_preview_box!`; the
other entries highlight no box. `force` draws the mark again, e.g. after the entries moved.
"""
function _hover_browse!(gui::LiveView, i; force::Bool = false)
    c = gui.cards.browse
    i = (isnothing(i) || i == 0) ? nothing : i
    (c.hovered == i && !force) && return nothing
    c.hovered = i
    _draw_hover!(gui, c)
    kind, obj = isnothing(i) ? (:none, nothing) : c.entries[i]
    _hover_highlight!(gui, kind === :part ? obj : nothing)
    _preview_box!(gui, c, kind === :select ? obj : nothing)
    return nothing
end

"""
    _preview_box!(gui, c, x)

Shows the bounding box of `x` in the 3D view of the `gui` in the color of the selection box, i.e.
what "Select" of the selection card `c` would select; `nothing` removes it.
"""
function _preview_box!(gui::LiveView, c::_BrowseCard, x)
    if !isnothing(c.preview)
        delete!(gui.ax, c.preview)
        c.preview = nothing
    end
    bb = isnothing(x) ? nothing : _part_box(gui, x)
    isnothing(bb) && return nothing
    c.preview = linesegments!(gui.ax, _bbox_wireframe(bb); color = _selection_box_color(gui),
        linewidth = _HOVER_BOX_WIDTH, clip_planes = Plane3f[], inspectable = false)
    return nothing
end

"""
    _drag_browse!(gui, c, p)

Moves the selection card `c` of the `gui` with the mouse at the figure pixel `p`, after a press on
the card beside its entries (see `c.drag`), once the mouse moved by `_CARD_DRAG_MIN` like for the
other cards (see `_drag_cards!`): the card follows the mouse inside the 3D view and stays at its new
`spot`, also on the other levels and after "More".
"""
function _drag_browse!(gui::LiveView, c::_BrowseCard, p::Point2f)
    start, origin, moved = c.drag
    d = p - start
    (moved || maximum(abs, d) >= _CARD_DRAG_MIN) || return nothing
    c.drag = (start, origin, true)
    c.spot = _spot_origin(Point2f(origin + d), c.size, Rect2f(Makie.viewport(gui.ax.scene)[]))
    _update_cards!(gui)
    return nothing
end

"""Scrolls the parts of the selection card of the `gui` by `d` rows (see `_set_scroll!`) and marks the entry under the cursor."""
function _scroll_browse!(gui::LiveView, d::Integer)
    c = gui.cards.browse
    _set_scroll!(c, c.scroll + d) || return nothing
    isnothing(c.origin) || _draw_browse!(gui, c)
    _hover_at_cursor!(gui)
    return nothing
end

"""
    _move_mark!(gui, d)

Moves the mark of the selection card of the `gui` by `d` entries (`↑`: -1, `↓`: 1), from the first
or the last entry if none is marked, and scrolls the parts such that the marked one is shown.
"""
function _move_mark!(gui::LiveView, d::Integer)
    c = gui.cards.browse
    n = length(c.entries)
    n > 0 || return nothing
    i = isnothing(c.hovered) ? (d > 0 ? 1 : n) : clamp(c.hovered + d, 1, n)
    k = findfirst(==(i), _part_entries(c))
    if !isnothing(k)
        scroll = k <= c.scroll ? k - 1 : k > c.scroll + _BROWSE_MAX_PARTS ? k - _BROWSE_MAX_PARTS : c.scroll
        _set_scroll!(c, scroll) && !isnothing(c.origin) && _draw_browse!(gui, c)
    end
    _hover_browse!(gui, i; force = true)
    return nothing
end

#=
Clicks in the 3D view
=#

"""
    _on_leaf_click!(gui, leaf) -> Bool

The click of the controls of the `gui` on the rendered object `leaf` (see `click_leaf` of
`KinematicController`): while browsing, the part under the cursor acts as its entry, a click beside
the parts closes the selection card, see `_click_while_browsing!`; a click beside the small menu
closes it and then counts like any other click. Otherwise a click on an object of a group opens
the small menu of its top-level group under the cursor (see `_open_menu!`), which closes the cards
of a beam inspection, of the background and of a failed solve; a click inside the current selection
keeps it, since a short click on the selection is usually a drag that did not move. Returns `false`
for the controls to select as before: an object that is not in a group, and any click while
measuring.
"""
function _on_leaf_click!(gui::LiveView, @nospecialize(leaf))
    try
        if !isnothing(gui.objects.browsed)
            if gui.cards.browse.compact
                _end_browse!(gui)
            else
                _click_while_browsing!(gui, _browsed_part(gui, leaf))
                return true
            end
        end
        gui.widgets.measure_toggle.active[] && return false
        chain = _chain(gui.controls, leaf)
        length(chain) > 1 || return false
        sel = gui.controls.selected[]
        (!isnothing(sel) && _has(chain, sel)) && return true
        _release_info!(gui, _SolveError)
        _release_info!(gui, _BackgroundItem)
        _clear_inspection!(gui)
        _open_menu!(gui, last(chain))
        return true
    catch e
        gui.last_error = _log_once(e, gui.last_error, "selection card")
        return false
    end
end

"""
Returns the part of the browsed object of the `gui` under the cursor after a click on the rendered
object `leaf`: the part whose plots were picked (see `_part_under_cursor`), else the part among the
entries that contains `leaf` (see `_chain`), else `nothing`.
"""
function _browsed_part(gui::LiveView, @nospecialize(leaf))
    parts = _browse_parts(gui.cards.browse)
    p = _part_under_cursor(gui, parts)
    isnothing(p) || return p
    chain = _chain(gui.controls, leaf)
    i = findfirst(q -> _has(chain, q), parts)
    return isnothing(i) ? nothing : parts[i]
end

"""A click in the 3D view while browsing: on a `part`, like its entry (see `_choose_entry!`); `nothing` closes the card."""
function _click_while_browsing!(gui::LiveView, part)
    isnothing(part) ? _end_browse!(gui) : _choose_entry!(gui, part)
    return nothing
end

"""
    _connect_browse!(gui)

Adds the selection card to the `gui` (see `_browse!`) and connects it: the clicks of the controls
on objects of groups (see `_on_leaf_click!`), the mouse over its entries (hover, click and the wheel,
which scrolls a long list of parts) and beside them (a drag moves the card, see `_drag_browse!`), the keys `↑`/`↓` (move the mark) and `Enter` (chooses the
marked entry, "Select" in the small menu if none is marked), and `Esc`, which goes up one level
(see `_browse_back!`), like the other `Esc` listeners before the controls and passed on; `Esc` that
closes the small menu is not passed on, such that the selection is kept.
"""
function _connect_browse!(gui::LiveView)
    c = _BrowseCard(gui.fig, gui.layout.theme)
    gui.cards.browse = c
    ctrl = gui.controls
    ctrl.click_leaf = function (leaf)
        @nospecialize leaf
        return _on_leaf_click!(gui, leaf)
    end
    ctrl.click_help = _BROWSE_CLICK_HELP
    push!(ctrl.help_extra, "Select" => [
        _HelpEntry(["Enter"], "in the menu of a group: choose the marked entry"),
        _HelpEntry([:mouse => "drag"], "head of the menu or of a card: move it")])
    _update_help!(ctrl)
    ev = events(gui.ax.scene)
    mouse() = Point2f(ev.mouseposition[])
    # Before the mouse shield of the cards (1), after the controls (200), which ignore the presses
    # on the card, see `_connect_cards!`
    push!(ctrl.listeners, on(ev.mousebutton, priority = 3) do event
        event.button == Mouse.left || return Consume(false)
        if event.action == Mouse.press
            if isnothing(gui.objects.browsed) || !_over_browse_card(gui)
                c.pressed = nothing
                return Consume(false)
            end
            c.pressed = _browse_entry_at(c, mouse())
            # A press beside the entries may move the card, see `_drag_browse!`
            c.drag = c.pressed == 0 ? (mouse(), c.origin, false) : nothing
            return Consume(true)
        elseif event.action == Mouse.release
            c.drag = nothing
            isnothing(c.pressed) && return Consume(false)
            i, c.pressed = c.pressed, nothing
            # Not right after the entries changed under the cursor, see `_BROWSE_GUARD`
            guarded = time() - c.changed < _BROWSE_GUARD[]
            i > 0 && !guarded && _over_browse_card(gui) && _browse_entry_at(c, mouse()) == i &&
                _choose_entry!(gui, i)
            return Consume(true)
        end
        return Consume(false)
    end)
    push!(ctrl.listeners, on(ev.mouseposition, priority = 3) do _
        isnothing(gui.objects.browsed) && return Consume(false)
        if !isnothing(c.drag)
            _drag_browse!(gui, c, mouse())
            return Consume(true)
        end
        _hover_browse!(gui, _over_browse_card(gui) ? _browse_entry_at(c, mouse()) : nothing)
        return Consume(false)
    end)
    # The wheel over a long list scrolls it, before the mouse shield of the cards (1)
    push!(ctrl.listeners, on(ev.scroll, priority = 3) do (_, dy)
        (isnothing(gui.objects.browsed) || !_over_browse_card(gui)) && return Consume(false)
        dy == 0 || _scroll_browse!(gui, dy > 0 ? -1 : 1)
        return Consume(true)
    end)
    # Before the controls (200), whose arrow keys move the selection
    push!(ctrl.listeners, on(ev.keyboardbutton, priority = 202) do event
        event.action in (Keyboard.press, Keyboard.repeat) || return Consume(false)
        (isnothing(gui.objects.browsed) || ctrl.ignore_keys()) && return Consume(false)
        if event.key in (Keyboard.up, Keyboard.down)
            _move_mark!(gui, event.key == Keyboard.down ? 1 : -1)
        elseif event.key in (Keyboard.enter, Keyboard.kp_enter)
            i = something(c.hovered, c.compact ? 1 : 0)
            (event.action == Keyboard.press && i > 0) && _choose_entry!(gui, i)
        else
            return Consume(false)
        end
        return Consume(true)
    end)
    push!(ctrl.listeners, on(ev.keyboardbutton, priority = 201) do event
        (event.action == Keyboard.press && event.key == Keyboard.escape) || return Consume(false)
        ctrl.ignore_keys() && return Consume(false)
        # Closing the small menu keeps the selection: the controls do not get this Esc
        menu = !isnothing(gui.objects.browsed) && c.compact
        _browse_back!(gui)
        return Consume(menu)
    end)
    return nothing
end
