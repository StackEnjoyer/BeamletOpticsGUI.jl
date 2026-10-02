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
The argument of the constructor for the value `v` of the parameter `p`: the number, the glass with
the name `v` (see `_glass`) or, for a constant refractive index `v`, the function `λ -> v`.
"""
_catalog_arg(::CatalogParam, v::Real) = Float64(v)
_catalog_arg(::CatalogGlass, v::AbstractString) = _glass(v)
_catalog_arg(::CatalogGlass, v::Real) = (n = Float64(v); λ -> n)

"""The argument of the constructor for the value `v` of the parameter `p` as Julia code, see `_catalog_arg`."""
_catalog_arg_code(::CatalogParam, v::Real) = repr(Float64(v))
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
    _catalog_object(entry, values) -> AbstractObject

Constructs the component of the catalog `entry` with the `values` of its parameters, see
`_catalog_args`. Throws what the constructor throws, and an `ArgumentError` if it does not return
an `AbstractObject`.
"""
function _catalog_object(entry::CatalogEntry, values)
    positional, keywords = _catalog_args(entry, values)
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
constructor, see `_glass_code`, such that the code runs without this package.
"""
function _catalog_code(entry::CatalogEntry, values)
    positional, keywords = _catalog_args(_catalog_arg_code, entry, values)
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
`Inf` is a value, e.g. for the radius of a plane surface.

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
    return isfinite(v) ? round(v; sigdigits = 15) : v
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
parameters of the `entry` (see `_catalog_value`), constructs the object `obj` and returns it with
its `origin = (; code, pose0)`, the call of its constructor as code and its pose as constructed,
see `_ComponentState`. Throws for an invalid input and what the constructor throws.
"""
function _catalog_component(entry::CatalogEntry, strings)
    length(strings) == length(entry.params) ||
        throw(ArgumentError("\"$(entry.name)\" has $(length(entry.params)) parameters, got $(length(strings)) values"))
    values = Any[_catalog_value(p, s) for (p, s) in zip(entry.params, strings)]
    obj = _catalog_object(entry, values)
    return (; obj, origin = (; code = _catalog_code(entry, values), pose0 = _pose(obj)))
end

"""
    _place_catalog!(gui, entry, strings) -> Union{AbstractObject, Nothing}

"Place" of the catalog of the `gui`: constructs the component of the `entry` from the `strings` of
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
    _start_placement!(gui, c.obj; origin = c.origin)
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
    _HelpEntry(["Ins"], "open the catalog at the mouse"),
    _HelpEntry([:mouse => "drag"], "head of the catalog: move it"),
    _HelpEntry([:mouse => "move"], "while placing: near a beam, snap onto it"),
    _HelpEntry([:mouse => "click"], "while placing: drop it, Esc cancels")]]
# Sizes of the widgets of the catalog [px]: the icon buttons of the groups, the tiles of the
# entries and their number per row, the boxes of the numbers and the menus of the glasses
const _CATALOG_GROUP_SIZE = 32
const _CATALOG_TILE_WIDTH = 86
const _CATALOG_TILES_PER_ROW = 4
const _CATALOG_BOX_WIDTH = 64
const _CATALOG_GLASS_WIDTH = 128
# The numbers of an entry are in two columns from this number on
const _CATALOG_TWO_COLUMNS = 5
# Gap between the name, the box and the unit of a parameter in the form of the catalog, and
# between its two columns [px]
const _CATALOG_GAP = 8
const _CATALOG_COLUMN_GAP = 20

"""
    _CatalogWidget

The widgets of the catalog of a `LiveView`, in the `layout` of the body of its window (see
`_build_catalog!`), in the colors of the theme tokens `theme`, from top to bottom:

- `target`: the label of the system that gets the component
- `group_buttons`: an icon per group of the `entries` (`groups`, in the order of their first
  entries), of which the one with the index `group` is chosen; `group_label` names it, or the one
  under the mouse
- `tiles`: a tile per entry of the chosen group with its icon and its name (`tile_buttons`, each
  with the index of its entry), of which the one of the entry with the index `entry` is chosen;
  `entry_label` names it
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
    const entries::Vector{CatalogEntry}
    const groups::Vector{String}
    const target::Label
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
    _build_catalog!(gui)

Builds the catalog of the `gui` (`gui.components.catalog`, see [`component_catalog`](@ref)) as the
window "Components" (see `_CatalogWindow`), which floats over the 3D view in every layout: the line
"into: <system>" with the system that gets the component (see `_target_system`), the icons of the
groups, the tiles of the entries of the chosen group, the form of the chosen entry and the button
"Place", see `_CatalogWidget` and `_place_catalog!`. The window is hidden at first; the toggle
"Components" among the tools of the layout (see [`add_tool!`](@ref)) shows and hides it, the key
`Insert` shows it at the mouse, see `_connect_catalog_window!`. Both are listed in the help with
the mouse while placing (`_CATALOG_HELP`). Nothing is built for an empty catalog and for a view
without a `System`, to which components can be added.
"""
function _build_catalog!(gui::LiveView)
    entries = gui.components.catalog
    (isempty(entries) || isempty(_mutable_systems(gui))) && return nothing
    t = gui.layout.theme
    scene, part, head, close_button, body = _catalog_window_parts(gui.fig, t)
    label = (; _card_style(t, Label)..., halign = :left)
    target = Label(body[1, 1], ""; label..., color = t.muted)
    groups = unique(e.group for e in entries)
    row = GridLayout(body[2, 1]; halign = :left, default_colgap = 4)
    group_buttons = [_OverlayItem(row[1, k], t; icon = _catalog_group_icon(entries, g),
        size = _CATALOG_GROUP_SIZE, icon_size = 20, padding = (0, 0, 0, 0)) for (k, g) in enumerate(groups)]
    group_label = Label(body[3, 1], ""; label..., fontsize = 11, color = t.muted)
    tiles = _catalog_tiles(body)
    entry_label = Label(body[5, 1], ""; label..., font = :bold)
    form = _catalog_form(body)
    place = Button(body[7, 1]; label = "Place", _card_style(t, Button)..., halign = :left)
    widget = _CatalogWidget(body, t, entries, groups, target, group_buttons, group_label,
        entry_label, place, 0, 0, tiles, Pair{Int, _OverlayItem}[], form, Any[], Textbox[], Menu[], false,
        nothing)
    w = _CatalogWindow(scene, part, head, close_button, widget, false, nothing, nothing)
    gui.components.window = w
    listeners = gui.controls.listeners
    for (k, button) in enumerate(group_buttons)
        push!(listeners, on(_ -> _select_catalog_group!(gui, widget, k), button.clicks))
        push!(listeners, on(_ -> _show_catalog_group!(widget), button.hovered))
    end
    push!(listeners, on(place.clicks) do _
        _show_catalog_target!(gui, widget)
        _place_catalog!(gui, _catalog_entry(widget), _catalog_strings(widget))
    end)
    _select_catalog_group!(gui, widget, 1)
    _connect_catalog_window!(gui, w)
    # The toggle of the layout, among its tools
    w.tool = add_tool!((g, shown) -> _show_catalog!(g, shown), gui, _CATALOG_TITLE; icon = :lens,
        toggle = true, tooltip = "$_CATALOG_TITLE (Ins)")
    append!(gui.controls.help_extra, _CATALOG_HELP)
    _update_help!(gui.controls)
    # The presses on the new widgets are kept from the camera, see `_shield_cards!`
    _shield_cards!(gui)
    _show_catalog_target!(gui, widget)
    _arrange_catalog!(gui)
    return nothing
end

"""
Shows the system that gets the next component in the catalog of the `gui` again, e.g. after a
system was inspected, see `_on_shown!`; nothing without a catalog.
"""
function _refresh_catalog!(gui::LiveView)
    w = _catalog_window(gui)
    isnothing(w) || _show_catalog_target!(gui, w.widget)
    return nothing
end

"""Shows the system that gets the component of the catalog widget `w`, see `_target_system`."""
function _show_catalog_target!(gui::LiveView, w::_CatalogWidget)
    sys = _target_system(gui)
    _update!(w.target.text, isnothing(sys) ? "into: no system" : "into: $(_label(gui, sys))")
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
_catalog_tiles(layout::GridLayout) =
    GridLayout(layout[4, 1]; halign = :left, valign = :top, default_rowgap = 2, default_colgap = 2)

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
    w.group == k && return nothing
    w.group = k
    foreach(((i, b),) -> _update!(b.active, i == k), enumerate(w.group_buttons))
    _show_catalog_group!(w)
    _build_catalog_tiles!(gui, w)
    _select_catalog_entry!(gui, w, first(first(w.tile_buttons)))
    return nothing
end

"""
    _build_catalog_tiles!(gui, w)

Replaces the tiles of the catalog widget `w` by those of the entries of its chosen group, in rows
of `_CATALOG_TILES_PER_ROW`: each with the icon of its entry (see `_catalog_icon`) and its name. A
click on a tile chooses its entry, see `_select_catalog_entry!`.
"""
function _build_catalog_tiles!(gui::LiveView, w::_CatalogWidget)
    _release_listeners!(gui, [tile.clicks for (_, tile) in w.tile_buttons])
    empty!(w.tile_buttons)
    _delete_catalog_grid!(w.tiles)
    w.tiles = _catalog_tiles(w.layout)
    group = w.groups[w.group]
    members = [i for (i, e) in enumerate(w.entries) if e.group == group]
    for (k, i) in enumerate(members)
        entry = w.entries[i]
        row, col = fldmod1(k, _CATALOG_TILES_PER_ROW)
        tile = _OverlayItem(w.tiles[row, col], w.theme; icon = _catalog_icon(w.entries, entry),
            label = entry.name, tile_width = _CATALOG_TILE_WIDTH, icon_size = 28, fontsize = 11,
            padding = (3, 3, 6, 5))
        push!(w.tile_buttons, i => tile)
        push!(gui.controls.listeners, on(_ -> _select_catalog_entry!(gui, w, i), tile.clicks))
    end
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
    foreach(((j, tile),) -> _update!(tile.active, j == i), w.tile_buttons)
    entry = w.entries[i]
    _update!(w.entry_label.text, entry.name)
    _build_catalog_form!(gui, w, String[_catalog_string(p) for p in entry.params])
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
unit, in two columns from `_CATALOG_TWO_COLUMNS` numbers on, then the glasses, each with its name
and the menu of the glasses and "constant", for which a box takes the refractive index. The boxes
and the menus take the keyboard like those of the controls, see `_register_widget!`.
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
        two = length(numbers) >= _CATALOG_TWO_COLUMNS
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
        for (k, i) in enumerate(glasses)
            p = params[i]
            glass = strings[i] in names ? strings[i] : _GLASS_CONSTANT
            constant = glass == _GLASS_CONSTANT
            Label(grid[k, 1], p.name; label...)
            menu = Menu(grid[k, 2]; options = names, default = glass, _card_style(t, Menu)...,
                width = _CATALOG_GLASS_WIDTH, halign = :left)
            tb = nothing
            if constant
                Label(grid[k, 3], "n"; label...)
                tb = Textbox(grid[k, 4]; stored_string = strings[i],
                    placeholder = _catalog_number_string(p.n), box...)
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
