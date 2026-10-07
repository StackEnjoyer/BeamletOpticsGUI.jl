module TestLiveBeamColor

using GLMakie, BeamletOptics, BeamletOpticsGUI
using Makie
using Test

const BMO = BeamletOptics
const GUI = BeamletOpticsGUI

@testset "Color of the beams" begin

    # Each change is solved at once, see `TestLiveView.jl`; no card of a detector is pinned at start
    _live_view(args...; kwargs...) =
        live_view(args...; merge((; trace_budget = Inf, throttle = false, detectors = []), kwargs)...)

    function _mirror(y = 0.1)
        m = RoundPlanoMirror(25e-3, 5e-3)
        zrotate3d!(m, deg2rad(45))
        translate3d!(m, [0, y, 0])
        return m
    end
    _beam(λ = 632.8e-9) = Beam([0.0, 0, 0], [0.0, 1, 0], λ)

    # The card of the selection: docked in the inspector of the app layout, else floating
    _card(gui::GUI.AppView) = gui.layout.inspector.card
    _card(gui) = gui.cards.selection
    _hex(c) = GUI._color_hex(Makie.to_color(c))
    # The plots of a beam hold one color per vertex
    _plot_colors(gui, beam) = unique(_hex(c) for p in GUI._color_plots(gui, beam) for c in p.color[])
    # Shows the page of the card of the selected `obj`
    function _show!(gui, obj, page)
        gui.controls.selected[] = obj
        GUI._update_selection_box!(gui.controls)
        GUI._update_cards!(gui)
        GUI._update_inspector!(gui)
        GUI._set_page!(gui, _card(gui), page)
        return _card(gui)
    end
    _names(card) = [w.name for (_, w) in card.widgets if !isnothing(w.name)]

    @testset "hex and input" begin
        @test GUI._color_hex(Makie.RGBf(1, 0.5, 0)) == "#ff8000"
        @test GUI._color_hex(Makie.to_color(:black)) == "#000000"
        @test _hex(GUI._parse_color("#ff8000")) == "#ff8000"
        @test _hex(GUI._parse_color("FF8000")) == "#ff8000"
        @test _hex(GUI._parse_color("orange")) == _hex(:orange)
        @test isnothing(GUI._parse_color("")) && isnothing(GUI._parse_color("no color"))
        @test isnothing(GUI._parse_color("#12345"))
        options = GUI._color_options()
        @test first(options) == "wavelength" && options[2] == "layout" && last(options) == "custom"
        @test allunique(options) && allunique(_hex.(last.(GUI._COLOR_PRESETS)))
    end

    @testset "color and opacity, $layout" for layout in (:compact, :app)
        m = _mirror()
        beam = _beam()
        group = UniformDiscSource([0.01, 0, 0], [0.0, 1, 0], 5e-3, 532e-9; num_rays = 20)
        gauss = GaussianBeamlet([-0.01, 0, 0], [0.0, 1, 0], 450e-9, 1e-3)
        gui = _live_view(System([m]) => beam, System([m]) => group, System([m]) => gauss; layout)
        layout_hex = _hex(gui.layout.theme.rays)

        # the sources of the start have the color of their wavelength
        @test _plot_colors(gui, beam) == [_hex(GUI._wavelength_color(632.8e-9))]
        @test GUI._color_preset(gui, beam) == "wavelength"
        @test _plot_colors(gui, group) == [_hex(GUI._wavelength_color(532e-9))]
        @test GUI._color_preset(gui, group) == "wavelength"
        @test GUI._color_preset(gui, gauss) == "wavelength"
        @test GUI._beam_opacity(gui, beam) == 1

        # a color: of all of its plots and of its kwargs
        for src in (beam, group, gauss)
            GUI._set_beam_color!(gui, src, :orange)
            @test _plot_colors(gui, src) == [_hex(:orange)]
            @test _hex(gui.beams.kwargs[src].color) == _hex(:orange)
            @test _hex(GUI._beam_color(gui, src)) == _hex(:orange)
        end
        @test _plot_colors(gui, group) == [_hex(:orange)]
        # display only: nothing is traced again
        @test !gui.trace.stale && isnothing(gui.trace.error)

        # the entries of the menu
        GUI._apply_color_preset!(gui, beam, "wavelength")
        @test _hex(GUI._beam_color(gui, beam)) == _hex(GUI._wavelength_color(632.8e-9))
        @test GUI._color_preset(gui, beam) == "wavelength"
        GUI._apply_color_preset!(gui, group, "wavelength")
        @test _plot_colors(gui, group) == [_hex(GUI._wavelength_color(532e-9))]
        GUI._apply_color_preset!(gui, beam, "layout")
        @test _plot_colors(gui, beam) == [layout_hex] && GUI._color_preset(gui, beam) == "layout"
        GUI._apply_color_preset!(gui, beam, "magenta")
        @test GUI._color_preset(gui, beam) == "magenta"
        # "custom" and no selection keep the color
        GUI._apply_color_preset!(gui, beam, "custom")
        GUI._apply_color_preset!(gui, beam, nothing)
        @test GUI._color_preset(gui, beam) == "magenta"

        # the box: a hex value or a name, anything else only a message
        GUI._apply_color_input!(gui, beam, " #123456 ")
        @test _plot_colors(gui, beam) == ["#123456"] && GUI._color_preset(gui, beam) == "custom"
        GUI._apply_color_input!(gui, beam, "no color")
        @test _plot_colors(gui, beam) == ["#123456"]
        @test occursin("invalid color \"no color\"", gui.status.text[])
        GUI._apply_color_input!(gui, beam, nothing)
        @test _plot_colors(gui, beam) == ["#123456"]

        # kept when the beam is rendered again, switched off and on, and solved
        GUI._set_flen!(gui, beam, 0.05)
        @test _plot_colors(gui, beam) == ["#123456"]
        GUI._set_beam_on!(gui, beam, false)
        GUI._set_beam_on!(gui, beam, true)
        @test _plot_colors(gui, beam) == ["#123456"]
        @test all(p -> p.visible[], GUI._color_plots(gui, beam))

        # the opacity: of its plots and its kwargs, clamped
        GUI._set_beam_opacity!(gui, gauss, 0.4)
        @test GUI._beam_opacity(gui, gauss) ≈ 0.4
        @test all(p -> p.alpha[] ≈ 0.4f0, GUI._alpha_plots(gui, gauss))
        @test GUI._beam_opacity_percent(gui, gauss) == 40
        GUI._set_beam_opacity!(gui, beam, 2)
        @test GUI._beam_opacity(gui, beam) == 1
        GUI._set_beam_opacity!(gui, beam, 0.5)
        GUI._set_flen!(gui, beam, 0.07)
        @test all(p -> p.alpha[] ≈ 0.5f0, GUI._alpha_plots(gui, beam))
        @test _plot_colors(gui, beam) == ["#123456"]
        @test !gui.trace.stale
        close(gui)
    end

    @testset "beam_kwargs color wins over the wavelength" begin
        beam = _beam()
        gui = _live_view(System([_mirror()]) => beam; beam_kwargs = Dict(beam => (; color = :orange)))
        @test _plot_colors(gui, beam) == [_hex(:orange)]
        @test GUI._color_preset(gui, beam) == "custom"
        close(gui)
    end

    @testset "outdated beams stay dimmed" begin
        m = _mirror()
        beam = _beam()
        gui = _live_view(System([m]) => beam; auto_trace = false)
        GUI._trace!(gui)
        translate3d!(m, [0, 0.01, 0])
        gui.controls.on_change(m)
        @test gui.trace.stale
        plots = GUI._alpha_plots(gui, beam)
        @test all(p -> p.alpha[] ≈ GUI._STALE_ALPHA, plots)
        GUI._set_beam_color!(gui, beam, :orange)
        GUI._set_beam_opacity!(gui, beam, 0.6)
        @test gui.trace.stale
        @test all(p -> p.alpha[] ≈ GUI._STALE_ALPHA, plots)
        @test GUI._beam_opacity(gui, beam) ≈ 0.6
        # restored with the next solve
        GUI._trace!(gui)
        @test all(p -> p.alpha[] ≈ 0.6f0, GUI._alpha_plots(gui, beam))
        @test _plot_colors(gui, beam) == [_hex(:orange)]
        close(gui)
    end

    @testset "clip planes stay applied" begin
        beam = _beam()
        gui = _live_view(System([_mirror()]) => beam; clip_planes = [[0, 0.05, 0] => [0, 1, 0]],
            clip_beams = true)
        planes = [p.clip_planes[] for p in GUI._color_plots(gui, beam)]
        @test all(!isempty, planes)
        GUI._set_beam_color!(gui, beam, :green)
        GUI._set_beam_opacity!(gui, beam, 0.5)
        @test [p.clip_planes[] for p in GUI._color_plots(gui, beam)] == planes
        close(gui)
    end

    @testset "page of the card, $layout" for layout in (:compact, :app)
        m = _mirror()
        beam = _beam(532e-9)
        gui = _live_view(System([m]) => beam; layout)
        card = _show!(gui, beam, :pose)
        pose_names = _names(card)
        @test :beam_on in pose_names && !(:color in pose_names)

        # the page "Color": its three rows instead of those of the page "Pose"
        card = _show!(gui, beam, :color)
        @test card.page === :color
        names = _names(card)
        @test :color in names && :color_hex in names && :beam_opacity in names
        @test !(:beam_on in names) && !(:remove in names)
        menu = GUI._card_widget(card, :color)
        box = GUI._card_widget(card, :color_hex)
        slider = GUI._card_widget(card, :beam_opacity)
        @test menu isa Menu && box isa Textbox && slider isa Slider
        @test menu.selection[] == "wavelength"
        @test box.displayed_string[] == _hex(GUI._wavelength_color(532e-9))
        @test slider.value[] == 100

        # the menu sets the color and the box shows it
        menu.i_selected[] = findfirst(==("layout"), menu.options[])
        @test _plot_colors(gui, beam) == [_hex(gui.layout.theme.rays)]
        @test box.displayed_string[] == _hex(gui.layout.theme.rays)
        # the box sets the color and the menu shows "custom"
        box.stored_string[] = "#102030"
        @test _plot_colors(gui, beam) == ["#102030"]
        @test menu.selection[] == "custom"
        # the slider sets the opacity
        Makie.set_close_to!(slider, 30)
        @test GUI._beam_opacity(gui, beam) ≈ 0.3
        @test GUI._card_widget(card, :beam_opacity_value).text[] == "30 %"
        # the slider of the line width sets it, without a solve, and it survives a new length
        @test :beam_linewidth in names && :beam_linewidth_value in names
        lw = GUI._card_widget(card, :beam_linewidth)
        @test lw isa Slider
        gui.trace.stale = false
        Makie.set_close_to!(lw, 3.0)
        @test GUI._beam_linewidth(gui, beam) ≈ 3.0
        @test gui.beams.kwargs[beam].linewidth ≈ 3.0
        @test !isempty(GUI._linewidth_plots(gui, beam))
        @test all(p -> p.linewidth[] ≈ 3.0, GUI._linewidth_plots(gui, beam))
        @test GUI._card_widget(card, :beam_linewidth_value).text[] == "3.0"
        GUI._set_flen!(gui, beam, 0.06)
        @test all(p -> p.linewidth[] ≈ 3.0, GUI._linewidth_plots(gui, beam))
        @test !gui.trace.stale

        # keys go to the search of the open menu, presses to its options
        @test !GUI._typing(gui)
        menu.is_open[] = true
        @test GUI._card_menu_open(gui) && GUI._typing(gui) && gui.controls.ignore_mouse()
        menu.is_open[] = false
        @test !GUI._card_menu_open(gui)

        # back on the page "Pose", its rows are built again; the other pages keep them
        card = _show!(gui, beam, :pose)
        @test _names(card) == pose_names
        card = _show!(gui, beam, :properties)
        @test _names(card) == pose_names
        # another object without the page: its default page
        card = _show!(gui, beam, :color)
        gui.controls.selected[] = m
        GUI._update_selection_box!(gui.controls)
        GUI._update_cards!(gui)
        GUI._update_inspector!(gui)
        @test _card(gui).page === :pose
        @test :remove in _names(_card(gui)) && !(:color in _names(_card(gui)))
        close(gui)
    end

    @testset "pinned card keeps its page" begin
        beam = _beam()
        gui = _live_view(System([_mirror()]) => beam)
        card = _show!(gui, beam, :color)
        GUI._toggle_pin!(gui, beam)
        GUI._update_cards!(gui)
        pinned = only(c for c in gui.cards.all if c.pinned && c.obj === beam)
        GUI._set_page!(gui, pinned, :color)
        @test :color in _names(pinned)
        gui.controls.selected[] = nothing
        GUI._update_cards!(gui)
        @test pinned.page === :color && :color in _names(pinned)
        close(gui)
    end
end

end
