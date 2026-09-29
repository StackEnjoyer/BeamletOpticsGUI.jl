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
| Left-drag on the selected component     | Move in the horizontal plane  | Rotate around the blue axis   |
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
camera, such that the system can be viewed without moving a component by accident. Components
whose kinematic trait is `Static` can not be selected.

The selected component is marked by a box and three axes above it: its local y-axis (green), its
local x-axis (red) and the vertical rotation axis (blue). In the move mode the axes are shown as
arrows, in the rotate mode as rings. The first key of each pair moves the component in the
direction of the arrow, or rotates it in the direction of the ring. The current mode and step
size are shown in the hint line at the top of the 3D view.

Clicking a component inside an `ObjectGroup` selects the outermost group first. Clicking the same
component again descends one level into the hierarchy (a subgroup, then the individual object),
so that the group can still be moved as a whole, or a single part can be moved on its own. `Esc`
goes back up one level.

A drag grabs the point under the cursor, which stays under the cursor during the drag. Each drag,
reset and series of steps with the same key (less than 1 s apart) is one entry of the undo history,
which undoes up to 100 changes.

The `constraints` lock axes of individual components, e.g. a mirror in a kinematic mount that can
only be tilted. The axes are named after the gizmo: `:x` (red), `:y` (green) and `:v` (blue, the
`rotation_axis`). Missing fields allow all axes, locked axes are shown faded:

```julia
ctrl = kinematic_controls!(ax, hsys; constraints = Dict(mirror => (; move = (), rotate = (:x, :v))))
```

Call `close(ctrl)` to remove the controls.

