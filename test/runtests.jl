# Runs the files of this folder in a pool of worker processes, each file on its own and in any
# order. `--help` lists the options: `--jobs=N`, and names that select the files starting with
# them, e.g. `TestLiveCard`. A single file also runs on its own: `julia --project=test test/<file>.jl`
using BeamletOptics, BeamletOpticsGUI, GLMakie
using ParallelTestRunner

# The `using` above precompiled the packages, once, before the workers start. A worker keeps what it
# compiled for the next file. The windows of the tests stay hidden
init_worker_code = quote
    using BeamletOptics, BeamletOpticsGUI, GLMakie
    GLMakie.activate!(; visible = false)
end

runtests(BeamletOpticsGUI, ARGS; testsuite = find_tests(@__DIR__), init_worker_code,
    max_default_jobs = 8)
