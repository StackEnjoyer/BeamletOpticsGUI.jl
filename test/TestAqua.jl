module TestAqua

using Aqua, BeamletOpticsGUI
using Test

@testset "Aqua" begin
    Aqua.test_all(BeamletOpticsGUI)
end

end
