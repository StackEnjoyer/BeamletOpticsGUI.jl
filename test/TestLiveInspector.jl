module TestLiveInspector

using GLMakie, BeamletOptics, BeamletOpticsGUI
using Makie
using Test

const BMO = BeamletOptics
const GUI = BeamletOpticsGUI

@testset "Live view inspector" begin

    # A lens group, a mirror that reflects the beam onto a detector and a beamsplitter off the path
    function _fixture(; kwargs...)
        l1 = SphericalLens(0.1, -0.1, 4e-3, 25.4e-3)
        l2 = SphericalLens(-0.1, 0.1, 2e-3, 25.4e-3)
        translate3d!(l2, [0, 0.015, 0])
        group = ObjectGroup([l1, l2])
        translate3d!(group, [0, 0.04, 0])
        m = RoundPlanoMirror(25e-3, 5e-3)
        zrotate3d!(m, deg2rad(45))
        translate3d!(m, [0, 0.1, 0])
        pd = Detector(5e-3)
        zrotate3d!(pd, -π / 2)
        translate3d!(pd, [0.1, 0.1, 0])
        bs = RoundThinBeamsplitter(10e-3; reflectance = 0.3)
        translate3d!(bs, [0, 0, 0.1])
        pd2 = Detector(5e-3)
        translate3d!(pd2, [0, 0.3, 0.2])
        beam = Beam([0.0, 0, 0], [0.0, 1, 0], 633e-9)
        gui = live_view(System([group, m, pd, bs, pd2]), beam; trace_budget = Inf, layout = :app,
            throttle = false, labels = Dict(pd => "PD1"),
            clip_planes = [[0, 0.1, 0] => [0, 0, 1]], kwargs...)
        return gui, (; l1, l2, group, m, pd, bs, pd2, beam)
    end

    _rows(gui) = gui.layout.inspector.list.rows
    _value(gui, label) = (i = findfirst(r -> r[1] == label, _rows(gui));
        isnothing(i) ? nothing : _rows(gui)[i][2])
    # Declared widgets of the docked card by name, see `card_rows`
    _w(gui, name) = GUI._card_widget(gui.layout.inspector.card, name)
    _rect(x) = x.layoutobservables.computedbbox[]
    _center(r) = Point2f(minimum(r) .+ Makie.widths(r) ./ 2)
    _height(x) = Makie.widths(_rect(x))[2]
    _visible(b) = b.blockscene.visible[]
    _tick!(gui) = (events(gui.ax.scene).tick[] = Makie.Tick(Makie.RegularRenderTick, 0, 0.0, 1.0))
    # A left click at the figure pixel `xy`: mouse events like those of a window
    function _click!(gui, xy)
        ev = events(gui.fig.scene)
        ev.mouseposition[] = (Float64(xy[1]), Float64(xy[2]))
        for action in (Mouse.press, Mouse.release)
            ev.mousebutton[] = Makie.MouseButtonEvent(Mouse.left, action)
        end
        return nothing
    end
    # A click on the `page` of the page bar of the docked card `c`
    _page!(c, page) = notify(c.bar.buttons[findfirst(==(page), c.bar.keys)].clicks)
    # The parts of the docked card `c` that are shown, see `_DockedCard`
    _parts(c) = [name for name in (:bar_part, :rows_part, :step_part, :view_part, :properties_part)
                 if !isnothing(getfield(c, name)) && getfield(c, name).shown]
    # Selects `obj` and opens the page "Properties" of the inspector
    function _properties!(gui, obj)
        gui.controls.selected[] = obj
        _page!(gui.layout.inspector.card, :properties)
        return nothing
    end

    @testset "formatting" begin
        @test GUI._property_row("Diameter [m]", 25.4e-3) == ("Diameter", "25.4 mm")
        @test GUI._property_row("Wavelength [m]", 633e-9) == ("Wavelength", "633 nm")
        @test GUI._property_row("Offset [m]", -2e-6) == ("Offset", "-2 µm")
        @test GUI._property_row("Length [m]", 1.5) == ("Length", "1.5 m")
        @test GUI._property_row("Angle [rad]", deg2rad(5)) == ("Angle", "87.3 mrad")
        @test GUI._property_row("Power [W]", 1e-3) == ("Power", "0.001 W")
        @test GUI._property_row("Size [m]", [10e-3, 2e-3]) == ("Size", "(10, 2) mm")
        @test GUI._property_row("Optical axis", [0.0, -1.0, 1e-17]) == ("Optical axis", "(0, -1, 0)")
        @test GUI._property_row("n(λ₀)", 1.51680) == ("n(λ₀)", "1.517")
        @test GUI._property_row("Hits", 12) == ("Hits", "12")
        @test GUI._property_row("Stops beams", true) == ("Stops beams", "yes")
        @test GUI._property_row("Shape", "Mesh") == ("Shape", "Mesh")
    end

    @testset "selection" begin
        gui, o = _fixture()
        insp = gui.layout.inspector
        card = insp.card
        ctrl = gui.controls
        # nothing selected: the step and a summary, no page bar
        @test insp.name.text[] == "No selection"
        @test _parts(card) == [:step_part, :properties_part]
        @test _value(gui, "Systems") == "1"
        @test _value(gui, "Objects") == "6"
        @test _value(gui, "Sources") == "1"
        @test _value(gui, "Clip planes") == "1"
        @test endswith(_value(gui, "Last trace"), "ms")
        @test _visible(insp.step_box) && _visible(insp.list.box)
        # without a selection, the docked card is empty and has no height
        @test isempty(card.widgets) && isempty(card.rows.content)
        @test !insp.pin.box.visible[]
        # a lens: header and the page "Pose" with the rows of its card (the pose), the step and
        # the mode
        ctrl.selected[] = o.l1
        @test insp.name.text[] == "Lens 1"
        @test insp.type.text[] == "Lens"
        @test insp.icon[] === GUI._icon(:lens)
        @test card.pages == (:pose, :properties) && card.page == :pose
        @test card.bar.keys == [:pose, :properties] && card.bar.selected[] == :pose
        @test [b.label[] for b in card.bar.buttons] == ["Pose", "Properties"]
        @test _parts(card) == [:bar_part, :rows_part, :step_part]
        @test _w(gui, :y).displayed_string[] == "40.0"
        @test _w(gui, :hide) isa BeamletOpticsGUI._IconToggle && !_w(gui, :hide).active[]
        @test all(k -> _w(gui, k) isa Textbox, (:x, :y, :z, :rx, :ry, :rv))
        @test insp.pin.box.visible[] && !insp.pin.active[]
        # the properties are on their own page: the list is empty and has no height
        @test isempty(_rows(gui)) && _height(insp.list.box) == 0 && !_visible(insp.list.box)
        # the actions in the header, the page bar below it, then the rows, then step and mode
        @test minimum(_rect(card.actions))[1] > maximum(_rect(insp.name))[1] - 1
        @test maximum(_rect(card.bar.grid))[2] < minimum(_rect(insp.type))[2]
        @test maximum(_rect(card.rows))[2] < minimum(_rect(card.bar.grid))[2]
        @test maximum(_rect(insp.step_box))[2] < minimum(_rect(card.rows))[2]
        # the boxes fill the width of the sidebar, inside of it
        sidebar = _rect(gui.layout.right.box)
        @test maximum(_rect(_w(gui, :z)))[1] <= maximum(sidebar)[1]
        @test minimum(_rect(_w(gui, :x)))[1] >= minimum(sidebar)[1]
        # the page "Properties": the list instead of the rows and the step, which are hidden and
        # laid out off-screen, where they take no clicks
        _page!(card, :properties)
        @test card.page == :properties && card.bar.selected[] == :properties
        @test _parts(card) == [:bar_part, :properties_part]
        @test _value(gui, "Thickness") == "4 mm"
        @test _value(gui, "n(λ₀)") == "1.5"
        @test isnothing(_value(gui, "Position"))   # in the pose rows
        @test isnothing(_value(gui, "Type"))       # in the header
        @test _visible(insp.list.box) && _height(insp.list.box) == length(_rows(gui)) * GUI._PROPERTY_ROW
        @test maximum(_rect(insp.list.box))[2] < minimum(_rect(card.bar.grid))[2]
        @test Makie.widths(_rect(insp.list.box))[1] ≈ Makie.widths(_rect(insp.grid))[1]
        @test _w(gui, :y) isa Textbox && !_visible(_w(gui, :y)) && maximum(_rect(_w(gui, :y)))[1] < 0
        @test !_visible(insp.step_box) && maximum(_rect(insp.step_box))[1] < 0
        # the page stays while the same object is shown, e.g. after a solve
        GUI._resolve!(gui, nothing)
        @test card.page == :properties && _value(gui, "Thickness") == "4 mm"
        # and back
        _page!(card, :pose)
        @test _parts(card) == [:bar_part, :rows_part, :step_part] && isempty(_rows(gui))
        @test _visible(_w(gui, :y)) && _visible(insp.step_box)
        @test minimum(_rect(_w(gui, :x)))[1] >= minimum(sidebar)[1]
        # another object opens on its default page; a group
        _page!(card, :properties)
        ctrl.selected[] = o.group
        @test card.page == :pose && isempty(_rows(gui))
        @test insp.name.text[] == "ObjectGroup 1"
        @test insp.icon[] === GUI._icon(:group)
        _page!(card, :properties)
        @test _value(gui, "Parts") == "2"
        # the source
        _properties!(gui, o.beam)
        @test insp.icon[] === GUI._icon(:source)
        @test _value(gui, "Wavelength") == "633 nm"
        @test _value(gui, "Direction") == "(0, 1, 0)"
        # a beamsplitter, with its own icon
        _properties!(gui, o.bs)
        @test insp.icon[] === GUI._icon(:beamsplitter)
        @test GUI._tree_kind(o.bs) == :beamsplitter
        @test _value(gui, "Reflectance") == "0.3"
        @test GUI._tree_kind(RoundLinearPolarizer(25e-3, 1e-3, 1e-3, λ -> 1.5)) == :polarizer
        @test GUI._tree_kind(PolarizationFilter(1e-2)) == :polarizer
        # a clip plane
        _properties!(gui, gui.clip.planes[1])
        @test insp.name.text[] == "Clip plane 1"
        @test insp.icon[] === GUI._icon(:clip_plane)
        @test _value(gui, "Normal") == "(0, 0, 1)"
        @test isnothing(_w(gui, :hide)) && _w(gui, :flip) isa Button && _w(gui, :remove) isa Button
        # the detector opens on its results and has a third page
        ctrl.selected[] = o.pd
        @test insp.name.text[] == "PD1"
        @test card.pages == (:pose, :results, :properties) && card.page == :results
        @test [b.label[] for b in card.bar.buttons] == ["Pose", "Results", "Properties"]
        @test _parts(card) == [:bar_part, :view_part]
        _page!(card, :properties)
        @test _value(gui, "Hits") == "1"
        @test _value(gui, "Size") == "(5, 5) mm"
        # the bars of the sets of pages (of components, sources and detectors) are built once
        @test length(card.bars) == 3
        ctrl.selected[] = o.l1
        @test length(card.bars) == 3 && card.bar.keys == [:pose, :properties]
        # an inspected system has no pose: its card is the system widget, on one page, without
        # the step and the mode
        GUI._inspect!(gui, gui.system_handles[1])
        @test insp.name.text[] == "System 1" && card.page == :pose
        @test insp.type.text[] == "System · 5 objects · 1 source"
        @test GUI._card_widget(card, :member_count).label.text[] == "6"
        @test _parts(card) == [:rows_part]
        # deselected: the summary again, the widgets of the card are removed
        ctrl.selected[] = o.pd
        blocks = copy(card.blocks)
        ctrl.selected[] = nothing
        @test insp.name.text[] == "No selection"
        @test isempty(card.blocks) && isempty(card.widgets)
        # the eye in the head is no block, but is drawn by one
        @test all(b -> (b isa Makie.Block ? b : b.box).parent === nothing, blocks)
        @test _parts(card) == [:step_part, :properties_part] && _value(gui, "Systems") == "1"
        @test _visible(insp.step_box) && !any(_visible, card.bar.buttons)
        close(gui)
    end

    @testset "updates in place" begin
        gui, o = _fixture()
        insp, ctrl = gui.layout.inspector, gui.controls
        plots = (insp.list.labels, insp.list.values, insp.list.lines)
        _properties!(gui, o.pd)
        blocks = copy(insp.card.blocks)
        view = insp.card.view
        @test !isempty(blocks)
        # a move updates the values, the widgets and plots stay; the widgets of the page "Pose"
        # take inputs while another page is shown
        _w(gui, :z).stored_string[] = "10"
        @test _value(gui, "Hits") == "0"
        @test _w(gui, :z).displayed_string[] == "10.0"
        @test insp.card.blocks == blocks
        @test (insp.list.labels, insp.list.values, insp.list.lines) === plots
        _w(gui, :z).stored_string[] = "0"
        @test _value(gui, "Hits") == "1"
        # a move in the 3D view, too
        translate3d!(o.pd, [0, 0, 0.002])
        GUI._update_inspector!(gui)
        @test _w(gui, :z).displayed_string[] == "2.0"
        translate3d!(o.pd, [0, 0, -0.002])
        # another detector keeps the widgets, the page bar and the view
        bar = insp.card.bar
        ctrl.selected[] = o.pd2
        @test insp.card.blocks == blocks && insp.card.bar === bar && insp.card.view === view
        # the list has a constant number of plots
        _properties!(gui, o.l1)
        @test (insp.list.labels, insp.list.values, insp.list.lines) === plots
        @test length(insp.list.box.blockscene.plots) == 4   # with the (invisible) box
        # collapsed, the inspector is not updated; it is refreshed when shown again
        gui.layout.collapse.right.active[] = false
        ctrl.selected[] = o.m
        @test insp.shown === o.l1
        gui.layout.collapse.right.active[] = true
        @test insp.shown === o.m
        @test insp.name.text[] == "Mirror 1"
        close(gui)
    end

    @testset "long lists" begin
        gui, o = _fixture()
        list = gui.layout.inspector.list
        rows = [("row $i", string(i)) for i in 1:30]
        GUI._set_rows!(list, rows)
        @test length(list.rows) == GUI._PROPERTY_MAX_ROWS
        @test list.rows[end][1] == "… $(30 - GUI._PROPERTY_MAX_ROWS + 1) more"
        # long values are ellipsized
        GUI._set_rows!(list, [("Shape", "x"^200)])
        @test endswith(list.values.text[][1], "…")
        close(gui)
    end

    @testset "mode" begin
        gui, _ = _fixture()
        ctrl = gui.controls
        sel = gui.layout.inspector.mode.selected
        @test ctrl.mode[] == :move && sel[] == :move
        # the control drives the controls
        gui.layout.inspector.mode.buttons[2].clicks[] += 1
        @test sel[] == :rotate
        @test ctrl.mode[] == :rotate
        # and follows the key `m` and the step box
        events(gui.ax.scene).keyboardbutton[] = Makie.KeyEvent(Keyboard.m, Keyboard.press)
        @test ctrl.mode[] == :move && sel[] == :move
        gui.widgets.step_box.stored_string[] = "1 mrad"
        @test sel[] == :rotate
        close(gui)
    end

    @testset "part of the selection shared with the floating card" begin
        gui, o = _fixture()
        insp = gui.layout.inspector
        # the step box of the inspector is the keyboard step
        @test gui.widgets.step_box === insp.step_box
        _properties!(gui, o.m)
        GUI._refresh_inspector!(gui)
        rows = _rows(gui)
        @test rows == GUI._inspector_rows(gui, o.m) && !isempty(rows)
        # the pages and the rows of `card_rows`, with the row "remove" of a component, are those of
        # the floating cards
        @test insp.card.pages == GUI._card_pages(o.m)
        key(c) = map(GUI._layout_key, GUI._declarations(gui, c, o.pd))
        @test length(GUI._declarations(gui, insp.card, o.pd)[2]) == length(card_rows(o.pd)) + 1
        @test key(insp.card) == key(gui.cards.selection)
        close(gui)
    end

    @testset "page Results of a detector" begin
        gui, o = _fixture()
        insp, ctrl = gui.layout.inspector, gui.controls
        card = insp.card
        state = GUI._detector_state(gui, o.pd)
        # no view is shown, none is built or computed
        @test isnothing(card.view) && isempty(GUI._layout_views(gui)) && isempty(GUI._shown_views(gui))
        @test state.stale && isnothing(state.result)
        # a click on the detector shows its results in the expanded view, computed from the hits of
        # the last solve
        ctrl.selected[] = o.pd
        view = card.view
        @test card.page == GUI._default_page(o.pd) == :results
        @test view isa GUI._DetectorView && view.expanded && card.view_expanded
        @test GUI._layout_views(gui) == [(o.pd, view)] && GUI._shown_views(gui) == [(o.pd, view)]
        @test !state.stale && GUI._kind_name(state.result.kind) == :spot
        @test view.result === state.result && view.name == "PD1" && view.kind == GUI._SpotKind()
        @test _visible(view.ax) && view.switch.keys == [:spot, :psf]
        # as wide as the sidebar, its axis as high as wide; below the page bar
        w = Makie.widths(_rect(insp.grid))[1]
        @test view.ax.width[] == w && view.ax.height[] == w
        @test GUI._view_size(view)[1] ≈ w
        @test minimum(_rect(view.ax))[1] >= minimum(_rect(gui.layout.right.box))[1]
        @test maximum(_rect(view.ax))[1] <= maximum(_rect(gui.layout.right.box))[1]
        @test maximum(_rect(view.full))[2] < minimum(_rect(card.bar.grid))[2]
        # a solve computes the shown view
        r = state.result
        GUI._resolve!(gui, nothing)
        @test state.result !== r && !state.stale && view.result === state.result
        # the widgets of the view set its options
        view.log_toggle.active[] = true
        @test state.opts.colorscale == :log
        view.switch.selected[] = :psf
        @test state.opts.kind == :psf && GUI._kind_name(state.result.kind) == :psf
        @test view.kind == GUI._PSFKind()
        view.switch.selected[] = :spot
        @test view.kind == GUI._SpotKind()
        # the wheel over the view zooms its axis, not the camera of the 3D view
        cam = cameracontrols(gui.ax.scene)
        eye, limits = cam.eyeposition[], view.ax.finallimits[]
        ev = events(gui.fig.scene)
        ev.mouseposition[] = Tuple(_center(Rect2f(view.ax.scene.viewport[])))
        ev.scroll[] = (0.0, 1.0)
        @test view.ax.finallimits[] != limits && cam.eyeposition[] == eye
        # collapsed to the thumbnail by its chevron and expanded again; the card remembers it
        h = GUI._view_size(view)[2]
        notify(view.collapse_button.clicks)
        @test !view.expanded && !card.view_expanded && GUI._view_size(view)[2] < h
        @test GUI._layout_views(gui) == [(o.pd, view)]
        ctrl.selected[] = o.l1
        ctrl.selected[] = o.pd
        @test card.view === view && !view.expanded
        notify(view.expand_button.clicks)
        @test view.expanded && card.view_expanded && GUI._view_size(view)[2] ≈ h
        # a view that is not shown is not computed: another page
        _page!(card, :pose)
        @test isempty(GUI._layout_views(gui)) && !_visible(view.ax) && maximum(_rect(view.ax))[1] < 0
        @test _visible(_w(gui, :x)) && _visible(insp.step_box)
        GUI._resolve!(gui, nothing)
        @test state.stale
        # shown again, it is computed from the hits of the last solve
        _page!(card, :results)
        @test GUI._layout_views(gui) == [(o.pd, view)] && !state.stale && view.result === state.result
        @test _visible(view.ax) && !_visible(_w(gui, :x)) && !_visible(insp.step_box)
        # another detector takes the view: without hits here
        ctrl.selected[] = o.pd2
        @test card.view === view && card.page == :results
        @test GUI._layout_views(gui) == [(o.pd2, view)]
        @test view.name == GUI._label(gui, o.pd2) != "PD1" && isnothing(view.kind) && isnothing(view.switch)
        @test isempty(GUI._detector_state(gui, o.pd2).result.kinds)
        # an object without a view hides it, no selection too
        ctrl.selected[] = o.m
        @test isempty(GUI._layout_views(gui)) && !_visible(view.ax)
        ctrl.selected[] = o.pd
        @test GUI._layout_views(gui) == [(o.pd, view)] && view.name == "PD1" && view.result === state.result
        ctrl.selected[] = nothing
        @test isempty(GUI._layout_views(gui)) && !_visible(view.ax)
        # not while the sidebar is collapsed: shown again, the view is computed
        ctrl.selected[] = o.pd
        gui.layout.collapse.right.active[] = false
        @test isempty(GUI._layout_views(gui))
        GUI._resolve!(gui, nothing)
        @test state.stale
        gui.layout.collapse.right.active[] = true
        @test GUI._layout_views(gui) == [(o.pd, view)] && !state.stale && view.result === state.result
        close(gui)
    end

    @testset "docked card" begin
        gui, o = _fixture()
        insp, ctrl = gui.layout.inspector, gui.controls
        # no floating card for the selection, its card is docked in the inspector
        ctrl.selected[] = o.m
        events(gui.ax.scene).tick[] = Makie.Tick(Makie.RegularRenderTick, 0, 0.0, 1.0)
        @test !GUI._selection_card_shown(gui)
        @test !any(c -> c.scene.visible[], gui.cards.all)
        @test insp.name.text[] == "Mirror 1"
        # the actions of the card: hide shows the hint of the tree and clears the selection
        (eye = _w(gui, :hide); eye.active[] = !eye.active[])
        @test o.m in gui.objects.hidden && isnothing(ctrl.selected[])
        @test occursin("eye", gui.status.text[])
        GUI._toggle_hidden!(gui, o.m)
        @test !(o.m in gui.objects.hidden)
        # a clip plane: flip and remove
        plane = gui.clip.planes[1]
        ctrl.selected[] = plane
        n = plane.dir[:, 2]
        notify(_w(gui, :flip).clicks)
        @test plane.dir[:, 2] ≈ -n
        notify(_w(gui, :remove).clicks)
        @test isempty(gui.clip.planes) && isnothing(ctrl.selected[])
        @test isempty(insp.card.widgets)
        close(gui)
    end

    @testset "ray slider of sources" begin
        m = RoundPlanoMirror(25e-3, 5e-3)
        zrotate3d!(m, deg2rad(45))
        translate3d!(m, [0, 0.1, 0])
        pd = Detector(5e-3)
        zrotate3d!(pd, -π / 2)
        translate3d!(pd, [0.1, 0.1, 0])
        src = CollimatedSource([0.0, 0, 0], [0.0, 1, 0], 2e-3, 1e-6; num_rings = 2, num_rays = 40)
        gui = live_view(System([m, pd]), src; trace_budget = Inf, layout = :app, preview = false)
        gui.controls.selected[] = src
        rays = _w(gui, :rays)
        @test rays isa Slider && rays.value[] == 40
        @test _w(gui, :ray_count).text[] == "40 rays"
        # the slider fills the sidebar
        @test maximum(_rect(rays))[1] <= maximum(_rect(gui.layout.right.box))[1]
        Makie.set_close_to!(rays, 200)
        @test length(src) == 200 && _w(gui, :ray_count).text[] == "200 rays"
        @test length(BMO.hits(pd)) == 200
        close(gui)
    end

    @testset "pin" begin
        gui, o = _fixture()
        insp, ctrl = gui.layout.inspector, gui.controls
        n = length(gui.cards.all)
        ctrl.selected[] = o.m
        # the pin in the header docks a card of the selected object below the inspector, no
        # floating card
        insp.pin.active[] = true
        c = only(insp.pinned)
        @test c.pinned && c.obj === o.m && GUI._is_pinned(gui, o.m) && length(gui.cards.all) == n
        _tick!(gui)
        @test !any(c -> c.scene.visible[], gui.cards.all)
        @test GUI._card_widget(c, :hide) isa BeamletOpticsGUI._IconToggle && GUI._card_widget(c, :x) isa Textbox
        @test c.head.title.text[] == "Mirror 1" && c.head.icon[] === GUI._icon(:mirror)
        @test c.head.pin.active[]
        # with the pages of its object, like the inspector, but without the step
        @test c.pages == (:pose, :properties) && c.page == :pose && isnothing(c.step_part)
        @test _parts(c) == [:bar_part, :rows_part]
        # it stays when the selection changes, the pin of the inspector follows the selection
        ctrl.selected[] = o.pd
        @test !insp.pin.active[] && only(insp.pinned) === c
        # a second pinned card below the first, on the page that the inspector shows
        insp.pin.active[] = true
        c2 = insp.pinned[2]
        @test c2.obj === o.pd && c2.page == :results && c2.view isa GUI._DetectorView
        @test GUI._card_widget(c2, :signal) isa Label
        @test maximum(_rect(c2.parent))[2] <= minimum(_rect(c.parent))[2]
        # the sidebar scrolls: no card collapses to make room
        @test !c.collapsed
        # the widgets of a pinned card act on its object, not on the selection
        ctrl.selected[] = o.l1
        GUI._card_widget(c, :z).stored_string[] = "5"
        @test BMO.position(o.m)[3] ≈ 5e-3
        @test GUI._card_widget(c, :z).displayed_string[] == "5.0"
        # and take the keyboard
        GUI._card_widget(c, :y).focused[] = true
        @test GUI._typing(gui)
        GUI._card_widget(c, :y).focused[] = false
        # collapsed to the head and the actions, expanded again
        notify(c.head.collapse.clicks)
        @test c.collapsed && isempty(c.rows.content) && GUI._card_widget(c, :hide) isa BeamletOpticsGUI._IconToggle
        @test c.head.collapse.icon[] === GUI._icon(:expand) && isempty(_parts(c))
        notify(c.head.collapse.clicks)
        @test !c.collapsed && GUI._card_widget(c, :x) isa Textbox && _parts(c) == [:bar_part, :rows_part]
        # the pin of a pinned card unpins it, the next card moves up
        c.head.pin.active[] = false
        @test only(insp.pinned) === c2 && !GUI._is_pinned(gui, o.m)
        @test isempty(c.widgets) && c.head.title.parent === nothing
        # pin and unpin from the inspector
        ctrl.selected[] = o.m
        insp.pin.active[] = true
        @test GUI._is_pinned(gui, o.m) && length(insp.pinned) == 2
        insp.pin.active[] = false
        @test !GUI._is_pinned(gui, o.m) && only(insp.pinned) === c2
        # the keyboard step stays in the inspector
        @test gui.widgets.step_box !== gui.cards.selection.step_box
        close(gui)
    end

    @testset "the sidebar scrolls with the pinned cards" begin
        gui, o = _fixture()
        insp, ctrl = gui.layout.inspector, gui.controls
        area = gui.layout.right.area
        ctrl.selected[] = o.m
        @test GUI._max_offset(area) == 0 && area.offset[] == 0
        # more pinned cards than fit: all stay expanded, the sidebar scrolls
        for obj in (o.m, o.pd, o.bs, o.pd2, o.l1)
            GUI._toggle_pin!(gui, obj)
            @test !any(c -> c.collapsed, insp.pinned)
        end
        top, bottom = maximum(area.region[])[2], minimum(area.region[])[2]
        @test GUI._max_offset(area) > 0 && area.height[] > top - bottom
        # the card of the selection at the top of the sidebar, the last card below the window
        @test bottom < minimum(_rect(insp.name))[2] && maximum(_rect(insp.name))[2] < top
        @test minimum(_rect(last(insp.pinned).parent))[2] < bottom
        # scrolled to the end: the last card is in the sidebar, the selection above it
        GUI._set_offset!(area, area.height[])
        @test area.offset[] == GUI._max_offset(area)
        @test minimum(_rect(last(insp.pinned).parent))[2] >= bottom
        @test minimum(_rect(insp.name))[2] > top
        # a click at the place of the pin of the inspector, which the toolbar covers now, is none
        # on the pin
        @test insp.pin.active[]
        _click!(gui, _center(_rect(insp.pin.box)))
        @test insp.pin.active[] && GUI._is_pinned(gui, o.m)
        # a collapsed card needs less height; a refresh keeps the cards as they are
        h = area.height[]
        notify(first(insp.pinned).head.collapse.clicks)
        @test first(insp.pinned).collapsed && area.height[] < h
        GUI._update_inspector!(gui; force = true)
        @test [c.collapsed for c in insp.pinned] == [true, false, false, false, false]
        # unpinned: the offset stays within its limits
        foreach(obj -> GUI._toggle_pin!(gui, obj), (o.m, o.pd, o.bs, o.pd2, o.l1))
        @test isempty(insp.pinned) && GUI._max_offset(area) == 0 && area.offset[] == 0
        close(gui)
    end

    @testset "pages of docked pinned cards" begin
        gui, o = _fixture()
        insp, ctrl = gui.layout.inspector, gui.controls
        ctrl.selected[] = o.m
        GUI._toggle_pin!(gui, o.m)
        c = only(insp.pinned)
        # a list of its own, on its page "Properties": empty and without a height on the page "Pose"
        @test c.list !== insp.list && c.page == :pose
        @test isempty(c.list.rows) && _height(c.list.box) == 0 && !_visible(c.list.box)
        # the page bar below the head, above the rows, inside the sidebar
        @test maximum(_rect(c.bar.grid))[2] <= minimum(_rect(c.head.title))[2]
        @test maximum(_rect(c.rows))[2] <= minimum(_rect(c.bar.grid))[2]
        @test minimum(_rect(c.bar.grid))[1] >= minimum(_rect(gui.layout.right.box))[1]
        # the page "Properties": the properties of its object below the page bar
        _page!(c, :properties)
        @test c.page == :properties && _parts(c) == [:bar_part, :properties_part]
        @test c.list.rows == GUI._inspector_rows(gui, o.m) && !isempty(c.list.rows)
        @test _height(c.list.box) == length(c.list.rows) * GUI._PROPERTY_ROW
        @test maximum(_rect(c.list.box))[2] <= minimum(_rect(c.bar.grid))[2]
        @test !_visible(GUI._card_widget(c, :x))
        # the page of the inspector is its own
        @test insp.card.page == :pose && isempty(_rows(gui))
        # they stay those of its object when another one is selected
        _properties!(gui, o.pd)
        @test c.list.rows == GUI._inspector_rows(gui, o.m)
        # the list of the selection is shortened first, to make room for them
        @test first(_rows(gui)) == first(GUI._inspector_rows(gui, o.pd))
        # a click on the page bar switches the page and does not select the object of the card
        _click!(gui, _center(_rect(c.bar.buttons[1])))
        @test c.page == :pose && isempty(c.list.rows) && _height(c.list.box) == 0
        @test _visible(GUI._card_widget(c, :x))
        @test ctrl.selected[] === o.pd
        @test !GUI._over_free(c, _center(_rect(c.bar.buttons[2])))
        _page!(c, :properties)
        # a collapsed card shows neither the page bar nor the list, and remembers its page
        notify(c.head.collapse.clicks)
        @test c.collapsed && isempty(_parts(c)) && isempty(c.list.rows)
        @test !any(_visible, c.bar.buttons) && maximum(_rect(c.bar.buttons[1]))[1] < 0
        notify(c.head.collapse.clicks)
        @test !c.collapsed && c.page == :properties && _parts(c) == [:bar_part, :properties_part]
        @test c.list.rows == GUI._inspector_rows(gui, o.m)
        @test all(_visible, c.bar.buttons)

        # floated and docked again: on the same page
        buttons = copy(c.bar.buttons)
        notify(c.head.float.clicks)
        _tick!(gui)
        f = only(GUI._floating_cards(gui, o.m))
        @test f.page == :properties
        @test isempty(insp.pinned) && c.list.box.parent === nothing
        @test all(b -> b.parent === nothing, buttons) && isnothing(c.bar)
        notify(f.dock_button.clicks)
        d = only(insp.pinned)
        @test d.obj === o.m && d.page == :properties && !isempty(d.list.rows)

        # three pinned cards on the page "Properties" fit into the sidebar: the older ones
        # collapse, the lists are shortened
        _page!(d, :properties)
        for obj in (o.pd, o.bs)
            GUI._toggle_pin!(gui, obj)
            _page!(last(insp.pinned), :properties)
        end
        @test length(insp.pinned) == 3 && last(insp.pinned).page == :properties && !last(insp.pinned).collapsed
        @test !any(c -> c.collapsed, insp.pinned)
        GUI._update_inspector!(gui; force = true)
        @test !any(c -> c.collapsed, insp.pinned)
        # the card of an item without properties, e.g. a measurement, has a single page: no page bar
        gui.widgets.measure_toggle.active[] = true
        GUI._add_measure_point!(gui, BMO.position(o.m), o.m)
        GUI._add_measure_point!(gui, BMO.position(o.pd), o.pd)
        GUI._info_card(gui).pin_button.active[] = true
        item = last(insp.pinned)
        @test item.obj isa GUI._Measurement && GUI._card_pages(item.obj) == (:pose,)
        @test !item.bar_part.shown && isnothing(item.bar) && !item.properties_part.shown
        # unpinned: its blocks are removed
        d = first(insp.pinned)
        box, buttons = d.list.box, copy(d.bar.buttons)
        GUI._toggle_pin!(gui, d.obj)
        @test !(d in insp.pinned) && box.parent === nothing && all(b -> b.parent === nothing, buttons)
        close(gui)
    end

    @testset "detector view on docked pinned cards" begin
        gui, o = _fixture()
        insp, ctrl = gui.layout.inspector, gui.controls
        state = GUI._detector_state(gui, o.pd)
        w = Makie.widths(_rect(insp.grid))[1]
        # the card pinned to the selected detector opens on the page of the inspector, with a view
        # of its own; both show the result of the detector, which is computed once
        ctrl.selected[] = o.pd
        r = state.result
        GUI._toggle_pin!(gui, o.pd)
        d = only(insp.pinned)
        view = d.view
        @test d.page == :results && view isa GUI._DetectorView && view !== insp.card.view
        @test view.expanded && d.view_expanded
        @test GUI._layout_views(gui) == [(o.pd, insp.card.view), (o.pd, view)]
        @test state.result === r && view.result === r && insp.card.view.result === r
        @test maximum(_rect(view.full))[2] < minimum(_rect(d.bar.grid))[2]
        # both views are as high as wide: the sidebar scrolls instead of shrinking them
        area = gui.layout.right.area
        @test insp.card.view.ax.height[] == w && insp.card.view.ax.width[] == w
        @test view.ax.height[] == w && GUI._max_offset(area) > 0
        GUI._update_inspector!(gui; force = true)
        @test insp.card.view.ax.height[] == w
        # the thumbnail of the pinned card needs less
        scroll = GUI._max_offset(area)
        notify(view.collapse_button.clicks)
        @test !view.expanded && !d.view_expanded && GUI._layout_views(gui)[2] == (o.pd, view)
        small = GUI._max_offset(area)
        @test small < scroll
        notify(view.expand_button.clicks)
        @test view.expanded && d.view_expanded && GUI._max_offset(area) > small
        # the view of the selection is hidden with its page
        ctrl.selected[] = o.m
        @test GUI._layout_views(gui) == [(o.pd, view)] && view.ax.height[] == w
        # a solve computes the view of the pinned card
        GUI._resolve!(gui, nothing)
        @test state.result !== r && !state.stale && view.result === state.result
        # a click on the view or on the page bar does not select the object of the card
        @test !GUI._over_free(d, _center(Rect2f(view.ax.scene.viewport[])))
        @test GUI._over_free(d, _center(_rect(d.head.title)))
        _click!(gui, _center(Rect2f(view.ax.scene.viewport[])))
        @test ctrl.selected[] === o.m
        # a collapsed card does not show its view, which is not computed then
        notify(d.head.collapse.clicks)
        @test d.collapsed && isempty(GUI._layout_views(gui)) && !_visible(view.ax)
        GUI._resolve!(gui, nothing)
        @test state.stale
        notify(d.head.collapse.clicks)
        @test !d.collapsed && GUI._layout_views(gui) == [(o.pd, view)] && !state.stale
        @test view.result === state.result && _visible(view.ax)
        # nor on another page
        _page!(d, :properties)
        @test isempty(GUI._layout_views(gui)) && d.list.rows == GUI._inspector_rows(gui, o.pd)
        _page!(d, :results)
        @test GUI._layout_views(gui) == [(o.pd, view)]
        # floated: the docked card is removed with its view and the listeners of the view
        listeners = copy(d.view_listeners)
        @test !isempty(listeners) && all(l -> any(k -> k === l, ctrl.listeners), listeners)
        GUI._float!(gui, o.pd)
        @test !(d in insp.pinned) && isnothing(d.view) && view.ax.parent === nothing
        @test !any(l -> any(k -> k === l, ctrl.listeners), listeners)
        @test isempty(GUI._layout_views(gui))
        # docked again: a new card with a view on the page "Results"
        GUI._dock!(gui, o.pd)
        d = last(insp.pinned)
        @test d.obj === o.pd && d.page == :results && d.view isa GUI._DetectorView
        @test GUI._layout_views(gui) == [(o.pd, d.view)] && d.view.result === state.result
        # more cards: none collapses, the sidebar scrolls
        for obj in (o.m, o.bs, o.pd2, o.l1)
            GUI._toggle_pin!(gui, obj)
        end
        @test !any(c -> c.collapsed, insp.pinned) && GUI._max_offset(gui.layout.right.area) > 0
        # unpinned
        view = d.view
        GUI._toggle_pin!(gui, o.pd)
        @test isnothing(d.view) && view.ax.parent === nothing
        @test !any(v -> first(v) === o.pd, GUI._layout_views(gui))
        close(gui)
    end

    @testset "pin and unpin by clicks" begin
        # Regression: the press and release of a click on a widget of the sidebar reached the
        # controls of the 3D view, whose release on the "background" cleared the selection, which
        # emptied the inspector before the pin could act
        gui, o = _fixture()
        insp, ctrl = gui.layout.inspector, gui.controls
        ctrl.selected[] = o.m
        _tick!(gui)
        _click!(gui, _center(_rect(insp.pin.box)))
        # the selection and its docked card stay, the pin is active, a card is pinned below
        @test ctrl.selected[] === o.m
        @test insp.shown === o.m && insp.name.text[] == "Mirror 1"
        @test _w(gui, :x) isa Textbox && !isempty(insp.card.rows.content)
        @test insp.pin.active[] && GUI._is_pinned(gui, o.m)
        @test gui.layout.right.shown
        _tick!(gui)
        c = only(insp.pinned)
        @test c.obj === o.m && !any(c -> c.scene.visible[], gui.cards.all)
        # a click on a widget of the docked card keeps the selection, too
        _click!(gui, _center(_rect(_w(gui, :y))))
        @test ctrl.selected[] === o.m && _w(gui, :y).focused[]
        _w(gui, :y).focused[] = false
        # unpinned via the pin of the inspector: the inspector stays
        _click!(gui, _center(_rect(insp.pin.box)))
        @test !GUI._is_pinned(gui, o.m) && !insp.pin.active[]
        @test ctrl.selected[] === o.m && insp.name.text[] == "Mirror 1" && _w(gui, :x) isa Textbox
        @test isempty(insp.pinned)
        # pinned again, then unpinned via the pin of the pinned card; a click on its widgets keeps
        # the selection
        _click!(gui, _center(_rect(insp.pin.box)))
        c = only(insp.pinned)
        _click!(gui, _center(_rect(GUI._card_widget(c, :y))))
        @test ctrl.selected[] === o.m && GUI._card_widget(c, :y).focused[]
        GUI._card_widget(c, :y).focused[] = false
        _click!(gui, _center(_rect(c.head.pin.box)))
        @test isempty(insp.pinned) && !insp.pin.active[]
        @test ctrl.selected[] === o.m && insp.name.text[] == "Mirror 1" && _w(gui, :x) isa Textbox
        # a click on the background of the 3D view still clears the selection
        vp = gui.ax.scene.viewport[]
        _click!(gui, Point2f(minimum(vp) .+ (5, 5)))
        @test isnothing(ctrl.selected[]) && insp.name.text[] == "No selection"
        close(gui)
    end

    @testset "float and dock pinned cards" begin
        gui, o = _fixture()
        insp, ctrl = gui.layout.inspector, gui.controls
        _floating(obj) = GUI._floating_cards(gui, obj)
        _inside(r, v) = all(minimum(r) .>= minimum(v) .- 1.0f-3) && all(maximum(r) .<= maximum(v) .+ 1.0f-3)
        ctrl.selected[] = o.m
        # pinned: docked by default, with the float button in its head
        GUI._toggle_pin!(gui, o.m)
        d = only(insp.pinned)
        @test GUI._is_pinned(gui, o.m) && !GUI._is_floating(gui, o.m) && isempty(_floating(o.m))
        @test d.head.float.icon[] === GUI._icon(:float) && d.head.float.tooltip[] == "Float in the 3D view"
        # floated: out of the sidebar, a floating card next to the object with the dock button
        notify(d.head.float.clicks)
        _tick!(gui)
        @test isempty(insp.pinned) && GUI._is_pinned(gui, o.m) && GUI._is_floating(gui, o.m)
        @test insp.pin.active[] && isempty(d.widgets) && d.head.title.parent === nothing
        c = only(_floating(o.m))
        @test c !== gui.cards.selection && c.scene.visible[] && c.title.text[] == "Mirror 1"
        @test c.icon[] === GUI._icon(:mirror) && GUI._card_widget(c, :x) isa Textbox
        @test c.dock_button.icon[] === GUI._icon(:dock) && c.dock_button.tooltip[] == "Dock in the sidebar"
        # the card of the selection stays docked in the inspector, whose header has no float button
        @test insp.name.text[] == "Mirror 1" && _w(gui, :x) isa Textbox && !gui.cards.selection.scene.visible[]
        _icons(g) = [p.marker[] for gc in g.content if gc.content isa Box
                     for p in gc.content.blockscene.plots if p isa Scatter]
        @test GUI._icon(:pin) in _icons(insp.card.header) || GUI._icon(:pinned) in _icons(insp.card.header)
        @test !(GUI._icon(:float) in _icons(insp.card.header))        # in the 3D view, linked to its object, the dock button in its head
        bg = _rect(c.background)
        @test _inside(bg, Rect2f(gui.ax.scene.viewport[])) && length(c.link[]) == 2
        @test _inside(_rect(c.dock_button.box), bg) && _inside(_rect(c.pin_button.box), bg)
        # in the colors of the theme, like the floating cards of the compact layout
        @test RGBAf(Makie.to_color(c.background.color[])) == RGBAf(Makie.to_color(gui.layout.theme.sidebar))
        # it stays with its object when the selection changes, its widgets act on its object
        ctrl.selected[] = o.pd
        _tick!(gui)
        @test c.scene.visible[] && c.obj === o.m && !insp.pin.active[]
        GUI._card_widget(c, :z).stored_string[] = "3"
        @test BMO.position(o.m)[3] ≈ 3e-3
        @test BMO.position(o.pd)[3] ≈ 0 atol = 1e-12
        # typing into its textbox blocks the keys of the 3D view
        box = GUI._card_widget(c, :y)
        box.focused[] = true
        @test GUI._typing(gui)
        P0 = Vector{Float64}(BMO.position(o.pd))
        events(gui.ax.scene).keyboardbutton[] = Makie.KeyEvent(Keyboard.left, Keyboard.press)
        @test Vector{Float64}(BMO.position(o.pd)) == P0
        box.focused[] = false
        @test !GUI._typing(gui)
        # hidden and shown again: the card stays floating, like in the compact layout
        (eye = GUI._card_widget(c, :hide); eye.active[] = !eye.active[])
        _tick!(gui)
        @test o.m in gui.objects.hidden && GUI._is_floating(gui, o.m) && c.scene.visible[]
        (eye = GUI._card_widget(c, :hide); eye.active[] = !eye.active[])
        @test !(o.m in gui.objects.hidden) && only(_floating(o.m)) === c
        # docked again: at the end of the pinned cards, in its collapsed state
        GUI._toggle_pin!(gui, o.pd)
        notify(c.collapse_button.clicks)
        @test c.collapsed
        notify(c.dock_button.clicks)
        _tick!(gui)
        @test !GUI._is_floating(gui, o.m) && !c.pinned && !c.scene.visible[]
        @test [d.obj for d in insp.pinned] == [o.pd, o.m] && insp.pinned[2].collapsed
        @test insp.pinned[2].head.collapse.icon[] === GUI._icon(:expand)
        # floated again, still collapsed; unpinned by the pin of the floating card
        notify(insp.pinned[2].head.float.clicks)
        _tick!(gui)
        c = only(_floating(o.m))
        @test c.collapsed && c.scene.visible[] && [d.obj for d in insp.pinned] == [o.pd]
        c.pin_button.active[] = false
        _tick!(gui)
        @test !GUI._is_pinned(gui, o.m) && isempty(_floating(o.m)) && !c.scene.visible[]
        # pinned again: docked
        GUI._toggle_pin!(gui, o.m)
        @test GUI._is_pinned(gui, o.m) && !GUI._is_floating(gui, o.m)
        @test [d.obj for d in insp.pinned] == [o.pd, o.m]
        # a floating card is unpinned by the pin of the inspector, too
        GUI._float!(gui, o.m)
        c = only(_floating(o.m))
        ctrl.selected[] = o.m
        @test insp.pin.active[]
        insp.pin.active[] = false
        _tick!(gui)
        @test !GUI._is_pinned(gui, o.m) && !c.pinned && !c.scene.visible[]
        @test [d.obj for d in insp.pinned] == [o.pd]
        # nothing to float or dock without a pinned card
        GUI._float!(gui, o.m)
        GUI._dock!(gui, o.pd)
        @test !GUI._is_pinned(gui, o.m) && [d.obj for d in insp.pinned] == [o.pd]
        close(gui)
    end

    @testset "floating cards do not count for the sidebar" begin
        gui, o = _fixture()
        insp, ctrl = gui.layout.inspector, gui.controls
        ctrl.selected[] = o.m
        # an expanded floating card, then more docked cards than fit into the sidebar
        GUI._toggle_pin!(gui, o.m)
        GUI._float!(gui, o.m)
        c = only(GUI._floating_cards(gui, o.m))
        for obj in (o.pd, o.bs, o.pd2, o.l1)
            GUI._toggle_pin!(gui, obj)
            @test !any(d -> d.collapsed, insp.pinned)
        end
        # the floating card is not in the stack of the sidebar
        @test all(d -> d.obj !== o.m, insp.pinned) && length(insp.pinned) == 4
        @test !c.collapsed && c.pinned
        # floating the docked cards makes room: the sidebar does not scroll anymore
        for obj in (o.pd, o.bs, o.pd2)
            GUI._float!(gui, obj)
        end
        @test only(insp.pinned).obj === o.l1 && GUI._max_offset(gui.layout.right.area) == 0
        @test count(c -> c.pinned, gui.cards.all) == 4
        _tick!(gui)
        # the floating cards cover neither each other nor the view cube
        rects = [_rect(c.background) for c in gui.cards.all if c.scene.visible[]]
        @test length(rects) == 4
        @test !any(GUI._overlaps(rects[i], rects[j]) for i in eachindex(rects) for j in (i + 1):length(rects))
        close(gui)
    end

    @testset "float and dock by clicks" begin
        # The clicks on the float button of a docked card and on the dock button of a floating
        # card keep the selection, like those on the pins
        gui, o = _fixture()
        insp, ctrl = gui.layout.inspector, gui.controls
        ctrl.selected[] = o.m
        _tick!(gui)
        _click!(gui, _center(_rect(insp.pin.box)))
        d = only(insp.pinned)
        _tick!(gui)
        sleep(0.3)  # later than a double click
        _click!(gui, _center(_rect(d.head.float.box)))
        @test ctrl.selected[] === o.m && insp.name.text[] == "Mirror 1" && _w(gui, :x) isa Textbox
        @test isempty(insp.pinned) && GUI._is_floating(gui, o.m) && insp.pin.active[]
        _tick!(gui)
        c = only(GUI._floating_cards(gui, o.m))
        @test c.scene.visible[]
        # a click on a widget of the floating card keeps the selection, too
        sleep(0.3)
        _click!(gui, _center(_rect(GUI._card_widget(c, :y))))
        @test ctrl.selected[] === o.m && GUI._card_widget(c, :y).focused[] && GUI._typing(gui)
        GUI._card_widget(c, :y).focused[] = false
        sleep(0.3)
        _click!(gui, _center(_rect(c.dock_button.box)))
        @test ctrl.selected[] === o.m && insp.name.text[] == "Mirror 1"
        @test !GUI._is_floating(gui, o.m) && only(insp.pinned).obj === o.m
        _tick!(gui)
        @test !c.scene.visible[]
        # floated again and unpinned by a click on the pin of the floating card
        sleep(0.3)
        _click!(gui, _center(_rect(only(insp.pinned).head.float.box)))
        _tick!(gui)
        c = only(GUI._floating_cards(gui, o.m))
        sleep(0.3)
        _click!(gui, _center(_rect(c.pin_button.box)))
        @test ctrl.selected[] === o.m && !GUI._is_pinned(gui, o.m) && !insp.pin.active[]
        @test isempty(insp.pinned) && _w(gui, :x) isa Textbox
        close(gui)
    end

    @testset "keyboard" begin
        gui, o = _fixture()
        ctrl = gui.controls
        ev = events(gui.ax.scene)
        cam = cameracontrols(gui.ax.scene)
        ctrl.selected[] = o.m
        # a box of the docked card takes the keyboard: the camera and the controls ignore the keys
        box = _w(gui, :x)
        box.focused[] = true
        @test GUI._typing(gui) && !cam.selected[]
        P0 = Vector{Float64}(BMO.position(o.m))
        ev.keyboardbutton[] = Makie.KeyEvent(Keyboard.left, Keyboard.press)
        @test Vector{Float64}(BMO.position(o.m)) == P0
        box.focused[] = false
        @test !GUI._typing(gui) && cam.selected[]
        # the step box as well
        gui.widgets.step_box.focused[] = true
        @test GUI._typing(gui) && !cam.selected[]
        gui.widgets.step_box.focused[] = false
        @test !GUI._typing(gui)
        # another selection ends the input into the old box
        box = _w(gui, :x)
        box.focused[] = true
        ctrl.selected[] = o.pd
        @test !box.focused[] && !GUI._typing(gui)
        # and so does another page, which hides the boxes
        ctrl.selected[] = o.m
        box = _w(gui, :x)
        box.focused[] = true
        _page!(gui.layout.inspector.card, :properties)
        @test !box.focused[] && !GUI._typing(gui)
        _page!(gui.layout.inspector.card, :pose)
        gui.widgets.step_box.focused[] = true
        _page!(gui.layout.inspector.card, :properties)
        @test !gui.widgets.step_box.focused[] && !GUI._typing(gui)
        close(gui)
    end

    @testset "a failing properties method" begin
        gui, o = _fixture()
        m = Module()
        Core.eval(m, quote
            import BeamletOptics
            struct Broken end
            BeamletOptics.properties(::Broken) = error("boom")
        end)
        # errors of `properties` are shown, not thrown
        rows = Base.invokelatest(GUI._inspector_rows, gui, Base.invokelatest(m.Broken))
        @test only(rows)[1] == "Error"
        @test occursin("boom", only(rows)[2])
        close(gui)
    end
end

end
