#=
The debug mode of the live view: the bounding spheres of the shapes of the traced components, and
the main spheres of the components of several shapes and of the groups, as an overlay, see `_Debug`
and `_set_debug!`
=#

"""
    _Debug

The debug mode of a `LiveView`, see the `debug` kwarg of [`live_view`](@ref): while it is `shown`,
the view draws the bounding spheres of its traced components, i.e. the spheres with which the
solver of BeamletOptics skips what a ray can not hit (`BeamletOptics.bounding_sphere_of`):

- the sphere of each part with a shape of its own (see `_debug_parts`), in magenta
- the main sphere of each object of several shapes and of each group (see `_debug_mains`), which
  encloses the spheres of its parts, in orange

`handles` maps each of these parts and objects to the render handle of its sphere, which follows
its pose; one without a sphere (`BeamletOptics.NoBoundingSphere`) has no entry, e.g. a
`NonInteractableObject` and a group that contains one. The handles are created when the mode is
switched on, afterwards only the `visible` attribute of their plots is set; a main sphere is drawn
again when its parts have moved relative to each other, see `_update_debug!`. They are not part of
the handle of the controls, i.e. they are neither picked nor part of the selection box, the camera
fit, the theme and the object tree. `toggle` is its tool.
"""
mutable struct _Debug
    shown::Bool
    const handles::IdDict{Any, AbstractObjectRenderHandle}
    toggle::Any
end

"""
    _debug_parts(x) -> Vector{Any}

The parts of `x` with a shape of its own, each of which the solver tests on its own: `x` itself for
a `SingleShape` object or a shape, the parts of the elements of `BeamletOptics.shape(x)` for a
`MultiShape` object, e.g. a group, a doublet or a cube beamsplitter (recursively); none for
anything else, e.g. a source.
"""
_debug_parts(x) = _debug_parts!(Any[], x)
_debug_parts!(parts, x::BMO.AbstractObject) = _debug_parts!(parts, x, BMO.shape_trait_of(x))
_debug_parts!(parts, x::BMO.AbstractShape) = push!(parts, x)
_debug_parts!(parts, _) = parts
_debug_parts!(parts, x, ::BMO.SingleShape) = push!(parts, x)
function _debug_parts!(parts, x, ::BMO.MultiShape)
    foreach(p -> _debug_parts!(parts, p), BMO.shape(x))
    return parts
end
_debug_parts!(parts, _, ::BMO.AbstractShapeTrait) = parts

"""
    _debug_mains(x) -> Vector{Any}

The objects of `x` with a main sphere, i.e. a sphere around the spheres of their parts, with which
the solver skips all of them at once: `x` itself if it is a `MultiShape` object, e.g. a group, a
doublet or a cube beamsplitter, and those of the elements of `BeamletOptics.shape(x)`
(recursively), each one before the ones it contains; none for anything else, e.g. a `SingleShape`
object, a shape or a source.
"""
_debug_mains(x) = _debug_mains!(Any[], x)
_debug_mains!(mains, x::BMO.AbstractObject) = _debug_mains!(mains, x, BMO.shape_trait_of(x))
_debug_mains!(mains, _) = mains
function _debug_mains!(mains, x, ::BMO.MultiShape)
    push!(mains, x)
    foreach(p -> _debug_mains!(mains, p), BMO.shape(x))
    return mains
end
_debug_mains!(mains, _, ::BMO.AbstractShapeTrait) = mains

"""The top-level objects of the systems of the `gui`, i.e. the traced components without the extras."""
_debug_tops(gui::LiveView) = (top for h in gui.system_handles for top in _top_levels(h))

"""
Whether the spheres of the object `obj` of the `gui` are visible: while the debug mode `d` is
shown, unless `obj` is hidden (a group: all its objects), and never in the spectator mode.
"""
_debug_visible(gui::LiveView, d::_Debug, obj) =
    d.shown && !gui.controls.spectator[] && !_all_hidden(gui, obj)

# The sphere of a part, and the main sphere of an object in orange: overlays like the markers of
# the sources, which are never clipped
_debug_draw(gui::LiveView, part) =
    () -> render_bounding_sphere!(gui.ax, part; clip_planes = Plane3f[], inspectable = false)
_debug_draw_main(gui::LiveView, obj) =
    () -> render_bounding_sphere!(gui.ax, BMO.bounding_sphere_of(obj); color = :orange,
        clip_planes = Plane3f[], inspectable = false)

# Stores the handle of the plots of `draw`, which follow the pose of `x`, unless `x` has one or
# nothing was drawn, i.e. `x` has no bounding sphere
function _add_debug_handle!(gui::LiveView, d::_Debug, x, draw)
    haskey(d.handles, x) && return nothing
    oh = live_render!(draw, gui.ax, x)
    isempty(render_plots(oh)) || (d.handles[x] = oh)
    return nothing
end

"""
    _add_debug!(gui, d::_Debug, top)

Draws the bounding spheres of the top-level object `top` of the `gui` that are not drawn yet, via
`render_bounding_sphere!` of BeamletOptics, as plots that follow the pose of what they enclose (see
`live_render!(draw, ax, x)`): the sphere of each of its parts (see `_debug_parts`) and, in orange,
the main sphere of each of its objects of several shapes and groups (see `_debug_mains`). An
overlay like the markers of the sources: it is never clipped. A part or object without a bounding
sphere, e.g. a `NonInteractableObject` and a group that contains one, gets no handle.
"""
function _add_debug!(gui::LiveView, d::_Debug, top)
    foreach(part -> _add_debug_handle!(gui, d, part, _debug_draw(gui, part)), _debug_parts(top))
    foreach(obj -> _add_debug_handle!(gui, d, obj, _debug_draw_main(gui, obj)), _debug_mains(top))
    return nothing
end

# Sets the `visible` attribute of the sphere of `x`, if it has one
function _show_debug_handle!(d::_Debug, x, visible::Bool)
    oh = get(d.handles, x, nothing)
    isnothing(oh) && return nothing
    for plot in render_plots(oh)
        plot.visible[] == visible || (plot.visible[] = visible)
    end
    return nothing
end

"""
    _show_debug!(gui)

Sets the `visible` attribute of the bounding spheres of the `gui`, see `_debug_visible`: after the
debug mode was switched, objects were hidden or shown, and the spectator mode was switched. The
spheres of the parts are hidden with their rendered object, a main sphere with its object, i.e.
that of a group when all its objects are hidden.
"""
_show_debug!(gui::LiveView) = _show_debug!(gui, gui.components.debug)
_show_debug!(::LiveView, ::Nothing) = nothing
function _show_debug!(gui::LiveView, d::_Debug)
    for top in _debug_tops(gui)
        for leaf in _leaves(top)
            visible = _debug_visible(gui, d, leaf)
            foreach(part -> _show_debug_handle!(d, part, visible), _debug_parts(leaf))
        end
        foreach(obj -> _show_debug_handle!(d, obj, _debug_visible(gui, d, obj)), _debug_mains(top))
    end
    return nothing
end

"""
    _update_debug!(gui)

Moves the bounding spheres of the `gui` to the poses of what they enclose, while the debug mode is
shown: after each change of the pose of an object, next to `update_render!` of the handle of the
controls.

A main sphere changes when the parts of its object move relative to each other, e.g. an object of
a group that is moved on its own. `update_render!` of BeamletOptics then draws it again; the main
spheres of the groups around such an object are drawn again here, since the parts of these groups
have not moved. The new plots get their `visible` attribute, see `_show_debug!`.
"""
_update_debug!(gui::LiveView) = _update_debug!(gui, gui.components.debug)
_update_debug!(::LiveView, ::Nothing) = nothing
function _update_debug!(gui::LiveView, d::_Debug)
    d.shown || return nothing
    redrawn = Base.IdSet{Any}()
    for top in _debug_tops(gui)
        for part in _debug_parts(top)
            oh = get(d.handles, part, nothing)
            isnothing(oh) || update_render!(oh)
        end
        # each object after the ones it contains
        for obj in Iterators.reverse(_debug_mains(top))
            oh = get(d.handles, obj, nothing)
            isnothing(oh) && continue
            if any(p -> p in redrawn, BMO.shape(obj))
                remove_render!(oh)
                d.handles[obj] = live_render!(_debug_draw_main(gui, obj), gui.ax, obj)
                push!(redrawn, obj)
            else
                plots = render_plots(oh)
                update_render!(oh)
                render_plots(oh) === plots || push!(redrawn, obj)
            end
        end
    end
    isempty(redrawn) || _show_debug!(gui, d)
    return nothing
end

"""
    _set_debug!(gui, shown::Bool)

Switches the debug mode of the `gui` on or off, see `_Debug`. Switched on, the spheres that are not
drawn yet are drawn, e.g. all of them the first time, and all spheres are moved to the poses of
what they enclose, which may have changed while the mode was off.
"""
function _set_debug!(gui::LiveView, shown::Bool)
    d = gui.components.debug
    d.shown = shown
    if shown
        foreach(top -> _add_debug!(gui, d, top), collect(_debug_tops(gui)))
        _update_debug!(gui, d)
    end
    _show_debug!(gui, d)
    gui.status.text[] = shown ? "debug mode on: bounding spheres of the shapes" : "debug mode off"
    return nothing
end

"""
    _debug_attach!(gui, obj)

Draws the bounding spheres of the component `obj` that was added to the `gui`, while the debug mode
is shown, see `_attach!`; otherwise they are drawn when it is switched on.
"""
_debug_attach!(gui::LiveView, obj) = _debug_attach!(gui, gui.components.debug, obj)
_debug_attach!(::LiveView, ::Nothing, _) = nothing
function _debug_attach!(gui::LiveView, d::_Debug, obj)
    d.shown || return nothing
    _add_debug!(gui, d, obj)
    _show_debug!(gui, d)
    return nothing
end

"""
    _debug_release!(gui, obj)

Removes the bounding spheres of the parts of `obj` and the main spheres of `obj` and of its
objects, which is removed from the `gui`, see `_release!`.
"""
_debug_release!(gui::LiveView, obj) = _debug_release!(gui.components.debug, obj)
_debug_release!(::Nothing, _) = nothing
function _debug_release!(d::_Debug, obj)
    for x in Iterators.flatten((_debug_parts(obj), _debug_mains(obj)))
        oh = pop!(d.handles, x, nothing)
        isnothing(oh) || remove_render!(oh)
    end
    return nothing
end

# The `debug` kwarg of `live_view` that builds the debug mode `d` again, see `_open_kwargs`
_debug_kwarg(::Nothing) = false
_debug_kwarg(d::_Debug) = d.shown

"""
    _build_debug!(gui, debug::Bool)

Creates the debug mode of the `gui` with its toggle "Debug" among the tools of the layout, which
has no key. With `debug`, the `debug` kwarg of [`live_view`](@ref), it starts switched on and keeps
the status line as it is.
"""
function _build_debug!(gui::LiveView, debug::Bool)
    d = _Debug(false, IdDict{Any, AbstractObjectRenderHandle}(), nothing)
    gui.components.debug = d
    d.toggle = add_tool!(_set_debug!, gui, "Debug"; icon = :mesh, toggle = true,
        tooltip = "Debug mode: the bounding spheres of the shapes")
    if debug
        status = gui.status.text[]
        d.toggle.active[] = true
        gui.status.text[] = status
    end
    return nothing
end
