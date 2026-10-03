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
after each change and the detector views update live. `export_changes(gui)` prints the changed poses
as Julia code. Needs an interactive display; not for headless scripts. A selected component opens a
card next to it in the 3D view: exact position `x`, `y`, `z` [mm], rotations `rx`, `ry`, `rv`
[mrad] about the gizmo axes and "hide". The pin keeps a card
with its component, so several components can be edited side by side. Dragging the head of a card
moves it to a fixed place in the view (kept when pinned; double click on the head: back next to
its component). Every card has pages, chosen by a page bar below its head: "Pose" (the pose
boxes and the rows of the type) and "Properties"; the card of a `Detector` has "Results" between
them (details below); a card with a single page (inspected point, measurement) has no bar. A card
opens on "Results" for a detector, else on "Pose"; a pinned card keeps its page. Rows of the
type: rays hitting it and their angle of incidence (last solve), `n` of lenses, R/T of
beamsplitters, the polarizer axis, detector `signal` (power or number of rays of its view while a
view is shown, else number of hits), the ray count slider of sources
(`set_num_rays!`), and on every beam, beam group, source and beamlet the toggle "on" (off: not
solved, not drawn, rays removed from detectors; only the source marker stays), for Gaussian
beamlets the toggle "beams" (generating beams as `render!(...; show_beams = true)`), for polarized
beams the toggle "polarization" and the sliders `pol λ`, `pol amp` (wavelength and amplitude of
the drawn curve, log scale; astigmatic beamlets: amplitude × beam radius). Of a group only the
central beam; display only. The box `length` [mm] sets how long rays that hit nothing are drawn
(`flen`). Start states: `beams_off = [src]`, `beam_kwargs = Dict(b => (;
show_polarization = true, show_beams = true, pol_λ = 1e-3, pol_amplitude = 2e-4))`.
The card of the selected object also has, on its page "Pose", the keyboard step (e.g. `250 nm` or `50 µrad`; shown in the unit of its size, pm to m and nrad to mrad) and a
"Move"/"Rotate" control (in sync with the key `m`); the page "Properties" lists the properties of
the object (the same rows as the inspector of the app). Objects without a `labels` entry
get automatic names ("Mirror 1", "Clip plane 2") in the cards, menus and tree. The card of a system
(number of objects, rays, solve time) opens from its entry in the component menu of the tool rail (compact) or its
row in the tree (app), without a selection; non-movable objects are shown the same way (pose
inputs are rejected). A click on an object of a group opens a small menu under the cursor ("Select <group>" under
the cursor, so a second click selects the top-level group, and "More ›"); "More ›" opens the
selection card of the group there (first entry "Select <group>", "‹ <parent>", then the parts, " ›"
on parts with parts, more than 5 parts scroll; a click on a part in the 3D view acts as its entry, a
click beside or `Esc` at the top closes, `Esc` goes up one level, `↑`/`↓` and `Enter` choose; the
card of an object with parts has "parts ›" in its head, the card of a part "‹"; a drag at the head
of the menu or the card moves it); a click inside the
selection keeps it; an object not in a group opens its card at once. A click on a pinned card beside
its widgets selects its object.
Own types add rows with a `card_rows` method (`CardRow`, `CardWidget`), see
`WIDGETS.md`.
`theme = :light` (default) or `:dark` colors the whole window (both layouts); the info label
(toast at the bottom for 3 s after each change in compact, status bar in app) shows the last solve
time, the number of rays (of the beams that are on) and the projection.
`layout = :compact` (default): the 3D view fills the window, the `add_panel!` panels, if any, are
in a column on its right (`gui.fig[1, 2]`), there are no rows below it. Help pill at the top left (`h` or a
click opens the help card: keys and mouse actions in sections, `add_tool!` keys under "Own tools";
the chips next to it show mode and keyboard step, clickable); the button "⋯" at the bottom left opens the tool rail (trace, auto trace, sources, clip
beams, measure, show all, component menu "select component", export, `add_tool!` tools, one entry
per `add_controls!` section, "Sliders" for `sliders`; entries with widgets open a popover; `Esc`
closes); the mouse over the view cube shows the camera popover (home, fit `g`, views, save view,
orthographic); the status line appears as a toast.
`layout = :app` arranges the window like an application, with the cards (selection and
pinned) docked in the "Properties" sidebar instead of floating; the float button of a pinned card
moves it into the 3D view next to its component, its dock button moves it back; docked pinned
cards have the same pages as floating ones (a detector view takes the width of the sidebar, has no
resize grip and collapses or shrinks when the sidebar is full). The dock below the 3D view only has
tabs of `add_panel!` and stays collapsed until the first one exists. Its 3D view has
the same help pill, chips and help card at the top left.
The spectator mode (`v`, the chip "Spectator" next to the help pill, or `spectator = true` at the
start) shows only the 3D view and the help in both layouts: tools, status, view cube, cards,
source markers (and with the cards the detector views), panels, toolbar, sidebars and dock are hidden and come back as they were; the progress window of a
running trace stays. `add_panel!`, `add_controls!` and `add_tool!` also work while it is on.

Mechanics that should be visible but not traced (e.g. a housing STL) go into
`extras = [housing => (; color = :lightblue), ...]` (`obj` or `obj => render_kwargs`), not into
the system and not via `render!(gui.ax, ...)`: extras cost nothing in the solves, but can be
selected, moved, hidden and exported like components. An extra must not also be an object of a
system (`ArgumentError`). The card of a `NonInteractableObject`/`MeshDummy` or
`IntersectableObject` has an "opacity" slider (0-100 %, 0 % hides it); below 50 % a click in the
3D view passes through it (select it in the tree or the component menu).

**Detector view.** The results of a `Detector` are on the page "Results" of its card (no panels
beside the 3D view or in the dock). The view is expanded by default; its chevron collapses it to a
thumbnail (92 px: kind, key value, centroid, radii), a click on the thumbnail expands it. Expanded:
a switch of the kinds, toggles "log" and "profiles" (field views only), button "fit", the plot in mm
(centroid as a red cross) and two lines of metrics; "profiles" adds the intensity along x (red) and
z (blue) through the centroid. Kinds (first = default): rays (`RayHit`, `PolarizedRayHit`): "Spot"
and "PSF" (`intensity` of the rays, normalized to its peak, metrics without power); Gaussian
beamlets: "Intensity" (W/m², with power) and "Spot" (1/e² outlines). A kind that the hits do not
offer falls back to the default; without hits the view reads "no hits". Mouse as on a Makie `Axis`: wheel zooms
about the cursor, left drag selects the rectangle to zoom to (shape of the plot), right drag pans,
Ctrl + click, double click or "fit" resets; in a PSF or intensity view the field is recomputed
for the visible window on the full grid `n` once the mouse rests for `idle_delay`. A field costs
about 14 ns · n² · hits per thread (n = 100, 1000 ray hits: about 150 ms on one thread, 9 ms with 32
threads): start Julia with `julia -t auto`. Slow computations run in the background with the
progress window and "Cancel"; above `trace_budget` a coarse preview comes first. Only shown views
are computed (page "Results" of the selected detector or of a pinned, not collapsed card; a
thumbnail on at most 48 points per axis). A floating card with an expanded view is resizable by its
grip at the bottom right (160 px up to the size of the 3D view). `detectors = [pd => (:intensity,
(; n = 100, colorscale = :log, colorrange = (lo, hi), profiles = true, expanded = false, x_min, ...))]`
pins the card at start (floating next to the detector in compact, docked in the right sidebar in
app); other entries go to `BeamletOptics.intensity`, `x_min`/`x_max`/`z_min`/`z_max` set the area
that "fit" shows. `history` is gone (`ArgumentError`): record in `on_change`, plot in `add_panel!`.

Own GUI parts go into a `gui = live_view(...)` via three functions that work with both
`layout = :compact` and `layout = :app` (the layout places them); do not place blocks at fixed
`gui.fig[...]` positions, those only exist in the compact layout:

```julia
power = Point2f[]   # recorded by on_change = (gui, obj) -> push!(power, ...), runs after every full solve
add_panel!(gui, "Power") do layout            # compact: a column right of the 3D view; app: a dock tab
    ax = Axis(layout[1, 1]; xlabel = "Update", ylabel = "P [mW]")
    pts = Observable(copy(power)); lines!(ax, pts)
    return gui -> (pts[] = copy(power); autolimits!(ax))   # update(gui): after full solves, only while shown
end
add_controls!(gui, "Mirror") do layout        # compact: entry of the tool rail "⋯", opens a popover; app: left sidebar
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
  `auto_trace = false`, which also starts the view untraced until `t`); make object changes
  inside `f` (a background solve is cancelled first).
- `f` of `add_controls!` may return `update(gui)` as well (after each full solve and once right
  away, must not change objects). Controls are for parameters without a scene object; widgets of
  an object belong on its card (`card_rows`). See `WIDGETS.md` for both recipes.
- Textboxes/menus built in `add_controls!`/`add_panel!` block the 3D keys while focused/open.
- `key` must be free: all letters, arrows, `1`, `Esc`, `Tab`, `Insert`, `Delete`, `Backspace`, Shift/Ctrl/Alt,
  `+`/`-` are taken (live view, kinematic controls, Makie `Camera3D`) → `ArgumentError`. Use
  digits `2`-`9` or `f1`-`f12`. `icon` must be an icon name of the app (e.g. `:measure`,
  `:export`, `:chart`, `:object`) or a `Makie.BezierPath`, else `ArgumentError` listing them (also
  in compact).

Solves longer than `progress_delay` (kwarg, default 0.5 s) run in the background: the window stays
usable and a small progress window appears next to the source being traced or the detector whose
field is computed, connected to it by a line. Moving a component or the button "Cancel" of the progress window cancels the solve (`Esc` does not).

A failed solve (also the initial one, `live_view` does not throw) opens a card "Solve failed" in the
3D view besides the log. A detector stores one kind of hits per solve: two kinds on one detector
(polarized + unpolarized rays, rays + Gaussian beamlets) fail by design in BMO; the card sits at
the detector and names both kinds. Fix: switch a beam off (card toggle "on") or add a detector.
