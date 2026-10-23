module TestLiveSystemTrace

using GLMakie, BeamletOptics, BeamletOpticsGUI
using BeamletOptics: render_plots
using Makie
using Test

const BMO = BeamletOptics
const GUI = BeamletOpticsGUI

@testset "Tracing per system" begin

    # Each change is solved at once, see `TestLiveView.jl`; no card of a detector is pinned at start
    _live_view(args...; kwargs...) =
        live_view(args...; merge((; trace_budget = Inf, throttle = false, detectors = []), kwargs)...)

    _beam(y = 0.0) = Beam([0.0, y, 0], [0.0, 1, 0], 632.8e-9)
    # A mirror on the beams along +y, which it reflects along +x
    function _mirror(y = 0.1; x = 0.0)
        m = RoundPlanoMirror(25e-3, 5e-3)
        zrotate3d!(m, deg2rad(45))
        translate3d!(m, [x, y, 0])
        return m
    end
    function _target(beam)
        isect = BMO.intersection(first(BMO.rays(beam)))
        return isnothing(isect) ? nothing : BMO.object(isect)
    end
    _nhits(pd) = (h = BMO.hits(pd); isnothing(h) ? 0 : length(h))
    _plots(gui, src) = render_plots(gui.beam_handles[findfirst(p -> p.second === src, gui.pairs)])
    _dimmed(gui, src) = all(p -> p.alpha[] == GUI._STALE_ALPHA, _plots(gui, src))
    _bright(gui, src) = all(p -> p.alpha[] != GUI._STALE_ALPHA, _plots(gui, src))
    # Out of the beams and back
    _away!(gui, obj) = translate3d!(gui, obj, [0, 0, 1.0])
    _back!(gui, obj) = translate3d!(gui, obj, [0, 0, -1.0])

    # A transmitter and a receiver that share the mirror `m`; `a` is an object of the transmitter only
    function _lidar(; kwargs...)
        m, a = _mirror(), _mirror(0.5; x = 0.3)
        tx, rx = System([m, a]), System([m])
        b1, b2 = _beam(), _beam(0.05)
        gui = _live_view(tx => b1, rx => b2; kwargs...)
        return (; gui, m, a, tx, rx, b1, b2)
    end

    @testset "a system without auto tracing, $layout" for layout in (:compact, :app)
        (; gui, m, a, tx, rx, b1, b2) = _lidar(; layout)
        @test GUI._system_auto(gui, tx) && GUI._system_auto(gui, rx)
        GUI._set_system_auto!(gui, rx, false)
        @test GUI._system_auto(gui, tx) && !GUI._system_auto(gui, rx) && gui.trace.auto[]

        # the shared mirror: the transmitter is traced, the receiver is outdated
        _away!(gui, m)
        @test isnothing(_target(b1)) && _target(b2) === m
        @test GUI._system_stale(gui, rx) && !GUI._system_stale(gui, tx) && gui.trace.stale
        @test _dimmed(gui, b2) && _bright(gui, b1)
        # an object of the transmitter only: the receiver stays as it is
        _away!(gui, a)
        @test GUI._system_stale(gui, rx) && !GUI._system_stale(gui, tx) && _dimmed(gui, b2)

        # its own button: only this system
        GUI._trace_system!(gui, rx)
        @test isnothing(_target(b2)) && !GUI._system_stale(gui, rx) && !gui.trace.stale
        @test _bright(gui, b2) && _bright(gui, b1)

        # the transmitter on request: the receiver is not traced with it
        _back!(gui, m)
        @test _target(b1) === m && isnothing(_target(b2)) && _dimmed(gui, b2)
        GUI._trace_system!(gui, tx)
        @test isnothing(_target(b2)) && GUI._system_stale(gui, rx)

        # the trace button and `t` trace all systems
        GUI._trace!(gui)
        @test _target(b2) === m && !gui.trace.stale && _bright(gui, b2)

        # switched on again while it is outdated: traced
        _away!(gui, m)
        @test _target(b2) === m && GUI._system_stale(gui, rx)
        GUI._set_system_auto!(gui, rx, true)
        @test GUI._system_auto(gui, rx) && isnothing(_target(b2)) && !gui.trace.stale
        close(gui)
    end

    @testset "the switch of the view" begin
        (; gui, m, tx, rx, b1, b2) = _lidar()
        GUI._set_system_auto!(gui, rx, false)
        # it switches all systems
        gui.trace.auto[] = false
        @test !GUI._system_auto(gui, tx) && !GUI._system_auto(gui, rx) && isempty(gui.trace.manual)
        _away!(gui, m)
        @test _target(b1) === m && _target(b2) === m && _dimmed(gui, b1) && _dimmed(gui, b2)
        gui.trace.auto[] = true
        @test GUI._system_auto(gui, tx) && GUI._system_auto(gui, rx)
        @test isnothing(_target(b1)) && isnothing(_target(b2)) && !gui.trace.stale

        # it follows the systems: on while any of them is traced after each change
        gui.trace.auto[] = false
        GUI._set_system_auto!(gui, rx, true)
        @test gui.trace.auto[] && GUI._system_auto(gui, rx) && !GUI._system_auto(gui, tx)
        _back!(gui, m)
        @test _target(b2) === m && isnothing(_target(b1)) && _dimmed(gui, b1) && _bright(gui, b2)
        GUI._set_system_auto!(gui, rx, false)
        @test !gui.trace.auto[] && isempty(gui.trace.manual)
        close(gui)
    end

    @testset "systems that share a detector are traced together" begin
        m, a = _mirror(), _mirror(0.5; x = 0.3)
        pd = Detector(5e-3)
        zrotate3d!(pd, -π / 2)
        translate3d!(pd, [0.1, 0.1, 0])
        tx, rx, other = System([m, a, pd]), System([m, pd]), System([_mirror(0.2; x = 0.5)])
        b1, b2 = _beam(), _beam(0.05)
        gui = _live_view(tx => b1, rx => b2, other)
        @test _nhits(pd) == 2
        @test GUI._trace_set(gui, [tx]) == [tx, rx] && GUI._trace_set(gui, [other]) == [other]
        GUI._set_system_auto!(gui, rx, false)
        # a change of the transmitter only: the receiver is traced as well, its hits are kept
        translate3d!(gui, a, [0, 0, 1e-3])
        @test _nhits(pd) == 2 && !gui.trace.stale
        # the shared mirror: the receiver is outdated, but traced with the transmitter anyway
        _away!(gui, m)
        @test _nhits(pd) == 0 && isnothing(_target(b2)) && !gui.trace.stale
        close(gui)
    end

    @testset "members and sources" begin
        (; gui, m, tx, rx, b1, b2) = _lidar()
        GUI._set_system_auto!(gui, rx, false)
        # out of the receiver: only the receiver is affected, and it is outdated
        remove_component!(gui, m; system = rx)
        @test _target(b2) === m && GUI._system_stale(gui, rx) && !GUI._system_stale(gui, tx)
        GUI._trace_system!(gui, rx)
        @test isnothing(_target(b2)) && _target(b1) === m
        # a source that moves to the transmitter is traced through it at once
        add_component!(gui, b2; system = tx, select = false)
        @test _target(b2) === m && !gui.trace.stale
        # a new system is traced after each change
        new = add_system!(gui; select = false)
        @test GUI._system_auto(gui, new)
        close(gui)
    end
end

end
