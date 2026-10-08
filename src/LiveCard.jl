using Makie: Figure, Observable, Point2f, Vec2f, Rect2f, GridLayout, Textbox, Button, Label, Box, Slider,
             Toggle, Menu, BezierPath

# Component cards of the live view: the controls of an object, next to it in the 3D view

# z translation of the scene of a card: GLMakie draws the plots in the order of this value, the
# card comes after the 3D scene, and its depth (≈ 0.005–0.02) lies in front of it. Each card gets
# its own value, `_CARD_Z0` for the first, `_CARD_DZ` more for each further one up to `_CARD_Z`,
# such that a newer card is drawn over an older one as a whole. Plus the offsets of the widgets,
# it stays within the clip range ±10000 of the pixel camera
const _CARD_Z = 9900.0f0
const _CARD_Z0 = 9600.0f0
const _CARD_DZ = 10.0f0

"""The z translation of the `k`-th card (from 1), see `_CARD_Z`."""
_card_z(k::Int) = min(_CARD_Z, _CARD_Z0 + (k - 1) * _CARD_DZ)
# Distance of the card from the bounding box of its object [px]
const _CARD_GAP = 12.0f0
# Minimum distance of the card from the edges of the 3D view and from the view cube [px]
const _CARD_MARGIN = 8.0f0
# Distance of the widgets from the edge of the background and between the parts of the card [px]
const _CARD_PADDING = 8.0f0
# Suggested bounding box of the parts that are not shown: hidden widgets still take clicks within
# their bounding box, hence they are moved far outside of the figure
const _CARD_AWAY = Rect2f(-1.0f5, -1.0f5, 0, 0)
# Font sizes of the cards, like the docked card of the app layout, such that several cards fit
# into the view, and of the title
const _CARD_FONTSIZE = 12
const _CARD_TITLE_FONTSIZE = 13
const _CARD_SUBTITLE_FONTSIZE = 11
# Radius of the corners of the background [px]
const _CARD_CORNER = 6
# Sizes of the icon of the kind of the object and of the icon buttons in the head [px]
const _CARD_ICON = 18
const _CARD_TOOL = 22
const _CARD_TOOL_ICON = 16
# z translation of the tooltips of the icon buttons relative to the card, instead of
# `_TOOLTIP_Z`, which would put them beyond the clip range of the pixel camera
const _CARD_TOOLTIP_DZ = 60.0f0

"""
    _AbstractCard

Host of the widgets that [`card_actions`](@ref) and [`card_rows`](@ref) declare for an object, see
`_build_content!`: the floating `_ComponentCard` in the 3D view, or a card docked in a sidebar,
e.g. `_DockedCard` in the inspector of the app layout. A host has the fields

- `actions::GridLayout` (the buttons of the actions, in one row) and `rows::GridLayout` (a row per
  `CardRow`), which `_new_parts!` replaces when the widgets are rebuilt
- `widgets` (each block with its `CardWidget`), `blocks`, `textboxes`, `listeners`, `content_key`,
  `refreshing` and `pose`, see `_ComponentCard`

and implements `_new_parts!(c)`, `_card_object(gui, c)`, `_card_boxes(c)` and the style of its
blocks, `_card_style(c, T)` (the colors of the `theme` of the live view and the sizes of the host).
Optionally, by dispatch on the host: `_card_value(c, v)` (e.g. of an `_AxisColor`),
`_host_attributes(c, T, attributes)`, `_row_attributes(c)`, `_declarations(c, obj)`,
`_fix_caret!(c, block)` and `_on_content_built!(gui, c)`.
"""
abstract type _AbstractCard end

"""
    _TitleEdit

The line of the title of a card in its layout `grid`: the `title`, i.e. the bold label of its
object, and, while `renamable`, i.e. for an object with a name of its own (see `_renamable`, e.g. a
system), the `pencil` next to it. A click on the pencil replaces the title by the textbox `box`
with the name (`editing`): Enter renames the object, Esc and a lost focus keep its name, see
`_begin_rename!` and `_end_rename!`. The parts that are not shown are detached from the layout, see
`_view_detach!`. Shared by the hosts of a card, see `_AbstractCard`.
"""
mutable struct _TitleEdit
    const grid::GridLayout
    const title::Label
    const pencil::_IconButton
    const box::Textbox
    renamable::Bool
    editing::Bool
end

"""
    _ComponentCard(fig::Figure, theme::NamedTuple, z = _CARD_Z)

Card of the live view with the controls of an object, shown over the 3D view next to the bounding
box of the object and connected to it by a line, see `_update_card!`. The card of the selected
object follows the selection; a `pinned` card stays with its object `obj`, independent of the
selection. It looks like the docked card in the inspector of the app layout, in the color tokens
`theme` of the live view (see `_APP_THEMES`): an opaque `background` in the color of the sidebars
with a border, the widgets in the style of the app (see `_card_style`), the line and its dot in the
accent color. It consists of free layouts (a `GridLayout` with a suggested bounding box) in `scene`,
a scene with a pixel camera over the whole figure:

- `head`: the `icon` of the kind of the object (see `_tree_kind`) in its `icon_color` and the
  `title`, i.e. the label of the object, in the line `name` (a `_TitleEdit`): next to the title of
  an object with a name of its own, e.g. a system, a pencil, which replaces the title by a textbox
  that renames the object, see `_begin_rename!`. Below the title, while `subtitle_shown`, the
  `subtitle` of the object in the muted color, e.g. "System · 3 objects · 1 source", see
  `_card_subtitle`
- `back`, left of the head while `back_shown`, i.e. for a part of another object (see
  `_part_parent`): the `back_button` "‹" (an `_IconButton`), which opens the selection card of that
  object, see `_browse_parent!`
- `actions`, right of the head: the widgets of [`card_actions`](@ref) for the object, e.g. the
  eye that hides it
- `tools`, at the right end of the first line: the `pin_button` (an `_IconToggle`, active while
  pinned) and the `collapse_button` (an `_IconButton`, a chevron down, or right while collapsed);
  in a layout that docks pinned cards, e.g. the app layout, before them the `dock_button`, which
  docks the card in the sidebar again (see `_dock!`), otherwise `dock_button = nothing`, see
  `_card_tools!`
- the page bar `bar` in its layout `bar_part`, below the head unless `collapsed`: a segmented
  control of the `pages` of the object (see `_card_pages`), of which the card shows one, its
  `page`. A card with a single page, e.g. of an inspected point or a measurement, has no bar. The
  bar of each set of pages is built once and kept in `bars`. A click sets the page (see
  `_set_page!`); a card that gets another object shows its default page (see `_default_page`),
  unless it is pinned. The page stays with the card when it is pinned.
- on the page `:pose`: `rows`, the rows of [`card_rows`](@ref) for the object, each in its own
  layout, and below them, while `step_shown`, `step`: the `step_box` of the keyboard step and the
  Move/Rotate control `mode` of the mode of the controls (see `_bind_mode!` and
  `_selection_part!`, shared with the inspector of the app layout). They belong to the selection,
  not to the object: the card of the selection shows them, and so does a pinned card while its
  object is selected, which then stands for the card of the selection, see `_shows_step`
- on the page `:properties`: `properties`, the `list` of the properties of the object (see
  `_show_properties!`)
- on the page `:results`, of an object with a view (see `_has_view`, e.g. a detector):
  `view_part` with the `view` of its results (a `_DetectorView`), built when the card gets such
  an object and deleted when it gets another one, see `_build_view!`. The view starts expanded,
  its chevron collapses it to a thumbnail (`view_expanded`, which the card remembers). While the
  expanded view is shown, the `grip` at the bottom right corner of the card resizes its axis to
  `view_size` [px], see `_resize_cards!`. `view_shown` is whether the view was shown when the card
  was updated last, by which the card notices that it must be computed (see `_show_view!`),
  `view_switches` the number of the switches of the view, which are built later than the view and
  must come before the mouse shield of the cards.

The widgets of the actions and the rows are built from their declarations when the card gets an
object with other declarations, see `_build_content!`: `widgets` holds each widget with its
[`CardWidget`](@ref), `blocks` all blocks (including the texts), `textboxes` the textboxes,
`listeners` their listeners and `content_key` the layout of the declarations. While `refreshing`,
the widgets show new values and their inputs are ignored.

The `link` holds the ends of the line, the object first; its plots, like all plots of the card, are
not inspectable. For a pinned card and the card of an inspected object (see `_inspect!`), `corners`
are the corners of the bounding box of its object in the pose `key = (obj, pose)` when it was
pinned or inspected; they move with the object, see `_card_corners`.
`pose` is the object and its pose that the widgets show.

A drag at the head of the card (outside its buttons) moves it to a `spot` in the 3D view, where it
stays with its line to the object, also when it is pinned, see `_drag_cards!`; a double click there
places it next to its object again.

Parts that are not shown are moved far outside of the figure (`_CARD_AWAY`), since hidden widgets
still take clicks within their bounding box. `scene` is translated to `z` (see `_card_z`), so that
GLMakie draws the card over the 3D scene, including plots added later and transparent plots.
"""
mutable struct _ComponentCard <: _AbstractCard
    scene::Scene
    theme::NamedTuple
    background::Box
    head::GridLayout
    actions::GridLayout
    tools::GridLayout
    rows::GridLayout
    step::GridLayout
    properties::GridLayout
    icon::Observable{BezierPath}
    icon_color::Observable{RGBAf}
    title::Label
    collapse_button::_IconButton
    pin_button::_IconToggle
    step_box::Textbox
    mode::_Segmented
    list::_PropertyList
    link::Observable{Vector{Point2f}}
    widgets::Vector{Tuple{Any, CardWidget}}
    blocks::Vector{Any}
    textboxes::Vector{Textbox}
    listeners::Vector{Any}
    content_key::Any
    refreshing::Bool
    collapsed::Bool
    auto_collapsed::Bool
    pinned::Bool
    obj::Any
    corners::Vector{Point3f}
    key::Any
    pose::Any
    dock_button::Union{Nothing, _IconButton}
    # a card of an inspected point or a measurement that is replaced by the next one unless it is
    # pinned, see `_show_info!`
    transient::Bool
    # the place in the 3D view to which the mouse moved the card, see `_card_spot`; `nothing` places
    # it next to its object
    spot::Union{Nothing, Tuple{Bool, Bool, Vec2f}}
    back::GridLayout
    back_button::_IconButton
    back_shown::Bool
    step_shown::Bool
    # pages, see `_card_pages`
    page::Symbol
    pages::Tuple{Vararg{Symbol}}
    bars::Dict{Any, Tuple{GridLayout, _Segmented}}
    bar::Union{Nothing, _Segmented}
    bar_part::Union{Nothing, GridLayout}
    # the view of the page "Results"
    view::Union{Nothing, _DetectorView}
    view_part::GridLayout
    view_expanded::Bool
    view_size::Vec2f
    view_shown::Bool
    view_switches::Int
    grip::Observable{Vector{Point2f}}
    # the line of the title with the pencil and the textbox that rename the object, and the line
    # below the title
    name::_TitleEdit
    subtitle::Label
    subtitle_shown::Bool
end

# Size of the axis of the expanded view of a new card [px] and its smallest side, see `_view_bounds`
const _CARD_VIEW_SIZE = Vec2f(280, 280)
const _CARD_VIEW_MIN = 160.0f0
# Side of the square at the bottom right corner of a card in which the mouse takes its grip [px]
const _CARD_GRIP = 16.0f0

# Content of a layout of the card `scene`, aligned at the top left corner of its suggested bounding box
function _card_part(scene::Scene)
    layout = GridLayout(; bbox = _CARD_AWAY, halign = :left, valign = :top, default_colgap = 6,
        default_rowgap = 6)
    layout.parent = scene
    return layout
end

function _ComponentCard(fig::Figure, theme::NamedTuple, z::Real = _CARD_Z)
    t = theme
    scene = Scene(fig.scene; camera = Makie.campixel!, clear = false)
    translate!(scene, 0, 0, z)
    # The line first, then the background, then the widgets: each covers the one before
    link = Observable(Point2f[])
    lines!(scene, link; color = t.accent, linewidth = 1.5, inspectable = false)
    scatter!(scene, Makie.lift(l -> l[1:min(1, end)], link); color = t.accent, markersize = 7,
        strokecolor = t.view, strokewidth = 1.5, inspectable = false)
    background = Box(scene; bbox = _CARD_AWAY, color = t.sidebar, strokecolor = t.border,
        strokewidth = 1, cornerradius = _CARD_CORNER)
    head, tools, step, properties = _card_part(scene), _card_part(scene), _card_part(scene), _card_part(scene)
    # The grip, in front of the background and of the view
    grip = Observable(Point2f[])
    translate!(linesegments!(scene, grip; color = t.muted, linewidth = 1.5, inspectable = false), 0, 0, 6)
    icon, icon_color = _card_icon!(head[1, 1])
    name = _card_name!(head[1, 2], t)
    title = name.title
    # shown for an object with a subtitle only, see `_show_subtitle!`
    subtitle = Label(head[2, 2], " "; halign = :left, _card_style(t, Label)...,
        fontsize = _CARD_SUBTITLE_FONTSIZE, color = t.muted)
    _view_detach!(subtitle)
    Makie.GridLayoutBase.trim!(head)
    pin_button = _card_pin!(tools[1, 1], t)
    collapse_button = _card_collapse!(tools[1, 2], t)
    Makie.colgap!(tools, 2)
    # Step and mode, and the properties, whose width follows the card, see `_fit_properties!`
    part = _selection_part!(step, properties[1, 1], t; width = _CARD_PROPERTIES_WIDTH, tellwidth = true)
    back = _card_part(scene)
    back_button = _card_back!(back[1, 1], t)
    foreach(_fix_tooltip!, (pin_button, collapse_button, back_button, name.pencil))
    _translate_caret!(part.step_box, z)
    _translate_caret!(name.box, z)
    scene.visible[] = false
    return _ComponentCard(scene, t, background, head, _card_part(scene), tools, _card_part(scene), step,
        properties, icon, icon_color, title, collapse_button, pin_button, part.step_box, part.mode,
        part.list, link, Tuple{Any, CardWidget}[], Any[], Textbox[], Any[], nothing,
        false, false, false, false, nothing, Point3f[], nothing, nothing, nothing, false, nothing, back, back_button, false,
        false, :pose, (:pose,), Dict{Any, Tuple{GridLayout, _Segmented}}(), nothing, nothing,
        nothing, _card_part(scene), true, _CARD_VIEW_SIZE, false, 0, grip, name, subtitle, false)
end

#=
Parts of the head of a card, shared by its hosts: the floating `_ComponentCard`, the card of the
selection in the inspector of the app layout and the pinned cards docked below it (`_DockedCard`)
=#

"""
    _card_icon!(pos; size = _CARD_ICON, box = size) -> (icon, color)

Adds the icon of the kind of an object (see `_tree_kind`) at the grid position `pos` of the head of
a card, `size` pixels large in a square of `box` pixels. Returns the observables of its marker and
its color, see `_show_kind!`.
"""
function _card_icon!(pos; size::Real = _CARD_ICON, box::Real = size)
    b = Box(pos; width = box, height = box, visible = false)
    icon = Observable(_icon(:object))
    color = Observable(RGBAf(0, 0, 0, 1))
    center = Makie.lift(r -> Point2f(Makie.origin(r) .+ Makie.widths(r) ./ 2), b.blockscene,
        b.layoutobservables.computedbbox)
    scatter!(b.blockscene, center; marker = icon, markersize = size, color,
        markerspace = :pixel, inspectable = false)
    return icon, color
end

"""Adds the title of a card, the bold label of its object, at the grid position `pos`."""
_card_title!(pos, t::NamedTuple; fontsize::Real = _CARD_TITLE_FONTSIZE, kwargs...) =
    Label(pos, ""; font = :bold, halign = :left, _card_style(t, Label)..., fontsize, kwargs...)

#=
The line of the title of a card, with the pencil and the textbox that rename its object
=#

# Size of the pencil next to the title of a card and of its icon [px], and the width of the textbox
# that replaces the title while its object is renamed
const _CARD_PENCIL = 18
const _CARD_PENCIL_ICON = 13
const _CARD_NAME_WIDTH = 170

"""
    _card_name!(pos, t; fontsize = _CARD_TITLE_FONTSIZE, kwargs...) -> _TitleEdit

Adds the line of the title of a card at the grid position `pos`, in the color tokens `t`: its title
and, not shown yet, the pencil and the textbox that rename its object, see `_TitleEdit`. The
`kwargs` go to the layout of the line.
"""
function _card_name!(pos, t::NamedTuple; fontsize::Real = _CARD_TITLE_FONTSIZE, kwargs...)
    grid = GridLayout(pos; halign = :left, default_colgap = 2, kwargs...)
    title = _card_title!(grid[1, 1], t; fontsize)
    pencil = _IconButton(grid[1, 2]; icon = :pencil, tooltip = "Rename", _card_icons(t)...,
        size = _CARD_PENCIL, icon_size = _CARD_PENCIL_ICON)
    box = Textbox(grid[1, 1]; placeholder = " ", _card_style(t, Textbox)..., font = :bold, fontsize,
        width = _CARD_NAME_WIDTH, halign = :left)
    _view_detach!(box)
    _view_detach!(pencil.box)
    Makie.GridLayoutBase.trim!(grid)
    return _TitleEdit(grid, title, pencil, box, false, false)
end

"""
Shows the pencil of the line of the title `e` for an object that is `renamable`, or takes it out of
the line. Only a change updates the layout.
"""
function _show_pencil!(e::_TitleEdit, renamable::Bool)
    e.renamable == renamable && return nothing
    e.renamable = renamable
    # while the name is edited, the textbox stands for the title and the pencil
    e.editing && return nothing
    if renamable
        _view_attach!(e.grid, 1, 2, e.pencil.box, true)
    else
        _view_detach!(e.pencil.box)
        Makie.GridLayoutBase.trim!(e.grid)
    end
    return nothing
end

# Whether the point `p` [figure px] is over the pencil or the textbox of the line of the title `e`
function _over_name_widget(e::_TitleEdit, p::Point2f)
    x = e.editing ? e.box : e.renamable ? e.pencil.box : nothing
    return !isnothing(x) && p in Rect2f(x.layoutobservables.computedbbox[])
end

# The icon buttons of the head, in the colors of the tokens `t`
_card_icons(t::NamedTuple; size::Real = _CARD_TOOL, icon_size::Real = _CARD_TOOL_ICON) =
    (; _icon_theme(t)..., icon_color = t.muted, size, icon_size)

"""The pin of a card at the grid position `pos`, an `_IconToggle` that is active while pinned."""
_card_pin!(pos, t::NamedTuple; kwargs...) = _IconToggle(pos; icon = :pinned, icon_off = :pin,
    tooltip = "Pin the card to the object", _card_icons(t)..., kwargs...)

"""
The button of a pinned card docked in the sidebar at the grid position `pos`, which floats the card
next to its object in the 3D view, see `_float!`.
"""
_card_float!(pos, t::NamedTuple; kwargs...) =
    _IconButton(pos; icon = :float, tooltip = "Float in the 3D view", _card_icons(t)..., kwargs...)

"""
The button of a floating pinned card at the grid position `pos`, which docks the card in the
sidebar again, see `_dock!`.
"""
_card_dock!(pos, t::NamedTuple; kwargs...) =
    _IconButton(pos; icon = :dock, tooltip = "Dock in the sidebar", _card_icons(t)..., kwargs...)

# A chevron to the left, the mirror image of the icon `:expand`
const _BACK_ICON = _svg_path("M456-480L640-664L584-720L344-480L584-240L640-296Z")

"""
The button "‹" of the card of a part at the grid position `pos`, which opens the selection card of
the object that it is a part of, see `_browse_parent!`.
"""
_card_back!(pos, t::NamedTuple; kwargs...) = _IconButton(pos; icon = _BACK_ICON,
    tooltip = "Parts of the enclosing object", _card_icons(t)..., kwargs...)

"""The chevron of a card at the grid position `pos` that collapses it, see `_show_head!`."""
_card_collapse!(pos, t::NamedTuple; kwargs...) =
    _IconButton(pos; icon = :collapse, tooltip = "Collapse the card", _card_icons(t)..., kwargs...)

"""The textbox of the keyboard step of a card at the grid position `pos`, see `_set_step!`."""
_step_box!(pos, t::NamedTuple; kwargs...) =
    Textbox(pos; placeholder = "e.g. 250 nm", _card_style(t, Textbox)..., kwargs...)

#=
Part of the selection, shared by the card of the selection (the floating `_ComponentCard`) and the
inspector of the app layout (`_Inspector`)
=#

# Width of the property list of a floating card at least [px], see `_fit_properties!`
const _CARD_PROPERTIES_WIDTH = 240.0f0

"""
    _selection_part!(grid::GridLayout, list_pos, t::NamedTuple; list_attributes...) -> (; step_box, mode, list)

Builds the part of the card of the selection that belongs to the selection, not to the declarations
of the object, in the color tokens `t`: in the rows 1 and 2 of `grid`, the textbox of the keyboard
step (`step_box`, see `_set_step!`) and the Move/Rotate control (`mode`, a `_Segmented`, see
`_bind_mode!`), each below a small label; at the grid position `list_pos`, the property list of the
selected object (`list`, see `_PropertyList` and `_show_properties!`), whose `Box` takes the
`list_attributes`. Shared by the floating card of the selection (see `_ComponentCard`) and the
inspector of the app layout (see `_build_inspector!`), both connected by `_connect_selection_part!`.
"""
function _selection_part!(grid::GridLayout, list_pos, t::NamedTuple; list_attributes...)
    small = (; _card_style(t, Label)..., fontsize = 11, color = t.muted, halign = :left)
    Label(grid[1, 1], "step"; small...)
    Label(grid[1, 2], "mode"; small...)
    step_box = _step_box!(grid[2, 1], t; placeholder = "250 nm", width = 80, halign = :left)
    mode = _Segmented(grid[2, 2], [:move => "Move", :rotate => "Rotate"]; theme = t, tellwidth = true)
    rowgap!(grid, 1, 2)
    list = _PropertyList(list_pos; label_color = t.muted, value_color = t.text,
        line_color = RGBAf(Makie.to_color(t.border)), list_attributes...)
    return (; step_box, mode, list)
end

"""
    _show_kind!(icon, color, t, obj)

Shows the icon of the kind of `obj` (see `_tree_kind`) in its color of the tokens `t`, the icon of
a system in the muted color for `nothing`.
"""
function _show_kind!(icon::Observable, color::Observable, t::NamedTuple, @nospecialize(obj))
    kind = _tree_kind(obj)
    _update!(icon, _icon(kind))
    _update!(color, RGBAf(Makie.to_color(_tree_marker_color(t, kind))))
    return nothing
end
function _show_kind!(icon::Observable, color::Observable, t::NamedTuple, ::Nothing)
    _update!(icon, _icon(:system))
    _update!(color, RGBAf(Makie.to_color(t.muted)))
    return nothing
end
_show_kind!(c::_ComponentCard, @nospecialize(obj)) = _show_kind!(c.icon, c.icon_color, c.theme, obj)

"""
    _show_head!(pin, collapse, pinned, collapsed)

Shows whether a card is `pinned` and `collapsed` on its `pin` and its `collapse` chevron (or
`nothing` for a card that does not collapse).
"""
function _show_head!(pin::_IconToggle, collapse, pinned::Bool, collapsed::Bool)
    _update!(pin.active, pinned)
    _update!(pin.tooltip, pinned ? "Unpin the card" : "Pin the card to the object")
    _show_collapsed!(collapse, collapsed)
    return nothing
end
_show_collapsed!(::Nothing, _) = nothing
function _show_collapsed!(b::_IconButton, collapsed::Bool)
    _update!(b.icon, _icon(collapsed ? :expand : :collapse))
    _update!(b.tooltip, collapsed ? "Expand the card" : "Collapse the card")
    return nothing
end
_show_head!(c::_ComponentCard) = _show_head!(c.pin_button, c.collapse_button, _pin_state(c), c.collapsed)
# A transient card is shown like a pinned one, but its pin is off, see `_show_info!`
_pin_state(c::_ComponentCard) = c.pinned && !c.transient

# The tooltip of an icon button of a card, relative to the translation of the card, see
# `_CARD_TOOLTIP_DZ`
_fix_tooltip!(b::Union{_IconButton, _IconToggle}) = translate!(last(b.plots), 0, 0, _CARD_TOOLTIP_DZ)

"""Returns the textboxes of the card `c`: the step box, the box of its name and the declared ones."""
_card_boxes(c::_ComponentCard) = (c.step_box, c.name.box, c.textboxes...)

"""Returns the declared widget with the `name` on the card `c` (see [`CardWidget`](@ref)), or `nothing`."""
function _card_widget(c::_AbstractCard, name::Symbol)
    i = findfirst(((_, w),) -> w.name === name, c.widgets)
    return isnothing(i) ? nothing : first(c.widgets[i])
end

#=
Widgets of the declarations, by the type of the block
=#

"""
    _card_style(theme::NamedTuple, T::Type) -> NamedTuple

Attributes of a block of the type `T` on a floating card in the color tokens `theme`: the style of
the widgets of the app layout (see `_makie_theme`), which the card sets itself, since the figure of
the compact layout has Makie's theme, in the compact sizes of the cards (see `_card_sizes`).
"""
_card_style(t::NamedTuple, ::Type{T}) where {T} = (; get(_makie_theme(t), nameof(T), (;))..., _card_sizes(T)...)
_card_style(c::_ComponentCard, T::Type) = _card_style(c.theme, T)

# Sizes of the blocks of the floating cards, like those of the docked card of the app layout
_card_sizes(::Type{Label}) = (; fontsize = _CARD_FONTSIZE)
_card_sizes(::Type{Textbox}) = (; fontsize = _CARD_FONTSIZE, height = 24, textpadding = (5, 5, 4, 4))
_card_sizes(::Type{Button}) = (; fontsize = _CARD_FONTSIZE, height = 22, padding = (7, 7, 3, 3))
_card_sizes(::Type{Menu}) = (; fontsize = _CARD_FONTSIZE)
_card_sizes(::Type) = (;)
# The icon buttons and toggles of a declaration, e.g. the eye in the head, like those of the head
_card_style(t::NamedTuple, ::Type{<:Union{_IconButton, _IconToggle}}) = _card_icons(t)

"""
    _AxisColor(k)

Color of the gizmo axis `k` (1: red, 2: green, 3: blue) in a declaration, e.g. of the labels of the
rotation boxes (see `pose_card_rows`), which each host of the card resolves to its own shade, see
`_card_value`: the `gizmo` colors of the theme of the live view (lighter in the dark theme).
"""
struct _AxisColor
    k::Int
end

"""
    _ThemeColor(name)

The color token `name` of the theme of the live view (see `_APP_THEMES`) in a declaration, e.g.
`_ThemeColor(:muted)` of the label of a section, which each host of the card resolves to the color
of its theme, see `_card_value`.
"""
struct _ThemeColor
    name::Symbol
end

# Values of the attributes of a declaration on the card `c`, see `_AxisColor` and `_ThemeColor`
_card_value(::_AbstractCard, v) = v
_card_value(c::_ComponentCard, a::_AxisColor) = c.theme.gizmo[a.k]
_card_value(c::_AbstractCard, a::_ThemeColor) = getproperty(c.theme, a.name)

"""
    _cell_attributes(c, w::CardWidget) -> NamedTuple

Attributes of the block of the declared widget `w` on the card `c`: the style of the card for the
type of the block (see `_card_style`), then the attributes of `w` with their values on the card
(see `_card_value`), which the host may adapt, see `_host_attributes`.
"""
_cell_attributes(c::_AbstractCard, w::CardWidget) = _host_attributes(c, w.type,
    (; _card_style(c, w.type)..., map(v -> _card_value(c, v), w.attributes)...))

# The attributes of a block of the type `T` on the card, as declared by default
_host_attributes(::_AbstractCard, T::Type, attributes::NamedTuple) = attributes

# Layout of a declared row of the card, see `_build_content!`
_row_attributes(::_ComponentCard) = (; halign = :left, default_colgap = 6)

# The caret and the selection of a textbox are drawn without the translation of the scene of the
# card, which is at `z`
function _translate_caret!(tb::Textbox, z::Real)
    for p in tb.editor.plots
        p isa Makie.Text || translate!(p, 0, 0, z + 5)
    end
    return nothing
end
_translate_caret!(_, ::Real) = nothing
# The block `b` of the card `c`, see `_AbstractCard`: only the floating card is translated
_fix_caret!(c::_ComponentCard, b) = _translate_caret!(b, _scene_z(c))
# The tooltip of a declared icon button likewise, see `_fix_tooltip!`
_fix_caret!(::_ComponentCard, b::Union{_IconButton, _IconToggle}) = (_fix_tooltip!(b); nothing)
_fix_caret!(::_AbstractCard, _) = nothing

# The z translation of the scene of the card `c`
_scene_z(c::_ComponentCard) = c.scene.transformation.translation[][3]

#=
Widget protocol of the cards (see `card_input` and `card_show!`) for the blocks of Makie; a type
without methods takes no input and shows nothing
=#

card_input(_) = nothing
card_input(b::Slider) = b.value
card_input(b::Toggle) = b.active
card_input(b::Textbox) = b.stored_string
card_input(b::Button) = b.clicks
card_input(b::Menu) = b.selection
# The icon buttons and toggles of the GUI, e.g. the eye in the head of a card
card_input(b::_IconButton) = b.clicks
card_input(b::_IconToggle) = b.active

card_show!(_, _) = nothing
card_show!(b::Label, v) = (_update!(b.text, string(v)); nothing)
card_show!(b::Button, v) = (_update!(b.label, string(v)); nothing)
card_show!(b::Textbox, v; force::Bool = false) = ((b.focused[] && !force) || _set_box!(b, string(v)); nothing)
card_show!(b::Slider, v) = (b.value[] == v || Makie.set_close_to!(b, v); nothing)
card_show!(b::Toggle, v) = (_update!(b.active, Bool(v)); nothing)
card_show!(b::_IconToggle, v) = (_update!(b.active, Bool(v)); nothing)
# The option with the value `v` of a menu; an unknown value keeps the selection
function card_show!(b::Menu, v)
    i = findfirst(o -> Makie.optionvalue(o) == v, b.options[])
    (isnothing(i) || b.i_selected[] == i) || (b.i_selected[] = i)
    return nothing
end

"""
    _show_value!(block, v, force::Bool)

Shows the value `v` of a declared widget in its `block` via [`card_show!`](@ref); `force` also
overwrites a focused `Textbox`, see `_refresh_card!`.
"""
_show_value!(b, v, ::Bool) = card_show!(b, v)
_show_value!(b::Textbox, v, force::Bool) = card_show!(b, v; force)

# The layout of declarations, independent of the functions `value` and `on`, see `_build_content!`
_layout_key(rows) = map(_layout_key, rows)
_layout_key(r::CardRow) = map(_layout_key, r.cells)
_layout_key(s::String) = s
_layout_key(w::CardWidget) = (w.type, w.attributes, w.name)

# The declared widgets of rows or actions, in the order of their blocks
_declared_widgets(rows) = CardWidget[w for r in rows for w in _declared_widgets(r)]
_declared_widgets(r::CardRow) = CardWidget[w for c in r.cells for w in _declared_widgets(c)]
_declared_widgets(w::CardWidget) = (w,)
_declared_widgets(::String) = ()

"""Moves the parts of the card `c` away, see `_CARD_AWAY`."""
function _park_card!(c::_ComponentCard)
    foreach(_park!, (c.back, c.head, c.actions, c.tools, c.background))
    foreach(_park!, _page_parts(c))
    _update!(c.grip, Point2f[])
    return nothing
end

"""Returns the parts of the card `c` below its head, shown or not: the page bars and the parts of the pages."""
_page_parts(c::_ComponentCard) =
    GridLayout[(first(b) for b in values(c.bars))..., c.rows, c.step, c.properties, c.view_part]

"""Removes the declared widgets of the card `c`, with their listeners and layouts."""
function _clear_content!(c::_AbstractCard)
    _close_menus!(c)
    foreach(off, c.listeners)
    foreach(delete!, c.blocks)
    empty!(c.listeners)
    empty!(c.blocks)
    empty!(c.widgets)
    empty!(c.textboxes)
    # New layouts instead of the empty rows and columns of the old ones
    _new_parts!(c)
    c.content_key = nothing
    return nothing
end

"""
Closes the open menus on the card `c` (see `_open_menu`), before it is hidden or its widgets are
rebuilt: the dropdown of an open menu is a scene of its own, which would stay on screen, e.g. after
`Esc` deselects the object of the card.
"""
function _close_menus!(c::_AbstractCard)
    for b in c.blocks
        m = _open_menu(b)
        isnothing(m) || (m.is_open[] = false)
    end
    return nothing
end

"""Replaces the layouts of the actions and the rows of the card `c` by new ones, see `_clear_content!`."""
function _new_parts!(c::_ComponentCard)
    c.actions, c.rows = _card_part(c.scene), _card_part(c.scene)
    return nothing
end

"""
Returns the parts of the card `c` below its head that are shown, from top to bottom: the page bar,
if any, and the parts of its page, see `_ComponentCard`.
"""
function _lower_parts(c::_ComponentCard)
    parts = GridLayout[]
    (c.collapsed || c.auto_collapsed) && return parts
    isnothing(c.bar_part) || push!(parts, c.bar_part)
    if c.page === :pose
        isempty(c.rows.content) || push!(parts, c.rows)
        # step and mode on the card that stands for the selection, see `_update_card!`
        c.step_shown && push!(parts, c.step)
    elseif _shows_rows(c.page)
        isempty(c.rows.content) || push!(parts, c.rows)
    elseif c.page === :properties
        push!(parts, c.properties)
    elseif c.page === :results && !isnothing(c.view)
        push!(parts, c.view_part)
    end
    return parts
end

"""Returns `true` if the card `c` shows its page "Results" with its view, unless it is collapsed."""
_shows_results(c::_ComponentCard) =
    c.page === :results && !isnothing(c.view) && !(c.collapsed || c.auto_collapsed)

"""
    _card_view(c::_ComponentCard)

The detector view that the floating card `c` shows: its `view` while its page "Results" is shown
and the card is neither hidden nor collapsed, else `nothing`. Only shown views are computed after a
solve, see `_shown_views`.
"""
_card_view(c::_ComponentCard) = (c.scene.visible[] && _shows_results(c)) ? c.view : nothing

# Size of a layout or block [px], which does not depend on its position
_card_size(x) = Vec2f(Makie.widths(x.layoutobservables.computedbbox[]))
# Size of the part of the card `c`; that of its view depends on the state of the view
_part_size(c::_ComponentCard, part) =
    (part === c.view_part && !isnothing(c.view)) ? _view_size(c.view) : _card_size(part)
# Moves a layout or block such that its top left corner is at `p`, or away, see `_CARD_AWAY`
_place!(x, p::Point2f) = _update!(x.layoutobservables.suggestedbbox, Rect2f(p[1], p[2], 0, 0))
_park!(x) = _update!(x.layoutobservables.suggestedbbox, _CARD_AWAY)

# Gap between the button "‹" and the head [px]
const _CARD_BACK_GAP = 2.0f0

# Width of the button "‹" left of the head with its gap, 0 without it
_back_width(c::_ComponentCard) = c.back_shown ? _card_size(c.back)[1] + _CARD_BACK_GAP : 0.0f0

# Size of the head with the button "‹" left of it, if shown
function _head_size(c::_ComponentCard)
    h = _card_size(c.head)
    c.back_shown || return h
    b = _card_size(c.back)
    return Vec2f(b[1] + _CARD_BACK_GAP + h[1], max(b[2], h[2]))
end

# Size of the actions, empty without actions
_actions_size(c::_ComponentCard) = isempty(c.actions.content) ? Vec2f(-_CARD_PADDING, 0) : _card_size(c.actions)

"""
    _card_size(c::_ComponentCard) -> Vec2f

Size of the card `c` [px] with its actions and tools right of the head and the parts below it (see
`_lower_parts`), including the padding of the background.
"""
function _card_size(c::_ComponentCard)
    h, a, t = _head_size(c), _actions_size(c), _card_size(c.tools)
    w, height = h[1] + _CARD_PADDING + a[1] + _CARD_PADDING + t[1], max(h[2], a[2], t[2])
    for part in _lower_parts(c)
        s = _part_size(c, part)
        w, height = max(w, s[1]), height + _CARD_PADDING + s[2]
    end
    return Vec2f(w, height) .+ 2 * _CARD_PADDING
end

"""
    _fit_properties!(c::_ComponentCard)

Sets the width of the property list of the card `c`, if it is shown, to the width of the other parts
of the card, at least `_CARD_PROPERTIES_WIDTH`, such that the expanded list makes the card higher,
but not wider than it needs. Only a changed width updates the layout.
"""
function _fit_properties!(c::_ComponentCard)
    lower = _lower_parts(c)
    any(p -> p === c.properties, lower) || return nothing
    h, a, t = _head_size(c), _actions_size(c), _card_size(c.tools)
    w = h[1] + _CARD_PADDING + a[1] + _CARD_PADDING + t[1]
    for part in lower
        part === c.properties || (w = max(w, _part_size(c, part)[1]))
    end
    _update!(c.list.box.width, max(w, _CARD_PROPERTIES_WIDTH))
    return nothing
end

"""
    _arrange_card!(c::_ComponentCard, p::Point2f)

Moves the card `c` such that its top left corner is at the figure pixel `p`, the parts that are not
shown (see `_lower_parts`) away. Only changed positions update the layout.
"""
function _arrange_card!(c::_ComponentCard, p::Point2f)
    size = _card_size(c)
    x, y = p[1] + _CARD_PADDING, p[2] - _CARD_PADDING
    h, a, t = _head_size(c), _actions_size(c), _card_size(c.tools)
    line = max(h[2], a[2], t[2])
    # The head, the actions and the tools are centered vertically in the first line: the head at the
    # left, the tools at the right end and the actions next to them, such that the icons of a card
    # form one group, however wide the rows below make it
    bw = _back_width(c)
    right = p[1] + size[1] - _CARD_PADDING - t[1]
    c.back_shown ? _place!(c.back, Point2f(x, y - (line - _card_size(c.back)[2]) / 2)) : _park!(c.back)
    _place!(c.head, Point2f(x + bw, y - (line - _card_size(c.head)[2]) / 2))
    _place!(c.actions, Point2f(right - _CARD_PADDING - a[1], y - (line - a[2]) / 2))
    _place!(c.tools, Point2f(right, y - (line - t[2]) / 2))
    y -= line
    lower = _lower_parts(c)
    for part in _page_parts(c)
        _has(lower, part) || _park!(part)
    end
    for part in lower
        y -= _CARD_PADDING
        _place!(part, Point2f(x, y))
        y -= _part_size(c, part)[2]
    end
    rect = Rect2f(p[1], p[2] - size[2], size...)
    _update!(c.background.layoutobservables.suggestedbbox, rect)
    _update!(c.grip, _has_grip(c) ? _grip_lines(rect) : Point2f[])
    return nothing
end

"""
Returns `true` if the card `c` has its grip, by which the mouse resizes its view (see
`_resize_cards!`): while the expanded view is shown.
"""
_has_grip(c::_ComponentCard) = _shows_results(c) && c.view.expanded

# The three diagonal lines of the grip in the bottom right corner of the card with the rectangle `rect`
function _grip_lines(rect::Rect2f)
    q = Point2f(maximum(rect)[1] - 3, minimum(rect)[2] + 3)
    lines = Point2f[]
    for k in (4, 8, 12)
        push!(lines, q + Point2f(-k, 0), q + Point2f(0, k))
    end
    return lines
end

"""Returns `true` if the card `c` is shown with its grip and the mouse of the `events` is over it."""
function _over_grip(c::_ComponentCard, events::Makie.Events)
    (c.scene.visible[] && _has_grip(c)) || return false
    r = c.background.layoutobservables.computedbbox[]
    q = Point2f(maximum(r)[1], minimum(r)[2])
    return Point2f(events.mouseposition[]) in Rect2f(q[1] - _CARD_GRIP, q[2], _CARD_GRIP, _CARD_GRIP)
end

"""
    _view_bounds(c::_ComponentCard, view::Rect2f) -> (lo, hi)

The smallest and the largest size [px] of the axis of the expanded view of the card `c` in the 3D
view `view`: each side at least `_CARD_VIEW_MIN`, and at most such that the card fits into the view
with the margin `_CARD_MARGIN`.
"""
function _view_bounds(c::_ComponentCard, view::Rect2f)
    room = Vec2f(Makie.widths(view)) .- 2 * _CARD_MARGIN
    # what the card needs beside the axis: its padding, and its head, its page bar and the
    # controls of the view above and below the axis
    frame = Vec2f(2 * _CARD_PADDING, _card_size(c)[2] - c.view.ax.height[])
    lo = Vec2f(_CARD_VIEW_MIN)
    return lo, max.(lo, room .- frame)
end

"""Ends the input into the textboxes of the card `c`, see `Makie.defocus!`."""
function _defocus_card!(c::_ComponentCard)
    for tb in _card_boxes(c)
        tb.focused[] && Makie.defocus!(tb)
    end
    return nothing
end

"""Hides the card `c`: ends the input into its textboxes and moves all its parts away."""
function _hide_card!(c::_ComponentCard)
    c.scene.visible[] || return nothing
    _defocus_card!(c)
    _close_menus!(c)
    _park_card!(c)
    _update!(c.link, Point2f[])
    c.scene.visible[] = false
    c.view_shown = false
    return nothing
end

"""Returns `true` if the card `c` is shown and the mouse of the `events` is over it."""
function _over_card(c::_ComponentCard, events::Makie.Events)
    c.scene.visible[] || return false
    return Point2f(events.mouseposition[]) in c.background.layoutobservables.computedbbox[]
end

"""Returns the 8 corners of the box `bb`."""
function _box_corners(bb)
    lo, hi = Vector{Float64}(minimum(bb)), Vector{Float64}(maximum(bb))
    return vec([Point3f(x, y, z) for x in (lo[1], hi[1]), y in (lo[2], hi[2]), z in (lo[3], hi[3])])
end

"""
    _screen_rect(scene, pts, obj) -> Rect2f

Rectangle [figure px] around the projections of the 3D points `pts` (e.g. the corners of the
bounding box of the object `obj`) in the 3D `scene`. Points behind the camera are skipped. If no
point remains, e.g. for an object behind the camera, the rectangle is the point at the edge of the
view towards `obj` (see `_card_anchor`), see `_screen_anchor`.
"""
function _screen_rect(scene::Scene, pts, @nospecialize(obj))
    o = Point2f(minimum(Makie.viewport(scene)[]))
    qs = Point2f[]
    for p in pts
        (all(isfinite, p) && !_behind(scene, p)) || continue
        q = Makie.project(scene, :data, :pixel, Point3f(p))
        all(isfinite, q) && push!(qs, o + Point2f(q[1], q[2]))
    end
    isempty(qs) && push!(qs, o + _screen_anchor(scene, _card_anchor(obj, pts)))
    lo = reduce((a, b) -> min.(a, b), qs)
    hi = reduce((a, b) -> max.(a, b), qs)
    return Rect2f(lo, hi - lo)
end

# The point of `obj` towards which a card points if the corners `pts` of its bounding box are behind
# the camera: its position, the center of the box for a system, which has no position
_card_anchor(@nospecialize(obj), _) = position(obj)
_card_anchor(::BMO.AbstractSystem, pts) = (reduce((a, b) -> min.(a, b), pts) + reduce((a, b) -> max.(a, b), pts)) / 2

"""
    _link_anchor(scene, pts, obj) -> Point2f

End of the line of a card at its object [figure px]: the projection of the center of the points
`pts` (the corners of the bounding box of `obj`), or the point at the edge of the view towards it,
see `_screen_anchor`, if it is behind the camera.
"""
function _link_anchor(scene::Scene, pts, @nospecialize(obj))
    p = isempty(pts) ? Point3f(position(obj)) :
        (reduce((a, b) -> min.(a, b), pts) + reduce((a, b) -> max.(a, b), pts)) / 2
    o = Point2f(minimum(Makie.viewport(scene)[]))
    q = Makie.project(scene, :data, :pixel, Point3f(p))
    (_behind(scene, p) || !all(isfinite, q)) && return o + _screen_anchor(scene, p)
    return o + Point2f(q[1], q[2])
end

"""
    _card_position(sel::Rect2f, size::Vec2f, view::Rect2f) -> Point2f

Top left corner [figure px] of a card of the `size` at the screen rectangle `sel` of the bounding
box of its object in the 3D view `view`: the first of right of `sel` and top-aligned with it, left
of it, below it and above it (left-aligned) that lies inside the view with the margin
`_CARD_MARGIN`. If none does, e.g. for an object that fills the view, the card is right of `sel`,
moved into the view, where it covers the object.
"""
function _card_position(sel::Rect2f, size::Vec2f, view::Rect2f)
    lo, hi = minimum(view) .+ _CARD_MARGIN, maximum(view) .- _CARD_MARGIN
    fits(q) = q[1] >= lo[1] && q[1] + size[1] <= hi[1] && q[2] - size[2] >= lo[2] && q[2] <= hi[2]
    top = clamp(maximum(sel)[2], min(hi[2], lo[2] + size[2]), hi[2])
    left = clamp(minimum(sel)[1], lo[1], max(lo[1], hi[1] - size[1]))
    candidates = (Point2f(maximum(sel)[1] + _CARD_GAP, top), Point2f(minimum(sel)[1] - _CARD_GAP - size[1], top),
        Point2f(left, minimum(sel)[2] - _CARD_GAP), Point2f(left, maximum(sel)[2] + _CARD_GAP + size[2]))
    for q in candidates
        fits(q) && return q
    end
    return Point2f(clamp(candidates[1][1], lo[1], max(lo[1], hi[1] - size[1])), top)
end

"""
    _card_spot(p::Point2f, size::Vec2f, view::Rect2f) -> (right, top, d)

The place of a card of the `size` with the top left corner `p` [figure px] in the 3D view `view`,
relative to the corner of the view nearest to the center of the card: `right` and `top` name the
corner, `d` is the distance [px] of the edges of the card from its edges. A card at an edge stays
there when the window is resized or the card changes its size, e.g. when it collapses, see
`_spot_position`.
"""
function _card_spot(p::Point2f, size::Vec2f, view::Rect2f)
    lo, hi = minimum(view), maximum(view)
    mid = lo .+ Makie.widths(view) ./ 2
    right, top = p[1] + size[1] / 2 > mid[1], p[2] - size[2] / 2 > mid[2]
    dx = right ? hi[1] - p[1] - size[1] : p[1] - lo[1]
    dy = top ? hi[2] - p[2] : p[2] - size[2] - lo[2]
    return (right, top, Vec2f(dx, dy))
end

"""
    _spot_position(spot, size::Vec2f, view::Rect2f) -> Point2f

Top left corner [figure px] of a card of the `size` at its `spot` (see `_card_spot`) in the 3D view
`view`, moved into the view with the margin `_CARD_MARGIN`.
"""
function _spot_position(spot::Tuple{Bool, Bool, Vec2f}, size::Vec2f, view::Rect2f)
    right, top, d = spot
    lo, hi = minimum(view) .+ _CARD_MARGIN, maximum(view) .- _CARD_MARGIN
    x = right ? maximum(view)[1] - d[1] - size[1] : minimum(view)[1] + d[1]
    y = top ? maximum(view)[2] - d[2] : minimum(view)[2] + d[2] + size[2]
    return Point2f(clamp(x, lo[1], max(lo[1], hi[1] - size[1])), clamp(y, min(hi[2], lo[2] + size[2]), hi[2]))
end

# Rectangle [figure px] of a part of a card, which hangs down from the point of its suggested bounding box
function _part_rect(x::GridLayout)
    p, s = minimum(x.layoutobservables.suggestedbbox[]), _card_size(x)
    return Rect2f(p[1], p[2] - s[2], s...)
end

"""
Returns `true` if the mouse of the `events` is over the handle of the shown card `c`, by which the
mouse moves it (see `_drag_cards!`): the card except its actions, its tools, the parts below the
head (the page bar, the rows, the view, where a drag zooms or pans, etc.) and its grip, i.e. its icon, its
title and the free room around them.
"""
function _over_handle(c::_ComponentCard, events::Makie.Events)
    _over_card(c, events) || return false
    p = Point2f(events.mouseposition[])
    (c.back_shown && p in _part_rect(c.back)) && return false
    _over_name_widget(c.name, p) && return false
    (_shows_results(c) && _over_view(c.view, p)) && return false
    _over_grip(c, events) && return false
    return !any(x -> p in _part_rect(x), (c.actions, c.tools, _page_parts(c)...))
end

# Rectangle of a card with the top left corner `p` and the `size`
_card_rect(p::Point2f, size::Vec2f) = Rect2f(p[1], p[2] - size[2], size...)
_overlaps(a::Rect2f, b::Rect2f) = all(minimum(a) .< maximum(b)) && all(minimum(b) .< maximum(a))
# The card with the top left corner `p` and the `size` overlaps one of the `obstacles`
_covers(p::Point2f, size::Vec2f, obstacles) = any(o -> _overlaps(_card_rect(p, size), o), obstacles)

"""Returns the screen rectangles [figure px] that the cards keep off: the view cube, if any and shown."""
_obstacles(::Nothing) = Rect2f[]
_obstacles(cube::ViewCube) = cube.scene.visible[] ? [Rect2f(Makie.viewport(cube.scene)[])] : Rect2f[]

"""
    _avoid(p::Point2f, size::Vec2f, view::Rect2f, obstacles) -> Point2f

Moves the top left corner `p` of a card of the `size` off the `obstacles`, i.e. the view cube and
the cards placed before (see `_update_cards!`), which would otherwise take its clicks or the other
way round: to the nearest position that lies inside the `view` with the margin `_CARD_MARGIN` and
overlaps no obstacle. The candidates combine the coordinates of `p`, of the edges of the view and of
the positions next to each obstacle (left or right of it, below or above it). Keeps `p` if none is
free, i.e. if the view is too full.
"""
function _avoid(p::Point2f, size::Vec2f, view::Rect2f, obstacles)
    free(q) = !_covers(q, size, obstacles)
    free(p) && return p
    lo, hi = minimum(view) .+ _CARD_MARGIN, maximum(view) .- _CARD_MARGIN
    m = _CARD_MARGIN
    # Left edges and top edges of the card
    xs, ys = Float32[p[1], lo[1], hi[1] - size[1]], Float32[p[2], hi[2], lo[2] + size[2]]
    for o in obstacles
        push!(xs, minimum(o)[1] - m - size[1], maximum(o)[1] + m)
        push!(ys, minimum(o)[2] - m, maximum(o)[2] + m + size[2])
    end
    inside(q) = q[1] >= lo[1] - 1.0f-3 && q[1] + size[1] <= hi[1] + 1.0f-3 &&
                q[2] - size[2] >= lo[2] - 1.0f-3 && q[2] <= hi[2] + 1.0f-3
    candidates = [Point2f(x, y) for x in xs for y in ys]
    filter!(q -> inside(q) && free(q), candidates)
    isempty(candidates) && return p
    return argmin(q -> norm(q - p), candidates)
end
