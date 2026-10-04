# Kinematic controls

All examples on this page assume `using GLMakie, BeamletOptics, BeamletOpticsGUI` and a live-rendered system `hsys` in an `LScene` `ax`, see `live_render!` in BeamletOptics.

With [`kinematic_controls!`](@ref), the components of a live-rendered system can be grabbed and
moved with the mouse. The `on_change` callback is invoked (at most once per frame) after every
change and is the place to re-solve the system and update dependent plots:

```julia
ctrl = kinematic_controls!(ax, hsys; on_change = obj -> begin
    empty!(detector)
    solve_system!(system, beam)
    update_render!(hbeam)
end)
```

A click selects a component, a drag on the selected component moves or rotates it, and every
other drag rotates the camera as usual, so that rotating the camera never selects or moves a
component by accident. The keyboard controls apply to the selected component and depend on the
mode, which is switched with `m`:

| Input                                   | Move mode                     | Rotate mode                   |
|:----------------------------------------|:------------------------------|:------------------------------|
| Left-click on a component               | Select it                     | Select it                     |
| Left-drag on the selected component     | Move in the plane of the view | Rotate around the ring that faces the camera |
| Left-drag elsewhere                     | Rotate the camera             | Rotate the camera             |
| `↑` / `↓`                               | Move along the green arrow    | Rotate around the red ring    |
| `→` / `←`                               | Move along the red arrow      | Rotate around the blue ring   |
| `Page Up` / `Page Down`                 | Move along the blue arrow     | Rotate around the green ring  |

| Input                        | Action                                                          |
|:-----------------------------|:----------------------------------------------------------------|
| `m`                          | Switch between the move and the rotate mode                     |
| Shift (held)                 | Ten times the step size                                         |
| `+` / `-`                    | Increase / decrease the step size along the 1-2-5 sequence      |
| `Backspace`                  | Reset the selected component to its initial pose                |
| `Ctrl`/`Cmd` + `Z`           | Undo the last change                                            |
| `Ctrl`/`Cmd` + `Y`           | Redo, also `Ctrl`/`Cmd` + `Shift` + `Z`                         |
| `Esc`                        | Select the enclosing group, or deselect at the top level        |
| Left-click on empty space    | Deselect                                                        |
| `v`                          | Switch the spectator mode on or off                             |
| `h`                          | Show or hide an overlay of all controls                         |

In the spectator mode, the selection is cleared and all mouse and keyboard input goes to the
camera, such that the system can be viewed without moving a component by accident. In
[`live_view`](@ref), the spectator mode also hides the user interface besides the 3D view and the
help. Components
whose kinematic trait is `Static` can not be selected.

The selected component is marked by a box and three axes above it: its local y-axis (green), its
local x-axis (red) and the vertical rotation axis (blue). If a local axis is parallel to the
rotation axis, e.g. the local x-axis of a `CollimatedSource` along +y, the axis perpendicular to
the other two takes its place, such that the component can be moved in all directions. In the move mode the axes are shown as
arrows, in the rotate mode as rings. The first key of each pair moves the component in the
direction of the arrow, or rotates it in the direction of the ring. The current mode and step
size are shown in the hint line at the top of the 3D view.

A drag in the rotate mode follows the camera like a drag in the move mode: the component turns
about the axis whose ring faces the camera, and a move of the mouse to the right turns it
counterclockwise on the screen, from whichever side the camera looks. Seen from above, also in an
oblique view (more than 30° above the table), it turns on the table, about the blue axis; seen from
the front or from the side, about the green or red axis along which the camera looks, e.g. a mirror
seen from the side tilts. The axis is taken at the start of the drag, and only its ring keeps its
color meanwhile. With a `plane_normal`, the drag always rotates about the blue axis.

Clicking a component inside an `ObjectGroup` selects the outermost group first. Clicking the same
component again descends one level into the hierarchy (a subgroup, then the individual object),
so that the group can still be moved as a whole, or a single part can be moved on its own. `Esc`
goes back up one level.

A drag grabs the point under the cursor, which stays under the cursor during the drag: the
component moves in the plane of the view, i.e. the plane through the grabbed point perpendicular to
the direction in which the camera looks. Seen from above, it moves on the table; seen from the
front, it moves sideways and in height, which is easiest in an orthographic view along an axis (see
the view cube). In an oblique view, a drag changes the height as well; the keyword
`plane_normal`, e.g. `plane_normal = [0, 0, 1]`, moves the components in a fixed plane instead,
and the `constraints` below lock axes. Each drag,
reset and series of steps with the same key (less than 1 s apart) is one entry of the undo history,
which undoes up to 100 changes. In a [`live_view`](@ref), adding, removing and changing a component
or source are entries of the same history. `Ctrl+Z` and `Ctrl+Y` are the keys with these letters in
the keyboard layout, e.g. on a German keyboard, where the two are swapped.

The `constraints` lock axes of individual components, e.g. a mirror in a kinematic mount that can
only be tilted. The axes are named after the gizmo: `:x` (red), `:y` (green) and `:v` (blue, the
`rotation_axis`). Missing fields allow all axes, locked axes are shown faded:

```julia
ctrl = kinematic_controls!(ax, hsys; constraints = Dict(mirror => (; move = (), rotate = (:x, :v))))
```

Call `close(ctrl)` to remove the controls.

