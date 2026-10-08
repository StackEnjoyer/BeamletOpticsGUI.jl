#=
Picking the members of a system with the mouse: "+" and "−" of a system, see `_set_member_pick!`
=#

# Priority of the listeners of the pick: its clicks before the controls (200), which would select
# what is clicked, and `Esc` before its other meanings, e.g. the placement (210); after the cards
# (250), the overlay of the compact layout (260) and the progress window (270)
const _PICK_PRIORITY = 205
const _PICK_KEY_PRIORITY = 220

"""
    _MemberPick

The system `sys` of a live view whose members are picked with the mouse, see `_set_member_pick!`:
with `add`, a click on a component or a source adds it to `sys`, otherwise it takes it out.
"""
struct _MemberPick
    sys::BMO.AbstractSystem
    add::Bool
end

"""The `_MemberPick` of the `gui`, or `nothing` while no members are picked."""
_member_pick(gui::LiveView) = gui.components.pick

"""
    _set_member_pick!(gui, sys, add::Bool)

Starts picking the members of the system `sys` of the `gui` with the mouse (`add`: "+", otherwise
"−"), or ends it if exactly this is going on, like a second click on the button. While picking, a
click on a component or a source marker in the 3D view, in the component menu or in the object tree
adds it to `sys` or takes it out instead of selecting it, see `_pick_member!`; the members of `sys`
are shown as they are and everything else see-through, see `_update_system_highlight!`. `sys` is
inspected, such that its card, the system widget, is shown. `Esc`, the spectator mode, the
inspection of another system and removing `sys` end the pick, see `_end_member_pick!`.
"""
function _set_member_pick!(gui::LiveView, sys::BMO.AbstractSystem, add::Bool)
    pick = _member_pick(gui)
    if !isnothing(pick) && pick.sys === sys && pick.add == add
        return _end_member_pick!(gui)
    end
    if isnothing(_system_handle(gui, sys))
        gui.status.text[] = "the system is not shown in the live view"
        return nothing
    end
    if gui.controls.spectator[]
        gui.status.text[] = "spectator mode, press v to pick the members of a system"
        return nothing
    end
    gui.components.pick = _MemberPick(sys, add)
    # the system widget; the selection is cleared, such that a drag moves the camera only
    _inspect!(gui, sys)
    _show_member_pick!(gui)
    gui.status.text[] = _pick_text(gui)
    return nothing
end

"""Ends picking the members of a system of the `gui`, if it is going on."""
function _end_member_pick!(gui::LiveView)
    pick = _member_pick(gui)
    isnothing(pick) && return nothing
    gui.components.pick = nothing
    _show_member_pick!(gui)
    gui.status.text[] = "members of $(_label(gui, pick.sys)): picking ended"
    return nothing
end

# What the pick of the `gui` does, for the chip of the help and the status line; `nothing` without one
function _pick_text(gui::LiveView)
    pick = _member_pick(gui)
    isnothing(pick) && return nothing
    name = _label(gui, pick.sys)
    return pick.add ? "+ $name: click components, Esc ends" :
           "− $name: click its components to take them out, Esc ends"
end

"""
    _show_member_pick!(gui)

Shows the pick of the `gui`, after it started, ended or its system was renamed: the chip of the
help (see `_show_pick_chip!`), the highlight of the members (see `_update_system_highlight!`), the
buttons "+" and "−" of the cards of the system and, via the hook of the layout, of its row in the
object tree.
"""
function _show_member_pick!(gui::LiveView)
    pick = _member_pick(gui)
    _show_pick_chip!(gui, isnothing(pick) ? nothing : (pick.add ? "+ " : "− ") * _label(gui, pick.sys))
    # the highlight of a browsed group would be restored to what the pick shows, see `_Highlight`
    _end_browse!(gui)
    _update_system_highlight!(gui)
    _on_components_changed!(gui)
    # the cards of the system say what a click does while it is picked, see `_system_rows`
    _sync_system_cards!(gui)
    _update_inspector!(gui)
    _update_cards!(gui)
    return nothing
end

"""Whether `obj` is what a pick of members takes: a component or a source."""
_pick_candidate(@nospecialize(obj)) = obj isa BMO.AbstractObject || _is_source(obj)

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
    top = _is_pair_source(gui, obj) ? obj : _component_top(gui, obj)
    try
        _apply_member_pick!(gui, top, pick.sys, pick.add)
    catch e
        e isa ArgumentError || rethrow()
        gui.status.text[] = e.msg
    end
    _on_members_changed!(gui)
    return nothing
end

# Whether `obj` is a source of the `gui`, e.g. a beam group, but not one of its beams
_is_pair_source(gui::LiveView, @nospecialize(obj)) = _is_source(obj) && any(p -> p.second === obj, gui.pairs)

function _apply_member_pick!(gui::LiveView, src::_Source, sys, add::Bool)
    if add
        _system_of_source(gui, src) === sys &&
            throw(ArgumentError("$(_label(gui, src)) is already traced through $(_label(gui, sys))"))
        _set_source_system!(gui, src, sys)
    else
        _system_of_source(gui, src) === sys ||
            throw(ArgumentError("$(_label(gui, src)) is not traced through $(_label(gui, sys))"))
        _set_source_system!(gui, src, nothing)
    end
    return nothing
end
function _apply_member_pick!(gui::LiveView, @nospecialize(obj), sys, add::Bool)
    obj isa BMO.AbstractObject || throw(ArgumentError("$(_label(gui, obj)) is not a component"))
    sys isa BMO.System || throw(ArgumentError(
        "$(_label(gui, sys)) is a $(nameof(typeof(sys))), its objects can not be changed"))
    add ? _add_member!(gui, obj, sys) : _remove_member!(gui, obj, sys)
    return nothing
end

#=
Clicks in the 3D view
=#

"""
    _member_under_cursor(gui)

The component or the source of the `gui` under the cursor in its 3D view, for a pick of members, or
`nothing`: resolved like a click of the controls (see `kinematic_controls!`), i.e. by the camera
ray, with the radius of the source markers, else by the plot under the cursor, or by the custom
`pick` of the controls. Unlike a click that selects, it also finds what the controls do not move or
select, e.g. a static object or a see-through housing, since everything that is not a member is
see-through while picking. Hidden objects are not found.
"""
function _member_under_cursor(gui::LiveView)
    ctrl = gui.controls
    scene = Makie.get_scene(gui.ax)
    if isnothing(ctrl.pick)
        leaf, t = _ray_pick(ctrl, scene)
        origin, dir = _cursor_ray(scene)
        objects = Any[]
        for oh in render_children(ctrl.h)
            x = rendered(oh)
            (x isa BMO.AbstractObject && !_is_hidden(ctrl, x)) && push!(objects, x)
        end
        other, s = _ray_pick(objects, origin, dir)
        (!isnothing(other) && (isnothing(t) || s < t)) && (leaf = other)
        isnothing(leaf) || return leaf
        plot, _ = _default_pick(gui.ax)
    else
        plot, _ = ctrl.pick(gui.ax)
    end
    leaf = isnothing(plot) ? nothing : _pick_leaf(ctrl.h, plot)
    (isnothing(leaf) || _is_hidden(ctrl, leaf)) && return nothing
    return leaf
end

"""
    _pick_press(gui) -> Union{Nothing, Tuple}

A press of the left mouse button while the members of a system of the `gui` are picked: the pixel
of the mouse and what is under it (see `_member_under_cursor`), or `nothing` for a press that is
not one into the 3D view, e.g. on a card, or that belongs to a placement or to aiming a source. The
press is passed on, such that a drag moves the camera; its release decides, see `_pick_release!`.
"""
function _pick_press(gui::LiveView)
    ctrl = gui.controls
    scene = Makie.get_scene(gui.ax)
    isnothing(_member_pick(gui)) && return nothing
    (ctrl.spectator[] || ctrl.ignore_mouse() || _placing(gui) || _aiming(gui)) && return nothing
    (isnothing(ctrl.select_modifier) || _modifier_held(scene, ctrl.select_modifier)) || return nothing
    return (_px(scene), _member_under_cursor(gui))
end

"""
    _pick_release!(gui, p0, leaf)

The release of a press at the pixel `p0` on `leaf` while the members of a system of the `gui` are
picked (see `_pick_press`): a click, i.e. a release near `p0`, picks `leaf` (see `_pick_member!`)
instead of selecting it, and the controls neither select nor deselect; a click beside the
components changes nothing. A drag is left to the controls and the camera.
"""
function _pick_release!(gui::LiveView, p0, @nospecialize(leaf))
    ctrl = gui.controls
    isnothing(_member_pick(gui)) && return nothing
    # the press of the controls, which come after this listener: not a drag of the selection or of
    # its gizmo
    (ctrl.dragging || ctrl.press_pos != p0) && return nothing
    ctrl.press_kind in (:pending_select, :pending_drag, :background) || return nothing
    moved = hypot((_px(Makie.get_scene(gui.ax)) .- p0)...)
    moved < ctrl.drag_threshold || return nothing
    # The click is taken: the release finds no press of the controls
    ctrl.press_kind, ctrl.press_leaf, ctrl.press_pos = :none, nothing, nothing
    if isnothing(leaf)
        gui.status.text[] = _pick_text(gui)
    else
        _pick_member!(gui, leaf)
    end
    return nothing
end

"""
Connects the picking of members with the mouse of the `gui`: the clicks on the components and the
source markers while a pick is active, `Esc`, the spectator mode and the closed window, which end
it, and the cards of the systems and the highlight of the members of a system, which follow the
members every frame, see `_sync_system_cards!` and `_update_system_highlight!`.
"""
function _connect_member_pick!(gui::LiveView)
    ctrl = gui.controls
    ev = events(gui.ax.scene)
    listeners = ctrl.listeners
    # The pixel and the object of the press, see `_pick_press`
    press = Ref{Any}(nothing)
    push!(listeners, on(ev.mousebutton; priority = _PICK_PRIORITY) do event
        event.button == Mouse.left || return Consume(false)
        try
            if event.action == Mouse.press
                press[] = _pick_press(gui)
            elseif event.action == Mouse.release && !isnothing(press[])
                p0, leaf = press[]
                press[] = nothing
                _pick_release!(gui, p0, leaf)
            end
        catch e
            gui.last_error = _log_once(e, gui.last_error, "picking members")
        end
        return Consume(false)
    end)
    # Before the other meanings of Esc, which is not passed on: the card of the system stays
    push!(listeners, on(ev.keyboardbutton; priority = _PICK_KEY_PRIORITY) do event
        (event.action == Keyboard.press && event.key == Keyboard.escape) || return Consume(false)
        (isnothing(_member_pick(gui)) || ctrl.ignore_keys()) && return Consume(false)
        _end_member_pick!(gui)
        return Consume(true)
    end)
    push!(listeners, on(v -> v && _end_member_pick!(gui), ctrl.spectator))
    # The spectator mode shows the view as it is, see `_highlighted_system`
    push!(listeners, on(_ -> _update_system_highlight!(gui), ctrl.spectator))
    push!(listeners, on(open -> open || _end_member_pick!(gui), ev.window_open))
    push!(listeners, on(ev.tick) do _
        try
            _sync_system_cards!(gui)
            _update_system_highlight!(gui)
        catch e
            gui.last_error = _log_once(e, gui.last_error, "system cards")
        end
        return nothing
    end)
    return nothing
end
