import Makie
using Makie: events, on, off, Consume, Mouse, Keyboard, mouseposition_px, Point2f, Vec3f
using LinearAlgebra: tr, diag, I, pinv

"""
    _ray_plane_intersect(origin, dir, plane_point, normal)

Returns the intersection of the ray `origin + t * dir` with the plane through `plane_point`, or
`nothing` if the ray is parallel to the plane or points away from it.
"""
function _ray_plane_intersect(origin, dir, plane_point, normal)
    denom = dot(dir, normal)
    abs(denom) < 1e-10 && return nothing
    t = dot(plane_point .- origin, normal) / denom
    t < 0 && return nothing
    return origin .+ t .* dir
end

"""
    _axis_angle_from_rotmatrix(R)

Returns the `axis` and `angle` of the rotation matrix `R` such that `rotate3d(axis, angle) ≈ R`.
"""
function _axis_angle_from_rotmatrix(R::AbstractMatrix{T}) where {T}
    angle = acos(clamp((tr(R) - 1) / 2, -one(T), one(T)))
    angle < 1e-8 && return [0.0, 0.0, 1.0], 0.0
    if angle > π - 1e-6
        # sin(angle) ≈ 0, use the symmetric part of R instead
        S = (R + I) / 2
        d = diag(S)
        i = argmax(d)
        axis = zeros(3)
        axis[i] = sqrt(max(d[i], 0.0))
        for j in 1:3
            j == i && continue
            axis[j] = S[i, j] / axis[i]
        end
        return normalize(axis), angle
    end
    axis = [R[3, 2] - R[2, 3], R[1, 3] - R[3, 1], R[2, 1] - R[1, 2]] ./ (2 * sin(angle))
    return normalize(axis), angle
end

"""Returns the 12 edges of the box `bb` as input for `linesegments`."""
function _bbox_wireframe(bb)
    lo, hi = minimum(bb), maximum(bb)
    c = [Point3f(x, y, z) for x in (lo[1], hi[1]), y in (lo[2], hi[2]), z in (lo[3], hi[3])]
    pts = Point3f[]
    for j in 1:2, k in 1:2
        push!(pts, c[1, j, k], c[2, j, k])
    end
    for i in 1:2, k in 1:2
        push!(pts, c[i, 1, k], c[i, 2, k])
    end
    for i in 1:2, j in 1:2
        push!(pts, c[i, j, 1], c[i, j, 2])
    end
    return pts
end

_shift_pressed(scene) = Keyboard.left_shift in events(scene).keyboardstate ||
                        Keyboard.right_shift in events(scene).keyboardstate

"""Returns whether the `modifier` (a `Keyboard.Button`, or a tuple/vector of them meaning "any of")
is currently held in the `scene`."""
_modifier_held(scene, modifier::Keyboard.Button) = modifier in events(scene).keyboardstate
_modifier_held(scene, modifiers) = any(m -> m in events(scene).keyboardstate, modifiers)

"""Returns a short display name for a `select_modifier` (a `Keyboard.Button`, or a tuple/vector of
them), e.g. `"left_shift"`."""
_modifier_name(btn::Keyboard.Button) = string(btn)
_modifier_name(btns) = join(string.(btns), "/")

# Ctrl (Windows/Linux) or Cmd (macOS) held, used for the undo/redo shortcuts
const _CTRL_OR_CMD_KEYS = (Keyboard.left_control, Keyboard.right_control,
    Keyboard.left_super, Keyboard.right_super)

"""
The name of the `key` in the keyboard layout of the user, e.g. `"z"`, or `nothing` if the backend
does not tell it: only GLMakie does, via GLFW, for the keys that print a character.
"""
function _key_letter(key::Keyboard.Button)
    backend = Makie.current_backend()
    (ismissing(backend) || !isdefined(backend, :GLFW)) && return nothing
    glfw = backend.GLFW
    try
        return glfw.GetKeyName(glfw.Key(Int(key)), 0)
    catch
        # a key that GLFW does not know, or GLFW is not initialized
        return nothing
    end
end

"""
    _layout_key(key::Keyboard.Button, name = _key_letter(key)) -> Keyboard.Button

The key of the letter that the pressed `key` types in the keyboard layout of the user, where it has
the `name`. Makie names a key by its place on a US keyboard, hence the key labelled "Z" of a German
keyboard is `Keyboard.y`: a shortcut that is known by its letter, like `Ctrl`+`z`, compares the
result of this function instead of the key of the event. Returns the `key` itself if it types no
letter of `a` to `z`, or if the layout is not known, see `_key_letter`.
"""
function _layout_key(key::Keyboard.Button, name = _key_letter(key))
    (name isa AbstractString && length(name) == 1) || return key
    c = lowercase(only(name))
    'a' <= c <= 'z' || return key
    return Keyboard.Button(Int(Keyboard.a) + (c - 'a'))
end

_px(scene) = Tuple(Float64.(mouseposition_px(scene)))

_other_mode(mode::Symbol) = mode == :move ? :rotate : :move

"""Formats `x` with 3 significant digits, without a trailing `.0` for integer values."""
function _fmt_sigdigits(x)
    v = round(x, sigdigits = 3)
    return isinteger(v) && abs(v) < 1e15 ? string(Int(v)) : string(v)
end

# Units of the keyboard steps (`factor => unit`, from small to large)
const _STEP_LENGTH_UNITS = (1e-12 => "pm", 1e-9 => "nm", 1e-6 => "µm", 1e-3 => "mm",
    1e-2 => "cm", 1.0 => "m")
const _STEP_ANGLE_UNITS = (1e-9 => "nrad", 1e-6 => "µrad", 1e-3 => "mrad")

"""
Formats `x` with 3 significant digits in the largest of the `units` in which it is at least 1, e.g.
0.005 m as 5 mm and 0.01 m as 1 cm, or in the smallest unit.
"""
function _step_unit_string(x, units)
    i = something(findlast(u -> round(x / first(u), sigdigits = 3) >= 1, units), 1)
    factor, unit = units[i]
    return "$(_fmt_sigdigits(x / factor)) $unit"
end

"""
Returns the current keyboard step of the `mode` in the unit of its size: pm to m for the move and
nrad to mrad for the rotate mode.
"""
function _step_string(mode::Symbol, fine_step, fine_angle)
    return mode == :move ? _step_unit_string(fine_step, _STEP_LENGTH_UNITS) :
           _step_unit_string(fine_angle, _STEP_ANGLE_UNITS)
end

const _SPECTATOR_HINT = "spectator mode, v: edit, h: show controls"

"""
    _default_hint(ctrl) -> String

The line of the controls overlay while its help is hidden (see the key `h`): the spectator hint,
otherwise the mode, the step and the keys, see `_help_hint`.
"""
_default_hint(ctrl) =
    ctrl.spectator[] ? _SPECTATOR_HINT : _help_hint(ctrl.mode[], ctrl.fine_step, ctrl.fine_angle)

function _help_hint(mode::Symbol, fine_step, fine_angle)
    step = _step_string(mode, fine_step, fine_angle)
    return "$mode mode, step $step, +/-: step, m: switch mode, v: spectator, h: show controls"
end

# What a click does by default, see `_drill_select`
const _CLICK_HELP = "select, again: part of a group"

"""
    _HelpEntry(keys, text; combo = false, color = "")

An entry of the help of the controls: the `keys` and the `text` of what they do. A key is the name
on its cap, e.g. `"Esc"`, or `:mouse => "drag"` for an action of the mouse. The `keys` are
alternatives, e.g. `["↑", "↓"]`, or, with `combo`, held together, e.g. `["Ctrl", "Z"]`. `color` is a
word of the `text` that names the color of a gizmo axis (`"red"`, `"green"` or `"blue"`), which a
help card draws in that color.
"""
struct _HelpEntry
    keys::Vector{Any}
    text::String
    combo::Bool
    color::String
end

_HelpEntry(keys, text::AbstractString; combo::Bool = false, color::AbstractString = "") =
    _HelpEntry(collect(Any, keys), String(text), combo, String(color))

"""A titled section of the help of the controls, `title => entries`, see `_help_sections`."""
const _HelpSection = Pair{String, Vector{_HelpEntry}}

# The name of the Ctrl key of undo and redo on its cap
_ctrl_cap() = Sys.isapple() ? "Cmd" : "Ctrl"

"""
    _help_sections(mode, fine_step, fine_angle, select_modifier = nothing; kwargs...)
    _help_sections(ctrl) -> Vector{_HelpSection}

The help of the controls as titled sections of entries (see `_HelpEntry`), from which both the
text of the controls overlay (see `_help_text`) and the help card of the live view are built: the
keys of the `mode` with the current keyboard step, or those of the spectator mode. Of a `ctrl`,
its `help_extra` sections are merged in, e.g. the keys of `live_view`, see `_merge_sections`.

# Keyword arguments

- `click_help = _CLICK_HELP`: what a click does
- `spectator = false`: the entries of the spectator mode instead
- `view_plane = true`: whether the mouse moves objects in the plane of the view, see `_drag_normal`
"""
function _help_sections(mode::Symbol, fine_step, fine_angle, select_modifier = nothing;
        click_help::String = _CLICK_HELP, spectator::Bool = false, view_plane::Bool = true)
    spectator && return _HelpSection["Spectator mode" => [
        _HelpEntry(["V"], "switch to edit mode"),
        _HelpEntry([:mouse => "drag"], "all clicks and drags: camera"),
        _HelpEntry([:mouse => "click"], "components can not be selected or moved")]]
    step = _step_string(mode, fine_step, fine_angle)
    move = mode == :move
    along(color) = move ? "along the $color arrow" : "around the $color ring"
    up, left, page = move ? ("green", "red", "blue") : ("red", "blue", "green")
    click = isnothing(select_modifier) ? Any[:mouse => "click"] :
            Any[_modifier_name(select_modifier), :mouse => "click"]
    return _HelpSection[
        "Select" => [
            _HelpEntry(click, click_help; combo = true),
            _HelpEntry(["Esc"], "enclosing group or deselect")],
        (move ? "Move" : "Rotate") * " the selection" => [
            _HelpEntry(["M"], "switch to $(_other_mode(mode)) mode"),
            _HelpEntry(["↑", "↓"], along(up); color = up),
            _HelpEntry(["←", "→"], along(left); color = left),
            _HelpEntry(["PgUp", "PgDn"], along(page); color = page),
            _HelpEntry([:mouse => "drag"],
                !move ? "rotate around the ring you grab, else the blue ring" :
                view_plane ? "move along the arrow you grab, else in the plane of the view" :
                "move along the arrow you grab, else in the plane";
                color = move ? "" : "blue"),
            _HelpEntry(["+", "−"], "keyboard step, now $step"),
            _HelpEntry(["Shift"], "with a key: 10× step"),
            _HelpEntry(["Bksp"], "reset the pose")],
        "Edit" => [
            _HelpEntry([_ctrl_cap(), "Z"], "undo"; combo = true),
            _HelpEntry([_ctrl_cap(), "Y"], "redo, also $(_ctrl_cap())+Shift+Z"; combo = true)],
        "View" => [
            _HelpEntry([:mouse => "drag"], "beside the selection: camera"),
            _HelpEntry(["V"], "spectator mode: camera only")]]
end

"""
    _merge_sections(sections, extra) -> Vector{_HelpSection}

Returns the `sections` with the entries of the `extra` sections appended to the section of the same
title, or as new sections at the end.
"""
function _merge_sections(sections, extra)
    out = _HelpSection[title => copy(entries) for (title, entries) in sections]
    for (title, entries) in extra
        i = findfirst(s -> s.first == title, out)
        isnothing(i) ? push!(out, title => copy(entries)) : append!(out[i].second, entries)
    end
    return out
end

# The keys of an entry in the text of the controls overlay, e.g. "ctrl+z" or "pgup/pgdn"
_key_text(key::Pair) = String(last(key))
_key_text(key) = replace(lowercase(String(key)), "−" => "-")
_keys_text(e::_HelpEntry) = join(map(_key_text, e.keys), e.combo ? "+" : "/")

"""
    _help_text(sections) -> String
    _help_text(mode, fine_step, fine_angle, select_modifier = nothing; kwargs...)

The text of the controls overlay of the standalone controls: a line per title and per entry of the
`sections` (see `_help_sections`, to which the other arguments are passed), then the key `h`.
"""
function _help_text(sections::AbstractVector{<:Pair})
    lines = String[]
    for (title, entries) in sections
        push!(lines, title)
        append!(lines, ("  " * _keys_text(e) * ": " * e.text for e in entries))
    end
    push!(lines, "h: hide controls")
    return join(lines, "\n")
end
_help_text(mode::Symbol, args...; kwargs...) = _help_text(_help_sections(mode, args...; kwargs...))

const _STEP_MANTISSAS = (1.0, 2.0, 5.0)
# Bounds of the keyboard steps, changed via + and -
const _FINE_STEP_LIMITS = (1e-12, 1.0)
const _FINE_ANGLE_LIMITS = (1e-9, π / 4)

"""
    _next_step(x, dir::Int)

Returns the next value after `x > 0` in the 1-2-5 sequence (…, 1, 2, 5, 10, 20, …) in the direction
`dir` (`1`: up, `-1`: down). If `x` is not a value of the sequence, the next value of the sequence
in the direction `dir` is returned.
"""
function _next_step(x::Real, dir::Int)
    x > 0 || throw(ArgumentError("step must be positive, got $x"))
    dir in (-1, 1) || throw(ArgumentError("dir must be -1 or 1, got $dir"))
    e = floor(log10(x))
    # Adjacent decades as well, in case of rounding errors of log10
    grid = [k * 10.0^d for d in (e - 1):(e + 2) for k in _STEP_MANTISSAS]
    i = findfirst(g -> isapprox(x, g; rtol = 1e-6), grid)
    isnothing(i) || return grid[i + dir]
    return dir > 0 ? grid[findfirst(>(x), grid)] : grid[findlast(<(x), grid)]
end

# Green, red and blue axes of the controls: local y-axis, local x-axis and rotation axis
const _AXES_COLORS = [:green, :red, :blue]
# Symbols of the gizmo axes in the same order as _AXES_COLORS, and as accepted by `constraints`
const _AXES_SYMS = (:y, :x, :v)
const _GIZMO_AXES = (:x, :y, :v)
const _GIZMO_FADE_ALPHA = 0.15
const _RING_RES = 32
# Pick radius of the rings [px], share of white of the ring under the cursor, and the smallest
# cosine of the angle between the view and the axis of a ring below which its plane is seen edge-on
const _RING_PICK_RADIUS = 8.0
const _RING_HOVER_BRIGHTEN = 0.55
const _RING_EDGE_ON = 0.15
# The part of an arrow of the gizmo from its start that is not grabbed, where the three arrows meet:
# a quarter of its length, and at least this distance on the screen [px], such that an object that
# is small on the screen and lies under the start of the arrows, e.g. seen from above, is still
# grabbed itself. An arrow that is shorter on the screen, e.g. one that points at the camera, is
# not grabbed at all
const _ARROW_PICK_START = 0.25
const _ARROW_PICK_FREE = 20.0

"""
    _ring_basis(a) -> (e1, e2)

The unit vectors of the plane of the ring around the unit vector `a`: `a`, `e1`, `e2` are a
right-handed frame, i.e. the ring runs counterclockwise about `a` from `e1` to `e2`.
"""
function _ring_basis(a)
    e1 = normalize(cross(a, abs(a[1]) < 0.9 ? [1, 0, 0] : [0, 1, 0]))
    return e1, cross(a, e1)
end

"""
    _gizmo(mode, origin, axes, l)

Returns the arrows, labels and rings that visualize the controls `axes` at the `origin`. In the
move mode, the arrows of length `l` point along the `axes`. In the rotate mode, the arrows mark the
positive direction of rotation on rings with radius `l` around the `axes`.
"""
function _gizmo(mode::Symbol, origin, axes, l)
    r = l
    arrow_pos = Point3f[]
    arrow_dir = Vec3f[]
    label_pos = Point3f[]
    ring_pts = Point3f[]
    for a in axes
        e1, e2 = _ring_basis(a)
        ts = LinRange(0, 1.5π, _RING_RES + 1)
        for i in 1:_RING_RES
            push!(ring_pts, Point3f(origin + r * (cos(ts[i]) * e1 + sin(ts[i]) * e2)))
            push!(ring_pts, Point3f(origin + r * (cos(ts[i + 1]) * e1 + sin(ts[i + 1]) * e2)))
        end
        if mode == :move
            push!(arrow_pos, Point3f(origin))
            push!(arrow_dir, Vec3f(l * a))
            push!(label_pos, Point3f(origin + 1.2 * l * a))
        else
            # Arrow tip at the end of the ring, label on the axis of the ring
            t = last(ts)
            push!(arrow_pos, Point3f(origin + r * (cos(t) * e1 + sin(t) * e2)))
            push!(arrow_dir, Vec3f(0.35 * r * (-sin(t) * e1 + cos(t) * e2)))
            push!(label_pos, Point3f(origin + 1.3 * r * a))
        end
    end
    return arrow_pos, arrow_dir, label_pos, ring_pts
end

"""
    _RingDrag

The state of a mouse drag on a ring of the gizmo in the rotate mode: the `sym` (`:x`, `:y` or `:v`)
and the unit vector `axis` of the ring and its `center` [m] at the press, which stay fixed during
the drag (the gizmo rests meanwhile, see `_update_selection_box!`), the angle `θ` [rad] of the
cursor on the plane of the ring at the last step (`nothing` if it was seen edge-on), and the
`tangent` of the ring at the press, a unit vector in pixels, which turns the movement of the cursor
into an angle if the plane is seen edge-on.
"""
mutable struct _RingDrag
    sym::Symbol
    axis::Vector{Float64}
    center::Vector{Float64}
    θ::Union{Nothing, Float64}
    tangent::NTuple{2, Float64}
end

"""
    _ArrowDrag

The state of a mouse drag on an arrow of the gizmo in the move mode: the `sym` (`:x`, `:y` or `:v`)
and the unit vector `axis` of the arrow and the `origin` [m] of the gizmo at the press, i.e. the
line along which the object is moved, which stays fixed during the drag, and the coordinate `s` [m]
of the cursor along that line at the last step (`nothing` if the line was seen end-on), see
`_arrow_coordinate`.
"""
mutable struct _ArrowDrag
    sym::Symbol
    axis::Vector{Float64}
    origin::Vector{Float64}
    s::Union{Nothing, Float64}
end

"""One entry of the undo history of [`kinematic_controls!`](@ref): the pose of `obj` before and
after one gesture (a mouse drag, a reset or one or several merged keyboard steps)."""
struct _HistoryEntry
    obj::_LiveMovable
    P0::Point3{Float64}
    R0::Matrix{Float64}
    P1::Point3{Float64}
    R1::Matrix{Float64}
end

"""
An entry of the undo history that is no change of a pose: an action on `obj`, e.g. adding it to or
removing it from the [`live_view`](@ref), which `undo()` takes back and `redo()` does again, see
`_push_action!`.
"""
struct _ActionEntry
    obj::Any
    undo::Function
    redo::Function
end

# The entries of the undo history, in the order of the gestures and actions
const _AnyHistoryEntry = Union{_HistoryEntry, _ActionEntry}

# Last key step, see `_record_key_step!`
const _KeyStepInfo = NamedTuple{(:obj, :key, :time), Tuple{_LiveMovable, Keyboard.Button, Float64}}

"""
    KinematicController

Returned by [`kinematic_controls!`](@ref). The currently selected object is stored in the
`selected` `Observable`, the current mode (`:move` or `:rotate`) in the `mode` `Observable`. Use
`close` to remove the controls.
"""
mutable struct KinematicController{H <: AbstractSystemRenderHandle}
    ax::_Axis
    h::H
    movable::Vector{_LiveMovable}
    init_poses::IdDict{_LiveMovable, Tuple{Point3{Float64}, Matrix{Float64}}}
    selected::Observable{Union{Nothing, _LiveMovable}}
    mode::Observable{Symbol}
    on_change::Function
    # normal of the plane of the mouse drags, `nothing` for the plane of the view, see `_drag_normal`
    plane_normal::Union{Nothing, Vector{Float64}}
    rotation_axis::Vector{Float64}
    rotate_speed::Float64
    fine_step::Float64
    fine_angle::Float64
    throttle::Bool
    # all input goes to the camera, toggled via v
    spectator::Observable{Bool}
    select_modifier::Any
    drag_threshold::Float64
    # locked move/rotate axes per object, see the `constraints` kwarg
    constraints::IdDict{Any, NamedTuple}
    # screen-space pick radius of sources [px]
    source_pick_radius::Float64
    # disables all keyboard handling while true, e.g. a focused text field elsewhere in the figure
    ignore_keys::Function
    # interaction state
    dirty::Bool
    dragging::Bool
    plane_point::Vector{Float64}
    grab_offset::Vector{Float64}
    last_mouse::NTuple{2, Float64}
    press_pos::Union{Nothing, NTuple{2, Float64}}
    press_leaf::Union{Nothing, _LiveMovable}
    press_kind::Symbol
    # pose of the selected object at the start of the current drag, for the undo history
    drag_start::Union{Nothing, Tuple{Point3{Float64}, Matrix{Float64}}}
    # undo/redo history, one entry per gesture, see `_push_history!` / `_record_key_step!`
    undo_stack::Vector{_AnyHistoryEntry}
    redo_stack::Vector{_AnyHistoryEntry}
    last_key_step::Union{Nothing, _KeyStepInfo}
    # selection box and gizmo of the keyboard controls
    box_obs::Observable{Vector{Point3f}}
    arrow_pos::Observable{Vector{Point3f}}
    arrow_dir::Observable{Vector{Vec3f}}
    label_pos::Observable{Vector{Point3f}}
    ring_pts::Observable{Vector{Point3f}}
    arrow_color::Observable{Vector{Makie.RGBAf}}
    label_color::Observable{Vector{Makie.RGBAf}}
    ring_color::Observable{Vector{Makie.RGBAf}}
    gizmo_size::Observable{Float64}
    gizmo_visible::Observable{Bool}
    # controls overlay, toggled via h
    help_obs::Observable{String}
    help_shown::Bool
    # additional sections of the help, e.g. the keys of `live_view`, see `_merge_sections`
    help_extra::Vector{_HelpSection}
    # `ctrl -> nothing`, shows the help instead of the text of the overlay, called after each change
    # of what it shows (see `_update_help!`); `nothing` for the text, e.g. `live_view` shows a card
    help_view::Union{Nothing, Function}
    plots::Vector{AbstractPlot}
    listeners::Vector{Any}
    # last error of on_change, logged only once
    last_error::Union{Nothing, String}
    # called after each click (not a drag) with the selected object, or `nothing` for a click on the
    # background; if it returns `true` for the background, the selection is kept, see `live_view`
    on_click::Function
    # called before each change of an object, see `_change!`
    before_change::Function
    # presses are left to other listeners while true, e.g. over the widgets of the component card of
    # `live_view` or its sidebars; releases are handled, such that a drag that started elsewhere
    # ends, but the release of an ignored press neither selects nor deselects
    ignore_mouse::Function
    # the `pick` kwarg, `nothing` for the ray pick
    pick::Any
    # called after a click (not a drag) on the movable rendered object `leaf` before the selection
    # changes; if it returns `true`, it took the click: the selection is kept and `on_click` is not
    # called, e.g. `live_view` opens the selection card of a group instead, see `_browse!`
    click_leaf::Function
    # what a click does, in the help, see `_help_sections`
    click_help::String
    # snapping of the mouse drags onto beams, see `_set_snap!`: `:off`, `:position` (the position of
    # the dragged object) or `:pose` (its optical axis as well)
    snap::Observable{Symbol}
    # `(obj, point) -> (; point, direction)`, or `nothing`: the point of a beam that `obj` snaps
    # onto when it is dragged to the `point` [m], with the direction of the beam there. Without
    # beams nothing snaps; `live_view` knows them, see `_snap_beam`
    snap_beam::Function
    # `(obj, point) -> (; point, direction)`, or `nothing`: the point of a grid that `obj` snaps onto
    # when it is dragged to the `point` [m] beside the beams, with a direction of the grid, to which
    # its rotation snaps; `live_view` has the holes of its table, see `_table_snap`
    snap_grid::Function
    # number of drags so far, such that `snap_beam` can tell a new drag
    drag_count::Int
    # rotation of the current drag in the rotate mode: the angle by the mouse and the angle that is
    # applied [rad], which differ while snapped, and the angle of the optical axis of the object to
    # the beam at its start, `nothing` without a beam, see `_snap_angle`
    drag_angle::Float64
    drag_applied::Float64
    drag_beam_angle::Union{Nothing, Float64}
    # center of the gizmo, i.e. of its rings [m], set by `_update_selection_box!`
    gizmo_origin::Vector{Float64}
    # the ring (`:x`, `:y` or `:v`) under the cursor, highlighted, see `_update_hover!`, or `nothing`
    ring_hover::Union{Nothing, Symbol}
    # the drag of a ring in the rotate mode, from its press to its release, see `_pick_ring`
    ring::Union{Nothing, _RingDrag}
    # likewise the arrow under the cursor and the drag of an arrow in the move mode, see `_pick_arrow`
    arrow_hover::Union{Nothing, Symbol}
    arrow::Union{Nothing, _ArrowDrag}
end

function Base.show(io::IO, ctrl::KinematicController)
    obj = ctrl.selected[]
    sel = isnothing(obj) ? "none" : string(nameof(typeof(obj)))
    print(io, "KinematicController(", length(ctrl.movable), " movable, selected = ", sel,
        ", mode = ", ctrl.mode[], ")")
end

"""Returns the objects of the group `obj`, or an empty vector if `obj` is not a group."""
_children(obj) = obj isa BMO.AbstractObjectGroup ? collect(_LiveMovable, BMO.shape(obj)) :
                 _LiveMovable[]

"""Returns all objects of the group `obj` that are not groups themselves (recursively), or `[obj]`."""
function _leaves(obj)
    obj isa BMO.AbstractObjectGroup || return _LiveMovable[obj]
    return reduce(vcat, (_leaves(c) for c in BMO.shape(obj)); init = _LiveMovable[])
end

"""Returns the `obj` and all its nested objects and subgroups (recursively)."""
function _descendants(obj)
    out = _LiveMovable[obj]
    for c in _children(obj)
        append!(out, _descendants(c))
    end
    return out
end

"""Returns the chain `[leaf, parent of leaf, …, top-level object]` of the hierarchy of `ctrl.h`."""
function _chain(ctrl, leaf)
    chain = _LiveMovable[leaf]
    parent = render_parent(ctrl.h, leaf)
    while !isnothing(parent)
        push!(chain, parent)
        parent = render_parent(ctrl.h, parent)
    end
    return chain
end

"""An object is movable if its top-level object is one of the movable objects of the `ctrl`."""
function _is_movable(ctrl::KinematicController, obj)
    top = _top_level(ctrl.h, obj)
    return any(o -> o === top, ctrl.movable)
end

function _object_plots(h::AbstractSystemRenderHandle, obj)
    plots = AbstractPlot[]
    for leaf in _leaves(obj)
        oh = _child_handle(h, leaf)
        isnothing(oh) || append!(plots, _pickable_plots(oh))
    end
    return plots
end

"""Returns `true` if all plots of the rendered object `leaf` are invisible, e.g. hidden via the
component menu of `live_view`. Such objects can not be selected in the 3D view."""
_is_hidden(ctrl::KinematicController, leaf) = _is_hidden(_object_plots(ctrl.h, leaf))
_is_hidden(plots::AbstractVector) = !isempty(plots) && all(p -> !p.visible[], plots)

"""
    _pickable(ctrl, leaf) -> Bool

Returns `true` if a click in the 3D view can select the rendered object `leaf` of the `ctrl`, i.e.
the ray pick and the pick of the plot under the cursor consider it. Decided by the type of `leaf`
and its plots, see `_pickable(ctrl, leaf, plots)`: by default, objects that are not hidden (see
`_is_hidden`). Objects that are not pickable can still be selected otherwise, e.g. via the component
menu or the object tree of `live_view`.
"""
_pickable(ctrl::KinematicController, leaf) = _pickable(ctrl, leaf, _object_plots(ctrl.h, leaf))
_pickable(::KinematicController, _, plots) = !_is_hidden(plots)

"""
    _drill_select(ctrl, leaf)

Returns the new selection after a click on the `leaf`: the top-level object of the `leaf` on the
first click, then one level further down the hierarchy towards the `leaf` on each further click.
"""
function _drill_select(ctrl::KinematicController, leaf)
    chain = _chain(ctrl, leaf)
    sel = ctrl.selected[]
    i = isnothing(sel) ? nothing : findfirst(o -> o === sel, chain)
    isnothing(i) && return last(chain)
    return chain[max(i - 1, 1)]
end

"""
    _click_leaf!(ctrl, leaf)

A click on the rendered object `leaf`: left to `click_leaf` of the `ctrl` if it takes it, otherwise
selects the next level of the hierarchy towards `leaf` (see `_drill_select`) and calls `on_click`.
"""
function _click_leaf!(ctrl::KinematicController, leaf)
    ctrl.click_leaf(leaf) && return nothing
    ctrl.selected[] = _drill_select(ctrl, leaf)
    _update_selection_box!(ctrl)
    ctrl.on_click(ctrl.selected[])
    return nothing
end

"""
    _control_axes(ctrl, obj) -> (y, x, v)

Axes of the controls of `obj`, i.e. of its gizmo, the keyboard and the mouse: its local y-axis, its
local x-axis and the rotation axis of the `ctrl`. They must span the space, otherwise `obj` can not
be moved in one direction. A local axis that is parallel to the rotation axis (`|a × v| < 10⁻⁶`) is
therefore replaced by the axis perpendicular to the other local axis and the rotation axis, e.g. the
local x-axis of a `CollimatedSource` along +y, which points along -z, by +x. The direction of the
replaced axis stays available as the rotation axis.
"""
function _control_axes(ctrl::KinematicController, obj)
    R = _pose(obj)[2]
    y, x, v = Vector{Float64}(R[:, 2]), Vector{Float64}(R[:, 1]), ctrl.rotation_axis
    parallel(a) = norm(cross(a, v)) < 1e-6
    if parallel(x) && !parallel(y)
        x = normalize(cross(y, v))
    elseif parallel(y) && !parallel(x)
        y = normalize(cross(v, x))
    end
    return (y, x, v)
end

"""Returns the vectors of the gizmo axes `syms` (a subset of `:x`, `:y`, `:v`) of `obj`."""
function _axis_vectors(ctrl::KinematicController, obj, syms)
    y, x, v = _control_axes(ctrl, obj)
    lookup = (y = y, x = x, v = v)
    return [lookup[s] for s in syms]
end

"""Returns the constraints `NamedTuple` of `obj` (`(; move, rotate)`, either field possibly
missing), or `(;)` if `obj` has no entry in `ctrl.constraints`."""
_constraints_of(ctrl::KinematicController, obj) = get(ctrl.constraints, obj, (;))

"""Returns the allowed axes (a tuple of `:x`, `:y`, `:v`) of `obj` for `kind` (`:move` or
`:rotate`), all axes by default."""
function _allowed_axes(ctrl::KinematicController, obj, kind::Symbol)
    return get(_constraints_of(ctrl, obj), kind, _GIZMO_AXES)
end

"""Validates the `constraints` kwarg of [`kinematic_controls!`](@ref)."""
function _validate_constraints(constraints)
    for (obj, c) in constraints
        for k in keys(c)
            k in (:move, :rotate) ||
                throw(ArgumentError("invalid constraints field :$k, use :move or :rotate"))
        end
        for kind in (:move, :rotate)
            haskey(c, kind) || continue
            for a in c[kind]
                a in _GIZMO_AXES ||
                    throw(ArgumentError("invalid constraint axis :$a for :$kind, use :x, :y or :v"))
            end
        end
    end
    return nothing
end

"""Returns the colors of the gizmo axes `[y, x, v]` (green, red, blue) of `obj`'s `kind` controls
(`:move` or `:rotate`), faded to indicate axes locked by the `constraints`."""
function _gizmo_colors(ctrl::KinematicController, obj, kind::Symbol)
    allowed = _allowed_axes(ctrl, obj, kind)
    colors = Makie.RGBAf[]
    for (sym, c) in zip(_AXES_SYMS, _AXES_COLORS)
        rgba = Makie.RGBAf(Makie.to_color(c))
        push!(colors, sym in allowed ? rgba : Makie.RGBAf(rgba.r, rgba.g, rgba.b, _GIZMO_FADE_ALPHA))
    end
    return colors
end

"""Returns the colors of the line segments of the rings for the `colors` of the axes: the ring under
the cursor, see `ctrl.ring_hover`, is brighter."""
function _ring_colors(ctrl::KinematicController, colors)
    out = repeat(colors; inner = 2 * _RING_RES)
    i = findfirst(==(ctrl.ring_hover), _AXES_SYMS)
    isnothing(i) && return out
    for k in ((i - 1) * 2 * _RING_RES + 1):(i * 2 * _RING_RES)
        c = out[k]
        out[k] = Makie.RGBAf(c.r + _RING_HOVER_BRIGHTEN * (1 - c.r), c.g + _RING_HOVER_BRIGHTEN * (1 - c.g),
            c.b + _RING_HOVER_BRIGHTEN * (1 - c.b), c.alpha)
    end
    return out
end

"""Returns the colors of the arrows of the gizmo for the `colors` of the axes: the arrow under the
cursor, see `ctrl.arrow_hover`, is brighter, like the ring under the cursor."""
function _arrow_colors(ctrl::KinematicController, colors)
    i = findfirst(==(ctrl.arrow_hover), _AXES_SYMS)
    isnothing(i) && return colors
    out = copy(colors)
    c = out[i]
    out[i] = Makie.RGBAf(c.r + _RING_HOVER_BRIGHTEN * (1 - c.r), c.g + _RING_HOVER_BRIGHTEN * (1 - c.g),
        c.b + _RING_HOVER_BRIGHTEN * (1 - c.b), c.alpha)
    return out
end

_help_sections(ctrl::KinematicController) = _merge_sections(
    _help_sections(ctrl.mode[], ctrl.fine_step, ctrl.fine_angle, ctrl.select_modifier;
        ctrl.click_help, spectator = ctrl.spectator[], view_plane = isnothing(ctrl.plane_normal)),
    ctrl.spectator[] ? _HelpSection[] : ctrl.help_extra)

"""
Updates the help of the `ctrl` after a change of what it shows (shown or hidden, mode, step,
spectator mode, entries): its `help_view`, if any, otherwise the text of the controls overlay.
"""
function _update_help!(ctrl::KinematicController)
    if !isnothing(ctrl.help_view)
        ctrl.help_view(ctrl)
        return nothing
    end
    ctrl.help_obs[] = ctrl.help_shown ? _help_text(_help_sections(ctrl)) : _default_hint(ctrl)
    return nothing
end

"""Changes the keyboard step of the current mode of the `ctrl` by one value of the 1-2-5 sequence."""
function _change_step!(ctrl::KinematicController, dir::Int)
    if ctrl.mode[] == :move
        ctrl.fine_step = clamp(_next_step(ctrl.fine_step, dir), _FINE_STEP_LIMITS...)
    else
        ctrl.fine_angle = clamp(_next_step(ctrl.fine_angle, dir), _FINE_ANGLE_LIMITS...)
    end
    _update_help!(ctrl)
    return nothing
end

_is_finite_box(bb) = all(isfinite, minimum(bb)) && all(isfinite, maximum(bb))

"""
    _selection_bbox(ctrl, obj, plots)

Returns the bounding box of the `plots` of the selected `obj`. With clip planes, see
[`live_view`](@ref), the bounding box of a plot only covers its visible part and is empty if the
plot is clipped entirely. Such plots are skipped; if all are clipped, a box around the `position`
of `obj` is returned, with the edge length of a source marker (8 % of the visible scene, or 1 cm).
"""
function _selection_bbox(ctrl::KinematicController, obj, plots)
    bbs = filter(_is_finite_box, [Makie.boundingbox(p) for p in plots])
    isempty(bbs) || return reduce(GeometryBasics.union, bbs)
    all_plots = render_plots(ctrl.h)
    scene_bbs = filter(_is_finite_box, [Makie.boundingbox(p) for p in all_plots])
    w = isempty(scene_bbs) ? 1e-2 :
        0.08 * maximum(GeometryBasics.widths(reduce(GeometryBasics.union, scene_bbs)))
    return GeometryBasics.Rect3d(Vector{Float64}(position(obj)) .- w / 2, fill(w, 3))
end

# Largest object size that scales the gizmo, relative to the typical object, see `_gizmo_cap`
const _GIZMO_MAX_TYPICAL = 3.0

"""
    _gizmo_cap(ctrl) -> Float64

Largest size of an object that the gizmo scales with: `_GIZMO_MAX_TYPICAL` times the size of a
typical object of the `ctrl`, i.e. the median of the largest edge of the bounding boxes of the
visible plots of the rendered objects; `Inf` without visible objects. The gizmo is scaled with the
selected object (see `_update_selection_box!`), which gives a huge gizmo for a large object, e.g. a
housing around the optics; with the cap, it stays in proportion to the components. Objects of the
typical size are not affected, nor are the objects of a scene with one or two objects.
"""
function _gizmo_cap(ctrl::KinematicController)
    sizes = Float64[]
    for oh in render_children(ctrl.h)
        bbs = filter(_is_finite_box, [Makie.boundingbox(p) for p in render_plots(oh) if p.visible[]])
        isempty(bbs) || push!(sizes, maximum(GeometryBasics.widths(reduce(GeometryBasics.union, bbs))))
    end
    isempty(sizes) && return Inf
    sort!(sizes)
    n = length(sizes)
    typical = isodd(n) ? sizes[(n + 1) ÷ 2] : (sizes[n ÷ 2] + sizes[n ÷ 2 + 1]) / 2
    return _GIZMO_MAX_TYPICAL * typical
end

function _update_selection_box!(ctrl::KinematicController)
    obj = ctrl.selected[]
    plots = isnothing(obj) ? AbstractPlot[] : _object_plots(ctrl.h, obj)
    if isempty(plots)
        isempty(ctrl.box_obs[]) || (empty!(ctrl.box_obs[]); notify(ctrl.box_obs))
        ctrl.gizmo_visible[] && (ctrl.gizmo_visible[] = false)
        ctrl.ring_hover = ctrl.arrow_hover = nothing
        return nothing
    end
    bb = _selection_bbox(ctrl, obj, plots)
    ctrl.box_obs[] = _bbox_wireframe(bb)
    # Place the gizmo above the object, where it is not covered by beams through the object
    w = GeometryBasics.widths(bb)
    l = (ctrl.mode[] == :move ? 1.2 : 0.8) * min(maximum(w), _gizmo_cap(ctrl))
    v = ctrl.rotation_axis
    offset = ctrl.mode[] == :move ? 0.3 * l : 1.4 * l
    origin = Vector{Float64}(position(obj)) + (dot(abs.(v), w) / 2 + offset) * v
    # The gizmo rests while one of its rings is dragged: the bounding box changes with the rotation
    # of the object, and a ring that moves away under the cursor would turn the object further
    if ctrl.dragging && !isnothing(ctrl.ring)
        l, origin = ctrl.gizmo_size[], ctrl.ring.center
    end
    arrow_pos, arrow_dir, label_pos, ring_pts = _gizmo(ctrl.mode[], origin, _control_axes(ctrl, obj), l)
    ctrl.gizmo_origin = origin
    ctrl.arrow_pos.val = arrow_pos
    ctrl.arrow_dir.val = arrow_dir
    ctrl.label_pos.val = label_pos
    ctrl.ring_pts.val = ring_pts
    ctrl.gizmo_size.val = l
    colors = _gizmo_colors(ctrl, obj, ctrl.mode[])
    ctrl.mode[] == :move || (ctrl.arrow_hover = nothing)
    ctrl.arrow_color.val = _arrow_colors(ctrl, colors)
    ctrl.label_color.val = colors
    ctrl.mode[] == :rotate || (ctrl.ring_hover = nothing)
    ctrl.ring_color.val = _ring_colors(ctrl, colors)
    foreach(notify, (ctrl.gizmo_size, ctrl.arrow_pos, ctrl.arrow_dir, ctrl.label_pos, ctrl.ring_pts,
        ctrl.arrow_color, ctrl.label_color, ctrl.ring_color))
    ctrl.gizmo_visible[] || (ctrl.gizmo_visible[] = true)
    return nothing
end

function _request_update!(ctrl::KinematicController)
    if ctrl.throttle
        ctrl.dirty = true
    else
        _apply_update!(ctrl)
    end
    return nothing
end

function _apply_update!(ctrl::KinematicController)
    ctrl.dirty = false
    update_render!(ctrl.h)
    _update_selection_box!(ctrl)
    obj = ctrl.selected[]
    isnothing(obj) && return nothing
    # Errors must not propagate into the render loop
    try
        ctrl.on_change(obj)
        ctrl.last_error = nothing
    catch e
        msg = sprint(showerror, e)
        if msg != ctrl.last_error
            @error "kinematic_controls!: `on_change` callback failed" exception = (e, catch_backtrace())
            ctrl.last_error = msg
        end
    end
    return nothing
end

"""
    _change!(f, ctrl::KinematicController, obj)

Changes `obj` by calling `f()` after the `before_change` hook of the `ctrl`, which e.g. stops a
solve of the [`live_view`](@ref) that traces the objects in a background task. All changes of
objects by the controls and the live view go through here, the callers do not stop solves
themselves. Clip planes are not traced and change without the hook.
"""
function _change!(f, ctrl::KinematicController, obj)
    ctrl.before_change()
    f()
    return nothing
end

_change!(f, ::KinematicController, ::LiveClipPlane) = (f(); nothing)

"""
    _set_pose!(obj, P, R)

Sets the pose of `obj` to position `P` and orientation `R`, by rotating around the axis-angle of
`R * orientation(obj)'` and then translating to `P`.
"""
function _set_pose!(obj, P, R)
    axis, angle = _axis_angle_from_rotmatrix(R * _pose(obj)[2]')
    angle > 1e-12 && rotate3d!(obj, axis, angle)
    translate_to3d!(obj, P)
    return nothing
end

function _reset_pose!(ctrl::KinematicController, obj)
    P0, R0 = ctrl.init_poses[obj]
    _change!(() -> _set_pose!(obj, P0, R0), ctrl, obj)
    return nothing
end

#=
Snapping of the mouse drags onto beams
=#

# The states of the snapping in the order of `_cycle_snap!`, see `_set_snap!`
const _SNAP_STATES = (:off, :position, :pose)
# The angles of the optical axis to the beam at which a rotation snaps, and how close it snaps [rad]
const _SNAP_ANGLE_STEP = π / 4
const _SNAP_ANGLE_TOLERANCE = deg2rad(5)

"""
    _set_snap!(ctrl, snap)

Sets the snapping of the mouse drags of the controls `ctrl`: `:off` (or `false`), `:position` (or
`true`) or `:pose`. While it is on, an object that is dragged in the move mode to a beam (see
`ctrl.snap_beam`) sits on the beam; with `:pose`, its optical axis (the local y-axis) also points
along the beam, and has the orientation of the start of the drag beside the beams. In the rotate
mode, the angle of the optical axis to the beam through the object snaps to the multiples of
`_SNAP_ANGLE_STEP`, see `_snap_angle`. The keyboard steps do not snap.
"""
function _set_snap!(ctrl::KinematicController, snap::Symbol)
    snap in _SNAP_STATES ||
        throw(ArgumentError("snap must be false, true, :position or :pose, got :$snap"))
    ctrl.snap[] == snap || (ctrl.snap[] = snap)
    _update_help!(ctrl)
    return nothing
end
_set_snap!(ctrl::KinematicController, snap::Bool) = _set_snap!(ctrl, snap ? :position : :off)

"""
    _cycle_snap!(ctrl, dir = 1)

Switches the snapping of the controls `ctrl` to its next state: off, `:position`, `:pose` and off
again, with `dir = -1` the other way round, see `_set_snap!`.
"""
function _cycle_snap!(ctrl::KinematicController, dir::Integer = 1)
    i = findfirst(==(ctrl.snap[]), _SNAP_STATES)
    return _set_snap!(ctrl, _SNAP_STATES[mod1(i + dir, length(_SNAP_STATES))])
end

# What the snapping of the controls does, for the chip and the status line
_snap_string(snap::Symbol) = snap == :off ? "off" : snap == :pose ? "position + rotation" : "position"

"""
Returns the signed angle [rad] about the unit vector `axis` from the direction `d` to the direction
`y`, both projected onto the plane perpendicular to it; `nothing` if one of them is parallel to it.
"""
function _angle_about(axis, d, y)
    dp = d .- dot(d, axis) .* axis
    yp = y .- dot(y, axis) .* axis
    (norm(dp) < 1e-9 || norm(yp) < 1e-9) && return nothing
    return atan(dot(axis, cross(dp, yp)), dot(dp, yp))
end

"""
Starts the snapping of a drag of `obj` by the controls `ctrl`: a new drag for `ctrl.snap_beam`,
and for the rotate mode the angle of the optical axis of `obj` to the beam through its position,
see `_snap_angle`; without such a beam, or with the snapping onto beams switched off, its angle to
the direction of the grid at its position (see `ctrl.snap_grid`), if there is one.
"""
function _start_snap!(ctrl::KinematicController, obj)
    ctrl.drag_count += 1
    ctrl.drag_angle = ctrl.drag_applied = 0.0
    ctrl.drag_beam_angle = nothing
    ctrl.mode[] == :rotate || return nothing
    P, R = _pose(obj)
    beam = ctrl.snap[] == :off ? nothing : ctrl.snap_beam(obj, Vector{Float64}(P))
    # beside the beams, the angle to the grid
    isnothing(beam) && (beam = ctrl.snap_grid(obj, Vector{Float64}(P)))
    isnothing(beam) && return nothing
    ctrl.drag_beam_angle = _angle_about(ctrl.rotation_axis, Vector{Float64}(beam.direction), R[:, 2])
    return nothing
end

"""
    _snap_angle(angle, beam_angle) -> Float64

The angle [rad] by which an object is rotated in a drag for the `angle` by the mouse, if its optical
axis had the angle `beam_angle` to the beam at the start of the drag: within
`_SNAP_ANGLE_TOLERANCE` of a multiple of `_SNAP_ANGLE_STEP` to the beam, the angle that reaches
the multiple, otherwise the `angle` itself, also without a beam (`nothing`).
"""
function _snap_angle(angle::Real, beam_angle::Real)
    φ = beam_angle + angle
    snapped = round(φ / _SNAP_ANGLE_STEP) * _SNAP_ANGLE_STEP
    return abs(φ - snapped) <= _SNAP_ANGLE_TOLERANCE ? angle + (snapped - φ) : Float64(angle)
end
_snap_angle(angle::Real, ::Nothing) = Float64(angle)

"""
Returns the angle [rad] by which the object of the current drag of the controls `ctrl` is rotated
for the step `δ` of the mouse: the step itself, or, with a beam to snap to, the step to the snapped
angle of the drag, see `_snap_angle`.
"""
function _snap_rotation!(ctrl::KinematicController, δ::Real)
    isnothing(ctrl.drag_beam_angle) && return Float64(δ)
    ctrl.drag_angle += δ
    step = _snap_angle(ctrl.drag_angle, ctrl.drag_beam_angle) - ctrl.drag_applied
    ctrl.drag_applied += step
    return step
end

"""
    _snap_orientation(ctrl, obj, snapped) -> Union{Nothing, Matrix{Float64}}

The orientation of `obj` in a drag of the controls `ctrl` in the move mode with the snapping
`:pose`: on a beam (`snapped`, see `ctrl.snap_beam`), the orientation of the start of the drag,
turned such that the optical axis (the local y-axis) points along the beam, in the direction or
against it, whichever is closer; beside the beams (`nothing`), the orientation of the start of the
drag. `nothing` if the orientation is not changed: without `:pose`, and for an object whose
rotation is constrained.
"""
function _snap_orientation(ctrl::KinematicController, obj, snapped)
    (ctrl.snap[] == :pose && !isnothing(ctrl.drag_start)) || return nothing
    Set(_allowed_axes(ctrl, obj, :rotate)) == Set(_GIZMO_AXES) || return nothing
    R0 = ctrl.drag_start[2]
    isnothing(snapped) && return R0
    y = R0[:, 2]
    d = Vector{Float64}(snapped.direction)
    dot(y, d) < 0 && (d = -d)
    return _align_rotation(y, d, ctrl.rotation_axis) * R0
end

const _HISTORY_LIMIT = 100

"""
    _push_history!(ctrl, obj, P0, R0, P1, R1)

Pushes a new undo entry moving `obj` from the pose `(P0, R0)` to `(P1, R1)`, unless nothing
changed. Starts a new gesture: clears the redo stack and drops the oldest entry once the history
exceeds `_HISTORY_LIMIT`.
"""
function _push_history!(ctrl::KinematicController, obj, P0, R0, P1, R1)
    (P0 == P1 && R0 == R1) && return nothing
    push!(ctrl.undo_stack, _HistoryEntry(obj, P0, R0, P1, R1))
    length(ctrl.undo_stack) > _HISTORY_LIMIT && popfirst!(ctrl.undo_stack)
    empty!(ctrl.redo_stack)
    return nothing
end

"""
    _record_key_step!(ctrl, obj, key, P0, R0, P1, R1)

Records a keyboard step of `obj` from `(P0, R0)` to `(P1, R1)` in the undo history. A step of the
same `key` on the same `obj` as the previous one, no more than 1 s apart, is merged into the same
entry instead of pushing a new one.
"""
function _record_key_step!(ctrl::KinematicController, obj, key, P0, R0, P1, R1)
    (P0 == P1 && R0 == R1) && return nothing
    now = time()
    m = ctrl.last_key_step
    if !isnothing(m) && m.obj === obj && m.key === key && (now - m.time) <= 1.0 &&
       !isempty(ctrl.undo_stack) && last(ctrl.undo_stack) isa _HistoryEntry
        e = pop!(ctrl.undo_stack)
        push!(ctrl.undo_stack, _HistoryEntry(obj, e.P0, e.R0, P1, R1))
    else
        _push_history!(ctrl, obj, P0, R0, P1, R1)
    end
    ctrl.last_key_step = (obj = obj, key = key, time = now)
    return nothing
end

"""
    _push_action!(ctrl, obj, undo, redo)

Pushes an action on `obj` to the undo history, e.g. adding it to the [`live_view`](@ref): `undo()`
takes it back, `redo()` does it again. Like a gesture, it clears the redo stack and drops the
oldest entry once the history exceeds `_HISTORY_LIMIT`. Both functions must not push entries
themselves.
"""
function _push_action!(ctrl::KinematicController, obj, undo, redo)
    push!(ctrl.undo_stack, _ActionEntry(obj, undo, redo))
    length(ctrl.undo_stack) > _HISTORY_LIMIT && popfirst!(ctrl.undo_stack)
    empty!(ctrl.redo_stack)
    ctrl.last_key_step = nothing
    return nothing
end

# Sets the pose of the object of the gesture `e` and selects it
function _apply_entry!(ctrl::KinematicController, e::_HistoryEntry, P, R)
    _change!(() -> _set_pose!(e.obj, P, R), ctrl, e.obj)
    ctrl.selected[] === e.obj || (ctrl.selected[] = e.obj)
    _update_selection_box!(ctrl)
    _request_update!(ctrl)
    return nothing
end

_undo_entry!(ctrl::KinematicController, e::_HistoryEntry) = _apply_entry!(ctrl, e, e.P0, e.R0)
_redo_entry!(ctrl::KinematicController, e::_HistoryEntry) = _apply_entry!(ctrl, e, e.P1, e.R1)
_undo_entry!(::KinematicController, e::_ActionEntry) = (e.undo(); nothing)
_redo_entry!(::KinematicController, e::_ActionEntry) = (e.redo(); nothing)

"""
    _history_step!(step!, ctrl, e, stack) -> Bool

Takes the entry `e` of the history back or does it again by `step!(ctrl, e)`, after it was moved to
the `stack`. An action that no longer applies, e.g. on a component that another window of the same
system removed meanwhile (see [`open_system`](@ref)), is dropped with a warning instead of an
error. Returns whether the step was done.
"""
function _history_step!(step!, ctrl::KinematicController, e, stack)
    try
        step!(ctrl, e)
    catch err
        (err isa ArgumentError && e isa _ActionEntry) || rethrow()
        filter!(x -> x !== e, stack)
        @warn "the entry of the undo history no longer applies and was dropped" exception = err
        return false
    end
    return true
end

"""
    _drop_history!(ctrl, objs)

Drops the entries of the undo history of the `ctrl` on the objects `objs`, e.g. after another window
of the same system added or removed them, see `_follow_structure!`.
"""
function _drop_history!(ctrl::KinematicController, objs)
    dropped = Base.IdSet{Any}(objs)
    filter!(e -> !(e.obj in dropped), ctrl.undo_stack)
    filter!(e -> !(e.obj in dropped), ctrl.redo_stack)
    !isnothing(ctrl.last_key_step) && ctrl.last_key_step.obj in dropped && (ctrl.last_key_step = nothing)
    return nothing
end

"""
    _undo!(ctrl::KinematicController)

Undoes the last recorded gesture (a mouse drag, a reset or one or several merged keyboard steps)
or action (see `_push_action!`), if any; a gesture selects its object. Returns whether an entry was
undone.
"""
function _undo!(ctrl::KinematicController)
    isempty(ctrl.undo_stack) && return false
    e = pop!(ctrl.undo_stack)
    push!(ctrl.redo_stack, e)
    ctrl.last_key_step = nothing
    return _history_step!(_undo_entry!, ctrl, e, ctrl.redo_stack)
end

"""
    _redo!(ctrl::KinematicController)

Redoes the last undone gesture or action, if any; a gesture selects its object. Returns whether an
entry was redone.
"""
function _redo!(ctrl::KinematicController)
    isempty(ctrl.redo_stack) && return false
    e = pop!(ctrl.redo_stack)
    push!(ctrl.undo_stack, e)
    ctrl.last_key_step = nothing
    return _history_step!(_redo_entry!, ctrl, e, ctrl.undo_stack)
end

"""
    _key_step!(ctrl, obj, key, factor)

Moves or rotates the `obj` depending on the mode of the `ctrl`. Returns `false` if the `key` is
not a control key. If the corresponding axis is locked by the `constraints` of `obj`, the key is
still consumed (returns `true`) but nothing moves.
"""
function _key_step!(ctrl::KinematicController, obj, key, factor)
    y, x, v = _control_axes(ctrl, obj)
    # Axis and sign of the step for each key, see _help_text
    axis_sym, axis, sign = if ctrl.mode[] == :move
        key == Keyboard.up ? (:y, y, 1) : key == Keyboard.down ? (:y, y, -1) :
        key == Keyboard.right ? (:x, x, 1) : key == Keyboard.left ? (:x, x, -1) :
        key == Keyboard.page_up ? (:v, v, 1) : key == Keyboard.page_down ? (:v, v, -1) :
        (nothing, nothing, 0)
    else
        key == Keyboard.up ? (:x, x, 1) : key == Keyboard.down ? (:x, x, -1) :
        key == Keyboard.left ? (:v, v, 1) : key == Keyboard.right ? (:v, v, -1) :
        key == Keyboard.page_up ? (:y, y, 1) : key == Keyboard.page_down ? (:y, y, -1) :
        (nothing, nothing, 0)
    end
    isnothing(axis) && return false
    axis_sym in _allowed_axes(ctrl, obj, ctrl.mode[]) || return true # locked: consumed, no motion
    _change!(ctrl, obj) do
        if ctrl.mode[] == :move
            translate3d!(obj, (sign * factor * ctrl.fine_step) .* axis)
        else
            rotate3d!(obj, axis, sign * factor * ctrl.fine_angle)
        end
    end
    return true
end

"""
    _set_spectator!(ctrl, on::Bool)

Switches the spectator mode of the `ctrl` on or off. In the spectator mode, the selection is
cleared and all mouse and keyboard input goes to the camera.
"""
function _set_spectator!(ctrl::KinematicController, on::Bool)
    ctrl.spectator[] = on
    if on
        ctrl.dragging = false
        ctrl.press_kind = :none
        ctrl.drag_start = nothing
        ctrl.ring = ctrl.arrow = nothing
        ctrl.last_key_step = nothing
        ctrl.selected[] = nothing
        _update_selection_box!(ctrl)
    end
    _update_help!(ctrl)
    return nothing
end

"""
    _cursor_ray(scene)

Returns the `origin` and the `direction` of the camera ray through the mouse position. For an
orthographic `Camera3D`, `Makie.ray_at_cursor` (Makie 0.24) returns the origin relative to the
world origin instead of the eye position, which is corrected here. The origin is also moved back to
a negative `near` plane, i.e. the start of the visible depth range behind the eye.
"""
function _cursor_ray(scene)
    r = Makie.ray_at_cursor(scene)
    origin, dir = Vector{Float64}(r.origin), Vector{Float64}(r.direction)
    cam = Makie.cameracontrols(scene)
    if cam isa Makie.Camera3D && cam.settings.projectiontype[] != Makie.Perspective
        origin .+= Vector{Float64}(cam.eyeposition[]) .+ min(cam.near[], 0.0) .* dir
    end
    return origin, dir
end

"""
Returns the direction in which the camera of the `scene` looks, a unit vector: from its eye to its
`lookat` point, or, for a view without a `Camera3D`, e.g. an `Axis3`, along the ray through the
cursor.
"""
function _view_direction(scene)
    cam = Makie.cameracontrols(scene)
    if cam isa Makie.Camera3D
        d = Vector{Float64}(cam.lookat[] .- cam.eyeposition[])
        norm(d) > 0 && return d ./ norm(d)
    end
    return normalize(_cursor_ray(scene)[2])
end

"""
    _drag_normal(scene, ctrl) -> Vector{Float64}

The normal of the plane in which the mouse moves an object of the controls `ctrl`: their
`plane_normal`, or by default (`nothing`) the direction in which the camera looks (see
`_view_direction`), i.e. the plane of the view, in which the object stays under the cursor in every
view, e.g. also in a view from the front.
"""
_drag_normal(scene, ctrl::KinematicController) =
    isnothing(ctrl.plane_normal) ? _view_direction(scene) : ctrl.plane_normal

"""Returns the drag plane intersection of the ray through the mouse position, see `_drag_normal`."""
function _mouse_plane_hit(scene, ctrl::KinematicController)
    origin, dir = _cursor_ray(scene)
    return _ray_plane_intersect(origin, dir, ctrl.plane_point, _drag_normal(scene, ctrl))
end

_default_pick(ax) = Makie.pick(Makie.get_scene(ax))

"""
    _pick_ring(ctrl, scene) -> Union{Nothing, Tuple{Symbol, NTuple{2, Float64}}}

Returns the ring of the gizmo under the cursor in the rotate mode as `(sym, tangent)`, or `nothing`:
the unlocked ring (see `constraints`) whose polyline is nearest to the cursor in pixels, within
`_RING_PICK_RADIUS`. `sym` is `:x`, `:y` or `:v`, `tangent` is the unit vector in pixels along the
positive direction of rotation at the nearest point, `(1, 0)` if the ring is seen end-on there.
"""
function _pick_ring(ctrl::KinematicController, scene)
    obj = ctrl.selected[]
    (ctrl.mode[] == :rotate && ctrl.gizmo_visible[] && !isnothing(obj)) || return nothing
    origin, dir = _cursor_ray(scene)
    cursor = _px(scene)
    allowed = _allowed_axes(ctrl, obj, :rotate)
    best, dmin = nothing, _RING_PICK_RADIUS
    n = 2 * _RING_RES
    for (i, sym) in enumerate(_AXES_SYMS)
        sym in allowed || continue
        for k in 1:2:n
            a, b = ctrl.ring_pts[][(i - 1) * n + k], ctrl.ring_pts[][(i - 1) * n + k + 1]
            # Segments behind the camera are not visible
            (dot(a .- origin, dir) > 0 && dot(b .- origin, dir) > 0) || continue
            pa = Makie.project(scene, :data, :pixel, Point3(a))
            pb = Makie.project(scene, :data, :pixel, Point3(b))
            d = _point_segment_distance(cursor, pa, pb)
            if d < dmin
                t = (pb[1] - pa[1], pb[2] - pa[2])
                L = hypot(t...)
                best, dmin = (sym, L > 1e-3 ? t ./ L : (1.0, 0.0)), d
            end
        end
    end
    return best
end

"""
    _ring_angle(scene, center, axis) -> Union{Nothing, Float64}

Returns the angle [rad] about the unit vector `axis` of the point of the plane through `center`
perpendicular to `axis` under the cursor, counted from `_ring_basis(axis)`, i.e. the angle on a
ring around `axis` with the center `center`; `nothing` if the plane is seen edge-on (see
`_RING_EDGE_ON`), where the point is not defined well.
"""
function _ring_angle(scene, center, axis)
    origin, dir = _cursor_ray(scene)
    abs(dot(normalize(dir), axis)) < _RING_EDGE_ON && return nothing
    hit = _ray_plane_intersect(origin, dir, center, axis)
    isnothing(hit) && return nothing
    e1, e2 = _ring_basis(axis)
    d = hit .- center
    return atan(dot(d, e2), dot(d, e1))
end

"""
    _pick_arrow(ctrl, scene) -> Union{Nothing, Symbol}

Returns the arrow of the gizmo under the cursor in the move mode (`:x`, `:y` or `:v`), or `nothing`:
the unlocked arrow (see `constraints`) that is nearest to the cursor in pixels, within
`_RING_PICK_RADIUS`. The start of the arrows, where the three meet, is not grabbed (see
`_ARROW_PICK_START` and `_ARROW_PICK_FREE`), such that the object below it can be, nor is an
arrow that points at the camera, i.e. one that is shorter than that on the screen, along which the
cursor can not move.
"""
function _pick_arrow(ctrl::KinematicController, scene)
    obj = ctrl.selected[]
    (ctrl.mode[] == :move && ctrl.gizmo_visible[] && !isnothing(obj)) || return nothing
    length(ctrl.arrow_pos[]) == length(_AXES_SYMS) || return nothing
    origin, dir = _cursor_ray(scene)
    cursor = _px(scene)
    allowed = _allowed_axes(ctrl, obj, :move)
    best, dmin = nothing, _RING_PICK_RADIUS
    for (i, sym) in enumerate(_AXES_SYMS)
        sym in allowed || continue
        p, d = ctrl.arrow_pos[][i], ctrl.arrow_dir[][i]
        a, b = p, p .+ d
        # An arrow behind the camera is not visible
        (dot(a .- origin, dir) > 0 && dot(b .- origin, dir) > 0) || continue
        pa = Makie.project(scene, :data, :pixel, Point3(a))
        pb = Makie.project(scene, :data, :pixel, Point3(b))
        len = hypot(pb[1] - pa[1], pb[2] - pa[2])
        len > _ARROW_PICK_FREE || continue
        start = max(_ARROW_PICK_START, _ARROW_PICK_FREE / len)
        dist = _point_segment_distance(cursor, pa .+ start .* (pb .- pa), pb)
        dist < dmin && ((best, dmin) = (sym, dist))
    end
    return best
end

"""
    _arrow_coordinate(scene, origin, axis) -> Union{Nothing, Float64}

Returns the coordinate [m] along the unit vector `axis` from the `origin` of the point of that line
that is closest to the ray through the cursor, i.e. the point of an arrow under the cursor;
`nothing` if the line is seen end-on (see `_RING_EDGE_ON`), where the point is not defined well.
"""
function _arrow_coordinate(scene, origin, axis)
    o, dir = _cursor_ray(scene)
    d = normalize(Vector{Float64}(dir))
    b = dot(axis, d)
    1 - b^2 < _RING_EDGE_ON^2 && return nothing
    w = Vector{Float64}(origin) .- Vector{Float64}(o)
    return (b * dot(d, w) - dot(axis, w)) / (1 - b^2)
end

"""Highlights the ring or the arrow under the cursor, see `ctrl.ring_hover` and `ctrl.arrow_hover`,
if the mouse is not busy otherwise."""
function _update_hover!(ctrl::KinematicController, scene)
    busy = ctrl.spectator[] || ctrl.ignore_mouse() ||
           (!isnothing(ctrl.select_modifier) && !_modifier_held(scene, ctrl.select_modifier))
    pick = busy ? nothing : _pick_ring(ctrl, scene)
    ring = isnothing(pick) ? nothing : first(pick)
    arrow = busy ? nothing : _pick_arrow(ctrl, scene)
    (ring === ctrl.ring_hover && arrow === ctrl.arrow_hover) && return nothing
    ring_changed, arrow_changed = ring !== ctrl.ring_hover, arrow !== ctrl.arrow_hover
    ctrl.ring_hover, ctrl.arrow_hover = ring, arrow
    obj = ctrl.selected[]
    isnothing(obj) && return nothing
    colors = _gizmo_colors(ctrl, obj, ctrl.mode[])
    ring_changed && (ctrl.ring_color[] = _ring_colors(ctrl, colors))
    arrow_changed && (ctrl.arrow_color[] = _arrow_colors(ctrl, colors))
    return nothing
end

"""
    _ray_box(origin, dir, bb)

Returns the distance along the ray from `origin` along `dir` to the box `bb`, `0` if `origin` is
inside of the box, or `nothing` if the ray misses the box.
"""
function _ray_box(origin, dir, bb)
    lo, hi = minimum(bb), maximum(bb)
    tmin, tmax = -Inf, Inf
    for i in 1:3
        if abs(dir[i]) < 1e-12
            lo[i] <= origin[i] <= hi[i] || return nothing
        else
            t1, t2 = (lo[i] - origin[i]) / dir[i], (hi[i] - origin[i]) / dir[i]
            tmin, tmax = max(tmin, min(t1, t2)), min(tmax, max(t1, t2))
        end
    end
    return tmax < max(tmin, 0) ? nothing : max(tmin, 0)
end

"""
    _ray_pick(objects, origin, dir, box = obj -> nothing)

Returns `(obj, t)`: the object among `objects` with the nearest hit of the ray from `origin` along
`dir`, and the hit distance `t`, or `(nothing, nothing)` if the ray misses all `objects`. Objects
are hit via `BMO.intersect3d`, i.e. `ObjectGroup`s and `MultiShape` objects are picked as a whole.
Objects for which `intersect3d` errors (e.g. custom objects without a geometry implementation) or
returns `nothing` (e.g. `NonInteractableObject`) are skipped. Sources, which have no geometry, are
hit via the bounding box returned by `box`.
"""
function _ray_pick(objects, origin, dir, box = obj -> nothing)
    ray = BMO.Ray(Vector{Float64}(origin), Vector{Float64}(dir))
    best, tmin = nothing, Inf
    for obj in objects
        t = if obj isa BMO.AbstractObject
            isect = try
                BMO.intersect3d(obj, ray)
            catch e
                e isa InterruptException && rethrow()
                nothing
            end
            isnothing(isect) ? nothing : BMO.length(isect)
        else
            bb = box(obj)
            isnothing(bb) ? nothing : _ray_box(origin, dir, bb)
        end
        isnothing(t) && continue
        if 0 <= t < tmin
            best, tmin = obj, t
        end
    end
    return best, isnothing(best) ? nothing : tmin
end

"""
    _ray_pick(ctrl::KinematicController, scene)

Returns `(obj, t)`: the object hit by the camera ray at the current cursor position of `scene`
among all objects of the movable objects of `ctrl`, i.e. objects of groups are returned instead of
the groups, and the hit distance `t`; or `(nothing, nothing)` if the ray misses everything. Objects
that a click can not select, e.g. hidden ones, are skipped, see `_pickable`. Sources
(non-`AbstractObject` leaves, i.e. beams and beam groups) are hit via the bounding box of their
marker as usual, and additionally whenever the screen-space projection of their `position` is
within `ctrl.source_pick_radius` pixels of the cursor, using as `t` the distance along the ray to
the point of the ray closest to the source position (so that the nearest candidate still wins).
"""
function _ray_pick(ctrl::KinematicController, scene)
    origin, dir = _cursor_ray(scene)
    leaves = reduce(vcat, (_leaves(o) for o in ctrl.movable); init = _LiveMovable[])
    filter!(leaf -> _pickable(ctrl, leaf), leaves)
    box = function (obj)
        plots = _object_plots(ctrl.h, obj)
        return isempty(plots) ? nothing : mapreduce(Makie.boundingbox, GeometryBasics.union, plots)
    end
    best, tmin = _ray_pick(leaves, origin, dir, box)
    tmin = isnothing(tmin) ? Inf : tmin
    cursor = _px(scene)
    for obj in leaves
        obj isa BMO.AbstractObject && continue # sources only, already covered by the bbox hit above
        p = Vector{Float64}(position(obj))
        px = Makie.project(scene, :data, :pixel, Point3(p))
        hypot(px[1] - cursor[1], px[2] - cursor[2]) <= ctrl.source_pick_radius || continue
        t = dot(p .- origin, dir)
        if 0 <= t < tmin
            best, tmin = obj, t
        end
    end
    return best, isnothing(best) ? nothing : tmin
end

"""
    kinematic_controls!(ax, h::AbstractSystemRenderHandle; kwargs...)

Enables mouse and keyboard controls for the objects of the live-rendered system `h`, see
[`live_render!`](@ref). Objects can be grabbed with the mouse and moved or rotated, while the
[`update_render!`](@ref) of `h` and the `on_change` callback are called after each change. The camera
can be used as usual as long as no object is grabbed. Returns a `KinematicController`.

The controls have a move and a rotate mode, which are switched with the key `m`. The selected object
is marked by a box and three axes above the object: its local y-axis (green), its local x-axis
(red) and the `rotation_axis` (blue). A local axis that is parallel to the `rotation_axis`, e.g. the
local x-axis of a `CollimatedSource` along +y, is replaced by the axis perpendicular to the other
two, such that the object can be moved in all directions. In the move mode the axes are shown as arrows, in the rotate
mode as rings. The key `h` shows or hides an overlay of all controls.

The key `v` switches the spectator mode on or off, in which the selection is cleared and all
mouse and keyboard input goes to the camera, such that nothing can be moved by accident.

Objects with a `Static` kinematic trait, see `BeamletOptics.kinematic_trait_of`, can not be
selected. Sources can be moved via their marker, see [`live_view`](@ref).

# Mouse controls

A click selects, a drag moves only what is already selected, every other drag rotates the camera:

- left-click on an object: selects it, so that a camera drag never moves or rotates a component by
  accident
- left-drag on the selected object: moves it within the plane of the view through the grabbed
  point, i.e. the plane perpendicular to the direction in which the camera looks, such that the
  point under the cursor at the start of the drag stays under the cursor in every view: a view
  from above moves it on the table, a view from the front changes its height. With a
  `plane_normal`, it moves within that plane instead; or rotates it around the `rotation_axis` in the rotate mode. If the exact point under the
  cursor is not known (a custom `pick` function, or the `Makie.pick` fallback), the object's
  `position` is used instead
- left-drag on a ring of the gizmo (rotate mode, only unlocked rings): rotates the selected object
  around the axis of that ring through its `position`, i.e. its `position` stays, groups turn
  around their `position`. The angle follows the cursor around the ring (the angle between the
  press and the cursor on the plane of the ring, which rests during the drag, also if the
  bounding box of the object changes); if the ring is seen almost edge-on, the movement
  of the cursor along the ring is turned into an angle with `rotate_speed` instead. The ring
  within about 8 px of the cursor (the nearest one) is highlighted and is grabbed, before the
  object itself is. The drag is one entry of the undo history, a click on a ring does nothing
- left-drag on an arrow of the gizmo (move mode, only unlocked arrows): moves the selected object
  along that arrow, such that the point of the arrow under the cursor stays under the cursor. It
  does not snap, neither onto beams nor onto a grid: the arrow names the direction. The arrow
  within about 8 px of the cursor is highlighted and is grabbed, before the object itself is,
  except where the three arrows meet and an arrow that points at the camera. The drag is one entry
  of the undo history, a click on an arrow does nothing
- left-drag elsewhere (background or an unselected object): rotates the camera as usual
- left-click on empty space: deselects the current object

Object groups (e.g. `ObjectGroup`) are selected as a whole by the first click. Each further click on
the selected group selects the next level of the hierarchy towards the object under the cursor,
i.e. a subgroup or a single object, which is then moved on its own. A group is moved and rotated
around its `position`, the group center.

Sources (beams and beam groups) are additionally picked when their `position`, projected to pixel
space, is within `source_pick_radius` of the cursor, in addition to the bounding box of their
marker, see [`live_view`](@ref).

# Keyboard controls

The following keys apply to the selected object, pressing shift multiplies the step size by 10:

| key                   | move mode (`fine_step`) | rotate mode (`fine_angle`) |
|:----------------------|:------------------------|:---------------------------|
| `↑`/`↓`               | along the green arrow   | around the red ring        |
| `→`/`←`               | along the red arrow     | around the blue ring       |
| `page up`/`page down` | along the blue arrow    | around the green ring      |

The first key moves the object in the direction of the arrow, or rotates it in the direction of
the ring. In addition, `Backspace` resets the object to its initial pose and `esc` deselects it. If
the object is part of a group, `esc` selects the enclosing group instead.

The keys `+` and `-` increase or decrease the step size of the current mode (`fine_step` or
`fine_angle`) along the 1-2-5 sequence, e.g. 10 nm → 20 nm → 50 nm → 100 nm. They also work
without a selected object. The current step size is shown in the hint line.

# Undo/redo

`Ctrl`+`Z` (`Cmd`+`Z` on macOS) undoes the last gesture, `Ctrl`+`Y` or `Ctrl`+`Shift`+`Z`
(`Cmd`+`Y`/`Cmd`+`Shift`+`Z`) redoes it. A gesture is a mouse drag, a reset (`Backspace`) or a run
of keyboard steps of the same key on the same object less than 1 s apart, each recorded as a single
history entry (up to 100 entries). Undoing or redoing selects the affected object and re-triggers
`on_change`. A new gesture clears the redo history. Not available in the spectator mode.

# Constraints

`constraints` locks the move and/or rotate axes of specific objects, e.g. a mirror in a kinematic
mount that may only tilt. A locked axis does not move via the mouse or the keyboard (the key is
still consumed) and is shown faded on the gizmo. For an object inside a group, the constraints of
the object (or subgroup) that is currently selected apply.

# Keyword args

- `objects = nothing`: the movable top-level objects, all top-level objects of `h` by default. The
  objects of a movable group are movable as well.
- `on_change = obj -> nothing`: called with the moved object after each change, e.g. to solve the system
- `plane_normal = nothing`: normal of the plane for mouse translation, e.g. `[0, 0, 1]` to keep
  the height of the objects; by default the plane of the view, see "Mouse controls"
- `rotation_axis = [0, 0, 1]`: rotation axis for mouse rotation, blue axis of the keyboard controls
- `rotate_speed = deg2rad(0.5)`: mouse rotation angle per pixel [rad]
- `fine_step = 10e-9`: keyboard translation step [m]
- `fine_angle = 10e-6`: keyboard rotation step [rad]
- `mode = :move`: initial mode, `:move` or `:rotate`
- `throttle = true`: limits updates to one per frame
- `show_help = false`: shows the controls overlay initially, otherwise only a hint
- `pick = nothing`: objects are selected by intersecting the camera ray with the movable objects, so
  meshes that are not part of the system (e.g. housings) do not block the selection; otherwise a
  function `ax -> (plot, index)`. The grab point of a drag falls back to the object's `position`
  when a custom `pick` is used, since it does not provide a hit point.
- `select_modifier = nothing`: if set to a `Keyboard.Button` (or a tuple/vector of them, meaning
  "any of"), clicks and drags only react on objects while the modifier is held; otherwise they
  always go to the camera. Suggested: `Keyboard.left_shift` (`Ctrl`+click is taken by Makie's
  `Camera3D` reset).
- `drag_threshold = 3`: [px] mouse movement between press and release that turns a click into a
  drag
- `spectator = false`: starts in the spectator mode
- `constraints = Dict()`: maps an object to a `NamedTuple` `(; move = axes, rotate = axes)`, where
  `axes` is a tuple of the allowed gizmo axes `:x` (red, local x), `:y` (green, local y) and `:v`
  (blue, `rotation_axis`); a missing field means all axes are allowed, `()` means none, see
  "Constraints"
- `source_pick_radius = 15`: [px] screen-space pick radius of source markers, see "Mouse controls"
- `ignore_keys = () -> false`: predicate checked before any keyboard handling (including `v`, `h`,
  `m` and undo/redo); while `true`, keys are not handled and passed on, e.g. while a text field
  elsewhere in the figure is focused
"""
function kinematic_controls!(
        ax::_Axis,
        h::AbstractSystemRenderHandle;
        objects = nothing,
        on_change = obj -> nothing,
        plane_normal = nothing,
        rotation_axis = [0, 0, 1],
        rotate_speed = deg2rad(0.5),
        fine_step = 10e-9,
        fine_angle = 10e-6,
        mode::Symbol = :move,
        throttle::Bool = true,
        show_help::Bool = false,
        pick = nothing,
        select_modifier = nothing,
        drag_threshold = 3,
        spectator::Bool = false,
        constraints = Dict(),
        source_pick_radius = 15,
        ignore_keys = () -> false
    )
    mode in (:move, :rotate) || throw(ArgumentError("mode must be :move or :rotate, got :$mode"))
    # Objects are compared by identity
    constraints_dict = IdDict{Any, NamedTuple}(constraints)
    _validate_constraints(constraints_dict)
    scene = Makie.get_scene(ax)
    movable = _LiveMovable[]
    if isnothing(objects)
        # Top-level objects, since the handles of groups belong to the objects of the group
        for oh in render_children(h)
            top = _top_level(h, rendered(oh))
            BMO.is_static(top) && continue
            any(o -> o === top, movable) || push!(movable, top)
        end
    else
        append!(movable, objects)
    end
    # Initial poses of all levels, such that each object and subgroup can be reset
    init_poses = IdDict{_LiveMovable, Tuple{Point3{Float64}, Matrix{Float64}}}(
        obj => _pose(obj) for top in movable for obj in _descendants(top))

    # Selection box and gizmo, updated via Observables. The hidden gizmo is placed in the center of
    # the system with a negligible size, since it counts towards the limits of the scene.
    box_obs = Observable(Point3f[])
    obj_plots = render_plots(h)
    bb = isempty(obj_plots) ? GeometryBasics.Rect3d(zeros(3), ones(3)) :
         mapreduce(Makie.boundingbox, GeometryBasics.union, obj_plots)
    center = Vector{Float64}(minimum(bb) + GeometryBasics.widths(bb) / 2)
    arrow_pos, arrow_dir, label_pos, ring_pts = _gizmo(mode, center,
        ([0, 1, 0], [1, 0, 0], [0, 0, 1]), 1e-3 * maximum(GeometryBasics.widths(bb)))
    arrow_pos, arrow_dir = Observable(arrow_pos), Observable(arrow_dir)
    label_pos, ring_pts = Observable(label_pos), Observable(ring_pts)
    default_colors = Makie.RGBAf[Makie.RGBAf(Makie.to_color(c)) for c in _AXES_COLORS]
    arrow_color = Observable(default_colors)
    label_color = Observable(default_colors)
    ring_color = Observable(repeat(default_colors; inner = 2 * _RING_RES))
    gizmo_size = Observable(1.0)
    gizmo_visible = Observable(false)
    mode_obs = Observable(mode)
    labels = Makie.lift(m -> m == :move ? ["↑", "→", "page up"] : ["page up", "↑", "←"], mode_obs)
    plots = AbstractPlot[
        linesegments!(ax, box_obs; color = :yellow, linewidth = 2, clip_planes = Plane3f[]),
        # Arrow dimensions relative to the gizmo size, such that ring arrows are mostly tip
        arrows3d!(ax, arrow_pos, arrow_dir; color = arrow_color, visible = gizmo_visible,
            markerscale = gizmo_size, shaftradius = 0.025, tipradius = 0.1, tiplength = 0.3,
            overdraw = true, clip_planes = Plane3f[]),
        linesegments!(ax, ring_pts; color = ring_color, linewidth = 3, overdraw = true,
            visible = Makie.lift((v, m) -> v && m == :rotate, gizmo_visible, mode_obs),
            clip_planes = Plane3f[]),
        text!(ax, label_pos; text = labels, color = label_color, visible = gizmo_visible,
            fontsize = 20, align = (:center, :center), overdraw = true, clip_planes = Plane3f[])
    ]
    help_obs = Observable("")
    # Drawn in the 2D scene of the axis, such that it does not count towards the limits of the scene
    help_pos = Makie.lift(vp -> Point2f(minimum(vp)[1] + 10, maximum(vp)[2] - 10), ax.scene.viewport)
    push!(plots, text!(ax.blockscene, help_pos; text = help_obs, space = :pixel,
        align = (:left, :top), fontsize = 14, color = :gray40))

    ctrl = KinematicController(
        ax, h, movable, init_poses, Observable{Union{Nothing, _LiveMovable}}(nothing),
        mode_obs, on_change, isnothing(plane_normal) ? nothing : normalize(Float64.(plane_normal)),
        normalize(Float64.(rotation_axis)),
        Float64(rotate_speed), Float64(fine_step), Float64(fine_angle), throttle,
        Observable(spectator), select_modifier, Float64(drag_threshold),
        constraints_dict, Float64(source_pick_radius), ignore_keys,
        false, false, zeros(3), zeros(3), (0.0, 0.0), nothing, nothing, :none,
        nothing, _AnyHistoryEntry[], _AnyHistoryEntry[], nothing,
        box_obs, arrow_pos, arrow_dir, label_pos, ring_pts, arrow_color, label_color, ring_color,
        gizmo_size, gizmo_visible, help_obs, show_help, _HelpSection[], nothing, plots, Any[],
        nothing, obj -> false,
        () -> nothing, () -> false, pick, leaf -> false, _CLICK_HELP,
        Observable(:off), (obj, point) -> nothing, (obj, point) -> nothing, 0, 0.0, 0.0, nothing,
        center, nothing, nothing, nothing, nothing
    )

    # High priority, so that the camera does not receive events while an object is dragged
    l1 = on(events(scene).mousebutton, priority = 200) do event
        (event.button == Mouse.left && !ctrl.spectator[]) || return Consume(false)
        if event.action == Mouse.press && ctrl.ignore_mouse()
            # Neither a selection nor a deselection by the release of this press
            ctrl.press_kind, ctrl.press_leaf, ctrl.press_pos = :none, nothing, nothing
            return Consume(false)
        end
        if event.action == Mouse.press
            if !isnothing(ctrl.select_modifier) && !_modifier_held(scene, ctrl.select_modifier)
                # Modifier not held: every click and drag goes to the camera, no state change
                return Consume(false)
            end
            ring = _pick_ring(ctrl, scene)
            if !isnothing(ring)
                # A drag on a ring of the gizmo rotates the selection around it, a click does nothing
                sym, tangent = ring
                obj = ctrl.selected[]
                axis = only(_axis_vectors(ctrl, obj, (sym,)))
                ctrl.press_pos = ctrl.last_mouse = _px(scene)
                ctrl.press_leaf = nothing
                ctrl.press_kind = :pending_ring
                center = copy(ctrl.gizmo_origin)
                ctrl.ring = _RingDrag(sym, axis, center, _ring_angle(scene, center, axis), tangent)
                return Consume(true)
            end
            arrow = _pick_arrow(ctrl, scene)
            if !isnothing(arrow)
                # A drag on an arrow of the gizmo moves the selection along it, a click does nothing
                axis = Vector{Float64}(only(_axis_vectors(ctrl, ctrl.selected[], (arrow,))))
                line = copy(ctrl.gizmo_origin)
                ctrl.press_pos = ctrl.last_mouse = _px(scene)
                ctrl.press_leaf = nothing
                ctrl.press_kind = :pending_arrow
                ctrl.arrow = _ArrowDrag(arrow, axis, line, _arrow_coordinate(scene, line, axis))
                return Consume(true)
            end
            local t
            if pick === nothing
                leaf, t = _ray_pick(ctrl, scene)
                if isnothing(leaf)
                    plot, _ = _default_pick(ax)
                    leaf = isnothing(plot) ? nothing : _pick_leaf(h, plot)
                    t = nothing
                end
            else
                plot, _ = pick(ax)
                leaf = isnothing(plot) ? nothing : _pick_leaf(h, plot)
                t = nothing
            end
            !isnothing(leaf) && !_pickable(ctrl, leaf) && (leaf = nothing)
            ctrl.press_pos = _px(scene)
            if isnothing(leaf) || !_is_movable(ctrl, leaf)
                ctrl.press_leaf = nothing
                ctrl.press_kind = :background
                return Consume(false)
            end
            ctrl.press_leaf = leaf
            sel = ctrl.selected[]
            if !isnothing(sel) && any(o -> o === sel, _chain(ctrl, leaf))
                # Dragging the already selected object: block the camera immediately
                ctrl.press_kind = :pending_drag
                ctrl.last_mouse = ctrl.press_pos
                ctrl.plane_point = Vector{Float64}(position(sel))
                # Grab at the exact point under the cursor, so that point stays under the cursor
                # during the drag; falls back to the pivot if the hit point is not known
                hit_point = nothing
                if !isnothing(t)
                    origin, dir = _cursor_ray(scene)
                    hit_point = origin .+ t .* dir
                    ctrl.plane_point = hit_point
                end
                if !isnothing(hit_point)
                    ctrl.grab_offset = Vector{Float64}(position(sel)) .- hit_point
                else
                    hit = _mouse_plane_hit(scene, ctrl)
                    ctrl.grab_offset = isnothing(hit) ? zeros(3) : ctrl.plane_point .- hit
                end
                return Consume(true)
            else
                # A press on an unselected object might turn into a camera drag: let it through
                ctrl.press_kind = :pending_select
                return Consume(false)
            end
        elseif event.action == Mouse.release
            cur = _px(scene)
            moved = isnothing(ctrl.press_pos) ? Inf : hypot((cur .- ctrl.press_pos)...)
            kind = ctrl.press_kind
            consume = false
            if ctrl.dragging
                ctrl.dragging = false
                consume = true
                if !isnothing(ctrl.drag_start)
                    obj = ctrl.selected[]
                    P0, R0 = ctrl.drag_start
                    P1, R1 = _pose(obj)
                    ctrl.drag_start = nothing
                    ctrl.last_key_step = nothing
                    _push_history!(ctrl, obj, P0, R0, P1, R1)
                end
            elseif kind in (:pending_ring, :pending_arrow)
                consume = true
            elseif kind == :pending_drag
                # Released before crossing the threshold: a click, not a drag
                moved < ctrl.drag_threshold && _click_leaf!(ctrl, ctrl.press_leaf)
                consume = true
            elseif kind == :pending_select
                # Only select if this was a click, not a camera rotation
                moved < ctrl.drag_threshold && _click_leaf!(ctrl, ctrl.press_leaf)
            elseif kind == :background
                if moved < ctrl.drag_threshold && !ctrl.on_click(nothing)
                    ctrl.selected[] = nothing
                    _update_selection_box!(ctrl)
                end
            end
            ctrl.press_kind = :none
            ctrl.press_leaf = nothing
            ctrl.press_pos = nothing
            if !isnothing(ctrl.ring)
                # the gizmo follows the object again, see `_update_selection_box!`
                ctrl.ring = nothing
                _update_selection_box!(ctrl)
            end
            ctrl.arrow = nothing
            return Consume(consume)
        end
        return Consume(false)
    end

    l2 = on(events(scene).mouseposition, priority = 200) do _
        if !ctrl.dragging
            if !(ctrl.press_kind in (:pending_drag, :pending_ring, :pending_arrow))
                _update_hover!(ctrl, scene)
                return Consume(false)
            end
            cur = _px(scene)
            moved = hypot((cur .- ctrl.press_pos)...)
            moved >= ctrl.drag_threshold || return Consume(true)
            ctrl.dragging = true
            ctrl.drag_start = _pose(ctrl.selected[])
            _start_snap!(ctrl, ctrl.selected[])
            # The snapping to beams is of the rotation around the rotation axis
            !isnothing(ctrl.ring) && ctrl.ring.sym != :v && (ctrl.drag_beam_angle = nothing)
        end
        obj = ctrl.selected[]
        if !isnothing(ctrl.ring)
            ring = ctrl.ring
            mp = _px(scene)
            Δ = (mp[1] - ctrl.last_mouse[1], mp[2] - ctrl.last_mouse[2])
            ctrl.last_mouse = mp
            θ = _ring_angle(scene, ring.center, ring.axis)
            # The cursor follows the ring, or, if its plane is seen edge-on, moves along it
            δ = isnothing(θ) || isnothing(ring.θ) ? ctrl.rotate_speed * (Δ[1] * ring.tangent[1] + Δ[2] * ring.tangent[2]) :
                mod(θ - ring.θ + π, 2π) - π
            ring.θ = θ
            δ = ring.sym == :v ? _snap_rotation!(ctrl, δ) : δ
            if δ != 0
                _change!(() -> rotate3d!(obj, ring.axis, δ), ctrl, obj)
                _request_update!(ctrl)
            end
        elseif !isnothing(ctrl.arrow)
            arrow = ctrl.arrow
            ctrl.last_mouse = _px(scene)
            # The point of the arrow under the cursor at the press stays under the cursor; on a line
            # that is seen end-on, the cursor tells no point
            s = _arrow_coordinate(scene, arrow.origin, arrow.axis)
            δ = isnothing(s) || isnothing(arrow.s) ? 0.0 : s - arrow.s
            arrow.s = s
            if δ != 0
                _change!(() -> translate3d!(obj, δ .* arrow.axis), ctrl, obj)
                _request_update!(ctrl)
            end
        elseif ctrl.mode[] == :move
            hit = _mouse_plane_hit(scene, ctrl)
            if !isnothing(hit)
                target = hit .+ ctrl.grab_offset
                allowed = _allowed_axes(ctrl, obj, :move)
                if !isempty(allowed)
                    snapped = ctrl.snap[] == :off ? nothing : ctrl.snap_beam(obj, target)
                    if isnothing(snapped)
                        # beside the beams: onto the grid, e.g. the holes of the table
                        grid = ctrl.snap_grid(obj, target)
                        isnothing(grid) || (target = Vector{Float64}(grid.point))
                    else
                        target = Vector{Float64}(snapped.point)
                    end
                    Δ = target .- Vector{Float64}(position(obj))
                    A = hcat(_axis_vectors(ctrl, obj, allowed)...)
                    R = _snap_orientation(ctrl, obj, snapped)
                    # Projection onto the allowed axes, which may be linearly dependent, e.g. if
                    # a local axis is almost parallel to the rotation axis
                    _change!(ctrl, obj) do
                        translate3d!(obj, A * (pinv(A) * Δ))
                        isnothing(R) || _set_pose!(obj, _pose(obj)[1], R)
                    end
                    _request_update!(ctrl)
                end
            end
        else
            mp = _px(scene)
            dx = mp[1] - ctrl.last_mouse[1]
            ctrl.last_mouse = mp
            if dx != 0 && :v in _allowed_axes(ctrl, obj, :rotate)
                δ = _snap_rotation!(ctrl, ctrl.rotate_speed * dx)
                if δ != 0
                    _change!(() -> rotate3d!(obj, ctrl.rotation_axis, δ), ctrl, obj)
                    _request_update!(ctrl)
                end
            end
        end
        return Consume(true)
    end

    l3 = on(events(scene).keyboardbutton, priority = 200) do event
        ctrl.ignore_keys() && return Consume(false)
        event.action in (Keyboard.press, Keyboard.repeat) || return Consume(false)
        if event.action == Keyboard.press && event.key == Keyboard.v
            _set_spectator!(ctrl, !ctrl.spectator[])
            return Consume(true)
        end
        # Only the overlay can be toggled in the spectator mode
        ctrl.spectator[] && event.key != Keyboard.h && return Consume(false)
        if event.action == Keyboard.press && event.key in (Keyboard.h, Keyboard.m)
            if event.key == Keyboard.h
                ctrl.help_shown = !ctrl.help_shown
            else
                ctrl.mode[] = _other_mode(ctrl.mode[])
                _update_selection_box!(ctrl)
            end
            _update_help!(ctrl)
            return Consume(true)
        end
        # By the letter of the key, not by its place: "Z" and "Y" are swapped on e.g. a German keyboard
        if _modifier_held(scene, _CTRL_OR_CMD_KEYS) &&
           (key = _layout_key(event.key)) in (Keyboard.z, Keyboard.y)
            if key == Keyboard.y || _shift_pressed(scene)
                _redo!(ctrl)
            else
                _undo!(ctrl)
            end
            return Consume(true)
        end
        obj = ctrl.selected[]
        isnothing(obj) && return Consume(false)
        if event.key == Keyboard.escape
            # One level up in the hierarchy of groups, deselect at the top level
            ctrl.selected[] = render_parent(ctrl.h, obj)
            _update_selection_box!(ctrl)
        elseif event.key == Keyboard.backspace
            P0, R0 = _pose(obj)
            _reset_pose!(ctrl, obj)
            P1, R1 = _pose(obj)
            ctrl.last_key_step = nothing
            _push_history!(ctrl, obj, P0, R0, P1, R1)
            _request_update!(ctrl)
        else
            P0, R0 = _pose(obj)
            if _key_step!(ctrl, obj, event.key, _shift_pressed(scene) ? 10 : 1)
                P1, R1 = _pose(obj)
                _record_key_step!(ctrl, obj, event.key, P0, R0, P1, R1)
                _request_update!(ctrl)
            else
                return Consume(false)
            end
        end
        return Consume(true)
    end
    # Typed characters instead of keys, since + and - depend on the keyboard layout
    l4 = on(events(scene).unicode_input, priority = 200) do char
        ctrl.ignore_keys() && return Consume(false)
        (char in ('+', '-') && !ctrl.spectator[]) || return Consume(false)
        _change_step!(ctrl, char == '+' ? 1 : -1)
        return Consume(true)
    end
    push!(ctrl.listeners, l1, l2, l3, l4)
    _update_help!(ctrl)

    if throttle
        push!(ctrl.listeners, on(_ -> ctrl.dirty && _apply_update!(ctrl), events(scene).tick))
    end
    return ctrl
end

function Base.close(ctrl::KinematicController)
    foreach(off, ctrl.listeners)
    empty!(ctrl.listeners)
    foreach(p -> delete!(p.parent, p), ctrl.plots)
    empty!(ctrl.plots)
    return nothing
end
