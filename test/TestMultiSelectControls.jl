module TestMultiSelectControls

using GLMakie, BeamletOptics, BeamletOpticsGUI
using BeamletOptics: render_children, render_plots, rendered
using Makie
using Test
using LinearAlgebra

const BMO = BeamletOptics
const GUI = BeamletOpticsGUI

@testset "Selections of several objects in the 3D view" begin
    # Three mirrors, picked via `target`, since picking needs a screen
    function _fixture(; kwargs...)
        m1 = RoundPlanoMirror(0.025, 0.005)
        m2 = RoundPlanoMirror(0.025, 0.005)
        m3 = RoundPlanoMirror(0.025, 0.005)
        zrotate3d!(m2, deg2rad(30))
        translate3d!(m2, [0.1, 0, 0])
        translate3d!(m3, [0, 0.1, 0])
        g = ObjectGroup([m3])
        fig = Figure()
        ax = LScene(fig[1, 1])
        h = live_render!(ax, System([m1, m2, g]))
        target = Ref{Any}(m1)
        plot_of(obj) = render_plots(only(oh for oh in render_children(h) if rendered(oh) === obj))[1]
        pick = ax2 -> (isnothing(target[]) ? (nothing, 0) : (plot_of(target[]), 0))
        ctrl = GUI.kinematic_controls!(ax, h; throttle = false, pick, kwargs...)
        return (; ctrl, scene = ax.scene, target, m1, m2, m3, g)
    end
    _press!(scene) = (events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.press))
    _release!(scene) = (events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.release))
    _click!(scene) = (_press!(scene); _release!(scene))
    function _ctrl_click!(scene)
        push!(events(scene).keyboardstate, Keyboard.left_control)
        _click!(scene)
        delete!(events(scene).keyboardstate, Keyboard.left_control)
    end
    _key!(scene, k) = (events(scene).keyboardbutton[] = Makie.KeyEvent(k, Keyboard.press))
    _at(obj) = collect(Float64.(BMO.position(obj)))
    _R(obj) = Matrix{Float64}(BMO.orientation(obj))
    _objects(f) = (f.m1, f.m2, f.g)
    _distances(objs) = [norm(_at(a) - _at(b)) for a in objs for b in objs]
    # Selects m1, m2 and g, the group of m3, by clicks
    function _select3!(f)
        f.target[] = f.m1
        events(f.scene).mouseposition[] = (100.0, 100.0)
        _click!(f.scene)
        f.target[] = f.m2
        _ctrl_click!(f.scene)
        f.target[] = f.m3
        _ctrl_click!(f.scene)
        return f.ctrl.selected[]
    end

    @testset "Ctrl+click adds and removes, a click on a member selects it alone" begin
        f = _fixture()
        ctrl, scene = f.ctrl, f.scene
        events(scene).mouseposition[] = (100.0, 100.0)
        _click!(scene)
        @test ctrl.selected[] === f.m1
        f.target[] = f.m2
        _ctrl_click!(scene)
        s = ctrl.selected[]
        @test s isa GUI._MultiSelection && s.objects == Any[f.m1, f.m2]
        @test !isempty(ctrl.box_obs[]) && ctrl.gizmo_visible[]
        # the top-level object of a part of a group
        f.target[] = f.m3
        _ctrl_click!(scene)
        @test ctrl.selected[].objects == Any[f.m1, f.m2, f.g]
        # on a member: removes it, also via a part of it
        _ctrl_click!(scene)
        @test ctrl.selected[].objects == Any[f.m1, f.m2]
        f.target[] = f.m1
        _ctrl_click!(scene)
        @test ctrl.selected[] === f.m2
        f.target[] = f.m3
        _ctrl_click!(scene)
        f.target[] = f.m1
        _ctrl_click!(scene)
        @test ctrl.selected[].objects == Any[f.m2, f.g, f.m1]
        # a plain click on a member selects it alone, also by a part of it
        f.target[] = f.m3
        _click!(scene)
        @test ctrl.selected[] === f.g
        f.target[] = f.m2
        _ctrl_click!(scene)
        f.target[] = f.m2
        _click!(scene)
        @test ctrl.selected[] === f.m2
        close(ctrl)
    end

    @testset "Ctrl+click on the background keeps the selection and the camera" begin
        f = _fixture()
        ctrl, scene = f.ctrl, f.scene
        s = _select3!(f)
        @test s isa GUI._MultiSelection
        Makie.update_cam!(scene, Vec3d(0.3, -0.4, 0.5), Vec3d(0.05, 0.02, 0), Vec3d(0, 0, 1))
        cam = Makie.cameracontrols(scene)
        eye, lookat = cam.eyeposition[], cam.lookat[]
        probe = Ref(0)
        on(events(scene).mousebutton, priority = -1000) do _
            probe[] += 1
            return Consume(false)
        end
        f.target[] = nothing
        _ctrl_click!(scene)
        @test ctrl.selected[] === s
        @test probe[] == 0
        @test cam.eyeposition[] == eye && cam.lookat[] == lookat
        # a Ctrl+drag on the background does nothing either
        push!(events(scene).keyboardstate, Keyboard.left_control)
        events(scene).mouseposition[] = (100.0, 100.0)
        _press!(scene)
        events(scene).mouseposition[] = (160.0, 140.0)
        _release!(scene)
        delete!(events(scene).keyboardstate, Keyboard.left_control)
        @test ctrl.selected[] === s && probe[] == 0
        @test cam.eyeposition[] == eye && cam.lookat[] == lookat
        # a plain click on the background deselects
        _click!(scene)
        @test isnothing(ctrl.selected[])
        close(ctrl)
    end

    @testset "a drag on any member moves all, one undo entry" begin
        f = _fixture()
        ctrl, scene = f.ctrl, f.scene
        s = _select3!(f)
        objs = _objects(f)
        P0 = [_at(o) for o in objs]
        R0 = [_R(o) for o in objs]
        # the drag starts on m2, whose plot is under the cursor
        f.target[] = f.m2
        events(scene).mouseposition[] = (100.0, 100.0)
        _press!(scene)
        @test ctrl.press_kind == :pending_drag
        events(scene).mouseposition[] = (140.0, 160.0)
        @test ctrl.dragging
        events(scene).mouseposition[] = (150.0, 170.0)
        _release!(scene)
        @test ctrl.selected[] === s
        d = _at(f.m1) - P0[1]
        @test norm(d) > 1e-6
        for (o, P, R) in zip(objs, P0, R0)
            @test _at(o) - P ≈ d atol = 1e-12
            @test _R(o) == R
        end
        @test position(s) ≈ sum(P0) / 3 + d atol = 1e-12
        @test length(ctrl.undo_stack) == 1 && only(ctrl.undo_stack).obj === s
        # undo restores every pose and selects the selection again
        ctrl.selected[] = nothing
        GUI._undo!(ctrl)
        @test ctrl.selected[] === s
        for (o, P) in zip(objs, P0)
            @test norm(_at(o) - P) < 1e-9
        end
        close(ctrl)
    end

    @testset "no snapping of a selection of several" begin
        f = _fixture()
        ctrl, scene = f.ctrl, f.scene
        s = _select3!(f)
        GUI._set_snap!(ctrl, :pose)
        calls = Ref(0)
        ctrl.snap_beam = (obj, p) -> (calls[] += 1; (; point = zeros(3), direction = [1.0, 0, 0]))
        ctrl.snap_grid = (obj, p) -> (calls[] += 1; (; point = zeros(3), direction = [1.0, 0, 0]))
        R0 = _R(f.m2)
        events(scene).mouseposition[] = (100.0, 100.0)
        _press!(scene)
        events(scene).mouseposition[] = (140.0, 160.0)
        _release!(scene)
        @test calls[] == 0
        @test _R(f.m2) == R0 && norm(_at(f.m1)) > 1e-6
        close(ctrl)
    end

    @testset "keys move and rotate all about the center, one undo entry per run" begin
        f = _fixture(; fine_step = 1e-3, fine_angle = 1e-2)
        ctrl, scene = f.ctrl, f.scene
        s = _select3!(f)
        objs = _objects(f)
        P0 = [_at(o) for o in objs]
        D0 = _distances(objs)
        # world axes: ↑ along y
        _key!(scene, Keyboard.up)
        _key!(scene, Keyboard.up)
        for (o, P) in zip(objs, P0)
            @test _at(o) ≈ P + [0, 2e-3, 0] atol = 1e-12
        end
        @test length(ctrl.undo_stack) == 1
        # rotate mode: ← about the rotation axis through the center
        _key!(scene, Keyboard.m)
        c = Vector{Float64}(position(s))
        P1 = [_at(o) for o in objs]
        R1 = [_R(o) for o in objs]
        foreach(_ -> _key!(scene, Keyboard.left), 1:3)
        Rz = BMO.rotate3d([0.0, 0, 1], 3e-2)
        for (o, P, R) in zip(objs, P1, R1)
            @test _at(o) ≈ c + Rz * (P - c) atol = 1e-12
            @test _R(o) ≈ Rz * R atol = 1e-12
        end
        @test maximum(abs.(_distances(objs) - D0)) < 1e-9
        @test length(ctrl.undo_stack) == 2
        GUI._undo!(ctrl)
        GUI._undo!(ctrl)
        for (o, P) in zip(objs, P0)
            @test norm(_at(o) - P) < 1e-9
        end
        close(ctrl)
    end

    @testset "the axes stay orthogonal after a tilt of the selection" begin
        f = _fixture(; fine_angle = 0.3)
        ctrl, scene = f.ctrl, f.scene
        s = _select3!(f)
        _key!(scene, Keyboard.m)
        # ↑ about the red axis, page up about the green one: the selection is tilted
        _key!(scene, Keyboard.up)
        _key!(scene, Keyboard.page_up)
        @test abs(BMO.orientation(s)[3, 2]) > 0.1
        y, x, v = GUI._control_axes(ctrl, s)
        @test v == ctrl.rotation_axis
        @test abs(dot(y, v)) < 1e-12 && abs(dot(x, v)) < 1e-12 && abs(dot(x, y)) < 1e-12
        @test norm(y) ≈ 1 && norm(x) ≈ 1 && cross(x, y) ≈ v
        # ← about the blue axis turns the arrows with the selection
        _key!(scene, Keyboard.left)
        y2, _, _ = GUI._control_axes(ctrl, s)
        @test y2 ≈ BMO.rotate3d(v, 0.3) * y atol = 1e-12
        # the move arrows stay orthogonal, e.g. ↑ moves within the plane perpendicular to v
        _key!(scene, Keyboard.m)
        P0 = Vector{Float64}(position(s))
        _key!(scene, Keyboard.up)
        @test abs(dot(Vector{Float64}(position(s)) - P0, v)) < 1e-12
        close(ctrl)
    end

    @testset "the gizmo arrows and rings move all" begin
        function _px(scene, p)
            q = Makie.project(scene, :data, :pixel, Point3(p))
            o = scene.viewport[].origin
            return (Float64(q[1] + o[1]), Float64(q[2] + o[2]))
        end
        f = _fixture()
        ctrl, scene = f.ctrl, f.scene
        s = _select3!(f)
        objs = _objects(f)
        o = copy(ctrl.gizmo_origin)
        Makie.update_cam!(scene, Vec3d((o .+ [0.12, -0.14, 0.15])...), Vec3d(o...), Vec3d(0, 0, 1))
        # the green arrow, along y of the world
        P0 = [_at(x) for x in objs]
        a = _px(scene, ctrl.arrow_pos[][1] .+ 0.5 .* ctrl.arrow_dir[][1])
        b = _px(scene, ctrl.arrow_pos[][1] .+ 0.8 .* ctrl.arrow_dir[][1])
        events(scene).mouseposition[] = a
        @test GUI._pick_arrow(ctrl, scene) === :y
        _press!(scene)
        @test ctrl.press_kind == :pending_arrow
        events(scene).mouseposition[] = b
        _release!(scene)
        d = _at(f.m1) - P0[1]
        @test norm(d) > 1e-4 && abs(d[1]) < 1e-9 && abs(d[3]) < 1e-9
        for (x, P) in zip(objs, P0)
            @test _at(x) - P ≈ d atol = 1e-12
        end
        @test length(ctrl.undo_stack) == 1
        # the blue ring, about z through the center
        _key!(scene, Keyboard.m)
        o = copy(ctrl.gizmo_origin)
        Makie.update_cam!(scene, Vec3d((o .+ [0.12, -0.14, 0.15])...), Vec3d(o...), Vec3d(0, 0, 1))
        D0 = _distances(objs)
        c = Vector{Float64}(position(s))
        n = 2 * GUI._RING_RES
        vertex(j) = _px(scene, ctrl.ring_pts[][2n + 2j - 1])
        events(scene).mouseposition[] = vertex(4)
        @test first(GUI._pick_ring(ctrl, scene)) === :v
        _press!(scene)
        @test ctrl.press_kind == :pending_ring
        events(scene).mouseposition[] = vertex(12)
        _release!(scene)
        @test ctrl.selected[] === s
        @test abs(_at(f.m1)[3] - P0[1][3]) < 1e-9
        @test norm(_at(f.m1) - (P0[1] + d)) > 1e-4
        @test maximum(abs.(_distances(objs) - D0)) < 1e-9
        @test norm(Vector{Float64}(position(s)) - c) < 1e-12
        @test length(ctrl.undo_stack) == 2
        close(ctrl)
    end

    @testset "Backspace resets all, undo and redo" begin
        f = _fixture(; fine_step = 1e-3)
        ctrl, scene = f.ctrl, f.scene
        objs = _objects(f)
        init = [(_at(o), _R(o)) for o in objs]
        s = _select3!(f)
        _key!(scene, Keyboard.up)
        _key!(scene, Keyboard.m)
        _key!(scene, Keyboard.left)
        moved = [(_at(o), _R(o)) for o in objs]
        n = length(ctrl.undo_stack)
        _key!(scene, Keyboard.backspace)
        @test length(ctrl.undo_stack) == n + 1
        for (o, (P, R)) in zip(objs, init)
            @test norm(_at(o) - P) < 1e-9 && norm(_R(o) - R) < 1e-9
        end
        @test position(s) ≈ sum(first.(init)) / 3 atol = 1e-12
        ctrl.selected[] = nothing
        GUI._undo!(ctrl)
        @test ctrl.selected[] === s
        for (o, (P, R)) in zip(objs, moved)
            @test norm(_at(o) - P) < 1e-9 && norm(_R(o) - R) < 1e-9
        end
        @test GUI._redo!(ctrl)
        for (o, (P, R)) in zip(objs, init)
            @test norm(_at(o) - P) < 1e-9
        end
        # the gestures before it are undone in order
        @test GUI._undo!(ctrl) && GUI._undo!(ctrl) && GUI._undo!(ctrl)
        for (o, (P, R)) in zip(objs, init)
            @test norm(_at(o) - P) < 1e-9 && norm(_R(o) - R) < 1e-9
        end
        # a selection at its initial poses: nothing to reset, no entry
        n = length(ctrl.undo_stack)
        ctrl.selected[] = s
        _key!(scene, Keyboard.backspace)
        @test length(ctrl.undo_stack) == n
        close(ctrl)
    end

    @testset "Escape deselects, the spectator mode restores it" begin
        f = _fixture()
        ctrl, scene = f.ctrl, f.scene
        s = _select3!(f)
        _key!(scene, Keyboard.escape)
        @test isnothing(ctrl.selected[])
        ctrl.selected[] = s
        _key!(scene, Keyboard.v)
        @test ctrl.spectator[] && isnothing(ctrl.selected[])
        _key!(scene, Keyboard.v)
        @test !ctrl.spectator[] && ctrl.selected[] === s
        close(ctrl)
    end

    @testset "the history drops the selections of dropped objects" begin
        f = _fixture(; fine_step = 1e-3)
        ctrl, scene = f.ctrl, f.scene
        s = _select3!(f)
        _key!(scene, Keyboard.up)
        _key!(scene, Keyboard.backspace)
        @test length(ctrl.undo_stack) == 2
        GUI._drop_history!(ctrl, [f.m2])
        @test isempty(ctrl.undo_stack) && isnothing(ctrl.last_key_step)
        close(ctrl)
    end

    @testset "with a select_modifier, Ctrl is held as well" begin
        f = _fixture(; select_modifier = Keyboard.left_shift)
        ctrl, scene = f.ctrl, f.scene
        events(scene).mouseposition[] = (100.0, 100.0)
        push!(events(scene).keyboardstate, Keyboard.left_shift)
        _click!(scene)
        @test ctrl.selected[] === f.m1
        # Shift+click selects as before
        f.target[] = f.m2
        _click!(scene)
        @test ctrl.selected[] === f.m2
        f.target[] = f.m1
        _ctrl_click!(scene)
        @test ctrl.selected[].objects == Any[f.m2, f.m1]
        delete!(events(scene).keyboardstate, Keyboard.left_shift)
        # without the modifier, Ctrl+click goes to the camera
        f.target[] = f.m3
        _ctrl_click!(scene)
        @test ctrl.selected[].objects == Any[f.m2, f.m1]
        close(ctrl)
    end

    @testset "help" begin
        sections = GUI._help_sections(:move, 10e-9, 10e-6)
        e = sections[1].second[2]
        @test e.keys == [GUI._ctrl_cap(), :mouse => "click"] && e.combo
        @test e.text == "add to or remove from the selection"
        e = GUI._help_sections(:move, 10e-9, 10e-6, Keyboard.left_shift)[1].second[2]
        @test e.keys == ["left_shift", GUI._ctrl_cap(), :mouse => "click"]
    end

    @testset "live_view: Ctrl+click and the spectator mode" begin
        m1 = RoundPlanoMirror(25e-3, 5e-3)
        zrotate3d!(m1, deg2rad(45))
        translate3d!(m1, [0, 0.1, 0])
        m2 = RoundPlanoMirror(25e-3, 5e-3)
        translate3d!(m2, [0.1, 0.1, 0])
        pd = Detector(5e-3)
        translate3d!(pd, [0.1, 0.2, 0])
        cs = CollimatedSource([0.0, 0, 0], [0.0, 1, 0], 2e-3, 1e-6; num_rings = 2, num_rays = 40)
        target = Ref{Any}(m1)
        gui = live_view(System([m1, m2, pd]) => cs; trace_budget = Inf, throttle = false,
            catalog = CatalogEntry[], pick = ax -> (GUI._object_plots(gui.controls.h, target[])[1], 0))
        scene = gui.ax.scene
        events(scene).mouseposition[] = (100.0, 100.0)
        _click!(scene)
        @test gui.controls.selected[] === m1
        target[] = m2
        _ctrl_click!(scene)
        s = gui.controls.selected[]
        @test s isa GUI._MultiSelection && s.objects == Any[m1, m2]
        spectator!(gui)
        @test isnothing(gui.controls.selected[])
        spectator!(gui, false)
        @test gui.controls.selected[] === s
        _key!(scene, Keyboard.escape)
        @test isnothing(gui.controls.selected[])
        close(gui)
    end
end

end
