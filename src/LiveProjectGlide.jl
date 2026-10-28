#=
Objects that glide to the poses of the files after a merge, see `_adopt!` in `LiveProjectSync.jl`
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
Moves `obj` of the `gui`, which is in `gliding` of its `_ProjectSync`, to the pose `(P, R)` of its
entry there: gliding over `_GLIDE` seconds if `animate`, the position along the line, the
orientation about the axis of the rotation between the two; then lands it (`_land!`). Stops if it
was landed meanwhile, see `_finish_glides!`.
"""
function _glide!(gui::LiveView, @nospecialize(obj); animate::Bool)
    gliding = gui.sync.gliding
    haskey(gliding, obj) || return nothing
    P1, R1, _ = gliding[obj]
    ctrl = gui.controls
    set!(P, R) = (_change!(() -> _set_pose!(obj, P, R), ctrl, obj); _apply_update!(ctrl, obj))
    if animate
        P0, R0 = _pose(obj)
        axis, angle = _rotation_axis_angle(Matrix{Float64}(R1) * Matrix{Float64}(R0)')
        n = max(1, round(Int, _GLIDE * _GLIDE_FPS))
        for i in 1:(n - 1)
            haskey(gliding, obj) || return nothing
            f = i / n
            f = f * f * (3 - 2f)
            R = angle > 0 ? _axis_rotation(axis, f * angle) * R0 : R0
            set!(Point3{Float64}(P0 .+ f .* (Vector{Float64}(P1) .- P0)), R)
            sleep(1 / _GLIDE_FPS)
        end
    end
    _land!(gui, obj)
    return nothing
end

"""
Puts `obj` of `gliding` of the `gui` exactly into the pose of its entry of the files and records
that pose, see `_glide!`.
"""
function _land!(gui::LiveView, @nospecialize(obj))
    haskey(gui.sync.gliding, obj) || return nothing
    P, R, e = pop!(gui.sync.gliding, obj)
    ctrl = gui.controls
    _change!(() -> _place_exactly!(obj, P, R), ctrl, obj)
    _apply_update!(ctrl, obj)
    _update_record!(gui, obj; pos = e.pos, rot = e.rot, pose = _pose(obj))
    return nothing
end

"""
Lands every object of the `gui` that glides to a pose of the files at once, e.g. before a save,
which must see the poses of the files; their glides stop.
"""
_finish_glides!(gui::LiveView) = foreach(obj -> _land!(gui, obj), collect(keys(gui.sync.gliding)))

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

"""
    _glide_all!(gui, glides; animate)

Glides the objects of one merge of the `gui` to the poses of the files, see `_adopt!`: `glides`
holds `(obj, (P, R), entry)` of each, which `gliding` of its `_ProjectSync` holds too.
"""
_glide_all!(gui::LiveView, glides; animate::Bool) = foreach(g -> _glide!(gui, first(g); animate), glides)
