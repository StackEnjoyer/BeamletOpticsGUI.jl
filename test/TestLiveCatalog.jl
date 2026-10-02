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

    _controls(gui) = filter(c -> c.title == "Components", gui.custom.controls)

    # The widgets of the catalog of the `gui`, in the order in which they were built
    function _widgets(gui)
        layout = only(_controls(gui)).layout
        blocks = GUI._blocks!(Any[], layout)
        return (; layout, target = first(filter(b -> b isa Label, blocks)),
            menu = only(filter(b -> b isa Menu, blocks)),
            boxes = filter(b -> b isa Textbox, blocks),
            labels = [b.text[] for b in blocks if b isa Label],
            place = only(filter(b -> b isa Button, blocks)))
    end

    _defaults(entry) = [p.default for p in entry.params]

    @testset "built-in entries" begin
        entries = GUI._builtin_catalog()
        @test [e.constructor for e in entries] == Any[ThinLens, SphericalLens, RoundPlanoMirror,
            SquarePlanoMirror, ThinBeamsplitter, CubeBeamsplitter, RightAnglePrism, Detector]
        @test all(e -> e.group in ("Lenses", "Mirrors", "Beamsplitters", "Prisms", "Detectors"), entries)
        @test allunique(e.name for e in entries)
        for entry in entries
            values = _defaults(entry)
            obj = GUI._catalog_object(entry, values)
            @test obj isa BMO.AbstractObject
            # the code constructs the same component
            code = GUI._catalog_code(entry, values)
            @test startswith(code, entry.code_name * "(")
            twin = Core.eval(@__MODULE__, Meta.parse(code))
            @test typeof(twin) === typeof(obj)
            @test position(twin) == position(obj)
            @test BMO.orientation(twin) == BMO.orientation(obj)
            # lengths are shown in mm
            @test all(p -> (p.unit == "mm") == (p.scale == 1e-3), entry.params)
        end
        # the parameters reach the constructor: a biconvex thin lens and its diameter
        lens = entries[findfirst(e -> e.constructor === ThinLens, entries)]
        @test [p.name for p in lens.params] == ["R1", "R2", "diameter", "n"]
        @test _defaults(lens) == [50e-3, -50e-3, 25.4e-3, 1.5]
        @test GUI._catalog_code(lens, _defaults(lens)) == "ThinLens(0.05, -0.05, 0.0254, 1.5)"
        @test BMO.refractive_index(GUI._catalog_object(lens, [50e-3, -50e-3, 25.4e-3, 1.7]), 1e-6) == 1.7
        splitter = entries[findfirst(e -> e.constructor === ThinBeamsplitter, entries)]
        @test GUI._catalog_code(splitter, _defaults(splitter)) ==
              "ThinBeamsplitter(0.0254, 0.0254; reflectance = 0.5)"
        @test BMO.reflectance(GUI._catalog_object(splitter, [10e-3, 10e-3, 0.36])) ≈ 0.6
        # the refractive index of a cube beamsplitter and of a prism is a number
        cube = entries[findfirst(e -> e.constructor === CubeBeamsplitter, entries)]
        @test GUI._catalog_code(cube, _defaults(cube)) == "CubeBeamsplitter(0.0254, 1.5; reflectance = 0.5)"
        @test BMO.refractive_index(GUI._catalog_object(cube, [10e-3, 1.7, 0.5]), 1e-6) == 1.7
        prism = entries[findfirst(e -> e.constructor === RightAnglePrism, entries)]
        @test GUI._catalog_code(prism, _defaults(prism)) == "RightAnglePrism(0.0254, 0.0254, 1.5)"
        @test BMO.refractive_index(GUI._catalog_object(prism, [10e-3, 10e-3, 1.7]), 1e-6) == 1.7
        detector = entries[findfirst(e -> e.constructor === Detector, entries)]
        @test GUI._catalog_code(detector, [5e-3]) == "Detector(0.005)"
    end

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
            @test last(_widgets(gui).menu.options[]) == ("Blocks / Block", n + 1)
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
        @test length(_controls(gui)) == 1
        w = _widgets(gui)
        if layout == :compact
            # an entry of the tool rail, which opens the catalog in a popover
            item, _ = only(gui.layout.overlay.sections)
            @test item.label[] == "Components"
        else
            # a section of the left sidebar
            @test last(gui.layout.sections[:left]) == ("Components" => w.layout)
        end
        @test w.target.text[] == "into: System 1"
        @test w.place.label[] == "Place (Ins)"
        # the menu lists all entries by group and name, the first one is chosen
        @test first.(w.menu.options[]) == ["$(e.group) / $(e.name)" for e in entries]
        @test w.menu.selection[] == 1
        # a box per parameter with its default, between its name and its unit
        lens = first(entries)
        @test [tb.displayed_string[] for tb in w.boxes] == ["50", "-50", "25.4", "1.5"]
        @test all(p -> p.name in w.labels, lens.params)
        @test count(==("mm"), w.labels) == 3
        # the boxes and the menu take the keyboard
        @test gui.custom.boxes == w.boxes
        @test w.menu in gui.custom.menus
        @test !GUI._typing(gui)
        w.boxes[1].focused[] = true
        @test GUI._typing(gui)

        # another entry: the form is built again, the old boxes are gone
        old = w.boxes
        n = length(gui.controls.listeners)
        k = findfirst(e -> e.constructor === ThinBeamsplitter, entries)
        w.menu.i_selected[] = k
        @test !GUI._typing(gui)
        w = _widgets(gui)
        @test [tb.displayed_string[] for tb in w.boxes] == ["25.4", "25.4", "0.5"]
        @test all(tb -> !any(o -> o === tb, old), w.boxes)
        @test gui.custom.boxes == w.boxes
        @test "reflectance" in w.labels && !("R1" in w.labels)
        w.boxes[3].focused[] = true
        @test GUI._typing(gui)
        w.boxes[3].focused[] = false
        # the listeners of the old boxes are released
        @test length(gui.controls.listeners) <= n
        # and back
        w.menu.i_selected[] = 1
        @test [tb.displayed_string[] for tb in _widgets(gui).boxes] == ["50", "-50", "25.4", "1.5"]
        @test sys.objects == [m]
        close(gui)
    end

    @testset "no widget ($layout)" for layout in (:compact, :app)
        # an empty catalog
        gui, _ = _fixture(; layout, catalog = CatalogEntry[])
        @test isempty(gui.components.catalog)
        @test isempty(_controls(gui))
        @test isempty(gui.custom.boxes)
        close(gui)
        # no system that components can be added to
        m = RoundPlanoMirror(25e-3, 5e-3)
        translate3d!(m, [0, 0.1, 0])
        gui = live_view(StaticSystem([m]) => Beam([0.0, 0, 0], [0.0, 1, 0], 1e-6); layout, trace_budget = Inf)
        @test isempty(_controls(gui))
        close(gui)
        # an empty system gets one
        gui = live_view(System() => Beam([0.0, 0, 0], [0.0, 1, 0], 1e-6); layout, trace_budget = Inf)
        @test length(_controls(gui)) == 1
        close(gui)
    end

    @testset "own entries ($layout)" for layout in (:compact, :app)
        entry = block_entry()
        none = CatalogEntry("Plain block", checked_block; group = "Blocks")
        gui, _ = _fixture(; layout, catalog = [entry, none])
        @test gui.components.catalog == [entry, none]
        w = _widgets(gui)
        @test w.menu.options[] == [("Blocks / Block", 1), ("Blocks / Plain block", 2)]
        @test [tb.displayed_string[] for tb in w.boxes] == ["10", "2"]
        @test "width" in w.labels && "scale" in w.labels && "mm" in w.labels
        # an entry without parameters has no boxes
        w.menu.i_selected[] = 2
        w = _widgets(gui)
        @test isempty(w.boxes) && isempty(gui.custom.boxes)
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

    @testset "the key Insert ($layout)" for layout in (:compact, :app)
        gui, sys, m = _fixture(; layout)
        w = _widgets(gui)
        key!(key) = (events(gui.ax.scene).keyboardbutton[] = Makie.KeyEvent(key, Keyboard.press))
        # presses "Place": the chosen entry with the values of its boxes follows the mouse
        w.boxes[3].displayed_string[] = "12"
        clicks = w.place.clicks[]
        key!(Keyboard.insert)
        @test w.place.clicks[] == clicks + 1
        @test GUI._placing(gui)
        lens = gui.components.placement.obj
        @test lens isa Lens
        @test gui.components.placement.origin.code == "ThinLens(0.05, -0.05, 0.012, 1.5)"
        # again: a new component replaces the one that is being placed
        key!(Keyboard.insert)
        @test GUI._placing(gui) && gui.components.placement.obj !== lens
        key!(Keyboard.escape)
        @test !GUI._placing(gui)
        @test sys.objects == [m]
        # not while a box takes the keyboard
        w.boxes[1].focused[] = true
        key!(Keyboard.insert)
        @test !GUI._placing(gui)
        w.boxes[1].focused[] = false
        # the key is taken, a tool can not use it, and it is listed in the help
        @test occursin("Insert", GUI._key_binding(gui, Keyboard.insert))
        @test_throws ArgumentError add_tool!(g -> nothing, gui, "x"; key = Keyboard.insert)
        sections = GUI._help_sections(gui.controls)
        components = only(filter(s -> s.first == "Components", sections)).second
        @test first(components).keys == ["Ins"]
        @test any(e -> occursin("snap", e.text), components)
        @test any(e -> occursin("Esc cancels", e.text), components)
        close(gui)

        # a view without a catalog has neither the key nor the section
        gui, _ = _fixture(; layout, catalog = CatalogEntry[])
        key!(Keyboard.insert)
        @test !GUI._placing(gui)
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
        w.menu.i_selected[] = 2
        w = _widgets(gui)
        gui.status.text[] = ""
        w.boxes[1].displayed_string[] = "-5"
        w.place.clicks[] += 1
        @test occursin("the width must be positive", gui.status.text[])
        @test unchanged()
        close(gui)
    end
end

end
