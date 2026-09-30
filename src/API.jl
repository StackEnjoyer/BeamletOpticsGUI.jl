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

Opens a complete interactive window for one or several pairs of `system` and `beam`: a 3D view in
which all components can be moved via [`kinematic_controls!`](@ref), one panel per `Detector`
(spot diagram or intensity), a status line and optional sliders. After each change, all detectors
are emptied, all systems are solved again and the beams and panels are updated. Returns a
`LiveView`, which can be shown via `display`.

The detector panels show metrics (centroid, RMS or 1/e² radius, power), optionally on a
logarithmic color scale with a history and profiles. A click on a beam shows its position, path
length and, for Gaussian beamlets, its radius and curvature, the "measure" toggle measures
distances and angles between components and beams. The key `g` zooms to the selection, "home",
the "views" menu and "save view" set and store camera views. While moving, beam groups are solved
only for their rendered beams (`preview = true`), the full group once the movement pauses.

Main keyword arguments: `detectors` (`:auto`, a vector of `pd`, `pd => mode` or
`pd => (mode, kwargs)`, or `[]`, with the panel options `colorscale`, `colorrange`, `history`
and `profiles`), `on_change = (gui, obj) -> nothing` (called after full solves),
`sliders = ["label" => (range, callback)]`, `system_kwargs`, `beam_kwargs`, `preview = true`,
`views = ["name" => (eye, lookat, up)]`, `lighting = :studio` (see `BeamletOptics.studio_lighting!`),
`edges` and `size`. `extras = [obj => render_kwargs, ...]` adds objects that are rendered,
selected, moved and hidden like the components, but never traced, e.g. a housing from an STL file
(`MeshDummy`); the card of such mechanics has an opacity slider. `background_card = obj` (or
`gui -> obj`, `nothing` for none) shows the card of an object without a place in the scene, e.g.
an environment, after a click on the empty background while nothing is selected; its
[`card_rows`](@ref) get `obj` itself. `layout = :app` arranges the window like an application, with a toolbar,
collapsible sidebars (object tree with selection and visibility, sliders, properties of the
selection), an analysis dock with a tab per detector panel (only the panel of the active tab is
computed after a solve) and a status bar, in the colors of `theme = :light` or `:dark`; the default
`layout = :compact` fills the window with the 3D view, places the panels on its right and shows the
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
layout: with `layout = :compact` below the detector panels next to the 3D view (in a new column if
there are none), with the title above it; with `layout = :app` as a new tab of the analysis dock,
behind the tabs that exist (the active tab stays active unless `select = true`).

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
`layout = :app`, an icon button (or toggle) in the toolbar, before "Help", with the `icon` and the
`tooltip`; with `layout = :compact`, an entry (icon and `name`) of the tool rail opened by the
button "⋯".

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
sources add the toggles of [`beam_card_rows`](@ref), a source whose rays can be regenerated (see
`BeamletOptics.set_num_rays!`) a slider for the number of rays, a `Detector`
the mode and the color scale of its detector panel, mechanics (`NonInteractableObject`, e.g. a
`MeshDummy`, and `IntersectableObject`) a slider for their opacity. The card of a system
(`AbstractSystem`, shown after a click on its entry in the component menu or the object tree)
shows the number of its objects, the number of rays of its sources that are on and the duration of
the last solve. Add a method for an own type to show its properties or controls on its card, e.g.

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
(or "show" for a hidden object), for clip planes "flip" and "remove".
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
a `Slider` (the closest step of its range) and the state of a `Toggle`. The default for any other
type shows nothing.

Showing a value is not an input: the card ignores the updates of [`card_input`](@ref) while it
shows values, and a method should not change the observable of `card_input` if it can avoid it,
since outside of a card, e.g. in [`add_controls!`](@ref), nothing ignores them. A method should
also keep what the user is typing: the method for a `Textbox` does not change a focused box,
unless it is called with `force = true`, which the card does after an input was applied.
"""
function card_show! end
