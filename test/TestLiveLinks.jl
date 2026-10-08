module TestLiveLinks

using GLMakie, BeamletOptics, BeamletOpticsGUI
using BeamletOptics: render_children, render_plots, rendered
using Makie
using Test

const BMO = BeamletOptics
const GUI = BeamletOpticsGUI

@testset "Linked windows" begin

    # Each change is solved at once, see `TestLiveView.jl`; no card of a detector is pinned at start
    _live_view(args...; kwargs...) =
        live_view(args...; merge((; trace_budget = Inf, throttle = false, detectors = [],
            progress_delay = Inf), kwargs)...)

    _key!(gui, key) = (events(gui.ax.scene).keyboardbutton[] = Makie.KeyEvent(key, Keyboard.press))

    # A system at `x`: a beam along +y, a lens and a mirror, which reflects the beam along +x
    function _setup(x)
        lens = ThinLens(100e-3, -100e-3, 25e-3, 1.5)
        translate3d!(lens, [x, 0.05, 0])
        mirror = RoundPlanoMirror(25e-3, 5e-3)
        zrotate3d!(mirror, deg2rad(45))
        translate3d!(mirror, [x, 0.1, 0])
        return (; sys = System([lens, mirror]), beam = Beam([x, 0, 0], [0.0, 1, 0], 632.8e-9), lens, mirror)
    end
    function _mirror(x, y)
        m = RoundPlanoMirror(25e-3, 5e-3)
        zrotate3d!(m, deg2rad(45))
        translate3d!(m, [x, y, 0])
        return m
    end
    # Two systems in one view, with steps of the keys that are large enough to tell
    function _views(; layout = :compact, kwargs...)
        a, b = _setup(0.0), _setup(0.3)
        gui = _live_view(a.sys => a.beam, b.sys => b.beam; layout, fine_step = 1e-3, kwargs...)
        return gui, a, b
    end

    _in(obj, list) = any(o -> o === obj, list)
    _handle(gui, obj) = GUI._child_handle(gui.controls.h, obj)
    _shown(gui, obj) = GUI._shows(gui, obj)
    _paired(gui, sys, src) = any(p -> p.first === sys && p.second === src, gui.pairs)
    _bbox(gui, obj) = Makie.boundingbox(first(render_plots(_handle(gui, obj))))
    _same_box(a, b) = Makie.origin(a) ≈ Makie.origin(b) && Makie.widths(a) ≈ Makie.widths(b)
    # The points of the plots of the beam in the view
    function _points(gui, beam)
        i = findfirst(p -> p.second === beam, gui.pairs)
        return [Point3f.(p[1][]) for p in render_plots(gui.beam_handles[i])]
    end
    # The object that the first ray of the beam ends on
    function _target(beam)
        isect = BMO.intersection(first(BMO.rays(beam)))
        return isnothing(isect) ? nothing : BMO.object(isect)
    end
    # Moves `obj` by a step of the keys in the `gui`
    function _move!(gui, obj)
        gui.controls.selected[] = obj
        GUI._update_selection_box!(gui.controls)
        _key!(gui, Keyboard.up)
        return nothing
    end
    _card(gui::GUI.AppView) = gui.layout.inspector.card
    _card(gui) = gui.cards.selection
    _no_errors(guis...) = all(g -> isnothing(g.last_error), guis)
    _message(f) = try
        f()
        ""
    catch e
        e isa ArgumentError ? e.msg : rethrow()
    end

    @testset "open_system, $layout" for layout in (:compact, :app)
        gui, a, b = _views(; layout, theme = :dark, snap = :pose, table = (; pitch = 0.05))
        GUI._set_beam_color!(gui, b.beam, :green)
        gui.labels[b.mirror] = "fold"
        new = open_system(gui, b.sys; display = false)
        @test new isa typeof(gui)
        @test GUI._systems(new) == [b.sys] && only(GUI._systems(new)) === b.sys
        @test length(new.pairs) == 1 && _paired(new, b.sys, b.beam)
        @test _shown(new, b.lens) && _shown(new, b.mirror) && !_shown(new, a.lens)
        # what it takes over
        @test new.layout.theme === gui.layout.theme
        @test new.controls.snap[] == :pose && new.controls.fine_step == 1e-3 && !new.controls.throttle
        @test new.components.table.pitch == 0.05 && new.components.table.shown
        @test new.components.catalog == gui.components.catalog
        @test GUI._beam_color(new, b.beam) == GUI._beam_color(gui, b.beam)
        @test new.trace.budget == Inf && new.trace.auto[]
        # one name per object in both windows
        @test GUI._label(new, b.mirror) == "fold"
        @test GUI._label(new, b.lens) == GUI._label(gui, b.lens) == "Lens 2"
        @test GUI._label(new, b.sys) == GUI._label(gui, b.sys) == "System 2"
        @test GUI._label(new, GUI._system_handle(new, b.sys)) == "System 2"
        # linked
        @test gui.links === new.links && gui.links.views == Any[gui, new]
        @test !new.trace.stale && !gui.trace.stale
        @test _no_errors(gui, new)
        close(new)
        close(gui)

        # the kwargs of `live_view` take precedence, a system without a source
        sys = System([_mirror(0.0, 0.1)])
        gui = _live_view(sys; layout)
        new = open_system(gui, sys; display = false, layout = :app, theme = :dark, auto_trace = false)
        @test new isa GUI.AppView && new.layout.theme === GUI._app_theme(:dark)
        @test isempty(new.pairs) && !new.trace.auto[]
        # the switch of the auto tracing is one for the linked windows, also the one of the kwarg
        @test !gui.trace.auto[]
        gui.widgets.auto_trace_toggle.active[] = true
        @test new.trace.auto[] && new.widgets.auto_trace_toggle.active[]
        new.widgets.auto_trace_toggle.active[] = false
        @test !gui.trace.auto[]
        close(new)
        close(gui)
    end

    @testset "what can not be opened" begin
        gui, a, b = _views()
        @test occursin("not a system of the live view", _message(() -> open_system(gui, System())))
        # the card of the extras is the card of a system
        GUI._open_system!(gui, rendered(gui.extras))
        @test occursin("can not be opened", gui.status.text[])
        @test isempty(gui.links.views)
        close(gui)
    end

    @testset "a move is followed, $layout" for layout in (:compact, :app)
        gui, a, b = _views(; layout)
        log = Any[]
        new = open_system(gui, b.sys; display = false, on_change = (g, obj) -> push!(log, obj))
        empty!(log)
        for (here, there) in ((new, gui), (gui, new))
            box = _bbox(there, b.lens)
            there.trace.solve_time = -1.0
            y = position(b.lens)[2]
            _move!(here, b.lens)
            @test position(b.lens)[2] != y
            # the plots of the other window follow, which did not solve
            @test !_same_box(_bbox(there, b.lens), box)
            @test _same_box(_bbox(there, b.lens), _bbox(here, b.lens))
            @test _points(there, b.beam) == _points(here, b.beam)
            @test there.trace.solve_time == -1.0 && here.trace.solve_time >= 0
            @test !there.trace.stale && !here.trace.stale
        end
        # its `on_change` is called once per change, with the object
        @test length(log) == 2 && all(o -> o === b.lens, log)
        # the mirror, which the beam ends on
        points = _points(gui, b.beam)
        _move!(new, b.mirror)
        @test _points(gui, b.beam) != points && _points(gui, b.beam) == _points(new, b.beam)
        # an object of the other system changes nothing for the new window
        empty!(log)
        points = _points(new, b.beam)
        _move!(gui, a.mirror)
        @test isempty(log) && _points(new, b.beam) == points
        # undo of a move in either window
        y = position(b.mirror)[2]
        GUI._undo!(new.controls)
        @test position(b.mirror)[2] != y
        @test _same_box(_bbox(gui, b.mirror), _bbox(new, b.mirror))
        @test _points(gui, b.beam) == _points(new, b.beam)
        @test _no_errors(gui, new)
        close(new)
        close(gui)
    end

    @testset "components are followed, $layout" for layout in (:compact, :app)
        gui, a, b = _views(; layout)
        new = open_system(gui, b.sys; display = false)
        # added in the first window, in front of the lens
        m = _mirror(0.3, 0.03)
        add_component!(gui, m; system = b.sys, label = "pick-off")
        @test _shown(new, m) && _in(m, new.controls.movable)
        @test GUI._label(new, m) == "pick-off"
        @test _in(m, new.components.added) && new.components.system[m] === b.sys
        @test _target(b.beam) === m
        @test _points(new, b.beam) == _points(gui, b.beam)
        @test !new.trace.stale
        # a component of the other system is not shown
        other = _mirror(0.0, 0.03)
        add_component!(gui, other; system = a.sys)
        @test !_shown(new, other)
        # removed in the new window
        remove_component!(new, m)
        @test !_in(m, b.sys.objects) && !_shown(gui, m) && !_in(m, gui.controls.movable)
        @test !_in(m, gui.components.added)
        @test _target(b.beam) === b.lens
        @test _points(new, b.beam) == _points(gui, b.beam)
        # undo and redo of the removal, in the window that removed
        GUI._undo!(new.controls)
        @test _in(m, b.sys.objects) && _shown(gui, m) && _shown(new, m)
        @test GUI._label(gui, m) == GUI._label(new, m) == "pick-off"
        GUI._redo!(new.controls)
        @test !_shown(gui, m) && !_shown(new, m)
        # undo of adding it in the first window: its entry on the object was dropped when the new
        # window removed it
        @test !any(e -> e.obj === m, gui.controls.undo_stack)
        # a name that is given once holds in both windows
        m2 = _mirror(0.3, 0.02)
        add_component!(new, m2)
        @test _shown(gui, m2) && GUI._label(gui, m2) == GUI._label(new, m2)
        @test count(o -> GUI._label(gui, o) == GUI._label(gui, m2),
            [a.mirror, b.mirror, other, m2]) == 1
        # a component that the view started with: removed in one, restored in the other by the API
        remove_component!(gui, b.lens)
        @test !_shown(new, b.lens) && _in(b.lens, new.components.removed)
        add_component!(new, b.lens)
        @test _shown(gui, b.lens) && isempty(gui.components.removed) && isempty(new.components.removed)
        @test _no_errors(gui, new)
        close(new)
        close(gui)
    end

    @testset "sources are followed, $layout" for layout in (:compact, :app)
        gui, a, b = _views(; layout)
        new = open_system(gui, b.sys; display = false)
        src = Beam([0.302, 0, 0], [0.0, 1, 0], 532e-9)
        add_component!(new, src)
        @test _paired(gui, b.sys, src) && length(gui.pairs) == 3 == length(gui.beam_handles)
        @test !isnothing(_handle(gui, src)) && _in(src, gui.controls.movable)
        @test GUI._label(gui, src) == GUI._label(new, src)
        @test GUI._beam_color(gui, src) == GUI._beam_color(new, src)
        @test _points(gui, src) == _points(new, src)
        @test !isnothing(_target(src))
        # switched off in one window: neither traced nor drawn in both
        GUI._set_beam_on!(gui, src, false)
        @test !GUI._beam_on(new, src)
        @test all(p -> !p.visible[], render_plots(last(new.beam_handles)))
        GUI._set_beam_on!(new, src, true)
        @test GUI._beam_on(gui, src) && !isnothing(_target(src))
        @test all(p -> p.visible[], render_plots(last(gui.beam_handles)))
        # removed in the first window
        remove_component!(gui, src)
        @test !_paired(new, b.sys, src) && length(new.pairs) == 1 == length(new.beam_handles)
        @test isnothing(_handle(new, src))
        # a source of the other system is not shown
        other = Beam([0.002, 0, 0], [0.0, 1, 0], 532e-9)
        add_component!(gui, other; system = a.sys)
        @test length(new.pairs) == 1
        # the source of the start, removed in the new window and brought back by undo
        remove_component!(new, b.beam)
        @test !_paired(gui, b.sys, b.beam) && isempty(new.pairs)
        GUI._undo!(new.controls)
        @test _paired(gui, b.sys, b.beam) && _paired(new, b.sys, b.beam)
        @test _points(gui, b.beam) == _points(new, b.beam)
        @test _no_errors(gui, new)
        close(new)
        close(gui)
    end

    @testset "the page \"Edit\" is followed" begin
        gui, a, b = _views(; layout = :app)
        entry = only(e for e in component_catalog() if e.name == "Thin lens")
        built = GUI._catalog_component(entry, String[GUI._catalog_string(p) for p in entry.params])
        translate3d!(built.obj, [0.3, 0.02, 0])
        add_component!(gui, built.obj; system = b.sys, origin = built.origin)
        new = open_system(gui, b.sys; display = false)
        old = built.obj
        # what the first window knows of the component of the catalog
        @test GUI._editable(new, old) && _in(old, new.components.added)
        name = GUI._label(gui, old)
        GUI._set_edit_string!(new, old, 1, "80")
        GUI._apply_edit!(new, old; read = false)
        lens = last(b.sys.objects)
        @test lens !== old && !_in(old, b.sys.objects)
        @test _shown(gui, lens) && !_shown(gui, old)
        @test GUI._label(gui, lens) == GUI._label(new, lens) == name
        # the head of the inspector shows the name that the new component took over
        @test new.controls.selected[] === lens && new.layout.inspector.name.text[] == name
        @test GUI._editable(gui, lens)
        # undo in the window that edited
        GUI._undo!(new.controls)
        @test _shown(gui, old) && !_shown(gui, lens) && GUI._label(gui, old) == name
        @test _no_errors(gui, new)
        close(new)
        close(gui)
    end

    @testset "outdated beams" begin
        gui, a, b = _views(; auto_trace = false)
        GUI._trace!(gui)
        new = open_system(gui, b.sys; display = false)
        @test !new.trace.auto[] && new.trace.stale
        GUI._trace!(new)
        @test !new.trace.stale && !gui.trace.stale
        # a change in one window: both are outdated, and tracing in either brings both up to date
        for (here, there, tracer) in ((new, gui, new), (new, gui, gui), (gui, new, new), (gui, new, gui))
            box = _bbox(there, b.lens)
            _move!(here, b.lens)
            @test here.trace.stale && !here.trace.link_stale
            @test there.trace.stale && there.trace.link_stale
            @test there.status.text[] == GUI._LINK_STALE
            # the object follows at once, the beams are dimmed
            @test !_same_box(_bbox(there, b.lens), box)
            @test all(p -> p.alpha[] == GUI._STALE_ALPHA, render_plots(last(there.beam_handles)))
            GUI._trace!(tracer)
            @test !here.trace.stale && !there.trace.stale && !there.trace.link_stale
            @test all(p -> p.alpha[] != GUI._STALE_ALPHA, render_plots(last(there.beam_handles)))
            @test _points(there, b.beam) == _points(here, b.beam)
        end
        # the first window is outdated on its own: the solve of the new one, which does not trace
        # all of its beams, leaves it outdated
        _move!(gui, a.lens)
        @test gui.trace.stale && !new.trace.stale
        _move!(new, b.lens)
        GUI._trace!(new)
        @test !new.trace.stale && gui.trace.stale && !gui.trace.link_stale
        GUI._trace!(gui)
        @test !gui.trace.stale && !new.trace.stale
        @test _no_errors(gui, new)
        close(new)
        close(gui)
    end

    @testset "a job of a linked view is cancelled" begin
        gui, a, b = _views()
        new = open_system(gui, b.sys; display = false)
        # A job that runs until it is cancelled
        function job(view, timing)
            sink = BMO.ProgressSink()
            done = Base.Event()
            task = Threads.@spawn try
                while !sink.cancel[]
                    sleep(0.001)
                end
            finally
                notify(done)
            end
            j = GUI._SolveJob(task, done, [sink], [Point3f(0)], r -> nothing, nothing, timing, time(),
                (; k = 0, t0 = NaN, t = NaN, count = 0))
            view.trace.job = j
            return j
        end
        # a solve of the first window, cancelled by a change in the new one
        j = job(gui, :solve_time)
        @test GUI._running(new) && GUI._running(gui)
        _move!(new, b.lens)
        @test istaskdone(j.task) && isnothing(gui.trace.job)
        # it traces again once the changes pause; the new window, which solved, is up to date
        @test gui.trace.stale && gui.trace.pending && !new.trace.stale
        gui.trace.last_change -= 1
        GUI._on_idle!(gui)
        @test !gui.trace.stale && !gui.trace.pending && !new.trace.stale
        # a computation of detector views does not keep the linked view from solving, and is
        # cancelled by its change: outdated only until that view has solved
        j = job(gui, :view_time)
        @test !GUI._running(new) && GUI._running(gui)
        _move!(new, b.lens)
        @test istaskdone(j.task) && isnothing(gui.trace.job)
        @test !gui.trace.stale && !gui.trace.pending && !new.trace.stale
        # views that share no system leave the jobs of each other alone
        first_only = open_system(gui, a.sys; display = false)
        j = job(first_only, :solve_time)
        @test !GUI._running(new) && GUI._running(gui)
        _move!(new, b.lens)
        @test !istaskdone(j.task) && first_only.trace.job === j
        _move!(gui, b.lens)
        @test istaskdone(j.task)
        @test _no_errors(gui, new, first_only)
        close(first_only)
        close(new)
        close(gui)
    end

    @testset "detector views are followed" begin
        m = _mirror(0.0, 0.1)
        pd = Detector(5e-3)
        zrotate3d!(pd, -π / 2)
        translate3d!(pd, [0.1, 0.1, 0])
        sys = System([m, pd])
        src = GaussianBeamlet([0.0, 0, 0], [0.0, 1, 0], 1e-6, 0.5e-3)
        other = _setup(0.3)
        gui = _live_view(sys => src, other.sys => other.beam; fine_step = 1e-4)
        new = open_system(gui, sys; display = false, detectors = [pd])
        state = GUI._detector_state(new, pd)
        @test !state.stale && !isnothing(state.result)
        result = state.result
        _move!(gui, m)
        @test !state.stale && state.result !== result
        @test new.detectors.hits_valid
        @test _no_errors(gui, new)
        close(new)
        close(gui)
    end

    @testset "several windows and the end of a link" begin
        gui, a, b = _views()
        new = open_system(gui, b.sys; display = false)
        # the same system again, from the new window
        third = open_system(new, b.sys; display = false)
        @test gui.links === third.links && length(gui.links.views) == 3
        points = _points(third, b.beam)
        _move!(gui, b.mirror)
        @test _points(third, b.beam) != points
        @test _points(third, b.beam) == _points(new, b.beam) == _points(gui, b.beam)
        m = _mirror(0.3, 0.03)
        add_component!(third, m)
        @test _shown(gui, m) && _shown(new, m)
        # a closed view is no longer followed and follows no longer
        close(third)
        @test isempty(third.links.views) && gui.links.views == Any[gui, new]
        remove_component!(gui, m)
        @test !_shown(new, m)
        # the window of a view that is closed
        events(new.fig.scene).window_open[] = true
        events(new.fig.scene).window_open[] = false
        @test isempty(gui.links.views) && isempty(new.links.views) && gui.links !== new.links
        # both go on alone, with their names
        @test GUI._label(new, b.lens) == GUI._label(gui, b.lens)
        box = _bbox(new, b.lens)
        _move!(gui, b.lens)
        @test _same_box(_bbox(new, b.lens), box)
        @test !gui.trace.stale && _target(b.beam) === b.lens
        m2 = _mirror(0.3, 0.02)
        add_component!(gui, m2; system = b.sys)
        @test !_shown(new, m2)
        @test _no_errors(gui, new, third)
        close(new)
        close(gui)
    end

    @testset "undo history" begin
        gui, a, b = _views()
        ctrl = gui.controls
        # an action that no longer applies is dropped with a warning
        GUI._push_action!(ctrl, b.lens, () -> throw(ArgumentError("gone")), () -> nothing)
        @test_logs (:warn,) match_mode = :any (@test !GUI._undo!(ctrl))
        @test isempty(ctrl.undo_stack) && isempty(ctrl.redo_stack)
        # other errors are thrown
        GUI._push_action!(ctrl, b.lens, () -> error("bug"), () -> nothing)
        @test_throws ErrorException GUI._undo!(ctrl)
        empty!(ctrl.redo_stack)
        # the entries on objects are dropped
        _move!(gui, b.lens)
        _move!(gui, b.mirror)
        @test length(ctrl.undo_stack) == 2
        GUI._drop_history!(ctrl, [b.lens])
        @test only(ctrl.undo_stack).obj === b.mirror
        close(gui)
    end

    @testset "the button of the card of a system, $layout" for layout in (:compact, :app)
        gui, a, b = _views(; layout)
        @test [w.name for w in card_actions(b.sys)] == [:hide, :open]
        @test [w.name for w in card_actions(a.lens)] == [:hide]
        GUI._inspect!(gui, b.sys)
        # an icon in the head of the card: two windows, not the one that floats a docked card
        button = GUI._card_widget(_card(gui), :open)
        @test button isa GUI._IconButton && button.icon[] === GUI._icon(:window)
        @test button.icon[] !== GUI._icon(:float)
        button.clicks[] += 1
        @test length(gui.links.views) == 2
        new = last(gui.links.views)
        @test only(GUI._systems(new)) === b.sys
        @test occursin("opened in a new window", gui.status.text[])
        # the window is shown, and closing it ends the link
        screen = Makie.getscreen(new.fig.scene)
        @test !isnothing(screen) && isopen(screen)
        close(screen)
        @test isempty(gui.links.views)
        close(new)
        close(gui)
    end
end

end
