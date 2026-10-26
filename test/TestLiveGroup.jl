module TestLiveGroup

using GLMakie, BeamletOptics, BeamletOpticsGUI
using BeamletOptics: render_children, render_plots, rendered
using Makie
using LinearAlgebra: norm, I
using Test

const BMO = BeamletOptics
const GUI = BeamletOpticsGUI

@testset "Groups made in the window" begin

    # Each change is solved at once, see `TestLiveView.jl`; no card of a detector is pinned at start
    _live_view(args...; kwargs...) =
        live_view(args...; merge((; trace_budget = Inf, throttle = false, detectors = [],
            catalog = CatalogEntry[], progress_delay = Inf), kwargs)...)

    _beam(x = 0.0) = Beam([x, 0, 0], [0.0, 1, 0])

    # A mirror on the beam along +y, which it reflects along +x
    function _mirror(y = 0.1; x = 0.0)
        m = RoundPlanoMirror(25e-3, 5e-3)
        zrotate3d!(m, deg2rad(45))
        translate3d!(m, [x, y, 0])
        return m
    end

    # A detector on the beam reflected by the mirror at `y`
    function _detector(y = 0.1; x = 0.0)
        pd = Detector(5e-3)
        zrotate3d!(pd, -π / 2)
        translate3d!(pd, [x + 0.1, y, 0])
        return pd
    end

    # A lens, a mirror and a detector on the beam
    function _fixture(; layout = :compact, kwargs...)
        lens = ThinLens(100e-3, -100e-3, 25e-3, 1.5)
        translate3d!(lens, [0, 0.05, 0])
        m, pd = _mirror(), _detector()
        sys = System([lens, m, pd])
        gui = _live_view(sys => _beam(); layout, kwargs...)
        return (; gui, sys, lens, m, pd)
    end

    _in(obj, list) = any(o -> o === obj, list)
    # the number of the handles of the controls that draw `obj`
    _drawn(gui, obj) = count(oh -> rendered(oh) === obj, render_children(gui.controls.h))
    _top(gui, obj) = GUI._top_level(gui.controls.h, obj)
    _close(a, b) = norm(Vector{Float64}(a) .- Vector{Float64}(b)) < 1e-9
    _same_pose(obj, pose) = _close(position(obj), pose[1]) && norm(BMO.orientation(obj) .- pose[2]) < 1e-9
    _group_of_selection!(gui, objs) = (select!(gui, objs); GUI._group!(gui, gui.controls.selected[]))

    @testset "grouping and ungrouping, $layout" for layout in (:compact, :app)
        fx = _fixture(; layout)
        gui, sys, m, pd = fx.gui, fx.sys, fx.m, fx.pd
        ctrl = gui.controls
        wait_solve(gui)
        @test BMO.hit_count(pd) == 1
        name_m, name_pd = GUI._label(gui, m), GUI._label(gui, pd)
        P_m, P_pd = position(m), position(pd)
        n = length(ctrl.undo_stack)

        g = _group_of_selection!(gui, [m, pd])
        @test g isa ObjectGroup
        @test BMO.objects(g) == (m, pd)
        # the system holds the group instead of its members
        @test _in(g, sys.objects) && !_in(m, sys.objects) && !_in(pd, sys.objects)
        @test length(sys.objects) == 2
        @test GUI._is_window_group(gui, g)
        rec = gui.components.groups[g]
        @test rec.members == Any[m, pd]
        @test _close(rec.pivot, (P_m .+ P_pd) ./ 2)
        @test _close(position(g), rec.pivot)
        @test _same_pose(m, rec.poses[m])
        # one action of the history, the group is selected, its leaves are drawn once
        @test length(ctrl.undo_stack) == n + 1
        @test ctrl.selected[] === g
        @test _drawn(gui, m) == 1 && _drawn(gui, pd) == 1
        @test _top(gui, m) === g && _top(gui, pd) === g
        @test _in(g, ctrl.movable) && !_in(m, ctrl.movable)
        # the members keep their names and are not recorded as removed; the group is added
        # without code, also with the initial poses of the members
        @test GUI._label(gui, m) == name_m && GUI._label(gui, pd) == name_pd
        @test gui.components.added == Any[g] && isempty(gui.components.removed)
        @test isnothing(gui.components.origin[g]) && gui.components.system[g] === sys
        @test !haskey(gui.components.start_systems, g) && haskey(gui.components.start_systems, m)
        @test occursin("grouped", gui.status.text[])
        # traced again
        wait_solve(gui)
        @test isnothing(gui.trace.error) && !gui.trace.stale
        @test BMO.hit_count(pd) == 1

        # the object tree shows the group with its members
        if layout === :app
            gui.layout.expanded[g] = true
            rows = GUI._tree_rows(gui)
            i = findfirst(r -> r.key === g, rows)
            @test !isnothing(i) && rows[i].kind === :group
            @test any(r -> r.key === m && r.depth == rows[i].depth + 1, rows)
        end
        # the selection card browses its parts
        GUI._browse!(gui, g)
        @test gui.objects.browsed === g
        parts = GUI._browse_parts(gui.cards.browse)
        @test _in(m, parts) && _in(pd, parts)
        GUI._end_browse!(gui)

        # moves and rotates as one, about the pivot
        translate3d!(gui, g, [0.0, 0, 0.01])
        wait_solve(gui)
        @test _close(position(m), P_m .+ [0, 0, 0.01]) && _close(position(pd), P_pd .+ [0, 0, 0.01])
        pivot = Vector{Float64}(position(g))
        rotate3d!(gui, g, [0.0, 0, 1], π / 2)
        wait_solve(gui)
        @test _close(position(g), pivot)
        d = Vector{Float64}(P_m .+ [0, 0, 0.01]) .- pivot
        @test _close(position(m), pivot .+ [-d[2], d[1], d[3]])
        rotate3d!(gui, g, [0.0, 0, 1], -π / 2)
        translate3d!(gui, g, [0.0, 0, -0.01])
        wait_solve(gui)
        @test _close(position(m), P_m) && _close(position(pd), P_pd)
        @test BMO.hit_count(pd) == 1

        # hides as one
        GUI._toggle_hidden!(gui, g)
        @test GUI._all_hidden(gui, m) && GUI._all_hidden(gui, pd)
        GUI._toggle_hidden!(gui, g)
        @test !GUI._all_hidden(gui, m)

        # ungrouping: the members at their current poses, selected
        translate3d!(gui, g, [0.0, 0, 0.02])
        P1_m, P1_pd = position(m), position(pd)
        n = length(ctrl.undo_stack)
        @test GUI._ungroup!(gui, g)
        @test length(ctrl.undo_stack) == n + 1
        @test _in(m, sys.objects) && _in(pd, sys.objects) && !_in(g, sys.objects)
        @test !GUI._is_window_group(gui, g)
        @test isempty(gui.components.added) && !haskey(gui.components.origin, g) && !haskey(gui.components.system, g)
        @test _close(position(m), P1_m) && _close(position(pd), P1_pd)
        sel = ctrl.selected[]
        @test sel isa GUI._MultiSelection && sel.objects == Any[m, pd]
        @test _top(gui, m) === m && _drawn(gui, m) == 1
        # no longer parts of the group, e.g. for the pick of the members of a system
        @test GUI._component_top(gui, m) === m && isnothing(GUI._part_parent(gui, m))
        @test GUI._shown_top(gui, m) && GUI._shown_top(gui, pd)
        @test _in(m, ctrl.movable) && !_in(g, ctrl.movable)
        @test GUI._label(gui, m) == name_m && GUI._label(gui, pd) == name_pd
        @test occursin("ungrouped", gui.status.text[])
        wait_solve(gui)
        @test isnothing(gui.trace.error)
        # a group that was not made in the window is not ungrouped
        @test !GUI._ungroup!(gui, g)
        @test !GUI._ungroup!(gui, m)
        @test length(ctrl.undo_stack) == n + 1

        # undo of ungrouping groups again, with the same group; redo ungroups
        @test GUI._undo!(ctrl)
        @test _in(g, sys.objects) && !_in(m, sys.objects) && GUI._is_window_group(gui, g)
        @test ctrl.selected[] === g && _top(gui, m) === g
        @test _close(position(m), P1_m)
        @test GUI._redo!(ctrl)
        @test _in(m, sys.objects) && !_in(g, sys.objects)
        @test _close(position(m), P1_m)
        # undo of ungrouping, of the move and of grouping
        @test GUI._undo!(ctrl)
        @test GUI._undo!(ctrl)
        @test _close(position(m), P_m) && _close(position(pd), P_pd)
        while _in(g, sys.objects)
            @test GUI._undo!(ctrl)
        end
        @test _in(m, sys.objects) && _in(pd, sys.objects)
        @test _close(position(m), P_m) && _close(position(pd), P_pd)
        @test !GUI._is_window_group(gui, g) && _top(gui, m) === m
        wait_solve(gui)
        @test BMO.hit_count(pd) == 1
        # redo of grouping: the same group
        @test GUI._redo!(ctrl)
        @test _in(g, sys.objects) && GUI._is_window_group(gui, g) && ctrl.selected[] === g
        close(gui)
    end

    @testset "members keep labels, hidden state, opacity and initial poses, $layout" for layout in (:compact, :app)
        m1, m2, m3 = _mirror(), _mirror(0.3), _mirror(0.5)
        sys = System([m1, m2, m3])
        gui = _live_view(sys => _beam(); layout, labels = Dict(m1 => "M1"))
        ctrl = gui.controls
        translate3d!(gui, m2, [0.0, 0, 0.01])
        init_m2 = ctrl.init_poses[m2]
        s = (select!(gui, [m1, m2, m3]); ctrl.selected[])
        GUI._set_opacity!(gui, m1, 0.5)
        GUI._set_hidden!(gui, m3, true)
        g = GUI._group!(gui, s)
        @test g isa ObjectGroup
        @test GUI._label(gui, m1) == "M1"
        @test m3 in gui.objects.hidden
        @test all(p -> !p.visible[], render_plots(GUI._child_handle(ctrl.h, m3)))
        @test GUI._opacity(gui, m1) ≈ 0.5
        @test any(p -> GUI._plot_opacity(p) < 0.99, GUI._object_plots(ctrl.h, m1))
        @test ctrl.init_poses[m2] == init_m2
        @test haskey(ctrl.init_poses, g)
        # the label of the group is dropped by ungrouping, the members keep theirs
        gui.labels[g] = "G"
        @test GUI._ungroup!(gui, g)
        @test !haskey(gui.labels, g)
        @test GUI._label(gui, m1) == "M1"
        @test m3 in gui.objects.hidden
        @test all(p -> !p.visible[], render_plots(GUI._child_handle(ctrl.h, m3)))
        @test GUI._opacity(gui, m1) ≈ 0.5
        @test any(p -> GUI._plot_opacity(p) < 0.99, GUI._object_plots(ctrl.h, m1))
        @test ctrl.init_poses[m2] == init_m2
        # the hidden member is not selected
        @test ctrl.selected[] isa GUI._MultiSelection && ctrl.selected[].objects == Any[m1, m2]
        # undo groups again, with the label of the group
        @test GUI._undo!(ctrl)
        @test GUI._label(gui, g) == "G"
        close(gui)
    end

    @testset "refused, $layout" for layout in (:compact, :app)
        m1, m2, m3, m4, m5 = _mirror(), _mirror(0.3), _mirror(0.5), _mirror(0.7), _mirror(0.9)
        sg = ObjectGroup([m4, m5])
        a, b = System([m1, m2, sg]), System([_mirror(; x = 0.3)])
        static = StaticSystem([_mirror(; x = 0.6)])
        beam = _beam()
        gui = _live_view(a => beam, b => _beam(0.3), static => _beam(0.6); layout,
            movable_sources = true)
        ctrl = gui.controls
        mb, ms = only(b.objects), only(static.objects)
        plane = GUI.LiveClipPlane([0, 0, 0], [0, 1, 0], 0.1)
        n = length(ctrl.undo_stack)
        objects = copy(a.objects)
        for (sel, text) in ((m1, "several"), (nothing, "several"),
            (GUI._MultiSelection(Any[m1, beam]), "source"),
            (GUI._MultiSelection(Any[m1, plane]), "clip plane"),
            (GUI._MultiSelection(Any[m1, ms]), "StaticSystem"),
            (GUI._MultiSelection(Any[m1, m4]), "not parts of the same group"),
            (GUI._MultiSelection(Any[m1, mb]), "different systems"))
            @test isnothing(GUI._group!(gui, sel))
            @test occursin(text, gui.status.text[])
        end
        @test length(ctrl.undo_stack) == n
        @test a.objects == objects
        @test isempty(gui.components.groups)
        # a group of the script is grouped with another object, but not ungrouped
        g = GUI._group!(gui, GUI._MultiSelection(Any[m1, sg]))
        @test g isa ObjectGroup && BMO.objects(g) == (m1, sg)
        @test !GUI._ungroup!(gui, sg)
        @test occursin("script", gui.status.text[])
        close(gui)
    end

    @testset "ungrouping a group inside a group, $layout" for layout in (:compact, :app)
        m1, m2, m3 = _mirror(), _mirror(0.3), _mirror(0.5)
        sys = System([m1, m2, m3])
        gui = _live_view(sys => _beam(); layout)
        ctrl = gui.controls
        wait_solve(gui)
        g1 = _group_of_selection!(gui, [m1, m2])
        g2 = _group_of_selection!(gui, [g1, m3])
        @test g2 isa ObjectGroup && BMO.objects(g2) == (g1, m3)
        gui.labels[g2] = "G2"
        # a rotation of the outer group first: the poses are no longer the initial ones
        rotate3d!(gui, g2, [0.0, 0, 1], 0.3)
        wait_solve(gui)
        poses = Dict(m => (Vector{Float64}(position(m)), Matrix{Float64}(BMO.orientation(m))) for m in (m1, m2, m3))
        pivot2 = Vector{Float64}(position(g2))
        name2 = get(gui.objects.names, g2, nothing)
        n = length(ctrl.undo_stack)

        @test GUI._ungroup!(gui, g1)
        @test length(ctrl.undo_stack) == n + 1
        new = only(filter(o -> o isa ObjectGroup, sys.objects))
        @test new !== g1 && new !== g2
        @test length(sys.objects) == 1
        @test BMO.objects(new) == (m1, m2, m3)
        @test GUI._is_window_group(gui, new)
        @test !GUI._is_window_group(gui, g1) && !GUI._is_window_group(gui, g2)
        @test !_in(g2, sys.objects) && !_in(g1, sys.objects)
        @test GUI._label(gui, new) == "G2"
        @test get(gui.labels, new, nothing) == "G2" && !haskey(gui.labels, g2)
        @test get(gui.objects.names, new, nothing) == name2
        @test _close(position(new), pivot2)
        @test norm(Matrix{Float64}(BMO.orientation(new)) .- Matrix{Float64}(I, 3, 3)) < 1e-9
        @test ctrl.selected[] === new
        @test occursin("ungrouped", gui.status.text[])
        @test all(m -> _same_pose(m, poses[m]), (m1, m2, m3))
        @test all(m -> _drawn(gui, m) == 1, (m1, m2, m3))
        @test all(m -> _top(gui, m) === new, (m1, m2, m3))
        wait_solve(gui)
        @test isnothing(gui.trace.error)
        @test all(m -> _same_pose(m, poses[m]), (m1, m2, m3))

        # the new group moves as one
        translate3d!(gui, new, [0.0, 0, 0.01])
        @test _close(position(m1), poses[m1][1] .+ [0, 0, 0.01])
        translate3d!(gui, new, [0.0, 0, -0.01])
        wait_solve(gui)
        @test all(m -> _same_pose(m, poses[m]), (m1, m2, m3))

        # undo (after the two moves, entries of their own): the old groups with their label,
        # redo: the same new group
        n = length(ctrl.undo_stack)
        @test GUI._undo!(ctrl) && GUI._undo!(ctrl)
        @test GUI._undo!(ctrl)
        @test length(ctrl.undo_stack) == n - 3
        @test _in(g2, sys.objects) && !_in(new, sys.objects) && length(sys.objects) == 1
        @test BMO.objects(g2) == (g1, m3) && BMO.objects(g1) == (m1, m2)
        @test GUI._is_window_group(gui, g1) && GUI._is_window_group(gui, g2)
        @test !GUI._is_window_group(gui, new)
        @test GUI._label(gui, g2) == "G2"
        @test _top(gui, m1) === g2 && _top(gui, m3) === g2
        @test all(m -> _same_pose(m, poses[m]), (m1, m2, m3))
        @test all(m -> _drawn(gui, m) == 1, (m1, m2, m3))
        @test GUI._redo!(ctrl)
        @test GUI._redo!(ctrl) && GUI._redo!(ctrl)
        @test length(sys.objects) == 1 && sys.objects[1] === new
        @test BMO.objects(new) == (m1, m2, m3) && GUI._is_window_group(gui, new)
        @test !GUI._is_window_group(gui, g2) && GUI._label(gui, new) == "G2"
        @test ctrl.selected[] === new
        @test all(m -> _same_pose(m, poses[m]), (m1, m2, m3))
        @test all(m -> _drawn(gui, m) == 1, (m1, m2, m3))
        wait_solve(gui)
        @test isnothing(gui.trace.error)
        # the dissolved group is gone: ungrouping the new one works as for any top-level group
        @test GUI._ungroup!(gui, new)
        @test _in(m1, sys.objects) && _in(m2, sys.objects) && _in(m3, sys.objects)
        @test all(m -> _same_pose(m, poses[m]), (m1, m2, m3))
        close(gui)
    end

    @testset "ungrouping a group inside two groups, $layout" for layout in (:compact, :app)
        m1, m2, m3, m4 = _mirror(), _mirror(0.3), _mirror(0.5), _mirror(0.7)
        sys = System([m1, m2, m3, m4])
        gui = _live_view(sys => _beam(); layout)
        ctrl = gui.controls
        wait_solve(gui)
        g1 = _group_of_selection!(gui, [m1, m2])
        g2 = _group_of_selection!(gui, [g1, m3])
        g3 = _group_of_selection!(gui, [g2, m4])
        @test BMO.objects(g3) == (g2, m4)
        gui.labels[g2] = "G2"
        gui.labels[g3] = "G3"
        rotate3d!(gui, g3, [0.0, 0, 1], 0.2)
        wait_solve(gui)
        poses = Dict(m => (Vector{Float64}(position(m)), Matrix{Float64}(BMO.orientation(m))) for m in (m1, m2, m3, m4))
        pivot2, pivot3 = Vector{Float64}(position(g2)), Vector{Float64}(position(g3))
        n = length(ctrl.undo_stack)

        @test GUI._ungroup!(gui, g1)
        @test length(ctrl.undo_stack) == n + 1
        @test length(sys.objects) == 1
        top = sys.objects[1]
        @test top isa ObjectGroup && top !== g3 && top !== g2
        @test length(BMO.objects(top)) == 2 && BMO.objects(top)[2] === m4
        mid = BMO.objects(top)[1]
        @test mid isa ObjectGroup && mid !== g2 && mid !== g1
        @test BMO.objects(mid) == (m1, m2, m3)
        @test GUI._is_window_group(gui, top) && GUI._is_window_group(gui, mid)
        @test !any(g -> GUI._is_window_group(gui, g), (g1, g2, g3))
        @test GUI._label(gui, top) == "G3" && GUI._label(gui, mid) == "G2"
        @test _close(position(top), pivot3) && _close(position(mid), pivot2)
        @test norm(Matrix{Float64}(BMO.orientation(top)) .- Matrix{Float64}(I, 3, 3)) < 1e-9
        @test norm(Matrix{Float64}(BMO.orientation(mid)) .- Matrix{Float64}(I, 3, 3)) < 1e-9
        @test GUI._part_parent(gui, mid) === top
        @test ctrl.selected[] === top
        @test occursin("ungrouped", gui.status.text[])
        @test all(m -> _same_pose(m, poses[m]), (m1, m2, m3, m4))
        @test all(m -> _drawn(gui, m) == 1, (m1, m2, m3, m4))
        @test all(m -> _top(gui, m) === top, (m1, m2, m3, m4))

        @test GUI._undo!(ctrl)
        @test length(sys.objects) == 1 && sys.objects[1] === g3
        @test BMO.objects(g3) == (g2, m4) && BMO.objects(g2) == (g1, m3) && BMO.objects(g1) == (m1, m2)
        @test all(g -> GUI._is_window_group(gui, g), (g1, g2, g3))
        @test !GUI._is_window_group(gui, top) && !GUI._is_window_group(gui, mid)
        @test GUI._label(gui, g2) == "G2" && GUI._label(gui, g3) == "G3"
        @test all(m -> _same_pose(m, poses[m]), (m1, m2, m3, m4))
        @test all(m -> _drawn(gui, m) == 1, (m1, m2, m3, m4))
        @test GUI._redo!(ctrl)
        @test length(sys.objects) == 1 && sys.objects[1] === top
        @test BMO.objects(top) == (mid, m4) && BMO.objects(mid) == (m1, m2, m3)
        @test GUI._is_window_group(gui, top) && GUI._is_window_group(gui, mid)
        @test GUI._label(gui, top) == "G3" && GUI._label(gui, mid) == "G2"
        @test all(m -> _same_pose(m, poses[m]), (m1, m2, m3, m4))
        @test all(m -> _drawn(gui, m) == 1, (m1, m2, m3, m4))
        wait_solve(gui)
        @test isnothing(gui.trace.error)
        close(gui)
    end

    @testset "objects without a system, $layout" for layout in (:compact, :app)
        h1, h2 = _mirror(0.5; x = 0.5), _mirror(0.6; x = 0.5)
        sys = System([_mirror()])
        gui = _live_view(sys => _beam(); layout, extras = [h1, h2])
        g = _group_of_selection!(gui, [h1, h2])
        @test g isa ObjectGroup
        extras = rendered(gui.extras).objects
        @test _in(g, extras) && !_in(h1, extras)
        @test length(sys.objects) == 1
        @test _top(gui, h1) === g
        @test GUI._ungroup!(gui, g)
        @test _in(h1, extras) && _in(h2, extras) && !_in(g, extras)
        close(gui)
    end

    @testset "removing a group made in the window, $layout" for layout in (:compact, :app)
        fx = _fixture(; layout)
        gui, sys, m, pd = fx.gui, fx.sys, fx.m, fx.pd
        ctrl = gui.controls
        g = _group_of_selection!(gui, [m, pd])
        @test GUI._delete_selected!(gui, g)
        @test !_in(g, sys.objects) && !GUI._is_window_group(gui, g)
        @test _drawn(gui, m) == 0
        # export_changes lists its members as removed
        @test _in(m, gui.components.removed) && _in(pd, gui.components.removed)
        @test !_in(g, gui.components.removed) && isempty(gui.components.added)
        @test GUI._undo!(ctrl)
        @test _in(g, sys.objects) && GUI._is_window_group(gui, g)
        @test isempty(gui.components.removed) && gui.components.added == Any[g]
        @test _top(gui, m) === g
        wait_solve(gui)
        @test BMO.hit_count(pd) == 1
        @test GUI._ungroup!(gui, g)
        @test _in(m, sys.objects) && _in(pd, sys.objects)
        close(gui)

        # a group of added components: removing it forgets them, undo adds them again
        fx = _fixture(; layout)
        gui, sys = fx.gui, fx.sys
        a1, a2 = _mirror(0.3; x = 0.2), _mirror(0.4; x = 0.2)
        add_component!(gui, a1; system = sys, code = "RoundPlanoMirror(25e-3, 5e-3)")
        add_component!(gui, a2; system = sys, code = "RoundPlanoMirror(25e-3, 5e-3)")
        g = _group_of_selection!(gui, [a1, a2])
        @test gui.components.added == Any[a1, a2, g]
        @test GUI._delete_selected!(gui, g)
        @test isempty(gui.components.added) && isempty(gui.components.removed)
        @test GUI._undo!(gui.controls)
        @test gui.components.added == Any[a1, a2, g]
        @test gui.components.origin[a1].code == "RoundPlanoMirror(25e-3, 5e-3)"
        @test GUI._is_window_group(gui, g)
        close(gui)
    end

    @testset "linked view follows, $layout" for layout in (:compact, :app)
        fx = _fixture(; layout)
        gui, sys, m, pd = fx.gui, fx.sys, fx.m, fx.pd
        new = open_system(gui, sys; display = false)
        g = _group_of_selection!(gui, [m, pd])
        @test GUI._is_window_group(new, g)
        @test _top(new, m) === g && _drawn(new, m) == 1
        @test GUI._label(new, m) == GUI._label(gui, m)
        @test isempty(new.components.removed) && new.components.added == Any[g]
        wait_solve(gui)
        # ungrouped in the linked view: the first one follows
        select!(new, g)
        @test GUI._ungroup!(new, g)
        @test _in(m, sys.objects) && !_in(g, sys.objects)
        @test !GUI._is_window_group(gui, g) && _top(gui, m) === m && _drawn(gui, m) == 1
        wait_solve(new)
        # undo in the linked view groups again in both
        @test GUI._undo!(new.controls)
        @test GUI._is_window_group(gui, g) && _top(gui, m) === g
        # a view opened on a system with a group made in the window ungroups it
        third = open_system(gui, sys; display = false)
        @test GUI._is_window_group(third, g) && third.components.added == Any[g]
        @test !haskey(third.components.start_systems, g) && third.components.start_systems[m] == Any[sys]
        @test GUI._ungroup!(third, g)
        @test _top(gui, m) === m && _top(new, m) === m
        close(third)
        close(new)
        close(gui)
    end

    # the poses of the mirrors, to compare after grouping, undo and redo
    _poses(ms) = Dict(m => (Vector{Float64}(position(m)), Matrix{Float64}(BMO.orientation(m))) for m in ms)
    _identity(g) = norm(Matrix{Float64}(BMO.orientation(g)) .- Matrix{Float64}(I, 3, 3)) < 1e-9

    @testset "grouping within a group made in the window, $layout" for layout in (:compact, :app)
        m1, m2, m3 = _mirror(), _mirror(0.3), _mirror(0.5)
        sys = System([m1, m2, m3])
        gui = _live_view(sys => _beam(); layout)
        ctrl = gui.controls
        wait_solve(gui)
        g1 = _group_of_selection!(gui, [m1, m2, m3])
        gui.labels[g1] = "G1"
        rotate3d!(gui, g1, [0.0, 0, 1], 0.3)
        wait_solve(gui)
        poses = _poses((m1, m2, m3))
        pivot1 = Vector{Float64}(position(g1))
        name1 = get(gui.objects.names, g1, nothing)
        n = length(ctrl.undo_stack)

        s = _group_of_selection!(gui, [m1, m2])
        @test s isa ObjectGroup && BMO.objects(s) == (m1, m2)
        @test length(ctrl.undo_stack) == n + 1
        @test length(sys.objects) == 1
        new = sys.objects[1]
        @test new isa ObjectGroup && new !== g1 && new !== s
        @test BMO.objects(new) == (s, m3)
        @test GUI._is_window_group(gui, new) && GUI._is_window_group(gui, s)
        @test !GUI._is_window_group(gui, g1)
        @test isnothing(gui.components.groups[new].replaces)
        @test GUI._label(gui, new) == "G1" && get(gui.labels, new, nothing) == "G1" && !haskey(gui.labels, g1)
        @test get(gui.objects.names, new, nothing) == name1
        @test _close(position(new), pivot1) && _identity(new)
        @test _close(position(s), (poses[m1][1] .+ poses[m2][1]) ./ 2) && _identity(s)
        @test GUI._part_parent(gui, s) === new
        @test ctrl.selected[] === s
        @test occursin("grouped", gui.status.text[])
        @test all(m -> _same_pose(m, poses[m]), (m1, m2, m3))
        @test all(m -> _drawn(gui, m) == 1, (m1, m2, m3))
        @test all(m -> _top(gui, m) === new, (m1, m2, m3))
        wait_solve(gui)
        @test isnothing(gui.trace.error)

        # undo: the old group with its parts, redo: the same new groups
        @test GUI._undo!(ctrl)
        @test length(ctrl.undo_stack) == n
        @test length(sys.objects) == 1 && sys.objects[1] === g1
        @test BMO.objects(g1) == (m1, m2, m3)
        @test GUI._is_window_group(gui, g1)
        @test !GUI._is_window_group(gui, new) && !GUI._is_window_group(gui, s)
        @test GUI._label(gui, g1) == "G1"
        @test all(m -> _same_pose(m, poses[m]), (m1, m2, m3))
        @test all(m -> _drawn(gui, m) == 1, (m1, m2, m3))
        @test all(m -> _top(gui, m) === g1, (m1, m2, m3))
        @test GUI._redo!(ctrl)
        @test length(sys.objects) == 1 && sys.objects[1] === new
        @test BMO.objects(new) == (s, m3) && BMO.objects(s) == (m1, m2)
        @test GUI._is_window_group(gui, new) && GUI._is_window_group(gui, s) && !GUI._is_window_group(gui, g1)
        @test GUI._label(gui, new) == "G1"
        @test ctrl.selected[] === s
        @test all(m -> _same_pose(m, poses[m]), (m1, m2, m3))
        @test all(m -> _drawn(gui, m) == 1, (m1, m2, m3))
        wait_solve(gui)
        @test isnothing(gui.trace.error)

        # the subgroup moves on its own
        translate3d!(gui, s, [0.0, 0, 0.01])
        @test _close(position(m1), poses[m1][1] .+ [0, 0, 0.01])
        @test _close(position(m3), poses[m3][1])
        close(gui)
    end

    @testset "grouping within a group of the script, $layout" for layout in (:compact, :app)
        m1, m2, m3 = _mirror(), _mirror(0.3), _mirror(0.5)
        sg = ObjectGroup([m1, m2, m3])
        sys = System([sg])
        gui = _live_view(sys => _beam(); layout)
        ctrl = gui.controls
        wait_solve(gui)
        gui.labels[sg] = "SG"
        poses = _poses((m1, m2, m3))
        pivot0 = Vector{Float64}(position(sg))
        name0 = get(gui.objects.names, sg, nothing)
        added = copy(gui.components.added)
        n = length(ctrl.undo_stack)

        s = _group_of_selection!(gui, [m1, m2])
        @test s isa ObjectGroup && BMO.objects(s) == (m1, m2)
        @test length(ctrl.undo_stack) == n + 1
        @test length(sys.objects) == 1
        new = sys.objects[1]
        @test new isa ObjectGroup && new !== sg && BMO.objects(new) == (s, m3)
        @test GUI._is_window_group(gui, new) && GUI._is_window_group(gui, s)
        @test gui.components.groups[new].replaces === sg
        @test isnothing(gui.components.groups[s].replaces)
        @test !GUI._is_window_group(gui, sg)
        @test GUI._label(gui, new) == "SG"
        @test get(gui.objects.names, new, nothing) == name0
        @test _close(position(new), pivot0) && _identity(new)
        @test ctrl.selected[] === s
        @test all(m -> _same_pose(m, poses[m]), (m1, m2, m3))
        @test all(m -> _drawn(gui, m) == 1, (m1, m2, m3))
        @test all(m -> _top(gui, m) === new, (m1, m2, m3))
        wait_solve(gui)
        @test isnothing(gui.trace.error)

        # undo: the group of the script is in the system as it was, no group made in the window
        @test GUI._undo!(ctrl)
        @test length(ctrl.undo_stack) == n
        @test length(sys.objects) == 1 && sys.objects[1] === sg
        @test BMO.objects(sg) == (m1, m2, m3)
        @test !GUI._is_window_group(gui, sg) && !GUI._is_window_group(gui, new) && !GUI._is_window_group(gui, s)
        @test isempty(gui.components.groups)
        @test !_in(sg, gui.components.added) && !_in(new, gui.components.added) && !_in(s, gui.components.added)
        @test gui.components.added == added
        @test !haskey(gui.components.start_systems, new)
        @test GUI._label(gui, sg) == "SG"
        @test all(m -> _same_pose(m, poses[m]), (m1, m2, m3))
        @test all(m -> _drawn(gui, m) == 1, (m1, m2, m3))
        @test all(m -> _top(gui, m) === sg, (m1, m2, m3))
        @test GUI._redo!(ctrl)
        @test length(sys.objects) == 1 && sys.objects[1] === new
        @test BMO.objects(new) == (s, m3) && gui.components.groups[new].replaces === sg
        @test ctrl.selected[] === s
        @test all(m -> _same_pose(m, poses[m]), (m1, m2, m3))
        wait_solve(gui)
        @test isnothing(gui.trace.error)
        # and back once more
        @test GUI._undo!(ctrl)
        @test sys.objects[1] === sg && isempty(gui.components.groups)
        close(gui)
    end

    @testset "grouping within groups on three levels, $layout" for layout in (:compact, :app)
        for script in (false, true)
            m1, m2, m3, m4, m5 = _mirror(), _mirror(0.3), _mirror(0.5), _mirror(0.7), _mirror(0.9)
            if script
                inner = ObjectGroup([m1, m2, m3])
                outer = ObjectGroup([inner, m4, m5])
                sys = System([outer])
            else
                inner, outer = nothing, nothing
                sys = System([m1, m2, m3, m4, m5])
            end
            gui = _live_view(sys => _beam(); layout)
            ctrl = gui.controls
            wait_solve(gui)
            if !script
                inner = _group_of_selection!(gui, [m1, m2, m3])
                outer = _group_of_selection!(gui, [inner, m4, m5])
            end
            gui.labels[inner] = "IN"
            gui.labels[outer] = "OUT"
            rotate3d!(gui, outer, [0.0, 0, 1], 0.2)
            wait_solve(gui)
            ms = (m1, m2, m3, m4, m5)
            poses = _poses(ms)
            pivot_in, pivot_out = Vector{Float64}(position(inner)), Vector{Float64}(position(outer))
            n = length(ctrl.undo_stack)

            s = _group_of_selection!(gui, [m1, m2])
            @test s isa ObjectGroup && BMO.objects(s) == (m1, m2)
            @test length(ctrl.undo_stack) == n + 1
            @test length(sys.objects) == 1
            top = sys.objects[1]
            @test top isa ObjectGroup && top !== outer && length(BMO.objects(top)) == 3
            mid = BMO.objects(top)[1]
            @test mid isa ObjectGroup && mid !== inner && BMO.objects(top)[2:3] == (m4, m5)
            @test BMO.objects(mid) == (s, m3)
            @test all(g -> GUI._is_window_group(gui, g), (top, mid, s))
            @test !GUI._is_window_group(gui, inner) && !GUI._is_window_group(gui, outer)
            @test gui.components.groups[top].replaces === (script ? outer : nothing)
            @test gui.components.groups[mid].replaces === (script ? inner : nothing)
            @test GUI._label(gui, top) == "OUT" && GUI._label(gui, mid) == "IN"
            @test _close(position(top), pivot_out) && _close(position(mid), pivot_in)
            @test _identity(top) && _identity(mid) && _identity(s)
            @test GUI._part_parent(gui, s) === mid && GUI._part_parent(gui, mid) === top
            @test ctrl.selected[] === s
            @test all(m -> _same_pose(m, poses[m]), ms)
            @test all(m -> _drawn(gui, m) == 1, ms)
            @test all(m -> _top(gui, m) === top, ms)
            wait_solve(gui)
            @test isnothing(gui.trace.error)

            @test GUI._undo!(ctrl)
            @test length(ctrl.undo_stack) == n
            @test length(sys.objects) == 1 && sys.objects[1] === outer
            @test BMO.objects(outer) == (inner, m4, m5) && BMO.objects(inner) == (m1, m2, m3)
            @test !any(g -> GUI._is_window_group(gui, g), (top, mid, s))
            @test GUI._is_window_group(gui, inner) == !script && GUI._is_window_group(gui, outer) == !script
            @test GUI._label(gui, inner) == "IN" && GUI._label(gui, outer) == "OUT"
            @test all(m -> _same_pose(m, poses[m]), ms)
            @test all(m -> _drawn(gui, m) == 1, ms)
            @test GUI._redo!(ctrl)
            @test sys.objects[1] === top && BMO.objects(top)[1] === mid && BMO.objects(mid) == (s, m3)
            @test all(g -> GUI._is_window_group(gui, g), (top, mid, s))
            @test ctrl.selected[] === s
            @test all(m -> _same_pose(m, poses[m]), ms)
            wait_solve(gui)
            @test isnothing(gui.trace.error)
            close(gui)
        end
    end

    @testset "grouping within a group refused, $layout" for layout in (:compact, :app)
        m1, m2, m3, m4, m5 = _mirror(), _mirror(0.3), _mirror(0.5), _mirror(0.7), _mirror(0.9)
        g1 = ObjectGroup([m1, m2])
        g2 = ObjectGroup([m3, m4])
        sys = System([g1, g2, m5])
        gui = _live_view(sys => _beam(); layout)
        ctrl = gui.controls
        wait_solve(gui)
        n = length(ctrl.undo_stack)
        objects = copy(sys.objects)
        for (sel, text) in ((GUI._MultiSelection(Any[m1, m3]), "not parts of the same group"),
            (GUI._MultiSelection(Any[m1, m5]), "not parts of the same group"),
            (GUI._MultiSelection(Any[m1, m2]), "all parts"),
            (m1, "several"))
            @test isnothing(GUI._group!(gui, sel))
            @test occursin(text, gui.status.text[])
        end
        @test length(ctrl.undo_stack) == n
        @test sys.objects == objects
        @test isempty(gui.components.groups)
        @test BMO.objects(g1) == (m1, m2) && BMO.objects(g2) == (m3, m4)
        close(gui)
    end

    @testset "linked view follows grouping within a group, $layout" for layout in (:compact, :app)
        m1, m2, m3 = _mirror(), _mirror(0.3), _mirror(0.5)
        sg = ObjectGroup([m1, m2, m3])
        sys = System([sg])
        gui = _live_view(sys => _beam(); layout)
        wait_solve(gui)
        new = open_system(gui, sys; display = false)
        ms = (m1, m2, m3)
        _tops(v) = [GUI._top_level(v.controls.h, m) for m in ms]
        @test all(t -> t === sg, _tops(new))

        s = _group_of_selection!(gui, [m1, m2])
        top = sys.objects[1]
        @test top !== sg && BMO.objects(top) == (s, m3)
        @test all(t -> t === top, _tops(new)) && all(t -> t === top, _tops(gui))
        @test GUI._is_window_group(new, top) && GUI._is_window_group(new, s)
        @test !GUI._is_window_group(new, sg)
        @test all(m -> _drawn(new, m) == 1, ms)
        wait_solve(gui)

        @test GUI._undo!(gui.controls)
        @test sys.objects[1] === sg
        @test all(t -> t === sg, _tops(new)) && all(t -> t === sg, _tops(gui))
        @test !GUI._is_window_group(new, top) && !GUI._is_window_group(new, s)
        @test all(m -> _drawn(new, m) == 1, ms)
        @test GUI._redo!(gui.controls)
        @test sys.objects[1] === top
        @test all(t -> t === top, _tops(new)) && all(t -> t === top, _tops(gui))
        @test GUI._is_window_group(new, top) && GUI._is_window_group(new, s)
        @test all(m -> _drawn(new, m) == 1, ms)
        wait_solve(gui)
        @test isnothing(gui.trace.error)
        close(new)
        close(gui)
    end
end

end
