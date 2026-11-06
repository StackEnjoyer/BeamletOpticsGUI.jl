using BeamletOptics, BeamletOpticsGUI, GLMakie

# An own component type: a screen that absorbs the rays and keeps the points where they hit it
# (x, z relative to its center [m], valid while the screen faces the beam along y without rotation)
struct Screen{T} <: BeamletOptics.AbstractObject{T}
    shape::BeamletOptics.PlanoSurfaceSDF{T}
    hits::Vector{Point2{Float64}}
    lock::ReentrantLock
end

Screen(width, thickness) = Screen(BeamletOptics.PlanoSurfaceSDF(thickness, width),
    Point2{Float64}[], ReentrantLock())

# Called for every ray that hits the screen (the solve may use several threads)
function BeamletOptics.interact3d(::BeamletOptics.AbstractSystem, s::Screen, ::Beam, ray::Ray)
    p = position(ray) + length(ray) * direction(ray) - position(s)
    lock(() -> push!(s.hits, Point2(p[1], p[3])), s.lock)
    return nothing
end

# The hits of the last solve are discarded before the next one
BeamletOptics.initialize!(s::Screen) = (lock(() -> empty!(s.hits), s.lock); nothing)

# The functions of the views: they only read the screen and return what is shown
hit_count(s::Screen) = length(s.hits)
hit_points(s::Screen) = copy(s.hits)

# The page "Results" of the card of a screen: the first view is shown first. `:series` records the
# count after each full solve and draws it over the solves, `:points` draws a spot diagram.
BeamletOpticsGUI.card_views(::Screen) = (
    CardView(hit_count, :series; name = :count, label = "Count", unit = "rays",
        text = (s, n) -> "$(Int(n)) rays hit the screen"),
    CardView(hit_points, :points; name = :spot, label = "Hits"))

# A narrow beam and a screen of 10 mm width behind it
beam = CollimatedSource([0.0, 0, 0], [0.0, 1, 0], 4e-3, 1e-6; num_rings = 2, num_rays = 40)
screen = Screen(10e-3, 2e-3)
translate3d!(screen, [0.0, 0.1, 0.0])
system = System([screen])

# Select the screen and drag it sideways: the count over the solves and the spots follow. A script
# gets the same numbers by calling `hit_count(screen)` after `solve_system!`.
gui = live_view(system, beam; labels = Dict(screen => "screen"))

# Open the interactive window when used from the REPL or run as a script
if isinteractive()
    display(gui)
elseif abspath(PROGRAM_FILE) == @__FILE__
    wait(display(gui))
end
