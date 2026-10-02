#=
Window of the component catalog: a part that floats over the 3D view of both layouts and is moved
with the mouse, see `_CatalogWindow`
=#

# z translation of the scene of the window: over the overlay of the layout (`_OVERLAY_Z`), under
# the cards (`_CARD_Z0`), which keep off it, see `_obstacles`
const _CATALOG_Z = 9550.0f0
# Priority of the listeners that move the window: before those of the cards (2, 3)
const _CATALOG_PRIORITY = 4

"""
    _CatalogWindow

The window "Components" of a `LiveView`: an `_OverlayPart` in a `scene` of its own over the whole
figure (a pixel camera, translated to `_CATALOG_Z`), with a `head` (the title, the key cap of
`Insert` and the `close_button`) and the `widget` of the catalog below it, see `_CatalogWidget`.

While `shown`, its top left corner is at `corner` [figure px], inside the 3D view (see
`_arrange_catalog!`); `nothing` until it is shown first. A drag at its head moves it, see
`_connect_catalog_window!`. `tool` is the toggle of the layout that shows and hides it, see
[`add_tool!`](@ref).
"""
mutable struct _CatalogWindow
    const scene::Scene
    const part::_OverlayPart
    const head::GridLayout
    const close_button::_OverlayItem
    const widget::_CatalogWidget
    shown::Bool
    corner::Union{Nothing, Point2f}
    tool::Any
end

"""The window of the catalog of the `gui`, or `nothing` for a view without a catalog."""
_catalog_window(gui::LiveView) = gui.components.window

"""
    _catalog_window_parts(fig, t) -> (scene, part, head, close_button, body)

The empty window of the catalog in the figure `fig` in the colors of the theme tokens `t`: its
scene, its part, its head and the grid `body` for the widgets of the catalog.
"""
function _catalog_window_parts(fig::Figure, t::NamedTuple)
    scene = Scene(fig.scene; camera = Makie.campixel!, clear = false)
    translate!(scene, 0, 0, _CATALOG_Z)
    part = _OverlayPart(scene, t; padding = (12, 12, 10, 12), default_rowgap = 8)
    head = GridLayout(part.content[1, 1]; default_colgap = 6)
    Label(head[1, 1], _CATALOG_TITLE; _card_style(t, Label)..., fontsize = 13, font = :bold,
        halign = :left)
    Label(head[1, 2], ""; tellwidth = false)
    _help_cap!(head[1, 3], t, "Ins")
    close_button = _OverlayItem(head[1, 4], t; icon = :close, size = 22, icon_size = 14,
        padding = (0, 0, 0, 0), icon_color = t.muted)
    body = GridLayout(part.content[2, 1]; halign = :left, default_rowgap = 8)
    return scene, part, head, close_button, body
end

"""The rectangle [figure px] of the window `w` of the catalog."""
_catalog_rect(w::_CatalogWindow) = _overlay_rect(w.part)

"""
The rectangles [figure px] of the window of the catalog of the `gui` while it is shown, which the
floating cards keep off, see `_obstacles`.
"""
function _catalog_rects(gui::LiveView)
    w = _catalog_window(gui)
    return (isnothing(w) || !_catalog_visible(gui, w)) ? Rect2f[] : Rect2f[_catalog_rect(w)]
end

# Shown, and not hidden with the rest of the UI by the spectator mode
_catalog_visible(gui::LiveView, w::_CatalogWindow) = w.shown && !gui.controls.spectator[]

"""
    _over_catalog(gui) -> Bool

Returns `true` if the mouse is over the window of the catalog of the `gui`: its presses and its
scrolling reach neither the controls nor the camera, like those over the cards, see
`_shield_cards!`.
"""
function _over_catalog(gui::LiveView)
    w = _catalog_window(gui)
    (isnothing(w) || !_catalog_visible(gui, w)) && return false
    return Point2f(events(gui.ax.scene).mouseposition[]) in _catalog_rect(w)
end

"""Returns `true` if the point `p` [figure px] is on the head of the window `w`, beside its close button."""
function _over_catalog_handle(w::_CatalogWindow, p::Point2f)
    rect = _catalog_rect(w)
    head = Rect2f(w.head.layoutobservables.computedbbox[])
    close = Rect2f(w.close_button.box.layoutobservables.computedbbox[])
    # the head and the padding of the window around it
    top = Rect2f(minimum(rect)[1], minimum(head)[2], Makie.widths(rect)[1], maximum(rect)[2] - minimum(head)[2])
    return p in top && !(p in close)
end

"""
    _catalog_corner(corner, size, view) -> Point2f

The top left corner of a window of the `size` [px] nearest to `corner` such that the window lies
inside the rectangle `view` with the margin of the overlay; at the top left of a `view` that is
smaller than the window.
"""
function _catalog_corner(corner::Point2f, size::Vec2f, view::Rect2f)
    lo, hi = minimum(view) .+ _OVERLAY_MARGIN, maximum(view) .- _OVERLAY_MARGIN
    x = clamp(corner[1], lo[1], max(lo[1], hi[1] - size[1]))
    y = clamp(corner[2], min(hi[2], lo[2] + size[2]), hi[2])
    return Point2f(x, y)
end

"""
    _arrange_catalog!(gui)

Places the window of the catalog of the `gui` with its top left corner at its `corner`, moved into
the 3D view (see `_catalog_corner`); below the help pill at the top left of the view if it has no
corner yet. A window that is not shown, or hidden by the spectator mode, is moved away, see `_park!`.
Called every frame, like the update of the cards: only a change updates the layout.
"""
function _arrange_catalog!(gui::LiveView)
    w = _catalog_window(gui)
    isnothing(w) && return nothing
    _catalog_visible(gui, w) || return _park!(w.part.outer)
    view = Rect2f(Makie.viewport(gui.ax.scene)[])
    corner = something(w.corner,
        Point2f(minimum(view)[1] + _OVERLAY_MARGIN, maximum(view)[2] - _OVERLAY_MARGIN - 40))
    w.corner = _catalog_corner(corner, _card_size(w.part.outer), view)
    _place!(w.part.outer, w.corner)
    return nothing
end

"""
    _show_catalog!(gui, shown::Bool; at = nothing)

Shows or hides the window of the catalog of the `gui`, with its top left corner at the point `at`
[figure px] if given, otherwise where it was. The toggle of the layout follows, see
`_CatalogWindow`. Hidden, its boxes no longer take the keyboard. Nothing happens without a catalog.
"""
function _show_catalog!(gui::LiveView, shown::Bool; at = nothing)
    w = _catalog_window(gui)
    isnothing(w) && return nothing
    isnothing(at) || (w.corner = Point2f(at))
    w.shown = shown
    if shown
        _show_catalog_target!(gui, w.widget)
    else
        foreach(tb -> tb.focused[] && Makie.defocus!(tb), w.widget.boxes)
        foreach(m -> m.is_open[] && (m.is_open[] = false), w.widget.menus)
    end
    (isnothing(w.tool) || w.tool.active[] == shown) || (w.tool.active[] = shown)
    _arrange_catalog!(gui)
    return nothing
end

"""
    _open_catalog_at_mouse!(gui)

The key `Insert`: shows the window of the catalog of the `gui` with its top left corner at the
mouse, or where it was if the mouse is not in the 3D view; a window that is shown moves there.
"""
function _open_catalog_at_mouse!(gui::LiveView)
    scene = gui.ax.scene
    at = Makie.is_mouseinside(scene) ? Point2f(events(scene).mouseposition[]) : nothing
    _show_catalog!(gui, true; at)
    return nothing
end

"""
    _connect_catalog_window!(gui, w)

Connects the window `w` of the catalog of the `gui`: its close button hides it, a drag at its head
moves it (it stays inside the 3D view), the key `Insert` (`_CATALOG_KEY`) shows it at the mouse
unless a textbox or menu takes the keyboard, and it follows the 3D view every frame, at which its
form is built again and settled if needed, see `_flush_catalog_form!` and `_settle_catalog_form!`.
The presses on
the window are kept from the controls and the camera like those on the cards, see `_over_catalog`.
"""
function _connect_catalog_window!(gui::LiveView, w::_CatalogWindow)
    ev = events(gui.ax.scene)
    listeners = gui.controls.listeners
    push!(listeners, on(_ -> _show_catalog!(gui, false), w.close_button.clicks))
    push!(listeners, on(ev.tick) do _
        _flush_catalog_form!(gui, w.widget)
        _settle_catalog_form!(w.widget)
        _arrange_catalog!(gui)
        return nothing
    end)
    # The mouse and the corner of the window at the press on its head
    drag = Ref{Any}(nothing)
    push!(listeners, on(ev.mousebutton; priority = _CATALOG_PRIORITY) do event
        event.button == Mouse.left || return Consume(false)
        if event.action == Mouse.press
            p = Point2f(ev.mouseposition[])
            (_catalog_visible(gui, w) && _over_catalog_handle(w, p)) || return Consume(false)
            drag[] = (p, w.corner)
            return Consume(true)
        elseif event.action == Mouse.release && !isnothing(drag[])
            drag[] = nothing
            return Consume(true)
        end
        return Consume(false)
    end)
    push!(listeners, on(ev.mouseposition; priority = _CATALOG_PRIORITY) do xy
        isnothing(drag[]) && return Consume(false)
        start, corner = drag[]
        w.corner = corner + (Point2f(xy) - start)
        _arrange_catalog!(gui)
        return Consume(true)
    end)
    push!(listeners, on(ev.keyboardbutton; priority = 200) do event
        (event.action == Keyboard.press && event.key == _CATALOG_KEY) || return Consume(false)
        # Nothing is placed in the spectator mode, which hides the window
        (gui.controls.ignore_keys() || gui.controls.spectator[]) && return Consume(false)
        _open_catalog_at_mouse!(gui)
        return Consume(true)
    end)
    return nothing
end
