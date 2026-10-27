module TestLiveProject

using GLMakie, BeamletOptics, BeamletOpticsGUI
using BeamletOpticsProjects
using Makie
using LinearAlgebra: norm, normalize
using TOML
using Test

const BMO = BeamletOptics
const BMOP = BeamletOpticsProjects
const GUI = BeamletOpticsGUI

@testset "Projects" begin

    # Each change is solved at once, see `TestLiveView.jl`; no card of a detector is pinned at start
    const_kw = (; trace_budget = Inf, throttle = false, detectors = [])
    _live_view(args...; kwargs...) = live_view(args...; merge(const_kw, kwargs)...)

    _entry(name) = only(e for e in component_catalog() if e.name == name)
    _defaults(entry) = String[GUI._catalog_string(p) for p in entry.params]
    _built(name, strings = _defaults(_entry(name))) = GUI._catalog_component(_entry(name), strings)

    # The key that types the letter of `key` in the keyboard layout of this machine, see `_layout_key`
    _typed(key) = first(k for k in Keyboard.Button.(Int(Keyboard.a):Int(Keyboard.z)) if GUI._layout_key(k) == key)
    _key!(gui, key) = (events(gui.ax.scene).keyboardbutton[] = Makie.KeyEvent(key, Keyboard.press))
    function _ctrl!(gui, key)
        state = events(gui.ax.scene).keyboardstate
        push!(state, Keyboard.left_control)
        _key!(gui, _typed(key))
        delete!(state, Keyboard.left_control)
        return nothing
    end
    function _select!(gui, obj)
        gui.controls.selected[] = obj
        GUI._update_selection_box!(gui.controls)
        return nothing
    end
    _in(obj, list) = any(o -> o === obj, list)
    _hex(c) = GUI._color_hex(Makie.to_color(c))

    # What `load_project` does, in memory: builds each entry from its code, poses it and builds
    # the systems, see BeamletOpticsProjects
    function _reload(p)
        M = Module()
        Core.eval(M, :(using BeamletOptics))
        entries = BMOP.Entry[]
        for e in p.entries
            obj = Core.eval(M, e.code)
            pose0 = BMOP.pose_of(obj)
            BMOP.apply_pose!(obj, e.pos, e.rot)
            push!(entries, BMOP.Entry(e.kind, e.name, e.code, obj; e.pos, e.rot, pose0, e.meta, e.label, e.uid))
        end
        byname = Dict(e.name => e.object for e in entries)
        systems = map(p.systems) do s
            objs = Any[byname[n] for n in s.members]
            sys = s.static ? StaticSystem(objs) : isempty(objs) ? System() : System(objs)
            BMOP.SystemEntry(s.name, s.members, s.sources; s.static, object = sys, s.label, s.uid)
        end
        return BMOP.Project(p.path, p.name; entries, systems)
    end

    # A setup from the catalog: a lens in two systems, a prism mirror, an object and a source
    # without a system, a source per system
    function _setup(layout)
        s1, s2 = System(), System()
        gui = _live_view(s1, s2; layout, labels = Dict(s1 => "Transmitter", s2 => "Receiver"))
        lens = _built("Thin lens", ["80", "-60", "30", "N-SF11"])
        rotate3d!(lens.obj, normalize([1.0, 2, 3]), 0.4)
        translate_to3d!(lens.obj, [0.01, 0.1, -0.02])
        add_component!(gui, lens.obj; system = s1, origin = lens.origin, label = "L1", select = false)
        add_component!(gui, lens.obj; system = s2, select = false)
        prism = _built("Prism mirror")
        zrotate3d!(prism.obj, deg2rad(90))
        translate3d!(prism.obj, [0.0, 0.2, 0.0])
        add_component!(gui, prism.obj; system = s2, origin = prism.origin, select = false)
        free = _built("Round mirror")
        translate3d!(free.obj, [0.1, 0.0, 0.0])
        add_component!(gui, free.obj; system = :none, origin = free.origin, label = "spare", select = false)
        b1 = _built("Beam", ["532"])
        add_component!(gui, b1.obj; system = s1, origin = b1.origin, label = "B1", select = false)
        b2 = _built("Beam")
        zrotate3d!(b2.obj, deg2rad(30))
        translate3d!(b2.obj, [0.0, -0.05, 0.01])
        add_component!(gui, b2.obj; system = s2, origin = b2.origin, label = "laser 2", select = false,
            beam_kwargs = (; color = :orange, linewidth = 3))
        b3 = _built("Beam", ["1064"])
        add_component!(gui, b3.obj; system = :none, origin = b3.origin, label = "B3", select = false)
        return (; gui, s1, s2, lens = lens.obj, prism = prism.obj, free = free.obj, b1 = b1.obj,
            b2 = b2.obj, b3 = b3.obj)
    end

    # The objects, sources and systems of a view by their readable ids, see `_ProjectSync`
    _byid(gui) = Dict(first(v) => x for (x, v) in gui.sync.ids)
    _prefix(x) = BMOP.id_prefix(x)

    @testset "collect and open, $layout" for layout in (:compact, :app)
        GUI._CLIPBOARD[] = nothing
        dir = mktempdir()
        t = _setup(layout)
        gui = t.gui
        # how the view looks
        GUI._set_beam_opacity!(gui, t.b2, 0.5)
        GUI._set_beam_on!(gui, t.b1, false)
        GUI._add_clip_plane!(gui, [0.0, 0.05, 0.0], [0.0, 1.0, 0.0]; select = false)
        GUI._set_clip_beams!(gui, true)
        push!(gui.camera.views, "side" => ([0.3, 0.0, 0.0], [0.0, 0.1, 0.0], [0.0, 0.0, 1.0]))
        gui.widgets.orthographic_toggle.active[] = true
        gui.widgets.sources_toggle.active[] = false
        GUI._set_snap!(gui.controls, :pose)
        set_view(gui.ax, [0.4, -0.3, 0.2], [0.0, 0.1, 0.0], [0.0, 0.0, 1.0])

        parts = GUI._project_parts(gui, dir)
        p = parts.project
        names = parts.names
        @test isempty(parts.skipped)
        @test p.path == abspath(dir) && Base.isidentifier(p.name)
        # readable ids by the kind of each, the labels of the view as labels (not if they are the id)
        @test [e.name for e in p.entries] ==
              [:L1, Symbol(_prefix(t.prism), 1), Symbol("M", _prefix(t.prism) == "M" ? 2 : 1), :B1, :B2, :B3]
        @test [e.label for e in p.entries] == [nothing, nothing, "spare", nothing, "laser 2", nothing]
        @test [e.kind for e in p.entries] == [:component, :component, :component, :source, :source, :source]
        @test [s.name for s in p.systems] == [:S1, :S2]
        @test [s.label for s in p.systems] == ["Transmitter", "Receiver"]
        @test p.systems[1].members == [names[t.lens]] && p.systems[1].sources == [:B1]
        @test p.systems[2].members == [names[t.lens], names[t.prism]] && p.systems[2].sources == [:B2]
        @test all(!s.static for s in p.systems)
        # a uid each, all different
        uids = [x.uid for x in [p.entries; p.systems]]
        @test all(u -> u isa String && length(u) == 36, uids) && allunique(uids)
        @test parts.ids[t.lens] == (:L1, p.entries[1].uid)
        # ids are free variable names
        @test all(e -> Base.isidentifier(String(e.name)), p.entries)
        e_lens = p.entries[1]
        @test e_lens.meta == [:catalog => ("Thin lens", ["80", "-60", "30", "N-SF11"])]
        @test e_lens.pos == Tuple(Float64.(position(t.lens)))
        @test e_lens.rot isa Matrix{Float64}
        # an unrotated source: no `rot`
        @test isnothing(p.entries[4].rot)
        GUI._write_view_toml(gui, p, names)
        view = TOML.parsefile(joinpath(dir, "view.toml"))
        @test view["beams"]["B2"]["color"] == _hex(:orange)
        @test view["beams"]["B2"]["alpha"] == 0.5 && view["beams"]["B2"]["linewidth"] == 3.0
        @test view["beams_off"] == ["B1"] && view["snap"] == "pose"

        # open: a project as `load_project` returns it
        p2 = _reload(p)
        gui2 = GUI._open_from(p2; layout)
        @test gui2.project == abspath(dir)
        by = _byid(gui2)
        @test Set(keys(by)) == Set([e.name for e in p.entries]) ∪ Set([:S1, :S2])
        # the ids and uids of the files; the labels of the files, else the ids
        for e in [p2.entries; p2.systems]
            @test gui2.sync.ids[e.object] == (e.name, e.uid)
            @test gui2.labels[e.object] == something(e.label, String(e.name))
        end
        @test gui2.labels[by[:S1]] == "Transmitter" && gui2.labels[by[:B2]] == "laser 2"
        @test gui2.sync.base === p2
        old = Dict(names[x] => x for x in keys(names))
        for e in p2.entries
            a, b = old[e.name], e.object
            @test typeof(a) === typeof(b) && by[e.name] === b
            @test position(b) == position(a)
            @test maximum(abs, GUI._pose(b)[2] - GUI._pose(a)[2]) < 1e-12
        end
        S1, S2 = by[:S1], by[:S2]
        @test GUI._systems(gui2) == [S1, S2]
        lens2 = by[names[t.lens]]
        @test _in(lens2, S1.objects) && _in(lens2, S2.objects) && length(S2.objects) == 2
        @test GUI._sources_of(gui2, S1) == [by[:B1]] && GUI._sources_of(gui2, S2) == [by[:B2]]
        @test by[:B3] in gui2.beams.unassigned
        spare = by[names[t.free]]
        @test _in(spare, GUI.rendered(gui2.extras).objects)
        @test isempty(gui2.controls.undo_stack) && isempty(gui2.controls.redo_stack)
        # view.toml
        @test _hex(gui2.beams.kwargs[by[:B2]].color) == _hex(:orange)
        @test GUI._beam_opacity(gui2, by[:B2]) == 0.5
        @test GUI._beam_linewidth(gui2, by[:B2]) == 3.0
        @test !GUI._beam_on(gui2, by[:B1])
        @test length(gui2.clip.planes) == 1 && collect(gui2.clip.planes[1].pos) == [0.0, 0.05, 0.0]
        @test gui2.clip.beams
        @test gui2.camera.views == gui.camera.views
        @test gui2.widgets.orthographic_toggle.active[] && !gui2.widgets.sources_toggle.active[]
        @test gui2.controls.snap[] === :pose
        for (a, b) in zip(GUI._current_view(gui2), GUI._current_view(gui))
            @test maximum(abs, a - b) < 1e-6
        end

        # unmoved objects keep the `pos` and `rot` of their entry bit for bit
        p3 = GUI._collect_project(gui2, dir)
        for (e2, e3) in zip(p2.entries, p3.entries)
            @test e2.name === e3.name && isequal(e2.pos, e3.pos) && isequal(e2.rot, e3.rot)
            @test e2.meta == e3.meta && e2.code == e3.code
            @test e2.label == e3.label && e2.uid == e3.uid
        end
        # a moved one gets its new pose
        translate3d!(spare, [0.0, 0.0, 0.01])
        p4 = GUI._collect_project(gui2, dir)
        e = only(e for e in p4.entries if e.object === spare)
        @test e.pos == Tuple(Float64.(position(spare)))

        # a loaded catalog lens can be edited and copied
        @test GUI._editable(gui2, lens2)
        _select!(gui2, lens2)
        _ctrl!(gui2, Keyboard.c)
        @test !isnothing(GUI._CLIPBOARD[]) && GUI._CLIPBOARD[].strings == ["80", "-60", "30", "N-SF11"]
        GUI._set_edit_string!(gui2, lens2, 1, "120")
        GUI._apply_edit!(gui2, lens2; read = false)
        new = only(o for o in S1.objects)
        @test new !== lens2 && _in(new, S2.objects) && GUI._editable(gui2, new)
        @test GUI._label(gui2, new) == String(names[t.lens])
        # ... keeps the id and the uid of the one it replaced ...
        lens_id = (names[t.lens], p2.entries[1].uid)
        @test gui2.sync.ids[new] == lens_id && !haskey(gui2.sync.ids, lens2)
        # ... and is saved with its new code
        p5 = GUI._collect_project(gui2, dir)
        e = only(e for e in p5.entries if e.name === names[t.lens])
        @test e.object === new && e.uid == lens_id[2]
        @test last(only(e.meta))[2][1] == "120"
        @test position(new) ≈ position(lens2) atol = 1e-12
        # undo gives the id back to the old one, redo to the new one
        GUI._undo!(gui2.controls)
        @test gui2.sync.ids[lens2] == lens_id && !haskey(gui2.sync.ids, new)
        GUI._redo!(gui2.controls)
        @test gui2.sync.ids[new] == lens_id && !haskey(gui2.sync.ids, lens2)
        close(gui2)
        close(gui)
    end

    @testset "catalog entry that does not match" begin
        dir = mktempdir()
        t = _setup(:compact)
        p = GUI._collect_project(t.gui, dir)
        close(t.gui)
        # an agent changed the code, but not the inputs of the catalog: not editable
        e = p.entries[1]
        code = :(ThinLens(0.1, -0.06, 0.003, 1.5))
        p.entries[1] = BMOP.Entry(e.kind, e.name, code, e.object; e.pos, e.rot, e.pose0, e.meta)
        p2 = _reload(p)
        gui = GUI._open_from(p2)
        lens = p2.entries[1].object
        @test !GUI._editable(gui, lens)
        @test gui.components.origin[lens].code == string(code)
        # it is saved as it is, with its meta
        p3 = GUI._collect_project(gui, dir)
        @test p3.entries[1].meta == e.meta && p3.entries[1].code == code
        close(gui)
    end

    @testset "objects without a recipe" begin
        dir = mktempdir()
        m = RoundPlanoMirror(25e-3, 5e-3)
        translate3d!(m, [0, 0.2, 0])
        sys = System([m])
        beam = Beam([0.0, 0, 0], [0.0, 1, 0], 632.8e-9)
        gui = _live_view(sys => beam; labels = Dict(m => "M0"))
        c = _built("Thin lens")
        add_component!(gui, c.obj; origin = c.origin, label = "L1", system = sys)
        path = @test_logs (:warn, r"2 objects without a recipe were not saved: M0, Beam") match_mode = :any save_project(gui, dir)
        @test isfile(path) && isfile(joinpath(dir, "view.toml"))
        @test occursin("project saved to $(abspath(dir))", gui.status.text[])
        @test occursin("2 objects without a recipe were not saved: M0, Beam", gui.status.text[])
        @test gui.project == abspath(dir)
        p = load_project(dir)
        @test [e.name for e in p.entries] == [:L1]
        @test only(p.systems).members == [:L1] && isempty(only(p.systems).sources)
        close(gui)
    end

    @testset "keys and dialogs" begin
        saved = Ref{Any}("")
        opened = Ref{Any}("")
        calls = Ref(0)
        GUI._SAVE_DIALOG[] = dir -> (calls[] += 1; saved[])
        GUI._OPEN_DIALOG[] = dir -> (calls[] += 1; opened[])
        _wait() = wait(GUI._DIALOG_TASK[])
        function _ctrl_shift!(gui, key)
            state = events(gui.ax.scene).keyboardstate
            push!(state, Keyboard.left_shift)
            _ctrl!(gui, key)
            delete!(state, Keyboard.left_shift)
            return nothing
        end
        try
            parent = mktempdir()
            t = _setup(:compact)
            gui = t.gui
            # without a project: the dialog of "Save as"; cancelled, nothing happens
            _ctrl!(gui, Keyboard.s)
            _wait()
            @test calls[] == 1 && isnothing(gui.project) && isempty(readdir(parent))
            # a place and a name: a new folder of that name with its project file
            saved[] = joinpath(parent, "Laser bench")
            _ctrl!(gui, Keyboard.s)
            _wait()
            dir = joinpath(parent, "Laser bench")
            @test calls[] == 2 && gui.project == dir
            @test isfile(joinpath(dir, "Laser bench.bmo")) && isfile(joinpath(dir, "system.jl"))
            @test load_project(joinpath(dir, "Laser bench.bmo")).name == "Laser_bench"
            @test gui.status.text[] == "project saved to $dir"
            # the new project has its first version
            @test [v.message for v in versions(dir)] == ["New project"]
            # with a project: saved without the dialog, then the card of the version
            translate3d!(gui, t.b3, [0.0, 0.0, 0.01])
            _ctrl!(gui, Keyboard.s)
            @test calls[] == 2 && position(load_project(dir)[first(gui.sync.ids[t.b3])]) ≈ position(t.b3)
            GUI._cancel_version!(gui)
            # the ids are kept, the labels stay as they are
            @test first(gui.sync.ids[t.b2]) === :B2 && gui.labels[t.b2] == "laser 2"
            @test !haskey(gui.labels, t.prism)
            # "Save as" always asks; the name of an existing folder is refused
            saved[] = joinpath(parent, "Laser bench.bmo")
            _ctrl_shift!(gui, Keyboard.s)
            _wait()
            @test calls[] == 3 && gui.project == dir
            @test startswith(gui.status.text[], "project not saved: \"$dir\" exists already")
            # picking the project file of a project overwrites it
            rm(joinpath(dir, "system.jl"))
            saved[] = joinpath(dir, "Laser bench.bmo")
            _ctrl_shift!(gui, Keyboard.s)
            _wait()
            @test calls[] == 4 && gui.project == dir && isfile(joinpath(dir, "system.jl"))
            @test !isdir(joinpath(dir, "Laser bench"))
            # another name: the window belongs to the new project, Ctrl+S saves there
            saved[] = joinpath(parent, "copy.bmo")
            _ctrl_shift!(gui, Keyboard.s)
            _wait()
            copy = joinpath(parent, "copy")
            @test calls[] == 5 && gui.project == copy && isfile(joinpath(copy, "copy.bmo"))
            @test gui.status.text[] == "project saved as $copy"
            # the copy keeps the module of the project
            @test load_project(copy).name == "Laser_bench" && isfile(joinpath(copy, "src", "Laser_bench.jl"))
            translate3d!(gui, t.b3, [0.0, 0.0, 0.01])
            _ctrl!(gui, Keyboard.s)
            @test calls[] == 5 && position(load_project(copy)[first(gui.sync.ids[t.b3])]) ≈ position(t.b3)
            @test position(load_project(dir)[first(gui.sync.ids[t.b3])]) ≉ position(t.b3)
            GUI._cancel_version!(gui)
            # the tool "Save as" does the same as the keys
            saved[] = ""
            GUI._save_as_key!(gui)
            _wait()
            @test calls[] == 6 && gui.project == copy
            # open: cancelled, and a file that is no project
            opened[] = ""
            gui.status.text[] = "before"
            _ctrl!(gui, Keyboard.o)
            _wait()
            @test calls[] == 7 && gui.status.text[] == "before"
            opened[] = joinpath(mktempdir(), "nothing.bmo")
            @test_logs (:error,) match_mode = :any begin
                _ctrl!(gui, Keyboard.o)
                _wait()
            end
            @test startswith(gui.status.text[], "project not opened")
            # the spectator mode ignores the keys
            gui.controls.spectator[] = true
            _ctrl!(gui, Keyboard.s)
            _ctrl_shift!(gui, Keyboard.s)
            @test calls[] == 8
            gui.controls.spectator[] = false
            close(gui)
        finally
            GUI._SAVE_DIALOG[] = dir -> GUI.NativeFileDialog.save_file(dir; filterlist = GUI._BMO_FILTER)
            GUI._OPEN_DIALOG[] = dir -> GUI.NativeFileDialog.pick_file(dir; filterlist = GUI._BMO_FILTER)
        end
    end

    @testset "Ctrl+S saves a version" begin
        dir = joinpath(mktempdir(), "bench")
        t = _setup(:compact)
        gui = t.gui
        save_project(gui, dir)
        @test length(versions(dir)) == 1
        _messages() = [v.message for v in versions(dir)]
        # nothing changed since the last version: no card
        GUI._save_key!(gui)
        @test isnothing(GUI._version_card(gui))
        @test gui.status.text[] == "no changes since the last version"
        # a move: written to the files, then the card with the summary in its focused box
        lens = first(gui.sync.ids[t.lens])
        translate3d!(gui, t.lens, [0.0, 0.0, 0.01])
        GUI._save_key!(gui)
        c = GUI._version_card(gui)
        @test !isnothing(c)
        box = GUI._version_box(gui)
        @test box.displayed_string[] == "moved $lens" == version_summary(dir)
        @test box.focused[] && gui.controls.ignore_keys()
        @test position(load_project(dir)[lens]) ≈ position(t.lens)
        # Esc: no version
        events(gui.ax.scene).keyboardbutton[] = Makie.KeyEvent(Keyboard.escape, Keyboard.press)
        @test isnothing(GUI._version_card(gui)) && !box.focused[]
        @test length(versions(dir)) == 1 && gui.status.text[] == "no version saved"
        # the button "Cancel" does the same
        GUI._save_key!(gui)
        GUI._cancel_version!(gui)
        @test isnothing(GUI._version_card(gui)) && length(versions(dir)) == 1
        # Enter in the box: a version with the typed message
        GUI._save_key!(gui)
        box = GUI._version_box(gui)
        box.displayed_string[] = "lens moved up"
        box.stored_string[] = "lens moved up"
        @test isnothing(GUI._version_card(gui))
        @test _messages() == ["lens moved up", "New project"]
        @test gui.status.text[] == "version saved: lens moved up"
        GUI._save_key!(gui)
        @test isnothing(GUI._version_card(gui))
        @test gui.status.text[] == "no changes since the last version"
        # the button "Save version": the text of the box
        translate3d!(gui, t.lens, [0.0, 0.0, -0.01])
        GUI._save_key!(gui)
        @test GUI._version_box(gui).displayed_string[] == "moved $lens"
        GUI._save_version!(gui)
        @test _messages() == ["moved $lens", "lens moved up", "New project"]
        @test gui.status.text[] == "version saved: moved $lens"
        @test !gui.controls.ignore_keys()
        close(gui)
    end

    @testset "Ctrl+S: journal, conflict, message of the version" begin
        dir = joinpath(mktempdir(), "bench")
        t = _setup(:compact)
        gui = t.gui
        save_project(gui, dir)
        _messages() = [v.message for v in versions(dir)]
        _session() = read(joinpath(dir, ".bmo", "session.md"), String)
        GUI._connect_session!(gui)
        lens = string(first(gui.sync.ids[t.lens]))
        prism = string(first(gui.sync.ids[t.prism]))
        # a move that the autosave has not written yet: Ctrl+S writes it and notes it in the journal
        translate3d!(gui, t.lens, [0.0, 0.0, 0.01])
        GUI._save_key!(gui)
        @test any(l -> occursin("moved $lens", l[2]), gui.sync.journal)
        @test occursin("moved $lens", _session())
        # the caret is at the end of the summary: typing adds to it
        box = GUI._version_box(gui)
        @test box.editor.cursors[] == [Makie.EditCursor(length("moved $lens"))]
        events(gui.ax.scene).unicode_input[] = '!'
        @test box.displayed_string[] == "moved $(lens)!"
        # the refreshes of the cards keep what was typed, also when the box lost the focus
        Makie.defocus!(box)
        GUI._update_inspector!(gui; force = true)
        @test box.displayed_string[] == "moved $(lens)!"
        GUI._cancel_version!(gui)
        # the summary left as it was is computed again when the version is saved: the prism that
        # moved while the card was open is in the message
        GUI._save_key!(gui)
        @test GUI._version_box(gui).displayed_string[] == "moved $lens"
        translate3d!(gui, t.prism, [0.0, 0.0, 0.01])
        @test GUI._autosave!(gui; force = true) === :saved
        GUI._save_version!(gui)
        @test occursin(lens, first(_messages())) && occursin(prism, first(_messages()))
        # a typed message is kept
        translate3d!(gui, t.prism, [0.0, 0.0, 0.01])
        GUI._save_key!(gui)
        translate3d!(gui, t.lens, [0.0, 0.0, 0.01])
        @test GUI._autosave!(gui; force = true) === :saved
        GUI._save_version!(gui, "prism up")
        @test first(_messages()) == "prism up"
        # an open conflict: Ctrl+S saves nothing and asks to decide on the card first
        n = length(versions(dir))
        file = read(joinpath(dir, "system.jl"), String)
        translate3d!(gui, t.lens, [0.0, 0.0, 0.01])
        GUI._show_info!(gui, GUI._ProjectConflict(Point3f(0), ["$lens"]))
        GUI._save_key!(gui)
        @test gui.status.text[] == "decide on the card first: $lens"
        @test GUI._info_card(gui).obj isa GUI._ProjectConflict
        @test read(joinpath(dir, "system.jl"), String) == file && length(versions(dir)) == n
        # also while the card is not shown
        GUI._release_info!(gui, GUI._ProjectConflict)
        push!(gui.sync.conflicts, "$prism")
        GUI._save_key!(gui)
        @test gui.status.text[] == "decide on the card first: $prism"
        @test isnothing(GUI._version_card(gui))
        @test read(joinpath(dir, "system.jl"), String) == file && length(versions(dir)) == n
        empty!(gui.sync.conflicts)
        close(gui)
    end

    @testset "save as closes the session of the old folder" begin
        dir = joinpath(mktempdir(), "bench")
        t = _setup(:compact)
        gui = t.gui
        save_project(gui, dir)
        GUI._connect_session!(gui)
        lens = first(gui.sync.ids[t.lens])
        translate3d!(gui, t.lens, [0.0, 0.0, 0.01])
        @test GUI._autosave!(gui; force = true) === :saved
        @test occursin("moved $lens", read(joinpath(dir, ".bmo", "session.md"), String))
        target = joinpath(mktempdir(), "copy")
        save_project(gui, target)
        @test occursin("No window is open on this project.", read(joinpath(dir, ".bmo", "session.md"), String))
        # the new project starts without the journal of the old one, and its session is connected
        @test isempty(gui.sync.journal) && !isempty(gui.sync.session)
        new = read(joinpath(target, ".bmo", "session.md"), String)
        @test !occursin("moved $lens", new) && occursin("Recent changes by the person: none", new)
        close(gui)
    end

    @testset "target of save as" begin
        parent = mktempdir()
        @test GUI._save_target(joinpath(parent, "a")).dir == joinpath(parent, "a")
        @test GUI._save_target(joinpath(parent, "a.bmo")).dir == joinpath(parent, "a")
        @test GUI._save_target(joinpath(parent, "A.BMO")).dir == joinpath(parent, "A")
        mkdir(joinpath(parent, "empty"))
        @test GUI._save_target(joinpath(parent, "empty")).dir == joinpath(parent, "empty")
        write(joinpath(parent, "file"), "x")
        @test isnothing(GUI._save_target(joinpath(parent, "file")).dir)
        @test isnothing(GUI._save_target(joinpath(parent, ".bmo")).dir)
    end

    @testset "ids, labels and uids across saves" begin
        dir = mktempdir()
        t = _setup(:compact)
        gui = t.gui
        save_project(gui, dir)
        p = load_project(dir)
        text = read(joinpath(dir, "system.jl"), String)
        ids = Dict(e.name => e.uid for e in [p.entries; p.systems])
        @test all(u -> u isa String, values(ids))
        @test occursin("label = \"spare\"", text) && occursin("label = \"Transmitter\"", text)
        # the uid is the last keyword of a line
        @test all(l -> occursin(r"uid = \"[0-9a-f-]{36}\"$", l), filter(startswith("@"), split(text, '\n')))
        # the view knows them
        known = Dict(first(v) => last(v) for (x, v) in gui.sync.ids)
        @test all(known[n] == u for (n, u) in ids)
        # renaming in the view: a label, the id and the uid stay
        GUI._rename_object!(gui, t.lens, "Kollimator")
        GUI._rename_system!(gui, t.s2, "Empfänger")
        save_project(gui)
        p2 = load_project(dir)
        e = only(e for e in p2.entries if e.name === :L1)
        @test e.label == "Kollimator" && e.uid == ids[:L1]
        s2 = only(s for s in p2.systems if s.name === :S2)
        @test s2.label == "Empfänger" && s2.uid == ids[:S2]
        @test Dict(e.name => e.uid for e in [p2.entries; p2.systems]) == ids
        # a new object gets the next id of its kind and a new uid, which stay
        c = _built("Thin lens")
        add_component!(gui, c.obj; system = t.s1, origin = c.origin, select = false)
        save_project(gui)
        p3 = load_project(dir)
        e3 = only(e for e in p3.entries if !haskey(ids, e.name))
        @test e3.name === :L2 && isnothing(e3.label) && !(e3.uid in values(ids))
        @test gui.sync.ids[c.obj] == (:L2, e3.uid)
        save_project(gui)
        @test only(e for e in load_project(dir).entries if e.name === :L2).uid == e3.uid
        # opening shows the labels, else the ids
        gui2 = open_project(dir; display = false, const_kw...)
        by = _byid(gui2)
        @test gui2.labels[by[:L1]] == "Kollimator" && gui2.labels[by[:L2]] == "L2"
        @test gui2.labels[by[:S2]] == "Empfänger" && gui2.labels[by[:B1]] == "B1"
        close(gui2)
        # an id that the view knows is never given again, also of an object later in the order
        gui.sync.ids[t.free] = (:L7, gui.sync.ids[t.free][2])
        c2 = _built("Thin lens")
        add_component!(gui, c2.obj; system = t.s1, origin = c2.origin, select = false)
        parts = GUI._project_parts(gui, dir)
        @test parts.names[c2.obj] === :L8 && parts.names[t.free] === :L7
        @test parts.ids[c2.obj][2] != parts.ids[c.obj][2]
        close(gui)
    end

    @testset "file order and lines of an agent" begin
        dir = mktempdir()
        t = _setup(:compact)
        save_project(t.gui, dir)
        close(t.gui)
        file = joinpath(dir, "system.jl")
        lines = split(chomp(read(file, String)), '\n')
        comps = filter(startswith("@component"), lines)
        srcs = filter(startswith("@source"), lines)
        systems = filter(startswith("@system"), lines)
        # an agent reorders the lines and adds a lens and a mirror without uid
        agent = ["@component L5 = SphericalLens(0.05, -0.05, 0.005, 0.0254, 1.5) pos = (0.0, 0.3, 0.0) label = \"agent lens\"",
                 "@component M9 = RoundPlanoMirror(0.0254, 0.005)"]
        order = [lines[1]; reverse(comps); agent; reverse(srcs); reverse(systems)]
        write(file, join(order, '\n') * '\n')
        gui = open_project(dir; display = false, const_kw...)
        by = _byid(gui)
        @test gui.labels[by[:L5]] == "agent lens" && gui.labels[by[:M9]] == "M9"
        # a lens added in the view: after L5, the largest id of the lenses
        c = _built("Thin lens")
        add_component!(gui, c.obj; system = :none, origin = c.origin, select = false)
        save_project(gui)
        saved = split(chomp(read(file, String)), '\n')
        name(l) = match(r"^@\w+ (\w+) =", l).captures[1]
        @test name.(filter(startswith("@component"), saved)) ==
              [name.(reverse(comps)); "L5"; "M9"; "L6"]
        @test name.(filter(startswith("@source"), saved)) == name.(reverse(srcs))
        @test name.(filter(startswith("@system"), saved)) == name.(reverse(systems))
        # the lines of the agent got a uid, the others kept theirs
        p = load_project(dir)
        @test all(e -> !isnothing(e.uid), p.entries)
        old = Dict(name(l) => match(r"uid = \"(.*)\"", l).captures[1] for l in [comps; srcs; systems])
        @test all(e -> !haskey(old, String(e.name)) || old[String(e.name)] == e.uid, p.entries)
        @test gui.sync.ids[by[:L5]] == (:L5, only(e for e in p.entries if e.name === :L5).uid)
        close(gui)
    end

    @testset "save as" begin
        dir = mktempdir()
        t = _setup(:compact)
        save_project(t.gui, dir)
        close(t.gui)
        name = BMOP.project_name(dir)
        own = joinpath(dir, "src", name * ".jl")
        write(own, "module $name\nusing BeamletOptics\nexport extra_lens\n" *
                   "extra_lens(f) = SphericalLens(f, -f, 0.004, 0.0254, 1.5)\nend\n")
        write(joinpath(dir, "system.jl"), read(joinpath(dir, "system.jl"), String) *
                                           "@component L9 = extra_lens(0.2) pos = (0.0, 0.3, 0.0)\n")
        gui = open_project(dir; display = false, const_kw...)
        screen = GLMakie.Screen(visible = false)
        display(screen, gui.fig)
        title() = unsafe_string(ccall((:glfwGetWindowTitle, GLMakie.GLFW.libglfw), Cstring,
            (GLMakie.GLFW.Window,), screen.glscreen))
        target = joinpath(mktempdir(), "Bench copy")
        save_project(gui, target)
        @test gui.project == abspath(target)
        @test gui.status.text[] == "project saved as $(abspath(target))"
        @test title() == "Bench copy"
        # the own code is copied, the module kept: the copy loads
        @test read(joinpath(target, "src", name * ".jl"), String) == read(own, String)
        p = load_project(target)
        @test p.name == name && any(e -> e.name === :L9, p.entries)
        # Ctrl+S saves to the copy, the original stays
        before = read(joinpath(dir, "system.jl"), String)
        translate3d!(_byid(gui)[:L9], [0.0, 0.0, 0.01])
        save_project(gui)
        @test read(joinpath(dir, "system.jl"), String) == before
        @test position(load_project(target)[:L9]) ≈ [0.0, 0.3, 0.01]
        close(screen)
        close(gui)
    end

    @testset "end-to-end" begin
        dir = mktempdir()
        t = _setup(:app)
        gui = t.gui
        GUI._set_beam_opacity!(gui, t.b2, 0.5)
        push!(gui.camera.views, "side" => ([0.3, 0.0, 0.0], [0.0, 0.1, 0.0], [0.0, 0.0, 1.0]))
        set_view(gui.ax, [0.4, -0.3, 0.2], [0.0, 0.1, 0.0], [0.0, 0.0, 1.0])
        save_project(gui, dir)
        close(gui)
        code = read(joinpath(dir, "system.jl"), String)
        view = read(joinpath(dir, "view.toml"), String)
        gui2 = open_project(project_marker(dir); display = false, const_kw...)
        @test gui2.project == abspath(dir)
        save_project(gui2)
        @test read(joinpath(dir, "system.jl"), String) == code
        @test read(joinpath(dir, "view.toml"), String) == view
        @test count(x -> GUI._editable(gui2, x), collect(keys(gui2.components.origin))) == 6
        close(gui2)
    end
end

end
