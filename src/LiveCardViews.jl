#=
The views on the page "Results" of the cards (see `CardView` and `card_views` in `API.jl`): the
default and the views of a `Detector`
=#

card_views(@nospecialize(_)) = ()

#=
The views of a `Detector`: the spot diagram (`BeamletOptics.spot_diagram`), the intensity of
beamlet hits (`BeamletOptics.intensity`, with the power of `BeamletOptics.optical_power` as its
line) and the PSF of ray hits (the intensity of the rays, normalized to its peak). They are shown
also while the detector moves, on a coarse grid, see `_view_grid`.
=#

# The points of the spot diagram of the detector `pd`
_detector_spots(@nospecialize(pd)) = BMO.spot_diagram(pd)

# The intensity of the detector `pd` on a `RegularGrid` of `num_points` in the `window`, with the
# further keywords of the grid, e.g. `crop_factor`
function _detector_intensity(@nospecialize(pd); num_points::Integer, window, kwargs...)
    grid = merge(NamedTuple(kwargs), (; num_points = Int(num_points)), _window_kwargs(window))
    return BMO.intensity(pd, BMO.RegularGrid(; grid...))
end

# The power of the intensity `(x, z, I)` of the detector `pd`, integrated by BeamletOptics with the
# weights of the samples of its grid, without computing the intensity again
function _detector_power(@nospecialize(pd), (x, z, I))
    P = BMO.optical_power(BMO.sample_points(pd, BMO.RectilinearGrid(x, z)), I)
    return "P = $(_fmt3(1e3 * P)) mW"
end

const _SPOT_VIEW = CardView(_detector_spots, :points; name = :spot, label = "Spot", preview = true)
const _PSF_VIEW = CardView(_detector_intensity, :field; name = :psf, label = "PSF", normalize = true,
    preview = true)
const _INTENSITY_VIEW = CardView(_detector_intensity, :field; name = :intensity, label = "Intensity",
    unit = "W/m²", preview = true, text = _detector_power)

# The views of a detector per type of its hits, the first one is the default: the spot diagram and
# the PSF of ray hits, the intensity and the spot diagram of beamlet hits, none without hits
card_views(@nospecialize(pd::BMO.Detector)) = _detector_views(BMO.hits(pd))
_detector_views(_) = ()
_detector_views(::AbstractVector{<:BMO.AbstractRayHit}) = (_SPOT_VIEW, _PSF_VIEW)
_detector_views(::AbstractVector{<:BMO.AbstractBeamletHit}) = (_INTENSITY_VIEW, _SPOT_VIEW)
