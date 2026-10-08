include(joinpath(@__DIR__, "live_empty_table.jl"))

GLMakie.activate!(; visible = false)
save("live_empty_table.png", gui.fig; px_per_unit = 2)

## A beam expander, built like with the catalog: every part is added as its constructor builds it,
## at the origin, and moved afterwards. `code` is the constructor call for `export_script`
add(obj, code, label) = add_component!(gui, obj; code, label, select = false)

laser = add(CollimatedSource([0.0, 0, 0], [0.0, 1, 0], 5e-3, 632.8e-9),
    "CollimatedSource([0.0, 0, 0], [0.0, 1, 0], 5e-3, 632.8e-9)", "laser")
lens1 = add(ThinLens(50e-3, -50e-3, 12.7e-3, 1.5), "ThinLens(50e-3, -50e-3, 12.7e-3, 1.5)", "lens1")
lens2 = add(ThinLens(100e-3, -100e-3, 25.4e-3, 1.5), "ThinLens(100e-3, -100e-3, 25.4e-3, 1.5)", "lens2")
mirror = add(RoundPlanoMirror(25.4e-3, 6e-3), "RoundPlanoMirror(25.4e-3, 6e-3)", "mirror")
detector = add(Detector(15e-3), "Detector(15e-3)", "detector")

# The lenses are f1 + f2 = 150 mm apart, which widens the beam by f2 / f1 = 2
translate_to3d!(gui, lens1, [0, 50e-3, 0])
translate_to3d!(gui, lens2, [0, 200e-3, 0])
# The mirror folds the beam by 90° onto the detector
translate_to3d!(gui, mirror, [0, 275e-3, 0])
rotate3d!(gui, mirror, [0, 0, 1], deg2rad(45))
translate_to3d!(gui, detector, [100e-3, 275e-3, 0])
rotate3d!(gui, detector, [0, 0, 1], deg2rad(90))

# The detector is selected: the inspector shows its card with the page "Results"
select!(gui, detector)
wait_solve(gui)
update_cam!(gui.ax.scene, Vec3f(0.27, -0.06, 0.26), Vec3f(0.05, 0.15, 0), Vec3f(0, 0, 1))
save("live_empty_table_setup.png", gui.fig; px_per_unit = 2)
