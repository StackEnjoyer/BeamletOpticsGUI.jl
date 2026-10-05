module TestLiveCompact

using GLMakie, BeamletOptics, BeamletOpticsGUI
using Makie
using Test

const BMO = BeamletOptics
const GUI = BeamletOpticsGUI

@testset "Compact layout" begin
    GLB = Makie.GridLayoutBase

    # Rays along +y, the mirror at 45° reflects them along +x onto the detector
    function _fixture(; kwargs...)
        m = RoundPlanoMirror(25e-3, 5e-3)
        zrotate3d!(m, deg2rad(45))
        translate3d!(m, [0, 0.1, 0])
        pd = Detector(5e-3)
        zrotate3d!(pd, -π / 2)
        translate3d!(pd, [0.1, 0.1, 0])
        gui = live_view(System([m, pd]) => Beam([0.0, 0, 0], [0.0, 1, 0]); throttle = false,
            kwargs...)
        return gui, m, pd
    end

    ev(gui) = events(gui.ax.scene)
    _tick!(gui) = (ev(gui).tick[] = Makie.Tick(Makie.RegularRenderTick, 0, 0.0, 1.0))
    _key!(gui, key) = (ev(gui).keyboardbutton[] = Makie.KeyEvent(key, Keyboard.press))
    _center(r::Rect2f) = Point2f(minimum(r) .+ Makie.widths(r) ./ 2)
    _rect(block) = Rect2f(block.layoutobservables.computedbbox[])
    # A click (press and release without moving) at the figure pixel `p`
    function _click!(gui, p)
        ev(gui).mouseposition[] = (p[1], p[2])
        ev(gui).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.press)
        ev(gui).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.release)
        return nothing
    end
    _parked(part) = minimum(part.outer.layoutobservables.suggestedbbox[])[1] < -1.0f4
    _overlaps(a, b) = all(minimum(a) .< maximum(b)) && all(minimum(b) .< maximum(a))
    # The grid that holds the block `b` of a tool
    _grid(b) = GLB.gridcontent(b).parent

    @testset "only the 3D view in the figure" begin
        gui, _, _ = _fixture(; detectors = [])
        root = gui.fig.layout
        @test size(root) == (1, 1)
        @test only(root.content).content === gui.ax
        # the widgets of the shared logic still exist, in the overlay
        @test gui.status isa Makie.Label && gui.widgets.info isa Makie.Label
        @test gui.widgets.menu isa Makie.Menu && gui.widgets.views_menu isa Makie.Menu
        close(gui)

        # also with detectors: their views are on their cards
        gui, _, pd = _fixture()
        @test size(gui.fig.layout) == (1, 1) && isnothing(gui.layout.panels)
        GUI._pin_view!(gui, pd)
        @test size(gui.fig.layout) == (1, 1) && GUI._is_pinned(gui, pd)
        @test only(GUI._floating_cards(gui, pd)).page == :results
        close(gui)

        # the panels of `add_panel!` are in fig[1, 2]
        gui, _, _ = _fixture()
        add_panel!(layout -> Axis(layout[1, 1]), gui, "Panel")
        root = gui.fig.layout
        @test size(root) == (1, 2)
        # the 3D view, and the panels with the background box of their collapsible part
        @test sort([(c.span.rows, c.span.cols) for c in root.content]) ==
              [(1:1, 1:1), (1:1, 2:2), (1:1, 2:2)]
        @test gui.layout.panel_part.grid === gui.layout.panels && gui.layout.panel_part.shown
        close(gui)
    end

    @testset "typed widgets of the shared logic" begin
        # the fields of `_LayoutWidgets` are unchanged, see `AbstractLiveLayout`
        @test fieldnames(GUI._LayoutWidgets) == (:trace_button, :auto_trace_toggle,
            :clip_beams_toggle, :orthographic_toggle, :sources_toggle, :measure_toggle,
            :export_button, :home_button, :save_view_button, :show_all_button, :step_box, :menu,
            :views_menu, :view_cube, :info)
        @test fieldtype(GUI._LayoutWidgets, :step_box) == Makie.Textbox
        @test fieldtype(GUI._LayoutWidgets, :menu) == Union{Nothing, Makie.Menu}
        @test fieldtype(GUI._LayoutWidgets, :views_menu) == Makie.Menu
        @test fieldtype(GUI._LayoutWidgets, :info) == Union{Nothing, Makie.Label}
    end

    @testset "tool rail" begin
        gui, m, _ = _fixture()
        o = gui.layout.overlay
        # closed at start: only the pill and "⋯" take clicks, the rail is away
        @test !GUI._rail_open(o) && _parked(o.rail)
        @test length(GUI._overlay_rects(o)) == 2
        # "⋯" opens it, above the button
        more = _center(GUI._overlay_rect(o.more))
        _click!(gui, more)
        @test GUI._rail_open(o) && !_parked(o.rail)
        rail = GUI._overlay_rect(o.rail)
        @test minimum(rail)[2] > maximum(GUI._overlay_rect(o.more))[2]
        # the controls ignore the clicks on it, the camera gets no press
        ev(gui).mouseposition[] = Tuple(_center(rail))
        @test GUI._outside_view(gui) && GUI._over_layout(gui)
        # a click on an entry uses its tool and keeps the rail open
        n = gui.widgets.trace_button.clicks[]
        _click!(gui, _center(_rect(gui.widgets.trace_button.box)))
        @test gui.widgets.trace_button.clicks[] == n + 1 && GUI._rail_open(o)
        # "⋯" closes it again
        _click!(gui, more)
        @test !GUI._rail_open(o) && _parked(o.rail)
        # Esc closes it before it deselects
        o.more_button.active[] = true
        gui.controls.selected[] = m
        _key!(gui, Keyboard.escape)
        @test !GUI._rail_open(o) && gui.controls.selected[] === m
        _key!(gui, Keyboard.escape)
        @test isnothing(gui.controls.selected[])
        # a click outside closes it
        o.more_button.active[] = true
        vp = Rect2f(Makie.viewport(gui.ax.scene)[])
        _click!(gui, Point2f(maximum(vp)[1] - 200, minimum(vp)[2] + 300))
        @test !GUI._rail_open(o)
        close(gui)
    end

    @testset "built-in tools in the rail or the camera popover" begin
        gui, _, _ = _fixture()
        o = gui.layout.overlay
        w = gui.widgets
        roles = [s.role for s in GUI._tools(gui.layout)]
        @test roles == [:trace_button, :auto_trace_toggle, :show_all_button, :home_button,
            :fit_button, :views_button, :save_view_button, :orthographic_toggle,
            :clip_beams_toggle, :sources_toggle, :measure_toggle, :export_button]
        widget(role) = role === :fit_button ? o.fit_button :
                       role === :views_button ? o.views_button : getfield(w, role)
        for role in roles
            @test _grid(widget(role).box) in (o.rail_tools, o.camera_tools)
        end
        # the rail in the order of the plan, the camera tools in the popover
        rows = [GLB.gridcontent(widget(r).box).span.rows.start for r in (:trace_button,
            :auto_trace_toggle, :sources_toggle, :clip_beams_toggle, :measure_toggle,
            :show_all_button, :export_button)]
        @test issorted(rows)
        @test all(r -> _grid(widget(r).box) === o.camera_tools, (:home_button, :fit_button,
            :views_button, :save_view_button, :orthographic_toggle))
        @test _grid(_grid(w.menu)) === o.rail_tools
        @test _grid(w.views_menu) === o.camera_tools
        # toggles and buttons like Makie's, initialized from the kwargs
        @test w.auto_trace_toggle.active[] && !w.measure_toggle.active[]
        @test w.trace_button.label[] == "Trace (t)" && w.sources_toggle.label[] == "Sources (1)"
        # the views icon opens the views menu
        o.views_button.clicks[] += 1
        @test w.views_menu.is_open[]
        w.views_menu.is_open[] = false
        close(gui)
    end

    @testset "camera popover" begin
        gui, _, _ = _fixture()
        o = gui.layout.overlay
        @test !o.camera_shown && _parked(o.camera)
        cube = Rect2f(Makie.viewport(gui.widgets.view_cube.scene)[])
        ev(gui).mouseposition[] = Tuple(_center(cube))
        @test o.camera_shown && !_parked(o.camera)
        cam = GUI._overlay_rect(o.camera)
        # below the cube, which it does not cover: a click on the cube still turns the camera
        @test maximum(cam)[2] <= minimum(cube)[2] && !_overlaps(cam, cube)
        @test !GUI._over_layout(gui)
        ev(gui).mouseposition[] = Tuple(_center(cam))
        @test GUI._over_layout(gui)
        # hidden 0.3 s after the mouse left both
        ev(gui).mouseposition[] = (5.0, 300.0)
        @test o.camera_shown
        sleep(0.8)
        @test !o.camera_shown && _parked(o.camera)
        close(gui)

        # without a view cube, always shown
        gui, _, _ = _fixture(; view_cube = false)
        @test gui.layout.overlay.camera_shown && !_parked(gui.layout.overlay.camera)
        close(gui)
    end

    @testset "own tools, controls and sliders in the rail" begin
        n = Ref(0)
        # without the catalog, whose toggle "Components" is a tool of the rail as well
        gui, _, _ = _fixture(; sliders = ["gap" => (0:0.1:1, v -> (n[] += 1))],
            catalog = CatalogEntry[])
        o = gui.layout.overlay
        tool = add_tool!(g -> nothing, gui, "Tool"; icon = :measure)
        toggle = add_tool!((g, v) -> nothing, gui, "Switch"; toggle = true)
        power = Ref{Any}(nothing)
        layout = add_controls!(gui, "Power") do layout
            power[] = Toggle(layout[1, 1])
            nothing
        end
        @test _grid(tool.box) === o.rail_tools && _grid(toggle.box) === o.rail_tools
        @test tool.label[] == "Tool" && !toggle.active[]
        row(b) = GLB.gridcontent(b).span.rows.start
        export_row = row(gui.widgets.export_button.box)
        (sliders_item, sliders_part), (controls_item, controls_part) = o.sections
        # below the built-in tools: the tools, the sections of the controls, the sliders
        @test export_row < row(tool.box) < row(toggle.box) < row(controls_item.box) <
              row(sliders_item.box)
        @test sliders_item.label[] == "Sliders" && controls_item.label[] == "Power"
        # an entry opens its popover right of the rail, another entry replaces it
        o.more_button.active[] = true
        _tick!(gui)
        @test _parked(controls_part) && _parked(sliders_part)
        _click!(gui, _center(_rect(controls_item.box)))
        @test !_parked(controls_part) && _parked(sliders_part)
        @test minimum(GUI._overlay_rect(controls_part))[1] > maximum(GUI._overlay_rect(o.rail))[1]
        @test _overlaps(_rect(power[]), GUI._overlay_rect(controls_part))
        _click!(gui, _center(_rect(sliders_item.box)))
        @test _parked(controls_part) && !_parked(sliders_part)
        s = only(gui.sliders.sliders)
        @test _overlaps(_rect(s), GUI._overlay_rect(sliders_part))
        # Esc closes the popover first, then the rail
        _key!(gui, Keyboard.escape)
        @test _parked(sliders_part) && GUI._rail_open(o)
        _key!(gui, Keyboard.escape)
        @test !GUI._rail_open(o)
        close(gui)
    end

    @testset "toast" begin
        old = GUI._TOAST_SECONDS[]
        GUI._TOAST_SECONDS[] = 0.2
        try
            gui, _, _ = _fixture()
            o = gui.layout.overlay
            sleep(0.5)
            @test !o.toast_shown && _parked(o.toast)
            gui.status.text[] = "hello"
            @test o.toast_shown && !_parked(o.toast)
            # at the bottom center of the 3D view, with the info label
            vp = Rect2f(Makie.viewport(gui.ax.scene)[])
            r = GUI._overlay_rect(o.toast)
            @test abs(_center(r)[1] - _center(vp)[1]) < 2
            @test minimum(r)[2] < minimum(vp)[2] + 100
            @test startswith(gui.widgets.info.text[], "traced in ")
            # a newer text restarts the timeout
            sleep(0.12)
            gui.status.text[] = "again"
            sleep(0.12)
            @test o.toast_shown
            sleep(0.4)
            @test !o.toast_shown && _parked(o.toast)
            # the toast takes no clicks and is no obstacle of the cards
            gui.status.text[] = "shown"
            @test !(GUI._overlay_rect(o.toast) in GUI._overlay_rects(o))
            # a closed view leaves no timer behind
            @test o.toast_deadline.timer isa Timer
            close(gui)
            @test isnothing(o.toast_deadline.timer) && isnothing(o.camera_deadline.timer)
            @test !isfinite(o.toast_deadline.at)
        finally
            GUI._TOAST_SECONDS[] = old
        end
    end

    @testset "help pill" begin
        gui, _, _ = _fixture()
        o = gui.layout.overlay
        ctrl = gui.controls
        help = gui.layout.help
        # the pill of the overlay is the pill of the help, at the top left of the 3D view
        @test help.pill === o.pill && help.scene === o.scene
        @test ctrl.help_obs[] == ""
        pill = GUI._overlay_rect(o.pill)
        vp = Rect2f(Makie.viewport(gui.ax.scene)[])
        @test minimum(pill)[1] - minimum(vp)[1] < 20 && maximum(vp)[2] - maximum(pill)[2] < 20
        # a click on the pill and the key h open and close the help card, see TestLiveHelp.jl
        _click!(gui, _center(pill))
        @test ctrl.help_shown && !_parked(help.card)
        _key!(gui, Keyboard.h)
        @test !ctrl.help_shown && _parked(help.card)
        # the help follows the 3D view every frame, like the overlay
        GUI._park!(help.chips.outer)
        _tick!(gui)
        @test !_parked(help.chips)
        # a press on the help card reaches nothing below it: the open tool rail stays open
        _key!(gui, Keyboard.h)
        o.more_button.active[] = true
        _click!(gui, _center(GUI._overlay_rect(help.card)))
        @test GUI._rail_open(o) && ctrl.help_shown
        close(gui)
    end

    @testset "spectator mode: only the 3D view and the help" begin
        gui, m, _ = _fixture()
        panel_axis = Ref{Any}(nothing)
        add_panel!(layout -> (panel_axis[] = Axis(layout[1, 1])), gui, "Panel")
        o, help, ctrl = gui.layout.overlay, gui.layout.help, gui.controls
        cube = gui.widgets.view_cube
        fig = Rect2f(gui.fig.scene.viewport[])
        view() = Rect2f(gui.ax.scene.viewport[])
        same(a, b) = minimum(a) ≈ minimum(b) && Makie.widths(a) ≈ Makie.widths(b)
        parts = (o.more, o.rail, o.toast, o.camera)
        v0 = view()
        @test Makie.widths(v0)[1] < Makie.widths(fig)[1]
        # an open tool rail, the camera popover, the toast and a pinned card
        o.more_button.active[] = true
        o.camera_shown = true
        gui.status.text[] = "hello"
        GUI._toggle_pin!(gui, m)
        _tick!(gui)
        c = only(GUI._floating_cards(gui, m))
        card = Rect2f(c.background.layoutobservables.suggestedbbox[])
        rects = map(GUI._overlay_rect, parts)
        @test c.scene.visible[] && !any(_parked, parts) && cube.scene.visible[]

        _key!(gui, Keyboard.v)
        _tick!(gui)
        @test ctrl.spectator[] && o.hidden
        # the 3D view fills the window: the panels are collapsed, hidden and off-screen
        @test same(view(), fig) && !gui.layout.panel_part.shown
        @test !panel_axis[].blockscene.visible[]
        @test maximum(_rect(panel_axis[]))[1] < 0
        # no tools, no status, no view cube, no cards
        @test all(_parked, parts)
        @test !cube.scene.visible[] && isempty(GUI._obstacles(cube))
        @test !c.scene.visible[] && c.pinned && c.obj === m
        # the help pill and the chip of the mode stay, inside the view
        @test !_parked(o.pill) && !_parked(help.spectator) && _parked(help.chips)
        inside(r) = all(minimum(r) .>= minimum(view())) && all(maximum(r) .<= maximum(view()))
        @test inside(GUI._overlay_rect(o.pill)) && inside(GUI._overlay_rect(help.spectator))
        @test GUI._overlay_rects(o) == [GUI._overlay_rect(o.pill)]
        _key!(gui, Keyboard.h)
        @test help.shown && !_parked(help.card)
        _key!(gui, Keyboard.h)
        # a new status does not bring the toast back
        gui.status.text[] = "again"
        _tick!(gui)
        @test _parked(o.toast)
        # clicks at the places of "⋯" and of the view cube, the hover of the cube and Esc do nothing
        eye = copy(cameracontrols(gui.ax.scene).eyeposition[])
        _click!(gui, _center(rects[1]))
        _click!(gui, _center(Rect2f(cube.scene.viewport[])))
        _key!(gui, Keyboard.escape)
        _tick!(gui)
        @test o.more_button.active[] && isnothing(cube.anim) && isnothing(cube.hovered)
        @test cameracontrols(gui.ax.scene).eyeposition[] == eye
        @test _parked(o.camera) && ctrl.spectator[]

        # back as it was: the view, the open rail, the panels, the cube, the pinned card
        _key!(gui, Keyboard.v)
        _tick!(gui)
        @test !ctrl.spectator[] && !o.hidden
        @test same(view(), v0) && gui.layout.panel_part.shown
        @test panel_axis[].blockscene.visible[] && minimum(_rect(panel_axis[]))[1] > 0
        @test o.more_button.active[] && same(GUI._overlay_rect(o.more), rects[1])
        @test same(GUI._overlay_rect(o.rail), rects[2])
        @test cube.scene.visible[] && !isempty(GUI._obstacles(cube))
        @test c.scene.visible[] && c.pinned
        @test same(Rect2f(c.background.layoutobservables.suggestedbbox[]), card)
        @test _parked(help.spectator) && !_parked(help.chips)
        close(gui)

        # the markers of the sources are hidden in the mode and follow their toggle afterwards
        gui, m, _ = _fixture()
        ctrl, toggle = gui.controls, gui.widgets.sources_toggle
        marker = only(oh for oh in BMO.render_children(ctrl.h) if GUI._is_source(BMO.rendered(oh)))
        shown() = all(p -> p.visible[], BMO.render_plots(marker))
        hidden() = !any(p -> p.visible[], BMO.render_plots(marker))
        mirror = BMO.render_plots(only(oh for oh in BMO.render_children(ctrl.h) if BMO.rendered(oh) === m))
        @test toggle.active[] && shown() && GUI._sources_shown(gui)
        _key!(gui, Keyboard.v)
        @test hidden() && toggle.active[] && !GUI._sources_shown(gui)
        # the components and the beams stay
        @test all(p -> p.visible[], mirror)
        _key!(gui, Keyboard.v)
        @test shown()
        # switched off before: off afterwards; the toggle does not show them in the mode
        toggle.active[] = false
        @test hidden()
        _key!(gui, Keyboard.v)
        toggle.active[] = true
        @test hidden() && toggle.active[]
        toggle.active[] = false
        _key!(gui, Keyboard.v)
        @test hidden()
        toggle.active[] = true
        @test shown()
        # a source hidden by "hide" stays hidden, and one shown again in the mode has no marker
        src = BMO.rendered(marker)
        GUI._set_hidden!(gui, src, true)
        _key!(gui, Keyboard.v)
        GUI._set_hidden!(gui, src, false)
        @test hidden()
        _key!(gui, Keyboard.v)
        @test shown()
        close(gui)

        # a view started in the spectator mode starts without the UI; the chip leaves the mode
        gui, _, _ = _fixture(; spectator = true)
        o = gui.layout.overlay
        _tick!(gui)
        @test o.hidden && _parked(o.more) && !gui.widgets.view_cube.scene.visible[]
        @test !GUI._sources_shown(gui) && !any(p -> p.visible[], BMO.render_plots(
            only(oh for oh in BMO.render_children(gui.controls.h) if GUI._is_source(BMO.rendered(oh)))))
        @test same(Rect2f(gui.ax.scene.viewport[]), Rect2f(gui.fig.scene.viewport[]))
        notify(gui.layout.help.spectator_button.clicks)
        _tick!(gui)
        @test !gui.controls.spectator[] && !o.hidden && !_parked(o.more)
        @test gui.widgets.view_cube.scene.visible[] && isnothing(gui.layout.panel_part)
        close(gui)

        # a panel added in the spectator mode to a view without panels stays hidden until it is left
        gui, _, _ = _fixture(; detectors = [])
        GUI._set_spectator!(gui.controls, true)
        axis = Ref{Any}(nothing)
        add_panel!(gui, "Own") do layout
            axis[] = Axis(layout[1, 1])
            return _ -> nothing
        end
        @test !gui.layout.panel_part.shown && !axis[].blockscene.visible[]
        @test same(Rect2f(gui.ax.scene.viewport[]), Rect2f(gui.fig.scene.viewport[]))
        GUI._set_spectator!(gui.controls, false)
        @test gui.layout.panel_part.shown && axis[].blockscene.visible[]
        @test Makie.widths(gui.ax.scene.viewport[])[1] < Makie.widths(gui.fig.scene.viewport[])[1]
        # controls and tools added in the spectator mode appear in the rail afterwards
        GUI._set_spectator!(gui.controls, true)
        o = gui.layout.overlay
        n = length(o.sections)
        add_controls!(layout -> Button(layout[1, 1]; label = "x"), gui, "Mine")
        tool = add_tool!(g -> nothing, gui, "Own tool")
        _tick!(gui)
        @test length(o.sections) == n + 1 && o.hidden && _parked(o.rail) && _parked(o.more)
        GUI._set_spectator!(gui.controls, false)
        o.more_button.active[] = true
        _tick!(gui)
        @test !_parked(o.rail) && all(minimum(_rect(tool.box)) .>= minimum(GUI._overlay_rect(o.rail)))
        close(gui)
    end

    @testset "cards keep off the overlay" begin
        gui, m, _ = _fixture(; size = (700, 450), detectors = [])
        o = gui.layout.overlay
        o.more_button.active[] = true
        o.camera_shown = true
        GUI._arrange_overlay!(o)
        gui.controls.selected[] = m
        _tick!(gui)
        c = gui.cards.selection
        @test c.scene.visible[]
        card = Rect2f(c.background.layoutobservables.suggestedbbox[])
        obstacles = GUI._obstacles(gui)
        @test GUI._overlay_rect(o.rail) in obstacles && GUI._overlay_rect(o.camera) in obstacles
        @test !_overlaps(card, GUI._overlay_rect(o.rail))
        @test !_overlaps(card, GUI._overlay_rect(o.camera))
        close(gui)
    end
end

end
