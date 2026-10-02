module TestLiveCatalog

using GLMakie, BeamletOptics, BeamletOpticsGUI
using Makie
using LinearAlgebra: norm
using Test

const BMO = BeamletOptics
const GUI = BeamletOpticsGUI

# A component that is not part of the built-in catalog, for own entries
struct CatalogBlock{T} <: BMO.AbstractObject{T}
    shape::BMO.PlanoSurfaceSDF{T}
end
CatalogBlock(width::Real = 10e-3; scale::Real = 1.0) = CatalogBlock(BMO.PlanoSurfaceSDF(scale * width, width))
BMO.interact3d(::BMO.AbstractSystem, ::CatalogBlock, ::Beam, ::Ray) = nothing

# A constructor that throws for a negative size
function checked_block(width::Real)
    width > 0 || throw(ArgumentError("the width must be positive, got $width"))
    return CatalogBlock(width)
end

@testset "Live view catalog" begin
    block_entry() = CatalogEntry("Block", CatalogBlock; group = "Blocks", params = [
        CatalogParam("width", 10e-3; unit = "mm", scale = 1e-3),
        CatalogParam("scale", 2.0; keyword = :scale)])

    # Rays along +y onto a mirror, in one system named `label`; a second pair with `two`
    function _fixture(; two::Bool = false, label = nothing, kwargs...)
        m = RoundPlanoMirror(25e-3, 5e-3)
        translate3d!(m, [0, 0.1, 0])
        sys = System([m])
        cs = CollimatedSource([0.0, 0, 0], [0.0, 1, 0], 2e-3, 1e-6; num_rings = 2, num_rays = 40)
        pairs = Any[sys => cs]
        m2 = RoundPlanoMirror(25e-3, 5e-3)
        translate3d!(m2, [0.05, 0.1, 0])
        sys2 = System([m2])
        two && push!(pairs, sys2 => Beam([0.05, 0, 0], [0.0, 1, 0], 1e-6))
        labels = isnothing(label) ? Dict() : Dict(sys => label)
        gui = live_view(pairs...; trace_budget = Inf, throttle = false, labels, kwargs...)
        return gui, sys, m, sys2, m2
    end

    _window(gui) = GUI._catalog_window(gui)

    # The widgets of the catalog of the `gui` in its window, in the order in which they were built
    function _widgets(gui)
        widget = _window(gui).widget
        blocks = GUI._blocks!(Any[], widget.layout)
        return (; widget, layout = widget.layout, target = widget.target,
            menus = filter(b -> b isa Menu, blocks),
            boxes = filter(b -> b isa Textbox, blocks),
            labels = [b.text[] for b in blocks if b isa Label],
            place = only(filter(b -> b isa Button, blocks)))
    end

    _texts(boxes) = [tb.displayed_string[] for tb in boxes]
    _tiles(widget) = [widget.entries[i].name for (i, _) in widget.tile_buttons]
    _active(widget) = [widget.entries[i].name for (i, tile) in widget.tile_buttons if tile.active[]]
    _tick!(gui) = (events(gui.ax.scene).tick[] = Makie.Tick(Makie.RegularRenderTick, 0, 0.0, 1.0))

    # Clicks the icon of the `group` of the catalog of the `gui`
    function _group!(gui, group)
        widget = _window(gui).widget
        widget.group_buttons[findfirst(==(group), widget.groups)].clicks[] += 1
        return widget
    end

    # Clicks the tile of the entry `name` of the catalog of the `gui`, after the icon of its group
    function _choose!(gui, name)
        widget = _window(gui).widget
        i = findfirst(e -> e.name == name, widget.entries)
        _group!(gui, widget.entries[i].group)
        last(only(filter(t -> first(t) == i, widget.tile_buttons))).clicks[] += 1
        return _widgets(gui)
    end

    bk7 = "SellmeierEquation(1.03961212, 0.231792344, 1.01046945, 0.00600069867, 0.0200179144, 103.560653)"

    @testset "registry" begin
        catalog = component_catalog()
        @test catalog isa Vector{CatalogEntry}
        @test component_catalog() === catalog
        builtin = GUI._builtin_catalog()
        @test [e.name for e in catalog[1:length(builtin)]] == [e.name for e in builtin]
        n = length(catalog)
        # an entry of a package is shown by the views that are opened afterwards
        entry = block_entry()
        push!(catalog, entry)
        try
            gui, _ = _fixture()
            @test gui.components.catalog == catalog
            # a copy: the view keeps its entries
            @test gui.components.catalog !== catalog
            widget = _window(gui).widget
@test last(widget.groups) == "Blocks" && last(widget.entries) === entry
@test _tiles(_group!(gui, "Blocks")) == ["Block"]
            close(gui)
        finally
            filter!(e -> e !== entry, catalog)
        end
        @test length(component_catalog()) == n
    end

    @testset "objects and code" begin
        entry = block_entry()
        # positional parameters in their order, keyword parameters as keywords
        @test GUI._catalog_args(entry, [5e-3, 3.0]) == ([5e-3], [:scale => 3.0])
        @test GUI._catalog_code(entry, [5e-3, 3.0]) == "CatalogBlock(0.005; scale = 3.0)"
        obj = GUI._catalog_object(entry, [5e-3, 3.0])
        @test obj isa CatalogBlock
        @test typeof(Core.eval(@__MODULE__, Meta.parse(GUI._catalog_code(entry, [5e-3, 3.0])))) === typeof(obj)
        @test_throws ArgumentError GUI._catalog_code(entry, [5e-3])
        @test_throws ArgumentError GUI._catalog_object(entry, [5e-3, 3.0, 1.0])
        # without parameters and with keywords only
        @test GUI._catalog_code(CatalogEntry("x", CatalogBlock), Float64[]) == "CatalogBlock()"
        only_kw = CatalogEntry("x", CatalogBlock; params = [CatalogParam("s", 2.0; keyword = :scale)])
        @test Meta.parse(GUI._catalog_code(only_kw, [2.0])) == :(CatalogBlock(; scale = 2.0))
        # `code_name` replaces the name of the constructor in the code
        named = CatalogEntry("x", checked_block; params = [CatalogParam("w", 1.0)], code_name = "Mod.block")
        @test GUI._catalog_code(named, [1.0]) == "Mod.block(1.0)"
        # a constructor that returns no object
        @test_throws ArgumentError GUI._catalog_object(CatalogEntry("x", identity; params = [CatalogParam("w", 1.0)]), [1.0])

        # the texts of the boxes: in the unit of the parameter
        width, scale = entry.params
        @test GUI._catalog_string(width) == "10"
        @test GUI._catalog_string(scale) == "2"
        @test GUI._catalog_string(CatalogParam("d", 25.4e-3; unit = "mm", scale = 1e-3)) == "25.4"
        @test GUI._catalog_string(CatalogParam("R", Inf; unit = "mm", scale = 1e-3)) == "Inf"
        @test GUI._catalog_value(width, "10") === 10e-3
        @test GUI._catalog_value(width, " 30 ") === 0.03
        @test GUI._catalog_value(width, "25.4") === 0.0254
        @test GUI._catalog_value(width, "1e3") === 1.0
        @test GUI._catalog_value(width, "-Inf") === -Inf
        # an empty box shows the default
        @test GUI._catalog_value(width, "") === 10e-3
        for s in ("abc", "1,5", "NaN", "1 2")
            @test_throws ArgumentError GUI._catalog_value(width, s)
        end

        # from the form to the component and its origin
        c = GUI._catalog_component(entry, ["4", "3"])
        @test c.obj isa CatalogBlock
        @test c.origin.code == "CatalogBlock(0.004; scale = 3.0)"
        P, R = c.origin.pose0
        @test P == position(c.obj) && R == BMO.orientation(c.obj)
        @test_throws ArgumentError GUI._catalog_component(entry, ["4"])
        @test_throws ArgumentError GUI._catalog_component(entry, ["4", "x"])
    end

    @testset "widget ($layout, $theme)" for (layout, theme) in ((:compact, :light), (:app, :dark))
        gui, sys, m = _fixture(; layout, theme)
        entries = gui.components.catalog
        # the window of both layouts, hidden at first, with the toggle of the layout that shows it
        win = _window(gui)
        @test win isa GUI._CatalogWindow && !win.shown && !win.tool.active[]
        @test isempty(GUI._catalog_rects(gui))
        @test isempty(filter(c -> c.title == "Components", gui.custom.controls))
        w = _widgets(gui)
        widget = w.widget
        @test w.layout === win.widget.layout
        @test w.target.text[] == "into: System 1"
        @test w.place.label[] == "Place"
        # an icon per group, the first group and its first entry are chosen
        @test widget.groups == unique(e.group for e in entries)
        @test length(widget.group_buttons) == length(widget.groups) == 7
        @test [b.active[] for b in widget.group_buttons] == (1:7 .== 1)
        @test widget.group_label.text[] == "Lenses"
        @test _tiles(widget) == ["Thin lens", "Singlet", "Doublet", "Triplet"]
        @test _active(widget) == ["Thin lens"] && widget.entry_label.text[] == "Thin lens"
        @test GUI._catalog_entry(widget) === first(entries)
        # the name of the group under the mouse
        widget.group_buttons[3].hovered[] = true
        @test widget.group_label.text[] == "Curved mirrors"
        widget.group_buttons[3].hovered[] = false
        @test widget.group_label.text[] == "Lenses"
        # a box per number with its default, between its name and its unit, a menu per glass
        lens = first(entries)
        @test _texts(w.boxes) == ["50", "-50", "25.4"]
        @test all(p -> p.name in w.labels, lens.params)
        @test count(==("mm"), w.labels) == 3
        menu = only(w.menus)
        @test menu.selection[] == "N-BK7"
        @test menu.options[] == [first.(catalog_glasses()); "constant"]
        @test GUI._catalog_strings(widget) == ["50", "-50", "25.4", "N-BK7"]
        # the boxes and the menu take the keyboard
        @test gui.custom.boxes == w.boxes && widget.boxes == w.boxes
        @test menu in gui.custom.menus && widget.menus == [menu]
        @test !GUI._typing(gui)
        w.boxes[1].focused[] = true
        @test GUI._typing(gui)

        # another entry of the group: the form is built again, the old inputs are gone
        old = w.boxes
        n = length(gui.controls.listeners)
        w = _choose!(gui, "Doublet")
        @test !GUI._typing(gui)
        @test _active(widget) == ["Doublet"] && widget.entry_label.text[] == "Doublet"
        @test _texts(w.boxes) == ["62.8", "-45.7", "-128.2", "4", "2.5", "25.4"]
        @test [mn.selection[] for mn in w.menus] == ["N-BK7", "N-SF5"]
        @test all(tb -> !any(o -> o === tb, old), w.boxes)
        @test gui.custom.boxes == w.boxes && !(menu in gui.custom.menus)
        @test "glass 2" in w.labels && !("glass" in w.labels)
        w.boxes[3].focused[] = true
        @test GUI._typing(gui)
        w.boxes[3].focused[] = false

        # another group: its tiles, its first entry is chosen
        w = _choose!(gui, "Thin beamsplitter")
        @test [b.active[] for b in widget.group_buttons] == (1:7 .== 4)
        @test widget.group_label.text[] == "Beamsplitters"
        @test _tiles(widget) == [e.name for e in entries if e.group == "Beamsplitters"]
        @test length(_tiles(widget)) == 6
        @test _active(widget) == ["Thin beamsplitter"]
        @test _texts(w.boxes) == ["25.4", "25.4", "0.5"] && isempty(w.menus)
        @test "reflectance" in w.labels && !("R1" in w.labels)
        w = _choose!(gui, "Cube beamsplitter")
        @test _active(widget) == ["Cube beamsplitter"]
        @test _texts(w.boxes) == ["25.4", "0.5"] && only(w.menus).selection[] == "N-BK7"
        # the chosen group again changes nothing
        _group!(gui, "Beamsplitters")
        @test _active(widget) == ["Cube beamsplitter"]
        # and back: the listeners of the old tiles and inputs are released
        w = _choose!(gui, "Thin lens")
        @test _texts(w.boxes) == ["50", "-50", "25.4"]
        @test length(gui.controls.listeners) <= n
        @test sys.objects == [m]
        close(gui)
    end

    @testset "glass ($layout)" for layout in (:compact, :app)
        gui, sys, m = _fixture(; layout)
        w = _widgets(gui)
        widget = w.widget
        menu = only(w.menus)
        function code()
            GUI._place_catalog!(gui, GUI._catalog_entry(widget), GUI._catalog_strings(widget))
            c = gui.components.placement.origin.code
            GUI._end_placement!(gui)
            return c
        end
        @test code() == "ThinLens(0.05, -0.05, 0.0254, $bk7)"
        # another glass: the form stays
        w.boxes[3].displayed_string[] = "12"
        menu.i_selected[] = findfirst(==("N-SF11"), menu.options[])
        @test !widget.dirty
        _tick!(gui)
        @test only(_widgets(gui).menus) === menu
        @test GUI._catalog_strings(widget) == ["50", "-50", "12", "N-SF11"]
        @test occursin("0.012, SellmeierEquation(1.73759695,", code())
        # "constant": the box of the refractive index comes with the next frame, the texts stay
        menu.i_selected[] = length(menu.options[])
        @test widget.dirty && length(_widgets(gui).boxes) == 3
        @test GUI._catalog_strings(widget) == ["50", "-50", "12", "1.5"]
        _tick!(gui)
        w = _widgets(gui)
        @test !widget.dirty && only(w.menus) !== menu && !(menu in gui.custom.menus)
        @test only(w.menus).selection[] == "constant"
        @test _texts(w.boxes) == ["50", "-50", "12", "1.5"] && "n" in w.labels
        @test gui.custom.boxes == w.boxes
        w.boxes[4].displayed_string[] = "1.7"
        @test code() == "ThinLens(0.05, -0.05, 0.012, λ -> 1.7)"
        GUI._place_catalog!(gui, GUI._catalog_entry(widget), GUI._catalog_strings(widget))
        @test BMO.refractive_index(gui.components.placement.obj, 1e-6) == 1.7
        GUI._end_placement!(gui)
        # not a refractive index
        w.boxes[4].displayed_string[] = "-1"
        gui.status.text[] = ""
        w.place.clicks[] += 1
        @test occursin("invalid input \"-1\" for glass", gui.status.text[]) && !GUI._placing(gui)
        # back to a glass: the box goes
        menu = only(w.menus)
        menu.i_selected[] = findfirst(==("Fused silica"), menu.options[])
        @test widget.dirty
        @test GUI._catalog_strings(widget) == ["50", "-50", "12", "Fused silica"]
        _tick!(gui)
        w = _widgets(gui)
        @test _texts(w.boxes) == ["50", "-50", "12"] && !("n" in w.labels)
        @test only(w.menus).selection[] == "Fused silica"
        @test sys.objects == [m]
        close(gui)

        # the glass of a package, and "constant" as the default
        own = "Own glass" => SellmeierEquation(1.0, 0.2, 1.0, 0.006, 0.02, 100.0)
        push!(catalog_glasses(), own)
        try
            entry = CatalogEntry("Block", CatalogBlock; group = "Blocks", params = [
                CatalogGlass("coating"; default = "constant", n = 1.38),
                CatalogGlass("glass"; default = "Own glass", keyword = :scale)])
            gui, _ = _fixture(; layout, catalog = [entry])
            w = _widgets(gui)
            @test [mn.selection[] for mn in w.menus] == ["constant", "Own glass"]
            @test all(mn -> "Own glass" in mn.options[], w.menus)
            @test _texts(w.boxes) == ["1.38"]
            @test GUI._catalog_strings(w.widget) == ["1.38", "Own glass"]
            close(gui)
        finally
            filter!(g -> g !== own, catalog_glasses())
        end
    end

    @testset "no widget ($layout)" for layout in (:compact, :app)
        # an empty catalog
        gui, _ = _fixture(; layout, catalog = CatalogEntry[])
        @test isempty(gui.components.catalog)
        @test isnothing(_window(gui))
        @test isempty(gui.custom.boxes)
        close(gui)
        # no system that components can be added to
        m = RoundPlanoMirror(25e-3, 5e-3)
        translate3d!(m, [0, 0.1, 0])
        gui = live_view(StaticSystem([m]) => Beam([0.0, 0, 0], [0.0, 1, 0], 1e-6); layout, trace_budget = Inf)
        @test isnothing(_window(gui))
        close(gui)
        # an empty system gets one
        gui = live_view(System() => Beam([0.0, 0, 0], [0.0, 1, 0], 1e-6); layout, trace_budget = Inf)
        @test !isnothing(_window(gui))
        close(gui)
    end

    @testset "own entries ($layout)" for layout in (:compact, :app)
        entry = block_entry()
        none = CatalogEntry("Plain block", checked_block; group = "Blocks")
        gui, _ = _fixture(; layout, catalog = [entry, none])
        @test gui.components.catalog == [entry, none]
        w = _widgets(gui)
        # one group with the icon of an own group, its tiles and the form of its first entry
        @test w.widget.groups == ["Blocks"] && length(w.widget.group_buttons) == 1
        @test w.widget.group_label.text[] == "Blocks"
        @test _tiles(w.widget) == ["Block", "Plain block"] && _active(w.widget) == ["Block"]
        @test GUI._catalog_group_icon(gui.components.catalog, "Blocks") === :object
        @test _texts(w.boxes) == ["10", "2"]
        @test "width" in w.labels && "scale" in w.labels && "mm" in w.labels
        # an entry without parameters has no boxes
        w = _choose!(gui, "Plain block")
        @test isempty(w.boxes) && isempty(gui.custom.boxes) && isempty(w.menus)
        @test "no parameters" in w.labels
        # the global catalog is not changed
        @test !any(e -> e === entry, component_catalog())
        close(gui)
    end

    @testset "target system ($layout)" for layout in (:compact, :app)
        gui, sys, m, sys2, m2 = _fixture(; layout, two = true, label = "Main")
        w = _widgets(gui)
        # the first system, by its label
        @test GUI._target_system(gui) === sys
        @test w.target.text[] == "into: Main"
        # the system of the selected component
        gui.controls.selected[] = m2
        @test GUI._target_system(gui) === sys2
        @test w.target.text[] == "into: System 2"
        gui.controls.selected[] = m
        @test w.target.text[] == "into: Main"
        gui.controls.selected[] = nothing
        @test w.target.text[] == "into: Main"
        close(gui)
    end

    @testset "window ($layout, $theme)" for (layout, theme) in ((:compact, :light), (:app, :dark))
        gui, sys, m = _fixture(; layout, theme)
        ctrl = gui.controls
        ev = events(gui.ax.scene)
        win = _window(gui)
        w = _widgets(gui)
        key!(key) = (ev.keyboardbutton[] = Makie.KeyEvent(key, Keyboard.press))
        mouse!(p) = (ev.mouseposition[] = (Float64(p[1]), Float64(p[2])))
        press!() = (ev.mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.press))
        release!() = (ev.mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.release))
        view = Rect2f(Makie.viewport(gui.ax.scene)[])
        at(fx, fy) = Point2f(minimum(view) .+ Makie.widths(view) .* Point2f(fx, fy))
        corner() = (r = GUI._catalog_rect(win); Point2f(minimum(r)[1], maximum(r)[2]))
        inside() = (r = GUI._catalog_rect(win); all(minimum(r) .>= minimum(view)) && all(maximum(r) .<= maximum(view)))

        # the key Insert shows the window with its top left corner at the mouse
        p = at(0.3, 0.8)
        mouse!(p)
        key!(Keyboard.insert)
        @test win.shown && win.tool.active[]
        @test corner() ≈ p atol = 0.5
        @test inside() && GUI._catalog_rects(gui) == [GUI._catalog_rect(win)]
        size = Makie.widths(GUI._catalog_rect(win))
        @test all(size .> 100)
        # nothing is placed by the key
        @test !GUI._placing(gui) && sys.objects == [m]
        # again, elsewhere: the window moves there; near an edge it stays inside the 3D view
        p = at(0.5, 0.5)
        mouse!(p)
        key!(Keyboard.insert)
        @test corner() ≈ p atol = 0.5
        mouse!(at(0.99, 0.02))
        key!(Keyboard.insert)
        @test inside() && Makie.widths(GUI._catalog_rect(win)) ≈ size
        @test maximum(GUI._catalog_rect(win))[1] ≈ maximum(view)[1] - GUI._OVERLAY_MARGIN atol = 0.5
        @test minimum(GUI._catalog_rect(win))[2] ≈ minimum(view)[2] + GUI._OVERLAY_MARGIN atol = 0.5

        # the mouse on the window belongs to it: the controls ignore it
        mouse!(at(0.5, 0.5))
        key!(Keyboard.insert)
        mouse!(corner() .+ Point2f(200, -50))
        @test GUI._over_catalog(gui) && ctrl.ignore_mouse()
        selected = ctrl.selected[]
        press!()
        release!()
        @test ctrl.selected[] === selected
        mouse!(at(0.05, 0.05))
        @test !GUI._over_catalog(gui)

        # a drag at the head moves the window
        c0 = corner()
        handle = c0 .+ Point2f(60, -22)
        @test GUI._over_catalog_handle(win, handle)
        mouse!(handle)
        press!()
        mouse!(handle .+ Point2f(-80, 45))
        @test corner() ≈ c0 .+ Point2f(-80, 45) atol = 0.5
        mouse!(handle .+ Point2f(-40, 20))
        release!()
        @test corner() ≈ c0 .+ Point2f(-40, 20) atol = 0.5
        # released: the mouse no longer moves it
        mouse!(handle .+ Point2f(100, 100))
        @test corner() ≈ c0 .+ Point2f(-40, 20) atol = 0.5
        # dragged beyond the 3D view, it stays inside
        mouse!(corner() .+ Point2f(60, -22))
        press!()
        mouse!(Point2f(minimum(view) .- 500))
        release!()
        @test inside()
        # the close button is no handle
        close_rect = Rect2f(win.close_button.box.layoutobservables.computedbbox[])
        @test !GUI._over_catalog_handle(win, Point2f(minimum(close_rect) .+ Makie.widths(close_rect) ./ 2))

        # "Place" places the chosen entry with the values of its boxes, the window stays
        w.boxes[3].displayed_string[] = "12"
        w.place.clicks[] += 1
        @test GUI._placing(gui) && win.shown
        @test gui.components.placement.obj isa Lens
        @test gui.components.placement.origin.code == "ThinLens(0.05, -0.05, 0.012, $bk7)"
        key!(Keyboard.escape)
        @test !GUI._placing(gui) && win.shown
        @test sys.objects == [m]

        # the close button hides it; its toggle follows and shows it where it was
        c0 = corner()
        w.boxes[1].focused[] = true
        only(w.menus).is_open[] = true
        win.close_button.clicks[] += 1
        @test !win.shown && !win.tool.active[] && isempty(GUI._catalog_rects(gui))
        @test !w.boxes[1].focused[] && !only(w.menus).is_open[] && !GUI._typing(gui)
        @test !GUI._over_catalog(gui)
        win.tool.active[] = true
        @test win.shown
        @test corner() ≈ c0 atol = 0.5
        win.tool.active[] = false
        @test !win.shown
        # without the mouse in the 3D view, the key shows it where it was
        mouse!(Point2f(-10, -10))
        key!(Keyboard.insert)
        @test win.shown
        @test corner() ≈ c0 atol = 0.5

        # not while a box takes the keyboard, and not in the spectator mode, which hides the window
        win.close_button.clicks[] += 1
        w.boxes[1].focused[] = true
        key!(Keyboard.insert)
        @test !win.shown
        w.boxes[1].focused[] = false
        key!(Keyboard.insert)
        @test win.shown
        GUI._set_spectator!(ctrl, true)
        GUI._arrange_catalog!(gui)
        @test isempty(GUI._catalog_rects(gui)) && !GUI._over_catalog(gui)
        GUI._set_spectator!(ctrl, false)
        GUI._arrange_catalog!(gui)
        @test GUI._catalog_rects(gui) == [GUI._catalog_rect(win)]

        # the floating cards keep off the window
        @test GUI._catalog_rect(win) in GUI._obstacles(gui)

        # the entry with the most parameters fits into the 3D view
        _choose!(gui, "Triplet")
        _tick!(gui)
        @test length(win.widget.boxes) == 8 && length(win.widget.menus) == 3
        @test inside() && Makie.widths(GUI._catalog_rect(win))[2] < Makie.widths(view)[2]
        _choose!(gui, "Thin lens")

        # the key is taken, a tool can not use it, and it is listed in the help
        @test occursin("Insert", GUI._key_binding(gui, Keyboard.insert))
        @test_throws ArgumentError add_tool!(g -> nothing, gui, "x"; key = Keyboard.insert)
        sections = GUI._help_sections(gui.controls)
        components = only(filter(s -> s.first == "Components", sections)).second
        @test first(components).keys == ["Ins"] && occursin("open the catalog", first(components).text)
        @test any(e -> occursin("move it", e.text), components)
        @test any(e -> occursin("snap", e.text), components)
        @test any(e -> occursin("Esc cancels", e.text), components)
        close(gui)

        # a view without a catalog has neither the key nor the section
        gui, _ = _fixture(; layout, theme, catalog = CatalogEntry[])
        events(gui.ax.scene).keyboardbutton[] = Makie.KeyEvent(Keyboard.insert, Keyboard.press)
        @test isnothing(_window(gui)) && isempty(GUI._catalog_rects(gui)) && !GUI._over_catalog(gui)
        @test !any(s -> s.first == "Components", GUI._help_sections(gui.controls))
        close(gui)
    end

    @testset "invalid input ($layout)" for layout in (:compact, :app)
        entry = block_entry()
        checked = CatalogEntry("Checked block", checked_block; group = "Blocks",
            params = [CatalogParam("width", 10e-3; unit = "mm", scale = 1e-3)])
        gui, sys, m = _fixture(; layout, catalog = [entry, checked])
        w = _widgets(gui)
        objects = copy(sys.objects)
        unchanged() = sys.objects == objects && !GUI._placing(gui) && isempty(gui.components.added)

        # not a number
        gui.status.text[] = ""
        @test isnothing(GUI._place_catalog!(gui, entry, ["abc", "2"]))
        @test occursin("Block not placed", gui.status.text[])
        @test occursin("invalid input \"abc\" for width", gui.status.text[])
        @test unchanged()
        # the constructor throws
        gui.status.text[] = ""
        @test isnothing(GUI._place_catalog!(gui, checked, ["-1"]))
        @test occursin("Checked block not placed", gui.status.text[])
        @test occursin("the width must be positive", gui.status.text[])
        @test unchanged()

        # the same via the widget: the typed text counts, also without Enter
        gui.status.text[] = ""
        w.boxes[2].displayed_string[] = "two"
        w.place.clicks[] += 1
        @test occursin("invalid input \"two\" for scale", gui.status.text[])
        @test unchanged()
        w = _choose!(gui, "Checked block")
        gui.status.text[] = ""
        w.boxes[1].displayed_string[] = "-5"
        w.place.clicks[] += 1
        @test occursin("the width must be positive", gui.status.text[])
        @test unchanged()
        close(gui)
    end
end

end
