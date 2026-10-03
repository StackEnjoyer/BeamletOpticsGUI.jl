module TestLiveAlign

using GLMakie, BeamletOptics, BeamletOpticsGUI
using Makie
using LinearAlgebra: I, norm, dot, normalize
using Test

const BMO = BeamletOptics
const GUI = BeamletOpticsGUI

@testset "Aligning components to the beams" begin
    y = [0.0, 1, 0]

    # Beam A along +y onto a mirror at 45° at y = 0.3, which sends it along +x; beam B along -y
    # beside it; a lens beside beam A at y = 0.1, turned by 10°
    function _fixture(; lens_at = [0.03, 0.1, 0.004], lens_angle = deg2rad(10), kwargs...)
        m = RoundPlanoMirror(25e-3, 5e-3)
        zrotate3d!(m, deg2rad(45))
        translate3d!(m, [0, 0.3, 0])
        lens = SphericalLens(0.05, -0.05, 0.01, 0.02)
        zrotate3d!(lens, lens_angle)
        translate_to3d!(lens, lens_at)
        sys = System([m, lens])
        a = Beam([0.0, 0, 0], [0.0, 1, 0], 1e-6)
        b = Beam([-0.05, 0.4, 0], [0.0, -1, 0], 1e-6)
        gui = live_view(sys => a, sys => b; trace_budget = Inf, throttle = false, kwargs...)
        return gui, sys, m, lens, a, b
    end
    _pose(obj) = (collect(Float64, position(obj)), Matrix{Float64}(BMO.orientation(obj)))
    _names(row) = [c isa CardWidget ? c.name : nothing for c in row.cells]

    @testset "nearest line" begin
        lines = [GUI._SnapLine([0.0, 0, 0], [0.0, 1, 0], y), GUI._SnapLine([1.0, 0, 0], [1.0, 0, 2], [0.0, 0, 1])]
        @test isnothing(GUI._nearest_line(GUI._SnapLine[], [0.0, 0, 0]))
        near = GUI._nearest_line(lines, [0.1, 0.4, 0.0])
        @test near.point ≈ [0.0, 0.4, 0] && near.direction == y && near.distance ≈ 0.1
        near = GUI._nearest_line(lines, [0.8, 0.4, 1.0])
        @test near.point ≈ [1.0, 0, 1] && near.direction == [0.0, 0, 1]
        # beyond its end: the end of the line
        near = GUI._nearest_line(lines, [0.1, 1.5, 0.0])
        @test near.point ≈ [0.0, 1, 0] && near.distance ≈ norm([0.1, 0.5])
    end

    @testset "rows of the cards" begin
        gui, sys, m, lens, a, b = _fixture()
        rows = GUI._card_rows(lens)
        @test length(rows) == length(card_rows(lens)) + 1
        @test _names(last(rows)) == [:center, :face, :remove]
        @test [c.attributes[:label] for c in last(rows).cells] == ["onto beam", "face beam", "remove"]
        # a source is aimed
        @test _names(last(GUI._card_rows(a))) == [:aim, :remove]
        close(gui)
    end

    @testset "onto the beam ($layout)" for layout in (:compact, :app)
        gui, sys, m, lens, a, b = _fixture(; layout)
        ctrl = gui.controls
        P0, R0 = _pose(lens)
        n = length(ctrl.undo_stack)
        @test GUI._center_on_beam!(gui, lens)
        P, R = _pose(lens)
        # the point of beam A closest to it; its orientation is kept
        @test P ≈ [0.0, 0.1, 0.0] atol = 1e-9
        @test R ≈ R0
        @test occursin("moved onto the beam", gui.status.text[])
        # traced: the beam passes the lens
        @test !isempty(GUI._hits(gui, lens))
        # one gesture of the undo history, also for a component that is not selected
        @test isnothing(ctrl.selected[]) && length(ctrl.undo_stack) == n + 1
        GUI._undo!(ctrl)
        @test _pose(lens)[1] ≈ P0 atol = 1e-12
        GUI._redo!(ctrl)
        @test _pose(lens)[1] ≈ [0.0, 0.1, 0.0] atol = 1e-9
        # already there
        n = length(ctrl.undo_stack)
        @test !GUI._center_on_beam!(gui, lens)
        @test occursin("on the beam already", gui.status.text[]) && length(ctrl.undo_stack) == n
        # via the button of its card
        translate3d!(lens, [-0.04, 0, 0])
        center = only(c for c in last(GUI._card_rows(lens)).cells if c.name === :center)
        center.on(gui, lens, nothing)
        # beam B at x = -0.05 is closer now
        @test _pose(lens)[1] ≈ [-0.05, 0.1, 0.0] atol = 1e-9
        close(gui)
    end

    @testset "facing the beam" begin
        gui, sys, m, lens, a, b = _fixture()
        ctrl = gui.controls
        P0, R0 = _pose(lens)
        @test GUI._face_beam!(gui, lens)
        P, R = _pose(lens)
        # the optical axis along beam A, the closer sense; the position is kept
        @test R[:, 2] ≈ y atol = 1e-9
        @test P ≈ P0 atol = 1e-12
        @test R' * R ≈ I atol = 1e-9
        @test occursin("faces the beam, turned by 175 mrad", gui.status.text[])
        GUI._undo!(ctrl)
        @test _pose(lens)[2] ≈ R0 atol = 1e-9
        GUI._redo!(ctrl)
        @test !GUI._face_beam!(gui, lens)
        @test occursin("faces the beam already", gui.status.text[])
        close(gui)

        # against the beam, if that is closer
        gui, sys, m, lens, a, b = _fixture(; lens_angle = deg2rad(170))
        @test GUI._face_beam!(gui, lens)
        @test _pose(lens)[2][:, 2] ≈ -y atol = 1e-9
        close(gui)

        # behind the mirror, the reflected beam along +x is the nearest
        gui, sys, m, lens, a, b = _fixture(; lens_at = [0.1, 0.31, 0.0], lens_angle = deg2rad(-80))
        @test GUI._face_beam!(gui, lens)
        @test _pose(lens)[2][:, 2] ≈ [1.0, 0, 0] atol = 1e-9
        @test GUI._center_on_beam!(gui, lens)
        @test _pose(lens)[1] ≈ [0.1, 0.3, 0.0] atol = 1e-9
        close(gui)
    end

    @testset "what can not be aligned" begin
        gui, sys, m, lens, a, b = _fixture(; constraints = Dict())
        ctrl = gui.controls
        P0, R0 = _pose(lens)
        # no beam that is switched on
        GUI._set_beam_on!(gui, a, false)
        GUI._set_beam_on!(gui, b, false)
        n = length(ctrl.undo_stack)
        @test !GUI._center_on_beam!(gui, lens) && !GUI._face_beam!(gui, lens)
        @test occursin("no beam to align", gui.status.text[])
        @test _pose(lens)[1] == P0 && length(ctrl.undo_stack) == n
        close(gui)

        # an object that the controls do not move
        fixed = RoundPlanoMirror(25e-3, 5e-3)
        translate3d!(fixed, [0.03, 0.2, 0])
        other = RoundPlanoMirror(25e-3, 5e-3)
        translate3d!(other, [0.2, 0.2, 0])
        gui = live_view(System([fixed, other]) => Beam([0.0, 0, 0], [0.0, 1, 0], 1e-6); trace_budget = Inf,
            objects = [other])
        @test !GUI._center_on_beam!(gui, fixed) && !GUI._face_beam!(gui, fixed)
        @test collect(position(fixed)) ≈ [0.03, 0.2, 0]
        @test occursin("not movable", gui.status.text[])
        close(gui)

        # constraints: only along the allowed axes, no rotation unless it is free
        m = RoundPlanoMirror(25e-3, 5e-3)
        translate3d!(m, [0, 0.3, 0])
        lens = SphericalLens(0.05, -0.05, 0.01, 0.02)
        translate_to3d!(lens, [0.03, 0.1, 0.004])
        sys = System([m, lens])
        gui = live_view(sys => Beam([0.0, 0, 0], [0.0, 1, 0], 1e-6); trace_budget = Inf, throttle = false,
            constraints = Dict(lens => (; move = (:x,), rotate = (:v,))))
        @test GUI._center_on_beam!(gui, lens)
        # along its local x-axis only: the height is kept
        @test _pose(lens)[1] ≈ [0.0, 0.1, 0.004] atol = 1e-9
        @test !GUI._face_beam!(gui, lens)
        @test occursin("can not rotate freely", gui.status.text[])
        close(gui)
        gui = live_view(sys => Beam([0.0, 0, 0], [0.0, 1, 0], 1e-6); trace_budget = Inf, throttle = false,
            constraints = Dict(lens => (; move = ())))
        translate_to3d!(lens, [0.03, 0.1, 0.0])
        @test !GUI._center_on_beam!(gui, lens)
        @test occursin("can not move", gui.status.text[])
        close(gui)
    end
end

end
