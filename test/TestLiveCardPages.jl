module TestLiveCardPages

using GLMakie, BeamletOptics, BeamletOpticsGUI
using Makie
using Test

const BMO = BeamletOptics
const GUI = BeamletOpticsGUI

# An object whose card has no properties, like an inspected point
struct NoProperties end
GUI._has_properties(::NoProperties) = false

@testset "Pages of the cards" begin
    pd = Detector(5e-3)
    m = RoundPlanoMirror(25e-3, 5e-3)
    beam = Beam([0.0, 0, 0], [0.0, 1, 0])

    @testset "pages per type" begin
        @test GUI._card_pages(m) == (:pose, :properties)
        # beams, beam groups and beamlets: the page of their color
        @test GUI._card_pages(beam) == (:pose, :color, :properties)
        @test GUI._card_pages(CollimatedSource([0.0, 0, 0], [0.0, 1, 0], 5e-3, 1e-6; num_rings = 2)) ==
              (:pose, :color, :properties)
        @test GUI._card_pages(GaussianBeamlet([0.0, 0, 0], [0.0, 1, 0], 1e-6, 1e-3)) ==
              (:pose, :color, :properties)
        @test GUI._card_pages(AstigmaticGaussianBeamlet([0.0, 0, 0], [0.0, 1, 0], 1e-6, 1e-3, 5e-4)) ==
              (:pose, :color, :properties)
        @test GUI._default_page(beam) == :pose
        # the rows of the pages: those of the page "Pose" unless a page has its own
        @test length(GUI._page_rows(beam, :color)) == 3
        @test length(GUI._page_rows(beam, :pose)) == length(GUI._page_rows(beam, :properties)) ==
              length(GUI._card_rows(beam))
        @test length(GUI._page_rows(m, :color)) == length(GUI._card_rows(m))
        @test GUI._shows_rows(:pose) && GUI._shows_rows(:color) && !GUI._shows_rows(:properties)
        @test GUI._card_pages(System([m])) == (:pose, :properties)
        @test GUI._card_pages(pd) == (:pose, :results, :properties)
        @test GUI._card_pages(NoProperties()) == (:pose,)
        # every card has the page of its rows
        @test all(obj -> :pose in GUI._card_pages(obj), (m, beam, pd, NoProperties()))
        @test GUI._default_page(pd) == :results
        @test GUI._default_page(m) == :pose
        @test GUI._default_page(NoProperties()) == :pose
        @test GUI._has_view(pd) && !GUI._has_view(m)
    end

    @testset "page bar" begin
        @test GUI._page_label.((:pose, :color, :results, :properties)) ==
              ("Pose", "Color", "Results", "Properties")
        fig = Figure()
        t = GUI._APP_THEMES[:light]
        bar = GUI._page_bar!(fig[1, 1], t, GUI._card_pages(pd); selected = :results)
        @test bar.keys == [:pose, :results, :properties]
        @test [b.label[] for b in bar.buttons] == ["Pose", "Results", "Properties"]
        @test bar.selected[] == :results
        notify(bar.buttons[1].clicks)
        @test bar.selected[] == :pose
        @test GUI._page_bar!(fig[2, 1], t, GUI._card_pages(m)).selected[] == :pose
    end
end

end
