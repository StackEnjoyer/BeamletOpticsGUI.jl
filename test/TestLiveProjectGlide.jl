module TestLiveProjectGlide

using GLMakie, BeamletOptics, BeamletOpticsGUI
using BeamletOpticsProjects
using Makie
using LinearAlgebra: norm, cross, dot, tr
using Test

const BMO = BeamletOptics
const GUI = BeamletOpticsGUI
const const_kw = (; trace_budget = Inf, throttle = false, detectors = [])

const LENS = "SphericalLens(0.05, -0.05, 0.005, 0.0254, 1.5)"
const START = """
    @component L1 = $LENS pos = (0.0, 0.1, 0.0)
    @component M1 = RoundPlanoMirror(0.0254, 0.006) pos = (0.0, 0.2, 0.0)
    @component L2 = $LENS pos = (0.0, 0.3, 0.0)
    @component M2 = RoundPlanoMirror(0.0254, 0.006) pos = (0.0, 0.4, 0.0)
    @component D1 = Detector(0.02) pos = (0.0, 0.5, 0.0)
    @source B1 = Beam([0.0, 0.0, 0.0], [0.0, 1.0, 0.0], 1.0e-6)
    @system S1 = [L1, M1, L2, M2, D1] sources = [B1]
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

"""The object of the readable id `id` in the window."""
function obj(gui, id)
    for (x, (name, _)) in gui.sync.ids
        name === id && return x
    end
    return nothing
end

window_groups(gui) = Dict(gui.sync.ids[g][1] => g for g in keys(gui.components.groups) if haskey(gui.sync.ids, g))
pose(o) = (Vector{Float64}(BMO.position(o)), Matrix{Float64}(BMO.orientation(o)))
same_pose(a, b; tol = 1e-12) = norm(a[1] - b[1]) <= tol && norm(a[2] - b[2]) <= tol
rotation_angle(R) = acos(clamp((tr(R) - 1) / 2, -1.0, 1.0))

function group!(gui, ids...)
    select!(gui, Any[obj(gui, id) for id in ids])
    return GUI._group!(gui, gui.controls.selected[])
end

function autosave!(gui)
    t = time()
    first = GUI._autosave!(gui; now = t)
    first === :saved && return first
    return GUI._autosave!(gui; now = t + 1)
end

"""Waits (yielding to the glides) until `cond()` holds or `timeout` seconds passed."""
function wait_for(cond; timeout = 30.0, step = 0.002)
    t0 = time()
    while !cond()
        time() - t0 > timeout && return false
        sleep(step)
    end
    return true
end

moved(o, p0) = norm(Vector{Float64}(BMO.position(o)) - p0[1]) > 1e-9 || norm(Matrix{Float64}(BMO.orientation(o)) - p0[2]) > 1e-9

"""Moves the objects `ids` of the window `a` by different offsets, saves and merges in `b` with
the glides, waiting until they landed: a merge that the glides compiled once."""
function warm_up!(a, b, ids)
    for (i, id) in enumerate(ids)
        translate3d!(a, obj(a, id), [0.0, 0.0, 0.001 * i])
    end
    @test autosave!(a) === :saved
    @test GUI._sync!(b; animate = true) === :applied
    @test wait_for(() -> isempty(b.sync.gliding))
end

@testset "_rigid_motion" begin
    R = BMO.rotate3d([0.0, 0.0, 1.0], deg2rad(30))
    t = [0.1, -0.2, 0.3]
    p1, p2 = [0.0, 0.1, 0.0], [0.05, 0.2, -0.01]
    Q1, Q2 = BMO.rotate3d([1.0, 0.0, 0.0], 0.2), Matrix{Float64}(BMO.rotate3d([0.0, 1.0, 0.0], -0.4))
    moves = [(p1, Q1) => (R * p1 + t, R * Q1), (p2, Q2) => (R * p2 + t, R * Q2)]
    dR, t1 = GUI._rigid_motion(moves)
    @test maximum(abs, dR - R) < 1e-14
    @test norm(t1 - t) < 1e-14
    # another offset of one of them, or another rotation
    @test isnothing(GUI._rigid_motion([moves[1], (p2, Q2) => (R * p2 + t .+ [1e-6, 0, 0], R * Q2)]))
    @test isnothing(GUI._rigid_motion([moves[1], (p2, Q2) => (R * p2 + t, Q2)]))
    @test isnothing(GUI._rigid_motion(Pair[]))
end

@testset "The objects of one merge glide together" begin
    a, b, dir = two_windows()
    ids = (:L1, :M1, :L2, :M2, :D1)
    warm_up!(a, b, ids)
    for (i, id) in enumerate(ids)
        translate3d!(a, obj(a, id), [0.002 * i, 0.0, 0.0])
    end
    @test autosave!(a) === :saved
    starts = Dict(id => pose(obj(b, id)) for id in ids)
    targets = Dict(id => pose(obj(a, id)) for id in ids)
    t0 = time()
    @test GUI._sync!(b; animate = true) === :applied
    @test length(b.sync.gliding) == length(ids)
    # the first frame moves all of them, none has landed
    @test wait_for(() -> any(id -> moved(obj(b, id), starts[id]), ids))
    @test all(id -> moved(obj(b, id), starts[id]), ids)
    @test !any(id -> same_pose(pose(obj(b, id)), targets[id]), ids)
    @test wait_for(() -> isempty(b.sync.gliding))
    elapsed = time() - t0
    # one glide for all of them, not one after the other (5 * _GLIDE)
    @test elapsed < 3 * GUI._GLIDE
    for id in ids
        @test same_pose(pose(obj(b, id)), targets[id])
    end
    @test autosave!(b) === :none
    close(a)
    close(b)
end

@testset "A group moved and rotated rigidly glides as one" begin
    a, b, dir = two_windows()
    warm_up!(a, b, (:L1, :M1))
    ga = group!(a, :L1, :M1)
    @test autosave!(a) === :saved
    @test GUI._sync!(b; animate = false) === :applied
    gb = window_groups(b)[:G1]
    ga = window_groups(a)[:G1]
    # A turns the group by 90° about z and moves it
    translate3d!(a, ga, [0.01, 0.0, 0.02])
    a.controls.selected[] = ga
    rotate3d!(ga, BMO.rotate3d([0.0, 0.0, 1.0], deg2rad(90)))
    GUI._apply_update!(a.controls, ga)
    @test autosave!(a) === :saved
    P0, R0 = pose(gb)
    starts = Dict(id => pose(obj(b, id)) for id in (:L1, :M1))
    targets = Dict(id => pose(obj(a, id)) for id in (:L1, :M1))
    @test GUI._sync!(b; animate = true) === :applied
    @test wait_for(() -> haskey(b.sync.gliding, gb))
    # about half way: the members lie where the group carries them, on arcs about its pivot
    halfway() = deg2rad(30) < rotation_angle(pose(gb)[2] * R0') < deg2rad(60)
    @test wait_for(halfway)
    Pf, Rf = pose(gb)
    dR = Rf * R0'
    for id in (:L1, :M1)
        p0, Q0 = starts[id]
        p, Q = pose(obj(b, id))
        @test norm(p - (Pf + dR * (p0 - P0))) < 1e-9
        @test maximum(abs, Q - dR * Q0) < 1e-9
        # not on the straight line between start and end
        p1 = targets[id][1]
        d = p1 - p0
        @test norm(cross(p - p0, d)) / norm(d) > 1e-3
    end
    # the pivot glides on the line from the old one to the one of the files
    P1 = pose(ga)[1]
    @test norm(cross(Pf - P0, P1 - P0)) < 1e-9
    @test wait_for(() -> isempty(b.sync.gliding))
    @test same_pose(pose(gb), pose(ga))
    for id in (:L1, :M1)
        @test same_pose(pose(obj(b, id)), targets[id])
    end
    @test same_pose(b.components.groups[gb].poses[obj(b, :L1)], GUI._current_record(ga).poses[obj(a, :L1)]; tol = 1e-9)
    @test autosave!(b) === :none

    @testset "landed at once by a save" begin
        rotate3d!(ga, BMO.rotate3d([0.0, 0.0, 1.0], deg2rad(-45)))
        GUI._apply_update!(a.controls, ga)
        @test autosave!(a) === :saved
        @test GUI._sync!(b; animate = true) === :applied
        @test wait_for(() -> moved(obj(b, :L1), targets[:L1]))
        GUI._finish_glides!(b)
        @test isempty(b.sync.gliding)
        @test same_pose(pose(gb), pose(ga))
        for id in (:L1, :M1)
            @test same_pose(pose(obj(b, id)), pose(obj(a, id)))
        end
        # the stopped glide does not move them afterwards
        sleep(2 * GUI._GLIDE)
        @test same_pose(pose(gb), pose(ga))
        @test same_pose(pose(obj(b, :M1)), pose(obj(a, :M1)))
        @test autosave!(b) === :none
    end
    close(a)
    close(b)
end

@testset "A group whose members moved differently glides member by member" begin
    a, b, dir = two_windows()
    warm_up!(a, b, (:L1, :M1))
    group!(a, :L1, :M1)
    @test autosave!(a) === :saved
    @test GUI._sync!(b; animate = false) === :applied
    gb = window_groups(b)[:G1]
    P0, R0 = pose(gb)
    # an agent moves the members in the file, not the group
    text = system_text(dir)
    line(id) = only(filter(l -> occursin("@component $id ", l), split(text, '\n')))
    l1, m1 = line(:L1), line(:M1)
    text = replace(text, l1 => replace(l1, r"pos = \([^)]*\)" => "pos = (0.0, 0.1, 0.01)"),
        m1 => replace(m1, r"pos = \([^)]*\)" => "pos = (0.01, 0.2, 0.0)"))
    write(joinpath(dir, "system.jl"), text)
    starts = Dict(id => pose(obj(b, id)) for id in (:L1, :M1))
    @test GUI._sync!(b; animate = true) === :applied
    @test !haskey(b.sync.gliding, gb)
    @test wait_for(() -> moved(obj(b, :L1), starts[:L1]))
    # both glide on straight lines, the group stays
    @test moved(obj(b, :M1), starts[:M1])
    for (id, p1) in ((:L1, [0.0, 0.1, 0.01]), (:M1, [0.01, 0.2, 0.0]))
        p, p0 = pose(obj(b, id))[1], starts[id][1]
        d = p1 - p0
        @test norm(cross(p - p0, d)) < 1e-12
        @test 0 < dot(p - p0, d) < dot(d, d)
    end
    @test !haskey(b.sync.gliding, gb)
    @test same_pose(pose(gb), (P0, R0))
    @test wait_for(() -> isempty(b.sync.gliding))
    @test pose(obj(b, :L1))[1] == [0.0, 0.1, 0.01]
    @test pose(obj(b, :M1))[1] == [0.01, 0.2, 0.0]
    @test same_pose(pose(gb), (P0, R0))
    @test autosave!(b) === :none
    close(a)
    close(b)
end

end
