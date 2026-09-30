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

# Kwargs of the overlay that would draw more than the polarization curve as a visible `Lines` plot,
# or that the sliders set, see `_pol_view`
const _POL_DROPPED_KWARGS = (:show_polarization, :render_every, :show_beams, :pol_λ, :pol_amplitude,
    :pol_scale)
const _POL_ASTIGMATIC_DROPPED_KWARGS = (:show_waist,)

"""
    _set_polarization!(gui, beam, on::Bool)

Shows or hides the polarization of the `beam` (a beam or beam group of the pairs) of the `gui`.
Shown, it is drawn by an overlay: a separate render handle of the central beam of the `beam`
(see `_central_beam`) with the kwargs `gui.beams.overlay_kwargs[beam]`, the wavelength and the
amplitude of `_pol_view` and `show_polarization = true`, stored in `gui.beams.pol[beam]` (see
`_add_overlay!`). Only the `Lines` plot of the polarization curve of the overlay is visible, and only while the `beam` is switched on, see `_set_beam_on!`. Hidden, the
overlay is removed. This changes the display only: nothing is solved or marked as outdated.
Nothing happens if the state does not change.

The overlay of a group renders its central `Beam` object itself. `set_num_rays!` would replace
that object, but no polarized group has a ray slider (all of them wrap given beams, `NoSampling`),
hence the overlay needs no re-sync after a change of the ray count.
"""
function _set_polarization!(gui::LiveView, beam, on::Bool)
    _polarization_on(gui, beam) == on && return nothing
    on || return _remove_overlay!(gui, gui.beams.pol, beam)
    _polarizable(beam) ||
        throw(ArgumentError("the polarization of $(typeof(beam)) can not be shown, it has no polarized rays"))
    target = _central_beam(beam)
    astigmatic = target isa BMO.AstigmaticGaussianBeamlet
    dropped = astigmatic ? (_POL_DROPPED_KWARGS..., _POL_ASTIGMATIC_DROPPED_KWARGS...) : _POL_DROPPED_KWARGS
    kw = Base.structdiff(get(gui.beams.overlay_kwargs, beam, (;)), NamedTuple{dropped})
    # The curve as the sliders of the card set it, see `_pol_view`
    v = _pol_view(gui, beam)
    # The envelope of an astigmatic beamlet stays hidden but is computed on every update
    extra = astigmatic ? (; pol_λ = v.λ, pol_scale = v.amp, r_res = 3, z_res = 2) :
            (; pol_λ = v.λ, pol_amplitude = v.amp)
    _add_overlay!(gui, gui.beams.pol, beam, target; shown = p -> p isa Makie.Lines, kw..., extra...,
        show_polarization = true)
    return nothing
end

#=
Sliders of the polarization curve on the card (see `beam_card_rows`): its wavelength and its
amplitude, absolute, on a logarithmic scale over a range given by the size of the scene
=#

# Kind of the amplitude of the curve: a length [m] for rays, a multiple of the beam radius for
# astigmatic beamlets (`pol_scale` of BMO)
_relative_amplitude(beam) = _central_beam(beam) isa BMO.AstigmaticGaussianBeamlet

"""The size of the scene of the `gui` [m], see `_ClipState`."""
_scene_size(gui::LiveView) = gui.clip.size / 1.2

"""
    _pol_view(gui, beam) -> (; λ, amp)

The wavelength [m] and the amplitude of the polarization curve of the `beam` of the `gui` (a
length [m] for rays, a multiple of the beam radius for astigmatic beamlets, see
`_relative_amplitude`): as set by the sliders of its card, else as given by the `beam_kwargs` of
`live_view` (`pol_λ`, `pol_amplitude`, `pol_scale`), else the size of the scene / 40 and λ/4 (1×
the beam radius).
"""
function _pol_view(gui::LiveView, beam)
    v = get(gui.beams.pol_view, beam, nothing)
    isnothing(v) || return v
    kw = get(gui.beams.overlay_kwargs, beam, (;))
    λ = Float64(something(get(kw, :pol_λ, nothing), _scene_size(gui) / 40))
    amp = _relative_amplitude(beam) ? Float64(get(kw, :pol_scale, 1.0)) :
          Float64(something(get(kw, :pol_amplitude, nothing), λ / 4))
    return (; λ, amp)
end

"""
    _set_pol_view!(gui, beam; λ, amp)

Sets the wavelength or the amplitude of the polarization curve of the `beam` of the `gui` (see
`_pol_view`) and redraws the curve if it is shown. Display only: nothing is solved.
"""
function _set_pol_view!(gui::LiveView, beam; kwargs...)
    v = merge(_pol_view(gui, beam), map(Float64, values(kwargs)))
    v == _pol_view(gui, beam) && return nothing
    gui.beams.pol_view[beam] = v
    if _polarization_on(gui, beam)
        _set_polarization!(gui, beam, false)
        _set_polarization!(gui, beam, true)
    end
    return nothing
end

# The ranges of the sliders: the wavelength from the size of the scene / 2000 (the finest one BMO
# draws without clamping on a path of that size) to / 2, lengths of the amplitude from / 20 000 to
# / 5, multiples of the beam radius from 0.1 to 10
_pol_range(gui::LiveView, ::Val{:λ}, _) = _scene_size(gui) .* (1 / 2000, 1 / 2)
_pol_range(gui::LiveView, ::Val{:amp}, beam) =
    _relative_amplitude(beam) ? (0.1, 10.0) : _scene_size(gui) .* (1 / 20_000, 1 / 5)

# Slider position in [0, 1] of the value `x` on the logarithmic range `(lo, hi)`, and back
_log_position(x, (lo, hi)) = clamp(log(x / lo) / log(hi / lo), 0.0, 1.0)
_log_value(u, (lo, hi)) = lo * (hi / lo)^clamp(u, 0.0, 1.0)

"""The slider position of the value `key` (`:λ` or `:amp`) of the polarization curve of the `beam`."""
_pol_position(gui::LiveView, beam, key::Symbol) =
    _log_position(getfield(_pol_view(gui, beam), key), _pol_range(gui, Val(key), beam))

"""Sets the value `key` of the polarization curve of the `beam` from the slider position `u`."""
_set_pol_position!(gui::LiveView, beam, key::Symbol, u) =
    _set_pol_view!(gui, beam; (key => _log_value(u, _pol_range(gui, Val(key), beam)),)...)

"""The text of the value `key` of the polarization curve of the `beam`, e.g. `0.5 mm` or `2.0 × w`."""
function _pol_text(gui::LiveView, beam, key::Symbol)
    x = getfield(_pol_view(gui, beam), key)
    key === :amp && _relative_amplitude(beam) && return "$(round(x; sigdigits = 2)) × w"
    return _length_string(x)
end

"""
    _init_overlays!(gui)

Shows the polarization curves and the generating beams of the beams of the `gui` whose
`beam_kwargs` of `live_view` set `show_polarization = true` or `show_beams = true`, see
`_set_polarization!` and `_set_generating_beams!`.
"""
function _init_overlays!(gui::LiveView)
    for (beam, kw) in gui.beams.overlay_kwargs
        get(kw, :show_polarization, false) === true && _set_polarization!(gui, beam, true)
        get(kw, :show_beams, false) === true && _set_generating_beams!(gui, beam, true)
    end
    return nothing
end
