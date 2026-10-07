#=
Property inspector of the app layout of the live view (`live_view(...; layout = :app)`): the
"PROPERTIES" section of the right sidebar, see `_Inspector`
=#

using Makie: Button, Box, Label, Textbox, GridLayout, Observable, Point2f, RGBAf, BezierPath,
             scatter!, text!, linesegments!, lift, on, rowgap!, colgap!, rowsize!, Fixed, Auto

#=
Docked cards: the card of the selection in the inspector and the pinned cards below it, see
`_AbstractCard`
=#

"""
    _DockedCard

A card docked in the "Properties" section of the app layout, the counterpart of the floating
`_ComponentCard` (see `_AbstractCard`): the widgets declared by [`card_actions`](@ref) (in
`actions`, in the head) and [`card_rows`](@ref) (in `rows`), built by the same code as the floating
cards (see `_build_content!`), but in the colors of the `theme` of the app and with the textboxes
and sliders filling the width of the sidebar (see `_cell_attributes`). It is either

- the card of the selection (`pinned = false`), whose head is the header of the inspector, see
  `_Inspector`, or
- a card `pinned` to the object `obj`, stacked below the inspector with its own `head` (icon,
  title, float button, pin and collapse chevron, built by the shared parts of `LiveCard.jl`), see
  `_dock_pinned!`; a `collapsed` card shows only its head and its actions. The float button moves
  it into the 3D view as a floating `_ComponentCard`, see `_float!`.

Like a floating card, it shows one `page` of its object at a time (see `_card_pages` and
`_show_page!`), chosen in the page bar `bar` below its head; a card with a single page has no bar.
The bar and the content of the pages are collapsible parts (`_LayoutPart`s) in the rows of the
`parent` from `first_row` on, one below the other:

- `bar_part`: the page bar, a `_Segmented` per set of pages (`bars`, built when first needed), of
  which the one of the `pages` of the object is shown
- `rows_part` (page "Pose"): the `rows` of [`card_rows`](@ref)
- `step_part` (page "Pose", only on the card of the selection, else `nothing`): the keyboard step
  and the mode of the controls, the widgets `step` of `_selection_part!`; also shown without a
  selection
- `view_part` (page "Results"): the `view` of the results of a detector (a `_DetectorView`, built
  when the page is first shown) as wide as the sidebar; `view_expanded` is its state (expanded or
  the thumbnail), the axis of the expanded view is as high as wide; `view_obj` is the object that the
  view shows, `shown_view` the one whose view was shown by the last refresh, see
  `_announce_views!`
- `properties_part` (page "Properties"): the `list` of the properties of the object; on the card
  of the selection, the summary of the live view without a selection

The rows of the parts that are not shown have neither a height nor a gap (`gap` between the shown
ones), see `_set_rowgaps!`. `header` and `parent` hold the layouts of the head and of the card: the
actions are placed in the rows `actions_rows` of column 3 of the `header`. The fields `widgets` to
`pose` are those of `_ComponentCard`.
"""
mutable struct _DockedCard <: _AbstractCard
    const header::GridLayout
    const parent::GridLayout
    const theme::NamedTuple
    const actions_rows::UnitRange{Int}
    const first_row::Int
    const gap::Float32
    actions::GridLayout
    rows::GridLayout
    widgets::Vector{Tuple{Any, CardWidget}}
    blocks::Vector{Any}
    textboxes::Vector{Textbox}
    listeners::Vector{Any}
    content_key::Any
    refreshing::Bool
    pose::Any
    pinned::Bool
    obj::Any
    collapsed::Bool
    # the parts of the head of a pinned card, `nothing` for the card of the selection
    head::Any
    # the page that is shown, the pages of the shown bar and the bars per set of pages
    page::Symbol
    pages::Tuple{Vararg{Symbol}}
    const bars::Dict{Any, _Segmented}
    bar::Union{Nothing, _Segmented}
    const bar_part::_LayoutPart
    const rows_part::_LayoutPart
    const step_part::Union{Nothing, _LayoutPart}
    const view_part::_LayoutPart
    const properties_part::_LayoutPart
    # the step box and the mode of the card of the selection, `nothing` for a pinned card
    const step::Any
    const list::_PropertyList
    view::Union{Nothing, _DetectorView}
    view_expanded::Bool
    view_obj::Any
    shown_view::Any
    view_listeners::Vector{Any}
end

# Positions of the actions in the header and of the rows in their part of the card
_docked_actions(c::_DockedCard) = _docked_actions(c.header, c.actions_rows)
_docked_actions(header::GridLayout, rows::UnitRange{Int}) = GridLayout(header[rows, 3]; default_colgap = 4)
_docked_rows_layout(part::_LayoutPart) =
    GridLayout(part.grid[1, 1]; default_rowgap = 4, tellwidth = false)

"""
Returns a collapsible part of a docked card in the `row` of its layout `parent`, see `_LayoutPart`:
its row has no height while the part is not shown.
"""
function _docked_part(parent::GridLayout, row::Int; kwargs...)
    box = Box(parent[row, 1]; visible = false)
    # content that is narrower than the sidebar, e.g. the thumbnail of a view, starts at its left edge
    grid = GridLayout(parent[row, 1]; tellwidth = false, halign = :left, kwargs...)
    return _LayoutPart(parent, (row, 1), s -> rowsize!(parent, row, s), Auto(), box, grid, true)
end

function _DockedCard(header::GridLayout, parent::GridLayout, theme::NamedTuple;
        actions_rows::UnitRange{Int} = 1:2, first_row::Int = 2, gap::Real = 4, selection::Bool = true)
    t = theme
    row = Ref(first_row - 1)
    part(; kwargs...) = _docked_part(parent, row[] += 1; kwargs...)
    bar_part, rows_part = part(), part()
    step_part = selection ? part(; default_colgap = 6) : nothing
    view_part, properties_part = part(), part()
    # Step and mode like on the floating card of the selection, see `_selection_part!`
    step = selection ? _selection_part!(step_part.grid, properties_part.grid[1, 1], t) : nothing
    list = selection ? step.list : _PropertyList(properties_part.grid[1, 1]; label_color = t.muted,
        value_color = t.text, line_color = RGBAf(Makie.to_color(t.border)))
    rowgap!(parent, gap)
    return _DockedCard(header, parent, t, actions_rows, first_row, gap,
        _docked_actions(header, actions_rows), _docked_rows_layout(rows_part),
        Tuple{Any, CardWidget}[], Any[], Textbox[], Any[], nothing, false, nothing, false, nothing,
        false, nothing, :pose, (), Dict{Any, _Segmented}(), nothing, bar_part, rows_part, step_part,
        view_part, properties_part, step, list, nothing, true, nothing, nothing, Any[])
end

function _new_parts!(c::_DockedCard)
    for part in (c.actions, c.rows)
        _GLB.remove_from_gridlayout!(_GLB.gridcontent(part))
    end
    c.actions, c.rows = _docked_actions(c), _docked_rows_layout(c.rows_part)
    return nothing
end

_card_object(gui::LiveView, c::_DockedCard) = c.pinned ? c.obj : _shown_object(gui)
# The properties of a docked card are on its page "Properties", see `_show_page!`
_refresh_selection_part!(::LiveView, ::_DockedCard, _) = nothing
_refresh_selection_part!(::LiveView, ::_DockedCard, ::Nothing) = nothing
_card_boxes(c::_DockedCard) = c.textboxes
# A collapsed card shows only its actions
_declarations(gui::LiveView, c::_DockedCard, @nospecialize(obj)) =
    (_head_actions(obj), c.collapsed ? () : _page_rows(gui, obj, c.page))

# The widgets take the theme of the figure, texts and axis colors from the tokens of the app
_card_style(c::_DockedCard, ::Type{Label}) = (; color = c.theme.text, fontsize = 12)
_card_style(::_DockedCard, ::Type{Textbox}) = (; fontsize = 12, textpadding = (5, 5, 4, 4))
_card_style(::_DockedCard, ::Type{Button}) = (; fontsize = 12, padding = (7, 7, 4, 4))
_card_style(::_DockedCard, ::Type) = (;)
_card_value(c::_DockedCard, a::_AxisColor) = c.theme.gizmo[a.k]
_row_attributes(::_DockedCard) = (; default_colgap = 6, tellwidth = false, halign = :left)

# Textboxes and sliders fill the width of the sidebar instead of the width declared for the card
_host_attributes(::_DockedCard, T::Type, attributes::NamedTuple) = _fill_width(T, attributes)
_fill_width(::Type{<:Union{Textbox, Slider}}, attributes) =
    merge(attributes, (; width = Relative(1), tellwidth = false))
_fill_width(::Type, attributes) = attributes

#=
Pages of a docked card
=#

# The collapsible parts of the card `c`, in the order of their rows
_card_parts(c::_DockedCard) = _LayoutPart[p for p in (c.bar_part, c.rows_part, c.step_part,
    c.view_part, c.properties_part) if !isnothing(p)]

"""
    _set_rowgaps!(grid::GridLayout, shown, gap)

Sets the gaps of the rows of the `grid` such that only the rows that are `shown` (a `Bool` per row)
are `gap` pixels apart: a row without a height takes no gap either. Only changed gaps update the
layout.
"""
function _set_rowgaps!(grid::GridLayout, shown::Vector{Bool}, gap::Real)
    for i in 1:(length(shown) - 1)
        g = Fixed(shown[i] && any(@view shown[(i + 1):end]) ? gap : 0)
        grid.addedrowgaps[i] == g || rowgap!(grid, i, g)
    end
    return nothing
end

# The rows of the layout of the card `c` that are shown: its head, its parts and, below the card of
# the selection, the pinned cards
function _set_card_gaps!(gui::AppView, c::_DockedCard)
    shown = Bool[fill(true, c.first_row - 1); [p.shown for p in _card_parts(c)]; _rows_below(gui, c)]
    _set_rowgaps!(c.parent, shown, c.gap)
    return nothing
end
_rows_below(gui::AppView, c::_DockedCard) = c.pinned ? Bool[] : Bool[!isempty(gui.layout.inspector.pinned)]

# The pages of the card of `obj`, none without an object
_docked_pages(::LiveView, ::Nothing) = ()
_docked_pages(gui::LiveView, @nospecialize(obj)) = _card_pages(gui, obj)

"""
    _show_page!(gui::AppView, c::_DockedCard, obj)

Shows the page `c.page` of the docked card `c` for its object `obj` (`nothing`: no selection): the
page bar if `obj` has several pages (see `_card_pages`), and of the parts of the card only those of
the page, see `_DockedCard`. A collapsed card shows none of them. Without a selection, the card of
the selection shows the keyboard step and the summary of the live view. Only changes update the
layout.
"""
function _show_page!(gui::AppView, c::_DockedCard, @nospecialize(obj))
    pages = _docked_pages(gui, obj)
    (isempty(pages) || c.page in pages) || (c.page = first(pages))
    open = !isnothing(obj) && !c.collapsed
    _show_bar!(gui, c, pages, open)
    _set_shown!(c.rows_part, open && _shows_rows(c.page) && !isempty(c.rows.content))
    _show_step!(c, c.step_part, isnothing(obj) || c.page === :pose)
    _show_view!(gui, c, obj, open && c.page === :results)
    _show_list!(gui, c, obj, isnothing(obj) ? !c.pinned : (open && c.page === :properties))
    _set_card_gaps!(gui, c)
    return nothing
end

# The page bar of the `pages`, `shown` if there are several
function _show_bar!(gui::AppView, c::_DockedCard, pages::Tuple, shown::Bool)
    shown = shown && length(pages) > 1
    if shown && (pages != c.pages || isnothing(c.bar))
        # blocks can only be added to a part that is attached to the figure
        _set_shown!(c.bar_part, true)
        isnothing(c.bar) || _view_detach!(c.bar.grid)
        c.bar = get!(() -> _docked_bar!(gui, c, pages), c.bars, pages)
        _view_attach!(c.bar_part.grid, 1, 1, c.bar.grid, true)
        c.pages = pages
    end
    _set_shown!(c.bar_part, shown)
    shown && _update!(c.bar.selected, c.page)
    return nothing
end

function _docked_bar!(gui::AppView, c::_DockedCard, pages::Tuple)
    bar = _page_bar!(c.bar_part.grid[1, 1], c.theme, pages; selected = c.page)
    on(page -> _set_page!(gui, c, page), bar.selected)
    return bar
end

"""
    _set_page!(gui::AppView, c::_DockedCard, page::Symbol)

Shows the `page` of the docked card `c`, e.g. after a click on its page bar. The page stays while
the card shows the same object.
"""
function _set_page!(gui::AppView, c::_DockedCard, page::Symbol)
    c.page === page && return nothing
    # A focused box of the page that is left would keep the keyboard
    foreach(tb -> tb.focused[] && Makie.defocus!(tb), c.textboxes)
    c.page = page
    # The rows of the new page, see `_declarations`
    obj = _card_object(gui, c)
    if !isnothing(obj) && !isnothing(c.pose)
        # blocks can only be added to a part that is attached to the figure
        _set_shown!(c.rows_part, true)
        _build_content!(gui, c, obj)
    end
    _refresh_inspector!(gui; force = true)
    return nothing
end

_show_step!(::_DockedCard, ::Nothing, ::Bool) = nothing
function _show_step!(c::_DockedCard, part::_LayoutPart, shown::Bool)
    box = c.step.step_box
    (!shown && box.focused[]) && Makie.defocus!(box)
    _set_shown!(part, shown)
    return nothing
end

# The properties of `obj` (the summary of the live view for `nothing`) while their page is shown
function _show_list!(gui::AppView, c::_DockedCard, @nospecialize(obj), shown::Bool)
    # an empty list has no height: emptied before its part is detached from the layout
    (shown || isempty(c.list.rows)) || _set_rows!(c.list, Tuple{String, String}[])
    _set_shown!(c.properties_part, shown)
    shown && _set_rows!(c.list, _inspector_rows(gui, obj))
    return nothing
end

#=
Detector view on the page "Results" of a docked card
=#

# Inner width of the right sidebar [px], the width of the docked cards
function _docked_width(gui::AppView)
    w = Float32(Makie.widths(gui.layout.inspector.grid.layoutobservables.computedbbox[])[1])
    return w > 1 ? w : 280.0f0
end

"""
    _show_view!(gui::AppView, c::_DockedCard, obj, shown::Bool)

Shows the detector view of `obj` on the docked card `c`, or hides it: the view is built when it is
first shown (see `_DetectorView`), in the state `c.view_expanded` and as wide as the sidebar; the
card of the selection keeps its view for the next detector. The result is shown by
`_announce_views!`.
"""
function _show_view!(gui::AppView, c::_DockedCard, @nospecialize(obj), shown::Bool)
    _set_shown!(c.view_part, shown)
    shown || return nothing
    w = _docked_width(gui)
    isnothing(c.view) && _build_view!(gui, c, w)
    view = c.view
    if c.view_obj !== obj
        # the limits that the mouse set belong to the detector before
        c.view_obj, c.shown_view, view.zoomed = obj, nothing, false
    end
    _set_expanded!(view, c.view_expanded)
    _resize_view!(view, w, w)
    return nothing
end

function _build_view!(gui::AppView, c::_DockedCard, w::Real)
    view = _DetectorView(c.view_part.grid, c.theme; expanded = c.view_expanded, width = w, height = w)
    c.view = view
    # the events of the sidebar: the view is scrolled with it, see `_ScrollArea`
    c.view_listeners = _connect_view!(view, gui.layout.right.area.events;
        on_options = (; changes...) -> _set_view!(gui, c.view_obj; changes...),
        on_expanded = expanded -> _set_view_expanded!(gui, c, expanded))
    append!(gui.controls.listeners, c.view_listeners)
    return view
end

"""
Expands the view of the docked card `c` or collapses it to its thumbnail, by its chevrons or a
click on the thumbnail. The card remembers the state. An expanded view is computed on its full
grid, see `_view_needed!`.
"""
function _set_view_expanded!(gui::AppView, c::_DockedCard, expanded::Bool)
    c.view_expanded = expanded
    _set_expanded!(c.view, expanded)
    _refresh_inspector!(gui)
    _view_needed!(gui, c.view_obj)
    return nothing
end

"""Removes the detector view of the docked card `c` with its listeners, see `_delete_view!`."""
function _remove_view!(gui::AppView, c::_DockedCard)
    isnothing(c.view) && return nothing
    filter!(l -> !_has(c.view_listeners, l), gui.controls.listeners)
    _delete_view!(c.view)
    empty!(c.view_listeners)
    c.view, c.view_obj, c.shown_view = nothing, nothing, nothing
    return nothing
end

# Whether the docked card `c` shows its detector view: on its page "Results", not collapsed, in a
# sidebar that is shown
_view_shown(gui::AppView, c::_DockedCard) =
    gui.layout.right.shown && c.view_part.shown && !isnothing(c.view)

# The docked cards of the `gui`: the card of the selection and the pinned ones
_docked_cards(gui::AppView) = _DockedCard[gui.layout.inspector.card; gui.layout.inspector.pinned]

# Also the menus of the docked cards
_card_menu_open(gui::AppView) =
    any(_has_open_menu, gui.cards.all) || any(_has_open_menu, _docked_cards(gui))

# The views of the inspector card and of the docked pinned cards that are shown, see `_shown_views`
_layout_views(gui::AppView) =
    Tuple{Any, Any}[(c.view_obj, c.view) for c in _docked_cards(gui) if _view_shown(gui, c)]

"""
    _announce_views!(gui::AppView)

Shows the stored result in the views of the docked cards that became shown since the last refresh
(built for another detector, page switched to "Results", card expanded, sidebar shown again, card
pinned), see `_redraw_views!`, and computes it if it is stale, see `_view_needed!`. Views that stay
shown are updated by the solves.
"""
function _announce_views!(gui::AppView)
    for c in _docked_cards(gui)
        pd = _view_shown(gui, c) ? c.view_obj : nothing
        pd === c.shown_view && continue
        c.shown_view = pd
        isnothing(pd) && continue
        _redraw_views!(gui, pd)
        _view_needed!(gui, pd)
    end
    return nothing
end

#=
Inspector
=#

# Row of the pinned cards in the layout of the inspector, below the parts of the card of the selection
const _PINNED_ROW = 7

"""
    _Inspector

The property inspector of the app layout, the "PROPERTIES" section of the right sidebar, from top
to bottom:

- the header: the icon of the kind of the selected object (see `_tree_kind`), its name (see
  `_label`) and its type, the actions of its card (e.g. hide) and the `pin` toggle, which pins a
  card to the object below the inspector (see `_toggle_pin!`); the icon, the name and the pin are
  built by the shared parts of the cards, see `_card_icon!`
- the docked `card` of the selected object with its pages, like a floating card (see `_DockedCard`
  and `_card_pages`): below the page bar, on the page "Pose" the rows of [`card_rows`](@ref) and
  the part of the selection, built and connected like on the floating card of the selection (see
  `_selection_part!` and `_connect_selection_part!`), i.e. the `step_box` and the mode as a
  segmented control (`mode`), bound to the `mode` of the controls; on the page "Results" the view
  of a detector (see `_DetectorView`); on the page "Properties" the `list` of the properties of the
  object, see `BeamletOptics.properties` and `_inspector_rows`. Without a selection, there is no
  page bar: the step, the mode and a summary of the live view are shown
- the `pinned` cards in the layout `pinned_grid`, one below the other in the order of pinning,
  each with its own head and its own pages, see `_dock_pinned!`. The "Properties" section is formed
  by the card of the selection and the docked pinned cards; a pinned card can float next to its
  object in the 3D view instead, see `_float!` and `_dock!`.

The inspector is updated on events only (see `_refresh_inspector!`): the selection, moves, solves
and inputs. The widgets of the card are only rebuilt if the selected object declares others, e.g.
when a source follows a lens; otherwise they show the values of the new object.
"""
mutable struct _Inspector
    const grid::GridLayout
    const icon::Observable{BezierPath}
    const icon_color::Observable{RGBAf}
    const name::Label
    const type::Label
    const pin::_IconToggle
    # "‹": opens the selection card of the object that the shown part belongs to, see `_browse_parent!`
    const back::_IconButton
    const card::_DockedCard
    const step_box::Textbox
    const mode::_Segmented
    const list::_PropertyList
    const pinned_grid::GridLayout
    const pinned::Vector{_DockedCard}
    # the object shown (`nothing`: the summary), a flag that nothing was shown yet
    shown::Any
    fresh::Bool
    # widths of the texts of the header in pixels, per label, see `_text_width`
    const widths::NTuple{2, Dict{String, Float32}}
end

"""
    _build_inspector!(layout::AppLayout) -> (; step_box)

Creates the "PROPERTIES" section of the right sidebar, see `_Inspector`. Returns the widgets that
are fields of `LiveView`.
"""
function _build_inspector!(layout::AppLayout)
    t = layout.theme
    g = _add_sidebar_section!(layout, :right, "Properties")
    # Header: icon, name and type, the actions of the card and the pin
    header = GridLayout(g[1, 1]; default_colgap = 6, tellwidth = false)
    icon, icon_color = _card_icon!(header[1:2, 1]; size = 22, box = 24)
    _show_kind!(icon, icon_color, t, nothing)
    name = _card_title!(header[1, 2], t; fontsize = 14, tellwidth = false)
    name.text[] = "No selection"
    type = Label(header[2, 2], " "; halign = :left, color = t.muted, fontsize = 12,
        tellwidth = false)
    pin = _card_pin!(header[1:2, 4], t; size = 24, icon_size = 18,
        tooltip = "Pin a card below the inspector", tooltip_placement = :left)
    back = _card_back!(header[1:2, 3], t; size = 24, icon_size = 18, tooltip_placement = :left)
    back.box.visible[] = false
    rowgap!(header, 0)
    colsize!(header, 2, Auto(false))
    # The card of the selection with its pages below the header, see `_DockedCard`
    card = _DockedCard(header, g, t; first_row = 2, gap = 10)
    # Pinned cards, see `_dock_pinned!`; there are none yet
    pinned_grid = GridLayout(g[_PINNED_ROW, 1]; default_rowgap = 10, tellwidth = false)
    rowsize!(g, _PINNED_ROW, Fixed(0))
    layout.inspector = _Inspector(g, icon, icon_color, name, type, pin, back, card, card.step.step_box,
        card.step.mode, card.list, pinned_grid, _DockedCard[], nothing, true,
        (Dict{String, Float32}(), Dict{String, Float32}()))
    return (; card.step.step_box)
end

#=
Pinned cards of the app layout, docked below the inspector
=#

"""
    _dock_pinned!(gui::AppView, obj) -> _DockedCard

Pins a card to `obj` in the app layout: a `_DockedCard` at the end of the pinned cards of the
inspector, below a line, with its own head (icon, title, actions, float button, pin and collapse
chevron, see the shared parts `_card_icon!`, `_card_title!`, `_card_float!`, `_card_pin!` and
`_card_collapse!`) and the pages of `obj` like a floating card (see `_card_pages`), on the page
`_default_page(obj)`. The float button moves it into the 3D view, see `_float!`;
the pin unpins it, see `_unpin!`; the chevron collapses it to its head. Its widgets are built by
`_refresh_inspector!`.
"""
function _dock_pinned!(gui::AppView, @nospecialize(obj))
    insp, t = gui.layout.inspector, gui.layout.theme
    g = GridLayout(insp.pinned_grid[length(insp.pinned) + 1, 1]; default_rowgap = 4, tellwidth = false)
    line = Box(g[1, 1]; height = 1, color = t.border, strokewidth = 0)
    header = GridLayout(g[2, 1]; default_colgap = 6, tellwidth = false)
    icon, icon_color = _card_icon!(header[1, 1])
    title = _card_title!(header[1, 2], t; tellwidth = false)
    float = _card_float!(header[1, 4], t; tooltip_placement = :left)
    pin = _card_pin!(header[1, 5], t; active = true, tooltip_placement = :left)
    collapse = _card_collapse!(header[1, 6], t; tooltip_placement = :left)
    colgap!(header, 4, 2)
    colgap!(header, 5, 2)
    colsize!(header, 2, Auto(false))
    # The page bar and the parts of the pages below the head, which a collapsed card does not show
    c = _DockedCard(header, g, t; actions_rows = 1:1, first_row = 3, selection = false)
    c.pinned, c.obj, c.page = true, obj, _default_page(obj)
    listeners = Any[
        on(_ -> _float!(gui, obj), float.clicks),
        on(v -> v || _unpin!(gui, obj), pin.active),
        on(_ -> _toggle_collapsed!(gui, c), collapse.clicks)]
    c.head = (; icon, icon_color, title, float, pin, collapse, line, listeners,
        widths = Dict{String, Float32}())
    _show_kind!(icon, icon_color, t, obj)
    _show_head!(pin, collapse, true, false)
    push!(insp.pinned, c)
    rowsize!(insp.grid, _PINNED_ROW, Auto())
    return c
end

"""
Returns `true` if the point `p` [figure px] is over the docked pinned card `c` beside its widgets:
over its head, its rows or its property list, but not over a button of the head, the page bar, the
detector view or a widget, see `_over_widget`.
"""
function _over_free(c::_DockedCard, p::Point2f)
    p in Rect2f(c.parent.layoutobservables.computedbbox[]) || return false
    buttons = (c.head.float, c.head.pin, c.head.collapse)
    any(b -> p in Rect2f(b.box.layoutobservables.computedbbox[]), buttons) && return false
    (_over_bar(c.bar, p) || _over_docked_view(c.view, p)) && return false
    return !_over_widget(c.blocks, p)
end
_over_bar(::Nothing, ::Point2f) = false
_over_bar(bar::_Segmented, p::Point2f) = _over_widget(bar.buttons, p)
_over_docked_view(::Nothing, ::Point2f) = false
_over_docked_view(view::_DetectorView, p::Point2f) = _over_view(view, p)

"""Removes the pinned card `c` of the app layout of the `gui` with its widgets and listeners."""
function _remove_pinned!(gui::AppView, c::_DockedCard)
    insp = gui.layout.inspector
    foreach(tb -> tb.focused[] && Makie.defocus!(tb), c.textboxes)
    _clear_content!(c)
    foreach(off, c.head.listeners)
    _remove_view!(gui, c)
    # the line and the blocks of the head: icon, title, pin and chevron
    delete!(c.head.line)
    foreach(delete!, [gc.content for gc in copy(c.header.content) if gc.content isa Makie.Block])
    # the page bars and the parts of the pages, which are detached from the card while they are not
    # shown
    parts = _card_parts(c)
    blocks = Any[b for bar in values(c.bars) for b in bar.buttons]
    foreach(part -> _blocks!(blocks, part.grid), parts)
    foreach(delete!, unique!(objectid, blocks))
    foreach(part -> delete!(part.box), parts)
    empty!(c.bars)
    c.bar = nothing
    _GLB.remove_from_gridlayout!(_GLB.gridcontent(c.parent))
    filter!(d -> d !== c, insp.pinned)
    # The remaining cards move up
    for (k, d) in enumerate(insp.pinned)
        insp.pinned_grid[k, 1] = d.parent
    end
    isempty(insp.pinned) || _GLB.trim!(insp.pinned_grid)
    rowsize!(insp.grid, _PINNED_ROW, isempty(insp.pinned) ? Fixed(0) : Auto())
    _set_card_gaps!(gui, insp.card)
    return nothing
end

"""
Collapses the pinned card `c` to its head and its actions, or expands it again.
"""
function _toggle_collapsed!(gui::AppView, c::_DockedCard)
    _set_collapsed!(c, !c.collapsed)
    _refresh_inspector!(gui; force = true)
    return nothing
end

function _set_collapsed!(c::_DockedCard, collapsed::Bool)
    c.collapsed = collapsed
    _show_collapsed!(c.head.collapse, collapsed)
    # the declarations change, see `_declarations`
    c.pose = nothing
    return nothing
end

"""
    _refresh_pinned!(gui::AppView, c::_DockedCard; force = false)

Shows the object of the pinned card `c`: builds its widgets when it was pinned or collapsed (see
`_build_content!`), then its page (see `_show_page!`), its title and the values of its widgets.
"""
function _refresh_pinned!(gui::AppView, c::_DockedCard; force::Bool = false)
    if c.pose === nothing
        # blocks can only be added to a part that is attached to the figure
        _set_shown!(c.rows_part, true)
        _build_content!(gui, c, c.obj)
        c.pose = (c.obj, nothing)
    end
    _show_page!(gui, c, c.obj)
    title = c.head.title
    w = Makie.widths(gui.layout.inspector.grid.layoutobservables.computedbbox[])[1] -
        _CARD_ICON - 3 * _CARD_TOOL - 22 - _actions_width(c)
    _set_text!(title, _fit_text(c.head.widths, _tree_font(title.blockscene, title.font[]),
        _CARD_TITLE_FONTSIZE, _label(gui, c.obj), w))
    _refresh_card!(gui, c; force)
    return nothing
end

# The card pinned to the object of the inspector opens on the page that the inspector shows, with
# its view in the same state
function _pin!(gui::AppView, @nospecialize(obj))
    insp = gui.layout.inspector
    c = _dock_pinned!(gui, obj)
    if insp.shown === obj
        c.page, c.view_expanded = insp.card.page, insp.card.view_expanded
    end
    _refresh_inspector!(gui; force = true)
    return nothing
end

# The card of a detector of the `detectors` kwarg starts docked, on its page "Results"
function _pin_view!(gui::AppView, pd; expanded::Bool = true)
    c = _dock_pinned!(gui, pd)
    c.page, c.view_expanded = :results, expanded
    _refresh_inspector!(gui; force = true)
    _on_pinned!(gui)
    return nothing
end

_is_pinned(gui::AppView, @nospecialize(obj)) = _is_docked(gui, obj) || _is_floating(gui, obj)
function _unpin!(gui::AppView, @nospecialize(obj))
    foreach(c -> _remove_pinned!(gui, c), _docked_cards(gui, obj))
    foreach(c -> _toggle_pinned!(gui, c), _floating_cards(gui, obj))
    _forget!(gui, obj)
    _on_pinned!(gui)
    return nothing
end

"""Returns the pinned cards of the app layout of the `gui` that are docked for `obj`."""
_docked_cards(gui::AppView, @nospecialize(obj)) = filter(c -> c.obj === obj, gui.layout.inspector.pinned)
_is_docked(gui::AppView, @nospecialize(obj)) = any(c -> c.obj === obj, gui.layout.inspector.pinned)

"""
    _float!(gui::AppView, obj)

Moves the card pinned to `obj` from the sidebar of the app layout into the 3D view: the docked card
is removed, a floating card (see `_ComponentCard`) is pinned to `obj` like in the compact layout,
collapsed if the docked card was, on the same page and with its detector view expanded if it was,
with the button that docks it again, see `_dock!`. The other docked cards keep their state; they
are not expanded into the room that becomes free.
"""
function _float!(gui::AppView, @nospecialize(obj))
    docked = _docked_cards(gui, obj)
    isempty(docked) && return nothing
    d = first(docked)
    collapsed, page, expanded = d.collapsed, d.page, d.view_expanded
    foreach(c -> _remove_pinned!(gui, c), docked)
    c = _spare_card!(gui)
    c.collapsed, c.page, c.view_expanded = collapsed, page, expanded
    _pin!(gui, c, obj)
    _on_pinned!(gui)
    return nothing
end

"""
    _dock!(gui::AppView, obj)

Moves the floating card pinned to `obj` back into the sidebar of the app layout, at the end of the
pinned cards, collapsed if the floating card was (by its chevron), on the same page and with its
detector view expanded if it was.
"""
function _dock!(gui::AppView, @nospecialize(obj))
    floating = _floating_cards(gui, obj)
    isempty(floating) && return nothing
    d = _dock_pinned!(gui, obj)
    d.page, d.view_expanded = first(floating).page, first(floating).view_expanded
    _set_collapsed!(d, first(floating).collapsed)
    foreach(c -> _toggle_pinned!(gui, c), floating)
    _refresh_inspector!(gui; force = true)
    return nothing
end

# The floating cards of the app layout are pinned cards, whose head has the button that docks them
function _card_tools!(layout::AppLayout, c::_ComponentCard)
    b = _card_dock!(c.tools[1, 0], layout.theme)
    colgap!(c.tools, 2)
    _fix_tooltip!(b)
    c.dock_button = b
    return c
end

"""
    _refresh_inspector!(gui::AppView; force = false)

Shows the selected object of the `gui` in the inspector (or the summary of the live view): header,
docked card and its page. The widgets of the card are rebuilt only if the object declares others,
see `_build_content!`; a focused textbox of the card keeps the typed text, unless `force`. Not
called per frame, but after the selection changed, a move, a solve and an input. Then the pinned
cards and the detector views that became shown, see `_announce_views!`. The sidebar scrolls if
the cards are higher than the window, see `_sidebar_part`. A collapsed
inspector is not updated: its views count as not shown (see `_layout_views`), it is refreshed when
it is shown again.
"""
function _refresh_inspector!(gui::AppView; force::Bool = false)
    layout = gui.layout
    insp = layout.inspector
    if !layout.right.shown
        foreach(c -> c.shown_view = nothing, _docked_cards(gui))
        return nothing
    end
    obj = _shown_object(gui)
    if insp.fresh || obj !== insp.shown
        insp.fresh = false
        insp.shown = obj
        _dock_card!(gui, insp.card, obj)
        _show_header!(gui, obj)
    end
    _show_page!(gui, insp.card, obj)
    _refresh_card!(gui, insp.card; force)
    _show_pin!(gui)
    foreach(c -> _refresh_pinned!(gui, c; force), insp.pinned)
    # The views first: what they show sets their height
    _announce_views!(gui)
    return nothing
end

"""
    _dock_card!(gui::AppView, c::_DockedCard, obj)

Builds the widgets of the docked card `c` for its new object `obj`, see `_build_content!`, or
removes them without a selection; the card opens on the page `_default_page(obj)`, which
`_show_page!` shows.
"""
function _dock_card!(::AppView, c::_DockedCard, ::Nothing)
    _clear_content!(c)
    c.pose = nothing
    return nothing
end
function _dock_card!(gui::AppView, c::_DockedCard, @nospecialize(obj))
    # A focused box of the old object would take the keyboard, and its input the new object
    foreach(tb -> tb.focused[] && Makie.defocus!(tb), c.textboxes)
    # blocks can only be added to a part that is attached to the figure
    _set_shown!(c.rows_part, true)
    # before the widgets, which are those of the page, see `_declarations`
    c.page = _default_page(obj)
    _build_content!(gui, c, obj)
    c.pose = (obj, nothing)
    return nothing
end

"""Sets the pin of the inspector of the `gui` to whether a card is pinned to the selected object."""
function _show_pin!(gui::AppView)
    pin = gui.layout.inspector.pin
    obj = _shown_object(gui)
    pinned = !isnothing(obj) && _is_pinned(gui, obj)
    pin.active[] == pinned || (pin.active[] = pinned)
    visible = !isnothing(obj)
    pin.box.visible[] == visible || (pin.box.visible[] = visible)
    # "‹" for a part of another object, see `_part_parent`
    back = gui.layout.inspector.back
    part = visible && !isnothing(_part_parent(gui, obj))
    back.box.visible[] == part || (back.box.visible[] = part)
    return nothing
end

_on_pinned!(gui::AppView) = _show_pin!(gui)

"""Sets the icon, name and type of the header of the inspector for `obj` (`nothing`: no selection)."""
function _show_header!(gui::AppView, @nospecialize(obj))
    insp, t = gui.layout.inspector, gui.layout.theme
    _show_kind!(insp.icon, insp.icon_color, t, obj)
    name = isnothing(obj) ? "No selection" : _label(gui, obj)
    type = isnothing(obj) ? "click an object to inspect it" : string(nameof(typeof(obj)))
    # Labels do not ellipsize: the room for the texts is the column of the name, between the icon
    # and the actions of the card
    w = Makie.widths(insp.grid.layoutobservables.computedbbox[])[1] - 32 - 30 -
        _actions_width(insp.card)
    font(label) = _tree_font(label.blockscene, label.font[])
    _set_text!(insp.name, _fit_text(insp.widths[1], font(insp.name), 14, name, w))
    _set_text!(insp.type, _fit_text(insp.widths[2], font(insp.type), 12, type, w))
    return nothing
end

# Width of the actions of the docked card `c` [px], with their gap
_actions_width(c::_DockedCard) =
    isempty(c.actions.content) ? 0.0f0 : Makie.widths(c.actions.layoutobservables.computedbbox[])[1] + 6

"""
Connects the inspector of the `gui`: the part of the selection like on the floating card (the step
box and the mode control, see `_connect_selection_part!`), the pin, and a refresh when the right
sidebar is collapsed or shown again. The widgets of the docked card are connected when they are
built, see `_build_content!`, its page bar and its detector view likewise, see `_show_page!`.
"""
function _connect_inspector!(gui::AppView)
    layout = gui.layout
    insp = layout.inspector
    ctrl = gui.controls
    listeners = ctrl.listeners
    _connect_selection_part!(gui, insp)
    push!(listeners, on(insp.pin.active) do v
        obj = _shown_object(gui)
        (isnothing(obj) || v == _is_pinned(gui, obj)) || _toggle_pin!(gui, obj)
        return nothing
    end)
    push!(listeners, on(_ -> _browse_parent!(gui, _shown_object(gui)), insp.back.clicks))
    # A click on a docked pinned card beside its widgets selects its object, like on a floating one;
    # the events of the sidebar, in which the mouse is nowhere while it is over another part of the
    # window, e.g. the toolbar that covers a card that is scrolled out, see `_ScrollArea`
    ev = layout.right.area.events
    press = Ref{Any}(nothing)
    push!(listeners, on(ev.mousebutton, priority = 2) do event
        event.button == Mouse.left || return Consume(false)
        p = Point2f(ev.mouseposition[])
        if event.action == Mouse.press
            i = findfirst(c -> _over_free(c, p), insp.pinned)
            press[] = isnothing(i) ? nothing : (insp.pinned[i], p)
        elseif event.action == Mouse.release && !isnothing(press[])
            c, p0 = press[]
            press[] = nothing
            (c in insp.pinned && maximum(abs, p - p0) < _CARD_DRAG_MIN) && _select_pinned!(gui, c.obj)
        end
        return Consume(false)
    end)
    # After the listener that shows or collapses the sidebar, see `_connect_layout!`: the views of
    # a collapsed sidebar are not shown, a sidebar that is shown again is refreshed
    push!(listeners, on(_ -> _refresh_inspector!(gui), layout.collapse.right.active))
    _refresh_inspector!(gui)
    return nothing
end

# The step box and the textboxes of the docked card take the keyboard like those of the floating
# cards, see `_typing`
_layout_boxes(gui::AppView) = (gui.layout.inspector.step_box, _card_boxes(gui.layout.inspector.card)...,
    (tb for c in gui.layout.inspector.pinned for tb in _card_boxes(c))...)

# The card of the selection is docked in the inspector, only pinned cards float in the 3D view
_selection_card_shown(::AppView) = false

# The toolbar, the sidebars, the dock and the status bar surround the 3D view: a click on their
# widgets, e.g. the pin of the inspector, neither selects nor deselects (the release of the press
# would clear the selection, and with it the inspector), like one on the help over the 3D view
_outside_view(gui::AppView) = !Makie.is_mouseinside(gui.ax.scene) || _over_layout(gui)

#=
Properties of the objects of the live view
=#

BMO.properties(p::LiveClipPlane) = Pair{String, Any}["Type" => "Clip plane",
    "Position [m]" => collect(Float64, p.pos), "Normal" => collect(Float64, _normal(p)),
    "Size [m]" => p.size]
