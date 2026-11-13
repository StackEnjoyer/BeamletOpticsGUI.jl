module TestLiveProjectOwnTypes

using GLMakie, BeamletOptics, BeamletOpticsGUI
using BeamletOpticsProjects
using BeamletOptics: render_plots
using Makie
using Test

const GUI = BeamletOpticsGUI
const BMOP = BeamletOpticsProjects
const const_kw = (; trace_budget = Inf, throttle = false, detectors = [])

# An own type with two parameters of its shape that tells its constructor, and one that does not
const BENCH = """
    module Bench
    using BeamletOptics
    import ..BeamletOpticsProjects
    export Block, Plate

    struct Block{T} <: BeamletOptics.AbstractObject{T}
        shape::BeamletOptics.PlanoSurfaceSDF{T}
    end
    Block(width, thickness) = Block(BeamletOptics.PlanoSurfaceSDF(thickness, width))
    BeamletOpticsProjects.constructor_code(b::Block) = "Block(\$(b.shape.diameter), \$(b.shape.thickness))"

    struct Plate{T} <: BeamletOptics.AbstractObject{T}
        shape::BeamletOptics.PlanoSurfaceSDF{T}
    end
    Plate(width) = Plate(BeamletOptics.PlanoSurfaceSDF(0.002, width))
    end
    """

# The window's part: a slider of the width of each
rows(name) = """
    using BeamletOpticsGUI
    using GLMakie: Slider

    width_row(name) = CardRow("width [mm]", CardWidget(Slider; name, range = 10.0:5.0:50.0,
        value = (gui, b) -> 1e3 * b.shape.diameter, on = (gui, b, w) -> (b.shape.diameter = 1e-3 * w),
        solve = true))
    BeamletOpticsGUI.card_rows(b::Block) = (pose_card_rows(b)..., width_row(:$name))
    BeamletOpticsGUI.card_rows(p::Plate) = (pose_card_rows(p)..., width_row(:plate_width))
    """

const SYSTEM = """
    @component K1 = Block(0.025, 0.005) pos = (0.0, 0.1, 0.0)
    @component P1 = Plate(0.02) pos = (0.0, 0.2, 0.0)
    @system S1 = [K1, P1]
    """

"""A project with the own types of `BENCH`, its `src/gui.jl` the text `gui` (none for `nothing`)."""
function project(; gui = rows("width"))
    dir = mktempdir()
    new_project(dir; name = "Bench")
    write(joinpath(dir, "src", "Bench.jl"), BENCH)
    isnothing(gui) || write(joinpath(dir, "src", "gui.jl"), gui)
    write(joinpath(dir, "system.jl"), SYSTEM)
    return dir
end

"""The object of the readable id `id` in the window."""
function obj(gui, id)
    for (x, (name, _)) in gui.sync.ids
        name === id && return x
    end
    return nothing
end

# The line of `id` in `system.jl`, and the width of its object as the files build it
line(dir, id) = only(filter(l -> startswith(l, "@component $id ="), readlines(joinpath(dir, "system.jl"))))
width(dir, id) = only(e for e in BMOP.load_project(dir).entries if e.name === id).object.shape.diameter

handle(gui, x) = only(GUI._pool_handles(gui, x))

"""Two looks of the watcher: the files changed, then settled."""
function tick!(gui)
    t = time()
    first = GUI._check_files!(gui; now = t)
    return first === :pending ? GUI._check_files!(gui; now = t + 1) : first
end

@testset "Own types of a project" begin
    @testset "a change of the shape on the card is drawn, saved and undone" begin
        dir = project()
        gui = open_project(dir; display = false, const_kw...)
        k1 = obj(gui, :K1)
        select!(gui, k1)
        s = card_widget(gui, k1, :width)
        @test s isa Slider
        @test s.value[] == 25.0
        @test isnothing(card_widget(gui, k1, :no_such_widget))
        # no card shows P1
        @test isnothing(card_widget(gui, obj(gui, :P1), :plate_width))
        plot = first(render_plots(handle(gui, k1)))
        Makie.set_close_to!(s, 40.0)
        @test k1.shape.diameter ≈ 0.04
        @test gui.components.origin[k1].code == "Block(0.04, 0.005)"
        @test first(render_plots(handle(gui, k1))) !== plot
        # the steps of a dragged slider are one entry of the history (less than 1 s apart, which the
        # test sets: the first call of each step compiles)
        undo = length(gui.controls.undo_stack)
        step!(v) = (last(gui.controls.undo_stack).obj.time = time(); Makie.set_close_to!(s, v))
        step!(45.0)
        step!(40.0)
        @test length(gui.controls.undo_stack) == undo
        @test GUI._autosave!(gui; force = true) === :saved
        @test startswith(line(dir, :K1), "@component K1 = Block(0.04, 0.005) pos = (0.0, 0.1, 0.0)")
        @test width(dir, :K1) ≈ 0.04
        # Ctrl+Z: built again from the old line, in its place
        plot = first(render_plots(handle(gui, k1)))
        @test GUI._undo!(gui.controls)
        old = obj(gui, :K1)
        @test old !== k1 && old.shape.diameter == 0.025
        @test position(old) == [0.0, 0.1, 0.0]
        @test any(o -> o === old, only(GUI._systems(gui)).objects)
        @test first(render_plots(handle(gui, old))) !== plot
        @test GUI._autosave!(gui; force = true) === :saved
        @test startswith(line(dir, :K1), "@component K1 = Block(0.025, 0.005) pos = (0.0, 0.1, 0.0)")
        @test width(dir, :K1) == 0.025
        # Ctrl+Y: the changed one again
        @test GUI._redo!(gui.controls)
        @test obj(gui, :K1) === k1 && k1.shape.diameter ≈ 0.04
        @test GUI._autosave!(gui; force = true) === :saved
        @test width(dir, :K1) ≈ 0.04
        # a move afterwards keeps the new shape in the line
        translate3d!(gui, k1, [0.0, 0.0, 0.01])
        @test GUI._autosave!(gui; force = true) === :saved
        @test occursin("Block(0.04, 0.005)", line(dir, :K1)) && occursin("0.01", line(dir, :K1))
        close(gui)
    end

    @testset "a type without constructor_code" begin
        dir = project()
        gui = open_project(dir; display = false, const_kw...)
        p1 = obj(gui, :P1)
        select!(gui, p1)
        s = card_widget(gui, p1, :plate_width)
        @test s isa Slider
        undo = length(gui.controls.undo_stack)
        Makie.set_close_to!(s, 30.0)
        @test p1.shape.diameter ≈ 0.03
        note = "changes of the shape of Plate are not saved: it has no `constructor_code`"
        @test gui.status.text[] == note
        @test length(gui.controls.undo_stack) == undo
        # once per type
        gui.status.text[] = "-"
        Makie.set_close_to!(s, 35.0)
        @test gui.status.text[] != note
        @test GUI._autosave!(gui; force = true) === :none
        @test startswith(line(dir, :P1), "@component P1 = Plate(0.02)")
        close(gui)
    end

    @testset "src/gui.jl changes in the files" begin
        dir = project()
        gui = open_project(dir; display = false, const_kw...)
        select!(gui, obj(gui, :K1))
        @test card_widget(gui, obj(gui, :K1), :width) isa Slider
        write(joinpath(dir, "src", "gui.jl"), rows("size"))
        @test tick!(gui) === :applied
        k1 = obj(gui, :K1)
        select!(gui, k1)
        @test card_widget(gui, k1, :size) isa Slider
        @test isnothing(card_widget(gui, k1, :width))
        # the new type takes inputs and saves them
        Makie.set_close_to!(card_widget(gui, k1, :size), 20.0)
        @test GUI._autosave!(gui; force = true) === :saved
        @test width(dir, :K1) ≈ 0.02
        close(gui)
    end

    @testset "src/gui.jl with an error" begin
        dir = project(; gui = "using BeamletOpticsGUI\nerror(\"broken card\")\n")
        gui = open_project(dir; display = false, const_kw...)
        @test gui isa GUI.LiveView
        @test startswith(gui.status.text[], "src/gui.jl:") && occursin("broken card", gui.status.text[])
        k1 = obj(gui, :K1)
        select!(gui, k1)
        @test isnothing(card_widget(gui, k1, :width))
        # the agents' load never includes it
        @test width(dir, :K1) == 0.025
        close(gui)
    end
end

end
