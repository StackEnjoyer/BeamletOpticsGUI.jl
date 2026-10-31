#=
Objects that glide to the poses of the files after a merge, see `_adopt!` in `LiveProjectSync.jl`:
all objects of one merge at the same time, a window group that moved rigidly as one
=#

# How long a moved object glides to its new pose [s], and the frames per second of that
const _GLIDE = 0.3
const _GLIDE_FPS = 60

"""The rotation by `angle` about the unit vector `axis`."""
function _axis_rotation(axis, angle)
    K = [0.0 -axis[3] axis[2]; axis[3] 0.0 -axis[1]; -axis[2] axis[1] 0.0]
    return Matrix{Float64}(I, 3, 3) + sin(angle) * K + (1 - cos(angle)) * K * K
end

"""
    _GroupGlide(group, poses)

What `gliding` of the `_ProjectSync` of a window holds for a window `group` that glides as one, see
`_glide_all!`: `poses` are the pivots and orientations of the files `(g, P, R)` of the group and of
each window group inside it, which they get when it lands (`_land!`); its objects land on their own
entries of `gliding`.
"""
mutable struct _GroupGlide
    group::Any
    poses::Vector{Tuple{Any, Point3{Float64}, Matrix{Float64}}}
end

"""
One object or window group that glides in `_glide_all!`: from `(P0, R0)` to `P1` and the rotation
by `angle` about `axis`. It glides while `gliding` holds `token` for `obj` and `tokens` for the
`members` (the objects of a group), see `_gliding`.
"""
struct _Glide
    obj::Any
    token::Any
    P0::Point3{Float64}
    R0::Matrix{Float64}
    P1::Point3{Float64}
    axis::Vector{Float64}
    angle::Float64
    members::Vector{Any}
    tokens::Vector{Any}
end

function _Glide(@nospecialize(obj), token, P0, R0, P1, R1; members = Any[], tokens = Any[])
    axis, angle = _rotation_axis_angle(Matrix{Float64}(R1) * Matrix{Float64}(R0)')
    return _Glide(obj, token, Point3{Float64}(P0), Matrix{Float64}(R0), Point3{Float64}(P1),
        Vector{Float64}(axis), Float64(angle), members, tokens)
end

# Whether the glide `x` still runs: neither it nor one of its members landed or glides anew meanwhile
function _gliding(gliding, x::_Glide)
    get(gliding, x.obj, nothing) === x.token || return false
    for (m, t) in zip(x.members, x.tokens)
        get(gliding, m, nothing) === t || return false
    end
    return true
end

# Sets the pose of the glide `x` at the fraction `f` of its way
function _glide_to!(x::_Glide, f)
    R = x.angle > 0 ? _axis_rotation(x.axis, f * x.angle) * x.R0 : x.R0
    _set_pose!(x.obj, Point3{Float64}(x.P0 .+ f .* (x.P1 .- x.P0)), R)
    return nothing
end

"""
    _window_tree(gui, g) -> (leaves, groups)

The objects of the window group `g` of the `gui` that are no window groups, also those inside the
window groups among its objects, and these window groups with `g` first, see
`gui.components.groups`.
"""
function _window_tree(gui::LiveView, @nospecialize(g), leaves = Any[], groups = Any[g])
    for m in BMO.objects(g)
        if haskey(gui.components.groups, m)
            push!(groups, m)
            _window_tree(gui, m, leaves, groups)
        else
            push!(leaves, m)
        end
    end
    return leaves, groups
end

"""
    _rigid_motion(moves; tol = 1e-9) -> Union{Nothing, Tuple{Matrix{Float64}, Vector{Float64}}}

The rigid motion `x ↦ ΔR x + t` that takes each pose `(p, Q)` of `moves` (pairs of poses
`(p, Q) => (p′, Q′)`) to `(p′, Q′) = (ΔR p + t, ΔR Q)` within `tol` [m] and `tol`, or `nothing` if
there is none. A group whose pivot and orientation the files changed from `(P, R)` to `(P′, R′)`
moved rigidly if its objects moved by `ΔR = R′ R⁻¹` and `t = P′ − ΔR P`.
"""
function _rigid_motion(moves; tol = 1e-9)
    isempty(moves) && return nothing
    (p, Q), (p1, Q1) = first(moves)
    dR = Matrix{Float64}(Q1) * Matrix{Float64}(Q)'
    t = Vector{Float64}(p1) .- dR * Vector{Float64}(p)
    for ((p, Q), (p1, Q1)) in moves
        maximum(abs, Matrix{Float64}(Q1) .- dR * Matrix{Float64}(Q)) <= tol || return nothing
        maximum(abs, Vector{Float64}(p1) .- dR * Vector{Float64}(p) .- t) <= tol || return nothing
    end
    return dR, t
end

"""
    _rigid_groups(gui, targets) -> Vector

The window groups of the `gui` that moved rigidly with all of their objects: each object inside
(see `_window_tree`) is in `targets` (`obj => (P, R)`, its pose of the files), and one rigid motion
`(ΔR, t)` takes all of them from their poses to these, see `_rigid_motion`. The outermost of them
only, as `(g, leaves, groups, ΔR, t)`.
"""
function _rigid_groups(gui::LiveView, targets::IdDict)
    found = Tuple{Any, Vector{Any}, Vector{Any}, Matrix{Float64}, Vector{Float64}}[]
    for g in keys(gui.components.groups)
        leaves, groups = _window_tree(gui, g)
        (isempty(leaves) || !all(m -> haskey(targets, m), leaves)) && continue
        motion = _rigid_motion([_pose(m) => targets[m] for m in leaves])
        isnothing(motion) || push!(found, (g, leaves, groups, motion...))
    end
    # The groups inside another one glide with it
    sort!(found; by = x -> -length(x[2]))
    claimed = IdDict{Any, Nothing}()
    outer = similar(found, 0)
    for x in found
        any(m -> haskey(claimed, m), x[2]) && continue
        foreach(m -> (claimed[m] = nothing), x[2])
        push!(outer, x)
    end
    return outer
end

# Shows the change of the objects `objs` of the `gui`: one update and one solve for all of them
function _update_glided!(gui::LiveView, objs)
    isempty(objs) && return nothing
    _apply_update!(gui.controls, length(objs) == 1 ? first(objs) : _MultiSelection(objs))
    return nothing
end

"""
    _glide_all!(gui, glides; animate)

Glides the objects of one merge of the `gui` to the poses of the files, see `_adopt!`: `glides`
holds `(obj, (P, R), entry)` of each, which `gliding` of its `_ProjectSync` holds too. If `animate`,
all of them glide at the same time over `_GLIDE` seconds, the position along the line and the
orientation about the axis of the rotation between the two, with one update of the view per frame;
then they land (`_land!`). A window group whose objects all moved by one rigid motion (see
`_rigid_groups`) glides as one, such that its objects follow on arcs about its pivot: from the pose
that the motion takes to the pivot and orientation of the files, which `_adopt_groups!` gave it
already, back to these. A glide stops when its object lands meanwhile (`_finish_glides!`) or glides
anew, that of a group with each of its objects.

`_adopt!` calls it in a task of its own, which may first run after a newer merge took over some of
the objects. So the tokens of the glides are what this merge put into `gliding` (see
`_glide_token`), taken from `glides` and not from `gliding` when the task runs: the objects that a
newer merge took over neither glide nor land here, that merge glides and lands them.
"""
function _glide_all!(gui::LiveView, glides; animate::Bool)
    gliding = gui.sync.gliding
    ctrl = gui.controls
    # What `gliding` holds for each object of this merge as long as no newer one took it over
    tokens = IdDict{Any, Any}(x[1] => _glide_token(x) for x in glides)
    ours(@nospecialize(o)) = get(gliding, o, nothing) === tokens[o]
    objs = Any[first(x) for x in glides]
    if animate
        targets = IdDict{Any, Any}()
        for (obj, (P, R), _) in glides
            ours(obj) && (targets[obj] = (Point3{Float64}(P), Matrix{Float64}(R)))
        end
        items = _Glide[]
        claimed = IdDict{Any, Nothing}()
        for (g, leaves, groups, dR, t) in _rigid_groups(gui, targets)
            # The pivots and orientations of the files, which the groups get back when they land,
            # and before the motion, which matches the poses of their objects now
            poses = Tuple{Any, Point3{Float64}, Matrix{Float64}}[(h, _pose(h)...) for h in groups]
            _change!(ctrl, nothing) do
                for (h, P, R) in poses
                    BMO.set_pivot3d!(h, dR' * (Vector{Float64}(P) .- t))
                    BMO.orientation!(h, dR' * R)
                end
            end
            token = _GroupGlide(g, poses)
            gliding[g] = token
            tokens[g] = token
            P0, R0 = _pose(g)
            push!(items, _Glide(g, token, P0, R0, poses[1][2], poses[1][3];
                members = leaves, tokens = Any[tokens[m] for m in leaves]))
            push!(objs, g)
            foreach(m -> (claimed[m] = nothing), leaves)
        end
        for (obj, (P, R), _) in glides
            (haskey(claimed, obj) || !ours(obj)) && continue
            P0, R0 = _pose(obj)
            push!(items, _Glide(obj, tokens[obj], P0, R0, P, R))
        end
        n = max(1, round(Int, _GLIDE * _GLIDE_FPS))
        for i in 1:(n - 1)
            filter!(x -> _gliding(gliding, x), items)
            isempty(items) && break
            f = i / n
            f = f * f * (3 - 2f)
            # Not over a landing during the wait of the change for a solve that it cancels
            _change!(() -> foreach(x -> _gliding(gliding, x) && _glide_to!(x, f), items), ctrl, nothing)
            _update_glided!(gui, Any[x.obj for x in items])
            sleep(1 / _GLIDE_FPS)
        end
    end
    # Not the ones that landed meanwhile or that a newer merge took over, which lands them
    _land_all!(gui, objs; tokens)
    return nothing
end

# The token of a glide `(obj, (P, R), entry)` of `_glide_all!`: what `_adopt!` puts into `gliding`
# for `obj`, a newer merge another one (another `R`)
_glide_token((_, (P, R), entry)) = (P, R, entry)

"""
Puts `obj` of `gliding` of the `gui` exactly into the pose of its entry of the files and records
that pose; a window group that glides as one (`_GroupGlide`) into the pivots and orientations of
the files. See `_land_all!`.
"""
_land!(gui::LiveView, @nospecialize(obj)) = _land_all!(gui, Any[obj])

"""
Lands those of the objects `objs` that are in `gliding` of the `gui` (see `_land!`): first the
objects, then the window groups. The records of the window groups that hold one of them or are one
of them are made anew (`_current_record`), then the view is updated once. With `tokens`
(`obj => token`), only the objects for which `gliding` holds their token, see `_glide_all!`.

An object leaves `gliding` only after its landing change: the change waits for a solve that it
cancels (see `_change!`), and meanwhile the merge must not end (`_finish_adopt!`), whose solve
would run while the object still moves. An object that landed or glides anew meanwhile is left to
that landing or to the newer merge.
"""
function _land_all!(gui::LiveView, objs; tokens = nothing)
    gliding = gui.sync.gliding
    ctrl = gui.controls
    landed = Any[]
    groups = _GroupGlide[]
    for obj in objs
        haskey(gliding, obj) || continue
        v = gliding[obj]
        isnothing(tokens) || get(tokens, obj, nothing) === v || continue
        v isa _GroupGlide && (push!(groups, v); continue)
        P, R, e = v
        _change!(() -> _place_exactly!(obj, P, R), ctrl, obj)
        get(gliding, obj, nothing) === v || continue
        delete!(gliding, obj)
        _update_record!(gui, obj; pos = e.pos, rot = e.rot, pose = _pose(obj))
        push!(landed, obj)
    end
    changed = IdDict{Any, Nothing}()
    foreach(o -> (changed[o] = nothing), landed)
    for gg in groups
        _change!(ctrl, nothing) do
            for (h, P, R) in gg.poses
                BMO.set_pivot3d!(h, Vector{Float64}(P))
                BMO.orientation!(h, R)
            end
        end
        get(gliding, gg.group, nothing) === gg && delete!(gliding, gg.group)
        foreach(x -> (changed[first(x)] = nothing), gg.poses)
    end
    isempty(changed) && return nothing
    for g in collect(keys(gui.components.groups))
        (haskey(changed, g) || any(m -> haskey(changed, m), BMO.objects(g))) &&
            (gui.components.groups[g] = _current_record(g))
    end
    _update_glided!(gui, landed)
    return nothing
end

"""
Lands every object of the `gui` that glides to a pose of the files at once, e.g. before a save,
which must see the poses of the files; their glides stop.
"""
_finish_glides!(gui::LiveView) = _land_all!(gui, collect(keys(gui.sync.gliding)))

"""
Sets the pose of `obj` to `(P, R)` with the position exactly `P`: rotates about its position, then
moves it to the origin, which is exact, and from there by `P`, like `BeamletOpticsProjects`
poses the objects of a project.
"""
function _place_exactly!(@nospecialize(obj), P, R)
    axis, angle = _rotation_axis_angle(Matrix{Float64}(R) * _pose(obj)[2]')
    angle > 0 && rotate3d!(obj, axis, angle)
    reset_translation3d!(obj)
    translate3d!(obj, Vector{Float64}(P))
    return nothing
end
