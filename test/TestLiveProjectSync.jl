module TestLiveProjectSync

using GLMakie, BeamletOptics, BeamletOpticsGUI
using BeamletOpticsProjects
using Makie
using Test

const GUI = BeamletOpticsGUI
const const_kw = (; trace_budget = Inf, throttle = false, detectors = [])

const LENS = "SphericalLens(0.05, -0.05, 0.005, 0.0254, 1.5)"
const START = """
    @component L1 = $LENS pos = (0.0, 0.1, 0.0)
    @component M1 = RoundPlanoMirror(0.0254, 0.006) pos = (0.0, 0.2, 0.0)
    @component D1 = Detector(0.02) pos = (0.0, 0.3, 0.0)
    @source B1 = Beam([0.0, 0.0, 0.0], [0.0, 1.0, 0.0], 1.0e-6)
    @system S1 = [L1, M1, D1] sources = [B1]
    """

"""A project with `START`, opened (not shown) and saved once, so that every line has a uid."""
function opened()
    dir = mktempdir()
    new_project(dir; name = "Bench")
    write(joinpath(dir, "system.jl"), START)
    gui = open_project(dir; display = false, const_kw...)
    save_project(gui)
    return gui, dir
end

system(dir) = joinpath(dir, "system.jl")
edit!(f, dir) = write(system(dir), f(read(system(dir), String)))

"""Two looks of the watcher: the files changed, then settled."""
function tick!(gui)
    t = time()
    first = GUI._check_files!(gui; now = t)
    return first === :pending ? GUI._check_files!(gui; now = t + 1) : first
end

"""The object of the readable id `id` in the window."""
function obj(gui, id)
    for (x, (name, _)) in gui.sync.ids
        name === id && return x
    end
    return nothing
end

_has_member(sys, o) = any(x -> x === o, sys.objects)

"""Replaces the line of `id` in `text` by `f(line)`."""
function line!(f, text, id)
    lines = split(text, "\n")
    i = findfirst(l -> occursin(Regex("^@(component|source|system) $id = "), l), lines)
    lines[i] = f(lines[i])
    return join(lines, "\n")
end

@testset "Live changes of the files" begin
    gui, dir = opened()
    ctrl = gui.controls
    undo = length(ctrl.undo_stack)

    @testset "moved, in place" begin
        l1 = obj(gui, :L1)
        edit!(text -> line!(l -> replace(l, "pos = (0.0, 0.1, 0.0)" => "pos = (0.0, 0.12, 0.01) rot = (0.0, 0.0, 30.0)"), text, "L1"), dir)
        @test tick!(gui) === :applied
        @test obj(gui, :L1) === l1
        @test BeamletOptics.position(l1) ≈ [0.0, 0.12, 0.01] atol = 1e-15
        @test occursin("moved L1", gui.status.text[])
        # The window writes the same line again
        @test occursin("pos = (0.0, 0.12, 0.01) rot = (0.0, 0.0, 30.0)",
            BeamletOpticsProjects.system_code(GUI._collect_project(gui, dir)))
    end

    @testset "added into a system" begin
        edit!(text -> line!(l -> replace(l, "[L1, M1, D1]" => "[L1, M1, D1, T1]"),
            text * "@component T1 = $LENS pos = (0.0, 0.4, 0.0)\n", "S1"), dir)
        @test tick!(gui) === :applied
        t1 = obj(gui, :T1)
        @test !isnothing(t1) && any(o -> o === t1, only(GUI._systems(gui)).objects)
        @test BeamletOptics.position(t1) == [0.0, 0.4, 0.0]
    end

    @testset "rebuilt, removed" begin
        d1 = obj(gui, :D1)
        uid = gui.sync.ids[d1][2]
        edit!(text -> line!(l -> replace(l, "Detector(0.02)" => "Detector(0.03)"), text, "D1"), dir)
        @test tick!(gui) === :applied
        d1b = obj(gui, :D1)
        @test d1b !== d1 && gui.sync.ids[d1b][2] == uid
        @test any(o -> o === d1b, only(GUI._systems(gui)).objects)
        @test BeamletOptics.position(d1b) == [0.0, 0.3, 0.0]
        m1 = obj(gui, :M1)
        edit!(dir) do text
            text = join(filter(l -> !startswith(l, "@component M1 = "), split(text, "\n")), "\n")
            return line!(l -> replace(l, "M1, " => ""), text, "S1")
        end
        @test tick!(gui) === :applied
        @test isnothing(obj(gui, :M1)) && !any(o -> o === m1, only(GUI._systems(gui)).objects)
    end

    @testset "renamed and relabeled" begin
        l1 = obj(gui, :L1)
        edit!(dir) do text
            text = line!(l -> replace(l, "@component L1 = " => "@component L7 = ") , text, "L1")
            text = line!(l -> replace(l, "uid = " => "label = \"Kollimator\" uid = "), text, "L7")
            return line!(l -> replace(l, "[L1, " => "[L7, "), text, "S1")
        end
        @test tick!(gui) === :applied
        @test obj(gui, :L7) === l1 && gui.labels[l1] == "Kollimator"
    end

    @testset "own code" begin
        own = joinpath(dir, "src", "Bench.jl")
        write(own, "module Bench\nusing BeamletOptics\nexport flat_lens\nflat_lens(r) = SphericalLens(r, Inf, 0.004, 0.0254, 1.5)\nend\n")
        edit!(text -> text * "@component Q1 = flat_lens(0.1) pos = (0.0, 0.5, 0.0)\n", dir)
        @test tick!(gui) === :applied
        q1 = obj(gui, :Q1)
        @test !isnothing(q1)
        write(own, "module Bench\nusing BeamletOptics\nexport flat_lens\nflat_lens(r) = SphericalLens(r, -r, 0.004, 0.0254, 1.5)\nend\n")
        @test tick!(gui) === :applied
        @test obj(gui, :Q1) !== q1 && BeamletOptics.position(obj(gui, :Q1)) == [0.0, 0.5, 0.0]
        # The merge reads the times of the own code itself, not those of the last look (which the
        # watcher reads in the background, possibly before the change)
        q1 = obj(gui, :Q1)
        write(own, "module Bench\nusing BeamletOptics\nexport flat_lens\nflat_lens(r) = SphericalLens(r, -2r, 0.004, 0.0254, 1.5)\nend\n")
        edit!(text -> text * "\n", dir)
        @test GUI._sync!(gui; animate = false) === :applied
        @test obj(gui, :Q1) !== q1
    end

    @testset "merged with changes in the window" begin
        t1 = obj(gui, :T1)
        translate3d!(gui, t1, [0.0, 0.0, 0.02])
        mine = BeamletOptics.position(t1)
        edit!(text -> line!(l -> replace(l, "pos = (0.0, 0.3, 0.0)" => "pos = (0.0, 0.31, 0.0)"), text, "D1"), dir)
        @test tick!(gui) === :applied
        @test BeamletOptics.position(t1) == mine
        @test BeamletOptics.position(obj(gui, :D1)) == [0.0, 0.31, 0.0]
        # Ctrl+S writes both, without a conflict
        save_project(gui)
        text = read(system(dir), String)
        @test occursin("pos = (0.0, 0.31, 0.0)", text) && occursin(string(mine[3]), text)
        @test tick!(gui) === :none
    end

    @testset "conflict" begin
        d1 = obj(gui, :D1)
        translate3d!(gui, d1, [0.01, 0.0, 0.0])
        edit!(text -> line!(l -> replace(l, "pos = (0.0, 0.31, 0.0)" => "pos = (0.0, 0.32, 0.0)"), text, "D1"), dir)
        @test tick!(gui) === :conflict
        card = GUI._info_card(gui)
        @test card.obj isa GUI._ProjectConflict && card.obj.names == ["D1"]
        @test BeamletOptics.position(d1) == [0.01, 0.31, 0.0]
        GUI._resolve_conflict!(gui, :theirs)
        @test BeamletOptics.position(obj(gui, :D1)) == [0.0, 0.32, 0.0]
        # Keep mine: the next save writes it
        translate3d!(gui, obj(gui, :D1), [0.0, 0.0, 0.01])
        edit!(text -> line!(l -> replace(l, "pos = (0.0, 0.32, 0.0)" => "pos = (0.0, 0.33, 0.0)"), text, "D1"), dir)
        @test tick!(gui) === :conflict
        GUI._resolve_conflict!(gui, :mine)
        save_project(gui)
        @test occursin("pos = (0.0, 0.32, 0.01)", read(system(dir), String))
    end

    @testset "syntax error, then fixed and back" begin
        good = read(system(dir), String)
        edit!(text -> text * "@component Z1 = $(LENS[1:end-1])\n", dir)
        @test tick!(gui) === :failed
        @test occursin(r"project not reloaded: system\.jl:\d+:\d+: ", gui.status.text[])
        write(system(dir), good)
        @test tick!(gui) === :none
        @test gui.status.text[] == "project files are as in the window"
    end

    @testset "Ctrl+S after a change of the files that the watcher did not see yet" begin
        edit!(text -> line!(l -> replace(l, "pos = (0.0, 0.32, 0.01)" => "pos = (0.0, 0.34, 0.01)"), text, "D1"), dir)
        translate3d!(gui, obj(gui, :T1), [0.5, 0.0, 0.0])
        GUI._save_to!(gui, dir)
        text = read(system(dir), String)
        @test occursin("pos = (0.0, 0.34, 0.01)", text) && occursin("pos = (0.5, 0.4, 0.02)", text)
        @test startswith(gui.status.text[], "project saved")
    end

    @testset "Ctrl+R loads the files in place" begin
        t1 = obj(gui, :T1)
        translate3d!(gui, t1, [0.05, 0.0, 0.0])
        GUI._reload_key!(gui)
        @test obj(gui, :T1) === t1 && BeamletOptics.position(t1)[1] == 0.5
    end

    @testset "no undo entries of the files" begin
        n = length(ctrl.undo_stack)
        edit!(text -> line!(l -> replace(l, "pos = (0.0, 0.5, 0.0)" => "pos = (0.0, 0.55, 0.0)"), text, "Q1"), dir)
        @test tick!(gui) === :applied
        @test length(ctrl.undo_stack) == n
    end

    @testset "time of a merge" begin
        edit!(text -> line!(l -> replace(l, "pos = (0.0, 0.55, 0.0)" => "pos = (0.0, 0.56, 0.0)"), text, "Q1"), dir)
        t = time()
        GUI._check_files!(gui; now = t)
        elapsed = @elapsed GUI._check_files!(gui; now = t + 1)
        @info "a merge of the files took $(round(elapsed * 1000; digits = 1)) ms"
        @test elapsed < 1.0
    end
    close(gui)
end

"""Looks of the autosave: the setup changed, not settled yet, settled."""
function autosave!(gui)
    t = time()
    first = GUI._autosave!(gui; now = t)
    first === :pending || return first
    @test GUI._autosave!(gui; now = t + 0.2) === :pending
    return GUI._autosave!(gui; now = t + 1)
end

"""Makes the hidden `gui` count as a shown window: a watcher (that never fires) and session.md."""
function watched!(gui)
    gui.sync.timer = Timer(3600)
    GUI._connect_session!(gui)
    return gui
end

pos_line(dir, id) = only(l for l in split(read(system(dir), String), "\n")
                         if startswith(l, "@component $id = ") || startswith(l, "@source $id = "))

@testset "Autosave" begin
    gui, dir = opened()

    @testset "a move is written once it settled" begin
        @test GUI._autosave!(gui) === :none
        before = read(system(dir), String)
        translate3d!(gui, obj(gui, :L1), [0.0, 0.0, 0.01])
        t = time()
        @test GUI._autosave!(gui; now = t) === :pending
        @test GUI._autosave!(gui; now = t + 0.2) === :pending
        @test read(system(dir), String) == before
        @test GUI._autosave!(gui; now = t + 0.6) === :saved
        @test occursin("pos = (0.0, 0.1, 0.01)", pos_line(dir, "L1"))
        # Its own write is no change of the files
        @test tick!(gui) === :none
        @test last(gui.sync.journal)[2] == "moved L1 to (0.0, 0.1, 0.01)"
        @test occursin("moved L1", read(GUI._session_file(dir), String))
    end

    @testset "nothing to write" begin
        m = mtime(system(dir))
        @test GUI._autosave!(gui; now = time() + 10) === :none
        @test mtime(system(dir)) == m
    end

    @testset "not while dragging or with changed files" begin
        translate3d!(gui, obj(gui, :M1), [0.0, 0.0, 0.01])
        gui.controls.dragging = true
        @test GUI._autosave!(gui) === :paused
        gui.controls.dragging = false
        gui.sync.changed_at = time()
        @test GUI._autosave!(gui) === :paused
        gui.sync.changed_at = nothing
        @test autosave!(gui) === :saved
        @test occursin("pos = (0.0, 0.2, 0.01)", pos_line(dir, "M1"))
    end

    @testset "a new object is written once, with one uid" begin
        lens = SphericalLens(0.05, -0.05, 0.005, 0.0254, 1.5)
        add_component!(gui, lens; system = only(GUI._systems(gui)), select = false, code = LENS)
        translate3d!(gui, lens, [0.0, 0.6, 0.0])
        @test autosave!(gui) === :saved
        line = only(l for l in split(read(system(dir), String), "\n") if occursin("0.6", l))
        @test occursin(r"uid = \"[0-9a-f-]{36}\"", line)
        @test GUI._autosave!(gui; now = time() + 10) === :none
        @test any(l -> startswith(l[2], "added L"), gui.sync.journal)
    end

    @testset "an agent's change and a change in the window, both written" begin
        translate3d!(gui, obj(gui, :L1), [0.01, 0.0, 0.0])
        edit!(text -> line!(l -> replace(l, "pos = (0.0, 0.3, 0.0)" => "pos = (0.0, 0.31, 0.0)"), text, "D1"), dir)
        @test tick!(gui) === :applied
        @test autosave!(gui) === :saved
        @test occursin("pos = (0.01, 0.1, 0.01)", pos_line(dir, "L1"))
        @test occursin("pos = (0.0, 0.31, 0.0)", pos_line(dir, "D1"))
        # The agent's change is no change of the person
        @test !any(l -> occursin("D1", l[2]), gui.sync.journal)
    end

    @testset "the files do not load: backup, then saved when they load again" begin
        good = read(system(dir), String)
        edit!(text -> text * "@component Z1 = $(LENS[1:end-1])\n", dir)
        @test tick!(gui) === :failed
        translate3d!(gui, obj(gui, :L1), [0.0, 0.0, 0.01])
        @test autosave!(gui) === :paused
        # one backup per person
        backup = joinpath(dir, ".bmo", "window-backup-$(GUI._person().id).jl")
        @test isfile(backup)
        @test occursin("window-backup-", gui.status.text[])
        @test GUI._autosave!(gui; now = time() + 10) === :paused
        # The backup loads as a project
        copy = mktempdir()
        new_project(copy; name = "Bench")
        cp(backup, system(copy); force = true)
        @test length(load_project(copy).entries) == length(gui.sync.base.entries)
        # The agent fixes the file, with another change
        write(system(dir), replace(good, "pos = (0.0, 0.31, 0.0)" => "pos = (0.0, 0.32, 0.0)"))
        @test tick!(gui) === :applied
        @test autosave!(gui) === :saved
        @test occursin("pos = (0.01, 0.1, 0.02)", pos_line(dir, "L1"))
        @test occursin("pos = (0.0, 0.32, 0.0)", pos_line(dir, "D1"))
    end

    @testset "an agent writing from an older read is a conflict" begin
        old = read(system(dir), String)
        m1 = obj(gui, :M1)
        translate3d!(gui, m1, [0.0, 0.0, 0.01])
        @test autosave!(gui) === :saved
        mine = BeamletOptics.position(m1)
        # The agent writes the whole file it read before, with a change of its own
        write(system(dir), replace(old, "pos = (0.0, 0.32, 0.0)" => "pos = (0.0, 0.33, 0.0)"))
        @test tick!(gui) === :conflict
        @test BeamletOptics.position(m1) == mine
        @test gui.sync.conflicts == [gui.sync.ids[m1][2]]
        @test BeamletOptics.position(obj(gui, :D1)) == [0.0, 0.33, 0.0]
        # The conflict holds only M1: nothing else to save, and M1 keeps the files' state
        GUI._autosave!(gui)
        @test GUI._autosave!(gui; now = time() + 10) === :none
        @test occursin("pos = (0.0, 0.2, 0.01)", pos_line(dir, "M1"))
        GUI._resolve_conflict!(gui, :mine)
        @test autosave!(gui) === :saved
        @test occursin("pos = (0.0, 0.2, 0.02)", pos_line(dir, "M1"))
    end

    @testset "an agent setting back its own change is no conflict" begin
        edit!(text -> line!(l -> replace(l, "pos = (0.0, 0.33, 0.0)" => "pos = (0.0, 0.4, 0.0)"), text, "D1"), dir)
        @test tick!(gui) === :applied
        edit!(text -> line!(l -> replace(l, "pos = (0.0, 0.4, 0.0)" => "pos = (0.0, 0.33, 0.0)"), text, "D1"), dir)
        @test tick!(gui) === :applied
        @test BeamletOptics.position(obj(gui, :D1)) == [0.0, 0.33, 0.0]
    end

    @testset "closing a watched window saves the last change" begin
        watched!(gui)
        translate3d!(gui, obj(gui, :M1), [0.0, 0.0, 0.01])
        @test GUI._autosave!(gui) === :pending
        close(gui)
        @test occursin("pos = (0.0, 0.2, 0.03)", pos_line(dir, "M1"))
        @test !isfile(GUI._session_file(dir)) && !isfile(GUI._presence_file(dir, GUI._person().id))
        # No watcher starts again, also not by that save
        @test isnothing(gui.sync.timer) && gui.sync.closed
    end
end

@testset "Corner cases of the autosave and the merge" begin
    @testset "a shared drive: dotfiles, the window of another person" begin
        gui, dir = opened()
        # macOS writes ._X files beside the files on a shared drive
        write(joinpath(dir, "src", "._Bench.jl"), "\0\0 not julia")
        @test GUI._file_marks(dir) == gui.sync.marks
        @test tick!(gui) === :none
        # The window of Anna wrote the next state of the files and published its stamp
        edit!(text -> line!(l -> replace(l, "pos = (0.0, 0.1, 0.0)" => "pos = (0.0, 0.15, 0.0)"), text, "L1"), dir)
        write(GUI._presence_file(dir, "Anna@pc2"), """
            name = "Anna"
            host = "pc2"
            beat = 1
            selected = ""
            selected_id = ""
            written = "$(project_stamp(dir))"
            """)
        GUI._check_presence!(gui)
        @test tick!(gui) === :applied
        @test startswith(gui.status.text[], "Anna: moved")
        # Without a match it was an agent
        edit!(text -> line!(l -> replace(l, "pos = (0.0, 0.15, 0.0)" => "pos = (0.0, 0.16, 0.0)"), text, "L1"), dir)
        @test tick!(gui) === :applied
        @test startswith(gui.status.text[], "agent: moved")
        close(gui)
    end

    @testset "the window and the files both add to a system: no conflict" begin
        gui, dir = opened()
        GUI._autosave!(gui)
        s1 = only(GUI._systems(gui))
        mine = SphericalLens(0.05, -0.05, 0.005, 0.0254, 1.5)
        add_component!(gui, mine; system = s1, select = false, code = LENS)
        translate3d!(gui, mine, [0.0, 0.45, 0.0])
        edit!(text -> line!(l -> replace(l, "D1]" => "D1, T1]"),
            text * "@component T1 = $LENS pos = (0.0, 0.4, 0.0)\n", "S1"), dir)
        @test tick!(gui) === :applied
        t1 = obj(gui, :T1)
        @test _has_member(s1, t1) && _has_member(s1, mine)
        @test isempty(gui.sync.conflicts)
        # The autosave writes both into the system
        @test autosave!(gui) === :saved
        line = only(l for l in split(read(system(dir), String), "\n") if startswith(l, "@system S1 = "))
        @test occursin("T1", line) && count(",", split(line, "]")[1]) == 4
        close(gui)
    end

    @testset "a member renamed or rebuilt in the files keeps the window's members" begin
        gui, dir = opened()
        edit!(text -> text * "@component X1 = $LENS pos = (0.0, 0.6, 0.0)\n", dir)
        @test tick!(gui) === :applied
        s1, x1 = only(GUI._systems(gui)), obj(gui, :X1)
        # Not saved yet: X1 into S1, while the files rename D1 (same uid), then rebuild L1
        GUI._add_member!(gui, x1, s1)
        edit!(text -> replace(text, "D1 = " => "D2 = ", "D1]" => "D2]"), dir)
        @test tick!(gui) === :applied
        @test obj(gui, :D2) !== nothing && _has_member(s1, x1)
        edit!(text -> line!(l -> replace(l, "0.005, 0.0254" => "0.006, 0.0254"), text, "L1"), dir)
        @test tick!(gui) === :applied
        @test _has_member(s1, x1) && isempty(gui.sync.conflicts)
        close(gui)
    end

    @testset "a member that the person removed stays removed" begin
        gui, dir = opened()
        edit!(text -> text * "@component X1 = $LENS pos = (0.0, 0.6, 0.0)\n", dir)
        @test tick!(gui) === :applied
        s1, x1 = only(GUI._systems(gui)), obj(gui, :X1)
        # Not saved yet: X1 removed and a new lens in S1, while the files put X1 into S1 (merged)
        remove_component!(gui, x1)
        mine = SphericalLens(0.05, -0.05, 0.005, 0.0254, 1.5)
        add_component!(gui, mine; system = s1, select = false, code = LENS)
        edit!(text -> line!(l -> replace(l, "D1]" => "D1, X1]"), text, "S1"), dir)
        @test tick!(gui) === :applied
        @test _has_member(s1, mine) && !_has_member(s1, x1) && !GUI._shown_top(gui, x1)
        close(gui)
        # Only removed in the window: the system of the files is taken, without X1
        gui, dir = opened()
        edit!(text -> text * "@component X1 = $LENS pos = (0.0, 0.6, 0.0)\n", dir)
        @test tick!(gui) === :applied
        s1, x1 = only(GUI._systems(gui)), obj(gui, :X1)
        remove_component!(gui, x1)
        edit!(text -> line!(l -> replace(l, "D1]" => "D1, X1]"), text, "S1"), dir)
        @test tick!(gui) === :applied
        @test !_has_member(s1, x1) && !GUI._shown_top(gui, x1)
        close(gui)
    end

    @testset "a write that leaves the times and sizes of the files as they were" begin
        gui, dir = opened()
        l1 = obj(gui, :L1)
        edit!(text -> line!(l -> replace(l, "pos = (0.0, 0.1, 0.0)" => "pos = (0.0, 0.2, 0.0)"), text, "L1"), dir)
        # As if the watcher had seen these times and sizes already, e.g. of its own save
        gui.sync.marks = GUI._file_marks(dir)
        @test tick!(gui) === :applied
        @test BeamletOptics.position(l1) == [0.0, 0.2, 0.0]
        @test tick!(gui) === :none
        close(gui)
    end

    @testset "closing a hidden view saves nothing" begin
        gui, dir = opened()
        before = read(system(dir), String)
        translate3d!(gui, obj(gui, :L1), [0.0, 0.0, 0.01])
        close(gui)
        @test read(system(dir), String) == before
        @test !isfile(GUI._session_file(dir))
    end

    @testset "an object gliding to a pose of the files" begin
        gui, dir = opened()
        GUI._autosave!(gui)
        m1 = obj(gui, :M1)
        # The merge of a shown window glides; here it is asked for
        edit!(text -> line!(l -> replace(l, "pos = (0.0, 0.2, 0.0)" => "pos = (0.0, 0.3, 0.0)"), text, "M1"), dir)
        @test GUI._sync!(gui; animate = true) === :applied
        @test haskey(gui.sync.gliding, m1)
        # The autosave waits until it landed
        translate3d!(gui, obj(gui, :L1), [0.0, 0.0, 0.01])
        @test GUI._autosave!(gui; now = time() + 10) === :paused
        # A save lands it at once and writes the pose of the files, not the one of the glide
        @test GUI._autosave!(gui; force = true) === :saved
        @test isempty(gui.sync.gliding)
        @test BeamletOptics.position(m1) == [0.0, 0.3, 0.0]
        @test occursin("pos = (0.0, 0.3, 0.0)", pos_line(dir, "M1"))
        @test !any(l -> occursin("M1", l[2]), gui.sync.journal)
        sleep(0.5)
        @test BeamletOptics.position(m1) == [0.0, 0.3, 0.0]
        close(gui)
    end

    @testset "files that break before a forced save: backup" begin
        gui, dir = opened()
        watched!(gui)
        translate3d!(gui, obj(gui, :L1), [0.0, 0.0, 0.01])
        @test GUI._autosave!(gui) === :pending
        # The agent breaks the file, the watcher did not look yet; the window closes
        edit!(text -> text * "@component Z1 = $(LENS[1:end-1])\n", dir)
        close(gui)
        backup = joinpath(dir, ".bmo", "window-backup-$(GUI._person().id).jl")
        @test isfile(backup) && occursin("pos = (0.0, 0.1, 0.01)", read(backup, String))
        @test gui.sync.failed && !isempty(gui.sync.load_error)
    end

    @testset "a conflict stays until the person decides" begin
        gui, dir = opened()
        GUI._autosave!(gui)
        l1, d1 = obj(gui, :L1), obj(gui, :D1)
        translate3d!(gui, l1, [0.01, 0.0, 0.0])
        edit!(text -> line!(l -> replace(l, "pos = (0.0, 0.1, 0.0)" => "pos = (0.0, 0.11, 0.0)"), text, "L1"), dir)
        @test tick!(gui) === :conflict
        key = gui.sync.ids[l1][2]
        @test gui.sync.conflicts == [key]
        # The agent goes on with D1 only: the conflict on L1 stays
        edit!(text -> line!(l -> replace(l, "pos = (0.0, 0.3, 0.0)" => "pos = (0.0, 0.31, 0.0)"), text, "D1"), dir)
        @test tick!(gui) === :conflict
        @test gui.sync.conflicts == [key] && GUI._conflict_shown(gui)
        @test BeamletOptics.position(d1) == [0.0, 0.31, 0.0]
        # Nothing else to save: the conflict holds only L1, which keeps the files' state
        GUI._autosave!(gui)
        @test GUI._autosave!(gui; now = time() + 10) === :none
        # The card is closed without a decision; a change of the person is saved, the card stays
        # closed and the conflict open
        GUI._release_info!(gui, GUI._ProjectConflict)
        translate3d!(gui, d1, [0.0, 0.0, 0.01])
        @test GUI._autosave!(gui) === :pending
        @test !GUI._conflict_shown(gui)
        @test GUI._autosave!(gui; now = time() + 10) === :saved
        @test occursin("pos = (0.0, 0.31, 0.01)", pos_line(dir, "D1"))
        @test occursin("pos = (0.0, 0.11, 0.0)", pos_line(dir, "L1")) && gui.sync.conflicts == [key]
        # Take theirs: L1 of the files
        GUI._resolve_conflict!(gui, :theirs)
        @test BeamletOptics.position(l1) == [0.0, 0.11, 0.0]
        @test isempty(gui.sync.conflicts)
        # the window is as in the files now
        @test autosave!(gui) === :none
        @test occursin("pos = (0.0, 0.11, 0.0)", pos_line(dir, "L1"))
        @test occursin("pos = (0.0, 0.31, 0.01)", pos_line(dir, "D1"))
        close(gui)
    end

    @testset "Ctrl+R ends a conflict" begin
        gui, dir = opened()
        GUI._autosave!(gui)
        translate3d!(gui, obj(gui, :L1), [0.01, 0.0, 0.0])
        edit!(text -> line!(l -> replace(l, "pos = (0.0, 0.1, 0.0)" => "pos = (0.0, 0.11, 0.0)"), text, "L1"), dir)
        @test tick!(gui) === :conflict
        GUI._reload_key!(gui)
        @test isempty(gui.sync.conflicts) && !GUI._conflict_shown(gui)
        @test GUI._autosave!(gui) === :none
        close(gui)
    end

    @testset "Save as… of a conflict, cancelled: the conflict stays" begin
        gui, dir = opened()
        GUI._autosave!(gui)
        translate3d!(gui, obj(gui, :L1), [0.01, 0.0, 0.0])
        edit!(text -> line!(l -> replace(l, "pos = (0.0, 0.1, 0.0)" => "pos = (0.0, 0.11, 0.0)"), text, "L1"), dir)
        @test tick!(gui) === :conflict
        dialog = GUI._SAVE_DIALOG[]
        GUI._SAVE_DIALOG[] = _ -> nothing
        try
            GUI._resolve_conflict!(gui, :save_as)
            wait(GUI._DIALOG_TASK[])
        finally
            GUI._SAVE_DIALOG[] = dialog
        end
        @test !isempty(gui.sync.conflicts)
        # the conflict holds L1 with the files' state; nothing else to save
        GUI._autosave!(gui)
        @test GUI._autosave!(gui; now = time() + 10) === :none
        @test occursin("pos = (0.0, 0.11, 0.0)", pos_line(dir, "L1"))
        close(gui)
    end

    @testset "no false conflicts of an agent's own changes" begin
        gui, dir = opened()
        GUI._autosave!(gui)
        # The agent moves L1, the person moves M1 (an autosave writes L1 as merged), the agent
        # sets L1 back
        edit!(text -> line!(l -> replace(l, "pos = (0.0, 0.1, 0.0)" => "pos = (0.0, 0.15, 0.0)"), text, "L1"), dir)
        @test tick!(gui) === :applied
        translate3d!(gui, obj(gui, :M1), [0.0, 0.0, 0.01])
        @test autosave!(gui) === :saved
        edit!(text -> line!(l -> replace(l, "pos = (0.0, 0.15, 0.0)" => "pos = (0.0, 0.1, 0.0)"), text, "L1"), dir)
        @test tick!(gui) === :applied
        @test BeamletOptics.position(obj(gui, :L1)) == [0.0, 0.1, 0.0]
        # The agent removes D1 and brings it back as it was
        full = read(system(dir), String)
        edit!(dir) do text
            text = join(filter(l -> !startswith(l, "@component D1 = "), split(text, "\n")), "\n")
            return line!(l -> replace(l, ", D1]" => "]"), text, "S1")
        end
        @test tick!(gui) === :applied
        @test isnothing(obj(gui, :D1))
        write(system(dir), full)
        @test tick!(gui) === :applied
        @test !isnothing(obj(gui, :D1))
        close(gui)
    end

    @testset "an agent overwriting the person's undo is a conflict" begin
        gui, dir = opened()
        GUI._autosave!(gui)
        l1 = obj(gui, :L1)
        # The person moves L1, the agent moves it on, the person undoes the move (Ctrl+Z)
        translate3d!(gui, l1, [0.0, 0.0, 0.01])
        @test autosave!(gui) === :saved
        edit!(text -> line!(l -> replace(l, "pos = (0.0, 0.1, 0.01)" => "pos = (0.0, 0.1, 0.02)"), text, "L1"), dir)
        @test tick!(gui) === :applied
        stale = read(system(dir), String)
        translate3d!(gui, l1, [0.0, 0.0, -0.02])
        @test autosave!(gui) === :saved
        # The agent writes the file of its older read
        write(system(dir), stale)
        @test tick!(gui) === :conflict
        @test BeamletOptics.position(l1) == [0.0, 0.1, 0.0]
        close(gui)
    end

    @testset "objects without a recipe: warned once" begin
        gui, dir = opened()
        GUI._autosave!(gui)
        add_component!(gui, RoundPlanoMirror(0.0254, 0.006); system = :none, select = false)
        translate3d!(gui, obj(gui, :L1), [0.0, 0.0, 0.01])
        t = time()
        GUI._autosave!(gui; now = t)
        @test_logs (:warn, r"1 objects without a recipe") GUI._autosave!(gui; now = t + 1)
        @test occursin("without a recipe", gui.status.text[])
        translate3d!(gui, obj(gui, :L1), [0.0, 0.0, 0.01])
        t = time()
        GUI._autosave!(gui; now = t)
        @test_logs GUI._autosave!(gui; now = t + 1)
        close(gui)
    end
end

@testset "Time of a merge and an autosave of a larger setup" begin
    dir = mktempdir()
    new_project(dir; name = "Bench")
    lines = ["@component L$i = $LENS pos = (0.0, $(0.01 * i), 0.0)" for i in 1:23]
    write(system(dir), join(lines, "\n") * "\n@system S1 = [$(join(("L$i" for i in 1:23), ", "))]\n")
    gui = open_project(dir; display = false, const_kw...)
    save_project(gui)
    GUI._autosave!(gui)
    function round!(id, from, to, other)
        edit!(text -> line!(l -> replace(l, from => to), text, id), dir)
        translate3d!(gui, obj(gui, other), [0.0, 0.0, 0.001])
        t = time()
        GUI._check_files!(gui; now = t)
        merge = @elapsed GUI._check_files!(gui; now = t + 1)
        GUI._autosave!(gui; now = t + 1)
        save = @elapsed GUI._autosave!(gui; now = t + 2)
        return merge, save
    end
    # The first round compiles
    round!("L2", "pos = (0.0, 0.02, 0.0)", "pos = (0.0, 0.021, 0.0)", :L3)
    merge, save = round!("L5", "pos = (0.0, 0.05, 0.0)", "pos = (0.0, 0.051, 0.0)", :L9)
    # The merge loads the project, which runs `system.jl` (most of its time)
    @info "with 23 objects, a merge took $(round(merge * 1000; digits = 1)) ms, an autosave $(round(save * 1000; digits = 1)) ms"
    @test save < 0.05
    @test occursin("pos = (0.0, 0.051, 0.0)", pos_line(dir, "L5"))
    @test occursin("pos = (0.0, 0.09, 0.001)", pos_line(dir, "L9"))
    close(gui)
end

@testset "The watcher reads the files in the background" begin
    gui, dir = opened()
    s = gui.sync
    # The next look of the watcher, after the one that runs is done
    function take!(now)
        isnothing(s.look) || wait(s.look.task)
        return GUI._take_look!(gui; now)
    end
    t = time()
    @testset "a look at a time, the stamp of the contents seldom" begin
        # The first call starts a look; the window does not wait for it
        @test GUI._take_look!(gui; now = t) === nothing
        @test s.look.task isa Task
        look = take!(t + 0.1)
        @test look.dir == dir && look.marks == GUI._file_marks(dir)
        @test look.stamp == s.stamp
        # Then without a stamp, until `_STAMP_EVERY` passed
        @test take!(t + 0.2).stamp === nothing
        @test take!(t + 0.2 + GUI._STAMP_EVERY).stamp === nothing
        @test take!(t + 0.3 + GUI._STAMP_EVERY).stamp == s.stamp
    end
    @testset "a look that waits, e.g. behind a solve" begin
        t2 = t + 5
        take!(t2)
        wait(s.look.task)
        slow = Threads.@spawn (sleep(1.0); GUI._files_look(dir))
        s.look = (; task = slow, gen = s.gen, presence = false)
        # While it runs, nothing, until `_LOOK_WAIT` passed: then read here, without the stamp
        @test GUI._take_look!(gui; now = t2 + 0.1) === nothing
        look = GUI._take_look!(gui; now = t2 + GUI._LOOK_WAIT)
        @test look.marks == GUI._file_marks(dir) && look.stamp === nothing
        @test GUI._take_look!(gui; now = t2 + GUI._LOOK_WAIT + 0.1) === nothing
        # The waiting one is dropped once it is done: it started before
        wait(slow)
        @test GUI._take_look!(gui; now = t2 + 3) === nothing
        @test !isnothing(take!(t2 + 3.1))
    end
    @testset "a look that failed is thrown once, the next one runs" begin
        take!(t + 10)
        wait(s.look.task)
        failed = Threads.@spawn error("network gone")
        s.look = (; task = failed, gen = s.gen, presence = true)
        s.presence_due = false
        try
            wait(failed)
        catch
        end
        @test_throws ErrorException("network gone") GUI._take_look!(gui; now = t + 10.1)
        # its presence file is written by the next look
        @test s.look.presence
        @test !isnothing(take!(t + 10.2))
    end
    @testset "a change of the files, through the looks" begin
        edit!(text -> line!(l -> replace(l, "pos = (0.0, 0.1, 0.0)" => "pos = (0.0, 0.13, 0.0)"), text, "L1"), dir)
        take!(t + 20)
        look = take!(t + 20.1)
        @test GUI._check_files!(gui; now = t + 20.1, look) === :pending
        look = take!(t + 21)
        @test GUI._check_files!(gui; now = t + 21, look) === :applied
        @test BeamletOptics.position(obj(gui, :L1)) ≈ [0.0, 0.13, 0.0] atol = 1e-15
        # A look without a stamp compares the times and sizes only
        @test GUI._check_files!(gui; now = t + 22, look = (; GUI._files_look(dir)..., stamp = nothing)) === :none
    end
    @testset "a look from before a save or of another folder is dropped" begin
        take!(t + 30)
        save_project(gui)
        @test take!(t + 30.1) === nothing
        @test !isnothing(take!(t + 30.2))
        wait(s.look.task)
        project = gui.project
        gui.project = mktempdir()
        @test GUI._take_look!(gui; now = t + 31) === nothing
        gui.project = project
        wait(s.look.task)
        s.look = nothing
    end
    @testset "the own presence file, written by the looks" begin
        withenv("BMO_PERSON" => "anna") do
            own = GUI._presence_file(dir, GUI._person().id)
            rm(own; force = true)
            s.presence_due = true
            take!(t + 40)
            wait(s.look.task)
            @test isfile(own)
            beat = GUI.TOML.parsefile(own)["beat"]
            # Not again until it is due: the selection changed or `_BEAT` passed
            take!(t + 40.1)
            wait(s.look.task)
            @test GUI.TOML.parsefile(own)["beat"] == beat
            take!(t + 40 + GUI._BEAT)
            wait(s.look.task)
            @test GUI.TOML.parsefile(own)["beat"] == beat + 1
            rm(own)
        end
    end
    close(gui)
end

end
