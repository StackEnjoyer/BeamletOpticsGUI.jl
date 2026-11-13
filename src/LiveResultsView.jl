#=
The views of the page "Results" of a card in a figure of its own: `results_view!`, `ResultsView`
and `refresh!`. The widget is the one of the cards (`_DetectorView`); with a live view it shares
the options and the result of the object with its cards, without one it keeps its own options and
computes only when it is built, on `refresh!` and on its own widgets
=#

"""
    ResultsView{G}

A view of the page "Results" of a card in a figure of its own, built by [`results_view!`](@ref):
it shows one of the [`card_views`](@ref) of an object, with the switch between them, zoom, pan and
the controls of a field like the card. `G` is the type of the [`live_view`](@ref) window that
updates it after each of its solves, or `Nothing` for a view that changes only on
[`refresh!`](@ref) and on its own widgets.

It only draws: it has no public fields and hands back no data or metrics of what it shows; a
script that wants the numbers calls the function of the [`CardView`](@ref) itself. `close(view)`
removes it from its figure, after which it is neither computed nor drawn.
"""
mutable struct ResultsView{G}
    const obj::Any
    const gui::G
    const widget::_DetectorView
    # the options of a view without a live view; those of a live view are in its state
    opts::_ViewOptions
    closed::Bool
end

Base.propertynames(::ResultsView) = ()

Base.show(io::IO, v::ResultsView) =
    print(io, "ResultsView(", repr(getfield(v, :widget).name), getfield(v, :closed) ? ", closed)" : ")")

function results_view!(position, gui::LiveView, @nospecialize(obj); kwargs...)
    return _rv_build!(position, gui, gui.layout.theme, _label(gui, obj), obj; kwargs...)
end

function results_view!(position, @nospecialize(obj); theme::Symbol = :light,
        name::AbstractString = "Results", kwargs...)
    return _rv_build!(position, nothing, _app_theme(theme), String(name), obj; kwargs...)
end

function refresh!(v::ResultsView)
    v.closed && throw(ArgumentError("the results view $(repr(v.widget.name)) is closed"))
    _rv_refresh!(v)
    return v
end

function Base.close(v::ResultsView)
    v.closed && return nothing
    v.closed = true
    _rv_detach!(v)
    _delete_view!(v.widget)
    return nothing
end

#=
Building
=#

function _rv_build!(position, gui, theme::NamedTuple, name::String, @nospecialize(obj);
        view::Symbol = :auto, expanded::Bool = true, width::Real = 280, height::Real = 280,
        spot_colors = nothing)
    _rv_check_view(obj, view)
    grid = _rv_grid(position)
    ev = _rv_events(grid)
    widget = _DetectorView(grid, theme; expanded, width, height)
    widget.name = name
    v = ResultsView(obj, gui, widget, _ViewOptions(; kind = view, spot_colors), false)
    _connect_view!(widget, ev; on_options = (; changes...) -> _rv_on_options!(v; changes...),
        on_expanded = e -> _rv_on_expanded!(v, e))
    _rv_attach!(v, view, spot_colors)
    return v
end

# The names of the views of `obj`, see `card_views`
_rv_view_names(@nospecialize(obj)) = Symbol[cv.name for cv in card_views(obj)]

"""
Throws an `ArgumentError` if `obj` has no views, or if `view` is neither `:auto` nor the name of one
of them. An object with the page "Results" (`_has_view`) that offers no views now, e.g. a
`Detector` without hits, is not checked by name.
"""
function _rv_check_view(@nospecialize(obj), view::Symbol)
    names = _rv_view_names(obj)
    if isempty(names)
        _has_view(obj) && return nothing
        throw(ArgumentError("$(nameof(typeof(obj))) has no views on the page \"Results\", see `card_views`"))
    end
    (view === :auto || view in names) && return nothing
    throw(ArgumentError("$(nameof(typeof(obj))) has no view :$view, its views are " *
        join((":" * string(n) for n in names), ", ")))
end

# The layout of the widget in the `position`
_rv_grid(position::GridLayout) = GridLayout(position[1, 1])
_rv_grid(position) = GridLayout(position)

# The events of the figure of the layout `grid`
function _rv_events(grid::GridLayout)
    fig = Makie.GridLayoutBase.top_parent(grid)
    fig isa Figure || throw(ArgumentError("the position of a results view must be in a Figure"))
    return events(Makie.get_scene(fig))
end

# The options of the view of a live view are those of its object: the `view` and the
# `spot_colors` are set for all views of the object unless they are `:auto` and `nothing`; then it
# is computed with the shown views of the window
function _rv_attach!(v::ResultsView{<:LiveView}, view::Symbol, spot_colors)
    gui = v.gui
    view === :auto || _set_view!(gui, v.obj; kind = view)
    isnothing(spot_colors) || _set_view!(gui, v.obj; spot_colors)
    _register_view!(gui, v.obj, v.widget)
    _redraw_views!(gui, v.obj)
    _view_needed!(gui, v.obj)
    return nothing
end
_rv_attach!(v::ResultsView{Nothing}, _, _) = (_rv_refresh!(v); nothing)

_rv_detach!(::ResultsView{Nothing}) = nothing
_rv_detach!(v::ResultsView{<:LiveView}) = _rv_unregister_view!(v.gui, v.widget)

"""
    _rv_unregister_view!(gui, view)

Removes the `view` (a `_DetectorView`) from the views that are registered in the `gui` (see
`_register_view!`), by identity: it is no longer computed after a solve.
"""
function _rv_unregister_view!(gui::LiveView, view)
    registered = gui.detectors.registered
    for i in length(registered):-1:1
        registered[i][2] === view && deleteat!(registered, i)
    end
    return nothing
end

#=
Computing and showing
=#

# The grid that the view of `v` needs with the options `opts`: of a thumbnail while it is collapsed
_rv_n(v::ResultsView, opts::_ViewOptions) =
    v.widget.expanded ? opts.num_points : min(opts.num_points, _THUMB_N)

# Without a live view: computed now from the current state of the object
function _rv_refresh!(v::ResultsView{Nothing})
    result = _view_result(v.obj, v.opts; n = _rv_n(v, v.opts))
    _show_result!(v.widget, v.widget.name, result, v.opts)
    return nothing
end

# With a live view: computed from the results of its last solve, like after a change of options
function _rv_refresh!(v::ResultsView{<:LiveView})
    _detector_state(v.gui, v.obj).stale = true
    _view_needed!(v.gui, v.obj)
    return nothing
end

# The options that only show the result again, see `_set_view!`
const _RV_REDRAW_ONLY = (:colorscale, :colorbar, :profiles)

# Called by the widget for the options that the user changed
_rv_on_options!(v::ResultsView{<:LiveView}; changes...) = _set_view!(v.gui, v.obj; changes...)
# Without a live view there is no series to `clear` (see `_set_view!`)
function _rv_on_options!(v::ResultsView{Nothing}; changes...)
    v.closed && return nothing
    opts = v.opts
    changed = (; (k => x for (k, x) in pairs(changes) if k !== :clear && getfield(opts, k) != x)...)
    isempty(changed) && return nothing
    v.opts = _ViewOptions(opts; changed...)
    if all(in(_RV_REDRAW_ONLY), keys(changed))
        _show_result!(v.widget, v.widget.name, v.widget.result, v.opts)
    else
        _rv_refresh!(v)
    end
    return nothing
end

# Called by the widget when the user expands or collapses it
function _rv_on_expanded!(v::ResultsView{<:LiveView}, expanded::Bool)
    _set_expanded!(v.widget, expanded)
    _view_needed!(v.gui, v.obj)
    return nothing
end
function _rv_on_expanded!(v::ResultsView{Nothing}, expanded::Bool)
    v.closed && return nothing
    _set_expanded!(v.widget, expanded)
    expanded && _rv_refresh!(v)
    return nothing
end
