#=
Glasses of the component catalog, see `catalog_glasses` and `CatalogGlass`: common optical glasses
and crystals as `SellmeierEquation`s of BeamletOptics.

The coefficients are those of the database refractiveindex.info
(https://github.com/polyanskiy/refractiveindex.info-database, public domain, CC0): the glasses of
SCHOTT from its Zemax catalog of 2017-01-20 (`data/specs/schott/optical/<name>.yml`), fused silica
and CaF2 from the measurements of Malitson (`data/main/SiO2/nk/Malitson.yml`,
`data/main/CaF2/nk/Malitson.yml`). They hold at room temperature within the given range of
wavelengths. The data of the materials belongs into BeamletOptics in the long run; the code of
`export_changes` therefore does not depend on this file, see `_glass_code`.
=#

# The entry of the menu of the glasses for a constant refractive index, see `CatalogGlass`
const _GLASS_CONSTANT = "constant"

const _GLASSES = Pair{String, Any}[]
# Whether `_GLASSES` got the built-in glasses, see `catalog_glasses`
const _GLASSES_FILLED = Ref(false)

function catalog_glasses()
    if !_GLASSES_FILLED[]
        _GLASSES_FILLED[] = true
        # before the glasses that were added without this function
        prepend!(_GLASSES, _builtin_glasses())
    end
    return _GLASSES
end

"""
    _sellmeier(B1, C1, B2, C2, B3, C3) -> SellmeierEquation

The Sellmeier equation `n² - 1 = Σ Bᵢ λ² / (λ² - Cᵢ)` with the coefficients in the order of the
database refractiveindex.info ("formula 2"), `Cᵢ` in [μm²].
"""
_sellmeier(B1, C1, B2, C2, B3, C3) = BMO.SellmeierEquation(B1, B2, B3, C1, C2, C3)

"""
    _builtin_glasses() -> Vector{Pair{String, Any}}

The glasses of [`catalog_glasses`](@ref), see the head of this file for their sources: the standard
crown N-BK7 first, the two crystals of UV and laser optics, then the flints by falling dispersion
and the two dense crowns of achromats.
"""
function _builtin_glasses()
    return Pair{String, Any}[
        # 0.3 to 2.5 μm
        "N-BK7" => _sellmeier(1.03961212, 0.00600069867, 0.231792344, 0.0200179144, 1.01046945, 103.560653),
        # 0.21 to 6.7 μm; Malitson 1965, resonance wavelengths [μm] instead of their squares
        "Fused silica" => _sellmeier(0.6961663, 0.0684043^2, 0.4079426, 0.1162414^2, 0.8974794, 9.896161^2),
        # 0.23 to 9.7 μm; Malitson 1963, resonance wavelengths [μm] instead of their squares
        "CaF2" => _sellmeier(0.5675888, 0.050263605^2, 0.4710914, 0.1003909^2, 3.8484723, 34.649040^2),
        # 0.37 to 2.5 μm
        "N-SF11" => _sellmeier(1.73759695, 0.013188707, 0.313747346, 0.0623068142, 1.89878101, 155.23629),
        # 0.38 to 2.5 μm
        "N-SF10" => _sellmeier(1.62153902, 0.0122241457, 0.256287842, 0.0595736775, 1.64447552, 147.468793),
        # 0.37 to 2.5 μm
        "N-SF6HT" => _sellmeier(1.77931763, 0.0133714182, 0.338149866, 0.0617533621, 2.08734474, 174.01759),
        # 0.37 to 2.5 μm
        "N-SF5" => _sellmeier(1.52481889, 0.011254756, 0.187085527, 0.0588995392, 1.42729015, 129.141675),
        # 0.365 to 2.5 μm
        "N-F2" => _sellmeier(1.39757037, 0.00995906143, 0.159201403, 0.0546931752, 1.2686543, 119.248346),
        # 0.35 to 2.5 μm
        "N-BAF10" => _sellmeier(1.5851495, 0.00926681282, 0.143559385, 0.0424489805, 1.08521269, 105.613573),
        # 0.31 to 2.5 μm
        "N-LAK22" => _sellmeier(1.14229781, 0.00585778594, 0.535138441, 0.0198546147, 1.04088385, 100.834017),
    ]
end

"""The names of the glasses of [`catalog_glasses`](@ref), without a glass named like "constant"."""
_glass_names() = String[first(g) for g in catalog_glasses() if first(g) != _GLASS_CONSTANT]

"""
    _glass(name) -> n

The glass with the `name` of [`catalog_glasses`](@ref), the first one of several. Throws an
`ArgumentError` for an unknown name.
"""
function _glass(name::AbstractString)
    glasses = catalog_glasses()
    i = findfirst(g -> first(g) == name, glasses)
    isnothing(i) && throw(ArgumentError(
        "unknown glass \"$name\", the glasses of catalog_glasses() are $(join(_glass_names(), ", "))"))
    return last(glasses[i])
end

"""
    _glass_code(n) -> String

The glass `n` as Julia code for [`export_changes`](@ref), which runs without this package: the call
of the constructor of a `SellmeierEquation` and of a `DiscreteRefractiveIndex`, `repr` otherwise,
e.g. the name of a function.
"""
_glass_code(n) = repr(n)
_glass_code(n::BMO.SellmeierEquation) =
    "SellmeierEquation(" * join(repr.((n.B1, n.B2, n.B3, n.C1, n.C2, n.C3)), ", ") * ")"
function _glass_code(n::BMO.DiscreteRefractiveIndex)
    λs = sort!(collect(keys(n.data)))
    return "DiscreteRefractiveIndex($(repr(λs)), $(repr([n.data[λ] for λ in λs])))"
end
