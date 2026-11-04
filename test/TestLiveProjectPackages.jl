module TestLiveProjectPackages

using GLMakie, BeamletOptics, BeamletOpticsGUI
using BeamletOpticsProjects
using Makie
using Test

const GUI = BeamletOpticsGUI
const TOML = GUI.TOML  # the TOML of the package, not a dependency of the tests
const const_kw = (; trace_budget = Inf, throttle = false, detectors = [])

const START = """
    @component L1 = SphericalLens(0.05, -0.05, 0.005, 0.0254, ConstantRefractiveIndex(1.5)) pos = (0.0, 0.1, 0.0)
    @source B1 = Beam([0.0, 0.0, 0.0], [0.0, 1.0, 0.0], 1.0e-6)
    @system S1 = [L1] sources = [B1]
    """

function opened()
    dir = mktempdir()
    new_project(dir; name = "Bench")
    write(joinpath(dir, "system.jl"), START)
    gui = open_project(dir; display = false, const_kw...)
    save_project(gui)
    return gui, dir
end

# Edits the Project.toml of the project in `dir` with `f(toml)`
function edit_project!(f, dir)
    file = joinpath(dir, "Project.toml")
    toml = TOML.parsefile(file)
    f(toml)
    open(io -> TOML.print(io, toml; sorted = true), file, "w")
    # a new time of change also on file systems with coarse times
    t = time() + 5
    Base.Filesystem.futime(Base.Filesystem.open(file, Base.Filesystem.JL_O_WRONLY), t, t) |> _ -> nothing
end

look(gui, dir, now) = GUI._check_packages!(gui, GUI._package_marks(dir); now)

@testset "The packages of the project of a window" begin
    gui, dir = opened()
    try
        st = GUI._package_state(gui)
        @test st.dir == dir && st.key == GUI._packages_key(dir)
        @test look(gui, dir, 100.0) === :none

        @testset "another part of Project.toml: no notice" begin
            edit_project!(t -> (t["version"] = "0.2.0"), dir)
            @test look(gui, dir, 200.0) === :pending
            @test look(gui, dir, 200.0 + GUI._SETTLE) === :none
            @test isnothing(GUI._info_card(gui))
        end

        @testset "a package added to the project: noticed once" begin
            edit_project!(t -> (t["deps"]["Dates"] = "ade2ca70-3891-5945-98fb-dc099432e06a"), dir)
            loaded = length(Base.loaded_modules)
            @test look(gui, dir, 300.0) === :pending
            @test look(gui, dir, 300.0 + GUI._SETTLE / 2) === :pending
            @test look(gui, dir, 300.0 + GUI._SETTLE) === :noticed
            @test gui.status.text[] == GUI._PACKAGE_NOTICE
            @test GUI._info_card(gui).obj isa GUI._PackageNotice
            # nothing is loaded, and the same state is not shown again
            @test length(Base.loaded_modules) == loaded
            GUI._release_info!(gui, GUI._PackageNotice)
            edit_project!(t -> (t["version"] = "0.3.0"), dir)
            @test look(gui, dir, 400.0) === :pending
            @test look(gui, dir, 400.0 + GUI._SETTLE) === :none
        end

        @testset "through the looks of the watcher, apart from the setup" begin
            stamp = gui.sync.stamp
            edit_project!(t -> (t["compat"]["Dates"] = "1"), dir)
            l = GUI._files_look(dir)
            @test l.packages == GUI._package_marks(dir)
            GUI._check_files!(gui; now = 500.0, look = l)
            GUI._check_files!(gui; now = 500.0 + GUI._SETTLE, look = l)
            @test gui.status.text[] == GUI._PACKAGE_NOTICE
            @test gui.sync.stamp == stamp
        end
    finally
        close(gui)
    end
end

@testset "No packages without a project" begin
    gui = live_view(BeamletOptics.System(); const_kw...)
    @test isnothing(GUI._package_state(gui))
    @test GUI._check_packages!(gui, Tuple{String, Float64, Int}[]) === :none
end

end
