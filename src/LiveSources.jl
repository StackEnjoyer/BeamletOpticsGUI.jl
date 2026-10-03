#=
Sources that are added to and removed from the live view at runtime: the methods of
`add_component!` and `remove_component!` for beams and beam groups
=#

"""The sources of a live view: beams and beam groups."""
const _Source = Union{BMO.AbstractBeam, BMO.AbstractBeamGroup}

"""
    _source_system(gui, system) -> AbstractSystem

The system that a source added to the `gui` is traced through: the given `system`, which must be
shown in the `gui`, or, for `nothing`, the system that gets a component (see `_target_system`), else
the first system of the view. A source does not change its system, hence a `StaticSystem` takes
sources as well. Throws an `ArgumentError` otherwise.
"""
function _source_system(gui::LiveView, ::Nothing)
    sys = _target_system(gui)
    return isnothing(sys) ? rendered(first(gui.system_handles)) : sys
end
function _source_system(gui::LiveView, sys::BMO.AbstractSystem)
    isnothing(_system_handle(gui, sys)) &&
        throw(ArgumentError("the system is not shown in the live view"))
    return sys
end
_source_system(::LiveView, x) =
    throw(ArgumentError("`system` must be a system of the live view, got a $(typeof(x))"))

"""
    _source_kwargs(src, beam_kwargs) -> NamedTuple

The kwargs of a source of the live view from its `beam_kwargs`, as for the `beam_kwargs` of
`live_view`: a beam group is rendered with `render_every = 5` by default. Throws an
`ArgumentError` for `show_polarization = true` of a source without polarized rays and for
`show_beams = true` of one that is no Gaussian beamlet.
"""
function _source_kwargs(src, beam_kwargs)
    default = src isa BMO.AbstractBeamGroup ? (; render_every = 5) : (;)
    kw = (; default..., beam_kwargs...)
    get(kw, :show_polarization, false) === true && !_polarizable(src) &&
        throw(ArgumentError("beam_kwargs: show_polarization = true for $(typeof(src)), which has no polarized rays"))
    get(kw, :show_beams, false) === true && !_has_generating_beams(src) &&
        throw(ArgumentError("beam_kwargs: show_beams = true for $(typeof(src)), which is no Gaussian beamlet"))
    return kw
end

# `origin` is `nothing` or `(; code, pose0)`, as for a component: the constructor call of `src` as
# Julia code and its pose as constructed, e.g. of a source of the catalog, see `_ComponentState`
function add_component!(gui::LiveView, src::_Source; system = nothing, select::Bool = true,
        label = nothing, beam_kwargs = (;), origin = nothing)
    ctrl = gui.controls
    comp = gui.components
    sys = _source_system(gui, system)
    any(p -> p.second === src, gui.pairs) && throw(ArgumentError(
        "the $(nameof(typeof(src))) is already a source of the live view"))
    kw = _source_kwargs(src, beam_kwargs)
    # The polarization and the generating beams are drawn by overlays, see `_BeamState`
    beam_kw = Base.structdiff(kw, NamedTuple{(:show_polarization, :show_beams)})
    # Stops a solve in the background, which traces the beams of the pairs; a beam that does not
    # take the kwargs throws before the view changes
    _change!(ctrl, src) do
        h = _live_render_beam!(gui.ax, gui.layout, src, beam_kw)
        gui.beams.kwargs[src] = beam_kw
        gui.beams.overlay_kwargs[src] = Base.structdiff(kw, NamedTuple{(:render_every,)})
        push!(gui.pairs, sys => src)
        push!(gui.beam_handles, h)
    end
    # The marker selects and moves the source, and removes it again: also in a view without
    # `movable_sources`
    if !BMO.is_static(src)
        oh = _live_render_source!(gui.ax, src; size = gui.beams.marker_size[],
            strokecolor = _marker_stroke(gui.layout))
        push!(ctrl.h, oh)
        push!(ctrl.movable, src)
        ctrl.init_poses[src] = _pose(src)
    end
    # Hidden with the markers of the other sources, dimmed and clipped like the other beams
    _update_source_markers!(gui)
    gui.trace.stale && _dim_beams!(gui)
    _apply_clip_planes!(gui)
    isnothing(label) || (gui.labels[src] = String(label))
    _name_objects!(gui)
    # A source the view started with, removed and added again to its systems, is no change
    i = findfirst(o -> o === src, comp.removed)
    if !isnothing(i) && length(comp.source_systems[src]) == 1 && only(comp.source_systems[src]) === sys
        deleteat!(comp.removed, i)
        delete!(comp.source_systems, src)
    else
        push!(comp.added, src)
        comp.system[src] = sys
        comp.origin[src] = origin
    end
    _on_components_changed!(gui)
    _update_info!(gui)
    if select
        # A source is selected by its marker, hence not while the markers are hidden
        if !_is_movable(ctrl, src)
            _inspect!(gui, src)
        elseif _sources_shown(gui)
            _select!(gui, src)
        end
    end
    _on_change!(gui, src)
    # After the solve, like the overlays of the sources of the start, see `_init_overlays!`
    get(kw, :show_polarization, false) === true && _set_polarization!(gui, src, true)
    get(kw, :show_beams, false) === true && _set_generating_beams!(gui, src, true)
    return src
end

function remove_component!(gui::LiveView, src::_Source)
    reason = _removal_reason(gui, src)
    isnothing(reason) || throw(ArgumentError(reason))
    ctrl = gui.controls
    comp = gui.components
    name = _label(gui, src)
    # A source can be traced through several systems
    idx = findall(p -> p.second === src, gui.pairs)
    systems = Any[gui.pairs[i].first for i in idx]
    # Stops a solve in the background, which traces the beams of the pairs
    _change!(ctrl, src) do
        for store in _overlay_stores(gui)
            haskey(store, src) && _remove_overlay!(gui, store, src)
        end
        for h in gui.beam_handles[idx]
            foreach(plot -> delete!(gui.trace.beam_alphas, plot), _beam_plots(h))
            remove_render!(h)
        end
        deleteat!(gui.pairs, idx)
        deleteat!(gui.beam_handles, idx)
        # Untraced, as it is when it is added again
        _empty_beam!(src)
    end
    delete!(gui.beams.off, src)
    delete!(gui.beams.kwargs, src)
    delete!(gui.beams.overlay_kwargs, src)
    delete!(gui.beams.pol_view, src)
    # A source the view started with is listed by `export_changes` as removed, under its name
    added = findfirst(o -> o === src, comp.added)
    _release!(gui, src, Base.IdSet{Any}((src,)); keep_name = isnothing(added))
    oh = _child_handle(ctrl.h, src)
    if !isnothing(oh)
        remove_render!(oh)
        delete!(ctrl.h, oh)
    end
    if isnothing(added)
        push!(comp.removed, src)
        comp.source_systems[src] = systems
    else
        deleteat!(comp.added, added)
        delete!(comp.origin, src)
        delete!(comp.system, src)
    end
    _refresh_menu_options!(gui, gui.widgets.menu)
    _on_components_changed!(gui)
    _update_info!(gui)
    gui.status.text[] = "$name removed"
    # The detectors lose the hits of the source with the next solve
    _on_change!(gui, nothing)
    isempty(gui.pairs) && (gui.status.text[] = "$name removed, " * _NO_SOURCE)
    return src
end
