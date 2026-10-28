module TestLiveProjectConflicts

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

system(dir) = joinpath(dir, "system.jl")
pos_line(dir, id) = only(l for l in split(read(system(dir), String), "\n") if startswith(l, "@component $id "))
obj(gui, id) = first(x for (x, (n, _)) in gui.sync.ids if n === id)
sync!(gui) = GUI._sync!(gui; animate = false)
function autosave!(gui)
    t = time()
    first = GUI._autosave!(gui; now = t)
    first === :saved && return first
    return GUI._autosave!(gui; now = t + 1)
end

"""Two windows (not shown) on one project, saved once by the first."""
function two_windows()
    dir = mktempdir()
    new_project(dir; name = "Bench")
    write(system(dir), START)
    a = open_project(dir; display = false, const_kw...)
    save_project(a)
    b = open_project(dir; display = false, const_kw...)
    return a, b, dir
end

@testset "a conflict holds only its own objects" begin
    a, b, dir = two_windows()
    # both move L1 differently; B saves first, A merges: a conflict on L1
    translate3d!(b, obj(b, :L1), [0.0, 0.0, 0.02])
    @test autosave!(b) === :saved
    translate3d!(a, obj(a, :L1), [0.0, 0.0, 0.01])
    @test sync!(a) === :conflict
    key = a.sync.ids[obj(a, :L1)][2]
    @test a.sync.conflicts == [key]
    card = GUI._info_card(a)
    @test card.obj isa GUI._ProjectConflict && card.obj.keys == [key] && card.obj.names == ["L1"]

    @testset "the rest is saved meanwhile, L1 keeps the files' state" begin
        translate3d!(a, obj(a, :M1), [0.0, 0.0, 0.03])
        @test autosave!(a) === :saved
        @test occursin("pos = (0.0, 0.2, 0.03)", pos_line(dir, "M1"))
        @test occursin("pos = (0.0, 0.1, 0.02)", pos_line(dir, "L1"))
        @test a.sync.conflicts == [key]
        # the other window takes the move of M1
        @test sync!(b) === :applied
        @test BeamletOptics.position(obj(b, :M1)) == [0.0, 0.2, 0.03]
        # the window keeps its own L1 until the person decides
        @test BeamletOptics.position(obj(a, :L1)) == [0.0, 0.1, 0.01]
    end

    @testset "a closed card does not come back after every action" begin
        GUI._release_info!(a, GUI._ProjectConflict)
        translate3d!(a, obj(a, :D1), [0.0, 0.0, 0.01])
        @test autosave!(a) === :saved
        @test isnothing(GUI._info_card(a))
        @test a.sync.conflicts == [key]
    end

    @testset "decided per object: mine is written" begin
        GUI._resolve_conflict!(a, :mine, [key])
        @test isempty(a.sync.conflicts)
        @test autosave!(a) === :saved
        @test occursin("pos = (0.0, 0.1, 0.01)", pos_line(dir, "L1"))
    end

    @testset "decided per object: theirs is taken" begin
        @test sync!(b) === :applied
        translate3d!(b, obj(b, :L1), [0.0, 0.0, 0.04])
        translate3d!(b, obj(b, :M1), [0.0, 0.0, 0.04])
        @test autosave!(b) === :saved
        translate3d!(a, obj(a, :L1), [0.0, 0.0, 0.05])
        translate3d!(a, obj(a, :M1), [0.0, 0.0, 0.05])
        @test sync!(a) === :conflict
        @test length(a.sync.conflicts) == 2
        kl = a.sync.ids[obj(a, :L1)][2]
        GUI._resolve_conflict!(a, :theirs, [kl])
        @test BeamletOptics.position(obj(a, :L1)) == [0.0, 0.1, 0.05]
        # the other stays open, its card shows it
        @test a.sync.conflicts == [a.sync.ids[obj(a, :M1)][2]]
        @test GUI._info_card(a).obj.names == ["M1"]
        GUI._resolve_conflict!(a, :mine)
        @test isempty(a.sync.conflicts)
        @test autosave!(a) === :saved
        @test occursin("pos = (0.0, 0.2, 0.08)", pos_line(dir, "M1"))
    end
    close(a)
    close(b)
end

const BMOP = BeamletOpticsProjects

"""Two looks of the watcher: the files changed, then settled."""
function tick!(gui)
    t = time()
    first = GUI._check_files!(gui; now = t)
    return first === :pending ? GUI._check_files!(gui; now = t + 1) : first
end

"""Replaces `a` by `b` in `system.jl` of `dir`, as an agent."""
edit!(dir, a, b) = write(system(dir), replace(read(system(dir), String), a => b))

"""The window as if shown: closing it saves and ends its session, see `_stop_watching!`."""
function watched!(gui)
    gui.sync.timer = Timer(3600)
    GUI._connect_session!(gui)
    return gui
end

"""A conflict on L1: B moved it by 0.02 and saved, A moved it by 0.01 and merged."""
function conflict_on_l1()
    a, b, dir = two_windows()
    translate3d!(b, obj(b, :L1), [0.0, 0.0, 0.02])
    @test autosave!(b) === :saved
    close(b)
    translate3d!(a, obj(a, :L1), [0.0, 0.0, 0.01])
    @test sync!(a) === :conflict
    return a, dir
end

@testset "a line claimed by another keeps the files' state, the rest is saved" begin
    a, b, dir = two_windows()
    close(b)
    l1, m1 = obj(a, :L1), obj(a, :M1)
    key = a.sync.ids[l1][2]
    # w1 claims L1 after the last read of the claims of the window, which moved it already
    @test BMOP.claim!(dir; by = "w1", ids = [:L1])
    translate3d!(a, l1, [0.0, 0.0, 0.01])
    translate3d!(a, m1, [0.0, 0.0, 0.01])
    @test isempty(GUI._claims(a).others)
    # the save refuses L1: the claims are read again and the rest is saved
    @test autosave!(a) === :saved
    @test haskey(GUI._claims(a).others, key)
    @test occursin("pos = (0.0, 0.1, 0.0)", pos_line(dir, "L1"))
    @test occursin("pos = (0.0, 0.2, 0.01)", pos_line(dir, "M1"))
    @test !any(l -> occursin("L1", l[2]), a.sync.journal)
    # with the claim known, the next change is saved at once; the window keeps its L1
    translate3d!(a, obj(a, :D1), [0.0, 0.0, 0.01])
    @test autosave!(a) === :saved
    @test occursin("pos = (0.0, 0.3, 0.01)", pos_line(dir, "D1"))
    @test occursin("pos = (0.0, 0.1, 0.0)", pos_line(dir, "L1"))
    @test BeamletOptics.position(l1) == [0.0, 0.1, 0.01]
    @test GUI._autosave!(a; now = time() + 10) === :none
    # released: the window writes its L1
    BMOP.release!(dir; by = "w1")
    @test !GUI._refresh_claims!(a, a.project) && isempty(GUI._claims(a).others)
    @test autosave!(a) === :saved
    @test occursin("pos = (0.0, 0.1, 0.01)", pos_line(dir, "L1"))

    @testset "the holder writes the line meanwhile: a conflict" begin
        @test BMOP.claim!(dir; by = "w1", ids = [:L1])
        @test GUI._refresh_claims!(a, a.project)
        translate3d!(a, l1, [0.0, 0.0, 0.01])
        @test GUI._autosave!(a; now = time() + 10) === :none
        edit!(dir, "pos = (0.0, 0.1, 0.01)", "pos = (0.0, 0.15, 0.01)")
        BMOP.release!(dir; by = "w1")
        GUI._refresh_claims!(a, a.project)
        @test tick!(a) === :conflict
        @test a.sync.conflicts == [key]
        @test BeamletOptics.position(l1) == [0.0, 0.1, 0.02]
    end
    close(a)
end

@testset "a system and a group made during a conflict keep their ids" begin
    a, dir = conflict_on_l1()
    m1, d1 = obj(a, :M1), obj(a, :D1)
    g = GUI._group!(a, GUI._MultiSelection(Any[m1, d1]))
    sys = add_system!(a; label = "Bench 2", select = false)
    @test autosave!(a) === :saved
    @test haskey(a.sync.ids, g) && haskey(a.sync.ids, sys)
    ids = (a.sync.ids[g], a.sync.ids[sys])
    text = read(system(dir), String)
    @test occursin(ids[1][2], text) && occursin(ids[2][2], text)
    # the next save writes the same ones
    translate3d!(a, obj(a, :B1), [0.0, 0.0, 0.01])
    @test autosave!(a) === :saved
    @test (a.sync.ids[g], a.sync.ids[sys]) == ids
    text = read(system(dir), String)
    @test occursin(ids[1][2], text) && occursin(ids[2][2], text)
    close(a)
end

@testset "the id of the files at a conflict stays theirs" begin
    a, b, dir = two_windows()
    close(b)
    l1 = obj(a, :L1)
    translate3d!(a, l1, [0.0, 0.0, 0.01])
    # an agent renames L1 to L2 and moves it: a conflict on its line
    edit!(dir, "@component L1 = ", "@component L2 = ")
    edit!(dir, "[L1, M1, D1]", "[L2, M1, D1]")
    edit!(dir, "pos = (0.0, 0.1, 0.0)", "pos = (0.0, 0.15, 0.0)")
    @test sync!(a) === :conflict
    # a new lens of the window does not take L2
    lens = SphericalLens(0.05, -0.05, 0.005, 0.0254, 1.5)
    add_component!(a, lens; system = only(GUI._systems(a)), select = false, code = LENS)
    translate3d!(a, lens, [0.0, 0.6, 0.0])
    @test autosave!(a) === :saved
    @test a.sync.ids[lens][1] !== :L2
    @test occursin("pos = (0.0, 0.15, 0.0)", pos_line(dir, "L2"))
    @test occursin("pos = (0.0, 0.6, 0.0)", pos_line(dir, String(a.sync.ids[lens][1])))
    close(a)
end

@testset "closed with an open conflict: the person's version in the backup" begin
    a, dir = conflict_on_l1()
    watched!(a)
    close(a)
    # the files keep their L1, the backup of the person has the window's
    @test occursin("pos = (0.0, 0.1, 0.02)", pos_line(dir, "L1"))
    backup = joinpath(dir, ".bmo", "window-backup-$(GUI._person().id).jl")
    @test isfile(backup)
    line = only(l for l in split(read(backup, String), "\n") if startswith(l, "@component L1 "))
    @test occursin("pos = (0.0, 0.1, 0.01)", line)
    # the session file stays and says so
    file = GUI._session_file(dir)
    @test isfile(file)
    text = read(file, String)
    @test occursin("The person's version of L1 is not in system.jl but in .bmo/window-backup-", text)

    @testset "without a conflict the session file goes" begin
        c = open_project(dir; display = false, const_kw...)
        watched!(c)
        translate3d!(c, obj(c, :M1), [0.0, 0.0, 0.01])
        rm(backup)
        close(c)
        @test !isfile(file) && !isfile(backup)
        @test occursin("pos = (0.0, 0.2, 0.01)", pos_line(dir, "M1"))
    end
end

end
