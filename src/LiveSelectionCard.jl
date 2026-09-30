#=
Selection card: a click on a group browses its parts level by level, see `_browse!`
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
# What a click does in the live view, in the overlay of the controls, see `_help_text`
const _BROWSE_CLICK_HELP = "select, on a group: choose a part"

"""
    _BrowseCard(fig::Figure, theme::NamedTuple)

The selection card of the live view (see `_browse!`): a floating card over the 3D view next to the
browsed group or `MultiShape` object (`gui.objects.browsed`), like a context menu, in the color
tokens `theme` of the live view. Drawn with plots in its own `scene` (a scene with a pixel camera
over the whole figure, translated to `_BROWSE_Z`), without blocks: the `background`, the box of the
first entry (`first_box`, in the accent color) and of the hovered entry (`hover_box`), the icon of
the kind of the object (`head_icon`, see `_tree_kind`), its `title` and the small text `kind` in the
head, the icon of the first entry (`entry_icon`) and the `texts` of the entries.

`entries` are the entries `(kind, obj)` of the card (see `_browse_entries`), `labels` their texts,
`rects` their rectangles and `size` the size of the card, relative to its top left corner `origin`
[figure px] (`nothing` until it is placed, see `_update_browse_card!`); `corners` the corners of the
bounding box of the browsed object, at which the card is placed. `hovered` is the entry under the
mouse (or `nothing`), `pressed` the entry of a press on the card (0 on no entry, `nothing` without a
press on the card). The texts are measured once in the caches `widths` of the `font` and
`bold_widths` of the `bold` font.
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
    # The boxes over the background, the texts and icons over the boxes
    foreach(p -> translate!(p, 0, 0, 1), (first_box, hover_box))
    foreach(p -> translate!(p, 0, 0, 2), (head_icon, title, kind, entry_icon, texts))
    scene.visible[] = false
    return _BrowseCard(scene, t, background, first_box, hover_box, head_icon, title, kind, entry_icon,
        texts, _tree_font(scene, :regular), _tree_font(scene, :bold), Dict{String, Float32}(),
        Dict{String, Float32}(), Tuple{Symbol, Any}[], String[], Rect2f[], Vec2f(0), nothing, Point3f[],
        nothing, nothing)
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

"""The text of the entry `(kind, obj)`: "Select <label>", "‹ <label>" or the label, " ›" for parts with parts."""
_entry_text(gui::LiveView, kind::Symbol, obj) = kind === :select ? "Select $(_label(gui, obj))" :
    kind === :parent ? "‹ $(_label(gui, obj))" : _label(gui, obj) * (isempty(_part_children(obj)) ? "" : " ›")

"""Returns the parts of the entries of the selection card `c`, see `_browse_entries`."""
_browse_parts(c::_BrowseCard) = Any[obj for (kind, obj) in c.entries if kind === :part]

#=
Layout and drawing
=#

"""
    _layout_browse!(gui, c)

Measures the texts of the entries of the selection card `c` of the `gui` and sets their `labels`,
their rectangles `rects` and the `size` of the card, relative to its top left corner: the head (the
icon of the kind of the browsed object, its label and the text "Selection"), the first entry in a
box, then the other entries one per row.
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
    for i in eachindex(c.labels)
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
              for (kind, _) in c.entries]
    Makie.update!(c.texts; arg1 = pos, text = copy(c.labels), color = colors)
    _draw_hover!(gui, c)
    return nothing
end

"""Draws the box of the hovered entry of the selection card `c`, outlined in the color of the selection box."""
function _draw_hover!(gui::LiveView, c::_BrowseCard)
    i = c.hovered
    if isnothing(i) || isnothing(c.origin) || !(1 <= i <= length(c.rects))
        c.hover_box.visible[] && Makie.update!(c.hover_box; visible = false)
        return nothing
    end
    Makie.update!(c.hover_box; arg1 = _rounded_rect(_at(c.rects[i], c.origin), _BROWSE_CORNER),
        strokecolor = _selection_box_color(gui), visible = true)
    return nothing
end

# The color of the selection box of the controls, see `kinematic_controls!`
_selection_box_color(gui::LiveView) = RGBAf(Makie.to_color(first(gui.controls.plots).color[]))

"""
    _update_browse_card!(gui, menu, obstacles)

Shows the selection card of the `gui` next to the bounding box of the browsed object (see
`_card_position`), off the `obstacles` (see `_avoid`), to which it adds its rectangle; hides it while
nothing is browsed or a `menu` is open. Called by `_update_cards!` every frame; only a new position
draws the card again.
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
    sel = _screen_rect(scene, c.corners, x)
    p = _avoid(_card_position(sel, c.size, view), c.size, view, obstacles)
    push!(obstacles, _card_rect(p, c.size))
    if c.origin != p
        c.origin = p
        _draw_browse!(gui, c)
    end
    _update!(c.scene.visible, true)
    return nothing
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
    i = findfirst(r -> p in _at(r, c.origin), c.rects)
    return something(i, 0)
end

#=
Browsing
=#

"""
    _browse!(gui, x)

Opens the selection card of the group or `MultiShape` object `x` in the `gui`, or shows the level of
`x` on the open card: its entries are "Select <x>", "‹ <parent>" (below the top level) and the
direct parts of `x`, see `_browse_entries` and `_choose_entry!`. Nothing is selected or inspected
while browsing; the group is see-through with a box per part, see `_browse_highlight!`. A click on
an object of a group in the 3D view opens the card of its top-level group, see `_on_leaf_click!`;
`Esc` goes up one level (see `_browse_back!`), a click beside the parts closes the card, and so
does any selected or inspected object, see `_end_browse!`.
"""
function _browse!(gui::LiveView, x)
    ctrl = gui.controls
    c = gui.cards.browse
    if !isnothing(ctrl.selected[])
        ctrl.selected[] = nothing
        _update_selection_box!(ctrl)
    end
    _end_inspection!(gui)
    gui.objects.browsed = x
    c.entries = _browse_entries(gui, x)
    c.hovered, c.pressed, c.origin = nothing, nothing, nothing
    c.corners = _box_corners(_card_bbox(ctrl, something(_plotted_part(gui, x), x)))
    _layout_browse!(gui, c)
    _browse_highlight!(gui, x, _browse_parts(c))
    gui.status.text[] = "$(_label(gui, x)): choose a part or select it, Esc goes up"
    _update_cards!(gui)
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
    c.hovered, c.pressed, c.origin = nothing, nothing, nothing
    empty!(c.entries)
    _update!(c.scene.visible, false)
    _end_highlight!(gui)
    return nothing
end

"""Goes up one level on the selection card of the `gui` (`Esc`), closes it at the top level."""
function _browse_back!(gui::LiveView)
    x = gui.objects.browsed
    isnothing(x) && return nothing
    parent = _part_parent(gui, x)
    isnothing(parent) ? _end_browse!(gui) : _browse!(gui, parent)
    return nothing
end

"""
Opens the selection card of the object that `obj` is a part of, from the button "‹" in the head of
the card of `obj`; nothing for a top-level object.
"""
function _browse_parent!(gui::LiveView, obj)
    parent = isnothing(obj) ? nothing : _part_parent(gui, obj)
    isnothing(parent) || _browse!(gui, parent)
    return nothing
end

"""
    _choose_entry!(gui, i::Integer)
    _choose_entry!(gui, obj)

Chooses the entry `i` (or the entry of `obj`) of the open selection card of the `gui`, like a click
on it: "Select <x>" selects the browsed object, "‹ <parent>" browses the parent, a part with parts
browses it, any other part is selected. An object that can not be moved on its own, e.g. a lens of
a doublet, is shown on its card without being selected (see `_inspect!`), at the bounding box of the
nearest object with plots, see `_anchor_part_card!`. Selecting or inspecting closes the card.
"""
function _choose_entry!(gui::LiveView, i::Integer)
    entries = _open_entries(gui)
    1 <= i <= length(entries) || throw(ArgumentError("no entry $i on the selection card"))
    return _run_entry!(gui, entries[i]...)
end
function _choose_entry!(gui::LiveView, obj)
    entries = _open_entries(gui)
    i = findfirst(e -> e[2] === obj, entries)
    isnothing(i) && throw(ArgumentError("$(_label(gui, obj)) is no entry of the selection card"))
    return _run_entry!(gui, entries[i]...)
end

function _open_entries(gui::LiveView)
    isnothing(gui.objects.browsed) && throw(ArgumentError("the selection card is not open"))
    return gui.cards.browse.entries
end

function _run_entry!(gui::LiveView, kind::Symbol, obj)
    if kind === :parent || (kind === :part && !isempty(_part_children(obj)))
        _browse!(gui, obj)
    else
        _take_part!(gui, obj)
    end
    return nothing
end

"""Closes the selection card and selects `obj`, or inspects it if it is not movable, see `_choose_entry!`."""
function _take_part!(gui::LiveView, obj)
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
    _hover_browse!(gui, i)

Highlights the entry `i` (0 or `nothing`: none) of the selection card of the `gui` under the mouse,
and the box of its part in the 3D view, see `_hover_highlight!`; the other entries highlight no box.
"""
function _hover_browse!(gui::LiveView, i)
    c = gui.cards.browse
    i = (isnothing(i) || i == 0) ? nothing : i
    c.hovered == i && return nothing
    c.hovered = i
    _draw_hover!(gui, c)
    part = isnothing(i) ? nothing : (c.entries[i][1] === :part ? c.entries[i][2] : nothing)
    _hover_highlight!(gui, part)
    return nothing
end

#=
Clicks in the 3D view
=#

"""
    _on_leaf_click!(gui, leaf) -> Bool

The click of the controls of the `gui` on the rendered object `leaf` (see `click_leaf` of
`KinematicController`): while browsing, the part under the cursor acts as its entry, a click beside
the parts closes the selection card, see `_click_while_browsing!`. Otherwise an object of a group
opens the selection card of its top-level group (see `_browse!`), which closes the cards of a beam
inspection, of the background and of a failed solve. Returns `false` for the controls to select as
before: an object that is not in a group, and any click while measuring.
"""
function _on_leaf_click!(gui::LiveView, leaf)
    try
        if !isnothing(gui.objects.browsed)
            _click_while_browsing!(gui, _browsed_part(gui, leaf))
            return true
        end
        gui.widgets.measure_toggle.active[] && return false
        chain = _chain(gui.controls, leaf)
        length(chain) > 1 || return false
        _release_info!(gui, _SolveError)
        _release_info!(gui, _BackgroundItem)
        _clear_inspection!(gui)
        _browse!(gui, last(chain))
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
function _browsed_part(gui::LiveView, leaf)
    parts = _browse_parts(gui.cards.browse)
    p = _part_under_cursor(gui, parts)
    isnothing(p) || return p
    chain = _chain(gui.controls, leaf)
    i = findfirst(q -> any(o -> o === q, chain), parts)
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
on objects of groups (see `_on_leaf_click!`), the mouse over its entries (hover and click) and
`Esc`, which goes up one level (see `_browse_back!`), like the other `Esc` listeners before the
controls and passed on.
"""
function _connect_browse!(gui::LiveView)
    c = _BrowseCard(gui.fig, gui.layout.theme)
    gui.cards.browse = c
    ctrl = gui.controls
    ctrl.click_leaf = leaf -> _on_leaf_click!(gui, leaf)
    ctrl.click_help = _BROWSE_CLICK_HELP
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
            return Consume(true)
        elseif event.action == Mouse.release
            isnothing(c.pressed) && return Consume(false)
            i, c.pressed = c.pressed, nothing
            i > 0 && _over_browse_card(gui) && _browse_entry_at(c, mouse()) == i && _choose_entry!(gui, i)
            return Consume(true)
        end
        return Consume(false)
    end)
    push!(ctrl.listeners, on(ev.mouseposition, priority = 3) do _
        isnothing(gui.objects.browsed) && return Consume(false)
        _hover_browse!(gui, _over_browse_card(gui) ? _browse_entry_at(c, mouse()) : nothing)
        return Consume(false)
    end)
    push!(ctrl.listeners, on(ev.keyboardbutton, priority = 201) do event
        (event.action == Keyboard.press && event.key == Keyboard.escape) || return Consume(false)
        ctrl.ignore_keys() || _browse_back!(gui)
        return Consume(false)
    end)
    return nothing
end
