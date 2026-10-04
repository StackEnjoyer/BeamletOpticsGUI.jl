---
name: beamletopticsgui
description: Build, extend and debug the interactive GUI of BeamletOptics.jl with BeamletOpticsGUI.jl (Julia). Use when writing Julia code that uses live_view, kinematic_controls!, view_cube!, cards (card_rows, CardRow, CardWidget), add_panel!, add_controls! or add_tool!, or when the user wants an interactive window in which optical components are moved with the mouse and the beams and detectors update live.
allowed-tools: Read, Write, Edit, Grep, Glob, Bash
metadata:
  beamletopticsgui-version: "0.2"
---

You are helping the user with the interactive GUI **BeamletOpticsGUI.jl**: a Julia package that opens a
GLMakie window for a BeamletOptics system, in which components are moved with the mouse and keyboard and
the beams and the detector views on the detector cards update live. The optics is BeamletOptics (BMO); this skill covers only the GUI.

When this Skill is active:

- **The optics comes from the `beamletoptics` skill.** Units (SI, wavelengths in meters), the optical
  axis (+y), components, beams, `solve_system!`, detectors and the rendering functions (`render!`,
  `live_render!`, look, camera helpers) are described there. Use it for everything except the window. If it
  is not installed: `using BeamletOptics; BeamletOptics.install_agent_skill()`.
- This skill describes BeamletOpticsGUI **0.2** (`beamletopticsgui-version` above). Check the installed
  version with `julia --project=<env> -e 'using BeamletOpticsGUI; println(pkgversion(BeamletOpticsGUI))'`.
  If its major or minor version differs, treat the signatures in these files as possibly outdated,
  confirm them with the docstrings and tell the user that
  `using BeamletOpticsGUI; BeamletOpticsGUI.install_agent_skill()` installs the matching skill.
- Use only documented API. **Do not invent functions or keywords.** Print the docstring before use:
  `julia --project=<env> -e 'using BeamletOpticsGUI; display(@doc live_view)'`, or list the exports with
  `names(BeamletOpticsGUI)`.
- Every script starts with `using GLMakie, BeamletOptics, BeamletOpticsGUI`.
- The window needs GLMakie and a display. It is not for headless scripts; on headless Linux run under
  `xvfb-run -a`. Say so to the user when you cannot open it, and do not claim that the window works
  when you did not run it.
- Changes of the optics from own widgets go through `retrace!(f, gui)`. Widgets of an object belong on
  its card (`card_rows`), parameters without an object in `add_controls!`, plots in `add_panel!`.
- Card functions are extended as `BeamletOpticsGUI.card_rows(x::MyType)`, in a package extension of
  the component package (weak dependency on BeamletOpticsGUI) or directly in a script.

## Default workflow

1) Build and check the system without the GUI first (the `beamletoptics` skill): solve it, look at the
   numbers, render it statically with `render!`.
2) Open the window: `gui = live_view(system, beam); display(gui)`. Several systems and beams:
   `live_view(sys1 => beam1, sys2 => beam2)`. Pass `labels`, `detectors`, `extras` (housings),
   `constraints`, `on_change` as needed (`API.md`).
3) Add own parts if the user needs them: a card for an own component type, a catalog entry for it, a
   controls section, a tool or a panel (`WIDGETS.md`, `VISUALIZATION.md`). Components and sources can be added
   to and removed from the view in the window (catalog "Components", keys `Insert` and `Delete`) or from code with
   `add_component!` and `remove_component!` (`API.md`); `live_view(System())` starts on an empty table.
4) Export the alignment found in the window with `export_changes(gui)` (the button "Export" does the
   same) and paste it into the script that builds the system.

## Limits of the current version

- Extras are fixed when the view starts (they can be hidden). Components of a `System` and sources can
  be added and removed at runtime, with these limits: the objects of a `StaticSystem` and objects
  inside a group cannot be added or removed; a component or source that is being placed is not traced until it is
  dropped; only components and sources from the catalog can be changed afterwards (page "Edit" of the card)
  and are written with their constructors by `export_script`. Adding, removing and changing are undone with
  `Ctrl+Z` and redone with `Ctrl+Y`.
- Aligning is done in the window only: the buttons "onto beam" and "face beam" of the card of a
  component, "aim" of the card of a source and the optical table (`table = true`, a grid of holes that
  dragged components snap onto). There is no public function for them; from code, set the poses with
  BeamletOptics (`translate_to3d!`, `rotate3d!`) and call `retrace!`.
- The window has two fixed layouts (`layout = :compact` or `:app`); there are no public widget blocks
  to assemble an own layout.
- The detector view (page "Results" of a card) exists for `Detector` only; there is no public API for
  views of own types. Own plots are added with `add_panel!`. A detector view in a figure of your own is
  `detector_view!` (`WIDGETS.md`); there are no detector panels beside the 3D view or in the dock, and
  no `history` option: record values in `on_change` and plot them in an `add_panel!` panel.

Do not describe these as available.

## Local references bundled with this Skill

- API primer and export table: `API.md`
- The live view, its own parts (panels, controls, tools) and inspection: `VISUALIZATION.md`
- Own cards, widgets and controls (recipes): `WIDGETS.md`

The optics, units, conventions, workflow patterns and the checklist are in the `beamletoptics` skill.
