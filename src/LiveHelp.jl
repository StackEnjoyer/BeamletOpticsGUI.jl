#=
Help of the live view: the help pill, the chips of the mode and the keyboard step next to it and
the help card with the keys of the controls, in both layouts, see `_HelpUI`
=#

using Makie: rich

# Gap between the columns of the help card and between the key caps of an entry [px]
const _HELP_COLGAP = 28
const _HELP_CAP_GAP = 3
# z translation of the scene of the help card: over everything else, i.e. the cards with their
# tooltips (`_CARD_Z` + `_CARD_TOOLTIP_DZ`), the selection card of groups and the windows of the
# live view, within the clip range ±10000 of the pixel camera
const _HELP_Z = 9970.0f0
# Priority of the listeners that keep the presses and the scrolling on the help card from
# everything below it: before the controls (200), the placement (210), the cards (250), the tool
# rail of the compact layout (260) and the view cube, the tree and the dock (300)
const _HELP_PRIORITY = 310

"""
A scene with a pixel camera over the whole figure of the overlay `scene`, translated to `_HELP_Z`,
for the help card, which is drawn over everything else.
"""
function _help_scene(scene::Scene)
    top = Scene(scene.parent; camera = Makie.campixel!, clear = false)
    translate!(top, 0, 0, _HELP_Z)
    return top
end

"""
    _HelpUI(scene, theme, ax, pill, pill_button)
    _HelpUI(scene, theme, ax)

The help of the live view over the 3D view `ax`, built from `_OverlayPart`s in the `scene` of an
overlay (see `_overlay_scene`) in the colors of the `theme` tokens:

- `pill`: the help pill at the top left ("? h keys", see `_help_pill`), whose `pill_button`
  opens and closes the help card like the key `h`
- `chips`, right of the pill: the mode (`mode_button`, a click switches it like the key `m`), the
  keyboard step (`step_label`, changed by the `step_buttons` "+" and "−" like the keys) and the
  snapping onto beams (`snap_button`, which names its state; a click switches it to the next one
  like the key `Tab`, see `_cycle_snap!`). In
  the spectator mode, the part `spectator` is shown instead, whose `spectator_button` switches
  back to the edit mode like the key `v`.
- `card`: the help card below the pill, shown while `shown`: the sections of `_help_sections` in
  columns (see `_help_columns`), each entry with its key caps (see `_help_cap!`) and its text; the
  `close_button` in its head closes it. It lies in a scene of its own over everything else (see
  `_help_scene`), e.g. over a card at the same place, and what lies below it gets neither its
  presses nor its scrolling, see `_connect_help!`. Its `body` holds the `blocks` of the sections, which are
  rebuilt when the keys of the entries change (`keys`, e.g. in the spectator mode or after
  [`add_tool!`](@ref) with a key), otherwise only the `texts` are updated, e.g. the step.

While `hidden`, all parts are moved away (see `_park!`), e.g. while a menu is open that they
would cover. See `_update_help_ui!` and `_arrange_help!`.
"""
mutable struct _HelpUI
    const scene::Scene
    const theme::NamedTuple
    const ax::LScene
    const pill::_OverlayPart
    const pill_button::_OverlayItem
    const chips::_OverlayPart
    const mode_button::Button
    const step_label::Label
    const step_buttons::NTuple{2, Button}
    const snap_button::Button
    const spectator::_OverlayPart
    const spectator_button::Button
    const card::_OverlayPart
    const close_button::_OverlayItem
    body::Union{Nothing, GridLayout}
    const blocks::Vector{Any}
    const texts::Vector{Label}
    keys::Any
    shown::Bool
    hidden::Bool
end

_HelpUI(scene::Scene, t::NamedTuple, ax::LScene) = _HelpUI(scene, t, ax, _help_pill(scene, t)...)

function _HelpUI(scene::Scene, t::NamedTuple, ax::LScene, pill::_OverlayPart,
        pill_button::_OverlayItem)
    # Chips of the edit mode: the mode and the keyboard step
    chips = _help_chips(scene, t)
    g = chips.content
    mode_button = _help_button(g[1, 1], t, "Move"; accent = true)
    _help_cap!(g[1, 2], t, "M")
    Box(g[1, 3]; width = 1, height = 14, color = t.border, strokewidth = 0)
    step_label = Label(g[1, 4], "step"; _card_style(t, Label)...)
    step_buttons = (_help_button(g[1, 5], t, "+"), _help_button(g[1, 6], t, "−"))
    Box(g[1, 7]; width = 1, height = 14, color = t.border, strokewidth = 0)
    snap_button = _help_button(g[1, 8], t, _snap_label(:off))
    _help_cap!(g[1, 9], t, "Tab")
    # Chip of the spectator mode
    spectator = _help_chips(scene, t)
    g = spectator.content
    spectator_button = _help_button(g[1, 1], t, "Spectator"; accent = true)
    _help_cap!(g[1, 2], t, "V")
    Label(g[1, 3], "camera only"; _card_style(t, Label)..., color = t.muted)
    # Help card: the head, the sections are built by `_build_help!`; in a scene of its own, over
    # the cards, and opaque, such that what it covers does not shine through
    card = _OverlayPart(_help_scene(scene), t; color = _rgba(t.sidebar, 1.0),
        padding = (14, 14, 12, 12), default_rowgap = 10)
    head = GridLayout(card.content[1, 1]; default_colgap = 6)
    Label(head[1, 1], "Keys and mouse"; _card_style(t, Label)..., fontsize = 13, font = :bold,
        halign = :left)
    Label(head[1, 2], ""; tellwidth = false)
    _help_cap!(head[1, 3], t, "H")
    Label(head[1, 4], "closes"; _card_style(t, Label)..., fontsize = 11, color = t.muted)
    close_button = _OverlayItem(head[1, 5], t; icon = :close, size = 22, icon_size = 14,
        padding = (0, 0, 0, 0), icon_color = t.muted)
    return _HelpUI(scene, t, ax, pill, pill_button, chips, mode_button, step_label, step_buttons,
        snap_button, spectator, spectator_button, card, close_button, nothing,
        Any[], Label[], nothing, false, false)
end

# A pill-shaped part for the chips next to the help pill, as high as the pill
_help_chips(scene::Scene, t::NamedTuple) =
    _OverlayPart(scene, t; cornerradius = 13, padding = (8, 8, 2, 2), default_colgap = 6)

"""A small button of the chips with the `label`, in the accent color with `accent`."""
function _help_button(pos, t::NamedTuple, label::AbstractString; accent::Bool = false)
    color = accent ? t.accent : t.text
    return Button(pos; label, _card_style(t, Button)..., height = 18, fontsize = accent ? 12 : 11,
        font = :bold, padding = (6, 6, 1, 1), labelcolor = color, labelcolor_hover = color,
        labelcolor_active = color, buttoncolor = accent ? t.accent_soft : t.field,
        strokecolor = accent ? t.accent_soft : t.border)
end

"""
    _help_cap!(pos, t, key) -> (Box, Label)

A key cap with the name `key` at the grid position `pos`, or, for `:mouse => name`, the rounded
chip of an action of the mouse, see `_HelpEntry`.
"""
function _help_cap!(pos, t::NamedTuple, key)
    mouse = key isa Pair
    box = Box(pos; color = mouse ? t.accent_soft : t.field,
        strokecolor = mouse ? t.accent_soft : t.border, strokewidth = 1,
        cornerradius = mouse ? 9 : 4)
    label = Label(pos, String(mouse ? last(key) : key); fontsize = 11,
        font = mouse ? :regular : :bold, color = mouse ? t.accent : t.text, padding = (6, 6, 2, 2))
    return box, label
end

# The text of an entry, the word of its gizmo axis in the color of the axis
function _help_rich(t::NamedTuple, e::_HelpEntry)
    i = findfirst(==(e.color), ("red", "green", "blue"))
    (isnothing(i) || !occursin(e.color, e.text)) && return e.text
    before, after = split(e.text, e.color; limit = 2)
    return rich(String(before), rich(e.color; color = t.gizmo[i], font = :bold), String(after))
end

"""
    _help_columns(sections) -> Vector{Vector{_HelpSection}}

Splits the `sections` of the help in their order into the two columns of the help card, such that
the longer column has as few rows as possible (a title and a row per entry; the first such split);
a single section stays alone.
"""
function _help_columns(sections)
    length(sections) < 2 && return [sections]
    rows = [1 + length(s.second) for s in sections]
    k = argmin(k -> max(sum(rows[1:k]), sum(rows[(k + 1):end])), 1:(length(sections) - 1))
    return [sections[1:k], sections[(k + 1):end]]
end

# What decides the widgets of the card: the keys of the entries of each section
_help_keys(sections) = [[(e.keys, e.combo) for e in entries] for (_, entries) in sections]

"""
    _show_help_sections!(help, sections)

Shows the `sections` (see `_help_sections`) on the card of the `help`: only the texts are updated
if the keys of the entries are those of the card, otherwise its widgets are built again.
"""
function _show_help_sections!(help::_HelpUI, sections)
    keys = _help_keys(sections)
    keys == help.keys || return _build_help!(help, sections, keys)
    texts = Iterators.Stateful(help.texts)
    for (title, entries) in sections
        _update!(popfirst!(texts).text, uppercase(title))
        foreach(e -> (popfirst!(texts).text[] = _help_rich(help.theme, e)), entries)
    end
    return nothing
end

function _build_help!(help::_HelpUI, sections, keys)
    t = help.theme
    foreach(delete!, help.blocks)
    empty!(help.blocks)
    empty!(help.texts)
    GLB = Makie.GridLayoutBase
    isnothing(help.body) || GLB.remove_from_gridlayout!(GLB.gridcontent(help.body))
    body = help.body = GridLayout(help.card.content[2, 1]; default_colgap = _HELP_COLGAP,
        halign = :left, valign = :top)
    label!(args...; kwargs...) = (l = Label(args...; _card_style(t, Label)..., halign = :left, kwargs...);
        push!(help.blocks, l); push!(help.texts, l); l)
    for (c, column) in enumerate(_help_columns(sections))
        grid = GridLayout(body[1, c]; default_rowgap = 4, default_colgap = 10, valign = :top)
        r = 0
        for (title, entries) in column
            label!(grid[r += 1, 1:2], uppercase(title); fontsize = 10, font = :bold, color = t.muted,
                tellwidth = false, padding = (0, 0, 0, r == 1 ? 0 : 8))
            for e in entries
                caps = GridLayout(grid[r += 1, 1]; default_colgap = _HELP_CAP_GAP, halign = :left)
                foreach(((k, key),) -> append!(help.blocks, _help_cap!(caps[1, k], t, key)),
                    enumerate(e.keys))
                label!(grid[r, 2], _help_rich(t, e))
            end
        end
    end
    help.keys = keys
    return nothing
end

#=
State and placement
=#

"""
    _update_help_ui!(help, ctrl)

Shows the state of the controls `ctrl` in the `help`: the mode and the keyboard step in the chips
and, while the help is shown (`ctrl.help_shown`), the help card with the sections of the `ctrl`.
The `help_view` of the controls of a live view, see `_connect_help!`.
"""
function _update_help_ui!(help::_HelpUI, ctrl::KinematicController)
    mode = ctrl.mode[]
    _update!(help.mode_button.label, uppercasefirst(String(mode)))
    _update!(help.step_label.text, "step " * _step_string(mode, ctrl.fine_step, ctrl.fine_angle))
    _show_snap_chip!(help, ctrl.snap[])
    help.shown = ctrl.help_shown
    help.shown && _show_help_sections!(help, _help_sections(ctrl))
    _arrange_help!(help, ctrl.spectator[])
    return nothing
end

# The label of the chip of the snapping in the state `snap`, see `_set_snap!`
_snap_label(snap::Symbol) = snap == :off ? "Snap off" : "Snap: " * _snap_string(snap)

"""
Shows the state `snap` of the snapping of the controls in the chip of the `help`: its name, in the
accent color unless it is off, see `_set_snap!`.
"""
function _show_snap_chip!(help::_HelpUI, snap::Symbol)
    t = help.theme
    b = help.snap_button
    on = snap != :off
    _update!(b.label, _snap_label(snap))
    color = on ? t.accent : t.text
    foreach(c -> _update!(c, Makie.to_color(color)), (b.labelcolor, b.labelcolor_hover, b.labelcolor_active))
    _update!(b.buttoncolor, Makie.to_color(on ? t.accent_soft : t.field))
    _update!(b.strokecolor, Makie.to_color(on ? t.accent_soft : t.border))
    return nothing
end

"""
    _arrange_help!(help, spectator::Bool)

Places the parts of the `help` at the top left of its 3D view: the pill, right of it the chips of
the edit mode or, with `spectator`, the chip of the spectator mode, and below them the help card
while it is shown; the others, or all while the help is `hidden`, are moved away, see `_park!`.
"""
function _arrange_help!(help::_HelpUI, spectator::Bool)
    parts = (help.pill, help.chips, help.spectator, help.card)
    help.hidden && return foreach(p -> _park!(p.outer), parts)
    vp = Rect2f(Makie.viewport(help.ax.scene)[])
    _place_pill!(help.pill, vp)
    size = _card_size(help.pill.outer)
    top = Point2f(minimum(vp)[1] + _OVERLAY_MARGIN, maximum(vp)[2] - _OVERLAY_MARGIN)
    shown, other = spectator ? (help.spectator, help.chips) : (help.chips, help.spectator)
    _place!(shown.outer, top .+ Point2f(size[1] + _OVERLAY_GAP, 0))
    _park!(other.outer)
    help.shown ? _place!(help.card.outer, top .- Point2f(0, size[2] + _OVERLAY_GAP)) :
    _park!(help.card.outer)
    return nothing
end

"""The help of the live view `gui`, see `_HelpUI`."""
_help_ui(gui::LiveView) = gui.layout.help

_arrange_help!(gui::LiveView) = _arrange_help!(_help_ui(gui), gui.controls.spectator[])

"""
Returns the rectangles [figure px] of the shown parts of the `help` besides its pill: the chips and,
while it is shown, the help card.
"""
function _help_rects(help::_HelpUI)
    parked(p) = minimum(p.outer.layoutobservables.suggestedbbox[])[1] < -1.0f4
    return Rect2f[_overlay_rect(p) for p in (help.chips, help.spectator, help.card) if !parked(p)]
end

"""Returns `true` if the point `p` [figure px] is over the pill or another shown part of the `help`."""
_over_help(help::_HelpUI, p::Point2f) =
    p in _overlay_rect(help.pill) || any(r -> p in r, _help_rects(help))

"""
    _connect_help!(gui)

Connects the help of the live view `gui` (see `_HelpUI`) to its controls: the pill and the close
button of the card open and close the card like the key `h`, the chips switch the mode, change the
keyboard step, switch the snapping onto beams and leave the spectator mode like the keys `m`, `+`,
`-`, `Tab` and `v`. The help replaces
the text of the controls overlay (`help_view`) and follows the 3D view. The presses and the
scrolling on the help card are consumed before all other listeners (`_HELP_PRIORITY`).
"""
function _connect_help!(gui::LiveView)
    help = _help_ui(gui)
    ctrl = gui.controls
    listeners = ctrl.listeners
    function toggle!(_)
        ctrl.help_shown = !ctrl.help_shown
        _update_help!(ctrl)
        return nothing
    end
    push!(listeners, on(toggle!, help.pill_button.clicks))
    push!(listeners, on(toggle!, help.close_button.clicks))
    # The help card lies over everything else: a press on it reaches nothing below it, e.g. a
    # button of a card at the same place, hence the press on its close button is taken here
    ev = events(gui.ax.scene)
    over_card = () -> help.shown && !help.hidden && Point2f(ev.mouseposition[]) in _overlay_rect(help.card)
    # The buttons whose press was taken, whose release is taken as well, also once the card is closed
    taken = Set{Mouse.Button}()
    push!(listeners, on(ev.mousebutton; priority = _HELP_PRIORITY) do event
        if event.action == Mouse.release && event.button in taken
            delete!(taken, event.button)
            return Consume(true)
        end
        over_card() || return Consume(false)
        event.action == Mouse.press && push!(taken, event.button)
        close = Rect2f(help.close_button.box.layoutobservables.computedbbox[])
        if event.button == Mouse.left && event.action == Mouse.press && Point2f(ev.mouseposition[]) in close
            toggle!(nothing)
        end
        return Consume(true)
    end)
    push!(listeners, on(_ -> Consume(over_card()), ev.scroll; priority = _HELP_PRIORITY))
    push!(listeners, on(_ -> _set_mode!(gui, _other_mode(ctrl.mode[])), help.mode_button.clicks))
    push!(listeners, on(_ -> _cycle_snap!(gui), help.snap_button.clicks))
    for (button, dir) in zip(help.step_buttons, (1, -1))
        push!(listeners, on(_ -> _change_step!(ctrl, dir), button.clicks))
    end
    push!(listeners, on(_ -> _set_spectator!(ctrl, false), help.spectator_button.clicks))
    push!(listeners, on(_ -> _arrange_help!(gui), gui.ax.scene.viewport))
    ctrl.help_view = c -> _update_help_ui!(help, c)
    ctrl.help_obs[] = ""
    _update_help!(ctrl)
    return nothing
end
