module TestLiveSources

using GLMakie, BeamletOptics, BeamletOpticsGUI
using BeamletOptics: render_children, render_plots, rendered
using Makie
using LinearAlgebra: norm, normalize, dot, cross
using Test

const BMO = BeamletOptics
const GUI = BeamletOpticsGUI

@testset "Live sources" begin

    # Each change is solved at once, see `TestLiveView.jl`; no card of a detector is pinned at start
    _live_view(args...; kwargs...) =
        live_view(args...; merge((; trace_budget = Inf, throttle = false, detectors = []), kwargs)...)

    _key!(gui, key) = (events(gui.ax.scene).keyboardbutton[] = Makie.KeyEvent(key, Keyboard.press))

    _beam(x = 0.0) = Beam([x, 0, 0], [0.0, 1, 0], 632.8e-9)

    # A mirror on a beam along +y at `x`, which it reflects along +x
    function _mirror(y = 0.1; x = 0.0)
        m = RoundPlanoMirror(25e-3, 5e-3)
        zrotate3d!(m, deg2rad(45))
        translate3d!(m, [x, y, 0])
        return m
    end

    _in(obj, list) = any(o -> o === obj, list)
    _handle(gui, obj) = GUI._child_handle(gui.controls.h, obj)
    _paired(gui, src) = any(p -> p.second === src, gui.pairs)
    # The object that the first ray of the beam ends on, `nothing` for an untraced beam
    function _target(beam)
        isect = BMO.intersection(first(BMO.rays(beam)))
        return isnothing(isect) ? nothing : BMO.object(isect)
    end
    # The number of hits of the detector, which has no list of hits before its first one
    _nhits(pd) = (hits = BMO.hits(pd); isnothing(hits) ? 0 : length(hits))
    _listed(gui::GUI.AppView, obj) = _in(obj, [r.key for r in GUI._tree_rows(gui)])
    _listed(gui, obj) = _in(obj, gui.objects.menu)
    _card(gui::GUI.AppView) = gui.layout.inspector.card
    _card(gui) = gui.cards.selection
    _message(f) = try
        f()
        ""
    catch e
        e isa ArgumentError ? e.msg : rethrow()
    end

    @testset "a view without a source, $layout" for layout in (:compact, :app)
        sys = System()
        gui = _live_view(sys; layout)
        @test isempty(gui.pairs) && isempty(gui.beam_handles)
        @test GUI._systems(gui) == [sys]
        @test isnothing(gui.trace.error)
        @test gui.status.text[] == GUI._NO_SOURCE
        @test occursin("1 systems, 0 sources", sprint(show, gui))
        @test occursin("0 rays", GUI._status_info(gui))

        # a source, then a component: the beam is traced through it
        src = _beam()
        @test add_component!(gui, src) === src
        m = _mirror()
        add_component!(gui, m)
        @test _target(src) === m
        @test isnothing(gui.trace.error) && !gui.trace.stale
        close(gui)
    end

    # The object tree of the app layout has no row with an eye in an empty view, which the backend
    # must draw as well
    @testset "an empty view in a window, $layout" for layout in (:compact, :app)
        gui = _live_view(System(); layout)
        screen = GLMakie.Screen(visible = false)
        src = _beam()
        # no error is thrown or logged while the window draws the view
        @test_logs min_level = Base.CoreLogging.Error begin
            display(screen, gui.fig)
            Makie.colorbuffer(screen)
            # a source, a component and back to an empty view, in the open window
            add_component!(gui, src)
            Makie.colorbuffer(screen)
            m = _mirror()
            add_component!(gui, m)
            Makie.colorbuffer(screen)
            remove_component!(gui, m)
            remove_component!(gui, src)
            Makie.colorbuffer(screen)
        end
        @test isempty(gui.pairs) && isempty(only(GUI._systems(gui)).objects)
        close(screen)
        close(gui)
    end

    @testset "several systems, some without a source" begin
        a, b, c = System(), System([_mirror()]), System()
        beam = _beam()
        gui = _live_view(a, b => beam, c)
        @test GUI._systems(gui) == [a, b, c]
        @test length(gui.pairs) == 1 && only(gui.pairs).first === b
        close(gui)
        # two systems are not a system and its beam
        gui = _live_view(a, c)
        @test GUI._systems(gui) == [a, c] && isempty(gui.pairs)
        close(gui)
        gui = _live_view(a, b => beam)
        @test GUI._systems(gui) == [a, b] && length(gui.pairs) == 1
        close(gui)
        @test_throws ArgumentError live_view()
    end

    @testset "add, $layout" for layout in (:compact, :app)
        m = _mirror()
        sys = System([m])
        first_beam = _beam(0.2)
        gui = _live_view(sys => first_beam; layout)
        nplots = length(gui.ax.scene.plots)

        src = _beam()
        @test add_component!(gui, src; label = "laser") === src
        @test _paired(gui, src) && last(gui.pairs).first === sys
        @test length(gui.beam_handles) == length(gui.pairs) == 2
        @test rendered(last(gui.beam_handles)) === src
        # its marker is a child of the handle of the controls: it is selected and moved by it
        @test !isnothing(_handle(gui, src))
        @test _in(src, gui.controls.movable)
        @test gui.controls.init_poses[src] == GUI._pose(src)
        @test GUI._label(gui, src) == "laser"
        @test gui.controls.selected[] === src
        @test _listed(gui, src)
        # traced through the system
        @test _target(src) === m
        @test isnothing(gui.trace.error) && !gui.trace.stale
        @test gui.components.added == [src] && isempty(gui.components.removed)
        @test gui.components.system[src] === sys && isnothing(gui.components.origin[src])
        @test occursin("2 rays", GUI._status_info(gui))

        # a beam group without a label: named by its type, not selected, rendered like the groups
        # of the start
        group = UniformDiscSource([0.0, 0, 0], [0.0, 1, 0], 5e-3, 532e-9; num_rays = 20)
        add_component!(gui, group; select = false)
        @test gui.controls.selected[] === src
        @test GUI._label(gui, group) == "CollimatedSource 1"
        @test gui.beams.kwargs[group].render_every == 5
        # solved as a preview like a moved group: its rendered beams, the others when the view rests
        @test _target(first(BMO.beams(group))) === m && gui.trace.preview
        GUI._resolve!(gui, nothing)
        @test all(b -> _target(b) === m, BMO.beams(group))
        # the kwargs of `live_render!` of the beam
        other = UniformDiscSource([0.0, 0, 0], [0.0, 1, 0], 5e-3, 532e-9; num_rays = 20)
        add_component!(gui, other; select = false, beam_kwargs = (; render_every = 2, flen = 0.02))
        @test gui.beams.kwargs[other] ==
              (; render_every = 2, color = :wavelength, flen = 0.02)
        @test GUI._flen(gui, other) == 0.02

        # moved like the sources of the start: the beam follows
        GUI._change!(() -> translate3d!(src, [0, 0, 0.1]), gui.controls, src)
        gui.controls.on_change(src)
        @test isnothing(_target(src))

        # errors: the view stays as it is
        n = length(gui.pairs)
        @test occursin("already a source", _message(() -> add_component!(gui, src)))
        @test occursin("already a source", _message(() -> add_component!(gui, first_beam)))
        @test occursin("not shown", _message(() -> add_component!(gui, _beam(); system = System())))
        @test occursin("must be a system", _message(() -> add_component!(gui, _beam(); system = 1)))
        @test occursin("show_beams", _message(() ->
            add_component!(gui, _beam(); beam_kwargs = (; show_beams = true))))
        @test occursin("show_polarization", _message(() ->
            add_component!(gui, _beam(); beam_kwargs = (; show_polarization = true))))
        @test length(gui.pairs) == length(gui.beam_handles) == n
        close(gui)
        @test nplots > 0
    end

    @testset "color of the wavelength" begin
        # the color of a wavelength is the one of BeamletOptics
        color(λ) = Makie.RGBf(wavelength_color(λ)...)

        # added sources and the sources of the start are drawn in the colors of their wavelengths:
        # the setting of their handles, which draw one color per vertex
        first_beam = _beam(0.2)
        gui = _live_view(System([_mirror()]) => first_beam)
        _main_handle(src) = gui.beam_handles[findfirst(p -> p.second === src, gui.pairs)]
        _colors(src) = [c for p in GUI._beam_plots(_main_handle(src)) for c in Makie.to_color(p.color[])]
        _is(c, ref) = Makie.RGBf(c) ≈ Makie.RGBf(ref)
        @test BMO.render_settings(_main_handle(first_beam)).color === :wavelength
        @test !isempty(_colors(first_beam)) && all(c -> _is(c, color(632.8e-9)), _colors(first_beam))
        @test GUI._color_preset(gui, first_beam) == "wavelength"
        green = Beam([0.0, 0, 0], [0.0, 1, 0], 532e-9)
        add_component!(gui, green)
        @test !isempty(_colors(green)) && all(c -> _is(c, color(532e-9)), _colors(green))
        @test BMO.render_settings(_main_handle(green)).color === :wavelength
        @test GUI._color_preset(gui, green) == "wavelength"
        group = UniformDiscSource([0.0, 0, 0], [0.0, 1, 0], 5e-3, 450e-9; num_rays = 20)
        add_component!(gui, group)
        @test all(c -> _is(c, color(450e-9)), _colors(group))
        gauss = GaussianBeamlet([0.0, 0, 0], [0.0, 1, 0], 632.8e-9, 1e-3)
        add_component!(gui, gauss)
        @test gui.beams.kwargs[gauss].color === :wavelength
        @test !isempty(_colors(gauss)) && all(c -> _is(c, color(632.8e-9)), _colors(gauss))
        # the color is kept with another length of the final rays, and `beam_kwargs` set another one
        GUI._set_flen!(gui, green, 0.05)
        @test all(c -> _is(c, color(532e-9)), _colors(green))
        other = Beam([0.0, 0, 0], [0.0, 1, 0], 532e-9)
        add_component!(gui, other; beam_kwargs = (; color = :black))
        @test all(c -> _is(c, Makie.to_color(:black)), _colors(other))
        @test GUI._color_preset(gui, other) == "black"
        close(gui)

        # a group of astigmatic beamlets as well, as a source of the start and as an added one
        astigmatic() = SphericalGaussianBeamletSource([0.0, 0, 0], [0.0, 1, 0], deg2rad(2), 532e-9;
            num_rings = 2, num_rays = 40)
        first_group, added = astigmatic(), astigmatic()
        gui = _live_view(System([_mirror()]) => first_group)
        add_component!(gui, added)
        for src in (first_group, added)
            @test BMO.render_settings(_main_handle(src)).color === :wavelength
            @test GUI._color_preset(gui, src) == "wavelength"
        end
        close(gui)
    end

    @testset "overlays of an added source" begin
        gui = _live_view(System([_mirror()]) => _beam(0.2))
        gauss = GaussianBeamlet([0.0, 0, 0], [0.0, 1, 0], 632.8e-9, 1e-3)
        add_component!(gui, gauss; beam_kwargs = (; show_beams = true))
        @test haskey(gui.beams.gen, gauss)
        pol = Beam([0.01, 0, 0], [0.0, 1, 0], 632.8e-9, [1.0, 0, 0])
        add_component!(gui, pol; beam_kwargs = (; show_polarization = true))
        @test haskey(gui.beams.pol, pol)
        # removed with the source
        nplots = length(gui.ax.scene.plots)
        remove_component!(gui, gauss)
        remove_component!(gui, pol)
        @test isempty(gui.beams.gen) && isempty(gui.beams.pol)
        @test length(gui.ax.scene.plots) < nplots
        close(gui)
    end

    @testset "remove, $layout" for layout in (:compact, :app)
        m = _mirror()
        pd = Detector(20e-3)
        translate3d!(pd, [0.15, 0.1, 0])
        zrotate3d!(pd, deg2rad(90))
        sys = System([m, pd])
        first_beam = _beam()
        gui = _live_view(sys => first_beam; layout)
        nplots = length(gui.ax.scene.plots)
        nchildren = length(render_children(gui.controls.h))
        @test _nhits(pd) == 1

        src = _beam()
        add_component!(gui, src; label = "laser")
        @test _nhits(pd) == 2
        GUI._toggle_pin!(gui, src)
        @test GUI._is_pinned(gui, src)
        @test remove_component!(gui, src) === src
        @test !_paired(gui, src) && length(gui.pairs) == length(gui.beam_handles) == 1
        @test isnothing(_handle(gui, src)) && length(render_children(gui.controls.h)) == nchildren
        @test !_in(src, gui.controls.movable) && !haskey(gui.controls.init_poses, src)
        # all of its plots are gone: the beam, the marker, the card
        @test length(gui.ax.scene.plots) == nplots
        @test isnothing(gui.controls.selected[])
        @test !GUI._is_pinned(gui, src)
        @test !any(c -> c.pinned && c.obj === src, gui.cards.all)
        @test !_listed(gui, src)
        @test !haskey(gui.labels, src) && !haskey(gui.beams.kwargs, src)
        @test occursin("laser removed", gui.status.text[])
        # the detector lost its hits with the solve
        @test _nhits(pd) == 1
        @test isempty(gui.components.added) && isempty(gui.components.removed)
        # untraced, and added again like a new one
        @test length(BMO.rays(src)) == 1
        add_component!(gui, src)
        @test _target(src) === m && _nhits(pd) == 2
        remove_component!(gui, src)

        # twice, and a source that is not shown
        @test occursin("not a source", _message(() -> remove_component!(gui, src)))
        @test occursin("not a source", _message(() -> remove_component!(gui, _beam())))

        # the last source: the view stays, the detectors are empty
        remove_component!(gui, first_beam)
        @test isempty(gui.pairs) && isempty(gui.beam_handles)
        @test _nhits(pd) == 0
        @test isnothing(gui.trace.error)
        @test occursin(GUI._NO_SOURCE, gui.status.text[])
        @test gui.components.removed == [first_beam]
        @test gui.components.source_systems[first_beam] == [sys]
        @test GUI._label(gui, first_beam) == "Beam 1"
        # a component without a source, then a new source
        m2 = _mirror(0.2; x = 0.3)
        add_component!(gui, m2)
        new = _beam(0.3)
        add_component!(gui, new)
        @test _target(new) === m2
        # the source of the start, added again to its system, is no change
        add_component!(gui, first_beam)
        @test isempty(gui.components.removed) && gui.components.added == [m2, new]
        @test _target(first_beam) === m && _nhits(pd) == 1
        close(gui)
    end

    @testset "a source of several systems" begin
        a, b = System([_mirror()]), System([_mirror(0.2)])
        beam = _beam()
        gui = _live_view(a => beam, b => beam)
        remove_component!(gui, beam)
        @test isempty(gui.pairs) && isempty(gui.beam_handles)
        @test gui.components.source_systems[beam] == [a, b]
        # added to one of them: a change
        add_component!(gui, beam; system = b)
        @test gui.components.removed == [beam] && gui.components.added == [beam]
        @test gui.components.system[beam] === b
        code, n = GUI._export_code(gui)
        @test n == 2
        @test occursin("removed", code) && occursin("solve_system!(system2, ", code)
        close(gui)
    end

    @testset "manual tracing" begin
        m = _mirror()
        gui = _live_view(System([m]) => _beam(0.2); auto_trace = false)
        src = _beam()
        add_component!(gui, src)
        @test gui.trace.stale
        @test isnothing(_target(src))
        GUI._trace!(gui)
        @test _target(src) === m && !gui.trace.stale
        remove_component!(gui, src)
        @test gui.trace.stale
        close(gui)
    end

    @testset "target system and StaticSystem" begin
        m = _mirror()
        static = StaticSystem([m])
        gui = _live_view(static => _beam(0.2))
        # a source does not change its system
        src = _beam()
        add_component!(gui, src)
        @test last(gui.pairs).first === static && _target(src) === m
        close(gui)

        a, b = System([_mirror()]), System([_mirror(0.2; x = 0.1)])
        gui = _live_view(a => _beam(), b => _beam(0.1))
        src = _beam(0.1)
        add_component!(gui, src; system = b)
        @test last(gui.pairs).first === b
        @test _target(src) === only(b.objects)
        # without `system`: the system of the selection, here of the source
        other = _beam()
        add_component!(gui, other)
        @test last(gui.pairs).first === b
        close(gui)
    end

    @testset "markers" begin
        # also in a view without movable sources, whose sources of the start have no marker
        first_beam = _beam(0.2)
        gui = _live_view(System([_mirror()]) => first_beam; movable_sources = false)
        @test isnothing(_handle(gui, first_beam))
        src = _beam()
        add_component!(gui, src)
        @test !isnothing(_handle(gui, src)) && gui.controls.selected[] === src
        close(gui)

        # hidden with the markers of the other sources, and not selected then
        gui = _live_view(System([_mirror()]) => _beam(0.2); show_sources = false)
        src = _beam()
        add_component!(gui, src)
        @test all(p -> !p.visible[], render_plots(_handle(gui, src)))
        @test isnothing(gui.controls.selected[]) && isnothing(gui.objects.inspected)
        @test _target(src) === only(GUI._systems(gui)).objects[1]
        close(gui)
    end

    @testset "Delete and the card, $layout" for layout in (:compact, :app)
        m = _mirror()
        sys = System([m])
        beam, src = _beam(), _beam(0.01)
        gui = _live_view(sys => beam; layout)
        add_component!(gui, src)

        # "remove" of the card of a source: a row below the rows of `card_rows`
        @test length(GUI._card_rows(src)) == length(card_rows(src)) + 1
        @test last(last(GUI._card_rows(src)).cells).name === :remove
        GUI._update_selection_box!(gui.controls)
        GUI._update_cards!(gui)
        GUI._update_inspector!(gui)
        button = GUI._card_widget(_card(gui), :remove)
        @test button isa Button
        notify(button.clicks)
        @test !_paired(gui, src) && isnothing(gui.controls.selected[])

        # the key `Delete` removes the selected source, also the last one
        gui.controls.selected[] = beam
        _key!(gui, Keyboard.delete)
        @test isempty(gui.pairs) && isnothing(gui.controls.selected[])
        @test gui.components.removed == [beam]
        close(gui)
    end

    @testset "catalog, $layout" for layout in (:compact, :app)
        m = _mirror()
        sys = System([m])
        gui = _live_view(sys; layout)
        sources = [e for e in gui.components.catalog if e.source]
        @test [e.name for e in sources] == ["Beam", "Gaussian beamlet", "Collimated source",
            "Uniform disc source", "Point source", "Uniform point source", "Astigmatic Gaussian beamlet"]
        # "Place" of each entry with its defaults, then the drop: a source of the system
        for (k, entry) in enumerate(sources)
            src = GUI._place_catalog!(gui, entry, String[GUI._catalog_string(p) for p in entry.params])
            @test src isa Union{BMO.AbstractBeam, BMO.AbstractBeamGroup}
            @test GUI._placing(gui) && gui.components.placement.obj === src
            GUI._drop_placement!(gui)
            @test length(gui.pairs) == k && last(gui.pairs).second === src
            @test last(gui.pairs).first === sys
            @test isnothing(gui.trace.error)
            @test startswith(gui.components.origin[src].code, entry.code_name * "([0.0, 0.0, 0.0], [0.0, 1.0, 0.0], ")
            # it moves in all directions: the axes of the controls span the space, also for a beam
            # group, whose local x-axis points along the rotation axis
            y, x, v = GUI._control_axes(gui.controls, src)
            @test abs(dot(cross(y, x), v)) ≈ 1 atol = 1e-9
        end
        code, n = GUI._export_code(gui)
        @test n == length(sources)
        @test all(e -> occursin(" = $(e.code_name)([0.0, 0.0, 0.0], [0.0, 1.0, 0.0], ", code), sources)
        @test count("solve_system!(system, ", code) == length(sources)
        # an invalid input places nothing
        entry = sources[4]
        @test isnothing(GUI._place_catalog!(gui, entry, ["10", "632.8", "2.5"]))
        @test !GUI._placing(gui) && occursin("whole number", gui.status.text[])
        close(gui)
    end

    @testset "target of the catalog" begin
        # a source is traced through any system, a component needs a `System`: a view without one
        # only offers the sources
        m = _mirror()
        gui = _live_view(StaticSystem([m]))
        w = GUI._catalog_widget(GUI._catalog_window(gui))
        @test !isempty(gui.components.catalog) && all(e -> e.source, gui.components.catalog)
        @test all(e -> e.source, w.entries)
        @test GUI._catalog_entry(w).source
        @test w.target.text[] == "into: System 1"
        src = GUI._place_catalog!(gui, GUI._catalog_entry(w), ["632.8"])
        GUI._drop_placement!(gui)
        @test only(gui.pairs).second === src
        close(gui)
        # no catalog without sources among its entries
        gui = _live_view(StaticSystem([m]); catalog = [e for e in component_catalog() if !e.source])
        @test isnothing(GUI._catalog_window(gui))
        close(gui)
        # the second of two systems: the source follows the selection like a component
        a, b = System([_mirror()]), System([_mirror(0.2; x = 0.1)])
        gui = _live_view(a, b)
        w = GUI._catalog_widget(GUI._catalog_window(gui))
        menu = w.target_menu
        @test w.target.text[] == "into" && menu.selection[] == "System 1"
        GUI._inspect!(gui, b)
        @test menu.selection[] == "System 2"
        # the menu chooses the system that the source is traced through
        menu.i_selected[] = 1
        src = GUI._place_catalog!(gui, GUI._catalog_entry(w), ["632.8"])
        GUI._drop_placement!(gui)
        @test only(gui.pairs).second === src && only(gui.pairs).first === a
        close(gui)

        # a source is also traced through a `StaticSystem`, a component is not added to it: the
        # menu offers the systems that can get the chosen entry
        static = StaticSystem([_mirror(0.3)])
        gui = _live_view(a, static)
        w = GUI._catalog_widget(GUI._catalog_window(gui))
        menu = w.target_menu
        @test GUI._catalog_entry(w).source && menu.options[] == ["System 1", "System 2"]
        menu.i_selected[] = 2
        @test GUI._catalog_target(gui, GUI._catalog_entry(w)) === static
        src = GUI._place_catalog!(gui, GUI._catalog_entry(w), ["632.8"])
        GUI._drop_placement!(gui)
        @test only(gui.pairs).first === static
        gui.controls.selected[] = nothing
        GUI._select_catalog_entry!(gui, w, findfirst(e -> !e.source, w.entries))
        @test menu.options[] == ["System 1"] && menu.selection[] == "System 1"
        @test GUI._catalog_target(gui, GUI._catalog_entry(w)) === a
        close(gui)
    end

    @testset "export" begin
        # Runs the exported `code` and returns the value of its variable `name`
        function _run(code, name; names...)
            mod = Module()
            Core.eval(mod, :(using BeamletOptics))
            for (key, value) in names
                Core.eval(mod, :($key = $value))
            end
            include_string(mod, code)
            return Core.eval(mod, name)
        end

        m = _mirror()
        sys = System([m])
        first_beam = _beam(0.2)
        gui = _live_view(sys => first_beam; labels = Dict(first_beam => "start"))

        # a source of the catalog: constructed at the origin, moved and rotated
        src = UniformDiscSource([0.0, 0, 0], [0.0, 1, 0], 5e-3, 532e-9; num_rays = 20)
        origin = (; code = "UniformDiscSource([0.0, 0.0, 0.0], [0.0, 1.0, 0.0], 0.005, 5.32e-7; num_rays = 20)",
            pose0 = GUI._pose(src))
        rotate3d!(src, normalize([1.0, 2, 3]), 0.3)
        translate_to3d!(src, [0.01, -0.02, 0.03])
        add_component!(gui, src; label = "disc", origin)
        code, n = GUI._export_code(gui)
        @test n == 1
        @test occursin("# disc (CollimatedSource), added", code)
        @test occursin("disc = UniformDiscSource(", code)
        @test occursin("solve_system!(system, disc)", code)
        @test !occursin("push!", code)
        # the code runs and reproduces the source: position, direction and orientation
        target = _mirror()
        translate_to3d!(target, position(src) .+ 0.1 .* BMO.direction(src))
        copy = _run(code, :disc; system = System([target]))
        @test copy isa CollimatedSource && length(BMO.beams(copy)) == 20
        @test norm(position(copy) - position(src)) < 1e-12
        @test norm(BMO.direction(copy) - BMO.direction(src)) < 1e-12
        @test norm(BMO.orientation(copy) - BMO.orientation(src)) < 1e-12
        # ... and traces it
        @test _target(first(BMO.beams(copy))) === target

        # moved afterwards: still relative to its pose as constructed
        GUI._change!(() -> translate3d!(src, [0.1, 0, 0]), gui.controls, src)
        code, n = GUI._export_code(gui)
        @test n == 1
        @test norm(position(_run(code, :disc; system = System())) - position(src)) < 1e-12

        # without an origin: a comment marks where to construct it
        plain = _beam()
        add_component!(gui, plain)
        code, n = GUI._export_code(gui)
        @test n == 2
        @test occursin("# construct `", code)

        # a removed source of the start is a comment
        remove_component!(gui, first_beam)
        code, n = GUI._export_code(gui)
        @test n == 3
        @test occursin("# start (Beam), removed", code)
        @test occursin("# do not trace start through system any more", code)
        # removed sources that were added are no change
        remove_component!(gui, plain)
        remove_component!(gui, src)
        code, n = GUI._export_code(gui)
        @test n == 1 && !occursin("disc", code)
        close(gui)
    end
end

end
