module TestLiveScripting

using GLMakie, BeamletOptics, BeamletOpticsGUI
using Makie
using GeometryBasics
using Test
using LinearAlgebra

const BMO = BeamletOptics
const GUI = BeamletOpticsGUI

# Object that can not be moved, see `kinematic_trait_of`
struct FixedMirror{T, S <: BMO.AbstractShape{T}} <: BMO.AbstractObject{T}
    shape::S
end
BMO.kinematic_trait_of(::FixedMirror) = BMO.Static()

@testset "Scripting the live view" begin
    # Rays along +y, the mirror at 45° reflects them along +x onto the detector
    function _fixture(; constraints = m -> Dict(), kwargs...)
        m = RoundPlanoMirror(25e-3, 5e-3)
        zrotate3d!(m, deg2rad(45))
        translate3d!(m, [0, 0.1, 0])
        pd = Detector(5e-3)
        zrotate3d!(pd, -π / 2)
        translate3d!(pd, [0.1, 0.1, 0])
        cs = CollimatedSource([0.0, 0, 0], [0.0, 1, 0], 2e-3, 1e-6; num_rings = 2, num_rays = 40)
        gui = live_view(System([m, pd]) => cs; trace_budget = Inf, throttle = false,
            catalog = CatalogEntry[], constraints = constraints(m), kwargs...)
        return gui, m, pd
    end

    _nhits(pd) = (h = BMO.hits(pd); isnothing(h) ? 0 : length(h))

    # Center of the drawing of `obj`
    function _center(gui, obj)
        bb = reduce(GeometryBasics.union,
            [Makie.boundingbox(p) for p in GUI._object_plots(gui.controls.h, obj)])
        return Vector{Float64}(minimum(bb) + GeometryBasics.widths(bb) / 2)
    end

    @testset "translate3d! redraws the object and solves" begin
        gui, m, pd = _fixture()
        @test _nhits(pd) > 0
        c0, P0 = _center(gui, m), Vector{Float64}(position(m))
        Δ = [0.05, 0.0, 0.01]
        # the object alone, without the window, does not redraw
        translate3d!(m, -Δ)
        translate3d!(m, Δ)
        @test _center(gui, m) ≈ c0

        translate3d!(gui, m, Δ)
        @test position(m) ≈ P0 + Δ
        @test _center(gui, m) ≈ c0 + Δ atol = 1e-5
        # the mirror is off the beam, the solve is up to date
        @test _nhits(pd) == 0
        @test gui.trace.stale == false

        # one undo entry restores the pose, the drawing and the solve
        @test length(gui.controls.undo_stack) == 1
        @test GUI._undo!(gui.controls)
        @test position(m) ≈ P0
        @test _center(gui, m) ≈ c0 atol = 1e-5
        @test _nhits(pd) > 0
        @test GUI._redo!(gui.controls)
        @test position(m) ≈ P0 + Δ
        close(gui)
    end

    @testset "translate_to3d! and rotate3d!" begin
        gui, m, pd = _fixture(; layout = :app)
        c0 = _center(gui, m)
        translate_to3d!(gui, m, [0.0, 0.1, 0.02])
        @test position(m) ≈ [0.0, 0.1, 0.02]
        @test _center(gui, m) ≈ c0 + [0, 0, 0.02] atol = 1e-5
        @test length(gui.controls.undo_stack) == 1

        R0 = Matrix{Float64}(BMO.orientation(m))
        rotate3d!(gui, m, [0.0, 0, 1], deg2rad(10))
        @test BMO.orientation(m) ≈ BMO.rotate3d([0.0, 0, 1], deg2rad(10)) * R0
        rotate3d!(gui, m, BMO.rotate3d([0.0, 0, 1], deg2rad(-10)))
        @test BMO.orientation(m) ≈ R0 atol = 1e-9
        @test length(gui.controls.undo_stack) == 3
        # nothing changed: no entry
        translate3d!(gui, m, zeros(3))
        @test length(gui.controls.undo_stack) == 3
        # a rotation matrix is applied as it is, also for a small angle
        R = BMO.rotate3d([0.0, 0, 1], 1e-6)
        rotate3d!(gui, m, R)
        @test BMO.orientation(m) ≈ R * R0 atol = 1e-14
        close(gui)
    end

    @testset "the selection box follows" begin
        gui, m, _ = _fixture()
        select!(gui, m)
        @test gui.controls.selected[] === m
        # like a click: the status line shows the pose
        @test gui.status.text[] == GUI._pose_string(gui, m)
        box0 = copy(gui.controls.box_obs[])
        translate3d!(gui, m, [0.0, 0.01, 0.0])
        @test gui.controls.box_obs[] ≈ box0 .+ Ref(Point3f(0, 0.01, 0))
        select!(gui, nothing)
        @test isnothing(gui.controls.selected[])
        @test isempty(gui.controls.box_obs[])
        close(gui)
    end

    @testset "constraints and static objects" begin
        gui, m, pd = _fixture(; constraints = m -> Dict(m => (; move = (:x,), rotate = (:v,))))
        P0 = Vector{Float64}(position(m))
        # projected onto the local x axis of the mirror, like a drag
        x = Vector{Float64}(BMO.orientation(m)[:, 1])
        translate3d!(gui, m, [0.01, 0.02, 0.03])
        @test position(m) ≈ P0 + dot(x, [0.01, 0.02, 0.03]) * x
        rotate3d!(gui, m, [0.0, 0, 1], 0.1)
        @test_throws ArgumentError rotate3d!(gui, m, [1.0, 0, 0], 0.1)
        # the same for a rotation matrix, by its axis
        rotate3d!(gui, m, BMO.rotate3d([0.0, 0, 1], -0.1))
        @test_throws ArgumentError rotate3d!(gui, m, BMO.rotate3d([1.0, 0, 0], 0.1))
        n = length(gui.controls.undo_stack)
        rotate3d!(gui, m, Matrix{Float64}(I, 3, 3))
        @test length(gui.controls.undo_stack) == n
        close(gui)

        m2 = RoundPlanoMirror(25e-3, 5e-3)
        gui2 = live_view(System([m2]) => Beam([0.0, -0.1, 0], [0.0, 1, 0], 1e-6);
            constraints = Dict(m2 => (; move = ())), catalog = CatalogEntry[])
        @test_throws ArgumentError translate3d!(gui2, m2, [0.01, 0, 0])
        close(gui2)

        fixed = FixedMirror(BMO.RoundPlanoMirror(25e-3, 5e-3).shape)
        gui3 = live_view(System([m2]) => Beam([0.0, -0.1, 0], [0.0, 1, 0], 1e-6);
            extras = [fixed], catalog = CatalogEntry[])
        @test_throws "static" translate3d!(gui3, fixed, [0.01, 0, 0])
        @test_throws "static" rotate3d!(gui3, fixed, [0.0, 0, 1], 0.1)
        @test_throws ArgumentError select!(gui3, FixedMirror(fixed.shape))  # not in the view
        @test isempty(gui3.controls.undo_stack)
        close(gui3)
    end

    @testset "spectator!" begin
        gui, m, _ = _fixture()
        select!(gui, m)
        spectator!(gui, true)
        @test gui.controls.spectator[]
        @test isnothing(gui.controls.selected[])
        @test_throws ArgumentError select!(gui, m)
        # still movable from code
        translate3d!(gui, m, [0.0, 0.001, 0.0])
        spectator!(gui, false)
        @test !gui.controls.spectator[]
        select!(gui, m)
        @test gui.controls.selected[] === m
        close(gui)
    end

    @testset "wait_solve" begin
        # deferred solves: every solve exceeds the budget
        gui, m, pd = _fixture(; trace_budget = 0.0, idle_delay = 100.0)
        translate3d!(gui, m, [0.05, 0, 0])
        translate3d!(gui, m, [0.0, 0, 0.001])
        @test gui.trace.pending || gui.trace.preview
        @test wait_solve(gui)
        @test !gui.trace.pending && !gui.trace.preview
        @test _nhits(pd) == 0
        close(gui)

        # a solve in the background, longer than progress_delay
        gui, m, pd = _fixture(; progress_delay = 0.0)
        translate3d!(gui, m, [0.05, 0, 0])
        @test wait_solve(gui; timeout = 60)
        @test isnothing(gui.trace.job)
        @test _nhits(pd) == 0
        translate3d!(gui, m, [-0.05, 0, 0])
        @test wait_solve(gui)
        @test _nhits(pd) > 0

        # a window on the same system: its solve in the background is waited for as well
        new = open_system(gui, first(gui.pairs).first; display = false)
        translate3d!(new, m, [0.05, 0, 0])
        @test !isnothing(new.trace.job) && gui.trace.stale
        @test wait_solve(gui; timeout = 60)
        @test isnothing(new.trace.job) && !gui.trace.stale && !new.trace.stale
        @test _nhits(pd) == 0
        close(new)
        close(gui)
    end
end

end # module
