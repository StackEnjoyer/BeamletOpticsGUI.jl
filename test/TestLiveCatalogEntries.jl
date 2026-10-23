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
    # A module like a script of the user, which only uses BeamletOptics
    _script() = (m = Module(:CatalogScript); Core.eval(m, :(using BeamletOptics)); m)

    @testset "built-in entries" begin
        catalog = GUI._builtin_catalog()
        # the sources come first, see the testset "sources"
        @test unique(e.group for e in catalog) == ["Sources", "Lenses", "Mirrors", "Curved mirrors",
            "Beamsplitters", "Prisms", "Polarizers", "Detectors"]
        @test allunique(e.name for e in catalog)
        entries = filter(e -> !e.source, catalog)
        @test all(e -> e.group != "Sources", entries)
        # all components of BeamletOptics with a constructor of numbers and glasses; the lenses
        # with surfaces are built by the GUI, see `TestLiveSurfaces.jl`
        @test [e.constructor for e in entries] == Any[
            ThinLens, GUI._surface_lens, GUI._surface_doublet, GUI._surface_triplet,
            RoundPlanoMirror, SquarePlanoMirror, RectangularPlanoMirror, SquarePlanoMirror2D,
            RightAnglePrismMirror, Retroreflector,
            SphericalMirror, ParabolicMirror, OffAxisParabolicMirror, ConicMirror, OffAxisConicMirror,
            EllipsoidalMirror, OffAxisEllipsoidalMirror, HyperbolicMirror, OffAxisHyperbolicMirror,
            ThinBeamsplitter, RoundThinBeamsplitter, RectangularPlateBeamsplitter,
            RoundPlateBeamsplitter, CubeBeamsplitter, RectangularCompensatorPlate,
            RightAnglePrism, PolarizationFilter, RoundPolarizationFilter, RoundLinearPolarizer,
            Detector]
        @test all(e -> e.code_name == string(nameof(e.constructor)), filter(e -> e.group != "Lenses", catalog))
        @test [e.code_name for e in entries[1:4]] ==
              ["ThinLens", "SphericalLens", "SphericalDoubletLens", "SphericalTripletLens"]
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

    @testset "sources" begin
        entries = filter(e -> e.source, GUI._builtin_catalog())
        @test all(e -> e.group == "Sources", entries)
        @test GUI._catalog_group_icon(entries, "Sources") === :source
        @test [e.constructor for e in entries] == Any[Beam, GaussianBeamlet, CollimatedSource,
            UniformDiscSource, PointSource, UniformPointSource, AstigmaticGaussianBeamlet]
        @test [e.icon for e in entries] == [:beam, :gaussian_beam, :collimated_source, :disc_source,
            :point_source, :uniform_point_source, :astigmatic_beam]
        # the number of rays of a source
        rays(src::BMO.AbstractBeamGroup) = length(BMO.beams(src))
        rays(::BMO.AbstractBeam) = 1
        for entry in entries
            values = _defaults(entry)
            src = GUI._catalog_object(entry, values)
            @test src isa Union{BMO.AbstractBeam, BMO.AbstractBeamGroup}
            # at the origin along +y, with the wavelength of a helium-neon laser
            @test position(src) == [0, 0, 0]
            @test BMO.direction(src) == [0, 1, 0]
            @test BMO.wavelength(src) == 632.8e-9
            # a new source with every call
            @test GUI._catalog_object(entry, values) !== src
            # the code constructs the same source, in a module that only uses BeamletOptics
            code = GUI._catalog_code(entry, values)
            @test startswith(code, entry.code_name * "([0.0, 0.0, 0.0], [0.0, 1.0, 0.0], ")
            twin = Core.eval(_script(), Meta.parse(code))
            @test typeof(twin) === typeof(src)
            @test BMO.wavelength(twin) == BMO.wavelength(src)
            @test rays(twin) == rays(src)
            @test position(twin) == position(src) && BMO.direction(twin) == BMO.direction(src)
            # the wavelength is shown in nm, whole numbers are written without a decimal point
            wavelength = only(filter(p -> p.name == "wavelength", entry.params))
            @test wavelength.unit == "nm" && GUI._catalog_string(wavelength) == "632.8"
            # ... with the laser lines as its presets, among them the default
            @test first.(wavelength.presets) == ["405 nm", "450 nm", "488 nm", "532 nm", "589 nm",
                "632.8 nm", "780 nm", "850 nm", "1064 nm", "1310 nm", "1550 nm"]
            @test last.(wavelength.presets) == [405e-9, 450e-9, 488e-9, 532e-9, 589e-9, 632.8e-9,
                780e-9, 850e-9, 1064e-9, 1310e-9, 1550e-9]
            @test wavelength.default == 632.8e-9 && GUI._catalog_preset(wavelength, "") == 6
            # a line as chosen in the form is the value of its preset
            for (k, (name, value)) in enumerate(wavelength.presets)
                text = GUI._catalog_number_string(value / wavelength.scale)
                @test name == "$text nm" && GUI._catalog_preset(wavelength, text) == k
                @test GUI._catalog_value(wavelength, text) == value
            end
            # the other parameters have none
            @test all(p -> isempty(p.presets), filter(p -> p isa CatalogParam && p !== wavelength, entry.params))
            for p in filter(p -> p.integer, entry.params)
                @test p.keyword in (:num_rings, :num_rays)
                @test !occursin(".", last(split(code, "$(p.keyword) = ")))
            end
        end
        # the parameters and the code of each source
        _code(constructor) = (e = _entry(entries, constructor); GUI._catalog_code(e, _defaults(e)))
        at = "[0.0, 0.0, 0.0], [0.0, 1.0, 0.0]"
        @test _code(Beam) == "Beam($at, 6.328e-7)"
        @test _code(GaussianBeamlet) == "GaussianBeamlet($at, 6.328e-7, 0.001; P0 = 0.001)"
        @test _code(CollimatedSource) == "CollimatedSource($at, 0.01, 6.328e-7; num_rings = 10)"
        @test _code(UniformDiscSource) == "UniformDiscSource($at, 0.01, 6.328e-7; num_rays = 1000)"
        @test _code(PointSource) == "PointSource($at, $(deg2rad(5)), 6.328e-7; num_rings = 10)"
        @test _code(UniformPointSource) == "UniformPointSource($at, $(deg2rad(5)), 6.328e-7; num_rays = 1000)"
        @test _code(AstigmaticGaussianBeamlet) ==
              "AstigmaticGaussianBeamlet($at, 6.328e-7, 0.001, 0.0005; P0 = 0.001)"
        # the inputs of the form reach the source: the half angle in degrees, the numbers of rays
        point = _entry(entries, UniformPointSource)
        @test [GUI._catalog_string(p) for p in point.params] == ["5", "632.8", "1000"]
        c = GUI._catalog_component(point, ["10", "500", "20"])
        @test rays(c.obj) == 20 && BMO.wavelength(c.obj) == 5e-7
        # an input is rounded to 15 digits, see `_catalog_value`
        @test c.origin.code == "UniformPointSource($at, 0.174532925199433, 5.0e-7; num_rays = 20)"
        @test_throws ArgumentError GUI._catalog_component(point, ["10", "500", "2.5"])
        disc = _entry(entries, UniformDiscSource)
        @test rays(GUI._catalog_component(disc, ["4", "500", "30"]).obj) == 30
        rings = _entry(entries, CollimatedSource)
        @test rays(GUI._catalog_component(rings, ["4", "500", "2"]).obj) <
              rays(GUI._catalog_component(rings, ["4", "500", "4"]).obj)
        gauss = _entry(entries, GaussianBeamlet)
        @test GUI._catalog_component(gauss, ["1064", "0.5", "2"]).origin.code ==
              "GaussianBeamlet($at, 1.064e-6, 0.0005; P0 = 0.002)"
    end

    @testset "parameters reach the constructor" begin
        entries = filter(e -> !e.source, GUI._builtin_catalog())
        # a biconvex thin lens of N-BK7 and its diameter
        lens = _entry(entries, ThinLens)
        @test [p.name for p in lens.params] == ["R1", "R2", "diameter", "glass"]
        @test _defaults(lens) == [50e-3, -50e-3, 25.4e-3, "N-BK7"]
        @test GUI._catalog_code(lens, _defaults(lens)) == "ThinLens(0.05, -0.05, 0.0254, $bk7)"
        @test GUI._catalog_code(lens, [50e-3, -50e-3, 25.4e-3, 1.7]) == "ThinLens(0.05, -0.05, 0.0254, λ -> 1.7)"
        # the glass disperses, a constant refractive index does not
        index(obj, λ) = BMO.refractive_index(obj, λ)
        for constructor in (ThinLens, GUI._surface_lens, CubeBeamsplitter, RightAnglePrism)
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
        doublet = _entry(entries, GUI._surface_doublet)
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
        # the components; adding and removing a source is tested in `TestLiveSources.jl`
        for entry in filter(e -> !e.source, gui.components.catalog)
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
