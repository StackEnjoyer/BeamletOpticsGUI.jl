#=
The file `.bmo/session.md` of a project: what the person sees and did in the open window, for the
agents that work on the same project (see plans/projects-reverse-sync.md). The window writes it
when the selection changes and when the autosave saved changes of the person (`_journal!`).
=#

# How many changes of the person `session.md` lists
const _JOURNAL_MAX = 20

_session_file(dir::AbstractString) = joinpath(dir, ".bmo", "session.md")

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
`$(_JOURNAL_MAX)`) and writes `.bmo/session.md`. `changes` is the result of
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

"""The id, label, type and position of the selected object of the `gui`, or `nothing`."""
function _session_selected(gui::LiveView)
    sel = gui.controls.selected[]
    isnothing(sel) && return nothing
    chain = try
        _chain(gui.controls, sel)
    catch
        Any[sel]
    end
    for x in chain
        haskey(gui.sync.ids, x) || continue
        id = gui.sync.ids[x][1]
        text = String(id)
        label = get(gui.labels, x, nothing)
        isnothing(label) || isempty(label) || label == text || (text *= " \"$label\"")
        text *= " ($(nameof(typeof(x))))"
        try
            text *= " at " * _session_pos(BMO.position(x))
        catch
        end
        return text
    end
    return nothing
end

_session_clock(t) = Libc.strftime("%H:%M:%S", t)

# The readable id of the entry or system of a conflict `key` (a uid, or "id:L1")
function _conflict_id(gui::LiveView, key::String)
    s = gui.sync
    for p in (s.theirs, s.base)
        isnothing(p) && continue
        x = something(_by_key(p.entries, key), _by_key(p.systems, key), Some(nothing))
        isnothing(x) || return String(x.name)
    end
    for (id, uid) in values(s.ids)
        uid == key && return String(id)
    end
    return startswith(key, "id:") ? key[4:end] : key
end

function _session_text(gui::LiveView)
    s = gui.sync
    io = IOBuffer()
    println(io, _session_header(gui.project))
    println(io, "Written by the open BeamletOpticsGUI window: what the person sees and did there.")
    println(io, "system.jl holds the state of the window (it saves every finished action), except while the")
    println(io, "files do not load or a conflict is open: then the window keeps its state, which")
    println(io, ".bmo/window-backup.jl holds.")
    println(io)
    sel = _session_selected(gui)
    println(io, "Selected: ", isnothing(sel) ? "nothing" : sel)
    isempty(s.conflicts) || println(io, "Open conflict: ", join((_conflict_id(gui, k) for k in s.conflicts), ", "),
        " (window and file differ; the person decides on the card)")
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

_session_header(dir) = "# Window of the project \"$(basename(abspath(dir)))\", " *
                       Libc.strftime("%Y-%m-%d %H:%M:%S", time())

# Writes `text` to `.bmo/session.md` atomically
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

Writes `.bmo/session.md` of the project of the `gui` now: selection, open conflicts, load failure
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
            @warn "could not write session.md" exception = e
        end
    end
    return nothing
end

# The last message of a failed write that was logged
const _SESSION_WARNED = Ref("")

"""
    _connect_session!(gui)

Starts writing `.bmo/session.md` whenever the selection of the `gui` changes, and writes it once.
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

Removes the listener of the `gui` and writes `.bmo/session.md` with the note that no window is open.
"""
function _session_closed!(gui::LiveView)
    for l in gui.sync.session
        off(l)
    end
    empty!(gui.sync.session)
    isnothing(gui.project) && return nothing
    _put_session(gui.project, _session_header(gui.project) * "\nNo window is open on this project.\n")
    return nothing
end
