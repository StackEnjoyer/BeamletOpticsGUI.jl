module TestMultiSelectRemove

using GLMakie, BeamletOptics, BeamletOpticsGUI
using BeamletOptics: render_children, rendered
using Makie
using Test

const BMO = BeamletOptics
const GUI = BeamletOpticsGUI

@testset "Removing and solving a selection of several objects" begin

    # Each change is solved at once, see `TestLiveView.jl`; no card of a detector is pinned at start
    _live_view(args...; kwargs...) =
        live_view(args...; merge((; trace_budget = Inf, throttle = false, detectors = [],
            catalog = CatalogEntry[]), kwargs)...)

    _beam() = Beam([0.0, 0, 0], [0.0, 1, 0])

    # A mirror on the beam along +y, which it reflects along +x
    function _mirror(y = 0.1)
        m = RoundPlanoMirror(25e-3, 5e-3)
        zrotate3d!(m, deg2rad(45))
        translate3d!(m, [0, y, 0])
        return m
    end

    # A detector on the reflected beam along +x
    function _detector()
        pd = Detector(5e-3)
        zrotate3d!(pd, -π / 2)
        translate3d!(pd, [0.1, 0.1, 0])
        return pd
    end

    _in(obj, list) = any(o -> o === obj, list)
    _rendered(gui, obj) = !isnothing(GUI._child_handle(gui.controls.h, obj))

    # Selects several objects without the listeners of the selection, i.e. without the card of the
    # selection of several (W3); `select!(gui, objs)` once that card exists
    function _select_several!(gui, objs)
        gui.controls.selected.val = GUI._MultiSelection(objs)
        GUI._update_selection_box!(gui.controls)
        return gui.controls.selected[]
    end

    @testset "Delete removes all as one action, $layout" for layout in (:compact, :app)
        m1, m2, pd = _mirror(), _mirror(0.3), _detector()
        sys = System([m1, m2, pd])
        gui = _live_view(sys => _beam(); layout)
        ctrl = gui.controls
        @test BMO.hit_count(pd) == 1
        s = _select_several!(gui, [m1, pd])
        n = length(ctrl.undo_stack)
        @test GUI._delete_selected!(gui, s)
        @test sys.objects == [m2]
        @test !_rendered(gui, m1) && !_rendered(gui, pd)
        @test isnothing(ctrl.selected[])
        @test occursin("2 objects removed", gui.status.text[])
        # one entry of the undo history
        @test length(ctrl.undo_stack) == n + 1
        @test isnothing(gui.trace.error) && !gui.trace.stale

        @test GUI._undo!(ctrl)
        @test length(sys.objects) == 3 && _in(m1, sys.objects) && _in(pd, sys.objects)
        @test _rendered(gui, m1) && _rendered(gui, pd)
        wait_solve(gui)
        @test BMO.hit_count(pd) == 1
        sel = ctrl.selected[]
        @test sel isa GUI._MultiSelection && sel.objects == Any[m1, pd]

        @test GUI._redo!(ctrl)
        @test sys.objects == [m2]
        @test !_rendered(gui, m1) && !_rendered(gui, pd)
        @test isnothing(ctrl.selected[])
        close(gui)
    end

    @testset "an object that can not be removed stays selected, $layout" for layout in (:compact, :app)
        m1, m2 = _mirror(), _mirror(0.2)
        static, sys = StaticSystem([m1]), System([m2])
        gui = _live_view(static => _beam(), sys => Beam([0.05, 0, 0], [0.0, 1, 0]); layout)
        ctrl = gui.controls
        s = _select_several!(gui, [m1, m2])
        n = length(ctrl.undo_stack)
        @test GUI._remove_selected!(gui, s)
        @test isempty(sys.objects) && _in(m1, static.objects)
        @test ctrl.selected[] === m1
        @test occursin("removed", gui.status.text[]) && occursin("StaticSystem", gui.status.text[])
        @test length(ctrl.undo_stack) == n + 1
        @test GUI._undo!(ctrl)
        @test sys.objects == [m2]

        # none can be removed: nothing changes
        m3 = _mirror(0.4)
        close(gui)
        gui = _live_view(StaticSystem([m1, m3]) => _beam(); layout)
        ctrl = gui.controls
        s = _select_several!(gui, [m1, m3])
        n = length(ctrl.undo_stack)
        @test !GUI._remove_selected!(gui, s)
        @test ctrl.selected[] === s && _rendered(gui, m1) && _rendered(gui, m3)
        @test occursin("nothing removed", gui.status.text[])
        @test length(ctrl.undo_stack) == n
        close(gui)
    end

    @testset "removing an object drops it from the selection, $layout" for layout in (:compact, :app)
        m1, m2 = _mirror(), _mirror(0.3)
        sys = System([m1, m2])
        gui = _live_view(sys => _beam(); layout)
        _select_several!(gui, [m1, m2])
        remove_component!(gui, m1)
        @test gui.controls.selected[] === m2
        @test sys.objects == [m2]
        close(gui)
    end

    @testset "moving solves once and calls on_change per object, $layout" for layout in (:compact, :app)
        m1, m2, pd = _mirror(), _mirror(0.3), _detector()
        sys = System([m1, m2, pd])
        calls = Any[]
        gui = _live_view(sys => _beam(); layout, on_change = (gui, obj) -> push!(calls, obj))
        @test BMO.hit_count(pd) == 1
        s = _select_several!(gui, [m1, pd])
        # the systems of the first object get new components, see `_target_system`
        @test GUI._target_system(gui) === sys
        empty!(calls)
        # off the beam along +y: the detector is no longer hit
        translate3d!(s, [0.05, 0, 0])
        gui.controls.on_change(s)
        wait_solve(gui)
        @test isnothing(gui.trace.error) && !gui.trace.stale
        @test BMO.hit_count(pd) == 0
        @test calls == Any[m1, pd]
        @test !any(c -> c isa GUI._MultiSelection, calls)
        @test occursin("2 objects", gui.status.text[])
        # and back
        empty!(calls)
        translate3d!(s, [-0.05, 0, 0])
        gui.controls.on_change(s)
        wait_solve(gui)
        @test BMO.hit_count(pd) == 1
        @test calls == Any[m1, pd]
        # tracing on request with the selection
        empty!(calls)
        GUI._trace!(gui)
        wait_solve(gui)
        @test calls == Any[m1, pd]
        close(gui)

        # extras only: nothing is traced
        h1, h2 = _mirror(0.5), _mirror(0.6)
        gui = _live_view(System([_mirror()]) => _beam(); layout, extras = [h1, h2])
        s = _select_several!(gui, [h1, h2])
        @test isempty(GUI._systems_of(gui, s))
        translate3d!(s, [0.0, 0, 0.01])
        gui.controls.on_change(s)
        @test !gui.trace.stale
        @test occursin("2 objects", gui.status.text[])
        close(gui)
    end

    @testset "Ctrl+C copies nothing, $layout" for layout in (:compact, :app)
        m1, m2 = _mirror(), _mirror(0.3)
        gui = _live_view(System([m1, m2]) => _beam(); layout)
        kept = GUI._CLIPBOARD[]
        _select_several!(gui, [m1, m2])
        @test isnothing(GUI._copy_selected!(gui))
        @test GUI._CLIPBOARD[] === kept
        @test occursin("2 objects selected", gui.status.text[])
        close(gui)
    end
end

end
