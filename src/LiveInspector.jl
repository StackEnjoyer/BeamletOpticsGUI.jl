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
`actions`, in the head) and [`card_rows`](@ref) (in `rows`, below the head), built by the same code
as the floating cards (see `_build_content!`), but in the colors of the `theme` of the app and with
the textboxes and sliders filling the width of the sidebar (see `_cell_attributes`). It is either

- the card of the selection (`pinned = false`), whose head is the header of the inspector, see
  `_Inspector`, or
- a card `pinned` to the object `obj`, stacked below the inspector with its own `head` (icon,
  title, float button, pin and collapse chevron, built by the shared parts of `LiveCard.jl`), see
  `_dock_pinned!`; a `collapsed` card shows only its head and its actions. The float button moves
  it into the 3D view as a floating `_ComponentCard`, see `_float!`. Below its rows it has the
  disclosure row "Properties" (`properties_button`) and the `list` of the properties of its object,
  like a floating card (see `_toggle_properties!`): the list is filled while `properties_shown`,
  both are in the collapsible `properties_part`, which a collapsed card does not show. For the
  card of the selection these are `nothing`: the inspector lists its properties.

`header` and `parent` hold the layouts of the head and of the card: the actions are placed in the
rows `actions_rows` of column 3 of the `header`, the rows in the row `rows_row` of the `parent`.
The fields `widgets` to `pose` are those of `_ComponentCard`.
"""
mutable struct _DockedCard <: _AbstractCard
    const header::GridLayout
    const parent::GridLayout
    const theme::NamedTuple
    const actions_rows::UnitRange{Int}
    const rows_row::Int
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
    # the properties of a pinned card, `nothing` for the card of the selection
    properties_part::Union{Nothing, _LayoutPart}
    properties_button::Union{Nothing, _IconButton}
    list::Union{Nothing, _PropertyList}
    properties_shown::Bool
end

# Positions of the actions in the header and of the rows in the card
_docked_actions(c::_DockedCard) = _docked_actions(c.header, c.actions_rows)
_docked_actions(header::GridLayout, rows::UnitRange{Int}) = GridLayout(header[rows, 3]; default_colgap = 4)
_docked_rows_layout(parent::GridLayout, row::Int) =
    GridLayout(parent[row, 1]; default_rowgap = 4, tellwidth = false)

function _DockedCard(header::GridLayout, parent::GridLayout, theme::NamedTuple;
        actions_rows::UnitRange{Int} = 1:2, rows_row::Int = 2)
    return _DockedCard(header, parent, theme, actions_rows, rows_row,
        _docked_actions(header, actions_rows), _docked_rows_layout(parent, rows_row),
        Tuple{Any, CardWidget}[], Any[], Textbox[], Any[], nothing, false, nothing, false, nothing,
        false, nothing, nothing, nothing, nothing, false)
end

function _new_parts!(c::_DockedCard)
    for part in (c.actions, c.rows)
        _GLB.remove_from_gridlayout!(_GLB.gridcontent(part))
    end
    c.actions, c.rows = _docked_actions(c), _docked_rows_layout(c.parent, c.rows_row)
    return nothing
end

_card_object(gui::LiveView, c::_DockedCard) = c.pinned ? c.obj : _shown_object(gui)
# The properties of a docked pinned card, see `_refresh_selection_part!`: the list of a collapsed
# card and of collapsed properties is empty, i.e. it has no height
_has_list(c::_DockedCard) = !isnothing(c.list)
_list_shown(c::_DockedCard, obj) = c.properties_shown && !c.collapsed && _has_properties(obj)
_hide_properties!(c::_DockedCard) = (_set_rows!(c.list, Tuple{String, String}[]); nothing)
_card_boxes(c::_DockedCard) = c.textboxes
# A collapsed card shows only its actions
_declarations(c::_DockedCard, obj) = (_head_actions(obj), c.collapsed ? () : _card_rows(obj))

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
Inspector
=#

"""
    _Inspector

The property inspector of the app layout, the "PROPERTIES" section of the right sidebar, from top
to bottom:

- the header: the icon of the kind of the selected object (see `_tree_kind`), its name (see
  `_label`) and its type, the actions of its card (e.g. hide) and the `pin` toggle, which pins a
  card to the object below the inspector (see `_toggle_pin!`); the icon, the name and the pin are
  built by the shared parts of the cards, see `_card_icon!`
- the docked `card` of the selected object: the rows of [`card_rows`](@ref), e.g. the pose, see
  `_DockedCard`
- the part of the selection, built and connected like on the floating card of the selection (see
  `_selection_part!` and `_connect_selection_part!`): the `step_box` and the mode as a segmented
  control (`mode`), bound to the `mode` of the controls, then the `list` of the properties of the
  object, see `BeamletOptics.properties` and `_show_properties!`; without a selection, a summary
  of the live view
- the `pinned` cards in the layout `pinned_grid`, one below the other in the order of pinning,
  each with its own head, see `_dock_pinned!`. The "Properties" section is formed by the card of
  the selection and the docked pinned cards; a pinned card can float next to its object in the 3D
  view instead, see `_float!` and `_dock!`.

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
    # the pinned card that was pinned or expanded last, which stays expanded, see `_fit_pinned!`
    keep::Any
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
    card = _DockedCard(header, g, t)
    # The part of the selection like on the floating card: step and mode, below a line the properties
    pose = GridLayout(g[3, 1]; default_colgap = 6, tellwidth = false)
    Box(g[4, 1]; height = 1, color = t.border, strokewidth = 0)
    step_box, mode, list = _selection_part!(pose, g[5, 1], t)
    # Pinned cards, see `_dock_pinned!`
    pinned_grid = GridLayout(g[6, 1]; default_rowgap = 10, tellwidth = false)
    # the rows of the card are empty without a selection, see `_refresh_inspector!`, and there are
    # no pinned cards yet
    rowsize!(g, 2, Fixed(0))
    rowsize!(g, 6, Fixed(0))
    rowgap!(g, 10)
    layout.inspector = _Inspector(g, icon, icon_color, name, type, pin, back, card, step_box, mode, list,
        pinned_grid, _DockedCard[], nothing, true, nothing, (Dict{String, Float32}(), Dict{String, Float32}()))
    return (; step_box)
end

#=
Pinned cards of the app layout, docked below the inspector
=#

"""
    _dock_pinned!(gui::AppView, obj) -> _DockedCard

Pins a card to `obj` in the app layout: a `_DockedCard` at the end of the pinned cards of the
inspector, below a line, with its own head (icon, title, actions, float button, pin and collapse
chevron, see the shared parts `_card_icon!`, `_card_title!`, `_card_float!`, `_card_pin!` and
`_card_collapse!`), the rows of `obj` and, below them, the disclosure row "Properties" and the
property list of the floating cards (see `_properties_disclosure!` and `_PropertyList`), collapsed
by default. The float button moves it into the 3D view, see `_float!`;
the pin unpins it, see `_unpin!`; the chevron collapses it to its head. Its widgets are built by
`_refresh_inspector!`.
"""
function _dock_pinned!(gui::AppView, obj)
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
    c = _DockedCard(header, g, t; actions_rows = 1:1, rows_row = 3)
    c.pinned, c.obj = true, obj
    # The properties below the rows, a part that a collapsed card does not show, see `_refresh_pinned!`
    box = Box(g[4, 1]; visible = false)
    part = GridLayout(g[4, 1]; default_rowgap = 2, tellwidth = false)
    c.properties_part = _LayoutPart(g, (4, 1), s -> rowsize!(g, 4, s), Auto(), box, part, true)
    c.properties_button = _properties_disclosure!(part[1, 1], t)
    # The list fills the width of the sidebar, not only that of the disclosure row
    colsize!(part, 1, Relative(1))
    c.list = _PropertyList(part[2, 1]; label_color = t.muted, value_color = t.text,
        line_color = RGBAf(Makie.to_color(t.border)))
    listeners = Any[
        on(_ -> _float!(gui, obj), float.clicks),
        on(v -> v || _unpin!(gui, obj), pin.active),
        on(_ -> _toggle_collapsed!(gui, c), collapse.clicks),
        on(_ -> _toggle_properties!(gui, c), c.properties_button.clicks)]
    c.head = (; icon, icon_color, title, float, pin, collapse, line, listeners,
        widths = Dict{String, Float32}())
    _show_kind!(icon, icon_color, t, obj)
    _show_head!(pin, collapse, true, false)
    push!(insp.pinned, c)
    rowsize!(insp.grid, 6, Auto())
    return c
end

"""
Returns `true` if the point `p` [figure px] is over the docked pinned card `c` beside its widgets:
over its head or its rows, but not over a button of the head or a widget, see `_over_widget`.
"""
function _over_free(c::_DockedCard, p::Point2f)
    p in Rect2f(c.parent.layoutobservables.computedbbox[]) || return false
    buttons = (c.head.float, c.head.pin, c.head.collapse, c.properties_button)
    any(b -> p in Rect2f(b.box.layoutobservables.computedbbox[]), buttons) && return false
    return !_over_widget(c.blocks, p)
end

"""Removes the pinned card `c` of the app layout of the `gui` with its widgets and listeners."""
function _remove_pinned!(gui::AppView, c::_DockedCard)
    insp = gui.layout.inspector
    foreach(tb -> tb.focused[] && Makie.defocus!(tb), c.textboxes)
    _clear_content!(c)
    foreach(off, c.head.listeners)
    # the line and the blocks of the head: icon, title, pin and chevron
    delete!(c.head.line)
    foreach(delete!, [gc.content for gc in copy(c.header.content) if gc.content isa Makie.Block])
    # the properties, which are detached from the card while it is collapsed
    foreach(delete!, _blocks!(Any[], c.properties_part.grid))
    delete!(c.properties_part.box)
    _GLB.remove_from_gridlayout!(_GLB.gridcontent(c.parent))
    filter!(d -> d !== c, insp.pinned)
    insp.keep === c && (insp.keep = nothing)
    # The remaining cards move up
    for (k, d) in enumerate(insp.pinned)
        insp.pinned_grid[k, 1] = d.parent
    end
    isempty(insp.pinned) || _GLB.trim!(insp.pinned_grid)
    rowsize!(insp.grid, 6, isempty(insp.pinned) ? Fixed(0) : Auto())
    return nothing
end

"""
Collapses the pinned card `c` to its head and its actions, or expands it again; the other pinned
cards collapse if the expanded card does not fit, see `_fit_pinned!`.
"""
# The expanded properties of a docked card stay, older cards collapse to make room, see `_fit_pinned!`
function _on_properties_toggled!(gui::AppView, c::_DockedCard)
    c.properties_shown && (gui.layout.inspector.keep = c)
    _refresh_inspector!(gui; force = true)
    return nothing
end

function _toggle_collapsed!(gui::AppView, c::_DockedCard)
    _set_collapsed!(c, !c.collapsed)
    c.collapsed || (gui.layout.inspector.keep = c)
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
    _fit_pinned!(gui::AppView; keep = nothing)

Fits the "Properties" section of the `gui` into the right sidebar, which does not scroll (see
`_overflow`): first the pinned cards collapse to their heads, the oldest first, except the card
`keep` (the one pinned or expanded last); then the property list of the selection is shortened,
then the expanded lists of the pinned cards, see `_fit_list!`. Cards are never expanded
automatically, i.e. they do not change back and forth.
"""
function _fit_pinned!(gui::AppView; keep = nothing)
    insp = gui.layout.inspector
    for c in insp.pinned
        _overflows(gui) || break
        (c === keep || c.collapsed) && continue
        _set_collapsed!(c, true)
        _refresh_pinned!(gui, c; force = true)
    end
    _fit_list!(gui, insp.list)
    foreach(c -> _fit_list!(gui, c.list), insp.pinned)
    return nothing
end

"""
Shortens the property `list` of the inspector of the `gui` or of one of its pinned cards by the rows
that do not fit into the right sidebar (see `_overflow`), the last row reading "… n more". The list
is set again in full by the next `_refresh_inspector!`.
"""
function _fit_list!(gui::AppView, list::_PropertyList)
    excess = _overflow(gui)
    excess > 0.5 || return nothing
    rows = list.rows
    isempty(rows) && return nothing
    n = length(rows) - ceil(Int, excess / _PROPERTY_ROW)
    n >= length(rows) && return nothing
    shown = n <= 1 ? Tuple{String, String}[] : [rows[1:(n - 1)]; ("… $(length(rows) - n + 1) more", "")]
    _set_rows!(list, shown)
    return nothing
end

"""
Returns how far [px] the parts of the right sidebar of the `gui` (the sections and their titles)
reach beyond it, above and below in total: its layout pushes the sections over the toolbar and the
dock if they do not fit.
"""
function _overflow(gui::AppView)
    stack = gui.layout.right.grid
    s = stack.layoutobservables.computedbbox[]
    isempty(stack.content) && return 0.0f0
    rs = [gc.content.layoutobservables.computedbbox[] for gc in stack.content]
    above = maximum(r -> maximum(r)[2], rs) - maximum(s)[2]
    below = minimum(s)[2] - minimum(r -> minimum(r)[2], rs)
    return Float32(max(above, 0) + max(below, 0))
end
_overflows(gui::AppView) = _overflow(gui) > 0.5

"""
    _refresh_pinned!(gui::AppView, c::_DockedCard; force = false)

Shows the object of the pinned card `c`: builds its widgets when it was pinned or collapsed (see
`_build_content!`), then its title, the values of its widgets and, while they are expanded, its
properties, see `_refresh_selection_part!`.
"""
function _refresh_pinned!(gui::AppView, c::_DockedCard; force::Bool = false)
    if c.pose === nothing
        _build_content!(gui, c, c.obj)
        c.pose = (c.obj, nothing)
        rowsize!(c.parent, c.rows_row, isempty(c.rows.content) ? Fixed(0) : Auto())
        # A collapsed card shows only its head, an item without properties no disclosure
        _set_shown!(c.properties_part, !c.collapsed && _has_properties(c.obj))
        _show_properties_state!(c.properties_button, c.properties_shown)
    end
    title = c.head.title
    w = Makie.widths(gui.layout.inspector.grid.layoutobservables.computedbbox[])[1] -
        _CARD_ICON - 3 * _CARD_TOOL - 22 - _actions_width(c)
    _set_text!(title, _fit_text(c.head.widths, _tree_font(title.blockscene, title.font[]),
        _CARD_TITLE_FONTSIZE, _label(gui, c.obj), w))
    _refresh_card!(gui, c; force)
    return nothing
end

function _pin!(gui::AppView, obj)
    gui.layout.inspector.keep = _dock_pinned!(gui, obj)
    _refresh_inspector!(gui; force = true)
    return nothing
end
_is_pinned(gui::AppView, obj) = _is_docked(gui, obj) || _is_floating(gui, obj)
function _unpin!(gui::AppView, obj)
    foreach(c -> _remove_pinned!(gui, c), _docked_cards(gui, obj))
    foreach(c -> _toggle_pinned!(gui, c), _floating_cards(gui, obj))
    _forget!(gui, obj)
    _on_pinned!(gui)
    return nothing
end

"""Returns the pinned cards of the app layout of the `gui` that are docked for `obj`."""
_docked_cards(gui::AppView, obj) = filter(c -> c.obj === obj, gui.layout.inspector.pinned)
_is_docked(gui::AppView, obj) = any(c -> c.obj === obj, gui.layout.inspector.pinned)

"""
    _float!(gui::AppView, obj)

Moves the card pinned to `obj` from the sidebar of the app layout into the 3D view: the docked card
is removed, a floating card (see `_ComponentCard`) is pinned to `obj` like in the compact layout,
collapsed if the docked card was and with its properties expanded if they were, with the button
that docks it again, see `_dock!`. The other
docked cards keep their state; they are not expanded into the room that becomes free.
"""
function _float!(gui::AppView, obj)
    docked = _docked_cards(gui, obj)
    isempty(docked) && return nothing
    collapsed, properties = first(docked).collapsed, first(docked).properties_shown
    foreach(c -> _remove_pinned!(gui, c), docked)
    c = _spare_card!(gui)
    c.collapsed, c.properties_shown = collapsed, properties
    _show_properties_state!(c.properties_button, properties)
    _pin!(gui, c, obj)
    _on_pinned!(gui)
    return nothing
end

"""
    _dock!(gui::AppView, obj)

Moves the floating card pinned to `obj` back into the sidebar of the app layout, at the end of the
pinned cards, collapsed if the floating card was (by its chevron) and with its properties expanded
if they were; an expanded card stays expanded
while the older ones collapse to make room, like a newly pinned card, see `_fit_pinned!`.
"""
function _dock!(gui::AppView, obj)
    floating = _floating_cards(gui, obj)
    isempty(floating) && return nothing
    d = _dock_pinned!(gui, obj)
    d.properties_shown = first(floating).properties_shown
    _set_collapsed!(d, first(floating).collapsed)
    d.collapsed || (gui.layout.inspector.keep = d)
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
docked card and properties. The widgets of the card are rebuilt only if the object declares others,
see `_build_content!`; a focused textbox of the card keeps the typed text, unless `force`. Not
called per frame, but after the selection changed, a move, a solve and an input. A collapsed
inspector is not updated, it is refreshed when it is shown again. Then the pinned cards, which
collapse (except the one pinned or expanded last) while they do not fit, see `_fit_pinned!`.
"""
function _refresh_inspector!(gui::AppView; force::Bool = false)
    layout = gui.layout
    layout.right.shown || return nothing
    insp = layout.inspector
    obj = _shown_object(gui)
    if insp.fresh || obj !== insp.shown
        insp.fresh = false
        insp.shown = obj
        _dock_card!(gui, insp.card, obj)
        _show_header!(gui, obj)
    end
    _refresh_card!(gui, insp.card; force)
    _show_pin!(gui)
    _show_properties!(gui, insp, obj)
    foreach(c -> _refresh_pinned!(gui, c; force), insp.pinned)
    _fit_pinned!(gui; keep = insp.keep)
    return nothing
end

"""
    _dock_card!(gui::AppView, c::_DockedCard, obj)

Builds the widgets of the docked card `c` for `obj`, see `_build_content!`, or removes them without
a selection. The row of the card in the inspector has no height without rows.
"""
function _dock_card!(::AppView, c::_DockedCard, ::Nothing)
    _clear_content!(c)
    c.pose = nothing
    rowsize!(c.parent, 2, Fixed(0))
    return nothing
end
function _dock_card!(gui::AppView, c::_DockedCard, obj)
    # A focused box of the old object would take the keyboard, and its input the new object
    foreach(tb -> tb.focused[] && Makie.defocus!(tb), c.textboxes)
    _build_content!(gui, c, obj)
    c.pose = (obj, nothing)
    rowsize!(c.parent, 2, isempty(c.rows.content) ? Fixed(0) : Auto())
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
function _show_header!(gui::AppView, obj)
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
sidebar is shown again. The widgets of the docked card are connected when they are built, see
`_build_content!`.
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
    # A click on a docked pinned card beside its widgets selects its object, like on a floating one
    ev = events(gui.ax.scene)
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
    push!(listeners, on(v -> v && _refresh_inspector!(gui), layout.collapse.right.active))
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
