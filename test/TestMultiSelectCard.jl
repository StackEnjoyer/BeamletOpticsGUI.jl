module TestMultiSelectCard

using GLMakie, BeamletOptics, BeamletOpticsGUI
using Makie
using Test

const BMO = BeamletOptics
const GUI = BeamletOpticsGUI

@testset "Card of a selection of several objects" begin
    # Three mirrors, one of them in a group with a second one, and a detector
    function _fixture(; kwargs...)
        m1 = RoundPlanoMirror(25e-3, 5e-3)
        zrotate3d!(m1, deg2rad(45))
        translate3d!(m1, [0, 0.1, 0])
        m2 = RoundPlanoMirror(25e-3, 5e-3)
        translate3d!(m2, [0.1, 0.1, 0])
        m3 = RoundPlanoMirror(25e-3, 5e-3)
        translate3d!(m3, [0.1, 0.2, 0])
        m4 = RoundPlanoMirror(25e-3, 5e-3)
        translate3d!(m4, [0.1, 0.0, 0.05])
        g = ObjectGroup([m4])
        pd = Detector(5e-3)
        translate3d!(pd, [-0.1, 0.2, 0])
        cs = CollimatedSource([0.0, 0, 0], [0.0, 1, 0], 2e-3, 1e-6; num_rings = 2, num_rays = 40)
        gui = live_view(System([m1, m2, m3, g, pd]) => cs; trace_budget = Inf, throttle = false,
            catalog = CatalogEntry[], labels = Dict(m1 => "M1", m2 => "M2", m3 => "M3"), kwargs...)
        return gui, (; m1, m2, m3, m4, g, pd)
    end
    _w(c, name) = GUI._card_widget(c, name)
    _attached(b) = (gc = Makie.GridLayoutBase.gridcontent(b); !isnothing(gc) && !isnothing(gc.parent))
    _tick!(gui) = (events(gui.ax.scene).tick[] = Makie.Tick(Makie.RegularRenderTick, 0, 0.0, 1.0))

    @testset "compact layout" begin
        gui, o = _fixture()
        ctrl = gui.controls
        select!(gui, [o.m1, o.m2])
        _tick!(gui)
        c = gui.cards.selection
        sel = ctrl.selected[]
        @test sel isa GUI._MultiSelection
        @test c.scene.visible[]
        @test c.title.text[] == "2 objects"
        @test c.subtitle_shown && c.subtitle.text[] == "Selection"
        # no pages: neither a page bar nor the pages "Results", "Edit" and "Properties"
        @test c.pages == (:pose,) && isnothing(c.bar) && c.page == :pose
        # a row per object with its name, the actions hide and remove, and the step and the mode
        @test _w(c, :object_1).label[] == "M1" && _w(c, :object_2).label[] == "M2"
        @test isnothing(_w(c, :object_3))
        @test _w(c, :hide) isa GUI._IconToggle && !_w(c, :hide).active[]
        @test _w(c, :remove) isa Button
        @test isnothing(_w(c, :x))
        @test c.step_shown
        # the card of a selection of several is not pinned
        @test !_attached(c.pin_button.box)
        c.pin_button.active[] = true
        @test !c.pinned && c === gui.cards.selection
        @test !any(d -> d.pinned, gui.cards.all)
        GUI._toggle_pin!(gui, sel)
        @test !any(d -> d.pinned, gui.cards.all)
        # the component menu shows no entry for the selection
        @test gui.widgets.menu.i_selected[] == 0
        # another selection of several: the card shows its objects
        select!(gui, [o.m1, o.m2, o.m3])
        _tick!(gui)
        @test c.title.text[] == "3 objects" && _w(c, :object_3).label[] == "M3"
        # a click on a name selects that object alone, whose card has its pin again
        _w(c, :object_2).clicks[] += 1
        @test ctrl.selected[] === o.m2
        _tick!(gui)
        @test gui.cards.selection.title.text[] == "M2" && _attached(gui.cards.selection.pin_button.box)
        @test !isnothing(_w(gui.cards.selection, :x))
        # the eye hides all objects and clears the selection
        select!(gui, [o.m1, o.m3])
        _tick!(gui)
        c = gui.cards.selection
        eye = _w(c, :hide)
        eye.active[] = !eye.active[]
        @test o.m1 in gui.objects.hidden && o.m3 in gui.objects.hidden
        @test !(o.m2 in gui.objects.hidden)
        @test isnothing(ctrl.selected[])
        # all of them hidden: the eye shows all of them again
        select!(gui, [o.m1, o.m3])
        _tick!(gui)
        @test _w(gui.cards.selection, :hide).active[]
        GUI._toggle_hidden!(gui, ctrl.selected[])
        @test !(o.m1 in gui.objects.hidden) && !(o.m3 in gui.objects.hidden)
        @test ctrl.selected[] isa GUI._MultiSelection
        # an object of the selection that is hidden on its own leaves it
        GUI._toggle_hidden!(gui, o.m1)
        @test ctrl.selected[] === o.m3
        GUI._toggle_hidden!(gui, o.m1)
        close(gui)
    end

    @testset "a click on an object of a group of the selection" begin
        gui, o = _fixture()
        ctrl = gui.controls
        select!(gui, [o.m1, o.g])
        @test GUI._on_leaf_click!(gui, o.m4)
        @test ctrl.selected[] === o.g
        # the selection card of groups ends with a selection of several
        GUI._browse!(gui, o.g)
        @test gui.objects.browsed === o.g
        select!(gui, [o.m1, o.g])
        @test isnothing(gui.objects.browsed)
        close(gui)
    end

    @testset "app layout" begin
        gui, o = _fixture(; layout = :app)
        ctrl = gui.controls
        insp = gui.layout.inspector
        card = insp.card
        select!(gui, [o.m1, o.m2])
        @test insp.name.text[] == "2 objects"
        @test insp.type.text[] == "Selection"
        @test card.pages == () || card.pages == (:pose,)
        @test isnothing(card.bar) || !card.bar_part.shown
        @test card.rows_part.shown && !card.properties_part.shown && !card.view_part.shown
        @test _w(card, :object_1).label[] == "M1" && _w(card, :object_2).label[] == "M2"
        @test _w(card, :hide) isa GUI._IconToggle && _w(card, :remove) isa Button
        @test isnothing(_w(card, :x))
        # no pin in the header, and its toggle pins nothing
        @test !insp.pin.box.visible[]
        insp.pin.active[] = true
        @test isempty(insp.pinned)
        insp.pin.active[] = false
        # another selection of several
        select!(gui, [o.m1, o.m2, o.m3])
        @test insp.name.text[] == "3 objects" && _w(card, :object_3).label[] == "M3"
        # a click on a name selects that object alone
        _w(card, :object_1).clicks[] += 1
        @test ctrl.selected[] === o.m1
        @test insp.name.text[] == "M1" && insp.pin.box.visible[]
        # the eye hides all objects and clears the selection
        select!(gui, [o.m2, o.m3])
        eye = _w(card, :hide)
        eye.active[] = !eye.active[]
        @test o.m2 in gui.objects.hidden && o.m3 in gui.objects.hidden
        @test isnothing(ctrl.selected[]) && insp.name.text[] == "No selection"
        close(gui)
    end
end

end
