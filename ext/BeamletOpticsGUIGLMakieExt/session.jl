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
# ... or of an icon button, e.g. the eye in the head of a card
_rect_center(b::Union{GUI._IconButton, GUI._IconToggle}) = _rect_center(b.box)
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
# The time of the ticks: one second per tick, otherwise Makie takes two clicks of consecutive steps
# for a double click, which it measures with the time of the ticks; the GUI animates with their
# `delta_time` only
const _CLOCK = Ref(0.0)
# A tick of the render loop, once the solve of the step is done, such that the step shows its
# result: while precompiling, a solve is slow and may continue in the background
function _tick!(gui)
    wait_solve(gui)
    _CLOCK[] += 1.0
    _events(gui).tick[] = Makie.Tick(Makie.RegularRenderTick, 0, _CLOCK[], 1 / 60)
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

# Holds (`Keyboard.press`) or lets go of (`Keyboard.release`) the left Ctrl key
_ctrl!(gui, action) = (_events(gui).keyboardbutton[] = Makie.KeyEvent(Keyboard.left_control, action))

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
steps, undo, snapping, the camera, the view cube, the inspection of a beam, clip planes, the eye
of a card, the card of a system (its pencil, its "+", the rows of its members and their "×"), the
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

    # Several objects at once: Ctrl+click adds to and removes from the selection, which is dragged,
    # stepped by the keys and reset as one
    ctrl_click!(xy) = (_ctrl!(gui, Keyboard.press); _click!(gui, xy); _ctrl!(gui, Keyboard.release))
    in_selection(objs...) = _check(GUI._selection_objects(gui.controls.selected[]) == Any[objs...],
        "the selection does not hold the $(join((nameof(typeof(o)) for o in objs), " and "))")
    step("ctrl+click lens and mirror (select both)") do
        _click!(gui, _px(gui, _pos(fx.lens)))
        frame!()
        ctrl_click!(_px(gui, _pos(fx.mirror)))
        frame!()
        in_selection(fx.lens, fx.mirror)
    end
    step("drag the selection of several") do
        a = _px(gui, _pos(fx.lens))
        _drag!(gui, a, a .+ (20, 5))
        settle!()
        in_selection(fx.lens, fx.mirror)
    end
    step("key steps, undo and reset of the selection of several") do
        _key!(gui, Keyboard.up)
        _key!(gui, Keyboard.z, Keyboard.left_control)
        _key!(gui, Keyboard.backspace)
        settle!()
    end
    step("ctrl+click mirror (remove it from the selection)") do
        ctrl_click!(_px(gui, _pos(fx.mirror)))
        frame!()
        _selected(gui, fx.lens)
    end
    step("delete the selection of several, undo") do
        ctrl_click!(_px(gui, _pos(fx.mirror)))
        frame!()
        in_selection(fx.lens, fx.mirror)
        _key!(gui, Keyboard.delete)
        settle!()
        _check(!GUI._has(fx.system.objects, fx.mirror), "the delete did not remove the selection")
        # not by the key: `Ctrl+Z` is "Ctrl+Y" on a keyboard with another layout, see `_layout_key`
        GUI._undo!(gui.controls)
        settle!()
        _check(GUI._has(fx.system.objects, fx.mirror) && GUI._has(fx.system.objects, fx.lens),
            "the undo did not restore the selection")
    end
    # Groups made in the window: Ctrl+G groups the selection of several, which is then dragged like a
    # group, Ctrl+Shift+G ungroups it; the undo history takes the ungrouping back and does it again
    is_group() = GUI._is_window_group(gui, gui.controls.selected[])
    step("ctrl+g (group lens and mirror)") do
        _click!(gui, _px(gui, _pos(fx.lens)))
        frame!()
        ctrl_click!(_px(gui, _pos(fx.mirror)))
        frame!()
        in_selection(fx.lens, fx.mirror)
        _key!(gui, Keyboard.g, Keyboard.left_control)
        settle!()
        _check(is_group(), "Ctrl+G did not make a group")
    end
    step("drag the group made in the window") do
        a = _px(gui, _pos(fx.lens))
        _drag!(gui, a, a .+ (20, 5))
        settle!()
        _check(is_group(), "the drag did not keep the group selected")
    end
    step("ctrl+shift+g (ungroup), undo, redo") do
        _key!(gui, Keyboard.g, Keyboard.left_control, Keyboard.left_shift)
        settle!()
        in_selection(fx.lens, fx.mirror)
        GUI._undo!(gui.controls)
        settle!()
        _check(is_group(), "the undo did not group again")
        GUI._redo!(gui.controls)
        settle!()
        _check(GUI._has(fx.system.objects, fx.mirror) && GUI._has(fx.system.objects, fx.lens),
            "the redo did not ungroup")
        # the later steps find the scene of before: grouped again, the drag and the grouping undone
        foreach(_ -> GUI._undo!(gui.controls), 1:3)
        settle!()
        _check(GUI._has(fx.system.objects, fx.mirror) && GUI._has(fx.system.objects, fx.lens),
            "the undo did not ungroup")
    end
    # A group made in the window that is part of another one is dissolved into it by Ctrl+Shift+G:
    # the other group stays the same object and gets the members, one action of the undo history
    flat() = all(o -> GUI._has(fx.system.objects, o), (fx.lens, fx.mirror, fx.detector))
    inner = Ref{Any}(nothing)
    outer = Ref{Any}(nothing)
    step("ctrl+g (group lens and mirror, then that group and the detector)") do
        _click!(gui, _px(gui, _pos(fx.lens)))
        frame!()
        ctrl_click!(_px(gui, _pos(fx.mirror)))
        frame!()
        _key!(gui, Keyboard.g, Keyboard.left_control)
        settle!()
        _check(is_group(), "Ctrl+G did not make the inner group")
        inner[] = gui.controls.selected[]
        ctrl_click!(_px(gui, _pos(fx.detector)))
        frame!()
        in_selection(inner[], fx.detector)
        _key!(gui, Keyboard.g, Keyboard.left_control)
        settle!()
        _check(is_group() && gui.controls.selected[] !== inner[], "Ctrl+G did not make the outer group")
        outer[] = gui.controls.selected[]
    end
    step("ctrl+shift+g (dissolve the inner group), undo, redo") do
        out = outer[]
        parts() = collect(Any, BMO.objects(out))
        three() = parts() == Any[fx.lens, fx.mirror, fx.detector]
        GUI._select!(gui, inner[])
        settle!()
        _check(gui.controls.selected[] === inner[], "the inner group is not selected")
        _check(parts() == Any[inner[], fx.detector], "the outer group does not hold the inner group")
        n = length(gui.controls.undo_stack)
        _key!(gui, Keyboard.g, Keyboard.left_control, Keyboard.left_shift)
        settle!()
        _check(length(gui.controls.undo_stack) == n + 1, "the dissolving is not one action of the undo history")
        _check(GUI._has(fx.system.objects, out) && three(),
            "Ctrl+Shift+G did not dissolve the inner group into the same outer group")
        in_selection(fx.lens, fx.mirror)
        GUI._undo!(gui.controls)
        settle!()
        _check(GUI._has(fx.system.objects, out) && parts() == Any[inner[], fx.detector] &&
               gui.controls.selected[] === inner[],
            "the undo did not bring back the inner group in the same outer group")
        GUI._redo!(gui.controls)
        settle!()
        _check(GUI._has(fx.system.objects, out) && three(), "the redo did not dissolve again")
        in_selection(fx.lens, fx.mirror)
        # the later steps find the scene of before: the dissolving and both groupings undone
        foreach(_ -> GUI._undo!(gui.controls), 1:3)
        settle!()
        _check(flat(), "the undo did not bring back the objects")
    end
    # The card buttons "group" (selection of several) and "ungroup" (group made in the window)
    step("card: group and ungroup buttons, undo, redo") do
        deselect!()
        _click!(gui, _px(gui, _pos(fx.lens)))
        frame!()
        ctrl_click!(_px(gui, _pos(fx.mirror)))
        frame!()
        in_selection(fx.lens, fx.mirror)
        cards = GUI._edit_cards(gui)
        i = findfirst(c -> !isnothing(GUI._card_widget(c, :group)), cards)
        _check(!isnothing(i), "no card of the selection of several has the button group")
        _click!(gui, _rect_center(GUI._card_widget(cards[i], :group)))
        settle!()
        _check(is_group(), "the button group did not make a group")
        g = gui.controls.selected[]
        cards = GUI._edit_cards(gui)
        i = findfirst(c -> GUI._card_object(gui, c) === g && !isnothing(GUI._card_widget(c, :ungroup)), cards)
        _check(!isnothing(i), "the card of the group has no button ungroup")
        _click!(gui, _rect_center(GUI._card_widget(cards[i], :ungroup)))
        settle!()
        in_selection(fx.lens, fx.mirror)
        GUI._undo!(gui.controls)
        settle!()
        _check(is_group(), "the undo did not group again")
        GUI._redo!(gui.controls)
        settle!()
        in_selection(fx.lens, fx.mirror)
        # the later steps find the scene of before
        foreach(_ -> GUI._undo!(gui.controls), 1:2)
        settle!()
        _check(flat(), "the undo did not bring back the objects")
    end
    # Several parts of one group: Ctrl+click on a sibling part adds it, Ctrl+G makes the parts a group
    # inside the group (also in a group of the script), one action of the undo history
    function subgroup!(parts, top, undo_n)
        GUI._select!(gui, parts[1])
        settle!()
        _check(gui.controls.selected[] === parts[1], "the part is not selected")
        ctrl_click!(_px(gui, _pos(parts[2])))
        frame!()
        in_selection(parts[1], parts[2])
        before = collect(Any, BMO.objects(top))
        kind = GUI._is_window_group(gui, top)
        _key!(gui, Keyboard.g, Keyboard.left_control)
        settle!()
        sub = gui.controls.selected[]
        _check(is_group() && sub !== top && GUI._has(fx.system.objects, top) &&
               BMO.objects(top)[1] === sub && !GUI._has(BMO.objects(top), parts[1]) &&
               GUI._has(BMO.objects(sub), parts[1]) && GUI._has(BMO.objects(sub), parts[2]),
            "Ctrl+G did not make the parts a group inside the same group")
        _check(length(gui.controls.undo_stack) == undo_n + 1, "the grouping is not one action of the undo history")
        GUI._undo!(gui.controls)
        settle!()
        _check(GUI._has(fx.system.objects, top) && collect(Any, BMO.objects(top)) == before,
            "the undo did not bring back the parts of the group")
        GUI._redo!(gui.controls)
        settle!()
        _check(GUI._has(fx.system.objects, top) && BMO.objects(top)[1] === sub && is_group(),
            "the redo did not group the parts again")
        _check(GUI._is_window_group(gui, top) == kind, "the grouping changed the kind of the group")
        GUI._undo!(gui.controls)
        settle!()
        _check(GUI._has(fx.system.objects, top) && collect(Any, BMO.objects(top)) == before,
            "the undo did not bring back the group")
    end
    step("ctrl+click a sibling part, ctrl+g (group inside a group made in the window), undo, redo") do
        deselect!()
        _click!(gui, _px(gui, _pos(fx.lens)))
        frame!()
        ctrl_click!(_px(gui, _pos(fx.mirror)))
        frame!()
        ctrl_click!(_px(gui, _pos(fx.detector)))
        frame!()
        _key!(gui, Keyboard.g, Keyboard.left_control)
        settle!()
        _check(is_group(), "Ctrl+G did not make the group")
        subgroup!((fx.lens, fx.mirror), gui.controls.selected[], length(gui.controls.undo_stack))
        # the later steps find the scene of before
        GUI._undo!(gui.controls)
        settle!()
        _check(flat(), "the undo did not bring back the objects")
    end
    step("ctrl+click a sibling part, ctrl+g (group inside a group of the script), undo, redo") do
        # a group of the script: it is added without being made in the window
        ms = [RoundPlanoMirror(10e-3, 3e-3) for _ in 1:3]
        foreach((m, y) -> translate3d!(m, [-0.05, y, 0]), ms, (0.0, 0.04, 0.08))
        sg = ObjectGroup(ms)
        add_component!(gui, sg; select = false)
        settle!()
        _check(GUI._has(fx.system.objects, sg) && !GUI._is_window_group(gui, sg), "no group of the script")
        subgroup!((ms[1], ms[2]), sg, length(gui.controls.undo_stack))
        # the later steps find the scene of before: the group of the script out again
        GUI._undo!(gui.controls)
        settle!()
        _check(flat() && !GUI._has(fx.system.objects, sg), "the undo did not remove the group of the script")
    end
    step(deselect!, "click background (deselect) after the groups")
    # Ctrl+drag beside the selection draws a rectangle, which adds the objects whose center it holds
    step("ctrl+drag a rectangle around lens and mirror") do
        deselect!()
        a, b = _px(gui, _pos(fx.lens)), _px(gui, _pos(fx.mirror))
        lo, hi = min.(a, b) .- 25, max.(a, b) .+ 25
        _ctrl!(gui, Keyboard.press)
        _move!(gui, lo)
        _press!(gui)
        _move!(gui, lo .+ 10)
        _check(gui.controls.rect_visible[], "the Ctrl+drag did not draw a rectangle")
        _move!(gui, hi)
        frame!()
        _release!(gui)
        _ctrl!(gui, Keyboard.release)
        settle!()
        sel = gui.controls.selected[]
        _check(GUI._in_selection(sel, fx.lens) && GUI._in_selection(sel, fx.mirror) &&
               !gui.controls.rect_visible[], "the rectangle did not select lens and mirror")
    end
    step(deselect!, "click background (deselect) of the selection")

    step("camera: rotate (left drag)") do
        a = _free_px(gui)
        _drag!(gui, a, a .+ (40, 20))
        frame!()
        _check(!isnothing(gui.camera.pivot) && gui.camera.pivot.visible[], "the drag did not show the pivot")
        _check(gui.camera.pivot_gesture == :rotate, "the left drag is not the gesture :rotate")
    end
    step("camera: pivot fades") do
        for _ in 1:600
            gui.camera.pivot.visible[] || break
            _tick!(gui)
        end
        frame!()
        _check(!gui.camera.pivot.visible[], "the pivot did not fade")
    end
    step("camera: pan (right drag)") do
        a = _free_px(gui)
        _drag!(gui, a, a .+ (40, 20); button = Mouse.right)
        frame!()
        _check(gui.camera.pivot_gesture == :pan, "the right drag is not the gesture :pan")
    end
    step("camera: zoom (scroll)") do
        _move!(gui, _free_px(gui))
        _events(gui).scroll[] = (0.0, 1.0)
        frame!()
        _check(gui.camera.pivot_gesture in (:zoom_in, :zoom_out), "the scroll is not a zoom gesture")
    end
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

    # The card that shows `obj` with the widget `name`: floating, or docked in the app layout
    function card_of(@nospecialize(obj), name::Symbol)
        cards = GUI._edit_cards(gui)
        i = findfirst(c -> GUI._card_object(gui, c) === obj && !isnothing(GUI._card_widget(c, name)), cards)
        _check(!isnothing(i), "no card shows the $(nameof(typeof(obj))) with :$name")
        return cards[i]
    end

    # The eye in the head of a card hides its object and shows it again
    step("card: eye (hide, show)") do
        _click!(gui, _px(gui, _pos(fx.mirror)))
        frame!()
        _selected(gui, fx.mirror)
        _click!(gui, _rect_center(GUI._card_widget(card_of(fx.mirror, :hide), :hide)))
        frame!()
        _check(GUI._all_hidden(gui, fx.mirror), "the eye did not hide the mirror")
        # a hidden object is selected by the component menu or the object tree
        GUI._select!(gui, fx.mirror)
        frame!()
        eye = GUI._card_widget(card_of(fx.mirror, :hide), :hide)
        _check(eye.active[], "the eye is not crossed out")
        _click!(gui, _rect_center(eye))
        frame!()
        _check(!GUI._all_hidden(gui, fx.mirror), "the eye did not show the mirror")
        deselect!()
    end

    # The pencil in the head of the card of a component: a typed name and Enter
    step("card: rename a component in the title") do
        _click!(gui, _px(gui, _pos(fx.mirror)))
        frame!()
        _selected(gui, fx.mirror)
        c = card_of(fx.mirror, :hide)
        name = GUI._label(gui, fx.mirror)
        _click!(gui, _rect_center(c.name.pencil))
        frame!()
        _check(c.name.editing && GUI._typing(gui), "the pencil did not start the renaming")
        foreach(char -> (_events(gui).unicode_input[] = char), "t1")
        frame!()
        _key!(gui, Keyboard.enter)
        frame!()
        _check(!c.name.editing && GUI._label(gui, fx.mirror) != name, "Enter did not rename the mirror")
        GUI._rename_object!(gui, fx.mirror, name)
        frame!()
        deselect!()
    end

    # The card of a system: its pencil with a typed name and Enter, "×" of a row of its members
    # and a click on a row
    step("system: rename in the title, × and click on a row of the members") do
        sys = fx.system
        GUI._inspect!(gui, sys)
        frame!()
        c = card_of(sys, :members)
        name = GUI._label(gui, sys)
        _click!(gui, _rect_center(c.name.pencil))
        frame!()
        _check(c.name.editing && GUI._typing(gui), "the pencil did not start the renaming")
        foreach(char -> (_events(gui).unicode_input[] = char), "t1")
        frame!()
        _key!(gui, Keyboard.enter)
        frame!()
        _check(!c.name.editing && GUI._label(gui, sys) != name, "Enter did not rename the system")
        GUI._rename_system!(gui, sys, name)
        frame!()
        # the rows: the sources, then the objects
        row(@nospecialize(obj)) = GUI._card_widget(card_of(sys, :members), :members).rows[GUI._index(GUI._members(gui, sys), obj)]
        _click!(gui, _rect_center(row(fx.mirror).out))
        settle!()
        _check(!GUI._has(sys.objects, fx.mirror) && gui.objects.inspected === sys,
            "× did not take the mirror out of the system")
        add_component!(gui, fx.mirror; system = sys, select = false)
        settle!()
        _check(GUI._has(sys.objects, fx.mirror), "the mirror is not in the system again")
        _move!(gui, _rect_center(row(fx.lens).name))
        frame!()
        _click!(gui)
        frame!()
        _selected(gui, fx.lens)
        deselect!()
    end

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

    # Systems of the window: a new one, a member of both systems, tracing per system, its removal
    step("system: add, shared mirror, auto trace off, Trace, remove") do
        n = length(GUI._systems(gui))
        sys = add_system!(gui)
        frame!()
        _check(length(GUI._systems(gui)) == n + 1 && gui.objects.inspected === sys, "no system was added")
        add_component!(gui, fx.mirror; system = sys, select = false)
        settle!()
        _check(GUI._member_systems(gui, fx.mirror) == [fx.system, sys], "the mirror is not in both systems")
        GUI._set_system_auto!(gui, sys, false)
        GUI._inspect!(gui, sys)
        frame!()
        button(name) = _rect_center(GUI._card_widget(
            only(c for c in GUI._edit_cards(gui) if !isnothing(GUI._card_widget(c, name))), name))
        _click!(gui, button(:trace))
        settle!()
        _check(!GUI._system_stale(gui, sys), "Trace did not trace the system")
        _click!(gui, button(:remove))
        settle!()
        _check(length(GUI._systems(gui)) == n && GUI._member_systems(gui, fx.mirror) == [fx.system],
            "the system was not removed")
    end

    step(() -> (_move!(gui, _center(gui)); _key!(gui, Keyboard.insert); frame!()), "catalog: Insert")
    # the form of a lens with surfaces: the last one as an asphere, whose fields come with the next
    # frame; the lens is placed with the button of the window, which closes when it is dropped
    aspheric = Ref{Any}(nothing)
    step("catalog: aspheric surface") do
        widget = GUI._catalog_widget(GUI._catalog_window(gui))
        i = findfirst(e -> any(p -> p isa GUI.CatalogSurface, e.params), widget.entries)
        k = findfirst(==(widget.entries[i].group), widget.groups)
        _click!(gui, _rect_center(widget.group_buttons[k].box))
        frame!()
        j = findfirst(tile -> first(tile) == i, widget.tile_buttons)
        _check(!isnothing(j), "the click did not choose the group of the lens")
        _click!(gui, _rect_center(last(widget.tile_buttons[j]).box))
        frame!()
        _check(widget.entry == i, "the click did not choose the lens")
        s = findlast(p -> p isa GUI.CatalogSurface, widget.entries[i].params)
        menu = widget.inputs[s].menu
        menu.i_selected[] = findfirst(==(GUI._SURFACE_ASPHERIC), menu.options[])
        frame!()
        input = widget.inputs[s]
        _check(!isnothing(input.conic) && length(input.coefficients) == length(GUI._SURFACE_ORDERS),
            "the fields of the asphere were not built")
        _move!(gui, _rect_center(input.conic))
        frame!()
    end
    step("catalog: place aspheric lens") do
        widget = GUI._catalog_widget(GUI._catalog_window(gui))
        _click!(gui, _rect_center(widget.place))
        _check(GUI._placing(gui), "the lens was not placed: $(gui.status.text[])")
        aspheric[] = gui.components.placement.obj
        a = _free_px(gui)
        _move!(gui, a .+ (3, 0))
        _tick!(gui)
        _move!(gui, a)
        frame!()
        _click!(gui)
        settle!()
        _check(GUI._has(fx.system.objects, aspheric[]), "the aspheric lens was not dropped")
    end
    # the page "Edit" of the lens: its asphere as a spherical surface again, whose fields go with
    # the next frame, then "Apply", which builds the lens again
    step("edit: surface + apply") do
        lens = aspheric[]
        isnothing(lens) && return nothing
        gui.controls.selected[] === lens || select!(gui, lens)
        frame!()
        # the card of the selection, in a layout with docked cards the docked one
        card() = last(filter(c -> GUI._card_object(gui, c) === gui.controls.selected[], GUI._edit_cards(gui)))
        GUI._set_page!(gui, card(), :edit)
        frame!()
        s = findlast(p -> p isa GUI.CatalogSurface, gui.components.origin[lens].entry.params)
        menu = GUI._card_widget(card(), GUI._edit_surface_menu(s))
        menu.i_selected[] = findfirst(==(GUI._SURFACE_SPHERICAL), menu.options[])
        frame!()
        _check(!(GUI._card_widget(card(), GUI._edit_field(s, 2)) isa Textbox),
            "the fields of the asphere were not removed")
        notify(GUI._card_widget(card(), :edit_apply).clicks)
        settle!()
        _check(!GUI._has(fx.system.objects, lens), "the lens was not built again")
        aspheric[] = gui.controls.selected[]
    end
    step("catalog: delete aspheric lens") do
        isnothing(aspheric[]) && return nothing
        gui.controls.selected[] === aspheric[] || select!(gui, aspheric[])
        _key!(gui, Keyboard.delete)
        settle!()
        _check(!GUI._has(fx.system.objects, aspheric[]), "the aspheric lens was not removed")
    end
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
    copied = Ref{Any}(nothing)
    # Ctrl+V of what Ctrl+C kept of the selection, dropped at the mouse
    function paste_drop!(n)
        _key!(gui, Keyboard.c, Keyboard.left_control)
        frame!()
        _key!(gui, Keyboard.v, Keyboard.left_control)
        _move!(gui, _free_px(gui))
        frame!()
        _click!(gui)
        settle!()
        _check(length(fx.system.objects) == n, "the copy was not dropped")
        return nothing
    end
    step("copy + paste + drop a group, undo") do
        copied[] = gui.controls.selected[]
        n = length(fx.system.objects)
        GUI._group!(gui, GUI._MultiSelection([placed[], copied[]]))
        settle!()
        _check(GUI._is_window_group(gui, gui.controls.selected[]), "the copies were not grouped")
        paste_drop!(n)
        _check(GUI._is_window_group(gui, last(fx.system.objects)), "the group was not pasted as a group")
        # the paste, then the grouping
        GUI._undo!(gui.controls)
        GUI._undo!(gui.controls)
        settle!()
        _check(GUI._has(fx.system.objects, copied[]), "the undo did not ungroup the copies")
    end
    step("copy + paste + drop several, undo") do
        n = length(fx.system.objects)
        GUI._select!(gui, GUI._MultiSelection([placed[], copied[]]))
        frame!()
        paste_drop!(n + 2)
        GUI._undo!(gui.controls)
        settle!()
        _check(length(fx.system.objects) == n, "the undo did not remove the copies")
        # the copy of before for the next step
        GUI._select!(gui, copied[])
        frame!()
    end
    step(() -> (_key!(gui, Keyboard.delete); settle!()), "delete selected")
    step(() -> (_key!(gui, Keyboard.v); frame!(); _key!(gui, Keyboard.v); frame!()), "key v (spectator mode)")

    # The debug mode: its toggle among the tools, the debug card (its rows refresh with the ticks),
    # the bounding spheres, the ends of the beams and the hit points after a drag and a solve, the
    # page "Debug" of a card, the spectator mode with the mode on
    debug_toggle() = GUI._debug(gui).toggle
    step("debug: on") do
        debug_toggle().active[] = true
        frame!()
        _check(GUI._debug_on(gui), "the toggle did not switch the debug mode on")
    end
    step("debug: drag mirror, solve") do
        a = _px(gui, _pos(fx.mirror))
        _drag!(gui, a, a .+ (15, 5))
        settle!()
        foreach(_ -> frame!(), 1:3)
    end
    step("debug: camera of a saved view, under the mouse") do
        eye, lookat, up = GUI._current_view(gui)
        GUI._save_view!(gui; io = devnull)
        # back from it, such that its camera is in front of the window
        GUI.set_view(gui.ax, lookat .+ 2 .* (eye .- lookat), lookat, up)
        frame!()
        _move!(gui, _px(gui, eye))
        frame!()
        v = GUI._debug_layer(gui, :views)
        _check(v.hover > 0, "the camera of the saved view is not highlighted under the mouse")
        _move!(gui, _free_px(gui))
        GUI.set_view(gui.ax, eye, lookat, up)
        frame!()
    end
    step("debug: page Debug of the card of the mirror") do
        _click!(gui, _px(gui, _pos(fx.mirror)))
        frame!()
        _selected(gui, fx.mirror)
        c = last(filter(c -> GUI._card_object(gui, c) === fx.mirror, GUI._edit_cards(gui)))
        GUI._set_page!(gui, c, :debug)
        frame!()
        deselect!()
    end
    step(() -> (_key!(gui, Keyboard.v); frame!(); _key!(gui, Keyboard.v); frame!()), "debug: spectator mode")
    step("debug: off") do
        debug_toggle().active[] = false
        frame!()
        _check(!GUI._debug_on(gui), "the toggle did not switch the debug mode off")
    end

    if layout == :app
        tree = gui.layout.tree
        step(() -> (tree.clicked[] = fx.detector; settle!()), "tree: click detector")
        step("tree: eye") do
            tree.eye_clicked[] = fx.detector
            frame!()
            tree.eye_clicked[] = fx.detector
            frame!()
        end
        step("tree: tooltip of + of the system") do
            i = findfirst(r -> !isnothing(r.buttons), tree.rows)
            o = minimum(tree.scene.viewport[])
            _move!(gui, (Float64(o[1] + GUI._button_columns(tree).add), Float64(o[2] + GUI._row_y(tree, i))))
            # without its delay, which a step does not wait for
            GUI._show_tree_tip!(gui)
            frame!()
            _check(GUI._tree_tip_state(gui).visible[], "the tooltip of the tree is not shown")
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
        step("tree: ctrl+click lens (select both)") do
            i = findfirst(r -> r.key === fx.lens, tree.rows)
            _check(!isnothing(i), "the tree has no row of the lens")
            o = minimum(tree.scene.viewport[])
            _move!(gui, (Float64(o[1] + GUI._row_columns(tree, tree.rows[i]).label + 5), Float64(o[2] + GUI._row_y(tree, i))))
            _ctrl!(gui, Keyboard.press)
            _click!(gui)
            _ctrl!(gui, Keyboard.release)
            frame!()
            in_selection(fx.mirror, fx.lens)
            deselect!()
        end
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

const _PROJECT_SYSTEM = """
    @component L1 = SphericalLens(0.05, -0.05, 0.005, 0.0254, 1.5) pos = (0.0, 0.05, 0.0)
    @component M1 = RoundPlanoMirror(0.025, 0.005) pos = (0.0, 0.1, 0.0) rot = (0.0, 0.0, 45.0)
    @source B1 = Beam([0.0, 0.0, 0.0], [0.0, 1.0, 0.0], 1.0e-6)
    @system S1 = [L1, M1] sources = [B1]
    """

# The position of `obj` of a project in the record of the `gui`, which a merge updates after the
# glide of `obj` (see `_update_record!`)
_project_pos(gui, @nospecialize(obj)) = collect(Float64, gui.components.origin[obj].project.pos)

"""
    _project_session(step; dir = mktempdir()) -> (gui, screen)

Opens a new project in the empty folder `dir`, with a repository of its own, in an invisible window
and works on it like a person with an agent: drags the lens, which the autosave writes to the
files; changes the files like an agent, which the window merges and glides; `Ctrl+S` with the card
of the version, closed by a typed message and `Enter`, by `Esc`, by the button "Cancel" and by the
button "Save version"; another participant (a presence file) works on the mirror, shown with its
name, and leaves. The steps call the autosave and the watcher themselves, with times that do
not depend on how long a step takes: the watcher of the window never starts, and the step of the
agent waits until the mirror has glided. Returns the live view and its screen, which the caller
closes.
"""
function _project_session(step; dir = mktempdir())
    file = joinpath(dir, "system.jl")
    gui = step("project: open") do
        # The versions go into this repository, not into one that encloses `dir`, e.g. a
        # repository of the home folder that holds the temporary folders on Windows
        mkpath(dir)
        close(GUI.BMOP.LibGit2.init(dir))
        GUI.BMOP.new_project(dir; name = "Bench")
        write(file, _PROJECT_SYSTEM)
        g = open_project(dir; display = false)
        # A closed timer in place of the watcher, such that `_start_watching!` does not start it
        t = Timer(3600.0)
        close(t)
        g.sync.timer = t
        g
    end
    isnothing(gui) && return nothing, nothing
    screen = _screen()
    display(screen, gui.fig)
    frame!() = _frame!(gui, screen)
    settle!() = _settle!(gui, screen)
    settle!()
    lens = only(o for (o, (id, _)) in gui.sync.ids if id === :L1)
    mirror = only(o for (o, (id, _)) in gui.sync.ids if id === :M1)
    # Drags the lens and lets the autosave write it to the files
    function drag_lens!()
        a = _px(gui, _pos(lens))
        _click!(gui, a)
        _drag!(gui, a, a .+ (14, 4))
        settle!()
        t = time()
        GUI._autosave!(gui; now = t)
        _check(GUI._autosave!(gui; now = t + 1) === :saved, "the autosave did not save the drag")
    end
    function ask_version!()
        _key!(gui, Keyboard.s, Keyboard.left_control)
        frame!()
        _check(!isnothing(GUI._version_box(gui)), "Ctrl+S did not show the card of the version")
    end
    button(name) = _rect_center(GUI._card_widget(GUI._version_card(gui), name))
    step("project: drag the lens, autosave") do
        drag_lens!()
    end
    step("project: an agent moves the mirror") do
        write(file, replace(read(file, String), "pos = (0.0, 0.1, 0.0)" => "pos = (0.0, 0.12, 0.0)"))
        t = time()
        GUI._check_files!(gui; now = t)
        _check(GUI._check_files!(gui; now = t + 1) === :applied, "the window did not merge the file")
        # the mirror glides in a task of its own, which ends with its record
        target = [0.0, 0.12, 0.0]
        timedwait(() -> _project_pos(gui, mirror) ≈ target, 60.0; pollint = 0.01)
        _check(_project_pos(gui, mirror) ≈ target && _pos(mirror) ≈ target, "the mirror did not glide")
        settle!()
    end
    step("project: Ctrl+S, the card of the version, Enter") do
        ask_version!()
        foreach(char -> (_events(gui).unicode_input[] = char), " ok")
        _key!(gui, Keyboard.enter)
        frame!()
        _check(length(GUI.BMOP.versions(dir)) == 2, "Enter did not save a version")
    end
    step("project: Ctrl+S, Esc") do
        drag_lens!()
        ask_version!()
        _key!(gui, Keyboard.escape)
        frame!()
        _check(isnothing(GUI._version_card(gui)), "Esc did not close the card of the version")
        _check(length(GUI.BMOP.versions(dir)) == 2, "Esc saved a version")
    end
    step("project: Ctrl+S, Cancel") do
        ask_version!()
        _click!(gui, button(:version_cancel))
        frame!()
        _check(isnothing(GUI._version_card(gui)), "Cancel did not close the card of the version")
        _check(length(GUI.BMOP.versions(dir)) == 2, "Cancel saved a version")
    end
    step("project: Ctrl+S, Save version") do
        ask_version!()
        _click!(gui, button(:version_save))
        frame!()
        _check(isnothing(GUI._version_card(gui)), "Save version did not close the card of the version")
        _check(length(GUI.BMOP.versions(dir)) == 3, "Save version did not save a version")
    end
    step("project: another participant works on the mirror, then leaves") do
        file = GUI._presence_file(dir, "Anna@pc2")
        mkpath(dirname(file))
        write(file, """
            name = "Anna"
            host = "pc2"
            beat = 1
            selected = "$(gui.sync.ids[mirror][2])"
            selected_id = "$(gui.sync.ids[mirror][1])"
            written = ""
            """)
        GUI._check_presence!(gui)
        frame!()
        _check(!isempty(gui.sync.presence), "the mirror of the other participant is not shown")
        rm(file)
        GUI._check_presence!(gui)
        frame!()
        _check(isempty(gui.sync.presence), "the other participant did not leave")
    end
    return gui, screen
end

"""
    _precompile_sessions(step)

The sessions of the workload: `_session` in both layouts, with a beam and with a Gaussian beamlet,
`_catalog_session` and `_project_session`. Closes their windows.
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
    _close!(_project_session(step)...)
    return nothing
end

function _close!(gui, screen)
    isnothing(gui) || close(gui)
    isnothing(screen) || close(screen)
    return nothing
end
