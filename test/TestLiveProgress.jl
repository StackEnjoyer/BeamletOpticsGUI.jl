module TestLiveProgress

using GLMakie, BeamletOptics, BeamletOpticsGUI
using Makie
using LinearAlgebra: normalize, cross, norm
using Test

const BMO = BeamletOptics
const GUI = BeamletOpticsGUI

@testset "Live progress window" begin

    fig = Figure()
    ax = LScene(fig[1, 1])
    scatter!(ax, [Point3f(0), Point3f(1)])
    n0 = length(ax.scene.plots)

    @testset "construction" begin
        o = GUI._ProgressOverlay(ax)
        # In a child scene, drawn after all plots of the 3D scene
        @test length(ax.scene.plots) == n0
        @test o.hud in ax.scene.children && length(o.plots) == 6 && length(o.link_plots) == 2
        @test length(o.hud.plots) == 8
        # the line to the anchor point and its dot: below the panel, hidden, no line yet
        @test isempty(o.link[])
        z(p) = Makie.transformationmatrix(p)[][3, 4]
        @test all(p -> GUI._PROGRESS_Z < z(p) < z(first(o.plots)), o.link_plots)
        @test all(p -> !p.visible[] && !p.inspectable[] && isempty(p.clip_planes[]), o.link_plots)
        # GLMakie sorts the plots by the z translation before drawing, which also puts them in front
        # of the 3D scene; `overdraw` would put transparent plots over them
        @test all(p -> Makie.transformationmatrix(p)[][3, 4] > GUI._PROGRESS_Z, o.plots)
        @test all(p -> Makie.transformationmatrix(p)[][3, 4] < GUI._CARD_Z, o.plots)
        @test all(p -> !p.visible[], o.plots)
        @test all(p -> !p.overdraw[], o.plots)
        @test all(p -> !p.inspectable[], o.plots)
        @test all(p -> !p.transparency[], o.plots)
        @test all(p -> isempty(p.clip_planes[]), o.plots)
        # A NaN anchor does not enter the scene limits
        @test all(isnan, o.anchor[])
    end

    @testset "show and hide" begin
        o = GUI._ProgressOverlay(ax)
        n = length(ax.scene.plots)
        track = GUI._PROGRESS_TRACK[1]
        left = GUI._PROGRESS_BAR_X

        GUI._show_progress!(o, [0.1, 0.2, 0.3], 0.5, "Tracing beams 50 %")
        @test length(ax.scene.plots) == n
        @test all(p -> p.visible[], o.plots)
        @test o.anchor[] == GUI._screen_anchor(ax.scene, [0.1, 0.2, 0.3])
        @test o.label[] == "Tracing beams 50 %"
        @test only(vcat(o.plots[4].text[])) == "Tracing beams 50 %"
        @test o.fill_size[][1] ≈ 0.5 * track
        # The fill stays left-aligned with the track
        @test o.fill_offset[][1] - o.fill_size[][1] / 2 ≈ left
        @test o.plots[3].markersize[] == o.fill_size[]

        for (fraction, expected) in ((-0.1, 0.0), (1.3, 1.0), (0.5, 0.5))
            GUI._show_progress!(o, [0.1, 0.2, 0.3], fraction, "x")
            @test o.fill_size[][1] ≈ expected * track
            @test o.fill_offset[][1] - o.fill_size[][1] / 2 ≈ left
        end

        # Anchor update, integer points are accepted
        GUI._show_progress!(o, [1, 2, 3], 0.5, "Detector field 50 %")
        @test o.anchor[] == GUI._screen_anchor(ax.scene, Point3f(1, 2, 3))
        @test all(p -> o.anchor[] in vcat(p[1][]), o.plots)
        @test o.label[] == "Detector field 50 %"

        # Unchanged values do not notify the plots
        count = Ref(0)
        on(_ -> count[] += 1, o.anchor)
        on(_ -> count[] += 1, o.fill_size)
        on(_ -> count[] += 1, o.label)
        GUI._show_progress!(o, [1, 2, 3], 0.5, "Detector field 50 %")
        @test count[] == 0

        GUI._hide_progress!(o)
        @test all(p -> !p.visible[], o.plots)
        @test length(ax.scene.plots) == n
        GUI._hide_progress!(o)
        @test all(p -> !p.visible[], o.plots)
        GUI._show_progress!(o, [1, 2, 3], 0.25, "y")
        @test all(p -> p.visible[], o.plots)
        @test length(ax.scene.plots) == n
    end

    @testset "line to the anchor point" begin
        o = GUI._ProgressOverlay(ax)
        scene = ax.scene
        cam = cameracontrols(scene)
        eye, look = Vector(cam.eyeposition[]), Vector(cam.lookat[])
        v = normalize(look - eye)
        right = normalize(cross(v, Vector(cam.upvector[])))
        line, dot = o.link_plots
        center(o) = Point2f(o.anchor[] .+ GUI._PROGRESS_GAP .+ GUI._PROGRESS_PANEL ./ 2)
        # a point in the view: from its projection, with the dot there, to the center of the panel
        GUI._show_progress!(o, look, 0.5, "x")
        q = Makie.project(scene, :data, :pixel, Point3f(look))
        @test length(o.link[]) == 2 && o.link[][1] ≈ Point2f(q[1], q[2]) && o.link[][2] == center(o)
        @test all(p -> p.visible[], o.link_plots)
        @test vcat(dot[1][]) == o.link[][1:1]
        @test line.color[] == Makie.to_color(GUI._PROGRESS_FILL_COLOR)
        # a point beyond the right edge: the panel stays in the view, the line leaves it towards the point
        w = Makie.widths(scene.viewport[])[1]
        GUI._show_progress!(o, look + 1e3 * norm(look - eye) * right, 0.5, "x")
        @test o.link[][1][1] > w && o.link[][2] == center(o) && o.link[][2][1] < w
        # behind the camera or without a position: no line and no dot
        GUI._show_progress!(o, eye - v + 0.5 * right, 0.5, "x")
        @test isempty(o.link[]) && isempty(vcat(dot[1][]))
        GUI._show_progress!(o, [NaN, NaN, NaN], 0.5, "x")
        @test isempty(o.link[])
        # hidden with the window
        GUI._show_progress!(o, look, 0.5, "x")
        GUI._hide_progress!(o)
        @test all(p -> !p.visible[], o.link_plots)
    end

    @testset "cancel button" begin
        o = GUI._ProgressOverlay(ax)
        button, text = o.plots[5], o.plots[6]
        @test only(vcat(text.text[])) == "Cancel"
        t = GUI._app_theme(:light)
        @test button.color[] == t.field
        GUI._show_progress!(o, [0.1, 0.2, 0.3], 0.5, "Tracing beams 50 %")
        # right of the bar, inside the panel
        r = GUI._cancel_rect(o)
        @test Makie.widths(r) == GUI._PROGRESS_CANCEL
        panel = Rect2f(o.anchor[] .+ GUI._PROGRESS_GAP, GUI._PROGRESS_PANEL)
        @test all(minimum(r) .> minimum(panel)) && all(maximum(r) .< maximum(panel))
        bar_end = o.anchor[][1] + GUI._PROGRESS_BAR_X + GUI._PROGRESS_TRACK[1]
        @test minimum(r)[1] ≈ bar_end + GUI._PROGRESS_CANCEL_GAP
        # the mouse [figure px] is over it only while the window is shown
        origin = Point2f(minimum(Makie.viewport(ax.scene)[]))
        center = Point2f(origin .+ minimum(r) .+ Makie.widths(r) ./ 2)
        @test GUI._over_cancel(o, center)
        @test !GUI._over_cancel(o, center .+ Point2f(0, GUI._PROGRESS_CANCEL[2]))
        @test !GUI._over_cancel(o, center .- Point2f(GUI._PROGRESS_CANCEL[1], 0))
        # hovered: highlighted; hiding the window ends it
        o.hovered[] = true
        @test button.color[] == t.hover
        GUI._hide_progress!(o)
        @test !o.hovered[] && button.color[] == t.field
        @test !GUI._over_cancel(o, center)
    end

    @testset "window stays in the view" begin
        scene = ax.scene
        w, h = Makie.widths(scene.viewport[])
        cam = cameracontrols(scene)
        eye, look = Vector(cam.eyeposition[]), Vector(cam.lookat[])
        v = normalize(look - eye)
        right = normalize(cross(v, Vector(cam.upvector[])))
        gap, margin, panel = GUI._PROGRESS_GAP, GUI._PROGRESS_MARGIN, GUI._PROGRESS_PANEL
        # The whole panel (from `gap` beyond the anchor on) lies inside the view with the margin
        inside(a) = all(a .+ gap .>= margin - 1e-3) &&
                    all(a .+ gap .+ panel .<= Vec2f(w, h) .- margin .+ 1e-3)
        # A point in the view: its projection
        a = GUI._screen_anchor(scene, look)
        q = Makie.project(scene, :data, :pixel, Point3f(look))
        @test a ≈ Point2f(q[1], q[2]) && inside(a)
        # Far to the right: at the right edge
        a = GUI._screen_anchor(scene, look + 1e3 * norm(look - eye) * right)
        @test inside(a) && a[1] ≈ w - margin - gap - panel[1]
        # Behind the camera, to the right: at the right edge (its projection is mirrored)
        a = GUI._screen_anchor(scene, eye - v + 0.5 * right)
        @test inside(a) && a[1] ≈ w - margin - gap - panel[1]
        # No position (NaN): at the bottom edge
        a = GUI._screen_anchor(scene, Point3f(NaN))
        @test inside(a) && a[2] ≈ margin - gap
    end
end

end
