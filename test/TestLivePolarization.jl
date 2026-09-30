module TestLivePolarization

using GLMakie, BeamletOptics, BeamletOpticsGUI
using BeamletOptics: render_plots, rendered
using Makie
using Test

const BMO = BeamletOptics
const GUI = BeamletOpticsGUI

@testset "Polarization overlays" begin

    _live_view(args...; kwargs...) =
        live_view(args...; merge((; trace_budget = Inf, throttle = false, preview = false), kwargs)...)

    _pbeam(pos, dir = [0.0, 1, 0]) = Beam(pos, dir, 633e-9, [1.0, 0, 0])
    # A wrapped source of polarized beams, the central beam is not the first one
    function _wrapped()
        bs = [_pbeam([2e-3, 0, 0]), _pbeam([0.0, 0, 2e-3]), _pbeam([0.0, 0, 0]), _pbeam([-2e-3, 0, 0]),
              _pbeam([0.0, 0, -2e-3])]
        return CollimatedSource(bs, 4e-3, [0.0, 0, 0], [0.0, 1, 0]), bs[3]
    end
    # A detector across +y, facing the beams
    function _system()
        pd = Detector(50e-3)
        translate3d!(pd, [0, 0.1, 0])
        return System([pd]), pd
    end

    _lines(gui) = [p for p in gui.ax.scene.plots if p isa Makie.Lines]
    _visible_lines(gui) = [p for p in _lines(gui) if p.visible[]]
    _curve(p) = filter(q -> all(isfinite, q), Point3f.(p[1][]))
    # the middle between the extremes of the field curve along x, i.e. the x of its beam
    _mid_x(p) = (c = _curve(p); (maximum(q[1] for q in c) + minimum(q[1] for q in c)) / 2)

    @testset "polarizable" begin
        @test GUI._polarizable(_pbeam([0.0, 0, 0]))
        @test GUI._polarizable(AstigmaticGaussianBeamlet([0.0, 0, 0], [0.0, 1, 0], 633e-9, 1e-3))
        @test GUI._polarizable(SphericalGaussianBeamletSource([0.0, 0, 0], [0.0, 1, 0], deg2rad(5), 633e-9;
            num_rings = 2, num_rays = 40))
        @test GUI._polarizable(first(_wrapped()))
        @test !GUI._polarizable(Beam([0.0, 0, 0], [0.0, 1, 0]))
        @test !GUI._polarizable(GaussianBeamlet([0.0, 0, 0], [0.0, 1, 0], 633e-9, 1e-3))
        @test !GUI._polarizable(CollimatedSource([0.0, 0, 0], [0.0, 1, 0], 4e-3, 633e-9; num_rings = 2, num_rays = 40))
        @test !GUI._polarizable(PointSource([0.0, 0, 0], [0.0, 1, 0], 0.01, 633e-9; num_rings = 2, num_rays = 40))
        @test !GUI._polarizable(UniformDiscSource([0.0, 0, 0], [0.0, 1, 0], 4e-3, 633e-9; num_rays = 20))
    end

    @testset "central beam" begin
        src, center = _wrapped()
        @test GUI._central_beam(src) === center
        b = _pbeam([0.0, 0, 0])
        @test GUI._central_beam(b) === b
        # Beamlets of a point source start at the same point: the one along the axis is central
        sg = SphericalGaussianBeamletSource([0.0, 0, 0], [0.0, 1, 0], deg2rad(5), 633e-9; num_rings = 2, num_rays = 40)
        c = GUI._central_beam(sg)
        @test all(b -> BMO.direction(b)[2] ≤ BMO.direction(c)[2] + 1e-12, BMO.beams(sg))
        @test BMO.direction(c) ≈ [0, 1, 0] atol = 1e-9
    end

    @testset "single beam: on, follows the beam, off" begin
        sys, pd = _system()
        b = _pbeam([0.0, 0, 0])
        gui = _live_view(sys => b)
        n = length(_lines(gui))
        @test !GUI._polarization_on(gui, b)
        GUI._set_polarization!(gui, b, true)
        @test GUI._polarization_on(gui, b)
        @test length(_lines(gui)) == n + 1
        h = gui.beams.pol[b]
        @test rendered(h) === b
        @test count(p -> p isa Makie.Lines && p.visible[], render_plots(h)) == 1
        @test all(p -> p isa Makie.Lines || !p.visible[], render_plots(h))
        line = only(p for p in render_plots(h) if p isa Makie.Lines)
        # the curve runs along the traced beam up to the detector at y = 0.1
        @test maximum(p[2] for p in _curve(line)) ≈ 0.1 atol = 1e-3
        # moved: follows the beam after solving
        translate3d!(b, [5e-3, 0, 0])
        GUI._resolve!(gui, nothing)
        @test _mid_x(line) ≈ 5e-3 atol = 1e-4
        # the same state again changes nothing
        GUI._set_polarization!(gui, b, true)
        @test gui.beams.pol[b] === h
        plots = copy(render_plots(h))
        GUI._set_polarization!(gui, b, false)
        @test !GUI._polarization_on(gui, b)
        @test !haskey(gui.beams.pol, b)
        @test all(p -> !(p in gui.ax.scene.plots), plots)
        @test length(_lines(gui)) == n
        # solving afterwards does not touch the removed overlay
        GUI._resolve!(gui, nothing)
        @test length(_lines(gui)) == n
    end

    @testset "group: central beam only" begin
        sys, pd = _system()
        src, center = _wrapped()
        gui = _live_view(sys => src)
        n = length(_visible_lines(gui))
        GUI._set_polarization!(gui, src, true)
        @test length(_visible_lines(gui)) == n + 1
        @test rendered(gui.beams.pol[src]) === center
        line = only(p for p in render_plots(gui.beams.pol[src]) if p isa Makie.Lines)
        # on the axis of the group
        @test _mid_x(line) ≈ 0 atol = 1e-4
        @test all(p -> abs(p[3]) < 1e-6, _curve(line))
        translate3d!(src, [0, 0, 5e-3])
        GUI._resolve!(gui, nothing)
        @test all(p -> abs(p[3] - 5e-3) < 1e-6, _curve(line))
        @test _mid_x(line) ≈ 0 atol = 1e-4
        GUI._set_polarization!(gui, src, false)
        @test length(_visible_lines(gui)) == n
    end

    @testset "astigmatic beamlet and group" begin
        sys, pd = _system()
        agb = AstigmaticGaussianBeamlet([0.0, 0, 0], [0.0, 1, 0], 633e-9, 1e-3)
        sg = SphericalGaussianBeamletSource([0.0, 0, 0], [0.0, 1, 0], deg2rad(5), 633e-9; num_rings = 2, num_rays = 40)
        gui = _live_view(sys => agb, sys => sg)
        n = length(_visible_lines(gui))
        GUI._set_polarization!(gui, agb, true)
        @test length(_visible_lines(gui)) == n + 1
        @test BMO.render_settings(gui.beams.pol[agb]).r_res == 3
        @test all(p -> p isa Makie.Lines || !p.visible[], render_plots(gui.beams.pol[agb]))
        GUI._set_polarization!(gui, sg, true)
        @test length(_visible_lines(gui)) == n + 2
        @test rendered(gui.beams.pol[sg]) === GUI._central_beam(sg)
        GUI._resolve!(gui, nothing)
        @test length(_visible_lines(gui)) == n + 2
        GUI._set_polarization!(gui, agb, false)
        GUI._set_polarization!(gui, sg, false)
        @test length(_visible_lines(gui)) == n
    end

    @testset "not polarizable" begin
        sys, pd = _system()
        b = Beam([0.0, 0, 0], [0.0, 1, 0])
        gui = _live_view(sys => b)
        @test_throws ArgumentError GUI._set_polarization!(gui, b, true)
        @test !GUI._polarization_on(gui, b)
    end

    @testset "beam_kwargs show_polarization" begin
        sys, pd = _system()
        b = _pbeam([0.0, 0, 0])
        b2 = _pbeam([10e-3, 0, 0])
        gui = _live_view(sys => b, sys => b2; beam_kwargs = Dict(b => (; show_polarization = true, color = :green)))
        # the main handles draw no polarization curve
        @test !any(p -> p isa Makie.Lines, render_plots(gui.beam_handles[1]))
        # live_view starts with the overlay of `b` only
        @test GUI._polarization_on(gui, b)
        @test !GUI._polarization_on(gui, b2)
        n = length(_visible_lines(gui))
        GUI._set_polarization!(gui, b, false)
        @test length(_visible_lines(gui)) == n - 1
        # a beam without polarized rays is rejected before the window is built
        b3 = Beam([0.0, 0, 0], [0.0, 1, 0])
        @test_throws ArgumentError _live_view(sys => b3; beam_kwargs = Dict(b3 => (; show_polarization = true)))
    end

    @testset "clip beams and beams off" begin
        sys, pd = _system()
        b = _pbeam([0.0, 0, 0])
        gui = _live_view(sys => b; clip_planes = [[0, 0.05, 0] => [0, 1, 0]])
        GUI._set_polarization!(gui, b, true)
        line = only(p for p in render_plots(gui.beams.pol[b]) if p isa Makie.Lines)
        # beams are not clipped by default, neither is the overlay
        @test isempty(line.clip_planes[])
        GUI._set_clip_beams!(gui, true)
        @test length(line.clip_planes[]) == 1
        GUI._set_clip_beams!(gui, false)
        @test isempty(line.clip_planes[])
        # an overlay created while the beams are clipped is clipped at once
        GUI._set_polarization!(gui, b, false)
        GUI._set_clip_beams!(gui, true)
        GUI._set_polarization!(gui, b, true)
        line = only(p for p in render_plots(gui.beams.pol[b]) if p isa Makie.Lines)
        @test length(line.clip_planes[]) == 1

        # a beam that is off hides its overlay, which reappears when it is on again
        GUI._set_beam_on!(gui, b, false)
        @test !line.visible[]
        GUI._set_beam_on!(gui, b, true)
        @test line.visible[]
        @test all(p -> p === line || !p.visible[], render_plots(gui.beams.pol[b]))
        # an overlay switched on while the beam is off stays hidden
        GUI._set_beam_on!(gui, b, false)
        GUI._set_polarization!(gui, b, false)
        GUI._set_polarization!(gui, b, true)
        @test all(p -> !p.visible[], render_plots(gui.beams.pol[b]))
        GUI._set_beam_on!(gui, b, true)
        @test count(p -> p.visible[], render_plots(gui.beams.pol[b])) == 1
    end

    @testset "overlay of outdated beams is dimmed" begin
        sys, pd = _system()
        b = _pbeam([0.0, 0, 0])
        gui = _live_view(sys => b; auto_trace = false)
        @test gui.trace.stale
        GUI._set_polarization!(gui, b, true)
        line = only(p for p in render_plots(gui.beams.pol[b]) if p isa Makie.Lines)
        @test line.alpha[] ≈ GUI._STALE_ALPHA
        GUI._set_polarization!(gui, b, false)
        # the removed overlay is forgotten by the restore after the next trace
        GUI._trace!(gui)
        @test !gui.trace.stale
    end

    @testset "sliders of the curve" begin
        sys, pd = _system()
        b = _pbeam([0.0, 0, 0])
        gui = _live_view(sys => b)
        E = GUI._scene_size(gui)
        v0 = GUI._pol_view(gui, b)
        @test v0.λ ≈ E / 40 && v0.amp ≈ v0.λ / 4
        GUI._set_polarization!(gui, b, true)
        _line() = only(p for p in render_plots(gui.beams.pol[b]) if p isa Makie.Lines)
        # the beam runs along +y, the field along x: the offset of the curve along x
        _amp() = maximum(abs(q[1]) for q in _curve(_line()))
        n0 = length(_curve(_line()))
        @test _amp() ≈ v0.amp rtol = 1e-2
        # half the wavelength: twice the points (a fixed number per wavelength), same amplitude
        GUI._set_pol_view!(gui, b; λ = v0.λ / 2)
        @test length(_curve(_line())) / n0 ≈ 2 rtol = 0.05
        @test _amp() ≈ v0.amp rtol = 1e-2
        GUI._set_pol_view!(gui, b; amp = 3 * v0.amp)
        @test _amp() ≈ 3 * v0.amp rtol = 1e-2
        # display only
        @test !gui.trace.stale
        # the slider positions map back to the values, on the logarithmic ranges
        @test GUI._log_value(GUI._pol_position(gui, b, :λ), GUI._pol_range(gui, Val(:λ), b)) ≈ v0.λ / 2
        GUI._set_pol_position!(gui, b, :λ, 1.0)
        @test GUI._pol_view(gui, b).λ ≈ E / 2
        @test GUI._pol_text(gui, b, :λ) == GUI._length_string(E / 2)
        # values set while the curve is off are kept for the next "on"
        GUI._set_polarization!(gui, b, false)
        GUI._set_pol_view!(gui, b; λ = v0.λ)
        GUI._set_polarization!(gui, b, true)
        @test length(_curve(_line())) / n0 ≈ 1 rtol = 0.05
        @test _amp() ≈ 3 * v0.amp rtol = 1e-2
        close(gui)

        # the beam_kwargs give the start values
        gui = _live_view(sys => b; beam_kwargs = Dict(b => (; pol_λ = 1e-3, pol_amplitude = 2e-4)))
        @test GUI._pol_view(gui, b) == (; λ = 1e-3, amp = 2e-4)
        close(gui)
        # astigmatic beamlets: the amplitude as a multiple of the beam radius (BMO's pol_scale)
        agb = AstigmaticGaussianBeamlet([0.0, 0, 0], [0.0, 1, 0], 633e-9, 1e-3)
        gui = _live_view(sys => agb; beam_kwargs = Dict(agb => (; pol_scale = 2.0)))
        @test GUI._pol_view(gui, agb).amp == 2.0
        @test GUI._pol_text(gui, agb, :amp) == "2.0 × w"
        @test GUI._pol_range(gui, Val(:amp), agb) == (0.1, 10.0)
        GUI._set_polarization!(gui, agb, true)
        # the largest distance of the curve from the axis of the beamlet (along +y) scales with it
        _offset() = maximum(hypot(q[1], q[3]) for p in render_plots(gui.beams.pol[agb])
                            if p isa Makie.Lines for q in _curve(p))
        d2 = _offset()
        GUI._set_pol_view!(gui, agb; amp = 1.0)
        @test d2 / _offset() ≈ 2 rtol = 1e-3
        close(gui)
    end
end

end
