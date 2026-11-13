module TestLiveTimeline

using GLMakie, BeamletOptics, BeamletOpticsGUI
using Makie
using Test

const GUI = BeamletOpticsGUI

@testset "Live timeline" begin

    function _view(layout; theme = :light)
        lens = SphericalLens(0.05, -0.05, 5e-3, 25.4e-3, ConstantRefractiveIndex(1.5))
        translate3d!(lens, [0, 0.1, 0])
        m = RoundPlanoMirror(25e-3, 5e-3)
        translate3d!(m, [0, 0.2, 0])
        gui = live_view(System([lens, m]) => Beam([0.0, 0, 0], [0.0, 1, 0]); layout, theme,
            size = (1300, 800), throttle = false, detectors = [], trace_budget = Inf)
        screen = GLMakie.Screen(visible = false, start_renderloop = false)
        display(screen, gui.fig)
        @test_logs min_level = Base.CoreLogging.Warn Makie.colorbuffer(screen)
        return gui, screen, lens, m
    end

    I3 = [1.0 0 0; 0 1 0; 0 0 1]
    _item(key) = GUI._ActivityItem(key, Symbol(key), :moved, ([0.0, 0.1, 0], I3), ([0.0, 0.11, 0], I3),
        Point3f[(-0.01, 0.1, -0.01), (0.01, 0.12, 0.01)])

    ev(gui) = events(gui.ax.scene)
    move!(gui, p) = (ev(gui).mouseposition[] = (Float64(p[1]), Float64(p[2])))
    press!(gui, b = Mouse.left) = (ev(gui).mousebutton[] = Makie.MouseButtonEvent(b, Mouse.press))
    release!(gui, b = Mouse.left) = (ev(gui).mousebutton[] = Makie.MouseButtonEvent(b, Mouse.release))
    click!(gui, p) = (move!(gui, p); press!(gui); release!(gui))
    center(r) = Point2f(minimum(r) .+ Makie.widths(r) ./ 2)
    inside(r, vp) = all(minimum(r) .>= minimum(vp) .- 0.5) && all(maximum(r) .<= maximum(vp) .+ 0.5)
    hits(tl, kind) = [h for h in tl.hits if h[2] === kind]
    eye_of(gui) = Vector{Float64}(cameracontrols(gui.ax.scene).eyeposition[])
    viewport(gui) = Rect2f(gui.ax.scene.viewport[])
    # the shown entries of a scatter: those not parked at (-100, -100)
    shown(plot) = count(p -> p[1] > -50, plot[1][])
    # the text of the tooltip
    tiptext(tl) = (s = tl.plots.tip_text.text[]; s isa AbstractString ? s : only(s))

    @testset "strip ($layout)" for layout in (:compact, :app)
        gui, screen, lens, m = _view(layout)
        a = GUI._activity(gui)
        tl = GUI._timeline!(gui)
        @test GUI._timeline!(gui) === tl
        @test a.strip === tl
        t0 = 1.0e9

        # hidden until an other was there
        GUI._update_timeline!(gui, t0)
        @test !tl.scene.visible[] && !tl.shown

        # Bob and Claude (an agent), 40 s apart: separate marks on the axis of 5 min; a message
        rec(who, name, agent, key, text, t; message = "") =
            GUI._record_episode!(gui, who, name, agent, [_item(key)]; text, message, now = t)
        rec("Bob@PC3", "Bob", false, "L1", "moved L1 by 4 mm", t0)
        rec("claude@agent", "Claude", true, "M2", "moved M2 by 12 mm", t0 + 40)
        rec("Bob@PC3", "Bob", false, "M1", "rotated M1 by 2°", t0 + 80)
        rec("claude@agent", "Claude", true, "M2", "", t0 + 120; message = "aligning")
        now = t0 + 150
        GUI._update_timeline!(gui, now)
        @test tl.scene.visible[] && tl.shown
        vp = viewport(gui)
        r = tl.rect

        # collapsed: one line at the bottom of the 3D view, inside it, clear of the layout
        @test Makie.widths(r)[2] == GUI._TL_COLLAPSED
        @test minimum(r)[2] ≈ minimum(vp)[2] + GUI._TL_MARGIN
        @test Makie.widths(r)[1] <= GUI._TL_MAX_WIDTH
        @test inside(r, vp)
        bottom = [o for o in GUI._layout_obstacles(gui) if minimum(o)[2] < maximum(r)[2]]
        @test all(o -> !Makie.overlaps(o, r), bottom)
        # the names and last texts with their ages, the latest first
        @test tl.plots.names.text[] == ["Claude", "Bob"]
        details = tl.plots.details.text[]
        @test occursin("aligning", details[1]) && occursin("30 s", details[1])
        @test occursin("rotated M1 by 2°", details[2]) && occursin("1 min", details[2])
        @test shown(tl.plots.dots) == 2
        @test_logs min_level = Base.CoreLogging.Warn Makie.colorbuffer(screen)

        # hover a participant: its last episode, the tooltip
        seg = hits(tl, :mark)
        @test length(seg) == 2
        move!(gui, center(seg[2][1]))
        @test a.hover == 3
        GUI._update_timeline!(gui, now)
        @test tl.plots.tip_box.visible[]
        @test occursin("Bob", tiptext(tl)) && occursin("rotated M1", tiptext(tl))
        move!(gui, center(vp))
        @test isnothing(a.hover)
        GUI._update_timeline!(gui, now)
        @test !tl.plots.tip_box.visible[]

        # a click on the line expands it; nothing reaches the 3D view: the selection stays
        GUI._select!(gui, lens)
        eye0 = eye_of(gui)
        click!(gui, center(r))
        @test a.expanded
        @test gui.controls.selected[] === lens
        @test eye_of(gui) ≈ eye0
        r = tl.rect
        @test Makie.widths(r)[2] ≈ GUI._tl_expanded_height(2)
        @test 90 <= Makie.widths(r)[2] <= 120
        @test inside(r, viewport(gui))

        # one lane per participant (eye, dot, name), one mark per episode
        @test length(hits(tl, :eye)) == 2
        @test [h[3] for h in hits(tl, :eye)] == ["Bob@PC3", "claude@agent"]
        @test tl.plots.names.text[] == ["Bob", "Claude"]
        marks = hits(tl, :mark)
        @test sort([only(h[3]) for h in marks]) == [1, 2, 3, 4]
        @test shown(tl.plots.marks) == 4
        @test !tl.plots.pills.visible[]
        # the message is a speech bubble, the changes are dots
        @test count(==(GUI._TL_SPEECH), tl.plots.marks.marker[]) == 1
        # the participant's color
        k = findfirst(h -> only(h[3]) == 2, marks)
        @test RGBAf(GUI._activity_color(gui, "claude@agent")) in tl.plots.marks.color[]
        # newer is further right, "now" at the right edge
        x(n) = center(marks[findfirst(h -> only(h[3]) == n, marks)][1])[1]
        @test x(1) < x(2) < x(3) < x(4) < tl.axis[2]
        @test tl.axis[2] - x(4) ≈ 30 / 300 * (tl.axis[2] - tl.axis[1]) atol = 1
        @test_logs min_level = Base.CoreLogging.Warn Makie.colorbuffer(screen)

        # hover a mark: it grows, its tooltip with the time, `activity.hover`
        move!(gui, center(marks[k][1]))
        @test a.hover == 2
        GUI._update_timeline!(gui, now)
        @test maximum(m -> m[1], tl.plots.marks.markersize[]) > GUI._TL_MARK
        tip = tiptext(tl)
        @test startswith(tip, "Claude · " * GUI._tl_clock(t0 + 40)) && endswith(tip, "moved M2 by 12 mm")
        # above the strip
        @test minimum(Rect2f(tl.plots.tip_box[1][]))[2] >= maximum(tl.rect)[2]

        # a click plays its cue again
        empty!(a.cues)
        click!(gui, center(marks[k][1]))
        @test any(c -> c[1].n == 2, a.cues)
        @test gui.controls.selected[] === lens
        # a double click frames its objects
        @test isnothing(gui.camera.animation)
        click!(gui, center(marks[k][1]))
        @test !isnothing(gui.camera.animation)
        @test gui.camera.animation.lookat1 ≈ [0.0, 0.11, 0.0] atol = 1.0e-6
        gui.camera.animation = nothing
        eye0 = eye_of(gui)

        # a drag in the lanes scrubs: the cursor follows the mouse, releasing ends it
        lanes = only(hits(tl, :lanes))[1]
        y = center(lanes)[2]
        move!(gui, (tl.axis[1] + 100, y))
        press!(gui)
        @test isnothing(a.cursor)
        move!(gui, (tl.axis[1] + 140, y))
        c1 = a.cursor
        @test !isnothing(c1)
        @test c1 ≈ GUI._tl_time_at(tl, tl.axis[1] + 140)
        @test tl.plots.cursor.visible[]
        move!(gui, (tl.axis[2] - 10, y))
        @test a.cursor > c1
        # the cursor stays on the axis when the mouse leaves the strip
        move!(gui, (tl.axis[2] + 400, y + 300))
        @test a.cursor ≈ now
        release!(gui)
        @test isnothing(a.cursor)
        @test !tl.plots.cursor.visible[]
        @test eye_of(gui) ≈ eye0
        @test gui.controls.selected[] === lens

        # the eye follows its participant, again stops
        eye = hits(tl, :eye)[2]
        click!(gui, center(eye[1]))
        @test a.follow == "claude@agent"
        @test tl.plots.eyes.marker[][2] == GUI._icon(:eye)
        click!(gui, center(hits(tl, :eye)[1][1]))
        @test a.follow == "Bob@PC3"
        click!(gui, center(hits(tl, :eye)[1][1]))
        @test isnothing(a.follow)

        # the wheel zooms within 1 min … 1 h, the camera does not get it
        move!(gui, center(lanes))
        ev(gui).scroll[] = (0.0, 1.0)
        @test tl.span < GUI._TL_SPAN
        for _ in 1:30
            ev(gui).scroll[] = (0.0, 1.0)
        end
        @test tl.span == GUI._TL_SPAN_MIN
        GUI._update_timeline!(gui, now)
        @test occursin("60 s", join(tl.plots.labels.text[]))
        for _ in 1:40
            ev(gui).scroll[] = (0.0, -1.0)
        end
        @test tl.span == GUI._TL_SPAN_MAX
        @test eye_of(gui) ≈ eye0
        tl.span = GUI._TL_SPAN

        # marks closer than a few pixels become one pill with their count
        for i in 1:9
            rec("claude@agent", "Claude", true, "M2", "moved M2 by $i mm", now + i * 0.05)
        end
        now += 1
        GUI._update_timeline!(gui, now)
        @test tl.plots.pills.visible[]
        @test "9" in tl.plots.labels.text[]
        pill = only(h for h in hits(tl, :mark) if length(h[3]) == 9)
        move!(gui, center(pill[1]))
        @test a.hover == 13
        GUI._update_timeline!(gui, now)
        @test occursin("9 changes", tiptext(tl))

        # the right button and its drags over the strip do not reach the camera either
        move!(gui, center(lanes))
        press!(gui, Mouse.right)
        move!(gui, center(lanes) .+ (60, 0))
        release!(gui, Mouse.right)
        @test eye_of(gui) ≈ eye0

        # the head collapses it again
        click!(gui, center(only(hits(tl, :toggle))[1]))
        @test !a.expanded
        @test Makie.widths(tl.rect)[2] == GUI._TL_COLLAPSED

        # hidden in the spectator mode, shown again after it
        spectator!(gui)
        GUI._update_timeline!(gui, now)
        @test !tl.scene.visible[]
        spectator!(gui, false)
        GUI._update_timeline!(gui, now)
        @test tl.scene.visible[]

        # inside the 3D view when the window or a sidebar is resized
        GUI._set_expanded!(gui, true)
        for sz in ((1000, 650), (1600, 900), (1100, 600))
            resize!(gui.fig, sz...)
            Makie.colorbuffer(screen)
            GUI._update_timeline!(gui, now)
            @test tl.shown
            @test inside(tl.rect, viewport(gui))
            @test Makie.widths(tl.rect)[1] <= GUI._TL_MAX_WIDTH
        end
        if layout === :app
            w0 = Makie.widths(viewport(gui))[1]
            GUI._set_shown!(gui.layout.left, false)
            Makie.colorbuffer(screen)
            GUI._update_timeline!(gui, now)
            @test Makie.widths(viewport(gui))[1] > w0
            @test inside(tl.rect, viewport(gui))
            # centered in the 3D view
            @test center(tl.rect)[1] ≈ center(viewport(gui))[1] atol = 1
        end
        @test_logs min_level = Base.CoreLogging.Warn Makie.colorbuffer(screen)
        close(screen)
    end

    @testset "dark theme" begin
        gui, screen, _, _ = _view(:compact; theme = :dark)
        tl = GUI._timeline!(gui)
        GUI._record_episode!(gui, "Bob@PC3", "Bob", false, [_item("L1")]; text = "moved L1", now = 1.0e9)
        GUI._update_timeline!(gui, 1.0e9 + 2)
        t = gui.layout.theme
        @test tl.plots.panel.color[] == GUI._rgba(t.view, GUI._TL_ALPHA)
        @test tl.plots.names.color[] == [RGBAf(t.text)]
        @test only(tl.plots.details.text[]) == "moved L1 · now"
        @test_logs min_level = Base.CoreLogging.Warn Makie.colorbuffer(screen)
        close(screen)
    end

    @testset "texts" begin
        @test GUI._tl_age(0) == "now"
        @test GUI._tl_age(12.7) == "12 s"
        @test GUI._tl_age(185) == "3 min"
        @test GUI._tl_age(3700) == "1 h"
        @test occursin(r"^\d\d:\d\d:\d\d$", GUI._tl_clock(1.0e9))
        @test GUI._tl_tick_label(0) == "now"
        @test GUI._tl_tick_label(30) == "30 s"
        @test GUI._tl_tick_label(120) == "2 min"
        @test GUI._tl_span_label(300) == "5 min"
        @test GUI._tl_span_label(3600) == "1 h"
    end
end

end
