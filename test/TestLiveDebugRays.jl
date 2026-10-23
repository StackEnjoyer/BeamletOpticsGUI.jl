module TestLiveDebugRays

using GLMakie, BeamletOptics, BeamletOpticsGUI
using Makie
using Test

const BMO = BeamletOptics
const GUI = BeamletOpticsGUI

@testset "Debug mode: ray diagnostics" begin

    _live_view(args...; kwargs...) =
        live_view(args...; merge((; trace_budget = Inf, throttle = false, preview = false,
            catalog = CatalogEntry[]), kwargs)...)

    # The layer of the rays of the `gui`, with the mode switched on
    function _rays!(gui)
        GUI._set_debug!(gui, true)
        r = GUI._debug_layer(gui, :rays)
        @test r isa GUI._DebugRays
        return r
    end
    _summary(gui) = GUI._debug(gui).stats.rays
    _shown(r) = r.visible[] && all(p -> p.visible[], values(r.plots))

    # Three beams along +y: one that leaves the system, one onto a detector that stops it, one
    # between two facing mirrors, which reflect it until it has the most rays of a solve; and a
    # mirror beside all beams
    function _fixture()
        pd = Detector(5e-3)
        translate3d!(pd, [0, 0.1, 0])
        m1, m2 = RoundPlanoMirror(25e-3, 5e-3), RoundPlanoMirror(25e-3, 5e-3)
        translate3d!(m1, [0.1, 0.3, 0])
        zrotate3d!(m2, π)
        translate3d!(m2, [0.1, 0.2, 0])
        side = RoundPlanoMirror(25e-3, 5e-3)
        translate3d!(side, [0.3, 0.1, 0])
        open = Beam([-0.1, 0, 0], [0.0, 1, 0])
        stopped = Beam([0.0, 0, 0], [0.0, 1, 0])
        bouncing = Beam([0.1, 0.25, 0], [0.0, 1, 0])
        sys = System([pd, m1, m2, side])
        return (; sys, pd, m1, m2, side, open, stopped, bouncing)
    end

    @testset "ends by reason, never hit" begin
        fx = _fixture()
        gui = _live_view(fx.sys => fx.open, fx.sys => fx.stopped, fx.sys => fx.bouncing)
        @test length(BMO.rays(fx.bouncing)) == BMO.get_default_r_max()
        # the mode is off: no layer
        @test isnothing(GUI._debug_layer(gui, :rays))
        r = _rays!(gui)
        s = _summary(gui)
        @test s isa GUI._RaySummary
        @test s.ends[:open] == 1
        @test s.ends[:object] == 1
        @test s.ends[:r_max] == 1
        @test s.ends[:depth_max] == 0
        @test s.beams == 3
        @test s.segments == 1 + 1 + BMO.get_default_r_max()
        @test s.rays == s.segments
        @test s.max_depth == 1
        # the mirror beside the beams, nothing else
        @test length(s.unhit) == 1 && only(s.unhit) === fx.side
        @test only(r.unhit) ≈ Point3f(position(fx.side))
        @test r.unhit_text[] == ["never hit"]
        # the end of the open beam where it is drawn, with the `flen` of its handle
        flen = GUI._flen(gui, fx.open)
        @test only(r.ends[:open]) ≈ Point3f(-0.1, flen, 0) atol = 1e-6
        @test only(r.ends[:object])[2] ≈ 0.1 atol = 1e-3
        @test length(r.ends[:limit]) == 1
        # a hit point on the detector, one on each reflection between the mirrors
        @test s.hits == length(r.hits) == 1 + BMO.get_default_r_max() - 1
        @test length(r.normals) == 2 * length(r.hits)
        # the normal of the detector points back towards the source
        i = findfirst(p -> abs(p[1]) < 1e-6, r.hits)
        n = r.normals[2i] - r.normals[2i - 1]
        @test n[2] < 0 && abs(n[1]) < 1e-6
        @test _shown(r)

        # the same result when called again
        GUI._debug_solved!(gui)
        s2 = _summary(gui)
        @test s2.ends == s.ends && s2.hits == s.hits && s2.unhit == s.unhit
        @test length(r.hits) == s.hits
        close(gui)
    end

    @testset "drawn on top of the beams" begin
        fx = _fixture()
        gui = _live_view(fx.sys => fx.stopped)
        r = _rays!(gui)
        # a pixel scene in the 3D scene, after it and in front of it
        @test r.hud.parent === gui.ax.scene
        for p in values(r.plots)
            @test p.parent === r.hud
            @test !p.transparency[] && !p.overdraw[]
            @test !p.inspectable[]
            @test isempty(p.clip_planes[])
            @test Makie.translation(p)[][3] > GUI._RAYS_Z
        end
        # the projections are those of the 3D scene
        q = Makie.project(gui.ax.scene, :data, :pixel, only(r.ends[:object]))
        @test only(r.ends_px[:object][]) ≈ Point2f(q[1], q[2]) atol = 0.5
        # and follow the camera
        cam = Makie.cameracontrols(gui.ax.scene)
        update_cam!(gui.ax.scene, cam.eyeposition[] .+ Vec3f(0.05, 0, 0.05), cam.lookat[])
        q = Makie.project(gui.ax.scene, :data, :pixel, only(r.ends[:object]))
        @test only(r.ends_px[:object][]) ≈ Point2f(q[1], q[2]) atol = 0.5
        close(gui)

        # The hit point of a thick Gaussian beamlet on a mirror is drawn inside the beam, in the
        # purple of the hit points
        m = RoundPlanoMirror(50e-3, 5e-3)
        zrotate3d!(m, deg2rad(45))
        translate3d!(m, [0, 0.1, 0])
        gauss = GaussianBeamlet([0.0, 0, 0], [0.0, 1, 0], 1e-6, 8e-3)
        gui = _live_view(System([m]) => gauss)
        screen = GLMakie.Screen(visible = false)
        display(screen, gui.fig)
        r = _rays!(gui)
        @test length(r.hits) == 1
        img = Makie.colorbuffer(screen)
        ppu = screen.px_per_unit[]
        o = minimum(Makie.viewport(gui.ax.scene)[])
        x, y = (only(r.hits_px[]) .+ o) .* ppu
        H = size(img, 1)
        near(c) = abs(c.r - 0x9b / 255) + abs(c.g - 0x40 / 255) + abs(c.b - 0xc9 / 255) < 0.15
        window = [img[clamp(H - round(Int, y) + j, 1, H), clamp(round(Int, x) + i, 1, size(img, 2))]
                  for i in -2:2, j in -2:2]
        @test count(near, window) >= 9
        close(gui)
    end

    @testset "at most $(GUI._RAYS_HIT_CAP) hit points, the beams that are drawn" begin
        pd = Detector(60e-3)
        translate3d!(pd, [0, 0.1, 0])
        src = CollimatedSource([0.0, 0, 0], [0.0, 1, 0], 40e-3, 1e-6; num_rings = 10, num_rays = 3000)
        n = length(BMO.beams(src))
        gui = _live_view(System([pd]) => src; beam_kwargs = Dict(src => (; render_every = 1)))
        r = _rays!(gui)
        s = _summary(gui)
        @test s.beams == n
        @test s.ends[:object] == n
        @test n > GUI._RAYS_HIT_CAP
        @test GUI._RAYS_HIT_CAP / 2 <= s.hits <= GUI._RAYS_HIT_CAP
        @test length(r.hits) == length(r.hits_px[]) == s.hits
        # the normals are arrows of at most `_RAYS_NORMAL_PX` on the screen, whatever the zoom
        ps = r.normals_px[]
        ls = [hypot((ps[2i] - ps[2i - 1])...) for i in 1:(length(ps) ÷ 2)]
        @test length(ls) == s.hits
        @test all(l -> isnan(l) || l <= GUI._RAYS_NORMAL_PX + 1e-3, ls) && any(l -> l > 1, ls)
        close(gui)

        # by default every 5th beam of a group is drawn
        gui = _live_view(System([pd]) => src)
        _rays!(gui)
        @test _summary(gui).beams == cld(n, 5)
        @test _summary(gui).ends[:object] == cld(n, 5)
        close(gui)
    end

    @testset "hidden while the beams are outdated, in the spectator mode and with the mode off" begin
        fx = _fixture()
        gui = _live_view(fx.sys => fx.stopped; auto_trace = false)
        # without auto tracing, the start is not solved: nothing is shown until a solve
        r = _rays!(gui)
        @test !r.visible[]
        GUI._trace!(gui)
        wait_solve(gui)
        @test !gui.trace.stale
        GUI._debug_solved!(gui)
        @test _shown(r)
        translate3d!(gui, fx.pd, [0.0, 0.01, 0])
        @test gui.trace.stale
        GUI._debug_stale!(gui)
        @test !r.visible[]
        # a solve of outdated beams reads nothing of them
        GUI._debug_solved!(gui)
        @test _summary(gui).beams == 0
        GUI._trace!(gui)
        wait_solve(gui)
        @test !gui.trace.stale
        GUI._debug_solved!(gui)
        @test r.visible[]
        @test only(r.ends[:object])[2] ≈ 0.11 atol = 1e-3

        spectator!(gui)
        GUI._debug_show!(gui)
        @test !r.visible[]
        spectator!(gui, false)
        GUI._debug_show!(gui)
        @test r.visible[]

        GUI._set_debug!(gui, false)
        @test !r.visible[]
        GUI._set_debug!(gui, true)
        @test r.visible[]
        close(gui)
    end

    @testset "follow the solves and the length of the final rays by themselves" begin
        fx = _fixture()
        # each change outdates the beams until the solve, which runs once the changes pause
        gui = _live_view(fx.sys => fx.stopped; trace_budget = 0.0)
        r = _rays!(gui)
        # without a call of `_debug_solved!`
        translate3d!(gui, fx.pd, [0.0, 0.01, 0])
        @test gui.trace.stale
        wait_solve(gui)
        @test !gui.trace.stale
        @test r.visible[]
        @test only(r.ends[:object])[2] ≈ 0.11 atol = 1e-3
        # a source added to the system, e.g. placed from the catalog, which flies on
        src = Beam([-0.2, 0, 0], [0.0, 1, 0])
        add_component!(gui, src; system = fx.sys)
        wait_solve(gui)
        @test !gui.trace.stale
        @test r.visible[]
        @test length(r.ends[:object]) == 1
        @test only(r.ends[:open]) ≈ Point3f(-0.2, GUI._flen(gui, src), 0) atol = 1e-6
        # its final ray drawn shorter: its end moves along, nothing is solved
        GUI._set_flen!(gui, src, 0.25)
        @test only(r.ends[:open]) ≈ Point3f(-0.2, 0.25, 0) atol = 1e-6
        @test r.visible[]
        close(gui)
    end

    @testset "nothing is read while a solve runs" begin
        fx = _fixture()
        gui = _live_view(fx.sys => fx.stopped)
        r = _rays!(gui)
        before = _summary(gui)
        GUI._debug(gui).stats.rays = nothing
        # a job of the view in the background (never started), see `_running`
        gui.trace.job = GUI._SolveJob(Task(() -> nothing), Base.Event(), BMO.ProgressSink[],
            Point3f[], identity, nothing, :solve_time, 0.0, (k = 0, t0 = 0.0, t = 0.0, count = 0))
        @test GUI._running(gui)
        try
            GUI._debug_solved!(gui)
            @test isnothing(_summary(gui))
        finally
            gui.trace.job = nothing
        end
        GUI._debug_solved!(gui)
        @test _summary(gui).ends == before.ends
        close(gui)
    end
end

end
