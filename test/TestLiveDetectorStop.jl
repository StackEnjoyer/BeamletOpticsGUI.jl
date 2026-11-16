module TestLiveDetectorStop

using GLMakie, BeamletOptics, BeamletOpticsGUI
using Test

const BMO = BeamletOptics
const GUI = BeamletOpticsGUI

@testset "Switch \"stop beams\" on the card of a detector" begin

    # Each change is solved at once, see `TestLiveView.jl`; no card of a detector is pinned at start
    _live_view(args...; kwargs...) =
        live_view(args...; merge((; trace_budget = Inf, throttle = false, detectors = []), kwargs)...)
    _entry(name) = only(e for e in component_catalog() if e.name == name)
    _defaults(entry) = String[GUI._catalog_string(p) for p in entry.params]
    _undo!(gui) = GUI._undo!(gui.controls)
    _redo!(gui) = GUI._redo!(gui.controls)
    # A detector at `y` on the beam along +y, and the beam
    function _detector(y; len = 10e-3)
        d = Detector(len)
        translate3d!(d, [0, y, 0])
        return d
    end
    _beam() = Beam([0.0, 0, 0], [0.0, 1, 0], 632.8e-9)
    _targets(beam) = Any[BMO.object(BMO.intersection(r)) for r in BMO.rays(beam) if !isnothing(BMO.intersection(r))]
    _in(x, xs) = any(y -> y === x, xs)

    @testset "the row of the card" begin
        rows = card_rows(Detector(10e-3))
        @test count(r -> any(c -> c isa CardWidget && c.name === :stop && c.type === Toggle, r.cells), rows) == 1
    end

    @testset "a detector of the script, $layout" for layout in (:compact, :app)
        front, back = _detector(0.1), _detector(0.2)
        sys = System([front, back])
        beam = _beam()
        gui = _live_view(sys => beam; layout, labels = Dict(front => "front"))
        @test _in(front, _targets(beam)) && !_in(back, _targets(beam))
        # switched off: the same object in its system, and the beam passes onto the second detector
        GUI._set_stop!(gui, front, false)
        @test !BMO.stop(front) && _in(front, sys.objects) && GUI._label(gui, front) == "front"
        @test isnothing(gui.trace.error) && _in(back, _targets(beam))
        # no code of its own: `export_changes` writes the switch, `export_script` a comment with it
        @test occursin("\nBeamletOptics.stop!(front, false)\n", GUI._export_code(gui)[1])
        @test occursin("\n# BeamletOptics.stop!(front, false)\n", GUI._export_script_code(gui))
        # undo and redo switch it back and forth and solve again
        @test _undo!(gui)
        @test BMO.stop(front) && !_in(back, _targets(beam))
        @test occursin("# no changes", GUI._export_code(gui)[1])
        @test _redo!(gui)
        @test !BMO.stop(front) && _in(back, _targets(beam))
        # the same state again changes nothing
        GUI._set_stop!(gui, front, false)
        @test _undo!(gui) && BMO.stop(front)
        close(gui)
    end

    @testset "outdated without auto tracing" begin
        front, back = _detector(0.1), _detector(0.2)
        beam = _beam()
        gui = _live_view(System([front, back]) => beam; auto_trace = false)
        GUI._set_stop!(gui, front, false)
        @test gui.trace.stale && !_in(back, _targets(beam))
        close(gui)
    end

    @testset "a detector of the catalog: its code and the inputs of the page \"Edit\"" begin
        back = _detector(0.2)
        sys = System([back])
        beam = _beam()
        gui = _live_view(sys => beam)
        c = GUI._catalog_component(_entry("Detector"), _defaults(_entry("Detector")))
        translate3d!(c.obj, [0, 0.1, 0])
        add_component!(gui, c.obj; origin = c.origin, label = "PD")
        GUI._set_stop!(gui, c.obj, false)
        origin = gui.components.origin[c.obj]
        @test origin.code == "Detector(0.01, false)" && origin.strings[end] == "false"
        # added in the window: its code has the state, no separate switch line
        code = GUI._export_code(gui)[1]
        @test occursin("PD = Detector(0.01, false)", code) && !occursin("stop!", code)
        # the page "Edit" has no switch of its own
        toggle = only(p for p in _entry("Detector").params if p isa GUI.CatalogToggle)
        @test isempty(GUI._edit_param_rows(gui, c.obj, toggle, 2))
        @test _undo!(gui)
        @test gui.components.origin[c.obj].code == "Detector(0.01, true)"
        close(gui)
    end

    @testset "the code of a call of Detector" begin
        @test GUI._stop_call_code("Detector(0.02)", false) == "Detector(0.02, false)"
        @test GUI._stop_call_code("Detector(0.02, false)", true) == "Detector(0.02, true)"
        @test GUI._stop_call_code("BeamletOptics.Detector(0.02, true)", false) ==
              "BeamletOptics.Detector(0.02, false)"
        @test isnothing(GUI._stop_call_code("Detector(0.02; stop = true)", false))
        @test isnothing(GUI._stop_call_code("RoundPlanoMirror(0.02, 0.005)", false))
        @test isnothing(GUI._stop_call_code("Detector(", false))
        # added with its code: the call takes the switch
        gui = _live_view(System())
        d = _detector(0.1; len = 20e-3)
        add_component!(gui, d; code = "Detector(0.02)")
        GUI._set_stop!(gui, d, false)
        @test gui.components.origin[d].code == "Detector(0.02, false)"
        close(gui)
    end

    @testset "in a second window" begin
        sys = System()
        gui = _live_view(sys => _beam())
        c = GUI._catalog_component(_entry("Detector"), _defaults(_entry("Detector")))
        translate3d!(c.obj, [0, 0.1, 0])
        add_component!(gui, c.obj; origin = c.origin, label = "PD")
        new = open_system(gui, sys; display = false)
        GUI._set_stop!(new, c.obj, false)
        @test !BMO.stop(c.obj)
        @test gui.components.origin[c.obj].code == "Detector(0.01, false)"
        @test new.components.origin[c.obj].code == "Detector(0.01, false)"
        close(new)
        close(gui)
    end
end

end
