---
name: beamletopticsgui
description: Build, extend and debug the interactive GUI of BeamletOptics.jl with BeamletOpticsGUI.jl (Julia). Use when writing Julia code that uses live_view, kinematic_controls!, view_cube!, cards (card_rows, CardRow, CardWidget), add_panel!, add_controls! or add_tool!, or when the user wants an interactive window in which optical components are moved with the mouse and the beams and detectors update live.
allowed-tools: Read, Write, Edit, Grep, Glob, Bash
metadata:
  beamletopticsgui-version: "0.1"
---

You are helping the user with the interactive GUI **BeamletOpticsGUI.jl**: a Julia package that opens a
GLMakie window for a BeamletOptics system, in which components are moved with the mouse and keyboard and
the beams and the detector views on the detector cards update live. The optics is BeamletOptics (BMO); this skill covers only the GUI.

When this Skill is active:

- **The optics comes from the `beamletoptics` skill.** Units (SI, wavelengths in meters), the optical
  axis (+y), components, beams, `solve_system!`, detectors and the rendering functions (`render!`,
  `live_render!`, look, camera helpers) are described there. Use it for everything except the window. If it
  is not installed: `using BeamletOptics; BeamletOptics.install_agent_skill()`.
- This skill describes BeamletOpticsGUI **0.1** (`beamletopticsgui-version` above). Check the installed
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
3) Add own parts if the user needs them: a card for an own component type, a controls section, a tool or
   a panel (`WIDGETS.md`, `VISUALIZATION.md`).
4) Export the alignment found in the window with `export_changes(gui)` (the button "Export" does the
   same) and paste it into the script that builds the system.

## Limits of the current version

- Components cannot be added or removed in the window at runtime (they can be hidden; extras are fixed
  when the view starts).
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
