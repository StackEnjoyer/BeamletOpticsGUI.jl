#=
The file `.bmo/session-<person>.md` of a project: what the person sees and did in the open window,
for the agents that work on the same project (see plans/projects-reverse-sync.md and
plans/projects-people.md). Every window has its own file, which is deleted at closing. The window
writes it when the selection changes and when the autosave saved changes of the person (`_journal!`).
=#

# How many changes of the person `session.md` lists
const _JOURNAL_MAX = 20

# The session file of the person of this window, see `_person`
_session_file(dir::AbstractString) = BMOP.session_file(dir, _person().id)

# A position in m with 4 significant digits, e.g. `(0.0, 0.105, 0.0)`
_session_pos(p) = "(" * join((string(round(Float64(x); sigdigits = 4)) for x in p), ", ") * ")"

_entry_pos(e) = isnothing(e.pos) ? Tuple(e.pose0[1]) : e.pos

# The code of an entry shortened to 60 characters
function _session_code(code)
    s = replace(string(code isa AbstractString ? code : BMOP.normalize_code(code)), r"\s+" => " ")
    return length(s) > 60 ? first(s, 57) * "..." : s
end

"""The one line of the journal for one change of an entry, see `_journal!`."""
function _entry_line(c)
    new, old = c.new, c.old
    c.kind === :added && return "added $(new.name) = $(_session_code(new.code))"
    c.kind === :removed && return "removed $(old.name)"
    c.kind === :renamed && return "renamed $(old.name) → $(new.name)"
    c.kind === :rebuilt && return "rebuilt $(new.name)"
    c.kind === :relabeled && return "relabeled $(new.name) \"$(something(new.label, ""))\""
    c.kind === :meta && return "changed settings of $(new.name)"
    if c.kind === :moved
        p = _entry_pos(old) != _entry_pos(new)
        r = maximum(abs, BMOP.rotation_matrix(old.rot) - BMOP.rotation_matrix(new.rot)) > 1e-13
        p && r && return "moved and rotated $(new.name) to $(_session_pos(_entry_pos(new)))"
        p && return "moved $(new.name) to $(_session_pos(_entry_pos(new)))"
        return "rotated $(new.name)"
    end
    return "changed $(new.name)"
end

"""The line of the journal for one change of a system, see `_journal!`."""
function _system_line(c, ::Nothing = nothing)
    new, old = c.new, c.old
    c.kind === :added && return "added system $(new.name)"
    c.kind === :removed && return "removed system $(old.name)"
    c.kind === :renamed && return "renamed system $(old.name) → $(new.name)"
    c.kind === :relabeled && return "relabeled system $(new.name) \"$(something(new.label, ""))\""
    return "changed system $(new.name)"
end

# `:members` as one line per added and removed member or source. `renames` maps the old id of a
# renamed entry to its new one, so that members are paired by identity like `diff_projects` does
function _member_lines(c, renames = Dict{Symbol, Symbol}())
    old, new = c.old, c.new
    lines = String[]
    for (a0, b) in ((old.members, new.members), (old.sources, new.sources))
        a = [get(renames, m, m) for m in a0]
        foreach(m -> push!(lines, "added $m to $(new.name)"), setdiff(b, a))
        foreach(m -> push!(lines, "removed $m from $(new.name)"), setdiff(a, b))
    end
    old.static == new.static || push!(lines, "set $(new.name) " * (new.static ? "static" : "not static"))
    isempty(lines) && push!(lines, "changed system $(new.name)")
    return lines
end

"""
    _journal!(gui, changes)

Adds the changes of the person to the journal of the `gui` (`gui.sync.journal`, the last
`$(_JOURNAL_MAX)`) and writes the session file. `changes` is the result of
`BeamletOpticsProjects.diff_projects` from the state before an autosave to the one it saved.
"""
function _journal!(gui::LiveView, changes)
    lines = String[]
    for c in changes.entries
        push!(lines, _entry_line(c))
    end
    renames = Dict{Symbol, Symbol}(c.old.name => c.new.name for c in changes.entries if c.kind === :renamed)
    for c in changes.systems
        if c.kind === :members
            append!(lines, _member_lines(c, renames))
        else
            push!(lines, _system_line(c))
        end
    end
    isempty(lines) && return nothing
    t = time()
    j = gui.sync.journal
    foreach(l -> push!(j, (t, l)), lines)
    length(j) > _JOURNAL_MAX && deleteat!(j, 1:(length(j) - _JOURNAL_MAX))
    _write_session!(gui)
    return nothing
end

"""
The id, label, type and position of the selected object of the `gui`, or `nothing`: of the
innermost item with an id that holds the selection, as `_presence_selected`; of a selection of
several, the number of objects and each of them.
"""
function _session_selected(gui::LiveView)
    sel = gui.controls.selected[]
    objs = sel isa _MultiSelection ? sel.objects : isnothing(sel) ? Any[] : Any[sel]
    items = String[]
    for o in objs
        x = _id_holder(gui, o)
        isnothing(x) || push!(items, _session_item(gui, x))
    end
    isempty(items) && return nothing
    length(items) == 1 && return only(items)
    return "$(length(items)) objects: " * join(items, "; ")
end

# The id, label, type and position of the item `x` with an id of the `gui`
function _session_item(gui::LiveView, @nospecialize(x))
    text = String(gui.sync.ids[x][1])
    label = get(gui.labels, x, nothing)
    isnothing(label) || isempty(label) || label == text || (text *= " \"$label\"")
    text *= " ($(nameof(typeof(x))))"
    try
        text *= " at " * _session_pos(BMO.position(x))
    catch
    end
    return text
end

# With the day: a session file of a window that was not closed may be read days later
_session_clock(t) = Libc.strftime("%Y-%m-%d %H:%M:%S", t)

# The readable id of the entry, group or system of a conflict `key` (a uid, or "id:L1")
function _conflict_id(gui::LiveView, key::String)
    s = gui.sync
    for p in (s.theirs, s.base)
        isnothing(p) && continue
        x = something(_by_key(p.entries, key), _by_key(p.systems, key), _by_key(p.groups, key),
            Some(nothing))
        isnothing(x) || return String(x.name)
    end
    for (id, uid) in values(s.ids)
        uid == key && return String(id)
    end
    return startswith(key, "id:") ? key[4:end] : key
end

"""
    _closed_kept(gui) -> Vector{String}

The readable ids of the objects of the `gui`, which is closed, whose state of the window the files
do not have (an open conflict, claimed by another participant, see `_kept_back`): the window wrote
it to the backup of the person when it closed (see `_autosave!`). Empty if it is not closed.
"""
function _closed_kept(gui::LiveView)
    s = gui.sync
    (s.closed && !isnothing(gui.project) && !isnothing(s.base)) || return String[]
    try
        mine = _project_parts(gui, gui.project; name = s.base.name).project
        return String[_conflict_id(gui, k) for k in _kept_back(gui, mine)]
    catch e
        e isa InterruptException && rethrow()
        return String[]
    end
end

function _session_text(gui::LiveView; kept = _closed_kept(gui))
    s = gui.sync
    io = IOBuffer()
    println(io, _session_header(gui.project))
    println(io, "Written by the open BeamletOpticsGUI window: what the person sees and did there.")
    println(io, "While the window is open, its presence file .bmo/presence-$(_person().id).toml changes at")
    println(io, "least every $(round(Int, _BEAT)) s; if it is older than $(round(Int, _ALIVE)) s or gone, the window was not closed")
    println(io, "properly and this file is out of date (`look` marks such a participant \"likely gone\").")
    println(io, "system.jl holds the state of the window (it saves every finished action), except the objects")
    println(io, "of an open conflict, which keep the state of the file until the person decides, those that")
    println(io, "another participant claims, until the claim is released, and while the files do not load:")
    println(io, "then the window keeps its state, which .bmo/window-backup-<person>.jl holds.")
    println(io)
    isempty(kept) || println(io, "The window was closed. The person's version of ", join(kept, ", "),
        " is not in system.jl but in .bmo/window-backup-$(_person().id).jl (the file kept its state of them).\n")
    sel = _session_selected(gui)
    println(io, "Selected: ", isnothing(sel) ? "nothing" : sel)
    isempty(s.conflicts) || println(io, "Open conflict: ", join((_conflict_id(gui, k) for k in s.conflicts), ", "),
        " (window and file differ: the file keeps its state of them until the person decides; all else is saved)")
    s.failed && println(io, "The file does not load: ", s.load_error,
        " (the window keeps its state)")
    println(io)
    if isempty(s.journal)
        println(io, "Recent changes by the person: none")
    else
        println(io, "Recent changes by the person (newest first):")
        for (t, l) in Iterators.reverse(s.journal)
            println(io, "- ", _session_clock(t), " ", l)
        end
    end
    return String(take!(io))
end

function _session_header(dir)
    p = _person()
    return "# Window of $(p.name) ($(p.host)) on the project \"$(basename(abspath(dir)))\", " *
           Libc.strftime("%Y-%m-%d %H:%M:%S", time())
end

# Writes `text` to the session file atomically
function _put_session(dir::AbstractString, text::AbstractString)
    file = _session_file(dir)
    mkpath(dirname(file))
    tmp = file * ".tmp"
    write(tmp, text)
    mv(tmp, file; force = true)
    return nothing
end

"""
    _write_session!(gui)

Writes the session file of the project of the `gui` now: selection, open conflicts, load failure
and the journal. Does nothing without a project. An error of writing never propagates; it is
logged once per distinct message.
"""
function _write_session!(gui::LiveView)
    isnothing(gui.project) && return nothing
    try
        _put_session(gui.project, _session_text(gui))
    catch e
        e isa InterruptException && rethrow()
        msg = sprint(showerror, e)
        if msg != _SESSION_WARNED[]
            _SESSION_WARNED[] = msg
            @warn "could not write the session file" exception = e
        end
    end
    return nothing
end

# The last message of a failed write that was logged
const _SESSION_WARNED = Ref("")

"""
    _connect_session!(gui)

Starts writing the session file whenever the selection of the `gui` changes, and writes it once.
Does nothing if it is connected already.
"""
function _connect_session!(gui::LiveView)
    isnothing(gui.project) && return nothing
    if isempty(gui.sync.session)
        l = on(_ -> _write_session!(gui), gui.controls.selected)
        push!(gui.sync.session, l)
    end
    _write_session!(gui)
    return nothing
end

"""
    _session_closed!(gui)

Removes the listener of the `gui` and deletes its session file (a missing file is fine). A window
that closed with objects whose state of the window the files do not have (see `_closed_kept`) keeps
the file instead, which names them and the backup of the person that holds them. An error of
deleting never propagates; it is logged once per distinct message.
"""
function _session_closed!(gui::LiveView)
    for l in gui.sync.session
        off(l)
    end
    empty!(gui.sync.session)
    isnothing(gui.project) && return nothing
    try
        kept = _closed_kept(gui)
        if isempty(kept)
            rm(_session_file(gui.project); force = true)
        else
            _put_session(gui.project, _session_text(gui; kept))
        end
    catch e
        e isa InterruptException && rethrow()
        msg = sprint(showerror, e)
        if msg != _SESSION_WARNED[]
            _SESSION_WARNED[] = msg
            @warn "could not delete the session file" exception = e
        end
    end
    return nothing
end
