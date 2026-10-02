#=
Catalog of the components that can be added to the systems of the live view, see
`component_catalog` and `CatalogEntry`: the entries of the components of BeamletOptics, the
registry of all entries, the step from an entry and its values to the object and its code, and the
widget "Components", built where the layout places controls (see `add_controls!`).
=#

#=
Entries
=#

const _CATALOG = CatalogEntry[]
# Whether `_CATALOG` got the built-in entries, see `component_catalog`
const _CATALOG_FILLED = Ref(false)

function component_catalog()
    if !_CATALOG_FILLED[]
        _CATALOG_FILLED[] = true
        # before the entries that were added without this function
        prepend!(_CATALOG, _builtin_catalog())
    end
    return _CATALOG
end

# A length in [m], shown in mm
_length_param(name, default; kwargs...) = CatalogParam(name, default; unit = "mm", scale = 1e-3, kwargs...)

"""
    _builtin_catalog() -> Vector{CatalogEntry}

The entries of [`component_catalog`](@ref) for the components of BeamletOptics, with the defaults
of one inch optics. Only the numeric arguments of a constructor are parameters, the others keep its
defaults, e.g. the `stop` of a `Detector`. The radii of curvature follow BeamletOptics: positive if
the center of the surface lies behind it (towards +y), i.e. `R1 > 0` and `R2 < 0` for a biconvex
lens, `Inf` for a plane surface of a `SphericalLens`.
"""
function _builtin_catalog()
    inch = 25.4e-3
    return [
        CatalogEntry("Thin lens", ThinLens; group = "Lenses", params = [
            _length_param("R1", 50e-3), _length_param("R2", -50e-3),
            _length_param("diameter", inch), CatalogParam("n", 1.5)]),
        CatalogEntry("Spherical lens", SphericalLens; group = "Lenses", params = [
            _length_param("R1", 50e-3), _length_param("R2", -50e-3),
            _length_param("thickness", 5e-3), _length_param("diameter", inch),
            CatalogParam("n", 1.5)]),
        CatalogEntry("Round mirror", RoundPlanoMirror; group = "Mirrors", params = [
            _length_param("diameter", inch), _length_param("thickness", 5e-3)]),
        CatalogEntry("Square mirror", SquarePlanoMirror; group = "Mirrors", params = [
            _length_param("width", inch), _length_param("thickness", 5e-3)]),
        CatalogEntry("Thin beamsplitter", ThinBeamsplitter; group = "Beamsplitters", params = [
            _length_param("width", inch), _length_param("height", inch),
            CatalogParam("reflectance", 0.5; keyword = :reflectance)]),
        CatalogEntry("Cube beamsplitter", CubeBeamsplitter; group = "Beamsplitters", params = [
            _length_param("leg length", inch), CatalogParam("n", 1.5),
            CatalogParam("reflectance", 0.5; keyword = :reflectance)]),
        CatalogEntry("Right-angle prism", RightAnglePrism; group = "Prisms", params = [
            _length_param("leg length", inch), _length_param("height", inch),
            CatalogParam("n", 1.5)]),
        CatalogEntry("Detector", Detector; group = "Detectors", params = [
            _length_param("edge length", 10e-3)]),
    ]
end

#=
From an entry and its values to the object and its code
=#

"""
    _catalog_args(entry, values) -> (positional, keywords)

The arguments of the constructor of the `entry` for the `values` of its parameters (in the units
of the constructor, in the order of `entry.params`): the positional arguments in their order and
the keyword arguments as `keyword => value`. The source of both `_catalog_object` and
`_catalog_code`, such that the code constructs the object.
"""
function _catalog_args(entry::CatalogEntry, values)
    length(values) == length(entry.params) ||
        throw(ArgumentError("\"$(entry.name)\" has $(length(entry.params)) parameters, got $(length(values)) values"))
    positional = Float64[]
    keywords = Pair{Symbol, Float64}[]
    for (p, v) in zip(entry.params, values)
        isnothing(p.keyword) ? push!(positional, v) : push!(keywords, p.keyword => v)
    end
    return positional, keywords
end

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
`_catalog_object` makes, for [`export_changes`](@ref).
"""
function _catalog_code(entry::CatalogEntry, values)
    positional, keywords = _catalog_args(entry, values)
    args = join(repr.(positional), ", ")
    isempty(keywords) && return "$(entry.code_name)($args)"
    kwargs = join(("$k = $(repr(v))" for (k, v) in keywords), ", ")
    return "$(entry.code_name)($args; $kwargs)"
end

"""The `default` of the parameter `p` as shown in its box of the catalog, i.e. in its `unit`."""
function _catalog_string(p::CatalogParam)
    v = p.default / p.scale
    # without the rounding error of the division, e.g. 25.4 instead of 25.400000000000002
    isfinite(v) && (v = round(v; sigdigits = 12))
    return isinteger(v) && abs(v) < 1e15 ? string(Int(v)) : string(v)
end

"""
    _catalog_value(p::CatalogParam, s) -> Float64

The value of the parameter `p` for the text `s` of its box, in the units of the constructor. The
unchanged text of the default and an empty box, which shows the default as its placeholder, give
`p.default` itself. `Inf` is a value, e.g. for the radius of a plane surface. Throws an
`ArgumentError` for a text that is not a number.
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

"""
    _catalog_component(entry, strings) -> (; obj, origin)

The step from the form of the catalog to a component: parses the `strings` of the boxes of the
parameters of the `entry` (see `_catalog_value`), constructs the object `obj` and returns it with
its `origin = (; code, pose0)`, the call of its constructor as code and its pose as constructed,
see `_ComponentState`. Throws for an invalid input and what the constructor throws.
"""
function _catalog_component(entry::CatalogEntry, strings)
    length(strings) == length(entry.params) ||
        throw(ArgumentError("\"$(entry.name)\" has $(length(entry.params)) parameters, got $(length(strings)) values"))
    values = Float64[_catalog_value(p, s) for (p, s) in zip(entry.params, strings)]
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

# The title of the controls of the catalog, see `add_controls!`
const _CATALOG_TITLE = "Components"
# Widths of the menu of the entries and of the boxes of the parameters [px]
const _CATALOG_MENU_WIDTH = 216
const _CATALOG_BOX_WIDTH = 70

"""
    _CatalogWidget

The widgets of the catalog of a `LiveView`, in the `layout` of its controls (see
`_build_catalog!`): the label `target` of the system that gets the component, the `menu` of the
`entries`, the `form` with a row per parameter of the chosen entry, whose `boxes` hold the values,
and the button `place`. The form is built again when another entry is chosen, see
`_build_catalog_form!`.
"""
mutable struct _CatalogWidget
    const layout::GridLayout
    const entries::Vector{CatalogEntry}
    const target::Label
    const menu::Menu
    const place::Button
    form::GridLayout
    const boxes::Vector{Textbox}
end

"""The entry that is chosen in the menu of the catalog widget `w`."""
_catalog_entry(w::_CatalogWidget) = w.entries[w.menu.selection[]]

"""The texts of the boxes of the catalog widget `w`, as typed, i.e. also without Enter."""
_catalog_strings(w::_CatalogWidget) = String[tb.displayed_string[] for tb in w.boxes]

"""
    _build_catalog!(gui)

Builds the catalog of the `gui` (`gui.components.catalog`, see [`component_catalog`](@ref)) as the
controls "Components", where its layout places controls (see [`add_controls!`](@ref)): the line
"into: <system>" with the system that gets the component (see `_target_system`), the menu of the
entries ("group / name"), a box per parameter of the chosen entry with its default, and the button
"Place", see `_place_catalog!`. Nothing is built for an empty catalog and for a view without a
`System`, to which components can be added.
"""
function _build_catalog!(gui::LiveView)
    entries = gui.components.catalog
    (isempty(entries) || isempty(_mutable_systems(gui))) && return nothing
    add_controls!(gui, _CATALOG_TITLE) do layout
        target = Label(layout[1, 1], ""; halign = :left)
        options = [("$(e.group) / $(e.name)", i) for (i, e) in enumerate(entries)]
        menu = Menu(layout[2, 1]; options, default = first(first(options)),
            width = _CATALOG_MENU_WIDTH, halign = :left)
        form = _catalog_form(layout)
        place = Button(layout[4, 1]; label = "Place", halign = :left)
        w = _CatalogWidget(layout, entries, target, menu, place, form, Textbox[])
        # The boxes of the first form are registered with the controls, once they are built
        _fill_catalog_form!(gui, w; register = false)
        listeners = gui.controls.listeners
        push!(listeners, on(_ -> _build_catalog_form!(gui, w), menu.selection))
        push!(listeners, on(place.clicks) do _
            _show_catalog_target!(gui, w)
            _place_catalog!(gui, _catalog_entry(w), _catalog_strings(w))
        end)
        # The target follows the selection and the inspection, see `_refresh_catalog!`
        return g -> _show_catalog_target!(g, w)
    end
    return nothing
end

"""
Shows the system that gets the next component in the catalog of the `gui` again, e.g. after a
system was inspected, see `_on_shown!`; nothing without a catalog.
"""
function _refresh_catalog!(gui::LiveView)
    for c in gui.custom.controls
        c.title == _CATALOG_TITLE && _run_update!(gui, c, c.update)
    end
    return nothing
end

"""Shows the system that gets the component of the catalog widget `w`, see `_target_system`."""
function _show_catalog_target!(gui::LiveView, w::_CatalogWidget)
    sys = _target_system(gui)
    _update!(w.target.text, isnothing(sys) ? "into: no system" : "into: $(_label(gui, sys))")
    return nothing
end

# Gap between the name, the box and the unit of a parameter in the form of the catalog [px]
const _CATALOG_GAP = 8

# The layout of the form of the catalog in the `layout` of its controls, see `_CatalogWidget`
_catalog_form(layout::GridLayout) =
    GridLayout(layout[3, 1]; halign = :left, default_rowgap = 6, default_colgap = _CATALOG_GAP)

"""
    _fill_catalog_form!(gui, w; register = true)

Builds the rows of the form of the catalog widget `w` for its chosen entry: per parameter its
name, a `Textbox` with the default and the unit. The boxes take the keyboard like those of the
controls (see `_register_widget!`) if `register`.
"""
function _fill_catalog_form!(gui::LiveView, w::_CatalogWidget; register::Bool = true)
    params = _catalog_entry(w).params
    # An empty layout has no size
    isempty(params) && Label(w.form[1, 1], "no parameters"; halign = :left)
    for (i, p) in enumerate(params)
        s = _catalog_string(p)
        Label(w.form[i, 1], p.name; halign = :left)
        # An emptied box shows the default as its placeholder, see `_catalog_value`
        tb = Textbox(w.form[i, 2]; stored_string = s, placeholder = s, width = _CATALOG_BOX_WIDTH)
        Label(w.form[i, 3], p.unit; halign = :left)
        push!(w.boxes, tb)
        register && _register_widget!(gui, tb)
    end
    _settle_catalog_form!(gui, w)
    return nothing
end

"""
    _settle_catalog_form!(gui, w)

Moves the boxes of the new form of the catalog widget `w` by a pixel, at the first frame with a
later clock time than now. A workaround for Makie 0.24, whose plots take the camera of their scene
anew when its trigger changes, which is the clock time `time()`: a `Textbox` is created with a
default size and resized by its layout at once; with a coarse clock (Windows) both happen at the
same time, the second update is discarded, and the text of the box is drawn with the camera of the
default size, i.e. tiny, until the viewport of the box changes again, which a box that keeps its
place never gets. The move changes the viewports without resizing them, hence the cameras are
taken anew whatever else happens at that time.
"""
function _settle_catalog_form!(gui::LiveView, w::_CatalogWidget)
    isempty(w.boxes) && return nothing
    form = w.form
    listeners = gui.controls.listeners
    t0 = time()
    listener = Ref{Any}(nothing)
    listener[] = on(events(gui.ax.scene).tick) do _
        time() == t0 && return nothing
        off(listener[])
        filter!(l -> l !== listener[], listeners)
        # not a form that was replaced since, see `_build_catalog_form!`
        w.form === form && Makie.colgap!(form, 1, _CATALOG_GAP + 1)
        return nothing
    end
    push!(listeners, listener[])
    return nothing
end

"""
Releases the boxes of the form of the catalog widget `w` before they are deleted: they no longer
take the keyboard, see `_register_widget!`.
"""
function _release_catalog_boxes!(gui::LiveView, w::_CatalogWidget)
    foreach(tb -> tb.focused[] && Makie.defocus!(tb), w.boxes)
    filter!(b -> !any(tb -> tb === b, w.boxes), gui.custom.boxes)
    filter!(gui.controls.listeners) do l
        (l isa Observables.ObserverFunction && any(tb -> l.observable === tb.focused, w.boxes)) ||
            return true
        off(l)
        return false
    end
    empty!(w.boxes)
    return nothing
end

"""
    _build_catalog_form!(gui, w)

Replaces the form of the catalog widget `w` after another entry was chosen: the blocks of the old
form are deleted (see `_release_catalog_boxes!`) and the rows of the new entry are built in a new
layout, see `_fill_catalog_form!`.
"""
function _build_catalog_form!(gui::LiveView, w::_CatalogWidget)
    _release_catalog_boxes!(gui, w)
    # Like `add_controls!`: blocks are only added to parts that are attached to the figure
    _with_ui(gui) do
        foreach(delete!, _blocks!(Any[], w.form))
        # A new layout instead of the empty rows and columns of the old one
        _GLB.remove_from_gridlayout!(_GLB.gridcontent(w.form))
        w.form = _catalog_form(w.layout)
        _fill_catalog_form!(gui, w)
        _on_controls_added!(gui)
    end
    return nothing
end
