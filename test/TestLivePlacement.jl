module TestLivePlacement

using GLMakie, BeamletOptics, BeamletOpticsGUI
using BeamletOptics: render_plots
using Makie
using LinearAlgebra: I, norm, dot, det, normalize
using Test

const BMO = BeamletOptics
const GUI = BeamletOpticsGUI

@testset "Placing components" begin

    @testset "rotation onto a beam" begin
        y = [0.0, 1, 0]
        z = [0.0, 0, 1]
        @test GUI._align_rotation(y, y, z) == Matrix{Float64}(I, 3, 3)
        # antiparallel: a half turn about the given axis
        @test GUI._align_rotation(y, -y, z) ≈ [-1.0 0 0; 0 -1 0; 0 0 1] atol = 1e-12
        # ... or about any axis perpendicular to `y` if the given axis is parallel to it
        R = GUI._align_rotation(y, -y, y)
        @test R * y ≈ -y atol = 1e-12
        @test R' * R ≈ I atol = 1e-12
        @test det(R) ≈ 1 atol = 1e-12
        # the smallest rotation: the axis perpendicular to both directions is kept
        d = [1.0, 2, -0.5] ./ norm([1.0, 2, -0.5])
        R = GUI._align_rotation(y, d, z)
        @test R * y ≈ d atol = 1e-12
        @test R' * R ≈ I atol = 1e-12
        axis = [y[2] * d[3] - y[3] * d[2], y[3] * d[1] - y[1] * d[3], y[1] * d[2] - y[2] * d[1]]
        @test R * axis ≈ axis atol = 1e-12
        # not normalized inputs
        @test GUI._align_rotation(2 .* y, 3 .* [1.0, 0, 0], z) * y ≈ [1.0, 0, 0] atol = 1e-12
    end

    # Beam A along +y, reflected along +x by a mirror at 45°; beam B along -y beside it
    function _fixture(; kwargs...)
        m = RoundPlanoMirror(25e-3, 5e-3)
        zrotate3d!(m, deg2rad(45))
        translate3d!(m, [0, 0.2, 0])
        sys = System([m])
        a = Beam([0.0, 0, 0], [0.0, 1, 0], 1e-6)
        b = Beam([-0.05, 0.3, 0], [0.0, -1, 0], 1e-6)
        gui = live_view(sys => a, sys => b; trace_budget = Inf, throttle = false, kwargs...)
        set_view(gui.ax, [0.35, -0.25, 0.45], [0.0, 0.1, 0.0], [0.0, 0, 1])
        return gui, sys, m
    end

    _lens() = SphericalLens(0.05, -0.05, 0.01, 0.02)

    # The pixel of the 3D `point` in the scene of the 3D view
    _pixel(gui, point) = Makie.project(gui.ax.scene, :data, :pixel, Point3f(point))[Vec(1, 2)]

    # Moves the mouse to the `point`, shifted by `shift` px perpendicular to the direction `dir` on
    # the screen
    function _mouse!(gui, point; dir = [0.0, 1, 0], shift = 0.0)
        scene = gui.ax.scene
        p = _pixel(gui, point)
        t = _pixel(gui, point .+ 0.01 .* dir) .- p
        t = t ./ norm(t)
        vp = Makie.viewport(scene)[]
        q = Point2f(vp.origin) .+ p .+ shift .* Point2f(-t[2], t[1])
        events(scene).mouseposition[] = (Float64(q[1]), Float64(q[2]))
        return nothing
    end
    _press!(gui) = (events(gui.ax.scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.press))
    _release!(gui) = (events(gui.ax.scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.release))
    _key!(gui, key) = (events(gui.ax.scene).keyboardbutton[] = Makie.KeyEvent(key, Keyboard.press))
    _in_scene(gui, plot) = any(q -> q === plot, gui.ax.scene.plots)
    _pose(obj) = (collect(Float64, position(obj)), Matrix{Float64}(BMO.orientation(obj)))

    @testset "pose under the mouse ($layout)" for layout in (:compact, :app)
        gui, sys, m = _fixture(; layout)
        ctrl = gui.controls
        scene = gui.ax.scene
        ignore_mouse = ctrl.ignore_mouse
        lens = _lens()
        R0 = _pose(lens)[2]
        n_plots = length(scene.plots)

        # outside of the 3D view
        events(scene).mouseposition[] = (-10.0, -10.0)
        GUI._start_placement!(gui, lens)
        p = gui.components.placement
        @test GUI._placing(gui)
        @test p.obj === lens && p.system === sys
        @test p.plane_point == [0.0, 0, 0]
        @test !any(o -> o === lens, sys.objects)
        ghost_plots = copy(render_plots(p.ghost))
        @test !isempty(ghost_plots) && all(q -> _in_scene(gui, q), ghost_plots)
        # shown on its plane, i.e. the plane of the view through the source; the controls ignore
        # the mouse
        n = GUI._view_direction(scene)
        @test n ≈ normalize([0.0, 0.1, 0.0] .- [0.35, -0.25, 0.45])
        @test dot(_pose(lens)[1], n) ≈ 0 atol = 1e-9
        @test abs(_pose(lens)[1][3]) > 1e-3
        @test ctrl.ignore_mouse()
        @test occursin("placing Lens", gui.status.text[])

        # 1: beside the beam, under the mouse on the plane of the view through the source, as
        # constructed
        _mouse!(gui, [0, 0.05, 0]; shift = 30)
        origin, dir = GUI._cursor_ray(scene)
        hit = GUI._ray_plane_intersect(origin, dir, [0.0, 0, 0], n)
        P, R = _pose(lens)
        @test !p.snapped
        @test P ≈ hit atol = 1e-9
        @test dot(P, n) ≈ 0 atol = 1e-9
        @test R ≈ R0 atol = 1e-9

        # 2: near beam A, on the beam, the optical axis along +y, i.e. as constructed
        _mouse!(gui, [0, 0.05, 0]; shift = 8)
        P, R = _pose(lens)
        @test p.snapped
        @test P[1] ≈ 0 atol = 1e-9
        @test P[3] ≈ 0 atol = 1e-9
        @test 0.02 < P[2] < 0.08
        @test R ≈ R0 atol = 1e-9

        # the reflected segment along +x: the smallest rotation, about z
        _mouse!(gui, [0.05, 0.2, 0]; dir = [1.0, 0, 0], shift = 5)
        P, R = _pose(lens)
        @test p.snapped
        @test P[2] ≈ 0.2 atol = 1e-6
        @test R[:, 2] ≈ [1.0, 0, 0] atol = 1e-9
        @test R[:, 3] ≈ R0[:, 3] atol = 1e-9

        # 3: beam B runs against the optical axis: a half turn about the rotation axis
        _mouse!(gui, [-0.05, 0.1, 0]; shift = 5)
        P3, R3 = _pose(lens)
        @test p.snapped
        @test P3[1] ≈ -0.05 atol = 1e-9
        @test P3[3] ≈ 0 atol = 1e-9
        @test R3 ≈ [-1.0 0 0; 0 -1 0; 0 0 1] * R0 atol = 1e-9

        # 4: outside of the 3D view, the pose is kept
        events(scene).mouseposition[] = (-10.0, -10.0)
        P, R = _pose(lens)
        @test P ≈ P3 atol = 1e-9
        @test R ≈ R3 atol = 1e-9

        # 5: seen from the side, beside the beams: under the mouse in the vertical plane through
        # the source, above the beam, in the orientation as constructed
        set_view(gui.ax, [0.5, 0.05, 0.0], [0.0, 0.05, 0.0], [0.0, 0, 1])
        vp = Makie.viewport(scene)[]
        c = Point2f(vp.origin) .+ Point2f(vp.widths) ./ 2
        events(scene).mouseposition[] = (Float64(c[1]), Float64(c[2]) + 100)
        P, R = _pose(lens)
        @test !p.snapped
        @test P[1] ≈ 0 atol = 1e-9
        @test P[3] > 0.01
        @test P[2] ≈ 0.05 atol = 1e-6
        @test R ≈ R0 atol = 1e-9

        # Esc cancels: no ghost, nothing added, the controls take the mouse again
        _key!(gui, Keyboard.escape)
        @test !GUI._placing(gui)
        @test !any(q -> _in_scene(gui, q), ghost_plots)
        @test length(scene.plots) == n_plots
        @test length(sys.objects) == 1
        @test ctrl.ignore_mouse === ignore_mouse
        @test gui.status.text[] == "placement cancelled"
        # Esc without a placement is left to the other listeners
        _key!(gui, Keyboard.escape)
        @test gui.status.text[] == "placement cancelled"
        close(gui)
    end

    @testset "a fixed plane ($layout)" for layout in (:compact, :app)
        # with a `plane_normal`, the component stays on that plane through the source
        gui, sys, m = _fixture(; layout, plane_normal = [0, 0, 1])
        scene = gui.ax.scene
        lens = _lens()
        R0 = _pose(lens)[2]
        events(scene).mouseposition[] = (-10.0, -10.0)
        GUI._start_placement!(gui, lens)
        p = gui.components.placement
        @test _pose(lens)[1][3] ≈ 0 atol = 1e-9
        _mouse!(gui, [0, 0.05, 0]; shift = 30)
        origin, dir = GUI._cursor_ray(scene)
        hit = GUI._ray_plane_intersect(origin, dir, [0.0, 0, 0], [0.0, 0, 1])
        P0, R = _pose(lens)
        @test !p.snapped
        @test P0 ≈ hit atol = 1e-9
        @test P0[3] ≈ 0 atol = 1e-9
        @test R ≈ R0 atol = 1e-9
        # looking along the plane, the camera ray beside the beams does not meet it: the position
        # is kept
        set_view(gui.ax, [0.5, 0.05, 0.0], [0.0, 0.05, 0.0], [0.0, 0, 1])
        vp = Makie.viewport(scene)[]
        c = Point2f(vp.origin) .+ Point2f(vp.widths) ./ 2
        events(scene).mouseposition[] = (Float64(c[1]), Float64(c[2]) + 100)
        P, R = _pose(lens)
        @test !p.snapped
        @test P ≈ P0 atol = 1e-9
        @test R ≈ R0 atol = 1e-9
        _key!(gui, Keyboard.escape)
        close(gui)
    end

    @testset "only the central beam of a source" begin
        # Rings of beams along +y, the outermost 10 mm beside the central beam
        source = CollimatedSource([0.0, 0, 0], [0.0, 1, 0], 20e-3, 1e-6; num_rings = 2)
        gauss = GaussianBeamlet([0.03, 0, 0], [0.0, 1, 0], 1e-6, 1e-3)
        sys = System()
        gui = live_view(sys => source, sys => gauss; trace_budget = Inf, throttle = false)
        # from above, such that the beams of the source lie apart on the screen
        set_view(gui.ax, [0.0, 0.05, 0.1], [0.0, 0.05, 0.0], [0.0, 1, 0])
        central = GUI._central_beam(source)
        @test collect(position(central)) ≈ [0.0, 0, 0] atol = 1e-12
        outer = argmax(b -> abs(position(b)[1]), BMO.beams(source))
        on_outer = collect(Float64, position(outer)) .+ [0, 0.05, 0]
        @test abs(on_outer[1]) ≈ 10e-3 atol = 1e-4
        # an outer beam is on the screen farther from the central one than the snap radius
        apart = norm(_pixel(gui, on_outer) .- _pixel(gui, [0.0, 0.05, 0]))
        @test apart > 3 * GUI._SNAP_RADIUS

        lens = _lens()
        R0 = _pose(lens)[2]
        GUI._start_placement!(gui, lens)
        p = gui.components.placement
        # on an outer beam: a beam is under the cursor, but the component does not snap onto it
        _mouse!(gui, on_outer)
        @test !isnothing(GUI._inspect_beam(gui; radius = GUI._SNAP_RADIUS))
        @test isnothing(GUI._inspect_beam(gui; radius = GUI._SNAP_RADIUS, central = true))
        @test !p.snapped
        @test _pose(lens)[1][1] ≈ on_outer[1] atol = 1e-3
        @test _pose(lens)[1][3] ≈ 0 atol = 1e-9
        # near the central beam
        _mouse!(gui, [0.0, 0.05, 0]; shift = 5)
        @test p.snapped
        @test _pose(lens)[1][1] ≈ 0 atol = 1e-9
        @test _pose(lens)[1][3] ≈ 0 atol = 1e-9
        @test _pose(lens)[2] ≈ R0 atol = 1e-9
        # near the chief ray of the Gaussian beamlet
        _mouse!(gui, [0.03, 0.05, 0]; shift = 5)
        @test p.snapped
        @test _pose(lens)[1][1] ≈ 0.03 atol = 1e-9
        GUI._cancel_placement!(gui)

        # the segments of the source are those of its central beam
        segs = GUI._central_segments(first(gui.beam_handles))
        @test !isempty(segs)
        @test all(s -> any(r -> r === s.ray, BMO.rays(central)), segs)
        @test length(GUI._beam_segments(first(gui.beam_handles))) > length(segs)
        @test isempty(GUI._central_segments(nothing))
        close(gui)
    end

    @testset "start, cancel and drop ($layout)" for layout in (:compact, :app)
        gui, sys, m = _fixture(; layout)
        ctrl = gui.controls
        scene = gui.ax.scene
        ignore_mouse = ctrl.ignore_mouse

        # a second placement cancels the first one
        first_lens, lens = _lens(), _lens()
        GUI._start_placement!(gui, first_lens)
        first_plots = copy(render_plots(gui.components.placement.ghost))
        origin = (; code = "SphericalLens(0.05, -0.05, 0.01, 0.02)", pose0 = GUI._pose(lens))
        GUI._start_placement!(gui, lens; origin)
        p = gui.components.placement
        @test p.obj === lens
        @test !any(q -> _in_scene(gui, q), first_plots)
        @test p.ignore_mouse === ignore_mouse

        # a drag is left to the camera
        _mouse!(gui, [-0.05, 0.1, 0]; shift = 5)
        _press!(gui)
        _mouse!(gui, [-0.05, 0.1, 0]; shift = 5 + 2 * ctrl.drag_threshold)
        _release!(gui)
        @test GUI._placing(gui)
        @test length(sys.objects) == 1

        # a click drops the component in its pose and selects it
        _mouse!(gui, [-0.05, 0.1, 0]; shift = 5)
        P, R = _pose(lens)
        ghost_plots = copy(render_plots(p.ghost))
        _press!(gui)
        _release!(gui)
        @test !GUI._placing(gui)
        @test !any(q -> _in_scene(gui, q), ghost_plots)
        @test sys.objects[end] === lens
        @test _pose(lens)[1] ≈ P atol = 1e-9
        @test _pose(lens)[2] ≈ R atol = 1e-9
        @test ctrl.selected[] === lens
        @test ctrl.ignore_mouse === ignore_mouse
        @test gui.components.origin[lens] === origin
        @test any(o -> o === lens, gui.components.added)
        # the dropped lens is traced: beam B ends on it
        b = last(gui.pairs).second
        @test BMO.object(BMO.intersection(first(BMO.rays(b)))) === lens

        # the spectator mode cancels a placement, and none starts in it
        other = _lens()
        GUI._start_placement!(gui, other)
        GUI._set_spectator!(ctrl, true)
        @test !GUI._placing(gui)
        GUI._start_placement!(gui, other)
        @test !GUI._placing(gui)
        @test occursin("spectator", gui.status.text[])
        GUI._set_spectator!(ctrl, false)

        # closing the view ends a placement
        GUI._start_placement!(gui, other)
        close(gui)
        @test !GUI._placing(gui)
        @test !any(o -> o === other, sys.objects)
    end

    @testset "views without a System" begin
        m = RoundPlanoMirror(25e-3, 5e-3)
        translate3d!(m, [0, 0.2, 0])
        gui = live_view(StaticSystem([m]) => Beam([0.0, 0, 0], [0.0, 1, 0], 1e-6); trace_budget = Inf)
        @test_throws ArgumentError GUI._start_placement!(gui, _lens())
        @test !GUI._placing(gui)
        # a source does not change its system
        src = Beam([0.0, 0, 0], [0.0, 1, 0], 1e-6)
        GUI._start_placement!(gui, src)
        @test GUI._placing(gui)
        GUI._drop_placement!(gui)
        @test last(gui.pairs).second === src && last(gui.pairs).first isa StaticSystem
        close(gui)
    end

    @testset "a source ($layout)" for layout in (:compact, :app)
        gui, sys, m = _fixture(; layout, show_sources = false)
        ctrl = gui.controls
        scene = gui.ax.scene
        nplots = length(scene.plots)
        a = first(gui.pairs).second

        src = Beam([0.0, 0, 0], [0.0, 1, 0], 632.8e-9)
        origin = (; code = "Beam([0.0, 0.0, 0.0], [0.0, 1.0, 0.0], 6.328e-7)", pose0 = GUI._pose(src))
        GUI._start_placement!(gui, src; origin)
        p = gui.components.placement
        @test p.obj === src && p.system === sys
        @test occursin("placing Beam", gui.status.text[])
        # placed by its marker: the markers of the sources are shown
        @test gui.widgets.sources_toggle.active[]
        @test all(q -> _in_scene(gui, q), render_plots(p.ghost))

        # it follows the mouse in the plane of the view through the first source, as constructed
        n = GUI._view_direction(scene)
        target = [0.1, 0.15, 0.05]
        _mouse!(gui, target)
        P = collect(Float64, position(src))
        @test norm(_pixel(gui, P) .- _pixel(gui, target)) < 0.5
        @test abs(dot(P .- position(a), n)) < 1e-9
        @test BMO.direction(src) ≈ [0, 1, 0] atol = 1e-12
        # not traced meanwhile
        @test length(gui.pairs) == 2 && isnothing(BMO.intersection(first(BMO.rays(src))))

        # no snapping: a lens 5 px beside beam A sits on it, a source stays under the mouse
        _mouse!(gui, [0.0, 0.1, 0]; shift = 5)
        @test !p.snapped
        P = collect(Float64, position(src))
        @test norm(_pixel(gui, P) .- _pixel(gui, [0.0, 0.1, 0])) > 4
        @test BMO.direction(src) ≈ [0, 1, 0] atol = 1e-12

        # `Esc` cancels: none of its plots is left
        ghost_plots = copy(render_plots(p.ghost))
        _key!(gui, Keyboard.escape)
        @test !GUI._placing(gui)
        @test !any(q -> _in_scene(gui, q), ghost_plots)
        @test length(scene.plots) == nplots && length(gui.pairs) == 2

        # a click drops it: a source of the system, traced, selected, with its origin
        GUI._start_placement!(gui, src; origin)
        _mouse!(gui, [0.0, 0.1, 0]; shift = 5)
        P = collect(Float64, position(src))
        _press!(gui)
        _release!(gui)
        @test !GUI._placing(gui)
        @test last(gui.pairs).second === src && last(gui.pairs).first === sys
        @test length(gui.beam_handles) == 3
        @test collect(Float64, position(src)) ≈ P atol = 1e-9
        @test ctrl.selected[] === src
        @test gui.components.origin[src] === origin
        @test any(o -> o === src, gui.components.added)
        @test isnothing(gui.trace.error) && !gui.trace.stale
        # moved onto the axis of beam A like any source: its beam ends on the mirror
        GUI._change!(() -> translate_to3d!(src, [0.0, 0.05, 0]), ctrl, src)
        ctrl.on_change(src)
        @test BMO.object(BMO.intersection(first(BMO.rays(src)))) === m
        close(gui)
    end

    @testset "the first source of a view" begin
        gui = live_view(System(); trace_budget = Inf, throttle = false)
        src = Beam([0.0, 0, 0], [0.0, 1, 0], 632.8e-9)
        GUI._start_placement!(gui, src)
        # without a source, the plane goes through the point the camera looks at
        @test gui.components.placement.plane_point ≈ collect(Float64, cameracontrols(gui.ax.scene).lookat[])
        GUI._drop_placement!(gui)
        @test only(gui.pairs).second === src
        close(gui)
    end

    # In an open window, new plots would fit the camera to the scene, see `_keep_camera!`
    @testset "the camera is kept" begin
        gui, sys, m = _fixture()
        screen = GLMakie.Screen(visible = false)
        display(screen, gui.fig)
        tick!() = (events(gui.ax.scene).tick[] = Makie.Tick(Makie.RegularRenderTick, 0, 0.0, 1 / 60))
        foreach(_ -> tick!(), 1:3)
        function kept(f)
            set_view(gui.ax, [0.2, -0.1, 0.25], [0.01, 0.1, 0.0], [0.0, 0, 1])
            tick!()
            v0 = GUI._current_view(gui)
            f()
            tick!()
            return all(a -> isapprox(a[1], a[2]; atol = 1e-9), zip(v0, GUI._current_view(gui)))
        end
        lens = _lens()
        @test kept(() -> GUI._start_placement!(gui, lens))
        @test kept(() -> GUI._cancel_placement!(gui))
        @test kept(() -> GUI._start_placement!(gui, lens))
        @test kept(() -> GUI._drop_placement!(gui))
        @test sys.objects[end] === lens
        close(screen)
        close(gui)
    end
end

end
