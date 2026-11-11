# How long the file accesses of a project take on a drive: the accesses that the window does on its
# own thread (the autosave, the look of the watcher, the presence), one by one, without the GUI.
# Run it on each machine with a folder on the shared drive (and once with a folder on the local
# disk to compare); it writes only into `<folder>/drive-io-<host>`, which it removes at the end.
#
#     julia benchmark/drive_io.jl <folder> [n = 40]
#
# Prints per access the median and the maximum in ms. Only the standard library is needed.
using Printf

const DIR = joinpath(abspath(ARGS[1]), "drive-io-" * gethostname())
const N = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : 40

median(x) = (s = sort(x); n = length(s); isodd(n) ? s[(n + 1) ÷ 2] : (s[n ÷ 2] + s[n ÷ 2 + 1]) / 2)

function measure()
    rm(DIR; recursive = true, force = true)
    mkpath(joinpath(DIR, "sub"))
    text = repeat("@component L1 = SphericalLens(0.05, -0.05, 0.005, 0.0254, ConstantRefractiveIndex(1.5)) pos = (0.0, 0.1, 0.0)\n", 30)
    file = joinpath(DIR, "system.jl")
    write(file, text)
    for i in 1:10
        write(joinpath(DIR, "sub", "f$i.toml"), "x = $i\n")
    end
    ops = [
        "isfile" => () -> isfile(file),
        "mtime" => () -> mtime(file),
        "read 3 KB" => () -> read(file, String),
        "readdir (10 files)" => () -> readdir(joinpath(DIR, "sub")),
        "write in place" => () -> write(file, text),
        "write tmp + rename" => () -> (tmp = file * ".tmp"; write(tmp, text); mv(tmp, file; force = true)),
        "create + remove" => () -> (f = joinpath(DIR, "lock"); write(f, "x"); rm(f)),
        "mkdir + rmdir" => () -> (d = joinpath(DIR, "d"); mkdir(d); rm(d)),
    ]
    println("folder: ", DIR, ", ", N, " times each")
    for (name, f) in ops
        f()
        t = Float64[]
        for _ in 1:N
            push!(t, @elapsed f())
        end
        @printf("%-20s median %8.2f ms   max %8.2f ms\n", name, 1000 * median(t), 1000 * maximum(t))
    end
    rm(DIR; recursive = true, force = true)
end

measure()
