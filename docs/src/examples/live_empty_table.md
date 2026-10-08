```@setup live_empty_table
# Runs the script with an invisible GLMakie window and saves the figures of this page
dir = joinpath(@__DIR__, "..", "assets", "examples")

include(joinpath(dir, "live_empty_table_showcase.jl"))
```

# Building a setup on an empty table

This example starts without a setup: [`live_view`](@ref) opens an empty `System()` as an application window, in which the sources and components are placed from the catalog. The setup that was built in the window is then written as a script, which runs without the window.

![Empty table in the app layout](live_empty_table.png)

The full script can be found [here](https://github.com/StackEnjoyer/BeamletOpticsGUI.jl/blob/main/docs/src/assets/examples/live_empty_table.jl). Running it from the REPL opens the interactive window.

## Opening the empty table

A system without components and a view without a source are enough:

```julia
using BeamletOptics, BeamletOpticsGUI, GLMakie

system = System()

gui = live_view(system; layout = :app, size = (1600, 900), table = true, snap = true,
    labels = Dict(system => "Beam expander"))
display(gui)
```

`layout = :app` arranges the window like an application: the toolbar at the top, the object tree and the catalog "Components" in the left sidebar, the inspector with the card of the selection in the right one and the status bar at the bottom. The edges of the sidebars are dragged with the mouse to resize them. `table = true` shows an optical table with holes at a distance of 25 mm, and with `snap = true`, a component that is placed or dragged with the mouse snaps onto the holes and onto the beams, see [Aligning on the table and to the beams](@ref). The entry of `labels` names the system in the object tree and in the line "into" of the catalog.

## Building the setup in the window

The setup of this page is a beam expander: two lenses at a distance of the sum of their focal lengths, a mirror that folds the beam, and a detector.

1. **The source.** The icons at the top of the catalog select a group, "Sources" at first, the tiles below it the entry. The form takes its numbers, e.g. the wavelength and the diameter of a collimated source. "Place" puts the first source of an empty view at the origin, pointing along +y.
2. **The components.** A lens of the group "Lenses" is attached to the mouse after "Place" and moves in the plane of the table, at the height of the beam. A click drops it; near the beam it snaps onto it. Mirrors and the detector are placed the same way.
3. **The poses.** A click selects a component, a drag moves it. The key `m` switches to the rotate mode, e.g. to turn the mirror by 45°, and the boxes of the page "Pose" of its card take exact values. "onto beam" and "face beam" on the card align a component to the nearest beam.
4. **The result.** After each change the system is solved again. A click on the detector shows its card in the inspector, which opens on the page "Results" with the spot diagram.

`Ctrl+Z` takes a step back, `Delete` removes the selected component, and the page "Edit" of a card builds a component from the catalog again with other values, e.g. a lens with other radii. See [Adding and removing components](@ref components_page) for the catalog and the placement.

![Beam expander on the table](live_empty_table_setup.png)

Further systems are added with the tool "System" of the toolbar, e.g. a receiver that shares the mirror with this system, see [Several systems](@ref).

## The same from code

The figure above is made by a [script](https://github.com/StackEnjoyer/BeamletOpticsGUI.jl/blob/main/docs/src/assets/examples/live_empty_table_showcase.jl) that does what the catalog does. [`add_component!`](@ref) adds a source or a component to the system and solves it again. With `code`, the constructor call as Julia code, the view knows how the object was built, like for an entry of the catalog:

```julia
add(obj, code, label) = add_component!(gui, obj; code, label, select = false)

laser = add(CollimatedSource([0.0, 0, 0], [0.0, 1, 0], 5e-3, 632.8e-9),
    "CollimatedSource([0.0, 0, 0], [0.0, 1, 0], 5e-3, 632.8e-9)", "laser")
lens1 = add(ThinLens(50e-3, -50e-3, 12.7e-3, 1.5), "ThinLens(50e-3, -50e-3, 12.7e-3, 1.5)", "lens1")
lens2 = add(ThinLens(100e-3, -100e-3, 25.4e-3, 1.5), "ThinLens(100e-3, -100e-3, 25.4e-3, 1.5)", "lens2")
mirror = add(RoundPlanoMirror(25.4e-3, 6e-3), "RoundPlanoMirror(25.4e-3, 6e-3)", "mirror")
detector = add(Detector(15e-3), "Detector(15e-3)", "detector")
```

Every object is added as its constructor builds it and moved afterwards, with the verbs of BeamletOptics that take the window as first argument, see [Scripting the live view](@ref scripting_live_view). The focal lengths of the lenses are 50 mm and 100 mm, hence they are 150 mm apart and widen the beam by a factor of 2:

```julia
translate_to3d!(gui, lens1, [0, 50e-3, 0])
translate_to3d!(gui, lens2, [0, 200e-3, 0])
translate_to3d!(gui, mirror, [0, 275e-3, 0])
rotate3d!(gui, mirror, [0, 0, 1], deg2rad(45))
translate_to3d!(gui, detector, [100e-3, 275e-3, 0])
rotate3d!(gui, detector, [0, 0, 1], deg2rad(90))

select!(gui, detector)
wait_solve(gui)
```

## The setup as a script

The tool "Script" of the toolbar and [`export_script`](@ref) write the setup as a script: the constructors and poses of the components and sources, the system, the `solve_system!` call and the `live_view` call. A label that is a valid name becomes the name of the variable. For the setup above:

```@example live_empty_table
export_script(gui);
nothing # hide
```

The first part runs with BeamletOptics alone, e.g. for an analysis without a window. A view that was built with the catalog gives the same kind of script; an object that the view started with is a comment in it, since its constructor is not known.
