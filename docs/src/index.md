# BeamletOpticsGUI.jl

BeamletOpticsGUI is the interactive GUI of [BeamletOptics.jl](https://github.com/JuliaPhysics/BeamletOptics.jl)
(BMO), a package for non-sequential 3D ray and Gaussian beamlet tracing. It opens a window in which a BMO
system and its beams are drawn, the components are moved and rotated with the mouse and keyboard, and
the beams and the detector views on the cards of the detectors are updated after each change:

```julia
using GLMakie, BeamletOptics, BeamletOpticsGUI

gui = live_view(system, beam)
display(gui)
```

BeamletOpticsGUI sits on BeamletOptics and visualizes its systems. All optics is computed by
BeamletOptics; the GUI draws the components and beams with the `render!` and `live_render!` functions
of BeamletOptics (through their render handle protocol) and adds the interaction.

## Installation

BeamletOpticsGUI needs BeamletOptics 0.13 (0.13.11 or newer) and a Makie backend with a window
(GLMakie). It is installed from the General registry:

```julia
using Pkg
Pkg.add("BeamletOpticsGUI")
Pkg.add("GLMakie")
```

On a headless Linux machine, run scripts under a virtual display, e.g. `xvfb-run -a julia --project=. script.jl`.

## What is in the package

| Page | Content |
|:--|:--|
| [Live view](@ref) | `live_view`: the complete window with cards, panels, clip planes, tracing and export |
| [Kinematic controls](@ref) | `kinematic_controls!`: moving components with the mouse and keyboard |
| [View cube](@ref) | `view_cube!`: the CAD-style cube for the standard views |
| [Cards and widgets](@ref) | recipes for cards of own component types, own widgets and controls |
| [Interactive Michelson interferometer](@ref) | a complete example |
| [API](@ref) | the exported names |

## Design principles

The GUI is developed against four principles. The table states what is met today and what is not.
Features in the column "Gap" are planned and are not available.

| # | Principle | State today | Gap |
|---|---|---|---|
| P1 | The GUI sits on BeamletOptics systems and visualizes them. All physics is computed by BeamletOptics. Components can be added and removed in the GUI. One view holds several systems with several beams each. | Met: `live_view(sys1 => b1, sys1 => b2, sys2 => b3)`, solving via `solve_system!`, components of a `System` are added from a catalog and removed at runtime, see [Adding and removing components](@ref components_page). | A `Detector` added at runtime gets no detector panel. Adding and removing is not part of the undo history. Sources, extras and the objects of a `StaticSystem` are fixed when the view starts. |
| P2 | The layout is built from widgets, one per BeamletOptics type. Widgets without a type are generic windows. | Met for cards (`card_rows` per type: objects, lenses, beamsplitters, polarizers, detectors, sources, Gaussians, systems) and for generic windows (`add_panel!`, `add_controls!`, `add_tool!`). | The detector view on the card is hard-wired to `Detector`. The icon per type in the object tree is internal. |
| P3 | Any layout can be assembled from the widgets and presented to the user. | Not met: there are two fixed layouts, chosen by `layout = :compact` or `layout = :app`. | Public widget blocks (tree, inspector, dock, toolbar) and a public layout interface. |
| P4 | An extensible API lets users with own BeamletOptics types define widgets that the GUI loads. | Met for cards: `card_rows`, `card_actions`, `CardWidget`, `card_input`, `card_show!`, from a package extension on BeamletOpticsGUI, see [Cards and widgets](@ref). | No own result view per type (see P2). No public icon per type. |

The split of the GUI from BeamletOptics changed no behavior. The gaps are closed one after the other in
the order P3, P2 and P4, P1, each with its own plan.

## Relation to BeamletOptics

| | BeamletOptics | BeamletOpticsGUI |
|:--|:--|:--|
| Optics, systems, beams, detectors | yes | uses them |
| `render!`, `live_render!`, `update_render!`, `remove_render!`, `pick_object`, look and camera helpers | yes | uses them |
| `live_view`, `kinematic_controls!`, `view_cube!`, cards, panels | no | yes |

The names that moved from BeamletOptics to BeamletOpticsGUI keep their names and signatures. They were
never part of a BeamletOptics release, so there is nothing to migrate.

## AI assistants

The package ships an agent skill for the GUI, which builds on the skill of BeamletOptics for the
optics. Install the version that matches the installed package with

```julia
using BeamletOpticsGUI
BeamletOpticsGUI.install_agent_skill()   # -> ./.claude/skills/beamletopticsgui
```
