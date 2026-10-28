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
        # each entry is placed, dragged and removed
        @test length(names) == 3 * length(component_catalog())
    end

    @testset "project" begin
        empty!(failed)
        empty!(names)
        # the project lies in a repository, whose history the workload must not change: the
        # versions go into the repository of the project
        LibGit2 = BeamletOpticsGUI.BMOP.LibGit2
        outer = mktempdir()
        close(LibGit2.init(outer))
        dir = joinpath(outer, "project")
        gui, screen = ext._project_session(step; dir)
        @test isempty(failed)
        @test length(names) == 11
        @test LibGit2.with(LibGit2.isorphan, LibGit2.GitRepo(outer))
        @test LibGit2.with(r -> realpath(LibGit2.path(r)) == realpath(dir), LibGit2.GitRepoExt(dir))
        # the steps call the watcher themselves: none runs alongside them
        @test isnothing(gui.sync.timer) || !isopen(gui.sync.timer)
        ext._close!(gui, screen)
    end
end

end
