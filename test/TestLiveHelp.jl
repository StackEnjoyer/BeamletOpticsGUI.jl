module TestLiveHelp

using GLMakie, BeamletOptics, BeamletOpticsGUI
using Makie
using Test

const BMO = BeamletOptics
const GUI = BeamletOpticsGUI

@testset "Live view help" begin

    # Rays along +y, the mirror at 45° reflects them along +x onto the detector
    function _fixture(; kwargs...)
        m = RoundPlanoMirror(25e-3, 5e-3)
        zrotate3d!(m, deg2rad(45))
        translate3d!(m, [0, 0.1, 0])
        pd = Detector(5e-3)
        zrotate3d!(pd, -π / 2)
        translate3d!(pd, [0.1, 0.1, 0])
        gui = live_view(System([m, pd]) => Beam([0.0, 0, 0], [0.0, 1, 0]); throttle = false,
            trace_budget = Inf, detectors = [], kwargs...)
        return gui, m
    end

    ev(gui) = events(gui.ax.scene)
    _tick!(gui) = (ev(gui).tick[] = Makie.Tick(Makie.RegularRenderTick, 0, 0.0, 1.0))
    _key!(gui, key) = (ev(gui).keyboardbutton[] = Makie.KeyEvent(key, Keyboard.press))
    _center(r::Rect2f) = Point2f(minimum(r) .+ Makie.widths(r) ./ 2)
    # A click (press and release without moving) at the figure pixel `p`
    function _click!(gui, p)
        ev(gui).mouseposition[] = (p[1], p[2])
        ev(gui).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.press)
        ev(gui).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.release)
        return nothing
    end
    _parked(part) = minimum(part.outer.layoutobservables.suggestedbbox[])[1] < -1.0f4
    _overlaps(a, b) = all(minimum(a) .< maximum(b)) && all(minimum(b) .< maximum(a))
    # The texts on the help card: titles and entries, the rich texts as plain strings
    _plain(s::AbstractString) = String(s)
    _plain(r::Makie.RichText) = join(_plain.(r.children))
    _texts(help) = [_plain(l.text[]) for l in help.texts]
    # The names on the key caps of all entries of the sections, without the mouse actions
    _caps(sections) = [k for (_, entries) in sections for e in entries for k in e.keys if k isa String]

    @testset "sections" begin
        move = GUI._help_sections(:move, 10e-9, 10e-6)
        @test first.(move) == ["Select", "Move the selection", "Edit", "View"]
        @test all(s -> s isa GUI._HelpSection, move)
        entries = move[2].second
        @test [e.keys for e in entries[1:4]] == [["M"], ["↑", "↓"], ["←", "→"], ["PgUp", "PgDn"]]
        @test [e.color for e in entries[2:4]] == ["green", "red", "blue"]
        @test entries[2].text == "along the green arrow"
        @test any(e -> e.text == "keyboard step, now 10 nm", entries)
        # the axes of the keys in the rotate mode, like the gizmo
        rotate = GUI._help_sections(:rotate, 10e-9, 50e-6)
        @test rotate[2].first == "Rotate the selection"
        @test [e.color for e in rotate[2].second[2:4]] == ["red", "blue", "green"]
        @test rotate[2].second[2].text == "around the red ring"
        @test any(e -> e.text == "keyboard step, now 50 µrad", rotate[2].second)
        # what a click does and its modifier
        click = move[1].second[1]
        @test click.keys == [:mouse => "click"] && click.text == "select, again: part of a group"
        click = GUI._help_sections(:move, 10e-9, 10e-6, Keyboard.left_shift; click_help = "x")[1].second[1]
        @test click.keys == ["left_shift", :mouse => "click"] && click.combo && click.text == "x"
        # the spectator mode has its own short list
        spectator = GUI._help_sections(:move, 10e-9, 10e-6; spectator = true)
        @test first.(spectator) == ["Spectator mode"]
        @test spectator[1].second[1].keys == ["V"]

        # extra sections are merged by their title, new ones follow at the end
        extra = ["View" => [GUI._HelpEntry(["1"], "one")], "Own" => [GUI._HelpEntry(["2"], "two")],
            "Own" => [GUI._HelpEntry(["3"], "three")]]
        merged = GUI._merge_sections(move, extra)
        @test first.(merged) == ["Select", "Move the selection", "Edit", "View", "Own"]
        @test last(merged[4].second).text == "one"
        @test [e.text for e in merged[5].second] == ["two", "three"]
        @test length(move[4].second) == 2

        # the text of the standalone controls: a line per title and entry
        text = GUI._help_text(move)
        lines = split(text, "\n")
        @test length(lines) == sum(s -> 1 + length(s.second), move) + 1
        @test lines[1] == "Select" && lines[end] == "h: hide controls"
        @test "  ↑/↓: along the green arrow" in lines
        @test "  +/-: keyboard step, now 10 nm" in lines
        @test "  ctrl+z: undo" in lines || "  cmd+z: undo" in lines
        @test text == GUI._help_text(:move, 10e-9, 10e-6)

        # two columns of about the same height, a single section stays alone
        columns = GUI._help_columns(move)
        @test length(columns) == 2 && reduce(vcat, columns) == move
        @test first.(columns[1]) == ["Select", "Move the selection"]
        @test GUI._help_columns(spectator) == [spectator]
        @test GUI._help_columns(GUI._HelpSection[]) == [GUI._HelpSection[]]
    end

    @testset "the keys of the live view are listed" begin
        gui, _ = _fixture()
        sections = GUI._help_sections(gui.controls)
        @test first.(sections) == ["Select", "Move the selection", "Edit", "View", "Clip planes", "Trace"]
        # each key of the live view (see `_LIVE_VIEW_KEYS`) is on a key cap; `h` is in the head of
        # the card
        ctrl = GUI._ctrl_cap()
        @test Set(_caps(sections)) == Set(["Esc", "Enter", "G", "M", "↑", "↓", "←", "→", "PgUp", "PgDn", "+",
            "−", "Shift", "Bksp", ctrl, "Z", "Y", "V", "1", "P", "Del", "C", "T"])
        # no key is listed twice; Esc is the key of the groups, a trace is cancelled by a button
        keys = [(e.keys, e.combo) for (_, entries) in sections for e in entries if !(e.keys[1] isa Pair)]
        @test allunique(keys)
        @test any(e -> occursin("Cancel in the progress window", e.text), sections[end].second)
        @test sections[1].second[1].text == GUI._BROWSE_CLICK_HELP
        close(gui)
    end

    @testset "help card, $layout $theme" for layout in (:compact, :app), theme in (:light, :dark)
        gui, m = _fixture(; layout, theme)
        ctrl = gui.controls
        help = GUI._help_ui(gui)
        t = gui.layout.theme
        vp = Rect2f(Makie.viewport(gui.ax.scene)[])
        pill = GUI._overlay_rect(help.pill)

        # closed at the start: the pill and the chips of the mode and the step, no text
        @test !ctrl.help_shown && !help.shown && _parked(help.card)
        @test ctrl.help_obs[] == ""
        @test !_parked(help.chips) && _parked(help.spectator)
        chips = GUI._overlay_rect(help.chips)
        @test minimum(chips)[1] > maximum(pill)[1] && maximum(chips)[2] ≈ maximum(pill)[2]
        @test help.mode_button.label[] == "Move" && help.step_label.text[] == "step 10 nm"
        @test GUI._help_rects(help) == [chips]
        @test chips in GUI._layout_obstacles(gui) && pill in GUI._layout_obstacles(gui)

        # the key h opens the card below the pill, in the 3D view
        _key!(gui, Keyboard.h)
        @test ctrl.help_shown && help.shown && !_parked(help.card)
        @test ctrl.help_obs[] == ""
        card = GUI._overlay_rect(help.card)
        @test minimum(card)[1] ≈ minimum(pill)[1] && maximum(card)[2] < minimum(pill)[2]
        @test minimum(card)[2] > minimum(vp)[2] && maximum(card)[1] < maximum(vp)[1]
        @test card in GUI._layout_obstacles(gui)
        texts = _texts(help)
        sections = GUI._help_sections(ctrl)
        @test length(texts) == sum(s -> 1 + length(s.second), sections)
        @test texts[1] == "SELECT" && "MOVE THE SELECTION" in texts && "TRACE" in texts
        @test "along the green arrow" in texts && "keyboard step, now 10 nm" in texts
        # the word of an axis has the color of the gizmo axis, the caps those of the theme
        green = only(l.text[] for l in help.texts if _plain(l.text[]) == "along the green arrow")
        @test green isa Makie.RichText
        @test green.children[2].attributes[:color] == t.gizmo[2]
        cap = only(b for b in help.blocks if b isa Makie.Label && b.text[] == "Bksp")
        @test Makie.to_color(cap.color[]) == Makie.to_color(t.text)

        # a click on the card is no click into the 3D view, the selection stays
        ctrl.selected[] = m
        _click!(gui, _center(card))
        @test ctrl.selected[] === m && ctrl.help_shown
        # the close button, the pill and the key h close and open the card
        _click!(gui, _center(Rect2f(help.close_button.box.layoutobservables.computedbbox[])))
        @test !ctrl.help_shown && _parked(help.card)
        _click!(gui, _center(pill))
        @test ctrl.help_shown && !_parked(help.card)
        @test ctrl.selected[] === m

        # mode and step: the chips and the card follow the keys, the buttons act like the keys
        blocks = copy(help.blocks)
        _key!(gui, Keyboard.m)
        @test help.mode_button.label[] == "Rotate" && help.step_label.text[] == "step 10 µrad"
        @test "ROTATE THE SELECTION" in _texts(help) && "around the red ring" in _texts(help)
        help.mode_button.clicks[] += 1
        @test ctrl.mode[] == :move && help.mode_button.label[] == "Move"
        ev(gui).unicode_input[] = '+'
        @test help.step_label.text[] == "step 20 nm" && "keyboard step, now 20 nm" in _texts(help)
        help.step_buttons[1].clicks[] += 1
        @test ctrl.fine_step ≈ 50e-9 && help.step_label.text[] == "step 50 nm"
        help.step_buttons[2].clicks[] += 1
        help.step_buttons[2].clicks[] += 1
        @test ctrl.fine_step ≈ 10e-9 && "keyboard step, now 10 nm" in _texts(help)
        # only the texts changed, the widgets of the card are kept
        @test help.blocks == blocks

        # spectator mode: its chip and its short card, the button leaves it like the key v
        _key!(gui, Keyboard.v)
        @test _parked(help.chips) && !_parked(help.spectator)
        @test _texts(help)[1] == "SPECTATOR MODE" && length(help.texts) == 4
        @test maximum(GUI._overlay_rect(help.card))[1] < maximum(card)[1]
        help.spectator_button.clicks[] += 1
        @test !ctrl.spectator[] && !_parked(help.chips) && _parked(help.spectator)
        @test _texts(help) == texts

        # the key of an own tool is listed
        add_tool!(g -> nothing, gui, "Align mirror"; key = Keyboard._2)
        @test _texts(help)[(end - 1):end] == ["OWN TOOLS", "Align mirror"]
        @test any(b -> b isa Makie.Label && b.text[] == "2", help.blocks)
        _key!(gui, Keyboard.h)
        @test !ctrl.help_shown && _parked(help.card)
        @test GUI._help_rects(help) == [GUI._overlay_rect(help.chips)]
        close(gui)
    end

    @testset "floating cards keep off the help card" begin
        gui, m = _fixture()
        help = GUI._help_ui(gui)
        _key!(gui, Keyboard.h)
        gui.controls.selected[] = m
        _tick!(gui)
        c = gui.cards.selection
        @test c.scene.visible[]
        card = Rect2f(c.background.layoutobservables.suggestedbbox[])
        @test !_overlaps(card, GUI._overlay_rect(help.card))
        @test !_overlaps(card, GUI._overlay_rect(help.chips))
        close(gui)
    end

    @testset "app layout: the help follows the 3D view" begin
        gui, _ = _fixture(; layout = :app)
        layout = gui.layout
        help = layout.help
        _corner(r, vp) = (minimum(r)[1] - minimum(vp)[1], maximum(vp)[2] - maximum(r)[2])
        vp = Rect2f(gui.ax.scene.viewport[])
        pill = GUI._overlay_rect(help.pill)
        @test all(0 .< _corner(pill, vp) .< 20)
        _key!(gui, Keyboard.h)
        card = GUI._overlay_rect(help.card)
        # a collapsed sidebar moves the pill, the chips and the card
        layout.collapse.left.active[] = false
        vp2 = Rect2f(gui.ax.scene.viewport[])
        @test minimum(vp2)[1] < minimum(vp)[1]
        @test all(0 .< _corner(GUI._overlay_rect(help.pill), vp2) .< 20)
        @test minimum(GUI._overlay_rect(help.card))[1] < minimum(card)[1]
        layout.collapse.left.active[] = true
        @test GUI._overlay_rect(help.pill) == pill && GUI._overlay_rect(help.card) == card
        # the help makes room for the drop-down of the views menu of the toolbar
        menu = gui.widgets.views_menu
        menu.is_open[] = true
        @test help.hidden && all(_parked, (help.pill, help.chips, help.card))
        @test isempty(GUI._help_rects(help))
        ev(gui).mouseposition[] = Tuple(_center(card))
        @test !GUI._over_layout(gui)
        menu.is_open[] = false
        @test GUI._overlay_rect(help.pill) == pill && GUI._overlay_rect(help.card) == card
        @test GUI._over_layout(gui)
        # the toolbar has no help icon
        @test !hasproperty(layout, :help_button) && !(:help in first.(layout.groups))
        close(gui)
    end

    @testset "standalone controls keep the text" begin
        fig = Figure()
        ax = LScene(fig[1, 1])
        h = live_render!(ax, System([RoundPlanoMirror(25e-3, 5e-3)]))
        c = kinematic_controls!(ax, h)
        @test isnothing(c.help_view)
        @test c.help_obs[] == GUI._help_hint(:move, 10e-9, 10e-6)
        events(ax.scene).keyboardbutton[] = Makie.KeyEvent(Keyboard.h, Keyboard.press)
        @test c.help_obs[] == GUI._help_text(:move, 10e-9, 10e-6)
        events(ax.scene).keyboardbutton[] = Makie.KeyEvent(Keyboard.v, Keyboard.press)
        @test c.help_obs[] == GUI._help_text(:move, 10e-9, 10e-6; spectator = true)
        close(c)
    end
end

end
