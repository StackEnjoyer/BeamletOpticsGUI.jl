#=
Objects that the files of a project add fade in, and those that they remove fade out, see `_fade!`
=#

# The duration of a fade [s], as long as a moved object glides, see `_GLIDE`
const _FADE = _GLIDE

"""
    _fade_start!(fades, gui, obj)

Makes the object `obj`, which the files of the project just added to the `gui`, transparent before
it is drawn, and adds its plots with their opacity as rendered (see `_plot_base`) to `fades`, which
`_fade!` brings up to that opacity. A source is not faded: its beam comes with the next solve.
"""
function _fade_start!(fades, gui::LiveView, @nospecialize(obj::BMO.ObjectOrGroup))
    for p in _object_plots(gui.controls.h, obj)
        base = _plot_base(p)
        push!(fades, (p, base))
        _apply_opacity!(p, base..., 0.0)
    end
    return fades
end
_fade_start!(fades, ::LiveView, ::_Source) = fades

"""
    _fade_ghost!(ghosts, gui, obj)

Renders the object `obj`, which the files removed from the `gui`, once more where it was and adds the
render handle to `ghosts`, which `_fade!` fades out and removes: BeamletOptics draws it, like the
ghost of a placement (see `_ghost!`), while the object itself is gone from the view and its systems
already. Not for a source, whose marker and beam are gone with it.
"""
function _fade_ghost!(ghosts, gui::LiveView, @nospecialize(obj::BMO.ObjectOrGroup))
    push!(ghosts, live_render!(gui.ax, obj; gui.components.render_kwargs...))
    return ghosts
end
_fade_ghost!(ghosts, ::LiveView, ::_Source) = ghosts

# The plots of the render handle `h` and of its children, e.g. of a group
_handle_plots(h) = AbstractPlot[render_plots(h)..., (p for c in AbstractTrees.children(h) for p in _handle_plots(c))...]

"""
    _fade!(fades, ghosts)

Brings the plots of the objects that the files added (`fades`, see `_fade_start!`) up to their
opacity as rendered and the `ghosts` of the removed ones (see `_fade_ghost!`) down to nothing,
together over `_FADE` seconds with the ease of a glide (see `_glide_all!`), then gives the plots
their opacity back and removes the ghosts, also when the fade is interrupted. Runs in a task of its
own, started by `_adopt!`.
"""
function _fade!(fades, ghosts)
    outs = [(p, _plot_base(p)) for h in ghosts for p in _handle_plots(h)]
    n = max(1, round(Int, _FADE * _GLIDE_FPS))
    try
        for i in 1:(n - 1)
            f = i / n
            f = f * f * (3 - 2f)
            foreach(((p, b),) -> _apply_opacity!(p, b..., f), fades)
            foreach(((p, b),) -> _apply_opacity!(p, b..., 1 - f), outs)
            sleep(1 / _GLIDE_FPS)
        end
    finally
        foreach(((p, b),) -> _apply_opacity!(p, b..., 1.0), fades)
        foreach(remove_render!, ghosts)
    end
    return nothing
end
