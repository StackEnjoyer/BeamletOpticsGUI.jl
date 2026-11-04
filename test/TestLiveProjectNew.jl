module TestLiveProjectNew

using GLMakie, BeamletOptics, BeamletOpticsGUI
using BeamletOpticsProjects
using Makie
using Test

const BMOP = BeamletOpticsProjects
const GUI = BeamletOpticsGUI

@testset "New project" begin

    # Each change is solved at once, see `TestLiveView.jl`; no card of a detector is pinned at start
    const_kw = (; trace_budget = Inf, throttle = false, detectors = [])

    _entry(name) = only(e for e in component_catalog() if e.name == name)
    _defaults(entry) = String[GUI._catalog_string(p) for p in entry.params]
    _built(name, strings = _defaults(_entry(name))) = GUI._catalog_component(_entry(name), strings)

    # The key that types the letter of `key` in the keyboard layout of this machine, see `_layout_key`
    _typed(key) = first(k for k in Keyboard.Button.(Int(Keyboard.a):Int(Keyboard.z)) if GUI._layout_key(k) == key)
    function _ctrl!(gui, key)
        state = events(gui.ax.scene).keyboardstate
        push!(state, Keyboard.left_control)
        events(gui.ax.scene).keyboardbutton[] = Makie.KeyEvent(_typed(key), Keyboard.press)
        delete!(state, Keyboard.left_control)
        return nothing
    end

    # A view with a mirror in a system and a source without one, from the catalog
    function _setup()
        sys = System()
        gui = live_view(sys; const_kw...)
        m = _built("Round mirror")
        translate3d!(m.obj, [0.0, 0.1, 0.0])
        add_component!(gui, m.obj; system = sys, origin = m.origin, label = "M1", select = false)
        b = _built("Beam")
        add_component!(gui, b.obj; system = :none, origin = b.origin, label = "B1", select = false)
        return (; gui, mirror = m.obj, beam = b.obj)
    end

    path = Ref{Any}("")
    calls = Ref(0)
    dialog = GUI._SAVE_DIALOG[]
    GUI._SAVE_DIALOG[] = dir -> (calls[] += 1; path[])
    # The view of the new project that the task of the dialog returns, else `nothing`
    _new!(gui) = (_ctrl!(gui, Keyboard.n); fetch(GUI._DIALOG_TASK[]))
    try
        @testset "with a project: its pending changes first, then the new one" begin
            parent = mktempdir()
            t = _setup()
            gui = t.gui
            old = joinpath(parent, "bench")
            save_project(gui, old)
            # a change that the autosave has not written yet (the view is not shown)
            translate3d!(gui, t.beam, [0.0, 0.0, 0.01])
            id = first(gui.sync.ids[t.beam])
            @test position(load_project(old)[id]) ≉ position(t.beam)

            # cancelled: nothing happens
            path[] = ""
            @test isnothing(_new!(gui))
            @test calls[] == 1 && gui.project == old && !gui.sync.closed

            # a folder that exists and is not empty is refused
            full = joinpath(parent, "full")
            mkpath(full)
            write(joinpath(full, "notes.txt"), "x")
            path[] = joinpath(parent, "full.bmo")
            @test isnothing(_new!(gui))
            @test calls[] == 2 && gui.project == old && !gui.sync.closed
            @test gui.status.text[] == "project not created: \"$full\" exists already"
            @test readdir(full) == ["notes.txt"]
            # ... and so is the project file of a project
            path[] = joinpath(old, "bench.bmo")
            @test isnothing(_new!(gui))
            @test gui.status.text[] == "project not created: \"$old\" is a project already"
            # no name
            path[] = joinpath(parent, ".bmo")
            @test isnothing(_new!(gui))
            @test gui.status.text[] == "project not created: no name given"
            @test gui.project == old && !gui.sync.closed
            # the changes are still pending
            @test position(load_project(old)[id]) ≉ position(t.beam)

            # a new name: the pending change is written, the empty project made and opened
            path[] = joinpath(parent, "New bench")
            new = _new!(gui)
            dir = joinpath(parent, "New bench")
            @test calls[] == 5
            @test position(load_project(old)[id]) ≈ position(t.beam)
            @test isfile(joinpath(dir, "system.jl")) && isfile(joinpath(dir, "New bench.bmo"))
            @test isfile(joinpath(dir, "src", "New_bench.jl"))
            @test isdir(joinpath(dir, ".claude", "skills", "beamletopticsgui"))
            @test [v.message for v in versions(dir)] == ["New project"]
            p = load_project(dir)
            @test p.name == "New_bench" && isempty(p.entries) && isempty(p.systems)
            # the window shows the empty project, the old one is closed
            @test new isa GUI.LiveView && new !== gui
            @test new.project == dir && new.sync.base.path == dir
            @test isempty(new.sync.ids) && isempty(new.beams.unassigned)
            @test all(s -> isempty(s.objects), GUI._systems(new))
            @test new.status.text[] == "project New_bench opened from $dir"
            @test gui.sync.closed
            # the new project saves like any other
            c = _built("Round mirror")
            add_component!(new, c.obj; origin = c.origin, label = "M1", select = false)
            save_project(new)
            @test length(load_project(dir).entries) == 1
            close(new)
        end

        @testset "without a project: opens the new one" begin
            parent = mktempdir()
            t = _setup()
            gui = t.gui
            # an empty folder is taken
            mkpath(joinpath(parent, "empty"))
            path[] = joinpath(parent, "empty.bmo")
            new = _new!(gui)
            dir = joinpath(parent, "empty")
            @test new isa GUI.LiveView && new.project == dir && gui.sync.closed
            @test isfile(joinpath(dir, "system.jl")) && isfile(joinpath(dir, "empty.bmo"))
            close(new)
        end

        @testset "tool, help and spectator mode" begin
            parent = mktempdir()
            t = _setup()
            gui = t.gui
            @test any(e -> occursin("new project", e.text), only(GUI._PROJECT_HELP).second)
            # the spectator mode ignores the key
            n = calls[]
            gui.controls.spectator[] = true
            _ctrl!(gui, Keyboard.n)
            @test calls[] == n
            gui.controls.spectator[] = false
            # the tool does the same as the key
            path[] = ""
            GUI._new_key!(gui)
            wait(GUI._DIALOG_TASK[])
            @test calls[] == n + 1 && !gui.sync.closed
            close(gui)
        end
    finally
        GUI._SAVE_DIALOG[] = dialog
    end
end

end
