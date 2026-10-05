#=
Copying and pasting the components and sources of the catalog with `Ctrl+C` and `Ctrl+V`, see
`_copy_selected!` and `_paste!`
=#

"""
    _Copy

What `Ctrl+C` keeps of a component or source that was built from an entry of the catalog, i.e.
how `Ctrl+V` builds it again: the `entry` and the `strings` of its form (see `_catalog_component`),
its `rotation` from its orientation as constructed, the keyword arguments `kwargs` of its
[`add_component!`](@ref) (of a source its `beam_kwargs`, i.e. how its beam is drawn) and its
`name` for the status line. It holds no object of a view.
"""
struct _Copy
    entry::CatalogEntry
    strings::Vector{String}
    rotation::Matrix{Float64}
    kwargs::NamedTuple
    name::String
end

# What `Ctrl+V` pastes: one for all live views of the session, such that a component that was copied
# in one window is pasted in another one
const _CLIPBOARD = Ref{Union{Nothing, _Copy}}(nothing)

# The keys of copying and pasting, in the help of the controls, see `_help_sections`
const _COPY_HELP = _HelpSection["Edit" => [
    _HelpEntry([_ctrl_cap(), "C"], "copy the selected component or source"; combo = true),
    _HelpEntry([_ctrl_cap(), "V"], "paste it at the mouse: click to drop it"; combo = true)]]

# Of a source also how its beam is drawn, e.g. its color and its line width
_copy_kwargs(::LiveView, ::BMO.AbstractObject) = (;)
_copy_kwargs(gui::LiveView, src::_Source) = (; beam_kwargs = _snapshot(gui, src).kwargs)

"""
    _copy_selected!(gui) -> Union{Nothing, _Copy}

`Ctrl+C` in the `gui`: keeps the selected (or inspected) component or source for `_paste!`, with
its parameters as they are applied, its orientation and, of a source, the look of its beam. Only an
object that was built from an entry of the catalog can be copied, like on the page "Edit" (see
`_editable`): of any other one the constructor is not known. Otherwise, and without a selection,
the status line tells why nothing was copied, and what was copied before is kept.
"""
function _copy_selected!(gui::LiveView)
    obj = _shown_object(gui)
    if isnothing(obj)
        gui.status.text[] = "nothing selected to copy"
        return nothing
    end
    name = _label(gui, obj)
    if !_editable(gui, obj)
        gui.status.text[] = "$name can not be copied: only components and sources from the catalog"
        return nothing
    end
    origin = gui.components.origin[obj]
    rotation = Matrix{Float64}(_pose(obj)[2] * origin.pose0[2]')
    kept = _Copy(origin.entry, String[origin.strings...], rotation, _copy_kwargs(gui, obj), name)
    _CLIPBOARD[] = kept
    gui.status.text[] = "$name copied: $(_ctrl_cap())+V pastes it at the mouse"
    return kept
end

"""
    _paste!(gui)

`Ctrl+V` in the `gui`: builds the component or source that `_copy_selected!` kept again, in the
orientation of the original, and attaches it to the mouse like "Place" of the catalog, see
`_start_placement!`: a click drops it into the system of the selection, else the first one (see
`_catalog_target`), `Esc` cancels. Each `Ctrl+V` pastes another one. Returns the new object, or
`nothing` with the reason in the status line: nothing was copied, the view has no system that
takes it, or its constructor threw.
"""
function _paste!(gui::LiveView)
    c = _CLIPBOARD[]
    if isnothing(c)
        gui.status.text[] = "nothing to paste: $(_ctrl_cap())+C copies the selected component"
        return nothing
    end
    system = _catalog_target(gui, c.entry)
    if isnothing(system)
        gui.status.text[] = "$(c.name) not pasted: the view has no System that takes a component"
        return nothing
    end
    built = try
        _catalog_component(c.entry, c.strings)
    catch e
        e isa InterruptException && rethrow()
        msg = first(split(sprint(showerror, e), '\n'))
        gui.status.text[] = "$(c.name) not pasted: $msg"
        return nothing
    end
    P, R = built.origin.pose0
    _set_pose_exact!(built.obj, P, c.rotation * R)
    _start_placement!(gui, built.obj; origin = built.origin, system, kwargs = c.kwargs)
    return built.obj
end

"""
Connects `Ctrl+C` and `Ctrl+V` (`Cmd` on macOS) of the `gui`, see `_copy_selected!` and `_paste!`,
by the letters of the keys in the keyboard layout, see `_layout_key`. The listener runs before the
controls and the clip planes (200), which would take the keys as `c` (clipping) and `v` (spectator
mode). The keys are left to a text box that is focused and do nothing in the spectator mode. They
are listed in the help of a view with a catalog.
"""
function _connect_copy!(gui::LiveView)
    scene = gui.ax.scene
    ctrl = gui.controls
    push!(ctrl.listeners, on(events(scene).keyboardbutton; priority = 210) do event
        (event.action == Keyboard.press && _modifier_held(scene, _CTRL_OR_CMD_KEYS)) ||
            return Consume(false)
        key = _layout_key(event.key)
        key in (Keyboard.c, Keyboard.v) || return Consume(false)
        ctrl.ignore_keys() && return Consume(false)
        ctrl.spectator[] && return Consume(true)
        key == Keyboard.c ? _copy_selected!(gui) : _paste!(gui)
        return Consume(true)
    end)
    if !isnothing(gui.components.window)
        append!(ctrl.help_extra, _COPY_HELP)
        _update_help!(ctrl)
    end
    return nothing
end
