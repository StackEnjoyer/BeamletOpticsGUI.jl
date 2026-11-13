module TestLiveCardRowWidth

#=
Rows of a card that fill its width (`CardWidget(...; fill = true)`) and rows whose first texts line
up in one column (`CardRow(...; aligned = true)`), on the floating card (compact layout) and on the
docked card (app layout)
=#

using GLMakie, BeamletOptics, BeamletOpticsGUI
using Makie
using Test

const BMO = BeamletOptics
const GUI = BeamletOpticsGUI

# A component whose card has the rows `rows(o)`, see `card_rows`; no actions in the head
struct RowTestObject{T, S <: BMO.AbstractShape{T}} <: BMO.AbstractObject{T}
    shape::S
    rows::Any
end
RowTestObject(rows) = RowTestObject(BMO.PlanoSurfaceSDF(1e-3, 10e-3), rows)
BMO.intersect3d(::RowTestObject, ::BMO.AbstractRay) = nothing
BMO.interact3d(::BMO.AbstractSystem, ::RowTestObject, ::BMO.AbstractBeam, ::BMO.AbstractRay) = nothing
BeamletOpticsGUI.card_rows(o::RowTestObject) = o.rows()
BeamletOpticsGUI.card_actions(::RowTestObject) = ()

# The example of `skills/beamletopticsgui/WIDGETS.md`: the labels in one column, the sliders to the
# right edge of the card
mutable struct MyFilterWheel{T} <: BMO.AbstractObject{T}
    shape::BMO.PlanoSurfaceSDF{T}
    od1::Float64
    od2::Float64
end
MyFilterWheel() = MyFilterWheel(BMO.PlanoSurfaceSDF(1e-3, 25e-3), 0.0, 0.0)
BMO.intersect3d(::MyFilterWheel, ::BMO.AbstractRay) = nothing
BMO.interact3d(::BMO.AbstractSystem, ::MyFilterWheel, ::BMO.AbstractBeam, ::BMO.AbstractRay) = nothing
BeamletOpticsGUI.card_rows(w::MyFilterWheel) = (pose_card_rows(w)...,
    CardRow("OD 1",
        CardWidget(Slider; name = :od1, range = 0:0.1:4, fill = true,
            value = (gui, w) -> w.od1, on = (gui, w, v) -> (w.od1 = v));
        aligned = true),
    CardRow("OD 2 (back)",
        CardWidget(Slider; name = :od2, range = 0:0.1:4, fill = true,
            value = (gui, w) -> w.od2, on = (gui, w, v) -> (w.od2 = v));
        aligned = true))

@testset "Live card row width" begin

    _live_view(args...; kwargs...) = live_view(args...; merge((; trace_budget = Inf, detectors = []), kwargs)...)
    _card(gui::GUI.LiveView{GUI.AppLayout}) = gui.layout.inspector.card
    _card(gui) = gui.cards.selection
    function _select!(gui, obj)
        gui.controls.selected[] = obj
        GUI._update_selection_box!(gui.controls)
        GUI._update_cards!(gui)
        gui isa GUI.LiveView{GUI.AppLayout} && GUI._update_inspector!(gui; force = true)
        return nothing
    end
    _w(gui, name) = GUI._card_widget(_card(gui), name)
    _rect(x) = x.layoutobservables.computedbbox[]
    _left(x) = minimum(_rect(x))[1]
    _right(x) = maximum(_rect(x))[1]
    _width(x) = Makie.widths(_rect(x))[1]
    # The layouts of the rows of the card, from top to bottom
    _rows(gui) = GridLayout[x.content for x in _card(gui).rows.content]
    # The right edge of the widest row that has no widget that fills
    _widest(gui) = maximum(g -> _right(g), filter(g -> g.tellwidth[], _rows(gui)); init = -Inf32)
    # The first cell (a label) of the row layout `g`
    _first(g) = only(Makie.contents(g[1, 1]))
    _second(g) = only(Makie.contents(g[1, 2]))

    _beam() = Beam([0.0, 0, 0], [0.0, 1, 0])

    @testset "declarations" begin
        s = CardWidget(Slider; fill = true)
        @test s.fill && !CardWidget(Slider).fill
        @test CardRow("a", s; aligned = true).aligned && !CardRow("a", s).aligned
        # at most one widget of a row fills
        @test_throws ArgumentError CardRow("a", s, CardWidget(Slider; fill = true))
        @test_throws ArgumentError CardRow(Union{String, CardWidget}[s, s], false)
        # a given width wins
        @test GUI._fills(s) && !GUI._fills(CardWidget(Slider; fill = true, width = 80))
        @test GUI._fills(CardRow("a", s)) && !GUI._fills(CardRow("a", CardWidget(Slider)))
        # another layout rebuilds the widgets
        @test GUI._layout_key(CardRow("a", s)) != GUI._layout_key(CardRow("a", CardWidget(Slider)))
        @test GUI._layout_key(CardRow("a"; aligned = true)) != GUI._layout_key(CardRow("a"))
    end

    @testset "fill ($layout)" for layout in (:compact, :app)
        # a row with a long or a short label above a row with a slider that fills
        rows(label) = () -> (CardRow(label, CardWidget(Label; name = :value, value = (gui, o) -> "1 mm")),
            CardRow("level", CardWidget(Slider; name = :level, range = 0:10, fill = true), "%"))
        long = RowTestObject(rows("a rather long label of the first row of this card"))
        short = RowTestObject(rows("short"))
        translate3d!(short, [0, 0.05, 0])
        gui = _live_view(System([long, short]), _beam(); layout)
        widths = Float32[]
        for obj in (long, short)
            _select!(gui, obj)
            slider = _w(gui, :level)
            # the slider and the "%" behind it end at the right edge of the widest row
            pct = _second(_rows(gui)[2]) === slider ? only(Makie.contents(_rows(gui)[2][1, 3])) : nothing
            @test !isnothing(pct)
            @test abs(_right(pct) - max(_widest(gui), _right(_rows(gui)[2]))) <= 2
            @test _width(slider) > 0
            if layout === :compact
                c = _card(gui)
                @test abs(_right(pct) - _widest(gui)) <= 2
                # ... which is the right edge of the card
                @test abs(_right(pct) - (_right(c.background) - GUI._CARD_PADDING)) <= 2
            else
                # the docked rows span the sidebar
                @test abs(_right(pct) - _right(_card(gui).rows)) <= 2
            end
            push!(widths, _width(slider))
        end
        # the floating card follows the other row, the docked one has the width of the sidebar
        layout === :compact && @test widths[1] > widths[2] + 50
        close(gui)
    end

    @testset "only a row that fills ($layout)" for layout in (:compact, :app)
        obj = RowTestObject(() -> (CardRow(CardWidget(Slider; name = :level, range = 0:10, fill = true)),))
        gui = _live_view(System([obj]), _beam(); layout)
        _select!(gui, obj)
        slider, c = _w(gui, :level), _card(gui)
        # the card keeps a width: at least that of its head, and the slider ends at its right edge
        @test _width(slider) >= GUI._CARD_FILL_MIN - 1
        if layout === :compact
            @test _width(c.background) >= GUI._head_size(c)[1] + 2 * GUI._CARD_PADDING - 1
            @test abs(_right(slider) - (_right(c.background) - GUI._CARD_PADDING)) <= 2
        else
            @test abs(_right(slider) - _right(c.rows)) <= 2
        end
        close(gui)
    end

    @testset "a given width wins over fill" begin
        obj = RowTestObject(() -> (CardRow("a label that makes the card wide enough", CardWidget(Label)),
            CardRow("level", CardWidget(Slider; name = :level, range = 0:10, fill = true, width = 80))))
        gui = _live_view(System([obj]), _beam())
        _select!(gui, obj)
        @test abs(_width(_w(gui, :level)) - 80) <= 1
        @test all(g -> g.tellwidth[], _rows(gui))
        close(gui)
    end

    @testset "aligned ($layout)" for layout in (:compact, :app)
        rows = () -> (CardRow("x", CardWidget(Slider; name = :a, range = 0:10, width = 90); aligned = true),
            CardRow("a longer label", CardWidget(Slider; name = :b, range = 0:10, width = 90); aligned = true),
            CardRow("mid", CardWidget(Slider; name = :c, range = 0:10, width = 90)),
            CardRow("y", CardWidget(Slider; name = :d, range = 0:10, width = 90); aligned = true))
        obj = RowTestObject(rows)
        gui = _live_view(System([obj]), _beam(); layout)
        _select!(gui, obj)
        g = _rows(gui)
        # the second cells of the aligned rows start at the same x, behind the widest first text
        xs = [_left(_second(g[i])) for i in (1, 2, 4)]
        @test maximum(xs) - minimum(xs) <= 1
        # their first columns have the width of the widest first text
        @test all(i -> g[i].colsizes[1] == g[2].colsizes[1], (1, 4)) && g[2].colsizes[1] isa Makie.Fixed
        @test abs(g[2].colsizes[1].x - _width(_first(g[2]))) <= 1
        @test _left(_second(g[2])) >= _right(_first(g[2])) - 1
        # a row without `aligned` keeps the width of its first text
        @test _left(_second(g[3])) < minimum(xs) - 5
        @test g[3].colsizes[1] == Auto()
        close(gui)
    end

    @testset "the example of WIDGETS.md ($layout)" for layout in (:compact, :app)
        w = MyFilterWheel()
        gui = _live_view(System([w]), _beam(); layout)
        _select!(gui, w)
        od1, od2 = _w(gui, :od1), _w(gui, :od2)
        @test abs(_left(od1) - _left(od2)) <= 1
        @test abs(_right(od1) - _right(od2)) <= 2
        right = layout === :compact ? _right(_card(gui).background) - GUI._CARD_PADDING : _right(_card(gui).rows)
        @test abs(_right(od1) - right) <= 2
        close(gui)
    end
end

end
