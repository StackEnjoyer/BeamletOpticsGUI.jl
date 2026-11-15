module TestLiveProjectFade

using GLMakie, BeamletOptics, BeamletOpticsGUI
using BeamletOpticsProjects
using Makie
using Test

const BMO = BeamletOptics
const GUI = BeamletOpticsGUI
const const_kw = (; trace_budget = Inf, throttle = false, detectors = [])

const START = """
    @component M1 = RoundPlanoMirror(0.0254, 0.006) pos = (0.0, 0.2, 0.0)
    @component D1 = Detector(0.02) pos = (0.0, 0.5, 0.0)
    @source B1 = Beam([0.0, 0.0, 0.0], [0.0, 1.0, 0.0], 1.0e-6)
    @system S1 = [M1, D1] sources = [B1]
    """

"""Two windows (not shown) on one project with `START`, saved once by the first."""
function two_windows()
    dir = mktempdir()
    new_project(dir; name = "Bench")
    write(joinpath(dir, "system.jl"), START)
    a = open_project(dir; display = false, const_kw...)
    save_project(a)
    b = open_project(dir; display = false, const_kw...)
    return a, b
end

"""The object of the readable id `id` in the window."""
function obj(gui, id)
    for (x, (name, _)) in gui.sync.ids
        name === id && return x
    end
    return nothing
end

function autosave!(gui)
    t = time()
    first = GUI._autosave!(gui; now = t)
    first === :saved && return first
    return GUI._autosave!(gui; now = t + 1)
end

"""Waits (yielding to the fades) until `cond()` holds or `timeout` seconds passed."""
function wait_for(cond; timeout = 30.0, step = 0.002)
    t0 = time()
    while !cond()
        time() - t0 > timeout && return false
        sleep(step)
    end
    return true
end

alphas(gui, o) = Float32[GUI._plot_alpha(p) for p in GUI._object_plots(gui.controls.h, o)]

@testset "Objects of the files fade in and out" begin
    @testset "an added object fades in, a removed one fades out" begin
        a, b = two_windows()
        m = RoundPlanoMirror(0.0254, 0.006)
        add_component!(a, m; code = "RoundPlanoMirror(0.0254, 0.006)", system = only(GUI._systems(a)))
        translate3d!(a, m, [0.0, 0.35, 0.0])
        @test autosave!(a) === :saved
        n0 = length(b.ax.scene.plots)
        @test GUI._sync!(b; animate = true) === :applied
        new = obj(b, :M2)
        @test !isnothing(new)
        # transparent at first, as rendered after the fade
        @test all(<(0.5), alphas(b, new))
        @test wait_for(() -> all(==(1.0f0), alphas(b, new)))
        # in its system from the start, as without a fade
        @test any(o -> o === new, only(GUI._systems(b)).objects)

        # removed in the files: gone from the view and its systems at once, its ghost fades out
        remove_component!(a, m)
        @test autosave!(a) === :saved
        n1 = length(b.ax.scene.plots)
        @test GUI._sync!(b; animate = true) === :applied
        @test isnothing(obj(b, :M2)) && !any(o -> o === new, only(GUI._systems(b)).objects)
        @test length(b.ax.scene.plots) == n1
        @test wait_for(() -> length(b.ax.scene.plots) < n1)
        @test length(b.ax.scene.plots) == n0
        close(b)
        close(a)
    end

    @testset "not without animation, not in the person's own window" begin
        a, b = two_windows()
        m = RoundPlanoMirror(0.0254, 0.006)
        add_component!(a, m; code = "RoundPlanoMirror(0.0254, 0.006)", system = only(GUI._systems(a)))
        @test autosave!(a) === :saved
        @test GUI._sync!(b; animate = false) === :applied
        @test all(==(1.0f0), alphas(b, obj(b, :M2)))
        # the person's own addition
        own = RoundPlanoMirror(0.0254, 0.006)
        add_component!(b, own; system = only(GUI._systems(b)))
        @test all(==(1.0f0), alphas(b, own))
        close(b)
        close(a)
    end

    @testset "a fade gives the plots back also when it is interrupted" begin
        a, b = two_windows()
        m1 = obj(b, :M1)
        fades = GUI._fade_start!(Tuple{Any, Any}[], b, m1)
        @test all(==(0.0f0), alphas(b, m1))
        t = @async GUI._fade!(fades, BeamletOptics.AbstractObjectRenderHandle[])
        sleep(0.05)
        schedule(t, InterruptException(); error = true)
        @test wait_for(() -> istaskdone(t))
        @test all(==(1.0f0), alphas(b, m1))
        close(b)
        close(a)
    end
end

end
