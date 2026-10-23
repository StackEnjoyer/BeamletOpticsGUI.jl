module TestMultiSelectTree

using GLMakie, BeamletOptics, BeamletOpticsGUI
using Makie
using Test

const BMO = BeamletOptics
const GUI = BeamletOpticsGUI

@testset "Selections of several objects in the object tree" begin

    # Each change is solved at once, see `TestLiveView.jl`; no card of a detector is pinned at start
    _live_app(args...; kwargs...) = live_view(args...;
        merge((; trace_budget = Inf, throttle = false, detectors = [], layout = :app,
            catalog = CatalogEntry[]), kwargs)...)

    # Two systems that share the mirror `m`: "TX" with the lens `l`, "RX" with the detector `pd`
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
        b1 = Beam([0.0, 0, 0], [0.0, 1, 0], 632.8e-9)
        gui = _live_app(tx => b1, rx; labels = Dict(tx => "TX", rx => "RX"), kwargs...)
        return gui, (; m, l, pd, tx, rx, b1)
    end

    _rows(gui) = gui.layout.tree.rows
    _index(gui, key) = findfirst(r -> r.key === key, _rows(gui))
    # The indices of the highlighted rows, from the rectangles of the selection plot
    function _highlighted(gui)
        tree = gui.layout.tree
        p = tree.plots.selection
        p.visible[] || return Int[]
        ys = unique(Makie.origin(r)[2] for r in p[1][])
        return sort([i for i in eachindex(tree.rows) if any(y -> y ≈ GUI._row_y(tree, i) - tree.row_height / 2, ys)])
    end

    # Clicks the label of the row of `key`, with the keys `held` held
    function _click!(gui, key; held = ())
        tree = gui.layout.tree
        o = minimum(tree.scene.viewport[])
        row = tree.rows[_index(gui, key)]
        x = GUI._row_columns(tree, row).label + 5
        ev = events(gui.fig.scene)
        foreach(k -> push!(ev.keyboardstate, k), held)
        ev.mouseposition[] = (Float64(o[1] + x), Float64(o[2] + GUI._row_y(tree, _index(gui, key))))
        ev.mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.press)
        ev.mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.release)
        foreach(k -> delete!(ev.keyboardstate, k), held)
        return nothing
    end
    _ctrl_click!(gui, key) = _click!(gui, key; held = (Keyboard.left_control,))

    @testset "the tree: toggled and several keys" begin
        fig = Figure(; size = (300, 400))
        tree = GUI._ObjectTree(fig[1, 1])
        Row = GUI._TreeRow
        rows = [Row("a", "A", 0, :lens, false, false, true), Row("b", "B", 0, :lens, false, false, true),
            Row("a", "A", 1, :lens, false, false, true)]
        for i in 1:60
            push!(rows, Row("x$i", "X$i", 0, :lens, false, false, true))
        end
        GUI._set_rows!(tree, rows)
        clicked, toggled = Any[], Any[]
        on(k -> push!(clicked, k), tree.clicked)
        on(k -> push!(toggled, k), tree.toggled)
        ev = events(tree.scene)
        function click!(i, held)
            vp = tree.scene.viewport[]
            c = GUI._row_columns(tree, tree.rows[i])
            foreach(k -> push!(ev.keyboardstate, k), held)
            ev.mouseposition[] = (Makie.origin(vp)[1] + c.label + 5, Makie.origin(vp)[2] + GUI._row_y(tree, i))
            ev.mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.press)
            ev.mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.release)
            foreach(k -> delete!(ev.keyboardstate, k), held)
        end
        click!(1, ())
        click!(2, (Keyboard.left_control,))
        click!(1, (Keyboard.right_super,))
        # Shift is a plain click
        click!(2, (Keyboard.left_shift,))
        @test clicked == ["a", "b"] && toggled == ["b", "a"]
        # all rows of several keys are highlighted
        GUI._set_selected!(tree, Any["a", "b"])
        @test length(tree.plots.selection[1][]) == 6
        @test tree.selected == "b" && tree.selected_keys == Any["a", "b"]
        # the last added key is scrolled into view
        GUI._set_selected!(tree, Any["a", "b", "x55"])
        @test tree.selected == "x55" && tree.offset > 0
        y = GUI._row_y(tree, 58)
        @test tree.row_height / 2 <= y <= Makie.widths(tree.scene.viewport[])[2] - tree.row_height / 2
        # removing a key does not scroll
        offset = tree.offset
        GUI._set_selected!(tree, Any["a", "x55"])
        @test tree.offset == offset && tree.selected == "x55"
        GUI._set_selected!(tree, Any[])
        @test !tree.plots.selection.visible[] && isnothing(tree.selected)
        # a single key as before
        GUI._set_selected!(tree, "b")
        @test tree.selected_keys == Any["b"] && length(tree.plots.selection[1][]) == 2
        GUI._set_selected!(tree, nothing)
        @test isempty(tree.selected_keys) && !tree.plots.selection.visible[]
    end

    @testset "Ctrl+click toggles, a plain click selects one" begin
        gui, o = _fixture()
        ctrl = gui.controls
        _click!(gui, o.l)
        @test ctrl.selected[] === o.l
        @test _highlighted(gui) == [_index(gui, o.l)]
        # Ctrl+click adds the mirror, which is listed under both systems: all its rows are highlighted
        _ctrl_click!(gui, o.m)
        sel = ctrl.selected[]
        @test sel isa GUI._MultiSelection && sel.objects == Any[o.l, o.m]
        mrows = [i for (i, r) in enumerate(_rows(gui)) if r.key === o.m]
        @test length(mrows) == 2
        @test _highlighted(gui) == sort([_index(gui, o.l); mrows])
        @test gui.layout.tree.selected === o.m
        # and the detector (Cmd on macOS)
        _click!(gui, o.pd; held = (Keyboard.left_super,))
        @test ctrl.selected[].objects == Any[o.l, o.m, o.pd]
        @test length(_highlighted(gui)) == 4
        # Ctrl+click on a selected row removes it
        _ctrl_click!(gui, o.m)
        @test ctrl.selected[].objects == Any[o.l, o.pd]
        @test _highlighted(gui) == sort([_index(gui, o.l), _index(gui, o.pd)])
        _ctrl_click!(gui, o.l)
        @test ctrl.selected[] === o.pd
        @test _highlighted(gui) == [_index(gui, o.pd)]
        # a plain click selects one alone; Shift+click, too
        _ctrl_click!(gui, o.l)
        @test GUI._is_multi(ctrl.selected[])
        _click!(gui, o.m; held = (Keyboard.left_shift,))
        @test ctrl.selected[] === o.m
        _ctrl_click!(gui, o.l)
        _click!(gui, o.pd)
        @test ctrl.selected[] === o.pd
        @test _highlighted(gui) == [_index(gui, o.pd)]
        # Ctrl+click on a system inspects it like a plain click, the selection ends
        h = GUI._system_handle(gui, o.tx)
        _ctrl_click!(gui, h)
        @test isnothing(ctrl.selected[]) && gui.objects.inspected === o.tx
        # Ctrl+click on an object that is not movable inspects it
        filter!(x -> x !== o.l, ctrl.movable)
        _ctrl_click!(gui, o.l)
        @test isnothing(ctrl.selected[]) && gui.objects.inspected === o.l
        close(gui)
    end

    @testset "select! of several objects highlights their rows" begin
        gui, o = _fixture()
        tree = gui.layout.tree
        # collapse the systems: selecting reveals the rows
        tree.expand_clicked[] = GUI._system_handle(gui, o.tx)
        tree.expand_clicked[] = GUI._system_handle(gui, o.rx)
        @test isnothing(_index(gui, o.l)) && isnothing(_index(gui, o.pd))
        select!(gui, [o.l, o.pd])
        @test !isnothing(_index(gui, o.l)) && !isnothing(_index(gui, o.pd))
        @test _highlighted(gui) == sort([_index(gui, o.l), _index(gui, o.pd)])
        @test tree.selected_keys == Any[o.l, o.pd]
        select!(gui, nothing)
        @test isempty(_highlighted(gui)) && isnothing(tree.selected)
        close(gui)
    end
end

end
