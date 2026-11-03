module TestLivePoseAngles

using GLMakie, BeamletOptics, BeamletOpticsGUI
using LinearAlgebra: I, norm, det
using Random: MersenneTwister
using Test

const GUI = BeamletOpticsGUI

@testset "Euler angles of the pose card" begin
    rng = MersenneTwister(1)
    # Angles of random orientations, |ry| < 89.9°
    rand_angles(n) = [(π * (2rand(rng) - 1), deg2rad(89.9) * (2rand(rng) - 1), π * (2rand(rng) - 1))
                      for _ in 1:n]

    @testset "order $order" for order in GUI._EULER_ORDERS
        for a in rand_angles(1000)
            R = GUI._euler_matrix(a, order)
            @test norm(R' * R - I) < 1e-12 && det(R) ≈ 1
            b = GUI._euler_angles(R, order)
            @test maximum(abs.(b .- a)) < 1e-12
            @test norm(GUI._euler_matrix(b, order) - R) < 1e-12
        end
        # The identity and a quarter turn about z, the same in both orders
        @test all(iszero, GUI._euler_angles(Matrix{Float64}(I, 3, 3), order))
        @test all(GUI._euler_angles(GUI._euler_matrix((0, 0, π / 2), order), order) .≈ (0, 0, π / 2))
        # Ranges: rx and rz in (−π, π], also for a half turn
        @test GUI._euler_angles(GUI._euler_matrix((0, 0, π), order), order)[3] ≈ π
        @test GUI._euler_angles(GUI._euler_matrix((π, 0, 0), order), order)[1] ≈ π
        # Gimbal lock: rx is 0, the matrix is reproduced
        for ry in (π / 2, -π / 2), (rx, rz) in ((0.3, -1.1), (0.0, 2.0), (-2.5, 0.7))
            R = GUI._euler_matrix((rx, ry, rz), order)
            b = GUI._euler_angles(R, order)
            @test b[1] == 0
            @test b[2] ≈ ry
            @test norm(GUI._euler_matrix(b, order) - R) < 1e-12
        end
    end

    @testset "orders differ" begin
        a = (0.2, -0.4, 0.9)
        Rxyz = GUI._euler_matrix(a, :xyz)
        @test Rxyz ≈ GUI._euler_rz(0.9) * GUI._euler_ry(-0.4) * GUI._euler_rx(0.2)
        @test GUI._euler_matrix(a, :zyx) ≈ GUI._euler_rx(0.2) * GUI._euler_ry(-0.4) * GUI._euler_rz(0.9)
        @test norm(Rxyz - GUI._euler_matrix(a, :zyx)) > 0.1
        # The same orientation in the other order
        b = GUI._euler_angles(Rxyz, :zyx)
        @test GUI._euler_matrix(b, :zyx) ≈ Rxyz
        @test_throws ArgumentError GUI._euler_matrix(a, :xzy)
        @test_throws ArgumentError GUI._euler_angles(Rxyz, :yxz)
    end

    @testset "matches rotate3d" begin
        # A turn about the global z-axis shows in rz
        R = Matrix{Float64}(BeamletOptics.rotate3d([0, 0, 1], 0.25))
        @test all(GUI._euler_angles(R, :xyz) .≈ (0, 0, 0.25))
        R = Matrix{Float64}(BeamletOptics.rotate3d([1, 0, 0], -0.5))
        @test all(GUI._euler_angles(R, :zyx) .≈ (-0.5, 0, 0))
    end

    @testset "wrap" begin
        @test GUI._wrap_angle(π) == Float64(π)
        @test GUI._wrap_angle(-π) ≈ π
        @test GUI._wrap_angle(3π / 2) ≈ -π / 2
        @test GUI._wrap_angle(-0.1) == -0.1
    end
end

@testset "Relative poses" begin
    rng = MersenneTwister(2)
    for _ in 1:100
        Pref, P = randn(rng, 3), randn(rng, 3)
        Rref = GUI._euler_matrix(Tuple(randn(rng, 3)), :xyz)
        R = GUI._euler_matrix(Tuple(randn(rng, 3)), :zyx)
        Δp, Rrel = GUI._relative_pose(P, R, Pref, Rref)
        P2, R2 = GUI._absolute_pose(Δp, Rrel, Pref, Rref)
        @test norm(P2 - P) < 1e-12
        @test norm(R2 - R) < 1e-12
    end
    # The offset is measured along the axes of the reference
    Rref = GUI._euler_matrix((0, 0, π / 2), :xyz)
    Δp, Rrel = GUI._relative_pose([1.0, 2.0, 0.0], Rref, [1.0, 0.0, 0.0], Rref)
    @test Δp ≈ [2.0, 0.0, 0.0]
    @test Rrel ≈ I
    # A turn about the local x-axis of the reference shows in Δrx
    Δp, Rrel = GUI._relative_pose(zeros(3), Rref * GUI._euler_rx(1e-3), zeros(3), Rref)
    @test all(GUI._euler_angles(Rrel, :xyz) .≈ (1e-3, 0, 0))
end

@testset "Units of the pose card" begin
    u(units, key) = GUI._pose_unit(units, key)
    L, A = GUI._LENGTH_UNITS, GUI._ANGLE_UNITS
    @test [x.key for x in L] == [:mm, :um, :nm, :m]
    @test [x.key for x in A] == [:rad, :mrad, :urad, :deg, :arcmin, :arcsec]
    @test GUI._next_unit(L, :mm) == :um
    @test GUI._next_unit(L, :m) == :mm
    @test GUI._next_unit(A, :arcsec) == :rad
    @test_throws ArgumentError GUI._next_unit(A, :mm)
    @test_throws ArgumentError GUI._pose_unit(L, :rad)

    f = GUI._format_pose_value
    # The digits of each unit
    @test f(1.0, u(L, :m)) == "1.000000000"
    @test f(5e-3, u(L, :mm)) == "5.000000"
    @test f(-12.5e-6, u(L, :um)) == "-12.500"
    @test f(3e-9, u(L, :nm)) == "3.0"
    @test f(π / 2, u(A, :rad)) == "1.570796"
    @test f(1.25e-3, u(A, :mrad)) == "1.250"
    @test f(5e-6, u(A, :urad)) == "5.0"
    @test f(deg2rad(10), u(A, :deg)) == "10.0000"
    @test f(deg2rad(3 / 60), u(A, :arcmin)) == "3.000"
    @test f(deg2rad(20 / 3600), u(A, :arcsec)) == "20.0"
    # Signs: no minus for a value that rounds to zero, `+` for offsets
    @test f(-1e-15, u(A, :rad)) == "0.000000"
    @test f(0.0, u(A, :mrad); signed = true) == "+0.000"
    @test f(-3e-4, u(A, :mrad); signed = true) == "-0.300"
    @test f(12.5e-6, u(L, :um); signed = true) == "+12.500"
    @test f(0.5e-3, u(L, :mm)) == "0.500000"
    # Rounding carries into the integer part
    @test f(0.99999999, u(A, :rad)) == "1.000000"
end

@testset "Frame of the controls" begin
    lens = SphericalLens(0.05, -0.05, 0.01, 0.02)
    sys = System([lens])
    fig = Figure()
    ax = LScene(fig[1, 1])
    h = live_render!(ax, sys)
    ctrl = kinematic_controls!(ax, h)
    @test ctrl.frame[] == :global
    GUI._set_frame!(ctrl, :local)
    @test ctrl.frame[] == :local
    @test_throws ArgumentError GUI._set_frame!(ctrl, :table)
    @test kinematic_controls!(LScene(fig[1, 2]), live_render!(LScene(fig[1, 3]), sys);
        frame = :local).frame[] == :local
    @test_throws ArgumentError kinematic_controls!(ax, h; frame = :x)
    # Without constraints any move and rotation is allowed
    @test GUI._within_constraints(ctrl, lens, :move, [1.0, 2.0, 3.0])
    @test GUI._within_constraints(ctrl, lens, :rotate, [0.0, 0.0, 1.0])
end

end
