module TestLiveHistory

using GLMakie, BeamletOptics, BeamletOpticsGUI
using BeamletOptics: render_children, render_plots, rendered
using Makie
using LinearAlgebra: norm
using Test

const BMO = BeamletOptics
const GUI = BeamletOpticsGUI

@testset "Undo history of the components" begin

    # Each change is solved at once, see `TestLiveView.jl`; no card of a detector is pinned at start
    _live_view(args...; kwargs...) =
        live_view(args...; merge((; trace_budget = Inf, throttle = false, detectors = []), kwargs)...)

    _beam(x = 0.0) = Beam([x, 0, 0], [0.0, 1, 0], 632.8e-9)
    function _mirror(y = 0.1; x = 0.0)
        m = RoundPlanoMirror(25e-3, 5e-3)
        zrotate3d!(m, deg2rad(45))
        translate3d!(m, [x, y, 0])
        return m
    end
    _in(obj, list) = any(o -> o === obj, list)
    _paired(gui, src) = any(p -> p.second === src, gui.pairs)
    _rendered(gui, obj) = !isnothing(GUI._child_handle(gui.controls.h, obj))
    function _target(beam)
        isect = BMO.intersection(first(BMO.rays(beam)))
        return isnothing(isect) ? nothing : BMO.object(isect)
    end
    # Ctrl+Z and Ctrl+Y of the controls
    _undo!(gui) = GUI._undo!(gui.controls)
    _redo!(gui) = GUI._redo!(gui.controls)
    _hex(c) = GUI._color_hex(Makie.to_color(c))

    @testset "add a component, $layout" for layout in (:compact, :app)
        sys = System()
        beam = _beam()
        gui = _live_view(sys => beam; layout)
        nplots = length(gui.ax.scene.plots)
        m = _mirror()
        origin = (; code = "RoundPlanoMirror(0.025, 0.005)", pose0 = GUI._pose(RoundPlanoMirror(25e-3, 5e-3)))
        add_component!(gui, m; label = "m1", origin)
        @test length(gui.controls.undo_stack) == 1 && isempty(gui.controls.redo_stack)
        @test _target(beam) === m

        # undo: as before it was added
        @test _undo!(gui)
        @test isempty(sys.objects) && !_rendered(gui, m)
        @test length(gui.ax.scene.plots) == nplots
        @test isnothing(_target(beam))
        @test isempty(gui.components.added) && isempty(gui.components.removed)
        @test occursin("# no changes", GUI._export_code(gui)[1])
        @test isempty(gui.controls.undo_stack) && length(gui.controls.redo_stack) == 1

        # redo: with its label, its origin and in its pose, and traced
        P, R = GUI._pose(m)
        @test _redo!(gui)
        @test sys.objects == [m] && sys.objects[1] === m && _rendered(gui, m)
        @test GUI._label(gui, m) == "m1"
        @test gui.components.origin[m] === origin && gui.components.added == [m]
        @test GUI._pose(m) == (P, R)
        @test _target(beam) === m
        @test gui.controls.selected[] === m
        @test length(gui.controls.undo_stack) == 1 && isempty(gui.controls.redo_stack)
        # ... again and again
        @test _undo!(gui) && _redo!(gui) && _undo!(gui)
        @test isempty(sys.objects)
        @test !_undo!(gui)
        close(gui)
    end

    @testset "remove a component, with moves, $layout" for layout in (:compact, :app)
        m, m2 = _mirror(), _mirror(0.2; x = 0.1)
        sys = System([m, m2])
        beam = _beam()
        gui = _live_view(sys => beam; layout, labels = Dict(m => "first"), fine_step = 1e-3)
        ctrl = gui.controls
        P0 = collect(Float64, position(m))
        name2 = GUI._label(gui, m2)

        # moved, then removed
        ctrl.selected[] = m
        events(gui.ax.scene).keyboardbutton[] = Makie.KeyEvent(Keyboard.page_up, Keyboard.press)
        P1 = collect(Float64, position(m))
        @test norm(P1 - P0) ≈ 1e-3
        remove_component!(gui, m)
        @test length(ctrl.undo_stack) == 2
        @test sys.objects == [m2] && isnothing(_target(beam))

        # undo of the removal: back in its system, moved as it was, with its label
        @test _undo!(gui)
        @test _in(m, sys.objects) && _rendered(gui, m)
        @test collect(Float64, position(m)) == P1
        @test GUI._label(gui, m) == "first"
        @test _in(m, ctrl.movable)
        @test isempty(gui.components.removed) && isempty(gui.components.added)
        # the move is still a change of the pose since the start of the view
        @test ctrl.init_poses[m][1] ≈ P0
        code, n = GUI._export_code(gui)
        @test n == 1 && occursin("translate_to3d!(first, ", code)
        # undo of the move
        @test _undo!(gui)
        @test collect(Float64, position(m)) ≈ P0
        @test _target(beam) === m
        @test occursin("# no changes", GUI._export_code(gui)[1])

        # redo of both: moved and removed again
        @test _redo!(gui) && _redo!(gui)
        @test sys.objects == [m2] && gui.components.removed == [m]
        @test !_redo!(gui)
        # a new action clears the redo stack
        @test _undo!(gui)
        remove_component!(gui, m2)
        @test isempty(ctrl.redo_stack)
        @test _undo!(gui)
        @test GUI._label(gui, m2) == name2 && _in(m2, sys.objects)
        close(gui)
    end

    @testset "sources, $layout" for layout in (:compact, :app)
        m = _mirror()
        sys = System([m])
        first_beam = _beam(0.2)
        gui = _live_view(sys => first_beam; layout)
        nplots = length(gui.ax.scene.plots)

        # added, with a color
        src = _beam()
        add_component!(gui, src; label = "laser")
        GUI._set_beam_color!(gui, src, :orange)
        @test _undo!(gui)
        @test !_paired(gui, src) && length(gui.ax.scene.plots) == nplots
        @test isempty(gui.components.added)
        @test _redo!(gui)
        @test _paired(gui, src) && GUI._label(gui, src) == "laser"
        @test _hex(GUI._beam_color(gui, src)) == _hex(:orange)
        @test _target(src) === m && gui.components.added == [src]

        # removed: undo traces it again; switched off, it stays off
        GUI._set_beam_on!(gui, src, false)
        remove_component!(gui, src)
        @test !_paired(gui, src)
        @test _undo!(gui)
        @test _paired(gui, src) && !GUI._beam_on(gui, src)
        @test _hex(GUI._beam_color(gui, src)) == _hex(:orange)

        # the last source of the start, removed and brought back: no change
        remove_component!(gui, src)
        remove_component!(gui, first_beam)
        @test isempty(gui.pairs)
        @test _undo!(gui)
        @test only(gui.pairs).second === first_beam && only(gui.pairs).first === sys
        @test isempty(gui.components.removed) && isempty(gui.components.added)
        @test GUI._label(gui, first_beam) == "Beam 1"
        @test _redo!(gui)
        @test isempty(gui.pairs) && gui.components.removed == [first_beam]
        close(gui)
    end

    @testset "a source of several systems" begin
        a, b = System([_mirror()]), System([_mirror(0.2)])
        beam = _beam()
        gui = _live_view(a => beam, b => beam)
        remove_component!(gui, beam)
        @test _undo!(gui)
        @test [p.first for p in gui.pairs] == [a, b] && length(gui.beam_handles) == 2
        @test isempty(gui.components.removed) && isempty(gui.components.added)
        @test occursin("# no changes", GUI._export_code(gui)[1])
        @test _redo!(gui)
        @test isempty(gui.pairs)
        close(gui)
    end

    @testset "keys and placement" begin
        sys = System()
        gui = _live_view(sys => _beam())
        scene = gui.ax.scene
        # the component of a placement that was dropped
        m = _mirror()
        GUI._start_placement!(gui, m)
        GUI._drop_placement!(gui)
        @test _in(m, sys.objects) && length(gui.controls.undo_stack) == 1
        # Ctrl+Z and Ctrl+Y
        events(scene).keyboardbutton[] = Makie.KeyEvent(Keyboard.left_control, Keyboard.press)
        events(scene).keyboardbutton[] = Makie.KeyEvent(Keyboard.z, Keyboard.press)
        @test isempty(sys.objects)
        events(scene).keyboardbutton[] = Makie.KeyEvent(Keyboard.y, Keyboard.press)
        @test _in(m, sys.objects)
        events(scene).keyboardbutton[] = Makie.KeyEvent(Keyboard.left_control, Keyboard.release)
        # Delete, then undo
        gui.controls.selected[] = m
        events(scene).keyboardbutton[] = Makie.KeyEvent(Keyboard.delete, Keyboard.press)
        @test isempty(sys.objects)
        @test _undo!(gui)
        @test _in(m, sys.objects)
        close(gui)
    end

    @testset "a clip plane keeps its own history" begin
        gui = _live_view(System([_mirror()]) => _beam())
        m = only(GUI._systems(gui)).objects[1]
        remove_component!(gui, m)
        plane = GUI._add_clip_plane!(gui, [0, 0.05, 0], [0, 1, 0])
        GUI._remove_clip_plane!(gui, plane)
        # the removal of the plane is no action, the one of the mirror still is
        @test length(gui.controls.undo_stack) == 1
        @test _undo!(gui)
        @test _in(m, only(GUI._systems(gui)).objects)
        close(gui)
    end
end

end
