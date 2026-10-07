module TestLiveSystems

using GLMakie, BeamletOptics, BeamletOpticsGUI
using BeamletOptics: render_children, render_plots, rendered
using Makie
using Test

const BMO = BeamletOptics
const GUI = BeamletOpticsGUI

@testset "Live systems" begin

    # Each change is solved at once, see `TestLiveView.jl`; no card of a detector is pinned at start
    _live_view(args...; kwargs...) =
        live_view(args...; merge((; trace_budget = Inf, throttle = false, detectors = []), kwargs)...)

    _beam(y = 0.0) = Beam([0.0, y, 0], [0.0, 1, 0], 632.8e-9)
    # A mirror on the beams along +y
    function _mirror(y = 0.1)
        m = RoundPlanoMirror(25e-3, 5e-3)
        zrotate3d!(m, deg2rad(45))
        translate3d!(m, [0, y, 0])
        return m
    end
    # The number of object handles of `obj` in the controls: one, also for an object of two systems
    _handles(gui, obj) = count(oh -> rendered(oh) === obj, render_children(gui.controls.h))
    function _target(beam)
        isect = BMO.intersection(first(BMO.rays(beam)))
        return isnothing(isect) ? nothing : BMO.object(isect)
    end
    _beam_handle(gui, src) = gui.beam_handles[findfirst(p -> p.second === src, gui.pairs)]
    _drawn(gui, src) = any(p -> p.visible[], render_plots(_beam_handle(gui, src)))
    _undo!(gui) = GUI._undo!(gui.controls)
    _redo!(gui) = GUI._redo!(gui.controls)

    @testset "an object of two systems, $layout" for layout in (:compact, :app)
        m = _mirror()
        tx, rx = System([m]), System([m])
        b1, b2 = _beam(), _beam(0.05)
        gui = _live_view(tx => b1, rx => b2; layout)
        # one object, drawn once
        @test _handles(gui, m) == 1 && length(render_children(gui.pool)) == 1
        @test GUI._member_systems(gui, m) == [tx, rx]
        @test _target(b1) === m && _target(b2) === m
        GUI._set_hidden!(gui, m, true)
        @test !any(p -> p.visible[], render_plots(GUI._child_handle(gui.controls.h, m)))
        GUI._set_hidden!(gui, m, false)

        # out of one system: only its beam passes
        remove_component!(gui, m; system = rx)
        @test tx.objects == [m] && isempty(rx.objects)
        @test _target(b1) === m && isnothing(_target(b2))
        @test _handles(gui, m) == 1 && !GUI._is_extra(gui, m)
        @test_throws ArgumentError remove_component!(gui, m; system = rx)
        @test _undo!(gui)
        @test rx.objects == [m] && _target(b2) === m
        @test _redo!(gui)
        @test isempty(rx.objects) && isnothing(_target(b2))

        # out of its last system: it stays in the view without a system and is not traced
        remove_component!(gui, m; system = tx)
        @test GUI._is_extra(gui, m) && _handles(gui, m) == 1
        @test isempty(GUI._member_systems(gui, m)) && isnothing(_target(b1))
        @test occursin("no system", gui.status.text[])
        add_component!(gui, m; system = rx, select = false)
        @test !GUI._is_extra(gui, m) && _target(b2) === m && isnothing(_target(b1))
        @test_throws ArgumentError add_component!(gui, m; system = rx)

        # removed from the view
        add_component!(gui, m; system = tx, select = false)
        remove_component!(gui, m)
        @test _handles(gui, m) == 0 && isempty(tx.objects) && isempty(rx.objects)
        @test isempty(render_children(gui.pool))
        @test _undo!(gui)
        @test tx.objects == [m] && rx.objects == [m] && _handles(gui, m) == 1
        @test _target(b1) === m && _target(b2) === m
        close(gui)
    end

    @testset "without a system" begin
        sys = System()
        beam = _beam()
        gui = _live_view(sys => beam)
        m = _mirror()
        add_component!(gui, m; system = :none)
        @test isempty(sys.objects) && GUI._is_extra(gui, m) && isnothing(_target(beam))
        @test gui.components.added == [m] && _handles(gui, m) == 1
        @test_throws ArgumentError add_component!(gui, _mirror(0.2); system = :other)
        add_component!(gui, m; system = sys, select = false)
        @test _target(beam) === m && !GUI._is_extra(gui, m)
        # an object without a system is removed like any other, and comes back without one
        remove_component!(gui, m; system = sys)
        remove_component!(gui, m)
        @test _handles(gui, m) == 0 && !GUI._is_extra(gui, m)
        @test _undo!(gui)
        @test GUI._is_extra(gui, m) && _handles(gui, m) == 1 && isempty(sys.objects)

        # a source without a system: its marker, but neither traced nor drawn
        add_component!(gui, m; system = sys, select = false)
        src = _beam(0.01)
        add_component!(gui, src; system = :none, select = false)
        @test isnothing(GUI._system_of_source(gui, src)) && src in gui.beams.unassigned
        @test !GUI._beam_on(gui, src) && !_drawn(gui, src) && isnothing(_target(src))
        @test _handles(gui, src) == 1
        add_component!(gui, src; system = sys, select = false)
        @test GUI._system_of_source(gui, src) === sys && _drawn(gui, src) && _target(src) === m
        remove_component!(gui, src; system = sys)
        @test isnothing(GUI._system_of_source(gui, src)) && !_drawn(gui, src) && isnothing(_target(src))
        @test _target(beam) === m
        @test_throws ArgumentError add_component!(gui, src)
        close(gui)
    end

    @testset "systems at runtime, $layout" for layout in (:compact, :app)
        m = _mirror()
        tx = System([m])
        b1 = _beam()
        gui = _live_view(tx => b1; layout)
        @test_throws ArgumentError remove_system!(gui, tx)
        rx = add_system!(gui; label = "Receiver")
        @test GUI._systems(gui) == [tx, rx] && GUI._label(gui, rx) == "Receiver"
        @test gui.objects.inspected === rx && GUI._target_system(gui) === rx
        other = add_system!(gui; select = false)
        @test GUI._label(gui, other) == "System 3" && GUI._systems(gui) == [tx, rx, other]
        add_component!(gui, m; system = rx, select = false)
        b2 = _beam(0.05)
        add_component!(gui, b2; system = rx, select = false)
        own = _mirror(0.3)
        add_component!(gui, own; system = rx, select = false)
        @test _target(b2) === m && _handles(gui, m) == 1

        # nothing is deleted: its sources and its own objects have no system afterwards
        remove_system!(gui, rx)
        @test GUI._systems(gui) == [tx, other] && rx.objects == [m, own]
        @test !GUI._is_extra(gui, m) && GUI._is_extra(gui, own) && _handles(gui, own) == 1
        @test isnothing(GUI._system_of_source(gui, b2)) && isnothing(_target(b2))
        @test _target(b1) === m
        @test_throws ArgumentError remove_system!(gui, rx)
        @test _undo!(gui)
        @test GUI._systems(gui) == [tx, rx, other] && !GUI._is_extra(gui, own)
        @test GUI._system_of_source(gui, b2) === rx && _target(b2) === m
        @test _redo!(gui)
        @test GUI._systems(gui) == [tx, other] && GUI._is_extra(gui, own)
        close(gui)
    end

    @testset "a source belongs to one system" begin
        a, b = System([_mirror()]), System()
        beam = _beam()
        @test_throws ArgumentError _live_view(a => beam, b => beam)
        @test_throws ArgumentError _live_view(a => beam, a => beam)
    end

    @testset "export" begin
        m = _mirror()
        tx, rx = System([m]), System()
        beam = _beam()
        gui = _live_view(tx => beam, rx; labels = Dict(m => "m", beam => "laser"))
        @test occursin("# no changes", GUI._export_code(gui)[1])
        add_component!(gui, m; system = rx, select = false)
        code, n = GUI._export_code(gui)
        @test n == 1 && occursin("\npush!(system2, m)\n", code) && !occursin("delete!", code)
        remove_component!(gui, m; system = tx)
        code, n = GUI._export_code(gui)
        @test n == 1 && occursin("\npush!(system2, m)\n", code) && occursin("\ndelete!(system1, m)\n", code)
        # a system of the window, and a source that is traced through it
        new = add_system!(gui; select = false)
        add_component!(gui, beam; system = new, select = false)
        code, n = GUI._export_code(gui)
        @test n == 3 && occursin("\nsystem3 = System()\n", code)
        @test occursin("# trace laser through system3 instead", code)
        # the script constructs an object of two systems once
        add_component!(gui, m; system = tx, select = false)
        script = GUI._export_script_code(gui)
        @test count("\n# m = … (", script) == 1
        @test occursin("\n# push!(system1, m)\n", script) && occursin("\n# push!(system2, m)\n", script)
        close(gui)
    end
end

end
