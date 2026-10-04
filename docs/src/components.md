# [Adding and removing components](@id components_page)

The components of a `System` in [`live_view`](@ref) and its sources can be added and removed at
runtime, from the window and from code, e.g. to build a setup from an empty `System()`. This page shows
the example from code, describes the catalog and how to extend it with own components. The
user-facing description of the window is in the section "Adding and removing components" of
[`live_view`](@ref).

All code blocks assume `using GLMakie, BeamletOptics, BeamletOpticsGUI`, need a `Makie` backend with
a window (`GLMakie`) and are therefore not run when the docs are built.

## From code

An empty system and a source are enough to start. The component is placed before it is added, e.g.
via `translate_to3d!`, and [`add_component!`](@ref) pushes it to the system, renders it, registers it
with the controls and solves the systems again:

```julia
beam = Beam([0.0, 0, 0], [0.0, 1, 0])
gui = live_view(System() => beam)

lens = ThinLens(50e-3, -50e-3, 25.4e-3, 1.5)
translate_to3d!(lens, [0, 0.1, 0])
add_component!(gui, lens; label = "lens")

remove_component!(gui, lens)
```

All beams that are paired with the target system are traced through the new component. With several
systems, the keyword `system` of [`add_component!`](@ref) selects the target.

Sources are added and removed with the same two functions. A view may start without one, as an
empty table, and every source can be removed, also the last one:

```julia
gui = live_view(System())

laser = Beam([0.0, 0, 0], [0.0, 1, 0], 632.8e-9)
add_component!(gui, laser; label = "laser")
add_component!(gui, lens)

remove_component!(gui, laser)
```

A source is traced through one system of the view (keyword `system`, also a `StaticSystem`) and
gets a marker, with which it is selected and moved like the sources the view started with. It is
drawn in the color of its wavelength: violet to red between 380 nm and 780 nm, a dark violet for
ultraviolet and a dark red for infrared light, like the sources that the view started with. The
keyword `beam_kwargs` takes the keywords of its rendering, e.g. `(; render_every = 10)` or another
`color`.

## The catalog and the placement

The catalog "Components" is a widget like the cards: it can be pinned, minimized and, in the app
layout, docked.

- In the compact layout it is a window over the 3D view, closed at first. The key `Insert` opens
  it with its top left corner at the mouse, the toggle "Components" of the tool rail opens and
  closes it. A drag at its head moves it.
- In the app layout it is docked in the section "Components" of the left sidebar, below the object
  tree, where its entries are icons. The buttons at the title of the section move it into its
  window over the 3D view and minimize it; the dock button of the window brings it back. `Insert`
  shows the window at the mouse.

A window that is not pinned is a popup: it closes (in the app layout: it is docked again) as soon
as the component was dropped. The pin in its head keeps it open at its place, e.g. to place
several components; the chevron minimizes it to its head.

The built-in entries are the sources of BeamletOptics and all its components whose constructor
takes numbers and glasses:

| group | entries |
|:--|:--|
| Sources | Beam, Gaussian beamlet, Collimated source, Uniform disc source, Point source, Uniform point source, Astigmatic Gaussian beamlet |
| Lenses | Thin lens, Singlet (`SphericalLens`), Doublet, Triplet |
| Mirrors | Round mirror, Square mirror, Rectangular mirror, Thin mirror (`SquarePlanoMirror2D`), Prism mirror, Retroreflector |
| Curved mirrors | Spherical, Parabolic, Conic, Ellipsoidal and Hyperbolic mirror, the last four also off-axis |
| Beamsplitters | Thin beamsplitter, Round thin beamsplitter, Plate beamsplitter, Round plate beamsplitter, Cube beamsplitter, Compensator plate |
| Prisms | Right-angle prism |
| Polarizers | Polarization filter, Round filter, Linear polarizer |
| Detectors | Detector |

The icons at the top of the catalog select the group, the tiles below the entry. The boxes of the
form take its numbers; the other arguments of the constructor keep their defaults, e.g. the
`thickness` and the `hole_diameter` of a curved mirror. An entry with a refractive index has a menu
of glasses instead of a number: N-BK7, fused silica, CaF2, N-SF11, N-SF10, N-SF6HT, N-SF5, N-F2,
N-BAF10 and N-LAK22 with their dispersion (see [`catalog_glasses`](@ref)), and "constant" with a box
for a constant refractive index. The line "into" at the top names the system that gets the
component or source: the system of the selected or inspected object, else the first one. In a view
with several systems it is a menu, which chooses another system; the choice holds until another
object is selected, which sets the system again. A source can be traced through any system, a
component is added to a `System` only, hence the menu lists the systems that can get the chosen
entry. "Place" attaches the component
to the mouse, which moves it in the plane of the table (perpendicular to the rotation axis) through
the first source of its system: beside the beams it lies at the height of the beam, also in an
oblique view; seen from the front or the side, it moves in the plane of the view at the depth of
the source. The first component or source of an empty view is placed at the origin, where the
camera of an empty view looks: it does not follow the mouse. A
left click drops it, `Esc` cancels. With the snapping onto beams switched on (the chip "Snap" or
the key `Tab`, also while placing; off by default, see the keyword `snap`), it snaps onto a
rendered beam within 12 px; of a beam group only onto its central beam, of a Gaussian beamlet onto
its chief ray. With "position + rotation" its optical axis also turns along the beam. The component that is being
placed is not traced until it is dropped. See the section "Adding and removing components" of
[`live_view`](@ref) for the details of the placement.

A source of the group "Sources" is placed the same way: its marker follows the mouse, a click
drops it, and its beam is traced through the system that the catalog names as "into". It points
along +y, as it is constructed; turn it with the controls afterwards (rotate mode, `m`). A source
does not snap onto beams. Its form takes the wavelength [nm], the diameter or the half angle of the
cone [°], and the number of rings or rays. If the markers of the sources are hidden, placing a
source shows them.

The button "remove" at the end of the page "Pose" of the card of a component or a source and the
key `Delete` remove it again. The added and removed
components are part of the code of [`export_changes`](@ref), which writes a glass as its
`SellmeierEquation` and a constant refractive index as `λ -> n`, such that the code runs without
BeamletOpticsGUI. An added source is its constructor at the origin along +y, the `rotate3d!` and
`translate_to3d!` to its pose and the `solve_system!` that traces it; a removed source that the
view started with is a comment.

## Aligning on the table and to the beams

The toggle "Table" among the tools shows an optical table below the setup, like the keyword
`table = true`: a grid of holes at a distance of 25 mm, perpendicular to the rotation axis of the
controls, at the lowest point of the components. While it is shown, a component or source that is
dragged or placed with the mouse sits on the hole closest to it, at its own height, and in the
rotate mode its optical axis snaps to the multiples of 45° to the rows of the holes. With the
snapping onto beams switched on (`Tab`), a beam within reach comes first, such that a component is
put on the grid beside the beams and on the beam near it. The table grows with the setup.

```julia
gui = live_view(System(); table = true)
# an imperial table 50 mm below the beams, shown without snapping
gui = live_view(system, beam; table = (; pitch = 25.4e-3, height = -50e-3, snap = false))
```

The card of a component aligns it to the nearest beam, i.e. the central beam of a source as far as
it does not depend on the component: "onto beam" moves it to the point of the beam closest to it,
"face beam" turns its optical axis along the beam, e.g. a lens straight in the beam or a mirror
that sends it back. The card of a source has "aim": a dashed line then follows the mouse, and a
click turns the source such that it points at the center of the component under the mouse, or at
the point of the plane of the mouse elsewhere, which is a hole of the table while it is shown.
`Esc` cancels it. Each of these is one step of the undo history.

## Changing, undoing and the whole script

A component or source that was placed from the catalog has the page "Edit" on its card: the form
of its entry with the values it was built with. "Apply", or Enter in a box, builds it again with the
new values in the same pose, in the same system and under the same label, e.g. a lens with other
radii or a source with another wavelength; a source that is drawn in the color of its wavelength
follows the new wavelength. An invalid input changes nothing and is reported in the status line.
Objects that the view started with have no page "Edit": the view does not know how they were
constructed.

`Ctrl+C` copies the selected component or source from the catalog, `Ctrl+V` builds it again with
the same values and attaches it to the mouse like "Place": in the orientation of the original, a
source also with the look of its beam (color, opacity, line width). A click drops it into the system
of the selection, else the first one, `Esc` cancels, and each further `Ctrl+V` pastes another one,
also in another window. Objects that the view started with can not be copied, for the same reason;
the status line says so.

Adding, removing and changing are part of the undo history of the controls, together with the
moves: `Ctrl+Z` takes the last step back, `Ctrl+Y` (or `Ctrl+Shift+Z`) does it again, e.g. a removed
component comes back in its pose, with its label. How a source is drawn (color, opacity, line
width, on and off) is not part of the history.

The tool "Script" next to "Export" prints the whole setup as a script and copies it to the
clipboard, like [`export_script`](@ref): the constructors and poses of all components and sources,
the systems, the `solve_system!` calls and the `live_view` call. A view that was built from an
empty `System()` with the catalog gives a script that runs as it is. An object that the view
started with is a comment with its type and its pose, since its constructor is not known; fill it
in there.

```julia
gui = live_view(System())
# place sources and components from the catalog, then
code = export_script(gui)
```

Limits of this version:

- A `StaticSystem` can not be changed: a view without a `System` only offers the sources of the
  catalog. Objects inside a group can not be added or removed, remove the group instead.
- Only components and sources from the catalog can be changed on the page "Edit" and are written
  with their constructors by [`export_script`](@ref).
- The script does not contain how the sources are drawn, the extras, the clip planes and the other
  keywords of `live_view`.

## Own catalog entries

A [`CatalogEntry`](@ref) is data: a name, a constructor and the parameters that are passed to it,
numbers ([`CatalogParam`](@ref)) and glasses ([`CatalogGlass`](@ref)). The same entry builds the
object and the constructor call in the code of [`export_changes`](@ref), hence the constructor
should be a function or type that a script can call by name. Its `group` is one of the built-in
groups or a new one; its `icon` is the name of an icon of the live view, as for
[`add_tool!`](@ref), or an own `Makie.BezierPath`, and the icon of its group without one. An entry
with `source = true` is a source: its constructor gets the position `[0, 0, 0]` and the direction
`[0, 1, 0]` before the values of its parameters and returns a beam or a beam group; a
`CatalogParam` with `integer = true` passes an `Int`, e.g. a number of rays, and one with `presets`
(`["532 nm" => 532e-9, ...]`) has a menu of these values next to its box, like the laser lines at
the wavelength of the built-in sources. A package
with own components adds its entries to [`component_catalog`](@ref) and its glasses to
[`catalog_glasses`](@ref), e.g. in the `__init__` of its package extension on BeamletOpticsGUI (see
[Cards and widgets](@ref)); a single view gets other entries via the keyword `catalog`:

```julia
# `MyLens(f, n)` builds the component, `f` is shown in mm, `n` is chosen among the glasses
push!(component_catalog(), CatalogEntry("My lens", MyLens; group = "Lenses", icon = :singlet,
    params = [CatalogParam("f", 100e-3; unit = "mm", scale = 1e-3), CatalogGlass()]))

# an own glass in the menu of every entry with a glass
push!(catalog_glasses(), "My glass" => SellmeierEquation(1.04, 0.23, 1.01, 0.006, 0.02, 103.6))

# only these entries in one view; `catalog = CatalogEntry[]` shows no catalog
entries = [CatalogEntry("Round mirror", RoundPlanoMirror; group = "Mirrors", params = [
    CatalogParam("diameter", 25.4e-3; unit = "mm", scale = 1e-3),
    CatalogParam("thickness", 6e-3; unit = "mm", scale = 1e-3)])]
gui = live_view(System() => beam; catalog = entries)
```

## Reference

```@docs; canonical=false
add_component!
remove_component!
CatalogEntry
CatalogParam
CatalogGlass
component_catalog
catalog_glasses
export_script
```
