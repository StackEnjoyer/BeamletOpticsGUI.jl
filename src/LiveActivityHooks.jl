#=
The activity of the others in a window of a project: the episodes of the merges of their changes
and of their messages, and the step per frame that draws the cues (`LiveActivityCues.jl`) and the
timeline (`LiveTimeline.jl`), see `LiveActivity.jl` and `plans/activity-cues.md`.
=#

"""
    _merge_snapshot(gui, take) -> Dict{String, Any}

What the objects of the `gui` at the keys `take` (of a merge, see `_sync!`) are before the merge
applies the files: their pose and the wireframe of their box, by key.
"""
function _merge_snapshot(gui::LiveView, take)
    out = Dict{String, Any}()
    for k in take
        obj = _object_of_key(gui, String(k))
        (isnothing(obj) || obj isa BMO.AbstractSystem) && continue
        bb = _part_box(gui, obj)
        pose = try
            _pose(obj)
        catch
            continue
        end
        out[String(k)] = (; pose = (Vector{Float64}(pose[1]), Matrix{Float64}(pose[2])),
            frame = isnothing(bb) ? Point3f[] : _bbox_wireframe(bb))
    end
    return out
end

# The angle [°] between the orientations `R0` and `R1`
_turned(R0, R1) = rad2deg(acos(clamp((sum(R0 .* R1) - 1) / 2, -1.0, 1.0)))

# The readable id of the line of key `k` in the project `p`, or `nothing`
function _id_of_key(p, k::String)
    for x in Iterators.flatten((p.entries, p.groups, p.systems))
        _key(x) == k && return x.name
    end
    return nothing
end

"""
    _merge_items(gui, before, mine, disk, take) -> (items, text)

The items of the episode of a merge: per key of `take` an `_ActivityItem` with the kind of the
change, the pose `before` (of `_merge_snapshot`) and after (of the object of the files), and the
frame of its box at the new place; and the text of the episode ("moved M2 by 12 mm, added L3").
"""
function _merge_items(gui::LiveView, before, mine, disk, take)
    items = _ActivityItem[]
    words = String[]
    for k in sort!(String.(collect(take)))
        id = something(_id_of_key(disk, k), _id_of_key(mine, k), Symbol(k))
        b = get(before, k, nothing)
        obj = _object_of_key(gui, k)
        if obj isa BMO.AbstractSystem || (isnothing(obj) && isnothing(b))
            # a system or a group line: in the text only
            any(s -> _key(s) == k, disk.systems) && push!(words, "changed $id")
            continue
        end
        if isnothing(obj)
            push!(items, _ActivityItem(k, id, :removed, b.pose, nothing, b.frame))
            push!(words, "removed $id")
            continue
        end
        e = findfirst(x -> _key(x) == k, disk.entries)
        after = if isnothing(e) || isnothing(disk.entries[e].object)
            p = _pose(obj)
            (Vector{Float64}(p[1]), Matrix{Float64}(p[2]))
        else
            o = disk.entries[e].object
            (Vector{Float64}(position(o)), Matrix{Float64}(BMO.orientation(o)))
        end
        if isnothing(b)
            bb = _part_box(gui, obj)
            push!(items, _ActivityItem(k, id, :added, nothing, after, isnothing(bb) ? Point3f[] : _bbox_wireframe(bb)))
            push!(words, "added $id")
            continue
        end
        d = after[1] .- b.pose[1]
        frame = Point3f[p + Point3f(d...) for p in b.frame]
        dist = sqrt(sum(abs2, d))
        angle = _turned(b.pose[2], after[2])
        change, word = if dist > 1e-9
            :moved, "moved $id by " * _mm_text(dist)
        elseif angle > 1e-6
            :rotated, "rotated $id by " * _short_number(angle) * "°"
        else
            :changed, "changed $id"
        end
        push!(items, _ActivityItem(k, id, change, b.pose, after, frame))
        push!(words, word)
    end
    return items, join(words, ", ")
end

# A distance [m] as a short text in mm or µm
_mm_text(d) = d >= 1e-3 ? _short_number(1e3 * d) * " mm" : _short_number(1e6 * d) * " µm"

# A number with one decimal below 10 and none above, without a trailing ".0"
function _short_number(v)
    r = round(v; digits = v < 10 ? 1 : 0)
    return isinteger(r) ? string(Int(r)) : string(r)
end

"""
    _writer_participant(gui, stamp; now = time()) -> (; who, name, agent)

The participant who wrote the files with the `stamp` (see `_writer`): its presence id, name and
whether it is an agent; an unnamed agent if none is found.
"""
function _writer_participant(gui::LiveView, stamp; now::Real = time())
    if !(isnothing(stamp) || isempty(stamp))
        for id in sort!(collect(keys(gui.sync.others)))
            o = gui.sync.others[id]
            _alive(o, now) && o.written == stamp && return (; who = id, name = String(o.name), agent = o.kind != "person")
        end
    end
    return (; who = "agent", name = "agent", agent = true)
end

"""
    _record_merge!(gui, before, mine, disk, take; now = time())

Records the episode of a merge of the files of another participant into the `gui` (see `_sync!`):
`before` the snapshot of the objects before the merge (see `_merge_snapshot`). Nothing for a merge
that changed nothing in the window.
"""
function _record_merge!(gui::LiveView, before, mine, disk, take; now::Real = time())
    isempty(take) && return nothing
    items, text = _merge_items(gui, before, mine, disk, take)
    isempty(text) && return nothing
    w = _writer_participant(gui, disk.stamp; now)
    ep = _record_episode!(gui, w.who, w.name, w.agent, items; text, now)
    stamp = something(disk.stamp, "")
    # The writer publishes the stamp of its files often only after the merge, see `_name_episode!`
    _activity(gui).unnamed = w.who == "agent" && !isempty(stamp) ? (ep.n, String(stamp)) : nothing
    return nothing
end

"""
    _name_episode!(gui; now = time())

Gives the episode of the last merge whose writer was not known (see `_record_merge!`) the writer,
once an other that is there published the stamp of those files (as `_name_writer!` does for the
status line). The cue that already plays keeps its name; the timeline shows the new one.
"""
function _name_episode!(gui::LiveView; now::Real = time())
    a = gui.activity
    (a isa _Activity && !isnothing(a.unnamed)) || return nothing
    n, stamp = a.unnamed
    w = _writer_participant(gui, stamp; now)
    w.who == "agent" && return nothing
    a.unnamed = nothing
    i = findfirst(e -> e.n == n, a.episodes)
    isnothing(i) && return nothing
    e = a.episodes[i]
    a.episodes[i] = _Episode(e.n, w.who, w.name, w.agent, e.t, e.items, e.text, e.message, e.count)
    return nothing
end

# The texts of `doing` that a write of an agent sets itself (`_announce_wrote` of
# BeamletOpticsProjects): no message of the agent, the merge is its episode
const _WRITE_DOINGS = ("added ", "moved ", "changed ", "copied ", "removed ", "put ", "took ")

"""
    _record_message!(gui, id, o; old = nothing, now = time())

Records a message of the other participant `id` (its presence `o`) if its `doing` is new and not the
note of one of its writes (see `_WRITE_DOINGS`): an agent says what it does next. People's windows
write no `doing`.
"""
function _record_message!(gui::LiveView, id::AbstractString, o; old = nothing, now::Real = time())
    doing = strip(String(o.doing))
    (isempty(doing) || (!isnothing(old) && String(old.doing) == o.doing)) && return nothing
    any(p -> startswith(doing, p), _WRITE_DOINGS) && return nothing
    items = _ActivityItem[]
    obj = isempty(o.selected_id) ? nothing : _object_of_id(gui, o.selected_id)
    if !isnothing(obj)
        bb = _part_box(gui, obj)
        p = _pose(obj)
        pose = (Vector{Float64}(p[1]), Matrix{Float64}(p[2]))
        push!(items, _ActivityItem(String(o.selected_uid), Symbol(o.selected_id), :changed, pose, pose,
            isnothing(bb) ? Point3f[] : _bbox_wireframe(bb)))
    end
    _record_episode!(gui, id, String(o.name), o.kind != "person", items; text = doing,
        message = doing, now)
    return nothing
end

"""
    _activity_tick!(gui)

The step per frame of the activity of the others in the `gui` (a watched window of a project, see
`_start_watching!`): builds the timeline once an other was there, draws the cues at their pace
(see `_activity_step!`), shows a mark that the mouse is over again as a cue, the ghosts of the
scrub, and moves the camera to a participant that is followed. Nothing before the first episode.
"""
function _activity_tick!(gui::LiveView)
    a = gui.activity
    a isa _Activity || return nothing
    now = time()
    a.seen && isnothing(a.strip) && _timeline!(gui)
    # a mark under the mouse plays its cue, once per mark
    hover = a.hover
    if hover != a.shown_hover
        isnothing(hover) || _replay!(gui, hover; now)
    end
    _draw_cues!(gui, _activity_step!(gui, now), now)
    if a.cursor != a.shown_cursor
        _draw_scrub!(gui, isnothing(a.cursor) ? nothing : _poses_at(gui, a.cursor))
    end
    a.shown_hover, a.shown_cursor = hover, a.cursor
    if !isnothing(a.strip)
        _update_timeline!(gui, now)
        # the toast of the compact layout stands above the timeline while it is shown
        tl = a.strip
        top = tl.shown ? maximum(tl.rect)[2] - minimum(gui.ax.scene.viewport[])[2] - _OVERLAY_MARGIN + 6 : 0
        _lift_toast!(gui, top)
    end
    target = _follow_target(gui, now)
    isnothing(target) || _frame_points!(gui, target)
    return nothing
end

