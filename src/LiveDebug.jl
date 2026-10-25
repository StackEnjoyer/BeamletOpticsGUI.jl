#=
The debug mode of the live view: what the GUI normally hides, to find errors in an optical system
or in the GUI, see `_Debug`. Its parts are layers (`_DebugLayer`): the debug card, the bounding
spheres, the diagnostics of the rays and the cameras of the saved views, each in a file of its own
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
- `_layer_solved!(gui, layer)`: a solve was shown, i.e. its beams are rendered, the systems it
  traced are up to date, or the beams are drawn otherwise (e.g. the length of their final rays)
- `_layer_stale!(gui, layer)`: the beams are outdated
- `_layer_tick!(gui, layer, tick)`: each tick of the window while the mode is on

The dispatchers (`_debug_moved!` etc.) call them for each layer while the mode is on; a hook must
not depend on being called once per action.
"""
abstract type _DebugLayer end

# The names of the layers, in the order in which they are created and shown
const _DEBUG_LAYERS = (:hud, :spheres, :rays, :views)

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
tool (`toggle`). `timing` is whether it switched on the compile timing of Julia
(`Base.cumulative_compile_timing`), which it does only while it is on; `start` is what the last
solve started with, `(; t0, compile, gc)` (`time()`, `Base.cumulative_compile_time_ns()` and
`Base.gc_num()`), from which a cancelled or failed solve is recorded, see `_debug_solve_started!`.
"""
Base.@kwdef mutable struct _Debug
    shown::Bool = false
    const layers::Vector{Pair{Symbol, Any}} = Pair{Symbol, Any}[]
    const stats::_DebugStats = _DebugStats()
    toggle::Any = nothing
    created::Bool = false
    timing::Bool = false
    start::Any = nothing
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
created (see `_new_layer`) and the ticks of the window are passed to them (see `_layer_tick!`).
Each time it is switched on, the layers catch up with the view as it is, e.g. the bounding spheres
of the objects of the view and the rays of the last solve, since they learn nothing while it is
off. Only while it is on, the compile time of the solves is measured, see `_set_compile_timing!`.
"""
function _set_debug!(gui::LiveView, shown::Bool)
    d = _debug!(gui)
    was = d.shown
    d.shown = shown
    # The compile time of the solves, only while the mode is on: it costs a little
    _set_compile_timing!(d, shown)
    if shown && !d.created
        d.created = true
        for name in _DEBUG_LAYERS
            push!(d.layers, name => _new_layer(gui, Val(name)))
        end
        # The ticks of the window, passed on while the mode is on
        push!(gui.controls.listeners,
            on(tick -> _debug_tick!(gui, tick), events(gui.ax.scene).tick))
    end
    if shown && !was
        # each layer catches up with the view as it is
        _debug_moved!(gui, nothing)
        _debug_hidden!(gui)
        _debug_solved!(gui)
        # the beams of the last solve are outdated
        gui.trace.stale && _debug_stale!(gui)
        _debug_event!(gui, "debug mode on")
    end
    _debug_show!(gui)
    # the page "Debug" of the cards comes or goes
    shown == was || _debug_pages_changed!(gui)
    return nothing
end

# Switches the compile timing of Julia on or off for the debug mode `d`, see `_Debug`: it counts
# how often it was switched on, hence once per mode
function _set_compile_timing!(d::_Debug, on::Bool)
    d.timing == on && return nothing
    Base.cumulative_compile_timing(on)
    d.timing = on
    return nothing
end

"""
    _close_debug!(gui)

Switches the compile timing that the debug mode of the `gui` switched on off again, when the `gui`
is closed, see `_set_compile_timing!`.
"""
function _close_debug!(gui::LiveView)
    d = _debug(gui)
    isnothing(d) || _set_compile_timing!(d, false)
    return nothing
end

# The entry of the debug mode in the help, a chip of its tool since it has no key
const _DEBUG_HELP = _HelpSection[
    "View" => [_HelpEntry([:tool => "Debug"], "debug mode: timings, bounding spheres, ends of the beams")]]

"""
    _build_debug!(gui, on::Bool)

Creates the debug mode of the `gui` with its toggle "Debug" among the tools of the layout, see the
`debug` kwarg of [`live_view`](@ref), and its entry in the help (`_DEBUG_HELP`). A mode that starts
on (`on`) keeps the status line as it is.
"""
function _build_debug!(gui::LiveView, on::Bool)
    d = _debug!(gui)
    d.toggle = add_tool!(_toggle_debug!, gui, "Debug"; icon = :tune, toggle = true,
        tooltip = "Debug mode: solve timings, bounding spheres, ends of the beams, hit points")
    append!(gui.controls.help_extra, _DEBUG_HELP)
    _update_help!(gui.controls)
    if on
        status = gui.status.text[]
        d.toggle.active[] = true
        gui.status.text[] = status
    end
    return nothing
end

# The toggle "Debug": switches the mode and says so in the status line
function _toggle_debug!(gui::LiveView, on::Bool)
    _set_debug!(gui, on)
    gui.status.text[] = on ? "debug mode on" : "debug mode off"
    return nothing
end

# The `debug` kwarg of `live_view` that builds the debug mode `d` again, see `_open_kwargs`
_debug_kwarg(::Nothing) = false
_debug_kwarg(d::_Debug) = d.shown

"""
    _debug_updated!(gui, obj, dt)

Called by the controls of the `gui` after each update of the render, e.g. a step of a drag, which
took `dt` [s] (see `_apply_update!`), with the moved `obj`: records `dt` in `stats.update`. The
layers learn about the move of an object from the `on_change` of the controls (see `live_view`),
those of an update without an object here.
"""
function _debug_updated!(gui::LiveView, @nospecialize(obj), dt::Float64)
    _debug_on(gui) || return nothing
    _debug(gui).stats.update = dt
    isnothing(obj) && _debug_moved!(gui, nothing)
    return nothing
end

#=
The records of the solves, see `_SolveRecord`
=#

# What is measured around the compile time and the garbage collector of a part of a solve
_debug_counters() = (; compile = first(Base.cumulative_compile_time_ns()), gc = Base.gc_num())

"""
    _debug_cost(start) -> (; compile, gc, allocated)

The time compiled [s], the time of the garbage collector [s] and the bytes allocated since the
counters `start` of `_debug_counters`, `nothing` while the mode is off: zero.
"""
_debug_cost(::Nothing) = (; compile = 0.0, gc = 0.0, allocated = 0)
function _debug_cost(start::NamedTuple)
    diff = Base.GC_Diff(Base.gc_num(), start.gc)
    return (; compile = 1e-9 * (first(Base.cumulative_compile_time_ns()) - start.compile),
        gc = 1e-9 * diff.total_time, allocated = Int(diff.allocd))
end

"""
    _debug_solve_started!(gui)

Notes the start of a solve of the `gui` while the debug mode is on, from which a solve that is
cancelled or fails is recorded, see `_debug_solve_ended!`.
"""
function _debug_solve_started!(gui::LiveView)
    _debug_on(gui) || return nothing
    _debug(gui).start = (; t0 = time(), _debug_counters()...)
    return nothing
end

"""
    _debug_record!(gui, r, kind, render, view, cost)

Records the solve of the `kind` `:full`, `:preview` or `:coarse` with the result `r` of `_compute`
that `_apply!` showed, while the debug mode of the `gui` is on: with the durations [s] of the
rendering of its beams (`render`) and of the detector views (`view`), and the cost of the rendering
(`cost`, see `_debug_cost`), which is added to the cost of the solve in its task (`r.cost`).
"""
function _debug_record!(gui::LiveView, r, kind::Symbol, render::Float64, view::Float64, cost)
    _debug_on(gui) || return nothing
    d = _debug(gui)
    d.start = nothing
    sources = Pair{String, Float64}[_label(gui, b) => t for (b, t) in zip(r.sources, r.source_times)]
    rc = r.cost
    record = _SolveRecord(time(), kind, r.solve_time, render, view, sources,
        rc.compile + cost.compile, rc.gc + cost.gc, rc.allocated + cost.allocated)
    _push_ring!(d.stats.solves, record, _DEBUG_SOLVES)
    _debug_event!(gui, "solve $kind, $(_ms_string(r.solve_time + render))")
    return nothing
end

"""
    _debug_solve_ended!(gui, kind, text; elapsed = nothing)

Records a solve of the `gui` that was cancelled or failed (`kind` `:cancelled` or `:failed`), with
the duration `elapsed` [s] (by default the time since it started, see `_debug_solve_started!`) as
the duration of the solve, while the debug mode is on; the event `text`, e.g. the first line of
the error.
"""
function _debug_solve_ended!(gui::LiveView, kind::Symbol, text::AbstractString;
        elapsed::Union{Nothing, Float64} = nothing)
    _debug_on(gui) || return nothing
    d = _debug(gui)
    start = d.start
    d.start = nothing
    elapsed = something(elapsed, isnothing(start) ? 0.0 : time() - start.t0)
    cost = _debug_cost(isnothing(start) ? nothing : (; start.compile, start.gc))
    record = _SolveRecord(time(), kind, elapsed, 0.0, 0.0, Pair{String, Float64}[], cost.compile,
        cost.gc, cost.allocated)
    _push_ring!(d.stats.solves, record, _DEBUG_SOLVES)
    _debug_event!(gui, text)
    return nothing
end

# The first line of the message of the error `e`, at most 80 characters
function _error_line(e)
    msg = first(split(sprint(showerror, e), '\n'))
    return length(msg) > 80 ? first(msg, 79) * "…" : String(msg)
end
