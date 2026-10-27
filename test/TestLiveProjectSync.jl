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

end
