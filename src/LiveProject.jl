#=
Projects: saving a view to a project folder and opening one (see BeamletOpticsProjects). The setup
is `system.jl` of the folder, written and read by BeamletOpticsProjects; how the view looks (camera,
saved views, clip planes, table, the colors of the beams, ...) is `.bmo/view-<person>.toml`, one per
person, which the GUI writes and reads itself; `view.toml` of the folder is only the default for a
person without a file.
=#

const BMOP = BeamletOpticsProjects

# The default view of the folder of a project; the view of a person is `_view_file`
const _VIEW_TOML = "view.toml"

# The keys of saving and opening, in the help of the controls, see `_help_sections`
const _PROJECT_HELP = _HelpSection["Edit" => [
    _HelpEntry([_ctrl_cap(), "S"], "save a version"; combo = true),
    _HelpEntry([_ctrl_cap(), "Shift", "S"], "save as a new project with a name"; combo = true),
    _HelpEntry([_ctrl_cap(), "O"], "open a project (.bmo)"; combo = true),
    _HelpEntry([_ctrl_cap(), "R"], "reload the project from its files"; combo = true)]]

# The filter of the dialogs: the project files, see `BeamletOpticsProjects.project_marker`
const _BMO_FILTER = "bmo"

"""
The dialog of "Save as", `folder -> path`: the user goes to a folder and types a name; `""` (or
`nothing`) if it was cancelled. The native dialog of NativeFileDialog, replaced by the tests.
"""
const _SAVE_DIALOG = Ref{Any}(dir -> NativeFileDialog.save_file(dir; filterlist = _BMO_FILTER))

"""
The dialog of "Open", `folder -> path` of a project file `*.bmo`; `""` (or `nothing`) if it was
cancelled. The native dialog of NativeFileDialog, replaced by the tests.
"""
const _OPEN_DIALOG = Ref{Any}(dir -> NativeFileDialog.pick_file(dir; filterlist = _BMO_FILTER))

# The task of the last dialog of `Ctrl+S` or `Ctrl+O`, which runs after the key callback returned
const _DIALOG_TASK = Ref{Any}(nothing)

#=
Names
=#

"""Whether `s` can be the name of an entry or a system of a project: a free variable name."""
_is_project_name(s::AbstractString) = _is_variable_name(s) && !_is_taken_name(s) &&
                                      !Base.isexported(BMOP, Symbol(s))

"""
    _project_ids(gui, items) -> IdDict{Any, Tuple{Symbol, String}}

The readable id and the machine id of the objects, sources, groups and systems `items` of the `gui`
in a project: those it has in `gui.sync.ids` (see `_ProjectSync`), else a new id of the prefix of its
type (see `BeamletOpticsProjects.id_prefix` and `next_id`) and a new uid. Every id in
`gui.sync.ids` is reserved first, also of an item later in `items` or of an object that is not in
the view anymore, such that a new one never takes it: after `L5` the next lens is `L6`. An id or a
uid that an item before took already is given anew, an empty uid too.
"""
function _project_ids(gui::LiveView, items)
    known = gui.sync.ids
    out = IdDict{Any, Tuple{Symbol, String}}()
    # The ids that are taken, as systems of a project for `next_id`
    taken = BMOP.Project(pwd(), "taken")
    reserve!(id) = (push!(taken.systems, BMOP.SystemEntry(id, Symbol[])); id)
    foreach(k -> reserve!(first(k)), values(known))
    used = Set{Symbol}()
    uids = Set{String}()
    for x in items
        k = get(known, x, nothing)
        (isnothing(k) || first(k) in used) && continue
        id, uid = k
        (isempty(uid) || uid in uids) && (uid = BMOP.new_uid())
        push!(used, id)
        push!(uids, uid)
        out[x] = (id, uid)
    end
    for x in items
        haskey(out, x) && continue
        prefix = BMOP.id_prefix(x)
        id = BMOP.next_id(taken, prefix)
        while !_is_project_name(String(id))
            reserve!(id)
            id = BMOP.next_id(taken, prefix)
        end
        reserve!(id)
        k = get(known, x, nothing)
        uid = isnothing(k) || isempty(last(k)) || last(k) in uids ? BMOP.new_uid() : last(k)
        push!(uids, uid)
        out[x] = (id, uid)
    end
    return out
end

"""
The `label` of an entry of `x` with the readable `id`: the label of `x` in the `gui` (see
`_ProjectSync`) if it has one and it is not the id, else `nothing`. The automatic names of the tree
(e.g. "Lens 2") are no labels.
"""
function _project_label(gui::LiveView, @nospecialize(x), id::Symbol)
    label = get(gui.labels, x, nothing)
    return (isnothing(label) || label == String(id)) ? nothing : String(label)
end

"""
    _file_order(base, entries, systems, groups) -> (entries, systems, groups)

The `entries`, `systems` and `groups` of a project in the order of the project `base` (the state
that the view and the files last agreed on, see `_ProjectSync`): each by the place of the entry,
system or group of the same uid in `base`, else of the same readable id; the others after those, in
their order. `system_code` writes the components before the sources and the inner groups before the
groups that hold them, so a new one is written at the end of its kind. Without `base`, as they are.
"""
function _file_order(base, entries, systems, groups)
    isnothing(base) && return entries, systems, groups
    function order(xs, old)
        by_uid = Dict{String, Int}()
        by_name = Dict{Symbol, Int}()
        for (i, o) in enumerate(old)
            isnothing(o.uid) || get!(by_uid, o.uid, i)
            get!(by_name, o.name, i)
        end
        # The uid of a line of an agent is given in the view, the file has none yet
        place(x) = !isnothing(x.uid) && haskey(by_uid, x.uid) ? by_uid[x.uid] :
                   get(by_name, x.name, typemax(Int))
        return xs[sortperm([place(x) for x in xs]; alg = Base.Sort.DEFAULT_STABLE)]
    end
    return order(entries, base.entries), order(systems, base.systems), order(groups, base.groups)
end

#=
Collecting a project from a view
=#

_entry_kind(::_Source) = :source
_entry_kind(@nospecialize(x)) = :component

_static_system(::BMO.StaticSystem) = true
_static_system(@nospecialize(sys)) = false

"""
    _project_pose(x, origin) -> (pos, rot)

The `pos` and `rot` of the entry of the object or source `x` with its `origin`: those of the entry
of the project that it was opened from (the `project` of its origin, see `_project_origin`) while
it is in the pose that it was loaded in, such that the text of an unmoved entry stays as it was;
otherwise its position and the rotation `Δ = R * R0'` since its pose `R0` as constructed, `nothing`
for the identity within `1e-13`.
"""
function _project_pose(@nospecialize(x), origin)
    P, R = _pose(x)
    rec = get(origin, :project, nothing)
    if !isnothing(rec) && P == rec.pose[1] && maximum(abs, R - rec.pose[2]) <= 1e-12
        return rec.pos, rec.rot
    end
    Δ = Matrix{Float64}(R * origin.pose0[2]')
    rot = maximum(abs, Δ - I) <= 1e-13 ? nothing : Δ
    return (Float64(P[1]), Float64(P[2]), Float64(P[3])), rot
end

"""
The `meta` of the entry of an object with the `origin`: that of the entry it was opened from, and
`:catalog => (name, strings)` of a component or source of the catalog, which the page "Edit" needs.
"""
function _project_meta(origin)
    rec = get(origin, :project, nothing)
    meta = isnothing(rec) ? Pair{Symbol, Any}[] : Pair{Symbol, Any}[m for m in rec.meta]
    if haskey(origin, :entry) && haskey(origin, :strings)
        cat = :catalog => (String(origin.entry.name), String[origin.strings...])
        i = findfirst(m -> first(m) === :catalog, meta)
        isnothing(i) ? push!(meta, cat) : (meta[i] = cat)
    end
    return meta
end

"""
    _group_pose(gui, g, uid) -> (pos, rot)

The `pos` and `rot` of the `@group` line of the group `g` made in the window with the machine id
`uid`: those of the group of that uid in the `base` of the sync (see `_ProjectSync`) while `g` has
that pivot and orientation, such that the text of an unmoved group stays as it was; otherwise its
position and its orientation, `nothing` for the identity within `1e-13`.
"""
function _group_pose(gui::LiveView, @nospecialize(g), uid)
    P = Vector{Float64}(position(g))
    R = Matrix{Float64}(BMO.orientation(g))
    base = gui.sync.base
    if !isnothing(base)
        i = findfirst(e -> e.uid == uid, base.groups)
        if !isnothing(i)
            e = base.groups[i]
            collect(e.pos) == P && maximum(abs, R - BMOP.rotation_matrix(e.rot)) <= 1e-12 &&
                return e.pos, e.rot
        end
    end
    rot = maximum(abs, R - I) <= 1e-13 ? nothing : R
    return (P[1], P[2], P[3]), rot
end

"""
    _collect_saved!(gui, x, saved, groups, members, skipped) -> Bool

Collects the object or source `x` of the `gui` for `_project_parts` and returns whether it is
saved: a group made in the window (see `gui.components.groups`) with those of its members that are
saved, in their order (`members[x]`), after its inner groups in `groups`, unless none of them is
saved; any other with a known constructor in `saved`; else its label in `skipped`.
"""
function _collect_saved!(gui::LiveView, @nospecialize(x), saved, groups, members, skipped)
    comp = gui.components
    if haskey(comp.groups, x)
        ms = Any[]
        for m in BMO.objects(x)
            _collect_saved!(gui, m, saved, groups, members, skipped) && push!(ms, m)
        end
        isempty(ms) && return false
        members[x] = ms
        push!(groups, x)
        return true
    end
    if isnothing(get(comp.origin, x, nothing))
        push!(skipped, _label(gui, x))
        return false
    end
    push!(saved, x)
    return true
end

"""
    _project_parts(gui, dir; name = project_name(dir)) -> (; project, names, ids, skipped)

The `project` of the `gui` in the folder `dir` with the module `name` (see `_collect_project`), the
readable ids (`names`) and the readable and machine `ids` of its objects, sources, groups and
systems (see `_project_ids`) and the labels of the objects and sources that were `skipped`, since
their constructor is not known.

A group made in the window (see `_group!`) is a `@group` of its members that are saved, with its
pivot and orientation (see `_group_pose`); each member is an entry or a group of its own, at its
absolute pose, and the systems list the group, not its members. A group of the script without a
constructor is skipped like any such object.
"""
function _project_parts(gui::LiveView, dir::AbstractString; name::AbstractString = BMOP.project_name(dir))
    comp = gui.components
    # A system without members and sources that has no name, e.g. the one of an empty view
    systems = Any[sys for sys in _systems(gui)
                  if !(isempty(sys.objects) && isempty(_sources_of(gui, sys)) && !haskey(gui.labels, sys))]
    # Without the objects of the `extras` kwarg, which have no system at the start
    start = comp.start_systems
    free = Any[obj for obj in rendered(gui.extras).objects if !isempty(get(start, obj, Any[nothing]))]
    objects = unique(objectid, Any[(obj for sys in systems for obj in sys.objects)..., free...])
    sources = unique(objectid, Any[(src for sys in systems for src in _sources_of(gui, sys))...,
        (src for src in _sources(gui) if isempty(_snapshot(gui, src).systems))...])
    skipped = String[]
    saved = Any[]
    groups = Any[]
    members = IdDict{Any, Vector{Any}}()
    for x in Any[objects..., sources...]
        _collect_saved!(gui, x, saved, groups, members, skipped)
    end
    ids = _project_ids(gui, Any[saved..., groups..., systems...])
    names = IdDict{Any, Symbol}(x => first(v) for (x, v) in ids)
    entries = BMOP.Entry[]
    for x in saved
        origin = comp.origin[x]
        pos, rot = _project_pose(x, origin)
        P0, R0 = origin.pose0
        id, uid = ids[x]
        push!(entries, BMOP.Entry(_entry_kind(x), id, Meta.parse(origin.code), x; pos, rot,
            pose0 = (Vector{Float64}(P0), Matrix{Float64}(R0)), meta = _project_meta(origin),
            label = _project_label(gui, x, id), uid))
    end
    group_entries = BMOP.GroupEntry[]
    for g in groups
        id, uid = ids[g]
        pos, rot = _group_pose(gui, g, uid)
        push!(group_entries, BMOP.GroupEntry(id, Symbol[names[m] for m in members[g]]; pos, rot,
            object = g, label = _project_label(gui, g, id), uid))
    end
    is_saved = Base.IdSet{Any}(Any[saved..., groups...])
    system_entries = BMOP.SystemEntry[BMOP.SystemEntry(names[sys],
        Symbol[names[obj] for obj in sys.objects if obj in is_saved],
        Symbol[names[src] for src in _sources_of(gui, sys) if src in is_saved];
        static = _static_system(sys), object = sys, label = _project_label(gui, sys, names[sys]),
        uid = last(ids[sys])) for sys in systems]
    entries, system_entries, group_entries = _file_order(gui.sync.base, entries, system_entries,
        group_entries)
    project = BMOP.Project(dir, name; entries, systems = system_entries, groups = group_entries)
    return (; project, names, ids, skipped)
end

"""
    _collect_project(gui, dir) -> Project

The setup of the `gui` as a project in the folder `dir`: its systems (`System` or `StaticSystem`)
with their members and sources, the objects and sources without a system (not those of the
`extras` kwarg), each object once, also one of several systems. Each is an entry with its
constructor call and its pose, see `_project_pose`; one whose constructor is not known (see the
`origin` of `_ComponentState`) is left out. A group made in the window is a `@group` of its
members, see `_project_parts`. The inputs of the page "Edit" that are not applied are
ignored.
"""
_collect_project(gui::LiveView, dir::AbstractString) = _project_parts(gui, dir).project

"""The packages whose versions a new project pins: BeamletOptics, the projects, the GUI, GLMakie."""
function _project_packages()
    mods = Module[BMO, BMOP, @__MODULE__]
    glmakie = Base.PkgId(Base.UUID("e9467ef8-e4e7-5192-8a1a-b1aee30e663a"), "GLMakie")
    m = get(Base.loaded_modules, glmakie, nothing)
    isnothing(m) || push!(mods, m)
    return mods
end

"""
    _apply_project_names!(gui, project; skip = String[])

Writes the readable ids and the machine ids of the entries, groups and systems of the saved `project` into
`gui.sync.ids` (see `_ProjectSync`), such that the next save gives the same ones; the uids that
`BeamletOpticsProjects.save_project` gave are those of the entries in `project`. Not those of the
keys `skip` (the objects of an open conflict, whose lines hold the files' state). The labels of the
`gui` stay as they are.
"""
function _apply_project_names!(gui::LiveView, project; skip = String[])
    ids = gui.sync.ids
    for e in Iterators.flatten((project.entries, project.systems, project.groups))
        (isnothing(e.object) || _key(e) in skip) && continue
        ids[e.object] = (e.name, something(e.uid, BMOP.new_uid()))
    end
    return nothing
end

"""
    _move_id!(gui, old, new)

Gives the readable id and the machine id of `old` to `new`, which takes its place in the `gui`,
e.g. on the page "Edit" (see `_replace!`): the project sees the same entry with other code.
"""
function _move_id!(gui::LiveView, @nospecialize(old), @nospecialize(new))
    ids = gui.sync.ids
    k = get(ids, old, nothing)
    isnothing(k) && return nothing
    delete!(ids, old)
    ids[new] = k
    return nothing
end

#=
.bmo/view-<person>.toml (default: view.toml)
=#

# The color of a beam in view.toml: "wavelength" or "#rrggbb"; `nothing` for any other
function _toml_color(color)
    _by_wavelength(color) && return "wavelength"
    c = _single_color(color)
    return isnothing(c) ? nothing : _color_hex(c)
end
_toml_color_value(s::AbstractString) = s == "wavelength" ? :wavelength : RGBf(Makie.to_color(s))

"""
    _view_dict(gui, names) -> Dict

What the view file holds of the `gui`: the `camera`, the saved `views`, the `clip_planes` and
`clip_beams`, the `table`, `auto_trace`, `orthographic`, `show_sources`, `snap`, per source (by its
name in `names`) the `color`, `alpha` and `linewidth` of its beam, and the sources that are off.
"""
function _view_dict(gui::LiveView, names)
    eye, lookat, up = _current_view(gui)
    d = Dict{String, Any}(
        "camera" => Dict{String, Any}("eye" => eye, "lookat" => lookat, "up" => up),
        "views" => [Dict{String, Any}("name" => name, "eye" => v[1], "lookat" => v[2], "up" => v[3])
                    for (name, v) in gui.camera.views],
        "clip_planes" => [Dict{String, Any}("pos" => Vector{Float64}(collect(p.pos)),
            "normal" => Vector{Float64}(_normal(p))) for p in gui.clip.planes],
        "clip_beams" => gui.clip.beams,
        "auto_trace" => gui.trace.auto[],
        "orthographic" => gui.widgets.orthographic_toggle.active[],
        "show_sources" => gui.widgets.sources_toggle.active[],
        "snap" => String(gui.controls.snap[]))
    table = _table_kwarg(gui.components.table)
    table === false || (d["table"] = Dict{String, Any}(String(k) => v for (k, v) in pairs(table) if !isnothing(v)))
    beams = Dict{String, Any}()
    off = String[]
    for src in _sources(gui)
        name = get(names, src, nothing)
        isnothing(name) && continue
        kw = _snapshot(gui, src).kwargs
        b = Dict{String, Any}()
        if haskey(kw, :color)
            c = _toml_color(kw.color)
            isnothing(c) || (b["color"] = c)
        end
        haskey(kw, :alpha) && (b["alpha"] = Float64(kw.alpha))
        haskey(kw, :linewidth) && (b["linewidth"] = Float64(kw.linewidth))
        isempty(b) || (beams[String(name)] = b)
        src in gui.beams.off && push!(off, String(name))
    end
    d["beams"] = beams
    d["beams_off"] = off
    return d
end

"""The view file of the person of this window in the folder `dir`: `.bmo/view-<id>.toml`."""
_view_file(dir) = joinpath(dir, ".bmo", "view-$(_person().id).toml")

# Writes `text` to `path` atomically
function _put_atomic(path::AbstractString, text::AbstractString)
    mkpath(dirname(path))
    tmp = path * ".tmp"
    write(tmp, text)
    mv(tmp, path; force = true)
    return nothing
end

"""
Writes the view of the `gui` to `.bmo/view-<id>.toml` of the person, in the folder of the `project`,
with the `names` of its sources. `view.toml` in the folder is written only if it does not exist: it is
the default for a person who has no view file yet.
"""
function _write_view_toml(gui::LiveView, project, names)
    path = _view_file(project.path)
    text = sprint(io -> TOML.print(io, _view_dict(gui, names); sorted = true))
    _put_atomic(path, text)
    default = BMOP.project_file(project, _VIEW_TOML)
    isfile(default) || _put_atomic(default, text)
    return path
end

"""The view of the person in the `project` (`.bmo/view-<id>.toml`), else `view.toml`, else an empty `Dict`."""
function _read_view(project)
    for path in (_view_file(project.path), BMOP.project_file(project, _VIEW_TOML))
        isfile(path) && return TOML.parsefile(path)
    end
    return Dict{String, Any}()
end

_view_tuple(d) = (Vector{Float64}(d["eye"]), Vector{Float64}(d["lookat"]), Vector{Float64}(d["up"]))

"""
    _view_kwargs(view, byname, paired) -> (kwargs, beam_kwargs, off)

The kwargs of `live_view` from the `view` (of the view file), with the objects of the project by name
in `byname`; `paired` are the sources of the pairs of the view. Also the `beam_kwargs` per source and
the sources that are `off`, of which those without a system are set after `live_view`.
"""
function _view_kwargs(view::AbstractDict, byname, paired)
    kw = Dict{Symbol, Any}()
    haskey(view, "views") && (kw[:views] = [String(v["name"]) => _view_tuple(v) for v in view["views"]])
    haskey(view, "clip_planes") &&
        (kw[:clip_planes] = [Vector{Float64}(c["pos"]) => Vector{Float64}(c["normal"]) for c in view["clip_planes"]])
    for key in ("clip_beams", "auto_trace", "orthographic", "show_sources")
        haskey(view, key) && (kw[Symbol(key)] = Bool(view[key]))
    end
    haskey(view, "snap") && (kw[:snap] = Symbol(view["snap"]))
    haskey(view, "table") && (kw[:table] = (; (Symbol(k) => v for (k, v) in view["table"])...))
    beam_kwargs = IdDict{Any, Any}()
    for (name, b) in get(view, "beams", Dict{String, Any}())
        src = get(byname, Symbol(name), nothing)
        isnothing(src) && continue
        nt = (;)
        haskey(b, "color") && (nt = merge(nt, (; color = _toml_color_value(b["color"]))))
        haskey(b, "alpha") && (nt = merge(nt, (; alpha = Float64(b["alpha"]))))
        haskey(b, "linewidth") && (nt = merge(nt, (; linewidth = Float64(b["linewidth"]))))
        beam_kwargs[src] = nt
    end
    off = Any[byname[Symbol(n)] for n in get(view, "beams_off", String[]) if haskey(byname, Symbol(n))]
    kw[:beam_kwargs] = IdDict{Any, Any}(src => nt for (src, nt) in beam_kwargs if src in paired)
    kw[:beams_off] = Tuple(src for src in off if src in paired)
    return (; kwargs = (; kw...), beam_kwargs, off)
end

#=
Opening a project
=#

# A literal of `meta` as a value: tuples and vectors of an expression become values
_literal(x) = x
_literal(ex::Expr) = ex.head === :tuple ? Tuple(_literal.(ex.args)) :
                     ex.head === :vect ? Any[_literal.(ex.args)...] : ex

# The code of an entry as a string on one line
_code_string(@nospecialize(code)) = string(BMOP.normalize_code(code))

"""
    _project_catalog(gui, entry) -> Union{Nothing, NamedTuple}

The entry of the catalog of the `gui` and the `strings` of its form that the `:catalog` of the
`meta` of the project `entry` names, if they build the same code as the entry has; `nothing`
otherwise, e.g. for an entry that an agent changed: then it can not be edited on the page "Edit".
"""
function _project_catalog(gui::LiveView, e)
    i = findfirst(m -> first(m) === :catalog, e.meta)
    isnothing(i) && return nothing
    v = _literal(last(e.meta[i]))
    (v isa Union{Tuple, AbstractVector} && length(v) == 2) || return nothing
    name, strings = v
    strings = _literal(strings)
    (name isa AbstractString && strings isa Union{Tuple, AbstractVector} &&
     all(s -> s isa AbstractString, strings)) || return nothing
    j = findfirst(c -> c.name == name, gui.components.catalog)
    isnothing(j) && return nothing
    entry = gui.components.catalog[j]
    built = try
        _catalog_component(entry, String[strings...])
    catch err
        err isa InterruptException && rethrow()
        return nothing
    end
    same = try
        Meta.parse(built.origin.code) == Meta.parse(_code_string(e.code))
    catch
        false
    end
    return same ? (; entry, strings = String[strings...]) : nothing
end

"""
    _project_origin(gui, entry) -> NamedTuple

The `origin` (see `_ComponentState`) of the object of the project `entry`: its `code` and `pose0`,
and `project`, the `name`, `pos`, `rot` and `meta` of the entry and the `pose` that the object was
loaded in, from which `_project_pose` tells whether it moved; of a component of the catalog also
its `entry` and `strings` (see `_project_catalog`).
"""
function _project_origin(gui::LiveView, e)
    P0, R0 = e.pose0
    origin = (; code = _code_string(e.code), pose0 = (Point3{Float64}(P0), Matrix{Float64}(R0)),
        project = (; e.name, e.pos, e.rot, meta = Pair{Symbol, Any}[e.meta...], pose = _pose(e.object)))
    cat = _project_catalog(gui, e)
    return isnothing(cat) ? origin : merge(origin, cat)
end

# Adds an object or source of the project without a system to the `gui`
function _add_loose!(gui::LiveView, src::_Source, label, origin, beam_kwargs)
    add_component!(gui, src; system = :none, select = false, label, origin,
        beam_kwargs = get(beam_kwargs, src, (;)))
    return nothing
end
function _add_loose!(gui::LiveView, @nospecialize(obj), label, origin, beam_kwargs)
    add_component!(gui, obj; system = :none, select = false, label, origin)
    return nothing
end

"""
    _open_from(project; kwargs...) -> LiveView

The live view of a loaded `project` (see `BeamletOpticsProjects.load_project`), without showing it:
its systems with their sources, a `System()` for a project without systems, the objects and
sources without a system, their labels (else their readable ids), their ids and uids (see
`_ProjectSync`), the origins of the objects (their code, with which they are saved again and, from
the catalog, edited and copied), and the view file of the person (`.bmo/view-<person>.toml`, else `view.toml`). The `kwargs` of `live_view` win over those of
the view file. The `project` becomes the `base` of the sync.

The groups of the project (`@group`, built by `BeamletOpticsProjects`) become groups made in the
window (see `_group!`), which `Ctrl+Shift+G` ungroups: an outermost group is a top-level object of
its systems or without a system, its members are no top-level objects.
"""
function _open_from(project; view = _read_view(project), kwargs...)
    @nospecialize
    byname = Dict{Symbol, Any}(e.name => e.object for e in project.entries)
    # The entries and groups inside a group: only their outermost group is a top-level object
    grouped = Set{Symbol}(m for g in project.groups for m in g.members)
    in_system = Set{Symbol}()
    args = Any[]
    for s in project.systems
        union!(in_system, s.members, s.sources)
        sources = Any[byname[n] for n in s.sources]
        isempty(sources) ? push!(args, s.object) : append!(args, Any[s.object => src for src in sources])
    end
    isempty(args) && push!(args, BMO.System())
    paired = Base.IdSet{Any}(a.second for a in args if a isa Pair)
    # The label of each, else its readable id
    labels = IdDict{Any, String}()
    for e in Iterators.flatten((project.entries, project.systems, project.groups))
        labels[e.object] = something(e.label, String(e.name))
    end
    vk = _view_kwargs(view, byname, paired)
    gui = live_view(args...; labels, vk.kwargs..., kwargs...)
    # The readable id and the uid of each; a line of an agent without a uid gets one, which the
    # next save writes (`diff_projects` pairs it with its line by the readable id meanwhile)
    for e in Iterators.flatten((project.entries, project.systems, project.groups))
        gui.sync.ids[e.object] = (e.name, something(e.uid, BMOP.new_uid()))
    end
    origins = IdDict{Any, Any}(e.object => _project_origin(gui, e) for e in project.entries)
    # The groups are groups made in the window, also before they are added without a system (see
    # `_record_units`); they have no origin, see `_regroup_reason`
    comp = gui.components
    for g in project.groups
        comp.groups[g.object] = _current_record(g.object)
    end
    _unrecorded(gui) do
        for e in project.entries
            (e.name in in_system || e.name in grouped) && continue
            _add_loose!(gui, e.object, labels[e.object], origins[e.object], vk.beam_kwargs)
        end
        for g in project.groups
            (g.name in in_system || g.name in grouped) && continue
            _add_loose!(gui, g.object, labels[g.object], nothing, vk.beam_kwargs)
        end
        for src in vk.off
            src in paired || _set_beam_on!(gui, src, false)
        end
    end
    for (obj, origin) in origins
        comp.origin[obj] = origin
    end
    foreach(g -> (comp.origin[g.object] = nothing), project.groups)
    empty!(gui.controls.undo_stack)
    empty!(gui.controls.redo_stack)
    if haskey(view, "camera")
        set_view(gui.ax, _view_tuple(view["camera"])...)
    end
    gui.project = project.path
    # What `Ctrl+S` and the watcher compare with, see `_ProjectSync`
    _saved!(gui, project)
    gui.status.text[] = "project $(project.name) opened from $(project.path)"
    return gui
end

"""
    open_project(path; display = true, kwargs...) -> LiveView

Opens the project in the folder `path`, or of its project file `path` (`<name>.bmo`), see
`BeamletOpticsProjects.load_project`, in a live view
and shows it if `display` is `true`: its systems with their sources, the objects and sources
without a system, their labels (else their ids) and how the view looked when it was saved
(`.bmo/view-<person>.toml` of the person, else `view.toml`: camera, saved views, clip planes,
table, the colors of the beams, ...). The `kwargs` are those of [`live_view`](@ref) and win over
the view file. While it is shown, the window writes
every finished change of the person to the files (autosave), applies the changes that others make
to them (an agent or the window of another person), notes the selection and the recent changes
of the person in `.bmo/session-<person>.md` and shows where the others work (see
`LiveProjectPresence.jl`). `Ctrl+S` saves a version of the project (a git commit with a message), see
[`save_project`](@ref). The components and sources from the catalog can be edited and copied.
`Ctrl+O` or the tool "Open" of a window opens a project chosen in a dialog and closes the window.
"""
function open_project(path::AbstractString; display::Bool = true, kwargs...)
    project = BMOP.load_project(path)
    gui = _open_from(project; kwargs...)
    if display
        title = basename(project.path)
        _multi_light_backend() ? Base.display(gui; title) : Base.display(gui)
        _start_watching!(gui)
    end
    return gui
end

#=
Saving
=#

"""
    _set_title!(gui, title)

Sets the title of the window of the `gui`, e.g. to the name of the folder of its project after
"Save as". Nothing if the `gui` is not shown or its backend has no window titles: the method per
backend is `_set_screen_title!(screen, title)`, of GLMakie in its extension.
"""
function _set_title!(gui::LiveView, title::AbstractString)
    _set_screen_title!(Makie.getscreen(gui.fig.scene), String(title))
    return nothing
end

"""Sets the title of the window of the `screen` of a backend, see `_set_title!`; nothing by default."""
_set_screen_title!(@nospecialize(screen), ::String) = nothing

"""
    save_project(gui::LiveView, dir = gui.project) -> String

Saves the setup of the live view `gui` as the project in the folder `dir` and returns the path of
its `system.jl`: each system with its members and sources, the objects and sources without a
system, each with its constructor call and its pose, see `BeamletOpticsProjects`. A folder that is
not a project yet becomes one, with the versions of BeamletOptics, BeamletOpticsProjects,
BeamletOpticsGUI and GLMakie. How the view looks is written to `.bmo/view-<person>.toml` (per person; `view.toml` only as the default of new people). An object whose
constructor is not known, e.g. one that the script gave to `live_view`, is not saved: a warning and
the status line name it. Each object, source and system keeps its readable id (e.g. `L1`) and its
machine id (uid) across saves; a new one gets the next free id of its kind and a new uid, and its
label in the view, if it has one, is saved as its `label`. The entries stay in the order of the
file, new ones at the end of their kind. `dir` becomes the project of the view, which the autosave
of its window and `Ctrl+S` save to, and the title of its window. `Ctrl+Shift+S` asks for a place and
a name, see `_save_as_key!`.

A shown window saves itself: every finished change of the person is written to the files (see
`_autosave!`) and noted in `.bmo/session-<person>.md`. `Ctrl+S` writes what is still pending and then saves a
version of the project, a git commit whose message the card of the version asks for (see
`_save_key!`).

Saving a view that has a project to another folder ("save as") copies the own code of the project
(`src/`) there first, without overwriting a file, and keeps the name of its module, such that the
copy loads. A shown window removes its session and presence files from the old folder.

Throws `BeamletOpticsProjects.ProjectChanged` and saves nothing if the files of the project of the
view changed since it opened or saved it, e.g. by an agent, unless `force` is `true`. The autosave
and `Ctrl+S` merge such changes into the window first and save again; objects that were changed
differently in both places get a card with "Take theirs", "Keep mine" and "Save as…", see
`_ProjectConflict`.
"""
function save_project(gui::LiveView, dir::AbstractString; force::Bool = false)
    dir = abspath(dir)
    from = gui.project
    save_as = !isnothing(from) && dir != from
    # A new folder of "save as" gets the own code and the module of the project
    name = save_as && !isfile(joinpath(dir, "Project.toml")) ? BMOP.project_name(from) :
           BMOP.project_name(dir)
    parts = _project_parts(gui, dir; name)
    # The objects of an open conflict keep the files' state in its own project, see `_saved_state`
    keep = save_as ? String[] : copy(gui.sync.conflicts)
    project = save_as ? parts.project : _saved_state(gui, parts.project)
    # The files as the view knows them: only of its own project
    dir == from && (project.stamp = gui.sync.stamp)
    if save_as
        # Before checking whether the folder is a project: the copy must not miss its module
        BMOP.copy_code(from, dir)
    end
    new = !isfile(joinpath(dir, "Project.toml"))
    # Refuses a line that another participant claimed (see `BeamletOpticsProjects.claim!`)
    path = save_project(project; packages = _project_packages(), force, by = _person().id)
    # A new project gets the skills of BeamletOptics and BeamletOpticsProjects from its scaffold,
    # and the one of the GUI here; derived copies, not part of the versions
    new && Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do
        install_agent_skill(joinpath(dir, ".claude", "skills"))
    end
    _write_view_toml(gui, parts.project, parts.names)
    # The uids that the save gave are those of `project`; at the objects of a conflict it holds
    # those of the files, not of the window
    _apply_project_names!(gui, project; skip = keep)
    # A shown window (see `_connect_session!`) leaves the old folder: its session and presence
    # files go, and its journal is not of the new project
    connected = save_as && !isempty(gui.sync.session)
    if connected
        try
            _session_closed!(gui)
            _presence_closed!(gui)
        catch e
            e isa InterruptException && rethrow()
            @warn "could not remove the session or presence file of $from" exception = e
        end
    end
    save_as && empty!(gui.sync.journal)
    gui.project = dir
    # The files of this stamp are the window's own write, see `_own_written`
    _own_save!(gui, project.stamp)
    _saved!(gui, project; keep)
    connected && _connect_session!(gui)
    dir == from || _set_title!(gui, basename(dir))
    msg = save_as ? "project saved as $dir" : "project saved to $dir"
    if !isempty(parts.skipped)
        list = join(parts.skipped, ", ")
        @warn "save_project: $(length(parts.skipped)) objects without a recipe were not saved: $list"
        msg *= "; $(length(parts.skipped)) objects without a recipe were not saved: $list"
    end
    gui.status.text[] = msg
    return path
end

function save_project(gui::LiveView; force::Bool = false)
    isnothing(gui.project) &&
        throw(ArgumentError("the live view has no project folder yet, use save_project(gui, dir)"))
    return save_project(gui, gui.project; force)
end

#=
Keys, tools and dialogs
=#

# The first line of the message of the error `e`
_message_line(e) = first(split(sprint(showerror, e), '\n'))

"""
Saves the `gui` to `dir`; if the files changed meanwhile, they are merged first (see `_sync!`) and
saved again, also with a conflict, whose objects keep the files' state (see `_saved_state`); any
other error, also of the second save, is logged and shown in the status line. Whether the files
hold the window afterwards (except the objects of a conflict): `false` after an error or files that
do not load.
"""
function _save_to!(gui::LiveView, dir::AbstractString; force::Bool = false)
    try
        save_project(gui, dir; force)
    catch e
        e isa InterruptException && rethrow()
        e isa BMOP.ProjectChanged || return _save_failed!(gui, e)
        gui.sync.changed_at = nothing
        # Without gliding: the save right after must see the poses of the files
        _adopting(() -> _sync!(gui; animate = false), gui) === :failed && return false
        gui.sync.failed && return false
        try
            save_project(gui, dir; force)
        catch e2
            e2 isa InterruptException && rethrow()
            return _save_failed!(gui, e2)
        end
    end
    return true
end

# Logs the error `e` of saving the `gui` and shows it in the status line; returns `false`
function _save_failed!(gui::LiveView, e)
    @error "save_project failed" exception = (e, catch_backtrace())
    gui.status.text[] = "project not saved: $(_message_line(e))"
    return false
end

"""
The path that the `dialog` (`_SAVE_DIALOG` or `_OPEN_DIALOG`) returns, starting in the folder that
holds the project of the `gui`; `nothing` if it was cancelled or failed, the reason of a failure in
the status line.
"""
function _ask_path(gui::LiveView, dialog::Ref)
    start = isnothing(gui.project) ? "" : dirname(gui.project)
    path = try
        dialog[](start)
    catch e
        e isa InterruptException && rethrow()
        gui.status.text[] = "no file dialog: $(_message_line(e)), use save_project/open_project"
        return nothing
    end
    (isnothing(path) || isempty(path)) && return nothing
    return String(path)
end

"""
    _save_target(path) -> (; dir, message)

The folder that "Save as" saves to, from the `path` of its dialog, a folder and a typed name
(`.bmo` or not): the folder of the project whose project file the user picked (the dialog asked
whether to overwrite it), else a new or empty folder with the name next to it. A `dir` of `nothing`
and the reason in `message` for any other path, e.g. a folder of that name that exists already.
"""
function _save_target(path::AbstractString)
    path = abspath(path)
    file = basename(path)
    name = endswith(lowercase(file), BMOP.EXTENSION) ? file[1:(end - length(BMOP.EXTENSION))] : file
    parent = dirname(path)
    isempty(strip(name)) && return (; dir = nothing, message = "project not saved: no name given")
    isfile(joinpath(parent, name * BMOP.EXTENSION)) && isfile(joinpath(parent, "Project.toml")) &&
        return (; dir = parent, message = "")
    dir = joinpath(parent, name)
    (!ispath(dir) || (isdir(dir) && isempty(readdir(dir)))) && return (; dir, message = "")
    return (; dir = nothing,
        message = "project not saved: \"$dir\" exists already; to overwrite a project, pick its .bmo file")
end

# Runs `f` after the key callback returned, e.g. a dialog, which blocks
_run_later(f) = (_DIALOG_TASK[] = @async f())

"""
`Ctrl+Shift+S` and the tool "Save as" of the `gui`: the dialog asks for a folder and a name, and the
setup is saved as the project in the folder of that name there, see `_save_target`, which becomes
the project of the `gui`. A cancelled dialog does nothing.
"""
function _save_as_key!(gui::LiveView)
    _run_later() do
        path = _ask_path(gui, _SAVE_DIALOG)
        isnothing(path) && return nothing
        target = _save_target(path)
        isnothing(target.dir) ? (gui.status.text[] = target.message) : _save_to!(gui, target.dir)
        return nothing
    end
    return nothing
end

"""
`Ctrl+S` and the tool "Save" of the `gui`: saves a version of its project. What the autosave has
not written yet is written to the files first, without waiting, and noted in the session file (see
`_autosave!` with `force`); then the card of the version asks for its message, filled with what
changed since the last version (see `_ask_version!`), or the status line says that nothing changed.
Nothing is saved while a conflict is open (see `_ProjectConflict`), whose card is shown, or when the
flush ends in a conflict, in files that do not load or in an error. Without a project, like "Save
as" (see `_save_as_key!`), whose new project has its first version.
"""
function _save_key!(gui::LiveView)
    isnothing(gui.project) && return _save_as_key!(gui)
    _conflict_open!(gui) && return nothing
    _autosave!(gui; force = true) in (:none, :saved) || return nothing
    summary = try
        BMOP.version_summary(gui.project)
    catch e
        e isa InterruptException && rethrow()
        @error "version_summary failed" exception = (e, catch_backtrace())
        gui.status.text[] = "no version saved: $(_message_line(e))"
        return nothing
    end
    isempty(summary) ? (gui.status.text[] = "no changes since the last version") : _ask_version!(gui, summary)
    return nothing
end

"""
Whether a conflict of the `gui` waits for a decision on its card (see `_ProjectConflict`), for
`_save_key!`: the card is shown again if another one replaced it, and the status line asks to
decide on it first.
"""
function _conflict_open!(gui::LiveView)
    s = gui.sync
    c = _info_card(gui)
    shown = !isnothing(c) && c.obj isa _ProjectConflict
    (shown || !isempty(s.conflicts)) || return false
    if !shown && !isnothing(s.theirs)
        _show_conflict!(gui, s.conflicts)
        c = _info_card(gui)
    end
    names = (!isnothing(c) && c.obj isa _ProjectConflict) ? c.obj.names : s.conflicts
    gui.status.text[] = "decide on the card first: $(join(names, ", "))"
    return true
end

"""
    _VersionCard

The card of `Ctrl+S` that saves a version of the project (see `_save_key!`): a text box with the
message of the version and the buttons "Save version" and "Cancel"; `Enter` in the box saves, `Esc`
cancels, see `_save_version!` and `_cancel_version!`. `message` is what changed since the last
version when the card was shown, which `_ask_version!` puts in the box once (the refreshes of the
cards leave the box alone, it holds what the person typed).
"""
struct _VersionCard <: _InfoItem
    point::Point3f
    message::String
end

_points(x::_VersionCard) = [x.point]
_title(::_VersionCard) = "Save a version"
_tree_kind(::_VersionCard) = :save
_keep_plots!(::LiveView, ::_VersionCard) = nothing
_keepable(::_VersionCard) = false
card_rows(::_VersionCard) = (
    CardRow(CardWidget(Textbox; name = :version_message, placeholder = "message of the version",
        width = 280, halign = :left,
        on = (gui, _, v) -> _save_version!(gui, v))),
    CardRow(
        CardWidget(Button; name = :version_save, label = "Save version",
            on = (gui, _, _) -> _save_version!(gui)),
        CardWidget(Button; name = :version_cancel, label = "Cancel",
            on = (gui, _, _) -> _cancel_version!(gui))))

"""The card of the version of the `gui` if it is shown (see `_VersionCard`), else `nothing`."""
function _version_card(gui::LiveView)
    c = _info_card(gui)
    return (isnothing(c) || !(c.obj isa _VersionCard)) ? nothing : c
end

"""The text box of the message on the card of the version of the `gui`, or `nothing`."""
function _version_box(gui::LiveView)
    c = _version_card(gui)
    return isnothing(c) ? nothing : _card_widget(c, :version_message)
end

"""
    _ask_version!(gui, message)

Shows the card of a version of the project of the `gui` (see `_VersionCard`) with the `message` in
its text box, which has the focus with the caret at the end, such that typing adds to it: the keys
of the window are left to it meanwhile.
"""
function _ask_version!(gui::LiveView, message::AbstractString)
    _show_info!(gui, _VersionCard(_error_anchor(gui), String(message)))
    box = _version_box(gui)
    if !isnothing(box)
        _set_box!(box, String(message))
        Makie.focus!(box)
        box.editor.cursors[] = [Makie.EditCursor(length(message))]
    end
    gui.status.text[] = "save a version: Enter saves, Esc cancels"
    return nothing
end

"""
    _save_version!(gui, message = text of the box)

Saves a version of the project of the `gui` with the `message` (see
`BeamletOpticsProjects.save_version`) and closes the card of the version; the result or the error
(e.g. changes outside the project that are staged in its repository) in the status line. A message
that is still the summary that the card showed is computed again (`version_summary`), since the
files may have changed while the card was open; a typed message is kept.
"""
function _save_version!(gui::LiveView, message = nothing)
    box = _version_box(gui)
    if isnothing(message)
        message = isnothing(box) ? "" : box.displayed_string[]
    end
    message = String(strip(String(message)))
    c = _version_card(gui)
    shown = isnothing(c) ? nothing : strip(c.obj.message)
    isnothing(box) || Makie.defocus!(box)
    _release_info!(gui, _VersionCard)
    isnothing(gui.project) && return nothing
    try
        message == shown && (message = String(strip(BMOP.version_summary(gui.project))))
        id = BMOP.save_version(gui.project; message)
        gui.status.text[] = isnothing(id) ? "no changes since the last version" : "version saved: $message"
    catch e
        e isa InterruptException && rethrow()
        @error "save_version failed" exception = (e, catch_backtrace())
        gui.status.text[] = "version not saved: $(_message_line(e))"
    end
    return nothing
end

"""Closes the card of the version of the `gui` without saving a version, e.g. by `Esc`."""
function _cancel_version!(gui::LiveView)
    box = _version_box(gui)
    isnothing(box) && return nothing
    Makie.defocus!(box)
    _release_info!(gui, _VersionCard)
    gui.status.text[] = "no version saved"
    return nothing
end

"""
`Ctrl+O` and the tool "Open" of the `gui`: opens the project of the project file (`*.bmo`) that the
dialog picks in a new window with the layout and the theme of the `gui`, then closes the `gui` and
its window. A cancelled dialog does nothing, an error shows its message in the status line and
keeps the `gui`.
"""
function _open_key!(gui::LiveView)
    _run_later() do
        path = _ask_path(gui, _OPEN_DIALOG)
        isnothing(path) && return nothing
        try
            open_project(path; _window_kwargs(gui)...)
        catch e
            e isa InterruptException && rethrow()
            @error "open_project failed" exception = (e, catch_backtrace())
            gui.status.text[] = "project not opened: $(_message_line(e))"
            return nothing
        end
        _close_window!(gui)
        return nothing
    end
    return nothing
end

"""
Connects `Ctrl+S`, `Ctrl+Shift+S` and `Ctrl+O` (`Cmd` on macOS) of the `gui` and the tools "Save",
"Save as" and "Open", see `_save_key!`, `_save_as_key!` and `_open_key!`, like `_connect_copy!`: by
the letters of the keys in the keyboard layout, before the camera, which takes `s` and `o`; left to
a focused text box, nothing in the spectator mode. `Esc` closes the card of a version.
"""
function _connect_project!(gui::LiveView)
    scene = gui.ax.scene
    ctrl = gui.controls
    push!(ctrl.listeners, on(events(scene).keyboardbutton; priority = 210) do event
        (event.action == Keyboard.press && _modifier_held(scene, _CTRL_OR_CMD_KEYS)) ||
            return Consume(false)
        key = _layout_key(event.key)
        ctrl.ignore_keys() && return Consume(false)
        ctrl.spectator[] && return Consume(true)
        key in (Keyboard.s, Keyboard.o, Keyboard.r) || return Consume(false)
        if key == Keyboard.o
            _open_key!(gui)
        elseif key == Keyboard.r
            _reload_key!(gui)
        else
            _shift_pressed(scene) ? _save_as_key!(gui) : _save_key!(gui)
        end
        return Consume(true)
    end)
    # Esc closes the card of a version, also while its text box has the keyboard, before the box
    # and the other keys of the window, see `_cancel_version!`
    push!(ctrl.listeners, on(events(scene).keyboardbutton; priority = 210) do event
        (event.action == Keyboard.press && event.key == Keyboard.escape) || return Consume(false)
        isnothing(_version_card(gui)) && return Consume(false)
        _cancel_version!(gui)
        return Consume(true)
    end)
    append!(ctrl.help_extra, _PROJECT_HELP)
    _update_help!(ctrl)
    add_tool!(_save_key!, gui, "Save"; icon = :save,
        tooltip = "Save a version ($(_ctrl_cap())+S)")
    add_tool!(_save_as_key!, gui, "Save as"; icon = :save_as,
        tooltip = "Save as a new project with a name ($(_ctrl_cap())+Shift+S)")
    add_tool!(_open_key!, gui, "Open"; icon = :open,
        tooltip = "Open a project, its .bmo file ($(_ctrl_cap())+O)")
    return nothing
end
