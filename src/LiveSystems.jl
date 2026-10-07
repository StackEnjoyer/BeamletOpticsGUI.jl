#=
Systems that are added to and removed from the live view at runtime, see `add_system!` and
`remove_system!`. The objects of the view belong to any number of its systems, see `_add_member!`
in `LiveComponents.jl`, and a source to at most one, see `_set_source_system!` in `LiveSources.jl`
=#

"""
Connects what the `gui` offers for its systems: the tool "System" among the tools of the layout,
which adds an empty system (see `add_system!`), and the picking of members with the mouse, see
`_connect_member_pick!`.
"""
function _connect_systems!(gui::LiveView)
    add_tool!(g -> (add_system!(g); nothing), gui, "System"; icon = :system,
        tooltip = "Add an empty system")
    _connect_member_pick!(gui)
    return nothing
end

# The name of a new system of the `gui`: "System n" with the smallest n that no system has
function _new_system_name(gui::LiveView)
    names = Set{String}(_label(gui, rendered(h)) for h in gui.system_handles)
    n = length(gui.system_handles) + 1
    while "System $n" in names
        n += 1
    end
    return "System $n"
end

function add_system!(gui::LiveView; label = nothing, select::Bool = true)
    sys = BMO.System()
    h = LiveSystemHandle(sys, AbstractObjectRenderHandle[], AbstractSystemRenderHandle[gui.pool])
    name = isnothing(label) ? _new_system_name(gui) : String(label)
    isnothing(label) || (gui.labels[sys] = name)
    gui.objects.names[h] = gui.objects.names[sys] = name
    _insert_system!(gui, h, length(gui.system_handles) + 1)
    if select
        _inspect!(gui, sys)
        # The system gets the next component of the catalog, see `_catalog_target`
        gui.components.target = sys
        gui.components.target_shown = _shown_object(gui)
        _refresh_catalog!(gui)
    end
    gui.status.text[] = "$name added, it gets the next component"
    if gui.components.recording
        taken = Ref{Any}(nothing)
        _push_action!(gui.controls, sys, () -> (taken[] = _take_system!(gui, sys)),
            () -> _put_system!(gui, taken[]))
    end
    return sys
end

# Shows the system of the handle `h` as the `i`-th system of the `gui`
function _insert_system!(gui::LiveView, h::AbstractSystemRenderHandle, i::Integer)
    insert!(gui.system_handles, clamp(i, 1, length(gui.system_handles) + 1), h)
    _refresh_systems!(gui)
    return nothing
end

# The menus, the tree and the catalog of the `gui` list its systems again
function _refresh_systems!(gui::LiveView)
    _refresh_menu_options!(gui, gui.widgets.menu)
    _on_components_changed!(gui)
    _refresh_catalog!(gui)
    _update_info!(gui)
    _update_inspector!(gui)
    return nothing
end

"""
    _take_system!(gui, sys) -> (; handle, index, sources, orphans)

Takes the system `sys` out of the `gui` without recording it: its `sources` have no system
afterwards (see `_set_source_system!`), and neither have its objects that are in no other system
of the view (`orphans`), which stay in the view, see `_live_render_extras!`. The objects of `sys`
itself are not changed. Returns what `_put_system!` needs to show it again.
"""
function _take_system!(gui::LiveView, sys::BMO.AbstractSystem)
    h = _system_handle(gui, sys)
    index = _index(gui.system_handles, h)
    # Stops a solve in the background, which traces the objects of the system
    _change!(() -> nothing, gui.controls, nothing)
    _end_member_pick!(gui)
    gui.objects.inspected === sys && _end_inspection!(gui)
    sources = _sources_of(gui, sys)
    _unrecorded(gui) do
        foreach(src -> _set_source_system!(gui, src, nothing), sources)
    end
    deleteat!(gui.system_handles, index)
    extras = rendered(gui.extras)
    orphans = Any[]
    for obj in sys.objects
        (isempty(_member_systems(gui, obj)) && !_has(extras.objects, obj)) || continue
        push!(orphans, obj)
        push!(extras, obj)
        foreach(oh -> _has(render_children(gui.extras), oh) || push!(gui.extras, oh), _pool_handles(gui, obj))
        # no hits of a system that is gone
        foreach(leaf -> leaf isa BMO.Detector && empty!(leaf), _leaves(obj))
    end
    comp = gui.components
    comp.target === sys && (comp.target = comp.target_shown = nothing)
    delete!(gui.trace.manual, sys)
    filter!(s -> s !== sys, gui.trace.stale_systems)
    _refresh_systems!(gui)
    return (; handle = h, index, sources, orphans)
end

# Shows the system that `_take_system!` took out of the `gui` again, as `taken` describes it
function _put_system!(gui::LiveView, taken)
    h = taken.handle
    sys = rendered(h)
    _change!(() -> nothing, gui.controls, nothing)
    extras = rendered(gui.extras)
    for obj in taken.orphans
        _has(extras.objects, obj) || continue
        delete!(extras, obj)
        foreach(oh -> delete!(gui.extras, oh), _pool_handles(gui, obj))
    end
    _insert_system!(gui, h, taken.index)
    _unrecorded(gui) do
        for src in taken.sources
            any(p -> p.second === src, gui.pairs) && _set_source_system!(gui, src, sys)
        end
    end
    return nothing
end

function remove_system!(gui::LiveView, sys::BMO.AbstractSystem)
    isnothing(_system_handle(gui, sys)) &&
        throw(ArgumentError("the system is not shown in the live view"))
    length(gui.system_handles) > 1 ||
        throw(ArgumentError("the last system of a live view can not be removed"))
    any(v -> v !== gui && !isnothing(_system_handle(v, sys)), gui.links.views) && throw(ArgumentError(
        "$(_label(gui, sys)) is open in another window, close that window first"))
    name = _label(gui, sys)
    taken = Ref{Any}(_take_system!(gui, sys))
    gui.status.text[] = "$name removed, its components stay in the view"
    # The detectors that it shares with other systems lose its hits
    _on_change!(gui, nothing)
    if gui.components.recording
        _push_action!(gui.controls, sys, () -> (_put_system!(gui, taken[]); _on_change!(gui, nothing)),
            () -> (taken[] = _take_system!(gui, sys); _on_change!(gui, nothing)))
    end
    return sys
end

"""
    _remove_system!(gui, sys) -> Bool

Removes the system `sys` from the `gui` like `remove_system!`, after "remove" on its card. A system
that can not be removed is kept, and the status line names the reason. Returns whether it was
removed.
"""
function _remove_system!(gui::LiveView, sys::BMO.AbstractSystem)
    try
        remove_system!(gui, sys)
        return true
    catch e
        e isa ArgumentError || rethrow()
        gui.status.text[] = e.msg
        return false
    end
end
