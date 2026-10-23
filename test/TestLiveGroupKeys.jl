module TestLiveGroupKeys

using GLMakie, BeamletOptics, BeamletOpticsGUI
using Makie
using LinearAlgebra: norm
using Test

const BMO = BeamletOptics
const GUI = BeamletOpticsGUI

# The keys, the zoom key and the card buttons of grouping; `_group!` and `_ungroup!` are tested
# in `TestLiveGroup.jl`, here their outcome on the view
@testset "Keys of grouping" begin

    _live_view(args...; kwargs...) =
        live_view(args...; merge((; trace_budget = Inf, throttle = false, detectors = []), kwargs)...)

    ev(gui) = events(gui.ax.scene)
    _tick!(gui, dt = 1.0) = (ev(gui).tick[] = Makie.Tick(Makie.RegularRenderTick, 0, 0.0, dt))
    # The key that types the letter of `key` in the keyboard layout of this machine, see `_layout_key`
    _typed(key) = first(k for k in Keyboard.Button.(Int(Keyboard.a):Int(Keyboard.z)) if GUI._layout_key(k) == key)
    _key!(gui, key) = (ev(gui).keyboardbutton[] = Makie.KeyEvent(key, Keyboard.press))
    function _chord!(gui, key, mods...)
        state = ev(gui).keyboardstate
        foreach(m -> push!(state, m), mods)
        _key!(gui, _typed(key))
        foreach(m -> delete!(state, m), mods)
        return nothing
    end
    _ctrl!(gui, key) = _chord!(gui, key, Keyboard.left_control)
    _ctrl_shift!(gui, key) = _chord!(gui, key, Keyboard.left_control, Keyboard.left_shift)
    _w(gui, name) = GUI._card_widget(gui.layout.inspector.card, name)
    _in(obj, list) = any(o -> o === obj, list)
    _view(gui) = GUI._current_view(gui)

    function _fixture(layout)
        a = SphericalLens(0.05, -0.05, 5e-3, 25.4e-3)
        translate3d!(a, [0.0, 0.05, 0])
        b = RoundPlanoMirror(25e-3, 5e-3)
        translate3d!(b, [0.04, 0.1, 0])
        c = Detector(5e-3)
        translate3d!(c, [0.1, 0.1, 0])
        sys = System([a, b, c])
        gui = _live_view(sys => Beam([0.0, 0, 0], [0.0, 1, 0], 632.8e-9); layout)
        return gui, sys, a, b, c
    end

    @testset "Ctrl+G and Ctrl+Shift+G, $layout" for layout in (:compact, :app)
        gui, sys, a, b, c = _fixture(layout)
        @test GUI._GROUP_HELP[1] in gui.controls.help_extra
        n_history = length(gui.controls.undo_stack)

        # nothing, or one object, selected: the status line says what to do, nothing changes
        _ctrl!(gui, Keyboard.g)
        @test gui.status.text[] == "select several objects to group them"
        select!(gui, a)
        _ctrl!(gui, Keyboard.g)
        @test gui.status.text[] == "select several objects to group them"
        _ctrl_shift!(gui, Keyboard.g)
        @test gui.status.text[] == "select a group made in the window to ungroup it"
        @test length(sys.objects) == 3 && length(gui.controls.undo_stack) == n_history

        # Ctrl+G groups the selection of several
        select!(gui, [a, b])
        _ctrl!(gui, Keyboard.g)
        g = gui.controls.selected[]
        @test g isa BMO.ObjectGroup && GUI._is_window_group(gui, g)
        @test length(sys.objects) == 2 && _in(g, sys.objects) && !_in(a, sys.objects)
        @test length(gui.controls.undo_stack) == n_history + 1

        # its card has "ungroup" and no "group"
        GUI._update_inspector!(gui; force = true)
        if layout == :app
            @test _w(gui, :ungroup) isa Button && _w(gui, :ungroup).blockscene.visible[]
            @test isnothing(_w(gui, :group))
        end

        # Ctrl+G with a group selected does not group again
        _ctrl!(gui, Keyboard.g)
        @test gui.status.text[] == "select several objects to group them"
        @test length(gui.controls.undo_stack) == n_history + 1

        # Ctrl+Shift+G ungroups: the members are top-level again and selected as several
        _ctrl_shift!(gui, Keyboard.g)
        @test length(sys.objects) == 3 && _in(a, sys.objects) && _in(b, sys.objects) && !_in(g, sys.objects)
        sel = gui.controls.selected[]
        @test GUI._is_multi(sel) && _in(a, sel.objects) && _in(b, sel.objects)
        @test !GUI._is_window_group(gui, g)
        @test length(gui.controls.undo_stack) == n_history + 2
    end

    @testset "the group of a script is not ungrouped" begin
        a = SphericalLens(0.05, -0.05, 5e-3, 25.4e-3)
        b = RoundPlanoMirror(25e-3, 5e-3)
        translate3d!(b, [0.04, 0.1, 0])
        g = ObjectGroup([a, b])
        gui = _live_view(System([g]) => Beam([0.0, 0, 0], [0.0, 1, 0], 632.8e-9))
        select!(gui, g)
        n_history = length(gui.controls.undo_stack)
        _ctrl_shift!(gui, Keyboard.g)
        @test gui.status.text[] == "select a group made in the window to ungroup it"
        @test gui.controls.selected[] === g && length(gui.controls.undo_stack) == n_history
        # its card has the button, which is hidden
        @test [w.name for w in card_actions(g)] == [:hide, :ungroup]
        @test !GUI._ungroup_button().value(gui, g).shown
    end

    @testset "the card of a selection of several" begin
        gui, sys, a, b, c = _fixture(:app)
        select!(gui, [a, b])
        GUI._update_inspector!(gui; force = true)
        @test [w.name for w in card_actions(gui.controls.selected[])] == [:hide, :group, :remove]
        @test _w(gui, :group) isa Button
        notify(_w(gui, :group).clicks)
        g = gui.controls.selected[]
        @test g isa BMO.ObjectGroup && GUI._is_window_group(gui, g)
        GUI._update_inspector!(gui; force = true)
        @test _w(gui, :ungroup).blockscene.visible[]
        notify(_w(gui, :ungroup).clicks)
        @test GUI._is_multi(gui.controls.selected[]) && _in(a, sys.objects) && _in(b, sys.objects)
    end

    @testset "ignored while typing and in the spectator mode" begin
        gui, sys, a, b, c = _fixture(:compact)
        select!(gui, [a, b])
        n_history = length(gui.controls.undo_stack)
        # a focused text box takes the key
        gui.controls.ignore_keys() && error("test setup")
        GUI._keep_keyboard!(gui)
        spectator!(gui)
        _ctrl!(gui, Keyboard.g)
        @test length(sys.objects) == 3 && length(gui.controls.undo_stack) == n_history
        spectator!(gui, false)
        select!(gui, [a, b])
        _ctrl!(gui, Keyboard.g)
        @test length(sys.objects) == 2
    end

    @testset "g zooms, Ctrl+G does not" begin
        gui, sys, a, b, c = _fixture(:compact)
        set_view(gui.ax, [0.3, -0.2, 0.25], [0.0, 0.05, 0.0], [0.0, 0.0, 1.0])
        _tick!(gui)
        select!(gui, a)
        eye0, lookat0, _ = _view(gui)
        _key!(gui, Keyboard.g)
        _tick!(gui)
        eye1, lookat1, _ = _view(gui)
        @test norm(lookat1 - lookat0) > 1e-3
        # Ctrl+G with a single object only reports; the camera stays
        set_view(gui.ax, eye0, lookat0, [0.0, 0.0, 1.0])
        _tick!(gui)
        _ctrl!(gui, Keyboard.g)
        _tick!(gui)
        eye2, lookat2, _ = _view(gui)
        @test isapprox(lookat2, lookat0; atol = 1e-6) && isapprox(eye2, eye0; atol = 1e-6)
        @test isnothing(gui.camera.animation)
    end
end

end
