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
ultraviolet and a dark red for infrared light. The sources that the view started with keep the
color of the layout. The keyword `beam_kwargs` takes the keywords of its rendering, e.g.
`(; render_every = 10)` or another `color`.

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
for a constant refractive index. "Place" attaches the component
to the mouse, which moves it in the plane of the view through the first source of its system: seen
from above it lies at the height of the beam, seen from the front at the depth of the source. A
left click drops it, `Esc` cancels. Within 12 px of a rendered beam, it snaps onto the beam; of a beam group
only onto its central beam, of a Gaussian beamlet onto its chief ray. The component that is being
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

Limits of this version:

- Adding and removing is not part of the undo history.
- A `StaticSystem` can not be changed: a view without a `System` only offers the sources of the
  catalog. Objects inside a group can not be added or removed, remove the group instead.
- The parameters of a source are fixed once it is placed, except its number of rays, which the
  slider "rays" of its card changes. To change e.g. its wavelength, remove it and place a new one.

## Own catalog entries

A [`CatalogEntry`](@ref) is data: a name, a constructor and the parameters that are passed to it,
numbers ([`CatalogParam`](@ref)) and glasses ([`CatalogGlass`](@ref)). The same entry builds the
object and the constructor call in the code of [`export_changes`](@ref), hence the constructor
should be a function or type that a script can call by name. Its `group` is one of the built-in
groups or a new one; its `icon` is the name of an icon of the live view, as for
[`add_tool!`](@ref), or an own `Makie.BezierPath`, and the icon of its group without one. An entry
with `source = true` is a source: its constructor gets the position `[0, 0, 0]` and the direction
`[0, 1, 0]` before the values of its parameters and returns a beam or a beam group; a
`CatalogParam` with `integer = true` passes an `Int`, e.g. a number of rays. A package
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
```
