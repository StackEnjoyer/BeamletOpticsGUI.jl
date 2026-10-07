module TestLiveDetectors

using GLMakie, BeamletOptics, BeamletOpticsGUI
using Makie
using Test

const BMO = BeamletOptics
const GUI = BeamletOpticsGUI

@testset "Detectors of the live view" begin

    _live_view(args...; kwargs...) =
        live_view(args...; merge((; trace_budget = Inf, throttle = false, detectors = [],
            progress_delay = Inf), kwargs)...)

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
    _rays() = CollimatedSource([0.0, 0, 0], [0.0, 1, 0], 2e-3, 1e-6; num_rings = 2, num_rays = 40)
    _gauss() = GaussianBeamlet([0.0, 0, 0], [0.0, 1, 0], 1e-6, 0.5e-3)

    # A view of `pd` in a figure of its own, shown like the view of a card
    function _view!(gui, pd; expanded = true)
        fig = Figure()
        view = GUI._DetectorView(GridLayout(fig[1, 1]), gui.layout.theme; expanded)
        return GUI._register_view!(gui, pd, view)
    end

    @testset "detectors kwarg" begin
        pd, pd2 = Detector(5e-3), Detector(5e-3)
        @test isempty(GUI._detector_specs(:auto))
        @test isempty(GUI._detector_specs([]))
        @test_throws ArgumentError GUI._detector_specs(:all)
        specs = GUI._detector_specs([pd, pd2 => :spot])
        @test [s.pd for s in specs] == [pd, pd2]
        @test [s.opts.kind for s in specs] == [:auto, :spot]
        @test all(s -> s.expanded, specs)
        # a vector of pairs with different values is a `Vector{Pair{Detector, Any}}`
        mixed = [pd => (:intensity, (; n = 50, x_min = -1e-3, x_max = 1e-3)), pd2 => :spot]
        @test eltype(mixed) <: Pair{<:Detector, Any}
        specs = GUI._detector_specs(mixed)
        @test specs[1].opts.kind == :intensity && specs[1].opts.n == 50
        # the options of the view are not passed to `intensity`
        @test specs[1].opts.kwargs == (; x_min = -1e-3, x_max = 1e-3)
        @test specs[2].opts.kind == :spot && specs[2].opts.n == 100
        opts = only(GUI._detector_specs([pd => (:psf, (; colorscale = :log, colorrange = (-3, 0),
            profiles = true, expanded = false))]))
        @test opts.opts.kind == :psf && opts.opts.colorscale == :log && opts.opts.profiles
        @test opts.opts.colorrange == (-3, 0) && !opts.expanded && isempty(opts.opts.kwargs)
        # the colorbar is shown unless it is switched off, and is no kwarg of `intensity`
        @test opts.opts.colorbar
        opts = only(GUI._detector_specs([pd => (:intensity, (; colorbar = false))]))
        @test !opts.opts.colorbar && isempty(opts.opts.kwargs)
        @test_throws ArgumentError GUI._detector_specs([pd => :heat])
        @test_throws ArgumentError GUI._detector_specs([pd => (:spot, (; colorscale = :sqrt))])
        @test_throws ArgumentError GUI._detector_specs([pd => "spot"])
        @test_throws ArgumentError GUI._detector_specs(["pd"])
        # the history of the former panels is recorded by `on_change` and plotted by `add_panel!`
        err = try
            GUI._detector_specs([pd => (:spot, (; history = true))])
        catch e
            e
        end
        @test err isa ArgumentError && occursin("add_panel!", err.msg)
    end

    @testset "state and options" begin
        m, pd = _fixture()
        gui = _live_view(System([m, pd]), _rays())
        # nothing is computed without a shown view
        @test isempty(gui.detectors.states) && gui.detectors.hits_valid
        @test isempty(GUI._shown_views(gui)) && isempty(GUI._view_requests(gui))
        state = GUI._detector_state(gui, pd)
        @test state === GUI._detector_state(gui, pd)
        @test state.stale && isnothing(state.result) && state.opts.kind == :auto
        opts = GUI._ViewOptions(state.opts; kind = :spot, n = 30)
        @test opts.kind == :spot && opts.n == 30 && opts.colorscale == state.opts.colorscale
        GUI._resolve!(gui, nothing)
        @test state.stale && isnothing(state.result)
        GUI._init_detectors!(gui, GUI._detector_specs([pd => (:spot, (; n = 30))]))
        @test state.opts.kind == :spot && state.opts.n == 30 && only(gui.detectors.start).pd === pd
        close(gui)
    end

    @testset "shown views are computed" begin
        m, pd = _fixture()
        gui = _live_view(System([m, pd]), _rays(); preview = false)
        view = _view!(gui, pd)
        state = GUI._detector_state(gui, pd)
        # a view that is shown after the solve is computed from its hits
        @test GUI._shown_views(gui) == [(pd, view)]
        @test !state.stale && GUI._kind_name(state.result.kind) == :spot
        @test state.result.metrics.n == 40
        @test GUI._signal_text(gui, pd) == "N = 40"
        @test isnothing(gui.trace.job)
        # nothing to do while it is up to date
        r = state.result
        GUI._view_needed!(gui, pd)
        @test state.result === r
        # a solve computes the shown views
        GUI._resolve!(gui, nothing)
        @test state.result !== r && !state.stale && gui.detectors.hits_valid
        # the kind needs a new result, the color scale only shows it again
        r = state.result
        GUI._set_view!(gui, pd; kind = :psf)
        @test state.opts.kind == :psf && state.result !== r && !state.stale
        @test GUI._kind_name(state.result.kind) == :psf
        r = state.result
        GUI._set_view!(gui, pd; colorscale = :log)
        @test state.opts.colorscale == :log && state.result === r && !state.stale
        GUI._set_view!(gui, pd; colorbar = false)
        @test !state.opts.colorbar && state.result === r && !state.stale
        GUI._set_view!(gui, pd; colorscale = :log)
        @test state.result === r
        # after a cancelled solve the views wait for the next one, like the beams
        GUI._views_cancelled!(gui)
        GUI._set_view!(gui, pd; kind = :spot)
        @test state.stale && state.result === r
        @test GUI._signal_text(gui, pd) == "40 hits"
        GUI._resolve!(gui, nothing)
        @test !state.stale && GUI._kind_name(state.result.kind) == :spot
        close(gui)
    end

    @testset "thumbnail grid" begin
        m, pd = _fixture()
        gui = _live_view(System([m, pd]), _gauss())
        view = _view!(gui, pd; expanded = false)
        state = GUI._detector_state(gui, pd)
        @test GUI._kind_name(state.result.kind) == :intensity
        @test state.result.n == GUI._THUMB_N < state.opts.n
        @test startswith(GUI._signal_text(gui, pd), "P = ")
        # the expanded view needs the grid of the options
        GUI._set_expanded!(view, true)
        @test only(GUI._view_requests(gui; stale_only = true)).n == state.opts.n
        GUI._view_needed!(gui, pd)
        @test state.result.n == state.opts.n && !state.stale
        # a second, collapsed view of the same detector shares the result
        _view!(gui, pd; expanded = false)
        @test length(GUI._shown_views(gui)) == 2 && length(GUI._view_requests(gui)) == 1
        GUI._resolve!(gui, nothing)
        @test state.result.n == state.opts.n
        # the beams of a Gaussian beamlet as a spot diagram
        GUI._set_view!(gui, pd; kind = :spot)
        @test GUI._kind_name(state.result.kind) == :spot
        close(gui)
    end

    @testset "window of a field view" begin
        m, pd = _fixture()
        gui = _live_view(System([m, pd]), _gauss())
        _view!(gui, pd)
        state = GUI._detector_state(gui, pd)
        r = state.result
        # zoom or pan: computed once the mouse rests for `idle_delay`
        gui.trace.idle_delay = 60.0
        window = (-1e-3, 1e-3, -0.5e-3, 0.5e-3)
        GUI._set_view!(gui, pd; window)
        @test state.opts.window == window && state.stale && state.window_changed > 0
        GUI._views_idle!(gui)
        @test state.result === r && state.stale
        gui.trace.idle_delay = 0.0
        GUI._views_idle!(gui)
        @test state.result !== r && !state.stale && state.window_changed == 0
        x = state.result.data[1]
        @test first(x) ≈ -1e-3 && last(x) ≈ 1e-3
        # "fit": the automatic window of the field
        GUI._set_view!(gui, pd; window = nothing)
        GUI._views_idle!(gui)
        @test isnothing(state.opts.window) && !state.stale
        close(gui)
    end

    @testset "cards pinned at the start" begin
        # only detectors of the systems
        m, pd = _fixture()
        @test_throws ArgumentError _live_view(System([m, pd]), _gauss(); detectors = [Detector(5e-3)])

        # compact layout: a floating card on the page "Results", whose view is computed by the
        # initial solve
        m, pd = _fixture()
        gui = _live_view(System([m, pd]), _gauss(); detectors = [pd => (:intensity, (; n = 20))])
        c = only(GUI._floating_cards(gui, pd))
        @test c.page == :results && c.view_expanded && GUI._card_view(c) === only(GUI._shown_views(gui))[2]
        state = GUI._detector_state(gui, pd)
        @test !state.stale && state.result.n == 20 && state.opts.kind == :intensity
        close(gui)

        # app layout: a docked card; floating and docking it keeps its page and the state of its view
        m, pd = _fixture()
        gui = _live_view(System([m, pd]), _rays(); layout = :app, detectors = [pd => (:spot, (; expanded = false))])
        d = only(gui.layout.inspector.pinned)
        @test d.obj === pd && d.page == :results && !d.view_expanded
        @test !GUI._detector_state(gui, pd).stale
        GUI._float!(gui, pd)
        f = only(GUI._floating_cards(gui, pd))
        @test isempty(gui.layout.inspector.pinned) && f.page == :results && !f.view_expanded
        f.view_expanded = true
        GUI._dock!(gui, pd)
        d = only(gui.layout.inspector.pinned)
        @test d.page == :results && d.view_expanded && isempty(GUI._floating_cards(gui, pd))
        close(gui)
    end

    @testset "manual tracing" begin
        m, pd = _fixture()
        gui = _live_view(System([m, pd]), _rays(); auto_trace = false)
        _view!(gui, pd)
        state = GUI._detector_state(gui, pd)
        @test !gui.detectors.hits_valid && state.stale && isnothing(state.result)
        @test GUI._signal_text(gui, pd) == "no hits"
        GUI._trace!(gui)
        @test gui.detectors.hits_valid && !state.stale && !isnothing(state.result)
        close(gui)
    end
end

end
