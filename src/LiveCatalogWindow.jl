#=
Window and dock of the component catalog: a window with the head of a card that floats over the 3D
view of every layout and is moved with the mouse, and, in a layout with a place for it, the
catalog docked there, e.g. in a sidebar, see `_CatalogWindow`
=#

# z translation of the scene of the window: over the overlay of the layout (`_OVERLAY_Z`), under
# the cards (`_CARD_Z0`), which keep off it, see `_obstacles`
const _CATALOG_Z = 9550.0f0
# Priority of the listeners that move the window: before those of the cards (2, 3)
const _CATALOG_PRIORITY = 4

"""
    _catalog_dock_slot!(gui, title) -> Union{Nothing, NamedTuple}

The place of the layout of the `gui` in which the catalog named `title` is docked, `nothing` (the
default) for a layout without one, e.g. the compact layout, whose catalog is a window only. A
layout with such a place, e.g. a section of a sidebar, returns

- `part`: a `_LayoutPart` whose `grid` takes the widgets of the catalog, collapsed while the
  catalog is minimized or floats
- `header`: a `GridLayout` at the title of the place for the buttons of the dock
- `width`: the width of the place [px], see `_catalog_style`
- `reveal`: a function that shows the place if its user collapsed it, e.g. a sidebar
- `tooltip_placement`: the side of the tooltips of the buttons

Part of the layout interface, see `AbstractLiveLayout`.
"""
_catalog_dock_slot!(::LiveView, _) = nothing

"""
    _CatalogDock

The catalog docked in a place of the layout (see `_catalog_dock_slot!`): its `widget` in the
collapsible `part`, and at the title of the place the `float_button`, which moves the catalog into
its window (see `_float_catalog!`) and, while it floats, back, and the `collapse_button`, a chevron
that minimizes the docked catalog to its title (`collapsed`). `reveal()` shows the place.
"""
mutable struct _CatalogDock
    const widget::_CatalogWidget
    const part::_LayoutPart
    const float_button::_IconButton
    const collapse_button::_IconButton
    const reveal::Function
    collapsed::Bool
end

function _CatalogDock(gui::LiveView, slot::NamedTuple)
    t = gui.layout.theme
    body = GridLayout(slot.part.grid[1, 1]; halign = :left, valign = :top, tellwidth = false,
        default_rowgap = 8)
    widget = _catalog_widget!(gui, body, _catalog_style(slot.width))
    float_button = _card_float!(slot.header[1, 1], t; slot.tooltip_placement)
    collapse_button = _card_collapse!(slot.header[1, 2], t; slot.tooltip_placement)
    return _CatalogDock(widget, slot.part, float_button, collapse_button, slot.reveal, false)
end

"""
    _resize_catalog_dock!(gui, width)

Lays out the docked catalog of the `gui` again for a place of the `width` [px], e.g. after the
sidebar that holds it was resized, see `_restyle_catalog!`: also while the catalog floats or is
minimized, for when it is docked again. Its state is kept. Nothing happens without a dock.
"""
function _resize_catalog_dock!(gui::LiveView, width::Real)
    w = _catalog_window(gui)
    (isnothing(w) || isnothing(w.dock)) && return nothing
    _restyle_catalog!(w.dock.widget, _catalog_style(width))
    return nothing
end

"""
    _CatalogWindow

The catalog "Components" of a `LiveView`: its window, and where the catalog is shown.

The window is an `_OverlayPart` in a `scene` of its own over the whole figure (a pixel camera,
translated to `_CATALOG_Z`) with the `head` of a card, built from the same parts (see
`_card_icon!`): the icon, the title and its tools, i.e. the `pin_button`, the `collapse_button`
and, in a layout with a dock, the `dock_button`, otherwise the `close_button`. Below the head, the
collapsible `body` holds the `widget` of the catalog, see `_CatalogWidget`.

- `shown`: the window is shown, with its top left corner at `corner` [figure px], inside the 3D
  view (see `_arrange_catalog!`); `nothing` until it is shown first. A drag at its head moves it,
  see `_connect_catalog_window!`.
- `pinned`: the window stays open at its place. A window that is not pinned is a popup: the key
  `Insert` moves it to the mouse, and it closes when a component was dropped, see
  `_close_unpinned_catalog!`. Unpinning closes it, like a card.
- `collapsed`: the window is minimized to its head.
- `dock`: the catalog docked in the layout (a `_CatalogDock`), `nothing` in a layout without such
  a place. While `docked`, the catalog is shown there and the window is hidden; closing the window
  docks the catalog again, see `_close_catalog!`.

`tool` is the toggle of the layout, which is active while the catalog is open (see
`_catalog_open`), see [`add_tool!`](@ref).
"""
mutable struct _CatalogWindow
    const scene::Scene
    const part::_OverlayPart
    const head::GridLayout
    const body::_LayoutPart
    const pin_button::_IconToggle
    const collapse_button::_IconButton
    const dock_button::Union{Nothing, _IconButton}
    const close_button::Union{Nothing, _IconButton}
    const widget::_CatalogWidget
    const dock::Union{Nothing, _CatalogDock}
    shown::Bool
    pinned::Bool
    collapsed::Bool
    docked::Bool
    corner::Union{Nothing, Point2f}
    tool::Any
end

"""
    _CatalogWindow(gui, slot)

The window of the catalog of the `gui` with its widgets and, with a `slot` of the layout (see
`_catalog_dock_slot!`), its dock, in which the catalog starts; without one, the window is hidden
at first.
"""
function _CatalogWindow(gui::LiveView, slot)
    t = gui.layout.theme
    docks = !isnothing(slot)
    scene = Scene(gui.fig.scene; camera = Makie.campixel!, clear = false)
    translate!(scene, 0, 0, _CATALOG_Z)
    part = _OverlayPart(scene, t; padding = (12, 12, 10, 12), default_rowgap = 8)
    # The head of a card: icon, title and tools
    head = GridLayout(part.content[1, 1]; default_colgap = 6)
    icon, icon_color = _card_icon!(head[1, 1])
    icon[] = _icon(:lens)
    icon_color[] = RGBAf(Makie.to_color(t.muted))
    _card_title!(head[1, 2], t).text[] = _CATALOG_TITLE
    Label(head[1, 3], ""; tellwidth = false)
    tools = GridLayout(head[1, 4]; default_colgap = 2)
    dock_button = docks ? _card_dock!(tools[1, 1], t) : nothing
    pin_button = _card_pin!(tools[1, 1 + docks], t)
    collapse_button = _card_collapse!(tools[1, 2 + docks], t)
    close_button = docks ? nothing :
                   _IconButton(tools[1, 3]; icon = :close, tooltip = "Close the catalog", _card_icons(t)...)
    foreach(_fix_tooltip!, filter(!isnothing, (dock_button, pin_button, collapse_button, close_button)))
    # The body, which a minimized window does not show
    box = Box(part.content[2, 1]; visible = false)
    grid = GridLayout(part.content[2, 1]; halign = :left, default_rowgap = 8)
    body = _LayoutPart(part.content, (2, 1), s -> rowsize!(part.content, 2, s), Auto(), box, grid, true)
    widget = _catalog_widget!(gui, grid, _catalog_style())
    dock = docks ? _CatalogDock(gui, slot) : nothing
    return _CatalogWindow(scene, part, head, body, pin_button, collapse_button, dock_button,
        close_button, widget, dock, false, false, false, docks, nothing, nothing)
end

"""The catalog of the `gui` (a `_CatalogWindow`), or `nothing` for a view without a catalog."""
_catalog_window(gui::LiveView) = gui.components.window

"""The widgets of the catalog `w`: those of its window and, if it has one, of its dock."""
_catalog_widgets(w::_CatalogWindow) = isnothing(w.dock) ? (w.widget,) : (w.widget, w.dock.widget)

"""The widgets of the catalog `w` that are in use: those of its dock while it is docked."""
_catalog_widget(w::_CatalogWindow) = w.docked ? w.dock.widget : w.widget

"""
Whether the catalog `w` is open, which its toggle shows: its window is shown, also minimized, or,
while it is docked, it is not minimized.
"""
_catalog_open(w::_CatalogWindow) = w.docked ? !w.dock.collapsed : w.shown

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

# The window is shown, and not hidden with the rest of the UI by the spectator mode
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

"""
Returns `true` if the point `p` [figure px] is on the head of the window `w`, beside its buttons;
a minimized window is its head.
"""
function _over_catalog_handle(w::_CatalogWindow, p::Point2f)
    rect = _catalog_rect(w)
    head = Rect2f(w.head.layoutobservables.computedbbox[])
    # the head and the padding of the window around it
    top = w.collapsed ? rect :
          Rect2f(minimum(rect)[1], minimum(head)[2], Makie.widths(rect)[1], maximum(rect)[2] - minimum(head)[2])
    buttons = filter(!isnothing, (w.dock_button, w.pin_button, w.collapse_button, w.close_button))
    return p in top && !any(b -> p in Rect2f(b.box.layoutobservables.computedbbox[]), buttons)
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
    _show_catalog_state!(gui, w)

Shows the state of the catalog `w` of the `gui` on its heads (the pin and the chevron of its
window, the buttons of its dock) and on the toggle of the layout, names the system that gets the
next component and places the window, see `_arrange_catalog!`.
"""
function _show_catalog_state!(gui::LiveView, w::_CatalogWindow)
    _update!(w.pin_button.active, w.pinned)
    _update!(w.pin_button.tooltip, w.pinned ? "Unpin and close the catalog" :
                                   "Keep the catalog open")
    _show_minimized!(w.collapse_button, w.collapsed)
    d = w.dock
    if !isnothing(d)
        # While the catalog floats, the buttons of its dock bring it back
        _show_minimized!(d.collapse_button, d.collapsed || !w.docked)
        _update!(d.float_button.icon, _icon(w.docked ? :float : :dock))
        _update!(d.float_button.tooltip, w.docked ? "Float in the 3D view" : "Dock in the sidebar")
    end
    open = _catalog_open(w)
    (isnothing(w.tool) || w.tool.active[] == open) || (w.tool.active[] = open)
    _show_catalog_target!(gui, _catalog_widget(w))
    _arrange_catalog!(gui)
    return nothing
end

# The chevron of the catalog: down, or right while it is minimized
function _show_minimized!(b::_IconButton, minimized::Bool)
    _update!(b.icon, _icon(minimized ? :expand : :collapse))
    _update!(b.tooltip, minimized ? "Expand the catalog" : "Minimize the catalog")
    return nothing
end

"""The inputs of the catalog `widget` no longer take the keyboard, e.g. before they are hidden."""
function _blur_catalog!(widget::_CatalogWidget)
    foreach(tb -> tb.focused[] && Makie.defocus!(tb), widget.boxes)
    foreach(m -> m.is_open[] && (m.is_open[] = false), widget.menus)
    menu = widget.target_menu
    (isnothing(menu) || !menu.is_open[]) || (menu.is_open[] = false)
    return nothing
end

# Gap between the title and the tools of the head of a minimized window [px]
const _CATALOG_HEAD_GAP = 24

"""
Shows only the head of the window `w` of the catalog (`collapsed`), or its body as well. The head
is as wide as the body; without it, the gap between its title and its tools has a width of its own.
"""
function _collapse_catalog_body!(w::_CatalogWindow, collapsed::Bool)
    w.collapsed == collapsed && return nothing
    collapsed && _blur_catalog!(w.widget)
    w.collapsed = collapsed
    _set_shown!(w.body, !collapsed)
    Makie.colsize!(w.head, 3, collapsed ? Fixed(_CATALOG_HEAD_GAP) : Auto())
    return nothing
end

"""Minimizes the window of the catalog `w` of the `gui` to its head, or expands it again."""
function _set_catalog_collapsed!(gui::LiveView, w::_CatalogWindow, collapsed::Bool)
    _collapse_catalog_body!(w, collapsed)
    _show_catalog_state!(gui, w)
    return nothing
end

"""
Minimizes the docked catalog `w` of the `gui` to the title of its place, or expands it again; a
catalog that floats remembers it for when it is docked.
"""
function _set_dock_collapsed!(gui::LiveView, w::_CatalogWindow, collapsed::Bool)
    d = w.dock
    collapsed && _blur_catalog!(d.widget)
    d.collapsed = collapsed
    w.docked && _set_shown!(d.part, !collapsed)
    _show_catalog_state!(gui, w)
    return nothing
end

"""
    _float_catalog!(gui; at = nothing, pinned = true)

Moves the docked catalog of the `gui` into its window, which shows what the dock showed (see
`_copy_catalog_state!`): with its top left corner at the point `at` [figure px] if given,
otherwise where it was, and `pinned`, e.g. by the float button of the dock, or as a popup, e.g. by
the key `Insert`. The dock keeps its title, whose buttons dock the catalog again.
"""
function _float_catalog!(gui::LiveView; at = nothing, pinned::Bool = true)
    w = _catalog_window(gui)
    (isnothing(w) || !w.docked) && return nothing
    d = w.dock
    _blur_catalog!(d.widget)
    _set_shown!(d.part, false)
    isnothing(at) || (w.corner = Point2f(at))
    w.docked, w.shown, w.pinned = false, true, pinned
    _collapse_catalog_body!(w, false)
    _copy_catalog_state!(gui, w.widget, d.widget)
    _show_catalog_state!(gui, w)
    return nothing
end

"""
    _dock_catalog!(gui; expand = false)

Moves the catalog of the `gui` from its window back into its dock, which shows what the window
showed (see `_copy_catalog_state!`) and is minimized if it was so before, unless `expand`, which
also shows its place (see `_catalog_dock_slot!`), e.g. for the dock button of the window. The
widgets are also built while the place is collapsed, see `_with_ui`.
"""
function _dock_catalog!(gui::LiveView; expand::Bool = false)
    w = _catalog_window(gui)
    (isnothing(w) || isnothing(w.dock) || w.docked) && return nothing
    d = w.dock
    _blur_catalog!(w.widget)
    w.shown, w.docked, w.pinned = false, true, false
    if expand
        d.collapsed = false
        d.reveal()
    end
    _with_ui(gui) do
        _set_shown!(d.part, true)
        _copy_catalog_state!(gui, d.widget, w.widget)
        _set_shown!(d.part, !d.collapsed)
    end
    _show_catalog_state!(gui, w)
    return nothing
end

"""
    _close_catalog!(gui)

Closes the window of the catalog of the `gui`: it is hidden and no longer pinned, its inputs no
longer take the keyboard. In a layout with a dock, the catalog is docked again, see
`_dock_catalog!`.
"""
function _close_catalog!(gui::LiveView)
    w = _catalog_window(gui)
    (isnothing(w) || w.docked) && return nothing
    isnothing(w.dock) || return _dock_catalog!(gui)
    _blur_catalog!(w.widget)
    w.shown, w.pinned = false, false
    _show_catalog_state!(gui, w)
    return nothing
end

"""
Closes the window of the catalog of the `gui` after a component was dropped, unless it is pinned,
see `_drop_placement!`; nothing for a docked catalog and without a catalog.
"""
function _close_unpinned_catalog!(gui::LiveView)
    w = _catalog_window(gui)
    (isnothing(w) || !w.shown || w.pinned) || _close_catalog!(gui)
    return nothing
end

"""
    _show_catalog!(gui, shown::Bool; at = nothing)

Opens or closes the catalog of the `gui`, like its toggle among the tools (see `_catalog_open`).
Nothing happens without a catalog.

- open: a docked catalog is expanded and its place is shown; with a point `at` [figure px], it
  moves into its window as a popup instead, see `_float_catalog!`. Otherwise the window is shown
  and expanded, with its top left corner at `at` if given, unless it is pinned, else where it was.
- close: the window is closed (see `_close_catalog!`), a docked catalog is minimized.
"""
function _show_catalog!(gui::LiveView, shown::Bool; at = nothing)
    w = _catalog_window(gui)
    isnothing(w) && return nothing
    # e.g. the toggle that follows the state
    (isnothing(at) && _catalog_open(w) == shown) && return nothing
    if !shown
        _close_catalog!(gui)
        w.docked && _set_dock_collapsed!(gui, w, true)
    elseif w.docked && isnothing(at)
        w.dock.reveal()
        _set_dock_collapsed!(gui, w, false)
    elseif w.docked
        _float_catalog!(gui; at, pinned = false)
    else
        (isnothing(at) || (w.shown && w.pinned)) || (w.corner = Point2f(at))
        w.shown = true
        w.collapsed ? _set_catalog_collapsed!(gui, w, false) : _show_catalog_state!(gui, w)
    end
    return nothing
end

"""
    _open_catalog_at_mouse!(gui)

The key `Insert`: shows the window of the catalog of the `gui` with its top left corner at the
mouse, or opens the catalog where it was if the mouse is not in the 3D view. A window that is shown
moves there, unless it is pinned.
"""
function _open_catalog_at_mouse!(gui::LiveView)
    scene = gui.ax.scene
    at = Makie.is_mouseinside(scene) ? Point2f(events(scene).mouseposition[]) : nothing
    _show_catalog!(gui, true; at)
    return nothing
end

"""
    _connect_catalog_window!(gui, w)

Connects the catalog `w` of the `gui`:

- the head of its window: the pin keeps it open, and closes it when it is switched off; the chevron
  minimizes it; the close button, or the dock button in a layout with a dock, closes it, see
  `_close_catalog!` and `_dock_catalog!`. A drag at the head moves the window, which stays inside
  the 3D view.
- its dock: the float button moves the catalog into its window, pinned, and back; the chevron
  minimizes the docked catalog and brings back one that floats.
- the key `Insert` (`_CATALOG_KEY`) shows the window at the mouse, unless a textbox or menu takes
  the keyboard and not in the spectator mode.
- every frame, the window follows the 3D view, and the forms are built again and settled if
  needed, see `_flush_catalog_form!` and `_settle_catalog_form!`.

The presses on the window are kept from the controls and the camera like those on the cards, see
`_over_catalog`.
"""
function _connect_catalog_window!(gui::LiveView, w::_CatalogWindow)
    ev = events(gui.ax.scene)
    listeners = gui.controls.listeners
    # The toggle switches itself, the state of the window follows
    push!(listeners, on(w.pin_button.active) do pinned
        pinned == w.pinned && return nothing
        w.pinned = pinned
        pinned ? _show_catalog_state!(gui, w) : _close_catalog!(gui)
        return nothing
    end)
    push!(listeners, on(_ -> _set_catalog_collapsed!(gui, w, !w.collapsed), w.collapse_button.clicks))
    isnothing(w.close_button) ||
        push!(listeners, on(_ -> _close_catalog!(gui), w.close_button.clicks))
    isnothing(w.dock_button) ||
        push!(listeners, on(_ -> _dock_catalog!(gui; expand = true), w.dock_button.clicks))
    d = w.dock
    if !isnothing(d)
        push!(listeners, on(d.float_button.clicks) do _
            w.docked ? _float_catalog!(gui) : _dock_catalog!(gui; expand = true)
        end)
        push!(listeners, on(d.collapse_button.clicks) do _
            w.docked ? _set_dock_collapsed!(gui, w, !d.collapsed) : _dock_catalog!(gui; expand = true)
        end)
    end
    push!(listeners, on(ev.tick) do _
        for widget in _catalog_widgets(w)
            _flush_catalog_form!(gui, widget)
            _settle_catalog_form!(widget)
        end
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
