#=
Catalog of the components that can be added to the systems of the live view, see
`component_catalog` and `CatalogEntry` (the entries of the components of BeamletOptics are in
`LiveCatalogEntries.jl`, the glasses in `LiveGlasses.jl`): the step from an entry and its values to
the object and its code, and the widgets of the catalog, which its window shows, see
`LiveCatalogWindow.jl`.
=#

#=
From an entry and its values to the object and its code
=#

"""
The default of the parameter `p` as a value, see `_catalog_args`: the number of a
[`CatalogParam`](@ref) in the units of the constructor, the name of the glass of a
[`CatalogGlass`](@ref) or its constant refractive index.
"""
_catalog_default(p::CatalogParam) = p.default
_catalog_default(p::CatalogGlass) = p.default == _GLASS_CONSTANT ? p.n : p.default

"""
The argument of the constructor for the value `v` of the parameter `p`: the number (an `Int` for a
parameter with `integer`), the glass with the name `v` (see `_glass`) or, for a constant refractive
index `v`, the function `λ -> v`.
"""
_catalog_arg(p::CatalogParam, v::Real) = p.integer ? Int(v) : Float64(v)
_catalog_arg(::CatalogGlass, v::AbstractString) = _glass(v)
_catalog_arg(::CatalogGlass, v::Real) = (n = Float64(v); λ -> n)

"""The argument of the constructor for the value `v` of the parameter `p` as Julia code, see `_catalog_arg`."""
_catalog_arg_code(p::CatalogParam, v::Real) = repr(_catalog_arg(p, v))
_catalog_arg_code(::CatalogGlass, v::AbstractString) = _glass_code(_glass(v))
_catalog_arg_code(::CatalogGlass, v::Real) = "λ -> $(repr(Float64(v)))"

"""
    _catalog_args([f,] entry, values) -> (positional, keywords)

The arguments of the constructor of the `entry` for the `values` of its parameters (numbers in the
units of the constructor, the names of the glasses or their constant refractive index, in the order
of `entry.params`): the positional arguments in their order and the keyword arguments as
`keyword => argument`, each as `f(param, value)`, by default the argument itself, see
`_catalog_arg`. The source of both `_catalog_object` and `_catalog_code`, such that the code
constructs the object.
"""
function _catalog_args(f, entry::CatalogEntry, values)
    length(values) == length(entry.params) ||
        throw(ArgumentError("\"$(entry.name)\" has $(length(entry.params)) parameters, got $(length(values)) values"))
    positional = Any[]
    keywords = Pair{Symbol, Any}[]
    for (p, v) in zip(entry.params, values)
        isnothing(p.keyword) ? push!(positional, f(p, v)) : push!(keywords, p.keyword => f(p, v))
    end
    return positional, keywords
end
_catalog_args(entry::CatalogEntry, values) = _catalog_args(_catalog_arg, entry, values)

"""
    _catalog_object(entry, values) -> Union{AbstractObject, AbstractBeam, AbstractBeamGroup}

Constructs the component of the catalog `entry` with the `values` of its parameters, see
`_catalog_args`. The constructor of an entry with `source` gets the position `[0, 0, 0]` and the
direction `[0, 1, 0]` before them and returns a beam or a beam group. Throws what the constructor
throws, and an `ArgumentError` if it does not return an `AbstractObject`, or a source for an entry
with `source`.
"""
function _catalog_object(entry::CatalogEntry, values)
    positional, keywords = _catalog_args(entry, values)
    if entry.source
        # new vectors with every call: a source may keep them
        src = entry.constructor([0.0, 0, 0], [0.0, 1, 0], positional...; keywords...)
        src isa Union{BMO.AbstractBeam, BMO.AbstractBeamGroup} ||
            throw(ArgumentError("the constructor returned a $(nameof(typeof(src))), not a beam or a beam group"))
        return src
    end
    obj = entry.constructor(positional...; keywords...)
    obj isa BMO.AbstractObject ||
        throw(ArgumentError("the constructor returned a $(nameof(typeof(obj))), not an AbstractObject"))
    return obj
end

"""
    _catalog_code(entry, values) -> String

The call of the constructor of the catalog `entry` with the `values` of its parameters as Julia
code, e.g. `"ThinBeamsplitter(0.0254, 0.0254; reflectance = 0.5)"`: the call that
`_catalog_object` makes, for [`export_changes`](@ref). A glass is written as the call of its
constructor, see `_glass_code`, such that the code runs without this package. The code of an entry
with `source` has the position and the direction of the source before the arguments, e.g.
`"Beam([0.0, 0.0, 0.0], [0.0, 1.0, 0.0], 6.328e-7)"`.
"""
function _catalog_code(entry::CatalogEntry, values)
    positional, keywords = _catalog_args(_catalog_arg_code, entry, values)
    # the position and the direction that `_catalog_object` passes
    entry.source && pushfirst!(positional, "[0.0, 0.0, 0.0], [0.0, 1.0, 0.0]")
    args = join(positional, ", ")
    isempty(keywords) && return "$(entry.code_name)($args)"
    kwargs = join(("$k = $v" for (k, v) in keywords), ", ")
    return "$(entry.code_name)($args; $kwargs)"
end

# A number as shown in a box: without the rounding error of a division, e.g. 25.4 instead of
# 25.400000000000002
function _catalog_number_string(v::Real)
    isfinite(v) && (v = round(v; sigdigits = 12))
    return isinteger(v) && abs(v) < 1e15 ? string(Int(v)) : string(v)
end

"""
The default of the parameter `p` as shown in the catalog: the number in its `unit`, the name of the
glass or its constant refractive index.
"""
_catalog_string(p::CatalogParam) = _catalog_number_string(p.default / p.scale)
_catalog_string(p::CatalogGlass) = p.default == _GLASS_CONSTANT ? _catalog_number_string(p.n) : p.default

"""
    _catalog_value(p, s) -> Union{Float64, String}

The value of the parameter `p` for the text `s` of its input in the catalog, see `_catalog_args`.

A [`CatalogParam`](@ref) gives the number in the units of the constructor. The unchanged text of
the default and an empty box, which shows the default as its placeholder, give `p.default` itself.
`Inf` is a value, e.g. for the radius of a plane surface. A parameter with `integer` only takes a
whole number.

A [`CatalogGlass`](@ref) gives the name of the glass if `s` is one of [`catalog_glasses`](@ref),
otherwise the constant refractive index that `s` holds, `p.n` for an empty box.

Throws an `ArgumentError` for a text that is neither.
"""
function _catalog_value(p::CatalogParam, s::AbstractString)
    text = strip(s)
    (isempty(text) || text == _catalog_string(p)) && return p.default
    x = tryparse(Float64, text)
    (isnothing(x) || isnan(x)) &&
        throw(ArgumentError("invalid input \"$text\" for $(p.name), enter a number"))
    v = x * p.scale
    # without the rounding error of the product, e.g. 0.03 instead of 0.030000000000000002
    isfinite(v) && (v = round(v; sigdigits = 15))
    (p.integer && !isinteger(v)) &&
        throw(ArgumentError("invalid input \"$text\" for $(p.name), enter a whole number"))
    return v
end

function _catalog_value(p::CatalogGlass, s::AbstractString)
    text = strip(s)
    text in _glass_names() && return String(text)
    isempty(text) && return p.n
    x = tryparse(Float64, text)
    (isnothing(x) || !isfinite(x) || x <= 0) &&
        throw(ArgumentError("invalid input \"$text\" for $(p.name), enter a refractive index"))
    return x
end

"""
    _catalog_component(entry, strings) -> (; obj, origin)

The step from the form of the catalog to a component: parses the `strings` of the inputs of the
parameters of the `entry` (see `_catalog_value`), constructs the object or source `obj` and returns
it with its `origin = (; code, pose0, entry, strings)`, the call of its constructor as code, its pose as constructed, the `entry` and the `strings`, with which it can be built again,
see `_ComponentState`. Throws for an invalid input and what the constructor throws.
"""
function _catalog_component(entry::CatalogEntry, strings)
    length(strings) == length(entry.params) ||
        throw(ArgumentError("\"$(entry.name)\" has $(length(entry.params)) parameters, got $(length(strings)) values"))
    values = Any[_catalog_value(p, s) for (p, s) in zip(entry.params, strings)]
    obj = _catalog_object(entry, values)
    return (; obj, origin = (; code = _catalog_code(entry, values), pose0 = _pose(obj), entry,
        strings = String[String(s) for s in strings]))
end

"""
    _place_catalog!(gui, entry, strings) -> Union{AbstractObject, AbstractBeam, AbstractBeamGroup, Nothing}

"Place" of the catalog of the `gui`: constructs the component or source of the `entry` from the `strings` of
its form (see `_catalog_component`) and starts placing it with the mouse, see `_start_placement!`.
An invalid input or an error of the constructor only shows a message in the status line: no object
is made, nothing is placed and `nothing` is returned.
"""
function _place_catalog!(gui::LiveView, entry::CatalogEntry, strings)
    c = try
        _catalog_component(entry, strings)
    catch e
        # the first line of the message, e.g. of a `MethodError`
        msg = first(split(sprint(showerror, e), '\n'))
        gui.status.text[] = "$(entry.name) not placed: $msg"
        return nothing
    end
    _start_placement!(gui, c.obj; origin = c.origin, system = _catalog_target(gui, entry))
    return c.obj
end

#=
Widget
=#

# The title of the window of the catalog and the name of the tool that shows it
const _CATALOG_TITLE = "Components"
# The key that opens the window of the catalog at the mouse, the counterpart of `Delete`; Makie's
# `Camera3D` binds almost all letters
const _CATALOG_KEY = Keyboard.insert

# The keys of a view with a catalog, in the help of the controls, see `_help_sections`
const _CATALOG_HELP = _HelpSection["Components" => [
    _HelpEntry(["Ins"], "open the catalog at the mouse, until a component is dropped"),
    _HelpEntry([:mouse => "click"], "pin of the catalog: keep it open"),
    _HelpEntry([:mouse => "drag"], "head of the catalog: move it"),
    _HelpEntry([:mouse => "move"], "while placing: near a beam, snap onto it"),
    _HelpEntry([:mouse => "click"], "while placing: drop it, Esc cancels")]]
# Sizes of the widgets of the catalog [px]: the boxes of the numbers and the menus of the glasses
const _CATALOG_BOX_WIDTH = 64
const _CATALOG_GLASS_WIDTH = 128
# Gap between the name, the box and the unit of a parameter in the form of the catalog, and
# between its two columns [px]
const _CATALOG_GAP = 8
const _CATALOG_COLUMN_GAP = 20
# Gaps between the icons of the groups and between the tiles of the entries [px]
const _CATALOG_GROUP_GAP = 4
const _CATALOG_TILE_GAP = 2

"""
    _catalog_style() -> NamedTuple
    _catalog_style(width) -> NamedTuple

How the widgets of the catalog are laid out, see `_CatalogWidget`: in its window, which is as wide
as its content, or in a place of the `width` [px], e.g. a section of a sidebar.

- `group_size`, `group_icon`: the icon buttons of the groups and their icons [px], in rows of
  `groups_per_row`
- `tile_width`: the width of the tiles of the entries, each with its icon and its name below it;
  `nothing` for icon buttons of `tile_size` without a name, in a narrow place, where the name of
  the entry under the mouse is shown below them. In rows of `tiles_per_row`.
- `two_columns`: the numbers of an entry are in two columns from this number on
- `constant_inline`: whether the box of a "constant" glass is right of its menu, otherwise below it
"""
_catalog_style() = (; group_size = 32, group_icon = 20, groups_per_row = typemax(Int),
    tile_width = 86, tile_size = 40, tiles_per_row = 4, two_columns = 5, constant_inline = true)
function _catalog_style(width::Real)
    group, tile = 26, 40
    per_row(size, gap) = max(1, floor(Int, (width + gap) / (size + gap)))
    return (; group_size = group, group_icon = 18,
        groups_per_row = per_row(group, _CATALOG_GROUP_GAP), tile_width = nothing,
        tile_size = tile, tiles_per_row = per_row(tile, _CATALOG_TILE_GAP),
        two_columns = typemax(Int), constant_inline = false)
end

"""
    _CatalogWidget

The widgets of the catalog of a `LiveView` in a `layout`, e.g. the body of its window or of its
dock (see `_catalog_widget!`), laid out by the `style` (see `_catalog_style`) in the colors of the
theme tokens `theme`, from top to bottom:

- `target`: the label of the system that gets the component, "into: <system>"; in a view with
  several systems only "into", next to the menu `target_menu` of the systems, see
  `_show_catalog_target!` (`showing` is `true` while the menu is set to the system that it shows)
- `group_buttons`: an icon per group of the `entries` (`groups`, in the order of their first
  entries), of which the one with the index `group` is chosen; `group_label` names it, or the one
  under the mouse
- `tiles`: a tile per entry of the chosen group with its icon and its name, or only its icon (see
  the `style`; `tile_buttons`, each with the index of its entry), of which the one of the entry
  with the index `entry` is chosen; `entry_label` names it, see `_show_catalog_entry!`
- `form`: the inputs of the parameters of the chosen entry (`inputs`, one per parameter): a
  `Textbox` per number, and per glass its menu and, for "constant", the box of the refractive
  index, as `(; menu, box)`. `boxes` and `menus` hold all of them.
- `place`: the button "Place"

The tiles are built again when another group is chosen (see `_build_catalog_tiles!`), the form
when another entry is chosen (see `_build_catalog_form!`) and, at the next frame while `dirty`,
after a menu of a glass changed to or from "constant", see `_flush_catalog_form!`. `settle` holds
the grids of a new form and its time until its boxes were moved once, see `_settle_catalog_form!`.
"""
mutable struct _CatalogWidget
    const layout::GridLayout
    const theme::NamedTuple
    const style::NamedTuple
    const entries::Vector{CatalogEntry}
    const groups::Vector{String}
    const target::Label
    const target_menu::Union{Nothing, Menu}
    showing::Bool
    const group_buttons::Vector{_OverlayItem}
    const group_label::Label
    const entry_label::Label
    const place::Button
    group::Int
    entry::Int
    tiles::GridLayout
    const tile_buttons::Vector{Pair{Int, _OverlayItem}}
    form::GridLayout
    const inputs::Vector{Any}
    const boxes::Vector{Textbox}
    const menus::Vector{Menu}
    dirty::Bool
    settle::Union{Nothing, Tuple{Float64, Vector{GridLayout}}}
end

"""The entry that is chosen in the catalog widget `w`."""
_catalog_entry(w::_CatalogWidget) = w.entries[w.entry]

"""The text of the `input` of the parameter `p` of the catalog, as typed, i.e. also without Enter."""
_catalog_input_string(::CatalogParam, input::Textbox) = String(input.displayed_string[])
function _catalog_input_string(p::CatalogGlass, input::NamedTuple)
    glass = input.menu.selection[]
    glass == _GLASS_CONSTANT || return String(glass)
    # "constant" was chosen and its box is not built yet, see `_flush_catalog_form!`
    return isnothing(input.box) ? _catalog_number_string(p.n) : String(input.box.displayed_string[])
end

"""The texts of the inputs of the catalog widget `w`, one per parameter of its entry, see `_catalog_value`."""
_catalog_strings(w::_CatalogWidget) =
    String[_catalog_input_string(p, input) for (p, input) in zip(_catalog_entry(w).params, w.inputs)]

"""
    _catalog_widget!(gui, body, style) -> _CatalogWidget

Builds the widgets of the catalog of the `gui` (`gui.components.catalog`) in the layout `body`,
laid out by the `style` (see `_catalog_style`): the line "into: <system>" with the system that gets
the component (see `_catalog_target`), which is a menu of the systems in a view with several
systems, the icons of the groups, the tiles of the entries of the
chosen group, the form of the chosen entry and the button "Place", see `_CatalogWidget` and
`_place_catalog!`. The first group and its first entry are chosen.
"""
function _catalog_widget!(gui::LiveView, body::GridLayout, style::NamedTuple)
    entries = gui.components.catalog
    t = gui.layout.theme
    label = (; _card_style(t, Label)..., halign = :left)
    # With several systems, the system is chosen in a menu next to the label
    line = GridLayout(body[1, 1]; halign = :left, default_colgap = _CATALOG_GAP)
    target = Label(line[1, 1], ""; label..., color = t.muted)
    target_menu = length(gui.system_handles) > 1 ?
                  Menu(line[1, 2]; options = [""], _card_style(t, Menu)...,
        width = _CATALOG_GLASS_WIDTH, halign = :left) : nothing
    groups = unique(e.group for e in entries)
    rows = GridLayout(body[2, 1]; halign = :left, default_colgap = _CATALOG_GROUP_GAP,
        default_rowgap = _CATALOG_GROUP_GAP)
    group_buttons = [_OverlayItem(rows[fldmod1(k, style.groups_per_row)...], t;
        icon = _catalog_group_icon(entries, g), size = style.group_size,
        icon_size = style.group_icon, padding = (0, 0, 0, 0)) for (k, g) in enumerate(groups)]
    group_label = Label(body[3, 1], ""; label..., fontsize = 11, color = t.muted)
    tiles = _catalog_tiles(body)
    entry_label = Label(body[5, 1], ""; label..., font = :bold)
    form = _catalog_form(body)
    place = Button(body[7, 1]; label = "Place", _card_style(t, Button)..., halign = :left)
    widget = _CatalogWidget(body, t, style, entries, groups, target, target_menu, false,
        group_buttons, group_label,
        entry_label, place, 0, 0, tiles, Pair{Int, _OverlayItem}[], form, Any[], Textbox[], Menu[], false,
        nothing)
    listeners = gui.controls.listeners
    if !isnothing(target_menu)
        # its search takes the keyboard like the menus of the form
        _register_widget!(gui, target_menu)
        push!(listeners, on(i -> _choose_catalog_target!(gui, widget, i), target_menu.i_selected))
    end
    for (k, button) in enumerate(group_buttons)
        push!(listeners, on(_ -> _select_catalog_group!(gui, widget, k), button.clicks))
        push!(listeners, on(_ -> _show_catalog_group!(widget), button.hovered))
    end
    push!(listeners, on(place.clicks) do _
        _show_catalog_target!(gui, widget)
        _place_catalog!(gui, _catalog_entry(widget), _catalog_strings(widget))
    end)
    _select_catalog_group!(gui, widget, 1)
    _show_catalog_target!(gui, widget)
    return widget
end

"""
    _build_catalog!(gui)

Builds the catalog "Components" of the `gui` (`gui.components.catalog`, see
[`component_catalog`](@ref)): its window over the 3D view (see `_CatalogWindow`) and, in a layout
with a place for it, its dock, e.g. a section of a sidebar (see `_catalog_dock_slot!`), each with
the widgets of the catalog, see `_catalog_widget!`. Without a dock, the window is hidden at first;
with one, the catalog starts docked. The toggle "Components" among the tools of the layout (see
[`add_tool!`](@ref)) shows and hides it, the key `Insert` shows the window at the mouse, see
`_connect_catalog_window!`. Both are listed in the help with the mouse while placing
(`_CATALOG_HELP`). A view without a `System`, to which components can be added, only offers the
sources of the catalog, which are traced through any system. Nothing is built for an empty catalog.
"""
function _build_catalog!(gui::LiveView)
    entries = gui.components.catalog
    isempty(_mutable_systems(gui)) && filter!(e -> e.source, entries)
    isempty(entries) && return nothing
    w = _CatalogWindow(gui, _catalog_dock_slot!(gui, _CATALOG_TITLE))
    gui.components.window = w
    _connect_catalog_window!(gui, w)
    # The toggle of the layout, among its tools
    w.tool = add_tool!((g, shown) -> _show_catalog!(g, shown), gui, _CATALOG_TITLE; icon = :lens,
        toggle = true, tooltip = "$_CATALOG_TITLE (Ins)")
    append!(gui.controls.help_extra, _CATALOG_HELP)
    _update_help!(gui.controls)
    # The presses on the new widgets are kept from the camera, see `_shield_cards!`
    _shield_cards!(gui)
    _show_catalog_state!(gui, w)
    return nothing
end

"""
Shows the system that gets the next component in the catalog of the `gui` again, e.g. after a
system was inspected, see `_on_shown!`; nothing without a catalog.
"""
function _refresh_catalog!(gui::LiveView)
    comp = gui.components
    # A system chosen in the menu holds until another object is shown, which sets the system again
    if comp.target_shown !== _shown_object(gui)
        comp.target, comp.target_shown = nothing, nothing
    end
    w = _catalog_window(gui)
    isnothing(w) || foreach(widget -> _show_catalog_target!(gui, widget), _catalog_widgets(w))
    return nothing
end

"""
The systems of the `gui` that can get the `entry` of the catalog: a source is traced through any
system, a component is added to a `System`.
"""
_catalog_systems(gui::LiveView, entry::CatalogEntry) =
    entry.source ? _systems(gui) : BMO.AbstractSystem[_mutable_systems(gui)...]

"""
    _catalog_target(gui, entry) -> Union{AbstractSystem, Nothing}

The system that gets the `entry` of the catalog of the `gui` when it is placed: the system of the
selected or inspected object, otherwise the first one (of a component the `_target_system`, of a
source the system it is traced through, see `_source_system`), unless another one was chosen in
the menu "into" of the catalog since that object is shown, see `_choose_catalog_target!`. `nothing`
without a system that can get it.
"""
function _catalog_target(gui::LiveView, entry::CatalogEntry)
    comp = gui.components
    if !isnothing(comp.target) && comp.target_shown === _shown_object(gui) &&
       any(sys -> sys === comp.target, _catalog_systems(gui, entry))
        return comp.target
    end
    return entry.source ? _source_system(gui, nothing) : _target_system(gui)
end

"""
The menu "into" of the catalog widget `w` of the `gui` chose its option `i`: that system gets the
entries of the catalog until another object is selected or inspected, see `_catalog_target`.
"""
function _choose_catalog_target!(gui::LiveView, w::_CatalogWidget, i::Integer)
    (w.showing || w.entry == 0) && return nothing
    systems = _catalog_systems(gui, _catalog_entry(w))
    i in eachindex(systems) || return nothing
    gui.components.target = systems[i]
    gui.components.target_shown = _shown_object(gui)
    # also in the other widget of the catalog, e.g. its window
    _refresh_catalog!(gui)
    return nothing
end

"""
Shows the system that gets the chosen entry of the catalog widget `w`, see `_catalog_target`: in
its label, or, in a view with several systems, in its menu of the systems that can get the entry.
"""
function _show_catalog_target!(gui::LiveView, w::_CatalogWidget)
    entry = w.entry == 0 ? nothing : _catalog_entry(w)
    sys = isnothing(entry) ? _target_system(gui) : _catalog_target(gui, entry)
    menu = w.target_menu
    if isnothing(menu)
        _update!(w.target.text, isnothing(sys) ? "into: no system" : "into: $(_label(gui, sys))")
        return nothing
    end
    _update!(w.target.text, "into")
    systems = isnothing(entry) ? _systems(gui) : _catalog_systems(gui, entry)
    names = isempty(systems) ? ["no system"] : String[_label(gui, s) for s in systems]
    i = something(findfirst(s -> s === sys, systems), 1)
    # Showing the system is no choice of the user, see `_choose_catalog_target!`
    w.showing = true
    try
        menu.options[] == names || (menu.options[] = names)
        menu.i_selected[] == i || (menu.i_selected[] = i)
    finally
        w.showing = false
    end
    return nothing
end

"""Releases the listeners of the `gui` on the `observables` of widgets that are deleted."""
function _release_listeners!(gui::LiveView, observables)
    filter!(gui.controls.listeners) do l
        (l isa Observables.ObserverFunction && any(o -> l.observable === o, observables)) ||
            return true
        off(l)
        return false
    end
    return nothing
end

# Deletes the blocks of the `grid` of the catalog and the grid itself, i.e. its rows and columns
function _delete_catalog_grid!(grid::GridLayout)
    foreach(delete!, _blocks!(Any[], grid))
    _GLB.remove_from_gridlayout!(_GLB.gridcontent(grid))
    return nothing
end

#=
Groups and tiles
=#

# The layout of the tiles of the catalog in the `layout` of its widgets, see `_CatalogWidget`
_catalog_tiles(layout::GridLayout) = GridLayout(layout[4, 1]; halign = :left, valign = :top,
    default_rowgap = _CATALOG_TILE_GAP, default_colgap = _CATALOG_TILE_GAP)

"""Names the group under the mouse in the catalog widget `w`, otherwise its chosen group."""
function _show_catalog_group!(w::_CatalogWidget)
    k = something(findfirst(b -> b.hovered[], w.group_buttons), w.group)
    _update!(w.group_label.text, w.groups[k])
    return nothing
end

"""
    _select_catalog_group!(gui, w, k)

Chooses the group with the index `k` in the catalog widget `w`: shows the tiles of its entries
(see `_build_catalog_tiles!`) and chooses the first one. Nothing happens for the chosen group.
"""
function _select_catalog_group!(gui::LiveView, w::_CatalogWidget, k::Integer)
    _set_catalog_group!(gui, w, k) && _select_catalog_entry!(gui, w, first(first(w.tile_buttons)))
    return nothing
end

"""
Shows the tiles of the group with the index `k` in the catalog widget `w`, without choosing one of
its entries, see `_select_catalog_group!`. Returns `false` for the chosen group, which is kept.
"""
function _set_catalog_group!(gui::LiveView, w::_CatalogWidget, k::Integer)
    w.group == k && return false
    w.group = k
    foreach(((i, b),) -> _update!(b.active, i == k), enumerate(w.group_buttons))
    _show_catalog_group!(w)
    _build_catalog_tiles!(gui, w)
    return true
end

"""
    _build_catalog_tiles!(gui, w)

Replaces the tiles of the catalog widget `w` by those of the entries of its chosen group, in the
rows of its style (see `_catalog_style`): each with the icon of its entry (see `_catalog_icon`)
and its name, or as an icon button, whose name is shown while the mouse is over it, see
`_show_catalog_entry!`. A click on a tile chooses its entry, see `_select_catalog_entry!`.
"""
function _build_catalog_tiles!(gui::LiveView, w::_CatalogWidget)
    _release_listeners!(gui, Any[[tile.clicks for (_, tile) in w.tile_buttons];
        [tile.hovered for (_, tile) in w.tile_buttons]])
    empty!(w.tile_buttons)
    _delete_catalog_grid!(w.tiles)
    w.tiles = _catalog_tiles(w.layout)
    style = w.style
    group = w.groups[w.group]
    members = [i for (i, e) in enumerate(w.entries) if e.group == group]
    for (k, i) in enumerate(members)
        entry = w.entries[i]
        pos = w.tiles[fldmod1(k, style.tiles_per_row)...]
        icon = _catalog_icon(w.entries, entry)
        tile = if isnothing(style.tile_width)
            _OverlayItem(pos, w.theme; icon, size = style.tile_size, icon_size = 28,
                padding = (0, 0, 0, 0))
        else
            _OverlayItem(pos, w.theme; icon, label = entry.name, tile_width = style.tile_width,
                icon_size = 28, fontsize = 11, padding = (3, 3, 6, 5))
        end
        push!(w.tile_buttons, i => tile)
        push!(gui.controls.listeners, on(_ -> _select_catalog_entry!(gui, w, i), tile.clicks))
        isnothing(style.tile_width) &&
            push!(gui.controls.listeners, on(_ -> _show_catalog_entry!(w), tile.hovered))
    end
    return nothing
end

"""
Marks the tile of the chosen entry of the catalog widget `w` and names the entry; tiles without a
name (see `_catalog_style`) name the entry under the mouse instead, like the icons of the groups.
"""
function _show_catalog_entry!(w::_CatalogWidget)
    w.entry == 0 && return nothing
    foreach(((j, tile),) -> _update!(tile.active, j == w.entry), w.tile_buttons)
    k = isnothing(w.style.tile_width) ? findfirst(((_, tile),) -> tile.hovered[], w.tile_buttons) :
        nothing
    i = isnothing(k) ? w.entry : first(w.tile_buttons[k])
    _update!(w.entry_label.text, w.entries[i].name)
    return nothing
end

"""
    _select_catalog_entry!(gui, w, i)

Chooses the entry with the index `i` of the entries of the catalog widget `w`, one of its chosen
group: marks its tile, names it and builds its form with its defaults, see `_build_catalog_form!`.
Nothing happens for the chosen entry, whose form keeps its texts.
"""
function _select_catalog_entry!(gui::LiveView, w::_CatalogWidget, i::Integer)
    w.entry == i && return nothing
    w.entry = i
    _show_catalog_entry!(w)
    _show_catalog_target!(gui, w)
    _build_catalog_form!(gui, w, String[_catalog_string(p) for p in w.entries[i].params])
    return nothing
end

"""
    _copy_catalog_state!(gui, to, from)

Shows in the catalog widget `to` what the widget `from` shows: its group, its entry and the texts
of its inputs, e.g. when the catalog moves from its dock into its window. The tiles and the form
of `to` are only built again if they differ.
"""
function _copy_catalog_state!(gui::LiveView, to::_CatalogWidget, from::_CatalogWidget)
    to === from && return nothing
    strings = _catalog_strings(from)
    _set_catalog_group!(gui, to, from.group)
    same = to.entry == from.entry && _catalog_strings(to) == strings
    to.entry = from.entry
    _show_catalog_entry!(to)
    same || _build_catalog_form!(gui, to, strings)
    return nothing
end

#=
Form
=#

# The layout of the form of the catalog in the `layout` of its widgets, see `_CatalogWidget`
_catalog_form(layout::GridLayout) = GridLayout(layout[6, 1]; halign = :left, default_rowgap = 6)

# A grid of the form of the catalog: the numbers or the glasses, see `_fill_catalog_form!`
_catalog_form_grid(pos) = GridLayout(pos; halign = :left, default_rowgap = 6, default_colgap = _CATALOG_GAP)

"""
    _fill_catalog_form!(gui, w, strings)

Builds the form of the catalog widget `w` for its chosen entry with the `strings` as the texts of
its inputs (see `_catalog_strings`): first the numbers, each with its name, a `Textbox` and its
unit, in two columns from the number of its style on (see `_catalog_style`), then the glasses, each
with its name and the menu of the glasses and "constant", for which a box takes the refractive
index, right of the menu or below it. The boxes and the menus take the keyboard like those of the
controls, see `_register_widget!`.
"""
function _fill_catalog_form!(gui::LiveView, w::_CatalogWidget, strings)
    params = _catalog_entry(w).params
    t = w.theme
    label = (; _card_style(t, Label)..., halign = :left)
    box = (; _card_style(t, Textbox)..., width = _CATALOG_BOX_WIDTH)
    resize!(w.inputs, length(params))
    # An empty layout has no size
    isempty(params) && Label(w.form[1, 1], "no parameters"; label..., color = t.muted)
    grids = GridLayout[]
    numbers = findall(p -> p isa CatalogParam, params)
    if !isempty(numbers)
        grid = _catalog_form_grid(w.form[length(grids) + 1, 1])
        push!(grids, grid)
        two = length(numbers) >= w.style.two_columns
        rows = two ? cld(length(numbers), 2) : length(numbers)
        for (k, i) in enumerate(numbers)
            p = params[i]
            # down the first column, then down the second one
            column, row = fldmod1(k, rows)
            col = 3 * (column - 1)
            Label(grid[row, col + 1], p.name; label...)
            # An emptied box shows the default as its placeholder, see `_catalog_value`
            tb = Textbox(grid[row, col + 2]; stored_string = strings[i],
                placeholder = _catalog_string(p), box...)
            Label(grid[row, col + 3], p.unit; label...)
            w.inputs[i] = tb
            push!(w.boxes, tb)
        end
        two && Makie.colgap!(grid, 3, _CATALOG_COLUMN_GAP)
    end
    glasses = findall(p -> p isa CatalogGlass, params)
    if !isempty(glasses)
        grid = _catalog_form_grid(w.form[length(grids) + 1, 1])
        push!(grids, grid)
        names = [_glass_names(); _GLASS_CONSTANT]
        inline = w.style.constant_inline
        row = 0
        for i in glasses
            p = params[i]
            glass = strings[i] in names ? strings[i] : _GLASS_CONSTANT
            constant = glass == _GLASS_CONSTANT
            row += 1
            Label(grid[row, 1], p.name; label...)
            menu = Menu(grid[row, 2]; options = names, default = glass, _card_style(t, Menu)...,
                width = _CATALOG_GLASS_WIDTH, halign = :left)
            tb = nothing
            if constant
                # right of the menu, or in a row of its own below it
                inline || (row += 1)
                Label(grid[row, inline ? 3 : 1], "n"; label..., halign = inline ? :left : :right)
                tb = Textbox(grid[row, inline ? 4 : 2]; stored_string = strings[i],
                    placeholder = _catalog_number_string(p.n), box..., halign = :left)
                push!(w.boxes, tb)
            end
            w.inputs[i] = (; menu, box = tb)
            push!(w.menus, menu)
            # The box of "constant" comes and goes with the next frame, not while the menu, which
            # is deleted with the form, handles its own selection
            push!(gui.controls.listeners, on(menu.selection) do s
                (s == _GLASS_CONSTANT) == constant || (w.dirty = true)
                return nothing
            end)
        end
    end
    foreach(b -> _register_widget!(gui, b), w.boxes)
    foreach(m -> _register_widget!(gui, m), w.menus)
    w.settle = isempty(w.boxes) ? nothing : (time(), grids)
    return nothing
end

"""
    _settle_catalog_form!(w)

Moves the boxes of a new form of the catalog widget `w` (in the grids of `w.settle`, with the clock
time at which they were built) by a pixel, at the first frame with a later clock time. A workaround
for Makie 0.24, whose plots take the camera of their scene anew when its trigger changes, which is
the clock time `time()`: a `Textbox` is created with a default size and resized by its layout at
once; with a coarse clock (Windows) both happen at the same time, the second update is discarded,
and the text of the box is drawn with the camera of the default size, i.e. tiny, until the viewport
of the box changes again, which a box that keeps its place never gets. The move changes the
viewports without resizing them, hence the cameras are taken anew whatever else happens at that
time. Called every frame, see `_connect_catalog_window!`.
"""
function _settle_catalog_form!(w::_CatalogWidget)
    isnothing(w.settle) && return nothing
    t0, grids = w.settle
    time() == t0 && return nothing
    w.settle = nothing
    foreach(g -> Makie.colgap!(g, 1, _CATALOG_GAP + 1), grids)
    return nothing
end

"""
Releases the inputs of the form of the catalog widget `w` before they are deleted: they no longer
take the keyboard, see `_register_widget!`.
"""
function _release_catalog_inputs!(gui::LiveView, w::_CatalogWidget)
    foreach(tb -> tb.focused[] && Makie.defocus!(tb), w.boxes)
    foreach(m -> m.is_open[] && (m.is_open[] = false), w.menus)
    filter!(b -> !any(tb -> tb === b, w.boxes), gui.custom.boxes)
    filter!(b -> !any(m -> m === b, w.menus), gui.custom.menus)
    _release_listeners!(gui, Any[[tb.focused for tb in w.boxes]; [m.is_open for m in w.menus];
        [m.selection for m in w.menus]])
    empty!(w.boxes)
    empty!(w.menus)
    empty!(w.inputs)
    return nothing
end

"""
    _build_catalog_form!(gui, w, strings)

Replaces the form of the catalog widget `w`, e.g. after another entry was chosen: the blocks of the
old form are deleted (see `_release_catalog_inputs!`) and the inputs of the chosen entry are built
in a new layout with the `strings` as their texts, see `_fill_catalog_form!`.
"""
function _build_catalog_form!(gui::LiveView, w::_CatalogWidget, strings)
    _release_catalog_inputs!(gui, w)
    # A new layout instead of the empty rows and columns of the old one
    _delete_catalog_grid!(w.form)
    w.form = _catalog_form(w.layout)
    w.dirty = false
    _fill_catalog_form!(gui, w, strings)
    # The presses on the new widgets are kept from the camera, see `_shield_cards!`
    _shield_cards!(gui)
    return nothing
end

"""
    _flush_catalog_form!(gui, w)

Builds the form of the catalog widget `w` again with the texts of its inputs if it is `dirty`,
i.e. after the menu of a glass changed to or from "constant": the box of the refractive index is
added or removed. Called every frame, see `_connect_catalog_window!`.
"""
function _flush_catalog_form!(gui::LiveView, w::_CatalogWidget)
    w.dirty && _build_catalog_form!(gui, w, _catalog_strings(w))
    return nothing
end
