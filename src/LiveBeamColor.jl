#=
Color and opacity in which the beams of the live view are drawn, set on the page "Color" of the
cards of the sources. Display only: nothing is solved.
=#

# The entries of the menu of colors that are no fixed color: the color of the wavelength of each ray
# (see `BeamletOptics.wavelength_color`), the color of the rays of the layout, and any other color
const _COLOR_WAVELENGTH = "wavelength"
const _COLOR_LAYOUT = "layout"
const _COLOR_CUSTOM = "custom"

# The fixed colors of the menu, saturated and told apart on a light and on a dark background
const _COLOR_PRESETS = Pair{String, RGBf}[
    "red" => RGBf(0.9, 0.1, 0.1),
    "orange" => RGBf(1.0, 0.5, 0.0),
    "yellow" => RGBf(0.95, 0.8, 0.0),
    "green" => RGBf(0.1, 0.7, 0.2),
    "cyan" => RGBf(0.0, 0.75, 0.85),
    "blue" => RGBf(0.1, 0.3, 0.95),
    "violet" => RGBf(0.55, 0.2, 0.9),
    "magenta" => RGBf(0.9, 0.1, 0.8),
    "black" => RGBf(0.0, 0.0, 0.0),
    "white" => RGBf(1.0, 1.0, 1.0),
]

"""The options of the menu of colors: the wavelength, the layout, the fixed colors and "custom"."""
_color_options() = String[_COLOR_WAVELENGTH, _COLOR_LAYOUT, first.(_COLOR_PRESETS)..., _COLOR_CUSTOM]

# The cards of beams and beam groups have the page "Color"
_has_page(::_Source, ::Val{:color}) = true
_page_rows(src::_Source, ::Val{:color}) = _color_rows(src)

"""
    _by_wavelength(color) -> Bool

Returns `true` if the `color` of a beam, as a kwarg of `live_render!` or a render setting, is the
one of the wavelength of each ray: `:wavelength` or `(:wavelength, alpha)`.
"""
_by_wavelength(color::Symbol) = color === :wavelength
_by_wavelength(color::Tuple{Symbol, Real}) = first(color) === :wavelength
_by_wavelength(_) = false

"""
    _color_setting(gui, beam)

The color with which the `beam` of the `gui` is drawn, as it was given: the render setting `color`
of its render handle (of the first one, a beam can be part of several pairs), see
`BeamletOptics.render_settings`, e.g. `:wavelength`. For a beam that is not part of the pairs the
color of its kwargs, `nothing` without one.
"""
function _color_setting(gui::LiveView, beam)
    i = findfirst(p -> p.second === beam, gui.pairs)
    isnothing(i) && return get(get(gui.beams.kwargs, beam, (;)), :color, nothing)
    return get(render_settings(gui.beam_handles[i]), :color, nothing)
end

# The wavelength [m] of the first ray of the `beam`, `nothing` for a beam group without beams
_first_wavelength(beam) = BMO.wavelength(_first_ray(beam))
_first_wavelength(bg::BMO.AbstractBeamGroup) =
    isempty(BMO.beams(bg)) ? nothing : _first_wavelength(first(BMO.beams(bg)))

# The single color that the `color` of a beam is, `nothing` for anything else, e.g. several colors
function _single_color(color)
    c = try
        Makie.to_color(color)
    catch e
        e isa InterruptException && rethrow()
        return nothing
    end
    return c isa Makie.Colorant ? RGBf(c) : nothing
end

"""
    _beam_color(gui, beam) -> RGBf

The color in which the `beam` of the `gui` is drawn, see `_color_setting`. Of a beam that is drawn
in the colors of its wavelengths, the color of the wavelength of its first ray; the color of the
rays of the layout for a beam without a single color.
"""
function _beam_color(gui::LiveView, beam)
    setting = _color_setting(gui, beam)
    if _by_wavelength(setting)
        λ = _first_wavelength(beam)
        return isnothing(λ) ? RGBf(gui.layout.theme.rays) : RGBf(wavelength_color(λ)...)
    end
    c = isnothing(setting) ? nothing : _single_color(setting)
    return isnothing(c) ? RGBf(gui.layout.theme.rays) : c
end

# The color as it is kept and set: the mode of the wavelength as it is, else without opacity, which
# is the `alpha` of the plots, see `_set_beam_opacity!`
_color_value(color) = _by_wavelength(color) ? color : RGBf(Makie.to_color(color))

"""
    _set_beam_color!(gui, beam, color)

Draws the `beam` (a beam or beam group of the pairs) of the `gui` in the `color`: anything that
`Makie.to_color` turns into one color, or `:wavelength` for each ray in the color of its
wavelength. The color is a setting of its render handles, which keep their plots (see
`_render_settings!`), and is kept in its kwargs, with which the beam is rendered when it is added
again. Throws an `ArgumentError`, and changes nothing, for a beam whose color the handle does not
manage, e.g. one that was given several colors by its `beam_kwargs`. Display only: nothing is
solved, and beams that are dimmed as outdated stay dimmed.
"""
function _set_beam_color!(gui::LiveView, beam, color)
    new = (; color = _color_value(color))
    # First the handles, which refuse a color they do not manage: then nothing is changed
    _render_settings!(gui, beam; new...)
    gui.beams.kwargs[beam] = merge(get(gui.beams.kwargs, beam, (;)), new)
    gui.beams.overlay_kwargs[beam] = merge(get(gui.beams.overlay_kwargs, beam, (;)), new)
    return nothing
end

# The plots of the `beam` of the `gui` with an opacity: those of its render handles
function _alpha_plots(gui::LiveView, beam)
    return Any[plot for (p, h) in zip(gui.pairs, gui.beam_handles) if p.second === beam
               for plot in _beam_plots(h) if haskey(plot, :alpha)]
end

"""
    _beam_opacity(gui, beam) -> Float64

The opacity (0 to 1) in which the `beam` of the `gui` is drawn: the one set on its card or by its
`beam_kwargs` (`alpha`), otherwise the one of its plots, without the dimming of outdated beams.
"""
function _beam_opacity(gui::LiveView, beam)
    kw = get(gui.beams.kwargs, beam, (;))
    haskey(kw, :alpha) && return Float64(kw.alpha)
    plots = _alpha_plots(gui, beam)
    isempty(plots) && return 1.0
    plot = first(plots)
    return Float64(get(gui.trace.beam_alphas, plot, plot.alpha[]))
end

"""
    _set_beam_opacity!(gui, beam, opacity)

Draws the `beam` of the `gui` with the `opacity` (clamped to 0…1), e.g. to see the components
through the envelope of a Gaussian beamlet: the `alpha` of its plots and of its kwargs, with which
it is rendered again. Of beams that are dimmed as outdated (see `_dim_beams!`), the opacity is the
one that is restored after the next solve. Display only: nothing is solved.
"""
function _set_beam_opacity!(gui::LiveView, beam, opacity::Real)
    a = Float64(clamp(opacity, 0, 1))
    new = (; alpha = a)
    gui.beams.kwargs[beam] = merge(get(gui.beams.kwargs, beam, (;)), new)
    gui.beams.overlay_kwargs[beam] = merge(get(gui.beams.overlay_kwargs, beam, (;)), new)
    stale = gui.trace.beam_alphas
    for plot in _alpha_plots(gui, beam)
        haskey(stale, plot) ? (stale[plot] = a) : (plot.alpha[] ≈ a || (plot.alpha[] = a))
    end
    return nothing
end

# The plots of the `beam` of the `gui` with a line width: those of its render handles
function _linewidth_plots(gui::LiveView, beam)
    return Any[plot for (p, h) in zip(gui.pairs, gui.beam_handles) if p.second === beam
               for plot in _beam_plots(h) if haskey(plot, :linewidth)]
end

"""
    _beam_linewidth(gui, beam) -> Float64

The line width in which the `beam` of the `gui` is drawn: the one set on its card or by its
`beam_kwargs` (`linewidth`), otherwise the one of its plots; 1.0 for a beam without a plot with a
line width, e.g. the envelope of a Gaussian beamlet.
"""
function _beam_linewidth(gui::LiveView, beam)
    kw = get(gui.beams.kwargs, beam, (;))
    haskey(kw, :linewidth) && return Float64(kw.linewidth)
    plots = _linewidth_plots(gui, beam)
    isempty(plots) && return 1.0
    return Float64(first(plots).linewidth[])
end

"""
    _set_beam_linewidth!(gui, beam, width)

Draws the `beam` of the `gui` with the line `width`: the `linewidth` of its plots that have this
attribute and of its kwargs, with which it is rendered again. Display only: nothing is solved.
"""
function _set_beam_linewidth!(gui::LiveView, beam, width::Real)
    w = Float64(width)
    new = (; linewidth = w)
    gui.beams.kwargs[beam] = merge(get(gui.beams.kwargs, beam, (;)), new)
    gui.beams.overlay_kwargs[beam] = merge(get(gui.beams.overlay_kwargs, beam, (;)), new)
    for plot in _linewidth_plots(gui, beam)
        plot.linewidth[] ≈ w || (plot.linewidth[] = w)
    end
    return nothing
end

#=
The page "Color" of the card of a source
=#

"""The color `c` as `#rrggbb`."""
_color_hex(c) = (c = RGBf(c); "#" * join(string(round(Int, 255 * clamp(x, 0, 1)); base = 16, pad = 2)
                                         for x in (c.r, c.g, c.b)))

# Colors are the same on the card if they are shown as the same hex value
_same_color(a, b) = _color_hex(a) == _color_hex(b)

"""
The color of the entry `name` of the menu of colors for the `beam` of the `gui`: `:wavelength` for
"wavelength" (see `_wavelength_style`), `nothing` for "custom" and unknown names, see
`_color_options`.
"""
function _preset_color(gui::LiveView, beam, name::AbstractString)
    name == _COLOR_LAYOUT && return RGBf(gui.layout.theme.rays)
    name == _COLOR_WAVELENGTH && return get(_wavelength_style(beam), :color, nothing)
    i = findfirst(p -> first(p) == name, _COLOR_PRESETS)
    return isnothing(i) ? nothing : last(_COLOR_PRESETS[i])
end

"""
The entry of the menu of colors that the color of the `beam` of the `gui` is: "wavelength" exactly
if it is drawn in the colors of its wavelengths (see `_color_setting`), the entry of its single
color, else "custom", also for a beam without a single color.
"""
function _color_preset(gui::LiveView, beam)
    setting = _color_setting(gui, beam)
    _by_wavelength(setting) && return _COLOR_WAVELENGTH
    (isnothing(setting) || !isnothing(_single_color(setting))) || return _COLOR_CUSTOM
    c = _beam_color(gui, beam)
    for name in _color_options()
        name == _COLOR_WAVELENGTH && continue
        ref = _preset_color(gui, beam, name)
        isnothing(ref) || !_same_color(c, ref) || return name
    end
    return _COLOR_CUSTOM
end

# Sets the color of the `beam` from its card; a beam whose color can not be set (see
# `_set_beam_color!`) only shows the message of the error in the status line
function _try_set_beam_color!(gui::LiveView, beam, color)
    try
        _set_beam_color!(gui, beam, color)
    catch e
        e isa ArgumentError || rethrow()
        gui.status.text[] = "color not changed: $(first(split(sprint(showerror, e), '\n')))"
    end
    return nothing
end

# The menu of colors chose the entry `name`; "custom" keeps the color
function _apply_color_preset!(gui::LiveView, beam, name)
    c = name isa AbstractString ? _preset_color(gui, beam, name) : nothing
    isnothing(c) || _try_set_beam_color!(gui, beam, c)
    return nothing
end

"""
    _apply_color_input!(gui, beam, s)

Applies the input `s` of the box "hex" of the card of the `beam`: a color as `#rrggbb`, `rrggbb` or
a name that Makie knows, e.g. `orange`. Any other input only shows a message in the status line,
and so does a beam whose color can not be set, see `_set_beam_color!`.
"""
function _apply_color_input!(gui::LiveView, beam, s)
    text = isnothing(s) ? "" : String(strip(s))
    c = _parse_color(text)
    if isnothing(c)
        gui.status.text[] = "invalid color \"$text\", enter e.g. #ff8000 or a name like orange"
        return nothing
    end
    _try_set_beam_color!(gui, beam, c)
    return nothing
end

# The color of the `text`, `nothing` if it is none
function _parse_color(text::AbstractString)
    isempty(text) && return nothing
    occursin(r"^[0-9a-fA-F]{6}$", text) && (text = "#" * text)
    return try
        RGBf(Makie.to_color(text))
    catch e
        e isa InterruptException && rethrow()
        nothing
    end
end

_beam_opacity_percent(gui::LiveView, beam) = round(Int, 100 * _beam_opacity(gui, beam))

"""
    _color_rows(beam)

The rows of the page "Color" of the card of a beam or a beam group: the menu of colors (the colors
of its wavelengths, the color of the layout, fixed colors, see `_color_options`), the box of the
color as a hex value (of the wavelength of its first ray while it is drawn in the colors of its
wavelengths), the slider of the opacity and the slider of the line width.
"""
function _color_rows(_)
    label(text) = CardWidget(Label; text, width = 48, halign = :left)
    return (
        CardRow(label("color"), CardWidget(Menu; name = :color, options = _color_options(),
            width = 150, value = _color_preset, on = _apply_color_preset!)),
        CardRow(label("hex"), CardWidget(Textbox; name = :color_hex, placeholder = " ", width = 76,
            value = (gui, b) -> _color_hex(_beam_color(gui, b)), on = _apply_color_input!)),
        CardRow(label("opacity"),
            CardWidget(Slider; name = :beam_opacity, range = 0:100, width = 110,
                value = _beam_opacity_percent, on = (gui, b, v) -> _set_beam_opacity!(gui, b, v / 100)),
            CardWidget(Label; name = :beam_opacity_value, width = 40, halign = :right,
                value = (gui, b) -> "$(_beam_opacity_percent(gui, b)) %")),
        CardRow(label("width"),
            CardWidget(Slider; name = :beam_linewidth, range = 0.5:0.5:6, width = 110,
                value = _beam_linewidth, on = (gui, b, v) -> _set_beam_linewidth!(gui, b, v)),
            CardWidget(Label; name = :beam_linewidth_value, width = 40, halign = :right,
                value = (gui, b) -> string(round(_beam_linewidth(gui, b); digits = 1)))))
end
