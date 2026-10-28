module TestLiveProjectClaims

using GLMakie, BeamletOptics, BeamletOpticsGUI
using BeamletOpticsProjects
using Makie
using Test

const GUI = BeamletOpticsGUI
const BMOP = BeamletOpticsProjects
const TOML = GUI.TOML  # the TOML of the package, not a dependency of the tests
const const_kw = (; trace_budget = Inf, throttle = false, detectors = [])

const START = """
    @component L1 = SphericalLens(0.05, -0.05, 0.005, 0.0254, 1.5) pos = (0.0, 0.1, 0.0)
    @component M1 = RoundPlanoMirror(0.0254, 0.006) pos = (0.0, 0.2, 0.0)
    @component M2 = RoundPlanoMirror(0.0254, 0.006) pos = (0.05, 0.2, 0.0)
    @source B1 = Beam([0.0, 0.0, 0.0], [0.0, 1.0, 0.0], 1.0e-6)
    @system S1 = [L1, M1, M2] sources = [B1]
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

"""Writes the presence file of an other participant `id` by hand, alive for the claims."""
function other!(dir, id; name = id, beat = 1)
    file = GUI._presence_file(dir, id)
    mkpath(dirname(file))
    data = Dict{String, Any}("name" => name, "host" => "PC9", "beat" => beat, "selected" => "",
        "selected_id" => "", "written" => "")
    open(io -> TOML.print(io, data), file, "w")
    return file
end

"""One look of the window, with the run of the claims in the background done and taken."""
function look!(gui; now = time())
    c = GUI._claims(gui)
    # the claims of the others are read again, not only after `_CLAIM_READ`
    c.run_at = -Inf
    GUI._check_presence!(gui; now)
    isnothing(c.task) || wait(c.task)
    GUI._claims_tick!(gui; now)
    isnothing(c.task) || wait(c.task)
    GUI._claims_tick!(gui; now)
    GUI._draw_presence!(gui, now)
    return gui
end

pose(x) = (Vector{Float64}(position(x)), Matrix{Float64}(BeamletOptics.orientation(x)))

mine(dir, me) = sort!([String(c.id) for c in values(BMOP.claims(dir)) if c.by == me])

@testset "Claims of the people" begin
    withenv("BMO_PERSON" => "anna") do
        gui, dir = opened()
        me = GUI._person().id
        ctrl = gui.controls
        L1, M1, M2 = obj(gui, :L1), obj(gui, :M1), obj(gui, :M2)
        other!(dir, "bob@PC9"; name = "Bob")
        @test BMOP.claim!(dir; by = "bob@PC9", ids = [:L1])
        look!(gui)
        @test haskey(GUI._claims(gui).others, uid(gui, :L1))
        @test GUI._claimed_by(gui, L1) == "Bob"
        @test isnothing(GUI._claimed_by(gui, M1))

        @testset "gestures on a claimed object are refused" begin
            P = pose(L1)
            ctrl.selected[] = L1
            # a key step
            gui.status.text[] = ""
            @test GUI._key_step!(ctrl, L1, Keyboard.up, 1)
            @test pose(L1) == P
            @test gui.status.text[] == "Bob is editing L1"
            # a drag: the press on the selected object crosses the threshold of a drag
            gui.status.text[] = ""
            scene = gui.ax.scene
            events(scene).mouseposition[] = (100.0, 100.0)
            ctrl.press_kind = :pending_drag
            ctrl.press_pos = ctrl.last_mouse = (100.0, 100.0)
            ctrl.plane_point = Vector{Float64}(position(L1))
            ctrl.grab_offset = zeros(3)
            events(scene).mouseposition[] = (160.0, 170.0)
            @test !ctrl.dragging
            @test ctrl.press_kind == :none
            @test pose(L1) == P
            @test gui.status.text[] == "Bob is editing L1"
            events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.release)
            @test pose(L1) == P
            # a pose on the card
            gui.status.text[] = ""
            GUI._apply_pose_input!(gui, L1, 1, "5")
            @test pose(L1) == P
            @test gui.status.text[] == "Bob is editing L1"
            # "Apply" of the page "Edit"
            gui.status.text[] = ""
            GUI._apply_edit!(gui, L1; read = false)
            @test obj(gui, :L1) === L1
            @test gui.status.text[] == "Bob is editing L1"
            # remove
            gui.status.text[] = ""
            @test !GUI._remove_selected!(gui, L1)
            @test obj(gui, :L1) === L1
            @test gui.status.text[] == "Bob is editing L1"
            gui.status.text[] = ""
            # of several, the others are removed; here M2 (and undone again)
            @test GUI._remove_selected!(gui, GUI._MultiSelection(Any[L1, M2]))
            @test obj(gui, :L1) === L1
            @test occursin("Bob is editing L1", gui.status.text[])
            @test GUI._undo!(ctrl)
            @test any(o -> o === M2, keys(gui.sync.ids))
            # Ctrl+G
            gui.status.text[] = ""
            @test isnothing(GUI._group!(gui, GUI._MultiSelection(Any[L1, M1])))
            @test gui.status.text[] == "Bob is editing L1"
            # an undo onto it stays in the history
            GUI._push_history!(ctrl, L1, Point3{Float64}(P[1] .+ 0.01), P[2], Point3{Float64}(P[1]), P[2])
            n = length(ctrl.undo_stack)
            @test !GUI._undo!(ctrl)
            @test length(ctrl.undo_stack) == n && isempty(ctrl.redo_stack)
            @test pose(L1) == P
            # The refused gestures claimed nothing; the undo of the removal of M2 claimed M2
            @test collect(values(GUI._claims(gui).held)) == [:M2]
            GUI._release!(gui)
        end

        @testset "the lock at the claimed object" begin
            c = GUI._claims(gui)
            @test length(c.locks) == 1
            lock = only(c.locks)
            @test lock isa Scatter
            bb = GUI._part_box(gui, L1)
            @test lock[1][] == [maximum(GUI._bbox_wireframe(bb))]
            labels = [GUI._label_text(p) for p in gui.sync.presence if p isa Makie.Text]
            @test labels == ["Bob · editing"]
            # hidden in the spectator mode
            GUI._set_spectator!(ctrl, true)
            GUI._draw_presence!(gui, time())
            @test !lock.visible[]
            GUI._set_spectator!(ctrl, false)
            GUI._draw_presence!(gui, time())
            @test lock.visible[]
        end

        @testset "no file access in the handlers" begin
            calls = Task[]
            GUI._CLAIM_FILES[] = function (args...)
                push!(calls, current_task())
                return GUI._claim_files(args...)
            end
            try
                ctrl.selected[] = M1
                P = pose(M1)
                @test GUI._key_step!(ctrl, M1, Keyboard.up, 1)
                @test pose(M1) != P
                GUI._apply_pose_input!(gui, M1, 3, "1")
                @test isempty(calls)
                # the claim is queued and written by the run in the background
                @test haskey(GUI._claims(gui).held, uid(gui, :M1))
                t = GUI._claims_tick!(gui)
                @test t isa Task
                wait(t)
                @test length(calls) == 1 && only(calls) !== current_task()
            finally
                GUI._CLAIM_FILES[] = GUI._claim_files
            end
            GUI._claims_tick!(gui)
            @test mine(dir, me) == ["M1"]
            # published in the presence
            @test GUI._presence_data(gui).data["claimed"] == [uid(gui, :M1)]
        end

        @testset "released on deselect and after the hold" begin
            look!(gui)
            @test mine(dir, me) == ["M1"]
            # another object: M1 is released, nothing claimed until a gesture
            ctrl.selected[] = M2
            look!(gui)
            @test isempty(mine(dir, me))
            @test GUI._gesture!(gui, M2; now = 1000.0)
            look!(gui; now = 1000.1)
            @test mine(dir, me) == ["M2"]
            # each gesture holds it longer
            @test GUI._gesture!(gui, M2; now = 1000.0 + GUI._CLAIM_HOLD - 1)
            look!(gui; now = 1000.0 + GUI._CLAIM_HOLD)
            @test mine(dir, me) == ["M2"]
            look!(gui; now = 1000.0 + 2 * GUI._CLAIM_HOLD)
            @test isempty(mine(dir, me))
            @test isempty(GUI._claims(gui).held)
            # deselect
            @test GUI._gesture!(gui, M2)
            look!(gui)
            @test mine(dir, me) == ["M2"]
            ctrl.selected[] = nothing
            look!(gui)
            @test isempty(mine(dir, me))
        end

        @testset "a group claims its members" begin
            ctrl.selected[] = nothing
            g = GUI._group!(gui, GUI._MultiSelection(Any[M1, M2]))
            @test !isnothing(g)
            @test ctrl.selected[] === g
            look!(gui)
            @test mine(dir, me) == ["M1", "M2"]
            # the other window sees them as claimed by anna
            ctrl.selected[] = nothing
            look!(gui)
            @test isempty(mine(dir, me))
            # the dot of its pivot is dragged like the group
            @test BMOP.claim!(dir; by = "bob@PC9", ids = [:M1])
            look!(gui)
            ctrl.selected[] = g
            P = Vector{Float64}(position(g))
            @test !GUI._start_pivot_drag!(gui)
            @test isnothing(gui.components.pivot_marker.drag)
            @test gui.status.text[] == "Bob is editing M1"
            @test Vector{Float64}(position(g)) == P
            BMOP.release!(dir; by = "bob@PC9")
            look!(gui)
            @test GUI._start_pivot_drag!(gui)
            GUI._end_pivot_drag!(gui)
            look!(gui)
            @test mine(dir, me) == ["M1", "M2"]
            ctrl.selected[] = nothing
            look!(gui)
            @test isempty(mine(dir, me))
        end

        @testset "claimed first by another" begin
            @test BMOP.claim!(dir; by = "bob@PC9", ids = [:M1])
            # the window did not read it yet: the gesture runs, the claim is refused in the background
            @test isnothing(GUI._claimed_by(gui, M1))
            ctrl.selected[] = M1
            @test GUI._gesture!(gui, M1)
            look!(gui)
            @test gui.status.text[] == "Bob is editing M1"
            @test isempty(GUI._claims(gui).held)
            @test GUI._claimed_by(gui, M1) == "Bob"
            BMOP.release!(dir; by = "bob@PC9")
            look!(gui)
            @test isnothing(GUI._claimed_by(gui, M1))
            @test isnothing(GUI._claimed_by(gui, L1))
            @test isempty(GUI._claims(gui).locks)
        end

        @testset "a drag holds its claims" begin
            ctrl.selected[] = M2
            @test GUI._gesture!(gui, M2; now = 2000.0)
            look!(gui; now = 2000.1)
            @test mine(dir, me) == ["M2"]
            # longer than the hold after its start
            ctrl.dragging = true
            look!(gui; now = 2000.0 + 2 * GUI._CLAIM_HOLD)
            @test mine(dir, me) == ["M2"]
            # held from its end on
            ctrl.dragging = false
            look!(gui; now = 2000.0 + 2.5 * GUI._CLAIM_HOLD)
            @test mine(dir, me) == ["M2"]
            look!(gui; now = 2000.0 + 3.5 * GUI._CLAIM_HOLD)
            @test isempty(mine(dir, me))
            ctrl.selected[] = nothing
        end

        @testset "rename, the system card, aim and align are gestures" begin
            S1, B1 = obj(gui, :S1), obj(gui, :B1)
            @test BMOP.claim!(dir; by = "bob@PC9", ids = [:L1, :B1, :S1])
            look!(gui)
            # the pencil of a card
            gui.status.text[] = ""
            GUI._rename_object!(gui, L1, "collimator")
            @test GUI._label(gui, L1) == "L1"
            @test gui.status.text[] == "Bob is editing L1"
            gui.status.text[] = ""
            GUI._rename_system!(gui, S1, "bench")
            @test GUI._label(gui, S1) == "S1"
            @test gui.status.text[] == "Bob is editing S1"
            # "+" and "Remove system" of the card of the system
            GUI._inspect!(gui, S1)
            card = gui isa GUI.AppView ? gui.layout.inspector.card : gui.cards.selection
            push(name) = (GUI._card_widget(card, name).clicks[] += 1; nothing)
            gui.status.text[] = ""
            push(:member_add)
            @test isnothing(GUI._member_pick(gui))
            @test gui.status.text[] == "Bob is editing S1"
            push(:remove)
            @test !isnothing(GUI._system_handle(gui, S1))
            # the click that aims a source, also when it was claimed after the aiming started
            P = GUI._pose(B1)
            gui.status.text[] = ""
            @test !GUI._aim!(gui, B1, [0.1, 0.1, 0.0])
            @test GUI._pose(B1) == P
            @test gui.status.text[] == "Bob is editing B1"
            # "onto beam" and "face beam"
            P = pose(L1)
            gui.status.text[] = ""
            @test !GUI._center_on_beam!(gui, L1)
            @test gui.status.text[] == "Bob is editing L1"
            gui.status.text[] = ""
            @test !GUI._face_beam!(gui, L1)
            @test gui.status.text[] == "Bob is editing L1"
            @test pose(L1) == P
            @test isempty(GUI._claims(gui).held)
            # released: the rename claims
            BMOP.release!(dir; by = "bob@PC9")
            look!(gui)
            GUI._rename_object!(gui, L1, "collimator")
            @test GUI._label(gui, L1) == "collimator"
            @test haskey(GUI._claims(gui).held, uid(gui, :L1))
            GUI._release!(gui)
            ctrl.selected[] = nothing
            look!(gui)
            @test isempty(mine(dir, me))
        end

        @testset "undo and redo of an edit ask the claims" begin
            entry = only(e for e in component_catalog() if e.name == "Thin lens")
            c = GUI._catalog_component(entry, String[GUI._catalog_string(p) for p in entry.params])
            lens = c.obj
            add_component!(gui, lens; origin = c.origin)
            save_project(gui)
            id, u = gui.sync.ids[lens]
            s = GUI._edit_strings(gui, lens)[1]
            GUI._set_edit_string!(gui, lens, 1, string(2 * parse(Float64, s)))
            GUI._apply_edit!(gui, lens; read = false)
            new = obj(gui, id)
            @test new !== lens
            @test GUI._undo!(ctrl)
            @test obj(gui, id) === lens
            ctrl.selected[] = nothing
            look!(gui)
            @test isempty(mine(dir, me))
            @test BMOP.claim!(dir; by = "bob@PC9", ids = [id])
            look!(gui)
            # the replacement is not done again, and stays in the history
            gui.status.text[] = ""
            @test !GUI._redo!(ctrl)
            @test obj(gui, id) === lens
            @test gui.status.text[] == "Bob is editing $id"
            @test length(ctrl.redo_stack) == 1
            @test isempty(GUI._claims(gui).held)
            BMOP.release!(dir; by = "bob@PC9")
            look!(gui)
            @test GUI._redo!(ctrl)
            @test obj(gui, id) === new
            @test haskey(GUI._claims(gui).held, u)
            ctrl.selected[] = nothing
            look!(gui)
            @test isempty(mine(dir, me))
        end

        @testset "a window of open_system claims for the project" begin
            S1 = obj(gui, :S1)
            win = open_system(gui, S1; display = false)
            try
                @test GUI._project_view(win) === gui
                @test BMOP.claim!(dir; by = "bob@PC9", ids = [:L1])
                look!(gui)
                P = pose(L1)
                win.status.text[] = ""
                @test !GUI._gesture!(win, L1)
                @test win.status.text[] == "Bob is editing L1"
                @test GUI._key_step!(win.controls, L1, Keyboard.up, 1)
                @test pose(L1) == P
                @test GUI._claimed_by(win, L1) == "Bob"
                # a gesture there claims for the project
                win.controls.selected[] = M1
                @test GUI._gesture!(win, M1)
                @test haskey(GUI._claims(gui).held, uid(gui, :M1))
                look!(gui)
                @test mine(dir, me) == ["M1"]
                # a drag there holds it
                win.controls.dragging = true
                look!(gui; now = time() + 2 * GUI._CLAIM_HOLD)
                @test mine(dir, me) == ["M1"]
                win.controls.dragging = false
                # kept while it is selected in either window
                ctrl.selected[] = nothing
                look!(gui)
                @test mine(dir, me) == ["M1"]
                win.controls.selected[] = nothing
                look!(gui)
                @test isempty(mine(dir, me))
                BMOP.release!(dir; by = "bob@PC9")
                look!(gui)
            finally
                GUI._unlink!(win)
                close(win)
            end
        end

        @testset "a gesture lands a glide first" begin
            P, R = pose(M1)
            origin = gui.components.origin[M1]
            rec = haskey(origin, :project) ? origin.project : (; pos = nothing, rot = nothing)
            # halfway of a glide to the pose of the files
            glide!() = begin
                translate3d!(M1, [0.0, 0.0, 0.005])
                gui.sync.gliding[M1] = (Point3{Float64}(P), Matrix{Float64}(R), (; rec.pos, rec.rot))
                return nothing
            end
            glide!()
            ctrl.selected[] = M1
            @test GUI._gesture!(gui, M1)
            @test isempty(gui.sync.gliding)
            @test pose(M1)[1] ≈ P
            # a drag starts from the pose of the files, which its undo gives back
            glide!()
            scene = gui.ax.scene
            events(scene).mouseposition[] = (100.0, 100.0)
            ctrl.press_kind = :pending_drag
            ctrl.press_pos = ctrl.last_mouse = (100.0, 100.0)
            ctrl.plane_point = Vector{Float64}(position(M1))
            ctrl.grab_offset = zeros(3)
            events(scene).mouseposition[] = (160.0, 170.0)
            @test ctrl.dragging
            @test isempty(gui.sync.gliding)
            @test ctrl.drag_start[1] ≈ P
            events(scene).mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.release)
            @test GUI._undo!(ctrl)
            @test pose(M1)[1] ≈ P
            # a glide of another object goes on
            gui.sync.gliding[M2] = (Point3{Float64}(pose(M2)[1]), pose(M2)[2], (; rec.pos, rec.rot))
            @test GUI._gesture!(gui, M1)
            @test haskey(gui.sync.gliding, M2)
            empty!(gui.sync.gliding)
            ctrl.selected[] = nothing
            look!(gui)
        end

        @testset "the claims leave the presence file to the window" begin
            look!(gui)
            file = GUI._presence_file(dir, me)
            @test isfile(file)
            before = read(file, String)
            r = GUI._claim_files(dir, me, Dict(uid(gui, :M2) => :M2), Dict{String, Symbol}())
            @test r.filed == Dict(uid(gui, :M2) => :M2)
            @test read(file, String) == before
            GUI._claim_files(dir, me, Dict{String, Symbol}(), r.filed)
            @test isempty(mine(dir, me))
        end

        @testset "released at closing" begin
            @test GUI._gesture!(gui, M1)
            look!(gui)
            @test mine(dir, me) == ["M1"]
            GUI._presence_closed!(gui)
            @test isempty(mine(dir, me))
        end
        close(gui)
    end
end

end
