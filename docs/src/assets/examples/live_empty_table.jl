using BeamletOptics, BeamletOpticsGUI, GLMakie

## An empty optical table: a system without components and a view without a source
system = System()

## The application window, `layout = :app`: the object tree and the catalog of the components in
## the left sidebar, the inspector with the card of the selection in the right one. `table` shows
## the optical table, and with `snap`, components that are placed or dragged with the mouse snap
## onto its holes and onto the beams
gui = live_view(system; layout = :app, size = (1600, 900), table = true, snap = true,
    labels = Dict(system => "Beam expander"))

# Open the interactive window when used from the REPL or run as a script
if isinteractive()
    display(gui)
elseif abspath(PROGRAM_FILE) == @__FILE__
    wait(display(gui))
end
