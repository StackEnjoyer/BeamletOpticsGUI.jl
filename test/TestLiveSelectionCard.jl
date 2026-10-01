module TestLiveSelectionCard

using GLMakie, BeamletOptics, BeamletOpticsGUI
using BeamletOptics: render_plots
using Makie
using Test

const BMO = BeamletOptics
const GUI = BeamletOpticsGUI

@testset "Live selection card" begin

    _press!(gui) = (events(gui.ax.scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.press))
    _release!(gui) = (events(gui.ax.scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.release))
    _move!(gui, xy) = (events(gui.ax.scene).mouseposition[] = (Float64(xy[1]), Float64(xy[2])))
    _key!(gui, key) = (events(gui.ax.scene).keyboardbutton[] = Makie.KeyEvent(key, Keyboard.press))

    # A bench (group) of a pair of mirrors (subgroup), a doublet and a third mirror, and a lens that
    # is in no group
    function _fixture()
        m1, m2, m3 = (RoundPlanoMirror(0.02, 0.004) for _ in 1:3)
        translate3d!(m2, [0, 0.05, 0])
        translate3d!(m3, [0, 0.25, 0])
        pair = ObjectGroup([m1, m2])
        dl = SphericalDoubletLens(0.0617, -0.0446, -0.1296, 6e-3, 2.5e-3, 25.4e-3, 1.5, 1.6)
        translate3d!(dl, [0, 0.15, 0])
        bench = ObjectGroup([pair, dl, m3])
        lens = SphericalLens(0.05, -0.05, 5e-3, 25.4e-3, 1.5)
        translate3d!(lens, [0.1, 0.1, 0])
        return (; bench, pair, dl, m1, m2, m3, lens)
    end
    fx = _fixture()

    # The plot that the custom `pick` of the controls returns, `nothing` for the background
    picked = Ref{Any}(nothing)
    _live_view(layout) = live_view(System([fx.bench, fx.lens]), Beam([0.0, 0, 0], [0.0, 1, 0]);
        layout, detectors = [], trace_budget = Inf, throttle = false, pick = _ -> (picked[], 0),
        labels = Dict(fx.bench => "Bench", fx.pair => "Pair", fx.dl => "Achromat", fx.dl.front => "Crown",
            fx.m3 => "Flat"))
    _plot(gui, leaf) = first(render_plots(GUI._child_handle(gui.controls.h, leaf)))
    # A click in the 3D view on `leaf` (`nothing`: the background), at the right edge of the view,
    # where no card is
    function _click!(gui, leaf)
        picked[] = isnothing(leaf) ? nothing : _plot(gui, leaf)
        vp = gui.ax.scene.viewport[]
        _move!(gui, (vp.origin[1] + vp.widths[1] - 3, vp.origin[2] + vp.widths[2] / 2))
        @assert !GUI._over_browse_card(gui)
        _press!(gui)
        _release!(gui)
        picked[] = nothing
        return nothing
    end
    _card(gui) = gui.cards.browse
    # A click on `leaf` and "More" of the small menu that it opens: the selection card
    function _open!(gui, leaf)
        _click!(gui, leaf)
        @assert _card(gui).compact
        GUI._choose_entry!(gui, 2)
        return nothing
    end
    # Clicks on the entries right after they changed count, see `_BROWSE_GUARD`
    GUI._BROWSE_GUARD[] = 0.0
    _labels(gui) = copy(_card(gui).labels)
    _shown(gui) = _card(gui).scene.visible[]
    # The center of the entry `i` of the selection card [figure px]
    function _entry_center(gui, i)
        c = _card(gui)
        GUI._update_cards!(gui)
        r = GUI._at(c.rects[i], c.origin)
        return minimum(r) .+ Makie.widths(r) ./ 2
    end
    # The card of the selection shows the selected object: floating (compact) or in the inspector (app)
    _component_card_shown(gui::GUI.LiveView{GUI.AppLayout}) = !isnothing(GUI._shown_object(gui))
    _component_card_shown(gui) = gui.cards.selection.scene.visible[]

    @testset "the selection card of a group ($layout)" for layout in (:compact, :app)
        gui = _live_view(layout)
        _open!(gui, fx.m1)
        @test gui.objects.browsed === fx.bench
        @test isnothing(gui.controls.selected[])
        @test isnothing(GUI._shown_object(gui))
        GUI._update_cards!(gui)
        @test _shown(gui)
        @test !_component_card_shown(gui)
        @test _labels(gui) == ["Select Bench", "Pair ›", "Achromat ›", "Flat"]
        @test only(vcat(_card(gui).title.text[])) == "Bench"
        # the card lies inside the 3D view
        c = _card(gui)
        r, v = GUI._card_rect(c.origin, c.size), Rect2f(gui.ax.scene.viewport[])
        @test all(minimum(r) .>= minimum(v)) && all(maximum(r) .<= maximum(v))

        # "Select" selects the group, with its card and the gizmo
        GUI._choose_entry!(gui, 1)
        @test gui.controls.selected[] === fx.bench
        @test isnothing(gui.objects.browsed)
        @test gui.controls.gizmo_visible[]
        GUI._update_cards!(gui)
        @test !_shown(gui)
        @test _component_card_shown(gui)

        # a click inside the selection keeps it; its card has the button "parts", which opens the
        # selection card again and deselects
        _click!(gui, fx.m3)
        @test isnothing(gui.objects.browsed)
        @test gui.controls.selected[] === fx.bench
        GUI._browse!(gui, fx.bench)
        @test gui.objects.browsed === fx.bench
        @test isnothing(gui.controls.selected[])

        # a subgroup is browsed, then selected
        GUI._choose_entry!(gui, fx.pair)
        @test gui.objects.browsed === fx.pair
        @test _labels(gui) == ["Select Pair", "‹ Bench", GUI._label(gui, fx.m1), GUI._label(gui, fx.m2)]
        GUI._choose_entry!(gui, 1)
        @test gui.controls.selected[] === fx.pair
        @test isnothing(gui.objects.browsed)

        # a single part is selected
        _click!(gui, nothing)
        _open!(gui, fx.m1)
        GUI._choose_entry!(gui, fx.m3)
        @test gui.controls.selected[] === fx.m3
        @test isnothing(gui.objects.browsed)

        # a lens of the doublet is shown, not selected for moving
        _open!(gui, fx.m1)
        GUI._choose_entry!(gui, fx.dl)
        @test gui.objects.browsed === fx.dl
        back = GUI._label(gui, fx.dl.back)
        @test startswith(back, "Lens ")
        @test _labels(gui) == ["Select Achromat", "‹ Bench", "Crown", back]
        GUI._choose_entry!(gui, fx.dl.front)
        @test isnothing(gui.controls.selected[])
        @test gui.objects.inspected === fx.dl.front
        @test isnothing(gui.objects.browsed)
        @test _component_card_shown(gui)
        close(gui)
    end

    @testset "levels, ‹ and Esc" begin
        gui = _live_view(:compact)
        _open!(gui, fx.m2)
        GUI._choose_entry!(gui, fx.pair)
        # "‹" goes one level up
        GUI._choose_entry!(gui, 2)
        @test gui.objects.browsed === fx.bench
        GUI._choose_entry!(gui, fx.pair)
        # Esc goes one level up, closes the card at the top level
        _key!(gui, Keyboard.escape)
        @test gui.objects.browsed === fx.bench
        @test _shown(gui) || (GUI._update_cards!(gui); _shown(gui))
        _key!(gui, Keyboard.escape)
        @test isnothing(gui.objects.browsed)
        GUI._update_cards!(gui)
        @test !_shown(gui)
        @test isnothing(gui.controls.selected[])
        # hidden parts are not listed
        GUI._toggle_hidden!(gui, fx.m3)
        GUI._browse!(gui, fx.bench)
        @test _labels(gui) == ["Select Bench", "Pair ›", "Achromat ›"]
        GUI._end_browse!(gui)
        GUI._toggle_hidden!(gui, fx.m3)
        @test_throws ArgumentError GUI._choose_entry!(gui, 1)
        close(gui)
    end

    @testset "clicks on the card" begin
        gui = _live_view(:compact)
        _open!(gui, fx.m1)
        GUI._update_cards!(gui)
        # the card takes the clicks, the 3D view behind it does not
        _move!(gui, _entry_center(gui, 2))
        @test GUI._over_browse_card(gui)
        @test gui.controls.ignore_mouse()
        @test _card(gui).hovered == 2
        _press!(gui)
        _release!(gui)
        @test gui.objects.browsed === fx.pair
        # the first entry selects
        _move!(gui, _entry_center(gui, 1))
        _press!(gui)
        _release!(gui)
        @test gui.controls.selected[] === fx.pair
        @test isnothing(gui.objects.browsed)
        close(gui)
    end

    @testset "clicks in the 3D view while browsing" begin
        gui = _live_view(:compact)
        _open!(gui, fx.m1)
        # a click on a part acts as its entry: the subgroup is browsed, then the mirror selected
        _click!(gui, fx.m1)
        @test gui.objects.browsed === fx.pair
        _click!(gui, fx.m2)
        @test gui.controls.selected[] === fx.m2
        @test isnothing(gui.objects.browsed)
        # a click beside the parts closes the card: on the background and on another object
        _click!(gui, nothing)
        _open!(gui, fx.m1)
        _click!(gui, nothing)
        @test isnothing(gui.objects.browsed)
        @test isnothing(gui.controls.selected[])
        _open!(gui, fx.m1)
        GUI._choose_entry!(gui, fx.pair)
        _click!(gui, fx.m3)
        @test isnothing(gui.objects.browsed)
        @test isnothing(gui.controls.selected[])
        # the part under the cursor, see `_part_under_cursor`, decides
        _open!(gui, fx.m1)
        m = @eval GUI _part_under_cursor(gui::LiveView, parts) = $(fx.dl) in parts ? $(fx.dl) : nothing
        try
            _click!(gui, fx.m3)
            @test gui.objects.browsed === fx.dl
        finally
            Base.delete_method(which(GUI._part_under_cursor, Tuple{GUI.LiveView, Any}))
        end
        GUI._end_browse!(gui)
        # an object that is in no group shows its card at once
        _click!(gui, fx.lens)
        @test gui.controls.selected[] === fx.lens
        @test isnothing(gui.objects.browsed)
        # while measuring, a click on a group selects it as before
        GUI._select!(gui, fx.lens)
        gui.widgets.measure_toggle.active[] = true
        _click!(gui, fx.m1)
        @test isnothing(gui.objects.browsed)
        @test gui.controls.selected[] === fx.bench
        gui.widgets.measure_toggle.active[] = false
        close(gui)
    end

    @testset "highlight calls" begin
        gui = _live_view(:compact)
        calls = Any[]
        sigs = (Tuple{GUI.LiveView, Any, Vector}, Tuple{GUI.LiveView, Any}, Tuple{GUI.LiveView})
        @eval GUI _browse_highlight!(gui::LiveView, group, parts::Vector) = push!($calls, (:browse, group, copy(parts)))
        @eval GUI _hover_highlight!(gui::LiveView, part) = push!($calls, (:hover, part))
        @eval GUI _end_highlight!(gui::LiveView) = push!($calls, (:end,))
        try
            # the small menu changes nothing in the 3D view, "More" highlights the group
            browses() = filter(c -> c[1] === :browse, calls)
            _click!(gui, fx.m1)
            @test isempty(browses())
            GUI._choose_entry!(gui, 2)
            @test browses() == [(:browse, fx.bench, Any[fx.pair, fx.dl, fx.m3])]
            # hover over the entries: the part of a part entry, none for "Select"
            _move!(gui, _entry_center(gui, 3))
            @test last(calls) == (:hover, fx.dl)
            _move!(gui, _entry_center(gui, 1))
            @test last(calls) == (:hover, nothing)
            # level change
            empty!(calls)
            GUI._choose_entry!(gui, fx.pair)
            @test browses() == [(:browse, fx.pair, Any[fx.m1, fx.m2])]
            @test !any(c -> c[1] === :end, calls)
            # the end, once
            empty!(calls)
            GUI._choose_entry!(gui, fx.m1)
            @test filter(c -> c[1] !== :hover, calls) == [(:end,)]
            _key!(gui, Keyboard.escape)
            @test filter(c -> c[1] !== :hover, calls) == [(:end,)]
        finally
            foreach(s -> Base.delete_method(which(getfield(GUI, s[1]), s[2])),
                zip((:_browse_highlight!, :_hover_highlight!, :_end_highlight!), sigs))
        end
        close(gui)
    end

    @testset "‹ on the card of a part" begin
        gui = _live_view(:compact)
        c = gui.cards.selection
        GUI._select!(gui, fx.m1)
        GUI._update_cards!(gui)
        @test c.back_shown
        @test c.back.layoutobservables.suggestedbbox[] != GUI._CARD_AWAY
        c.back_button.clicks[] += 1
        @test gui.objects.browsed === fx.pair
        @test isnothing(gui.controls.selected[])
        # the lens of a doublet: the doublet
        GUI._choose_entry!(gui, 2)
        GUI._choose_entry!(gui, fx.dl)
        GUI._choose_entry!(gui, fx.dl.front)
        GUI._update_cards!(gui)
        @test c.back_shown
        c.back_button.clicks[] += 1
        @test gui.objects.browsed === fx.dl
        # top-level objects have none
        GUI._end_browse!(gui)
        GUI._select!(gui, fx.bench)
        GUI._update_cards!(gui)
        @test !c.back_shown
        @test c.back.layoutobservables.suggestedbbox[] == GUI._CARD_AWAY
        GUI._select!(gui, fx.lens)
        GUI._update_cards!(gui)
        @test !c.back_shown
        close(gui)

        # the card docked in the inspector of the app layout
        gui = _live_view(:app)
        back = gui.layout.inspector.back
        @test !back.box.visible[]
        GUI._select!(gui, fx.m1)
        GUI._show_pin!(gui)
        @test back.box.visible[]
        back.clicks[] += 1
        @test gui.objects.browsed === fx.pair
        GUI._end_browse!(gui)
        GUI._select!(gui, fx.bench)
        GUI._show_pin!(gui)
        @test !back.box.visible[]
        close(gui)
    end

    # A click at the figure pixel `xy` of the 3D view on `leaf`
    function _click_at!(gui, leaf, xy)
        picked[] = isnothing(leaf) ? nothing : _plot(gui, leaf)
        _move!(gui, xy)
        _press!(gui)
        _release!(gui)
        picked[] = nothing
        return nothing
    end
    _mouse(gui) = Point2f(events(gui.ax.scene).mouseposition[])
    # The rectangle of the shown entry `k` of the selection card [figure px]
    _entry_rect(gui, k) = GUI._at(_card(gui).rects[k], _card(gui).origin)
    _state(plots) = [(p.alpha[], p.transparency[]) for p in plots]
    # Closes the selection card and deselects, without a click
    function _reset!(gui)
        GUI._end_browse!(gui)
        gui.controls.selected[] = nothing
        GUI._update_selection_box!(gui.controls)
        return nothing
    end

    @testset "small menu under the cursor ($layout)" for layout in (:compact, :app)
        gui = _live_view(layout)
        ctrl, c = gui.controls, _card(gui)
        view = Rect2f(gui.ax.scene.viewport[])
        center = Point2f(minimum(view) .+ Makie.widths(view) ./ 2)
        plots = GUI._object_plots(ctrl.h, fx.bench)
        state = _state(plots)
        # the selection is kept while the menu is open
        GUI._select!(gui, fx.lens)
        n = length(gui.ax.scene.plots)
        _click_at!(gui, fx.m1, center)
        @test gui.objects.browsed === fx.bench && c.compact
        @test _labels(gui) == ["Select Bench", "More ›"]
        @test c.visible == [1, 2] && _shown(gui)
        @test ctrl.selected[] === fx.lens
        # "Select" lies under the cursor and is marked without a mouse move
        @test _mouse(gui) in _entry_rect(gui, 1)
        @test c.hovered == 1 && c.hover_box.visible[]
        @test c.origin == c.spot
        # nothing of the group changed: not see-through, no boxes of parts; only the box of the
        # group, in the color of the selection box
        @test _state(plots) == state
        @test isnothing(GUI._highlight(gui))
        @test c.preview isa Makie.LineSegments && c.preview in gui.ax.scene.plots
        @test c.preview.color[] == GUI._selection_box_color(gui)
        @test length(gui.ax.scene.plots) == n + 1
        # the mark leaves "Select": no box
        _move!(gui, _entry_center(gui, 2))
        @test c.hovered == 2 && isnothing(c.preview)
        # a second click at the same place selects the group
        _reset!(gui)
        _click_at!(gui, fx.m1, center)
        @test c.compact
        _press!(gui)
        _release!(gui)
        @test ctrl.selected[] === fx.bench
        @test isnothing(gui.objects.browsed) && isnothing(c.preview)
        @test length(gui.ax.scene.plots) == n
        @test _state(plots) == state

        # a click inside the selection keeps it and opens no menu: the group and a part of it
        _click_at!(gui, fx.m3, center)
        @test ctrl.selected[] === fx.bench && isnothing(gui.objects.browsed)
        GUI._select!(gui, fx.pair)
        _click_at!(gui, fx.m1, center)
        @test ctrl.selected[] === fx.pair && isnothing(gui.objects.browsed)
        # another part of the group: the menu of the outermost group
        _click_at!(gui, fx.m3, center)
        @test gui.objects.browsed === fx.bench && c.compact
        @test ctrl.selected[] === fx.pair

        # a click beside the menu closes it and counts like any other click
        _click_at!(gui, fx.lens, center .+ Point2f(0, 150))
        @test isnothing(gui.objects.browsed) && ctrl.selected[] === fx.lens
        _click_at!(gui, fx.m1, center)
        _click_at!(gui, nothing, center .+ Point2f(0, 150))
        @test isnothing(gui.objects.browsed)
        # on another group object: its menu, at the new place
        _click_at!(gui, fx.m1, center)
        spot = c.spot
        _click_at!(gui, fx.m3, center .+ Point2f(0, 150))
        @test gui.objects.browsed === fx.bench && c.compact && c.spot != spot
        @test _mouse(gui) in _entry_rect(gui, 1)

        # keys: Esc closes the menu and keeps the selection, Enter selects, the arrows move the mark
        GUI._select!(gui, fx.lens)
        _click_at!(gui, fx.m1, center)
        _key!(gui, Keyboard.escape)
        @test isnothing(gui.objects.browsed) && ctrl.selected[] === fx.lens
        _click_at!(gui, fx.m1, center)
        P0 = Vector(position(fx.lens))
        _key!(gui, Keyboard.down)
        @test c.hovered == 2 && Vector(position(fx.lens)) == P0
        _key!(gui, Keyboard.up)
        @test c.hovered == 1 && !isnothing(c.preview)
        _key!(gui, Keyboard.enter)
        @test ctrl.selected[] === fx.bench && isnothing(gui.objects.browsed)
        # without a mark, Enter chooses "Select" of the small menu
        _reset!(gui)
        _click_at!(gui, fx.m1, center)
        GUI._hover_browse!(gui, nothing)
        _key!(gui, Keyboard.enter)
        @test ctrl.selected[] === fx.bench

        # near the left and the right edge of the 3D view the menu is shifted, "Select" stays under
        # the cursor
        for x in (minimum(view)[1] + 25, maximum(view)[1] - 25)
            _reset!(gui)
            _click_at!(gui, fx.m1, Point2f(x, center[2]))
            r = GUI._card_rect(c.origin, c.size)
            @test all(minimum(r) .>= minimum(view)) && all(maximum(r) .<= maximum(view))
            @test _mouse(gui) in _entry_rect(gui, 1) && c.hovered == 1
        end
        close(gui)
    end

    @testset "More opens the selection card in place" begin
        gui = _live_view(:compact)
        c = _card(gui)
        view = Rect2f(gui.ax.scene.viewport[])
        center = Point2f(minimum(view) .+ Makie.widths(view) ./ 2)
        _click_at!(gui, fx.m1, center)
        origin = c.origin
        # a click on "More": the entries of the group, the group see-through, same corner
        GUI._BROWSE_GUARD[] = 0.3
        _move!(gui, _entry_center(gui, 2))
        _press!(gui)
        _release!(gui)
        @test gui.objects.browsed === fx.bench && !c.compact
        @test _labels(gui) == ["Select Bench", "Pair ›", "Achromat ›", "Flat"]
        @test c.origin == origin
        @test !isnothing(GUI._highlight(gui)) && isnothing(c.preview)
        @test isnothing(gui.controls.selected[])
        # the first part is under the cursor and marked; the second click of an accidental double
        # click chooses nothing
        @test c.hovered == 2
        _press!(gui)
        _release!(gui)
        @test gui.objects.browsed === fx.bench
        # later it does, and the next level keeps the corner
        c.changed = 0.0
        _press!(gui)
        _release!(gui)
        @test gui.objects.browsed === fx.pair && c.origin == origin
        _key!(gui, Keyboard.escape)
        @test gui.objects.browsed === fx.bench && c.origin == origin
        GUI._BROWSE_GUARD[] = 0.0
        GUI._end_browse!(gui)
        @test isnothing(c.spot)

        # a list that does not fit below the cursor is shifted into the view
        _click_at!(gui, fx.m1, Point2f(center[1], minimum(view)[2] + 80))
        small = c.origin
        GUI._choose_entry!(gui, 2)
        r = GUI._card_rect(c.origin, c.size)
        @test c.origin[2] > small[2] && c.origin[1] == small[1]
        @test all(minimum(r) .>= minimum(view)) && all(maximum(r) .<= maximum(view))
        GUI._end_browse!(gui)

        # opened without the cursor in the 3D view: next to the group, as before
        _move!(gui, (-10, -10))
        GUI._browse!(gui, fx.bench)
        @test isnothing(c.spot) && !isnothing(c.origin)
        close(gui)
    end

    @testset "a drag at the head moves the card" begin
        gui = _live_view(:compact)
        c = _card(gui)
        view = Rect2f(gui.ax.scene.viewport[])
        center = Point2f(minimum(view) .+ Makie.widths(view) ./ 2)
        head(c) = Point2f(c.origin[1] + c.size[1] / 2, c.origin[2] - GUI._CARD_PADDING - GUI._BROWSE_HEAD / 2)
        function drag!(from, d)
            _move!(gui, from)
            _press!(gui)
            _move!(gui, from .+ d)
            _release!(gui)
        end
        # the small menu: a press on its head and a move take it along, nothing is chosen
        _click_at!(gui, fx.m1, center)
        origin = c.origin
        @test GUI._browse_entry_at(c, head(c)) == 0
        drag!(head(c), Point2f(120, 60))
        @test c.origin ≈ origin .+ Point2f(120, 60) && c.spot == c.origin
        @test gui.objects.browsed === fx.bench && c.compact && isnothing(c.drag)
        @test isnothing(gui.controls.selected[])
        # "More" and the levels below keep the new place
        moved = c.origin
        GUI._choose_entry!(gui, 2)
        @test !c.compact && c.origin == moved
        # the list as well; the camera does not move meanwhile
        eye = copy(cameracontrols(gui.ax.scene).eyeposition[])
        drag!(head(c), Point2f(-200, -40))
        @test c.origin ≈ moved .+ Point2f(-200, -40)
        @test cameracontrols(gui.ax.scene).eyeposition[] == eye
        @test gui.objects.browsed === fx.bench && !isnothing(GUI._highlight(gui))
        GUI._choose_entry!(gui, fx.pair)
        @test gui.objects.browsed === fx.pair && c.origin ≈ moved .+ Point2f(-200, -40)
        # less than the threshold: no move
        o = c.origin
        drag!(head(c), Point2f(1, 1))
        @test c.origin == o
        # a press on an entry does not move the card, also if the mouse leaves the entry
        p = _entry_center(gui, 1)
        drag!(p, Point2f(0, 60))
        @test c.origin == o && gui.objects.browsed === fx.pair
        # closed while dragged: the drag ends
        _move!(gui, head(c))
        _press!(gui)
        @test !isnothing(c.drag)
        _key!(gui, Keyboard.escape)
        _key!(gui, Keyboard.escape)
        @test isnothing(gui.objects.browsed) && isnothing(c.drag)
        _release!(gui)
        # the next card opens at the cursor again
        _click_at!(gui, fx.m1, center)
        @test c.origin == origin
        # it stays inside the 3D view
        drag!(head(c), Point2f(5000, 5000))
        r = GUI._card_rect(c.origin, c.size)
        @test all(minimum(r) .>= minimum(view)) && all(maximum(r) .<= maximum(view))
        close(gui)
    end

    @testset "long lists scroll" begin
        mirrors = [RoundPlanoMirror(0.02, 0.004) for _ in 1:8]
        foreach(((i, m),) -> translate3d!(m, [0.03 * (i - 1), 0.1, 0]), enumerate(mirrors))
        row = ObjectGroup(mirrors)
        five = ObjectGroup([RoundPlanoMirror(0.02, 0.004) for _ in 1:5])
        gui = live_view(System([row, five]), Beam([0.0, 0, 0], [0.0, 1, 0]); detectors = [],
            trace_budget = Inf, throttle = false, labels = Dict(row => "Row"))
        c = _card(gui)
        view = Rect2f(gui.ax.scene.viewport[])
        _move!(gui, minimum(view) .+ Makie.widths(view) ./ 2)
        # up to 5 parts are shown in full
        GUI._browse!(gui, five)
        @test c.visible == 1:6 && !GUI._scrollable(c) && !c.scrollbar.visible[]
        GUI._end_browse!(gui)
        # from 6 parts on, 5 are shown, with a scroll bar; the width fits all labels
        GUI._browse!(gui, row)
        @test length(c.entries) == 9 && length(c.labels) == 9
        @test c.visible == [1, 2, 3, 4, 5, 6] && length(c.rects) == 6
        @test GUI._scrollable(c) && c.scrollbar.visible[]
        height = c.size[2]
        # the wheel over the card scrolls by a row and does not zoom the camera
        cam = cameracontrols(gui.ax.scene)
        eye = cam.eyeposition[]
        _move!(gui, _entry_center(gui, 3))
        @test c.hovered == 3
        events(gui.ax.scene).scroll[] = (0.0, -1.0)
        @test c.scroll == 1 && c.visible == [1, 3, 4, 5, 6, 7]
        @test cam.eyeposition[] == eye && c.size[2] == height
        # the entry under the cursor is marked again: the next part
        @test c.hovered == 4
        foreach(_ -> (events(gui.ax.scene).scroll[] = (0.0, -1.0)), 1:5)
        @test c.scroll == 3 && c.visible == [1, 5, 6, 7, 8, 9]
        events(gui.ax.scene).scroll[] = (0.0, 1.0)
        @test c.scroll == 2
        # a click chooses the entry that is shown there
        i = c.hovered
        _press!(gui)
        _release!(gui)
        @test gui.controls.selected[] === mirrors[i - 1]

        # the arrow keys move the mark and scroll it into the view, Enter chooses it
        GUI._browse!(gui, row)
        GUI._hover_browse!(gui, nothing)
        _key!(gui, Keyboard.down)
        @test c.hovered == 1
        foreach(_ -> _key!(gui, Keyboard.down), 1:6)
        @test c.hovered == 7 && c.scroll == 1 && 7 in c.visible
        foreach(_ -> _key!(gui, Keyboard.down), 1:5)
        @test c.hovered == 9 && c.scroll == 3
        _key!(gui, Keyboard.up)
        @test c.hovered == 8 && c.scroll == 3
        foreach(_ -> _key!(gui, Keyboard.up), 1:6)
        @test c.hovered == 2 && c.scroll == 0
        # the mark of a part highlights its box
        @test GUI._highlight(gui).hovered === mirrors[1]
        _key!(gui, Keyboard.down)
        _key!(gui, Keyboard.enter)
        @test gui.controls.selected[] === mirrors[2] && isnothing(gui.objects.browsed)
        # from the last entry upwards
        GUI._browse!(gui, row)
        GUI._hover_browse!(gui, nothing)
        _key!(gui, Keyboard.up)
        @test c.hovered == 9 && c.scroll == 3
        close(gui)
    end

    @testset "parts button on the card of a group ($layout)" for layout in (:compact, :app)
        gui = _live_view(layout)
        names(obj) = [w.name for w in GUI._head_actions(obj)]
        @test names(fx.bench) == [:hide, :parts] && names(fx.dl) == [:hide, :parts]
        @test names(fx.lens) == [:hide] && names(fx.m1) == [:hide]
        GUI._select!(gui, fx.bench)
        layout == :compact ? GUI._update_cards!(gui) : GUI._refresh_inspector!(gui; force = true)
        card = layout == :compact ? gui.cards.selection : gui.layout.inspector.card
        button = GUI._card_widget(card, :parts)
        @test button isa Makie.Button && button.label[] == "parts ›"
        button.clicks[] += 1
        @test gui.objects.browsed === fx.bench && !_card(gui).compact
        @test isnothing(gui.controls.selected[])
        GUI._end_browse!(gui)
        GUI._select!(gui, fx.lens)
        layout == :compact ? GUI._update_cards!(gui) : GUI._refresh_inspector!(gui; force = true)
        @test isnothing(GUI._card_widget(card, :parts))
        close(gui)
    end

    @testset "a click on a pinned card selects its object" begin
        gui = _live_view(:compact)
        ctrl = gui.controls
        GUI._toggle_pin!(gui, fx.lens)
        GUI._toggle_pin!(gui, fx.m3)
        GUI._update_cards!(gui)
        c = only(GUI._floating_cards(gui, fx.lens))
        center(r) = Point2f(minimum(r) .+ Makie.widths(r) ./ 2)
        bbox(b) = Rect2f(b.layoutobservables.computedbbox[])
        click!(p) = (_move!(gui, p); _press!(gui); _release!(gui))
        # on its head
        @test isnothing(ctrl.selected[])
        click!(center(GUI._part_rect(c.head)))
        @test ctrl.selected[] === fx.lens
        # the selection has no second card
        GUI._update_cards!(gui)
        @test !gui.cards.selection.scene.visible[] && c.pinned
        # on a text of its rows
        GUI._select!(gui, fx.m3)
        GUI._update_cards!(gui)
        label = first(b for b in c.blocks if b isa Makie.Label &&
                      center(bbox(b)) in GUI._part_rect(c.rows))
        click!(center(bbox(label)))
        @test ctrl.selected[] === fx.lens
        # a widget keeps its click: it does not select
        GUI._select!(gui, fx.m3)
        GUI._update_cards!(gui)
        box = first(c.textboxes)
        @test GUI._over_widget(c.blocks, center(bbox(box)))
        click!(center(bbox(box)))
        @test ctrl.selected[] === fx.m3
        foreach(GUI._defocus_card!, gui.cards.all)
        # a drag of the head moves the card and does not select
        p = center(GUI._part_rect(c.head))
        _move!(gui, p)
        _press!(gui)
        _move!(gui, p .+ Point2f(30, 20))
        _release!(gui)
        @test ctrl.selected[] === fx.m3 && !isnothing(c.spot)
        # the card of the selection, which is not pinned, does not react
        GUI._toggle_pin!(gui, fx.m3)
        GUI._update_cards!(gui)
        s = gui.cards.selection
        @test s.scene.visible[] && !s.pinned
        click!(center(GUI._part_rect(s.head)))
        @test ctrl.selected[] === fx.m3
        close(gui)

        # app layout: the docked pinned cards
        gui = _live_view(:app)
        ctrl = gui.controls
        GUI._toggle_pin!(gui, fx.lens)
        GUI._refresh_inspector!(gui; force = true)
        d = only(gui.layout.inspector.pinned)
        click2!(p) = (_move!(gui, p); _press!(gui); _release!(gui))
        @test isnothing(ctrl.selected[])
        click2!(center(bbox(d.head.title)))
        @test ctrl.selected[] === fx.lens
        # its buttons keep their clicks
        GUI._select!(gui, fx.m3)
        @test !GUI._over_free(d, center(bbox(d.head.collapse.box)))
        click2!(center(bbox(d.head.collapse.box)))
        @test ctrl.selected[] === fx.m3
        close(gui)
    end

    @testset "no parts row" begin
        @test !isdefined(GUI, :parts_card_rows)
        @test !isdefined(GUI, :_PartsMenu)
        cube = CubeBeamsplitter(10e-3, λ -> 1.5)
        for obj in (fx.bench, fx.dl, fx.lens, cube, RoundLinearPolarizer(25e-3, 1e-3, 1e-3, λ -> 1.5))
            @test !any(r -> any(c -> c == "part" || (c isa CardWidget && c.name === :parts), r.cells),
                card_rows(obj))
        end
        @test GUI._part_children(cube) == BMO.shape(cube)
    end
end

end
