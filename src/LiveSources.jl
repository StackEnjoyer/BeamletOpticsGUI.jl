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
The color of a source that is added to the live view, as a kwarg of its `live_render!`:
`:wavelength`, i.e. each of its rays in the color of its wavelength, see
`BeamletOptics.wavelength_color`; nothing for a source without rays.
"""
_wavelength_style(::Union{BMO.Beam, BMO.GaussianBeamlet, BMO.AstigmaticGaussianBeamlet}) =
    (; color = :wavelength)
_wavelength_style(src::BMO.AbstractBeamGroup) =
    isempty(BMO.beams(src)) ? (;) : _wavelength_style(first(BMO.beams(src)))
_wavelength_style(_) = (;)

"""
    _source_kwargs(src, beam_kwargs) -> NamedTuple

The kwargs of a source that is added to the live view from its `beam_kwargs`, which are those of
the `beam_kwargs` of `live_view`: by default it is drawn in the colors of its wavelengths (see
`_wavelength_style`), like the sources of the start (see `_beam_style`), and a beam group with
`render_every = 5`. Throws an `ArgumentError` for `show_polarization = true` of a
source without polarized rays and for `show_beams = true` of one that is no Gaussian beamlet.
"""
function _source_kwargs(src, beam_kwargs)
    default = src isa BMO.AbstractBeamGroup ? (; render_every = 5) : (;)
    kw = (; default..., _wavelength_style(src)..., beam_kwargs...)
    get(kw, :show_polarization, false) === true && !_polarizable(src) &&
        throw(ArgumentError("beam_kwargs: show_polarization = true for $(typeof(src)), which has no polarized rays"))
    get(kw, :show_beams, false) === true && !_has_generating_beams(src) &&
        throw(ArgumentError("beam_kwargs: show_beams = true for $(typeof(src)), which is no Gaussian beamlet"))
    return kw
end

# `origin` is `nothing` or `(; code, pose0)`, as for a component: the constructor call of `src` as
# Julia code and its pose as constructed, e.g. of a source of the catalog, see `_ComponentState`
function add_component!(gui::LiveView, src::_Source; system = nothing, select::Bool = true,
        label = nothing, beam_kwargs = (;), code = nothing, origin = _code_origin(src, code))
    ctrl = gui.controls
    sys = _source_system(gui, system)
    any(p -> p.second === src, gui.pairs) && throw(ArgumentError(
        "the $(nameof(typeof(src))) is already a source of the live view"))
    kw = _attach!(gui, src, sys; label, origin, beam_kwargs)
    # The linked views show it before the solve, see `_sync_structure!`
    _sync_structure!(gui)
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
    _record_added!(gui, src)
    return src
end

"""
    _attach!(gui, src, sys; label = nothing, origin = nothing, beam_kwargs = (;)) -> NamedTuple

Shows the source `src` in the `gui`, traced through its system `sys`: the part of
[`add_component!`](@ref) before the solve, i.e. its plots, its marker, its name and what the `gui`
records of it. Also for a view that follows a linked one, in which `src` was added, see
`_follow_structure!`. Returns the kwargs of the source, see `_source_kwargs`, which throws for
kwargs that the source does not take, before the view changes.
"""
function _attach!(gui::LiveView, src::_Source, sys::BMO.AbstractSystem; label = nothing,
        origin = nothing, beam_kwargs = (;))
    ctrl = gui.controls
    comp = gui.components
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
    i = _index(comp.removed, src)
    if !isnothing(i) && length(comp.source_systems[src]) == 1 && only(comp.source_systems[src]) === sys
        deleteat!(comp.removed, i)
        delete!(comp.source_systems, src)
    else
        _has(comp.added, src) || push!(comp.added, src)
        comp.system[src] = sys
        comp.origin[src] = origin
    end
    _table_include!(gui, src)
    _on_components_changed!(gui)
    _update_info!(gui)
    return kw
end

#=
Sources in the undo history, see `_record_added!` and `_record_removed!`
=#

# Of a source: also the systems it is traced through, the kwargs with which it is drawn (e.g. its
# color), whether it is switched on and its overlays
function _snapshot(gui::LiveView, src::_Source)
    ctrl = gui.controls
    beams = gui.beams
    kwargs = merge(get(beams.overlay_kwargs, src, (;)), get(beams.kwargs, src, (;)),
        (; show_polarization = haskey(beams.pol, src), show_beams = haskey(beams.gen, src)))
    names = haskey(gui.objects.names, src) ? Pair{Any, String}[src => gui.objects.names[src]] :
            Pair{Any, String}[]
    init_poses = haskey(ctrl.init_poses, src) ? Pair{Any, Any}[src => ctrl.init_poses[src]] :
                 Pair{Any, Any}[]
    return (; systems = Any[p.first for p in gui.pairs if p.second === src],
        label = get(gui.labels, src, nothing), origin = get(gui.components.origin, src, nothing),
        names, init_poses, kwargs, on = _beam_on(gui, src),
        # a source that the view started with
        start = !_has(gui.components.added, src))
end

function _restore!(gui::LiveView, src::_Source, snap)
    comp = gui.components
    _unrecorded(gui) do
        add_component!(gui, src; system = first(snap.systems), label = snap.label,
            origin = snap.origin, beam_kwargs = snap.kwargs)
        # A source of the start that was traced through several systems
        for sys in snap.systems[2:end]
            _change!(gui.controls, src) do
                push!(gui.pairs, sys => src)
                push!(gui.beam_handles, _live_render_beam!(gui.ax, gui.layout, src, gui.beams.kwargs[src]))
            end
        end
    end
    if snap.start && length(snap.systems) > 1
        # no change for `export_changes`, like a source of the start with a single system
        filter!(o -> o !== src, comp.removed)
        filter!(o -> o !== src, comp.added)
        delete!(comp.source_systems, src)
        delete!(comp.system, src)
        delete!(comp.origin, src)
        gui.trace.stale && _dim_beams!(gui)
        _apply_clip_planes!(gui)
        _on_change!(gui, src)
    end
    snap.on || _set_beam_on!(gui, src, false)
    _restore_names!(gui, snap)
    return nothing
end

function remove_component!(gui::LiveView, src::_Source)
    reason = _removal_reason(gui, src)
    isnothing(reason) || throw(ArgumentError(reason))
    name = _label(gui, src)
    snap = _snapshot(gui, src)
    _detach!(gui, src)
    # The linked views let go of it before the solve, see `_sync_structure!`
    _sync_structure!(gui)
    gui.status.text[] = "$name removed"
    # The detectors lose the hits of the source with the next solve
    _on_change!(gui, nothing)
    isempty(gui.pairs) && (gui.status.text[] = "$name removed, " * _NO_SOURCE)
    _record_removed!(gui, src, snap)
    return src
end

"""
    _detach!(gui, src)

Lets go of the source `src` in the `gui`: the part of [`remove_component!`](@ref) before the solve,
i.e. its pairs, its plots, its marker, its name and what the `gui` records of it. Also for a view
that follows a linked one, in which `src` was removed, see `_follow_structure!`.
"""
function _detach!(gui::LiveView, src::_Source)
    ctrl = gui.controls
    comp = gui.components
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
    added = _index(comp.added, src)
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
    return nothing
end
