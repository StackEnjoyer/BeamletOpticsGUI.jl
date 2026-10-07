module TestLiveSurfaces

using GLMakie, BeamletOptics, BeamletOpticsGUI
using Test

const BMO = BeamletOptics
const GUI = BeamletOpticsGUI

@testset "Catalog surfaces" begin
    catalog = GUI._builtin_catalog()
    _entry(constructor) = catalog[findfirst(e -> e.constructor === constructor, catalog)]
    _defaults(entry) = Any[GUI._catalog_default(p) for p in entry.params]
    # A module like a script of the user, which only uses BeamletOptics
    _script() = (m = Module(:SurfaceScript); Core.eval(m, :(using BeamletOptics)); m)
    bk7 = "SellmeierEquation(1.03961212, 0.231792344, 1.01046945, 0.00600069867, 0.0200179144, 103.560653)"
    # Where a ray parallel to the axis at the height `x` crosses the axis behind the lens
    function _focus(obj; x = 8e-3)
        beam = Beam([x, -0.05, 0], [0.0, 1, 0], 632.8e-9)
        solve_system!(System([obj]), beam)
        ray = last(BMO.rays(beam))
        p, dir = position(ray), BMO.direction(ray)
        return p[2] - p[1] / dir[1] * dir[2]
    end
    zeros7 = fill("0", 7)

    @testset "text" begin
        @test GUI._SURFACE_ORDERS == 4:2:16
        @test GUI._surface_string(false, " 50 ", "-1", ["1e-6"]) == "50"
        @test GUI._surface_string(true, " -50", "-1 ", ["1e-6", " 0"]) == "-50; -1; 1e-6, 0"
        # a `;` or `,` in a field does not divide the text: "1,5" is one field, which is not a number
        @test GUI._surface_string(true, "5;0", "1,5", ["1", "2,"]) == "5 0; 1 5; 1, 2"
        @test GUI._surface_string(false, "5;0", "", String[]) == "5 0"
        @test_throws ArgumentError GUI._catalog_value(GUI.CatalogSurface("S1", 0.05), "50; 1 5; 0")
        # a spherical surface is the text of its radius, the other fields are zero
        @test GUI._surface_fields("50") == (; aspheric = false, radius = "50", conic = "0", coefficients = zeros7)
        @test GUI._surface_fields("") == (; aspheric = false, radius = "", conic = "0", coefficients = zeros7)
        f = GUI._surface_fields(" -50;-1 ; 1e-6, 2e-9 ")
        @test f.aspheric && f.radius == "-50" && f.conic == "-1"
        @test f.coefficients == ["1e-6", "2e-9", "0", "0", "0", "0", "0"]
        # the fields as entered give the text again
        @test GUI._surface_fields(GUI._surface_string(true, f.radius, f.conic, f.coefficients)) == f
        # an asphere whose fields are empty
        empty = GUI._surface_fields(GUI._surface_string(true, "", "", fill("", 7)))
        @test empty.aspheric && empty.radius == "" && empty.conic == "" && empty.coefficients == fill("", 7)
        @test_throws ArgumentError GUI._surface_fields("50; -1")
        @test_throws ArgumentError GUI._surface_fields("50; -1; 0; 0")
        @test_throws ArgumentError GUI._surface_fields("50; -1; 1, 2, 3, 4, 5, 6, 7, 8")
    end

    @testset "value" begin
        p = GUI.CatalogSurface("S1", 50e-3)
        @test GUI._catalog_string(p) == "50" && isnothing(GUI._catalog_keyword(p))
        sphere = GUI._SurfaceValue(50e-3, false, 0.0, Float64[])
        @test GUI._catalog_default(p) == sphere && hash(GUI._catalog_default(p)) == hash(sphere)
        @test GUI._catalog_value(p, "50") == GUI._catalog_value(p, "") == sphere
        # in mm, without the rounding error of the product
        @test GUI._catalog_value(p, "30").radius === 0.03
        @test GUI._catalog_value(p, "Inf").radius == Inf && GUI._catalog_value(p, "-Inf").radius == -Inf
        # an asphere: the coefficients in mm^(1 - order), without the zeros at their end
        v = GUI._catalog_value(p, "-25; -1.5; 1e-6, 0, 2e-12, 0")
        @test v.aspheric && v.radius === -0.025 && v.conic == -1.5
        @test v.coefficients == [1e3, 0.0, 2e9]
        @test GUI._coefficient_scale(4) == 1e9 && GUI._coefficient_scale(16) == 1e45
        # empty fields: the default radius, zero for the others
        blank = GUI._catalog_value(p, "; ; , ,")
        @test blank == GUI._SurfaceValue(50e-3, true, 0.0, Float64[])
        @test blank != sphere
        @test_throws ArgumentError GUI._catalog_value(p, "wide")
        @test_throws ArgumentError GUI._catalog_value(p, "NaN")
        @test_throws ArgumentError GUI._catalog_value(p, "50; k; 0")
        @test_throws ArgumentError GUI._catalog_value(p, "50; Inf; 0")
        @test_throws ArgumentError GUI._catalog_value(p, "50; 0; 1e-6, x")
        @test_throws ArgumentError GUI._catalog_value(p, "50; 0")
        # the surfaces of BeamletOptics and their code, with zero as the coefficient A2
        @test GUI._surface(sphere, 0.02) isa SphericalSurface
        @test GUI._surface_code(sphere, 0.02) == "SphericalSurface(0.05, 0.02)"
        asphere = GUI._surface(v, 0.02)
        @test asphere isa EvenAsphericalSurface && asphere.coefficients == [0.0, 1e3, 0.0, 2e9]
        @test asphere.conic_constant == -1.5 && BMO.radius(asphere) == -0.025 && BMO.diameter(asphere) == 0.02
        @test GUI._surface_code(v, 0.02) == "EvenAsphericalSurface(-0.025, 0.02, -1.5, [0.0, 1000.0, 0.0, 2.0e9])"
        @test GUI._surface_code(blank, 0.02) == "EvenAsphericalSurface(0.05, 0.02, 0.0, [0.0])"
    end

    @testset "singlet" begin
        entry = _entry(GUI._surface_lens)
        @test [p.name for p in entry.params] == ["S1", "S2", "thickness", "diameter", "glass"]
        @test [GUI._catalog_string(p) for p in entry.params] == ["50", "-50", "5", "25.4", "N-BK7"]
        # spherical surfaces: the lens and the code of the `SphericalLens`
        plain = GUI._catalog_component(entry, ["80", "-80", "4", "25.4", "N-SF5"])
        @test plain.origin.strings == ["80", "-80", "4", "25.4", "N-SF5"]
        @test startswith(plain.origin.code, "SphericalLens(0.08, -0.08, 0.004, 0.0254, SellmeierEquation(")
        @test GUI._catalog_code(entry, _defaults(entry)) == "SphericalLens(0.05, -0.05, 0.005, 0.0254, $bk7)"
        # ... also the thin lens of a thickness of zero
        thin = GUI._catalog_component(entry, ["50", "-50", "0", "25.4", "1.5"])
        @test typeof(BMO.shape(thin.obj)) === typeof(BMO.shape(ThinLens(0.05, -0.05, 25.4e-3, 1.5)))
        @test thin.origin.code == "SphericalLens(0.05, -0.05, 0.0, 0.0254, λ -> 1.5)"
        # every combination of spherical and aspheric surfaces: the code builds the same lens
        asphere(r) = "$r; -0.8; 1e-6, -2e-9"
        for front in ("50", asphere(50)), back in ("-50", asphere(-50), "Inf")
            strings = [front, back, "6", "25.4", "N-BK7"]
            c = GUI._catalog_component(entry, strings)
            @test c.obj isa Lens && c.origin.strings == strings
            code = c.origin.code
            GUI._check_code(code)
            twin = Core.eval(_script(), Meta.parse(code))
            @test typeof(twin) === typeof(c.obj) && thickness(twin) == thickness(c.obj)
            @test _focus(twin) == _focus(c.obj)
            aspheric = occursin(";", front) || occursin(";", back)
            @test startswith(code, aspheric ? "Lens(" : "SphericalLens(")
            @test occursin("EvenAsphericalSurface(", code) == aspheric
        end
        code = GUI._catalog_component(entry, ["50", asphere(-50), "6", "25.4", "1.5"]).origin.code
        @test code == "Lens(SphericalSurface(0.05, 0.0254), " *
                      "EvenAsphericalSurface(-0.05, 0.0254, -0.8, [0.0, 1000.0, -2.0e6]), 0.006, λ -> 1.5)"
        # an asphere without a conic constant and without coefficients is the sphere
        sphere = _focus(GUI._catalog_component(entry, ["50", "-50", "6", "25.4", "1.5"]).obj)
        for strings in (["50; 0; 0", "-50", "6", "25.4", "1.5"], ["50", "-50; 0; 0", "6", "25.4", "1.5"],
            ["50; ;", "-50; ;", "6", "25.4", "1.5"])
            same = GUI._catalog_component(entry, strings)
            @test occursin("EvenAsphericalSurface(", same.origin.code)
            @test abs(_focus(same.obj) - sphere) < 1e-9
        end
        # ... and a conic constant changes the focus
        conic = GUI._catalog_component(entry, ["50; -1; 0", "-50", "6", "25.4", "1.5"])
        @test abs(_focus(conic.obj) - sphere) > 1e-5
        # BeamletOptics has no aspheric meniscus without a cylindrical section
        err = try
            GUI._catalog_component(entry, ["30; -1; 0", "25", "1", "25.4", "1.5"])
        catch e
            e
        end
        @test err isa ArgumentError && occursin("meniscus", err.msg)
        @test GUI._catalog_component(entry, ["30; -1; 0", "60", "6", "25.4", "1.5"]).obj isa Lens
        # other errors of the constructor are not taken for it
        @test_throws MethodError GUI._surface_lens(GUI._SurfaceValue(0.03, true, 0.0, Float64[]),
            GUI._SurfaceValue(0.06, false, 0.0, Float64[]), 6e-3, 25.4e-3, "glass")
    end

    @testset "doublet and triplet" begin
        doublet, triplet = _entry(GUI._surface_doublet), _entry(GUI._surface_triplet)
        @test [p.name for p in doublet.params] ==
              ["S1", "S2", "S3", "thickness 1", "thickness 2", "diameter", "glass 1", "glass 2"]
        @test [p.name for p in triplet.params] == ["S1", "S2", "S3", "S4", "thickness 1", "thickness 2",
            "thickness 3", "diameter", "glass 1", "glass 2", "glass 3"]
        # spherical surfaces: the lenses and the code of BeamletOptics
        for (entry, name, type) in ((doublet, "SphericalDoubletLens", DoubletLens),
            (triplet, "SphericalTripletLens", TripletLens))
            strings = String[GUI._catalog_string(p) for p in entry.params]
            c = GUI._catalog_component(entry, strings)
            @test c.obj isa type && c.origin.strings == strings
            @test startswith(c.origin.code, name * "(")
            twin = Core.eval(_script(), Meta.parse(c.origin.code))
            @test typeof(twin) === typeof(c.obj) && thickness(twin) == thickness(c.obj)
        end
        values = Any[v isa String ? 1.5 : v for v in _defaults(doublet)]
        @test GUI._catalog_code(doublet, values) ==
              "SphericalDoubletLens(0.0628, -0.0457, -0.1282, 0.004, 0.0025, 0.0254, λ -> 1.5, λ -> 1.5)"
        # an asphere at any surface, also at a cemented one, which both of its elements get: the
        # lens of BeamletOptics from surfaces, and the code builds the same lens
        for (entry, name, type) in ((doublet, "DoubletLens", DoubletLens), (triplet, "TripletLens", TripletLens))
            surfaces = findall(p -> p isa GUI.CatalogSurface, entry.params)
            defaults = String[GUI._catalog_string(p) for p in entry.params]
            sphere = _focus(GUI._catalog_component(entry, defaults).obj)
            for aspheres in ([[i] for i in surfaces]..., surfaces)
                strings = copy(defaults)
                foreach(i -> strings[i] *= "; -0.5; 1e-6", aspheres)
                c = GUI._catalog_component(entry, strings)
                @test c.obj isa type && c.origin.strings == strings
                code = c.origin.code
                GUI._check_code(code)
                @test startswith(code, name * "(") && !occursin("Spherical$name", code)
                @test count("EvenAsphericalSurface(", code) == length(aspheres)
                @test count("SphericalSurface(", code) == length(surfaces) - length(aspheres)
                twin = Core.eval(_script(), Meta.parse(code))
                @test typeof(twin) === typeof(c.obj) && thickness(twin) == thickness(c.obj)
                @test _focus(twin) == _focus(c.obj) != sphere
                # an asphere without a conic constant and without coefficients is the sphere
                foreach(i -> strings[i] = defaults[i] * "; 0; 0", aspheres)
                same = GUI._catalog_component(entry, strings)
                @test startswith(same.origin.code, name * "(")
                @test abs(_focus(same.obj) - sphere) < 1e-9
            end
        end
        values = Any[GUI._catalog_value(p, s)
                     for (p, s) in zip(doublet.params, ["62.8", "-45.7; -1; 5e-9", "-128.2", "4", "2.5", "25.4", "1.5", "1.7"])]
        @test GUI._catalog_code(doublet, values) ==
              "DoubletLens(SphericalSurface(0.0628, 0.0254), EvenAsphericalSurface(-0.0457, 0.0254, -1.0, [0.0, 5.0]), " *
              "SphericalSurface(-0.1282, 0.0254), 0.004, 0.0025, λ -> 1.5, λ -> 1.7)"
        # an element that BeamletOptics can not build: an aspheric meniscus without a cylindrical section
        err = try
            GUI._catalog_component(doublet, ["30; -1; 0", "25", "-128.2", "1", "2.5", "25.4", "1.5", "1.7"])
        catch e
            e
        end
        @test err isa ArgumentError && occursin("meniscus", err.msg)
    end

    @testset "placing" begin
        sys = System()
        gui = live_view(sys => Beam([0.0, 0, 0], [0.0, 1, 0], 1e-6); trace_budget = Inf, throttle = false)
        # an aspheric singlet is placed with the text of its surfaces
        singlet = _entry(GUI._surface_lens)
        strings = ["50; -1; 1e-6", "-50", "5", "25.4", "N-BK7"]
        lens = GUI._place_catalog!(gui, singlet, strings)
        @test lens isa Lens && gui.components.placement.origin.strings == strings
        @test startswith(gui.components.placement.origin.code, "Lens(EvenAsphericalSurface(0.05, 0.0254, -1.0, [0.0, 1000.0]), ")
        GUI._cancel_placement!(gui)
        # ... and so is a doublet with an aspheric cemented surface
        doublet = _entry(GUI._surface_doublet)
        strings = String[GUI._catalog_string(p) for p in doublet.params]
        strings[2] = "-45.7; -1; 0"
        lens = GUI._place_catalog!(gui, doublet, strings)
        @test lens isa DoubletLens && gui.components.placement.origin.strings == strings
        @test startswith(gui.components.placement.origin.code, "DoubletLens(SphericalSurface(0.0628, 0.0254), ")
        GUI._cancel_placement!(gui)
        # a lens that BeamletOptics can not build is not placed: the status line says why
        strings[1:2] = ["30; -1; 0", "25"]
        strings[4] = "1"
        @test isnothing(GUI._place_catalog!(gui, doublet, strings))
        @test occursin("Doublet not placed", gui.status.text[]) && occursin("meniscus", gui.status.text[])
        @test isnothing(gui.components.placement) && isempty(sys.objects)
        close(gui)
    end
end

end
