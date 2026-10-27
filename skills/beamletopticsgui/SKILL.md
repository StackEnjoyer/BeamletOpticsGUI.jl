---
name: beamletopticsgui
description: Build, extend and debug the interactive GUI of BeamletOptics.jl with BeamletOpticsGUI.jl (Julia). Use when writing Julia code that uses live_view, kinematic_controls!, view_cube!, cards (card_rows, CardRow, CardWidget), add_panel!, add_controls! or add_tool!, or when the user wants an interactive window in which optical components are moved with the mouse and the beams and detectors update live.
allowed-tools: Read, Write, Edit, Grep, Glob, Bash
metadata:
  beamletopticsgui-version: "0.3"
---

You are helping the user with the interactive GUI **BeamletOpticsGUI.jl**: a Julia package that opens a
GLMakie window for a BeamletOptics system, in which components are moved with the mouse and keyboard and
the beams and the detector views on the detector cards update live. The optics is BeamletOptics (BMO); this skill covers only the GUI.

When this Skill is active:

- **The optics comes from the `beamletoptics` skill.** Units (SI, wavelengths in meters), the optical
  axis (+y), components, beams, `solve_system!`, detectors and the rendering functions (`render!`,
  `live_render!`, look, camera helpers) are described there. Use it for everything except the window. If it
  is not installed: `using BeamletOptics; BeamletOptics.install_agent_skill()`.
- This skill describes BeamletOpticsGUI **0.3** (`beamletopticsgui-version` above). Check the installed
  version with `julia --project=<env> -e 'using BeamletOpticsGUI; println(pkgversion(BeamletOpticsGUI))'`.
  If its major or minor version differs, treat the signatures in these files as possibly outdated,
  confirm them with the docstrings and tell the user that
  `using BeamletOpticsGUI; BeamletOpticsGUI.install_agent_skill()` installs the matching skill.
- Use only documented API. **Do not invent functions or keywords.** Print the docstring before use:
  `julia --project=<env> -e 'using BeamletOpticsGUI; display(@doc live_view)'`, or list the exports with
  `names(BeamletOpticsGUI)`.
- Every script starts with `using BeamletOptics, BeamletOpticsGUI, GLMakie`. The order makes a
  difference: GLMakie is loaded last. The window works in any order, but with GLMakie loaded before
  BeamletOpticsGUI, Julia rejects a part of the precompiled code of the GUI and compiles about twice
  as much at the first hover, click or drag.
- The window needs GLMakie and a display. It is not for headless scripts; on headless Linux run under
  `xvfb-run -a`. Say so to the user when you cannot open it, and do not claim that the window works
  when you did not run it.
- Moving objects from a script goes through the verbs with the window first, e.g. `translate3d!(gui, obj, d)`, see "Scripting a window" in API.md.
- Changes of the optics from own widgets go through `retrace!(f, gui)`. Widgets of an object belong on
  its card (`card_rows`), parameters without an object in `add_controls!`, plots in `add_panel!`.
- Card functions are extended as `BeamletOpticsGUI.card_rows(x::MyType)`, in a package extension of
  the component package (weak dependency on BeamletOpticsGUI) or directly in a script.

## Default workflow

1) Build and check the system without the GUI first (the `beamletoptics` skill): solve it, look at the
   numbers, render it statically with `render!`.
2) Open the window: `gui = live_view(system, beam); display(gui)`. Several systems and beams:
   `live_view(sys1 => beam1, sys2 => beam2)` (a source is given once: the same beam for two systems
   throws an `ArgumentError`); systems are added with `add_system!(gui)` or the tool "System", and an
   object that two systems share is added to the second with `add_component!(gui, obj; system = sys2)`
   (one object, drawn once, each system traced on its own); `open_system(gui, sys2)` opens one of
   them in a second, linked window. Pass `labels`, `detectors`, `extras` (housings),
   `constraints`, `on_change` as needed (`API.md`).
3) Add own parts if the user needs them: a card for an own component type, a catalog entry for it, a
   controls section, a tool or a panel (`WIDGETS.md`, `VISUALIZATION.md`). Components and sources can be added
   to and removed from the view in the window (catalog "Components", keys `Insert` and `Delete`) or from code with
   `add_component!` and `remove_component!` (`API.md`); `live_view(System())` starts on an empty table.
4) Export the alignment found in the window with `export_changes(gui)` (the button "Export" does the
   same) and paste it into the script that builds the system.

## Limits of the current version

- Extras (objects without a system) are given when the view starts; they can be hidden, removed and
  made members of a system like any component. Components of a `System`, sources and systems can
  be added and removed at runtime, with these limits: the objects of a `StaticSystem` and objects
  inside a group cannot be added or removed; a component or source that is being placed is not traced until it is
  dropped; only components and sources from the catalog can be changed afterwards (page "Edit" of the card).
  `export_script` writes the constructors of those and of the objects added with
  `add_component!(...; code = "...")`; an object that the view started with is a comment in the
  script. Adding, removing and changing are undone with
  `Ctrl+Z` and redone with `Ctrl+Y`. `Ctrl+C` and `Ctrl+V` copy and paste the selected component or
  source from the catalog, in the window only (the copy is placed with the mouse); from code, construct
  the object again and call `add_component!`. A group whose components are all from the catalog, or
  several selected objects, are copied with their structure and relative poses; a pasted group is a
  group made in the window, several pasted objects stay separate; one undo step. A source is copied
  only on its own.
- Several objects can be selected: `Ctrl`+click (`Cmd` on macOS) in the 3D view or on a row of the
  tree (app layout) toggles an object, `Ctrl`+drag from the background or an unselected object draws a rectangle that adds
  the visible, movable top-level objects whose center is inside (a drag on a selected object moves the
  selection), `select!(gui, [a, b])` from code, `Esc` clears. They are moved
  and rotated as one about the mean of their positions with the world axes as gizmo axes, without
  snapping, only on the axes that all allow; one drag, run of keys or `Backspace` is one undo step,
  and `on_change` is called once per object. Their card (compact) or the inspector (app) shows "N
  objects" ("Selection"), one row per object (click: that object alone), hide and remove, no pages and
  no pin. `Ctrl+C` copies them if all their components are from the catalog. `gui.controls.selected[]` then holds an internal value, not a
  component.
- `Ctrl+G` (`Cmd+G`) makes a selection of several an `ObjectGroup`: the systems hold the group
  instead of the objects, it is selected, moved, rotated, hidden and browsed like a group of the
  script (pivot: mean of the member positions, world axes), one undo step. Only two or more movable
  top-level components with the same systems (or none) qualify (no sources, clip planes, static
  objects, parts of groups, objects of a `StaticSystem`); else the status line says why.
  `Ctrl+Shift+G` ungroups a group made in the window (not one of the script): the members are
  top-level again at their poses and selected, one undo step; one inside another group made in the
  window is dissolved into it (that group is made anew, same name, label, pivot). `Ctrl+G` on several
  (not all) parts of one group (made in the window, or an `ObjectGroup` of the script) makes them a
  group inside it (pivot: mean of their positions, world axes, selected); the groups above are made
  anew (same name, label, pivot, world axes) as groups made in the window, also one that replaced a
  group of the script (`Ctrl+Shift+G` can ungroup it); one undo step, which brings the old groups
  back. `Ctrl`+click in the 3D view on a part of the same group, or on part rows of the tree
  (app layout), adds or removes it while parts of one group are selected. The cards have the actions "group"
  and "ungroup". `export_script` writes the members, `g = ObjectGroup([a, b])`, `set_pivot3d!` and
  the pose of the group; `export_changes` writes the grouping of objects of the script (`delete!`
  of the members, the group, `push!` of the group; for a script group that was made anew also
  `delete!(system, sg)` of the old one before the new groups, also after the new group was ungrouped).
- A source belongs to at most one system: `live_view(sys1 => b, sys2 => b)` throws an
  `ArgumentError`, and a source without a system is not traced or drawn. The last system of a view
  cannot be removed. The auto tracing of a single system and the picking of members with "+" and "−"
  exist in the window only; there is no public function for them (from code: `add_component!` and
  `remove_component!` with `system`).
- Aligning is done in the window only: the buttons "onto beam" and "face beam" of the card of a
  component, "aim" of the card of a source and the optical table (`table = true`, a grid of holes that
  dragged components snap onto). There is no public function for them; from code, set the poses with
  BeamletOptics (`translate_to3d!`, `rotate3d!`) and call `retrace!`.
- The window has two fixed layouts (`layout = :compact` or `:app`); there are no public widget blocks
  to assemble an own layout.
- The detector view (page "Results" of a card) exists for `Detector` only; there is no public API for
  views of own types. Own plots are added with `add_panel!`.
- There are no detector panels beside the 3D view or in the dock and no `history` option: record
  values in `on_change` and plot them in an `add_panel!` panel.

Do not describe these as available.

## Local references bundled with this Skill

- API primer and export table: `API.md`
- The live view, its own parts (panels, controls, tools) and inspection: `VISUALIZATION.md`
- Own cards, widgets and controls (recipes): `WIDGETS.md`

The optics, units, conventions, workflow patterns and the checklist are in the `beamletoptics` skill.
