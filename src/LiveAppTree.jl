#=
Object tree
=#

"""
    _tree_kind(obj) -> Symbol

The kind of the row of `obj` in the object tree, which selects its icon, see `_icon`: `:lens`,
`:mirror`, `:beamsplitter`, `:polarizer`, `:detector`, `:group`, `:mesh` (objects without optical
function, e.g. housings), `:source`, `:clip_plane`, `:system` or `:object` for all other objects.
The inspector shows the same icon. Add a method for a new type of component to give it a matching
icon.
"""
_tree_kind(_) = :object
_tree_kind(::Union{BMO.Lens, BMO.DoubletLens, BMO.TripletLens}) = :lens
_tree_kind(::BMO.AbstractReflectiveOptic) = :mirror
_tree_kind(::BMO.AbstractBeamsplitter) = :beamsplitter
_tree_kind(::Union{BMO.AbstractJonesPolarizer, BMO.LinearPolarizer}) = :polarizer
_tree_kind(::BMO.AbstractDetector) = :detector
_tree_kind(::BMO.AbstractObjectGroup) = :group
_tree_kind(::Union{BMO.NonInteractableObject, BMO.IntersectableObject}) = :mesh
_tree_kind(::Union{BMO.AbstractBeam, BMO.AbstractBeamGroup}) = :source
_tree_kind(::LiveClipPlane) = :clip_plane
_tree_kind(::Union{AbstractSystemRenderHandle, BMO.AbstractSystem}) = :system

"""The rendered objects of the system of `h`, i.e. the leaves of its groups, see `_set_hidden!`."""
_leaves(h::AbstractSystemRenderHandle) = _LiveMovable[rendered(oh) for oh in render_children(h)]

"""
The objects of the system `sys` as they are rendered, i.e. the leaves of its groups (see
`live_render!`), e.g. for the card of an inspected system, see `_inspect!`.
"""
_leaves(sys::BMO.AbstractSystem) = reduce(vcat, (_leaves(obj) for obj in sys.objects); init = _LiveMovable[])

"""Returns the top-level objects (outermost groups) of the system of `h`, in the order of `h`."""
function _top_levels(h::AbstractSystemRenderHandle)
    tops = _LiveMovable[]
    seen = Base.IdSet{Any}()
    for oh in render_children(h)
        top = _top_level(h, rendered(oh))
        top in seen && continue
        push!(seen, top)
        push!(tops, top)
    end
    return tops
end

"""Returns the sources of the `gui`, i.e. the beams of its pairs, without duplicates."""
_sources(gui::LiveView) = unique(objectid, last.(gui.pairs))

"""
    _name_objects!(gui::LiveView)

Names the systems ("System i") and all objects and sources without an entry in `labels` by their
type and a running index per type, e.g. "Lens 2": the objects of the systems in their order (an
object of several systems is named once), then those without a system, then the sources. A system
has its name twice, as its `AbstractSystemRenderHandle` (the key of its row and menu entry) and as
the system itself, which its card shows (see `_inspect!`); so have the objects and sources without
a system, "No system" (`gui.extras`). Names, once given, are kept, see `_label`. The component menu,
if any, shows the names.
"""
function _name_objects!(gui::LiveView)
    layout = gui.objects
    function name!(@nospecialize(obj))
        (haskey(gui.labels, obj) || haskey(layout.names, obj)) && return nothing
        base = string(nameof(typeof(obj)))
        n = layout.counters[base] = get(layout.counters, base, 0) + 1
        layout.names[obj] = "$base $n"
        return nothing
    end
    for (i, h) in enumerate(gui.system_handles)
        haskey(layout.names, h) || (layout.names[h] = get(gui.labels, rendered(h), "System $i"))
        haskey(layout.names, rendered(h)) || (layout.names[rendered(h)] = layout.names[h])
        foreach(top -> foreach(name!, _descendants(top)), _top_levels(h))
    end
    haskey(layout.names, gui.extras) || (layout.names[gui.extras] = "No system")
    haskey(layout.names, rendered(gui.extras)) || (layout.names[rendered(gui.extras)] = "No system")
    foreach(top -> foreach(name!, _descendants(top)), _top_levels(gui.extras))
    foreach(name!, _sources(gui))
    _refresh_menu_options!(gui, gui.widgets.menu)
    return nothing
end

"""
Returns the state of the eye of the row of `obj`: `nothing` if none of its `_leaves` is rendered,
i.e. it can not be hidden, otherwise whether any of them is shown.
"""
function _tree_visible(gui::LiveView, drawn, @nospecialize(obj))
    leaves = filter(leaf -> leaf in drawn, _leaves(obj))
    isempty(leaves) && return nothing
    return !all(leaf -> leaf in gui.objects.hidden, leaves)
end
# Clip planes are switched off, not hidden, see `_toggle_hidden!`
_tree_visible(::LiveView, _, ::LiveClipPlane) = nothing

function _push_tree_rows!(rows, gui::AppView, drawn, @nospecialize(obj), depth; count::Int = 0)
    children = _children(obj)
    expanded = get(gui.layout.expanded, obj, false)
    push!(rows, _TreeRow(obj, _label(gui, obj), depth, _tree_kind(obj), !isempty(children),
        expanded, _tree_visible(gui, drawn, obj); count))
    expanded && foreach(c -> _push_tree_rows!(rows, gui, drawn, c, depth + 1), children)
    return rows
end

"""
    _tree_rows(gui::AppView) -> Vector{_TreeRow}

Returns the rows of the object tree of the `gui`, which lists the members of each system: per
system a row (key: its system handle) followed by its sources (see `_sources_of`) and its objects
in the hierarchy of the kinematic controls (groups with their objects, including static objects
such as housings, which can be hidden, but not selected). An object of several systems is listed
under each of them: its rows have the same key, such that they are all highlighted while it is
selected, and show the number of its systems as their `count`. Then the sources and the objects
without a system in the same way under a row "No system" (key: `gui.extras`, only if there are
any), and the clip planes. The keys of all other rows are the objects. Systems and "No system" are
expanded, and groups collapsed, by default. Objects whose plots are all hidden (see
`gui.objects.hidden`) are muted.

The row of a system has the buttons "+" and "−", which pick its members with the mouse, see
`_tree_button!`; the one of the pick that is going on (see `_member_pick`) is highlighted.
"""
function _tree_rows(gui::AppView)
    drawn = Base.IdSet{Any}(rendered(oh) for oh in render_children(gui.controls.h))
    rows = _TreeRow[]
    pick = _member_pick(gui)
    for h in gui.system_handles
        sys = rendered(h)
        buttons = (isnothing(pick) || pick.sys !== sys) ? :none : pick.add ? :add : :remove
        _push_system_rows!(rows, gui, drawn, h, :system, _sources_of(gui, sys), buttons)
    end
    unassigned = Any[src for src in _sources(gui) if src in gui.beams.unassigned]
    if !isempty(unassigned) || !isempty(render_children(gui.extras))
        _push_system_rows!(rows, gui, drawn, gui.extras, :group, unassigned, nothing)
    end
    foreach(plane -> _push_tree_rows!(rows, gui, drawn, plane, 0), gui.clip.planes)
    return rows
end

# The row of the system (or of "No system") of `h` with the icon of the `kind` and the `buttons`
# (see `_TreeRow`), then its `sources` and its objects
function _push_system_rows!(rows, gui::AppView, drawn, h::AbstractSystemRenderHandle, kind::Symbol,
        sources, buttons)
    tops = _top_levels(h)
    expanded = get(gui.layout.expanded, h, true)
    push!(rows, _TreeRow(h, _label(gui, h), 0, kind, !isempty(tops) || !isempty(sources), expanded,
        _tree_visible(gui, drawn, h); buttons))
    expanded || return rows
    foreach(src -> _push_tree_rows!(rows, gui, drawn, src, 1), sources)
    for top in tops
        n = length(_member_systems(gui, top))
        _push_tree_rows!(rows, gui, drawn, top, 1; count = n > 1 ? n : 0)
    end
    return rows
end

"""Sets the rows of the object tree of the `gui`, only called on events, see `_tree_rows`."""
function _update_tree!(gui::AppView)
    _set_rows!(gui.layout.tree, _tree_rows(gui))
    return nothing
end

"""Expands or collapses the row `key` of the object tree, see `_tree_rows`."""
function _toggle_expanded!(gui::AppView, key)
    expanded = gui.layout.expanded
    expanded[key] = !get(expanded, key, key isa AbstractSystemRenderHandle)
    _update_tree!(gui)
    return nothing
end

"""
    _tree_button!(gui, h, button::Symbol)

Handles a click on the button "+" (`button == :add`) or "−" (`:remove`) of the row of the system
of `h` in the object tree: starts picking its members with the mouse, or ends it if exactly this
is going on, see `_set_member_pick!`. The button of the pick is highlighted, see `_tree_rows`.
"""
function _tree_button!(gui::AppView, h::AbstractSystemRenderHandle, button::Symbol)
    _set_member_pick!(gui, rendered(h), button === :add)
    _update_tree!(gui)
    return nothing
end

"""
    _tree_click!(gui, key)

Handles a click on the label of a row of the object tree: selects the object like a click in the
3D view (see `_select!`). A click on a system (or the extras) and on an object that is not movable
inspects it instead, i.e. shows its card in the inspector without selecting it, see `_inspect!`;
the expander of a system expands or collapses it.
"""
_tree_click!(gui::AppView, h::AbstractSystemRenderHandle) = _inspect!(gui, h)

function _tree_click!(gui::AppView, @nospecialize(obj))
    _is_movable(gui.controls, obj) ? _select!(gui, obj) : _inspect!(gui, obj)
    return nothing
end

# The row of the inspected object is highlighted like the selected one, see `_on_selected!`
_show_inspected!(::AppView, ::Nothing) = nothing
function _show_inspected!(gui::AppView, @nospecialize(obj))
    _reveal!(gui, obj)
    _set_selected!(gui.layout.tree, _row_key(gui, obj))
    return nothing
end

"""
Expands the groups that contain `obj` and a system that lists it (or "No system"), such that a row
of it is shown in the object tree: of an object of several systems the first one, unless one of
them is expanded. The rows are only set again if a row was expanded.
"""
_reveal!(::AppView, ::Nothing) = nothing
# The rows of the systems are always shown
_reveal!(::AppView, ::BMO.AbstractSystem) = nothing

function _reveal!(gui::AppView, @nospecialize(obj))
    expanded = gui.layout.expanded
    chain = _chain(gui.controls, obj)
    changed = false
    for group in chain[2:end]
        get(expanded, group, false) && continue
        expanded[group] = changed = true
    end
    handles = _listing_handles(gui, last(chain))
    if !isempty(handles) && !any(h -> get(expanded, h, true), handles)
        expanded[first(handles)] = changed = true
    end
    changed && _update_tree!(gui)
    return nothing
end

"""
The handles of the systems of the `gui` whose rows list the top-level object or the source `obj`
in the object tree, in the order of the tree; `gui.extras` for one without a system. Empty for what
is listed under no system, e.g. a clip plane.
"""
_listing_handles(gui::AppView, @nospecialize(obj)) = AbstractSystemRenderHandle[
    h for h in (gui.system_handles..., gui.extras) if _has(_top_levels(h), obj)]

function _listing_handles(gui::AppView, src::Union{BMO.AbstractBeam, BMO.AbstractBeamGroup})
    sys = _system_of_source(gui, src)
    h = isnothing(sys) ? gui.extras : _system_handle(gui, sys)
    return isnothing(h) ? AbstractSystemRenderHandle[] : AbstractSystemRenderHandle[h]
end

#=
Tooltips of the object tree
=#

# Seconds that the mouse rests on an eye, a button or a counter of the object tree before its
# tooltip is shown, like on the icons of the toolbar, see `_icon_widget`
const _TREE_TIP_DELAY = 0.5

"""
    _TreeTip

The tooltip of the object tree of a live view in the app layout, see `_connect_tree_tips!`: its
`text`, its position `pos` [figure px] and whether it is `visible`, the row and the part under the
mouse that it is for (`hovered`, `nothing`: none) and the `timer` of its delay.
"""
mutable struct _TreeTip
    const text::Observable{String}
    const pos::Observable{Point2f}
    const visible::Observable{Bool}
    hovered::Any
    timer::Union{Nothing, Timer}
end

"""
Returns the tooltip of the object tree of the `gui` (see `_TreeTip`), `nothing` before
`_connect_tree_tips!`. A field of the layout and not an entry of a global registry, which would keep
every closed window alive, see `_highlight`.
"""
_tree_tip_state(gui::AppView) =
    isdefined(gui.layout, :tree_tip) ? gui.layout.tree_tip::_TreeTip : nothing

"""
    _tree_tip(gui) -> Union{Nothing, NamedTuple}

What the part of the object tree of the `gui` under the mouse does, for its tooltip: `(; key, text,
pos)` with the row and the part (`key`), the `text` and the point below the part [figure px]. The
eye of a row hides or shows its object, "+" and "−" of a system pick its members with the mouse
(see `_set_member_pick!`) and the counter is the number of systems of an object. `nothing` for a
label, an expander and beside the rows.
"""
function _tree_tip(gui::AppView)
    tree = gui.layout.tree
    _mouse_in_tree(tree) || return nothing
    hit = _hit(tree)
    isnothing(hit) && return nothing
    i, part = hit
    row = tree.rows[i]
    origin = Point2f(Makie.origin(tree.scene.viewport[]))
    buttons = _button_columns(tree)
    x = events(tree.scene).mouseposition[][1] - origin[1]
    counter = isnothing(row.buttons) && row.count > 0
    (part === :label && counter && abs(x - buttons.counter) <= _TREE_BUTTON / 2) && (part = :counter)
    text = part === :eye ? (row.visible === false ? "Show" : "Hide") :
           part === :add ? "Add members: click components" :
           part === :remove ? "Take members out: click components" :
           part === :counter ? "In $(row.count) systems" : return nothing
    column = part === :eye ? _row_columns(tree, row).eye : getproperty(buttons, part)
    return (; key = (i, part), text, pos = origin + Point2f(column, _row_y(tree, i) - tree.row_height / 2))
end

"""Hides the tooltip of the object tree of the `gui` and forgets what it was for."""
function _hide_tree_tip!(gui::AppView)
    tip = _tree_tip_state(gui)
    isnothing(tip) && return nothing
    isnothing(tip.timer) || (close(tip.timer); tip.timer = nothing)
    tip.visible[] && (tip.visible[] = false)
    tip.hovered = nothing
    return nothing
end

"""
Shows the tooltip of the part of the object tree of the `gui` under the mouse (see `_tree_tip`),
if the mouse still rests on the part that the tooltip waits for.
"""
function _show_tree_tip!(gui::AppView)
    tip = _tree_tip_state(gui)
    isnothing(tip) && return nothing
    info = _tree_tip(gui)
    (isnothing(info) || info.key != tip.hovered) && return nothing
    tip.text[] = info.text
    tip.pos[] = info.pos
    tip.visible[] = true
    return nothing
end

"""
The mouse moved in the window of the `gui`: the tooltip of the object tree waits for
`_TREE_TIP_DELAY` on another eye, button or counter, and is hidden elsewhere.
"""
function _on_tree_hover!(gui::AppView)
    tip = _tree_tip_state(gui)
    isnothing(tip) && return nothing
    info = _tree_tip(gui)
    key = isnothing(info) ? nothing : info.key
    key == tip.hovered && return nothing
    _hide_tree_tip!(gui)
    isnothing(key) && return nothing
    tip.hovered = key
    tip.timer = Timer(_TREE_TIP_DELAY) do _
        try
            _show_tree_tip!(gui)
        catch e
            gui.last_error = _log_once(e, gui.last_error, "tooltip of the object tree")
        end
    end
    return nothing
end

"""
    _connect_tree_tips!(gui::AppView)

Gives the eyes, the buttons "+" and "−" and the counters of the object tree of the `gui` tooltips
like those of the icons of the toolbar: the tree draws them as markers of one plot, which have no
tooltip of their own. A click, scrolling and the closed window hide the tooltip.
"""
function _connect_tree_tips!(gui::AppView)
    scene = gui.fig.scene
    t = gui.layout.theme
    tip = _TreeTip(Observable(""), Observable(Point2f(0)), Observable(false), nothing, nothing)
    gui.layout.tree_tip = tip
    plot = Makie.tooltip!(scene, tip.pos, tip.text; placement = :below, visible = tip.visible,
        backgroundcolor = t.tooltip, textcolor = t.tooltip_text, outline_linewidth = 0,
        triangle_size = 6, offset = 4, fontsize = 13, textpadding = (6, 6, 4, 4), overdraw = true,
        inspectable = false)
    translate!(plot, 0, 0, _TOOLTIP_Z)
    ev = events(scene)
    listeners = gui.controls.listeners
    push!(listeners, on(_ -> (_on_tree_hover!(gui); Consume(false)), ev.mouseposition))
    push!(listeners, on(_ -> (_hide_tree_tip!(gui); Consume(false)), ev.mousebutton; priority = 300))
    push!(listeners, on(_ -> (_hide_tree_tip!(gui); Consume(false)), ev.scroll; priority = 300))
    push!(listeners, on(open -> open || _hide_tree_tip!(gui), ev.window_open))
    return nothing
end
