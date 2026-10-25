module TestLiveDebugViews

using GLMakie, BeamletOptics, BeamletOpticsGUI
using Makie
using LinearAlgebra
using Test

const BMO = BeamletOptics
const GUI = BeamletOpticsGUI

@testset "Debug mode: cameras of the saved views" begin

    Z = [0.0, 0, 1]
    VIEWS = ["top" => ([0.0, 0.1, 0.5], [0.0, 0.1, 0.0], [0.0, 1, 0]),
        "side" => ([0.4, 0.1, 0.05], [0.0, 0.1, 0.0], Z)]

    function _fixture(; kwargs...)
        m = RoundPlanoMirror(25e-3, 5e-3)
        translate3d!(m, [0, 0.2, 0])
        beam = Beam([0.0, 0, 0], [0.0, 1, 0], 1e-6)
        gui = live_view(System([m]) => beam; trace_budget = Inf, throttle = false,
            catalog = CatalogEntry[], detectors = [], views = VIEWS, kwargs...)
        return gui
    end
    # Ticks of the window: the first one sets the home view
    function _ticks!(gui, n = 2)
        for k in 1:n
            events(gui.ax.scene).tick[] = Makie.Tick(Makie.RegularRenderTick, k, k / 30, 1 / 30)
        end
    end
    # The layer of the views of the `gui`, with the mode switched on
    function _views!(gui)
        _ticks!(gui)
        GUI._set_debug!(gui, true)
        v = GUI._debug_layer(gui, :views)
        @test v isa GUI._DebugViews
        return v
    end
    _names(v) = v.plots[:labels].text[]
    _shown(v) = all(p -> p.visible[], values(v.plots))
    # Away from all saved views and the home view
    _away!(gui) = (GUI.set_view(gui.ax, [0.9, -0.7, 0.6], [0.0, 0.1, 0.0], Z); nothing)

    @testset "a camera per saved view and the home view" begin
        gui = _fixture()
        @test isnothing(GUI._debug_layer(gui, :views))
        v = _views!(gui)
        _away!(gui)
        @test first.(v.views) == ["home", "top", "side"]
        @test _names(v) == ["home", "top", "side"]
        @test _shown(v)
        # the home view gray, the saved views in the accent color
        t = gui.layout.theme
        colors = v.plots[:labels].color[]
        @test colors[1] == RGBAf(t.muted) && all(==(RGBAf(t.accent)), colors[2:3])
        # frustum and up triangle (22 points each), sight line and pivot per camera
        @test length(v.plots[:frames][1][]) == 3 * 22
        @test length(v.plots[:sights][1][]) == 3 * 2
        @test length(v.plots[:pivots][1][]) == 3
        # nothing highlighted
        @test isempty(v.plots[:highlight][1][]) && isempty(v.plots[:full][1][])
        # the row of the debug card
        @test GUI._hud_views(gui) == "2 saved · home"
        close(gui)
    end

    @testset "the glyph of a camera" begin
        eye, lookat, up = [0.0, -1, 0], [0.0, 0, 0], [0.0, 0, 1]
        s, fov, aspect = 0.1, 45.0, 2.0
        frame, sight = GUI._view_glyph((eye, lookat, up), s, fov, aspect, false)
        @test sight == Point3f[Point3f(eye), Point3f(lookat)]
        @test length(frame) == 22
        # the edges start at the eye, the rectangle is `s` ahead with the field of view
        @test all(k -> frame[4k - 3] ≈ Point3f(eye), 1:4)
        far = [frame[4k - 2] for k in 1:4]
        @test all(p -> p[2] ≈ -1 + s, far)
        h, w = s * tand(fov / 2), aspect * s * tand(fov / 2)
        @test maximum(p -> p[3], far) ≈ h atol = 1e-6
        @test maximum(p -> p[1], far) ≈ w atol = 1e-6
        # the up triangle above the rectangle, along `up`
        @test all(p -> p[3] > h, frame[17:22])
        # up to the plane of the pivot: the area the view frames there
        whole, _ = GUI._view_glyph((eye, lookat, up), s, fov, aspect, false; full = true)
        @test length(whole) == 16
        @test all(p -> abs(p[2]) < 1e-6, whole[2:4:end])
        @test maximum(p -> p[3], whole) ≈ tand(fov / 2) atol = 1e-6
        # orthographic: a box, its near rectangle at the eye
        box, _ = GUI._view_glyph((eye, lookat, up), s, fov, aspect, true)
        @test length(box) == 4 * 6 + 6
        @test all(p -> p[2] ≈ -1, [box[6k - 5] for k in 1:4])
        @test !any(p -> p ≈ Point3f(eye), box)
    end

    @testset "follow the camera, the view of the window has no camera" begin
        gui = _fixture()
        v = _views!(gui)
        _away!(gui)
        # the names at the projections of the eyes of the saved views, which are in front of the
        # camera (the eye of the home view is behind it: `NaN`, not drawn)
        for i in 2:3
            q = Makie.project(gui.ax.scene, :data, :pixel, Point3f(v.views[i].second[1]))
            @test v.plots[:labels][1][][i] ≈ Point2f(q[1], q[2]) atol = 0.5
        end
        # through the saved view "top": its camera is gone
        GUI.set_view(gui.ax, VIEWS[1].second...)
        @test _names(v) == ["home", "side"]
        _away!(gui)
        @test _names(v) == ["home", "top", "side"]
        # a view saved while the mode is on appears at the next tick
        GUI._save_view!(gui; io = devnull)
        GUI.set_view(gui.ax, [0.9, -0.7, 0.9], [0.0, 0.1, 0.0], Z)
        _ticks!(gui, 1)
        @test _names(v) == ["home", "top", "side", "view 3"]
        @test GUI._hud_views(gui) == "3 saved · home"
        close(gui)
    end

    @testset "orthographic projection: boxes" begin
        gui = _fixture(orthographic = true)
        v = _views!(gui)
        _away!(gui)
        @test length(v.plots[:frames][1][]) == length(v.views) * 30
        close(gui)
    end

    @testset "the camera under the mouse is highlighted, its label with eye and pivot" begin
        gui = _fixture()
        v = _views!(gui)
        _away!(gui)
        i = findfirst(==("side"), first.(v.views))
        apex = v.plots[:labels][1][][i]
        @test GUI._view_at(gui, v, apex) == i
        @test GUI._view_at(gui, v, apex .+ Point2f(300, 300)) == 0
        GUI._set_view_hover!(gui, v, i)
        @test v.hover == i
        @test length(v.plots[:highlight][1][]) == 22
        @test length(v.plots[:frames][1][]) == 2 * 22
        @test length(v.plots[:full][1][]) == 16
        @test _names(v)[i] == "side\neye (400.0, 100.0, 50.0) mm\npivot (0.0, 100.0, 0.0) mm"
        @test _names(v)[1] == "home"
        GUI._set_view_hover!(gui, v, 0)
        @test _names(v)[i] == "side"
        @test isempty(v.plots[:highlight][1][]) && isempty(v.plots[:full][1][])
        # by the mouse: in the 3D view, at the eye of the camera
        o = Point2f(Makie.origin(Makie.viewport(gui.ax.scene)[]))
        events(gui.ax.scene).mouseposition[] = Tuple(Float64.(apex .+ o))
        @test v.hover == i
        events(gui.ax.scene).mouseposition[] = Tuple(Float64.(apex .+ o .+ Point2f(300, 300)))
        @test v.hover == 0
        close(gui)
    end

    @testset "hidden in the spectator mode and with the mode off" begin
        gui = _fixture()
        v = _views!(gui)
        _away!(gui)
        @test _shown(v)
        spectator!(gui)
        GUI._debug_show!(gui)
        @test !any(p -> p.visible[], values(v.plots))
        spectator!(gui, false)
        GUI._debug_show!(gui)
        @test _shown(v)
        GUI._set_debug!(gui, false)
        @test !any(p -> p.visible[], values(v.plots))
        close(gui)
    end
end

end
