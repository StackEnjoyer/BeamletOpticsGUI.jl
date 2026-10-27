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
            push!(entries, BMOP.Entry(e.kind, e.name, e.code, obj; e.pos, e.rot, pose0, e.meta))
        end
        byname = Dict(e.name => e.object for e in entries)
        systems = map(p.systems) do s
            objs = Any[byname[n] for n in s.members]
            sys = s.static ? StaticSystem(objs) : isempty(objs) ? System() : System(objs)
            BMOP.SystemEntry(s.name, s.members, s.sources; s.static, object = sys)
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

    _byname(gui) = Dict(Symbol(l) => x for (x, l) in gui.labels)

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
        @test [e.name for e in p.entries][[1, 3, 4, 5, 6]] == [:L1, :spare, :B1, :laser_2, :B3]
        @test [e.kind for e in p.entries] == [:component, :component, :component, :source, :source, :source]
        @test [s.name for s in p.systems] == [:Transmitter, :Receiver]
        @test p.systems[1].members == [names[t.lens]] && p.systems[1].sources == [:B1]
        @test p.systems[2].members == [names[t.lens], names[t.prism]] && p.systems[2].sources == [:laser_2]
        @test all(!s.static for s in p.systems)
        # names are free variable names
        @test all(e -> Base.isidentifier(String(e.name)), p.entries)
        e_lens = p.entries[1]
        @test e_lens.meta == [:catalog => ("Thin lens", ["80", "-60", "30", "N-SF11"])]
        @test e_lens.pos == Tuple(Float64.(position(t.lens)))
        @test e_lens.rot isa Matrix{Float64}
        # an unrotated source: no `rot`
        @test isnothing(p.entries[4].rot)
        GUI._write_view_toml(gui, p, names)
        view = TOML.parsefile(joinpath(dir, "view.toml"))
        @test view["beams"]["laser_2"]["color"] == _hex(:orange)
        @test view["beams"]["laser_2"]["alpha"] == 0.5 && view["beams"]["laser_2"]["linewidth"] == 3.0
        @test view["beams_off"] == ["B1"] && view["snap"] == "pose"

        # open: a project as `load_project` returns it
        p2 = _reload(p)
        gui2 = GUI._open_from(p2; layout)
        @test gui2.project == abspath(dir)
        by = _byname(gui2)
        @test Set([e.name for e in p.entries]) ∪ Set([:Transmitter, :Receiver]) ⊆ Set(keys(by))
        old = Dict(names[x] => x for x in keys(names))
        for e in p2.entries
            a, b = old[e.name], e.object
            @test typeof(a) === typeof(b) && by[e.name] === b
            @test position(b) == position(a)
            @test maximum(abs, GUI._pose(b)[2] - GUI._pose(a)[2]) < 1e-12
        end
        S1, S2 = by[:Transmitter], by[:Receiver]
        @test GUI._systems(gui2) == [S1, S2]
        lens2 = by[names[t.lens]]
        @test _in(lens2, S1.objects) && _in(lens2, S2.objects) && length(S2.objects) == 2
        @test GUI._sources_of(gui2, S1) == [by[:B1]] && GUI._sources_of(gui2, S2) == [by[:laser_2]]
        @test by[:B3] in gui2.beams.unassigned
        @test _in(by[:spare], GUI.rendered(gui2.extras).objects)
        @test isempty(gui2.controls.undo_stack) && isempty(gui2.controls.redo_stack)
        # view.toml
        @test _hex(gui2.beams.kwargs[by[:laser_2]].color) == _hex(:orange)
        @test GUI._beam_opacity(gui2, by[:laser_2]) == 0.5
        @test GUI._beam_linewidth(gui2, by[:laser_2]) == 3.0
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
        end
        # a moved one gets its new pose
        translate3d!(by[:spare], [0.0, 0.0, 0.01])
        p4 = GUI._collect_project(gui2, dir)
        e = only(e for e in p4.entries if e.name === :spare)
        @test e.pos == Tuple(Float64.(position(by[:spare])))

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
        # ... and is saved with its new code
        p5 = GUI._collect_project(gui2, dir)
        e = only(e for e in p5.entries if e.name === names[t.lens])
        @test last(only(e.meta))[2][1] == "120"
        @test position(new) ≈ position(lens2) atol = 1e-12
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
            # with a project: saved without the dialog
            rm(joinpath(dir, "system.jl"))
            _ctrl!(gui, Keyboard.s)
            @test calls[] == 2 && isfile(joinpath(dir, "system.jl"))
            # the names became the labels
            @test Base.isidentifier(gui.labels[t.prism]) && gui.labels[t.b2] == "laser_2"
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
            rm(joinpath(copy, "system.jl"))
            _ctrl!(gui, Keyboard.s)
            @test calls[] == 5 && isfile(joinpath(copy, "system.jl"))
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

    @testset "files changed outside" begin
        dir = mktempdir()
        t = _setup(:compact)
        gui = t.gui
        save_project(gui, dir)
        system = joinpath(dir, "system.jl")
        check!(g) = GUI._check_files!(g; const_kw...)
        # an agent appends a line (a function of its own code), the GUI saves in the meantime
        agent_line = "@component L9 = extra_lens(0.2) pos = (0.0, 0.3, 0.0)\n"
        name = BeamletOpticsProjects.project_name(dir)
        own = joinpath(dir, "src", name * ".jl")
        @test check!(gui).status === :none
        save_project(gui)
        @test check!(gui).status === :none
        # only the files changed: reloaded, after the second look, with the view state of the window
        set_view(gui.ax, [0.4, -0.3, 0.2], [0.0, 0.1, 0.0], [0.0, 0.0, 1.0])
        cam = GUI._current_view(gui)
        GUI._set_beam_opacity!(gui, t.b2, 0.25)
        write(own, "module $name\nusing BeamletOptics\nexport extra_lens\n" *
                   "extra_lens(f) = SphericalLens(f, -f, 0.004, 0.0254, 1.5)\nend\n")
        write(system, read(system, String) * agent_line)
        r = check!(gui)
        @test r.status === :pending && r.gui === gui
        r = check!(gui)
        @test r.status === :reloaded && r.gui !== gui
        gui2 = r.gui
        @test gui2.project == dir && haskey(_byname(gui2), :L9)
        @test all(abs.(reduce(vcat, GUI._current_view(gui2)) .- reduce(vcat, cam)) .< 1e-6)
        b2 = _byname(gui2)[:laser_2]
        @test GUI._snapshot(gui2, b2).kwargs.alpha == 0.25
        @test check!(gui2).status === :none
        # the setup changed here and there: the card, once; Ctrl+S does not overwrite
        translate3d!(gui2, _byname(gui2)[:spare], [0.0, 0.0, 0.01])
        agent_text = read(system, String) * "@component L10 = extra_lens(0.3)\n"
        write(system, agent_text)
        @test check!(gui2).status === :pending
        @test check!(gui2).status === :conflict
        @test GUI._info_card(gui2).obj isa GUI._ProjectConflict
        @test occursin("choose on the card", gui2.status.text[])
        @test check!(gui2).status === :none && check!(gui2).status === :none
        GUI._release_info!(gui2, GUI._ProjectConflict)
        GUI._save_to!(gui2, dir)
        @test read(system, String) == agent_text
        @test GUI._info_card(gui2).obj isa GUI._ProjectConflict
        @test_throws BeamletOpticsProjects.ProjectChanged save_project(gui2)
        # "Overwrite": the setup of the window
        GUI._resolve_conflict!(gui2, :overwrite)
        @test isnothing(GUI._info_card(gui2)) || !(GUI._info_card(gui2).obj isa GUI._ProjectConflict)
        @test !occursin("L10", read(system, String)) && check!(gui2).status === :none
        # a syntax error while the agent writes: the window stays, the line is named; then fixed
        good = read(system, String)
        write(system, good * "@component L11 = extra_lens(\n")
        @test check!(gui2).status === :pending
        r = check!(gui2)
        @test r.status === :failed && r.gui === gui2
        @test occursin(r"project not reloaded: .*system\.jl:\d+", gui2.status.text[])
        write(system, good * "@component L11 = extra_lens(0.4)\n")
        @test check!(gui2).status === :pending
        r = check!(gui2)
        @test r.status === :reloaded && haskey(_byname(r.gui), :L11)
        gui3 = r.gui
        # "Load from disk" through _reload!: the change here is lost
        translate3d!(gui3, _byname(gui3)[:spare], [0.0, 0.0, 0.01])
        moved = BeamletOptics.position(_byname(gui3)[:spare])
        gui4 = GUI._reload!(gui3; display = false, const_kw...)
        @test BeamletOptics.position(_byname(gui4)[:spare]) == moved .- [0.0, 0.0, 0.01]
        @test !GUI._setup_changed(gui4)
        # Ctrl+R without a project, and close stops the watcher
        gui5 = _live_view(System())
        GUI._reload_key!(gui5)
        @test startswith(gui5.status.text[], "no project to reload")
        close(gui5)
        gui4.sync.timer = Timer(100)
        close(gui4)
        @test isnothing(gui4.sync.timer)
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
