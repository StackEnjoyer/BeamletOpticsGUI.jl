module TestRectSelect

using GLMakie, BeamletOptics, BeamletOpticsGUI
using BeamletOpticsGUI: AbstractTrees
using BeamletOptics: render_plots, rendered
using Makie
using Test
using LinearAlgebra

const BMO = BeamletOptics
const GUI = BeamletOpticsGUI

@testset "Selection rectangle in the 3D view" begin
    # Four mirrors in a square, seen from above; m3 in a group, picked via `target`, since picking
    # needs a screen
    function _fixture(; kwargs...)
        m1 = RoundPlanoMirror(0.01, 0.005)
        m2 = RoundPlanoMirror(0.01, 0.005)
        m3 = RoundPlanoMirror(0.01, 0.005)
        m4 = RoundPlanoMirror(0.01, 0.005)
        translate3d!(m2, [0.1, 0, 0])
        translate3d!(m3, [0, 0.1, 0])
        translate3d!(m4, [0.1, 0.1, 0])
        g = ObjectGroup([m3])
        fig = Figure()
        ax = LScene(fig[1, 1])
        h = live_render!(ax, System([m1, m2, g, m4]))
        target = Ref{Any}(nothing)
        plot_of(obj) = render_plots(only(oh for oh in AbstractTrees.children(h) if rendered(oh) === obj))[1]
        pick = ax2 -> (isnothing(target[]) ? (nothing, 0) : (plot_of(target[]), 0))
        ctrl = GUI.kinematic_controls!(ax, h; throttle = false, pick, kwargs...)
        scene = ax.scene
        Makie.update_cam!(scene, Vec3d(0.05, 0.05, 0.6), Vec3d(0.05, 0.05, 0), Vec3d(0, 1, 0))
        return (; ctrl, scene, target, m1, m2, m3, m4, g)
    end
    _press!(scene) = (events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.press))
    _release!(scene) = (events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.release))
    _ctrl_down!(scene) = push!(events(scene).keyboardstate, Keyboard.left_control)
    _ctrl_up!(scene) = delete!(events(scene).keyboardstate, Keyboard.left_control)
    # window pixels of a pixel of the scene (see `GUI._px`)
    _win(scene, p) = (Float64(p[1] + scene.viewport[].origin[1]), Float64(p[2] + scene.viewport[].origin[2]))
    _center(f, obj) = GUI._center_px(f.ctrl, f.scene, obj)
    # the window pixels of a rectangle around the centers of the `objs`, `pad` pixels beyond them
    function _around(f, objs; pad = 10)
        ps = [_center(f, o) for o in objs]
        lo = (minimum(first.(ps)) - pad, minimum(last.(ps)) - pad)
        hi = (maximum(first.(ps)) + pad, maximum(last.(ps)) + pad)
        return _win(f.scene, lo), _win(f.scene, hi)
    end
    # Ctrl+drag from `a` to `b` via the middle, returns whether the rectangle was shown on the way
    function _ctrl_drag!(scene, ctrl, a, b)
        _ctrl_down!(scene)
        events(scene).mouseposition[] = a
        _press!(scene)
        events(scene).mouseposition[] = ((a[1] + b[1]) / 2, (a[2] + b[2]) / 2)
        events(scene).mouseposition[] = b
        shown = ctrl.rect_visible[]
        _release!(scene)
        _ctrl_up!(scene)
        return shown
    end

    @testset "the centers of the objects lie apart on the screen" begin
        f = _fixture()
        ps = [_center(f, o) for o in (f.m1, f.m2, f.g, f.m4)]
        @test all(!isnothing, ps)
        @test minimum(norm(collect(a) .- collect(b)) for a in ps for b in ps if a !== b) > 50
        close(f.ctrl)
    end

    @testset "a rectangle selects, a second one adds, the camera stays" begin
        f = _fixture()
        ctrl, scene = f.ctrl, f.scene
        cam = Makie.cameracontrols(scene)
        eye, lookat = cam.eyeposition[], cam.lookat[]
        probe = Ref(0)
        on(events(scene).mousebutton, priority = -1000) do _
            probe[] += 1
            return Consume(false)
        end
        a, b = _around(f, (f.m1, f.m2))
        # the drag shows the rectangle in the pixels of the axis, between the press and the cursor
        _ctrl_down!(scene)
        events(scene).mouseposition[] = a
        _press!(scene)
        @test ctrl.press_kind == :background && !ctrl.rect_visible[]
        events(scene).mouseposition[] = b
        @test ctrl.press_kind == :rect && ctrl.rect_visible[]
        r = ctrl.rect[]
        o = minimum(ctrl.ax.scene.viewport[]) .- minimum(ctrl.ax.blockscene.viewport[])
        @test minimum(r) ≈ Point2f(min.(a, b) .- scene.viewport[].origin .+ o) atol = 1e-3
        @test maximum(r) ≈ Point2f(max.(a, b) .- scene.viewport[].origin .+ o) atol = 1e-3
        @test ctrl.rect_visible[] && any(p -> p isa Makie.Poly && p.visible[], ctrl.plots)
        _release!(scene)
        _ctrl_up!(scene)
        @test !ctrl.rect_visible[]
        s = ctrl.selected[]
        @test s isa GUI._MultiSelection && Set(s.objects) == Set(Any[f.m1, f.m2])
        @test !isempty(ctrl.box_obs[])
        @test probe[] == 0
        @test cam.eyeposition[] == eye && cam.lookat[] == lookat
        # a second rectangle, from an object that is not selected, adds the group as a whole
        f.target[] = f.m3
        a, b = _around(f, (f.g,))
        @test _ctrl_drag!(scene, ctrl, a, b)
        f.target[] = nothing
        s = ctrl.selected[]
        @test s isa GUI._MultiSelection && length(s.objects) == 3
        @test Set(s.objects) == Set(Any[f.m1, f.m2, f.g]) && !(f.m3 in s.objects)
        @test !ctrl.rect_visible[]
        @test probe[] == 0
        @test cam.eyeposition[] == eye && cam.lookat[] == lookat
        # a rectangle with nothing inside changes nothing
        p = _center(f, f.m1)
        q = _center(f, f.m2)
        mid = _win(scene, ((p[1] + q[1]) / 2, (p[2] + q[2]) / 2))
        @test _ctrl_drag!(scene, ctrl, mid .- 5, mid .+ 5)
        @test ctrl.selected[] === s
        # nor does one around the selected objects only
        a, b = _around(f, (f.m1, f.m2))
        _ctrl_drag!(scene, ctrl, a, b)
        @test ctrl.selected[] === s
        close(ctrl)
    end

    @testset "hidden objects and objects outside are not selected" begin
        f = _fixture()
        ctrl, scene = f.ctrl, f.scene
        foreach(p -> p.visible[] = false, GUI._object_plots(ctrl.h, f.m2))
        # m2 hidden, m3 and m4 outside: m1 alone
        a, b = _around(f, (f.m1, f.m2))
        _ctrl_drag!(scene, ctrl, a, b)
        @test ctrl.selected[] === f.m1
        a, b = _around(f, (f.m4,))
        _ctrl_drag!(scene, ctrl, a, b)
        s = ctrl.selected[]
        @test s isa GUI._MultiSelection && Set(s.objects) == Set(Any[f.m1, f.m4])
        close(ctrl)
    end

    @testset "a group replaces its selected part" begin
        f = _fixture()
        ctrl, scene = f.ctrl, f.scene
        # two clicks on m3: the group, then m3
        f.target[] = f.m3
        events(scene).mouseposition[] = (100.0, 100.0)
        _press!(scene); _release!(scene)
        _press!(scene); _release!(scene)
        @test ctrl.selected[] === f.m3
        f.target[] = nothing
        a, b = _around(f, (f.g, f.m4))
        _ctrl_drag!(scene, ctrl, a, b)
        s = ctrl.selected[]
        @test s isa GUI._MultiSelection && Set(s.objects) == Set(Any[f.g, f.m4])
        close(ctrl)
    end

    @testset "a short Ctrl+click toggles, a Ctrl+drag on the selection moves it" begin
        f = _fixture()
        ctrl, scene = f.ctrl, f.scene
        f.target[] = f.m1
        events(scene).mouseposition[] = (100.0, 100.0)
        _press!(scene); _release!(scene)
        @test ctrl.selected[] === f.m1
        # a move below the threshold is a click
        f.target[] = f.m2
        _ctrl_down!(scene)
        _press!(scene)
        events(scene).mouseposition[] = (101.0, 100.0)
        @test !ctrl.rect_visible[] && ctrl.press_kind == :pending_select
        _release!(scene)
        _ctrl_up!(scene)
        s = ctrl.selected[]
        @test s isa GUI._MultiSelection && s.objects == Any[f.m1, f.m2]
        # a Ctrl+drag on an object of the selection drags the selection
        P0 = Vector{Float64}(BMO.position(f.m1))
        _ctrl_down!(scene)
        _press!(scene)
        @test ctrl.press_kind == :pending_drag
        events(scene).mouseposition[] = (140.0, 130.0)
        @test ctrl.dragging && !ctrl.rect_visible[]
        _release!(scene)
        _ctrl_up!(scene)
        @test ctrl.selected[] === s && norm(Vector{Float64}(BMO.position(f.m1)) - P0) > 1e-6
        close(ctrl)
    end

    @testset "the spectator mode ends the rectangle" begin
        f = _fixture()
        ctrl, scene = f.ctrl, f.scene
        a, b = _around(f, (f.m1, f.m2))
        _ctrl_down!(scene)
        events(scene).mouseposition[] = a
        _press!(scene)
        events(scene).mouseposition[] = b
        @test ctrl.rect_visible[]
        events(scene).keyboardbutton[] = Makie.KeyEvent(Keyboard.v, Keyboard.press)
        @test ctrl.spectator[] && !ctrl.rect_visible[] && ctrl.press_kind == :none
        _release!(scene)
        _ctrl_up!(scene)
        @test isnothing(ctrl.selected[])
        events(scene).keyboardbutton[] = Makie.KeyEvent(Keyboard.v, Keyboard.press)
        @test !ctrl.spectator[] && isnothing(ctrl.selected[])
        # spectator mode: a Ctrl+drag draws no rectangle
        events(scene).keyboardbutton[] = Makie.KeyEvent(Keyboard.v, Keyboard.press)
        @test !_ctrl_drag!(scene, ctrl, a, b)
        @test isnothing(ctrl.selected[])
        close(ctrl)
    end

    @testset "help" begin
        sections = GUI._help_sections(:move, 10e-9, 10e-6)
        e = sections[1].second[3]
        @test e.keys == [GUI._ctrl_cap(), :mouse => "drag"] && e.combo
        @test e.text == "add the objects in a rectangle"
        e = GUI._help_sections(:move, 10e-9, 10e-6, Keyboard.left_shift)[1].second[3]
        @test e.keys == ["left_shift", GUI._ctrl_cap(), :mouse => "drag"]
        f = _fixture()
        @test any(e -> e.text == "add the objects in a rectangle", GUI._help_sections(f.ctrl)[1].second)
        @test occursin("add the objects in a rectangle", GUI._help_text(GUI._help_sections(f.ctrl)))
        close(f.ctrl)
        spectator = GUI._help_sections(:move, 10e-9, 10e-6; spectator = true)
        @test !any(e -> e.text == "add the objects in a rectangle", spectator[1].second)
    end

    @testset "live_view: the card shows the objects of the rectangle" begin
        m1 = RoundPlanoMirror(10e-3, 5e-3)
        m2 = RoundPlanoMirror(10e-3, 5e-3)
        translate3d!(m2, [0.1, 0, 0])
        m3 = RoundPlanoMirror(10e-3, 5e-3)
        translate3d!(m3, [0.1, 0.1, 0])
        gui = live_view(System([m1, m2, m3]); throttle = false, layout = :compact,
            catalog = CatalogEntry[], pick = ax -> (nothing, 0))
        ctrl = gui.controls
        scene = gui.ax.scene
        Makie.update_cam!(scene, Vec3d(0.05, 0.05, 0.6), Vec3d(0.05, 0.05, 0), Vec3d(0, 1, 0))
        f = (; ctrl, scene)
        a, b = _around(f, (m1, m2))
        @test _ctrl_drag!(scene, ctrl, a, b)
        s = ctrl.selected[]
        @test s isa GUI._MultiSelection && Set(s.objects) == Set(Any[m1, m2])
        @test gui.cards.selection.title.text[] == "2 objects"
        a, b = _around(f, (m3,))
        _ctrl_drag!(scene, ctrl, a, b)
        @test ctrl.selected[] isa GUI._MultiSelection && length(ctrl.selected[].objects) == 3
        @test gui.cards.selection.title.text[] == "3 objects"
        close(gui)
    end
end

end
