#=
Compact layout of `live_view(...; layout = :compact)`, see `CompactLayout`
=#

"""
    CompactLayout

Layout of `live_view(...; layout = :compact)`: the 3D view fills the window, the detector panels
(if any) are on its right, in `gui.fig[1, 2]`, where users may add their own axes (see
[`add_panel!`](@ref)). There are no rows below the 3D view: the tools, the status and the own
parts appear on demand in an overlay over the 3D view (see `_CompactOverlay` in `LiveOverlay.jl`):

- a help pill at the top left; a click on it or the key `h` shows the keys of the controls
- the tool rail, opened by the round button "⋯" at the bottom left: the tools of tracing and the
  display, the component menu, export, the tools of [`add_tool!`](@ref), and an entry per section
  of [`add_controls!`](@ref) and one for the `sliders`, which opens their widgets in a popover
  next to the rail
- the camera popover below the view cube, shown while the mouse is over the cube or the popover:
  home, fit, the views menu, save view and orthographic
- a toast at the bottom, which shows each new status text and the info label for a few seconds

The widgets are drawn in the colors of the `theme` tokens like the whole window and the cards.
"""
mutable struct CompactLayout <: AbstractLiveLayout
    # the color tokens of the `theme` kwarg, see `_APP_THEMES`
    const theme::NamedTuple
    # the grid of the detector panels in `fig[1, 2]` (`nothing` without panels), the place of
    # `add_panel!`, see `LiveCustom.jl`
    panels::Union{Nothing, GridLayout}
    # the overlay over the 3D view, a `_CompactOverlay` (defined in `LiveOverlay.jl`, which is
    # included after this file)
    overlay::Any
    CompactLayout(theme::NamedTuple) = new(theme, nothing, nothing)
end

"""`LiveView` with the compact layout, i.e. `live_view(...; layout = :compact)`."""
const CompactView = LiveView{CompactLayout}

# The colors of the theme; the 3D view fills the window, hence no padding around the figure
_figure(layout::CompactLayout, size) = Figure(; size, backgroundcolor = layout.theme.background,
    figure_padding = 0, _makie_theme(layout.theme)...)

# Width of the sliders in their popover next to the tool rail [px]
const _SLIDERS_WIDTH = 320

# Distance of the detector panels and the own panels from the edges of the window [px]
const _COMPACT_PANEL_PADDING = 12

function _build_layout(layout::CompactLayout, fig, spec)
    (; specs, slider_specs, labels, lighting, view_cube) = spec
    t = layout.theme
    ax = LScene(fig[1, 1]; show_axis = false, scenekw = (; clear = true, backgroundcolor = t.view))
    studio_lighting!(ax; preset = lighting)
    # Its click listener runs before the controls, hence clicks on the cube never select objects
    cube = view_cube ? view_cube!(ax) : nothing

    # Detector panels in a near-square grid next to the 3D view
    panels = Any[]
    if !isempty(specs)
        grid = GridLayout(fig[1, 2]; alignmode = Outside(_COMPACT_PANEL_PADDING))
        nc = ceil(Int, sqrt(length(specs)))
        for (i, (pd, mode, kw)) in enumerate(specs)
            parent = grid[(i - 1) ÷ nc + 1, (i - 1) % nc + 1]
            p = DetectorPanel(parent, pd, get(labels, pd, "Detector $i"), mode, kw)
            _theme_panel!(p, t)
            push!(panels, p)
        end
        colsize!(fig.layout, 1, Relative(0.6))
        layout.panels = grid
    end
    # Everything else is part of the overlay over the 3D view
    o = layout.overlay = _CompactOverlay(fig, ax, cube, t)
    sliders = isempty(slider_specs) ? nothing :
              SliderGrid(_add_section!(o, "Sliders"; sliders = true)[1, 1], first.(slider_specs)...;
                  width = _SLIDERS_WIDTH)
    status, info = _toast_labels!(o, "Click on a component to select it, press h to show the controls")
    tools = _build_tools(layout, spec)
    o.fit_button, o.views_button = tools.fit_button, tools.views_button
    _arrange_overlay!(o)
    return (; ax, cube, panels, sliders, status, info, tools...)
end

"""
The component menu in the tool rail ("select component"), the views menu in the camera popover
after its views icon, which opens it, like in the app layout.
"""
function _build_menus(layout::CompactLayout, _, options, views_options)
    o = layout.overlay
    menu = _rail_menu!(o, options)
    views_menu = Menu(o.camera_tools[1, _camera_column(:views) + 1]; options = views_options,
        default = nothing, prompt = "views", width = 84, _card_style(layout.theme, Menu)...,
        height = _OVERLAY_TOOL - 4, textpadding = (6, 4, 3, 3), dropdown_arrow_size = 8,
        valign = :center)
    on(_ -> (views_menu.is_open[] = !views_menu.is_open[]), o.views_button.clicks)
    _arrange_overlay!(o)
    return (; menu, views_menu)
end

# The compact layout also has the tools fit (the key `g`) and views, in its camera popover
_has_tool(::CompactLayout, ::Union{Val{:fit_button}, Val{:views_button}}) = true

"""
Connects the parts of the compact layout that are not fields of `LiveView`: the fit button, the
line of the controls next to the help pill (see `_compact_hint`) and the overlay, see
`_connect_overlay!`.
"""
function _connect_layout!(gui::CompactView)
    o = gui.layout.overlay
    ctrl = gui.controls
    push!(ctrl.listeners, on(_ -> _zoom_to_selection!(gui), o.fit_button.clicks))
    # The pill names the key `h`, the full help starts below it
    ctrl.help_hint = _compact_hint
    ctrl.help_top[] = _help_top(o)
    _update_help!(ctrl)
    _connect_overlay!(gui)
    return nothing
end

"""
The line of the controls of the compact layout while the help is hidden: none, since the help pill
names the key `h`, except in the spectator mode, see `_default_hint`.
"""
_compact_hint(ctrl) = ctrl.spectator[] ? "spectator mode, v: edit" : ""

_show_hint(::CompactView) = "choose it in the component menu of ⋯ to show it again"

#=
Tools: the built-in tools in the tool rail or the camera popover, the tools of `add_tool!` in the
rail below the built-in ones
=#

"""
The icons of the built-in tools of the tool rail in their order, see `_tool_widget`; the component
menu (`:search`) is added by `_build_menus`.
"""
const _RAIL_TOOLS = (:trace, :auto_trace, :sources, :clip_beams, :measure, :eye, :search, :export)

"""The icons of the tools of the camera popover in their order, the views menu after `:views`."""
const _CAMERA_TOOLS = (:home, :fit, :views, :save_view, :orthographic)

# The column of the tool with the `icon` in the camera popover; the views menu takes the one after
# the views icon
function _camera_column(icon::Symbol)
    i = findfirst(==(icon), _CAMERA_TOOLS)
    return i <= 3 ? i : i + 1
end

"""
    _tool_widget(layout::CompactLayout, group, toggle, label, icon, tooltip, active)

A tool of the compact layout. The built-in tools are placed by their `icon`: the camera tools (see
`_CAMERA_TOOLS`) as icon buttons with the `tooltip` in the camera popover, the others as entries
with the icon and the `label` in the tool rail, in the order of `_RAIL_TOOLS`. The tools of
[`add_tool!`](@ref) (group `:user`) are entries of the rail below the built-in ones.
"""
function _tool_widget(layout::CompactLayout, group::Symbol, toggle::Val, label, icon, tooltip,
        active::Bool)
    o = layout.overlay
    if group === :user
        item = _rail_item!(o, _rail_slot!(o, 1), toggle, label, icon, active)
        _on_overlay_changed!(o)
        return item
    end
    icon in _CAMERA_TOOLS &&
        return _camera_tool!(o, _camera_column(icon), toggle, icon, tooltip, active)
    i = findfirst(==(icon), _RAIL_TOOLS)
    isnothing(i) && return _slot_error(layout, "place for the tool \"$label\"")
    return _rail_item!(o, o.rail_tools[i, 1], toggle, uppercasefirst(label), icon, active)
end

#=
Panels below the detector panels in `fig[1, 2]`, controls as sections of the tool rail
=#

"""
Returns the grid of the panels in `fig[1, 2]` of the compact layout, created without detector
panels.
"""
_panel_grid!(gui::CompactView) = _panel_grid!(gui, gui.layout.panels)
_panel_grid!(::CompactView, grid::GridLayout) = grid
function _panel_grid!(gui::CompactView, ::Nothing)
    root = gui.fig.layout
    grid = gui.layout.panels = GridLayout(root[1, 2]; alignmode = Outside(_COMPACT_PANEL_PADDING))
    colsize!(root, 1, Relative(0.6))
    return grid
end

function _add_user_panel!(f, gui::CompactView, title::String, ::Bool)
    grid = _panel_grid!(gui)
    nrows, ncols = size(grid)
    # Below all panels, over all columns of their grid
    row = isempty(grid.content) ? 1 : nrows + 1
    box = GridLayout(grid[row, 1:ncols])
    Label(box[1, 1], title; font = :bold, halign = :left, tellwidth = false)
    layout = GridLayout(box[2, 1])
    rowgap!(box, 4)
    return _user_panel(f, title, layout)
end

# An entry of the tool rail per section of controls, which opens them in a popover next to the rail
_controls_slot!(gui::CompactView, title::String) = _add_section!(gui.layout.overlay, title)
_on_controls_added!(gui::CompactView) = _on_overlay_changed!(gui.layout.overlay)
