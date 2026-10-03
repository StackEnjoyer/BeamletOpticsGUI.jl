module TestLiveDetectorWidget

using GLMakie, BeamletOptics, BeamletOpticsGUI
using Makie
using Test

const BMO = BeamletOptics
const GUI = BeamletOpticsGUI

GLMakie.activate!(; visible = false)

@testset "Detector view in a figure of its own" begin

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

    # The colors of the spots of the view `v`, in its axis
    _spot_colors(v) = v.widget.spots[2].color[]
    red, blue = Makie.to_color(:red), Makie.to_color(:blue)

    @testset "without a live view" begin
        m, pd = _fixture()
        sys = System([m, pd])
        fig = Figure()
        # no hits yet
        v = detector_view!(fig[1, 1], pd; kind = :spot)
        @test v isa DetectorView{Nothing} && v.detector === pd && v.axis isa Axis
        @test isnothing(v.kind) && isnothing(v.metrics)
        @test sort(collect(propertynames(v))) == [:axis, :detector, :kind, :metrics]
        @test occursin("DetectorView", sprint(show, v))
        # the view is computed by `update_detector_view!`
        solve_system!(sys, _rays())
        @test update_detector_view!(v) === v
        @test v.kind == :spot
        @test v.metrics.n == 40 && all(isfinite, (v.metrics.cx, v.metrics.cz, v.metrics.rms, v.metrics.rmax))
        @test length(v.widget.xy) == 40
        # spots of the theme color, then by a function of the hits
        @test all(==(Makie.to_color(GUI._APP_THEMES[:light].text)), _spot_colors(v))
        @test set_spot_colors!(v, hit -> BMO.wavelength(hit.ray) > 0 ? :red : :blue) === v
        @test length(_spot_colors(v)) == 40 && all(==(red), _spot_colors(v))
        # the function is applied to each new result
        empty!(pd)
        solve_system!(sys, _rays())
        update_detector_view!(v)
        @test v.metrics.n == 40 && all(==(red), _spot_colors(v))
        # one color for all spots, a vector, one of the wrong length, the default again
        set_spot_colors!(v, :blue)
        @test all(==(blue), _spot_colors(v))
        set_spot_colors!(v, [i <= 20 ? :red : :blue for i in 1:40])
        @test count(==(red), _spot_colors(v)) == 20 && count(==(blue), _spot_colors(v)) == 20
        set_spot_colors!(v, [:red, :blue])
        @test all(==(Makie.to_color(GUI._APP_THEMES[:light].text)), _spot_colors(v))
        set_spot_colors!(v, nothing)
        @test all(==(Makie.to_color(GUI._APP_THEMES[:light].text)), _spot_colors(v))
        # the PSF of rays has no power
        v2 = detector_view!(fig[1, 2], pd; kind = :psf, n = 40)
        @test v2.kind == :psf && !haskey(v2.metrics, :P) && v2.metrics.peak ≈ 1
        # the mouse of the figure zooms the axis of the view: a rectangle of its limits is kept
        fig4 = Figure(; size = (500, 500))
        v4 = detector_view!(fig4[1, 1], pd; kind = :spot, width = 300, height = 300)
        colorbuffer(fig4)
        w0 = Makie.widths(v4.axis.finallimits[])
        center = Makie.origin(v4.axis.scene.viewport[]) .+ Makie.widths(v4.axis.scene.viewport[]) ./ 2
        events(fig4).mouseposition[] = Tuple(center)
        events(fig4).scroll[] = (0.0, 2.0)
        @test all(Makie.widths(v4.axis.finallimits[]) .< w0)
        close(v4)
        # a kind that the hits do not offer falls back to the first one
        @test detector_view!(fig[2, 1], pd; kind = :intensity).kind == :spot
        # the options of the constructor
        @test_throws ArgumentError detector_view!(fig[2, 2], pd; kind = :heat)
        @test_throws ArgumentError detector_view!(fig[2, 2], pd; history = 10)
        @test_throws ArgumentError detector_view!(fig[2, 2], pd; theme = :blue)
        # the thumbnail
        v3 = detector_view!(Figure()[1, 1], pd; expanded = false, theme = :dark)
        @test !v3.widget.expanded && v3.kind == :spot
        close(v); close(v); close(v2)
    end

    @testset "intensity" begin
        m, pd = _fixture()
        solve_system!(System([m, pd]), _gauss())
        fig = Figure()
        v = detector_view!(fig[1, 1], pd; n = 50, width = 320, height = 300)
        @test v.kind == :intensity
        @test v.metrics.P > 0 && v.metrics.peak > 0 && isfinite(v.metrics.wx)
        @test v.metrics.wx ≈ 0.5e-3 rtol = 0.2
        @test v.axis.width[] == 320 && v.axis.height[] == 300
        @test v.widget.result.n == 50
        # options of a field, the options of the view change its result
        v = detector_view!(fig[1, 2], pd; kind = :intensity, n = 20, colorscale = :log, profiles = true,
            x_min = -1e-3, x_max = 1e-3)
        @test v.widget.result.n == 20 && v.widget.opts.colorscale == :log && v.widget.opts.profiles
        @test first(v.widget.result.data[1]) ≈ -1e-3
        # the widget of the view calls back for the options the user changes
        v.widget.on_options(; kind = :spot)
        @test v.kind == :spot && v.metrics.n > 0
        v.widget.on_options(; colorscale = :linear)
        @test v.widget.opts.colorscale == :linear
        # expanding and collapsing computes the grid that it needs
        v.widget.on_expanded(false)
        @test !v.widget.expanded
        v.widget.on_expanded(true)
        @test v.widget.expanded
        # the spot diagram of a Gaussian beamlet has the colors, too
        set_spot_colors!(v, :red)
        @test all(==(red), _spot_colors(v))
        close(v)
    end

    @testset "with a live view" begin
        m, pd = _fixture()
        gui = _live_view(System([m, pd]), _rays(); layout = :compact)
        fig = Figure(; backgroundcolor = gui.layout.theme.background)
        v = detector_view!(fig[1, 1], gui, pd; kind = :spot,
            spot_colors = hit -> BMO.wavelength(hit.ray) > 0 ? :red : :blue)
        @test v isa DetectorView{typeof(gui)} && v.gui === gui
        state = GUI._detector_state(gui, pd)
        # shown at once from the last solve, and registered with the views that are computed after a solve
        @test v.kind == :spot && v.metrics.n == 40 && !state.stale
        @test any(((p, w),) -> p === pd && w === v.widget, GUI._shown_views(gui))
        @test state.opts.kind == :spot
        @test all(==(red), _spot_colors(v))
        # a solve of the live view updates it
        r = state.result
        GUI._resolve!(gui, nothing)
        @test state.result !== r && v.widget.result === state.result
        @test v.metrics.n == 40 && all(==(red), _spot_colors(v))
        # the view follows the pose of the components after a move: another centroid
        cx = v.metrics.cx
        translate3d!(pd, [0, 0, 1e-3])
        GUI._resolve!(gui, nothing)
        @test v.metrics.cz != 0 || v.metrics.cx != cx
        # the options are those of the detector: a change in the view is shown in its other views
        v2 = detector_view!(fig[1, 2], gui, pd; kind = :psf, n = 30)
        @test state.opts.kind == :psf && state.opts.n == 30 && v.kind == :psf && v2.kind == :psf
        # the options that are not passed stay
        v3 = detector_view!(fig[2, 1], gui, pd; expanded = false)
        @test state.opts.kind == :psf && state.opts.n == 30
        # the widget changes the options of the detector
        v.widget.on_options(; kind = :spot)
        @test state.opts.kind == :spot && v2.kind == :spot && v3.kind == :spot
        # update of the hits that the live view did not solve
        empty!(pd)
        update_detector_view!(v)
        @test isnothing(v.kind) && isnothing(v.metrics)
        GUI._resolve!(gui, nothing)
        @test v.kind == :spot
        # closed, the view is no longer computed
        close(v)
        @test !any(((_, w),) -> w === v.widget, GUI._shown_views(gui))
        @test length(gui.detectors.registered) == 2
        close(v2); close(v3)
        @test isempty(gui.detectors.registered)
        close(gui)
    end

    @testset "intensity with a live view" begin
        m, pd = _fixture()
        gui = _live_view(System([m, pd]), _gauss())
        v = detector_view!(Figure()[1, 1], gui, pd)
        @test v.kind == :intensity && v.metrics.P > 0
        P = v.metrics.P
        GUI._resolve!(gui, nothing)
        @test v.metrics.P ≈ P
        close(v); close(gui)
    end
end

end
