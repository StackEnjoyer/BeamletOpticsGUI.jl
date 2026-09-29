# The live view (GLMakie)

The interactive window of BeamletOpticsGUI. It needs GLMakie and an interactive display, so it is not
for headless scripts. Rendering of components and beams (`render!`, look, camera helpers, `live_render!`)
belongs to BeamletOptics, see `VISUALIZATION.md` of the `beamletoptics` skill.

```julia
using GLMakie, BeamletOptics, BeamletOpticsGUI

gui = live_view(system, beam)   # several systems: live_view(sys1 => beam1, sys2 => beam2)
display(gui)
```

`view_cube!(ls)` adds a CAD-style cube to a corner of an `LScene`; a click sets the standard view
(`live_view` shows one by default, `view_cube = false` disables it).

`gui = live_view(system, beam); display(gui)` opens a window in which components are moved with
the mouse and keyboard (`kinematic_controls!`, `h` shows all controls), the system is re-solved
after each change and detector panels update live. `export_changes(gui)` prints the changed poses
as Julia code. Needs an interactive display; not for headless scripts. A selected component opens a
card next to it in the 3D view: exact position `x`, `y`, `z` [mm], rotations `rx`, `ry`, `rv`
[mrad] about the gizmo axes and "hide". The pin keeps a card
with its component, so several components can be edited side by side. Dragging the head of a card
moves it to a fixed place in the view (kept when pinned; double click on the head: back next to
its component). Below the pose, rows of the
type: rays hitting it and their angle of incidence (last solve), `n` of lenses, R/T of
beamsplitters, the polarizer axis, detector power, the ray count slider of sources
(`set_num_rays!`). Only the card of the selection also has the keyboard step (e.g. `250 nm`), a
"Move"/"Rotate" control (in sync with the key `m`) and a "Properties" part (collapsed by default,
the same rows as the inspector of the app), pinned cards do not. Objects without a `labels` entry
get automatic names ("Mirror 1", "Clip plane 2") in the cards, menus and tree. The card of a system
(number of objects, rays, solve time) opens from its entry in the component menu (compact) or its
row in the tree (app), without a selection; non-movable objects are shown the same way (pose
inputs are rejected). Own types add rows with a `card_rows` method (`CardRow`, `CardWidget`), see
`WIDGETS.md`.
`theme = :light` (default) or `:dark` colors the whole window (both layouts); the info label at
the end of the status row shows the last solve time, the number of rays and the projection.
`layout = :app` arranges the window like an application, with the cards (selection and
pinned) docked in the "Properties" sidebar instead of floating; the float button of a pinned card
moves it into the 3D view next to its component, its dock button moves it back.

Mechanics that should be visible but not traced (e.g. a housing STL) go into
`extras = [housing => (; color = :lightblue), ...]` (`obj` or `obj => render_kwargs`), not into
the system and not via `render!(gui.ax, ...)`: extras cost nothing in the solves, but can be
selected, moved, hidden and exported like components. An extra must not also be an object of a
system (`ArgumentError`). The card of a `NonInteractableObject`/`MeshDummy` or
`IntersectableObject` has an "opacity" slider (0-100 %, 0 % hides it); below 50 % a click in the
3D view passes through it (select it in the tree or the component menu). The card of a `Detector`
has the mode and log color scale of its detector panel.

Own GUI parts go into a `gui = live_view(...)` via three functions that work with both
`layout = :compact` and `layout = :app` (the layout places them); do not place blocks at fixed
`gui.fig[...]` positions, those only exist in the compact layout:

```julia
power = Point2f[]   # recorded by on_change = (gui, obj) -> push!(power, ...), runs after every full solve
add_panel!(gui, "Power") do layout            # compact: below the detector panels; app: a dock tab
    ax = Axis(layout[1, 1]; xlabel = "Update", ylabel = "P [mW]")
    pts = Observable(copy(power)); lines!(ax, pts)
    return gui -> (pts[] = copy(power); autolimits!(ax))   # update(gui): after full solves, only while shown
end
add_controls!(gui, "Mirror") do layout        # compact: row above the status row; app: left sidebar
    b = Button(layout[1, 1]; label = "tilt +1 mrad")
    on(_ -> retrace!(() -> zrotate3d!(m1, 1e-3), gui), b.clicks)   # change inside retrace!, then re-solve
end
add_tool!(gui, "Reset m1"; icon = :home, key = Keyboard._2) do gui   # toggle = true: f(gui, active)
    retrace!(() -> translate_to3d!(m1, [0, 0.1, 0]), gui)
end
```

- `f` of `add_panel!` returns `update(gui)` or anything else (= no update); in the app, hidden tabs
  are updated when opened (`select = true` shows the new tab). Record data in `on_change`, not in
  `update`, if it must be recorded while the panel is hidden.
- `retrace!(gui)` / `retrace!(f, gui)` re-solves like a `sliders` entry (marks stale with
  `auto_trace = false`); make object changes inside `f` (a background solve is cancelled first).
- `f` of `add_controls!` may return `update(gui)` as well (after each full solve and once right
  away, must not change objects). Controls are for parameters without a scene object; widgets of
  an object belong on its card (`card_rows`). See `WIDGETS.md` for both recipes.
- Textboxes/menus built in `add_controls!`/`add_panel!` block the 3D keys while focused/open.
- `key` must be free: all letters, arrows, `1`, `Esc`, `Delete`, `Backspace`, Shift/Ctrl/Alt,
  `+`/`-` are taken (live view, kinematic controls, Makie `Camera3D`) → `ArgumentError`. Use
  digits `2`-`9` or `f1`-`f12`. `icon` must be an icon name of the app (e.g. `:measure`,
  `:export`, `:chart`, `:object`) or a `Makie.BezierPath`, else `ArgumentError` listing them (also
  in compact).

Solves longer than `progress_delay` (kwarg, default 0.5 s) run in the background: the window stays
usable and a small progress window appears next to the source being traced or the detector whose
field is computed. Moving a component or pressing `Esc` cancels the solve.
