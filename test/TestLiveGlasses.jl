module TestLiveGlasses

using GLMakie, BeamletOptics, BeamletOpticsGUI
using Test

const BMO = BeamletOptics
const GUI = BeamletOpticsGUI

# A glass that is a named function
flat_glass(λ) = 1.6

@testset "Catalog glasses" begin

    @testset "built-in glasses" begin
        # The catalog values at the d line, which the Sellmeier coefficients do not come from: the
        # refractive index n_d and the Abbe number V_d = (n_d - 1) / (n_F - n_C)
        λd, λF, λC = 587.56e-9, 486.13e-9, 656.27e-9
        catalog = ["N-BK7" => (1.5168, 64.17), "Fused silica" => (1.4585, 67.82),
            "CaF2" => (1.4338, 95.0), "N-SF11" => (1.7847, 25.68), "N-SF10" => (1.7283, 28.53),
            "N-SF6HT" => (1.8052, 25.36), "N-SF5" => (1.6727, 32.25), "N-F2" => (1.6200, 36.43),
            "N-BAF10" => (1.6700, 47.11), "N-LAK22" => (1.6511, 55.89)]
        glasses = GUI._builtin_glasses()
        @test first.(glasses) == first.(catalog)
        for (name, (nd, Vd)) in catalog
            n = GUI._glass(name)
            @test n isa SellmeierEquation
            @test n(λd) ≈ nd atol = 2e-4
            @test (n(λd) - 1) / (n(λF) - n(λC)) ≈ Vd rtol = 5e-3
            # normal dispersion over the visible range
            @test n(λF) > n(λd) > n(λC)
        end
    end

    @testset "registry" begin
        glasses = catalog_glasses()
        @test glasses isa Vector{Pair{String, Any}}
        @test catalog_glasses() === glasses
        builtin = GUI._builtin_glasses()
        @test first.(glasses[1:length(builtin)]) == first.(builtin)
        @test GUI._glass_names() == first.(glasses)
        @test GUI._glass("N-BK7") === last(first(glasses))
        err = try
            GUI._glass("Unobtainium")
        catch e
            e
        end
        @test err isa ArgumentError && occursin("Unobtainium", err.msg) && occursin("N-BK7", err.msg)
        # the glass of a package
        n = length(glasses)
        own = "Own glass" => SellmeierEquation(1.0, 0.2, 1.0, 0.006, 0.02, 100.0)
        push!(glasses, own, GUI._GLASS_CONSTANT => flat_glass)
        try
            @test GUI._glass("Own glass") === last(own)
            # "constant" is the entry of the menu for a constant refractive index
            @test GUI._glass_names() == [first.(builtin); "Own glass"]
        finally
            filter!(g -> !(first(g) in ("Own glass", GUI._GLASS_CONSTANT)), glasses)
        end
        @test length(catalog_glasses()) == n
    end

    @testset "code" begin
        # the code builds the glass without this package
        for (name, n) in GUI._builtin_glasses()
            code = GUI._glass_code(n)
            @test startswith(code, "SellmeierEquation(")
            twin = Core.eval(@__MODULE__, Meta.parse(code))
            @test twin === n
        end
        @test GUI._glass_code(GUI._glass("N-BK7")) ==
              "SellmeierEquation(1.03961212, 0.231792344, 1.01046945, 0.00600069867, 0.0200179144, 103.560653)"
        table = DiscreteRefractiveIndex([1064e-9, 532e-9], [1.5066, 1.5195])
        code = GUI._glass_code(table)
        @test code == "DiscreteRefractiveIndex([5.32e-7, 1.064e-6], [1.5195, 1.5066])"
        @test Core.eval(@__MODULE__, Meta.parse(code)).data == table.data
        # a named function by its name
        @test Core.eval(@__MODULE__, Meta.parse(GUI._glass_code(flat_glass))) === flat_glass
    end

    @testset "parameter" begin
        p = CatalogGlass()
        @test (p.name, p.default, p.n, p.keyword) == ("glass", "N-BK7", 1.5, nothing)
        q = CatalogGlass("substrate"; default = "constant", n = 1.45, keyword = :n)
        @test (q.name, q.default, q.n, q.keyword) == ("substrate", "constant", 1.45, :n)
        @test_throws ArgumentError CatalogGlass(; default = "Unobtainium")
        @test_throws ArgumentError CatalogGlass(; n = 0)
        @test_throws ArgumentError CatalogGlass(; n = Inf)
        # as shown in the catalog and as values
        @test GUI._catalog_string(p) == "N-BK7" && GUI._catalog_default(p) == "N-BK7"
        @test GUI._catalog_string(q) == "1.45" && GUI._catalog_default(q) === 1.45
        @test GUI._catalog_value(p, "N-SF11") == "N-SF11"
        @test GUI._catalog_value(p, " 1.6 ") === 1.6
        # the empty box of "constant" shows the default
        @test GUI._catalog_value(q, "") === 1.45
        for s in ("abc", "0", "-1", "Inf", "NaN", "Unobtainium")
            @test_throws ArgumentError GUI._catalog_value(p, s)
        end
        # the argument of the constructor and its code
        @test GUI._catalog_arg(p, "N-SF11") === GUI._glass("N-SF11")
        n = GUI._catalog_arg(p, 1.6)
        @test n isa Function && n(532e-9) === 1.6 && n(1) === 1.6
        @test GUI._catalog_arg_code(p, 1.6) == "λ -> 1.6"
        twin = Core.eval(@__MODULE__, Meta.parse(GUI._catalog_arg_code(p, 1.6)))
        @test Base.invokelatest(twin, 1e-6) === 1.6
        @test GUI._catalog_arg_code(p, "N-BK7") == GUI._glass_code(GUI._glass("N-BK7"))
    end
end

end
