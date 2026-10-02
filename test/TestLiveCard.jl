module TestLiveCard

using GLMakie, BeamletOptics, BeamletOpticsGUI
using Makie
using Test

const BMO = BeamletOptics
const GUI = BeamletOpticsGUI

# A component with its own card rows, see `card_rows`: its height as a text and a slider that lifts
# it, which changes the optics (`solve = true`); no actions in the head
struct CardTestObject{T, S <: BMO.AbstractShape{T}} <: BMO.AbstractObject{T}
    shape::S
end
BMO.intersect3d(::CardTestObject, ::BMO.AbstractRay) = nothing
BMO.interact3d(::BMO.AbstractSystem, ::CardTestObject, ::BMO.AbstractBeam, ::BMO.AbstractRay) = nothing
_height(o) = round(Int, 1e3 * BMO.position(o)[3])
BeamletOpticsGUI.card_rows(o::CardTestObject) = (pose_card_rows(o)...,
    CardRow("height", CardWidget(Label; name = :height, value = (gui, o) -> "$(_height(o)) mm")),
    CardRow("lift", CardWidget(Slider; name = :lift, range = 0:5, width = 120, solve = true,
        value = (gui, o) -> _height(o), on = (gui, o, v) -> translate3d!(o, [0, 0, 1e-3 * (v - _height(o))]))))
BeamletOpticsGUI.card_actions(::CardTestObject) = ()

@testset "Live component card" begin

    # Beam along +y, mirror at 45° reflects it along +x onto the detector
    function _fixture()
        m = RoundPlanoMirror(25e-3, 5e-3)
        zrotate3d!(m, deg2rad(45))
        translate3d!(m, [0, 0.1, 0])
        pd = Detector(5e-3)
        zrotate3d!(pd, -π / 2)
        translate3d!(pd, [0.1, 0.1, 0])
        return m, pd
    end
    _gauss() = GaussianBeamlet([0.0, 0, 0], [0.0, 1, 0], 1e-6, 0.5e-3)
    _live_view(args...; kwargs...) = live_view(args...; merge((; trace_budget = Inf, detectors = []), kwargs)...)
    _tick!(gui) = (events(gui.ax.scene).tick[] = Makie.Tick(Makie.RegularRenderTick, 0, 0.0, 1.0))
    # a click on the pin toggle of the card `c`
    _pin!(c) = (c.pin_button.active[] = !c.pin_button.active[])

    _rect(x) = x.layoutobservables.computedbbox[]
    _center(r) = Point2f(minimum(r) .+ Makie.widths(r) ./ 2)
    _away(x) = x.layoutobservables.suggestedbbox[] == GUI._CARD_AWAY
    _move!(gui, xy) = (events(gui.ax.scene).mouseposition[] = (Float64(xy[1]), Float64(xy[2])))
    _press!(gui, button = Mouse.left) =
        (events(gui.ax.scene).mousebutton[] = Makie.MouseButtonEvent(button, Mouse.press))
    _release!(gui, button = Mouse.left) =
        (events(gui.ax.scene).mousebutton[] = Makie.MouseButtonEvent(button, Mouse.release))
    _click!(gui, xy) = (_move!(gui, xy); _press!(gui); _release!(gui))
    function _drag!(gui, a, b; button = Mouse.left)
        _move!(gui, a)
        _press!(gui, button)
        for t in range(0, 1; length = 10)
            _move!(gui, a .+ t .* (b .- a))
        end
        _release!(gui, button)
    end
    _eye(gui) = Vector{Float64}(cameracontrols(gui.ax.scene).eyeposition[])
    # The card lies inside the 3D view, with the margin
    function _inside(gui)
        r, v = _rect(gui.cards.selection.background), Rect2f(gui.ax.scene.viewport[])
        return all(minimum(r) .>= minimum(v) .+ GUI._CARD_MARGIN .- 1.0f-3) &&
               all(maximum(r) .<= maximum(v) .- GUI._CARD_MARGIN .+ 1.0f-3)
    end
    function _select!(gui, obj)
        gui.controls.selected[] = obj
        GUI._update_selection_box!(gui.controls)
        return nothing
    end
    # Declared widgets by name, the pose boxes by their index
    _w(c, name) = GUI._card_widget(c, name)
    _pose(c, k) = _w(c, (:x, :y, :z, :rx, :ry, :rv)[k])

    @testset "widgets in the card" begin
        m, pd = _fixture()
        gui = _live_view(System([m, pd]), _gauss(); labels = Dict(m => "M1"))
        c = gui.cards.selection
        @test gui.widgets.step_box === c.step_box
        # no textboxes and no hide button below the 3D view
        @test !any(b -> b isa Textbox, gui.fig.content)
        @test !any(b -> b isa Button && b.label[] == "hide", gui.fig.content)
        # drawn after the 3D scene
        @test c.scene.transformation.translation[][3] == GUI._card_z(1)
        # hidden without a selection, without widgets and with all parts away
        @test !c.scene.visible[] && isempty(c.widgets)
        @test all(_away, (c.head, c.rows, c.step, c.actions, c.background))

        _select!(gui, m)
        @test c.scene.visible[]
        @test c.title.text[] == "M1"
        # the default declarations: "hide" and the pose rows
        @test _w(c, :hide).label[] == "hide"
        @test all(k -> _pose(c, k) isa Textbox, 1:6)
        @test !_away(c.rows) && !_away(c.actions) && !_away(c.step)
        @test _inside(gui)
        # the head and the actions in the first line, the rows below, the step below them
        @test minimum(_rect(c.actions))[1] > maximum(_rect(c.head))[1]
        @test maximum(_rect(c.rows))[2] < minimum(_rect(c.head))[2]
        @test maximum(_rect(c.step))[2] < minimum(_rect(c.rows))[2]
        # the pose of the object in the boxes, the boxes of both rows line up
        @test _pose(c, 2).displayed_string[] == "100.0"
        @test minimum(_rect(_pose(c, 1)))[1] ≈ minimum(_rect(_pose(c, 4)))[1]
        # at the bounding box of the object (not at the gizmo), at one of its sides, see "placement"
        set_view(gui.ax, [0.3, -0.2, 0.3], [0.0, 0.1, 0.0], [0.0, 0, 1])
        _tick!(gui)
        sel = GUI._screen_rect(gui.ax.scene, gui.controls.box_obs[], m)
        r = _rect(c.background)
        gap = GUI._CARD_GAP
        @test minimum(r)[1] ≈ maximum(sel)[1] + gap || maximum(r)[1] ≈ minimum(sel)[1] - gap ||
              maximum(r)[2] ≈ minimum(sel)[2] - gap || minimum(r)[2] ≈ maximum(sel)[2] + gap
        # the line from the center of the bounding box to the card, which covers its end
        a, b = c.link[]
        @test a ≈ GUI._link_anchor(gui.ax.scene, gui.controls.box_obs[], m)
        @test all(minimum(sel) .<= a .<= maximum(sel)) && b in r

        # follows the camera
        r0 = _rect(c.background)
        set_view(gui.ax, [0.2, -0.1, 0.1], [0.0, 0.1, 0.0], [0.0, 0, 1])
        _tick!(gui)
        @test _rect(c.background) != r0
        @test _inside(gui)
        # a selection behind the camera: at the edge of the view
        set_view(gui.ax, [0.0, 0.3, 0.0], [0.0, 0.6, 0.0], [0.0, 0, 1])
        _tick!(gui)
        @test all(iszero, Makie.widths(GUI._screen_rect(gui.ax.scene, gui.controls.box_obs[], m)))
        @test c.scene.visible[] && _inside(gui)

        # an open menu would be covered
        gui.widgets.menu.is_open[] = true
        _tick!(gui)
        @test !c.scene.visible[]
        gui.widgets.menu.is_open[] = false
        _tick!(gui)
        @test c.scene.visible[]

        # collapsed to the head and the actions
        h0 = Makie.widths(_rect(c.background))[2]
        notify(c.collapse_button.clicks)
        @test c.collapsed && c.collapse_button.icon[] === GUI._icon(:expand)
        @test _away(c.rows) && _away(c.step) && !_away(c.actions)
        @test Makie.widths(_rect(c.background))[2] < h0 / 2
        notify(c.collapse_button.clicks)
        @test !c.collapsed && c.collapse_button.icon[] === GUI._icon(:collapse)
        @test !_away(c.rows)

        # deselected: hidden
        _select!(gui, nothing)
        @test !c.scene.visible[]
        @test all(_away, (c.head, c.rows, c.step, c.actions, c.background))
        _select!(gui, m)
        close(gui)
        @test !c.scene.visible[]
    end

    @testset "pages: pose and properties, step and mode" begin
        m, pd = _fixture()
        gui = _live_view(System([m, pd]), _gauss(); labels = Dict(m => "M1"), size = (1600, 1000))
        ctrl = gui.controls
        c = gui.cards.selection
        # no page bar and no view without an object
        @test isnothing(c.bar) && isnothing(c.bar_part) && isnothing(c.view) && isempty(c.bars)
        _select!(gui, m)
        _tick!(gui)
        # the page bar below the head; the page of the pose with the rows, step and mode
        @test c.pages == (:pose, :properties) && c.page == :pose
        @test c.bar.keys == [:pose, :properties] && c.bar.selected[] == :pose
        @test [b.label[] for b in c.bar.buttons] == ["Pose", "Properties"]
        @test !_away(c.bar_part) && !_away(c.rows) && !_away(c.step) && _away(c.properties)
        @test maximum(_rect(c.bar_part))[2] < minimum(_rect(c.head))[2]
        @test maximum(_rect(c.rows))[2] < minimum(_rect(c.bar_part))[2]
        @test maximum(_rect(c.step))[2] < minimum(_rect(c.rows))[2]
        @test Makie.widths(_rect(c.bar_part))[1] > 60
        @test c.mode.selected[] == :move && c.mode.keys == [:move, :rotate]
        # the bar and the page inside the card
        inside(x) = all(minimum(_rect(x)) .>= minimum(_rect(c.background))) &&
                    all(maximum(_rect(x)) .<= maximum(_rect(c.background)))
        @test inside(c.bar_part) && inside(c.rows) && inside(c.step)
        # no disclosure "Properties" on a floating card
        @test !any(f -> hasfield(typeof(c), f), (:disclosure, :properties_button, :properties_shown))
        @test isempty(c.list.rows)

        # a click on "Properties" shows the page with the rows of the inspector, without step and mode
        _click!(gui, _center(_rect(c.bar.buttons[2])))
        @test c.page == :properties && c.bar.selected[] == :properties && ctrl.selected[] === m
        @test _away(c.rows) && _away(c.step) && !_away(c.properties) && !_away(c.bar_part)
        @test c.list.rows == GUI._inspector_rows(gui, m) && !isempty(c.list.rows)
        @test maximum(_rect(c.list.box))[2] < minimum(_rect(c.bar_part))[2]
        # the list fills the card, which contains it
        @test inside(c.list.box)
        @test Makie.widths(_rect(c.list.box))[1] ≈ Makie.widths(_rect(c.background))[1] - 2 * GUI._CARD_PADDING
        @test _inside(gui)
        # the page stays while the card shows the same object: after a move and a tick
        translate3d!(m, [0.0, 0.0, 0.01])
        set_view(gui.ax, [0.3, -0.2, 0.3], [0.0, 0.1, 0.0], [0.0, 0, 1])
        _tick!(gui)
        @test c.page == :properties && !_away(c.properties)
        # collapsed to the head: without the bar and the page
        notify(c.collapse_button.clicks)
        @test _away(c.bar_part) && _away(c.properties)
        notify(c.collapse_button.clicks)
        @test !_away(c.bar_part) && !_away(c.properties)
        # a page that the object does not have is ignored
        GUI._set_page!(gui, c, :results)
        @test c.page == :properties

        # another object: its default page and its pages, a detector has the page "Results"
        _select!(gui, pd)
        _tick!(gui)
        @test gui.cards.selection === c && c.pages == (:pose, :results, :properties) && c.page == :results
        @test [b.label[] for b in c.bar.buttons] == ["Pose", "Results", "Properties"]
        @test c.bar.selected[] == :results
        # the bar of the mirror is kept for the next object with its pages, away
        @test length(c.bars) == 2 && count(!_away, first.(values(c.bars))) == 1
        _click!(gui, _center(_rect(c.bar.buttons[1])))
        @test c.page == :pose && !_away(c.rows) && !_away(c.step) && _away(c.view_part)
        # a click on "Rotate" sets the mode of the controls, the key `m` sets it back
        _click!(gui, _center(_rect(c.mode.buttons[2])))
        @test ctrl.mode[] == :rotate && c.mode.selected[] == :rotate
        @test ctrl.selected[] === pd
        events(gui.ax.scene).keyboardbutton[] = Makie.KeyEvent(Keyboard.m, Keyboard.press)
        @test ctrl.mode[] == :move && c.mode.selected[] == :move
        # a step in an angle unit switches to the rotate mode
        c.step_box.stored_string[] = "1 mrad"
        @test ctrl.mode[] == :rotate && c.mode.selected[] == :rotate

        # pinning does not change the card: the object is still selected, the card keeps its page
        _click!(gui, _center(_rect(c.bar.buttons[3])))
        _tick!(gui)
        @test c.page == :properties && c.list.rows == GUI._inspector_rows(gui, pd)
        size0 = Makie.widths(_rect(c.background))
        _pin!(c)
        _tick!(gui)
        @test c.pinned && c.scene.visible[] && c.page == :properties
        @test !_away(c.bar_part) && !_away(c.properties) && _away(c.rows) && _away(c.step)
        @test Makie.widths(_rect(c.background)) == size0
        @test c.list.rows == GUI._inspector_rows(gui, pd)
        # the new card of the selection has its own state: the default page of its object
        _select!(gui, m)
        _tick!(gui)
        c2 = gui.cards.selection
        @test c2 !== c && c2.page == :pose && !_away(c2.step) && _away(c2.properties)
        @test c2.mode.selected[] == ctrl.mode[]
        @test c.page == :properties && c.list.rows == GUI._inspector_rows(gui, pd)
        # step and mode belong to the selection: the pinned card of another object shows its rows
        # only on the page of the pose
        _click!(gui, _center(_rect(c.bar.buttons[1])))
        _tick!(gui)
        @test c.page == :pose && c2.page == :pose && !_away(c.rows) && _away(c.step)
        # selected again, e.g. by a click on the card: step and mode are back
        _select!(gui, pd)
        _tick!(gui)
        @test !_away(c.step) && !c2.scene.visible[]
        @test maximum(_rect(c.step))[2] < minimum(_rect(c.rows))[2]
        # unpinned: a spare card again, which the next pin shows on the default page of its object
        _pin!(c)
        @test !c.pinned && c.page == :pose
        GUI._toggle_pin!(gui, pd)
        pinned = only(filter(x -> x.pinned, gui.cards.all))
        @test pinned.page == :results && pinned.view isa GUI._DetectorView
        close(gui)
    end

    @testset "placement" begin
        view = Rect2f(0, 0, 800, 600)
        size = Vec2f(300, 150)
        margin, gap = GUI._CARD_MARGIN, GUI._CARD_GAP
        # right of the selection, top-aligned
        @test GUI._card_position(Rect2f(100, 200, 50, 80), size, view) == Point2f(150 + gap, 280)
        # left of it if the right side has no room
        @test GUI._card_position(Rect2f(600, 200, 50, 80), size, view) == Point2f(600 - gap - 300, 280)
        # inside the view: below its top edge, at the edges for a selection outside of the view
        @test GUI._card_position(Rect2f(100, 500, 50, 200), size, view)[2] == 600 - margin
        @test GUI._card_position(Rect2f(-500, -400, 10, 10), size, view) == Point2f(margin, margin + 150)
        # neither side has room: below, left-aligned, or above
        @test GUI._card_position(Rect2f(50, 200, 700, 80), size, view) == Point2f(50, 200 - gap)
        @test GUI._card_position(Rect2f(50, 100, 700, 80), size, view) == Point2f(50, 180 + gap + 150)
        # no room at all, e.g. an object that fills the view: right, moved into the view
        @test GUI._card_position(Rect2f(0, 0, 800, 600), size, view) == Point2f(800 - margin - 300, 600 - margin)

        # off the view cube
        m, pd = _fixture()
        gui = _live_view(System([m, pd]), _gauss())
        cube = gui.widgets.view_cube
        C = Rect2f(Makie.viewport(cube.scene)[])
        view = Rect2f(gui.ax.scene.viewport[])
        p = Point2f(minimum(C)[1] - 50, maximum(C)[2])
        @test GUI._overlaps(GUI._card_rect(p, size), C)
        q = GUI._avoid(p, size, view, GUI._obstacles(cube))
        r = GUI._card_rect(q, size)
        @test !GUI._overlaps(r, C)
        @test all(minimum(r) .>= minimum(view) .+ margin) && all(maximum(r) .<= maximum(view) .- margin)
        # beside or below the cube, at the margin
        @test minimum(C)[2] - maximum(r)[2] ≈ margin || minimum(C)[1] - maximum(r)[1] ≈ margin
        far = Point2f(minimum(view)[1] + 20, minimum(view)[2] + 200)
        @test GUI._avoid(far, size, view, GUI._obstacles(cube)) == far
        @test GUI._avoid(p, size, view, Rect2f[]) == p
        close(gui)
    end

    @testset "mouse and keyboard" begin
        m, pd = _fixture()
        gui = _live_view(System([m, pd]), _gauss())
        c, ctrl = gui.cards.selection, gui.controls
        ev = events(gui.ax.scene)
        _select!(gui, m)
        @test c.scene.visible[]
        vp = Rect2f(gui.ax.scene.viewport[])
        # a point of the 3D view beside the card, the objects and the button "⋯" of the tool rail
        # at the bottom left, see `_CompactOverlay`
        beside = Point2f(minimum(vp) .+ (30, 90))
        _move!(gui, beside)
        @test !GUI._over_card(c, ev)
        _move!(gui, _center(_rect(c.title)))
        @test GUI._over_card(c, ev) && ctrl.ignore_mouse()

        # a click on the card keeps the selection
        _click!(gui, _center(_rect(c.title)))
        @test ctrl.selected[] === m
        # a drag from the card moves the card, not the camera, a drag beside it moves the camera
        eye = _eye(gui)
        _drag!(gui, _center(_rect(c.title)), _center(_rect(c.title)) .+ Point2f(150, -100))
        @test _eye(gui) ≈ eye
        @test ctrl.selected[] === m && !isnothing(c.spot)
        ev.mouseposition[] = Tuple(Float64.(_center(_rect(c.title))))
        ev.scroll[] = (0.0, 3.0)
        @test _eye(gui) ≈ eye
        _drag!(gui, beside, beside .+ Point2f(150, 100))
        @test !(_eye(gui) ≈ eye)
        _tick!(gui)

        # the declared widgets get the clicks
        hide = _w(c, :hide)
        xy = _center(_rect(hide))
        _click!(gui, xy)
        @test hide.clicks[] == 1
        @test m in gui.objects.hidden && isnothing(ctrl.selected[])
        @test !c.scene.visible[]
        # hidden widgets are away and take no clicks at their former position
        _click!(gui, xy)
        @test hide.clicks[] == 1 && c.collapse_button.clicks[] == 0
        # selected in the menu, the hidden object shows "show"; the same declarations keep the widgets
        gui.widgets.menu.i_selected[] = findfirst(o -> o === m, gui.objects.menu)
        @test ctrl.selected[] === m && _w(c, :hide) === hide && hide.label[] == "show"
        notify(hide.clicks)
        @test !(m in gui.objects.hidden) && hide.label[] == "hide"

        # a textbox gets the keyboard, a press elsewhere ends the input
        box = _pose(c, 1)
        _click!(gui, _center(_rect(box)))
        @test box.focused[] && GUI._typing(gui)
        P0 = Vector{Float64}(BMO.position(m))
        ev.keyboardbutton[] = Makie.KeyEvent(Keyboard.left, Keyboard.press)
        @test Vector{Float64}(BMO.position(m)) == P0
        _click!(gui, beside)
        @test !box.focused[] && !GUI._typing(gui)
        close(gui)
    end

    @testset "clip planes" begin
        m, pd = _fixture()
        gui = _live_view(System([m, pd]), _gauss())
        c, ctrl = gui.cards.selection, gui.controls
        plane = GUI._add_clip_plane!(gui, [0, 0.05, 0], [0, 1, 0])
        @test ctrl.selected[] === plane
        @test c.title.text[] == "Clip plane 1"
        @test isnothing(_w(c, :hide)) && !isnothing(_w(c, :flip))
        n = plane.dir[:, 2]
        notify(_w(c, :flip).clicks)
        @test plane.dir[:, 2] ≈ -n
        notify(_w(c, :remove).clicks)
        @test !(plane in gui.clip.planes)
        @test isnothing(ctrl.selected[]) && !c.scene.visible[]
        # another object gets its own actions
        _select!(gui, m)
        @test isnothing(_w(c, :flip)) && !isnothing(_w(c, :hide))
        # a pinned plane is unpinned when it is removed
        plane = GUI._add_clip_plane!(gui, [0, 0.05, 0], [0, 1, 0])
        pinned = gui.cards.selection
        _pin!(pinned)
        @test pinned.pinned && pinned.obj === plane
        notify(_w(pinned, :remove).clicks)
        @test !pinned.pinned && !pinned.scene.visible[]
        close(gui)
    end

    @testset "pinned cards" begin
        m, pd = _fixture()
        beam = _gauss()
        # room for three cards next to each other, one of them with the rows of the detector
        gui = _live_view(System([m, pd]), beam; labels = Dict(m => "M1", pd => "PD"), size = (1800, 1100))
        ctrl = gui.controls
        c1 = gui.cards.selection
        # nothing to pin without a selection
        _pin!(c1)
        @test !c1.pinned && !c1.pin_button.active[]

        _select!(gui, m)
        _pin!(c1)
        @test c1.pinned && c1.obj === m && c1.pin_button.active[]
        # the selection gets another card
        @test gui.cards.selection !== c1 && length(gui.cards.all) == 2 && gui.widgets.step_box === gui.cards.selection.step_box
        # the pinned object shows its pinned card only, with the keyboard step while it is selected
        @test c1.scene.visible[] && !gui.cards.selection.scene.visible[]
        @test !_away(c1.step) && !_away(c1.rows)
        @test length(c1.link[]) == 2

        # the pinned card stays when the selection changes
        _select!(gui, pd)
        @test c1.scene.visible[] && gui.cards.selection.scene.visible[]
        @test c1.title.text[] == "M1" && gui.cards.selection.title.text[] == "PD"
        _select!(gui, nothing)
        @test c1.scene.visible[] && !gui.cards.selection.scene.visible[]
        # and follows its object, also when it is moved elsewhere
        set_view(gui.ax, [0.3, -0.2, 0.3], [0.0, 0.1, 0.0], [0.0, 0, 1])
        _tick!(gui)
        r0 = _rect(c1.background)
        translate3d!(m, [0.0, 0.0, 0.02])
        _tick!(gui)
        @test _rect(c1.background) != r0
        @test _pose(c1, 3).displayed_string[] == "20.0"

        # its widgets act on its object, not on the selection
        _select!(gui, pd)
        _pose(c1, 3).stored_string[] = "5"
        @test BMO.position(m)[3] ≈ 5e-3
        @test BMO.position(pd)[3] ≈ 0 atol = 1e-12
        notify(_w(c1, :hide).clicks)
        @test m in gui.objects.hidden && ctrl.selected[] === pd
        @test c1.scene.visible[] && _w(c1, :hide).label[] == "show"
        notify(_w(c1, :hide).clicks)
        @test !(m in gui.objects.hidden) && _w(c1, :hide).label[] == "hide"
        _pose(c1, 1).focused[] = true
        @test GUI._typing(gui)
        _pose(c1, 1).focused[] = false
        @test !GUI._typing(gui)

        # a second pinned card; the widgets of the newest card take the clicks
        _pin!(gui.cards.selection)
        @test length(gui.cards.all) == 3 && count(c -> c.pinned, gui.cards.all) == 2
        _select!(gui, beam)
        c3 = gui.cards.selection
        @test c3 === gui.cards.all[3] && c3.scene.visible[]
        # no card covers another
        rects = [_rect(c.background) for c in gui.cards.all]
        @test !any(GUI._overlaps(rects[i], rects[j]) for i in 1:3 for j in (i + 1):3)
        _click!(gui, _center(_rect(c3.collapse_button.box)))
        @test c3.collapsed
        sleep(0.3)  # later than a double click
        _click!(gui, _center(_rect(c3.collapse_button.box)))
        @test !c3.collapsed
        # the menu hides all cards
        gui.widgets.menu.is_open[] = true
        _tick!(gui)
        @test !any(c -> c.scene.visible[], gui.cards.all)
        gui.widgets.menu.is_open[] = false
        _tick!(gui)
        @test count(c -> c.scene.visible[], gui.cards.all) == 3

        # unpinned: hidden, and reused for the next pin
        _pin!(c1)
        @test !c1.pinned && !c1.scene.visible[] && !c1.pin_button.active[]
        _pin!(c3)
        @test gui.cards.selection === c1 && length(gui.cards.all) == 3
        close(gui)
        @test !any(c -> c.scene.visible[], gui.cards.all)
    end

    @testset "cards moved by the mouse" begin
        # the spot of a card is relative to the nearest corner of the view, inside the view
        view, size = Rect2f(0, 0, 1000, 800), Vec2f(200, 100)
        spot = GUI._card_spot(Point2f(780, 750), size, view)
        @test spot == (true, true, Vec2f(20, 50))
        @test GUI._spot_position(spot, size, view) == Point2f(780, 750)
        @test GUI._spot_position(spot, size, Rect2f(0, 0, 1200, 600)) == Point2f(980, 550)
        @test GUI._spot_position(spot, size, Rect2f(0, 0, 150, 90)) == Point2f(8, 82)
        spot = GUI._card_spot(Point2f(30, 140), size, view)
        @test spot == (false, false, Vec2f(30, 40))
        @test GUI._spot_position(spot, Vec2f(200, 30), view) == Point2f(30, 70)

        m, pd = _fixture()
        gui = _live_view(System([m, pd]), _gauss(); size = (1400, 900))
        c, ctrl = gui.cards.selection, gui.controls
        ev = events(gui.ax.scene)
        vp = Rect2f(gui.ax.scene.viewport[])
        _select!(gui, m)
        _tick!(gui)
        @test isnothing(c.spot)
        top_left(c) = Point2f(minimum(_rect(c.background))[1], maximum(_rect(c.background))[2])
        # a drag at a widget does not move the card
        box = _pose(c, 1)
        p0 = top_left(c)
        _drag!(gui, _center(_rect(box)), _center(_rect(box)) .+ Point2f(-200, 100))
        @test isnothing(c.spot) && top_left(c) == p0
        box.focused[] && Makie.defocus!(box)
        # a drag at the title moves the card to the top left corner of the view, off the objects
        target = Point2f(minimum(vp)[1] + 40, maximum(vp)[2] - 40)
        a = _center(_rect(c.title))
        eye = _eye(gui)
        _drag!(gui, a, a .+ (target - p0))
        @test _eye(gui) ≈ eye && ctrl.selected[] === m
        @test top_left(c) ≈ target
        @test c.spot[1:2] == (false, true)
        # it stays there when the camera moves, with its line to the object
        set_view(gui.ax, [0.3, -0.2, 0.3], [0.0, 0.1, 0.0], [0.0, 0, 1])
        _tick!(gui)
        @test top_left(c) ≈ target && length(c.link[]) == 2
        # and for another selected object
        _select!(gui, pd)
        _tick!(gui)
        @test top_left(c) ≈ target && c.pose[1] === pd
        # a drag beyond the view keeps the card inside the view
        a = _center(_rect(c.title))
        _drag!(gui, a, a .+ Point2f(-500, 500))
        r = _rect(c.background)
        @test minimum(r)[1] ≈ minimum(vp)[1] + GUI._CARD_MARGIN
        @test maximum(r)[2] ≈ maximum(vp)[2] - GUI._CARD_MARGIN
        _drag!(gui, _center(_rect(c.title)), _center(_rect(c.title)) .+ (target - top_left(c)))
        @test top_left(c) ≈ target

        # pinned, the card stays at its spot; the new card of the selection keeps off it
        _pin!(c)
        @test c.pinned && top_left(c) ≈ target
        _select!(gui, m)
        _tick!(gui)
        s = gui.cards.selection
        @test s !== c && isnothing(s.spot) && s.scene.visible[]
        @test !GUI._overlaps(_rect(s.background), _rect(c.background))
        # a double click at the head places the card next to its object again
        a = _center(_rect(c.title))
        _click!(gui, a)
        _click!(gui, a)
        @test isnothing(c.spot) && c.pinned
        @test !(top_left(c) ≈ target)
        # two slow clicks do not
        a = _center(_rect(c.title))
        _drag!(gui, a, a .+ (target - top_left(c)))
        @test !isnothing(c.spot)
        a = _center(_rect(c.title))
        _click!(gui, a)
        sleep(1.2 * GUI._CARD_DOUBLE_CLICK)
        _click!(gui, a)
        @test !isnothing(c.spot)
        # the buttons at the head are no handle: a click on the collapse button collapses the card
        _click!(gui, _center(_rect(c.collapse_button.box)))
        @test c.collapsed && !isnothing(c.spot) && top_left(c) ≈ target
        # an unpinned card forgets its spot
        _pin!(c)
        @test !c.pinned && isnothing(c.spot)
        close(gui)
    end

    @testset "no dock toggle in the compact layout" begin
        # the compact layout has no sidebar: its pinned cards always float, without a dock button
        m, pd = _fixture()
        gui = _live_view(System([m, pd]), _gauss())
        _select!(gui, m)
        c = gui.cards.selection
        _pin!(c)
        _tick!(gui)
        @test c.pinned && c.scene.visible[] && isnothing(c.dock_button)
        @test all(c -> isnothing(c.dock_button), gui.cards.all)
        @test GUI._is_floating(gui, m) && GUI._is_pinned(gui, m)
        # the head holds the pin and the chevron only
        @test length(c.tools.content) == 2
        # floating and docking do nothing
        GUI._dock!(gui, m)
        GUI._float!(gui, m)
        _tick!(gui)
        @test c.pinned && c.obj === m && c.scene.visible[] && count(c -> c.pinned, gui.cards.all) == 1
        close(gui)
    end

    @testset "declared rows" begin
        m, pd = _fixture()
        t = CardTestObject(BMO.shape(RoundPlanoMirror(0.01, 0.002)))
        translate3d!(t, [-0.05, 0.05, 0.0])
        # a second mirror off the beam path, with the same declarations as `m`
        m2 = RoundPlanoMirror(25e-3, 5e-3)
        translate3d!(m2, [0.1, 0.25, 0])
        solves = Ref(0)
        gui = _live_view(System([m, pd, t, m2]), _gauss(); on_change = (gui, obj) -> (solves[] += 1))
        c, ctrl = gui.cards.selection, gui.controls
        _select!(gui, t)
        # the pose rows, then its own rows; no actions
        @test _pose(c, 1) isa Textbox && _w(c, :height).text[] == "0 mm"
        @test isnothing(_w(c, :hide)) && isempty(c.actions.content)
        lift = _w(c, :lift)
        @test lift isa Slider && lift.value[] == 0
        # an input calls `on`, solves again (`solve = true`) and shows the new values on the card
        n = solves[]
        Makie.set_close_to!(lift, 3)
        @test BMO.position(t)[3] ≈ 3e-3
        @test _w(c, :height).text[] == "3 mm" && _pose(c, 3).displayed_string[] == "3.0"
        @test solves[] > n

        # the declared widgets take the clicks like the others: a click at the right end of the
        # slider sets its last value, and neither deselects nor moves the camera
        set_view(gui.ax, [0.3, -0.2, 0.3], [0.0, 0.1, 0.0], [0.0, 0, 1])
        _tick!(gui)
        eye = _eye(gui)
        r = _rect(lift)
        _click!(gui, Point2f(maximum(r)[1] - 2, _center(r)[2]))
        @test lift.value[] == 5 && BMO.position(t)[3] ≈ 5e-3
        @test ctrl.selected[] === t && _eye(gui) ≈ eye

        # another object with other declarations: new widgets, the old ones are removed
        old = copy(c.blocks)
        _select!(gui, m)
        @test isnothing(_w(c, :lift)) && _w(c, :hide) isa Button
        @test all(b -> b.parent === nothing, filter(b -> !any(x -> x === b, c.blocks), old))
        # an object with the same declarations (another mirror) keeps the widgets and shows its values
        kept = copy(c.blocks)
        _select!(gui, m2)
        @test length(c.blocks) == length(kept) && all(c.blocks .=== kept)
        @test _pose(c, 2).displayed_string[] == "250.0"
        close(gui)
    end

    @testset "ray slider of sources" begin
        m, pd = _fixture()
        src = CollimatedSource([0.0, 0, 0], [0.0, 1, 0], 2e-3, 1e-6; num_rings = 2, num_rays = 40)
        # without the preview solve of the rendered rays only, see `preview` of `live_view`
        gui = _live_view(System([m, pd]), src; preview = false)
        c = gui.cards.selection
        _select!(gui, src)
        rays = _w(c, :rays)
        @test rays.value[] == 40 && _w(c, :ray_count).text[] == "40 rays"
        # steps 1-2-5 from the minimum of the rings, 20 × 2, up to 20 000
        @test first(rays.range[]) == 40 && last(rays.range[]) == 20_000 && 200 in rays.range[]
        Makie.set_close_to!(rays, 200)
        @test length(src) == 200 && _w(c, :ray_count).text[] == "200 rays"
        # solved again: the new rays reach the detector
        @test length(BMO.hits(pd)) == 200
        close(gui)
        # a source that wraps given beams has no slider
        wrapped = CollimatedSource(BMO.beams(src), 2e-3, [0.0, 0, 0], [0.0, 1, 0])
        gui = _live_view(System([m, pd]), wrapped)
        _select!(gui, wrapped)
        @test isnothing(_w(gui.cards.selection, :rays)) && _pose(gui.cards.selection, 1) isa Textbox
        close(gui)
    end

    @testset "colors of the theme" begin
        _rgba(x) = RGBAf(Makie.to_color(x))
        _label(c, text) = only(b for b in c.blocks if b isa Label && b.text[] == text)
        for layout in (:compact, :app), theme in (:light, :dark)
            m, pd = _fixture()
            gui = _live_view(System([m, pd]), _gauss(); layout, theme, labels = Dict(m => "M1"))
            t = GUI._app_theme(theme)
            @test gui.layout.theme === t
            # a pinned card: floating in the compact layout, docked below the inspector in the app
            # layout, whose floating cards keep the colors of the theme
            GUI._toggle_pin!(gui, m)
            @test _rgba(gui.cards.selection.background.color[]) == _rgba(t.sidebar)
            @test _rgba(gui.cards.selection.background.strokecolor[]) == _rgba(t.border)
            if layout === :app
                c = only(gui.layout.inspector.pinned)
                @test c.theme === t && !any(c -> c.scene.visible[], gui.cards.all)
                @test _rgba(c.head.title.color[]) == _rgba(t.text) && c.head.title.text[] == "M1"
                @test c.head.pin.active[] && c.head.icon[] === GUI._icon(:mirror)
            else
                c = only(filter(c -> c.pinned, gui.cards.all))
                @test c.theme === t && c.scene.visible[]
                @test _rgba(c.title.color[]) == _rgba(t.text) && c.title.text[] == "M1"
                @test c.pin_button.active[] && c.icon[] === GUI._icon(:mirror)
                # the line to the object
                @test _rgba(c.scene.plots[1].color[]) == _rgba(t.accent)
            end
            # the widgets in the style of the app layout, the rotations in the gizmo colors
            @test _rgba(_pose(c, 1).boxcolor[]) == _rgba(t.field)
            @test _rgba(_pose(c, 1).textcolor[]) == _rgba(t.text)
            @test _rgba(_label(c, "x").color[]) == _rgba(t.text)
            @test [_rgba(_label(c, k).color[]) for k in ("rx", "ry", "rv")] == _rgba.(collect(t.gizmo))
            # the progress window: panel and text from the theme, the bar orange
            panel, track, bar, text = gui.trace.progress.plots
            @test _rgba(panel.color[]) == _rgba(t.sidebar) && _rgba(text.color[]) == _rgba(t.text)
            @test _rgba(track.color[]) == _rgba(t.border) && bar.color[] == GUI._PROGRESS_FILL_COLOR
            close(gui)
        end
        # the icon toggle pins the card of the selection with a click
        m, pd = _fixture()
        gui = _live_view(System([m, pd]), _gauss())
        _select!(gui, m)
        _tick!(gui)
        c = gui.cards.selection
        _click!(gui, _center(_rect(c.pin_button.box)))
        @test c.pinned && c.pin_button.active[] && gui.cards.selection !== c
        sleep(0.3)  # later than a double click
        _click!(gui, _center(_rect(c.pin_button.box)))
        @test !c.pinned && !c.pin_button.active[]
        @test_throws ArgumentError _live_view(System([m, pd]), _gauss(); theme = :blue)
        close(gui)
    end

    @testset "page Results of detectors" begin
        _results_view(args...; kwargs...) = _live_view(args...; throttle = false, progress_delay = Inf,
            size = (1600, 1000), kwargs...)
        _scroll!(gui, dy) = (events(gui.ax.scene).scroll[] = (0.0, Float64(dy)))
        _axis_center(v) = _center(Rect2f(v.ax.scene.viewport[]))
        top_left(c) = Point2f(minimum(_rect(c.background))[1], maximum(_rect(c.background))[2])
        _grip(c) = Point2f(maximum(_rect(c.background))[1] - 5, minimum(_rect(c.background))[2] + 5)

        m, pd = _fixture()
        # a detector off the beam path
        pd2 = Detector(5e-3)
        translate3d!(pd2, [0, 0.3, 0.2])
        gui = _results_view(System([m, pd, pd2]), _gauss(); labels = Dict(pd => "PD"))
        c, ctrl = gui.cards.selection, gui.controls
        ev = events(gui.ax.scene)
        # the rows of a detector: its pose, the beam and the signal
        @test length(card_rows(pd)) == length(pose_card_rows(pd)) + 2
        # nothing is shown or computed without a selected detector
        @test isnothing(GUI._card_view(c)) && isempty(GUI._shown_views(gui))
        _select!(gui, m)
        _tick!(gui)
        @test isnothing(c.view) && isempty(GUI._shown_views(gui)) && isempty(c.grip[])

        # the card of a selected detector opens on the page "Results" with the expanded view
        _select!(gui, pd)
        _tick!(gui)
        v = c.view
        @test c.page == :results && v isa GUI._DetectorView && v.expanded && c.view_expanded
        @test GUI._card_view(c) === v && only(GUI._shown_views(gui)) == (pd, v)
        @test !_away(c.view_part) && !_away(c.bar_part) && _away(c.rows) && _away(c.step) && _away(c.properties)
        @test c.view_size == GUI._CARD_VIEW_SIZE && v.ax.width[] == 280 && v.ax.height[] == 280
        # computed from the hits of the last solve and shown
        state = GUI._detector_state(gui, pd)
        @test !state.stale && state.result.n == state.opts.n
        @test v.result === state.result && GUI._kind_name(v.kind) == :intensity && v.name == "PD"
        # the view below the page bar, inside the card, at its left edge below the icon
        r, bg = Rect2f(v.full.layoutobservables.computedbbox[]), _rect(c.background)
        @test maximum(r)[2] < minimum(_rect(c.bar_part))[2]
        @test all(minimum(r) .>= minimum(bg)) && all(maximum(r) .<= maximum(bg))
        @test minimum(r)[1] ≈ minimum(bg)[1] + GUI._CARD_PADDING
        @test Makie.widths(bg)[2] ≈ GUI._card_size(c)[2] && GUI._card_size(c)[2] > 280 + Makie.widths(_rect(c.head))[2]
        @test _inside(gui)
        # its switch takes the clicks: the kind is an option of the detector
        _click!(gui, _center(_rect(v.switch.buttons[2])))
        @test state.opts.kind == :spot && GUI._kind_name(v.kind) == :spot && ctrl.selected[] === pd
        GUI._set_view!(gui, pd; kind = :auto)
        @test GUI._kind_name(v.kind) == :intensity
        v.log_toggle.active[] = true
        @test state.opts.colorscale == :log
        v.log_toggle.active[] = false

        # the wheel over the axis zooms the view and leaves the camera; a drag on the axis with
        # the right button pans and moves neither the card nor the camera
        eye, p0 = _eye(gui), top_left(c)
        lims = GUI._shown_limits(v.ax)
        _move!(gui, _axis_center(v))
        @test !GUI._over_handle(c, ev) && GUI._over_card(c, ev)
        _scroll!(gui, 1)
        zoomed = GUI._shown_limits(v.ax)
        @test zoomed[2] - zoomed[1] ≈ 0.9 * (lims[2] - lims[1]) && _eye(gui) ≈ eye
        _drag!(gui, _axis_center(v), _axis_center(v) .+ Point2f(28, -14); button = Mouse.right)
        panned = GUI._shown_limits(v.ax)
        @test panned[1] ≈ zoomed[1] - 0.1 * (zoomed[2] - zoomed[1]) && panned[2] - panned[1] ≈ zoomed[2] - zoomed[1]
        @test isnothing(c.spot) && top_left(c) == p0 && _eye(gui) ≈ eye && ctrl.selected[] === pd
        @test !isnothing(state.opts.window)
        # a drag with the left button zooms to the selected rectangle, which is the window of the
        # field; Ctrl + click returns to the automatic one
        _drag!(gui, _axis_center(v), _axis_center(v) .+ Point2f(56, 28))
        selected = GUI._shown_limits(v.ax)
        @test selected[1] ≈ (panned[1] + panned[2]) / 2 && selected[2] - selected[1] ≈ 0.2 * (panned[2] - panned[1])
        @test collect(state.opts.window) ≈ 1e-3 .* collect(selected)
        @test isnothing(c.spot) && top_left(c) == p0 && _eye(gui) ≈ eye && ctrl.selected[] === pd
        ev.keyboardbutton[] = Makie.KeyEvent(Keyboard.left_control, Keyboard.press)
        _click!(gui, _axis_center(v))
        ev.keyboardbutton[] = Makie.KeyEvent(Keyboard.left_control, Keyboard.release)
        @test isnothing(state.opts.window) && ctrl.selected[] === pd
        GUI._set_view!(gui, pd; window = 1e-3 .* selected)
        v.fit_button.clicks[] += 1
        @test isnothing(state.opts.window)
        _tick!(gui)

        # the chevron of the view collapses it to the thumbnail, which the card remembers
        h0 = Makie.widths(_rect(c.background))[2]
        @test length(c.grip[]) == 6
        _click!(gui, _center(_rect(v.collapse_button.box)))
        @test !v.expanded && !c.view_expanded && GUI._card_view(c) === v
        @test GUI._view_size(v)[2] ≈ GUI._THUMB_SIZE
        @test Makie.widths(_rect(c.background))[2] < h0 - 150 && isempty(c.grip[])
        @test all(maximum(Rect2f(v.thumb.layoutobservables.computedbbox[])) .<= maximum(_rect(c.background)))
        # a click on the thumbnail expands it again, and so does its chevron
        sleep(0.3)  # later than a double click
        _click!(gui, _center(Rect2f(v.thumb_ax.scene.viewport[])))
        @test v.expanded && c.view_expanded && Makie.widths(_rect(c.background))[2] ≈ h0
        @test isnothing(c.spot) && ctrl.selected[] === pd
        notify(v.collapse_button.clicks)
        @test !c.view_expanded
        _click!(gui, _center(_rect(v.expand_button.box)))
        @test v.expanded && c.view_expanded && length(c.grip[]) == 6

        # the page chosen by a click stays while the card shows the same object
        _click!(gui, _center(_rect(c.bar.buttons[1])))
        @test c.page == :pose && isnothing(GUI._card_view(c)) && isempty(GUI._shown_views(gui))
        @test _away(c.view_part) && !_away(c.rows) && isempty(c.grip[]) && c.view === v
        # a view that is not shown is not computed by a solve, but when it is shown again
        r0 = state.result
        GUI._resolve!(gui, nothing)
        _tick!(gui)
        @test c.page == :pose && state.stale && state.result === r0
        _click!(gui, _center(_rect(c.bar.buttons[2])))
        @test c.page == :results && !state.stale && state.result !== r0 && v.result === state.result
        # neither is the view of a collapsed card
        notify(c.collapse_button.clicks)
        @test isnothing(GUI._card_view(c)) && _away(c.view_part) && isempty(c.grip[])
        r0 = state.result
        GUI._resolve!(gui, nothing)
        @test state.stale && state.result === r0
        notify(c.collapse_button.clicks)
        @test GUI._card_view(c) === v && !state.stale && v.result === state.result

        # the grip at the bottom right corner resizes the expanded view; the card keeps its place
        _tick!(gui)
        p0 = top_left(c)
        _move!(gui, _grip(c))
        @test GUI._over_grip(c, ev) && !GUI._over_handle(c, ev)
        _drag!(gui, _grip(c), _grip(c) .+ Point2f(60, -40))
        @test c.view_size ≈ Vec2f(340, 320) && v.ax.width[] ≈ 340 && v.ax.height[] ≈ 320
        @test Makie.widths(Rect2f(v.ax.scene.viewport[])) ≈ Vec2f(340, 320)
        @test isnothing(c.spot) && _eye(gui) ≈ eye && ctrl.selected[] === pd
        @test top_left(c) ≈ p0
        @test maximum(_rect(c.background))[1] ≈ p0[1] + 340 + 2 * GUI._CARD_PADDING
        # clamped: each side at least 160 px, at most such that the card fits into the 3D view
        _drag!(gui, _grip(c), _grip(c) .+ Point2f(-600, 600))
        @test c.view_size == Vec2f(GUI._CARD_VIEW_MIN) && v.ax.width[] == 160 && v.ax.height[] == 160
        _drag!(gui, _grip(c), _grip(c) .+ Point2f(3000, -3000))
        vp = Rect2f(gui.ax.scene.viewport[])
        @test Makie.widths(_rect(c.background)) ≈ Makie.widths(vp) .- 2 * GUI._CARD_MARGIN
        @test c.view_size[1] ≈ Makie.widths(vp)[1] - 2 * GUI._CARD_MARGIN - 2 * GUI._CARD_PADDING
        @test _inside(gui)
        _drag!(gui, _grip(c), _grip(c) .+ (Point2f(minimum(_rect(c.background))[1] + 216, maximum(_rect(c.background))[2] - 300) .- _grip(c)))
        size0 = c.view_size
        @test 160 < size0[1] < 400

        # pinning keeps the page, the expanded state and the size of the view
        notify(v.collapse_button.clicks)
        _pin!(c)
        _tick!(gui)
        @test c.pinned && c.page == :results && c.view === v && !c.view_expanded && c.view_size == size0
        @test GUI._card_view(c) === v
        notify(v.expand_button.clicks)
        @test v.ax.width[] ≈ size0[1] && v.ax.height[] ≈ size0[2]
        # the selection gets another card; a second detector has its own view and state
        _select!(gui, pd2)
        _tick!(gui)
        c2 = gui.cards.selection
        v2 = c2.view
        @test c2 !== c && c2.page == :results && v2 isa GUI._DetectorView && v2 !== v && v2.expanded
        @test c2.view_size == GUI._CARD_VIEW_SIZE
        @test Set(GUI._shown_views(gui)) == Set([(pd, v), (pd2, v2)])
        @test isnothing(v2.kind) && isnothing(GUI._detector_state(gui, pd2).result.kind)
        @test !GUI._overlaps(_rect(c.background), _rect(c2.background))
        # a press on the view of a pinned card does not select its object
        _click!(gui, _axis_center(v))
        @test ctrl.selected[] === pd2
        # a solve computes both shown views
        r0 = state.result
        GUI._resolve!(gui, nothing)
        @test state.result !== r0 && !state.stale && v.result === state.result
        # another object without a view: the view of the card is removed, with its listeners
        n = length(Makie.Observables.listeners(ev.scroll))
        _select!(gui, m)
        _tick!(gui)
        @test isnothing(c2.view) && c2.page == :pose && only(GUI._shown_views(gui)) == (pd, v)
        @test length(Makie.Observables.listeners(ev.scroll)) < n
        @test isempty(v2.listeners)
        # the cards are hidden while a menu is open: no view is shown, afterwards it is again
        gui.widgets.menu.is_open[] = true
        _tick!(gui)
        @test isempty(GUI._shown_views(gui))
        gui.widgets.menu.is_open[] = false
        _tick!(gui)
        @test only(GUI._shown_views(gui)) == (pd, v) && c.view_shown
        # unpinned: the card is a spare card without a view
        _pin!(c)
        @test !c.pinned && isnothing(c.view) && isempty(GUI._shown_views(gui)) && isempty(v.listeners)
        @test c.view_expanded && c.view_size == GUI._CARD_VIEW_SIZE
        close(gui)

        # ray hits: the spot diagram first, the PSF by the switch
        m, pd = _fixture()
        src = CollimatedSource([0.0, 0, 0], [0.0, 1, 0], 2e-3, 1e-6; num_rings = 2, num_rays = 40)
        gui = _results_view(System([m, pd]), src; preview = false)
        c = gui.cards.selection
        _select!(gui, pd)
        _tick!(gui)
        v = c.view
        @test GUI._kind_name(v.kind) == :spot && v.switch.keys == [:spot, :psf]
        _click!(gui, _center(_rect(v.switch.buttons[2])))
        @test GUI._kind_name(v.kind) == :psf && GUI._detector_state(gui, pd).opts.kind == :psf
        close(gui)
    end

    @testset "no cards in the spectator mode" begin
        m, pd = _fixture()
        gui = _live_view(System([m, pd]), _gauss(); labels = Dict(m => "M1", pd => "PD"),
            size = (1600, 1000))
        ctrl = gui.controls
        _select!(gui, m)
        c = gui.cards.selection
        _pin!(c)
        # a measurement, whose card is kept by its pin
        gui.widgets.measure_toggle.active[] = true
        GUI._add_measure_point!(gui, BMO.position(m), m)
        GUI._add_measure_point!(gui, BMO.position(pd), pd)
        info = GUI._info_card(gui)
        info.pin_button.active[] = true
        gui.widgets.measure_toggle.active[] = false
        # the spectator mode clears the selection, with which the pinned card loses step and mode
        _select!(gui, nothing)
        _tick!(gui)
        @test c.scene.visible[] && info.scene.visible[] && info.pinned
        r, ri = _rect(c.background), _rect(info.background)
        # hidden with all their parts, still pinned
        GUI._set_spectator!(ctrl, true)
        _tick!(gui)
        @test !any(x -> x.scene.visible[], gui.cards.all)
        @test all(_away, (c.head, c.rows, c.background, info.head, info.background))
        @test c.pinned && c.obj === m && info.pinned && info.obj isa GUI._Measurement
        # shown again at the same places
        GUI._set_spectator!(ctrl, false)
        _tick!(gui)
        @test c.scene.visible[] && info.scene.visible[]
        @test _rect(c.background) ≈ r && _rect(info.background) ≈ ri
        close(gui)
    end

    @testset "info cards of the inspection and the measurement" begin
        _info(y; w = nothing, R = nothing) = (; point = [0.0, y, 0.0], direction = [0.0, 1.0, 0.0],
            length = y, opl = y, w, R)
        _text(c, name) = _w(c, name).text[]
        m, pd = _fixture()
        gui = _live_view(System([m, pd]), _gauss(); labels = Dict(m => "M1", pd => "PD"))
        # an inspected point: a transient card at the point, its pin off, no step box
        GUI._show_inspection!(gui, _info(0.05))
        c = GUI._info_card(gui)
        @test c.transient && c.obj isa GUI._BeamPoint && c.scene.visible[] && !c.pin_button.active[]
        @test c.title.text[] == "Beam" && c.icon[] === GUI._icon(:trace)
        @test _text(c, :at) == "(0.000, 50.000, 0.000) mm" && _text(c, :path) == "50.000 mm"
        @test isnothing(_w(c, :w)) && isnothing(_w(c, :hide)) && _away(c.step)
        # a card with one page: no page bar, no properties of a point
        @test c.pages == (:pose,) && c.page == :pose && isnothing(c.bar) && isnothing(c.bar_part)
        @test all(_away, first.(values(c.bars))) && _away(c.properties) && !_away(c.rows)
        @test length(c.link[]) == 2
        # the next inspection replaces it, with the rows of a Gaussian beamlet
        GUI._show_inspection!(gui, _info(0.06; w = 1e-3, R = 0.0))
        @test GUI._info_card(gui) === c && _text(c, :at) == "(0.000, 60.000, 0.000) mm"
        @test _text(c, :w) == "1 mm" && _text(c, :R) == "∞"
        # its pin keeps it, the next inspection gets another card
        c.pin_button.active[] = true
        @test !c.transient && c.pinned && isnothing(GUI._info_card(gui))
        # the card keeps the marker of the point, which the next inspection does not remove
        marker = only(c.obj.plots)
        @test isnothing(gui.measure.inspection_plot) && marker in gui.ax.scene.plots
        GUI._show_inspection!(gui, _info(0.07))
        c2 = GUI._info_card(gui)
        @test c2 !== c && c.scene.visible[] && c2.scene.visible[]
        # clearing the inspection (a click elsewhere, Esc) removes the transient card only
        GUI._clear_inspection!(gui)
        @test isnothing(GUI._info_card(gui)) && !c2.scene.visible[] && c.scene.visible[]
        # unpinned: removed
        c.pin_button.active[] = false
        @test !c.pinned && !c.scene.visible[]
        @test !(marker in gui.ax.scene.plots)

        # a measurement: the first point, then the distance, its components and the angle
        gui.widgets.measure_toggle.active[] = true
        GUI._add_measure_point!(gui, BMO.position(m), m)
        c = GUI._info_card(gui)
        @test c.obj isa GUI._Measurement && c.title.text[] == "Measurement"
        @test _text(c, :at) == "M1, (0.000, 100.000, 0.000) mm"
        GUI._add_measure_point!(gui, BMO.position(pd), pd)
        @test GUI._info_card(gui) === c
        @test _text(c, :from) == "M1" && _text(c, :to) == "PD"
        @test _text(c, :distance) == "100.0 mm" && _text(c, :delta) == "(100.000, 0.000, 0.000) mm"
        @test _text(c, :angle) == "785 mrad"
        # its pin keeps the card with the line and the markers; switching measuring off removes
        # only the transient card of a new measurement
        c.pin_button.active[] = true
        kept = copy(c.obj.plots)
        @test length(kept) == 2 && isempty(gui.measure.plots)
        GUI._add_measure_point!(gui, BMO.position(m), m)
        c3 = GUI._info_card(gui)
        @test c3 !== c && all(p -> p in gui.ax.scene.plots, kept)
        # unpinned: its plots are removed
        c.pin_button.active[] = false
        @test !c.pinned && !any(p -> p in gui.ax.scene.plots, kept)
        c = c3
        gui.widgets.measure_toggle.active[] = false
        @test isnothing(GUI._info_card(gui)) && !c.scene.visible[]
        close(gui)

        # app layout: the transient card floats at the point, its pin docks the item below the
        # inspector
        m, pd = _fixture()
        gui = _live_view(System([m, pd]), _gauss(); layout = :app)
        GUI._show_inspection!(gui, _info(0.05))
        c = GUI._info_card(gui)
        @test c.scene.visible[]
        c.pin_button.active[] = true
        d = only(gui.layout.inspector.pinned)
        @test d.obj isa GUI._BeamPoint && d.head.title.text[] == "Beam"
        @test GUI._card_widget(d, :at).text[] == "(0.000, 50.000, 0.000) mm"
        @test isnothing(GUI._info_card(gui)) && !c.scene.visible[]
        # the kept marker moves with the card between the sidebar and the 3D view
        x = d.obj
        marker = only(x.plots)
        GUI._float!(gui, x)
        f = only(GUI._floating_cards(gui, x))
        @test !f.transient && isempty(gui.layout.inspector.pinned) && marker in gui.ax.scene.plots
        GUI._dock!(gui, x)
        @test GUI._is_docked(gui, x) && isempty(GUI._floating_cards(gui, x))
        @test marker in gui.ax.scene.plots
        # the dock button of a transient card keeps it, docked once
        GUI._show_inspection!(gui, _info(0.06))
        c = GUI._info_card(gui)
        notify(c.dock_button.clicks)
        @test length(gui.layout.inspector.pinned) == 2 && isnothing(GUI._info_card(gui))
        # unpinned: its marker is removed
        GUI._unpin!(gui, x)
        @test !GUI._is_pinned(gui, x) && !(marker in gui.ax.scene.plots)
        close(gui)
    end

    @testset "widget protocol of the blocks of Makie" begin
        # the cards use the public verbs only, see `card_input` and `card_show!`
        @test !isdefined(GUI, :_widget_input) && !isdefined(GUI, :_show!)
        fig = Figure()
        slider = Slider(fig[1, 1]; range = 0:10)
        toggle = Toggle(fig[2, 1])
        box = Textbox(fig[3, 1])
        button = Button(fig[4, 1])
        menu = Menu(fig[5, 1]; options = ["a", "b"])
        label = Label(fig[6, 1], "")
        @test BeamletOpticsGUI.card_input(slider) === slider.value
        @test BeamletOpticsGUI.card_input(toggle) === toggle.active
        @test BeamletOpticsGUI.card_input(box) === box.stored_string
        @test BeamletOpticsGUI.card_input(button) === button.clicks
        @test BeamletOpticsGUI.card_input(menu) === menu.selection
        # no input: labels and any other type
        @test isnothing(BeamletOpticsGUI.card_input(label))
        @test isnothing(BeamletOpticsGUI.card_input(42))
        BeamletOpticsGUI.card_show!(slider, 7)
        @test slider.value[] == 7
        BeamletOpticsGUI.card_show!(toggle, true)
        @test toggle.active[]
        BeamletOpticsGUI.card_show!(button, "hide")
        @test button.label[] == "hide"
        BeamletOpticsGUI.card_show!(label, 1.5)
        @test label.text[] == "1.5"
        # a textbox shows the value without an input, but keeps what is typed, unless `force`
        n = Ref(0)
        on(_ -> (n[] += 1), box.stored_string)
        BeamletOpticsGUI.card_show!(box, 12)
        @test box.displayed_string[] == "12" && box.stored_string[] == "12"
        box.focused[] = true
        BeamletOpticsGUI.card_show!(box, 13)
        @test box.displayed_string[] == "12"
        BeamletOpticsGUI.card_show!(box, 13; force = true)
        @test box.displayed_string[] == "13"
        @test n[] == 0
        # shows nothing for any other type
        @test isnothing(BeamletOpticsGUI.card_show!(menu, "b"))
        @test isnothing(BeamletOpticsGUI.card_show!(42, 1))
    end
end

end
