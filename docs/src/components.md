# [Adding and removing components](@id components_page)

The components of a `System` in [`live_view`](@ref) can be added and removed at runtime, from the
window and from code, e.g. to build a setup from an empty `System()` and a source. This page shows
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

## The catalog and the placement

The catalog "Components" is an entry of the tool rail in the compact layout and a section of the left
sidebar in the app layout, i.e. where [`add_controls!`](@ref) places its widgets. The built-in
entries are

| group | entries |
|:--|:--|
| Lenses | Thin lens, Spherical lens |
| Mirrors | Round mirror, Square mirror |
| Beamsplitters | Thin beamsplitter, Cube beamsplitter |
| Prisms | Right-angle prism |
| Detectors | Detector |

A menu selects the entry, the boxes below take its parameters, and "Place" attaches the component
to the mouse. A left click drops it, `Esc` cancels. Within 12 px of a rendered beam, it snaps onto
the beam; of a beam group only onto its central beam, of a Gaussian beamlet onto its chief ray. The
component that is being placed is not traced until it is dropped. See the section
"Adding and removing components" of [`live_view`](@ref) for the details of the placement.

The button "remove" below the rows of the card of a component and the key `Delete` remove it again. The added and removed
components are part of the code of [`export_changes`](@ref).

Limits of this version:

- A `Detector` that is added at runtime is traced and has a card, but gets no detector panel.
- Adding and removing is not part of the undo history.
- A `StaticSystem` can not be changed. Sources and objects inside a group can not be added or
  removed, remove the group instead.

## Own catalog entries

A [`CatalogEntry`](@ref) is data: a name, a constructor and the [`CatalogParam`](@ref)s that are
passed to it. The same entry builds the object and the constructor call in the code of
[`export_changes`](@ref), hence the constructor should be a function or type that a script can call
by name. A package with own components adds its entries to [`component_catalog`](@ref), e.g. in the
`__init__` of its package extension on BeamletOpticsGUI (see [Cards and widgets](@ref)); a single
view gets other entries via the keyword `catalog`:

```julia
# `MyLens(f)` builds the component, `f` is shown in mm
push!(component_catalog(), CatalogEntry("My lens", MyLens; group = "Lenses",
    params = [CatalogParam("f", 100e-3; unit = "mm", scale = 1e-3)]))

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
component_catalog
```
