#=
Several participants on one project, e.g. on a shared drive: the open windows of people and the
coding agents that change the files. Each participant has a presence file
`.bmo/presence-<id>.toml`; a window writes its own and shows where the others are (see
plans/projects-people.md).

The file holds the name and host of the participant, its `kind` (`"person"` for a window, `"agent"`
for a coding agent; default `"person"`), a counter `beat` that grows with every write, `ttl` (the
seconds that a beat counts; windows write `_ALIVE`, agents e.g. 600, since they write only when
they act), the object it works on (`selected`: its uid, `selected_id`: its readable id; `""` if
nothing; the readable id counts when the uid is missing or unknown, an agent writes only that),
optionally `doing` (a few words, shown under the name) and the stamp of the files after its last
save (`written`). A window writes its file when it saves, when its selection changes and every
`_BEAT` seconds. It reads the files of the others at every look of the watcher: an other is there
while its `beat` changed within its `ttl` seconds of the clock of this machine, so the clocks of
the machines are never compared. People and agents are shown alike: a box at their object and
their name.
=#

# How often a window writes its presence file at least [s]
const _BEAT = 20.0
# How long an other is shown after its `beat` last changed [s]: the `ttl` of a window and the
# default of a file without one; the `ttl` of a file is clamped to `_TTL_RANGE`
const _ALIVE = 60.0
const _TTL_RANGE = (5.0, 3600.0)
# At most this many characters of `doing` are shown
const _DOING_CHARS = 80
# The color of the boxes and names of the others: the green of Julia, not the accent of the themes
# (the selection, the boxes of the parts), not the purple of the clip planes or the orange of aiming
const _OTHER_COLOR = RGBf(0.22, 0.596, 0.149)
const _OTHER_BOX_WIDTH = 2
const _OTHER_FONTSIZE = 14

"""
    _person() -> (; id, name, host)

The person of this window: `name` from `ENV["BMO_PERSON"]`, else the user name of the system
(`USERNAME`, `USER`), else `"someone"`; `host` the name of the machine; `id` is `"name@host"` with
every character outside `[A-Za-z0-9_.@-]` replaced by `_`, for the names of the files of the person
in `.bmo/`.
"""
function _person()
    name = get(ENV, "BMO_PERSON", get(ENV, "USERNAME", get(ENV, "USER", "someone")))
    isempty(strip(name)) && (name = "someone")
    host = gethostname()
    id = replace("$name@$host", r"[^A-Za-z0-9_.@-]" => "_")
    return (; id, name = String(name), host = String(host))
end

"""The presence file of the person `id` in the project folder `dir`."""
_presence_file(dir::AbstractString, id::AbstractString) = joinpath(dir, ".bmo", "presence-$id.toml")

# The id of the person of a presence file name, `nothing` for other files
function _presence_id(name::AbstractString)
    m = match(r"^presence-(.+)\.toml$", name)
    return isnothing(m) ? nothing : String(m.captures[1])
end

"""The machine id and the readable id of the selected object of the `gui`, `("", "")` if none."""
function _presence_selected(gui::LiveView)
    sel = gui.controls.selected[]
    isnothing(sel) && return ("", "")
    chain = try
        _chain(gui.controls, sel)
    catch
        Any[sel]
    end
    for x in chain
        haskey(gui.sync.ids, x) || continue
        id, uid = gui.sync.ids[x]
        return (uid, String(id))
    end
    return ("", "")
end

# The `beat` of the presence file `file`, 0 if it is missing or does not parse: a window that is
# opened again continues the counter, so that the others see a change
function _file_beat(file::AbstractString)
    isfile(file) || return 0
    try
        b = get(TOML.parsefile(file), "beat", 0)
        return b isa Integer ? Int(b) : 0
    catch
        return 0
    end
end

"""
    _write_presence!(gui; now = time())

Writes the presence file of the person of the `gui` (see `_person`, `_presence_file`) atomically:
its name and host, `kind = "person"`, `ttl = _ALIVE`, the `beat` one higher than in the file, the
selected object and the stamp of the files after the last save (`gui.sync.stamp`). Sets `gui.sync.beat_at` to `now`. Does nothing
without a project. An error of writing propagates; the watcher logs it.
"""
function _write_presence!(gui::LiveView; now::Real = time())
    dir = gui.project
    isnothing(dir) && return nothing
    me = _person()
    file = _presence_file(dir, me.id)
    uid, id = _presence_selected(gui)
    data = Dict{String, Any}("name" => me.name, "host" => me.host, "kind" => "person", "ttl" => _ALIVE,
        "beat" => _file_beat(file) + 1, "selected" => uid, "selected_id" => id, "written" => something(gui.sync.stamp, ""))
    mkpath(dirname(file))
    tmp = file * ".tmp"
    open(io -> TOML.print(io, data; sorted = true), tmp, "w")
    mv(tmp, file; force = true)
    gui.sync.beat_at = Float64(now)
    return nothing
end

# Whether the other `o` (an entry of `gui.sync.others`) is there at the time `now`
_alive(o, now::Real) = now - o.seen_at < o.ttl

# The `ttl` of a presence file: a positive real clamped to `_TTL_RANGE`, else `_ALIVE`
function _presence_ttl(x)
    (x isa Real && isfinite(x) && x > 0) || return _ALIVE
    return clamp(Float64(x), _TTL_RANGE...)
end

# A string field of a presence file, `""` if it is missing or not a string
_presence_string(data, key) = (x = get(data, key, ""); x isa AbstractString ? String(x) : "")

"""
    _check_presence!(gui; now = time())

One look at the presence files of the project of the `gui`: writes the own file if the last write
is `_BEAT` seconds ago, reads the files of the others (never the own one; a file that does not
parse, e.g. half written on a network drive, is skipped and its participant kept as it was) and
updates `gui.sync.others`, people and agents alike. An other whose `beat` changed is seen at `now`;
one whose file is gone is dropped. One whose `beat` did not change for its `ttl` seconds stays in
`others` but is not shown, so that the file of a window that crashed or of an agent that did not
delete it does not come back. Then the boxes and names of the
selections of the others are drawn again if what they show changed (see `_draw_presence!`). Does
nothing without a project.
"""
function _check_presence!(gui::LiveView; now::Real = time())
    dir = gui.project
    isnothing(dir) && return nothing
    s = gui.sync
    now - s.beat_at >= _BEAT && _write_presence!(gui; now)
    me = _person().id
    bmo = joinpath(dir, ".bmo")
    names = isdir(bmo) ? readdir(bmo) : String[]
    found = Set{String}()
    for name in names
        id = _presence_id(name)
        (isnothing(id) || id == me) && continue
        push!(found, id)
        data = try
            TOML.parsefile(joinpath(bmo, name))
        catch
            continue
        end
        beat = get(data, "beat", nothing)
        beat isa Integer || continue
        old = get(s.others, id, nothing)
        seen_at = isnothing(old) || old.beat != beat ? Float64(now) : old.seen_at
        name = _presence_string(data, "name")
        kind = _presence_string(data, "kind")
        s.others[id] = (; name = isempty(name) ? id : name, kind = isempty(kind) ? "person" : kind,
            selected_uid = _presence_string(data, "selected"), selected_id = _presence_string(data, "selected_id"),
            doing = first(_presence_string(data, "doing"), _DOING_CHARS), written = _presence_string(data, "written"),
            ttl = _presence_ttl(get(data, "ttl", nothing)), seen_at, beat = Int(beat))
    end
    for id in collect(keys(s.others))
        id in found || delete!(s.others, id)
    end
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

# The label of the other `o`: its name, with what it is doing in a second line
_other_label(o) = isempty(o.doing) ? o.name : o.name * "\n" * o.doing

# What the overlay of the others shows at `now`: per alive other with an object in the view the
# edges of the box of the object and the label, sorted by the id of the participant
function _presence_shown(gui::LiveView, now::Real)
    shown = Tuple{Vector{Point3f}, String}[]
    for id in sort!(collect(keys(gui.sync.others)))
        o = gui.sync.others[id]
        _alive(o, now) || continue
        obj = _object_of_other(gui, o)
        isnothing(obj) && continue
        bb = _part_box(gui, obj)
        isnothing(bb) && continue
        push!(shown, (_bbox_wireframe(bb), _other_label(o)))
    end
    return shown
end

# What the plots of the overlay show now, in the form of `_presence_shown`
function _presence_drawn(gui::LiveView)
    p = gui.sync.presence
    return [(Vector{Point3f}(p[i][1][]), _label_text(p[i + 1])) for i in 1:2:(length(p) - 1)]
end

# The text of a label of the overlay (Makie keeps it as a vector of one string)
_label_text(p) = (t = p.text[]; String(t isa AbstractString ? t : only(t)))

"""
    _draw_presence!(gui, now)

Draws where the others of the `gui` (people and agents alike) are at `now` (see
`_check_presence!`): the box of the object each works on in `_OTHER_COLOR` and its name at the
upper corner, with what it is doing (`doing`) in a second line; overlays in `gui.sync.presence` (a
box and a label per other). Only an object of the view is shown.
Draws again only if the boxes or names changed; hidden in the spectator mode.
"""
function _draw_presence!(gui::LiveView, now::Real)
    s = gui.sync
    shown = _presence_shown(gui, now)
    visible = !gui.controls.spectator[]
    if shown != _presence_drawn(gui)
        _delete_presence!(gui)
        for (pts, name) in shown
            box = linesegments!(gui.ax, pts; color = _OTHER_COLOR, linewidth = _OTHER_BOX_WIDTH, visible,
                clip_planes = Plane3f[], inspectable = false)
            label = text!(gui.ax, maximum(pts); text = name, color = _OTHER_COLOR, fontsize = _OTHER_FONTSIZE,
                align = (:left, :bottom), visible, clip_planes = Plane3f[], inspectable = false)
            push!(s.presence, box, label)
        end
    end
    for p in s.presence
        p.visible[] == visible || (p.visible[] = visible)
    end
    return nothing
end

function _delete_presence!(gui::LiveView)
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

Removes the boxes and names of the others from the `gui` and deletes its own presence file, when
the window is closed. A missing file is fine.
"""
function _presence_closed!(gui::LiveView)
    _delete_presence!(gui)
    empty!(gui.sync.others)
    isnothing(gui.project) || rm(_presence_file(gui.project, _person().id); force = true)
    return nothing
end

"""
    _writer(gui, stamp) -> Union{Nothing, String}

The name of the participant of the `gui` (an other person or an agent) who is there now and wrote
the files with the stamp `stamp` (`written` of its presence file). Else, if exactly one participant
that is there is an agent (`kind = "agent"`), its name, since an agent need not write `written`.
Else `nothing` (the status then says "agent").
"""
function _writer(gui::LiveView, stamp; now::Real = time())
    (isnothing(stamp) || isempty(stamp)) && return nothing
    others = [gui.sync.others[id] for id in sort!(collect(keys(gui.sync.others)))]
    filter!(o -> _alive(o, now), others)
    for o in others
        o.written == stamp && return o.name
    end
    agents = filter(o -> o.kind == "agent", others)
    return length(agents) == 1 ? only(agents).name : nothing
end
