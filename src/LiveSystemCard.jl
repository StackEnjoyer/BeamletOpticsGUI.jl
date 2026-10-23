#=
The card of a system, the system widget of both layouts (floating in the compact layout, docked in
the inspector of the app layout): its name and its members in the head, its tracing, "+" and "−",
which pick its members with the mouse (see `_set_member_pick!`), the list of its members and, at
the bottom, its rays and "Remove system"
=#

# The members that the card of a system lists at most, then "… n more", such that the card stays
# inside the window
const _MEMBER_ROWS = 10
# The longest name of a member in the list, longer ones are shortened: a `Label` does not ellipsize
const _MEMBER_NAME_LENGTH = 26
# Width of the list of the members on a floating card [px], which is the width of its rows; on a
# docked card, the list is as wide as the sidebar
const _MEMBER_LIST_WIDTH = 272
# Height of a row of the list of the members [px]
const _MEMBER_ROW_HEIGHT = 26
# What the list shows instead of the members of an empty system
const _MEMBERS_EMPTY = "No members yet. Press + and click components or sources, or place new ones from the catalog."

# Systems (inspected, see `_inspect!`): no rows of their own. The rows of the system widget need
# the view, e.g. the list of the members, and come with `_system_rows`; the rows of a method for an
# own system type are shown between the members and the last row
card_rows(::BMO.AbstractSystem) = ()

# Systems: next to the eye, the system in a window of its own, see `open_system`. "Remove system"
# is in the last row of the card, see `_system_rows`
card_actions(sys::BMO.AbstractSystem) = (invoke(card_actions, Tuple{Any}, sys)...,
    CardWidget(_IconButton; name = :open, icon = :window, tooltip = "Open in a window of its own",
        on = (gui, s, _) -> _open_system!(gui, s)))

# A system is renamed in the title of its card, see `_TitleEdit`
_renamable(::BMO.AbstractSystem) = true
_rename!(gui::LiveView, sys::BMO.AbstractSystem, name) = _rename_system!(gui, sys, name)

"""
The line below the name of the system `sys` on its card: its top-level objects and its sources,
e.g. "System · 3 objects · 1 source", or "System · empty".
"""
function _card_subtitle(gui::LiveView, sys::BMO.AbstractSystem)
    objects, sources = length(sys.objects), length(_sources_of(gui, sys))
    objects + sources == 0 && return "System · empty"
    return "System · $objects $(objects == 1 ? "object" : "objects") · " *
           "$sources $(sources == 1 ? "source" : "sources")"
end

"""
    _system_rows(gui, sys) -> Tuple

The rows of the card of the system `sys` of the `gui`, the system widget, below its head (its name,
which the pencil renames, see `_rename_system!`, the eye, the window of its own and the pin):

- the section "TRACE": a chip with the state of its beams ("up to date" with the duration of the
  last solve, "outdated", "no source", see `_trace_chip`), the toggle of its auto tracing (see
  `_set_system_auto!`) and the button "Trace" (see `_trace_system!`), which is filled with the
  accent color while its beams are outdated, see `_system_stale`
- the section "MEMBERS": the number of its members and the buttons "+" and "−", which pick its
  members with the mouse (see `_set_member_pick!`) and are shown pressed while they do; below
  them, while they do, what a click does
- the list of its members, see `_MemberList`
- the rows of [`card_rows`](@ref), none by default
- below a line: the rays of its sources per solve and "Remove system", see `_remove_system!`

The rows depend on the members and on the pick, hence the cards of a system are built again when
these change, see `_sync_system_cards!`.
"""
function _system_rows(gui::LiveView, sys::BMO.AbstractSystem)
    muted = _ThemeColor(:muted)
    section(text) = CardWidget(Label; text, font = :bold, fontsize = 11, color = muted, halign = :left)
    # takes the free width of its row, such that what follows is at the right edge
    spacer() = CardWidget(Box; visible = false, height = 1)
    trace = CardRow(
        CardWidget(_Chip; name = :trace_state, value = _trace_chip),
        spacer(), CardWidget(Label; text = "auto", color = muted),
        CardWidget(Toggle; name = :auto_trace, value = (gui, s) -> _system_auto(gui, s),
            on = (gui, s, v) -> _set_system_auto!(gui, s, Bool(v))),
        CardWidget(Button; name = :trace, label = "Trace", width = 48, value = _trace_look,
            on = (gui, s, _) -> _trace_system!(gui, s)))
    members = CardRow(section("MEMBERS"),
        CardWidget(_Chip; name = :member_count, height = 18, strokewidth = 1, padding = (6, 6, 0, 0),
            value = _count_chip),
        spacer(), _pick_button(:member_add, "+", true), _pick_button(:member_remove, "−", false))
    hint = isnothing(_pick_hint(gui, sys)) ? () :
           (CardRow(CardWidget(_Chip; name = :member_hint, height = 26, cornerradius = 6,
        value = _hint_chip)),)
    n = _member_counts(gui, sys)
    list = CardRow(CardWidget(_MemberList; name = :members, rows = n.shown, outs = n.buttons,
        more = n.total > n.shown, value = _member_value, on = _on_member!))
    line = CardRow(CardWidget(Box; height = 1, color = _ThemeColor(:border), strokevisible = false))
    last = CardRow(CardWidget(Label; name = :rays, color = muted, halign = :left, value = _rays_per_solve),
        spacer(),
        CardWidget(_IconButton; name = :remove, icon = :trash, label = "Remove system",
            icon_color = _ThemeColor(:danger), tooltip = "Removes the system, its members stay in the view",
            on = (gui, s, _) -> _remove_system!(gui, s)))
    return (CardRow(section("TRACE")), trace, members, hint..., list, card_rows(sys)..., line, last)
end

# The card of a system has one page, see `_has_page`
_page_rows(gui::LiveView, sys::BMO.AbstractSystem, ::Val{:pose}) = _system_rows(gui, sys)

# The rays of the sources of the system `sys` that are switched on, as in the info label
function _rays_per_solve(gui::LiveView, sys)
    n = _on_ray_count(gui, filter(p -> p.first === sys, gui.pairs))
    return "$n $(n == 1 ? "ray" : "rays") per solve"
end

#=
Chips and buttons that show a state
=#

"""
    _Chip(pos; height = 22, cornerradius = height / 2, strokewidth = 0, fontsize = 11,
          padding = (9, 9, 0, 0), kwargs...)

A chip of a card at the grid position `pos`, a widget of the card (see [`CardWidget`](@ref)) that
takes no input: a `label` on a `box` with round ends, which shows a state in its text and its
colors, a `_ChipLook`, see `card_show!`. E.g. the state of the tracing of a system. A `Label`
instead of a `Button`: with Makie 0.24, a button whose label changes right after it was built
draws it distorted.
"""
struct _Chip
    box::Box
    label::Label
end

function _Chip(pos; height::Real = 22, cornerradius::Real = height / 2, strokewidth::Real = 0,
        fontsize::Real = 11, padding = (9, 9, 0, 0), kwargs...)
    box = Box(pos; height, cornerradius, strokewidth, color = _TRANSPARENT, strokecolor = _TRANSPARENT)
    # in the middle of the box: both are in the middle of their cell
    label = Label(pos, " "; fontsize, padding, kwargs...)
    return _Chip(box, label)
end

Base.delete!(c::_Chip) = (delete!(c.box); delete!(c.label); nothing)

"""
    _ChipLook(text, background, color, stroke)

The value of a `_Chip` of a card: its `text`, the color of its `background`, of its text (`color`)
and of its `stroke`, see `_chip`.
"""
struct _ChipLook
    text::String
    background::RGBAf
    color::RGBAf
    stroke::RGBAf
end

function card_show!(c::_Chip, v::_ChipLook)
    _set_text!(c.label, v.text)
    _update!(c.label.color, v.color)
    _update!(c.box.color, v.background)
    _update!(c.box.strokecolor, v.stroke)
    return nothing
end

"""
    _chip(text, background, color, stroke = background) -> _ChipLook

What a chip with the `text` shows, in the colors of the tokens of a theme.
"""
_chip(text::String, background, color, stroke = background) =
    _ChipLook(text, _rgba(background), _rgba(color), _rgba(stroke))

"""
    _ButtonLook(colors, text, stroke)

The value of a `Button` of a card that shows a state in its colors, see `card_show!`: the `colors`
of its background (idle, under the mouse and pressed), of its `text` and of its `stroke`. E.g. the
button "Trace" of a system, which is filled while its beams are outdated.
"""
struct _ButtonLook
    colors::NTuple{3, RGBAf}
    text::RGBAf
    stroke::RGBAf
end

function card_show!(b::Button, v::_ButtonLook)
    foreach((o, c) -> _update!(o, c), (b.buttoncolor, b.buttoncolor_hover, b.buttoncolor_active), v.colors)
    foreach(o -> _update!(o, v.text), (b.labelcolor, b.labelcolor_hover, b.labelcolor_active))
    _update!(b.strokecolor, v.stroke)
    return nothing
end

"""
    _trace_chip(gui, sys) -> _ChipLook

The chip of the tracing of the system `sys` on its card, in the color tokens of the theme: "no
source" for a system without a source, "outdated" while its beams are (see `_system_stale`), else
"up to date" with the duration of the last solve. While a solve runs in the background,
`_TRACING_VALUE`.
"""
function _trace_chip(gui::LiveView, sys)
    t = gui.layout.theme
    _tracing(gui) && return _chip(_TRACING_VALUE, t.chip, t.chip_text)
    isempty(_sources_of(gui, sys)) && return _chip("no source", t.chip, t.chip_text)
    _system_stale(gui, sys) && return _chip("● outdated", t.stale_soft, t.stale_text)
    time = gui.trace.solve_time
    return _chip("● up to date" * (time > 0 ? " · $(_ms_string(time))" : ""), t.ok_soft, t.ok_text)
end

# The number of the members of the system `sys`, next to the label of their section
function _count_chip(gui::LiveView, sys)
    t = gui.layout.theme
    return _chip(string(length(_members(gui, sys))), t.sidebar, t.muted, t.border)
end

# The button "Trace" of the system `sys`: filled with the accent color while its beams are outdated
function _trace_look(gui::LiveView, sys)
    t = gui.layout.theme
    _system_stale(gui, sys) || return _ButtonLook(_rgba.((t.field, t.hover, t.accent_soft)),
        _rgba(t.text), _rgba(t.border))
    return _ButtonLook(_rgba.((t.accent, t.accent, t.accent_soft)), _rgba(t.on_accent), _rgba(t.accent))
end

#=
"+" and "−"
=#

"""
    _Pressed(on, theme)

The value of a `Button` of a card that is shown pressed while `on`, in the color tokens `theme` of
the live view, e.g. "+" of a system while its members are picked, see `card_show!`.
"""
struct _Pressed
    on::Bool
    theme::NamedTuple
end

function card_show!(b::Button, v::_Pressed)
    t = v.theme
    color = Makie.to_color(v.on ? t.accent : t.text)
    foreach(c -> _update!(c, color), (b.labelcolor, b.labelcolor_hover, b.labelcolor_active))
    _update!(b.buttoncolor, Makie.to_color(v.on ? t.accent_soft : t.field))
    _update!(b.strokecolor, Makie.to_color(v.on ? t.accent : t.border))
    return nothing
end

# The button "+" (`add`) or "−" of the card of a system, pressed while it picks, see `_set_member_pick!`
_pick_button(name::Symbol, label::String, add::Bool) = CardWidget(Button; name, label, width = 26,
    value = (gui, s) -> _Pressed(_picks(gui, s, add), gui.layout.theme),
    on = (gui, s, _) -> _set_member_pick!(gui, s, add))

# Whether the members of the system `sys` of the `gui` are picked, with `add` or not
function _picks(gui::LiveView, sys, add::Bool)
    pick = _member_pick(gui)
    return !isnothing(pick) && pick.sys === sys && pick.add == add
end

# What a click does while the members of the system `sys` of the card are picked, `nothing` without
# a pick
function _pick_hint(gui::LiveView, sys)
    pick = _member_pick(gui)
    (isnothing(pick) || pick.sys !== sys) && return nothing
    return pick.add ? "Click a component or a source to add it · Esc ends" :
           "Click a member to take it out · Esc ends"
end

# The line below "+" and "−" while they pick, see `_pick_hint`
function _hint_chip(gui::LiveView, sys)
    t = gui.layout.theme
    return _chip(something(_pick_hint(gui, sys), " "), t.accent_soft, t.text)
end

#=
The list of the members
=#

"""
The members of the system `sys` of the `gui`, in the order of its card: its sources (see
`_sources_of`), then its top-level objects.
"""
_members(gui::LiveView, sys::BMO.AbstractSystem) = Any[_sources_of(gui, sys)..., sys.objects...]

# The members of the list (see `_MEMBER_ROWS`) and how many of them are taken out by their "×":
# of a `StaticSystem` only the sources, since its objects can not be changed
function _member_counts(gui::LiveView, sys::BMO.AbstractSystem)
    sources, objects = length(_sources_of(gui, sys)), length(sys.objects)
    shown = min(sources + objects, _MEMBER_ROWS)
    return (; total = sources + objects, shown, buttons = sys isa BMO.System ? shown : min(sources, shown))
end

"""
    _MemberItem(kind, name, systems)

A member of a system in the list of its card: the `kind` of its icon (see `_tree_kind`), its
`name` and the number of the `systems` that it is a member of.
"""
struct _MemberItem
    kind::Symbol
    name::String
    systems::Int
end

"""
    _MemberValue(items, more)

The value of the list of the members of a system on its card, see `_MemberList`: the `items` of
its rows and the number of the members that it does not list (`more`).
"""
struct _MemberValue
    items::Vector{_MemberItem}
    more::Int
end

# The parts of a row of the list of the members that change with the member
struct _MemberRow
    icon::Observable{BezierPath}
    icon_color::Observable{RGBAf}
    name::Label
    badge::Label
    badge_shown::Observable{Bool}
    out::Union{Nothing, _IconButton}
end

"""
    _MemberList(pos; rows, outs, more, theme, width = nothing)

The list of the members of a system on its card, a widget of the card (see [`CardWidget`](@ref))
at the grid position `pos`, in the color tokens `theme`: a box in the field color with a border and
a row per member, `rows` of them, each with the icon of its kind, its name, the number of its
systems if it is a member of several, and, in the first `outs` rows, "×", which takes it out of the
system. The row under the mouse has the hover color (`hovered`, 0 for none). With `more`, a last
line tells how many members are not listed. Without rows, i.e. for an empty system, a dashed box
says how it gets members. `width` is the width of the list [px], `nothing` fills the width of the
card.

A click on a row sets `event` to `(:select, i)`, a click on its "×" to `(:out, i)`, the input of
the widget, see `card_input`; `card_show!` shows a `_MemberValue`, whose items the list keeps in
`items`. The list has a fixed number of rows: a card whose system has another number of members is
built again, see `_sync_system_cards!`.
"""
mutable struct _MemberList
    const grid::GridLayout
    const rows::Vector{_MemberRow}
    const outs::Int
    const more::Union{Nothing, Label}
    const theme::NamedTuple
    const event::Observable{Tuple{Symbol, Int}}
    const hovered::Observable{Int}
    items::Vector{_MemberItem}
    # the number of the members that are not listed, as shown
    rest::Int
end

function _MemberList(pos; rows::Int, outs::Int, more::Bool, theme::NamedTuple,
        width::Union{Nothing, Real} = nothing, tooltip_placement::Symbol = :below)
    t = theme
    grid = isnothing(width) ? GridLayout(pos; default_rowgap = 0, tellwidth = false) :
           GridLayout(pos; default_rowgap = 0, width, halign = :left)
    event = Observable((:none, 0))
    hovered = Observable(0)
    built = _MemberRow[]
    if rows == 0
        # an empty system: how it gets members
        Box(grid[1, 1]; color = _TRANSPARENT, strokecolor = t.muted, strokewidth = 1, linestyle = :dash,
            cornerradius = 6)
        Label(grid[1, 1], _MEMBERS_EMPTY; color = t.chip_text, fontsize = 11.5, word_wrap = true,
            halign = :left, justification = :left, tellwidth = false, padding = (10, 10, 10, 10))
        return _MemberList(grid, built, 0, nothing, t, event, hovered, _MemberItem[], 0)
    end
    n = rows + more
    Box(grid[1:n, 1]; color = t.field, strokecolor = t.border, strokewidth = 1, cornerradius = 6)
    hover, clear = _rgba(t.hover), _TRANSPARENT
    for i in 1:rows
        # the hover color inside the border of the box
        back = Box(grid[i, 1]; color = Makie.lift(h -> h == i ? hover : clear, hovered),
            strokevisible = false, cornerradius = 0, alignmode = Makie.Outside(1))
        g = GridLayout(grid[i, 1]; default_colgap = 6, alignmode = Makie.Outside(9, 4, 0, 0))
        icon, icon_color = _card_icon!(g[1, 1]; size = 16)
        name = Label(g[1, 2], " "; color = t.text, fontsize = 12, halign = :left, tellwidth = false)
        # the number of the systems of a member of several ones, in a frame
        badge_shown = Observable(false)
        Box(g[1, 3]; color = _TRANSPARENT, strokecolor = t.border, strokewidth = 1, cornerradius = 8,
            visible = badge_shown, height = 16)
        badge = Label(g[1, 3], ""; color = t.muted, fontsize = 10.5, padding = (6, 6, 0, 0))
        out = i <= outs ? _IconButton(g[1, 4]; icon = :close, tooltip = "Take out of the system",
            _icon_theme(t)..., icon_color = t.muted, size = 22, icon_size = 13, tooltip_placement) : nothing
        Makie.colsize!(g, 2, Makie.Auto())
        Makie.rowsize!(grid, i, Makie.Fixed(_MEMBER_ROW_HEIGHT))
        isnothing(out) || on(_ -> (event[] = (:out, i)), back.blockscene, out.clicks)
        # The row under the mouse and a click on it, beside its "×"
        mouse = Makie.addmouseevents!(back.blockscene, back.layoutobservables.computedbbox)
        on(back.blockscene, mouse.obs) do e
            type = e.type
            if type === Makie.MouseEventTypes.enter
                hovered[] = i
            elseif type === Makie.MouseEventTypes.out
                hovered[] == i && (hovered[] = 0)
            elseif type in (Makie.MouseEventTypes.leftclick, Makie.MouseEventTypes.leftdoubleclick)
                (isnothing(out) || !out.hovered[]) && (event[] = (:select, i))
            end
            return Consume(false)
        end
        push!(built, _MemberRow(icon, icon_color, name, badge, badge_shown, out))
    end
    rest = more ? Label(grid[n, 1], " "; color = t.muted, fontsize = 12, halign = :left,
        tellwidth = false, padding = (10, 10, 4, 4)) : nothing
    return _MemberList(grid, built, outs, rest, t, event, hovered, _MemberItem[], 0)
end

# Deleted with the widgets of its card, see `_clear_content!`
function Base.delete!(l::_MemberList)
    foreach(delete!, _blocks!(Any[], l.grid))
    content = _GLB.gridcontent(l.grid)
    isnothing(content) || _GLB.remove_from_gridlayout!(content)
    return nothing
end

card_input(l::_MemberList) = l.event

function card_show!(l::_MemberList, v::_MemberValue)
    for (row, item) in zip(l.rows, v.items)
        _update!(row.icon, _icon(item.kind))
        _update!(row.icon_color, _rgba(_tree_marker_color(l.theme, item.kind)))
        _set_text!(row.name, item.name)
        _set_text!(row.badge, item.systems > 1 ? string(item.systems) : "")
        _update!(row.badge_shown, item.systems > 1)
    end
    _set_text!(l.more, "… $(v.more) more")
    l.items, l.rest = v.items, v.more
    return nothing
end

# The list on a floating card, in its theme and of a fixed width; the tooltips of its buttons are
# relative to the translation of the card, see `_fix_tooltip!`
_card_style(t::NamedTuple, ::Type{_MemberList}) = (; theme = t, width = _MEMBER_LIST_WIDTH)
function _fix_caret!(::_ComponentCard, l::_MemberList)
    foreach(row -> isnothing(row.out) || _fix_tooltip!(row.out), l.rows)
    return nothing
end
# The list on a docked card is as wide as the sidebar
_card_style(c::_DockedCard, ::Type{_MemberList}) = (; theme = c.theme, tooltip_placement = :left)

# The name of the member `x` in the list of the card of a system
function _member_name(gui::LiveView, @nospecialize(x))
    name = _label(gui, x)
    return length(name) <= _MEMBER_NAME_LENGTH ? name : first(name, _MEMBER_NAME_LENGTH - 1) * "…"
end

# The systems that the member `x` belongs to: a source to one
_member_count(::LiveView, ::_Source) = 1
_member_count(gui::LiveView, @nospecialize(x)) = length(_member_systems(gui, x))

"""
    _member_value(gui, sys) -> _MemberValue

What the list of the members of the system `sys` shows on its card (see `_members`): its first
`_MEMBER_ROWS` members and the number of the others.
"""
function _member_value(gui::LiveView, sys)
    members = _members(gui, sys)
    items = _MemberItem[]
    for x in Iterators.take(members, _MEMBER_ROWS)
        push!(items, _MemberItem(_tree_kind(x), _member_name(gui, x), _member_count(gui, x)))
    end
    return _MemberValue(items, max(length(members) - _MEMBER_ROWS, 0))
end

# An input of the list of the members of the system `sys`, see `_MemberList`
function _on_member!(gui::LiveView, sys, event::Tuple{Symbol, Int})
    kind, i = event
    kind === :out ? _take_out_member!(gui, sys, i) : kind === :select ? _select_member!(gui, sys, i) : nothing
    return nothing
end

"""
    _select_member!(gui, sys, i)

A click on the row of the member `i` of the list of the card of the system `sys` (see `_members`):
the member is selected like by a click on its row of the object tree, or inspected if it is not
movable, which closes the card of the system. While the members of a system are picked, it is
picked instead, see `_pick_shown!`.
"""
function _select_member!(gui::LiveView, sys::BMO.AbstractSystem, i::Int)
    members = _members(gui, sys)
    i <= length(members) || return nothing
    x = members[i]
    _is_movable(gui.controls, x) ? _select!(gui, x) : _inspect!(gui, x)
    return nothing
end

"""
    _take_out_member!(gui, sys, i)

"×" of the member `i` of the list of the card of the system `sys` (see `_members`): a source has no
system afterwards (see `_set_source_system!`), an object is taken out of `sys` and stays in the
view (see `_remove_member!`). What can not be done only shows a message in the status line.
"""
function _take_out_member!(gui::LiveView, sys::BMO.AbstractSystem, i::Int)
    members = _members(gui, sys)
    i <= length(members) || return nothing
    try
        _take_out!(gui, members[i], sys)
    catch e
        e isa ArgumentError || rethrow()
        gui.status.text[] = e.msg
    end
    _on_members_changed!(gui)
    return nothing
end

_take_out!(gui::LiveView, src::_Source, _) = _set_source_system!(gui, src, nothing)
function _take_out!(gui::LiveView, @nospecialize(obj), sys)
    sys isa BMO.System || throw(ArgumentError(
        "$(_label(gui, sys)) is a $(nameof(typeof(sys))), its objects can not be changed"))
    _remove_member!(gui, obj, sys)
    return nothing
end

#=
The name
=#

"""
    _rename_system!(gui, sys, name)

Names the system `sys` of the `gui` `name`, the input of the textbox of the title of its card: in
the component menu, the object tree, the catalog and on the cards. An empty name only shows a
message in the status line.
"""
function _rename_system!(gui::LiveView, sys::BMO.AbstractSystem, name)
    name = strip(something(name, ""))
    old = _label(gui, sys)
    if isempty(name)
        gui.status.text[] = "enter a name for $old"
    elseif name != old
        gui.labels[sys] = gui.objects.names[sys] = String(name)
        h = _system_handle(gui, sys)
        isnothing(h) || (gui.objects.names[h] = String(name))
        _refresh_menu_options!(gui, gui.widgets.menu)
        _on_components_changed!(gui)
        _refresh_catalog!(gui)
        # The linked views share the names, see `_ViewLinks`
        _refresh_links!(gui)
        _show_member_pick!(gui)
        gui.status.text[] = "$old renamed to $name"
    end
    _update_inspector!(gui; force = true)
    _update_cards!(gui)
    return nothing
end

#=
Cards that follow the members
=#

# What the card `c` of the system `sys` was built for: the rows of its list, those with "×",
# whether it tells of more members, and whether it shows what a pick does; `nothing` for a card
# without a list, e.g. a collapsed one
function _built_members(c::_AbstractCard)
    list = _card_widget(c, :members)
    list isa _MemberList || return nothing
    return (length(list.rows), list.outs, !isnothing(list.more), !isnothing(_card_widget(c, :member_hint)))
end

"""
    _sync_system_cards!(gui)

Builds the cards of the systems of the `gui` again whose rows are not those of their system any
more (see `_system_rows`), e.g. after a component was added, removed or picked or a pick started:
the floating cards and the docked ones of a layout. A card that lists other members in the same
rows, e.g. after an undo, shows their values. Called every frame and after the changes of the card
itself; a card that is up to date costs the comparison of its list.
"""
function _sync_system_cards!(gui::LiveView)
    changed = false
    for c in _edit_cards(gui)
        sys = _card_object(gui, c)
        sys isa BMO.AbstractSystem || continue
        # only a card whose widgets were built for this system, see `_update_card!`
        (isnothing(c.pose) || c.pose[1] !== sys) && continue
        n = _member_counts(gui, sys)
        wanted = (n.shown, n.buttons, n.total > n.shown, !isnothing(_pick_hint(gui, sys)))
        if _built_members(c) == wanted
            # the same rows for other members, e.g. after an undo
            value = _member_value(gui, sys)
            list = _card_widget(c, :members)
            (list.items == value.items && list.rest == value.more) && continue
            _refresh_card!(gui, c)
            changed = true
            continue
        end
        # e.g. a collapsed card, which shows no rows
        actions, rows = _declarations(gui, c, sys)
        (_layout_key(actions), _layout_key(rows)) == c.content_key && continue
        _rebuild_card!(gui, c)
        changed = true
    end
    # what a layout shows of a system beside its card, e.g. the line below its name in the inspector
    changed && _refresh_inspector!(gui)
    return nothing
end

"""
Builds the widgets of the card `c` of the `gui` again from the declarations of its object, which
changed: like a card that is switched to its page (see `_set_page!`), which every host of a card
implements, also for a part that is not shown.
"""
function _rebuild_card!(gui::LiveView, c::_AbstractCard)
    page = c.page
    c.page = :rebuild
    try
        _set_page!(gui, c, page)
    finally
        c.page === :rebuild && (c.page = page)
    end
    return nothing
end

"""
Called after the members of a system of the `gui` changed by its card or by a pick: the cards of
the systems list them again, show their values, and the highlight of the pick follows.
"""
function _on_members_changed!(gui::LiveView)
    _sync_system_cards!(gui)
    _update_system_highlight!(gui)
    _update_inspector!(gui)
    return nothing
end
