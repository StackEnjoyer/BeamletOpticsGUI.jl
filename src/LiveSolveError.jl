#=
Failed solves: a message on a transient info card in the 3D view (see `_show_info!`), in addition
to the log and the status line, see `_fail!`
=#

"""
    _SolveError

The message of a failed solve, shown on a transient info card at `point` [m]: at the detector of a
hit-kind conflict (see `_hit_conflict`), otherwise at the first source. `rows` are the label and
the text of the lines of the card. Unlike the other info items, it can not be kept: its pin and its
dock button close it, see `_keepable`.
"""
struct _SolveError <: _InfoItem
    point::Point3f
    rows::Vector{Pair{String, String}}
end

_points(x::_SolveError) = [x.point]
_title(::_SolveError) = "Solve failed"
_tree_kind(::_SolveError) = :warning
_keep_plots!(::LiveView, ::_SolveError) = nothing
_keepable(::_SolveError) = false
card_rows(x::_SolveError) = Tuple(_text_row(label, Symbol(:error_, i), (_, _) -> text; width = 48)
                                 for (i, (label, text)) in enumerate(x.rows))

# The names of the kinds of detector hits in the messages
_hit_kind(::Type{<:BMO.RayHit}) = "rays"
_hit_kind(::Type{<:BMO.PolarizedRayHit}) = "polarized rays"
_hit_kind(::Type{<:BMO.GaussianBeamletHit}) = "Gaussian beamlets"
_hit_kind(::Type{<:BMO.AstigmaticGaussianBeamletHit}) = "astigmatic Gaussian beamlets"
_hit_kind(T::Type) = string(nameof(T))

"""
    _hit_conflict(gui, e) -> Union{Nothing, NamedTuple}

Recognizes the error `e` of a solve of the `gui` that a detector was hit by two kinds of beams,
e.g. polarized and unpolarized rays: a detector stores one kind of hits per solve (BMO sets it with
the first hit), a hit of another kind fails to `convert` in `push!`. Returns the detectors of the
systems whose hits have the kind of the first hit, `pds`, and the two kinds `(; pds, kinds)`, or
`nothing` for any other error.
"""
function _hit_conflict(gui::LiveView, e)
    e isa MethodError && e.f === convert && length(e.args) == 2 || return nothing
    T, hit = e.args
    (T isa Type && T <: BMO.AbstractDetectorHit && hit isa BMO.AbstractDetectorHit) || return nothing
    pds = [pd for pd in _find_detectors(_systems(gui)) if BMO.hits(pd) isa AbstractVector{T}]
    return (; pds, kinds = (_hit_kind(T), _hit_kind(typeof(hit))))
end

"""The first line of the message of the error `e`, at most `n` characters long."""
function _first_line(e; n::Int = 60)
    s = first(split(sprint(showerror, e), '\n'))
    return length(s) <= n ? String(s) : first(s, n - 1) * "…"
end

"""
    _solve_error(gui, e) -> _SolveError

The message of the error `e` of a solve of the `gui`: for a hit-kind conflict (see
`_hit_conflict`) the detector, the two kinds and what to do, otherwise the first line of the error.
"""
function _solve_error(gui::LiveView, e)
    c = _hit_conflict(gui, e)
    if isnothing(c)
        return _SolveError(_error_anchor(gui), ["error" => _first_line(e), "details" => "see the log"])
    end
    names = isempty(c.pds) ? "a detector" : join((_label(gui, pd) for pd in c.pds), ", ")
    point = isempty(c.pds) ? _error_anchor(gui) : Point3f(position(first(c.pds)))
    return _SolveError(point, ["at" => names, "hits" => "$(c.kinds[1]) and $(c.kinds[2])",
        "cause" => "a detector takes one kind per solve",
        "fix" => "switch a beam off or add a detector"])
end

"""The first finite position of a source of the `gui` that is switched on, else the origin."""
function _error_anchor(gui::LiveView)
    for (_, beam) in gui.pairs
        _beam_on(gui, beam) || continue
        p = _progress_anchor(beam)
        all(isfinite, p) && return p
    end
    return Point3f(0, 0, 0)
end

"""
    _show_solve_error!(gui, e)

Shows the message of the error `e` of a solve of the `gui` on the transient info card, once per
distinct message: after the card was closed (`Esc`, a click, its pin), the same message opens it
again only after a solve succeeded, see `_clear_solve_error!`.
"""
function _show_solve_error!(gui::LiveView, e)
    x = _solve_error(gui, e)
    x.rows == gui.trace.error && return nothing
    gui.trace.error = x.rows
    _show_info!(gui, x)
    return nothing
end

"""Closes the message of a failed solve of the `gui` after a solve succeeded, see `_show_solve_error!`."""
function _clear_solve_error!(gui::LiveView)
    isnothing(gui.trace.error) && return nothing
    gui.trace.error = nothing
    _release_info!(gui, _SolveError)
    return nothing
end
