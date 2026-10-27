#=
Working on a project while an agent changes its files. A watcher looks at the times of the files
of the project of a shown view; when they changed and settled, the project is loaded and compared
with the state that the view and the files last agreed on (`base`) and with the setup in the view:
what only the files changed is applied in the open window (moved objects glide, new ones appear,
changed ones are rebuilt, removed ones go), what both changed differently is a conflict, shown on
a card. The window is never replaced.
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
    _saved!(gui, project)

Records that the `gui` and the files of the `project` agree, after it was opened, saved or the
files were merged: `project` becomes the `base` of the comparisons (see `_ProjectSync`), and the
watcher starts if the `gui` is shown.
"""
function _saved!(gui::LiveView, project)
    s = gui.sync
    s.base = _align_uids!(gui, project)
    s.stamp = project.stamp
    s.marks = _file_marks(project.path)
    s.src = _src_marks(s.marks)
    s.changed_at = s.handled = nothing
    s.failed = false
    _start_watching!(gui)
    return nothing
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
    _check_files!(gui; now = time()) -> Symbol

One look of the watcher at the files of the project of the `gui`: `:pending` while they change or
have not stayed unchanged for `_SETTLE` seconds; then, once per state of the files, `:applied`,
`:conflict` or `:failed`, see `_sync!`; `:none` otherwise, also for the files that the `gui` saved
itself. A load error shown before is cleared when the files are back to the state of the `gui`.
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
    isnothing(s.changed_at) && return :none
    now - s.changed_at < _SETTLE && return :pending
    s.changed_at = nothing
    disk = BMOP.project_stamp(dir)
    if disk == s.stamp
        # Saved by the view itself, or back to the state of the view
        s.failed && (s.failed = false; gui.status.text[] = "project files are as in the window")
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
    _sync!(gui) -> Symbol

Loads the project of the `gui` from its files and merges it into the open window, see
`LiveProjectSync.jl`: the changes of the files since `base` that the window did not change too are
applied (`_adopt!`), conflicting ones are left and shown on a card (`_ProjectConflict`). The
files become the new `base`. Returns `:applied`, `:conflict` or `:failed` (the reason in the status
line, the window as it was).
"""
function _sync!(gui::LiveView)
    s = gui.sync
    dir = gui.project
    disk = try
        BMOP.load_project(dir)
    catch e
        e isa InterruptException && rethrow()
        s.failed = true
        gui.status.text[] = "project not reloaded: $(_load_message(e))"
        return :failed
    end
    s.failed = false
    # The lines without uid (of an agent) get those of their objects in the window
    _align_uids!(gui, disk)
    rebuild = _src_marks(s.marks) == s.src ? Symbol[] : _calls_own_code(disk)
    d = BMOP.diff_projects(s.base, disk; rebuild)
    mine = _collect_project(gui, dir)
    g = BMOP.diff_projects(s.base, mine)
    theirs = Set{String}(_change_key(c) for c in Iterators.flatten((d.entries, d.systems)))
    ours = Set{String}(_change_key(c) for c in Iterators.flatten((g.entries, g.systems)))
    conflicts = String[k for k in theirs if k in ours && !_same_state(mine, disk, k)]
    done = _adopt!(gui, mine, disk, setdiff(theirs, conflicts); rebuild = Set(rebuild))
    s.base = _align_uids!(gui, disk)
    s.stamp = disk.stamp
    s.src = _src_marks(s.marks)
    s.conflicts = conflicts
    s.theirs = disk
    if isempty(conflicts)
        isempty(done) || (gui.status.text[] = "agent: " * join(done, ", "))
        return :applied
    end
    _show_conflict!(gui, conflicts)
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
Moves `obj` of the `gui` to the pose `(P1, R1)`: gliding over `_GLIDE` seconds if `animate`, the
position along the line, the orientation about the axis of the rotation between the two.
"""
function _glide!(gui::LiveView, @nospecialize(obj), P1, R1; animate::Bool)
    ctrl = gui.controls
    set!(P, R) = (_change!(() -> _set_pose!(obj, P, R), ctrl, obj); _apply_update!(ctrl, obj))
    if animate
        P0, R0 = _pose(obj)
        axis, angle = _rotation_axis_angle(Matrix{Float64}(R1) * Matrix{Float64}(R0)')
        n = max(1, round(Int, _GLIDE * _GLIDE_FPS))
        for i in 1:(n - 1)
            f = i / n
            f = f * f * (3 - 2f)
            R = angle > 0 ? _axis_rotation(axis, f * angle) * R0 : R0
            set!(Point3{Float64}(P0 .+ f .* (Vector{Float64}(P1) .- P0)), R)
            sleep(1 / _GLIDE_FPS)
        end
    end
    _change!(() -> _place_exactly!(obj, P1, R1), ctrl, obj)
    _apply_update!(ctrl, obj)
    return nothing
end

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
    _adopt!(gui, mine, disk, keys; rebuild = Set{Symbol}()) -> Vector{String}

Makes the entries and systems of the `keys` in the open `gui` (whose state is the project `mine`,
see `_collect_project`) as in the files `disk`, without undo entries: removes, adds, rebuilds (other
code, or calling own code in `rebuild`), moves (gliding, if the `gui` is shown), renames and
relabels. The changed objects get a box for a moment. Returns what was done, e.g. `"moved M1"`.
"""
function _adopt!(gui::LiveView, mine, disk, keys; rebuild = Set{Symbol}())
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
    animate = _shown(gui)
    finish() = begin
        for (obj, (P, R), e) in glides
            _glide!(gui, obj, P, R; animate)
            _update_record!(gui, obj; pos = e.pos, rot = e.rot, pose = _pose(obj))
        end
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
        gui.status.text[] = "project not reloaded: $(_load_message(e))"
        return nothing
    end
    _align_uids!(gui, disk)
    mine = _collect_project(gui, gui.project)
    keys = Set{String}(_key(x) for x in Iterators.flatten((disk.entries, disk.systems, mine.entries,
        mine.systems)))
    _release_info!(gui, _ProjectConflict)
    done = _adopt!(gui, mine, disk, keys; rebuild = Set(_calls_own_code(disk)))
    _saved!(gui, disk)
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
`Ctrl+S` found the files changed since the window last agreed with them (`ProjectChanged`): merges
them now (see `_sync!`) and saves again if that left no conflict.
"""
function _show_conflict!(gui::LiveView)
    gui.sync.changed_at = nothing
    _sync!(gui) === :applied || return nothing
    try
        save_project(gui, gui.project)
    catch e
        e isa InterruptException && rethrow()
        gui.status.text[] = "project not saved: $(_message_line(e))"
    end
    return nothing
end

"""
Resolves the conflict of the `gui` (see `_ProjectConflict`) as the user chose, `how`: `:theirs`
takes the objects of the conflict from the files (their changes here are lost), `:mine` keeps them
as they are here, which the next save writes, `:save_as` saves the window as a new project (see
`_save_as_key!`).
"""
function _resolve_conflict!(gui::LiveView, how::Symbol)
    s = gui.sync
    _release_info!(gui, _ProjectConflict)
    if how === :theirs && !isnothing(s.theirs)
        mine = _collect_project(gui, gui.project)
        done = _adopt!(gui, mine, s.theirs, Set(s.conflicts))
        gui.status.text[] = "taken from the files: " * join(done, ", ")
    elseif how === :mine
        gui.status.text[] = "kept as here; Ctrl+S writes it to the files"
    elseif how === :save_as
        _save_as_key!(gui)
    end
    empty!(s.conflicts)
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
