#=
Snapping of the components of the live view onto its beams while they are dragged with the mouse
(a component that is being placed follows the same switch, see `_placement_pose`),
see `_set_snap!` of the controls: the beams that a component snaps onto (`_snap_beam`), the key
and the help
=#

# The key that switches the snapping to its next state, with Shift to the one before; Makie's
# `Camera3D` and the live view bind all letters
const _SNAP_KEY = Keyboard.tab

# The keys of the snapping, in the help of the controls, see `_help_sections`
const _SNAP_HELP = _HelpSection["Snap onto beams" => [
    _HelpEntry(["Tab"], "snap dragged and placed components (beams, table): off, position, position + rotation"),
    _HelpEntry(["Shift", "Tab"], "the same backwards"; combo = true),
    _HelpEntry([:mouse => "drag"], "move mode: onto the central beam of a source"),
    _HelpEntry([:mouse => "drag"], "rotate mode: in steps of 45° to the beam"),
    _HelpEntry([:mouse => "drag"], "with the table shown: onto its holes beside the beams")]]

"""
    _SnapLine

A line that a dragged component snaps onto: the part of a central beam from `a` to `b` [m] with its
`direction`, see `_snap_lines`.
"""
struct _SnapLine
    a::Vector{Float64}
    b::Vector{Float64}
    direction::Vector{Float64}
end

# The rays of a node of a beam that its central line follows: the beam itself, the chief ray of a
# Gaussian beamlet
_snap_rays(beam::Beam) = BMO.rays(beam)
_snap_rays(gauss::BMO.GaussianBeamlet) = BMO.rays(gauss.chief)
_snap_rays(agb::BMO.AstigmaticGaussianBeamlet) = BMO.rays(agb.c)

"""
    _snap_lines!(lines, beam, hits, flen) -> lines

Appends the lines of the `beam` and of its children that do not depend on a dragged object:
`hits(o)` tells whether the object `o` of an intersection belongs to it. The rays up to the first
one that hits the object are lines as they are rendered, a ray without an intersection with the
length `flen`. The ray that hits the object is a line that goes on behind it by `flen`, such that
the object can be dragged along the beam; what follows, i.e. the rays behind the object and the
children of the beam, changes with the object and is left out.
"""
function _snap_lines!(lines, beam, hits, flen)
    for ray in _snap_rays(beam)
        isect = BMO.intersection(ray)
        a = Vector{Float64}(position(ray))
        d = Vector{Float64}(BMO.direction(ray))
        if isnothing(isect)
            push!(lines, _SnapLine(a, a .+ flen .* d, d))
        elseif hits(BMO.object(isect))
            push!(lines, _SnapLine(a, a .+ (Float64(length(isect)) + flen) .* d, d))
            return lines
        else
            push!(lines, _SnapLine(a, a .+ Float64(length(isect)) .* d, d))
        end
    end
    foreach(child -> _snap_lines!(lines, child, hits, flen), AbstractTrees.children(beam))
    return lines
end

function _snap_lines!(lines, ray::BMO.AbstractRay, hits, flen)
    isect = BMO.intersection(ray)
    a = Vector{Float64}(position(ray))
    d = Vector{Float64}(BMO.direction(ray))
    len = isnothing(isect) ? flen : Float64(length(isect)) + (hits(BMO.object(isect)) ? flen : 0.0)
    return push!(lines, _SnapLine(a, a .+ len .* d, d))
end

"""
    _snap_lines(gui, obj) -> Vector{_SnapLine}

The lines that the component `obj` of the `gui` snaps onto while it is dragged: of each beam that is
switched on, the central beam (of a beam group, see `_central_beam`; of a Gaussian beamlet its
chief ray) as far as it does not depend on `obj`, see `_snap_lines!`. As for a component that is
being placed, which is not traced, the lines do not move with the component.
"""
function _snap_lines(gui::LiveView, @nospecialize(obj))
    parts = _descendants(obj)
    hits = o -> _has(parts, o)
    lines = _SnapLine[]
    for (p, h) in zip(gui.pairs, gui.beam_handles)
        _beam_on(gui, p.second) || continue
        _snap_lines!(lines, _central_beam(rendered(h)), hits, Float64(render_settings(h).flen))
    end
    return lines
end

# Only the components of the systems snap, not the sources and the clip planes
_snaps(::BMO.AbstractObject) = true
_snaps(_) = false

"""
    _sight_line(scene, point) -> (origin, direction)

The line of sight of the camera of the `scene` through the `point` [m]: from the eye of a
perspective camera, otherwise along the direction of the view, see `_view_direction`.
"""
function _sight_line(scene, point)
    cam = Makie.cameracontrols(scene)
    if cam isa Makie.Camera3D && cam.settings.projectiontype[] == Makie.Perspective
        eye = Vector{Float64}(cam.eyeposition[])
        norm(point .- eye) > 0 && return eye, normalize(point .- eye)
    end
    return Vector{Float64}(point), _view_direction(scene)
end

"""
    _snap_point(scene, lines, point; radius = _SNAP_RADIUS) -> Union{Nothing, NamedTuple}

The point of the `lines` that a component at the `point` [m] snaps onto: of the line whose
projection into the `scene` is closest to the projected point within `radius` pixels, the point
that is seen closest to the `point`, i.e. the one closest to the line of sight through the `point`
(see `_sight_line`), as `(; point, direction)` with the direction of the line. Hence a component
that is dragged in the plane of the view snaps onto the beam where it is seen, also if it is far
from the beam in depth. Of a line that is seen end-on, it is the point closest to the `point` in
space. `nothing` without a line that close.
"""
function _snap_point(scene, lines, point; radius::Real = _SNAP_RADIUS)
    origin, dir = _cursor_ray(scene)
    px = Makie.project(scene, :data, :pixel, Point3(point...))
    best, dmin = nothing, Float64(radius)
    for line in lines
        # Lines behind the camera are not visible
        (dot(line.a .- origin, dir) > 0 || dot(line.b .- origin, dir) > 0) || continue
        pa = Makie.project(scene, :data, :pixel, Point3(line.a...))
        pb = Makie.project(scene, :data, :pixel, Point3(line.b...))
        d = _point_segment_distance(px, pa, pb)
        if d <= dmin
            best, dmin = line, d
        end
    end
    isnothing(best) && return nothing
    u = best.b .- best.a
    o, d = _sight_line(scene, point)
    # the closest points of the line `best.a + s u` and the line of sight `o + t d`
    w = best.a .- o
    uu, ud, uw, dw = dot(u, u), dot(u, d), dot(u, w), dot(d, w)
    denom = uu - ud^2
    s = denom > 1e-12 * uu ? (ud * dw - uw) / denom : dot(point .- best.a, u) / uu
    s = clamp(s, 0.0, 1.0)
    return (; point = best.a .+ s .* u, direction = best.direction)
end

"""
    _connect_snap!(gui)

Connects the snapping of the controls of the `gui` (see `_set_snap!`) to its beams: a component
that is dragged snaps onto the lines of `_snap_lines`, which are taken once per drag, as soon as no
solve in the background changes the beams. The key `Tab` (`_SNAP_KEY`) switches the snapping to its
next state (off, the position, position and rotation, see `_cycle_snap!`), with `Shift` to the one
before, unless a textbox or menu takes the keyboard and not in the spectator mode; both are listed
in the help (`_SNAP_HELP`).
"""
function _connect_snap!(gui::LiveView)
    ctrl = gui.controls
    scene = gui.ax.scene
    # The lines of the current drag: its number, its object and the lines
    cache = Ref{Any}(nothing)
    ctrl.snap_beam = function (obj, point)
        @nospecialize obj
        _snaps(obj) || return nothing
        if isnothing(cache[]) || cache[][1] != ctrl.drag_count || cache[][2] !== obj
            # The beams are being traced by a solve in the background
            _running(gui) && return nothing
            cache[] = (ctrl.drag_count, obj, _snap_lines(gui, obj))
        end
        return _snap_point(scene, cache[][3], Vector{Float64}(point))
    end
    push!(ctrl.listeners, on(events(scene).keyboardbutton; priority = 200) do event
        (event.action == Keyboard.press && event.key == _SNAP_KEY) || return Consume(false)
        (ctrl.ignore_keys() || ctrl.spectator[]) && return Consume(false)
        _cycle_snap!(gui, _shift_pressed(scene) ? -1 : 1)
        return Consume(true)
    end)
    append!(ctrl.help_extra, _SNAP_HELP)
    _update_help!(ctrl)
    return nothing
end

"""
Switches the snapping of the controls of the `gui` to its next state, like the key `Tab`, with
`dir = -1` to the one before, like `Shift`+`Tab`, and tells it in the status line, see
`_cycle_snap!`.
"""
function _cycle_snap!(gui::LiveView, dir::Integer = 1)
    ctrl = gui.controls
    _cycle_snap!(ctrl, dir)
    gui.status.text[] = ctrl.snap[] == :off ? "snap off" :
                        "snap on: $(_snap_string(ctrl.snap[])) onto the beams"
    return nothing
end
