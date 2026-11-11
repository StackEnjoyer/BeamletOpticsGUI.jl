# Two machines on one project in a shared folder: step 3 of the roadmap, without two people.
#
# Machine A and machine B each run this script with a visible window of the same project, which
# lies in the shared folder. The script acts like a person in the window: simulated mouse and key
# events (the same as GLFW sends them, as in the precompile session of the GLMakie extension), so
# that the claims and the autosave go the way of a real gesture. Between the steps, the two sides
# wait for each other through small files in `<folder>/coord`. Each side logs its steps to
# `<folder>/log-<role>.md` and saves a picture of its window after each step to `<folder>/screens`.
#
#     A>  julia --project=test benchmark/two_machines.jl A "H:\BMOP test env"
#     B>  julia --project=test benchmark/two_machines.jl B "H:\BMOP test env"
#
# `--no-notify` after the folder skips the measurement of the notifications (e.g. for a trial run of
# both roles on one machine, in a folder of `tempdir()`).
#
# A starts a run: it removes what an earlier run left (`coord`, `project`, `screens`, `results`,
# its log) and writes `coord/run.txt`. B joins the run of A, also when it started first. Both
# windows must stay visible and the mouse must stay off them while the run lasts.
#
# The script touches nothing outside the folder. If the folder can not be reached, or the other
# side halts, the script halts (exit code 2) with a line that starts with "HALT".
#
# The steps: preflight (versions, clock against the drive), the notifications of the drive both
# ways (`watch_notify.jl`), presence, a drag of each side seen by the other, the claims (refused
# gesture, lock, release, expiry after 30 s), edits of both at the same time on different objects
# and on the same object, an agent's edit through BeamletOpticsProjects, a group, versions of both,
# leaving, and the final comparison of both windows and the files.
const ROLE = uppercase(get(ARGS, 1, ""))
ROLE in ("A", "B") || error("usage: julia --project=test benchmark/two_machines.jl A|B <folder>")
const ROOT = abspath(ARGS[2])
const OTHER = ROLE == "A" ? "B" : "A"
const NAMES = Dict("A" => "Alice", "B" => "Bob")
const ME, THEM = NAMES[ROLE], NAMES[OTHER]
# The person of this window for the claims and the presence: both machines may run under the same
# user name, which would make them one person
ENV["BMO_PERSON"] = ME

using Dates, Printf, Pkg
using BeamletOptics, BeamletOpticsGUI, BeamletOpticsProjects, GLMakie
using Makie

const GUI = BeamletOpticsGUI
const BMOP = BeamletOpticsProjects
const LibGit2 = BMOP.LibGit2

const COORD = joinpath(ROOT, "coord")
const PROJ = joinpath(ROOT, "project", "Bench")
const SHOTS = joinpath(ROOT, "screens")
const RESULTS = joinpath(ROOT, "results")
const LOGF = joinpath(ROOT, "log-$ROLE.md")
const STEP = Ref(0)
const RUN = Ref("")
const FAILS = String[]
const WINDOW = Ref{Any}(nothing)

#=
Halting, logging
=#

struct Halt <: Exception
    msg::String
end

reachable() = try
    isdir(ROOT)
catch
    false
end

function reach()
    reachable() || throw(Halt("the shared folder $ROOT can not be reached"))
    return nothing
end

stamp() = Dates.format(now(), "HH:MM:SS.sss")

function logline(step, result, details = "")
    line = "| $(stamp()) | $step | $result | $(replace(string(details), '|' => '/', '\n' => ' ')) |"
    println(line)
    reach()
    open(io -> println(io, line), LOGF, "a")
    return nothing
end

step!(name) = (STEP[] += 1; logline("**$(STEP[]) $name**", "start"))

"""Records a check: `ok` or `FAIL`, and continues the run."""
function check(ok::Bool, what, details = "")
    ok || push!(FAILS, "step $(STEP[]): $what")
    logline("  $what", ok ? "ok" : "FAIL", details)
    return ok
end

info(what, details = "") = logline("  $what", "info", details)

#=
Files of the coordination: `coord/<run>-<role>-<name>`, written once, read by the other side
=#

cfile(role, name) = joinpath(COORD, "$(RUN[])-$role-$name")

function signal(name; data...)
    reach()
    text = join(["$k=$v" for (k, v) in pairs(data)], "\n")
    tmp = cfile(ROLE, name) * ".tmp"
    write(tmp, "t=$(time())\n" * text * "\n")
    mv(tmp, cfile(ROLE, name); force = true)
    return nothing
end

function readsignal(file)
    d = Dict{String, String}()
    for l in eachline(file)
        occursin('=', l) || continue
        k, v = split(l, '='; limit = 2)
        d[k] = v
    end
    return d
end

"""Waits for the signal `name` of the other side; halts when it halts or the folder is gone."""
function await(name; timeout = 600.0)
    t0 = time()
    file = cfile(OTHER, name)
    last_touch = time()
    while true
        reach()
        isfile(file) && return readsignal(file)
        isfile(cfile(OTHER, "HALT")) && throw(Halt("machine $OTHER halted: " * read(cfile(OTHER, "HALT"), String)))
        run_now = try
            strip(read(joinpath(COORD, "run.txt"), String))
        catch
            ""
        end
        run_now == RUN[] || throw(Halt("the run $(RUN[]) is gone (another run started: \"$run_now\")"))
        # A keeps its run fresh for a B that starts later
        if ROLE == "A" && time() - last_touch > 20
            touch(joinpath(COORD, "run.txt"))
            last_touch = time()
        end
        time() - t0 > timeout && throw(Halt("machine $OTHER did not reach \"$name\" within $(round(Int, timeout)) s"))
        sleep(0.2)
    end
end

barrier(name; timeout = 600.0) = (signal(name); await(name; timeout))

"""Waits until `f()` is true, at most `timeout` s; returns the time it took or `nothing`."""
function until(f; timeout = 30.0, every = 0.05)
    t0 = time()
    while time() - t0 < timeout
        ok = try
            f()
        catch e
            e isa InterruptException && rethrow()
            false
        end
        ok && return time() - t0
        sleep(every)
    end
    return nothing
end

fmt(x::Nothing) = "never"
fmt(x::Real) = @sprintf("%.2f s", x)

#=
The window: objects, poses, simulated events
=#

function obj(gui, id::Symbol)
    for (o, (i, _)) in gui.sync.ids
        i === id && return o
    end
    error("no object $id in the window")
end

wpos(o) = Vector{Float64}(BeamletOptics.position(o))
wpos(gui, id::Symbol) = wpos(obj(gui, id))

"""The position of `id` in the files, `nothing` while they can not be read."""
function fpos(id::Symbol)
    try
        return collect(Float64, BMOP.pose(BMOP.load_project(PROJ), id).pos)
    catch e
        e isa InterruptException && rethrow()
        return nothing
    end
end

near(a, b; atol = 1e-6) = !isnothing(a) && !isnothing(b) && isapprox(a, b; atol)
vec3(s) = parse.(Float64, split(strip(s, ['[', ']']), ","))
show3(v) = isnothing(v) ? "nothing" : "[" * join((@sprintf("%.5f", x) for x in v), ", ") * "]"

ev(gui) = events(gui.ax.scene)

function px(gui, p)
    scene = gui.ax.scene
    vp = scene.viewport[]
    q = Makie.project(scene, :data, :pixel, Point3f(p...))
    return (Float64(vp.origin[1] + q[1]), Float64(vp.origin[2] + q[2]))
end

function free_px(gui)
    vp = gui.ax.scene.viewport[]
    o, w = minimum(vp), widths(vp)
    for fy in (0.5, 0.3, 0.7, 0.15, 0.85), fx in (0.2, 0.8, 0.35, 0.65, 0.1, 0.9)
        p = (Float64(o[1] + fx * w[1]), Float64(o[2] + fy * w[2]))
        isnothing(first(Makie.pick(gui.fig.scene, Point2f(p), 40))) && return p
    end
    error("the 3D view has no free pixel")
end

mouse!(gui, xy) = (ev(gui).mouseposition[] = (Float64(xy[1]), Float64(xy[2])); sleep(0.03))
press!(gui) = (ev(gui).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.press); sleep(0.03))
release!(gui) = (ev(gui).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.release); sleep(0.03))
click!(gui, xy) = (mouse!(gui, xy); press!(gui); release!(gui); sleep(0.6))

function key!(gui, key, modifiers...)
    e = ev(gui)
    foreach(m -> e.keyboardbutton[] = Makie.KeyEvent(m, Keyboard.press), modifiers)
    e.keyboardbutton[] = Makie.KeyEvent(key, Keyboard.press)
    e.keyboardbutton[] = Makie.KeyEvent(key, Keyboard.release)
    foreach(m -> e.keyboardbutton[] = Makie.KeyEvent(m, Keyboard.release), modifiers)
    sleep(0.3)
    return nothing
end

# The pixel in the middle of a block of the layout, e.g. of a button of a card
rect_center(block) = (r = block.layoutobservables.computedbbox[]; Tuple(Float64.(minimum(r) .+ widths(r) ./ 2)))
rect_center(b::Union{GUI._IconButton, GUI._IconToggle}) = rect_center(b.box)

type!(gui, text) =foreach(c -> (ev(gui).unicode_input[] = c; sleep(0.02)), text)

"""Selects the object `id` with a click on it; `true` if it is selected then."""
function select_obj!(gui, id::Symbol)
    o = obj(gui, id)
    click!(gui, px(gui, wpos(o)))
    return gui.controls.selected[] === o
end

"""A click on the background, which deselects (and releases the claims)."""
deselect!(gui) = (click!(gui, free_px(gui)); isnothing(gui.controls.selected[]))

"""Drags the selected object `id` by `d` pixels, as a press, moves and a release."""
function drag_obj!(gui, id::Symbol, d)
    a = px(gui, wpos(gui, id))
    mouse!(gui, a)
    press!(gui)
    for t in range(0, 1; length = 12)
        mouse!(gui, a .+ t .* d)
    end
    release!(gui)
    wait_solve(gui)
    sleep(0.2)
    return nothing
end

"""Waits until the files have the position of `id` in the window (the autosave wrote it)."""
written(gui, id; timeout = 20.0) = until(() -> near(fpos(id), wpos(gui, id); atol = 1e-10); timeout)

function shot(gui, name)
    try
        reach()
        mkpath(SHOTS)
        img = Makie.colorbuffer(Makie.getscreen(gui.fig.scene))
        Makie.save(joinpath(SHOTS, "$ROLE-$(lpad(STEP[], 2, '0'))-$name.png"), img)
    catch e
        e isa Halt && rethrow()
        info("picture $name not saved", sprint(showerror, e))
    end
    return nothing
end

others(gui) = [o.name for o in values(gui.sync.others)]
claimed(gui, id) = GUI._claimed_by(gui, obj(gui, id))
status(gui) = gui.status.text[]

#=
The steps
=#

const START = """
    @component L1 = SphericalLens(0.05, -0.05, 0.005, 0.0254, ConstantRefractiveIndex(1.5)) pos = (0.0, 0.08, 0.0)
    @component L2 = SphericalLens(0.1, -0.1, 0.005, 0.0254, ConstantRefractiveIndex(1.5)) pos = (0.0, 0.14, 0.0)
    @component M1 = RoundPlanoMirror(0.0254, 0.006) pos = (0.0, 0.2, 0.0) rot = (0.0, 0.0, 45.0)
    @component M2 = RoundPlanoMirror(0.0254, 0.006) pos = (-0.1, 0.2, 0.0) rot = (0.0, 0.0, 45.0)
    @source B1 = Beam([0.0, 0.0, 0.0], [0.0, 1.0, 0.0], 1.0e-6)
    @system S1 = [L1, L2, M1, M2] sources = [B1]
    """

"""The offset of the clock of the drive against this machine [s]: the time of a written file."""
function clock_offset()
    f = joinpath(COORD, "clock-$ROLE.txt")
    offs = Float64[]
    for _ in 1:5
        t0 = time()
        write(f, "$t0")
        t1 = time()
        push!(offs, mtime(f) - (t0 + t1) / 2)
        sleep(0.2)
    end
    rm(f; force = true)
    return sort(offs)[3]
end

function start_run()
    mkpath(ROOT)
    reach()
    if ROLE == "A"
        for d in (COORD, joinpath(ROOT, "project"), SHOTS, RESULTS)
            rm(d; recursive = true, force = true)
        end
        mkpath(COORD)
        RUN[] = Dates.format(now(), "yyyymmdd-HHMMSS")
        write(joinpath(COORD, "run.txt"), RUN[])
    else
        # The run of A, written or touched within the last 90 s, which A did neither halt nor end
        function fresh()
            f = joinpath(COORD, "run.txt")
            isfile(f) && abs(time() - mtime(f)) < 90 || return false
            r = strip(read(f, String))
            return !isfile(joinpath(COORD, "$r-A-HALT")) && !isfile(joinpath(COORD, "$r-A-end"))
        end
        println("waiting for machine A to start a run ...")
        t = until(fresh; timeout = 1800.0, every = 0.5)
        isnothing(t) && throw(Halt("machine A started no run within 30 min"))
        RUN[] = strip(read(joinpath(COORD, "run.txt"), String))
    end
    write(LOGF, "# Machine $ROLE ($ME), run $(RUN[])\n\n| time | step | result | details |\n|---|---|---|---|\n")
    mkpath(RESULTS)
    return nothing
end

"""The git tree of the code of the package `m` (as Pkg has it, also for a package tracked by path)."""
function tree(m::Module)
    d = Pkg.dependencies()[Base.PkgId(m).uuid]
    t = d.is_tracking_path ? readchomp(`git -C $(d.source) rev-parse "HEAD^{tree}"`) : string(d.tree_hash)
    return first(t, 10)
end

function preflight()
    step!("preflight")
    info("host", gethostname())
    info("versions", "Julia $(VERSION), BeamletOptics $(pkgversion(BeamletOptics)), " *
        "BeamletOpticsProjects $(pkgversion(BMOP)), BeamletOpticsGUI $(pkgversion(GUI))")
    commit = try
        readchomp(`git -C $(dirname(@__DIR__)) rev-parse --short HEAD`)
    catch
        "unknown"
    end
    info("commit of the GUI", commit)
    info("person", "$(BMOP.person())")
    off = clock_offset()
    info("clock of the drive minus this clock", @sprintf("%.3f s", off))
    versions = "BeamletOptics $(pkgversion(BeamletOptics)) ($(tree(BeamletOptics))), " *
        "BeamletOpticsProjects $(pkgversion(BMOP)) ($(tree(BMOP))), BeamletOpticsGUI $(pkgversion(GUI))"
    info("trees of the packages", versions)
    signal("ready"; offset = off, commit, versions)
    other = await("ready"; timeout = 1800.0)
    check(other["versions"] == versions, "same packages on both machines (versions and git trees)",
        "$ROLE: $versions; $OTHER: $(other["versions"])")
    check(other["commit"] == commit, "same commit of the GUI", "$ROLE: $commit, $OTHER: $(other["commit"])")
    # (drive - me) - (drive - other) = other - me
    skew = parse(Float64, other["offset"]) - off
    check(abs(skew) < 5, "clocks of the machines agree within 5 s", @sprintf("clock of %s minus clock of %s: %.3f s", OTHER, ROLE, skew))
    return skew
end

"""`watch_notify.jl` both ways: B watches while A writes, then A watches while B writes."""
function notifications()
    step!("notifications of the drive (watch_notify.jl, 60 writes each way)")
    script = joinpath(@__DIR__, "watch_notify.jl")
    julia = Base.julia_cmd()
    for (watcher, n) in (("B", 1), ("A", 2))
        dir = joinpath(ROOT, "notify-$n")
        out = joinpath(RESULTS, "notify-$watcher-watches.txt")
        if ROLE == watcher
            rm(dir; recursive = true, force = true)
            mkpath(dir)
            p = run(pipeline(`$julia --startup-file=no $script watch $dir 300`; stdout = out, stderr = out); wait = false)
            sleep(8)
            signal("watching-$n")
            ok = until(() -> !process_running(p); timeout = 400.0, every = 0.5)
            isnothing(ok) && kill(p)
            text = read(out, String)
            summary = join(filter(l -> occursin(r"^(writes seen|notification after|no write|no end)", l), split(text, '\n')), " / ")
            info("notifications, $OTHER writes, $ROLE watches", summary)
        else
            await("watching-$n"; timeout = 120.0)
            run(pipeline(`$julia --startup-file=no $script write $dir 60`; stdout = devnull))
            info("wrote 60 probes for the watcher on $watcher")
        end
        barrier("notify-$n-done"; timeout = 600.0)
    end
    return nothing
end

function open_window()
    step!("open the project")
    if ROLE == "A"
        mkpath(PROJ)
        close(LibGit2.init(PROJ))
        BMOP.new_project(PROJ; name = "Bench")
        write(joinpath(PROJ, "system.jl"), START)
        gui = open_project(PROJ)
        WINDOW[] = gui
        save_project(gui)
        signal("project")
    else
        await("project"; timeout = 300.0)
        # the files of A settle
        sleep(2)
        gui = open_project(PROJ)
        WINDOW[] = gui
    end
    gui = WINDOW[]
    sleep(3)
    check(length(gui.sync.ids) >= 5, "the window has the objects of the project", "$(length(gui.sync.ids)) ids")
    signal("opened")
    await("opened"; timeout = 300.0)
    t = until(() -> THEM in others(gui); timeout = 90.0)
    check(!isnothing(t), "$THEM is shown as present", "after $(fmt(t)) (beat every 20 s); others: $(others(gui))")
    shot(gui, "opened")
    barrier("presence")
    return gui
end

"""One side drags `id`, the other sees it glide to the same place."""
function drag_seen(gui, actor, id, d)
    step!("$(NAMES[actor]) drags $id, $(actor == "A" ? NAMES["B"] : NAMES["A"]) sees it")
    if ROLE == actor
        check(select_obj!(gui, id), "the click selects $id")
        before = wpos(gui, id)
        drag_obj!(gui, id, d)
        after = wpos(gui, id)
        check(!near(before, after), "the drag moved $id", "$(show3(before)) -> $(show3(after))")
        t = written(gui, id)
        check(!isnothing(t), "the autosave wrote $id", "after $(fmt(t))")
        shot(gui, "dragged-$id")
        check(deselect!(gui), "a click on the background deselects")
        signal("moved-$id"; pos = after)
    else
        s = await("moved-$id"; timeout = 120.0)
        target = vec3(s["pos"])
        sent = parse(Float64, s["t"])
        t = until(() -> near(wpos(gui, id), target); timeout = 60.0)
        check(!isnothing(t), "$id glides to the place of $(NAMES[actor])",
            "$(fmt(t)) after the signal was seen, $(fmt(isnothing(t) ? nothing : time() - sent)) after it was written (clock of $actor)")
        shot(gui, "seen-$id")
    end
    barrier("drag-$id")
    return nothing
end

"""Claims: B holds M1, A is refused and sees the lock; B lets go, A moves M1; a claim expires."""
function claims(gui)
    step!("claims: $(NAMES["B"]) holds M1, $(NAMES["A"]) is refused")
    if ROLE == "B"
        check(select_obj!(gui, :M1), "the click selects M1")
        key!(gui, Keyboard.up)
        t = until(() -> any(c -> c.id === :M1, values(BMOP.claims(PROJ))); timeout = 10.0)
        check(!isnothing(t), "the key step on M1 claims it (a file in .bmo/claims)", "after $(fmt(t))")
        # the key step is in the files before A looks, such that A sees no move of M1 later
        written(gui, :M1)
        signal("holds-M1")
        await("refused")
        shot(gui, "holding-M1")
        check(deselect!(gui), "a click on the background deselects M1")
        t = until(() -> !any(c -> c.id === :M1, values(BMOP.claims(PROJ))); timeout = 15.0)
        check(!isnothing(t), "the claim file of M1 is removed", "after $(fmt(t))")
        signal("released")
        s = await("moved-M1")
        target = vec3(s["pos"])
        t = until(() -> near(wpos(gui, :M1), target); timeout = 60.0)
        check(!isnothing(t), "M1 glides to the place of $(NAMES["A"])", "after $(fmt(t))")
    else
        await("holds-M1"; timeout = 120.0)
        t = until(() -> claimed(gui, :M1) == THEM; timeout = 30.0)
        check(!isnothing(t), "M1 is shown as claimed by $THEM", "after $(fmt(t)) from the signal")
        check(!isempty(GUI._claims(gui).locks), "the lock of M1 is drawn")
        # the key step of B has arrived
        # (a key step is 10 nm: compared to 0.1 nm)
        until(() -> near(wpos(gui, :M1), fpos(:M1); atol = 1e-10) && isempty(gui.sync.gliding); timeout = 30.0)
        before = wpos(gui, :M1)
        select_obj!(gui, :M1)
        gui.status.text[] = ""
        drag_obj!(gui, :M1, (40, 0))
        drag_status = status(gui)
        gui.status.text[] = ""
        key!(gui, Keyboard.up)
        key_status = status(gui)
        check(near(wpos(gui, :M1), before; atol = 1e-12), "the drag and the key step do not move M1")
        check(occursin("$THEM is editing M1", drag_status * " " * key_status), "the status line names $THEM",
            "after the drag: \"$drag_status\", after the key: \"$key_status\"")
        shot(gui, "refused-M1")
        deselect!(gui)
        signal("refused")
        await("released")
        t = until(() -> isnothing(claimed(gui, :M1)); timeout = 30.0)
        check(!isnothing(t), "the lock of M1 goes when $THEM lets go", "after $(fmt(t)) from the signal")
        check(select_obj!(gui, :M1), "the click selects M1")
        drag_obj!(gui, :M1, (40, 0))
        after = wpos(gui, :M1)
        check(!near(before, after), "now the drag moves M1")
        t = written(gui, :M1)
        check(!isnothing(t), "the autosave wrote M1", "after $(fmt(t))")
        check(deselect!(gui), "a click on the background deselects")
        signal("moved-M1"; pos = after)
    end
    barrier("claims")

    step!("claims: a claim without a gesture for 30 s expires")
    if ROLE == "B"
        check(select_obj!(gui, :L2), "the click selects L2")
        key!(gui, Keyboard.up)
        written(gui, :L2)
        signal("holds-L2")
        # L2 stays selected, without a gesture
        await("L2-free"; timeout = 120.0)
        check(deselect!(gui), "a click on the background deselects L2")
    else
        s = await("holds-L2"; timeout = 120.0)
        t1 = until(() -> claimed(gui, :L2) == THEM; timeout = 30.0)
        check(!isnothing(t1), "L2 is shown as claimed by $THEM", "after $(fmt(t1))")
        t2 = until(() -> isnothing(claimed(gui, :L2)); timeout = 90.0)
        check(!isnothing(t2) && 20 < (isnothing(t1) ? 0 : t1) + t2 < 60, "the claim of L2 expires after about 30 s",
            "free $(fmt(isnothing(t1) || isnothing(t2) ? nothing : t1 + t2)) after the signal")
        signal("L2-free")
    end
    barrier("expiry")
    return nothing
end

"""The time `t` of the clock of A on this machine, with the skew of the clocks (other - me)."""
local_time(tA, skew) = ROLE == "A" ? tA : tA - skew

"""Both sides drag at the same moment: A `idA`, B `idB` (the same object: a race)."""
function at_once(gui, skew, idA, idB, tag, name)
    step!(name)
    id = ROLE == "A" ? idA : idB
    d = ROLE == "A" ? (35, 0) : (-35, 0)
    if ROLE == "A"
        signal("go-$tag"; at = time() + 15)
        tA = time() + 15
    else
        tA = parse(Float64, await("go-$tag"; timeout = 120.0)["at"])
    end
    t0 = local_time(tA, skew)
    sleep(max(0.0, t0 - 2 - time()))
    check(select_obj!(gui, id), "the click selects $id")
    sleep(max(0.0, t0 - time()))
    gui.status.text[] = ""
    drag_obj!(gui, id, d)
    info("drag of $id at", @sprintf("%+.2f s against the agreed time", time() - t0))
    mine = wpos(gui, id)
    st = status(gui)
    info("status line after the drag", "\"$st\"")
    sleep(3)
    shot(gui, "at-once")
    deselect!(gui)
    signal("dragged-$tag"; pos = mine)
    await("dragged-$tag"; timeout = 120.0)
    if idA === idB
        # The same object: the window whose write came second finds the object changed in the
        # files and here, a conflict that the person decides on its card (unless the claim of the
        # other was seen first, which refuses the drag). The script takes "theirs"
        sleep(8)
        conflict = !isempty(gui.sync.conflicts)
        info("outcome of the race here", (conflict ? "conflict" : "no conflict") * ", status \"$(status(gui))\"")
        signal("outcome-$tag"; conflict)
        o = await("outcome-$tag"; timeout = 120.0)
        n = conflict + (o["conflict"] == "true")
        check(n <= 1, "at most one window has a conflict", "conflicts in $n windows")
        if conflict
            shot(gui, "conflict")
            card = GUI._info_card(gui)
            check(!isnothing(card) && card.obj isa GUI._ProjectConflict, "the card of the conflict is shown")
            isnothing(card) || click!(gui, rect_center(GUI._card_widget(card, :conflict_theirs)))
            t = until(() -> isempty(gui.sync.conflicts); timeout = 20.0)
            check(!isnothing(t), "\"theirs\" on the card ends the conflict", "after $(fmt(t))")
        end
    end
    # Both windows and the files agree on both objects
    agree() = all(i -> near(wpos(gui, i), fpos(i)), unique([idA, idB])) && isempty(gui.sync.conflicts)
    t = until(agree; timeout = 60.0)
    check(!isnothing(t), "the window agrees with the files on $(join(unique([idA, idB]), " and ")), no conflict open",
        "after $(fmt(t)); conflicts: $(gui.sync.conflicts); status \"$(status(gui))\"")
    finals = Dict(i => wpos(gui, i) for i in unique([idA, idB]))
    signal("final-$tag"; (Symbol(i) => finals[i] for i in keys(finals))...)
    other = await("final-$tag"; timeout = 180.0)
    for i in keys(finals)
        check(near(finals[i], vec3(other[string(i)])), "both windows have the same $i",
            "$ROLE: $(show3(finals[i])), $OTHER: $(other[string(i)])")
    end
    shot(gui, "after")
    barrier("done-$tag")
    return nothing
end

"""B changes the files like an agent, with BeamletOpticsProjects; both windows follow."""
function agent_edit(gui)
    step!("an agent (on B) moves M2 by 10 mm in z through BeamletOpticsProjects")
    before = wpos(gui, :M2)
    if ROLE == "B"
        barrier("before-agent")
        BMOP.move!(PROJ, [:M2]; offset = (0.0, 0.0, 0.01), by = "agent-B")
        signal("agent-moved")
    else
        barrier("before-agent")
        await("agent-moved"; timeout = 120.0)
    end
    target = before .+ [0.0, 0.0, 0.01]
    t = until(() -> near(wpos(gui, :M2), target); timeout = 60.0)
    check(!isnothing(t), "M2 glides 10 mm up", "after $(fmt(t)) from the signal")
    shot(gui, "agent")
    barrier("agent")
    return nothing
end

"""A groups L1 and L2 (Ctrl+click, Ctrl+G); B sees the group."""
function group(gui)
    step!("$(NAMES["A"]) groups L1 and L2 (select!, Ctrl+G), $(NAMES["B"]) sees the group")
    if ROLE == "A"
        # Both lenses as by Ctrl+click: a click may land on the card of the first one, which covers
        # the second one depending on where the race left them
        select!(gui, [obj(gui, :L1), obj(gui, :L2)])
        sleep(0.5)
        key!(gui, Keyboard.g, Keyboard.left_control)
        wait_solve(gui)
        check(!isempty(gui.components.groups), "Ctrl+G makes a group")
        t = until(() -> occursin("@group", read(joinpath(PROJ, "system.jl"), String)); timeout = 20.0)
        check(!isnothing(t), "the autosave writes the @group line", "after $(fmt(t))")
        shot(gui, "group")
        deselect!(gui)
        signal("grouped")
    else
        await("grouped"; timeout = 120.0)
        t = until(() -> !isempty(gui.components.groups); timeout = 60.0)
        check(!isnothing(t), "the group appears", "after $(fmt(t)) from the signal")
        shot(gui, "group")
    end
    barrier("group")
    return nothing
end

"""Each side saves a version with Ctrl+S, one after the other."""
function versions(gui)
    step!("versions: Ctrl+S on both machines")
    for who in ("A", "B")
        if ROLE == who
            # A change of this side since the last version, otherwise Ctrl+S says "no changes"
            id = who == "A" ? :M1 : :M2
            check(select_obj!(gui, id), "the click selects $id")
            key!(gui, Keyboard.page_up, Keyboard.left_shift)
            check(!isnothing(written(gui, id)), "the key step on $id is written")
            deselect!(gui)
            n = length(BMOP.versions(PROJ))
            key!(gui, Keyboard.s, Keyboard.left_control)
            shown = !isnothing(until(() -> !isnothing(GUI._version_box(gui)); timeout = 20.0))
            check(shown, "Ctrl+S shows the card of the version")
            type!(gui, " (two machines, $ME)")
            key!(gui, Keyboard.enter)
            t = until(() -> length(BMOP.versions(PROJ)) == n + 1; timeout = 60.0)
            check(!isnothing(t), "Enter saves a version", "after $(fmt(t)); $(n + 1) versions")
            shot(gui, "version")
            signal("version-$who"; n = n + 1)
        else
            s = await("version-$who"; timeout = 180.0)
            n = parse(Int, s["n"])
            check(length(BMOP.versions(PROJ)) == n, "the version of $(NAMES[who]) is in the history", "$(length(BMOP.versions(PROJ))) versions")
        end
        barrier("versions-$who")
    end
    msgs = [v.message for v in BMOP.versions(PROJ)]
    info("messages of the versions", join(msgs, " / "))
    return nothing
end

"""B closes its window; A sees B leave. Both compare the window with the files."""
function finish(gui)
    step!("compare and leave")
    ids = [:L1, :L2, :M1, :M2]
    mine = Dict(i => wpos(gui, i) for i in ids)
    for i in ids
        check(near(mine[i], fpos(i)), "$i: the window agrees with the files", show3(mine[i]))
    end
    signal("final"; (Symbol(i) => mine[i] for i in ids)...)
    other = await("final"; timeout = 120.0)
    for i in ids
        haskey(other, string(i)) || continue
        check(near(mine[i], vec3(other[string(i)])), "$i: both windows agree")
    end
    if ROLE == "B"
        close(gui)
        WINDOW[] = nothing
        signal("left")
    else
        await("left"; timeout = 120.0)
        t = until(() -> !(THEM in others(gui)); timeout = 90.0)
        check(!isnothing(t), "$THEM is no longer shown after leaving", "after $(fmt(t))")
        shot(gui, "left")
    end
    return nothing
end

function main()
    start_run()
    skew = preflight()
    "--no-notify" in ARGS || notifications()
    gui = open_window()
    drag_seen(gui, "A", :L1, (40, 10))
    drag_seen(gui, "B", :M2, (-30, 20))
    claims(gui)
    at_once(gui, skew, :L2, :M2, "pair", "both drag at once, different objects")
    at_once(gui, skew, :L1, :L1, "race", "both drag L1 at once (a race)")
    agent_edit(gui)
    group(gui)
    versions(gui)
    finish(gui)
    signal("end")
    logline("**end**", isempty(FAILS) ? "all ok" : "$(length(FAILS)) FAIL", join(FAILS, "; "))
    return isempty(FAILS) ? 0 : 1
end

code = try
    main()
catch e
    msg = e isa Halt ? e.msg : sprint(showerror, e, catch_backtrace())
    drive = !reachable()
    println(drive ? "HALT: the shared folder can not be reached: $msg" : "HALT: $msg")
    try
        reachable() && (signal("HALT"; reason = replace(first(msg, 300), '\n' => ' ')); logline("**HALT**", "HALT", first(msg, 2000)))
    catch
    end
    2
finally
    w = WINDOW[]
    isnothing(w) || try close(w) catch end
end
exit(code)
