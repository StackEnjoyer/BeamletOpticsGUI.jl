#=
Driving a live view from code: the gestures of the user as functions, see `translate3d!(gui, obj, offset)`
=#

"""
    _scriptable(gui, obj)

Throws an `ArgumentError` unless `obj` is an object of the live view `gui` that can be moved, i.e.
not static (see `kinematic_trait_of`). Static objects can not be selected in the window either.
"""
function _scriptable(gui::LiveView, obj)
    BMO.is_static(obj) && throw(ArgumentError("$(typeof(obj)) is static and can not be moved"))
    haskey(gui.controls.init_poses, obj) ||
        throw(ArgumentError("$(typeof(obj)) is not an object of the live view"))
    return nothing
end

"""
    _gesture!(f, gui, obj)

One gesture of the user on `obj` from code: `f()` changes `obj` after a solve in the background is
cancelled (see `_change!`), the render of the objects, the selection box and the cards are updated,
`on_change` of the controls solves the systems like after a drag (see `_on_moved!`) and one entry of
the undo history is recorded, unless the pose did not change.
"""
function _gesture!(f, gui::LiveView, obj)
    ctrl = gui.controls
    P0, R0 = _pose(obj)
    _change!(f, ctrl, obj)
    P1, R1 = _pose(obj)
    ctrl.last_key_step = nothing
    _push_history!(ctrl, obj, P0, R0, P1, R1)
    _apply_update!(ctrl, obj)
    return nothing
end

"""
    translate3d!(gui::LiveView, obj, offset)
    translate_to3d!(gui::LiveView, obj, position)

Moves the object `obj` of the [`live_view`](@ref) window `gui` by `offset` [m], or to `position`
[m], like a gesture of the user: the drawing of `obj` (also of the parts of a group), the selection
box and the cards follow, the systems are solved like after a drag (with preview tracing and deferred
solves of slow systems, or marked as outdated if auto tracing is off, see [`wait_solve`](@ref) to
wait for the result), `on_change` is called after the full solve, and the move is one entry of the
undo history (`Ctrl+Z` in the window). Unlike `translate3d!(obj, offset)`, which changes the
object only, the window is not told about it.

The `constraints` of `obj` apply as for the mouse: the offset is projected onto its allowed move
axes. `obj` can be any object, group, source or extra of the view, selected or not. Throws an `ArgumentError` if `obj` is static, is not
part of the view, or if all its move axes are locked.

```julia
translate3d!(gui, lens, [0, 1e-3, 0])  # 1 mm along the optical axis
translate_to3d!(gui, lens, [0, 0.12, 0])
wait_solve(gui)
```
"""
function translate3d!(gui::LiveView, obj, offset::AbstractVector)
    _scriptable(gui, obj)
    ctrl = gui.controls
    allowed = _allowed_axes(ctrl, obj, :move)
    isempty(allowed) && throw(ArgumentError("all move axes of $(typeof(obj)) are locked"))
    Δ = Vector{Float64}(offset)
    if length(allowed) < length(_GIZMO_AXES)
        A = hcat(_axis_vectors(ctrl, obj, allowed)...)
        Δ = A * (pinv(A) * Δ)
    end
    _gesture!(() -> translate3d!(obj, Δ), gui, obj)
end

translate_to3d!(gui::LiveView, obj, target::AbstractVector) =
    translate3d!(gui, obj, Vector{Float64}(target) - Vector{Float64}(position(obj)))

"""
    rotate3d!(gui::LiveView, obj, axis, θ)
    rotate3d!(gui::LiveView, obj, R)

Rotates the object `obj` of the [`live_view`](@ref) window `gui` about its position, by the angle
`θ` [rad] about `axis` (counter-clockwise, global frame) or by the rotation matrix `R`, like a
gesture of the user, see [`translate3d!(::BeamletOpticsGUI.LiveView, ::Any, ::AbstractVector)`](@ref)
for what follows and for the errors.

The `constraints` of `obj` apply as for the mouse: if some rotation axes are locked, `axis` must be
parallel to an allowed one (the local x or y axis of `obj` or the rotation axis of the controls),
otherwise an `ArgumentError` is thrown.
"""
function rotate3d!(gui::LiveView, obj, axis::AbstractVector, θ::Real)
    _scriptable(gui, obj)
    ctrl = gui.controls
    allowed = _allowed_axes(ctrl, obj, :rotate)
    if length(allowed) < length(_GIZMO_AXES)
        n = normalize(Vector{Float64}(axis))
        free = _axis_vectors(ctrl, obj, allowed)
        any(a -> norm(cross(a, n)) < 1e-6, free) ||
            throw(ArgumentError("the rotation of $(typeof(obj)) is constrained to the axes " *
                                "$(join(allowed, ", ")), not about $(axis)"))
    end
    _gesture!(() -> rotate3d!(obj, axis, θ), gui, obj)
end

function rotate3d!(gui::LiveView, obj, R::AbstractMatrix)
    axis, θ = _axis_angle_from_rotmatrix(R)
    return rotate3d!(gui, obj, axis, θ)
end

"""
    select!(gui::LiveView, obj)
    select!(gui::LiveView, ::Nothing)

Selects the object `obj` of the [`live_view`](@ref) window `gui` like a click on it: its selection
box and gizmo are shown, and its card opens or the inspector shows it. `nothing` clears the
selection, like a click on the background. A group is selected as a whole. Throws an
`ArgumentError` if `obj` is not part of the view or the spectator mode is on, see
[`spectator!`](@ref), in which nothing can be selected.
"""
function select!(gui::LiveView, obj)
    ctrl = gui.controls
    haskey(ctrl.init_poses, obj) ||
        throw(ArgumentError("$(typeof(obj)) is not an object of the live view"))
    ctrl.spectator[] && throw(ArgumentError("nothing can be selected in the spectator mode"))
    ctrl.selected[] === obj || (ctrl.selected[] = obj)
    _update_selection_box!(ctrl)
    return nothing
end

function select!(gui::LiveView, ::Nothing)
    ctrl = gui.controls
    isnothing(ctrl.selected[]) || (ctrl.selected[] = nothing)
    _update_selection_box!(ctrl)
    return nothing
end

"""
    spectator!(gui::LiveView, on::Bool)

Switches the spectator mode of the [`live_view`](@ref) window `gui` on or off, like the key `v`: on,
the selection is cleared, the tools, cards and help are hidden and all mouse and keyboard input
goes to the camera; off, they come back as they were. The objects can still be moved from code,
see [`translate3d!(::BeamletOpticsGUI.LiveView, ::Any, ::AbstractVector)`](@ref).
"""
spectator!(gui::LiveView, on::Bool) = _set_spectator!(gui.controls, on)

"""
    wait_solve(gui::LiveView; timeout = Inf) -> Bool

Waits until the [`live_view`](@ref) window `gui` is up to date: a solve running in the background
(see `progress_delay` of `live_view`) is shown, and a solve that was deferred while moving
(`trace_budget`, `idle_delay`), the full solve after a preview and the refinement of coarse detector
views are done at once instead of when the movement pauses. Returns `true` when it is settled and
`false` after `timeout` [s], with the solve still running. With auto tracing off, the beams stay
outdated, see [`retrace!`](@ref). Call it after moves from code before reading detectors or
saving an image.
"""
function wait_solve(gui::LiveView; timeout::Real = Inf)
    t0 = time()
    trace = gui.trace
    # A deferred solve may start a solve in the background in turn
    for _ in 1:4
        job = trace.job
        if !isnothing(job)
            _wait(job.done, timeout - (time() - t0))
            # `done` is notified by the task before it ends
            while !istaskdone(job.task)
                time() - t0 < timeout || return false
                sleep(1e-3)
            end
            _poll_job!(gui)
        end
        (trace.pending || trace.preview || trace.coarse) || return isnothing(trace.job)
        # Not before the movement pauses, as on the tick of the window
        trace.last_change = -Inf
        _on_idle!(gui)
    end
    return isnothing(trace.job)
end
