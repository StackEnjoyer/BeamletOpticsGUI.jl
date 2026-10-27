#=
Working on a project while an agent changes its files. A watcher looks at the times of the files
of the project of a shown view; when they changed and settled, the project is loaded and compared
with the state that the view and the files last agreed on (`base`) and with the setup in the view:
what only the files changed is applied in the open window (moved objects glide, new ones appear,
changed ones are rebuilt, removed ones go), what both changed differently is a conflict, shown on
a card. The window is never replaced.

The other way, the window saves every finished action of the person (autosave, `_autosave!`), so
that `system.jl` is always what the person sees, and lists them in `.bmo/session.md` for the agent
(see `LiveProjectSession.jl`).
=#

# How often the watcher looks at the times of the files [s]
const _WATCH_INTERVAL = 0.2
# How long the files must stay unchanged before they are loaded [s], an agent writes in steps
const _SETTLE = 0.3
# How long a moved object glides to its new pose [s], and the frames per second of that
const _GLIDE = 0.3
const _GLIDE_FPS = 60
# How long the boxes of the changed objects are shown [s]
const _FLASH = 1.0
# How long the setup in the window must stay unchanged before it is saved [s], and how long the
# autosave waits after a save that failed
const _AUTOSAVE_DELAY = 0.5
const _AUTOSAVE_RETRY = 5.0
# How many states of each entry that the window wrote are kept, see `_stale`
const _WRITTEN_MAX = 8

"""Whether the `gui` is shown in a window that is open."""
function _shown(gui::LiveView)
    screen = Makie.getscreen(gui.fig.scene)
    isnothing(screen) && return false
    return applicable(isopen, screen) ? isopen(screen) : true
end

"""
The times and sizes of the files of the project in `dir` that define the setup: `system.jl` and
the `.jl` files of `src/`. Cheap enough to be looked at often, see `_check_files!`.
"""
function _file_marks(dir::AbstractString)
    marks = Tuple{String, Float64, Int}[]
    file = joinpath(dir, "system.jl")
    isfile(file) && push!(marks, ("system.jl", mtime(file), filesize(file)))
    src = joinpath(dir, "src")
    if isdir(src)
        for (root, _, names) in walkdir(src), n in names
            endswith(n, ".jl") || continue
            path = joinpath(root, n)
            push!(marks, (relpath(path, dir), mtime(path), filesize(path)))
        end
    end
    return sort!(marks)
end

_src_marks(marks) = filter(m -> m[1] != "system.jl", marks)

"""
    _saved!(gui, project; written = true)

Records that the `gui` and the files of the `project` agree, after it was opened, saved or the
files were merged: `project` becomes the `base` of the comparisons (see `_ProjectSync`), a conflict
is over, the states that the window wrote are remembered (unless `written` is `false`, e.g. for
files that `Ctrl+R` took in; see `_stale`), `.bmo/session.md` is written if the view writes it,
and the watcher starts if the `gui` is shown.
"""
function _saved!(gui::LiveView, project; written::Bool = true)
    s = gui.sync
    before = s.base
    s.base = _align_uids!(gui, project)
    s.stamp = project.stamp
    s.marks = _file_marks(project.path)
    s.src = _src_marks(s.marks)
    s.changed_at = s.handled = nothing
    s.failed = false
    s.load_error = ""
    if !isempty(s.conflicts)
        empty!(s.conflicts)
        _release_info!(gui, _ProjectConflict)
    end
    written && _remember_written!(s, before)
    _note_session!(gui)
    _start_watching!(gui)
    return nothing
end

# Writes `.bmo/session.md` of the `gui` if it is connected (a shown window), see `_connect_session!`
_note_session!(gui::LiveView) = (isempty(gui.sync.session) || _write_session!(gui); nothing)

_same_written(a, b) = (isnothing(a) || isnothing(b)) ? a === b : BMOP.same_entry(a, b)

function _push_written!(w::Vector{Any}, x)
    (isempty(w) || !_same_written(last(w), x)) && push!(w, x)
    length(w) > _WRITTEN_MAX && popfirst!(w)
    return nothing
end

"""
Adds the states of the entries that the window wrote by a save from the state `before` (the `base`
before the save, `nothing` when it was opened: then every entry) to `written` of `s`: each one that
the save changed, after the state it overwrote (e.g. merged from an agent), and `nothing` after the
last state of an entry that the save removed.
"""
function _remember_written!(s::_ProjectSync, before)
    for e in s.base.entries
        isnothing(e.uid) && continue
        old = isnothing(before) ? nothing : _by_key(before.entries, e.uid)
        !isnothing(old) && BMOP.same_entry(old, e) && continue
        w = get!(() -> Any[], s.written, e.uid)
        isnothing(old) || _push_written!(w, old)
        _push_written!(w, e)
    end
    isnothing(before) && return nothing
    for old in before.entries
        (isnothing(old.uid) || !isnothing(_by_key(s.base.entries, old.uid))) && continue
        w = get!(() -> Any[], s.written, old.uid)
        _push_written!(w, old)
        _push_written!(w, nothing)
    end
    return nothing
end

"""
Starts the watcher of the files of the project of the `gui` if it is shown, which calls
`_check_files!` and `_autosave!` every `_WATCH_INTERVAL` seconds until the window is closed, and
the file `.bmo/session.md` (see `_connect_session!`). A view that is not shown (e.g. in the tests
or of a script) is not watched and writes no `session.md`; the functions can be called instead.
"""
function _start_watching!(gui::LiveView)
    s = gui.sync
    (isnothing(s.timer) && !s.closed && !isnothing(gui.project) && _shown(gui)) || return nothing
    _connect_session!(gui)
    last_error = Ref("")
    s.timer = Timer(_WATCH_INTERVAL; interval = _WATCH_INTERVAL) do _
        _shown(gui) || return _stop_watching!(gui)
        try
            _check_files!(gui)
            _autosave!(gui)
        catch e
            e isa InterruptException && rethrow()
            last_error[] = _log_once(e, last_error[], "watching the project")
        end
    end
    return nothing
end

"""
Stops the watcher of the `gui` (see `_start_watching!`) when it is closed: if it was watched, saves
what the person changed last, without waiting (`_autosave!` with `force`), and notes in
`.bmo/session.md` that no window is open. A view that was not watched saves nothing. No watcher
starts again afterwards, also not by that save.
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

#=
Autosave
=#

# The text of `system.jl` of the project `p` without the machine ids: the view gives one to a new
# object only when it saves, a new one at every look before
_uidless_code(p) = replace(BMOP.system_code(p), r" uid = \"[^\"]*\"" => "")

"""
    _autosave!(gui; now = time(), force = false) -> Symbol

One look of the autosave at the setup of the `gui`, after `_check_files!`: once the setup differs
from the files (`base`) and has not changed for `_AUTOSAVE_DELAY` seconds, it is saved (`:saved`)
and the changes of the person are added to the journal of `.bmo/session.md` (`_journal!`); files
changed meanwhile are merged first. `:pending` while it waits, `:none` if the setup is as in the
files. `:paused` while the mouse drags or places an object (also in a linked view, see
`open_system`), an object glides to a pose of the files, the files changed and are not merged yet,
or a conflict is open: a change of the person then shows its card again if it was closed without
a decision. While the files do not load (e.g. an agent is half through an edit) or a conflict is
open, the setup is written to `.bmo/window-backup.jl` instead (`:paused`) and saved once they load
again. `:failed` if the save failed, the reason in the status line; tried again after
`_AUTOSAVE_RETRY` seconds. `force` saves without waiting and while the files changed or objects
glide (when the window closes or `Ctrl+S` saves a version); a conflict then writes the backup.
"""
function _autosave!(gui::LiveView; now::Real = time(), force::Bool = false)
    s = gui.sync
    dir = gui.project
    (isnothing(dir) || isnothing(s.base)) && return :none
    if force
        _finish_glides!(gui)
    else
        (_busy(gui) || !isnothing(s.changed_at) || !isempty(s.gliding)) && return :paused
    end
    parts = _project_parts(gui, dir)
    text = _uidless_code(parts.project)
    if text == _uidless_code(s.base)
        s.text, s.edited_at = text, nothing
        return :none
    end
    if text != s.text
        s.text, s.edited_at = text, now
        # A change of the person while a conflict is open whose card was closed: ask again
        !force && !isempty(s.conflicts) && !_conflict_shown(gui) && _show_conflict!(gui, s.conflicts)
        force || return :pending
    end
    !force && !isempty(s.conflicts) && return :paused
    # Written to the backup already, the files still do not load
    isnothing(s.edited_at) && s.failed && !force && return :paused
    !force && !isnothing(s.edited_at) && now - s.edited_at < _AUTOSAVE_DELAY && return :pending
    s.edited_at = nothing
    if s.failed || !isempty(s.conflicts)
        _write_backup!(gui, parts.project)
        return :paused
    end
    return _autosave_write!(gui, parts, now)
end

"""Whether the mouse drags or places an object in the `gui` or in a view linked to it."""
_busy(gui::LiveView) = any(v -> v.controls.dragging || _placing(v), Any[gui, gui.links.views...])

"""Whether the card of the conflict of the `gui` is shown, see `_ProjectConflict`."""
function _conflict_shown(gui::LiveView)
    c = _info_card(gui)
    return !isnothing(c) && c.obj isa _ProjectConflict
end

"""
Saves the setup (`parts`, see `_project_parts`) of the `gui` for `_autosave!`. Files that changed
since the last look are merged first, without gliding, such that the save sees the poses of the
files; a conflict or files that do not load then write the backup. A new list of objects without a
recipe stays in the status line and is warned once; otherwise the status line stays as it was.
"""
function _autosave_write!(gui::LiveView, parts, now::Real)
    s = gui.sync
    dir = gui.project
    if BMOP.project_stamp(dir) != s.stamp
        s.changed_at = nothing
        if _sync!(gui; animate = false) !== :applied || !isempty(s.conflicts)
            _write_backup!(gui, _collect_project(gui, dir))
            return :paused
        end
        parts = _project_parts(gui, dir)
        _uidless_code(parts.project) == _uidless_code(s.base) && return :none
    end
    changes = BMOP.diff_projects(s.base, parts.project)
    status = gui.status.text[]
    saved = Base.CoreLogging.with_logger(Base.CoreLogging.SimpleLogger(stderr, Base.CoreLogging.Error)) do
        _save_to!(gui, dir)
    end
    if !saved
        # A conflict, files that do not load (both found by a merge of the save), or an error in
        # the status line
        if !isempty(s.conflicts) || s.failed
            _write_backup!(gui, _collect_project(gui, dir))
            return :paused
        end
        s.edited_at = now + _AUTOSAVE_RETRY
        return :failed
    end
    _journal!(gui, changes)
    if !isempty(parts.skipped) && parts.skipped != s.skipped
        @warn "save_project: $(length(parts.skipped)) objects without a recipe are not saved: " *
              join(parts.skipped, ", ")
    elseif startswith(gui.status.text[], "project saved to")
        gui.status.text[] = status
    end
    s.skipped = parts.skipped
    return :saved
end

"""Writes the setup `mine` of the `gui` to `.bmo/window-backup.jl`, while the files do not load."""
function _write_backup!(gui::LiveView, mine)
    file = joinpath(gui.project, ".bmo", "window-backup.jl")
    mkpath(dirname(file))
    write(file, BMOP.system_code(mine))
    note = "the window is kept in .bmo/window-backup.jl"
    st = gui.status.text[]
    occursin(note, st) || (gui.status.text[] = isempty(st) ? note : "$st; $note")
    _note_session!(gui)
    return file
end

"""
    _check_files!(gui; now = time()) -> Symbol

One look of the watcher at the files of the project of the `gui`: `:pending` while they change or
have not stayed unchanged for `_SETTLE` seconds; then, once per state of the files, `:applied`,
`:conflict` or `:failed`, see `_sync!`; `:none` otherwise, also for the files that the `gui` saved
itself. The files changed if their times or sizes (`_file_marks`) or else the stamp of their
contents (`project_stamp`) changed. A load error shown before is cleared when the files are back to
the state of the `gui`.
"""
function _check_files!(gui::LiveView; now::Real = time())
    s = gui.sync
    dir = gui.project
    (isnothing(dir) || isnothing(s.base)) && return :none
    marks = _file_marks(dir)
    if marks != s.marks
        s.marks = marks
        s.changed_at = now
        return :pending
    end
    if isnothing(s.changed_at)
        # A write of the same size within the resolution of the file times (e.g. right after a save
        # of the view) leaves the marks as they were: the stamp of the contents tells
        stamp = BMOP.project_stamp(dir)
        (stamp == s.stamp || stamp == s.handled) && return :none
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

#=
Comparing and applying
=#

# The key of an entry or system: its machine id, or its readable id for a line without one
_key(x) = isnothing(x.uid) ? "id:" * String(x.name) : x.uid
_change_key(c) = _key(something(c.old, c.new))

"""The entry (or system) of the `key` in `xs`, by machine id or by readable id (`\"id:L1\"`)."""
function _by_key(xs, key::String)
    if startswith(key, "id:")
        name = Symbol(key[4:end])
        i = findfirst(x -> x.name === name, xs)
    else
        i = findfirst(x -> x.uid == key, xs)
    end
    return isnothing(i) ? nothing : xs[i]
end

"""
The message of an error of loading a project for the status line: file, line, column and reason,
e.g. `system.jl:22:34: Expected ')' or ','`.
"""
function _load_message(e)
    e isa LoadError || return _message_line(e)
    inner = e.error
    text = sprint(showerror, inner)
    if inner isa Base.Meta.ParseError
        at = match(r"@ .*?([^\\/]+\.jl):(\d+):(\d+)", text)
        reason = match(r"└[─┘ ]*── (.*)$"m, text)
        file = isnothing(at) ? basename(e.file) : at.captures[1]
        pos = isnothing(at) ? string(e.line) : string(at.captures[2], ":", at.captures[3])
        return string(file, ":", pos, ": ", isnothing(reason) ? "syntax error" : strip(reason.captures[1]))
    end
    msg = first(split(text, '\n'))
    # The macros of BeamletOpticsProjects name the line themselves
    occursin(r"\.jl:\d+", msg) && return msg
    return "$(basename(e.file)):$(e.line): $msg"
end

"""
The readable ids of the entries of the project `p` whose code calls a function or type that the own
code of the project (`src/<name>.jl`) exports; they are built again when that code changed.
"""
function _calls_own_code(p)
    isnothing(p.mod) && return Symbol[]
    own = Symbol(p.name)
    Base.invokelatest(isdefined, p.mod, own) || return Symbol[]
    m = Base.invokelatest(getfield, p.mod, own)
    m isa Module || return Symbol[]
    exported = Set{Symbol}(Base.invokelatest(names, m))
    return Symbol[e.name for e in p.entries if _uses(e.code, exported)]
end
_uses(x::Symbol, names) = x in names
_uses(x::Expr, names) = any(a -> _uses(a, names), x.args)
_uses(x, names) = false

"""Whether the state of the `key` is the same in the projects `a` and `b`."""
function _same_state(a, b, key::String)
    ea, eb = _by_key(a.entries, key), _by_key(b.entries, key)
    if !(isnothing(ea) && isnothing(eb))
        (isnothing(ea) || isnothing(eb)) && return false
        return BMOP.same_entry(ea, eb)
    end
    sa, sb = _by_key(a.systems, key), _by_key(b.systems, key)
    (isnothing(sa) && isnothing(sb)) && return true
    (isnothing(sa) || isnothing(sb)) && return false
    return BMOP.same_system(sa, a, sb, b)
end

"""
    _stale(s, key, disk) -> Bool

Whether the files `disk` bring the entry of the machine id `key` back to an older state of the
window (see `written` of `_ProjectSync`), while the last state that the window and the files
agreed on is one the window wrote: most likely an agent that writes from an older read, over a
change of the person. Also an entry that the window removed last and that comes back as it was.
Not a change of an agent that sets back its own change (the window did not write the state it
sets back from), and not an entry that the agent removed and brings back. Entries without a
machine id are not checked.
"""
function _stale(s::_ProjectSync, key::String, disk)
    startswith(key, "id:") && return false
    w = get(s.written, key, nothing)
    (isnothing(w) || length(w) < 2) && return false
    de, be = _by_key(disk.entries, key), _by_key(s.base.entries, key)
    isnothing(de) && return false
    older(x) = !isnothing(x) && BMOP.same_entry(x, de)
    isnothing(be) && return isnothing(last(w)) && any(older, w)
    _same_written(be, last(w)) || return false
    return !BMOP.same_entry(de, be) && any(older, @view w[1:(end - 1)])
end

"""
    _sync!(gui; animate = _shown(gui)) -> Symbol

Loads the project of the `gui` from its files and merges it into the open window, see
`LiveProjectSync.jl`: the changes of the files since `base` that the window did not change too are
applied (`_adopt!`, moved objects glide if `animate`), conflicting ones are left and shown on a
card (`_ProjectConflict`), also changes back to an older state of the window (see `_stale`) and
the conflicts still open from before, unless the files now agree with the window there. The files
become the new `base`. Returns `:applied`, `:conflict` or `:failed` (the reason in the status line
and in `load_error`, the window as it was).
"""
function _sync!(gui::LiveView; animate::Bool = _shown(gui))
    s = gui.sync
    dir = gui.project
    disk = try
        BMOP.load_project(dir)
    catch e
        e isa InterruptException && rethrow()
        s.failed = true
        s.load_error = _load_message(e)
        gui.status.text[] = "project not reloaded: $(s.load_error)"
        _note_session!(gui)
        return :failed
    end
    s.failed = false
    s.load_error = ""
    # The window compares in the poses of the files of the last merge
    _finish_glides!(gui)
    # The lines without uid (of an agent) get those of their objects in the window
    _align_uids!(gui, disk)
    rebuild = _src_marks(s.marks) == s.src ? Symbol[] : _calls_own_code(disk)
    d = BMOP.diff_projects(s.base, disk; rebuild)
    mine = _collect_project(gui, dir)
    g = BMOP.diff_projects(s.base, mine)
    theirs = Set{String}(_change_key(c) for c in Iterators.flatten((d.entries, d.systems)))
    ours = Set{String}(_change_key(c) for c in Iterators.flatten((g.entries, g.systems)))
    conflicts = String[k for k in theirs
                       if k in ours ? !_same_state(mine, disk, k) : _stale(s, k, disk)]
    # A conflict of before stays until the person decides, or the files agree with the window
    still = String[k for k in s.conflicts if !(k in conflicts) && !_same_state(mine, disk, k)]
    conflicts = vcat(still, conflicts)
    done = _adopt!(gui, mine, disk, setdiff(theirs, conflicts); rebuild = Set(rebuild), animate)
    s.base = _align_uids!(gui, disk)
    s.stamp = disk.stamp
    s.src = _src_marks(s.marks)
    s.conflicts = conflicts
    s.theirs = disk
    if isempty(conflicts)
        _release_info!(gui, _ProjectConflict)
        isempty(done) || (gui.status.text[] = "agent: " * join(done, ", "))
        _note_session!(gui)
        return :applied
    end
    _show_conflict!(gui, conflicts)
    _note_session!(gui)
    return :conflict
end

"""
Gives the entries and systems of the `project` without a machine id (lines of an agent) the one
that the `gui` gave their objects (see `ids`), such that the project and the window compare equal.
"""
function _align_uids!(gui::LiveView, project)
    for (i, e) in enumerate(project.entries)
        isnothing(e.uid) || continue
        obj = _window_object(gui, e)
        isnothing(obj) && continue
        project.entries[i] = BMOP.Entry(e.kind, e.name, e.code, e.object, e.pos, e.rot, e.pose0,
            e.meta, e.label, gui.sync.ids[obj][2])
    end
    for (i, se) in enumerate(project.systems)
        isnothing(se.uid) || continue
        sys = _window_object(gui, se)
        isnothing(sys) && continue
        project.systems[i] = BMOP.SystemEntry(se.name, se.members, se.sources, se.static, se.object,
            se.label, gui.sync.ids[sys][2])
    end
    return project
end

"""The object, source or system of the `gui` of the project entry (or system) `x`."""
function _window_object(gui::LiveView, x)
    for (obj, (name, uid)) in gui.sync.ids
        (isnothing(x.uid) ? name === x.name : uid == x.uid) && return obj
    end
    return nothing
end

# The label that the view shows for an entry: its label, else its readable id
_shown_label(x) = something(x.label, String(x.name))

"""Changes the record of the project in the `origin` of `obj` (see `_project_origin`)."""
function _update_record!(gui::LiveView, @nospecialize(obj); kwargs...)
    origin = get(gui.components.origin, obj, nothing)
    rec = isnothing(origin) ? nothing : get(origin, :project, nothing)
    isnothing(rec) && return nothing
    gui.components.origin[obj] = merge(origin, (; project = merge(rec, (; kwargs...))))
    return nothing
end

# The handle of a system has the name of the system, see `_rename_system!`
function _name_handle!(gui::LiveView, sys::BMO.AbstractSystem, name::String)
    h = _system_handle(gui, sys)
    isnothing(h) || (gui.objects.names[h] = name)
    return nothing
end
_name_handle!(::LiveView, @nospecialize(x), ::String) = nothing

"""Sets the label of `x` (an object, source or system of the `gui`) and its id in `ids`."""
function _name!(gui::LiveView, @nospecialize(x), e)
    uid = something(e.uid, get(gui.sync.ids, x, (e.name, BMOP.new_uid()))[2])
    gui.sync.ids[x] = (e.name, uid)
    label = _shown_label(e)
    if get(gui.labels, x, nothing) != label
        gui.labels[x] = gui.objects.names[x] = label
        _name_handle!(gui, x, label)
    end
    return nothing
end

"""Adds the object or source of the entry `e` of the files to the `gui`, without a system yet."""
function _add_entry!(gui::LiveView, e)
    obj = e.object
    origin = _project_origin(gui, e)
    _unrecorded(gui) do
        add_component!(gui, obj; system = :none, select = false, label = _shown_label(e), origin)
    end
    _name!(gui, obj, e)
    return obj
end

"""Removes the object or source `obj` of the project from the `gui`, and its undo history."""
function _remove_entry!(gui::LiveView, @nospecialize(obj))
    _unrecorded(() -> remove_component!(gui, obj), gui)
    _drop_history!(gui.controls, Any[obj])
    delete!(gui.sync.ids, obj)
    return nothing
end

"""
Puts the object of the entry `e` of the files in the place of `old` in the `gui` (other code, or
own code that changed): in the same systems, with the pose of the files; selected if `old` was.
"""
function _swap!(gui::LiveView, @nospecialize(old), e)
    new = e.object
    origin = _project_origin(gui, e)
    selected = gui.controls.selected[] === old
    snap = _replacement_snapshot(gui, old, new, origin, _snapshot(gui, old))
    _remove_unrecorded!(gui, old)
    _restore!(gui, new, snap)
    _drop_history!(gui.controls, Any[old])
    delete!(gui.sync.ids, old)
    _name!(gui, new, e)
    selected && select!(gui, new)
    return new
end

"""The rotation by `angle` about the unit vector `axis`."""
function _axis_rotation(axis, angle)
    K = [0.0 -axis[3] axis[2]; axis[3] 0.0 -axis[1]; -axis[2] axis[1] 0.0]
    return Matrix{Float64}(I, 3, 3) + sin(angle) * K + (1 - cos(angle)) * K * K
end

"""
Moves `obj` of the `gui`, which is in `gliding` of its `_ProjectSync`, to the pose `(P, R)` of its
entry there: gliding over `_GLIDE` seconds if `animate`, the position along the line, the
orientation about the axis of the rotation between the two; then lands it (`_land!`). Stops if it
was landed meanwhile, see `_finish_glides!`.
"""
function _glide!(gui::LiveView, @nospecialize(obj); animate::Bool)
    gliding = gui.sync.gliding
    haskey(gliding, obj) || return nothing
    P1, R1, _ = gliding[obj]
    ctrl = gui.controls
    set!(P, R) = (_change!(() -> _set_pose!(obj, P, R), ctrl, obj); _apply_update!(ctrl, obj))
    if animate
        P0, R0 = _pose(obj)
        axis, angle = _rotation_axis_angle(Matrix{Float64}(R1) * Matrix{Float64}(R0)')
        n = max(1, round(Int, _GLIDE * _GLIDE_FPS))
        for i in 1:(n - 1)
            haskey(gliding, obj) || return nothing
            f = i / n
            f = f * f * (3 - 2f)
            R = angle > 0 ? _axis_rotation(axis, f * angle) * R0 : R0
            set!(Point3{Float64}(P0 .+ f .* (Vector{Float64}(P1) .- P0)), R)
            sleep(1 / _GLIDE_FPS)
        end
    end
    _land!(gui, obj)
    return nothing
end

"""
Puts `obj` of `gliding` of the `gui` exactly into the pose of its entry of the files and records
that pose, see `_glide!`.
"""
function _land!(gui::LiveView, @nospecialize(obj))
    haskey(gui.sync.gliding, obj) || return nothing
    P, R, e = pop!(gui.sync.gliding, obj)
    ctrl = gui.controls
    _change!(() -> _place_exactly!(obj, P, R), ctrl, obj)
    _apply_update!(ctrl, obj)
    _update_record!(gui, obj; pos = e.pos, rot = e.rot, pose = _pose(obj))
    return nothing
end

"""
Lands every object of the `gui` that glides to a pose of the files at once, e.g. before a save,
which must see the poses of the files; their glides stop.
"""
_finish_glides!(gui::LiveView) = foreach(obj -> _land!(gui, obj), collect(keys(gui.sync.gliding)))

"""
Sets the pose of `obj` to `(P, R)` with the position exactly `P`: rotates about its position, then
moves it to the origin, which is exact, and from there by `P`, like `BeamletOpticsProjects`
poses the objects of a project.
"""
function _place_exactly!(@nospecialize(obj), P, R)
    axis, angle = _rotation_axis_angle(Matrix{Float64}(R) * _pose(obj)[2]')
    angle > 0 && rotate3d!(obj, axis, angle)
    reset_translation3d!(obj)
    translate3d!(obj, Vector{Float64}(P))
    return nothing
end

"""Shows a box around each of the `objs` of the `gui` for `_FLASH` seconds."""
function _flash!(gui::LiveView, objs)
    color = _part_box_color(gui)
    boxes = AbstractPlot[]
    for obj in objs
        bb = _part_box(gui, obj)
        isnothing(bb) && continue
        push!(boxes, linesegments!(gui.ax, _bbox_wireframe(bb); color, linewidth = 2,
            clip_planes = Plane3f[], inspectable = false))
    end
    isempty(boxes) || Timer(_ -> foreach(b -> delete!(gui.ax, b), boxes), _FLASH)
    return boxes
end

"""
Makes the systems of the `gui` that are in `keys` (or that the entries `changed` are members of)
have the members and sources of the files `disk`.
"""
function _sync_members!(gui::LiveView, disk, keys, changed)
    for se in disk.systems
        member = any(n -> n in changed, se.members) || any(n -> n in changed, se.sources)
        (_key(se) in keys || member) || continue
        sys = _window_object(gui, se)
        sys isa BMO.System || continue
        objs(names) = Any[o for n in names
                          for o in (_window_object(gui, _by_key(disk.entries, "id:" * String(n))),)
                          if !isnothing(o)]
        want, sources = objs(se.members), objs(se.sources)
        _unrecorded(gui) do
            for o in want
                _has(sys.objects, o) || _add_member!(gui, o, sys)
            end
            for o in copy(sys.objects)
                haskey(gui.sync.ids, o) && !_has(want, o) && _remove_member!(gui, o, sys)
            end
            for src in _sources_of(gui, sys)
                haskey(gui.sync.ids, src) && !_has(sources, src) && _set_source_system!(gui, src, nothing)
            end
            for src in sources
                _has(_sources_of(gui, sys), src) || _set_source_system!(gui, src, sys)
            end
        end
    end
    return nothing
end

"""
    _adopt!(gui, mine, disk, keys; rebuild = Set{Symbol}(), animate = _shown(gui)) -> Vector{String}

Makes the entries and systems of the `keys` in the open `gui` (whose state is the project `mine`,
see `_collect_project`) as in the files `disk`, without undo entries: removes, adds, rebuilds (other
code, or calling own code in `rebuild`), moves (gliding if `animate`, see `_glide!`), renames and
relabels. The changed objects get a box for a moment. Returns what was done, e.g. `"moved M1"`.
"""
function _adopt!(gui::LiveView, mine, disk, keys; rebuild = Set{Symbol}(), animate::Bool = _shown(gui))
    done = String[]
    touched = Any[]
    glides = Tuple{Any, Any, Any}[]
    changed = Set{Symbol}()
    m = BMOP.match_entries(disk.entries, mine.entries)
    # In the window only: removed in the files
    for e in m.added
        _key(e) in keys || continue
        _remove_entry!(gui, e.object)
        push!(done, "removed $(_shown_label(e))")
    end
    ms = BMOP.match_entries(disk.systems, mine.systems)
    for se in ms.removed
        _key(se) in keys || continue
        sys = _unrecorded(() -> add_system!(gui; label = _shown_label(se), select = false), gui)
        _name!(gui, sys, se)
        push!(done, "added $(_shown_label(se))")
    end
    # In the files only: added
    for e in m.removed
        _key(e) in keys || continue
        push!(touched, _add_entry!(gui, e))
        push!(changed, e.name)
        push!(done, "added $(_shown_label(e))")
    end
    for (e, mine_e) in m.pairs
        _key(e) in keys || continue
        obj = mine_e.object
        if e.kind != mine_e.kind || e.name in rebuild ||
           BMOP.normalize_code(e.code) != BMOP.normalize_code(mine_e.code)
            push!(touched, _swap!(gui, obj, e))
            push!(changed, e.name)
            push!(done, "rebuilt $(_shown_label(e))")
            continue
        end
        if !BMOP.same_entry(BMOP.Entry(e.kind, e.name, e.code, nothing; e.pos, e.rot, e.pose0),
                            BMOP.Entry(e.kind, e.name, e.code, nothing; mine_e.pos, mine_e.rot, e.pose0))
            push!(glides, (obj, _pose(e.object), e))
            push!(done, "moved $(_shown_label(e))")
        end
        if e.name !== mine_e.name || e.label != mine_e.label
            _name!(gui, obj, e)
            e.name === mine_e.name || push!(changed, e.name)
            push!(done, "renamed $(_shown_label(e))")
        end
        isequal(Dict(e.meta), Dict(mine_e.meta)) || _update_record!(gui, obj; meta = Pair{Symbol, Any}[e.meta...])
    end
    _sync_members!(gui, disk, keys, changed)
    for se in ms.added
        _key(se) in keys || continue
        try
            _unrecorded(() -> remove_system!(gui, se.object), gui)
            delete!(gui.sync.ids, se.object)
            push!(done, "removed $(_shown_label(se))")
        catch e
            e isa ArgumentError || rethrow()
        end
    end
    for (se, mine_se) in ms.pairs
        _key(se) in keys || continue
        (se.name !== mine_se.name || se.label != mine_se.label) && _name!(gui, mine_se.object, se)
    end
    isempty(glides) && (_flash!(gui, touched); return done)
    # The autosave waits until they landed, a save lands them at once
    foreach(((obj, (P, R), e),) -> (gui.sync.gliding[obj] = (P, R, e)), glides)
    finish() = begin
        foreach(g -> _glide!(gui, first(g); animate), glides)
        _flash!(gui, Any[touched..., first.(glides)...])
        return nothing
    end
    animate ? (@async finish()) : finish()
    return done
end

#=
Loading from disk, the conflict and its card
=#

"""
`Ctrl+R` of the `gui`: makes the window as in the files of its project, in place: everything that
differs is taken from the files, the changes in the window that were not saved are lost.
"""
function _reload_key!(gui::LiveView)
    if isnothing(gui.project)
        gui.status.text[] = "no project to reload: open or save one first"
        return nothing
    end
    _load_from_disk!(gui)
    return nothing
end

"""Takes all of the files of the project into the open `gui`, see `_reload_key!`."""
function _load_from_disk!(gui::LiveView)
    disk = try
        BMOP.load_project(gui.project)
    catch e
        e isa InterruptException && rethrow()
        gui.sync.failed = true
        gui.sync.load_error = _load_message(e)
        gui.status.text[] = "project not reloaded: $(gui.sync.load_error)"
        _note_session!(gui)
        return nothing
    end
    _finish_glides!(gui)
    _align_uids!(gui, disk)
    mine = _collect_project(gui, gui.project)
    keys = Set{String}(_key(x) for x in Iterators.flatten((disk.entries, disk.systems, mine.entries,
        mine.systems)))
    _release_info!(gui, _ProjectConflict)
    done = _adopt!(gui, mine, disk, keys; rebuild = Set(_calls_own_code(disk)))
    # Taken in from the files, not written by the window
    _saved!(gui, disk; written = false)
    gui.status.text[] = isempty(done) ? "project reloaded, nothing changed" : "reloaded: " * join(done, ", ")
    return nothing
end

"""
    _ProjectConflict

Objects that were changed both in the window and in the files of its project (e.g. by an agent),
differently: an info card at `point` naming them (`names`), with three buttons, see
`_resolve_conflict!`. All other changes of the files are already applied, see `_sync!`.
"""
struct _ProjectConflict <: _InfoItem
    point::Point3f
    names::Vector{String}
end

_points(x::_ProjectConflict) = [x.point]
_title(::_ProjectConflict) = "Changed here and in the files"
_tree_kind(::_ProjectConflict) = :warning
_keep_plots!(::LiveView, ::_ProjectConflict) = nothing
_keepable(::_ProjectConflict) = false
card_rows(x::_ProjectConflict) = (
    _text_row("objects", :conflict_names, (_, _) -> join(x.names, ", "); width = 48),
    _text_row("files", :conflict_files, (_, _) -> "the rest of the files is applied"; width = 48),
    CardRow(
        CardWidget(Button; name = :conflict_theirs, label = "Take theirs",
            on = (gui, _, _) -> _resolve_conflict!(gui, :theirs)),
        CardWidget(Button; name = :conflict_mine, label = "Keep mine",
            on = (gui, _, _) -> _resolve_conflict!(gui, :mine)),
        CardWidget(Button; name = :conflict_save_as, label = "Save as…",
            on = (gui, _, _) -> _resolve_conflict!(gui, :save_as))))

"""Shows the card of the conflict of the `gui` for the entries and systems of the `keys`."""
function _show_conflict!(gui::LiveView, keys::Vector{String})
    names = String[]
    for k in keys
        x = something(_by_key(gui.sync.theirs.entries, k), _by_key(gui.sync.theirs.systems, k),
            Some(nothing))
        if isnothing(x)
            obj = findfirst(t -> t[2] == k, gui.sync.ids)
            push!(names, isnothing(obj) ? k : _label(gui, obj))
        else
            push!(names, _shown_label(x))
        end
    end
    _show_info!(gui, _ProjectConflict(_error_anchor(gui), names))
    gui.status.text[] = "changed here and in the files: $(join(names, ", ")); choose on the card"
    return nothing
end

"""
Resolves the conflict of the `gui` (see `_ProjectConflict`) as the user chose, `how`: `:theirs`
takes the objects of the conflict from the files (their changes here are lost), `:mine` keeps them
as they are here, which the autosave writes, `:save_as` saves the window as a new project (see
`_save_as_key!`): the conflict is over once that is saved (`_saved!`); if the dialog is cancelled,
it stays open, and the autosave of the project keeps waiting for a decision.
"""
function _resolve_conflict!(gui::LiveView, how::Symbol)
    s = gui.sync
    _release_info!(gui, _ProjectConflict)
    if how === :save_as
        _save_as_key!(gui)
        return nothing
    end
    if how === :theirs && !isnothing(s.theirs)
        mine = _collect_project(gui, gui.project)
        done = _adopt!(gui, mine, s.theirs, Set(s.conflicts))
        gui.status.text[] = "taken from the files: " * join(done, ", ")
    elseif how === :mine
        gui.status.text[] = "kept as here; written to the files"
    end
    empty!(s.conflicts)
    _note_session!(gui)
    return nothing
end

#=
Windows
=#

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
