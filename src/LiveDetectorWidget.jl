#=
The public detector view: the view of a card (see `_DetectorView`) in a figure of its own, the
widget behind `detector_view!`
=#

"""
    DetectorView{G}

The detector view that [`detector_view!`](@ref) builds: the view of the results of one `Detector`
(spot diagram, PSF or intensity, see [`detector_view!`](@ref)) in a layout of a figure. `G` is the
[`LiveView`](@ref live_view) that updates it, or `Nothing`.

Public fields and properties:

- `detector`: the `Detector` that it shows
- `axis`: the `Axis` of the expanded view, in mm of the local x and z of the detector, with equal
  scales; for own decorations, limits or plots. Zoom, pan and the reset of the view are done by the
  widget itself, the interactions of the `Axis` are off
- `kind`: the kind that is shown, `:spot`, `:psf` or `:intensity`, `nothing` without hits
- `metrics`: the metrics of what is shown as a `NamedTuple` in SI units, `nothing` without a result.
  Spot diagram: `(; n, cx, cz, rms, rmax)` (the number of spots, the centroid, the RMS radius and
  the largest distance from the centroid, in m). Intensity: `(; P, cx, cz, wx, wz, peak)` (power in
  W, the centroid and the 1/e² radii along x and z in m, the peak in W/m²; `NaN` without
  intensity). PSF: as intensity without `P`

Update it with [`update_detector_view!`](@ref), color its spots with [`set_spot_colors!`](@ref) and
remove it with `close(view)`.
"""
mutable struct DetectorView{G}
    const detector::BMO.Detector
    const gui::G
    const axis::Axis
    const widget::_DetectorView
    # the options of a view without a live view, those of a live view are in its state, see `_options`
    opts::_ViewOptions
    closed::Bool
end

Base.propertynames(::DetectorView) = (:detector, :axis, :kind, :metrics)

function Base.getproperty(v::DetectorView, name::Symbol)
    name === :kind && return _shown_kind(getfield(v, :widget).result)
    name === :metrics && return _shown_metrics(getfield(v, :widget).result)
    return getfield(v, name)
end

_shown_kind(::Nothing) = nothing
_shown_kind(r::_ViewResult) = isnothing(r.kind) ? nothing : _kind_name(r.kind)
_shown_metrics(::Nothing) = nothing
_shown_metrics(r::_ViewResult) = r.metrics

Base.show(io::IO, v::DetectorView) =
    print(io, "DetectorView(", repr(getfield(v, :widget).name), ", ", something(v.kind, "no hits"), ")")

# The options of the view `v`: those of its detector in its live view, else its own
_options(v::DetectorView{Nothing}) = v.opts
_options(v::DetectorView{<:LiveView}) = _detector_state(v.gui, v.detector).opts

# Grid of the computation: the one of the options if the view is expanded, else of a thumbnail
_view_n(v::DetectorView) = v.widget.expanded ? _options(v).n : min(_options(v).n, _THUMB_N)

# Called by the widget when the user changes an option: with a live view, the options of the
# detector (which its cards share) change and all its views are shown again
_set_options!(v::DetectorView{<:LiveView}; changes...) = _set_view!(v.gui, v.detector; changes...)
function _set_options!(v::DetectorView{Nothing}; changes...)
    v.opts = _ViewOptions(v.opts; changes...)
    haskey(changes, :colorscale) || haskey(changes, :profiles) ? _show_options!(v) : update_detector_view!(v)
    return nothing
end

# The color scale and the profiles only show the result again
_show_options!(v::DetectorView) = _show_result!(v.widget, v.widget.name, v.widget.result, _options(v))

# Called by the widget when the user expands or collapses it
function _on_expanded!(v::DetectorView, expanded::Bool)
    _set_expanded!(v.widget, expanded)
    update_detector_view!(v)
    return nothing
end

function update_detector_view!(v::DetectorView{Nothing})
    result = _view_result(v.detector, v.opts; n = _view_n(v))
    _show_result!(v.widget, v.widget.name, result, v.opts)
    return v
end
function update_detector_view!(v::DetectorView{<:LiveView})
    state = _detector_state(v.gui, v.detector)
    n = _view_n(v)
    _apply_view!(v.gui, _ViewRequest(v.detector, state, state.opts, n), _view_result(v.detector, state.opts; n))
    return v
end

function set_spot_colors!(v::DetectorView, colors)
    _set_spot_colors!(v.widget, _by_hits(colors))
    return v
end

# `spot_colors` as a function of the hits that the view calls for each result, see `_set_spot_colors!`
_by_hits(::Nothing) = nothing
_by_hits(f::Function) = hits -> [f(hit) for hit in hits]
_by_hits(colors) = _ -> colors

# The events of the figure of a position of a layout
_events_of(position) = events(Makie.get_scene(Makie.get_top_parent(position)))

function detector_view!(position, gui::LiveView, pd::BMO.Detector; kwargs...)
    return _detector_view!(position, gui, gui.layout.theme, _label(gui, pd), pd; kwargs...)
end

function detector_view!(position, pd::BMO.Detector; theme::Symbol = :light,
        name::AbstractString = "Detector", kwargs...)
    return _detector_view!(position, nothing, _app_theme(theme), String(name), pd; kwargs...)
end

function _detector_view!(position, gui, theme, name, pd; expanded::Bool = true, width::Real = 280,
        height::Real = 280, spot_colors = nothing, options...)
    kind = get(options, :kind, :auto)
    spec = _view_spec(pd, kind, (; Base.structdiff(NamedTuple(options), (; kind))..., expanded))
    widget = _DetectorView(GridLayout(position), theme; expanded, width, height)
    widget.name = name
    v = DetectorView(pd, gui, widget.ax, widget, spec.opts, false)
    _set_spot_colors!(widget, _by_hits(spot_colors))
    _connect_view!(widget, _events_of(position); on_options = (; changes...) -> _set_options!(v; changes...),
        on_expanded = e -> _on_expanded!(v, e))
    _attach!(v, _given_options(spec.opts, options))
    return v
end

# The options of `opts` that the user passed to `detector_view!` as `options`
_given_options(opts, options) = (; (k => getfield(opts, k) for k in (:kind, :n, :colorscale, :colorrange, :profiles)
    if k in keys(options))..., (any(!in(_VIEW_OPTION_KEYS), keys(options)) ? (; kwargs = opts.kwargs) : (;))...)

# A view of a live view sets the options that were given in those of its detector (which its cards
# share), is computed with the shown views of the live view and shown; a view without one is computed now
function _attach!(v::DetectorView{<:LiveView}, given)
    gui = v.gui
    _set_view!(gui, v.detector; given...)
    _register_view!(gui, v.detector, v.widget)
    _redraw_views!(gui, v.detector)
    _view_needed!(gui, v.detector)
    return nothing
end
_attach!(v::DetectorView{Nothing}, _) = (update_detector_view!(v); nothing)

function Base.close(v::DetectorView)
    v.closed && return nothing
    v.closed = true
    _detach!(v)
    _delete_view!(v.widget)
    return nothing
end

_detach!(::DetectorView{Nothing}) = nothing
_detach!(v::DetectorView{<:LiveView}) = _unregister_view!(v.gui, v.widget)
