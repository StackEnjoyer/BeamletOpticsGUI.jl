#=
The page "Edit" of the card of a component or source that was built from an entry of the catalog:
the form of the entry, and "Apply", which builds the object again in its pose, see `_replace!`
=#

"""
Whether `obj` of the `gui` can be built again with other parameters: it was built from an entry of
the catalog, whose `origin` keeps the entry and its inputs, see `_catalog_component`.
"""
function _editable(gui::LiveView, @nospecialize(obj))
    origin = get(gui.components.origin, obj, nothing)
    return !isnothing(origin) && haskey(origin, :entry) && haskey(origin, :strings)
end

_has_page(gui::LiveView, @nospecialize(obj), ::Val{:edit}) = _editable(gui, obj)
_page_rows(gui::LiveView, @nospecialize(obj), ::Val{:edit}) = _editable(gui, obj) ? _edit_rows(gui, obj) : ()

"""
    _edit_strings(gui, obj) -> Vector{String}

The inputs of the page "Edit" of `obj`, one per parameter of its entry of the catalog (see
`_catalog_value`): those with which it was built, or those that were changed since and are not
applied yet.
"""
_edit_strings(gui::LiveView, @nospecialize(obj)) =
    get(gui.components.edits, obj, gui.components.origin[obj].strings)

# Changes the input `i` of the page "Edit" of `obj` to `s`, without applying it
function _set_edit_string!(gui::LiveView, @nospecialize(obj), i::Int, s::AbstractString)
    strings = copy(_edit_strings(gui, obj))
    strings[i] = String(s)
    gui.components.edits[obj] = strings
    return nothing
end

# The names of the widgets of the parameter `i`: its box and, of a glass, its menu
_edit_box(i::Int) = Symbol(:edit_, i)
_edit_menu(i::Int) = Symbol(:edit_glass_, i)
# Of a surface: its menu, and the box of its field `k`, see `_edit_surface`: the radius in the box
# of the parameter, then the conic constant and the coefficients
_edit_surface_menu(i::Int) = Symbol(:edit_surface_, i)
_edit_field(i::Int, k::Int) = k == 1 ? _edit_box(i) : k == 2 ? Symbol(:edit_, i, :_k) :
                              Symbol(:edit_, i, :_A, _SURFACE_ORDERS[k - 2])

"""The cards of the `gui` that can show the page "Edit": the floating ones, and docked ones of a layout."""
_edit_cards(gui::LiveView) = Any[gui.cards.all...]
_edit_cards(gui::AppView) = Any[gui.cards.all..., _docked_cards(gui)...]

"""
    _read_edit_inputs!(gui, obj)

Takes what the boxes of the page "Edit" of the cards of `obj` show into its inputs, see
`_edit_strings`: "Apply" also takes a text that was typed without Enter.
"""
function _read_edit_inputs!(gui::LiveView, @nospecialize(obj))
    params = gui.components.origin[obj].entry.params
    for c in _edit_cards(gui)
        (c.page === :edit && _card_object(gui, c) === obj) || continue
        for (i, p) in enumerate(params)
            _read_edit_input!(gui, obj, c, p, i)
        end
        return nothing
    end
    return nothing
end

# What the box with the `name` on the card `c` shows, `nothing` without such a box
function _edit_shown(c, name::Symbol)
    box = _card_widget(c, name)
    box isa Textbox || return nothing
    return String(strip(something(box.displayed_string[], "")))
end

# Takes what the boxes of the parameter `i` on the card `c` show into its input: the one box of a
# number and of a glass, the boxes of the fields of a surface, which share the text of the surface
function _read_edit_input!(gui::LiveView, @nospecialize(obj), c, p, i::Int)
    text = _edit_shown(c, _edit_box(i))
    isnothing(text) && return nothing
    _takes_edit_text(gui, obj, p, i, text) && _set_edit_string!(gui, obj, i, text)
    return nothing
end
function _read_edit_input!(gui::LiveView, @nospecialize(obj), c, p::CatalogSurface, i::Int)
    aspheric, texts = _edit_surface(gui, obj, i)
    changed = false
    for k in eachindex(texts)
        shown = _edit_shown(c, _edit_field(i, k))
        isnothing(shown) && continue
        text = _surface_field(shown)
        (_takes_edit_text(gui, obj, p, i, text) && text != texts[k]) || continue
        texts[k] = text
        changed = true
    end
    changed && _set_edit_surface!(gui, obj, i, aspheric, texts)
    return nothing
end

# The text of the box of a number is its input; the box of a glass only while "constant" is chosen;
# an empty box of a field of a surface keeps the text of the field
_takes_edit_text(::LiveView, _, ::CatalogParam, ::Int, text) = !isempty(text)
_takes_edit_text(gui::LiveView, @nospecialize(obj), ::CatalogGlass, i::Int, text) =
    !isempty(text) && !(_edit_strings(gui, obj)[i] in _glass_names())
_takes_edit_text(::LiveView, _, ::CatalogSurface, ::Int, text) = !isempty(text)

"""
    _apply_edit!(gui, obj)

"Apply" of the page "Edit" of `obj`: builds its entry of the catalog with the inputs of the page
(see `_read_edit_inputs!`, unless `read` is `false`) and puts the new object in the place of `obj`,
see `_replace!`. An
invalid input or an error of the constructor only shows a message in the status line; unchanged
inputs do nothing.
"""
function _apply_edit!(gui::LiveView, @nospecialize(obj); read::Bool = true)
    _editable(gui, obj) || return nothing
    read && _read_edit_inputs!(gui, obj)
    origin = gui.components.origin[obj]
    strings = _edit_strings(gui, obj)
    if strings == origin.strings
        gui.status.text[] = "$(_label(gui, obj)): nothing to apply"
        return nothing
    end
    c = try
        _catalog_component(origin.entry, strings)
    catch e
        e isa InterruptException && rethrow()
        msg = first(split(sprint(showerror, e), '\n'))
        gui.status.text[] = "$(_label(gui, obj)) not changed: $msg"
        return nothing
    end
    name = _label(gui, obj)
    _replace!(gui, obj, c.obj, c.origin)
    gui.status.text[] = "$name changed"
    return nothing
end

"""
    _replacement_snapshot(gui, old, new, origin, snap)

The snapshot (see `_snapshot`) with which `new` takes the place of `old`, whose snapshot is `snap`:
the system and the label of `old`, its name, and the `origin` of `new`. A source keeps how it is
drawn, except a color that was the one of the wavelength of `old`, which follows the wavelength.
"""
function _replacement_snapshot(gui::LiveView, old, new, origin, snap)
    names = haskey(gui.objects.names, old) ? Pair{Any, String}[new => gui.objects.names[old]] :
            Pair{Any, String}[]
    return _replacement_kwargs(old, merge(snap, (; origin, names, init_poses = Pair{Any, Any}[])))
end

_replacement_kwargs(_, snap) = snap
function _replacement_kwargs(old::_Source, snap)
    ref = get(_wavelength_style(old), :color, nothing)
    follows = haskey(snap.kwargs, :color) && !isnothing(ref) && _same_color(snap.kwargs.color, ref)
    return follows ? merge(snap, (; kwargs = Base.structdiff(snap.kwargs, NamedTuple{(:color,)}))) : snap
end

"""
    _replace!(gui, old, new, origin)

Puts the component or source `new` with its `origin` in the place of `old` in the `gui`: `new` gets
the pose of `old`, i.e. it is moved and rotated from its pose as constructed like `old` was from
its own, then `old` is removed and `new` is added to the same system with the label of `old` and
selected, and the card of the selection shows its page "Edit" again. The replacement is one action
of the undo history: undo brings `old` back, redo `new`.
"""
function _replace!(gui::LiveView, old, new, origin)
    comp = gui.components
    old_snap = _snapshot(gui, old)
    # The pose of `old` relative to its pose as constructed, applied to `new`
    P, R = _pose(old)
    P0, R0 = old_snap.origin.pose0
    Pn, Rn = origin.pose0
    ΔR = R * R0'
    _set_pose_exact!(new, Point3{Float64}(Vector{Float64}(P) .+ ΔR * (Vector{Float64}(Pn) .- Vector{Float64}(P0))),
        ΔR * Rn)
    new_snap = Ref{Any}(_replacement_snapshot(gui, old, new, origin, old_snap))
    old_state = Ref{Any}(old_snap)
    swap!(out, out_state, in, in_state) = begin
        out_state[] = _remove_unrecorded!(gui, out)
        delete!(comp.edits, out)
        _restore!(gui, in, in_state[])
        _show_edit_page!(gui, in)
        return nothing
    end
    swap!(old, old_state, new, new_snap)
    comp.recording && _push_action!(gui.controls, new, () -> swap!(new, new_snap, old, old_state),
        () -> swap!(old, old_state, new, new_snap))
    return new
end

"""Shows the page "Edit" of the cards of `obj` again, e.g. after it replaced the object of the page."""
function _show_edit_page!(gui::LiveView, @nospecialize(obj))
    _update_cards!(gui)
    _update_inspector!(gui)
    for c in _edit_cards(gui)
        (_card_object(gui, c) === obj && :edit in _card_pages(gui, obj)) && _set_page!(gui, c, :edit)
    end
    return nothing
end

"""
    _rebuild_edit_rows!(gui, obj)

Builds the rows of the page "Edit" of the cards that show it for `obj` again, with the inputs of
the page as their values: the rows depend on the inputs, see `_edit_param_rows` of a surface, and a
card builds its rows only for another object or another page, see `_set_page!`.
"""
function _rebuild_edit_rows!(gui::LiveView, @nospecialize(obj))
    _editable(gui, obj) || return nothing
    for c in _edit_cards(gui)
        (c.page === :edit && _card_object(gui, c) === obj) || continue
        # as if the page was chosen again
        c.page = :pose
        _set_page!(gui, c, :edit)
    end
    return nothing
end

"""
    _rebuild_edit_rows_later!(gui, obj)

`_rebuild_edit_rows!` at the next frame, for a widget of the page that changes its rows, e.g. the
menu of a surface: the widget is deleted with the rows and must not be while it handles its own
input, like the menu of a glass in the form of the catalog, see `_flush_catalog_form!`.
"""
function _rebuild_edit_rows_later!(gui::LiveView, @nospecialize(obj))
    listeners = gui.controls.listeners
    listener = Ref{Any}(nothing)
    # The last listener of the frame: it removes itself, and no other one is skipped by that
    listener[] = on(events(gui.ax.scene).tick; priority = typemin(Int)) do _
        off(listener[])
        k = _index(listeners, listener[])
        isnothing(k) || deleteat!(listeners, k)
        _rebuild_edit_rows!(gui, obj)
        return nothing
    end
    push!(listeners, listener[])
    return nothing
end

#=
Rows of the page
=#

# The value of the box of the parameter `i`: its input, of a glass only a constant refractive index
_edit_box_text(gui::LiveView, @nospecialize(obj), ::CatalogParam, i::Int) = _edit_strings(gui, obj)[i]
function _edit_box_text(gui::LiveView, @nospecialize(obj), ::CatalogGlass, i::Int)
    s = _edit_strings(gui, obj)[i]
    return s in _glass_names() ? "" : s
end

# The entry of the menu of the glass `i`: its glass, or "constant"
function _edit_glass(gui::LiveView, @nospecialize(obj), i::Int)
    s = _edit_strings(gui, obj)[i]
    return s in _glass_names() ? s : _GLASS_CONSTANT
end

# The menu of the glass `i` chose `name`: the glass, or the constant refractive index of the box
function _choose_edit_glass!(gui::LiveView, @nospecialize(obj), p::CatalogGlass, i::Int, name)
    name isa AbstractString || return nothing
    # The card shows its values again after an input: keep what was typed into its boxes
    _read_edit_inputs!(gui, obj)
    if name == _GLASS_CONSTANT
        _edit_glass(gui, obj, i) == _GLASS_CONSTANT ||
            _set_edit_string!(gui, obj, i, _catalog_number_string(p.n))
    else
        _set_edit_string!(gui, obj, i, name)
    end
    return nothing
end

# Enter in the box of the parameter `i`: its input, then "Apply"
function _enter_edit!(gui::LiveView, @nospecialize(obj), i::Int, s)
    # the other boxes as they are shown, then the entered one
    _read_edit_inputs!(gui, obj)
    isnothing(s) || _set_edit_string!(gui, obj, i, strip(s))
    _apply_edit!(gui, obj; read = false)
    return nothing
end

#=
Surfaces: the menu and the boxes of a surface share its one input, the text of the surface, see
`_surface_string`
=#

"""
    _edit_surface(gui, obj, i) -> (aspheric, texts)

The input `i` of the page "Edit" of `obj`, the text of a surface, as the fields of its widgets
(see `_surface_fields`): whether the menu shows "aspheric", and the `texts` of the boxes, i.e. of
the radius, the conic constant and the coefficients of `_SURFACE_ORDERS`, see `_edit_field`.
"""
function _edit_surface(gui::LiveView, @nospecialize(obj), i::Int)
    f = _surface_fields(_edit_strings(gui, obj)[i])
    return f.aspheric, String[f.radius, f.conic, f.coefficients...]
end

# Changes the input `i` of `obj`, a surface, to the fields of `_edit_surface`, without applying it
_set_edit_surface!(gui::LiveView, @nospecialize(obj), i::Int, aspheric::Bool, texts) =
    _set_edit_string!(gui, obj, i, _surface_string(aspheric, texts[1], texts[2], @view texts[3:end]))

# The entry of the menu of the surface `i`
_edit_surface_kind(gui::LiveView, @nospecialize(obj), i::Int) =
    first(_edit_surface(gui, obj, i)) ? _SURFACE_ASPHERIC : _SURFACE_SPHERICAL

# What the box of the field `k` of the surface `i` shows; none of an asphere for a spherical one
function _edit_field_text(gui::LiveView, @nospecialize(obj), i::Int, k::Int)
    aspheric, texts = _edit_surface(gui, obj, i)
    return (aspheric || k == 1) ? texts[k] : ""
end

"""
    _choose_edit_surface!(gui, obj, i, name)

The menu of the surface `i` of the page "Edit" of `obj` chose `name`: an asphere gets the radius of
the spherical surface, a conic constant of zero and no coefficients; a spherical surface keeps the
radius of the asphere. The boxes of the asphere come and go at the next frame, see
`_rebuild_edit_rows_later!`.
"""
function _choose_edit_surface!(gui::LiveView, @nospecialize(obj), i::Int, name)
    name isa AbstractString || return nothing
    # The card shows its values again after an input: keep what was typed into its boxes
    _read_edit_inputs!(gui, obj)
    aspheric, texts = _edit_surface(gui, obj, i)
    (name == _SURFACE_ASPHERIC) == aspheric && return nothing
    _set_edit_surface!(gui, obj, i, !aspheric, texts)
    _rebuild_edit_rows_later!(gui, obj)
    return nothing
end

# Enter in the box of the field `k` of the surface `i`: its input, then "Apply", see `_enter_edit!`
function _enter_edit_surface!(gui::LiveView, @nospecialize(obj), i::Int, k::Int, s)
    _read_edit_inputs!(gui, obj)
    if !isnothing(s)
        aspheric, texts = _edit_surface(gui, obj, i)
        if aspheric || k == 1
            texts[k] = _surface_field(s)
            _set_edit_surface!(gui, obj, i, aspheric, texts)
        end
    end
    _apply_edit!(gui, obj; read = false)
    return nothing
end

_edit_label(text; width = 76) = CardWidget(Label; text, width, halign = :left)

# The label and the box of the field `k` of the surface `i`
_edit_field_cells(i::Int, k::Int, label; width = 76) = (_edit_label(label; width),
    CardWidget(Textbox; name = _edit_field(i, k), placeholder = " ", width = 76,
        value = (gui, o) -> _edit_field_text(gui, o, i, k),
        on = (gui, o, s) -> _enter_edit_surface!(gui, o, i, k, s)))

# The label of the field `k` of an asphere: "k" and "A4", "A6", ...
_edit_field_label(k::Int) = k == 2 ? "k" : "A$(_SURFACE_ORDERS[k - 2])"

"""
    _edit_param_rows(gui, obj, p, i) -> rows

The rows of the parameter `p`, the input `i`, on the page "Edit" of `obj`: a box for a number, the
menu and the box of a constant refractive index for a glass, and for a surface its menu
("spherical", "aspheric"), the box of its radius and, only while "aspheric" is chosen, the boxes of
the conic constant `k` and of the coefficients A4, A6, ... [mm^(1 - order)], two in a row. The rows
of a surface thus depend on its input, see `_rebuild_edit_rows!`.
"""
_edit_param_rows(::LiveView, _, p::CatalogParam, i::Int) = (CardRow(_edit_label(p.name),
    CardWidget(Textbox; name = _edit_box(i), placeholder = " ", width = 76,
        value = (gui, o) -> _edit_box_text(gui, o, p, i), on = (gui, o, s) -> _enter_edit!(gui, o, i, s)),
    p.unit),)

function _edit_param_rows(gui::LiveView, @nospecialize(obj), p::CatalogSurface, i::Int)
    aspheric, texts = _edit_surface(gui, obj, i)
    rows = CardRow[
        CardRow(_edit_label(p.name), CardWidget(Menu; name = _edit_surface_menu(i),
            options = String[_SURFACE_SPHERICAL, _SURFACE_ASPHERIC], width = 128,
            value = (gui, o) -> _edit_surface_kind(gui, o, i),
            on = (gui, o, name) -> _choose_edit_surface!(gui, o, i, name))),
        CardRow(_edit_field_cells(i, 1, "radius")..., _SURFACE_UNIT)]
    aspheric || return Tuple(rows)
    for ks in Iterators.partition(2:length(texts), 2)
        left, right = first(ks), last(ks)
        cells = Any[_edit_field_cells(i, left, _edit_field_label(left))...]
        right == left || append!(cells, _edit_field_cells(i, right, _edit_field_label(right); width = 28))
        push!(rows, CardRow(cells...))
    end
    return Tuple(rows)
end

_edit_param_rows(::LiveView, _, p::CatalogGlass, i::Int) = (
    CardRow(_edit_label(p.name), CardWidget(Menu; name = _edit_menu(i),
        options = String[_glass_names()..., _GLASS_CONSTANT], width = 128,
        value = (gui, o) -> _edit_glass(gui, o, i),
        on = (gui, o, name) -> _choose_edit_glass!(gui, o, p, i, name))),
    CardRow(_edit_label("n (constant)"), CardWidget(Textbox; name = _edit_box(i), placeholder = " ",
        width = 76, value = (gui, o) -> _edit_box_text(gui, o, p, i),
        on = (gui, o, s) -> _enter_edit!(gui, o, i, s))))

"""
    _edit_rows(gui, obj)

The rows of the page "Edit" of the card of `obj`, which was built from an entry of the catalog: the
name of the entry, a box per number, a menu of the glasses with the box of a constant refractive
index per glass and a menu with the boxes of its fields per surface, as in the form of the catalog
(see `_edit_param_rows`), and the button "Apply", see `_apply_edit!`. Enter in a box applies as
well.
"""
function _edit_rows(gui::LiveView, @nospecialize(obj))
    entry = gui.components.origin[obj].entry
    rows = CardRow[CardRow(CardWidget(Label; text = entry.name, font = :bold, halign = :left))]
    for (i, p) in enumerate(entry.params)
        append!(rows, _edit_param_rows(gui, obj, p, i))
    end
    push!(rows, CardRow(CardWidget(Button; name = :edit_apply, label = "Apply",
        on = (gui, o, _) -> _apply_edit!(gui, o))))
    return Tuple(rows)
end
