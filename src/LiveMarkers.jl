#=
Markers of the live view that `render!` does not draw: the clip planes and the markers of the
sources, live-rendered via `live_render!(draw, ax, x)`
=#

"""
    LiveClipPlane

Clip plane of a `LiveView`, see [`live_view`](@ref). The plane passes through `pos`, its normal is
the local y-axis of the right-handed orthonormal frame `dir`, i.e. `dir[:, 2]`. Only the side the
normal points to stays visible. `size` is the edge length of its outline. The plane is moved like a
component via its marker, see `_live_render_clip_plane!`.
"""
mutable struct LiveClipPlane
    pos::Point3{Float64}
    dir::Matrix{Float64}
    size::Float64
end

function LiveClipPlane(point, normal, size::Real)
    n = Vector{Float64}(collect(normal))
    norm(n) < 1e-12 && throw(ArgumentError("the normal of a clip plane must not be zero, got $normal"))
    return LiveClipPlane(Point3{Float64}(collect(point)), _direction_frame(n), Float64(size))
end

function Base.show(io::IO, p::LiveClipPlane)
    print(io, "LiveClipPlane(", collect(p.pos), ", normal = ", _normal(p), ")")
end

BMO.kinematic_trait_of(::LiveClipPlane) = BMO.Movable(BMO.Oriented())
Base.position(p::LiveClipPlane) = p.pos
BMO.orientation(p::LiveClipPlane) = p.dir

function BMO.translate3d!(::BMO.Movable, p::LiveClipPlane, offset)
    p.pos = p.pos + Point3{Float64}(collect(offset))
    return nothing
end

function BMO.rotate3d!(::BMO.Movable, p::LiveClipPlane, R::AbstractMatrix)
    p.dir = Matrix{Float64}(R * p.dir)
    return nothing
end

"""Returns the unit normal of the clip plane `p`, i.e. its local y-axis."""
_normal(p::LiveClipPlane) = p.dir[:, 2]

"""Returns the `Makie.Plane3f` of the clip plane `p`, as applied to the plots."""
_plane3f(p::LiveClipPlane) = Plane3f(Point3f(p.pos), Vec3f(_normal(p)))

"""Values that can be live-rendered and moved by the controls: objects, sources and clip planes."""
const _LiveMovable = Union{BMO.AbstractObject, BMO.AbstractBeam, BMO.AbstractBeamGroup, LiveClipPlane}

"""
    _live_render_source!(ax, src; size, color = :orange, strokecolor = :black)

Renders a marker of the source `src` (a beam or beam group), i.e. an arrow of length `size` along
its direction and a sphere at its position, and returns its object render handle, see
`live_render!(draw, ax, x)`. The marker allows selecting and moving the source with the
[`kinematic_controls!`](@ref).
"""
function _live_render_source!(ax::_Axis, src; size::Real, color = :orange, strokecolor = :black)
    draw = function ()
        p, d = Point3f(position(src)), Vec3f(size * normalize(BMO.direction(src)))
        # Markers are never clipped, see the clip planes of `live_view`
        arrows3d!(ax, [p], [d]; color, shaftradius = 0.05, tipradius = 0.15, tiplength = 0.35,
            clip_planes = Plane3f[])
        mesh!(ax, GeometryBasics.Sphere(p, Float32(size / 5)); color, clip_planes = Plane3f[])
        # Constant size on the screen, such that the source is visible in the overview as well
        scatter!(ax, [p]; color, markersize = 12, strokecolor, strokewidth = 1,
            clip_planes = Plane3f[])
    end
    return live_render!(draw, ax, src)
end

"""
    _live_render_clip_plane!(ax, plane::LiveClipPlane; color = :purple, strokecolor = :black)

Renders the marker of the clip `plane`, i.e. its outline of edge length `plane.size` and a handle
(sphere and scatter) at its position, and returns its object render handle, see
`live_render!(draw, ax, x)`. The marker is never clipped. Only the handle selects the plane, see
`pickable_plots`.
"""
function _live_render_clip_plane!(ax::_Axis, plane::LiveClipPlane; color = :purple,
        strokecolor = :black)
    draw = function ()
        p = Vector{Float64}(plane.pos)
        # Outline along the local x- and z-axes, i.e. within the plane
        x, z = plane.dir[:, 1], plane.dir[:, 3]
        s = plane.size / 2
        corners = [Point3f(p + s * (a * x + b * z)) for (a, b) in ((-1, -1), (1, -1), (1, 1), (-1, 1), (-1, -1))]
        lines!(ax, corners; color, linewidth = 2, clip_planes = Plane3f[])
        # About the size of the sphere of a source marker, see `live_view`
        mesh!(ax, GeometryBasics.Sphere(Point3f(p), Float32(plane.size / 75)); color,
            clip_planes = Plane3f[])
        scatter!(ax, [Point3f(p)]; color, markersize = 12, strokecolor, strokewidth = 1,
            clip_planes = Plane3f[])
    end
    return live_render!(draw, ax, plane)
end

"""The plots of the marker of a clip plane that select it, i.e. all but its outline."""
pickable_plots(::LiveClipPlane, plots) = AbstractPlot[p for p in plots if !(p isa Makie.Lines)]

