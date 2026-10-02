# BeamletOpticsGUI.jl: developer instructions for coding agents

The interactive GUI of [BeamletOptics.jl](https://github.com/JuliaPhysics/BeamletOptics.jl) (BMO):
`live_view` and the tools around it (kinematic controls, view cube, cards, custom panels, controls
and tools), built on Makie. BMO does the physics and draws the components; this package arranges
them into an interactive window.

This file is for **developing** the GUI. Guidance for **using** it lives in the agent skill
[skills/beamletopticsgui/](skills/beamletopticsgui/SKILL.md). BMO's own developer instructions
(`AGENTS.md` in the BMO repository) apply to anything that touches optics, kinematics or rendering.

## Design principles

Evaluate every change against these principles. The "Gap" column is the planned work; do not
describe it as available in docs or the skill.

| # | Principle | Gap in 0.2 |
|---|---|---|
| P1 | The GUI sits on BeamletOptics systems and visualizes them. All physics is computed by BeamletOptics. Components can be added to and removed from the scene in the GUI. One view holds several systems with several beams each. | adding and removing is not part of the undo history; sources and `StaticSystem`s can not be changed; the glasses of the catalog (`catalog_glasses`) are data of the GUI until BeamletOptics has a glass catalog |
| P2 | The layout is built from widgets, one per BeamletOptics type (e.g. the card of a lens, of a detector, of a system). Widgets without a type are generic windows (`add_panel!`, `add_controls!`, `add_tool!`). | the pages of a card and its view ("Results") are chosen per type by internal traits (`_has_page`, `_has_view`), only `Detector` has a view; tree icons per type are internal |
| P3 | Any layout can be assembled from the widgets and presented to the user. Layouts are composed in code from public widget blocks; `:compact` and `:app` are two such compositions. | the layout interface `AbstractLiveLayout` is internal, the widgets have no public constructors |
| P4 | An extensible API lets users with own BeamletOptics types define widgets that the GUI loads (`card_rows`, `card_actions`, `CardWidget`, `card_input`, `card_show!`; a component package adds them in a package extension on BeamletOpticsGUI). | own views (the page "Results") and icons per type |

**Rules that follow from them:**

- **The GUI draws components only via BMO.** Objects, systems and beams are drawn with
  `live_render!` and moved with `update_render!`; the GUI never calls `lines!`, `mesh!`,
  `surface!` etc. for a component. Its own plots are overlays only: source markers and clip planes
  (via `live_render!(draw, ax, x)`), measurements, the view cube, panels, icons.
- **The GUI prefers declared BMO API**: exported names, the render handle protocol
  (`AbstractObjectRenderHandle`, `AbstractSystemRenderHandle`, `AbstractBeamRenderHandle`,
  `rendered`, `render_plots`, `render_children`, `render_parent`, `render_settings`,
  `pickable_plots`, `look_colors`, `push!`/`delete!` of system handles) and the `public` developer
  API (`is_static`, `hit_count`, `wavelength`, `min_num_rays`, `ProgressSink`, `PROGRESS_SINK`,
  `progress_state`, `is_cancelled`, the sampling types). It also uses some internal BMO names
  without underscore (the abstract types, the kinematic and shape traits, getters such as
  `intersection`, `hits` or `objects`); these may change with any BMO release, which the compat
  entry on the BMO version pins. Never `BMO._x` names in `src/`, never
  `Base.get_extension(BeamletOptics, ...)`. If something is missing, add it to BMO first.
- **Physics stays in BMO.** Solving is `solve_system!`; the GUI never computes rays, intersections
  or detector fields itself.
- **Per-type behavior is dispatch**, never `isa` chains: a new BMO type gets its card via a
  `card_rows` method, not a branch in the card code.
- **Layout-independent code does not know the layouts.** Shared logic calls the hooks of
  `AbstractLiveLayout`; a new widget must not depend on `CompactLayout` or `AppLayout` (P3).

## Code map

- `src/BeamletOpticsGUI.jl`: module, exports, include order (order matters).
- `src/API.jl`: the docstrings of the exported functions, `CardWidget`, `CardRow`.
- `src/LiveHandles.jl`: `LiveSystemHandle`, the GUI's system handle on BMO's render handle
  protocol (combines systems, source markers, clip planes and extras), and small pose helpers.
- `src/LiveView.jl`: `LiveView{L}` and its state structs (`_TraceState`, `_ClipState`,
  `_MeasureState`, `_CameraState`, `_CardState`, `_ObjectState`, `_DetectorStates`, `_LayoutWidgets`), `live_view`,
  and the docstring of `AbstractLiveLayout` (the layout interface).
- `src/LiveLayout.jl`: built-in tools (`_BUILTIN_TOOLS`), themes, the collapsible parts of the
  layouts (`_LayoutPart`, `_set_shown!`: the only way to collapse a part of the figure layout) and
  the spectator mode, which hides the UI (`_on_spectator!`, `_set_spectator_ui!`). `src/LiveCompact.jl`,
  `src/LiveApp.jl`, `src/LiveAppTree.jl`, `src/LiveDock.jl`, `src/LiveInspector.jl`: the two layouts.
- `src/LiveCard.jl`, `src/LiveCards.jl`, `src/LiveCardRows.jl`: cards and the card API.
  `src/LiveCardPages.jl`: the pages of a card per type ("Pose", "Results", "Properties").
- `src/LiveDetectorView.jl`: the view of a detector on the page "Results" of its card: the kinds
  of views per type of hits (spot diagram, PSF, intensity), their results and metrics, and the
  widget (thumbnail, zoomable plot). `src/LiveDetectors.jl`: the state of the view per detector,
  its computation only while it is shown, and the `detectors` kwarg.
- `src/LiveTrace.jl`, `src/LiveProgress.jl`: solving, progress window. `src/LiveClip.jl`, `src/LiveMeasure.jl`, `src/LiveCamera.jl`,
  `src/LiveSelection.jl`, `src/LiveExport.jl`, `src/LiveExtras.jl`, `src/LiveInfo.jl`: features.
- `src/LiveSelectionCard.jl`: the small menu of a click on a group ("Select", "More") and the selection card of groups (browsing their parts level by level).
  `src/LiveHighlight.jl`: the highlight while browsing (group see-through, boxes of the parts).
  `src/LiveBackground.jl`: the background card. `src/LiveOverlay.jl`: the overlay of the compact layout. `src/LiveHelp.jl`: the help of both layouts (pill, chips of mode and step, help card), built from the entries of `_help_sections` in `src/LiveInteraction.jl`.
- `src/LiveInteraction.jl`: `kinematic_controls!`. `src/ViewCube.jl`: `view_cube!`.
- `src/LiveCustom.jl`, `src/LiveWidgets.jl`: `add_panel!`, `add_controls!`, `add_tool!`,
  `retrace!`, own widgets.
- `src/LiveComponents.jl`: `add_component!`, `remove_component!` (components added to and removed
  from a `System` at runtime). `src/LiveCatalog.jl`: the component catalog (`CatalogEntry`,
  `component_catalog`) and its widgets (groups, tiles, form), `src/LiveCatalogWindow.jl`: its
  window over the 3D view, `src/LiveCatalogEntries.jl`: the entries of the components of
  BeamletOptics, `src/LiveGlasses.jl`: the glasses (`catalog_glasses`, `CatalogGlass`).
  `src/LivePlacement.jl`: placing a new component with the mouse, with snapping onto beams.
- `src/LiveMarkers.jl`: clip planes and source markers.
- `docs/`: Documenter site. `skills/beamletopticsgui/`: the agent skill.

## Running Julia and tests

- Julia ≥ 1.12. The repository is a Pkg workspace (`test`, `docs`). BeamletOptics comes from
  the General registry. To work against a local BMO checkout, add `BeamletOptics = {path = "..."}`
  under `[sources]` in `Project.toml`, `test/Project.toml` and `docs/Project.toml` locally and do
  not commit that change. A feature that needs unreleased BMO code waits for the BMO release and
  raises the compat entry.
- GLMakie is the backend of the tests; on headless Linux run under `xvfb-run -a`.
- Single test module: `julia --project=test -e 'using Pkg; Pkg.instantiate()'` once, then
  `julia --project=test test/<file>.jl`.
- Full suite: `julia --project=test test/runtests.jl`.
- New test files are `module TestXyz ... end` and are included in `test/runtests.jl`.
- Docs: `julia --project=docs docs/make.jl`.

## Agent skill

[skills/beamletopticsgui/](skills/beamletopticsgui/) ships with every release and must describe
exactly that release. A patch that changes public behavior (exports, keyword arguments or their
defaults, the card API) updates the skill in the same patch. `test/TestAgentSkill.jl` checks the
export table in `API.md` and the version field in `SKILL.md` against the package.

## Docstrings and style

As in BMO: pages embed docstrings instead of repeating them, docstrings are self-sufficient in the
REPL, the SciML style guide is the baseline, and new functionality comes with tests and docs.
