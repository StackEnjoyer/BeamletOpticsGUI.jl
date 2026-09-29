module TestLiveBeamSwitch

using GLMakie, BeamletOptics, BeamletOpticsGUI
using BeamletOptics: render_plots
using Makie
using Test

const BMO = BeamletOptics
const GUI = BeamletOpticsGUI

@testset "Beams on and off" begin

    _live_view(args...; kwargs...) =
        live_view(args...; merge((; trace_budget = Inf, throttle = false, preview = false), kwargs)...)

    _key!(gui, key) = (events(gui.ax.scene).keyboardbutton[] = Makie.KeyEvent(key, Keyboard.press))

    # Two beams along +y, 20 mm apart, onto a detector facing them
    function _fixture()
        pd = Detector(50e-3)
        translate3d!(pd, [0, 0.1, 0])
        b1 = Beam([0.0, 0, 0], [0.0, 1, 0])
        b2 = Beam([20e-3, 0, 0], [0.0, 1, 0])
        return System([pd]), pd, b1, b2
    end

    _traced(b::BMO.AbstractBeam) = length(BMO.rays(b)) > 1 || !isnothing(BMO.intersection(first(BMO.rays(b))))
    _traced(bg::BMO.AbstractBeamGroup) = any(_traced, BMO.beams(bg))
    _nhits(pd) = (h = BMO.hits(pd); isnothing(h) ? 0 : length(h))
    # the plots of the beam `b` of the `gui`
    _plots(gui, b) = [p for (q, h) in zip(gui.pairs, gui.beam_handles) if q.second === b
                      for p in render_plots(h)]
    _visible(gui, b) = all(p -> p.visible[], _plots(gui, b))
    _hidden(gui, b) = all(p -> !p.visible[], _plots(gui, b))
    # the plots of the source marker of `b`
    _marker(gui, b) = only(h for h in BMO.render_children(gui.controls.h) if BMO.rendered(h) === b)

    @testset "off and on again" begin
        sys, pd, b1, b2 = _fixture()
        gui = _live_view(sys => b1, sys => b2)
        @test _traced(b1) && _traced(b2)
        @test _nhits(pd) == 2
        @test GUI._beam_on(gui, b2)

        GUI._set_beam_on!(gui, b2, false)
        @test !GUI._beam_on(gui, b2)
        @test !_traced(b2)
        @test _traced(b1)
        @test _hidden(gui, b2)
        @test _visible(gui, b1)
        # the hits come from the other beam only, at x = 0
        @test _nhits(pd) == 1
        @test all(x -> abs(x) < 1e-9, only(BMO.spot_diagram(pd)))
        # the source marker stays
        @test all(p -> p.visible[], render_plots(_marker(gui, b2)))
        @test !gui.trace.stale
        # unchanged state: nothing happens
        GUI._set_beam_on!(gui, b2, false)
        @test _nhits(pd) == 1

        GUI._set_beam_on!(gui, b2, true)
        @test GUI._beam_on(gui, b2)
        @test _traced(b2)
        @test _visible(gui, b2)
        @test _nhits(pd) == 2
        close(gui)
    end

    @testset "beam group" begin
        sys, pd, b1, _ = _fixture()
        src = CollimatedSource([20e-3, 0, 0], [0.0, 1, 0], 4e-3, 633e-9; num_rings = 2, num_rays = 40)
        gui = _live_view(sys => b1, sys => src)
        n = _nhits(pd)
        @test n > 1
        GUI._set_beam_on!(gui, src, false)
        @test all(!_traced(b) for b in BMO.beams(src))
        @test _hidden(gui, src)
        @test _nhits(pd) == 1
        GUI._set_beam_on!(gui, src, true)
        @test _traced(src)
        @test _nhits(pd) == n
        close(gui)
    end

    @testset "auto trace off marks the trace stale" begin
        sys, pd, b1, b2 = _fixture()
        gui = _live_view(sys => b1, sys => b2; auto_trace = false)
        GUI._trace!(gui)
        @test !gui.trace.stale
        GUI._set_beam_on!(gui, b2, false)
        @test gui.trace.stale
        @test occursin("outdated, press t to trace", gui.status.text[])
        # switched off, the beam is emptied at once, the detector keeps the old hits until the trace
        @test !_traced(b2)
        @test _hidden(gui, b2)
        @test _nhits(pd) == 2
        _key!(gui, Keyboard.t)
        @test !gui.trace.stale
        @test _nhits(pd) == 1
        GUI._set_beam_on!(gui, b2, true)
        @test gui.trace.stale
        @test _visible(gui, b2)
        @test !_traced(b2)
        GUI._trace!(gui)
        @test _traced(b2)
        @test _nhits(pd) == 2
        close(gui)
    end

    @testset "all beams off" begin
        sys, pd, b1, b2 = _fixture()
        gui = _live_view(sys => b1, sys => b2)
        GUI._set_beam_on!(gui, b1, false)
        GUI._set_beam_on!(gui, b2, false)
        @test !_traced(b1) && !_traced(b2)
        @test _nhits(pd) == 0
        @test !gui.trace.stale
        @test gui.status.text[] isa String && !isempty(gui.status.text[])
        # tracing without beams does not throw
        GUI._trace!(gui)
        @test !gui.trace.stale
        @test gui.status.text[] == "traced"
        @test isnothing(gui.last_error)
        GUI._set_beam_on!(gui, b1, true)
        @test _nhits(pd) == 1
        close(gui)
    end

    @testset "inspection ignores beams that are off" begin
        sys, pd, b1, b2 = _fixture()
        gui = _live_view(sys => b1, sys => b2)
        mid = [20e-3, 0.05, 0.0]
        set_view(gui.ax, [20e-3, 0.05, 0.25], mid, [0.0, 1, 0])
        scene = gui.ax.scene
        px = Makie.project(scene, :data, :pixel, Point3(mid))
        vp = scene.viewport[]
        events(scene).mouseposition[] = (vp.origin[1] + px[1], vp.origin[2] + px[2])
        info = GUI._inspect_beam(gui)
        @test !isnothing(info)
        @test maximum(abs.(info.point .- mid)) < 1e-6
        GUI._set_beam_on!(gui, b2, false)
        @test isnothing(GUI._inspect_beam(gui))
        close(gui)
    end

    @testset "beams_off" begin
        sys, pd, b1, b2 = _fixture()
        gui = _live_view(sys => b1, sys => b2; beams_off = [b2])
        @test !GUI._beam_on(gui, b2)
        @test !_traced(b2)
        @test _hidden(gui, b2)
        @test _traced(b1)
        @test _nhits(pd) == 1
        GUI._set_beam_on!(gui, b2, true)
        @test _traced(b2)
        @test _nhits(pd) == 2
        close(gui)
        # a beam that is not in the pairs
        other = Beam([0.0, 0, 0], [0.0, 1, 0])
        @test_throws ArgumentError _live_view(sys => b1; beams_off = [other])
    end

    @testset "untraced start with auto_trace = false" begin
        sys, pd, b1, b2 = _fixture()
        n_calls = Ref(0)
        gui = _live_view(sys => b1, sys => b2; auto_trace = false,
            on_change = (g, obj) -> (n_calls[] += 1))
        @test !_traced(b1) && !_traced(b2)
        @test _nhits(pd) == 0
        @test n_calls[] == 0
        @test gui.trace.stale
        @test gui.status.text[] == "not traced, press t to trace"
        _key!(gui, Keyboard.t)
        @test _traced(b1) && _traced(b2)
        @test _nhits(pd) == 2
        @test !gui.trace.stale
        @test n_calls[] == 1
        close(gui)

        # switching auto trace on traces as well
        sys, pd, b1, b2 = _fixture()
        gui = _live_view(sys => b1, sys => b2; auto_trace = false)
        @test gui.trace.stale
        gui.widgets.auto_trace_toggle.active[] = true
        @test !gui.trace.stale
        @test _nhits(pd) == 2
        close(gui)
    end
end

end
