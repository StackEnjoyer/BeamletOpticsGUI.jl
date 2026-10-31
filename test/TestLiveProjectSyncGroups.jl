module TestLiveProjectSyncGroups

using GLMakie, BeamletOptics, BeamletOpticsGUI
using BeamletOpticsProjects
using Makie
using LinearAlgebra: norm
using Test

const BMO = BeamletOptics
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

"""Two windows (not shown) on one project with `START`, saved once by the first."""
function two_windows()
    dir = mktempdir()
    new_project(dir; name = "Bench")
    write(joinpath(dir, "system.jl"), START)
    a = open_project(dir; display = false, const_kw...)
    save_project(a)
    b = open_project(dir; display = false, const_kw...)
    return a, b, dir
end

system_text(dir) = read(joinpath(dir, "system.jl"), String)
sync!(gui) = GUI._sync!(gui; animate = false)

"""The object of the readable id `id` in the window."""
function obj(gui, id)
    for (x, (name, _)) in gui.sync.ids
        name === id && return x
    end
    return nothing
end

"""The groups made in the window, by their readable ids."""
window_groups(gui) = Dict(gui.sync.ids[g][1] => g for g in keys(gui.components.groups) if haskey(gui.sync.ids, g))
member_ids(gui, g) = Set(gui.sync.ids[m][1] for m in BMO.objects(g))
top_ids(gui, sys) = Set(gui.sync.ids[o][1] for o in sys.objects if haskey(gui.sync.ids, o))
pose(o) = (Vector{Float64}(BMO.position(o)), Matrix{Float64}(BMO.orientation(o)))
same_pose(a, b; tol = 1e-12) = norm(a[1] - b[1]) <= tol && norm(a[2] - b[2]) <= tol

"""Groups the objects of the readable `ids` in the window `gui`, as `Ctrl+G` does."""
function group!(gui, ids...)
    select!(gui, Any[obj(gui, id) for id in ids])
    return GUI._group!(gui, gui.controls.selected[])
end

"""The autosave of the window: waits for the change to settle, then saves."""
function autosave!(gui)
    t = time()
    first = GUI._autosave!(gui; now = t)
    first === :saved && return first
    return GUI._autosave!(gui; now = t + 1)
end

@testset "Groups of the files in an open window" begin
    a, b, dir = two_windows()
    undo = length(b.controls.undo_stack)

    @testset "a group made in another window" begin
        group!(a, :L1, :M1)
        @test autosave!(a) === :saved
        @test occursin("@group G1 = [L1, M1]", system_text(dir))
        @test sync!(b) === :applied
        g = window_groups(b)[:G1]
        @test member_ids(b, g) == Set([:L1, :M1])
        @test top_ids(b, obj(b, :S1)) == Set([:G1, :D1])
        @test same_pose(pose(g), pose(window_groups(a)[:G1]))
        # the members are the objects the window had, no new ones
        @test any(x -> x === obj(b, :L1), BMO.objects(g))
        # nothing to save afterwards, no undo entries
        @test autosave!(b) === :none
        @test length(b.controls.undo_stack) == undo
        # the window can ungroup it
        @test GUI._is_window_group(b, g)
    end

    @testset "a group moved and rotated in another window" begin
        ga = window_groups(a)[:G1]
        translate3d!(a, ga, [0.0, 0.0, 0.01])
        a.controls.selected[] = ga
        rotate3d!(ga, BMO.rotate3d([0.0, 0.0, 1.0], deg2rad(10)))
        GUI._apply_update!(a.controls, ga)
        @test autosave!(a) === :saved
        gb = window_groups(b)[:G1]
        @test sync!(b) === :applied
        @test window_groups(b)[:G1] === gb
        @test same_pose(pose(gb), pose(ga))
        for id in (:L1, :M1)
            @test same_pose(pose(obj(b, id)), pose(obj(a, id)))
        end
        @test autosave!(b) === :none
    end

    @testset "a group made while this window moved another object" begin
        # B groups M1 and D1? no: B moves D1, A ungroups G1 and groups M1 with D1 meanwhile
        translate3d!(b, obj(b, :D1), [0.0, 0.0, 0.005])
        GUI._ungroup!(a, window_groups(a)[:G1])
        @test autosave!(a) === :saved
        @test sync!(b) === :applied
        @test isempty(window_groups(b))
        @test top_ids(b, obj(b, :S1)) == Set([:L1, :M1, :D1])
        # B saves its move, A takes it
        @test autosave!(b) === :saved
        @test sync!(a) === :applied
        @test same_pose(pose(obj(a, :D1)), pose(obj(b, :D1)))
    end

    @testset "a group inside a group" begin
        g1 = group!(a, :L1, :M1)
        @test autosave!(a) === :saved
        # the ids of removed groups stay taken, see `_project_ids`: the new one gets the next
        id1 = a.sync.ids[g1][1]
        g2 = group!(a, id1, :D1)
        @test autosave!(a) === :saved
        id2 = a.sync.ids[g2][1]
        text = system_text(dir)
        @test occursin("@group $id1 = [L1, M1]", text)
        @test occursin(Regex("@group $id2 = \\[($id1, D1|D1, $id1)\\]"), text)
        @test sync!(b) === :applied
        outer = window_groups(b)[id2]
        @test GUI._shown_top(b, outer)
        inner = window_groups(b)[id1]
        @test any(x -> x === inner, BMO.objects(outer))
        @test member_ids(b, inner) == Set([:L1, :M1])
        @test top_ids(b, obj(b, :S1)) == Set([b.sync.ids[outer][1]])
        @test autosave!(b) === :none
    end

    @testset "an agent adds a member to a group in the file" begin
        a2, b2, dir2 = two_windows()
        group!(a2, :L1, :M1)
        @test autosave!(a2) === :saved
        @test sync!(b2) === :applied
        text = system_text(dir2)
        text = replace(text, r"@group G1 = \[L1, M1\]" => "@group G1 = [L1, M1, D1]")
        text = replace(text, r"@system S1 = \[[^\]]*\]" => "@system S1 = [G1]")
        write(joinpath(dir2, "system.jl"), text)
        @test sync!(b2) === :applied
        @test member_ids(b2, window_groups(b2)[:G1]) == Set([:L1, :M1, :D1])
        @test top_ids(b2, obj(b2, :S1)) == Set([:G1])
        @test autosave!(b2) === :none
        # and removes the group again: the members are in the system
        text = replace(system_text(dir2), r"@group G1 = [^\n]*\n" => "")
        text = replace(text, r"@system S1 = \[G1\]" => "@system S1 = [L1, M1, D1]")
        write(joinpath(dir2, "system.jl"), text)
        @test sync!(b2) === :applied
        @test isempty(window_groups(b2))
        @test top_ids(b2, obj(b2, :S1)) == Set([:L1, :M1, :D1])
        close(a2)
        close(b2)
    end

    @testset "the same member grouped differently in both: a conflict" begin
        a3, b3, dir3 = two_windows()
        group!(b3, :L1, :D1)
        group!(a3, :L1, :M1)
        @test autosave!(a3) === :saved
        @test sync!(b3) === :conflict
        # the window keeps its own group, not saved yet (no id)
        @test member_ids(b3, only(keys(b3.components.groups))) == Set([:L1, :D1])
        close(a3)
        close(b3)
    end
    close(a)
    close(b)
end

@testset "Groups of the window in a merge, found in review" begin
    @testset "a group not saved yet survives a rebuild of its member" begin
        a, b, dir = two_windows()
        g = group!(b, :L1, :M1)
        @test !haskey(b.sync.ids, g)
        text = replace(system_text(dir), "SphericalLens(0.05, -0.05," => "SphericalLens(0.06, -0.05,")
        write(joinpath(dir, "system.jl"), text)
        @test sync!(b) === :applied
        g2 = only(keys(b.components.groups))
        @test member_ids(b, g2) == Set([:L1, :M1])
        @test BMO.objects(g2)[1] !== nothing && obj(b, :L1) !== nothing && any(x -> x === obj(b, :L1), BMO.objects(g2))
        # made again with the id it gets when it is saved
        @test any(x -> x === g2, obj(b, :S1).objects)
        @test top_ids(b, obj(b, :S1)) == Set([:D1, b.sync.ids[g2][1]])
        close(a)
        close(b)
    end

    @testset "Ctrl+R drops a group not saved yet" begin
        a, b, dir = two_windows()
        group!(b, :L1, :M1)
        GUI._load_from_disk!(b)
        @test isempty(b.components.groups)
        @test top_ids(b, obj(b, :S1)) == Set([:L1, :M1, :D1])
        close(a)
        close(b)
    end

    @testset "a member taken out of a group in the file leaves the system" begin
        a, b, dir = two_windows()
        group!(a, :L1, :M1)
        @test autosave!(a) === :saved
        @test sync!(b) === :applied
        write(joinpath(dir, "system.jl"), replace(system_text(dir), r"@group G1 = \[L1, M1\]" => "@group G1 = [L1]"))
        @test sync!(b) === :applied
        @test member_ids(b, window_groups(b)[:G1]) == Set([:L1])
        @test !any(x -> x === obj(b, :M1), obj(b, :S1).objects)
        @test autosave!(b) === :none
        close(a)
        close(b)
    end

    @testset "a group of one member: ungroup and undo" begin
        a, b, dir = two_windows()
        close(b)
        group!(a, :L1, :M1)
        @test autosave!(a) === :saved
        write(joinpath(dir, "system.jl"), replace(system_text(dir), r"@group G1 = \[L1, M1\]" => "@group G1 = [L1]",
            r"@system S1 = \[[^\]]*\]" => "@system S1 = [M1, D1, G1]"))
        c = open_project(dir; display = false, const_kw...)
        g = window_groups(c)[:G1]
        @test GUI._ungroup!(c, g)
        @test isempty(c.components.groups)
        GUI._undo!(c.controls)
        @test haskey(c.components.groups, g)
        close(a)
        close(c)
    end

    @testset "export_changes of a reopened project with a group" begin
        a, b, dir = two_windows()
        close(b)
        group!(a, :L1, :M1)
        @test autosave!(a) === :saved
        c = open_project(dir; display = false, const_kw...)
        @test occursin("# no changes", sprint(io -> export_changes(c; io)))
        close(a)
        close(c)
    end
end

end
