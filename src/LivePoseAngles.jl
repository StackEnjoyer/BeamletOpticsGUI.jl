#=
Angles and units of the pose card: Euler angles about the global axes in the order xyz or zyx,
poses relative to a reference pose, and the units in which the boxes show lengths and angles
=#

"""Orders of the Euler angles of the pose card, see `_euler_matrix`."""
const _EULER_ORDERS = (:xyz, :zyx)

_check_euler_order(order::Symbol) = order in _EULER_ORDERS ||
    throw(ArgumentError("order must be :xyz or :zyx, got :$order"))

# Rotations about the global x-, y- and z-axis by the angle `a` [rad]
_euler_rx(a::Real) = (c = cos(a); s = sin(a); [1.0 0.0 0.0; 0.0 c -s; 0.0 s c])
_euler_ry(a::Real) = (c = cos(a); s = sin(a); [c 0.0 s; 0.0 1.0 0.0; -s 0.0 c])
_euler_rz(a::Real) = (c = cos(a); s = sin(a); [c -s 0.0; s c 0.0; 0.0 0.0 1.0])

"""
    _euler_matrix((rx, ry, rz), order) -> Matrix{Float64}

The orientation of the Euler angles `rx`, `ry` and `rz` [rad] about the fixed global axes:
`order = :xyz` turns about x first, then y, then z, i.e. `R = R_z(rz) · R_y(ry) · R_x(rx)`, and
`order = :zyx` the reverse, `R = R_x(rx) · R_y(ry) · R_z(rz)`. See `_euler_angles`.
"""
function _euler_matrix(angles, order::Symbol)
    _check_euler_order(order)
    rx, ry, rz = angles
    return order === :xyz ? _euler_rz(rz) * _euler_ry(ry) * _euler_rx(rx) :
           _euler_rx(rx) * _euler_ry(ry) * _euler_rz(rz)
end

"""Wraps the angle `a` [rad] into (−π, π]."""
function _wrap_angle(a::Real)
    a = rem2pi(Float64(a), RoundNearest)
    return a <= -π ? a + 2π : a
end

"""
    _euler_angles(R, order) -> (rx, ry, rz)

The Euler angles [rad] of the orientation `R` in the `order` `:xyz` or `:zyx`, the inverse of
`_euler_matrix`: `rx` and `rz` in (−π, π], `ry` in [−π/2, π/2]. At `|ry| = π/2` (gimbal lock),
where only the sum or difference of `rx` and `rz` is defined, `rx` is 0.
"""
function _euler_angles(R::AbstractMatrix, order::Symbol)
    _check_euler_order(order)
    if order === :xyz
        # R[3, 1] = -sin(ry), hypot(R[1, 1], R[2, 1]) = cos(ry)
        c = hypot(R[1, 1], R[2, 1])
        ry = atan(-R[3, 1], c)
        c < 1e-12 && return (0.0, ry, _wrap_angle(atan(-R[1, 2], R[2, 2])))
        return (_wrap_angle(atan(R[3, 2], R[3, 3])), ry, _wrap_angle(atan(R[2, 1], R[1, 1])))
    end
    # R[1, 3] = sin(ry), hypot(R[1, 1], R[1, 2]) = cos(ry)
    c = hypot(R[1, 1], R[1, 2])
    ry = atan(R[1, 3], c)
    c < 1e-12 && return (0.0, ry, _wrap_angle(atan(R[2, 1], R[2, 2])))
    return (_wrap_angle(atan(-R[2, 3], R[3, 3])), ry, _wrap_angle(atan(-R[1, 2], R[1, 1])))
end

"""
    _relative_pose(P, R, Pref, Rref) -> (Δp, Rrel)

The pose (`P`, `R`) relative to the reference pose (`Pref`, `Rref`), in the frame of the reference:
`Δp = Rrefᵀ (P − Pref)` and `Rrel = Rrefᵀ R`. See `_absolute_pose`.
"""
function _relative_pose(P::AbstractVector, R::AbstractMatrix, Pref::AbstractVector,
        Rref::AbstractMatrix)
    return Vector{Float64}(Rref' * (P - Pref)), Matrix{Float64}(Rref' * R)
end

"""
    _absolute_pose(Δp, Rrel, Pref, Rref) -> (P, R)

The pose of the offset (`Δp`, `Rrel`) from the reference pose (`Pref`, `Rref`), the inverse of
`_relative_pose`: `P = Pref + Rref Δp` and `R = Rref Rrel`.
"""
function _absolute_pose(Δp::AbstractVector, Rrel::AbstractMatrix, Pref::AbstractVector,
        Rref::AbstractMatrix)
    return Vector{Float64}(Pref + Rref * Δp), Matrix{Float64}(Rref * Rrel)
end

"""
Units of the lengths of the pose card in the order of its unit button: the `key`, the `factor` to
meters, the `digits` after the point and the `label`.
"""
const _LENGTH_UNITS = (
    (key = :mm, factor = 1e-3, digits = 6, label = "mm"),
    (key = :um, factor = 1e-6, digits = 3, label = "µm"),
    (key = :nm, factor = 1e-9, digits = 1, label = "nm"),
    (key = :m, factor = 1.0, digits = 9, label = "m"),
)

"""
Units of the angles of the pose card in the order of its unit button: the `key`, the `factor` to
radians, the `digits` after the point and the `label`.
"""
const _ANGLE_UNITS = (
    (key = :rad, factor = 1.0, digits = 6, label = "rad"),
    (key = :mrad, factor = 1e-3, digits = 3, label = "mrad"),
    (key = :urad, factor = 1e-6, digits = 1, label = "µrad"),
    (key = :deg, factor = π / 180, digits = 4, label = "°"),
    (key = :arcmin, factor = π / 10800, digits = 3, label = "arcmin"),
    (key = :arcsec, factor = π / 648000, digits = 1, label = "arcsec"),
)

"""Returns the unit with the `key` of the `units` (`_LENGTH_UNITS` or `_ANGLE_UNITS`)."""
function _pose_unit(units, key::Symbol)
    for u in units
        u.key === key && return u
    end
    throw(ArgumentError("unknown unit :$key"))
end

"""Returns the key of the unit after the one with the `key` in the `units`, after the last the first."""
function _next_unit(units, key::Symbol)
    i = findfirst(u -> u.key === key, units)
    isnothing(i) && throw(ArgumentError("unknown unit :$key"))
    return units[mod1(i + 1, length(units))].key
end

"""
    _format_pose_value(x, unit; signed = false) -> String

Formats the length or angle `x` (in meters or radians) in the `unit` (an entry of `_LENGTH_UNITS`
or `_ANGLE_UNITS`) with its number of digits after the point, e.g. `"1.570796"` for `π / 2` in
rad. A value that rounds to zero has no minus sign. With `signed`, a value that is not negative
starts with `+`, as the offsets of the frame "local" do.
"""
function _format_pose_value(x::Real, unit; signed::Bool = false)
    v = Float64(x) / unit.factor
    d = unit.digits
    scaled = abs(v) * 10.0^d
    # Beyond the integers of `Int64` (e.g. 10⁹ m in nm), without the digits
    scaled < 9e18 || return string(v)
    n = round(Int64, scaled)
    s = lpad(string(n), d + 1, '0')
    body = d == 0 ? s : s[1:(end - d)] * "." * s[(end - d + 1):end]
    sign = (v < 0 && n != 0) ? "-" : signed ? "+" : ""
    return sign * body
end
