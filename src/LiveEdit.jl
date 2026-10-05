#=
The page "Edit" of the card of a component or source that was built from an entry of the catalog:
the form of the entry, and "Apply", which builds the object again in its pose, see `_replace!`
=#

"""
Whether `obj` of the `gui` can be built again with other parameters: it was built from an entry of
the catalog, whose `origin` keeps the entry and its inputs, see `_catalog_component`.
"""
function _editable(gui::LiveView, obj)
    origin = get(gui.components.origin, obj, nothing)
    return !isnothing(origin) && haskey(origin, :entry) && haskey(origin, :strings)
end

_has_page(gui::LiveView, obj, ::Val{:edit}) = _editable(gui, obj)
_page_rows(gui::LiveView, obj, ::Val{:edit}) = _editable(gui, obj) ? _edit_rows(gui, obj) : ()

"""
    _edit_strings(gui, obj) -> Vector{String}

The inputs of the page "Edit" of `obj`, one per parameter of its entry of the catalog (see
`_catalog_value`): those with which it was built, or those that were changed since and are not
applied yet.
"""
_edit_strings(gui::LiveView, obj) =
    get(gui.components.edits, obj, gui.components.origin[obj].strings)

# Changes the input `i` of the page "Edit" of `obj` to `s`, without applying it
function _set_edit_string!(gui::LiveView, obj, i::Int, s::AbstractString)
    strings = copy(_edit_strings(gui, obj))
    strings[i] = String(s)
    gui.components.edits[obj] = strings
    return nothing
end

# The names of the widgets of the parameter `i`: its box and, of a glass, its menu
_edit_box(i::Int) = Symbol(:edit_, i)
_edit_menu(i::Int) = Symbol(:edit_glass_, i)

"""The cards of the `gui` that can show the page "Edit": the floating ones, and docked ones of a layout."""
_edit_cards(gui::LiveView) = Any[gui.cards.all...]
_edit_cards(gui::AppView) = Any[gui.cards.all..., _docked_cards(gui)...]

"""
    _read_edit_inputs!(gui, obj)

Takes what the boxes of the page "Edit" of the cards of `obj` show into its inputs, see
`_edit_strings`: "Apply" also takes a text that was typed without Enter.
"""
function _read_edit_inputs!(gui::LiveView, obj)
    params = gui.components.origin[obj].entry.params
    for c in _edit_cards(gui)
        (c.page === :edit && _card_object(gui, c) === obj) || continue
        for (i, p) in enumerate(params)
            box = _card_widget(c, _edit_box(i))
            box isa Textbox || continue
            text = strip(something(box.displayed_string[], ""))
            _takes_edit_text(gui, obj, p, i, text) && _set_edit_string!(gui, obj, i, text)
        end
        return nothing
    end
    return nothing
end

# The text of the box of a number is its input; the box of a glass only while "constant" is chosen
_takes_edit_text(::LiveView, _, ::CatalogParam, ::Int, text) = !isempty(text)
_takes_edit_text(gui::LiveView, obj, ::CatalogGlass, i::Int, text) =
    !isempty(text) && !(_edit_strings(gui, obj)[i] in _glass_names())

"""
    _apply_edit!(gui, obj)

"Apply" of the page "Edit" of `obj`: builds its entry of the catalog with the inputs of the page
(see `_read_edit_inputs!`, unless `read` is `false`) and puts the new object in the place of `obj`,
see `_replace!`. An
invalid input or an error of the constructor only shows a message in the status line; unchanged
inputs do nothing.
"""
function _apply_edit!(gui::LiveView, obj; read::Bool = true)
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
function _show_edit_page!(gui::LiveView, obj)
    _update_cards!(gui)
    _update_inspector!(gui)
    for c in _edit_cards(gui)
        (_card_object(gui, c) === obj && :edit in _card_pages(gui, obj)) && _set_page!(gui, c, :edit)
    end
    return nothing
end

#=
Rows of the page
=#

# The value of the box of the parameter `i`: its input, of a glass only a constant refractive index
_edit_box_text(gui::LiveView, obj, ::CatalogParam, i::Int) = _edit_strings(gui, obj)[i]
function _edit_box_text(gui::LiveView, obj, ::CatalogGlass, i::Int)
    s = _edit_strings(gui, obj)[i]
    return s in _glass_names() ? "" : s
end

# The entry of the menu of the glass `i`: its glass, or "constant"
function _edit_glass(gui::LiveView, obj, i::Int)
    s = _edit_strings(gui, obj)[i]
    return s in _glass_names() ? s : _GLASS_CONSTANT
end

# The menu of the glass `i` chose `name`: the glass, or the constant refractive index of the box
function _choose_edit_glass!(gui::LiveView, obj, p::CatalogGlass, i::Int, name)
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
function _enter_edit!(gui::LiveView, obj, i::Int, s)
    # the other boxes as they are shown, then the entered one
    _read_edit_inputs!(gui, obj)
    isnothing(s) || _set_edit_string!(gui, obj, i, strip(s))
    _apply_edit!(gui, obj; read = false)
    return nothing
end

_edit_label(text) = CardWidget(Label; text, width = 76, halign = :left)

_edit_param_rows(p::CatalogParam, i::Int) = (CardRow(_edit_label(p.name),
    CardWidget(Textbox; name = _edit_box(i), placeholder = " ", width = 76,
        value = (gui, o) -> _edit_box_text(gui, o, p, i), on = (gui, o, s) -> _enter_edit!(gui, o, i, s)),
    p.unit),)

_edit_param_rows(p::CatalogGlass, i::Int) = (
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
name of the entry, a box per number and a menu of the glasses with the box of a constant refractive
index per glass, as in the form of the catalog, and the button "Apply", see `_apply_edit!`. Enter
in a box applies as well.
"""
function _edit_rows(gui::LiveView, obj)
    entry = gui.components.origin[obj].entry
    rows = CardRow[CardRow(CardWidget(Label; text = entry.name, font = :bold, halign = :left))]
    for (i, p) in enumerate(entry.params)
        append!(rows, _edit_param_rows(p, i))
    end
    push!(rows, CardRow(CardWidget(Button; name = :edit_apply, label = "Apply",
        on = (gui, o, _) -> _apply_edit!(gui, o))))
    return Tuple(rows)
end
