#=
Layouts, see `AbstractLiveLayout`: the parts that do not depend on the layout, i.e. the theme, the
built-in tools and the info label
=#

"""
    _live_layout(layout::Symbol, theme::Symbol) -> AbstractLiveLayout

Returns the layout of the `layout` and `theme` kwargs of `live_view`, the only place where the
names are mapped to the layout types. The tokens of the `theme` color the whole window of all
layouts, see `_APP_THEMES`.
"""
function _live_layout(layout::Symbol, theme::Symbol)
    tokens = _app_theme(theme)
    layout == :compact && return CompactLayout(tokens)
    layout == :app && return AppLayout(tokens)
    throw(ArgumentError("layout must be :compact or :app, got :$layout"))
end

_default_size(::AbstractLiveLayout) = (1400, 800)
_figure(::AbstractLiveLayout, size) = Figure(; size)

# Optional parts of the layout interface, see `AbstractLiveLayout`
_connect_layout!(::LiveView) = nothing
_on_selected!(::LiveView) = nothing
_on_clipping!(::LiveView) = nothing
_on_clip_planes_changed!(::LiveView) = nothing
_on_hidden!(::LiveView) = nothing
_on_components_changed!(::LiveView) = nothing
# The detector panels of a layout are built with the view; panels of detectors that are added or
# removed at runtime are not shown yet
_add_detector_panel!(::LiveView, _) = nothing
_remove_detector_panel!(::LiveView, _) = nothing

_slot_error(gui::LiveView, what) = _slot_error(gui.layout, what)
function _slot_error(layout::AbstractLiveLayout, what)
    throw(ArgumentError("the $(nameof(typeof(layout))) of this live view has no $what"))
end
_add_toolbar_entry!(gui::LiveView, _) = _slot_error(gui, "toolbar")
_add_sidebar_section!(gui::LiveView, _, _) = _slot_error(gui, "sidebars")
_add_dock_panel!(gui::LiveView, _) = _slot_error(gui, "dock")

"""
    _step_box(layout, w, card) -> Textbox

The box of the keyboard step of the `layout` with the widgets `w` (see `_build_layout`): the step
box of the `card` of the selection by default, see `_ComponentCard`.
"""
_step_box(::AbstractLiveLayout, _, card) = card.step_box

#=
Collapsible parts, see `_LayoutPart`
=#

"""
    _LayoutPart

Collapsible part of a layout, e.g. a sidebar, the dock, the toolbar or the status bar of the app
layout or the panels of the compact layout: a background `box` and the `grid` of
its content, both placed at `pos` of the `parent` layout. `resize(size)` sets the size of its
column or row in the `parent`, which is `size` while the part is shown, see `_set_shown!`.
"""
mutable struct _LayoutPart
    parent::GridLayout
    pos::Tuple{Int, Int}
    resize::Function
    size::Any
    box::Box
    grid::GridLayout
    shown::Bool
end

"""Appends all blocks in the layout `x` to `out`, including the blocks of nested layouts."""
function _blocks!(out, gl::GridLayout)
    for c in gl.content
        _blocks!(out, c.content)
    end
    return out
end
_blocks!(out, b::Makie.Block) = push!(out, b)
function _blocks!(out, sg::SliderGrid)
    push!(out, sg)
    return _blocks!(out, sg.layout)
end

# Detached parts are laid out here, where they can not take mouse events
const _OFFSCREEN = Point2f(-1.0f5, -1.0f5)

"""
    _set_shown!(part::_LayoutPart, shown::Bool)

Shows or collapses the `part`. A collapsed part is removed from its parent layout, whose column
or row shrinks to zero, such that the 3D view takes the space. The only way to hide a part of a
layout: the sidebars and the dock by their toggles, all parts in the spectator mode (see
`_set_spectator_ui!`), the properties of a collapsed docked card. Since Makie keeps drawing, and
buttons keep reacting to clicks within their last bounding boxes, the blocks of the part are also
hidden and laid out off-screen. Its plots are kept, i.e. their state survives collapsing.
"""
function _set_shown!(part::_LayoutPart, shown::Bool)
    part.shown == shown && return nothing
    part.shown = shown
    blocks = _blocks!(Any[], part.grid)
    if shown
        part.parent[part.pos...] = part.box
        part.parent[part.pos...] = part.grid
        part.resize(part.size)
        Makie.unhide!(part.box)
        foreach(Makie.unhide!, blocks)
    else
        Makie.hide!(part.box)
        foreach(Makie.hide!, blocks)
        for x in (part.box, part.grid)
            _GLB.remove_from_gridlayout!(_GLB.gridcontent(x))
            w = GeometryBasics.widths(x.layoutobservables.computedbbox[])
            x.layoutobservables.suggestedbbox[] = Rect2f(_OFFSCREEN, w)
        end
        part.resize(Fixed(0))
    end
    return nothing
end

"""Hides the blocks of the collapsed `part`, e.g. those added to it since it was collapsed."""
function _hide_collapsed!(part::_LayoutPart)
    part.shown || foreach(Makie.hide!, _blocks!(Any[], part.grid))
    return nothing
end

#=
Spectator mode: only the 3D view, the help and the progress window are shown
=#

"""
    _set_spectator_ui!(gui, on::Bool)

Hides (`on`) or shows again the parts of the layout of the `gui` besides the 3D view and the help,
for the spectator mode, see `_on_spectator!`: the tools, the status, the sidebars and the panels.
Each part comes back as it was, e.g. a sidebar that was collapsed stays collapsed. Nothing by
default, see `AbstractLiveLayout`.
"""
_set_spectator_ui!(::LiveView, ::Bool) = nothing

"""
    _on_spectator!(gui, on::Bool)

Hides the UI of the `gui` when the spectator mode of its controls is switched `on` (the key `v`),
and shows it again when it is switched off: the parts that all layouts share, i.e. the view cube
(see `_set_visible!`), the floating cards (see `_update_cards!`), the markers of the sources (see
`_update_source_markers!`, they come back if their toggle is on), the selection card and open
menus, then the parts of the layout, see `_set_spectator_ui!`. The help pill with the chip of the
mode and the progress window of a running solve stay, such that the mode can be left and a long
trace cancelled.
"""
function _on_spectator!(gui::LiveView, on::Bool)
    if on
        _end_browse!(gui)
        for m in (gui.widgets.menu, gui.widgets.views_menu)
            (isnothing(m) || !m.is_open[]) || (m.is_open[] = false)
        end
    end
    _set_visible!(gui.widgets.view_cube, !on)
    _update_source_markers!(gui)
    _set_spectator_ui!(gui, on)
    _update_cards!(gui)
    _arrange_help!(gui)
    return nothing
end

"""
    _with_ui(f, gui)

Calls `f()` with all parts of the layout of the `gui` in the layout of the figure, and returns its
result: Makie can only add blocks to a part that is attached to the figure, not to a collapsed one
(see `_set_shown!`). In the spectator mode, the parts are shown for the call and hidden again, with
the new blocks; nothing is drawn in between. Used by [`add_panel!`](@ref), [`add_controls!`](@ref)
and [`add_tool!`](@ref), e.g. for a view that starts with `spectator = true`. A layout extends it
for parts that its users collapse, e.g. the left sidebar of the app layout.
"""
function _with_ui(f, gui::LiveView)
    hidden = gui.controls.spectator[]
    hidden && _set_spectator_ui!(gui, false)
    try
        return f()
    finally
        hidden && _set_spectator_ui!(gui, true)
    end
end

#=
Theme
=#

"""
Color tokens of the live view by `theme`, see `_live_layout`:

- chrome: `background` (figure, toolbar, status bar), `sidebar`, `view` (background of the 3D view
  and the detector panels), `border`, `text`, `muted` (secondary text), `accent` and `accent_soft`
  (active toggles), `field` (buttons and textboxes), `hover`, `tooltip` and `tooltip_text`
- `gizmo`: the red, green and blue axes of the controls, e.g. the labels of the rotations in the
  inspector, and the x (red) and z (blue) lines of the profiles and the centroid history of the
  detector panels
- 3D view: `help` (text of the controls), `rays` (rays and beams, see `_beam_style`),
  `clip_plane` (marker of a clip plane) and `clip_plane_icon` (its icon in the object tree),
  `marker_stroke` (outline of the handles of sources, clip planes and measured points),
  `gizmo_outline` (outline of the labels of the gizmo, `nothing` for none) and
  `materials`, the colors of material classes that replace the colors of the render look, e.g.
  of detectors, which are too dark on a dark background, see `_theme_render!`

The 3D view tokens of the light theme are the defaults of the rendering (e.g. the `color` of
`live_render!` of rays, the colors of the render look), i.e. `:light` draws the 3D view as before
the themes. The chrome tokens also color the floating component cards and the progress window, see
`_ComponentCard`.
"""
const _APP_THEMES = Dict{Symbol, NamedTuple}(
    :light => (;
        background = Makie.to_color("#eceef1"), sidebar = Makie.to_color("#f7f8fa"),
        view = Makie.to_color("#ffffff"), border = Makie.to_color("#d3d8de"),
        text = Makie.to_color("#1f2328"), muted = Makie.to_color("#69727d"),
        accent = Makie.to_color("#2f6fdb"), accent_soft = Makie.to_color("#d7e4fa"),
        field = Makie.to_color("#ffffff"), hover = Makie.to_color("#e2e6eb"),
        tooltip = _TOOLTIP_COLOR, tooltip_text = _TOOLTIP_TEXT_COLOR,
        gizmo = Makie.to_color.((:red, :green, :blue)),
        help = Makie.to_color(:gray40), rays = Makie.to_color(:blue),
        clip_plane = Makie.to_color(:purple), clip_plane_icon = Makie.to_color("#9b40c9"),
        marker_stroke = Makie.to_color(:black), gizmo_outline = nothing,
        materials = Dict{Symbol, RGBf}()),
    :dark => (;
        background = Makie.to_color("#1e2023"), sidebar = Makie.to_color("#25282c"),
        view = Makie.to_color("#34373b"), border = Makie.to_color("#3d4147"),
        text = Makie.to_color("#e3e5e8"), muted = Makie.to_color("#9aa1a9"),
        accent = Makie.to_color("#6ea4ff"), accent_soft = Makie.to_color("#2b4166"),
        field = Makie.to_color("#1a1c1f"), hover = Makie.to_color("#33373c"),
        tooltip = Makie.to_color("#e3e5e8"), tooltip_text = Makie.to_color("#1f2328"),
        gizmo = Makie.to_color.(("#ff6b6b", "#5ccf5c", "#6ea4ff")),
        help = Makie.to_color("#a4abb3"), rays = Makie.to_color("#5b9bff"),
        clip_plane = Makie.to_color("#b48ef0"), clip_plane_icon = Makie.to_color("#b48ef0"),
        marker_stroke = Makie.to_color("#d5d9de"), gizmo_outline = Makie.to_color("#e3e5e8"),
        materials = Dict{Symbol, RGBf}(:detector => Makie.to_color("#5d6673"),
            :polarizer => Makie.to_color("#56707d"))))

"""Returns the color tokens of the `theme`, see `_APP_THEMES`."""
function _app_theme(theme::Symbol)
    haskey(_APP_THEMES, theme) ||
        throw(ArgumentError("theme must be one of $(Tuple(sort!(collect(keys(_APP_THEMES))))), got :$theme"))
    return _APP_THEMES[theme]
end

"""Returns the Makie theme of the widgets of the live view with the color tokens `t`."""
function _makie_theme(t)
    return (;
        Label = (; color = t.text, fontsize = 13),
        Box = (; color = t.sidebar, strokecolor = t.border, strokewidth = 1),
        Button = (; buttoncolor = t.field, buttoncolor_hover = t.hover,
            buttoncolor_active = t.accent_soft, labelcolor = t.text, labelcolor_hover = t.text,
            labelcolor_active = t.text, strokecolor = t.border, strokewidth = 1, cornerradius = 4,
            fontsize = 13, padding = (8, 8, 5, 5)),
        Textbox = (; boxcolor = t.field, boxcolor_hover = t.field, boxcolor_focused = t.field,
            bordercolor = t.border, bordercolor_hover = t.accent, bordercolor_focused = t.accent,
            textcolor = t.text, textcolor_placeholder = t.muted, cursorcolor = t.accent,
            fontsize = 13, textpadding = (6, 6, 5, 5), cornerradius = 4),
        Menu = (; cell_color_inactive_even = t.field, cell_color_inactive_odd = t.field,
            cell_color_hover = t.hover, cell_color_active = t.accent_soft,
            selection_cell_color_inactive = t.field, textcolor = t.text, textcolor_hover = t.text,
            textcolor_active = t.text, dropdown_arrow_color = t.muted, fontsize = 13,
            textpadding = (8, 8, 5, 5)),
        Slider = (; color_inactive = t.border, color_active = t.accent,
            color_active_dimmed = t.accent_soft, linewidth = 6),
        Toggle = (; framecolor_inactive = t.muted, framecolor_active = t.accent,
            buttoncolor = :white),
        Axis = (; backgroundcolor = t.view, titlecolor = t.text, subtitlecolor = t.muted,
            xlabelcolor = t.text, ylabelcolor = t.text, xticklabelcolor = t.muted,
            yticklabelcolor = t.muted, xtickcolor = t.border, ytickcolor = t.border,
            xgridcolor = (t.muted, 0.15), ygridcolor = (t.muted, 0.15), bottomspinecolor = t.border,
            topspinecolor = t.border, leftspinecolor = t.border, rightspinecolor = t.border,
            titlesize = 14))
end

"""Keyword arguments of the icon buttons and toggles with the color tokens `t` of the theme."""
_icon_theme(t) = (; icon_color = t.text, hover_color = t.hover, active_color = t.accent_soft,
    active_icon_color = t.accent, tooltip_color = t.tooltip, tooltip_text_color = t.tooltip_text)

# Colors of the 3D view by the theme of the layout, see `_APP_THEMES`
_clip_plane_color(layout::AbstractLiveLayout) = layout.theme.clip_plane
_marker_stroke(layout::AbstractLiveLayout) = layout.theme.marker_stroke

"""
Default kwargs of `live_render!` of the source `beam` in the `layout`: the color of the rays of
sources that are drawn as lines, not the envelopes of Gaussian beamlets, which keep their color.
"""
_beam_style(::AbstractLiveLayout, _) = (;)
_beam_style(layout::AbstractLiveLayout, ::Union{BMO.AbstractRay, Beam, BMO.AbstractBeamGroup}) =
    (; color = layout.theme.rays)
_beam_style(::AbstractLiveLayout, ::BMO.AstigmaticBeamGroup) = (;)

"""
    _theme_render!(layout, h::AbstractSystemRenderHandle)

Replaces the colors of the material classes of the render look by the `materials` of the theme
of the `layout` (see `_APP_THEMES`) in the plots of all objects of `h`, e.g. the dark detectors of
the `:modern` look on a dark background. Only plots in the color of the look are changed, i.e. not
the colors given by the user via `system_kwargs`.
"""
function _theme_render!(layout::AbstractLiveLayout, h::AbstractSystemRenderHandle)
    materials = layout.theme.materials
    isempty(materials) && return nothing
    look = look_colors()
    replace = Dict{RGBf, RGBf}(look[class] => c for (class, c) in materials)
    for p in render_plots(h)
        haskey(p.attributes, :color) && _replace_color!(p, p.color[], replace)
    end
    return nothing
end

# Replaces a single color `c` of the plot `p` by its entry in `replace`, keeping its alpha;
# per-vertex colors, colormaps and the like are kept
function _replace_color!(p, c::Makie.Colors.Colorant, replace)
    new = get(replace, RGBf(c), nothing)
    isnothing(new) || (p.color[] = RGBAf(new, Makie.Colors.alpha(c)))
    return nothing
end
_replace_color!(_, _, _) = nothing

"""
Sets the colors of the overlays of the controls in the 3D view of the `gui` (see
`kinematic_controls!`) to the theme: the help text, drawn in the block scene of the 3D view, and
the outline of the labels of the gizmo, whose colors are the fixed colors of its axes.
"""
function _theme_controls!(gui::LiveView)
    foreach(p -> _theme_control!(gui, p), gui.controls.plots)
    return nothing
end

_theme_control!(::LiveView, _) = nothing
function _theme_control!(gui::LiveView, p::Makie.Text)
    t = gui.layout.theme
    p.parent === gui.ax.blockscene ? (p.color[] = t.help) : _outline_text!(p, t.gizmo_outline)
    return nothing
end

_outline_text!(_, ::Nothing) = nothing
function _outline_text!(p, color)
    p.strokecolor[] = color
    p.strokewidth[] = 1
    return nothing
end

#=
Built-in tools, declared once for all layouts
=#

"""
    _ToolSpec

A built-in tool of the live view, i.e. a button (with `clicks`) or a toggle (with `active`) that
the shared logic or the layout connects:

- `role`: the field of `_LayoutWidgets` it becomes (e.g. `:trace_button`), or of the layout for
  tools that only a layout has (e.g. `:fit_button` of `AppLayout`), see `_build_tools`
- `toggle`: a toggle, otherwise a button
- `icon`: its icon (see `_icon`), `label`: its text in layouts without icons, `tooltip`: its
  tooltip, which names its key
- `group`: the group of tools it belongs to, e.g. a group of the toolbar of the app layout, see
  `_tool_widget`
- `active`: the initial state of a toggle, `true`/`false` or the name of a field of the `spec` of
  `_build_layout` (e.g. `:auto_trace`) or a function of the `spec`
"""
struct _ToolSpec
    role::Symbol
    toggle::Bool
    icon::Symbol
    label::String
    tooltip::String
    group::Symbol
    active::Union{Bool, Symbol, Function}
end

_ToolSpec(role, toggle, icon, label, tooltip, group) =
    _ToolSpec(role, toggle, icon, label, tooltip, group, false)

"""
The built-in tools in their order, see `_ToolSpec`; a layout builds those of `_tools(layout)`.
The groups (`:trace`, `:objects`, `:camera`, `:display`, `:tools`, `:panels`) are placed by the
layout, see `_tool_widget`. The help of the controls has no tool: both layouts have a help pill, see
`_help_pill`.
"""
const _BUILTIN_TOOLS = (
    _ToolSpec(:trace_button, false, :trace, "Trace (t)", "Trace (t)", :trace),
    _ToolSpec(:auto_trace_toggle, true, :auto_trace, "auto trace", "Auto trace", :trace, :auto_trace),
    _ToolSpec(:show_all_button, false, :eye, "show all", "Show all", :objects),
    _ToolSpec(:home_button, false, :home, "home", "Home", :camera),
    _ToolSpec(:fit_button, false, :fit, "fit (g)", "Fit to selection (g)", :camera),
    _ToolSpec(:views_button, false, :views, "views", "Views", :camera),
    _ToolSpec(:save_view_button, false, :save_view, "save view", "Save view", :camera),
    _ToolSpec(:orthographic_toggle, true, :orthographic, "orthographic", "Orthographic", :display,
        :orthographic),
    _ToolSpec(:clip_toggle, true, :clip, "clipping (c)", "Clipping (c)", :display, true),
    _ToolSpec(:clip_beams_toggle, true, :clip_beams, "clip beams", "Clip beams", :display,
        :clip_beams),
    _ToolSpec(:sources_toggle, true, :sources, "sources (1)", "Source markers (1)", :display,
        :show_sources),
    _ToolSpec(:measure_toggle, true, :measure, "measure", "Measure", :tools),
    _ToolSpec(:export_button, false, :export, "Export", "Export changed poses", :tools),
    _ToolSpec(:collapse_left, true, :panel_left, "object tree", "Object tree", :panels, true),
    _ToolSpec(:collapse_right, true, :panel_right, "properties", "Properties", :panels, true),
    _ToolSpec(:collapse_dock, true, :panel_bottom, "analysis", "Analysis", :panels,
        spec -> !isempty(spec.specs)),
)

"""
    _has_tool(layout, ::Val{role}) -> Bool

Whether the `layout` has the built-in tool of the `role`, see `_tools`: by default the tools of
the shared logic, i.e. the fields of `_LayoutWidgets`.
"""
_has_tool(::AbstractLiveLayout, ::Val{R}) where {R} = R in fieldnames(_LayoutWidgets)

"""The built-in tools (`_ToolSpec`s) of the `layout` in their order, see `_has_tool`."""
_tools(layout::AbstractLiveLayout) = filter(s -> _has_tool(layout, Val(s.role)), _BUILTIN_TOOLS)

_initial_active(active::Bool, _) = active
_initial_active(field::Symbol, spec) = getfield(spec, field)
_initial_active(f::Function, spec) = f(spec)

"""
    _build_tools(layout, spec) -> NamedTuple

Creates the built-in tools of the `layout` (see `_tools`) via `_tool_widget`, like the tools of
[`add_tool!`](@ref), and returns them by role, e.g. `trace_button`. The toggles are initialized
from the `spec` of `_build_layout`.
"""
function _build_tools(layout::AbstractLiveLayout, spec)
    specs = _tools(layout)
    widgets = map(specs) do s
        _tool_widget(layout, s.group, Val(s.toggle), s.label, s.icon, s.tooltip,
            _initial_active(s.active, spec))
    end
    return NamedTuple{map(s -> s.role, specs)}(widgets)
end

"""
    _tool_widget(layout, group::Symbol, toggle::Val, label, icon, tooltip, active::Bool)

Creates a tool of the `layout` in the tool `group` (see `_BUILTIN_TOOLS`, `:user` for the tools of
[`add_tool!`](@ref)): a button (`Val(false)`, with `clicks`) or a toggle (`Val(true)`, with
`active`, initially `active`), shown with the `label` or the `icon` and the `tooltip`, which name
the key of the tool, if any. Throws for a layout without a place for tools.
"""
_tool_widget(layout::AbstractLiveLayout, _, ::Val, _, _, _, _) = _slot_error(layout, "place for tools")

"""
Returns the position of a new column right after the `block` in its `GridLayout`, e.g. for a menu
next to a tool; the columns after it move one to the right.
"""
function _column_after!(block)
    gc = _GLB.gridcontent(block)
    col = gc.span.cols.stop + 1
    grid = gc.parent
    col <= _GLB.ncols(grid) && _GLB.insertcols!(grid, col, 1)
    return grid[gc.span.rows, col]
end

#=
Info label: the last solve, the number of rays and the projection
=#

"""Returns the number of rays (or beams) of the source `beam`, see `_status_info`."""
_ray_count(beam::BMO.AbstractBeamGroup) = length(BMO.beams(beam))
_ray_count(_) = 1
# The rays of the beams of the `pairs` of the `gui` that are switched on, see `_set_beam_on!`
_on_ray_count(gui::LiveView, pairs) = sum(p -> _beam_on(gui, p.second) ? _ray_count(p.second) : 0, pairs; init = 0)

"""Formats the duration `s` [s] of a solve in ms."""
_ms_string(s) = s < 1e-3 ? "<1 ms" : "$(round(Int, 1e3 * s)) ms"

"""
Returns the text of the info label: last solve (or "not traced" before the first one, see
`auto_trace`), number of rays of the beams that are switched on, projection.
"""
function _status_info(gui::LiveView)
    n = _on_ray_count(gui, gui.pairs)
    traced = gui.trace.preview ? "preview in $(_ms_string(gui.trace.preview_time))" :
             gui.trace.solve_time > 0 ? "traced in $(_ms_string(gui.trace.solve_time))" : "not traced"
    projection = gui.widgets.orthographic_toggle.active[] ? "orthographic" : "perspective"
    return "$traced · $n $(n == 1 ? "ray" : "rays") · $projection"
end

function _set_text!(label::Label, s::String)
    label.text[] == s || (label.text[] = s)
    return nothing
end
_set_text!(::Nothing, _) = nothing

# The info label shows the last solve, e.g. the inspector of the app layout the hits of a detector
# after `_update_inspector!` of `_apply!`
_on_solved!(gui::LiveView) = _update_info!(gui)
# Also without a solve: at an untraced start and after a beam is switched, see `_set_beam_on!`
_update_info!(gui::LiveView) = _set_text!(gui.widgets.info, _status_info(gui))

"""
Connects the parts of the `gui` that all layouts share: the info label follows the projection,
the overlays of the controls take the theme. Called by `_connect_layout!` of the layouts.
"""
function _connect_theme!(gui::LiveView)
    push!(gui.controls.listeners, on(_ -> _on_solved!(gui), gui.widgets.orthographic_toggle.active))
    _theme_controls!(gui)
    return nothing
end
