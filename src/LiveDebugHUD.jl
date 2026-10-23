#=
The debug card of the debug mode (see `_Debug` in `src/LiveDebug.jl`): a card at the top left of
the 3D view with the frames, the solves, the rays, the scene and the last events, see `_DebugHUD`
=#

# z translation of the scene of the debug card: over the 3D view and the overlays of the layouts,
# below the component cards (`_CARD_Z0`), which are drawn over it when they are moved onto it, and
# the help card (`_HELP_Z`)
const _HUD_Z = 9500.0f0
# Distance of the card from the left edge and from the top edge of the 3D view [px]: below the
# help pill and its chips
const _HUD_LEFT = 12.0f0
const _HUD_TOP = 46.0f0
# Distance of the content from the edge of the background [px]
const _HUD_PADDING = 10.0f0
# Gaps between the rows, between the columns and before the header of a section [px]
const _HUD_ROWGAP = 3.0f0
const _HUD_COLGAP = 12.0f0
const _HUD_SECTION_GAP = 9.0f0
# Least time between two refreshes of the rows [s of tick time]: each change of a text makes the
# backend draw a frame, which the card itself would count, see `_hud_tick!`
const _HUD_PERIOD = 0.25
# The window of the frames per second and of the maximum of the drag step [s of tick time], and the
# least time between two counts of the atomic plots of the figure [s]
const _HUD_FRAMES_WINDOW = 1.0
const _HUD_UPDATE_WINDOW = 2.0
const _HUD_PLOTS_PERIOD = 1.0
# The most components that the row "never hit" names, and the most events that the card lists
const _HUD_UNHIT = 3
const _HUD_EVENTS = 4

# The sections of the card from top to bottom, with their titles, see `_hud_rows`
const _HUD_SECTIONS = (:frames => "Frames", :solve => "Solve", :rays => "Rays", :scene => "Scene",
    :events => "Events")

# The title of the section `name`
function _hud_title(name::Symbol)
    for (k, title) in _HUD_SECTIONS
        k === name && return title
    end
    return string(name)
end

# The items of the legend of the ends of the beams (the row "ends" of the section "Rays") by the
# start of their text, with the color token of their dot
const _HUD_ENDS = ("on object" => :ok, "open" => :stale, "ray limit" => :danger,
    "depth limit" => :danger)

"""
    _DebugHUD <: _DebugLayer

The debug card of the debug mode of a live view: a card at the top left of the 3D view, below the
help pill, in the style of the component cards (see `_ComponentCard`) and the color tokens `theme`
of the layout. It lies in a `scene` of its own with a pixel camera over the whole figure, translated
to `_HUD_Z`: an overlay that is neither picked nor fitted by the camera nor clipped. It consists of
the `background`, the `head` (the icon `:tune`, the title "Debug" and the rate of its refresh) and
the `body`, a free layout of a header per section and a row per value, see `_hud_rows`.

`blocks` are the blocks of the body and `cells` their labels per row of the layout `key`: a header
(a `Label`), a row (the labels of its key and its value) or the legend of the ends of the beams
(the label of its key, the labels of its items and their dots). The body is built again only when
the `key` changes, e.g. the number of the events; otherwise only changed texts are assigned, since
each assignment makes the backend draw a frame, see `_hud_refresh!`.

The ticks of the window (`_layer_tick!`) count the frames (`frames`, the times of the
`RegularRenderTick`s within the last second) and the drag steps (`updates`, the time of the tick
and the duration of each new drag step of `_DebugStats` within the last 2 s, the last one in
`last_update`), and refresh the rows at most every `_HUD_PERIOD` s of tick time (`refreshed`,
`refreshes`; `now` is the time of the last tick). `plots` is the number of the atomic plots of the
figure, counted at most every `_HUD_PLOTS_PERIOD` s (`plots_time`). The card is `shown` while the
debug mode is on and the spectator mode off; `listeners` place it again when the 3D view is
resized.
"""
mutable struct _DebugHUD <: _DebugLayer
    const scene::Scene
    const theme::NamedTuple
    const background::Box
    const head::GridLayout
    body::GridLayout
    const blocks::Vector{Any}
    const cells::Vector{Any}
    key::Vector{Any}
    const listeners::Vector{Any}
    shown::Bool
    refreshed::Float64
    refreshes::Int
    now::Float64
    const frames::Vector{Float64}
    const updates::Vector{Tuple{Float64, Float64}}
    last_update::Float64
    plots::Int
    plots_time::Float64
end

# A free layout of the card `scene`, aligned at the top left corner of its suggested bounding box
function _hud_grid(scene::Scene)
    g = GridLayout(; bbox = _CARD_AWAY, halign = :left, valign = :top, default_colgap = _HUD_COLGAP,
        default_rowgap = _HUD_ROWGAP)
    g.parent = scene
    return g
end

# The style of a label of the card in the tokens `t`: a value, unless overridden by `kwargs`
_hud_label(pos, t::NamedTuple, text::AbstractString; kwargs...) =
    Label(pos, text; halign = :left, _card_style(t, Label)..., kwargs...)
# A key of a row, in the muted color
_hud_key(pos, t::NamedTuple, text::AbstractString) = _hud_label(pos, t, text; color = t.muted)

function _new_layer(gui::LiveView, ::Val{:hud})
    t = gui.layout.theme
    scene = Scene(gui.fig.scene; camera = Makie.campixel!, clear = false)
    translate!(scene, 0, 0, _HUD_Z)
    background = Box(scene; bbox = _CARD_AWAY, color = t.sidebar, strokecolor = t.border,
        strokewidth = 1, cornerradius = _CARD_CORNER)
    head = _hud_grid(scene)
    Makie.colgap!(head, 6)
    icon, icon_color = _card_icon!(head[1, 1])
    icon[] = _icon(:tune)
    icon_color[] = RGBAf(Makie.to_color(t.text))
    _hud_label(head[1, 2], t, "Debug"; font = :bold, fontsize = _CARD_TITLE_FONTSIZE)
    _hud_label(head[1, 3], t, "$(round(Int, 1 / _HUD_PERIOD))×/s"; color = t.muted,
        fontsize = _CARD_SUBTITLE_FONTSIZE)
    Makie.GridLayoutBase.trim!(head)
    scene.visible[] = false
    hud = _DebugHUD(scene, t, background, head, _hud_grid(scene), Any[], Any[], Any[], Any[],
        false, -Inf, 0, 0.0, Float64[], Tuple{Float64, Float64}[], 0.0, -1, -Inf)
    push!(hud.listeners, Makie.on(_ -> hud.shown && _hud_arrange!(gui, hud), Makie.viewport(gui.ax.scene)))
    return hud
end

function _layer_show!(gui::LiveView, hud::_DebugHUD, on::Bool)
    hud.shown = on
    _update!(hud.scene.visible, on)
    if on
        _hud_refresh!(gui, hud)
    else
        # hidden blocks still take the mouse within their bounding boxes, see `_CARD_AWAY`
        foreach(_park!, (hud.head, hud.body, hud.background))
    end
    return nothing
end

_layer_tick!(gui::LiveView, hud::_DebugHUD, tick) = _hud_tick!(gui, hud, tick)

"""
    _hud_tick!(gui, hud::_DebugHUD, tick)

Counts the `tick` of the window of the `gui` for the debug card `hud`: a `RegularRenderTick` is a
frame, the others are not (GLMakie ticks also without drawing). Records a new drag step of the
stats and refreshes the rows of the shown card at most every `_HUD_PERIOD` s of the time of the
ticks, see `_hud_refresh!`.
"""
function _hud_tick!(gui::LiveView, hud::_DebugHUD, tick)
    now = Float64(tick.time)
    hud.now = now
    tick.state === Makie.RegularRenderTick && push!(hud.frames, now)
    filter!(s -> s > now - _HUD_FRAMES_WINDOW, hud.frames)
    d = _debug(gui)
    u = isnothing(d) ? 0.0 : d.stats.update
    if u != hud.last_update
        hud.last_update = u
        u > 0 && push!(hud.updates, (now, u))
    end
    filter!(x -> x[1] > now - _HUD_UPDATE_WINDOW, hud.updates)
    (hud.shown && now - hud.refreshed >= _HUD_PERIOD) && _hud_refresh!(gui, hud)
    return nothing
end

#=
The rows of the sections
=#

# A duration [s] in ms with one decimal, e.g. "41.0 ms", or "–"
_hud_ms(s::Real) = isfinite(s) ? "$(round(1e3 * s; digits = 1)) ms" : "–"
# A number with the noun in the singular or the plural, e.g. "1 system", "7 objects"
_hud_count(n::Integer, noun::AbstractString) = "$n $noun$(n == 1 ? "" : "s")"
# The age of an event [s], e.g. "0.2 s", "12 s", "3 min"
_hud_age(dt::Real) = dt < 10 ? "$(round(max(dt, 0.0); digits = 1)) s" :
    dt < 60 ? "$(round(Int, dt)) s" : "$(round(Int, dt / 60)) min"

# The debug card of the debug mode `d`, or `nothing`
function _hud_layer(d::_Debug)
    for (_, layer) in d.layers
        layer isa _DebugHUD && return layer
    end
    return nothing
end

"""
    _hud_rows(gui, d::_Debug, ::Val{section}) -> Vector{Pair{String, String}}

The rows of the `section` of the debug card (see `_HUD_SECTIONS`) of the debug mode `d` of the
`gui`, key => value, computed from the stats of `d` (see `_DebugStats`), the state of the `gui` and
what the debug card counted. A value that is not known yet is "–".
"""
function _hud_rows end

function _hud_rows(gui::LiveView, d::_Debug, ::Val{:frames})
    hud = _hud_layer(d)
    rows = Pair{String, String}[]
    if isnothing(hud)
        push!(rows, "frames" => "–", "drag step" => "–", "plots" => "–")
        return rows
    end
    n = length(hud.frames)
    frames = n < 2 ? "$n /s" :
        "$n /s · $(_hud_ms((hud.frames[end] - hud.frames[1]) / (n - 1)))"
    push!(rows, "frames" => frames)
    u = d.stats.update
    top = maximum(last, hud.updates; init = u)
    push!(rows, "drag step" => (u > 0 ? "$(_hud_ms(u)) (max $(_hud_ms(top)))" : "–"))
    w, h = round.(Int, Makie.widths(Makie.viewport(gui.fig.scene)[]))
    ppu = _hud_px_per_unit(gui)
    plots = hud.plots < 0 ? "–" : string(hud.plots)
    window = isnothing(ppu) ? "$(w)×$(h)" :
        "$(w)×$(h) @$(isinteger(ppu) ? round(Int, ppu) : round(ppu; digits = 2))×"
    push!(rows, "plots" => "$plots · $window")
    return rows
end

# The pixels per unit of the screen of the `gui`, or `nothing` without a screen
function _hud_px_per_unit(gui::LiveView)
    screen = Makie.getscreen(gui.fig.scene)
    (isnothing(screen) || !hasproperty(screen, :px_per_unit)) && return nothing
    p = getproperty(screen, :px_per_unit)
    p = p isa Observable ? p[] : p
    return p isa Real ? Float64(p) : nothing
end

"""
The state of the solve of the `gui` as the debug card names it: "running" (a solve in the
background), "failed" (the last solve threw), "pending" (a solve waits for the movement to pause),
"outdated" (the beams are), "preview" (the beams are a preview or coarse) or "idle".
"""
function _hud_state(gui::LiveView)
    _running(gui) && return "running"
    isnothing(gui.trace.error) || return "failed"
    gui.trace.pending && return "pending"
    gui.trace.stale && return "outdated"
    (gui.trace.preview || gui.trace.coarse) && return "preview"
    return "idle"
end

function _hud_rows(gui::LiveView, d::_Debug, ::Val{:solve})
    rows = Pair{String, String}["state" => _hud_state(gui)]
    solves = d.stats.solves
    budget = gui.trace.budget
    budget_text = isfinite(budget) ? _ms_string(budget) : "none"
    if isempty(solves)
        push!(rows, "solve" => "–  (budget $budget_text)", "beams drawn" => "–", "views" => "–",
            "JIT · GC" => "–")
    else
        r = last(solves)
        kind = r.kind === :full ? "" : " $(r.kind)"
        push!(rows, "solve" => "$(_hud_ms(r.solve))$kind  (budget $budget_text)",
            "beams drawn" => _hud_ms(r.render), "views" => _hud_ms(r.view),
            "JIT · GC" => "$(_hud_ms(r.compile)) · $(_hud_ms(r.gc)), $(round(r.allocated / 2^20; digits = 1)) MiB")
    end
    push!(rows, "threads" => string(Threads.nthreads()))
    if isempty(solves) || isempty(last(solves).sources)
        push!(rows, "slowest" => "–")
    else
        name, s = argmax(last, last(solves).sources)
        push!(rows, "slowest" => "$name  $(_hud_ms(s))")
    end
    return rows
end

function _hud_rows(gui::LiveView, d::_Debug, ::Val{:rays})
    r = d.stats.rays
    isnothing(r) && return Pair{String, String}["beams" => "–", "ends" => "–", "normals" => "–"]
    n(k) = get(r.ends, k, 0)
    ends = ["on object $(n(:object))", "open $(n(:open))", "ray limit $(n(:r_max))"]
    n(:depth_max) > 0 && push!(ends, "depth limit $(n(:depth_max))")
    rows = Pair{String, String}[
        "beams" => "$(r.beams) · $(_hud_count(r.segments, "segment")) · depth $(r.max_depth)",
        "ends" => join(ends, " · "), "normals" => "$(r.hits) hit points"]
    if !isempty(r.unhit)
        names = join((_label(gui, x) for x in first(r.unhit, _HUD_UNHIT)), ", ")
        more = length(r.unhit) - _HUD_UNHIT
        push!(rows, "never hit" => (more > 0 ? "$names +$more" : names))
    end
    return rows
end

function _hud_rows(gui::LiveView, ::_Debug, ::Val{:scene})
    systems = length(gui.system_handles)
    objects = length(render_children(gui.pool))
    sources = length(_sources(gui))
    detectors = length(_find_detectors(_systems(gui)))
    cards = gui.cards.all
    open = count(c -> c.scene.visible[], cards)
    pinned = count(c -> c.pinned && !c.transient, cards)
    undo = length(gui.controls.undo_stack)
    return Pair{String, String}[
        "objects" => join((_hud_count(systems, "system"), _hud_count(objects, "object"),
            _hud_count(sources, "source"), _hud_count(detectors, "detector")), " · "),
        "cards" => "$open open · $pinned pinned · undo $undo"]
end

function _hud_rows(::LiveView, d::_Debug, ::Val{:events})
    events = d.stats.events
    isempty(events) && return Pair{String, String}["" => "none"]
    now = time()
    return Pair{String, String}[_hud_age(now - t) => text
                                for (t, text) in Iterators.reverse(last(events, _HUD_EVENTS))]
end

"""
    _hud_sections(gui, d::_Debug) -> Vector{Pair{Symbol, Vector{Pair{String, String}}}}

The rows of each section of the debug card of the debug mode `d` of the `gui`, see `_hud_rows`. A
section whose rows fail shows the row "error" with the first line of its message instead.
"""
function _hud_sections(gui::LiveView, d::_Debug)
    return Pair{Symbol, Vector{Pair{String, String}}}[
        name => try
            _hud_rows(gui, d, Val(name))
        catch err
            Pair{String, String}["error" => first(split(sprint(showerror, err), '\n'))]
        end
        for (name, _) in _HUD_SECTIONS]
end

#=
The widgets of the rows
=#

# Whether the row `key => value` of the `section` is the legend of the ends of the beams
_hud_legend(section::Symbol, row::Pair) = section === :rays && first(row) == "ends" && last(row) != "–"
# The items of the legend `value`, e.g. "on object 2"
_hud_items(value::AbstractString) = split(value, " · ")

# The color of the dot of the legend item `item` in the tokens `t`, see `_HUD_ENDS`
function _hud_dot(t::NamedTuple, item::AbstractString)
    for (start, token) in _HUD_ENDS
        startswith(item, start) && return getproperty(t, token)
    end
    return t.muted
end

# The color of the value of the row `key => value` of the `section` in the tokens `t`
function _hud_color(t::NamedTuple, section::Symbol, row::Pair)
    key, value = row
    if section === :solve && key == "state"
        value == "idle" && return t.ok_text
        value == "failed" && return t.danger
        value == "outdated" && return t.stale_text
    end
    (section === :rays && key == "never hit") && return t.stale_text
    key == "error" && return t.danger
    return t.text
end

# The layout of the `sections`: a header per section, a row per value, the number of the items of
# a legend; the body is built again when it changes
_hud_layout_key(sections) = Any[k for (name, rows) in sections
                         for k in (:header, (_hud_legend(name, r) ? (:legend, length(_hud_items(last(r)))) : :row
                                             for r in rows)...)]

"""
    _hud_refresh!(gui, hud::_DebugHUD)

Shows the rows of the debug mode of the `gui` on its debug card `hud`: builds the body again if its
layout changed (see `_hud_layout_key`), otherwise assigns the texts and colors that changed, and places
the card at the top left of the 3D view. Counts the atomic plots of the figure at most every
`_HUD_PLOTS_PERIOD` s.
"""
function _hud_refresh!(gui::LiveView, hud::_DebugHUD)
    d = _debug(gui)
    isnothing(d) && return nothing
    hud.refreshed = hud.now
    hud.refreshes += 1
    if hud.plots < 0 || hud.now - hud.plots_time >= _HUD_PLOTS_PERIOD
        hud.plots = length(Makie.collect_atomic_plots(gui.fig.scene))
        hud.plots_time = hud.now
    end
    sections = _hud_sections(gui, d)
    key = _hud_layout_key(sections)
    if key != hud.key
        _hud_build!(hud, sections)
        hud.key = key
    else
        _hud_update!(hud, sections)
    end
    _hud_arrange!(gui, hud)
    return nothing
end

# Builds the body of the debug card `hud` for the `sections`, see `_DebugHUD`
function _hud_build!(hud::_DebugHUD, sections)
    foreach(delete!, hud.blocks)
    empty!(hud.blocks)
    empty!(hud.cells)
    # a new layout instead of the empty rows of the old one, see `_clear_content!`
    _park!(hud.body)
    hud.body = g = _hud_grid(hud.scene)
    t = hud.theme
    r = 0
    for (name, rows) in sections
        r += 1
        header = _hud_label(g[r, 1:2], t, uppercase(_hud_title(name)); color = t.muted,
            font = :bold, fontsize = 10)
        push!(hud.blocks, header)
        push!(hud.cells, header)
        r > 1 && Makie.rowgap!(g, r - 1, _HUD_SECTION_GAP)
        for row in rows
            r += 1
            key = _hud_key(g[r, 1], t, first(row))
            push!(hud.blocks, key)
            if _hud_legend(name, row)
                legend = GridLayout(g[r, 2]; default_colgap = 4, halign = :left)
                dots, labels = Label[], Label[]
                for (i, item) in enumerate(_hud_items(last(row)))
                    push!(dots, _hud_label(legend[1, 2i - 1], t, "●"; color = _hud_dot(t, item),
                        fontsize = 13))
                    push!(labels, _hud_label(legend[1, 2i], t, String(item)))
                end
                append!(hud.blocks, dots, labels)
                push!(hud.cells, (key, labels, dots))
            else
                value = _hud_label(g[r, 2], t, last(row); color = _hud_color(t, name, row))
                push!(hud.blocks, value)
                push!(hud.cells, (key, value))
            end
        end
    end
    Makie.GridLayoutBase.trim!(g)
    return nothing
end

# Assigns the texts and colors of the `sections` that changed to the body of the debug card `hud`,
# whose layout is the one of the `sections`
function _hud_update!(hud::_DebugHUD, sections)
    t = hud.theme
    i = 0
    for (name, rows) in sections
        i += 1 # the header
        for row in rows
            i += 1
            cell = hud.cells[i]
            _update!(cell[1].text, first(row))
            if cell[2] isa Label
                _update!(cell[2].text, last(row))
                _update!(cell[2].color, _hud_color(t, name, row))
            else
                for (label, dot, item) in zip(cell[2], cell[3], _hud_items(last(row)))
                    _update!(label.text, String(item))
                    _update!(dot.color, _hud_dot(t, item))
                end
            end
        end
    end
    return nothing
end

"""
    _hud_arrange!(gui, hud::_DebugHUD)

Places the debug card `hud` at the top left of the 3D view of the `gui`, `_HUD_LEFT` px from its
left edge and `_HUD_TOP` px below its top edge, and fits the background around the head and the
body. Only changed positions update the layout.
"""
function _hud_arrange!(gui::LiveView, hud::_DebugHUD)
    vp = Rect2f(Makie.viewport(gui.ax.scene)[])
    x0, y0 = minimum(vp)[1] + _HUD_LEFT, maximum(vp)[2] - _HUD_TOP
    p = Point2f(x0 + _HUD_PADDING, y0 - _HUD_PADDING)
    _place!(hud.head, p)
    h = _card_size(hud.head)
    _place!(hud.body, p - Point2f(0, h[2] + _HUD_ROWGAP))
    b = _card_size(hud.body)
    w, height = max(h[1], b[1]) + 2 * _HUD_PADDING, h[2] + _HUD_ROWGAP + b[2] + 2 * _HUD_PADDING
    _update!(hud.background.layoutobservables.suggestedbbox, Rect2f(x0, y0 - height, w, height))
    return nothing
end

#=
The debug card among the other parts over the 3D view: the floating cards keep off it, and its
presses and scrolling reach neither the controls nor the camera, like those of the cards
=#

"""
    _debug_obstacles(gui) -> Vector{Rect2f}

The rectangle [figure px] of the debug card of the `gui` while it is shown, which the floating
cards keep off like the view cube, see `_obstacles`; none while the debug mode is off, in the
spectator mode and before the card is created.
"""
function _debug_obstacles(gui::LiveView)
    hud = _shown_hud(gui)
    return isnothing(hud) ? Rect2f[] : Rect2f[_hud_rect(hud)]
end

"""
    _over_debug(gui) -> Bool

Returns `true` if the mouse is over the debug card of the `gui` while it is shown: its presses and
its scrolling reach neither the controls (`ignore_mouse`, no selection) nor the camera (see
`_shield_cards!`), like those over the cards.
"""
function _over_debug(gui::LiveView)
    hud = _shown_hud(gui)
    isnothing(hud) && return false
    return Point2f(Makie.events(gui.ax.scene).mouseposition[]) in _hud_rect(hud)
end

# The debug card of the `gui` while it is shown, else `nothing`
function _shown_hud(gui::LiveView)
    d = _debug(gui)
    hud = isnothing(d) ? nothing : _hud_layer(d)
    return (isnothing(hud) || !hud.shown) ? nothing : hud
end

# The rectangle of the background of the debug card `hud` [figure px]
_hud_rect(hud::_DebugHUD) = Rect2f(hud.background.layoutobservables.computedbbox[])
