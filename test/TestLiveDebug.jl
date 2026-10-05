module TestLiveDebug

using GLMakie, BeamletOptics, BeamletOpticsGUI
using BeamletOptics: render_children, render_plots, rendered
using Makie
using LinearAlgebra: norm
using Test

const BMO = BeamletOptics
const GUI = BeamletOpticsGUI

@testset "Debug mode" begin

    # Each change is solved at once, see `TestLiveView.jl`; no card of a detector is pinned at start
    _live_view(args...; kwargs...) =
        live_view(args...; merge((; trace_budget = Inf, throttle = false, preview = false,
            detectors = [], progress_delay = Inf), kwargs)...)

    _key!(gui, key) = (events(gui.ax.scene).keyboardbutton[] = Makie.KeyEvent(key, Keyboard.press))
    _tick!(gui) = (events(gui.ax.scene).tick[] = Makie.Tick(Makie.RegularRenderTick, 0, 0.0, 1 / 60))

    function _mirror(y = 0.3)
        m = RoundPlanoMirror(25e-3, 5e-3)
        zrotate3d!(m, deg2rad(45))
        translate3d!(m, [0, y, 0])
        return m
    end
    function _lens(y)
        lens = SphericalLens(0.05, -0.05, 0.01, 0.02)
        translate3d!(lens, [0, y, 0])
        return lens
    end

    # A beam along +y through a lens, a doublet, a cube beamsplitter and a group of a lens and a
    # mesh, onto a mirror: objects of one and of several shapes, with and without a bounding sphere
    function _setup()
        lens = _lens(0.05)
        doublet = SphericalDoubletLens(0.1, -0.08, -0.2, 6e-3, 3e-3, 0.02, 1.6, 1.7)
        translate3d!(doublet, [0, 0.1, 0])
        cube = CubeBeamsplitter(0.02, 1.5)
        translate3d!(cube, [0, 0.15, 0])
        inner = _lens(0.2)
        dummy = BMO.NonInteractableObject(BMO.CubeMesh(0.01))
        translate3d!(dummy, [0.05, 0.2, 0])
        group = ObjectGroup([inner, dummy])
        mirror = _mirror()
        sys = System([lens, doublet, cube, group, mirror])
        beam = Beam([0.0, 0, 0], [0.0, 1, 0], 1e-6)
        return (; sys, beam, lens, doublet, cube, group, inner, dummy, mirror)
    end

    # The shapes that the solver tests one by one, see `TestRenderBoundingSphere.jl` of BeamletOptics
    _shapes(obj) = _shapes(BMO.shape_trait_of(obj), obj)
    _shapes(shape::BMO.AbstractShape) = Any[shape]
    _shapes(::BMO.SingleShape, obj) = Any[BMO.shape(obj)]
    _shapes(::BMO.MultiShape, obj) = reduce(vcat, (_shapes(part) for part in BMO.shape(obj)); init = Any[])
    _shapes(sys::BMO.AbstractSystem) = reduce(vcat, (_shapes(obj) for obj in sys.objects); init = Any[])
    # Those with a bounding sphere, which BeamletOptics decides, not a list of types
    _with_sphere(x) = filter(s -> !isnothing(BMO.world_bounding_sphere(s)), _shapes(x))

    _debug(gui) = gui.components.debug
    _shape(part::BMO.AbstractShape) = part
    _shape(part) = BMO.shape(part)
    # The sphere plots of the view per shape
    _plots(gui) = IdDict{Any, Any}(_shape(part) => only(render_plots(oh)) for (part, oh) in _debug(gui).handles)
    _plots(gui, x) = Any[p for (s, p) in _plots(gui) if any(q -> q === s, _shapes(x))]
    _in_scene(gui, plot) = any(q -> q === plot, gui.ax.scene.plots)

    # The points of the plot in world coordinates, i.e. with its model matrix applied
    function _world_points(p)
        model = Makie.transformation(p).model[]
        pts = filter(q -> !any(isnan, q), p[1][])
        return map(pts) do q
            w = model * Makie.Point4d(q[1], q[2], q[3], 1.0)
            Makie.Point3d(w[1], w[2], w[3]) ./ w[4]
        end
    end
    # Whether the plot `p` shows the bounding sphere of the `shape` as it is now
    function _on_sphere(p, shape; rtol = 1e-4)
        center, radius = BMO.world_bounding_sphere(shape)
        c = Makie.Point3d(center)
        pts = _world_points(p)
        return !isempty(pts) && all(q -> isapprox(norm(q - c), radius; rtol), pts)
    end
    # Whether the view shows exactly the spheres of the shapes of its systems, where they are
    function _matches(gui)
        plots = _plots(gui)
        expected = reduce(vcat, (_with_sphere(rendered(h)) for h in gui.system_handles); init = Any[])
        return length(plots) == length(expected) && all(s -> haskey(plots, s), expected) &&
               all(s -> _on_sphere(plots[s], s), expected)
    end
    _all_visible(plots) = !isempty(plots) && all(p -> p.visible[], plots)
    _none_visible(plots) = all(p -> !p.visible[], plots)

    @testset "parts" begin
        s = _setup()
        parts = GUI._debug_parts(s.lens)
        @test length(parts) == 1 && parts[1] === s.lens
        # one part per shape of an object of several shapes and of a group
        for obj in (s.doublet, s.cube, s.group, s.mirror)
            parts = GUI._debug_parts(obj)
            @test length(parts) == length(_shapes(obj))
            @test all(((p, shape),) -> _shape(p) === shape, zip(parts, _shapes(obj)))
        end
        # a source has none
        @test isempty(GUI._debug_parts(s.beam))
        # the fixture has shapes with a bounding sphere
        @test !isempty(_with_sphere(s.sys))
    end

    @testset "tool and kwarg, $layout" for layout in (:compact, :app)
        s = _setup()
        gui = _live_view(s.sys => s.beam; layout)
        d = _debug(gui)
        # off at the start, nothing is drawn before the mode is switched on
        @test !d.shown && !d.toggle.active[] && isempty(d.handles)
        n_scene = length(gui.ax.scene.plots)
        n_objects = length(render_plots(gui.controls.h))
        bbox = GUI._visible_bbox((gui.system_handles..., gui.extras))

        d.toggle.active[] = true
        @test d.shown
        @test occursin("debug mode on", gui.status.text[])
        plots = _plots(gui)
        # one sphere per shape with a sphere, none for a shape without
        @test length(plots) == length(_with_sphere(s.sys))
        @test length(gui.ax.scene.plots) == n_scene + length(plots)
        @test _matches(gui)
        @test _all_visible(values(plots))
        @test all(p -> p isa Makie.Lines && _in_scene(gui, p), values(plots))
        for shape in _shapes(s.sys)
            @test haskey(plots, shape) == !isnothing(BMO.world_bounding_sphere(shape))
        end
        # an overlay: not among the plots of the objects, not picked, not clipped, and the box of
        # the scene is the same
        @test length(render_plots(gui.controls.h)) == n_objects
        @test !any(p -> any(q -> q === p, render_plots(gui.controls.h)), values(plots))
        @test all(p -> isnothing(GUI._pick_leaf(gui.controls.h, p)), values(plots))
        @test all(p -> isempty(p.clip_planes[]) && !p.inspectable[], values(plots))
        @test GUI._visible_bbox((gui.system_handles..., gui.extras)) == bbox
        plane = GUI._add_clip_plane!(gui, [0.0, 0.1, 0], [0.0, 1, 0]; select = false)
        @test all(p -> isempty(p.clip_planes[]), values(plots))
        GUI._remove_clip_plane!(gui, plane)

        # switched off, the spheres are hidden, and shown again they are the same plots
        d.toggle.active[] = false
        @test !d.shown && gui.status.text[] == "debug mode off"
        @test _none_visible(values(plots))
        @test all(p -> _in_scene(gui, p), values(plots))
        d.toggle.active[] = true
        @test _all_visible(values(plots))
        @test all(((shape, p),) -> _plots(gui)[shape] === p, collect(plots))
        @test length(gui.ax.scene.plots) == n_scene + length(plots)
        @test isnothing(gui.last_error)
        close(gui)

        # the kwarg starts with the mode on and keeps the status line
        s = _setup()
        gui = _live_view(s.sys => s.beam; layout, debug = true)
        d = _debug(gui)
        @test d.shown && d.toggle.active[]
        @test !occursin("debug", gui.status.text[])
        @test _matches(gui) && _all_visible(values(_plots(gui)))
        close(gui)
    end

    @testset "no key" begin
        s = _setup()
        gui = _live_view(s.sys => s.beam)
        d = _debug(gui)
        @test !any(==("Debug"), values(gui.custom.keys))
        # `d` moves the camera of GLMakie and does not switch the mode
        _key!(gui, Keyboard.d)
        @test !d.shown && !d.toggle.active[]
        close(gui)
    end

    @testset "moves, $layout" for layout in (:compact, :app)
        s = _setup()
        moved = Ref(0.0)
        gui = _live_view(s.sys => s.beam; layout, debug = true, fine_step = 1e-3,
            sliders = ["lens" => (0.0:0.001:0.01, function (v)
                translate3d!(s.lens, [v - moved[], 0, 0])
                moved[] = v
            end)])
        @test _matches(gui)
        plots = _plots(gui)

        # a step of the keys
        y0 = position(s.doublet)[2]
        gui.controls.selected[] = s.doublet
        GUI._update_selection_box!(gui.controls)
        _key!(gui, Keyboard.up)
        @test position(s.doublet)[2] != y0 || position(s.doublet)[3] != 0
        @test _matches(gui)
        # undo and redo of the step
        @test GUI._undo!(gui.controls)
        @test position(s.doublet)[2] ≈ y0
        @test _matches(gui)
        @test GUI._redo!(gui.controls)
        @test _matches(gui)

        # a group moves its objects
        gui.controls.selected[] = s.group
        GUI._update_selection_box!(gui.controls)
        _key!(gui, Keyboard.up)
        @test _matches(gui)

        # a slider
        gui.sliders.sliders[1].value[] = 0.005
        _tick!(gui)
        @test position(s.lens)[1] ≈ 0.005
        @test _matches(gui)

        # `retrace!` after a change from code, also a rotation
        retrace!(gui) do
            translate3d!(s.cube, [0.01, 0, 0.02])
            zrotate3d!(s.cube, deg2rad(30))
            xrotate3d!(s.lens, deg2rad(20))
        end
        @test _matches(gui)

        # an action of a card, see `_commit_pose!`
        P0, R0 = GUI._pose(s.mirror)
        translate3d!(s.mirror, [0, 0.01, 0])
        GUI._commit_pose!(gui, s.mirror, P0, R0)
        @test _matches(gui)

        # moved while the mode is off, the spheres are where the shapes are when it is on again
        d = _debug(gui)
        d.toggle.active[] = false
        retrace!(() -> translate3d!(s.lens, [0, 0, 0.03]), gui)
        d.toggle.active[] = true
        @test _matches(gui)
        # the plots are moved, not drawn again
        @test all(((shape, p),) -> _plots(gui)[shape] === p, collect(plots))
        @test isnothing(gui.last_error)
        close(gui)
    end

    @testset "add and remove, $layout" for layout in (:compact, :app)
        s = _setup()
        gui = _live_view(s.sys => s.beam; layout, debug = true)
        d = _debug(gui)
        n = length(_plots(gui))

        # added while the mode is on
        lens = _lens(0.25)
        add_component!(gui, lens)
        new = _plots(gui, lens)
        @test length(new) == length(_with_sphere(lens))
        @test length(_plots(gui)) == n + length(new)
        @test _matches(gui) && _all_visible(values(_plots(gui)))

        # removed with the component
        remove_component!(gui, lens)
        @test length(_plots(gui)) == n && isempty(_plots(gui, lens))
        @test !any(p -> _in_scene(gui, p), new)
        @test _matches(gui)
        # undo adds it again, redo removes it
        @test GUI._undo!(gui.controls)
        @test any(o -> o === lens, s.sys.objects)
        @test length(_plots(gui)) == n + length(_with_sphere(lens))
        @test _matches(gui)
        @test GUI._redo!(gui.controls)
        @test length(_plots(gui)) == n && _matches(gui)

        # an object of several shapes and a group
        old = _plots(gui, s.doublet)
        remove_component!(gui, s.doublet)
        @test isempty(_plots(gui, s.doublet)) && !any(p -> _in_scene(gui, p), old)
        @test _matches(gui)
        @test GUI._undo!(gui.controls)
        @test length(_plots(gui, s.doublet)) == length(_with_sphere(s.doublet))
        @test _matches(gui)
        old = _plots(gui, s.group)
        remove_component!(gui, s.group)
        @test isempty(_plots(gui, s.group)) && !any(p -> _in_scene(gui, p), old)
        @test _matches(gui)
        @test GUI._undo!(gui.controls)
        @test _matches(gui)

        # added while the mode is off: drawn when it is switched on
        d.toggle.active[] = false
        cube = CubeBeamsplitter(0.02, 1.5)
        translate3d!(cube, [0.1, 0.1, 0])
        scene_plots = length(gui.ax.scene.plots)
        add_component!(gui, cube)
        @test isempty(_plots(gui, cube))
        @test _none_visible(values(_plots(gui)))
        d.toggle.active[] = true
        @test length(_plots(gui, cube)) == length(_with_sphere(cube))
        @test _matches(gui) && _all_visible(values(_plots(gui)))
        # removed while the mode is off
        d.toggle.active[] = false
        old = _plots(gui, cube)
        remove_component!(gui, cube)
        @test !any(p -> _in_scene(gui, p), old)
        d.toggle.active[] = true
        @test _matches(gui)
        @test isnothing(gui.last_error)
        close(gui)

        # a view that never had the mode on draws nothing
        s = _setup()
        gui = _live_view(s.sys => s.beam; layout)
        add_component!(gui, _lens(0.25))
        remove_component!(gui, s.doublet)
        @test isempty(_debug(gui).handles)
        close(gui)
    end

    @testset "sources and extras, $layout" for layout in (:compact, :app)
        s = _setup()
        housing = _lens(0.4)
        gui = _live_view(s.sys => s.beam; layout, debug = true, extras = [housing])
        # only the traced components
        @test isempty(_plots(gui, housing))
        @test !haskey(_debug(gui).handles, s.beam)
        @test _matches(gui)
        close(gui)
    end

    @testset "hidden and spectator, $layout" for layout in (:compact, :app)
        s = _setup()
        gui = _live_view(s.sys => s.beam; layout, debug = true)
        d = _debug(gui)
        all_plots = collect(values(_plots(gui)))
        others(x) = filter(p -> !any(q -> q === p, _plots(gui, x)), all_plots)

        # hidden with their object
        for obj in (s.lens, s.doublet, s.group)
            GUI._toggle_hidden!(gui, obj)
            @test _none_visible(_plots(gui, obj))
            @test _all_visible(others(obj))
            # the mode switched off and on: the hidden object stays without spheres
            d.toggle.active[] = false
            @test _none_visible(all_plots)
            d.toggle.active[] = true
            @test _none_visible(_plots(gui, obj)) && _all_visible(others(obj))
            GUI._toggle_hidden!(gui, obj)
            @test _all_visible(all_plots)
        end
        GUI._toggle_hidden!(gui, s.lens)
        GUI._toggle_hidden!(gui, s.cube)
        GUI._show_all!(gui)
        @test _all_visible(all_plots)

        # the spectator mode shows the scene without them
        GUI._toggle_hidden!(gui, s.lens)
        gui.controls.spectator[] = true
        @test _none_visible(all_plots)
        # they still follow, and a component that is added has none in this mode
        retrace!(() -> translate3d!(s.cube, [0.01, 0, 0]), gui)
        lens = _lens(0.25)
        add_component!(gui, lens)
        @test _none_visible(values(_plots(gui)))
        gui.controls.spectator[] = false
        @test _none_visible(_plots(gui, s.lens))
        @test _all_visible(others(s.lens)) && _all_visible(_plots(gui, lens))
        @test _matches(gui)
        @test isnothing(gui.last_error)
        close(gui)

        # a view that starts in the spectator mode
        s = _setup()
        gui = _live_view(s.sys => s.beam; layout, debug = true, spectator = true)
        @test _debug(gui).shown && _none_visible(values(_plots(gui)))
        gui.controls.spectator[] = false
        @test _matches(gui) && _all_visible(values(_plots(gui)))
        close(gui)
    end

    @testset "linked windows, $layout" for layout in (:compact, :app)
        s = _setup()
        gui = _live_view(s.sys => s.beam; layout, debug = true, fine_step = 1e-3)
        # the new window takes over the mode
        other = open_system(gui, s.sys; display = false)
        @test _debug(other).shown && _debug(other).toggle.active[]
        @test _matches(other) && _all_visible(values(_plots(other)))
        # each window has plots of its own
        @test !any(p -> any(q -> q === p, values(_plots(gui))), values(_plots(other)))

        # a move in one window shows in the other one
        gui.controls.selected[] = s.doublet
        GUI._update_selection_box!(gui.controls)
        _key!(gui, Keyboard.up)
        @test _matches(gui) && _matches(other)
        retrace!(() -> translate3d!(s.lens, [0.01, 0, 0]), other)
        @test _matches(gui) && _matches(other)

        # and so do added and removed components
        lens = _lens(0.25)
        add_component!(gui, lens)
        @test length(_plots(other, lens)) == length(_with_sphere(lens))
        @test _matches(gui) && _matches(other)
        old = _plots(other, lens)
        remove_component!(other, lens)
        @test isempty(_plots(gui, lens)) && isempty(_plots(other, lens))
        @test !any(p -> _in_scene(other, p), old)
        @test _matches(gui) && _matches(other)
        @test isnothing(gui.last_error) && isnothing(other.last_error)

        # a window opened from a view with the mode off has it off; the switch is per window
        _debug(gui).toggle.active[] = false
        @test _debug(other).shown
        third = open_system(gui, s.sys; display = false)
        @test !_debug(third).shown && isempty(_debug(third).handles)
        close(third)
        close(other)
        close(gui)
    end
end

end
