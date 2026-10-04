module TestLiveScroll

using GLMakie, BeamletOptics, BeamletOpticsGUI
using Makie
using Test

const GUI = BeamletOpticsGUI

@testset "Scroll areas" begin
    _rect(block) = Rect2f(block.layoutobservables.computedbbox[])
    _rect(r::Rect2f) = r
    _mouse!(fig, p) = (events(fig).mouseposition[] = (Float64(p[1]), Float64(p[2])))
    _press!(fig) = (events(fig).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.press))
    _release!(fig) = (events(fig).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.release))
    _click!(fig, p) = (_mouse!(fig, p); _press!(fig); _release!(fig))
    _center(block) = (r = _rect(block); minimum(r) .+ Makie.widths(r) ./ 2)
    _center(r::Rect2f) = minimum(r) .+ Makie.widths(r) ./ 2
    _wheel!(fig, dy) = (events(fig).scroll[] = (0.0, Float64(dy)))

    # Ten buttons of 30 px with gaps of 8 px and a padding of 10 px: 392 px in a region of 200 px
    function _fixture(; n = 10)
        fig = Figure(; size = (400, 300))
        region = Observable(Rect2f(0, 50, 200, 200))
        area = GUI._ScrollArea(fig.scene, region; padding = 10, default_rowgap = 8)
        buttons = [Button(area.layout[i, 1]; label = "b$i", height = 30, tellwidth = false) for i in 1:n]
        return fig, region, area, buttons
    end

    @testset "content and offset" begin
        fig, region, area, buttons = _fixture()
        @test area.height[] ≈ 392
        @test GUI._max_offset(area) ≈ 192
        @test area.offset[] == 0
        # the top of the content at the top of the region
        @test maximum(_rect(buttons[1]))[2] ≈ 240
        @test 10 <= minimum(_rect(buttons[1]))[1] && maximum(_rect(buttons[1]))[1] <= 190
        @test minimum(_rect(buttons[10]))[2] ≈ 250 - 392 + 10
        GUI._set_offset!(area, 100)
        @test area.offset[] == 100 && maximum(_rect(buttons[1]))[2] ≈ 340
        # within its limits
        GUI._set_offset!(area, 1000)
        @test area.offset[] ≈ 192 && minimum(_rect(buttons[10]))[2] ≈ 60
        GUI._set_offset!(area, -5)
        @test area.offset[] == 0
        # the blocks lie behind the rest of the window, with events of their own
        @test area.scene.transformation.translation[][3] == GUI._SCROLL_Z
        @test buttons[1].blockscene.parent === area.scene
        @test events(buttons[1].blockscene) === area.events !== events(fig)
        @test area.events.keyboardbutton === events(fig).keyboardbutton
        # the region follows the window: the offset stays within its limits
        GUI._set_offset!(area, 192)
        region[] = Rect2f(0, 50, 200, 300)
        @test GUI._max_offset(area) ≈ 92 && area.offset[] ≈ 92
        @test minimum(_rect(buttons[10]))[2] ≈ 60
        # a content that fits stays at the top of the region and does not scroll
        region[] = Rect2f(0, 0, 200, 500)
        @test area.height[] ≈ 392 && GUI._max_offset(area) == 0 && area.offset[] == 0
        @test maximum(_rect(buttons[1]))[2] ≈ 490
        # the content changes
        region[] = Rect2f(0, 50, 200, 200)
        more = Button(area.layout[11, 1]; label = "more", height = 30, tellwidth = false)
        @test area.height[] ≈ 430
        delete!(more)
        Makie.trim!(area.layout)
        @test area.height[] ≈ 392
    end

    @testset "mouse wheel" begin
        fig, region, area, buttons = _fixture()
        seen = Ref(0)
        on(_ -> (seen[] += 1), events(fig).scroll)
        _mouse!(fig, (100, 150))
        _wheel!(fig, -1)
        # consumed: a listener behind it, e.g. the camera of a 3D view, does not get it
        @test area.offset[] ≈ GUI._SCROLL_STEP && seen[] == 0
        _wheel!(fig, -10)
        @test area.offset[] ≈ 192
        _wheel!(fig, 2)
        @test area.offset[] ≈ 192 - 2 * GUI._SCROLL_STEP
        # beside the region: passed on
        _mouse!(fig, (300, 150))
        _wheel!(fig, -1)
        @test area.offset[] ≈ 192 - 2 * GUI._SCROLL_STEP && seen[] == 1
        _mouse!(fig, (100, 20))
        _wheel!(fig, -1)
        @test seen[] == 2
        # a block of the area takes the wheel first
        taken = Ref(0)
        on(_ -> (taken[] += 1; Consume(true)), area.events.scroll)
        _mouse!(fig, (100, 150))
        o = area.offset[]
        _wheel!(fig, 1)
        @test taken[] == 1 && area.offset[] == o && seen[] == 2
        # a content that fits: the wheel is passed on
        fig, region, area, buttons = _fixture(; n = 3)
        seen = Ref(0)
        on(_ -> (seen[] += 1), events(fig).scroll)
        _mouse!(fig, (100, 150))
        _wheel!(fig, -1)
        @test area.offset[] == 0 && seen[] == 1
    end

    @testset "the mouse in the region only" begin
        fig, region, area, buttons = _fixture()
        GUI._set_offset!(area, 100)
        # button 5 is in the region, button 1 above it, button 10 below it
        @test all(y -> 50 < y < 250, (minimum(_rect(buttons[5]))[2], maximum(_rect(buttons[5]))[2]))
        @test minimum(_rect(buttons[1]))[2] > 250 && maximum(_rect(buttons[10]))[2] < 50
        @test GUI._in_area(area, _center(buttons[5])) && !GUI._in_area(area, _center(buttons[1]))
        _click!(fig, _center(buttons[5]))
        @test buttons[5].clicks[] == 1
        @test area.events.mouseposition[] == Tuple(Float64.(_center(buttons[5])))
        # scrolled out: the click at its place belongs to what covers it
        _click!(fig, _center(buttons[1]))
        _click!(fig, _center(buttons[10]))
        @test buttons[1].clicks[] == 0 && buttons[10].clicks[] == 0
        @test area.events.mouseposition[] == GUI._SCROLL_NOWHERE
        # the presses are passed on, e.g. such that a textbox loses its focus
        presses = Ref(0)
        on(e -> (e.action == Mouse.press && (presses[] += 1); Consume(false)), area.events.mousebutton)
        _click!(fig, (300, 150))
        @test presses[] == 1
        # a press in the region keeps the mouse until it is released, e.g. the drag of a slider
        _mouse!(fig, _center(buttons[5]))
        _press!(fig)
        _mouse!(fig, (300, 20))
        @test area.events.mouseposition[] == (300.0, 20.0)
        _release!(fig)
        @test area.events.mouseposition[] == GUI._SCROLL_NOWHERE
    end

    @testset "elastic row" begin
        fig = Figure(; size = (400, 600))
        region = Observable(Rect2f(0, 0, 200, 400))
        area = GUI._ScrollArea(fig.scene, region; padding = 10, default_rowgap = 8)
        top = Button(area.layout[1, 1]; label = "top", height = 30, tellwidth = false)
        middle = Box(area.layout[2, 1]; tellheight = false)
        bottom = Button(area.layout[3, 1]; label = "bottom", height = 50, tellwidth = false)
        GUI._set_elastic!(area, 2, 100)
        # 20 (padding) + 30 + 50 + 16 (gaps) = 116: the row takes the rest of the region
        @test area.elastic_size ≈ 284 && Makie.widths(_rect(middle))[2] ≈ 284
        @test area.height[] ≈ 400 && GUI._max_offset(area) == 0
        @test minimum(_rect(bottom))[2] ≈ 10
        # a lower region: at least its smallest height, then the area scrolls
        region[] = Rect2f(0, 0, 200, 180)
        @test area.elastic_size ≈ 100 && area.height[] ≈ 216 && GUI._max_offset(area) ≈ 36
        region[] = Rect2f(0, 0, 200, 300)
        @test area.elastic_size ≈ 184 && GUI._max_offset(area) == 0
        # the other rows grow
        bottom.height[] = 150
        @test area.elastic_size ≈ 100 && area.height[] ≈ 316
        # another row is elastic: the old one tells its height again
        GUI._set_elastic!(area, 0)
        @test area.layout.rowsizes[2] == Auto()
        rowsize!(area.layout, 2, Fixed(40))
        filler = Box(area.layout[4, 1]; tellheight = false)
        GUI._set_elastic!(area, 4, 0)
        # 20 + 30 + 40 + 150 + 24 = 264
        @test area.elastic_size ≈ 36 && area.height[] ≈ 300
        region[] = Rect2f(0, 0, 200, 200)
        @test area.elastic_size == 0 && area.height[] ≈ 264
        # a row that does not tell its height: no scrolling
        rowsize!(area.layout, 2, Auto(false))
        GUI._fit_area!(area)
        @test area.height[] ≈ 200 && GUI._max_offset(area) == 0
    end

    @testset "sidebars of the app layout" begin
        m = RoundPlanoMirror(25e-3, 5e-3)
        translate3d!(m, [0, 0.2, 0])
        pd = Detector(20e-3)
        translate3d!(pd, [0, 0.3, 0])
        gui = live_view(System([m, pd]) => Beam([0.0, 0, 0], [0.0, 1, 0], 1e-6); layout = :app,
            size = (1400, 560), trace_budget = Inf)
        layout, fig = gui.layout, gui.fig
        left, right = layout.left.area, layout.right.area
        @test layout.left.grid === left.layout && layout.right.grid === right.layout
        @test left.region[] == _rect(layout.left.box) && right.region[] == _rect(layout.right.box)
        # the backgrounds lie behind the sections, which lie behind the rest of the window
        @test layout.left.box.blockscene.transformation.translation[][3] == GUI._SCROLL_BACKGROUND_Z
        @test gui.widgets.step_box.blockscene.parent === right.scene
        @test layout.tree.scene.parent.parent === left.scene
        # the object tree takes the free height of the left sidebar, at least its smallest one:
        # with the docked catalog below it, the sidebar is higher than the low window
        @test left.elastic == 2 && left.elastic_size == GUI._SIDEBAR_GROW_MIN
        @test Makie.widths(_rect(layout.tree.box))[2] ≈ GUI._SIDEBAR_GROW_MIN
        @test GUI._max_offset(left) > 0
        # the right one fits: its filler takes the free height
        @test GUI._max_offset(right) == 0 && right.elastic_size > 0
        # the wheel in the sidebar scrolls it, also over the tree, whose rows fit; the 3D view
        # does not zoom
        eye = copy(Makie.cameracontrols(gui.ax.scene).eyeposition[])
        top = maximum(_rect(layout.tree.box))[2]
        _mouse!(fig, _center(layout.tree.box))
        _wheel!(fig, -1)
        @test left.offset[] ≈ min(GUI._SCROLL_STEP, GUI._max_offset(left))
        @test maximum(_rect(layout.tree.box))[2] ≈ top + left.offset[]
        @test Makie.cameracontrols(gui.ax.scene).eyeposition[] == eye
        _wheel!(fig, 1)
        @test left.offset[] == 0
        # a card pinned in the right sidebar: the view of the detector is as high as the sidebar
        # is wide, the sidebar scrolls
        gui.controls.selected[] = pd
        GUI._toggle_pin!(gui, pd)
        @test GUI._max_offset(right) > 0
        GUI._set_offset!(right, 1e4)
        name = layout.inspector.name
        @test minimum(_rect(name))[2] > maximum(right.region[])[2]
        # scrolled out below the toolbar: a click there does not reach the pin of the inspector
        pin = layout.inspector.pin
        @test pin.active[]
        _click!(fig, _center(pin.box))
        @test pin.active[] && GUI._is_pinned(gui, pd)
        # a higher window: both fit again, the tree takes the free height
        resize!(fig.scene, 1400, 1300)
        @test GUI._max_offset(left) == 0 && left.offset[] == 0 && left.elastic_size > GUI._SIDEBAR_GROW_MIN
        @test GUI._max_offset(right) == 0 && right.offset[] == 0
        @test maximum(_rect(name))[2] < maximum(right.region[])[2]
        # a collapsed sidebar is off-screen and takes no wheel
        layout.collapse.left.active[] = false
        @test !left.visible[] && maximum(_rect(layout.tree.box))[1] < -1e4
        layout.collapse.left.active[] = true
        @test left.visible[] && minimum(_rect(layout.tree.box))[1] >= 0
        # the listeners of the sidebars end with those of the controls
        @test all(l -> any(k -> k === l, gui.controls.listeners), (left.listeners..., right.listeners...))
        close(gui)
        @test isempty(gui.controls.listeners)
    end

    @testset "hidden" begin
        fig, region, area, buttons = _fixture()
        GUI._set_area_shown!(area, false)
        @test maximum(_rect(buttons[1]))[1] < -1e4
        @test !GUI._in_area(area, (100, 150))
        _mouse!(fig, (100, 150))
        _wheel!(fig, -1)
        @test area.offset[] == 0 && area.events.mouseposition[] == GUI._SCROLL_NOWHERE
        GUI._set_area_shown!(area, true)
        @test maximum(_rect(buttons[1]))[2] ≈ 240
        _wheel!(fig, -1)
        @test area.offset[] ≈ GUI._SCROLL_STEP
    end
end

end
