#=
The card of a system, the system widget of both layouts (floating in the compact layout, docked in
the inspector of the app layout): its name, its tracing, "+" and "−", which pick its members with
the mouse (see `_set_member_pick!`), and the list of its members
=#

# The members that the card of a system lists at most, then "… n more", such that the card stays
# inside the window
const _MEMBER_ROWS = 10
# The longest name of a member in the list, longer ones are shortened: a `Label` does not ellipsize
const _MEMBER_NAME_LENGTH = 26
# Width of the labels at the start of the rows of a system [px]
const _SYSTEM_LABEL_WIDTH = 56

# The names of the widgets of the member `i` of the list: its name and its button "−"
_member_label(i::Int) = Symbol(:member_, i)
_member_button(i::Int) = Symbol(:member_out_, i)
const _MEMBER_LABELS = Set{Symbol}([map(_member_label, 1:_MEMBER_ROWS)..., :member_more])
const _MEMBER_BUTTONS = Set{Symbol}(map(_member_button, 1:_MEMBER_ROWS))

# Systems (inspected, see `_inspect!`): no pose, the number of objects, the rays of their sources and
# the duration of the last solve. The rows that need the view, e.g. the list of the members, come
# with `_system_rows`
card_rows(::BMO.AbstractSystem) = (_text_row("objects", :objects, _objects_text; width = _SYSTEM_LABEL_WIDTH),
    _text_row("rays", :rays, _rays_text; width = _SYSTEM_LABEL_WIDTH),
    _text_row("solve", :solve, _solve_text; width = _SYSTEM_LABEL_WIDTH))

# Systems: also "new window", which opens the system in a window of its own, see `open_system`.
# "remove" is in the last row of the card, like the one of a component, see `_system_rows`
card_actions(sys::BMO.AbstractSystem) = (invoke(card_actions, Tuple{Any}, sys)...,
    CardWidget(Button; name = :open, label = "new window", on = (gui, s, _) -> _open_system!(gui, s)))

"""
    _system_rows(gui, sys) -> Tuple

The rows of the card of the system `sys` of the `gui`, the system widget:

- its name in a textbox, which renames it, see `_rename_system!`
- "trace": the toggle of its auto tracing (see `_set_system_auto!`), the button "Trace" (see
  `_trace_system!`) and "outdated" while its beams are, see `_system_stale`
- "members": the buttons "+" and "−", which pick its members with the mouse (see
  `_set_member_pick!`) and are shown pressed while they do
- the list of its members, see `_member_rows`
- the rows of [`card_rows`](@ref): its objects, its rays and the last solve
- the button "remove", see `_remove_system!`

The list depends on the members, hence the cards of a system are built again when they change, see
`_sync_system_cards!`.
"""
function _system_rows(gui::LiveView, sys::BMO.AbstractSystem)
    label(text) = CardWidget(Label; text, width = _SYSTEM_LABEL_WIDTH, halign = :left)
    name = CardRow(label("name"), CardWidget(Textbox; name = :system_name, placeholder = " ", width = 170,
        value = (gui, s) -> _label(gui, s), on = (gui, s, text) -> _rename_system!(gui, s, text)))
    trace = CardRow(label("trace"),
        CardWidget(Toggle; name = :auto_trace, value = (gui, s) -> _system_auto(gui, s),
            on = (gui, s, v) -> _set_system_auto!(gui, s, Bool(v))), "auto",
        CardWidget(Button; name = :trace, label = "Trace", on = (gui, s, _) -> _trace_system!(gui, s)),
        CardWidget(Label; name = :trace_state, halign = :left,
            value = (gui, s) -> _system_stale(gui, s) ? "outdated" : " "))
    members = CardRow(label("members"), _pick_button(:member_add, "+", true),
        _pick_button(:member_remove, "−", false),
        CardWidget(Label; name = :member_hint, halign = :left, value = _pick_hint))
    remove = CardRow(CardWidget(Button; name = :remove, label = "remove",
        on = (gui, s, _) -> _remove_system!(gui, s)))
    return (name, trace, members, _member_rows(gui, sys)..., card_rows(sys)..., remove)
end

# The card of a system has the same rows on all its pages, such that they stay built, see `_page_rows`
_page_rows(gui::LiveView, sys::BMO.AbstractSystem, ::Val{:pose}) = _system_rows(gui, sys)
_page_rows(gui::LiveView, sys::BMO.AbstractSystem, ::Val{:properties}) = _system_rows(gui, sys)

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

# What a click does while the members of the system `sys` of the card are picked
function _pick_hint(gui::LiveView, sys)
    pick = _member_pick(gui)
    (isnothing(pick) || pick.sys !== sys) && return " "
    return pick.add ? "click to add" : "click to take out"
end

#=
The list of the members
=#

"""
The members of the system `sys` of the `gui`, in the order of its card: its sources (see
`_sources_of`), then its top-level objects.
"""
_members(gui::LiveView, sys::BMO.AbstractSystem) = Any[_sources_of(gui, sys)..., sys.objects...]

# The members of the list (see `_MEMBER_ROWS`) and how many of them are taken out by a button "−":
# of a `StaticSystem` only the sources, since its objects can not be changed
function _member_counts(gui::LiveView, sys::BMO.AbstractSystem)
    sources, objects = length(_sources_of(gui, sys)), length(sys.objects)
    shown = min(sources + objects, _MEMBER_ROWS)
    return (; total = sources + objects, shown, buttons = sys isa BMO.System ? shown : min(sources, shown))
end

"""
    _member_rows(gui, sys) -> Tuple

The list of the members of the system `sys` on its card (see `_members`): a row per member with its
name and a button "−", which takes it out of `sys` (see `_take_out_member!`), at most
`_MEMBER_ROWS`, then "… n more". The objects of a `StaticSystem` have no button. The rows name the
members by their place in the list, such that they only depend on the number of members.
"""
function _member_rows(gui::LiveView, sys::BMO.AbstractSystem)
    n = _member_counts(gui, sys)
    rows = CardRow[]
    for i in 1:n.shown
        name = CardWidget(Label; name = _member_label(i), width = 170, halign = :left,
            value = (gui, s) -> _member_text(gui, s, i))
        out = CardWidget(Button; name = _member_button(i), label = "−", width = 26,
            on = (gui, s, _) -> _take_out_member!(gui, s, i))
        push!(rows, i <= n.buttons ? CardRow(name, out) : CardRow(name))
    end
    n.total > n.shown && push!(rows, CardRow(CardWidget(Label; name = :member_more, halign = :left,
        value = (gui, s) -> "… $(length(_members(gui, s)) - _MEMBER_ROWS) more")))
    return Tuple(rows)
end

# The name of the member `i` of the system `sys` in the list of its card
function _member_text(gui::LiveView, sys, i::Int)
    members = _members(gui, sys)
    i <= length(members) || return " "
    name = _label(gui, members[i])
    return length(name) <= _MEMBER_NAME_LENGTH ? name : first(name, _MEMBER_NAME_LENGTH - 1) * "…"
end

"""
    _take_out_member!(gui, sys, i)

"−" of the member `i` of the list of the card of the system `sys` (see `_members`): a source has no
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

Names the system `sys` of the `gui` `name`, the input of the textbox of its card: in the component
menu, the object tree, the catalog and on the cards. An empty name only shows a message in the
status line.
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

# The widgets of the list of the members on the card `c`: the names and the buttons
function _built_members(c::_AbstractCard)
    labels = buttons = 0
    for (_, w) in c.widgets
        labels += w.name in _MEMBER_LABELS
        buttons += w.name in _MEMBER_BUTTONS
    end
    return labels, buttons
end

# Whether the list of the members on the card `c` shows the names of the members of `sys`
function _members_shown(gui::LiveView, c::_AbstractCard, sys)
    for (b, w) in c.widgets
        (w.name in _MEMBER_LABELS && b isa Label) || continue
        b.text[] == w.value(gui, sys) || return false
    end
    return true
end

"""
    _sync_system_cards!(gui)

Builds the cards of the systems of the `gui` again whose list of members is not the one of their
system any more (see `_member_rows`), e.g. after a component was added, removed or picked: the
floating cards and the docked ones of a layout. Called every frame and after the changes of the
card itself; a card whose list is up to date costs a comparison of two numbers.
"""
function _sync_system_cards!(gui::LiveView)
    for c in _edit_cards(gui)
        sys = _card_object(gui, c)
        sys isa BMO.AbstractSystem || continue
        # only a card whose widgets were built for this system, see `_update_card!`
        (isnothing(c.pose) || c.pose[1] !== sys) && continue
        n = _member_counts(gui, sys)
        if _built_members(c) == (n.shown + (n.total > n.shown), n.buttons)
            # the same rows for other members, e.g. after an undo
            _members_shown(gui, c, sys) || _refresh_card!(gui, c)
            continue
        end
        # e.g. a collapsed card, which shows no rows
        actions, rows = _declarations(gui, c, sys)
        (_layout_key(actions), _layout_key(rows)) == c.content_key && continue
        _rebuild_card!(gui, c)
    end
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
    _update_pick_highlight!(gui)
    _update_inspector!(gui)
    return nothing
end
