#=
Detector view of the live view: the kinds of views per type of hits, their results and metrics,
and the view widget on the page "Results" of the card of a detector
=#

using Makie: Axis, Label, Button, Toggle, GridLayout, Observable, Point2f, Vec2f, Rect2f, RGBAf,
             AbstractPlot, image!, scatter!, lines!, text!, lift, on, off, limits!, autolimits!, Consume,
             Mouse, Outside, Auto, colsize!, colgap!, translate!

#=
Kinds of views, by the type of the hits of the detector
=#

"""
    _ViewKind

Kind of the view of the hits of a detector: `_SpotKind` (the spot diagram), `_PSFKind` (the
intensity of ray hits, normalized to its peak) and `_IntensityKind` (the intensity of beamlet
hits); the latter two are fields on a grid, i.e. `_FieldKind`s. The kinds that hits offer are
`_view_kinds(hits)`. Per kind: `_kind_name`, `_kind_label`, the data (`_kind_data`), the metrics
(`_kind_metrics`) and how the widget draws it (`_draw_kind!`).
"""
abstract type _ViewKind end
abstract type _FieldKind <: _ViewKind end
struct _SpotKind <: _ViewKind end
struct _PSFKind <: _FieldKind end
struct _IntensityKind <: _FieldKind end

"""Name of the `kind` in the options of a view, see `_ViewOptions`."""
_kind_name(::_SpotKind) = :spot
_kind_name(::_PSFKind) = :psf
_kind_name(::_IntensityKind) = :intensity

"""Label of the `kind` in the switch of a view."""
_kind_label(::_SpotKind) = "Spot"
_kind_label(::_PSFKind) = "PSF"
_kind_label(::_IntensityKind) = "Intensity"

"""
    _view_kinds(hits) -> Tuple{Vararg{_ViewKind}}

The kinds of views that the `hits` of a detector offer, the first one is the default: the spot
diagram and the PSF for ray hits, the intensity and the spot diagram for beamlet hits, none
without hits.
"""
_view_kinds(_) = ()
_view_kinds(::AbstractVector{<:BMO.AbstractRayHit}) = (_SpotKind(), _PSFKind())
_view_kinds(::AbstractVector{<:BMO.AbstractBeamletHit}) = (_IntensityKind(), _SpotKind())

# Grid of a field that is shown only as a thumbnail
const _THUMB_N = 48

"""
    _ViewOptions(; kind = :auto, n = 100, kwargs = (;), colorscale = :linear, colorrange = nothing,
        colorbar = true, profiles = false, window = nothing)
    _ViewOptions(opts; changed...)

Options of the view of a detector: the `kind` (`:auto` or a name, see `_kind_name`; a kind that the
hits do not offer falls back to their default), the grid `n` of a field and further `kwargs` of
`BeamletOptics.intensity`, the `colorscale` (`:linear` or `:log`) and the fixed `colorrange` of a
field (or `nothing`), whether the `colorbar` and the `profiles` of a field are shown, and the
`window` `(x_min, x_max, z_min, z_max)` [m] of a field, `nothing` for the automatic limits of
BeamletOptics. The second form copies `opts` with changed fields.
"""
struct _ViewOptions
    kind::Symbol
    n::Int
    kwargs::NamedTuple
    colorscale::Symbol
    colorrange::Any
    colorbar::Bool
    profiles::Bool
    window::Union{Nothing, NTuple{4, Float64}}
end

_ViewOptions(; kind = :auto, n = 100, kwargs = (;), colorscale = :linear, colorrange = nothing,
    colorbar = true, profiles = false, window = nothing) =
    _ViewOptions(kind, n, kwargs, colorscale, colorrange, colorbar, profiles, _view_window(window))

_ViewOptions(o::_ViewOptions; kind = o.kind, n = o.n, kwargs = o.kwargs, colorscale = o.colorscale,
    colorrange = o.colorrange, colorbar = o.colorbar, profiles = o.profiles, window = o.window) =
    _ViewOptions(kind, n, kwargs, colorscale, colorrange, colorbar, profiles, _view_window(window))

_view_window(::Nothing) = nothing
_view_window(w) = NTuple{4, Float64}(Float64.(Tuple(w)))

Base.:(==)(a::_ViewOptions, b::_ViewOptions) =
    all(f -> getfield(a, f) == getfield(b, f), fieldnames(_ViewOptions))
Base.hash(o::_ViewOptions, h::UInt) =
    foldl((h, f) -> hash(getfield(o, f), h), fieldnames(_ViewOptions); init = hash(:_ViewOptions, h))

"""
    _ViewResult

What the view of a detector shows after a solve, computed by `_view_result`: the `kinds` that the
hits offer, the `kind` that is shown (`nothing` without hits), its `data` (the points [m] of a
spot diagram, or `(x, z, I)` of a field), its `metrics` (see `_kind_metrics`) and the exception
`error` of a failed computation (then without data and metrics). `n` is the grid of the field as
computed (after the reduction of a `coarse` result; as requested for a spot diagram), `coarse` and
`preview` mark a result on a coarse grid and after a preview solve.
"""
struct _ViewResult
    kinds::Tuple{Vararg{_ViewKind}}
    kind::Union{Nothing, _ViewKind}
    data::Any
    metrics::Any
    n::Int
    coarse::Bool
    preview::Bool
    error::Any
end

"""Returns the kind of the `kinds` with the `name`, their first one for `:auto` or another name."""
function _resolve_kind(kinds::Tuple, name::Symbol)
    i = findfirst(k -> _kind_name(k) == name, kinds)
    return isnothing(i) ? first(kinds) : kinds[i]
end

"""Grid of a field with `n` samples, reduced for a `coarse` result while objects move."""
_view_grid(n::Integer, coarse::Bool) = coarse ? max(16, Int(n) ÷ 4) : Int(n)

_window_kwargs(::Nothing) = (;)
_window_kwargs(w::NTuple{4, Float64}) = (; x_min = w[1], x_max = w[2], z_min = w[3], z_max = w[4])

"""
    _kind_data(kind, pd, hits, opts, n, coarse)

Computes the data of the `kind` of view for the detector `pd` with the `hits`: the points [m] of
the spot diagram, or the field `(x, z, I)` on the grid `_view_grid(n, coarse)` in the window of
the `opts` (see `_ViewOptions`), for the PSF divided by its maximum.
"""
_kind_data(::_SpotKind, pd, _, _, _, _) = BMO.spot_diagram(pd)
function _kind_data(::_IntensityKind, pd, _, opts::_ViewOptions, n, coarse)
    kwargs = merge(opts.kwargs, (; n = _view_grid(n, coarse)), _window_kwargs(opts.window))
    x, z, I = BMO.intensity(pd; kwargs...)
    return (x, z, I)
end
function _kind_data(::_PSFKind, pd, hits, opts::_ViewOptions, n, coarse)
    x, z, I = _kind_data(_IntensityKind(), pd, hits, opts, n, coarse)
    peak = maximum(I)
    return (x, z, peak > 0 ? I ./ peak : I)
end

# The data of the `kind`, with the kind that is shown
_shown_data(kind::_ViewKind, pd, hits, opts, n, coarse) =
    (kind, _kind_data(kind, pd, hits, opts, n, coarse))

# With the kind `:auto`, the spot diagram is shown if the field of the hits can not be evaluated
function _shown_data(kind::_IntensityKind, pd, hits::AbstractVector{<:BMO.AstigmaticGaussianBeamletHit},
        opts, n, coarse)
    try
        return (kind, _kind_data(kind, pd, hits, opts, n, coarse))
    catch e
        (BMO.is_cancelled(e) || opts.kind != :auto) && rethrow()
        return (_SpotKind(), _kind_data(_SpotKind(), pd, hits, opts, n, coarse))
    end
end

"""Metrics of the `data` of the `kind`, see `_spot_metrics` and `_intensity_metrics`; the PSF without the power."""
_kind_metrics(::_SpotKind, pts) = _spot_metrics(pts)
_kind_metrics(::_IntensityKind, (x, z, I)) = _intensity_metrics(x, z, I)
function _kind_metrics(::_PSFKind, (x, z, I))
    m = _intensity_metrics(x, z, I)
    return (; m.cx, m.cz, m.wx, m.wz, m.peak)
end

_result_n(::_FieldKind, n, coarse) = _view_grid(n, coarse)
_result_n(::_ViewKind, n, _) = Int(n)

"""
    _view_result(pd, opts::_ViewOptions; n = opts.n, coarse = false, preview = false) -> _ViewResult

Computes what the view of the detector `pd` shows with the options `opts`: the kinds of its hits,
the kind of the options or their default, its data (`BeamletOptics.spot_diagram`, or
`BeamletOptics.intensity` on a grid of `n`, for `coarse` a quarter of it, at least 16) and its
metrics. Creates no plot and touches no observable, such that it can run in a background task.
An error is returned in the result, a cancelled solve is rethrown, see `BMO.is_cancelled`.
"""
function _view_result(pd, opts::_ViewOptions; n::Integer = opts.n, coarse::Bool = false,
        preview::Bool = false)
    kinds, kind = (), nothing
    try
        hits = BMO.hits(pd)
        kinds = _view_kinds(hits)
        isempty(kinds) && return _ViewResult(kinds, nothing, nothing, nothing, Int(n), coarse, preview, nothing)
        kind = _resolve_kind(kinds, opts.kind)
        kind, data = _shown_data(kind, pd, hits, opts, n, coarse)
        return _ViewResult(kinds, kind, data, _kind_metrics(kind, data), _result_n(kind, n, coarse),
            coarse, preview, nothing)
    catch e
        BMO.is_cancelled(e) && rethrow()
        return _ViewResult(kinds, kind, nothing, nothing, Int(n), coarse, preview, e)
    end
end

#=
Metrics and their texts
=#

# Floor of the logarithmic intensity scale, relative to the maximum
const _LOG_FLOOR = 1e-4

"""Formats `x` with 3 decimal places."""
function _fmt3(x::Real)
    s = string(round(x, digits = 3))
    occursin(r"[eE]", s) && return s
    i = findfirst('.', s)
    isnothing(i) && return s * ".000"
    return s * "0"^max(0, 3 - (length(s) - i))
end

"""
    _spot_metrics(pts)

Returns the metrics `(; n, cx, cz, rms, rmax)` of the spot diagram `pts` (local x/z [m]): the
number of hits, the centroid, the RMS radius `sqrt(mean(|p - c|²))` and the geometric radius, i.e.
the largest distance from the centroid [m].
"""
function _spot_metrics(pts)
    n = length(pts)
    cx = sum(q -> Float64(q[1]), pts) / n
    cz = sum(q -> Float64(q[2]), pts) / n
    r2 = [(Float64(q[1]) - cx)^2 + (Float64(q[2]) - cz)^2 for q in pts]
    return (; n, cx, cz, rms = sqrt(sum(r2) / n), rmax = sqrt(maximum(r2)))
end

"""
    _intensity_metrics(x, z, I)

Returns the metrics `(; P, cx, cz, wx, wz, peak)` of the intensity `I[i, j]` at `x[i]`, `z[j]`
[m]: the power (integrated like `optical_power`), the centroid, the 1/e² radii `2σ` from the second
moments along x and z and the peak intensity. The centroid and the radii are `NaN` without
intensity.
"""
function _intensity_metrics(x, z, I)
    P = trapz((x, z), I)
    peak = maximum(I)
    S = sum(I)
    S > 0 || return (; P, cx = NaN, cz = NaN, wx = NaN, wz = NaN, peak)
    # Marginal distributions along x and z, the uniform cell area cancels
    Ix, Iz = vec(sum(I; dims = 2)), vec(sum(I; dims = 1))
    cx, cz = dot(Ix, x) / S, dot(Iz, z) / S
    σx2 = sum(Ix .* (x .- cx) .^ 2) / S
    σz2 = sum(Iz .* (z .- cz) .^ 2) / S
    return (; P, cx, cz, wx = 2 * sqrt(σx2), wz = 2 * sqrt(σz2), peak)
end

"""Formats the length `x` like `_length_string` with its sign, below 1 pm as `0 nm`."""
function _signed_length_string(x)
    abs(x) < 1e-12 && return "0 nm"
    return x < 0 ? "-" * _length_string(-x) : _length_string(x)
end

"""Formats the metrics `m` of a view, see `_spot_metrics` and `_intensity_metrics`, in two lines."""
function _metrics_string(m)
    if haskey(m, :rms)
        return "N = $(m.n), c = ($(_signed_length_string(m.cx)), $(_signed_length_string(m.cz)))\n" *
               "rms $(_length_string(m.rms)), max $(_length_string(m.rmax))"
    end
    s = "P = $(_fmt3(1e3 * m.P)) mW, peak $(_fmt_sigdigits(m.peak)) W/m²"
    isfinite(m.cx) || return s * "\nno intensity"
    return s * "\nc = ($(_signed_length_string(m.cx)), $(_signed_length_string(m.cz))), " *
           "w = ($(_length_string(m.wx)), $(_length_string(m.wz)))"
end

"""
    _pad_degenerate_limits!(ax, xy; ε = 1e-6)

Sets the limits of the spot diagram `ax` if the x or z extent of the spots `xy` [mm] is below `ε`,
e.g. for a single ray, since a zero-width data range gives degenerate limits. A degenerate axis
gets half the extent of the other axis around its center, or 1 µm if both are degenerate. Otherwise
the limits of `autolimits!` are kept.
"""
function _pad_degenerate_limits!(ax::Axis, xy; ε = 1e-6)
    isempty(xy) && return nothing
    xmin, xmax = extrema(q -> Float64(q[1]), xy)
    zmin, zmax = extrema(q -> Float64(q[2]), xy)
    Δx, Δz = xmax - xmin, zmax - zmin
    (Δx < ε || Δz < ε) || return nothing
    h = max(Δx, Δz) / 2
    h = h < ε ? 1e-3 : h
    hx = Δx < ε ? h : Δx / 2 * 1.05
    hz = Δz < ε ? h : Δz / 2 * 1.05
    cx, cz = (xmin + xmax) / 2, (zmin + zmax) / 2
    limits!(ax, cx - hx, cx + hx, cz - hz, cz + hz)
    return nothing
end

"""
    _display_intensity(I, colorscale) -> (values, colorrange)

Returns the values of the image of the intensity `I` and their color range: `I` for the linear
scale, `log10(I)` with a floor of `_LOG_FLOOR` times the maximum for the logarithmic scale.
"""
function _display_intensity(I, colorscale::Symbol)
    Imax = Float64(maximum(I))
    colorscale == :linear && return I, (0.0, Imax > 0 ? Imax : 1.0)
    floor = Imax > 0 ? _LOG_FLOOR * Imax : _LOG_FLOOR
    return log10.(max.(I, floor)), (log10(floor), log10(floor / _LOG_FLOOR))
end

# The two lines of the metrics below the expanded view
_metrics_text(::_ViewKind, m) = _metrics_string(m)
function _metrics_text(::_PSFKind, m)
    s = "PSF, normalized to its peak"
    isfinite(m.cx) || return s * "\nno intensity"
    return s * "\n" * _centroid_text(m) * ", " * _radii_text(_PSFKind(), m)
end

_centroid_text(m) = "c = ($(_signed_length_string(m.cx)), $(_signed_length_string(m.cz)))"
_radii_text(::_SpotKind, m) = "rms $(_length_string(m.rms)), max $(_length_string(m.rmax))"
_radii_text(::_FieldKind, m) = "w = ($(_length_string(m.wx)), $(_length_string(m.wz)))"

# The key value of the metrics beside the thumbnail
_key_text(::_SpotKind, m) = "N = $(m.n)"
_key_text(::_IntensityKind, m) = "P = $(_fmt3(1e3 * m.P)) mW"
_key_text(::_PSFKind, _) = "normalized"

# The key value, the centroid and the radii beside the thumbnail, one per line
function _thumb_text(kind::_ViewKind, m)
    isfinite(m.cx) || return _key_text(kind, m) * "\nno intensity"
    return join((_key_text(kind, m), _centroid_text(m), _radii_text(kind, m)), "\n")
end

#=
The view widget
=#

# Side of the thumbnail of a collapsed view [px]
const _THUMB_SIZE = 92.0f0
# Height of the axis of the profiles [px]
const _VIEW_PROFILES_HEIGHT = 70.0f0
# Height of the colorbar of a field without its tick labels [px], and its ticks
const _VIEW_BAR_HEIGHT = 8.0f0
const _VIEW_BAR_TICKS = Makie.WilkinsonTicks(4; k_min = 2)
# Ticks of the expanded view, of the axis and of the labels drawn inside its frame
const _VIEW_TICKS = Makie.WilkinsonTicks(5; k_min = 3)
# Font size of the texts inside the frame, their offsets from the edges of the frame [px] and the
# room that is kept free between two of them [px]
const _VIEW_FONTSIZE = 10
const _VIEW_LABEL_OFFSET = (; x = 8.0f0, z = 9.0f0, corner = 6.0f0)
const _VIEW_LABEL_GAP = 4.0f0
# z translation of the texts inside the frame relative to the image, see `_DetectorView`
const _VIEW_OVERLAY_DZ = 5.0f0
# Zoom per step of the wheel and the longest pause between the presses of a double click [s]
const _VIEW_ZOOM_SPEED = 0.1
const _VIEW_DOUBLE_CLICK = 0.35
# The rectangle of a zoom selection: its z above the plots, the opacity of its fill and the
# smallest size [px] that zooms
const _VIEW_SELECT_DZ = 4.5f0
# The lines of the cuts of the profiles: their z, above the image and below the centroid, and their
# opacity, with which they stay in the background of the image
const _VIEW_CUT_DZ = 3.5f0
const _VIEW_CUT_ALPHA = 0.5f0
const _VIEW_SELECT_ALPHA = 0.2f0
const _VIEW_SELECT_MIN = 4.0f0

_no_options(; _...) = nothing
_no_expanded(::Bool) = nothing

"""
    _DetectorView(grid::GridLayout, theme::NamedTuple; expanded = true, width = 280, height = 280)

The view of the results of a detector, built into the `grid` of its host (a layout of a figure,
e.g. in a sidebar, or a free layout in the pixel scene of a floating card) in the color tokens
`theme`. It shows a `_ViewResult` (see `_show_result!`) in one of two states, both built once and
switched by `_set_expanded!`; the layout of the other state is detached, hidden and laid out
off-screen:

- collapsed (`thumb`): a thumbnail axis of `_THUMB_SIZE` without decorations, right of it the
  chevron `expand_button`, the kind in bold and the key value, the centroid and the radii of the
  metrics. A click on the thumbnail or the chevron calls `on_expanded(true)`.
- expanded (`full`): the switch of the kinds that the hits offer (a `_Segmented` per set of kinds,
  built when it is first needed) and the chevron `collapse_button`, which calls
  `on_expanded(false)`; below, the toggles "log", "profiles" and "bar" of a field and the button
  "fit"; the axis `ax` of `width` × `height` pixels in mm with equal scales, the y axis on the
  right and all decorations inside its frame; the colorbar of a field (`bar`: the colormap over
  the color range of the image in the axis `bar_ax`, its ticks below and its unit right of it,
  see `_set_bar!`) and the axis of the profiles of a field along x (red) and z (blue) through the
  centroid, each if its options ask for it; the metrics in two lines. A red cross marks the
  centroid of a spot diagram, and that of a field while its profiles are shown, together with a
  dashed line along each of the two cuts in the color of its profile (`cut_x`, `cut_z`).

The tick labels and the axis names of `ax` are own texts in the axis (`xlabels`, `zlabels`,
`xname`, `zname`, `status`), in front of the image by `_VIEW_OVERLAY_DZ`, since the decorations of
an `Axis` are drawn below its plots; they follow its limits, see `_update_decorations!`. The
interactions of the axes are deregistered: in a floating card they never fire, see
`_connect_view!` for the zoom, the pan and the reset of the view.

The widget does not change the options itself: it calls `on_options` with the changed option and
`on_expanded`, and the host shows the result again.
"""
mutable struct _DetectorView
    const grid::GridLayout
    const theme::NamedTuple
    expanded::Bool
    # collapsed
    const thumb::GridLayout
    const thumb_ax::Axis
    const expand_button::_IconButton
    const kind_label::Label
    const info_label::Label
    # expanded
    const full::GridLayout
    const header::GridLayout
    const controls::GridLayout
    const field_controls::GridLayout
    const log_toggle::Toggle
    const profiles_toggle::Toggle
    const bar_toggle::Toggle
    const fit_button::Button
    const collapse_button::_IconButton
    const plots::GridLayout
    const ax::Axis
    const bar::GridLayout
    const bar_ax::Axis
    const bar_unit::Label
    const bar_image::AbstractPlot
    const profiles_ax::Axis
    const metrics_label::Label
    # the switch per set of kinds and the one that is shown
    const switches::Dict{Any, _Segmented}
    switch::Union{Nothing, _Segmented}
    switch_key::Any
    # plots of the thumbnail and of the axis
    const frames::Vector{AbstractPlot}
    const images::Vector{AbstractPlot}
    const spots::Vector{AbstractPlot}
    const crosses::Vector{AbstractPlot}
    const profile_x::AbstractPlot
    const profile_z::AbstractPlot
    # the lines of the cuts of the profiles in the axis and the point [mm] they cross in
    const cut_x::AbstractPlot
    const cut_z::AbstractPlot
    cut::Union{Nothing, Point2f}
    # the rectangle of a zoom selection in the axis
    const select_fill::AbstractPlot
    const select_line::AbstractPlot
    # texts inside the frame of the axis and their pixel boxes in the frame
    const xlabels::AbstractPlot
    const zlabels::AbstractPlot
    const xname::AbstractPlot
    const zname::AbstractPlot
    const status::AbstractPlot
    boxes::Vector{Rect2f}
    const font::Any
    const text_sizes::Dict{String, Vec2f}
    # what is shown
    shown::Bool
    name::String
    result::Union{Nothing, _ViewResult}
    opts::_ViewOptions
    kind::Union{Nothing, _ViewKind}
    scale::Any
    xy::Vector{Point2f}
    extent::NTuple{4, Float64}
    status_text::String
    fields_shown::Bool
    bar_shown::Bool
    profiles_shown::Bool
    # the limits of a spot diagram were changed by the mouse, they stay over new results
    zoomed::Bool
    refreshing::Bool
    last_error::Union{Nothing, String}
    # mouse: the pan (start [px] and the limits then), the start [px] of a zoom selection, whether
    # the pan moved, the last press
    drag::Any
    select::Union{Nothing, Point2f}
    dragged::Bool
    thumb_pressed::Bool
    last_press::Float64
    press_position::Point2f
    on_options::Any
    on_expanded::Any
    const listeners::Vector{Any}
end

# Axis of a view in the tokens `t`: equal scales that fill the frame, nothing outside the frame
function _view_axis(pos, t::NamedTuple; kwargs...)
    ax = Axis(pos; _card_style(t, Axis)..., autolimitaspect = 1, alignmode = Outside(),
        halign = :left, valign = :top, backgroundcolor = :transparent, xgridvisible = false,
        ygridvisible = false, xticklabelsvisible = false, yticklabelsvisible = false,
        xlabelvisible = false, ylabelvisible = false, titlevisible = false, kwargs...)
    _deregister_interactions!(ax)
    return ax
end

# The interactions of `Axis` come after the camera of the 3D view and the shield of the cards
_deregister_interactions!(ax::Axis) =
    foreach(name -> Makie.deregister_interaction!(ax, name), collect(keys(Makie.interactions(ax))))

# The plots of a result in the axis `ax`: the background of its frame, the image of a field or the
# spots, and the centroid. The background of the `Axis` itself lies behind the background of a
# floating card, and plots at the z of the card scene are not ordered against it: each plot gets a
# z translation of its own, below `_VIEW_OVERLAY_DZ`. The background is an image of one pixel over
# the limits, since plots in the relative space are drawn without the z of the card scene
function _view_plots!(ax::Axis, t::NamedTuple, margin::Float32)
    frame = image!(ax, (0.0, 1.0), (0.0, 1.0), fill(RGBAf(0, 0, 0, 0), 1, 1); xautolimits = false,
        yautolimits = false, inspectable = false)
    on(ax.finallimits; update = true) do lims
        (x0, z0), (x1, z1) = minimum(lims), maximum(lims)
        Makie.update!(frame; arg1 = (x0, x1), arg2 = (z0, z1))
    end
    image = image!(ax, (0.0, 1.0), (0.0, 1.0), zeros(Float32, 2, 2); colormap = :viridis,
        colorrange = (0.0f0, 1.0f0), interpolate = true, visible = false, inspectable = false)
    spots = scatter!(ax, Point2f[]; markersize = 3, color = t.text, visible = false, inspectable = false)
    cross = scatter!(ax, Point2f[]; marker = :cross, markersize = 11, color = :red, inspectable = false)
    foreach(((k, p),) -> translate!(p, 0, 0, k), enumerate((frame, image, spots, cross)))
    # An image sets the margins of the automatic limits to zero, the spots need them
    ax.xautolimitmargin[] = (margin, margin)
    ax.yautolimitmargin[] = (margin, margin)
    return (; frame, image, spots, cross)
end

function _DetectorView(grid::GridLayout, theme::NamedTuple; expanded::Bool = true, width::Real = 280,
        height::Real = 280)
    t = theme
    label = (; _card_style(t, Label)..., halign = :left)
    small = (; label..., fontsize = 11, color = t.muted)
    icons = _card_icons(t; size = 18, icon_size = 14)

    # collapsed: the thumbnail and the metrics
    thumb = GridLayout(grid[1, 1]; halign = :left, valign = :top, default_colgap = 8)
    thumb_ax = _view_axis(thumb[1, 1], t; width = _THUMB_SIZE, height = _THUMB_SIZE,
        xticksvisible = false, yticksvisible = false)
    side = GridLayout(thumb[1, 2]; halign = :left, valign = :top, default_rowgap = 2)
    # The chevron and the kind in a row of their own: a label that spans columns would not report
    # its width, and the texts would stick out of the card
    title = GridLayout(side[1, 1]; halign = :left, default_colgap = 2)
    expand_button = _IconButton(title[1, 1]; icon = :expand, icons...)
    kind_label = Label(title[1, 2], ""; label..., font = :bold)
    info_label = Label(side[2, 1], ""; small..., justification = :left, valign = :top)

    # expanded: the switch and the chevron, the controls, the axis, the profiles and the metrics
    full = GridLayout(grid[1, 1]; halign = :left, valign = :top, default_rowgap = 5)
    header = GridLayout(full[1, 1]; tellwidth = false, default_colgap = 6)
    collapse_button = _IconButton(header[1, 3]; icon = :collapse, icons...)
    colsize!(header, 2, Auto())
    controls = GridLayout(full[2, 1]; tellwidth = false, default_colgap = 6)
    field_controls = GridLayout(controls[1, 1]; default_colgap = 4)
    toggle = (; _card_style(t, Toggle)..., length = 26, markersize = 14)
    Label(field_controls[1, 1], "log"; small...)
    log_toggle = Toggle(field_controls[1, 2]; toggle...)
    Label(field_controls[1, 3], "profiles"; small...)
    profiles_toggle = Toggle(field_controls[1, 4]; toggle...)
    Label(field_controls[1, 5], "bar"; small...)
    bar_toggle = Toggle(field_controls[1, 6]; toggle...)
    colgap!(field_controls, 2, 8)
    colgap!(field_controls, 4, 8)
    fit_button = Button(controls[1, 3]; label = "fit", _card_style(t, Button)..., fontsize = 11,
        height = 20, padding = (6, 6, 2, 2))
    colsize!(controls, 2, Auto())
    plots = GridLayout(full[3, 1]; halign = :left, valign = :top, default_rowgap = 5)
    ax = _view_axis(plots[1, 1], t; width, height, yaxisposition = :right, xtickalign = 1,
        ytickalign = 1, xticksize = 4, yticksize = 4, xticks = _VIEW_TICKS, yticks = _VIEW_TICKS)
    # The colorbar: its axis fills the width that its unit leaves
    bar = GridLayout(plots[2, 1]; tellwidth = false, default_colgap = 6)
    bar_ax = Axis(bar[1, 1]; _card_style(t, Axis)..., height = _VIEW_BAR_HEIGHT,
        alignmode = Outside(), backgroundcolor = :transparent, xgridvisible = false,
        ygridvisible = false, yticksvisible = false, yticklabelsvisible = false,
        xticks = _VIEW_BAR_TICKS, xticklabelsize = 9, xticksize = 3)
    _deregister_interactions!(bar_ax)
    bar_unit = Label(bar[1, 2], ""; small..., fontsize = _VIEW_FONTSIZE, valign = :top,
        padding = (0, 0, 0, -1))
    profiles_ax = Axis(plots[3, 1]; _card_style(t, Axis)..., height = _VIEW_PROFILES_HEIGHT,
        tellwidth = false, alignmode = Outside(), backgroundcolor = :transparent,
        xgridvisible = false, ygridvisible = false, yticksvisible = false,
        yticklabelsvisible = false, xticklabelsize = 9, xticksize = 3)
    _deregister_interactions!(profiles_ax)
    metrics_label = Label(full[4, 1], ""; small..., justification = :left, tellwidth = false)

    a, b = _view_plots!(thumb_ax, t, 0.05f0), _view_plots!(ax, t, 0.1f0)
    profile = (; inspectable = false, linewidth = 1.5)
    profile_x = lines!(profiles_ax, Point2f[]; color = t.gizmo[1], profile...)
    profile_z = lines!(profiles_ax, Point2f[]; color = t.gizmo[3], profile...)
    # The names of the profiles in the top left corner of their frame
    legend = (; fontsize = _VIEW_FONTSIZE, align = (:left, :top), inspectable = false,
        xautolimits = false, yautolimits = false)
    corner = lift(l -> [Makie.Point2d(minimum(l)[1], maximum(l)[2])], profiles_ax.finallimits)
    legend_x = text!(profiles_ax, corner; text = ["x"], color = t.gizmo[1], offset = (6, -4), legend...)
    legend_z = text!(profiles_ax, corner; text = ["z"], color = t.gizmo[3], offset = (18, -4), legend...)
    # The colormap from its first to its last color over the limits of the bar, see `_set_bar!`
    bar_image = image!(bar_ax, (0.0, 1.0), (0.0, 1.0), reshape(collect(range(0.0f0, 1.0f0; length = 256)), :, 1);
        colormap = :viridis, colorrange = (0.0f0, 1.0f0), interpolate = true, inspectable = false)
    limits!(bar_ax, 0, 1, 0, 1)
    foreach(p -> translate!(p, 0, 0, 2), (profile_x, profile_z, bar_image))
    foreach(p -> translate!(p, 0, 0, _VIEW_OVERLAY_DZ), (legend_x, legend_z))
    # The rectangle of a zoom selection does not count for the limits
    select = (; visible = false, inspectable = false, xautolimits = false, yautolimits = false)
    select_fill = poly!(ax, Rect2f(0, 0, 1, 1); color = (t.text, _VIEW_SELECT_ALPHA), select...)
    select_line = lines!(ax, Point2f[]; color = t.text, linewidth = 1, select...)
    foreach(p -> translate!(p, 0, 0, _VIEW_SELECT_DZ), (select_fill, select_line))
    # The lines of the cuts of the profiles follow the limits, see `_update_cuts!`
    cut = (; linestyle = :dash, linewidth = 1, inspectable = false, xautolimits = false, yautolimits = false)
    cut_x = lines!(ax, Point2f[]; color = (t.gizmo[1], _VIEW_CUT_ALPHA), cut...)
    cut_z = lines!(ax, Point2f[]; color = (t.gizmo[3], _VIEW_CUT_ALPHA), cut...)
    foreach(p -> translate!(p, 0, 0, _VIEW_CUT_DZ), (cut_x, cut_z))

    # The texts inside the frame do not count for the limits, which they follow
    o = _VIEW_LABEL_OFFSET
    style = (; fontsize = _VIEW_FONTSIZE, color = t.text, glowwidth = 0.0, glowcolor = (:black, 0.55),
        xautolimits = false, yautolimits = false, inspectable = false)
    point = [Makie.Point2d(0)]
    xlabels = text!(ax, Makie.Point2d[]; text = String[], align = (:center, :bottom), offset = (0, o.x), style...)
    zlabels = text!(ax, Makie.Point2d[]; text = String[], align = (:right, :center), offset = (-o.z, 0), style...)
    xname = text!(ax, point; text = ["x [mm]"], align = (:left, :bottom), offset = (o.corner, o.x), style...)
    zname = text!(ax, point; text = ["z [mm]"], align = (:right, :top), offset = (-o.z, -o.corner), style...)
    status = text!(ax, point; text = [""], align = (:left, :top), offset = (o.corner, -o.corner), style...)
    foreach(p -> translate!(p, 0, 0, _VIEW_OVERLAY_DZ), (xlabels, zlabels, xname, zname, status))

    v = _DetectorView(grid, t, true, thumb, thumb_ax, expand_button, kind_label, info_label, full,
        header, controls, field_controls, log_toggle, profiles_toggle, bar_toggle, fit_button,
        collapse_button, plots, ax, bar, bar_ax, bar_unit, bar_image, profiles_ax, metrics_label,
        Dict{Any, _Segmented}(), nothing, (),
        AbstractPlot[a.frame, b.frame], AbstractPlot[a.image, b.image], AbstractPlot[a.spots, b.spots], AbstractPlot[a.cross, b.cross],
        profile_x, profile_z, cut_x, cut_z, nothing, select_fill, select_line, xlabels, zlabels, xname,
        zname, status, Rect2f[],
        _tree_font(ax.blockscene, :regular), Dict{String, Vec2f}(), false, "", nothing,
        _ViewOptions(), nothing, nothing, Point2f[], (0.0, 1.0, 0.0, 1.0), "", true, true, true, false,
        false, nothing, nothing, nothing, false, false, 0.0, Point2f(0), _no_options, _no_expanded, Any[])

    on(_ -> _update_decorations!(v), ax.finallimits)
    on(_ -> _update_cuts!(v), ax.finallimits)
    on(_ -> _update_decorations!(v), ax.scene.viewport)
    on(_ -> v.on_expanded(true), expand_button.clicks)
    on(_ -> v.on_expanded(false), collapse_button.clicks)
    on(_ -> _fit!(v), fit_button.clicks)
    on(a -> v.refreshing || v.on_options(; colorscale = a ? :log : :linear), log_toggle.active)
    on(a -> v.refreshing || v.on_options(; profiles = a), profiles_toggle.active)
    on(a -> v.refreshing || v.on_options(; colorbar = a), bar_toggle.active)

    # Both states are built, the one that is not shown and the parts without a result are detached
    _show_profiles!(v, false)
    _show_bar!(v, false)
    _show_field_controls!(v, false)
    _view_detach!(expanded ? thumb : full)
    v.expanded = expanded
    _draw_empty!(v, "no result")
    return v
end

Base.show(io::IO, v::_DetectorView) =
    print(io, "_DetectorView(", repr(v.name), ", ", v.expanded ? "expanded" : "collapsed", ")")

#=
Parts of the widget that are not shown: detached from their layout, hidden and laid out
off-screen, like the collapsed parts of the layouts, see `_set_shown!`
=#

function _view_detach!(x)
    foreach(Makie.hide!, _blocks!(Any[], x))
    content = Makie.GridLayoutBase.gridcontent(x)
    isnothing(content) || Makie.GridLayoutBase.remove_from_gridlayout!(content)
    w = Makie.widths(x.layoutobservables.computedbbox[])
    x.layoutobservables.suggestedbbox[] = Rect2f(_OFFSCREEN, w)
    return nothing
end

# Places `x` in the cell of the `parent`; its blocks are `shown` unless the parent is hidden itself
function _view_attach!(parent::GridLayout, row, col, x, shown::Bool)
    parent[row, col] = x
    foreach(shown ? Makie.unhide! : Makie.hide!, _blocks!(Any[], x))
    return nothing
end

# The layout of the state of the view `v`
_state_layout(v::_DetectorView) = v.expanded ? v.full : v.thumb

"""
    _set_expanded!(view, expanded::Bool)

Shows the thumbnail with the metrics, or (`expanded`) the large view with its controls.
"""
function _set_expanded!(v::_DetectorView, expanded::Bool)
    v.expanded == expanded && return nothing
    _view_detach!(_state_layout(v))
    v.expanded = expanded
    v.drag = nothing
    v.thumb_pressed = false
    _view_attach!(v.grid, 1, 1, _state_layout(v), true)
    expanded && _refresh_switch!(v)
    return nothing
end

# The switch of the kinds of the shown result, which a collapsed view could not build
_refresh_switch!(v::_DetectorView) = _refresh_switch!(v, v.result)
_refresh_switch!(::_DetectorView, ::Nothing) = nothing
function _refresh_switch!(v::_DetectorView, r::_ViewResult)
    v.refreshing = true
    try
        _show_switch!(v, r.kinds, r.kind)
    finally
        v.refreshing = false
    end
    return nothing
end

"""Sets the size of the axis of the expanded view `v` to `width` × `height` pixels."""
function _resize_view!(v::_DetectorView, width::Real, height::Real)
    _update!(v.ax.width, Float32(width))
    _update!(v.ax.height, Float32(height))
    return nothing
end

"""Returns the size [px] of the whole widget `v` in its current state."""
_view_size(v::_DetectorView) = Vec2f(Makie.widths(_state_layout(v).layoutobservables.computedbbox[]))

"""Returns `true` if the figure pixel `p` is over the widget `v`."""
_over_view(v::_DetectorView, p::Point2f) =
    p in Rect2f(_state_layout(v).layoutobservables.computedbbox[])

# The mouse at the figure pixel `p` is over the axis of the expanded view, or over the thumbnail
_over_axis(v::_DetectorView, p::Point2f) = v.expanded && p in Rect2f(v.ax.scene.viewport[])
_over_thumb(v::_DetectorView, p::Point2f) = !v.expanded && p in Rect2f(v.thumb_ax.scene.viewport[])

function _show_field_controls!(v::_DetectorView, shown::Bool)
    v.fields_shown == shown && return nothing
    v.fields_shown = shown
    shown ? _view_attach!(v.controls, 1, 1, v.field_controls, v.expanded) : _view_detach!(v.field_controls)
    return nothing
end

function _show_profiles!(v::_DetectorView, shown::Bool)
    v.profiles_shown == shown && return nothing
    v.profiles_shown = shown
    _arrange_plots!(v)
    return nothing
end

function _show_bar!(v::_DetectorView, shown::Bool)
    v.bar_shown == shown && return nothing
    v.bar_shown = shown
    _arrange_plots!(v)
    return nothing
end

# The colorbar and the profiles below the axis, in this order: those that are shown, without a
# row for the other one
function _arrange_plots!(v::_DetectorView)
    _view_detach!(v.bar)
    _view_detach!(v.profiles_ax)
    Makie.trim!(v.plots)
    v.bar_shown && _view_attach!(v.plots, 2, 1, v.bar, v.expanded)
    v.profiles_shown && _view_attach!(v.plots, v.bar_shown ? 3 : 2, 1, v.profiles_ax, v.expanded)
    return nothing
end

# The switch of the `kinds`, of which `kind` is selected; none without kinds
function _show_switch!(v::_DetectorView, kinds::Tuple, kind)
    key = map(_kind_name, kinds)
    if key != v.switch_key
        # A new switch is built into the header, i.e. only while the expanded state is laid out;
        # a collapsed view gets it when it is expanded, see `_set_expanded!`
        (v.expanded || isempty(key) || haskey(v.switches, key)) || return nothing
        isnothing(v.switch) || _view_detach!(v.switch.grid)
        v.switch = isempty(key) ? nothing : get!(() -> _view_switch(v, kinds), v.switches, key)
        v.switch_key = key
        isnothing(v.switch) || _view_attach!(v.header, 1, 1, v.switch.grid, v.expanded)
    end
    _select_kind!(v.switch, kind)
    return nothing
end

_select_kind!(_, _) = nothing
_select_kind!(s::_Segmented, kind::_ViewKind) = _update!(s.selected, _kind_name(kind))

function _view_switch(v::_DetectorView, kinds::Tuple)
    options = Pair{Symbol, String}[_kind_name(k) => _kind_label(k) for k in kinds]
    s = _Segmented(v.header[1, 1], options; theme = v.theme, tellwidth = true)
    on(k -> v.refreshing || v.on_options(; kind = k), s.selected)
    return s
end

#=
Texts inside the frame of the axis
=#

function _text_size(v::_DetectorView, s::String)
    return get!(v.text_sizes, s) do
        w = Makie.widths(Makie.text_bb(s, v.font, _VIEW_FONTSIZE))
        Vec2f(w[1], w[2])
    end
end

function _view_ticks(lo::Real, hi::Real)
    values, labels = Makie.get_ticks(_VIEW_TICKS, identity, Makie.Automatic(), lo, hi)
    return Float64.(values), String.(labels)
end

_boxes_meet(a::Rect2f, b::Rect2f, gap) =
    all(minimum(a) .< maximum(b) .+ gap) && all(minimum(b) .< maximum(a) .+ gap)

"""
    _view_decorations(lims, size, measure, status) -> (; xpos, xtext, zpos, ztext, boxes)

The tick labels inside the frame of an axis with the limits `lims` and the `size` [px]: the
positions [data] and texts of the x labels at its bottom edge and of the z labels at its right
edge, and the pixel `boxes` in the frame of all texts, first those of the axis names in the bottom
left and the top right corner and of the `status` in the top left corner (if not empty).
`measure(text)` returns the size of a text [px]. A tick label that would stick out of the frame or
come closer than `_VIEW_LABEL_GAP` to a text placed before is left out.
"""
function _view_decorations(lims, size::Vec2f, measure, status::String)
    lo, w = Makie.origin(lims), Makie.widths(lims)
    W, H = size
    o = _VIEW_LABEL_OFFSET
    box(x, y, s) = Rect2f(x, y, s[1], s[2])
    sx, sz = measure("x [mm]"), measure("z [mm]")
    boxes = Rect2f[box(o.corner, o.x, sx), box(W - o.z - sz[1], H - o.corner - sz[2], sz)]
    if !isempty(status)
        s = measure(status)
        push!(boxes, box(o.corner, H - o.corner - s[2], s))
    end
    inside(b) = minimum(b)[1] >= 2 && minimum(b)[2] >= 2 && maximum(b)[1] <= W - 2 && maximum(b)[2] <= H - 2
    free(b) = inside(b) && !any(other -> _boxes_meet(b, other, _VIEW_LABEL_GAP), boxes)
    xpos, zpos = Makie.Point2d[], Makie.Point2d[]
    xtext, ztext = String[], String[]
    for (x, text) in zip(_view_ticks(lo[1], lo[1] + w[1])...)
        s = measure(text)
        b = box((x - lo[1]) / w[1] * W - s[1] / 2, o.x, s)
        free(b) || continue
        push!(boxes, b)
        push!(xpos, Makie.Point2d(x, lo[2]))
        push!(xtext, text)
    end
    for (z, text) in zip(_view_ticks(lo[2], lo[2] + w[2])...)
        s = measure(text)
        b = box(W - o.z - s[1], (z - lo[2]) / w[2] * H - s[2] / 2, s)
        free(b) || continue
        push!(boxes, b)
        push!(zpos, Makie.Point2d(lo[1] + w[1], z))
        push!(ztext, text)
    end
    return (; xpos, xtext, zpos, ztext, boxes)
end

"""
Places the texts inside the frame of the axis of the view `v` for its limits and its size, see
`_view_decorations`; without a kind, only the status is shown.
"""
function _update_decorations!(v::_DetectorView)
    lims = v.ax.finallimits[]
    size = Vec2f(Makie.widths(v.ax.scene.viewport[]))
    lo, w = Makie.origin(lims), Makie.widths(lims)
    (all(>(0), size) && all(x -> isfinite(x) && x > 0, w)) || return nothing
    top_left = [Makie.Point2d(lo[1], lo[2] + w[2])]
    Makie.update!(v.status; arg1 = top_left, text = [v.status_text])
    decorated = !isnothing(v.kind)
    Makie.update!(v.xname; arg1 = [Makie.Point2d(lo)], visible = decorated)
    Makie.update!(v.zname; arg1 = [Makie.Point2d(lo .+ w)], visible = decorated)
    if decorated
        d = _view_decorations(lims, size, s -> _text_size(v, s), v.status_text)
        Makie.update!(v.xlabels; arg1 = d.xpos, text = d.xtext)
        Makie.update!(v.zlabels; arg1 = d.zpos, text = d.ztext)
        v.boxes = d.boxes
    else
        Makie.update!(v.xlabels; arg1 = Makie.Point2d[], text = String[])
        Makie.update!(v.zlabels; arg1 = Makie.Point2d[], text = String[])
        v.boxes = Rect2f[]
    end
    return nothing
end

# Look of the axis per kind: white texts with a glow on the image of a field, whose frame has the
# lowest color of the colormap; the text color of the theme on the spots, whose background is the card
_kind_look(::_FieldKind, t) = (; text = RGBAf(1, 1, 1, 1), glow = 2.0, tick = RGBAf(1, 1, 1, 1),
    background = RGBAf(first(Makie.to_colormap(:viridis))))
_kind_look(::_SpotKind, t) = (; text = RGBAf(Makie.to_color(t.text)), glow = 0.0,
    tick = RGBAf(Makie.to_color(t.muted)), background = RGBAf(0, 0, 0, 0))

_is_field(::_FieldKind) = true
_is_field(_) = false

# The color of the background of the frames of the thumbnail and of the axis, see `_view_plots!`
_set_frames!(v::_DetectorView, color::RGBAf) =
    foreach(p -> Makie.update!(p; arg3 = fill(color, 1, 1)), v.frames)

# Shows the look and the controls of the `kind`; returns whether it is another kind than before
function _set_kind!(v::_DetectorView, kind::_ViewKind)
    v.kind == kind && return false
    v.kind = kind
    v.zoomed = false
    look = _kind_look(kind, v.theme)
    for p in (v.xlabels, v.zlabels, v.xname, v.zname, v.status)
        Makie.update!(p; color = look.text, glowwidth = look.glow)
    end
    _update!(v.ax.xtickcolor, look.tick)
    _update!(v.ax.ytickcolor, look.tick)
    Makie.update!(v.select_fill; color = RGBAf(look.text.r, look.text.g, look.text.b, _VIEW_SELECT_ALPHA))
    Makie.update!(v.select_line; color = look.text)
    _set_frames!(v, look.background)
    _show_field_controls!(v, _is_field(kind))
    return true
end

#=
Showing a result
=#

"""
    _show_result!(view, name::String, result::Union{Nothing, _ViewResult}, opts::_ViewOptions)

Shows the `result` of the detector with the `name` in the `view`, with the options `opts`:
the switch of its kinds, the plots of its kind in the thumbnail and in the axis, the metrics and
the state of the controls. The limits of a field are its window (`opts.window`, or the extent of
the data), those of a spot diagram are fitted to the spots unless the mouse changed them. Nothing
is updated if the result, the options and the name are those shown.
"""
function _show_result!(v::_DetectorView, name::String, result::Union{Nothing, _ViewResult},
        opts::_ViewOptions)
    (v.shown && v.result === result && v.opts == opts && v.name == name) && return nothing
    fresh = !v.shown || v.result !== result
    v.shown, v.name, v.result, v.opts = true, name, result, opts
    v.refreshing = true
    try
        _update!(v.log_toggle.active, opts.colorscale == :log)
        _update!(v.profiles_toggle.active, opts.profiles)
        _update!(v.bar_toggle.active, opts.colorbar)
        _draw!(v, result, opts, fresh)
    catch e
        v.last_error = _log_once(e, v.last_error, "detector view \"$name\"")
        _draw_empty!(v, "error")
    finally
        v.refreshing = false
    end
    return nothing
end

_draw!(v::_DetectorView, ::Nothing, _, _) = (_show_switch!(v, (), nothing); _draw_empty!(v, "no result"))
function _draw!(v::_DetectorView, r::_ViewResult, opts::_ViewOptions, fresh::Bool)
    _show_switch!(v, r.kinds, r.kind)
    _draw_data!(v, r.error, r, opts, fresh)
    return nothing
end

# A failed computation: logged once, the switch stays for another choice
function _draw_data!(v::_DetectorView, e, ::_ViewResult, _, _)
    v.last_error = _log_once(e, v.last_error, "detector view \"$(v.name)\"")
    _draw_empty!(v, "error")
    return nothing
end
function _draw_data!(v::_DetectorView, ::Nothing, r::_ViewResult, opts::_ViewOptions, fresh::Bool)
    v.last_error = nothing
    _draw_kind!(v, r.kind, r, opts, fresh)
    return nothing
end

_preview_text(r::_ViewResult) = (r.coarse || r.preview) ? "preview" : ""
_with_preview(s::String, r::_ViewResult) = (r.coarse || r.preview) ? s * " (preview)" : s

_draw_kind!(v::_DetectorView, ::Nothing, r::_ViewResult, _, _) = _draw_empty!(v, _with_preview("no hits", r))

function _draw_kind!(v::_DetectorView, kind::_SpotKind, r::_ViewResult, ::_ViewOptions, fresh::Bool)
    changed = _set_kind!(v, kind)
    if fresh || changed
        v.xy = [Point2f(1e3 * q[1], 1e3 * q[2]) for q in r.data]
        foreach(p -> Makie.update!(p; visible = false), v.images)
        foreach(p -> Makie.update!(p; arg1 = v.xy, visible = true), v.spots)
        _show_centroid!(v, r.metrics)
        _fit_spots!(v.thumb_ax, v.xy)
        v.zoomed || _fit_spots!(v.ax, v.xy)
    end
    _show_profiles!(v, false)
    _set_cuts!(v, nothing)
    _show_bar!(v, false)
    _show_texts!(v, kind, r)
    return nothing
end

function _draw_kind!(v::_DetectorView, kind::_FieldKind, r::_ViewResult, opts::_ViewOptions, fresh::Bool)
    changed = _set_kind!(v, kind)
    x, z, I = r.data
    scale = (opts.colorscale, opts.colorrange)
    if fresh || changed || scale != v.scale
        v.scale = scale
        values, range = _display_intensity(I, opts.colorscale)
        colorrange = Float32.(Tuple(something(opts.colorrange, range)))
        # The samples are the centers of the pixels of the image
        ex, ez = _pixel_edges(x), _pixel_edges(z)
        foreach(p -> Makie.update!(p; visible = false), v.spots)
        foreach(p -> Makie.update!(p; arg1 = ex, arg2 = ez, arg3 = Float32.(values), colorrange,
                visible = true), v.images)
        _set_bar!(v, kind, colorrange, opts.colorscale)
    end
    _show_bar!(v, opts.colorbar)
    v.extent = 1e3 .* (Float64(first(x)), Float64(last(x)), Float64(first(z)), Float64(last(z)))
    _view_limits!(v.thumb_ax, v.extent)
    _view_limits!(v.ax, _window_mm(opts.window, v.extent))
    _draw_profiles!(v, opts.profiles, x, z, I, r.metrics)
    _show_texts!(v, kind, r)
    return nothing
end

_window_mm(::Nothing, extent) = extent
_window_mm(w::NTuple{4, Float64}, _) = 1e3 .* w

#=
The colorbar of a field
=#

# SI prefixes of the unit of the colorbar (`factor => prefix`, from small to large)
const _BAR_PREFIXES = (1e-9 => "n", 1e-6 => "µ", 1e-3 => "m", 1.0 => "", 1e3 => "k", 1e6 => "M", 1e9 => "G")
const _SUPERSCRIPTS = ('⁰', '¹', '²', '³', '⁴', '⁵', '⁶', '⁷', '⁸', '⁹')

"""Returns the integer `k` in superscript digits, e.g. `"⁻²"`, for the label of a power of ten."""
_superscript(k::Integer) = join(c == '-' ? '⁻' : _SUPERSCRIPTS[c - '0' + 1] for c in string(k))

"""
    _bar_unit(kind) -> String
    _bar_prefix(kind, hi) -> Pair{Float64, String}

The unit of the values of the field `kind`: `W/m²` for the intensity, `rel.` for the PSF, which is
normalized to its maximum. `_bar_prefix` is the SI prefix (`factor => prefix`) with which the
linear colorbar shows values up to `hi`, such that its largest tick has two to four digits, e.g.
`1e3 => "k"` for 25000 W/m²; none for the PSF.
"""
_bar_unit(::_IntensityKind) = "W/m²"
_bar_unit(::_PSFKind) = "rel."
_bar_prefix(::_IntensityKind, hi::Real) =
    _BAR_PREFIXES[something(findlast(p -> 10 * first(p) <= hi, _BAR_PREFIXES), 1)]
_bar_prefix(::_PSFKind, _) = 1.0 => ""

"""
    _bar_scale(kind, colorrange, colorscale) -> (; limits, ticks, unit)

What the colorbar of the field `kind` shows for the `colorrange` of its image: its `limits`, its
`ticks` (an object for the `xticks` of an `Axis`) and its `unit`. On the linear scale, the limits
are the color range in the unit with the prefix of `_bar_prefix`. On the logarithmic scale, the
color range and the limits are `log10` of the values in the unit without a prefix, with ticks at
the powers of ten (at most about five, e.g. `10⁻²`); a range without a power of ten gets the values
themselves as tick labels.
"""
function _bar_scale(kind::_FieldKind, colorrange, colorscale::Symbol)
    lo, hi = Float64.(Tuple(colorrange))
    # A degenerate range has no limits
    hi > lo || (hi = lo + 1)
    unit = _bar_unit(kind)
    if colorscale == :linear
        factor, prefix = _bar_prefix(kind, max(abs(lo), abs(hi)))
        return (; limits = (lo / factor, hi / factor), ticks = _VIEW_BAR_TICKS, unit = prefix * unit)
    end
    k0, k1 = ceil(Int, lo - 1e-9), floor(Int, hi + 1e-9)
    if k0 <= k1
        decades = collect(k0:max(1, cld(k1 - k0 + 1, 5)):k1)
        return (; limits = (lo, hi), ticks = (Float64.(decades), ["10" * _superscript(k) for k in decades]), unit)
    end
    values = Makie.get_tickvalues(_VIEW_BAR_TICKS, lo, hi)
    return (; limits = (lo, hi), ticks = (values, [_fmt_sigdigits(10.0^x) for x in values]), unit)
end

"""
    _set_bar!(view, kind, colorrange, colorscale)

Shows the `colorrange` of the image of the field `kind` in the colorbar of the `view`, see
`_bar_scale`: the colormap spans its limits, i.e. the bar looks the same for every range and only
its ticks and its unit change.
"""
function _set_bar!(v::_DetectorView, kind::_FieldKind, colorrange, colorscale::Symbol)
    s = _bar_scale(kind, colorrange, colorscale)
    lo, hi = s.limits
    Makie.update!(v.bar_image; arg1 = (lo, hi))
    v.bar_ax.xticks[] = s.ticks
    limits!(v.bar_ax, lo, hi, 0, 1)
    _update!(v.bar_unit.text, s.unit)
    return nothing
end

# Edges [mm] of the image of a field with the samples `x` [m]
function _pixel_edges(x)
    lo, hi = 1e3 * Float64(first(x)), 1e3 * Float64(last(x))
    h = length(x) > 1 ? (hi - lo) / (length(x) - 1) / 2 : 0.5e-3
    return (lo - h, hi + h)
end

# The red cross at the centroid of the metrics `m` in the thumbnail and in the axis, if `shown`
function _show_centroid!(v::_DetectorView, m, shown::Bool = true)
    c = shown && isfinite(m.cx) ? [Point2f(1e3 * m.cx, 1e3 * m.cz)] : Point2f[]
    foreach(p -> Makie.update!(p; arg1 = c), v.crosses)
    return nothing
end

"""
    _set_cuts!(view, c)

Shows the lines of the two cuts of the profiles through the point `c` [mm] in the axis of the
`view`, or none for `nothing`: dashed and half transparent, the one along x in the color of the profile along x, the one
along z in that of the profile along z. They span the shown limits and follow them.
"""
function _set_cuts!(v::_DetectorView, c::Union{Nothing, Point2f})
    v.cut = c
    _update_cuts!(v)
    return nothing
end

_update_cuts!(v::_DetectorView) = _update_cuts!(v, v.cut)
function _update_cuts!(v::_DetectorView, ::Nothing)
    isempty(v.cut_x[1][]) && return nothing
    foreach(p -> Makie.update!(p; arg1 = Point2f[]), (v.cut_x, v.cut_z))
    return nothing
end
function _update_cuts!(v::_DetectorView, c::Point2f)
    x0, x1, z0, z1 = _shown_limits(v.ax)
    Makie.update!(v.cut_x; arg1 = [Point2f(x0, c[2]), Point2f(x1, c[2])])
    Makie.update!(v.cut_z; arg1 = [Point2f(c[1], z0), Point2f(c[1], z1)])
    return nothing
end

function _show_texts!(v::_DetectorView, kind::_ViewKind, r::_ViewResult)
    _update!(v.kind_label.text, _with_preview(_kind_label(kind), r))
    _update!(v.info_label.text, _thumb_text(kind, r.metrics))
    _update!(v.metrics_label.text, _metrics_text(kind, r.metrics))
    _set_status!(v, _preview_text(r))
    return nothing
end

function _set_status!(v::_DetectorView, text::String)
    v.status_text = text
    _update_decorations!(v)
    return nothing
end

# No plots and the `message` in place of the kind and the metrics, e.g. without hits
function _draw_empty!(v::_DetectorView, message::String)
    v.kind = nothing
    v.scale = nothing
    v.zoomed = false
    v.xy = Point2f[]
    _set_frames!(v, RGBAf(0, 0, 0, 0))
    foreach(p -> Makie.update!(p; visible = false), v.images)
    foreach(p -> Makie.update!(p; arg1 = Point2f[], visible = false), v.spots)
    foreach(p -> Makie.update!(p; arg1 = Point2f[]), v.crosses)
    _show_profiles!(v, false)
    _set_cuts!(v, nothing)
    _show_bar!(v, false)
    _show_field_controls!(v, false)
    _update!(v.kind_label.text, message)
    _update!(v.info_label.text, "")
    _update!(v.metrics_label.text, message)
    _set_status!(v, message)
    return nothing
end

# The intensity along x and z through the centroid of the metrics `m`, see `_ViewOptions`: the
# profiles below the axis, and in the image the centroid and the lines of the two cuts
function _draw_profiles!(v::_DetectorView, shown::Bool, x, z, I, m)
    shown = shown && isfinite(m.cx)
    _show_centroid!(v, m, shown)
    _set_cuts!(v, shown ? Point2f(1e3 * m.cx, 1e3 * m.cz) : nothing)
    if !shown
        _show_profiles!(v, false)
        return nothing
    end
    i, j = argmin(abs.(x .- m.cx)), argmin(abs.(z .- m.cz))
    Makie.update!(v.profile_x; arg1 = [Point2f(1e3 * x[k], I[k, j]) for k in eachindex(x)])
    Makie.update!(v.profile_z; arg1 = [Point2f(1e3 * z[k], I[i, k]) for k in eachindex(z)])
    autolimits!(v.profiles_ax)
    _show_profiles!(v, true)
    return nothing
end

#=
Limits: zoom, pan and fit
=#

# The limits `(x_min, x_max, z_min, z_max)` [mm] of the axis `ax`, as shown
function _shown_limits(ax::Axis)
    lo, w = Makie.origin(ax.finallimits[]), Makie.widths(ax.finallimits[])
    return (Float64(lo[1]), Float64(lo[1] + w[1]), Float64(lo[2]), Float64(lo[2] + w[2]))
end

# Sets the limits [mm] of `ax`, unless it shows them
function _view_limits!(ax::Axis, lims::NTuple{4, Float64})
    (lims[2] > lims[1] && lims[4] > lims[3]) || return nothing
    tol = 1e-9 * max(lims[2] - lims[1], lims[4] - lims[3])
    all(abs.(_shown_limits(ax) .- lims) .<= tol) || limits!(ax, lims...)
    return nothing
end

function _fit_spots!(ax::Axis, xy)
    autolimits!(ax)
    _pad_degenerate_limits!(ax, xy)
    return nothing
end

# The limits of the axis were changed by the mouse: a field is computed again for this window by
# the host, a spot diagram keeps them
_limits_changed!(::_DetectorView, ::Nothing) = nothing
_limits_changed!(v::_DetectorView, ::_SpotKind) = (v.zoomed = true; nothing)
_limits_changed!(v::_DetectorView, ::_FieldKind) = (v.on_options(; window = 1e-3 .* _shown_limits(v.ax)); nothing)

"""Shows all of the result in the view `v` again: the spots, or the field in its automatic window."""
function _fit!(v::_DetectorView)
    v.zoomed = false
    v.drag = nothing
    _end_selection!(v)
    _fit_kind!(v, v.kind)
    return nothing
end
_fit_kind!(::_DetectorView, ::Nothing) = nothing
_fit_kind!(v::_DetectorView, ::_SpotKind) = _fit_spots!(v.ax, v.xy)
function _fit_kind!(v::_DetectorView, ::_FieldKind)
    _view_limits!(v.ax, v.extent)
    isnothing(v.opts.window) || v.on_options(; window = nothing)
    return nothing
end

# Zooms the axis by the `factor` about the figure pixel `p`
function _zoom!(v::_DetectorView, p::Point2f, factor::Real)
    vp = v.ax.scene.viewport[]
    x0, x1, z0, z1 = _shown_limits(v.ax)
    rx, rz = (p .- Makie.origin(vp)) ./ Makie.widths(vp)
    cx, cz = x0 + rx * (x1 - x0), z0 + rz * (z1 - z0)
    _zoom_to!(v, (cx - (cx - x0) * factor, cx + (x1 - cx) * factor, cz - (cz - z0) * factor, cz + (z1 - cz) * factor))
    return nothing
end

# Shows the limits `lims` [mm] in the axis, unless they are too small
function _zoom_to!(v::_DetectorView, lims::NTuple{4, Float64})
    (lims[2] - lims[1] > 1e-9 && lims[4] - lims[3] > 1e-9) || return nothing
    limits!(v.ax, lims...)
    _limits_changed!(v, v.kind)
    return nothing
end

#=
The limits [mm] of the zoom selection from its start to the figure pixel `p`. The scales of the
axis are equal, such that only limits of the shape of its frame can be shown (a square for a
square frame, like the grid of a field): the larger side of the drag sets the size of the
selection, the other one follows from the shape of the frame.
=#
function _selection(v::_DetectorView, p::Point2f)
    vp = v.ax.scene.viewport[]
    start, size = Makie.Point2d(v.select), Makie.Vec2d(Makie.widths(vp))
    d = (Makie.Point2d(p) .- start) ./ size
    a = (start .- Makie.Point2d(Makie.origin(vp))) ./ size
    b = a .+ maximum(abs, d) .* map(x -> x < 0 ? -1.0 : 1.0, d)
    x0, x1, z0, z1 = _shown_limits(v.ax)
    xa, xb = x0 + a[1] * (x1 - x0), x0 + b[1] * (x1 - x0)
    za, zb = z0 + a[2] * (z1 - z0), z0 + b[2] * (z1 - z0)
    return (min(xa, xb), max(xa, xb), min(za, zb), max(za, zb))
end

# Draws the rectangle of the zoom selection up to the figure pixel `p`
function _show_selection!(v::_DetectorView, p::Point2f)
    x0, x1, z0, z1 = _selection(v, p)
    Makie.update!(v.select_fill; arg1 = Rect2f(x0, z0, x1 - x0, z1 - z0), visible = true)
    Makie.update!(v.select_line; visible = true,
        arg1 = Point2f[(x0, z0), (x1, z0), (x1, z1), (x0, z1), (x0, z0)])
    return nothing
end

function _end_selection!(v::_DetectorView)
    v.select = nothing
    foreach(q -> Makie.update!(q; visible = false), (v.select_fill, v.select_line))
    return nothing
end

# Moves the limits of the drag with the mouse at the figure pixel `p`
function _pan!(v::_DetectorView, p::Point2f)
    p0, (x0, x1, z0, z1) = v.drag
    size = Makie.widths(v.ax.scene.viewport[])
    dx, dz = (p[1] - p0[1]) / size[1] * (x1 - x0), (p[2] - p0[2]) / size[2] * (z1 - z0)
    limits!(v.ax, x0 - dx, x1 - dx, z0 - dz, z1 - dz)
    return nothing
end

"""
    _connect_view!(view, events; on_options, on_expanded, priority = 2) -> listeners

Connects the `view` to its host: `on_options(; kind)`, `on_options(; colorscale)`,
`on_options(; profiles)` or `on_options(; window)` is called with the option that the user changed
(the switch, the toggles, zoom, pan and "fit"; `window` in [m], `nothing` for the automatic one),
`on_expanded(::Bool)` by the chevrons and a click on the thumbnail. The mouse is taken from the
`events` of the figure with listeners of the `priority`, which are returned. Over the axis of the
expanded view it acts like on an `Axis` of Makie, all consumed: the wheel zooms about the cursor,
a drag with the left button selects the rectangle to zoom to (of the shape of the frame, see
`_selection`), a drag with the right button pans, and Ctrl + click or a double click fits the
view. A click on the thumbnail expands the view. Elsewhere, and over a thumbnail for the wheel,
the events pass.
"""
function _connect_view!(v::_DetectorView, events; on_options, on_expanded, priority = 2)
    foreach(off, v.listeners)
    empty!(v.listeners)
    v.on_options, v.on_expanded = on_options, on_expanded
    push!(v.listeners,
        on(e -> _on_scroll!(v, events, e), events.scroll; priority),
        on(e -> _on_button!(v, events, e), events.mousebutton; priority),
        on(p -> _on_move!(v, Point2f(p)), events.mouseposition; priority))
    return copy(v.listeners)
end

function _on_scroll!(v::_DetectorView, events, (_, dy))
    p = Point2f(events.mouseposition[])
    (_over_axis(v, p) && !isnothing(v.kind)) || return Consume(false)
    iszero(dy) || _zoom!(v, p, (1 - _VIEW_ZOOM_SPEED)^dy)
    return Consume(true)
end

function _on_button!(v::_DetectorView, events, e)
    p, press = Point2f(events.mouseposition[]), Val(e.action == Mouse.press)
    e.button == Mouse.left && return _on_left!(v, p, press, _ctrl_held(events))
    e.button == Mouse.right && return _on_right!(v, p, press)
    return Consume(false)
end

_ctrl_held(events) = Keyboard.left_control in events.keyboardstate ||
                     Keyboard.right_control in events.keyboardstate

function _on_left!(v::_DetectorView, p::Point2f, ::Val{true}, ctrl::Bool)
    if _over_thumb(v, p)
        v.thumb_pressed = true
        return Consume(true)
    end
    (_over_axis(v, p) && !isnothing(v.kind)) || return Consume(false)
    # the right button pans
    isnothing(v.drag) || return Consume(true)
    now = time()
    if ctrl || (now - v.last_press < _VIEW_DOUBLE_CLICK && norm(p - v.press_position) < 4)
        v.last_press = 0.0
        _fit!(v)
        return Consume(true)
    end
    v.last_press, v.press_position = now, p
    v.select = p
    return Consume(true)
end

function _on_left!(v::_DetectorView, p::Point2f, ::Val{false}, ::Bool)
    if !isnothing(v.select)
        selected = maximum(abs, p - v.select) >= _VIEW_SELECT_MIN
        lims = _selection(v, p)
        _end_selection!(v)
        selected && _zoom_to!(v, lims)
        return Consume(true)
    elseif v.thumb_pressed
        v.thumb_pressed = false
        _over_thumb(v, p) && v.on_expanded(true)
        return Consume(true)
    end
    return Consume(false)
end

function _on_right!(v::_DetectorView, p::Point2f, ::Val{true})
    (_over_axis(v, p) && !isnothing(v.kind)) || return Consume(false)
    # the left button selects
    isnothing(v.select) || return Consume(true)
    v.drag, v.dragged = (p, _shown_limits(v.ax)), false
    return Consume(true)
end

function _on_right!(v::_DetectorView, ::Point2f, ::Val{false})
    isnothing(v.drag) && return Consume(false)
    v.drag = nothing
    v.dragged && _limits_changed!(v, v.kind)
    return Consume(true)
end

function _on_move!(v::_DetectorView, p::Point2f)
    if !isnothing(v.select)
        _show_selection!(v, p)
        return Consume(true)
    end
    isnothing(v.drag) && return Consume(false)
    (v.dragged || norm(p - first(v.drag)) > 2) || return Consume(true)
    v.dragged = true
    _pan!(v, p)
    return Consume(true)
end

"""Removes the view `v` from its host: its listeners, its blocks and its layouts."""
function _delete_view!(v::_DetectorView)
    foreach(off, v.listeners)
    empty!(v.listeners)
    v.on_options, v.on_expanded = _no_options, _no_expanded
    blocks = Any[]
    for part in (v.thumb, v.full, v.field_controls, v.profiles_ax, (s.grid for s in values(v.switches))...)
        _blocks!(blocks, part)
    end
    foreach(delete!, unique!(objectid, blocks))
    for layout in (v.thumb, v.full)
        content = Makie.GridLayoutBase.gridcontent(layout)
        isnothing(content) || Makie.GridLayoutBase.remove_from_gridlayout!(content)
    end
    empty!(v.switches)
    v.switch, v.switch_key = nothing, ()
    return nothing
end
