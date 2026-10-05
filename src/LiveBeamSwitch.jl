#=
Beams switched on and off: a beam that is off is neither traced nor drawn, everything else behaves
as if it were not in the live view, except its source marker, see `_BeamState`
=#

"""Returns `true` unless the `beam` of the `gui` is switched off, see `_set_beam_on!`."""
_beam_on(gui::LiveView, beam) = !(beam in gui.beams.off)

"""
    _all_beam_handles(gui)

The render handles of all beam plots of the `gui`: the handles of the beams of its pairs
(`gui.beam_handles`), followed by the overlays (`gui.beams.pol`, `gui.beams.gen`).
"""
_all_beam_handles(gui::LiveView) =
    Any[gui.beam_handles..., values(gui.beams.pol)..., values(gui.beams.gen)...]

"""The stores of the overlay handles of the `gui` by beam, see `_BeamState`."""
_overlay_stores(gui::LiveView) = (gui.beams.pol, gui.beams.gen)

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
`beam` (a beam can be part of several pairs) and the shown plots of its overlays (see
`_add_overlay!`), whose other plots stay hidden.
"""
function _show_beam!(gui::LiveView, beam, on::Bool)
    for (p, h) in zip(gui.pairs, gui.beam_handles)
        p.second === beam || continue
        foreach(plot -> plot.visible[] = on, _beam_plots(h))
    end
    for store in _overlay_stores(gui)
        h = get(store, beam, nothing)
        isnothing(h) || foreach(plot -> plot.visible[] = on, gui.beams.shown[h])
    end
    return nothing
end

"""
    _add_overlay!(gui, store, beam, target; shown, kwargs...)

Renders the overlay of the `beam` of the `gui`: a separate render handle of `target` (the `beam`
or its central beam, see `_central_beam`) with the `kwargs`, stored as `store[beam]`. Only its
plots for which `shown(plot)` holds are visible, and only while the `beam` is switched on. Like the
beams, it is dimmed while the trace is outdated and clipped with `clip_beams`.
"""
function _add_overlay!(gui::LiveView, store::IdDict, beam, target; shown, kwargs...)
    h = live_render!(gui.ax, target; kwargs..., clip_planes = Plane3f[])
    plots = Any[p for p in _beam_plots(h) if shown(p)]
    visible = _beam_on(gui, beam)
    foreach(p -> p.visible[] = visible && any(q -> q === p, plots), _beam_plots(h))
    store[beam] = h
    gui.beams.shown[h] = plots
    # A new overlay of outdated beams is dimmed like them
    gui.trace.stale && _dim_beams!(gui)
    _apply_clip_planes!(gui)
    return h
end

"""Removes the overlay `store[beam]` of the `gui`, see `_add_overlay!`; it is never updated again."""
function _remove_overlay!(gui::LiveView, store::IdDict, beam)
    h = pop!(store, beam)
    delete!(gui.beams.shown, h)
    foreach(p -> delete!(gui.trace.beam_alphas, p), _beam_plots(h))
    remove_render!(h)
    return nothing
end

#=
Settings of the render handles of a beam, e.g. the length of the final rays
=#

"""
    _live_render_beam!(ax, layout, beam, kwargs) -> AbstractBeamRenderHandle

Renders the `beam` of a pair of a live view into `ax`: in the style of the `layout`, with the
`kwargs` of `live_render!` of the beam (see `_BeamState`) and without clip planes, which
`_apply_clip_planes!` sets explicitly, see `clip_beams`.
"""
_live_render_beam!(ax, layout, beam, kwargs::NamedTuple) =
    live_render!(ax, beam; _beam_style(layout, beam)..., kwargs..., clip_planes = Plane3f[])

"""
    _flen(gui, beam) -> Union{Float64, Nothing}

The length [m] with which a final ray of the `beam` of the `gui`, i.e. one without intersection,
is drawn (`flen` of `live_render!`); `nothing` for a beam that is not part of the pairs.
"""
function _flen(gui::LiveView, beam)
    i = findfirst(p -> p.second === beam, gui.pairs)
    return isnothing(i) ? nothing : Float64(render_settings(gui.beam_handles[i]).flen)
end

"""
    _render_settings!(gui, beam; kwargs...)

Changes the settings with which the `beam` (a beam or beam group of the pairs) of the `gui` is
drawn, see `BeamletOptics.render_settings!`: of each render handle of a pair with the `beam` (a
beam can be part of several pairs), and `flen` also of its overlays (see `_add_overlay!`), which
draw the same rays. The handles and their plots stay, hidden, dimmed and clipped as they are.
Display only: nothing is solved, except that a solve that runs in the background is cancelled and
started again, since the handles draw the rays as they are.
"""
function _render_settings!(gui::LiveView, beam; kwargs...)
    isempty(kwargs) && return nothing
    running = _running(gui)
    _change!(gui.controls, beam) do
        for (p, h) in zip(gui.pairs, gui.beam_handles)
            p.second === beam && render_settings!(h; kwargs...)
        end
        if haskey(kwargs, :flen)
            for store in _overlay_stores(gui)
                h = get(store, beam, nothing)
                isnothing(h) || render_settings!(h; flen = kwargs[:flen])
            end
        end
    end
    running && gui.controls.on_change(beam)
    return nothing
end

"""
    _set_flen!(gui, beam, flen)

Draws the final rays of the `beam` (a beam or beam group of the pairs) of the `gui` with the length
`flen` [m], also those of its overlays that are shown, see `_render_settings!`; the length is kept
in its kwargs, with which the beam is rendered when it is added again. Throws an `ArgumentError`
unless `flen` is positive and finite. Nothing happens if the length does not change.
"""
function _set_flen!(gui::LiveView, beam, flen::Real)
    (isfinite(flen) && flen > 0) ||
        throw(ArgumentError("the length of the final rays must be positive and finite, got $flen"))
    old = _flen(gui, beam)
    (isnothing(old) || old == flen) && return nothing
    new = (; flen = Float64(flen))
    gui.beams.kwargs[beam] = merge(get(gui.beams.kwargs, beam, (;)), new)
    gui.beams.overlay_kwargs[beam] = merge(get(gui.beams.overlay_kwargs, beam, (;)), new)
    _render_settings!(gui, beam; new...)
    return nothing
end

"""The length of the final rays of the `beam` of the `gui` as shown in its box [mm], see `_flen`."""
function _flen_string(gui::LiveView, beam)
    flen = _flen(gui, beam)
    isnothing(flen) && return ""
    v = round(1e3 * flen; sigdigits = 12)
    return isinteger(v) && abs(v) < 1e15 ? string(Int(v)) : string(v)
end

"""
    _apply_flen_input!(gui, beam, s)

Applies the input `s` of the box "length" of the card of the `beam` [mm], see `_set_flen!`. An
input that is no positive number only shows a message in the status line.
"""
function _apply_flen_input!(gui::LiveView, beam, s)
    x = isnothing(s) ? nothing : tryparse(Float64, strip(s))
    if isnothing(x) || !isfinite(x) || x <= 0
        gui.status.text[] = "invalid input \"$(something(s, ""))\" for the length, enter a positive number [mm]"
        return nothing
    end
    _set_flen!(gui, beam, 1e-3 * x)
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
