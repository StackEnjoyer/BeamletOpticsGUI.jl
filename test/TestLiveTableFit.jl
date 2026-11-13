module TestLiveTableFit

using GLMakie, BeamletOptics, BeamletOpticsGUI
using Test

const BMO = BeamletOptics
const GUI = BeamletOpticsGUI

@testset "Optical table fits the setup again" begin
    function _fixture()
        m = RoundPlanoMirror(25e-3, 5e-3)
        lens = SphericalLens(0.05, -0.05, 0.01, 0.02)
        translate_to3d!(lens, [0.0, 0.1, 0.0])
        sys = System([m, lens])
        gui = live_view(sys => Beam([0.0, 0, 0], [0.0, 1, 0], 1e-6); trace_budget = Inf,
            throttle = false, plane_normal = [0, 0, 1], table = true)
        return gui, sys, m, lens
    end

    @testset "moved back from far away" begin
        gui, sys, m, lens = _fixture()
        t = gui.components.table
        r0 = t.range
        @test !GUI._table_fit!(gui)
        translate_to3d!(lens, [1.0, 0.1, 0.0])
        GUI._table_include!(gui, lens)
        @test t.range[2] > r0[2]
        # not while the mouse drags or a component is placed
        gui.controls.dragging = true
        translate_to3d!(lens, [0.0, 0.1, 0.0])
        @test !GUI._table_fit!(gui)
        @test t.range[2] > r0[2]
        gui.controls.dragging = false
        @test GUI._table_fit!(gui)
        @test t.range == r0
        @test length(t.holes[]) == length(GUI._table_holes(t)[1])
        @test !GUI._table_fit!(gui)
    end

    @testset "removed" begin
        gui, sys, m, lens = _fixture()
        t = gui.components.table
        r0 = t.range
        translate_to3d!(lens, [0.0, 1.0, 0.0])
        GUI._table_include!(gui, lens)
        grown = t.range[4]
        @test grown > r0[4]
        remove_component!(gui, lens)
        GUI._table_fit!(gui)
        @test t.range == GUI._table_range(t, GUI._table_points(gui)) && t.range[4] < grown
    end

    @testset "after undo, a key step or a card input" begin
        gui, sys, m, lens = _fixture()
        t = gui.components.table
        r0 = t.range
        @test !GUI._table_tick!(gui; now = time() + 1)
        # a drag far away grows the table and fits it at its end
        P0, R0 = GUI._pose(lens)
        translate3d!(gui, lens, [1.0, 0.0, 0.0])
        @test t.range[2] > r0[2]
        # the undo moves it back: the table fits after the delay, not at once
        @test GUI._undo!(gui.controls)
        @test GUI._pose(lens)[1] ≈ P0
        @test t.range[2] > r0[2]
        @test !GUI._table_tick!(gui; now = t.fit_at + GUI._TABLE_FIT_DELAY / 2)
        @test GUI._table_tick!(gui; now = t.fit_at + 2 * GUI._TABLE_FIT_DELAY)
        @test t.range == r0
        @test isnan(t.fit_at)
        @test !GUI._table_tick!(gui; now = time() + 1)
    end

    @testset "a fit refused while placing is made up" begin
        gui, sys, m, lens = _fixture()
        t = gui.components.table
        r0 = t.range
        translate_to3d!(lens, [0.0, 1.0, 0.0])
        GUI._table_include!(gui, lens)
        translate_to3d!(lens, [0.0, 0.1, 0.0])
        gui.controls.dragging = true
        @test !GUI._table_fit!(gui)
        @test !isnan(t.fit_at)
        @test !GUI._table_tick!(gui; now = time() + 1)
        gui.controls.dragging = false
        @test GUI._table_tick!(gui; now = time() + 1)
        @test t.range == r0
    end

    @testset "hidden table is left alone" begin
        gui, sys, m, lens = _fixture()
        t = gui.components.table
        t.toggle.active[] = false
        @test !GUI._table_fit!(gui)
    end
end

end
