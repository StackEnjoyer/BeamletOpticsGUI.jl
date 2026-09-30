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

    @testset "a click on a group opens its selection card ($layout)" for layout in (:compact, :app)
        gui = _live_view(layout)
        _click!(gui, fx.m1)
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

        # a click on the selected group opens the card again, which deselects it
        _click!(gui, fx.m3)
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
        _click!(gui, fx.m1)
        GUI._choose_entry!(gui, fx.m3)
        @test gui.controls.selected[] === fx.m3
        @test isnothing(gui.objects.browsed)

        # a lens of the doublet is shown, not selected for moving
        _click!(gui, fx.m1)
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
        _click!(gui, fx.m2)
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
        _click!(gui, fx.m1)
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
        _click!(gui, fx.m1)
        # a click on a part acts as its entry: the subgroup is browsed, then the mirror selected
        _click!(gui, fx.m1)
        @test gui.objects.browsed === fx.pair
        _click!(gui, fx.m2)
        @test gui.controls.selected[] === fx.m2
        @test isnothing(gui.objects.browsed)
        # a click beside the parts closes the card: on the background and on another object
        _click!(gui, fx.m1)
        _click!(gui, nothing)
        @test isnothing(gui.objects.browsed)
        @test isnothing(gui.controls.selected[])
        _click!(gui, fx.m1)
        GUI._choose_entry!(gui, fx.pair)
        _click!(gui, fx.m3)
        @test isnothing(gui.objects.browsed)
        @test isnothing(gui.controls.selected[])
        # the part under the cursor, see `_part_under_cursor`, decides
        _click!(gui, fx.m1)
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
            _click!(gui, fx.m1)
            @test calls == [(:browse, fx.bench, Any[fx.pair, fx.dl, fx.m3])]
            # hover over the entries: the part of a part entry, none for "Select"
            _move!(gui, _entry_center(gui, 3))
            @test last(calls) == (:hover, fx.dl)
            _move!(gui, _entry_center(gui, 1))
            @test last(calls) == (:hover, nothing)
            # level change
            empty!(calls)
            GUI._choose_entry!(gui, fx.pair)
            @test calls == [(:browse, fx.pair, Any[fx.m1, fx.m2])]
            # the end, once
            empty!(calls)
            GUI._choose_entry!(gui, fx.m1)
            @test calls == [(:end,)]
            _key!(gui, Keyboard.escape)
            @test calls == [(:end,)]
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
