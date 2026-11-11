module TestLiveActivityCues

using GLMakie, BeamletOptics, BeamletOpticsGUI
using Makie
using Test

const BMO = BeamletOptics
const GUI = BeamletOpticsGUI

@testset "Live activity cues" begin

    function _fixture()
        m1 = RoundPlanoMirror(0.0254, 0.006)
        m2 = RoundPlanoMirror(0.0254, 0.006)
        translate3d!(m2, [0.15, 0.1, 0])
        lens = SphericalLens(0.05, -0.05, 5e-3, 25.4e-3, ConstantRefractiveIndex(1.5))
        translate3d!(lens, [0, 0.12, 0])
        return (; m1, m2, lens)
    end

    function _live_view(fx; theme = :light)
        gui = live_view(System([fx.m1, fx.m2, fx.lens]), Beam([0.0, -0.05, 0], [0.0, 1, 0]);
            theme, detectors = [], trace_budget = Inf, throttle = false)
        screen = GLMakie.Screen(visible = false, start_renderloop = false)
        display(screen, gui.fig)
        Makie.colorbuffer(screen)
        return gui, screen
    end

    _frame(gui, obj) = GUI._bbox_wireframe(GUI._part_box(gui, obj))
    _pose(obj) = (Vector{Float64}(BMO.position(obj)), Matrix{Float64}(BMO.orientation(obj)))
    _shift(p, d) = (p[1] .+ d, p[2])
    _turn(p, deg) = (p[1], GUI._rotation_matrix([0.0, 0, 1], deg2rad(deg))' * p[2])

    # An item of the object `obj` of the kind `change`
    function _item(gui, obj, change; key = "u-$change")
        after = _pose(obj)
        f = _frame(gui, obj)
        change === :moved && return GUI._ActivityItem(key, :L1, change, _shift(after, [0.0, -0.03, 0]), after, f)
        change === :rotated && return GUI._ActivityItem(key, :L1, change, _turn(after, 40), after, f)
        change === :added && return GUI._ActivityItem(key, :L1, change, nothing, after, f)
        change === :removed && return GUI._ActivityItem(key, :L1, change, after, nothing, f)
        return GUI._ActivityItem(key, :L1, change, after, after, f)
    end
    _episode(items; n = 1, who = "claude@agent", name = "Claude", text = "moved L1 by 30 mm",
        message = "", count = 1) = GUI._Episode(n, who, name, true, 0.0, items, text, message, count)

    _drawn(gui) = GUI._cue_plots(gui).drawn
    _in(scene, p) = any(q -> q === p, scene.plots)
    _rgb(c) = (c = Makie.to_color(c); (Float32(c.r), Float32(c.g), Float32(c.b)))
    _alpha(c) = Float32(Makie.to_color(c).alpha)

    # The state of the plots of the components, which the cues must not change
    _component_plots(gui, fx) = [p for obj in values(fx) for p in GUI._object_plots(gui.controls.h, obj)]
    _state(p) = (p.color[], p.visible[], p.alpha[], p.transparency[])

    @testset "kinds of change" begin
        fx = _fixture()
        gui, screen = _live_view(fx)
        comps = _component_plots(gui, fx)
        @test !isempty(comps)
        before = IdDict(p => _state(p) for p in comps)
        nplots = length(gui.ax.scene.plots)
        expected = Dict(:moved => (:frames, :ghosts, :arcs, :heads), :rotated => (:frames, :ghosts, :arcs, :heads),
            :added => (:frames,), :removed => (:ghosts, :crosses), :changed => (:frames,),
            :grouped => (:frames,), :ungrouped => (:frames,), :system => (:frames,))
        all3d = (:frames, :ghosts, :arcs, :heads, :crosses)
        who = "claude@agent"
        for (n, (change, parts)) in enumerate(expected)
            ep = _episode([_item(gui, fx.lens, change)]; n)
            GUI._draw_cues!(gui, [(ep, 1.0)], 10.0)
            Makie.colorbuffer(screen)
            d = only(_drawn(gui))
            @test d.episode === ep
            for s in all3d
                @test haskey(d.plots, s) == (s in parts)
            end
            # the chip
            for s in (:background, :dot, :name, :text)
                @test haskey(d.plots, s)
            end
            @test GUI._label_text(d.plots[:text]) == " · moved L1 by 30 mm"
            @test GUI._label_text(d.plots[:name]) == "Claude"
            # the colour of the participant
            c = GUI._activity_color(gui, who)
            for s in (parts..., :dot)
                @test _rgb(d.plots[s].color[]) == _rgb(c)
            end
            # overlays only: in the 3D view, not clipped, not picked
            for (s, p) in d.plots
                @test p.inspectable[] == false
                @test isempty(p.clip_planes[])
                s in all3d ? @test(_in(gui.ax.scene, p)) : @test(_in(GUI._cue_plots(gui).hud, p))
                s in all3d && @test p.transparency[]
            end
            plots = collect(values(d.plots))
            # the cue ends with the end of its life: its plots are deleted
            GUI._draw_cues!(gui, Tuple{GUI._Episode, Float64}[], 20.0)
            @test isempty(_drawn(gui))
            @test !any(p -> _in(gui.ax.scene, p) || _in(GUI._cue_plots(gui).hud, p), plots)
        end
        # the arc of a move goes from the old to the new centre, lifted towards the camera's up vector
        ep = _episode([_item(gui, fx.lens, :moved)])
        GUI._draw_cues!(gui, [(ep, 1.0)], 10.0)
        d = only(_drawn(gui))
        arc = only(d.arcs)
        @test length(arc) == GUI._CUE_ARC_POINTS
        c1 = GUI._frame_center(_frame(gui, fx.lens))
        @test arc[end] ≈ c1 atol = 1e-6
        @test arc[1] ≈ c1 - Point3f(0, 0.03, 0) atol = 1e-6
        up = GUI._cue_up(gui)
        mid = arc[GUI._CUE_ARC_POINTS ÷ 2]
        lift = Vector{Float64}(mid - (arc[1] + arc[end]) / 2)
        @test sum(lift .* up) > 0
        # drawn out during `_CUE_IN`: partial at first, whole afterwards
        GUI._draw_cues!(gui, [(ep, 0.2)], 10.0 - 0.8)
        @test length(_drawn(gui)) == 1
        d = only(_drawn(gui))
        @test length(d.plots[:arcs][1][]) < GUI._CUE_ARC_POINTS
        GUI._draw_cues!(gui, [(ep, 0.8)], 10.0 - 0.2)
        @test length(d.plots[:arcs][1][]) == GUI._CUE_ARC_POINTS
        @test length(d.plots[:heads][1][]) == 1
        # a cue that is not passed any more is deleted
        GUI._draw_cues!(gui, Tuple{GUI._Episode, Float64}[], 10.0)
        @test isempty(_drawn(gui))
        # the components: the same plots, unchanged
        Makie.colorbuffer(screen)
        @test length(gui.ax.scene.plots) == nplots
        @test _component_plots(gui, fx) == comps
        @test all(p -> _state(p) == before[p], comps)
        close(screen)
    end

    @testset "alpha over the life" begin
        fx = _fixture()
        gui, screen = _live_view(fx)
        ep = _episode([_item(gui, fx.lens, :moved)])
        start = 100.0
        life = GUI._CUE_IN + GUI._CUE_HOLD + GUI._CUE_OUT
        for age in (0.0, 0.1, 0.3, 0.6, 1.0, 2.0, 2.5, 3.0)
            GUI._draw_cues!(gui, [(ep, age)], start + age)
            d = only(_drawn(gui))
            a = GUI._cue_alpha(age)
            @test _alpha(d.plots[:frames].color[]) ≈ a atol = 1e-6
            @test _alpha(d.plots[:arcs].color[]) ≈ a atol = 1e-6
            @test _alpha(d.plots[:ghosts].color[]) ≈ GUI._CUE_GHOST_ALPHA * a atol = 1e-6
            @test _alpha(d.plots[:text].color[]) ≈ a atol = 1e-6
            @test _alpha(d.plots[:name].color[]) ≈ a atol = 1e-6
            @test _alpha(d.plots[:background].color[]) ≈ GUI._CHIP_BACKGROUND_ALPHA * a atol = 1e-6
        end
        # the same cue all along: its plots were created once
        @test length(_drawn(gui)) == 1
        GUI._draw_cues!(gui, [(ep, life + 0.01)], start + life + 0.01)
        @test isempty(_drawn(gui))
        close(screen)
    end

    @testset "summary, message, several cues" begin
        fx = _fixture()
        gui, screen = _live_view(fx)
        items = [_item(gui, fx.lens, :moved; key = "a"), _item(gui, fx.m2, :rotated; key = "b"),
            _item(gui, fx.m1, :added; key = "c")]
        summary = _episode(items; n = 0, text = "14 changes (3 objects)", count = 14)
        GUI._draw_cues!(gui, [(summary, 1.0)], 10.0)
        d = only(_drawn(gui))
        @test d.summary
        # one chip for all objects; their frames and arcs in a few plots
        @test count(s -> s === :background, keys(d.plots)) == 1
        @test GUI._label_text(d.plots[:text]) == " · 14 changes (3 objects)"
        @test length(d.plots[:frames][1][]) == 3 * 24
        @test length(d.arcs) == 2
        # at lower alpha
        @test _alpha(d.plots[:frames].color[]) ≈ GUI._CUE_SUMMARY_ALPHA * GUI._cue_alpha(1.0) atol = 1e-6
        @test _alpha(d.plots[:text].color[]) ≈ GUI._cue_alpha(1.0) atol = 1e-6
        GUI._clear_cues!(gui)
        @test isempty(_drawn(gui))

        # a summary of several participants is drawn in the muted colour of the theme
        several = _episode(items; n = 0, who = "several", name = "several", text = "3 changes", count = 3)
        GUI._draw_cues!(gui, [(several, 1.0)], 10.0)
        @test _rgb(only(_drawn(gui)).plots[:frames].color[]) == _rgb(gui.layout.theme.muted)
        @test !haskey(GUI._activity(gui).colors, "several")
        GUI._clear_cues!(gui)

        # a message: a bubble with the colour at its left edge, wrapped
        text = "aligning the fold mirror M1 to the beam, then checking the focus on the detector and the spot size of the second camera while waiting for the next solve"
        msg = _episode([_item(gui, fx.m1, :changed)]; n = 2, who = "bob@PC3", name = "Bob", text = "", message = text)
        GUI._draw_cues!(gui, [(msg, 1.0)], 10.0)
        d = only(_drawn(gui))
        @test d.bubble
        @test haskey(d.plots, :bar) && !haskey(d.plots, :dot)
        @test _rgb(d.plots[:bar].color[]) == _rgb(GUI._activity_color(gui, "bob@PC3"))
        lines = split(GUI._label_text(d.plots[:text]), '\n')
        @test length(lines) == GUI._BUBBLE_LINES
        @test all(l -> length(l) <= GUI._BUBBLE_WRAP, lines)
        @test endswith(lines[end], "…")
        # a message without an object: at the corner of the view
        GUI._clear_cues!(gui)
        alone = _episode(GUI._ActivityItem[]; n = 3, who = "bob@PC3", name = "Bob", text = "", message = "back in 5")
        GUI._draw_cues!(gui, [(alone, 1.0)], 10.0)
        d = only(_drawn(gui))
        @test !isempty(d.plots)
        @test all(isfinite, d.pos[])

        # several cues at once at one object stack their chips
        GUI._clear_cues!(gui)
        e1 = _episode([_item(gui, fx.lens, :moved)]; n = 4)
        e2 = _episode([_item(gui, fx.lens, :changed)]; n = 5, text = "changed L1")
        GUI._draw_cues!(gui, [(e1, 1.5), (e2, 0.6)], 10.0)
        d1, d2 = _drawn(gui)
        @test d1.slot != d2.slot
        @test d1.pos[] != d2.pos[]
        # a replay of the episode while its cue is still shown: a cue of its own
        GUI._draw_cues!(gui, [(e1, 1.6), (e2, 0.7), (e1, 0.0)], 10.1)
        @test length(_drawn(gui)) == 3
        GUI._clear_cues!(gui)
        close(screen)
    end

    @testset "spectator mode" begin
        fx = _fixture()
        gui, screen = _live_view(fx)
        ep = _episode([_item(gui, fx.lens, :moved)])
        spectator!(gui, true)
        GUI._draw_cues!(gui, [(ep, 1.0)], 10.0)
        d = only(_drawn(gui))
        for s in (:background, :dot, :name, :text)
            @test !d.plots[s].visible[]
        end
        for s in (:frames, :ghosts, :arcs, :heads)
            @test d.plots[s].visible[]
        end
        spectator!(gui, false)
        GUI._draw_cues!(gui, [(ep, 1.1)], 10.1)
        @test all(s -> d.plots[s].visible[], (:background, :dot, :name, :text))
        close(screen)
    end

    # The contrast of two colours (WCAG)
    _lum(c) = (f(x) = x <= 0.03928 ? x / 12.92 : ((x + 0.055) / 1.055)^2.4;
        0.2126 * f(c.r) + 0.7152 * f(c.g) + 0.0722 * f(c.b))
    _contrast(a, b) = ((x, y) = extrema((_lum(a), _lum(b))); (y + 0.05) / (x + 0.05))
    # A colour `c` with alpha over the opaque `under`
    _over(c, under) = (a = Makie.to_color(c).alpha; RGBf((a .* _rgb(c) .+ (1 - a) .* _rgb(under))...))

    @testset "readable text ($theme)" for theme in (:light, :dark)
        fx = _fixture()
        gui, screen = _live_view(fx; theme)
        msg = _episode([_item(gui, fx.m1, :changed)]; n = 2, text = "", message = "checking the focus")
        ep = _episode([_item(gui, fx.lens, :moved)])
        GUI._draw_cues!(gui, [(ep, 1.0), (msg, 1.0)], 10.0)
        for d in _drawn(gui)
            # the background over whatever lies behind it, black or white
            for under in (RGBf(0, 0, 0), RGBf(1, 1, 1))
                bg = _over(d.plots[:background].color[], under)
                for s in (:name, :text)
                    @test _contrast(_over(d.plots[s].color[], bg), bg) >= 4.5
                end
            end
        end
        img = Makie.colorbuffer(screen)
        @test img isa AbstractMatrix
        close(screen)
    end

    @testset "scrub" begin
        fx = _fixture()
        gui, screen = _live_view(fx)
        gui.sync.ids[fx.lens] = (:L1, "u1")
        gui.sync.ids[fx.m2] = (:M2, "u2")
        gui.sync.ids[fx.m1] = (:M1, "u3")
        a = GUI._activity(gui)
        lens_before = _shift(_pose(fx.lens), [0.0, -0.03, 0])
        m2_before = _turn(_pose(fx.m2), 30)
        push!(a.episodes, GUI._Episode(1, "bob@PC3", "Bob", false, 5.0,
            [GUI._ActivityItem("u1", :L1, :moved, lens_before, _pose(fx.lens), _frame(gui, fx.lens))], "moved L1", "", 1))
        push!(a.episodes, GUI._Episode(2, "claude@agent", "Claude", true, 6.0,
            [GUI._ActivityItem("u2", :M2, :rotated, m2_before, _pose(fx.m2), _frame(gui, fx.m2))], "rotated M2", "", 1))
        # a removed object, not in the view any more
        gone = (Vector{Float64}([0.3, 0.0, 0.0]), Matrix{Float64}(BMO.orientation(fx.m1)))
        gone_frame = GUI._move_points(_frame(gui, fx.m1), _pose(fx.m1), gone)
        push!(a.episodes, GUI._Episode(3, "claude@agent", "Claude", true, 7.0,
            [GUI._ActivityItem("u9", :M9, :removed, gone, nothing, gone_frame)], "removed M9", "", 1))
        a.cursor = 4.0
        comps = _component_plots(gui, fx)
        before = IdDict(p => _state(p) for p in comps)
        # one ghost frame per key whose pose differs from now; m1 is where it is
        poses = Dict("u1" => lens_before, "u2" => m2_before, "u3" => _pose(fx.m1), "u9" => gone)
        GUI._draw_scrub!(gui, poses)
        c = GUI._cue_plots(gui)
        @test c.scrub_keys == ["u1", "u2", "u9"]
        pts = c.scrub[1][]
        @test length(pts) == 3 * 24
        # the ghost of the lens is its frame 30 mm lower
        @test pts[1:24] ≈ [p - Point3f(0, 0.03, 0) for p in _frame(gui, fx.lens)] atol = 1e-6
        @test pts[49:72] ≈ gone_frame atol = 1e-6
        # in the colour of who changed it after the cursor
        @test _rgb(c.scrub.color[][1]) == _rgb(GUI._activity_color(gui, "bob@PC3"))
        @test _rgb(c.scrub.color[][25]) == _rgb(GUI._activity_color(gui, "claude@agent"))
        @test c.scrub.inspectable[] == false && isempty(c.scrub.clip_planes[])
        Makie.colorbuffer(screen)
        # an update reuses the plot
        p = c.scrub
        GUI._draw_scrub!(gui, Dict("u1" => lens_before))
        @test c.scrub === p && length(p[1][]) == 24
        GUI._draw_scrub!(gui, nothing)
        @test isnothing(c.scrub) && isempty(c.scrub_keys)
        @test !_in(gui.ax.scene, p)
        @test all(p -> _state(p) == before[p], comps)
        close(screen)
    end

    @testset "wrap and presence colour" begin
        @test GUI._wrap_text("short") == ["short"]
        @test GUI._wrap_text("one two three", 7) == ["one two", "three"]
        @test GUI._wrap_text("a" ^ 12, 5, 3) == ["aaaaa", "aaaaa", "aa"]
        w = GUI._wrap_text(repeat("word ", 40), 10, 3)
        @test length(w) == 3 && endswith(w[end], "…") && all(l -> length(l) <= 10, w)
        @test GUI._wrap_text("") == String[]
        gui = live_view(System([RoundPlanoMirror(0.02, 0.004)]))
        @test GUI._presence_color(gui, "bob@PC3") == GUI._activity_color(gui, "bob@PC3")
    end
end

end
