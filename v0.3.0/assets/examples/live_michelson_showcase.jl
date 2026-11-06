include(joinpath(@__DIR__, "live_michelson.jl"))

GLMakie.activate!(; visible = false)

## Tilt mirror 1 by 1 mrad, which generates fringes on the detector. The verbs with the window as
## first argument act like a gesture of the user, `wait_solve` waits for the solve of each step
select!(gui, m1)
for _ in 1:10
    rotate3d!(gui, m1, [0, 0, 1], 1e-4)
    wait_solve(gui)
end
save("live_michelson_fringes.png", gui.fig; px_per_unit = 2)

## Undo the tilt and move mirror 2 by λ/2, i.e. one period of the optical power
rotate3d!(gui, m1, [0, 0, 1], -1e-3)
wait_solve(gui)
empty!(power)
for _ in 1:40
    translate3d!(gui, m2, [0, λ / 80, 0])
    wait_solve(gui)
end
# Without a selection, no card of a mirror covers the setup
select!(gui, nothing)
save("live_michelson_power.png", gui.fig; px_per_unit = 2)
