#=
Several windows on the same systems: a system of a live view opens in a second live view, which is
linked with the first one, see `open_system` and `_ViewLinks`. The view in which something changes
solves, the linked views follow, see `_sync_links!`
=#

# Status of a view whose beams are outdated because a linked view changed a system of both
const _LINK_STALE = "outdated, changed in another window"
const _LINK_TRACED = "traced in another window"

"""The systems that the live views `a` and `b` both show."""
_shared_systems(a::LiveView, b::LiveView) =
    BMO.AbstractSystem[sys for sys in _systems(a) if !isnothing(_system_handle(b, sys))]
_shares_system(a::LiveView, b::LiveView) =
    any(h -> !isnothing(_system_handle(b, rendered(h))), a.system_handles)

"""Whether the `gui` shows `obj`, as an object of its systems, as an extra or as a source."""
_shows(::LiveView, ::Nothing) = false
_shows(gui::LiveView, @nospecialize(obj)) = any(p -> p.second === obj, gui.pairs) ||
                             any(leaf -> !isnothing(_child_handle(gui.controls.h, leaf)), _leaves(obj))

"""The name of the `theme` kwarg of `live_view` with the color tokens `tokens`, see `_app_theme`."""
function _theme_name(tokens)
    name = _index(_APP_THEMES, tokens)
    return isnothing(name) ? :light : name
end

"""
    _note_stale!(gui, obj)

Records why the beams of the `gui` are outdated: the change of `obj` in the `gui` itself, i.e. the
systems of `obj` in `stale_systems`, or all systems for `nothing` or an object without a system
(`stale_all`), see `_TraceState`. A linked view that traces these systems brings the `gui` up to
date, see `_follow_solved!`.
"""
function _note_stale!(gui::LiveView, @nospecialize(obj))
    trace = gui.trace
    trace.link_stale = false
    systems = _systems_of(gui, obj)
    isempty(systems) && (trace.stale_all = true)
    for sys in systems
        _has(trace.stale_systems, sys) || push!(trace.stale_systems, sys)
    end
    return nothing
end

# The systems of the `gui` that `obj` belongs to: those it is traced through, or those that hold it
_systems_of(::LiveView, ::Nothing) = BMO.AbstractSystem[]
function _systems_of(gui::LiveView, @nospecialize(obj))
    systems = BMO.AbstractSystem[p.first for p in gui.pairs if p.second === obj]
    isempty(systems) || return systems
    top = _component_top(gui, obj)
    return BMO.AbstractSystem[rendered(h) for h in gui.system_handles
                              if _has(rendered(h).objects, top)]
end

"""The beams of the `gui` are up to date, after its solve or that of a linked view."""
function _set_fresh!(gui::LiveView)
    trace = gui.trace
    trace.stale = trace.link_stale = trace.stale_all = false
    empty!(trace.stale_systems)
    return nothing
end

# The `table` kwarg of `live_view` that builds the table `t` again
_table_kwarg(::Nothing) = false
_table_kwarg(t) = (; t.shown, t.pitch, t.height, t.snap)

"""
    _open_kwargs(gui, system, sources) -> NamedTuple

The kwargs of `live_view` with which [`open_system`](@ref) opens the `system` of the `gui` with its
`sources`: what the new window takes over, i.e. the layout, the theme, the catalog, the labels, how
the system and the beams are drawn, the beams that are switched off, the tracing, the snapping, the
table and the settings of the controls, e.g. the steps of the keys and the constraints.
"""
function _open_kwargs(gui::LiveView, system, sources)
    ctrl = gui.controls
    trace = gui.trace
    # The markers of the sources, as in a view with `movable_sources`
    markers = all(src -> BMO.is_static(src) || !isnothing(_child_handle(ctrl.h, src)), sources)
    return (; layout = _layout_name(gui.layout), theme = _theme_name(gui.layout.theme),
        auto_trace = trace.auto[], trace_budget = trace.budget, trace.idle_delay,
        preview = trace.preview_enabled, trace.progress_delay,
        system_kwargs = gui.components.render_kwargs,
        beam_kwargs = IdDict{Any, Any}(src => _snapshot(gui, src).kwargs for src in sources),
        beams_off = Tuple(src for src in sources if !_beam_on(gui, src)),
        movable_sources = markers, show_sources = gui.widgets.sources_toggle.active[],
        labels = gui.labels, catalog = gui.components.catalog,
        orthographic = gui.widgets.orthographic_toggle.active[],
        view_cube = !isnothing(gui.widgets.view_cube), snap = ctrl.snap[],
        table = _table_kwarg(gui.components.table),
        # the controls
        ctrl.rotation_axis, ctrl.plane_normal, ctrl.rotate_speed, ctrl.fine_step, ctrl.fine_angle,
        ctrl.throttle, ctrl.select_modifier, ctrl.drag_threshold, ctrl.constraints,
        ctrl.source_pick_radius)
end

function open_system(gui::LiveView, system::BMO.AbstractSystem; display::Bool = true, kwargs...)
    isnothing(_system_handle(gui, system)) &&
        throw(ArgumentError("the system is not a system of the live view"))
    sources = Any[p.second for p in gui.pairs if p.first === system]
    args = isempty(sources) ? (system,) : Tuple(system => src for src in sources)
    new = live_view(args...; _open_kwargs(gui, system, sources)..., kwargs...)
    _link!(gui, new, system)
    # The name of the system is the title of the window of GLMakie
    display && (_multi_light_backend() ? Base.display(new; title = _label(gui, system)) : Base.display(new))
    return new
end

"""
    _open_system!(gui, system)

The button "new window" of the card of the `system`: opens it in a new window, see
[`open_system`](@ref). What can not be opened, e.g. the extras, only shows a message in the status
line.
"""
function _open_system!(gui::LiveView, system)
    if isnothing(_system_handle(gui, system))
        gui.status.text[] = "$(_label(gui, system)) is not a system, it can not be opened in a window"
        return nothing
    end
    open_system(gui, system)
    gui.status.text[] = "$(_label(gui, system)) opened in a new window"
    return nothing
end

"""
    _link!(gui, new, system)

Links the live view `new`, which shows the `system` of the `gui` and its sources, with the `gui` and
the views that are linked with it, see `_ViewLinks`: `new` shares the labels and the names of the
`gui`, and knows what the `gui` recorded of the components and sources of the `system` (those that
were added and removed, their origins and the poses from which [`export_changes`](@ref) counts),
such that both export the same changes of the system.
"""
function _link!(gui::LiveView, new::LiveView, system)
    links = gui.links
    if isempty(links.views)
        push!(links.views, gui)
        _watch_window!(gui)
    end
    # The names of the objects of the system as the `gui` has them, beside those of `new` itself,
    # e.g. of its handles
    names = gui.objects.names
    for (key, name) in new.objects.names
        haskey(names, key) || (names[key] = name)
    end
    names[_system_handle(new, system)] = _label(gui, system)
    new.objects.names = names
    new.objects.counters = gui.objects.counters
    new.labels = gui.labels
    from, to = gui.components, new.components
    for obj in from.added
        get(from.system, obj, nothing) === system || continue
        push!(to.added, obj)
        to.system[obj] = system
        to.origin[obj] = get(from.origin, obj, nothing)
    end
    for obj in from.removed
        if haskey(from.source_systems, obj)
            _has(from.source_systems[obj], system) || continue
            to.source_systems[obj] = Any[system]
        elseif get(from.system, obj, nothing) === system
            to.system[obj] = system
        else
            continue
        end
        push!(to.removed, obj)
    end
    init = new.controls.init_poses
    for (obj, pose) in gui.controls.init_poses
        haskey(init, obj) && (init[obj] = pose)
    end
    new.links = links
    push!(links.views, new)
    _watch_window!(new)
    _refresh_names!(new)
    # One switch of the auto tracing for all of them: the one of `new`, which is the one of the
    # `gui` unless a kwarg of `open_system` set it, see `_connect_links!`
    _share_auto_trace!(new, new.trace.auto[])
    return nothing
end

# Sets the switch of the auto tracing of the views that are linked with the `gui` like its own
function _share_auto_trace!(gui::LiveView, active::Bool)
    _each_linked(gui) do view
        view.trace.auto[] == active || (view.trace.auto[] = active)
        return nothing
    end
    return nothing
end

"""
Connects what the `gui` shares with the views that are linked with it beside their objects, see
`_link!`: the switch of the auto tracing. The linked views solve for each other, such that one of
them that traces on its own would bring the other ones up to date although their auto tracing is
off. Nothing for a view on its own.
"""
function _connect_links!(gui::LiveView)
    push!(gui.controls.listeners, on(active -> _share_auto_trace!(gui, active), gui.trace.auto))
    return nothing
end

# The window of a linked view that is closed ends its link
function _watch_window!(gui::LiveView)
    push!(gui.controls.listeners, on(events(gui.fig.scene).window_open) do open
        open || _unlink!(gui)
        return nothing
    end)
    return nothing
end

"""
    _unlink!(gui)

Ends the link of the `gui` with the other views of its systems, e.g. when it is closed: they no
longer follow it, nor it them. It keeps its names, which it no longer shares. Nothing for a view on
its own.
"""
function _unlink!(gui::LiveView)
    links = gui.links
    isempty(links.views) && return nothing
    filter!(v -> v !== gui, links.views)
    # the last view is on its own again
    length(links.views) == 1 && empty!(links.views)
    gui.links = _ViewLinks()
    gui.objects.names = copy(gui.objects.names)
    gui.objects.counters = copy(gui.objects.counters)
    gui.labels = copy(gui.labels)
    # outdated until it traces itself
    gui.trace.link_stale && _note_stale!(gui, nothing)
    return nothing
end

# Shows the names of the objects of the `gui` again, e.g. in the menu and in the object tree
function _refresh_names!(gui::LiveView)
    _refresh_menu_options!(gui, gui.widgets.menu)
    _on_components_changed!(gui)
    _update_inspector!(gui)
    return nothing
end

"""
    _each_linked(f, gui)

Calls `f(view)` for each view that is linked with the `gui`, see `_ViewLinks`, unless the `gui`
itself follows one: what a view does while it follows is not sent back. An error of a view is
logged, such that the `gui` and the other views go on.
"""
function _each_linked(f, gui::LiveView)
    links = gui.links
    (isempty(links.views) || links.following) && return nothing
    links.following = true
    try
        for view in copy(links.views)
            view === gui && continue
            try
                f(view)
            catch e
                e isa InterruptException && rethrow()
                view.last_error = _log_once(e, view.last_error, "following a linked view")
            end
        end
    finally
        links.following = false
    end
    return nothing
end

"""
    _sync_links!(gui, obj; stale, preview = false)

Called by the `gui` after it solved (`stale = false`; `preview` after a preview solve, see
`_apply!`) and when its beams become outdated (`stale = true`), after `obj` changed (or `nothing`):
the views that are linked with it follow, see `_follow!`.
"""
_sync_links!(gui::LiveView, @nospecialize(obj); stale::Bool, preview::Bool = false) =
    _each_linked(view -> _follow!(view, gui, obj; stale, preview), gui)

"""
    _sync_structure!(gui)

Called by the `gui` after a component or a source was added to or removed from it, before it
solves: the views that are linked with it show the same components and sources, see
`_follow_structure!`. A solve in the background must not run meanwhile, which holds here, since
adding and removing cancel it.
"""
_sync_structure!(gui::LiveView) = _each_linked(view -> _follow_structure!(view, gui), gui)

"""Shows the names of the objects again in the views that are linked with the `gui`."""
_refresh_links!(gui::LiveView) = _each_linked(_refresh_names!, gui)

"""
    _cancel_linked!(gui)

Cancels the jobs of the views that are linked with the `gui` and share a system with it, before the
`gui` changes or solves: they trace the same beams or read the hits of the same detectors. A view
whose solve was cancelled solves again once the changes pause, like after a deferred change (see
`_on_idle!`); one that only computed detector views is outdated until the `gui` has solved.
"""
function _cancel_linked!(gui::LiveView)
    _each_linked(gui) do view
        job = view.trace.job
        (isnothing(job) || isempty(_shared_systems(view, gui))) && return nothing
        trace = view.trace
        fresh = !trace.stale
        _cancel!(view, job)
        if _solves(job)
            trace.pending = trace.auto[]
            trace.pending_obj = nothing
            trace.last_change = time()
        elseif fresh
            trace.link_stale = true
            trace.stale_all = false
            view.status.text[] = _LINK_STALE
        end
        return nothing
    end
    return nothing
end

"""
    _follow!(gui, from, obj; stale, preview)

The `gui` follows the linked view `from`, which changed a system that both show (the object `obj`,
or `nothing`): it shows the same sources and components (see `_follow_structure!`, not while a job
runs in the background, which traces them), the poses of the objects, and then either the beams as
`from` traced them (see `_follow_solved!`) or, if they are `stale`, dimmed beams. The `gui` does
not solve. A change of an object that the `gui` does not show, e.g. of another system of `from`,
changes nothing for it, unless the solve of `from` brings its outdated beams up to date.
"""
function _follow!(gui::LiveView, from::LiveView, @nospecialize(obj); stale::Bool, preview::Bool)
    systems = _shared_systems(gui, from)
    isempty(systems) && return nothing
    foreign = !isnothing(obj) && !_shows(gui, obj)
    (foreign && (stale || !gui.trace.stale)) && return nothing
    # The changes pause for both, see `_on_idle!`
    gui.trace.last_change = time()
    any(view -> _running(view.trace.job), gui.links.views) || _follow_structure!(gui, from, systems)
    _follow_switches!(gui, from, systems)
    update_render!(gui.controls.h)
    _update_selection_box!(gui.controls)
    _shows(gui, obj) && _table_include!(gui, obj)
    if stale
        _follow_stale!(gui)
    else
        _follow_solved!(gui, from, systems, obj; preview)
    end
    _update_inspector!(gui)
    return nothing
end

"""
    _follow_structure!(gui, from[, systems])

Shows the sources and the components of the `systems` that the `gui` shares with the linked view
`from` as `from` has them: a source or component that `from` no longer has is let go of (see
`_detach!`), one that the `gui` lacks is shown (see `_attach!`), with the origin and, for a source,
the kwargs that it has in `from`. The entries of the undo history of the `gui` on these objects are
dropped, since they no longer apply. A source that the `gui` traces through another system as well
is left as it is.
"""
function _follow_structure!(gui::LiveView, from::LiveView, systems = _shared_systems(gui, from))
    changed = Any[]
    origin(obj) = get(from.components.origin, obj, nothing)
    for sys in systems
        theirs = Any[p.second for p in from.pairs if p.first === sys]
        mine = Any[p.second for p in gui.pairs if p.first === sys]
        for src in mine
            _has(theirs, src) && continue
            _detach!(gui, src)
            push!(changed, src)
        end
        for src in theirs
            any(p -> p.second === src, gui.pairs) && continue
            # The overlays are shown per window
            kwargs = Base.structdiff(
                merge(get(from.beams.overlay_kwargs, src, (;)), get(from.beams.kwargs, src, (;))),
                NamedTuple{(:show_polarization, :show_beams)})
            _attach!(gui, src, sys; origin = origin(src), beam_kwargs = kwargs)
            push!(changed, src)
        end
        # The objects of a `StaticSystem` do not change
        sys isa BMO.System || continue
        h = _system_handle(gui, sys)
        for obj in _top_levels(h)
            _has(sys.objects, obj) && continue
            _detach!(gui, obj, sys)
            append!(changed, _component_parts(obj))
        end
        shown = _top_levels(h)
        for obj in sys.objects
            _has(shown, obj) && continue
            leaves = _leaves(obj)
            # nothing to show, or shown elsewhere, e.g. as an extra
            (isempty(leaves) || any(leaf -> !isnothing(_child_handle(gui.controls.h, leaf)), leaves)) &&
                continue
            _attach!(gui, obj, sys; origin = origin(obj))
            append!(changed, _component_parts(obj))
        end
    end
    isempty(changed) || _drop_history!(gui.controls, changed)
    return nothing
end

"""
The beams of the shared `systems` are switched on and off in the `gui` as in the linked view `from`,
without solving, see `_set_beam_on!`.
"""
function _follow_switches!(gui::LiveView, from::LiveView, systems)
    for src in unique(objectid, Any[p.second for p in gui.pairs if any(s -> s === p.first, systems)])
        any(p -> p.second === src, from.pairs) || continue
        on = _beam_on(from, src)
        _beam_on(gui, src) == on && continue
        if on
            delete!(gui.beams.off, src)
            _show_beam!(gui, src, true)
        else
            _set_beam_off!(gui, src)
        end
        _update_info!(gui)
    end
    return nothing
end

# The beams of the `gui` are outdated because of a linked view, until that view has solved
function _follow_stale!(gui::LiveView)
    gui.trace.stale && return nothing
    _dim_beams!(gui)
    gui.trace.stale = true
    gui.trace.link_stale = true
    gui.status.text[] = _LINK_STALE
    return nothing
end

"""
    _follow_solved!(gui, from, systems, obj; preview)

Shows in the `gui` what the linked view `from` traced through the shared `systems`: the beams and
their overlays, and, after a full solve, the detector views (computed at once if they are fast,
otherwise once the changes pause, see `_views_idle!`), the user `on_change` (with `obj` if the
`gui` shows it) and the panels. The `gui` is up to date again if it was outdated only because of a
linked view, or because of changes of the `systems`, which `from` traced, see `_note_stale!`.
"""
function _follow_solved!(gui::LiveView, from::LiveView, systems, @nospecialize(obj); preview::Bool)
    trace = gui.trace
    shared(sys) = _has(systems, sys)
    for (p, h) in zip(gui.pairs, gui.beam_handles)
        (shared(p.first) && _beam_on(gui, p.second)) && update_render!(h)
    end
    for store in _overlay_stores(gui), (beam, h) in store
        _beam_on(gui, beam) && update_render!(h)
    end
    # Up to date again, if `from` traced what made the `gui` outdated
    if trace.stale && (trace.link_stale || (!trace.stale_all && all(shared, trace.stale_systems)))
        _restore_beams!(gui)
        _set_fresh!(gui)
        trace.pending = false
        gui.status.text[] = _LINK_TRACED
    end
    states = _DetectorState[gui.detectors.states[pd] for pd in _find_detectors(systems)
                            if haskey(gui.detectors.states, pd)]
    foreach(state -> state.stale = true, states)
    preview && return nothing
    if !trace.stale
        gui.detectors.hits_valid = true
        if trace.view_time <= trace.budget
            _refresh_views!(gui)
        else
            now = time()
            foreach(state -> state.window_changed = now, states)
        end
    end
    try
        gui.on_change(gui, _shows(gui, obj) ? obj : nothing)
        gui.last_error = nothing
    catch e
        gui.last_error = _log_once(e, gui.last_error, "`on_change` callback")
    end
    _update_user_panels!(gui)
    _on_solved!(gui)
    return nothing
end
