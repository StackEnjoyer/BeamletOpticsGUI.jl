#=
The public API of BeamletOpticsGUI: the generic functions with their docstrings and the types of the
cards. The methods are defined in the other files.
=#

"""
    kinematic_controls!(axis, handle; kwargs...)

Enables mouse and keyboard controls for moving and rotating the objects of a live-rendered system
`handle` within the `axis`. Returns a controller that can be removed via `close`.
"""
function kinematic_controls! end

"""
    live_view(system => beam, ...; kwargs...)
    live_view(system, beam; kwargs...)
    live_view(system, ...; kwargs...)

Opens a complete interactive window for one or several pairs of `system` and `beam`, or for systems
without a source, e.g. an empty table `live_view(System())` that gets its sources in the window: a 3D view in
which all components can be moved via [`kinematic_controls!`](@ref), a status line and optional
sliders. After each change, the detectors are emptied, the systems are solved again and the beams
and the shown detector views are updated. Returns a `LiveView`, which can be shown via `display`.

A source is given once: `live_view(sys1 => beam, sys2 => beam)` throws an `ArgumentError`, since a
source belongs to at most one system. Systems are added and removed in the window
([`add_system!`](@ref), [`remove_system!`](@ref)), an object may belong to several systems or to
none, and each system is traced on its own; see "Systems" and "Tracing per system" in the method
below.

The card of a `Detector` has a page "Results" with its detector view (spot diagram, PSF or
intensity, with metrics such as centroid, RMS or 1/e² radius and power), which collapses to a
thumbnail and, as a field, has a colorbar and can be shown on a logarithmic color scale with profiles. A click on a beam shows its position, path
length and, for Gaussian beamlets, its radius and curvature, the "measure" toggle measures
distances and angles between components and beams. The key `g` zooms to the selection, "home",
the "views" menu and "save view" set and store camera views. While moving, beam groups are solved
only for their rendered beams (`preview = true`), the full group once the movement pauses.

Main keyword arguments: `detectors` (`:auto` or `[]`: every detector has its page "Results", no
card is pinned at start; a vector of `pd`, `pd => kind` or `pd => (kind, kwargs)` pins the cards of
these detectors at start, with `kind` one of `:auto`, `:spot`, `:psf` and `:intensity` and the
options `n`, `colorscale`, `colorrange`, `colorbar`, `profiles` and `expanded`), `on_change = (gui, obj) -> nothing` (called after full solves),
`sliders = ["label" => (range, callback)]`, `system_kwargs`, `beam_kwargs`, `preview = true`,
`views = ["name" => (eye, lookat, up)]`, `lighting = :studio` (see `BeamletOptics.studio_lighting!`),
`edges` and `size`. `extras = [obj => render_kwargs, ...]` adds objects without a system that are
rendered, selected, moved and hidden like the components, but never traced, e.g. a housing from an
STL file (`MeshDummy`); the card of such mechanics has an opacity slider. `auto_trace` is the start
value of the auto tracing of every system. `sidebar_width` and `dock_height` set the start sizes
of the sidebars and the dock of `layout = :app`, which are resized with the mouse. `background_card = obj` (or
`gui -> obj`, `nothing` for none) shows the card of an object without a place in the scene, e.g.
an environment, after a click on the empty background while nothing is selected; its
[`card_rows`](@ref) get `obj` itself. `layout = :app` arranges the window like an application, with a toolbar,
collapsible sidebars (object tree with selection and visibility, sliders, the cards of the
selection and of pinned objects), an analysis dock with a tab per [`add_panel!`](@ref) (collapsed
until the first one exists) and a status bar, in the colors of `theme = :light` or `:dark`; the
default `layout = :compact` fills the window with the 3D view, places the panels of
[`add_panel!`](@ref) in a column on its right and shows the
tools, the status and the help on demand over the 3D view. The component
cards and the progress window have the colors of the `theme` in both layouts. Own panels,
widgets and tools are added to either layout via [`add_panel!`](@ref), [`add_controls!`](@ref)
and [`add_tool!`](@ref). All other keyword arguments are passed to [`kinematic_controls!`](@ref). See
the method below for details.
"""
function live_view end

"""
    export_changes(gui; io = stdout, clipboard = false)

Returns the changes of the poses in the `live_view` window `gui` as Julia code, i.e. one
`rotate3d!` about the position of the object and one `translate_to3d!` per moved object, relative
to its initial pose. The code is printed to `io` and copied to the clipboard if `clipboard` is
`true`. See the method below for details.
"""
function export_changes end

"""
    add_panel!(f, gui, title::AbstractString; select = false) -> GridLayout

Adds an own analysis panel named `title` to the [`live_view`](@ref) window `gui`, placed by its
layout: with `layout = :compact` in a column right of the 3D view (created by the first panel),
with the title above it; with `layout = :app` as a new tab of the analysis dock, behind the tabs
that exist (the active tab stays active unless `select = true`). The dock stays collapsed until the
first panel exists.

`f(layout)` builds the content into the given `GridLayout`, e.g. an `Axis` with plots, and may
return a function `update(gui)`, which is called after each full solve (not after the preview
solves while moving), like the `on_change` of `live_view`, and once right away. In the app layout,
`update` only runs while the tab is shown; a hidden panel is updated when its tab is opened or the
dock is expanded. Any other return value of `f`, e.g. the last plot of a `do` block, means no
`update`. Errors in `update` are logged once and do not interrupt the interaction. Returns the
layout.

```julia
gui = live_view(system, beam)
add_panel!(gui, "Power") do layout
    ax = Axis(layout[1, 1]; xlabel = "Update", ylabel = "P [mW]")
    pts = Observable(Point2f[])
    lines!(ax, pts)
    return gui -> (push!(pts[], Point2f(length(pts[]) + 1, 1e3 * optical_power(pd))); notify(pts))
end
```
"""
function add_panel! end

"""
    add_controls!(f, gui, title::AbstractString) -> GridLayout

Adds own widgets to the [`live_view`](@ref) window `gui`, placed by its layout: with
`layout = :compact` as an entry `title` of the tool rail (the button "⋯"), which opens the widgets
in a popover next to the rail; with `layout = :app` as a section `title` of the left sidebar, below
"Parameters". `f(layout)`
builds the widgets (e.g. `Button`, `Toggle`, `Menu`, `Textbox`, or an own widget type, see
[`card_input`](@ref)) into the given `GridLayout` and connects them. Returns the layout.

Controls are meant for parameters without an object in the scene, e.g. a setting of the whole
setup; the widgets of an object belong on its card, see [`card_rows`](@ref).

`Textbox`es and `Menu`s in the layout take the keyboard like those of the live view: while a box
is focused or a menu is open, the keys of the 3D view and the camera are ignored. They are
collected once `f` returns, widgets added later are not. An input that changes the optics solves
the systems again via [`retrace!`](@ref), which makes the change after a running solve is
cancelled.

Like the builder of [`add_panel!`](@ref), `f` may return a function `update(gui)`, which is called
once right away and after each full solve (not after the preview solves while moving), e.g. to
show the current value of a parameter after an undo; `update` must not change objects. Any other
return value of `f`, e.g. the last listener of a `do` block, means no `update`. Errors in `update`
are logged once and do not interrupt the interaction.

```julia
add_controls!(gui, "Laser") do layout
    box = Textbox(layout[1, 1]; placeholder = "power [mW]", width = 100)
    on(box.stored_string) do s
        retrace!(() -> set_power!(laser, 1e-3 * parse(Float64, s)), gui)
    end
    return gui -> card_show!(box, 1e3 * power(laser))
end
```
"""
function add_controls! end

"""
    add_tool!(f, gui, name::AbstractString; icon = :object, key = nothing, toggle = false, tooltip = name)

Adds a tool to the [`live_view`](@ref) window `gui`: a button that calls `f(gui)`, or with
`toggle = true` a toggle that calls `f(gui, active::Bool)` whenever it is switched. With
`layout = :app`, an icon button (or toggle) at the end of the toolbar, with the `icon` and the
`tooltip`; with `layout = :compact`, an entry (icon and `name`) of the tool rail opened by the
button "⋯". A tool with a `key` is listed in the help card under "Own tools".

`icon` is a name of the icon set of the app layout, e.g. `:measure`, `:export` or `:chart` (an
unknown name throws an `ArgumentError` that lists the valid ones, in any layout), or an own
`Makie.BezierPath`, drawn like a `scatter` marker: in the unit square centered at the origin, e.g.
`BezierPath("M -0.3 -0.3 L 0.3 -0.3 L 0 0.3 Z")` for a triangle.

`key`, a free `Makie.Keyboard.Button` such as `Keyboard._2` or `Keyboard.f5`, presses the button
(or switches the toggle) from the 3D view; it is shown in the tooltip or label. Keys taken by the
live view, the kinematic controls, Makie's `Camera3D` (which binds almost all letters) or another
tool throw an `ArgumentError` that names the existing binding. The key is ignored while a textbox of the window is focused. Errors in
`f` are logged once. Returns the widget, with `clicks` (button) or `active` (toggle).
"""
function add_tool! end

"""
    retrace!(gui)
    retrace!(f, gui)

Solves the systems of the [`live_view`](@ref) window `gui` again after a change from code, e.g. a
widget of [`add_controls!`](@ref) or a tool of [`add_tool!`](@ref), like after a slider of the
`sliders` kwarg: the render of the objects is updated, then the systems are solved (with preview
tracing and deferred solves of slow systems, as while moving), or the beams are marked as
outdated if auto tracing is off. `on_change` and the `update` of the panels of
[`add_panel!`](@ref) run after the full solve.

With `f`, `f()` makes the change first, after a solve running in the background is cancelled:
objects must not change while they are traced, hence changes of objects belong into `f`.
"""
function retrace! end

"""
    view_cube!(ls::LScene; size = 110, corner = :top_right, duration = 0.3)

Adds a CAD-style view cube to a corner of the 3D view `ls`. The cube rotates with the camera, and a
left click on a face, an edge or a corner of the cube moves the camera to the corresponding
standard view, keeping the `lookat` point and the distance of the camera. Returns a `ViewCube`,
which can be removed via `close`. The view cube is shown by default in [`live_view`](@ref).

The camera looks at the clicked side of the system, i.e. it is placed on the side of the clicked
face:

| face     | camera at | up   |
|:---------|:----------|:-----|
| `Top`    | `+z`      | `+y` |
| `Bottom` | `-z`      | `+y` |
| `Front`  | `-y`      | `+z` |
| `Back`   | `+y`      | `+z` |
| `Right`  | `+x`      | `+z` |
| `Left`   | `-x`      | `+z` |

Edges and corners give the diagonal views between the adjacent faces, with `+z` as the up
direction. The region under the cursor is highlighted.

# Keyword args

- `size = 110`: [px] edge length of the square viewport of the cube
- `corner = :top_right`: one of `:top_right`, `:top_left`, `:bottom_right` and `:bottom_left`
- `duration = 0.3`: [s] duration of the animated transition, `0` switches the view instantly
"""
function view_cube! end

"""
    CardWidget(T; name = nothing, value = nothing, on = nothing, solve = false, attributes...)

A widget on a card of [`live_view`](@ref), see [`card_rows`](@ref): a `Makie` block of the type
`T`, e.g. `Label`, `Slider`, `Toggle`, `Textbox`, `Button` or `Menu`, created as
`T(position; attributes...)` with the `attributes`, e.g. the `range` of a `Slider` or the `width`.
The card places the widget, hides it with the card and keeps clicks on it from the 3D view, and its
textboxes take the keyboard. `T` may be an own widget type with methods of [`card_input`](@ref) and
[`card_show!`](@ref), e.g. a `Makie.@Block`.

- `value(gui, obj)`: the value the widget shows for the object `obj` of the card, passed to
  [`card_show!`](@ref): the text of a `Label` or `Button`, the value of a `Slider`, `Toggle` or
  `Textbox`. Refreshed when the card gets its object, after moves, solves and inputs.
- `on(gui, obj, v)`: applies an input `v` of the widget to `obj`, a new value of its
  [`card_input`](@ref): the value of a `Slider`, the state of a `Toggle`, the entered text of a
  `Textbox`, the click count of a `Button` or the selection of a `Menu`. Inputs of a widget without
  `on` are ignored.
- `solve = true`: the input changes the optics, e.g. a parameter of `obj`: a running solve is
  cancelled before `on`, and the systems are solved again afterwards (or the beams are marked as
  outdated without auto tracing), like after a move, via the `on_change` of the controls.
- `name`: finds the widget on a card, e.g. in tests.

`gui` is the `LiveView`, e.g. for the beams of the last solve or the status line.
"""
struct CardWidget
    type::Type
    attributes::NamedTuple
    value::Any
    on::Any
    solve::Bool
    name::Union{Nothing, Symbol}
end

CardWidget(type::Type; name = nothing, value = nothing, on = nothing, solve::Bool = false, attributes...) =
    CardWidget(type, NamedTuple(attributes), value, on, solve, name)

"""
    CardRow(cells...)

A line of a card of [`live_view`](@ref), see [`card_rows`](@ref): its `cells` from left to right,
each a text or a [`CardWidget`](@ref).
"""
struct CardRow
    cells::Vector{Union{String, CardWidget}}
end

CardRow(cells::Union{AbstractString, CardWidget}...) = CardRow(Union{String, CardWidget}[_card_cell(c) for c in cells])
_card_cell(s::AbstractString) = String(s)
_card_cell(w::CardWidget) = w

"""
    card_rows(obj)

Rows of the card of `obj` in [`live_view`](@ref), a tuple of [`CardRow`](@ref)s, chosen by multiple
dispatch. By default, the rows of the pose, see [`pose_card_rows`](@ref); beams, beam groups and
sources add the rows of [`beam_card_rows`](@ref) (toggles and the drawn length of the final rays), a source whose rays can be regenerated (see
`BeamletOptics.set_num_rays!`) a slider for the number of rays, a `Detector`
its signal (the power or the number of rays of its detector view while a view is shown, else the
number of hits), mechanics (`NonInteractableObject`, e.g. a
`MeshDummy`, and `IntersectableObject`) a slider for their opacity. The card of a system
(`AbstractSystem`, shown after a click on its entry in the component menu or the object tree)
shows the number of its objects, the number of rays of its sources that are on and the duration of
the last solve; the window adds the rows of the system widget to these (its name, its tracing, its
members and "remove", see "Systems" of [`live_view`](@ref)), which are not part of this method. Add a method for an own type to show its properties or controls on its card, e.g.

```julia
BeamletOpticsGUI.card_rows(l::MyLens) = (pose_card_rows(l)...,
    CardRow("f", CardWidget(Label; value = (gui, l) -> "\$(1e3 * focal_length(l)) mm")))
```

A card exists only for things in the scene (objects, groups, sources, systems, clip planes); a
parameter without an object belongs into [`add_controls!`](@ref). The card may be rebuilt at any
time and shows other objects of the same declarations, hence the widgets keep no state: `value`
and `on` get the `gui` and the object. `value` runs after every move, solve and input and must be
cheap. The rows of a system type extend the default ones via
`invoke(BeamletOpticsGUI.card_rows, Tuple{BeamletOptics.AbstractSystem}, sys)`.

BeamletOpticsGUI has the methods for the types of BeamletOptics.
"""
function card_rows end

"""
    pose_card_rows(obj)

The rows of the pose of `obj` on its card in [`live_view`](@ref), see [`card_rows`](@ref): the
position `x`, `y`, `z` [mm], where `Enter` moves `obj` to the typed coordinate, and the rotations
`rx`, `ry`, `rv` [mrad] about the red, green and blue axis of the controls.
"""
function pose_card_rows end

"""
    beam_card_rows(beam)

The rows of the beam on the card of a beam, beam group or source `beam` in [`live_view`](@ref),
see [`card_rows`](@ref). The row `beam` has the toggle "on", which switches the beam off and on.
A beam that is off is neither solved nor drawn, its rays are removed, such that detectors and
measurements ignore it, and only its source marker stays; with `auto_trace = false` the switch
marks the beams as outdated instead of solving.

Gaussian beamlets (`GaussianBeamlet`, `AstigmaticGaussianBeamlet` and groups of them) add the
toggle "beams", which draws the generating beams (chief, divergence and waist rays) as the static
`render!` with `show_beams = true` does. Polarized beams (their rays are `PolarizedRay`s, e.g. an
`AstigmaticGaussianBeamlet`) add the toggle "polarization", which draws the polarization along
the beam, and the rows `pol λ` and `pol amp` with sliders for the wavelength [mm] of the drawn
curve and its amplitude ([mm], of astigmatic beamlets as a multiple of the beam radius), on
logarithmic scales over ranges given by the size of the scene. Of a beam group, the generating
beams and the polarization are drawn for its central beam, the one starting nearest the axis of
the group. These change the display only. The initial states are set by the `live_view` keywords
`beams_off` and `beam_kwargs` (`show_beams`, `show_polarization`, `pol_λ`, `pol_amplitude`,
`pol_scale`).

The last row, `length`, has a box with the length [mm] with which the final rays of the beam, i.e.
those that hit nothing, are drawn (`flen` of `live_render!`: by default 1 m, of Gaussian beamlets
0.1 m, or as given by the `beam_kwargs`). An input draws the beam and its overlays again with that
length, nothing is solved; an input that is no positive number is reported in the status line.

The card of an own beam type adds the rows after its own rows, e.g.

```julia
BeamletOpticsGUI.card_rows(b::MyBeam) = (pose_card_rows(b)..., beam_card_rows(b)...)
```
"""
function beam_card_rows end

"""
    card_actions(obj)

Buttons in the head of the card of `obj` in [`live_view`](@ref), a tuple of
[`CardWidget`](@ref)s, chosen by multiple dispatch like [`card_rows`](@ref): by default "hide"
(or "show" for a hidden object), for clip planes "flip" and "remove", for systems "hide" and "new
window" (see [`open_system`](@ref)). The card of an object with parts (a group or a `MultiShape`
object) gets the button "parts ›" after them, which opens its selection card.
"""
function card_actions end

"""
    card_input(w) -> Union{Observable, Nothing}

The input of the widget `w` on a card of [`live_view`](@ref) (see [`CardWidget`](@ref)): an
`Observable` whose updates are the inputs of the user, each passed as `v` to the `on(gui, obj, v)`
of the declaration. `nothing` means that the widget takes no input, e.g. a `Label`, and is the
default for any type. BeamletOpticsGUI has methods for the blocks of `Makie`: the `value` of a
`Slider`, `active` of a `Toggle`, `stored_string` of a `Textbox`, `clicks` of a `Button` and
`selection` of a `Menu`.

An own widget type, e.g. a `Makie.@Block` or any type constructed as `T(position; attributes...)`
that places itself at a `GridPosition`, adds a method of `card_input` and of [`card_show!`](@ref)
and can then be declared as `CardWidget(T; ...)` on a card. Widgets built in
[`add_controls!`](@ref) may use both functions as well, the controls do not call them. An own type
that consists of several blocks deletes them in `Base.delete!`, which the card calls when it
rebuilds its widgets (a `Makie.@Block` with `@forwarded_layout` does so by itself).
"""
function card_input end

"""
    card_show!(w, v)

Shows the value `v` in the widget `w` on a card of [`live_view`](@ref), where `v` is the result of
the `value(gui, obj)` of its [`CardWidget`](@ref). The card calls it when it gets its object and
after moves, solves and inputs. BeamletOpticsGUI has methods for the blocks of `Makie`: the
text of a `Label` or the label of a `Button` (`string(v)`), the text of a `Textbox`, the value of
a `Slider` (the closest step of its range), the state of a `Toggle` and the selected option of a
`Menu` (the option with the value `v`; an unknown value keeps the selection). The default for any
other type shows nothing.

Showing a value is not an input: the card ignores the updates of [`card_input`](@ref) while it
shows values, and a method should not change the observable of `card_input` if it can avoid it,
since outside of a card, e.g. in [`add_controls!`](@ref), nothing ignores them. A method should
also keep what the user is typing: the method for a `Textbox` does not change a focused box,
unless it is called with `force = true`, which the card does after an input was applied.
"""
function card_show! end

"""
    add_component!(gui, obj; system = nothing, select = true, label = nothing, code = nothing) -> obj

Adds the object `obj` (an `AbstractObject` or an object group) to a system of the
[`live_view`](@ref) window `gui` at runtime: `obj` is pushed to the system, rendered and registered
with the controls, i.e. it is selected, moved, hidden and exported like the components the view
started with. Then the systems are solved again, or the beams are marked as outdated without auto
tracing. Place `obj` before adding it, e.g. via `translate_to3d!`.

`system` is the `System` of the `gui` that gets `obj`: by default the system of the selected or
inspected object (or the inspected system itself), otherwise the first `System` of the view. All
beams paired with that system are traced through `obj`. `system = :none` adds `obj` without a
system: it is shown, moved and exported like any component, but not traced, until it becomes a
member of a system. A `StaticSystem` can not be changed: it throws an `ArgumentError`, like a
`system` that is not shown in the `gui` and, without a `system`, an `obj` that the `gui` shows
already. `select = true` selects `obj` afterwards (or shows its card if it is not movable), `label`
names it like an entry of the `labels` kwarg of `live_view`.

An object belongs to any number of systems of the view: for an `obj` that the `gui` shows already
(at its top level, i.e. not an object of a group), `add_component!(gui, obj; system = sys2)` makes it a
member of `sys2` as well, like "+" of that system in the window. It stays one object, with one
pose, one card and one set of plots, and the beams of all its systems are traced through it, e.g.
a mirror that the transmitter and the receiver of a lidar share.

`code` is the constructor call of `obj` as Julia code, e.g. `"ThinLens(0.05, -0.05, 0.0254, 1.5)"`,
which constructs `obj` in the pose that it has when it is added. [`export_script`](@ref) then writes
this call followed by the change of the pose of `obj` since it was added, like for a component of
the catalog; without `code` the constructor is not known and the script marks where to construct
`obj`. Give `code` for an object built from code, e.g. by a tool or an agent, before you move it,
and move it afterwards (e.g. in [`retrace!`](@ref)): an object that was moved before it was added
with `code` is exported in a wrong pose, which is not checked. The page "Edit" and copying stay for
the components of the catalog, whose parameters are known.

`code` must be one Julia expression that runs on its own in the script, i.e. after
`using BeamletOptics` only: write the values out and do not refer to variables or functions of the
session, e.g. a glass `nbk7`, which the script does not define. An `ArgumentError` is thrown, and
nothing is added, if `code` is empty, does not parse or has several statements; what it evaluates
to is not checked.

The components of the catalog are added this way once they are placed, see
[`component_catalog`](@ref). [`remove_component!`](@ref) removes a component again,
[`export_changes`](@ref) lists the added and removed components.

    add_component!(gui, source; system = nothing, select = true, label = nothing, beam_kwargs = (;), code = nothing) -> source

Adds the `source` (a beam or a beam group, e.g. a `Beam`, a `GaussianBeamlet` or a
`CollimatedSource`) to the `gui`: it is traced through the `system` with every solve, rendered with
the `beam_kwargs` (those of `live_render!` of the beam, as an entry of the `beam_kwargs` of
`live_view`; by default in the color of its wavelength, e.g. red for 632.8 nm and a dark red for
infrared light, and a beam group with `render_every = 5`; `beam_kwargs = (; color = :blue)` sets
another color) and gets a marker, with
which it is selected and moved like the sources the view started with, also in a view with
`movable_sources = false`. `system` is any system of the `gui`, also a `StaticSystem`, which a
source does not change; by default the system that gets a component, otherwise the first system of
the view. A source belongs to at most one system: `system = :none` adds it without one, which
shows its marker, but neither traces nor draws it. For a `source` that the `gui` shows already,
a `system` moves it to that system (or to none), and without a `system` it throws an
`ArgumentError`. A view may start without a source, see `live_view(system)`. `code` is the
constructor call of the `source` in its current pose, as for a component.

```julia
gui = live_view(System())
add_component!(gui, Beam([0.0, 0, 0], [0.0, 1, 0], 632.8e-9); label = "laser")
lens = ThinLens(50e-3, -50e-3, 25.4e-3, 1.5)
translate_to3d!(lens, [0, 0.1, 0])
add_component!(gui, lens; label = "lens")
```
"""
function add_component! end

"""
    remove_component!(gui, obj; system = nothing) -> obj

Removes the object `obj` from the [`live_view`](@ref) window `gui`, like "remove" on its card or
the key `Delete` while it is selected: `obj` is deleted from all its systems, its plots and its
cards are removed, and the systems are solved again, or the beams are marked as outdated without
auto tracing. Adding and removing are entries of the undo history of the controls: `Ctrl+Z` in the
window brings a removed object back, as does [`add_component!`](@ref).

With a `system`, `obj` is only taken out of that `System`, like "−" of the system in the window: it
stays in the view, as a member of its other systems or, after its last one, without a system, i.e.
shown but not traced.

`obj` is a top-level object (or object group) of the `gui`: of its `System`s, or one without a
system, e.g. an extra. An object of a group can not be removed on its own, remove the group
instead. It throws an `ArgumentError`, like an object of a `StaticSystem` and an object that is not
shown in the `gui`.

    remove_component!(gui, source; system = nothing) -> source

Removes the `source` (a beam or a beam group) from the `gui`: it is no longer traced, and its
beam, its marker and its cards are removed. Every source can be removed, also the
last one, which leaves a view without a source; it throws an `ArgumentError` for a beam that is no
source of the `gui`. With the `system` that it is traced through, the source only loses its
system: it keeps its marker, but is neither traced nor drawn.
"""
function remove_component! end

"""
    add_system!(gui; label = nothing, select = true) -> System

Adds a new, empty `System` to the [`live_view`](@ref) window `gui` at runtime, like "System" among
its tools, and returns it. `label` names it, by default "System n". With `select`, its card is
shown and it gets the next component of the catalog. Its components and sources are added with
[`add_component!`](@ref), e.g. an object that another system holds already:

```julia
rx = add_system!(gui; label = "Receiver")
add_component!(gui, mirror; system = rx)    # the mirror of the transmitter, in both systems
add_component!(gui, Beam([0.0, 0.1, 0], [0.0, -1, 0], 905e-9); system = rx)
```

Each system is traced on its own, see "Tracing per system" of [`live_view`](@ref).
[`remove_system!`](@ref) removes a system again; both are entries of the undo history.
"""
function add_system! end

"""
    remove_system!(gui, system) -> system

Removes the `system` from the [`live_view`](@ref) window `gui`, like "remove" on its card. Nothing
is deleted: its sources and its objects that are in no other system of the view stay in the view
without a system, i.e. shown but not traced, and the objects of the `system` itself are not
changed. It throws an `ArgumentError` for the last system of the view, for a system that the `gui`
does not show and for one that is open in another window, see [`open_system`](@ref).
"""
function remove_system! end

"""
    open_system(gui, system; display = true, kwargs...) -> LiveView

Opens the `system` of the [`live_view`](@ref) window `gui` in a new window with its components and
the sources that are traced through it, like the button "new window" on the card of the system
(shown after a click on the system in the object tree or in the component menu). Useful for a view
of several systems, one of which is worked on in a window of its own. Returns the new live view,
which is shown unless `display` is `false`.

The new window is a live view of its own: it takes over the layout, the theme, the catalog, the
names and labels, how the system and the beams are drawn, the beams that are switched off, the
tracing, the snapping, the table and the settings of the controls (e.g. the steps of the keys and
the constraints) of the `gui`, but not its clip planes, sliders, panels, tools, pinned cards,
hidden objects and camera. The `kwargs` are those of [`live_view`](@ref) and take
precedence, e.g. `layout = :app` or `size = (1000, 700)`.

Both windows are linked: they show the same objects, not copies. A component or source that is
moved, added, removed or edited in one window changes in the other one as well, with the same name,
and the variables of the script stay valid. Only the window in which something changed solves the
systems, the other one shows the result; while the beams of one window are outdated, e.g. without
auto tracing, those of the other one are dimmed as well, and tracing in either window brings both
up to date. The switch of the auto tracing is one for the linked windows: switching it in one of
them switches it in the other ones, also the `auto_trace` kwarg given here. Everything else is
kept per window: the selection, the camera, colors, hidden objects,
clip planes and the undo history, from which the entries on a component that the
other window added or removed are dropped. The link ends when one of the windows is closed.

A system can be opened several times, and also from the new window. It throws an `ArgumentError`
for a system that the `gui` does not show.
"""
function open_system end

"""
    CatalogParam(name, default; unit = "", scale = 1.0, keyword = nothing, integer = false,
        presets = ())

A numeric parameter of a [`CatalogEntry`](@ref), passed to its constructor: the `default` value in
the units of the constructor (SI in BeamletOptics, e.g. [m]), shown and entered in the catalog as
`value / scale` with the `unit`, e.g. `CatalogParam("diameter", 25.4e-3; unit = "mm", scale = 1e-3)`
for a box that shows `25.4` mm. A parameter with `keyword = :name` is passed as that keyword
argument, the other parameters are passed as positional arguments in their order.

A parameter with `integer = true` is passed as an `Int`, e.g. the `num_rays` of a source: its
`default` must be a whole number, otherwise an `ArgumentError` is thrown, and the catalog only takes
whole numbers for it.

`presets` are named values of the parameter, as pairs `"name" => value` in the units of the
constructor, e.g. `presets = ["532 nm" => 532e-9, "632.8 nm" => 632.8e-9]` for the laser lines of a
wavelength. The catalog shows them in a menu next to the box of the parameter: choosing one writes
its value into the box, and the menu shows "custom" for any other value of the box.
"""
struct CatalogParam
    name::String
    default::Float64
    unit::String
    scale::Float64
    keyword::Union{Nothing, Symbol}
    integer::Bool
    presets::Vector{Pair{String, Float64}}
end

function CatalogParam(name::AbstractString, default::Real; unit::AbstractString = "",
        scale::Real = 1.0, keyword::Union{Nothing, Symbol} = nothing, integer::Bool = false,
        presets = ())
    (isfinite(scale) && scale != 0) ||
        throw(ArgumentError("the scale of the parameter \"$name\" must be finite and not zero, got $scale"))
    (!integer || isinteger(default)) ||
        throw(ArgumentError("the default of the integer parameter \"$name\" must be a whole number, got $default"))
    return CatalogParam(String(name), Float64(default), String(unit), Float64(scale), keyword, integer,
        Pair{String, Float64}[String(first(p)) => Float64(last(p)) for p in presets])
end

"""
    CatalogGlass(name = "glass"; default = "N-BK7", n = 1.5, keyword = nothing)

The glass of a [`CatalogEntry`](@ref), passed to its constructor as the refractive index `n(λ)`:
the catalog shows a menu of the glasses of [`catalog_glasses`](@ref) and "constant", for which a
box takes a constant refractive index with the default `n`. `default` is the name of the glass that
is chosen at first, or `"constant"`; a name that [`catalog_glasses`](@ref) does not hold throws an
`ArgumentError`. `name` and `keyword` as for [`CatalogParam`](@ref).

The constructor gets the glass as it is stored in [`catalog_glasses`](@ref), e.g. a
`SellmeierEquation`, and for "constant" a function `λ -> n`, which every constructor of
BeamletOptics with a refractive index takes.
"""
struct CatalogGlass
    name::String
    default::String
    n::Float64
    keyword::Union{Nothing, Symbol}
end

function CatalogGlass(name::AbstractString = "glass"; default::AbstractString = "N-BK7", n::Real = 1.5,
        keyword::Union{Nothing, Symbol} = nothing)
    default == _GLASS_CONSTANT || _glass(default)
    (isfinite(n) && n > 0) ||
        throw(ArgumentError("the refractive index of the parameter \"$name\" must be positive, got $n"))
    return CatalogGlass(String(name), String(default), Float64(n), keyword)
end

"""
    CatalogEntry(name, constructor; group = "Components", params = [], code_name = string(nameof(constructor)), icon = nothing, source = false)

An entry of the component catalog of [`live_view`](@ref), see [`component_catalog`](@ref): a
component that the user picks, parametrizes and places in the 3D view. `constructor` is called with
the values of the `params` (numbers, see [`CatalogParam`](@ref), and glasses, see
[`CatalogGlass`](@ref)) and returns the `AbstractObject` (or object group) to add, in the pose in
which it is constructed; the catalog then moves it to where it is placed.

An entry with `source = true` is a source: `constructor` is called as
`constructor([0, 0, 0], [0, 1, 0], values...; keywords...)`, i.e. with the position and the
direction of the source before the values of the `params`, and returns the beam or the beam group
to add, e.g. `Beam` or `CollimatedSource`. A constructor that returns an object for an entry with
`source = true`, or a beam for one without, throws an `ArgumentError` when the entry is placed.

The catalog shows the entries by their `group`, each as a tile with its `name` and its `icon`: the
name of an icon of the live view as for [`add_tool!`](@ref) (e.g. `:lens`, an unknown name throws
an `ArgumentError`) or an own `Makie.BezierPath`. An entry without an icon shows the icon of its
group; a group that is not one of the built-in ones shows the icon of its first entry that has one.

[`export_changes`](@ref) prints the component as the call `code_name(values...; keywords...)`,
a source as `code_name([0.0, 0.0, 0.0], [0.0, 1.0, 0.0], values...; keywords...)`, each followed by
the calls that move it to its pose; hence `constructor` should be a function or type that the user's script can call by that name,
e.g. `ThinLens`, not an anonymous wrapper.

```julia
entry = CatalogEntry("Thin lens", ThinLens; group = "Lenses", icon = :lens, params = [
    CatalogParam("R1", 50e-3; unit = "mm", scale = 1e-3),
    CatalogParam("R2", -50e-3; unit = "mm", scale = 1e-3),
    CatalogParam("diameter", 25.4e-3; unit = "mm", scale = 1e-3),
    CatalogGlass()])
```
"""
struct CatalogEntry
    name::String
    group::String
    constructor::Any
    params::Vector{Union{CatalogParam, CatalogGlass}}
    code_name::String
    icon::Union{Nothing, Symbol, Makie.BezierPath}
    source::Bool
end

function CatalogEntry(name::AbstractString, constructor; group::AbstractString = "Components",
        params = CatalogParam[], code_name::AbstractString = string(nameof(constructor)),
        icon::Union{Nothing, Symbol, Makie.BezierPath} = nothing, source::Bool = false)
    # an unknown name throws
    icon isa Symbol && _icon(icon)
    return CatalogEntry(String(name), String(group), constructor,
        Union{CatalogParam, CatalogGlass}[params...], String(code_name), icon, source)
end

"""
    catalog_glasses() -> Vector{Pair{String, Any}}

The glasses that the component catalog of [`live_view`](@ref) offers for the entries with a
[`CatalogGlass`](@ref), as `name => n`, where `n(λ)` is the refractive index at the wavelength `λ`
[m] as BeamletOptics takes it, e.g. a `SellmeierEquation`. The built-in glasses are common optical
glasses and crystals with the dispersion formulas of the database refractiveindex.info: N-BK7,
fused silica, CaF2, N-SF11, N-SF10, N-SF6HT, N-SF5, N-F2, N-BAF10 and N-LAK22.

A package adds its glasses to the returned vector; views opened afterwards show them.
[`export_changes`](@ref) prints a `SellmeierEquation` and a `DiscreteRefractiveIndex` as their
constructor call and any other glass via `repr`, hence an own glass should be one of the two or a
named function.

```julia
push!(catalog_glasses(), "My glass" => SellmeierEquation(1.04, 0.23, 1.01, 0.006, 0.02, 103.6))
```
"""
function catalog_glasses end

"""
    component_catalog() -> Vector{CatalogEntry}

The catalog of components that a [`live_view`](@ref) window offers by default (its `catalog`
kwarg): the entries of BeamletOpticsGUI for the sources and the components of BeamletOptics
(sources, lenses, mirrors, beamsplitters, prisms, polarizers and the detector) and the entries that
packages added. The
catalog is the widget "Components", a window over the 3D view or, in the app layout, a section of
the left sidebar: the entry is chosen by its group and its tile,
its parameters are typed into boxes, its glass is chosen in a menu, and "Place" attaches the
component to the mouse, see "Adding and removing components" of [`live_view`](@ref).

A package with own components adds its entries (see [`CatalogEntry`](@ref)) to the returned
vector, e.g. in the `__init__` of its package extension on BeamletOpticsGUI; views opened afterwards
show them. A single view gets other entries via `live_view(...; catalog = entries)`, none with
`catalog = CatalogEntry[]`.

```julia
push!(component_catalog(), CatalogEntry("My lens", MyLens; group = "Lenses",
    params = [CatalogParam("f", 100e-3; unit = "mm", scale = 1e-3)]))
```
"""
function component_catalog end
