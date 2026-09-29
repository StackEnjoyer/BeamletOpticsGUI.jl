#=
Beams switched on and off: a beam that is off is neither traced nor drawn, everything else behaves
as if it were not in the live view, except its source marker, see `_BeamState`
=#

"""Returns `true` unless the `beam` of the `gui` is switched off, see `_set_beam_on!`."""
_beam_on(gui::LiveView, beam) = !(beam in gui.beams.off)

"""
    _all_beam_handles(gui)

The render handles of all beam plots of the `gui`: the handles of the beams of its pairs
(`gui.beam_handles`), followed by the polarization overlays (`gui.beams.pol`).
"""
_all_beam_handles(gui::LiveView) = Any[gui.beam_handles..., values(gui.beams.pol)...]

"""
    _on_pairs(gui, pairs, handles) -> (pairs, handles)

The `pairs` of the `gui` whose beams are switched on and their render `handles`.
"""
function _on_pairs(gui::LiveView, pairs, handles)
    keep = [_beam_on(gui, p.second) for p in pairs]
    return pairs[keep], handles[keep]
end

"""Resets the `beam` (a beam or a beam group) to its untraced start state, see `_solve_from_start!`."""
_empty_beam!(beam::BMO.AbstractBeam) = (empty!(beam); nothing)
_empty_beam!(bg::BMO.AbstractBeamGroup) = (foreach(empty!, BMO.beams(bg)); nothing)
_empty_beam!(_) = nothing

"""
    _show_beam!(gui, beam, on)

Shows or hides the plots of the `beam` of the `gui`: of each render handle of a pair with the
`beam` (a beam can be part of several pairs) and the `Lines` of its polarization overlay, if any,
whose other plots stay hidden.
"""
function _show_beam!(gui::LiveView, beam, on::Bool)
    for (p, h) in zip(gui.pairs, gui.beam_handles)
        p.second === beam || continue
        foreach(plot -> plot.visible[] = on, _beam_plots(h))
    end
    pol = get(gui.beams.pol, beam, nothing)
    isnothing(pol) || foreach(plot -> plot isa Makie.Lines && (plot.visible[] = on), _beam_plots(pol))
    return nothing
end

"""
    _set_beam_off!(gui, beam)

Switches the `beam` of the `gui` off without solving: it is reset to its untraced start state,
such that detectors and measurements ignore its old rays, its plots are updated to that state and
hidden.
"""
function _set_beam_off!(gui::LiveView, beam)
    push!(gui.beams.off, beam)
    _empty_beam!(beam)
    for (p, h) in zip(gui.pairs, gui.beam_handles)
        p.second === beam && update_render!(h)
    end
    _show_beam!(gui, beam, false)
    return nothing
end

"""
    _set_beam_on!(gui, beam, on::Bool)

Switches the `beam` (a beam or beam group of the pairs) of the `gui` on or off. A beam that is off
is neither traced nor drawn, see `_set_beam_off!`; its source marker stays. Like the ray slider
(see `_set_num_rays!`) this is a change of the `beam`: a running solve is cancelled first, then the
systems are solved again, or marked as outdated if auto tracing is off, via the `on_change` of the
controls. Nothing happens if the state does not change.
"""
function _set_beam_on!(gui::LiveView, beam, on::Bool)
    _beam_on(gui, beam) == on && return nothing
    _change!(gui.controls, beam) do
        on ? delete!(gui.beams.off, beam) : _set_beam_off!(gui, beam)
    end
    on && _show_beam!(gui, beam, true)
    # The number of rays, also if the change is not solved right away
    _update_info!(gui)
    gui.controls.on_change(beam)
    return nothing
end
