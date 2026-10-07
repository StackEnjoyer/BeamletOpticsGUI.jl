#=
The sessions of simulated mouse and key actions that the workload of the extension replays in an
invisible GLMakie window, see `_precompile_sessions`. Each action is a step `step(f, name)`, which
runs `f`: the workload swallows the error of a step, `test/TestPrecompileSession.jl` rethrows it and
`benchmark/jit_probe.jl` measures the compilation of each step.

A patch that adds an action of the mouse or the keys to the GUI adds a step here, see `AGENTS.md`.
=#

"""
The scene of `_session`: a `system` with a `mirror`, a `lens` and a `detector`, and its `beam`. The
fields have no types, such that the session is not compiled again for the types of another scene.
"""
struct _Fixture
    system::BMO.AbstractSystem
    mirror::Any
    lens::Any
    detector::Any
    beam::Any
end

"""
    _fixture(beam = Beam([0.0, 0, 0], [0.0, 1, 0])) -> _Fixture

The scene of the workload: the `beam` along +y through the `lens` onto the `mirror` at 45°, which
reflects it along +x onto the `detector`.
"""
function _fixture(beam = Beam([0.0, 0, 0], [0.0, 1, 0]))
    mirror = RoundPlanoMirror(25e-3, 5e-3)
    zrotate3d!(mirror, deg2rad(45))
    translate3d!(mirror, [0, 0.1, 0])
    lens = SphericalLens(0.05, -0.05, 5e-3, 25.4e-3)
    translate3d!(lens, [0, 0.05, 0])
    detector = Detector(5e-3)
    zrotate3d!(detector, -π / 2)
    translate3d!(detector, [0.1, 0.1, 0])
    return _Fixture(System([mirror, lens, detector]), mirror, lens, detector, beam)
end

#=
Events of the window of a live view, as GLFW sends them
=#

_events(gui) = events(gui.ax.scene)

# An invisible window without the render loop of GLMakie: the session sends the ticks and draws the
# images itself, such that nothing runs beside its steps
_screen() = GLMakie.Screen(; visible = false, start_renderloop = false)

# What a step must have done: otherwise the session does not use what it is meant to compile
_check(done::Bool, msg) = done || error(msg)
_selected(gui, @nospecialize(obj)) =
    _check(gui.controls.selected[] === obj, "the click did not select the $(nameof(typeof(obj)))")

"""The pixel of the window of the `gui` that shows the point `p` of its 3D view."""
function _px(gui, p)
    scene = gui.ax.scene
    vp = scene.viewport[]
    q = Makie.project(scene, :data, :pixel, Point3f(p...))
    return (Float64(vp.origin[1] + q[1]), Float64(vp.origin[2] + q[2]))
end
_pos(obj) = Vector{Float64}(BMO.position(obj))
# How far [px] a free pixel is from everything, e.g. from a beam, which a click near it inspects
const _FREE_RANGE = 40

"""
A pixel of the 3D view of the `gui` that shows nothing within `_FREE_RANGE`: no component, beam,
card or widget.
"""
function _free_px(gui)
    vp = gui.ax.scene.viewport[]
    o, w = minimum(vp), widths(vp)
    for fy in (0.5, 0.3, 0.7, 0.15, 0.85), fx in (0.2, 0.8, 0.35, 0.65, 0.1, 0.9)
        p = (Float64(o[1] + fx * w[1]), Float64(o[2] + fy * w[2]))
        isnothing(first(Makie.pick(gui.fig.scene, Point2f(p), _FREE_RANGE))) && return p
    end
    error("the 3D view has no free pixel")
end
# The pixel in the middle of a block of the layout, e.g. of the title of a card
_rect_center(block) = (r = block.layoutobservables.computedbbox[]; Tuple(Float64.(minimum(r) .+ widths(r) ./ 2)))
_center(gui) = Tuple(Float64.(minimum(gui.ax.scene.viewport[]) .+ widths(gui.ax.scene.viewport[]) ./ 2))
# The pixel in the middle of the splitter of a sidebar `part`: its right (`side = 1`) or left edge
function _splitter_px(part, side)
    r = part.box.layoutobservables.computedbbox[]
    return (Float64((side > 0 ? maximum(r) : minimum(r))[1]), Float64(minimum(r)[2] + widths(r)[2] / 2))
end

_move!(gui, xy) = (_events(gui).mouseposition[] = (Float64(xy[1]), Float64(xy[2])))
_press!(gui, button = Mouse.left) = (_events(gui).mousebutton[] = Makie.MouseButtonEvent(button, Mouse.press))
_release!(gui, button = Mouse.left) = (_events(gui).mousebutton[] = Makie.MouseButtonEvent(button, Mouse.release))
_click!(gui) = (_press!(gui); _release!(gui))
_click!(gui, xy) = (_move!(gui, xy); _click!(gui))
# A tick of the render loop, once the solve of the step is done, such that the step shows its
# result: while precompiling, a solve is slow and may continue in the background
function _tick!(gui)
    wait_solve(gui)
    _events(gui).tick[] = Makie.Tick(Makie.RegularRenderTick, 0, 0.0, 1 / 60)
    return nothing
end
# A tick and a rendered image, such that the plots that an action shows are drawn
_frame!(gui, screen) = (_tick!(gui); Makie.colorbuffer(screen); nothing)

"""
Runs the animation of the camera of the `gui` to its end and draws an image after its solve (see
`_tick!`), such that the next step finds the same view whatever time the steps take.
"""
function _settle!(gui, screen)
    for _ in 1:600
        isnothing(gui.camera.animation) && break
        _tick!(gui)
    end
    return _frame!(gui, screen)
end

"""Moves the mouse over the whole window of the `gui`, i.e. over its widgets, cards and views."""
function _sweep!(gui)
    w, h = size(gui.fig.scene)
    for y in range(8, h - 8; length = 9), x in range(8, w - 8; length = 13)
        _move!(gui, (x, y))
    end
    return nothing
end

function _key!(gui, key, modifiers...)
    ev = _events(gui)
    foreach(m -> ev.keyboardbutton[] = Makie.KeyEvent(m, Keyboard.press), modifiers)
    ev.keyboardbutton[] = Makie.KeyEvent(key, Keyboard.press)
    ev.keyboardbutton[] = Makie.KeyEvent(key, Keyboard.release)
    foreach(m -> ev.keyboardbutton[] = Makie.KeyEvent(m, Keyboard.release), modifiers)
    return nothing
end

function _drag!(gui, a, b; button = Mouse.left, n = 6)
    _move!(gui, a)
    _press!(gui, button)
    for t in range(0, 1; length = n)
        _move!(gui, a .+ t .* (b .- a))
        _tick!(gui)
    end
    _release!(gui, button)
    return nothing
end

"""
    _session(step, layout, fixture = _fixture()) -> (gui, screen)

Opens a live view of the `fixture` (see `_fixture`) in the `layout` in an invisible window and uses
it with the mouse and the keys: hover, selection, dragging in both modes and with the gizmo, key
steps, undo, snapping, the camera, the view cube, the inspection of a beam, clip planes, the
catalog, placing, copy and paste, removing, and in the app layout the object tree (with the button
"+" of the system, which picks its members) and the splitters of the sidebars. Returns the live view and its screen, which the caller closes.

The steps do not depend on the time that they take, which is much longer while they are compiled:
the animations of the camera are run to their end and the solves are awaited (see `_settle!`), and
a step checks what it did (see `_check`).
"""
function _session(step, layout::Symbol, fixture::_Fixture = _fixture())
    # the closures of the steps keep the fixture, not its components, see `_Fixture`
    fx = fixture

    gui = step(() -> live_view(fx.system, fx.beam; layout), "live_view")
    screen = step("display + first frame") do
        s = _screen()
        display(s, gui.fig)
        Makie.colorbuffer(s)
        s
    end
    frame!() = _frame!(gui, screen)
    settle!() = _settle!(gui, screen)
    deselect!() = (_click!(gui, _free_px(gui)); frame!(); _selected(gui, nothing))
    home!() = (GUI._go_home!(gui); settle!())
    step(frame!, "second frame")
    step(settle!, "wait_solve + frame")

    step(() -> (_sweep!(gui); frame!()), "hover: sweep over the window")
    step(() -> (_move!(gui, _free_px(gui)); frame!()), "hover background")
    step(() -> (_move!(gui, _px(gui, _pos(fx.mirror))); frame!()), "hover mirror")
    step(() -> (_click!(gui); frame!(); _selected(gui, fx.mirror)), "click mirror (select)")
    step("drag mirror: press + first move") do
        _press!(gui)
        _move!(gui, _px(gui, _pos(fx.mirror)) .+ (12, 3))
        frame!()
    end
    step("drag mirror: 5 more moves") do
        for k in 1:5
            _move!(gui, _px(gui, _pos(fx.mirror)) .+ (12 + 3k, 3))
            _tick!(gui)
        end
        frame!()
    end
    step(() -> (_release!(gui); frame!()), "drag mirror: release")
    step(settle!, "wait_solve + frame after drag")
    step("drag mirror again") do
        a = _px(gui, _pos(fx.mirror))
        _drag!(gui, a, a .+ (20, 5))
        settle!()
    end
    if layout == :compact
        step("card: drag by its title") do
            a = _rect_center(gui.cards.selection.title)
            _drag!(gui, a, a .+ (30, 20))
            frame!()
        end
    end

    drag_lens!() = (a = _px(gui, _pos(fx.lens)); _drag!(gui, a, a .+ (20, 5)); settle!())
    step(deselect!, "click background (deselect)")
    step(() -> (_click!(gui, _px(gui, _pos(fx.lens))); frame!(); _selected(gui, fx.lens)), "click lens (select)")
    step(drag_lens!, "drag lens")

    # the gizmo: an arrow in the move mode, a ring in the rotate mode
    step("drag arrow of the gizmo") do
        c = gui.controls
        a = _px(gui, c.arrow_pos[][1] .+ 0.7 .* c.arrow_dir[][1])
        _move!(gui, a)
        frame!()
        _drag!(gui, a, a .+ (15, 15))
        settle!()
    end
    step(() -> (_key!(gui, Keyboard.m); frame!()), "key m (rotate mode)")
    step("drag ring of the gizmo") do
        a = _px(gui, gui.controls.ring_pts[][5])
        _move!(gui, a)
        frame!()
        _drag!(gui, a, a .+ (15, 15))
        settle!()
    end
    step(drag_lens!, "drag lens (rotate mode)")
    step(() -> (_key!(gui, Keyboard.m); frame!()), "key m (move mode)")

    step("key steps") do
        foreach(k -> _key!(gui, k), (Keyboard.up, Keyboard.left, Keyboard.page_up))
        _key!(gui, Keyboard.up, Keyboard.left_shift)
        _events(gui).unicode_input[] = '+'
        _events(gui).unicode_input[] = '-'
        settle!()
    end
    step(() -> (_key!(gui, Keyboard.z, Keyboard.left_control); settle!()), "undo")
    step(() -> (_key!(gui, Keyboard.y, Keyboard.left_control); settle!()), "redo")
    step(() -> (_key!(gui, Keyboard.backspace); settle!()), "reset pose")
    step(() -> (_key!(gui, Keyboard.tab); frame!()), "key tab (snap: position)")
    step(drag_lens!, "drag lens (snap on)")
    step(() -> (_key!(gui, Keyboard.tab); drag_lens!()), "key tab (snap: position + rotation) + drag")
    step(() -> (_key!(gui, Keyboard.tab); frame!()), "key tab (snap off)")
    step(() -> (_key!(gui, Keyboard.g); settle!()), "key g (zoom to the selection)")
    step(home!, "camera: home")

    step(deselect!, "click background (deselect) again")
    step("click detector (select)") do
        _click!(gui, _px(gui, _pos(fx.detector)))
        settle!()
        _selected(gui, fx.detector)
    end
    step(deselect!, "click background (deselect) of the detector")

    step("camera: rotate (left drag)") do
        a = _free_px(gui)
        _drag!(gui, a, a .+ (40, 20))
        frame!()
    end
    step("camera: pan (right drag)") do
        a = _free_px(gui)
        _drag!(gui, a, a .+ (40, 20); button = Mouse.right)
        frame!()
    end
    step(() -> (_move!(gui, _free_px(gui)); _events(gui).scroll[] = (0.0, 1.0); frame!()), "camera: zoom (scroll)")
    step(home!, "camera: home after the drags")

    cube = gui.widgets.view_cube
    if !isnothing(cube)
        top = Tuple(Float64.(Makie.shift_project(cube.scene, Point3f(0, 0, 1))))
        step(() -> (_move!(gui, top); frame!()), "view cube: hover")
        step(() -> (_click!(gui); settle!()), "view cube: click")
        step(home!, "camera: home after the view cube")
    end

    step("click beam (inspect)") do
        _click!(gui, _px(gui, [0, 0.025, 0]))
        frame!()
        _check(!isnothing(gui.measure.inspection), "the click did not inspect the beam")
    end
    step(() -> (_key!(gui, Keyboard.escape); frame!()), "key escape")
    step("key p (clip plane)") do
        _key!(gui, Keyboard.p)
        frame!()
        _check(gui.controls.selected[] isa GUI.LiveClipPlane, "no clip plane was added")
    end
    step(() -> (_key!(gui, Keyboard.c); frame!()), "key c (clipping)")
    step(() -> (_key!(gui, Keyboard.delete); frame!()), "delete clip plane")
    step(() -> (_key!(gui, Keyboard._1); _key!(gui, Keyboard._1); frame!()), "key 1 (source markers)")
    step(() -> (_key!(gui, Keyboard.t); settle!()), "key t (trace)")
    step(() -> (_key!(gui, Keyboard.h); frame!(); _key!(gui, Keyboard.h); frame!()), "key h (help)")

    # The members of a system are picked with the mouse: "+" on its card, a click on a component, Esc
    step("system: + on its card, click mirror (pick), escape") do
        GUI._inspect!(gui, fx.system)
        frame!()
        i = findfirst(c -> !isnothing(GUI._card_widget(c, :member_add)), GUI._edit_cards(gui))
        _check(!isnothing(i), "the card of the system has no button +")
        _click!(gui, _rect_center(GUI._card_widget(GUI._edit_cards(gui)[i], :member_add)))
        frame!()
        _check(!isnothing(GUI._member_pick(gui)), "+ did not start the pick")
        _click!(gui, _px(gui, _pos(fx.mirror)))
        frame!()
        _check(isnothing(gui.controls.selected[]) && occursin("already in", gui.status.text[]),
            "the click did not pick the mirror")
        _key!(gui, Keyboard.escape)
        frame!()
        _check(isnothing(GUI._member_pick(gui)), "Esc did not end the pick")
        _key!(gui, Keyboard.escape)
        frame!()
        _check(isnothing(gui.objects.inspected), "Esc did not close the card of the system")
    end

    step(() -> (_move!(gui, _center(gui)); _key!(gui, Keyboard.insert); frame!()), "catalog: Insert")
    step(() -> (_key!(gui, Keyboard.escape); frame!()), "catalog: escape")
    # a component of the catalog, which can be copied
    entry = first(e for e in component_catalog() if !e.source)
    placed = Ref{Any}(nothing)
    step("placement: start + moves") do
        placed[] = GUI._place_catalog!(gui, entry, _catalog_strings(entry))
        a = _free_px(gui)
        for k in 1:4
            _move!(gui, a .+ (3k, 0))
            _tick!(gui)
        end
        frame!()
    end
    step("placement: drop") do
        _click!(gui)
        settle!()
        _check(GUI._has(fx.system.objects, placed[]), "the component was not dropped")
    end
    step(() -> (_key!(gui, Keyboard.c, Keyboard.left_control); frame!()), "copy")
    step("paste + drop") do
        n = length(fx.system.objects)
        _key!(gui, Keyboard.v, Keyboard.left_control)
        _move!(gui, _free_px(gui))
        frame!()
        _click!(gui)
        settle!()
        _check(length(fx.system.objects) == n + 1, "the copy was not dropped")
    end
    step(() -> (_key!(gui, Keyboard.delete); settle!()), "delete selected")
    step(() -> (_key!(gui, Keyboard.v); frame!(); _key!(gui, Keyboard.v); frame!()), "key v (spectator mode)")

    if layout == :app
        tree = gui.layout.tree
        step(() -> (tree.clicked[] = fx.detector; settle!()), "tree: click detector")
        step("tree: eye") do
            tree.eye_clicked[] = fx.detector
            frame!()
            tree.eye_clicked[] = fx.detector
            frame!()
        end
        step("tree: + of the system (pick its members)") do
            i = findfirst(r -> !isnothing(r.buttons), tree.rows)
            # the pixel of the button "+" of the row of the system
            o = minimum(tree.scene.viewport[])
            a = (Float64(o[1] + GUI._button_columns(tree).add), Float64(o[2] + GUI._row_y(tree, i)))
            _click!(gui, a)
            frame!()
            pick = GUI._member_pick(gui)
            _check(!isnothing(pick) && pick.add && pick.sys === fx.system, "the click did not start the pick")
            # a second click ends it
            _click!(gui, a)
            frame!()
            _check(isnothing(GUI._member_pick(gui)), "the second click did not end the pick")
        end
        # the splitters, the right one with the view of the detector in the inspector
        step("splitter: drag the right sidebar") do
            right = gui.layout.right
            w = right.size.x
            a = _splitter_px(right, -1)
            _move!(gui, a)
            frame!()
            _drag!(gui, a, a .- (40, 0))
            settle!()
            _check(right.size.x == w + 40, "the drag did not resize the right sidebar")
        end
        step(() -> (tree.clicked[] = fx.mirror; frame!()), "tree: click mirror")
        step("splitter: drag the left sidebar") do
            left = gui.layout.left
            w = left.size.x
            a = _splitter_px(left, 1)
            _move!(gui, a)
            frame!()
            _drag!(gui, a, a .+ (50, 0))
            settle!()
            _check(left.size.x == w + 50, "the drag did not resize the left sidebar")
        end
    end

    return gui, screen
end

# Few rays, such that the sources of the catalog are traced quickly
const _CATALOG_SMALL = Dict("rings" => "2", "rays" => "50")

"""The texts of the form of the catalog `entry`: its defaults, with few rays for a source."""
_catalog_strings(entry) =
    String[get(_CATALOG_SMALL, p.name, GUI._catalog_string(p)) for p in entry.params]

"""
    _catalog_session(step, entries = component_catalog()) -> (gui, screen)

Opens a live view in an invisible window and places each of the `entries` of the catalog with the
mouse onto its beam, selects it with a click, drags it and removes it with `Delete`, such that the
code of the GUI and of BeamletOptics for the types of the catalog is compiled. The snapping is on,
and with each source of the catalog in the view, the lens of the view is dragged, which snaps onto
its beams. Returns the live view and its screen, which the caller closes.
"""
function _catalog_session(step, entries = component_catalog())
    # a view with a component is needed: the first component of an empty view is not placed with
    # the mouse
    mirror = RoundPlanoMirror(25e-3, 5e-3)
    zrotate3d!(mirror, deg2rad(45))
    translate3d!(mirror, [0, 0.3, 0])
    lens = SphericalLens(0.05, -0.05, 5e-3, 25.4e-3)
    translate3d!(lens, [0, 0.2, 0])
    gui = live_view(System([lens, mirror]), Beam([0.0, 0, 0], [0.0, 1, 0]))
    screen = _screen()
    display(screen, gui.fig)
    frame!() = _frame!(gui, screen)
    settle!() = _settle!(gui, screen)
    settle!()
    _key!(gui, Keyboard.tab)
    # on the beam, before the lens
    at = [0.0, 0.1, 0.0]
    for entry in entries
        obj = step("catalog, $(entry.name): place") do
            o = GUI._place_catalog!(gui, entry, _catalog_strings(entry))
            isnothing(o) && error(gui.status.text[])
            _move!(gui, _px(gui, at) .+ (3, 0))
            _tick!(gui)
            _move!(gui, _px(gui, at))
            frame!()
            _click!(gui)
            settle!()
            _check(!GUI._placing(gui), "the $(entry.name) was not dropped")
            o
        end
        if isnothing(obj)
            GUI._cancel_placement!(gui)
            continue
        end
        step("catalog, $(entry.name): select + drag") do
            a = _px(gui, _pos(obj))
            _click!(gui, a)
            # the click misses a component that does not lie at its position, e.g. an off-axis mirror
            gui.controls.selected[] === obj || select!(gui, obj)
            frame!()
            _drag!(gui, a, a .+ (12, 4))
            settle!()
            if entry.source
                select!(gui, lens)
                b = _px(gui, _pos(lens))
                _drag!(gui, b, b .+ (6, 2))
                settle!()
            end
        end
        step("catalog, $(entry.name): delete") do
            gui.controls.selected[] === obj || select!(gui, obj)
            _key!(gui, Keyboard.delete)
            settle!()
        end
    end
    return gui, screen
end

"""
    _precompile_sessions(step)

The sessions of the workload: `_session` in both layouts, with a beam and with a Gaussian beamlet,
and `_catalog_session`. Closes their windows.
"""
function _precompile_sessions(step)
    # Without an OpenGL context, e.g. on a headless machine, no window opens: the error is thrown
    # here, to the caller, instead of in every step of the sessions, where `step` may swallow it
    close(_screen())
    gauss() = GaussianBeamlet([0.0, 0, 0], [0.0, 1, 0], 1e-6, 0.5e-3)
    for (layout, fixture) in ((:compact, _fixture()), (:app, _fixture(gauss())),
            (:compact, _fixture(gauss())), (:app, _fixture()))
        _close!(_session(step, layout, fixture)...)
    end
    _close!(_catalog_session(step)...)
    return nothing
end

function _close!(gui, screen)
    isnothing(gui) || close(gui)
    isnothing(screen) || close(screen)
    return nothing
end
