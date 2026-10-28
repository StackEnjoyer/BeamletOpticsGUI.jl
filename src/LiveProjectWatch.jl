#=
The watcher of the files of a project of a shown window: it looks at the files in the background
(see `_take_look!`), merges a change of them once they settled (`_check_files!`, `_sync!`) and calls
the autosave and the presence; see `LiveProjectSync.jl`
=#

# How often the watcher looks at the times of the files [s]
const _WATCH_INTERVAL = 0.2
# How often a look reads the contents of the files for their stamp, while their times stay [s]
const _STAMP_EVERY = 2.0
# How long a look may wait in the background before the window reads the files itself [s]
const _LOOK_WAIT = 1.0
# How long the files must stay unchanged before they are loaded [s], an agent writes in steps
const _SETTLE = 0.3

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
Starts the watcher of the files of the project of the `gui` if it is shown, the file
`.bmo/session.md` (see `_connect_session!`) and the presence file of the window, written again when
the selection changes (see `LiveProjectPresence.jl`). Every `_WATCH_INTERVAL` seconds until the
window is closed, the watcher takes the last look at the files, read in the background (see
`_take_look!`), and calls `_check_files!` and `_check_presence!` with it once there is a new one,
and `_autosave!` and `_draw_presence!` every time. A view that is not shown (e.g. in the tests or
of a script) is not watched and writes neither; the functions can be called instead.
"""
function _start_watching!(gui::LiveView)
    s = gui.sync
    (isnothing(s.timer) && !s.closed && !isnothing(gui.project) && _shown(gui)) || return nothing
    _connect_session!(gui)
    # The presence file is written by the looks of the watcher, see `_presence_due!`
    s.presence_due = true
    push!(gui.controls.listeners, on(gui.controls.selected) do _
        gui.sync.presence_due = true
        return nothing
    end)
    last_error = Ref("")
    s.timer = Timer(_WATCH_INTERVAL; interval = _WATCH_INTERVAL) do _
        _shown(gui) || return _stop_watching!(gui)
        try
            # The files are read in the background; the window works with the last look
            look = _take_look!(gui)
            isnothing(look) || _check_files!(gui; look)
            _autosave!(gui)
            isnothing(look) ? _draw_presence!(gui, time()) : _check_presence!(gui; look)
        catch e
            e isa InterruptException && rethrow()
            last_error[] = _log_once(e, last_error[], "watching the project")
        end
    end
    return nothing
end

"""
Stops the watcher of the `gui` (see `_start_watching!`) when it is closed: if it was watched, saves
what the person changed last, without waiting (`_autosave!` with `force`), and removes its session
and presence files (`_session_closed!`, `_presence_closed!`). A view that was not watched saves
nothing. No watcher starts again afterwards, also not by that save.
"""
function _stop_watching!(gui::LiveView)
    s = gui.sync
    s.closed = true
    t = s.timer
    s.timer = nothing
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
have not stayed unchanged for `_SETTLE` seconds; then, once per state of the files, `:applied`,
`:conflict` or `:failed`, see `_sync!`; `:none` otherwise, also for the files that the `gui` saved
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
        s.changed_at = now
        return :pending
    end
    if isnothing(s.changed_at)
        # A write of the same size within the resolution of the file times (e.g. right after a save
        # of the view) leaves the marks as they were: the stamp of the contents tells
        stamp = look.stamp
        (isnothing(stamp) || stamp == s.stamp || stamp == s.handled) && return :none
        s.changed_at = now
        return :pending
    end
    now - s.changed_at < _SETTLE && return :pending
    s.changed_at = nothing
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
    return _sync!(gui)
end
