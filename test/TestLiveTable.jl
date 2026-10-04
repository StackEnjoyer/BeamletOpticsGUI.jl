module TestLiveTable

using GLMakie, BeamletOptics, BeamletOpticsGUI
using Makie
using LinearAlgebra: norm, dot, normalize
using Test

const BMO = BeamletOptics
const GUI = BeamletOpticsGUI

@testset "Optical table" begin
    x, y, z = [1.0, 0, 0], [0.0, 1, 0], [0.0, 0, 1]

    # Beam A along +y onto a mirror at 45° at y = 0.3 and a lens beside it at y = 0.1; the mouse
    # moves the objects in the plane of the table
    function _fixture(; lens_at = [0.031, 0.108, 0.0], lens_angle = 0.0, kwargs...)
        m = RoundPlanoMirror(25e-3, 5e-3)
        zrotate3d!(m, deg2rad(45))
        translate3d!(m, [0, 0.3, 0])
        lens = SphericalLens(0.05, -0.05, 0.01, 0.02)
        zrotate3d!(lens, lens_angle)
        translate_to3d!(lens, lens_at)
        sys = System([m, lens])
        a = Beam([0.0, 0, 0], [0.0, 1, 0], 1e-6)
        gui = live_view(sys => a; trace_budget = Inf, throttle = false, plane_normal = [0, 0, 1],
            kwargs...)
        set_view(gui.ax, [0.25, -0.2, 0.5], [0.0, 0.15, 0.0], [0.0, 0, 1])
        return gui, sys, m, lens, a
    end

    _pose(obj) = (collect(Float64, position(obj)), Matrix{Float64}(BMO.orientation(obj)))
    function _pixel(gui, point)
        scene = gui.ax.scene
        p = Makie.project(scene, :data, :pixel, Point3f(point))[Vec(1, 2)]
        return Point2f(Makie.viewport(scene)[].origin) .+ p
    end
    _mouse!(gui, px) = (events(gui.ax.scene).mouseposition[] = (Float64(px[1]), Float64(px[2])))
    _press!(gui) = (events(gui.ax.scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.press))
    _release!(gui) = (events(gui.ax.scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.release))
    # `at` [px] is where the object is grabbed, from its position
    function _drag!(gui, obj, by; steps = 4, at = (0, 0))
        gui.controls.selected[] = obj
        p0 = _pixel(gui, position(obj)) .+ Point2f(at)
        _mouse!(gui, p0)
        _press!(gui)
        foreach(k -> _mouse!(gui, p0 .+ (k / steps) .* Point2f(by)), 1:steps)
        _release!(gui)
        return nothing
    end
    _to(gui, obj, point) = _pixel(gui, point) .- _pixel(gui, position(obj))
    # Whether the coordinate `u` [m] is a multiple of the `pitch`
    _on_grid(u, pitch) = abs(u / pitch - round(u / pitch)) < 1e-6
    _in_scene(gui, plot) = any(q -> q === plot, gui.ax.scene.plots)

    @testset "kwarg" begin
        @test GUI._table_spec(false) == (; shown = false, pitch = 25e-3, height = nothing, snap = true)
        @test GUI._table_spec(true).shown
        spec = GUI._table_spec((; pitch = 25.4e-3, height = -0.1))
        @test spec == (; shown = true, pitch = 25.4e-3, height = -0.1, snap = true)
        @test !GUI._table_spec((; snap = false)).snap
        @test !GUI._table_spec((; shown = false)).shown
        @test_throws ArgumentError GUI._table_spec(3)
        @test_throws ArgumentError GUI._table_spec((; size = 1))
        @test_throws ArgumentError GUI._table_spec((; pitch = 0))
        @test_throws ArgumentError GUI._table_spec((; pitch = "a"))
        @test_throws ArgumentError GUI._table_spec((; height = Inf))
        @test_throws ArgumentError GUI._table_spec((; snap = 1))
        # checked before the window is built
        sys = System([RoundPlanoMirror(25e-3, 5e-3)])
        @test_throws ArgumentError live_view(sys; table = (; pitch = -1))
    end

    @testset "grid" begin
        @test GUI._table_axes(z) == (x, y)
        e1, e2 = GUI._table_axes(x)
        @test e1 == y && e2 ≈ z
        n = normalize([1.0, 1, 1])
        e1, e2 = GUI._table_axes(n)
        @test abs(dot(e1, n)) < 1e-12 && abs(dot(e2, n)) < 1e-12 && abs(dot(e1, e2)) < 1e-12
        @test norm(e1) ≈ 1 && norm(e2) ≈ 1

        t = GUI._Table(z, GUI._table_spec(true))
        @test t.pitch == 25e-3 && t.normal == z && !t.shown && isnothing(t.height) && isnothing(t.range)
        # the closest hole, at the height of the point
        @test GUI._grid_point(t, [0.031, 0.108, 0.02]) ≈ [0.025, 0.1, 0.02]
        @test GUI._grid_point(t, [-0.0126, 0.0124, -0.3]) ≈ [-0.025, 0.0, -0.3]
        @test GUI._grid_point(t, [0.05, 0.075, 0.0]) ≈ [0.05, 0.075, 0.0]
        # a table perpendicular to x: the height is x
        tx = GUI._Table(x, GUI._table_spec((; pitch = 0.01)))
        @test GUI._grid_point(tx, [0.123, 0.016, -0.004]) ≈ [0.123, 0.02, 0.0]

        # the holes below the points with a margin, at least 12 x 8
        @test GUI._table_range(t, Vector{Float64}[]) == (-5, 6, -3, 4)
        r = GUI._table_range(t, [[0.0, 0, 0], [0.26, 0.6, 0.1]])
        @test r == (-2, 13, -2, 26)
        @test GUI._table_range(t, [[0.26, 0.6, 0.1]]; margin = 0, min_holes = (1, 1)) == (10, 11, 24, 24)
        @test GUI._union_range(nothing, r) == r
        @test GUI._union_range((0, 1, -5, 2), (-3, 0, 0, 7)) == (-3, 1, -5, 7)

        t.height, t.range = -0.01, (-1, 1, 0, 1)
        holes, every = GUI._table_holes(t)
        @test every == 1 && length(holes) == 6
        @test holes[1] ≈ Point3f(-0.025, 0, -0.01) && holes[end] ≈ Point3f(0.025, 0.025, -0.01)
        outline = GUI._table_outline(t)
        @test length(outline) == 5 && outline[1] == outline[end]
        @test outline[1] ≈ Point3f(-0.0375, -0.0125, -0.01) && outline[3] ≈ Point3f(0.0375, 0.0375, -0.01)
        # too many holes: every second one, those with even indices
        t.range = (-150, 150, -100, 100)
        holes, every = GUI._table_holes(t)
        @test every == 2 && length(holes) == 151 * 101 <= GUI._TABLE_MAX_HOLES
        @test all(h -> isapprox(h[1] / 0.05, round(h[1] / 0.05); atol = 1e-3) &&
            isapprox(h[2] / 0.05, round(h[2] / 0.05); atol = 1e-3), holes)
    end

    @testset "shown and hidden ($layout)" for layout in (:compact, :app)
        gui, sys, m, lens, a = _fixture(; layout)
        t = gui.components.table
        scene = gui.ax.scene
        @test t isa GUI._Table && !t.shown && isempty(t.plots) && !t.toggle.active[]
        @test t.normal == z && (t.e1, t.e2) == (x, y)
        n_plots = length(scene.plots)
        # hidden: nothing snaps
        @test isnothing(GUI._table_snap(gui, lens, [0.031, 0.108, 0.0]))

        t.toggle.active[] = true
        @test t.shown && length(t.plots) == 2 && all(p -> _in_scene(gui, p), t.plots)
        @test length(scene.plots) == n_plots + 2
        @test all(p -> p.visible[], t.plots)
        @test occursin("table shown", gui.status.text[]) && occursin("25 mm", gui.status.text[])
        # below the components: at their lowest point, here the edge of the mirror
        bb = GUI._visible_bbox((gui.system_handles..., gui.extras))
        @test t.height ≈ minimum(bb)[3]
        @test t.height < -0.01
        # around the components and the source, with two holes of margin
        i0, i1, j0, j1 = t.range
        @test i0 * t.pitch <= minimum(bb)[1] - 0.05 && i1 * t.pitch >= maximum(bb)[1] + 0.05
        @test j0 * t.pitch <= -0.05 && j1 * t.pitch >= maximum(bb)[2] + 0.05
        @test i1 - i0 + 1 >= 12 && j1 - j0 + 1 >= 8
        @test length(t.holes[]) == (i1 - i0 + 1) * (j1 - j0 + 1)
        @test all(h -> h[3] ≈ t.height, t.holes[])
        @test t.hole_size[] ≈ 0.24f0 * 0.025f0
        # an overlay: never clipped, and no object of the controls
        @test all(p -> isempty(p.clip_planes[]), t.plots)
        @test !any(p -> any(q -> q === p, BMO.render_plots(gui.controls.h)), t.plots)

        snap = GUI._table_snap(gui, lens, [0.031, 0.108, 0.0])
        @test snap.point ≈ [0.025, 0.1, 0.0] && snap.direction == x
        @test GUI._table_snap(gui, a, [0.031, 0.108, 0.0]).point ≈ [0.025, 0.1, 0.0]
        plane = GUI._add_clip_plane!(gui, [0.0, 0.1, 0.0], [0.0, 1, 0]; select = false)
        @test isnothing(GUI._table_snap(gui, plane, [0.031, 0.108, 0.0]))

        # hidden again: the plots are kept, shown again at the same height
        h = t.height
        t.toggle.active[] = false
        @test !t.shown && all(p -> !p.visible[], t.plots) && gui.status.text[] == "table hidden"
        @test isnothing(GUI._table_snap(gui, lens, [0.031, 0.108, 0.0]))
        t.toggle.active[] = true
        @test t.shown && length(t.plots) == 2 && all(p -> p.visible[], t.plots) && t.height == h
        close(gui)
    end

    @testset "at the start" begin
        gui, sys, m, lens, a = _fixture(; table = true)
        t = gui.components.table
        @test t.shown && t.toggle.active[] && length(t.plots) == 2
        # the status line of the start is kept
        @test !occursin("table", gui.status.text[])
        close(gui)

        gui, sys, m, lens, a = _fixture(; layout = :app, table = (; pitch = 12.5e-3, height = -0.1, snap = false))
        t = gui.components.table
        @test t.shown && t.pitch == 12.5e-3 && t.height == -0.1 && !t.snap
        @test all(h -> h[3] ≈ -0.1f0, t.holes[])
        @test isnothing(GUI._table_snap(gui, lens, [0.031, 0.108, 0.0]))
        t.toggle.active[] = false
        t.toggle.active[] = true
        @test gui.status.text[] == "table shown"
        close(gui)

        # perpendicular to the rotation axis of the controls
        gui, sys, m, lens, a = _fixture(; table = true, rotation_axis = [0, 1, 0])
        t = gui.components.table
        @test t.normal == y && t.e1 == x && t.e2 ≈ -z
        @test all(h -> h[2] ≈ t.height, t.holes[])
        close(gui)

        # a view without components and sources: around the origin, two holes below it
        gui = live_view(System(); table = true)
        t = gui.components.table
        @test t.height ≈ -0.05
        @test t.range == (-5, 6, -3, 4) && length(t.holes[]) == 96
        close(gui)
        # ... or below its source
        gui = live_view(System() => Beam([0.0, 0, 0.1], [0.0, 1, 0], 1e-6); table = true)
        @test gui.components.table.height ≈ 0.05
        close(gui)
    end

    @testset "dragged components snap onto the holes" begin
        gui, sys, m, lens, a = _fixture(; table = true)
        ctrl = gui.controls
        t = gui.components.table
        @test ctrl.snap[] == :off
        _drag!(gui, lens, _to(gui, lens, [0.062, 0.139, 0.0]))
        P = _pose(lens)[1]
        @test P ≈ [0.05, 0.15, 0.0] atol = 1e-9
        # one gesture
        GUI._undo!(ctrl)
        @test _pose(lens)[1] ≈ [0.031, 0.108, 0.0] atol = 1e-9
        GUI._redo!(ctrl)
        @test _pose(lens)[1] ≈ [0.05, 0.15, 0.0] atol = 1e-9
        # the source as well
        _drag!(gui, a, _to(gui, a, [0.03, -0.02, 0.0]))
        @test collect(Float64, position(a)) ≈ [0.025, -0.025, 0.0] atol = 1e-9
        # hidden: the mouse moves it freely
        t.toggle.active[] = false
        _drag!(gui, lens, _to(gui, lens, [0.062, 0.139, 0.0]))
        P = _pose(lens)[1]
        @test P[3] ≈ 0 atol = 1e-9
        @test !_on_grid(P[1], t.pitch) && !_on_grid(P[2], t.pitch)
        close(gui)

        # a table that does not snap
        gui, sys, m, lens, a = _fixture(; table = (; snap = false))
        _drag!(gui, lens, _to(gui, lens, [0.062, 0.139, 0.0]))
        P = _pose(lens)[1]
        @test !_on_grid(P[1], 25e-3) && !_on_grid(P[2], 25e-3)
        close(gui)

        # the beams come first: onto the beam within its radius, beside it onto the holes
        gui, sys, m, lens, a = _fixture(; table = true, snap = true)
        _drag!(gui, lens, _to(gui, lens, [0.002, 0.113, 0.0]))
        P = _pose(lens)[1]
        @test abs(P[1]) < 1e-9 && !_on_grid(P[2], 25e-3)
        _drag!(gui, lens, _to(gui, lens, [0.07, 0.11, 0.0]))
        @test _pose(lens)[1] ≈ [0.075, 0.1, 0.0] atol = 1e-9
        close(gui)
    end

    @testset "rotation in steps of 45° to the rows of the holes" begin
        gui, sys, m, lens, a = _fixture(; lens_at = [0.1, 0.1, 0.0], lens_angle = deg2rad(10), table = true)
        ctrl = gui.controls
        GUI._set_mode!(gui, :rotate)
        angle() = GUI._angle_about(ctrl.rotation_axis, x, _pose(lens)[2][:, 2])
        φ0 = angle()
        @test φ0 ≈ deg2rad(100)
        # 9° back by the mouse: within 3° of 90° to the rows
        dx = -round(deg2rad(9) / ctrl.rotate_speed)
        _drag!(gui, lens, (dx, 0.0))
        @test ctrl.drag_beam_angle ≈ φ0
        @test angle() ≈ π / 2 atol = 1e-9
        GUI._undo!(ctrl)
        @test angle() ≈ φ0 atol = 1e-9
        # hidden: the angle follows the mouse. The gizmo of the lens is shown by now, and seen from
        # above its rings lie over the lens: it is grabbed beside them, a press on a ring drags the ring
        gui.components.table.toggle.active[] = false
        at = (0, -6)
        _mouse!(gui, _pixel(gui, position(lens)) .+ Point2f(at))
        @test isnothing(GUI._pick_ring(ctrl, gui.ax.scene))
        _drag!(gui, lens, (dx, 0.0); at)
        @test isnothing(ctrl.drag_beam_angle)
        @test angle() ≈ φ0 + dx * ctrl.rotate_speed atol = 1e-9
        close(gui)
    end

    @testset "placed components snap onto the holes" begin
        gui, sys, m, lens, a = _fixture(; table = true)
        new = SphericalLens(0.05, -0.05, 0.01, 0.02)
        GUI._start_placement!(gui, new)
        _mouse!(gui, _pixel(gui, [0.112, 0.068, 0.0]))
        @test _pose(new)[1] ≈ [0.1, 0.075, 0.0] atol = 1e-9
        _press!(gui)
        _release!(gui)
        @test any(o -> o === new, sys.objects)
        @test _pose(new)[1] ≈ [0.1, 0.075, 0.0] atol = 1e-9
        # a source as well
        src = Beam([0.0, 0, 0], [0.0, 1, 0], 532e-9)
        GUI._start_placement!(gui, src)
        _mouse!(gui, _pixel(gui, [-0.06, 0.04, 0.0]))
        _press!(gui)
        _release!(gui)
        @test any(p -> p.second === src, gui.pairs)
        @test collect(Float64, position(src)) ≈ [-0.05, 0.05, 0.0] atol = 1e-9
        close(gui)
    end

    @testset "grows with the setup" begin
        gui, sys, m, lens, a = _fixture(; table = true)
        t = gui.components.table
        r = t.range
        # moved within the table: as it is
        _drag!(gui, lens, _to(gui, lens, [0.062, 0.139, 0.0]))
        @test t.range == r
        # added beyond it: two holes around the new component
        far = RoundPlanoMirror(25e-3, 5e-3)
        translate3d!(far, [0.5, 0.1, 0])
        add_component!(gui, far)
        @test t.range == (r[1], 22, r[3], r[4])
        @test length(t.holes[]) == (22 - r[1] + 1) * (r[4] - r[3] + 1)
        @test t.outline[][2][1] ≈ 22.5f0 * 0.025f0
        # ... and moved beyond it from code
        GUI._table_include!(gui, far)
        @test t.range == (r[1], 22, r[3], r[4])
        translate3d!(far, [0, -0.5, 0])
        GUI._table_include!(gui, far)
        @test t.range == (r[1], 22, -18, r[4])
        # while it is hidden, it stays; shown again, it covers the setup
        t.toggle.active[] = false
        src = Beam([-0.4, 0, 0], [0.0, 1, 0], 532e-9)
        add_component!(gui, src)
        @test t.range == (r[1], 22, -18, r[4])
        t.toggle.active[] = true
        # with the edge of the mirror
        @test t.range == (-18, 23, -18, r[4])
        GUI._table_include!(gui, nothing)
        close(gui)
    end
end

end
