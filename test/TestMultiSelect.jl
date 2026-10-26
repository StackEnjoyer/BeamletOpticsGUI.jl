module TestMultiSelect

using GLMakie, BeamletOptics, BeamletOpticsGUI
using Test
using LinearAlgebra

const BMO = BeamletOptics
const GUI = BeamletOpticsGUI

@testset "Selections of several objects" begin
    function _fixture(; kwargs...)
        m1 = RoundPlanoMirror(25e-3, 5e-3)
        zrotate3d!(m1, deg2rad(45))
        translate3d!(m1, [0, 0.1, 0])
        m2 = RoundPlanoMirror(25e-3, 5e-3)
        translate3d!(m2, [0.1, 0.1, 0])
        pd = Detector(5e-3)
        translate3d!(pd, [0.1, 0.2, 0])
        cs = CollimatedSource([0.0, 0, 0], [0.0, 1, 0], 2e-3, 1e-6; num_rings = 2, num_rays = 40)
        gui = live_view(System([m1, m2, pd]) => cs; trace_budget = Inf, throttle = false,
            catalog = CatalogEntry[], kwargs...)
        return gui, m1, m2, pd
    end

    @testset "kinematics about the common center" begin
        m1, m2 = RoundPlanoMirror(25e-3, 5e-3), RoundPlanoMirror(25e-3, 5e-3)
        translate3d!(m1, [0.1, 0, 0])
        translate3d!(m2, [-0.1, 0, 0])
        s = GUI._MultiSelection([m1, m2])
        @test position(s) ≈ zeros(3)
        @test BMO.orientation(s) == Matrix(1.0I, 3, 3)
        translate3d!(s, [0, 0.05, 0])
        @test position(m1) ≈ [0.1, 0.05, 0] && position(m2) ≈ [-0.1, 0.05, 0]
        @test position(s) ≈ [0, 0.05, 0]
        R2 = Matrix{Float64}(BMO.orientation(m2))
        rotate3d!(s, [0.0, 0, 1], π / 2)
        @test position(m1) ≈ [0, 0.15, 0] atol = 1e-12
        @test position(m2) ≈ [0, -0.05, 0] atol = 1e-12
        @test BMO.orientation(m2) ≈ BMO.rotate3d([0.0, 0, 1], π / 2) * R2
        @test BMO.orientation(s) ≈ BMO.rotate3d([0.0, 0, 1], π / 2)
        # the pose of the selection is set like the one of an object, e.g. by the undo history
        P, R = GUI._pose(s)
        GUI._set_pose!(s, Point3(0.0, 0, 0), Matrix(1.0I, 3, 3))
        @test position(m1) ≈ [0.1, 0, 0] atol = 1e-12
        @test position(m2) ≈ [-0.1, 0, 0] atol = 1e-12
        @test_throws ArgumentError GUI._MultiSelection([m1])
    end

    @testset "no NaN by the undo of a move after many rotations" begin
        m1, m2 = RoundPlanoMirror(25e-3, 5e-3), RoundPlanoMirror(25e-3, 5e-3)
        translate3d!(m2, [0.1, 0, 0])
        s = GUI._MultiSelection([m1, m2])
        # the frame of many steps of a rotation drag differs from an orthonormal one by rounding
        # errors, `R * R'` of the undo of a move then is the identity up to them
        s.dir = (1 - 1e-13) * Matrix(1.0I, 3, 3)
        P = Vector{Float64}(position(m2))
        GUI._set_pose!(s, GUI._pose(s)...)
        @test position(m2) ≈ P && all(isfinite, BMO.orientation(m2))
        axis, angle = GUI._rotation_axis_angle((1 - 1e-13) * Matrix(1.0I, 3, 3))
        @test angle == 0 && all(isfinite, axis)
        for θ in (1e-9, 0.3, 2.0, π - 1e-7)
            a = normalize([0.2, -0.5, 1.0])
            axis, angle = GUI._rotation_axis_angle(BMO.rotate3d(a, θ))
            @test angle ≈ θ && isapprox(BMO.rotate3d(axis, angle), BMO.rotate3d(a, θ); atol = 1e-12)
        end
    end

    @testset "toggling objects" begin
        m1, m2, m3 = (RoundPlanoMirror(25e-3, 5e-3) for _ in 1:3)
        @test GUI._with_toggled(nothing, m1) === m1
        s = GUI._with_toggled(m1, m2)
        @test s isa GUI._MultiSelection && s.objects == Any[m1, m2]
        s3 = GUI._with_toggled(s, m3)
        @test s3.objects == Any[m1, m2, m3]
        # a new value, the old one keeps its objects
        @test s.objects == Any[m1, m2]
        @test GUI._with_toggled(s, m2) === m1
        @test GUI._with_toggled(m1, m1) === nothing
        @test GUI._selection_objects(nothing) == Any[]
        @test GUI._selection_objects(m1) == Any[m1]
        @test GUI._in_selection(s3, m2) && !GUI._in_selection(s, m3)
        @test GUI._without(s3, [m2]).objects == Any[m1, m3]
        @test GUI._without(s3, [m1, m2]) === m3
        @test GUI._without(s, [m3]) === s
        # a group replaces its parts and vice versa
        g = ObjectGroup([m2, m3])
        sg = GUI._with_toggled(GUI._MultiSelection([m1, m2]), g)
        @test sg.objects == Any[m1, g]
        @test GUI._with_toggled(sg, m3).objects == Any[m1, m3]
        # a clip plane is selected on its own
        plane = GUI.LiveClipPlane([0, 0, 0], [0, 1, 0], 0.1)
        @test GUI._with_toggled(s, plane) === plane
        @test GUI._with_toggled(plane, m1) === m1
    end

    @testset "select! of several objects" begin
        gui, m1, m2, pd = _fixture()
        select!(gui, [m1, m2])
        sel = gui.controls.selected[]
        @test sel isa GUI._MultiSelection && sel.objects == Any[m1, m2]
        @test !isempty(gui.controls.box_obs[])
        select!(gui, [m2])
        @test gui.controls.selected[] === m2
        select!(gui, Any[])
        @test isnothing(gui.controls.selected[])
        @test_throws ArgumentError select!(gui, [m1, RoundPlanoMirror(25e-3, 5e-3)])
        GUI._toggle_select!(gui, m1)
        GUI._toggle_select!(gui, pd)
        @test gui.controls.selected[].objects == Any[m1, pd]
        close(gui)
    end
end

end
