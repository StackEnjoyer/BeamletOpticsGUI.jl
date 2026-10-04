#=
Declarations of the cards, see `card_rows` and `card_actions`
=#

# Labels of the pose rows, see `_POSE_FIELDS`, the units are given at the end of the rows, and the
# names of their boxes
const _CARD_POSE_LABELS = ("x", "y", "z", "rx", "ry", "rv")
const _CARD_POSE_NAMES = (:x, :y, :z, :rx, :ry, :rv)

# Label of the pose box `k`, of the same width in both rows, such that the boxes line up
# (the positions in the text color of the card, the rotations in the colors of the axes, see
# `_AxisColor`)
_pose_label(k::Int) = CardWidget(Label; text = _CARD_POSE_LABELS[k], width = 18, halign = :right,
    _pose_label_color(k)...)
_pose_label_color(k::Int) = k <= 3 ? (;) : (; color = _AxisColor(k - 3))

# Pose box `k`: the position [mm] (wide enough for e.g. -6869.709 of a telescope, longer values
# scroll while typing) or an empty rotation box, see `_apply_pose_input!`
_pose_box(k::Int) = CardWidget(Textbox; name = _CARD_POSE_NAMES[k], placeholder = k <= 3 ? " " : "0",
    width = 76, value = (gui, obj) -> k <= 3 ? string(round(1e3 * position(obj)[k], digits = 6)) : "",
    on = (gui, obj, s) -> _apply_pose_input!(gui, obj, k, s))

function pose_card_rows(obj)
    cells(ks, unit) = (Iterators.flatten((_pose_label(k), _pose_box(k)) for k in ks)..., unit)
    return (CardRow(cells(1:3, "mm")...), CardRow(cells(4:6, "mrad")...))
end

# A row of a label `label` (`width` pixels wide) and a text of the object, `text(gui, obj)`,
# refreshed after moves and solves
_text_row(label::String, name::Symbol, text; width::Real = 40) =
    CardRow(CardWidget(Label; text = label, width, halign = :left),
        CardWidget(Label; name, halign = :left, value = text))

#=
Rows of the component families, below the pose rows
=#

# Clip planes and any other movable object: the pose
card_rows(obj) = pose_card_rows(obj)
# Optical components and groups: the pose and the beams that hit them, see `_beam_text`
card_rows(obj::BMO.AbstractObject) = (pose_card_rows(obj)..., _beam_row())
# Lenses and prisms: the refractive index at the wavelength of the beam and the center thickness
card_rows(l::BMO.AbstractRefractiveOptic) = (pose_card_rows(l)..., _beam_row(),
    _text_row("n", :index, _index_text), _thickness_rows(l)...)
# Beamsplitters: the splitting ratio of the coating
card_rows(bs::BMO.AbstractBeamsplitter) = (pose_card_rows(bs)..., _beam_row(),
    _text_row("split", :split, (gui, bs) -> _split_text(_coating(bs))))
# Polarizers: the transmission axis
card_rows(p::Union{BMO.LinearPolarizer, BMO.PolarizationFilter}) =
    (pose_card_rows(p)..., _beam_row(), _text_row("axis", :axis, _axis_text))
# Detectors: the hits of the last solve, the power, or the number of rays, of the view of the
# detector; the view itself is on the page "Results" of the card, see `_has_view`
card_rows(pd::BMO.Detector) = (pose_card_rows(pd)..., _beam_row(), _text_row("signal", :signal, _signal_text))
# Beams and beam groups: switched on and off, their polarization, see `beam_card_rows`
card_rows(b::Union{BMO.AbstractBeam, BMO.AbstractBeamGroup}) = (pose_card_rows(b)..., beam_card_rows(b)...)
# Sources whose rays can be regenerated: wavelength, size and a slider for the number of rays
card_rows(src::Union{BMO.CollimatedSource, BMO.PointSource}) = (pose_card_rows(src)...,
    _text_row("λ", :source, _source_text), beam_card_rows(src)...,
    _ray_rows(BMO.min_num_rays(src), length(src))...)
# Gaussian beamlets: wavelength, waist and Rayleigh range
card_rows(g::BMO.GaussianBeamlet) = (pose_card_rows(g)..., _text_row("λ", :gauss, _gauss_text),
    beam_card_rows(g)...)
# Systems (inspected, see `_inspect!`): no pose, the number of objects, the rays of their sources and
# the duration of the last solve
card_rows(::BMO.AbstractSystem) = (_text_row("objects", :objects, _objects_text; width = 48),
    _text_row("rays", :rays, _rays_text; width = 48), _text_row("solve", :solve, _solve_text; width = 48))

card_actions(obj) = (CardWidget(Button; name = :hide, label = "hide",
    value = (gui, o) -> _all_hidden(gui, o) ? "show" : "hide", on = (gui, o, _) -> _toggle_hidden!(gui, o)),)

# The button "remove" of a component or a source, in the last row of its card (see `_card_rows`):
# removes a top-level object of a `System` or a source from the view (see `remove_component!`) and
# names the reason in the status line for any other object, e.g. an object of a group or an extra
_remove_button() = CardWidget(Button; name = :remove, label = "remove",
    on = (gui, o, _) -> _remove_selected!(gui, o))

# Systems: also "new window", which opens the system in a window of its own, see `open_system`
card_actions(sys::BMO.AbstractSystem) = (invoke(card_actions, Tuple{Any}, sys)...,
    CardWidget(Button; name = :open, label = "new window", on = (gui, s, _) -> _open_system!(gui, s)))

card_actions(::LiveClipPlane) = (
    CardWidget(Button; name = :flip, label = "flip", on = (gui, p, _) -> _flip_clip_plane!(gui, p)),
    CardWidget(Button; name = :remove, label = "remove", on = (gui, p, _) -> _remove_clip_plane!(gui, p)))

#=
Beams of the last solve that hit an object
=#

"""
    _hits(gui, obj) -> Vector{AbstractRay}

The rays of all beams of the `gui` that hit the object `obj` in the last solve: its rendered objects
(the leaves of a group) and their parts (e.g. the prisms and the coating of a cube beamsplitter),
see `intersection`. Of Gaussian beamlets, the chief rays.
"""
function _hits(gui::LiveView, obj)
    targets = Base.IdSet{Any}()
    foreach(leaf -> foreach(p -> push!(targets, p), _parts(leaf, BMO.shape_trait_of(leaf))), _leaves(obj))
    rs = BMO.AbstractRay[]
    foreach(((_, beam),) -> _collect_hits!(rs, beam, targets), gui.pairs)
    return rs
end

# An object and the objects it consists of, which the intersections may name
_parts(obj, ::BMO.SingleShape) = (obj,)
_parts(obj, ::BMO.MultiShape) = (obj, BMO.shape(obj)...)
_parts(obj, _) = (obj,)

# All branches of a beam, e.g. behind a beamsplitter (the children of the beam tree)
_collect_hits!(rs, bg::BMO.AbstractBeamGroup, targets) = foreach(b -> _collect_hits!(rs, b, targets), BMO.beams(bg))
_collect_hits!(rs, beam::BMO.Beam, targets) = foreach(b -> _node_hits!(rs, b, targets), PreOrderDFS(beam))
_collect_hits!(rs, g::BMO.GaussianBeamlet, targets) = foreach(b -> _node_hits!(rs, b.chief, targets), PreOrderDFS(g))
_collect_hits!(rs, g::BMO.AstigmaticGaussianBeamlet, targets) = foreach(b -> _node_hits!(rs, b.c, targets), PreOrderDFS(g))
_collect_hits!(rs, _, _) = rs

# The rays of one branch of a beam that hit one of the `targets`
function _node_hits!(rs, beam::BMO.Beam, targets)
    for ray in BMO.rays(beam)
        _hit_object(BMO.intersection(ray)) in targets && push!(rs, ray)
    end
    return rs
end

_hit_object(::Nothing) = nothing
_hit_object(isect::BMO.Intersection) = BMO.object(isect)

"""Angle of incidence of the `ray` on the surface it hits [°], between 0 and 90°."""
function _incidence(ray)
    θ = rad2deg(BMO.angle3d(ray))
    return min(θ, 180 - θ)
end

_deg_string(θ) = "$(round(θ; digits = 1))°"

# A wavelength [m] in nm, e.g. 633 nm or 632.8 nm
function _wavelength_string(λ)
    x = round(1e9 * λ; digits = 1)
    return isinteger(x) ? "$(Int(x)) nm" : "$x nm"
end

"""
    _beam_text(gui, obj)

The rays that hit `obj` in the last solve and the angle of incidence of the first one, i.e. the
center ray of a ring source, with the range of all of them, e.g. `12 rays, AOI 45.0° (44.1–45.9°)`,
or "not hit".
"""
function _beam_text(gui::LiveView, obj)
    rs = _hits(gui, obj)
    isempty(rs) && return "not hit"
    θ = map(_incidence, rs)
    n = length(rs) == 1 ? "1 ray" : "$(length(rs)) rays"
    spread = length(rs) == 1 ? "" : " ($(round(minimum(θ); digits = 1))–$(_deg_string(maximum(θ))))"
    return "$n, AOI $(_deg_string(first(θ)))$spread"
end

_beam_row() = _text_row("beam", :beam, _beam_text)

#=
Values of the families
=#

# Wavelength of the first ray of a beam, see `_live_wavelength`
_first_ray(bg::BMO.AbstractBeamGroup) = _first_ray(first(BMO.beams(bg)))
_first_ray(g::BMO.GaussianBeamlet) = _first_ray(g.chief)
_first_ray(g::BMO.AstigmaticGaussianBeamlet) = _first_ray(g.c)
_first_ray(beam::BMO.Beam) = first(BMO.rays(beam))

"""
The wavelength of the first ray hitting `obj`, or of the first beam of the `gui` [m]; 1000 nm, the
default of BeamletOptics, in a view without a source.
"""
function _live_wavelength(gui::LiveView, obj)
    rs = _hits(gui, obj)
    isempty(rs) || return BMO.wavelength(first(rs))
    return isempty(gui.pairs) ? 1.0e-6 : BMO.wavelength(_first_ray(last(first(gui.pairs))))
end

function _index_text(gui::LiveView, l)
    λ = _live_wavelength(gui, l)
    return "$(round(BMO.refractive_index(l, λ); digits = 4)) at $(_wavelength_string(λ))"
end

_thickness_rows(l::BMO.Lens) = (_text_row("d", :thickness, (gui, l) -> _length_string(BMO.thickness(l))),)
_thickness_rows(_) = ()

_coating(bs::BMO.ThinBeamsplitter) = bs
_coating(bs::Union{BMO.CubeBeamsplitter, BMO.AbstractPlateBeamsplitter}) = bs.coating
# The coating stores amplitude factors, the ratio is given in power
_split_text(c::BMO.ThinBeamsplitter) =
    "R $(round(100 * abs2(BMO.reflectance(c)); digits = 1)) %, T $(round(100 * abs2(BMO.transmittance(c)); digits = 1)) %"

"""
The transmission axis of the polarizer `p` as angle about its optical axis `n` (the local y-axis)
from the horizontal, i.e. from `n × z` (global z up), in [0°, 180°): 0° horizontal, 90° vertical.
For a vertical optical axis, the reference is the global x-axis.
"""
function _axis_text(gui::LiveView, p)
    a = Vector{Float64}(BMO.transmission_axis(p))
    n = Vector{Float64}(BMO.orientation(p)[:, 2])
    h = cross(n, [0.0, 0, 1])
    norm(h) < 1e-9 && (h = [1.0, 0, 0] - n[1] * n)
    h = normalize(h)
    return _deg_string(mod(atand(dot(a, cross(h, n)), dot(a, h)), 180)) * " from horizontal"
end

"""
The signal of the detector `pd` on its card: the power of a field view or the number of rays of a
spot view, from the metrics of its view if it was computed for the hits of the last solve (i.e.
while a view of `pd` is shown, see `_shown_views`), otherwise the number of its hits.
"""
function _signal_text(gui::LiveView, pd)
    state = get(gui.detectors.states, pd, nothing)
    (isnothing(state) || state.stale || isnothing(state.result)) && return _hits_text(pd)
    return _signal_metric(state.result.metrics, pd)
end
_signal_metric(m::NamedTuple, pd) = haskey(m, :P) ? "P = $(_fmt3(1e3 * m.P)) mW" :
                                    haskey(m, :n) ? "N = $(m.n)" : _hits_text(pd)
_signal_metric(_, pd) = _hits_text(pd)

_hits_text(pd) = (n = BMO.hit_count(pd); iszero(n) ? "no hits" : n == 1 ? "1 hit" : "$n hits")

_source_text(gui::LiveView, src) = "$(_wavelength_string(BMO.wavelength(src))), $(_size_text(src))"
_size_text(cs::BMO.CollimatedSource) = "⌀ $(_length_string(cs.diameter))"
_size_text(ps::BMO.PointSource) = "NA $(round(BMO.numerical_aperture(ps); digits = 3))"

# The rendered objects of a system, see `_leaves`
_objects_text(::LiveView, sys) = string(length(_leaves(sys)))
# The rays of the sources of a system (or beams of a beam group) that are switched on, as in the
# info label, see `_on_ray_count`
_rays_text(gui::LiveView, sys) = string(_on_ray_count(gui, filter(p -> p.first === sys, gui.pairs)))
# The duration of the last full solve of all systems
_solve_text(gui::LiveView, _) = gui.trace.solve_time > 0 ? _ms_string(gui.trace.solve_time) : "–"

_gauss_text(gui::LiveView, g) ="$(_wavelength_string(BMO.wavelength(_first_ray(g)))), w0 " *
    "$(_length_string(BMO.beam_waist(g))), zR $(_length_string(BMO.rayleigh_range(g)))"

#=
Beams switched on and off and their polarization, see `_set_beam_on!` and `_set_polarization!`
=#

function beam_card_rows(b)
    on = CardWidget(Toggle; name = :beam_on, value = (gui, b) -> _beam_on(gui, b),
        on = (gui, b, v) -> _set_beam_on!(gui, b, v))
    gen = _has_generating_beams(b) ? (CardWidget(Toggle; name = :show_beams,
        value = (gui, b) -> _generating_beams_on(gui, b),
        on = (gui, b, v) -> _set_generating_beams!(gui, b, v)), "beams") : ()
    _polarizable(b) || return (CardRow("beam", on, "on", gen...), _flen_row())
    pol = CardWidget(Toggle; name = :polarization, value = (gui, b) -> _polarization_on(gui, b),
        on = (gui, b, v) -> _set_polarization!(gui, b, v))
    return (CardRow("beam", on, "on", gen..., pol, "polarization"),
        _pol_slider_row("pol λ", :pol_wavelength, :λ), _pol_slider_row("pol amp", :pol_amplitude, :amp),
        _flen_row())
end

# The length with which the final rays of a beam are drawn [mm], see `_set_flen!`
_flen_row() = CardRow(CardWidget(Label; text = "length", width = 48, halign = :left),
    CardWidget(Textbox; name = :flen, placeholder = " ", width = 76,
        value = (gui, b) -> _flen_string(gui, b), on = (gui, b, s) -> _apply_flen_input!(gui, b, s)),
    "mm")

# A slider of the polarization curve, see `_pol_view`: over 0…1, mapped logarithmically to the
# range of the value `key`, which is shown as text next to it
_pol_slider_row(label::String, name::Symbol, key::Symbol) = CardRow(
    CardWidget(Label; text = label, width = 48, halign = :left),
    CardWidget(Slider; name, range = 0:0.005:1, width = 140,
        value = (gui, b) -> _pol_position(gui, b, key), on = (gui, b, u) -> _set_pol_position!(gui, b, key, u)),
    CardWidget(Label; name = Symbol(name, :_text), width = 64, halign = :left,
        value = (gui, b) -> _pol_text(gui, b, key)))

#=
Ray count slider of the sources
=#

# A source whose rays can not be regenerated has no slider, see `BMO.min_num_rays`
_ray_rows(::Nothing, ::Int) = ()
# The slider starts at the fewest rays of the source, at least 10
_ray_rows(lo::Int, n::Int) = (CardRow(
    CardWidget(Label; name = :ray_count, width = 80, halign = :left, value = (gui, src) -> "$(length(src)) rays"),
    CardWidget(Slider; name = :rays, range = _ray_steps(max(lo, 10), n), width = 200,
        value = (gui, src) -> length(src), on = (gui, src, n) -> _set_num_rays!(gui, src, n))),)

"""Values of the ray slider: the steps 1-2-5 from `lo` up to 20 000, `lo` itself and the current count `n`."""
function _ray_steps(lo::Int, n::Int)
    steps = [m * 10^e for e in 1:4 for m in (1, 2, 5)]
    return sort!(unique!([lo; n; filter(s -> lo < s <= 20_000, steps)]))
end

"""
    _set_num_rays!(gui, src, n)

Regenerates the rays of the source `src` of the `gui` with `n` rays (see `BeamletOptics.set_num_rays!`),
a change of the source (a running solve is cancelled first, see `_change!`), and solves again or
marks the beams as outdated like after a move, via the `on_change` of the controls. The slider
snaps to its steps, hence `n` may be the current count.
"""
function _set_num_rays!(gui::LiveView, src, n)
    n = round(Int, n)
    length(src) == n && return nothing
    _change!(() -> set_num_rays!(src, n), gui.controls, src)
    gui.controls.on_change(src)
    return nothing
end

#=
Parts of groups and multi-shape objects, one level at a time, see the selection card (`_browse!`)
=#

"""
    _part_children(x) -> Tuple

The direct parts of `x` on the selection card (see `_browse!`): of a `MultiShape` object, e.g. a
group, a doublet or a cube beamsplitter, the elements of `BeamletOptics.shape(x)` that are objects,
in their order (beams and bare shapes are left out); none of a `SingleShape` object or of anything
else, e.g. a beam or a clip plane.
"""
_part_children(x::BMO.AbstractObject) = _part_children(x, BMO.shape_trait_of(x))
_part_children(_) = ()
_part_children(x, ::BMO.MultiShape) = Tuple(c for c in BMO.shape(x) if c isa BMO.AbstractObject)
_part_children(_, ::BMO.AbstractShapeTrait) = ()

"""Returns the object whose part `x` is in the `gui` (see `_map_parts!`), `nothing` at the top level."""
_part_parent(gui::LiveView, x) = get(gui.objects.parents, x, nothing)

"""
    _map_parts!(gui)

Maps each part of the top-level objects of the systems and the extras of the `gui` to the object it
is a part of, recursively (see `_part_children` and `_part_parent`), and names the parts without a
label and a name by their type and a running index, like `_name_objects!`, e.g. the lenses of a
doublet. Called when the view is built and after a component was added, see `add_component!`;
entries, once made, are kept.
"""
function _map_parts!(gui::LiveView)
    state = gui.objects
    function walk!(x)
        for c in _part_children(x)
            state.parents[c] = x
            if !haskey(gui.labels, c) && !haskey(state.names, c)
                base = string(nameof(typeof(c)))
                n = state.counters[base] = get(state.counters, base, 0) + 1
                state.names[c] = "$base $n"
            end
            walk!(c)
        end
        return nothing
    end
    for h in (gui.system_handles..., gui.extras), top in _top_levels(h)
        walk!(top)
    end
    return nothing
end

"""
    _anchor_part_card!(gui, part)

Places the card of the selection of the `gui`, which shows the inspected `part`, at the bounding box
of the plots of `part`, or, without plots of its own (e.g. a lens of a doublet, whose plots belong
to the doublet), of the nearest object that it is a part of, see `_plotted_part`.
"""
function _anchor_part_card!(gui::LiveView, part)
    ctrl = gui.controls
    x = _plotted_part(gui, part)
    isnothing(x) && return nothing
    c = gui.cards.selection
    c.corners = _box_corners(_selection_bbox(ctrl, x, _object_plots(ctrl.h, x)))
    c.key = (part, _card_pose(part))
    _update_cards!(gui)
    return nothing
end

"""
Returns `part` if it has plots in the `gui`, else the nearest object that it is a part of with plots
(see `_part_parent`), e.g. the doublet of a lens, or `nothing`.
"""
function _plotted_part(gui::LiveView, part)
    x = part
    while !isnothing(x) && isempty(_object_plots(gui.controls.h, x))
        x = _part_parent(gui, x)
    end
    return x
end
