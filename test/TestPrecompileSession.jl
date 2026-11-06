module TestPrecompileSession

using GLMakie, BeamletOptics, BeamletOpticsGUI
using Test

# The workload of the GLMakie extension replays these sessions and swallows the error of a step,
# such that a step that fails would only lose its part of the precompilation. Here they must all
# run, in both layouts and for every entry of the catalog.
@testset "Precompile sessions" begin
    ext = Base.get_extension(BeamletOpticsGUI, :BeamletOpticsGUIGLMakieExt)
    @test ext isa Module

    failed = String[]
    names = String[]
    function step(@nospecialize(f), name)
        push!(names, name)
        try
            return f()
        catch e
            push!(failed, "$name: $(sprint(showerror, e))")
            return nothing
        end
    end

    @testset "session, $layout" for layout in (:compact, :app)
        empty!(failed)
        empty!(names)
        ext._close!(ext._session(step, layout)...)
        @test isempty(failed)
        @test "click mirror (select)" in names && "click beam (inspect)" in names
    end

    @testset "session with a Gaussian beamlet" begin
        empty!(failed)
        gauss = GaussianBeamlet([0.0, 0, 0], [0.0, 1, 0], 1e-6, 0.5e-3)
        ext._close!(ext._session(step, :compact, ext._fixture(gauss))...)
        @test isempty(failed)
    end

    @testset "catalog" begin
        empty!(failed)
        empty!(names)
        ext._close!(ext._catalog_session(step)...)
        @test isempty(failed)
        # each entry is placed, dragged and removed; one with a switch is also switched on its
        # page "Edit", e.g. the detector
        switched = count(e -> any(p -> p isa BeamletOpticsGUI.CatalogToggle, e.params), component_catalog())
        @test switched >= 1
        @test length(names) == 3 * length(component_catalog()) + switched
        @test any(n -> occursin("edit switch", n), names)
    end
end

end
