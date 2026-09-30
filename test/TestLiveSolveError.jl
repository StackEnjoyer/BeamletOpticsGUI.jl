module TestLiveSolveError

using GLMakie, BeamletOptics, BeamletOpticsGUI
using Makie
using Test

const BMO = BeamletOptics
const GUI = BeamletOpticsGUI

@testset "Solve error message" begin

    _live_view(args...; kwargs...) =
        live_view(args...; merge((; trace_budget = Inf, throttle = false, preview = false), kwargs)...)

    _key!(gui, key) = (events(gui.ax.scene).keyboardbutton[] = Makie.KeyEvent(key, Keyboard.press))

    # An unpolarized and a polarized beam along +y, 20 mm apart, onto one detector
    function _fixture()
        pd = Detector(50e-3)
        translate3d!(pd, [0, 0.1, 0])
        b1 = Beam([0.0, 0, 0], [0.0, 1, 0])
        b2 = Beam([20e-3, 0, 0], [0.0, 1, 0], 633e-9, [1.0, 0, 0])
        return System([pd]), pd, b1, b2
    end

    # The transient card of the gui if it shows the message of a failed solve, else `nothing`
    function _message(gui)
        c = GUI._info_card(gui)
        return isnothing(c) || !(c.obj isa GUI._SolveError) ? nothing : c
    end
    _texts(c) = [GUI._card_widget(c, Symbol(:error_, i)).text[] for i in eachindex(c.obj.rows)]

    @testset "two kinds of beams on one detector ($layout)" for layout in (:compact, :app)
        sys, pd, b1, b2 = _fixture()
        # the initial solve fails, the window opens with the message at the detector
        gui = _live_view(sys => b1, sys => b2; layout, labels = Dict(pd => "PD"))
        c = _message(gui)
        @test !isnothing(c)
        @test gui.trace.stale
        @test gui.status.text[] == "solving the systems failed, see the log"
        @test _texts(c)[1:2] == ["PD", "rays and polarized rays"]
        @test c.obj.point ≈ Point3f(0, 0.1, 0)
        @test GUI._title(c.obj) == "Solve failed"

        # Esc closes it, the same failure does not open it again
        _key!(gui, Keyboard.escape)
        @test isnothing(_message(gui))
        GUI._trace!(gui)
        @test gui.trace.stale
        @test isnothing(_message(gui))
        # a different error does
        GUI._fail!(gui, ErrorException("another error"))
        @test _texts(_message(gui))[1] == "another error"

        # a successful solve closes the message
        GUI._set_beam_on!(gui, b2, false)
        @test !gui.trace.stale
        @test isnothing(_message(gui))
        @test isnothing(gui.trace.error)
        # after a successful solve, the same failure opens it again
        GUI._set_beam_on!(gui, b2, true)
        @test !isnothing(_message(gui))
        close(gui)
    end

    @testset "other errors, pin and click close ($layout)" for layout in (:compact, :app)
        sys, pd, b1, _ = _fixture()
        gui = _live_view(sys => b1; layout)
        @test isnothing(_message(gui))
        # solve_system! fails for this beam
        gui.pairs[1] = gui.pairs[1].first => nothing
        GUI._trace!(gui)
        c = _message(gui)
        @test !isnothing(c)
        t = _texts(c)
        @test !isempty(t[1]) && length(t[1]) <= 60
        @test t[2] == "see the log"
        # no source with a position: at the origin
        @test c.obj.point ≈ Point3f(0, 0, 0)
        # the pin closes the message instead of keeping it
        GUI._toggle_pinned!(gui, c)
        @test isnothing(_message(gui))
        @test !any(x -> x.obj isa GUI._SolveError, gui.cards.all)
        layout == :app && @test !any(d -> d.obj isa GUI._SolveError, gui.layout.inspector.pinned)
        GUI._fail!(gui, ErrorException("a third error"))
        @test !isnothing(_message(gui))
        # a click in the 3D view closes it as well
        gui.controls.on_click(nothing)
        @test isnothing(_message(gui))
        close(gui)
    end

    @testset "texts" begin
        @test GUI._first_line(ErrorException("a\nb")) == "a"
        long = GUI._first_line(ErrorException(repeat("x", 100)))
        @test length(long) == 60 && endswith(long, "…")
        @test GUI._hit_kind(BMO.GaussianBeamletHit{Float64}) == "Gaussian beamlets"
        @test GUI._hit_kind(BMO.AstigmaticGaussianBeamletHit{Float64}) == "astigmatic Gaussian beamlets"
    end
end

end
