module TestLiveAim

using GLMakie, BeamletOptics, BeamletOpticsGUI
using Makie
using LinearAlgebra: norm, dot, normalize
using Test

const BMO = BeamletOptics
const GUI = BeamletOpticsGUI

@testset "Aiming sources" begin
    # A beam along +y beside a mirror at [0.1, 0.2, 0.02] and a second source; the mouse moves the
    # objects in the plane z = const
    function _fixture(; kwargs...)
        m = RoundPlanoMirror(25e-3, 5e-3)
        translate3d!(m, [0.1, 0.2, 0.02])
        sys = System([m])
        a = Beam([0.0, 0, 0], [0.0, 1, 0], 1e-6)
        b = CollimatedSource([-0.1, 0.0, 0.0], [0.0, 1, 0], 5e-3, 532e-9; num_rings = 2)
        gui = live_view(sys => a, sys => b; trace_budget = Inf, throttle = false,
            plane_normal = [0, 0, 1], kwargs...)
        set_view(gui.ax, [0.25, -0.2, 0.5], [0.0, 0.15, 0.0], [0.0, 0, 1])
        return gui, sys, m, a, b
    end
    _dir(src) = normalize(collect(Float64, BMO.direction(src)))
    _pos(obj) = collect(Float64, position(obj))
    function _pixel(gui, point)
        scene = gui.ax.scene
        p = Makie.project(scene, :data, :pixel, Point3f(point))[Vec(1, 2)]
        return Point2f(Makie.viewport(scene)[].origin) .+ p
    end
    _mouse!(gui, px) = (events(gui.ax.scene).mouseposition[] = (Float64(px[1]), Float64(px[2])))
    _press!(gui) = (events(gui.ax.scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.press))
    _release!(gui) = (events(gui.ax.scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.release))
    _click!(gui) = (_press!(gui); _release!(gui))
    _key!(gui, key) = (events(gui.ax.scene).keyboardbutton[] = Makie.KeyEvent(key, Keyboard.press))
    _in_scene(gui, plot) = any(q -> q === plot, gui.ax.scene.plots)
    # The center of the plots of the mirror, which a source is aimed at
    _center(gui, obj) = GUI._aim_point(gui.controls, obj)

    @testset "at a point" begin
        gui, sys, m, a, b = _fixture()
        ctrl = gui.controls
        n = length(ctrl.undo_stack)
        @test GUI._aim!(gui, a, [0.1, 0.1, 0.0])
        @test _dir(a) ≈ normalize([1.0, 1, 0]) atol = 1e-9
        # about its position
        @test _pos(a) == [0.0, 0, 0]
        # one gesture of the undo history, also for a source that is not selected
        @test isnothing(ctrl.selected[]) && length(ctrl.undo_stack) == n + 1
        GUI._undo!(ctrl)
        @test _dir(a) ≈ [0.0, 1, 0] atol = 1e-9
        GUI._redo!(ctrl)
        @test _dir(a) ≈ normalize([1.0, 1, 0]) atol = 1e-9
        # out of the plane, and backwards: a half turn about the rotation axis
        @test GUI._aim!(gui, a, [0.0, 0.3, 0.3])
        @test _dir(a) ≈ normalize([0.0, 1, 1]) atol = 1e-9
        GUI._aim!(gui, a, [0.0, 1.0, 0.0])
        @test GUI._aim!(gui, a, [0.0, -2.0, 0.0])
        @test _dir(a) ≈ [0.0, -1, 0] atol = 1e-9
        # a beam group as a whole
        @test GUI._aim!(gui, b, [0.1, 0.2, 0.02])
        @test _dir(b) ≈ normalize([0.2, 0.2, 0.02]) atol = 1e-9
        @test _pos(b) ≈ [-0.1, 0, 0] atol = 1e-12
        # traced again: it hits the mirror at [0.1, 0.2, 0.02] now
        @test !isempty(GUI._hits(gui, m))
        # at its own position: nothing
        n = length(ctrl.undo_stack)
        @test !GUI._aim!(gui, a, [0.0, 0, 0])
        @test occursin("can not be aimed at it", gui.status.text[]) && length(ctrl.undo_stack) == n
        close(gui)

        # a source whose rotation is constrained
        gui, sys, m, a, b = _fixture(; constraints = Dict())
        close(gui)
        m = RoundPlanoMirror(25e-3, 5e-3)
        a = Beam([0.0, 0, 0], [0.0, 1, 0], 1e-6)
        gui = live_view(System([m]) => a; trace_budget = Inf, constraints = Dict(a => (; rotate = ())))
        @test !GUI._aim!(gui, a, [0.1, 0.1, 0.0])
        @test occursin("can not rotate freely", gui.status.text[]) && _dir(a) == [0.0, 1, 0]
        close(gui)
        # ... or that is not movable
        gui = live_view(System([m]) => a; trace_budget = Inf, movable_sources = false)
        @test !GUI._aim!(gui, a, [0.1, 0.1, 0.0])
        @test occursin("not movable", gui.status.text[])
        GUI._start_aim!(gui, a)
        @test !GUI._aiming(gui) && occursin("not movable", gui.status.text[])
        close(gui)
    end

    @testset "with the mouse ($layout)" for layout in (:compact, :app)
        gui, sys, m, a, b = _fixture(; layout)
        ctrl = gui.controls
        scene = gui.ax.scene
        ignore_mouse = ctrl.ignore_mouse
        n_plots = length(scene.plots)
        aim = only(c for c in last(GUI._card_rows(a)).cells if c.name === :aim)
        @test aim.value(gui, a) == "aim"

        _mouse!(gui, _pixel(gui, [0.05, 0.05, 0.0]))
        aim.on(gui, a, nothing)
        s = gui.components.aim
        @test GUI._aiming(gui) && GUI._aiming(gui, a) && !GUI._aiming(gui, b)
        @test s.src === a && _in_scene(gui, s.plot) && length(scene.plots) == n_plots + 1
        @test aim.value(gui, a) == "cancel" && aim.value(gui, b) == "aim"
        @test occursin("aiming", gui.status.text[]) && occursin("Esc", gui.status.text[])
        # the controls ignore the mouse; the source did not turn yet
        @test ctrl.ignore_mouse() && _dir(a) == [0.0, 1, 0]
        # the line from the source to the point of its plane under the mouse
        @test s.line[][1] ≈ Point3f(0)
        @test s.line[][2] ≈ Point3f(0.05, 0.05, 0.0) atol = 1e-4
        _mouse!(gui, _pixel(gui, [-0.03, 0.12, 0.0]))
        @test s.line[][2] ≈ Point3f(-0.03, 0.12, 0.0) atol = 1e-4
        # over a component: its center
        _mouse!(gui, _pixel(gui, _pos(m)))
        target = GUI._aim_target(gui, s)
        @test target.obj === m && target.point ≈ _center(gui, m)
        @test s.line[][2] ≈ Point3f(_center(gui, m))
        # a drag is left to the camera
        _press!(gui)
        _mouse!(gui, _pixel(gui, _pos(m)) .+ Point2f(40, 0))
        _release!(gui)
        @test GUI._aiming(gui) && _dir(a) == [0.0, 1, 0]
        # a click aims at it
        _mouse!(gui, _pixel(gui, _pos(m)))
        n = length(ctrl.undo_stack)
        _click!(gui)
        @test !GUI._aiming(gui) && isnothing(gui.components.aim)
        @test _dir(a) ≈ normalize(_center(gui, m)) atol = 1e-9
        @test !_in_scene(gui, s.plot) && length(scene.plots) == n_plots
        @test ctrl.ignore_mouse === ignore_mouse
        @test occursin("aimed at", gui.status.text[]) && occursin(GUI._label(gui, m), gui.status.text[])
        @test length(ctrl.undo_stack) == n + 1 && aim.value(gui, a) == "aim"
        @test !isempty(GUI._hits(gui, m))
        GUI._undo!(ctrl)
        @test _dir(a) ≈ [0.0, 1, 0] atol = 1e-9

        # a click beside the components: the point of the plane through the source
        GUI._start_aim!(gui, a)
        _mouse!(gui, _pixel(gui, [-0.03, 0.12, 0.0]))
        _click!(gui)
        @test !GUI._aiming(gui)
        @test _dir(a) ≈ normalize([-0.03, 0.12, 0.0]) atol = 1e-4
        @test abs(_dir(a)[3]) < 1e-9
        @test occursin("aimed at (", gui.status.text[])

        # at another source: its position
        GUI._start_aim!(gui, a)
        _mouse!(gui, _pixel(gui, _pos(b)))
        @test GUI._aim_target(gui, gui.components.aim).obj === b
        _click!(gui)
        @test _dir(a) ≈ [-1.0, 0, 0] atol = 1e-9
        close(gui)
    end

    @testset "in the plane of the table" begin
        # without a `plane_normal`, in an oblique view: the beam stays in the plane of the table
        m = RoundPlanoMirror(25e-3, 5e-3)
        translate3d!(m, [0.1, 0.2, 0.0])
        a = Beam([0.0, 0, 0], [0.0, 1, 0], 1e-6)
        gui = live_view(System([m]) => a; trace_budget = Inf, throttle = false)
        set_view(gui.ax, [0.25, -0.2, 0.5], [0.0, 0.15, 0.0], [0.0, 0, 1])
        GUI._start_aim!(gui, a)
        _mouse!(gui, _pixel(gui, [-0.08, 0.12, 0.0]))
        target = GUI._aim_target(gui, gui.components.aim)
        @test isnothing(target.obj)
        @test abs(target.point[3]) < 1e-9
        @test norm(target.point .- [-0.08, 0.12, 0.0]) < 2e-3
        _click!(gui)
        @test !GUI._aiming(gui)
        @test abs(_dir(a)[3]) < 1e-9 && _dir(a)[1] < 0
        close(gui)
    end

    @testset "cancelled" begin
        gui, sys, m, a, b = _fixture()
        ctrl = gui.controls
        ignore_mouse = ctrl.ignore_mouse
        n_plots = length(gui.ax.scene.plots)
        # Esc
        GUI._start_aim!(gui, a)
        _key!(gui, Keyboard.escape)
        @test !GUI._aiming(gui) && gui.status.text[] == "aiming cancelled"
        @test ctrl.ignore_mouse === ignore_mouse && length(gui.ax.scene.plots) == n_plots
        # "aim" again
        GUI._toggle_aim!(gui, a)
        @test GUI._aiming(gui, a)
        GUI._toggle_aim!(gui, a)
        @test !GUI._aiming(gui)
        # another source takes over
        GUI._start_aim!(gui, a)
        GUI._start_aim!(gui, b)
        @test GUI._aiming(gui, b) && length(gui.ax.scene.plots) == n_plots + 1
        @test gui.components.aim.ignore_mouse === ignore_mouse
        # placing a component
        GUI._start_placement!(gui, SphericalLens(0.05, -0.05, 0.01, 0.02))
        @test !GUI._aiming(gui) && GUI._placing(gui)
        # ... and aiming cancels the placement
        GUI._start_aim!(gui, a)
        @test GUI._aiming(gui, a) && !GUI._placing(gui)
        @test gui.components.aim.ignore_mouse === ignore_mouse
        # the spectator mode
        GUI._set_spectator!(ctrl, true)
        @test !GUI._aiming(gui) && ctrl.ignore_mouse === ignore_mouse
        GUI._start_aim!(gui, a)
        @test !GUI._aiming(gui) && occursin("spectator", gui.status.text[])
        GUI._set_spectator!(ctrl, false)
        # the source is removed meanwhile
        GUI._start_aim!(gui, a)
        remove_component!(gui, a)
        _mouse!(gui, _pixel(gui, [0.05, 0.05, 0.0]))
        @test !GUI._aiming(gui) && length(gui.ax.scene.plots) < n_plots + 1
        # only sources are aimed
        GUI._start_aim!(gui, m)
        @test !GUI._aiming(gui) && occursin("no source", gui.status.text[])
        close(gui)
    end

    @testset "onto the holes of the table" begin
        gui, sys, m, a, b = _fixture(; table = true, snap = true)
        GUI._start_aim!(gui, a)
        _mouse!(gui, _pixel(gui, [0.031, 0.108, 0.0]))
        target = GUI._aim_target(gui, gui.components.aim)
        @test isnothing(target.obj)
        @test target.point ≈ [0.025, 0.1, 0.0] atol = 1e-9
        _click!(gui)
        @test _dir(a) ≈ normalize([0.025, 0.1, 0.0]) atol = 1e-9
        close(gui)
    end
end

end
