#=
Several participants on one project, e.g. on a shared drive: the open windows of people and the
coding agents that change the files. Each participant has a presence file
`.bmo/presence-<id>.toml`; a window writes its own and shows where the others are (see
plans/projects-people.md).

The file holds the name and host of the participant, its `kind` (`"person"` for a window, `"agent"`
for a coding agent; default `"person"`), a counter `beat` that grows with every write, `ttl` (the
seconds that a beat counts; windows write `_ALIVE`, agents e.g. 600, since they write only when
they act), the object it works on (`selected`: its uid, `selected_id`: its readable id; `""` if
nothing; of a selection of several all of them in `selected_uids` and `selected_ids`, the first also
in `selected` and `selected_id`; the readable id counts when the uid is missing or unknown, an agent
writes only that),
of a window the keys of the lines that its person claims (`claimed`, see `LiveProjectClaims.jl`),
optionally `doing` (a few words, shown under the name) and the stamp of the files after its last
write (`written`; of a window: its last save, never files it merged). A window writes its file when it saves, when its selection changes and every
`_BEAT` seconds. It reads the files of the others at every look of the watcher: an other is there
while its `beat` changed within its `ttl` seconds of the clock of this machine, so the clocks of
the machines are never compared. People and agents are shown alike: a box at their object and
their name.
=#

# How often a window writes its presence file at least [s]
const _BEAT = 20.0
# How long an other is shown after its `beat` last changed [s]: the `ttl` of a window and the
# default of a file without one (`BeamletOpticsProjects.read_presences` clamps the `ttl` of a file)
const _ALIVE = 60.0
# At most this many characters of `doing` are shown
const _DOING_CHARS = 80
# The color of the boxes and names of the others: the green of Julia, not the accent of the themes
# (the selection, the boxes of the parts), not the purple of the clip planes or the orange of aiming
const _OTHER_COLOR = RGBf(0.22, 0.596, 0.149)
const _OTHER_BOX_WIDTH = 2
const _OTHER_FONTSIZE = 14

"""
    _person() -> (; id, name, host)

The person of this window, see `BeamletOpticsProjects.person`.
"""
_person() = BMOP.person()

"""The presence file of the person `id` in the project folder `dir`, see `BeamletOpticsProjects.presence_file`."""
_presence_file(dir::AbstractString, id::AbstractString) = BMOP.presence_file(dir, id)

"""
The machine id and the readable id of the selected object of the `gui`, `("", "")` if none: of the
innermost item with an id that holds the selection, e.g. a group (`@group`), a member of a group, or
the component of a selected part of it; of a selection of several the first object, see
`_presence_selection`.
"""
function _presence_selected(gui::LiveView)
    uids, ids = _presence_selection(gui)
    return isempty(ids) ? ("", "") : (first(uids), first(ids))
end

"""
The machine ids and readable ids of the selected objects of the `gui`, `(uids, ids)`: of each
object of a selection of several, else of the one selected (see `_presence_selected`); empty if
nothing with an id is selected.
"""
function _presence_selection(gui::LiveView)
    sel = gui.controls.selected[]
    objs = sel isa _MultiSelection ? sel.objects : isnothing(sel) ? Any[] : Any[sel]
    uids, ids = String[], String[]
    for o in objs
        x = _id_holder(gui, o)
        isnothing(x) && continue
        id, uid = gui.sync.ids[x]
        push!(uids, uid)
        push!(ids, String(id))
    end
    return uids, ids
end

"""
    _write_presence!(gui; now = time())

Writes the presence file of the person of the `gui` (see `_person`, `_presence_file`) atomically:
its name and host, `kind = "person"`, `ttl = _ALIVE`, the `beat` one higher than in the file, the
selected object and `written`, the stamp of the files after the last save of the window (see
`_own_written`). Sets `gui.sync.beat_at` to `now`. Does nothing without a project. An error of
writing is no error: the file is written again with the next look. The watcher writes it in the
background instead, see `_presence_due!`.
"""
function _write_presence!(gui::LiveView; now::Real = time())
    dir = gui.project
    isnothing(dir) && return nothing
    _write_presence_file(dir, _presence_data(gui)) || (gui.sync.presence_due = true)
    gui.sync.beat_at = Float64(now)
    return nothing
end

"""
    _presence_data(gui) -> (; id, data, own)

What the presence file of the person of the `gui` holds, without `written`: the `id` of the
person, the fields `data` and `own`, the stamp of the own last save if the files are still those
(else `nothing`: the file keeps its `written`, see `_own_written`). Read on the thread of the
window, written by `_write_presence_file`, also in the background.
"""
function _presence_data(gui::LiveView)
    me = _person()
    uids, ids = _presence_selection(gui)
    uid, id = isempty(ids) ? ("", "") : (first(uids), first(ids))
    data = Dict{String, Any}("name" => me.name, "host" => me.host, "kind" => "person", "ttl" => _ALIVE,
        "selected" => uid, "selected_id" => id, "selected_uids" => uids, "selected_ids" => ids,
        "claimed" => _claimed_keys(gui))
    own = get(_OWN_SAVE, gui, nothing)
    return (; id = me.id, data, own = !isnothing(own) && own == gui.sync.stamp ? own : nothing)
end

# The keys of the lines whose objects the person of the `gui` claims, sorted, see `LiveProjectClaims.jl`
function _claimed_keys(gui::LiveView)
    c = gui.sync.claim
    return c isa _ClaimState ? sort!(collect(keys(c.held))) : String[]
end

"""
    _write_presence_file(dir, p) -> Bool

Writes the presence file of `_presence_data` `p` into the project folder `dir`. Returns whether it
was written: a write that fails on the file system (e.g. the file of a shared drive is busy, see
`BeamletOpticsProjects.write_presence`) is no error, the caller writes it again later.
"""
function _write_presence_file(dir::AbstractString, p)
    data = copy(p.data)
    try
        data["written"] = something(p.own, _file_written(_presence_file(dir, p.id)))
        BMOP.write_presence(dir, p.id, data)
    catch e
        (e isa Base.IOError || e isa SystemError) || rethrow()
        @debug "live_view: the presence file was not written" exception = e
        return false
    end
    return true
end

"""
    _presence_due!(gui, now) -> `_presence_data` or nothing

The presence file of the `gui` to be written by the next look of the watcher (see `_take_look!`):
when the selection changed or the window saved since the last write (`gui.sync.presence_due`) or
the last write is `_BEAT` seconds ago; `nothing` otherwise. Counts it as written at `now`.
"""
function _presence_due!(gui::LiveView, now::Real)
    s = gui.sync
    (s.presence_due || now - s.beat_at >= _BEAT) || return nothing
    s.presence_due = false
    s.beat_at = Float64(now)
    return _presence_data(gui)
end

# The `written` of the presence file `file`, `""` if it is missing, does not parse or has none
function _file_written(file::AbstractString)
    isfile(file) || return ""
    try
        w = get(TOML.parsefile(file), "written", "")
        return w isa AbstractString ? String(w) : ""
    catch
        return ""
    end
end

"""
    _own_written(gui, file) -> String

The stamp of the files that the window of the `gui` wrote last, for `written` of its presence file
`file`: `gui.sync.stamp` if the window wrote these files itself (`Ctrl+S`, the autosave, "save
as", see `_own_save!`); else the `written` of the file before is kept, so that the window never
claims files that it only opened, reloaded (`Ctrl+R`) or merged, e.g. the change of an other.
"""
_own_written(gui::LiveView, file::AbstractString) = something(_presence_data(gui).own, _file_written(file))

# Per view, the stamp of the files that its last save wrote, see `_own_written`
const _OWN_SAVE = WeakKeyDict{LiveView, String}()

"""
    _own_save!(gui, stamp)

Records that the window of the `gui` wrote the files of the project with the `stamp` itself, by a
save (`save_project`), such that its presence publishes it as `written` (see `_own_written`).
"""
function _own_save!(gui::LiveView, stamp)
    if isnothing(stamp)
        delete!(_OWN_SAVE, gui)
    else
        _OWN_SAVE[gui] = String(stamp)
    end
    return nothing
end

# Whether the other `o` (an entry of `gui.sync.others`) is there at the time `now`
_alive(o, now::Real) = BMOP.alive(o, now)

"""
    _check_presence!(gui; now = time(), look = nothing)

One look at the presence files of the project of the `gui`: takes the files of the others from the
`look` of the watcher (see `_take_look!`, which also writes the own file); without a `look`, writes
the own file if the last write is `_BEAT` seconds ago and reads the others here (never the own one; a file that does not
parse, e.g. half written on a network drive, is skipped and its participant kept as it was) and
updates `gui.sync.others`, people and agents alike. An other whose `beat` changed is seen at `now`;
one whose file is gone is dropped. One whose `beat` did not change for its `ttl` seconds stays in
`others` but is not shown, so that the file of a window that crashed or of an agent that did not
delete it does not come back. A merge whose status line says "agent" gets the name of the other
that published its stamp meanwhile (see `_name_writer!`). The claims go one step on (see
`_claims_tick!`: the own ones are written and those of the others read in the background). Then
the boxes and names of the
selections of the others are drawn again if what they show changed (see `_draw_presence!`). Does
nothing without a project.
"""
function _check_presence!(gui::LiveView; now::Real = time(), look = nothing)
    dir = gui.project
    isnothing(dir) && return nothing
    s = gui.sync
    if isnothing(look)
        now - s.beat_at >= _BEAT && _write_presence!(gui; now)
        look = _files_look(dir; stamp = false, except = _person().id, known = collect(keys(s.others)))
    end
    for (id, data) in look.presences
        beat = data["beat"]
        old = get(s.others, id, nothing)
        seen_at = isnothing(old) || old.beat != beat ? Float64(now) : old.seen_at
        s.others[id] = (; name = data["name"], kind = data["kind"], selected_uid = data["selected"],
            selected_id = data["selected_id"], selected_uids = _string_list(get(data, "selected_uids", nothing)),
            selected_ids = _string_list(get(data, "selected_ids", nothing)),
            doing = first(data["doing"], _DOING_CHARS), written = data["written"], ttl = data["ttl"], seen_at, beat)
    end
    # A file that is skipped (it does not parse) keeps its participant as it was; a file that is gone drops it
    for id in collect(keys(s.others))
        haskey(look.presences, id) && continue
        id in look.known && !(id in look.present) && delete!(s.others, id)
    end
    _name_writer!(gui, now)
    _claims_tick!(gui; now)
    _draw_presence!(gui, now)
    return nothing
end

# The object of the view with the machine id `uid`, `nothing` if it is not in the view
function _object_of_uid(gui::LiveView, uid::AbstractString)
    isempty(uid) && return nothing
    for (obj, (_, u)) in gui.sync.ids
        u == uid && return obj
    end
    return nothing
end

# The object of the view with the readable id `id` (e.g. "L1"), `nothing` if it is not in the view
function _object_of_id(gui::LiveView, id::AbstractString)
    isempty(id) && return nothing
    for (obj, (i, _)) in gui.sync.ids
        string(i) == id && return obj
    end
    return nothing
end

# The object the other `o` works on: by its uid, else by its readable id, else `nothing`
function _object_of_other(gui::LiveView, o)
    obj = _object_of_uid(gui, o.selected_uid)
    return isnothing(obj) ? _object_of_id(gui, o.selected_id) : obj
end

# The objects of the view that the other `o` has selected: those of a selection of several
# (`selected_uids`, `selected_ids` of its file, each by uid, else by readable id), else the one of
# `_object_of_other`
function _objects_of_other(gui::LiveView, o)
    isempty(o.selected_ids) && return (obj = _object_of_other(gui, o); isnothing(obj) ? Any[] : Any[obj])
    objs = Any[]
    for (i, id) in enumerate(o.selected_ids)
        uid = get(o.selected_uids, i, "")
        obj = something(_object_of_uid(gui, uid), _object_of_id(gui, id), Some(nothing))
        isnothing(obj) || _has(objs, obj) || push!(objs, obj)
    end
    return objs
end

# The strings of a list field of a presence file, `String[]` if it is missing or not a list
_string_list(x) = x isa AbstractVector ? String[s for s in x if s isa AbstractString] : String[]

# The label of the other `o`: its name, with what it is doing in a second line
_other_label(o) = isempty(o.doing) ? o.name : o.name * "\n" * o.doing

# What the overlay of the others shows at `now`, sorted by the id of the participant: per alive
# other with an object in the view the edges of the box of the object, the label and `false`; per
# object of the view that a participant claims (see `_claimed_objects`, also of one whose presence
# is not shown) the box, the label with "editing" and `true` for the lock
function _presence_shown(gui::LiveView, now::Real)
    shown = Tuple{Vector{Point3f}, String, Bool}[]
    claimed = _claimed_objects(gui)
    for id in sort!(unique!([collect(keys(gui.sync.others)); collect(keys(claimed))]))
        o = get(gui.sync.others, id, nothing)
        objs = get(claimed, id, Any[])
        if !isnothing(o) && _alive(o, now)
            # the name at the first object of a selection of several
            label = _other_label(o)
            for obj in _objects_of_other(gui, o)
                _has(objs, obj) && continue
                bb = _part_box(gui, obj)
                isnothing(bb) && continue
                push!(shown, (_bbox_wireframe(bb), label, false))
                label = ""
            end
        end
        for obj in objs
            bb = _part_box(gui, obj)
            isnothing(bb) || push!(shown, (_bbox_wireframe(bb), _claim_label(gui, id, o), true))
        end
    end
    return shown
end

# What the plots of the overlay show now, in the form of `_presence_shown`
function _presence_drawn(gui::LiveView)
    c = gui.sync.claim
    return c isa _ClaimState ? c.drawn : Tuple{Vector{Point3f}, String, Bool}[]
end

# The text of a label of the overlay (Makie keeps it as a vector of one string)
_label_text(p) = (t = p.text[]; String(t isa AbstractString ? t : only(t)))

"""
    _draw_presence!(gui, now)

Draws where the others of the `gui` (people and agents alike) are at `now` (see
`_check_presence!`): the box of the object each works on in `_OTHER_COLOR` and its name at the
upper corner, with what it is doing (`doing`) in a second line; overlays in `gui.sync.presence` (a
box and a label per other). An object that a participant claims (see `LiveProjectClaims.jl`) has a
lock at the corner (`gui.sync.claim.locks`) and "editing" after the name. Only an object of the view
is shown. Draws again only if the boxes or names changed; hidden in the spectator mode.
"""
function _draw_presence!(gui::LiveView, now::Real)
    s = gui.sync
    shown = _presence_shown(gui, now)
    visible = !gui.controls.spectator[]
    if shown != _presence_drawn(gui)
        _delete_presence!(gui)
        for (pts, name, locked) in shown
            box = linesegments!(gui.ax, pts; color = _OTHER_COLOR, linewidth = _OTHER_BOX_WIDTH, visible,
                clip_planes = Plane3f[], inspectable = false)
            # the name of a claimed object after its lock
            label = text!(gui.ax, maximum(pts); text = name, color = _OTHER_COLOR, fontsize = _OTHER_FONTSIZE,
                align = (:left, :bottom), offset = (locked ? 0.6 * _LOCK_SIZE : 0.0, 0.0), visible,
                clip_planes = Plane3f[], inspectable = false)
            push!(s.presence, box, label)
        end
        _draw_locks!(gui, shown, visible)
        append!(_claims(gui).drawn, shown)
    end
    for p in Iterators.flatten((s.presence, _presence_locks(gui)))
        p.visible[] == visible || (p.visible[] = visible)
    end
    return nothing
end

# The plots of the locks of the claimed objects, see `_draw_locks!`
_presence_locks(gui::LiveView) = (c = gui.sync.claim; c isa _ClaimState ? c.locks : Any[])

function _delete_presence!(gui::LiveView)
    _delete_locks!(gui)
    for p in gui.sync.presence
        try
            delete!(gui.ax, p)
        catch
        end
    end
    empty!(gui.sync.presence)
    return nothing
end

"""
    _presence_closed!(gui)

Removes the boxes and names of the others from the `gui`, releases the claims of its person (see
`_claims_closed!`) and deletes its own presence file, when the window is closed. A missing file is
fine.
"""
function _presence_closed!(gui::LiveView)
    _delete_presence!(gui)
    _claims_closed!(gui)
    empty!(gui.sync.others)
    isnothing(gui.project) || rm(_presence_file(gui.project, _person().id); force = true)
    return nothing
end

# Per view, the stamp of the files of the last merge whose writer `_writer` did not find, see
# `_name_writer!`
const _UNNAMED = WeakKeyDict{LiveView, String}()

# The start of the status line of a merge whose writer was not found
const _UNNAMED_PREFIX = "agent: "

"""
    _writer(gui, stamp) -> Union{Nothing, String}

The name of the participant of the `gui` (an other person or an agent, alike) who is there now and
wrote the files with the stamp `stamp` (`written` of its presence file), else `nothing` (the status
then says "agent"). Called once per merge. An agent publishes the stamp of its write with
`BeamletOpticsProjects.announce(...; wrote = true)`, often only after the window merged it: a merge
whose writer is not found is therefore remembered, and `_name_writer!` names the writer in the
status line once its stamp arrives.
"""
function _writer(gui::LiveView, stamp; now::Real = time())
    name = _writer_of(gui, stamp, now)
    if isnothing(name) && !isnothing(stamp) && !isempty(stamp)
        _UNNAMED[gui] = String(stamp)
    else
        delete!(_UNNAMED, gui)
    end
    return name
end

# The name of the other of the `gui` that is there at `now` and whose `written` is `stamp`, else `nothing`
function _writer_of(gui::LiveView, stamp, now::Real)
    (isnothing(stamp) || isempty(stamp)) && return nothing
    for id in sort!(collect(keys(gui.sync.others)))
        o = gui.sync.others[id]
        _alive(o, now) && o.written == stamp && return o.name
    end
    return nothing
end

"""
    _name_writer!(gui, now)

Names the writer of the last merge of the `gui` whose writer `_writer` did not find, once an other
that is there at `now` published the stamp of its files: the status line of that merge,
`"agent: …"`, becomes `"<name>: …"`. The merge is forgotten once it is named, or once the files or
the status line are no longer those of a merge (a save, a new merge, another message). The status
line is only checked for its start: a merge that changed nothing in the window keeps the status line
`"agent: …"` of a merge before it, which is then named after the writer of the later files.
"""
function _name_writer!(gui::LiveView, now::Real)
    stamp = get(_UNNAMED, gui, nothing)
    isnothing(stamp) && return nothing
    text = gui.status.text[]
    if gui.sync.stamp != stamp || !startswith(text, _UNNAMED_PREFIX)
        delete!(_UNNAMED, gui)
        return nothing
    end
    name = _writer_of(gui, stamp, now)
    isnothing(name) && return nothing
    gui.status.text[] = name * ": " * text[(ncodeunits(_UNNAMED_PREFIX) + 1):end]
    delete!(_UNNAMED, gui)
    return nothing
end
