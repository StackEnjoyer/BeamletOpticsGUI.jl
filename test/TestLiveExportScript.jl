module TestLiveExportScript

using GLMakie, BeamletOptics, BeamletOpticsGUI
using Makie
using LinearAlgebra: norm, normalize
using Test

const BMO = BeamletOptics
const GUI = BeamletOpticsGUI

@testset "Live export of a script" begin

    # Each change is solved at once, see `TestLiveView.jl`; no card of a detector is pinned at start
    _live_view(args...; kwargs...) =
        live_view(args...; merge((; trace_budget = Inf, throttle = false, detectors = []), kwargs)...)

    _script(gui) = BeamletOpticsGUI.export_script(gui; io = devnull)

    # The part of the script before the live view, and the whole script
    function _setup(code)
        parts = split(code, "\n# Live view\n")
        @test length(parts) == 2
        return String(parts[1])
    end

    # Runs the `code` in a fresh module and returns the module
    function _run(code)
        mod = Module()
        include_string(mod, code)
        return mod
    end
    _value(mod, name) = Core.eval(mod, Symbol(name))

    function _same_pose(a, b; atol = 1e-12)
        (Pa, Ra), (Pb, Rb) = GUI._pose(a), GUI._pose(b)
        return norm(Pa - Pb) < atol && norm(Ra - Rb) < atol
    end
    # The same types and poses, also of the objects of groups, but not the same objects
    _same_objects(as, bs) = length(as) == length(bs) && all(zip(as, bs)) do (a, b)
        da, db = GUI._descendants(a), GUI._descendants(b)
        a !== b && length(da) == length(db) &&
            all(((x, y),) -> typeof(x) == typeof(y) && _same_pose(x, y), zip(da, db))
    end

    # A component or source of the catalog by the name of its entry, with the defaults of its form
    # or the `strings`; returns `(; obj, origin)`
    function _catalog(name, strings = nothing)
        entry = only(filter(e -> e.name == name, component_catalog()))
        defaults = String[GUI._catalog_string(p) for p in entry.params]
        return GUI._catalog_component(entry, something(strings, defaults))
    end
    # Adds a component of the catalog to the `gui`, turned and moved before it is added
    function _add!(gui, name; axis = [0.0, 0, 1], angle = 0.0, at = [0.0, 0, 0], strings = nothing, kwargs...)
        c = _catalog(name, strings)
        angle == 0 || rotate3d!(c.obj, normalize(axis), angle)
        translate_to3d!(c.obj, at)
        add_component!(gui, c.obj; origin = c.origin, select = false, kwargs...)
        return c.obj
    end
    _move!(gui, obj, v) = GUI._change!(() -> translate3d!(obj, v), gui.controls, obj)
    _turn!(gui, obj, axis, angle) = GUI._change!(() -> rotate3d!(obj, normalize(axis), angle), gui.controls, obj)

    _nrays(beam) = length(BMO.rays(beam))

    @testset "a view from the catalog, $layout" for layout in (:compact, :app)
        sys = System()
        gui = _live_view(sys; layout)
        # an empty view: a system, no source
        code = _script(gui)
        @test startswith(code, "# Script of the live view")
        @test occursin("\nusing BeamletOptics\n\nsystem = System()\n", code)
        @test occursin("\n# Live view\nusing GLMakie, BeamletOpticsGUI\ngui = live_view(\n    system\n)\n", code)
        @test !occursin("solve_system!", code)
        @test isempty(_value(_run(_setup(code)), :system).objects)

        # components: labelled with a variable name, with another label, without a label
        lens = _add!(gui, "Thin lens"; at = [0.0, 0.1, 0], label = "lens")
        mirror = _add!(gui, "Round mirror"; axis = [0.0, 0, 1], angle = deg2rad(45), at = [0.0, 0.2, 0],
            label = "the mirror")
        doublet = _add!(gui, "Doublet"; axis = [1.0, 2, 3], angle = 0.3, at = [0.1, 0.2, 0.01])
        plain = _add!(gui, "Singlet"; strings = ["80", "-80", "4", "25.4", "N-SF5"], label = "plain")
        # moved and turned in the view
        _move!(gui, lens, [1e-3, 0, -2e-3])
        _turn!(gui, lens, [1.0, 0, 0], 0.05)
        _turn!(gui, doublet, [0.0, 1, 1], -0.2)
        # sources: along the axis of the lens, and one that is turned and moved
        laser = _add!(gui, "Beam"; label = "laser")
        disc = _add!(gui, "Collimated source"; axis = [0.0, 0, 1], angle = 0.1, at = [0.02, -0.05, 0.0],
            label = "disc")
        _move!(gui, disc, [0.0, 0, 5e-3])
        @test length(gui.pairs) == 2 && all(o -> !isnothing(gui.components.origin[o]), sys.objects)

        code = _script(gui)
        setup = _setup(code)
        @test !occursin("live_view", setup) && !occursin("Makie", setup)
        # constructor, pose, system, sources, solves, in this order
        @test occursin("\n# lens ($(nameof(typeof(lens))))\nlens = ThinLens(", setup)
        @test occursin("\n# the mirror ($(nameof(typeof(mirror))))\nobj2 = RoundPlanoMirror(", setup)
        @test occursin("\n# $(nameof(typeof(doublet)))\nobj3 = SphericalDoubletLens(", setup)
        # in its pose as constructed: no pose lines
        @test occursin("\nplain = SphericalLens(", setup) && !occursin("(plain, [", setup)
        @test occursin("\nsystem = System([lens, obj2, obj3, plain])\n", setup)
        @test occursin("\n# laser (Beam)\nlaser = Beam([0.0, 0.0, 0.0], [0.0, 1.0, 0.0], ", setup)
        @test occursin("\ndisc = CollimatedSource(", setup)
        @test endswith(setup, "\nsolve_system!(system, laser)\nsolve_system!(system, disc)\n")
        order = [findfirst(s, setup).start for s in
            ("using BeamletOptics", "lens = ", "system = ", "laser = ", "solve_system!")]
        @test issorted(order)
        @test occursin("gui = live_view(\n    system => laser,\n    system => disc;\n    labels = Dict(\n" *
            "        lens => \"lens\",\n        obj2 => \"the mirror\",\n        plain => \"plain\",\n" *
            "        laser => \"laser\",\n        disc => \"disc\",\n    )\n)\n", code)

        # the script runs without the view and rebuilds the system and the sources
        mod = _run(setup)
        copy = _value(mod, :system)
        @test copy isa System && copy !== sys
        @test _same_objects(copy.objects, sys.objects)
        @test _value(mod, :lens) === copy.objects[1] && _value(mod, :plain) === copy.objects[4]
        for (name, src) in (:laser => laser, :disc => disc)
            c = _value(mod, name)
            @test typeof(c) == typeof(src) && c !== src
            @test _same_pose(c, src)
        end
        @test length(BMO.beams(_value(mod, :disc))) == length(BMO.beams(disc))
        # ... and traces them
        @test _nrays(laser) > 1 && _nrays(_value(mod, :laser)) == _nrays(laser)

        # removed components and sources are not part of the script
        remove_component!(gui, plain)
        remove_component!(gui, disc)
        code = _script(gui)
        @test !occursin("plain", code) && !occursin("disc", code)
        @test occursin("\nsystem = System([lens, obj2, obj3])\n", code)
        @test _same_objects(_value(_run(_setup(code)), :system).objects, sys.objects)

        # printed, and the tool of the view
        @test sprint(io -> BeamletOpticsGUI.export_script(gui; io)) == code
        gui.export_clipboard = false
        redirect_stdout(devnull) do
            GUI._export_script!(gui)
        end
        @test gui.status.text[] == "script exported"
        # the changes are exported as before
        changes, n = GUI._export_code(gui)
        @test n == 4 && occursin("push!(system, lens)", changes) && !occursin("live_view", changes)
        close(gui)
    end

    @testset "the whole script opens the view" begin
        gui = _live_view(System())
        lens = _add!(gui, "Thin lens"; at = [0.0, 0.1, 0], label = "lens")
        mirror = _add!(gui, "Round mirror"; at = [0.0, 0.2, 0])
        laser = _add!(gui, "Beam"; label = "laser")
        code = _script(gui)
        mod = _run(code)
        gui2 = _value(mod, :gui)
        @test gui2 isa GUI.LiveView
        sys2 = only(GUI._systems(gui2))
        @test sys2 === _value(mod, :system)
        @test _same_objects(sys2.objects, only(GUI._systems(gui)).objects)
        @test length(gui2.pairs) == 1 && only(gui2.pairs).second === _value(mod, :laser)
        @test gui2.labels[_value(mod, :lens)] == "lens" && gui2.labels[_value(mod, :laser)] == "laser"
        @test length(gui2.labels) == 2
        close(gui2)
        close(gui)
    end

    @testset "two systems" begin
        a, b = System(), System()
        gui = _live_view(a, b; labels = Dict(b => "bench"))
        lens = _add!(gui, "Thin lens"; at = [0.0, 0.1, 0], system = a, label = "lens")
        m1 = _add!(gui, "Square mirror"; angle = 0.4, at = [0.3, 0.1, 0], system = b, label = "m1")
        m2 = _add!(gui, "Round mirror"; axis = [1.0, 1, 0], angle = -0.2, at = [0.3, 0.2, 0], system = b)
        laser = _add!(gui, "Beam"; system = a, label = "laser")
        code = _script(gui)
        setup = _setup(code)
        @test occursin("\nsystem1 = System([lens])\n", setup)
        @test occursin("\nbench = System([m1, obj3])\n", setup)
        @test endswith(setup, "\nsolve_system!(system1, laser)\n")
        # a system without a source is an argument of its own
        @test occursin("gui = live_view(\n    system1 => laser,\n    bench;\n    labels = Dict(\n" *
            "        bench => \"bench\",\n", code)
        mod = _run(setup)
        @test _same_objects(_value(mod, :system1).objects, a.objects)
        @test _same_objects(_value(mod, :bench).objects, b.objects)
        @test _same_pose(_value(mod, :laser), laser)

        # a source of the other system
        gaussian = _add!(gui, "Gaussian beamlet"; at = [0.3, 0.0, 0], system = b, label = "gauss")
        code = _script(gui)
        @test count("gauss = GaussianBeamlet(", code) == 1
        @test occursin("\nsolve_system!(system1, laser)\nsolve_system!(bench, gauss)\n", code)
        @test occursin("    system1 => laser,\n    bench => gauss;\n", code)
        mod = _run(_setup(code))
        @test _same_pose(_value(mod, :gauss), gaussian)
        close(gui)
    end

    @testset "objects without an origin" begin
        m = RoundPlanoMirror(25e-3, 5e-3)
        zrotate3d!(m, deg2rad(45))
        translate3d!(m, [0, 0.1, 0])
        start = Beam([0.0, 0, 0], [0.0, 1, 0])
        sys = System([m])
        gui = _live_view(sys => start; labels = Dict(m => "m", start => "start"))
        lens = _add!(gui, "Thin lens"; at = [0.0, 0.05, 0], label = "lens")
        type = nameof(typeof(m))
        code = _script(gui)
        setup = _setup(code)
        # a comment with the type and the position; the lines that need the object are comments
        @test occursin("\n# m = … ($type) at [0.0, 0.1, 0.0], construct it here\n", setup)
        @test occursin("\nsystem = System([lens])\n# push!(system, m)\n", setup)
        @test occursin("\n# start = … (Beam) at [0.0, 0.0, 0.0], construct it here\n", setup)
        @test endswith(setup, "\n# solve_system!(system, start)\n")
        @test !occursin("translate_to3d!(m, ", setup)
        @test occursin("gui = live_view(\n    # system => start,\n    system;\n    labels = Dict(\n" *
            "        # m => \"m\",\n        lens => \"lens\",\n        # start => \"start\",\n    )\n)\n", code)
        # the script still runs, with the components that it knows
        mod = _run(setup)
        @test _same_objects(_value(mod, :system).objects, [lens])
        @test !isdefined(mod, :m) && !isdefined(mod, :start)

        # moved in the view: its change of pose since the view got it, as a comment
        _move!(gui, m, [0.01, 0, 0])
        _turn!(gui, m, [0.0, 0, 1], 0.1)
        setup = _setup(_script(gui))
        @test occursin("\n# m = … ($type) at [0.01, 0.1, 0.0], construct it here\n# rotate3d!(m, [", setup)
        @test occursin("\n# translate_to3d!(m, [0.01, 0.1, 0.0])\n", setup)
        @test !occursin("\nrotate3d!(m, ", setup) && !occursin("\ntranslate_to3d!(m, ", setup)
        @test _same_objects(_value(_run(setup), :system).objects, [lens])
        # uncommented and with the object as the view got it, the script reproduces its pose
        fresh = RoundPlanoMirror(25e-3, 5e-3)
        zrotate3d!(fresh, deg2rad(45))
        translate3d!(fresh, [0, 0.1, 0])
        lines = split(setup, "\n")
        i = findfirst(startswith("# m = …"), lines)
        lines[i] = "m = FRESH"
        for j in eachindex(lines)
            occursin("(m, ", lines[j]) || occursin(", m)", lines[j]) || continue
            lines[j] = replace(lines[j], r"^# " => "")
        end
        mod = Module()
        Core.eval(mod, :(FRESH = $fresh))
        include_string(mod, join(lines, "\n"))
        @test _value(mod, :system).objects[2] === fresh && _same_pose(fresh, m)

        # a removed component of the start is not part of the script
        remove_component!(gui, m)
        code = _script(gui)
        @test !occursin("(m, ", code) && !occursin("# m = ", code) && !occursin("\"m\"", code)
        @test occursin("\nsystem = System([lens])\n", code) && !occursin("push!", code)
        close(gui)

        # a static system can not get its objects afterwards: a comment, with all that needs it
        m1, m2 = RoundPlanoMirror(25e-3, 5e-3), RoundPlanoMirror(25e-3, 5e-3)
        translate3d!(m2, [0, 0.1, 0])
        static = StaticSystem([m1, m2])
        gui = _live_view(static => Beam([0.0, -0.1, 0], [0.0, 1, 0]); labels = Dict(m1 => "m1"))
        code = _script(gui)
        @test occursin("\n# system = StaticSystem([m1, obj2])\n", code)
        @test occursin("\n# solve_system!(system, obj3)\n", code)
        @test occursin("\n# gui = live_view(\n#     # system => obj3,\n#     # system,\n" *
            "#     labels = Dict(\n#         # m1 => \"m1\",\n#     )\n# )\n", code)
        _run(code)
        close(gui)

        # a source that is traced through two systems is constructed once and solved per pair
        a, b = System(), System()
        beam = Beam([0.0, 0, 0], [0.0, 1, 0])
        gui = _live_view(a => beam, b => beam; labels = Dict(beam => "beam"))
        code = _script(gui)
        @test count("# beam = … (Beam)", code) == 1
        @test occursin("\n# solve_system!(system1, beam)\n# solve_system!(system2, beam)\n", code)
        @test occursin("gui = live_view(\n    # system1 => beam,\n    system1,\n" *
            "    # system2 => beam,\n    system2;\n    labels = Dict(\n        # beam => \"beam\",\n    )\n)\n", code)
        mod = _run(_setup(code))
        @test isempty(_value(mod, :system1).objects) && isempty(_value(mod, :system2).objects)
        close(gui)
    end
end

end
