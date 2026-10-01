#=
Overlay of the compact layout: help pill, tool rail, camera popover at the view cube and toast,
see `CompactLayout`; the help pill is a part of the help of both layouts, see `_HelpUI`
=#

using Makie: Box, Outside

# z translation of the scene of the overlay: over the 3D view, under the cards (`_CARD_Z0`), whose
# menus and tooltips come after it, see `_CARD_Z`
const _OVERLAY_Z = 9500.0f0
# Distance of the parts from the edges of the 3D view and between them [px]
const _OVERLAY_MARGIN = 12.0f0
const _OVERLAY_GAP = 8.0f0
# Size of the icon buttons of the camera popover and of their icons [px]
const _OVERLAY_TOOL = 30
const _OVERLAY_ICON = 20
# Alpha of the backgrounds of the parts: the 3D view shines through a little
const _OVERLAY_ALPHA = 0.95
const _TOAST_ALPHA = 0.85

"""
Seconds for which the toast shows a new status text, see `_show_toast!`. A `Ref`, such that tests
can shorten it.
"""
const _TOAST_SECONDS = Ref(3.0)

"""Seconds after which the camera popover hides once the mouse left it and the view cube."""
const _CAMERA_HIDE_DELAY = 0.3

"""The icon `name` of the overlay, see `_icon`."""
_overlay_icon(name::Symbol) = _icon(name)
_overlay_icon(path::BezierPath) = path

_rgba(c) = RGBAf(Makie.to_color(c))
_rgba(c, alpha::Real) = (x = _rgba(c); RGBAf(x.r, x.g, x.b, alpha))

#=
Timer of the toast and of the camera popover
=#

"""
    _Deadline(action)

Calls `action()` once at the time `at` [s, see `time`], via a `Timer`, i.e. without blocking and
without work per frame; `at = Inf` while nothing is scheduled. `_schedule!` sets or moves the time,
`_cancel!` cancels it. `fire` is the time for which the `timer` is armed.
"""
mutable struct _Deadline
    at::Float64
    fire::Float64
    timer::Union{Nothing, Timer}
    action::Function
end

_Deadline(action::Function = () -> nothing) = _Deadline(Inf, Inf, nothing, action)

"""Schedules the `action` of `d` in `delay` seconds, instead of the time scheduled before."""
function _schedule!(d::_Deadline, delay::Real)
    d.at = time() + delay
    if isnothing(d.timer) || d.at < d.fire
        isnothing(d.timer) || close(d.timer)
        _arm!(d, delay)
    end
    return nothing
end

"""Cancels the scheduled `action` of `d`."""
_cancel!(d::_Deadline) = (d.at = Inf; nothing)

function _arm!(d::_Deadline, delay::Real)
    d.fire = time() + delay
    d.timer = Timer(max(delay, 1.0e-3)) do _
        d.timer = nothing
        isfinite(d.at) || return nothing
        rest = d.at - time()
        if rest > 1.0e-3
            # moved by `_schedule!` since the timer was armed
            _arm!(d, rest)
        else
            d.at = Inf
            try
                d.action()
            catch e
                @error "live_view: overlay timer failed" exception = (e, catch_backtrace())
            end
        end
        return nothing
    end
    return nothing
end

#=
Parts and entries of the overlay
=#

"""
    _OverlayPart

A part of the overlay of the compact layout, e.g. the tool rail: a free `GridLayout` `outer` in
the scene of the overlay, placed by the top left corner of its suggested bounding box like the
parts of a card (see `_place!`, moved away while hidden, see `_park!`), holding the background
`box` and the `content`, a grid with the widgets inside the padding.
"""
struct _OverlayPart
    outer::GridLayout
    box::Box
    content::GridLayout
end

function _OverlayPart(scene::Scene, t::NamedTuple; color = _rgba(t.sidebar, _OVERLAY_ALPHA),
        strokecolor = t.border, cornerradius::Real = 8, padding = (8, 8, 8, 8),
        default_rowgap = 4, default_colgap = 6)
    outer = GridLayout(; bbox = _CARD_AWAY, halign = :left, valign = :top)
    outer.parent = scene
    box = Box(outer[1, 1]; color, strokecolor, strokewidth = 1, cornerradius)
    content = GridLayout(outer[1, 1]; alignmode = Outside(padding...), default_rowgap,
        default_colgap)
    return _OverlayPart(outer, box, content)
end

"""The rectangle [figure px] of the part `p`, i.e. of its background."""
_overlay_rect(p::_OverlayPart) = Rect2f(p.box.layoutobservables.computedbbox[])

"""
    _OverlayItem(pos, t; icon, label = "", toggle = false, active = false, kwargs...)

An entry of the overlay of the compact layout at the grid position `pos`, e.g. a tool of the tool
rail: its `icon` (see `_overlay_icon`) and its `label` on a background that shows the hover and,
for a `toggle`, the active state in the colors of the theme tokens `t`. A left click increments
`clicks` (a button) or flips `active` (a toggle), like `Makie.Button` and `Makie.Toggle`, hence
the shared logic and [`add_tool!`](@ref) use it like them.

# Keyword arguments

- `trailing = ""`: a text at the right end, e.g. "›" of an entry that opens a popover
- `color`: the background while neither hovered nor active (transparent by default),
  `cornerradius = 6`, `padding = (8, 12, 5, 5)`, `size`: the width and height, fixed if given
- `icon_size = 18`, `fontsize = 13`, `icon_color = t.text`, `label_color = t.text`

# Fields

`box` (the background), `clicks`, `active`, `hovered`, `label` (the text, an observable) and
`toggle`.
"""
struct _OverlayItem
    box::Box
    clicks::Observable{Int}
    active::Observable{Bool}
    hovered::Observable{Bool}
    label::Observable{String}
    toggle::Bool
end

function _OverlayItem(pos, t::NamedTuple; icon::Union{Symbol, BezierPath},
        label::AbstractString = "", trailing::AbstractString = "", toggle::Bool = false,
        active::Bool = false, color = _TRANSPARENT, cornerradius::Real = 6,
        padding = (8, 12, 5, 5), size = nothing, icon_size::Real = 18, fontsize::Real = 13,
        icon_color = t.text, label_color = t.text)
    clicks, active, hovered = Observable(0), Observable(active), Observable(false)
    c0, ch, ca = _rgba(color), _rgba(t.hover), _rgba(t.accent_soft)
    fi, fl, fa = _rgba(icon_color), _rgba(label_color), _rgba(t.accent)
    background = Observable(c0)
    icon_fg, label_fg = Observable(fi), Observable(fl)
    # The background fills the cell of `pos`, e.g. the width of the tool rail, under the icon and
    # the label
    box = Box(pos; color = background, strokewidth = 0, cornerradius, width = size, height = size)
    g = GridLayout(pos; alignmode = Outside(padding...), default_colgap = 10,
        halign = isnothing(size) ? :left : :center)
    holder = Box(g[1, 1]; width = icon_size, height = icon_size, visible = false)
    center = Makie.lift(r -> Point2f(Makie.origin(r) .+ Makie.widths(r) ./ 2), holder.blockscene,
        holder.layoutobservables.computedbbox)
    scatter!(holder.blockscene, center; marker = _overlay_icon(icon), markersize = icon_size,
        color = icon_fg, markerspace = :pixel, inspectable = false)
    text = if isempty(label)
        Observable(String(label))
    else
        Label(g[1, 2], label; _card_style(t, Label)..., fontsize, color = label_fg,
            halign = :left).text
    end
    isempty(trailing) || Label(g[1, 3], trailing; _card_style(t, Label)..., fontsize,
        color = t.muted, halign = :right)
    function update_look!(_...)
        _update!(background, active[] ? ca : hovered[] ? ch : c0)
        _update!(icon_fg, active[] ? fa : fi)
        _update!(label_fg, active[] ? fa : fl)
        return nothing
    end
    onany(update_look!, hovered, active)
    update_look!()
    scene = box.blockscene
    mouse = Makie.addmouseevents!(scene, box.layoutobservables.computedbbox)
    on(scene, mouse.obs) do event
        type = event.type
        if type === Makie.MouseEventTypes.enter
            _update!(hovered, true)
        elseif type === Makie.MouseEventTypes.out
            _update!(hovered, false)
        elseif type in (Makie.MouseEventTypes.leftclick, Makie.MouseEventTypes.leftdoubleclick)
            # The second of two fast clicks is a double click, which counts as a click
            toggle ? (active[] = !active[]) : (clicks[] += 1)
            return Consume(true)
        end
        return Consume(false)
    end
    return _OverlayItem(box, clicks, active, hovered, text, toggle)
end

#=
Help pill, of both layouts
=#

"""
    _overlay_scene(fig) -> Scene

A scene with a pixel camera over the whole figure `fig`, translated to `_OVERLAY_Z`, for the
`_OverlayPart`s of a layout.
"""
function _overlay_scene(fig::Figure)
    scene = Scene(fig.scene; camera = Makie.campixel!, clear = false)
    translate!(scene, 0, 0, _OVERLAY_Z)
    return scene
end

"""
    _help_pill(scene, t) -> (pill::_OverlayPart, button::_OverlayItem)

The help pill ("? h keys") in the `scene` of an overlay in the colors of the theme tokens `t`,
placed at the top left of the 3D view by `_place_pill!`; a click on its `button` opens and closes
the help card, see `_HelpUI`.
"""
function _help_pill(scene::Scene, t::NamedTuple)
    pill = _OverlayPart(scene, t; cornerradius = 13, padding = (0, 0, 0, 0))
    button = _OverlayItem(pill.content[1, 1], t; icon = :help, label = "h  keys",
        cornerradius = 13, padding = (8, 10, 3, 3), icon_size = 16, fontsize = 12,
        icon_color = t.muted, label_color = t.muted)
    return pill, button
end

"""Places the help `pill` at the top left of the 3D view with the viewport `vp` [figure px]."""
_place_pill!(pill::_OverlayPart, vp) = _place!(pill.outer,
    Point2f(minimum(vp)[1] + _OVERLAY_MARGIN, maximum(vp)[2] - _OVERLAY_MARGIN))

#=
The overlay
=#

"""
    _CompactOverlay(fig, ax, cube, theme)

The overlay of the compact layout over the 3D view `ax` (see `CompactLayout`), in `scene`, a scene
with a pixel camera over the whole figure, translated to `_OVERLAY_Z`, built like the floating cards
(see `_ComponentCard`) from `_OverlayPart`s:

- `pill`: the help pill at the top left with its `pill_button`, a part of the help of the layout,
  see `_HelpUI`
- `more`: the round button "⋯" at the bottom left, whose toggle `more_button` opens the tool rail
- `rail`: the tool rail above it, whose grid `rail_tools` holds an entry per row: the built-in
  tools (see `_RAIL_TOOLS`), then `rail_counts[1]` tools of [`add_tool!`](@ref),
  `rail_counts[2]` entries of the sections of [`add_controls!`](@ref) and `rail_counts[3]` (0 or
  1) of the sliders, see `_rail_slot!`; the `sections` are the entries with their popovers right of the rail, of which the one with the index
  `open_section` is shown (0 for none)
- `camera`: the camera popover below the view `cube` (`camera_tools`: home, fit, views and its
  `views_menu`, save view, orthographic), shown while `camera_shown`: while the mouse is over the
  cube or the popover, hidden by `camera_deadline` after it left both; always without a view cube
- `toast`: the status and the info label at the bottom center, shown for `_TOAST_SECONDS` after a
  new text while `toast_shown`, see `toast_deadline`

The shown parts are placed by `_arrange_overlay!`, the others moved away (see `_park!`), since
hidden widgets still take clicks within their bounding box. `reshield` adds the mouse shield of
the cards again after widgets were added, see `_shield_cards!`.
"""
mutable struct _CompactOverlay
    const scene::Scene
    const theme::NamedTuple
    const ax::LScene
    const cube::Union{Nothing, ViewCube}
    const pill::_OverlayPart
    const pill_button::_OverlayItem
    const more::_OverlayPart
    const more_button::_OverlayItem
    const rail::_OverlayPart
    const rail_tools::GridLayout
    const rail_counts::Vector{Int}
    const sections::Vector{Tuple{_OverlayItem, _OverlayPart}}
    open_section::Int
    const camera::_OverlayPart
    const camera_tools::GridLayout
    camera_shown::Bool
    const camera_deadline::_Deadline
    const toast::_OverlayPart
    toast_shown::Bool
    const toast_deadline::_Deadline
    fit_button::Any
    views_button::Any
    views_menu::Union{Nothing, Menu}
    reshield::Function
end

function _CompactOverlay(fig::Figure, ax::LScene, cube, t::NamedTuple)
    scene = _overlay_scene(fig)
    pill, pill_button = _help_pill(scene, t)
    # "⋯" and the tool rail
    more = _OverlayPart(scene, t; color = _rgba(t.accent_soft, _OVERLAY_ALPHA),
        strokecolor = t.accent, cornerradius = 20, padding = (0, 0, 0, 0))
    more_button = _OverlayItem(more.content[1, 1], t; icon = :more, toggle = true,
        cornerradius = 20, padding = (0, 0, 0, 0), size = 40, icon_size = 24)
    rail = _OverlayPart(scene, t; padding = (6, 6, 6, 6), default_rowgap = 0)
    # One grid for all entries, which take the width of the rail
    rail_tools = GridLayout(rail.content[1, 1]; default_rowgap = 2)
    # Camera popover
    camera = _OverlayPart(scene, t; padding = (8, 8, 6, 8))
    Label(camera.content[1, 1], "Camera"; _card_style(t, Label)..., fontsize = 11,
        color = t.muted, halign = :left, tellwidth = false)
    camera_tools = GridLayout(camera.content[2, 1]; default_colgap = 4)
    # Toast
    toast = _OverlayPart(scene, t; color = _rgba(t.sidebar, _TOAST_ALPHA), strokecolor = t.border,
        cornerradius = 14, padding = (14, 14, 6, 6))
    o = _CompactOverlay(scene, t, ax, cube, pill, pill_button, more, more_button, rail, rail_tools,
        [0, 0, 0], Tuple{_OverlayItem, _OverlayPart}[], 0, camera, camera_tools, isnothing(cube),
        _Deadline(), toast, false, _Deadline(), nothing, nothing, nothing, () -> nothing)
    o.camera_deadline.action = () -> _hide_camera!(o)
    o.toast_deadline.action = () -> _hide_toast!(o)
    return o
end

# The rail is open while its button "⋯" is active
_rail_open(o::_CompactOverlay) = o.more_button.active[]

"""
    _rail_item!(o, pos, toggle::Val, label, icon, active) -> _OverlayItem

An entry of a tool at the grid position `pos` of the tool rail of the overlay `o`: a button
(`Val(false)`) or a toggle (`Val(true)`, initially `active`) with the `icon` and the `label`.
"""
_rail_item!(o::_CompactOverlay, pos, ::Val{T}, label, icon, active::Bool) where {T} =
    _OverlayItem(pos, o.theme; icon, label, toggle = T, active)

"""
    _rail_slot!(o, group::Int) -> GridPosition

The position of a new entry of the tool rail of the overlay `o` at the end of its `group`: 1 for the
tools of [`add_tool!`](@ref), 2 for the sections of [`add_controls!`](@ref), 3 for the sliders,
which follow the built-in tools in this order; the entries after it move one row down.
"""
function _rail_slot!(o::_CompactOverlay, group::Int)
    grid = o.rail_tools
    row = length(_RAIL_TOOLS) + sum(o.rail_counts[1:group]) + 1
    row <= _GLB.nrows(grid) && _GLB.insertrows!(grid, row, 1)
    o.rail_counts[group] += 1
    return grid[row, 1]
end

"""The component menu in the tool rail of the overlay `o`, with the `options`, see `_build_menus`."""
function _rail_menu!(o::_CompactOverlay, options)
    t = o.theme
    g = GridLayout(o.rail_tools[findfirst(==(:search), _RAIL_TOOLS), 1];
        alignmode = Outside(8, 12, 3, 3), default_colgap = 10, halign = :left)
    holder = Box(g[1, 1]; width = 18, height = 18, visible = false)
    center = Makie.lift(r -> Point2f(Makie.origin(r) .+ Makie.widths(r) ./ 2), holder.blockscene,
        holder.layoutobservables.computedbbox)
    scatter!(holder.blockscene, center; marker = _overlay_icon(:search), markersize = 18,
        color = t.text, markerspace = :pixel, inspectable = false)
    return Menu(g[1, 2]; options, default = nothing, prompt = "select component", width = 170,
        _card_style(t, Menu)...)
end

"""
    _camera_tool!(o, col, toggle::Val, icon, tooltip, active)

A tool of the camera popover of the overlay `o` in the column `col`: an icon button (`Val(false)`)
or toggle (`Val(true)`, initially `active`) with the `tooltip`, like the toolbar of the app layout.
"""
function _camera_tool!(o::_CompactOverlay, col::Int, ::Val{T}, icon, tooltip, active::Bool) where {T}
    kw = (; _icon_theme(o.theme)..., size = _OVERLAY_TOOL, icon_size = _OVERLAY_ICON, icon, tooltip)
    b = T ? _IconToggle(o.camera_tools[1, col]; active, kw...) : _IconButton(o.camera_tools[1, col]; kw...)
    # The tooltip relative to the translation of the overlay, like on the cards
    _fix_tooltip!(b)
    return b
end

"""
    _add_section!(o, title; sliders = false) -> GridLayout

Adds an entry named `title` to the tool rail of the overlay `o` (in the place of the sliders if
`sliders`, otherwise after the sections before) and its popover, a card-styled part with the
`title` right of the rail, which the entry opens and closes. Returns the grid of the widgets in the
popover, e.g. of [`add_controls!`](@ref).
"""
function _add_section!(o::_CompactOverlay, title::String; sliders::Bool = false)
    t = o.theme
    item = _OverlayItem(_rail_slot!(o, sliders ? 3 : 2), t; icon = :tune, label = title,
        trailing = "›")
    part = _OverlayPart(o.scene, t; padding = (10, 10, 8, 10), default_rowgap = 6)
    Label(part.content[1, 1], title; _card_style(t, Label)..., font = :bold, halign = :left)
    content = GridLayout(part.content[2, 1])
    push!(o.sections, (item, part))
    k = length(o.sections)
    on(_ -> _toggle_section!(o, k), item.clicks)
    _arrange_overlay!(o)
    return content
end

"""Opens the popover of the section `k` of the overlay `o`, or closes it if it is open."""
function _toggle_section!(o::_CompactOverlay, k::Int)
    o.open_section = o.open_section == k ? 0 : k
    _arrange_overlay!(o)
    return nothing
end

"""Adds the mouse shield again and places the parts, after widgets were added to the overlay `o`."""
function _on_overlay_changed!(o::_CompactOverlay)
    o.reshield()
    _arrange_overlay!(o)
    return nothing
end

#=
Toast
=#

"""
    _toast_labels!(o, text) -> (status, info)

Creates the labels of the toast of the overlay `o`: the status line with the initial `text` and
the info label (see `_status_info`) after a separator " · ", which is shown while both have a
text. Each new text of either shows the toast, see `_show_toast!`.
"""
function _toast_labels!(o::_CompactOverlay, text::String)
    t = o.theme
    style = (; _card_style(t, Label)..., fontsize = 13)
    status = Label(o.toast.content[1, 1], text; style...)
    sep = Label(o.toast.content[1, 2], ""; style..., color = t.muted)
    info = Label(o.toast.content[1, 3], ""; style..., color = t.muted)
    function update!(_)
        _update!(sep.text, isempty(status.text[]) || isempty(info.text[]) ? "" : "·")
        _show_toast!(o)
        return nothing
    end
    on(update!, status.text)
    on(update!, info.text)
    update!(nothing)
    return status, info
end

"""Shows the toast of the overlay `o` for `_TOAST_SECONDS`, from now on, see `_Deadline`."""
function _show_toast!(o::_CompactOverlay)
    o.toast_shown = true
    _arrange_toast!(o, _view_rect(o))
    _schedule!(o.toast_deadline, _TOAST_SECONDS[])
    return nothing
end

function _hide_toast!(o::_CompactOverlay)
    o.toast_shown = false
    _park!(o.toast.outer)
    return nothing
end

#=
Camera popover
=#

"""
Shows the camera popover of the overlay `o` while the mouse at `p` is over the view cube or the
popover (or the gap between them), and hides it `_CAMERA_HIDE_DELAY` seconds after it left them,
see `_hide_camera!`. Nothing without a view cube, whose popover is always shown.
"""
function _hover_camera!(o::_CompactOverlay, p::Point2f)
    isnothing(o.cube) && return nothing
    c = Rect2f(Makie.viewport(o.cube.scene)[])
    over = p in c || (o.camera_shown && p in _hull(c, _overlay_rect(o.camera)))
    if over
        _cancel!(o.camera_deadline)
        if !o.camera_shown
            o.camera_shown = true
            _arrange_overlay!(o)
        end
    elseif o.camera_shown && !isfinite(o.camera_deadline.at)
        _schedule!(o.camera_deadline, _CAMERA_HIDE_DELAY)
    end
    return nothing
end

# The smallest rectangle around `a` and `b`
function _hull(a::Rect2f, b::Rect2f)
    lo, hi = min.(minimum(a), minimum(b)), max.(maximum(a), maximum(b))
    return Rect2f(lo, hi - lo)
end

"""Hides the camera popover of the overlay `o`, unless its views menu is open."""
function _hide_camera!(o::_CompactOverlay)
    isnothing(o.cube) && return nothing
    if !isnothing(o.views_menu) && o.views_menu.is_open[]
        _schedule!(o.camera_deadline, _CAMERA_HIDE_DELAY)
        return nothing
    end
    o.camera_shown = false
    _arrange_overlay!(o)
    return nothing
end

#=
Placement
=#

_view_rect(o::_CompactOverlay) = Rect2f(Makie.viewport(o.ax.scene)[])

"""
    _arrange_overlay!(o)

Places the parts of the overlay `o` that are shown in the 3D view and moves the others away (see
`_park!`): the help pill at the top left, "⋯" at the bottom left, the open tool rail above it and
the open popover of a section right of the rail at the height of its entry, the camera popover
below the view cube (at the top right without a cube), the toast at the bottom center. Only changed
positions update the layout, hence it is called every frame, which follows the size of the window
and of the parts.
"""
function _arrange_overlay!(o::_CompactOverlay)
    vp = _view_rect(o)
    lo, hi = minimum(vp), maximum(vp)
    m = _OVERLAY_MARGIN
    _place_pill!(o.pill, vp)
    ms = _card_size(o.more.outer)
    _place!(o.more.outer, Point2f(lo[1] + m, lo[2] + m + ms[2]))
    rail = if _rail_open(o)
        rs = _card_size(o.rail.outer)
        top = min(lo[2] + m + ms[2] + _OVERLAY_GAP + rs[2], hi[2] - m)
        _place!(o.rail.outer, Point2f(lo[1] + m, top))
        Rect2f(lo[1] + m, top - rs[2], rs...)
    else
        _park!(o.rail.outer)
        nothing
    end
    for (k, (item, part)) in enumerate(o.sections)
        if isnothing(rail) || k != o.open_section
            _park!(part.outer)
            continue
        end
        ps = _card_size(part.outer)
        y = maximum(Rect2f(item.box.layoutobservables.computedbbox[]))[2]
        y = clamp(y, min(hi[2] - m, lo[2] + m + ps[2]), hi[2] - m)
        _place!(part.outer, Point2f(maximum(rail)[1] + _OVERLAY_GAP, y))
    end
    if o.camera_shown
        cs = _card_size(o.camera.outer)
        p = if isnothing(o.cube)
            Point2f(hi[1] - m - cs[1], hi[2] - m)
        else
            c = Rect2f(Makie.viewport(o.cube.scene)[])
            Point2f(clamp(maximum(c)[1] - cs[1], lo[1] + m, max(lo[1] + m, hi[1] - m - cs[1])),
                minimum(c)[2] - 2)
        end
        _place!(o.camera.outer, p)
    else
        _park!(o.camera.outer)
    end
    _arrange_toast!(o, vp)
    return nothing
end

function _arrange_toast!(o::_CompactOverlay, vp::Rect2f)
    o.toast_shown || return _park!(o.toast.outer)
    ts = _card_size(o.toast.outer)
    x = minimum(vp)[1] + (Makie.widths(vp)[1] - ts[1]) / 2
    _place!(o.toast.outer, Point2f(max(x, minimum(vp)[1]), minimum(vp)[2] + _OVERLAY_MARGIN + ts[2]))
    return nothing
end

"""
Returns the rectangles [figure px] of the parts of the overlay `o` that take clicks and are shown:
the help pill, "⋯", the open tool rail and popover of a section, the shown camera popover. The
toast only shows text, the clicks on it reach the 3D view.
"""
function _overlay_rects(o::_CompactOverlay)
    rects = Rect2f[_overlay_rect(o.pill), _overlay_rect(o.more)]
    if _rail_open(o)
        push!(rects, _overlay_rect(o.rail))
        o.open_section > 0 && push!(rects, _overlay_rect(last(o.sections[o.open_section])))
    end
    o.camera_shown && push!(rects, _overlay_rect(o.camera))
    return rects
end

"""Returns `true` if the point `p` [figure px] is over a shown part of the overlay `o` that takes clicks."""
_over_overlay(o::_CompactOverlay, p::Point2f) = any(r -> p in r, _overlay_rects(o))

"""
Closes the open popover of a section of the overlay `o`, else the tool rail, else the camera
popover. Returns `false` if none was open, see the key `Esc`.
"""
function _close_overlay!(o::_CompactOverlay)
    if _rail_open(o) && o.open_section > 0
        o.open_section = 0
        _arrange_overlay!(o)
    elseif _rail_open(o)
        o.more_button.active[] = false
    elseif o.camera_shown && !isnothing(o.cube)
        _cancel!(o.camera_deadline)
        _hide_camera!(o)
    else
        return false
    end
    return true
end

#=
Hooks of the compact layout, see `AbstractLiveLayout`
=#

_layout_obstacles(gui::CompactView) =
    [_overlay_rects(gui.layout.overlay); _help_rects(gui.layout.help)]
function _over_layout(gui::CompactView)
    p = Point2f(events(gui.ax.scene).mouseposition[])
    return _over_overlay(gui.layout.overlay, p) || _over_help(gui.layout.help, p)
end
# While a menu is open, a click into the 3D view only closes it
_outside_view(gui::CompactView) = _menu_open(gui) || _over_layout(gui)

"""
    _connect_overlay!(gui)

Connects the overlay of the compact layout of the `gui` (see `_CompactOverlay`), except its help
pill (see `_connect_help!`): "⋯" toggles the tool rail, which a press outside of it (unless a menu
is open) and the key `Esc` close, like its popovers; the camera popover follows the mouse, the
parts follow the size of the window and their content.
"""
function _connect_overlay!(gui::CompactView)
    o = gui.layout.overlay
    ctrl = gui.controls
    ev = events(gui.ax.scene)
    listeners = ctrl.listeners
    o.views_menu = gui.widgets.views_menu
    o.reshield = () -> _shield_cards!(gui)
    push!(listeners, on(o.more_button.active) do open
        open || (o.open_section = 0)
        _arrange_overlay!(o)
        return nothing
    end)
    # Before the cards (250) and the controls (200), which still get the press
    push!(listeners, on(ev.mousebutton, priority = 260) do event
        (event.action == Mouse.press && _rail_open(o)) || return Consume(false)
        p = Point2f(ev.mouseposition[])
        (_over_overlay(o, p) || _menu_open(gui) || any(m -> m.is_open[], gui.custom.menus)) &&
            return Consume(false)
        o.more_button.active[] = false
        return Consume(false)
    end)
    # Before the other listeners of Esc (≤ 202), e.g. cancelling a solve or deselecting
    push!(listeners, on(ev.keyboardbutton, priority = 203) do event
        (event.action == Keyboard.press && event.key == Keyboard.escape) || return Consume(false)
        ctrl.ignore_keys() && return Consume(false)
        return Consume(_close_overlay!(o))
    end)
    push!(listeners, on(ev.mouseposition, priority = 3) do p
        _hover_camera!(o, Point2f(p))
        return Consume(false)
    end)
    push!(listeners, on(_ -> _arrange_overlay!(o), gui.ax.scene.viewport))
    push!(listeners, on(_ -> _arrange_overlay!(o), ev.tick))
    _arrange_overlay!(o)
    return nothing
end
