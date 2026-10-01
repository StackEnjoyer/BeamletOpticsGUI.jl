module TestLiveDock

using GLMakie, BeamletOptics, BeamletOpticsGUI
using Makie
using Test

const BMO = BeamletOptics
const GUI = BeamletOpticsGUI

@testset "Live view analysis dock" begin

    # Rays along +y through a transparent detector onto a second one
    function _fixture(; layout = :app, kwargs...)
        pds = [Detector(25e-3, false), Detector(25e-3)]
        foreach(((k, pd),) -> translate3d!(pd, [0, 0.05k, 0]), enumerate(pds))
        src = CollimatedSource([0.0, 0, 0], [0.0, 1, 0], 4e-3, 1e-6; num_rings = 2, num_rays = 40)
        gui = live_view(System(pds) => src; layout, labels = Dict(pds[1] => "PD1", pds[2] => "PD2"),
            trace_budget = Inf, throttle = false, preview = false, kwargs...)
        return gui, pds
    end

    # A panel of `add_panel!` with an axis, whose updates are counted
    function _panel!(gui, title; kwargs...)
        n, ax = Ref(0), Ref{Any}(nothing)
        layout = add_panel!(gui, title; kwargs...) do l
            ax[] = Axis(l[1, 1])
            return _ -> (n[] += 1)
        end
        return (; layout, n, ax = ax[], panel = last(gui.custom.panels))
    end

    _tabs(gui) = gui.layout.tabs
    _shown(ax) = ax.blockscene.visible[]

    # A click on the tab `i` of the tab bar
    function _click_tab!(gui, i)
        bar = _tabs(gui).bar
        s = only(s for s in GUI._tab_slots(bar).slots if s.i == i)
        o = Makie.origin(bar.scene.viewport[])
        events(gui.fig.scene).mouseposition[] = (o[1] + (s.x0 + s.x1) / 2, o[2] + GUI._TAB_HEIGHT / 2)
        for action in (Mouse.press, Mouse.release)
            events(gui.fig.scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, action)
        end
        return nothing
    end

    @testset "no tabs without add_panel!" begin
        # the results of the detectors are on their cards: the dock has no tab and stays collapsed
        gui, pds = _fixture()
        tabs = _tabs(gui)
        @test tabs.bar isa GUI._TabBar
        @test isempty(tabs.bar.titles) && isempty(tabs.parts) && isempty(tabs.panels)
        @test tabs.active == 0 && isnothing(GUI._active_panel(tabs))
        @test isempty(gui.layout.dock_panels) && !gui.layout.dock.shown
        # also after a solve, with a selected detector and with the toggle of the dock
        gui.controls.selected[] = pds[2]
        GUI._resolve!(gui, nothing)
        @test isempty(tabs.bar.titles) && !gui.layout.dock.shown
        gui.layout.collapse.dock.active[] = false
        gui.layout.collapse.dock.active[] = true
        @test !gui.layout.dock.shown
        # a constant number of plots
        @test length(tabs.bar.scene.plots) == 3
        close(gui)

        gui, _ = _fixture(; detectors = [])
        @test isempty(_tabs(gui).bar.titles) && !gui.layout.dock.shown
        close(gui)
    end

    @testset "tabs" begin
        gui, _ = _fixture()
        tabs = _tabs(gui)
        # the first panel shows the dock, later panels are tabs behind the active one
        a = _panel!(gui, "Power")
        @test gui.layout.dock.shown && gui.layout.collapse.dock.active[]
        b = _panel!(gui, "Spectrum")
        c = _panel!(gui, "History")
        @test tabs.bar.titles == ["Power", "Spectrum", "History"]
        @test first.(gui.layout.dock_panels) == tabs.bar.titles
        @test last.(gui.layout.dock_panels) == [a.layout, b.layout, c.layout]
        @test tabs.panels == gui.custom.panels
        @test tabs.active == 1 && tabs.bar.active == 1
        @test GUI._active_panel(tabs) === a.panel
        # only the active panel is laid out and drawn
        @test _shown(a.ax) && !_shown(b.ax) && !_shown(c.ax)
        @test maximum(b.ax.layoutobservables.computedbbox[])[1] < 0
        # a constant number of plots
        @test length(tabs.bar.scene.plots) == 3
        # a click on a tab switches the panel
        _click_tab!(gui, 3)
        @test tabs.active == 3 && tabs.bar.active == 3
        @test _shown(c.ax) && !_shown(a.ax)
        @test minimum(c.ax.layoutobservables.computedbbox[])[1] > 0
        # `select = true` shows the new tab at once
        d = _panel!(gui, "Selected"; select = true)
        @test tabs.active == 4 && _shown(d.ax) && !_shown(c.ax)
        close(gui)
    end

    @testset "lazy panels" begin
        gui, _ = _fixture()
        tabs = _tabs(gui)
        a, b, c = _panel!(gui, "A"), _panel!(gui, "B"), _panel!(gui, "C")
        # a new panel shows the result of the last solve if it is shown, else it is stale
        @test (a.n[], b.n[], c.n[]) == (1, 0, 0)
        @test Set(tabs.stale) == Set([b.panel, c.panel])
        @test GUI._panel_shown(gui, a.panel) && !GUI._panel_shown(gui, b.panel)
        # after a solve only the panel of the active tab is updated
        GUI._resolve!(gui, nothing)
        @test (a.n[], b.n[], c.n[]) == (2, 0, 0)
        @test !(a.panel in tabs.stale)
        # a stale tab is updated once when it becomes active
        GUI._activate_tab!(gui, 2)
        @test (a.n[], b.n[], c.n[]) == (2, 1, 0)
        @test !(b.panel in tabs.stale)
        GUI._activate_tab!(gui, 1)
        GUI._activate_tab!(gui, 2)
        @test (a.n[], b.n[], c.n[]) == (2, 1, 0)
        # the panel that is left is stale after the next solve
        GUI._resolve!(gui, nothing)
        @test (a.n[], b.n[], c.n[]) == (2, 2, 0)
        @test a.panel in tabs.stale
        GUI._activate_tab!(gui, 1)
        @test (a.n[], b.n[], c.n[]) == (3, 2, 0)
        @test isnothing(gui.trace.job) && !gui.trace.stale
        close(gui)
    end

    @testset "collapsed dock" begin
        gui, _ = _fixture()
        tabs = _tabs(gui)
        a, b = _panel!(gui, "A"), _panel!(gui, "B")
        GUI._activate_tab!(gui, 2)
        @test (a.n[], b.n[]) == (1, 1)
        gui.layout.collapse.dock.active[] = false
        @test !gui.layout.dock.shown
        @test !GUI._panel_shown(gui, b.panel) && !_shown(b.ax)
        # a collapsed dock updates nothing
        GUI._resolve!(gui, nothing)
        @test (a.n[], b.n[]) == (1, 1)
        @test b.panel in tabs.stale
        # expanding updates the active panel
        gui.layout.collapse.dock.active[] = true
        @test (a.n[], b.n[]) == (1, 2)
        @test !(b.panel in tabs.stale)
        @test _shown(b.ax) && !_shown(a.ax)
        close(gui)
    end

    @testset "stale hits" begin
        gui, _ = _fixture()
        tabs = _tabs(gui)
        a, b = _panel!(gui, "A"), _panel!(gui, "B")
        # a solve that did not complete (e.g. cancelled) leaves incomplete hits: stale tabs are
        # not updated until the next solve
        GUI._views_cancelled!(gui)
        @test !GUI._results_valid(gui)
        GUI._activate_tab!(gui, 2)
        @test (a.n[], b.n[]) == (1, 0)
        @test b.panel in tabs.stale
        GUI._resolve!(gui, nothing)
        @test (a.n[], b.n[]) == (1, 1)
        @test !(b.panel in tabs.stale) && GUI._results_valid(gui)
        # a panel that is added meanwhile waits, too
        GUI._views_cancelled!(gui)
        c = _panel!(gui, "C"; select = true)
        @test c.n[] == 0 && c.panel in tabs.stale
        GUI._resolve!(gui, nothing)
        @test c.n[] == 1 && !(c.panel in tabs.stale)
        close(gui)
    end

    @testset "coarse results" begin
        gui, _ = _fixture()
        tabs = _tabs(gui)
        a, b = _panel!(gui, "A"), _panel!(gui, "B")
        # a panel that is left while the live view shows a coarse result is updated again when it
        # is shown next
        GUI._resolve!(gui, nothing; coarse = true)
        @test gui.trace.coarse && a.n[] == 2
        GUI._activate_tab!(gui, 2)
        @test a.panel in tabs.stale
        GUI._activate_tab!(gui, 1)
        @test a.n[] == 3 && !(a.panel in tabs.stale)
        close(gui)
    end

    @testset "slots" begin
        gui, _ = _fixture()
        tabs = _tabs(gui)
        a = _panel!(gui, "A")
        # a dock panel without an update is a tab, which becomes active
        d = GUI._add_dock_panel!(gui, "Mine")
        ax = Axis(d[1, 1])
        @test tabs.bar.titles == ["A", "Mine"]
        @test tabs.active == 2
        @test isnothing(GUI._active_panel(tabs))
        @test !_shown(a.ax) && _shown(ax)
        # nothing is updated for it
        GUI._resolve!(gui, nothing)
        @test a.n[] == 1 && a.panel in tabs.stale
        GUI._activate_tab!(gui, 1)
        @test !ax.blockscene.visible[]
        @test a.n[] == 2
        close(gui)
    end

    @testset "overflow" begin
        gui, _ = _fixture(; size = (700, 700), view_cube = false)
        bar = _tabs(gui).bar
        for k in 1:12
            GUI._add_dock_panel!(gui, "Panel with a long name $k")
        end
        (; slots, overflow) = GUI._tab_slots(bar)
        @test overflow
        # the active (last) tab is scrolled into view
        @test slots[end].i == 12
        @test bar.first > 1
        # the wheel over the bar scrolls by whole tabs
        f = bar.first
        vp = bar.scene.viewport[]
        events(gui.fig.scene).mouseposition[] = Tuple(Makie.origin(vp) .+ Makie.widths(vp) ./ 2)
        events(gui.fig.scene).scroll[] = (0.0, 1.0)
        @test bar.first == f - 1
        GUI._activate_tab!(gui, 1)
        @test bar.first == 1
        close(gui)
    end
end

end
