# Whether a `FileWatching.FolderMonitor` on one machine sees the writes of another machine to a
# folder on a shared drive, how late, and how often an event is lost (D7 of the plan "projects-live":
# the watcher of a project polls every 0.2 s until this measurement says that the notifications can
# be relied on, see `_POLL_WITH_MONITOR` in `src/LiveProjectWatch.jl`).
#
# Start the watcher on machine B first, then the writer on machine A, with the same folder:
#
#     B>  julia benchmark/watch_notify.jl watch \\server\share\some\folder [timeout = 600]
#     A>  julia benchmark/watch_notify.jl write \\server\share\some\folder [n = 60] [rename|direct]
#
# The writer writes `watch-notify/probe.txt` in the folder every second, `n` times, with a counter
# and its clock, by default like the writers of a project (a temporary file, then `rename`), with
# `direct` in place. The watcher waits for the notifications of the folder `watch-notify` and
# polls the file every 0.05 s as well; it prints per write when the poll and the notification saw
# it, and at the end how many writes no notification announced (lost) and how late the others
# were. "late" is the time after the poll (the clocks of the two machines play no role); "clock" is
# the time after the writer's clock (includes the difference of the clocks). Both on one machine
# measure the local drive. Only the standard library is needed (no `--project`).
using FileWatching, Printf

const POLL = 0.05

median(x) = (s = sort(x); n = length(s); isodd(n) ? s[(n + 1) ÷ 2] : (s[n ÷ 2] + s[n ÷ 2 + 1]) / 2)

probe_dir(folder) = joinpath(folder, "watch-notify")
probe_file(folder) = joinpath(probe_dir(folder), "probe.txt")

function write_probes(folder; n = 60, mode = "rename")
    mkpath(probe_dir(folder))
    file = probe_file(folder)
    tmp = joinpath(probe_dir(folder), ".probe.$(getpid()).tmp")
    for k in 1:n
        text = "$k $(time())\n"
        if mode == "direct"
            write(file, text)
        else
            write(tmp, text)
            mv(tmp, file; force = true)
        end
        println("wrote $k")
        sleep(1.0)
    end
    write(file, "done $(time())\n")
    println("done")
end

# The counter and the writer's time in the probe file, `nothing` if it can not be read now
function read_probe(file)
    text = try
        read(file, String)
    catch
        return nothing
    end
    parts = split(strip(text))
    length(parts) == 2 || return nothing
    parts[1] == "done" && return (-1, parse(Float64, parts[2]))
    k = tryparse(Int, parts[1])
    t = tryparse(Float64, parts[2])
    (isnothing(k) || isnothing(t)) && return nothing
    return (k, t)
end

function watch_probes(folder; timeout = 600.0)
    mkpath(probe_dir(folder))
    file = probe_file(folder)
    # per counter: the writer's time, the time the poll saw it, the time a notification saw it
    written = Dict{Int, Float64}()
    polled = Dict{Int, Float64}()
    noted = Dict{Int, Float64}()
    events = Ref(0)
    finished = Ref(false)
    function see!(seen, p, t)
        (isnothing(p) || p[1] <= 0 || haskey(seen, p[1])) && return false
        seen[p[1]] = t
        written[p[1]] = p[2]
        return true
    end
    monitor = FolderMonitor(probe_dir(folder))
    listener = @async while true
        try
            wait(monitor)
        catch
            break
        end
        t = time()
        events[] += 1
        see!(noted, read_probe(file), t)
    end
    println("watching $(probe_dir(folder)); start the writer now")
    t0 = time()
    while time() - t0 < timeout
        t = time()
        p = read_probe(file)
        if !isnothing(p) && p[1] == -1 && haskey(written, 1)
            finished[] = true
            break
        end
        if see!(polled, p, t)
            k = p[1]
            @printf("write %3d  seen by the poll, clock %+7.1f ms\n", k, 1000 * (t - p[2]))
        end
        sleep(POLL)
    end
    sleep(1.0)
    close(monitor)
    wait(listener)
    finished[] || println("no end of the writer seen within $timeout s")
    ks = sort!(collect(keys(written)))
    isempty(ks) && return println("no write seen: is the writer writing to the same folder?")
    println()
    println("write   poll [clock ms]   notification [clock ms]   late after the poll [ms]")
    lates = Float64[]
    lost = Int[]
    for k in ks
        tw = written[k]
        tp = get(polled, k, NaN)
        tn = get(noted, k, NaN)
        isnan(tn) ? push!(lost, k) : (isnan(tp) || push!(lates, tn - tp))
        @printf("%5d   %15.1f   %23.1f   %24.1f\n", k, 1000 * (tp - tw), 1000 * (tn - tw), 1000 * (tn - tp))
    end
    println()
    println("writes seen: $(length(ks)), notifications: $(events[]), writes without a notification (lost): $(length(lost))",
        isempty(lost) ? "" : " ($(join(lost, ", ")))")
    if !isempty(lates)
        @printf("notification after the poll (negative: before), of %d writes: median %+.1f ms, max %+.1f ms\n",
            length(lates), 1000 * median(lates), 1000 * maximum(lates))
        println("(the poll sees a write up to $(Int(1000POLL)) ms late itself)")
    end
end

if length(ARGS) >= 2 && ARGS[1] == "write"
    write_probes(ARGS[2]; n = length(ARGS) >= 3 ? parse(Int, ARGS[3]) : 60,
        mode = length(ARGS) >= 4 ? ARGS[4] : "rename")
elseif length(ARGS) >= 2 && ARGS[1] == "watch"
    watch_probes(ARGS[2]; timeout = length(ARGS) >= 3 ? parse(Float64, ARGS[3]) : 600.0)
else
    println("usage: julia benchmark/watch_notify.jl watch <folder> [timeout = 600]\n" *
            "       julia benchmark/watch_notify.jl write <folder> [n = 60] [rename|direct]")
end
