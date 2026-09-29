module TestAgentSkill

using BeamletOpticsGUI
using Test

const SKILL_DIR = joinpath(@__DIR__, "..", "skills", "beamletopticsgui")

@testset "Agent skill" begin
    @testset "API.md export table matches names(BeamletOpticsGUI)" begin
        api = read(joinpath(SKILL_DIR, "API.md"), String)
        table = split(split(api, "## Exported names")[2], "\n## ")[1]
        rows = filter(l -> startswith(l, "|") && !occursin(r"^\|\s*(Category|-)", l),
            split(table, '\n'))
        documented = Set{Symbol}()
        for row in rows, m in eachmatch(r"`([A-Za-z_][A-Za-z0-9_!]*)`", split(row, '|')[3])
            push!(documented, Symbol(m.captures[1]))
        end
        exported = Set(filter(!=(:BeamletOpticsGUI), names(BeamletOpticsGUI)))
        @test isempty(setdiff(documented, exported))  # documented but not exported
        @test isempty(setdiff(exported, documented))  # exported but not documented
    end

    @testset "SKILL.md targets the current minor version" begin
        skill = read(joinpath(SKILL_DIR, "SKILL.md"), String)
        m = match(r"beamletopticsgui-version:\s*\"(\d+)\.(\d+)\"", skill)
        @test m !== nothing
        v = pkgversion(BeamletOpticsGUI)
        @test parse.(Int, m.captures) == [v.major, v.minor]
    end

    @testset "install_agent_skill copies the shipped skill" begin
        mktempdir() do dest
            skill_md = joinpath(dest, "beamletopticsgui", "SKILL.md")
            original = read(joinpath(SKILL_DIR, "SKILL.md"), String)

            path = @test_logs (:info, r"Installed BeamletOpticsGUI agent skill") BeamletOpticsGUI.install_agent_skill(dest)
            @test path == joinpath(dest, "beamletopticsgui")
            @test read(skill_md, String) == original
            @test isfile(joinpath(path, "API.md"))
            @test isfile(joinpath(path, "WIDGETS.md"))

            # a reinstall replaces an edited, read-only copy (as left behind by a read-only Pkg install)
            write(skill_md, "edited")
            for (root, _, files) in walkdir(path)
                foreach(f -> chmod(joinpath(root, f), 0o444), files)
            end
            @test_logs (:info,) BeamletOpticsGUI.install_agent_skill(dest)
            @test read(skill_md, String) == original
            @test uperm(skill_md) & 0x02 != 0   # writable again
        end
    end
end

end
