module TestLiveGroupInPlace

using GLMakie, BeamletOptics, BeamletOpticsGUI
using Makie
using LinearAlgebra: norm, normalize
using Logging
using Test

const BMO = BeamletOptics
const GUI = BeamletOpticsGUI

# Grouping within a group and ungrouping a group that is a part of another one change the parent
# group in place (`_regroup!`): the groups that leave the tree, the undo and redo of such a change
# in linked views, and the export of the changed parts
@testset "Groups changed in place" begin

    # Each change is solved at once, see `TestLiveView.jl`; no card of a detector is pinned at start
    _live_view(args...; kwargs...) =
        live_view(args...; merge((; trace_budget = Inf, throttle = false, detectors = [],
            catalog = CatalogEntry[], progress_delay = Inf), kwargs)...)

    _changes(gui) = export_changes(gui; io = devnull)
    function _run(code)
        mod = Module()
        include_string(mod, code)
        return mod
    end
    _value(mod, name) = Core.eval(mod, Symbol(name))
    _parts(g) = collect(Any, BMO.objects(g))
    _same_objs(xs, ys) = length(xs) == length(ys) && all(((x, y),) -> x === y, zip(xs, ys))
    _in(obj, list) = any(o -> o === obj, list)
    _group!(gui, objs...) = GUI._group!(gui, GUI._MultiSelection(Any[objs...]))
    _move!(gui, obj, v) = GUI._change!(() -> translate3d!(obj, v), gui.controls, obj)
    _turn!(gui, obj, axis, angle) = GUI._change!(() -> rotate3d!(obj, normalize(axis), angle), gui.controls, obj)
    # the undo or redo of an entry that no longer applies warns that it is dropped
    _quiet(f) = with_logger(f, NullLogger())

    function _same_pose(a, b; atol = 1e-9)
        (Pa, Ra), (Pb, Rb) = GUI._pose(a), GUI._pose(b)
        return norm(Pa - Pb) < atol && norm(Ra - Rb) < atol
    end
    # The same tree of types and poses in any order of the parts of a group
    function _same_parts(x, y)
        (typeof(x) == typeof(y) && _same_pose(x, y)) || return false
        x isa BMO.AbstractObjectGroup || return true
        xs, ys = collect(Any, BMO.objects(x)), collect(Any, BMO.objects(y))
        return length(xs) == length(ys) && all(v -> count(u -> _same_parts(u, v), xs) == 1, ys)
    end
    # The `code` applied to the `script` reproduces the poses of the objects `objs` (pairs
    # `variable => object` of the window) and the objects of the system
    function _replayed(script, code, objs, sys)
        mod = _run(script * code)
        for (k, obj) in objs
            @test _same_pose(_value(mod, k), obj)
        end
        xs, ys = collect(Any, _value(mod, :system).objects), collect(Any, sys.objects)
        @test length(xs) == length(ys) && all(v -> count(u -> _same_parts(u, v), xs) == 1, ys)
        return mod
    end
    # What the `gui` knows of the groups and parents agrees with the tree of the group `top`
    function _consistent(gui, top)
        tree = GUI._descendants(top)
        @test all(g -> _in(g, tree), keys(gui.components.groups))
        @test all(g -> _in(g, tree), (a for a in gui.components.added if a isa BMO.AbstractObjectGroup))
        for d in tree, c in GUI._children(d)
            @test get(gui.objects.parents, c, nothing) === d
        end
        for (k, _) in gui.objects.parents
            k isa BMO.AbstractObjectGroup && @test _in(k, tree)
        end
        @test all(d -> haskey(gui.controls.init_poses, d), tree)
        @test !any(k -> k isa BMO.AbstractObjectGroup && !_in(k, tree), keys(gui.controls.init_poses))
    end

    MIRROR = "RoundPlanoMirror(25e-3, 5e-3)"
    SCRIPT = """
        using BeamletOptics
        m1 = $MIRROR
        zrotate3d!(m1, deg2rad(45))
        translate_to3d!(m1, [0.0, 0.1, 0.0])
        m2 = $MIRROR
        rotate3d!(m2, [1.0, 0.0, 0.0], 0.4)
        translate_to3d!(m2, [0.05, 0.2, 0.01])
        m3 = $MIRROR
        translate_to3d!(m3, [-0.04, 0.15, 0.02])
        m4 = $MIRROR
        translate_to3d!(m4, [0.02, 0.3, -0.01])
        sg = ObjectGroup([m1, m2, m3, m4])
        set_pivot3d!(sg, [0.0, 0.15, 0.0])
        rotate3d!(sg, [0.0, 0.0, 1.0], 0.1)
        system = System([sg])
        """
    function _scene(; layout = :compact)
        mod = _run(SCRIPT)
        m1, m2, m3, m4, sg, sys = (_value(mod, x) for x in (:m1, :m2, :m3, :m4, :sg, :system))
        objs = Pair{Symbol, Any}[:m1 => m1, :m2 => m2, :m3 => m3, :m4 => m4, :sg => sg]
        gui = _live_view(sys => Beam([0.0, 0, 0], [0.0, 1, 0]); layout,
            labels = Dict{Any, String}(v => string(k) for (k, v) in objs))
        wait_solve(gui)
        return (; gui, sys, m1, m2, m3, m4, sg, objs)
    end

    @testset "a dissolved group leaves the view, $layout" for layout in (:compact, :app)
        (; gui, sys, m1, m2, m3, m4, sg, objs) = _scene(; layout)
        ctrl = gui.controls
        s = _group!(gui, m1, m2)
        @test _same_objs(_parts(sg), Any[s, m3, m4])
        _turn!(gui, s, [0.0, 0.0, 1.0], 0.2)
        _move!(gui, s, [0.0, 0.0, 0.005])
        wait_solve(gui)
        init = ctrl.init_poses[s]
        before = _changes(gui)
        _replayed(SCRIPT, before, objs, sys)

        @test GUI._ungroup!(gui, s)
        wait_solve(gui)
        @test _same_objs(_parts(sg), Any[m1, m2, m3, m4])
        @test !GUI._is_window_group(gui, s)
        @test !haskey(ctrl.init_poses, s) && !haskey(ctrl.constraints, s)
        @test haskey(gui.components.forgotten, s)
        _consistent(gui, sg)
        # not an object of the view any more
        @test_throws ArgumentError select!(gui, s)
        @test_throws ArgumentError translate3d!(gui, s, [0.01, 0, 0])
        @test _same_objs(_parts(sg), Any[m1, m2, m3, m4])
        _replayed(SCRIPT, _changes(gui), objs, sys)

        # undo: `s` is a part again, with its initial pose of before
        @test GUI._undo!(ctrl)
        wait_solve(gui)
        @test _same_objs(_parts(sg), Any[s, m3, m4]) && GUI._is_window_group(gui, s)
        @test ctrl.init_poses[s] == init
        @test !haskey(gui.components.forgotten, s)
        @test _changes(gui) == before
        _consistent(gui, sg)
        select!(gui, s)
        @test ctrl.selected[] === s

        # redo and undo again
        @test GUI._redo!(ctrl)
        @test_throws ArgumentError select!(gui, s)
        @test GUI._undo!(ctrl)
        @test ctrl.init_poses[s] == init && _changes(gui) == before
        wait_solve(gui)
        close(gui)
    end

    @testset "a subgroup taken back by undo leaves the view, $layout" for layout in (:compact, :app)
        (; gui, sys, m1, m2, m3, m4, sg, objs) = _scene(; layout)
        ctrl = gui.controls
        before = _changes(gui)
        s = _group!(gui, m1, m2)
        init = ctrl.init_poses[s]
        @test GUI._undo!(ctrl)
        wait_solve(gui)
        @test _same_objs(_parts(sg), Any[m1, m2, m3, m4])
        @test !haskey(ctrl.init_poses, s)
        @test_throws ArgumentError select!(gui, s)
        @test_throws ArgumentError translate3d!(gui, s, [0.01, 0, 0])
        @test _changes(gui) == before
        _consistent(gui, sg)
        @test GUI._redo!(ctrl)
        @test ctrl.init_poses[s] == init
        @test _same_objs(_parts(sg), Any[s, m3, m4])
        _consistent(gui, sg)
        wait_solve(gui)
        close(gui)
    end

    @testset "ending the spectator mode of a linked view, $layout" for layout in (:compact, :app)
        (; gui, sys, m1, m2, sg) = _scene(; layout)
        A = gui
        B = open_system(A, sys; display = false)
        s = _group!(A, m1, m2)
        select!(B, s)
        @test B.controls.selected[] === s
        spectator!(B, true)
        @test GUI._undo!(A.controls)
        @test !_in(s, BMO.objects(sg))
        spectator!(B, false)
        @test B.controls.selected[] !== s
        @test !_in(s, GUI._selection_objects(B.controls.selected[]))
        _consistent(B, sg)
        wait_solve(A); wait_solve(B)
        close(B); close(A)
    end

    @testset "undo after a linked view changed the parts, $layout" for layout in (:compact, :app)
        (; gui, sys, m1, m2, m3, m4, sg, objs) = _scene(; layout)
        A = gui
        B = open_system(A, sys; display = false)
        wait_solve(A); wait_solve(B)
        s = _group!(A, m1, m2)
        @test GUI._is_window_group(B, s)
        _turn!(A, s, [0.0, 1.0, 0.0], 0.15)
        t = _group!(B, s, m3)
        @test _same_objs(_parts(sg), Any[t, m4]) && _same_objs(_parts(t), Any[s, m3])
        _move!(B, t, [0.0, 0.0, 0.004])
        wait_solve(A); wait_solve(B)

        # the grouping of A no longer applies: `sg` is not changed
        done = _quiet(() -> GUI._undo!(A.controls))
        @test done == false
        wait_solve(A); wait_solve(B)
        @test _same_objs(_parts(sg), Any[t, m4]) && _same_objs(_parts(t), Any[s, m3])
        @test _same_objs(_parts(s), Any[m1, m2])
        for v in (A, B)
            @test GUI._is_window_group(v, t) && GUI._is_window_group(v, s)
            @test v.objects.parents[m1] === s && v.objects.parents[m2] === s
            @test v.objects.parents[s] === t && v.objects.parents[m3] === t
            @test v.objects.parents[t] === sg && v.objects.parents[m4] === sg
            _consistent(v, sg)
            _replayed(SCRIPT, _changes(v), objs, sys)
        end

        # B ungroups `t` by undo
        @test GUI._undo!(B.controls)
        wait_solve(A); wait_solve(B)
        @test _same_objs(_parts(sg), Any[s, m3, m4]) && _same_objs(_parts(s), Any[m1, m2])
        for v in (A, B)
            @test !GUI._is_window_group(v, t) && GUI._is_window_group(v, s)
            @test v.objects.parents[s] === sg && v.objects.parents[m3] === sg
            @test !haskey(v.objects.parents, t)
            _consistent(v, sg)
            _replayed(SCRIPT, _changes(v), objs, sys)
        end
        close(B); close(A)
    end

    @testset "open_system copies the parts of the start" begin
        (; gui, sys, m1, m2, m3, m4, sg, objs) = _scene()
        A = gui
        s = _group!(A, m1, m2)
        _turn!(A, s, [0.0, 0.0, 1.0], -0.2)
        wait_solve(A)
        B = open_system(A, sys; display = false)
        wait_solve(B)
        @test haskey(B.components.start_parts, sg)
        @test _same_objs(B.components.start_parts[sg], A.components.start_parts[sg])
        @test B.components.start_parts[sg] !== A.components.start_parts[sg]
        @test GUI._is_window_group(B, s)
        ca, cb = _changes(A), _changes(B)
        for code in (ca, cb)
            @test occursin("\n# sg (ObjectGroup), parts changed\ndelete!(sg, m1)\ndelete!(sg, m2)\n", code)
            @test !isnothing(match(r"\npush!\(sg, \w+\)\n", code))
        end
        _replayed(SCRIPT, cb, objs, sys)
        close(B); close(A)
    end

    @testset "a changed group of the script removed and added again" begin
        script = """
            using BeamletOptics
            a = $MIRROR
            translate_to3d!(a, [0.0, 0.1, 0.0])
            b = $MIRROR
            translate_to3d!(b, [0.05, 0.2, 0.01])
            c = $MIRROR
            translate_to3d!(c, [-0.04, 0.15, 0.02])
            d = $MIRROR
            translate_to3d!(d, [0.1, 0.0, 0.0])
            e = $MIRROR
            translate_to3d!(e, [0.1, 0.3, 0.0])
            G = ObjectGroup([a, b, c, d])
            system = System([G, e])
            """
        mod0 = _run(script)
        objs = Pair{Symbol, Any}[k => _value(mod0, k) for k in (:a, :b, :c, :d, :e, :G)]
        o = Dict(objs)
        sys = _value(mod0, :system)
        gui = _live_view(sys; labels = Dict{Any, String}(v => string(k) for (k, v) in objs))
        s = _group!(gui, o[:a], o[:b])
        _turn!(gui, s, [0.0, 1.0, 0.3], 0.3)
        remove_component!(gui, o[:G])
        add_component!(gui, o[:G]; system = sys)
        code = _changes(gui)
        @test occursin("# push!(G, …) of ", code) && occursin("whose code is not known", code)
        # no `push!` of the group that the view forgot; the parts of `G` lost their labels with the
        # removal (see `_release!`), hence their names in the code are no variables of the script
        @test !occursin(r"^push!\(G, "m, code)
        close(gui)
    end
end

end
