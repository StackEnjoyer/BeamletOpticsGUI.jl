#=
The packages of the project of a window: each person and machine runs a project in a package
environment of its own, `.envs/<person>@<machine>/` (see `BeamletOpticsProjects.personal_environment!`),
which has the packages that the project's `Project.toml` names. When someone changes those (e.g.
`] add` of a package that the project needs), the window says so: the person updates the
environment and starts again. Nothing here loads or reloads a package.
=#

"""
    _package_marks(dir) -> Vector{Tuple{String, Float64, Int}}

The time and size of the `Project.toml` of the project in `dir` (if it exists), like `_file_marks`;
read by each look of the watcher, see `_files_look`.
"""
function _package_marks(dir::AbstractString)
    file = joinpath(dir, "Project.toml")
    return isfile(file) ? [("Project.toml", mtime(file), filesize(file))] : Tuple{String, Float64, Int}[]
end

"""
    _packages_key(dir) -> Union{Nothing, Dict}

What the `Project.toml` of the project in `dir` says about its packages: its `[deps]`, `[compat]`
and `[sources]`; `nothing` if it is missing or does not parse (e.g. while it is written).
"""
function _packages_key(dir::AbstractString)
    file = joinpath(dir, "Project.toml")
    isfile(file) || return nothing
    toml = try
        TOML.parsefile(file)
    catch e
        e isa InterruptException && rethrow()
        return nothing
    end
    return Dict{String, Any}(k => get(toml, k, nothing) for k in ("deps", "compat", "sources"))
end

"""
    _PackageState

What a window knows about the packages of its project: the folder `dir`, the packages at its start
(`key`, see `_packages_key`), the `marks` of the last look and the time `changed_at` they changed
(`nothing` once settled), and the packages it noticed last (`noticed`), so that a change is shown
once.
"""
mutable struct _PackageState
    dir::String
    key::Union{Nothing, Dict{String, Any}}
    marks::Vector{Tuple{String, Float64, Int}}
    changed_at::Union{Nothing, Float64}
    noticed::Union{Nothing, Dict{String, Any}}
end

const _PACKAGES = WeakKeyDict{LiveView, _PackageState}()

"""
    _package_state(gui) -> Union{Nothing, _PackageState}

The packages of the project of the `gui` as it started with them (noted at the first call, e.g.
when its watcher starts); `nothing` without a project.
"""
function _package_state(gui::LiveView)
    dir = gui.project
    isnothing(dir) && return nothing
    st = get(_PACKAGES, gui, nothing)
    (isnothing(st) || st.dir != dir) || return st
    st = _PackageState(String(dir), _packages_key(dir), _package_marks(dir), nothing, nothing)
    _PACKAGES[gui] = st
    return st
end

"""The info card that the packages of the project changed, see `_check_packages!`."""
struct _PackageNotice <: _InfoItem
    point::Point3f
end

_points(x::_PackageNotice) = [x.point]
_title(::_PackageNotice) = "Packages changed"
_tree_kind(::_PackageNotice) = :warning
_keep_plots!(::LiveView, ::_PackageNotice) = nothing
_keepable(::_PackageNotice) = false
card_rows(::_PackageNotice) = (
    _text_row("what", :packages_what, (_, _) -> "the packages of the project changed"; width = 48),
    _text_row("take", :packages_take, (_, _) -> "personal_environment!(\".\"), then start again"; width = 48))

const _PACKAGE_NOTICE = "packages of the project changed: personal_environment!(\".\") and start again to take them"

"""
    _check_packages!(gui, marks; now = time()) -> Symbol

One look of the watcher at the `Project.toml` of the project of the `gui` with its `marks` (see
`_package_marks`): `:pending` while it changes or has not stayed unchanged for `_SETTLE` seconds,
then `:noticed` once per new state of its packages (`[deps]`, `[compat]`, `[sources]`) that
differs from the one the window started with, shown in the status line and on an info card (see
`_PackageNotice`); `:none` otherwise, e.g. for an edit of another part of it. The window keeps
its loaded packages: nothing is loaded.
"""
function _check_packages!(gui::LiveView, marks; now::Real = time())
    st = _package_state(gui)
    isnothing(st) && return :none
    if marks != st.marks
        st.marks = marks
        st.changed_at = Float64(now)
        return :pending
    end
    isnothing(st.changed_at) && return :none
    now - st.changed_at >= _SETTLE || return :pending
    st.changed_at = nothing
    key = _packages_key(st.dir)
    (isnothing(key) || key == st.key || key == st.noticed) && return :none
    st.noticed = key
    gui.status.text[] = _PACKAGE_NOTICE
    _show_info!(gui, _PackageNotice(_error_anchor(gui)))
    return :noticed
end
