#=
The diagnostics of the rays of the debug mode (see `_Debug` in `src/LiveDebug.jl`): the ends of
the beams by reason, the hit points with their surface normals and the components that no ray hit,
read from what the last solve stored, see `_DebugRays`
=#

# z translation of the plots in their pixel scene: GLMakie draws the plots in the order of this
# value, after the 3D scene, and their depth lies in front of it, also of transparent plots such as
# the beams, which are drawn last. Below the catalog window (`_CATALOG_Z`), the cards
# (`_CARD_Z0`) and the progress window (`_PROGRESS_Z`), which cover them
const _RAYS_Z = 9000.0f0
# The most hit points drawn, see `_layer_solved!`
const _RAYS_HIT_CAP = 2000
# The length of a normal as a fraction of the radius of the scene, see `_scene_bounds`
const _RAYS_NORMAL = 0.05
# The color of the hit points and normals: the purple of the clip planes
const _RAYS_HIT_COLOR = RGBAf(Makie.to_color("#9b40c9"))

"""
    _DebugRays <: _DebugLayer

The layer `:rays` of the debug mode: the diagnostics of the rays of the last solve, read from the
beams as they were traced (`BMO.path_segments`, `intersection`), never traced again.

- the end of each branch of the beams, colored by reason (see `_end_reason`): green (`t.ok`) on an
  object, amber (`t.stale`) open, red (`t.danger`) at a limit of the solve
- the hit points of the rays (of a Gaussian beamlet its chief rays) with the normals of the
  surfaces they hit, purple like the clip planes, at most `_RAYS_HIT_CAP` (every k-th)
- the label "never hit" at the components of the traced systems that no ray hit

Only the sources that are switched on and up to date count, of a beam group the beams that are
drawn (`render_every`). The result is also the `_RaySummary` in `stats.rays` of the debug mode.

The plots lie in a child scene of the 3D scene with a pixel camera (`hud`), at the projections of
the 3D points (`ends`, `hits`, `normals` and `unhit` [m]), which follow the camera. As the
progress window (see `_ProgressOverlay`), they are drawn after the 3D scene and in front of it
(`_RAYS_Z`): fully on top of the beams, also inside a thick Gaussian beam, which is drawn
transparent. They are not inspectable, not clipped and do not enter the limits of the 3D scene.
They are shown while the mode is (`on`) and the last solve is shown (`fresh`), i.e. hidden while
the beams are outdated.
"""
mutable struct _DebugRays <: _DebugLayer
    const scene::Makie.Scene
    const hud::Makie.Scene
    # 3D points [m] of the last solve; `normals` in pairs of start and end
    const ends::Dict{Symbol, Vector{Point3f}}
    const hits::Vector{Point3f}
    const normals::Vector{Point3f}
    const unhit::Vector{Point3f}
    # their projections [px in `hud`]
    const ends_px::Dict{Symbol, Observable{Vector{Point2f}}}
    const hits_px::Observable{Vector{Point2f}}
    const normals_px::Observable{Vector{Point2f}}
    const unhit_px::Observable{Vector{Point2f}}
    const unhit_text::Observable{Vector{String}}
    const visible::Observable{Bool}
    # the plots of the ends by color (`:object`, `:open`, `:limit`), the normals, the hit points
    # and the labels
    const plots::Dict{Symbol, AbstractPlot}
    on::Bool
    fresh::Bool
end

# The colors of the ends, see `_end_reason`: the limits of the solve share one
const _RAYS_END_KEYS = (:object, :open, :limit)
_end_key(reason::Symbol) = reason === :r_max || reason === :depth_max ? :limit : reason
_end_color(t, key::Symbol) = key === :object ? t.ok : key === :open ? t.stale : t.danger

function _new_layer(gui::LiveView, ::Val{:rays})
    t = gui.layout.theme
    scene = gui.ax.scene
    hud = Makie.campixel(scene)
    visible = Observable(false)
    common = (; visible, inspectable = false, transparency = false, clip_planes = Plane3f[])
    ends_px = Dict(k => Observable(Point2f[]) for k in _RAYS_END_KEYS)
    hits_px, normals_px, unhit_px = Observable(Point2f[]), Observable(Point2f[]), Observable(Point2f[])
    unhit_text = Observable(String[])
    plots = Dict{Symbol, AbstractPlot}()
    plots[:normals] = linesegments!(hud, normals_px; common..., color = _RAYS_HIT_COLOR,
        linewidth = 2.5)
    plots[:hits] = scatter!(hud, hits_px; common..., color = _RAYS_HIT_COLOR, markersize = 7,
        strokecolor = :white, strokewidth = 1)
    for k in _RAYS_END_KEYS
        plots[k] = scatter!(hud, ends_px[k]; common..., color = _end_color(t, k), markersize = 14,
            strokecolor = :white, strokewidth = 2)
    end
    plots[:labels] = text!(hud, unhit_px; common..., text = unhit_text, color = t.stale_text,
        fontsize = 12, offset = Vec2f(16, 0), align = (:left, :center))
    # In this order: the normals below the hit points, the ends and the labels on top
    for (k, name) in enumerate((:normals, :hits, _RAYS_END_KEYS..., :labels))
        translate!(plots[name], 0, 0, _RAYS_Z + k)
    end
    r = _DebugRays(scene, hud, Dict(k => Point3f[] for k in _RAYS_END_KEYS), Point3f[],
        Point3f[], Point3f[], ends_px, hits_px, normals_px, unhit_px, unhit_text, visible, plots,
        false, false)
    # The projections follow the camera and the size of the view while they are shown
    Makie.onany(Makie.camera(scene).projectionview, Makie.viewport(scene)) do _, _
        r.visible[] && _project_rays!(r)
        return nothing
    end
    return r
end

function _layer_show!(::LiveView, r::_DebugRays, on::Bool)
    r.on = on
    _show_rays!(r)
    return nothing
end

function _layer_stale!(::LiveView, r::_DebugRays)
    r.fresh = false
    _show_rays!(r)
    return nothing
end

"""
    _layer_solved!(gui, r::_DebugRays)

Reads the beams of the last solve of the `gui` into the diagnostics `r` and `stats.rays` of the
debug mode, see `_DebugRays`, and shows them. Reads nothing while a solve runs in the background,
which owns the beams.
"""
function _layer_solved!(gui::LiveView, r::_DebugRays)
    _running(gui) && return nothing
    t = gui.layout.theme
    r_max, depth_max = BMO.get_default_r_max(), BMO.get_default_depth_max()
    ends = Dict(k => Point3f[] for k in _RAYS_END_KEYS)
    counts = Dict(:open => 0, :object => 0, :r_max => 0, :depth_max => 0)
    hits = Tuple{Point3f, Vec3f}[]
    hit_objects = Base.IdSet{Any}()
    systems = Any[]
    seen = Any[]
    nbeams = nrays = nsegments = max_depth = 0
    for (p, h) in zip(gui.pairs, gui.beam_handles)
        src = p.second
        _has(seen, src) && continue
        push!(seen, src)
        (_beam_on(gui, src) && !_beam_stale(gui, src)) || continue
        _has(systems, p.first) || push!(systems, p.first)
        settings = render_settings(h)
        every = Int(get(settings, :render_every, 1))
        segments = try
            BMO.path_segments(src; flen = settings.flen)
        catch
            # a source that BeamletOptics can not flatten: no ends and hits of it
            continue
        end
        for s in segments
            # Of a beam group, only the beams that are drawn
            (s.beam_index - 1) % every == 0 || continue
            nsegments += 1
            max_depth = max(max_depth, s.depth)
            isnothing(s.object) || push!(hit_objects, s.object)
            s.leaf || continue
            reason = _end_reason(s, r_max, depth_max)
            counts[reason] += 1
            push!(ends[_end_key(reason)], Point3f(s.stop))
        end
        for beam in _drawn_beams(src, every)
            nbeams += 1
            nrays += _debug_hits!(hits, beam)
        end
    end
    # At most `_RAYS_HIT_CAP` hit points, every k-th
    k = max(1, cld(length(hits), _RAYS_HIT_CAP))
    shown = hits[1:k:end]
    L = Float32(_RAYS_NORMAL * _scene_bounds(gui)[2])
    unhit = _unhit(systems, hit_objects)
    # The 3D points, then the plots
    for key in _RAYS_END_KEYS
        copy!(r.ends[key], ends[key])
        r.plots[key].color = _end_color(t, key)
    end
    copy!(r.hits, Point3f[first(x) for x in shown])
    empty!(r.normals)
    for (p, n) in shown
        push!(r.normals, p, p + L * n)
    end
    copy!(r.unhit, Point3f[Point3f(position(obj)) for obj in unhit])
    r.plots[:labels].color = t.stale_text
    _debug(gui).stats.rays = _RaySummary(nbeams, nrays, nsegments, max_depth, counts,
        length(shown), unhit)
    r.fresh = true
    _show_rays!(r, true)
    return nothing
end

"""
    _end_reason(segment, r_max, depth_max) -> Symbol

Why the branch of a beam ends with the leaf `segment` (see `BMO.path_segments`): `:r_max` if its
beam has the most rays a solve traces (`r_max`), `:depth_max` if the solve cut off the children of
its beam, which lies deeper than `depth_max` in the tree of the beams (only a segment that ends on
an object can have children), `:open` if it flies on (a final ray, or an intersection that does
not name its object), otherwise `:object`, it ends on an object, e.g. a detector.
"""
function _end_reason(s, r_max::Integer, depth_max::Integer)
    s.ray_index >= r_max && return :r_max
    (!s.final && s.depth > depth_max) && return :depth_max
    (s.final || isnothing(s.object)) && return :open
    return :object
end

# The root beams of a source that are drawn: of a beam group every `every`-th
_drawn_beams(bg::BMO.AbstractBeamGroup, every::Int) = BMO.beams(bg)[1:every:end]
_drawn_beams(beam, ::Int) = (beam,)

"""
    _debug_hits!(hits, beam) -> Int

Appends the hit point and the normal of each ray of the `beam` and of its children (of a Gaussian
beamlet: of its chief rays) that has an intersection to `hits`, the normal towards the side the ray
comes from. Returns the number of rays of the beam, of a Gaussian beamlet also its waist and
divergence rays.
"""
function _debug_hits!(hits, beam::BMO.Beam)
    n = 0
    for b in PreOrderDFS(beam)
        _ray_hits!(hits, b)
        n += length(BMO.rays(b))
    end
    return n
end

function _debug_hits!(hits, g::BMO.GaussianBeamlet)
    n = 0
    for b in PreOrderDFS(g)
        _ray_hits!(hits, b.chief)
        n += length(BMO.rays(b.chief)) + length(BMO.rays(b.waist)) + length(BMO.rays(b.divergence))
    end
    return n
end

function _debug_hits!(hits, g::BMO.AstigmaticGaussianBeamlet)
    n = 0
    for b in PreOrderDFS(g)
        _ray_hits!(hits, b.c)
        n += sum(f -> length(BMO.rays(getfield(b, f))), (:c, :wxp, :wxm, :wyp, :wym, :dxp, :dxm, :dyp, :dym))
    end
    return n
end

_debug_hits!(hits, _) = 0

# The hit points and normals of the rays of one branch of a beam
function _ray_hits!(hits, beam::BMO.Beam)
    for ray in BMO.rays(beam)
        isect = BMO.intersection(ray)
        isnothing(isect) && continue
        n = Vector{Float64}(BMO.normal3d(isect))
        norm(n) > 0 || continue
        n = normalize(n)
        dot(n, BMO.direction(ray)) > 0 && (n = -n)
        push!(hits, (Point3f(BMO.hit_point(ray)), Vec3f(n)))
    end
    return hits
end

"""
The components of the `systems` that no ray hit, i.e. that are none of the `hit` objects of the
intersections, neither themselves nor one of their parts (see `_parts`). Of a group its objects, see
`_leaves`; mechanics (`NonInteractableObject`) are left out, since no ray can hit them.
"""
function _unhit(systems, hit)
    out = Any[]
    for sys in systems, leaf in _leaves(sys)
        leaf isa BMO.NonInteractableObject && continue
        _has(out, leaf) && continue
        any(p -> p in hit, _parts(leaf, BMO.shape_trait_of(leaf))) || push!(out, leaf)
    end
    return out
end

# Shows the plots of `r` while the mode is on and the last solve is shown, see `_DebugRays`. With
# `update`, also when they are shown already: their points changed
function _show_rays!(r::_DebugRays, update::Bool = false)
    v = r.on && r.fresh
    v && (update || !r.visible[]) && _project_rays!(r)
    r.visible[] == v || (r.visible[] = v)
    return nothing
end

"""
    _project_rays!(r::_DebugRays)

Projects the 3D points of `r` into the pixel scene of its plots, with the camera of the 3D scene: a
point behind the camera is `NaN`, which is not drawn.
"""
function _project_rays!(r::_DebugRays)
    pv = Makie.camera(r.scene).projectionview[]
    wh = Makie.widths(Makie.viewport(r.scene)[])
    for k in _RAYS_END_KEYS
        r.ends_px[k][] = _rays_px(pv, wh, r.ends[k])
    end
    r.normals_px[] = _rays_px(pv, wh, r.normals)
    r.hits_px[] = _rays_px(pv, wh, r.hits)
    # The texts first, the plot is computed when it is drawn
    length(r.unhit_text[]) == length(r.unhit) || (r.unhit_text[] = fill("never hit", length(r.unhit)))
    r.unhit_px[] = _rays_px(pv, wh, r.unhit)
    return nothing
end

# The pixel positions of the 3D points `ps` with the matrix `pv` of the camera in a view of the
# size `wh` [px]
function _rays_px(pv, wh, ps::Vector{Point3f})
    out = Vector{Point2f}(undef, length(ps))
    for (i, p) in enumerate(ps)
        c = pv * Makie.Vec4f(p[1], p[2], p[3], 1)
        out[i] = c[4] > 0 ?
                 Point2f((c[1] / c[4] + 1) * wh[1] / 2, (c[2] / c[4] + 1) * wh[2] / 2) :
                 Point2f(NaN, NaN)
    end
    return out
end
