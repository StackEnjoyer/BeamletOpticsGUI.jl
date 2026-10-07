module TestLiveCardRows

using GLMakie, BeamletOptics, BeamletOpticsGUI
using BeamletOptics: render_plots, render_settings
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
    # A view of the detector `pd` in a figure of its own: the signal of a detector is the metric of
    # its view while one is shown, see `_signal_text`
    _view!(gui, pd) = GUI._register_view!(gui, pd,
        GUI._DetectorView(GridLayout(Figure()[1, 1]), gui.layout.theme))
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
        _view!(gui, pd)
        _select!(gui, m)
        @test _text(gui, :beam) == "1 ray, AOI 45.0°"
        _select!(gui, far)
        @test _text(gui, :beam) == "not hit"
        _select!(gui, pd)
        @test _text(gui, :beam) == "1 ray, AOI 0.0°"
        # the number of rays of the spot view
        @test _text(gui, :signal) == "N = 1"
        # no options of a panel on the card: they are on the view
        @test isnothing(GUI._card_widget(gui.cards.selection, :panel_mode))
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
        # no dropdown of its parts, but the button that opens its selection card
        @test GUI._card_widget(gui.cards.selection, :parts) isa Makie.Button
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
        _view!(gui, pd)
        _select!(gui, g)
        @test _text(gui, :gauss) == "1000 nm, w0 500 µm, zR $(GUI._length_string(rayleigh_range(g)))"
        # the power of the intensity view of the detector
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
        # its sliders set the wavelength and the amplitude of the curve, shown as text
        λ = _w(gui, :pol_wavelength)
        @test λ isa Slider
        Makie.set_close_to!(λ, 0.5)
        @test GUI._pol_view(gui, pol).λ ≈ GUI._log_value(λ.value[], GUI._pol_range(gui, Val(:λ), pol))
        @test _w(gui, :pol_wavelength_text).text[] == GUI._length_string(GUI._pol_view(gui, pol).λ)
        Makie.set_close_to!(_w(gui, :pol_amplitude), 0.2)
        @test _w(gui, :pol_amplitude_text).text[] == GUI._length_string(GUI._pol_view(gui, pol).amp)
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
        agb = AstigmaticGaussianBeamlet([0.0, 0, 0], [0.0, 1, 0], 633e-9, 1e-3)
        # the pose, the λ row (sources, beamlets), the slider (sources), the row of the toggles,
        # of polarized beams the two sliders of the polarization curve, and the length row
        @test length(card_rows(b)) == length(pose_card_rows(b)) + 2
        @test length(card_rows(pol)) == length(pose_card_rows(pol)) + 4
        @test length(card_rows(g)) == length(pose_card_rows(g)) + 3
        @test length(card_rows(src)) == length(pose_card_rows(src)) + 4
        @test length(beam_card_rows(b)) == 2
        @test length(beam_card_rows(pol)) == 4
        @test length(beam_card_rows(agb)) == 4
        # the label, the toggle of the beam and its label; with the toggles "beams" (beamlets) and
        # "polarization" (polarized beams) and their labels
        _names(row) = [c.name for c in row.cells if c isa CardWidget]
        @test length(first(beam_card_rows(b)).cells) == 3
        @test _names(first(beam_card_rows(g))) == [:beam_on, :show_beams]
        @test _names(first(beam_card_rows(pol))) == [:beam_on, :polarization]
        @test _names(first(beam_card_rows(agb))) == [:beam_on, :show_beams, :polarization]
        @test _names(beam_card_rows(pol)[2]) == [nothing, :pol_wavelength, :pol_wavelength_text]
       @test _names(beam_card_rows(pol)[3]) == [nothing, :pol_amplitude, :pol_amplitude_text]
        # the last row: the length of the final rays
        for beam in (b, g, pol, src, agb)
            @test _names(last(beam_card_rows(beam))) == [nothing, :flen]
        end
    end

    @testset "length of the final rays ($layout)" for layout in (:compact, :app)
        _card(gui::GUI.LiveView{GUI.AppLayout}) = gui.layout.inspector.card
        _card(gui) = gui.cards.selection
        _w(gui, name) = GUI._card_widget(_card(gui), name)
        # a mirror beside the beams, which all end in free space
        m = RoundPlanoMirror(25e-3, 5e-3)
        translate3d!(m, [0.2, 0.1, 0])
        sys = System([m])
        b = Beam([0.0, 0, 0], [0.0, 1, 0])
        pol = Beam([0.0, 0, 10e-3], [0.0, 1, 0], 1e-6, [1.0, 0, 0])
        src = CollimatedSource([0.0, 0, 20e-3], [0.0, 1, 0], 2e-3, 1e-6; num_rings = 2, num_rays = 40)
        g = GaussianBeamlet([0.0, 0, 30e-3], [0.0, 1, 0], 1e-6, 0.5e-3)
        gui = _live_view(sys => b, sys => pol, sys => src, sys => g; layout, preview = false,
            beam_kwargs = Dict(src => (; render_every = 3, flen = 0.4)))
        h(beam) = gui.beam_handles[findfirst(p -> p.second === beam, gui.pairs)]
        in_scene(plot) = any(q -> q === plot, gui.ax.scene.plots)
        # the lengths as rendered: the defaults of BeamletOptics and the `beam_kwargs`
        @test GUI._flen(gui, b) == 1.0 && GUI._flen(gui, g) == 0.1 && GUI._flen(gui, src) == 0.4
        @test isnothing(GUI._flen(gui, Beam([0.0, 0, 0], [0.0, 1, 0])))

        # the box of the card shows the length in mm and sets it
        _select!(gui, b)
        box = _w(gui, :flen)
        @test box isa Textbox && box.displayed_string[] == "1000"
        old = h(b)
        old_plots = copy(render_plots(old))
        @test !isempty(old_plots) && all(in_scene, old_plots)
        n_rays = length(BMO.rays(b))
        box.stored_string[] = "250"
        @test GUI._flen(gui, b) == 0.25
        # the handle and its plots stay
        @test h(b) === old && length(render_plots(old)) == length(old_plots)
        @test all(p === q for (p, q) in zip(render_plots(old), old_plots)) && all(in_scene, old_plots)
        @test only(GUI._beam_segments(h(b))).b ≈ [0, 0.25, 0]
        @test _w(gui, :flen).displayed_string[] == "250"
        # display only: nothing is solved, the other beams keep their length
        @test length(BMO.rays(b)) == n_rays && !gui.trace.stale
        @test GUI._flen(gui, pol) == 1.0 && GUI._flen(gui, src) == 0.4
        # the same length again changes nothing
        kept = h(b)
        GUI._set_flen!(gui, b, 0.25)
        @test h(b) === kept
        # an input that is no positive number only shows a message
        for s in ("abc", "0", "-5")
            gui.status.text[] = ""
            _w(gui, :flen).stored_string[] = s
            @test GUI._flen(gui, b) == 0.25 && h(b) === kept
            @test occursin("invalid input \"$s\" for the length", gui.status.text[])
        end
        @test_throws ArgumentError GUI._set_flen!(gui, b, 0)
        @test_throws ArgumentError GUI._set_flen!(gui, b, Inf)
        @test h(b) === kept

        # the overlays follow the new length: the polarization, the generating beams
        GUI._set_polarization!(gui, pol, true)
        overlay = gui.beams.pol[pol]
        shown = [p.visible[] for p in render_plots(overlay)]
        GUI._set_flen!(gui, pol, 0.3)
        @test gui.beams.pol[pol] === overlay && all(in_scene, render_plots(overlay))
        @test [p.visible[] for p in render_plots(overlay)] == shown
        @test render_settings(overlay).flen == 0.3
        @test GUI._flen(gui, pol) == 0.3
        GUI._set_generating_beams!(gui, g, true)
        overlay = gui.beams.gen[g]
        GUI._set_flen!(gui, g, 0.05)
        @test gui.beams.gen[g] === overlay && render_settings(overlay).flen == 0.05
        GUI._set_flen!(gui, g, 0.1)
        GUI._set_generating_beams!(gui, g, false)
        # a beam that is off stays hidden, and is shown with the new length when switched on
        GUI._set_beam_on!(gui, b, false)
        GUI._set_flen!(gui, b, 0.5)
        @test all(p -> !p.visible[], render_plots(h(b)))
        GUI._set_beam_on!(gui, b, true)
        @test all(p -> p.visible[], render_plots(h(b)))
        @test only(GUI._beam_segments(h(b))).b ≈ [0, 0.5, 0]
        # the plots of outdated beams stay dimmed and clipped, and are restored with them
        GUI._mark_stale!(gui, nothing)
        clip = [copy(p.clip_planes[]) for p in render_plots(h(b))]
        GUI._set_flen!(gui, b, 0.6)
        dimmed = filter(p -> haskey(p, :alpha), render_plots(h(b)))
        @test !isempty(dimmed) && all(p -> p.alpha[] == GUI._STALE_ALPHA, dimmed)
        @test [p.clip_planes[] for p in render_plots(h(b))] == clip
        GUI._restore_beams!(gui)
        @test all(p -> p.alpha[] != GUI._STALE_ALPHA, dimmed)
        # a source keeps its other kwargs, e.g. `render_every`; a Gaussian beamlet
        GUI._set_flen!(gui, src, 0.2)
        @test render_settings(h(src)).render_every == 3 && GUI._flen(gui, src) == 0.2
        _select!(gui, src)
        @test _w(gui, :flen).displayed_string[] == "200"
        _select!(gui, g)
        @test _w(gui, :flen).displayed_string[] == "100"
        _w(gui, :flen).stored_string[] = "12.5"
        @test GUI._flen(gui, g) == 0.0125
        close(gui)
    end

    @testset "solve in the background" begin
        lens = SphericalLens(0.05, -0.05, 5e-3, 25.4e-3, 1.5)
        translate3d!(lens, [0, 0.05, 0])
        m, pd = _fixture()
        gui = _live_view(System([lens, m, pd]), Beam([0.0, 0, 0], [0.0, 1, 0], 633e-9))
        # A job in the background that ends once the test releases or cancels it, like a solve
        # whose task traces the beams and fills the detectors
        function slow_job(timing; background = true)
            sink = BMO.ProgressSink()
            done = Base.Event()
            release = Threads.Atomic{Bool}(false)
            task = Threads.@spawn try
                while !release[] && !sink.cancel[]
                    sleep(0.001)
                end
            finally
                notify(done)
            end
            job = GUI._SolveJob(task, done, [sink], [Point3f(0)], _ -> GUI._update_inspector!(gui),
                nothing, timing, time(), (; k = 0, t0 = NaN, t = NaN, count = 0))
            background && (gui.trace.job = job)
            return job, release
        end
        _select!(gui, m)
        @test _text(gui, :beam) == "1 ray, AOI 45.0°"
        # While the solve runs, the cards do not read the beams and detectors, which it changes:
        # the card that is shown, and the card of an object that is selected meanwhile
        job, release = slow_job(:solve_time)
        GUI._update_inspector!(gui)
        @test _text(gui, :beam) == GUI._TRACING_VALUE
        _select!(gui, lens)
        @test _text(gui, :beam) == GUI._TRACING_VALUE
        @test _text(gui, :index) == GUI._TRACING_VALUE
        # a property of the lens, not a result
        @test _text(gui, :thickness) == "5 mm"
        @test GUI._card_widget(gui.cards.selection, :y).displayed_string[] == "50.0"
        _select!(gui, pd)
        @test _text(gui, :signal) == GUI._TRACING_VALUE
        # shown again once the solve is done
        release[] = true
        @test wait_solve(gui; timeout = 10)
        @test _text(gui, :signal) == "1 hit"
        @test _text(gui, :beam) == "1 ray, AOI 0.0°"
        # and after it was cancelled
        job, release = slow_job(:solve_time)
        _select!(gui, lens)
        @test _text(gui, :index) == GUI._TRACING_VALUE
        GUI._cancel_solve!(gui)
        @test isnothing(gui.trace.job)
        @test _text(gui, :index) == "1.5 at 633 nm"
        # A job that only computes detector views changes neither
        job, release = slow_job(:view_time)
        _select!(gui, m)
        @test _text(gui, :beam) == "1 ray, AOI 45.0°"
        GUI._cancel_solve!(gui)
        # A solve counts as running from its start, i.e. also while the task that started it waits
        # for it (see `_run!`) and another task runs, e.g. the render loop of the window if a
        # script started the solve: its ticks neither read the beams nor show the result
        gui.trace.progress_delay = 10.0
        job, release = slow_job(:solve_time; background = false)
        seen = Ref{Any}(nothing)
        ticks = @async begin
            timedwait(() -> gui.trace.awaited, 10.0; pollint = 0.001)
            GUI._poll_job!(gui)
            GUI._update_inspector!(gui)
            seen[] = (GUI._running(gui), gui.trace.job === job, _text(gui, :beam))
            release[] = true
        end
        @test GUI._run!(gui, job, GUI._TRACING)
        wait(ticks)
        @test seen[] == (true, true, GUI._TRACING_VALUE)
        @test isnothing(gui.trace.job) && !gui.trace.awaited
        @test _text(gui, :beam) == "1 ray, AOI 45.0°"
        # A solve of the systems that continues in the background ends with the values on the card
        gui.trace.progress_delay = 0.0
        translate3d!(gui, m, [0, 1e-3, 0])
        @test wait_solve(gui; timeout = 10)
        @test _text(gui, :beam) == "1 ray, AOI 45.0°"
        close(gui)
    end

    @testset "refresh of 1000 rays" begin
        m, pd = _fixture()
        src = UniformDiscSource([0.0, 0, 0], [0.0, 1, 0], 4e-3, 633e-9; num_rays = 1000)
        gui = _live_view(System([m, pd]), src; preview = false)
        _select!(gui, m)
        @test startswith(_text(gui, :beam), "1000 rays")
        GUI._update_inspector!(gui)
        # the fastest of three: a single one can contain a pause of the garbage collector
        t = minimum(@elapsed(GUI._update_inspector!(gui)) for _ in 1:3)
        @test t < 5e-3
        close(gui)
    end
end

end
