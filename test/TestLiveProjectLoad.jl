module TestLiveProjectLoad

# The watcher under load: files that keep changing, one solve per merge, notifications of the
# file system, see `LiveProjectWatch.jl`

using GLMakie, BeamletOptics, BeamletOpticsGUI
using BeamletOpticsProjects
using Test

const GUI = BeamletOpticsGUI

const LENS = "SphericalLens(0.05, -0.05, 0.005, 0.0254, 1.5)"
const START = """
    @component L1 = $LENS pos = (0.0, 0.1, 0.0)
    @component D1 = Detector(0.02) pos = (0.0, 0.3, 0.0)
    @source B1 = Beam([0.0, 0.0, 0.0], [0.0, 1.0, 0.0], 1.0e-6)
    @system S1 = [L1, D1] sources = [B1]
    @component M1 = $LENS pos = (0.1, 0.1, 0.0)
    @component D2 = Detector(0.02) pos = (0.1, 0.3, 0.0)
    @source B2 = Beam([0.1, 0.0, 0.0], [0.0, 1.0, 0.0], 1.0e-6)
    @system S2 = [M1, D2] sources = [B2]
    """

"""
A project with `START`, opened (not shown) and saved once, so that every line has a uid, and the
number of the solves since then (the `on_change` of the view is called once per full solve).
"""
function opened()
    dir = mktempdir()
    new_project(dir; name = "Bench")
    write(joinpath(dir, "system.jl"), START)
    solves = Ref(0)
    gui = open_project(dir; display = false, trace_budget = Inf, throttle = false, detectors = [],
        progress_delay = Inf, on_change = (_, _) -> (solves[] += 1))
    save_project(gui)
    solves[] = 0
    return gui, dir, solves
end

system(dir) = joinpath(dir, "system.jl")

"""Sets the position of the line of `id` in `system.jl` of `dir` to `pos`."""
function move!(dir, id, pos)
    lines = split(read(system(dir), String), "\n")
    i = findfirst(l -> startswith(l, "@component $id = "), lines)
    lines[i] = replace(lines[i], r"pos = \([^)]*\)" => "pos = ($(join(pos, ", ")))")
    write(system(dir), join(lines, "\n"))
    return nothing
end

"""The object of the readable id `id` in the window."""
function obj(gui, id)
    for (x, (name, _)) in gui.sync.ids
        name === id && return x
    end
    return nothing
end

"""Two looks of the watcher: the files changed, then settled."""
function tick!(gui)
    t = time()
    first = GUI._check_files!(gui; now = t)
    return first === :pending ? GUI._check_files!(gui; now = t + 1) : first
end

@testset "Files that keep changing" begin
    gui, dir, solves = opened()
    # The first merge compiles
    move!(dir, "L1", (0.0, 0.1, 0.001))
    @test tick!(gui) === :applied
    solves[] = 0
    # A look of the watcher every `_WATCH_INTERVAL`, a write every 0.1 s, for 10 s
    merges = Float64[]
    # the time from the first write after a merge to the next merge
    delays = Float64[]
    results = Symbol[]
    t0 = time()
    next_look = t0
    first_write = nothing
    i = 0
    while time() - t0 < 10
        i += 1
        y = 0.1 + 1e-4 * i
        move!(dir, "L1", (0.0, y, 0.0))
        isnothing(first_write) && (first_write = time())
        now = time()
        if now >= next_look
            r = GUI._check_files!(gui; now)
            push!(results, r)
            if r === :applied
                push!(merges, now)
                push!(delays, now - first_write)
                first_write = nothing
            end
            next_look = time() + GUI._WATCH_INTERVAL
        end
        sleep(0.1)
    end
    @info "files changed every 0.1 s for 10 s: $(length(merges)) merges, each $(round.(delays; digits = 2)) s after the first write since the last one"
    @test all(in((:pending, :applied)), results)
    @test length(merges) >= 4
    # A merge at the latest `_MERGE_EVERY` after the files began to change: the next look sees
    # the first write, the look after `_MERGE_EVERY` merges
    @test maximum(delays) <= GUI._MERGE_EVERY + 2 * GUI._WATCH_INTERVAL + 0.1
    # One solve per merge, each moved L1
    @test solves[] == length(merges)
    @test !gui.sync.adopting
    # Once the files are quiet, their last state is merged (unless the last look did)
    r = tick!(gui)
    @test r in (:applied, :none)
    @test BeamletOptics.position(obj(gui, :L1)) ≈ [0.0, 0.1 + 1e-4 * i, 0.0] atol = 1e-12
    @test solves[] == length(merges) + (r === :applied)
    close(gui)
end

@testset "One solve per merge" begin
    gui, dir, solves = opened()
    l1, m1 = obj(gui, :L1), obj(gui, :M1)

    @testset "a change of each of two systems solves twice outside of a merge" begin
        translate3d!(l1, [0.0, 0.0, 0.001])
        GUI._on_change!(gui, l1)
        translate3d!(m1, [0.0, 0.0, 0.001])
        GUI._on_change!(gui, m1)
        @test solves[] == 2
        translate3d!(l1, [0.0, 0.0, -0.001])
        translate3d!(m1, [0.0, 0.0, -0.001])
        save_project(gui)
        solves[] = 0
    end

    @testset "a merge that changes both systems solves once" begin
        move!(dir, "L1", (0.0, 0.11, 0.0))
        move!(dir, "M1", (0.1, 0.12, 0.0))
        write(system(dir), read(system(dir), String) * "@component T1 = $LENS pos = (0.0, 0.2, 0.0)\n")
        @test tick!(gui) === :applied
        @test BeamletOptics.position(l1) ≈ [0.0, 0.11, 0.0] atol = 1e-12
        @test BeamletOptics.position(m1) ≈ [0.1, 0.12, 0.0] atol = 1e-12
        @test !isnothing(obj(gui, :T1))
        @test solves[] == 1
        @test !gui.sync.adopting && !gui.trace.stale
    end

    @testset "the solve waits for the glides" begin
        solves[] = 0
        move!(dir, "L1", (0.0, 0.12, 0.0))
        move!(dir, "M1", (0.1, 0.13, 0.0))
        @test GUI._adopting(() -> GUI._sync!(gui; animate = true), gui) === :applied
        # The objects glide in a task of their own, one after the other
        @test gui.sync.adopting && !isempty(gui.sync.gliding)
        @test solves[] == 0
        t = time()
        stale = false
        while gui.sync.adopting && time() - t < 5
            sleep(0.02)
            # as on each frame of a shown window
            GUI._on_idle!(gui)
            # outdated while they glide
            stale |= gui.sync.adopting && gui.trace.stale && solves[] == 0
        end
        @test stale
        @test !gui.sync.adopting && isempty(gui.sync.gliding)
        @test BeamletOptics.position(l1) ≈ [0.0, 0.12, 0.0] atol = 1e-12
        @test BeamletOptics.position(m1) ≈ [0.1, 0.13, 0.0] atol = 1e-12
        @test solves[] == 1 && !gui.trace.stale
    end

    @testset "merges inside a merge solve once" begin
        solves[] = 0
        GUI._adopting(gui) do
            GUI._adopting(() -> GUI._on_change!(gui, l1), gui)
            @test gui.sync.adopting && solves[] == 0
            GUI._on_change!(gui, m1)
        end
        @test !gui.sync.adopting && solves[] == 1
        # Nothing changed: no solve
        GUI._adopting(() -> nothing, gui)
        @test solves[] == 1
    end
    close(gui)
end

@testset "Notifications of changes of the files" begin
    @testset "a monitor per folder, a write wakes the watcher up" begin
        dir = mktempdir()
        mkpath(joinpath(dir, "src"))
        n = GUI._file_notes(dir)
        @test length(n.monitors) == 2
        t = time()
        write(joinpath(dir, "system.jl"), "# changed\n")
        @test timedwait(() -> n.first > 0, 0.5; pollint = 0.01) === :ok
        @info "the notification of a write arrived after $(round(1000 * (n.first - t); digits = 1)) ms"
        # The project saved to another folder
        other = mktempdir()
        GUI._renew_notes!(n, other)
        @test n.dir == other && length(n.monitors) == 1
        n.first = 0.0
        write(joinpath(other, "system.jl"), "# changed\n")
        @test timedwait(() -> n.first > 0, 0.5; pollint = 0.01) === :ok
        GUI._close_notes!(n)
        @test isempty(n.monitors)
        @test isempty(GUI._file_notes(dir; notes = false).monitors)
    end

    @testset "a shown window sees a change of the files" begin
        # Within 0.5 s with notifications, although it polls only every 10 s; within two looks
        # without (the look that runs at the change read the files before it)
        for (notes, poll, within) in ((true, 10.0, 0.5), (false, 10.0, 2 * GUI._WATCH_INTERVAL + 0.1))
            gui, dir, _ = opened()
            screen = GLMakie.Screen(visible = false)
            display(screen, gui.fig)
            GUI._start_watching!(gui; notes, poll)
            n = gui.sync.monitor
            @test n isa GUI._FileNotes && isempty(n.monitors) == !notes
            # Its own presence file is written first, by a look
            @test timedwait(() -> !gui.sync.presence_due && !isnothing(gui.sync.look) &&
                                  istaskdone(gui.sync.look.task), 2.0; pollint = 0.01) === :ok
            sleep(0.5)
            marks = gui.sync.marks
            t = time()
            move!(dir, "L1", (0.0, 0.15, 0.0))
            @test timedwait(() -> gui.sync.marks != marks, 2.0; pollint = 0.005) === :ok
            seen = time() - t
            @info "a change of the files was seen after $(round(1000 * seen; digits = 1)) ms" notes
            @test seen <= within
            # and merged once it settled
            @test timedwait(() -> BeamletOptics.position(obj(gui, :L1)) ≈ [0.0, 0.15, 0.0], 3.0;
                pollint = 0.01) === :ok
            close(screen)
            close(gui)
            @test isnothing(gui.sync.monitor) && isempty(n.monitors)
        end
    end
end

end
