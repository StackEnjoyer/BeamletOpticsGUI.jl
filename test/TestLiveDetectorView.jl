module TestLiveDetectorView

using GLMakie, BeamletOptics, BeamletOpticsGUI
using Makie
using Test

const BMO = BeamletOptics
const GUI = BeamletOpticsGUI

GLMakie.activate!(; visible = false)

@testset "Detector view" begin

    Spot, PSF, Intensity = GUI._SpotKind(), GUI._PSFKind(), GUI._IntensityKind()
    theme = GUI._APP_THEMES[:light]

    # 40 rays along +y on a detector
    function _rays()
        pd = Detector(25e-3)
        translate3d!(pd, [0, 0.05, 0])
        src = CollimatedSource([0.0, 0, 0], [0.0, 1, 0], 4e-3, 1e-6; num_rings = 2, num_rays = 40)
        solve_system!(System([pd]), src)
        return pd
    end

    # A Gaussian beamlet with a waist of 0.5 mm, 200 mm before the detector
    function _gauss()
        pd = Detector(10e-3)
        translate3d!(pd, [0, 0.2, 0])
        solve_system!(System([pd]), GaussianBeamlet([0.0, 0, 0], [0.0, 1, 0], 1e-6, 0.5e-3))
        return pd
    end

    # The widget beside a 3D view in the layout of a figure, or (`floating`) in a free layout of
    # a pixel scene over the 3D view, like on a floating card
    function _host(; floating = false, kwargs...)
        fig = Figure(; size = (900, 600))
        ls = LScene(fig[1, 1])
        if floating
            scene = Scene(fig.scene; camera = Makie.campixel!, clear = false)
            translate!(scene, 0, 0, GUI._CARD_Z0)
            grid = GUI._card_part(scene)
            GUI._place!(grid, Point2f(100, 560))
        else
            grid = GridLayout(fig[1, 2]; tellheight = false, valign = :top)
        end
        return fig, ls, GUI._DetectorView(grid, theme; kwargs...)
    end

    _show!(v, pd, opts = GUI._ViewOptions(); kwargs...) =
        GUI._show_result!(v, "PD", GUI._view_result(pd, opts; kwargs...), opts)

    # The options that the widget reports and the states that it asks for
    function _connect!(fig, v)
        options, expanded = Any[], Bool[]
        listeners = GUI._connect_view!(v, events(fig); on_options = (; kw...) -> push!(options, only(pairs(kw))),
            on_expanded = b -> push!(expanded, b))
        return options, expanded, listeners
    end

    _center(ax) = Point2f(Makie.origin(ax.scene.viewport[]) .+ Makie.widths(ax.scene.viewport[]) ./ 2)
    _move!(fig, p) = (events(fig).mouseposition[] = (Float64(p[1]), Float64(p[2])))
    _scroll!(fig, dy) = (events(fig).scroll[] = (0.0, Float64(dy)))
    _button!(fig, action, button = Mouse.left) =
        (events(fig).mousebutton[] = Makie.MouseButtonEvent(button, action))
    _ctrl!(fig, action) = (events(fig).keyboardbutton[] = Makie.KeyEvent(Keyboard.left_control, action))
    _limits(ax) = GUI._shown_limits(ax)

    # Pixel boxes in the frame of the texts that Makie draws inside the frame of the axis
    function _text_boxes(v)
        lims, size = v.ax.finallimits[], Makie.widths(v.ax.scene.viewport[])
        boxes = Rect2f[]
        for p in (v.xlabels, v.zlabels, v.xname, v.zname, v.status)
            p.visible[] || continue
            offset = p.offset[]
            for (q, bb, s) in zip(p.positions[], Makie.raw_string_boundingboxes(p), p.text[])
                isempty(s) && continue
                px = (Point2f(q) .- Point2f(Makie.origin(lims))) ./ Vec2f(Makie.widths(lims)) .* Vec2f(size)
                o, w = Makie.origin(bb), Makie.widths(bb)
                push!(boxes, Rect2f(o[1] + px[1] + offset[1], o[2] + px[2] + offset[2], w[1], w[2]))
            end
        end
        return boxes
    end
    _overlap(a, b) = all(minimum(a) .< maximum(b)) && all(minimum(b) .< maximum(a))
    _any_overlap(boxes) = any(_overlap(boxes[i], boxes[j]) for i in eachindex(boxes) for j in 1:(i - 1))

    @testset "kinds" begin
        for T in (BMO.RayHit{Float64}, BMO.PolarizedRayHit{Float64})
            @test GUI._view_kinds(T[]) == (Spot, PSF)
        end
        for T in (BMO.GaussianBeamletHit{Float64}, BMO.AstigmaticGaussianBeamletHit{Float64})
            @test GUI._view_kinds(T[]) == (Intensity, Spot)
        end
        @test GUI._view_kinds(nothing) == ()
        @test GUI._view_kinds(BMO.hits(_rays())) == (Spot, PSF)

        @test GUI._view_kinds(BMO.hits(_gauss())) == (Intensity, Spot)
        @test map(GUI._kind_name, (Spot, PSF, Intensity)) == (:spot, :psf, :intensity)
        @test map(GUI._kind_label, (Spot, PSF, Intensity)) == ("Spot", "PSF", "Intensity")
        @test GUI._THUMB_N == 48
        @test GUI._resolve_kind((Spot, PSF), :psf) == PSF
        @test GUI._resolve_kind((Spot, PSF), :auto) == Spot
        @test GUI._resolve_kind((Intensity, Spot), :psf) == Intensity

        # dispatch instead of `isa` chains, images instead of heatmaps, only the declared BMO functions
        source = read(joinpath(pkgdir(GUI), "src", "LiveDetectorView.jl"), String)
        @test !occursin(r"\bisa\b", source)
        @test !occursin("heatmap", source)
        @test !occursin("BMO._", source)
        called = Set(m.captures[1] for m in eachmatch(r"BMO\.(\w+)\(", source))
        @test called ⊆ Set(["spot_diagram", "intensity", "hits", "hit_count", "is_cancelled"])
    end

    @testset "scale of the colorbar" begin
        I, psf = GUI._IntensityKind(), GUI._PSFKind()
        # linear: the color range in a unit in which the largest tick has two to four digits
        s = GUI._bar_scale(I, (0, 1350), :linear)
        @test s.limits == (0.0, 1350.0) && s.unit == "W/m²" && s.ticks === GUI._VIEW_BAR_TICKS
        s = GUI._bar_scale(I, (0, 25000), :linear)
        @test collect(s.limits) ≈ [0, 25] && s.unit == "kW/m²"
        s = GUI._bar_scale(I, (0, 0.5), :linear)
        @test collect(s.limits) ≈ [0, 500] && s.unit == "mW/m²"
        @test GUI._bar_scale(I, (0, 3e8), :linear).unit == "MW/m²"
        @test GUI._bar_scale(I, (0, 1e-12), :linear).unit == "nW/m²"
        s = GUI._bar_scale(psf, (0, 1), :linear)
        @test s.limits == (0.0, 1.0) && s.unit == "rel."
        # a degenerate range still has limits
        @test GUI._bar_scale(psf, (2, 2), :linear).limits == (2.0, 3.0)
        # logarithmic: the powers of ten in the range, without a prefix of the unit
        s = GUI._bar_scale(I, (log10(0.135), log10(1350)), :log)
        @test collect(s.limits) ≈ [log10(0.135), log10(1350)] && s.unit == "W/m²"
        @test s.ticks == ([0.0, 1.0, 2.0, 3.0], ["10⁰", "10¹", "10²", "10³"])
        # at most about five of them
        s = GUI._bar_scale(I, (-12, 0), :log)
        @test s.ticks == ([-12.0, -9.0, -6.0, -3.0, 0.0], ["10⁻¹²", "10⁻⁹", "10⁻⁶", "10⁻³", "10⁰"])
        # a range without a power of ten shows the values
        values, labels = GUI._bar_scale(I, (2.1, 2.4), :log).ticks
        @test !isempty(values) && all(x -> 2.1 <= x <= 2.4, values)
        @test labels == [GUI._fmt_sigdigits(10.0^x) for x in values]
    end

    @testset "options" begin
        o = GUI._ViewOptions()
        @test o.kind == :auto && o.n == 100 && o.kwargs == (;) && o.colorscale == :linear
        @test isnothing(o.colorrange) && o.colorbar && !o.profiles && isnothing(o.window)
        @test !GUI._ViewOptions(o; colorbar = false).colorbar
        p = GUI._ViewOptions(o; kind = :psf, window = (-1, 1, -2, 2))
        @test p.kind == :psf && p.n == 100 && p.window === (-1.0, 1.0, -2.0, 2.0)
        @test o.kind == :auto
        @test GUI._ViewOptions(p; window = nothing) == GUI._ViewOptions(; kind = :psf)
        @test GUI._ViewOptions(; kwargs = (; crop_factor = 2)) != o
        @test hash(GUI._ViewOptions()) == hash(o)
    end

    @testset "results" begin
        pd = _rays()
        r = GUI._view_result(pd, GUI._ViewOptions())
        @test r.kinds == (Spot, PSF) && r.kind == Spot
        @test r.data == BMO.spot_diagram(pd) && r.metrics.n == 40
        @test isnothing(r.error) && !r.coarse && !r.preview && r.n == 100

        # the PSF: the intensity of the rays, normalized to its peak, without a power
        o = GUI._ViewOptions(; kind = :psf, n = 20)
        r = GUI._view_result(pd, o)
        x, z, I = BMO.intensity(pd; n = 20)
        @test r.kind == PSF && r.n == 20
        @test r.data[1] == x && r.data[2] == z && r.data[3] ≈ I ./ maximum(I)
        @test maximum(r.data[3]) ≈ 1
        @test !haskey(r.metrics, :P) && isfinite(r.metrics.wx)
        # the grid: of the options, of the call, coarse
        @test size(GUI._view_result(pd, o; n = GUI._THUMB_N).data[3]) == (48, 48)
        r = GUI._view_result(pd, GUI._ViewOptions(o; n = 100); coarse = true, preview = true)
        @test size(r.data[3]) == (25, 25) && r.n == 25 && r.coarse && r.preview
        @test size(GUI._view_result(pd, o; coarse = true).data[3]) == (16, 16)
        # the window, over the area of the kwargs
        w = (-1e-3, 1e-3, -2e-3, 2e-3)
        r = GUI._view_result(pd, GUI._ViewOptions(o; window = w, kwargs = (; x_min = -5e-3, x_max = 5e-3)))
        @test collect(extrema(r.data[1])) ≈ [-1e-3, 1e-3] && collect(extrema(r.data[2])) ≈ [-2e-3, 2e-3]
        r = GUI._view_result(pd, GUI._ViewOptions(o; kwargs = (; x_min = -5e-3, x_max = 5e-3)))
        @test collect(extrema(r.data[1])) ≈ [-5e-3, 5e-3]

        # Gaussian beamlet: the intensity, a choice that the hits do not offer falls back
        pd = _gauss()
        r = GUI._view_result(pd, GUI._ViewOptions(; n = 40))
        @test r.kinds == (Intensity, Spot) && r.kind == Intensity
        @test r.data[3] == BMO.intensity(pd; n = 40)[3]
        @test isapprox(r.metrics.P, optical_power(pd; n = 40); rtol = 1e-9)
        @test GUI._view_result(pd, GUI._ViewOptions(; kind = :psf, n = 20)).kind == Intensity
        r = GUI._view_result(pd, GUI._ViewOptions(; kind = :spot))
        @test r.kind == Spot && haskey(r.metrics, :rms)

        # no hits, an error, a background task
        r = GUI._view_result(Detector(1e-3), GUI._ViewOptions())
        @test r.kinds == () && isnothing(r.kind) && isnothing(r.data) && isnothing(r.metrics) && isnothing(r.error)
        r = GUI._view_result(pd, GUI._ViewOptions(; kwargs = (; crop_factor = "wide")))
        @test r.error isa Exception && r.kinds == (Intensity, Spot) && r.kind == Intensity && isnothing(r.data)
        @test fetch(Threads.@spawn GUI._view_result(pd, GUI._ViewOptions(; n = 20))).kind == Intensity
        # hits whose field can not be evaluated: the spot diagram, with the kind :auto only
        astigmatic = BMO.AstigmaticGaussianBeamletHit{Float64}[]
        failing = Detector(1e-3)
        @test_throws "No hits available" GUI._shown_data(Intensity, failing, astigmatic, GUI._ViewOptions(), 20, false)
        @test GUI._shown_data(Intensity, pd, astigmatic, GUI._ViewOptions(; n = 20), 20, false)[1] == Intensity
    end

    @testset "metrics" begin
        # synthetic spot
        c = (0.3e-3, -0.2e-3)
        pts = [Point2(c[1] + dx, c[2] + dz) for (dx, dz) in ((1e-3, 0), (-1e-3, 0), (0, 2e-3), (0, -2e-3))]
        mt = GUI._spot_metrics(pts)
        @test mt.n == 4
        @test abs(mt.cx - c[1]) < 1e-9 && abs(mt.cz - c[2]) < 1e-9
        @test abs(mt.rms - sqrt(2.5) * 1e-3) < 1e-9
        @test abs(mt.rmax - 2e-3) < 1e-9
        @test startswith(GUI._metrics_string(mt), "N = 4, c = (")
        @test occursin("rms ", GUI._metrics_string(mt))

        # ray hits
        pd = _rays()
        spots = BMO.spot_diagram(pd)
        m = GUI._view_result(pd, GUI._ViewOptions()).metrics
        cx, cz = sum(q -> q[1], spots) / 40, sum(q -> q[2], spots) / 40
        @test abs(m.cx - cx) < 1e-9 && abs(m.cz - cz) < 1e-9
        @test abs(m.rms - sqrt(sum(q -> (q[1] - cx)^2 + (q[2] - cz)^2, spots) / 40)) < 1e-9
        @test m.n == 40

        # Gaussian beamlet: power and 1/e² radius
        pd = _gauss()
        m = GUI._view_result(pd, GUI._ViewOptions()).metrics
        @test m == GUI._intensity_metrics(BMO.intensity(pd)...)
        @test isapprox(m.P, optical_power(pd); rtol = 1e-3)
        # waist 0.5 mm at the source, 200 mm to the detector
        zR = π * 0.5e-3^2 / 1e-6
        w = 0.5e-3 * sqrt(1 + (0.2 / zR)^2)
        @test isapprox(m.wx, w; rtol = 0.02)
        @test isapprox(m.wz, w; rtol = 0.02)
        @test abs(m.cx) < 1e-6 && abs(m.cz) < 1e-6
        @test m.peak ≈ maximum(BMO.intensity(pd)[3])
        @test startswith(GUI._metrics_string(m), "P = ")
        @test GUI._metrics_string((; P = 1e-3, cx = NaN, cz = NaN, wx = NaN, wz = NaN, peak = 0.0)) ==
              "P = 1.000 mW, peak 0 W/m²\nno intensity"

        # logarithmic color scale with a floor
        _, _, I = BMO.intensity(pd; n = 20, x_min = -2.5e-3, x_max = 2.5e-3, z_min = -2.5e-3, z_max = 2.5e-3)
        Imax = maximum(I)
        values, range = GUI._display_intensity(I, :log)
        @test values ≈ log10.(max.(I, 1e-4 * Imax))
        @test minimum(values) ≈ log10(1e-4 * Imax)
        @test collect(range) ≈ [log10(1e-4 * Imax), log10(Imax)]
        values, range = GUI._display_intensity(I, :linear)
        @test values === I && collect(range) ≈ [0, Imax]

        @test GUI._fmt3(1.5) == "1.500" && GUI._fmt3(2) == "2.000" && GUI._fmt3(0.12345) == "0.123"
        @test GUI._signed_length_string(-2e-3) == "-2 mm" && GUI._signed_length_string(1e-14) == "0 nm"

        # Only the degenerate axis is padded, by half the extent of the other axis
        ax = Axis(Figure()[1, 1])
        GUI._pad_degenerate_limits!(ax, [Point2f(1, 0), Point2f(1, 2)])
        lims = ax.targetlimits[]
        @test lims.origin ≈ [0.0, 1 - 1.05] && lims.widths ≈ [2.0, 2 * 1.05]
    end

    @testset "states ($(floating ? "pixel scene" : "figure"))" for floating in (false, true)
        fig, _, v = _host(; floating)
        # a new view is expanded, without a result
        @test v.expanded
        @test v.metrics_label.text[] == "no result" && isnothing(v.switch)
        @test v.ax.blockscene.visible[] && !v.thumb_ax.blockscene.visible[]
        @test Makie.widths(v.ax.scene.viewport[]) == Vec2(280, 280)
        @test GUI._view_size(v)[1] ≈ 280 && GUI._view_size(v)[2] > 280

        # the axis: y axis on the right, nothing outside the frame, which spans the widget
        pd = _gauss()
        _show!(v, pd, GUI._ViewOptions(; n = 30))
        @test v.ax.yaxisposition[] == :right
        for ax in (v.ax, v.thumb_ax)
            pr = ax.layoutobservables.protrusions[]
            @test pr.left == 0 && pr.right == 0 && pr.top == 0 && pr.bottom == 0
        end
        frame, widget = Rect2f(v.ax.scene.viewport[]), Rect2f(v.full.layoutobservables.computedbbox[])
        @test abs(minimum(frame)[1] - minimum(widget)[1]) < 1
        @test abs(maximum(frame)[1] - maximum(widget)[1]) < 1
        @test GUI._over_view(v, _center(v.ax))
        @test !GUI._over_view(v, Point2f(maximum(widget)) .+ 5)

        # the field is an interpolated image, in front of it the texts; no centroid without profiles
        thumb_image, image = v.images
        @test image isa Makie.Image && image.interpolate[] && image.visible[] && thumb_image.visible[]
        @test size(image[3][]) == (30, 30)
        @test !v.spots[2].visible[]
        @test all(p -> isempty(p[1][]), v.crosses) && isempty(v.cut_x[1][]) && isempty(v.cut_z[1][])
        @test v.xlabels.transformation.translation[][3] > image.transformation.translation[][3]
        @test v.switch.keys == [:intensity, :spot] && v.switch.selected[] == :intensity
        @test startswith(v.metrics_label.text[], "P = ")
        @test v.fields_shown && v.log_toggle.blockscene.visible[]
        size_expanded = GUI._view_size(v)

        # collapsed: the thumbnail of 92 px without decorations, the kind and the metrics
        GUI._set_expanded!(v, false)
        @test !v.expanded
        @test GUI._view_size(v) != size_expanded
        @test GUI._view_size(v)[2] ≈ GUI._THUMB_SIZE
        @test Makie.widths(v.thumb_ax.scene.viewport[]) == Vec2(92, 92)
        @test v.thumb_ax.blockscene.visible[] && !v.ax.blockscene.visible[]
        @test !v.log_toggle.blockscene.visible[] && !v.fit_button.blockscene.visible[]
        @test !v.thumb_ax.xticksvisible[] && !v.thumb_ax.xticklabelsvisible[] && !v.thumb_ax.yticklabelsvisible[]
        @test v.kind_label.text[] == "Intensity"
        info = split(v.info_label.text[], "\n")
        @test startswith(info[1], "P = ") && startswith(info[2], "c = (") && startswith(info[3], "w = (")
        # the expanded view is laid out off-screen, where it takes no events
        @test maximum(v.ax.scene.viewport[])[1] < 0
        @test GUI._over_view(v, _center(v.thumb_ax)) && !GUI._over_axis(v, _center(v.thumb_ax))

        GUI._set_expanded!(v, true)
        @test v.expanded && GUI._view_size(v) == size_expanded
        @test minimum(v.ax.scene.viewport[])[1] > 0 && maximum(v.thumb_ax.scene.viewport[])[1] < 0
        @test v.log_toggle.blockscene.visible[]

        # size of the axis
        GUI._resize_view!(v, 200, 160)
        @test Makie.widths(v.ax.scene.viewport[]) == Vec2(200, 160)
        @test GUI._view_size(v)[1] ≈ 200
        # equal scales fill the frame
        x0, x1, z0, z1 = _limits(v.ax)
        @test (x1 - x0) / (z1 - z0) ≈ 200 / 160

        # the colorbar of a field, below the axis: as wide as the axis with its unit
        @test v.bar_shown && v.bar_ax.blockscene.visible[] && v.bar_toggle.active[]
        frame, bar, unit = Rect2f(v.ax.scene.viewport[]), Rect2f(v.bar_ax.scene.viewport[]),
        Rect2f(v.bar_unit.layoutobservables.computedbbox[])
        @test maximum(bar)[2] < minimum(frame)[2] && Makie.widths(bar)[2] ≈ GUI._VIEW_BAR_HEIGHT
        @test abs(minimum(bar)[1] - minimum(frame)[1]) < 1 && maximum(bar)[1] < minimum(unit)[1]
        @test abs(maximum(unit)[1] - maximum(frame)[1]) < 1
        # its limits are the color range of the image in its unit, the colormap spans them
        s = GUI._bar_scale(GUI._IntensityKind(), v.images[2].colorrange[], :linear)
        @test endswith(s.unit, "W/m²") && v.bar_unit.text[] == s.unit
        @test collect(_limits(v.bar_ax)) ≈ [s.limits..., 0, 1] && collect(v.bar_image[1][]) ≈ collect(s.limits)
        @test v.bar_image.transformation.translation[][3] > 0
        h_bar = GUI._view_size(v)[2]
        _show!(v, pd, GUI._ViewOptions(; n = 30, colorbar = false))
        @test !v.bar_shown && !v.bar_ax.blockscene.visible[] && !v.bar_toggle.active[]
        @test GUI._view_size(v)[2] < h_bar - GUI._VIEW_BAR_HEIGHT
        h_none = GUI._view_size(v)[2]
        # without the bar, the profiles take its row
        _show!(v, pd, GUI._ViewOptions(; n = 30, colorbar = false, profiles = true))
        @test v.profiles_shown && !v.bar_shown
        h_profiles = GUI._view_size(v)[2]
        _show!(v, pd, GUI._ViewOptions(; n = 30, profiles = true))
        @test maximum(Rect2f(v.profiles_ax.scene.viewport[]))[2] < minimum(Rect2f(v.bar_ax.scene.viewport[]))[2]
        @test GUI._view_size(v)[2] - h_profiles ≈ h_bar - h_none atol = 1
        _show!(v, pd, GUI._ViewOptions(; n = 30))
        @test v.bar_shown && GUI._view_size(v)[2] ≈ h_bar

        # profiles of a field, below the axis
        @test !v.profiles_shown && !v.profiles_ax.blockscene.visible[]
        h = GUI._view_size(v)[2]
        _show!(v, pd, GUI._ViewOptions(; n = 30, profiles = true))
        @test v.profiles_shown && v.profiles_ax.blockscene.visible[] && v.profiles_toggle.active[]
        @test GUI._view_size(v)[2] > h + GUI._VIEW_PROFILES_HEIGHT
        @test length(v.profile_x[1][]) == 30 && length(v.profile_z[1][]) == 30
        # with the profiles, the plot shows the centroid and a dashed line along each cut, in the
        # color of its profile, between the image and the centroid
        c = only(v.crosses[2][1][])
        @test only(v.crosses[1][1][]) == c
        x0, x1, z0, z1 = _limits(v.ax)
        @test v.cut_x[1][] ≈ [Point2f(x0, c[2]), Point2f(x1, c[2])]
        @test v.cut_z[1][] ≈ [Point2f(c[1], z0), Point2f(c[1], z1)]
        for (cut, profile) in ((v.cut_x, v.profile_x), (v.cut_z, v.profile_z))
            a, b = Makie.to_color(cut.color[]), Makie.to_color(profile.color[])
            @test RGBf(a) == RGBf(b) && Makie.alpha(a) == GUI._VIEW_CUT_ALPHA
        end
        @test v.cut_x.linestyle[] != v.profile_x.linestyle[]
        @test v.images[2].transformation.translation[][3] < v.cut_x.transformation.translation[][3] <
              v.crosses[2].transformation.translation[][3]
        # the lines follow the limits
        GUI._view_limits!(v.ax, (x0 / 2, x1 / 2, z0 / 2, z1 / 2))
        x0, x1, z0, z1 = _limits(v.ax)
        @test v.cut_x[1][] ≈ [Point2f(x0, c[2]), Point2f(x1, c[2])]
        @test v.cut_z[1][] ≈ [Point2f(c[1], z0), Point2f(c[1], z1)]
        # and leave with the profiles
        _show!(v, pd, GUI._ViewOptions(; n = 30))
        @test all(p -> isempty(p[1][]), v.crosses) && isempty(v.cut_x[1][]) && isempty(v.cut_z[1][])
        _show!(v, pd, GUI._ViewOptions(; n = 30, profiles = true))
        @test !isempty(v.cut_x[1][])
        _show!(v, pd, GUI._ViewOptions(; n = 30, kind = :spot, profiles = true))
        @test !v.profiles_shown && GUI._view_size(v)[2] <= h + 1
        # a spot diagram keeps the centroid, without the lines
        @test length(v.crosses[2][1][]) == 1 && isempty(v.cut_x[1][]) && isempty(v.cut_z[1][])
        # a spot diagram has no colorbar
        @test !v.bar_shown && !v.bar_ax.blockscene.visible[]

        # the picture is drawn
        @test Makie.colorbuffer(fig) isa AbstractMatrix

        # a view that starts collapsed
        _, _, w = _host(; floating, expanded = false, width = 300, height = 200)
        @test !w.expanded && GUI._view_size(w)[2] ≈ GUI._THUMB_SIZE
        GUI._set_expanded!(w, true)
        @test Makie.widths(w.ax.scene.viewport[]) == Vec2(300, 200)
    end

    @testset "results in the widget" begin
        fig, _, v = _host()
        options, expanded, _ = _connect!(fig, v)
        rays, gauss = _rays(), _gauss()

        # rays: the spots in the text color of the theme, texts without a glow
        _show!(v, rays)
        @test v.switch.keys == [:spot, :psf] && v.switch.selected[] == :spot
        @test v.spots[2].visible[] && !v.images[2].visible[] && length(v.spots[2][1][]) == 40
        @test v.xlabels.glowwidth[] == 0 && !v.fields_shown
        @test only(v.frames[2][3][]).alpha == 0
        @test startswith(v.metrics_label.text[], "N = 40")
        @test v.kind_label.text[] == "Spot" && startswith(v.info_label.text[], "N = 40\nc = (")
        # the limits hold all spots
        x0, x1, z0, z1 = _limits(v.ax)
        @test all(q -> x0 < q[1] < x1 && z0 < q[2] < z1, v.xy)

        # the PSF, normalized: white texts with a glow, a logarithmic scale, a fixed color range
        o = GUI._ViewOptions(; kind = :psf, n = 20)
        _show!(v, rays, o)
        @test v.switch.selected[] == :psf && v.images[2].visible[] && !v.spots[2].visible[]
        @test maximum(v.images[2][3][]) ≈ 1
        @test collect(v.images[2].colorrange[]) ≈ [0, 1]
        @test v.xlabels.glowwidth[] == 2 && v.fields_shown
        # the frame beside the image has the lowest color of the colormap, in front of the host
        @test only(v.frames[2][3][]) == RGBAf(first(Makie.to_colormap(:viridis)))
        @test 0 < v.frames[2].transformation.translation[][3] < v.images[2].transformation.translation[][3]
        x0, x1, z0, z1 = _limits(v.ax)
        @test collect(v.frames[2][1][]) ≈ [x0, x1] && collect(v.frames[2][2][]) ≈ [z0, z1]
        @test startswith(v.metrics_label.text[], "PSF")
        @test startswith(v.info_label.text[], "normalized\nc = (")
        r = GUI._view_result(rays, o)
        GUI._show_result!(v, "PD", r, GUI._ViewOptions(o; colorscale = :log))
        @test v.log_toggle.active[]
        @test collect(v.images[2].colorrange[]) ≈ [-4, 0]
        @test v.images[2][3][] ≈ log10.(max.(r.data[3], 1e-4))
        # the colorbar of the PSF: its decades on the logarithmic scale, no unit of an intensity
        @test collect(_limits(v.bar_ax)) ≈ [-4, 0, 0, 1] && v.bar_unit.text[] == "rel."
        @test v.bar_ax.xticks[] == ([-4.0, -3.0, -2.0, -1.0, 0.0], ["10⁻⁴", "10⁻³", "10⁻²", "10⁻¹", "10⁰"])
        GUI._show_result!(v, "PD", r, GUI._ViewOptions(o; colorscale = :linear))
        @test v.images[2][3][] ≈ r.data[3] && collect(v.images[2].colorrange[]) ≈ [0, 1]
        @test collect(_limits(v.bar_ax)) ≈ [0, 1, 0, 1] && v.bar_ax.xticks[] === GUI._VIEW_BAR_TICKS
        GUI._show_result!(v, "PD", r, GUI._ViewOptions(o; colorrange = (0, 5)))
        @test collect(v.images[2].colorrange[]) == [0, 5] && !v.log_toggle.active[]
        @test collect(_limits(v.bar_ax)) ≈ [0, 5, 0, 1]
        # showing a result never reports an option
        @test isempty(options)

        # nothing is updated if nothing changed
        GUI._show_result!(v, "PD", r, o)
        v.metrics_label.text[] = "kept"
        GUI._show_result!(v, "PD", r, o)
        @test v.metrics_label.text[] == "kept"
        GUI._show_result!(v, "PD", r, GUI._ViewOptions(o; colorscale = :log))
        @test startswith(v.metrics_label.text[], "PSF")

        # the limits of a field: the extent of its samples, or its window
        wide = GUI._ViewOptions(; n = 20, kwargs = (; x_min = -2.5e-3, x_max = 2.5e-3, z_min = -2.5e-3, z_max = 2.5e-3))
        _show!(v, gauss, wide)
        @test collect(_limits(v.ax)) ≈ [-2.5, 2.5, -2.5, 2.5]
        # the logarithmic scale of an intensity has a floor relative to its peak
        _show!(v, gauss, GUI._ViewOptions(wide; colorscale = :log))
        I = GUI._view_result(gauss, wide).data[3]
        @test minimum(v.images[2][3][]) ≈ log10(1e-4 * maximum(I))
        @test collect(v.images[2].colorrange[]) ≈ [log10(1e-4 * maximum(I)), log10(maximum(I))]
        # equal scales: the frame shows at least the samples
        _show!(v, rays, o)
        x, z, _ = GUI._view_result(rays, o).data
        x0, x1, z0, z1 = _limits(v.ax)
        @test [z0, z1] ≈ 1e3 .* [first(z), last(z)] && x0 <= 1e3 * first(x) && x1 >= 1e3 * last(x)
        @test x1 - x0 ≈ z1 - z0
        w = (-1e-3, 1e-3, -1e-3, 1e-3)
        _show!(v, rays, GUI._ViewOptions(o; window = w))
        @test collect(_limits(v.ax)) ≈ [-1, 1, -1, 1]
        @test collect(_limits(v.thumb_ax)) ≈ [-1, 1, -1, 1]

        # a beamlet: other kinds, the stored choice :psf falls back to the intensity
        _show!(v, gauss, o)
        @test v.switch.keys == [:intensity, :spot] && v.switch.selected[] == :intensity
        @test length(v.switches) == 2
        @test startswith(v.metrics_label.text[], "P = ")
        # ... and applies again with rays, with the switch built before
        _show!(v, rays, o)
        @test v.switch.keys == [:spot, :psf] && v.switch.selected[] == :psf
        @test length(v.switches) == 2
        @test v.switch.buttons[1].blockscene.visible[]
        @test !first(v.switches[(:intensity, :spot)].buttons).blockscene.visible[]

        # a coarse result and a result of a preview solve
        _show!(v, rays, o; coarse = true)
        @test v.kind_label.text[] == "PSF (preview)" && v.status.text[] == ["preview"]
        _show!(v, rays; preview = true)
        @test v.kind_label.text[] == "Spot (preview)"
        _show!(v, rays)
        @test v.kind_label.text[] == "Spot" && v.status.text[] == [""]

        # no hits: no plots, no switch
        _show!(v, Detector(1e-3))
        @test v.kind_label.text[] == "no hits" && v.metrics_label.text[] == "no hits"
        @test isnothing(v.switch) && isnothing(v.kind)
        @test !v.spots[2].visible[] && !v.images[2].visible[] && isempty(v.crosses[2][1][])
        @test isempty(v.xlabels.text[]) && !v.xname.visible[] && v.status.text[] == ["no hits"]
        @test !first(v.switches[(:spot, :psf)].buttons).blockscene.visible[]
        # the wheel does nothing without a result
        lims = _limits(v.ax)
        _move!(fig, _center(v.ax))
        _scroll!(fig, 1)
        @test _limits(v.ax) == lims
        GUI._show_result!(v, "PD", nothing, o)
        @test v.metrics_label.text[] == "no result"

        # an error: shown and logged once, the switch stays for another choice
        bad = GUI._ViewOptions(; kwargs = (; crop_factor = "wide"))
        @test_logs (:error,) match_mode = :any _show!(v, gauss, bad)
        @test v.metrics_label.text[] == "error" && v.kind_label.text[] == "error"
        @test v.switch.keys == [:intensity, :spot] && !v.images[2].visible[]
        @test_logs _show!(v, gauss, bad)
        _show!(v, gauss, GUI._ViewOptions(; n = 20))
        @test startswith(v.metrics_label.text[], "P = ") && v.images[2].visible[]

        # a single ray: limits around it
        pd = Detector(25e-3)
        translate3d!(pd, [0, 0.05, 0])
        solve_system!(System([pd]), Beam([0.0, 0, 0], [0.0, 1, 0]))
        _show!(v, pd)
        x0, x1, z0, z1 = _limits(v.ax)
        @test x1 - x0 ≈ 2e-3 && z1 - z0 ≈ 2e-3 && x0 < v.xy[1][1] < x1
        @test isempty(options) && isempty(expanded)
    end

    @testset "texts inside the frame" begin
        fig, _, v = _host()
        gauss, rays = _gauss(), _rays()
        for (pd, o) in ((gauss, GUI._ViewOptions(; n = 30)), (rays, GUI._ViewOptions()),
                (rays, GUI._ViewOptions(; kind = :psf, n = 20, window = (-0.012345, 0.023456, -0.01, 0.02559))))
            _show!(v, pd, o; preview = true)
            for size in (160, 400)
                GUI._resize_view!(v, size, size)
                boxes = _text_boxes(v)
                # the names of the axes, the status and at least a tick label per axis
                @test v.xname.text[] == ["x [mm]"] && v.zname.text[] == ["z [mm]"]
                @test v.status.text[] == ["preview"]
                @test !isempty(v.xlabels.text[]) && !isempty(v.zlabels.text[])
                @test length(boxes) == 3 + length(v.xlabels.text[]) + length(v.zlabels.text[])
                @test length(v.boxes) == length(boxes)
                # no two texts overlap, all lie inside the frame
                @test !_any_overlap(boxes)
                @test all(b -> all(minimum(b) .>= 0) && all(maximum(b) .<= size), boxes)
                # the labels sit at the bottom and at the right edge of the limits
                x0, x1, z0, z1 = _limits(v.ax)
                @test all(q -> q[2] ≈ z0 && x0 < q[1] < x1, v.xlabels.positions[])
                @test all(q -> q[1] ≈ x1 && z0 < q[2] < z1, v.zlabels.positions[])
                # the ticks of the axis are those of the labels
                ticks = first(Makie.get_ticks(v.ax.xticks[], identity, Makie.Automatic(), x0, x1))
                @test first.(v.xlabels.positions[]) ⊆ ticks
            end
        end
        @test v.ax.xtickalign[] == 1 && v.ax.ytickalign[] == 1
        @test !v.ax.xticklabelsvisible[] && !v.ax.yticklabelsvisible[]
        @test !v.ax.xgridvisible[] && !v.ax.ygridvisible[]

        # the texts follow zoom and pan
        _connect!(fig, v)
        _show!(v, gauss, GUI._ViewOptions(; n = 30))
        before = copy(v.xlabels.positions[])
        _move!(fig, _center(v.ax) .+ Point2f(40, 30))
        _scroll!(fig, 3)
        x0, x1, z0, z1 = _limits(v.ax)
        @test v.xlabels.positions[] != before
        @test all(q -> q[2] ≈ z0 && x0 < q[1] < x1, v.xlabels.positions[])
        @test v.xname.positions[] ≈ [Point2(x0, z0)] && v.zname.positions[] ≈ [Point2(x1, z1)]
        @test !_any_overlap(_text_boxes(v))
    end

    @testset "mouse ($(floating ? "pixel scene" : "figure"))" for floating in (false, true)
        fig, ls, v = _host(; floating)
        options, expanded, listeners = _connect!(fig, v)
        @test length(listeners) == 3
        camera = cameracontrols(ls.scene)
        eye = copy(camera.eyeposition[])
        gauss, rays = _gauss(), _rays()
        o = GUI._ViewOptions(; n = 20)
        _show!(v, gauss, o)

        # the wheel over the axis zooms about the cursor and leaves the camera of the 3D view
        lims = _limits(v.ax)
        p = _center(v.ax) .+ Point2f(70, -35)
        at(lims) = (lims[1] + (0.5 + 70 / 280) * (lims[2] - lims[1]), lims[3] + (0.5 - 35 / 280) * (lims[4] - lims[3]))
        _move!(fig, p)
        _scroll!(fig, 1)
        zoomed = _limits(v.ax)
        @test zoomed != lims
        @test zoomed[2] - zoomed[1] ≈ 0.9 * (lims[2] - lims[1])
        @test collect(at(zoomed)) ≈ collect(at(lims))
        @test camera.eyeposition[] == eye
        # a field is asked for the window that is shown [m]
        @test length(options) == 1 && first(options[1]) == :window
        @test collect(last(options[1])) ≈ 1e-3 .* collect(zoomed)
        _scroll!(fig, -1)
        @test collect(_limits(v.ax)) ≈ collect(lims)
        @test length(options) == 2
        # the host shows the result with the window: the limits stay
        _show!(v, gauss, GUI._ViewOptions(o; window = last(options[1])))
        @test collect(_limits(v.ax)) ≈ collect(zoomed)

        # a drag with the right button pans, the window is reported when the button is released
        empty!(options)
        _move!(fig, _center(v.ax))
        _button!(fig, Mouse.press, Mouse.right)
        _move!(fig, _center(v.ax) .+ Point2f(28, -14))
        panned = _limits(v.ax)
        w = zoomed[2] - zoomed[1]
        @test collect(panned) ≈ collect(zoomed) .+ [-0.1w, -0.1w, 0.05w, 0.05w]
        @test isempty(options)
        # the left button does not select meanwhile
        _button!(fig, Mouse.press)
        _button!(fig, Mouse.release)
        @test isnothing(v.select) && !isnothing(v.drag) && isempty(options)
        _button!(fig, Mouse.release, Mouse.right)
        @test length(options) == 1 && collect(last(options[1])) ≈ 1e-3 .* collect(panned)
        @test isnothing(v.drag)
        _move!(fig, _center(v.ax) .+ Point2f(50, 50))
        @test _limits(v.ax) == panned
        @test camera.eyeposition[] == eye

        # a drag with the left button selects the rectangle to zoom to: the larger side of the drag
        # sets its size, its shape is that of the frame of 280 px
        empty!(options)
        w, h = panned[2] - panned[1], panned[4] - panned[3]
        a = _center(v.ax) .+ Point2f(-70, -70)
        _move!(fig, a)
        _button!(fig, Mouse.press)
        @test v.select == a && !v.select_line.visible[] && !v.select_fill.visible[]
        _move!(fig, a .+ Point2f(56, 28))
        @test v.select_line.visible[] && v.select_fill.visible[]
        @test collect(GUI._selection(v, a .+ Point2f(56, 28))) ≈
              [panned[1] + 0.25w, panned[1] + 0.45w, panned[3] + 0.25h, panned[3] + 0.45h]
        corners = v.select_line[1][]
        @test corners[1] ≈ Point2f(panned[1] + 0.25w, panned[3] + 0.25h) && corners[3] ≈ Point2f(panned[1] + 0.45w, panned[3] + 0.45h)
        # the right button does not pan meanwhile, and the limits stay until the release
        _button!(fig, Mouse.press, Mouse.right)
        _button!(fig, Mouse.release, Mouse.right)
        @test isnothing(v.drag) && _limits(v.ax) == panned && isempty(options)
        _button!(fig, Mouse.release)
        selected = _limits(v.ax)
        @test collect(selected) ≈ [panned[1] + 0.25w, panned[1] + 0.45w, panned[3] + 0.25h, panned[3] + 0.45h]
        @test isnothing(v.select) && !v.select_line.visible[] && !v.select_fill.visible[]
        @test length(options) == 1 && collect(last(options[1])) ≈ 1e-3 .* collect(selected)
        @test camera.eyeposition[] == eye
        # towards the bottom left, also beyond the frame
        v.select = a
        w, h = selected[2] - selected[1], selected[4] - selected[3]
        @test collect(GUI._selection(v, a .+ Point2f(-14, -112))) ≈
              [selected[1] - 0.15w, selected[1] + 0.25w, selected[3] - 0.15h, selected[3] + 0.25h]
        v.select = nothing
        # a selection of less than 4 px does not zoom
        empty!(options)
        _move!(fig, a .+ Point2f(40, 40))
        _button!(fig, Mouse.press)
        _move!(fig, a .+ Point2f(43, 38))
        _button!(fig, Mouse.release)
        @test _limits(v.ax) == selected && isempty(options) && !v.select_line.visible[]

        # "fit", a double click and Ctrl + click ask for the automatic window
        _show!(v, gauss, GUI._ViewOptions(o; window = 1e-3 .* selected))
        empty!(options)
        v.fit_button.clicks[] += 1
        @test options == Any[:window => nothing]
        _show!(v, gauss, o)
        @test collect(_limits(v.ax)) ≈ collect(lims)
        _show!(v, gauss, GUI._ViewOptions(o; window = (-1e-4, 1e-4, -1e-4, 1e-4)))
        empty!(options)
        _move!(fig, _center(v.ax))
        for _ in 1:2
            _button!(fig, Mouse.press)
            _button!(fig, Mouse.release)
        end
        @test options == Any[:window => nothing]
        empty!(options)
        _ctrl!(fig, Keyboard.press)
        _button!(fig, Mouse.press)
        @test options == Any[:window => nothing] && isnothing(v.select)
        _button!(fig, Mouse.release)
        _ctrl!(fig, Keyboard.release)
        @test length(options) == 1

        # a spot diagram: zoom changes only the limits, which stay over new results until "fit"
        empty!(options)
        _show!(v, rays)
        lims = _limits(v.ax)
        _move!(fig, _center(v.ax))
        _scroll!(fig, 2)
        zoomed = _limits(v.ax)
        @test zoomed[2] - zoomed[1] ≈ 0.81 * (lims[2] - lims[1])
        @test isempty(options) && v.zoomed
        _show!(v, rays)
        @test _limits(v.ax) == zoomed
        v.fit_button.clicks[] += 1
        @test collect(_limits(v.ax)) ≈ collect(lims) && !v.zoomed && isempty(options)

        # outside of the axis, the wheel and the mouse pass
        lims = _limits(v.ax)
        _move!(fig, Point2f(maximum(Rect2f(v.ax.scene.viewport[]))) .+ Point2f(20, 0))
        _scroll!(fig, 1)
        for button in (Mouse.left, Mouse.right)
            _button!(fig, Mouse.press, button)
            _button!(fig, Mouse.release, button)
        end
        @test _limits(v.ax) == lims && isnothing(v.drag) && isnothing(v.select)

        # the switch, the toggles and the chevrons
        v.switch.buttons[2].clicks[] += 1
        @test options == Any[:kind => :psf]
        _show!(v, rays, GUI._ViewOptions(; kind = :psf, n = 20))
        empty!(options)
        v.log_toggle.active[] = true
        v.profiles_toggle.active[] = true
        v.bar_toggle.active[] = false
        @test options == Any[:colorscale => :log, :profiles => true, :colorbar => false]
        pop!(options)
        v.log_toggle.active[] = false
        @test last(options) == (:colorscale => :linear)
        v.collapse_button.clicks[] += 1
        @test expanded == [false]

        # a thumbnail does not zoom; a click on it or on its chevron expands the view
        GUI._set_expanded!(v, false)
        empty!(options)
        thumb, lims = _limits(v.thumb_ax), _limits(v.ax)
        _move!(fig, _center(v.thumb_ax))
        _scroll!(fig, 1)
        @test _limits(v.thumb_ax) == thumb && _limits(v.ax) == lims && isempty(options)
        _button!(fig, Mouse.press)
        _move!(fig, _center(v.thumb_ax) .+ Point2f(5, 5))
        _button!(fig, Mouse.release)
        @test expanded == [false, true]
        @test _limits(v.thumb_ax) == thumb
        v.expand_button.clicks[] += 1
        @test expanded == [false, true, true]
        # the widget does not change its state itself
        @test !v.expanded

        # deleted: no listeners, no blocks
        GUI._set_expanded!(v, true)
        GUI._delete_view!(v)
        @test isempty(v.listeners) && isempty(v.grid.content) && isempty(v.switches)
        _move!(fig, _center(v.ax))
        _scroll!(fig, 1)
        @test isempty(options)
        @test Makie.colorbuffer(fig) isa AbstractMatrix
    end

    @testset "switch of a collapsed view" begin
        # the switch is built into the header, which a collapsed view has not laid out
        fig, _, v = _host(; expanded = false)
        options, _, _ = _connect!(fig, v)
        _show!(v, _gauss())
        @test isnothing(v.last_error) && isnothing(v.switch)
        @test v.kind_label.text[] == "Intensity"
        GUI._set_expanded!(v, true)
        @test v.switch.keys == [:intensity, :spot] && v.switch.selected[] == :intensity
        @test isempty(options)
        # other kinds while it is collapsed again
        GUI._set_expanded!(v, false)
        _show!(v, _rays())
        @test isnothing(v.last_error) && v.switch.keys == [:intensity, :spot]
        GUI._set_expanded!(v, true)
        @test v.switch.keys == [:spot, :psf] && v.switch.selected[] == :spot && isempty(options)
    end

    @testset "the wheel beside the view moves the camera" begin
        # the reference of the tests above: the camera of the 3D view does react to the wheel
        fig, ls, v = _host(; floating = true)
        _connect!(fig, v)
        _show!(v, _rays())
        camera = cameracontrols(ls.scene)
        eye = copy(camera.eyeposition[])
        _move!(fig, Point2f(maximum(Rect2f(v.ax.scene.viewport[]))) .+ Point2f(60, -60))
        @test Makie.is_mouseinside(ls.scene)
        _scroll!(fig, 1)
        @test camera.eyeposition[] != eye
    end
end

end
