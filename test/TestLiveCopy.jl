module TestLiveCopy

using GLMakie, BeamletOptics, BeamletOpticsGUI
using Makie
using LinearAlgebra: norm, normalize
using Test

const BMO = BeamletOptics
const GUI = BeamletOpticsGUI

@testset "Copy and paste" begin

    # Each change is solved at once, see `TestLiveView.jl`; no card of a detector is pinned at start
    _live_view(args...; kwargs...) =
        live_view(args...; merge((; trace_budget = Inf, throttle = false, detectors = []), kwargs)...)

    _entry(name) = only(e for e in component_catalog() if e.name == name)
    _defaults(entry) = String[GUI._catalog_string(p) for p in entry.params]
    # A component or source of the catalog with the texts `strings` of its form
    _built(name, strings = _defaults(_entry(name))) = GUI._catalog_component(_entry(name), strings)

    # The key that types the letter of `key` in the keyboard layout of this machine, see `_layout_key`
    _typed(key) = first(k for k in Keyboard.Button.(Int(Keyboard.a):Int(Keyboard.z)) if GUI._layout_key(k) == key)
    _key!(gui, key) = (events(gui.ax.scene).keyboardbutton[] = Makie.KeyEvent(key, Keyboard.press))
    function _ctrl!(gui, key)
        state = events(gui.ax.scene).keyboardstate
        push!(state, Keyboard.left_control)
        _key!(gui, _typed(key))
        delete!(state, Keyboard.left_control)
        return nothing
    end
    function _select!(gui, obj)
        gui.controls.selected[] = obj
        GUI._update_selection_box!(gui.controls)
        return nothing
    end
    _in(obj, list) = any(o -> o === obj, list)
    _beam() = Beam([0.0, 0, 0], [0.0, 1, 0], 632.8e-9)
    _hex(c) = GUI._color_hex(Makie.to_color(c))

    @testset "a component, $layout" for layout in (:compact, :app)
        GUI._CLIPBOARD[] = nothing
        sys = System()
        gui = _live_view(sys => _beam(); layout)
        # nothing copied yet, nothing selected
        _ctrl!(gui, Keyboard.v)
        @test !GUI._placing(gui) && occursin("nothing to paste", gui.status.text[])
        _ctrl!(gui, Keyboard.c)
        @test isnothing(GUI._CLIPBOARD[]) && gui.status.text[] == "nothing selected to copy"

        c = _built("Thin lens", ["80", "-60", "30", "N-SF11"])
        lens = c.obj
        rotate3d!(lens, normalize([1.0, 2, 3]), 0.4)
        translate_to3d!(lens, [0.01, 0.1, -0.02])
        add_component!(gui, lens; origin = c.origin, label = "L1")
        R = GUI._pose(lens)[2]
        n_history = length(gui.controls.undo_stack)

        # Ctrl+C keeps the entry, its inputs and the rotation, and changes nothing
        _select!(gui, lens)
        _ctrl!(gui, Keyboard.c)
        kept = GUI._CLIPBOARD[]
        @test kept.entry === c.origin.entry && kept.strings == ["80", "-60", "30", "N-SF11"]
        @test kept.rotation * c.origin.pose0[2] ≈ R atol = 1e-12
        @test kept.kwargs == (;) && kept.name == "L1"
        @test occursin("L1 copied", gui.status.text[])
        @test length(sys.objects) == 1 && length(gui.controls.undo_stack) == n_history
        @test !GUI._placing(gui)

        # Ctrl+V attaches another one to the mouse, in the orientation of the original
        _ctrl!(gui, Keyboard.v)
        @test GUI._placing(gui)
        p = gui.components.placement
        new = p.obj
        @test new !== lens && typeof(new) === typeof(lens)
        @test p.system === sys && p.kwargs == (;)
        @test GUI._pose(new)[2] ≈ R atol = 1e-9
        @test p.origin.entry === c.origin.entry && p.origin.strings == kept.strings
        @test p.origin.code == c.origin.code
        @test p.origin.pose0[2] ≈ c.origin.pose0[2] atol = 1e-12
        @test occursin("placing", gui.status.text[])
        @test length(sys.objects) == 1
        # the original is as it was
        @test GUI._pose(lens)[2] == R
        @test collect(position(lens)) ≈ [0.01, 0.1, -0.02] atol = 1e-12

        # another Ctrl+V takes its place, the click drops it: one step of the undo history
        _ctrl!(gui, Keyboard.v)
        second = gui.components.placement.obj
        @test second !== new && second !== lens
        GUI._drop_placement!(gui)
        @test length(sys.objects) == 2 && sys.objects[end] === second && !_in(new, sys.objects)
        @test GUI._pose(second)[2] ≈ R atol = 1e-9
        @test gui.controls.selected[] === second
        # built from the catalog like the original: with the page "Edit", and a copy of the copy
        @test GUI._editable(gui, second) && gui.components.origin[second].strings == kept.strings
        @test gui.components.origin[second].strings !== kept.strings
        @test GUI._label(gui, second) != "L1"
        @test length(gui.controls.undo_stack) == n_history + 1
        _ctrl!(gui, Keyboard.c)
        @test GUI._CLIPBOARD[] !== kept && GUI._CLIPBOARD[].strings == kept.strings
        @test GUI._undo!(gui.controls)
        @test length(sys.objects) == 1 && sys.objects[1] === lens

        # the inputs of the page "Edit" that are not applied are not copied
        _select!(gui, lens)
        GUI._set_edit_string!(gui, lens, 1, "120")
        _ctrl!(gui, Keyboard.c)
        @test GUI._CLIPBOARD[].strings == ["80", "-60", "30", "N-SF11"]

        # `Esc` cancels a paste
        _ctrl!(gui, Keyboard.v)
        @test GUI._placing(gui)
        _key!(gui, Keyboard.escape)
        @test !GUI._placing(gui) && length(sys.objects) == 1
        close(gui)
    end

    @testset "what can not be copied" begin
        GUI._CLIPBOARD[] = nothing
        m = RoundPlanoMirror(25e-3, 5e-3)
        translate3d!(m, [0, 0.2, 0])
        sys = System([m])
        beam = _beam()
        gui = _live_view(sys => beam)
        c = _built("Thin lens")
        add_component!(gui, c.obj; origin = c.origin, label = "L1")
        _ctrl!(gui, Keyboard.c)
        kept = GUI._CLIPBOARD[]
        @test kept.name == "L1"
        # an object and a source of the start: their constructors are not known
        for obj in (m, beam)
            _select!(gui, obj)
            _ctrl!(gui, Keyboard.c)
            @test GUI._CLIPBOARD[] === kept
            @test occursin("can not be copied", gui.status.text[])
        end
        # a system
        GUI._inspect!(gui, sys)
        _ctrl!(gui, Keyboard.c)
        @test GUI._CLIPBOARD[] === kept && occursin("can not be copied", gui.status.text[])
        close(gui)
    end

    @testset "a source with its look" begin
        GUI._CLIPBOARD[] = nothing
        m = RoundPlanoMirror(25e-3, 5e-3)
        translate3d!(m, [0, 0.2, 0])
        sys = System([m])
        gui = _live_view(sys => _beam())
        c = _built("Beam", ["532"])
        src = c.obj
        zrotate3d!(src, deg2rad(30))
        add_component!(gui, src; origin = c.origin, beam_kwargs = (; color = :orange, linewidth = 3))
        _select!(gui, src)
        _ctrl!(gui, Keyboard.c)
        kept = GUI._CLIPBOARD[]
        @test kept.strings == ["532"] && _hex(kept.kwargs.beam_kwargs.color) == _hex(:orange)

        _ctrl!(gui, Keyboard.v)
        new = gui.components.placement.obj
        @test new isa Beam && new !== src
        @test BMO.direction(new) ≈ BMO.direction(src) atol = 1e-9
        @test BMO.wavelength(first(BMO.rays(new))) ≈ 532e-9
        GUI._drop_placement!(gui)
        @test last(gui.pairs).second === new && last(gui.pairs).first === sys
        @test _hex(gui.beams.kwargs[new].color) == _hex(:orange)
        @test gui.beams.kwargs[new].linewidth == 3
        @test GUI._editable(gui, new)
        @test isnothing(gui.trace.error) && !gui.trace.stale
        close(gui)
    end

    @testset "into another window" begin
        GUI._CLIPBOARD[] = nothing
        sys = System()
        gui = _live_view(sys => _beam())
        c = _built("Thin lens")
        add_component!(gui, c.obj; origin = c.origin)
        _ctrl!(gui, Keyboard.c)
        s = _built("Beam")
        add_component!(gui, s.obj; origin = s.origin)

        # a second view: the component goes into its system
        other_sys = System()
        other = _live_view(other_sys => _beam())
        _ctrl!(other, Keyboard.v)
        @test GUI._placing(other) && !GUI._placing(gui)
        @test gui.components.placement === nothing
        new = other.components.placement.obj
        @test other.components.placement.system === other_sys
        GUI._drop_placement!(other)
        @test other_sys.objects == [new] && length(sys.objects) == 1
        close(other)

        # a view without a `System` places a component without a system, and a source
        m = RoundPlanoMirror(25e-3, 5e-3)
        translate3d!(m, [0, 0.2, 0])
        static = _live_view(StaticSystem([m]) => _beam())
        _ctrl!(static, Keyboard.v)
        @test GUI._placing(static) && static.components.placement.system === :none
        pasted = static.components.placement.obj
        GUI._drop_placement!(static)
        @test GUI._is_extra(static, pasted)
        _select!(gui, s.obj)
        _ctrl!(gui, Keyboard.c)
        _ctrl!(static, Keyboard.v)
        @test GUI._placing(static) && static.components.placement.obj isa Beam
        GUI._drop_placement!(static)
        @test length(static.pairs) == 2
        close(static)
        close(gui)
    end

    @testset "the keys" begin
        GUI._CLIPBOARD[] = nothing
        sys = System()
        gui = _live_view(sys => _beam())
        ctrl = gui.controls
        c = _built("Thin lens")
        add_component!(gui, c.obj; origin = c.origin)
        _select!(gui, c.obj)
        # Ctrl+C is not the `c` of the clipping, Ctrl+V not the `v` of the spectator mode
        GUI._add_clip_plane!(gui, [0.0, 0.1, 0], [1.0, 0, 0])
        _select!(gui, c.obj)
        enabled = gui.clip.enabled
        _ctrl!(gui, Keyboard.c)
        @test gui.clip.enabled == enabled && !isnothing(GUI._CLIPBOARD[])
        _ctrl!(gui, Keyboard.v)
        @test !ctrl.spectator[] && GUI._placing(gui)
        GUI._cancel_placement!(gui)
        # without Ctrl, the keys are what they were
        _key!(gui, Keyboard.c)
        @test gui.clip.enabled != enabled
        _key!(gui, Keyboard.v)
        @test ctrl.spectator[]
        # in the spectator mode they do nothing, and do not leave it
        kept = GUI._CLIPBOARD[]
        _ctrl!(gui, Keyboard.v)
        @test ctrl.spectator[] && !GUI._placing(gui)
        _ctrl!(gui, Keyboard.c)
        @test GUI._CLIPBOARD[] === kept
        _key!(gui, Keyboard.v)
        @test !ctrl.spectator[]
        # listed in the help of a view with a catalog
        help(g) = repr(GUI._merge_sections(GUI._HelpSection[], g.controls.help_extra))
        @test occursin("copy the selected component or source", help(gui))
        @test occursin("paste it at the mouse", help(gui))
        close(gui)
        bare = _live_view(System() => _beam(); catalog = CatalogEntry[])
        @test !occursin("copy the selected", help(bare)) && !occursin("paste it", help(bare))
        close(bare)
    end
end

end
