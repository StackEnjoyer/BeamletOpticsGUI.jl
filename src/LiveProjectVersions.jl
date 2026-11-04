#=
The versions of a project: its project file (`<name>.bmo`) records the newest versions of
BeamletOptics, BeamletOpticsProjects and the GUI that it was saved with and the packages that its
code uses (see `BeamletOpticsProjects.check_versions`). The tool "Open" checks them against this
session before it opens a project (`_open_checked!`): the same or newer compatible versions open
silently, newer versions that may break it open with a notice in the status line, and older
versions or a package that is not installed show a card that asks first (`_VersionsCard`).
`open_project` from code warns instead (`_warn_versions`). The presence file of a window carries
its versions (`_own_versions`), and the window says once per participant and difference when
another participant works with other versions (`_versions_notice!`).
=#

"""
    _own_versions() -> Dict{String, String}

The versions of BeamletOptics, BeamletOpticsProjects and the GUI in this session by name (see
`_project_packages`), for the presence file of a window: the others compare them with theirs, see
`_versions_notice!`. A package without a version is left out.
"""
function _own_versions()
    out = Dict{String, String}()
    for m in _project_packages()
        v = pkgversion(m)
        isnothing(v) || (out[string(nameof(m))] = string(v))
    end
    return out
end

"""
    _version_checks(path) -> Vector{BeamletOpticsProjects.VersionCheck}

The versions of the project of the folder or project file `path` compared with this session, see
`BeamletOpticsProjects.check_versions` (with the GUI). Empty if they can not be read, e.g. a project
file that does not parse: opening it reports that.
"""
function _version_checks(path::AbstractString)
    try
        return BMOP.check_versions(path; packages = Module[@__MODULE__])
    catch e
        e isa InterruptException && rethrow()
        @debug "live_view: the versions of the project were not checked" exception = e
        return BMOP.VersionCheck[]
    end
end

# The checks that ask before the project opens (an older version, a package that is not
# installed) and those that only note it (a newer version that may break it)
const _ASKING = (:older, :missing)
const _NOTED = (:older, :missing, :breaking)

# The versions in a text: `"?"` for an unknown one
_version_string(v) = isnothing(v) ? "?" : string(v)

"""
The text of the check `c` of a version (see `BeamletOpticsProjects.VersionCheck`) on the card and in
the warnings, with the command that installs what the project needs: `] up X` for an older version,
`] add X` for a package that is not installed.
"""
function _check_text(c)
    s = c.status
    s === :older && return "saved with $(_version_string(c.recorded)), here $(_version_string(c.installed)): ] up $(c.package)"
    s === :missing && return isnothing(c.recorded) ? "not installed here: ] add $(c.package)" :
                             "saved with $(c.recorded), not installed here: ] add $(c.package)"
    s === :breaking && return "saved with $(_version_string(c.recorded)), here $(_version_string(c.installed)), which may break it"
    return "saved with $(_version_string(c.recorded)), here $(_version_string(c.installed))"
end

"""
    _VersionsCard

The card of `_open_checked!` before a project opens that was saved with newer versions than this
session has, or whose code uses a package that is not installed here (see
`BeamletOpticsProjects.check_versions`): an info card at `point` with a row per such package
(`checks`, of the status `:older`, `:missing` or `:breaking`) with the version that the project
recorded, the one here and the command that installs what it needs, and the buttons "Open anyway"
(see `_open_now!`) and "Cancel" (see `_cancel_open!`). The project of the folder or project file
`path` opens only by "Open anyway".
"""
struct _VersionsCard <: _InfoItem
    point::Point3f
    path::String
    checks::Vector{Any}
end

_points(x::_VersionsCard) = [x.point]
_title(::_VersionsCard) = "Saved with other versions"
_tree_kind(::_VersionsCard) = :warning
_keep_plots!(::LiveView, ::_VersionsCard) = nothing
_keepable(::_VersionsCard) = false
function card_rows(x::_VersionsCard)
    # the names in a column as wide as the longest one
    width = 8 * maximum(c -> length(c.package), x.checks; init = 5)
    rows = Any[_text_row(c.package, Symbol(:versions_, i), (_, _) -> _check_text(c); width)
               for (i, c) in enumerate(x.checks)]
    push!(rows, CardRow(
        CardWidget(Button; name = :versions_open, label = "Open anyway",
            on = (gui, _, _) -> _open_anyway!(gui)),
        CardWidget(Button; name = :versions_cancel, label = "Cancel",
            on = (gui, _, _) -> _cancel_open!(gui))))
    return Tuple(rows)
end

"""The card of the versions of the `gui` if it is shown (see `_VersionsCard`), else `nothing`."""
function _versions_card(gui::LiveView)
    c = _info_card(gui)
    return (isnothing(c) || !(c.obj isa _VersionsCard)) ? nothing : c
end

"""
    _open_checked!(gui, path; checks = _version_checks(path)) -> Union{LiveView, Nothing}

Opens the project of the folder or project file `path` from the window of the `gui`, e.g. by the
tool "Open" (`Ctrl+O`), after its versions were compared with this session (`checks`, see
`_version_checks`): the same or newer compatible versions open it at once, newer versions that may
break it (`:breaking`) open it with a notice in the status line of the new window (see
`_open_now!`). An older version or a package that is not installed (`:older`, `:missing`) show the
card of the versions (`_VersionsCard`) instead, which opens it by "Open anyway"; the status line
says so. Returns the view of the opened project, else `nothing`.
"""
function _open_checked!(gui::LiveView, path::AbstractString; checks = _version_checks(path))
    noted = Any[c for c in checks if c.status in _NOTED]
    if any(c -> c.status in _ASKING, noted)
        _show_info!(gui, _VersionsCard(_error_anchor(gui), String(path), noted))
        gui.status.text[] = "project not opened yet: it needs other versions, see the card"
        return nothing
    end
    return _open_now!(gui, path, noted)
end

# Whether `open_project` warns about the versions of the project: not when the window checked them
const _VERSIONS_SHOWN = Base.ScopedValues.ScopedValue(false)

"""
    _open_now!(gui, path, noted) -> Union{LiveView, Nothing}

Opens the project of the folder or project file `path` in a new window with the layout and the
theme of the `gui` (see `open_project`, which does not warn about its versions then), notes the
checks `noted` of its versions in the status line of the new window (see `_check_text`), and closes
the `gui` and its window. An error shows its message in the status line and keeps the `gui`.
Returns the new view, else `nothing`. Never called inside an event callback of the window of the
`gui`, which it closes (see `_open_anyway!`).
"""
function _open_now!(gui::LiveView, path::AbstractString, noted)
    new = try
        Base.ScopedValues.with(_VERSIONS_SHOWN => true) do
            open_project(path; _window_kwargs(gui)...)
        end
    catch e
        e isa InterruptException && rethrow()
        @error "open_project failed" exception = (e, catch_backtrace())
        gui.status.text[] = "project not opened: $(_message_line(e))"
        return nothing
    end
    isempty(noted) || (new.status.text[] = new.status.text[] * "; " * _noted_text(noted))
    _close_window!(gui)
    return new
end

# The checks `noted` of the versions of a project in the status line, see `_open_now!`
_noted_text(noted) = "other versions: " * join(("$(c.package) $(_check_text(c))" for c in noted), "; ")

"""
"Open anyway" on the card of the versions of the `gui` (see `_VersionsCard`): closes the card and
opens its project after the callback of the button returned, which the task `_DIALOG_TASK` returns.
"""
function _open_anyway!(gui::LiveView)
    c = _versions_card(gui)
    isnothing(c) && return nothing
    x = c.obj
    _release_info!(gui, _VersionsCard)
    _run_later(() -> _open_now!(gui, x.path, x.checks))
    return nothing
end

"""
"Cancel" on the card of the versions of the `gui` (see `_VersionsCard`): closes the card, the project
is not opened.
"""
function _cancel_open!(gui::LiveView)
    c = _versions_card(gui)
    isnothing(c) && return nothing
    path = c.obj.path
    _release_info!(gui, _VersionsCard)
    gui.status.text[] = "project not opened: $path"
    return nothing
end

"""
    _warn_versions(path)

Warns for `open_project` from code when the project of the folder or project file `path` was saved
with newer versions than this session has, needs newer ones or a package that is not installed
(see `_version_checks`), with the command that installs it; one warning for all. Nothing when the
window checked them already (see `_open_checked!`).
"""
function _warn_versions(path::AbstractString)
    _VERSIONS_SHOWN[] && return nothing
    noted = [c for c in _version_checks(path) if c.status in _NOTED]
    isempty(noted) && return nothing
    @warn "the project was saved with other versions:\n" *
          join(("$(c.package): $(_check_text(c))" for c in noted), "\n")
    return nothing
end

#=
The versions of the others
=#

# Per view, the differences of the versions of the others that its status line noted:
# (id of the participant, package, its version)
const _VERSIONS_NOTED = WeakKeyDict{LiveView, Set{Tuple{String, String, String}}}()

"""
    _versions_notice!(gui, look, now)

Notes in the status line of the `gui` once per participant and difference when another
participant that is there at `now` works with other versions of a package than this session (see
`_own_versions`), from the `versions` of the presence files of the `look` of the watcher (see
`_check_presence!`), e.g. `"Oliver: BeamletOptics 0.14.1, you: 0.14.0"`. A package that one of
both does not name is no difference.
"""
function _versions_notice!(gui::LiveView, look, now::Real)
    mine = _own_versions()
    noted = get!(Set{Tuple{String, String, String}}, _VERSIONS_NOTED, gui)
    texts = String[]
    for id in sort!(collect(keys(look.presences)))
        o = get(gui.sync.others, id, nothing)
        (isnothing(o) || !_alive(o, now)) && continue
        theirs = get(look.presences[id], "versions", nothing)
        theirs isa AbstractDict || continue
        diffs = String[]
        for name in sort!(collect(keys(theirs)))
            v = theirs[name]
            m = get(mine, name, nothing)
            (v isa AbstractString && !isnothing(m) && v != m) || continue
            key = (String(id), String(name), String(v))
            key in noted && continue
            push!(noted, key)
            push!(diffs, "$name $v, you: $m")
        end
        isempty(diffs) || push!(texts, "$(o.name): " * join(diffs, "; "))
    end
    isempty(texts) || (gui.status.text[] = join(texts, " · "))
    return nothing
end
