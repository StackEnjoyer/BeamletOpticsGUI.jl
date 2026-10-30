module TestLiveDebugPage

using GLMakie, BeamletOptics, BeamletOpticsGUI
using Makie
using Test

const BMO = BeamletOptics
const GUI = BeamletOpticsGUI

# A component with a row that fails, see `_debug_kind`
struct DebugPageBroken{T, S <: BMO.AbstractShape{T}} <: BMO.AbstractObject{T}
    shape::S
end
BMO.intersect3d(::DebugPageBroken, ::BMO.AbstractRay) = nothing
BMO.interact3d(::BMO.AbstractSystem, ::DebugPageBroken, ::BMO.AbstractBeam, ::BMO.AbstractRay) = nothing
GUI._debug_kind(::GUI.LiveView, ::DebugPageBroken) = Any[() -> error("broken row"), () -> ["fine" => "yes"]]

@testset "Live debug page" begin

    # Beam along +y, mirror at 45° reflects it along +x onto the detector; a lens beside them
    function _fixture()
        m = RoundPlanoMirror(25e-3, 5e-3)
        zrotate3d!(m, deg2rad(45))
        translate3d!(m, [0, 0.1, 0])
        pd = Detector(5e-3)
        zrotate3d!(pd, -π / 2)
        translate3d!(pd, [0.1, 0.1, 0])
        lens = SphericalLens(0.05, -0.05, 0.01, 0.02)
        translate3d!(lens, [0.0, 0.05, 0.0])
        return m, pd, lens
    end
    _gauss() = GaussianBeamlet([0.0, 0, 0], [0.0, 1, 0], 1e-6, 0.5e-3)
    _live_view(args...; kwargs...) = live_view(args...; merge((; trace_budget = Inf, detectors = []), kwargs)...)
    clock = Ref(0.0)
    _tick!(gui) = (clock[] += 1.0; events(gui.ax.scene).tick[] = Makie.Tick(Makie.RegularRenderTick, 0, clock[], 1.0))
    function _select!(gui, obj)
        gui.controls.selected[] = obj
        GUI._update_selection_box!(gui.controls)
        return nothing
    end
    _debug!(gui, on) = (GUI._set_debug!(gui, on); GUI._debug_pages_changed!(gui); nothing)
    _names(rows) = first.(rows)
    _value(rows, name) = last(rows[findfirst(r -> first(r) == name, rows)])

    @testset "the page exists only while the mode is on" begin
        m, pd, lens = _fixture()
        gui = _live_view(System([m, pd, lens]), _gauss())
        sys = only(GUI._systems(gui))
        for obj in (m, pd, lens, gui.pairs[1].second)
            @test !(:debug in GUI._card_pages(gui, obj))
        end
        _select!(gui, m)
        _tick!(gui)
        c = gui.cards.selection
        @test c.pages == (:pose, :properties)
        _debug!(gui, true)
        @test GUI._debug_on(gui)
        @test c.pages == (:pose, :properties, :debug)
        @test [b.label[] for b in c.bar.buttons] == ["Pose", "Properties", "Debug"]
        # a system has no page "Debug"
        @test !(:debug in GUI._card_pages(gui, sys))
        # the page shows the rows of the object
        GUI._set_page!(gui, c, :debug)
        @test c.page == :debug && c.bar.selected[] == :debug
        @test !isempty(c.list.rows)
        @test c.list.rows == GUI._debug_list_rows(gui, m)
        @test !any(r -> r[1] == "Error", c.list.rows)
        # the mode off: the card falls back to its default page
        _debug!(gui, false)
        @test c.pages == (:pose, :properties) && c.page == :pose
        @test c.bar.keys == [:pose, :properties]
        @test !(:debug in GUI._card_pages(gui, m))
        close(gui)
    end

    @testset "rows of a lens, a doublet, a group, a source, a beam group and a detector" begin
        m, pd, lens = _fixture()
        doublet = SphericalDoubletLens(40e-3, -30e-3, -120e-3, 6e-3, 2.5e-3, 25e-3, _ -> 1.62, _ -> 1.72)
        translate3d!(doublet, [0.0, 0.0, 0.1])
        l1 = SphericalLens(0.1, -0.1, 4e-3, 25.4e-3)
        l2 = SphericalLens(-0.1, 0.1, 2e-3, 25.4e-3)
        translate3d!(l1, [0.0, 0.0, -0.1])
        translate3d!(l2, [0.0, 0.0, -0.12])
        group = ObjectGroup([l1, l2])
        beam = _gauss()
        src = CollimatedSource([-0.1, 0.0, 0.0], [0.0, 1, 0], 2e-3, 532e-9; num_rings = 2, num_rays = 40)
        sys = System([m, pd, lens, doublet, group])
        gui = _live_view(sys => beam, sys => src)
        _debug!(gui, true)
        wait_solve(gui; timeout = 120)

        # every object
        for obj in (m, pd, lens, doublet, group, beam, src)
            rows = GUI._debug_rows(gui, obj)
            @test !("Error" in _names(rows))
            @test _value(rows, "id") == "0x" * string(objectid(obj); base = 16)
            @test length(_value(rows, "type")) <= 40
            @test endswith(_value(rows, "systems"), "movable")
            @test _value(rows, "systems") isa String
        end
        # an object: pose in six digits, three rows of the orientation, shapes, sphere
        rows = GUI._debug_rows(gui, lens)
        @test _names(rows) ⊇ ["position [m]", "orientation", "shapes", "sphere", "hits", "plots"]
        @test count(r -> r[1] == "orientation" || r[1] == "", rows) == 3
        @test occursin(r"^\(\+0\.000000, \+0\.050000, \+0\.000000\)$", _value(rows, "position [m]"))
        @test occursin(r"^[+-]\d\.\d{6}  [+-]\d\.\d{6}  [+-]\d\.\d{6}$", _value(rows, "orientation"))
        @test startswith(_value(rows, "sphere"), "r = ")
        @test occursin("rays", _value(rows, "hits"))
        # a doublet has several shapes
        rows = GUI._debug_rows(gui, doublet)
        @test occursin("×", _value(rows, "shapes")) || occursin(",", _value(rows, "shapes"))
        @test startswith(_value(rows, "sphere"), "r = ") && occursin("parts", _value(rows, "sphere"))
        # a group
        rows = GUI._debug_rows(gui, group)
        @test _value(rows, "objects") == "2"
        @test startswith(_value(rows, "main sphere"), "r = ")
        # the mirror was hit by the beam
        rows = GUI._debug_rows(gui, m)
        @test !startswith(_value(rows, "hits"), "0 ")
        # a source and a beam group
        rows = GUI._debug_rows(gui, beam)
        @test _names(rows) ⊇ ["beams", "rays", "segments", "max depth", "ends", "wavelength"]
        @test _value(rows, "beams") == "1"
        @test occursin("object", _value(rows, "ends"))
        @test occursin("nm", _value(rows, "wavelength"))
        rows = GUI._debug_rows(gui, src)
        @test parse(Int, _value(rows, "beams")) == length(BMO.beams(src))
        @test "min rays" in _names(rows)
        @test occursin("532", _value(rows, "wavelength"))
        # a detector
        rows = GUI._debug_rows(gui, pd)
        @test _names(rows) ⊇ ["hit type", "hit count", "view", "position [m]"]
        @test _value(rows, "hit count") == string(length(pd))
        # outdated beams are shown as such
        translate3d!(m, [0.0, 0.0, 0.001])
        GUI._mark_stale!(gui, m)
        @test GUI._beam_stale(gui, beam)
        @test _value(GUI._debug_rows(gui, beam), "state") == "outdated"
        @test endswith(_value(GUI._debug_rows(gui, m), "hits"), "(outdated)")
        close(gui)
    end

    @testset "a failing row does not break the card" begin
        m, pd, _ = _fixture()
        broken = DebugPageBroken(BMO.shape(RoundPlanoMirror(25e-3, 5e-3)))
        gui = _live_view(System([m, pd, broken]), _gauss())
        _debug!(gui, true)
        rows = GUI._debug_rows(gui, broken)
        @test ("Error" => "broken row") in rows
        @test _value(rows, "fine") == "yes"
        @test "type" in _names(rows)
        # the card shows it
        _select!(gui, broken)
        _tick!(gui)
        c = gui.cards.selection
        GUI._set_page!(gui, c, :debug)
        @test c.page == :debug && any(r -> r[1] == "Error", c.list.rows)
        close(gui)
    end

    @testset "the docked cards of the app layout" begin
        m, pd, _ = _fixture()
        gui = _live_view(System([m, pd]), _gauss(); layout = :app, throttle = false)
        card = gui.layout.inspector.card
        gui.controls.selected[] = m
        @test card.pages == (:pose, :properties)
        _debug!(gui, true)
        @test card.pages == (:pose, :properties, :debug)
        GUI._set_page!(gui, card, :debug)
        @test card.page == :debug && card.properties_part.shown && !card.rows_part.shown
        @test card.list.rows == GUI._debug_list_rows(gui, m)
        # the mode off: back to a page that exists
        _debug!(gui, false)
        @test card.pages == (:pose, :properties) && card.page in card.pages
        @test card.page != :debug
        close(gui)
    end
end

end
