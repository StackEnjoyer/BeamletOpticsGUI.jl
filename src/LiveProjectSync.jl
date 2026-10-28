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

# How long the boxes of the changed objects are shown [s]
const _FLASH = 1.0
# How long the setup in the window must stay unchanged before it is saved [s], and how long the
# autosave waits after a save that failed
const _AUTOSAVE_DELAY = 0.5
const _AUTOSAVE_RETRY = 5.0
# How long a change of the person waits at most for the merge of files that keep changing [s], see
# `_autosave!`: as long as the watcher waits at most before it merges them (`_MERGE_EVERY`)
const _AUTOSAVE_WAIT = 2.0
# How many states of each entry that the window wrote are kept, see `_stale`
const _WRITTEN_MAX = 8

"""Whether the `gui` is shown in a window that is open."""
function _shown(gui::LiveView)
    screen = Makie.getscreen(gui.fig.scene)
    isnothing(screen) && return false
    return applicable(isopen, screen) ? isopen(screen) : true
end

"""
    _saved!(gui, project; written = true, keep = String[])

Records that the `gui` and the files of the `project` agree, after it was opened, saved or the
files were merged: `project` becomes the `base` of the comparisons (see `_ProjectSync`), the
conflicts are over except those of `keep` (a save of the window writes the files' state of the
objects in conflict and keeps them open, see `_saved_state`), the states that the window wrote are
remembered (unless `written` is `false`, e.g. for files that `Ctrl+R` took in; see `_stale`),
`.bmo/session.md` is written if the view writes it, the watcher starts if the `gui` is shown, and a
watched view publishes the stamp of the files in its presence file (the others name it as the
writer, see `_writer`).
"""
function _saved!(gui::LiveView, project; written::Bool = true, keep = String[])
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
        filter!(in(keep), s.conflicts)
        isempty(s.conflicts) && _release_info!(gui, _ProjectConflict)
    end
    written && _remember_written!(s, before)
    # A look of the watcher that started before this read the files before it, see `_take_look!`
    s.gen += 1
    _note_session!(gui)
    _start_watching!(gui)
    # written by the next look of the watcher
    isnothing(s.timer) || (s.presence_due = true)
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

#=
Autosave
=#

# The text of `system.jl` of the project `p` without the machine ids: the view gives one to a new
# object only when it saves, a new one at every look before
_uidless_code(p) = replace(BMOP.system_code(p), r" uid = \"[^\"]*\"" => "")

"""
    _claimed_lines(gui) -> Vector{String}

The keys (see `_key`) of the lines of the files (`base`) that another participant claims, by the
claims of the others at the last read of the `gui` (see `_ClaimState`, no file access): a save of
the `gui` keeps their state of the files, see `_composed`.
"""
function _claimed_lines(gui::LiveView)
    c = gui.sync.claim
    base = gui.sync.base
    out = String[]
    (c isa _ClaimState && !isempty(c.others) && !isnothing(base)) || return out
    for k in keys(c.others)
        x = something(_by_key(base.entries, k), _by_key(base.systems, k), _by_key(base.groups, k),
            Some(nothing))
        isnothing(x) || _key(x) in out || push!(out, _key(x))
    end
    return out
end

"""
The keys of the lines whose state of the files a save of the `gui` keeps: those of an open conflict
(`gui.sync.conflicts`) and those that another participant claims (`_claimed_lines`).
"""
_held_keys(gui::LiveView) = union(gui.sync.conflicts, _claimed_lines(gui))

"""
    _composed(gui, project) -> (; project, keys)

What a save of the `gui` writes of its setup `project` (see `_project_parts`): the setup, except at
the lines of an open conflict (see `_ProjectConflict`) and the lines that another participant claims
(see `_claimed_lines`), where the files keep their state (`base`): of a conflict until the person
decides, of a claim until it is released. The window keeps its own state of them meanwhile and
writes it once that is over; if the other wrote the line meanwhile, the merge makes it a conflict.
`keys` are the keys of the lines of the files that the result holds, widened by
`BeamletOpticsProjects.compose` to the systems and groups that keep the tree of the result whole.
"""
function _composed(gui::LiveView, project)
    s = gui.sync
    held = isnothing(s.base) ? String[] : _held_keys(gui)
    isempty(held) && return (; project, keys = String[])
    return BMOP.compose(s.base, project, s.base, held)
end

"""
    _saved_state(gui, project) -> Project

What a save of the `gui` writes of its setup `project`, see `_composed`.
"""
_saved_state(gui::LiveView, project) = _composed(gui, project).project

"""
    _kept_back(gui, mine) -> Vector{String}

The keys of the lines of the setup `mine` of the `gui` (see `_project_parts`) whose state of the
window a save does not write, see `_composed`: those that differ from the state of the files there.
"""
function _kept_back(gui::LiveView, mine)
    c = _composed(gui, mine)
    isempty(c.keys) && return String[]
    d = BMOP.diff_projects(c.project, mine)
    changed = Set{String}(_change_key(x) for x in Iterators.flatten((d.entries, d.systems, d.groups)))
    return String[k for k in c.keys if k in changed]
end

# What the text `text` of `system.jl` changes in the text `base`: the lines that only one of them
# has, sorted. A merge of the files changes both alike, so this stays while the files change.
function _own_change(base::AbstractString, text::AbstractString)
    a, b = Set(split(base, '\n')), Set(split(text, '\n'))
    return join(sort!(String[symdiff(a, b)...]), '\n')
end

"""
    _autosave!(gui; now = time(), force = false) -> Symbol

One look of the autosave at the setup of the `gui`, after `_check_files!`: once the setup differs
from the files (`base`) and its change has not changed for `_AUTOSAVE_DELAY` seconds (`_own_change`:
a merge of the files does not count), it is saved (`:saved`) and the changes of the person are added
to the journal of `.bmo/session.md` (`_journal!`); files changed meanwhile are merged first. An open
conflict and the claims of others hold only their own objects: the save writes everything else, see
`_composed`. `:pending` while it waits, `:none` if the setup is as in the files. `:paused` while
the mouse drags or places an object (also in a linked view, see `open_system`) or an object glides
to a pose of the files, and while the files changed and are not merged yet, there for at most
`_AUTOSAVE_WAIT` seconds since the change of the person: then it is saved anyway, while other
writers keep changing the files. While the files do not load (e.g. an agent is half through an
edit), the setup is written to the backup of the person (see `_write_backup!`) instead (`:paused`)
and saved once they load again. `:busy` if another participant held the write lock of the files,
tried again after `_AUTOSAVE_DELAY` seconds; `:failed` if the save failed, the reason in the status
line, tried again after `_AUTOSAVE_RETRY` seconds. `force` saves without waiting and while the
files changed or objects glide (when the window closes or `Ctrl+S` saves a version). A window that
closes with objects whose state of the window is not written (see `_kept_back`) writes its setup to
the backup of the person, which `.bmo/session.md` names.
"""
function _autosave!(gui::LiveView; now::Real = time(), force::Bool = false)
    s = gui.sync
    dir = gui.project
    (isnothing(dir) || isnothing(s.base)) && return :none
    if force
        _finish_glides!(gui)
    else
        (_busy(gui) || !isempty(s.gliding)) && return :paused
    end
    # The name of the files that the view agrees with, not read from `Project.toml` at every look
    parts = _project_parts(gui, dir; name = s.base.name)
    # The person's version of the objects that the files keep is lost otherwise
    force && s.closed && !isempty(_kept_back(gui, parts.project)) && _write_backup!(gui, parts.project)
    text = _uidless_code(_saved_state(gui, parts.project))
    base = _uidless_code(s.base)
    if text == base
        s.text, s.edited_at = nothing, nothing
        return :none
    end
    change = _own_change(base, text)
    if change != s.text
        s.text, s.edited_at = change, now
        force || return :pending
    end
    # Written to the backup already, the files still do not load
    isnothing(s.edited_at) && s.failed && !force && return :paused
    if !force && !isnothing(s.edited_at)
        now - s.edited_at < _AUTOSAVE_DELAY && return :pending
        # The watcher merges files that changed (gliding) before the save, unless they keep changing
        !isnothing(s.changed_at) && now - s.edited_at < _AUTOSAVE_WAIT && return :paused
    end
    s.edited_at = nothing
    if s.failed
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
files; files that do not load then write the backup, a conflict and the claims of others hold only
their objects (see `_composed`). While another participant holds the write lock of the files, it is
tried again after `_AUTOSAVE_DELAY` seconds (`:busy`), without waiting here. A new list of objects
without a recipe stays in the status line and is warned once; otherwise the status line stays as
it was.
"""
function _autosave_write!(gui::LiveView, parts, now::Real)
    s = gui.sync
    dir = gui.project
    if BMOP.project_stamp(dir) != s.stamp
        s.changed_at = nothing
        if _adopting(() -> _sync!(gui; animate = false), gui) === :failed
            _write_backup!(gui, _collect_project(gui, dir))
            return :paused
        end
        parts = _project_parts(gui, dir)
        _uidless_code(_saved_state(gui, parts.project)) == _uidless_code(s.base) && return :none
    end
    changes = BMOP.diff_projects(s.base, _saved_state(gui, parts.project))
    status = gui.status.text[]
    result = Base.CoreLogging.with_logger(Base.CoreLogging.SimpleLogger(stderr, Base.CoreLogging.Error)) do
        _save_to!(gui, dir)
    end
    if result === :busy
        s.edited_at = now
        return :busy
    end
    if result !== :saved
        # Files that do not load (found by a merge of the save), or an error in the status line
        if s.failed
            _write_backup!(gui, _collect_project(gui, dir))
            return :paused
        end
        s.edited_at = now + _AUTOSAVE_RETRY
        return :failed
    end
    # Not the changes of the lines that the save did not write: claimed since the last read
    held = _held_keys(gui)
    isempty(held) || (changes = map(cs -> filter(c -> !(_change_key(c) in held), cs), changes))
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

"""
Writes the setup `mine` of the `gui` to `.bmo/window-backup-<person>.jl` (see `_person`), while
the files do not load: each person has a backup of their own.
"""
function _write_backup!(gui::LiveView, mine)
    name = "window-backup-$(_person().id).jl"
    file = joinpath(gui.project, ".bmo", name)
    mkpath(dirname(file))
    write(file, BMOP.system_code(mine))
    note = "the window is kept in .bmo/$name"
    st = gui.status.text[]
    occursin(note, st) || (gui.status.text[] = isempty(st) ? note : "$st; $note")
    _note_session!(gui)
    return file
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
`LiveProjectSync.jl` and `BeamletOpticsProjects.merge_plan`: the changes of the files since `base`
that the window did not change too are applied (`_adopt!`, moved objects glide if `animate`), the
members of a system that both changed are merged as sets, conflicting ones are left and shown on a
card (`_ProjectConflict`), also changes back to an older state of the window (see `_stale`) and
the conflicts still open from before, unless the files now agree with the window there. The files
become the new `base`; the status line names the person whose window wrote them (`_writer`), else
"agent". Returns `:applied`, `:conflict` or `:failed` (the reason in the status line
and in `load_error`, the window as it was).
"""
function _sync!(gui::LiveView; animate::Bool = _shown(gui))
    s = gui.sync
    dir = gui.project
    # The own code as it is loaded, not as the last look saw it (read before the load, such that a
    # change between both is found by the next look)
    src = _src_marks(_file_marks(dir))
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
    rebuild = src == s.src ? Symbol[] : _calls_own_code(disk)
    mine = _collect_project(gui, dir)
    # A conflict of before stays until the person decides, or the files agree with the window. A
    # new id of the files that an unsaved object of the window has too stays the files': the
    # window's object gets the next id when it is saved (see `_project_ids`), so `renames` of the
    # plan is not applied here
    plan = BMOP.merge_plan(s.base, mine, disk; stale = k -> _stale(s, k, disk), rebuild,
        keep = s.conflicts)
    conflicts = plan.conflicts
    new_conflicts = setdiff(conflicts, s.conflicts)
    done = _adopt!(gui, mine, disk, plan.take; rebuild = Set(rebuild), animate, merged = plan.merged)
    s.base = _align_uids!(gui, disk)
    s.stamp = disk.stamp
    s.src = src
    s.conflicts = conflicts
    s.theirs = disk
    if isempty(conflicts)
        _release_info!(gui, _ProjectConflict)
        # The other person whose window wrote these files, else an agent
        who = something(_writer(gui, disk.stamp), "agent")
        isempty(done) || (gui.status.text[] = "$who: " * join(done, ", "))
        _note_session!(gui)
        return :applied
    end
    # The card comes for new conflicts only; one that the person closed without deciding stays
    # closed, its objects keep the files' state (see `_saved_state`)
    isempty(new_conflicts) || _show_conflict!(gui, conflicts)
    _note_session!(gui)
    return :conflict
end

"""
Gives the entries, systems and groups of the `project` without a machine id (lines of an agent) the
one that the `gui` gave their objects (see `ids`), such that the project and the window compare equal.
"""
function _align_uids!(gui::LiveView, project)
    for (i, ge) in enumerate(project.groups)
        isnothing(ge.uid) || continue
        g = _window_object(gui, ge)
        isnothing(g) && continue
        project.groups[i] = BMOP.GroupEntry(ge.name, ge.members, ge.pos, ge.rot, ge.object, ge.label,
            gui.sync.ids[g][2])
    end
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

"""The object, source or system of the `gui` of the entry key `key` (a uid, or `"id:L1"`)."""
function _object_of_key(gui::LiveView, key::String)
    name = startswith(key, "id:") ? Symbol(key[4:end]) : nothing
    for (obj, (id, uid)) in gui.sync.ids
        (isnothing(name) ? uid == key : id === name) && return obj
    end
    return nothing
end

"""
The objects of the `gui` that the names `names` (members of a system or group of the files `disk`)
stand for, those for which `shown` is `true`: the object of an entry, the window group of a group,
or for a group that the window has not (yet, see `_make_groups!`) the objects of its members.
"""
function _member_objects(gui::LiveView, disk, names, shown)
    out = Any[]
    for n in names
        key = "id:" * String(n)
        x = something(_by_key(disk.entries, key), _by_key(disk.groups, key), Some(nothing))
        isnothing(x) && continue
        o = _window_object(gui, x)
        if !isnothing(o) && shown(o)
            push!(out, o)
        elseif x isa BMOP.GroupEntry
            append!(out, _member_objects(gui, disk, x.members, shown))
        end
    end
    return out
end

"""
The objects of the `gui` of the keys `ks` of entries and groups (see `BeamletOpticsProjects.merge_plan`)
for which `shown` is `true`; a group that the window has not, by its members in the first of the
`projects` that has it.
"""
function _key_objects(gui::LiveView, projects, ks, shown)
    out = Any[]
    for k in ks
        o = _object_of_key(gui, k)
        if !isnothing(o) && shown(o)
            push!(out, o)
            continue
        end
        for p in projects
            ge = _by_key(p.groups, k)
            isnothing(ge) && continue
            append!(out, _member_objects(gui, p, ge.members, shown))
            break
        end
    end
    return out
end

"""
Makes the systems of the `gui` that are in `keys` have the members and sources of the files `disk`;
those of `merged` (see `BeamletOpticsProjects.merge_plan`) get the merged members and sources, given
by keys of entries and groups (`mine` is the state of the window). A group that the window has not
yet stands for its members until it is made, see `_make_groups!`. Objects and sources that the
person removed from the view stay removed.
"""
function _sync_members!(gui::LiveView, disk, keys; merged = Dict{String, Any}(), mine = nothing)
    # The ids of objects removed from the view are kept, see `_project_ids`
    shown(@nospecialize o) = _shown_top(gui, o) || _has(_sources(gui), o)
    for se in disk.systems
        (_key(se) in keys || haskey(merged, _key(se))) || continue
        sys = _window_object(gui, se)
        sys isa BMO.System || continue
        want, sources = _member_objects(gui, disk, se.members, shown), _member_objects(gui, disk, se.sources, shown)
        if haskey(merged, _key(se))
            # Changed both in the window and in the files: the union of what each added (an object
            # of the window that is not saved yet has no id here and is not removed)
            m = merged[_key(se)]
            projects = isnothing(mine) ? Any[disk] : Any[disk, mine]
            want, sources = _key_objects(gui, projects, m.members, shown), _key_objects(gui, projects, m.sources, shown)
        end
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

#=
Groups of the files in the window: a group whose members change is made anew, one that only moves,
is renamed or relabeled is changed in place
=#

# The keys of the members of the group `ge` of the project `p`, by the names of its entries and groups
_group_member_keys(p, ge) = String[_key(x) for n in ge.members
                                   for x in (something(_by_key(p.entries, "id:" * String(n)),
                                                       _by_key(p.groups, "id:" * String(n)), Some(nothing)),)
                                   if !isnothing(x)]

"""
    _group_plan(gui, mine, disk, keys, merged, rebuilt) -> (; dissolve, make)

How the groups of the `gui` (whose state is `mine`, see `_collect_project`: the `object` of each of
its groups is the window group) take the groups of the files `disk` for the `keys` and `merged` of a
merge (see `_adopt!`):

- `dissolve`: the outermost groups of the window whose tree is made anew, since a group in it is
  added, removed or gets other members in the files, or it holds one of the objects `rebuilt` (that
  are removed or rebuilt, which must be top-level for that);
- `make`: the groups to make afterwards, `(; key, old, name, label, uid, pos, rot, members)`, whose
  members are keys of entries and groups or objects of the window: as in the files for the `keys`,
  the merged members for `merged`, and the window group `old` as it is for the other groups of the
  dissolved trees, also one that is not saved yet (it has no id then, `name` is `nothing`).
"""
function _group_plan(gui::LiveView, mine, disk, keys, merged, rebuilt)
    comp = gui.components
    restructure = Set{String}()
    for ge in disk.groups
        k = _key(ge)
        (k in keys || haskey(merged, k)) || continue
        mg = _by_key(mine.groups, k)
        want = haskey(merged, k) ? merged[k].members : Set(_group_member_keys(disk, ge))
        (isnothing(mg) || Set(_group_member_keys(mine, mg)) != want) && push!(restructure, k)
    end
    for mg in mine.groups
        k = _key(mg)
        k in keys && isnothing(_by_key(disk.groups, k)) && push!(restructure, k)
    end
    # The outermost window groups of the trees to make anew
    dissolve = Any[]
    function mark!(@nospecialize(o))
        top = _component_top(gui, o)
        haskey(comp.groups, top) && !_has(dissolve, top) && push!(dissolve, top)
        return nothing
    end
    for k in restructure
        mg = _by_key(mine.groups, k)
        o = isnothing(mg) ? _object_of_key(gui, k) : mg.object
        isnothing(o) || mark!(o)
    end
    foreach(mark!, rebuilt)
    # Every group of these trees is made anew, also those that did not change
    trees = Any[]
    collect_groups!(@nospecialize(g)) = (push!(trees, g);
        foreach(m -> haskey(comp.groups, m) && collect_groups!(m), BMO.objects(g)))
    foreach(collect_groups!, dissolve)
    make = NamedTuple[]
    made = Set{String}()
    function from_files!(k, old)
        ge = _by_key(disk.groups, k)
        isnothing(ge) && return nothing
        members = haskey(merged, k) ? Any[merged[k].members...] : Any[_group_member_keys(disk, ge)...]
        push!(make, (; key = k, old, ge.name, ge.label, ge.uid, ge.pos, ge.rot, members))
        return nothing
    end
    for g in trees
        i = findfirst(x -> x.object === g, mine.groups)
        mg = isnothing(i) ? nothing : mine.groups[i]
        k = isnothing(mg) ? nothing : _key(mg)
        isnothing(k) || push!(made, k)
        if !isnothing(k) && (k in keys || haskey(merged, k))
            from_files!(k, g)
        else
            # As in the window, by its objects: also members that are not saved
            name, label, uid = isnothing(mg) ? (nothing, nothing, nothing) : (mg.name, mg.label, mg.uid)
            R = Matrix{Float64}(BMO.orientation(g))
            push!(make, (; key = k, old = g, name, label, uid, pos = Tuple(Vector{Float64}(position(g))),
                rot = R, members = collect(Any, BMO.objects(g))))
        end
    end
    for k in restructure
        k in made || from_files!(k, nothing)
    end
    return (; dissolve, make)
end

"""
Dissolves the top-level group `g` made in the window of the `gui` and the window groups inside it,
without undo entries and without selecting: their members take their places in the systems.
Returns the objects that were members.
"""
function _unmake_group!(gui::LiveView, @nospecialize(g))
    ctrl = gui.controls
    systems = _member_systems(gui, g)
    members = collect(Any, BMO.objects(g))
    _change!(ctrl, nothing) do
        for sys in systems
            delete!(sys, g)
            foreach(m -> push!(sys, m), members)
        end
    end
    _unshow_group!(gui, g, systems)
    _sync_structure!(gui)
    isempty(systems) || _on_systems_change!(gui, systems)
    # Also the linked views, which followed the ungrouping
    foreach(v -> _drop_history!(v.controls, Any[g]), Any[gui, gui.links.views...])
    ctrl.selected[] === g && (ctrl.selected[] = nothing)
    delete!(gui.sync.ids, g)
    freed = copy(members)
    for m in members
        haskey(gui.components.groups, m) && append!(freed, _unmake_group!(gui, m))
    end
    return freed
end

"""
Makes the groups `specs` (see `_group_plan`) in the `gui`, inner groups first: each an
`ObjectGroup` of its members (keys of entries and groups, or objects; a group of the window that is
made anew stands for the new one), which are taken out of their systems, with the pivot and
orientation of its spec; the group goes into each of these systems. Without undo entries and
without selecting. A member that is not in the view or not top-level is left out, a group without
members is not made. A spec with a `name` gives the group that id (the stale object of a group that
had the uid loses it). Adds `"grouped G1"` to `done` and the groups to `touched`.
"""
function _make_groups!(gui::LiveView, specs, done, touched; replaced = IdDict{Any, Any}())
    ctrl = gui.controls
    ids = gui.sync.ids
    remade = IdDict{Any, Any}()
    pending = collect(specs)
    waits(s, ref) = ref isa String ? (ref == s.key) : (ref === s.old)
    resolve(ref) = ref isa String ? _object_of_key(gui, ref) : get(remade, ref, get(replaced, ref, ref))
    while !isempty(pending)
        i = findfirst(s -> !any(ref -> any(t -> t !== s && waits(t, ref), pending), s.members), pending)
        # A cycle can not come from a loaded project; whatever is left is not made
        isnothing(i) && break
        s = popat!(pending, i)
        members = Any[o for ref in s.members for o in (resolve(ref),)
                      if !isnothing(o) && _shown_top(gui, o)]
        isempty(members) && continue
        g = BMO.ObjectGroup(members)
        BMO.set_pivot3d!(g, Float64[s.pos...])
        isnothing(s.rot) || BMO.orientation!(g, BMOP.rotation_matrix(s.rot))
        systems = unique(objectid, Any[sys for m in members for sys in _member_systems(gui, m)])
        _change!(ctrl, nothing) do
            for sys in systems
                foreach(m -> _has(sys.objects, m) && delete!(sys, m), members)
                push!(sys, g)
            end
        end
        isnothing(s.old) || (remade[s.old] = g)
        if isnothing(s.name)
            _show_group!(gui, g, _current_record(g), systems)
        else
            _show_group!(gui, g, _current_record(g), systems; label = _shown_label(s))
            for (o, (_, uid)) in collect(ids)
                o !== g && !isnothing(s.uid) && uid == s.uid && delete!(ids, o)
            end
            _name!(gui, g, s)
        end
        _sync_structure!(gui)
        isempty(systems) || _on_systems_change!(gui, systems)
        push!(touched, g)
        isnothing(s.old) && push!(done, "grouped $(_shown_label(s))")
    end
    return nothing
end

"""
Takes the objects `freed` (members of dissolved groups, see `_unmake_group!`) that are top-level
objects after the groups were made again out of the systems of the `gui` that do not list them:
the system of the files `disk` for the `keys` and `merged`, else that of the window `mine`. A
dissolved group put its members into its systems, which list only the group.
"""
function _settle_freed!(gui::LiveView, mine, disk, keys, merged, freed)
    for o in freed
        (_shown_top(gui, o) && haskey(gui.sync.ids, o)) || continue
        name, uid = gui.sync.ids[o]
        for sys in _member_systems(gui, o)
            haskey(gui.sync.ids, sys) || continue
            k = gui.sync.ids[sys][2]
            listed = if haskey(merged, k)
                uid in merged[k].members || "id:" * String(name) in merged[k].members
            else
                se = _by_key((k in keys ? disk : mine).systems, k)
                isnothing(se) || name in se.members
            end
            listed || _unrecorded(() -> _remove_member!(gui, o, sys), gui)
        end
    end
    return nothing
end

"""
The groups of the files `disk` that the window of the `gui` has and that only moved, were renamed or
relabeled for the `keys`: changed in place. The members keep the poses of their own lines, so the
pivot and the orientation are set without moving them.
"""
function _adopt_groups!(gui::LiveView, mine, disk, keys, done)
    for ge in disk.groups
        _key(ge) in keys || continue
        mg = _by_key(mine.groups, _key(ge))
        isnothing(mg) && continue
        g = _window_object(gui, ge)
        (isnothing(g) || !haskey(gui.components.groups, g)) && continue
        if ge.name !== mg.name || ge.label != mg.label
            _name!(gui, g, ge)
            push!(done, "renamed $(_shown_label(ge))")
        end
        R = BMOP.rotation_matrix(ge.rot)
        if collect(ge.pos) != Vector{Float64}(position(g)) || maximum(abs, R - BMO.orientation(g)) > 1e-12
            _change!(gui.controls, nothing) do
                BMO.set_pivot3d!(g, Float64[ge.pos...])
                BMO.orientation!(g, R)
            end
            gui.components.groups[g] = _current_record(g)
            push!(done, "moved $(_shown_label(ge))")
        end
    end
    return nothing
end

"""
    _adopt!(gui, mine, disk, keys; rebuild = Set{Symbol}(), animate = _shown(gui), merged = Dict()) -> Vector{String}

Makes the entries, systems and groups of the `keys` in the open `gui` (whose state is the project
`mine`, see `_collect_project`) as in the files `disk`, without undo entries: removes, adds,
rebuilds (other code, or calling own code in `rebuild`), moves (gliding if `animate`, see
`_glide_all!`), renames and relabels; the systems and groups of `merged` get the merged members (see
`_sync_members!`). A group whose members change is made anew with the window groups around and
inside it (see `_group_plan`), one that only moved or was renamed is changed in place. The changed
objects get a box for a moment. Returns what was done, e.g. `"moved M1"`.
"""
function _adopt!(gui::LiveView, mine, disk, keys; rebuild = Set{Symbol}(), animate::Bool = _shown(gui),
        merged = Dict{String, Any}())
    done = String[]
    touched = Any[]
    glides = Tuple{Any, Any, Any}[]
    m = BMOP.match_entries(disk.entries, mine.entries)
    # The trees of groups that change are dissolved first and made again after the entries and the
    # systems, so that removed and rebuilt members are top-level objects then
    rebuilt = Any[e.object for e in m.added if _key(e) in keys]
    for (e, mine_e) in m.pairs
        _key(e) in keys || continue
        (e.kind != mine_e.kind || e.name in rebuild ||
         BMOP.normalize_code(e.code) != BMOP.normalize_code(mine_e.code)) && push!(rebuilt, mine_e.object)
    end
    groups = _group_plan(gui, mine, disk, keys, merged, rebuilt)
    freed = Any[o for g in groups.dissolve for o in _unmake_group!(gui, g)]
    # The objects that a rebuild replaced, for the groups made again by their objects
    replaced = IdDict{Any, Any}()
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
        push!(done, "added $(_shown_label(e))")
    end
    for (e, mine_e) in m.pairs
        _key(e) in keys || continue
        obj = mine_e.object
        if e.kind != mine_e.kind || e.name in rebuild ||
           BMOP.normalize_code(e.code) != BMOP.normalize_code(mine_e.code)
            new = _swap!(gui, obj, e)
            replaced[obj] = new
            push!(touched, new)
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
            push!(done, "renamed $(_shown_label(e))")
        end
        isequal(Dict(e.meta), Dict(mine_e.meta)) || _update_record!(gui, obj; meta = Pair{Symbol, Any}[e.meta...])
    end
    _sync_members!(gui, disk, keys; merged, mine)
    _make_groups!(gui, groups.make, done, touched; replaced)
    _settle_freed!(gui, mine, disk, keys, merged, freed)
    _adopt_groups!(gui, mine, disk, keys, done)
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
    # The table fits the setup of the files, see `_table_fit!`
    isempty(glides) && (_flash!(gui, touched); _table_fit!(gui); return done)
    # The autosave waits until they landed, a save lands them at once
    foreach(((obj, (P, R), e),) -> (gui.sync.gliding[obj] = (P, R, e)), glides)
    finish() = begin
        _glide_all!(gui, glides; animate)
        _flash!(gui, Any[touched..., first.(glides)...])
        _table_fit!(gui)
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
    keys = Set{String}(_key(x) for x in Iterators.flatten((disk.entries, disk.systems, disk.groups,
        mine.entries, mine.systems, mine.groups)))
    _release_info!(gui, _ProjectConflict)
    done = _adopting(() -> _adopt!(gui, mine, disk, keys; rebuild = Set(_calls_own_code(disk))), gui)
    # Taken in from the files, not written by the window
    _saved!(gui, disk; written = false)
    gui.status.text[] = isempty(done) ? "project reloaded, nothing changed" : "reloaded: " * join(done, ", ")
    return nothing
end

"""
    _ProjectConflict

Objects that were changed both in the window and in the files of its project (e.g. by an agent),
differently: an info card at `point` with a row per object (`names`, their `keys`) to take the
state of the files ("theirs") or keep the window's ("mine"), and buttons for all of them and for
"Save as…", see `_resolve_conflict!`. All other changes of the files are already applied (see
`_sync!`), and the window saves all other changes meanwhile; the files keep their state of these
objects until the person decides (see `_saved_state`).
"""
struct _ProjectConflict <: _InfoItem
    point::Point3f
    names::Vector{String}
    keys::Vector{String}
end

_points(x::_ProjectConflict) = [x.point]
_title(::_ProjectConflict) = "Changed here and in the files"
_tree_kind(::_ProjectConflict) = :warning
_keep_plots!(::LiveView, ::_ProjectConflict) = nothing
_keepable(::_ProjectConflict) = false
function card_rows(x::_ProjectConflict)
    rows = Any[_text_row("files", :conflict_files,
        (_, _) -> "the rest is applied and saved; these keep the files' state until you choose"; width = 48)]
    for (i, (name, key)) in enumerate(zip(x.names, x.keys))
        push!(rows, CardRow(name,
            CardWidget(Button; name = Symbol("conflict_theirs_", i), label = "theirs",
                on = (gui, _, _) -> _resolve_conflict!(gui, :theirs, [key])),
            CardWidget(Button; name = Symbol("conflict_mine_", i), label = "mine",
                on = (gui, _, _) -> _resolve_conflict!(gui, :mine, [key]))))
    end
    push!(rows, CardRow(
        CardWidget(Button; name = :conflict_theirs, label = "All theirs",
            on = (gui, _, _) -> _resolve_conflict!(gui, :theirs)),
        CardWidget(Button; name = :conflict_mine, label = "All mine",
            on = (gui, _, _) -> _resolve_conflict!(gui, :mine)),
        CardWidget(Button; name = :conflict_save_as, label = "Save as…",
            on = (gui, _, _) -> _resolve_conflict!(gui, :save_as))))
    return Tuple(rows)
end

# The name of the entry, group or system of the conflict `key` of the `gui`
function _conflict_name(gui::LiveView, key::String)
    t = gui.sync.theirs
    x = isnothing(t) ? nothing :
        something(_by_key(t.entries, key), _by_key(t.systems, key), _by_key(t.groups, key), Some(nothing))
    isnothing(x) || return _shown_label(x)
    obj = findfirst(v -> v[2] == key, gui.sync.ids)
    return isnothing(obj) ? key : _label(gui, obj)
end

"""Shows the card of the conflict of the `gui` for the entries, systems and groups of the `keys`."""
function _show_conflict!(gui::LiveView, keys::Vector{String})
    names = String[_conflict_name(gui, k) for k in keys]
    _show_info!(gui, _ProjectConflict(_error_anchor(gui), names, copy(keys)))
    gui.status.text[] = "changed here and in the files: $(join(names, ", ")); choose on the card"
    return nothing
end

"""
    _resolve_conflict!(gui, how, keys = all open ones)

Resolves the conflict of the `gui` (see `_ProjectConflict`) for the objects of the `keys` as the
person chose, `how`: `:theirs` takes them from the files (their changes here are lost), `:mine`
keeps them as they are here, which the autosave writes next; `:save_as` saves the window as a new
project (see `_save_as_key!`), which ends all conflicts once it is saved (`_saved!`). The card shows
the objects still open, if any.
"""
function _resolve_conflict!(gui::LiveView, how::Symbol, keys = copy(gui.sync.conflicts))
    s = gui.sync
    _release_info!(gui, _ProjectConflict)
    if how === :save_as
        _save_as_key!(gui)
        return nothing
    end
    keys = String[k for k in keys if k in s.conflicts]
    names = String[_conflict_name(gui, k) for k in keys]
    if how === :theirs && !isnothing(s.theirs)
        mine = _collect_project(gui, gui.project)
        done = _adopting(() -> _adopt!(gui, mine, s.theirs, Set(keys)), gui)
        gui.status.text[] = "taken from the files: " * join(isempty(done) ? names : done, ", ")
    elseif how === :mine
        gui.status.text[] = "kept as here, written to the files: " * join(names, ", ")
    end
    filter!(k -> !(k in keys), s.conflicts)
    isempty(s.conflicts) || _show_conflict!(gui, s.conflicts)
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
