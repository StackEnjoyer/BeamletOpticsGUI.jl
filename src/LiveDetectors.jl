#=
Detectors of the live view: the state of the view of each detector, its computation after a
solve and the `detectors` kwarg of `live_view`
=#

"""
    _has_view(obj) -> Bool

Whether the card of `obj` has the page "Results" with a view of what `obj` measures (see
`_DetectorView`): a `Detector`. Add a method for a type to give its card this page.
"""
_has_view(_) = false
_has_view(::BMO.Detector) = true

"""Returns all `Detector`s of the `systems`, deduplicated by identity, in the order of discovery."""
function _find_detectors(systems)
    seen = Base.IdSet{Any}()
    dets = BMO.Detector[]
    for sys in systems, obj in BMO.objects(sys)
        obj isa BMO.Detector || continue
        obj in seen && continue
        push!(seen, obj)
        push!(dets, obj)
    end
    return dets
end

"""
    _detector_state(gui, pd) -> _DetectorState

The state of the view of the detector `pd` in the `gui`, created with the default options (see
`_ViewOptions`) when it is first asked for.
"""
_detector_state(gui::LiveView, pd::BMO.Detector) =
    get!(() -> _DetectorState(pd, _ViewOptions(), nothing, true, 0.0), gui.detectors.states, pd)

#=
Views that are shown: on the floating cards (see `_card_view`) and in the layout (see
`_layout_views`)
=#

"""
    _card_view(c)

The detector view that the card `c` shows, i.e. on its page "Results" while the card is neither
hidden nor collapsed, or `nothing`. By default `nothing`; the hosts of views add their methods.
"""
_card_view(_) = nothing

"""
    _layout_views(gui) -> iterable of (pd, view)

The detector views shown by the layout of the `gui` outside the floating cards, each with its
detector, e.g. on the docked cards of the app layout; none by default, see `AbstractLiveLayout`.
"""
_layout_views(::LiveView) = ()

"""
    _shown_views(gui) -> Vector{Tuple{Any, Any}}

The detector views `(pd, view)` that the `gui` shows: those of its floating cards (see
`_card_view`), those of its layout (see `_layout_views`) and the registered ones (see
`_register_view!`). Only their detectors are computed after a solve, see `_view_requests`.
"""
function _shown_views(gui::LiveView)
    views = Tuple{Any, Any}[]
    for c in gui.cards.all
        view = _card_view(c)
        isnothing(view) || push!(views, (_card_object(gui, c), view))
    end
    for (pd, view) in _layout_views(gui)
        push!(views, (pd, view))
    end
    append!(views, gui.detectors.registered)
    return views
end

"""
    _register_view!(gui, pd, view)

Registers the `view` (a `_DetectorView`) of the detector `pd` that a host outside the cards and the
layout of the `gui` shows, e.g. in a figure of its own: it is computed and shown like the views of
the cards while it is registered, see `_shown_views`.
"""
function _register_view!(gui::LiveView, pd::BMO.Detector, view)
    push!(gui.detectors.registered, (pd, view))
    _view_needed!(gui, pd)
    return view
end

#=
Computation: a request per detector with a shown view, computed with the fields of a solve (see
`_compute`) or in a job of its own for a view that is shown later, see `_refresh_views!`
=#

"""
    _ViewRequest

The computation of the view of the detector `pd` with the options `opts` (those of its `state` when
the request was made) on a grid of `n` points per axis, see `_view_requests`. It is computed in a
background task, see `_view_field`, and shown by `_apply_view!`.
"""
struct _ViewRequest
    pd::BMO.Detector
    state::_DetectorState
    opts::Any
    n::Int
end

"""
    _view_requests(gui; stale_only = false) -> Vector{Any}

A request per detector of which the `gui` shows a view (see `_shown_views`), on the grid of its
options if one of its views is expanded, on the grid of a thumbnail (`_THUMB_N`) otherwise. With
`stale_only`, only for the views that need a computation, see `_needs_result`.
"""
function _view_requests(gui::LiveView; stale_only::Bool = false)
    requests = Any[]
    seen = Base.IdSet{Any}()
    views = _shown_views(gui)
    for (pd, _) in views
        pd in seen && continue
        push!(seen, pd)
        state = _detector_state(gui, pd)
        expanded = any(((p, v),) -> p === pd && v.expanded, views)
        n = expanded ? state.opts.n : min(state.opts.n, _THUMB_N)
        (stale_only && !_needs_result(gui, state, n)) && continue
        push!(requests, _ViewRequest(pd, state, state.opts, n))
    end
    return requests
end

"""
Whether the view of the `state` must be computed on a grid of `n` points: it is stale (and no zoom
is waiting for the mouse to rest, see `_set_view!`), or its result is of a coarser grid, e.g. of a
thumbnail, while a view is expanded.
"""
function _needs_result(gui::LiveView, state::_DetectorState, n::Int)
    _window_pending(gui, state) && return false
    state.stale && return true
    r = state.result
    return !isnothing(r) && r.n < n && !r.coarse
end

_window_pending(gui::LiveView, state::_DetectorState) =
    state.window_changed > 0 && time() - state.window_changed < gui.trace.idle_delay

"""
    _view_field(r::_ViewRequest, coarse::Bool, preview::Bool) -> _ViewResult

Computes the view of the request `r` from the hits of its detector, without changing any plot, such
that it can run in a background task, see `_compute` and `_view_result`.
"""
_view_field(r::_ViewRequest, coarse::Bool, preview::Bool) =
    _view_result(r.pd, r.opts; n = r.n, coarse, preview)

"""
    _apply_view!(gui, r::_ViewRequest, result)

Stores the `result` of the request `r` in the state of its detector and shows it in all views of
the detector, see `_redraw_views!`. The state stays stale if its options changed while the result
was computed.
"""
function _apply_view!(gui::LiveView, r::_ViewRequest, result)
    state = r.state
    state.result = result
    state.stale = state.opts !== r.opts
    _redraw_views!(gui, r.pd)
    return nothing
end

"""
    _redraw_views!(gui, pd)

Shows the result of the state of the detector `pd` with its options in all shown views of `pd`,
see `_show_result!`.
"""
function _redraw_views!(gui::LiveView, pd)
    state = _detector_state(gui, pd)
    name = _label(gui, pd)
    for (p, view) in _shown_views(gui)
        p === pd && _show_result!(view, name, state.result, state.opts)
    end
    return nothing
end

"""
Marks the views of all detectors of the `gui` stale before a solve empties the detectors; until its
result is shown, the hits are incomplete, see `_views_applied!`.
"""
function _views_solve_started!(gui::LiveView)
    gui.detectors.hits_valid = false
    for state in values(gui.detectors.states)
        state.stale = true
    end
    return nothing
end

"""
After the result of a solve was shown: the hits are complete, views that were shown meanwhile, e.g.
while the solve ran in the background, are computed from them, see `_refresh_views!`.
"""
function _views_applied!(gui::LiveView)
    gui.detectors.hits_valid = true
    _refresh_views!(gui)
    return nothing
end

"""After a cancelled solve or computation, the views wait for the next solve, like the beams."""
_views_cancelled!(gui::LiveView) = (gui.detectors.hits_valid = false; nothing)

# Status of the computation of a view in the background, see `_refresh_views!`
const _VIEW_COMPUTING = "computing the detector view, Cancel in the progress window stops it"

"""
    _refresh_views!(gui)

Computes the shown views that need it (see `_needs_result`): a view shown or expanded after the
last solve, or after its options changed. They are computed from the hits of the last solve in a
job like the refinement of a coarse preview (see `_start_job`), with a progress window for long
computations. Nothing is computed while a solve runs or after a cancelled or failed solve; the next
solve computes the shown views.
"""
function _refresh_views!(gui::LiveView)
    (gui.detectors.hits_valid && !_running(gui)) || return nothing
    requests = _view_requests(gui; stale_only = true)
    isempty(requests) && return nothing
    foreach(r -> r.state.window_changed = 0.0, requests)
    status = gui.status.text[]
    # The job has a state as its object, such that the status line is not set to "traced"
    job = _start_job(gui, r -> _show_views!(gui, r, status), first(requests).state, empty(gui.pairs),
        empty(gui.beam_handles), requests; timing = :view_time)
    _run!(gui, job, _VIEW_COMPUTING)
    return nothing
end

"""Shows the result `r` of a job of `_refresh_views!`, the status line is restored to `status`."""
function _show_views!(gui::LiveView, r, status)
    foreach((request, result) -> _apply_view!(gui, request, result), r.requests, r.results)
    gui.status.text[] == _VIEW_COMPUTING && (gui.status.text[] = status)
    return nothing
end

"""
    _view_needed!(gui, pd)

Called by the host of a view of the detector `pd` when it shows the view or expands it: computes it
if it needs a result, see `_refresh_views!`.
"""
_view_needed!(gui::LiveView, _) = _refresh_views!(gui)

"""
Called every frame: computes the views whose window changed by zoom or pan once the mouse rested for
`idle_delay`, see `_set_view!`.
"""
function _views_idle!(gui::LiveView)
    any(s -> s.window_changed > 0, values(gui.detectors.states)) || return nothing
    _refresh_views!(gui)
    return nothing
end

"""
    _set_view!(gui, pd; kind, colorscale, colorbar, profiles, window)

Sets options of the view of the detector `pd` from its widgets, only those given: the `kind`
(`:auto` or the name of a kind, see `_view_kinds`) and the `window` of a field view (the visible
rectangle `(x_min, x_max, z_min, z_max)` [m] after zoom or pan, `nothing` for the automatic one)
need a new result, the `colorscale`, the `colorbar` and the `profiles` only show the result again. A new window is
computed once the mouse rests for `idle_delay`, see `_views_idle!`, not per step of the wheel.
"""
function _set_view!(gui::LiveView, pd; changes...)
    state = _detector_state(gui, pd)
    changes = (; (k => v for (k, v) in pairs(changes) if getfield(state.opts, k) != v)...)
    isempty(changes) && return nothing
    state.opts = _ViewOptions(state.opts; changes...)
    if haskey(changes, :window)
        state.stale = true
        state.window_changed = time()
    end
    if haskey(changes, :kind)
        state.stale = true
        _refresh_views!(gui)
    end
    # The other options, and the new ones until the result follows
    _redraw_views!(gui, pd)
    return nothing
end

#=
The `detectors` kwarg of `live_view`
=#

# The kinds of a view that the `detectors` kwarg accepts, see `_view_kinds`
const _DETECTOR_KINDS = (:auto, :spot, :psf, :intensity)

# Options of a view in the kwargs of a detector, which are not passed to `intensity`
const _VIEW_OPTION_KEYS = (:n, :colorscale, :colorrange, :colorbar, :profiles, :expanded)

const _DETECTOR_SPEC_HINT = "use `pd`, `pd => kind` or `pd => (kind, kwargs)`"

_detector_spec(pd::BMO.Detector) = (pd, :auto, (;))
_detector_spec(p::Pair{<:BMO.Detector}) = _detector_spec(p.first, p.second)
_detector_spec(x) = throw(ArgumentError("invalid detector $x, $_DETECTOR_SPEC_HINT"))
_detector_spec(pd, kind::Symbol) = (pd, kind, (;))
_detector_spec(pd, t::Tuple{Symbol, NamedTuple}) = (pd, t...)
_detector_spec(pd, x) = throw(ArgumentError("invalid detector $(pd => x), $_DETECTOR_SPEC_HINT"))

"""
    _detector_specs(detectors) -> Vector{Any}

The detectors of the `detectors` kwarg of [`live_view`](@ref) whose cards start pinned, each as
`(; pd, opts, expanded)` with the options of its view (a `_ViewOptions`) and whether the view
starts expanded: none for `:auto`, otherwise an entry per `pd`, `pd => kind` or
`pd => (kind, kwargs)`. The `kwargs` hold the options `n`, `colorscale`, `colorrange`, `colorbar`,
`profiles` and `expanded`; all others are passed to `intensity`.
"""
function _detector_specs(detectors)
    if detectors isa Symbol
        detectors == :auto || throw(ArgumentError("detectors must be :auto or a vector, got :$detectors"))
        return Any[]
    end
    return Any[_view_spec(_detector_spec(d)...) for d in detectors]
end

"""
    _detector_specs(detectors, systems) -> Vector{Any}

The specs of the `detectors` kwarg, see `_detector_specs(detectors)`; a detector that is not part of
the `systems` throws an `ArgumentError`, since its card would show nothing.
"""
function _detector_specs(detectors, systems)
    specs = _detector_specs(detectors)
    known = _find_detectors(systems)
    for spec in specs
        any(pd -> pd === spec.pd, known) ||
            throw(ArgumentError("detectors: a listed `Detector` is not part of the systems"))
    end
    return specs
end

function _view_spec(pd, kind::Symbol, kwargs::NamedTuple)
    kind in _DETECTOR_KINDS ||
        throw(ArgumentError("the kind of a detector view must be one of $_DETECTOR_KINDS, got :$kind"))
    haskey(kwargs, :history) && throw(ArgumentError("detector views have no `history`: record the " *
        "values in `on_change` and plot them in a panel of `add_panel!`"))
    colorscale = get(kwargs, :colorscale, :linear)
    colorscale in (:linear, :log) ||
        throw(ArgumentError("colorscale of a detector view must be :linear or :log, got $(repr(colorscale))"))
    rest = NamedTuple(k => v for (k, v) in pairs(kwargs) if !(k in _VIEW_OPTION_KEYS))
    opts = _ViewOptions(; kind, n = Int(get(kwargs, :n, 100)), kwargs = rest, colorscale,
        colorrange = get(kwargs, :colorrange, nothing), colorbar = Bool(get(kwargs, :colorbar, true)),
        profiles = Bool(get(kwargs, :profiles, false)))
    return (; pd, opts, expanded = Bool(get(kwargs, :expanded, true)))
end

"""
    _init_detectors!(gui, specs)

Takes the options of the views of the `specs` (see `_detector_specs`) into the states of their
detectors and keeps the specs as the cards that start pinned.
"""
function _init_detectors!(gui::LiveView, specs)
    for spec in specs
        _detector_state(gui, spec.pd).opts = spec.opts
    end
    gui.detectors.start = collect(Any, specs)
    return nothing
end

"""
    _pin_view!(gui, pd; expanded = true)

Pins a card to the detector `pd` that shows its page "Results", with the view `expanded` or
collapsed to its thumbnail: a floating card next to the detector by default; a layout that docks
the pinned cards, e.g. the app layout, docks it, see `AbstractLiveLayout`.
"""
function _pin_view!(gui::LiveView, pd; expanded::Bool = true)
    c = _spare_card!(gui)
    c.page, c.view_expanded = :results, expanded
    _pin!(gui, c, pd)
    _on_pinned!(gui)
    return nothing
end

"""Pins the cards of the detectors of the `detectors` kwarg of the `gui`, see `_init_detectors!`."""
_pin_detectors!(gui::LiveView) = foreach(s -> _pin_view!(gui, s.pd; s.expanded), gui.detectors.start)
