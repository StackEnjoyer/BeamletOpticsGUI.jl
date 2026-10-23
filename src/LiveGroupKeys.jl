#=
The keys of the groups made in the window, see `_connect_group_keys!`
=#

# The keys of grouping and ungrouping, in the help of the controls, see `_help_sections`
const _GROUP_HELP = _HelpSection["Edit" => [
    _HelpEntry([_ctrl_cap(), "G"], "group the selection of several objects"; combo = true),
    _HelpEntry([_ctrl_cap(), "Shift", "G"], "ungroup a group made in the window"; combo = true)]]

"""
    _group_key!(gui, ungroup::Bool)

`Ctrl+G` (`ungroup = false`) and `Ctrl+Shift+G` (`ungroup = true`) in the `gui`: groups the selection
of several objects (see `_group!`), or ungroups the selected group that was made in the window (see
`_ungroup!`). Otherwise the status line tells what to select.
"""
function _group_key!(gui::LiveView, ungroup::Bool)
    sel = gui.controls.selected[]
    if ungroup
        if !isnothing(sel) && _is_window_group(gui, sel)
            _ungroup!(gui, sel)
        else
            gui.status.text[] = "select a group made in the window to ungroup it"
        end
    elseif _is_multi(sel)
        _group!(gui, sel)
    else
        gui.status.text[] = "select several objects to group them"
    end
    return nothing
end

"""
Connects `Ctrl+G` and `Ctrl+Shift+G` (`Cmd` on macOS) of the `gui`, see `_group_key!`, by the
letter of the key in the keyboard layout, see `_layout_key`. The listener runs before the controls
and the camera (200), which would take `g` as the zoom to the selection. The keys are left to a text
box that is focused and do nothing in the spectator mode. They are listed in the help of a view with
a catalog.
"""
function _connect_group_keys!(gui::LiveView)
    scene = gui.ax.scene
    ctrl = gui.controls
    push!(ctrl.listeners, on(events(scene).keyboardbutton; priority = 210) do event
        (event.action == Keyboard.press && _modifier_held(scene, _CTRL_OR_CMD_KEYS)) ||
            return Consume(false)
        _layout_key(event.key) == Keyboard.g || return Consume(false)
        ctrl.ignore_keys() && return Consume(false)
        ctrl.spectator[] && return Consume(true)
        _group_key!(gui, _shift_pressed(scene))
        return Consume(true)
    end)
    if !isnothing(gui.components.window)
        append!(ctrl.help_extra, _GROUP_HELP)
        _update_help!(ctrl)
    end
    return nothing
end

"""
    _GroupButton(text, shown)

The value of a button of a card that is only shown while `shown`, with the `text`, see `card_show!`:
"ungroup" on the card of a group, which only groups made in the window have.
"""
struct _GroupButton
    text::String
    shown::Bool
end

function card_show!(b::Button, v::_GroupButton)
    _update!(b.label, v.text)
    _update!(b.blockscene.visible, v.shown)
    return nothing
end

# The button "group" of the card of a selection of several: groups the objects, see `_group!`
_group_button() = CardWidget(Button; name = :group, label = "group",
    on = (gui, o, _) -> _group!(gui, o))

# The button "ungroup" of the card of a group: only for a group made in the window, see `_ungroup!`
_ungroup_button() = CardWidget(Button; name = :ungroup, label = "ungroup",
    value = (gui, o) -> _GroupButton("ungroup", _is_window_group(gui, o)),
    on = (gui, o, _) -> _ungroup!(gui, o))
