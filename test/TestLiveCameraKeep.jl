module TestLiveCameraKeep

using GLMakie, BeamletOptics, BeamletOpticsGUI
using Makie
using Test

const GUI = BeamletOpticsGUI

# In an open window (here an invisible screen), Makie's `plot!` into the `LScene` calls
# `reset_limits!`, whose `center!` would fit the camera to the scene, see `_keep_camera!`
@testset "Camera kept in the open window" begin
    pd = Detector(50e-3)
    translate3d!(pd, [0, 0.1, 0])
    m = RoundPlanoMirror(25e-3, 5e-3)
    translate3d!(m, [0.05, 0.3, 0])
    g = GaussianBeamlet([0.0, 0, 0], [0.0, 1, 0], 1e-6, 0.5e-3)
    pol = Beam([20e-3, 0, 0], [0.0, 1, 0], 633e-9, [1.0, 0, 0])
    gui = live_view(System([pd, m]) => g, System([m]) => pol; trace_budget = Inf, throttle = false)
    screen = GLMakie.Screen(visible = false)
    display(screen, gui.fig)
    tick!() = (events(gui.ax.scene).tick[] = Makie.Tick(Makie.RegularRenderTick, 0, 0.0, 1 / 60))
    foreach(_ -> tick!(), 1:3)
    @test isopen(gui.ax.scene)
    cam = cameracontrols(gui.ax.scene)

    # the view was fitted to the scene when the window was shown, the home view is that view
    eye, lookat, up = GUI._current_view(gui)
    @test lookat ≈ Vector{Float64}(Makie.origin(cam.bounding_sphere[])) atol = 1e-6
    @test GUI._current_view(gui) == gui.camera.home

    # a view of the user, zoomed in and shifted
    user_view() = GUI.set_view(gui.ax, lookat .+ 0.3 .* (eye .- lookat) .+ [0.01, 0, 0],
        lookat .+ [0.01, 0, 0], up)
    function kept(f)
        user_view()
        tick!()
        v0 = GUI._current_view(gui)
        f()
        tick!()
        return all(a -> isapprox(a[1], a[2]; atol = 1e-9), zip(v0, GUI._current_view(gui)))
    end
    @test kept(() -> GUI._set_generating_beams!(gui, g, true))
    @test kept(() -> GUI._set_generating_beams!(gui, g, false))
    @test kept(() -> GUI._set_polarization!(gui, pol, true))
    @test kept(() -> GUI._set_pol_position!(gui, pol, :λ, 0.3))
    @test kept(() -> GUI._set_pol_position!(gui, pol, :amp, 0.7))
    @test kept(() -> GUI._set_polarization!(gui, pol, false))
    @test kept(() -> GUI._set_beam_on!(gui, pol, false))
    @test kept(() -> GUI._set_beam_on!(gui, pol, true))
    @test kept(() -> redirect_stderr(() -> GUI._fail!(gui, ErrorException("x")), devnull))
    @test kept(() -> GUI._trace!(gui))
    @test kept(() -> GUI._add_clip_plane!(gui, [0.0, 0.05, 0.0], [0.0, 1.0, 0.0]))
    @test kept(() -> GUI._add_measure_point!(gui, [0.0, 0.05, 0.0], nothing))
    @test kept(() -> reset_limits!(gui.ax))

    # home still restores the fitted view
    user_view()
    GUI._go_home!(gui)
    foreach(_ -> tick!(), 1:60)
    @test all(a -> isapprox(a[1], a[2]; atol = 1e-6), zip(GUI._current_view(gui), gui.camera.home))
    close(screen)
end

end
