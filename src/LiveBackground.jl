#=
Card of the `background_card` of `live_view`, shown on a click on the empty background
=#

"""
    _BackgroundItem <: _InfoItem

The object `obj` of the `background_card` of [`live_view`](@ref), shown on the transient info card
at `point` [m] after a click on the empty background (see `_show_background!`): like the card of an
inspected point of a beam, `Esc` or a click elsewhere closes it and its pin keeps it (docked in the
app layout). Its title is the label of `obj` (see `_label`), its icon that of the kind of `obj`
(see `_tree_kind`), its rows are the [`card_rows`](@ref) of `obj`, whose `value` and `on` get `obj`
itself, see `_for_object`. It has no actions. Mutable, such that each click gives a card of its own
(`===`), also at the same point.
"""
mutable struct _BackgroundItem <: _InfoItem
    const obj::Any
    const point::Point3f
end

_points(x::_BackgroundItem) = [x.point]
_label(gui::LiveView, x::_BackgroundItem) = _label(gui, x.obj)
_label(gui::AppView, x::_BackgroundItem) = _label(gui, x.obj)
_tree_kind(x::_BackgroundItem) = _tree_kind(x.obj)
_keep_plots!(::LiveView, ::_BackgroundItem) = nothing
_forget!(::LiveView, ::_BackgroundItem) = nothing

card_rows(x::_BackgroundItem) = map(r -> _for_object(r, x.obj), Tuple(card_rows(x.obj)))

"""
    _for_object(row::CardRow, obj) -> CardRow

The `row` of the card of `obj` on the card of the `_BackgroundItem` of `obj`: its widgets get `obj`
instead of the item in `value(gui, obj)` and `on(gui, obj, v)`. An input with `solve = true` is
applied like on the card of `obj` itself (see `_apply_on!`), i.e. `on_change` gets `obj`.
"""
_for_object(r::CardRow, obj) = CardRow(Union{String, CardWidget}[_for_object(c, obj) for c in r.cells])
_for_object(s::String, _) = s
_for_object(w::CardWidget, obj) = CardWidget(w.type, w.attributes, _value_of(w.value, obj),
    _on_of(w.on, obj, w.solve), false, w.name)

_value_of(::Nothing, _) = nothing
_value_of(value, obj) = (gui, _) -> value(gui, obj)
_on_of(::Nothing, _, ::Bool) = nothing
_on_of(on, obj, solve::Bool) = (gui, _, v) -> _apply_on!(gui, on, obj, v, Val(solve))

"""
    _background_object(gui, spec)

The object whose card a click on the empty background of the `gui` shows, from the `background_card`
kwarg `spec` of [`live_view`](@ref): `nothing` (no card), a function `gui -> object or nothing`,
evaluated at each click, or the object itself.
"""
_background_object(::LiveView, ::Nothing) = nothing
_background_object(gui::LiveView, f::Function) = f(gui)
_background_object(::LiveView, obj) = obj

"""
    _background_anchor(scene) -> Point3f

The point of the card of the background: where the camera ray through the mouse meets the plane
through the `lookat` point of the camera of the 3D `scene`, perpendicular to the view direction,
i.e. the card appears at the click and follows the view like the other info cards.
"""
function _background_anchor(scene)
    origin, dir = _cursor_ray(scene)
    cam = cameracontrols(scene)
    lookat = Vector{Float64}(cam.lookat[])
    v = normalize(lookat .- Vector{Float64}(cam.eyeposition[]))
    den = dot(dir, v)
    abs(den) < 1e-12 && return Point3f(lookat)
    return Point3f(origin .+ (dot(lookat .- origin, v) / den) .* dir)
end

"""
    _show_background!(gui) -> Bool

Shows the card of the object of the `background_card` of the `gui` (see `_background_object`) on the
transient info card at the click, see `_background_anchor` and `_show_info!`, after a click on the
empty background, see `_on_click!`. Returns `false` without such an object.
"""
function _show_background!(gui::LiveView)
    x = _background_object(gui, gui.background_card)
    isnothing(x) && return false
    _show_info!(gui, _background_item(x, gui.ax.scene))
    return true
end

"""
The item of the card of the background for the result `x` of `_background_object`: the object at
the click (see `_background_anchor`), or for `obj => point` the object at the `point` [m] of the
3D `scene`, e.g. on a sky dome.
"""
_background_item(obj, scene) = _BackgroundItem(obj, _background_anchor(scene))
_background_item((obj, point)::Pair, _) = _BackgroundItem(obj, Point3f(point))
