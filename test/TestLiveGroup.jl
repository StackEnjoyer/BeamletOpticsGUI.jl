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
            (GUI._MultiSelection(Any[m1, m4]), "part of"),
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
end

end
