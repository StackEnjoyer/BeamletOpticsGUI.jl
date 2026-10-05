module TestLiveApp

using GLMakie, BeamletOptics, BeamletOpticsGUI
using BeamletOptics: render_children, render_plots, rendered
using Makie
using Test

const BMO = BeamletOptics
const GUI = BeamletOpticsGUI

@testset "Live view app layout" begin

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

    _key!(gui, key) = (events(gui.ax.scene).keyboardbutton[] = Makie.KeyEvent(key, Keyboard.press))

    # Deterministic solves, see TestLiveView.jl
    _live_app(args...; kwargs...) =
        live_view(args...; merge((; trace_budget = Inf, layout = :app), kwargs)...)

    _width(block) = widths(block.layoutobservables.computedbbox[])[1]
    _height(block) = widths(block.layoutobservables.computedbbox[])[2]
    _marker(gui, src) = only(oh for oh in render_children(gui.controls.h) if rendered(oh) === src)

    @testset "construction" begin
        m, pd = _fixture()
        gui = _live_app(System([m, pd]), Beam([0.0, 0, 0], [0.0, 1, 0]);
            sliders = ["a" => (0:0.1:1, v -> nothing)])
        @test gui isa GUI.AppView
        @test gui isa GUI.LiveView
        @test gui.layout isa GUI.AppLayout
        @test Tuple(gui.fig.scene.viewport[].widths) == (1600, 950)
        # the results of the detector are on its card: the dock has no tab and starts collapsed
        @test isempty(gui.layout.dock_panels) && isempty(gui.layout.tabs.bar.titles)
        @test !gui.layout.dock.shown
        @test isnothing(gui.widgets.menu)
        @test gui.sliders isa Makie.SliderGrid
        # the catalog is docked below the object tree and the sliders
        @test first.(gui.layout.sections[:left]) == ["Objects", "Parameters", "Components"]
        @test first.(gui.layout.sections[:right]) == ["Properties"]
        # the built-in groups and the one of the own tools, with the toggle of the catalog
        @test first.(gui.layout.groups) == [:trace, :camera, :display, :tools, :panels, :user]
        @test occursin("1 ray", gui.widgets.info.text[])
        @test occursin("perspective", gui.widgets.info.text[])
        close(gui)

        # without sliders, the 3D view fills the height between the toolbar and the status bar
        m, pd = _fixture()
        gui = _live_app(System([m, pd]), Beam([0.0, 0, 0], [0.0, 1, 0]); detectors = [],
            size = (1280, 800))
        @test isnothing(gui.sliders)
        @test !gui.layout.dock.shown
        @test !gui.layout.collapse.dock.active[]
        @test first.(gui.layout.sections[:left]) == ["Objects", "Components"]
        @test _height(gui.ax) > 650
        close(gui)

        # the compact layout is the default
        gui = live_view(System([m, pd]), Beam([0.0, 0, 0], [0.0, 1, 0]); trace_budget = Inf)
        @test gui isa GUI.CompactView
        @test gui.widgets.menu isa Makie.Menu
        close(gui)

        @test_throws ArgumentError _live_app(System([m, pd]), Beam([0.0, 0, 0], [0.0, 1, 0]);
            layout = :fancy)
        @test_throws ArgumentError _live_app(System([m, pd]), Beam([0.0, 0, 0], [0.0, 1, 0]);
            theme = :blue)
        @test_throws ArgumentError live_view(System([m, pd]), Beam([0.0, 0, 0], [0.0, 1, 0]);
            theme = :blue)
    end

    @testset "dark theme" begin
        m, pd = _fixture()
        gui = _live_app(System([m, pd]), Beam([0.0, 0, 0], [0.0, 1, 0]); theme = :dark)
        t = GUI._APP_THEMES[:dark]
        @test gui.layout.theme == t
        @test gui.fig.scene.backgroundcolor[] == t.background
        @test gui.ax.scene.backgroundcolor[] == t.view
        @test gui.status.color[] == t.text
        close(gui)

        # the colors of the 3D view and of the detector view follow the theme
        _rgb(c) = RGBf(Makie.to_color(c))
        _plots(gui, obj) = render_plots(only(oh for oh in render_children(gui.controls.h) if rendered(oh) === obj))
        _detector_color(gui, pd) = _rgb(first(p for p in _plots(gui, pd) if p isa Makie.Mesh).color[])
        m, pd = _fixture()
        beam = Beam([0.0, 0, 0], [0.0, 1, 0])
        dark = _live_app(System([m, pd]), beam; theme = :dark,
            clip_planes = [[0, 0.05, 0] => [0, 1, 0]], detectors = [pd => (:intensity, (; profiles = true))])
        # the rays in the color of their wavelength, here 1000 nm, in both themes (one color per vertex)
        @test only(unique(_rgb.(only(render_plots(dark.beam_handles[1])).color[]))) == _rgb(GUI._wavelength_color(1.0e-6))
        @test _detector_color(dark, pd) == t.materials[:detector]
        # the mirror keeps the color of the look
        @test _rgb(first(_plots(dark, m)).color[]) == BMO.look_colors()[:reflective]
        plane = only(dark.clip.planes)
        @test only(p for p in _plots(dark, plane) if p isa Makie.Lines).color[] == t.clip_plane
        @test all(p -> p.strokecolor[] == t.marker_stroke,
            filter(p -> p isa Makie.Scatter, [_plots(dark, plane); _plots(dark, beam)]))
        help = only(p for p in dark.controls.plots if p isa Makie.Text && p.parent === dark.ax.blockscene)
        @test help.color[] == t.help
        # the floating cards in the colors of the theme, with a border
        @test dark.cards.selection.background.strokevisible[] && dark.cards.selection.background.strokecolor[] == t.border
        @test dark.cards.selection.background.color[] == t.sidebar
        @test dark.widgets.trace_button.plots[3].backgroundcolor[] == t.tooltip
        # the detector view of the inspector: the spots in the text color, the profiles in the red
        # and blue of the gizmo
        dark.controls.selected[] = pd
        view = dark.layout.inspector.card.view
        @test view isa GUI._DetectorView && view.theme == t
        @test all(p -> p.color[] == t.text, view.spots)
        @test (view.profile_x.color[], view.profile_z.color[]) == (t.gizmo[1], t.gizmo[3])
        close(dark)
        # the light theme keeps the colors of the compact layout
        m, pd = _fixture()
        light = _live_app(System([m, pd]), beam)
        @test _detector_color(light, pd) == BMO.look_colors()[:detector]
        @test only(unique(_rgb.(only(render_plots(light.beam_handles[1])).color[]))) == _rgb(GUI._wavelength_color(1.0e-6))
        # the cards in the light colors, with a border
        @test light.cards.selection.background.color[] == GUI._app_theme(:light).sidebar
        close(light)
    end

    @testset "toolbar drives the shared logic" begin
        m, pd = _fixture()
        beam = Beam([0.0, 0, 0], [0.0, 1, 0])
        gui = _live_app(System([m, pd]), beam; throttle = false, clip_planes = [[0, 0.1, 0] => [0, 1, 0]])
        # flat icon buttons and toggles
        @test gui.widgets.trace_button isa GUI._IconButton
        @test gui.widgets.auto_trace_toggle isa GUI._IconToggle
        @test gui.layout.clip_toggle isa GUI._IconToggle
        @test gui.layout.fit_button isa GUI._IconButton
        @test all(t -> t isa GUI._IconToggle, gui.layout.collapse)
        @test gui.widgets.orthographic_toggle.tooltip[] == "Orthographic"
        @test gui.layout.clip_toggle.tooltip[] == "Clipping (c)"
        # orthographic, via a click on the toggle
        cam = cameracontrols(gui.ax.scene)
        @test cam.settings.projectiontype[] == Makie.Perspective
        bb = gui.widgets.orthographic_toggle.box.layoutobservables.computedbbox[]
        events(gui.fig.scene).mouseposition[] = Tuple(Makie.origin(bb) .+ Makie.widths(bb) ./ 2)
        for action in (Mouse.press, Mouse.release)
            events(gui.fig.scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, action)
        end
        @test gui.widgets.orthographic_toggle.active[]
        @test cam.settings.projectiontype[] == Makie.Orthographic
        gui.widgets.orthographic_toggle.active[] = false
        # the views icon opens the views menu
        gui.layout.views_button.clicks[] += 1
        @test gui.widgets.views_menu.is_open[]
        gui.layout.views_button.clicks[] += 1
        @test !gui.widgets.views_menu.is_open[]
        gui.widgets.orthographic_toggle.active[] = true
        @test cam.settings.projectiontype[] == Makie.Orthographic
        @test occursin("orthographic", gui.widgets.info.text[])
        gui.widgets.orthographic_toggle.active[] = false
        @test cam.settings.projectiontype[] == Makie.Perspective
        # auto trace and trace button
        @test gui.trace.auto === gui.widgets.auto_trace_toggle.active
        gui.widgets.auto_trace_toggle.active[] = false
        gui.controls.selected[] = m
        _key!(gui, Keyboard.left)
        @test gui.trace.stale
        gui.widgets.trace_button.clicks[] += 1
        @test !gui.trace.stale
        gui.widgets.auto_trace_toggle.active[] = true
        # clipping, in sync with the key `c`
        @test gui.clip.enabled && gui.layout.clip_toggle.active[]
        gui.layout.clip_toggle.active[] = false
        @test !gui.clip.enabled
        @test isempty(gui.ax.scene.theme.clip_planes[])
        _key!(gui, Keyboard.c)
        @test gui.clip.enabled && gui.layout.clip_toggle.active[]
        @test length(gui.ax.scene.theme.clip_planes[]) == 1
        # clip beams
        gui.widgets.clip_beams_toggle.active[] = true
        @test gui.clip.beams
        gui.widgets.clip_beams_toggle.active[] = false
        @test !gui.clip.beams
        # sources
        marker = _marker(gui, beam)
        gui.widgets.sources_toggle.active[] = false
        @test !any(p -> p.visible[], render_plots(marker))
        gui.widgets.sources_toggle.active[] = true
        @test all(p -> p.visible[], render_plots(marker))
        # measure
        gui.widgets.measure_toggle.active[] = true
        @test startswith(gui.status.text[], "measure:")
        gui.widgets.measure_toggle.active[] = false
        # fit
        gui.layout.fit_button.clicks[] += 1
        @test !isnothing(gui.camera.animation)
        # the views menu is in the toolbar
        n = length(gui.camera.views)
        redirect_stdout(() -> (gui.widgets.save_view_button.clicks[] += 1), devnull)
        @test length(gui.camera.views) == n + 1
        @test length(gui.widgets.views_menu.options[]) == n + 1
        close(gui)
    end

    @testset "inspector" begin
        m, pd = _fixture()
        gui = _live_app(System([m, pd]), Beam([0.0, 0, 0], [0.0, 1, 0]); throttle = false,
            labels = Dict(m => "M1"))
        @test gui.layout.inspector.name.text[] == "No selection"
        gui.controls.selected[] = m
        @test gui.layout.inspector.name.text[] == "M1"
        @test gui.layout.inspector.type.text[] == string(nameof(typeof(m)))
        # the pose rows of the card, docked in the inspector
        card = gui.layout.inspector.card
        @test GUI._card_widget(card, :y).displayed_string[] == "100.0"
        GUI._card_widget(card, :x).stored_string[] = "5"
        @test BMO.position(m)[1] ≈ 5e-3
        @test gui.layout.inspector.mode.selected[] == :move
        gui.widgets.step_box.stored_string[] = "1 mrad"
        @test gui.layout.inspector.mode.selected[] == :rotate
        # the step box is in the inspector, not on a card
        @test gui.widgets.step_box !== gui.cards.selection.step_box
        # the pages of the card: a mirror opens on its pose, a detector on its results
        @test card.pages == (:pose, :properties) && card.page == :pose
        @test card.rows_part.shown && card.step_part.shown && !card.view_part.shown
        gui.controls.selected[] = pd
        @test card.pages == (:pose, :results, :properties) && card.page == :results
        @test card.view_part.shown && card.view isa GUI._DetectorView && !card.rows_part.shown
        @test GUI._layout_views(gui) == [(pd, card.view)]
        # no component menu, the eyes of the tree and "show all" in its title replace it
        @test gui.widgets.show_all_button isa GUI._IconButton
        close(gui)
    end

    # A system with a group of two lenses, a static housing, a detector, a source and a clip plane
    function _tree_fixture(; kwargs...)
        l1 = SphericalLens(0.1, -0.1, 4e-3, 25.4e-3)
        l2 = SphericalLens(-0.1, 0.1, 2e-3, 25.4e-3)
        translate3d!(l2, [0, 0.015, 0])
        group = ObjectGroup([l1, l2])
        translate3d!(group, [0, 0.04, 0])
        m, pd = _fixture()
        cube = BMO.CubeMesh(0.01)
        translate3d!(cube, [0.03, 0.1, 0])
        housing = NonInteractableObject(cube)
        beam = Beam([0.0, 0, 0], [0.0, 1, 0])
        gui = _live_app(System([group, m, pd, housing]), beam; throttle = false,
            labels = Dict(pd => "PD1"), clip_planes = [[0, 0.1, 0] => [0, 0, 1]], kwargs...)
        return gui, (; l1, l2, group, m, pd, housing, beam)
    end

    _rows(gui) = gui.layout.tree.rows
    _row(gui, key) = only(r for r in _rows(gui) if r.key === key)
    _labels(gui) = [r.label for r in _rows(gui)]

    @testset "object tree rows" begin
        gui, o = _tree_fixture()
        tree = gui.layout.tree
        @test tree isa GUI._ObjectTree
        # systems expanded, groups collapsed; sources and clip planes after the systems
        @test _labels(gui) == ["System 1", "ObjectGroup 1", "Mirror 1", "PD1",
            "NonInteractableObject 1", "Beam 1", "Clip plane 1"]
        @test [r.kind for r in _rows(gui)] ==
              [:system, :group, :mirror, :detector, :mesh, :source, :clip_plane]
        @test [r.depth for r in _rows(gui)] == [0, 1, 1, 1, 1, 0, 0]
        @test _row(gui, o.group).expandable && !_row(gui, o.group).expanded
        @test _row(gui, gui.system_handles[1]).expanded
        # eyes for everything that is rendered, none for clip planes
        @test all(r -> r.visible === true, _rows(gui)[1:6])
        @test isnothing(_row(gui, gui.clip.planes[1]).visible)
        # the names are used in the status line and the inspector
        @test GUI._label(gui, o.m) == "Mirror 1"
        # the kinds of the tree, by dispatch
        @test GUI._tree_kind(o.l1) == :lens
        @test GUI._tree_kind(o.pd) == :detector
        @test GUI._tree_kind(gui.system_handles[1]) == :system
        @test GUI._tree_kind(RoundThinBeamsplitter(0.01)) == :beamsplitter
        # one plot per part, independent of the number of rows
        @test length(tree.scene.plots) == 7
        # the compact layout has no tree and its hooks do nothing
        close(gui)
        gui = live_view(System([o.m, o.pd]), o.beam; trace_budget = Inf)
        @test !hasproperty(gui.layout, :tree)
        @test isnothing(GUI._on_clip_planes_changed!(gui))
        @test GUI._label(gui, o.m) == "Mirror 1"
        _key!(gui, Keyboard.p)
        @test gui.labels[gui.clip.planes[1]] == "Clip plane 1"
        close(gui)
    end

    @testset "object tree interaction" begin
        gui, o = _tree_fixture()
        tree, ctrl = gui.layout.tree, gui.controls
        # a click on a row selects like a click in the 3D view
        tree.clicked[] = o.m
        @test ctrl.selected[] === o.m
        @test tree.selected === o.m
        @test gui.layout.inspector.name.text[] == "Mirror 1"
        @test startswith(gui.status.text[], "Mirror 1")
        # objects that are not movable (e.g. static ones, or not among the `objects` kwarg of the
        # controls) are inspected instead of selected, they are listed and can be hidden
        filter!(x -> x !== o.housing, ctrl.movable)
        tree.clicked[] = o.housing
        @test isnothing(ctrl.selected[]) && gui.objects.inspected === o.housing
        @test gui.layout.inspector.name.text[] == "NonInteractableObject 1"
        # a selection in the 3D view (here: of an object in a collapsed group) expands the group
        # and highlights the row
        ctrl.selected[] = o.l2
        @test _row(gui, o.group).expanded
        @test "Lens 2" in _labels(gui)
        @test _row(gui, o.l2).depth == 2
        @test tree.selected === o.l2
        ctrl.selected[] = nothing
        @test isnothing(tree.selected)
        # expanders keep their state per group
        tree.expand_clicked[] = o.group
        @test !_row(gui, o.group).expanded
        @test !("Lens 1" in _labels(gui))
        tree.expand_clicked[] = gui.system_handles[1]
        @test _labels(gui) == ["System 1", "Beam 1", "Clip plane 1"]
        tree.expand_clicked[] = gui.system_handles[1]
        @test length(_rows(gui)) == 7
        # the eye hides and shows, the row is muted
        handle(obj) = only(oh for oh in render_children(ctrl.h) if rendered(oh) === obj)
        tree.eye_clicked[] = o.housing
        @test o.housing in gui.objects.hidden
        @test !any(p -> p.visible[], render_plots(handle(o.housing)))
        @test _row(gui, o.housing).visible === false
        @test tree.plots.labels.color[][5] == tree.muted_color
        tree.eye_clicked[] = o.housing
        @test isempty(gui.objects.hidden)
        @test all(p -> p.visible[], render_plots(handle(o.housing)))
        @test _row(gui, o.housing).visible === true
        # hiding a group hides its objects and clears a selection within it
        ctrl.selected[] = o.l1
        tree.eye_clicked[] = o.group
        @test o.l1 in gui.objects.hidden && o.l2 in gui.objects.hidden
        @test isnothing(ctrl.selected[])
        @test _row(gui, o.group).visible === false
        # the system eye hides everything, "show all" shows everything again
        tree.eye_clicked[] = gui.system_handles[1]
        @test all(r -> r.visible === false, _rows(gui)[1:5])
        gui.widgets.show_all_button.clicks[] += 1
        @test isempty(gui.objects.hidden)
        @test all(r -> r.visible !== false, _rows(gui))
        # the source marker
        tree.eye_clicked[] = o.beam
        @test !any(p -> p.visible[], render_plots(handle(o.beam)))
        tree.eye_clicked[] = o.beam
        @test all(p -> p.visible[], render_plots(handle(o.beam)))
        close(gui)
    end

    @testset "object tree clip planes" begin
        gui, o = _tree_fixture()
        tree = gui.layout.tree
        # `p` adds a numbered plane, selected and shown in the tree
        _key!(gui, Keyboard.p)
        plane = gui.clip.planes[end]
        @test _labels(gui)[end] == "Clip plane 2"
        @test tree.selected === plane
        @test gui.layout.inspector.name.text[] == "Clip plane 2"
        # `Delete` removes it, the numbers are not reused
        _key!(gui, Keyboard.delete)
        @test _labels(gui)[end] == "Clip plane 1"
        @test isnothing(tree.selected)
        _key!(gui, Keyboard.p)
        @test _labels(gui)[end] == "Clip plane 3"
        # a click selects a plane
        ctrl = gui.controls
        ctrl.selected[] = nothing
        tree.clicked[] = gui.clip.planes[1]
        @test ctrl.selected[] === gui.clip.planes[1]
        close(gui)
    end

    @testset "collapsing" begin
        m, pd = _fixture()
        gui = _live_app(System([m, pd]), Beam([0.0, 0, 0], [0.0, 1, 0]);
            sliders = ["a" => (0:0.1:1, v -> nothing)])
        layout = gui.layout
        # a panel in the dock, which shows it
        axis = Ref{Any}(nothing)
        add_panel!(l -> (axis[] = Axis(l[1, 1]); nothing), gui, "Own")
        @test layout.dock.shown
        w0, h0 = _width(gui.ax), _height(gui.ax)
        box = gui.widgets.step_box
        layout.collapse.right.active[] = false
        @test !layout.right.shown
        @test _width(gui.ax) ≈ w0 + 300
        # hidden and laid out off-screen, where it can not take clicks
        @test !box.blockscene.visible[]
        @test maximum(box.layoutobservables.computedbbox[])[1] < 0
        layout.collapse.left.active[] = false
        @test _width(gui.ax) ≈ w0 + 540
        @test !gui.sliders.blockscene.visible[]
        layout.collapse.dock.active[] = false
        @test !layout.dock.shown
        @test _height(gui.ax) > h0 + 200
        @test !axis[].blockscene.visible[]
        # restored
        foreach(t -> t.active[] = true, layout.collapse)
        @test layout.left.shown && layout.right.shown && layout.dock.shown
        @test _width(gui.ax) ≈ w0
        @test _height(gui.ax) ≈ h0
        @test box.blockscene.visible[]
        @test minimum(box.layoutobservables.computedbbox[])[1] > 0
        @test axis[].scene.visible[]
        # the detector view of the inspector is not shown while the sidebar is collapsed
        gui.controls.selected[] = pd
        view = layout.inspector.card.view
        @test GUI._shown_views(gui) == [(pd, view)] && view.ax.blockscene.visible[]
        layout.collapse.right.active[] = false
        @test isempty(GUI._shown_views(gui)) && !view.ax.blockscene.visible[]
        layout.collapse.right.active[] = true
        @test GUI._shown_views(gui) == [(pd, view)] && view.ax.blockscene.visible[]
        close(gui)
    end

    @testset "spectator mode: only the 3D view and the help" begin
        m, pd = _fixture()
        gui = _live_app(System([m, pd]), Beam([0.0, 0, 0], [0.0, 1, 0]);
            sliders = ["a" => (0:0.1:1, v -> nothing)])
        layout, ctrl, help = gui.layout, gui.controls, gui.layout.help
        # a panel in the dock, which shows it
        axis = Ref{Any}(nothing)
        add_panel!(l -> (axis[] = Axis(l[1, 1]); nothing), gui, "Own")
        cube = gui.widgets.view_cube
        ev = events(gui.fig.scene)
        fig = Rect2f(gui.fig.scene.viewport[])
        view() = Rect2f(gui.ax.scene.viewport[])
        same(a, b) = minimum(a) ≈ minimum(b) && Makie.widths(a) ≈ Makie.widths(b)
        bbox(b) = Rect2f(b.layoutobservables.computedbbox[])
        center(r) = minimum(r) .+ Makie.widths(r) ./ 2
        parked(part) = minimum(part.outer.layoutobservables.suggestedbbox[])[1] < -1.0f4
        function click!(p)
            ev.mouseposition[] = (Float64(p[1]), Float64(p[2]))
            ev.mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.press)
            ev.mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.release)
            return nothing
        end
        parts = (layout.bar, layout.status_bar, layout.left, layout.right, layout.dock)
        @test all(p -> p.shown, parts) && !layout.ui_hidden
        # the left sidebar is collapsed before, a card is pinned in the right one
        layout.collapse.left.active[] = false
        GUI._toggle_pin!(gui, m)
        GUI._toggle_pin!(gui, pd)
        pinned_view = last(layout.inspector.pinned).view
        @test GUI._shown_views(gui) == [(pd, pinned_view)]
        v1 = view()
        ortho = gui.widgets.orthographic_toggle
        button = bbox(ortho.box)
        blocks = (gui.status, gui.widgets.step_box, ortho.box, axis[],
            first(layout.inspector.pinned).head.title, pinned_view.ax)

        _key!(gui, Keyboard.v)
        @test ctrl.spectator[] && layout.ui_hidden
        @test !any(p -> p.shown, parts)
        @test same(view(), fig)
        # hidden and off-screen, where they take no clicks
        @test all(b -> !b.blockscene.visible[] && maximum(bbox(b))[1] < 0, blocks)
        # no detector view is shown, i.e. none is computed
        @test isempty(GUI._shown_views(gui))
        active = ortho.active[]
        click!(center(button))
        @test ortho.active[] == active
        # no view cube: a click at its place does not turn the camera
        @test !cube.scene.visible[]
        click!(center(Rect2f(cube.scene.viewport[])))
        @test isnothing(cube.anim)
        # the help pill and the chip of the mode stay, inside the 3D view
        @test !parked(help.pill) && !parked(help.spectator) && parked(help.chips)
        @test all(minimum(GUI._overlay_rect(help.pill)) .>= minimum(fig))
        # the toggles keep their state and do not show a part meanwhile
        @test !layout.collapse.left.active[] && layout.collapse.right.active[] && layout.collapse.dock.active[]
        layout.collapse.dock.active[] = false
        layout.collapse.dock.active[] = true
        layout.collapse.right.active[] = false
        layout.collapse.right.active[] = true
        @test !layout.dock.shown && !layout.right.shown && same(view(), fig)

        # back: each part as its toggle says, the sidebar that was collapsed stays collapsed
        _key!(gui, Keyboard.v)
        @test !ctrl.spectator[] && !layout.ui_hidden
        @test layout.bar.shown && layout.status_bar.shown && layout.right.shown && layout.dock.shown
        @test !layout.left.shown
        @test same(view(), v1)
        @test all(b -> b.blockscene.visible[] && minimum(bbox(b))[1] >= 0, blocks)
        @test same(bbox(ortho.box), button) && cube.scene.visible[]
        click!(center(button))
        @test ortho.active[] != active
        @test [c.obj for c in layout.inspector.pinned] == [m, pd]
        @test GUI._shown_views(gui) == [(pd, pinned_view)]
        close(gui)

        # a view started in the spectator mode starts without the UI
        m, pd = _fixture()
        gui = _live_app(System([m, pd]), Beam([0.0, 0, 0], [0.0, 1, 0]); spectator = true)
        layout = gui.layout
        @test layout.ui_hidden && !any(p -> p.shown, (layout.bar, layout.status_bar, layout.left,
            layout.right, layout.dock))
        @test same(Rect2f(gui.ax.scene.viewport[]), Rect2f(gui.fig.scene.viewport[]))
        GUI._set_spectator!(gui.controls, false)
        @test all(p -> p.shown, (layout.bar, layout.status_bar, layout.left, layout.right))
        # the dock has no panels
        @test !layout.dock.shown
        close(gui)

        # panels, controls and tools added in the spectator mode are hidden until it is left, e.g.
        # those of a view that starts in it
        m, pd = _fixture()
        gui = _live_app(System([m, pd]), Beam([0.0, 0, 0], [0.0, 1, 0]); spectator = true)
        layout = gui.layout
        visible(b) = b.blockscene.visible[]
        axis, button = Ref{Any}(nothing), Ref{Any}(nothing)
        add_panel!(gui, "Own") do l
            axis[] = Axis(l[1, 1])
            return _ -> nothing
        end
        add_controls!(l -> (button[] = Button(l[1, 1]; label = "x")), gui, "Mine")
        tool = add_tool!(g -> nothing, gui, "Own tool")
        @test layout.ui_hidden && !any(p -> p.shown, (layout.bar, layout.left, layout.dock))
        @test !visible(axis[]) && !visible(button[]) && !visible(tool.box)
        @test same(Rect2f(gui.ax.scene.viewport[]), Rect2f(gui.fig.scene.viewport[]))
        GUI._set_spectator!(gui.controls, false)
        @test visible(button[]) && visible(tool.box) && "Mine" in first.(layout.sections[:left])
        @test first.(layout.dock_panels) == ["Own"] && layout.dock.shown && visible(axis[])
        close(gui)

        # controls added while the left sidebar is collapsed by its toggle
        m, pd = _fixture()
        gui = _live_app(System([m, pd]), Beam([0.0, 0, 0], [0.0, 1, 0]))
        layout = gui.layout
        layout.collapse.left.active[] = false
        add_controls!(l -> (button[] = Button(l[1, 1]; label = "x")), gui, "Mine")
        @test !layout.left.shown && !visible(button[])
        layout.collapse.left.active[] = true
        @test layout.left.shown && visible(button[])
        close(gui)
    end

    @testset "one collapse mechanism" begin
        # the parts of both layouts are collapsed by the same function
        @test length(methods(GUI._set_shown!)) == 1
        @test only(methods(GUI._set_shown!)).sig.parameters[2] === GUI._LayoutPart
    end

    @testset "slots" begin
        m, pd = _fixture()
        # without the catalog; the tool "Script" is in the group of the own tools
        gui = _live_app(System([m, pd]), Beam([0.0, 0, 0], [0.0, 1, 0]); detectors = [],
            catalog = CatalogEntry[])
        # a new toolbar group after the built-in ones
        b = Button(GUI._add_toolbar_entry!(gui, :custom); label = "Mine")
        @test first.(gui.layout.groups[(end - 2):end]) == [:panels, :user, :custom]
        @test b in contents(gui.layout.groups[end].second)
        # the groups and separators alternate in the columns of the toolbar
        cols(x) = Makie.GridLayoutBase.gridcontent(x).span.cols
        @test [cols(g.second) for g in gui.layout.groups] == [1:1, 3:3, 5:5, 7:7, 9:9, 11:11, 13:13]
        # a sidebar section below the built-in ones
        g = GUI._add_sidebar_section!(gui, :right, "Extra")
        @test g isa GridLayout
        @test first.(gui.layout.sections[:right]) == ["Properties", "Extra"]
        @test_throws ArgumentError GUI._add_sidebar_section!(gui, :top, "Extra")
        # the first dock panel shows the dock
        @test !gui.layout.dock.shown
        d = GUI._add_dock_panel!(gui, "Mine")
        Axis(d[1, 1])
        @test gui.layout.dock.shown
        @test gui.layout.collapse.dock.active[]
        close(gui)

        # the compact layout has no slots yet
        gui = live_view(System([m, pd]), Beam([0.0, 0, 0], [0.0, 1, 0]); trace_budget = Inf)
        @test_throws ArgumentError GUI._add_toolbar_entry!(gui, :custom)
        @test_throws ArgumentError GUI._add_sidebar_section!(gui, :left, "Extra")
        @test_throws ArgumentError GUI._add_dock_panel!(gui, "Mine")
        close(gui)
    end
end

end
