#=
The page "Debug" of the cards, while the debug mode is on: what the GUI knows about an object and
what the last solve did to it, see `_debug_rows`
=#

# The page exists only while the debug mode is on, and not for a system or an inspected item
_has_page(gui::LiveView, @nospecialize(obj), ::Val{:debug}) = _debug_on(gui)
_has_page(::LiveView, ::BMO.AbstractSystem, ::Val{:debug}) = false
_has_page(::LiveView, ::_InfoItem, ::Val{:debug}) = false

"""
    _debug_list_rows(gui, obj) -> Vector{Tuple{String, String}}

The rows of the list of the page "Debug" of the card of `obj`, formatted like the properties, see
`_debug_rows` and `_property_row`.
"""
_debug_list_rows(gui::LiveView, @nospecialize(obj)) =
    Tuple{String, String}[_property_row(name, value) for (name, value) in _debug_rows(gui, obj)]

"""
    _debug_rows(gui, obj) -> Vector{Pair{String, Any}}

The rows of the page "Debug" of the card of `obj`: those of every object (`_debug_common`) and
those of its type, by dispatch on `_debug_kind`. Each row is computed on its own: one that fails
shows as the row "Error", the others stay.
"""
function _debug_rows(gui::LiveView, @nospecialize(obj))
    rows = Pair{String, Any}[]
    for entry in Iterators.flatten((_debug_common(gui, obj), _debug_kind(gui, obj)))
        try
            append!(rows, entry())
        catch e
            push!(rows, "Error" => first(split(sprint(showerror, e), '\n')))
        end
    end
    return rows
end

# Fixed-point text of `x` with 6 digits and its sign
function _fixed6(x::Real)
    n = round(Int, abs(Float64(x)) * 1e6)
    return string(x < 0 && n > 0 ? "-" : "+", n ÷ 1_000_000, ".", lpad(n % 1_000_000, 6, '0'))
end
_vector6(v) = string("(", join((_fixed6(x) for x in v), ", "), ")")

_short_type(@nospecialize(obj)) = (s = string(typeof(obj)); length(s) > 40 ? first(s, 39) * "…" : s)
_hex_id(@nospecialize(obj)) = "0x" * string(objectid(obj); base = 16)
_trait_text(trait) = replace(string(typeof(trait)), "BeamletOptics." => "")
_shape_trait_text(@nospecialize(obj::BMO.AbstractObject)) = string(nameof(typeof(BMO.shape_trait_of(obj))))
_shape_trait_text(@nospecialize(obj)) = "–"

function _systems_rows(gui::LiveView, @nospecialize(obj))
    systems = _systems_of(gui, obj)
    names = isempty(systems) ? "none" : join((_label(gui, s) for s in systems), ", ")
    return ["systems" => string(names, " · ", BMO.is_static(obj) ? "static" : "movable")]
end

# The entries (functions without arguments that return rows) of every object
function _debug_common(gui::LiveView, @nospecialize(obj))
    return Any[
        () -> ["type" => _short_type(obj)],
        () -> ["id" => _hex_id(obj)],
        () -> _systems_rows(gui, obj),
        () -> ["kinematic trait" => _trait_text(BMO.kinematic_trait_of(obj))],
        () -> ["shape trait" => _shape_trait_text(obj)]]
end

"""
    _debug_kind(gui, obj) -> Vector

The entries (functions without arguments that return rows) of the page "Debug" that belong to the
type of `obj`, after the common ones, see `_debug_common`: for an object, a group, a source or beam
group and a detector. Add a method for a type of your own to list more.
"""
_debug_kind(::LiveView, @nospecialize(obj)) = Any[]

#=
Objects and groups
=#

_as_shapes(s::Union{Tuple, AbstractVector}) = s
_as_shapes(s) = (s,)

# "2 × RightAnglePrismSDF, Plane"
function _shapes_text(@nospecialize(obj))
    names = String[]
    counts = Int[]
    for s in _as_shapes(BMO.shape(obj))
        name = string(nameof(typeof(s)))
        i = findfirst(==(name), names)
        if isnothing(i)
            push!(names, name)
            push!(counts, 1)
        else
            counts[i] += 1
        end
    end
    isempty(names) && return "none"
    return join((n == 1 ? name : "$n × $name" for (name, n) in zip(names, counts)), ", ")
end

_sphere_text(::BMO.NoBoundingSphere, parts::Int) = "none"
_sphere_text(sph, parts::Int) =
    string("r = ", _length_string(BMO.radius(sph)), " (", parts, parts == 1 ? " part)" : " parts)")
_part_count(@nospecialize(obj::BMO.AbstractObject)) = length(_as_shapes(BMO.shape(obj)))
_part_count(@nospecialize(group::BMO.AbstractObjectGroup)) = sum(_part_count, BMO.objects(group); init = 0)

# How often the rays of the last solve end on each object: of the sources that are switched on
function _hit_counts(gui::LiveView)
    counts = IdDict{Any, Int}()
    for (i, pair) in enumerate(gui.pairs)
        _beam_on(gui, pair.second) || continue
        for seg in _debug_segments(gui, pair.second, i)
            isnothing(seg.object) || (counts[seg.object] = get(counts, seg.object, 0) + 1)
        end
    end
    return counts
end
_hits_on(counts, @nospecialize(obj::BMO.AbstractObject)) = get(counts, obj, 0)
_hits_on(counts, @nospecialize(group::BMO.AbstractObjectGroup)) =
    sum(o -> _hits_on(counts, o), BMO.objects(group); init = 0)

# The solve owns the beams while it runs, see AGENTS.md
function _object_hits_text(gui::LiveView, @nospecialize(obj))
    _running(gui) && return "solving …"
    n = _hits_on(_hit_counts(gui), obj)
    text = n == 1 ? "1 ray" : "$n rays"
    return gui.trace.stale ? text * " (outdated)" : text * " (last solve)"
end

_plots_text(gui::LiveView, @nospecialize(obj)) =
    string(sum(h -> length(render_plots(h)), _pool_handles(gui, obj); init = 0), " (render handle)")

function _orientation_rows(@nospecialize(obj))
    R = _pose(obj)[2]
    return Pair{String, Any}[(i == 1 ? "orientation" : "") => join((_fixed6(R[i, j]) for j in 1:3), "  ")
                             for i in 1:3]
end

function _object_entries(gui::LiveView, @nospecialize(obj))
    return Any[
        () -> ["position [m]" => _vector6(_pose(obj)[1])],
        () -> _orientation_rows(obj),
        () -> ["shapes" => _shapes_text(obj)],
        () -> ["sphere" => _sphere_text(BMO.bounding_sphere_of(obj), _part_count(obj))],
        () -> ["hits" => _object_hits_text(gui, obj)],
        () -> ["plots" => _plots_text(gui, obj)]]
end

_debug_kind(gui::LiveView, @nospecialize(obj::BMO.AbstractObject)) = _object_entries(gui, obj)

_debug_kind(gui::LiveView, @nospecialize(group::BMO.AbstractObjectGroup)) = Any[
    () -> ["objects" => string(length(BMO.objects(group)))],
    () -> ["position [m]" => _vector6(_pose(group)[1])],
    () -> ["main sphere" => _sphere_text(BMO.bounding_sphere_of(group), _part_count(group))],
    () -> ["hits" => _object_hits_text(gui, group)],
    () -> ["plots" => _plots_text(gui, group)]]

#=
Sources and beam groups
=#

# The beam tree below `x`: the beams of a group, the beam and its children
_beam_tree(group::BMO.AbstractBeamGroup) = Any[b for beam in BMO.beams(group) for b in _beam_tree(beam)]
function _beam_tree(beam)
    tree = Any[beam]
    for child in BMO.children(beam)
        append!(tree, _beam_tree(child))
    end
    return tree
end

# The path segments of the source `src` (the `i`-th pair of the `gui`) as it is drawn, see
# `BMO.path_segments`
function _debug_segments(gui::LiveView, @nospecialize(src), i::Int)
    flen = try
        render_settings(gui.beam_handles[i]).flen
    catch
        1.0
    end
    return BMO.path_segments(src; flen)
end

# The number of rays of a beam, of a Gaussian beamlet those of its chief, waist and divergence beams
_ray_count(beam) = length(BMO.rays(beam))
_ray_count(beam::BMO.GaussianBeamlet) =
    length(BMO.rays(beam.chief)) + length(BMO.rays(beam.waist)) + length(BMO.rays(beam.divergence))

# The index of `src` in the pairs of the `gui`, or `nothing`
_pair_index(gui::LiveView, @nospecialize(src)) = findfirst(p -> p.second === src, gui.pairs)

function _source_rows(gui::LiveView, @nospecialize(src))
    _running(gui) && return Pair{String, Any}["state" => "solving …"]
    i = _pair_index(gui, src)
    isnothing(i) && return Pair{String, Any}["state" => "not a source of the view"]
    segs = _debug_segments(gui, src, i)
    tree = _beam_tree(src)
    rows = Pair{String, Any}[]
    _beam_stale(gui, src) && push!(rows, "state" => "outdated")
    push!(rows, "beams" => string(src isa BMO.AbstractBeamGroup ? length(BMO.beams(src)) : 1))
    push!(rows, "rays" => string(sum(_ray_count, tree; init = 0)))
    push!(rows, "segments" => string(length(segs)))
    push!(rows, "max depth" => string(maximum(s -> s.depth, segs; init = 0)))
    ends = Dict{Symbol, Int}()
    r_max, depth_max = BMO.get_default_r_max(), BMO.get_default_depth_max()
    for s in segs
        s.leaf || continue
        r = _ray_end_reason(s, r_max, depth_max)
        ends[r] = get(ends, r, 0) + 1
    end
    push!(rows, "ends" => isempty(ends) ? "–" :
        join(("$r $(ends[r])" for r in (:open, :object, :r_max, :depth_max) if haskey(ends, r)), " · "))
    return rows
end

function _source_entries(gui::LiveView, @nospecialize(src))
    return Any[
        () -> _source_rows(gui, src),
        () -> (n = BMO.min_num_rays(src); isnothing(n) ? Pair{String, Any}[] : ["min rays" => string(n)]),
        () -> ["wavelength" => string(round(1e9 * BMO.wavelength(src); digits = 2), " nm")]]
end

_debug_kind(gui::LiveView, @nospecialize(src::BMO.AbstractBeam)) = _source_entries(gui, src)
_debug_kind(gui::LiveView, @nospecialize(src::BMO.AbstractBeamGroup)) = _source_entries(gui, src)

#=
Detectors
=#

_hits_type(::Nothing) = "none"
_hits_type(hits) = string(nameof(eltype(hits)))

function _view_rows(gui::LiveView, pd::BMO.Detector)
    state = get(gui.detectors.states, pd, nothing)
    return ["view" => isnothing(state) ? "not computed" : state.stale ? "outdated" : "up to date"]
end

function _detector_entries(gui::LiveView, pd::BMO.Detector)
    return Any[
        () -> ["hit type" => _running(gui) ? "solving …" : _hits_type(BMO.hits(pd))],
        () -> ["hit count" => _running(gui) ? "solving …" : string(BMO.hit_count(pd))],
        () -> _view_rows(gui, pd)]
end

_debug_kind(gui::LiveView, pd::BMO.Detector) = vcat(_object_entries(gui, pd), _detector_entries(gui, pd))

#=
Switching the mode
=#

"""
    _debug_pages_changed!(gui)

The pages of the cards changed because the debug mode was switched on or off (see `_set_debug!`):
every card gets its page bar again, a card that shows the page "Debug" falls back to its default
page, and the docked cards of the app layout follow.
"""
function _debug_pages_changed!(gui::LiveView)
    for c in gui.cards.all
        obj = _card_object(gui, c)
        isnothing(obj) && continue
        pages = _card_pages(gui, obj)
        pages == c.pages && continue
        fallback = !(c.page in pages)
        fallback && (c.page = _default_page(obj))
        _show_bar!(gui, c, pages)
        if fallback && !isnothing(c.pose) && c.pose[1] === obj
            _build_content!(gui, c, obj)
            _refresh_card!(gui, c; force = true)
        end
        _refresh_selection_part!(gui, c, obj)
    end
    _update_cards!(gui)
    _refresh_inspector!(gui; force = true)
    return nothing
end
