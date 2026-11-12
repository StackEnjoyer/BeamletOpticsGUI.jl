module TestLiveActivityHooks

# The activity of the others in a watched window of a project: episodes of merges and messages,
# and the step per frame that draws the cues and the timeline (see `LiveActivityHooks.jl`)

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
    @component M1 = RoundPlanoMirror(0.0254, 0.006) pos = (0.0, 0.2, 0.0) rot = (0.0, 0.0, 45.0)
    @component M2 = RoundPlanoMirror(0.0254, 0.006) pos = (0.1, 0.2, 0.0) rot = (0.0, 0.0, 45.0)
    @source B1 = Beam([0.0, 0.0, 0.0], [0.0, 1.0, 0.0], 1.0e-6)
    @system S1 = [L1, M1, M2] sources = [B1]
    """

function opened()
    dir = mktempdir()
    new_project(dir; name = "Bench")
    write(joinpath(dir, "system.jl"), START)
    gui = open_project(dir; display = false, const_kw...)
    save_project(gui)
    # as a watched window, without its watcher
    gui.sync.background = true
    return gui, dir
end

"""Writes the presence file of an agent `name`, alive, with `doing` and the stamp `written`."""
function agent!(dir, name; doing = "", selected_id = "", written = "", beat = 1)
    id = "$name@agent"
    file = GUI._presence_file(dir, id)
    mkpath(dirname(file))
    data = Dict{String, Any}("name" => name, "host" => "PC9", "kind" => "agent", "beat" => beat,
        "ttl" => 120, "selected" => "", "selected_id" => selected_id, "written" => written, "doing" => doing)
    open(io -> TOML.print(io, data), file, "w")
    return id
end

"""Lets the window see the files: merges them as the watcher would."""
function merge!(gui)
    t = time()
    GUI._check_files!(gui; now = t)
    return GUI._check_files!(gui; now = t + 1)
end

@testset "the activity of the others in a window" begin
    gui, dir = opened()
    try
        a() = GUI._activity(gui)
        @testset "a move of an agent is an episode" begin
            id = agent!(dir, "claude")
            GUI._check_presence!(gui; now = time())
            BMOP.move!(dir, [:M1]; offset = (0.0, 0.0, 0.012), by = id)
            # the agent publishes the stamp of its write
            agent!(dir, "claude"; written = BMOP.project_stamp(dir), beat = 2, doing = "moved M1")
            GUI._check_presence!(gui; now = time())
            @test merge!(gui) === :applied
            eps = a().episodes
            @test length(eps) == 1
            ep = only(eps)
            @test ep.who == id && ep.name == "claude" && ep.agent
            @test ep.text == "moved M1 by 12 mm"
            item = only(ep.items)
            @test item.change === :moved && item.id === :M1
            @test item.after[1] - item.before[1] ≈ [0.0, 0.0, 0.012]
            @test length(item.frame) == 24
            # the note of the write in `doing` is no message
            @test all(e -> isempty(e.message), eps)
            @test a().seen
        end
        @testset "a message of an agent at its object" begin
            id = agent!(dir, "claude"; doing = "aligning the fold mirror M2", selected_id = "M2", beat = 3)
            GUI._check_presence!(gui; now = time())
            ep = a().episodes[end]
            @test ep.message == "aligning the fold mirror M2"
            @test only(ep.items).id === :M2
            # the same text again is no new message
            agent!(dir, "claude"; doing = "aligning the fold mirror M2", selected_id = "M2", beat = 4)
            GUI._check_presence!(gui; now = time())
            @test length(a().episodes) == 2
        end
        @testset "an unknown writer is named once it publishes its stamp" begin
            BMOP.move!(dir, [:M2]; offset = (0.003, 0.0, 0.0))
            @test merge!(gui) === :applied
            ep = a().episodes[end]
            @test ep.who == "agent" && ep.text == "moved M2 by 3 mm"
            agent!(dir, "claude"; written = BMOP.project_stamp(dir), beat = 5)
            GUI._check_presence!(gui; now = time())
            @test a().episodes[end].name == "claude"
            @test a().episodes[end].n == ep.n
        end
        @testset "the step per frame: cues and the timeline" begin
            screen = GLMakie.Screen(; visible = false, start_renderloop = false)
            try
                display(screen, gui.fig)
                for _ in 1:3
                    GUI._activity_tick!(gui)
                    Makie.colorbuffer(screen)
                end
                @test !isnothing(a().strip)
                @test !isnothing(a().cue_plots)
                # a mark under the mouse plays its cue again
                n = a().episodes[1].n
                a().hover = n
                GUI._activity_tick!(gui)
                @test any(c -> c[1].n == n, a().cues)
                # the scrub shows ghosts until it ends
                a().cursor = a().episodes[1].t - 1
                GUI._activity_tick!(gui)
                @test a().shown_cursor == a().cursor
                a().cursor = nothing
                GUI._activity_tick!(gui)
                Makie.colorbuffer(screen)
                @test isnothing(a().shown_cursor)
                # the toast of the compact layout stands above the shown timeline
                if gui isa GUI.CompactView && a().strip.shown
                    lift = get(GUI._TOAST_LIFT, gui.layout.overlay, 0.0f0)
                    @test lift > 0
                    @test GUI._TOAST_LIFT[gui.layout.overlay] + minimum(gui.ax.scene.viewport[])[2] >=
                          maximum(a().strip.rect)[2] - GUI._OVERLAY_MARGIN
                end
            finally
                close(screen)
            end
        end
    finally
        close(gui)
    end
end

end
