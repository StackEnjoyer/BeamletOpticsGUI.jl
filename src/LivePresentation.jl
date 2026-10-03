#=
The presentation mode: only the 3D view, for screenshots and videos, and the recording of a live view
=#

"""
    presentation!(gui::LiveView, on::Bool = true; background = nothing, cards = false, view_cube = false)

Switches the presentation mode of the [`live_view`](@ref) window `gui` on or off: only the 3D view
stays, for screenshots and videos. The tools (the button "⋯" and the tool rail of the compact layout,
the toolbar and the sidebars of the app layout), the status line, the info label, the help (pill,
chips and card), the floating cards, the view cube, the markers of the sources, the selection box and
the gizmo are hidden, and nothing can be selected, i.e. the spectator mode is on (see
[`spectator!`](@ref)) and the help is hidden as well. The 3D view fills the window. The camera
works as usual, and objects can still be moved from code, see
[`translate3d!(::BeamletOpticsGUI.LiveView, ::Any, ::AbstractVector)`](@ref).

Switching it off restores what was before: the spectator mode, the selection (if it is still in the
view), the colors of the background and the parts of the window as they were, e.g. a sidebar that
was collapsed stays collapsed. The key `v` also leaves the presentation mode.

# Keyword arguments

- `background = nothing`: the color of the background of the 3D view and the window, e.g.
  `:black` or `RGBf(0.1, 0.1, 0.12)` (anything `Makie.to_color` accepts), by default the one of the
  theme
- `cards = false`: keep the pinned cards, e.g. of the detectors of the `detectors` kwarg of
  `live_view`: floating in the 3D view with `layout = :compact`, in the inspector sidebar (which
  stays) with `layout = :app`
- `view_cube = false`: keep the view cube

Calling it again with `on = true` applies the new keyword arguments, relative to the state before
the first call. Use [`Makie.record`](@ref) with a `gui` to record a video of the presentation mode.

```julia
presentation!(gui; background = :black)
wait_solve(gui)
save("setup.png", gui.fig; px_per_unit = 2)
presentation!(gui, false)
```
"""
function presentation!(gui::LiveView, on::Bool = true; background = nothing,
        cards::Bool = false, view_cube::Bool = false)
    p = gui.presentation
    ctrl = gui.controls
    if on
        # Applies the new options to the state from before
        p.on && presentation!(gui, false)
        p.saved = (; spectator = ctrl.spectator[], selected = ctrl.selected[],
            ax_background = gui.ax.scene.backgroundcolor[],
            fig_background = gui.fig.scene.backgroundcolor[])
        p.on, p.cards, p.view_cube = true, cards, view_cube
        if !isnothing(background)
            color = Makie.to_color(background)
            gui.ax.scene.backgroundcolor[] = color
            gui.fig.scene.backgroundcolor[] = color
        end
        # Hides the parts of the window, see `_on_spectator!`; if it is on already, they are again
        ctrl.spectator[] ? _on_spectator!(gui, true) : spectator!(gui, true)
    elseif p.on
        saved = p.saved
        _restore_presentation!(gui)
        # The parts of the window of the presentation mode come back as the spectator mode says
        saved.spectator ? _on_spectator!(gui, true) : spectator!(gui, false)
        if !saved.spectator && !isnothing(saved.selected) &&
           haskey(ctrl.init_poses, saved.selected)
            select!(gui, saved.selected)
        end
    end
    return nothing
end

"""
    _restore_presentation!(gui)

Ends the presentation mode of the `gui` without touching the spectator mode: the background colors
come back and the options are reset; the caller shows the parts of the window, see `_on_spectator!`.
"""
function _restore_presentation!(gui::LiveView)
    p = gui.presentation
    p.on || return nothing
    saved = p.saved
    p.on, p.cards, p.view_cube, p.saved = false, false, false, nothing
    gui.ax.scene.backgroundcolor[] = saved.ax_background
    gui.fig.scene.backgroundcolor[] = saved.fig_background
    return nothing
end

"""
    record(f, gui::LiveView, path, iter; presentation = true, framerate = 30, px_per_unit = 1, kwargs...)

Records a video of the [`live_view`](@ref) window `gui` to the file `path` (its extension is the
format, e.g. `.mp4` or `.gif`), like `Makie.record` of a figure, but made for a live view: for each
element `i` of `iter`, `f(i)` changes the window, e.g. moves objects with
[`translate3d!`](@ref BeamletOpticsGUI.LiveView) (the plain verbs of BeamletOptics would not redraw), then
the solve is finished (see [`wait_solve`](@ref)), the window is told a frame has passed (`tick`:
moves the cards, camera transitions) and one frame of `framerate` frames per second is rendered
offscreen, with `px_per_unit` pixels per unit of the size of the window (`px_per_unit = 2` doubles
the resolution). Returns `path`. The video encoder is the one of Makie (a ffmpeg of the Makie
installation).

With `presentation = true`, the window is in the presentation mode while recording, see
[`presentation!`](@ref), and as before afterwards; if it was in this mode already (e.g. with a
`background`) it stays as it was. Other `kwargs` go to `Makie.record`, e.g. `compression`.
Recording to a window that is open at the same time is not supported.

```julia
Makie.record(gui, "slide.mp4", range(0, 5e-3, 60); framerate = 30, px_per_unit = 2) do d
    translate_to3d!(gui, lens, [0, 0.1 + d, 0])
end
```
"""
function Makie.record(f, gui::LiveView, path::AbstractString, iter; presentation::Bool = true,
        framerate::Real = 30, kwargs...)
    was_presenting = gui.presentation.on
    presentation && !was_presenting && presentation!(gui, true)
    try
        scene = gui.ax.scene
        Makie.record(gui.fig, path, iter; framerate, kwargs...) do i
            f(i)
            wait_solve(gui)
            events(scene).tick[] = Makie.Tick(Makie.RegularRenderTick, 0, 0.0, 1 / framerate)
        end
    finally
        presentation && !was_presenting && presentation!(gui, false)
    end
    return path
end
