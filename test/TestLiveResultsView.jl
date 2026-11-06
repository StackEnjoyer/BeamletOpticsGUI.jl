module TestLiveResultsView

using GLMakie, BeamletOptics, BeamletOpticsGUI
using Makie
using Test

const BMO = BeamletOptics
const GUI = BeamletOpticsGUI

GLMakie.activate!(; visible = false)

# An own type with views: a beam block that counts the rays it absorbs
struct CountingBlock{T} <: BMO.AbstractObject{T}
    shape::BMO.PlanoSurfaceSDF{T}
    count::Threads.Atomic{Int}
end

CountingBlock(width, thickness) =
    CountingBlock(BMO.PlanoSurfaceSDF(thickness, width), Threads.Atomic{Int}(0))

BMO.interact3d(::BMO.AbstractSystem, b::CountingBlock, ::Beam, ::Ray) =
    (Threads.atomic_add!(b.count, 1); nothing)

BMO.initialize!(b::CountingBlock) = (b.count[] = 0; nothing)

# A field of the count on a grid of `num_points` in the `window`
function _count_field(b::CountingBlock; num_points, window)
    x0, x1, z0, z1 = something(window, (-1e-3, 1e-3, -1e-3, 1e-3))
    x, z = range(x0, x1; length = num_points), range(z0, z1; length = num_points)
    return (x, z, [b.count[] * exp(-(xi^2 + zi^2) / 1e-7) for xi in x, zi in z])
end

GUI.card_views(::CountingBlock) = (
    CardView(b -> b.count[], :series; name = :count, label = "Count", unit = "rays"),
    CardView(_count_field, :field; name = :map, label = "Map"))

@testset "Results views in a figure of their own" begin

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

    # What the widget of the view `v` shows: its result, the name of the view shown, whether it
    # shows data without an error
    _widget(v) = getfield(v, :widget)
    _result(v) = _widget(v).result
    _shown(v) = _shown_name(_result(v))
    _shown_name(::Nothing) = nothing
    _shown_name(r) = isnothing(r.view) ? nothing : r.view.name
    _ok(v) = (r = _result(v); !isnothing(r) && isnothing(r.error) && !isnothing(r.data))
    _registered(gui, v) = any(((_, w),) -> w === _widget(v), gui.detectors.registered)
    _retrace!(gui) = (retrace!(gui); wait_solve(gui))

    @testset "without a live view" begin
        m, pd = _fixture()
        sys = System([m, pd])
        fig = Figure()
        # no hits yet: shown as such
        v = results_view!(fig[1, 1], pd)
        @test v isa ResultsView{Nothing}
        @test isempty(propertynames(v))
        @test occursin("ResultsView(\"Results\"", sprint(show, v))
        @test isnothing(_shown(v))
        # it changes only on `refresh!`
        solve_system!(sys, _rays())
        @test isnothing(_shown(v))
        @test refresh!(v) === v
        @test _shown(v) == :spot && _ok(v)
        r = _result(v)
        BMO.initialize!(pd)
        solve_system!(sys, _rays())
        @test _result(v) === r
        refresh!(v)
        @test _result(v) !== r && _shown(v) == :spot

        # the view by its name, the options of its own widgets
        v2 = results_view!(fig[1, 2], pd; view = :psf, name = "PD", theme = :dark)
        @test _shown(v2) == :psf && _widget(v2).name == "PD"
        @test _widget(v2).theme === GUI._app_theme(:dark)
        r = _result(v2)
        _widget(v2).on_options(; colorscale = :log)
        @test _result(v2) === r && _widget(v2).opts.colorscale == :log
        _widget(v2).on_options(; kind = :spot)
        @test _shown(v2) == :spot && _result(v2) !== r
        window = (-1e-3, 1e-3, -1e-3, 1e-3)
        _widget(v2).on_options(; kind = :psf)
        _widget(v2).on_options(; window)
        @test _shown(v2) == :psf && first(_result(v2).data[1]) ≈ -1e-3
        # expanding computes the grid of the options, a thumbnail a coarser one
        _widget(v2).on_expanded(false)
        @test !_widget(v2).expanded
        r = _result(v2)
        _widget(v2).on_expanded(true)
        @test _widget(v2).expanded && _result(v2) !== r && _result(v2).n == getfield(v2, :opts).num_points
        v3 = results_view!(fig[2, 1], pd; view = :psf, expanded = false)
        @test !_widget(v3).expanded && _result(v3).n == GUI._THUMB_N

        # into a `GridLayout`, of the given size
        v4 = results_view!(GridLayout(fig[2, 2]), pd; width = 200, height = 150)
        @test _ok(v4) && _widget(v4).ax.width[] == 200 && _widget(v4).ax.height[] == 150

        # closed: removed, neither computed nor drawn
        close(v)
        @test occursin("closed", sprint(show, v))
        @test isnothing(close(v))
        @test_throws ArgumentError refresh!(v)
        r = _result(v2)
        close(v2)
        _widget(v2).on_options(; kind = :spot)
        @test _result(v2) === r
        close(v3); close(v4)

        # arguments
        @test_throws ArgumentError results_view!(Figure()[1, 1], pd; theme = :blue)
        @test_throws ArgumentError results_view!(Figure()[1, 1], m)
        # a name that is not a view of the detector with its hits (`card_views(::Detector)`)
        err = try
            results_view!(Figure()[1, 1], pd; view = :intensity)
        catch e
            e
        end
        @test err isa ArgumentError && occursin(":spot, :psf", err.msg)
        # a detector without hits offers no views yet, any name is accepted
        v5 = results_view!(Figure()[1, 1], Detector(5e-3); view = :intensity)
        @test isnothing(_shown(v5))
        close(v5)

        # spot colors per hit
        red = Makie.to_color(:red)
        v6 = results_view!(Figure()[1, 1], pd; view = :spot, spot_colors = _ -> :red)
        @test _ok(v6) && length(_result(v6).colors) == length(_result(v6).data) &&
              all(==(red), _result(v6).colors)
        close(v6)
    end

    @testset "with a live view" begin
        m, pd = _fixture()
        gui = _live_view(System([m, pd]), _rays(); layout = :compact)
        state = GUI._detector_state(gui, pd)
        fig = Figure()
        v = results_view!(fig[1, 1], gui, pd; view = :spot)
        @test v isa ResultsView{typeof(gui)}
        @test _registered(gui, v) && _widget(v).name == GUI._label(gui, pd)
        # shown at once from the last solve, the view is set for the object
        @test state.opts.kind == :spot && !state.stale
        @test _result(v) === state.result && _shown(v) == :spot
        # updated after each solve
        r = state.result
        _retrace!(gui)
        @test state.result !== r && _result(v) === state.result
        # `refresh!` computes it from the last solve of the window
        r = state.result
        @test refresh!(v) === v
        @test state.result !== r && _result(v) === state.result

        # it shares the view, the grid, the scale and the zoom with a pinned card
        GUI._pin_view!(gui, pd)
        c = only(GUI._floating_cards(gui, pd))
        @test c.page == :results
        _widget(v).on_options(; kind = :psf)
        @test state.opts.kind == :psf && _shown(v) == :psf
        _widget(v).on_options(; colorscale = :log)
        @test state.opts.colorscale == :log && _widget(v).opts.colorscale == :log
        window = (-1e-3, 1e-3, -1e-3, 1e-3)
        _widget(v).on_options(; window)
        @test state.opts.window == window
        # a second view of the window: options given are set, the others stay
        v2 = results_view!(fig[1, 2], gui, pd; expanded = false)
        @test state.opts.kind == :psf && state.opts.colorscale == :log && _widget(v2).opts === state.opts
        # a zoom is computed once the mouse rests for `idle_delay`
        gui.trace.idle_delay = 0.0
        GUI._set_view!(gui, pd; kind = :spot, window = nothing)
        @test _shown(v) == :spot && _shown(v2) == :spot
        # the card's view, once it is laid out, shows the same
        cv = c.view
        @test !isnothing(cv) && cv.opts === state.opts && cv.result === state.result
        # the spot colors are an option of the object, too
        v3 = results_view!(fig[2, 1], gui, pd; spot_colors = _ -> :red)
        @test !isnothing(state.opts.spot_colors) && state.opts.kind == :spot
        @test all(==(Makie.to_color(:red)), _result(v3).colors)
        close(v3)
        # the switch of the card changes the views in the figure
        cv.on_options(; kind = :psf)
        @test _shown(v) == :psf && _shown(v2) == :psf
        # expanding
        _widget(v2).on_expanded(true)
        @test _widget(v2).expanded

        # closed: no longer registered nor updated
        close(v)
        @test !_registered(gui, v) && _registered(gui, v2)
        r = _result(v)
        _retrace!(gui)
        @test _result(v) === r && _result(v2) === state.result !== r
        @test_throws ArgumentError refresh!(v)
        close(v2)
        @test isempty(gui.detectors.registered)
        @test_throws ArgumentError results_view!(Figure()[1, 1], gui, m)
        close(gui)
    end

    @testset "an own type with card_views" begin
        b = CountingBlock(20e-3, 2e-3)
        translate3d!(b, [0, 0.1, 0])
        sys = System([b])
        rays = _rays()
        # by name: an unknown one throws with the names of the views
        err = try
            results_view!(Figure()[1, 1], b; view = :nope)
        catch e
            e
        end
        @test err isa ArgumentError && occursin(":count", err.msg) && occursin(":map", err.msg)
        # without a live view: the field of the current state, the zoom computes it again
        solve_system!(sys, rays)
        v = results_view!(Figure()[1, 1], b; view = :map)
        @test _ok(v) && _shown(v) == :map && maximum(_result(v).data[3]) > 0
        window = (-0.5e-3, 0.5e-3, -0.5e-3, 0.5e-3)
        _widget(v).on_options(; window)
        @test first(_result(v).data[1]) ≈ -0.5e-3
        # the series: only its current value, nothing to clear
        _widget(v).on_options(; kind = :count)
        @test _ok(v) && _shown(v) == :count
        r = _result(v)
        _widget(v).on_options(; clear = true)
        @test _result(v) === r
        close(v)

        # with a live view: the series gets a value after each solve
        gui = _live_view(sys, _rays())
        v = results_view!(Figure()[1, 1], gui, b)
        @test _ok(v) && _shown(v) == :count
        n = length(_result(v).data)
        _retrace!(gui)
        @test _ok(v) && length(_result(v).data) == n + 1
        _retrace!(gui)
        @test length(_result(v).data) == n + 2
        # "clear" of the widget empties it
        _widget(v).on_options(; clear = true)
        @test isempty(_result(v).data)
        # the field shares its window with the cards of the window
        _widget(v).on_options(; kind = :map)
        @test _shown(v) == :map && GUI._detector_state(gui, b).opts.kind == :map
        close(v)
        @test !_registered(gui, v)
        close(gui)
    end
end

end
