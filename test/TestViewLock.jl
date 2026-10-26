module TestViewLock

using GLMakie, BeamletOptics, BeamletOpticsGUI
using Makie
using Test
using LinearAlgebra: normalize, norm

const BMO = BeamletOptics
const GUI = BeamletOpticsGUI

@testset "View lock" begin
    function fixture(layout; kwargs...)
        m = RoundPlanoMirror(25e-3, 5e-3)
        zrotate3d!(m, deg2rad(45))
        translate3d!(m, [0, 0.1, 0])
        pd = Detector(5e-3)
        zrotate3d!(pd, -π / 2)
        translate3d!(pd, [0.1, 0.1, 0])
        gui = live_view(System([m, pd]), Beam([0.0, 0, 0], [0.0, 1, 0]); layout,
            trace_budget = Inf, throttle = false, catalog = CatalogEntry[], kwargs...)
        screen = GLMakie.Screen(visible = false)
        display(screen, gui.fig)
        return gui, m, screen
    end
    ev(gui) = events(gui.ax.scene)
    tick!(gui, dt = 1 / 60) = (ev(gui).tick[] = Makie.Tick(Makie.RegularRenderTick, 0, 0.0, dt))
    settle!(gui) = foreach(_ -> tick!(gui, 0.05), 1:60)
    move!(gui, xy) = (ev(gui).mouseposition[] = (Float64(xy[1]), Float64(xy[2])))
    press!(gui, b = Mouse.left) = (ev(gui).mousebutton[] = Makie.MouseButtonEvent(b, Mouse.press))
    release!(gui, b = Mouse.left) = (ev(gui).mousebutton[] = Makie.MouseButtonEvent(b, Mouse.release))
    function drag!(gui, from, to, b = Mouse.left)
        move!(gui, from)
        press!(gui, b)
        for t in 0.25:0.25:1.0
            move!(gui, from .+ t .* (to .- from))
            tick!(gui)
        end
        release!(gui, b)
        tick!(gui)
    end
    hold!(gui, key) = begin
        ev(gui).keyboardbutton[] = Makie.KeyEvent(key, Keyboard.press)
        foreach(_ -> tick!(gui), 1:10)
        ev(gui).keyboardbutton[] = Makie.KeyEvent(key, Keyboard.release)
        tick!(gui)
    end
    cam(gui) = cameracontrols(gui.ax.scene)
    function dir(gui)
        eye, at, _ = GUI._current_view(gui)
        return normalize(eye .- at)
    end
    dist(gui) = ((e, l, _) = GUI._current_view(gui); norm(e .- l))
    lookat(gui) = GUI._current_view(gui)[2]
    toggle(gui) = gui.widgets.lock_view_toggle
    rotations(gui) = (c = cam(gui).controls; (c.rotation_button[], c.pan_left_key[], c.pan_right_key[],
        c.tilt_up_key[], c.tilt_down_key[], c.roll_clockwise_key[], c.roll_counterclockwise_key[]))
    function viewport_px(gui, fx, fy)
        vp = viewport(gui.ax.scene)[]
        return (Float64(vp.origin[1] + fx * vp.widths[1]), Float64(vp.origin[2] + fy * vp.widths[2]))
    end
    # a view onto the mirror from the side, a pixel beside everything
    function setup!(gui)
        foreach(_ -> tick!(gui), 1:3)
        GUI.set_view(gui.ax, [0.3, -0.2, 0.3], [0.0, 0.1, 0.0], [0.0, 0, 1])
        tick!(gui)
        move!(gui, viewport_px(gui, 0.85, 0.25))
        return nothing
    end
    free(gui) = viewport_px(gui, 0.85, 0.25)

    for layout in (:compact, :app)
        @testset "$layout" begin
            # starts locked
            gui, m, screen = fixture(layout; lock_view = true)
            setup!(gui)
            @test toggle(gui).active[] isa Bool && toggle(gui).active[]
            @test all(==(false), rotations(gui))
            @test cam(gui).selected[]
            d0 = dir(gui)
            l0 = lookat(gui)
            d0v = dist(gui)

            # left drag and keys do not turn the view
            drag!(gui, free(gui), free(gui) .+ (60.0, 40.0))
            @test norm(dir(gui) - d0) < 1e-9
            for key in (Keyboard.j, Keyboard.i, Keyboard.q)
                move!(gui, free(gui))
                hold!(gui, key)
                @test norm(dir(gui) - d0) < 1e-9
            end

            # right drag pans, scroll zooms
            drag!(gui, free(gui), free(gui) .+ (50.0, 30.0), Mouse.right)
            @test norm(lookat(gui) - l0) > 1e-6
            @test norm(dir(gui) - d0) < 1e-9
            move!(gui, free(gui))
            d1 = dist(gui)
            ev(gui).scroll[] = (0.0, 1.0)
            tick!(gui)
            @test abs(dist(gui) - d1) > 1e-6
            @test norm(dir(gui) - d0) < 1e-9

            # unlocking gives the rotation back, with the defaults
            toggle(gui).active[] = false
            tick!(gui)
            @test !toggle(gui).active[]
            @test gui.status.text[] == "view unlocked"
            c = cam(gui).controls
            @test c.rotation_button[] == Mouse.left
            @test c.pan_left_key[] == Keyboard.j && c.pan_right_key[] == Keyboard.l
            @test c.tilt_up_key[] == Keyboard.i && c.tilt_down_key[] == Keyboard.k
            @test c.roll_clockwise_key[] == Keyboard.e && c.roll_counterclockwise_key[] == Keyboard.q
            @test !any(==(false), rotations(gui))
            drag!(gui, free(gui), free(gui) .+ (60.0, 40.0))
            @test norm(dir(gui) - d0) > 1e-3

            # lock again
            toggle(gui).active[] = true
            tick!(gui)
            @test gui.status.text[] == "view locked"
            @test all(==(false), rotations(gui))
            d2 = dir(gui)
            drag!(gui, free(gui), free(gui) .+ (60.0, 40.0))
            @test norm(dir(gui) - d2) < 1e-9

            # home and saved views set the direction, the lock stays
            gui.camera.views = ["side" => ([0.0, -0.3, 0.0], [0.0, 0.1, 0.0], [0.0, 0.0, 1.0])]
            GUI._set_saved_view!(gui, 1)
            settle!(gui)
            @test dir(gui) ≈ [0.0, -1.0, 0.0] atol = 1e-6
            @test toggle(gui).active[]
            @test all(==(false), rotations(gui))
            GUI._go_home!(gui)
            settle!(gui)
            @test dir(gui) ≈ normalize(gui.camera.home[1] .- gui.camera.home[2]) atol = 1e-6
            @test norm(dir(gui) - [0.0, -1.0, 0.0]) > 1e-3
            @test toggle(gui).active[]
            @test all(==(false), rotations(gui))
            close(screen)

            # starts unlocked, locks later
            gui, m, screen = fixture(layout)
            setup!(gui)
            @test !toggle(gui).active[]
            @test rotations(gui)[1] == Mouse.left
            toggle(gui).active[] = true
            @test all(==(false), rotations(gui))
            close(screen)

            # selecting and dragging an object work while locked
            gui, m, screen = fixture(layout; lock_view = true)
            setup!(gui)
            center = viewport_px(gui, 0.5, 0.5)
            move!(gui, center)
            @test norm(GUI._current_view(gui)[2] .- [0.0, 0.1, 0.0]) < 1e-6
            press!(gui)
            release!(gui)
            @test gui.controls.selected[] === m
            P0 = Vector{Float64}(BMO.position(m))
            d0 = dir(gui)
            press!(gui)
            move!(gui, center .+ (40.0, 30.0))
            @test gui.controls.dragging
            release!(gui)
            @test norm(Vector{Float64}(BMO.position(m)) - P0) > 1e-6
            @test norm(dir(gui) - d0) < 1e-9
            close(screen)

            # the window of open_system starts unlocked, in its own home view
            gui, m, screen = fixture(layout; lock_view = true)
            new = open_system(gui, GUI._systems(gui)[1]; display = false)
            @test !toggle(new).active[]
            @test rotations(new)[1] == Mouse.left
            @test toggle(gui).active[]
            close(new)
            close(gui)
            close(screen)
        end
    end
end

end
