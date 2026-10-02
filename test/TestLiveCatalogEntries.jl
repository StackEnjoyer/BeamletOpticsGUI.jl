module TestLiveCatalogEntries

using GLMakie, BeamletOptics, BeamletOpticsGUI
using Makie
using Test

const BMO = BeamletOptics
const GUI = BeamletOpticsGUI

@testset "Catalog entries" begin
    _defaults(entry) = Any[GUI._catalog_default(p) for p in entry.params]
    _entry(entries, constructor) = entries[findfirst(e -> e.constructor === constructor, entries)]
    _glasses(entry) = findall(p -> p isa CatalogGlass, entry.params)
    bk7 = "SellmeierEquation(1.03961212, 0.231792344, 1.01046945, 0.00600069867, 0.0200179144, 103.560653)"

    @testset "built-in entries" begin
        entries = GUI._builtin_catalog()
        # all components of BeamletOptics with a constructor of numbers and glasses
        @test [e.constructor for e in entries] == Any[
            ThinLens, SphericalLens, SphericalDoubletLens, SphericalTripletLens,
            RoundPlanoMirror, SquarePlanoMirror, RectangularPlanoMirror, SquarePlanoMirror2D,
            RightAnglePrismMirror, Retroreflector,
            SphericalMirror, ParabolicMirror, OffAxisParabolicMirror, ConicMirror, OffAxisConicMirror,
            EllipsoidalMirror, OffAxisEllipsoidalMirror, HyperbolicMirror, OffAxisHyperbolicMirror,
            ThinBeamsplitter, RoundThinBeamsplitter, RectangularPlateBeamsplitter,
            RoundPlateBeamsplitter, CubeBeamsplitter, RectangularCompensatorPlate,
            RightAnglePrism, PolarizationFilter, RoundPolarizationFilter, RoundLinearPolarizer,
            Detector]
        @test unique(e.group for e in entries) == ["Lenses", "Mirrors", "Curved mirrors",
            "Beamsplitters", "Prisms", "Polarizers", "Detectors"]
        @test allunique(e.name for e in entries)
        @test all(e -> e.code_name == string(nameof(e.constructor)), entries)
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
            @test all(p -> (p.unit == "mm") == (p.scale == 1e-3), filter(p -> p isa CatalogParam, entry.params))
            # the default is a glass, and a constant refractive index works as well
            @test all(i -> values[i] in GUI._glass_names(), _glasses(entry))
            if !isempty(_glasses(entry))
                constant = Any[p isa CatalogGlass ? 1.6 : v for (p, v) in zip(entry.params, values)]
                flat = GUI._catalog_object(entry, constant)
                @test nameof(typeof(flat)) === nameof(typeof(obj))
                code = GUI._catalog_code(entry, constant)
                @test occursin("λ -> 1.6", code) && !occursin("SellmeierEquation", code)
                @test nameof(typeof(Core.eval(@__MODULE__, Meta.parse(code)))) === nameof(typeof(obj))
            end
        end
    end

    @testset "parameters reach the constructor" begin
        entries = GUI._builtin_catalog()
        # a biconvex thin lens of N-BK7 and its diameter
        lens = _entry(entries, ThinLens)
        @test [p.name for p in lens.params] == ["R1", "R2", "diameter", "glass"]
        @test _defaults(lens) == [50e-3, -50e-3, 25.4e-3, "N-BK7"]
        @test GUI._catalog_code(lens, _defaults(lens)) == "ThinLens(0.05, -0.05, 0.0254, $bk7)"
        @test GUI._catalog_code(lens, [50e-3, -50e-3, 25.4e-3, 1.7]) == "ThinLens(0.05, -0.05, 0.0254, λ -> 1.7)"
        # the glass disperses, a constant refractive index does not
        index(obj, λ) = BMO.refractive_index(obj, λ)
        for constructor in (ThinLens, SphericalLens, CubeBeamsplitter, RightAnglePrism)
            entry = _entry(entries, constructor)
            values = _defaults(entry)
            obj = GUI._catalog_object(entry, values)
            @test index(obj, 587.56e-9) ≈ 1.5168 atol = 2e-4
            @test index(obj, 486e-9) > index(obj, 656e-9)
            values[only(_glasses(entry))] = "N-SF11"
            @test index(GUI._catalog_object(entry, values), 587.56e-9) ≈ 1.7847 atol = 2e-4
            values[only(_glasses(entry))] = 1.7
            flat = GUI._catalog_object(entry, values)
            @test index(flat, 486e-9) == index(flat, 656e-9) == 1.7
        end
        # the two glasses of the achromat
        doublet = _entry(entries, SphericalDoubletLens)
        @test [_defaults(doublet)[i] for i in _glasses(doublet)] == ["N-BK7", "N-SF5"]
        splitter = _entry(entries, ThinBeamsplitter)
        @test GUI._catalog_code(splitter, _defaults(splitter)) ==
              "ThinBeamsplitter(0.0254, 0.0254; reflectance = 0.5)"
        @test BMO.reflectance(GUI._catalog_object(splitter, [10e-3, 10e-3, 0.36])) ≈ 0.6
        # the glass is a positional argument before the keyword
        cube = _entry(entries, CubeBeamsplitter)
        @test GUI._catalog_code(cube, _defaults(cube)) == "CubeBeamsplitter(0.0254, $bk7; reflectance = 0.5)"
        prism = _entry(entries, RightAnglePrism)
        @test GUI._catalog_code(prism, [10e-3, 10e-3, 1.7]) == "RightAnglePrism(0.01, 0.01, λ -> 1.7)"
        detector = _entry(entries, Detector)
        @test GUI._catalog_code(detector, [5e-3]) == "Detector(0.005)"
        # an angle in degrees as a keyword
        oap = _entry(entries, OffAxisParabolicMirror)
        @test GUI._catalog_code(oap, _defaults(oap)) == "OffAxisParabolicMirror(0.05, 0.0254; angle = 90.0)"
    end

    @testset "every entry in a view" begin
        sys = System()
        gui = live_view(sys => Beam([0.0, 0, 0], [0.0, 1, 0], 1e-6); trace_budget = Inf, throttle = false)
        for entry in gui.components.catalog
            obj = GUI._catalog_object(entry, _defaults(entry))
            translate_to3d!(obj, [0, 0.1, 0])
            add_component!(gui, obj; label = entry.name)
            @test only(sys.objects) === obj
            @test !isnothing(GUI._child_handle(gui.controls.h, first(BMO.Leaves(obj))))
            remove_component!(gui, obj)
            @test isempty(sys.objects)
        end
        close(gui)
    end

    @testset "icons" begin
        entries = GUI._builtin_catalog()
        # every group and every entry has an icon of the icon set
        for group in unique(e.group for e in entries)
            @test GUI._icon(GUI._catalog_group_icon(entries, group)) isa Makie.BezierPath
        end
        @test all(e -> GUI._icon(GUI._catalog_icon(entries, e)) isa Makie.BezierPath, entries)
        # an entry without an icon shows the one of its group
        plain = CatalogEntry("x", Detector; group = "Lenses")
        @test isnothing(plain.icon) && GUI._catalog_icon(entries, plain) === :lens
        # an own group: the icon of its first entry that has one, otherwise `:object`
        path = Makie.BezierPath("M -0.3 -0.3 L 0.3 -0.3 L 0 0.3 Z")
        own = [CatalogEntry("a", Detector; group = "Own"),
            CatalogEntry("b", Detector; group = "Own", icon = path),
            CatalogEntry("c", Detector; group = "Own", icon = :mirror),
            CatalogEntry("d", Detector; group = "Other")]
        @test GUI._catalog_group_icon(own, "Own") === path
        @test GUI._catalog_icon(own, own[1]) === path && GUI._catalog_icon(own, own[3]) === :mirror
        @test GUI._catalog_group_icon(own, "Other") === :object
        @test_throws ArgumentError CatalogEntry("x", Detector; icon = :no_such_icon)
    end
end

end
