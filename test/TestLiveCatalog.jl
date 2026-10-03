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

# The constructor of a source that returns an object, and the one of a component that returns a beam
block_at(pos, dir, width::Real) = CatalogBlock(width)
ray_of(λ::Real) = Beam([0.0, 0, 0], [0.0, 1, 0], λ)

@testset "Live view catalog" begin
    width_param() = CatalogParam("width", 10e-3; unit = "mm", scale = 1e-3)
    block_entry() = CatalogEntry("Block", CatalogBlock; group = "Blocks", params = [
        width_param(),
        CatalogParam("scale", 2.0; keyword = :scale)])

    # Rays along +y onto a mirror, in one system named `label`; a second pair with `two`. The
    # catalog shows the thin lens, in its window and in its dock, unless `lens = false`: then its
    # first entry, a source
    function _fixture(; two::Bool = false, label = nothing, lens::Bool = true, kwargs...)
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
        lens && _show_entry!(gui, "Thin lens")
        return gui, sys, m, sys2, m2
    end

    _window(gui) = GUI._catalog_window(gui)

    # Chooses the entry `name` in all widgets of the catalog of the `gui`, if it has the entry
    function _show_entry!(gui, name)
        win = _window(gui)
        isnothing(win) && return nothing
        for widget in GUI._catalog_widgets(win)
            i = findfirst(e -> e.name == name, widget.entries)
            isnothing(i) && continue
            GUI._set_catalog_group!(gui, widget, findfirst(==(widget.entries[i].group), widget.groups))
            GUI._select_catalog_entry!(gui, widget, i)
        end
        return nothing
    end

    # The widgets of the catalog of the `gui` that are in use, i.e. of its window or of its dock, in
    # the order in which they were built
    function _widgets(gui)
        widget = GUI._catalog_widget(_window(gui))
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
        widget = GUI._catalog_widget(_window(gui))
        widget.group_buttons[findfirst(==(group), widget.groups)].clicks[] += 1
        return widget
    end

    # Clicks the tile of the entry `name` of the catalog of the `gui`, after the icon of its group
    function _choose!(gui, name)
        widget = GUI._catalog_widget(_window(gui))
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
            widget = GUI._catalog_widget(_window(gui))
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

        # a whole number is passed as an `Int` and written without a decimal point
        count = CatalogParam("count", 3; keyword = :scale, integer = true)
        @test count.integer && !width_param().integer
        counted = CatalogEntry("x", CatalogBlock; params = [width_param(), count])
        positional, keywords = GUI._catalog_args(counted, [5e-3, 4.0])
        @test positional == [5e-3] && only(keywords) == (:scale => 4) && last(only(keywords)) isa Int
        @test GUI._catalog_code(counted, [5e-3, 4.0]) == "CatalogBlock(0.005; scale = 4)"
        @test GUI._catalog_object(counted, [5e-3, 4.0]) isa CatalogBlock
        @test GUI._catalog_string(count) == "3"
        @test GUI._catalog_value(count, "3") === 3.0 && GUI._catalog_value(count, "") === 3.0
        @test GUI._catalog_value(count, " 12 ") === 12.0 && GUI._catalog_value(count, "1e3") === 1000.0
        for s in ("2.5", "Inf", "abc")
            @test_throws ArgumentError GUI._catalog_value(count, s)
        end
        @test_throws "enter a whole number" GUI._catalog_value(count, "2.5")
        @test_throws ArgumentError GUI._catalog_component(counted, ["4", "2.5"])
        @test GUI._catalog_component(counted, ["4", "2"]).origin.code == "CatalogBlock(0.004; scale = 2)"
        @test_throws ArgumentError CatalogParam("count", 2.5; integer = true)

        # a source: the position and the direction come before the parameters
        wavelength = CatalogParam("wavelength", 500e-9; unit = "nm", scale = 1e-9)
        ray = CatalogEntry("Ray", Beam; group = "Sources", params = [wavelength], source = true)
        @test ray.source && !entry.source
        beam = GUI._catalog_object(ray, [600e-9])
        @test beam isa Beam && BMO.wavelength(beam) == 600e-9
        @test position(beam) == [0, 0, 0] && BMO.direction(beam) == [0, 1, 0]
        @test GUI._catalog_code(ray, [600e-9]) == "Beam([0.0, 0.0, 0.0], [0.0, 1.0, 0.0], 6.0e-7)"
        twin = Core.eval(@__MODULE__, Meta.parse(GUI._catalog_code(ray, [600e-9])))
        @test typeof(twin) === typeof(beam) && BMO.wavelength(twin) == 600e-9
        # without parameters and with keywords only
        @test GUI._catalog_code(CatalogEntry("x", Beam; source = true), Float64[]) ==
              "Beam([0.0, 0.0, 0.0], [0.0, 1.0, 0.0])"
        rings = CatalogEntry("x", CollimatedSource; source = true,
            params = [CatalogParam("d", 1e-3), CatalogParam("rings", 2; keyword = :num_rings, integer = true)])
        @test GUI._catalog_code(rings, [1e-3, 2.0]) ==
              "CollimatedSource([0.0, 0.0, 0.0], [0.0, 1.0, 0.0], 0.001; num_rings = 2)"
        @test GUI._catalog_object(rings, [1e-3, 2.0]) isa CollimatedSource
        c = GUI._catalog_component(ray, ["650"])
        @test c.obj isa Beam && BMO.wavelength(c.obj) == 650e-9
        @test c.origin.code == "Beam([0.0, 0.0, 0.0], [0.0, 1.0, 0.0], 6.5e-7)"
        @test first(c.origin.pose0) == [0, 0, 0]
        # the constructor of a source returns an object, and the one of a component a beam
        @test_throws ArgumentError GUI._catalog_object(
            CatalogEntry("x", block_at; params = [width_param()], source = true), [5e-3])
        @test_throws ArgumentError GUI._catalog_object(CatalogEntry("x", ray_of; params = [wavelength]), [1e-6])

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
        gui, sys, m = _fixture(; layout, theme, lens = false)
        entries = gui.components.catalog
        # the window of both layouts, hidden at first, with the toggle of the layout; the catalog
        # is docked in a layout with a place for it, and open there
        win = _window(gui)
        docks = layout == :app
        @test win isa GUI._CatalogWindow && !win.shown && !win.pinned && !win.collapsed
        @test win.docked == docks && isnothing(win.dock) == !docks && win.tool.active[] == docks
        @test isempty(GUI._catalog_rects(gui))
        @test isempty(filter(c -> c.title == "Components", gui.custom.controls))
        w = _widgets(gui)
        widget = w.widget
        @test w.layout === (docks ? win.dock.widget : win.widget).layout
        # the boxes and the menus of the widgets that are not in use, i.e. of the hidden window
        other_boxes() = Textbox[b for x in GUI._catalog_widgets(win) if x !== widget for b in x.boxes]
        other_menus() = Menu[mn for x in GUI._catalog_widgets(win) if x !== widget for mn in x.menus]
        @test isempty(other_boxes()) == !docks
        @test w.target.text[] == "into: System 1"
        @test w.place.label[] == "Place"
        # an icon per group, the first group and its first entry are chosen
        @test widget.groups == unique(e.group for e in entries)
        @test length(widget.group_buttons) == length(widget.groups) == 8
        # the sources are the first group: the form of a beam is its wavelength
        @test first(widget.groups) == "Sources"
        @test [b.active[] for b in widget.group_buttons] == (1:8 .== 1)
        @test widget.group_label.text[] == "Sources"
        @test _tiles(widget) == ["Beam", "Gaussian beamlet", "Collimated source", "Uniform disc source",
            "Point source", "Uniform point source", "Astigmatic Gaussian beamlet"]
        @test _active(widget) == ["Beam"] && widget.entry_label.text[] == "Beam"
        @test GUI._catalog_entry(widget) === first(entries) && first(entries).source
        @test _texts(w.boxes) == ["632.8"] && isempty(w.menus)
        @test "wavelength" in w.labels && "nm" in w.labels
        # whole numbers and an angle in degrees
        w = _choose!(gui, "Point source")
        @test _texts(w.boxes) == ["5", "632.8", "10"]
        @test "half angle" in w.labels && "°" in w.labels && "rings" in w.labels
        w.boxes[3].displayed_string[] = "2.5"
        gui.status.text[] = ""
        w.place.clicks[] += 1
        @test occursin("invalid input \"2.5\" for rings, enter a whole number", gui.status.text[])
        @test !GUI._placing(gui)
        # the lenses
        w = _choose!(gui, "Thin lens")
        @test [b.active[] for b in widget.group_buttons] == (1:8 .== 2)
        @test widget.group_label.text[] == "Lenses"
        @test _tiles(widget) == ["Thin lens", "Singlet", "Doublet", "Triplet"]
        @test _active(widget) == ["Thin lens"] && widget.entry_label.text[] == "Thin lens"
        # the name of the group under the mouse
        widget.group_buttons[4].hovered[] = true
        @test widget.group_label.text[] == "Curved mirrors"
        widget.group_buttons[4].hovered[] = false
        @test widget.group_label.text[] == "Lenses"
        # a box per number with its default, between its name and its unit, a menu per glass
        lens = GUI._catalog_entry(widget)
        @test lens.constructor === ThinLens
        @test _texts(w.boxes) == ["50", "-50", "25.4"]
        @test all(p -> p.name in w.labels, lens.params)
        @test count(==("mm"), w.labels) == 3
        menu = only(w.menus)
        @test menu.selection[] == "N-BK7"
        @test menu.options[] == [first.(catalog_glasses()); "constant"]
        @test GUI._catalog_strings(widget) == ["50", "-50", "25.4", "N-BK7"]
        # the boxes and the menu take the keyboard
        @test Set(gui.custom.boxes) == Set([w.boxes; other_boxes()]) && widget.boxes == w.boxes
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
        @test Set(gui.custom.boxes) == Set([w.boxes; other_boxes()]) && !(menu in gui.custom.menus)
        @test Set(gui.custom.menus) == Set([w.menus; other_menus()])
        @test "glass 2" in w.labels && !("glass" in w.labels)
        w.boxes[3].focused[] = true
        @test GUI._typing(gui)
        w.boxes[3].focused[] = false

        # another group: its tiles, its first entry is chosen
        w = _choose!(gui, "Thin beamsplitter")
        @test [b.active[] for b in widget.group_buttons] == (1:8 .== 5)
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
        # besides those of the hidden window of a docked catalog
        @test filter(b -> b in w.boxes, gui.custom.boxes) == w.boxes
        @test length(gui.custom.boxes) == (layout == :app ? 7 : 4)
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
        # no system that components can be added to: only the sources, see `TestLiveSources.jl`,
        # and no widget without them
        m = RoundPlanoMirror(25e-3, 5e-3)
        translate3d!(m, [0, 0.1, 0])
        static() = StaticSystem([m]) => Beam([0.0, 0, 0], [0.0, 1, 0], 1e-6)
        gui = live_view(static(); layout, trace_budget = Inf)
        @test all(e -> e.source, GUI._catalog_widget(_window(gui)).entries)
        close(gui)
        gui = live_view(static(); layout, trace_budget = Inf,
            catalog = [e for e in component_catalog() if !e.source])
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
        @test isempty(w.boxes) && isempty(w.menus)
        # the hidden window of a docked catalog keeps its entry
        @test isempty(gui.custom.boxes) == (layout == :compact)
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
        docks = !isnothing(win.dock)
        key!(key) = (ev.keyboardbutton[] = Makie.KeyEvent(key, Keyboard.press))
        mouse!(p) = (ev.mouseposition[] = (Float64(p[1]), Float64(p[2])))
        press!() = (ev.mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.press))
        release!() = (ev.mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.release))
        view = Rect2f(Makie.viewport(gui.ax.scene)[])
        at(fx, fy) = Point2f(minimum(view) .+ Makie.widths(view) .* Point2f(fx, fy))
        corner() = (r = GUI._catalog_rect(win); Point2f(minimum(r)[1], maximum(r)[2]))
        inside() = (r = GUI._catalog_rect(win); all(minimum(r) .>= minimum(view)) && all(maximum(r) .<= maximum(view)))
        # Closes the window: its close button, or its dock button in a layout with a dock
        close!() = ((docks ? win.dock_button : win.close_button).clicks[] += 1)

        # the key Insert shows the window with its top left corner at the mouse, as a popup
        p = at(0.3, 0.8)
        mouse!(p)
        key!(Keyboard.insert)
        @test win.shown && !win.pinned && !win.docked && win.tool.active[]
        @test GUI._catalog_widget(win) === win.widget
        w = _widgets(gui)
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
        # the buttons of the head are no handles: the pin, the chevron and the close or dock button
        buttons = filter(!isnothing, (win.dock_button, win.pin_button, win.collapse_button, win.close_button))
        @test length(buttons) == 3 && isnothing(win.close_button) == docks
        for b in buttons
            r = Rect2f(b.box.layoutobservables.computedbbox[])
            @test r in GUI._catalog_rect(win)
            @test !GUI._over_catalog_handle(win, Point2f(minimum(r) .+ Makie.widths(r) ./ 2))
        end

        # "Place" places the chosen entry with the values of its boxes; the window stays while
        # the component is placed, and when that is cancelled
        w.boxes[3].displayed_string[] = "12"
        w.place.clicks[] += 1
        @test GUI._placing(gui) && win.shown
        @test gui.components.placement.obj isa Lens
        @test gui.components.placement.origin.code == "ThinLens(0.05, -0.05, 0.012, $bk7)"
        key!(Keyboard.escape)
        @test !GUI._placing(gui) && win.shown
        @test sys.objects == [m]

        # closing hides it; with a dock, the catalog is open there
        c0 = corner()
        w.boxes[1].focused[] = true
        only(w.menus).is_open[] = true
        close!()
        @test !win.shown && isempty(GUI._catalog_rects(gui))
        @test !w.boxes[1].focused[] && !only(w.menus).is_open[] && !GUI._typing(gui)
        @test !GUI._over_catalog(gui)
        @test win.docked == docks && win.tool.active[] == docks
        # without the mouse in the 3D view, the key opens it where it was
        mouse!(Point2f(-10, -10))
        key!(Keyboard.insert)
        if docks
            @test win.docked && !win.shown && win.tool.active[]
        else
            @test win.shown
            @test corner() ≈ c0 atol = 0.5
            # its toggle hides it and shows it where it was
            win.tool.active[] = false
            @test !win.shown
            win.tool.active[] = true
            @test win.shown && !win.pinned
            @test corner() ≈ c0 atol = 0.5
            close!()
        end

        # not while a box takes the keyboard, and not in the spectator mode, which hides the window
        mouse!(at(0.5, 0.5))
        box = first(GUI._catalog_widget(win).boxes)
        box.focused[] = true
        key!(Keyboard.insert)
        @test !win.shown
        box.focused[] = false
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
        @test any(e -> occursin("keep it open", e.text), components)
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

    @testset "pin and minimize ($layout)" for layout in (:compact, :app)
        gui, sys, m = _fixture(; layout)
        ev = events(gui.ax.scene)
        win = _window(gui)
        docks = layout == :app
        key!(key) = (ev.keyboardbutton[] = Makie.KeyEvent(key, Keyboard.press))
        mouse!(p) = (ev.mouseposition[] = (Float64(p[1]), Float64(p[2])))
        view = Rect2f(Makie.viewport(gui.ax.scene)[])
        at(fx, fy) = Point2f(minimum(view) .+ Makie.widths(view) .* Point2f(fx, fy))
        corner() = (r = GUI._catalog_rect(win); Point2f(minimum(r)[1], maximum(r)[2]))
        size() = Makie.widths(GUI._catalog_rect(win))
        # Places the entry of the window and drops it where it is
        function drop!()
            win.widget.place.clicks[] += 1
            @test GUI._placing(gui) && win.shown
            GUI._drop_placement!(gui)
            return nothing
        end

        # a popup: it closes when the component was dropped
        p = at(0.3, 0.8)
        mouse!(p)
        key!(Keyboard.insert)
        @test win.shown && !win.pinned && !win.pin_button.active[]
        drop!()
        @test length(sys.objects) == 2 && !GUI._placing(gui)
        @test !win.shown && win.docked == docks && isempty(GUI._catalog_rects(gui))

        # pinned, it stays open at its place, also for the key
        mouse!(p)
        key!(Keyboard.insert)
        win.pin_button.active[] = true
        @test win.pinned && win.shown
        c0 = corner()
        drop!()
        @test length(sys.objects) == 3 && win.shown && win.pinned && win.pin_button.active[]
        mouse!(at(0.6, 0.5))
        key!(Keyboard.insert)
        @test corner() ≈ c0 atol = 0.5

        # minimized, it shows only its head, which is its handle; the inputs are kept
        box = first(win.widget.boxes)
        box.displayed_string[] = "33"
        box.focused[] = true
        size0 = size()
        win.collapse_button.clicks[] += 1
        @test win.collapsed && !win.body.shown && win.shown && win.tool.active[]
        @test !box.focused[] && !GUI._typing(gui)
        @test size()[2] < 60 && 150 < size()[1] < size0[1]
        @test corner() ≈ c0 atol = 0.5
        r = GUI._catalog_rect(win)
        @test GUI._over_catalog_handle(win, Point2f(minimum(r) .+ Point2f(60, 4)))
        @test all(b -> !b.blockscene.visible[], win.widget.boxes)
        # the chevron expands it again
        win.collapse_button.clicks[] += 1
        @test !win.collapsed && win.body.shown && size() ≈ size0
        @test all(b -> b.blockscene.visible[], win.widget.boxes)
        @test first(GUI._catalog_strings(win.widget)) == "33"
        # and so does the key
        win.collapse_button.clicks[] += 1
        @test win.collapsed
        key!(Keyboard.insert)
        @test !win.collapsed && win.pinned && size() ≈ size0
        @test corner() ≈ c0 atol = 0.5

        # unpinning closes it
        win.pin_button.active[] = false
        @test !win.pinned && !win.shown && win.docked == docks && !win.pin_button.active[]
        # closed while pinned, it is a popup again
        mouse!(p)
        key!(Keyboard.insert)
        win.pin_button.active[] = true
        (docks ? win.dock_button : win.close_button).clicks[] += 1
        @test !win.shown && !win.pinned && !win.pin_button.active[]
        mouse!(at(0.5, 0.6))
        key!(Keyboard.insert)
        @test win.shown && !win.pinned
        @test corner() ≈ at(0.5, 0.6) atol = 0.5
        close(gui)
    end

    @testset "dock of the app layout" begin
        gui, sys, m = _fixture(; layout = :app)
        ev = events(gui.ax.scene)
        layout = gui.layout
        win = _window(gui)
        d = win.dock
        entries = gui.components.catalog
        key!(key) = (ev.keyboardbutton[] = Makie.KeyEvent(key, Keyboard.press))
        mouse!(p) = (ev.mouseposition[] = (Float64(p[1]), Float64(p[2])))
        view = Rect2f(Makie.viewport(gui.ax.scene)[])
        p = Point2f(minimum(view) .+ Makie.widths(view) .* Point2f(0.3, 0.8))
        corner() = (r = GUI._catalog_rect(win); Point2f(minimum(r)[1], maximum(r)[2]))
        bbox(x) = Rect2f(x.layoutobservables.computedbbox[])
        visible(widget) = [b.blockscene.visible[] for b in GUI._blocks!(Any[], widget.layout)]
        # The widgets of the dock lie inside the sidebar, within its padding
        function inside()
            side, r = bbox(layout.left.grid), bbox(d.widget.layout)
            return minimum(r)[1] >= minimum(side)[1] + GUI._SIDEBAR_PADDING - 0.5 &&
                   maximum(r)[1] <= maximum(side)[1] - GUI._SIDEBAR_PADDING + 0.5
        end

        # docked and open at the start: the section "Components" of the left sidebar
        @test win.docked && !win.shown && !d.collapsed && d.part.shown && win.tool.active[]
        @test first.(layout.sections[:left]) == ["Objects", "Components"]
        @test GUI._catalog_widget(win) === d.widget
        @test GUI._catalog_widgets(win) == (win.widget, d.widget)
        @test isempty(GUI._catalog_rects(gui)) && !GUI._over_catalog(gui)
        @test all(visible(d.widget)) && inside()
        # the buttons of the dock are in the title row of the section
        title = bbox(d.float_button.box)
        @test maximum(title)[1] < minimum(bbox(d.collapse_button.box))[1] + 1
        @test minimum(title)[2] > maximum(bbox(d.widget.layout))[2] - 1

        # icons without names in rows of five, the name of the one under the mouse
        @test d.widget.style.tiles_per_row == 5 && isnothing(d.widget.style.tile_width)
        @test win.widget.style.tiles_per_row == 4 && win.widget.style.tile_width == 86
        curved = [e.name for e in entries if e.group == "Curved mirrors"]
        _group!(gui, "Curved mirrors")
        tiles = last.(d.widget.tile_buttons)
        @test length(tiles) == length(curved) > 5
        @test all(t -> isempty(t.label[]), tiles)
        rects = [Rect2f(t.box.layoutobservables.computedbbox[]) for t in tiles]
        @test minimum(rects[5])[2] ≈ minimum(rects[1])[2] && minimum(rects[5])[1] > minimum(rects[4])[1]
        @test minimum(rects[6])[2] < minimum(rects[1])[2] && minimum(rects[6])[1] ≈ minimum(rects[1])[1]
        @test d.widget.entry_label.text[] == curved[1]
        tiles[3].hovered[] = true
        @test d.widget.entry_label.text[] == curved[3] && _active(d.widget) == [curved[1]]
        tiles[3].hovered[] = false
        @test d.widget.entry_label.text[] == curved[1]
        @test inside()

        # the form in one column, the box of a constant glass below its menu
        _choose!(gui, "Triplet")
        _tick!(gui)
        @test length(d.widget.boxes) == 8 && length(d.widget.menus) == 3
        @test allequal(round(minimum(bbox(b))[1]) for b in d.widget.boxes)
        @test inside()
        menu = first(d.widget.menus)
        menu.i_selected[] = length(menu.options[])
        _tick!(gui)
        @test length(d.widget.boxes) == 9 && inside()
        constant = last(d.widget.boxes)
        @test maximum(bbox(constant))[2] < minimum(bbox(first(d.widget.menus)))[2] + 1
        first(d.widget.boxes).displayed_string[] = "61"
        strings = GUI._catalog_strings(d.widget)
        @test strings[1] == "61" && strings[9] == "1.5" && strings[10] == "N-SF5"

        # the float button: the window, pinned, shows the same; the dock keeps its title
        d.float_button.clicks[] += 1
        @test !win.docked && win.shown && win.pinned && win.pin_button.active[]
        @test !d.part.shown && !any(visible(d.widget)) && win.tool.active[]
        @test GUI._catalog_widget(win) === win.widget
        @test GUI._catalog_strings(win.widget) == strings
        @test win.widget.group == d.widget.group && _active(win.widget) == ["Triplet"]
        @test GUI._catalog_rects(gui) == [GUI._catalog_rect(win)]
        @test length(win.widget.boxes) == 9
        # "Place" of the window places with its values; pinned, it stays
        first(win.widget.boxes).displayed_string[] = "62"
        win.widget.place.clicks[] += 1
        @test GUI._placing(gui)
        @test startswith(gui.components.placement.origin.code, "SphericalTripletLens(0.062, ")
        GUI._drop_placement!(gui)
        @test length(sys.objects) == 2 && win.shown

        # the dock button of the window: back, with what the window showed
        win.widget.group_buttons[3].clicks[] += 1
        win.dock_button.clicks[] += 1
        @test win.docked && !win.shown && !win.pinned && d.part.shown && all(visible(d.widget))
        @test isempty(GUI._catalog_rects(gui)) && win.tool.active[]
        @test d.widget.group == 3 && _tiles(d.widget) == _tiles(win.widget)
        @test _active(d.widget) == _active(win.widget) && inside()
        @test GUI._catalog_strings(d.widget) == GUI._catalog_strings(win.widget)

        # minimized by its chevron and by the toggle of the layout
        d.collapse_button.clicks[] += 1
        @test d.collapsed && !d.part.shown && !any(visible(d.widget)) && !win.tool.active[]
        win.tool.active[] = true
        @test !d.collapsed && d.part.shown && all(visible(d.widget))
        win.tool.active[] = false
        @test d.collapsed && win.docked

        # the key Insert: a popup at the mouse, which is docked again once a component was
        # dropped, minimized as before
        mouse!(p)
        key!(Keyboard.insert)
        @test win.shown && !win.pinned && !win.docked && win.tool.active[]
        @test corner() ≈ p atol = 0.5
        win.widget.place.clicks[] += 1
        GUI._drop_placement!(gui)
        @test length(sys.objects) == 3
        @test win.docked && !win.shown && d.collapsed && !d.part.shown && !win.tool.active[]

        # while the catalog floats, both buttons of the dock bring it back
        d.float_button.clicks[] += 1
        @test !win.docked && win.shown && win.pinned
        d.collapse_button.clicks[] += 1
        @test win.docked && !d.collapsed && d.part.shown
        d.float_button.clicks[] += 1
        d.float_button.clicks[] += 1
        @test win.docked && !win.shown && d.part.shown

        # with the sidebar collapsed, the catalog is docked without showing it
        layout.collapse.left.active[] = false
        @test !layout.left.shown
        mouse!(p)
        key!(Keyboard.insert)
        @test win.shown
        win.widget.group_buttons[5].clicks[] += 1
        win.widget.place.clicks[] += 1
        GUI._drop_placement!(gui)
        @test win.docked && !layout.left.shown && !any(visible(d.widget))
        @test d.widget.group == 5 && _tiles(d.widget) == _tiles(win.widget)
        # its toggle shows the sidebar
        win.tool.active[] = false
        @test d.collapsed && !layout.left.shown
        win.tool.active[] = true
        @test layout.left.shown && layout.collapse.left.active[] && d.part.shown
        @test all(visible(d.widget)) && inside()
        close(gui)

        # the compact layout has no dock
        gui, _ = _fixture(; layout = :compact)
        win = _window(gui)
        @test isnothing(win.dock) && isnothing(win.dock_button) && !win.docked
        @test isnothing(GUI._catalog_dock_slot!(gui, "Components"))
        @test GUI._catalog_widgets(win) == (win.widget,)
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
