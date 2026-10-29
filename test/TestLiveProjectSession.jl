module TestLiveProjectSession

using GLMakie, BeamletOptics, BeamletOpticsGUI
using BeamletOpticsProjects
using Makie
using Test

const GUI = BeamletOpticsGUI
const const_kw = (; trace_budget = Inf, throttle = false, detectors = [])

const LENS = "SphericalLens(0.05, -0.05, 0.005, 0.0254, 1.5)"
const START = """
    @component L1 = $LENS pos = (0.0, 0.1, 0.0)
    @component M1 = RoundPlanoMirror(0.0254, 0.006) pos = (0.0, 0.2, 0.0)
    @component D1 = Detector(0.02) pos = (0.0, 0.3, 0.0)
    @source B1 = Beam([0.0, 0.0, 0.0], [0.0, 1.0, 0.0], 1.0e-6)
    @system S1 = [L1, M1, D1] sources = [B1]
    """

function opened()
    dir = mktempdir()
    new_project(dir; name = "Bench")
    write(joinpath(dir, "system.jl"), START)
    gui = open_project(dir; display = false, const_kw...)
    save_project(gui)
    return gui, dir
end

obj(gui, id) = first(x for (x, (name, _)) in gui.sync.ids if name === id)
session(dir) = read(GUI._session_file(dir), String)

@testset "session file" begin
    @testset "no file without a project" begin
        gui = live_view(BeamletOptics.System(); trace_budget = Inf, throttle = false, detectors = [])
        @test GUI._write_session!(gui) === nothing
        @test GUI._connect_session!(gui) === nothing
        @test GUI._session_closed!(gui) === nothing
    end

    gui, dir = opened()
    file = GUI._session_file(dir)
    sys = joinpath(dir, "system.jl")

    @testset "connect, selection" begin
        GUI._connect_session!(gui)
        GUI._connect_session!(gui)
        @test length(gui.sync.session) == 1
        text = session(dir)
        p = GUI._person()
        @test basename(file) == "session-$(p.id).md"
        @test startswith(text, "# Window of $(p.name) ($(p.host)) on the project \"$(basename(dir))\", ")
        @test occursin("Selected: nothing", text)
        @test occursin("Recent changes by the person: none", text)
        @test !occursin("Open conflict", text)
        @test !occursin("does not load", text)
        gui.controls.selected[] = obj(gui, :L1)
        text = session(dir)
        @test occursin(r"Selected: L1 \(Lens\) at \(0\.0, 0\.1, 0\.0\)", text)
        gui.labels[obj(gui, :L1)] = "Kollimator"
        gui.controls.selected[] = obj(gui, :M1)
        gui.controls.selected[] = obj(gui, :L1)
        @test occursin("Selected: L1 \"Kollimator\" (Lens)", session(dir))
        @test !isfile(file * ".tmp")
        # how to tell a file of a window that was not closed
        @test occursin("presence-$(p.id).toml changes at", text)
        # a selection of several: each object, in the session and the presence file
        gui.controls.selected[] = GUI._MultiSelection(Any[obj(gui, :L1), obj(gui, :M1)])
        @test occursin(r"Selected: 2 objects: L1 \"Kollimator\" \(Lens\) at [^;]*; M1 \(", session(dir))
        data = GUI._presence_data(gui).data
        @test data["selected_ids"] == ["L1", "M1"] && data["selected_id"] == "L1"
        @test length(data["selected_uids"]) == 2 && data["selected"] == data["selected_uids"][1]
        gui.controls.selected[] = nothing
        @test GUI._presence_data(gui).data["selected_ids"] == String[]
    end

    @testset "conflict and failure" begin
        uid = gui.sync.ids[obj(gui, :M1)][2]
        gui.sync.conflicts = ["id:D1", uid]
        gui.sync.failed = true
        gui.sync.load_error = "system.jl:12:5: boom"
        gui.status.text[] = "something else"
        GUI._write_session!(gui)
        text = session(dir)
        @test occursin("Open conflict: D1, M1 (window and file differ: the file keeps its state of them until the person decides; all else is saved)", text)
        @test !occursin(uid, text)
        @test occursin("The file does not load: system.jl:12:5: boom (the window keeps its state)", text)
        @test occursin(".bmo/window-backup-<person>.jl", text)
        gui.sync.conflicts = String[]
        gui.sync.failed = false
        GUI._write_session!(gui)
        @test !occursin("Open conflict", session(dir))
    end

    @testset "a failing write does not propagate" begin
        bad = mktempdir()
        write(joinpath(bad, ".bmo"), "a file where the folder should be")
        old = gui.project
        gui.project = bad
        try
            @test_logs (:warn, "could not write the session file") GUI._write_session!(gui)
            @test_logs GUI._write_session!(gui)
            @test (gui.controls.selected[] = obj(gui, :M1)) !== nothing
        finally
            gui.project = old
        end
    end

    @testset "lines of the journal" begin
        before = BeamletOpticsProjects.load_project(dir)
        t = read(sys, String)
        t = replace(t, "L1 = $LENS pos = (0.0, 0.1, 0.0)" => "L1 = $LENS pos = (0.0, 0.10512, 0.0)")
        t = replace(t, "@component D1 = Detector(0.02) pos = (0.0, 0.3, 0.0)" => "@component D1 = Detector(0.02) pos = (0.0, 0.3, 0.0) rot = (0.0, 0.0, 30.0)")
        t = replace(t, "@component M1 = RoundPlanoMirror(0.0254, 0.006)" => "@component M1 = RoundPlanoMirror(0.0254, 0.007)")
        t *= "@component M4 = RoundPlanoMirror(0.0254, 0.006) pos = (0.0, 0.5, 0.0)\n"
        write(sys, t)
        after = BeamletOpticsProjects.load_project(dir)
        changes = BeamletOpticsProjects.diff_projects(before, after)
        empty!(gui.sync.journal)
        GUI._journal!(gui, changes)
        lines = [l for (_, l) in gui.sync.journal]
        @test "moved L1 to (0.0, 0.1051, 0.0)" in lines
        @test "rotated D1" in lines
        @test "rebuilt M1" in lines
        @test any(l -> startswith(l, "added M4 = RoundPlanoMirror("), lines)
        text = session(dir)
        @test occursin("Recent changes by the person (newest first):", text)
        # with the day: a file of a window that was not closed may be read days later
        @test occursin(r"- \d{4}-\d\d-\d\d \d\d:\d\d:\d\d moved L1 to \(0\.0, 0\.1051, 0\.0\)", text)
        # newest first
        @test findfirst("added M4", text).start < findfirst("moved L1", text).start

        both = BeamletOpticsProjects.Entry(:component, :Q1, "Detector(0.02)", nothing;
            pos = (0.0, 0.0, 0.0), pose0 = ([0.0, 0.0, 0.0], [1.0 0 0; 0 1 0; 0 0 1]), uid = "u1")
        moved = BeamletOpticsProjects.Entry(:component, :Q1, "Detector(0.02)", nothing;
            pos = (1.0, 0.0, 0.0), rot = (0.0, 0.0, 10.0),
            pose0 = ([0.0, 0.0, 0.0], [1.0 0 0; 0 1 0; 0 0 1]), uid = "u1")
        EC = BeamletOpticsProjects.EntryChange
        SC = BeamletOpticsProjects.SystemChange
        @test GUI._entry_line(EC("u1", :moved, both, moved)) == "moved and rotated Q1 to (1.0, 0.0, 0.0)"
        @test GUI._entry_line(EC("u1", :removed, both, nothing)) == "removed Q1"
        @test GUI._entry_line(EC("u1", :renamed, both, moved)) == "renamed Q1 → Q1"
        lab = BeamletOpticsProjects.Entry(:component, :Q1, "Detector(0.02)", nothing;
            pos = (0.0, 0.0, 0.0), pose0 = ([0.0, 0.0, 0.0], [1.0 0 0; 0 1 0; 0 0 1]), uid = "u1", label = "Kollimator")
        @test GUI._entry_line(EC("u1", :relabeled, both, lab)) == "relabeled Q1 \"Kollimator\""

        s1 = BeamletOpticsProjects.SystemEntry(:S1, [:L1, :M1], [:B1]; uid = "s")
        s2 = BeamletOpticsProjects.SystemEntry(:S1, [:L1, :M4], [:B1]; uid = "s")
        @test GUI._member_lines(SC("s", :members, s1, s2)) == ["added M4 to S1", "removed M1 from S1"]
        # a renamed member did not leave the system
        s3 = BeamletOpticsProjects.SystemEntry(:S1, [:L7, :M1, :M4], [:B1]; uid = "s")
        @test GUI._member_lines(SC("s", :members, s1, s3), Dict(:L1 => :L7)) == ["added M4 to S1"]
        @test GUI._system_line(SC("s", :added, nothing, s2)) == "added system S1"
    end

    @testset "at most 20 entries" begin
        empty!(gui.sync.journal)
        EC = BeamletOpticsProjects.EntryChange
        e = BeamletOpticsProjects.Entry(:component, :Q1, "Detector(0.02)", nothing;
            pose0 = ([0.0, 0.0, 0.0], [1.0 0 0; 0 1 0; 0 0 1]), uid = "u1")
        for i in 1:25
            GUI._journal!(gui, (; entries = [EC("u1", :removed, e, nothing)], systems = []))
        end
        @test length(gui.sync.journal) == 20
        @test count("- ", session(dir)) >= 20
        @test count(l -> occursin("removed Q1", l), split(session(dir), "\n")) == 20
    end

    @testset "closed" begin
        @test isfile(file)
        GUI._session_closed!(gui)
        @test isempty(gui.sync.session)
        @test !isfile(file)
        @test GUI._session_closed!(gui) === nothing   # a missing file is fine
        gui.controls.selected[] = obj(gui, :M1)
        @test !isfile(file)
    end

    @testset "one file per person" begin
        dir2 = mktempdir()
        new_project(dir2; name = "Bench")
        write(joinpath(dir2, "system.jl"), START)
        open_as(who) = withenv(() -> open_project(dir2; display = false, const_kw...), "BMO_PERSON" => who)
        ga, gb = open_as("anna"), open_as("ben")
        fa = withenv(() -> GUI._session_file(dir2), "BMO_PERSON" => "anna")
        fb = withenv(() -> GUI._session_file(dir2), "BMO_PERSON" => "ben")
        @test fa != fb
        withenv("BMO_PERSON" => "anna") do
            GUI._write_session!(ga)
        end
        withenv("BMO_PERSON" => "ben") do
            GUI._write_session!(gb)
        end
        @test startswith(read(fa, String), "# Window of anna (")
        @test startswith(read(fb, String), "# Window of ben (")
        withenv("BMO_PERSON" => "anna") do
            GUI._session_closed!(ga)
        end
        @test !isfile(fa)
        @test isfile(fb)
    end
end

end
