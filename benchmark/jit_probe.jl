# Measures the compilation that the first use of the mouse and key actions of a live view triggers,
# in a real (invisible) GLMakie window: the sessions that the workload of the GLMakie extension
# replays (ext/BeamletOpticsGUIGLMakieExt/session.jl), step by step. Run from the repository with
#
#   julia --project=test --trace-compile=stderr --trace-compile-timing benchmark/jit_probe.jl [layout] [scene] 2> trace.txt
#   julia benchmark/jit_trace_summary.jl trace.txt
#
# - `layout`: `compact` (default) or `app`
# - `scene`: `same` (default): the components of the workload, i.e. what is left to compile in the
#   best case; `other`: components of types that no workload has seen (lenses with own glasses), i.e.
#   what a script of a user pays; `catalog`: every entry of the catalog, placed, dragged and removed
#
# The environment variable `JIT_PROBE_ORDER` chooses the order in which the packages are loaded:
# `glmakie-first` (default, the less favorable one, e.g. of a startup file that loads GLMakie) or
# `gui-first`, the order of the documentation, in which the workload of the extension is built and
# in which Julia accepts most of its code.
#
# The table shows the time and the compile time of each step. Each step prints `### name` to
# stderr, such that the methods compiled by it follow in the trace.
const T_LOAD = @elapsed if get(ENV, "JIT_PROBE_ORDER", "glmakie-first") == "glmakie-first"
    @eval using GLMakie, BeamletOptics, BeamletOpticsGUI, Makie
else
    @eval using BeamletOptics, BeamletOpticsGUI, GLMakie, Makie
end

const EXT = Base.get_extension(BeamletOpticsGUI, :BeamletOpticsGUIGLMakieExt)
const LAYOUT = Symbol(get(ARGS, 1, "compact"))
const SCENE = get(ARGS, 2, "same")

Base.cumulative_compile_timing(true)
const ROWS = Tuple{String, Float64, Float64}[]

function step(@nospecialize(f), name)
    println(stderr, "### ", name)
    flush(stderr)
    c0 = Base.cumulative_compile_time_ns()[1]
    t0 = time_ns()
    r = try
        f()
    catch e
        println(stdout, "!! step '", name, "' failed: ", sprint(showerror, e))
        nothing
    end
    push!(ROWS, (name, (time_ns() - t0) / 1e6, (Base.cumulative_compile_time_ns()[1] - c0) / 1e6))
    return r
end

# Lenses with the glasses of a script, whose types are new to the compiler, and a point source
function other_fixture()
    mirror = SphericalLens(0.08, Inf, 4e-3, 25.4e-3, λ -> 1.6)
    zrotate3d!(mirror, deg2rad(45))
    translate3d!(mirror, [0, 0.1, 0])
    lens = SphericalDoubletLens(0.1, -0.05, -0.2, 4e-3, 2e-3, 25.4e-3, λ -> 1.5, λ -> 1.7)
    translate3d!(lens, [0, 0.05, 0])
    detector = Detector(5e-3)
    zrotate3d!(detector, -π / 2)
    translate3d!(detector, [0.1, 0.1, 0])
    beam = PointSource([0.0, 0, 0], [0.0, 1, 0], deg2rad(1), 1e-6; num_rings = 2, num_rays = 40)
    return EXT._Fixture(System([mirror, lens, detector]), mirror, lens, detector, beam)
end

gui, screen = if SCENE == "catalog"
    EXT._catalog_session(step)
else
    EXT._session(step, LAYOUT, SCENE == "other" ? other_fixture() : EXT._fixture())
end

println("\nlayout = ", LAYOUT, ", scene = ", SCENE)
println(rpad("step", 46), lpad("wall [ms]", 11), lpad("compile [ms]", 14))
println(rpad("using ...", 46), lpad(round(Int, 1e3 * T_LOAD), 11))
for (name, wall, comp) in ROWS
    println(rpad(name, 46), lpad(round(Int, wall), 11), lpad(round(Int, comp), 14))
end
println(rpad("sum (without using)", 46), lpad(round(Int, sum(r -> r[2], ROWS)), 11),
    lpad(round(Int, sum(r -> r[3], ROWS)), 14))
EXT._close!(gui, screen)
