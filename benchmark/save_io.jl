# The parts of an autosave after a change, on the local disk and over SMB, to find the file
# accesses that cost the thread of the window.
#
#     julia --project=test benchmark/save_io.jl <project folder on C:> [<folder on a drive>]
#
# Without the second folder, the copy of the project is measured on the local disk and through
# \\localhost\C$\...; with it, on the local disk and in a copy inside that folder (e.g. a folder on a
# shared drive), which is removed at the end.
using GLMakie, BeamletOptics, BeamletOpticsGUI, BeamletOpticsProjects
const G = BeamletOpticsGUI
const P = BeamletOpticsProjects

ms(t) = round(1000t; digits = 1)

copy_dir = joinpath(mktempdir(), basename(ARGS[1]))
cp(ARGS[1], copy_dir)
rm(joinpath(copy_dir, ".bmo"); force = true, recursive = true)
remote = if length(ARGS) >= 2
    d = joinpath(abspath(ARGS[2]), "save-io-" * gethostname(), basename(ARGS[1]))
    rm(dirname(d); recursive = true, force = true)
    mkpath(dirname(d))
    cp(copy_dir, d)
    d
else
    raw"\\localhost\C$" * copy_dir[3:end]
end
try
    for dir in (copy_dir, remote)
        t_open = @elapsed(gui = open_project(dir; display = false, trace_budget = Inf, throttle = false, detectors = []))
        obj = first(x for x in keys(gui.sync.ids) if haskey(gui.components.origin, x))
        times = Dict{String, Float64}()
        for i in 1:4
            G.translate3d!(gui, obj, [0.0, 0.0, 1e-4])
            t = Dict(
                "project_stamp" => @elapsed(P.project_stamp(dir)),
                "file_marks" => @elapsed(G._file_marks(dir)),
                "project_parts" => @elapsed(G._project_parts(gui, dir; name = gui.sync.base.name)),
                "save_project" => @elapsed(save_project(gui, dir)),
                "write_presence" => @elapsed(G._write_presence!(gui)),
                "write_session" => @elapsed(G._write_session!(gui)),
                "files_look" => @elapsed(G._files_look(dir; stamp = true, except = G._person().id, known = String[])),
                "claims" => @elapsed(P.claims(dir)),
            )
            i > 1 && mergewith!(+, times, t)
        end
        println(dir, "   (open_project ", ms(t_open), " ms, the first time compiles)")
        for (k, v) in sort(collect(times); by = last, rev = true)
            println("  ", rpad(k, 16), ms(v / 3), " ms")
        end
        close(gui)
    end
finally
    length(ARGS) >= 2 && rm(dirname(remote); recursive = true, force = true)
end
