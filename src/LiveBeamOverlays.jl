#=
Generating beams of Gaussian beamlets (BMO's `show_beams`): an overlay of the beamlet, like the
polarization curve, see `_add_overlay!`
=#

"""
    _has_generating_beams(beam) -> Bool

Returns `true` if the `beam` is drawn with generating beams by BMO's `show_beams` (chief,
divergence and waist rays): `GaussianBeamlet`s, `AstigmaticGaussianBeamlet`s and groups of them.
"""
_has_generating_beams(::Union{BMO.GaussianBeamlet, BMO.AstigmaticGaussianBeamlet}) = true
_has_generating_beams(bg::BMO.AbstractBeamGroup) =
    !isempty(BMO.beams(bg)) && _has_generating_beams(first(BMO.beams(bg)))
_has_generating_beams(_) = false

"""Returns `true` if the generating beams of the `beam` of the `gui` are shown, see `_set_generating_beams!`."""
_generating_beams_on(gui::LiveView, beam) = haskey(gui.beams.gen, beam)

# Kwargs of the overlay that it sets itself or that would draw more than the generating beams
const _GEN_DROPPED_KWARGS = (:show_beams, :show_polarization, :show_waist, :render_every, :r_res, :z_res)

"""
    _set_generating_beams!(gui, beam, on::Bool)

Shows or hides the generating beams (chief, divergence and waist rays) of the Gaussian beamlet
`beam` (a beamlet or a group of them, of which the central one, see `_central_beam`) of the `gui`.
Shown, they are drawn by an overlay (see `_add_overlay!`): the beamlet rendered again with
`show_beams = true` and the kwargs of its main handle (the style of the layout and the
`beam_kwargs`, e.g. `show_pos`), of which only the generating beams (`LineSegments`, and the
`Scatter` of `show_pos`) are visible. With the envelope of the main handle, this looks like the
static `render!` with `show_beams = true`; the hidden envelope of the overlay is computed on a
coarse grid. Hidden, the overlay is removed. Display only: nothing is solved. Nothing happens if
the state does not change.
"""
function _set_generating_beams!(gui::LiveView, beam, on::Bool)
    _generating_beams_on(gui, beam) == on && return nothing
    on || return _remove_overlay!(gui, gui.beams.gen, beam)
    _has_generating_beams(beam) ||
        throw(ArgumentError("$(typeof(beam)) has no generating beams, it is no Gaussian beamlet"))
    kw = Base.structdiff(get(gui.beams.overlay_kwargs, beam, (;)), NamedTuple{_GEN_DROPPED_KWARGS})
    target = _central_beam(beam)
    _add_overlay!(gui, gui.beams.gen, beam, target;
        shown = p -> p isa Union{Makie.LineSegments, Makie.Scatter},
        _beam_style(gui.layout, target)..., kw..., show_beams = true, r_res = 3, z_res = 2)
    return nothing
end
