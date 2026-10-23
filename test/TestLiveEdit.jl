module TestLiveEdit

using GLMakie, BeamletOptics, BeamletOpticsGUI
using Makie
using LinearAlgebra: norm, normalize
using Test

const BMO = BeamletOptics
const GUI = BeamletOpticsGUI

@testset "Page \"Edit\" of the cards" begin

    # Each change is solved at once, see `TestLiveView.jl`; no card of a detector is pinned at start
    _live_view(args...; kwargs...) =
        live_view(args...; merge((; trace_budget = Inf, throttle = false, detectors = []), kwargs)...)

    _entry(name) = only(e for e in component_catalog() if e.name == name)
    _defaults(entry) = String[GUI._catalog_string(p) for p in entry.params]
    # A component or source of the catalog with the texts `strings` of its form
    _built(name, strings = _defaults(_entry(name))) = GUI._catalog_component(_entry(name), strings)

    _card(gui::GUI.AppView) = gui.layout.inspector.card
    _card(gui) = gui.cards.selection
    _names(card) = [w.name for (_, w) in card.widgets if !isnothing(w.name)]
    function _show!(gui, obj, page)
        gui.controls.selected[] = obj
        GUI._update_selection_box!(gui.controls)
        GUI._update_cards!(gui)
        GUI._update_inspector!(gui)
        GUI._set_page!(gui, _card(gui), page)
        return _card(gui)
    end
    _in(obj, list) = any(o -> o === obj, list)
    # Types the `text` into the box of the parameter `i` of the page "Edit", without Enter
    _type!(card, i, text) = (GUI._card_widget(card, Symbol(:edit_, i)).displayed_string[] = text)
    _hex(c) = GUI._color_hex(Makie.to_color(c))
    function _target(beam)
        isect = BMO.intersection(first(BMO.rays(beam)))
        return isnothing(isect) ? nothing : BMO.object(isect)
    end

    @testset "pages" begin
        m = RoundPlanoMirror(25e-3, 5e-3)
        beam = Beam([0.0, 0, 0], [0.0, 1, 0], 632.8e-9)
        gui = _live_view(System([m]) => beam)
        # the objects of the start were not built from the catalog
        @test GUI._card_pages(gui, m) == (:pose, :properties)
        @test GUI._card_pages(gui, beam) == (:pose, :color, :properties)
        @test !GUI._editable(gui, m) && !GUI._editable(gui, beam)
        lens = _built("Thin lens")
        add_component!(gui, lens.obj; origin = lens.origin)
        src = _built("Beam")
        add_component!(gui, src.obj; origin = src.origin)
        @test GUI._card_pages(gui, lens.obj) == (:pose, :edit, :properties)
        @test GUI._card_pages(gui, src.obj) == (:pose, :color, :edit, :properties)
        # an origin without its entry, e.g. given by hand
        other = RoundPlanoMirror(25e-3, 5e-3)
        add_component!(gui, other; origin = (; code = "RoundPlanoMirror(0.025, 0.005)", pose0 = GUI._pose(other)))
        @test !GUI._editable(gui, other) && GUI._card_pages(gui, other) == (:pose, :properties)
        @test GUI._page_label(:edit) == "Edit" && GUI._shows_rows(:edit)
        close(gui)
    end

    @testset "a component, $layout" for layout in (:compact, :app)
        sys = System()
        beam = Beam([0.0, 0, 0], [0.0, 1, 0], 632.8e-9)
        gui = _live_view(sys => beam; layout)
        c = _built("Thin lens")
        lens = c.obj
        rotate3d!(lens, normalize([1.0, 2, 3]), 0.4)
        translate_to3d!(lens, [0.01, 0.1, -0.02])
        add_component!(gui, lens; origin = c.origin, label = "L1")
        P, R = GUI._pose(lens)
        n_history = length(gui.controls.undo_stack)

        # the page: the name of the entry, a box per number, the menu of the glass, "Apply"
        card = _show!(gui, lens, :edit)
        names = _names(card)
        @test :edit_1 in names && :edit_2 in names && :edit_3 in names
        @test :edit_glass_4 in names && :edit_4 in names && :edit_apply in names
        @test !(:remove in names)
        box(i) = GUI._card_widget(card, Symbol(:edit_, i))
        @test box(1).displayed_string[] == "50" && box(2).displayed_string[] == "-50"
        menu = GUI._card_widget(card, :edit_glass_4)
        @test menu.selection[] == "N-BK7" && strip(box(4).displayed_string[]) == ""

        # unchanged inputs: nothing to apply
        notify(GUI._card_widget(card, :edit_apply).clicks)
        @test _in(lens, sys.objects) && length(gui.controls.undo_stack) == n_history
        @test occursin("nothing to apply", gui.status.text[])

        # an invalid input changes nothing
        _type!(card, 1, "abc")
        notify(GUI._card_widget(card, :edit_apply).clicks)
        @test _in(lens, sys.objects) && occursin("not changed", gui.status.text[])
        @test length(gui.controls.undo_stack) == n_history

        # other radii and another glass, applied with the button
        card = _card(gui)
        _type!(card, 1, "80")
        _type!(card, 2, "-80")
        menu = GUI._card_widget(card, :edit_glass_4)
        menu.i_selected[] = findfirst(==("N-SF5"), menu.options[])
        @test GUI._edit_strings(gui, lens)[4] == "N-SF5"
        @test _in(lens, sys.objects)
        notify(GUI._card_widget(card, :edit_apply).clicks)
        new = only(sys.objects)
        @test new !== lens && new isa typeof(lens)
        # in the same pose, in the same system, with the label, selected, traced
        Pn, Rn = GUI._pose(new)
        @test norm(Pn - P) < 1e-12 && norm(Rn - R) < 1e-12
        @test GUI._label(gui, new) == "L1"
        @test gui.controls.selected[] === new
        @test isnothing(gui.trace.error) && !gui.trace.stale
        @test occursin("L1 changed", gui.status.text[])
        # its card shows the page "Edit" again, with the new inputs
        card = _card(gui)
        @test card.page === :edit
        @test GUI._card_widget(card, :edit_1).displayed_string[] == "80"
        @test GUI._card_widget(card, :edit_glass_4).selection[] == "N-SF5"
        # the code of the new component
        origin = gui.components.origin[new]
        @test origin.strings == ["80", "-80", "25.4", "N-SF5"]
        @test startswith(origin.code, "ThinLens(0.08, -0.08, 0.0254, ")
        code, n = GUI._export_code(gui)
        @test n == 1 && occursin("L1 = ThinLens(0.08, -0.08, 0.0254, ", code)
        @test gui.components.added == [new] && isempty(gui.components.removed)

        # one action of the undo history: undo brings the old lens back, redo the new one
        @test length(gui.controls.undo_stack) == n_history + 1
        @test GUI._undo!(gui.controls)
        @test only(sys.objects) === lens && GUI._label(gui, lens) == "L1"
        @test GUI._pose(lens) == (P, R)
        @test gui.components.origin[lens].strings == ["50", "-50", "25.4", "N-BK7"]
        @test GUI._redo!(gui.controls)
        @test only(sys.objects) === new
        @test norm(GUI._pose(new)[1] - P) < 1e-12

        # a constant refractive index, applied with Enter in its box
        card = _show!(gui, new, :edit)
        menu = GUI._card_widget(card, :edit_glass_4)
        menu.i_selected[] = findfirst(==("constant"), menu.options[])
        @test GUI._edit_strings(gui, new)[4] == "1.5"
        GUI._card_widget(card, :edit_4).stored_string[] = "1.7"
        newer = only(sys.objects)
        @test newer !== new
        @test gui.components.origin[newer].strings[4] == "1.7"
        @test occursin("λ -> 1.7", gui.components.origin[newer].code)
        close(gui)
    end

    @testset "a source, $layout" for layout in (:compact, :app)
        m = RoundPlanoMirror(25e-3, 5e-3)
        translate3d!(m, [0, 0.2, 0])
        sys = System([m])
        gui = _live_view(sys; layout)
        c = _built("Uniform disc source", ["10", "532", "20"])
        src = c.obj
        translate_to3d!(src, [0.001, 0.02, 0.0])
        zrotate3d!(src, 0.02)
        add_component!(gui, src; origin = c.origin, label = "disc")
        P, R = GUI._pose(src)
        @test _hex(GUI._beam_color(gui, src)) == _hex(GUI._wavelength_color(532e-9))

        # another wavelength and number of rays: same pose, the color follows the wavelength
        card = _show!(gui, src, :edit)
        _type!(card, 2, "632.8")
        _type!(card, 3, "30")
        notify(GUI._card_widget(card, :edit_apply).clicks)
        new = only(gui.pairs).second
        @test new !== src && only(gui.pairs).first === sys
        @test length(BMO.beams(new)) == 30
        Pn, Rn = GUI._pose(new)
        @test norm(Pn - P) < 1e-12 && norm(Rn - R) < 1e-12
        @test GUI._label(gui, new) == "disc"
        @test _hex(GUI._beam_color(gui, new)) == _hex(GUI._wavelength_color(632.8e-9))
        @test gui.controls.selected[] === new && _card(gui).page === :edit
        @test occursin("UniformDiscSource([0.0, 0.0, 0.0], [0.0, 1.0, 0.0], 0.01, 6.328e-7; num_rays = 30)",
            GUI._export_code(gui)[1])

        # a color that was set by hand is kept
        GUI._set_beam_color!(gui, new, :black)
        _type!(_card(gui), 2, "450")
        notify(GUI._card_widget(_card(gui), :edit_apply).clicks)
        newer = only(gui.pairs).second
        @test newer !== new && _hex(GUI._beam_color(gui, newer)) == "#000000"

        # undo and redo
        @test GUI._undo!(gui.controls)
        @test only(gui.pairs).second === new
        @test GUI._undo!(gui.controls)
        @test only(gui.pairs).second === src && length(BMO.beams(src)) == 20
        @test GUI._redo!(gui.controls)
        @test only(gui.pairs).second === new
        close(gui)
    end

    @testset "text typed without Enter" begin
        sys = System()
        gui = _live_view(sys => Beam([0.0, 0, 0], [0.0, 1, 0], 632.8e-9))
        c = _built("Round mirror")
        add_component!(gui, c.obj; origin = c.origin)
        card = _show!(gui, c.obj, :edit)
        # "Apply" takes what the boxes show
        GUI._card_widget(card, :edit_1).displayed_string[] = "50.8"
        notify(GUI._card_widget(card, :edit_apply).clicks)
        new = only(sys.objects)
        @test new !== c.obj && gui.components.origin[new].strings[1] == "50.8"
        close(gui)
    end

    # A frame: the rows of a surface follow its menu at the next one
    _tick!(gui) = (events(gui.ax.scene).tick[] = Makie.Tick(Makie.RegularRenderTick, 0, 0.0, 1 / 60))
    _widget(gui, name) = GUI._card_widget(_card(gui), name)
    _shown(gui, name) = _widget(gui, name).displayed_string[]
    # Chooses the entry `name` of the menu of the surface `i`
    function _choose!(gui, i, name)
        menu = _widget(gui, Symbol(:edit_surface_, i))
        menu.i_selected[] = findfirst(==(name), menu.options[])
        return nothing
    end
    _asphere_names(i) = [Symbol(:edit_, i, :_k); [Symbol(:edit_, i, :_A, n) for n in 4:2:16]]

    @testset "surfaces of a singlet, $layout" for layout in (:compact, :app)
        sys = System()
        gui = _live_view(sys => Beam([0.0, 0, 0], [0.0, 1, 0], 632.8e-9); layout)
        c = _built("Singlet")
        lens = c.obj
        rotate3d!(lens, normalize([1.0, 2, 3]), 0.4)
        translate_to3d!(lens, [0.01, 0.1, -0.02])
        add_component!(gui, lens; origin = c.origin, label = "L1")
        P, R = GUI._pose(lens)
        spherical = copy(c.origin.strings)
        @test spherical[1:2] == ["50", "-50"]
        n_history = length(gui.controls.undo_stack)
        n_listeners = length(gui.controls.listeners)

        # a spherical surface: its menu and the box of its radius
        names = _names(_show!(gui, lens, :edit))
        @test all(in(names), (:edit_surface_1, :edit_1, :edit_surface_2, :edit_2, :edit_apply))
        @test !any(in(names), [_asphere_names(1); _asphere_names(2)])
        @test _widget(gui, :edit_surface_1).selection[] == "spherical"
        @test _shown(gui, :edit_1) == "50" && _shown(gui, :edit_2) == "-50"

        # "aspheric": the boxes of the asphere come with the next frame, typed texts are kept
        _type!(_card(gui), 1, "60")
        _choose!(gui, 2, "aspheric")
        @test GUI._edit_strings(gui, lens) == ["60", "-50; 0; 0, 0, 0, 0, 0, 0, 0", spherical[3:end]...]
        @test !(:edit_2_k in _names(_card(gui)))
        _tick!(gui)
        names = _names(_card(gui))
        @test all(in(names), _asphere_names(2)) && !any(in(names), _asphere_names(1))
        @test length(gui.controls.listeners) == n_listeners
        @test _widget(gui, :edit_surface_2).selection[] == "aspheric"
        @test _widget(gui, :edit_surface_1).selection[] == "spherical"
        @test _shown(gui, :edit_1) == "60" && _shown(gui, :edit_2) == "-50"
        @test _shown(gui, :edit_2_k) == "0" && _shown(gui, :edit_2_A16) == "0"
        @test _card(gui).page === :edit && _in(lens, sys.objects)

        # an invalid field changes nothing
        _widget(gui, :edit_2_k).displayed_string[] = "1,5"
        notify(_widget(gui, :edit_apply).clicks)
        @test _in(lens, sys.objects) && occursin("not changed", gui.status.text[])
        @test length(gui.controls.undo_stack) == n_history

        # `k` and a coefficient, typed without Enter and applied with the button
        _widget(gui, :edit_2_k).displayed_string[] = "-1"
        _widget(gui, :edit_2_A4).displayed_string[] = "1e-6"
        notify(_widget(gui, :edit_apply).clicks)
        new = only(sys.objects)
        @test new !== lens && new isa BMO.Lens
        origin = gui.components.origin[new]
        @test origin.strings == ["60", "-50; -1; 1e-6, 0, 0, 0, 0, 0, 0", spherical[3:end]...]
        @test startswith(origin.code, "Lens(SphericalSurface(0.06, 0.0254), EvenAsphericalSurface(-0.05, 0.0254, -1.0, [0.0, 1000.0])")
        Pn, Rn = GUI._pose(new)
        @test norm(Pn - P) < 1e-12 && norm(Rn - R) < 1e-12
        @test GUI._label(gui, new) == "L1" && gui.controls.selected[] === new
        @test isnothing(gui.trace.error) && occursin("L1 changed", gui.status.text[])
        # its card shows the page "Edit" again, with the boxes of the asphere
        @test _card(gui).page === :edit
        @test _widget(gui, :edit_surface_2).selection[] == "aspheric"
        @test _shown(gui, :edit_2_k) == "-1" && _shown(gui, :edit_2_A4) == "1e-6"
        # unchanged inputs: nothing to apply
        notify(_widget(gui, :edit_apply).clicks)
        @test only(sys.objects) === new && occursin("nothing to apply", gui.status.text[])

        # undo brings the spherical lens back, redo the asphere
        @test length(gui.controls.undo_stack) == n_history + 1
        @test GUI._undo!(gui.controls)
        @test only(sys.objects) === lens && gui.components.origin[lens].strings == spherical
        @test GUI._pose(lens) == (P, R)
        @test !(:edit_2_k in _names(_card(gui))) && _shown(gui, :edit_1) == "50"
        @test _widget(gui, :edit_surface_2).selection[] == "spherical"
        @test GUI._redo!(gui.controls)
        @test only(sys.objects) === new && :edit_2_k in _names(_card(gui))

        # Enter in a box of the asphere applies
        _show!(gui, new, :edit)
        _widget(gui, :edit_2_A6).stored_string[] = "2e-9"
        newer = only(sys.objects)
        @test newer !== new
        @test gui.components.origin[newer].strings[2] == "-50; -1; 1e-6, 2e-9, 0, 0, 0, 0, 0"

        # back to "spherical": the boxes go, the radius stays
        _show!(gui, newer, :edit)
        _type!(_card(gui), 2, "-70")
        _choose!(gui, 2, "spherical")
        _tick!(gui)
        @test !any(in(_names(_card(gui))), _asphere_names(2))
        @test GUI._edit_strings(gui, newer)[2] == "-70" && _shown(gui, :edit_2) == "-70"
        notify(_widget(gui, :edit_apply).clicks)
        final = only(sys.objects)
        @test final !== newer
        @test startswith(gui.components.origin[final].code, "SphericalLens(0.06, -0.07, ")
        close(gui)
    end

    @testset "an asphere with a short text" begin
        sys = System()
        gui = _live_view(sys => Beam([0.0, 0, 0], [0.0, 1, 0], 632.8e-9))
        strings = _defaults(_entry("Singlet"))
        strings[2] = "-50;-1;1e-6"
        c = _built("Singlet", strings)
        add_component!(gui, c.obj; origin = c.origin)
        names = _names(_show!(gui, c.obj, :edit))
        @test all(in(names), _asphere_names(2))
        @test _shown(gui, :edit_2_k) == "-1" && _shown(gui, :edit_2_A4) == "1e-6" && _shown(gui, :edit_2_A6) == "0"
        # the boxes as they are shown are the inputs of the lens: nothing to apply
        notify(_widget(gui, :edit_apply).clicks)
        @test only(sys.objects) === c.obj && occursin("nothing to apply", gui.status.text[])
        @test GUI._edit_strings(gui, c.obj) == strings

        # its copy has the same inputs
        GUI._CLIPBOARD[] = nothing
        @test !isnothing(GUI._copy_selected!(gui))
        pasted = GUI._paste!(gui)
        @test pasted isa BMO.Lens && pasted !== c.obj
        @test gui.components.placement.origin.strings == strings
        GUI._drop_placement!(gui)
        @test sys.objects[end] === pasted && gui.components.origin[pasted].strings == strings
        @test gui.components.origin[pasted].code == c.origin.code
        GUI._CLIPBOARD[] = nothing
        close(gui)
    end

    @testset "surfaces of a doublet, $layout" for layout in (:compact, :app)
        sys = System()
        gui = _live_view(sys => Beam([0.0, 0, 0], [0.0, 1, 0], 632.8e-9); layout)
        c = _built("Doublet")
        add_component!(gui, c.obj; origin = c.origin, label = "D1")
        n_history = length(gui.controls.undo_stack)
        names = _names(_show!(gui, c.obj, :edit))
        @test all(in(names), (:edit_surface_1, :edit_surface_2, :edit_surface_3))
        # the cemented surface as an asphere: the `DoubletLens` of the surfaces takes its place
        _choose!(gui, 2, "aspheric")
        _tick!(gui)
        @test all(in(_names(_card(gui))), _asphere_names(2))
        _widget(gui, :edit_2_k).displayed_string[] = "-1"
        notify(_widget(gui, :edit_apply).clicks)
        new = only(sys.objects)
        @test new !== c.obj && new isa DoubletLens && length(gui.controls.undo_stack) == n_history + 1
        @test occursin("D1 changed", gui.status.text[])
        @test gui.components.origin[new].strings[2] == "-45.7; -1; 0, 0, 0, 0, 0, 0, 0"
        @test startswith(gui.components.origin[new].code, "DoubletLens(SphericalSurface(0.0628, 0.0254), " *
                                                          "EvenAsphericalSurface(-0.0457, 0.0254, -1.0, [0.0]), ")
        @test _widget(gui, :edit_surface_2).selection[] == "aspheric"
        # spherical again: the `SphericalDoubletLens`
        _choose!(gui, 2, "spherical")
        _tick!(gui)
        notify(_widget(gui, :edit_apply).clicks)
        @test only(sys.objects) !== new
        @test startswith(gui.components.origin[only(sys.objects)].code, "SphericalDoubletLens(0.0628, -0.0457, ")
        # an element that BeamletOptics can not build changes nothing
        kept = only(sys.objects)
        _choose!(gui, 1, "aspheric")
        _tick!(gui)
        _widget(gui, :edit_1).displayed_string[] = "30"
        _widget(gui, :edit_2).displayed_string[] = "25"
        _widget(gui, :edit_4).displayed_string[] = "1"
        notify(_widget(gui, :edit_apply).clicks)
        @test only(sys.objects) === kept
        @test occursin("D1 not changed", gui.status.text[]) && occursin("meniscus", gui.status.text[])
        close(gui)
    end
end

end
