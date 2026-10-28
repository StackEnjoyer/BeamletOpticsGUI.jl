module TestLiveProjectPresence

using GLMakie, BeamletOptics, BeamletOpticsGUI
using BeamletOpticsProjects
using Makie
using Test

const GUI = BeamletOpticsGUI
const TOML = GUI.TOML  # the TOML of the package, not a dependency of the tests
const const_kw = (; trace_budget = Inf, throttle = false, detectors = [])

const START = """
    @component L1 = SphericalLens(0.05, -0.05, 0.005, 0.0254, 1.5) pos = (0.0, 0.1, 0.0)
    @component M1 = RoundPlanoMirror(0.0254, 0.006) pos = (0.0, 0.2, 0.0)
    @source B1 = Beam([0.0, 0.0, 0.0], [0.0, 1.0, 0.0], 1.0e-6)
    @system S1 = [L1, M1] sources = [B1]
    """

"""A project with `START`, opened (not shown) and saved once, so that every line has a uid."""
function opened()
    dir = mktempdir()
    new_project(dir; name = "Bench")
    write(joinpath(dir, "system.jl"), START)
    gui = open_project(dir; display = false, const_kw...)
    save_project(gui)
    return gui, dir
end

"""The object of the readable id `id` in the window."""
function obj(gui, id)
    for (x, (name, _)) in gui.sync.ids
        name === id && return x
    end
    return nothing
end

uid(gui, id) = gui.sync.ids[obj(gui, id)][2]

"""Writes the presence file of an other participant `id` by hand; `extra` adds fields (e.g. `kind`)."""
function other!(dir, id; name = id, beat = 1, selected = "", selected_id = "", written = "", extra...)
    file = GUI._presence_file(dir, id)
    mkpath(dirname(file))
    data = Dict{String, Any}("name" => name, "host" => "PC9", "beat" => beat,
        "selected" => selected, "selected_id" => selected_id, "written" => written)
    for (k, v) in extra
        data[string(k)] = v
    end
    open(io -> TOML.print(io, data), file, "w")
    return file
end

"""Writes the presence file of an agent `id` by hand, as an agent would: no uid, no host."""
function agent!(dir, id; name = id, beat = 1, selected_id = "", doing = nothing, ttl = 600, written = nothing)
    file = GUI._presence_file(dir, id)
    mkpath(dirname(file))
    data = Dict{String, Any}("name" => name, "kind" => "agent", "beat" => beat, "ttl" => ttl,
        "selected_id" => selected_id)
    isnothing(doing) || (data["doing"] = doing)
    isnothing(written) || (data["written"] = written)
    open(io -> TOML.print(io, data), file, "w")
    return file
end

boxes(gui) = filter(p -> p isa LineSegments, gui.sync.presence)
labels(gui) = [GUI._label_text(p) for p in gui.sync.presence if p isa Makie.Text]

@testset "Presence of several people" begin
    withenv("BMO_PERSON" => "anna") do
        gui, dir = opened()
        me = GUI._person()
        own = GUI._presence_file(dir, me.id)

        @testset "own file" begin
            gui.controls.selected[] = obj(gui, :L1)
            GUI._write_presence!(gui; now = 100.0)
            @test isfile(own)
            @test !isfile(own * ".tmp")
            d = TOML.parsefile(own)
            @test d["name"] == "anna" && d["host"] == me.host
            @test d["beat"] == 1
            @test d["kind"] == "person" && d["ttl"] == GUI._ALIVE
            @test d["selected"] == uid(gui, :L1) && d["selected_id"] == "L1"
            @test d["written"] == gui.sync.stamp
            @test gui.sync.beat_at == 100.0
            GUI._write_presence!(gui; now = 101.0)
            @test TOML.parsefile(own)["beat"] == 2
            gui.controls.selected[] = nothing
            GUI._write_presence!(gui; now = 102.0)
            d = TOML.parsefile(own)
            @test d["selected"] == "" && d["selected_id"] == ""
            # The heartbeat: written again only after `_BEAT`
            GUI._check_presence!(gui; now = 102.0 + GUI._BEAT / 2)
            @test TOML.parsefile(own)["beat"] == 3
            GUI._check_presence!(gui; now = 102.0 + GUI._BEAT)
            @test TOML.parsefile(own)["beat"] == 4
            # The own file is never an other
            @test isempty(gui.sync.others)
            @test isempty(gui.sync.presence)
        end

        @testset "an other with a selection" begin
            file = other!(dir, "bob@PC9"; name = "Bob", selected = uid(gui, :M1))
            GUI._check_presence!(gui; now = 200.0)
            @test haskey(gui.sync.others, "bob@PC9")
            @test length(boxes(gui)) == 1
            @test labels(gui) == ["Bob"]
            box = only(boxes(gui))
            bb = GUI._part_box(gui, obj(gui, :M1))
            @test box[1][] == GUI._bbox_wireframe(bb)
            @test box.color[] == Makie.to_color(GUI._OTHER_COLOR)
            # Nothing changed: not drawn again
            GUI._check_presence!(gui; now = 201.0)
            @test only(boxes(gui)) === box

            # Alive while the beat changes, gone after `_ALIVE` without a change
            GUI._check_presence!(gui; now = 200.0 + GUI._ALIVE - 1)
            @test length(boxes(gui)) == 1
            other!(dir, "bob@PC9"; name = "Bob", beat = 2, selected = uid(gui, :M1))
            GUI._check_presence!(gui; now = 200.0 + GUI._ALIVE - 1)
            GUI._check_presence!(gui; now = 200.0 + 2 * GUI._ALIVE - 2)
            @test length(boxes(gui)) == 1
            GUI._check_presence!(gui; now = 200.0 + 2 * GUI._ALIVE - 1)
            @test isempty(gui.sync.presence)
            # A stale file does not come back
            GUI._check_presence!(gui; now = 200.0 + 3 * GUI._ALIVE)
            @test isempty(gui.sync.presence)
            # ... until its beat changes again
            other!(dir, "bob@PC9"; name = "Bob", beat = 3, selected = uid(gui, :M1))
            GUI._check_presence!(gui; now = 400.0)
            @test labels(gui) == ["Bob"]

            # Another selection moves the box
            other!(dir, "bob@PC9"; name = "Bob", beat = 4, selected = uid(gui, :L1))
            GUI._check_presence!(gui; now = 401.0)
            @test only(boxes(gui))[1][] == GUI._bbox_wireframe(GUI._part_box(gui, obj(gui, :L1)))

            # A half-written file is skipped, the other kept
            write(file, "name = \"Bob\nbeat = ")
            GUI._check_presence!(gui; now = 402.0)
            @test labels(gui) == ["Bob"]

            # An empty selection
            other!(dir, "bob@PC9"; name = "Bob", beat = 5, selected = "")
            GUI._check_presence!(gui; now = 403.0)
            @test isempty(gui.sync.presence)

            # A uid that is not in the view
            other!(dir, "bob@PC9"; name = "Bob", beat = 6, selected = "no-such-uid")
            GUI._check_presence!(gui; now = 404.0)
            @test haskey(gui.sync.others, "bob@PC9")
            @test isempty(gui.sync.presence)

            # The file is deleted
            other!(dir, "bob@PC9"; name = "Bob", beat = 7, selected = uid(gui, :M1))
            GUI._check_presence!(gui; now = 405.0)
            @test length(boxes(gui)) == 1
            rm(file)
            GUI._check_presence!(gui; now = 406.0)
            @test isempty(gui.sync.presence)
            @test !haskey(gui.sync.others, "bob@PC9")
        end

        @testset "two others, spectator mode" begin
            other!(dir, "bob@PC9"; name = "Bob", selected = uid(gui, :M1))
            other!(dir, "carl@PC8"; name = "Carl", selected = uid(gui, :L1))
            GUI._check_presence!(gui; now = 500.0)
            @test sort(labels(gui)) == ["Bob", "Carl"]
            @test all(p -> p.visible[], gui.sync.presence)
            GUI._set_spectator!(gui.controls, true)
            GUI._check_presence!(gui; now = 501.0)
            @test length(gui.sync.presence) == 4
            @test !any(p -> p.visible[], gui.sync.presence)
            GUI._set_spectator!(gui.controls, false)
            GUI._check_presence!(gui; now = 502.0)
            @test all(p -> p.visible[], gui.sync.presence)
        end

        @testset "writer" begin
            other!(dir, "bob@PC9"; name = "Bob", beat = 10, written = "stamp-b")
            other!(dir, "carl@PC8"; name = "Carl", beat = 10, written = "stamp-c")
            GUI._check_presence!(gui; now = 600.0)
            @test GUI._writer(gui, "stamp-b"; now = 600.0) == "Bob"
            @test GUI._writer(gui, "stamp-c"; now = 600.0) == "Carl"
            @test isnothing(GUI._writer(gui, "stamp-x"; now = 600.0))
            @test isnothing(GUI._writer(gui, ""; now = 600.0))
            @test isnothing(GUI._writer(gui, nothing; now = 600.0))
            # Not alive any more
            @test isnothing(GUI._writer(gui, "stamp-b"; now = 600.0 + GUI._ALIVE))
            # The own stamp is never an other's
            GUI._write_presence!(gui; now = 600.0)
            GUI._check_presence!(gui; now = 600.0)
            @test isnothing(GUI._writer(gui, gui.sync.stamp; now = 600.0))
        end

        @testset "agents" begin
            for id in ("bob@PC9", "carl@PC8")
                rm(GUI._presence_file(dir, id); force = true)
            end
            GUI._check_presence!(gui; now = 1000.0)
            @test isempty(gui.sync.others)

            # An agent with only the readable id is shown at that object, with its name
            claude = agent!(dir, "claude@agent"; name = "Claude (Opus 5.5)", selected_id = "L1")
            GUI._check_presence!(gui; now = 1000.0)
            @test gui.sync.others["claude@agent"].kind == "agent"
            @test only(boxes(gui))[1][] == GUI._bbox_wireframe(GUI._part_box(gui, obj(gui, :L1)))
            @test labels(gui) == ["Claude (Opus 5.5)"]

            # `doing` in a second line of the label, at most `_DOING_CHARS` characters
            agent!(dir, "claude@agent"; name = "Claude (Opus 5.5)", beat = 2, selected_id = "L1", doing = "moving L1")
            GUI._check_presence!(gui; now = 1001.0)
            @test labels(gui) == ["Claude (Opus 5.5)\nmoving L1"]
            agent!(dir, "claude@agent"; name = "Claude (Opus 5.5)", beat = 3, selected_id = "L1", doing = "x"^200)
            GUI._check_presence!(gui; now = 1002.0)
            @test labels(gui) == ["Claude (Opus 5.5)\n" * "x"^GUI._DOING_CHARS]

            # A uid that is not in the view: the readable id counts
            bob = other!(dir, "bob@PC9"; name = "Bob", beat = 1, selected = "no-such-uid", selected_id = "M1",
                kind = "person", ttl = 60)
            GUI._check_presence!(gui; now = 1002.0)
            @test gui.sync.others["bob@PC9"].kind == "person"
            @test sort(labels(gui)) == ["Bob", "Claude (Opus 5.5)\n" * "x"^GUI._DOING_CHARS]

            # The `ttl` of each: the agent's 600 s keep it, the window's 60 s do not
            GUI._check_presence!(gui; now = 1002.0 + 300)
            @test haskey(gui.sync.others, "bob@PC9")
            @test labels(gui) == ["Claude (Opus 5.5)\n" * "x"^GUI._DOING_CHARS]
            @test only(boxes(gui))[1][] == GUI._bbox_wireframe(GUI._part_box(gui, obj(gui, :L1)))
            GUI._check_presence!(gui; now = 1002.0 + 600)
            @test isempty(gui.sync.presence)

            # The `ttl` of a file is clamped, a wrong one is the default
            for (ttl, want) in ((1.0e6, 3600.0), (1, 5.0), (-3, GUI._ALIVE), ("long", GUI._ALIVE))
                other!(dir, "bob@PC9"; name = "Bob", beat = 2, ttl)
                GUI._check_presence!(gui; now = 2000.0)
                @test gui.sync.others["bob@PC9"].ttl == want
            end
            rm(bob)

            # `_writer`: no fallback by kind, an agent without `written` is not named
            agent!(dir, "claude@agent"; name = "Claude (Opus 5.5)", beat = 4)
            GUI._check_presence!(gui; now = 3000.0)
            @test isnothing(GUI._writer(gui, "stamp-z"; now = 3000.0))
            # An agent that announced after its write is named, like a person
            agent!(dir, "claude@agent"; name = "Claude (Opus 5.5)", beat = 5, written = "stamp-z")
            GUI._check_presence!(gui; now = 3000.0)
            @test GUI._writer(gui, "stamp-z"; now = 3000.0) == "Claude (Opus 5.5)"
            # A person with a matching `written` is named alike; no match, no name
            other!(dir, "bob@PC9"; name = "Bob", beat = 3, written = "stamp-y")
            GUI._check_presence!(gui; now = 3000.0)
            @test GUI._writer(gui, "stamp-y"; now = 3000.0) == "Bob"
            @test isnothing(GUI._writer(gui, "stamp-x"; now = 3000.0))
            rm(GUI._presence_file(dir, "bob@PC9"))
            # Two agents: each is named by its own `written`
            agent!(dir, "codex@agent"; name = "Codex", beat = 1, written = "stamp-c")
            GUI._check_presence!(gui; now = 3000.0)
            @test GUI._writer(gui, "stamp-z"; now = 3000.0) == "Claude (Opus 5.5)"
            @test GUI._writer(gui, "stamp-c"; now = 3000.0) == "Codex"
            rm(GUI._presence_file(dir, "codex@agent"))
            # None alive: nothing
            GUI._check_presence!(gui; now = 3000.0)
            @test isnothing(GUI._writer(gui, "stamp-z"; now = 3000.0 + 600))
            rm(claude)
            GUI._check_presence!(gui; now = 3000.0)
            @test isempty(gui.sync.others)
            @test isnothing(GUI._writer(gui, "stamp-z"; now = 3000.0))
        end

        @testset "writer named after the merge" begin
            gui.controls.selected[] = nothing
            GUI._write_presence!(gui; now = 4000.0)
            saved = gui.sync.stamp
            @test TOML.parsefile(own)["written"] == saved
            # An agent writes the files; the window merges before the agent announces
            file = joinpath(dir, "system.jl")
            write(file, replace(read(file, String), "pos = (0.0, 0.1, 0.0)" => "pos = (0.0, 0.13, 0.0)"))
            @test GUI._sync!(gui; animate = false) === :applied
            merged = gui.sync.stamp
            @test merged != saved
            status = gui.status.text[]
            @test startswith(status, "agent: ") && occursin("moved L1", status)
            # The window does not claim the merged files as its write
            GUI._write_presence!(gui; now = 4000.0)
            @test TOML.parsefile(own)["written"] == saved
            # An announce of the agent without its stamp changes nothing
            claude = agent!(dir, "claude@agent"; name = "Claude (Opus 5.5)", beat = 1, written = "stamp-old")
            GUI._check_presence!(gui; now = 4001.0)
            @test gui.status.text[] == status
            # Its announce after the write names it in the status line of the merge
            agent!(dir, "claude@agent"; name = "Claude (Opus 5.5)", beat = 2, written = merged)
            GUI._check_presence!(gui; now = 4002.0)
            @test gui.status.text[] == "Claude (Opus 5.5): " * status[(length("agent: ") + 1):end]
            # Once only: another status line is not renamed
            gui.status.text[] = "agent: something else"
            GUI._check_presence!(gui; now = 4003.0)
            @test gui.status.text[] == "agent: something else"
            # A status line that changed since the merge is not renamed either
            write(file, replace(read(file, String), "pos = (0.0, 0.13, 0.0)" => "pos = (0.0, 0.14, 0.0)"))
            @test GUI._sync!(gui; animate = false) === :applied
            gui.status.text[] = "project files are as in the window"
            agent!(dir, "claude@agent"; name = "Claude (Opus 5.5)", beat = 3, written = gui.sync.stamp)
            GUI._check_presence!(gui; now = 4004.0)
            @test gui.status.text[] == "project files are as in the window"
            rm(claude)
            GUI._check_presence!(gui; now = 4005.0)
        end

        @testset "writer of two merges of the same change" begin
            # The agent writes L1 twice before it announces: both merges say "agent: moved L1"
            file = joinpath(dir, "system.jl")
            write(file, replace(read(file, String), "pos = (0.0, 0.14, 0.0)" => "pos = (0.0, 0.15, 0.0)"))
            @test GUI._sync!(gui; animate = false) === :applied
            status = gui.status.text[]
            @test startswith(status, "agent: ") && occursin("moved L1", status)
            write(file, replace(read(file, String), "pos = (0.0, 0.15, 0.0)" => "pos = (0.0, 0.16, 0.0)"))
            @test GUI._sync!(gui; animate = false) === :applied
            @test gui.status.text[] == status
            claude = agent!(dir, "claude@agent"; name = "Claude (Opus 5.5)", beat = 1, written = gui.sync.stamp)
            GUI._check_presence!(gui; now = 5000.0)
            @test gui.status.text[] == "Claude (Opus 5.5): " * status[(length("agent: ") + 1):end]
            rm(claude)
            GUI._check_presence!(gui; now = 5001.0)
        end

        @testset "open and reload claim no write" begin
            # Someone edits the files without announcing; the window merges them
            file = joinpath(dir, "system.jl")
            write(file, replace(read(file, String), "pos = (0.0, 0.16, 0.0)" => "pos = (0.0, 0.17, 0.0)"))
            @test GUI._sync!(gui; animate = false) === :applied
            edited = gui.sync.stamp
            status = gui.status.text[]
            @test startswith(status, "agent: ")
            # Anna opens the project in a second window: its presence does not claim the files
            rm(own)
            gui2 = open_project(dir; display = false, const_kw...)
            @test gui2.sync.stamp == edited
            GUI._write_presence!(gui2; now = 6000.0)
            @test TOML.parsefile(own)["written"] == ""
            # Nor after `Ctrl+R`
            GUI._load_from_disk!(gui2)
            GUI._write_presence!(gui2; now = 6000.0)
            @test TOML.parsefile(own)["written"] == ""
            # So the window of the merge does not name her as the writer
            anna = other!(dir, "anna@PC2"; name = "Anna", beat = 1,
                written = TOML.parsefile(own)["written"])
            GUI._check_presence!(gui; now = 6001.0)
            @test gui.status.text[] == status
            # Her own save is claimed (the same text: the same stamp)
            save_project(gui2)
            GUI._write_presence!(gui2; now = 6002.0)
            @test TOML.parsefile(own)["written"] == gui2.sync.stamp == edited
            rm(anna)
            GUI._write_presence!(gui; now = 6003.0)
        end

        @testset "closing" begin
            other = other!(dir, "bob@PC9"; name = "Bob", beat = 20, selected = uid(gui, :M1))
            GUI._check_presence!(gui; now = 700.0)
            @test !isempty(gui.sync.presence)
            plots = copy(gui.sync.presence)
            GUI._presence_closed!(gui)
            @test isempty(gui.sync.presence)
            @test !any(p -> p in gui.ax.scene.plots, plots)
            @test !isfile(own)
            @test isfile(other)
            GUI._presence_closed!(gui)  # a missing file is fine
        end
    end
end

@testset "Presence without a project" begin
    gui = live_view(BeamletOptics.System(); const_kw...)
    @test isnothing(GUI._write_presence!(gui))
    @test isnothing(GUI._check_presence!(gui))
    @test isnothing(GUI._presence_closed!(gui))
    @test isnothing(GUI._writer(gui, "x"))
end

end
