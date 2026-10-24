module TestLivePivot

using GLMakie, BeamletOptics, BeamletOpticsGUI
using Makie
using Makie.GeometryBasics: Point2f
using Test

const GUI = BeamletOpticsGUI

@testset "gesture of a move of the view" begin
    d0 = [0.3, 0, 0]
    l0 = [0.0, 0.1, 0]
    up = [0.0, 0, 1]
    v0 = (l0 .+ d0, l0, up)
    rotz(v, a) = [cos(a) * v[1] - sin(a) * v[2], sin(a) * v[1] + cos(a) * v[2], v[3]]
    @test GUI._pivot_gesture(v0, (l0 .+ rotz(d0, 0.2), l0, up)) === :rotate
    @test GUI._pivot_gesture(v0, (v0[1], l0, [0.0, sin(0.2), cos(0.2)])) === :rotate
    s = [0.05, -0.02, 0.01]
    @test GUI._pivot_gesture(v0, (v0[1] .+ s, l0 .+ s, up)) === :pan
    @test GUI._pivot_gesture(v0, (l0 .+ 0.8 .* d0, l0, up)) === :zoom_in
    @test GUI._pivot_gesture(v0, (l0 .+ 1.25 .* d0, l0, up)) === :zoom_out
    # scroll zoom of Camera3D: lookat shifted sideways, eye by the same plus the scaled d
    t = [0.0, 0.03, 0.01]
    @test GUI._pivot_gesture(v0, (l0 .+ t .+ 0.8 .* d0, l0 .+ t, up)) === :zoom_in
    @test GUI._pivot_gesture(v0, (l0 .+ t .+ 1.25 .* d0, l0 .+ t, up)) === :zoom_out
    # lookat moved, distance changed and direction rotated
    @test GUI._pivot_gesture(v0, (l0 .+ t .+ 0.7 .* rotz(d0, 0.5), l0 .+ t, up)) === :none
    # the view set again, e.g. by Camera3D when a drag ends, also rounded to Float32
    @test GUI._pivot_gesture(v0, v0) === :still
    @test GUI._pivot_gesture(v0, map(x -> Vector{Float64}(Float32.(x)), v0)) === :still
end

@testset "Pivot marker of the camera" begin
    function fixture(layout)
        m = RoundPlanoMirror(25e-3, 5e-3)
        zrotate3d!(m, deg2rad(45))
        translate3d!(m, [0, 0.1, 0])
        pd = Detector(5e-3)
        zrotate3d!(pd, -π / 2)
        translate3d!(pd, [0.1, 0.1, 0])
        gui = live_view(System([m, pd]), Beam([0.0, 0, 0], [0.0, 1, 0]); layout,
            trace_budget = Inf, throttle = false, catalog = CatalogEntry[])
        screen = GLMakie.Screen(visible = false)
        display(screen, gui.fig)
        return gui, m, screen
    end
    tick!(gui, dt = 1 / 60) = (events(gui.ax.scene).tick[] = Makie.Tick(Makie.RegularRenderTick, 0, 0.0, dt))
    key!(gui, key) = (events(gui.ax.scene).keyboardbutton[] = Makie.KeyEvent(key, Keyboard.press))
    view(gui) = GUI._current_view(gui)
    alpha(gui) = gui.camera.pivot.alpha[]
    shown(gui) = gui.camera.pivot.visible[]
    # the marker is in a scene of pixels over the 3D view, at its center
    function center_px(gui)
        vp = viewport(gui.ax.scene)[]
        return Point2f(Makie.origin(vp) .+ Makie.widths(vp) ./ 2)
    end
    glyph_plots(g) = vcat(g.halo, g.fg)
    all_plots(gui) = reduce(vcat, glyph_plots.(values(gui.camera.pivot_glyphs)); init = Any[])
    # exactly the glyph `key` is visible
    function only_glyph(gui, key)
        gl = gui.camera.pivot_glyphs
        haskey(gl, key) || return false
        ok = all(p -> p.visible[], glyph_plots(gl[key]))
        for (k, g) in gl
            k === key && continue
            ok &= all(p -> !p.visible[], glyph_plots(g))
        end
        return ok
    end
    none_visible(gui) = all(p -> !p.visible[], all_plots(gui))
    # a move of the view and one tick
    function move!(gui, f)
        eye, lookat, up = view(gui)
        e, l, u = f(eye, lookat, up)
        GUI.set_view(gui.ax, e, l, u)
        tick!(gui)
    end
    function rotz(v, a)
        c, s = cos(a), sin(a)
        return [c * v[1] - s * v[2], s * v[1] + c * v[2], v[3]]
    end
    settle!(gui) = foreach(_ -> tick!(gui, 0.05), 1:20)
    function shift!(gui, dx)
        eye, lookat, up = view(gui)
        GUI.set_view(gui.ax, eye .+ [dx, 0, 0], lookat .+ [dx, 0, 0], up)
    end

    for layout in (:compact, :app)
        @testset "$layout" begin
            gui, m, screen = fixture(layout)
            foreach(_ -> tick!(gui), 1:3)
            @test gui.camera.home_set

            # 1. no marker before the first move
            @test !shown(gui)

            # 2. a move shows the marker at lookat
            eye, lookat, up = view(gui)
            target = lookat .+ [0.02, -0.01, 0.03]
            GUI.set_view(gui.ax, eye .+ [0.02, -0.01, 0.03], target, up)
            tick!(gui)
            @test !isnothing(gui.camera.pivot)
            @test shown(gui)
            @test alpha(gui) ≈ 1
            @test gui.camera.pivot[1][] == [Point2f(0, 0)]
            @test Makie.translation(gui.camera.pivot)[] ≈ Vec3f(GUI._pivot_px(gui)..., 0) atol = 0.5
            @test Makie.translation(gui.camera.pivot)[] ≈ Vec3f(center_px(gui)..., 0) atol = 0.5

            # 3. hold, fade, gone
            n = round(Int, (GUI._PIVOT_HOLD + GUI._PIVOT_FADE / 2) / 0.01)
            foreach(_ -> tick!(gui, 0.01), 1:n)
            @test 0 < alpha(gui) < 1
            @test shown(gui)
            foreach(_ -> tick!(gui, 0.01), 1:round(Int, GUI._PIVOT_FADE / 2 / 0.01) + 10)
            @test !shown(gui)
            @test alpha(gui) ≈ 0 atol = 1e-6

            # 4. a move during the fade restores the alpha
            shift!(gui, 0.01)
            tick!(gui)
            @test shown(gui) && alpha(gui) ≈ 1
            foreach(_ -> tick!(gui, 0.01), 1:n)
            @test 0 < alpha(gui) < 1
            shift!(gui, 0.01)
            tick!(gui)
            @test alpha(gui) ≈ 1
            foreach(_ -> tick!(gui, 0.05), 1:20)
            @test !shown(gui)

            # 5. g: the marker follows lookat during the animation
            select!(gui, m)
            key!(gui, Keyboard.g)
            tick!(gui, 0.02)
            @test !isnothing(gui.camera.animation)
            steps = 0
            while !isnothing(gui.camera.animation) && steps < 1000
                tick!(gui, 0.02)
                steps += 1
                if shown(gui)
                    @test Makie.translation(gui.camera.pivot)[] ≈ Vec3f(center_px(gui)..., 0) atol = 0.5
                end
            end
            @test steps < 1000
            @test shown(gui)
            tick!(gui, 0.02)
            bb = GUI._selection_bbox(gui.controls, m, GUI._object_plots(gui.controls.h, m))
            center = collect(minimum(bb) .+ Makie.widths(bb) ./ 2)
            @test view(gui)[2] ≈ center atol = 1e-6
            @test Makie.translation(gui.camera.pivot)[] ≈ Vec3f(center_px(gui)..., 0) atol = 0.5
            foreach(_ -> tick!(gui, 0.05), 1:20)
            @test !shown(gui)

            # 6. spectator mode hides the marker, also at once
            shift!(gui, 0.01)
            tick!(gui)
            @test shown(gui)
            spectator!(gui)
            @test !shown(gui)
            @test none_visible(gui)
            shift!(gui, 0.01)
            tick!(gui)
            @test !shown(gui)
            spectator!(gui, false)
            shift!(gui, 0.01)
            tick!(gui)
            @test shown(gui) && alpha(gui) ≈ 1

            # 7. the marker does not widen the bounds of the scene
            foreach(_ -> tick!(gui, 0.05), 1:20)
            b0 = GUI._scene_bounds(gui)
            eye, lookat, up = view(gui)
            GUI.set_view(gui.ax, eye .+ [100.0, 0, 0], lookat .+ [100.0, 0, 0], up)
            tick!(gui)
            @test shown(gui)
            @test GUI._scene_bounds(gui) == b0

            # 8. scroll zoom shows the marker
            GUI.set_view(gui.ax, eye, lookat, up)
            foreach(_ -> tick!(gui, 0.05), 1:20)
            @test !shown(gui)
            vp = viewport(gui.ax.scene)[]
            events(gui.ax.scene).mouseposition[] = Tuple(vp.origin .+ vp.widths ./ 2)
            events(gui.ax.scene).scroll[] = (0.0, 1.0)
            tick!(gui)
            @test shown(gui)
            @test alpha(gui) ≈ 1
            @test gui.camera.pivot_gesture in (:zoom_in, :zoom_out)
            @test only_glyph(gui, gui.camera.pivot_gesture)

            # 9. the gesture of the last move selects the glyph
            settle!(gui)
            @test none_visible(gui)
            for (key, f) in (
                :rotate => (e, l, u) -> (l .+ rotz(e .- l, deg2rad(10)), l, u),
                :pan => (e, l, u) -> (e .+ [0.02, 0.01, 0.0], l .+ [0.02, 0.01, 0.0], u),
                :zoom_in => (e, l, u) -> (l .+ 0.8 .* (e .- l), l, u),
                :zoom_out => (e, l, u) -> (l .+ 1.25 .* (e .- l), l, u),
            )
                move!(gui, f)
                @test gui.camera.pivot_gesture === key
                @test shown(gui)
                @test only_glyph(gui, key)
                # the glyph fades with the symbol
                nf = round(Int, (GUI._PIVOT_HOLD + GUI._PIVOT_FADE / 2) / 0.01)
                foreach(_ -> tick!(gui, 0.01), 1:nf)
                @test all(p -> 0 < p.alpha[] < 1, gui.camera.pivot_glyphs[key].fg)
                @test only_glyph(gui, key)
                settle!(gui)
                @test none_visible(gui)
            end

            # spectator mode hides a shown glyph at once
            move!(gui, (e, l, u) -> (l .+ rotz(e .- l, deg2rad(10)), l, u))
            @test only_glyph(gui, :rotate)
            spectator!(gui)
            @test none_visible(gui)
            spectator!(gui, false)

            close(screen)
        end
    end
end

end
