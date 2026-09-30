module TestLiveGroupCard

using GLMakie, BeamletOptics, BeamletOpticsGUI
using BeamletOptics: render_plots
using Makie
using Test

const BMO = BeamletOptics
const GUI = BeamletOpticsGUI

@testset "Live group card" begin

    # The card of the selection: floating (compact) or in the inspector (app)
    _card(gui::GUI.LiveView{GUI.AppLayout}) = gui.layout.inspector.card
    _card(gui) = gui.cards.selection
    _w(gui, name) = GUI._card_widget(_card(gui), name)
    _options(gui) = _w(gui, :parts).menu.options[]
    _labels(gui) = [String(first(o)) for o in _options(gui)]
    _objects(gui) = [last(o) for o in _options(gui)]
    # Chooses the entry `label` of the parts menu of the card, like a click on the option
    function _choose!(gui, label)
        i = findfirst(==(label), _labels(gui))
        @assert !isnothing(i) "no option $label in $(_labels(gui))"
        _w(gui, :parts).menu.i_selected[] = i
        return nothing
    end
    _press!(gui) = (events(gui.ax.scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.press))
    _release!(gui) = (events(gui.ax.scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.release))
    _move!(gui, xy) = (events(gui.ax.scene).mouseposition[] = (Float64(xy[1]), Float64(xy[2])))

    # A bench (group) of a pair of mirrors (subgroup), a doublet and a third mirror, and a lens
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
        labels = Dict(fx.bench => "Bench", fx.pair => "Pair", fx.dl => "Achromat", fx.dl.front => "Crown"))

    @testset "parts rows" begin
        # SingleShape objects and anything else have none, MultiShape objects one menu
        @test parts_card_rows(fx.lens) == ()
        @test parts_card_rows(fx.m1) == ()
        @test parts_card_rows(Beam([0.0, 0, 0], [0.0, 1, 0])) == ()
        @test !any(r -> any(c -> c isa CardWidget && c.name === :parts, r.cells), card_rows(fx.lens))
        for obj in (fx.bench, fx.dl)
            row = last(card_rows(obj))
            @test first(row.cells) == "part" && row.cells[2].type === GUI._PartsMenu
            @test only(parts_card_rows(obj)).cells[2].name === :parts
        end
        cube = CubeBeamsplitter(10e-3, λ -> 1.5)
        @test last(card_rows(cube)).cells[2].name === :parts
        @test GUI._part_children(cube) == BMO.shape(cube)
        @test length(GUI._part_children(RoundLinearPolarizer(25e-3, 1e-3, 1e-3, λ -> 1.5))) == 3
    end

    @testset "one level at a time ($layout)" for layout in (:compact, :app)
        gui = _live_view(layout)
        GUI._select!(gui, fx.bench)
        # the direct children only, those with parts marked, no parent at the top level
        @test _objects(gui) == [fx.pair, fx.dl, fx.m3]
        @test _labels(gui)[1:2] == ["Pair ›", "Achromat ›"]
        @test !any(l -> startswith(l, "‹"), _labels(gui))
        @test _w(gui, :parts).menu.i_selected[] == 0
        # hidden objects are not listed
        GUI._toggle_hidden!(gui, fx.m3)
        GUI._select!(gui, fx.bench)
        @test _objects(gui) == [fx.pair, fx.dl]
        GUI._toggle_hidden!(gui, fx.m3)

        # a subgroup is selected, movable, its card lists its children and the group
        GUI._select!(gui, fx.bench)
        _choose!(gui, "Pair ›")
        @test gui.controls.selected[] === fx.pair
        @test isnothing(gui.objects.inspected)
        @test _objects(gui) == [fx.bench, fx.m1, fx.m2]
        @test _labels(gui)[1] == "‹ Bench"
        @test _labels(gui)[2] == GUI._label(gui, fx.m1)
        # back to the group
        _choose!(gui, "‹ Bench")
        @test gui.controls.selected[] === fx.bench

        # a doublet is selected, its lenses are shown, not selected for moving
        _choose!(gui, "Achromat ›")
        @test gui.controls.selected[] === fx.dl
        back = GUI._label(gui, fx.dl.back)
        @test _labels(gui) == ["‹ Bench", "Crown", back]
        # the lenses without a label are named like the other objects
        @test startswith(back, "Lens ")
        @test _objects(gui) == [fx.bench, fx.dl.front, fx.dl.back]
        _choose!(gui, "Crown")
        @test isnothing(gui.controls.selected[])
        @test gui.objects.inspected === fx.dl.front
        @test GUI._label(gui, GUI._shown_object(gui)) == "Crown"
        layout === :compact && @test gui.cards.selection.title.text[] == "Crown"
        # the rows of a lens, which ends the parts (SingleShape)
        @test !isnothing(_w(gui, :index))
        @test isnothing(_w(gui, :parts))
        # its pose shows the values, but ignores inputs
        p0 = Vector{Float64}(position(fx.dl.front))
        @test _w(gui, :x).displayed_string[] == string(round(1e3 * p0[1], digits = 6))
        _w(gui, :x).stored_string[] = "12"
        @test Vector{Float64}(position(fx.dl.front)) == p0
        @test occursin("not movable", gui.status.text[])
        # back up from the doublet to the group
        GUI._select!(gui, fx.dl)
        @test isnothing(gui.objects.inspected)
        _choose!(gui, "‹ Bench")
        @test gui.controls.selected[] === fx.bench

        # a SingleShape object has no part row
        GUI._select!(gui, fx.lens)
        @test isnothing(_w(gui, :parts))
        @test !isnothing(_w(gui, :index))
        close(gui)
    end

    @testset "card of a part at its object" begin
        gui = _live_view(:compact)
        GUI._select!(gui, fx.dl)
        _choose!(gui, "Crown")
        c = gui.cards.selection
        @test c.scene.visible[]
        # the lens has no plots of its own: the bounding box of the doublet
        bb = GUI._selection_bbox(gui.controls, fx.dl, GUI._object_plots(gui.controls.h, fx.dl))
        @test c.corners == GUI._box_corners(bb)
        close(gui)
    end

    @testset "3D clicks do not drill into a doublet" begin
        gui = _live_view(:compact)
        picked[] = first(render_plots(GUI._child_handle(gui.controls.h, fx.dl)))
        vp = gui.ax.scene.viewport[]
        _move!(gui, vp.origin .+ vp.widths ./ 2)
        # first click: the group, second click: the doublet, third click: still the doublet
        for expected in (fx.bench, fx.dl, fx.dl)
            _press!(gui)
            _release!(gui)
            @test gui.controls.selected[] === expected
        end
        @test isnothing(gui.objects.inspected)
        picked[] = nothing
        close(gui)
    end

    @testset "the open dropdown takes the clicks ($layout)" for layout in (:compact, :app)
        gui = _live_view(layout)
        GUI._select!(gui, fx.bench)
        GUI._update_cards!(gui)
        menu = _w(gui, :parts).menu
        menu.is_open[] = true
        # the options, which may reach beyond the card
        area = only(filter(s -> all(>(0), widths(s.viewport[])), menu.blockscene.children)).viewport[]
        # over the last option, the third mirror
        _move!(gui, (area.origin[1] + area.widths[1] / 2, area.origin[2] + 5))
        @test gui.controls.ignore_mouse()
        # the click chooses the option, it selects nothing behind it in the 3D view
        picked[] = first(render_plots(GUI._child_handle(gui.controls.h, fx.lens)))
        _press!(gui)
        _release!(gui)
        picked[] = nothing
        @test gui.controls.selected[] === fx.m3
        close(gui)
    end

    @testset "an open dropdown closes with its card" begin
        gui = _live_view(:compact)
        GUI._select!(gui, fx.bench)
        GUI._update_cards!(gui)
        menu = _w(gui, :parts).menu
        menu.is_open[] = true
        # e.g. `Esc` deselects the object of the card: the dropdown must not stay on screen
        gui.controls.selected[] = nothing
        GUI._update_cards!(gui)
        @test !gui.cards.selection.scene.visible[]
        @test !menu.is_open[]
        close(gui)
    end
end

end
