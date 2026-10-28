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
    # The same tree of types and poses in any order of the parts of a group: `push!` of an
    # `ObjectGroup` appends, the window puts a new part at the place of the first of its objects
    function _same_parts(x, y)
        (typeof(x) == typeof(y) && _same_pose(x, y)) || return false
        x isa BMO.AbstractObjectGroup || return true
        xs, ys = collect(Any, BMO.objects(x)), collect(Any, BMO.objects(y))
        return length(xs) == length(ys) && all(v -> count(u -> _same_parts(u, v), xs) == 1, ys)
    end
    # The same objects in the same order
    _same_objs(xs, ys) = length(xs) == length(ys) && all(((x, y),) -> x === y, zip(xs, ys))
    _parts(g) = collect(Any, BMO.objects(g))
    _orientation(g) = Matrix{Float64}(BMO.orientation(g))

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

    @testset "dissolving a nested group, $layout" for layout in (:compact, :app)
        m1, o1 = _built(MIRROR; angle = 0.2, at = [0.0, 0.1, 0.0])
        m2, o2 = _built(MIRROR; axis = [1.0, 2, 3], angle = 0.4, at = [0.05, 0.2, 0.01])
        m3, o3 = _built(MIRROR; axis = [0.0, 1, 0], angle = 0.3, at = [-0.04, 0.15, 0.02])
        sys = System([m1, m2, m3])
        gui = _live_view(sys; layout, labels = Dict(m1 => "m1", m2 => "m2", m3 => "m3"))
        for (m, o) in ((m1, o1), (m2, o2), (m3, o3))
            gui.components.origin[m] = o
        end
        g1 = GUI._group!(gui, GUI._MultiSelection(Any[m1, m2]))
        @test g1 isa BMO.ObjectGroup
        _move!(gui, g1, [0.01, -0.02, 0.003])
        _turn!(gui, g1, [0.3, 0.1, 1.0], 0.5)
        g2 = GUI._group!(gui, GUI._MultiSelection(Any[g1, m3]))
        @test g2 isa BMO.ObjectGroup
        _turn!(gui, g2, [1.0, 1, 0], 0.6)
        _move!(gui, g2, [0.02, 0.0, -0.01])

        # nested, before dissolving
        setup = _setup(_script(gui))
        mod = _run(setup)
        top = only(_value(mod, :system).objects)
        @test _same_tree(top, g2)
        @test any(o -> o isa BMO.ObjectGroup, BMO.objects(top))

        pos0, R0 = Vector{Float64}(position(g2)), _orientation(g2)
        # `g1` is dissolved into `g2`, which is changed in place: the same group in its pose
        @test GUI._ungroup!(gui, g1)
        ng = only(sys.objects)
        @test ng === g2
        @test GUI._is_window_group(gui, g2) && !GUI._is_window_group(gui, g1)
        @test _same_objs(_parts(g2), Any[m1, m2, m3])
        @test norm(Vector{Float64}(position(g2)) - pos0) < 1e-12 && norm(_orientation(g2) - R0) < 1e-12
        # the record of `g2` is the group as it is now, see `_current_record`
        rec = gui.components.groups[g2]
        @test _same_objs(rec.members, Any[m1, m2, m3]) && norm(rec.pivot - pos0) < 1e-12
        # the members of `g1` are selected
        sel = gui.controls.selected[]
        @test GUI._is_multi(sel) && _same_objs(sel.objects, Any[m1, m2])
        _check_flat(code) = begin
            setup = _setup(code)
            mod = _run(setup)
            top = only(_value(mod, :system).objects)
            @test top isa BMO.ObjectGroup
            @test length(BMO.objects(top)) == 3
            @test !any(o -> o isa BMO.AbstractObjectGroup, BMO.objects(top))
            @test _same_tree(top, ng)
            @test norm(Vector{Float64}(position(top)) - Vector{Float64}(position(ng))) < 1e-9
            for (k, m) in enumerate((m1, m2, m3))
                @test _same_pose(_value(mod, Symbol("m$k")), m)
            end
            @test count(l -> occursin("ObjectGroup(", l), split(setup, "\n")) == 1
        end
        _check_flat(_script(gui))

        # moved afterwards
        _turn!(gui, ng, [0.0, 1, 1], 0.3)
        _move!(gui, ng, [0.0, 0.01, 0.0])
        _check_flat(_script(gui))

        # undo of the dissolving: the nested structure is written again
        # (`_change!` of the moves above is not an entry of the history, only the dissolving is,
        # and `g2` keeps its pose after them)
        pos1 = Vector{Float64}(position(g2))
        @test GUI._undo!(gui.controls)
        @test only(sys.objects) === g2
        @test _same_objs(_parts(g2), Any[g1, m3]) && GUI._is_window_group(gui, g1)
        @test norm(Vector{Float64}(position(g2)) - pos1) < 1e-9
        mod = _run(_setup(_script(gui)))
        top = only(_value(mod, :system).objects)
        @test _same_tree(top, g2)
        @test any(o -> o isa BMO.ObjectGroup, BMO.objects(top))
        @test norm(Vector{Float64}(position(top)) - Vector{Float64}(position(g2))) < 1e-9
        for (k, m) in enumerate((m1, m2, m3))
            @test _same_pose(_value(mod, Symbol("m$k")), m)
        end
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

    # The `code` applied to the `script` reproduces the poses of the objects `objs` (pairs
    # `variable => object` of the window) and the tree of the top-level object `top` of the system,
    # in any order of the parts of a group, see `_same_parts`
    function _replayed(script, code, objs; top)
        mod = _run(script * code)
        for (k, obj) in objs
            @test _same_pose(_value(mod, k), obj)
        end
        t = only(_value(mod, :system).objects)
        @test t === _value(mod, first(only(p for p in objs if last(p) === top)))
        @test _same_parts(t, top)
        return mod
    end
    # The variable of the group that `export_changes` pushes to the group of the script `name`
    function _pushed(code, name)
        m = match(Regex("\\npush!\\($name, (\\w+)\\)\\n"), code)
        @test !isnothing(m)
        return isnothing(m) ? "" : String(m[1])
    end
    _pose_of(g) = (Vector{Float64}(position(g)), _orientation(g))
    _same_place(g, (P, R)) = norm(Vector{Float64}(position(g)) - P) < 1e-12 && norm(_orientation(g) - R) < 1e-12

    @testset "a group made in a group of the script, $layout, nested = $nested" for layout in (:compact, :app),
            nested in (false, true)
        # the script: `sg` of `a`, `b`, `c` with its own pivot and axes, inside `top` with `d` if `nested`
        script = """
            using BeamletOptics
            a = $MIRROR
            rotate3d!(a, [0.0, 0.0, 1.0], 0.2)
            translate_to3d!(a, [0.0, 0.1, 0.0])
            b = $MIRROR
            rotate3d!(b, [1.0, 0.0, 0.0], 0.4)
            translate_to3d!(b, [0.05, 0.2, 0.01])
            c = $MIRROR
            translate_to3d!(c, [-0.04, 0.15, 0.02])
            d = $MIRROR
            translate_to3d!(d, [0.1, 0.0, 0.0])
            sg = ObjectGroup([a, b, c])
            set_pivot3d!(sg, [0.0, 0.12, 0.0])
            rotate3d!(sg, [0.0, 0.0, 1.0], 0.1)
            top = ObjectGroup([sg, d])
            system = System([$(nested ? "top" : "sg")])
            """
        mod0 = _run(script)
        a, b, c, d, sg, top, sys = (_value(mod0, x) for x in (:a, :b, :c, :d, :sg, :top, :system))
        outer = nested ? top : sg
        name = nested ? "top" : "sg"
        labels = Dict{Any, String}(a => "a", b => "b", c => "c", sg => "sg")
        nested && (labels[top] = "top"; labels[d] = "d")
        objs = Pair{Symbol, Any}[:a => a, :b => b, :c => c, :sg => sg]
        nested && push!(objs, :d => d, :top => top)
        gui = _live_view(sys; layout, labels)
        # a part of the script moved before
        _move!(gui, a, [0.0, 0.0, 0.01])
        before = _changes(gui)
        @test !occursin("ObjectGroup", before)

        place = _pose_of(sg), _pose_of(top)
        s = GUI._group!(gui, GUI._MultiSelection(Any[a, b]))
        @test s isa BMO.ObjectGroup
        # `sg` is changed in place: the same group of the script in its pose, in its system
        @test only(sys.objects) === outer
        @test _same_objs(_parts(sg), Any[s, c]) && _same_objs(_parts(top), Any[sg, d])
        @test _same_place(sg, place[1]) && _same_place(top, place[2])
        @test GUI._is_window_group(gui, s) && _same_objs(gui.components.groups[s].members, Any[a, b])
        @test !GUI._is_window_group(gui, sg) && !GUI._is_window_group(gui, top)
        @test _same_objs(gui.components.start_parts[sg], Any[a, b, c])
        @test !haskey(gui.components.start_parts, top)
        @test gui.controls.selected[] === s
        code = _changes(gui)
        # the parts of `sg` are changed, its system is not
        @test occursin("\n# sg (ObjectGroup), parts changed\ndelete!(sg, a)\ndelete!(sg, b)\n", code)
        sname = _pushed(code, "sg")
        @test occursin("\n$sname = ObjectGroup([a, b])\nset_pivot3d!($sname, [", code)
        @test findfirst("delete!(sg, b)", code).start < findfirst("$sname = ObjectGroup", code).start <
              findfirst("push!(sg, $sname)", code).start
        @test count("delete!(", code) == 2 && count("ObjectGroup(", code) == 1
        @test !occursin("push!(system", code) && !occursin("delete!(system", code)
        @test !occursin("top (ObjectGroup), parts changed", code)
        mod = _replayed(script, code, objs; top = outer)
        s1 = _value(mod, Symbol(sname))
        @test _same_objs(_parts(s1), Any[_value(mod, :a), _value(mod, :b)])
        @test length(BMO.objects(_value(mod, :sg))) == 2 && count(o -> o === s1, BMO.objects(_value(mod, :sg))) == 1

        # undo: the export is as before the grouping
        @test GUI._undo!(gui.controls)
        @test only(sys.objects) === outer && _same_objs(_parts(sg), Any[a, b, c])
        @test !GUI._is_window_group(gui, s)
        @test _changes(gui) == before

        # redo, then moved as a whole and inside
        @test GUI._redo!(gui.controls)
        @test only(sys.objects) === outer && _same_objs(_parts(sg), Any[s, c])
        @test GUI._is_window_group(gui, s)
        _turn!(gui, outer, [0.3, 0.1, 1.0], 0.5)
        _move!(gui, outer, [0.01, -0.02, 0.003])
        _move!(gui, s, [0.0, 0.0, 0.004])
        _turn!(gui, s, [0.0, 1.0, 0.0], 0.15)
        _turn!(gui, c, [1.0, 0, 0], 0.2)
        code = _changes(gui)
        @test occursin("\npush!(sg, $sname)\n", code)
        @test !occursin("push!(system", code) && !occursin("delete!(system", code)
        mod = _replayed(script, code, objs; top = outer)
        @test _same_pose(_value(mod, Symbol(sname)), s)

        # export_script: the group of the script is a comment, its constructor is not known
        setup = _setup(_script(gui))
        @test !occursin("delete!(", setup)
        @test occursin("\n# $name = … (ObjectGroup) at [", setup)
        @test occursin("\nsystem = System()\n# push!(system, $name)\n", setup)
        mod = _run(setup)
        @test isempty(_value(mod, :system).objects) && !isdefined(mod, Symbol(name))
        close(gui)
    end

    @testset "Ctrl+G in a group of the script inside another one, after turning them, $layout" for layout in (:compact, :app)
        script = """
            using BeamletOptics
            a = $MIRROR
            rotate3d!(a, [0.0, 0.0, 1.0], 0.2)
            translate_to3d!(a, [0.0, 0.1, 0.0])
            b = $MIRROR
            rotate3d!(b, [1.0, 0.0, 0.0], 0.4)
            translate_to3d!(b, [0.05, 0.2, 0.01])
            c = $MIRROR
            translate_to3d!(c, [-0.04, 0.15, 0.02])
            d = $MIRROR
            rotate3d!(d, [0.0, 1.0, 0.0], 0.3)
            translate_to3d!(d, [0.1, 0.0, 0.0])
            inner = ObjectGroup([a, b, c])
            set_pivot3d!(inner, [0.0, 0.12, 0.0])
            rotate3d!(inner, [0.0, 0.0, 1.0], 0.1)
            outer = ObjectGroup([inner, d])
            set_pivot3d!(outer, [0.05, 0.05, 0.0])
            rotate3d!(outer, [1.0, 0.0, 0.0], -0.2)
            system = System([outer])
            """
        mod0 = _run(script)
        a, b, c, d, inner, outer, sys = (_value(mod0, x) for x in (:a, :b, :c, :d, :inner, :outer, :system))
        objs = Pair{Symbol, Any}[:a => a, :b => b, :c => c, :d => d, :inner => inner, :outer => outer]
        gui = _live_view(sys; layout, labels = Dict{Any, String}(v => string(k) for (k, v) in objs))
        # turned and moved as a whole and inside, a part of the inner group moved
        _turn!(gui, outer, [0.2, 1.0, 0.3], 0.35)
        _move!(gui, outer, [0.01, 0.0, -0.02])
        _turn!(gui, inner, [1.0, 0.0, 0.0], 0.25)
        _move!(gui, b, [0.0, 0.003, 0.0])
        _replayed(script, _changes(gui), objs; top = outer)

        place = _pose_of(inner), _pose_of(outer)
        s = GUI._group!(gui, GUI._MultiSelection(Any[c, a]))
        @test s isa BMO.ObjectGroup
        # in the order of `inner`, at the place of the first of them
        @test _same_objs(_parts(s), Any[a, c])
        @test only(sys.objects) === outer && _same_objs(_parts(outer), Any[inner, d])
        @test _same_objs(_parts(inner), Any[s, b])
        @test _same_place(inner, place[1]) && _same_place(outer, place[2])
        @test GUI._is_window_group(gui, s)
        @test !GUI._is_window_group(gui, inner) && !GUI._is_window_group(gui, outer)
        @test _same_objs(gui.components.start_parts[inner], Any[a, b, c])
        @test !haskey(gui.components.start_parts, outer)
        code = _changes(gui)
        @test occursin("\n# inner (ObjectGroup), parts changed\ndelete!(inner, a)\ndelete!(inner, c)\n", code)
        sname = _pushed(code, "inner")
        @test occursin("\n$sname = ObjectGroup([a, c])\n", code)
        @test !occursin("delete!(outer", code) && !occursin("push!(outer", code)
        @test !occursin("push!(system", code) && !occursin("delete!(system", code)
        mod = _replayed(script, code, objs; top = outer)
        @test _same_parts(_value(mod, Symbol(sname)), s)

        # turned again, also the new group and a part of it
        _turn!(gui, outer, [0.0, 0.0, 1.0], -0.4)
        _turn!(gui, s, [0.0, 1.0, 1.0], 0.3)
        _move!(gui, a, [0.002, 0.0, 0.0])
        _turn!(gui, inner, [0.0, 1.0, 0.0], 0.1)
        code = _changes(gui)
        mod = _replayed(script, code, objs; top = outer)
        @test _same_parts(_value(mod, Symbol(sname)), s)

        # ungrouped into the inner group: its parts of the start, in another order, only poses change
        @test GUI._ungroup!(gui, s)
        @test _same_objs(_parts(inner), Any[a, c, b]) && _same_objs(_parts(outer), Any[inner, d])
        code = _changes(gui)
        @test !occursin("ObjectGroup(", code) && !occursin("parts changed", code)
        @test !occursin("delete!(", code) && !occursin("push!(", code)
        _replayed(script, code, objs; top = outer)
        close(gui)
    end

    @testset "ungrouping a group made in a group of the script, $layout" for layout in (:compact, :app)
        script = """
            using BeamletOptics
            a = $MIRROR
            translate_to3d!(a, [0.0, 0.1, 0.0])
            b = $MIRROR
            rotate3d!(b, [1.0, 0.0, 0.0], 0.4)
            translate_to3d!(b, [0.05, 0.2, 0.01])
            c = $MIRROR
            translate_to3d!(c, [-0.04, 0.15, 0.02])
            f = $MIRROR
            rotate3d!(f, [0.0, 1.0, 0.0], 0.3)
            translate_to3d!(f, [0.02, 0.05, -0.03])
            sg = ObjectGroup([a, b, c, f])
            set_pivot3d!(sg, [0.0, 0.12, 0.0])
            rotate3d!(sg, [0.0, 0.0, 1.0], 0.1)
            system = System([sg])
            """
        mod0 = _run(script)
        a, b, c, f, sg, sys = (_value(mod0, x) for x in (:a, :b, :c, :f, :sg, :system))
        objs = Pair{Symbol, Any}[:a => a, :b => b, :c => c, :f => f, :sg => sg]
        gui = _live_view(sys; layout, labels = Dict(a => "a", b => "b", c => "c", f => "f", sg => "sg"))
        _no_parts_changed(code) =
            !occursin("ObjectGroup(", code) && !occursin("parts changed", code) &&
            !occursin("delete!(", code) && !occursin("push!(", code)

        s = GUI._group!(gui, GUI._MultiSelection(Any[a, b]))
        @test _same_objs(_parts(sg), Any[s, c, f])
        _turn!(gui, s, [0.0, 0.0, 1.0], 0.2)
        _move!(gui, sg, [0.0, 0.01, 0.0])
        _turn!(gui, sg, [1.0, 0.0, 0.0], 0.3)
        before = _changes(gui)
        _replayed(script, before, objs; top = sg)

        place = _pose_of(sg)
        @test GUI._ungroup!(gui, s)
        # dissolved into `sg`, which is changed in place: its parts of the start
        @test only(sys.objects) === sg && _same_objs(_parts(sg), Any[a, b, c, f])
        @test _same_place(sg, place)
        @test !GUI._is_window_group(gui, s) && !GUI._is_window_group(gui, sg)
        sel = gui.controls.selected[]
        @test GUI._is_multi(sel) && _same_objs(sel.objects, Any[a, b])
        _move!(gui, c, [0.0, 0.0, 0.005])
        code = _changes(gui)
        @test _no_parts_changed(code)
        _replayed(script, code, objs; top = sg)

        # undo of the ungrouping: the export is as before it
        @test GUI._undo!(gui.controls)
        @test only(sys.objects) === sg && _same_objs(_parts(sg), Any[s, c, f])
        @test GUI._is_window_group(gui, s)
        _move!(gui, c, [0.0, 0.0, -0.005])
        # `s` keeps its initial pose, from which the export writes its change
        @test _changes(gui) == before
        _replayed(script, _changes(gui), objs; top = sg)

        # ungrouped again, then grouped within `sg` twice, the second time with the first new group
        @test GUI._redo!(gui.controls)
        @test _same_objs(_parts(sg), Any[a, b, c, f])
        s2 = GUI._group!(gui, GUI._MultiSelection(Any[a, b]))
        t = GUI._group!(gui, GUI._MultiSelection(Any[s2, c]))
        @test t isa BMO.ObjectGroup && gui.controls.selected[] === t
        @test _same_objs(_parts(sg), Any[t, f]) && _same_objs(_parts(t), Any[s2, c])
        _turn!(gui, t, [0.0, 0.0, 1.0], 0.3)
        _move!(gui, s2, [0.0, 0.002, 0.0])
        _turn!(gui, sg, [0.0, 1.0, 0.0], -0.2)
        code = _changes(gui)
        @test occursin("\n# sg (ObjectGroup), parts changed\ndelete!(sg, a)\ndelete!(sg, b)\ndelete!(sg, c)\n", code)
        tname = _pushed(code, "sg")
        @test occursin("\n$tname = ObjectGroup([", code) && count("ObjectGroup(", code) == 2
        @test !occursin("push!(system", code) && !occursin("delete!(system", code)
        mod = _replayed(script, code, objs; top = sg)
        @test _same_parts(_value(mod, Symbol(tname)), t)

        # `s2` ungrouped into `t`, a group made in the window inside a group of the script, which is
        # changed in place: its record is the group as it is now, see `_current_record`
        place = _pose_of(t)
        @test GUI._ungroup!(gui, s2)
        @test only(sys.objects) === sg && _same_objs(_parts(sg), Any[t, f])
        @test _same_objs(_parts(t), Any[a, b, c]) && _same_place(t, place)
        @test GUI._is_window_group(gui, t) && !GUI._is_window_group(gui, s2)
        rec = gui.components.groups[t]
        @test _same_objs(rec.members, Any[a, b, c]) && norm(rec.pivot - place[1]) < 1e-12
        code = _changes(gui)
        tname = _pushed(code, "sg")
        @test occursin("\n$tname = ObjectGroup([a, b, c])\n", code) && count("ObjectGroup(", code) == 1
        mod = _replayed(script, code, objs; top = sg)
        @test _same_parts(_value(mod, Symbol(tname)), t)

        # and `t` ungrouped into `sg`: its parts of the start again
        @test GUI._ungroup!(gui, t)
        @test _same_objs(_parts(sg), Any[a, b, c, f])
        code = _changes(gui)
        @test _no_parts_changed(code)
        _replayed(script, code, objs; top = sg)
        close(gui)
    end
end

end
