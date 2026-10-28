module TestLiveGroupPivot

using GLMakie, BeamletOptics, BeamletOpticsGUI
using Makie
using LinearAlgebra: norm, normalize
using Test

const BMO = BeamletOptics
const GUI = BeamletOpticsGUI

@testset "Pivot of groups and selections of several" begin

    # Each change is solved at once, see `TestLiveView.jl`; no card of a detector is pinned at start
    _live_view(args...; kwargs...) =
        live_view(args...; merge((; trace_budget = Inf, throttle = false, detectors = [],
            catalog = CatalogEntry[], progress_delay = Inf), kwargs)...)

    _mirror(at) = (m = RoundPlanoMirror(25e-3, 5e-3); zrotate3d!(m, deg2rad(45)); translate3d!(m, at); m)

    # A lens, a group of the script of two mirrors (its pivot at the origin, as BeamletOptics starts
    # it) and a detector
    function _fixture(; layout = :compact, kwargs...)
        lens = ThinLens(100e-3, -100e-3, 25e-3, 1.5)
        translate3d!(lens, [0, 0.05, 0])
        m1, m2 = _mirror([0, 0.1, 0]), _mirror([0.1, 0.1, 0])
        arm = ObjectGroup([m1, m2])
        pd = Detector(5e-3)
        translate3d!(pd, [0.1, 0.2, 0])
        sys = System([lens, arm, pd])
        gui = _live_view(sys => Beam([0.0, 0, 0], [0.0, 1, 0]); layout,
            labels = Dict(lens => "lens", m1 => "m1", m2 => "m2", arm => "arm", pd => "pd"), kwargs...)
        set_view(gui.ax, [0.05, -0.3, 0.4], [0.05, 0.1, 0.0], [0.0, 0, 1])
        return (; gui, sys, lens, m1, m2, arm, pd)
    end

    _close(a, b; atol = 1e-12) = norm(Vector{Float64}(a) .- Vector{Float64}(b)) < atol
    _pose(obj) = (Vector{Float64}(position(obj)), Matrix{Float64}(BMO.orientation(obj)))
    _same_pose(obj, pose; atol = 1e-12) = _close(position(obj), pose[1]; atol) &&
        norm(Matrix{Float64}(BMO.orientation(obj)) .- pose[2]) < atol
    _card(gui) = gui isa GUI.AppView ? gui.layout.inspector.card : gui.cards.selection
    function _select!(gui, sel)
        select!(gui, sel)
        GUI._update_cards!(gui)
        GUI._update_inspector!(gui; force = true)
        return gui.controls.selected[]
    end
    _marker(gui) = (GUI._update_selection_pivot!(gui); gui.components.pivot_marker)
    _mouse!(gui, px) = (events(gui.ax.scene).mouseposition[] = (Float64(px[1]), Float64(px[2])))
    _press!(gui) = (events(gui.ax.scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.press))
    _release!(gui) = (events(gui.ax.scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.release))
    _key!(gui, key) = (events(gui.ax.scene).keyboardbutton[] = Makie.KeyEvent(key, Keyboard.press))

    @testset "marker, $layout" for layout in (:compact, :app)
        fx = _fixture(; layout)
        gui, arm = fx.gui, fx.arm
        _select!(gui, arm)
        m = _marker(gui)
        @test m.dot.visible[] && m.line.visible[]
        at = GUI._view_px(gui, position(arm))
        @test Makie.translation(m.dot)[] ≈ Vec3f(at..., 0)
        @test m.line[1][][1] ≈ at
        @test m.line[1][][2] ≈ GUI._view_px(gui, gui.controls.gizmo_origin)
        # follows a move of the group
        translate3d!(gui, arm, [0.0, 0, 0.01])
        @test Makie.translation(_marker(gui).dot)[] ≈ Vec3f(GUI._view_px(gui, position(arm))..., 0)
        # also of a selection of several, at its center
        s = _select!(gui, [fx.lens, fx.pd])
        @test _marker(gui).dot.visible[]
        @test Makie.translation(m.dot)[] ≈ Vec3f(GUI._view_px(gui, position(s))..., 0)
        # not for a single component, without a selection and in the spectator mode
        _select!(gui, fx.lens)
        @test !_marker(gui).dot.visible[] && !m.line.visible[]
        _select!(gui, nothing)
        @test !_marker(gui).dot.visible[]
        _select!(gui, arm)
        spectator!(gui, true)
        @test !_marker(gui).dot.visible[]
        spectator!(gui, false)
    end

    @testset "row of the card, undo and reset, $layout" for layout in (:compact, :app)
        fx = _fixture(; layout)
        gui, arm, m1, m2 = fx.gui, fx.arm, fx.m1, fx.m2
        ctrl = gui.controls
        start = (_pose(m1), _pose(m2))
        @test _close(position(arm), zeros(3))
        _select!(gui, arm)
        card = _card(gui)
        @test GUI._card_widget(card, :pivot_x).displayed_string[] == "0.0"
        n = length(ctrl.undo_stack)

        # moved, then the pivot by its boxes: the mirrors stay
        translate3d!(gui, arm, [0.0, 0, 0.01])
        moved = (_pose(m1), _pose(m2))
        GUI._card_widget(card, :pivot_x).stored_string[] = "100"
        GUI._card_widget(card, :pivot_y).stored_string[] = "100"
        @test _close(position(arm), [0.1, 0.1, 0.01])
        @test _same_pose(m1, moved[1]) && _same_pose(m2, moved[2])
        @test length(ctrl.undo_stack) == n + 3
        @test GUI._card_widget(card, :pivot_x).displayed_string[] == "100.0"
        # a turn is about the new pivot: m2 is at the pivot and stays
        rotate3d!(gui, arm, [0.0, 0, 1], π / 2)
        @test _close(position(m2), [0.1, 0.1, 0.01]; atol = 1e-9)
        @test _close(position(m1), [0.1, 0.0, 0.01]; atol = 1e-9)
        turned = (_pose(m1), _pose(m2))

        # the reset of the pose of the group (Backspace, one gesture): the mirrors at the start, the
        # pivot where it is in them
        _key!(gui, Keyboard.backspace)
        @test _same_pose(m1, start[1]; atol = 1e-9) && _same_pose(m2, start[2]; atol = 1e-9)
        @test _close(position(arm), [0.1, 0.1, 0.0]; atol = 1e-9)
        GUI._undo!(ctrl)
        @test _same_pose(m1, turned[1]; atol = 1e-9)

        # undo of the turn, of the two pivots and of the move
        @test GUI._undo!(ctrl)
        @test _same_pose(m1, moved[1]; atol = 1e-9) && _same_pose(m2, moved[2]; atol = 1e-9)
        @test GUI._undo!(ctrl) && GUI._undo!(ctrl)
        @test _close(position(arm), [0.0, 0, 0.01]; atol = 1e-9)
        @test _same_pose(m1, moved[1]; atol = 1e-9)
        @test GUI._undo!(ctrl)
        @test _same_pose(m1, start[1]; atol = 1e-9) && _same_pose(m2, start[2]; atol = 1e-9)
        @test _close(position(arm), zeros(3); atol = 1e-9)
        @test isempty(gui.components.pivots)
        # redo of all of them
        foreach(_ -> @test(GUI._redo!(ctrl)), 1:4)
        @test _same_pose(m1, turned[1]; atol = 1e-9) && _same_pose(m2, turned[2]; atol = 1e-9)
        @test _close(position(arm), [0.1, 0.1, 0.01]; atol = 1e-9)
        @test ctrl.selected[] === arm

        # an invalid input changes nothing
        GUI._card_widget(card, :pivot_z).stored_string[] = "a"
        @test occursin("invalid input", gui.status.text[])
        @test _close(position(arm), [0.1, 0.1, 0.01]; atol = 1e-9)

        # "center": the center of the box around the mirrors
        GUI._center_pivot!(gui, arm)
        bb = GUI._selection_bbox(ctrl, arm, GUI._object_plots(ctrl.h, arm))
        @test _close(position(arm), minimum(bb) .+ Makie.widths(bb) ./ 2; atol = 1e-9)
        @test _same_pose(m1, turned[1]; atol = 1e-12)
    end

    @testset "pick, $layout" for layout in (:compact, :app)
        fx = _fixture(; layout)
        gui, arm, m1, m2 = fx.gui, fx.arm, fx.m1, fx.m2
        ctrl = gui.controls
        _select!(gui, arm)
        P1 = Vector{Float64}(position(m1))
        GUI._start_pivot_pick!(gui, arm)
        @test gui.components.pivot_pick === arm
        @test GUI._card_widget(_card(gui), :pivot_pick).label[] == "Esc"
        # a click on a part sets the pivot to its position, the group stays selected
        GUI._pick_pivot!(gui, m2)
        @test isnothing(gui.components.pivot_pick)
        @test _close(position(arm), position(m2))
        @test ctrl.selected[] === arm
        @test GUI._card_widget(_card(gui), :pivot_pick).label[] == "pick"
        # selected from the tree or the menu while picked: the part is not selected
        GUI._start_pivot_pick!(gui, arm)
        GUI._select!(gui, m1)
        @test ctrl.selected[] === arm && _close(position(arm), P1)
        # something else ends the pick without a change
        GUI._start_pivot_pick!(gui, arm)
        GUI._pick_pivot!(gui, fx.lens)
        @test isnothing(gui.components.pivot_pick) && _close(position(arm), P1)
        # Esc, a second click on "pick" and another selection end it
        GUI._start_pivot_pick!(gui, arm)
        _key!(gui, Keyboard.escape)
        @test isnothing(gui.components.pivot_pick) && ctrl.selected[] === arm
        GUI._start_pivot_pick!(gui, arm)
        GUI._start_pivot_pick!(gui, arm)
        @test isnothing(gui.components.pivot_pick)
        GUI._start_pivot_pick!(gui, arm)
        _select!(gui, fx.lens)
        @test isnothing(gui.components.pivot_pick)
        # a component has no pivot of its own
        GUI._start_pivot_pick!(gui, fx.lens)
        @test isnothing(gui.components.pivot_pick)
        @test occursin("no pivot of its own", gui.status.text[])
    end

    @testset "drag of the dot" begin
        fx = _fixture()
        gui, arm, m1, m2 = fx.gui, fx.arm, fx.m1, fx.m2
        ctrl = gui.controls
        GUI._set_pivot!(gui, arm, [0.05, 0.1, 0.0])
        _select!(gui, arm)
        n = length(ctrl.undo_stack)
        poses = (_pose(m1), _pose(m2))
        eye = Vector{Float64}(cameracontrols(gui.ax.scene).eyeposition[])
        at = GUI._view_px(gui, position(arm))
        _mouse!(gui, at)
        @test GUI._pivot_hit(gui)
        _press!(gui)
        @test !isnothing(gui.components.pivot_marker.drag)
        _mouse!(gui, at .+ (30, 0))
        _mouse!(gui, at .+ (40, 10))
        _release!(gui)
        @test isnothing(gui.components.pivot_marker.drag)
        # the pivot under the cursor, in the plane of the view through it; nothing else moved
        @test GUI._view_px(gui, position(arm)) ≈ at .+ (40, 10) atol = 0.5
        @test !_close(position(arm), [0.05, 0.1, 0.0]; atol = 1e-6)
        @test _same_pose(m1, poses[1]) && _same_pose(m2, poses[2])
        @test ctrl.selected[] === arm
        @test Vector{Float64}(cameracontrols(gui.ax.scene).eyeposition[]) ≈ eye
        # one action of the history
        @test length(ctrl.undo_stack) == n + 1
        GUI._undo!(ctrl)
        @test _close(position(arm), [0.05, 0.1, 0.0]; atol = 1e-12)
    end

    @testset "selection of several" begin
        fx = _fixture()
        gui, lens, pd = fx.gui, fx.lens, fx.pd
        ctrl = gui.controls
        s = _select!(gui, [lens, pd])
        @test GUI._card_widget(_card(gui), :pivot_y).displayed_string[] == string(round(1e3 * position(s)[2], digits = 6))
        poses = (_pose(lens), _pose(pd))
        GUI._card_widget(_card(gui), :pivot_x).stored_string[] = "0"
        GUI._card_widget(_card(gui), :pivot_y).stored_string[] = "200"
        @test _close(position(s), [0.0, 0.2, 0.0])
        @test _same_pose(lens, poses[1]) && _same_pose(pd, poses[2])
        # a turn about the new pivot
        GUI._change!(() -> rotate3d!(s, [0.0, 0, 1], π), ctrl, s)
        @test _close(position(pd), [-0.1, 0.2, 0.0]; atol = 1e-9)
        GUI._change!(() -> rotate3d!(s, [0.0, 0, 1], π), ctrl, s)
        # pick: one of its objects
        GUI._start_pivot_pick!(gui, s)
        GUI._pick_pivot!(gui, lens)
        @test _close(position(s), position(lens))
        # undo of the pivot
        GUI._undo!(ctrl)
        @test _close(position(s), [0.0, 0.2, 0.0])
        # a new selection starts at the mean again
        s2 = _select!(gui, [lens, pd])
        @test s2 !== s && _close(position(s2), (position(lens) .+ position(pd)) ./ 2)
    end

    @testset "scripting" begin
        fx = _fixture()
        gui, arm, m1 = fx.gui, fx.arm, fx.m1
        ctrl = gui.controls
        n = length(ctrl.undo_stack)
        set_pivot3d!(gui, arm, position(m1))
        @test _close(position(arm), position(m1))
        @test length(ctrl.undo_stack) == n + 1
        @test_throws ArgumentError set_pivot3d!(gui, ObjectGroup([_mirror([0.0, 0, 0])]), [0.0, 0, 0])
    end

    @testset "linked view" begin
        fx = _fixture()
        gui, sys, arm, m1, m2 = fx.gui, fx.sys, fx.arm, fx.m1, fx.m2
        start = (_pose(m1), _pose(m2))
        new = open_system(gui, sys; display = false)
        translate3d!(new, arm, [0.0, 0, 0.01])
        set_pivot3d!(gui, arm, position(m2))
        @test _close(new.controls.init_poses[arm][1], [0.1, 0.1, 0.0]; atol = 1e-12)
        @test haskey(new.components.pivots, arm)
        # the undo of the move in the other view: the mirrors back where they were
        GUI._undo!(new.controls)
        @test _same_pose(m1, start[1]; atol = 1e-12) && _same_pose(m2, start[2]; atol = 1e-12)
        # the reset there
        rotate3d!(new, arm, [0.0, 0, 1], 0.3)
        GUI._reset_pose!(new.controls, arm)
        @test _same_pose(m1, start[1]; atol = 1e-9) && _same_pose(m2, start[2]; atol = 1e-9)
    end

    @testset "export_changes" begin
        script = """
        m1 = RoundPlanoMirror(25e-3, 5e-3)
        zrotate3d!(m1, deg2rad(45))
        translate3d!(m1, [0, 0.1, 0])
        m2 = RoundPlanoMirror(25e-3, 5e-3)
        zrotate3d!(m2, deg2rad(45))
        translate3d!(m2, [0.1, 0.1, 0])
        lens = ThinLens(100e-3, -100e-3, 25e-3, 1.5)
        translate3d!(lens, [0, 0.05, 0])
        pd = Detector(5e-3)
        translate3d!(pd, [0.1, 0.2, 0])
        arm = ObjectGroup([m1, m2])
        system = System([lens, arm, pd])
        """
        _run(code) = (mod = Module(); Core.eval(mod, :(using BeamletOptics)); include_string(mod, code); mod)
        mod = _run(script)
        v(name) = Core.eval(mod, name)
        arm, m1, m2, lens, pd = v(:arm), v(:m1), v(:m2), v(:lens), v(:pd)
        gui = _live_view(v(:system); labels = Dict(arm => "arm", m1 => "m1", m2 => "m2", lens => "lens", pd => "pd"))
        translate3d!(gui, arm, [0.0, 0, 0.01])
        set_pivot3d!(gui, arm, position(m2))
        rotate3d!(gui, arm, [0.0, 0, 1], 0.4)
        code = export_changes(gui; io = devnull)
        @test occursin("set_pivot3d!(arm, [", code)
        replay = _run(script * code)
        r(name) = Core.eval(replay, name)
        @test _close(position(r(:arm)), position(arm); atol = 1e-12)
        for (a, b) in ((r(:m1), m1), (r(:m2), m2))
            @test _same_pose(a, _pose(b); atol = 1e-12)
        end
        # later turns in the script are about the same pivot
        rotate3d!(r(:arm), [0.0, 0, 1], 0.2)
        rotate3d!(gui, arm, [0.0, 0, 1], 0.2)
        @test _same_pose(r(:m1), _pose(m1); atol = 1e-9)

        # a group made in the window with a moved pivot
        s = _select!(gui, [lens, pd])
        g = GUI._group!(gui, s)
        set_pivot3d!(gui, g, position(lens))
        rotate3d!(gui, g, [0.0, 0, 1], 0.3)
        replay = _run(script * export_changes(gui; io = devnull))
        @test _same_pose(r(:lens), _pose(lens); atol = 1e-9)
        @test _same_pose(r(:pd), _pose(pd); atol = 1e-9)
        groups = [o for o in Core.eval(replay, :system).objects if o isa ObjectGroup && o !== r(:arm)]
        @test length(groups) == 1 && _close(position(only(groups)), position(g); atol = 1e-9)
    end
end

end
