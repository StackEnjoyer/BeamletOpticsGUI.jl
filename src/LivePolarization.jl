#=
Polarization of the beams: a separate overlay handle per beam whose polarization is shown, see
`_set_polarization!`. The main render handle of the beam is never touched, since BMO fixes the
kwargs of a handle when it is created and draws the polarization of every rendered beam of a group.
=#

"""
    _polarizable(beam) -> Bool

Returns `true` if the polarization of the `beam` can be shown, i.e. for beams and beam groups of
`PolarizedRay`s. This includes `AstigmaticGaussianBeamlet`s and `AstigmaticBeamGroup`s, but not
`GaussianBeamlet`s.
"""
_polarizable(::BMO.AbstractBeam{<:Any, <:BMO.PolarizedRay}) = true
_polarizable(::BMO.AbstractBeamGroup{<:Any, <:BMO.PolarizedRay}) = true
_polarizable(_) = false

"""
    _central_beam(beam)

The beam whose polarization the overlay of `beam` shows: a single beam itself, of a beam group the
beam whose start point is nearest to the axis of the group. The axis runs through the mean start
point of the beams along the central direction of the group (the second column of its
orientation). Ties, e.g. of the beamlets of a point source that all start at the same point, are
broken by the smallest angle between the start direction of the beam and the axis.
"""
_central_beam(beam::BMO.AbstractBeam) = beam
function _central_beam(bg::BMO.AbstractBeamGroup)
    bs = BMO.beams(bg)
    length(bs) == 1 && return first(bs)
    axis = normalize(Vector{Float64}(BMO.orientation(bg)[:, 2]))
    starts = [Vector{Float64}(position(b)) for b in bs]
    center = sum(starts) / length(starts)
    # distance of each start point from the axis
    dist = map(starts) do p
        v = p - center
        norm(v - dot(v, axis) * axis)
    end
    extent = maximum(norm(p - center) for p in starts)
    tol = 1e-9 * max(extent, eps())
    dmin = minimum(dist)
    best, best_angle = 0, Inf
    for (i, b) in enumerate(bs)
        dist[i] ≤ dmin + tol || continue
        d = normalize(Vector{Float64}(BMO.direction(b)))
        angle = acos(clamp(dot(d, axis), -1.0, 1.0))
        angle < best_angle && ((best, best_angle) = (i, angle))
    end
    return bs[best]
end

"""Returns `true` if the polarization of the `beam` of the `gui` is shown, see `_set_polarization!`."""
_polarization_on(gui::LiveView, beam) = haskey(gui.beams.pol, beam)

# Kwargs of the overlay that would draw more than the polarization curve as a visible `Lines` plot
const _POL_DROPPED_KWARGS = (:show_polarization, :render_every)
const _POL_ASTIGMATIC_DROPPED_KWARGS = (:show_beams, :show_waist)

"""
    _set_polarization!(gui, beam, on::Bool)

Shows or hides the polarization of the `beam` (a beam or beam group of the pairs) of the `gui`.
Shown, it is drawn by an overlay: a separate render handle of the central beam of the `beam`
(see `_central_beam`) with the kwargs `gui.beams.pol_kwargs[beam]` and `show_polarization =
true`, stored in `gui.beams.pol[beam]`. Only the `Lines` plot of the polarization curve of the
overlay is visible, and only while the `beam` is switched on, see `_set_beam_on!`. Hidden, the
overlay is removed. This changes the display only: nothing is solved or marked as outdated.
Nothing happens if the state does not change.

The overlay of a group renders its central `Beam` object itself. `set_num_rays!` would replace
that object, but no polarized group has a ray slider (all of them wrap given beams, `NoSampling`),
hence the overlay needs no re-sync after a change of the ray count.
"""
function _set_polarization!(gui::LiveView, beam, on::Bool)
    _polarization_on(gui, beam) == on && return nothing
    if !on
        h = pop!(gui.beams.pol, beam)
        foreach(p -> delete!(gui.trace.beam_alphas, p), _beam_plots(h))
        remove_render!(h)
        return nothing
    end
    _polarizable(beam) ||
        throw(ArgumentError("the polarization of $(typeof(beam)) can not be shown, it has no polarized rays"))
    target = _central_beam(beam)
    astigmatic = target isa BMO.AstigmaticGaussianBeamlet
    dropped = astigmatic ? (_POL_DROPPED_KWARGS..., _POL_ASTIGMATIC_DROPPED_KWARGS...) : _POL_DROPPED_KWARGS
    kw = Base.structdiff(get(gui.beams.pol_kwargs, beam, (;)), NamedTuple{dropped})
    # The envelope of an astigmatic beamlet stays hidden but is computed on every update
    res = astigmatic ? (; r_res = 3, z_res = 2) : (;)
    h = live_render!(gui.ax, target; kw..., res..., show_polarization = true, clip_planes = Plane3f[])
    visible = _beam_on(gui, beam)
    for plot in _beam_plots(h)
        plot.visible[] = plot isa Makie.Lines && visible
    end
    gui.beams.pol[beam] = h
    # A new overlay of outdated beams is dimmed like them
    gui.trace.stale && _dim_beams!(gui)
    _apply_clip_planes!(gui)
    return nothing
end

"""
    _init_polarization!(gui)

Shows the polarization of the beams of the `gui` whose `beam_kwargs` of `live_view` set
`show_polarization = true`, see `_set_polarization!`.
"""
function _init_polarization!(gui::LiveView)
    for (beam, kw) in gui.beams.pol_kwargs
        get(kw, :show_polarization, false) === true && _set_polarization!(gui, beam, true)
    end
    return nothing
end
