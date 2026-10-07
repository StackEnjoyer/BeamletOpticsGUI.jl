module TestLivePick

using GLMakie, BeamletOptics, BeamletOpticsGUI
using BeamletOptics: render_children, render_plots, rendered
using Makie
using Test

const BMO = BeamletOptics
const GUI = BeamletOpticsGUI

@testset "Live pick" begin

    _beam(y = 0.0) = Beam([0.0, y, 0], [0.0, 1, 0], 632.8e-9)
    # A mirror on the beams along +y
    function _mirror(y = 0.1)
        m = RoundPlanoMirror(25e-3, 5e-3)
        zrotate3d!(m, deg2rad(45))
        translate3d!(m, [0, y, 0])
        return m
    end

    """
    A transmitter and a receiver, each with a mirror and a beam, in the `layout`. A click in the 3D
    view picks `target[]`, see the `pick` kwarg: the plots of an object, or nothing for `nothing`.
    """
    function _fixture(layout; kwargs...)
        m1, m2 = _mirror(0.1), _mirror(0.2)
        tx, rx = System([m1]), System([m2])
        b1, b2 = _beam(), _beam(0.05)
        target = Ref{Any}(nothing)
        gui_ref = Ref{Any}(nothing)
        function pick(ax)
            isnothing(target[]) && return (nothing, 0)
            return (first(render_plots(GUI._child_handle(gui_ref[].controls.h, target[]))), 0)
        end
        gui = live_view(tx => b1, rx => b2; layout, pick, trace_budget = Inf, throttle = false,
            detectors = [], labels = Dict(tx => "TX", rx => "RX", m1 => "M1", m2 => "M2"), kwargs...)
        gui_ref[] = gui
        return (; gui, m1, m2, tx, rx, b1, b2, target)
    end

    _events(gui) = events(gui.ax.scene)
    _press!(gui) = (_events(gui).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.press))
    _release!(gui) = (_events(gui).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.release))
    _key!(gui, key) = (_events(gui).keyboardbutton[] = Makie.KeyEvent(key, Keyboard.press))
    _tick!(gui) = notify(_events(gui).tick)

    # Moves the mouse to a pixel of the 3D view that no card and no part of the layout covers
    function _into_view!(gui)
        vp = gui.ax.scene.viewport[]
        o, w = minimum(vp), Makie.widths(vp)
        for fy in (0.5, 0.2, 0.8, 0.1, 0.9), fx in (0.5, 0.2, 0.8, 0.1, 0.9)
            _events(gui).mouseposition[] = (Float64(o[1] + fx * w[1]), Float64(o[2] + fy * w[2]))
            gui.controls.ignore_mouse() || return nothing
        end
        error("the 3D view has no free pixel")
    end

    # A click in the 3D view on `obj` (`nothing`: beside the components)
    function _click!(f, obj)
        f.target[] = obj
        _into_view!(f.gui)
        _press!(f.gui)
        _release!(f.gui)
        return nothing
    end

    # The card of the selection: floating (compact) or in the inspector (app)
    _card(gui::GUI.LiveView{GUI.AppLayout}) = gui.layout.inspector.card
    _card(gui) = gui.cards.selection
    _w(gui, name) = GUI._card_widget(_card(gui), name)
    _text(gui, name) = _w(gui, name).text[]
    _push!(gui, name) = (_w(gui, name).clicks[] += 1; nothing)
    _handles(gui, obj) = count(oh -> rendered(oh) === obj, render_children(gui.controls.h))
    _alpha(gui, obj) = first(render_plots(GUI._child_handle(gui.controls.h, obj))).alpha[]
    _picks(gui, sys, add) = (p = GUI._member_pick(gui); !isnothing(p) && p.sys === sys && p.add == add)
    _target(beam) = (i = BMO.intersection(first(BMO.rays(beam))); isnothing(i) ? nothing : BMO.object(i))

    @testset "+ and − with clicks, $layout" for layout in (:compact, :app)
        f = _fixture(layout)
        gui = f.gui
        @test isnothing(GUI._member_pick(gui))

        # "+" of the transmitter: its card is shown, everything else is see-through
        GUI._set_member_pick!(gui, f.tx, true)
        @test _picks(gui, f.tx, true)
        @test gui.objects.inspected === f.tx && isnothing(gui.controls.selected[])
        @test occursin("+ TX", gui.status.text[]) && occursin("Esc", gui.status.text[])
        help = gui.layout.help
        @test help.picking && help.pick_label.text[] == "+ TX"
        @test GUI._overlay_rect(help.pick) in GUI._help_rects(help)
        a1, a2 = _alpha(gui, f.m1), _alpha(gui, f.m2)
        @test a2 < 1 && a1 == 1
        @test haskey(GUI._pick_dimmed(gui), first(render_plots(GUI._child_handle(gui.controls.h, f.b2))))
        @test !haskey(GUI._pick_dimmed(gui), first(render_plots(GUI._child_handle(gui.controls.h, f.b1))))

        # a click on an object of the other system adds it: one object, two systems, not selected
        _click!(f, f.m2)
        @test f.tx.objects == [f.m1, f.m2] && f.rx.objects == [f.m2]
        @test GUI._member_systems(gui, f.m2) == [f.tx, f.rx] && _handles(gui, f.m2) == 1
        @test isnothing(gui.controls.selected[]) && gui.objects.inspected === f.tx
        @test _picks(gui, f.tx, true)
        @test _alpha(gui, f.m2) == 1
        @test occursin("M2 added to TX", gui.status.text[])

        # a click on a member only shows a message
        _click!(f, f.m2)
        @test f.tx.objects == [f.m1, f.m2]
        @test occursin("already in TX", gui.status.text[])
        @test isnothing(gui.controls.selected[])

        # a click beside the components changes nothing: the card and the pick stay
        _click!(f, nothing)
        @test _picks(gui, f.tx, true) && gui.objects.inspected === f.tx
        @test occursin("+ TX", gui.status.text[])

        # a click on the marker of a source moves the source
        @test GUI._system_of_source(gui, f.b2) === f.rx
        _click!(f, f.b2)
        @test GUI._system_of_source(gui, f.b2) === f.tx
        @test GUI._sources_of(gui, f.tx) == [f.b1, f.b2] && isempty(GUI._sources_of(gui, f.rx))
        _click!(f, f.b2)
        @test occursin("already traced through TX", gui.status.text[])

        # the second press on "+" ends the pick, like Esc below
        GUI._set_member_pick!(gui, f.tx, true)
        @test isnothing(GUI._member_pick(gui)) && !help.picking
        @test isempty(GUI._pick_dimmed(gui))
        @test _alpha(gui, f.m1) == 1 && _alpha(gui, f.m2) == 1
        @test isempty(GUI._help_rects(help)) || !(GUI._overlay_rect(help.pick) in GUI._help_rects(help))
        # without a pick, a click selects as before
        _click!(f, f.m2)
        @test gui.controls.selected[] === f.m2

        # "−" of the receiver: its only object becomes one of the transmitter only
        GUI._set_member_pick!(gui, f.rx, false)
        @test _picks(gui, f.rx, false) && isnothing(gui.controls.selected[])
        @test help.pick_label.text[] == "− RX"
        @test _alpha(gui, f.m1) < 1 && _alpha(gui, f.m2) == 1
        _click!(f, f.m1)
        @test occursin("M1 is not in RX", gui.status.text[])
        _click!(f, f.m2)
        @test isempty(f.rx.objects) && f.tx.objects == [f.m1, f.m2]
        @test !GUI._is_extra(gui, f.m2) && _alpha(gui, f.m2) < 1

        # out of its last system: the object stays in the view without a system
        GUI._set_member_pick!(gui, f.tx, false)
        @test _picks(gui, f.tx, false)
        _click!(f, f.m2)
        @test f.tx.objects == [f.m1] && GUI._is_extra(gui, f.m2) && _handles(gui, f.m2) == 1
        @test occursin("no system", gui.status.text[])
        # a source that is taken out has no system
        _click!(f, f.b2)
        @test isnothing(GUI._system_of_source(gui, f.b2)) && f.b2 in gui.beams.unassigned
        _click!(f, f.b2)
        @test occursin("not traced through TX", gui.status.text[])

        # undo brings the source and the object back
        @test GUI._undo!(gui.controls)
        @test GUI._system_of_source(gui, f.b2) === f.tx
        @test GUI._undo!(gui.controls)
        @test f.tx.objects == [f.m1, f.m2]
        @test _picks(gui, f.tx, false)

        # Esc ends the pick before its other meanings: the card of the system stays
        _key!(gui, Keyboard.escape)
        @test isnothing(GUI._member_pick(gui)) && gui.objects.inspected === f.tx
        @test _alpha(gui, f.m1) == 1 && _alpha(gui, f.m2) == 1
        _key!(gui, Keyboard.escape)
        @test isnothing(gui.objects.inspected)
        close(gui)
    end

    @testset "drags, the menu and what ends the pick, $layout" for layout in (:compact, :app)
        f = _fixture(layout)
        gui = f.gui
        GUI._set_member_pick!(gui, f.tx, true)

        # a drag is left to the camera: the events are passed on by the pick and the controls, and
        # nothing is picked
        seen = Makie.MouseButtonEvent[]
        l = on(e -> (push!(seen, e); Consume(false)), _events(gui).mousebutton; priority = 100)
        eye = copy(cameracontrols(gui.ax.scene).eyeposition[])
        f.target[] = f.m2
        _into_view!(gui)
        p = _events(gui).mouseposition[]
        _press!(gui)
        _events(gui).mouseposition[] = (p[1] + 40, p[2] + 25)
        _release!(gui)
        @test [e.action for e in seen] == [Mouse.press, Mouse.release]
        @test cameracontrols(gui.ax.scene).eyeposition[] != eye
        @test f.tx.objects == [f.m1] && isnothing(gui.controls.selected[]) && _picks(gui, f.tx, true)
        # a click is passed on as well
        empty!(seen)
        _click!(f, f.m2)
        @test [e.action for e in seen] == [Mouse.press, Mouse.release]
        @test f.tx.objects == [f.m1, f.m2]
        off(l)

        # the component menu and the object tree select via `_select!`: picked instead
        GUI._set_member_pick!(gui, f.rx, true)
        @test _picks(gui, f.rx, true) && gui.objects.inspected === f.rx
        GUI._select!(gui, f.m1)
        @test f.rx.objects == [f.m2, f.m1] && isnothing(gui.controls.selected[])
        @test gui.objects.inspected === f.rx && _picks(gui, f.rx, true)
        GUI._select!(gui, f.b1)
        @test GUI._system_of_source(gui, f.b1) === f.rx
        GUI._inspect!(gui, f.b1)
        @test occursin("already traced", gui.status.text[]) && gui.objects.inspected === f.rx
        # its own system is inspected as usual, another one ends the pick
        GUI._select!(gui, GUI._system_handle(gui, f.rx))
        @test _picks(gui, f.rx, true)
        GUI._select!(gui, GUI._system_handle(gui, f.tx))
        @test isnothing(GUI._member_pick(gui)) && gui.objects.inspected === f.tx
        @test isempty(GUI._pick_dimmed(gui))

        # the spectator mode ends it, and none starts there
        GUI._set_member_pick!(gui, f.tx, false)
        GUI._set_spectator!(gui.controls, true)
        @test isnothing(GUI._member_pick(gui))
        GUI._set_member_pick!(gui, f.tx, false)
        @test isnothing(GUI._member_pick(gui)) && occursin("spectator", gui.status.text[])
        GUI._set_spectator!(gui.controls, false)

        # removing the system ends it
        GUI._set_member_pick!(gui, f.rx, false)
        @test _picks(gui, f.rx, false)
        remove_system!(gui, f.rx)
        @test isnothing(GUI._member_pick(gui)) && isempty(GUI._pick_dimmed(gui))
        @test !gui.layout.help.picking

        # a new component is see-through while another system is picked
        sys = add_system!(gui)
        GUI._set_member_pick!(gui, sys, true)
        m3 = _mirror(0.3)
        add_component!(gui, m3; system = f.tx, select = false)
        _tick!(gui)
        @test _alpha(gui, m3) < 1
        _click!(f, m3)
        @test sys.objects == [m3] && _alpha(gui, m3) == 1
        _key!(gui, Keyboard.escape)
        close(gui)
    end

    @testset "the card of a system, $layout" for layout in (:compact, :app)
        f = _fixture(layout; auto_trace = false)
        gui = f.gui
        GUI._inspect!(gui, f.tx)
        # the rows of the system widget; "remove" is in its last row, not in the head
        @test [w.name for w in card_actions(f.tx)] == [:hide, :open]
        @test length(card_rows(f.tx)) == 3
        for name in (:system_name, :auto_trace, :trace, :trace_state, :member_add, :member_remove,
                :objects, :rays, :solve, :remove)
            @test !isnothing(_w(gui, name))
        end
        # the members: the sources, then the objects
        @test GUI._members(gui, f.tx) == [f.b1, f.m1]
        @test _text(gui, :member_1) == "Beam 1" && _text(gui, :member_2) == "M1"
        @test isnothing(_w(gui, :member_3)) && isnothing(_w(gui, :member_more))

        # "+" and "−" start and end the pick and are shown pressed
        accent = Makie.to_color(gui.layout.theme.accent)
        _push!(gui, :member_add)
        @test _picks(gui, f.tx, true)
        @test _w(gui, :member_add).labelcolor[] == accent && _w(gui, :member_remove).labelcolor[] != accent
        @test _text(gui, :member_hint) == "click to add"
        _push!(gui, :member_remove)
        @test _picks(gui, f.tx, false)
        @test _w(gui, :member_remove).labelcolor[] == accent && _w(gui, :member_add).labelcolor[] != accent
        @test _text(gui, :member_hint) == "click to take out"
        _push!(gui, :member_remove)
        @test isnothing(GUI._member_pick(gui)) && _w(gui, :member_remove).labelcolor[] != accent
        @test strip(_text(gui, :member_hint)) == ""

        # the list follows a pick
        _push!(gui, :member_add)
        _click!(f, f.m2)
        @test _text(gui, :member_3) == "M2" && !isnothing(_w(gui, :member_out_3))
        _key!(gui, Keyboard.escape)
        # ... and changes from elsewhere, with the next frame
        remove_component!(gui, f.m2; system = f.tx)
        _tick!(gui)
        @test isnothing(_w(gui, :member_3)) && _text(gui, :member_2) == "M1"
        add_component!(gui, f.m2; system = f.tx, select = false)
        _tick!(gui)
        @test _text(gui, :member_3) == "M2"
        @test gui.objects.inspected === f.tx

        # "−" of a member takes it out: an object stays in its other system, a source has none
        _push!(gui, :member_out_3)
        @test f.tx.objects == [f.m1] && f.rx.objects == [f.m2] && isnothing(_w(gui, :member_3))
        _push!(gui, :member_out_1)
        @test isnothing(GUI._system_of_source(gui, f.b1)) && _text(gui, :member_1) == "M1"
        @test isnothing(_w(gui, :member_2))
        _push!(gui, :member_out_1)
        @test isempty(f.tx.objects) && GUI._is_extra(gui, f.m1) && isnothing(_w(gui, :member_1))
        @test GUI._undo!(gui.controls) && GUI._undo!(gui.controls)
        _tick!(gui)
        @test GUI._members(gui, f.tx) == [f.b1, f.m1] && _text(gui, :member_2) == "M1"

        # auto tracing of the system and "Trace"
        gui.trace.auto[] = true
        GUI._update_inspector!(gui)
        @test _w(gui, :auto_trace).active[]
        _w(gui, :auto_trace).active[] = false
        @test !GUI._system_auto(gui, f.tx) && GUI._system_auto(gui, f.rx)
        _w(gui, :auto_trace).active[] = true
        @test GUI._system_auto(gui, f.tx)
        gui.trace.auto[] = false
        translate3d!(gui, f.m1, [0, 0.01, 0])
        GUI._update_inspector!(gui)
        @test GUI._system_stale(gui, f.tx) && _text(gui, :trace_state) == "outdated"
        _push!(gui, :trace)
        @test !GUI._system_stale(gui, f.tx) && strip(_text(gui, :trace_state)) == ""
        @test _target(f.b1) === f.m1

        # the name
        _w(gui, :system_name).stored_string[] = "Transmitter"
        @test GUI._label(gui, f.tx) == "Transmitter" && gui.labels[f.tx] == "Transmitter"
        @test GUI._label(gui, GUI._system_handle(gui, f.tx)) == "Transmitter"
        @test occursin("renamed to Transmitter", gui.status.text[])
        if !isnothing(gui.widgets.menu)
            @test "Transmitter" in first.(gui.widgets.menu.options[])
        end
        _w(gui, :system_name).stored_string[] = "  "
        @test GUI._label(gui, f.tx) == "Transmitter" && occursin("enter a name", gui.status.text[])
        # the chip of a pick follows the name
        _push!(gui, :member_add)
        _w(gui, :system_name).stored_string[] = "TX2"
        @test gui.layout.help.pick_label.text[] == "+ TX2"
        _key!(gui, Keyboard.escape)

        # "remove": its components stay in the view, the last system is kept
        _push!(gui, :remove)
        @test GUI._systems(gui) == [f.rx] && GUI._is_extra(gui, f.m1)
        @test isnothing(GUI._system_of_source(gui, f.b1))
        @test gui.objects.inspected !== f.tx
        GUI._inspect!(gui, f.rx)
        _push!(gui, :remove)
        @test GUI._systems(gui) == [f.rx] && occursin("last system", gui.status.text[])
        close(gui)
    end

    @testset "a long list of members, $layout" for layout in (:compact, :app)
        ms = [_mirror(0.05 * i) for i in 1:(GUI._MEMBER_ROWS + 2)]
        sys = System(ms)
        gui = live_view(sys, _beam(); layout, trace_budget = Inf, throttle = false, detectors = [])
        GUI._inspect!(gui, sys)
        # the source and the first objects, then the rest as a number
        @test !isnothing(_w(gui, GUI._member_label(GUI._MEMBER_ROWS)))
        @test isnothing(_w(gui, GUI._member_label(GUI._MEMBER_ROWS + 1)))
        @test _text(gui, :member_more) == "… 3 more"
        remove_component!(gui, ms[end])
        _tick!(gui)
        @test _text(gui, :member_more) == "… 2 more"
        remove_component!(gui, ms[end - 1])
        remove_component!(gui, ms[end - 2])
        _tick!(gui)
        @test isnothing(_w(gui, :member_more))
        @test !isnothing(_w(gui, GUI._member_label(GUI._MEMBER_ROWS)))
        close(gui)
    end

    @testset "a StaticSystem, $layout" for layout in (:compact, :app)
        m1, m2 = _mirror(0.1), _mirror(0.2)
        static, sys = StaticSystem([m1]), System([m2])
        b1, b2 = _beam(), _beam(0.05)
        target = Ref{Any}(nothing)
        gui_ref = Ref{Any}(nothing)
        pick(ax) = isnothing(target[]) ? (nothing, 0) :
                   (first(render_plots(GUI._child_handle(gui_ref[].controls.h, target[]))), 0)
        gui = live_view(static => b1, sys => b2; layout, pick, trace_budget = Inf, throttle = false,
            detectors = [])
        gui_ref[] = gui
        f = (; gui, target)
        GUI._inspect!(gui, static)
        # its objects can not be changed: no "−" in their rows, but in those of its sources
        @test GUI._members(gui, static) == [b1, m1]
        @test !isnothing(_w(gui, :member_out_1)) && isnothing(_w(gui, :member_out_2))
        @test !isnothing(_w(gui, :member_2)) && !isnothing(_w(gui, :member_add))
        # sources are moved to it with "+", objects are not
        _push!(gui, :member_add)
        @test _picks(gui, static, true)
        _click!(f, m2)
        @test length(static.objects) == 1 && occursin("can not be changed", gui.status.text[])
        _click!(f, b2)
        @test GUI._system_of_source(gui, b2) === static
        @test GUI._members(gui, static) == [b1, b2, m1]
        @test !isnothing(_w(gui, :member_out_2)) && isnothing(_w(gui, :member_out_3))
        _key!(gui, Keyboard.escape)
        _push!(gui, :member_out_2)
        @test isnothing(GUI._system_of_source(gui, b2)) && isnothing(_w(gui, :member_3))
        # "+" of the other system takes the object of the static one as well, which is not movable
        GUI._set_member_pick!(gui, sys, true)
        _click!(f, m1)
        @test sys.objects == [m2, m1] && GUI._member_systems(gui, m1) == [static, sys]
        _key!(gui, Keyboard.escape)
        @test isnothing(GUI._member_pick(gui))
        close(gui)
    end
end

end
