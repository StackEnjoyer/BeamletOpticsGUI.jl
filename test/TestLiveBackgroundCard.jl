module TestLiveBackgroundCard

using GLMakie, BeamletOptics, BeamletOpticsGUI
using BeamletOptics: render_plots
using Makie
using LinearAlgebra: dot, normalize
using Test

const GUI = BeamletOpticsGUI

# An object without a place in the scene, e.g. the environment of a telescope
mutable struct Sky
    hour::Float64
end

# The objects that `value` and `on` of the card of the sky got
const SEEN = Any[]

BeamletOpticsGUI.card_rows(::Sky) = (CardRow("hour",
    CardWidget(Slider; name = :hour, range = 0:0.5:24, width = 120,
        value = (gui, s) -> (push!(SEEN, s); s.hour), on = (gui, s, v) -> (push!(SEEN, s); s.hour = v)),
    CardWidget(Label; name = :hour_text, value = (gui, s) -> "$(s.hour) h")),)

@testset "Live background card" begin

    _press!(gui) = (events(gui.ax.scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.press))
    _release!(gui) = (events(gui.ax.scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.release))
    _key!(gui, key) = (events(gui.ax.scene).keyboardbutton[] = Makie.KeyEvent(key, Keyboard.press))
    # A click without drag at the left of the 3D view, where no component is
    function _click_background!(gui)
        vp = gui.ax.scene.viewport[]
        events(gui.ax.scene).mouseposition[] = (vp.origin[1] + 0.15 * vp.widths[1], vp.origin[2] + 0.5 * vp.widths[2])
        _press!(gui)
        _release!(gui)
        return nothing
    end
    # The item on the transient card, or `nothing`
    function _shown(gui)
        c = GUI._info_card(gui)
        return isnothing(c) ? nothing : c.obj
    end

    # The plot that the custom `pick` of the controls returns, `nothing` for the background
    picked = Ref{Any}(nothing)
    function _live_view(layout; kwargs...)
        m = RoundPlanoMirror(25e-3, 5e-3)
        translate3d!(m, [0, 0.1, 0])
        b = Beam([0.0, 0, 0], [0.0, 1, 0])
        # the beam is off: a click near it would inspect it instead
        gui = live_view(System([m]), b; layout, detectors = [], beams_off = [b], trace_budget = Inf,
            throttle = false, pick = _ -> (picked[], 0), kwargs...)
        return gui, m
    end

    @testset "object ($layout)" for layout in (:compact, :app)
        sky = Sky(6.0)
        gui, m = _live_view(layout; background_card = sky, labels = Dict(sky => "Sky"))
        empty!(SEEN)
        _click_background!(gui)
        x = _shown(gui)
        @test x isa GUI._BackgroundItem && x.obj === sky
        c = GUI._info_card(gui)
        @test c.scene.visible[] && c.transient
        # title from `labels`, the icon of an object, no actions
        @test c.title.text[] == "Sky"
        @test isempty(c.actions.content)
        # the widgets get the user object
        slider = GUI._card_widget(c, :hour)
        @test slider isa Slider && slider.value[] == 6.0
        @test GUI._card_widget(c, :hour_text).text[] == "6.0 h"
        @test !isempty(SEEN) && all(s -> s === sky, SEEN)
        empty!(SEEN)
        Makie.set_close_to!(slider, 12.0)
        @test sky.hour == 12.0
        @test GUI._card_widget(c, :hour_text).text[] == "12.0 h"
        @test !isempty(SEEN) && all(s -> s === sky, SEEN)
        # at the click, on the plane through the lookat point perpendicular to the view direction
        cam = cameracontrols(gui.ax.scene)
        lookat, eye = Vector{Float64}(cam.lookat[]), Vector{Float64}(cam.eyeposition[])
        v = normalize(lookat - eye)
        p = Vector{Float64}(x.point)
        @test abs(dot(p - lookat, v)) < 1e-4 * sqrt(sum(abs2, lookat - eye))
        origin, dir = GUI._cursor_ray(gui.ax.scene)
        w = p - origin
        @test sqrt(sum(abs2, w - dot(w, dir) * dir)) < 1e-4 * sqrt(sum(abs2, w))

        # a click elsewhere closes it, without opening it again
        _click_background!(gui)
        @test isnothing(_shown(gui))
        # the next one opens it again, Esc closes it
        _click_background!(gui)
        @test _shown(gui) isa GUI._BackgroundItem
        _key!(gui, Keyboard.escape)
        @test isnothing(_shown(gui))
        @test !c.scene.visible[]

        # with a selection, the click only deselects
        GUI._select!(gui, m)
        _click_background!(gui)
        @test isnothing(gui.controls.selected[])
        @test isnothing(_shown(gui))
        _click_background!(gui)
        @test _shown(gui) isa GUI._BackgroundItem
        # a click on an object closes it and selects the object
        picked[] = first(render_plots(GUI._child_handle(gui.controls.h, m)))
        _press!(gui)
        _release!(gui)
        picked[] = nothing
        @test gui.controls.selected[] === m
        @test isnothing(_shown(gui))
        _click_background!(gui)
        @test isnothing(gui.controls.selected[]) && isnothing(_shown(gui))
        # also an inspected object, e.g. the card of a system, only closes
        GUI._inspect!(gui, first(gui.pairs).first)
        _click_background!(gui)
        @test isnothing(gui.objects.inspected) && isnothing(_shown(gui))

        # the pin keeps it
        _click_background!(gui)
        c = GUI._info_card(gui)
        item = c.obj
        GUI._toggle_pinned!(gui, c)
        # floating (compact) or docked (app), no longer transient
        @test isnothing(GUI._info_card(gui))
        @test GUI._is_pinned(gui, item)
        # and the next click on the background opens a new card
        _click_background!(gui)
        @test _shown(gui) isa GUI._BackgroundItem && _shown(gui) !== item

        # while measuring, no card
        gui.widgets.measure_toggle.active[] = true
        _click_background!(gui)
        _click_background!(gui)
        @test isnothing(_shown(gui))
        close(gui)
    end

    @testset "function and nothing ($layout)" for layout in (:compact, :app)
        sky = Sky(3.0)
        shown = Ref(false)
        calls = Ref(0)
        gui, _ = _live_view(layout; background_card = g -> (calls[] += 1; g isa GUI.LiveView && shown[] ? sky : nothing))
        _click_background!(gui)
        @test calls[] == 1 && isnothing(_shown(gui))
        shown[] = true
        _click_background!(gui)
        @test calls[] == 2
        x = _shown(gui)
        @test x isa GUI._BackgroundItem && x.obj === sky
        # the type name without a label
        @test GUI._info_card(gui).title.text[] == "Sky"
        close(gui)

        # none by default
        gui, _ = _live_view(layout)
        @test isnothing(gui.background_card)
        _click_background!(gui)
        @test isnothing(_shown(gui))
        close(gui)
    end
end

end
