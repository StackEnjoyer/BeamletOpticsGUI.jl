module TestLiveProjectBackground

# A watched window writes its files in the background, such that a slow drive does not stop it
# (see `_start_save!`, `_write_later!`): here the writes are slowed down by a hook instead

using GLMakie, BeamletOptics, BeamletOpticsGUI
using BeamletOpticsProjects
using Makie
using Test

const GUI = BeamletOpticsGUI
const BMOP = BeamletOpticsProjects
const TOML = GUI.TOML
const const_kw = (; trace_budget = Inf, throttle = false, detectors = [])

const START = """
    @component L1 = SphericalLens(0.05, -0.05, 0.005, 0.0254, ConstantRefractiveIndex(1.5)) pos = (0.0, 0.1, 0.0)
    @component M1 = RoundPlanoMirror(0.0254, 0.006) pos = (0.0, 0.2, 0.0)
    @component M2 = RoundPlanoMirror(0.0254, 0.006) pos = (0.05, 0.2, 0.0)
    @source B1 = Beam([0.0, 0.0, 0.0], [0.0, 1.0, 0.0], 1.0e-6)
    @system S1 = [L1, M1, M2] sources = [B1]
    """

"""A project with `START`, opened (not shown) and saved once; it writes in the background as a watched window."""
function opened()
    dir = mktempdir()
    new_project(dir; name = "Bench")
    write(joinpath(dir, "system.jl"), START)
    gui = open_project(dir; display = false, const_kw...)
    save_project(gui)
    gui.sync.background = true
    return gui, dir
end

function obj(gui, id)
    for (x, (name, _)) in gui.sync.ids
        name === id && return x
    end
    return nothing
end

file_pos(dir, id) = collect(BMOP.pose(BMOP.load_project(dir), id).pos)
pos(x) = Vector{Float64}(position(x))

"""Calls the autosave until it is no longer `:saving` (the write in the background ended), returns its last result."""
function settle!(gui, now)
    r = :saving
    for _ in 1:400
        r = GUI._autosave!(gui; now)
        r === :saving || return r
        sleep(0.01)
    end
    return r
end

"""Changes the setup and lets `_AUTOSAVE_DELAY` pass: the next autosave writes. Returns the time to call it with."""
function changed!(gui, id, d)
    GUI.translate3d!(gui, obj(gui, id), d)
    t = time()
    @test GUI._autosave!(gui; now = t) === :pending
    return t + 1.0
end

hook!(f) = (GUI._SAVE_HOOK[] = f)
unhook!() = (GUI._SAVE_HOOK[] = () -> nothing)

@testset "the autosave of a watched window writes in the background" begin
    gui, dir = opened()
    s = gui.sync
    try
        @testset "the window does not wait for a slow write" begin
            hook!(() -> sleep(1.0))
            t = changed!(gui, :L1, [0.0, 0.0, 0.01])
            took = @elapsed(r = GUI._autosave!(gui; now = t))
            @test r === :saving && took < 0.5
            @test s.saving && !isnothing(s.save)
            # no look starts while it writes
            @test GUI._take_look!(gui; now = t) === nothing
            # the next steps do not wait either
            @test @elapsed(GUI._autosave!(gui; now = t + 0.1)) < 0.1
            @test settle!(gui, t + 2) === :saved
            @test !s.saving && isnothing(s.save)
            @test file_pos(dir, :L1) ≈ pos(obj(gui, :L1))
            @test GUI._autosave!(gui; now = t + 3) === :none
        end
        @testset "a change during the write is saved by the next write" begin
            hook!(() -> sleep(0.5))
            t = changed!(gui, :M1, [0.0, 0.0, 0.01])
            @test GUI._autosave!(gui; now = t) === :saving
            GUI.translate3d!(gui, obj(gui, :M2), [0.0, 0.0, 0.02])
            @test settle!(gui, t + 0.1) === :saved
            unhook!()
            # the change of M2 came after the write started: not written yet
            @test !(file_pos(dir, :M2) ≈ pos(obj(gui, :M2)))
            @test GUI._autosave!(gui; now = t + 1) === :pending
            @test GUI._autosave!(gui; now = t + 2) === :saving
            @test settle!(gui, t + 2) === :saved
            @test file_pos(dir, :M1) ≈ pos(obj(gui, :M1)) && file_pos(dir, :M2) ≈ pos(obj(gui, :M2))
        end
        @testset "files changed by another before the write: merged, written again" begin
            n = Ref(0)
            hook!(() -> (n[] += 1; n[] == 1 && BMOP.move!(dir, [:M2]; offset = (0.0, 0.03, 0.0), by = "agent")))
            m2 = file_pos(dir, :M2)
            t = changed!(gui, :L1, [0.01, 0.0, 0.0])
            @test GUI._autosave!(gui; now = t) === :saving
            @test settle!(gui, t) === :saved
            @test n[] == 2
            # both: the change of the window and the one of the agent
            @test file_pos(dir, :L1) ≈ pos(obj(gui, :L1))
            @test file_pos(dir, :M2) ≈ m2 .+ [0.0, 0.03, 0.0]
            @test pos(obj(gui, :M2)) ≈ m2 .+ [0.0, 0.03, 0.0]
            unhook!()
        end
        @testset "the file system refuses the write: tried again" begin
            n = Ref(0)
            hook!(() -> (n[] += 1; n[] == 1 && throw(Base.IOError("the file is in use", -4082))))
            t = changed!(gui, :M1, [0.0, 0.01, 0.0])
            @test GUI._autosave!(gui; now = t) === :saving
            @test settle!(gui, t) === :busy
            @test !(file_pos(dir, :M1) ≈ pos(obj(gui, :M1)))
            @test GUI._autosave!(gui; now = t + 1) === :saving
            @test settle!(gui, t + 1) === :saved
            @test file_pos(dir, :M1) ≈ pos(obj(gui, :M1))
            unhook!()
        end
        @testset "a closing window and Ctrl+S wait for the write" begin
            hook!(() -> sleep(0.5))
            t = changed!(gui, :L1, [0.0, 0.0, -0.01])
            @test GUI._autosave!(gui; now = t) === :saving
            GUI.translate3d!(gui, obj(gui, :M1), [0.0, 0.0, -0.01])
            # force: waits for the write, then writes the rest on this thread
            @test GUI._autosave!(gui; now = t, force = true) === :saved
            @test isnothing(s.save) && !s.saving
            @test file_pos(dir, :L1) ≈ pos(obj(gui, :L1)) && file_pos(dir, :M1) ≈ pos(obj(gui, :M1))
            unhook!()
        end
        @testset "save_project and Ctrl+R wait for the write" begin
            hook!(() -> sleep(0.5))
            t = changed!(gui, :M2, [0.0, 0.0, -0.01])
            @test GUI._autosave!(gui; now = t) === :saving
            save_project(gui)
            @test isnothing(s.save)
            @test file_pos(dir, :M2) ≈ pos(obj(gui, :M2))
            t = changed!(gui, :M2, [0.0, 0.0, -0.01])
            @test GUI._autosave!(gui; now = t) === :saving
            GUI._reload_key!(gui)
            @test isnothing(s.save)
            # the write was done before the window took the files
            @test file_pos(dir, :M2) ≈ pos(obj(gui, :M2))
            unhook!()
        end
    finally
        unhook!()
        close(gui)
    end
end

@testset "a watched window writes its session file in the background" begin
    gui, dir = opened()
    try
        file = GUI._session_file(dir)
        GUI._write_session!(gui)
        GUI._drain_writes!(gui)
        @test isfile(file)
        # Many writes in a row: the latest text is written last
        for id in (:L1, :M1, :M2)
            gui.controls.selected[] = obj(gui, id)
            GUI._write_session!(gui)
        end
        GUI._drain_writes!(gui)
        @test read(file, String) == GUI._session_text(gui)
        @test occursin("M2", read(file, String))
        # A write that is slow does not hold the window
        slow = Ref(false)
        GUI._write_later!(gui, :slow, () -> (sleep(0.5); slow[] = true))
        @test !slow[]
        GUI._drain_writes!(gui)
        @test slow[]
        # A failed write is logged and the next ones run
        @test_logs (:warn, r"in the background failed") begin
            GUI._write_later!(gui, :bad, () -> error("disk full"))
            GUI._drain_writes!(gui)
        end
        ok = Ref(false)
        GUI._write_later!(gui, :next, () -> (ok[] = true))
        GUI._drain_writes!(gui)
        @test ok[]
    finally
        close(gui)
    end
end

end
