module TestLiveHighlight

using GLMakie, BeamletOptics, BeamletOpticsGUI
using Makie
using Test

const BMO = BeamletOptics
const GUI = BeamletOpticsGUI
const WARN = Base.CoreLogging.Warn

@testset "Live highlight" begin

    # A bench (group) of a pair of mirrors (subgroup), a doublet and a third mirror, and a lens
    function _fixture()
        m1, m2, m3 = (RoundPlanoMirror(0.02, 0.004) for _ in 1:3)
        translate3d!(m2, [0, 0.05, 0])
        translate3d!(m3, [0, 0.25, 0])
        pair = ObjectGroup([m1, m2])
        dl = SphericalDoubletLens(0.0617, -0.0446, -0.1296, 6e-3, 2.5e-3, 25.4e-3, 1.5, 1.6)
        translate3d!(dl, [0, 0.15, 0])
        bench = ObjectGroup([pair, dl, m3])
        lens = SphericalLens(0.05, -0.05, 5e-3, 25.4e-3, 1.5)
        translate3d!(lens, [0.1, 0.1, 0])
        return (; bench, pair, dl, m1, m2, m3, lens)
    end

    # The plot that the custom `pick` of the controls returns, `nothing` for the background
    picked = Ref{Any}(nothing)
    _live_view(fx, layout) = live_view(System([fx.bench, fx.lens]), Beam([0.0, 0, 0], [0.0, 1, 0]);
        layout, detectors = [], trace_budget = Inf, throttle = false, pick = _ -> (picked[], 0))

    _plots(gui, obj) = GUI._object_plots(gui.controls.h, obj)
    # The attributes that the highlight may change and must restore
    _state(p) = (p.alpha[], p.transparency[], p.color[], p.visible[])
    _boxes(gui) = last.(GUI._highlight(gui).boxes)
    _in_scene(gui, p) = any(q -> q === p, gui.ax.scene.plots)

    @testset "browse, hover, end ($layout)" for layout in (:compact, :app)
        fx = _fixture()
        gui = _live_view(fx, layout)
        all_plots = [p for obj in (fx.bench, fx.lens) for p in _plots(gui, obj)]
        before = IdDict(p => _state(p) for p in all_plots)
        # a user opacity set before browsing
        GUI._set_opacity!(gui, fx.m3, 0.5)
        user = IdDict(p => _state(p) for p in _plots(gui, fx.m3))
        @test isnothing(GUI._highlight(gui))

        parts = Any[fx.pair, fx.dl, fx.m3]
        GUI._browse_highlight!(gui, fx.bench, parts)
        hl = GUI._highlight(gui)
        @test hl.group === fx.bench
        for p in _plots(gui, fx.bench)
            s0 = haskey(user, p) ? user[p] : before[p]
            @test p.alpha[] ≈ 0.25 * s0[1]
            @test p.transparency[]
            @test p.color[] == s0[3]
        end
        # the objects outside the group do not change
        @test all(p -> _state(p) == before[p], _plots(gui, fx.lens))
        # one box per part, thin, in the accent color
        @test first.(hl.boxes) == parts
        @test all(b -> b isa Makie.LineSegments && _in_scene(gui, b), _boxes(gui))
        accent = RGBAf(Makie.to_color(gui.layout.theme.accent), GUI._PART_BOX_ALPHA)
        @test all(b -> b.color[] == accent && b.linewidth[] == GUI._PART_BOX_WIDTH, _boxes(gui))

        # hover: exactly one box thick in the color of the selection box
        GUI._hover_highlight!(gui, fx.dl)
        thick = [b for b in _boxes(gui) if b.linewidth[] != GUI._PART_BOX_WIDTH]
        @test length(thick) == 1 && only(thick) === _boxes(gui)[2]
        @test only(thick).color[] == RGBAf(Makie.to_color(:yellow))
        @test only(thick).linewidth[] > GUI._PART_BOX_WIDTH
        @test count(b -> b.color[] != accent, _boxes(gui)) == 1
        @test hl.hovered === fx.dl
        GUI._hover_highlight!(gui, fx.m3)
        @test count(b -> b.linewidth[] != GUI._PART_BOX_WIDTH, _boxes(gui)) == 1
        @test _boxes(gui)[3].linewidth[] > GUI._PART_BOX_WIDTH
        GUI._hover_highlight!(gui, nothing)
        @test all(b -> b.color[] == accent && b.linewidth[] == GUI._PART_BOX_WIDTH, _boxes(gui))

        # a level inside the group: the whole group stays see-through (dimmed once), the old boxes
        # are replaced by those of the parts of the subgroup
        old = _boxes(gui)
        GUI._browse_highlight!(gui, fx.pair, Any[fx.m1, fx.m2])
        @test !any(b -> _in_scene(gui, b), old)
        @test length(_boxes(gui)) == 2
        @test GUI._highlight(gui).group === fx.pair && isnothing(GUI._highlight(gui).hovered)
        @test all(p -> p.alpha[] ≈ 0.25 * before[p][1] && p.transparency[], _plots(gui, fx.pair))
        @test all(p -> p.alpha[] ≈ 0.25 * before[p][1] && p.transparency[], _plots(gui, fx.dl))
        @test all(p -> p.alpha[] ≈ 0.25 * user[p][1] && p.transparency[], _plots(gui, fx.m3))

        # a doublet: its lenses have no plots of their own, their boxes are those of the doublet
        GUI._browse_highlight!(gui, fx.dl, Any[fx.dl.front, fx.dl.back])
        @test length(_boxes(gui)) == 2
        @test _boxes(gui)[1][1][] == _boxes(gui)[2][1][]

        # end: everything exactly as before, the boxes removed; idempotent
        boxes = _boxes(gui)
        GUI._end_highlight!(gui)
        @test isnothing(GUI._highlight(gui))
        @test !any(b -> _in_scene(gui, b), boxes)
        for p in all_plots
            @test _state(p) == (haskey(user, p) ? user[p] : before[p])
        end
        @test GUI._opacity(gui, fx.m3) == 0.5
        GUI._end_highlight!(gui)
        GUI._hover_highlight!(gui, fx.m3)
        @test isnothing(GUI._highlight(gui))
        # the user opacity still applies after browsing
        GUI._set_opacity!(gui, fx.m3, 1.0)
        @test all(p -> _state(p) == before[p], _plots(gui, fx.m3))
    end

    @testset "part under the cursor" begin
        fx = _fixture()
        gui = _live_view(fx, :compact)
        parts = Any[fx.pair, fx.dl, fx.m3]
        picked[] = first(_plots(gui, fx.m1))
        @test GUI._part_under_cursor(gui, parts) === fx.pair
        @test GUI._part_under_cursor(gui, Any[fx.m1, fx.m2]) === fx.m1
        picked[] = first(_plots(gui, fx.dl))
        @test GUI._part_under_cursor(gui, parts) === fx.dl
        picked[] = last(_plots(gui, fx.m3))
        @test GUI._part_under_cursor(gui, parts) === fx.m3
        # outside the parts, the background, no parts
        picked[] = first(_plots(gui, fx.lens))
        @test isnothing(GUI._part_under_cursor(gui, parts))
        picked[] = nothing
        @test isnothing(GUI._part_under_cursor(gui, parts))
        picked[] = first(_plots(gui, fx.m1))
        @test isnothing(GUI._part_under_cursor(gui, Any[]))
        # the see-through group is picked all the same
        GUI._browse_highlight!(gui, fx.bench, parts)
        @test GUI._part_under_cursor(gui, parts) === fx.pair
        # the box of a part picks the part
        picked[] = GUI._highlight(gui).boxes[3][2]
        @test GUI._part_under_cursor(gui, parts) === fx.m3
        GUI._end_highlight!(gui)
        # hidden parts are not picked
        GUI._toggle_hidden!(gui, fx.m3)
        picked[] = first(_plots(gui, fx.m3))
        @test isnothing(GUI._part_under_cursor(gui, parts))
        GUI._toggle_hidden!(gui, fx.m3)
        @test GUI._part_under_cursor(gui, parts) === fx.m3
    end

    # GLMakie rejects a scalar alpha on some plots when it updates their render object, which it
    # logs as an error while rendering, e.g. on a scatter with an image marker (seen with the red
    # lights of a telescope). The objects of the fixture have neither per-vertex colors nor image
    # markers, and the color of a rendered mesh can not become a vector, hence such plots are added
    # next to the objects and dimmed like the plots of a browsed group.
    @testset "per-vertex colors and image markers" begin
        fx = _fixture()
        gui = _live_view(fx, :compact)
        screen = GLMakie.Screen(visible = false)
        display(screen, gui.fig)
        render() = (Makie.colorbuffer(screen); nothing)
        # a tetrahedron with a color per vertex
        pts = [Point3f(0, 0.3, 0), Point3f(0.01, 0.3, 0), Point3f(0, 0.31, 0), Point3f(0, 0.3, 0.01)]
        faces = [1 2 3; 1 2 4; 1 3 4; 2 3 4]
        mesh_plot = mesh!(gui.ax, pts, faces; color = [RGBAf(i / 4, 0.5, 0.5, 1) for i in 1:4])
        img = [RGBAf(1, 0.1, 0.06, (i + j) / 20) for i in 1:10, j in 1:10]
        marker_plot = scatter!(gui.ax, [Point3f(0, 0.25, 0)]; marker = img, markersize = 8)
        render()
        mesh_state = _state(mesh_plot)
        alpha, transparency = marker_plot.alpha[], marker_plot.transparency[]
        @test isnothing(GUI._image_marker(mesh_plot))
        @test GUI._image_marker(marker_plot) == img

        GUI._browse_highlight!(gui, fx.bench, Any[fx.pair, fx.dl, fx.m3])
        GUI._dim_plot!(mesh_plot, 0.25)
        GUI._dim_plot!(marker_plot, 0.25)
        @test mesh_plot.alpha[] ≈ 0.25 * mesh_state[1] && mesh_plot.transparency[]
        @test mesh_plot.color[] == mesh_state[3]
        # the image marker is dimmed via the alpha of its image
        @test marker_plot.alpha[] == alpha
        @test [c.alpha for c in marker_plot.marker[]] ≈ 0.25 .* [c.alpha for c in img]
        @test marker_plot.transparency[]
        @test_logs min_level = WARN render()

        GUI._restore_plot!(mesh_plot, mesh_state[1], mesh_state[2], nothing)
        GUI._restore_plot!(marker_plot, alpha, transparency, img)
        GUI._end_highlight!(gui)
        @test_logs min_level = WARN render()
        @test _state(mesh_plot) == mesh_state
        @test marker_plot.marker[] == img && marker_plot.transparency[] == transparency
        @test marker_plot.alpha[] == alpha
        close(screen)
    end
end

end
