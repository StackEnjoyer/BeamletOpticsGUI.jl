module TestExports

# A script loads BeamletOptics, BeamletOpticsProjects and the GUI together: an exported name of two
# of them must be one thing, or Julia leaves it undefined in the script (e.g. `add_system!`, a
# function of the files of a project and a method of it for a window)

using BeamletOptics, BeamletOpticsProjects, BeamletOpticsGUI
using Test

const PACKAGES = (BeamletOptics, BeamletOpticsProjects, BeamletOpticsGUI)

@testset "the exports of the three packages name no two different things" begin
    for (i, a) in enumerate(PACKAGES), b in PACKAGES[(i + 1):end]
        common = [n for n in intersect(names(a), names(b)) if Base.isexported(a, n) && Base.isexported(b, n)]
        clashes = [n for n in common if getfield(a, n) !== getfield(b, n)]
        @test isempty(clashes)
    end
    # every exported name of the GUI is defined in a script that loads all three
    @test all(n -> isdefined(@__MODULE__, n), names(BeamletOpticsGUI))
    @test parentmodule(add_system!) === BeamletOpticsProjects
    @test hasmethod(add_system!, Tuple{BeamletOpticsGUI.LiveView})
end

end
