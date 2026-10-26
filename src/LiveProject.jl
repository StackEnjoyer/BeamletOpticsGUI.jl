#=
Projects: saving a view to a project folder and opening one (see BeamletOpticsProjects). The setup
is `system.jl` of the folder, written and read by BeamletOpticsProjects; how the view looks (camera,
saved views, clip planes, table, the colors of the beams, ...) is `view.toml`, which the GUI writes
and reads itself.
=#

const BMOP = BeamletOpticsProjects

# The file of the folder of a project that holds how the view looks
const _VIEW_TOML = "view.toml"

# The keys of saving and opening, in the help of the controls, see `_help_sections`
const _PROJECT_HELP = _HelpSection["Edit" => [
    _HelpEntry([_ctrl_cap(), "S"], "save the setup as a project folder"; combo = true),
    _HelpEntry([_ctrl_cap(), "O"], "open a project folder"; combo = true)]]

"""
The dialog that picks a folder, `path -> folder`, which returns `""` (or `nothing`) if it was
cancelled: the native dialog of NativeFileDialog, replaced by the tests.
"""
const _PICK_FOLDER = Ref{Any}(path -> NativeFileDialog.pick_folder(path))

# The task of the last dialog of `Ctrl+S` or `Ctrl+O`, which runs after the key callback returned
const _DIALOG_TASK = Ref{Any}(nothing)

#=
Names
=#

"""Whether `s` can be the name of an entry or a system of a project: a free variable name."""
_is_project_name(s::AbstractString) = _is_variable_name(s) && !_is_taken_name(s) &&
                                      !Base.isexported(BMOP, Symbol(s))

"""`s` with every character that is not allowed in a name replaced by `_`, e.g. `Mirror_1`."""
function _sanitized_name(s::AbstractString)
    t = replace(strip(s), r"[^\p{L}\p{N}_]+" => "_")
    t = strip(t, '_')
    isempty(t) && return "obj"
    return isletter(first(t)) ? String(t) : "obj_" * t
end

"""
    _project_names(gui, items) -> IdDict{Any, Symbol}

The names of the objects, sources and systems `items` of the `gui` in a project: the label (see
`_label`) if it is a free variable name (see `_is_project_name`) that no item before took, else the
label with the characters of no name replaced by `_` (see `_sanitized_name`), with `_2`, `_3`, …
appended while it is taken.
"""
function _project_names(gui::LiveView, items)
    names = IdDict{Any, Symbol}()
    used = Set{String}()
    for x in items
        label = _label(gui, x)
        base = _is_project_name(label) ? label : _sanitized_name(label)
        name, k = base, 1
        while name in used || !_is_project_name(name)
            k += 1
            name = "$(base)_$k"
        end
        push!(used, name)
        names[x] = Symbol(name)
    end
    return names
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
    _project_parts(gui, dir) -> (; project, names, skipped)

The `project` of the `gui` in the folder `dir` (see `_collect_project`), the `names` of its
objects, sources and systems and the labels of the objects and sources that were `skipped`, since
their constructor is not known.
"""
function _project_parts(gui::LiveView, dir::AbstractString)
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
    for x in Any[objects..., sources...]
        if isnothing(get(comp.origin, x, nothing))
            push!(skipped, _label(gui, x))
        else
            push!(saved, x)
        end
    end
    names = _project_names(gui, Any[saved..., systems...])
    entries = BMOP.Entry[]
    for x in saved
        origin = comp.origin[x]
        pos, rot = _project_pose(x, origin)
        P0, R0 = origin.pose0
        push!(entries, BMOP.Entry(_entry_kind(x), names[x], Meta.parse(origin.code), x; pos, rot,
            pose0 = (Vector{Float64}(P0), Matrix{Float64}(R0)), meta = _project_meta(origin)))
    end
    is_saved = Base.IdSet{Any}(saved)
    system_entries = BMOP.SystemEntry[BMOP.SystemEntry(names[sys],
        Symbol[names[obj] for obj in sys.objects if obj in is_saved],
        Symbol[names[src] for src in _sources_of(gui, sys) if src in is_saved];
        static = _static_system(sys), object = sys) for sys in systems]
    project = BMOP.Project(dir, BMOP.project_name(dir); entries, systems = system_entries)
    return (; project, names, skipped)
end

"""
    _collect_project(gui, dir) -> Project

The setup of the `gui` as a project in the folder `dir`: its systems (`System` or `StaticSystem`)
with their members and sources, the objects and sources without a system (not those of the
`extras` kwarg), each object once, also one of several systems. Each is an entry with its
constructor call and its pose, see `_project_pose`; one whose constructor is not known (see the
`origin` of `_ComponentState`) is left out. The inputs of the page "Edit" that are not applied are
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

# The handle of a system has the name of the system, see `_rename_system!`
function _name_handle!(gui::LiveView, sys::BMO.AbstractSystem, name::String)
    h = _system_handle(gui, sys)
    isnothing(h) || (gui.objects.names[h] = name)
    return nothing
end
_name_handle!(::LiveView, @nospecialize(x), ::String) = nothing

"""
Writes the `names` of a saved project into the labels of the `gui`, such that the next save gives
the same names.
"""
function _apply_project_names!(gui::LiveView, names)
    changed = false
    for (x, name) in names
        s = String(name)
        get(gui.labels, x, nothing) == s && continue
        changed = true
        gui.labels[x] = gui.objects.names[x] = s
        _name_handle!(gui, x, s)
    end
    changed || return nothing
    _refresh_names!(gui)
    _refresh_catalog!(gui)
    _refresh_links!(gui)
    return nothing
end

#=
view.toml
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

What `view.toml` holds of the `gui`: the `camera`, the saved `views`, the `clip_planes` and
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

"""Writes `view.toml` of the `gui` into the folder of the `project`, with the `names` of its sources."""
function _write_view_toml(gui::LiveView, project, names)
    path = BMOP.project_file(project, _VIEW_TOML)
    mkpath(dirname(path))
    text = sprint(io -> TOML.print(io, _view_dict(gui, names); sorted = true))
    write(path, text)
    return path
end

"""`view.toml` of the `project`, an empty `Dict` without one."""
function _read_view(project)
    path = BMOP.project_file(project, _VIEW_TOML)
    return isfile(path) ? TOML.parsefile(path) : Dict{String, Any}()
end

_view_tuple(d) = (Vector{Float64}(d["eye"]), Vector{Float64}(d["lookat"]), Vector{Float64}(d["up"]))

"""
    _view_kwargs(view, byname, paired) -> (kwargs, beam_kwargs, off)

The kwargs of `live_view` from the `view` (of `view.toml`), with the objects of the project by name
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
sources without a system, the names of the project as labels, the origins of the objects (their
code, with which they are saved again and, from the catalog, edited and copied), and `view.toml`.
The `kwargs` of `live_view` win over those of `view.toml`.
"""
function _open_from(project; kwargs...)
    @nospecialize
    byname = Dict{Symbol, Any}(e.name => e.object for e in project.entries)
    in_system = Set{Symbol}()
    args = Any[]
    for s in project.systems
        union!(in_system, s.members, s.sources)
        sources = Any[byname[n] for n in s.sources]
        isempty(sources) ? push!(args, s.object) : append!(args, Any[s.object => src for src in sources])
    end
    isempty(args) && push!(args, BMO.System())
    paired = Base.IdSet{Any}(a.second for a in args if a isa Pair)
    labels = IdDict{Any, String}()
    foreach(e -> labels[e.object] = String(e.name), project.entries)
    foreach(s -> labels[s.object] = String(s.name), project.systems)
    view = _read_view(project)
    vk = _view_kwargs(view, byname, paired)
    gui = live_view(args...; labels, vk.kwargs..., kwargs...)
    origins = IdDict{Any, Any}(e.object => _project_origin(gui, e) for e in project.entries)
    _unrecorded(gui) do
        for e in project.entries
            e.name in in_system && continue
            _add_loose!(gui, e.object, String(e.name), origins[e.object], vk.beam_kwargs)
        end
        for src in vk.off
            src in paired || _set_beam_on!(gui, src, false)
        end
    end
    for (obj, origin) in origins
        gui.components.origin[obj] = origin
    end
    empty!(gui.controls.undo_stack)
    empty!(gui.controls.redo_stack)
    if haskey(view, "camera")
        set_view(gui.ax, _view_tuple(view["camera"])...)
    end
    gui.project = project.path
    gui.status.text[] = "project $(project.name) opened from $(project.path)"
    return gui
end

"""
    open_project(dir; display = true, kwargs...) -> LiveView

Opens the project in the folder `dir` (see `BeamletOpticsProjects.load_project`) in a live view
and shows it if `display` is `true`: its systems with their sources, the objects and sources
without a system, the names of the project as labels and how the view looked when it was saved
(`view.toml`: camera, saved views, clip planes, table, the colors of the beams, ...). The `kwargs`
are those of [`live_view`](@ref) and win over `view.toml`. `Ctrl+S` saves it there again, see
[`save_project`](@ref). The components and sources from the catalog can be edited and copied.
`Ctrl+O` or the tool "Open" of a window opens a project chosen in a dialog and closes the window.
"""
function open_project(dir::AbstractString; display::Bool = true, kwargs...)
    project = BMOP.load_project(dir)
    gui = _open_from(project; kwargs...)
    if display
        _multi_light_backend() ? Base.display(gui; title = project.name) : Base.display(gui)
    end
    return gui
end

#=
Saving
=#

"""
    save_project(gui::LiveView, dir = gui.project) -> String

Saves the setup of the live view `gui` as the project in the folder `dir` and returns the path of
its `system.jl`: each system with its members and sources, the objects and sources without a
system, each with its constructor call and its pose, see `BeamletOpticsProjects`. A folder that is
not a project yet becomes one, with the versions of BeamletOptics, BeamletOpticsProjects,
BeamletOpticsGUI and GLMakie. How the view looks is written to `view.toml`. An object whose
constructor is not known, e.g. one that the script gave to `live_view`, is not saved: a warning and
the status line name it. The names of the project become the labels of the view, and `dir` its
project, which `Ctrl+S` saves to.
"""
function save_project(gui::LiveView, dir::AbstractString)
    dir = abspath(dir)
    parts = _project_parts(gui, dir)
    path = save_project(parts.project; packages = _project_packages())
    _write_view_toml(gui, parts.project, parts.names)
    _apply_project_names!(gui, parts.names)
    gui.project = dir
    msg = "project saved to $dir"
    if !isempty(parts.skipped)
        list = join(parts.skipped, ", ")
        @warn "save_project: $(length(parts.skipped)) objects without a recipe were not saved: $list"
        msg *= "; $(length(parts.skipped)) objects without a recipe were not saved: $list"
    end
    gui.status.text[] = msg
    return path
end

function save_project(gui::LiveView)
    isnothing(gui.project) &&
        throw(ArgumentError("the live view has no project folder yet, use save_project(gui, dir)"))
    return save_project(gui, gui.project)
end

#=
Keys, tools and dialogs
=#

# The first line of the message of the error `e`
_message_line(e) = first(split(sprint(showerror, e), '\n'))

"""Saves the `gui` to `dir`; an error is logged and shown in the status line."""
function _save_to!(gui::LiveView, dir::AbstractString)
    try
        save_project(gui, dir)
    catch e
        e isa InterruptException && rethrow()
        @error "save_project failed" exception = (e, catch_backtrace())
        gui.status.text[] = "project not saved: $(_message_line(e))"
    end
    return nothing
end

"""
The folder that the dialog picks, starting at the project of the `gui`; `nothing` if it was
cancelled or failed, the reason of a failure in the status line.
"""
function _pick_folder(gui::LiveView)
    dir = try
        _PICK_FOLDER[](something(gui.project, ""))
    catch e
        e isa InterruptException && rethrow()
        gui.status.text[] = "no folder dialog: $(_message_line(e)), use save_project/open_project"
        return nothing
    end
    (isnothing(dir) || isempty(dir)) && return nothing
    return String(dir)
end

# Runs `f` after the key callback returned, e.g. a dialog, which blocks
_run_later(f) = (_DIALOG_TASK[] = @async f())

"""
`Ctrl+S` and the tool "Save" of the `gui`: saves to its project, or, without one, to the folder
that the dialog picks (a cancelled dialog does nothing).
"""
function _save_key!(gui::LiveView)
    if isnothing(gui.project)
        _run_later() do
            dir = _pick_folder(gui)
            isnothing(dir) || _save_to!(gui, dir)
            return nothing
        end
    else
        _save_to!(gui, gui.project)
    end
    return nothing
end

"""
`Ctrl+O` and the tool "Open" of the `gui`: opens the project that the dialog picks in a new window
with the layout and the theme of the `gui`, then closes the `gui` and its window. A cancelled dialog
does nothing, an error shows its message in the status line and keeps the `gui`.
"""
function _open_key!(gui::LiveView)
    _run_later() do
        dir = _pick_folder(gui)
        isnothing(dir) && return nothing
        try
            open_project(dir; layout = _layout_name(gui.layout), theme = _theme_name(gui.layout.theme))
        catch e
            e isa InterruptException && rethrow()
            @error "open_project failed" exception = (e, catch_backtrace())
            gui.status.text[] = "project not opened: $(_message_line(e))"
            return nothing
        end
        # Never inside the event callback of its own screen: this task runs after it returned
        screen = Makie.getscreen(gui.fig.scene)
        close(gui)
        isnothing(screen) || close(screen)
        return nothing
    end
    return nothing
end

"""
Connects `Ctrl+S` and `Ctrl+O` (`Cmd` on macOS) of the `gui` and the tools "Save" and "Open", see
`_save_key!` and `_open_key!`, like `_connect_copy!`: by the letters of the keys in the keyboard
layout, before the camera, which takes `s` and `o`; left to a focused text box, nothing in the
spectator mode.
"""
function _connect_project!(gui::LiveView)
    scene = gui.ax.scene
    ctrl = gui.controls
    push!(ctrl.listeners, on(events(scene).keyboardbutton; priority = 210) do event
        (event.action == Keyboard.press && _modifier_held(scene, _CTRL_OR_CMD_KEYS)) ||
            return Consume(false)
        key = _layout_key(event.key)
        key in (Keyboard.s, Keyboard.o) || return Consume(false)
        ctrl.ignore_keys() && return Consume(false)
        ctrl.spectator[] && return Consume(true)
        key == Keyboard.s ? _save_key!(gui) : _open_key!(gui)
        return Consume(true)
    end)
    append!(ctrl.help_extra, _PROJECT_HELP)
    _update_help!(ctrl)
    add_tool!(_save_key!, gui, "Save"; icon = :save,
        tooltip = "Save the setup as a project folder ($(_ctrl_cap())+S)")
    add_tool!(_open_key!, gui, "Open"; icon = :open,
        tooltip = "Open a project folder ($(_ctrl_cap())+O)")
    return nothing
end
