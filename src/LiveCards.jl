#=
Cards of the live view: the pose inspector, the card of the selection and the pinned cards,
their widgets and moving them with the mouse; the card widget is in LiveCard.jl
=#

#=
Pose inspector
=#

"""Labels of the boxes of the pose inspector: position [mm] and rotations about the axes [mrad]."""
const _POSE_FIELDS = ("x [mm]", "y [mm]", "z [mm]", "rx [mrad]", "ry [mrad]", "rv [mrad]")

"""Gizmo axes (see `_axis_vectors`) of the rotation boxes of the pose inspector."""
const _POSE_AXES = (:x, :y, :v)

"""Label colors of the pose inspector: the colors of the gizmo axes for the rotations."""
const _POSE_COLORS = (:black, :black, :black, :red, :green, :blue)

"""Returns `true` if a textbox or a menu of the `gui` takes keyboard input."""
function _typing(gui::LiveView)
    any(c -> any(tb -> tb.focused[], _card_boxes(c)), gui.cards.all) && return true
    any(tb -> tb.focused[], _layout_boxes(gui)) && return true
    # the widgets of `add_controls!` and `add_panel!`, see `_register_widgets!`
    _custom_typing(gui.custom) && return true
    # the search of an open menu of a card, e.g. of the colors of a beam
    _card_menu_open(gui) && return true
    return _menu_open(gui)
end

"""Whether a menu of the card `c` is open, see `_open_menu`."""
_has_open_menu(c::_AbstractCard) = any(b -> !isnothing(_open_menu(b)), c.blocks)

"""
Whether a menu of a card of the `gui` is open: its options may reach beyond the card, hence presses
are left to it and the keys to its search, see `_connect_cards!` and `_typing`.
"""
_card_menu_open(gui::LiveView) = any(_has_open_menu, gui.cards.all)

"""
Returns the textboxes of the `gui` outside of the cards, e.g. of the inspector of the app layout,
which take the keyboard like those of the cards, see `_typing`. None by default.
"""
_layout_boxes(::LiveView) = ()

"""Shows `s` in the textbox `tb` without triggering its listeners, `""` shows the placeholder."""
function _set_box!(tb::Textbox, s::String)
    tb.stored_string.val = isempty(s) ? nothing : s
    tb.displayed_string[] == s || (tb.displayed_string[] = s)
    return nothing
end

"""
    _update_inspector!(gui; force = false)

Shows the values of the objects of all cards of the `gui` in their widgets, e.g. the position of
an object in its pose boxes, see `_refresh_card!`, and, in layouts with an inspector, refreshes it,
see `_refresh_inspector!`. Focused textboxes keep the typed text, unless `force`.
"""
function _update_inspector!(gui::LiveView; force::Bool = false)
    foreach(c -> _refresh_card!(gui, c; force), gui.cards.all)
    _refresh_inspector!(gui; force)
    return nothing
end

"""
Refreshes the parts of the layout of the `gui` that show the selected object besides the cards,
e.g. the inspector of the app layout; nothing by default.
"""
_refresh_inspector!(::LiveView; force::Bool = false) = nothing

"""Returns `true` if the constraints of `obj` allow a move by `Δ`, see `kinematic_controls!`."""
function _move_allowed(ctrl::KinematicController, obj, Δ)
    haskey(_constraints_of(ctrl, obj), :move) || return true
    allowed = _allowed_axes(ctrl, obj, :move)
    isempty(allowed) && return iszero(Δ)
    A = hcat(_axis_vectors(ctrl, obj, allowed)...)
    return norm(Δ - A * (pinv(A) * Δ)) <= 1e-12 + 1e-9 * norm(Δ)
end

"""
    _apply_pose_input!(gui, obj, k, s)

Applies the input `s` of the pose box `k` of a card (see `_POSE_FIELDS`) to its object `obj`: for
`k ≤ 3`, moves it to the absolute position x, y or z [mm], otherwise rotates it about the red,
green or blue axis of the controls [mrad], like a key step in the rotate mode. The change is
recorded in the undo history and solved like a key step. An invalid input only shows a message in
the status line, and so does an input for an object that is not movable, e.g. an inspected one (see
`_inspect!`).
"""
_apply_pose_input!(gui::LiveView, ::Nothing, ::Int, _) = _update_inspector!(gui; force = true)
function _apply_pose_input!(gui::LiveView, obj, k::Int, s)
    ctrl = gui.controls
    if !_is_movable(ctrl, obj)
        gui.status.text[] = "$(_label(gui, obj)) is not movable, its pose can not be changed"
        _update_inspector!(gui; force = true)
        return nothing
    end
    x = isnothing(s) ? nothing : tryparse(Float64, strip(s))
    if isnothing(x) || !isfinite(x)
        gui.status.text[] = "invalid input \"$(something(s, ""))\" for $(_POSE_FIELDS[k]), enter a number"
        return nothing
    end
    P0, R0 = _pose(obj)
    if k <= 3
        P = Vector{Float64}(P0)
        P[k] = x / 1e3
        if !_move_allowed(ctrl, obj, P - P0)
            gui.status.text[] = "$(_label(gui, obj)) can not move along $(_POSE_FIELDS[k][1]), see the constraints"
            _update_inspector!(gui; force = true)
            return nothing
        end
        _change!(ctrl, obj) do
            translate_to3d!(obj, P)
            # `translate_to3d!` moves by `P - position`, which may round
            r = P - Vector{Float64}(position(obj))
            iszero(r) || translate3d!(obj, r)
        end
    else
        sym = _POSE_AXES[k - 3]
        if !(sym in _allowed_axes(ctrl, obj, :rotate))
            gui.status.text[] = "$(_label(gui, obj)) can not rotate about this axis, see the constraints"
            _update_inspector!(gui; force = true)
            return nothing
        end
        iszero(x) || _change!(() -> rotate3d!(obj, only(_axis_vectors(ctrl, obj, (sym,))), x / 1e3),
            ctrl, obj)
    end
    P1, R1 = _pose(obj)
    ctrl.last_key_step = nothing
    _push_history!(ctrl, obj, P0, R0, P1, R1)
    _request_update!(ctrl)
    _update_inspector!(gui; force = true)
    return nothing
end

"""
Camera3D takes the keyboard (WASD etc.) only after a click on the background of the 3D view, which
a click on a widget, e.g. the orthographic toggle, undoes. Here the keyboard stays with the camera
of the `gui` unless a textbox or a menu takes the input, see `_typing`.
"""
function _keep_keyboard!(gui::LiveView)
    cam = cameracontrols(gui.ax.scene)
    selected = !_typing(gui)
    cam.selected[] == selected || (cam.selected[] = selected)
    return nothing
end
#=
Component card
=#

"""
Returns the object of the card `c` of the `gui`: the pinned object, the selected (or inspected, see
`_shown_object`) object for the card of the selection (`gui.cards.selection`), `nothing` for a
spare card.
"""
function _card_object(gui::LiveView, c::_ComponentCard)
    c.pinned && return c.obj
    return c === gui.cards.selection ? _shown_object(gui) : nothing
end

"""
    _update_cards!(gui)

Shows the card of the selection (`gui.cards.selection`) next to the selected (or inspected, see
`_inspect!`) object, unless it has a pinned card, and the pinned cards of the `gui` next to their objects; see `_update_card!`. The cards are
placed in this order, each off the obstacles of the `gui` (the view cube and the parts of the
layout over the 3D view, see `_obstacles`) and the cards before, so that none covers another:
the cards that the mouse moved to their `spot` first, where they stay (see `_drag_cards!`), then
the selection card of groups (see `_update_browse_card!`), then the card of the selection, at its
object; a pinned card without room is collapsed to its head. All cards are hidden while a menu is
open, whose options they would cover, and in the spectator mode (see `_on_spectator!`), after which
the pinned cards are shown again where they were. Called every frame, which moves the cards with the camera
and the objects.
"""
function _update_cards!(gui::LiveView)
    _settle_cards!(gui)
    menu = _menu_open(gui)
    sel = _shown_object(gui)
    obstacles = _obstacles(gui)
    shown = menu || !_selection_card_shown(gui) || any(c -> c.pinned && c.obj === sel, gui.cards.all) ?
        nothing : sel
    spectator = gui.controls.spectator[]
    target(c) = spectator ? nothing : c === gui.cards.selection ? shown : c.pinned && !menu ? c.obj : nothing
    order = [gui.cards.selection; filter(c -> c !== gui.cards.selection, gui.cards.all)]
    for c in order
        isnothing(c.spot) || _update_card!(gui, c, target(c), obstacles)
    end
    _update_browse_card!(gui, menu, obstacles)
    for c in order
        isnothing(c.spot) && _update_card!(gui, c, target(c), obstacles)
    end
    return nothing
end

"""
    _obstacles(gui) -> Vector{Rect2f}

The screen rectangles [figure px] that the floating cards of the `gui` keep off, see `_avoid`: the
view cube, if any, the parts of the layout over the 3D view that are shown, see
`_layout_obstacles`, and the window of the catalog while it is shown, see `_CatalogWindow`.
"""
_obstacles(gui::LiveView) = [_obstacles(gui.widgets.view_cube); _layout_obstacles(gui); _catalog_rects(gui)]

"""
    _layout_obstacles(gui) -> Vector{Rect2f}

The rectangles [figure px] of the parts of the layout of the `gui` that lie over the 3D view and
are shown, e.g. the overlay of the compact layout (see `_CompactOverlay`), which the floating
cards keep off like the view cube; none by default.
"""
_layout_obstacles(::LiveView) = Rect2f[]

"""
    _over_layout(gui) -> Bool

Returns `true` if the mouse is over a part of the layout of the `gui` that lies over the 3D view,
whose presses and scrolling the camera must not get, like those over the cards (see
`_shield_cards!`), e.g. the overlay of the compact layout; `false` by default.
"""
_over_layout(::LiveView) = false

"""
Returns `true` if the layout of the `gui` shows the card of the selection (`gui.cards.selection`) next to the
selected object; layouts that show the card elsewhere, e.g. docked in the inspector of the app
layout, return `false`. Pinned cards are shown in all layouts.
"""
_selection_card_shown(::LiveView) = true

"""
    _update_card!(gui, c, obj, obstacles)

Shows the card `c` for `obj` (or hides it for `nothing`): builds its declared widgets when it gets
another object (see `_build_content!`) and shows the values of `obj` when it or its pose changes,
then moves the card next to the bounding box of `obj` (see `_card_position`), off the `obstacles`
(see `_avoid`), to which it adds its rectangle, and connects it to `obj` by a line. A pinned card
that finds no room is collapsed to its head (`auto_collapsed`) until there is room again. A card
that the mouse moved stays at its `spot` instead (see `_spot_position`). Only changed values update
the layout.
"""
_update_card!(::LiveView, c::_ComponentCard, ::Nothing, ::Vector{Rect2f}) = _hide_card!(c)
function _update_card!(gui::LiveView, c::_ComponentCard, obj, obstacles::Vector{Rect2f})
    pose = _card_pose(obj)
    if c.pose === nothing || c.pose[1] !== obj
        # The rows of the card are those of its page, see `_declarations`
        _choose_page!(gui, c, obj)
        _build_content!(gui, c, obj)
        _build_pages!(gui, c, obj)
    end
    # Another object or a new pose, e.g. after a move by a program
    if c.pose === nothing || c.pose[1] !== obj || c.pose[2] != pose
        c.pose = (obj, pose)
        _refresh_card!(gui, c)
    end
    corners = _card_corners(gui, c, obj)
    _update!(c.title.text, _label(gui, obj))
    # "‹" on the card of a part, see `_browse_parent!`
    c.back_shown = !isnothing(_part_parent(gui, obj))
    _show_kind!(c, obj)
    scene = gui.ax.scene
    view = Rect2f(Makie.viewport(scene)[])
    sel = _screen_rect(scene, corners, obj)
    c.auto_collapsed = false
    c.step_shown = _shows_step(gui, c, obj)
    _fit_properties!(c)
    _fit_view!(c, view)
    size = _card_size(c)
    p = isnothing(c.spot) ? _avoid(_card_position(sel, size, view), size, view, obstacles) :
        _spot_position(c.spot, size, view)
    if isnothing(c.spot) && c.pinned && !c.collapsed && _covers(p, size, obstacles)
        c.auto_collapsed = true
        size = _card_size(c)
        p = _avoid(_card_position(sel, size, view), size, view, obstacles)
    end
    _arrange_card!(c, p)
    rect = _card_rect(p, size)
    push!(obstacles, rect)
    _update!(c.link, [_link_anchor(scene, corners, obj), Point2f(minimum(rect) .+ size ./ 2)])
    _update!(c.scene.visible, true)
    _show_view!(gui, c, obj)
    return nothing
end

#=
Pages of a floating card, see `_card_pages`, and the view of its page "Results"
=#

"""
    _build_pages!(gui, c, obj)

Shows the pages of the new object `obj` of the floating card `c`: its page bar (see `_show_bar!`),
its default page (see `_default_page`), unless the card is pinned and has the page that it showed
before, e.g. a card that was docked on this page, and the view of an object with a view, see
`_build_view!`.
"""
function _build_pages!(gui::LiveView, c::_ComponentCard, obj)
    pages = _card_pages(gui, obj)
    _choose_page!(gui, c, obj)
    _show_bar!(gui, c, pages)
    _build_view!(gui, c, obj)
    return nothing
end

"""
The page of the floating card `c` for its new object `obj`: its default page (see `_default_page`),
unless the card is pinned and has the page that it showed before.
"""
function _choose_page!(gui::LiveView, c::_ComponentCard, obj)
    (c.pinned && c.page in _card_pages(gui, obj)) || (c.page = _default_page(obj))
    return nothing
end

"""
Shows the page bar of the `pages` on the card `c` of the `gui`, built when the card first gets an
object with these pages; none for a single page.
"""
function _show_bar!(gui::LiveView, c::_ComponentCard, pages::Tuple)
    c.pages = pages
    if length(pages) > 1
        c.bar_part, c.bar = get!(() -> _new_bar!(gui, c, pages), c.bars, pages)
        _update!(c.bar.selected, c.page)
    else
        c.bar_part, c.bar = nothing, nothing
    end
    return nothing
end

function _new_bar!(gui::LiveView, c::_ComponentCard, pages::Tuple)
    part = _card_part(c.scene)
    bar = _page_bar!(part[1, 1], c.theme, pages; selected = c.page)
    # as wide as its buttons: the free layout of the card has no width to fill
    bar.grid.tellwidth[] = true
    push!(gui.controls.listeners, on(page -> _set_page!(gui, c, page), bar.selected))
    # The new buttons come before the mouse shield of the cards
    _shield_cards!(gui)
    return (part, bar)
end

"""
    _set_page!(gui, c, page)

Shows the `page` of the floating card `c` of the `gui`, one of its `pages`, e.g. after a click on
its page bar: ends the input into the textboxes of the page before, fills the property list of the
page "Properties" and lays out the cards again, which computes a view that is shown now, see
`_show_view!`.
"""
function _set_page!(gui::LiveView, c::_ComponentCard, page::Symbol)
    (c.page === page || !(page in c.pages)) && return nothing
    c.page = page
    isnothing(c.bar) || _update!(c.bar.selected, page)
    _defocus_card!(c)
    # The rows of the new page, see `_declarations`
    obj = _card_object(gui, c)
    if !isnothing(obj) && !isnothing(c.pose) && c.pose[1] === obj
        _build_content!(gui, c, obj)
        _refresh_card!(gui, c; force = true)
    end
    _refresh_selection_part!(gui, c, _card_object(gui, c))
    _update_cards!(gui)
    return nothing
end

"""
    _build_view!(gui, c, obj)

Replaces the view of the floating card `c` by one of its new object `obj`, if `obj` has a view (see
`_has_view`), in the state `view_expanded` and of the size `view_size` of the card. The widgets of
the view set the options of the view of `obj` (see `_set_view!`), its chevrons and its thumbnail
expand and collapse it, see `_expand_view!`.
"""
function _build_view!(gui::LiveView, c::_ComponentCard, obj)
    _drop_view!(gui, c)
    _has_view(obj) || return nothing
    c.view_part = _card_part(c.scene)
    view = _DetectorView(c.view_part, c.theme; expanded = c.view_expanded, width = c.view_size[1],
        height = c.view_size[2])
    append!(gui.controls.listeners, _connect_view!(view, events(gui.ax.scene);
        on_options = (; changes...) -> _set_view!(gui, obj; changes...),
        on_expanded = expanded -> _expand_view!(gui, c, obj, expanded)))
    c.view = view
    # The new widgets come before the mouse shield of the cards
    _shield_cards!(gui)
    return nothing
end

"""Removes the view of the floating card `c` of the `gui`, if any, with its listeners."""
function _drop_view!(gui::LiveView, c::_ComponentCard)
    view = c.view
    c.view, c.view_shown, c.view_switches = nothing, false, 0
    isnothing(view) && return nothing
    filter!(l -> !any(x -> x === l, view.listeners), gui.controls.listeners)
    _delete_view!(view)
    return nothing
end

"""
Expands the view of `obj` on the card `c` of the `gui`, or collapses it to its thumbnail; the card
remembers the state. An expanded view is computed on the full grid, if it was not, see
`_view_needed!`.
"""
function _expand_view!(gui::LiveView, c::_ComponentCard, obj, expanded::Bool)
    c.view_expanded = expanded
    _set_expanded!(c.view, expanded)
    _update_cards!(gui)
    _view_needed!(gui, obj)
    return nothing
end

"""
    _show_view!(gui, c, obj)

Called when the card `c` of `obj` was laid out: if it shows its view now and did not before (a new
object, the page "Results", an expanded or a pinned card), the view shows the stored result of
`obj` and is computed if that is stale, see `_view_needed!`. The switches of the view, which are
built with its results, come before the mouse shield of the cards.
"""
function _show_view!(gui::LiveView, c::_ComponentCard, obj)
    shown = !isnothing(_card_view(c))
    if shown && !c.view_shown
        c.view_shown = true
        _redraw_views!(gui, obj)
        _view_needed!(gui, obj)
    end
    c.view_shown = shown
    n = isnothing(c.view) ? 0 : length(c.view.switches)
    if n != c.view_switches
        c.view_switches = n
        _shield_cards!(gui)
    end
    return nothing
end

"""
    _fit_view!(c, view::Rect2f)
    _set_view_size!(c, size, view::Rect2f)

Sets the size of the axis of the expanded view of the card `c` to its `view_size`, or to the new
`size` [px], which the card remembers: within the bounds of the 3D view `view`, see `_view_bounds`.
"""
function _fit_view!(c::_ComponentCard, view::Rect2f)
    _has_grip(c) || return nothing
    lo, hi = _view_bounds(c, view)
    _resize_view!(c.view, clamp.(c.view_size, lo, hi)...)
    return nothing
end
function _set_view_size!(c::_ComponentCard, size::Vec2f, view::Rect2f)
    lo, hi = _view_bounds(c, view)
    c.view_size = clamp.(size, lo, hi)
    _resize_view!(c.view, c.view_size...)
    return nothing
end

"""
    _build_content!(gui, c, obj)

Builds the widgets of the card `c` of the `gui` for its new object `obj` from the declarations
[`card_actions`](@ref) (in `c.actions`) and [`card_rows`](@ref) (one layout per row in `c.rows`),
see `_add_cell!`. If the declarations have the same layout as those of the widgets on the card,
e.g. for another mirror, the widgets are kept and only take the new declarations. The card is any
host of the declarations, see `_AbstractCard`, e.g. the floating card, whose new widgets come
before the mouse shield of the cards (see `_on_content_built!`), or the docked card of the app.
"""
function _build_content!(gui::LiveView, c::_AbstractCard, obj)
    actions, rows = _declarations(gui, c, obj)
    key = (_layout_key(actions), _layout_key(rows))
    declared = CardWidget[_declared_widgets(actions)..., _declared_widgets(rows)...]
    if key == c.content_key
        c.widgets = [(b, w) for ((b, _), w) in zip(c.widgets, declared)]
        return nothing
    end
    _clear_content!(c)
    for (j, w) in enumerate(actions)
        _add_cell!(gui, c, c.actions[1, j], w)
    end
    grids = GridLayout[]
    for (i, row) in enumerate(rows)
        layout = GridLayout(c.rows[i, 1]; _row_attributes(c)...)
        for (j, cell) in enumerate(row.cells)
            _add_cell!(gui, c, layout[1, j], cell)
        end
        length(row.cells) > 1 && push!(grids, layout)
    end
    c.content_key = key
    isempty(grids) || push!(gui.cards.settle, (time(), grids))
    _on_content_built!(gui, c)
    return nothing
end

"""
    _settle_cards!(gui)

Moves the widgets of the rows of cards that were just built (`gui.cards.settle`, with the clock
time of the build) by a pixel, at the first frame with a later clock time. A workaround for
Makie 0.24, see `_settle_catalog_form!`: a `Textbox` that is created and laid out at the same clock
time draws its text with the camera of its default size, i.e. misplaced, until its viewport changes
again, e.g. the boxes of a page of a card that is built when the page is chosen. Called every
frame, see `_update_cards!`.
"""
function _settle_cards!(gui::LiveView)
    settle = gui.cards.settle
    isempty(settle) && return nothing
    now = time()
    for (t0, grids) in settle
        t0 == now && continue
        for g in grids
            # a row that was deleted meanwhile has no columns left
            size(g)[2] > 1 && Makie.colgap!(g, 1, g.addedcolgaps[1].x + 1)
        end
    end
    filter!(((t0, _),) -> t0 == now, settle)
    return nothing
end

"""
    _declarations(gui, c, obj) -> (actions, rows)

The declarations of the widgets of `obj` on the card `c`: [`card_actions`](@ref) with the button
"parts" of an object with parts (see `_head_actions`) and [`card_rows`](@ref) with the row of buttons
of a component or a source (see `_card_rows`), which a host may extend, e.g. the docked card of
the app layout.
"""
_declarations(gui::LiveView, c::_AbstractCard, obj) =
    (_head_actions(obj), _page_rows(gui, obj, c.page))

"""
    _card_rows(obj)

The rows of the card of `obj`: those of [`card_rows`](@ref) and, below them, a row of buttons for
a component, i.e. an `AbstractObject` ("onto beam", "face beam" and "remove", see
`_component_row`), and for a source, i.e. a beam or a beam group ("aim" and "remove", see
`_source_row`). They are a row and not actions in the head, whose width the name of the object
needs in the inspector of the app layout.
"""
_card_rows(obj) = card_rows(obj)
_card_rows(obj::BMO.AbstractObject) = (card_rows(obj)..., _component_row())
_card_rows(obj::Union{BMO.AbstractBeam, BMO.AbstractBeamGroup}) = (card_rows(obj)..., _source_row())

"""
    _head_actions(obj)

The buttons in the head of the card of `obj`: those of [`card_actions`](@ref) and, for a group or
another object with parts (see `_part_children`), the button "parts", which opens its selection
card, see `_browse!`. A click selects such an object as a whole (see `_open_menu!`), the button is
the visible way to its parts.
"""
_head_actions(obj) = isempty(_part_children(obj)) ? card_actions(obj) :
    (card_actions(obj)..., CardWidget(Button; name = :parts, label = "parts ›",
        on = (gui, o, _) -> _browse!(gui, o)))

# The new widgets of a floating card come before the mouse shield of the cards
_on_content_built!(gui::LiveView, ::_ComponentCard) = _shield_cards!(gui)
_on_content_built!(::LiveView, ::_AbstractCard) = nothing

"""
    _add_cell!(gui, c, pos, cell)

Adds a cell of a declaration to the card `c` of the `gui` at the grid position `pos`: a text as a
`Label`, a [`CardWidget`](@ref) as a block of its type with the attributes of the card, see
`_cell_attributes`. The inputs of the block call `on` of the declaration (see `_on_input!`), and a
textbox takes the keyboard like the others of the card.
"""
function _add_cell!(::LiveView, c::_AbstractCard, pos, text::String)
    push!(c.blocks, Label(pos, text; halign = :left, _card_style(c, Label)...))
    return nothing
end
function _add_cell!(gui::LiveView, c::_AbstractCard, pos, w::CardWidget)
    b = w.type(pos; _cell_attributes(c, w)...)
    push!(c.blocks, b)
    push!(c.widgets, (b, w))
    i = length(c.widgets)
    _fix_caret!(c, b)
    _track_textbox!(gui, c, b)
    _listen_input!(gui, c, i, card_input(b))
    return nothing
end

function _track_textbox!(gui::LiveView, c::_AbstractCard, tb::Textbox)
    push!(c.textboxes, tb)
    push!(c.listeners, on(_ -> _keep_keyboard!(gui), tb.focused))
    return nothing
end
_track_textbox!(::LiveView, ::_AbstractCard, _) = nothing

_listen_input!(::LiveView, ::_AbstractCard, ::Int, ::Nothing) = nothing
function _listen_input!(gui::LiveView, c::_AbstractCard, i::Int, obs::Observable)
    push!(c.listeners, on(v -> _on_input!(gui, c, i, v), obs))
    return nothing
end

"""
    _on_input!(gui, c, i, v)

Applies the input `v` of the declared widget `i` of the card `c` to the object of the card (see
`_card_object`) with `on` of its declaration (and solves again for `solve = true`), then shows the
new values on all cards. Ignored while the card shows new values (`refreshing`).
"""
function _on_input!(gui::LiveView, c::_AbstractCard, i::Int, v)
    c.refreshing && return nothing
    w = c.widgets[i][2]
    _apply_input!(gui, w.on, _card_object(gui, c), v, w.solve)
    _update_inspector!(gui)
    _update_cards!(gui)
    return nothing
end
_apply_input!(gui::LiveView, on, obj, v, solve::Bool) = _apply_on!(gui, on, obj, v, Val(solve))
_apply_input!(::LiveView, ::Nothing, _, _, ::Bool) = nothing
_apply_input!(::LiveView, _, ::Nothing, _, ::Bool) = nothing
_apply_input!(::LiveView, ::Nothing, ::Nothing, _, ::Bool) = nothing
_apply_on!(gui::LiveView, on, obj, v, ::Val{false}) = (on(gui, obj, v); nothing)
# The input changes the optics, see `solve` of `CardWidget`: like a move, via the `on_change` of
# the controls, which callers of the live view may extend
function _apply_on!(gui::LiveView, on, obj, v, ::Val{true})
    _change!(() -> on(gui, obj, v), gui.controls, obj)
    gui.controls.on_change(obj)
    return nothing
end

"""
    _refresh_card!(gui, c; force = false)

Shows the values of the object of the card `c` (see `_card_object`) in its declared widgets, see
`value` of [`CardWidget`](@ref), and in the part of the selection of a floating card, see
`_refresh_selection_part!`; a focused textbox keeps the typed text, unless `force`. Only if the
widgets were built for this object (`c.pose`), see `_update_card!`.
"""
function _refresh_card!(gui::LiveView, c::_AbstractCard; force::Bool = false)
    obj = _card_object(gui, c)
    (isnothing(obj) || c.pose === nothing || c.pose[1] !== obj) && return nothing
    c.refreshing = true
    try
        for (b, w) in c.widgets
            _refresh_widget!(b, w.value, gui, obj; force)
        end
    finally
        c.refreshing = false
    end
    _refresh_selection_part!(gui, c, obj)
    return nothing
end
_refresh_widget!(b, value, gui::LiveView, obj; force::Bool = false) = _show_value!(b, value(gui, obj), force)
_refresh_widget!(_, ::Nothing, ::LiveView, _; force::Bool = false) = nothing

"""
    _card_corners(gui, c, obj)

Returns the corners of the bounding box of the object `obj` of the card `c` of the `gui`: of the
selection box for the card of the selected object, which the controls keep up to date. A pinned
card and the card of an inspected object (see `_inspect!`) take the bounding box of the plots of
`obj` once (see `_card_bbox`) and move it with the pose of `obj` (see `key` and `_card_pose`),
since the plots follow a move only after they are rendered again.
"""
function _card_corners(gui::LiveView, c::_ComponentCard, obj)
    ctrl = gui.controls
    (c.pinned || obj !== ctrl.selected[]) || return ctrl.box_obs[]
    if c.key === nothing || c.key[1] !== obj
        c.corners = _box_corners(_card_bbox(ctrl, obj))
        c.key = (obj, _card_pose(obj))
    end
    return _moved_corners(c.corners, c.key[2], _card_pose(obj))
end

"""
    _card_pose(obj)

The pose of the object `obj` of a card (see `_pose`), by which the card notices a move; `nothing`
for a system, whose card is refreshed after the moves of its objects like any card, see
`_update_inspector!`.
"""
_card_pose(obj) = _pose(obj)
_card_pose(::BMO.AbstractSystem) = nothing

"""
Returns the `corners` of a bounding box taken in the pose `(P0, R0)`, moved to the pose `(P, R)`;
unchanged for an object without a pose, see `_card_pose`.
"""
function _moved_corners(corners, (P0, R0), (P, R))
    T = Matrix{Float64}(R) * Matrix{Float64}(R0)'
    return [Point3f(Vector{Float64}(P) + T * (Vector{Float64}(q) - Vector{Float64}(P0))) for q in corners]
end
_moved_corners(corners, ::Nothing, ::Nothing) = corners

"""
    _card_bbox(ctrl, obj)

The bounding box of the plots of `obj` in the controls `ctrl`, see `_selection_bbox`; for a system,
the union of the boxes of its rendered objects (see `_leaves`), or a box around its first object if
all of them are clipped.
"""
_card_bbox(ctrl::KinematicController, obj) = _selection_bbox(ctrl, obj, _object_plots(ctrl.h, obj))
function _card_bbox(ctrl::KinematicController, sys::BMO.AbstractSystem)
    leaves = _leaves(sys)
    isempty(leaves) && return GeometryBasics.Rect3d(fill(-5e-3, 3), fill(1e-2, 3))
    return _selection_bbox(ctrl, first(leaves), _object_plots(ctrl.h, sys))
end

"""Collapses the card `c` of the `gui` to its head, or expands it again."""
function _toggle_collapsed!(gui::LiveView, c::_ComponentCard)
    c.collapsed = !c.collapsed
    _show_head!(c)
    _update_cards!(gui)
    return nothing
end

"""
    _toggle_pinned!(gui, c)

Pins the card `c` of the selection to the selected object, which keeps the card next to the object
(or at the spot to which the mouse moved it, see `_drag_cards!`) independent of the selection; the
selection gets another card. Unpins a pinned card, which hides it and forgets its spot.
"""
function _toggle_pinned!(gui::LiveView, c::_ComponentCard)
    # The card of an inspected point or a measurement stays, see `_keep_info!`
    c.transient && return _keep_info!(gui, c)
    if c.pinned
        obj = c.obj
        c.pinned, c.obj, c.spot = false, nothing, nothing
        _hide_card!(c)
        _reset_pages!(gui, c)
        # the plots of an inspected point or a measurement, unless it is still pinned elsewhere,
        # e.g. after it was docked, see `_forget!`
        _is_pinned(gui, obj) || _forget!(gui, obj)
    elseif c === gui.cards.selection && !isnothing(_shown_object(gui))
        c.pinned, c.obj, c.key = true, _shown_object(gui), nothing
        _use_card!(gui, _spare_card!(gui))
    end
    # Also resets the pin toggle of a card that cannot be pinned
    _show_head!(c)
    _update_cards!(gui)
    _on_pinned!(gui)
    return nothing
end

"""
Makes the unpinned card `c` of the `gui` a spare card again (see `_spare_card!`): without a view,
and with the state of a new card, i.e. the page of the pose and an expanded view of the default size.
"""
function _reset_pages!(gui::LiveView, c::_ComponentCard)
    _drop_view!(gui, c)
    c.pose = nothing
    c.page, c.view_expanded, c.view_size = :pose, true, _CARD_VIEW_SIZE
    return nothing
end

"""Unpins the cards of the `gui` that are pinned to `obj`, e.g. a removed clip plane."""
_unpin!(gui::LiveView, obj) = foreach(c -> _toggle_pinned!(gui, c), _floating_cards(gui, obj))

"""Returns `true` if a card of the `gui` is pinned to `obj`: the pinned cards float by default."""
_is_pinned(gui::LiveView, obj) = _is_floating(gui, obj)

"""Returns the pinned cards of the `gui` that float next to `obj` in the 3D view."""
_floating_cards(gui::LiveView, obj) = filter(c -> c.pinned && c.obj === obj, gui.cards.all)

"""Returns `true` if a pinned card of the `gui` floats next to `obj` in the 3D view."""
_is_floating(gui::LiveView, obj) = any(c -> c.pinned && c.obj === obj, gui.cards.all)

"""
    _float!(gui, obj)
    _dock!(gui, obj)

Moves the card pinned to `obj` from the sidebar into the 3D view, next to `obj`, or back. Only a
layout that docks the pinned cards, e.g. the app layout, implements them; by default, e.g. in the
compact layout, which has no sidebar, the pinned cards always float and these do nothing.
"""
_float!(::LiveView, _) = nothing
_dock!(::LiveView, _) = nothing

"""
    _toggle_pin!(gui, obj)

Pins a card to `obj`, independent of the card of the selection, or unpins the cards pinned to
`obj`. Where a pinned card is shown depends on the layout (see `_pin!`, `_unpin!` and
`_is_pinned`): floating next to its object by default, docked below the inspector in the app layout.
"""
function _toggle_pin!(gui::LiveView, obj)
    _is_pinned(gui, obj) ? _unpin!(gui, obj) : _pin!(gui, obj)
    _on_pinned!(gui)
    return nothing
end
_toggle_pin!(::LiveView, ::Nothing) = nothing

"""
    _pin!(gui, obj)
    _pin!(gui, c::_ComponentCard, obj)

Pins a floating card to `obj`: the card `c`, by default a spare card (see `_spare_card!`) on the
default page of `obj` (see `_default_page`), see `_toggle_pin!`. The card is placed next to `obj`,
also if the mouse moved it before. The card `c` keeps its `page`, if `obj` has it, the state
`view_expanded` and the size `view_size` of its view, which a caller may set before, e.g. to those
of a docked card.
"""
function _pin!(gui::LiveView, obj)
    c = _spare_card!(gui)
    c.page = _default_page(obj)
    return _pin!(gui, c, obj)
end
function _pin!(gui::LiveView, c::_ComponentCard, obj)
    c.pinned, c.obj, c.key, c.pose, c.spot = true, obj, nothing, nothing, nothing
    _show_head!(c)
    _update_cards!(gui)
    return nothing
end

# Called after a card was pinned or unpinned, see `AbstractLiveLayout`
_on_pinned!(::LiveView) = nothing

"""Returns a card of the `gui` that is neither pinned nor the card of the selection, or a new one."""
function _spare_card!(gui::LiveView)
    i = findfirst(c -> !c.pinned && c !== gui.cards.selection, gui.cards.all)
    isnothing(i) || return gui.cards.all[i]
    c = _ComponentCard(gui.fig, gui.layout, _card_z(length(gui.cards.all) + 1))
    push!(gui.cards.all, c)
    _connect_card!(gui, c)
    # The listeners of the new widgets come after the mouse shield of the cards, which must come last
    _shield_cards!(gui)
    return c
end

"""
    _ComponentCard(fig, layout::AbstractLiveLayout, z = _CARD_Z)

A floating card in the theme of the `layout`, with the tools of the `layout`, see `_card_tools!`.
"""
_ComponentCard(fig::Figure, layout::AbstractLiveLayout, z::Real = _CARD_Z) =
    _card_tools!(layout, _ComponentCard(fig, layout.theme, z))

"""
    _card_tools!(layout, c::_ComponentCard) -> c

Adds the tools of the `layout` to the head of the floating card `c`: none by default, the
`dock_button` in a layout that docks pinned cards (see `_dock!`).
"""
_card_tools!(::AbstractLiveLayout, c::_ComponentCard) = c

"""Makes `c` the card of the selection of the `gui`, whose `step_box` sets the keyboard step."""
function _use_card!(gui::LiveView, c::_ComponentCard)
    gui.cards.selection = c
    gui.widgets.step_box = c.step_box
    c.key, c.pose, c.spot = nothing, nothing, nothing
    return nothing
end

"""
    _connect_card!(gui, c)

Connects the head and the part of the selection (step and mode, see `_connect_selection_part!`) of
the card `c` of the `gui`; the declared widgets are connected when they are built, see
`_build_content!`, the page bar and the view when the card gets its object, see `_build_pages!`.
"""
function _connect_card!(gui::LiveView, c::_ComponentCard)
    listeners = gui.controls.listeners
    push!(listeners, on(_ -> _toggle_collapsed!(gui, c), c.collapse_button.clicks))
    # The toggle switches itself, `_toggle_pinned!` sets it to the state of the card
    push!(listeners, on(v -> v == _pin_state(c) || _toggle_pinned!(gui, c), c.pin_button.active))
    push!(listeners, on(_ -> _browse_parent!(gui, _card_object(gui, c)), c.back_button.clicks))
    _connect_selection_part!(gui, c)
    _connect_dock_button!(gui, c, c.dock_button)
    return nothing
end

#=
Part of the selection, see `_selection_part!`: shared by the floating card of the selection and
the inspector of the app layout, which both have the fields `step_box`, `mode` and `list`
=#

"""
    _connect_selection_part!(gui, part)

Connects the part of the selection `part` (the floating card of the selection or the inspector of
the app layout, see `_selection_part!`) to the `gui`: its step box sets the keyboard step (see
`_set_step!`) and takes the keyboard while focused, its mode control follows the mode of the
controls in both directions, see `_bind_mode!`.
"""
function _connect_selection_part!(gui::LiveView, part)
    listeners = gui.controls.listeners
    push!(listeners, on(s -> _set_step!(gui, s), part.step_box.stored_string))
    push!(listeners, on(_ -> _keep_keyboard!(gui), part.step_box.focused))
    _bind_mode!(gui, part.mode)
    return nothing
end

"""
    _bind_mode!(gui, mode::_Segmented)

Binds the Move/Rotate control `mode` to the mode of the controls of the `gui` in both directions: a
click sets the mode like the key `m` (see `_set_mode!`), the key `m` and a step in another unit (see
`_set_step!`) select the other option.
"""
function _bind_mode!(gui::LiveView, mode::_Segmented)
    ctrl = gui.controls
    sel = mode.selected
    push!(ctrl.listeners, on(m -> _set_mode!(gui, m), sel))
    push!(ctrl.listeners, on(m -> (sel[] == m || (sel[] = m)), ctrl.mode; update = true))
    return nothing
end

"""Sets the mode of the controls of the `gui`, like the key `m`."""
function _set_mode!(gui::LiveView, mode::Symbol)
    ctrl = gui.controls
    ctrl.mode[] == mode && return nothing
    ctrl.mode[] = mode
    _update_selection_box!(ctrl)
    _update_help!(ctrl)
    gui.status.text[] = "$mode mode, step: $(_step_string(mode, ctrl.fine_step, ctrl.fine_angle))"
    return nothing
end

# Names of `properties` that the part of the selection does not list: the header of the card and
# its pose rows show them
const _INSPECTOR_SKIPPED = ("Type", "Position [m]")

"""
    _show_properties!(gui, part, obj)

Shows the properties of `obj` (see `_inspector_rows`) in the property list of the part of the
selection `part`, see `_selection_part!`.
"""
_show_properties!(gui::LiveView, part, obj) = (_set_rows!(part.list, _inspector_rows(gui, obj)); nothing)

"""Returns the rows of the property list for `obj`, see `BeamletOptics.properties`."""
function _inspector_rows(::LiveView, obj)
    props = try
        BMO.properties(obj)
    catch e
        # a failing `properties` method of a user type must not break the live view
        Pair{String, Any}["Error" => sprint(showerror, e)]
    end
    return [_property_row(name, value) for (name, value) in props if !(name in _INSPECTOR_SKIPPED)]
end

"""
The rows of the property list of an inspected system (see `_inspect!`): its properties (see
`BeamletOptics.properties`), then the number of its objects and of its sources.
"""
function _inspector_rows(gui::LiveView, sys::BMO.AbstractSystem)
    rows = invoke(_inspector_rows, Tuple{LiveView, Any}, gui, sys)
    sources = count(p -> p.first === sys, gui.pairs)
    return Tuple{String, String}[rows; ("Objects", string(length(_leaves(sys)))); ("Sources", string(sources))]
end

"""Summary of the live view, shown without a selection, e.g. in the inspector of the app layout."""
function _inspector_rows(gui::LiveView, ::Nothing)
    objects = sum(h -> length(render_children(h)), gui.system_handles; init = 0)
    rows = Tuple{String, String}[
        ("Systems", string(length(gui.system_handles))), ("Objects", string(objects)),
        ("Sources", string(length(_sources(gui)))),
        ("Detectors", string(length(_find_detectors(_systems(gui))))),
        ("Clip planes", string(length(gui.clip.planes))),
        ("Last trace", gui.trace.solve_time > 0 ? _ms_string(gui.trace.solve_time) : "–")]
    return rows
end

"""
    _shows_step(gui, c, obj) -> Bool

Returns `true` if the floating card `c` of the `gui` shows the keyboard step and the mode for its
object `obj`: the card of the selection, and a pinned card while its object is selected, which is
then shown instead of the card of the selection (see `_update_cards!`). Not in a layout that shows
them elsewhere, e.g. in the inspector of the app layout, see `_selection_card_shown`.
"""
_shows_step(gui::LiveView, c::_ComponentCard, obj) = c === gui.cards.selection ||
    (_selection_card_shown(gui) && !c.transient && obj === gui.controls.selected[])

"""
Returns `true` if the card of `obj` has the page "Properties" with the list of its properties (see
`_show_properties!` and `_card_pages`): any object, but no inspected point, measurement or other
`_InfoItem`.
"""
_has_properties(_) = true

"""
    _refresh_selection_part!(gui, c, obj)

Shows the properties of `obj` in the property list of the card `c` while it is shown (see
`_list_shown`: on the page "Properties" of a floating card), otherwise empties the list, see
`_hide_properties!`. For the cards with a list of their own (see `_has_list`), i.e. the floating
cards; the docked cards of the app layout list the properties themselves, see
`_refresh_inspector!`.
"""
function _refresh_selection_part!(gui::LiveView, c::_AbstractCard, obj)
    _has_list(c) || return nothing
    _list_shown(c, obj) ? _show_properties!(gui, c, obj) : _hide_properties!(c)
    return nothing
end
_refresh_selection_part!(::LiveView, ::_AbstractCard, ::Nothing) = nothing

# A card with a property list `list` of its own
_has_list(::_AbstractCard) = false
_has_list(::_ComponentCard) = true
# A floating card lists the properties on its page "Properties"
_list_shown(c::_ComponentCard, obj) = c.page === :properties && _has_properties(obj)
# The list of a floating card that is not shown is moved away with its part, see `_lower_parts`
_hide_properties!(::_AbstractCard) = nothing

# The button that docks the pinned card `c` in the sidebar, if the layout has one, see `_card_tools!`
_connect_dock_button!(::LiveView, ::_ComponentCard, ::Nothing) = nothing
_connect_dock_button!(gui::LiveView, c::_ComponentCard, b::_IconButton) =
    (push!(gui.controls.listeners, on(_ -> _dock!(gui, c.obj), b.clicks)); nothing)

"""
    _shield_cards!(gui)

(Re)adds the listeners that keep the presses and the scrolling over the cards of the `gui` and
over the parts of its layout in the 3D view (see `_over_layout`) from the camera: after the
widgets of all cards and parts (Textbox 70, Button 1), whose presses they would take otherwise,
and before the camera (0). Called again when widgets are added later.
"""
function _shield_cards!(gui::LiveView)
    ev = events(gui.ax.scene)
    listeners = gui.controls.listeners
    foreach(off, gui.cards.shield)
    filter!(l -> !any(s -> s === l, gui.cards.shield), listeners)
    over = () -> any(c -> _over_card(c, ev), gui.cards.all) || _over_browse_card(gui) ||
                 _over_catalog(gui) || _over_layout(gui)
    gui.cards.shield = Any[on(event -> Consume(event.action == Mouse.press && over()), ev.mousebutton; priority = 1),
        on(_ -> Consume(over()), ev.scroll; priority = 1)]
    append!(listeners, gui.cards.shield)
    return nothing
end

"""
    _outside_view(gui) -> Bool

Returns `true` if the mouse is over a part of the layout of the `gui` whose presses are not clicks
into the 3D view, see `ignore_mouse` of the controls: the controls neither select nor deselect on
them. By default none, see `AbstractLiveLayout`.
"""
_outside_view(::LiveView) = false

"""
    _connect_cards!(gui)

Connects the cards of the `gui`: their widgets, their update every frame and the mouse. Presses on
a card reach its widgets only: the controls ignore them (`ignore_mouse`) and the camera does not
get them, see `_shield_cards!`; a drag at its head moves the card, see `_drag_cards!`, a drag at
its grip resizes its view, see `_resize_cards!`. A press
elsewhere ends the input into the textboxes of the cards, also if the controls consume it.
"""
function _connect_cards!(gui::LiveView)
    ctrl = gui.controls
    ev = events(gui.ax.scene)
    over = () -> any(c -> _over_card(c, ev), gui.cards.all) || _over_browse_card(gui) ||
                 _over_catalog(gui) || _card_menu_open(gui)
    ctrl.ignore_mouse = () -> over() || _outside_view(gui)
    foreach(c -> _connect_card!(gui, c), gui.cards.all)
    push!(ctrl.listeners, on(_ -> _update_cards!(gui), ev.tick))
    # Before the controls (200)
    push!(ctrl.listeners, on(ev.mousebutton, priority = 250) do event
        event.action == Mouse.press && !over() && foreach(_defocus_card!, gui.cards.all)
        return Consume(false)
    end)
    _drag_cards!(gui)
    _resize_cards!(gui)
    _click_cards!(gui)
    _shield_cards!(gui)
    _update_cards!(gui)
    return nothing
end

"""Selects the object `obj` of a pinned card of the `gui` after a click on the card, if it can be selected."""
function _select_pinned!(gui::LiveView, obj)
    (isnothing(obj) || !_is_movable(gui.controls, obj)) && return nothing
    _select!(gui, obj)
    return nothing
end

"""Returns `true` if the point `p` [figure px] is over a widget among the `blocks` of a card, i.e. not over a text."""
_over_widget(blocks, p::Point2f) = any(b -> b isa Makie.Block && !(b isa Union{Label, Makie.Box}) &&
    p in Rect2f(b.layoutobservables.computedbbox[]), blocks)

"""
    _click_cards!(gui)

A click on a pinned floating card of the `gui` selects its object (see `_select_pinned!`): on its
head (see `_drag_cards!`, which takes the presses there) or, here, on its rows beside the widgets,
whose clicks keep their meaning. The listener comes after `_drag_cards!` and passes the events on.
"""
function _click_cards!(gui::LiveView)
    ev = events(gui.ax.scene)
    # The card and the mouse at the press
    press = Ref{Any}(nothing)
    push!(gui.controls.listeners, on(ev.mousebutton, priority = 2) do event
        event.button == Mouse.left || return Consume(false)
        p = Point2f(ev.mouseposition[])
        if event.action == Mouse.press
            i = findlast(c -> c.pinned && _over_card(c, ev) && p in _part_rect(c.rows) &&
                              !_over_widget(c.blocks, p), gui.cards.all)
            press[] = isnothing(i) ? nothing : (gui.cards.all[i], p)
        elseif event.action == Mouse.release && !isnothing(press[])
            c, p0 = press[]
            press[] = nothing
            (c.pinned && maximum(abs, p - p0) < _CARD_DRAG_MIN) && _select_pinned!(gui, c.obj)
        end
        return Consume(false)
    end)
    return nothing
end

# Distance [px] that the mouse must move with the button down until a press at the head of a card
# moves it, and the longest pause [s] between the two clicks of a double click there
const _CARD_DRAG_MIN = 3.0f0
const _CARD_DOUBLE_CLICK = 0.4

"""
    _drag_cards!(gui)

Connects the mouse to the handles of the floating cards of the `gui`, i.e. their heads outside the
buttons (see `_over_handle`): a drag moves the card, which then stays at its new `spot` (see
`_card_spot`) with its line to the object, while the camera and the objects move, when it is pinned
and, on the card of the selection, when another object is selected. The cards without a spot keep
off it, see `_update_cards!`. A double click on the handle places the card next to its object again;
so do unpinning it and pinning another card, see `_pin!`. The listeners come before the widgets of
the cards (Button 1) and the mouse shield (1), after the controls (200), which ignore the presses on
the cards.
"""
function _drag_cards!(gui::LiveView)
    ev = events(gui.ax.scene)
    listeners = gui.controls.listeners
    # The card, the mouse at the press, the top left corner of the card at the press and whether it moved
    drag = Ref{Any}(nothing)
    # The card and the time of the last click on a handle, for the double click
    click = Ref{Any}((nothing, 0.0))
    push!(listeners, on(ev.mousebutton, priority = 2) do event
        event.button == Mouse.left || return Consume(false)
        if event.action == Mouse.press
            i = findlast(c -> _over_handle(c, ev), gui.cards.all)
            isnothing(i) && return Consume(false)
            c = gui.cards.all[i]
            r = c.background.layoutobservables.suggestedbbox[]
            drag[] = (c, Point2f(ev.mouseposition[]), Point2f(minimum(r)[1], maximum(r)[2]), false)
            return Consume(true)
        elseif event.action == Mouse.release && !isnothing(drag[])
            c, _, _, moved = drag[]
            drag[] = nothing
            moved && return Consume(true)
            prev, t = click[]
            if prev === c && time() - t < _CARD_DOUBLE_CLICK
                c.spot = nothing
                click[] = (nothing, 0.0)
                _update_cards!(gui)
            else
                click[] = (c, time())
                # A click on the head of a pinned card selects its object, see `_click_cards!`
                c.pinned && _select_pinned!(gui, c.obj)
            end
            return Consume(true)
        end
        return Consume(false)
    end)
    push!(listeners, on(ev.mouseposition, priority = 2) do xy
        isnothing(drag[]) && return Consume(false)
        c, start, p0, moved = drag[]
        d = Point2f(xy) - start
        (moved || maximum(abs, d) >= _CARD_DRAG_MIN) || return Consume(true)
        drag[] = (c, start, p0, true)
        size, view = _card_size(c), Rect2f(Makie.viewport(gui.ax.scene)[])
        # The spot of the card inside the view
        c.spot = _card_spot(_spot_position(_card_spot(p0 + d, size, view), size, view), size, view)
        _update_cards!(gui)
        return Consume(true)
    end)
    return nothing
end

"""
    _resize_cards!(gui)

Connects the mouse to the grips of the floating cards of the `gui`, at their bottom right corner
while their expanded view is shown (see `_over_grip`): a drag changes the size of the axis of the
view (`view_size`, which the card remembers) within the bounds of the 3D view, see
`_set_view_size!`. During the drag the card keeps its top left corner, such that the grip follows
the mouse; afterwards it is placed next to its object again, unless the mouse moved it to a `spot`
before. The listeners come with those of `_drag_cards!`, before the widgets of the cards and the
mouse shield.
"""
function _resize_cards!(gui::LiveView)
    ev = events(gui.ax.scene)
    listeners = gui.controls.listeners
    # The card, the mouse, the size of the axis and the top left corner of the card at the press,
    # and the spot of the card before
    drag = Ref{Any}(nothing)
    function finish!()
        c, _, _, _, spot = drag[]
        drag[] = nothing
        c.spot = spot
        _update_cards!(gui)
        return nothing
    end
    push!(listeners, on(ev.mousebutton, priority = 2) do event
        event.button == Mouse.left || return Consume(false)
        if event.action == Mouse.press
            i = findlast(c -> _over_grip(c, ev), gui.cards.all)
            isnothing(i) && return Consume(false)
            c = gui.cards.all[i]
            r = c.background.layoutobservables.suggestedbbox[]
            drag[] = (c, Point2f(ev.mouseposition[]), Vec2f(c.view.ax.width[], c.view.ax.height[]),
                Point2f(minimum(r)[1], maximum(r)[2]), c.spot)
            return Consume(true)
        elseif event.action == Mouse.release && !isnothing(drag[])
            finish!()
            return Consume(true)
        end
        return Consume(false)
    end)
    push!(listeners, on(ev.mouseposition, priority = 2) do xy
        isnothing(drag[]) && return Consume(false)
        c, start, size0, p0, _ = drag[]
        # the card lost its view, e.g. with another selection by a key
        if !_has_grip(c)
            finish!()
            return Consume(false)
        end
        d = Point2f(xy) - start
        view = Rect2f(Makie.viewport(gui.ax.scene)[])
        # the mouse moves the bottom right corner: to the right and down
        _set_view_size!(c, Vec2f(size0[1] + d[1], size0[2] - d[2]), view)
        size = _card_size(c)
        c.spot = _card_spot(_spot_position(_card_spot(p0, size, view), size, view), size, view)
        _update_cards!(gui)
        return Consume(true)
    end)
    return nothing
end
