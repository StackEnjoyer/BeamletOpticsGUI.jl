module TestLiveSplitter

using GLMakie, BeamletOptics, BeamletOpticsGUI
using Makie
using Test

const BMO = BeamletOptics
const GUI = BeamletOpticsGUI

@testset "Splitters of the app layout" begin

    # Beam along +y, mirror at 45° reflects it along +x onto the detector
    function _fixture()
        m = RoundPlanoMirror(25e-3, 5e-3)
        zrotate3d!(m, deg2rad(45))
        translate3d!(m, [0, 0.1, 0])
        pd = Detector(5e-3)
        zrotate3d!(pd, -π / 2)
        translate3d!(pd, [0.1, 0.1, 0])
        return m, pd, Beam([0.0, 0, 0], [0.0, 1, 0])
    end

    # Deterministic solves, see TestLiveView.jl
    function _live_app(; kwargs...)
        m, pd, beam = _fixture()
        gui = live_view(System([m, pd]), beam; merge((; trace_budget = Inf, layout = :app), kwargs)...)
        return gui, m, pd
    end

    _ev(gui) = events(gui.fig.scene)
    _mouse!(gui, p) = (_ev(gui).mouseposition[] = (Float64(p[1]), Float64(p[2])))
    _press!(gui, button = Mouse.left) = (_ev(gui).mousebutton[] = Makie.MouseButtonEvent(button, Mouse.press))
    _release!(gui, button = Mouse.left) = (_ev(gui).mousebutton[] = Makie.MouseButtonEvent(button, Mouse.release))
    _click!(gui, p) = (_mouse!(gui, p); _press!(gui); _release!(gui))
    _tick!(gui) = (_ev(gui).tick[] = Makie.Tick(Makie.RegularRenderTick, 0, 0.0, 1 / 60))
    function _drag!(gui, a, b; n = 5)
        _mouse!(gui, a)
        _press!(gui)
        for t in range(0, 1; length = n)[2:end]
            _mouse!(gui, a .+ t .* (b .- a))
            _tick!(gui)
        end
        _release!(gui)
        return nothing
    end

    _rect(part) = Rect2f(part.box.layoutobservables.computedbbox[])
    _width(part) = widths(_rect(part))[1]
    _height(part) = widths(_rect(part))[2]
    # A point on the splitter of a part, in the middle of its edge
    _left_edge(gui) = (r = _rect(gui.layout.left); (maximum(r)[1], minimum(r)[2] + widths(r)[2] / 2))
    _right_edge(gui) = (r = _rect(gui.layout.right); (minimum(r)[1], minimum(r)[2] + widths(r)[2] / 2))
    _dock_edge(gui) = (r = _rect(gui.layout.dock); (minimum(r)[1] + widths(r)[1] / 2, maximum(r)[2]))
    _line(gui) = gui.layout.splitters.line[]
    _marked(gui) = !any(p -> isnan(p[1]), _line(gui))
    _view(gui) = GUI._current_view(gui)

    # A view with a panel, such that the dock is shown
    function _with_dock(; kwargs...)
        gui, m, pd = _live_app(; kwargs...)
        add_panel!(gui, "Panel") do layout
            Axis(layout[1, 1])
            return nothing
        end
        @test gui.layout.dock.shown && gui.layout.collapse.dock.active[]
        return gui, m, pd
    end

    @testset "start sizes" begin
        gui, = _live_app()
        layout = gui.layout
        @test layout.left.size == Fixed(240) && layout.right.size == Fixed(300)
        @test layout.dock.size == Relative(0.36)
        @test _width(layout.left) ≈ 240 && _width(layout.right) ≈ 300
        @test length(layout.splitters.splitters) == 3
        @test !_marked(gui)
        close(gui)

        gui, = _with_dock()
        # 36 % of the height of the window
        @test gui.layout.dock.size == Relative(0.36)
        @test _height(gui.layout.dock) ≈ 0.36 * 950 atol = 1
        close(gui)
    end

    @testset "kwargs" begin
        gui, = _with_dock(; sidebar_width = (320, 280), dock_height = 200)
        layout = gui.layout
        @test layout.left.size == Fixed(320) && layout.right.size == Fixed(280)
        @test layout.dock.size == Fixed(200)
        @test _width(layout.left) ≈ 320 && _width(layout.right) ≈ 280 && _height(layout.dock) ≈ 200
        # the docked catalog is laid out for the width of its sidebar
        @test GUI._catalog_window(gui).dock.widget.style.tiles_per_row == 7
        @test GUI._part_size_kwargs(gui) == (; sidebar_width = (320.0, 280.0), dock_height = 200.0)
        close(gui)

        # a number sets both sidebars
        gui, = _live_app(; sidebar_width = 200)
        @test gui.layout.left.size == Fixed(200) && gui.layout.right.size == Fixed(200)
        @test _width(gui.layout.left) ≈ 200 && _width(gui.layout.right) ≈ 200
        @test GUI._part_size_kwargs(gui) == (; sidebar_width = (200.0, 200.0), dock_height = nothing)
        close(gui)
        gui, = _live_app(; sidebar_width = [160, 600])
        @test gui.layout.left.size == Fixed(160) && gui.layout.right.size == Fixed(600)
        close(gui)

        # values outside of the limits and of another kind
        for kw in ((; sidebar_width = 159), (; sidebar_width = 601), (; sidebar_width = (240, 700)),
            (; sidebar_width = (100, 300)), (; sidebar_width = (240, 300, 200)),
            (; sidebar_width = :wide), (; sidebar_width = ("a", 300)), (; dock_height = 79),
            (; dock_height = 0.7 * 950 + 1), (; dock_height = :high),
            # 70 % of the height of the figure
            (; dock_height = 500, size = (1200, 700)))
            @test_throws ArgumentError _live_app(; kw...)
        end
        gui, = _live_app(; dock_height = 0.7 * 950)
        @test gui.layout.dock.size == Fixed(0.7 * 950)
        close(gui)
        gui, = _live_app(; dock_height = 490, size = (1200, 700))
        @test gui.layout.dock.size == Fixed(490)
        close(gui)
    end

    @testset "the compact layout ignores the kwargs" begin
        m, pd, beam = _fixture()
        gui = live_view(System([m, pd]), beam; trace_budget = Inf, sidebar_width = (320, 280),
            dock_height = 200)
        @test gui isa GUI.CompactView
        @test GUI._part_size_kwargs(gui) == (;)
        close(gui)
        # also values that the app layout rejects
        m, pd, beam = _fixture()
        gui = live_view(System([m, pd]), beam; trace_budget = Inf, layout = :compact,
            sidebar_width = 10, dock_height = 5000)
        @test gui isa GUI.CompactView
        close(gui)
    end

    @testset "dragging a sidebar" begin
        gui, = _live_app()
        layout = gui.layout
        left, right = layout.left, layout.right
        view_width = widths(gui.ax.scene.viewport[])[1]
        # the left sidebar: its edge towards the 3D view, wider to the right
        a = _left_edge(gui)
        @test a[1] ≈ 240
        _drag!(gui, a, a .+ (50, 0))
        @test left.size == Fixed(290) && _width(left) ≈ 290
        @test widths(gui.ax.scene.viewport[])[1] ≈ view_width - 50
        @test right.size == Fixed(300)
        a = _left_edge(gui)
        @test a[1] ≈ 290
        _drag!(gui, a, a .+ (-70, 30))
        @test left.size == Fixed(220) && _width(left) ≈ 220
        # the right sidebar: wider to the left
        b = _right_edge(gui)
        @test b[1] ≈ 1600 - 300
        _drag!(gui, b, b .+ (-40, 0))
        @test right.size == Fixed(340) && _width(right) ≈ 340
        b = _right_edge(gui)
        _drag!(gui, b, b .+ (90, 0))
        @test right.size == Fixed(250) && _width(right) ≈ 250
        @test left.size == Fixed(220)
        # the strip is 6 px wide
        a = _left_edge(gui)
        _drag!(gui, a .+ (3, 0), a .+ (13, 0))
        @test left.size == Fixed(230)
        a = _left_edge(gui)
        _drag!(gui, a .- (3, 0), a .+ (7, 0))
        @test left.size == Fixed(240)
        a = _left_edge(gui)
        for off in (5, -5)
            _drag!(gui, a .+ (off, 0), a .+ (off + 30, 0))
            @test left.size == Fixed(240)
        end
        close(gui)
    end

    @testset "the size is set once per frame" begin
        gui, = _live_app()
        left = gui.layout.left
        s = gui.layout.splitters
        a = _left_edge(gui)
        _mouse!(gui, a)
        _press!(gui)
        @test GUI._dragging(s)
        # less than the smallest drag: nothing
        _mouse!(gui, a .+ (2, 0))
        _tick!(gui)
        @test left.size == Fixed(240)
        _mouse!(gui, a .+ (20, 0))
        _mouse!(gui, a .+ (30, 0))
        # not before the frame
        @test left.size == Fixed(240) && _width(left) ≈ 240
        _tick!(gui)
        @test left.size == Fixed(270) && _width(left) ≈ 270
        # the line follows the edge
        @test _line(gui)[1][1] ≈ 270 && _line(gui)[2][1] ≈ 270
        # back to within the smallest drag: the part follows
        _mouse!(gui, a .+ (1, 0))
        _tick!(gui)
        @test left.size == Fixed(241)
        # the release applies the last size
        _mouse!(gui, a .+ (12.4, 0))
        _release!(gui)
        @test !GUI._dragging(s) && left.size == Fixed(252) && _width(left) ≈ 252
        close(gui)
    end

    @testset "limits of the sidebars" begin
        gui, = _live_app()
        left, right = gui.layout.left, gui.layout.right
        a = _left_edge(gui)
        _drag!(gui, a, a .+ (-200, 0))
        @test left.size == Fixed(160) && _width(left) ≈ 160
        a = _left_edge(gui)
        _drag!(gui, a, a .+ (700, 0))
        @test left.size == Fixed(600) && _width(left) ≈ 600
        b = _right_edge(gui)
        _drag!(gui, b, b .+ (400, 0))
        @test right.size == Fixed(160) && _width(right) ≈ 160
        # the size follows the mouse again once it is back within the limits
        b = _right_edge(gui)
        _mouse!(gui, b)
        _press!(gui)
        _mouse!(gui, b .+ (300, 0))
        _tick!(gui)
        @test right.size == Fixed(160)
        _mouse!(gui, b .+ (-20, 0))
        _tick!(gui)
        @test right.size == Fixed(180)
        _mouse!(gui, b .+ (-1200, 0))
        _release!(gui)
        @test right.size == Fixed(600) && _width(right) ≈ 600
        close(gui)
    end

    @testset "dragging the dock" begin
        gui, = _with_dock()
        dock = gui.layout.dock
        h = _height(dock)
        c = _dock_edge(gui)
        # its upper edge, higher upwards; a fixed height once it was dragged
        _drag!(gui, c, c .+ (0, 60))
        @test dock.size == Fixed(round(h) + 60) && _height(dock) ≈ round(h) + 60
        c = _dock_edge(gui)
        _drag!(gui, c, c .+ (10, -100))
        @test dock.size == Fixed(round(h) - 40)
        # within 80 px and 70 % of the height of the window
        c = _dock_edge(gui)
        _drag!(gui, c, c .+ (0, -600))
        @test dock.size == Fixed(80) && _height(dock) ≈ 80
        c = _dock_edge(gui)
        _drag!(gui, c, c .+ (0, 900))
        @test dock.size == Fixed(round(0.7 * 950)) && _height(dock) ≈ round(0.7 * 950)
        # the sidebars keep their widths
        @test gui.layout.left.size == Fixed(240) && gui.layout.right.size == Fixed(300)
        close(gui)

        # with a height of the start
        gui, = _with_dock(; dock_height = 200)
        dock = gui.layout.dock
        c = _dock_edge(gui)
        _drag!(gui, c, c .+ (0, 25))
        @test dock.size == Fixed(225) && _height(dock) ≈ 225
        close(gui)
    end

    @testset "double click" begin
        gui, = _with_dock()
        layout = gui.layout
        left, right, dock = layout.left, layout.right, layout.dock
        s = layout.splitters
        a = _left_edge(gui)
        _drag!(gui, a, a .+ (80, 0))
        b = _right_edge(gui)
        _drag!(gui, b, b .+ (-80, 0))
        c = _dock_edge(gui)
        _drag!(gui, c, c .+ (0, 50))
        @test left.size == Fixed(320) && right.size == Fixed(380) && dock.size isa Fixed
        # a click changes nothing
        _click!(gui, _left_edge(gui))
        @test left.size == Fixed(320) && !GUI._dragging(s)
        # the second one restores the size of the start
        _click!(gui, _left_edge(gui))
        @test left.size == Fixed(240) && _width(left) ≈ 240 && !GUI._dragging(s)
        @test right.size == Fixed(380)
        # the third one is the first of the next double click
        _click!(gui, _left_edge(gui))
        @test left.size == Fixed(240)
        _click!(gui, _right_edge(gui))
        _click!(gui, _right_edge(gui))
        @test right.size == Fixed(300) && _width(right) ≈ 300
        # the dock follows the window again
        _click!(gui, _dock_edge(gui))
        _click!(gui, _dock_edge(gui))
        @test dock.size == Relative(0.36) && isapprox(_height(dock), 0.36 * 950; atol = 1)
        close(gui)

        gui, = _with_dock(; sidebar_width = (320, 280), dock_height = 200)
        layout = gui.layout
        left, right, dock = layout.left, layout.right, layout.dock
        a = _left_edge(gui)
        _drag!(gui, a, a .+ (-100, 0))
        c = _dock_edge(gui)
        _drag!(gui, c, c .+ (0, 100))
        @test left.size == Fixed(220) && dock.size == Fixed(300)
        # two presses on different splitters, and with a drag in between
        _click!(gui, _left_edge(gui))
        _click!(gui, _dock_edge(gui))
        @test left.size == Fixed(220) && dock.size == Fixed(300)
        a = _left_edge(gui)
        _drag!(gui, a, a .+ (10, 0))
        @test left.size == Fixed(230)
        _click!(gui, _left_edge(gui))
        @test left.size == Fixed(230)
        # ... and more than 0.4 s apart
        sleep(GUI._SPLITTER_DOUBLE_CLICK + 0.1)
        _click!(gui, _left_edge(gui))
        @test left.size == Fixed(230)
        _click!(gui, _left_edge(gui))
        @test left.size == Fixed(320) && _width(left) ≈ 320
        _click!(gui, _dock_edge(gui))
        _click!(gui, _dock_edge(gui))
        @test dock.size == Fixed(200) && _height(dock) ≈ 200
        close(gui)
    end

    @testset "a drag reaches neither the camera nor the selection" begin
        gui, m, pd = _live_app()
        ctrl = gui.controls
        ev = _ev(gui)
        select!(gui, m)
        @test ctrl.selected[] === m
        view = _view(gui)
        # listeners behind the splitters, like the controls (200) and the camera
        seen = Ref(0)
        moved = Ref(0)
        l1 = on(_ -> (seen[] += 1; Consume(false)), ev.mousebutton; priority = 300)
        l2 = on(_ -> (moved[] += 1; Consume(false)), ev.mouseposition; priority = 300)
        a = _left_edge(gui)
        _mouse!(gui, a)
        moved[] = 0
        _press!(gui)
        for k in 1:5
            _mouse!(gui, a .+ (10k, 4k))
            _tick!(gui)
        end
        _release!(gui)
        @test gui.layout.left.size == Fixed(290)
        @test seen[] == 0 && moved[] == 0
        @test ctrl.selected[] === m && !ctrl.dragging
        @test _view(gui) == view
        # a double click as well
        _press!(gui); _release!(gui)
        _press!(gui); _release!(gui)
        @test gui.layout.left.size == Fixed(240) && seen[] == 0
        @test ctrl.selected[] === m && _view(gui) == view
        # the other buttons and a press beside the splitters are passed on
        _mouse!(gui, _left_edge(gui))
        _press!(gui, Mouse.right)
        _release!(gui, Mouse.right)
        @test seen[] == 2 && !GUI._dragging(gui.layout.splitters)
        off(l1)
        off(l2)
        close(gui)
    end

    @testset "line along the edge" begin
        gui, = _with_dock()
        s = gui.layout.splitters
        @test !_marked(gui)
        a = _left_edge(gui)
        _mouse!(gui, a)
        @test _marked(gui) && s.hovered === s.splitters[1]
        r = _rect(gui.layout.left)
        @test _line(gui) ≈ [Point2f(240, minimum(r)[2]), Point2f(240, maximum(r)[2])]
        _mouse!(gui, a .+ (20, 0))
        @test !_marked(gui) && isnothing(s.hovered)
        _mouse!(gui, _right_edge(gui))
        @test _marked(gui) && s.hovered === s.splitters[2] && _line(gui)[1][1] ≈ 1300
        c = _dock_edge(gui)
        _mouse!(gui, c)
        @test s.hovered === s.splitters[3]
        @test _line(gui)[1][2] ≈ c[2] && _line(gui)[2][2] ≈ c[2] && _line(gui)[1][1] != _line(gui)[2][1]
        # while it is dragged, also beside the strip
        _press!(gui)
        _mouse!(gui, c .+ (0, 50))
        _tick!(gui)
        @test _marked(gui) && _line(gui)[1][2] ≈ c[2] + 50
        # released beyond the largest height, i.e. beside the edge
        _mouse!(gui, c .+ (300, 500))
        _release!(gui)
        @test !_marked(gui)
        # in the color of the theme, over the parts
        @test only(s.scene.plots).color[] == Makie.to_color(gui.layout.theme.accent)
        @test s.scene.transformation.translation[][3] == GUI._SPLITTER_Z
        # not while another button is held, e.g. a drag of the camera over the edge
        _mouse!(gui, _left_edge(gui) .+ (100, 0))
        _press!(gui, Mouse.right)
        _mouse!(gui, _left_edge(gui))
        @test !_marked(gui)
        _release!(gui, Mouse.right)
        _mouse!(gui, _left_edge(gui))
        @test _marked(gui)
        # the mouse leaves the window
        _ev(gui).entered_window[] = false
        @test !_marked(gui)
        close(gui)
    end

    @testset "collapsed parts" begin
        gui, = _with_dock()
        layout = gui.layout
        left, right, dock = layout.left, layout.right, layout.dock
        s = layout.splitters
        a = _left_edge(gui)
        _drag!(gui, a, a .+ (60, 0))
        b = _right_edge(gui)
        _drag!(gui, b, b .+ (-50, 0))
        c = _dock_edge(gui)
        _drag!(gui, c, c .+ (0, -42))
        h = dock.size
        @test left.size == Fixed(300) && right.size == Fixed(350) && h isa Fixed
        a, b, c = _left_edge(gui), _right_edge(gui), _dock_edge(gui)
        for (toggle, part, p, size) in ((layout.collapse.left, left, a, Fixed(300)),
            (layout.collapse.right, right, b, Fixed(350)), (layout.collapse.dock, dock, c, h))
            toggle.active[] = false
            @test !part.shown
            # no splitter where its edge was, nor at the edge of the window
            # no splitter where its edge was
            @test isnothing(GUI._splitter_at(s, Point2f(p)))
            _mouse!(gui, p)
            @test !_marked(gui)
            _press!(gui)
            @test !GUI._dragging(s)
            _release!(gui)
            @test part.size == size
            # it comes back with the size it had
            toggle.active[] = true
            @test part.shown && part.size == size
        end
        @test _width(left) ≈ 300 && _width(right) ≈ 350 && _height(dock) ≈ h.x
        @test !isnothing(GUI._splitter_at(s, Point2f(_left_edge(gui))))
        # a double click on the splitter of a part that was collapsed in between
        _mouse!(gui, _left_edge(gui))
        _press!(gui); _release!(gui)
        _press!(gui); _release!(gui)
        @test left.size == Fixed(240)
        close(gui)
    end

    @testset "spectator mode" begin
        gui, = _with_dock()
        layout = gui.layout
        left, right, dock = layout.left, layout.right, layout.dock
        s = layout.splitters
        a = _left_edge(gui)
        _drag!(gui, a, a .+ (60, 0))
        a, b, c = _left_edge(gui), _right_edge(gui), _dock_edge(gui)
        spectator!(gui)
        @test layout.ui_hidden && !left.shown && !right.shown && !dock.shown
        for p in (a, b, c)
            @test isnothing(GUI._splitter_at(s, Point2f(p)))
            _mouse!(gui, p)
            @test !_marked(gui)
        end
        spectator!(gui, false)
        @test left.shown && left.size == Fixed(300) && _width(left) ≈ 300
        @test right.size == Fixed(300) && dock.shown
        # the pinned cards stay with `cards`, their sidebar is not resized in the mode
        spectator!(gui; cards = true)
        @test layout.ui_hidden && right.shown
        b = _right_edge(gui)
        @test isnothing(GUI._splitter_at(s, Point2f(b)))
        _drag!(gui, b, b .+ (-50, 0))
        @test right.size == Fixed(300)
        spectator!(gui, false)
        # the mode ends a drag
        a = _left_edge(gui)
        _mouse!(gui, a)
        _press!(gui)
        _mouse!(gui, a .+ (30, 0))
        _tick!(gui)
        @test left.size == Fixed(330) && GUI._dragging(s)
        spectator!(gui)
        _mouse!(gui, a .+ (60, 0))
        _tick!(gui)
        @test !GUI._dragging(s) && !_marked(gui)
        _release!(gui)
        spectator!(gui, false)
        @test left.size == Fixed(330) && _width(left) ≈ 330
        close(gui)
    end

    @testset "the docked catalog follows the width" begin
        gui, = _live_app()
        left = gui.layout.left
        win = GUI._catalog_window(gui)
        w = win.dock.widget
        per_row(buttons) = count(b -> GUI._GLB.gridcontent(b.box).span.rows.start == 1, buttons)
        tiles() = last.(w.tile_buttons)
        @test w.style.tiles_per_row == 5 && w.style.groups_per_row == 7
        # the group with the most tiles, an entry of it and a typed input
        k = argmax([count(e -> e.group == g, w.entries) for g in w.groups])
        GUI._select_catalog_group!(gui, w, k)
        i = first(w.tile_buttons[3])
        GUI._select_catalog_entry!(gui, w, i)
        box = first(w.boxes)
        box.displayed_string[] = "12.5"
        n = length(w.tile_buttons)
        @test n > 5 && per_row(tiles()) == 5
        buttons, form, boxes, group_buttons = copy(tiles()), w.form, copy(w.boxes), copy(w.group_buttons)
        # while it is dragged, the catalog keeps its rows
        a = _left_edge(gui)
        _mouse!(gui, a)
        _press!(gui)
        _mouse!(gui, a .+ (84, 0))
        _tick!(gui)
        @test left.size == Fixed(324) && w.style.tiles_per_row == 5 && per_row(tiles()) == 5
        # laid out again when the drag ends
        _release!(gui)
        @test w.style.tiles_per_row == 7 && per_row(tiles()) == min(7, n)
        @test w.style.groups_per_row == 10 && per_row(w.group_buttons) == min(10, length(w.groups))
        # the same tiles in the same order, with the state of the catalog
        @test tiles() == buttons && length(w.tile_buttons) == n
        spans = [GUI._GLB.gridcontent(b.box).span for b in tiles()]
        @test [(sp.rows.start, sp.cols.start) for sp in spans] == [fldmod1(j, 7) for j in 1:n]
        @test w.group == k && w.entry == i && w.form === form && w.boxes == boxes
        @test w.group_buttons == group_buttons
        @test box.displayed_string[] == "12.5" && "12.5" in GUI._catalog_strings(w)
        @test only(b for (j, b) in w.tile_buttons if b.active[]) === last(w.tile_buttons[3])
        # the tiles are as wide as the sidebar allows
        r = _rect(left)
        @test all(b -> minimum(Rect2f(b.box.layoutobservables.computedbbox[]))[1] >= minimum(r)[1] &&
                       maximum(Rect2f(b.box.layoutobservables.computedbbox[]))[1] <= maximum(r)[1], tiles())
        # a tile still chooses its entry, another group has the new rows
        j = first(w.tile_buttons[2])
        last(w.tile_buttons[2]).clicks[] += 1
        @test w.entry == j
        GUI._select_catalog_group!(gui, w, k == 1 ? 2 : 1)
        @test per_row(tiles()) == min(7, length(w.tile_buttons))
        # narrower again, and the double click
        GUI._select_catalog_group!(gui, w, k)
        a = _left_edge(gui)
        _drag!(gui, a, a .+ (-160, 0))
        @test left.size == Fixed(164) && w.style.tiles_per_row == 3 && per_row(tiles()) == 3
        @test w.style.groups_per_row == 4 && per_row(w.group_buttons) == min(4, length(w.groups))
        _mouse!(gui, _left_edge(gui))
        _press!(gui); _release!(gui)
        _press!(gui); _release!(gui)
        @test left.size == Fixed(240) && w.style.tiles_per_row == 5 && per_row(tiles()) == 5
        # the window of the catalog keeps its style
        @test win.widget.style.tiles_per_row == 4 && win.widget.style.tile_width == 86
        close(gui)

        # while the catalog floats: laid out for when it is docked again
        gui, = _live_app()
        win = GUI._catalog_window(gui)
        w = win.dock.widget
        GUI._float_catalog!(gui)
        @test !win.docked
        a = _left_edge(gui)
        _drag!(gui, a, a .+ (84, 0))
        @test w.style.tiles_per_row == 7
        GUI._dock_catalog!(gui; expand = true)
        @test win.docked && per_row(last.(w.tile_buttons)) == min(7, length(w.tile_buttons))
        close(gui)

        # a view without a catalog
        gui, = _live_app(; catalog = CatalogEntry[])
        @test isnothing(GUI._catalog_window(gui))
        a = _left_edge(gui)
        _drag!(gui, a, a .+ (40, 0))
        @test gui.layout.left.size == Fixed(280)
        close(gui)
    end

    @testset "the docked detector views follow the width" begin
        m, pd, beam = _fixture()
        gui = live_view(System([m, pd]), beam; trace_budget = Inf, layout = :app,
            detectors = [pd => :spot])
        layout = gui.layout
        insp = layout.inspector
        right = layout.right
        select!(gui, pd)
        card = insp.card
        GUI._set_page!(gui, card, :results)
        pinned = only(insp.pinned)
        @test card.view isa GUI._DetectorView && pinned.view isa GUI._DetectorView
        w = GUI._docked_width(gui)
        @test w ≈ 300 - 2 * GUI._SIDEBAR_PADDING
        @test card.view.ax.width[] == w && pinned.view.ax.width[] == w
        views = (card.view, pinned.view)
        # the state of the views: the kind and the limits that the mouse set
        card.view.zoomed = true
        kind = card.view.kind
        b = _right_edge(gui)
        _mouse!(gui, b)
        _press!(gui)
        _mouse!(gui, b .+ (-60, 0))
        _tick!(gui)
        # they grow with the sidebar, as high as wide
        @test right.size == Fixed(360)
        @test all(v -> v.ax.width[] == w + 60 && v.ax.height[] == w + 60, views)
        _mouse!(gui, b .+ (-100, 0))
        _release!(gui)
        @test right.size == Fixed(400) && GUI._docked_width(gui) ≈ w + 100
        @test all(v -> v.ax.width[] == w + 100 && v.ax.height[] == w + 100, views)
        @test (card.view, pinned.view) === views
        @test card.view.zoomed && card.view.kind == kind && card.page == :results
        @test card.view_obj === pd && pinned.view_obj === pd
        # narrower, and the double click
        b = _right_edge(gui)
        _drag!(gui, b, b .+ (180, 0))
        @test right.size == Fixed(220) && all(v -> v.ax.width[] == w - 80, views)
        _mouse!(gui, _right_edge(gui))
        _press!(gui); _release!(gui)
        _press!(gui); _release!(gui)
        @test right.size == Fixed(300) && all(v -> v.ax.width[] == w && v.ax.height[] == w, views)
        # a view of a page that is not shown gets the width when it is shown
        GUI._set_page!(gui, card, :pose)
        b = _right_edge(gui)
        _drag!(gui, b, b .+ (-30, 0))
        @test pinned.view.ax.width[] == w + 30
        GUI._set_page!(gui, card, :results)
        @test card.view.ax.width[] == w + 30
        close(gui)
    end

    @testset "the inspector follows the width" begin
        gui, m, pd = _live_app()
        select!(gui, m)
        insp = gui.layout.inspector
        @test insp.shown === m
        blocks = copy(insp.card.blocks)
        name = insp.name.text[]
        b = _right_edge(gui)
        _drag!(gui, b, b .+ (-80, 0))
        @test gui.layout.right.size == Fixed(380)
        @test insp.shown === m && insp.card.blocks == blocks && insp.name.text[] == name
        # a name that does not fit is shortened to the width
        b = _right_edge(gui)
        _drag!(gui, b, b .+ (220, 0))
        @test gui.layout.right.size == Fixed(160)
        @test gui.controls.selected[] === m
        close(gui)
    end

    @testset "close removes the listeners" begin
        gui, = _live_app()
        ev = _ev(gui)
        left = gui.layout.left
        a = _left_edge(gui)
        close(gui)
        _drag!(gui, a, a .+ (50, 0))
        @test left.size == Fixed(240)
        _mouse!(gui, a)
        @test !_marked(gui)
    end

    @testset "a second window" begin
        gui, = _live_app(; sidebar_width = (300, 320))
        a = _left_edge(gui)
        _drag!(gui, a, a .+ (40, 0))
        kw = GUI._part_size_kwargs(gui)
        @test kw == (; sidebar_width = (340.0, 320.0), dock_height = nothing)
        other = open_system(gui, first(gui.pairs).first; display = false, kw...)
        @test other.layout.left.size == Fixed(340) && other.layout.right.size == Fixed(320)
        # its splitters are its own
        b = _left_edge(other)
        _drag!(other, b, b .+ (-40, 0))
        @test other.layout.left.size == Fixed(300) && gui.layout.left.size == Fixed(340)
        close(other)
        close(gui)
    end
end

end
