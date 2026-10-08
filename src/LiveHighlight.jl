#=
Highlight while a group is browsed on the selection card: the group see-through, the boxes of its
parts, the box of the hovered part, see `LiveSelectionCard.jl`
=#

# Opacity of the browsed group relative to its opacity before browsing
const _BROWSE_OPACITY = 0.25
# Boxes of the parts: thin and translucent in the accent color of the theme; the hovered one thick in
# the color of the selection box of the controls (see `kinematic_controls!`)
const _PART_BOX_WIDTH = 1.5
const _PART_BOX_ALPHA = 0.55
const _HOVER_BOX_WIDTH = 4.0
const _HOVER_BOX_COLOR = :yellow

"""
    _Highlight

The highlight of a `LiveView` while the `group` (a group or a `MultiShape` object) is browsed on
the selection card, see `_browse_highlight!`: per plot of the `group`, its attributes before
browsing in `base` (`alpha`, `transparency` and the image marker of a scatter, `nothing` for other
plots), the `boxes` of the parts (`part => plot`, in the order of the parts) and the `hovered` part
(`nothing`: none), see `_hover_highlight!`.
"""
mutable struct _Highlight
    group::Any
    base::IdDict{AbstractPlot, Tuple{Float32, Bool, Any}}
    boxes::Vector{Pair{Any, AbstractPlot}}
    hovered::Any
end

# The highlight is a field of the `gui` (`gui.objects.highlight`) and not an entry of a global
# registry: it holds plots, which lead back to the `gui` via their scene, and a `WeakKeyDict` never
# frees a key that its value refers to, i.e. no closed window of a session
"""Returns the highlight of the `gui` (see `_Highlight`), `nothing` while no group is browsed."""
_highlight(gui::LiveView) = gui.objects.highlight::Union{Nothing, _Highlight}

"""
    _browse_highlight!(gui, group, parts)

Highlights the browsed `group` of the `gui` (a group or a `MultiShape` object, see
`LiveSelectionCard.jl`): its plots at `_BROWSE_OPACITY` of their current opacity, i.e. including an
opacity set by the user (see `_set_opacity!`), which is not changed, and a thin box around each of
the `parts` in the accent color of the theme. A part without plots of its own, e.g. a lens of a
doublet, gets the box of the nearest object with plots that it is a part of, see `_part_box`.
A level inside the browsed group (its plots already see-through) keeps the outer group see-through
and only replaces the boxes; any other group replaces the previous highlight. `_end_highlight!`
ends it.
"""
function _browse_highlight!(gui::LiveView, group, parts::Vector)
    plots = _object_plots(gui.controls.h, group)
    hl = _highlight(gui)
    if !isnothing(hl) && all(p -> haskey(hl.base, p), plots)
        # A level inside the browsed group: it stays see-through, only the boxes change, else the
        # opaque rest of the outer group would hide the parts (e.g. the housing of a telescope)
        for (_, box) in hl.boxes
            delete!(gui.ax, box)
        end
        empty!(hl.boxes)
        hl.group, hl.hovered = group, nothing
    else
        _end_highlight!(gui)
        hl = _Highlight(group, IdDict{AbstractPlot, Tuple{Float32, Bool, Any}}(),
            Pair{Any, AbstractPlot}[], nothing)
        gui.objects.highlight = hl
    end
    for p in plots
        haskey(hl.base, p) && continue
        hl.base[p] = (_plot_alpha(p), Bool(p.transparency[]), _image_marker(p))
        _dim_plot!(p, _BROWSE_OPACITY)
    end
    color = _part_box_color(gui)
    for part in parts
        bb = _part_box(gui, part)
        isnothing(bb) && continue
        box = linesegments!(gui.ax, _bbox_wireframe(bb); color, linewidth = _PART_BOX_WIDTH,
            clip_planes = Plane3f[], inspectable = false)
        push!(hl.boxes, part => box)
    end
    return nothing
end

_part_box_color(gui::LiveView) = RGBAf(Makie.to_color(gui.layout.theme.accent), _PART_BOX_ALPHA)

"""
    _part_box(gui, part)

The bounding box of the plots of `part` (see `_selection_bbox`), or, without plots of its own, of
the nearest object with plots that it is a part of (see `_part_parent`); `nothing` if there is none.
"""
function _part_box(gui::LiveView, part)
    ctrl = gui.controls
    x = part
    while !isnothing(x)
        plots = _object_plots(ctrl.h, x)
        isempty(plots) || return _selection_bbox(ctrl, x, plots)
        x = _part_parent(gui, x)
    end
    return nothing
end

"""
    _dim_plot!(p, s)

Scales the current opacity of the plot `p` with `s < 1` and makes it `transparency = true`, see
`_apply_opacity!`. The colors are not changed; the alpha of per-vertex colors is multiplied by the
`alpha` of the plot.
"""
_dim_plot!(p::AbstractPlot, s) = _apply_opacity!(p, _plot_base(p)..., s)

"""Restores the plot `p` to its `alpha`, `transparency` and image `marker` (`nothing`: none)."""
function _restore_plot!(p::AbstractPlot, alpha, transparency, marker)
    if isnothing(marker)
        haskey(p, :alpha) && (p.alpha[] == alpha || (p.alpha[] = alpha))
    else
        p.marker[] = marker
    end
    _set_transparency!(p, transparency)
    return nothing
end

"""
    _hover_highlight!(gui, part)

Highlights the box of the `part` of the browsed group of the `gui` (see `_browse_highlight!`): thick
in the color of the selection box, the other boxes thin; `nothing` highlights none. Does nothing
without a highlight.
"""
function _hover_highlight!(gui::LiveView, part)
    hl = _highlight(gui)
    isnothing(hl) && return nothing
    hl.hovered = part
    thin = _part_box_color(gui)
    thick = RGBAf(Makie.to_color(_HOVER_BOX_COLOR))
    for (x, box) in hl.boxes
        color, width = !isnothing(part) && x === part ? (thick, _HOVER_BOX_WIDTH) :
                       (thin, _PART_BOX_WIDTH)
        box.color[] == color || (box.color[] = color)
        box.linewidth[] == width || (box.linewidth[] = width)
    end
    return nothing
end

"""
    _end_highlight!(gui)

Ends the highlight of the browsed group of the `gui` (see `_browse_highlight!`): restores the
attributes of its plots exactly as they were before browsing and removes the boxes. Does nothing
without a highlight.
"""
function _end_highlight!(gui::LiveView)
    hl = _highlight(gui)
    isnothing(hl) && return nothing
    gui.objects.highlight = nothing
    for (p, base) in hl.base
        _restore_plot!(p, base...)
    end
    for (_, box) in hl.boxes
        delete!(gui.ax, box)
    end
    return nothing
end

#=
Highlight of the members of a system: of the inspected system, and while its members are picked,
see `_inspect!` and `_set_member_pick!`
=#

# Opacity of what is not a member of the inspected system, relative to its opacity before, and
# while the members of a system are picked, where a click on the rest is what is asked for
const _SYSTEM_OPACITY = 0.4
const _PICK_OPACITY = 0.25

"""
    _SystemHighlight

The highlight of the members of a system of a `LiveView`, see `_update_system_highlight!`: the
`opacity` of the plots that are no members, relative to their opacity before, and these plots in
`dimmed` with their attributes before (`alpha`, `transparency` and the image marker of a scatter,
like `base` of `_Highlight`).
"""
mutable struct _SystemHighlight
    opacity::Float64
    dimmed::IdDict{AbstractPlot, Tuple{Float32, Bool, Any}}
end

"""
Returns the highlight of the members of a system of the `gui` (see `_SystemHighlight`), `nothing`
without one. A field of the `gui` like `_highlight`.
"""
_system_highlight(gui::LiveView) = gui.objects.system_highlight::Union{Nothing, _SystemHighlight}

"""
    _system_dimmed(gui) -> IdDict

The plots of the `gui` that are see-through because they are no members of the highlighted system,
with their attributes before, see `_update_system_highlight!`; empty without such a system.
"""
function _system_dimmed(gui::LiveView)
    hl = _system_highlight(gui)
    return isnothing(hl) ? IdDict{AbstractPlot, Tuple{Float32, Bool, Any}}() : hl.dimmed
end

"""
    _highlighted_system(gui) -> Union{Nothing, Tuple}

The system of the `gui` whose members are highlighted and the opacity of everything else: the
system of the pick of members (see `_set_member_pick!`) with `_PICK_OPACITY`, else the inspected
system (see `_inspect!`), e.g. the one whose row of the object tree was clicked, with
`_SYSTEM_OPACITY`; also the objects without a system, which the row "No system" inspects. `nothing`
without one and in the spectator mode, which shows the view as it is.
"""
function _highlighted_system(gui::LiveView)
    pick = _member_pick(gui)
    isnothing(pick) || return (pick.sys, _PICK_OPACITY)
    sys = gui.objects.inspected
    (sys isa BMO.AbstractSystem && !gui.controls.spectator[]) || return nothing
    return (sys, _SYSTEM_OPACITY)
end

"""
    _update_system_highlight!(gui)

Shows the members of the highlighted system of the `gui` (see `_highlighted_system`) in its 3D view:
its objects and the markers of its sources are shown as they are, and the plots of all other
components and source markers see-through, at the opacity of the highlight relative to their own,
like a browsed group (see `_browse_highlight!`); clip planes and beams are not changed. Without such
a system, e.g. after a click on the empty space of the 3D view, which ends the inspection, all
plots get their attributes back. Only the plots whose state changes are touched, hence it is called
after every change of the selection and of the members, and every frame, e.g. for a component that
is added meanwhile.
"""
function _update_system_highlight!(gui::LiveView)
    target = _highlighted_system(gui)
    hl = _system_highlight(gui)
    isnothing(target) && isnothing(hl) && return nothing
    # the plots of the components and source markers of the view, and those that are to be see-through
    shown, wanted = Base.IdSet{AbstractPlot}(), Base.IdSet{AbstractPlot}()
    members = Base.IdSet{Any}()
    if !isnothing(target)
        sys, opacity = target
        foreach(obj -> foreach(leaf -> push!(members, leaf), _leaves(obj)), sys.objects)
        foreach(src -> push!(members, src), _sources_of(gui, sys))
        if isnothing(hl)
            hl = gui.objects.system_highlight = _SystemHighlight(opacity,
                IdDict{AbstractPlot, Tuple{Float32, Bool, Any}}())
        elseif hl.opacity != opacity
            # e.g. a pick that starts or ends on the inspected system: dimmed again from the
            # attributes before
            for (p, base) in hl.dimmed
                _restore_plot!(p, base...)
            end
            empty!(hl.dimmed)
            hl.opacity = opacity
        end
    end
    for oh in render_children(gui.controls.h)
        x = rendered(oh)
        _pick_candidate(x) || continue
        for p in _pickable_plots(oh)
            push!(shown, p)
            (isnothing(target) || x in members) || push!(wanted, p)
        end
    end
    for (p, base) in collect(hl.dimmed)
        p in wanted && continue
        # the plots of a component that was removed meanwhile are deleted, not restored
        p in shown && _restore_plot!(p, base...)
        delete!(hl.dimmed, p)
    end
    for p in wanted
        haskey(hl.dimmed, p) && continue
        hl.dimmed[p] = (_plot_alpha(p), Bool(p.transparency[]), _image_marker(p))
        _dim_plot!(p, hl.opacity)
    end
    isnothing(target) && (gui.objects.system_highlight = nothing)
    return nothing
end

"""
    _part_under_cursor(gui, parts)

Returns the part among `parts` under the cursor in the 3D view of the `gui`, or `nothing`. Picked
like the controls pick (see `kinematic_controls!`), but among the `parts` only and regardless of
their opacity, since the browsed group is see-through (see `_MIN_PICK_OPACITY`): with the custom
`pick` of the controls, the part whose plots contain the picked plot (see `_plot_part`); without
it, the part hit by the camera ray (see `_ray_pick`), which also finds parts without plots of their
own, e.g. the lenses of a doublet, else the part of the plot under the cursor. Hidden parts are not
picked.
"""
function _part_under_cursor(gui::LiveView, parts)
    shown = Any[x for x in parts if !_all_hidden(gui, x)]
    isempty(shown) && return nothing
    pick = gui.controls.pick
    if isnothing(pick)
        origin, dir = _cursor_ray(Makie.get_scene(gui.ax))
        part, _ = _ray_pick(shown, origin, dir, x -> _part_box(gui, x))
        isnothing(part) || return part
        plot, _ = _default_pick(gui.ax)
    else
        plot, _ = pick(gui.ax)
    end
    return _plot_part(gui, shown, plot)
end

"""
    _plot_part(gui, parts, plot)

The part among `parts` that the `plot` belongs to: the part whose box it is (see
`_browse_highlight!`), or the part that contains the rendered object of the `plot` (see
`_pick_leaf`), itself or at any level of its groups; `nothing` if none does.
"""
function _plot_part(gui::LiveView, parts, plot)
    isnothing(plot) && return nothing
    hl = _highlight(gui)
    if !isnothing(hl)
        i = findfirst(b -> last(b) === plot, hl.boxes)
        isnothing(i) || return first(hl.boxes[i])
    end
    leaf = _pick_leaf(gui.controls.h, plot)
    isnothing(leaf) && return nothing
    chain = _chain(gui.controls, leaf)
    i = findfirst(x -> _has(chain, x), parts)
    return isnothing(i) ? nothing : parts[i]
end
