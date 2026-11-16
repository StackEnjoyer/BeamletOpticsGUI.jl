# The lines of the package that each test file covers on its own, see "Running Julia and tests" in
# AGENTS.md.
#
#   julia --startup-file=no benchmark/test_coverage.jl map [jobs]       # all files: the map
#   julia --startup-file=no benchmark/test_coverage.jl check File ...   # the files again, lines lost
#
# Every test file runs in a Julia process of its own (`--project=test`, the preference of the
# workloads as the test environment has it) with an LCOV trace of `src/` and `ext/`. The results go
# to `COVERAGE_OUT` (default: a directory in `tempdir()`). `map` writes `<TestFile>.info` per file,
# `covered.txt` (every covered line with the files that cover it) and `only.txt` (the lines that
# only one file covers, with that file). `check` runs the given files again into `check/`
# (`COVERAGE_JOBS` at once, default 2) and prints every line that was covered before (by any file,
# see `covered.txt`) and is now covered neither by the given files nor by any other file of the
# map. The traces of the files that were not run again stand for those files.
const ROOT = normpath(joinpath(@__DIR__, ".."))
const OUT = get(ENV, "COVERAGE_OUT", joinpath(tempdir(), "BeamletOpticsGUI-test-coverage"))
const JULIA = joinpath(Sys.BINDIR, Base.julia_exename())

# `file:line` keys of the lines of `src/` and `ext/` that the LCOV trace `info` covers
function covered_lines(info::AbstractString)
    lines = Set{String}()
    isfile(info) || return lines
    sf = nothing
    for l in eachline(info)
        if startswith(l, "SF:")
            p = replace(normpath(l[4:end]), '\\' => '/')
            i = findfirst(r"/(src|ext)/", p)
            # the drive letter of ROOT and of the trace may differ in case (`c:` from Git Bash)
            sf = isnothing(i) || !startswith(lowercase(p), lowercase(replace(ROOT, '\\' => '/'))) ? nothing : p[(first(i) + 1):end]
        elseif startswith(l, "DA:") && !isnothing(sf)
            n, c = split(l[4:end], ',')[1:2]
            parse(Int, c) > 0 && push!(lines, "$sf:$n")
        elseif l == "end_of_record"
            sf = nothing
        end
    end
    return lines
end

# Runs the test file `name` with a trace into `dir`; returns its time [s]
function trace!(name::AbstractString, dir::AbstractString)
    info = joinpath(dir, "$name.info")
    rm(info; force = true)
    test = joinpath(ROOT, "test", "$name.jl")
    env = copy(ENV)
    env["JULIA_LOAD_PATH"] = "@" * (Sys.iswindows() ? ";" : ":") * joinpath(ROOT, "test") *
                            (Sys.iswindows() ? ";" : ":") * "@stdlib"
    cmd = `$JULIA --startup-file=no --project=$(joinpath(ROOT, "test")) --code-coverage=@$ROOT --code-coverage=$info $test`
    t = @elapsed ok = success(pipeline(setenv(cmd, env); stdout = joinpath(dir, "$name.log"), stderr = joinpath(dir, "$name.log"), append = false))
    ok || @warn "$name failed, see $(joinpath(dir, "$name.log"))"
    return t
end

# Runs the files `names` with at most `jobs` at once into `dir`; returns `name => seconds`
function trace_all!(names, dir; jobs::Int)
    mkpath(dir)
    times = Dict{String, Float64}()
    queue = Channel{String}(length(names))
    foreach(n -> put!(queue, n), names)
    close(queue)
    @sync for _ in 1:jobs
        @async for n in queue
            times[n] = trace!(n, dir)
            println(rpad(n, 36), lpad(round(times[n]; digits = 1), 8), " s")
            flush(stdout)
        end
    end
    return times
end

test_files() = sort([first(splitext(f)) for f in readdir(joinpath(ROOT, "test")) if occursin(r"^Test\w+\.jl$", f)])

function write_map(names)
    who = Dict{String, Vector{String}}()
    for n in names, l in covered_lines(joinpath(OUT, "$n.info"))
        push!(get!(who, l, String[]), n)
    end
    keys_sorted = sort(collect(keys(who)))
    open(joinpath(OUT, "covered.txt"), "w") do io
        foreach(l -> println(io, l, "\t", join(sort(who[l]), ",")), keys_sorted)
    end
    open(joinpath(OUT, "only.txt"), "w") do io
        foreach(l -> length(who[l]) == 1 && println(io, l, "\t", only(who[l])), keys_sorted)
    end
    println(length(keys_sorted), " lines covered, ", count(l -> length(who[l]) == 1, keys_sorted), " by one file only")
end

function check(names; jobs::Int = 2)
    covered = Dict{String, Vector{String}}()
    for l in eachline(joinpath(OUT, "covered.txt"))
        k, fs = split(l, '\t')
        covered[k] = split(fs, ',')
    end
    dir = joinpath(OUT, "check")
    trace_all!(names, dir; jobs = min(length(names), jobs))
    now = union(Set{String}(), (covered_lines(joinpath(dir, "$n.info")) for n in names)...)
    lost = String[]
    for (k, fs) in covered
        any(f -> !(f in names), fs) && continue   # another file covers it
        k in now || push!(lost, k)
    end
    sort!(lost)
    println(isempty(lost) ? "no line lost" : "$(length(lost)) lines lost:")
    foreach(println, lost)
    return lost
end

if abspath(PROGRAM_FILE) == @__FILE__
    mode = get(ARGS, 1, "map")
    if mode == "map"
        jobs = length(ARGS) > 1 ? parse(Int, ARGS[2]) : 6
        names = test_files()
        # the files of a run that was stopped keep their trace (a finished file has its summary)
        done(n) = isfile(joinpath(OUT, "$n.info")) && isfile(joinpath(OUT, "$n.log")) &&
                  occursin("Test Summary", read(joinpath(OUT, "$n.log"), String))
        times = trace_all!(filter(!done, names), OUT; jobs)
        open(joinpath(OUT, "times.txt"), "a") do io
            foreach(n -> println(io, n, "\t", round(times[n]; digits = 1)), keys(times))
        end
        write_map(names)
    elseif mode == "check"
        jobs = parse(Int, get(ENV, "COVERAGE_JOBS", "2"))
        check(String[first(splitext(basename(a))) for a in ARGS[2:end]]; jobs)
    else
        error("modes: map [jobs], check File ... (COVERAGE_JOBS=n for n at once)")
    end
end
