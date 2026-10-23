#=
The debug mode of the live view: what the GUI normally hides, to find errors in an optical system
or in the GUI, see `_Debug`. Its parts are layers (`_DebugLayer`): the debug card, the bounding
spheres and the diagnostics of the rays, each in a file of its own
=#

"""
    _DebugLayer

A part of the debug mode of a live view, e.g. the debug card or the bounding spheres. A layer is
created by a method of `_new_layer` for its name in `_DEBUG_LAYERS` the first time the mode is
switched on, and follows the view by methods of the hooks below, which do nothing by default:

- `_layer_show!(gui, layer, on)`: shows or hides it, `on` is whether the mode is on and the
  spectator mode is off
- `_layer_moved!(gui, layer, obj)`: `obj` was moved, `nothing` if anything may have moved
- `_layer_attached!(gui, layer, obj)`, `_layer_released!(gui, layer, obj)`: `obj` was added to
  the view or is removed from it
- `_layer_hidden!(gui, layer)`: objects were hidden or shown
- `_layer_solved!(gui, layer)`: a solve was shown, i.e. its beams are rendered
- `_layer_stale!(gui, layer)`: the beams are outdated
- `_layer_tick!(gui, layer, tick)`: each tick of the window while the mode is on

The dispatchers (`_debug_moved!` etc.) call them for each layer while the mode is on; a hook must
not depend on being called once per action.
"""
abstract type _DebugLayer end

# The names of the layers, in the order in which they are created and shown
const _DEBUG_LAYERS = (:hud, :spheres, :rays)

"""
    _new_layer(gui, ::Val{name}) -> Union{Nothing, _DebugLayer}

Creates the layer `name` (see `_DEBUG_LAYERS`) of the debug mode of the `gui`, or `nothing` for a
name without a layer.
"""
_new_layer(::LiveView, ::Val) = nothing

_layer_show!(::LiveView, ::_DebugLayer, ::Bool) = nothing
_layer_moved!(::LiveView, ::_DebugLayer, _) = nothing
_layer_attached!(::LiveView, ::_DebugLayer, _) = nothing
_layer_released!(::LiveView, ::_DebugLayer, _) = nothing
_layer_hidden!(::LiveView, ::_DebugLayer) = nothing
_layer_solved!(::LiveView, ::_DebugLayer) = nothing
_layer_stale!(::LiveView, ::_DebugLayer) = nothing
_layer_tick!(::LiveView, ::_DebugLayer, _) = nothing

"""
    _SolveRecord

A solve of the live view as the debug mode records it: when it ended (`time()`), its `kind`
(`:full`, `:preview`, `:coarse`, `:cancelled`, `:failed`), the durations [s] of `solve_system!` for
all sources without rendering (`solve`), of `update_render!` of the beams (`render`) and of the
detector views (`view`), the duration per source (`sources`, label => [s]), the time compiled
during solve and render (`compile` [s]), the time of the garbage collector (`gc` [s]) and the
bytes `allocated`.
"""
struct _SolveRecord
    time::Float64
    kind::Symbol
    solve::Float64
    render::Float64
    view::Float64
    sources::Vector{Pair{String, Float64}}
    compile::Float64
    gc::Float64
    allocated::Int
end

"""
    _RaySummary

The rays of the last solve as the debug mode shows them: the number of `beams`, `rays` and path
`segments`, the largest depth of the tree of the beams (`max_depth`), the number of the ends of the
beams per reason (`ends`: `:open` flies on, `:object` ends on an object, `:r_max` the most rays a
beam has, `:depth_max` the deepest child beam), the number of hit points drawn (`hits`) and the
components of the systems that no ray hit (`unhit`).
"""
struct _RaySummary
    beams::Int
    rays::Int
    segments::Int
    max_depth::Int
    ends::Dict{Symbol, Int}
    hits::Int
    unhit::Vector{Any}
end

# The most solve records and events that the debug mode keeps
const _DEBUG_SOLVES = 20
const _DEBUG_EVENTS = 50

"""
    _DebugStats

What the debug mode of a live view records: the last solves (`solves`, see `_SolveRecord`), the
last events (`events`, `time() => text`, see `_debug_event!`), the duration of the last drag step
(`update` [s]) and the rays of the last solve (`rays`, a `_RaySummary` or `nothing`).
"""
Base.@kwdef mutable struct _DebugStats
    const solves::Vector{_SolveRecord} = _SolveRecord[]
    const events::Vector{Pair{Float64, String}} = Pair{Float64, String}[]
    update::Float64 = 0.0
    rays::Union{Nothing, _RaySummary} = nothing
end

"""
    _Debug

The debug mode of a `LiveView`: whether it is `shown`, its `layers` (name => layer or `nothing`,
created the first time it is switched on, see `_new_layer`), what it records (`stats`) and its
tool (`toggle`).
"""
Base.@kwdef mutable struct _Debug
    shown::Bool = false
    const layers::Vector{Pair{Symbol, Any}} = Pair{Symbol, Any}[]
    const stats::_DebugStats = _DebugStats()
    toggle::Any = nothing
    created::Bool = false
end

"""The debug mode of the `gui`, or `nothing` before it is built."""
_debug(gui::LiveView) = gui.components.debug

"""Whether the debug mode of the `gui` is switched on."""
_debug_on(gui::LiveView) = (d = _debug(gui); !isnothing(d) && d.shown)

# The debug mode of the `gui`, built on first use
function _debug!(gui::LiveView)
    d = _debug(gui)
    isnothing(d) || return d
    d = _Debug()
    gui.components.debug = d
    return d
end

# Pushes `x` to the ring buffer `xs` of at most `n` entries
function _push_ring!(xs::Vector, x, n::Int)
    push!(xs, x)
    length(xs) > n && popfirst!(xs)
    return xs
end

"""
    _debug_event!(gui, text)

Records the event `text` (e.g. "solve done, 48 ms") with the current time in the debug mode of the
`gui`, while it is on.
"""
function _debug_event!(gui::LiveView, text::AbstractString)
    _debug_on(gui) || return nothing
    _push_ring!(_debug(gui).stats.events, time() => String(text), _DEBUG_EVENTS)
    return nothing
end

"""
    _register_layer!(gui, name, layer)

Adds the `layer` named `name` to the debug mode of the `gui`, e.g. a layer of a test; it is shown
like the layers of `_DEBUG_LAYERS`.
"""
function _register_layer!(gui::LiveView, name::Symbol, layer)
    d = _debug!(gui)
    push!(d.layers, name => layer)
    layer isa _DebugLayer && _layer_show!(gui, layer, _debug_visible(gui, d))
    return layer
end

"""The layer `name` of the debug mode of the `gui`, or `nothing`."""
function _debug_layer(gui::LiveView, name::Symbol)
    d = _debug(gui)
    isnothing(d) && return nothing
    for (k, layer) in d.layers
        k === name && return layer
    end
    return nothing
end

# Whether the layers of the debug mode `d` of the `gui` are visible: the mode is on and the
# spectator mode, which hides the UI, is off
_debug_visible(gui::LiveView, d::_Debug) = d.shown && !gui.controls.spectator[]

# Calls `f(gui, layer, args...)` for each layer of the debug mode of the `gui` while it is on
function _each_layer(f, gui::LiveView, args...)
    _debug_on(gui) || return nothing
    for (_, layer) in _debug(gui).layers
        layer isa _DebugLayer && f(gui, layer, args...)
    end
    return nothing
end

_debug_moved!(gui::LiveView, @nospecialize(obj)) = _each_layer(_layer_moved!, gui, obj)
_debug_attached!(gui::LiveView, @nospecialize(obj)) = _each_layer(_layer_attached!, gui, obj)
_debug_released!(gui::LiveView, @nospecialize(obj)) = _each_layer(_layer_released!, gui, obj)
_debug_hidden!(gui::LiveView) = _each_layer(_layer_hidden!, gui)
_debug_solved!(gui::LiveView) = _each_layer(_layer_solved!, gui)
_debug_stale!(gui::LiveView) = _each_layer(_layer_stale!, gui)
_debug_tick!(gui::LiveView, tick) = _each_layer(_layer_tick!, gui, tick)

"""
    _debug_show!(gui)

Shows or hides the layers of the debug mode of the `gui`: after it was switched and after the
spectator mode was switched, see `_debug_visible`.
"""
function _debug_show!(gui::LiveView)
    d = _debug(gui)
    isnothing(d) && return nothing
    on = _debug_visible(gui, d)
    for (_, layer) in d.layers
        layer isa _DebugLayer && _layer_show!(gui, layer, on)
    end
    return nothing
end

"""
    _set_debug!(gui, on::Bool)

Switches the debug mode of the `gui` on or off. The first time it is switched on, its layers are
created (see `_new_layer`), each one at its current state, e.g. the bounding spheres of the objects
of the view and the rays of the last solve.
"""
function _set_debug!(gui::LiveView, on::Bool)
    d = _debug!(gui)
    d.shown = on
    if on && !d.created
        d.created = true
        for name in _DEBUG_LAYERS
            push!(d.layers, name => _new_layer(gui, Val(name)))
        end
        # each layer catches up with the view as it is
        _debug_moved!(gui, nothing)
        _debug_solved!(gui)
    end
    _debug_show!(gui)
    return nothing
end
