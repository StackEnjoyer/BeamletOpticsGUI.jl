module TestLiveCardViews

using GLMakie, BeamletOptics, BeamletOpticsGUI
using Makie
using Test, Logging

const BMO = BeamletOptics
const GUI = BeamletOpticsGUI

GLMakie.activate!(; visible = false)

# An own type with views: a beam block that counts the rays it absorbs
struct Counter{T} <: BMO.AbstractObject{T}
    shape::BMO.PlanoSurfaceSDF{T}
    count::Threads.Atomic{Int}
end

Counter(width, thickness) = Counter(BMO.PlanoSurfaceSDF(thickness, width), Threads.Atomic{Int}(0))

BMO.interact3d(::BMO.AbstractSystem, c::Counter, ::Beam, ::Ray) = (Threads.atomic_add!(c.count, 1); nothing)
BMO.initialize!(c::Counter) = (c.count[] = 0; nothing)

# A field of the count on a grid of `num_points` in the `window`
function _count_field(c::Counter; num_points, window)
    x0, x1, z0, z1 = something(window, (-1e-3, 1e-3, -1e-3, 1e-3))
    x, z = range(x0, x1; length = num_points), range(z0, z1; length = num_points)
    return (x, z, [c.count[] * exp(-(xi^2 + zi^2) / 1e-7) for xi in x, zi in z])
end

# Points with a color each, from the count
_count_points(::Counter) = ([Point2(1e-3 * i, 0.0) for i in 1:3], [:red, :green, :blue])

GUI.card_views(::Counter) = (
    CardView(c -> c.count[], :series; name = :count, label = "Count", unit = "rays",
        text = (c, v) -> "count $(Int(v))"),
    CardView(_count_field, :field; name = :map, label = "Map", unit = "rays/m²"),
    CardView(_count_points, :points; name = :marks, label = "Marks"),
    CardView(_ -> error("boom"), :points; name = :bad, label = "Bad"))

@testset "Own views on the page Results" begin

    _live_view(args...; kwargs...) =
        live_view(args...; merge((; trace_budget = Inf, throttle = false, detectors = [],
            progress_delay = Inf), kwargs)...)
    _retrace!(gui) = (retrace!(gui); wait_solve(gui))

    _rays() = CollimatedSource([0.0, 0, 0], [0.0, 1, 0], 4e-3, 1e-6; num_rings = 2, num_rays = 40)
    function _counter()
        c = Counter(20e-3, 2e-3)
        translate3d!(c, [0, 0.1, 0])
        return c
    end

    @testset "the page and the views" begin
        c = _counter()
        @test GUI._has_view(c) && :results in GUI._card_pages(c) && GUI._default_page(c) == :results
        # the forms: what the functions return, with the display helpers of the window
        solve_system!(System([c]), _rays())
        n = c.count[]
        @test n > 0
        r = GUI._view_result(c, GUI._ViewOptions())
        @test r.view.name == :count && r.data == n && r.text == "count $n" && isnothing(r.error)
        r = GUI._view_result(c, GUI._ViewOptions(; kind = :map, num_points = 21))
        @test r.view.name == :map && size(r.data[3]) == (21, 21) && r.metrics.peak ≈ n
        @test abs(r.metrics.cx) < 1e-12 && isfinite(r.metrics.wx)
        r = GUI._view_result(c, GUI._ViewOptions(; kind = :map, window = (0.0, 1e-3, 0.0, 1e-3), num_points = 5))
        @test collect(extrema(r.data[1])) ≈ [0, 1e-3]
        r = GUI._view_result(c, GUI._ViewOptions(; kind = :marks))
        @test length(r.data) == 3 && r.colors == [:red, :green, :blue] && r.metrics.n == 3
        # an error of a function is shown in the view
        r = GUI._view_result(c, GUI._ViewOptions(; kind = :bad))
        @test r.view.name == :bad && r.error isa ErrorException && isnothing(r.data)
        # the texts of the forms
        cv = first(card_views(c))
        @test GUI._metrics_text(GUI._SeriesForm(), cv, (; n = 3, last = 40.0), "count 40") ==
              "count 40, last 40 rays\n3 solves"
        @test GUI._thumb_text(GUI._SeriesForm(), cv, (; n = 0, last = NaN), nothing) == "no values\n0 solves"
    end

    @testset "drawn by the widget" begin
        c = _counter()
        solve_system!(System([c]), _rays())
        fig = Figure(; size = (600, 600))
        v = GUI._DetectorView(GridLayout(fig[1, 1]), GUI._APP_THEMES[:light])
        show!(o) = GUI._show_result!(v, "C", GUI._view_result(c, o), o)
        show!(GUI._ViewOptions(; kind = :marks))
        @test v.spots[2].visible[] && v.spots[2].color[] == RGBAf.(Makie.to_color.([:red, :green, :blue]))
        @test v.names == GUI._POSITION_NAMES && v.ax.autolimitaspect[] == 1
        show!(GUI._ViewOptions())
        @test v.lines[2].visible[] && !v.spots[2].visible[] && v.lines[2][1][] == [Point2f(1, c.count[])]
        @test v.names == ("solve", "rays") && isnothing(v.ax.autolimitaspect[])
        @test v.series_shown && !v.fields_shown && v.switch.keys == [:count, :map, :marks, :bad]
        show!(GUI._ViewOptions(; kind = :map, num_points = 11))
        @test v.images[2].visible[] && !v.lines[2].visible[] && v.fields_shown && !v.series_shown
        @test v.bar_unit.text[] == "rays/m²"
        @test_logs (:error,) match_mode = :any show!(GUI._ViewOptions(; kind = :bad))
        @test v.metrics_label.text[] == "error"

        # a view that starts collapsed builds its switch when it is expanded: drawn without errors
        fig = Figure()
        rv = results_view!(fig[1, 1], c; view = :map, expanded = false)
        screen = display(GLMakie.Screen(; visible = false), fig)
        try
            colorbuffer(screen)
            @test_logs min_level = Logging.Error begin
                GUI._rv_on_expanded!(rv, true)
                colorbuffer(screen)
                GUI._rv_on_options!(rv; kind = :marks)
                colorbuffer(screen)
            end
            @test getfield(rv, :widget).view.name == :marks
        finally
            close(rv)
            close(screen)
        end
    end

    @testset "in the live view: a series per solve" begin
        c = _counter()
        gui = _live_view(System([c]), _rays())
        state = GUI._detector_state(gui, c)
        # recorded after each solve also while no card shows it
        values = state.series[:count]
        k = length(values)
        @test k >= 1 && last(values) == c.count[]
        _retrace!(gui)
        _retrace!(gui)
        @test length(values) == k + 2
        # not while objects move (a coarse solve), but once the movement pauses
        GUI._resolve!(gui, nothing; coarse = true)
        @test length(values) == k + 2 && gui.trace.coarse
        gui.trace.last_change = 0.0
        GUI._on_idle!(gui)
        wait_solve(gui)
        @test length(values) == k + 3 && !gui.trace.coarse
        # the view of a card shows the recorded values, "clear" empties them
        GUI._set_view!(gui, c; kind = :count)
        GUI._pin_view!(gui, c)
        _retrace!(gui)
        r = state.result
        @test r.view.name == :count && r.data == values && length(values) == k + 4
        GUI._set_view!(gui, c; clear = true)
        @test isempty(values) && isempty(state.result.data) && state.result.metrics.n == 0
        _retrace!(gui)
        @test length(values) == 1
        # a view without `preview` waits for a full result while objects move
        GUI._set_view!(gui, c; kind = :map)
        _retrace!(gui)
        before = state.result
        @test before.view.name == :map && !before.coarse
        GUI._resolve!(gui, nothing; coarse = true)
        @test state.result === before && state.stale
        gui.trace.last_change = 0.0
        GUI._on_idle!(gui)
        wait_solve(gui)
        @test state.result !== before && !state.result.coarse && !state.stale
        # removing the object drops its series
        remove_component!(gui, c)
        @test !haskey(gui.detectors.states, c)
        close(gui)
    end

    @testset "spot colors of a detector" begin
        pd = Detector(25e-3)
        translate3d!(pd, [0, 0.05, 0])
        solve_system!(System([pd]), _rays())
        r = GUI._view_result(pd, GUI._ViewOptions(; kind = :spot, spot_colors = hit -> :red))
        @test length(r.colors) == length(r.data) == 40 && all(==(RGBAf(1, 0, 0, 1)), r.colors)
        # beamlets: the contour of each hit in its color
        pd = Detector(10e-3)
        translate3d!(pd, [0, 0.2, 0])
        solve_system!(System([pd]), GaussianBeamlet([0.0, 0, 0], [0.0, 1, 0], 1e-6, 0.5e-3))
        r = GUI._view_result(pd, GUI._ViewOptions(; kind = :spot, spot_colors = hit -> :blue))
        @test length(r.colors) == length(r.data) > 1 && all(==(RGBAf(0, 0, 1, 1)), r.colors)
        # through the `detectors` kwarg, and changed later
        m = RoundPlanoMirror(25e-3, 5e-3)
        pd = Detector(25e-3)
        translate3d!(pd, [0, 0.05, 0])
        gui = _live_view(System([pd]), _rays(); detectors = [pd => (:spot, (; spot_colors = _ -> :green))])
        state = GUI._detector_state(gui, pd)
        wait_solve(gui)
        @test all(==(RGBAf(Makie.to_color(:green))), state.result.colors)
        GUI._set_view!(gui, pd; spot_colors = _ -> :red)
        wait_solve(gui)
        @test all(==(RGBAf(1, 0, 0, 1)), state.result.colors)
        close(gui)
    end

    @testset "the GUI hands no results back" begin
        # the public API: no function or field of a view returns its data
        @test fieldnames(CardView) == (:f, :form, :name, :label, :unit, :normalize, :preview, :text)
        @test propertynames(ResultsView) isa Tuple
        @test !any(n -> occursin(r"metric|result_data|data", lowercase(string(n))), names(BeamletOpticsGUI))
    end
end

end
