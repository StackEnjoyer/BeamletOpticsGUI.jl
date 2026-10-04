#=
The optical table of the live view: a grid of holes below the components, onto which dragged and
placed components and sources snap, see `_Table` and `_set_table!`
=#

# Distance of the holes of the table by default [m], the metric grid of optical tables
const _TABLE_PITCH = 25e-3
# Holes around the components, and the fewest holes along the two edges of the table
const _TABLE_MARGIN = 2
const _TABLE_MIN_HOLES = (12, 8)
# Diameter of a hole relative to the distance of the holes: M6 in a grid of 25 mm
const _TABLE_HOLE = 0.24
# The most holes that are drawn, see `_table_holes`
const _TABLE_MAX_HOLES = 20_000
# Distance of the table below the sources of a view without components [holes]
const _TABLE_DROP = 2

"""
    _Table

The optical table of a `LiveView`, see the `table` kwarg of [`live_view`](@ref): a grid of holes at
the distance `pitch` [m] in the plane with the `normal` (the rotation axis of the controls) at the
`height` [m], i.e. through `height * normal`; `nothing` until the table is shown for the first
time, then the lowest point of the components, see `_table_height`. The rows of the holes run
along `e1` and `e2`, through the origin, see `_table_axes`. `range` are the holes that the table
has, `(i0, i1, j0, j1)` along `e1` and `e2`, which grow with the setup while it is shown, see
`_table_include!`. While it is `shown`, components and sources `snap` onto its holes, see
`_table_snap`. Its `plots` are an outline and the `holes`, of the diameter `hole_size` [m], created
when it is shown for the first time, see `_draw_table!`; `toggle` is its tool.
"""
mutable struct _Table
    const pitch::Float64
    const normal::Vector{Float64}
    const e1::Vector{Float64}
    const e2::Vector{Float64}
    const snap::Bool
    height::Union{Nothing, Float64}
    range::Union{Nothing, NTuple{4, Int}}
    shown::Bool
    const holes::Observable{Vector{Point3f}}
    const outline::Observable{Vector{Point3f}}
    const hole_size::Observable{Float32}
    const plots::Vector{AbstractPlot}
    toggle::Any
end

"""
    _table_spec(table) -> (; shown, pitch, height, snap)

The table of the `table` kwarg of [`live_view`](@ref): `false` (hidden at the start), `true` or a
`NamedTuple` with some of `pitch`, `height`, `snap` and `shown`. Throws an `ArgumentError` for
anything else.
"""
_table_spec(table::Bool) = (; shown = table, pitch = _TABLE_PITCH, height = nothing, snap = true)
function _table_spec(table::NamedTuple)
    for k in keys(table)
        k in (:shown, :pitch, :height, :snap) || throw(ArgumentError(
            "table: unknown entry `$k`, use `pitch`, `height`, `snap` or `shown`"))
    end
    spec = merge(_table_spec(true), table)
    (spec.pitch isa Real && isfinite(spec.pitch) && spec.pitch > 0) ||
        throw(ArgumentError("table: `pitch` must be a positive length [m], got $(repr(spec.pitch))"))
    (isnothing(spec.height) || (spec.height isa Real && isfinite(spec.height))) ||
        throw(ArgumentError("table: `height` must be a length [m] or `nothing`, got $(repr(spec.height))"))
    (spec.snap isa Bool && spec.shown isa Bool) ||
        throw(ArgumentError("table: `snap` and `shown` must be `true` or `false`"))
    return spec
end
_table_spec(table) = throw(ArgumentError(
    "table must be `true`, `false` or a NamedTuple with `pitch`, `height`, `snap` or `shown`, got $(repr(table))"))

"""
    _table_axes(normal) -> (e1, e2)

The directions of the rows of the holes of a table with the unit `normal`: `e1` is the first of the
global axes x, y and z that is not along the normal, without its part along the normal, and
`e2 = normal × e1`; x and y for a table perpendicular to z.
"""
function _table_axes(normal)
    n = Vector{Float64}(normal)
    for a in ([1.0, 0, 0], [0.0, 1, 0], [0.0, 0, 1])
        abs(dot(a, n)) < 0.9 || continue
        e1 = normalize(a .- dot(a, n) .* n)
        return e1, cross(n, e1)
    end
end

function _Table(normal, spec)
    n = normalize(Vector{Float64}(normal))
    e1, e2 = _table_axes(n)
    return _Table(Float64(spec.pitch), n, e1, e2, spec.snap,
        isnothing(spec.height) ? nothing : Float64(spec.height), nothing, false,
        Observable(Point3f[]), Observable(Point3f[]), Observable(0.0f0), AbstractPlot[], nothing)
end

"""
    _grid_point(t::_Table, point) -> Vector{Float64}

The hole of the table `t` closest to the `point` [m], at the height of the point: its coordinates
along the rows of the holes are rounded to the multiples of the pitch, its height above the table
is kept.
"""
function _grid_point(t::_Table, point)
    p = Vector{Float64}(point)
    u, v = dot(p, t.e1), dot(p, t.e2)
    return p .+ (round(u / t.pitch) * t.pitch - u) .* t.e1 .+ (round(v / t.pitch) * t.pitch - v) .* t.e2
end

"""
The points [m] that the table of the `gui` lies below: the corners of the bounding box of the
visible components and extras (see `_visible_bbox`) and the positions of the sources.
"""
function _table_points(gui::LiveView)
    pts = Vector{Float64}[Vector{Float64}(position(p.second)) for p in gui.pairs]
    bb = _visible_bbox((gui.system_handles..., gui.extras))
    isnothing(bb) || append!(pts, Vector{Float64}.(_box_corners(bb)))
    return pts
end

"""
The height of the table `t` of the `gui` that has none [m]: the lowest point of the visible
components and extras along its normal, such that they stand on it; without any, `_TABLE_DROP`
holes below the lowest source, or below the origin in an empty view.
"""
function _table_height(gui::LiveView, t::_Table)
    bb = _visible_bbox((gui.system_handles..., gui.extras))
    isnothing(bb) || return minimum(c -> dot(Vector{Float64}(c), t.normal), _box_corners(bb))
    lowest = minimum(p -> dot(Vector{Float64}(position(p.second)), t.normal), gui.pairs; init = Inf)
    return (isfinite(lowest) ? lowest : 0.0) - _TABLE_DROP * t.pitch
end

"""
    _table_range(t, points; margin = _TABLE_MARGIN, min_holes = _TABLE_MIN_HOLES) -> (i0, i1, j0, j1)

The holes of the table `t` below the `points` [m] with `margin` holes around them, at least
`min_holes` along `e1` and `e2`; around the origin without points.
"""
function _table_range(t::_Table, points; margin::Int = _TABLE_MARGIN, min_holes = _TABLE_MIN_HOLES)
    function along(e, n)
        xs = isempty(points) ? [0.0] : [dot(p, e) for p in points]
        # a point on a hole is at this hole, also if the division rounds
        lo = floor(Int, minimum(xs) / t.pitch + 1e-9) - margin
        hi = ceil(Int, maximum(xs) / t.pitch - 1e-9) + margin
        missing_holes = max(n - (hi - lo + 1), 0)
        return lo - missing_holes ÷ 2, hi + (missing_holes + 1) ÷ 2
    end
    return (along(t.e1, min_holes[1])..., along(t.e2, min_holes[2])...)
end

_union_range(::Nothing, b::NTuple{4, Int}) = b
_union_range(a::NTuple{4, Int}, b::NTuple{4, Int}) =
    (min(a[1], b[1]), max(a[2], b[2]), min(a[3], b[3]), max(a[4], b[4]))

"""
    _table_holes(t::_Table) -> (holes, every)

The holes of the table `t` that are drawn [m]: all of its `range`, or, of more than
`_TABLE_MAX_HOLES`, every `every`-th one along both rows, those whose index is a multiple of it,
such that the drawn ones stay while the table grows.
"""
function _table_holes(t::_Table)
    i0, i1, j0, j1 = t.range
    n = (i1 - i0 + 1) * (j1 - j0 + 1)
    every = n > _TABLE_MAX_HOLES ? ceil(Int, sqrt(n / _TABLE_MAX_HOLES)) : 1
    o = t.height .* t.normal
    holes = [Point3f(o .+ (i * t.pitch) .* t.e1 .+ (j * t.pitch) .* t.e2)
             for j in j0:j1 if mod(j, every) == 0 for i in i0:i1 if mod(i, every) == 0]
    return holes, every
end

"""The corners of the outline of the table `t` [m], half a hole distance around its holes, closed."""
function _table_outline(t::_Table)
    i0, i1, j0, j1 = t.range
    o = t.height .* t.normal
    corner(i, j) = Point3f(o .+ (i * t.pitch) .* t.e1 .+ (j * t.pitch) .* t.e2)
    return [corner(i, j) for (i, j) in ((i0 - 0.5, j0 - 0.5), (i1 + 0.5, j0 - 0.5),
        (i1 + 0.5, j1 + 0.5), (i0 - 0.5, j1 + 0.5), (i0 - 0.5, j0 - 0.5))]
end

"""
    _draw_table!(gui, t::_Table)

Draws the table `t` of the `gui` for its `range` and `height`: its outline and its holes (see
`_table_holes`) as discs in its plane, in the muted color of the theme. An overlay of the 3D view
like the markers of the sources: it is never clipped and nothing of it is traced.
"""
function _draw_table!(gui::LiveView, t::_Table)
    holes, every = _table_holes(t)
    t.hole_size[] = Float32(_TABLE_HOLE * t.pitch * every)
    t.holes[] = holes
    t.outline[] = _table_outline(t)
    isempty(t.plots) || return nothing
    muted = gui.layout.theme.muted
    color = RGBAf(muted.r, muted.g, muted.b, 0.7)
    push!(t.plots,
        lines!(gui.ax, t.outline; color, linewidth = 1.5, clip_planes = Plane3f[]),
        scatter!(gui.ax, t.holes; marker = Makie.Circle, markersize = t.hole_size,
            markerspace = :data, rotation = Makie.rotation_between(Vec3f(0, 0, 1), Vec3f(t.normal)),
            color, clip_planes = Plane3f[]))
    return nothing
end

"""
    _set_table!(gui, shown::Bool)

Shows or hides the optical table of the `gui`, see `_Table`. Shown for the first time, it gets its
height (see `_table_height`) unless the `table` kwarg gave one; each time it is shown, it is
extended to the setup as it is, see `_table_range`, and never shrinks. While it is shown and the
snapping of the controls is switched on, dragged and placed components and sources snap onto its
holes, see `_table_snap`; the status line tells if the snapping is off.
"""
function _set_table!(gui::LiveView, shown::Bool)
    t = gui.components.table
    t.shown = shown
    if shown
        isnothing(t.height) && (t.height = _table_height(gui, t))
        t.range = _union_range(t.range, _table_range(t, _table_points(gui)))
        _draw_table!(gui, t)
    end
    foreach(p -> p.visible[] == shown || (p.visible[] = shown), t.plots)
    gui.status.text[] = !shown ? "table hidden" : !t.snap ? "table shown" :
                        gui.controls.snap[] == :off ?
                        "table shown: with the snapping on (Tab), components snap onto its holes ($(_length_string(t.pitch)))" :
                        "table shown: components snap onto its holes ($(_length_string(t.pitch)))"
    return nothing
end

"""
    _table_include!(gui, obj)

Extends the table of the `gui` to the position of the component or source `obj`, which was moved or
added, with `_TABLE_MARGIN` holes around it, while the table is shown.
"""
_table_include!(::LiveView, _) = nothing
function _table_include!(gui::LiveView, obj::Union{BMO.AbstractObject, _Source})
    t = gui.components.table
    (isnothing(t) || !t.shown) && return nothing
    range = _union_range(t.range,
        _table_range(t, [Vector{Float64}(position(obj))]; min_holes = (1, 1)))
    range == t.range && return nothing
    t.range = range
    _draw_table!(gui, t)
    return nothing
end

# Components and sources snap onto the holes of the table, clip planes do not
_grid_snaps(::Union{BMO.AbstractObject, _Source}) = true
_grid_snaps(_) = false

"""
    _table_snap(gui, obj, point) -> Union{Nothing, NamedTuple}

The `snap_grid` of the controls of the `gui`: the hole of the table that the component or source
`obj` snaps onto at the `point` [m] (see `_grid_point`), as `(; point, direction)` with the
direction `e1` of the rows of the holes, to which its rotation snaps in steps of 45° (see
`_snap_angle`). `nothing` while the table is hidden or does not snap, while the snapping of the
controls is switched off (see `_set_snap!`), which switches all snapping, and for a clip plane.
"""
function _table_snap(gui::LiveView, obj, point)
    t = gui.components.table
    (isnothing(t) || !t.shown || !t.snap || !_grid_snaps(obj)) && return nothing
    gui.controls.snap[] == :off && return nothing
    return (; point = _grid_point(t, point), direction = t.e1)
end

"""
    _build_table!(gui, spec)

Creates the optical table of the `gui` from the `spec` of the `table` kwarg (see `_table_spec`),
perpendicular to the rotation axis of the controls, with its toggle "Table" among the tools of the
layout, and makes its holes the grid of the controls, see `_table_snap`. A table that starts shown
keeps the status line as it is.
"""
function _build_table!(gui::LiveView, spec)
    t = _Table(gui.controls.rotation_axis, spec)
    gui.components.table = t
    t.toggle = add_tool!(_set_table!, gui, "Table"; icon = :table, toggle = true,
        tooltip = "Optical table: with the snapping on, components snap onto its holes")
    gui.controls.snap_grid = (obj, point) -> _table_snap(gui, obj, point)
    if spec.shown
        status = gui.status.text[]
        t.toggle.active[] = true
        gui.status.text[] = status
    end
    return nothing
end
