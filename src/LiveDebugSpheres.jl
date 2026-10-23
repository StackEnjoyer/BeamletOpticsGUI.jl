#=
The bounding spheres of the debug mode: the spheres of the shapes of the traced components, and the
main spheres of the components of several shapes and of the groups, as an overlay, see
`_DebugSpheres`
=#

"""
    _DebugSpheres

The layer `:spheres` of the debug mode (see `_DebugLayer`): it draws the bounding spheres of the
traced components of the view, i.e. the spheres with which the solver of BeamletOptics skips what a
ray can not hit (`BeamletOptics.bounding_sphere_of`):

- the sphere of each part with a shape of its own (see `_debug_parts`), in magenta
- the main sphere of each object of several shapes and of each group (see `_debug_mains`), which
  encloses the spheres of its parts, in orange

`handles` maps each of these parts and objects to the render handle of its sphere, which follows
its pose; one without a sphere (`BeamletOptics.NoBoundingSphere`) has no entry, e.g. a
`NonInteractableObject` and a group that contains one. The handles are created when the layer is
first brought up to date, afterwards only the `visible` attribute of their plots is set; a main
sphere is drawn again when its parts have moved relative to each other, see `_update_spheres!`.
They are not part of the handle of the controls, i.e. they are neither picked nor part of the
selection box, the camera fit, the theme and the object tree. `on` is whether they may be visible,
i.e. the mode is on and the spectator mode is off.
"""
mutable struct _DebugSpheres <: _DebugLayer
    on::Bool
    const handles::IdDict{Any, AbstractObjectRenderHandle}
end

_new_layer(::LiveView, ::Val{:spheres}) = _DebugSpheres(false, IdDict{Any, AbstractObjectRenderHandle}())

"""
    _debug_parts(x) -> Vector{Any}

The parts of `x` with a shape of its own, each of which the solver tests on its own: `x` itself for
a `SingleShape` object or a shape, the parts of the elements of `BeamletOptics.shape(x)` for a
`MultiShape` object (recursively), the parts of the objects of a group; none for anything else,
e.g. a source.
"""
_debug_parts(@nospecialize(x)) = _debug_parts!(Any[], x)
_debug_parts!(parts, @nospecialize(x::BMO.AbstractObject)) = _debug_parts!(parts, x, BMO.shape_trait_of(x))
_debug_parts!(parts, @nospecialize(x::BMO.AbstractShape)) = push!(parts, x)
function _debug_parts!(parts, @nospecialize(x::BMO.AbstractObjectGroup))
    for p in BMO.objects(x)
        _debug_parts!(parts, p)
    end
    return parts
end
_debug_parts!(parts, @nospecialize(_)) = parts
_debug_parts!(parts, @nospecialize(x), ::BMO.SingleShape) = push!(parts, x)
function _debug_parts!(parts, @nospecialize(x), ::BMO.MultiShape)
    for p in BMO.shape(x)
        _debug_parts!(parts, p)
    end
    return parts
end
_debug_parts!(parts, @nospecialize(_), ::BMO.AbstractShapeTrait) = parts

"""
    _debug_mains(x) -> Vector{Any}

The objects of `x` with a main sphere, i.e. a sphere around the spheres of their parts, with which
the solver skips all of them at once: `x` itself if it is a group or a `MultiShape` object, e.g. a
doublet or a cube beamsplitter, and those of the elements of `BeamletOptics.shape(x)` or of the
group (recursively), each one before the ones it contains; none for anything else, e.g. a
`SingleShape` object, a shape or a source.
"""
_debug_mains(@nospecialize(x)) = _debug_mains!(Any[], x)
_debug_mains!(mains, @nospecialize(x::BMO.AbstractObject)) = _debug_mains!(mains, x, BMO.shape_trait_of(x))
function _debug_mains!(mains, @nospecialize(x::BMO.AbstractObjectGroup))
    push!(mains, x)
    for p in BMO.objects(x)
        _debug_mains!(mains, p)
    end
    return mains
end
_debug_mains!(mains, @nospecialize(_)) = mains
function _debug_mains!(mains, @nospecialize(x), ::BMO.MultiShape)
    push!(mains, x)
    for p in BMO.shape(x)
        _debug_mains!(mains, p)
    end
    return mains
end
_debug_mains!(mains, @nospecialize(_), ::BMO.AbstractShapeTrait) = mains

# What the main sphere of `x` encloses: the objects of a group, the shapes of an object
_debug_subs(@nospecialize(x::BMO.AbstractObjectGroup)) = BMO.objects(x)
_debug_subs(@nospecialize(x)) = BMO.shape(x)

# The top-level objects of the systems of the `gui`, i.e. the traced components without the extras
_debug_tops(gui::LiveView) = (top for h in gui.system_handles for top in _top_levels(h))

# Whether the spheres of the object `x` are visible: the layer is on, unless `x` is hidden (a
# group: all its objects)
_spheres_visible(gui::LiveView, layer::_DebugSpheres, @nospecialize(x)) = layer.on && !_all_hidden(gui, x)

# The sphere of a part, and the main sphere of an object in orange: overlays like the markers of
# the sources, which are never clipped
_sphere_draw(gui::LiveView, @nospecialize(part)) =
    () -> render_bounding_sphere!(gui.ax, part; clip_planes = Plane3f[], inspectable = false)
_main_draw(gui::LiveView, @nospecialize(obj)) =
    () -> render_bounding_sphere!(gui.ax, BMO.bounding_sphere_of(obj); color = :orange,
        clip_planes = Plane3f[], inspectable = false)

# Stores the handle of the plots of `draw`, which follow the pose of `x`, unless `x` has one or
# nothing was drawn, i.e. `x` has no bounding sphere
function _add_sphere_handle!(gui::LiveView, layer::_DebugSpheres, @nospecialize(x), draw)
    haskey(layer.handles, x) && return nothing
    oh = live_render!(draw, gui.ax, x)
    isempty(render_plots(oh)) || (layer.handles[x] = oh)
    return nothing
end

# Draws the spheres of the top-level object `top` that are not drawn yet
function _add_spheres!(gui::LiveView, layer::_DebugSpheres, @nospecialize(top))
    for part in _debug_parts(top)
        _add_sphere_handle!(gui, layer, part, _sphere_draw(gui, part))
    end
    for obj in _debug_mains(top)
        _add_sphere_handle!(gui, layer, obj, _main_draw(gui, obj))
    end
    return nothing
end

# Sets the `visible` attribute of the sphere of `x`, if it has one
function _show_sphere_handle!(layer::_DebugSpheres, @nospecialize(x), visible::Bool)
    oh = get(layer.handles, x, nothing)
    isnothing(oh) && return nothing
    for plot in render_plots(oh)
        plot.visible[] == visible || (plot.visible[] = visible)
    end
    return nothing
end

# Sets the `visible` attribute of all spheres: the spheres of the parts are hidden with their
# rendered object, a main sphere with its object, i.e. that of a group when all its objects are hidden
function _show_spheres!(gui::LiveView, layer::_DebugSpheres)
    for top in _debug_tops(gui)
        for leaf in _leaves(top)
            visible = _spheres_visible(gui, layer, leaf)
            for part in _debug_parts(leaf)
                _show_sphere_handle!(layer, part, visible)
            end
        end
        for obj in _debug_mains(top)
            _show_sphere_handle!(layer, obj, _spheres_visible(gui, layer, obj))
        end
    end
    return nothing
end

# Moves the spheres to the poses of what they enclose, and draws those that are not drawn yet.
# A main sphere changes when the parts of its object move relative to each other, e.g. an object
# of a group that is moved on its own. `update_render!` of BeamletOptics then draws it again; the
# main spheres of the groups around such an object are drawn again here, since the parts of these
# groups have not moved.
function _update_spheres!(gui::LiveView, layer::_DebugSpheres)
    redrawn = Base.IdSet{Any}()
    for top in _debug_tops(gui)
        _add_spheres!(gui, layer, top)
        for part in _debug_parts(top)
            oh = get(layer.handles, part, nothing)
            isnothing(oh) || update_render!(oh)
        end
        # each object after the ones it contains
        for obj in Iterators.reverse(_debug_mains(top))
            oh = get(layer.handles, obj, nothing)
            isnothing(oh) && continue
            if any(p -> p in redrawn, _debug_subs(obj))
                remove_render!(oh)
                layer.handles[obj] = live_render!(_main_draw(gui, obj), gui.ax, obj)
                push!(redrawn, obj)
            else
                plots = render_plots(oh)
                update_render!(oh)
                render_plots(oh) === plots || push!(redrawn, obj)
            end
        end
    end
    isempty(redrawn) || _show_spheres!(gui, layer)
    return nothing
end

function _layer_show!(gui::LiveView, layer::_DebugSpheres, on::Bool)
    layer.on = on
    on && _update_spheres!(gui, layer)
    _show_spheres!(gui, layer)
    return nothing
end

function _layer_moved!(gui::LiveView, layer::_DebugSpheres, @nospecialize(obj))
    _update_spheres!(gui, layer)
    return nothing
end

function _layer_attached!(gui::LiveView, layer::_DebugSpheres, @nospecialize(obj))
    _add_spheres!(gui, layer, obj)
    _show_spheres!(gui, layer)
    return nothing
end

# Removes the spheres of the parts of `obj` and the main spheres of `obj` and of its objects
function _layer_released!(gui::LiveView, layer::_DebugSpheres, @nospecialize(obj))
    for x in Iterators.flatten((_debug_parts(obj), _debug_mains(obj)))
        oh = pop!(layer.handles, x, nothing)
        isnothing(oh) || remove_render!(oh)
    end
    return nothing
end

_layer_hidden!(gui::LiveView, layer::_DebugSpheres) = _show_spheres!(gui, layer)
