module TestLiveProjectVersions

using GLMakie, BeamletOptics, BeamletOpticsGUI
using BeamletOpticsProjects
using Makie
using Test

const GUI = BeamletOpticsGUI
const BMOP = BeamletOpticsProjects
const TOML = GUI.TOML  # the TOML of the package, not a dependency of the tests
const const_kw = (; trace_budget = Inf, throttle = false, detectors = [])

const START = """
    @component L1 = SphericalLens(0.05, -0.05, 0.005, 0.0254, ConstantRefractiveIndex(1.5)) pos = (0.0, 0.1, 0.0)
    @source B1 = Beam([0.0, 0.0, 0.0], [0.0, 1.0, 0.0], 1.0e-6)
    @system S1 = [L1] sources = [B1]
    """

const BMO_VERSION = pkgversion(BeamletOptics)

"""
A project with `START` whose project file records the `versions` and `packages` in addition to
those of `new_project`.
"""
function project(; versions = Dict{String, String}(), packages = Dict{String, String}())
    dir = mktempdir()
    new_project(dir; name = "Bench")
    write(joinpath(dir, "system.jl"), START)
    file = BMOP.project_marker(dir)
    data = TOML.parsefile(file)
    merge!(get!(data, "versions", Dict{String, Any}()), versions)
    merge!(get!(data, "packages", Dict{String, Any}()), packages)
    open(io -> TOML.print(io, data), file, "w")
    return dir
end

# A version of BeamletOptics before the one here that is not compatible with it
breaking_below(v) = v.major >= 1 ? VersionNumber(v.major - 1, 0, 0) : VersionNumber(0, v.minor - 1, 0)

# A window without a project, from which a project is opened (not shown: neither is the new one)
window() = live_view(System(); const_kw...)

press!(gui, name) = (GUI._card_widget(GUI._versions_card(gui), name).clicks[] += 1; nothing)
card_texts(gui) = [GUI._card_widget(GUI._versions_card(gui), Symbol(:versions_, i)).text[]
                   for i in eachindex(GUI._versions_card(gui).obj.checks)]

@testset "Versions of a project" begin
    @test BMO_VERSION isa VersionNumber && (BMO_VERSION.major >= 1 || BMO_VERSION.minor >= 1)

    @testset "the same versions open silently" begin
        dir = project()
        @test all(c -> c.status === :same, GUI._version_checks(dir))
        gui = window()
        new = @test_logs min_level = Base.CoreLogging.Warn GUI._open_checked!(gui, dir)
        @test new isa GUI.LiveView && new.project == dir && gui.sync.closed
        @test isnothing(GUI._versions_card(gui))
        @test new.status.text[] == "project Bench opened from $dir"
        close(new)
    end

    @testset "newer compatible versions open silently" begin
        dir = project()
        gui = window()
        checks = [BMOP.VersionCheck("BeamletOptics", v"0.14.0", v"0.14.3", :newer)]
        new = GUI._open_checked!(gui, dir; checks)
        @test new isa GUI.LiveView && gui.sync.closed
        @test new.status.text[] == "project Bench opened from $dir"
        close(new)
    end

    @testset "newer versions that may break it open with a notice" begin
        old = breaking_below(BMO_VERSION)
        dir = project(; versions = Dict("BeamletOptics" => string(old)))
        @test first(GUI._version_checks(dir)).status === :breaking
        gui = window()
        # the window notes it, `open_project` does not warn again
        new = @test_logs min_level = Base.CoreLogging.Warn GUI._open_checked!(gui, dir)
        @test new isa GUI.LiveView && new.project == dir && gui.sync.closed
        @test isnothing(GUI._versions_card(gui))
        @test new.status.text[] == "project Bench opened from $dir; other versions: BeamletOptics " *
                                   "saved with $old, here $BMO_VERSION, which may break it"
        close(new)
    end

    @testset "an older version shows the card: Cancel" begin
        dir = project(; versions = Dict("BeamletOptics" => "99.0.0"))
        gui = window()
        @test isnothing(GUI._open_checked!(gui, dir))
        c = GUI._versions_card(gui)
        @test !isnothing(c) && !gui.sync.closed && isnothing(gui.project)
        @test only(c.obj.checks).status === :older && c.obj.path == dir
        @test card_texts(gui) == ["saved with 99.0.0, here $BMO_VERSION: ] up BeamletOptics"]
        @test gui.status.text[] == "project not opened yet: it needs other versions, see the card"
        press!(gui, :versions_cancel)
        @test isnothing(GUI._versions_card(gui))
        @test !gui.sync.closed && isnothing(gui.project)
        @test gui.status.text[] == "project not opened: $dir"
        close(gui)
    end

    @testset "an older version shows the card: Open anyway" begin
        dir = project(; versions = Dict("BeamletOptics" => "99.0.0"))
        gui = window()
        @test isnothing(GUI._open_checked!(gui, dir))
        @test !gui.sync.closed
        # opened in a task after the callback of the button, without a warning of `open_project`
        press!(gui, :versions_open)
        new = @test_logs min_level = Base.CoreLogging.Warn fetch(GUI._DIALOG_TASK[])
        @test new isa GUI.LiveView && new.project == dir && gui.sync.closed
        @test new.status.text[] == "project Bench opened from $dir; other versions: BeamletOptics " *
                                   "saved with 99.0.0, here $BMO_VERSION: ] up BeamletOptics"
        close(new)
    end

    @testset "a package that is not installed shows the card" begin
        dir = project(; packages = Dict("NotInstalledAnywhere" => "1.2.0"))
        checks = GUI._version_checks(dir)
        @test last(checks).package == "NotInstalledAnywhere" && last(checks).status === :missing
        gui = window()
        @test isnothing(GUI._open_checked!(gui, dir))
        @test card_texts(gui) == ["saved with 1.2.0, not installed here: ] add NotInstalledAnywhere"]
        press!(gui, :versions_cancel)
        @test isnothing(GUI._versions_card(gui)) && !gui.sync.closed
        close(gui)
    end

    @testset "a path that is no project: the error of opening it" begin
        dir = mktempdir()
        # nothing recorded: nothing to compare
        @test all(c -> c.status === :same, GUI._version_checks(dir))
        gui = window()
        @test isnothing(GUI._open_checked!(gui, dir))
        @test isnothing(GUI._versions_card(gui)) && !gui.sync.closed
        @test startswith(gui.status.text[], "project not opened: ")
        close(gui)
    end

    @testset "Ctrl+O opens through the check" begin
        dir = project(; versions = Dict("BeamletOptics" => "99.0.0"))
        dialog = GUI._OPEN_DIALOG[]
        GUI._OPEN_DIALOG[] = _ -> joinpath(dir, "Bench.bmo")
        try
            gui = window()
            GUI._open_key!(gui)
            @test isnothing(fetch(GUI._DIALOG_TASK[]))
            @test !isnothing(GUI._versions_card(gui)) && !gui.sync.closed
            close(gui)
        finally
            GUI._OPEN_DIALOG[] = dialog
        end
    end

    @testset "open_project warns" begin
        dir = project(; versions = Dict("BeamletOptics" => "99.0.0"),
            packages = Dict("NotInstalledAnywhere" => "1.2.0"))
        gui = @test_logs (:warn, r"saved with other versions:\nBeamletOptics: saved with 99\.0\.0, here .*: \] up BeamletOptics\nNotInstalledAnywhere: saved with 1\.2\.0, not installed here: \] add NotInstalledAnywhere") open_project(dir; display = false, const_kw...)
        @test gui.project == dir
        close(gui)
        same = project()
        gui = @test_logs min_level = Base.CoreLogging.Warn open_project(same; display = false, const_kw...)
        close(gui)
    end

    @testset "the versions of the others" begin
        dir = project()
        gui = open_project(dir; display = false, const_kw...)
        # the own presence file carries the versions of this session
        GUI._write_presence!(gui)
        mine = TOML.parsefile(GUI._presence_file(dir, GUI._person().id))["versions"]
        @test mine == Dict("BeamletOptics" => string(BMO_VERSION),
            "BeamletOpticsProjects" => string(pkgversion(BeamletOpticsProjects)),
            "BeamletOpticsGUI" => string(pkgversion(BeamletOpticsGUI)))
        @test mine == GUI._own_versions()

        function other!(id, name, beat, versions)
            file = GUI._presence_file(dir, id)
            mkpath(dirname(file))
            data = Dict{String, Any}("name" => name, "host" => "PC9", "beat" => beat, "selected" => "",
                "selected_id" => "", "written" => "", "versions" => versions)
            open(io -> TOML.print(io, data), file, "w")
            return file
        end
        v = string(VersionNumber(BMO_VERSION.major, BMO_VERSION.minor, BMO_VERSION.patch + 1))
        gui.status.text[] = "-"
        # the same versions, a package that this session does not have: no notice
        other!("Anna@pc2", "Anna", 1, Dict("BeamletOptics" => string(BMO_VERSION), "Unitful" => "1.0.0"))
        GUI._check_presence!(gui)
        @test gui.status.text[] == "-"
        # another version: one notice
        other!("Oliver@pc3", "Oliver", 1, Dict("BeamletOptics" => v))
        GUI._check_presence!(gui)
        @test gui.status.text[] == "Oliver: BeamletOptics $v, you: $BMO_VERSION"
        # ... once
        gui.status.text[] = "-"
        other!("Oliver@pc3", "Oliver", 2, Dict("BeamletOptics" => v))
        GUI._check_presence!(gui)
        @test gui.status.text[] == "-"
        # a participant that is not there any more (its `beat` did not change for its `ttl`) gives none
        t = time()
        other!("Bob@pc4", "Bob", 1, Dict("BeamletOptics" => string(BMO_VERSION)))
        GUI._check_presence!(gui; now = t)
        other!("Bob@pc4", "Bob", 1, Dict("BeamletOptics" => v))
        GUI._check_presence!(gui; now = t + 3600)
        @test gui.status.text[] == "-"
        # another difference of the same participant: a new notice, several in one line
        other!("Oliver@pc3", "Oliver", 3, Dict("BeamletOptics" => "0.0.1", "BeamletOpticsGUI" => "9.9.9"))
        GUI._check_presence!(gui; now = t + 3600)
        @test gui.status.text[] == "Oliver: BeamletOptics 0.0.1, you: $BMO_VERSION; " *
                                   "BeamletOpticsGUI 9.9.9, you: $(pkgversion(BeamletOpticsGUI))"
        close(gui)
    end
end

end
