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
        @test haskey(GUI._system_dimmed(gui), first(render_plots(GUI._child_handle(gui.controls.h, f.b2))))
        @test !haskey(GUI._system_dimmed(gui), first(render_plots(GUI._child_handle(gui.controls.h, f.b1))))

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
        @test isempty(GUI._system_dimmed(gui))
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
        # the members of the inspected system stay highlighted: the source of the receiver is none
        @test _alpha(gui, f.m1) == 1 && _alpha(gui, f.m2) == 1
        @test haskey(GUI._system_dimmed(gui), first(render_plots(GUI._child_handle(gui.controls.h, f.b1))))

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
        @test isnothing(GUI._member_pick(gui)) && isempty(GUI._system_dimmed(gui))
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

    @testset "the members of an inspected system, $layout" for layout in (:compact, :app)
        f = _fixture(layout)
        gui = f.gui
        plot(x) = first(render_plots(GUI._child_handle(gui.controls.h, x)))
        dimmed() = GUI._system_dimmed(gui)
        @test isempty(dimmed())
        # A click on the empty space of the 3D view: on no component and on no beam, which would
        # be inspected and keep the cards
        function _click_empty!()
            f.target[] = nothing
            vp = gui.ax.scene.viewport[]
            o, w = minimum(vp), Makie.widths(vp)
            for fy in (0.3, 0.7, 0.2, 0.8), fx in (0.3, 0.7, 0.2, 0.8)
                _events(gui).mouseposition[] = (Float64(o[1] + fx * w[1]), Float64(o[2] + fy * w[2]))
                (gui.controls.ignore_mouse() || !isnothing(GUI._inspect_beam(gui))) && continue
                _press!(gui)
                _release!(gui)
                return nothing
            end
            error("the 3D view has no empty pixel")
        end

        # a system is inspected, e.g. by its row of the object tree: everything else is see-through
        GUI._select!(gui, GUI._system_handle(gui, f.tx))
        @test gui.objects.inspected === f.tx
        @test _alpha(gui, f.m1) == 1 && _alpha(gui, f.m2) ≈ GUI._SYSTEM_OPACITY
        @test haskey(dimmed(), plot(f.b2)) && !haskey(dimmed(), plot(f.b1))
        # another system
        GUI._select!(gui, GUI._system_handle(gui, f.rx))
        @test _alpha(gui, f.m2) == 1 && _alpha(gui, f.m1) ≈ GUI._SYSTEM_OPACITY
        @test haskey(dimmed(), plot(f.b1)) && !haskey(dimmed(), plot(f.b2))

        # a pick of its members dims more, and less again when it ends
        GUI._set_member_pick!(gui, f.rx, true)
        @test _alpha(gui, f.m1) ≈ GUI._PICK_OPACITY
        _key!(gui, Keyboard.escape)
        @test isnothing(GUI._member_pick(gui)) && gui.objects.inspected === f.rx
        @test _alpha(gui, f.m1) ≈ GUI._SYSTEM_OPACITY && _alpha(gui, f.m2) == 1

        # a component that becomes a member meanwhile, and one that is none any more
        add_component!(gui, f.m1; system = f.rx, select = false)
        _tick!(gui)
        @test gui.objects.inspected === f.rx && _alpha(gui, f.m1) == 1
        remove_component!(gui, f.m1; system = f.rx)
        _tick!(gui)
        @test _alpha(gui, f.m1) ≈ GUI._SYSTEM_OPACITY

        # a click on the empty space of the 3D view ends the inspection: everything as it was
        _click_empty!()
        @test isnothing(gui.objects.inspected) && isempty(dimmed())
        @test _alpha(gui, f.m1) == 1 && _alpha(gui, f.m2) == 1

        # a selected component ends it as well, and so does Esc
        GUI._select!(gui, GUI._system_handle(gui, f.tx))
        @test _alpha(gui, f.m2) ≈ GUI._SYSTEM_OPACITY
        select!(gui, f.m2)
        @test isempty(dimmed()) && _alpha(gui, f.m2) == 1
        GUI._select!(gui, GUI._system_handle(gui, f.tx))
        @test !isempty(dimmed())
        _key!(gui, Keyboard.escape)
        @test isnothing(gui.objects.inspected) && isempty(dimmed())

        # the spectator mode shows the view as it is
        GUI._select!(gui, GUI._system_handle(gui, f.tx))
        GUI._set_spectator!(gui.controls, true)
        @test isempty(dimmed()) && _alpha(gui, f.m2) == 1
        GUI._set_spectator!(gui.controls, false)
        @test (gui.objects.inspected === f.tx) == !isempty(dimmed())
        close(gui)
    end

    # The line below the name of the card, whether it has a page bar and shows the step and the mode
    _subtitle(gui::GUI.LiveView{GUI.AppLayout}) = gui.layout.inspector.type.text[]
    _subtitle(gui) = (c = gui.cards.selection; c.subtitle_shown ? c.subtitle.text[] : nothing)
    _has_bar(c::GUI._DockedCard) = c.bar_part.shown
    _has_bar(c::GUI._ComponentCard) = !isnothing(c.bar)
    _has_step(c::GUI._DockedCard) = c.step_part.shown
    _has_step(c::GUI._ComponentCard) = c.step_shown
    _chip(gui, name) = _w(gui, name).label.text[]
    # The names of the list of the members, and an input of the list: a click on a row or on its "×"
    _listed(gui) = [row.name.text[] for row in _w(gui, :members).rows]
    _member!(gui, kind, i) = (_w(gui, :members).event[] = (kind, i); nothing)

    @testset "the card of a system, $layout" for layout in (:compact, :app)
        f = _fixture(layout; auto_trace = false)
        gui = f.gui
        GUI._inspect!(gui, f.tx)
        c = _card(gui)
        # the head: the eye and the window of its own, as icons; the pin is the one of every card
        @test [w.name for w in card_actions(f.tx)] == [:hide, :open]
        @test isempty(card_rows(f.tx))
        @test _w(gui, :hide) isa GUI._IconToggle && _w(gui, :open) isa GUI._IconButton
        @test _w(gui, :open).icon[] === GUI._icon(:window) && GUI._icon(:window) !== GUI._icon(:float)
        @test _w(gui, :open).tooltip[] == "Open in a window of its own"
        @test _subtitle(gui) == "System · 1 object · 1 source"
        # one page: no page bar, and neither the step nor the mode
        @test GUI._card_pages(gui, f.tx) == (:pose,)
        @test !_has_bar(c) && !_has_step(c)
        @test !any(b -> b isa Button && b.label[] in ("hide", "show", "new window", "remove"), c.blocks)
        for name in (:trace_state, :auto_trace, :trace, :member_count, :member_add, :member_remove,
                :members, :rays, :remove)
            @test !isnothing(_w(gui, name))
        end
        @test isnothing(_w(gui, :system_name)) && isnothing(_w(gui, :member_hint))
        # the members: the sources, then the objects, each with the icon of its kind
        list = _w(gui, :members)
        @test list isa GUI._MemberList && list.outs == 2 && isnothing(list.more)
        @test GUI._members(gui, f.tx) == [f.b1, f.m1]
        @test _listed(gui) == ["Beam 1", "M1"] && _chip(gui, :member_count) == "2"
        @test list.rows[1].icon[] === GUI._icon(:source) && list.rows[2].icon[] === GUI._icon(:mirror)
        @test !list.rows[2].badge_shown[]
        @test _w(gui, :rays).text[] == "1 ray per solve"

        # "+" and "−" start and end the pick and are shown pressed, with what a click does below
        accent = Makie.to_color(gui.layout.theme.accent)
        _push!(gui, :member_add)
        @test _picks(gui, f.tx, true)
        @test _w(gui, :member_add).labelcolor[] == accent && _w(gui, :member_remove).labelcolor[] != accent
        @test occursin("to add it", _chip(gui, :member_hint)) && occursin("Esc", _chip(gui, :member_hint))
        _push!(gui, :member_remove)
        @test _picks(gui, f.tx, false)
        @test _w(gui, :member_remove).labelcolor[] == accent && _w(gui, :member_add).labelcolor[] != accent
        @test occursin("take it out", _chip(gui, :member_hint))
        _push!(gui, :member_remove)
        @test isnothing(GUI._member_pick(gui)) && _w(gui, :member_remove).labelcolor[] != accent
        @test isnothing(_w(gui, :member_hint))

        # the list follows a pick: an object of two systems shows their number
        _push!(gui, :member_add)
        _click!(f, f.m2)
        @test _listed(gui) == ["Beam 1", "M1", "M2"] && !isnothing(_w(gui, :members).rows[3].out)
        @test _w(gui, :members).rows[3].badge.text[] == "2" && _w(gui, :members).rows[3].badge_shown[]
        @test _chip(gui, :member_count) == "3" && _subtitle(gui) == "System · 2 objects · 1 source"
        _key!(gui, Keyboard.escape)
        # ... and changes from elsewhere, with the next frame
        remove_component!(gui, f.m2; system = f.tx)
        _tick!(gui)
        @test _listed(gui) == ["Beam 1", "M1"]
        add_component!(gui, f.m2; system = f.tx, select = false)
        _tick!(gui)
        @test _listed(gui) == ["Beam 1", "M1", "M2"]
        @test gui.objects.inspected === f.tx

        # "×" of a member takes it out: an object stays in its other system, a source has none
        _member!(gui, :out, 3)
        @test f.tx.objects == [f.m1] && f.rx.objects == [f.m2] && _listed(gui) == ["Beam 1", "M1"]
        @test gui.objects.inspected === f.tx && isnothing(gui.controls.selected[])
        _member!(gui, :out, 1)
        @test isnothing(GUI._system_of_source(gui, f.b1)) && _listed(gui) == ["M1"]
        @test _chip(gui, :trace_state) == "no source"
        _member!(gui, :out, 1)
        @test isempty(f.tx.objects) && GUI._is_extra(gui, f.m1)
        # an empty system says how it gets members
        @test isempty(_w(gui, :members).rows) && _chip(gui, :member_count) == "0"
        @test _subtitle(gui) == "System · empty"
        @test any(b -> b isa Label && b.text[] == GUI._MEMBERS_EMPTY, GUI._blocks!(Any[], _w(gui, :members).grid))
        @test GUI._undo!(gui.controls) && GUI._undo!(gui.controls)
        _tick!(gui)
        @test GUI._members(gui, f.tx) == [f.b1, f.m1] && _listed(gui) == ["Beam 1", "M1"]

        # auto tracing of the system and "Trace", which is filled while the system is outdated
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
        @test GUI._system_stale(gui, f.tx) && _chip(gui, :trace_state) == "● outdated"
        @test _w(gui, :trace).buttoncolor[] == accent
        @test _w(gui, :trace_state).box.color[] == GUI._rgba(gui.layout.theme.stale_soft)
        _push!(gui, :trace)
        @test !GUI._system_stale(gui, f.tx) && startswith(_chip(gui, :trace_state), "● up to date")
        @test occursin("ms", _chip(gui, :trace_state))
        @test _w(gui, :trace).buttoncolor[] != accent
        @test _w(gui, :trace_state).box.color[] == GUI._rgba(gui.layout.theme.ok_soft)
        @test _target(f.b1) === f.m1

        # "Remove system": its components stay in the view, the last system is kept
        @test _w(gui, :remove) isa GUI._IconButton && _w(gui, :remove).icon[] === GUI._icon(:trash)
        @test occursin("members stay in the view", _w(gui, :remove).tooltip[])
        _push!(gui, :remove)
        @test GUI._systems(gui) == [f.rx] && GUI._is_extra(gui, f.m1)
        @test isnothing(GUI._system_of_source(gui, f.b1))
        @test gui.objects.inspected !== f.tx
        GUI._inspect!(gui, f.rx)
        _push!(gui, :remove)
        @test GUI._systems(gui) == [f.rx] && occursin("last system", gui.status.text[])
        close(gui)
    end

    @testset "renaming a system in the title, $layout" for layout in (:compact, :app)
        f = _fixture(layout; auto_trace = false)
        gui = f.gui
        GUI._inspect!(gui, f.tx)
        e = _card(gui).name
        @test e.renamable && !e.editing && !GUI._typing(gui)
        solved = gui.trace.solve_time

        # the pencil: a textbox with the name instead of the title, which takes the keyboard
        e.pencil.clicks[] += 1
        @test e.editing && e.box.focused[] && e.box.displayed_string[] == "TX"
        @test GUI._typing(gui) && occursin("Enter renames", _subtitle(gui))
        # typing "t" does not trace
        _events(gui).unicode_input[] = 't'
        _key!(gui, Keyboard.t)
        @test gui.trace.solve_time == solved && GUI._system_stale(gui, f.tx)
        # Enter renames
        e.box.displayed_string[] = "Transmitter"
        _key!(gui, Keyboard.enter)
        @test !e.editing && !e.box.focused[] && !GUI._typing(gui)
        @test GUI._label(gui, f.tx) == "Transmitter" && gui.labels[f.tx] == "Transmitter"
        @test GUI._label(gui, GUI._system_handle(gui, f.tx)) == "Transmitter"
        @test e.title.text[] == "Transmitter" && _subtitle(gui) == "System · 1 object · 1 source"
        @test occursin("renamed to Transmitter", gui.status.text[])
        if !isnothing(gui.widgets.menu)
            @test "Transmitter" in first.(gui.widgets.menu.options[])
        end
        @test gui.objects.inspected === f.tx

        # Esc keeps the name, and the card
        e.pencil.clicks[] += 1
        e.box.displayed_string[] = "Other"
        _key!(gui, Keyboard.escape)
        @test !e.editing && GUI._label(gui, f.tx) == "Transmitter" && gui.objects.inspected === f.tx
        # a lost focus keeps it as well
        e.pencil.clicks[] += 1
        e.box.displayed_string[] = "Other"
        Makie.defocus!(e.box)
        @test !e.editing && GUI._label(gui, f.tx) == "Transmitter" && e.title.text[] == "Transmitter"
        # an empty name only shows a message
        e.pencil.clicks[] += 1
        e.box.displayed_string[] = "  "
        _key!(gui, Keyboard.enter)
        @test !e.editing && GUI._label(gui, f.tx) == "Transmitter"
        @test occursin("enter a name", gui.status.text[])

        # the chip of a pick follows the name
        GUI._set_member_pick!(gui, f.tx, true)
        e.pencil.clicks[] += 1
        e.box.displayed_string[] = "TX2"
        _key!(gui, Keyboard.enter)
        @test gui.layout.help.pick_label.text[] == "+ TX2"
        _key!(gui, Keyboard.escape)
        # another object of the card ends the editing
        e.pencil.clicks[] += 1
        @test e.editing
        select!(gui, f.m1)
        @test !e.editing && !GUI._typing(gui) && GUI._label(gui, f.tx) == "TX2"
        close(gui)
    end

    @testset "renaming a component and a source in the title, $layout" for layout in (:compact, :app)
        f = _fixture(layout)
        gui = f.gui
        for (obj, old, new) in ((f.m1, "M1", "Fold mirror"), (f.b1, "Beam 1", "Laser"))
            GUI._select!(gui, obj)
            e = _card(gui).name
            @test e.renamable && !e.editing && e.title.text[] == old
            e.pencil.clicks[] += 1
            @test e.editing && e.box.focused[] && e.box.displayed_string[] == old
            @test occursin("Enter renames", _subtitle(gui))
            e.box.displayed_string[] = new
            _key!(gui, Keyboard.enter)
            @test !e.editing && !GUI._typing(gui)
            @test GUI._label(gui, obj) == new && gui.labels[obj] == new && e.title.text[] == new
            @test occursin("$old renamed to $new", gui.status.text[])
            @test GUI._shown_object(gui) === obj
            if !isnothing(gui.widgets.menu)
                # the entries of the members of a system are indented
                @test new in strip.(first.(gui.widgets.menu.options[]))
            end
            # Esc keeps the name, an empty name only shows a message
            e.pencil.clicks[] += 1
            e.box.displayed_string[] = "Other"
            _key!(gui, Keyboard.escape)
            @test !e.editing && GUI._label(gui, obj) == new
            e.pencil.clicks[] += 1
            e.box.displayed_string[] = " "
            _key!(gui, Keyboard.enter)
            @test GUI._label(gui, obj) == new && occursin("enter a name", gui.status.text[])
        end
        # the names are those of the tree, of the members of a system and of the exported code
        if layout === :app
            @test "Fold mirror" in [r.label for r in gui.layout.tree.rows]
            @test "Laser" in [r.label for r in gui.layout.tree.rows]
        end
        @test occursin("Fold mirror", export_script(gui; io = devnull))
        close(gui)
    end

    @testset "the icons of a floating card are next to its tools" begin
        f = _fixture(:compact)
        gui = f.gui
        GUI._select!(gui, f.m1)
        _tick!(gui)
        c = gui.cards.selection
        rect(x) = GUI._part_rect(x)
        actions, tools = rect(c.actions), rect(c.tools)
        # right of the head, and their right edge at the tools, also on a card whose rows are wider
        @test minimum(actions)[1] >= maximum(rect(c.head))[1]
        @test maximum(actions)[1] ≈ minimum(tools)[1] - GUI._CARD_PADDING
        @test minimum(actions)[1] - maximum(rect(c.head))[1] > 2 * GUI._CARD_PADDING
        close(gui)
    end

    @testset "the eye of a card, $layout" for layout in (:compact, :app)
        f = _fixture(layout)
        gui = f.gui
        show!(obj) = obj isa System ? GUI._inspect!(gui, obj) : GUI._select!(gui, obj)
        # a component, a source and a system
        for obj in (f.m1, f.b1, f.tx)
            show!(obj)
            @test GUI._shown_object(gui) === obj
            eye = _w(gui, :hide)
            @test eye isa GUI._IconToggle && first(card_actions(obj)).name === :hide
            @test !eye.active[] && eye.icon[] === GUI._icon(:eye) && eye.tooltip[] == "Hide"
            # no text button "hide" or "show" on the card
            @test !any(b -> b isa Button && b.label[] in ("hide", "show"), _card(gui).blocks)
            # a click hides the object
            eye.active[] = true
            @test GUI._all_hidden(gui, obj)
            # hidden, and shown on its card again: the eye is crossed out
            show!(obj)
            eye = _w(gui, :hide)
            @test eye.active[] && eye.icon[] === GUI._icon(:eye_off) && eye.tooltip[] == "Show"
            eye.active[] = false
            @test !GUI._all_hidden(gui, obj)
            @test !_w(gui, :hide).active[] && _w(gui, :hide).icon[] === GUI._icon(:eye)
            # the eye follows what hides the object from elsewhere, e.g. the eye of the object tree
            if obj isa System
                GUI._toggle_hidden!(gui, obj)
                @test _w(gui, :hide).active[] && _w(gui, :hide).tooltip[] == "Show"
                GUI._toggle_hidden!(gui, obj)
                @test !_w(gui, :hide).active[] && _w(gui, :hide).tooltip[] == "Hide"
            end
        end
        close(gui)
    end

    @testset "a click on a row of the members, $layout" for layout in (:compact, :app)
        f = _fixture(layout)
        gui = f.gui
        GUI._inspect!(gui, f.tx)
        # a row selects its member like its row of the object tree, which closes the card of the system
        _member!(gui, :select, 2)
        @test gui.controls.selected[] === f.m1 && isnothing(gui.objects.inspected)
        GUI._inspect!(gui, f.tx)
        _member!(gui, :select, 1)
        @test GUI._shown_object(gui) === f.b1
        # "×" does not select
        GUI._inspect!(gui, f.tx)
        add_component!(gui, f.m2; system = f.tx, select = false)
        _tick!(gui)
        _member!(gui, :out, 3)
        @test f.tx.objects == [f.m1] && isnothing(gui.controls.selected[]) && gui.objects.inspected === f.tx

        # while the members of a system are picked, a row is picked instead
        GUI._set_member_pick!(gui, f.tx, false)
        @test _picks(gui, f.tx, false)
        _member!(gui, :select, 2)
        @test isempty(f.tx.objects) && isnothing(gui.controls.selected[]) && _picks(gui, f.tx, false)
        @test gui.objects.inspected === f.tx && _listed(gui) == ["Beam 1"]
        _key!(gui, Keyboard.escape)
        close(gui)
    end

    @testset "the rows of the members under the mouse" begin
        f = _fixture(:compact)
        gui = f.gui
        GUI._inspect!(gui, f.tx)
        _tick!(gui)
        list = _w(gui, :members)
        center(block) = (r = block.layoutobservables.computedbbox[];
            Tuple(Float64.(minimum(r) .+ Makie.widths(r) ./ 2)))
        @test list.hovered[] == 0
        # the row under the mouse has the hover color
        _events(gui).mouseposition[] = center(list.rows[2].name)
        @test list.hovered[] == 2
        _events(gui).mouseposition[] = center(list.rows[1].name)
        @test list.hovered[] == 1
        # a click on "×" takes the member out and does not select it
        _events(gui).mouseposition[] = center(list.rows[2].out.box)
        @test list.rows[2].out.hovered[]
        _press!(gui)
        _release!(gui)
        @test isempty(f.tx.objects) && isnothing(gui.controls.selected[]) && gui.objects.inspected === f.tx
        # a click on a row selects its member
        _tick!(gui)
        list = _w(gui, :members)
        _events(gui).mouseposition[] = center(list.rows[1].name)
        _press!(gui)
        _release!(gui)
        @test GUI._shown_object(gui) === f.b1
        close(gui)
    end

    @testset "a long list of members, $layout" for layout in (:compact, :app)
        ms = [_mirror(0.05 * i) for i in 1:(GUI._MEMBER_ROWS + 2)]
        sys = System(ms)
        gui = live_view(sys, _beam(); layout, trace_budget = Inf, throttle = false, detectors = [])
        GUI._inspect!(gui, sys)
        # the source and the first objects, then the rest as a number
        list = _w(gui, :members)
        @test length(list.rows) == GUI._MEMBER_ROWS && list.more.text[] == "… 3 more"
        @test _chip(gui, :member_count) == string(GUI._MEMBER_ROWS + 3)
        remove_component!(gui, ms[end])
        _tick!(gui)
        @test _w(gui, :members).more.text[] == "… 2 more"
        remove_component!(gui, ms[end - 1])
        remove_component!(gui, ms[end - 2])
        _tick!(gui)
        @test isnothing(_w(gui, :members).more) && length(_w(gui, :members).rows) == GUI._MEMBER_ROWS
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
        outs() = [!isnothing(row.out) for row in _w(gui, :members).rows]
        # its objects can not be changed: no "×" in their rows, but in those of its sources
        @test GUI._members(gui, static) == [b1, m1]
        @test outs() == [true, false] && !isnothing(_w(gui, :member_add))
        # sources are moved to it with "+", objects are not
        _push!(gui, :member_add)
        @test _picks(gui, static, true)
        _click!(f, m2)
        @test length(static.objects) == 1 && occursin("can not be changed", gui.status.text[])
        _click!(f, b2)
        @test GUI._system_of_source(gui, b2) === static
        @test GUI._members(gui, static) == [b1, b2, m1]
        @test outs() == [true, true, false]
        _key!(gui, Keyboard.escape)
        _member!(gui, :out, 2)
        @test isnothing(GUI._system_of_source(gui, b2)) && length(_w(gui, :members).rows) == 2
        # "+" of the other system takes the object of the static one as well, which is not movable
        GUI._set_member_pick!(gui, sys, true)
        _click!(f, m1)
        @test sys.objects == [m2, m1] && GUI._member_systems(gui, m1) == [static, sys]
        _key!(gui, Keyboard.escape)
        @test isnothing(GUI._member_pick(gui))
        close(gui)
    end

    @testset "the rows of the system widget" begin
        # the rows of a method of `card_rows` for an own system type come between the list of the
        # members and the line above the last row
        f = _fixture(:compact)
        declared = GUI._system_rows(f.gui, f.tx)
        named = [w.name for r in declared for w in GUI._declared_widgets(r) if !isnothing(w.name)]
        @test named == [:trace_state, :auto_trace, :trace, :member_count, :member_add, :member_remove,
            :members, :rays, :remove]
        i = findfirst(r -> any(w -> w.name === :members, GUI._declared_widgets(r)), declared)
        @test length(declared) == i + length(card_rows(f.tx)) + 2
        close(f.gui)
    end

    @testset "the colors of the chips, $theme" for theme in (:light, :dark)
        t = GUI._app_theme(theme)
        lin(c) = c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055)^2.4
        lum(c) = (x = GUI._rgba(c); 0.2126 * lin(x.r) + 0.7152 * lin(x.g) + 0.0722 * lin(x.b))
        contrast(a, b) = (la = lum(a); lb = lum(b); (max(la, lb) + 0.05) / (min(la, lb) + 0.05))
        # the texts of the chips, of the filled button "Trace" and of "Remove system"
        @test contrast(t.ok_text, t.ok_soft) >= 4.5
        @test contrast(t.stale_text, t.stale_soft) >= 4.5
        @test contrast(t.chip_text, t.chip) >= 4.5
        @test contrast(t.on_accent, t.accent) >= 4.5
        @test contrast(t.text, t.accent_soft) >= 4.5
        @test contrast(t.danger, t.sidebar) >= 4.5
    end
end

end
