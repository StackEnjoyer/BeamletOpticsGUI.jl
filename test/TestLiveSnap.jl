module TestLiveSnap

using GLMakie, BeamletOptics, BeamletOpticsGUI
using Makie
using LinearAlgebra: I, norm, dot, normalize
using Test

const BMO = BeamletOptics
const GUI = BeamletOpticsGUI

@testset "Snapping onto beams" begin
    y = [0.0, 1, 0]
    z = [0.0, 0, 1]

    # Beam A along +y onto a mirror at 45° at y = 0.3, beam B along -y beside it, and a lens beside
    # beam A at y = 0.1
    function _fixture(; lens_at = [0.03, 0.1, 0.0], lens_angle = 0.0, kwargs...)
        m = RoundPlanoMirror(25e-3, 5e-3)
        zrotate3d!(m, deg2rad(45))
        translate3d!(m, [0, 0.3, 0])
        lens = SphericalLens(0.05, -0.05, 0.01, 0.02)
        zrotate3d!(lens, lens_angle)
        translate_to3d!(lens, lens_at)
        sys = System([m, lens])
        a = Beam([0.0, 0, 0], [0.0, 1, 0], 1e-6)
        b = Beam([-0.05, 0.4, 0], [0.0, -1, 0], 1e-6)
        gui = live_view(sys => a, sys => b; trace_budget = Inf, throttle = false, kwargs...)
        set_view(gui.ax, [0.25, -0.2, 0.5], [0.0, 0.15, 0.0], [0.0, 0, 1])
        return gui, sys, m, lens, a
    end

    _pose(obj) = (collect(Float64, position(obj)), Matrix{Float64}(BMO.orientation(obj)))
    # The pixel of the 3D `point` in the figure
    function _pixel(gui, point)
        scene = gui.ax.scene
        p = Makie.project(scene, :data, :pixel, Point3f(point))[Vec(1, 2)]
        return Point2f(Makie.viewport(scene)[].origin) .+ p
    end
    _mouse!(gui, px) = (events(gui.ax.scene).mouseposition[] = (Float64(px[1]), Float64(px[2])))
    _press!(gui) = (events(gui.ax.scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.press))
    _release!(gui) = (events(gui.ax.scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.release))
    _key!(gui, key, action = Keyboard.press) =
        (events(gui.ax.scene).keyboardbutton[] = Makie.KeyEvent(key, action))
    # The distance [px] of the `point` from the line through `a` along `dir` on the screen
    function _px_distance(gui, point, a, dir)
        p, q = _pixel(gui, point), _pixel(gui, a)
        t = normalize(_pixel(gui, a .+ 0.1 .* dir) .- q)
        return abs((p[1] - q[1]) * t[2] - (p[2] - q[2]) * t[1])
    end

    # Grabs the selected `obj` at its position and moves the mouse by the pixels `by`, in steps;
    # the button stays pressed
    function _grab!(gui, obj, by; steps = 4)
        gui.controls.selected[] = obj
        p0 = _pixel(gui, position(obj))
        _mouse!(gui, p0)
        _press!(gui)
        foreach(k -> _mouse!(gui, p0 .+ (k / steps) .* Point2f(by)), 1:steps)
        return nothing
    end
    _drag!(gui, obj, by; kwargs...) = (_grab!(gui, obj, by; kwargs...); _release!(gui))

    # The pixels from the position of `obj` to the 3D `point`
    _to(gui, obj, point) = _pixel(gui, point) .- _pixel(gui, position(obj))

    @testset "angles" begin
        # the signed angle about the axis from the beam to the optical axis
        @test GUI._angle_about(z, y, y) ≈ 0 atol = 1e-12
        @test GUI._angle_about(z, y, [-1.0, 0, 0]) ≈ π / 2
        @test GUI._angle_about(z, y, [1.0, 0, 0]) ≈ -π / 2
        @test GUI._angle_about(z, y, [0.0, 1, 5]) ≈ 0 atol = 1e-12
        @test isnothing(GUI._angle_about(z, z, y)) && isnothing(GUI._angle_about(z, y, z))
        # within 3° of a multiple of 45° to the beam: the angle that reaches it
        step, tol = GUI._SNAP_ANGLE_STEP, GUI._SNAP_ANGLE_TOLERANCE
        @test step ≈ π / 4 && tol ≈ deg2rad(3)
        @test GUI._snap_angle(deg2rad(2), 0.0) == 0.0
        @test GUI._snap_angle(deg2rad(-2.9), 0.0) == 0.0
        @test GUI._snap_angle(deg2rad(3.5), 0.0) == deg2rad(3.5)
        @test GUI._snap_angle(deg2rad(44), 0.0) ≈ π / 4
        @test GUI._snap_angle(deg2rad(-91), 0.0) ≈ -π / 2
        # relative to the angle at the start of the drag
        @test GUI._snap_angle(deg2rad(-9), deg2rad(10)) ≈ deg2rad(-10)
        @test GUI._snap_angle(deg2rad(36), deg2rad(10)) ≈ deg2rad(35)
        @test GUI._snap_angle(deg2rad(20), deg2rad(10)) == deg2rad(20)
        # without a beam
        @test GUI._snap_angle(0.3, nothing) === 0.3
    end

    @testset "lines of the beams" begin
        gui, sys, m, lens, a = _fixture()
        ctrl = gui.controls
        flen = Float64(BMO.render_settings(first(gui.beam_handles)).flen)
        on_a(l) = abs(l.a[1]) < 1e-9 && abs(l.b[1]) < 1e-9
        # the lens beside the beams: all segments, also the reflected one
        lines = GUI._snap_lines(gui, lens)
        @test length(lines) == 3
        @test count(l -> abs(l.direction[1]) ≈ 1, lines) == 1
        @test all(l -> l.direction ≈ (l.b .- l.a) ./ norm(l.b .- l.a), lines)
        # the mirror: the beam that reaches it, continued behind it, without the reflected beam
        lines = GUI._snap_lines(gui, m)
        @test length(lines) == 2 && all(l -> abs(l.direction[2]) ≈ 1, lines)
        la = only(filter(on_a, lines))
        @test la.a ≈ [0.0, 0, 0] atol = 1e-12
        @test la.b[2] ≈ norm(position(m)) + flen rtol = 0.05
        # the lens in the beam: only the ray that reaches it; the mirror: the rays through the lens
        translate_to3d!(lens, [0, 0.1, 0])
        GUI.retrace!(gui)
        lines = filter(on_a, GUI._snap_lines(gui, lens))
        @test length(lines) == 1 && only(lines).b[2] > 0.1 + 0.5 * flen
        lines = filter(on_a, GUI._snap_lines(gui, m))
        @test length(lines) == 3 && lines[end].b[2] > 0.3 + 0.5 * flen
        @test sum(l -> norm(l.b .- l.a), lines[1:2]) < 0.12
        # a beam that is switched off has no lines
        GUI._set_beam_on!(gui, a, false)
        @test isempty(filter(on_a, GUI._snap_lines(gui, lens)))
        # sources and clip planes do not snap
        @test isnothing(ctrl.snap_beam(a, [0.0, 0.1, 0]))
        close(gui)

        # a lens of several parts counts as a whole
        doublet = SphericalDoubletLens(62.8e-3, -45.7e-3, -128.2e-3, 4e-3, 2.5e-3, 25.4e-3, 1.5, 1.6)
        translate_to3d!(doublet, [0, 0.1, 0])
        gui = live_view(System([doublet]) => Beam([0.0, 0, 0], [0.0, 1, 0], 1e-6); trace_budget = Inf)
        lines = GUI._snap_lines(gui, doublet)
        @test length(lines) == 1 && only(lines).direction ≈ y
        close(gui)
    end

    @testset "point on a line" begin
        gui, sys, m, lens, a = _fixture()
        scene = gui.ax.scene
        lines = GUI._snap_lines(gui, lens)
        # a point 4 mm beside beam A: the point of the beam that is seen next to it, with the
        # direction of the beam
        s = GUI._snap_point(scene, lines, [0.004, 0.12, 0.0]; radius = 1e3)
        @test abs(s.point[1]) < 1e-12 && abs(s.point[3]) < 1e-12
        @test s.point[2] ≈ 0.12 atol = 3e-3
        @test s.direction ≈ y
        d = _px_distance(gui, [0.004, 0.12, 0.0], [0.0, 0, 0], y)
        @test norm(_pixel(gui, s.point) .- _pixel(gui, [0.004, 0.12, 0.0])) ≈ d atol = 0.5
        # a point above the table that is seen on the beam: the point of the beam behind it, not
        # the one closest in space
        eye = Vector{Float64}(Makie.cameracontrols(scene).eyeposition[])
        above = eye .+ 0.8 .* ([0.0, 0.2, 0] .- eye)
        @test above[3] > 0.05
        s = GUI._snap_point(scene, lines, above)
        @test s.point ≈ [0.0, 0.2, 0] atol = 1e-9
        @test abs(above[2] - 0.2) > 0.02
        # the same in an orthographic view from above: the foot on the beam
        GUI._sight_line(scene, above) # perspective: from the eye
        @test GUI._sight_line(scene, above)[1] ≈ eye
        # only within the radius on the screen
        d = _px_distance(gui, [0.004, 0.12, 0.0], [0.0, 0, 0], y)
        @test !isnothing(GUI._snap_point(scene, lines, [0.004, 0.12, 0.0]; radius = d + 1))
        @test isnothing(GUI._snap_point(scene, lines, [0.004, 0.12, 0.0]; radius = d - 1))
        # the closest line: beam B at x = -0.05
        @test GUI._snap_point(scene, lines, [-0.048, 0.2, 0.0]; radius = 1e3).point ≈ [-0.05, 0.2, 0] atol = 3e-3
        @test GUI._snap_point(scene, lines, [-0.048, 0.2, 0.0]; radius = 1e3).point[1] ≈ -0.05 atol = 1e-12
        # behind the end of a line: its end
        s = GUI._snap_point(scene, lines, [0.001, -0.01, 0.0]; radius = 1e3)
        @test s.point ≈ [0.0, 0, 0] atol = 1e-12
        # orthographic, from above: the line of sight is the direction of the view, the point of
        # the beam is the foot of the point
        Makie.cameracontrols(scene).settings.projectiontype[] = Makie.Orthographic
        set_view(gui.ax, [0.0, 0.15, 0.5], [0.0, 0.15, 0.0], [0.0, 1, 0])
        o, dir = GUI._sight_line(scene, [0.004, 0.12, 0.03])
        @test o ≈ [0.004, 0.12, 0.03] && dir ≈ [0.0, 0, -1]
        s = GUI._snap_point(scene, lines, [0.004, 0.12, 0.03]; radius = 1e3)
        @test s.point ≈ [0.0, 0.12, 0] atol = 1e-9
        close(gui)
    end

    @testset "move ($layout)" for layout in (:compact, :app)
        gui, sys, m, lens, a = _fixture(; layout)
        ctrl = gui.controls
        P0, R0 = _pose(lens)
        near = [0.003, 0.12, 0.0]
        far = [0.02, 0.12, 0.0]
        by_near, by_far = _to(gui, lens, near), _to(gui, lens, far)

        # snap off: the lens follows the mouse, in the plane of the view
        @test ctrl.snap[] == :off
        _drag!(gui, lens, by_near)
        free = _pose(lens)[1]
        @test abs(free[1]) > 1e-4 && _pose(lens)[2] == R0
        @test norm(_pixel(gui, free) .- _pixel(gui, near)) < 0.5
        @test abs(dot(free .- P0, GUI._view_direction(gui.ax.scene))) < 1e-9
        @test _px_distance(gui, free, [0.0, 0, 0], y) < GUI._SNAP_RADIUS
        GUI._undo!(ctrl)
        @test _pose(lens)[1] ≈ P0

        # snap on: within 12 px of the beam, the lens sits on the beam, in its orientation
        GUI._set_snap!(ctrl, :position)
        n = length(ctrl.undo_stack)
        _drag!(gui, lens, by_near)
        P, R = _pose(lens)
        @test abs(P[1]) < 1e-9 && abs(P[3]) < 1e-9
        # where the beam is seen next to the mouse, not where it is closest in space
        @test norm(_pixel(gui, P) .- _pixel(gui, free)) < GUI._SNAP_RADIUS
        @test P[2] ≈ near[2] atol = 2e-3
        @test R == R0
        # one gesture of the history
        @test length(ctrl.undo_stack) == n + 1
        GUI._undo!(ctrl)
        @test _pose(lens)[1] ≈ P0 && _pose(lens)[2] ≈ R0
        # beside the beam it follows the mouse
        _drag!(gui, lens, by_far)
        @test _px_distance(gui, _pose(lens)[1], [0.0, 0, 0], y) > GUI._SNAP_RADIUS
        @test abs(_pose(lens)[1][1]) > 5e-3
        GUI._undo!(ctrl)

        # on the beam, the lens slides along it, and leaves it again
        _grab!(gui, lens, by_near)
        @test abs(_pose(lens)[1][1]) < 1e-9
        p = _pixel(gui, position(lens))
        _mouse!(gui, p .+ (_pixel(gui, [0.0, 0.16, 0]) .- _pixel(gui, [0.0, 0.12, 0])))
        @test abs(_pose(lens)[1][1]) < 1e-9
        @test _pose(lens)[1][2] ≈ near[2] + 0.04 atol = 3e-3
        _mouse!(gui, _pixel(gui, P0))
        @test _pose(lens)[1] ≈ P0 atol = 2e-3
        _release!(gui)
        GUI._undo!(ctrl)
        @test _pose(lens)[1] ≈ P0
        close(gui)
    end

    @testset "move with the rotation" begin
        gui, sys, m, lens, a = _fixture(; lens_angle = deg2rad(20), snap = :pose)
        ctrl = gui.controls
        @test ctrl.snap[] == :pose
        P0, R0 = _pose(lens)
        @test abs(dot(R0[:, 2], y)) < 0.95
        by_near = _to(gui, lens, [0.003, 0.12, 0.0])
        # on the beam: the optical axis along the beam, in the closer of its two directions
        _grab!(gui, lens, by_near)
        P, R = _pose(lens)
        @test abs(P[1]) < 1e-9
        @test R[:, 2] ≈ y atol = 1e-9
        @test R' * R ≈ I atol = 1e-12
        # beside the beam: the orientation of the start of the drag
        _mouse!(gui, _pixel(gui, P0))
        @test _pose(lens)[2] ≈ R0 atol = 1e-9
        _release!(gui)
        GUI._undo!(ctrl)
        @test _pose(lens)[1] ≈ P0
        @test _pose(lens)[2] ≈ R0 atol = 1e-9
        close(gui)

        # a lens that faces the source turns onto the opposite direction
        gui, sys, m, lens, a = _fixture(; lens_angle = deg2rad(160), snap = :pose)
        _drag!(gui, lens, _to(gui, lens, [0.003, 0.12, 0.0]))
        @test _pose(lens)[2][:, 2] ≈ -y atol = 1e-9
        close(gui)

        # with the position only, and with a constrained rotation, the orientation stays
        gui, sys, m, lens, a = _fixture(; lens_angle = deg2rad(20), snap = true)
        @test gui.controls.snap[] == :position
        R0 = _pose(lens)[2]
        _drag!(gui, lens, _to(gui, lens, [0.003, 0.12, 0.0]))
        @test abs(_pose(lens)[1][1]) < 1e-9 && _pose(lens)[2] == R0
        close(gui)
        lens = SphericalLens(0.05, -0.05, 0.01, 0.02)
        zrotate3d!(lens, deg2rad(20))
        translate_to3d!(lens, [0.03, 0.1, 0])
        gui = live_view(System([lens]) => Beam([0.0, 0, 0], [0.0, 1, 0], 1e-6); trace_budget = Inf,
            throttle = false, snap = :pose, constraints = Dict(lens => (; rotate = (:v,))))
        set_view(gui.ax, [0.25, -0.2, 0.5], [0.0, 0.15, 0.0], [0.0, 0, 1])
        R0 = _pose(lens)[2]
        _drag!(gui, lens, _to(gui, lens, [0.003, 0.12, 0.0]))
        @test abs(_pose(lens)[1][1]) < 1e-9 && _pose(lens)[2] == R0
        close(gui)
    end

    @testset "locked axes" begin
        # only along the local x-axis: the lens reaches the beam, but keeps its y
        lens = SphericalLens(0.05, -0.05, 0.01, 0.02)
        translate_to3d!(lens, [0.03, 0.1, 0])
        gui = live_view(System([lens]) => Beam([0.0, 0, 0], [0.0, 1, 0], 1e-6); trace_budget = Inf,
            throttle = false, snap = true, constraints = Dict(lens => (; move = (:x,))))
        set_view(gui.ax, [0.25, -0.2, 0.5], [0.0, 0.15, 0.0], [0.0, 0, 1])
        _drag!(gui, lens, _to(gui, lens, [0.003, 0.12, 0.0]))
        P = _pose(lens)[1]
        @test abs(P[1]) < 1e-9 && P[2] == 0.1 && P[3] == 0
        close(gui)
    end

    @testset "a component in its beam" begin
        # the mirror deflects beam A: it snaps onto the beam that reaches it, not onto the
        # reflected one, also while it leaves and enters the beam
        gui, sys, m, lens, a = _fixture(; snap = true)
        P0, R0 = _pose(m)
        along = _pixel(gui, [0.0, 0.25, 0]) .- _pixel(gui, [0.0, 0.3, 0])
        side = _pixel(gui, [0.004, 0.3, 0]) .- _pixel(gui, [0.0, 0.3, 0])
        _grab!(gui, m, along .+ side)
        P = _pose(m)[1]
        @test abs(P[1]) < 1e-9 && 0.2 < P[2] < 0.29
        # far beside it, and back onto it
        _mouse!(gui, _pixel(gui, [0.04, 0.25, 0]))
        @test _pose(m)[1][1] > 0.02
        _mouse!(gui, _pixel(gui, [0.002, 0.2, 0]))
        @test abs(_pose(m)[1][1]) < 1e-9
        _release!(gui)
        @test _pose(m)[2] == R0
        close(gui)
    end

    @testset "rotate" begin
        gui, sys, m, lens, a = _fixture(; lens_at = [0.0, 0.1, 0.0], lens_angle = deg2rad(10), snap = true)
        ctrl = gui.controls
        GUI._set_mode!(gui, :rotate)
        speed = ctrl.rotate_speed
        angle() = GUI._angle_about(ctrl.rotation_axis, y, _pose(lens)[2][:, 2])
        φ0 = angle()
        @test abs(φ0) ≈ deg2rad(10) atol = 1e-9
        # the pixels that turn the optical axis to within 1.5° of the beam: it snaps onto it
        dx = round(-φ0 / speed) + sign(φ0) * 3
        @test abs(φ0 + dx * speed) ≈ deg2rad(1.5) atol = speed
        _grab!(gui, lens, (dx, 0.0))
        @test angle() ≈ 0 atol = 1e-9
        @test ctrl.drag_beam_angle ≈ φ0
        # further: free again, as far as the mouse turned it
        _mouse!(gui, _pixel(gui, position(lens)) .+ Point2f(dx - sign(φ0) * 20, 0))
        @test angle() ≈ φ0 + (dx - sign(φ0) * 20) * speed atol = 1e-9
        # and to 45°
        target = sign(angle()) * π / 4
        dx45 = round((target - φ0) / speed) + 2
        _mouse!(gui, _pixel(gui, position(lens)) .+ Point2f(dx45, 0))
        @test angle() ≈ target atol = 1e-9
        _release!(gui)
        GUI._undo!(ctrl)
        @test angle() ≈ φ0 atol = 1e-9

        # snap off: the angle follows the mouse
        GUI._set_snap!(ctrl, false)
        _drag!(gui, lens, (dx, 0.0))
        @test angle() ≈ φ0 + dx * speed atol = 1e-9
        @test isnothing(ctrl.drag_beam_angle)
        close(gui)

        # a component beside the beams turns freely with the snap
        gui, sys, m, lens, a = _fixture(; lens_at = [0.1, 0.1, 0.0], lens_angle = deg2rad(10), snap = true)
        ctrl = gui.controls
        GUI._set_mode!(gui, :rotate)
        _drag!(gui, lens, (dx, 0.0))
        @test isnothing(ctrl.drag_beam_angle)
        @test GUI._angle_about(ctrl.rotation_axis, y, _pose(lens)[2][:, 2]) ≈ φ0 + dx * speed atol = 1e-9
        close(gui)
    end

    @testset "switching ($layout)" for layout in (:compact, :app)
        gui, sys, m, lens, a = _fixture(; layout)
        ctrl = gui.controls
        @test ctrl.snap[] == :off
        # the key Tab switches to the next state: the position, position and rotation, off
        _key!(gui, Keyboard.tab)
        @test ctrl.snap[] == :position
        @test gui.status.text[] == "snap on: position onto the beams"
        _key!(gui, Keyboard.tab)
        @test ctrl.snap[] == :pose
        @test gui.status.text[] == "snap on: position + rotation onto the beams"
        _key!(gui, Keyboard.tab)
        @test ctrl.snap[] == :off && gui.status.text[] == "snap off"
        # with Shift to the state before
        _key!(gui, Keyboard.left_shift)
        _key!(gui, Keyboard.tab)
        @test ctrl.snap[] == :pose
        _key!(gui, Keyboard.tab)
        _key!(gui, Keyboard.left_shift, Keyboard.release)
        @test ctrl.snap[] == :position
        @test gui.status.text[] == "snap on: position onto the beams"
        GUI._cycle_snap!(ctrl, -1)
        @test ctrl.snap[] == :off
        GUI._cycle_snap!(ctrl)
        @test ctrl.snap[] == :position
        # not while a box takes the keyboard, and not in the spectator mode
        box = first(GUI._catalog_widget(GUI._catalog_window(gui)).boxes)
        box.focused[] = true
        _key!(gui, Keyboard.tab)
        @test ctrl.snap[] == :position
        box.focused[] = false
        GUI._set_spectator!(ctrl, true)
        _key!(gui, Keyboard.tab)
        @test ctrl.snap[] == :position
        GUI._set_spectator!(ctrl, false)
        _key!(gui, Keyboard.tab)
        @test ctrl.snap[] == :pose

        # the key is taken, and listed in the help
        @test occursin("Tab", GUI._key_binding(gui, Keyboard.tab))
        @test_throws ArgumentError add_tool!(g -> nothing, gui, "x"; key = Keyboard.tab)
        snap = only(filter(s -> s.first == "Snap onto beams", GUI._help_sections(ctrl))).second
        @test first(snap).keys == ["Tab"]
        @test any(e -> e.keys == ["Shift", "Tab"] && e.combo, snap)
        @test any(e -> occursin("45°", e.text), snap)
        close(gui)

        # the kwarg
        @test_throws ArgumentError _fixture(; layout, snap = :beam)
    end
end

end
