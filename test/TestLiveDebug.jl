module TestLiveDebug

using GLMakie, BeamletOptics, BeamletOpticsGUI
using Makie
using Test

const BMO = BeamletOptics
const GUI = BeamletOpticsGUI

# A layer of the debug mode that counts the calls of its hooks, see `GUI._DebugLayer`
mutable struct _CountingLayer <: GUI._DebugLayer
    counts::Dict{Symbol, Int}
    objs::Dict{Symbol, Vector{Any}}
    shown::Union{Nothing, Bool}
end
_CountingLayer() = _CountingLayer(Dict{Symbol, Int}(), Dict{Symbol, Vector{Any}}(), nothing)

function _count!(l::_CountingLayer, hook::Symbol, obj = nothing)
    l.counts[hook] = get(l.counts, hook, 0) + 1
    push!(get!(l.objs, hook, Any[]), obj)
    return nothing
end
_n(l::_CountingLayer, hook::Symbol) = get(l.counts, hook, 0)

GUI._layer_show!(::GUI.LiveView, l::_CountingLayer, on::Bool) = (l.shown = on; _count!(l, :show))
GUI._layer_moved!(::GUI.LiveView, l::_CountingLayer, obj) = _count!(l, :moved, obj)
GUI._layer_attached!(::GUI.LiveView, l::_CountingLayer, obj) = _count!(l, :attached, obj)
GUI._layer_released!(::GUI.LiveView, l::_CountingLayer, obj) = _count!(l, :released, obj)
GUI._layer_hidden!(::GUI.LiveView, l::_CountingLayer) = _count!(l, :hidden)
GUI._layer_solved!(::GUI.LiveView, l::_CountingLayer) = _count!(l, :solved)
GUI._layer_stale!(::GUI.LiveView, l::_CountingLayer) = _count!(l, :stale)
GUI._layer_tick!(::GUI.LiveView, l::_CountingLayer, tick) = _count!(l, :tick, tick)

@testset "Debug mode" begin
    # Beam along +y onto a mirror at 45° at y = 0.3, a detector beside it at x = 0.2
    function _fixture(; source = Beam([0.0, 0, 0], [0.0, 1, 0], 1e-6), kwargs...)
        m = RoundPlanoMirror(25e-3, 5e-3)
        zrotate3d!(m, deg2rad(45))
        translate3d!(m, [0, 0.3, 0])
        pd = Detector(50e-3)
        zrotate3d!(pd, deg2rad(90))
        translate3d!(pd, [0.2, 0.3, 0])
        sys = System([m, pd])
        gui = live_view(sys => source; trace_budget = Inf, throttle = false, preview = false,
            plane_normal = [0, 0, 1], kwargs...)
        set_view(gui.ax, [0.25, -0.2, 0.5], [0.0, 0.15, 0.0], [0.0, 0, 1])
        return gui, sys, m, pd, source
    end

    function _pixel(gui, point)
        scene = gui.ax.scene
        p = Makie.project(scene, :data, :pixel, Point3f(point))[Vec(1, 2)]
        return Point2f(Makie.viewport(scene)[].origin) .+ p
    end
    _mouse!(gui, px) = (events(gui.ax.scene).mouseposition[] = (Float64(px[1]), Float64(px[2])))
    _button!(gui, action) = (events(gui.ax.scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, action))
    function _drag!(gui, obj, by; steps = 4)
        gui.controls.selected[] = obj
        p0 = _pixel(gui, position(obj))
        _mouse!(gui, p0)
        _button!(gui, Mouse.press)
        foreach(k -> _mouse!(gui, p0 .+ (k / steps) .* Point2f(by)), 1:steps)
        _button!(gui, Mouse.release)
        return nothing
    end
    clock = Ref(0.0)
    _tick!(gui) = (clock[] += 1.0;
        events(gui.ax.scene).tick[] = Makie.Tick(Makie.RegularRenderTick, 0, clock[], 1.0))
    _layer_names(gui) = first.(GUI._debug(gui).layers)
    _kinds(gui) = [r.kind for r in GUI._debug(gui).stats.solves]
    _texts(gui) = last.(GUI._debug(gui).stats.events)

    @testset "off by default: no layers, records or compile timing" begin
        gui, sys, m = _fixture()
        d = GUI._debug(gui)
        @test !isnothing(d) && !GUI._debug_on(gui)
        @test !isnothing(d.toggle) && !d.toggle.active[]
        @test isempty(d.layers) && !d.created && !d.timing
        GUI._resolve!(gui, nothing)
        translate3d!(gui, m, [0.0, 0.01, 0.0])
        GUI._mark_stale!(gui, nothing)
        _tick!(gui)
        @test isempty(d.stats.solves) && isempty(d.stats.events)
        @test isempty(d.layers) && !d.timing
        @test d.stats.update == 0.0
        @test GUI._debug_kwarg(d) == false && GUI._debug_kwarg(nothing) == false
        close(gui)
    end

    @testset "toggle and kwarg switch the mode" begin
        gui, = _fixture()
        d = GUI._debug(gui)
        status = gui.status.text[]
        d.toggle.active[] = true
        @test GUI._debug_on(gui) && d.created && d.timing
        @test all(name -> name in _layer_names(gui), GUI._DEBUG_LAYERS)
        @test gui.status.text[] == "debug mode on"
        @test "debug mode on" in _texts(gui)
        n = length(d.layers)
        d.toggle.active[] = false
        @test !GUI._debug_on(gui) && !d.timing
        @test gui.status.text[] == "debug mode off"
        # the layers are created once
        d.toggle.active[] = true
        @test length(d.layers) == n
        @test GUI._debug_kwarg(d)
        close(gui)
        # closing the window ends the compile timing
        @test !d.timing

        # the kwarg starts the mode without a message in the status line
        gui, = _fixture(; debug = true)
        d = GUI._debug(gui)
        @test GUI._debug_on(gui) && d.toggle.active[] && d.timing
        @test gui.status.text[] != "debug mode on"
        # the initial solve is recorded
        @test _kinds(gui) == [:full]
        close(gui)
    end

    @testset "hooks of the layers" begin
        gui, sys, m, pd = _fixture()
        l = GUI._register_layer!(gui, :counting, _CountingLayer())
        # registered while the mode is off: hidden, and no hook is called
        @test l.shown === false
        GUI._resolve!(gui, nothing)
        translate3d!(gui, m, [0.0, 0.001, 0.0])
        _tick!(gui)
        @test all(h -> _n(l, h) == 0, (:moved, :solved, :tick))

        # switched on: shown, and the layer catches up with the view
        GUI._set_debug!(gui, true)
        @test l.shown === true
        @test _n(l, :moved) == 1 && only(l.objs[:moved]) === nothing
        @test _n(l, :solved) == 1 && _n(l, :hidden) == 1

        # move by script
        empty!(l.counts), empty!(l.objs)
        translate3d!(gui, m, [0.0, -0.001, 0.0])
        @test _n(l, :moved) >= 1 && any(o -> o === m, l.objs[:moved])
        # the move is solved
        @test _n(l, :solved) >= 1
        @test GUI._debug(gui).stats.update > 0

        # move by drag
        empty!(l.counts), empty!(l.objs)
        GUI._debug(gui).stats.update = 0.0
        P0 = Vector{Float64}(position(m))
        _drag!(gui, m, (20, 0))
        @test Vector{Float64}(position(m)) != P0
        @test _n(l, :moved) >= 1 && any(o -> o === m, l.objs[:moved])
        @test GUI._debug(gui).stats.update > 0

        # retrace! of a change from code
        empty!(l.counts), empty!(l.objs)
        retrace!(() -> nothing, gui)
        @test _n(l, :moved) == 1 && only(l.objs[:moved]) === nothing

        # add and remove
        empty!(l.counts), empty!(l.objs)
        m2 = RoundPlanoMirror(25e-3, 5e-3)
        translate3d!(m2, [0.0, 0.6, 0.0])
        add_component!(gui, m2; system = sys, label = "M2", select = false)
        @test _n(l, :attached) == 1 && only(l.objs[:attached]) === m2
        @test "added M2" in _texts(gui)
        remove_component!(gui, m2)
        @test _n(l, :released) == 1 && only(l.objs[:released]) === m2
        @test "removed M2" in _texts(gui)
        # a source as well
        b2 = Beam([0.05, 0, 0], [0.0, 1, 0], 1e-6)
        add_component!(gui, b2; system = sys, label = "B2", select = false)
        @test any(o -> o === b2, l.objs[:attached])
        remove_component!(gui, b2)
        @test any(o -> o === b2, l.objs[:released])

        # hide and show
        empty!(l.counts), empty!(l.objs)
        GUI._set_hidden!(gui, pd, true)
        @test _n(l, :hidden) == 1
        GUI._set_hidden!(gui, pd, false)
        @test _n(l, :hidden) == 2

        # solve and stale
        empty!(l.counts), empty!(l.objs)
        GUI._resolve!(gui, nothing)
        @test _n(l, :solved) == 1 && _n(l, :stale) == 0
        GUI._mark_stale!(gui, nothing)
        @test _n(l, :stale) == 1
        GUI._trace!(gui)
        @test _n(l, :solved) == 2

        # ticks
        _tick!(gui)
        _tick!(gui)
        @test _n(l, :tick) == 2 && l.objs[:tick][end] isa Makie.Tick

        # the spectator mode hides the layers, leaving it shows them again
        spectator!(gui)
        @test l.shown === false
        spectator!(gui, false)
        @test l.shown === true

        # switched off: hidden, and no hook is called
        GUI._set_debug!(gui, false)
        @test l.shown === false
        empty!(l.counts), empty!(l.objs)
        translate3d!(gui, m, [0.0, 0.001, 0.0])
        GUI._mark_stale!(gui, nothing)
        GUI._set_hidden!(gui, pd, true)
        _tick!(gui)
        @test all(h -> _n(l, h) == 0, (:moved, :solved, :stale, :hidden, :tick))
        # the spectator mode does not show it while the mode is off
        spectator!(gui)
        spectator!(gui, false)
        @test l.shown === false
        close(gui)
    end

    @testset "records of the solves" begin
        src = CollimatedSource([0.0, 0, 0], [0.0, 1, 0], 2e-3, 1e-6; num_rings = 2, num_rays = 40)
        gui, = _fixture(; source = src, labels = Dict(src => "S"))
        GUI._set_debug!(gui, true)
        d = GUI._debug(gui)
        solves = d.stats.solves

        # a full solve: solve + render is the duration that the budget uses
        GUI._resolve!(gui, nothing)
        r = solves[end]
        @test r.kind == :full
        @test abs(r.solve + r.render - gui.trace.solve_time) < 1e-6
        @test r.solve > 0 && r.render >= 0 && r.view >= 0
        @test length(r.sources) == 1 && r.sources[1].first == "S" && r.sources[1].second > 0
        @test r.sources[1].second <= r.solve
        @test r.compile >= 0 && r.gc >= 0 && r.allocated > 0
        @test r.time <= time()
        @test any(t -> startswith(t, "solve full"), _texts(gui))

        # a preview of the beam group, which renders every 5th beam
        n = length(solves)
        GUI._resolve!(gui, nothing; preview = true)
        @test length(solves) == n + 1 && solves[end].kind == :preview
        @test abs(solves[end].solve + solves[end].render - gui.trace.preview_time) < 1e-6

        # a coarse one
        GUI._resolve!(gui, nothing; coarse = true)
        @test length(solves) == n + 2 && solves[end].kind == :coarse

        # a solve in the background that is cancelled
        sink = BMO.ProgressSink()
        done = Base.Event()
        task = Threads.@spawn try
            while !sink.cancel[]
                sleep(0.001)
            end
        finally
            notify(done)
        end
        job = GUI._SolveJob(task, done, [sink], [Point3f(0)], r -> nothing, nothing, :solve_time,
            time() - 0.05, (; k = 0, t0 = NaN, t = NaN, count = 0))
        gui.trace.job = job
        GUI._cancel_solve!(gui)
        @test length(solves) == n + 3 && solves[end].kind == :cancelled
        # `time()` near 1.7e9 s rounds the difference of the two timestamps to some 1e-7 s
        @test solves[end].solve >= 0.049 && solves[end].render == 0
        @test any(t -> startswith(t, "solve cancelled"), _texts(gui))

        # a job that only computes the detector views is no solve
        sink = BMO.ProgressSink()
        done = Base.Event()
        task = Threads.@spawn (notify(done); nothing)
        gui.trace.job = GUI._SolveJob(task, done, [sink], [Point3f(0)], r -> nothing, nothing,
            :view_time, time(), (; k = 0, t0 = NaN, t = NaN, count = 0))
        GUI._cancel_solve!(gui)
        @test length(solves) == n + 3

        # a failed solve
        @test_logs (:error, r"solving the systems failed") GUI._fail!(gui, ErrorException("boom\nmore"))
        @test length(solves) == n + 4 && solves[end].kind == :failed
        @test "solve failed: boom" in _texts(gui)

        # a solve that runs in the background like after a move
        GUI._solve!(gui, nothing)
        @test timedwait(() -> (notify(events(gui.ax.scene).tick); !GUI._running(gui)), 10.0;
            pollint = 0.005) === :ok
        @test length(solves) == n + 5 && solves[end].kind == :full
        @test abs(solves[end].solve + solves[end].render - gui.trace.solve_time) < 1e-6

        # rings of at most 20 solves and 50 events
        foreach(_ -> GUI._resolve!(gui, nothing), 1:25)
        @test length(solves) == GUI._DEBUG_SOLVES
        foreach(i -> GUI._debug_event!(gui, "event $i"), 1:60)
        @test length(d.stats.events) == GUI._DEBUG_EVENTS
        @test d.stats.events[end].second == "event 60"

        # switched off, nothing is recorded
        GUI._set_debug!(gui, false)
        k = length(d.stats.events)
        last_record = solves[end]
        GUI._resolve!(gui, nothing)
        @test solves[end] === last_record && length(d.stats.events) == k
        GUI._debug_event!(gui, "ignored")
        @test length(d.stats.events) == k
        close(gui)
    end

    @testset "errors of callbacks are events" begin
        gui, = _fixture(; debug = true)
        @test_logs (:error, r"tool \"Broken\"") begin
            w = add_tool!(gui -> error("broken tool"), gui, "Broken")
            w.clicks[] += 1
        end
        @test any(t -> occursin("error in tool \"Broken\": broken tool", t), _texts(gui))
        close(gui)
    end

    @testset "open_system takes the mode over" begin
        gui, sys = _fixture(; debug = true)
        new = open_system(gui, sys; display = false)
        @test GUI._debug_on(new)
        @test any(t -> startswith(t, "linked view opened"), _texts(gui))
        close(new)
        GUI._set_debug!(gui, false)
        new = open_system(gui, sys; display = false)
        @test !GUI._debug_on(new)
        close(new)
        close(gui)
    end
end

end
