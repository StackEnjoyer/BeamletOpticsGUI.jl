#=
Copying and pasting the components and sources of the catalog, and groups and selections of several
of them, with `Ctrl+C` and `Ctrl+V`, see `_copy_selected!` and `_paste!`
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

"""
    _CopyNode

A part of what `Ctrl+C` keeps of a group or of a selection of several objects, see `_GroupCopy`: a
component that was built from an entry of the catalog (the `entry` and the `strings` of its form,
see `_catalog_component`) or an `ObjectGroup` of the `children`, in its `pose` `(P, R)` when it was
copied, of a group its pivot and its axes.
"""
struct _CopyNode
    entry::Union{Nothing, CatalogEntry}
    strings::Vector{String}
    pose::Tuple{Point3{Float64}, Matrix{Float64}}
    children::Vector{_CopyNode}
end

"""
    _GroupCopy

What `Ctrl+C` keeps of a group whose components are all from the catalog (`several = false`, the
`root` is the group) or of a selection of several objects (`several = true`, the children of the
`root` are the objects), see `_CopyNode`, and its `name` for the status line. `Ctrl+V` builds the
components and groups again, see `_paste_group!`. It holds no object of a view.
"""
struct _GroupCopy
    root::_CopyNode
    several::Bool
    name::String
end

# What `Ctrl+V` pastes: one for all live views of the session, such that a component that was copied
# in one window is pasted in another one
const _CLIPBOARD = Ref{Union{Nothing, _Copy, _GroupCopy}}(nothing)

# The keys of copying and pasting, in the help of the controls, see `_help_sections`
const _COPY_HELP = _HelpSection["Edit" => [
    _HelpEntry([_ctrl_cap(), "C"], "copy the selection (also a group)"; combo = true),
    _HelpEntry([_ctrl_cap(), "V"], "paste it at the mouse: click to drop it"; combo = true)]]

# Of a source also how its beam is drawn, e.g. its color and its line width
_copy_kwargs(::LiveView, ::BMO.ObjectOrGroup) = (;)
_copy_kwargs(gui::LiveView, src::_Source) = (; beam_kwargs = _snapshot(gui, src).kwargs)

"""
    _copy_selected!(gui) -> Union{Nothing, _Copy, _GroupCopy}

`Ctrl+C` in the `gui`: keeps the selected (or inspected) component or source for `_paste!`, with
its parameters as they are applied, its orientation and, of a source, the look of its beam. Only an
object that was built from an entry of the catalog can be copied, like on the page "Edit" (see
`_editable`): of any other one the constructor is not known. A group and a selection of several
objects (see `_MultiSelection`) are copied with their structure if all their components are from
the catalog, see `_copy_group!`. Otherwise, and without a selection, the status line tells why
nothing was copied, and what was copied before is kept.
"""
function _copy_selected!(gui::LiveView)
    obj = _shown_object(gui)
    if isnothing(obj)
        gui.status.text[] = "nothing selected to copy"
        return nothing
    end
    (_is_multi(obj) || (obj isa BMO.ObjectGroup && !_editable(gui, obj))) && return _copy_group!(gui, obj)
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
    _copy_reason(gui, obj) -> Union{Nothing, String}

Why `obj` of the `gui` can not be a part of a `_GroupCopy`, or `nothing` if it can: a component
that was built from an entry of the catalog, or an `ObjectGroup` (made in the window or of the
script) whose parts can, at any depth. A source is copied only on its own.
"""
function _copy_reason(gui::LiveView, @nospecialize(obj))
    obj isa BMO.ObjectOrGroup || return "$(_label(gui, obj)) is copied only on its own"
    _editable(gui, obj) && return nothing
    obj isa BMO.ObjectGroup || return "$(_label(gui, obj)) is not from the catalog"
    for part in BMO.objects(obj)
        reason = _copy_reason(gui, part)
        isnothing(reason) || return reason
    end
    return nothing
end

# The `_CopyNode` of `obj` of the `gui`, which `_copy_reason` accepts
function _copy_node(gui::LiveView, @nospecialize(obj))
    pose = _pose(obj)
    if _editable(gui, obj)
        origin = gui.components.origin[obj]
        return _CopyNode(origin.entry, String[origin.strings...], pose, _CopyNode[])
    end
    return _CopyNode(nothing, String[], pose, _CopyNode[_copy_node(gui, p) for p in BMO.objects(obj)])
end

"""
    _copy_group!(gui, sel) -> Union{Nothing, _GroupCopy}

`Ctrl+C` of a group or of a selection of several objects `sel` of the `gui`, see `_copy_selected!`:
keeps the structure of its groups and the poses of its components and groups, see `_GroupCopy`.
Nothing is copied, with the reason in the status line, if a part can not be, see `_copy_reason`.
"""
function _copy_group!(gui::LiveView, @nospecialize(sel))
    name = _label(gui, sel)
    several = _is_multi(sel)
    objs = several ? collect(Any, sel.objects) : Any[sel]
    for obj in objs
        reason = _copy_reason(gui, obj)
        if !isnothing(reason)
            gui.status.text[] = "$name can not be copied: $reason"
            return nothing
        end
    end
    root = several ?
           _CopyNode(nothing, String[], _pose(sel), _CopyNode[_copy_node(gui, o) for o in objs]) :
           _copy_node(gui, sel)
    kept = _GroupCopy(root, several, name)
    _CLIPBOARD[] = kept
    gui.status.text[] = "$name copied: $(_ctrl_cap())+V pastes it at the mouse"
    return kept
end

"""
    _paste!(gui)

`Ctrl+V` in the `gui`: builds the component or source that `_copy_selected!` kept again, in the
orientation of the original, and attaches it to the mouse like "Place" of the catalog, see
`_start_placement!`: a click drops it into the system of the selection, else the first one, or
into no system (see `_catalog_target`), `Esc` cancels. Each `Ctrl+V` pastes another one. A group
or several objects are pasted by `_paste_group!`. Returns the new object, or `nothing` with the
reason in the status line: nothing was copied or its constructor threw.
"""
function _paste!(gui::LiveView)
    c = _CLIPBOARD[]
    if isnothing(c)
        gui.status.text[] = "nothing to paste: $(_ctrl_cap())+C copies the selected component"
        return nothing
    end
    c isa _GroupCopy && return _paste_group!(gui, c)
    system = _catalog_target(gui, c.entry)
    built = try
        _catalog_component(c.entry, c.strings)
    catch e
        e isa InterruptException && rethrow()
        gui.status.text[] = "$(c.name) not pasted: $(_error_line(e))"
        return nothing
    end
    P, R = built.origin.pose0
    _set_pose!(built.obj, P, c.rotation * R)
    _start_placement!(gui, built.obj; origin = built.origin, system, kwargs = c.kwargs)
    return built.obj
end

"""
    _Pasted(several)

The `origin` of a group or of several objects that `Ctrl+V` pastes (see `_paste_group!`) while they
are placed with the mouse: the records of the pasted groups (`groups`, see `_WindowGroup`) and the
origins of the pasted components (`origins`, see `_catalog_component`), which `gui.components`
gets when they are dropped, see `_add_placed!`. With `several`, the placed object is a group that
only holds the pasted objects together while they follow the mouse.
"""
struct _Pasted
    several::Bool
    groups::IdDict{Any, Any}
    origins::IdDict{Any, Any}
end
_Pasted(several::Bool) = _Pasted(several, IdDict{Any, Any}(), IdDict{Any, Any}())

_placed_snaps(p::_Pasted) = !p.several

"""
    _build_copy!(pasted, node) -> BMO.ObjectOrGroup

Builds the component or group of the `node` (see `_CopyNode`) again in its pose and keeps the
origins of the components and the records of the groups in `pasted`, see `_Pasted`. A group is
made like one of the window (see `_group!`): its members are turned into its axes, grouped with
the axes of the world at its pivot, and turned back, such that the export builds it like a group
that was made in the window and rotated since.
"""
function _build_copy!(pasted::_Pasted, node::_CopyNode)
    P, R = node.pose
    if !isnothing(node.entry)
        built = _catalog_component(node.entry, node.strings)
        _set_pose!(built.obj, P, R)
        pasted.origins[built.obj] = built.origin
        return built.obj
    end
    members = Any[_build_copy!(pasted, child) for child in node.children]
    turn = BMO.ObjectGroup(members)
    BMO.set_pivot3d!(turn, P)
    _set_pose!(turn, P, Matrix{Float64}(R'))
    g = BMO.ObjectGroup(members)
    BMO.set_pivot3d!(g, P)
    poses = IdDict{Any, Tuple{Point3{Float64}, Matrix{Float64}}}()
    foreach(m -> (poses[m] = _pose(m)), members)
    pasted.groups[g] = _WindowGroup(members, Vector{Float64}(P), poses)
    _set_pose!(g, P, R)
    return g
end

"""
    _paste_group!(gui, c::_GroupCopy)

`Ctrl+V` of a group or of several objects that `_copy_group!` kept: builds them again (see
`_build_copy!`) and attaches them to the mouse like a single copy, see `_paste!`. Several objects
follow it as one, at the mean of their positions and without snapping (see `_placed_snaps`), and
are dropped as separate objects, see `_add_placed!`.
"""
function _paste_group!(gui::LiveView, c::_GroupCopy)
    system = _catalog_target(gui, _first_entry(c.root))
    pasted = _Pasted(c.several)
    obj = try
        if c.several
            members = Any[_build_copy!(pasted, child) for child in c.root.children]
            g = BMO.ObjectGroup(members)
            BMO.set_pivot3d!(g, sum(m -> Vector{Float64}(position(m)), members) ./ length(members))
            g
        else
            _build_copy!(pasted, c.root)
        end
    catch e
        e isa InterruptException && rethrow()
        gui.status.text[] = "$(c.name) not pasted: $(_error_line(e))"
        return nothing
    end
    _start_placement!(gui, obj; origin = pasted, system)
    _placing(gui) && (gui.status.text[] = "pasting $(c.name): click to drop it, Esc to cancel")
    return obj
end

# The entry of the first component in the `node`, for the system it is pasted into
_first_entry(node::_CopyNode) = isnothing(node.entry) ? _first_entry(first(node.children)) : node.entry

"""
    _add_placed!(gui, obj, pasted::_Pasted, system, kwargs)

Drops a pasted group or several pasted objects (see `_paste_group!`) into the `system` of the
`gui`: `gui.components` gets the records of the groups (as groups made in the window, see
`_group!`) and the origins of the components, as if they had been placed from the catalog and
grouped. A group is added like [`add_component!`](@ref); several objects each on its own, as one
action of the undo history, and they are selected.
"""
function _add_placed!(gui::LiveView, @nospecialize(obj), pasted::_Pasted, system, ::NamedTuple)
    comp = gui.components
    for (g, rec) in pasted.groups
        comp.groups[g] = rec
        comp.origin[g] = nothing
    end
    merge!(comp.origin, pasted.origins)
    if !pasted.several
        add_component!(gui, obj; system, origin = nothing)
        return nothing
    end
    members = collect(Any, BMO.objects(obj))
    _unrecorded(gui) do
        for m in members
            add_component!(gui, m; system, select = false, origin = get(pasted.origins, m, nothing))
        end
    end
    if comp.recording
        state = Ref{Any}(nothing)
        _push_action!(gui.controls, _selection_of(members),
            () -> (state[] = _remove_all!(gui, members)), () -> _restore_all!(gui, members, state[]))
    end
    ctrl = gui.controls
    if !ctrl.spectator[]
        ctrl.selected[] = _selection_of(members)
        _update_selection_box!(ctrl)
    end
    gui.status.text[] = "$(length(members)) objects pasted"
    return nothing
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
