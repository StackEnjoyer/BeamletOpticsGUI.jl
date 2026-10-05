# Live view

All examples on this page assume `using GLMakie, BeamletOptics, BeamletOpticsGUI` and a `system` and `beam` (or beam group `source`) built with BeamletOptics.

[`live_view`](@ref) combines `live_render!`, [`kinematic_controls!`](@ref), cards with detector
views and optional sliders into a single ready-to-use window. It is the fastest way to explore
the sensitivity of a system in the REPL: grab a mirror, watch the beam path and the detector
views update live.

```julia
using GLMakie, BeamletOptics, BeamletOpticsGUI

gui = live_view(system, beam)
display(gui)
```

With GLMakie, `display(gui)` opens the window without SSAO and with up to 60 fps, since SSAO (e.g.
enabled globally via `GLMakie.activate!(ssao = true)`) multiplies the frame time with large meshes
such as a housing, and GLMakie's default of 30 fps makes rotating the view sluggish. Screen settings
passed to `display(gui; ...)` override these defaults. For static renders with SSAO, pass it to the
display of that figure only, e.g. `display(fig; ssao = true)`.

A [view cube](@ref "View cube") in the top right corner of the 3D view switches to the standard
views with a click, clicks on the cube never select or deselect a component. The live view starts
in the isometric view from the corner between `Top`, `Front` and `Right`, i.e. from `(1, -1, 1)`,
such that the labels of the cube read correctly. The "orthographic" toggle of the camera popover
(compact layout, shown below the cube while the mouse is over it) or of the toolbar (app layout)
switches between perspective and orthographic projection, `orthographic = true` starts with the
latter. Moving along the view direction does not change an
orthographic view, there `W`/`S` zoom like `U`/`O`:

```julia
gui = live_view(system, beam; orthographic = true)
```

With `layout = :compact` (default), the 3D view fills the window; the panels of
[`add_panel!`](@ref), if there are any, form a column on its right. Everything else appears on
demand over the 3D view:

- a help pill at the top left ("? h keys"); a click on it or the key `h` opens the help card
  below it, which lists the keys and mouse actions in sections (select, move or rotate, edit, view,
  clip planes, trace, own tools), the keys as key caps; the 3D view stays usable while it is open.
  The chips right of the pill show the mode and the keyboard step; a click on the mode switches it
  (`m`), "+" and "−" change the step. In the spectator mode (`v`), a chip names it and its button
  leaves it. The spectator mode shows only the 3D view with this help: the tools, the status,
  the view cube, the cards (and with them the detector views), the markers of the sources and the panels of [`add_panel!`](@ref) are hidden, in the app layout also the toolbar,
  the sidebars, the dock and the status bar, such that the 3D view fills the window. Only the
  progress window of a running trace stays, with its "Cancel". Leaving the mode shows everything
  as it was, e.g. a sidebar that was collapsed stays collapsed, and selects the object again that
  was selected before. `Shift+V` enters the mode without this help, such that only the 3D view is
  left, e.g. for a screenshot; `v` leaves it. A view can start in the mode with `spectator = true`.
- the button "⋯" at the bottom left opens the tool rail: Trace (`t`), Auto trace, Sources (`1`),
  Clip beams, Measure, Show all, the component menu ("select component"), Export, then the tools
  of [`add_tool!`](@ref), one entry per section of [`add_controls!`](@ref) and the entry "Sliders"
  for the `sliders`. Such an entry opens its widgets in a popover next to the rail. `Esc`, "⋯" or
  a click outside close the rail (`Esc` closes an open popover first).
- the mouse over the view cube shows the camera popover below it: home, fit (`g`), the views menu,
  save view and orthographic; it hides 0.3 s after the mouse left the cube and the popover
- the status line and the info label (last solve, rays, projection) appear as a toast at the bottom
  for 3 s after each change

The floating cards keep off the pill, the chips, the open help card, "⋯", the open rail and the
popovers.

The app layout (`layout = :app`) has the same help pill, chips and help card at the top left of its
3D view.

More than one `system => beam` pair can be shown in the same 3D view, e.g. the transmitter and
receiver path of a lidar, which are solved with different sources:

```julia
gui = live_view(system_tx => beam_tx, system_rx => source_rx)
```

A system can also be shown without a source, e.g. an empty table `live_view(System())`: its sources
are added in the window, from the group "Sources" of the catalog, or from code, see
[Adding and removing components](@ref components_page).

## Movable sources in the live view

Each source, i.e. the beam or beam group of each `system => beam` pair, is shown with an orange
marker at its position, which points along its direction. A source is selected and moved via its
marker like any component, after which the systems are solved again. For a beam, which only has a
direction, the green axis is its direction. If a marker covers small components, the "Sources"
toggle of the tool rail (or the toolbar) or the key `1` hides all markers and shows them again, `show_sources =
false` starts with hidden markers. Pass `movable_sources = false` to omit the markers altogether.

## Extras and static context

Objects that are not part of any `system`, e.g. a housing from a CAD file, are passed as `extras`,
each optionally with the kwargs of its `render!` call:

```julia
housing = MeshDummy("housing.stl")
gui = live_view(system => beam; extras = [housing => (; transparency = true, color = (:gray, 0.3))])
```

Extras are never traced, so they cost nothing in the solves, and moving them does not solve the
systems. Otherwise they act like components: they are selected with a click, in the component menu
or in the object tree (under "Extras"), moved, hidden and exported. They do not block clicking on
the optics behind them: objects are picked by intersecting the camera ray with the optical
components first, which a `NonInteractableObject` never intersects. The card of a
`NonInteractableObject` (e.g. a `MeshDummy`) or an `IntersectableObject` has an "opacity" slider,
which makes it transparent without changing the optics; 0 % hides it. Below 50 % opacity, a click
in the 3D view passes through such an object, i.e. a click into the empty space inside a
transparent housing does not select the housing; select it in the object tree or the component
menu instead. Visible extras count towards the size of the scene, which sets the size of the
source markers and of new clip planes and the view of "fit all" (`g` without a selection).

Plots added directly to `gui.ax` via `render!` are only drawn, i.e. they are neither selectable nor
hideable:

```julia
render!(gui.ax, housing_mesh; transparency = true, color = (:gray, 0.3))
```

## Clip planes

Clip planes cut the 3D view open, e.g. to look into a housing or behind a component. Only the side
of a plane its normal points to stays visible. `p` adds a plane through the selected component, or
through the point the camera looks at if nothing is selected, with its normal along the view
direction. A plane is selected via the purple handle at its center and moved and rotated like a
component, its normal is the green axis. Moving a plane does not solve the systems.

| Input      | Action                                                  |
|:-----------|:--------------------------------------------------------|
| `p`        | Add a clip plane and select it                          |
| `Delete`   | Remove the selected clip plane (or the selected component, see [Adding and removing components](@ref components_page)) |
| `c`        | Switch clipping on or off (all planes)                  |
| `Shift+c`  | Flip the selected clip plane, i.e. show the other side  |

Planes can also be given at construction as `point => normal`. The beams are not clipped unless
`clip_beams = true` or the "Clip beams" toggle of the tool rail (or the toolbar) is switched on, the markers of
the sources and planes are never clipped:

```julia
gui = live_view(system, beam; clip_planes = [[0, 0.1, 0] => [0, 1, 0]], clip_beams = true)
```

Makie supports at most 8 clip planes. The selection box of a partly clipped component only covers
its visible part.

## Detector view

The results of a detector are on its card. Every card has pages, chosen by a page bar below its head: "Pose" (the rows of
[`card_rows`](@ref); on the card of the selection also the keyboard step and the Move/Rotate mode)
and "Properties" (the property list of the object, see `properties`). The card of a `Detector`
has a third page, "Results", between them, which shows the detector view. The card of a source (a
beam, a beam group or a Gaussian beamlet) has the page "Color": a menu sets the color in which it is
drawn ("wavelength" for the color of its wavelength, in which every source starts, "layout" for the
color of the layout, or a fixed color), a box takes any color as a hex value such as `#ff8000` or
by its name, a slider sets the opacity, e.g. to see the components through the envelope of a
Gaussian beamlet, and another one the line width of its rays. They only change the display: nothing
is traced again, and they are not part of [`export_changes`](@ref). In a script,
`beam_kwargs = Dict(source => (; color = :orange, alpha = 0.5, linewidth = 2))` sets them from the
start. A card with a single
page, e.g. of an inspected point or a measurement, has no page bar. A card opens on "Results" for a
detector and on "Pose" for every other object; a pinned card keeps its page.

The view is expanded by default. Its chevron collapses it to a thumbnail (92 px) with the kind,
the key value (the power or the number of rays), the centroid and the radii; a click on the
thumbnail or on its chevron expands it again. The expanded view has:

- a switch of the kinds that the hits of the last solve offer, the toggles "log" and "profiles"
  (field views only) and the button "fit"
- the plot in mm with equal scales, the y axis on the right, the ticks, tick labels and axis names
  inside the frame, and the centroid as a red cross
- the metrics in two lines below the plot

"profiles" adds an axis with the intensity along x (red) and z (blue) through the centroid.

The kinds depend on the hits, the first is the default:

| Hits | Kinds |
|:-----|:------|
| rays (`RayHit`, `PolarizedRayHit`) | "Spot" (spot diagram), "PSF" (the `intensity` of the rays, which BeamletOptics returns unscaled, hence shown normalized to its peak, with the metrics without the power) |
| Gaussian beamlets (`GaussianBeamletHit`, `AstigmaticGaussianBeamletHit`) | "Intensity" (in W/m², with the power), "Spot" (the 1/e² outlines) |

A chosen kind that the current hits do not offer falls back to their default and applies again
when they offer it. Without hits, the view reads "no hits". The metrics, with the centroid marked
by a red cross, are for alignment:

- spot diagram: the number of hits `N`, the centroid `c`, the RMS radius `sqrt(mean(|p - c|²))`
  and the geometric radius, i.e. the largest distance from the centroid
- intensity: the power `P`, the peak intensity, the centroid `c` and the 1/e² radii `w` along x
  and z, i.e. twice the standard deviation of the intensity along each axis
- PSF: as the intensity, but without the power

In the expanded view, the mouse acts like on an `Axis` of Makie: the wheel zooms about the cursor,
a drag with the left button selects the rectangle to zoom to (of the shape of the plot, i.e. a
square in a square plot), a drag with the right button pans, and Ctrl + click, a double click or
"fit" resets the view. In a spot view, this only changes the limits. In a PSF or intensity view, the
field is recomputed for the visible window on the full grid `n` once the mouse rests for
`idle_delay`, not per wheel step. The cost of one field is proportional to `n² ·` the number of
hits, about 14 ns per pixel and hit on one thread, e.g. about 150 ms for `n = 100` and 1000 ray
hits, but about 9 ms with 32 threads. Start Julia with `julia -t auto` to use the threads. Long
computations run in the background with the progress window and its "Cancel", like long solves;
computations slower than `trace_budget` show a coarse preview first.

Only shown views are computed: the page "Results" of the card of the selected detector or of a
pinned card that is not collapsed. A thumbnail is computed on a grid of at most 48 points per
axis. A view that is shown later is computed from the hits of the last solve. The spectator mode
hides the cards and with them the views.

The floating card with an expanded view is resizable: a grip at its bottom right corner changes
its size from 160 px up to the size of the 3D view. In the sidebar of the app layout, the view
takes the width of the sidebar, is as high as wide and has no grip; the sidebar scrolls with the
mouse wheel if its cards are higher than the window, and the float button moves a pinned card with
its view into the 3D view.

By default (`detectors = :auto`, or `[]`), every `Detector` of every system, deduplicated by
identity, has its page "Results", and no card is pinned at start. A vector pins the cards of
these detectors at start, floating next to the detector in the compact layout and docked in the
right sidebar in the app layout, and sets their options; a listed detector that is not part of
the systems throws an `ArgumentError`:

```julia
gui = live_view(system, beam; detectors = [pd1, pd2 => :spot, pd3 => (:intensity, (; n = 200))])
```

`kind` is `:auto` (default, the first kind of the hits), `:spot`, `:psf` or `:intensity`. The
`kwargs` of the `pd => (kind, kwargs)` form are options of the view or are passed to `intensity`;
most useful is a fixed extent via `x_min`, `x_max`, `z_min` and `z_max` (in meters, like the rest
of this package), which is the area that "fit" shows, instead of the automatic crop around the
beam. The following options are not passed to `intensity`:

| Option                  | Effect                                                               |
|:------------------------|:---------------------------------------------------------------------|
| `n = 100`               | grid points per axis of a field                                      |
| `colorscale = :linear`  | `:log` shows `log10` of the intensity, with a floor of 1e-4 times the maximum |
| `colorrange = nothing`  | `(lo, hi)`: fixed color range of the intensity (in `log10` units for `:log`) |
| `profiles = false`      | `true` adds the axis with the intensity along x and z through the centroid |
| `expanded = true`       | `false` starts the pinned card with the thumbnail                    |

```julia
gui = live_view(system, beam; detectors = [pd => (:intensity, (; colorscale = :log, profiles = true))])
```

The option `history` is no longer available and throws an `ArgumentError`: record the values in
`on_change` and plot them in a panel of [`add_panel!`](@ref), see [Own panels, controls and tools](@ref)
and the [Interactive Michelson interferometer](@ref) example.

## Sliders

`sliders` adds custom parameters: in the compact layout the entry "Sliders" of the tool rail, which
opens them in a popover, in the app layout the section "Parameters" of the left sidebar. Each entry is `"label" => (range, callback)`
(or `(range, callback, startvalue)`); `callback` is called with the current slider value and is
expected to move objects or otherwise change the system:

```julia
gui = live_view(system, beam;
    sliders = ["focus [mm]" => (-1:0.01:4, v -> set_focus(cl, v * 1e-3))])
```

Since this package uses SI units throughout, a slider that is labeled and ranged in millimeters
for convenience must convert its value before applying it, as in `v * 1e-3` above.

## Custom updates

`on_change = (gui, obj) -> ...` is called after every full solve, with the moved object or
`nothing` (initial solve, or after a slider change). It is not called after the preview solves of
beam groups while moving, see [Manual tracing](@ref), but once the full solve follows. Use it to
record derived quantities, e.g. the optical power on a detector over time, which an own panel
plots, see [Own panels, controls and tools](@ref):

```julia
power = Point2f[]

function record_power!(gui, obj)
    push!(power, Point2f(length(power) + 1, 1e3 * optical_power(pd)))
    return nothing
end

gui = live_view(system, beam; on_change = record_power!)
```

Errors raised inside `on_change` are logged once and do not interrupt the interaction. See the
[Interactive Michelson interferometer](@ref) example for a full callback that tracks the optical
power over time.

## Own panels, controls and tools

Own parts are added to a `gui = live_view(...)` by three functions, which work with both layouts;
the layout decides where the parts go:

| function | `layout = :compact` | `layout = :app` |
|:--|:--|:--|
| [`add_panel!`](@ref) | a column right of the 3D view, created by the first panel | a tab of the analysis dock, which stays collapsed until the first panel exists |
| [`add_controls!`](@ref) | an entry of the tool rail that opens the controls in a popover | a section of the left sidebar, below "Parameters" and "Components" |
| [`add_tool!`](@ref) | an entry (icon and name) of the tool rail | an icon button (or toggle) at the end of the toolbar |

`add_panel!(f, gui, title)` calls `f(layout)` with the `GridLayout` of the new panel, into which it
builds e.g. an `Axis` with plots. The function returned by `f` is called with the `gui` after each
full solve, like `on_change`, and once right away. In the app layout, only the panel of the shown
tab is updated, hidden panels when their tab is opened, i.e. hidden panels cost nothing. The new tab
stays in the background unless `select = true`:

```julia
add_panel!(gui, "Optical power") do layout
    ax = Axis(layout[1, 1]; xlabel = "Update", ylabel = "P [mW]")
    pts = Observable(copy(power))
    lines!(ax, pts)
    return gui -> (pts[] = copy(power); autolimits!(ax))
end
```

Data that must be recorded after every solve, also while the panel is hidden, is recorded by
`on_change`, as above, and only plotted by the panel. In the compact layout, the panels are placed
in a grid in `gui.fig[1, 2]`, but only `add_panel!` works with both layouts.

`add_controls!(f, gui, title)` calls `f(layout)` to build widgets, e.g. buttons, menus and
textboxes. While a textbox of the controls is focused or a menu is open, the keys of the 3D view and
the camera are ignored, as for the boxes of the live view. A change of the optics from such a
widget calls [`retrace!`](@ref), which solves the systems again like after a slider of the
`sliders` kwarg (or marks the beams as outdated with `auto_trace = false`); the change itself goes
into its first argument, since objects must not change while a solve runs in the background. Like
the builder of `add_panel!`, `f` may return a function `update(gui)`, which is called after each
full solve and once right away, e.g. to show the current value of a parameter. Controls are meant
for parameters without a scene object; the widgets of an object belong on its card, see
[Cards and widgets](@ref):

```julia
add_controls!(gui, "Mirror") do layout
    box = Textbox(layout[1, 1]; placeholder = "tilt [mrad]", width = 100)
    on(box.stored_string) do s
        θ = tryparse(Float64, s)
        isnothing(θ) || retrace!(() -> zrotate3d!(m1, 1e-3 * θ), gui)
    end
end
```

`add_tool!(f, gui, name)` adds a button that calls `f(gui)`, with `toggle = true` a toggle that
calls `f(gui, active)`. In the app layout, it is an icon of the toolbar (`icon`, e.g. `:measure`,
`:export` or `:chart`, an unknown name lists the valid ones, or an own `Makie.BezierPath`) with a
`tooltip`. `key` binds a key of
the 3D view to the tool; keys that the live view, the kinematic controls or the camera use (all
letters) throw an `ArgumentError` naming the binding, e.g. the digits `2`–`9` or the function keys
are free:

```julia
add_tool!(gui, "Center m1"; icon = :fit, key = Keyboard._2) do gui
    retrace!(() -> translate_to3d!(m1, [0, 0.1, 0]), gui)
end
# Shows or hides a reference line along the optical axis
ref = lines!(gui.ax, [Point3f(0, 0, 0), Point3f(0, 0.3, 0)]; color = :gray, visible = false)
add_tool!(gui, "Optical axis"; toggle = true, key = Keyboard._3) do gui, active
    ref.visible[] = active
end
```

## Scripting the live view

Demos, tutorials and tests drive a window from code. Changing an object directly, e.g.
`translate3d!(lens, offset)`, leaves the window unaware: neither the drawing nor the beams follow.
The verbs of BeamletOptics with the window as first argument do what a gesture of the user does:
the drawing, the selection box and the cards follow, the systems are solved like after a drag
(respecting `trace_budget` and `auto_trace`), the `constraints` apply, static objects throw an
`ArgumentError`, and each call is one entry of the undo history. [`select!`](@ref) and
[`spectator!`](@ref) act like a click and the keys `v` and `Shift+V`, and [`wait_solve`](@ref)
waits until the solve in the background is shown.

```julia
gui = live_view(system, beam)
display(gui)
select!(gui, lens)
for Δ in range(0, 5e-3, 20)
    translate_to3d!(gui, lens, [0, 0.1 + Δ, 0])
    wait_solve(gui)
end
rotate3d!(gui, mirror, [0, 0, 1], deg2rad(2))
spectator!(gui, true)
```

## Screenshots and recording

For screenshots and videos, [`spectator!`](@ref) with `help = false` hides everything but the 3D
view (tools, status line, help, cards, view cube, selection box and the sidebars of the app
layout), optionally with another `background` and with the pinned cards or the view cube kept, and
restores the window when switched off. `Makie.record` with a live view renders a video offscreen,
in this mode: `f(i)` changes the window for each element of `iter`, then the solve is awaited and a
frame is written.

```julia
spectator!(gui; help = false, background = :black, cards = true)  # keep the pinned detector cards
wait_solve(gui)
save("setup.png", gui.fig; px_per_unit = 2)
spectator!(gui, false)

Makie.record(gui, "move.mp4", range(0, 5e-3, 60); framerate = 30, px_per_unit = 2) do d
    translate_to3d!(gui, lens, [0, 0.1 + d, 0])
end
```

## Manual tracing

Solving a large system on every mouse-drag event can be too slow for smooth interaction. With
`auto_trace = false`, `live_view` still updates the 3D view and the sliders immediately, but only
solves the systems (and updates the beams and detector views) on request: the `Trace (t)` button
of the tool rail (compact layout) or the toolbar (app layout), the key `t`, or switching the "Auto trace" toggle back on (which solves once if
the state is outdated). While outdated, the beam plots are dimmed and the status line shows a
hint. With `auto_trace = false`, the view also starts untraced, with the hint "not traced, press t
to trace" in the status line, such that a slow system opens right away.

With `auto_trace = true`, `live_view` adapts to slow systems as well: if solving takes longer than
`trace_budget` (30 ms by default), the components still follow the mouse immediately, while the
systems are solved once the movement pauses for `idle_delay` (0.2 s). Likewise, detector views
that take longer than `trace_budget` show a coarse preview while moving, which is refined once the
movement pauses.

Beam groups, e.g. a source with thousands of rays, are rendered with `render_every = 5` by
default, i.e. only every fifth beam is drawn. While a component is moved, such groups are only
solved for the rendered beams (preview tracing), the other beams are reset and do not hit the
detectors; the kinds of the detector views read "(preview)". Once the movement pauses for
`idle_delay`, the full group is solved. The `trace_budget` applies to the preview solve while
moving, such that large groups stay interactive. `preview = false` always solves the full groups:

```julia
gui = live_view(system, source; beam_kwargs = Dict(source => (; render_every = 50)), preview = false)
```

A beam is switched off and on by the toggle "on" of its card (see the rows of the cards below); a
beam that is off is neither solved nor drawn. The beams in `beams_off` start off, and
`show_polarization = true` in the `beam_kwargs` of a polarized beam starts with its polarization
drawn, like the toggle "polarization" of its card:

```julia
gui = live_view(system => src1, system => src2; beams_off = [src2],
    beam_kwargs = Dict(src1 => (; show_polarization = true)))
```

Solves longer than `progress_delay` run in the background with a progress window next to the
source or detector, connected to it by a line, see "Long solves" in the docstring of [`live_view`](@ref).

If a solve fails, a card "Solve failed" opens in the 3D view, in addition to the log and the status
line. A detector stores one kind of hits per solve: if it is hit by two kinds of beams, e.g.
polarized and unpolarized rays, the card is placed at the detector and names both kinds; switching
one of the beams off by its card or giving it its own detector solves it. See "Failed solves" in
the docstring of [`live_view`](@ref).

## Component card and component menu

Selecting a component, source or clip plane opens a card next to its bounding box in the 3D view,
connected to it by a line. The card follows the camera and the component and stays inside the
view, off the view cube and the other cards. With `theme = :light` (default) or `:dark`, the whole
window has the colors of the theme, i.e. the cards, the menus, the buttons and the status line, in
the compact layout as well as in the app layout. Objects without an entry in `labels` are named by
their type and a running index, e.g. "Mirror 1" or "Clip plane 2", in the card, the status line and
the menus, like in the object tree of the app layout:

- The head shows the icon of the kind of the component, its label and "hide", which hides it, e.g. a mirror in front of
  the component of interest, and clears the selection. A hidden component can not be selected in
  the 3D view, but stays in the systems, i.e. it is still traced. Selected in the menu, its card
  reads "show", which shows it again. For a clip plane, the head holds "flip" and "remove".
- `x`, `y`, `z` [mm] show the position of the component. Typing a value and pressing `Enter`
  moves the component to this absolute coordinate. The boxes `rx`, `ry` and `rv` [mrad] rotate it
  by the typed angle about the red, green and blue axis of the controls, like the arrow keys in the
  rotate mode, e.g. `rv = 1` equals one key step with a step of 1 mrad. Each input is a step of the
  undo history, the constraints of the component apply. While a box is focused, the keys of the 3D
  view are ignored.
- On the page "Pose", the card of the selected object has, below its rows, the `step` box of the keyboard step, see
  below, and the "Move"/"Rotate" control, which shows the mode of the controls and sets it, and
  follows the key `m` and vice versa. A pinned card has them while its object is selected.
- A page bar below the head chooses the page of the card: "Pose" (the pose boxes and the rows
  below), "Properties" (the properties of the object, see `properties`, the same rows as the
  inspector of the app layout) and, for a detector, "Results" (see [Detector view](@ref)). A card
  opens on "Results" for a detector and on "Pose" otherwise; a click on the bar sets the page,
  which stays while the card shows the same object and when the card is pinned, so pinning does
  not change the card. A card with a single page has no bar.
- The chevron at the right end of the head collapses the card to its head and expands it again.
- The pin keeps the card with its component when the selection changes, e.g. to watch or type the
  poses of several components; the widgets of a pinned card act on its component. Clicking the
  pin again closes it.
- Dragging the head (icon, label or the free room around them) moves the card to another place in
  the view, e.g. to line up several pinned cards at an edge. It stays there, connected to its
  component by the line, when the camera or the component moves and when it is pinned; the card of
  the selection also keeps its place for the next selected component. The place is kept relative
  to the nearest corner of the view, so a card at an edge stays there when the window is resized.
  A double click on the head places the card next to its component again, as does unpinning it.
- Below the pose on the page "Pose", rows of the component type, refreshed after each solve and move:

  | Component | Rows |
  |:----------|:-----|
  | optical components | `beam`: the rays hitting it in the last solve and the angle of incidence of the first one (e.g. the center ray of a ring source) with the range of all, or "not hit" |
  | lenses, prisms | `n` at the wavelength of the hitting beam, `d` the center thickness (`Lens`) |
  | beamsplitters | `split`: R and T (power) of the coating |
  | polarizers | `axis`: the transmission axis about the optical axis, from the horizontal |
  | detectors | `signal`: the power or the number of rays of its detector view while a view of it is shown, otherwise the number of hits; the switch of the kinds and the toggle "log" are in the view (see [Detector view](@ref)) |
  | ray sources | `λ` and the diameter or NA; sources whose rays can be regenerated (`CollimatedSource`, `PointSource` and their uniform variants, see `set_num_rays!`) add the slider "rays" for their number of rays, which solves again |
  | Gaussian beamlets | `λ`, the waist `w0` and the Rayleigh range `zR` |
  | beams, beam groups, sources, beamlets | `beam`: the toggle "on" switches the beam off and on; a beam that is off is neither solved nor drawn and its rays are removed from the detectors and measurements, only its source marker stays (with `auto_trace = false` the switch marks the beams as outdated). Gaussian beamlets and their groups add the toggle "beams", which draws the generating beams (chief, divergence, waist) like `render!` with `show_beams = true`. Polarized beams (rays of type `PolarizedRay`, astigmatic Gaussian beamlets) add the toggle "polarization", which draws the polarization along the beam, and the sliders `pol λ` and `pol amp` for the wavelength and the amplitude of that curve. Of a beam group, both are drawn for its central beam; they only change the display. The box `length` sets the length [mm] with which the final rays, i.e. those that hit nothing, are drawn (`flen`). See [`beam_card_rows`](@ref) |

The rows and the buttons in the head are declared per type by multiple dispatch, see
[`card_rows`](@ref) and [`card_actions`](@ref): each row is a [`CardRow`](@ref) of texts and
[`CardWidget`](@ref)s, i.e. any `Makie` widget with a function for the value it shows and one for
its input. The card places the widgets, hides them and keeps their clicks and keys from the 3D
view. An own component adds its rows to the pose rows, e.g.

```julia
BeamletOpticsGUI.card_rows(l::MyLens) = (pose_card_rows(l)...,
    CardRow("f", CardWidget(Label; value = (gui, l) -> "$(round(1e3 * focal_length(l); digits = 2)) mm")),
    CardRow("n", CardWidget(Slider; range = 1.4:0.01:1.9, solve = true,
        value = (gui, l) -> refractive_index(l), on = (gui, l, n) -> set_index!(l, n))))
```

where `solve = true` solves the systems again after an input, like a move. The recipes for the card of
an own component or system type, for own widget types and for controls without a scene object are
on the page [Cards and widgets](@ref).

The card of a system shows the number of its objects, the number of rays of its beams that are on
and the duration of the last solve. A system is shown by its entry ("System 1", ...) in the component menu (compact layout) or by
a click on its row in the object tree (app layout), without a selection and without a gizmo, i.e.
`gui.controls.selected[]` stays `nothing`. An object that is not movable is shown in the same way
instead of being selected; its pose boxes reject inputs with a message in the status line. `Esc`, a
click on empty space or the selection of an object closes such a card.

A click in the 3D view on an object of a group opens a small menu under the cursor: "Select <group>",
which lies under the cursor, and "More ›". A second click without moving the mouse selects the
top-level group for moving; until then nothing changes in the 3D view, except the box of the group
while "Select" is marked. "More ›" opens the selection card at the same place, which browses the
parts one level at a time: "Select <group>" selects the group, "‹ <parent>" goes up, a part marked
" ›" opens the next level, any other part is selected. While browsing, the group is see-through and
the boxes of the parts are drawn. A click on a part in the 3D view acts like its entry, a click
beside closes the card, `Esc` goes up one level. More than 5 parts scroll with the mouse wheel;
`↑`/`↓` move the mark, `Enter` chooses the marked entry. A click inside the current selection keeps
it; the card of an object with parts has the button "parts ›" in its head, which opens its selection
card, and the card of a part has a button "‹" that browses its parent. A drag at the head of the
small menu or of the selection card moves it, e.g. off the parts that it covers. An object that is not in a
group opens its card at once. A click on a pinned card beside its widgets selects its object. The standalone [`kinematic_controls!`](@ref) keeps its drill-down (a second click
on a selected group selects the part). See the section "Selection card" of [`live_view`](@ref).

With `live_view(...; layout = :app)`, the cards are docked in the "Properties" sidebar instead of
floating next to the components: the card of the selection at the top, with the same rows and
actions, and below it the pinned cards, one below the other, each with its own head (icon, label,
actions, pin and chevron) and the same pages as a floating card; its state, including its page and
its view, moves with the card when it floats or is docked. The pin of the selection pins
a card, the pin of a pinned card unpins
it. Both sidebars scroll with the mouse wheel if their content is higher than the window, with a
scroll bar at their right edge: the cards keep their full size, the chevron of a pinned card
collapses it to its head. Over the object tree, the wheel scrolls its rows first, and over a
detector view it zooms the view. The float button in the head of
a pinned card moves it out of the sidebar into the 3D view, where it floats next to its component
as in the compact layout; the dock button in its head moves it back. Only the docked cards take
room in the sidebar. The floating cards and the docked cards are built by the same code from the
same declarations.

In the compact layout, the tool rail (the button "⋯") holds the component menu ("select component")
and "Show all". The menu lists the systems,
each entry followed by its movable components and sources, by their `labels` (or automatic names),
the objects of a group indented after the group. Selecting an entry selects the component like a
click in the 3D view, a click in the 3D view shows the selected component in the menu; a system
entry shows the card of the system, see above. The menu can be searched by typing while it is open.
Clip planes are not listed. "Show all" shows all hidden components. The info label with the duration of the last solve (or of
the preview), the number of rays and the projection appears with the status line as a toast at the
bottom of the 3D view for 3 s after each change; in the app layout, it is in the status bar.

## Beam inspection and measuring

A click on a beam, within 6 px of a rendered segment, marks the point on the beam and shows in the
status line its position [mm], the direction of the beam, the geometric path length and the
optical path length (Σ n·L) from the source [mm] and, for Gaussian beamlets, the radius `w` and
the radius of curvature `R` at this point (see `BeamletOptics.gauss_parameters`). Components take
precedence over beams, i.e. a click on a component still selects it. `esc` or a click elsewhere
removes the marker.

The "Measure" toggle of the tool rail (or the toolbar) switches measuring on: two clicks on
components or beams show the distance between the positions of the components or the points of
the beams [mm], its components Δ, and the angle between the optical axes (local y-axes) of two
components, with a dashed line between the points. A third click starts a new measurement,
switching the toggle off clears it.

Both results are also shown on a card at their points in the 3D view, in the style of the
component cards: "Beam" with the rows `at`, `dir`, `path`, `OPL` (and `w`, `R`) and
"Measurement" with `from`, `to`, `d`, `Δ` (and `angle`). The card is replaced by the next
inspection or measurement and removed with it, unless its pin is clicked: a pinned card stays with
its marker or its line until it is unpinned, so several points and distances can be compared. In
the app layout, a pinned result is docked below the inspector like a pinned component.

## Camera tools

| Input       | Action                                                                     |
|:------------|:---------------------------------------------------------------------------|
| `g`         | Zoom to the selected component, or to all systems, keeping the view direction |
| "home"      | Restore the view when the window was shown                                 |
| "views"     | Set one of the saved views                                                 |
| "save view" | Save the current view as `"view n"` and print it as code for `views`       |

Saved views can be passed to the next session via `views`:

```julia
gui = live_view(system, beam;
    views = ["top" => ([0.0, 0.05, 0.5], [0.0, 0.05, 0.0], [0.0, 1.0, 0.0])])
```

## A system in a window of its own

In a view of several systems, one of them can be opened in a second window with its components
and its sources: click the system in the object tree (or choose it in the component menu) and
press "new window" in the head of its card, or call [`open_system`](@ref).

```julia
gui = live_view(interferometer => laser, telescope => star; layout = :app)
window = open_system(gui, telescope)
```

The new window is a live view of the same objects, not of copies, and both windows are linked: a
component or source that is moved, added, removed or edited in one of them changes in the other
one as well. Only the window in which something changed solves the systems, the other one shows
the result. The switch of the auto tracing is shared: switched in one window, it is switched in
the other one as well. The selection, the camera, colors, hidden objects, clip planes and the undo
history are kept per window. Closing one of the windows ends the link.

## Adding and removing components

Components can be added to a `System` of the view and removed again at runtime, from a catalog in
the window or from code with [`add_component!`](@ref) and [`remove_component!`](@ref). See
[Adding and removing components](@ref components_page) and the section of the same name in the docstring of
[`live_view`](@ref).

## Exporting the changes

The "Export" button of the tool rail (or the toolbar) prints the changed poses as Julia code and copies it
to the clipboard, such that an alignment found interactively can be pasted into the script that
builds the system. The tool "Script" next to it prints the whole setup as a script, see
[`export_script`](@ref) and [Adding and removing components](@ref components_page).
[`export_changes`](@ref) returns the same code:

```julia
gui = live_view(system, beam; labels = Dict(m1 => "m1", lens => "lens"))
# move the components, then
code = export_changes(gui)
```

```julia
# Changed poses of the live view, apply to the objects in their initial poses.
# Each rotation is about the position of the object, groups are moved before their objects.

# m1 (Mirror)
rotate3d!(m1, [0.0, 0.0, 1.0], 0.0005)
translate_to3d!(m1, [0.0, 0.1000012, 0.0])
```

Each moved object gets a `rotate3d!` about its own position (only if it was rotated) and a
`translate_to3d!` to its absolute position [m], relative to its pose when the window was opened.
Labels that are valid variable names are used as names, other objects are called `obj1`, `obj2`,
… by their position in the component menu. Clip planes are not exported.

## Controls

The 3D view uses the controls of [`kinematic_controls!`](@ref), see
[Kinematic controls](@ref). In addition, the key `t` solves the systems immediately, see
[Manual tracing](@ref), `p`, `Delete`, `c` and `Shift+c` control the clip planes, see
[Clip planes](@ref), `1` shows or hides the source markers, see
[Movable sources in the live view](@ref), `g` zooms to the selection, see [Camera tools](@ref), and
`Insert` opens the catalog of the components at the mouse, see [Adding and removing components](@ref components_page). `Tab` switches the snapping onto beams: a component that is dragged or placed with the mouse
then snaps onto the central beam of a source, and in the rotate mode
the angle of its optical axis to the beam snaps to the multiples of 45°. Each `Tab` goes to the
next of three states: off, only the position snaps, the position and the rotation snap, and off
again; `Shift`+`Tab` goes the other way round. The chip "Snap" next to the mode at the top left of
the 3D view names the state, and a click on it does the same as `Tab`. The keyword `snap` of
[`live_view`](@ref) sets the start, see the section "Snapping onto beams" of its docstring. The toggle
"Table" among the tools shows an optical table, onto whose holes dragged and placed components
snap beside the beams while the snapping is switched on, see [Aligning on the table and to the beams](@ref). The keyboard step can be typed into the box `step` of the component card, e.g.
`250 nm` or `50 µrad`, where the unit selects the move or rotate mode (`pm`, `nm`, `µm`, `mm`,
`cm` or `m`; `nrad`, `µrad`, `mrad`, `rad` or `deg`), see
[Component card and component menu](@ref). The step is shown in the unit of its size, e.g. `5 mm`,
`1 cm` or `2 mrad`. The status line shows the
pose of the moved component and its change since the window was opened. Names for the status line
and the cards are passed via `labels`:

```julia
gui = live_view(system, beam; labels = Dict(m1 => "Mirror 1", pd => "Photodiode"),
    constraints = Dict(m1 => (; move = ())))
```

A complete example, including a custom `on_change` callback, can be found in the
[Interactive Michelson interferometer](@ref) example.
