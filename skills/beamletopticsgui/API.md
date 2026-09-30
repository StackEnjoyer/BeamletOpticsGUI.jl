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
```

Look up the docstring of any name before use, e.g.
`julia --project=<env> -e 'using BeamletOpticsGUI; display(@doc live_view)'`. Do not invent keywords.

## Exported names (by category)

| Category | Names |
|----------|-------|
| Window | `live_view`, `export_changes`, `retrace!` |
| Interactive helpers | `kinematic_controls!`, `view_cube!` |
| Extending the window | `add_panel!`, `add_controls!`, `add_tool!` |
| Cards | `card_rows`, `pose_card_rows`, `beam_card_rows`, `card_actions`, `CardRow`, `CardWidget`, `card_input`, `card_show!` |

Not exported: `BeamletOpticsGUI.install_agent_skill`.

## `live_view` keywords (the frequent ones)

| Keyword | Meaning |
|---------|---------|
| `layout = :compact` or `:app` | the window layout (the app layout has a tree, an inspector, a dock and a toolbar) |
| `theme = :light` or `:dark` | colors of the whole window |
| `labels = Dict(obj => "name")` | names in cards, status line and menus |
| `constraints = Dict(obj => (; move = (), rotate = (:x, :v)))` | lock axes of components |
| `detectors = :auto`, a vector (`pd => :spot`, `pd => (:intensity, (; x_min, ...))`) or `[]` | detector panels |
| `sliders = ["label" => (range, callback)]` | custom parameters (callbacks in SI units) |
| `on_change = (gui, obj) -> ...` | called after each full solve, with the moved object or `nothing` |
| `extras = [housing => (; color = ...)]` | shown, movable, but never traced |
| `clip_planes`, `clip_beams` | clip planes (`point => normal`) |
| `auto_trace`, `trace_budget`, `idle_delay`, `preview`, `progress_delay` | when and how the systems are solved (`auto_trace = false` also starts untraced, `t` traces) |
| `beam_kwargs = Dict(source => (; render_every = 50))` | `render!` keywords per source; `show_polarization`, `show_beams`, `pol_λ`, `pol_amplitude`, `pol_scale` set the start state of the card toggles and sliders |
| `beams_off = [src]` | beams that start off (not solved, not drawn; the card toggle "on" switches them) |
| `views`, `orthographic`, `view_cube`, `show_sources`, `movable_sources` | camera and markers |

`kinematic_controls!(ax, hsys; on_change, constraints, rotation_axis, fine_step)` adds the mouse and
keyboard controls to a live-rendered system on its own, without `live_view`.

## Rules

- Everything is SI (meters, radians); cards show mm and mrad and convert.
- Changes of the optics from own controls go through `retrace!(f, gui)`, never directly.
- The card functions are `BeamletOpticsGUI.card_rows` etc., not `BeamletOptics.card_rows`.
- The window needs a display. On headless Linux use `xvfb-run -a`; there is no CairoMakie fallback.
