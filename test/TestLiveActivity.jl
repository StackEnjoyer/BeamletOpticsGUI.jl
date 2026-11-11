module TestLiveActivity

using GLMakie, BeamletOptics, BeamletOpticsGUI
using Makie
using Test

const BMO = BeamletOptics
const GUI = BeamletOpticsGUI
const R0 = [1.0 0 0; 0 1 0; 0 0 1]

@testset "Live activity" begin

    # `live_view` does not display the window by itself
    _gui(; theme = :light) = live_view(BMO.System(); theme)

    # an item of the line `key` moved from x = `a` to x = `b` (`nothing`: did not exist)
    _item(key, a, b; change = :moved) = GUI._ActivityItem(key, Symbol(key), change,
        a === nothing ? nothing : ([Float64(a), 0.0, 0.0], R0),
        b === nothing ? nothing : ([Float64(b), 0.0, 0.0], R0),
        fill(Point3f(something(b, a), 0, 0), 24))
    _rec!(gui, who, t, items = [_item("L1", 0, 1)]; agent = true, message = "") =
        GUI._record_episode!(gui, who, who, agent, items; text = "moved", message, now = t)
    _shown(cues) = [ep.n for (ep, _) in cues]

    @testset "pacing (the trace of the plan)" begin
        gui = _gui()
        a = GUI._activity(gui)
        @test !a.seen
        @test GUI._activity_step!(gui, 0.0) == Tuple{GUI._Episode, Float64}[]

        # t = 0: episode 1 starts at once
        ep = _rec!(gui, "claude@agent", 0.0)
        @test ep.n == 1 && ep.count == 1
        @test a.seen
        @test a.queue == [1]
        cues = GUI._activity_step!(gui, 0.0)
        @test isempty(a.queue)
        @test _shown(cues) == [1]
        @test last(cues[1]) == 0.0

        # t = 0.1: episodes 2, 3 wait, the slot is not over
        _rec!(gui, "claude@agent", 0.1)
        _rec!(gui, "claude@agent", 0.1)
        cues = GUI._activity_step!(gui, 0.1)
        @test a.queue == [2, 3]
        @test _shown(cues) == [1]
        @test last(cues[1]) ≈ 0.1

        cues = GUI._activity_step!(gui, 0.9)
        @test a.queue == [3]
        @test _shown(cues) == [1, 2]

        cues = GUI._activity_step!(gui, 1.8)
        @test isempty(a.queue)
        @test _shown(cues) == [1, 2, 3]
        @test last.(cues) ≈ [1.8, 0.9, 0.0]

        # t = 2.0 … 2.4: an agent, episodes 4 … 40; the episode k changes the line "L(k % 9)" from
        # x = k to x = k + 1
        for (j, t) in enumerate(range(2.0, 2.4; length = 37))
            k = j + 3
            _rec!(gui, "claude@agent", t, [_item("L$(k % 9)", k, k + 1)])
            cues = GUI._activity_step!(gui, t)
            @test _shown(cues) == [1, 2, 3]
        end
        @test a.queue == collect(4:40)

        # t = 2.7: 4 starts, the oldest waiting (5) is 0.7 s behind
        cues = GUI._activity_step!(gui, 2.7)
        @test a.queue == collect(5:40)
        @test _shown(cues) == [1, 2, 3, 4]

        # The oldest waiting (5, seen at 2.011) is more than 3 s behind from 5.012 on (the plan's
        # table says 5.0, where it is 2.99 s behind): one summary of all waiting, started at once.
        # The cues 1, 2, 3 are over (life 3.2 s).
        cues = GUI._activity_step!(gui, 5.1)
        @test isempty(a.queue)
        @test _shown(cues) == [4, 0]
        s, age = cues[2]
        @test age == 0.0
        @test a.last_start == 5.1
        @test s.count == 36
        @test s.who == "claude@agent" && s.name == "claude@agent" && s.agent
        @test isempty(s.message)
        # the latest item per key: 9 keys, in the order of their first change
        @test length(s.items) == 9
        @test [it.key for it in s.items] == ["L$(k % 9)" for k in 5:13]
        @test s.text == "36 changes (9 objects)"
        for it in s.items
            ks = [k for k in 5:40 if "L$(k % 9)" == it.key]
            @test it.before[1][1] == first(ks)      # before from the first episode
            @test it.after[1][1] == last(ks) + 1    # after from the last
            @test it.frame == fill(Point3f(last(ks) + 1, 0, 0), 24)
        end
        # the summary is not stored, the timeline keeps every episode
        @test length(a.episodes) == 40
        @test all(ep -> ep.n != 0, a.episodes)

        # the summary is over after its life; nothing is waiting
        @test _shown(GUI._activity_step!(gui, 5.1 + 3.2)) == Int[]
    end

    @testset "summary of several participants, messages" begin
        gui = _gui()
        a = GUI._activity(gui)
        _rec!(gui, "Bob@PC3", 0.0, [_item("A", nothing, 1; change = :added)]; agent = false)
        GUI._activity_step!(gui, 0.0)
        _rec!(gui, "Bob@PC3", 0.1, [_item("A", 1, 2)]; agent = false)
        _rec!(gui, "claude@agent", 0.2, GUI._ActivityItem[]; message = "aligning M2")
        _rec!(gui, "claude@agent", 0.3, [_item("A", 2, 5), _item("B", 0, 1)])
        @test a.queue == [2, 3, 4]  # messages are queued too
        cues = GUI._activity_step!(gui, 3.2)
        s = first(cues[end])
        @test s.n == 0
        @test s.who == "several" && s.name == "several"
        @test !s.agent
        @test s.count == 3
        @test s.text == "3 changes (2 objects)"
        @test [it.key for it in s.items] == ["A", "B"]
        @test s.items[1].before[1][1] == 1 && s.items[1].after[1][1] == 5
        @test s.items[2].before[1][1] == 0 && s.items[2].after[1][1] == 1

        # a single waiting cue that is late stays itself
        gui = _gui()
        _rec!(gui, "Bob@PC3", 0.0)
        cues = GUI._activity_step!(gui, 3.5)
        @test _shown(cues) == [1]
    end

    @testset "colours" begin
        gui = _gui()
        ids = ["p$k" for k in 1:10]
        cs = [GUI._activity_color(gui, id) for id in ids]
        # the first 8 participants differ and get the palette in order
        @test length(unique(cs[1:8])) == 8
        @test [RGBf(c) for c in cs[1:8]] == GUI._ACTIVITY_PALETTE
        # stable within the window
        @test [GUI._activity_color(gui, id) for id in ids] == cs
        @test GUI._activity_color(gui, "p3") == cs[3]
        # alpha passed through
        @test GUI._activity_color(gui, "p2"; alpha = 0.3) == RGBAf(RGBf(cs[2]), 0.3)
        @test GUI._activity_color(gui, "p2").alpha == 1
        # recording assigns the colour of a new participant
        gui = _gui()
        _rec!(gui, "Bob@PC3", 0.0)
        _rec!(gui, "claude@agent", 0.0)
        @test GUI._activity(gui).colors == Dict("Bob@PC3" => 1, "claude@agent" => 2)
        @test RGBf(GUI._activity_color(gui, "claude@agent")) == GUI._ACTIVITY_PALETTE[2]

        # the dark theme: lighter, each mixed 30 % towards white
        light = _gui()
        dark = _gui(; theme = :dark)
        @test !GUI._is_dark(light)
        @test GUI._is_dark(dark)
        for id in ids[1:8]
            cl = GUI._activity_color(light, id)
            cd = GUI._activity_color(dark, id; alpha = 0.5)
            @test cd.alpha == 0.5f0
            @test GUI._rel_luminance(RGBf(cd)) > GUI._rel_luminance(RGBf(cl))
            @test cd.r ≈ cl.r + 0.3 * (1 - cl.r) atol = 1e-6
        end
    end

    @testset "poses at a time" begin
        gui = _gui()
        _rec!(gui, "Bob@PC3", 1.0, [_item("A", 0, 1)])
        _rec!(gui, "Bob@PC3", 2.0, [_item("A", 1, 2), _item("B", 10, 11)])
        _rec!(gui, "Bob@PC3", 3.0, [_item("C", nothing, 7; change = :added)])
        _rec!(gui, "Bob@PC3", 4.0, [_item("B", 11, 12)])
        p = GUI._poses_at(gui, 0.5)
        @test sort!(collect(keys(p))) == ["A", "B"]  # C did not exist at 0.5
        @test p["A"][1] == [0.0, 0, 0]
        @test p["B"][1] == [10.0, 0, 0]
        @test p["A"][2] == R0
        p = GUI._poses_at(gui, 1.5)
        @test p["A"][1] == [1.0, 0, 0] && p["B"][1] == [10.0, 0, 0]
        p = GUI._poses_at(gui, 3.5)
        @test collect(keys(p)) == ["B"]
        @test p["B"][1] == [11.0, 0, 0]
        @test isempty(GUI._poses_at(gui, 4.0))
    end

    @testset "cue alpha" begin
        @test GUI._cue_alpha(-1) == 0
        @test GUI._cue_alpha(0) == 0
        @test all(GUI._cue_alpha(t) == 1 for t in 0.6:0.05:2.0)
        @test all(GUI._cue_alpha(t) == 0 for t in 3.2:0.1:5.0)
        @test GUI._CUE_IN + GUI._CUE_HOLD + GUI._CUE_OUT ≈ 3.2
        ts = range(0, 3.4; step = 1 / 60)
        as = GUI._cue_alpha.(ts)
        @test all(0 .<= as .<= 1)
        d = diff(as)
        @test maximum(abs, d) < 0.05
        @test all(d[ts[2:end] .<= 0.6] .>= 0)    # monotone in
        @test all(d[ts[1:(end - 1)] .>= 2.0] .<= 0)  # monotone out
    end

    @testset "at most 500 episodes" begin
        gui = _gui()
        a = GUI._activity(gui)
        for k in 1:520
            _rec!(gui, "claude@agent", k * 0.001)
        end
        @test length(a.episodes) == GUI._ACTIVITY_MAX == 500
        @test first(a.episodes).n == 21 && last(a.episodes).n == 520
        @test a.queue == collect(21:520)
        cues = GUI._activity_step!(gui, 0.6)
        @test _shown(cues) == [21]
        # the numbers stay unique
        @test _rec!(gui, "claude@agent", 0.7).n == 521
        # replay of a kept episode, nothing for one that is gone
        GUI._replay!(gui, 300; now = 0.8)
        @test _shown(a.cues) == [21, 300]
        GUI._replay!(gui, 3; now = 0.8)
        @test _shown(a.cues) == [21, 300]
    end

    @testset "replay" begin
        gui = _gui()
        a = GUI._activity(gui)
        _rec!(gui, "Bob@PC3", 0.0)
        _rec!(gui, "Bob@PC3", 0.1)
        @test _shown(GUI._activity_step!(gui, 0.2)) == [1]
        # at once, not queued, and once only
        GUI._replay!(gui, 1; now = 0.5)
        cues = GUI._activity_step!(gui, 0.5)
        @test _shown(cues) == [1]
        @test last(cues[1]) == 0.0
        @test a.queue == [2]
        # the waiting cue keeps its pace after it
        @test _shown(GUI._activity_step!(gui, 1.3)) == [1]
        @test _shown(GUI._activity_step!(gui, 1.5)) == [1, 2]
    end

    @testset "follow" begin
        gui = _gui()
        a = GUI._activity(gui)
        @test GUI._follow_target(gui, 0.0) === nothing
        GUI._set_follow!(gui, "Bob@PC3")
        @test a.follow == "Bob@PC3"
        _rec!(gui, "claude@agent", 0.0, [_item("A", 0, 1)])
        GUI._activity_step!(gui, 0.0)
        @test GUI._follow_target(gui, 0.0) === nothing  # an other participant
        _rec!(gui, "Bob@PC3", 0.5, [_item("B", 0, 3)])
        GUI._activity_step!(gui, 1.0)
        pts = GUI._follow_target(gui, 1.0)
        @test pts == fill(Point3f(3, 0, 0), 24)
        @test a.follow_at == 1.0
        # nothing new
        @test GUI._follow_target(gui, 3.5) === nothing
        # one target per 2 s
        _rec!(gui, "Bob@PC3", 1.5, [_item("C", 0, 4)])
        GUI._activity_step!(gui, 2.0)
        @test GUI._follow_target(gui, 2.0) === nothing
        _rec!(gui, "Bob@PC3", 2.1, [_item("D", 0, 5)])
        @test _shown(GUI._activity_step!(gui, 2.95))[(end - 1):end] == [3, 4]
        @test GUI._follow_target(gui, 2.99) === nothing
        # the newest cue of the participant
        @test GUI._follow_target(gui, 3.0) == fill(Point3f(5, 0, 0), 24)
        @test a.follow_at == 3.0
        @test GUI._follow_target(gui, 3.1) === nothing
        # a message has no frames
        _rec!(gui, "Bob@PC3", 3.2, GUI._ActivityItem[]; message = "thinking")
        @test last(_shown(GUI._activity_step!(gui, 3.9))) == 5
        @test GUI._follow_target(gui, 5.5) === nothing
        GUI._set_follow!(gui, nothing)
        @test a.follow === nothing
        @test GUI._follow_target(gui, 10.0) === nothing
    end
end

end
