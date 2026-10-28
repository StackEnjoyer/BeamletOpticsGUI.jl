#=
The watcher of the files of a project of a shown window: it looks at the files in the background
(see `_take_look!`), merges a change of them once they settled, or at the latest every
`_MERGE_EVERY` seconds while they keep changing (`_check_files!`, `_sync!`), and calls the autosave
and the presence; see `LiveProjectSync.jl`. Notifications of the file system (`_FileNotes`) start a
look at once; the polling stays as a safety net
=#

import FileWatching

# How often the watcher wakes up for the autosave and the presence, and looks at the times of the
# files without notifications [s]
const _WATCH_INTERVAL = 0.2
# How often the watcher looks at the times of the files while notifications run [s]. Stays at
# `_WATCH_INTERVAL` until `benchmark/watch_notify.jl` showed on the shared drive that the
# notifications of a write of another machine arrive (D7 of the plan: then 2 s)
const _POLL_WITH_MONITOR = 0.2
# How often a look reads the contents of the files for their stamp, while their times stay [s]
const _STAMP_EVERY = 2.0
# How long a look may wait in the background before the window reads the files itself [s]
const _LOOK_WAIT = 1.0
# How long the files must stay unchanged before they are loaded [s], an agent writes in steps
const _SETTLE = 0.3
# How long the files may keep changing before they are loaded anyway [s], e.g. while several
# participants write one after the other
const _MERGE_EVERY = 2.0

"""
The times and sizes of the files of the project in `dir` that define the setup: `system.jl` and
the `.jl` files of `src/`, without names that start with `.` (e.g. `._X.jl` that macOS writes on
a shared drive), like `project_stamp`. Cheap enough to be looked at often, see `_check_files!`.
"""
function _file_marks(dir::AbstractString)
    marks = Tuple{String, Float64, Int}[]
    file = joinpath(dir, "system.jl")
    isfile(file) && push!(marks, ("system.jl", mtime(file), filesize(file)))
    src = joinpath(dir, "src")
    if isdir(src)
        for (root, dirs, names) in walkdir(src)
            filter!(d -> !startswith(d, "."), dirs)
            for n in names
                (endswith(n, ".jl") && !startswith(n, ".")) || continue
                path = joinpath(root, n)
                push!(marks, (relpath(path, dir), mtime(path), filesize(path)))
            end
        end
    end
    return sort!(marks)
end

_src_marks(marks) = filter(m -> m[1] != "system.jl", marks)

"""
    _files_look(dir; stamp = true, except = nothing, known = String[], presence = nothing) -> (; dir, marks, stamp, presences, known, present)

What one look of the watcher reads of the project folder `dir`: the times and sizes of its files
(`_file_marks`), the stamp of their contents if `stamp` (else `nothing`), the presence files of the
others without the id `except` (`BeamletOpticsProjects.read_presences`) and of the ids `known` those
whose presence file is still there (`present`), also if it does not parse. Writes the own presence
file first if `presence` (see `_presence_data`). Touches no state of a window, so that it can run
in the background.
"""
function _files_look(dir::AbstractString; stamp::Bool = true, except = nothing, known = String[],
        presence = nothing)
    isnothing(presence) || _write_presence_file(dir, presence)
    marks = _file_marks(dir)
    st = stamp ? BMOP.project_stamp(dir) : nothing
    presences = BMOP.read_presences(dir; except)
    known = Set{String}(known)
    present = Set{String}(id for id in known if isfile(_presence_file(dir, id)))
    return (; dir = String(dir), marks, stamp = st, presences, known, present)
end

"""
    _take_look!(gui; now = time()) -> look or nothing

The result of the look of the watcher of the `gui` that ran in the background (see `_files_look`)
if it is done, and starts the next one; `nothing` while it runs. On a shared drive every access
to a file waits for the network, often longer than a frame: the window never waits for it.

- A look reads the stamp of the contents at most every `_STAMP_EVERY` seconds and only while the
  files are settled, and writes the own presence file when it is due (see `_presence_due!`).
- A look that started before the last save of the window (see `_saved!`) or before a look here is
  dropped; one of another folder too.
- While a look waits longer than `_LOOK_WAIT` seconds, e.g. behind a solve on the only thread of
  the background (a solve does not yield), the files are read here instead, without the stamp, at
  most every `_LOOK_WAIT` seconds, so that changes of the files and the own presence go on.
- An error of a look is thrown here once, after the next look started.
"""
function _take_look!(gui::LiveView; now::Real = time())
    s = gui.sync
    dir = gui.project
    run = s.look
    if !isnothing(run) && !istaskdone(run.task)
        (isnothing(dir) || now - s.look_at < _LOOK_WAIT) && return nothing
        s.look_at = Float64(now)
        s.gen += 1
        # Two writes of the own presence file at a time would share its temporary file
        presence = run.presence ? nothing : _presence_due!(gui, now)
        return _files_look(dir; stamp = false, except = _person().id, known = collect(keys(s.others)), presence)
    end
    s.look = nothing
    look = failed = nothing
    if !isnothing(run)
        try
            look = fetch(run.task)
        catch e
            e isa TaskFailedException || rethrow()
            failed = e.task.exception
            # The presence file of the failed look is written by the next one
            run.presence && (s.presence_due = true)
        end
    end
    isnothing(dir) && return nothing
    stamp = isnothing(s.changed_at) && now - s.stamp_at >= _STAMP_EVERY
    stamp && (s.stamp_at = Float64(now))
    except = _person().id
    known = collect(keys(s.others))
    presence = _presence_due!(gui, now)
    task = Threads.@spawn _files_look(dir; stamp, except, known, presence)
    s.look = (; task, gen = s.gen, presence = !isnothing(presence))
    s.look_at = Float64(now)
    isnothing(failed) || throw(failed)
    (isnothing(look) || run.gen != s.gen || look.dir != dir) && return nothing
    return look
end

"""
    _FileNotes

The notifications of changes of the files of the project in `dir`, see `_file_notes`: `wake` wakes
the watcher up (also its timer, see `_start_watching!`), `notes` whether notifications are wanted,
`monitors` the `FileWatching.FolderMonitor`s (none: the watcher polls every `_WATCH_INTERVAL`
seconds), `poll` how often the watcher polls while they run, `first` the time of the first
notification that no look answered yet (`0.0`: none), `last` the time of the last one and `waited`
the task of the look whose end wakes the watcher up, see `_watch_step!`.
"""
mutable struct _FileNotes
    wake::Base.Event
    dir::String
    notes::Bool
    monitors::Vector{FileWatching.FolderMonitor}
    poll::Float64
    first::Float64
    last::Float64
    waited::Union{Nothing, Task}
end

"""
    _file_notes(dir; notes = true, poll = _POLL_WITH_MONITOR) -> _FileNotes

Starts the notifications of changes of the files of the project in `dir`: a
`FileWatching.FolderMonitor` of the folder and of its folders `src/` and `.bmo/` (those that
exist), each followed by a task that wakes the watcher up. Without monitors if `notes` is `false`
or if one of them fails to start (e.g. on a drive that does not send them); the watcher polls every
`_WATCH_INTERVAL` seconds then, else every `poll` seconds.
"""
function _file_notes(dir::AbstractString; notes::Bool = true, poll::Real = _POLL_WITH_MONITOR)
    n = _FileNotes(Base.Event(true), String(dir), notes, FileWatching.FolderMonitor[], Float64(poll),
        0.0, 0.0, nothing)
    _monitor!(n)
    return n
end

# Starts the monitors of the notifications `n` for the folders of `n.dir`, see `_file_notes`
function _monitor!(n::_FileNotes)
    n.notes || return nothing
    try
        for d in (n.dir, joinpath(n.dir, "src"), joinpath(n.dir, ".bmo"))
            isdir(d) && push!(n.monitors, FileWatching.FolderMonitor(d))
        end
    catch e
        e isa InterruptException && rethrow()
        foreach(close, n.monitors)
        empty!(n.monitors)
        @debug "no notifications of changes of the files of $(n.dir), polling" exception = e
        return nothing
    end
    foreach(m -> @async(_follow_notes!(n, m)), n.monitors)
    return nothing
end

# The notifications `n` follow the project of a view that was saved to another folder `dir`
function _renew_notes!(n::_FileNotes, dir::AbstractString)
    foreach(close, n.monitors)
    empty!(n.monitors)
    n.dir = String(dir)
    _monitor!(n)
    return nothing
end

# Wakes the watcher up for each change in the folder of the monitor `m`, until `m` is closed
function _follow_notes!(n::_FileNotes, m::FileWatching.FolderMonitor)
    while true
        try
            wait(m)
        catch
            # closed (`EOFError`) or failed: the polling goes on
            return nothing
        end
        n.last = time()
        n.first == 0.0 && (n.first = n.last)
        notify(n.wake)
    end
end

"""Stops the notifications `n` (see `_file_notes`) and wakes the watcher up for its end."""
function _close_notes!(n::_FileNotes)
    foreach(close, n.monitors)
    empty!(n.monitors)
    notify(n.wake)
    return nothing
end

"""
    _start_watching!(gui; notes = true, poll = _POLL_WITH_MONITOR)

Starts the watcher of the files of the project of the `gui` if it is shown, the file
`.bmo/session.md` (see `_connect_session!`) and the presence file of the window, written again when
the selection changes (see `LiveProjectPresence.jl`). Every `_WATCH_INTERVAL` seconds until the
window is closed, and at once after a notification of a change of the files (see `_file_notes`,
none if `notes` is `false`), the watcher takes a step, see `_watch_step!`: a look at the files every
`poll` seconds while the notifications run, else every `_WATCH_INTERVAL` seconds, read in the
background (see `_take_look!`), `_check_files!` and `_check_presence!` with it once there is a new
one, and `_autosave!` and `_draw_presence!` every time. A view that is not shown (e.g. in the tests
or of a script) is not watched and writes neither; the functions can be called instead.
"""
function _start_watching!(gui::LiveView; notes::Bool = true, poll::Real = _POLL_WITH_MONITOR)
    s = gui.sync
    (isnothing(s.timer) && !s.closed && !isnothing(gui.project) && _shown(gui)) || return nothing
    _connect_session!(gui)
    # The presence file is written by the looks of the watcher, see `_presence_due!`
    s.presence_due = true
    push!(gui.controls.listeners, on(gui.controls.selected) do _
        gui.sync.presence_due = true
        return nothing
    end)
    n = _file_notes(gui.project; notes, poll)
    s.monitor = n
    s.timer = Timer(_ -> notify(n.wake), _WATCH_INTERVAL; interval = _WATCH_INTERVAL)
    # One task takes the steps, of the timer and of the notifications, one after the other
    @async _watch_loop!(gui, n)
    return nothing
end

# The task of the watcher of the `gui` with the notifications `n`, see `_start_watching!`
function _watch_loop!(gui::LiveView, n::_FileNotes)
    s = gui.sync
    last_error = ""
    while true
        wait(n.wake)
        (s.closed || s.monitor !== n) && return nothing
        _shown(gui) || return _stop_watching!(gui)
        try
            _watch_step!(gui, n)
        catch e
            e isa InterruptException && rethrow()
            last_error = _log_once(e, last_error, "watching the project")
        end
    end
end

"""
    _watch_step!(gui, n; now = time())

One step of the watcher of the `gui` (see `_start_watching!`): takes the last look at the files
(`_take_look!`) if one is due, i.e. `n.poll` seconds after the last one started while the
notifications `n` run (else `_WATCH_INTERVAL`, see `_file_notes`), while the files change (until
they are merged), while the own presence file is due, or after a notification until a look that
started after it was taken (a look that is still running then wakes the watcher up when it is
done); calls `_check_files!` and `_check_presence!` with a new look, and `_autosave!` and
`_draw_presence!` every time. The notifications follow the project to another folder.
"""
function _watch_step!(gui::LiveView, n::_FileNotes; now::Real = time())
    s = gui.sync
    dir = gui.project
    isnothing(dir) || dir == n.dir || _renew_notes!(n, dir)
    poll = isempty(n.monitors) ? _WATCH_INTERVAL : n.poll
    noted = n.first
    take = noted > 0 || poll <= _WATCH_INTERVAL || !isnothing(s.changed_at) || s.presence_due ||
           now - s.look_at >= poll
    run, started = s.look, s.look_at
    # The files are read in the background; the window works with the last look
    look = take ? _take_look!(gui; now) : nothing
    isnothing(look) || _check_files!(gui; look)
    _autosave!(gui)
    isnothing(look) ? _draw_presence!(gui, time()) : _check_presence!(gui; look)
    noted > 0 || return nothing
    if !isnothing(run) && s.look !== run && started >= n.first
        # Answered, unless notifications came after that look started
        n.first = n.last > started ? n.last : 0.0
    end
    if n.first > 0 && !isnothing(s.look) && s.look.task !== n.waited
        task = n.waited = s.look.task
        @async begin
            try
                wait(task)
            catch
            end
            notify(n.wake)
        end
    end
    return nothing
end

"""
Stops the watcher of the `gui` (see `_start_watching!`) and its notifications when it is closed: if
it was watched, saves
what the person changed last, without waiting (`_autosave!` with `force`), and removes its session
and presence files (`_session_closed!`, `_presence_closed!`). A view that was not watched saves
nothing. No watcher starts again afterwards, also not by that save.
"""
function _stop_watching!(gui::LiveView)
    s = gui.sync
    s.closed = true
    t = s.timer
    s.timer = nothing
    n = s.monitor
    s.monitor = nothing
    n isa _FileNotes && _close_notes!(n)
    if !isnothing(t)
        close(t)
        try
            _autosave!(gui; force = true)
        catch e
            e isa InterruptException && rethrow()
            @error "saving the project at closing failed" exception = (e, catch_backtrace())
        end
        try
            # A look that still runs may write the presence file after it was removed
            isnothing(s.look) || wait(s.look.task)
        catch
        end
        s.look = nothing
        try
            _presence_closed!(gui)
        catch e
            e isa InterruptException && rethrow()
            @error "removing the presence file at closing failed" exception = (e, catch_backtrace())
        end
    end
    isempty(s.session) && return nothing
    try
        _session_closed!(gui)
    catch e
        e isa InterruptException && rethrow()
        @error "writing .bmo/session.md at closing failed" exception = (e, catch_backtrace())
    end
    return nothing
end

"""
    _check_files!(gui; now = time(), look = nothing) -> Symbol

One look of the watcher at the files of the project of the `gui`: `:pending` while they change or
have not stayed unchanged for `_SETTLE` seconds, but at most `_MERGE_EVERY` seconds since they
began to change (`first_change_at`), e.g. while several participants write one after the other;
then, once per state of the files, `:applied`, `:conflict` or `:failed`, see `_sync!`, which
solves once per merge (see `_adopting`); `:none` otherwise, also for the files that the `gui` saved
itself. The files changed if their times or sizes (`_file_marks`) or else the stamp of their
contents (`project_stamp`) changed, as read by the `look` (see `_files_look`; read here if
`nothing`; the watcher reads it in the background, see `_take_look!`, and a look without a stamp
compares the times and sizes only). A load error shown before is cleared when the files are back
to the state of the `gui`.
"""
function _check_files!(gui::LiveView; now::Real = time(), look = nothing)
    s = gui.sync
    dir = gui.project
    (isnothing(dir) || isnothing(s.base)) && return :none
    isnothing(look) && (look = _files_look(dir))
    marks = look.marks
    if marks != s.marks
        s.marks = marks
        _files_changed!(s, now)
        _merge_due(s, now) || return :pending
    elseif isnothing(s.changed_at)
        # A write of the same size within the resolution of the file times (e.g. right after a save
        # of the view) leaves the marks as they were: the stamp of the contents tells
        stamp = look.stamp
        (isnothing(stamp) || stamp == s.stamp || stamp == s.handled) && return :none
        _files_changed!(s, now)
        return :pending
    else
        _merge_due(s, now) || return :pending
    end
    s.changed_at = s.first_change_at = nothing
    disk = BMOP.project_stamp(dir)
    if disk == s.stamp
        # Saved by the view itself, or back to the state of the view
        if s.failed
            s.failed = false
            s.load_error = ""
            gui.status.text[] = "project files are as in the window"
            _note_session!(gui)
        end
        s.handled = nothing
        return :none
    end
    disk == s.handled && return :none
    s.handled = disk
    # One solve after the merge, also after the glides of the objects that it moved
    return _adopting(() -> _sync!(gui), gui)
end

# The files of `s` (a `_ProjectSync`) changed at `now`: since then, if they had settled
function _files_changed!(s::_ProjectSync, now::Real)
    (isnothing(s.changed_at) || isnothing(s.first_change_at)) && (s.first_change_at = Float64(now))
    s.changed_at = Float64(now)
    return nothing
end

# Whether the files of `s` that changed are merged at `now`: they settled, or changed for too long
function _merge_due(s::_ProjectSync, now::Real)
    now - s.changed_at >= _SETTLE && return true
    return !isnothing(s.first_change_at) && now - s.first_change_at >= _MERGE_EVERY
end
