module TestLiveSystemTree

using GLMakie, BeamletOptics, BeamletOpticsGUI
using BeamletOptics: render_children, render_plots, rendered
using Makie
using Test

const BMO = BeamletOptics
const GUI = BeamletOpticsGUI

@testset "Live object tree of several systems" begin

    # Each change is solved at once, see `TestLiveView.jl`; no card of a detector is pinned at start
    _live_app(args...; kwargs...) = live_view(args...;
        merge((; trace_budget = Inf, throttle = false, detectors = [], layout = :app), kwargs)...)

    _beam(x = 0.0) = Beam([x, 0.0, 0], [0.0, 1, 0], 632.8e-9)

    # Two systems that share a mirror: "TX" with a lens and the beam `b1`, "RX" with a detector and
    # the beam `b2`
    function _fixture(; kwargs...)
        m = RoundPlanoMirror(25e-3, 5e-3)
        zrotate3d!(m, deg2rad(45))
        translate3d!(m, [0, 0.1, 0])
        l = SphericalLens(0.1, -0.1, 4e-3, 25.4e-3)
        translate3d!(l, [0, 0.05, 0])
        pd = Detector(5e-3)
        zrotate3d!(pd, -π / 2)
        translate3d!(pd, [0.1, 0.1, 0])
        tx, rx = System([m, l]), System([m, pd])
        b1, b2 = _beam(), _beam(2e-3)
        gui = _live_app(tx => b1, rx => b2; labels = Dict(tx => "TX", rx => "RX"), kwargs...)
        return gui, (; m, l, pd, tx, rx, b1, b2)
    end

    _rows(gui) = gui.layout.tree.rows
    _keys(gui) = Any[r.key for r in _rows(gui)]
    _labels(gui) = [r.label for r in _rows(gui)]
    # The keys of the rows are compared by identity
    _same(a, b) = length(a) == length(b) && all(((x, y),) -> x === y, zip(a, b))
    _rows_of(gui, key) = [r for r in _rows(gui) if r.key === key]
    _row(gui, key) = only(_rows_of(gui, key))
    _index(gui, key) = findfirst(r -> r.key === key, _rows(gui))
    _handle(gui, sys) = GUI._system_handle(gui, sys)

    # Clicks the pixel `x` (from the left edge of the tree) of the row of `key` with the mouse
    function _click!(gui, key, x)
        tree = gui.layout.tree
        o = minimum(tree.scene.viewport[])
        ev = events(gui.fig.scene)
        ev.mouseposition[] = (Float64(o[1] + x), Float64(o[2] + GUI._row_y(tree, _index(gui, key))))
        ev.mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.press)
        ev.mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.release)
        return nothing
    end
    _click_button!(gui, sys, button) =
        _click!(gui, _handle(gui, sys), getfield(GUI._button_columns(gui.layout.tree), button))
    # The pick of the `gui` as `(system, add)`
    _pick(gui) = (p = GUI._member_pick(gui); isnothing(p) ? nothing : (p.sys, p.add))

    @testset "members of two systems" begin
        gui, o = _fixture()
        tree = gui.layout.tree
        h1, h2 = _handle(gui, o.tx), _handle(gui, o.rx)
        # per system its row, its sources and its objects; the shared mirror under both
        @test _same(_keys(gui), Any[h1, o.b1, o.m, o.l, h2, o.b2, o.m, o.pd])
        @test _labels(gui) == ["TX", "Beam 1", "Mirror 1", "Lens 1", "RX", "Beam 2", "Mirror 1", "Detector 1"]
        @test [r.depth for r in _rows(gui)] == [0, 1, 1, 1, 0, 1, 1, 1]
        @test [r.kind for r in _rows(gui)] ==
              [:system, :source, :mirror, :lens, :system, :source, :mirror, :detector]
        # the counter of the systems of the shared object
        @test [r.count for r in _rows(gui)] == [0, 0, 2, 0, 0, 0, 2, 0]
        @test tree.plots.counters.text[] == ["2", "2"]
        # no row "No system" while everything has a system
        @test !any(r -> r.key === gui.extras, _rows(gui))
        # "+" and "−" on the rows of the systems only
        @test [r.buttons for r in _rows(gui)] == [:none, nothing, nothing, nothing, :none, nothing, nothing, nothing]
        @test tree.plots.buttons.text[] == ["+", "−", "+", "−"]
        @test all(==(tree.icon_color), tree.plots.buttons.color[])
        @test all(r -> r.visible === true, _rows(gui))

        # both rows of the shared object are highlighted while it is selected
        @test !tree.plots.selection.visible[]
        gui.controls.selected[] = o.m
        @test tree.selected === o.m
        @test tree.plots.selection.visible[]
        rects = tree.plots.selection[1][]
        @test length(rects) == 4
        ys = [GUI._row_y(tree, i) for (i, r) in enumerate(_rows(gui)) if r.key === o.m]
        @test [Makie.origin(r)[2] for r in rects[[1, 3]]] ≈ ys .- tree.row_height / 2
        @test tree.plots.selection.color[] ==
              [tree.selection_color, tree.accent_color, tree.selection_color, tree.accent_color]
        # one row of an object of one system
        gui.controls.selected[] = o.l
        @test length(tree.plots.selection[1][]) == 2
        gui.controls.selected[] = nothing
        @test !tree.plots.selection.visible[]

        # the eye of the shared object mutes both rows
        tree.eye_clicked[] = o.m
        @test all(r -> r.visible === false, _rows_of(gui, o.m))
        tree.eye_clicked[] = o.m
        @test all(r -> r.visible === true, _rows_of(gui, o.m))
        close(gui)
    end

    @testset "expanding and revealing" begin
        gui, o = _fixture()
        tree = gui.layout.tree
        h1, h2 = _handle(gui, o.tx), _handle(gui, o.rx)
        # a collapsed system hides its sources and its objects
        tree.expand_clicked[] = h1
        @test _same(_keys(gui), Any[h1, h2, o.b2, o.m, o.pd])
        @test _row(gui, h1).expandable && !_row(gui, h1).expanded
        # the shared object is shown under the other system: nothing is expanded
        gui.controls.selected[] = o.m
        @test !_row(gui, h1).expanded && length(_rows_of(gui, o.m)) == 1
        @test length(tree.plots.selection[1][]) == 2
        gui.controls.selected[] = nothing
        # under no expanded system: the first of its systems is expanded
        tree.expand_clicked[] = h2
        @test _same(_keys(gui), Any[h1, h2])
        gui.controls.selected[] = o.m
        @test _row(gui, h1).expanded && !_row(gui, h2).expanded
        @test length(_rows_of(gui, o.m)) == 1
        gui.controls.selected[] = nothing
        # a source is revealed under its system
        gui.controls.selected[] = o.b2
        @test _row(gui, h2).expanded && tree.selected === o.b2
        @test length(_rows_of(gui, o.m)) == 2
        gui.controls.selected[] = nothing
        # a system without members has no expander
        sys = add_system!(gui; select = false)
        @test !_row(gui, _handle(gui, sys)).expandable
        close(gui)
    end

    @testset "no system" begin
        gui, o = _fixture()
        tree = gui.layout.tree
        h1, h2 = _handle(gui, o.tx), _handle(gui, o.rx)
        @test GUI._label(gui, gui.extras) == "No system"
        @test GUI._label(gui, rendered(gui.extras)) == "No system"
        # an object that is taken out of its last system
        GUI._remove_member!(gui, o.l, o.tx)
        @test GUI._is_extra(gui, o.l)
        @test _same(_keys(gui), Any[h1, o.b1, o.m, h2, o.b2, o.m, o.pd, gui.extras, o.l])
        row = _row(gui, gui.extras)
        @test row.label == "No system" && row.depth == 0 && row.expanded && row.expandable
        @test isnothing(row.buttons) && row.visible === true
        @test _row(gui, o.l).depth == 1
        # a source that loses its system: listed first under "No system"
        GUI._set_source_system!(gui, o.b2, nothing)
        @test _same(_keys(gui), Any[h1, o.b1, o.m, h2, o.m, o.pd, gui.extras, o.b2, o.l])
        @test _row(gui, o.b2).depth == 1 && _row(gui, o.b2).kind == :source
        # the row is revealed and collapsed like a system
        tree.expand_clicked[] = gui.extras
        @test _same(_keys(gui), Any[h1, o.b1, o.m, h2, o.m, o.pd, gui.extras])
        gui.controls.selected[] = o.b2
        @test _row(gui, gui.extras).expanded && tree.selected === o.b2
        gui.controls.selected[] = nothing
        tree.expand_clicked[] = gui.extras
        gui.controls.selected[] = o.l
        @test _row(gui, gui.extras).expanded && tree.selected === o.l
        gui.controls.selected[] = nothing
        # back into systems: the row goes away
        GUI._set_source_system!(gui, o.b2, o.tx)
        @test _same(_keys(gui), Any[h1, o.b1, o.b2, o.m, h2, o.m, o.pd, gui.extras, o.l])
        GUI._add_member!(gui, o.l, o.rx)
        @test _same(_keys(gui), Any[h1, o.b1, o.b2, o.m, h2, o.m, o.pd, o.l])
        # the shared object out of one system: listed once, without a counter
        GUI._remove_member!(gui, o.m, o.rx)
        @test _row(gui, o.m).count == 0 && isempty(tree.plots.counters.text[])
        # only sources without a system: the row has no eye
        GUI._set_source_system!(gui, o.b1, nothing)
        row = _row(gui, gui.extras)
        @test isnothing(row.visible) && row.expandable
        @test _same(_keys(gui), Any[h1, o.b2, o.m, h2, o.pd, o.l, gui.extras, o.b1])
        close(gui)
    end

    @testset "systems at runtime" begin
        gui, o = _fixture()
        h1, h2 = _handle(gui, o.tx), _handle(gui, o.rx)
        # a new system gets a row with the buttons, after the other systems
        sys = add_system!(gui; label = "Probe")
        h3 = _handle(gui, sys)
        @test _same(_keys(gui), Any[h1, o.b1, o.m, o.l, h2, o.b2, o.m, o.pd, h3])
        @test _row(gui, h3).label == "Probe" && _row(gui, h3).buttons == :none
        @test _row(gui, h3).kind == :system && isnothing(_row(gui, h3).visible)
        # a third system of the shared object
        GUI._add_member!(gui, o.m, sys)
        @test [r.count for r in _rows_of(gui, o.m)] == [3, 3, 3]
        @test _row(gui, h3).expandable
        # a removed system leaves its source and its orphaned object without a system
        remove_system!(gui, o.rx)
        @test _same(_keys(gui), Any[h1, o.b1, o.m, o.l, h3, o.m, gui.extras, o.b2, o.pd])
        @test [r.count for r in _rows_of(gui, o.m)] == [2, 2]
        @test GUI._undo!(gui.controls)
        @test _same(_keys(gui), Any[h1, o.b1, o.m, o.l, h2, o.b2, o.m, o.pd, h3, o.m])
        close(gui)

        # a `StaticSystem` has the buttons, too: sources can be moved to it
        m = RoundPlanoMirror(25e-3, 5e-3)
        translate3d!(m, [0, 0.1, 0])
        static = StaticSystem([m])
        gui = _live_app(static => _beam())
        @test _row(gui, _handle(gui, static)).buttons == :none
        close(gui)
    end

    @testset "buttons pick the members" begin
        gui, o = _fixture()
        tree = gui.layout.tree
        h1, h2 = _handle(gui, o.tx), _handle(gui, o.rx)
        _colors(h) = (i = 2 * (count(r -> !isnothing(r.buttons), _rows(gui)[1:_index(gui, h)]) - 1);
            tree.plots.buttons.color[][(i + 1):(i + 2)])
        @test isnothing(_pick(gui))
        # a click on "+" starts the pick, its button has the accent color
        _click_button!(gui, o.rx, :add)
        @test _pick(gui) == (o.rx, true)
        @test _row(gui, h2).buttons == :add && _row(gui, h1).buttons == :none
        @test _colors(h2) == [tree.accent_color, tree.icon_color]
        @test _colors(h1) == [tree.icon_color, tree.icon_color]
        # "−" of the same system
        _click_button!(gui, o.rx, :remove)
        @test _pick(gui) == (o.rx, false)
        @test _row(gui, h2).buttons == :remove
        @test _colors(h2) == [tree.icon_color, tree.accent_color]
        # the button of another system
        _click_button!(gui, o.tx, :remove)
        @test _pick(gui) == (o.tx, false)
        @test _row(gui, h1).buttons == :remove && _row(gui, h2).buttons == :none
        # a second click on the button ends the pick
        _click_button!(gui, o.tx, :remove)
        @test isnothing(_pick(gui))
        @test all(r -> r.buttons in (nothing, :none), _rows(gui))
        @test all(==(tree.icon_color), tree.plots.buttons.color[])
        # a click on the label of the row does not pick
        _click!(gui, h1, GUI._row_columns(tree, _row(gui, h1)).label + 5)
        @test isnothing(_pick(gui)) && gui.objects.inspected === o.tx
        # a pick that ends elsewhere is shown with the next rows
        tree.button_clicked[] = (h1, :add)
        @test _pick(gui) == (o.tx, true) && _row(gui, h1).buttons == :add
        GUI._end_member_pick!(gui)
        GUI._on_components_changed!(gui)
        @test _row(gui, h1).buttons == :none
        # the pick applies to a member like a click on it does, and the tree follows
        tree.button_clicked[] = (h1, :add)
        GUI._pick_member!(gui, o.pd)
        @test _same(_keys(gui), Any[h1, o.b1, o.m, o.l, o.pd, h2, o.b2, o.m, o.pd])
        @test [r.count for r in _rows_of(gui, o.pd)] == [2, 2]
        @test _row(gui, h1).buttons == :add
        # a removed system ends its pick
        remove_system!(gui, o.tx)
        @test isnothing(_pick(gui))
        @test _same(_keys(gui), Any[h2, o.b2, o.m, o.pd, gui.extras, o.b1, o.l])
        close(gui)
    end
end

end
