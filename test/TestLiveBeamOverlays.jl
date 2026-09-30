module TestLiveBeamOverlays

using GLMakie, BeamletOptics, BeamletOpticsGUI
using BeamletOptics: render_plots, rendered
using Makie
using Test

const BMO = BeamletOptics
const GUI = BeamletOpticsGUI

@testset "Generating beams of beamlets" begin

    _live_view(args...; kwargs...) =
        live_view(args...; merge((; trace_budget = Inf, throttle = false, preview = false), kwargs)...)

    # A detector across +y, facing the beamlets
    function _system()
        pd = Detector(50e-3)
        translate3d!(pd, [0, 0.1, 0])
        return System([pd]), pd
    end
    _gauss() = GaussianBeamlet([0.0, 0, 0], [0.0, 1, 0], 1e-6, 0.5e-3)
    _astigmatic() = AstigmaticGaussianBeamlet([0.0, 0, 0], [0.0, 1, 0], 633e-9, 1e-3)

    _segments(gui) = [p for p in gui.ax.scene.plots if p isa Makie.LineSegments && p.visible[]]
    _points(p) = filter(q -> all(isfinite, q), Point3f.(p[1][]))
    # The generating beams of the static `render!` of `g` with `show_beams = true`
    function _static_segments(g)
        fig = Figure()
        ax = LScene(fig[1, 1])
        render!(ax, g; show_beams = true)
        return [p for p in ax.scene.plots if p isa Makie.LineSegments]
    end

    @testset "toggle, look and move ($(nameof(typeof(g()))))" for g in (_gauss, _astigmatic)
        sys, pd = _system()
        beamlet = g()
        gui = _live_view(sys => beamlet)
        n = length(_segments(gui))
        @test !GUI._generating_beams_on(gui, beamlet)
        GUI._set_generating_beams!(gui, beamlet, true)
        h = gui.beams.gen[beamlet]
        @test rendered(h) === beamlet
        # chief, divergence and waist rays; the envelope of the overlay stays hidden
        shown = [p for p in render_plots(h) if p.visible[]]
        @test length(shown) == 3 && all(p -> p isa Makie.LineSegments, shown)
        @test length(_segments(gui)) == n + 3
        # as drawn by the static render! with show_beams = true
        static = _static_segments(beamlet)
        @test sort([string(p.color[]) for p in shown]) == sort([string(p.color[]) for p in static])
        @test sort([_points(p) for p in shown]; by = first) ≈ sort([_points(p) for p in static]; by = first)
        # the main handle draws no generating beams
        @test !any(p -> p isa Makie.LineSegments, render_plots(only(gui.beam_handles)))
        # moved: follows the beamlet after solving
        translate3d!(beamlet, [5e-3, 0, 0])
        GUI._resolve!(gui, nothing)
        @test all(p -> all(q -> abs(q[1] - 5e-3) < 3e-3, _points(p)), shown)
        # off: the overlay is removed
        plots = copy(render_plots(h))
        GUI._set_generating_beams!(gui, beamlet, false)
        @test !haskey(gui.beams.gen, beamlet)
        @test all(p -> !(p in gui.ax.scene.plots), plots)
        @test length(_segments(gui)) == n
        GUI._resolve!(gui, nothing)
        close(gui)
    end

    @testset "beams off, clip beams, beam_kwargs" begin
        sys, pd = _system()
        g = _gauss()
        gui = _live_view(sys => g; clip_planes = [[0, 0.05, 0] => [0, 1, 0]],
            beam_kwargs = Dict(g => (; show_beams = true)))
        # started on by the beam_kwargs, drawn by the overlay only
        @test GUI._generating_beams_on(gui, g)
        @test !any(p -> p isa Makie.LineSegments, render_plots(only(gui.beam_handles)))
        shown = gui.beams.shown[gui.beams.gen[g]]
        @test length(shown) == 3
        # clipped with the beams
        @test all(p -> isempty(p.clip_planes[]), shown)
        GUI._set_clip_beams!(gui, true)
        @test all(p -> length(p.clip_planes[]) == 1, shown)
        # hidden while the beamlet is off
        GUI._set_beam_on!(gui, g, false)
        @test !any(p -> p.visible[], render_plots(gui.beams.gen[g]))
        GUI._set_beam_on!(gui, g, true)
        @test all(p -> p.visible[], shown)
        close(gui)
        # only Gaussian beamlets have generating beams
        b = Beam([0.0, 0, 0], [0.0, 1, 0])
        @test !GUI._has_generating_beams(b)
        @test_throws ArgumentError _live_view(sys => b; beam_kwargs = Dict(b => (; show_beams = true)))
    end

    @testset "groups: the central beamlet" begin
        sys, pd = _system()
        sg = SphericalGaussianBeamletSource([0.0, 0, 0], [0.0, 1, 0], 0.1, 633e-9; num_rings = 2)
        @test GUI._has_generating_beams(sg)
        gui = _live_view(sys => sg)
        GUI._set_generating_beams!(gui, sg, true)
        @test rendered(gui.beams.gen[sg]) === GUI._central_beam(sg)
        @test length(gui.beams.shown[gui.beams.gen[sg]]) == 3
        close(gui)
    end

    @testset "card toggle ($layout)" for layout in (:compact, :app)
        _card(gui::GUI.LiveView{GUI.AppLayout}) = gui.layout.inspector.card
        _card(gui) = gui.cards.selection
        sys, pd = _system()
        g = _gauss()
        gui = _live_view(sys => g; layout)
        gui.controls.selected[] = g
        GUI._update_selection_box!(gui.controls)
        toggle = GUI._card_widget(_card(gui), :show_beams)
        @test toggle isa Toggle && !toggle.active[]
        @test isnothing(GUI._card_widget(_card(gui), :polarization))
        toggle.active[] = true
        @test GUI._generating_beams_on(gui, g)
        toggle.active[] = false
        @test !GUI._generating_beams_on(gui, g)
        close(gui)
    end
end

end
