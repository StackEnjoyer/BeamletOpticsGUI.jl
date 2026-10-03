module TestLiveInteraction

using GLMakie, BeamletOptics, BeamletOpticsGUI
using BeamletOptics: render_children, render_plots, rendered
using Makie
using GeometryBasics
using Test
using LinearAlgebra

const BMO = BeamletOptics
const GUI = BeamletOpticsGUI

# Object that can not be moved, see `kinematic_trait_of`
struct FixedMirror{T, S <: BMO.AbstractShape{T}} <: BMO.AbstractObject{T}
    shape::S
end
BMO.kinematic_trait_of(::FixedMirror) = BMO.Static()

@testset "Kinematic controls" begin

    @testset "_ray_plane_intersect" begin
        # Straight down the -z axis onto the z=0 plane
        p = GUI._ray_plane_intersect([0.0, 0, 5], [0.0, 0, -1], [0.0, 0, 0], [0.0, 0, 1])
        @test p ≈ [0.0, 0, 0]

        # Off-axis ray/plane
        p = GUI._ray_plane_intersect([1.0, 2, 5], [0.0, 0, -1], [0.0, 0, 0], [0.0, 0, 1])
        @test p ≈ [1.0, 2, 0]

        # Parallel to the plane: no intersection
        @test isnothing(GUI._ray_plane_intersect([0.0, 0, 5], [1.0, 0, 0], [0.0, 0, 0], [0.0, 0, 1]))

        # Intersection behind the ray origin
        @test isnothing(GUI._ray_plane_intersect([0.0, 0, -5], [0.0, 0, -1], [0.0, 0, 0], [0.0, 0, 1]))
    end

    @testset "_axis_angle_from_rotmatrix round-trips through rotate3d" begin
        cases = [
            ([0.0, 0, 1], deg2rad(30)),
            ([1.0, 0, 0], deg2rad(90)),
            (normalize([1.0, 2, 3]), deg2rad(179)), # near pi
            ([0.0, 1, 0], 1e-9),                     # near 0
            (normalize([1.0, 1, 1]), deg2rad(120)),
        ]
        for (axis, θ) in cases
            R = BMO.rotate3d(axis, θ)
            got_axis, got_angle = GUI._axis_angle_from_rotmatrix(R)
            R2 = BMO.rotate3d(got_axis, got_angle)
            @test isapprox(R2, R; atol = 1e-6)
        end
    end

    @testset "reset restores the original pose" begin
        mir = RoundPlanoMirror(0.025, 0.005)
        P0, R0 = BMO.position(mir), Matrix{Float64}(BMO.orientation(mir))

        translate3d!(mir, [0.03, -0.01, 0.02])
        zrotate3d!(mir, deg2rad(37))
        xrotate3d!(mir, deg2rad(-12))

        R = Matrix{Float64}(BMO.orientation(mir))
        Rd = R0 * R'
        axis, angle = GUI._axis_angle_from_rotmatrix(Rd)
        angle > 1e-12 && rotate3d!(mir, axis, angle)
        translate_to3d!(mir, P0)

        @test isapprox(collect(BMO.position(mir)), collect(P0); atol = 1e-9)
        @test isapprox(Matrix{Float64}(BMO.orientation(mir)), R0; atol = 1e-6)
    end

    @testset "_bbox_wireframe" begin
        bb = GeometryBasics.Rect3d(GeometryBasics.Point3d(0, 0, 0), GeometryBasics.Vec3d(1, 2, 3))
        pts = GUI._bbox_wireframe(bb)
        @test length(pts) == 24 # 12 segments
        xs = [p[1] for p in pts]
        @test isapprox(minimum(xs), 0.0; atol = 1e-6)
        @test isapprox(maximum(xs), 1.0; atol = 1e-6)
    end

    @testset "_ray_pick pure helper" begin
        origin = [0.0, -1.0, 0.0]
        dir = [0.0, 1.0, 0.0]

        @testset "occluder in front is skipped, mirror behind is picked" begin
            cube = BMO.CubeMesh(1)
            translate3d!(cube, -[0.5, 0.5, 0.5])
            translate3d!(cube, [0.0, -0.5, 0.0]) # in front of the mirror, on the ray
            occluder = NonInteractableObject(cube) # not part of any system
            mir = RoundPlanoMirror(0.025, 0.005) # at the origin, behind the occluder
            @test GUI._ray_pick([occluder, mir], origin, dir)[1] === mir
        end

        @testset "nearest of two movables on the ray is picked" begin
            near = RoundPlanoMirror(0.025, 0.005)
            far = RoundPlanoMirror(0.025, 0.005)
            translate3d!(far, [0.0, 2.0, 0.0])
            @test GUI._ray_pick([far, near], origin, dir)[1] === near
            @test GUI._ray_pick([near, far], origin, dir)[1] === near
        end

        @testset "ray misses all movables" begin
            m1 = RoundPlanoMirror(0.025, 0.005)
            m2 = RoundPlanoMirror(0.025, 0.005)
            translate3d!(m2, [0.0, 2.0, 0.0])
            @test isnothing(GUI._ray_pick([m1, m2], [0.1, -1.0, 0.0], dir)[1])
        end

        @testset "objects whose intersect3d errors are skipped, not rethrown" begin
            struct _BrokenRayPickObject <: BMO.AbstractObject{Float64} end
            mir = RoundPlanoMirror(0.025, 0.005)
            @test GUI._ray_pick([_BrokenRayPickObject(), mir], origin, dir)[1] === mir
        end
    end

    # Event handling, picking requires a screen and is replaced
    function _fixture()
        m1 = RoundPlanoMirror(0.025, 0.005)
        m2 = RoundPlanoMirror(0.025, 0.005)
        translate3d!(m2, [0.2, 0, 0])
        sys = System([m1, m2])
        fig = Figure()
        ax = LScene(fig[1, 1])
        h = live_render!(ax, sys)
        return fig, ax, h, m1, m2
    end

    @testset "default pick (nothing) selects via ray casting" begin
        fig, ax, h, m1, m2 = _fixture()
        scene = ax.scene
        # Default camera looks at [0,0,0] (m1's position) from the center of the viewport
        vp = scene.viewport[]
        cx, cy = vp.origin[1] + vp.widths[1] / 2, vp.origin[2] + vp.widths[2] / 2
        ctrl = GUI.kinematic_controls!(ax, h; throttle = false) # no pick kwarg: ray picking
        events(scene).mouseposition[] = (cx, cy)
        events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.press)
        events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.release)
        @test ctrl.selected[] === m1
        close(ctrl)
    end

    @testset "ray miss falls back to Makie.pick" begin
        fig, ax, h, m1, m2 = _fixture()
        scene = ax.scene
        ctrl = GUI.kinematic_controls!(ax, h; throttle = false)
        # Mouse position at the corner: the ray misses both mirrors, the fallback finds no plot
        # without a backend
        events(scene).mouseposition[] = (1.0, 1.0)
        @test isnothing(GUI._ray_pick(ctrl, scene)[1])
        @test_logs events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.press)
        @test ctrl.selected[] === nothing
        @test !ctrl.dragging
        close(ctrl)
    end

    @testset "grab, drag-translate, release" begin
        fig, ax, h, m1, m2 = _fixture()
        scene = ax.scene
        P0 = collect(Float64.(BMO.position(m1)))

        pick_m1 = ax2 -> (render_plots(render_children(h)[1])[1], 0)
        ctrl = GUI.kinematic_controls!(ax, h; throttle = false, pick = pick_m1)
        @test ctrl isa GUI.KinematicController

        # a click selects, but does not move the object
        events(scene).mouseposition[] = (100.0, 100.0)
        events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.press)
        events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.release)
        @test ctrl.selected[] === m1
        @test !ctrl.dragging

        # dragging the now-selected object moves it
        events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.press)
        events(scene).mouseposition[] = (140.0, 160.0)
        @test ctrl.dragging
        @test collect(Float64.(BMO.position(m1))) != P0 # object followed the drag
        @test length(render_plots(render_children(h)[1])) > 0 # no plot churn

        events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.release)
        @test !ctrl.dragging
        @test ctrl.selected[] === m1 # stays selected after releasing

        close(ctrl)
    end

    @testset "drag with a local axis parallel to the rotation axis" begin
        # the local x-axis of m1 points along -z, i.e. along the rotation axis: the axes of the
        # controls would span only the y-z plane, hence the axis perpendicular to the local y-axis
        # and the rotation axis takes its place
        fig, ax, h, m1, m2 = _fixture()
        BMO.yrotate3d!(m1, π / 2)
        GUI.update_render!(h)
        scene = ax.scene
        P0 = collect(Float64.(BMO.position(m1)))
        ctrl = GUI.kinematic_controls!(ax, h; throttle = false, pick = ax2 -> (render_plots(render_children(h)[1])[1], 0))
        @test abs(GUI._pose(m1)[2][3, 1]) ≈ 1 atol = 1e-12
        y, x, v = GUI._control_axes(ctrl, m1)
        @test abs(det(hcat(y, x, v))) ≈ 1 atol = 1e-12
        @test y ≈ GUI._pose(m1)[2][:, 2] && v == [0, 0, 1]
        @test x ≈ cross(y, v) atol = 1e-12
        # the same for the local y-axis, e.g. of an object that looks upwards
        BMO.xrotate3d!(m2, π / 2)
        y2, x2, v2 = GUI._control_axes(ctrl, m2)
        @test abs(GUI._pose(m2)[2][3, 2]) ≈ 1 atol = 1e-9
        @test abs(det(hcat(y2, x2, v2))) ≈ 1 atol = 1e-9
        @test x2 ≈ GUI._pose(m2)[2][:, 1]
        # axes in general position are the local ones
        BMO.xrotate3d!(m2, 0.3)
        @test GUI._control_axes(ctrl, m2)[1] ≈ GUI._pose(m2)[2][:, 2]
        # the key of the x-axis moves m1 along the new axis, i.e. sideways
        ctrl.selected[] = m1
        events(scene).keyboardbutton[] = Makie.KeyEvent(Keyboard.right, Keyboard.press)
        @test collect(Float64.(BMO.position(m1))) .- P0 ≈ ctrl.fine_step .* x atol = 1e-12
        events(scene).keyboardbutton[] = Makie.KeyEvent(Keyboard.left, Keyboard.press)
        ctrl.selected[] = nothing
        events(scene).mouseposition[] = (100.0, 100.0)
        events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.press)
        events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.release)
        @test ctrl.selected[] === m1
        events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.press)
        events(scene).mouseposition[] = (140.0, 160.0)
        @test ctrl.dragging
        P1 = collect(Float64.(BMO.position(m1)))
        @test P1 != P0
        @test all(isfinite, P1)
        events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.release)
        close(ctrl)
    end

    @testset "grab consumes the press once the object is selected" begin
        fig, ax, h, m1, m2 = _fixture()
        scene = ax.scene
        pick_m1 = ax2 -> (render_plots(render_children(h)[1])[1], 0)
        ctrl = GUI.kinematic_controls!(ax, h; throttle = false, pick = pick_m1)

        probe = Ref(0)
        on(events(scene).mousebutton, priority = -1000) do event
            probe[] += 1
            return Consume(false)
        end

        # first click: the object is not yet selected, so press and release are not consumed
        events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.press)
        @test probe[] == 1
        events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.release)
        @test probe[] == 2
        @test ctrl.selected[] === m1

        # pressing again on the now-selected object is consumed (camera blocked)
        events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.press)
        @test probe[] == 2 # low-priority listener not reached this time

        close(ctrl)
    end

    @testset "background click without drag deselects" begin
        fig, ax, h, m1, m2 = _fixture()
        scene = ax.scene
        pick_none = ax2 -> (nothing, 0)
        ctrl = GUI.kinematic_controls!(ax, h; throttle = false, pick = pick_none)
        ctrl.selected[] = m1 # pretend something was already selected

        events(scene).mouseposition[] = (50.0, 50.0)
        events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.press)
        @test ctrl.selected[] === m1 # press alone doesn't deselect yet
        events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.release)
        @test ctrl.selected[] === nothing

        close(ctrl)
    end

    @testset "keyboard fine controls" begin
        fig, ax, h, m1, m2 = _fixture()
        scene = ax.scene
        pick_m1 = ax2 -> (render_plots(render_children(h)[1])[1], 0)
        ctrl = GUI.kinematic_controls!(ax, h; throttle = false, pick = pick_m1, fine_step = 1e-3, fine_angle = 1e-3)
        events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.press)
        events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.release)
        @test ctrl.selected[] === m1

        P0 = collect(Float64.(BMO.position(m1)))
        events(scene).keyboardbutton[] = Makie.KeyEvent(Keyboard.up, Keyboard.press)
        P1 = collect(Float64.(BMO.position(m1)))
        @test isapprox(norm(P1 .- P0), 1e-3; atol = 1e-9)

        events(scene).keyboardbutton[] = Makie.KeyEvent(Keyboard.down, Keyboard.press)
        P2 = collect(Float64.(BMO.position(m1)))
        @test isapprox(P2, P0; atol = 1e-9)

        # move mode: ← moves along -x, page up along the rotation axis
        R0 = Matrix{Float64}(BMO.orientation(m1))
        events(scene).keyboardbutton[] = Makie.KeyEvent(Keyboard.left, Keyboard.press)
        @test collect(Float64.(BMO.position(m1))) ≈ P0 .- 1e-3 .* R0[:, 1]
        events(scene).keyboardbutton[] = Makie.KeyEvent(Keyboard.page_up, Keyboard.press)
        @test collect(Float64.(BMO.position(m1))) ≈ P0 .- 1e-3 .* R0[:, 1] .+ [0, 0, 1e-3]
        @test Matrix{Float64}(BMO.orientation(m1)) ≈ R0

        # rotate mode: ← rotates positively around the rotation axis, position is kept
        events(scene).keyboardbutton[] = Makie.KeyEvent(Keyboard.m, Keyboard.press)
        @test ctrl.mode[] == :rotate
        P1 = collect(Float64.(BMO.position(m1)))
        events(scene).keyboardbutton[] = Makie.KeyEvent(Keyboard.left, Keyboard.press)
        @test Matrix{Float64}(BMO.orientation(m1)) ≈ BMO.rotate3d([0, 0, 1], 1e-3) * R0
        @test collect(Float64.(BMO.position(m1))) ≈ P1
        events(scene).keyboardbutton[] = Makie.KeyEvent(Keyboard.m, Keyboard.press)
        @test ctrl.mode[] == :move

        # shift multiplies the step by 10
        push!(events(scene).keyboardstate, Keyboard.left_shift)
        P3 = collect(Float64.(BMO.position(m1)))
        events(scene).keyboardbutton[] = Makie.KeyEvent(Keyboard.up, Keyboard.press)
        P4 = collect(Float64.(BMO.position(m1)))
        @test isapprox(norm(P4 .- P3), 1e-2; atol = 1e-8)
        delete!(events(scene).keyboardstate, Keyboard.left_shift)

        # reset
        events(scene).keyboardbutton[] = Makie.KeyEvent(Keyboard.backspace, Keyboard.press)
        @test isapprox(collect(Float64.(BMO.position(m1))), P0; atol = 1e-9)
        @test isapprox(Matrix{Float64}(BMO.orientation(m1)), R0; atol = 1e-6)

        # escape deselects
        events(scene).keyboardbutton[] = Makie.KeyEvent(Keyboard.escape, Keyboard.press)
        @test ctrl.selected[] === nothing

        close(ctrl)
    end

    @testset "on_change and update_render! are called" begin
        fig, ax, h, m1, m2 = _fixture()
        scene = ax.scene
        pick_m1 = ax2 -> (render_plots(render_children(h)[1])[1], 0)
        changed = Ref{Any}(nothing)
        ctrl = GUI.kinematic_controls!(
            ax, h; throttle = false, pick = pick_m1, on_change = o -> (changed[] = o)
        )
        events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.press)
        events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.release)
        events(scene).keyboardbutton[] = Makie.KeyEvent(Keyboard.up, Keyboard.press)
        @test changed[] === m1
        close(ctrl)
    end

    @testset "errors in on_change are logged once, not rethrown" begin
        fig, ax, h, m1, m2 = _fixture()
        scene = ax.scene
        pick_m1 = ax2 -> (render_plots(render_children(h)[1])[1], 0)
        ctrl = GUI.kinematic_controls!(
            ax, h; throttle = false, pick = pick_m1, on_change = o -> error("no hits")
        )
        events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.press)
        events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.release)
        @test_logs (:error, r"on_change") events(scene).keyboardbutton[] = Makie.KeyEvent(Keyboard.up, Keyboard.press)
        # the same error again is not logged a second time
        @test_logs events(scene).keyboardbutton[] = Makie.KeyEvent(Keyboard.up, Keyboard.press)
        close(ctrl)
    end

    @testset "throttle coalesces updates to one per tick" begin
        fig, ax, h, m1, m2 = _fixture()
        scene = ax.scene
        pick_m1 = ax2 -> (render_plots(render_children(h)[1])[1], 0)
        n_updates = Ref(0)
        ctrl = GUI.kinematic_controls!(
            ax, h; throttle = true, pick = pick_m1, on_change = o -> (n_updates[] += 1)
        )
        events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.press)
        events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.release)
        for _ in 1:5
            events(scene).keyboardbutton[] = Makie.KeyEvent(Keyboard.up, Keyboard.press)
        end
        @test n_updates[] == 0 # nothing applied yet, only marked dirty
        @test ctrl.dirty
        notify(events(scene).tick)
        @test n_updates[] == 1
        @test !ctrl.dirty
        close(ctrl)
    end

    @testset "left-drag rotates in the rotate mode" begin
        fig, ax, h, m1, m2 = _fixture()
        scene = ax.scene
        pick_m1 = ax2 -> (render_plots(render_children(h)[1])[1], 0)
        ctrl = GUI.kinematic_controls!(ax, h; throttle = false, pick = pick_m1, mode = :rotate,
            rotate_speed = 1e-2)
        P0 = collect(Float64.(BMO.position(m1)))
        R0 = Matrix{Float64}(BMO.orientation(m1))
        events(scene).mouseposition[] = (100.0, 100.0)
        events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.press)
        events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.release)
        @test ctrl.selected[] === m1
        events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.press)
        events(scene).mouseposition[] = (110.0, 100.0)
        events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.release)
        @test Matrix{Float64}(BMO.orientation(m1)) ≈ BMO.rotate3d([0, 0, 1], 0.1) * R0
        @test collect(Float64.(BMO.position(m1))) ≈ P0
        # rings are shown instead of arrows
        @test ctrl.plots[3].visible[]
        close(ctrl)
        @test_throws ArgumentError GUI.kinematic_controls!(ax, h; mode = :fly)
    end

    @testset "h toggles the controls overlay" begin
        fig, ax, h, m1, m2 = _fixture()
        scene = ax.scene
        ctrl = GUI.kinematic_controls!(ax, h; throttle = false, fine_step = 20e-9)
        hint = GUI._help_hint(:move, 20e-9, 10e-6)
        @test ctrl.help_obs[] == hint
        # works without a selected object
        events(scene).keyboardbutton[] = Makie.KeyEvent(Keyboard.h, Keyboard.press)
        @test occursin("+/-: keyboard step, now 20 nm", ctrl.help_obs[])
        @test ctrl.help_obs[] == GUI._help_text(:move, 20e-9, 10e-6)
        events(scene).keyboardbutton[] = Makie.KeyEvent(Keyboard.h, Keyboard.press)
        @test ctrl.help_obs[] == hint
        close(ctrl)
        ctrl = GUI.kinematic_controls!(ax, h; show_help = true)
        @test ctrl.help_obs[] != GUI._help_hint(:move, 10e-9, 10e-6)
        close(ctrl)
    end

    @testset "spectator mode" begin
        fig, ax, h, m1, m2 = _fixture()
        scene = ax.scene
        pick_m1 = ax2 -> (render_plots(render_children(h)[1])[1], 0)
        ctrl = GUI.kinematic_controls!(ax, h; throttle = false, pick = pick_m1)
        events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.press)
        events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.release)
        @test ctrl.selected[] === m1

        # v clears the selection, clicks and keys no longer select or move anything
        events(scene).keyboardbutton[] = Makie.KeyEvent(Keyboard.v, Keyboard.press)
        @test ctrl.spectator[]
        @test ctrl.selected[] === nothing
        @test ctrl.help_obs[] == GUI._SPECTATOR_HINT
        P0 = collect(Float64.(BMO.position(m1)))
        events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.press)
        events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.release)
        @test ctrl.selected[] === nothing
        events(scene).keyboardbutton[] = Makie.KeyEvent(Keyboard.m, Keyboard.press)
        @test ctrl.mode[] == :move
        events(scene).unicode_input[] = '+'
        @test ctrl.fine_step ≈ 10e-9
        events(scene).keyboardbutton[] = Makie.KeyEvent(Keyboard.h, Keyboard.press)
        @test ctrl.help_obs[] == GUI._help_text(:move, 10e-9, 10e-6; spectator = true)
        @test occursin("v: switch to edit mode", ctrl.help_obs[])
        events(scene).keyboardbutton[] = Makie.KeyEvent(Keyboard.h, Keyboard.press)

        # v again switches back to the edit mode
        events(scene).keyboardbutton[] = Makie.KeyEvent(Keyboard.v, Keyboard.press)
        @test !ctrl.spectator[]
        events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.press)
        events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.release)
        @test ctrl.selected[] === m1
        @test collect(Float64.(BMO.position(m1))) == P0
        close(ctrl)

        ctrl = GUI.kinematic_controls!(ax, h; spectator = true)
        @test ctrl.spectator[]
        @test ctrl.help_obs[] == GUI._SPECTATOR_HINT
        close(ctrl)
    end

    @testset "static objects are not movable" begin
        m1 = RoundPlanoMirror(0.025, 0.005)
        fixed = FixedMirror(BMO.shape(RoundPlanoMirror(0.025, 0.005)))
        translate3d!(m1, [0.1, 0, 0])
        fig = Figure()
        ax = LScene(fig[1, 1])
        h = live_render!(ax, System([m1, fixed]))
        @test length(render_children(h)) == 2
        ctrl = GUI.kinematic_controls!(ax, h)
        @test ctrl.movable == [m1]
        close(ctrl)
    end

    @testset "step size keys" begin
        @test GUI._next_step(3e-8, 1) ≈ 5e-8
        @test GUI._next_step(3e-8, -1) ≈ 2e-8
        @test GUI._next_step(1e-8, 1) ≈ 2e-8
        @test GUI._next_step(5e-8, 1) ≈ 1e-7
        @test GUI._next_step(1e-7, -1) ≈ 5e-8
        @test GUI._next_step(1.0, -1) ≈ 0.5

        # the step is shown in the unit of its size
        _step(x) = GUI._step_string(:move, x, 0.0)
        @test _step.([1e-12, 5e-10, 1e-9, 5e-7]) == ["1 pm", "500 pm", "1 nm", "500 nm"]
        @test _step.([1e-6, 2.5e-4, 1e-3, 5e-3]) == ["1 µm", "250 µm", "1 mm", "5 mm"]
        @test _step.([1e-2, 0.5, 1.0, 12.0]) == ["1 cm", "50 cm", "1 m", "12 m"]
        # rounding errors of the 1-2-5 sequence, and steps below the smallest unit
        @test _step(0.9999999e-3) == "1 mm" && _step(5e-13) == "0.5 pm"
        @test foldl((x, _) -> GUI._next_step(x, 1), 1:19; init = 5e-9) |> _step == "1 cm"
        _angle(x) = GUI._step_string(:rotate, 0.0, x)
        @test _angle.([1e-9, 5e-5, 1e-3, 0.5, π / 4]) ==
              ["1 nrad", "50 µrad", "1 mrad", "500 mrad", "785 mrad"]

        fig, ax, h, m1, m2 = _fixture()
        scene = ax.scene
        ctrl = GUI.kinematic_controls!(ax, h; throttle = false, fine_step = 10e-9, fine_angle = 10e-6)
        @test ctrl.help_obs[] == "move mode, step 10 nm, +/-: step, m: switch mode, v: spectator, h: show controls"

        # move mode, no object selected: 1-2-5 sequence on fine_step only
        @test isnothing(ctrl.selected[])
        steps = Float64[]
        for c in ('+', '+', '+', '-')
            events(scene).unicode_input[] = c
            push!(steps, ctrl.fine_step)
        end
        @test steps ≈ [20e-9, 50e-9, 100e-9, 50e-9]
        @test ctrl.fine_angle == 10e-6
        @test ctrl.help_obs[] == "move mode, step 50 nm, +/-: step, m: switch mode, v: spectator, h: show controls"

        # help overlay shows the new step as well
        events(scene).keyboardbutton[] = Makie.KeyEvent(Keyboard.h, Keyboard.press)
        @test occursin("keyboard step, now 50 nm", ctrl.help_obs[])
        events(scene).keyboardbutton[] = Makie.KeyEvent(Keyboard.h, Keyboard.press)

        # rotate mode: fine_angle only
        events(scene).keyboardbutton[] = Makie.KeyEvent(Keyboard.m, Keyboard.press)
        steps = Float64[]
        for c in ('+', '+', '+', '-')
            events(scene).unicode_input[] = c
            push!(steps, ctrl.fine_angle)
        end
        @test steps ≈ [20e-6, 50e-6, 100e-6, 50e-6]
        @test ctrl.fine_step ≈ 50e-9
        @test occursin("rotate mode, step 50 µrad", ctrl.help_obs[])

        # clamping at the bounds
        ctrl.fine_angle = π / 4
        events(scene).unicode_input[] = '+'
        @test ctrl.fine_angle ≈ π / 4
        events(scene).unicode_input[] = '-'
        @test ctrl.fine_angle ≈ 0.5
        ctrl.fine_angle = 1e-9
        events(scene).unicode_input[] = '-'
        @test ctrl.fine_angle ≈ 1e-9
        events(scene).keyboardbutton[] = Makie.KeyEvent(Keyboard.m, Keyboard.press)
        ctrl.fine_step = 1.0
        events(scene).unicode_input[] = '+'
        @test ctrl.fine_step ≈ 1.0
        ctrl.fine_step = 1e-12
        events(scene).unicode_input[] = '-'
        @test ctrl.fine_step ≈ 1e-12

        # + and - are consumed, other characters are passed on
        probe = Char[]
        on(events(scene).unicode_input, priority = -1000) do c
            push!(probe, c)
            return Consume(false)
        end
        events(scene).unicode_input[] = '+'
        events(scene).unicode_input[] = 'x'
        @test probe == ['x']

        # also with a selected object
        ctrl.selected[] = m1
        ctrl.fine_step = 10e-9
        events(scene).unicode_input[] = '+'
        @test ctrl.fine_step ≈ 20e-9

        # the listener is removed by close
        close(ctrl)
        events(scene).unicode_input[] = '+'
        @test ctrl.fine_step ≈ 20e-9
    end

    # Nested groups G ⊃ H ⊃ lens and a second top-level group M ⊃ m. The lens is at the origin,
    # which the default camera looks at, all other objects are away from the camera ray.
    function _group_fixture()
        lens = RoundPlanoMirror(0.025, 0.005)
        h1 = RoundPlanoMirror(0.025, 0.005)
        g1 = RoundPlanoMirror(0.025, 0.005)
        m = RoundPlanoMirror(0.025, 0.005)
        translate3d!(h1, [0.3, 0, 0])
        translate3d!(g1, [0, 0.3, 0])
        translate3d!(m, [0, 0, -0.3])
        H = ObjectGroup([lens, h1])
        G = ObjectGroup([g1, H])
        M = ObjectGroup([m])
        sys = System([G, M])
        fig = Figure()
        ax = LScene(fig[1, 1])
        h = live_render!(ax, sys)
        return (; fig, ax, h, lens, h1, g1, m, H, G, M)
    end

    _click!(scene) = (events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.press);
                      events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.release))
    _pos(obj) = collect(Float64.(BMO.position(obj)))

    @testset "group drill-down" begin
        @testset "_drill_select reproduces the trace table" begin
            f = _group_fixture()
            ctrl = GUI.kinematic_controls!(f.ax, f.h; throttle = false)
            @test length(ctrl.movable) == 2
            @test ctrl.movable[1] === f.G && ctrl.movable[2] === f.M
            @test GUI._chain(ctrl, f.lens) == [f.lens, f.H, f.G]
            @test GUI._drill_select(ctrl, f.lens) === f.G
            ctrl.selected[] = f.G
            @test GUI._drill_select(ctrl, f.lens) === f.H
            ctrl.selected[] = f.H
            @test GUI._drill_select(ctrl, f.lens) === f.lens
            ctrl.selected[] = f.lens
            @test GUI._drill_select(ctrl, f.lens) === f.lens
            @test GUI._drill_select(ctrl, f.m) === f.M
            # clicking on a sibling of the selected sub-object selects the top level again
            @test GUI._drill_select(ctrl, f.h1) === f.G
            @test GUI._is_movable(ctrl, f.lens)
            close(ctrl)
        end

        @testset "trace table via clicks and esc" begin
            f = _group_fixture()
            scene = f.ax.scene
            target = Ref{Any}(f.lens)
            plot_of(obj) = render_plots(only(oh for oh in render_children(f.h) if rendered(oh) === obj))[1]
            ctrl = GUI.kinematic_controls!(f.ax, f.h; throttle = false,
                pick = ax2 -> (plot_of(target[]), 0))
            selections = Any[]
            for _ in 1:4
                _click!(scene)
                push!(selections, ctrl.selected[])
            end
            @test selections[1] === f.G
            @test selections[2] === f.H
            @test selections[3] === f.lens
            @test selections[4] === f.lens
            target[] = f.m
            _click!(scene)
            @test ctrl.selected[] === f.M

            # esc goes up one level, deselects at the top level
            ctrl.selected[] = f.lens
            events(scene).keyboardbutton[] = Makie.KeyEvent(Keyboard.escape, Keyboard.press)
            @test ctrl.selected[] === f.H
            events(scene).keyboardbutton[] = Makie.KeyEvent(Keyboard.escape, Keyboard.press)
            @test ctrl.selected[] === f.G
            events(scene).keyboardbutton[] = Makie.KeyEvent(Keyboard.escape, Keyboard.press)
            @test ctrl.selected[] === nothing
            close(ctrl)
        end

        @testset "drill-down via ray picking" begin
            f = _group_fixture()
            scene = f.ax.scene
            vp = scene.viewport[]
            cx, cy = vp.origin[1] + vp.widths[1] / 2, vp.origin[2] + vp.widths[2] / 2
            ctrl = GUI.kinematic_controls!(f.ax, f.h; throttle = false)
            events(scene).mouseposition[] = (cx, cy)
            # the ray pick returns the leaf, the click logic decides the level
            @test GUI._ray_pick(ctrl, scene)[1] === f.lens
            _click!(scene)
            @test ctrl.selected[] === f.G
            _click!(scene)
            @test ctrl.selected[] === f.H
            _click!(scene)
            @test ctrl.selected[] === f.lens
            close(ctrl)
        end

        @testset "key steps and reset per level" begin
            f = _group_fixture()
            scene = f.ax.scene
            # handles in render order: g1, lens, h1, m
            @test [rendered(oh) for oh in render_children(f.h)] == [f.g1, f.lens, f.h1, f.m]
            ctrl = GUI.kinematic_controls!(f.ax, f.h; throttle = false, fine_step = 1e-3,
                pick = ax2 -> (render_plots(render_children(f.h)[2])[1], 0))
            key!(k) = (events(scene).keyboardbutton[] = Makie.KeyEvent(k, Keyboard.press))
            init = Dict(n => _pos(getfield(f, n)) for n in (:lens, :h1, :g1, :m, :H, :G, :M))
            siblings = (:h1, :g1, :m, :H, :G, :M)

            # init_poses of all levels
            for n in keys(init)
                @test haskey(ctrl.init_poses, getfield(f, n))
            end

            # sub-object: only the lens moves
            foreach(_ -> _click!(scene), 1:3)
            @test ctrl.selected[] === f.lens
            key!(Keyboard.up)
            @test isapprox(norm(_pos(f.lens) - init[:lens]), 1e-3; atol = 1e-12)
            for n in siblings
                @test isapprox(_pos(getfield(f, n)), init[n]; atol = 1e-12)
            end
            # the plots of the lens follow, the others do not (their model matrix is the move)
            shift(oh) = Vector{Float64}(Makie.translation(first(render_plots(oh)))[])
            @test isapprox(shift(render_children(f.h)[2]), _pos(f.lens) - init[:lens]; atol = 1e-9)
            @test isapprox(shift(render_children(f.h)[3]), zeros(3); atol = 1e-12)

            # backspace resets the sub-object only
            key!(Keyboard.backspace)
            @test isapprox(_pos(f.lens), init[:lens]; atol = 1e-12)

            # esc: subgroup H, moving H moves lens and h1, but not g1
            key!(Keyboard.escape)
            @test ctrl.selected[] === f.H
            key!(Keyboard.up)
            d = _pos(f.H) - init[:H]
            @test isapprox(norm(d), 1e-3; atol = 1e-12)
            @test isapprox(_pos(f.lens), init[:lens] + d; atol = 1e-12)
            @test isapprox(_pos(f.h1), init[:h1] + d; atol = 1e-12)
            @test isapprox(_pos(f.g1), init[:g1]; atol = 1e-12)

            # move the lens within the moved H, backspace on the lens keeps h1 moved
            _click!(scene)
            @test ctrl.selected[] === f.lens
            key!(Keyboard.up)
            key!(Keyboard.backspace)
            @test isapprox(_pos(f.lens), init[:lens]; atol = 1e-12)
            @test isapprox(_pos(f.h1), init[:h1] + d; atol = 1e-12)

            # backspace on the group resets the group
            key!(Keyboard.escape)
            @test ctrl.selected[] === f.H
            key!(Keyboard.backspace)
            @test isapprox(_pos(f.H), init[:H]; atol = 1e-12)
            @test isapprox(_pos(f.h1), init[:h1]; atol = 1e-12)
            @test isapprox(_pos(f.g1), init[:g1]; atol = 1e-12)
            close(ctrl)
        end

        @testset "selection box of a group spans all leaves" begin
            f = _group_fixture()
            ctrl = GUI.kinematic_controls!(f.ax, f.h; throttle = false)
            leaf_plots(objs) = reduce(vcat, [render_plots(oh) for oh in render_children(f.h) if any(o -> o === rendered(oh), objs)])
            function check_box(objs)
                bb = mapreduce(Makie.boundingbox, GeometryBasics.union, leaf_plots(objs))
                pts = ctrl.box_obs[]
                @test length(pts) == 24
                lo = [minimum(p[i] for p in pts) for i in 1:3]
                hi = [maximum(p[i] for p in pts) for i in 1:3]
                @test isapprox(lo, collect(minimum(bb)); atol = 1e-5)
                @test isapprox(hi, collect(maximum(bb)); atol = 1e-5)
            end
            ctrl.selected[] = f.G
            GUI._update_selection_box!(ctrl)
            check_box((f.lens, f.h1, f.g1))
            ctrl.selected[] = f.H
            GUI._update_selection_box!(ctrl)
            check_box((f.lens, f.h1))
            ctrl.selected[] = f.lens
            GUI._update_selection_box!(ctrl)
            check_box((f.lens,))
            close(ctrl)
        end

        @testset "help text" begin
            help = GUI._help_text(:move, 10e-9, 10e-6)
            @test occursin("again: part of a group", help)
            @test occursin("esc: enclosing group or deselect", help)
        end
    end

    @testset "close disconnects listeners and removes the selection box" begin
        fig, ax, h, m1, m2 = _fixture()
        scene = ax.scene
        pick_m1 = ax2 -> (render_plots(render_children(h)[1])[1], 0)
        n0 = length(ax.scene.plots)
        nb = length(ax.blockscene.plots)
        limits = Makie.data_limits(ax.scene)
        ctrl = GUI.kinematic_controls!(ax, h; throttle = false, pick = pick_m1)
        @test length(ax.scene.plots) == n0 + 4 # selection box and gizmo
        @test length(ax.blockscene.plots) == nb + 1 # controls overlay
        # the hidden gizmo and the overlay must not change the limits of the scene
        @test Makie.data_limits(ax.scene) ≈ limits

        close(ctrl)
        @test isempty(ctrl.listeners)
        @test length(ax.scene.plots) == n0
        @test length(ax.blockscene.plots) == nb

        # listeners are gone: this must not error and must not select anything
        events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.press)
        @test ctrl.selected[] === nothing
    end

    @testset "click vs drag" begin
        # Simplified group hierarchy matching the trace table of the plan: G ⊃ lens, M separate
        function _cvd_fixture()
            lens = RoundPlanoMirror(0.025, 0.005)
            m = RoundPlanoMirror(0.025, 0.005)
            translate3d!(m, [0, 0, -0.3])
            G = ObjectGroup([lens])
            M = ObjectGroup([m])
            sys = System([G, M])
            fig = Figure()
            ax = LScene(fig[1, 1])
            h = live_render!(ax, sys)
            return (; fig, ax, h, lens, m, G, M)
        end
        _plot_of(f, obj) = render_plots(only(oh for oh in render_children(f.h) if rendered(oh) === obj))[1]

        _press!(scene, pos) = (events(scene).mouseposition[] = pos;
                                events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.press))
        _move!(scene, pos) = (events(scene).mouseposition[] = pos)
        _release!(scene) = (events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.release))
        _drag!(scene, from, to) = (_press!(scene, from); _move!(scene, to); _release!(scene))
        _click_at!(scene, pos) = (_press!(scene, pos); _release!(scene))

        @testset "trace table" begin
            f = _cvd_fixture()
            scene = f.ax.scene
            target = Ref{Any}(f.lens)
            ctrl = GUI.kinematic_controls!(f.ax, f.h; throttle = false,
                pick = ax2 -> (isnothing(target[]) ? nothing : _plot_of(f, target[]), 0))

            # drag starting on lens, 50 px; nothing selected before -> camera rotates, nothing selected
            _drag!(scene, (100.0, 100.0), (150.0, 100.0))
            @test ctrl.selected[] === nothing

            # click on lens; nothing selected before -> G selected
            _click_at!(scene, (100.0, 100.0))
            @test ctrl.selected[] === f.G

            # drag starting on lens, 50 px; G selected -> G moves, camera still
            P0 = collect(Float64.(BMO.position(f.G)))
            _drag!(scene, (100.0, 100.0), (150.0, 100.0))
            @test collect(Float64.(BMO.position(f.G))) != P0
            @test ctrl.selected[] === f.G

            # click on lens; G selected -> lens selected
            _click_at!(scene, (100.0, 100.0))
            @test ctrl.selected[] === f.lens

            # drag starting on M, 50 px; lens selected -> camera rotates, lens stays selected
            target[] = f.m
            _drag!(scene, (100.0, 100.0), (150.0, 100.0))
            @test ctrl.selected[] === f.lens

            # click on empty space; lens selected -> nothing selected
            target[] = nothing
            _click_at!(scene, (400.0, 400.0))
            @test ctrl.selected[] === nothing

            close(ctrl)
        end

        @testset "drag on an unselected object does not block the camera" begin
            fig, ax, h, m1, m2 = _fixture()
            scene = ax.scene
            pick_m1 = ax2 -> (render_plots(render_children(h)[1])[1], 0)
            ctrl = GUI.kinematic_controls!(ax, h; throttle = false, pick = pick_m1)
            P0 = collect(Float64.(BMO.position(m1)))

            probe = Ref(0)
            on(events(scene).mousebutton, priority = -1000) do event
                probe[] += 1
                return Consume(false)
            end

            # No mouseposition is set before the press, so Makie's own Camera3D mouse controls
            # (which only react while the mouse is inside the viewport) do not compete for the
            # event either; this isolates whether `kinematic_controls!` itself consumes it.
            events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.press)
            @test probe[] == 1 # camera not blocked
            _move!(scene, (150.0, 100.0))
            _release!(scene)
            @test collect(Float64.(BMO.position(m1))) == P0 # no pose change
            @test ctrl.selected[] === nothing # it was a drag, not a click
            close(ctrl)
        end

        @testset "drag on the selected object blocks the camera and moves it" begin
            fig, ax, h, m1, m2 = _fixture()
            scene = ax.scene
            pick_m1 = ax2 -> (render_plots(render_children(h)[1])[1], 0)
            ctrl = GUI.kinematic_controls!(ax, h; throttle = false, pick = pick_m1)
            _click_at!(scene, (100.0, 100.0))
            @test ctrl.selected[] === m1

            probe = Ref(0)
            on(events(scene).mousebutton, priority = -1000) do event
                probe[] += 1
                return Consume(false)
            end

            P0 = collect(Float64.(BMO.position(m1)))
            _press!(scene, (100.0, 100.0))
            @test probe[] == 0 # probe receives nothing
            _move!(scene, (140.0, 100.0))
            @test collect(Float64.(BMO.position(m1))) != P0 # the object moves
            _release!(scene)
            close(ctrl)
        end

        @testset "press+release with 2 px movement does not change the pose" begin
            fig, ax, h, m1, m2 = _fixture()
            scene = ax.scene
            pick_m1 = ax2 -> (render_plots(render_children(h)[1])[1], 0)
            ctrl = GUI.kinematic_controls!(ax, h; throttle = false, pick = pick_m1)
            _click_at!(scene, (100.0, 100.0))
            @test ctrl.selected[] === m1

            P0 = collect(Float64.(BMO.position(m1)))
            _press!(scene, (100.0, 100.0))
            _move!(scene, (102.0, 100.0)) # 2 px, below the default threshold of 3
            _release!(scene)
            @test collect(Float64.(BMO.position(m1))) == P0
            @test !ctrl.dragging
            close(ctrl)
        end

        @testset "select_modifier gates clicks and drags" begin
            fig, ax, h, m1, m2 = _fixture()
            scene = ax.scene
            pick_m1 = ax2 -> (render_plots(render_children(h)[1])[1], 0)
            ctrl = GUI.kinematic_controls!(ax, h; throttle = false, pick = pick_m1,
                select_modifier = Keyboard.left_shift)

            probe = Ref(0)
            on(events(scene).mousebutton, priority = -1000) do event
                probe[] += 1
                return Consume(false)
            end

            # without shift: the click does not select, the probe gets the event (no mouseposition
            # is set, so Camera3D's own mouse controls do not compete for the event either)
            events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.press)
            @test probe[] == 1
            events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.release)
            @test ctrl.selected[] === nothing

            # with shift held: the click selects
            push!(events(scene).keyboardstate, Keyboard.left_shift)
            events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.press)
            events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.release)
            @test ctrl.selected[] === m1
            delete!(events(scene).keyboardstate, Keyboard.left_shift)
            close(ctrl)
        end
    end

    @testset "keyboard controls unchanged except backspace reset" begin
        fig, ax, h, m1, m2 = _fixture()
        scene = ax.scene
        pick_m1 = ax2 -> (render_plots(render_children(h)[1])[1], 0)
        ctrl = GUI.kinematic_controls!(ax, h; throttle = false, pick = pick_m1, fine_step = 1e-3)
        events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.press)
        events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.release)
        @test ctrl.selected[] === m1

        P0 = collect(Float64.(BMO.position(m1)))
        events(scene).keyboardbutton[] = Makie.KeyEvent(Keyboard.up, Keyboard.press)
        @test isapprox(norm(collect(Float64.(BMO.position(m1))) .- P0), 1e-3; atol = 1e-9)

        events(scene).keyboardbutton[] = Makie.KeyEvent(Keyboard.backspace, Keyboard.press)
        @test isapprox(collect(Float64.(BMO.position(m1))), P0; atol = 1e-9)

        events(scene).unicode_input[] = '+'
        @test ctrl.fine_step ≈ 2e-3

        # r is no longer bound to reset: not consumed, the probe receives it, pose unchanged
        keys_probe = Any[]
        on(events(scene).keyboardbutton, priority = -1000) do event
            push!(keys_probe, event.key)
            return Consume(false)
        end
        P1 = collect(Float64.(BMO.position(m1)))
        events(scene).keyboardbutton[] = Makie.KeyEvent(Keyboard.r, Keyboard.press)
        @test keys_probe == [Keyboard.r]
        @test collect(Float64.(BMO.position(m1))) == P1
        close(ctrl)
    end

    @testset "no key collides with Camera3D" begin
        _collect_keys!(out, x::Keyboard.Button) = push!(out, x)
        _collect_keys!(out, ::Mouse.Button) = out
        _collect_keys!(out, ::Bool) = out
        _collect_keys!(out, x::Makie.And) = (_collect_keys!(out, x.left); _collect_keys!(out, x.right))
        _collect_keys!(out, x::Makie.Or) = (_collect_keys!(out, x.left); _collect_keys!(out, x.right))
        _collect_keys!(out, x::Makie.Not) = _collect_keys!(out, x.x)
        _collect_keys!(out, x::Makie.Exclusively) = (foreach(b -> _collect_keys!(out, b), x.x); out)
        _collect_keys!(out, x) = out

        fig = Figure()
        ax = LScene(fig[1, 1])
        cam = Makie.cameracontrols(ax.scene)
        camera_keys = Set{Keyboard.Button}()
        for (_, obs) in cam.controls.attributes
            _collect_keys!(camera_keys, obs[])
        end
        @test !isempty(camera_keys) # sanity: the extraction actually found keys

        handled_keys = Set([
            Keyboard.h, Keyboard.m, Keyboard.t, Keyboard.v, Keyboard.escape, Keyboard.backspace,
            Keyboard.up, Keyboard.down, Keyboard.left, Keyboard.right,
            Keyboard.page_up, Keyboard.page_down, Keyboard.left_shift, Keyboard.right_shift,
            Keyboard.p, Keyboard.c, Keyboard.delete, Keyboard.g
        ])
        @test isempty(intersect(handled_keys, camera_keys))

        # Key combinations with a modifier: the key itself must not be a camera key either, except
        # for the deliberate exceptions below. The modifiers alone are no conflict, Camera3D only
        # uses ctrl and alt together with a left click (reset, reposition).
        combo_keys = Set([
            Keyboard.z, # ctrl/cmd+z: undo, ctrl/cmd+shift+z: redo
            Keyboard.y, # ctrl/cmd+y: redo
            Keyboard.c  # shift+c: flip the selected clip plane
        ])
        # Camera3D fixes the camera to the z/y axis only while z/y is held during a camera drag,
        # which does not happen for the standard undo/redo shortcuts, hence they are kept
        exceptions = Set([Keyboard.z, Keyboard.y])
        @test isempty(intersect(setdiff(combo_keys, exceptions), camera_keys))
        # the exceptions are still needed, otherwise they can be removed
        @test exceptions ⊆ camera_keys
    end

    @testset "undo/redo" begin
        _ctrl_z!(scene) = (push!(events(scene).keyboardstate, Keyboard.left_control);
                            events(scene).keyboardbutton[] = Makie.KeyEvent(Keyboard.z, Keyboard.press);
                            delete!(events(scene).keyboardstate, Keyboard.left_control))
        _ctrl_y!(scene) = (push!(events(scene).keyboardstate, Keyboard.left_control);
                            events(scene).keyboardbutton[] = Makie.KeyEvent(Keyboard.y, Keyboard.press);
                            delete!(events(scene).keyboardstate, Keyboard.left_control))

        @testset "undo/redo of a drag" begin
            fig, ax, h, m1, m2 = _fixture()
            scene = ax.scene
            pick_m1 = ax2 -> (render_plots(render_children(h)[1])[1], 0)
            ctrl = GUI.kinematic_controls!(ax, h; throttle = false, pick = pick_m1)
            events(scene).mouseposition[] = (100.0, 100.0)
            events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.press)
            events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.release)
            @test ctrl.selected[] === m1
            P0 = collect(Float64.(BMO.position(m1)))

            events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.press)
            events(scene).mouseposition[] = (140.0, 160.0)
            events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.release)
            P1 = collect(Float64.(BMO.position(m1)))
            @test P1 != P0
            @test length(ctrl.undo_stack) == 1
            @test isempty(ctrl.redo_stack)

            _ctrl_z!(scene)
            @test isapprox(collect(Float64.(BMO.position(m1))), P0; atol = 1e-9)
            @test isempty(ctrl.undo_stack)
            @test length(ctrl.redo_stack) == 1
            @test ctrl.selected[] === m1

            _ctrl_y!(scene)
            @test isapprox(collect(Float64.(BMO.position(m1))), P1; atol = 1e-9)
            @test length(ctrl.undo_stack) == 1
            @test isempty(ctrl.redo_stack)
            close(ctrl)
        end

        @testset "consecutive key steps merge into one entry" begin
            fig, ax, h, m1, m2 = _fixture()
            scene = ax.scene
            pick_m1 = ax2 -> (render_plots(render_children(h)[1])[1], 0)
            ctrl = GUI.kinematic_controls!(ax, h; throttle = false, pick = pick_m1, fine_step = 1e-3)
            events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.press)
            events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.release)
            @test ctrl.selected[] === m1
            P0 = collect(Float64.(BMO.position(m1)))
            for _ in 1:5
                events(scene).keyboardbutton[] = Makie.KeyEvent(Keyboard.up, Keyboard.press)
            end
            P1 = collect(Float64.(BMO.position(m1)))
            @test isapprox(norm(P1 .- P0), 5e-3; atol = 1e-9)
            @test length(ctrl.undo_stack) == 1 # 5 steps merged into 1 entry

            _ctrl_z!(scene)
            @test isapprox(collect(Float64.(BMO.position(m1))), P0; atol = 1e-9)
            @test isempty(ctrl.undo_stack)
        end

        @testset "key steps more than 1 s apart do not merge" begin
            fig, ax, h, m1, m2 = _fixture()
            scene = ax.scene
            pick_m1 = ax2 -> (render_plots(render_children(h)[1])[1], 0)
            ctrl = GUI.kinematic_controls!(ax, h; throttle = false, pick = pick_m1, fine_step = 1e-3)
            events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.press)
            events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.release)
            events(scene).keyboardbutton[] = Makie.KeyEvent(Keyboard.up, Keyboard.press)
            @test length(ctrl.undo_stack) == 1
            # pretend the previous step happened more than 1 s ago
            ctrl.last_key_step = (obj = m1, key = Keyboard.up, time = ctrl.last_key_step.time - 2.0)
            events(scene).keyboardbutton[] = Makie.KeyEvent(Keyboard.up, Keyboard.press)
            @test length(ctrl.undo_stack) == 2 # not merged: a separate entry
            close(ctrl)
            close(ctrl)
        end

        @testset "undo/redo of a reset" begin
            fig, ax, h, m1, m2 = _fixture()
            scene = ax.scene
            pick_m1 = ax2 -> (render_plots(render_children(h)[1])[1], 0)
            ctrl = GUI.kinematic_controls!(ax, h; throttle = false, pick = pick_m1, fine_step = 1e-3)
            events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.press)
            events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.release)
            P0 = collect(Float64.(BMO.position(m1)))
            events(scene).keyboardbutton[] = Makie.KeyEvent(Keyboard.up, Keyboard.press)
            events(scene).keyboardbutton[] = Makie.KeyEvent(Keyboard.backspace, Keyboard.press)
            @test isapprox(collect(Float64.(BMO.position(m1))), P0; atol = 1e-9)
            @test length(ctrl.undo_stack) == 2 # the key step, then the reset

            _ctrl_z!(scene) # undo the reset
            @test !isapprox(collect(Float64.(BMO.position(m1))), P0; atol = 1e-9)
            _ctrl_z!(scene) # undo the key step
            @test isapprox(collect(Float64.(BMO.position(m1))), P0; atol = 1e-9)
            @test isempty(ctrl.undo_stack)
            close(ctrl)
        end

        @testset "a new gesture clears the redo stack" begin
            fig, ax, h, m1, m2 = _fixture()
            scene = ax.scene
            pick_m1 = ax2 -> (render_plots(render_children(h)[1])[1], 0)
            ctrl = GUI.kinematic_controls!(ax, h; throttle = false, pick = pick_m1, fine_step = 1e-3)
            events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.press)
            events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.release)
            events(scene).keyboardbutton[] = Makie.KeyEvent(Keyboard.up, Keyboard.press)
            _ctrl_z!(scene)
            @test length(ctrl.redo_stack) == 1
            events(scene).keyboardbutton[] = Makie.KeyEvent(Keyboard.up, Keyboard.press)
            @test isempty(ctrl.redo_stack)
            close(ctrl)
        end

        @testset "spectator mode ignores undo" begin
            fig, ax, h, m1, m2 = _fixture()
            scene = ax.scene
            pick_m1 = ax2 -> (render_plots(render_children(h)[1])[1], 0)
            ctrl = GUI.kinematic_controls!(ax, h; throttle = false, pick = pick_m1, fine_step = 1e-3)
            events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.press)
            events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.release)
            events(scene).keyboardbutton[] = Makie.KeyEvent(Keyboard.up, Keyboard.press)
            P1 = collect(Float64.(BMO.position(m1)))
            @test length(ctrl.undo_stack) == 1
            events(scene).keyboardbutton[] = Makie.KeyEvent(Keyboard.v, Keyboard.press) # spectator on
            @test ctrl.spectator[]
            _ctrl_z!(scene)
            @test collect(Float64.(BMO.position(m1))) == P1 # unaffected
            @test length(ctrl.undo_stack) == 1 # nothing popped
            close(ctrl)
        end

        @testset "_undo!/_redo! return whether something happened" begin
            fig, ax, h, m1, m2 = _fixture()
            ctrl = GUI.kinematic_controls!(ax, h; throttle = false)
            @test GUI._undo!(ctrl) == false
            @test GUI._redo!(ctrl) == false
            close(ctrl)
        end
    end

    @testset "constraints" begin
        @testset "validates axis and field names" begin
            fig, ax, h, m1, m2 = _fixture()
            @test_throws ArgumentError GUI.kinematic_controls!(
                ax, h; constraints = Dict(m1 => (; move = (:q,))))
            @test_throws ArgumentError GUI.kinematic_controls!(
                ax, h; constraints = Dict(m1 => (; spin = (:x,))))
            close(GUI.kinematic_controls!(ax, h; constraints = Dict(m1 => (; move = (:x, :y)))))
        end

        @testset "locked keys are consumed without moving" begin
            fig, ax, h, m1, m2 = _fixture()
            scene = ax.scene
            pick_m1 = ax2 -> (render_plots(render_children(h)[1])[1], 0)
            ctrl = GUI.kinematic_controls!(ax, h; throttle = false, pick = pick_m1, fine_step = 1e-3,
                constraints = Dict(m1 => (; move = (:x,))))
            events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.press)
            events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.release)
            @test ctrl.selected[] === m1
            P0 = collect(Float64.(BMO.position(m1)))
            # up moves along the (locked) y-axis
            events(scene).keyboardbutton[] = Makie.KeyEvent(Keyboard.up, Keyboard.press)
            @test collect(Float64.(BMO.position(m1))) == P0
            @test isempty(ctrl.undo_stack)
            # right moves along the (allowed) x-axis
            events(scene).keyboardbutton[] = Makie.KeyEvent(Keyboard.right, Keyboard.press)
            @test collect(Float64.(BMO.position(m1))) != P0
            close(ctrl)
        end

        @testset "mouse drag projects onto the allowed move axis" begin
            fig, ax, h, m1, m2 = _fixture()
            scene = ax.scene
            pick_m1 = ax2 -> (render_plots(render_children(h)[1])[1], 0)
            ctrl = GUI.kinematic_controls!(ax, h; throttle = false, pick = pick_m1,
                constraints = Dict(m1 => (; move = (:x,))))
            events(scene).mouseposition[] = (100.0, 100.0)
            events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.press)
            events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.release)
            @test ctrl.selected[] === m1
            P0 = collect(Float64.(BMO.position(m1)))
            events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.press)
            events(scene).mouseposition[] = (140.0, 160.0) # diagonal drag
            events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.release)
            d = collect(Float64.(BMO.position(m1))) .- P0
            # motion is only along local x = [1, 0, 0] (mirror is unrotated)
            @test isapprox(d[2], 0.0; atol = 1e-9)
            @test isapprox(d[3], 0.0; atol = 1e-9)
            close(ctrl)
        end

        @testset "no allowed move axis: drag does not move the object" begin
            fig, ax, h, m1, m2 = _fixture()
            scene = ax.scene
            pick_m1 = ax2 -> (render_plots(render_children(h)[1])[1], 0)
            ctrl = GUI.kinematic_controls!(ax, h; throttle = false, pick = pick_m1,
                constraints = Dict(m1 => (; move = ())))
            events(scene).mouseposition[] = (100.0, 100.0)
            events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.press)
            events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.release)
            P0 = collect(Float64.(BMO.position(m1)))
            events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.press)
            events(scene).mouseposition[] = (140.0, 160.0)
            events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.release)
            @test collect(Float64.(BMO.position(m1))) == P0
            close(ctrl)
        end

        @testset "rotate drag is blocked when :v is locked" begin
            fig, ax, h, m1, m2 = _fixture()
            scene = ax.scene
            pick_m1 = ax2 -> (render_plots(render_children(h)[1])[1], 0)
            ctrl = GUI.kinematic_controls!(ax, h; throttle = false, pick = pick_m1, mode = :rotate,
                rotate_speed = 1e-2, constraints = Dict(m1 => (; rotate = (:x,))))
            R0 = Matrix{Float64}(BMO.orientation(m1))
            events(scene).mouseposition[] = (100.0, 100.0)
            events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.press)
            events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.release)
            @test ctrl.selected[] === m1
            events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.press)
            events(scene).mouseposition[] = (110.0, 100.0)
            events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.release)
            @test Matrix{Float64}(BMO.orientation(m1)) ≈ R0 # :v (rotation_axis) is locked
            close(ctrl)
        end

        @testset "gizmo colors fade for locked axes" begin
            fig, ax, h, m1, m2 = _fixture()
            scene = ax.scene
            pick_m1 = ax2 -> (render_plots(render_children(h)[1])[1], 0)
            ctrl = GUI.kinematic_controls!(ax, h; throttle = false, pick = pick_m1,
                constraints = Dict(m1 => (; move = (:x,))))
            events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.press)
            events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.release)
            # order is [y, x, v]: y locked, x allowed, v locked
            @test ctrl.arrow_color[][1].alpha ≈ GUI._GIZMO_FADE_ALPHA
            @test ctrl.arrow_color[][2].alpha ≈ 1.0
            @test ctrl.arrow_color[][3].alpha ≈ GUI._GIZMO_FADE_ALPHA
            close(ctrl)
        end
    end

    @testset "grab point" begin
        @testset "drag keeps the grabbed point under the cursor" begin
            fig, ax, h, m1, m2 = _fixture()
            scene = ax.scene
            vp = scene.viewport[]
            cx, cy = vp.origin[1] + vp.widths[1] / 2, vp.origin[2] + vp.widths[2] / 2
            ctrl = GUI.kinematic_controls!(ax, h; throttle = false) # default ray picking: t is known
            events(scene).mouseposition[] = (cx, cy)
            events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.press)
            events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.release)
            @test ctrl.selected[] === m1

            events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.press)
            leaf, t = GUI._ray_pick(ctrl, scene)
            @test leaf === m1
            @test !isnothing(t)
            r0 = Makie.ray_at_cursor(scene)
            hit0 = Vector{Float64}(r0.origin) .+ t .* Vector{Float64}(r0.direction)
            @test isapprox(ctrl.plane_point, hit0; atol = 1e-9) # plane through the hit, not the pivot
            grab_offset = copy(ctrl.grab_offset)
            @test isapprox(collect(Float64.(BMO.position(m1))) .- grab_offset, hit0; atol = 1e-9)

            events(scene).mouseposition[] = (cx + 30, cy + 15)
            r1 = Makie.ray_at_cursor(scene)
            hit1 = GUI._ray_plane_intersect(Vector{Float64}(r1.origin), Vector{Float64}(r1.direction),
                ctrl.plane_point, GUI._drag_normal(scene, ctrl))
            # the grabbed point (position - grab_offset) is still exactly the new plane hit
            @test isapprox(collect(Float64.(BMO.position(m1))) .- grab_offset, hit1; atol = 1e-9)
            events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.release)
            close(ctrl)
        end

        @testset "custom pick falls back to the pivot" begin
            fig, ax, h, m1, m2 = _fixture()
            scene = ax.scene
            pick_m1 = ax2 -> (render_plots(render_children(h)[1])[1], 0)
            ctrl = GUI.kinematic_controls!(ax, h; throttle = false, pick = pick_m1)
            events(scene).mouseposition[] = (100.0, 100.0)
            events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.press)
            events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.release)
            events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.press)
            @test isapprox(ctrl.plane_point, collect(Float64.(BMO.position(m1))); atol = 1e-9)
            events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.release)
            close(ctrl)
        end
    end

    @testset "drag on a ring rotates around it" begin
        _press!(scene, pos) = (events(scene).mouseposition[] = pos;
                                events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.press))
        _move!(scene, pos) = (events(scene).mouseposition[] = pos)
        _release!(scene) = (events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.release))
        # Position [px of the window] of the vertex `j` (1:_RING_RES + 1) of the ring `i` (1:3, in
        # the order `_AXES_SYMS`) of the gizmo, which is at the angle (j - 1) / 32 * 3π/2 on it
        function _vertex_px(ctrl, scene, i, j)
            n = 2 * GUI._RING_RES
            p = j <= GUI._RING_RES ? ctrl.ring_pts[][(i - 1) * n + 2j - 1] : ctrl.ring_pts[][(i - 1) * n + n]
            q = Makie.project(scene, :data, :pixel, Point3(p))
            o = scene.viewport[].origin
            return (Float64(q[1] + o[1]), Float64(q[2] + o[2]))
        end
        _Δθ(j1, j2) = (j2 - j1) / GUI._RING_RES * 1.5π
        function _setup(; constraints = m1 -> Dict(), kwargs...)
            fig, ax, h, m1, m2 = _fixture()
            scene = ax.scene
            pick_m1 = ax2 -> (render_plots(render_children(h)[1])[1], 0)
            ctrl = GUI.kinematic_controls!(ax, h; throttle = false, pick = pick_m1, mode = :rotate,
                rotate_speed = 1e-2, constraints = constraints(m1), kwargs...)
            for key in (haskey(kwargs, :select_modifier) ? (kwargs[:select_modifier],) : ())
                push!(events(scene).keyboardstate, key)
            end
            events(scene).mouseposition[] = (100.0, 100.0)
            events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.press)
            events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.release)
            @test ctrl.selected[] === m1
            # close to the gizmo, which stands above the mirror, such that its rings are large
            Makie.update_cam!(scene, Vec3d(0.12, -0.14, 0.15), Vec3d(0, 0, 0.06), Vec3d(0, 0, 1))
            return ctrl, scene, m1
        end

        @testset "the angle follows the cursor around each ring" begin
            for (i, sym) in enumerate(GUI._AXES_SYMS)
                ctrl, scene, m1 = _setup()
                R0 = Matrix{Float64}(BMO.orientation(m1))
                P0 = collect(Float64.(BMO.position(m1)))
                axis = only(GUI._axis_vectors(ctrl, m1, (sym,)))
                a, b = _vertex_px(ctrl, scene, i, 4), _vertex_px(ctrl, scene, i, 12)
                events(scene).mouseposition[] = a
                @test first(GUI._pick_ring(ctrl, scene)) === sym
                _press!(scene, a)
                @test ctrl.press_kind == :pending_ring
                _move!(scene, b)
                @test ctrl.dragging
                @test Matrix{Float64}(BMO.orientation(m1)) ≈ BMO.rotate3d(axis, _Δθ(4, 12)) * R0 atol = 1e-4
                @test collect(Float64.(BMO.position(m1))) ≈ P0
                _release!(scene)
                @test !ctrl.dragging
                @test length(ctrl.undo_stack) == 1
                @test ctrl.selected[] === m1
                e = only(ctrl.undo_stack)
                @test e.obj === m1 && e.R0 ≈ R0 && e.R1 ≈ Matrix{Float64}(BMO.orientation(m1))
                @test GUI._undo!(ctrl)
                @test Matrix{Float64}(BMO.orientation(m1)) ≈ R0
                close(ctrl)
            end
        end

        @testset "a click on a ring does nothing, the ring under the cursor is highlighted" begin
            ctrl, scene, m1 = _setup()
            R0 = Matrix{Float64}(BMO.orientation(m1))
            a = _vertex_px(ctrl, scene, 2, 8)
            _move!(scene, a)
            @test ctrl.ring_hover === :x
            @test ctrl.ring_color[][2 * GUI._RING_RES + 1].r > 0.9 # the red ring is brighter
            _press!(scene, a)
            _release!(scene)
            @test ctrl.selected[] === m1
            @test Matrix{Float64}(BMO.orientation(m1)) ≈ R0
            @test isempty(ctrl.undo_stack)
            _move!(scene, (1.0, 1.0))
            @test isnothing(ctrl.ring_hover)
            close(ctrl)
        end

        @testset "a ring seen edge-on follows the movement along it" begin
            ctrl, scene, m1 = _setup()
            # view along the table: the plane of the blue ring is seen edge-on
            Makie.update_cam!(scene, Vec3d(0, -1, 0), Vec3d(0, 0, 0), Vec3d(0, 0, 1))
            GUI._update_selection_box!(ctrl)
            R0 = Matrix{Float64}(BMO.orientation(m1))
            @test isnothing(GUI._ring_angle(scene, ctrl.gizmo_origin, [0.0, 0, 1]))
            a = _vertex_px(ctrl, scene, 3, 8)
            events(scene).mouseposition[] = a
            ring = GUI._pick_ring(ctrl, scene)
            @test first(ring) === :v
            _press!(scene, a)
            _move!(scene, a .+ (20.0, 0.0))
            _release!(scene)
            expected = 1e-2 * 20 * ring[2][1]
            @test abs(expected) > 0.05
            @test Matrix{Float64}(BMO.orientation(m1)) ≈ BMO.rotate3d([0, 0, 1], expected) * R0 atol = 1e-6
            close(ctrl)
        end

        @testset "locked rings can not be dragged" begin
            # only the red ring is unlocked: the green and the blue one are faded
            ctrl, scene, m1 = _setup(constraints = m -> Dict(m => (; rotate = (:x,))))
            R0 = Matrix{Float64}(BMO.orientation(m1))
            @test ctrl.ring_color[][1].alpha ≈ GUI._GIZMO_FADE_ALPHA
            for i in (1, 3)
                a = _vertex_px(ctrl, scene, i, 6)
                events(scene).mouseposition[] = a
                @test first(something(GUI._pick_ring(ctrl, scene), (nothing,))) in (nothing, :x)
                _press!(scene, a)
                _move!(scene, a .+ (30.0, 10.0))
                _release!(scene)
                # a drag on a locked ring starts no ring drag, and :v is locked, too
                @test Matrix{Float64}(BMO.orientation(m1)) ≈ R0
                @test isempty(ctrl.undo_stack)
            end
            # the red ring still works
            axis = only(GUI._axis_vectors(ctrl, m1, (:x,)))
            _press!(scene, _vertex_px(ctrl, scene, 2, 4))
            _move!(scene, _vertex_px(ctrl, scene, 2, 10))
            _release!(scene)
            @test Matrix{Float64}(BMO.orientation(m1)) ≈ BMO.rotate3d(axis, _Δθ(4, 10)) * R0 atol = 1e-4
            close(ctrl)
        end

        @testset "off the rings the drag rotates around the rotation axis" begin
            ctrl, scene, m1 = _setup()
            R0 = Matrix{Float64}(BMO.orientation(m1))
            _press!(scene, (100.0, 100.0))
            @test ctrl.press_kind == :pending_drag
            _move!(scene, (110.0, 100.0))
            _release!(scene)
            @test Matrix{Float64}(BMO.orientation(m1)) ≈ BMO.rotate3d([0, 0, 1], 0.1) * R0
            close(ctrl)
        end

        @testset "select_modifier and the spectator mode" begin
            ctrl, scene, m1 = _setup(select_modifier = Keyboard.left_shift)
            R0 = Matrix{Float64}(BMO.orientation(m1))
            a, b = _vertex_px(ctrl, scene, 2, 4), _vertex_px(ctrl, scene, 2, 10)
            # without the modifier the press goes to the camera and nothing is highlighted
            delete!(events(scene).keyboardstate, Keyboard.left_shift)
            _move!(scene, a)
            @test isnothing(ctrl.ring_hover)
            _press!(scene, a)
            @test ctrl.press_kind == :none
            _move!(scene, b)
            _release!(scene)
            @test Matrix{Float64}(BMO.orientation(m1)) ≈ R0
            # with it, the ring is dragged
            push!(events(scene).keyboardstate, Keyboard.left_shift)
            _press!(scene, a)
            _move!(scene, b)
            _release!(scene)
            @test !(Matrix{Float64}(BMO.orientation(m1)) ≈ R0)
            close(ctrl)

            # nothing is selected in the spectator mode, which has no rings
            ctrl, scene, m1 = _setup()
            GUI._set_spectator!(ctrl, true)
            R0 = Matrix{Float64}(BMO.orientation(m1))
            _press!(scene, (100.0, 100.0))
            _move!(scene, (140.0, 100.0))
            _release!(scene)
            @test isnothing(GUI._pick_ring(ctrl, scene))
            @test Matrix{Float64}(BMO.orientation(m1)) ≈ R0
            close(ctrl)
        end
    end

    @testset "drag in the plane of the view" begin
        # Selects m1 at the center of the view (the camera looks at it) and drags it by `d` px.
        # Returns its displacement, the direction of the view and the distance [px] between the
        # cursor and the grabbed point after the drag. `move` are the axes it may move along
        function dragged(eye, up; ortho = false, d = (40.0, 25.0), move = nothing, tilt = 0.0, kwargs...)
            fig, ax, h, m1, m2 = _fixture()
            # the local x-axis along -z for a quarter turn, see `_control_axes`
            if tilt != 0
                BMO.yrotate3d!(m1, tilt)
                GUI.update_render!(h)
            end
            scene = ax.scene
            cam = Makie.cameracontrols(scene)
            ortho && (cam.settings.projectiontype[] = Makie.Orthographic)
            Makie.update_cam!(scene, Vec3d(eye), Vec3d(0, 0, 0), Vec3d(up))
            vp = scene.viewport[]
            c = (vp.origin[1] + vp.widths[1] / 2, vp.origin[2] + vp.widths[2] / 2)
            constraints = isnothing(move) ? Dict() : Dict(m1 => (; move))
            ctrl = GUI.kinematic_controls!(ax, h; throttle = false, constraints, kwargs...)
            ev = events(scene)
            ev.mouseposition[] = c
            ev.mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.press)
            ev.mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.release)
            @test ctrl.selected[] === m1
            P0 = collect(Float64.(BMO.position(m1)))
            ev.mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.press)
            grabbed = P0 .- ctrl.grab_offset
            ev.mouseposition[] = c .+ d
            n = GUI._view_direction(scene)
            Δ = collect(Float64.(BMO.position(m1))) .- P0
            px = Makie.project(scene, :data, :pixel, Point3d((grabbed .+ Δ)...))
            ev.mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.release)
            miss = hypot(px[1] - (c[1] + d[1] - vp.origin[1]), px[2] - (c[2] + d[2] - vp.origin[2]))
            close(ctrl)
            return Δ, n, miss
        end

        @testset "$name, ortho = $ortho" for (name, eye, up) in (
                    ("oblique", [0.3, -0.4, 0.25], [0, 0, 1]),
                    ("front", [0.0, -0.5, 0.0], [0, 0, 1]),
                    ("side", [-0.5, 0.0, 0.0], [0, 0, 1]),
                    ("top", [0.0, 0.0, 0.5], [0, 1, 0])),
                ortho in (false, true)
            Δ, n, miss = dragged(eye, up; ortho)
            @test n ≈ -normalize(Float64.(eye))
            # it moved, within the plane of the view, and the grabbed point is under the cursor
            @test norm(Δ) > 1e-4
            @test abs(dot(Δ, n)) < 1e-9
            @test miss < 0.5
        end

        # from the front, a drag to the right and upwards changes x and z, not y
        Δ, n, _ = dragged([0.0, -0.5, 0.0], [0, 0, 1]; ortho = true)
        @test Δ[1] > 1e-4 && Δ[3] > 1e-4 && abs(Δ[2]) < 1e-12
        # from above, with y upwards on the screen, x and y, not z
        Δ, n, _ = dragged([0.0, 0.0, 0.5], [0, 1, 0]; ortho = true)
        @test Δ[1] > 1e-4 && Δ[2] > 1e-4 && abs(Δ[3]) < 1e-12

        # ... also if a local axis of the object is parallel to the rotation axis, e.g. the local
        # x-axis of a beam group along +y: it still moves sideways
        Δ, n, miss = dragged([0.0, 0.0, 0.5], [0, 1, 0]; ortho = true, tilt = π / 2)
        @test Δ[1] > 1e-4 && Δ[2] > 1e-4 && abs(Δ[3]) < 1e-12
        @test miss < 0.5

        # a `plane_normal` keeps the plane, whatever the view: here the height
        Δ, n, miss = dragged([0.3, -0.4, 0.25], [0, 0, 1]; plane_normal = [0, 0, 1])
        @test norm(Δ) > 1e-4 && abs(Δ[3]) < 1e-12 && abs(dot(Δ, n)) > 1e-5
        @test miss < 0.5
        # parallel to that plane, i.e. from the front, nothing moves
        Δ, _, _ = dragged([0.0, -0.5, 0.0], [0, 0, 1]; ortho = true, plane_normal = [0, 0, 1])
        @test norm(Δ) < 1e-12

        # locked axes stay locked: only along the local x-axis of the mirror, the world x-axis
        Δ, _, _ = dragged([0.3, -0.4, 0.25], [0, 0, 1])
        @test norm(cross(Δ, [1.0, 0, 0])) > 1e-5
        Δ, _, _ = dragged([0.3, -0.4, 0.25], [0, 0, 1]; move = (:x,))
        @test abs(Δ[1]) > 1e-4 && norm(cross(Δ, [1.0, 0, 0])) < 1e-12
        Δ, _, _ = dragged([0.3, -0.4, 0.25], [0, 0, 1]; move = ())
        @test norm(Δ) < 1e-12
    end

    @testset "screen-space picking of sources" begin
        fig, ax, h, m1, m2 = _fixture()
        scene = ax.scene
        beam = Beam([0.0, -1.0, 2.0], [0.0, 1.0, 0.0]) # away from m1/m2
        src_handle = GUI._live_render_source!(ax, beam; size = 1e-3) # tiny marker
        push!(h, src_handle)
        ctrl = GUI.kinematic_controls!(ax, h; throttle = false)
        @test any(o -> o === beam, ctrl.movable)

        p = Vector{Float64}(BMO.position(beam))
        px = Makie.project(scene, :data, :pixel, Point3(p))
        vp = scene.viewport[]

        # a few pixels off the tiny marker: within source_pick_radius, but outside its 3D bbox
        events(scene).mouseposition[] = (px[1] + vp.origin[1] + 10, px[2] + vp.origin[2] + 10)
        leaf, t = GUI._ray_pick(ctrl, scene)
        @test leaf === beam
        @test !isnothing(t)

        # far outside source_pick_radius: no longer picked
        events(scene).mouseposition[] = (px[1] + vp.origin[1] + 100, px[2] + vp.origin[2] + 100)
        leaf2, _ = GUI._ray_pick(ctrl, scene)
        @test leaf2 !== beam
        close(ctrl)
    end

    @testset "ignore_keys disables all key handling" begin
        fig, ax, h, m1, m2 = _fixture()
        scene = ax.scene
        pick_m1 = ax2 -> (render_plots(render_children(h)[1])[1], 0)
        ignore = Ref(false)
        ctrl = GUI.kinematic_controls!(ax, h; throttle = false, pick = pick_m1, fine_step = 1e-3,
            ignore_keys = () -> ignore[])
        events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.press)
        events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.release)
        @test ctrl.selected[] === m1

        ignore[] = true
        probe = Any[]
        on(events(scene).keyboardbutton, priority = -1000) do event
            push!(probe, event.key)
            return Consume(false)
        end
        P0 = collect(Float64.(BMO.position(m1)))
        events(scene).keyboardbutton[] = Makie.KeyEvent(Keyboard.up, Keyboard.press)
        @test collect(Float64.(BMO.position(m1))) == P0 # not moved
        @test probe == [Keyboard.up] # passed through to lower-priority listeners
        events(scene).keyboardbutton[] = Makie.KeyEvent(Keyboard.v, Keyboard.press)
        @test !ctrl.spectator[] # v not handled either
        events(scene).unicode_input[] = '+'
        @test ctrl.fine_step == 1e-3 # not changed

        ignore[] = false
        events(scene).keyboardbutton[] = Makie.KeyEvent(Keyboard.up, Keyboard.press)
        @test collect(Float64.(BMO.position(m1))) != P0 # works again
        close(ctrl)
    end
end

end # module
