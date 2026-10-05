module TestLiveSpectator

using GLMakie, BeamletOptics, BeamletOpticsGUI
using Makie
using Test

const BMO = BeamletOptics
const GUI = BeamletOpticsGUI

@testset "Spectator mode and its options" begin
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
    _press!(gui, key) = events(gui.ax.scene).keyboardbutton[] = Makie.KeyEvent(key, Keyboard.press)
    _release!(gui, key) = events(gui.ax.scene).keyboardbutton[] = Makie.KeyEvent(key, Keyboard.release)

    @testset "compact: without help, chrome hidden and restored" begin
        gui, m, _ = _fixture(:compact)
        select!(gui, m)
        GUI._update_cards!(gui)
        bg0 = gui.ax.scene.backgroundcolor[]
        fig0 = gui.fig.scene.backgroundcolor[]
        @test cube_shown(gui) && pinned_shown(gui)
        o = gui.layout.overlay

        spectator!(gui; help = false, background = :black)
        @test gui.controls.spectator[] && isnothing(gui.controls.selected[])
        @test o.hidden && o.pill_hidden
        @test GUI._help_ui(gui).muted
        @test !cube_shown(gui) && !pinned_shown(gui)
        @test gui.ax.scene.backgroundcolor[] == Makie.to_color(:black)
        @test gui.fig.scene.backgroundcolor[] == Makie.to_color(:black)

        spectator!(gui, false)
        @test !gui.controls.spectator[] && gui.controls.selected[] === m
        @test !o.hidden && !o.pill_hidden && !GUI._help_ui(gui).muted
        @test cube_shown(gui) && pinned_shown(gui)
        @test gui.ax.scene.backgroundcolor[] == bg0
        @test gui.fig.scene.backgroundcolor[] == fig0
        @test isnothing(gui.spectator.saved) && isnothing(gui.spectator.background)
        # off again: nothing to do
        spectator!(gui, false)
        @test !gui.controls.spectator[] && gui.controls.selected[] === m
        close(gui)
    end

    @testset "compact: the options change while the mode is on" begin
        gui, m, _ = _fixture(:compact)
        select!(gui, m)
        bg0 = gui.ax.scene.backgroundcolor[]
        o = gui.layout.overlay
        # by default the help stays, which tells how to leave the mode
        spectator!(gui)
        @test gui.controls.spectator[] && o.hidden && !o.pill_hidden && !GUI._help_ui(gui).muted
        spectator!(gui; help = false, background = :black, cards = true, view_cube = true)
        GUI._update_cards!(gui)
        @test o.pill_hidden && GUI._help_ui(gui).muted
        @test pinned_shown(gui) && cube_shown(gui)
        @test gui.ax.scene.backgroundcolor[] == Makie.to_color(:black)
        # new options are relative to the state before the mode
        spectator!(gui)
        GUI._update_cards!(gui)
        @test !o.pill_hidden && !GUI._help_ui(gui).muted
        @test !pinned_shown(gui) && !cube_shown(gui)
        @test gui.ax.scene.backgroundcolor[] == bg0
        # the selection from before the mode is kept over the changes
        spectator!(gui, false)
        @test gui.controls.selected[] === m && gui.ax.scene.backgroundcolor[] == bg0
        close(gui)
    end

    @testset "compact: the keys v and Shift+V" begin
        gui, m, _ = _fixture(:compact)
        select!(gui, m)
        o = gui.layout.overlay
        # v: with the help, and back with the selection
        _press!(gui, Keyboard.v)
        @test gui.controls.spectator[] && isnothing(gui.controls.selected[])
        @test o.hidden && !o.pill_hidden && !GUI._help_ui(gui).muted
        _press!(gui, Keyboard.v)
        @test !gui.controls.spectator[] && gui.controls.selected[] === m
        # Shift+V: without the help, v leaves
        _press!(gui, Keyboard.left_shift)
        _press!(gui, Keyboard.v)
        _release!(gui, Keyboard.left_shift)
        @test gui.controls.spectator[] && o.pill_hidden && GUI._help_ui(gui).muted
        _press!(gui, Keyboard.v)
        @test !gui.controls.spectator[] && gui.controls.selected[] === m
        @test !o.pill_hidden && !GUI._help_ui(gui).muted
        # the key v leaves the mode with its options, which are reset
        spectator!(gui; help = false, background = :black, cards = true)
        _press!(gui, Keyboard.v)
        @test !gui.controls.spectator[] && !gui.spectator.cards
        @test gui.ax.scene.backgroundcolor[] != Makie.to_color(:black)
        _press!(gui, Keyboard.v)
        GUI._update_cards!(gui)
        @test gui.controls.spectator[] && !pinned_shown(gui) && !o.pill_hidden
        _press!(gui, Keyboard.v)
        # an object that was removed meanwhile is not selected again
        select!(gui, m)
        spectator!(gui)
        remove_component!(gui, m)
        spectator!(gui, false)
        @test isnothing(gui.controls.selected[])
        close(gui)
    end

    @testset "app layout" begin
        gui, m, _ = _fixture(:app)
        select!(gui, m)
        l = gui.layout
        @test l.bar.shown && l.status_bar.shown && l.right.shown
        spectator!(gui; help = false)
        @test !l.bar.shown && !l.status_bar.shown && !l.left.shown && !l.right.shown
        @test GUI._help_ui(gui).muted
        spectator!(gui, false)
        @test l.bar.shown && l.status_bar.shown && l.right.shown
        @test gui.controls.selected[] === m
        spectator!(gui; cards = true)
        @test !l.bar.shown && l.right.shown && !GUI._help_ui(gui).muted
        spectator!(gui, false)
        close(gui)
    end

    @testset "record" begin
        gui, m, pd = _fixture(:compact)
        mktempdir() do dir
            path = joinpath(dir, "move.mp4")
            P0 = copy(Vector{Float64}(position(m)))
            was = Ref(false)
            ret = Makie.record(gui, path, 1:3; framerate = 10) do i
                was[] = gui.controls.spectator[] && GUI._help_ui(gui).muted
                translate3d!(gui, m, [0.0, 1e-3, 0.0])
            end
            @test ret == path
            @test was[]
            @test isfile(path) && filesize(path) > 0
            @test position(m) ≈ P0 + [0, 3e-3, 0]
            # the window is as before
            @test !gui.controls.spectator[] && !GUI._help_ui(gui).muted
            # a gif, without the spectator mode
            gif = joinpath(dir, "f.gif")
            Makie.record(gui, gif, 1:2; spectator = false, px_per_unit = 0.5) do i
                was[] = gui.controls.spectator[]
            end
            @test isfile(gif) && !was[]
            # a mode that is on keeps its options, its help comes back
            spectator!(gui; background = :black, cards = true)
            Makie.record(gui, gif, 1:2; px_per_unit = 0.5) do i
                was[] = GUI._help_ui(gui).muted && gui.spectator.cards
            end
            @test was[]
            @test gui.controls.spectator[] && !GUI._help_ui(gui).muted && gui.spectator.cards
            @test gui.ax.scene.backgroundcolor[] == Makie.to_color(:black)
            spectator!(gui, false)
        end
        close(gui)
    end
end

end # module
