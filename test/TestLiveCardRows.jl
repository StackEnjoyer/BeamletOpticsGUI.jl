module TestLiveCardRows

using GLMakie, BeamletOptics, BeamletOpticsGUI
using Makie
using Test

const BMO = BeamletOptics
const GUI = BeamletOpticsGUI

@testset "Live card rows" begin

    _live_view(args...; kwargs...) =
        live_view(args...; merge((; trace_budget = Inf, throttle = false), kwargs)...)
    function _select!(gui, obj)
        gui.controls.selected[] = obj
        GUI._update_selection_box!(gui.controls)
        return nothing
    end
    # Text of the declared label `name` on the card of the selection
    _text(gui, name) = GUI._card_widget(gui.cards.selection, name).text[]

    # Beam along +y, mirror at 45° reflects it along +x onto the detector
    function _fixture()
        m = RoundPlanoMirror(25e-3, 5e-3)
        zrotate3d!(m, deg2rad(45))
        translate3d!(m, [0, 0.1, 0])
        pd = Detector(5e-3)
        zrotate3d!(pd, -π / 2)
        translate3d!(pd, [0.1, 0.1, 0])
        return m, pd
    end

    @testset "mirror, detector, missed component" begin
        m, pd = _fixture()
        far = RoundPlanoMirror(25e-3, 5e-3)
        translate3d!(far, [0.3, 0.3, 0.3])
        gui = _live_view(System([m, pd, far]), Beam([0.0, 0, 0], [0.0, 1, 0]))
        _select!(gui, m)
        @test _text(gui, :beam) == "1 ray, AOI 45.0°"
        _select!(gui, far)
        @test _text(gui, :beam) == "not hit"
        _select!(gui, pd)
        @test _text(gui, :beam) == "1 ray, AOI 0.0°"
        # the number of rays of the spot panel
        @test _text(gui, :signal) == "N = 1"
        # refreshed after the solve of a change: the mirror rotated by 1° about z
        _select!(gui, m)
        GUI._card_widget(gui.cards.selection, :rv).stored_string[] = string(1e3 * deg2rad(1))
        @test _text(gui, :beam) in ("1 ray, AOI 44.0°", "1 ray, AOI 46.0°")
        close(gui)
    end

    @testset "lens, beamsplitters, polarizer" begin
        lens = SphericalLens(0.05, -0.05, 5e-3, 25.4e-3, 1.5)
        translate3d!(lens, [0, 0.05, 0])
        bs = RoundThinBeamsplitter(25e-3; reflectance = 0.3)
        translate3d!(bs, [0, 0.1, 0])
        cube = CubeBeamsplitter(10e-3, λ -> 1.5)
        translate3d!(cube, [0, 0.2, 0])
        pol = RoundLinearPolarizer(25e-3, 1e-3, 1e-3, λ -> 1.5)
        translate3d!(pol, [0, 0.3, 0])
        gui = _live_view(System([lens, bs, cube, pol]), Beam([0.0, 0, 0], [0.0, 1, 0], 633e-9))
        _select!(gui, lens)
        @test _text(gui, :index) == "1.5 at 633 nm"
        @test _text(gui, :thickness) == "5 mm"
        # the front and the back surface on the axis (and reflections of the splitters behind)
        hits = match(r"^(\d+) rays, AOI 0.0°", _text(gui, :beam))
        @test !isnothing(hits) && parse(Int, hits[1]) >= 2
        _select!(gui, bs)
        @test _text(gui, :split) == "R 30.0 %, T 70.0 %"
        @test _text(gui, :beam) != "not hit"
        # a multi-shape component: the hits of its prisms and its coating, behind the split
        _select!(gui, cube)
        @test _text(gui, :split) == "R 50.0 %, T 50.0 %"
        @test _text(gui, :beam) != "not hit"
        # the transmission axis along the local x-axis, i.e. horizontal for an optical axis along y
        _select!(gui, pol)
        @test _text(gui, :axis) == "0.0° from horizontal"
        rotate3d!(pol, [0.0, 1, 0], deg2rad(30))
        GUI._update_inspector!(gui; force = true)
        @test _text(gui, :axis) in ("30.0° from horizontal", "150.0° from horizontal")
        close(gui)
    end

    @testset "sources" begin
        m, pd = _fixture()
        g = GaussianBeamlet([0.0, 0, 0], [0.0, 1, 0], 1e-6, 0.5e-3)
        gui = _live_view(System([m, pd]), g)
        _select!(gui, g)
        @test _text(gui, :gauss) == "1000 nm, w0 500 µm, zR $(GUI._length_string(rayleigh_range(g)))"
        # the power of the intensity panel of the detector
        _select!(gui, pd)
        @test startswith(_text(gui, :signal), "P = ") && endswith(_text(gui, :signal), " mW")
        close(gui)

        src = CollimatedSource([0.0, 0, 0], [0.0, 1, 0], 4e-3, 633e-9; num_rings = 2, num_rays = 40)
        gui = _live_view(System([m, pd]), src; preview = false)
        _select!(gui, src)
        @test _text(gui, :source) == "633 nm, ⌀ 4 mm"
        # the rays of the source hit the mirror: the center ray first, the range of all of them
        _select!(gui, m)
        @test startswith(_text(gui, :beam), "40 rays, AOI 45.0° (")
        close(gui)

        ps = PointSource([0.0, 0, 0], [0.0, 1, 0], 0.01, 633e-9; num_rings = 2, num_rays = 40)
        gui = _live_view(System([m, pd]), ps)
        _select!(gui, ps)
        @test _text(gui, :source) == "633 nm, NA 0.01"
        close(gui)
    end

    @testset "systems" begin
        m, pd = _fixture()
        src = CollimatedSource([0.0, 0, 0], [0.0, 1, 0], 4e-3, 633e-9; num_rings = 2, num_rays = 40)
        sys = System([m, pd])
        gui = _live_view(sys => src, sys => Beam([0.0, 0, 0], [0.0, 1, 0]); preview = false)
        # no pose rows, the number of objects, the rays of both sources and the last solve
        rows = BeamletOpticsGUI.card_rows(sys)
        @test length(rows) == 3
        GUI._inspect!(gui, sys)
        @test _text(gui, :objects) == "2"
        @test _text(gui, :rays) == "41"
        @test _text(gui, :solve) == GUI._ms_string(gui.trace.solve_time)
        @test isnothing(GUI._card_widget(gui.cards.selection, :x))
        close(gui)
    end

    @testset "beam toggles ($layout)" for layout in (:compact, :app)
        # the card of the selection: floating (compact) or in the inspector (app)
        _card(gui::GUI.LiveView{GUI.AppLayout}) = gui.layout.inspector.card
        _card(gui) = gui.cards.selection
        _w(gui, name) = GUI._card_widget(_card(gui), name)
        _nhits(pd) = (h = BMO.hits(pd); isnothing(h) ? 0 : length(h))
        m, pd = _fixture()
        sys = System([m, pd])
        b = Beam([0.0, 0, 0], [0.0, 1, 0])
        # polarized, hits the mirror but misses the detector (a detector takes one kind of ray)
        pol = Beam([0.0, 0, 10e-3], [0.0, 1, 0], 1e-6, [1.0, 0, 0])
        src = CollimatedSource([0.0, 0, 0], [0.0, 1, 0], 2e-3, 1e-6; num_rings = 2, num_rays = 40)
        gui = _live_view(sys => b, sys => pol, sys => src; layout, preview = false)
        @test _nhits(pd) == 41
        # an unpolarized beam: only the on/off toggle
        _select!(gui, b)
        on = _w(gui, :beam_on)
        @test on isa Toggle && on.active[] && isnothing(_w(gui, :polarization))
        on.active[] = false
        @test !GUI._beam_on(gui, b) && _nhits(pd) == 40
        GUI._inspect!(gui, sys)
        @test _w(gui, :rays).text[] == "41"
        @test occursin("41 rays", gui.widgets.info.text[])
        _select!(gui, b)
        @test !_w(gui, :beam_on).active[]
        _w(gui, :beam_on).active[] = true
        @test GUI._beam_on(gui, b) && _nhits(pd) == 41
        # a polarized beam: the polarization toggle, display only
        _select!(gui, pol)
        toggle = _w(gui, :polarization)
        @test toggle isa Toggle && !toggle.active[] && _w(gui, :beam_on).active[]
        toggle.active[] = true
        @test GUI._polarization_on(gui, pol) && _nhits(pd) == 41
        toggle.active[] = false
        @test !GUI._polarization_on(gui, pol)
        # a ray source keeps its slider and gets the toggle
        _select!(gui, src)
        @test _w(gui, :rays) isa Slider && _w(gui, :ray_count).text[] == "40 rays"
        @test _w(gui, :beam_on) isa Toggle && isnothing(_w(gui, :polarization))
        close(gui)
    end

    @testset "card rows of beams" begin
        g = GaussianBeamlet([0.0, 0, 0], [0.0, 1, 0], 1e-6, 0.5e-3)
        b = Beam([0.0, 0, 0], [0.0, 1, 0])
        pol = Beam([0.0, 0, 0], [0.0, 1, 0], 1e-6, [1.0, 0, 0])
        src = CollimatedSource([0.0, 0, 0], [0.0, 1, 0], 2e-3, 1e-6; num_rings = 2, num_rays = 40)
        # the pose, the λ row (sources, beamlets), the slider (sources) and the row of the toggles
        @test length(card_rows(b)) == length(pose_card_rows(b)) + 1
        @test length(card_rows(pol)) == length(pose_card_rows(pol)) + 1
        @test length(card_rows(g)) == length(pose_card_rows(g)) + 2
        @test length(card_rows(src)) == length(pose_card_rows(src)) + 3
        @test length(beam_card_rows(b)) == 1
        # the toggle of the beam, and the label; with the polarization toggle and its label
        @test length(only(beam_card_rows(b)).cells) == 3
        @test length(only(beam_card_rows(pol)).cells) == 5
    end

    @testset "refresh of 1000 rays" begin
        m, pd = _fixture()
        src = UniformDiscSource([0.0, 0, 0], [0.0, 1, 0], 4e-3, 633e-9; num_rays = 1000)
        gui = _live_view(System([m, pd]), src; preview = false)
        _select!(gui, m)
        @test startswith(_text(gui, :beam), "1000 rays")
        GUI._update_inspector!(gui)
        t = @elapsed GUI._update_inspector!(gui)
        @test t < 5e-3
        close(gui)
    end
end

end
