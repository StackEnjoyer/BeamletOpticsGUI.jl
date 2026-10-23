module TestLiveGroupExport

using GLMakie, BeamletOptics, BeamletOpticsGUI
using Makie
using GeometryBasics: Point3
using LinearAlgebra: norm, normalize
using Test

const BMO = BeamletOptics
const GUI = BeamletOpticsGUI

@testset "Export of the groups made in the window" begin

    # Each change is solved at once, see `TestLiveView.jl`; no card of a detector is pinned at start
    _live_view(args...; kwargs...) =
        live_view(args...; merge((; trace_budget = Inf, throttle = false, detectors = []), kwargs)...)

    _script(gui) = BeamletOpticsGUI.export_script(gui; io = devnull)
    _changes(gui) = BeamletOpticsGUI.export_changes(gui; io = devnull)

    # The part of the script before the live view
    function _setup(code)
        parts = split(code, "\n# Live view\n")
        @test length(parts) == 2
        return String(parts[1])
    end
    function _run(code)
        mod = Module()
        include_string(mod, code)
        return mod
    end
    _value(mod, name) = Core.eval(mod, Symbol(name))

    function _same_pose(a, b; atol = 1e-9)
        (Pa, Ra), (Pb, Rb) = GUI._pose(a), GUI._pose(b)
        return norm(Pa - Pb) < atol && norm(Ra - Rb) < atol
    end
    # The same tree of types and poses, but other objects
    function _same_tree(a, b)
        da, db = GUI._descendants(a), GUI._descendants(b)
        return a !== b && length(da) == length(db) &&
            all(((x, y),) -> typeof(x) == typeof(y) && _same_pose(x, y), zip(da, db))
    end

    _move!(gui, obj, v) = GUI._change!(() -> translate3d!(obj, v), gui.controls, obj)
    _turn!(gui, obj, axis, angle) = GUI._change!(() -> rotate3d!(obj, normalize(axis), angle), gui.controls, obj)

    LENS = "SphericalLens(0.05, -0.05, 0.005, 0.0254, 1.5)"
    MIRROR = "RoundPlanoMirror(25e-3, 5e-3)"

    # An object from its `code`, with its origin (see `_ComponentState`), then moved
    function _built(code; axis = [0.0, 0, 1], angle = 0.0, at = [0.0, 0, 0])
        obj = include_string(@__MODULE__, code)
        origin = (; code, pose0 = GUI._pose(obj))
        angle == 0 || rotate3d!(obj, normalize(axis), angle)
        translate_to3d!(obj, at)
        return obj, origin
    end
    # A group of the `members` with its pivot at the mean of their positions, like `_group!`
    function _grouped(members)
        g = ObjectGroup(members)
        set_pivot3d!(g, sum(m -> Vector{Float64}(position(m)), members) ./ length(members))
        return g
    end
    # The record of the group `g` as made in the window now, see `_group!`
    function _record(g)
        ms = collect(Any, BMO.objects(g))
        poses = IdDict{Any, Tuple{Point3{Float64}, Matrix{Float64}}}(m => GUI._pose(m) for m in ms)
        return GUI._WindowGroup(ms, Vector{Float64}(position(g)), poses)
    end
    # Records the group `g` of the script as made in the window (`_group!` builds it from the
    # selection of several), in its current pose or with the record `rec`, and the constructors of
    # its members
    function _made_in_window!(gui, g, origins = (); rec = _record(g))
        gui.components.groups[g] = rec
        for (obj, origin) in origins
            gui.components.origin[obj] = origin
        end
        return g
    end

    @testset "export_script, $layout" for layout in (:compact, :app)
        a, oa = _built(LENS; axis = [0.0, 0, 1], angle = 0.2, at = [0.0, 0.1, 0.0])
        b, ob = _built(MIRROR; axis = [1.0, 2, 3], angle = 0.4, at = [0.05, 0.2, 0.01])
        g = _grouped([a, b])
        sys = System([g])
        gui = _live_view(sys; layout, labels = Dict(a => "a", b => "b", g => "g"))
        _made_in_window!(gui, g, (a => oa, b => ob))
        pivot = Vector{Float64}(position(g))

        # not moved since it was made
        setup = _setup(_script(gui))
        @test occursin("\na = $LENS\n", setup) && occursin("\nb = $MIRROR\n", setup)
        @test occursin("\ng = ObjectGroup([a, b])\nset_pivot3d!(g, $(GUI._vector_code(pivot)))\n", setup)
        @test !occursin("BeamletOptics.objects(g)", setup)
        @test !occursin("rotate3d!(g", setup) && !occursin("translate_to3d!(g", setup)
        @test occursin("\nsystem = System([g])\n", setup)
        @test findfirst("b = ", setup).start < findfirst("g = ObjectGroup", setup).start
        mod = _run(setup)
        @test _same_tree(_value(mod, :g), g)
        @test only(_value(mod, :system).objects) === _value(mod, :g)

        # moved and turned as one, and a member inside the group
        _move!(gui, g, [0.01, -0.02, 0.003])
        _turn!(gui, g, [0.3, 0.1, 1.0], 0.7)
        _turn!(gui, b, [1.0, 0, 0], 0.1)
        _move!(gui, b, [0.0, 0.0, 0.002])
        code = _script(gui)
        setup = _setup(code)
        @test occursin("\nrotate3d!(g, [", setup) && occursin("\ntranslate_to3d!(g, [", setup)
        @test occursin("\nrotate3d!(b, [", setup)
        mod = _run(setup)
        @test _same_tree(_value(mod, :g), g)
        # the members are not moved before the group is made: their pose then
        @test _same_pose(_value(mod, :a), a) && _same_pose(_value(mod, :b), b)
        # the labels of the members are variables of the script
        @test occursin("a => \"a\"", code) && occursin("b => \"b\"", code) && occursin("g => \"g\"", code)
        @test !occursin("# a => \"a\"", code)
        close(gui)
    end

    @testset "nested groups and a member of the catalog" begin
        entry = only(filter(e -> e.name == "Doublet", component_catalog()))
        c = GUI._catalog_component(entry, String[GUI._catalog_string(p) for p in entry.params])
        d = c.obj
        rotate3d!(d, [0.0, 0, 1], 0.3)
        translate_to3d!(d, [0.0, 0.3, 0.0])
        a, oa = _built(LENS; at = [0.0, 0.1, 0.0])
        b, ob = _built(MIRROR; angle = 0.25, at = [0.02, 0.15, 0.0])
        # the inner group is made, moved, then grouped with the doublet
        inner = _grouped([a, b])
        rec_inner = _record(inner)
        translate3d!(inner, [0.0, 0.0, 0.01])
        rotate3d!(inner, [0.0, 0, 1], -0.3)
        outer = _grouped([inner, d])
        sys = System([outer])
        gui = _live_view(sys; labels = Dict(a => "a", b => "b", d => "d", inner => "inner", outer => "outer"))
        _made_in_window!(gui, inner, (a => oa, b => ob, d => c.origin); rec = rec_inner)
        _made_in_window!(gui, outer)
        _turn!(gui, outer, [1.0, 1, 0], 0.5)
        _move!(gui, outer, [0.1, 0.0, 0.0])
        if d isa BMO.AbstractObjectGroup
            # a part of the doublet inside the group is its part in the script
            part = first(BMO.objects(d))
            _move!(gui, part, [0.0, 0.0, 0.001])
        end

        setup = _setup(_script(gui))
        @test occursin("\nsystem = System([outer])\n", setup)
        @test occursin("\ninner = ObjectGroup([a, b])\n", setup)
        @test occursin("\nouter = ObjectGroup([inner, d])\n", setup)
        @test findfirst("inner = ObjectGroup", setup).start < findfirst("outer = ObjectGroup", setup).start
        d isa BMO.AbstractObjectGroup && @test occursin("BeamletOptics.objects(d)[1]", setup)
        mod = _run(setup)
        @test _same_tree(_value(mod, :outer), outer)
        close(gui)
    end

    @testset "a member without a known constructor" begin
        a, oa = _built(LENS; at = [0.0, 0.1, 0.0])
        u = RoundPlanoMirror(25e-3, 5e-3)
        translate_to3d!(u, [0.0, 0.2, 0.0])
        g = _grouped([a, u])
        gui = _live_view(System([g]); labels = Dict(a => "a", u => "u", g => "g"))
        _made_in_window!(gui, g, (a => oa,))
        _move!(gui, g, [0.01, 0.0, 0.0])
        code = _script(gui)
        setup = _setup(code)
        @test occursin("\n# u = … ", setup)
        @test occursin("\n# g = ObjectGroup([a, u])\n# set_pivot3d!(g, [", setup)
        @test occursin("\n# translate_to3d!(g, [", setup)
        @test occursin("\nsystem = System()\n# push!(system, g)\n", setup)
        # the member that is constructed is a variable of the script
        @test occursin("\na = $LENS\n", setup)
        @test occursin("\n        a => \"a\",", code) && occursin("\n        # g => \"g\",", code)
        mod = _run(setup)
        @test isempty(_value(mod, :system).objects)
        @test isdefined(mod, :a) && !isdefined(mod, :g)
        close(gui)
    end

    @testset "export_changes, $layout" for layout in (:compact, :app)
        # the script: `a` in `system`; `b` was added in the window, then both were grouped
        a, _ = _built(LENS)
        pa0 = GUI._pose(a)
        translate_to3d!(a, [0.0, 0.1, 0.0])
        b, ob = _built(MIRROR; axis = [0.0, 0, 1], angle = 0.3, at = [0.03, 0.2, 0.0])
        g = _grouped([a, b])
        sys = System([g])
        gui = _live_view(sys; layout, labels = Dict(a => "a", b => "b", g => "g"))
        # what `_group!` leaves (see G1): `a` started in `sys` and keeps its initial pose, `b` and
        # `g` are added in the window, `b` with its code
        comp = gui.components
        delete!(comp.start_systems, g)
        comp.start_systems[a] = Any[sys]
        gui.controls.init_poses[a] = pa0
        push!(comp.added, b, g)
        comp.system[b], comp.system[g] = sys, sys
        comp.origin[g] = nothing
        _made_in_window!(gui, g, (b => ob,))
        _turn!(gui, g, [0.0, 1, 1], 0.4)
        _move!(gui, g, [0.0, 0.01, 0.0])

        code = _changes(gui)
        @test occursin("\nb = $MIRROR\n# b is grouped into g below\n", code)
        @test !occursin("push!(system, b)", code)
        @test occursin("\ndelete!(system, a)\ng = ObjectGroup([a, b])\nset_pivot3d!(g, [", code)
        @test occursin("\npush!(system, g)\n", code)
        @test !occursin("delete!(system, b)", code)
        @test occursin("\ntranslate_to3d!(a, [0.0, 0.1, 0.0])\n", code)
        @test occursin("\nrotate3d!(g, [", code)
        # applied to the script, the changes rebuild the view
        mod = _run("using BeamletOptics\na = $LENS\nsystem = System([a])\n" * code)
        @test _same_tree(_value(mod, :g), g)
        @test only(_value(mod, :system).objects) === _value(mod, :g)
        close(gui)
    end
end

end
