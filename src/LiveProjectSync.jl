#=
Working on a project while an agent changes its files: a watcher of the files of the project of a
shown view, which reloads the project when only the files changed and shows the card of the
conflict when the setup in the view changed too; `Ctrl+S` never overwrites a change of the files
silently (`BeamletOpticsProjects.ProjectChanged`)
=#

# How often the watcher looks at the files [s]
const _WATCH_INTERVAL = 1.0

"""Whether the `gui` is shown in a window that is open."""
function _shown(gui::LiveView)
    screen = Makie.getscreen(gui.fig.scene)
    isnothing(screen) && return false
    return applicable(isopen, screen) ? isopen(screen) : true
end

"""Records the files of the `project` that the `gui` just saved, see `_ProjectSync`."""
function _saved!(gui::LiveView, project)
    s = gui.sync
    s.stamp = project.stamp
    s.code = BMOP.system_code(project)
    s.pending = s.handled = nothing
    _start_watching!(gui)
    return nothing
end

"""
Whether the setup of the `gui` differs from that of the files of its project when it opened or
saved them; only the setup (`system.jl`), not the camera or the colors.
"""
function _setup_changed(gui::LiveView)
    (isnothing(gui.project) || isnothing(gui.sync.code)) && return false
    return BMOP.system_code(_collect_project(gui, gui.project)) != gui.sync.code
end

"""
Starts the watcher of the files of the project of the `gui` if it is shown, which calls
`_check_files!` every `_WATCH_INTERVAL` seconds until the window is closed. A view that is not
shown (e.g. in the tests) is not watched; `_check_files!` can be called instead.
"""
function _start_watching!(gui::LiveView)
    s = gui.sync
    (isnothing(s.timer) && !isnothing(gui.project) && _shown(gui)) || return nothing
    last_error = Ref("")
    s.timer = Timer(_WATCH_INTERVAL; interval = _WATCH_INTERVAL) do _
        _shown(gui) || return _stop_watching!(gui)
        try
            _check_files!(gui)
        catch e
            e isa InterruptException && rethrow()
            last_error[] = _log_once(e, last_error[], "watching the project")
        end
    end
    return nothing
end

"""Stops the watcher of the `gui`, see `_start_watching!`."""
function _stop_watching!(gui::LiveView)
    t = gui.sync.timer
    gui.sync.timer = nothing
    isnothing(t) || close(t)
    return nothing
end

"""
    _check_files!(gui; kwargs...) -> (; status, gui)

One look of the watcher at the files of the project of the `gui`, with the `status` `:none` if they are
as the `gui`
knows them; `:pending` when they changed, to look again at the next call, since an agent may still
be writing; when they changed and stayed so, `:reloaded` (or `:failed`, e.g. a syntax error) if the
setup in the `gui` did not change (see `_reload!`), otherwise `:conflict` with the card of the
conflict (see `_ProjectConflict`). It reacts once to each state of the files. `gui` is the view
afterwards, the new one after a reload, which gets the `kwargs` of `live_view`.
"""
function _check_files!(gui::LiveView; kwargs...)
    s = gui.sync
    (isnothing(gui.project) || isnothing(s.stamp)) && return (; status = :none, gui)
    disk = try
        BMOP.project_stamp(gui.project)
    catch e
        e isa InterruptException && rethrow()
        return (; status = :none, gui)
    end
    if disk == s.stamp
        s.pending = nothing
        return (; status = :none, gui)
    end
    # Reacted to this state already, e.g. the card of the conflict was shown
    disk == s.handled && return (; status = :none, gui)
    if disk != s.pending
        s.pending = disk
        return (; status = :pending, gui)
    end
    s.pending = nothing
    s.handled = disk
    if _setup_changed(gui)
        _show_conflict!(gui)
        return (; status = :conflict, gui)
    end
    new = _reload!(gui; kwargs...)
    return isnothing(new) ? (; status = :failed, gui) : (; status = :reloaded, gui = new)
end

"""The layout, theme and size of the window of the `gui`, for a window that replaces it."""
function _window_kwargs(gui::LiveView)
    w = Makie.widths(gui.fig.scene.viewport[])
    return (; layout = _layout_name(gui.layout), theme = _theme_name(gui.layout.theme),
        size = (round(Int, w[1]), round(Int, w[2])))
end

"""Closes the `gui` and its window, never inside an event callback of that window."""
function _close_window!(gui::LiveView)
    screen = Makie.getscreen(gui.fig.scene)
    close(gui)
    isnothing(screen) || close(screen)
    return nothing
end

"""The message of an error of loading a project: the file and line of a `LoadError`."""
function _load_message(e)
    e isa LoadError || return _message_line(e)
    msg = _message_line(e.error)
    # The macros of BeamletOpticsProjects name the line themselves
    occursin(r"\.jl:\d+", msg) && return msg
    return "$(basename(e.file)):$(e.line): $msg"
end

"""
    _reload!(gui; display = _shown(gui), kwargs...) -> Union{Nothing, LiveView}

Loads the project of the `gui` from its files again and shows it in a new window that replaces the
window of the `gui` (if `display`), with the layout, theme and size of that window and how it
looked: camera, saved views, clip planes, colors of the beams (not `view.toml`). The own code in
`src/` is loaded again too. The changes of the setup in the `gui` that were not saved are lost.
Returns the new view, or `nothing` and the reason in the status line of the `gui` if the project
could not be loaded, e.g. while an agent is still writing it; the `gui` stays then. The `kwargs` are
those of `live_view`.
"""
function _reload!(gui::LiveView; display::Bool = _shown(gui), kwargs...)
    project = try
        BMOP.load_project(gui.project)
    catch e
        e isa InterruptException && rethrow()
        gui.status.text[] = "project not reloaded: $(_load_message(e))"
        return nothing
    end
    view = _view_dict(gui, _project_parts(gui, gui.project).names)
    window = display ? _window_kwargs(gui) : (; layout = _layout_name(gui.layout))
    new = try
        _open_from(project; view, window..., kwargs...)
    catch e
        e isa InterruptException && rethrow()
        @error "reloading the project failed" exception = (e, catch_backtrace())
        gui.status.text[] = "project not reloaded: $(_message_line(e))"
        return nothing
    end
    new.status.text[] = "project reloaded from $(project.path)"
    if display
        title = basename(project.path)
        _multi_light_backend() ? Base.display(new; title) : Base.display(new)
        _start_watching!(new)
        _close_window!(gui)
    else
        close(gui)
    end
    return new
end

"""`Ctrl+R` of the `gui`: loads its project from the files again, see `_reload!`."""
function _reload_key!(gui::LiveView)
    if isnothing(gui.project)
        gui.status.text[] = "no project to reload: open or save one first"
        return nothing
    end
    _run_later(() -> (_reload!(gui); nothing))
    return nothing
end

#=
The card of the conflict
=#

"""
    _ProjectConflict

The files of the project of the view changed outside of it (e.g. by an agent) and its setup changed
too: an info card at `point` with what happened and three buttons, see `_resolve_conflict!`.
Shown by `Ctrl+S` (see `_save_to!`) and by the watcher (see `_check_files!`).
"""
struct _ProjectConflict <: _InfoItem
    point::Point3f
end

_points(x::_ProjectConflict) = [x.point]
_title(::_ProjectConflict) = "Project changed on disk"
_tree_kind(::_ProjectConflict) = :warning
_keep_plots!(::LiveView, ::_ProjectConflict) = nothing
_keepable(::_ProjectConflict) = false
card_rows(::_ProjectConflict) = (
    _text_row("files", :conflict_files, (_, _) -> "changed outside, e.g. by an agent"; width = 48),
    _text_row("here", :conflict_here, (_, _) -> "changes that are not saved"; width = 48),
    CardRow(
        CardWidget(Button; name = :conflict_load, label = "Load from disk",
            on = (gui, _, _) -> _resolve_conflict!(gui, :load)),
        CardWidget(Button; name = :conflict_overwrite, label = "Overwrite",
            on = (gui, _, _) -> _resolve_conflict!(gui, :overwrite)),
        CardWidget(Button; name = :conflict_save_as, label = "Save as…",
            on = (gui, _, _) -> _resolve_conflict!(gui, :save_as))))

"""Shows the card of the conflict of the `gui`, see `_ProjectConflict`."""
function _show_conflict!(gui::LiveView)
    _show_info!(gui, _ProjectConflict(_error_anchor(gui)))
    gui.status.text[] = "the project changed on disk and here: choose on the card"
    return nothing
end

"""
Resolves the conflict of the `gui` (see `_ProjectConflict`) as the user chose, `how`: `:load` the
files (the changes here are lost, see `_reload!`), `:overwrite` them with the setup here, or
`:save_as` a new project (see `_save_as_key!`), which leaves the files as they are.
"""
function _resolve_conflict!(gui::LiveView, how::Symbol)
    _release_info!(gui, _ProjectConflict)
    if how === :load
        # Replaces the window: after the callback of its button returned
        _run_later(() -> (_reload!(gui); nothing))
    elseif how === :overwrite
        _save_to!(gui, gui.project; force = true)
    else
        _save_as_key!(gui)
    end
    return nothing
end
