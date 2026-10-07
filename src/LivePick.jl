#=
Picking the members of a system with the mouse: "+" and "−" of a system, see `_set_member_pick!`
=#

"""
    _MemberPick

The system `sys` of a live view whose members are picked with the mouse, see `_set_member_pick!`:
with `add`, a click on a component or a source adds it to `sys`, otherwise it takes it out.
"""
struct _MemberPick
    sys::BMO.AbstractSystem
    add::Bool
end

"""
Connects the picking of members with the mouse of the `gui`: the clicks on the components and the
source markers while a pick is active, and `Esc`, which ends it.
"""
_connect_member_pick!(gui::LiveView) = nothing

"""The `_MemberPick` of the `gui`, or `nothing` while no members are picked."""
_member_pick(gui::LiveView) = gui.components.pick

"""
    _set_member_pick!(gui, sys, add::Bool)

Starts picking the members of the system `sys` of the `gui` with the mouse (`add`: "+", otherwise
"−"), or ends it if exactly this is going on, like a second click on the button.
"""
function _set_member_pick!(gui::LiveView, sys::BMO.AbstractSystem, add::Bool)
    pick = _member_pick(gui)
    if !isnothing(pick) && pick.sys === sys && pick.add == add
        return _end_member_pick!(gui)
    end
    gui.components.pick = _MemberPick(sys, add)
    return nothing
end

"""Ends picking the members of a system of the `gui`, if it is going on."""
function _end_member_pick!(gui::LiveView)
    gui.components.pick = nothing
    return nothing
end

"""
    _pick_member!(gui, obj)

Applies the pick of the `gui` to `obj`, a component or a source that was clicked: it is added to
the system of the pick or taken out of it, see `_add_member!`, `_remove_member!` and
`_set_source_system!`. What can not be done, e.g. an object that is in the system already, only
shows a message in the status line.
"""
function _pick_member!(gui::LiveView, @nospecialize(obj))
    pick = _member_pick(gui)
    isnothing(pick) && return nothing
    top = obj isa _Source ? obj : _component_top(gui, obj)
    try
        _apply_member_pick!(gui, top, pick.sys, pick.add)
    catch e
        e isa ArgumentError || rethrow()
        gui.status.text[] = e.msg
    end
    return nothing
end

_apply_member_pick!(gui::LiveView, src::_Source, sys, add::Bool) =
    add ? _set_source_system!(gui, src, sys) :
    _system_of_source(gui, src) === sys ? _set_source_system!(gui, src, nothing) :
    throw(ArgumentError("$(_label(gui, src)) is not traced through $(_label(gui, sys))"))
function _apply_member_pick!(gui::LiveView, @nospecialize(obj), sys, add::Bool)
    sys isa BMO.System || throw(ArgumentError(
        "$(_label(gui, sys)) is a $(nameof(typeof(sys))), its objects can not be changed"))
    obj isa BMO.AbstractObject || throw(ArgumentError("$(_label(gui, obj)) is not a component"))
    add ? _add_member!(gui, obj, sys) : _remove_member!(gui, obj, sys)
    return nothing
end
