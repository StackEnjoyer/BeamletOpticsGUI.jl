#=
The debug mode of the live view: the bounding spheres of the shapes of the traced components as an
overlay, see `_Debug` and `_set_debug!`
=#

"""
    _Debug

The debug mode of a `LiveView`, see the `debug` kwarg of [`live_view`](@ref): while it is `shown`,
the view draws the bounding sphere of each shape of its traced components, i.e. the sphere with
which the solver of BeamletOptics skips the shape (`BeamletOptics.world_bounding_sphere`). `handles`
maps each part with a shape of its own (see `_debug_parts`) to the render handle of its sphere,
which follows the pose of the part; a part whose shape has no sphere has no entry. The handles are
created when the mode is switched on, afterwards only the `visible` attribute of their plots is
set. They are not part of the handle of the controls, i.e. they are neither picked nor part of the
selection box, the camera fit, the theme and the object tree. `toggle` is its tool.
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

"""The rendered objects of the systems of the `gui`, i.e. the traced components without the extras."""
_debug_leaves(gui::LiveView) = (leaf for h in gui.system_handles for leaf in _leaves(h))

"""
Whether the spheres of the parts of the rendered object `leaf` of the `gui` are visible: while the
debug mode `d` is shown, unless `leaf` is hidden, and never in the spectator mode.
"""
_debug_visible(gui::LiveView, d::_Debug, leaf) =
    d.shown && !gui.controls.spectator[] && !(leaf in gui.objects.hidden)

"""
    _add_debug!(gui, d::_Debug, leaf)

Draws the bounding spheres of the parts of the rendered object `leaf` of the `gui` that have none
yet, via `render_bounding_sphere!` of BeamletOptics, as plots that follow the pose of the part (see
`live_render!(draw, ax, x)`). An overlay like the markers of the sources: it is never clipped. A
part whose shape has no bounding sphere, e.g. a mesh, gets no handle.
"""
function _add_debug!(gui::LiveView, d::_Debug, leaf)
    for part in _debug_parts(leaf)
        haskey(d.handles, part) && continue
        draw = () -> render_bounding_sphere!(gui.ax, part; clip_planes = Plane3f[], inspectable = false)
        oh = live_render!(draw, gui.ax, part)
        isempty(render_plots(oh)) || (d.handles[part] = oh)
    end
    return nothing
end

"""
    _show_debug!(gui)

Sets the `visible` attribute of the bounding spheres of the `gui`, see `_debug_visible`: after the
debug mode was switched, objects were hidden or shown, and the spectator mode was switched.
"""
_show_debug!(gui::LiveView) = _show_debug!(gui, gui.components.debug)
_show_debug!(::LiveView, ::Nothing) = nothing
function _show_debug!(gui::LiveView, d::_Debug)
    for leaf in _debug_leaves(gui)
        visible = _debug_visible(gui, d, leaf)
        for part in _debug_parts(leaf)
            oh = get(d.handles, part, nothing)
            isnothing(oh) && continue
            for plot in render_plots(oh)
                plot.visible[] == visible || (plot.visible[] = visible)
            end
        end
    end
    return nothing
end

"""
    _update_debug!(gui)

Moves the bounding spheres of the `gui` to the poses of their parts, while the debug mode is shown:
after each change of the pose of an object, next to `update_render!` of the handle of the controls.
"""
_update_debug!(gui::LiveView) = _update_debug!(gui.components.debug)
_update_debug!(::Nothing) = nothing
function _update_debug!(d::_Debug)
    d.shown || return nothing
    foreach(update_render!, values(d.handles))
    return nothing
end

"""
    _set_debug!(gui, shown::Bool)

Switches the debug mode of the `gui` on or off, see `_Debug`. Switched on, the spheres of the parts
that have none yet are drawn, e.g. all of them the first time, and all spheres are moved to the
poses of their parts, which may have changed while the mode was off.
"""
function _set_debug!(gui::LiveView, shown::Bool)
    d = gui.components.debug
    d.shown = shown
    if shown
        foreach(leaf -> _add_debug!(gui, d, leaf), collect(_debug_leaves(gui)))
        _update_debug!(d)
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
    foreach(leaf -> _add_debug!(gui, d, leaf), _leaves(obj))
    _show_debug!(gui, d)
    return nothing
end

"""
    _debug_release!(gui, obj)

Removes the bounding spheres of the parts of `obj`, which is removed from the `gui`, see `_release!`.
"""
_debug_release!(gui::LiveView, obj) = _debug_release!(gui.components.debug, obj)
_debug_release!(::Nothing, _) = nothing
function _debug_release!(d::_Debug, obj)
    for part in _debug_parts(obj)
        oh = pop!(d.handles, part, nothing)
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
