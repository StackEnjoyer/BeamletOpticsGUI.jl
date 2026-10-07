#=
The surfaces of the lenses of the catalog (`CatalogSurface`, see `LiveCatalogEntries.jl`), each
spherical or an even asphere: the text of the inputs of a surface and its value, the lenses that
are built from the values, and their code. The surfaces and the lenses themselves are those of
BeamletOptics.
=#

# The radius of a surface is shown in mm, like the lengths of the catalog, see `_length_param`
const _SURFACE_UNIT = "mm"
const _SURFACE_SCALE = 1e-3
# The kinds of a surface, as the menu of the catalog names them
const _SURFACE_SPHERICAL = "spherical"
const _SURFACE_ASPHERIC = "aspheric"
# The orders of the coefficients of an asphere that the catalog takes: A4, A6, ... The coefficient
# A2 of BeamletOptics is zero, since the radius holds the curvature at the vertex.
const _SURFACE_ORDERS = 4:2:16

"""
    _coefficient_scale(order) -> Float64

The factor from the coefficient of the `order` of an asphere as entered, in mm^(1 - order) as on a
data sheet, to the one of BeamletOptics in m^(1 - order), e.g. `1e9` for A4.
"""
_coefficient_scale(order::Integer) = (1 / _SURFACE_SCALE)^(order - 1)

"""
    _SurfaceValue

The value of a `CatalogSurface`, see `_catalog_value`, in the units of BeamletOptics: the
`radius` of curvature [m], whether the surface is `aspheric`, and of an asphere its `conic`
constant and its `coefficients` from A4 on (see `_SURFACE_ORDERS`) without the zeros at their end;
a spherical surface has none.
"""
struct _SurfaceValue
    radius::Float64
    aspheric::Bool
    conic::Float64
    coefficients::Vector{Float64}
end

Base.:(==)(a::_SurfaceValue, b::_SurfaceValue) = a.radius == b.radius && a.aspheric == b.aspheric &&
                                                 a.conic == b.conic && a.coefficients == b.coefficients
Base.hash(v::_SurfaceValue, h::UInt) = hash((v.radius, v.aspheric, v.conic, v.coefficients), h)

#=
The text of a surface
=#

"""
    _surface_string(aspheric, radius, conic, coefficients) -> String

The text of a surface, one of the inputs of an entry of the catalog (see `_catalog_strings`), from
the texts of its fields: the `radius` alone for a spherical surface, i.e. the text of a number, and
`"radius; conic; A4, A6, ..."` for an asphere, e.g. `"-50; -1; 1e-6, 0"`. The fields are as entered:
the radius in mm, the coefficients in mm^(1 - order), see `_catalog_value`; a `;` or `,` in a field
becomes a space, such that the text keeps its fields.
"""
function _surface_string(aspheric::Bool, radius::AbstractString, conic::AbstractString, coefficients)
    aspheric || return _surface_field(radius)
    return string(_surface_field(radius), "; ", _surface_field(conic), "; ",
        join((_surface_field(c) for c in coefficients), ", "))
end

# The text of a box of a surface as a field of the text of the surface, which `;` and `,` divide:
# without them, such that e.g. "1,5" stays one field, which is not a number
_surface_field(s::AbstractString) = String(strip(replace(s, ';' => ' ', ',' => ' ')))

"""
    _surface_fields(s) -> (; aspheric, radius, conic, coefficients)

The texts of the fields of the surface with the text `s`, see `_surface_string`: whether it is an
asphere, its `radius`, its `conic` constant and its `coefficients`, one per order of
`_SURFACE_ORDERS`. A field that the text does not hold is `"0"`, e.g. the conic constant of a
spherical surface. Throws an `ArgumentError` for a text that is neither a radius nor the three
parts of an asphere, and for more coefficients than orders.
"""
function _surface_fields(s::AbstractString)
    parts = String[strip(part) for part in split(s, ';')]
    n = length(_SURFACE_ORDERS)
    length(parts) == 1 &&
        return (; aspheric = false, radius = parts[1], conic = "0", coefficients = fill("0", n))
    length(parts) == 3 ||
        throw(ArgumentError("invalid surface \"$s\", enter a radius or \"radius; conic; A4, A6, ...\""))
    coefficients = String[strip(c) for c in split(parts[3], ',')]
    length(coefficients) <= n ||
        throw(ArgumentError("a surface takes the $n coefficients A$(first(_SURFACE_ORDERS)) to " *
                            "A$(last(_SURFACE_ORDERS)), got $(length(coefficients))"))
    append!(coefficients, fill("0", n - length(coefficients)))
    return (; aspheric = true, radius = parts[1], conic = parts[2], coefficients)
end

# The number of the field `what` of the surface `p` with the `text`, zero for an empty field
function _surface_number(p::CatalogSurface, what::AbstractString, text::AbstractString)
    isempty(text) && return 0.0
    x = tryparse(Float64, text)
    (isnothing(x) || !isfinite(x)) &&
        throw(ArgumentError("invalid input \"$text\" for $what of $(p.name), enter a number"))
    return x
end

# The radius [m] of the surface `p` with the `text` of its box, as `_catalog_value` of a number
function _surface_radius(p::CatalogSurface, text::AbstractString)
    (isempty(text) || text == _catalog_string(p)) && return p.radius
    x = tryparse(Float64, text)
    (isnothing(x) || isnan(x)) &&
        throw(ArgumentError("invalid input \"$text\" for the radius of $(p.name), enter a number"))
    v = x * _SURFACE_SCALE
    return isfinite(v) ? round(v; sigdigits = 15) : v
end

_catalog_keyword(::CatalogSurface) = nothing
_catalog_default(p::CatalogSurface) = _SurfaceValue(p.radius, false, 0.0, Float64[])
# A surface is spherical at first: the text of its radius
_catalog_string(p::CatalogSurface) = _catalog_number_string(p.radius / _SURFACE_SCALE)

function _catalog_value(p::CatalogSurface, s::AbstractString)
    f = _surface_fields(s)
    radius = _surface_radius(p, f.radius)
    f.aspheric || return _SurfaceValue(radius, false, 0.0, Float64[])
    conic = _surface_number(p, "the conic constant", f.conic)
    coefficients = Float64[round(_surface_number(p, "A$order", c) * _coefficient_scale(order); sigdigits = 15)
                           for (order, c) in zip(_SURFACE_ORDERS, f.coefficients)]
    last_set = something(findlast(!iszero, coefficients), 0)
    return _SurfaceValue(radius, true, conic, coefficients[1:last_set])
end

# The constructor of an entry with surfaces gets their values, see `_surface_lens`; in the call of
# a spherical lens, a surface is its radius
_catalog_arg(::CatalogSurface, v::_SurfaceValue) = v
_catalog_arg_code(::CatalogSurface, v::_SurfaceValue) = repr(v.radius)

#=
From the values to the lenses and their code
=#

"""
    _surface(v, d) -> AbstractRotationallySymmetricSurface

The surface of BeamletOptics for the value `v` of a surface of the catalog with the diameter `d`
[m]: a `SphericalSurface`, or an `EvenAsphericalSurface` with zero as its coefficient A2.
`_surface_code` is the same call as Julia code.
"""
function _surface(v::_SurfaceValue, d::Real)
    v.aspheric || return SphericalSurface(v.radius, d)
    return EvenAsphericalSurface(v.radius, d, v.conic, [0.0; v.coefficients])
end

function _surface_code(v::_SurfaceValue, d::Real)
    v.aspheric || return "SphericalSurface($(repr(v.radius)), $(repr(d)))"
    coefficients = repr([0.0; v.coefficients])
    return "EvenAsphericalSurface($(repr(v.radius)), $(repr(d)), $(repr(v.conic)), $coefficients)"
end

# Whether one of the values of the parameters of an entry is an asphere
_has_asphere(values) = any(v -> v isa _SurfaceValue && v.aspheric, values)

"""
    _surface_lens(s1, s2, l, d, n) -> Lens
    _surface_doublet(s1, s2, s3, l1, l2, d, n1, n2) -> DoubletLens
    _surface_triplet(s1, s2, s3, s4, l1, l2, l3, d, n1, n2, n3) -> TripletLens

The constructors of the entries "Singlet", "Doublet" and "Triplet" of the catalog: a lens with the
surfaces `s1`, `s2`, ... (see `_SurfaceValue`), the thicknesses `l` of its elements, the diameter
`d` of all surfaces and the refractive indices `n`. The cemented surfaces of a doublet (`s2`) and of
a triplet (`s2`, `s3`) belong to both elements that they join.

Spherical surfaces give the `SphericalLens`, the `SphericalDoubletLens` and the
`SphericalTripletLens` of BeamletOptics. With an asphere, the lens is the `Lens`, the `DoubletLens`
or the `TripletLens` of the surfaces of BeamletOptics, see `_surface`; these throw an
`ArgumentError` for an element that they can not build, e.g. an aspheric meniscus without a
cylindrical section at its edge.
"""
function _surface_lens(s1::_SurfaceValue, s2::_SurfaceValue, l::Real, d::Real, @nospecialize(n))
    _has_asphere((s1, s2)) || return SphericalLens(s1.radius, s2.radius, l, d, n)
    return Lens(_surface(s1, d), _surface(s2, d), l, n)
end

function _surface_doublet(s1::_SurfaceValue, s2::_SurfaceValue, s3::_SurfaceValue, l1::Real,
        l2::Real, d::Real, @nospecialize(n1), @nospecialize(n2))
    _has_asphere((s1, s2, s3)) ||
        return SphericalDoubletLens(s1.radius, s2.radius, s3.radius, l1, l2, d, n1, n2)
    return DoubletLens(_surface(s1, d), _surface(s2, d), _surface(s3, d), l1, l2, n1, n2)
end

function _surface_triplet(s1::_SurfaceValue, s2::_SurfaceValue, s3::_SurfaceValue, s4::_SurfaceValue,
        l1::Real, l2::Real, l3::Real, d::Real, @nospecialize(n1), @nospecialize(n2), @nospecialize(n3))
    _has_asphere((s1, s2, s3, s4)) ||
        return SphericalTripletLens(s1.radius, s2.radius, s3.radius, s4.radius, l1, l2, l3, d, n1, n2, n3)
    return TripletLens(_surface(s1, d), _surface(s2, d), _surface(s3, d), _surface(s4, d),
        l1, l2, l3, n1, n2, n3)
end

"""
    _surfaces_code(name, entry, values) -> String

The call of the constructor `name` of BeamletOptics for a lens from surfaces, for the `values` of
the parameters of the `entry` of a lens with surfaces: the arguments of its spherical lens (see
`_call_code`) with the surfaces in the place of their radii (see `_surface_code`) and without the
diameter, the last of its numbers, which every surface holds.
"""
function _surfaces_code(name::AbstractString, entry::CatalogEntry, values)
    args, _ = _catalog_args(_catalog_arg_code, entry, values)
    k = findlast(p -> p isa CatalogParam, entry.params)
    d = values[k]
    for (i, v) in enumerate(values)
        v isa _SurfaceValue && (args[i] = _surface_code(v, d))
    end
    deleteat!(args, k)
    return "$name($(join(args, ", ")))"
end

# The code of a lens with surfaces: the call of the spherical lens of BeamletOptics, in which a
# surface is its radius, unless one of them is an asphere
_entry_code(::typeof(_surface_lens), entry::CatalogEntry, values) =
    _has_asphere(values) ? _surfaces_code("Lens", entry, values) : _call_code(entry, values)
_entry_code(::typeof(_surface_doublet), entry::CatalogEntry, values) =
    _has_asphere(values) ? _surfaces_code("DoubletLens", entry, values) : _call_code(entry, values)
_entry_code(::typeof(_surface_triplet), entry::CatalogEntry, values) =
    _has_asphere(values) ? _surfaces_code("TripletLens", entry, values) : _call_code(entry, values)
