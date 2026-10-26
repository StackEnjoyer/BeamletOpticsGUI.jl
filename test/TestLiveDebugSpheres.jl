module TestLiveDebugSpheres

using GLMakie, BeamletOptics, BeamletOpticsGUI
using BeamletOptics: render_plots, rendered
using Makie
using LinearAlgebra: norm
using Test

const BMO = BeamletOptics
const GUI = BeamletOpticsGUI

@testset "Debug mode: bounding spheres" begin

    # Each change is solved at once, see `TestLiveView.jl`; no card of a detector is pinned at start
    _live_view(args...; kwargs...) =
        live_view(args...; merge((; trace_budget = Inf, throttle = false, preview = false,
            detectors = [], progress_delay = Inf), kwargs)...)

    function _mirror(y = 0.3)
        m = RoundPlanoMirror(25e-3, 5e-3)
        zrotate3d!(m, deg2rad(45))
        translate3d!(m, [0, y, 0])
        return m
    end
    function _lens(y, x = 0.0)
        lens = SphericalLens(0.05, -0.05, 0.01, 0.02)
        translate3d!(lens, [x, y, 0])
        return lens
    end

    # A beam along +y through a lens, a doublet, a cube beamsplitter and a group of a lens and a
    # mesh, onto a mirror: objects of one and of several shapes, with and without a bounding sphere.
    # Beside the beam a group of a group of two lenses (`pair` of `a` and `b`) and a lens (`c`):
    # groups with a main sphere, in contrast to the group with the mesh
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
        a, b, c = _lens(0.2, 0.1), _lens(0.23, 0.1), _lens(0.26, 0.1)
        pair = ObjectGroup([a, b])
        nested = ObjectGroup([pair, c])
        sys = System([lens, doublet, cube, group, nested, mirror])
        beam = Beam([0.0, 0, 0], [0.0, 1, 0], 1e-6)
        return (; sys, beam, lens, doublet, cube, group, inner, dummy, mirror, nested, pair, a, b, c)
    end

    # The shapes that the solver tests one by one
    _shapes(obj) = _shapes(BMO.shape_trait_of(obj), obj)
    _shapes(shape::BMO.AbstractShape) = Any[shape]
    _shapes(::BMO.SingleShape, obj) = Any[BMO.shape(obj)]
    _shapes(::BMO.MultiShape, obj) = reduce(vcat, (_shapes(part) for part in BMO.shape(obj)); init = Any[])
    _shapes(group::BMO.AbstractObjectGroup) =
        reduce(vcat, (_shapes(part) for part in BMO.objects(group)); init = Any[])
    _shapes(sys::BMO.AbstractSystem) = reduce(vcat, (_shapes(obj) for obj in sys.objects); init = Any[])
    # What is tested with a sphere of its own: the objects of one shape and the shapes of the
    # objects of several shapes (`_parts`), and the objects of several shapes and the groups
    # themselves, with their main sphere (`_mains`)
    _parts(obj) = _parts(BMO.shape_trait_of(obj), obj)
    _parts(shape::BMO.AbstractShape) = Any[shape]
    _parts(::BMO.SingleShape, obj) = Any[obj]
    _parts(::BMO.MultiShape, obj) = reduce(vcat, (_parts(part) for part in BMO.shape(obj)); init = Any[])
    _parts(group::BMO.AbstractObjectGroup) =
        reduce(vcat, (_parts(part) for part in BMO.objects(group)); init = Any[])
    _parts(sys::BMO.AbstractSystem) = reduce(vcat, (_parts(obj) for obj in sys.objects); init = Any[])
    _mains(obj) = _mains(BMO.shape_trait_of(obj), obj)
    _mains(::BMO.AbstractShape) = Any[]
    _mains(::BMO.SingleShape, obj) = Any[]
    _mains(::BMO.MultiShape, obj) = reduce(vcat, (_mains(part) for part in BMO.shape(obj)); init = Any[obj])
    _mains(group::BMO.AbstractObjectGroup) =
        reduce(vcat, (_mains(part) for part in BMO.objects(group)); init = Any[group])
    _mains(sys::BMO.AbstractSystem) = reduce(vcat, (_mains(obj) for obj in sys.objects); init = Any[])
    _spheres(x) = vcat(_parts(x), _mains(x))
    # Those with a bounding sphere, which BeamletOptics decides, not a list of types
    _has_sphere(x) = !(BMO.bounding_sphere_of(x) isa BMO.NoBoundingSphere)
    _with_sphere(x) = filter(_has_sphere, _spheres(x))

    # The layer, and the sphere plots of the view per part and per object with a main sphere
    _layer(gui) = GUI._debug_layer(gui, :spheres)
    _plots(gui) = IdDict{Any, Any}(x => only(render_plots(oh)) for (x, oh) in _layer(gui).handles)
    _plots(gui, x) = Any[p for (s, p) in _plots(gui) if any(q -> q === s, _spheres(x))]
    _in_scene(gui, plot) = any(q -> q === plot, gui.ax.scene.plots)
    _has_color(p, color) = Makie.to_color(p.color[]) == Makie.to_color(color)

    # The points of the plot in world coordinates, i.e. with its model matrix applied
    function _world_points(p)
        model = Makie.transformation(p).model[]
        pts = filter(q -> !any(isnan, q), p[1][])
        return map(pts) do q
            w = model * Makie.Point4d(q[1], q[2], q[3], 1.0)
            Makie.Point3d(w[1], w[2], w[3]) ./ w[4]
        end
    end
    # Whether the plot `p` shows the bounding sphere of `x` as it is now
    function _on_sphere(p, x; rtol = 1e-4)
        sphere = BMO.bounding_sphere_of(x)
        c = Makie.Point3d(sphere.pos)
        pts = _world_points(p)
        return !isempty(pts) && all(q -> isapprox(norm(q - c), sphere.radius; rtol), pts)
    end
    # Whether the view shows exactly the spheres of the parts and the main spheres of the objects
    # of its systems, where they are
    function _matches(gui)
        plots = _plots(gui)
        expected = reduce(vcat, (_with_sphere(rendered(h)) for h in gui.system_handles); init = Any[])
        return length(plots) == length(expected) && all(s -> haskey(plots, s), expected) &&
               all(s -> _on_sphere(plots[s], s), expected)
    end
    _all_visible(plots) = !isempty(plots) && all(p -> p.visible[], plots)
    _none_visible(plots) = all(p -> !p.visible[], plots)

    # A view with the debug mode on; the call sites of the dispatchers may not be in the host files
    # yet, hence the tests call them after an action, which gives the same result twice
    function _debug_view(s; kwargs...)
        gui = _live_view(s.sys => s.beam; kwargs...)
        GUI._set_debug!(gui, true)
        return gui
    end
    _moved!(gui, obj = nothing) = (GUI._debug_moved!(gui, obj); GUI._debug_moved!(gui, obj))

    @testset "parts" begin
        s = _setup()
        parts = GUI._debug_parts(s.lens)
        @test length(parts) == 1 && parts[1] === s.lens
        # one part per shape of an object of several shapes and of a group
        for obj in (s.doublet, s.cube, s.group, s.nested, s.mirror)
            parts = GUI._debug_parts(obj)
            @test length(parts) == length(_shapes(obj))
            @test all(((p, q),) -> p === q, zip(parts, _parts(obj)))
        end
        # a source has none
        @test isempty(GUI._debug_parts(s.beam))
        # the fixture has shapes with a bounding sphere
        @test !isempty(_with_sphere(s.sys))
        # a mesh has a sphere, the object that is never hit has none
        @test _has_sphere(BMO.shape(s.dummy)) && !_has_sphere(s.dummy)
    end

    @testset "objects with a main sphere" begin
        s = _setup()
        # an object of one shape, a shape and a source have none
        @test isempty(GUI._debug_mains(s.lens))
        @test isempty(GUI._debug_mains(BMO.shape(s.lens)))
        @test isempty(GUI._debug_mains(s.beam))
        # an object of several shapes
        for obj in (s.doublet, s.cube)
            mains = GUI._debug_mains(obj)
            @test length(mains) == 1 && mains[1] === obj
        end
        # a group and the groups in it, each one before the ones it contains
        mains = GUI._debug_mains(s.nested)
        @test length(mains) == 2 && mains[1] === s.nested && mains[2] === s.pair
        mains = GUI._debug_mains(s.group)
        @test length(mains) == 1 && mains[1] === s.group
        for obj in (s.lens, s.doublet, s.cube, s.group, s.nested, s.mirror)
            mains = GUI._debug_mains(obj)
            @test length(mains) == length(_mains(obj))
            @test all(((p, q),) -> p === q, zip(mains, _mains(obj)))
        end
        # no object is a part and has a main sphere
        @test !any(p -> any(q -> q === p, _mains(s.sys)), _parts(s.sys))
        # the fixture has main spheres, and a group without one: one of its objects has no sphere
        @test all(_has_sphere, (s.doublet, s.cube, s.nested, s.pair))
        @test !_has_sphere(s.group)
    end

    @testset "switching, $layout" for layout in (:compact, :app)
        s = _setup()
        gui = _live_view(s.sys => s.beam; layout)
        # nothing is created before the mode is switched on
        @test isnothing(GUI._debug_layer(gui, :spheres))
        n_scene = length(gui.ax.scene.plots)
        n_objects = length(render_plots(gui.controls.h))
        bbox = GUI._visible_bbox((gui.system_handles..., gui.extras))

        GUI._set_debug!(gui, true)
        layer = _layer(gui)
        @test layer isa GUI._DebugSpheres
        plots = _plots(gui)
        # one sphere per part with a sphere and one per object with a main sphere, none for one
        # without
        @test length(plots) == length(_with_sphere(s.sys))
        @test length(gui.ax.scene.plots) == n_scene + length(plots)
        @test _matches(gui)
        @test _all_visible(values(plots))
        @test all(p -> p isa Makie.Lines && _in_scene(gui, p), values(plots))
        for x in _spheres(s.sys)
            @test haskey(plots, x) == _has_sphere(x)
        end
        # the spheres of the parts in magenta, the main spheres in orange
        @test all(x -> !haskey(plots, x) || _has_color(plots[x], :magenta), _parts(s.sys))
        @test all(x -> !haskey(plots, x) || _has_color(plots[x], :orange), _mains(s.sys))
        @test all(x -> haskey(plots, x), (s.doublet, s.cube, s.nested, s.pair))
        @test !haskey(plots, s.group) && !haskey(plots, s.dummy)
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
        GUI._set_debug!(gui, false)
        @test _none_visible(values(plots))
        @test all(p -> _in_scene(gui, p), values(plots))
        GUI._set_debug!(gui, true)
        @test _all_visible(values(plots))
        @test all(((x, p),) -> _plots(gui)[x] === p, collect(plots))
        @test length(gui.ax.scene.plots) == n_scene + length(plots)
        @test isnothing(gui.last_error)
        close(gui)
    end

    @testset "moves" begin
        s = _setup()
        gui = _debug_view(s)
        @test _matches(gui)
        plots = _plots(gui)

        # a step of a part
        translate3d!(s.doublet, [0, 0.01, 0.005])
        _moved!(gui, s.doublet)
        @test _matches(gui)

        # a group moves its objects
        translate3d!(s.group, [0.01, 0, 0])
        _moved!(gui, s.group)
        @test _matches(gui)

        # a rotation, with `nothing`: anything may have moved
        zrotate3d!(s.cube, deg2rad(30))
        xrotate3d!(s.lens, deg2rad(20))
        _moved!(gui)
        @test _matches(gui)

        # moved while the mode is off, the spheres are where the shapes are when it is on again
        GUI._set_debug!(gui, false)
        translate3d!(s.lens, [0, 0, 0.03])
        GUI._debug_moved!(gui, s.lens)
        GUI._set_debug!(gui, true)
        @test _matches(gui)
        # the plots are moved, not drawn again
        @test all(((x, p),) -> haskey(_plots(gui), x) && _plots(gui)[x] === p,
            filter(((x, p),) -> x !== s.nested, collect(plots)))
        @test isnothing(gui.last_error)
        close(gui)
    end

    @testset "main spheres" begin
        s = _setup()
        gui = _debug_view(s)
        n_scene = length(gui.ax.scene.plots)
        plots = _plots(gui)
        same(x) = _plots(gui)[x] === plots[x]

        # a group that is moved as a whole: its main spheres are moved, not drawn again
        translate3d!(s.nested, [0, 0, 0.01])
        zrotate3d!(s.nested, deg2rad(20))
        _moved!(gui, s.nested)
        @test _matches(gui)
        @test all(((x, p),) -> _plots(gui)[x] === p, collect(plots))

        # an object of a group that is moved on its own changes the main sphere of the group
        r0 = BMO.bounding_sphere_of(s.nested).radius
        translate3d!(s.c, [0, 0, 0.03])
        _moved!(gui, s.c)
        @test BMO.bounding_sphere_of(s.nested).radius > r0
        @test _matches(gui)
        @test !same(s.nested) && same(s.pair) && same(s.c) && same(s.doublet)
        @test !_in_scene(gui, plots[s.nested])
        @test _has_color(_plots(gui)[s.nested], :orange)
        @test length(gui.ax.scene.plots) == n_scene

        # and so does an object of a group in the group, for both groups
        plots = _plots(gui)
        translate3d!(s.a, [0, 0, 0.04])
        _moved!(gui, s.a)
        @test _matches(gui)
        @test !same(s.pair) && !same(s.nested) && same(s.a) && same(s.cube)
        @test length(gui.ax.scene.plots) == n_scene
        @test isnothing(gui.last_error)
        close(gui)
    end

    @testset "add and remove" begin
        s = _setup()
        gui = _debug_view(s)
        n = length(_plots(gui))

        # added while the mode is on
        lens = _lens(0.25)
        add_component!(gui, lens)
        GUI._debug_attached!(gui, lens)
        GUI._debug_attached!(gui, lens)
        new = _plots(gui, lens)
        @test length(new) == length(_with_sphere(lens))
        @test length(_plots(gui)) == n + length(new)
        @test _matches(gui) && _all_visible(values(_plots(gui)))

        # removed with the component
        GUI._debug_released!(gui, lens)
        remove_component!(gui, lens)
        GUI._debug_released!(gui, lens)
        @test length(_plots(gui)) == n && isempty(_plots(gui, lens))
        @test !any(p -> _in_scene(gui, p), new)
        @test _matches(gui)

        # an object of several shapes
        old = _plots(gui, s.doublet)
        GUI._debug_released!(gui, s.doublet)
        remove_component!(gui, s.doublet)
        @test isempty(_plots(gui, s.doublet)) && !any(p -> _in_scene(gui, p), old)
        @test _matches(gui)

        # a group of groups with its main spheres
        old = _plots(gui, s.nested)
        @test length(old) == length(_with_sphere(s.nested)) == 5
        GUI._debug_released!(gui, s.nested)
        remove_component!(gui, s.nested)
        @test isempty(_plots(gui, s.nested)) && !any(p -> _in_scene(gui, p), old)
        @test !haskey(_layer(gui).handles, s.nested) && !haskey(_layer(gui).handles, s.pair)
        @test _matches(gui)

        # added while the mode is off: drawn when it is switched on
        GUI._set_debug!(gui, false)
        cube = CubeBeamsplitter(0.02, 1.5)
        translate3d!(cube, [0.1, 0.1, 0])
        add_component!(gui, cube)
        GUI._debug_attached!(gui, cube)
        @test isempty(_plots(gui, cube))
        @test _none_visible(values(_plots(gui)))
        GUI._set_debug!(gui, true)
        @test length(_plots(gui, cube)) == length(_with_sphere(cube))
        @test _matches(gui) && _all_visible(values(_plots(gui)))
        @test isnothing(gui.last_error)
        close(gui)

        # a view that never had the mode on draws nothing
        s = _setup()
        gui = _live_view(s.sys => s.beam)
        add_component!(gui, _lens(0.25))
        GUI._debug_attached!(gui, s.lens)
        remove_component!(gui, s.doublet)
        @test isnothing(GUI._debug_layer(gui, :spheres))
        close(gui)
    end

    @testset "sources and extras" begin
        s = _setup()
        housing = _lens(0.4)
        gui = _live_view(s.sys => s.beam; extras = [housing])
        GUI._set_debug!(gui, true)
        # only the traced components
        @test isempty(_plots(gui, housing))
        @test !haskey(_layer(gui).handles, s.beam)
        @test _matches(gui)
        close(gui)
    end

    @testset "hidden and spectator" begin
        s = _setup()
        gui = _debug_view(s)
        all_plots = collect(values(_plots(gui)))
        others(x) = filter(p -> !any(q -> q === p, _plots(gui, x)), all_plots)

        # hidden with their object, also the main spheres
        for obj in (s.lens, s.doublet, s.group, s.nested)
            GUI._toggle_hidden!(gui, obj)
            GUI._debug_hidden!(gui)
            GUI._debug_hidden!(gui)
            @test _none_visible(_plots(gui, obj))
            @test _all_visible(others(obj))
            # the mode switched off and on: the hidden object stays without spheres
            GUI._set_debug!(gui, false)
            @test _none_visible(all_plots)
            GUI._set_debug!(gui, true)
            @test _none_visible(_plots(gui, obj))
            @test _all_visible(others(obj))
            GUI._toggle_hidden!(gui, obj)
            GUI._debug_hidden!(gui)
            @test _all_visible(all_plots)
        end

        # one object of a group hidden: its sphere only, and the main sphere of the group stays
        GUI._toggle_hidden!(gui, s.a)
        GUI._debug_hidden!(gui)
        @test _none_visible(_plots(gui, s.a)) && _all_visible(others(s.a))
        GUI._toggle_hidden!(gui, s.a)
        GUI._debug_hidden!(gui)
        @test _all_visible(all_plots)

        # the spectator mode hides them, and a sphere that is moved stays hidden
        gui.controls.spectator[] = true
        GUI._debug_show!(gui)
        @test _none_visible(all_plots)
        translate3d!(s.b, [0, 0, 0.01])
        _moved!(gui, s.b)
        @test _none_visible(values(_plots(gui)))
        gui.controls.spectator[] = false
        GUI._debug_show!(gui)
        @test _matches(gui) && _all_visible(values(_plots(gui)))

        # a main sphere that is drawn again stays hidden with its group
        GUI._toggle_hidden!(gui, s.nested)
        GUI._debug_hidden!(gui)
        translate3d!(s.b, [0, 0, -0.02])
        _moved!(gui, s.b)
        @test _matches(gui)
        @test _none_visible(_plots(gui, s.nested))
        GUI._toggle_hidden!(gui, s.nested)
        GUI._debug_hidden!(gui)
        @test _all_visible(values(_plots(gui)))
        @test isnothing(gui.last_error)
        close(gui)
    end
end

end
