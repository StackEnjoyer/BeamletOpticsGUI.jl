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

| # | Principle | Gap in 0.3 |
|---|---|---|
| P1 | The GUI sits on BeamletOptics systems and visualizes them. All physics is computed by BeamletOptics. Components, sources and systems can be added to and removed from the scene in the GUI. One view holds several systems with several beams each; an object belongs to any number of systems or to none and is drawn once, a source to at most one, and each system is traced on its own. | `StaticSystem`s can not be changed; only components and sources from the catalog can be changed afterwards (page "Edit"); `export_script` writes the constructors of those and of the objects added with `code` (`add_component!`), since the constructor of an object from the user's script is not known otherwise; the glasses of the catalog (`catalog_glasses`) are data of the GUI until BeamletOptics has a glass catalog |
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
- **A solve in the background owns the beams and detectors**, from its start until its result is
  shown or it is cancelled. Nothing else changes or reads them meanwhile: changes of objects go
  through `_change!`, which cancels the solve first, and code that reads the beams or the hits
  returns early or shows a placeholder while `_running(gui)` or `_tracing(gui)` (e.g.
  `_inspect_beam`, `_beam_text` of the cards). This also holds while the task that started the
  solve waits for it (`_run!`): the render loop of the window runs meanwhile if a script started it.
- **Per-type behavior is dispatch**, never `isa` chains: a new BMO type gets its card via a
  `card_rows` method, not a branch in the card code.
- **Layout-independent code does not know the layouts.** Shared logic calls the hooks of
  `AbstractLiveLayout`; a new widget must not depend on `CompactLayout` or `AppLayout` (P3).

## Code map

- `src/BeamletOpticsGUI.jl`: module, exports, include order (order matters).
- `src/API.jl`: the docstrings of the exported functions, `CardWidget`, `CardRow`.
- `src/LiveHandles.jl`: `LiveSystemHandle`, the GUI's system handle on BMO's render handle
  protocol (combines systems, source markers, clip planes and extras), the pool (`_render_pool`,
  `gui.pool`: the one handle that renders every object of the view once, also an object of several
  systems; the `LiveSystemHandle` of a system holds the object handles of its members, which are the
  pool's, see `_render_members!`), and small pose helpers.
- `src/LiveView.jl`: `LiveView{L}` and its state structs (`_TraceState`, `_ClipState`,
  `_MeasureState`, `_CameraState`, `_CardState`, `_ObjectState`, `_DetectorStates`, `_LayoutWidgets`), `live_view`,
  and the docstring of `AbstractLiveLayout` (the layout interface).
- `src/LiveScroll.jl`: scroll areas (`_ScrollArea`), e.g. the sidebars of the app layout: Makie has
  no scroll container and GLMakie does not clip, so the content lies behind the other parts of the
  window, which cover what is scrolled out, and gets the mouse only inside its region.
- `src/LiveSplitter.jl`: splitters (`_Splitter`, `_Splitters`), e.g. of the sidebars and the dock of
  the app layout: the mouse drags the edge of a `_LayoutPart` to resize it, a double click restores
  the size of the start. An invisible strip around the edge instead of a column or row of the layout.
- `src/LiveLayout.jl`: built-in tools (`_BUILTIN_TOOLS`), themes, the collapsible parts of the
  layouts (`_LayoutPart`, `_set_shown!`: the only way to collapse a part of the figure layout) and
  the spectator mode, which hides the UI (`_on_spectator!`, `_set_spectator_ui!`). `src/LiveCompact.jl`,
  `src/LiveApp.jl`, `src/LiveAppTree.jl`, `src/LiveDock.jl`, `src/LiveInspector.jl`: the two layouts.
- `src/LiveCard.jl`, `src/LiveCards.jl`, `src/LiveCardRows.jl`: cards and the card API.
  `src/LiveCardPages.jl`: the pages of a card per type ("Pose", "Color", "Results", "Properties").
  `src/LiveBeamColor.jl`: the page "Color" of the sources (color, opacity and line width of their
  beams). `src/LiveEdit.jl`: the page "Edit" of the components and sources from the catalog, which
  builds them again with other parameters. `src/LiveCopy.jl`: `Ctrl+C` and `Ctrl+V`, which build
  one of them again as it is and place it with the mouse. Adding, removing and changing are actions of the undo
  history of the controls (`_push_action!` in `src/LiveInteraction.jl`, `_record_added!` in
  `src/LiveComponents.jl`).
- `src/LiveDetectorView.jl`: the view of a detector on the page "Results" of its card: the kinds
  of views per type of hits (spot diagram, PSF, intensity), their results and metrics, and the
  widget (thumbnail, zoomable plot). `src/LiveDetectors.jl`: the state of the view per detector,
  its computation only while it is shown, and the `detectors` kwarg.
- `src/LiveTrace.jl`, `src/LiveProgress.jl`: solving, progress window. `src/LiveSystemTrace.jl`:
  tracing per system (`_system_auto`, `_set_system_auto!`, `_trace_system!`, `_trace_set`: systems
  that share a `Detector` are traced together, the outdated beams of a system). `src/LiveClip.jl`, `src/LiveMeasure.jl`, `src/LiveCamera.jl`,
  `src/LiveSelection.jl`, `src/LiveExport.jl`, `src/LiveExtras.jl`, `src/LiveInfo.jl`: features.
- `src/LiveSelectionCard.jl`: the small menu of a click on a group ("Select", "More") and the selection card of groups (browsing their parts level by level).
  `src/LiveHighlight.jl`: the highlight while browsing (group see-through, boxes of the parts).
  `src/LiveBackground.jl`: the background card. `src/LiveOverlay.jl`: the overlay of the compact layout. `src/LiveHelp.jl`: the help of both layouts (pill, chips of mode and step, help card), built from the entries of `_help_sections` in `src/LiveInteraction.jl`.
- `src/LiveInteraction.jl`: `kinematic_controls!`. `src/ViewCube.jl`: `view_cube!`.
- `src/LiveScripting.jl`: driving a window from code: the verbs of BMO with the window as first
  argument (`translate3d!(gui, obj, offset)`), `select!`, `spectator!` and its options, `wait_solve`.
  `src/LiveRecord.jl`: `Makie.record` of a live view.
- `src/LiveCustom.jl`, `src/LiveWidgets.jl`: `add_panel!`, `add_controls!`, `add_tool!`,
  `retrace!`, own widgets.
- `src/LiveComponents.jl`: `add_component!`, `remove_component!` (components added to and removed
  from a `System` at runtime; an object is a member of any number of systems or of none,
  `_add_member!`, `_remove_member!`, `_attach!`, `_detach!`, `_drop!`), `src/LiveSources.jl`: their
  methods for sources (beams and beam groups), which belong to at most one system or to none
  (`_set_source_system!`) and may also leave a view without a source. `src/LiveSystems.jl`:
  `add_system!`, `remove_system!` and the tool "System". `src/LiveSystemCard.jl`: the card of a
  system, the system widget (name, tracing, "+" and "−", the list of its members, "remove").
  `src/LivePick.jl`: picking the members of a system with the mouse (`_set_member_pick!`,
  `_pick_member!`), whose highlight is in `src/LiveHighlight.jl`. `src/LiveCatalog.jl`: the component catalog (`CatalogEntry`,
  `component_catalog`) and its widgets (groups, tiles, form), `src/LiveCatalogWindow.jl`: its
  window over the 3D view (pin, minimize) and its dock in a place of the layout
  (`_catalog_dock_slot!`, e.g. the left sidebar of the app layout), `src/LiveCatalogEntries.jl`: the entries of the components of
  BeamletOptics, `src/LiveGlasses.jl`: the glasses (`catalog_glasses`, `CatalogGlass`).
  `src/LivePlacement.jl`: placing a new component with the mouse, with snapping onto beams.
  `src/LiveSnap.jl`: snapping of dragged components onto beams (the beams of the live view for
  the snapping of the controls, see `_set_snap!` in `src/LiveInteraction.jl`).
  `src/LiveTable.jl`: the optical table, an overlay with a grid of holes that dragged and placed
  components snap onto (the `snap_grid` of the controls). `src/LiveAlign.jl`: the buttons of the
  card of a component that align it to the nearest beam. `src/LiveAim.jl`: aiming a source with
  the mouse.
- `src/LiveLinks.jl`: `open_system`, a system of a view in a second window: the views are linked
  (`_ViewLinks`) and show the same objects; the view that changes solves, the others follow
  (`_sync_links!` after a solve and when the beams become outdated, `_sync_structure!` after adding
  and removing, which `_attach!` and `_detach!` do for a view without changing the system).
- `src/LiveMarkers.jl`: clip planes and source markers.
- `src/LivePrecompile.jl`: the precompile workload of the package, without a Makie backend.
  `ext/BeamletOpticsGUIGLMakieExt/`: the extension for GLMakie, whose workload replays the sessions
  of simulated mouse and key actions of `session.jl` in an invisible window (`_session` per layout,
  `_catalog_session` for every entry of the catalog). `benchmark/`: scripts that measure what a
  session still compiles, see "Precompilation".
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
- `test/TestPrecompileSession.jl` runs the sessions of the precompile workload, see "Precompilation".
- Docs: `julia --project=docs docs/make.jl`.

## Precompilation

The first use of an action of the mouse or the keys must not compile: a lag at the first hover,
click or drag is what a user notices most. Two workloads provide for that. The one of the package
(`src/LivePrecompile.jl`) runs without a backend. It can not compile the drawing of GLMakie, and
loading GLMakie invalidates a part of what it compiled. The one of the GLMakie extension
(`ext/BeamletOpticsGUIGLMakieExt/`) therefore replays whole sessions in an invisible window.

- **A patch that adds an action adds it to the session in the same patch**: a key, a mouse gesture,
  a tool, a widget or page of a card, a part of a layout. It is a step of `_session` in
  `ext/BeamletOpticsGUIGLMakieExt/session.jl`, made of the events that GLFW sends (`_move!`,
  `_click!`, `_drag!`, `_key!`), followed by `_frame!` or `_settle!`, such that what it shows is
  drawn. An entry of the catalog needs no step: `_catalog_session` places, drags and removes every
  entry of `component_catalog()`.
- **A step checks what it did** (`_check`, `_selected`) and does not depend on the time it takes:
  while precompiling, every step is slow, animations end and solves go to the background. Wait with
  `_settle!`, click on the background at `_free_px`. A step that fails is swallowed by the workload
  and compiles nothing; `test/TestPrecompileSession.jl` runs the sessions with their errors.
- **The GUI is not compiled per component type.** A function of the GUI takes a component as
  `@nospecialize(obj)`, a closure that is called with one starts with `@nospecialize obj`, and a
  search by identity is `_has(xs, x)` or `_index(xs, x)` instead of a closure like `o -> o === x`.
  A script of a user holds types that no workload has seen, e.g. a lens with its own glass. The
  behavior per type stays dispatch (`card_rows` etc.). `live_view` and `kinematic_controls!` are
  not specialized on their arguments either.
- **Measure** with `benchmark/jit_probe.jl` (see its header): it replays a session step by step and
  prints the compile time of each step; `benchmark/jit_trace_summary.jl` lists the methods of a
  trace. The scene `other` holds types that no workload has seen. A step of a new action that
  compiles more than a few 10 ms in the scene `same` is not covered by the workload.
- The workload of the extension is built with GLMakie loaded after the package. Code that Julia
  cached is checked against the methods of the session when it is loaded, and in a session that
  loads GLMakie first, a part of it is rejected and compiled again at the first use, about twice as
  much as with GLMakie loaded last (`JIT_PROBE_ORDER` of the probe). The README, the docs, the
  skill and the script of `export_script` therefore load GLMakie last
  (`using BeamletOptics, BeamletOpticsGUI, GLMakie`) and say that the order makes a difference, see
  "Order of loading" in `docs/src/index.md`; new examples do the same. Nothing in the package may
  depend on the order.

## Agent skill

[skills/beamletopticsgui/](skills/beamletopticsgui/) ships with every release and must describe
exactly that release. A patch that changes public behavior (exports, keyword arguments or their
defaults, the card API) updates the skill in the same patch. `test/TestAgentSkill.jl` checks the
export table in `API.md` and the version field in `SKILL.md` against the package.

## Docstrings and style

As in BMO: pages embed docstrings instead of repeating them, docstrings are self-sufficient in the
REPL, the SciML style guide is the baseline, and new functionality comes with tests and docs.
