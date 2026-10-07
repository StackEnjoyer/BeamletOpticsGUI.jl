# View cube

[`view_cube!`](@ref) adds a small CAD-style cube to a corner of an `LScene`. The cube rotates
with the camera and shows the current orientation of the scene. A left click on a face, an edge or
a corner of the cube moves the camera to the corresponding standard view in a short animation,
while the point the camera looks at and its distance are kept. The region under the cursor is
highlighted.

```julia
using BeamletOptics, BeamletOpticsGUI, GLMakie

fig = Figure()
ax = LScene(fig[1, 1])
render!(ax, system)
cube = view_cube!(ax; size = 110, corner = :top_right)
display(fig)
```

The camera is placed on the side of the clicked face and looks at the system from there:

| Face     | Camera at | Up   |
|:---------|:----------|:-----|
| `Top`    | `+z`      | `+y` |
| `Bottom` | `-z`      | `+y` |
| `Front`  | `-y`      | `+z` |
| `Back`   | `+y`      | `+z` |
| `Right`  | `+x`      | `+z` |
| `Left`   | `-x`      | `+z` |

The 12 edges and 8 corners give the diagonal views between the adjacent faces, e.g. the corner
between `Top`, `Front` and `Right` looks from `(1, -1, 1)`, with `+z` as the up direction. The
transition takes `duration = 0.3` s, `duration = 0` switches the view instantly. The cube is not
affected by zooming or by clip planes. Call `close(cube)` to remove it. The
[live view](@ref "Live view") shows a view cube by default, which is disabled via
`live_view(system, beam; view_cube = false)`.

