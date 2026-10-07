#=
Recording a video of a live view
=#

"""
    record(f, gui::LiveView, path, iter; spectator = true, framerate = 30, px_per_unit = 1, kwargs...)

Records a video of the [`live_view`](@ref) window `gui` to the file `path` (its extension is the
format, e.g. `.mp4` or `.gif`), like `Makie.record` of a figure, but made for a live view: for each
element `i` of `iter`, `f(i)` changes the window, e.g. moves objects with
[`translate3d!(::BeamletOpticsGUI.LiveView, ::Any, ::AbstractVector)`](@ref) (the plain verbs of
BeamletOptics would not redraw), then the solve is finished (see [`wait_solve`](@ref)), the
window is told a frame has passed (`tick`: moves the cards, camera transitions) and one frame of
`framerate` frames per second is rendered offscreen, with `px_per_unit` pixels per unit of the size
of the window (`px_per_unit = 2` doubles the resolution). Returns `path`. The video encoder is the
one of Makie (a ffmpeg of the Makie installation).

With `spectator = true`, the window is in the spectator mode without its help while recording, i.e.
only the 3D view is recorded, see [`spectator!`](@ref), and as before afterwards; a mode that is on
already keeps its options, e.g. a `background` or the pinned cards. Other `kwargs` go to
`Makie.record`, e.g. `compression`. Recording to a window that is open at the same time is not
supported.

```julia
Makie.record(gui, "slide.mp4", range(0, 5e-3, 60); framerate = 30, px_per_unit = 2) do d
    translate_to3d!(gui, lens, [0, 0.1 + d, 0])
end
```
"""
function Makie.record(f, gui::LiveView, path::AbstractString, iter; spectator::Bool = true,
        framerate::Real = 30, kwargs...)
    ctrl = gui.controls
    was, was_help = ctrl.spectator[], ctrl.spectator_help
    # Not needed for a mode without help that is on already
    clean = spectator && (!was || was_help)
    clean && _set_spectator!(ctrl, true; help = false)
    try
        scene = gui.ax.scene
        Makie.record(gui.fig, path, iter; framerate, kwargs...) do i
            f(i)
            wait_solve(gui)
            events(scene).tick[] = Makie.Tick(Makie.RegularRenderTick, 0, 0.0, 1 / framerate)
        end
    finally
        clean && _set_spectator!(ctrl, was; help = was_help)
    end
    return path
end
