#=
Claims of the people in a window of a project: whoever edits an object holds its claim, and the
others do not change it meanwhile (see `BeamletOpticsProjects.claim!`). The window of a person
claims an object implicitly, with the first gesture that changes it (a drag, a key step, an input
on a card, "Apply" of the page "Edit", grouping), and releases it when it is deselected or
`_CLAIM_HOLD` seconds after the last gesture. A gesture on an object that another participant
claims is refused, and the status line names the holder. The claims of the others are drawn at
their objects with the boxes and names of the presence (see `_draw_presence!`): a lock and
"editing".

No file is touched in the handlers of the mouse and the keys: they look up the claims of the others
in the cache of the last read and queue the own ones; the file work runs in a task of its own,
started by `_claims_tick!` at every look of the watcher (see `_check_presence!`).
=#

# How long a person holds the claim of an object after the last gesture on it [s] (D3)
const _CLAIM_HOLD = 30.0
# How often the claims of the others are read at least [s]
const _CLAIM_READ = 0.5
# The lock drawn at an object claimed by an other [px]
const _LOCK_SIZE = 16
# The text of an object claimed by an other, after the name of the holder
const _EDITING = " · editing"

# The lock, "lock" of Material Symbols (outlined, weight 400, grade 0, optical size 24) by Google,
# Apache License 2.0, see `LiveIcons.jl`
const _LOCK_ICON = _svg_path("M240-80q-33 0-56.5-23.5T160-160v-400q0-33 23.5-56.5T240-640h40v-80q0-83 " *
    "58.5-141.5T480-920q83 0 141.5 58.5T680-720v80h40q33 0 56.5 23.5T800-560v400q0 33-23.5 56.5T720-80H240Zm0-80h480v-400H240v400Zm240-120q33 " *
    "0 56.5-23.5T560-360q0-33-23.5-56.5T480-440q-33 0-56.5 23.5T400-360q0 33 23.5 56.5T480-280ZM360-640h240v-80q0-50-35-85t-85-35q-50 " *
    "0-85 35t-35 85v80Z")

# The claims of others, by the key of their line (the machine id, else "id:L1")
const _ClaimMap = Dict{String, @NamedTuple{by::String, id::Symbol}}

"""
    _ClaimState

The claims of the person of a view and of the others, `gui.sync.claim` (see `_claims`):
- `held`: the objects that the person holds or is about to hold, by the key of their line (the
  machine id, else `"id:L1"`) => readable id; `filed` those that the claim files have after the
  last run of `_claim_files`;
- `gesture_at`: the time of the last gesture that claimed (`_CLAIM_HOLD`);
- `others`: the claims of the other participants at the last read, by key (`BeamletOpticsProjects.claims`);
- `task`: the run of the file work in the background, `run_at` the time it started, `dirty`
  whether the claims of the person changed since;
- `drawn`: what the overlay of the presence shows (`_presence_shown`), `locks` the plots of the
  locks of the claimed objects;
- `last_error`: the last error of the file work, logged once.
"""
Base.@kwdef mutable struct _ClaimState
    held::Dict{String, Symbol} = Dict{String, Symbol}()
    filed::Dict{String, Symbol} = Dict{String, Symbol}()
    gesture_at::Float64 = -Inf
    others::_ClaimMap = _ClaimMap()
    task::Union{Nothing, Task} = nothing
    run_at::Float64 = -Inf
    dirty::Bool = false
    drawn::Vector{Tuple{Vector{Point3f}, String, Bool}} = Tuple{Vector{Point3f}, String, Bool}[]
    locks::Vector{Any} = Any[]
    last_error::String = ""
end

"""The claims of the `gui`, see `_ClaimState`; created at the first use."""
function _claims(gui::LiveView)
    c = gui.sync.claim
    c isa _ClaimState && return c
    c = _ClaimState()
    gui.sync.claim = c
    return c
end

# The participant id of the holder `by` of a claim, as in its presence file: as given if it has a
# host (`"anna@pc2"`), else an agent (`"w1@agent"`), see `BeamletOpticsProjects.claim!`
_holder_pid(by::AbstractString) = occursin('@', by) ? String(by) : string(by, "@agent")

# The name of the holder `by` of a claim: of its presence, else its id without the host
function _holder_name(gui::LiveView, by::AbstractString)
    o = get(gui.sync.others, _holder_pid(by), nothing)
    isnothing(o) || return String(o.name)
    return String(first(split(by, '@')))
end

# The innermost item with an id of the project that holds `x` (e.g. the component of a selected
# part of it, see `_presence_selected`), `nothing` if none
function _id_holder(gui::LiveView, @nospecialize(x))
    chain = try
        _chain(gui.controls, x)
    catch
        Any[x]
    end
    for y in chain
        haskey(gui.sync.ids, y) && return y
    end
    return nothing
end

"""
    _claim_objects(gui, sel) -> Vector{Any}

The objects of the project that a gesture on the selection `sel` of the `gui` (an object, a
selection of several, a vector of objects or `nothing`) claims (D2): per object the innermost item
with an id that holds it (else the object itself), and the objects with an id of a group,
recursively.
"""
function _claim_objects(gui::LiveView, @nospecialize(sel))
    out = Any[]
    xs = sel isa AbstractVector ? sel : _selection_objects(sel)
    for x in xs
        # a group without an id yet, e.g. one just made in the window: its members
        _with_members!(out, gui, something(_id_holder(gui, x), x))
    end
    return out
end

# Adds `x` if it has an id and the members of a group `x` (recursively) to `out`
function _with_members!(out, gui::LiveView, @nospecialize(x))
    (haskey(gui.sync.ids, x) && !_has(out, x)) && push!(out, x)
    if x isa BMO.AbstractObjectGroup
        for m in BMO.objects(x)
            _with_members!(out, gui, m)
        end
    end
    return out
end

# The key of the line of the object `x` of the project: its machine id, else "id:<readable id>"
function _claim_key(gui::LiveView, @nospecialize(x))
    id, uid = gui.sync.ids[x]
    return isempty(uid) ? "id:" * String(id) : uid
end

"""
    _claim_keys(gui, sel) -> Dict{String, Symbol}

The keys of the lines (see `_claim_key`) of the objects that a gesture on `sel` claims (see
`_claim_objects`) => their readable ids.
"""
_claim_keys(gui::LiveView, @nospecialize(sel)) =
    Dict{String, Symbol}(_claim_key(gui, x) => gui.sync.ids[x][1] for x in _claim_objects(gui, sel))

# The claim of an other on the object `x` of the project, `nothing` if none
function _other_claim(gui::LiveView, @nospecialize(x))
    others = _claims(gui).others
    isempty(others) && return nothing
    id, uid = gui.sync.ids[x]
    c = isempty(uid) ? nothing : get(others, uid, nothing)
    return isnothing(c) ? get(others, "id:" * String(id), nothing) : c
end

"""
    _claimed_by(gui, obj) -> Union{Nothing, String}

The name of the participant other than the person of the `gui` who claims `obj` or an object that
a gesture on it claims (see `_claim_objects`), at the last read of the claims (no file access);
`nothing` if none.
"""
function _claimed_by(gui::LiveView, @nospecialize(obj))
    r = _claim_holder(gui, obj)
    return isnothing(r) ? nothing : r.name
end

# The name of the holder and the readable id of the first object of a gesture on `sel` that an
# other claims, `nothing` if none
function _claim_holder(gui::LiveView, @nospecialize(sel))
    (isnothing(gui.project) || isempty(_claims(gui).others)) && return nothing
    for x in _claim_objects(gui, sel)
        c = _other_claim(gui, x)
        isnothing(c) && continue
        return (; name = _holder_name(gui, c.by), id = gui.sync.ids[x][1])
    end
    return nothing
end

"""
    _claim_refusal(gui, sel) -> Union{Nothing, String}

Why a gesture on the selection `sel` of the `gui` is refused, for the status line: an object of it
is claimed by another participant (`"Anna is editing L1"`), see `_claimed_by`; `nothing` if it is
not. Reads only the cache of the claims, never a file.
"""
function _claim_refusal(gui::LiveView, @nospecialize(sel))
    r = _claim_holder(gui, sel)
    return isnothing(r) ? nothing : "$(r.name) is editing $(r.id)"
end

"""
    _gesture!(gui, sel; now = time()) -> Bool

The start of a gesture of the person on the selection `sel` of the `gui` that changes it (a drag, a
key step, an undo onto it, an input on a card, see `gesture` of `KinematicController`): `false` with
the reason in the status line if an object of it is claimed by another participant (see
`_claim_refusal`), else `true`, and the objects are claimed (see `_claim!`). Without a project, every
gesture is allowed and nothing is claimed.
"""
function _gesture!(gui::LiveView, @nospecialize(sel); now::Real = time())
    isnothing(gui.project) && return true
    reason = _claim_refusal(gui, sel)
    if !isnothing(reason)
        gui.status.text[] = reason
        return false
    end
    _claim!(gui, sel; now)
    return true
end

"""
    _claim!(gui, sel; now = time())

Claims the objects that a gesture on `sel` claims (see `_claim_objects`) for the person of the
`gui`, from `now` on: they are queued, and the next run of `_claims_tick!` writes the claim files
in the background. Each gesture holds them `_CLAIM_HOLD` seconds longer. Does nothing without a
project.
"""
function _claim!(gui::LiveView, @nospecialize(sel); now::Real = time())
    isnothing(gui.project) && return nothing
    _hold!(gui, _claim_keys(gui, sel); now)
    return nothing
end

"""
    _hold!(gui, keys; now = time())

Adds the claims `keys` (key => readable id, see `_claim_keys`) to those that the person of the
`gui` holds, see `_claim!`; e.g. of an object that a gesture replaces by another (see
`_apply_edit!`).
"""
function _hold!(gui::LiveView, keys::AbstractDict; now::Real = time())
    (isnothing(gui.project) || isempty(keys)) && return nothing
    c = _claims(gui)
    c.gesture_at = Float64(now)
    changed = false
    for (k, id) in keys
        get(c.held, k, nothing) === id && continue
        c.held[k] = id
        changed = true
    end
    changed && _claims_changed!(gui)
    return nothing
end

# The claims of the person changed: written by the next run, published in the presence
function _claims_changed!(gui::LiveView)
    _claims(gui).dirty = true
    gui.sync.presence_due = true
    return nothing
end

"""
    _release!(gui; keep = nothing)

Releases the claims of the person of the `gui`, all of them or those not in `keep` (keys of
lines): queued like `_claim!`. Called when the selection changes (see `_claims_selected!`) and
`_CLAIM_HOLD` seconds after the last gesture (see `_claims_tick!`).
"""
function _release!(gui::LiveView; keep = nothing)
    c = _claims(gui)
    isempty(c.held) && return nothing
    n = length(c.held)
    isnothing(keep) ? empty!(c.held) : filter!(p -> p.first in keep, c.held)
    length(c.held) == n || _claims_changed!(gui)
    return nothing
end

"""
    _claims_selected!(gui)

The selection of the `gui` changed: the claims of the objects that are no longer selected are
released (D3), those of the new selection are kept, e.g. of the members of a group that was just
made of them.
"""
function _claims_selected!(gui::LiveView)
    c = gui.sync.claim
    (c isa _ClaimState && !isempty(c.held)) || return nothing
    _release!(gui; keep = keys(_claim_keys(gui, gui.controls.selected[])))
    return nothing
end

"""
    _connect_claims!(gui)

Connects the claims to the controls of the `gui`: every gesture asks `_gesture!` (`gesture` of the
`KinematicController`), and a change of the selection releases the claims of what is no longer
selected, see `_claims_selected!`.
"""
function _connect_claims!(gui::LiveView)
    ctrl = gui.controls
    ctrl.gesture = function (obj)
        @nospecialize obj
        return _gesture!(gui, obj)
    end
    push!(ctrl.listeners, on(ctrl.selected) do _
        _claims_selected!(gui)
        return nothing
    end)
    return nothing
end

"""
    _claim_files(dir, by, want, filed) -> (; filed, refused, others)

The file work of the claims of the participant `by` in the project folder `dir`, in the background
(see `_claims_tick!`): releases the claims of `filed` (key => readable id) that are not in `want`
(all of `by` if `want` is empty), claims those of `want` that are not filed yet, and reads the
claims of the others. Returns the claims now in the files (`filed`), the readable ids that another
participant held (`refused`, none of them was claimed then) and the claims of the others.
Touches no state of a window.
"""
function _claim_files(dir::AbstractString, by::AbstractString, want::Dict{String, Symbol},
        filed::Dict{String, Symbol})
    filed = copy(filed)
    drop = [k for k in keys(filed) if !haskey(want, k)]
    if !isempty(drop)
        if isempty(want)
            BMOP.release!(dir; by)
        else
            BMOP.release!(dir; by, ids = unique!([filed[k] for k in drop]))
        end
        foreach(k -> delete!(filed, k), drop)
    end
    add = [k for k in keys(want) if !haskey(filed, k)]
    refused = Symbol[]
    if !isempty(add)
        ids = unique!([want[k] for k in add])
        if BMOP.claim!(dir; by, ids)
            foreach(k -> (filed[k] = want[k]), add)
        else
            refused = ids
        end
    end
    others = _ClaimMap()
    for (k, c) in BMOP.claims(dir)
        c.by == by || (others[k] = c)
    end
    return (; filed, refused, others)
end

# The file work of the claims, see `_claim_files`; a `Ref` so that the tests can see where it runs
const _CLAIM_FILES = Ref{Function}(_claim_files)

"""
    _claims_tick!(gui; now = time())

One step of the claims of the `gui`, at every look of the watcher (see `_check_presence!`): takes
the result of the file work that ran in the background (see `_claim_files`): the claims of the
others and, if another participant held an object first, the status line `"Anna is editing L1"`;
releases the claims `_CLAIM_HOLD` seconds after the last gesture; then starts the next run if the
claims of the person changed or the last one is `_CLAIM_READ` seconds ago. Returns the task of
the run that it started, else `nothing`. Does nothing without a project.
"""
function _claims_tick!(gui::LiveView; now::Real = time())
    dir = gui.project
    isnothing(dir) && return nothing
    c = _claims(gui)
    t = c.task
    if !isnothing(t)
        istaskdone(t) || return nothing
        c.task = nothing
        try
            r = fetch(t)
            c.filed = r.filed
            c.others = r.others
            if !isempty(r.refused)
                filter!(p -> !(p.second in r.refused), c.held)
                gui.sync.presence_due = true
                gui.status.text[] = _refused_text(gui, r.refused)
            end
            c.last_error = ""
        catch e
            e isa InterruptException && rethrow()
            err = e isa TaskFailedException ? e.task.exception : e
            c.last_error = _log_once(err, c.last_error, "claiming the objects of the project")
            c.dirty = true
        end
    end
    !isempty(c.held) && now - c.gesture_at >= _CLAIM_HOLD && _release!(gui)
    (c.dirty || c.held != c.filed || now - c.run_at >= _CLAIM_READ) || return nothing
    c.dirty = false
    c.run_at = Float64(now)
    by = _person().id
    want = copy(c.held)
    filed = copy(c.filed)
    f = _CLAIM_FILES[]
    c.task = Threads.@spawn f(dir, by, want, filed)
    return c.task
end

# The status line of the readable ids `ids` that another participant claimed first
function _refused_text(gui::LiveView, ids)
    for id in ids
        for (k, c) in _claims(gui).others
            c.id == id && return "$(_holder_name(gui, c.by)) is editing $id"
        end
    end
    return "$(join(ids, ", ")) is claimed by another participant"
end

"""
    _claims_closed!(gui)

Releases the claims of the person of the `gui` when its window is closed (see
`_presence_closed!`), after the run in the background is done.
"""
function _claims_closed!(gui::LiveView)
    c = gui.sync.claim
    c isa _ClaimState || return nothing
    t = c.task
    c.task = nothing
    if !isnothing(t)
        try
            r = fetch(t)
            c.filed = r.filed
        catch
        end
    end
    had = !isempty(c.filed) || !isempty(c.held)
    empty!(c.held)
    empty!(c.filed)
    empty!(c.others)
    (had && !isnothing(gui.project)) && BMOP.release!(gui.project; by = _person().id)
    return nothing
end

# The object of the view of the claim `c` with the key `k`, `nothing` if it is not in the view
function _object_of_claim(gui::LiveView, k::AbstractString, c)
    obj = startswith(k, "id:") ? nothing : _object_of_uid(gui, k)
    return isnothing(obj) ? _object_of_id(gui, String(c.id)) : obj
end

"""
    _claimed_objects(gui) -> Dict{String, Vector{Any}}

The objects of the view that the others claim, by the participant id of the holder (see
`_holder_pid`), sorted by their readable ids: only the outermost of a group whose members are
claimed by the same holder, since the box of the group holds them.
"""
function _claimed_objects(gui::LiveView)
    out = Dict{String, Vector{Any}}()
    c = gui.sync.claim
    c isa _ClaimState || return out
    for k in sort!(collect(keys(c.others)))
        cl = c.others[k]
        obj = _object_of_claim(gui, k, cl)
        isnothing(obj) && continue
        objs = get!(out, _holder_pid(cl.by), Any[])
        _has(objs, obj) || push!(objs, obj)
    end
    for (pid, objs) in out
        inner = filter(objs) do o
            chain = try
                _chain(gui.controls, o)
            catch
                Any[o]
            end
            return any(p -> p !== o && _has(objs, p), chain)
        end
        filter!(o -> !_has(inner, o), objs)
        sort!(objs; by = o -> String(gui.sync.ids[o][1]))
    end
    return out
end

# The label of an object that the holder `pid` claims (`o` its presence, or `nothing`)
function _claim_label(gui::LiveView, pid::AbstractString, o)
    name = isnothing(o) ? String(first(split(pid, '@'))) : String(o.name)
    text = name * _EDITING
    return isnothing(o) || isempty(o.doing) ? text : text * "\n" * o.doing
end

# Draws the locks at the claimed objects of `shown` (see `_presence_shown`), after the boxes
function _draw_locks!(gui::LiveView, shown, visible::Bool)
    c = _claims(gui)
    for (pts, _, locked) in shown
        locked || continue
        lock = scatter!(gui.ax, [maximum(pts)]; marker = _LOCK_ICON, markersize = _LOCK_SIZE,
            color = _OTHER_COLOR, markerspace = :pixel, visible, clip_planes = Plane3f[],
            inspectable = false)
        push!(c.locks, lock)
    end
    return nothing
end

function _delete_locks!(gui::LiveView)
    c = gui.sync.claim
    c isa _ClaimState || return nothing
    for p in c.locks
        try
            delete!(gui.ax, p)
        catch
        end
    end
    empty!(c.locks)
    empty!(c.drawn)
    return nothing
end
