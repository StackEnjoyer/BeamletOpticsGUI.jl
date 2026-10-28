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

end
