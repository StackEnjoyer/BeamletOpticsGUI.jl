module TestLiveProjectGroups

using GLMakie, BeamletOptics, BeamletOpticsGUI
using BeamletOpticsProjects
using Makie
using LinearAlgebra: norm
using Test

const BMO = BeamletOptics
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

"""A project with `text`, opened (not shown) and saved once, so that every line has a uid."""
function opened(text = START)
    dir = mktempdir()
    new_project(dir; name = "Bench")
    write(joinpath(dir, "system.jl"), text)
    gui = open_project(dir; display = false, const_kw...)
    save_project(gui)
    return gui, dir
end

system_text(dir) = read(joinpath(dir, "system.jl"), String)
reopen(dir) = open_project(dir; display = false, const_kw...)

"""The object of the readable id `id` in the window."""
function obj(gui, id)
    for (x, (name, _)) in gui.sync.ids
        name === id && return x
    end
    return nothing
end

"""The line of `id` in `text`."""
id_line(text, id) = only(l for l in split(text, "\n") if occursin(Regex("^@\\w+ $id = "), l))

"""The autosave of a change: it waits for the change to settle, then saves."""
function autosave!(gui)
    t = time()
    first = GUI._autosave!(gui; now = t)
    first === :saved && return first
    return GUI._autosave!(gui; now = t + 1)
end

ev(gui) = events(gui.ax.scene)
# The key that types the letter of `key` in the keyboard layout of this machine, see `_layout_key`
_typed(key) = first(k for k in Keyboard.Button.(Int(Keyboard.a):Int(Keyboard.z)) if GUI._layout_key(k) == key)
function _chord!(gui, key, mods...)
    state = ev(gui).keyboardstate
    foreach(m -> push!(state, m), mods)
    ev(gui).keyboardbutton[] = Makie.KeyEvent(_typed(key), Keyboard.press)
    foreach(m -> delete!(state, m), mods)
    return nothing
end
ctrl_g!(gui) = _chord!(gui, Keyboard.g, Keyboard.left_control)
ctrl_shift_g!(gui) = _chord!(gui, Keyboard.g, Keyboard.left_control, Keyboard.left_shift)

_in(o, list) = any(x -> x === o, list)
_pose(o) = (Vector{Float64}(BMO.position(o)), Matrix{Float64}(BMO.orientation(o)))
_same_pose(a, b; tol = 1e-12) = norm(a[1] - b[1]) <= tol && norm(a[2] - b[2]) <= tol

"""The poses of the objects of the readable `ids` in the window."""
poses(gui, ids) = Dict(id => _pose(obj(gui, id)) for id in ids)

@testset "Groups in projects" begin

    @testset "Ctrl+G, autosave, reopen, Ctrl+Shift+G" begin
        gui, dir = opened()
        l1, m1, d1 = obj(gui, :L1), obj(gui, :M1), obj(gui, :D1)
        sys = obj(gui, :S1)
        select!(gui, [l1, m1])
        ctrl_g!(gui)
        g = gui.controls.selected[]
        @test g isa ObjectGroup && GUI._is_window_group(gui, g)
        # turned and moved as a whole: the group has its own axes
        rotate3d!(gui, g, [0.0, 0.0, 1.0], deg2rad(10))
        translate3d!(gui, g, [0.01, 0.0, 0.0])
        @test autosave!(gui) === :saved
        text = system_text(dir)
        # no member line is missing, the system lists the group
        for id in (:L1, :M1, :D1, :B1)
            @test any(l -> occursin(Regex("^@(component|source) $id = "), l), split(text, "\n"))
        end
        @test startswith(id_line(text, "G1"), "@group G1 = [L1, M1] pos = ")
        @test occursin("rot = (0.0, 0.0, 10.0)", id_line(text, "G1"))
        @test occursin(r"^@system S1 = \[D1, G1\]", id_line(text, "S1"))
        @test !occursin(r"\bL1\b", id_line(text, "S1")) && !occursin(r"\bM1\b", id_line(text, "S1"))
        @test obj(gui, :G1) === g
        # the window and the files agree: nothing to save
        @test GUI._autosave!(gui) === :none
        before = poses(gui, (:L1, :M1, :D1, :G1))
        pivot = Vector{Float64}(BMO.position(g))

        gui2 = reopen(dir)
        g2 = obj(gui2, :G1)
        @test g2 isa ObjectGroup && GUI._is_window_group(gui2, g2)
        @test isnothing(gui2.components.origin[g2])
        @test Tuple(BMO.objects(g2)) == (obj(gui2, :L1), obj(gui2, :M1))
        sys2 = obj(gui2, :S1)
        @test _in(g2, sys2.objects) && !_in(obj(gui2, :L1), sys2.objects) &&
              !_in(obj(gui2, :M1), sys2.objects) && _in(obj(gui2, :D1), sys2.objects)
        @test Vector{Float64}(BMO.position(g2)) == pivot
        after = poses(gui2, (:L1, :M1, :D1, :G1))
        @test all(id -> _same_pose(before[id], after[id]), keys(before))
        # the members keep their origins: they are saved again as they are
        @test !isnothing(gui2.components.origin[obj(gui2, :L1)])
        @test GUI._autosave!(gui2) === :none
        # the selected group and a selected member have their ids
        select!(gui2, g2)
        @test GUI._presence_selected(gui2) == (gui2.sync.ids[g2][2], "G1")
        @test startswith(GUI._session_selected(gui2), "G1 (ObjectGroup) at ")
        select!(gui2, obj(gui2, :L1))
        @test GUI._presence_selected(gui2)[2] == "L1"

        # Ctrl+Shift+G ungroups it, the next save writes the members into the system again
        select!(gui2, g2)
        ctrl_shift_g!(gui2)
        @test _in(obj(gui2, :L1), sys2.objects) && _in(obj(gui2, :M1), sys2.objects) &&
              !_in(g2, sys2.objects)
        @test !GUI._is_window_group(gui2, g2)
        @test autosave!(gui2) === :saved
        text = system_text(dir)
        @test !occursin("@group", text)
        line = id_line(text, "S1")
        @test occursin(r"\bL1\b", line) && occursin(r"\bM1\b", line) && occursin(r"\bD1\b", line)
        close(gui2)
        close(gui)
    end

    @testset "a group inside a group" begin
        gui, dir = opened()
        l1, m1, d1 = obj(gui, :L1), obj(gui, :M1), obj(gui, :D1)
        inner = GUI._group!(gui, GUI._MultiSelection(Any[l1, m1]))
        outer = GUI._group!(gui, GUI._MultiSelection(Any[inner, d1]))
        @test GUI._is_window_group(gui, outer) && _in(inner, BMO.objects(outer))
        rotate3d!(gui, outer, [1.0, 0.0, 0.0], deg2rad(20))
        @test autosave!(gui) === :saved
        text = system_text(dir)
        @test startswith(id_line(text, "G1"), "@group G1 = [L1, M1] pos = ")
        @test startswith(id_line(text, "G2"), "@group G2 = [G1, D1] pos = ")
        # inner groups first
        @test findfirst("@group G1", text)[1] < findfirst("@group G2", text)[1]
        @test occursin(r"^@system S1 = \[G2\]", id_line(text, "S1"))
        before = poses(gui, (:L1, :M1, :D1, :G1, :G2))
        @test GUI._autosave!(gui) === :none

        gui2 = reopen(dir)
        g1, g2 = obj(gui2, :G1), obj(gui2, :G2)
        @test GUI._is_window_group(gui2, g1) && GUI._is_window_group(gui2, g2)
        @test Tuple(BMO.objects(g2)) == (g1, obj(gui2, :D1))
        @test Tuple(BMO.objects(g1)) == (obj(gui2, :L1), obj(gui2, :M1))
        @test obj(gui2, :S1).objects == Any[g2]
        after = poses(gui2, (:L1, :M1, :D1, :G1, :G2))
        @test all(id -> _same_pose(before[id], after[id]), keys(before))
        @test GUI._autosave!(gui2) === :none
        # a part of the group has the id of the innermost item with one
        select!(gui2, g1)
        @test GUI._presence_selected(gui2)[2] == "G1"
        # the outer one is ungrouped: the inner one is a top-level object of the system
        select!(gui2, g2)
        ctrl_shift_g!(gui2)
        @test _in(g1, obj(gui2, :S1).objects) && _in(obj(gui2, :D1), obj(gui2, :S1).objects)
        @test autosave!(gui2) === :saved
        text = system_text(dir)
        @test !occursin("@group G2", text) && occursin("@group G1 = [L1, M1]", text)
        # and the inner one too
        select!(gui2, g1)
        ctrl_shift_g!(gui2)
        @test autosave!(gui2) === :saved
        @test !occursin("@group", system_text(dir))
        close(gui2)
        close(gui)
    end

    @testset "a group without a system, written by an agent" begin
        text = START * """
            @component L2 = $LENS pos = (0.1, 0.1, 0.0) rot = (0.0, 0.0, 90.0)
            @component M2 = RoundPlanoMirror(0.0254, 0.006) pos = (0.1, 0.2, 0.0)
            @group G1 = [L2, M2] pos = (0.1, 0.15, 0.0) rot = (0.0, 0.0, 30.0) label = "Spare pair"
            """
        gui, dir = opened(text)
        g = obj(gui, :G1)
        @test GUI._is_window_group(gui, g) && gui.labels[g] == "Spare pair"
        @test isempty(GUI._member_systems(gui, g))
        @test GUI._shown_top(gui, g) && !GUI._shown_top(gui, obj(gui, :L2))
        @test BMO.position(obj(gui, :L2)) == [0.1, 0.1, 0.0]
        @test norm(BMO.orientation(g) - BeamletOpticsProjects.rotation_matrix((0.0, 0.0, 30.0))) < 1e-12
        # saved once by `opened` with the same lines
        written = system_text(dir)
        @test occursin("@group G1 = [L2, M2] pos = (0.1, 0.15, 0.0) rot = (0.0, 0.0, 30.0) label = \"Spare pair\" uid = ", written)
        @test GUI._autosave!(gui) === :none
        # Ctrl+Shift+G: the members are objects without a system
        select!(gui, g)
        ctrl_shift_g!(gui)
        @test GUI._shown_top(gui, obj(gui, :L2)) && GUI._shown_top(gui, obj(gui, :M2))
        @test autosave!(gui) === :saved
        written = system_text(dir)
        @test !occursin("@group", written) && occursin("@component L2 = ", written)
        close(gui)
    end

    @testset "a pasted group" begin
        GUI._CLIPBOARD[] = nothing
        entry(name) = only(e for e in component_catalog() if e.name == name)
        defaults(e) = String[GUI._catalog_string(p) for p in e.params]
        built(name) = GUI._catalog_component(entry(name), defaults(entry(name)))
        sys = System()
        gui = live_view(sys => Beam([0.0, 0, 0], [0.0, 1, 0], 632.8e-9); const_kw...)
        lens, mirror = built("Thin lens"), built("Round mirror")
        translate3d!(lens.obj, [0.0, 0.1, 0.0])
        translate3d!(mirror.obj, [0.0, 0.2, 0.0])
        add_component!(gui, lens.obj; origin = lens.origin, select = false)
        add_component!(gui, mirror.obj; origin = mirror.origin, select = false)
        g = GUI._group!(gui, GUI._MultiSelection(Any[lens.obj, mirror.obj]))
        rotate3d!(gui, g, [0.0, 0.0, 1.0], deg2rad(15))
        select!(gui, g)
        @test !isnothing(GUI._copy_selected!(gui))
        pasted = GUI._paste!(gui)
        @test pasted isa ObjectGroup
        GUI._drop_placement!(gui)
        @test _in(pasted, sys.objects) && GUI._is_window_group(gui, pasted)
        dir = mktempdir()
        save_project(gui, dir)
        text = system_text(dir)
        @test count("@group", text) == 2 && count("@component", text) == 4
        @test occursin(r"^@system S1 = \[G1, G2\]", id_line(text, "S1"))
        ids = Dict(first(v) => x for (x, v) in gui.sync.ids)
        before = Dict(id => _pose(x) for (id, x) in ids if !(x isa BMO.AbstractSystem) && !(x isa Beam))
        GUI._CLIPBOARD[] = nothing

        gui2 = reopen(dir)
        for (id, pose) in before
            @test _same_pose(pose, _pose(obj(gui2, id)))
        end
        p2 = obj(gui2, Symbol(only(id for (id, x) in ids if x === pasted)))
        @test GUI._is_window_group(gui2, p2) && length(BMO.objects(p2)) == 2
        # the members of the catalog stay editable and can be copied
        @test all(m -> haskey(gui2.components.origin[m], :entry), BMO.objects(p2))
        @test GUI._autosave!(gui2) === :none
        select!(gui2, p2)
        ctrl_shift_g!(gui2)
        @test all(m -> _in(m, obj(gui2, :S1).objects), BMO.objects(p2))
        close(gui2)
        close(gui)
    end
end

end
