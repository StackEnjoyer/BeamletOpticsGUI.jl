# BeamletOpticsGUI API primer

BeamletOpticsGUI is the interactive GUI of BeamletOptics. It draws BeamletOptics systems and beams
(with `render!`/`live_render!` of BeamletOptics), lets the user move the components and re-solves
after each change. The optics itself (components, beams, `solve_system!`, detectors, units,
conventions) is described by the `beamletoptics` skill.

```julia
using GLMakie, BeamletOptics, BeamletOpticsGUI

# system and beam built as in the beamletoptics skill
gui = live_view(system, beam; layout = :compact, labels = Dict(m1 => "Mirror 1"))
display(gui)                # opens the window; `wait(display(gui))` in a script
code = export_changes(gui)  # the changed poses as Julia code
script = export_script(gui) # the whole setup as a script (constructors of catalog parts)
```

Look up the docstring of any name before use, e.g.
`julia --project=<env> -e 'using BeamletOpticsGUI; display(@doc live_view)'`. Do not invent keywords.

## Exported names (by category)

| Category | Names |
|----------|-------|
| Window | `live_view`, `open_system`, `export_changes`, `export_script`, `retrace!` |
| Scripting | `select!`, `spectator!`, `wait_solve` (plus methods of the BeamletOptics verbs, see "Scripting a window") |
| Components at runtime | `add_component!`, `remove_component!`, `CatalogEntry`, `CatalogParam`, `CatalogGlass`, `component_catalog`, `catalog_glasses` |
| Interactive helpers | `kinematic_controls!`, `view_cube!` |
| Extending the window | `add_panel!`, `add_controls!`, `add_tool!` |
| Cards | `card_rows`, `pose_card_rows`, `beam_card_rows`, `card_actions`, `CardRow`, `CardWidget`, `card_input`, `card_show!` |

Not exported: `BeamletOpticsGUI.install_agent_skill`.

## `live_view` keywords (the frequent ones)

| Keyword | Meaning |
|---------|---------|
| `layout = :compact` or `:app` | the window layout (compact: 3D view fills the window, tools on demand in a tool rail over it; app: a tree, an inspector, a dock and a toolbar) |
| `theme = :light` or `:dark` | colors of the whole window |
| `labels = Dict(obj => "name")` | names in cards, status line and menus |
| `constraints = Dict(obj => (; move = (), rotate = (:x, :v)))` | lock axes of components |
| `detectors = :auto` or `[]`, or a vector (`pd`, `pd => :spot`, `pd => (:intensity, (; n, colorscale, colorrange, profiles, expanded, x_min, ...))`) | `:auto` and `[]`: every detector has the page "Results" on its card, none is pinned at start; a vector pins the cards of these detectors at start with these options (kind `:auto`, `:spot`, `:psf` or `:intensity`; other entries go to `BeamletOptics.intensity`; `history` throws `ArgumentError`) |
| `sliders = ["label" => (range, callback)]` | custom parameters (callbacks in SI units); compact: entry "Sliders" of the tool rail, app: "Parameters" |
| `on_change = (gui, obj) -> ...` | called after each full solve, with the moved object or `nothing` |
| `extras = [housing => (; color = ...)]` | shown, movable, but never traced |
| `clip_planes`, `clip_beams` | clip planes (`point => normal`) |
| `auto_trace`, `trace_budget`, `idle_delay`, `preview`, `progress_delay` | when and how the systems are solved (`auto_trace = false` also starts untraced, `t` traces) |
| `beam_kwargs = Dict(source => (; render_every = 50))` | `render!` keywords per source; `show_polarization`, `show_beams`, `pol_λ`, `pol_amplitude`, `pol_scale` set the start state of the card toggles and sliders |
| `beams_off = [src]` | beams that start off (not solved, not drawn; the card toggle "on" switches them) |
| `background_card = obj` or `gui -> obj_or_nothing` (or `obj => point`) | the card of an object without a place in the scene, shown on a click on the empty background while nothing is selected; `obj => point` attaches it to `point` [m] |
| `catalog = component_catalog()` | the entries of the component catalog (`CatalogEntry`s); `CatalogEntry[]` shows no catalog |
| `snap = false` | components snap onto the central beams, and onto the holes of a shown table, while dragged or placed with the mouse: `true`/`:position` (position only) or `:pose` (position and rotation); in the rotate mode in steps of 45° to the beam. In the window: `Tab` or the chip "Snap" cycles off, position, position and rotation; `Shift`+`Tab` backwards |
| `table = false` | optical table below the setup, also the toggle "Table" among the tools: `true`, or `(; pitch = 25e-3, height = nothing, snap = true, shown = true)` [m]; while shown and `snap` is on, dragged and placed components and sources snap onto its holes beside the beams, rotations in steps of 45° to its rows |
| `views`, `orthographic`, `view_cube`, `show_sources`, `movable_sources` | camera and markers |

`open_system(gui, system; display = true, kwargs...)` opens a system of the view with its components
and sources in a second window and returns its `LiveView` (in the window: the button "new window" on
the card of the system). Both windows show the same objects and are linked: moving, adding, removing
and editing in one of them shows in the other one, only the window that changed solves. `kwargs`
are those of `live_view` and override what the new window takes over (layout, theme, catalog, names,
beam colors, snap, table, settings of the controls); the switch of the auto tracing is shared by the
linked windows, the selection, camera, colors, hidden objects, clip planes and the undo history are
per window. Closing a window ends the link.

`add_component!(gui, obj; system, select, label)` adds a component (placed beforehand, e.g. with
`translate_to3d!`) to a `System` of the view at runtime, `remove_component!(gui, obj)` removes it.
Sources are added and removed the same way: `add_component!(gui, source; system, select, label,
beam_kwargs)` traces a beam or beam group through a system of the view (also a `StaticSystem`) and
gives it a marker, `remove_component!(gui, source)` removes it, also the last one. Every source is
drawn with `color = :wavelength` (every ray in the display color of its own wavelength, dark red
for infrared and dark violet for ultraviolet), unless its `beam_kwargs` set a fixed `color` for all
rays (`add_component!(...; beam_kwargs = (; color = ...))`, or the `beam_kwargs` of `live_view`;
`(; color = :wavelength)` or `(:wavelength, alpha)` are accepted). A view may start
without a source: `live_view(System())`, or `live_view(sys1, sys2 => beam)`.
The catalog "Components" does the same with the mouse: a movable window over the 3D view, opened
at the mouse with the key `Insert` or with the toggle "Components" among the tools; it closes after
the drop unless its pin is on, and its chevron minimizes it. With `layout = :app` it is docked in
the left sidebar (section "Components"), from where its buttons move it into the window and back. Its
line "into" names the system that gets the entry (of the selection, else the first one) and is a menu
of the systems in a view with several systems. Its icons select a
group (sources, lenses, mirrors, curved mirrors, beamsplitters, prisms, polarizers, detectors), its tiles a
component (all components of BeamletOptics with a constructor of numbers and glasses) or a source
(`Beam`, `GaussianBeamlet`, `CollimatedSource`, `UniformDiscSource`, `PointSource`,
`UniformPointSource`, `AstigmaticGaussianBeamlet`; placed along +y, then rotated with the controls), its form takes
the numbers and the glass: one of `catalog_glasses()` (N-BK7, fused silica, CaF2, N-SF11, N-SF10,
N-SF6HT, N-SF5, N-F2, N-BAF10, N-LAK22, as `SellmeierEquation`s) or "constant" with a number. "Place"
attaches the chosen component to the mouse, a click drops it, `Esc` cancels, `Delete` removes the
selected component or source. It moves in the plane of the table (perpendicular to `rotation_axis`,
at the height of the source of its system) and snaps onto beams while `snap` is on; the first component or source of
an empty view is placed at the origin. `export_changes` writes a glass as `SellmeierEquation(...)` and a constant
refractive index as `λ -> n`; an added source is its constructor at the origin along +y, its
`rotate3d!`/`translate_to3d!` and `solve_system!(system, name)`, a removed source of the start a comment.

`kinematic_controls!(ax, hsys; on_change, constraints, rotation_axis, fine_step)` adds the mouse and
keyboard controls to a live-rendered system on its own, without `live_view`. In the rotate mode a
mouse drag on a ring of the gizmo (highlighted under the cursor) rotates the selected component around
that ring, e.g. to tilt it out of the table plane; locked rings (`constraints`) can not be dragged, a
drag elsewhere on the selection rotates around `rotation_axis` as before. In the move mode a drag on
an arrow of the gizmo moves the component along that arrow only, a drag elsewhere on the selection
in the plane of the view.

## Scripting a window

Never change an object of a window with the plain verbs (`translate3d!(lens, d)`): the window is not
told and neither the drawing nor the beams follow. Use the verbs with the window first, which do
what a gesture does (redraw, selection box, cards, solve like a drag, one undo entry, constraints;
static objects throw `ArgumentError`):

```julia
translate3d!(gui, lens, [0, 1e-3, 0]);  translate_to3d!(gui, lens, [0, 0.12, 0])
rotate3d!(gui, mirror, [0, 0, 1], deg2rad(2))   # or rotate3d!(gui, mirror, R)
select!(gui, lens); select!(gui, nothing)       # like a click
spectator!(gui, true)                           # like the key v
wait_solve(gui)                                 # solve in the background shown, deferred solves done
```

Screenshots and videos: `spectator!(gui; help = false, background = :black, cards = false, view_cube = false)`
hides all chrome but the 3D view (no cropping of status line, help or "⋯" needed; `spectator!(gui, false)`
restores it with the selection from before, the key `v` leaves it; `help = true`, the default, keeps the
help pill, as the key `v` does, `Shift+V` in the window is `help = false`).
`Makie.record(gui, "x.mp4", iter; framerate, px_per_unit) do i ... end` (method for a live view) runs
`f(i)`, waits for the solve and writes a frame offscreen, in the spectator mode without help unless
`spectator = false`; do not record while the window is open.

Call `wait_solve(gui)` before reading detectors or saving an image. Never use `BeamletOpticsGUI._x`
internals or `gui.controls.on_change` for this.

## Rules

- Everything is SI (meters, radians); cards show mm and mrad and convert.
- Changes of the optics from own controls go through `retrace!(f, gui)`, never directly.
- The card functions are `BeamletOpticsGUI.card_rows` etc., not `BeamletOptics.card_rows`.
- The window needs a display. On headless Linux use `xvfb-run -a`; there is no CairoMakie fallback.
