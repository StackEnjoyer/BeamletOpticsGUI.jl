module TestLivePresentation

using GLMakie, BeamletOptics, BeamletOpticsGUI
using Makie
using Test

const BMO = BeamletOptics
const GUI = BeamletOpticsGUI

@testset "Presentation mode" begin
    # Rays along +y, the mirror at 45° reflects them along +x onto the detector, whose card is pinned
    function _fixture(layout; kwargs...)
        m = RoundPlanoMirror(25e-3, 5e-3)
        zrotate3d!(m, deg2rad(45))
        translate3d!(m, [0, 0.1, 0])
        pd = Detector(5e-3)
        zrotate3d!(pd, -π / 2)
        translate3d!(pd, [0.1, 0.1, 0])
        cs = CollimatedSource([0.0, 0, 0], [0.0, 1, 0], 2e-3, 1e-6; num_rings = 2, num_rays = 40)
        gui = live_view(System([m, pd]) => cs; layout, trace_budget = Inf, throttle = false,
            catalog = CatalogEntry[], detectors = [pd], kwargs...)
        return gui, m, pd
    end
    cube_shown(gui) = gui.widgets.view_cube.scene.visible[]
    pinned_shown(gui) = any(c -> c.pinned && c.scene.visible[], gui.cards.all)

    @testset "compact: chrome hidden and restored" begin
        gui, m, _ = _fixture(:compact)
        select!(gui, m)
        GUI._update_cards!(gui)
        bg0 = gui.ax.scene.backgroundcolor[]
        fig0 = gui.fig.scene.backgroundcolor[]
        @test cube_shown(gui) && pinned_shown(gui)
        o = gui.layout.overlay

        presentation!(gui; background = :black)
        @test gui.presentation.on
        @test gui.controls.spectator[] && isnothing(gui.controls.selected[])
        @test o.hidden && o.pill_hidden
        @test GUI._help_ui(gui).presenting
        @test !cube_shown(gui) && !pinned_shown(gui)
        @test gui.ax.scene.backgroundcolor[] == Makie.to_color(:black)
        @test gui.fig.scene.backgroundcolor[] == Makie.to_color(:black)

        presentation!(gui, false)
        @test !gui.presentation.on
        @test !gui.controls.spectator[] && gui.controls.selected[] === m
        @test !o.hidden && !o.pill_hidden && !GUI._help_ui(gui).presenting
        @test cube_shown(gui) && pinned_shown(gui)
        @test gui.ax.scene.backgroundcolor[] == bg0
        @test gui.fig.scene.backgroundcolor[] == fig0
        # off again: nothing to do
        presentation!(gui, false)
        close(gui)
    end

    @testset "compact: cards, view cube and the key v" begin
        gui, m, _ = _fixture(:compact)
        presentation!(gui; cards = true, view_cube = true)
        GUI._update_cards!(gui)
        @test pinned_shown(gui) && cube_shown(gui)
        presentation!(gui)  # new options relative to the state before
        @test !pinned_shown(gui) && !cube_shown(gui)
        # the key v leaves the presentation mode
        events(gui.ax.scene).keyboardbutton[] = Makie.KeyEvent(Keyboard.v, Keyboard.press)
        @test !gui.presentation.on && !gui.controls.spectator[]
        @test !GUI._help_ui(gui).presenting && !gui.layout.overlay.pill_hidden
        close(gui)
    end

    @testset "spectator mode before stays" begin
        gui, m, _ = _fixture(:compact)
        spectator!(gui, true)
        presentation!(gui)
        presentation!(gui, false)
        @test gui.controls.spectator[] && !gui.presentation.on
        @test !GUI._help_ui(gui).presenting
        close(gui)
    end

    @testset "app layout" begin
        gui, m, _ = _fixture(:app)
        select!(gui, m)
        l = gui.layout
        @test l.bar.shown && l.status_bar.shown && l.right.shown
        presentation!(gui)
        @test !l.bar.shown && !l.status_bar.shown && !l.left.shown && !l.right.shown
        @test GUI._help_ui(gui).presenting
        presentation!(gui, false)
        @test l.bar.shown && l.status_bar.shown && l.right.shown
        @test gui.controls.selected[] === m
        presentation!(gui; cards = true)
        @test !l.bar.shown && l.right.shown
        presentation!(gui, false)
        close(gui)
    end

    @testset "record" begin
        gui, m, pd = _fixture(:compact)
        mktempdir() do dir
            path = joinpath(dir, "move.mp4")
            P0 = copy(Vector{Float64}(position(m)))
            was = Ref(false)
            ret = Makie.record(gui, path, 1:3; framerate = 10) do i
                was[] = gui.presentation.on
                translate3d!(gui, m, [0.0, 1e-3, 0.0])
            end
            @test ret == path
            @test was[]
            @test isfile(path) && filesize(path) > 0
            @test position(m) ≈ P0 + [0, 3e-3, 0]
            # the window is as before
            @test !gui.presentation.on && !gui.controls.spectator[]
            # a gif, without the presentation mode
            png = joinpath(dir, "f.gif")
            Makie.record(gui, png, 1:2; presentation = false, px_per_unit = 0.5) do i end
            @test isfile(png)
        end
        close(gui)
    end
end

end # module
