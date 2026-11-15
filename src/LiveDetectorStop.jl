#=
The switch "stop beams" on the card of a detector, which changes the detector itself, see `_set_stop!`
=#

# The row of the switch on the page "Pose" of the card of a `Detector`, see `card_rows`
_stop_row() = CardRow("stop", CardWidget(Toggle; name = :stop, value = (gui, d) -> BMO.stop(d),
    on = (gui, d, v) -> _set_stop!(gui, d, v)), "beams")

"""
    _set_stop!(gui, d, stop::Bool)

Switches whether the detector `d` of the `gui` stops the beams that hit it, in place
(`BeamletOptics.stop!`): it stays the same object, in its systems, with its label and its cards. Like
a move, a running solve is cancelled first, then the systems are solved again, or marked as outdated
without auto tracing, via the `on_change` of the controls. The code of `d` (of the catalog, of a
project or added with `code`) gets the new state in every window that shows `d`, see `_stop_code!`,
such that export, save and copy keep it; `export_changes` writes a `BeamletOptics.stop!` for a
detector without code. An entry of the undo history. Nothing happens if the state does not change.
"""
function _set_stop!(gui::LiveView, @nospecialize(d), stop::Bool)
    BMO.stop(d) == stop && return nothing
    _change!(() -> BMO.stop!(d, stop), gui.controls, d)
    comp = gui.components
    haskey(comp.stops0, d) || (comp.stops0[d] = !stop)
    # every window of the links that shows `d`, also this one
    foreach(v -> _stop_code!(v, d, stop), unique(objectid, Any[gui, gui.links.views...]))
    if comp.recording
        _push_action!(gui.controls, d, () -> _unrecorded(() -> _set_stop!(gui, d, !stop), gui),
            () -> _unrecorded(() -> _set_stop!(gui, d, stop), gui))
    end
    _update_cards!(gui)
    _update_inspector!(gui)
    gui.controls.on_change(d)
    return nothing
end

"""
    _stop_code!(gui, d, stop::Bool)

Writes the state `stop` of the detector `d` into its origin in the `gui` (see `_ComponentState`): for
an entry of the catalog its input of the switch, with which the code is built again (and a pending
input of the page "Edit"); for other code the second argument of its call `Detector(…)`, see
`_stop_call_code`. Code that is no such call keeps its state, and the status line says that the
switch is not saved. Nothing for a detector without code, e.g. one of the user's script.
"""
function _stop_code!(gui::LiveView, @nospecialize(d), stop::Bool)
    comp = gui.components
    origin = get(comp.origin, d, nothing)
    isnothing(origin) && return nothing
    i = haskey(origin, :entry) && origin.entry.constructor === BMO.Detector ?
        findfirst(_is_toggle, origin.entry.params) : nothing
    if !isnothing(i) && haskey(origin, :strings)
        strings = copy(origin.strings)
        strings[i] = string(stop)
        values = Any[_catalog_value(p, s) for (p, s) in zip(origin.entry.params, strings)]
        comp.origin[d] = merge(origin, (; code = _catalog_code(origin.entry, values), strings))
        haskey(comp.edits, d) && (comp.edits[d][i] = string(stop))
        return nothing
    end
    code = _stop_call_code(origin.code, stop)
    if isnothing(code)
        gui.status.text[] = "the switch of $(_label(gui, d)) is not saved: its code is no call of `Detector`"
        return nothing
    end
    comp.origin[d] = merge(origin, (; code))
    return nothing
end

_is_toggle(::CatalogToggle) = true
_is_toggle(_) = false

"""
    _stop_call_code(code, stop) -> Union{String, Nothing}

The `code` of a call `Detector(edge_length)` or `Detector(edge_length, stop)` (also qualified, e.g.
`BeamletOptics.Detector(…)`) with the second argument `stop`, or `nothing` for any other code.
"""
function _stop_call_code(code::AbstractString, stop::Bool)
    ex = try
        Meta.parse(code)
    catch
        return nothing
    end
    (ex isa Expr && ex.head === :call && _is_detector_name(ex.args[1])) || return nothing
    # the positional arguments, after the name and before keywords
    args = ex.args[2:end]
    any(a -> a isa Expr && a.head in (:parameters, :kw), args) && return nothing
    length(args) in (1, 2) || return nothing
    return string(Expr(:call, ex.args[1], args[1], stop))
end

_is_detector_name(f) = f === :Detector ||
    (f isa Expr && f.head === :. && f.args[end] == QuoteNode(:Detector))
