# What one look of the project watcher costs the thread of the window, on a local path and over
# SMB (the same folder as \\localhost\C$\...), before (all files read in the look) and now (read in
# the background, see `_take_look!`), and what an autosave after a change costs.
#
#     julia --project=<project> benchmark/watch_io.jl <project folder on C:>
#
# The folder is copied to a temporary one first; the copy is opened without a window.
using GLMakie, BeamletOptics, BeamletOpticsGUI, BeamletOpticsProjects
const G = BeamletOpticsGUI

ms(t) = round(1000t; digits = 1)

function measure(dir; n = 20)
    gui = open_project(dir; display = false, trace_budget = Inf, throttle = false, detectors = [])
    G._autosave!(gui)
    # Before: the look reads every file itself
    before() = (G._check_files!(gui); G._autosave!(gui); G._check_presence!(gui))
    # Now: the window takes what the background read
    function now()
        look = G._take_look!(gui)
        isnothing(look) || G._check_files!(gui; look)
        G._autosave!(gui)
        isnothing(look) || G._check_presence!(gui; look)
    end
    before(); now()
    t_before = @elapsed foreach(_ -> before(), 1:n)
    t_now = 0.0
    for _ in 1:n
        isnothing(gui.sync.look) || wait(gui.sync.look.task)
        t_now += @elapsed now()
    end
    t_autosave = @elapsed foreach(_ -> G._autosave!(gui), 1:n)
    obj = first(x for x in keys(gui.sync.ids) if haskey(gui.components.origin, x))
    save = 0.0
    for i in 1:3
        G.translate3d!(gui, obj, [0.0, 0.0, 1e-4])
        save = @elapsed G._autosave!(gui; force = true)
    end
    println(rpad(dir, 60), " look before: ", ms(t_before / n), " ms, now: ", ms(t_now / n),
        " ms (of which the autosave without a change: ", ms(t_autosave / n),
        " ms); autosave after a change: ", ms(save), " ms")
    close(gui)
end

copy_dir = joinpath(mktempdir(), basename(ARGS[1]))
cp(ARGS[1], copy_dir)
rm(joinpath(copy_dir, ".bmo"); force = true, recursive = true)
for _ in 1:2
    measure(copy_dir)
    measure(raw"\\localhost\C$" * copy_dir[3:end])
end
