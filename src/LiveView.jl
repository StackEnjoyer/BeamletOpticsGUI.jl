using Makie: Figure, Axis, Label, SliderGrid, GridLayout, Relative, colsize!, colgap!,
             autolimits!, limits!, Button, Toggle, Textbox, Menu, rowgap!
import InteractiveUtils

"""
    _SolveJob

A solve of the systems (or a computation of the detector views) of a `LiveView` in a background
task, see `_solve!` and `_run!`.

# Fields

- `task`: runs `_compute` and returns its result
- `done`: notified when `task` ends (or the wait of `_run!` times out)
- `sinks`: the progress outputs of `task`, see `BMO.ProgressSink`: one per source, then one per
  computed detector view
- `anchors`: the position of the progress window of each sink, i.e. of its source or detector
- `apply`: shows the result of `task` in the live view, called on the render task
- `obj`: the moved object, or `nothing`
- `timing`: the duration field of the live view (e.g. `:solve_time`) that a cancelled job updates
- `t0`: `time()` at the start
- `shown`: the loop whose progress window is shown, `(; k, t0, t, count)`: the index of its sink,
  its start and the time and count when its window appeared (`k = 0` before the first window)
"""
mutable struct _SolveJob
    task::Task
    done::Base.Event
    sinks::Vector{BMO.ProgressSink}
    anchors::Vector{Point3f}
    apply::Function
    obj::Any
    timing::Symbol
    t0::Float64
    shown::@NamedTuple{k::Int, t0::Float64, t::Float64, count::Int}
end

"""
    AbstractLiveLayout

Layout of a [`LiveView`](@ref), i.e. where its widgets are placed in the figure, see the
`layout` kwarg of [`live_view`](@ref). The logic of the live view (tracing, clipping, measuring,
camera, inspection) is shared by all layouts: it works on the observables of the widgets, e.g.
`clicks` of a button, `active` of a toggle and `stored_string` of a textbox, never on their type
or position. A layout `L` holds its own state (e.g. the slots of its sidebars) and is stored in
`gui.layout` of the `LiveView{L}`.

# Interface

A subtype `L <: AbstractLiveLayout` has the field `theme`, the color tokens of the `theme` kwarg
(see `_APP_THEMES`), in which the floating cards and the progress window are drawn in all layouts,
and implements

- `_build_layout(layout::L, fig, spec) -> NamedTuple`: creates the widgets in the `Figure` `fig`,
  which `_figure(layout, size)` created. `spec` holds the inputs of `live_view`: `slider_specs`,
  `labels`, `lighting`, `view_cube`, `auto_trace`, `clip_beams`, `orthographic`, `show_sources` and
  `view_specs`. The result has the fields
  - `ax`: the `LScene` of the 3D view, with `studio_lighting!` applied, and `cube`: its view cube
    or `nothing`
  - `sliders`: a `SliderGrid` of `spec.slider_specs` or `nothing`, `status`: the `Label` of the
    status line
  - the built-in tools by role, e.g. `trace_button` (anything with `clicks::Observable{Int}`) or
    `auto_trace_toggle` (anything with `active::Observable{Bool}`, initialized from `spec`), created
    by `_build_tools(layout, spec)`, see "Tools" below
  - `info`: the `Label` of the last solve, the number of rays and the projection, or `nothing`

  `live_view` collects the widgets in a `_LayoutWidgets`, whose typed fields reject a missing or
  wrong widget at construction.
- `_build_menus(layout::L, w, options, views_options) -> (; menu, views_menu)`: called with the
  result `w` of `_build_layout` once the movable objects are known; the component `menu` (a `Menu`
  with the `options`, or `nothing`) and the `views_menu` (a `Menu` with the `views_options`)

and optionally, with defaults for any layout,

- `_figure(layout::L, size)`: the `Figure`, and `_default_size(layout::L)`: its size unless given
- `_connect_layout!(gui::LiveView{L})`: connects the widgets that only the layout has, e.g.
  collapsing; its listeners belong in `gui.controls.listeners`; `_close_layout!(gui)` stops what
  runs besides them when the view is closed, e.g. timers
- where the controls of the selected object are shown, i.e. the widgets that
  [`card_actions`](@ref) and [`card_rows`](@ref) declare, built by the same code for any host (see
  `_AbstractCard`): by default on the floating card next to the object (`_ComponentCard`), which
  holds the step box. A layout that shows them elsewhere, e.g. the app layout on a card docked in
  its inspector (`_DockedCard`), returns `false` from `_selection_card_shown(gui)` and refreshes
  them in `_refresh_inspector!(gui; force)`, called with the cards (see `_update_inspector!`);
  `_step_box(layout, w, card)` returns its `Textbox` of the keyboard step, `_layout_boxes(gui)`
  the textboxes that take the keyboard (see `_typing`). Pinned cards float by default; a layout
  that shows them elsewhere, e.g. the app layout below its inspector, implements `_pin!(gui, obj)`,
  `_unpin!(gui, obj)` and `_is_pinned(gui, obj)`, see `_toggle_pin!`; if it also lets a pinned
  card float, `_float!(gui, obj)` and `_dock!(gui, obj)`, whose floating cards get the button that
  docks them (`_card_tools!(layout, c)`).
- `_outside_view(gui)`: `true` while the mouse is over a part of the layout whose clicks must not
  reach the controls of the 3D view, e.g. the sidebars of the app layout (none by default)
- `_layout_obstacles(gui) -> Vector{Rect2f}`: the rectangles [figure px] of the parts of the layout
  that lie over the 3D view and are shown, which the floating cards keep off besides the view cube,
  e.g. the overlay of the compact layout (none by default)
- `_over_layout(gui) -> Bool`: `true` while the mouse is over a part of the layout that lies over the
  3D view, whose presses and scrolling the camera must not get (`false` by default)
- `_set_spectator_ui!(gui, on)`: hides the parts of the layout besides the 3D view and the help in
  the spectator mode and shows them again as they were (nothing by default), see `_on_spectator!`;
  parts of the figure layout are collapsed as `_LayoutPart`s with `_set_shown!`, the one way to
  collapse a part. `_with_ui(f, gui)` attaches collapsed parts while blocks are added to them
- hooks called by the shared logic: `_on_solved!(gui)` after a solve is shown,
  `_on_selected!(gui)` after the selection changed, `_on_clipping!(gui)` after clipping was
  switched, `_on_clip_planes_changed!(gui)` after a clip plane was added or removed,
  `_on_hidden!(gui)` after objects were hidden or shown, `_on_pinned!(gui)` after a card was
  pinned or unpinned and `_on_components_changed!(gui)` after a component was added to or removed
  from a system, see [`add_component!`](@ref)
- the pages of the cards (see `_card_pages`), which every host of a card shows, and the detector
  views on the page "Results" (see `_DetectorView`): the views of the floating cards are known to
  the shared logic, a layout that shows views elsewhere, e.g. on its docked cards, returns them from
  `_layout_views(gui)`, since only shown views are computed after a solve (see `_shown_views`),
  calls `_redraw_views!(gui, pd)` and `_view_needed!(gui, pd)` when it shows one, and implements
  `_pin_view!(gui, pd; expanded)` if it docks the cards that start pinned
- `_show_hint(gui)`: how a hidden object is shown again, for the status line
- colors of the 3D view: by default from the tokens of the `theme` (see `LiveLayout.jl`),
  `_clip_plane_color(layout)`, `_marker_stroke(layout)` (the outline of the handles of sources,
  clip planes and measured points), `_beam_style(layout, beam)` (default kwargs of `live_render!`
  of a source) and `_theme_render!(layout, h)` for the rendered objects
- slots for additional parts: `_add_toolbar_entry!(gui, group)`, `_add_sidebar_section!(gui,
  side, title)` and `_add_dock_panel!(gui, title)`, which return the `GridPosition` or
  `GridLayout` to place widgets in, see `AppLayout`
- `_catalog_dock_slot!(gui, title)`: the place in which the component catalog is docked, e.g. a
  section of a sidebar; `nothing` by default, then the catalog is a window over the 3D view only,
  see `_CatalogWindow`
- the places of the public customization API (see `LiveCustom.jl`), without which it throws for
  the layout: `_add_user_panel!(f, gui, title, select)` for [`add_panel!`](@ref),
  `_controls_slot!(gui, title)` for [`add_controls!`](@ref) and `_tool_widget` (see "Tools")
  for [`add_tool!`](@ref). A layout that
  hides panels implements `_panel_shown(gui, p)` and `_mark_panel_stale!(gui, p)` and updates a
  stale panel once it is shown, see `_UserPanel`

# Tools

The built-in tools (buttons and toggles such as trace, clipping or export) are declared once in
`_BUILTIN_TOOLS` (see `_ToolSpec`). A layout implements `_tool_widget(layout, group, toggle::Val,
label, icon, tooltip, active)`, which creates a tool of a `group` in the place of the layout, e.g.
an entry of a tool rail or an icon in a toolbar; `_build_tools(layout, spec)` builds all tools
that `_has_tool(layout, Val(role))` selects (by default those with a field in `_LayoutWidgets`)
this way, and [`add_tool!`](@ref) its tools with the group `:user`.

The layouts of `live_view` are `CompactLayout` and `AppLayout`.
"""
abstract type AbstractLiveLayout end

"""
    _UserPanel

A panel added via [`add_panel!`](@ref): its `title`, the `layout` of its content and the
`update(gui)` returned by the builder (or `nothing`), which runs after each full solve while the
panel is shown, see `_update_user_panels!`. A layout that hides panels (the tabs of the app layout)
marks a hidden panel stale instead and updates it once it is shown, see `_mark_panel_stale!`.
"""
mutable struct _UserPanel
    const title::String
    const layout::GridLayout
    const update::Union{Nothing, Function}
    last_error::Union{Nothing, String}
end

"""
    _UserControls

Controls added via [`add_controls!`](@ref): their `title`, the `layout` of their widgets and the
`update(gui)` returned by the builder (or `nothing`), which runs once when they are added and after
each full solve, like the `update` of a `_UserPanel`, but never stale, since controls are always
shown.
"""
mutable struct _UserControls
    const title::String
    const layout::GridLayout
    const update::Union{Nothing, Function}
    last_error::Union{Nothing, String}
end

"""
    _UserParts()

The parts of a live view added via the customization API (see `LiveCustom.jl`): the `panels`
(`_UserPanel`s), the `controls` (`_UserControls`), the `boxes` (`Textbox`es) and `menus` of added
controls and panels, which take the keyboard like those of the layout (see `_typing`), and the
`keys` of added tools with their names, see [`add_tool!`](@ref).
"""
struct _UserParts
    panels::Vector{_UserPanel}
    controls::Vector{_UserControls}
    boxes::Vector{Textbox}
    menus::Vector{Menu}
    keys::Dict{Keyboard.Button, String}
end

_UserParts() = _UserParts(_UserPanel[], _UserControls[], Textbox[], Menu[], Dict{Keyboard.Button, String}())

"""
    _TraceState

Tracing of a `LiveView`: the systems are solved after each change if `auto[]` (the `active`
observable of the auto trace toggle) is `true`, otherwise only via the trace button, the key `t` or
by switching auto tracing on. `stale` is `true` if the beams and detector views do not match the
current poses of the objects; the alpha of the beam plots before dimming is stored in
`beam_alphas`. If solving takes longer than `budget` [s], the systems are solved once the movement
pauses for `idle_delay` [s] (`pending`, the moved `pending_obj`, the time of the `last_change`);
`solve_time`, `view_time` and `preview_time` are the durations of the last solve, computation of
the detector views and preview solve [s], `coarse` is `true` while the views show a preview on a
coarse grid.

While moving, beam groups are solved only for their rendered beams if `preview_enabled`; `preview`
is `true` from such a solve (of the moved `preview_obj`) until the full solve. A solve that takes
longer than `budget` continues in the background as `job`, the `progress` window shows its loops
after `progress_delay` [s]. The duration fields are named by `_SolveJob.timing`. `error` holds
the rows of the message of the last failed solve until a solve succeeds, see `_show_solve_error!`.
"""
Base.@kwdef mutable struct _TraceState
    auto::Observable{Bool}
    budget::Float64
    idle_delay::Float64
    preview_enabled::Bool
    progress::_ProgressOverlay
    progress_delay::Float64
    stale::Bool = false
    beam_alphas::IdDict{Any, Any} = IdDict{Any, Any}()
    solve_time::Float64 = 0.0
    view_time::Float64 = 0.0
    preview_time::Float64 = 0.0
    pending::Bool = false
    pending_obj::Any = nothing
    last_change::Float64 = 0.0
    coarse::Bool = false
    preview::Bool = false
    preview_obj::Any = nothing
    job::Union{Nothing, _SolveJob} = nothing
    error::Union{Nothing, Vector{Pair{String, String}}} = nothing
end

"""
    _ClipState

Clip planes of a `LiveView`: the `planes`, applied if `enabled`, to the beams as well if `beams`.
`size` is the edge length of the outline of new planes, fixed at construction, since the bounding
boxes of clipped plots only cover their visible part.
"""
Base.@kwdef mutable struct _ClipState
    planes::Vector{LiveClipPlane} = LiveClipPlane[]
    enabled::Bool = true
    size::Float64
    beams::Bool
end

"""
    _MeasureState

Beam inspection and measuring of a `LiveView`: the inspected point of a beam (see
`_inspect_beam`) and its marker `inspection_plot`; up to two measured `points` `(; point, obj)`,
the `result` `(; distance, angle)` and its `plots`.
"""
Base.@kwdef mutable struct _MeasureState
    inspection::Any = nothing
    inspection_plot::Union{Nothing, AbstractPlot} = nothing
    points::Vector{Any} = Any[]
    result::Any = nothing
    plots::Vector{AbstractPlot} = AbstractPlot[]
end

"""
    _CameraState

Camera tools of a `LiveView`: the `home` view `(eye, lookat, up)`, taken at the first tick
(`home_set`), the saved `views` and the running `animation` of a camera transition.
"""
Base.@kwdef mutable struct _CameraState
    home::NTuple{3, Vector{Float64}} = (zeros(3), zeros(3), zeros(3))
    home_set::Bool = false
    views::Vector{Pair{String, NTuple{3, Vector{Float64}}}}
    animation::Any = nothing
end

"""
    _CardState

Cards of a `LiveView`: the card of the `selection` next to the selected object, which shows the
rows and actions declared for it (see [`card_rows`](@ref)); `all` cards, including the pinned
ones; the listeners that keep the camera from the cards (`shield`, see `_shield_cards!`); the
selection card of groups (`browse`, a `_BrowseCard`, see `_browse!`), `nothing` until it is
connected.
"""
Base.@kwdef mutable struct _CardState
    selection::_ComponentCard
    all::Vector{_ComponentCard} = [selection]
    shield::Vector{Any} = Any[]
    browse::Any = nothing
end

"""
    _ObjectState

The objects of a `LiveView` as the selection shows them: the movable objects of the component
`menu` (the option `i` selects `menu[i]`), the `hidden` objects (rendered objects, i.e. leaves of
groups, whose plots are invisible, see the action "hide" of the cards), the `opacity` of objects
set via their card (see `_set_opacity!`), and the automatic `names` of objects without a label
with the `counters` of their running indices per type, see `_name_objects!`. `inspected` is shown
on the card of the selection, but not selected for moving: a system or an object that is not
movable, see `_inspect!`; it and `controls.selected[]` exclude each other. `parents` maps each part
of an object (an object of a group or of a `MultiShape` object, e.g. a lens of a doublet) to that
object, see `_map_parts!`; the top-level objects have no entry. `browsed` is the group or
`MultiShape` object whose parts the selection card shows, `nothing` while it is closed, see
`_browse!`.
"""
Base.@kwdef mutable struct _ObjectState
    menu::Vector{Any} = Any[]
    hidden::Base.IdSet{Any} = Base.IdSet{Any}()
    opacity::IdDict{Any, Any} = IdDict{Any, Any}()
    names::IdDict{Any, String} = IdDict{Any, String}()
    counters::Dict{String, Int} = Dict{String, Int}()
    inspected::Any = nothing
    parents::IdDict{Any, Any} = IdDict{Any, Any}()
    browsed::Any = nothing
end

"""
    _BeamState

The beams of a `LiveView` (the objects `last.(gui.pairs)`) as their cards switch them: the beams
that are `off`, i.e. neither traced nor drawn (see `_set_beam_on!`); per beam, the `kwargs` of
`live_render!` of its handle in `gui.beam_handles` besides the style of the layout, with which it
is rendered again for another length of its final rays (see `_set_flen!`); the handles of its
overlays, the polarization curve in `pol` (see `_set_polarization!`) and the generating beams of a
Gaussian beamlet in `gen` (see `_set_generating_beams!`), and the kwargs of `live_render!` of the
overlays in `overlay_kwargs`, taken from the `beam_kwargs` of `live_view` without `render_every`,
including the initial `show_polarization` and `show_beams`. `shown` holds per overlay handle the
plots that are visible while the beam is on, the others stay hidden; `pol_view` per beam the
values of the sliders of its polarization curve, see `_pol_view`. `marker_size` is the length [m] of
the arrow of the markers of the sources, also of those that are added later.
"""
Base.@kwdef struct _BeamState
    off::Base.IdSet{Any} = Base.IdSet{Any}()
    kwargs::IdDict{Any, NamedTuple} = IdDict{Any, NamedTuple}()
    pol::IdDict{Any, Any} = IdDict{Any, Any}()
    gen::IdDict{Any, Any} = IdDict{Any, Any}()
    overlay_kwargs::IdDict{Any, NamedTuple} = IdDict{Any, NamedTuple}()
    shown::IdDict{Any, Vector{Any}} = IdDict{Any, Vector{Any}}()
    pol_view::IdDict{Any, NamedTuple} = IdDict{Any, NamedTuple}()
    marker_size::Base.RefValue{Float64} = Ref(0.01)
end

"""
    _ComponentState

The components that were added to and removed from the systems of a `LiveView` at runtime, see
[`add_component!`](@ref) and [`remove_component!`](@ref): the `render_kwargs` of `live_render!` of
the systems, with which added components are rendered; the `catalog` of the view (see
[`component_catalog`](@ref)); the `added` components that are still part of a system and the
`removed` ones that the view started with, both in the order of the calls, with the `system` of
each; sources are added and removed like components, the `system` of an added one is the system it
is traced through, and a removed source of the start has its systems in `source_systems`; the
`origin` of an added component, `(; code, pose0)`: its constructor call as Julia code and
its pose as constructed, or `nothing` if it is not known (see `export_changes`); the component that
is being placed with the mouse in `placement`, `nothing` otherwise, see `_start_placement!`; the
`window` of the catalog with its dock (a `_CatalogWindow`), `nothing` for a view without a catalog.
"""
Base.@kwdef mutable struct _ComponentState
    const render_kwargs::NamedTuple
    const catalog::Vector{CatalogEntry}
    const added::Vector{Any} = Any[]
    const removed::Vector{Any} = Any[]
    const system::IdDict{Any, Any} = IdDict{Any, Any}()
    const origin::IdDict{Any, Any} = IdDict{Any, Any}()
    const source_systems::IdDict{Any, Vector{Any}} = IdDict{Any, Vector{Any}}()
    placement::Any = nothing
    window::Any = nothing
end

"""
    _DetectorState

The view of the detector `pd` of a `LiveView`, shared by all cards that show it (see
`LiveDetectors.jl`): its options `opts` (a `_ViewOptions`), the `result` of its last computation (a
`_ViewResult`, `nothing` before the first one) and whether it is `stale`, i.e. the hits of the
detector or the options changed since. `window_changed` is the time of the last zoom or pan of a
field view, whose recomputation waits until the mouse rests (`0.0` if none is pending), see
`_set_view!`.
"""
mutable struct _DetectorState
    const pd::BMO.Detector
    opts::Any
    result::Any
    stale::Bool
    window_changed::Float64
end

"""
    _DetectorStates

The detector views of a `LiveView`: the `states` per detector, created on demand (see
`_detector_state`); `hits_valid` is `true` while the hits of the detectors are those of a complete
solve, i.e. stale views can be computed from them; `start` holds the specs of the `detectors`
kwarg of [`live_view`](@ref), whose cards start pinned, see `_detector_specs`; `registered` the
views `(pd, view)` that are shown outside the cards and the layout, see `_register_view!`.
"""
Base.@kwdef mutable struct _DetectorStates
    states::IdDict{Any, _DetectorState} = IdDict{Any, _DetectorState}()
    hits_valid::Bool = false
    start::Vector{Any} = Any[]
    registered::Vector{Tuple{Any, Any}} = Tuple{Any, Any}[]
end

"""
    _LayoutWidgets

The widgets of a `LiveView` that its layout creates (see `_build_layout` and `_build_menus`) and
the shared logic uses. They are typed by what the logic uses, since the layouts use different
widgets: buttons have `clicks::Observable{Int}`, toggles `active::Observable{Bool}`.

- buttons: `trace_button`, `export_button` (see [`export_changes`](@ref)), `home_button`,
  `save_view_button`, `show_all_button` (or `nothing`)
- toggles: `auto_trace_toggle`, `clip_beams_toggle`, `orthographic_toggle`, `sources_toggle` (the
  markers of the movable sources, also the key `1`), `measure_toggle`
- `step_box`: the `Textbox` of the keyboard step (replaced when another card becomes the card of
  the selection, see `_use_card!`); `menu`: the component menu (or `nothing`),
  `views_menu`: the saved views; `view_cube`: the view cube of the 3D view (or `nothing`)
- `info`: the label of the last solve, the number of rays and the projection (or `nothing`)
"""
Base.@kwdef mutable struct _LayoutWidgets
    trace_button::Any
    auto_trace_toggle::Any
    clip_beams_toggle::Any
    orthographic_toggle::Any
    sources_toggle::Any
    measure_toggle::Any
    export_button::Any
    home_button::Any
    save_view_button::Any
    show_all_button::Any
    step_box::Textbox
    menu::Union{Nothing, Menu}
    views_menu::Menu
    view_cube::Union{Nothing, ViewCube}
    info::Union{Nothing, Label} = nothing
end

"""
    LiveView

Interactive window returned by [`live_view`](@ref). The `Figure` is stored in `fig`, the `LScene`
of the 3D view in `ax`, the `KinematicController` in `controls`, the `status` line and the
`sliders` (or `nothing`). Use `display` to show the window and `close` to
remove the controls and the view cube.

The state of the shared logic is grouped by concern: `trace` (`_TraceState`), `clip`
(`_ClipState`), `measure` (`_MeasureState`), `camera` (`_CameraState`), `cards` (`_CardState`),
`objects` (`_ObjectState`), `beams` (`_BeamState`), `detectors` (`_DetectorStates`) and `components`
(`_ComponentState`); the widgets that the layout creates are in `widgets`
(`_LayoutWidgets`). The export button prints the changed poses as Julia code, see
[`export_changes`](@ref), and copies them to the clipboard if `export_clipboard` is `true`. The
objects of the `extras` kwarg are rendered, selectable and movable, but not part of any system,
see `_live_render_extras!`. Panels, widgets and tool keys added via the customization API are in
`custom`, see `LiveCustom.jl`. `background_card` is the kwarg of [`live_view`](@ref): the object
(or `gui -> object`) whose card a click on the empty background shows, see `_show_background!`.

The type parameter `L` is the type of the `layout`, see `AbstractLiveLayout`: `CompactView` and
`AppView` are the `LiveView`s of `live_view(...; layout = :compact)` and `layout = :app`.
"""
Base.@kwdef mutable struct LiveView{L <: AbstractLiveLayout}
    fig::Figure
    ax::LScene
    pairs::Vector{Pair{BMO.AbstractSystem, Any}}
    system_handles::Vector{AbstractSystemRenderHandle}
    beam_handles::Vector{AbstractBeamRenderHandle}
    controls::KinematicController
    status::Label
    sliders::Union{Nothing, SliderGrid}
    on_change::Function
    last_error::Union{Nothing, String} = nothing
    labels::IdDict{Any, String}
    export_clipboard::Bool = true
    extras::LiveSystemHandle
    custom::_UserParts = _UserParts()
    trace::_TraceState
    clip::_ClipState
    measure::_MeasureState = _MeasureState()
    camera::_CameraState
    cards::_CardState
    objects::_ObjectState
    beams::_BeamState = _BeamState()
    detectors::_DetectorStates = _DetectorStates()
    components::_ComponentState
    background_card::Any = nothing
    widgets::_LayoutWidgets
    # state of the layout, e.g. the slots of the app layout, see `AbstractLiveLayout`
    layout::L
end

# Infers the layout type like the constructor of a non-parametric type
LiveView(fields...) = LiveView{typeof(last(fields))}(fields...)

"""
The systems of the `gui` in the order in which they are rendered: those of its pairs and those
without a source, see `live_view`.
"""
_systems(gui::LiveView) = BMO.AbstractSystem[rendered(h) for h in gui.system_handles]


"""
    display(gui::LiveView; screen_config...)

Displays the window of the `gui`. With GLMakie, the live view gets its own window, rendered without
SSAO and with up to 60 fps: SSAO (e.g. enabled globally via `GLMakie.activate!(ssao = true)`)
multiplies the frame time of a live view with large meshes, and GLMakie's default of 30 fps makes
rotating the view sluggish. The `screen_config` kwargs of the backend override these defaults.

A new window is used instead of reusing the current one, since GLMakie fails to reuse a window
whose screen configuration (e.g. `ssao`) and size both change ("Binding freed Texture").
"""
function Base.display(gui::LiveView; screen_config...)
    if _multi_light_backend() # i.e. GLMakie
        # A figure can only be shown in one screen: an open window of the gui is reused, unless new
        # screen settings are given
        old = Makie.getscreen(gui.fig.scene)
        if !isnothing(old) && isopen(old)
            isempty(screen_config) && return old
            close(old)
        end
        screen = Makie.current_backend().Screen(; ssao = false, framerate = 60.0, screen_config...)
        return display(screen, gui.fig)
    end
    return display(gui.fig; screen_config...)
end

function Base.show(io::IO, gui::LiveView)
    print(io, "LiveView(", length(gui.system_handles), " systems, ", length(_sources(gui)),
        " sources, ", length(_find_detectors(_systems(gui))), " detectors)")
end

function Base.close(gui::LiveView)
    _cancel_solve!(gui)
    _end_placement!(gui)
    _close_layout!(gui)
    close(gui.controls)
    isnothing(gui.widgets.view_cube) || close(gui.widgets.view_cube)
    foreach(_hide_card!, gui.cards.all)
    return nothing
end

"""Logs the error `e` of the `source` once per distinct message, returns the new last message."""
function _log_once(e, last_error, source::String)
    msg = sprint(showerror, e)
    if msg != last_error
        @error "live_view: $source failed" exception = (e, catch_backtrace())
    end
    return msg
end

# What `live_view` shows: a system with one of its sources, or a system without a source
const _ViewArg = Union{BMO.AbstractSystem, Pair{<:BMO.AbstractSystem}}
_view_system(sys::BMO.AbstractSystem) = sys
_view_system(p::Pair) = p.first

# The status line of a view without a source
const _NO_SOURCE = "no source, add one from the catalog or with add_component!"

"""
    live_view(system => beam, ...; kwargs...)
    live_view(system, beam; kwargs...)
    live_view(system, ...; kwargs...)

Opens a complete interactive window for one or several pairs of `system` and `beam`, or for systems
without a source, which get their sources at runtime (see "Adding and removing components"). All systems
and beams are live-rendered into the same `LScene`, see [`live_render!`](@ref), and can be moved
with the [`kinematic_controls!`](@ref). After each change, all `Detector`s are emptied, all systems
are solved again and the beams and the shown detector views are updated. Returns a `LiveView` with
the fields `fig`, `ax`, `controls`, `status` and `sliders`. Use `display(gui)` to show the window
and `close(gui)` to remove the controls.

Additional context, e.g. an optomechanical assembly from a CAD file, is passed via `extras`: these
objects are rendered, selected, moved, hidden and exported like the components, but they are not
part of any system, i.e. never traced and without cost in the solves; see "Extras and opacity".
Plots added via `render!(gui.ax, ...)` are only drawn. The status line shows the pose of the moved
object and its change since the window was opened.

# Component card, component menu and export

The selected object opens a card next to its bounding box in the 3D view, connected to it by a
line, which follows the camera and the object: right of the box, or left of, below or above it if
there is no room, always inside the view and never over the view cube or another card. It is
hidden without a selection and while a menu is open. "pin" in its head keeps the card with its
object, independent of the selection, e.g. to watch or type the poses of several objects; the
selection then gets a new card. "unpin" closes a pinned card. The head shows the label of the
object and its actions:

- "hide" makes the plots of the object invisible and clears the selection. On a hidden object
  selected in the menu, the button reads "show" and shows it again. Hidden objects can not be
  selected in the 3D view, but are still traced.
- For a clip plane, "flip" and "remove" instead, like `Shift+c` and `Delete`.

Below its head, a card has pages, chosen by a page bar: "Pose" with the rows of the object,
"Properties" with its properties (see [`properties`](@ref), the same rows as in the inspector of
the app layout) and, for a `Detector`, "Results" with its view between them, see "Detector view".
A card with a single page, e.g. of an inspected point, has no page bar. A card opens on "Results"
for a detector and on "Pose" for any other object; a pinned card keeps its page.

On "Pose", `x`, `y`, `z` [mm] show the position of the object, `Enter` in a box moves the object to the
typed absolute coordinate. `rx`, `ry` and `rv` [mrad] rotate the object about the red, green and
blue axis of the controls, like the keys in the rotate mode. Each input is recorded in the undo
history, invalid inputs are reported in the status line. The widgets of a pinned card act on its
object, also if another object is selected. The card of the selected object has, below its rows,
the `step` box of the keyboard step, e.g. `250 nm` or `50 µrad`, where the unit selects the move
or rotate mode (`pm`, `nm`, `µm`, `mm`, `cm` or `m`; `nrad`, `µrad`, `mrad`, `rad` or `deg`; the
step is shown in the unit of its size, e.g. `5 mm` or `1 cm`), and the "Move"/"Rotate" control, which shows and sets the mode of the controls (it
follows the key `m` and vice versa); a pinned card has them while its object is selected.
Pinning does not change the card. "–" in the
head collapses the card to its head, "+" expands it again. Clicks and drags on the card neither
select objects nor move the camera, and while a box of the card has the focus, the keys of the 3D
view are ignored. Further rows by type, see [`card_rows`](@ref): the number of rays of a source,
the signal of a `Detector` (the power or the number of rays of its view while one is shown,
otherwise the number of its hits) and the opacity of mechanics. The card, the menus and the
buttons take the colors of the `theme`.

Objects without a `labels` entry are named by their type and a running index, e.g. "Mirror 1" or
"Clip plane 2", in the card, the status line and the menus, like in the object tree of the app
layout. The rows of an own type are added by a method of [`card_rows`](@ref), see the page "Live
view widgets" of the documentation.

Beside the component cards, the card of a system shows the number of its objects, the number of
rays and the duration of the last solve. It is shown, without a gizmo and without a selection
(`controls.selected[]` stays `nothing`), by selecting the system entry ("System 1", ...) in the
component menu. An object that is not movable is shown on its card in the same way instead of
being selected, and its pose boxes reject inputs with a message in the status line. `Esc`, a click
on empty space or the selection of an object closes such a card.

In the compact layout, the tool rail (the button "⋯" at the bottom left) holds a menu of the systems
and all movable objects ("select component"; each system entry followed by its objects, the objects
of a group indented after the group, without clip planes), which selects an object like a click in
the 3D view, and "Show all", which shows all hidden objects. The info label, the duration of the
last solve (or of the preview), the number of rays and the projection, appears together with the
status line as a toast at the bottom of the 3D view for 3 s after each change.

The "Export" button of the tool rail prints the changed poses as Julia code to `stdout` and copies it to the
clipboard, see [`export_changes`](@ref).

# Selection card

A click in the 3D view on an object of a group opens a small menu under the cursor, like a context
menu: "Select <group>", which lies under the cursor, and "More ›". A second click without moving the
mouse thus selects the top-level group for moving (its card and the gizmo); nothing changes in the
3D view until then, except the box of the group while "Select" is marked, and a selection is kept.
"More ›" opens the selection card at the same place, which browses the parts one level at a time:
its first entry "Select <group>" selects the group itself, then "‹ <parent>" (except at the top
level) browses the enclosing object, then the
direct parts that are not hidden, those with parts of their own (a subgroup or a `MultiShape`
object, e.g. a `DoubletLens`, a `CubeBeamsplitter` or a `LinearPolarizer`) marked " ›". A part with
parts browses its parts, any other part is selected like by a click in the 3D view, or, if it can
not be moved on its own, e.g. a lens of a doublet, shown on its card without being selected for
moving, like an object that is not movable (its pose boxes reject inputs). While browsing, the group
is drawn see-through with a box around each part, the box of the part under the mouse highlighted;
nothing is selected. A click in the 3D view on a part acts like its entry, a click elsewhere closes
the card, `Esc` goes up one level and closes the card at the top level (and the small menu, which
keeps the selection). More than 5 parts scroll: 5 are shown, the mouse wheel over the card scrolls.
`↑`/`↓` move the mark over the entries, `Enter` chooses the marked one ("Select" of the small menu
if none is marked). A click on the card is ignored for 0.3 s after its entries changed, such that a
double click on "More ›" does not choose the part that appears under the cursor. A click inside the
current selection keeps it and opens no menu; the card of an object with parts has the button
"parts ›" in its head, which opens its selection card, and the card of a part has "‹", which
browses the object that it is a part of. A drag at the head of the small menu or of the selection
card moves it, e.g. off the parts that it covers; it stays there on the other levels until it is
closed. A click on an object that is not in a group shows its card
at once. A click on a pinned card beside its widgets selects its object.

# Background card

`background_card = sky` shows the card of an object without a place in the scene, e.g. the
environment of a telescope, after a click on the empty background of the 3D view (no component, no
beam, no drag) while nothing is selected and no card of an inspected object, beam point,
measurement or failed solve is shown; with a selection, the click only deselects as before, and
while measuring it shows no card. `background_card = gui -> obj` is evaluated at each such click,
e.g. to show the card only in some state of the view, and may return `nothing` for no card. The card
has the rows of [`card_rows`](@ref) of the object, whose `value(gui, obj)` and `on(gui, obj, v)` get
the object itself, the title of its `labels` entry (else its type) and no actions. It appears at the
click, where the ray through the mouse meets the plane through the `lookat` point of the camera
perpendicular to the view direction, and follows the view like the card of an inspected beam
point: `Esc` or another click closes it, its pin keeps it (docked in the app layout). The function
may return `obj => point` instead to attach the card to the `point` [m], e.g. where the ray through
the mouse (`Makie.ray_at_cursor`) meets a sky dome.

# Extras and opacity

`extras = [housing => (; color = :lightblue), mount]` adds objects without optical function, e.g.
a `MeshDummy` of an STL file, each an `AbstractObject` (or a group of them) with optional kwargs
of its [`render!`](@ref) call. They are not part of any system: never traced, moving them does not
solve the systems. Otherwise they act like the components: a click in the 3D view (where they do
not cover the components behind them, which are picked first) or in the component menu or object
tree selects them, they are moved with the controls if their kinematic trait allows it (static
ones are only rendered and hidden), hidden via "hide" or the eye of the tree, in which they are
listed under "Extras", and their moves are exported by [`export_changes`](@ref). An extra must not
be an object of a system.

The card of mechanics, i.e. a `NonInteractableObject` (e.g. `MeshDummy`) or an
`IntersectableObject`, in a system or among the extras, has an "opacity" slider (0-100 %,
initially the opacity as rendered, e.g. 5 % for a color with alpha 0.05). It scales the alpha of
the plots of the object, including its feature edges, and does not change the optics. Objects below
100 % are drawn with order independent transparency (`transparency = true`), opaque ones without
it, which is cheaper and keeps the correct depth; switching rebuilds the render objects of the
object once (a few ms for a mesh with 1 M triangles). At 0 % the object is hidden like via "hide",
a larger opacity shows it again. The opacity is kept while the object is hidden; showing an object
hidden at 0 % restores its initial opacity.

Mechanics below 50 % opacity (as rendered or set via the slider) are not selected by a click in
the 3D view: a click into the empty space inside or over a transparent housing selects what lies
behind it, e.g. a component, or clears the selection. Select them via the object tree or the
component menu instead. From 50 % on, a click selects them like any component.

# Beam inspection and measuring

A click on a rendered beam (within 6 px) that does not hit a component marks the point on the beam
and shows its position [mm], the direction of the beam, the geometric and optical path length
(Σ n·L) from the source [mm] and, for Gaussian beamlets, the radius `w` and the radius of curvature
`R` in the status line. Components take precedence over beams. `esc` or a click elsewhere removes
the marker.

With the "measure" toggle on, two clicks on components or beams show the distance between the
positions of the components or the points of the beams [mm], and the angle between the optical
axes (local y-axes) of two components, with a dashed line between the points. A third click starts
a new measurement, switching the toggle off clears it.

# Camera tools

The key `g` zooms to the selected object, or to all systems if nothing is selected, while the view
direction is kept. "home" restores the view when the window was shown. The "views" menu sets one
of the `views`, "save view" adds the current view as `"view n"` and prints it as an entry of the
`views` kwarg, e.g. `"view 1" => ([0.1, -0.2, 0.3], [0.0, 0.0, 0.0], [0.0, 0.0, 1.0])`. The view
is fitted to the scene when the window is shown and kept afterwards, also when plots are added,
e.g. the generating beams or the polarization curve of a beam, a clip plane or a measurement.

# Adaptive tracing

If solving the systems takes longer than `trace_budget`, the objects still follow the mouse and the
keys immediately, while the beams are dimmed. The systems are solved once the movement pauses for
`idle_delay`. Likewise, detector views that take longer than `trace_budget` show a preview on a
coarse grid while objects are moved, which is refined once the movement pauses.

With `preview = true`, beam groups rendered with `render_every > 1` are solved only for their
rendered beams while objects are moved, and the detector views are marked as a preview. The full
beam group is solved once the movement pauses for `idle_delay`. The
`trace_budget` applies to the preview solve while moving. `on_change` is only called after full
solves.

# Long solves

A solve, or the computation of the detector views, that takes longer than `progress_delay` runs
in the background: the camera can still be moved, the beams are dimmed and the status line shows
"tracing". The loops that show a progress bar in the terminal, i.e. the tracing of a beam group
and the field of a detector view, show a small progress window in the 3D view next to their source
or detector once they have run for `progress_delay`, with the remaining time and a button "Cancel",
connected to the source or detector by a line with a dot at its end, also when the window is kept
at the edge of the view because the source lies outside of it;
the terminal bar is not drawn meanwhile. The button, moving a component or a source and a slider
cancel the solve after the current beam, `t` is ignored until it is done. `Esc` does not cancel
it: it is the key of the groups, see "Selection card".

# Failed solves

If solving fails, also the initial solve, the error is logged, the beams stay dimmed and a card
"Solve failed" opens in the 3D view with the first line of the error. A detector hit by two kinds
of beams in one solve, e.g. polarized and unpolarized rays or rays and Gaussian beamlets, stores
only one kind: the card is placed at the detector and names it and both kinds, switching one of the
beams off (see [`beam_card_rows`](@ref)) or giving it its own detector solves it. `Esc`, a click in
the 3D view or the pin of the card closes it; the same error opens it again only after a solve
succeeded, which also closes it.

# Manual tracing

With `auto_trace = false`, the systems are not solved after each change, which is useful for
systems that take long to solve. Objects and sliders still update the 3D view, while the beams are
dimmed and the status line shows that they are outdated. The systems are solved by the
`Trace (t)` button of the tool rail (compact layout, opened by "⋯") or the toolbar (app layout), or
the key `t`. The "Auto trace" toggle next to it switches auto tracing on or off, switching it on solves the systems if they are outdated. The view also starts
untraced: the beams are dimmed and the status line shows "not traced, press t to trace" until the
first `t`, the button or switching auto tracing on solves the systems.

# Detector view

The page "Results" of the card of a `Detector` shows what it measured in the last solve. Which
views it offers follows from its hits; the first one is the default, a switch above the plot
selects another:

- rays: "Spot", the spot diagram, and "PSF", the intensity of the coherent sum of the rays, which
  BeamletOptics returns unscaled, hence normalized to its peak
- Gaussian beamlets: "Intensity" [W/m²] with the optical power, and "Spot", the 1/e² outlines of
  the beamlets

A kind that the hits do not offer falls back to their default and applies again once they offer it.
The plot has equal scales in mm, the y axis on its right and its ticks and labels inside its frame;
a red cross marks the centroid. Below it are the metrics: the number of hits, the centroid, the RMS
radius and the geometric radius of a spot diagram, or the power, the peak, the centroid and the
1/e² radii along x and z from the second moments of a field. "log" shows `log10` of a field with a
floor of 1e-4 times its maximum, "profiles" adds an axis with the field along x (red) and z (blue)
through the centroid.

The mouse acts like on an `Axis` of Makie: the wheel zooms about the cursor, a drag with the left
button selects the rectangle to zoom to (of the shape of the plot, i.e. a square in a square
plot), a drag with the right button pans, and Ctrl + click, a double click or "fit" resets the
view. A spot diagram only changes its limits. A field is computed again for the visible window on its full
grid once the mouse rests for `idle_delay`, not per step of the wheel; "fit" returns to the
automatic window around the beam, or to `x_min`, `x_max`, `z_min` and `z_max` if they are given.
One field costs about 14 ns per pixel and hit on one thread, i.e. it grows with `n²` times the
number of hits (`n = 100` and 1000 ray hits: about 150 ms); the computation uses all threads, start
Julia with `julia -t auto`.

The chevron of the view collapses it to a thumbnail with the kind, the power or the number of rays,
the centroid and the radii; a click on the thumbnail expands it again. A floating card with an
expanded view is resized by the grip at its bottom right corner. Only shown views are computed
after a solve, i.e. those on the page "Results" of the card of the selection and of the pinned
cards, a thumbnail on a grid of at most 48 points; a view that is shown later is computed from
the hits of the last solve. Pin the card of a detector to keep its view, or list the detector in
`detectors` to start with its card pinned.

The options of a view in the `kwargs` of `detectors`, which are not passed to `intensity`:

- `n = 100`: number of points per axis of a field
- `colorscale = :linear`: `:log` starts with "log" on
- `colorrange = nothing`: fixed color range of a field, in `log10` units for `:log`
- `profiles = false`: starts with "profiles" on
- `expanded = true`: `false` starts with the thumbnail

# Clip planes

Clip planes cut the 3D view open, e.g. to look into a housing. Only the side of a plane its normal
points to stays visible. The key `p` adds a plane through the selected object, or through the
`lookat` point of the camera if nothing is selected, with its normal along the view direction.
A plane is selected via the purple handle at its center and moved and rotated like a component,
its normal is the green axis. Moving a plane does not solve the systems. The keys apply as follows:

| key       | action                                   |
|:----------|:-----------------------------------------|
| `p`       | add a clip plane and select it           |
| `Delete`  | remove the selected clip plane (or the selected component, see "Adding and removing components") |
| `c`       | switch clipping on or off (all planes)   |
| `Shift+c` | flip the selected clip plane             |

Makie supports at most 8 clip planes. The markers of the sources and planes and the controls are
never clipped, the beams only with `clip_beams = true` or the "Clip beams" toggle of the
tool rail. The selection box of a partly clipped component only covers its visible part.

The key `g` zooms to the selection, see "Camera tools".

# App layout

With `layout = :app`, the same live view is arranged as an application window, all keys and mouse
actions in the 3D view are unchanged:

- toolbar (icons with tooltips): trace and auto trace, home, fit (`g`), views, save view,
  orthographic, clipping (`c`), clip beams, sources (`1`), measure, export, the toggles of the
  sidebars and the dock
- left sidebar: the object tree and, below it, the sliders ("Parameters") and the catalog
  ("Components", see "Adding and removing components"). The tree lists each
  system with its objects (groups with their objects, collapsed by default), then the `extras`
  under "Extras", the sources and the clip planes. A click on a name selects the object like a click in the 3D view, and a
  selection in the 3D view highlights its row. The eye hides or shows an object, a group or a
  whole system, the eye in the title of the tree shows all objects again. A click on the name of
  a system row shows the card of the system in the inspector, without selecting anything (the
  expander still folds the row); a click on an object that is not movable shows its card in the
  same way. Objects without a `labels` entry are named by their type and a running index, e.g.
  "Lens 2", also in the status line.
- right sidebar ("Properties"): the card of the selected object, docked instead of floating next
  to it: its name and type, the actions of the card (e.g. "hide", or "flip" and "remove" for a
  clip plane) and a pin, which pins a card to the object; below, the rows of the card (see
  [`card_rows`](@ref), e.g. the pose or the ray slider of a source) on the pages of the card, like
  on a floating card: "Pose" with the rows, the step box and the mode, "Results" with the view of
  a detector, "Properties" with the properties of the object (see [`properties`](@ref)); without a
  selection, a summary of the live view. The pinned cards are docked below, one below the other,
  each with its own head (icon, label, actions, float button, pin and chevron) and its pages. A
  detector view takes the width of the sidebar. The sidebar does not scroll: if the docked cards
  do not fit, the older ones collapse to their heads, then the property lists are shortened and the
  views shrink. The float button of a docked
  card moves it into the 3D view, where it floats next to its object like a pinned card of the
  compact layout; the dock button in its head moves it back to the end of the docked cards. A
  card keeps its collapsed state, its page and the state of its view when it moves; pinned again
  after it was unpinned, it starts docked.
- analysis dock below the 3D view: a tab per panel of [`add_panel!`](@ref), a click on a tab shows
  its panel; only the panel of the active tab is updated after a solve, the others when their tab
  is opened. Without such a panel the dock is collapsed.
- status bar: the status line and the duration of the last solve, the number of rays and the
  projection
- the help pill at the top left of the 3D view ("? h keys") with the chips of the mode and the
  keyboard step and the help card, like in the compact layout. They make room while the views menu
  is open.

The sidebars and the dock can be collapsed via the toolbar, the 3D view then takes their space.
The component menu of the compact layout is replaced by the tree.

# Compact layout

With `layout = :compact`, the 3D view fills the window; the panels of [`add_panel!`](@ref), if
any, are on its right, in `gui.fig[1, 2]`. There are no rows below the 3D view; everything else
appears on demand over the 3D view:

- a help pill at the top left ("? h keys"); a click on it or the key `h` opens the help card
  below it, which lists the keys and mouse actions in sections (select, move or rotate, edit, view,
  clip planes, trace, own tools), the keys as key caps; the 3D view stays usable while it is open.
  The chips right of the pill show the mode and the keyboard step; a click on the mode switches it
  (`m`), "+" and "−" change the step. In the spectator mode (`v`), a chip names it and its button
  leaves it. The spectator mode shows only the 3D view with this help: the tools, the status,
  the view cube, the cards with their detector views, the markers of the sources and the panels of
  [`add_panel!`](@ref) are hidden, in the app layout also the toolbar,
  the sidebars, the dock and the status bar, such that the 3D view fills the window. Only the
  progress window of a running trace stays, with its "Cancel". Leaving the mode shows everything
  as it was, e.g. a sidebar that was collapsed stays collapsed. A view can start in it with
  `spectator = true`.
- the button "⋯" at the bottom left opens the tool rail: Trace (`t`), Auto trace, Sources (`1`),
  Clip beams, Measure, Show all, the component menu ("select component"), Export, then the tools of
  [`add_tool!`](@ref), one entry per section of [`add_controls!`](@ref) and one entry "Sliders" for
  the `sliders`. Such an entry opens its widgets in a popover next to the rail. `Esc`, "⋯" or a
  click outside close the rail (`Esc` closes an open popover first).
- the mouse over the view cube shows the camera popover below it: home, fit (`g`), the views menu,
  save view and orthographic; it hides 0.3 s after the mouse left the cube and the popover
- the status line and the info label (last solve, rays, projection) appear as a toast at the bottom
  for 3 s after each change

The floating cards keep off the pill, the chips, the open help card, "⋯", the open rail and the
popovers.

# Own panels, controls and tools

[`add_panel!`](@ref) adds an own panel (right of the 3D view, or a tab of the dock of the app
layout), [`add_controls!`](@ref) own widgets (an entry of the tool rail that
opens them in a popover, or a section of the left sidebar) and [`add_tool!`](@ref) a button or
toggle, optionally with a key (an entry of the tool rail, or an icon in the toolbar). [`retrace!`](@ref) solves again after a change from code, e.g. from such a widget.
Widgets of a thing in the scene belong on its card, see [`card_rows`](@ref), own widget types on
cards and in controls use [`card_input`](@ref) and [`card_show!`](@ref).

# Adding and removing components

The components of a `System` of the view and its sources can be changed at runtime, e.g. to build
a setup from an empty `System()`, also without a source (`live_view(System())`); a `StaticSystem`
can not be changed. The catalog "Components"
offers the sources and components of the `catalog` kwarg, see [`component_catalog`](@ref): the icons at its top
select a group, e.g. the sources or the lenses, the tiles below an entry of the group, e.g. a doublet. The
boxes of the form take its numbers, e.g. the radii of a lens [mm], and a menu selects its glass
among those of [`catalog_glasses`](@ref) or "constant", for which a box takes a constant refractive
index. "Place" attaches the component to the mouse. An input that is no number, or that the
constructor of the component rejects, is reported in the status line. The line "into" names the
system that gets the component.

The catalog is a window over the 3D view with the head of a card. The key `Insert` opens it with
its top left corner at the mouse, as a popup: it closes when the component was dropped. Its pin
keeps it open at its place, and unpinning closes it. Its chevron minimizes it to its head, a drag
at its head moves it; it stays inside the 3D view. The toggle "Components" among the tools (tool
rail or toolbar) opens and closes the catalog.

- `layout = :compact`: the catalog is closed at first, and its window has a close button.
- `layout = :app`: the catalog is docked in the section "Components" of the left sidebar, below the
  object tree, and open at first; there its entries are icons, the one under the mouse is named
  below them. The buttons at the title of the section move it into its window over the 3D view
  (pinned) and minimize it. The window has a dock button instead of the close button, and closing
  it docks the catalog again; `Insert` shows it as a popup at the mouse, which is docked again
  after the drop. The sidebar does not scroll: in a low window, minimize the catalog or move it
  into its window.

The component then follows the mouse, drawn at half of its opacity, on the plane of the view
through the first source of its system (or the plane with the `plane_normal` of the controls), in
the orientation in which it was constructed: seen from above, it is placed at the height of the
beam. Within 12 px of a rendered beam it snaps onto the beam, with its optical axis (its
local y-axis as constructed) along the beam. Of a beam group, e.g. a `CollimatedSource`, it snaps
only onto the central beam, and of a Gaussian beamlet onto its chief ray. A left click drops it:
it becomes part of its system, i.e. the system of the selected or inspected object when "Place"
was pressed, else the first `System` of the view, all beams of that system are traced through it,
and it is selected. `Esc` cancels the placement. Meanwhile the component is not traced, a drag
still moves the camera, and a click selects nothing.

A source of the group "Sources" (a beam, a Gaussian beamlet, a collimated or a point source) is
placed by its marker in the same way. It does not snap onto beams and points along +y, as it is
constructed; turn it with the controls afterwards. Its beam is traced through the system that the
line "into" names, which may be a `StaticSystem`, once it is dropped. Placing a source shows the
markers of the sources if they were hidden.

The button "remove" below the rows of the card of a component or a source, or the key `Delete`
while it is selected, removes it: a component from its system, a source from the view, also the
last one. An object of a group and an extra can not be
removed: they are kept, and the status line names the reason. Removing is not part of the undo
history. From code, [`add_component!`](@ref) and [`remove_component!`](@ref) do the same.
[`export_changes`](@ref) lists the added components and sources, with their constructor calls, and
the removed ones. A `Detector` added at runtime shows its view on the page "Results" of its card like any other.

# Snapping onto beams

With the snapping switched on (the chip "Snap" next to the mode at the top left, the key `Tab`, or
the `snap` kwarg), a component that is dragged with the mouse snaps onto the beams like one that is
being placed. In the move mode, a component whose position comes within 12 px of a beam sits on the
beam and slides along it; of a beam group only the central beam takes part, of a Gaussian beamlet
its chief ray. `Tab` and a click on the chip switch to the next of three states, `Shift`+`Tab` to
the one before: off, the "position" only, such that e.g. a mirror keeps its tilt, and
"position + rotation", which also turns the optical axis (the local y-axis) along the beam; beside
the beams the component then has the orientation of the start of the drag again. The chip names the
state. In the rotate mode, the angle between the optical axis and the beam
through the component snaps to the multiples of 45° within 3°, e.g. a lens straight in the beam or
a mirror at 45°.

The beams are those at the start of the drag, without what lies behind the dragged component: it
snaps onto the beam that reaches it, continued as a straight line, and not onto the part that it
deflects itself. Locked axes (see `constraints`) stay locked. The keyboard steps do not snap, and
neither do sources and clip planes.

# Keyword args

- `layout = :compact`: arrangement of the widgets, `:compact` or `:app`, see "Compact layout" and "App layout"
- `theme = :light`: colors, `:light` or `:dark`, of the whole window (background, cards, buttons,
  menus, status line and progress window) in both layouts. For contrast on a dark 3D view, `:dark`
  draws the rays, the markers and the dark materials of the render look (detectors, polarizers) in
  lighter colors; `:light` keeps the colors of the default look.
- `size`: size of the figure, by default `(1400, 800)` for `:compact` and `(1600, 950)` for `:app`
- `auto_trace = true`: solves the systems at the start and after each change, otherwise only on
  request, see "Manual tracing"
- `detectors = :auto`: every `Detector` has the page "Results" on its card, no card is pinned at
  the start (also for `[]`). A vector of `pd`, `pd => kind` or `pd => (kind, kwargs)` pins the
  cards of these detectors at the start and sets the options of their views: `kind` is `:auto`,
  `:spot`, `:psf` or `:intensity`; `kwargs` holds the options of the view, e.g.
  `(; n = 200, colorscale = :log, expanded = false)`, all other entries are passed to `intensity`,
  e.g. `(; x_min = -1e-3, x_max = 1e-3, ...)`, see "Detector view". A listed detector that is not
  part of the systems throws an `ArgumentError`.
- `on_change = (gui, obj) -> nothing`: called after each full solve with the moved object, or
  `nothing` after a slider change, i.e. not after preview solves, see "Adaptive tracing"
- `sliders = []`: vector of `"label" => (range, callback)` or `"label" => (range, callback, startvalue)`.
  The `callback` is called with the new value, then the systems are solved again.
- `system_kwargs = (;)`: passed to `live_render!` of each system
- `extras = []`: objects that are rendered and can be moved and hidden, but are not traced, a
  vector of `obj` or `obj => render_kwargs`, e.g. `[housing => (; transparency = true, color =
  RGBAf(0.7, 0.8, 0.9, 0.05))]`, see "Extras and opacity"
- `beam_kwargs = Dict()`: `beam => kwargs` passed to `live_render!` of the beam, by default
  `(; render_every = 5)` for beam groups. `show_polarization = true` of a polarized beam and
  `show_beams = true` of a Gaussian beamlet start with the toggles "polarization" and "beams" of
  its card on, `pol_λ`, `pol_amplitude` and `pol_scale` set the start values of the sliders of
  the polarization curve, see [`beam_card_rows`](@ref); of a beam group only its central beam is
  drawn so. `show_polarization` for a beam without polarized rays and `show_beams` for one that is
  no Gaussian beamlet throw an `ArgumentError`.
- `beams_off = ()`: beams of the pairs that start switched off, i.e. neither traced nor drawn
  (their source markers stay), e.g. `[src]`. Each entry must be one of the beams of the pairs
  (`===`), otherwise an `ArgumentError` is thrown.
- `movable_sources = true`: shows an orange marker at each source, i.e. the beam or beam group of
  each pair, with which the source can be selected and moved like the components
- `show_sources = true`: initial visibility of the source markers, which can be switched with the
  "Sources" toggle of the tool rail or the key `1`
- `labels = Dict()`: `obj => "name"` for the status line, the cards, the component menu and the
  variable names of [`export_changes`](@ref)
- `trace_budget = 0.03`: [s] duration of a solve or of the computation of the detector views, above
  which tracing is deferred or the views show a preview, see "Adaptive tracing"
- `idle_delay = 0.2`: [s] pause of the movement after which deferred tracing runs
- `clip_planes = []`: initial clip planes, a vector of `point => normal`, e.g.
  `[[0, 0.1, 0] => [0, 1, 0]]`, see "Clip planes"
- `clip_beams = false`: clips the beams as well, can be switched with the "Clip beams" toggle
- `view_cube = true`: shows a view cube in the top right corner of the 3D view, a click on a
  face, edge or corner switches to the corresponding standard view, see [`view_cube!`](@ref)
- `orthographic = false`: starts the 3D view with orthographic instead of perspective projection,
  can be switched with the "orthographic" toggle of the camera popover
- `lighting = :studio`: lighting rig of the 3D view, see `BeamletOptics.studio_lighting!`, `:none`
  keeps the default lights of Makie
- `edges = nothing`: draws the feature edges of the components, by default depending on the look,
  see [`set_render_look`](@ref) and [`render!`](@ref). An `edges` entry of `system_kwargs` takes
  precedence.
- `preview = true`: solves beam groups only for their rendered beams while moving, see
  "Adaptive tracing"
- `views = []`: saved views of the "views" menu, a vector of `"name" => (eye, lookat, up)`, see
  "Camera tools"
- `progress_delay = 0.5`: [s] duration after which a solve continues in the background and a loop
  shows its progress window, see "Long solves"
- `background_card = nothing`: an object, or a function `gui -> object or nothing`, whose card a
  click on the empty background shows, see "Background card"
- `catalog = component_catalog()`: the components that the catalog "Components" offers, a vector of
  [`CatalogEntry`](@ref); an empty vector shows no catalog, see "Adding and removing components"
- `snap = false`: whether the components snap onto the beams while they are dragged with the mouse:
  `false`, `true` or `:position` (the position), or `:pose` (the position and the rotation), see
  "Snapping onto beams"
- all other kwargs are passed to [`kinematic_controls!`](@ref), e.g. `fine_step`, `plane_normal`
  or `rotation_axis`
"""
function live_view(
        args::_ViewArg...;
        size = nothing,
        layout::Symbol = :compact,
        theme::Symbol = :light,
        auto_trace::Bool = true,
        detectors = :auto,
        on_change = (gui, obj) -> nothing,
        sliders = [],
        system_kwargs = (;),
        beam_kwargs = Dict(),
        beams_off = (),
        movable_sources = true,
        show_sources::Bool = true,
        labels = Dict(),
        trace_budget = 0.03,
        idle_delay = 0.2,
        clip_planes = [],
        clip_beams::Bool = false,
        view_cube::Bool = true,
        orthographic::Bool = false,
        lighting::Symbol = :studio,
        edges::Union{Nothing, Bool} = nothing,
        preview::Bool = true,
        views = [],
        progress_delay::Real = 0.5,
        extras = [],
        background_card = nothing,
        catalog = component_catalog(),
        snap::Union{Bool, Symbol} = false,
        kwargs...
    )
    isempty(args) &&
        throw(ArgumentError("live_view requires at least one system or system => beam pair"))
    ps = Pair{BMO.AbstractSystem, Any}[p for p in args if p isa Pair]
    for b in beams_off
        any(p -> p.second === b, ps) ||
            throw(ArgumentError("beams_off: $(typeof(b)) is not a beam of the pairs"))
    end
    # Checked before the window is built, see `_init_overlays!`
    for (b, kw) in beam_kwargs
        get(kw, :show_polarization, false) === true && !_polarizable(b) &&
            throw(ArgumentError("beam_kwargs: show_polarization = true for $(typeof(b)), which has no polarized rays"))
        get(kw, :show_beams, false) === true && !_has_generating_beams(b) &&
            throw(ArgumentError("beam_kwargs: show_beams = true for $(typeof(b)), which is no Gaussian beamlet"))
    end
    # several beams may share a system, which is rendered once; a system without a source gets
    # its sources at runtime, see `add_component!`
    systems = unique(objectid, BMO.AbstractSystem[_view_system(a) for a in args])
    extra_specs = _extra_specs(extras, systems)
    detector_specs = _detector_specs(detectors, systems)
    slider_specs = [_slider_spec(s) for s in sliders]
    clip_specs = _clip_plane_specs(clip_planes)
    view_specs = _view_specs(views)

    lay = _live_layout(layout, theme)
    fig = _figure(lay, something(size, _default_size(lay)))
    w = _build_layout(lay, fig, (; slider_specs, labels, lighting, view_cube, auto_trace,
        clip_beams, orthographic, show_sources, view_specs))
    ax = w.ax
    # Pose, keyboard step and hide button of the selected object, next to it in the 3D view
    card = _ComponentCard(fig, lay, _card_z(1))

    # `edges` is only passed if given, i.e. custom `render!` methods of user objects do not need to
    # accept it
    sys_kw = isnothing(edges) ? system_kwargs : (; edges, system_kwargs...)
    system_handles = AbstractSystemRenderHandle[live_render!(ax, sys; sys_kw...) for sys in systems]
    beam_handles = AbstractBeamRenderHandle[]
    beam_state = _BeamState()
    for beam in last.(ps)
        default = beam isa BMO.AbstractBeamGroup ? (; render_every = 5) : (;)
        kw = (; get(beam_kwargs, beam, default)...)
        # The polarization and the generating beams are drawn by overlays of the beam, whose
        # initial states `show_polarization` and `show_beams` are kept with the kwargs of the
        # overlays, see `_BeamState`
        beam_state.overlay_kwargs[beam] = Base.structdiff(kw, NamedTuple{(:render_every,)})
        beam_state.kwargs[beam] = Base.structdiff(kw, NamedTuple{(:show_polarization, :show_beams)})
        push!(beam_handles, _live_render_beam!(ax, lay, beam, beam_state.kwargs[beam]))
    end

    # The extras are moved and selected like the objects of the systems, but never traced
    extras_handle = _live_render_extras!(ax, extra_specs)
    # Size of the scene (the systems and the visible extras), before any clip plane shrinks the
    # bounding boxes
    extent = _scene_extent((system_handles..., extras_handle))
    markers = AbstractObjectRenderHandle[]
    # Markers of the sources, scaled to the size of the systems, also of the sources that are
    # added at runtime
    marker_size = beam_state.marker_size[] = 0.08 * extent
    if movable_sources
        for src in unique(objectid, last.(ps))
            BMO.is_static(src) || push!(markers,
                _live_render_source!(ax, src; size = marker_size, strokecolor = _marker_stroke(lay)))
        end
    end
    # A single controller for all systems, otherwise several controllers would compete for events,
    # hence one handle of the objects of all systems, the source markers and the extras; the clip
    # planes are added later
    combined = LiveSystemHandle(first(systems), AbstractObjectRenderHandle[
            (c for h in system_handles for c in render_children(h))..., markers...,
            render_children(extras_handle)...],
        AbstractSystemRenderHandle[system_handles..., extras_handle])
    # Colors of the render look that the theme of the layout replaces, e.g. of dark detectors
    _theme_render!(lay, combined)
    gui_ref = Ref{LiveView}()
    # Moving a clip plane or an extra does not solve the systems, see `_on_moved!`
    change = function (obj)
        gui = gui_ref[]
        _on_moved!(gui, obj)
        _update_inspector!(gui)
        return nothing
    end
    # Typing into a textbox or the search of the component menu must not trigger the controls
    controls = kinematic_controls!(ax, combined; on_change = change,
        ignore_keys = () -> isassigned(gui_ref) && _typing(gui_ref[]), kwargs...)

    labels_dict = IdDict{Any, String}(labels)
    entries = _menu_entries(controls)
    menus = _build_menus(lay, w, _menu_options(labels_dict, entries), _views_options(view_specs))
    widgets = _LayoutWidgets(; w.trace_button, w.auto_trace_toggle, w.clip_beams_toggle,
        w.orthographic_toggle, w.sources_toggle, w.measure_toggle, w.export_button, w.home_button,
        w.save_view_button, w.show_all_button, step_box = _step_box(lay, w, card), menus.menu,
        menus.views_menu, view_cube = w.cube, w.info)
    trace = _TraceState(; auto = w.auto_trace_toggle.active, budget = trace_budget, idle_delay,
        preview_enabled = preview, progress = _ProgressOverlay(ax, lay.theme), progress_delay)
    gui = LiveView(; fig, ax, pairs = ps, system_handles, beam_handles, controls,
        w.status, w.sliders, on_change, labels = labels_dict, extras = extras_handle, trace,
        clip = _ClipState(; size = 1.2 * extent, beams = clip_beams),
        camera = _CameraState(; views = view_specs), cards = _CardState(; selection = card),
        objects = _ObjectState(; menu = Any[first.(entries)...]), beams = beam_state,
        components = _ComponentState(; render_kwargs = (; sys_kw...),
            catalog = CatalogEntry[catalog...]),
        background_card, widgets, layout = lay)
    gui_ref[] = gui
    # Names of the objects without a label, e.g. for the object tree, see `_name_objects!`
    _name_objects!(gui)
    # The parents of the parts of groups and multi-shape objects, for the selection card
    _map_parts!(gui)
    # Objects must not change while a solve in the background traces them
    controls.before_change = () -> _cancel_solve!(gui)
    for (point, normal) in clip_specs
        _add_clip_plane!(gui, point, normal; select = false)
    end
    isnothing(gui.sliders) || _connect_sliders!(gui, last.(slider_specs))
    _connect_trace!(gui)
    _connect_clip_planes!(gui)
    _connect_tools!(gui)
    _connect_inspection!(gui)
    _connect_camera!(gui)
    _connect_cards!(gui)
    # The selection card of groups, see `_browse!`
    _connect_browse!(gui)
    push!(controls.listeners, on(v -> v == gui.clip.beams || _set_clip_beams!(gui, v),
        gui.widgets.clip_beams_toggle.active))
    _connect_projection!(gui, orthographic)
    _connect_sources!(gui)
    _connect_layout!(gui)
    # The catalog of components that can be added to the systems, see `add_component!`, and their
    # placement with the mouse
    _build_catalog!(gui)
    _connect_placement!(gui)
    # The components snap onto the beams while they are dragged, see the `snap` kwarg
    _connect_snap!(gui)
    _set_snap!(controls, snap)
    # The info label and the colors of the controls, shared by all layouts
    _connect_theme!(gui)
    # The cards of the detectors of the `detectors` kwarg start pinned, before the initial solve,
    # which computes their views
    _init_detectors!(gui, detector_specs)
    _pin_detectors!(gui)
    # The spectator mode hides the UI, also at a start with `spectator = true`
    push!(controls.listeners, on(v -> _on_spectator!(gui, v), controls.spectator))
    controls.spectator[] && _on_spectator!(gui, true)
    # Before the initial solve, such that they are never traced
    foreach(b -> _set_beam_off!(gui, b), beams_off)
    if gui.trace.auto[]
        # A failed solve opens the window anyway, with its message, see `_fail!`
        try
            _resolve!(gui, nothing)
        catch e
            _fail!(gui, e)
        end
    else
        # Traced on request, see "Manual tracing"
        _mark_stale!(gui, nothing; msg = _NOT_TRACED)
        _update_info!(gui)
    end
    isempty(ps) && (gui.status.text[] = _NO_SOURCE)
    # The overlays of the beams with `show_polarization` or `show_beams`, after the solve they show
    _init_overlays!(gui)
    # Initial view from the Front-Right-Top corner, in which the labels of the view cube read
    # correctly. Only set once, later changes of the view, e.g. via `set_view`, are kept.
    cam = cameracontrols(ax.scene)
    lookat = Vector{Float64}(cam.lookat[])
    dist = norm(Vector{Float64}(cam.eyeposition[]) .- lookat)
    o, up = _region_view((1, -1, 1))
    set_view(ax, lookat .+ dist .* o, lookat, up)
    # Replaced by the view at the first tick, i.e. when the window is shown
    gui.camera.home = _current_view(gui)
    return gui
end

live_view(system::BMO.AbstractSystem, beam; kwargs...) = live_view(system => beam; kwargs...)
# Several systems, the first one without a source: not a system and its beam
live_view(system::BMO.AbstractSystem, arg::_ViewArg, args::_ViewArg...; kwargs...) =
    invoke(live_view, Tuple{Vararg{_ViewArg}}, system, arg, args...; kwargs...)
