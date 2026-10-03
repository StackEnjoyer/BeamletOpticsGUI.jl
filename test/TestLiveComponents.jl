module TestLiveComponents

using GLMakie, BeamletOptics, BeamletOpticsGUI
using BeamletOptics: render_children, render_plots, render_parent, rendered
using Makie
using LinearAlgebra: norm, normalize
using Test

const BMO = BeamletOptics
const GUI = BeamletOpticsGUI

@testset "Live components" begin

    # Each change is solved at once, see `TestLiveView.jl`; no card of a detector is pinned at start
    _live_view(args...; kwargs...) =
        live_view(args...; merge((; trace_budget = Inf, throttle = false, detectors = []), kwargs)...)

    _key!(gui, key) = (events(gui.ax.scene).keyboardbutton[] = Makie.KeyEvent(key, Keyboard.press))

    _beam() = Beam([0.0, 0, 0], [0.0, 1, 0])

    # A mirror on the beam along +y, which it reflects along +x
    function _mirror(y = 0.1)
        m = RoundPlanoMirror(25e-3, 5e-3)
        zrotate3d!(m, deg2rad(45))
        translate3d!(m, [0, y, 0])
        return m
    end

    _in(obj, list) = any(o -> o === obj, list)
    _handle(gui, obj) = GUI._child_handle(gui.controls.h, obj)
    _rendered(gui, obj) = !isnothing(_handle(gui, obj))
    _hit(gui, obj) = !isempty(GUI._hits(gui, obj))
    _in_scene(gui, plots) = any(p -> _in(p, gui.ax.scene.plots), plots)
    _listed(gui::GUI.AppView, obj) = _in(obj, [r.key for r in GUI._tree_rows(gui)])
    _listed(gui, obj) = _in(obj, gui.objects.menu)
    # The card of the selection: docked in the inspector of the app layout, else floating
    _card(gui::GUI.AppView) = gui.layout.inspector.card
    _card(gui) = gui.cards.selection
    _message(f) = try
        f()
        ""
    catch e
        e isa ArgumentError ? e.msg : rethrow()
    end

    @testset "add to an empty system, $layout" for layout in (:compact, :app)
        sys = System()
        beam = _beam()
        gui = _live_view(sys => beam; layout)
        @test isnothing(gui.trace.error)
        @test isempty(sys.objects)

        m = _mirror()
        @test add_component!(gui, m; label = "m1") === m
        @test sys.objects == [m] && sys.objects[1] === m
        @test _rendered(gui, m)
        @test _in(m, rendered.(render_children(gui.system_handles[1])))
        @test _in(m, gui.controls.movable)
        @test gui.controls.init_poses[m] == GUI._pose(m)
        @test GUI._label(gui, m) == "m1"
        @test gui.controls.selected[] === m
        @test _hit(gui, m)
        @test _listed(gui, m)
        @test isnothing(gui.trace.error) && !gui.trace.stale
        @test gui.components.added == [m] && isempty(gui.components.removed)
        @test gui.components.system[m] === sys && isnothing(gui.components.origin[m])

        # without a label: named by its type, not selected; the beam reaches it after the mirror
        m2 = _mirror()
        translate3d!(m2, [0.1, 0, 0])
        add_component!(gui, m2; select = false, system = sys)
        @test gui.controls.selected[] === m
        @test GUI._label(gui, m2) == "Mirror 1"
        @test _hit(gui, m2) && _listed(gui, m2)
        @test length(sys.objects) == 2

        # added twice, a system that the view does not show
        @test_throws ArgumentError add_component!(gui, m)
        @test_throws ArgumentError add_component!(gui, _mirror(0.3); system = System())
        @test_throws ArgumentError add_component!(gui, _mirror(0.3); system = :first)
        @test length(sys.objects) == 2 && length(gui.components.added) == 2
        close(gui)
    end

    @testset "group, $layout" for layout in (:compact, :app)
        sys = System()
        gui = _live_view(sys => _beam(); layout)
        a, b = _mirror(0.1), _mirror(0.2)
        g = ObjectGroup([a, b])
        add_component!(gui, g; label = "pair")
        @test _rendered(gui, a) && _rendered(gui, b) && !_rendered(gui, g)
        @test render_parent(gui.controls.h, a) === g && render_parent(gui.controls.h, b) === g
        @test GUI._part_parent(gui, a) === g && GUI._part_parent(gui, b) === g
        @test all(o -> haskey(gui.controls.init_poses, o), (g, a, b))
        @test _in(g, gui.controls.movable) && !_in(a, gui.controls.movable)
        @test gui.controls.selected[] === g
        @test _hit(gui, a)

        # an object of a group is not removed on its own
        @test_throws ArgumentError remove_component!(gui, a)
        @test occursin("pair", _message(() -> remove_component!(gui, a)))
        @test _rendered(gui, a) && sys.objects[1] === g

        plots = [render_plots(_handle(gui, a)); render_plots(_handle(gui, b))]
        @test _in_scene(gui, plots)
        @test remove_component!(gui, g) === g
        @test isempty(sys.objects)
        @test !_rendered(gui, a) && !_rendered(gui, b)
        @test !_in_scene(gui, plots)
        @test isnothing(render_parent(gui.controls.h, a))
        @test isnothing(GUI._part_parent(gui, a))
        @test !any(o -> haskey(gui.controls.init_poses, o), (g, a, b))
        @test isempty(gui.components.added) && isempty(gui.components.removed)
        close(gui)
    end

    @testset "remove, $layout" for layout in (:compact, :app)
        # the second mirror is hit once the first one is removed
        m, m2 = _mirror(0.1), _mirror(0.2)
        sys = System([m, m2])
        beam = _beam()
        gui = _live_view(sys => beam; layout, fine_step = 1e-3, labels = Dict(m => "m1"))
        @test _hit(gui, m) && !_hit(gui, m2)

        # traces of the mirror in the state of the view
        gui.controls.selected[] = m
        _key!(gui, Keyboard.up)
        _key!(gui, Keyboard.page_up)
        @test any(e -> e.obj === m, gui.controls.undo_stack)
        GUI._undo!(gui.controls)
        @test any(e -> e.obj === m, gui.controls.redo_stack)
        GUI._set_opacity!(gui, m, 0.5)
        GUI._set_hidden!(gui, m, true)
        GUI._toggle_pin!(gui, m)
        GUI._add_measure_point!(gui, position(m), m)
        gui.controls.selected[] = m
        @test m in gui.objects.hidden && haskey(gui.objects.opacity, m) && GUI._is_pinned(gui, m)
        plots = copy(render_plots(_handle(gui, m)))

        @test remove_component!(gui, m) === m
        @test sys.objects == [m2] && sys.objects[1] === m2
        @test !_rendered(gui, m)
        @test !_in(m, rendered.(render_children(gui.system_handles[1])))
        @test !_in_scene(gui, plots)
        @test !_in(m, gui.controls.movable)
        @test !haskey(gui.controls.init_poses, m)
        # the removal is an action of the undo history, after the gestures of the mirror, which
        # stay: undo brings the mirror back, see `TestLiveHistory.jl`
        @test last(gui.controls.undo_stack) isa GUI._ActionEntry
        @test last(gui.controls.undo_stack).obj === m
        @test isempty(gui.controls.redo_stack)
        @test isnothing(gui.controls.last_key_step)
        @test !(m in gui.objects.hidden) && !haskey(gui.objects.opacity, m)
        @test !GUI._is_pinned(gui, m)
        @test !any(c -> c.pinned && c.obj === m, gui.cards.all)
        @test isnothing(gui.controls.selected[]) && isnothing(gui.objects.inspected)
        @test isempty(gui.measure.points)
        @test !_listed(gui, m) && _listed(gui, m2)
        @test gui.status.text[] == "m1 removed"
        @test gui.components.removed == [m] && gui.components.system[m] === sys

        # solved again: the beam passes where the mirror was
        @test isnothing(gui.trace.error) && !gui.trace.stale
        @test !_hit(gui, m) && _hit(gui, m2)
        GUI._resolve!(gui, nothing)
        @test isnothing(gui.trace.error)
        @test !_hit(gui, m) && _hit(gui, m2)

        # not removable: twice, a source that is not shown, a clip plane, an unknown object
        @test_throws ArgumentError remove_component!(gui, m)
        @test_throws ArgumentError remove_component!(gui, _beam())
        plane = GUI._add_clip_plane!(gui, [0, 0.05, 0], [0, 1, 0]; select = false)
        @test_throws ArgumentError remove_component!(gui, plane)
        @test_throws ArgumentError remove_component!(gui, sys)
        @test_throws ArgumentError remove_component!(gui, _mirror())
        @test length(gui.clip.planes) == 1 && sys.objects == [m2]

        # added again: no change of the system is left, the label is kept
        add_component!(gui, m)
        @test isempty(gui.components.removed) && isempty(gui.components.added)
        @test GUI._label(gui, m) == "m1"
        @test _hit(gui, m) && !_hit(gui, m2)
        # a component added at runtime and removed again
        m3 = _mirror(0.05)
        add_component!(gui, m3; label = "m3")
        @test gui.components.added == [m3]
        remove_component!(gui, m3)
        @test isempty(gui.components.removed) && isempty(gui.components.added)
        @test !haskey(gui.components.system, m3) && !haskey(gui.components.origin, m3)
        @test !haskey(gui.labels, m3)
        close(gui)
    end

    @testset "manual tracing" begin
        m = _mirror()
        sys = System([m])
        gui = _live_view(sys => _beam(); auto_trace = false)
        GUI._trace!(gui)
        @test !gui.trace.stale && _hit(gui, m)
        remove_component!(gui, m)
        @test gui.trace.stale
        GUI._trace!(gui)
        @test !gui.trace.stale && !_hit(gui, m)
        add_component!(gui, m)
        @test gui.trace.stale && !_hit(gui, m)
        GUI._trace!(gui)
        @test _hit(gui, m)
        close(gui)
    end

    @testset "StaticSystem and extras, $layout" for layout in (:compact, :app)
        m = _mirror()
        static = StaticSystem([m])
        gui = _live_view(static => _beam(); layout)
        @test isnothing(GUI._target_system(gui))
        @test_throws ArgumentError add_component!(gui, _mirror(0.2))
        @test_throws ArgumentError add_component!(gui, _mirror(0.2); system = static)
        @test_throws ArgumentError remove_component!(gui, m)
        @test occursin("StaticSystem", _message(() -> remove_component!(gui, m)))
        @test _rendered(gui, m) && isempty(gui.components.added) && isempty(gui.components.removed)
        close(gui)

        m, housing = _mirror(), _mirror(0.3)
        sys = System([m])
        gui = _live_view(sys => _beam(); layout, extras = [housing])
        @test_throws ArgumentError add_component!(gui, housing)
        @test_throws ArgumentError remove_component!(gui, housing)
        @test occursin("extra", _message(() -> remove_component!(gui, housing)))
        @test _rendered(gui, housing) && sys.objects == [m]
        # "remove" on the card of the extra only names the reason
        remove = only(w for row in GUI._card_rows(housing) for w in row.cells
                      if w isa CardWidget && w.name === :remove)
        remove.on(gui, housing, nothing)
        @test _rendered(gui, housing) && occursin("extra", gui.status.text[])
        close(gui)
    end

    @testset "several systems" begin
        m1, m2 = _mirror(0.1), _mirror(0.2)
        sys1, sys2 = System([m1]), System([m2])
        b1, b2 = _beam(), Beam([0.01, 0, 0], [0.0, 1, 0])
        gui = _live_view(sys1 => b1, sys2 => b2)
        # the first system by default, the system of the selection, the given one
        @test GUI._target_system(gui) === sys1
        a = _mirror(0.05)
        add_component!(gui, a; select = false)
        @test _in(a, sys1.objects) && !_in(a, sys2.objects)
        gui.controls.selected[] = m2
        b = _mirror(0.15)
        add_component!(gui, b)
        @test _in(b, sys2.objects) && !_in(b, sys1.objects)
        c = _mirror(0.25)
        add_component!(gui, c; system = sys1)
        @test _in(c, sys1.objects)
        @test_throws ArgumentError add_component!(gui, c; system = sys2)
        remove_component!(gui, b)
        @test sys2.objects == [m2] && length(sys1.objects) == 3
        close(gui)
    end

    @testset "detector added at runtime, $layout" for layout in (:compact, :app)
        sys = System([_mirror()])
        gui = _live_view(sys => _beam(); layout)
        tick!() = (events(gui.ax.scene).tick[] = Makie.Tick(Makie.RegularRenderTick, 0, 0.0, 1 / 60))
        # on the reflected beam along +x
        pd = Detector(5e-3)
        zrotate3d!(pd, -π / 2)
        translate3d!(pd, [0.1, 0.1, 0])
        @test !haskey(gui.detectors.states, pd)
        add_component!(gui, pd; label = "PD")
        tick!()
        # traced, with the page "Results" like the detectors the view started with
        @test BMO.hit_count(pd) == 1
        @test GUI._card_pages(pd) == (:pose, :results, :properties)
        # its card, the card of the selection, shows its view, which is computed for its hits
        @test _card(gui).page == :results
        state = GUI._detector_state(gui, pd)
        @test any(((p, _),) -> p === pd, GUI._shown_views(gui))
        @test !state.stale && !isnothing(state.result)
        # the solves empty it like the other detectors
        GUI._resolve!(gui, nothing)
        @test BMO.hit_count(pd) == 1

        # pinned and removed: its cards are unpinned and the views forget it
        GUI._toggle_pin!(gui, pd)
        tick!()
        @test GUI._is_pinned(gui, pd)
        remove_component!(gui, pd)
        tick!()
        @test !GUI._is_pinned(gui, pd)
        @test !haskey(gui.detectors.states, pd)
        @test !any(((p, _),) -> p === pd, GUI._shown_views(gui))
        @test BMO.hit_count(pd) == 0
        # it is no longer traced
        GUI._resolve!(gui, nothing)
        @test BMO.hit_count(pd) == 0 && !haskey(gui.detectors.states, pd)
        # and can be added again
        add_component!(gui, pd)
        tick!()
        @test BMO.hit_count(pd) == 1
        @test !GUI._detector_state(gui, pd).stale
        close(gui)
    end

    @testset "Delete and the card, $layout" for layout in (:compact, :app)
        m, m2, m3 = _mirror(0.1), _mirror(0.2), _mirror(0.3)
        sys = System([m, m2, m3])
        beam = _beam()
        gui = _live_view(sys => beam; layout)
        help = GUI._help_text(GUI._help_sections(gui.controls))
        @test occursin("del: remove the selected component or clip plane", help)

        # nothing selected: the key is not handled
        _key!(gui, Keyboard.delete)
        @test length(sys.objects) == 3

        gui.controls.selected[] = m
        _key!(gui, Keyboard.delete)
        @test !_in(m, sys.objects) && !_rendered(gui, m)
        @test isnothing(gui.controls.selected[])
        @test gui.components.removed == [m]

        # a clip plane as before
        _key!(gui, Keyboard.p)
        plane = only(gui.clip.planes)
        @test gui.controls.selected[] === plane
        _key!(gui, Keyboard.delete)
        @test isempty(gui.clip.planes) && isnothing(gui.controls.selected[])
        @test length(sys.objects) == 2 && gui.components.removed == [m]

        # "remove" of the card: a row below the rows of `card_rows`, not an action in the head
        @test [w.name for w in card_actions(m2)] == [:hide]
        @test length(GUI._card_rows(m2)) == length(card_rows(m2)) + 1
        @test only(last(GUI._card_rows(m2)).cells).name === :remove
        gui.controls.selected[] = m2
        GUI._update_selection_box!(gui.controls)
        GUI._update_cards!(gui)
        GUI._update_inspector!(gui)
        button = GUI._card_widget(_card(gui), :remove)
        @test button isa Button
        notify(button.clicks)
        @test sys.objects == [m3] && sys.objects[1] === m3
        @test !_rendered(gui, m2) && isnothing(gui.controls.selected[])
        @test _hit(gui, m3)
        close(gui)
    end

    @testset "camera kept in the open window" begin
        sys = System([_mirror(0.1)])
        gui = _live_view(sys => _beam())
        screen = GLMakie.Screen(visible = false)
        display(screen, gui.fig)
        tick!() = (events(gui.ax.scene).tick[] = Makie.Tick(Makie.RegularRenderTick, 0, 0.0, 1 / 60))
        foreach(_ -> tick!(), 1:3)
        eye, lookat, up = GUI._current_view(gui)
        GUI.set_view(gui.ax, lookat .+ 0.3 .* (eye .- lookat) .+ [0.01, 0, 0], lookat .+ [0.01, 0, 0], up)
        tick!()
        v0 = GUI._current_view(gui)
        m = _mirror(0.6)
        add_component!(gui, m)
        tick!()
        @test all(a -> isapprox(a[1], a[2]; atol = 1e-9), zip(v0, GUI._current_view(gui)))
        remove_component!(gui, m)
        tick!()
        @test all(a -> isapprox(a[1], a[2]; atol = 1e-9), zip(v0, GUI._current_view(gui)))
        close(screen)
        close(gui)
    end

    @testset "export" begin
        # Runs the exported `code` on the `system` (by default an empty one) and returns its objects
        function _run(code, system = System(); names...)
            mod = Module()
            Core.eval(mod, :(using BeamletOptics))
            Core.eval(mod, :(system = $system))
            for (name, value) in names
                Core.eval(mod, :($name = $value))
            end
            include_string(mod, code)
            return system.objects
        end
        function _same_pose(a, b; atol = 1e-12)
            (Pa, Ra), (Pb, Rb) = GUI._pose(a), GUI._pose(b)
            return norm(Pa - Pb) < atol && norm(Ra - Rb) < atol
        end

        sys = System()
        gui = _live_view(sys => _beam(); fine_step = 1e-3, fine_angle = 1e-2)
        code, n = GUI._export_code(gui)
        @test n == 0 && occursin("# no changes", code)

        # a lens of the catalog: constructed, placed, added, then moved
        lens = ThinLens(50e-3, -50e-3, 25.4e-3, 1.5)
        origin = (; code = "ThinLens(0.05, -0.05, 0.0254, 1.5)", pose0 = GUI._pose(lens))
        rotate3d!(lens, normalize([1.0, 2, 3]), 0.3)
        translate_to3d!(lens, [0.01, 0.1, -0.02])
        add_component!(gui, lens; origin, label = "lens")
        @test gui.components.origin[lens] === origin
        _key!(gui, Keyboard.up)
        _key!(gui, Keyboard.m)
        _key!(gui, Keyboard.left)
        code, n = GUI._export_code(gui)
        @test n == 1
        @test occursin("# lens ($(nameof(typeof(lens)))), added\nlens = ThinLens(0.05, -0.05, 0.0254, 1.5)\n" *
            "push!(system, lens)\nrotate3d!(lens, [", code)
        @test count("translate_to3d!(lens, ", code) == 1
        @test !occursin("# no changes", code)
        @test export_changes(gui; io = devnull) == code
        objs = _run(code)
        @test length(objs) == 1
        copy = only(objs)
        @test typeof(copy) == typeof(lens) && copy !== lens
        @test _same_pose(copy, lens)

        # in the pose as constructed: no pose lines
        lens2 = ThinLens(50e-3, -50e-3, 25.4e-3, 1.5)
        add_component!(gui, lens2; label = "lens2", select = false,
            origin = (; code = "ThinLens(0.05, -0.05, 0.0254, 1.5)", pose0 = GUI._pose(lens2)))
        code, n = GUI._export_code(gui)
        @test n == 2
        @test occursin("lens2 = ThinLens(0.05, -0.05, 0.0254, 1.5)\npush!(system, lens2)\n", code)
        @test !occursin("(lens2, [", code)
        objs = _run(code)
        @test length(objs) == 2 && _same_pose(objs[2], lens2)
        remove_component!(gui, lens2)

        # without an origin: a comment instead of the constructor, the change since it was added
        m = _mirror(0.2)
        fresh = deepcopy(m)
        add_component!(gui, m; label = "m")
        code, n = GUI._export_code(gui)
        @test n == 2
        @test occursin("# m (Mirror), added\n# construct `m` here, in its pose when it was added\npush!(system, m)\n", code)
        @test !occursin("translate_to3d!(m, ", code)
        # the controls are in the rotate mode
        _key!(gui, Keyboard.up)
        code, n = GUI._export_code(gui)
        @test n == 2 && occursin("push!(system, m)\nrotate3d!(m, [", code)
        @test count("translate_to3d!(m, [", code) == 1
        objs = _run(code; m = fresh)
        @test objs[2] === fresh && _same_pose(fresh, m)
        # removed again: neither added nor removed
        remove_component!(gui, m)
        code, n = GUI._export_code(gui)
        @test n == 1 && !occursin("(system, m)", code)
        close(gui)

        # a group with an origin, moved as a whole before and after it is added
        _pair() = ObjectGroup([RoundPlanoMirror(25e-3, 5e-3), SphericalLens(0.05, -0.05, 5e-3, 25.4e-3, 1.5)])
        pair_code = "ObjectGroup([RoundPlanoMirror(25e-3, 5e-3), SphericalLens(0.05, -0.05, 5e-3, 25.4e-3, 1.5)])"
        sys = System()
        gui = _live_view(sys => _beam(); fine_step = 1e-3, fine_angle = 1e-2)
        g = _pair()
        origin = (; code = pair_code, pose0 = GUI._pose(g))
        rotate3d!(g, normalize([0.0, 1, 1]), 0.2)
        translate3d!(g, [0.02, 0.1, 0.01])
        add_component!(gui, g; origin, label = "pair")
        _key!(gui, Keyboard.page_up)
        code, n = GUI._export_code(gui)
        @test n == 1 && occursin("pair = $pair_code\npush!(system, pair)\nrotate3d!(pair, [", code)
        copy = only(_run(code))
        @test _same_pose(copy, g)
        @test all(i -> _same_pose(copy.objects[i], g.objects[i]), 1:2)
        close(gui)

        # removed components: by their label, else as a comment; the system by its label
        m1, m2, m3 = _mirror(0.1), _mirror(0.2), _mirror(0.3)
        sys = System([m1, m2, m3])
        gui = _live_view(sys => _beam(); labels = Dict(m1 => "m1", m2 => "the mirror"))
        remove_component!(gui, m1)
        remove_component!(gui, m2)
        code, n = GUI._export_code(gui)
        @test n == 2
        @test occursin("# m1 (Mirror), removed\ndelete!(system, m1)\n", code)
        @test occursin("# the mirror (Mirror), removed\n# delete!(system, …) with the variable of the mirror\n", code)
        @test count("delete!(system, ", code) == 2
        # applied to a system as the view started with: the labelled mirror is deleted
        objs = _run(code, System([m1, m3]); m1)
        @test length(objs) == 1 && objs[1] === m3
        close(gui)

        sys = System([m1, m2, m3])
        gui = _live_view(sys => _beam(); labels = Dict(m1 => "m1", sys => "bench"))
        gui.export_clipboard = false
        remove_component!(gui, m1)
        @test occursin("\ndelete!(bench, m1)\n", GUI._export_code(gui)[1])
        redirect_stdout(devnull) do
            GUI._export!(gui)
        end
        @test gui.status.text[] == "exported 1 change"
        close(gui)

        # several systems are numbered
        sys1, sys2 = System([m1]), System([m2])
        gui = _live_view(sys1 => _beam(), sys2 => Beam([0.01, 0, 0], [0.0, 1, 0]);
            labels = Dict(m1 => "m1", m2 => "m2"))
        remove_component!(gui, m2)
        add_component!(gui, m3; label = "m3", system = sys1)
        code, n = GUI._export_code(gui)
        @test n == 2
        @test occursin("\ndelete!(system2, m2)\n", code) && occursin("\npush!(system1, m3)\n", code)
        close(gui)
    end
end

end
