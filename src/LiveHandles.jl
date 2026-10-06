#=
Render handles of the live view on the render handle protocol of BeamletOptics, see
`BeamletOptics.AbstractRenderHandle`, and small helpers for poses and the Makie backend
=#

"""
    LiveSystemHandle <: AbstractSystemRenderHandle

System handle of the live view that combines object handles of several sources, e.g. of all systems,
the source markers, the clip planes and the extras of a `LiveView` (the handle on which the
[`kinematic_controls!`](@ref) work), or of the extras only.

- `sys`: the system returned by `rendered`, e.g. the first system of the live view, or a `System` of
  the extras
- `children`: the object handles, changed via `push!` and `delete!`
- `sources`: the system handles whose hierarchy of groups `render_parent` looks up
"""
mutable struct LiveSystemHandle{S <: BMO.AbstractSystem} <: AbstractSystemRenderHandle
    sys::S
    children::Vector{AbstractObjectRenderHandle}
    sources::Vector{AbstractSystemRenderHandle}
end

"""
    LiveSystemHandle(sys, handles)

Combines the children of the system `handles` into one handle, whose `rendered` is `sys`.
"""
function LiveSystemHandle(sys::BMO.AbstractSystem, handles)
    children = AbstractObjectRenderHandle[c for h in handles for c in render_children(h)]
    return LiveSystemHandle(sys, children, AbstractSystemRenderHandle[handles...])
end

function Base.show(io::IO, h::LiveSystemHandle)
    print(io, "LiveSystemHandle(", length(h.children), " objects, ", length(render_plots(h)), " plots)")
end

rendered(h::LiveSystemHandle) = h.sys
render_children(h::LiveSystemHandle) = h.children

function render_parent(h::LiveSystemHandle, @nospecialize(obj))
    for s in h.sources
        parent = render_parent(s, obj)
        isnothing(parent) || return parent
    end
    return nothing
end

function Base.push!(h::LiveSystemHandle, oh::AbstractObjectRenderHandle)
    push!(h.children, oh)
    return h
end

function Base.delete!(h::LiveSystemHandle, oh::AbstractObjectRenderHandle)
    filter!(c -> c !== oh, h.children)
    return h
end

"""Returns the top-level object of `obj` in the hierarchy of `h`, i.e. the outermost group."""
function _top_level(h::AbstractSystemRenderHandle, @nospecialize(obj))
    parent = render_parent(h, obj)
    while !isnothing(parent)
        obj = parent
        parent = render_parent(h, obj)
    end
    return obj
end

"""
    _pick_leaf(h::AbstractSystemRenderHandle, plot)

Returns the rendered (leaf) object of `plot`, i.e. an object of a group, or `nothing`. The owner is
looked up in the children of `h`, since a rerender replaces the plots of a child.
"""
function _pick_leaf(h::AbstractSystemRenderHandle, plot)
    for child in render_children(h)
        leaf = pick_object(child, plot)
        isnothing(leaf) || return leaf
    end
    return nothing
end

"""Returns the object handle of `obj` among the children of `h`, or `nothing`."""
function _child_handle(h::AbstractSystemRenderHandle, @nospecialize(obj))
    i = findfirst(oh -> rendered(oh) === obj, render_children(h))
    return isnothing(i) ? nothing : render_children(h)[i]
end

"""The plots of `oh` that select its object, see `BeamletOptics.pickable_plots`."""
_pickable_plots(oh::AbstractObjectRenderHandle) = pickable_plots(rendered(oh), render_plots(oh))

#=
Search by identity. A closure like `o -> o === x` is compiled for the type of each object it
is called with, these are compiled once
=#

"""Returns `true` if `x` is one of `xs`, like `any(y -> y === x, xs)`."""
function _has(xs, @nospecialize(x))
    for y in xs
        y === x && return true
    end
    return false
end

"""Returns the index or key of `x` in `xs`, or `nothing`, like `findfirst(y -> y === x, xs)`."""
function _index(xs, @nospecialize(x))
    for (i, y) in pairs(xs)
        y === x && return i
    end
    return nothing
end

#=
Poses and backend, like the live rendering of BeamletOptics
=#

"""Returns the pose `(position, orientation)` of `x`; of a directed thing, see `_direction_frame`."""
_pose(@nospecialize(x)) = _pose(BMO.kinematic_trait_of(x), x)
_pose(::Any, @nospecialize(x)) = (Point3{Float64}(position(x)), Matrix{Float64}(BMO.orientation(x)))
# Beams only have a direction, which is the local y-axis of the frame
_pose(::BMO.Movable{BMO.Directed}, @nospecialize(x)) = (Point3{Float64}(position(x)), _direction_frame(BMO.direction(x)))

"""Returns a right-handed orthonormal frame with the local y-axis along `d`."""
function _direction_frame(d)
    y = normalize(Vector{Float64}(d))
    x = normalize(cross(y, abs(y[3]) < 0.9 ? [0.0, 0, 1] : [1.0, 0, 0]))
    return hcat(x, y, cross(x, y))
end

"""
    _quat_from_rotmatrix(R)

Converts the rotation matrix `R` into a `Makie.Quaternion`.
"""
function _quat_from_rotmatrix(R::AbstractMatrix{T}) where {T}
    tr = R[1, 1] + R[2, 2] + R[3, 3]
    if tr > 0
        S = sqrt(tr + 1) * 2
        w = T(0.25) * S
        x = (R[3, 2] - R[2, 3]) / S
        y = (R[1, 3] - R[3, 1]) / S
        z = (R[2, 1] - R[1, 2]) / S
    elseif R[1, 1] > R[2, 2] && R[1, 1] > R[3, 3]
        S = sqrt(1 + R[1, 1] - R[2, 2] - R[3, 3]) * 2
        w = (R[3, 2] - R[2, 3]) / S
        x = T(0.25) * S
        y = (R[1, 2] + R[2, 1]) / S
        z = (R[1, 3] + R[3, 1]) / S
    elseif R[2, 2] > R[3, 3]
        S = sqrt(1 + R[2, 2] - R[1, 1] - R[3, 3]) * 2
        w = (R[1, 3] - R[3, 1]) / S
        x = (R[1, 2] + R[2, 1]) / S
        y = T(0.25) * S
        z = (R[2, 3] + R[3, 2]) / S
    else
        S = sqrt(1 + R[3, 3] - R[1, 1] - R[2, 2]) * 2
        w = (R[2, 1] - R[1, 2]) / S
        x = (R[1, 3] + R[3, 1]) / S
        y = (R[2, 3] + R[3, 2]) / S
        z = T(0.25) * S
    end
    return Quaternion(x, y, z, w)
end

"""`true` if the active Makie backend supports several lights, i.e. GLMakie, see `studio_lighting!`."""
function _multi_light_backend()
    backend = Makie.current_backend()
    return !ismissing(backend) && nameof(backend) === :GLMakie
end
