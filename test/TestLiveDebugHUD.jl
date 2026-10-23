module TestLiveDebugHUD

using GLMakie, BeamletOptics, BeamletOpticsGUI
using Makie
using Test

const BMO = BeamletOptics
const GUI = BeamletOpticsGUI

@testset "Debug card" begin
    # Rays along +y, the mirror at 45° reflects them along +x onto the detector
    function _fixture(; kwargs...)
        m = RoundPlanoMirror(25e-3, 5e-3)
        zrotate3d!(m, deg2rad(45))
        translate3d!(m, [0, 0.1, 0])
        pd = Detector(5e-3)
        zrotate3d!(pd, -π / 2)
        translate3d!(pd, [0.1, 0.1, 0])
        cs = CollimatedSource([0.0, 0, 0], [0.0, 1, 0], 2e-3, 1e-6; num_rings = 2, num_rays = 40)
        gui = live_view(System([m, pd]) => cs; trace_budget = Inf, throttle = false,
            catalog = CatalogEntry[], detectors = [], kwargs...)
        return gui, m, pd
    end
    # A tick of the window at the time `t` [s], straight to the layers of the debug mode, such that
    # it does not depend on the listener of the ticks
    _tick!(gui, t; state = Makie.RegularRenderTick) =
        GUI._debug_tick!(gui, Makie.Tick(state, 0, Float64(t), 1 / 30))
    _hud(gui) = GUI._debug_layer(gui, :hud)
    _rect(x) = Rect2f(x.layoutobservables.computedbbox[])
    _view(gui) = Rect2f(Makie.viewport(gui.ax.scene)[])
    _row(sections, name, key) = Dict(Dict(sections)[name])[key]
    # The labels of the rows of the card: the keys and values, the items of a legend and their dots
    _labels(hud) = Label[l for c in hud.cells if c isa Tuple for l in (c[1], (c[2] isa Label ? (c[2],) : c[2])...)]
    # The texts of the values of the rows of the card by their key
    _values(hud) = Dict(c[1].text[] => (c[2] isa Label ? c[2].text[] : join((l.text[] for l in c[2]), " · "))
                        for c in hud.cells if c isa Tuple)
    _record(; kind = :full, sources = ["Beam" => 0.041]) =
        GUI._SolveRecord(time(), kind, 0.041, 0.0102, 0.0, sources, 0.0, 0.0004, 3_355_443)

    @testset "shows and hides with the mode, at the top left of the 3D view" begin
        gui, _, _ = _fixture()
        @test isnothing(_hud(gui))
        GUI._set_debug!(gui, true)
        hud = _hud(gui)
        @test hud isa GUI._DebugHUD
        @test hud.scene.visible[] && hud.shown
        r, vp = _rect(hud.background), _view(gui)
        @test minimum(r)[1] ≈ minimum(vp)[1] + GUI._HUD_LEFT
        @test maximum(r)[2] ≈ maximum(vp)[2] - GUI._HUD_TOP
        @test Makie.widths(r)[1] > 100 && Makie.widths(r)[2] > 100
        # the head and the body lie inside the background
        for part in (hud.head, hud.body)
            p = _rect(part)
            @test minimum(r)[1] < minimum(p)[1] && maximum(p)[1] < maximum(r)[1]
            @test minimum(r)[2] < minimum(p)[2] && maximum(p)[2] < maximum(r)[2]
        end
        # idempotent: switched on again, the same card, still shown
        GUI._set_debug!(gui, true)
        GUI._debug_show!(gui)
        @test _hud(gui) === hud && hud.scene.visible[]
        @test _rect(hud.background) ≈ r

        GUI._set_debug!(gui, false)
        @test !hud.scene.visible[] && !hud.shown
        @test hud.background.layoutobservables.suggestedbbox[] == GUI._CARD_AWAY
        # the dispatcher of the ticks does nothing while the mode is off
        n = hud.refreshes
        _tick!(gui, 5.0)
        @test hud.refreshes == n
        GUI._set_debug!(gui, true)
        # at the same place; the event "debug mode on" adds a row, which makes it higher
        r1 = _rect(hud.background)
        @test hud.scene.visible[]
        @test minimum(r1)[1] ≈ minimum(r)[1] && maximum(r1)[2] ≈ maximum(r)[2]
        close(gui)
    end

    @testset "hides in the spectator mode" begin
        gui, _, _ = _fixture()
        GUI._set_debug!(gui, true)
        hud = _hud(gui)
        spectator!(gui)
        GUI._debug_show!(gui)
        @test !hud.scene.visible[]
        # ticks are counted, but the hidden card is not refreshed
        n = hud.refreshes
        _tick!(gui, 1.0)
        @test hud.refreshes == n && length(hud.frames) == 1
        spectator!(gui, false)
        GUI._debug_show!(gui)
        @test hud.scene.visible[]
        close(gui)
    end

    @testset "an overlay: its own scene, not picked, fitted or clipped" begin
        gui, _, _ = _fixture()
        GUI._set_debug!(gui, true)
        hud = _hud(gui)
        @test hud.scene.parent === gui.fig.scene
        plots = Makie.collect_atomic_plots(hud.scene)
        @test !isempty(plots)
        # nothing of the card in the scene of the 3D view, whose plots are picked, fitted and clipped
        in3d = Makie.collect_atomic_plots(gui.ax.scene)
        @test !any(p -> any(q -> q === p, in3d), plots)
        pickable = [p for h in BMO.render_children(gui.pool) for p in GUI._pickable_plots(h)]
        @test !isempty(pickable)
        @test !any(p -> any(q -> q === p, plots), pickable)
        # in front of the 3D view and below the component cards and the help card
        z = hud.scene.transformation.translation[][3]
        @test 0 < z < GUI._CARD_Z0 && z < GUI._HELP_Z
        close(gui)
    end

    @testset "the cards keep off it, the controls and the camera do not get its mouse" begin
        gui, m, _ = _fixture()
        ev = events(gui.ax.scene)
        _move!(xy) = (ev.mouseposition[] = (Float64(xy[1]), Float64(xy[2])))
        _click!(xy) = (_move!(xy); ev.mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.press);
                       ev.mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.release))
        _eye() = Makie.cameracontrols(gui.ax.scene).eyeposition[]
        _center(r) = Point2f(minimum(r) .+ Makie.widths(r) ./ 2)
        # no card yet
        @test isempty(GUI._debug_obstacles(gui)) && !GUI._over_debug(gui)

        GUI._set_debug!(gui, true)
        hud = _hud(gui)
        r = _rect(hud.background)
        @test GUI._debug_obstacles(gui) == [r]
        _move!(_center(r))
        @test GUI._over_debug(gui)
        _move!(_center(_view(gui)) .+ Point2f(0, -100))
        @test !GUI._over_debug(gui)

        # wired by the lead in src/LiveCards.jl: the obstacles of the cards, `ignore_mouse` of the
        # controls and the mouse shield of the cards
        @test any(o -> o ≈ r, GUI._obstacles(gui))
        _move!(_center(r))
        @test gui.controls.ignore_mouse()
        # a click on the card does not deselect
        select!(gui, m)
        _click!(_center(r))
        @test gui.controls.selected[] === m
        # the camera does not zoom by scrolling over the card, but beside it
        eye = _eye()
        ev.scroll[] = (0.0, 1.0)
        @test _eye() == eye
        _move!(_center(_view(gui)) .+ Point2f(0, -100))
        ev.scroll[] = (0.0, 1.0)
        @test _eye() != eye
        # the card of the selection keeps off the debug card
        GUI._update_cards!(gui)
        c = gui.cards.selection
        if c.scene.visible[]
            cr = _rect(c.background)
            @test !(all(minimum(cr) .< maximum(r)) && all(minimum(r) .< maximum(cr)))
        end

        # hidden: neither obstacle nor shield
        spectator!(gui)
        GUI._debug_show!(gui)
        @test isempty(GUI._debug_obstacles(gui))
        _move!(_center(r))
        @test !GUI._over_debug(gui)
        spectator!(gui, false)
        GUI._debug_show!(gui)
        @test GUI._over_debug(gui)
        GUI._set_debug!(gui, false)
        @test isempty(GUI._debug_obstacles(gui)) && !GUI._over_debug(gui)
        close(gui)
    end

    @testset "refreshes at most 4× per second, assigns only changed texts" begin
        gui, _, _ = _fixture()
        GUI._set_debug!(gui, true)
        hud = _hud(gui)
        d = GUI._debug(gui)
        # ticks every 10 ms for 1 s of tick time
        n = hud.refreshes
        for k in 101:200
            _tick!(gui, k / 100)
        end
        @test 3 <= hud.refreshes - n <= 4
        # without new frames and stats, the texts stay: no assignment for 2 s of ticks without
        # drawing, after the frames of the last second have run out (no events, whose age changes)
        empty!(d.stats.events)
        for k in 1:20
            _tick!(gui, 2.0 + k / 10; state = Makie.SkippedRenderTick)
        end
        @test _values(hud)["frames"] == "0 /s"
        assigned = Ref(0)
        listeners = [on(_ -> assigned[] += 1, l.text) for l in _labels(hud)]
        n = hud.refreshes
        for k in 1:20
            _tick!(gui, 4.0 + k / 10; state = Makie.SkippedRenderTick)
        end
        @test hud.refreshes - n >= 4
        @test assigned[] == 0
        # a drag step changes its row only
        d.stats.update = 0.0041
        _tick!(gui, 7.0; state = Makie.SkippedRenderTick)
        @test assigned[] == 1
        @test _values(hud)["drag step"] == "4.1 ms (max 4.1 ms)"
        foreach(off, listeners)
        close(gui)
    end

    @testset "frames count only RegularRenderTick" begin
        gui, _, _ = _fixture()
        GUI._set_debug!(gui, true)
        hud = _hud(gui)
        # 30 frames per second, and between them ticks without drawing
        for k in 1:60
            _tick!(gui, k / 30)
            _tick!(gui, k / 30 + 0.01; state = Makie.SkippedRenderTick)
            _tick!(gui, k / 30 + 0.02; state = Makie.PausedRenderTick)
        end
        @test length(hud.frames) == 30
        rows = GUI._hud_rows(gui, GUI._debug(gui), Val(:frames))
        @test Dict(rows)["frames"] == "30 /s · 33.3 ms"
        GUI._hud_refresh!(gui, hud)
        @test _values(hud)["frames"] == "30 /s · 33.3 ms"
        # the largest drag step of the last 2 s
        d = GUI._debug(gui)
        d.stats.update = 0.0098
        _tick!(gui, 3.0)
        d.stats.update = 0.0041
        _tick!(gui, 4.0)
        @test Dict(GUI._hud_rows(gui, d, Val(:frames)))["drag step"] == "4.1 ms (max 9.8 ms)"
        _tick!(gui, 5.5)
        @test Dict(GUI._hud_rows(gui, d, Val(:frames)))["drag step"] == "4.1 ms (max 4.1 ms)"
        @test hud.plots > 0
        w, h = round.(Int, Makie.widths(Makie.viewport(gui.fig.scene)[]))
        @test startswith(Dict(GUI._hud_rows(gui, d, Val(:frames)))["plots"], "$(hud.plots) · $(w)×$(h)")
        close(gui)
    end

    @testset "every section from hand-made stats" begin
        gui, m, pd = _fixture()
        t = gui.layout.theme
        # an empty debug mode without a card: every section has rows
        empty = GUI._Debug()
        sections = GUI._hud_sections(gui, empty)
        @test first.(sections) == collect(first.(GUI._HUD_SECTIONS))
        @test all(!isempty(last(s)) for s in sections)
        @test !any(r -> first(r) == "error", (r for s in sections for r in last(s)))
        @test _row(sections, :frames, "frames") == "–"
        @test _row(sections, :solve, "solve") == "–  (budget none)"
        @test _row(sections, :solve, "slowest") == "–"
        @test _row(sections, :solve, "threads") == string(Threads.nthreads())
        @test _row(sections, :rays, "ends") == "–"
        @test !haskey(Dict(Dict(sections)[:rays]), "never hit")
        @test _row(sections, :scene, "objects") ==
              "1 system · $(length(BMO.render_children(gui.pool))) objects · 1 source · 1 detector"
        @test _row(sections, :scene, "cards") == "0 open · 0 pinned · undo 0"
        @test Dict(sections)[:events] == ["" => "none"]

        # the card shows the empty stats, too
        GUI._set_debug!(gui, true)
        hud = _hud(gui)
        d = GUI._debug(gui)
        d.stats.rays = nothing
        empty!(d.stats.solves)
        empty!(d.stats.events)
        GUI._hud_refresh!(gui, hud)
        @test _values(hud)["ends"] == "–"
        @test _values(hud)[""] == "none"

        push!(d.stats.solves, _record(kind = :preview), _record(sources = ["Beam" => 0.002, "Fan" => 0.039]))
        d.stats.rays = GUI._RaySummary(1, 25, 27, 3, Dict(:object => 2, :open => 2, :r_max => 0), 25, Any[m])
        for (k, text) in enumerate(("window opened", "drag Mirror 1 started", "preview, 6 ms",
                                   "solve done, 48 ms (full)", "solve done, 12 ms (full)"))
            push!(d.stats.events, time() - 10 + k => text)
        end
        sections = GUI._hud_sections(gui, d)
        @test _row(sections, :solve, "state") == "idle"
        @test _row(sections, :solve, "solve") == "41.0 ms  (budget none)"
        @test _row(sections, :solve, "beams drawn") == "10.2 ms"
        @test _row(sections, :solve, "views") == "0.0 ms"
        @test _row(sections, :solve, "JIT · GC") == "0.0 ms · 0.4 ms, 3.2 MiB"
        @test _row(sections, :solve, "slowest") == "Fan  39.0 ms"
        @test _row(sections, :rays, "beams") == "1 · 27 segments · depth 3"
        @test _row(sections, :rays, "ends") == "on object 2 · open 2 · ray limit 0"
        @test _row(sections, :rays, "normals") == "25 hit points"
        @test _row(sections, :rays, "never hit") == GUI._label(gui, m)
        events = Dict(sections)[:events]
        @test last.(events) == ["solve done, 12 ms (full)", "solve done, 48 ms (full)",
            "preview, 6 ms", "drag Mirror 1 started"]
        @test all(endswith(first(e), " s") for e in events)
        # a preview is named
        pop!(d.stats.solves)
        @test _row(GUI._hud_sections(gui, d), :solve, "solve") == "41.0 ms preview  (budget none)"
        push!(d.stats.solves, _record(sources = ["Beam" => 0.002, "Fan" => 0.039]))

        # the card shows them after its next refresh: new rows build the body again
        _tick!(gui, 1.0)
        v = _values(hud)
        @test v["never hit"] == GUI._label(gui, m)
        @test v["ends"] == "on object 2 · open 2 · ray limit 0"
        @test v["slowest"] == "Fan  39.0 ms"
        @test count(c -> c isa Label, hud.cells) == length(GUI._HUD_SECTIONS)
        # the colors of the legend, of "never hit" and of the state
        legend = only(c for c in hud.cells if c isa Tuple && !(c[2] isa Label))
        @test [l.color[] for l in legend[3]] == [t.ok, t.stale, t.danger]
        cell(key) = only(c for c in hud.cells if c isa Tuple && c[1].text[] == key)
        @test cell("never hit")[2].color[] == t.stale_text
        @test cell("state")[2].color[] == t.ok_text
        # the card grows with the rows, its top left corner stays
        r = _rect(hud.background)
        @test maximum(r)[2] ≈ maximum(_view(gui))[2] - GUI._HUD_TOP

        # more than three components never hit: three names and the number of the others
        d.stats.rays = GUI._RaySummary(1, 25, 27, 3, Dict(:open => 1, :depth_max => 2), 25,
            Any[m, pd, m, pd, m])
        rays = Dict(Dict(GUI._hud_sections(gui, d))[:rays])
        @test endswith(rays["never hit"], " +2")
        @test rays["ends"] == "on object 0 · open 1 · ray limit 0 · depth limit 2"
        _tick!(gui, 2.0)
        legend = only(c for c in hud.cells if c isa Tuple && !(c[2] isa Label))
        @test length(legend[2]) == 4 && legend[3][4].color[] == t.danger

        # an outdated solve
        gui.trace.stale = true
        @test _row(GUI._hud_sections(gui, d), :solve, "state") == "outdated"
        _tick!(gui, 3.0)
        @test cell("state")[2].color[] == t.stale_text
        gui.trace.stale = false
        close(gui)
    end

    @testset "follows the resize of the 3D view" begin
        gui, _, _ = _fixture()
        GUI._set_debug!(gui, true)
        hud = _hud(gui)
        vp0 = _view(gui)
        resize!(gui.fig, 1000, 700)
        vp = _view(gui)
        @test vp != vp0
        r = _rect(hud.background)
        @test minimum(r)[1] ≈ minimum(vp)[1] + GUI._HUD_LEFT
        @test maximum(r)[2] ≈ maximum(vp)[2] - GUI._HUD_TOP
        close(gui)
    end

    @testset "the colors of the cards in both themes and layouts" begin
        for (layout, theme) in ((:compact, :light), (:compact, :dark), (:app, :light), (:app, :dark))
            gui, _, _ = _fixture(; layout, theme)
            t = gui.layout.theme
            GUI._set_debug!(gui, true)
            hud = _hud(gui)
            @test hud.theme === t
            bg = hud.background
            @test bg.color[] == t.sidebar && bg.strokecolor[] == t.border
            @test bg.cornerradius[] == GUI._CARD_CORNER
            title = only(b for b in hud.head.content if b.content isa Label && b.content.text[] == "Debug").content
            @test title.font[] == :bold && title.fontsize[] == GUI._CARD_TITLE_FONTSIZE
            @test title.color[] == t.text
            headers = [c for c in hud.cells if c isa Label]
            @test [h.text[] for h in headers] == uppercase.(collect(last.(GUI._HUD_SECTIONS)))
            @test all(h -> h.color[] == t.muted && h.fontsize[] == 10, headers)
            keys = [c[1] for c in hud.cells if c isa Tuple]
            @test all(k -> k.color[] == t.muted && k.fontsize[] == GUI._CARD_FONTSIZE, keys)
            # at the top left of the 3D view, also beside the sidebar of the app layout
            r, vp = _rect(bg), _view(gui)
            @test minimum(r)[1] ≈ minimum(vp)[1] + GUI._HUD_LEFT
            @test maximum(r)[2] ≈ maximum(vp)[2] - GUI._HUD_TOP
            close(gui)
        end
    end
end

end
