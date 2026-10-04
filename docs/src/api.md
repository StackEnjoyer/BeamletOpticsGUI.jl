# API

The exported names of BeamletOpticsGUI. The functions and types of BeamletOptics that the GUI
builds on (`render!`, `live_render!`, `update_render!`, `remove_render!`, `pick_object` and the
render handle protocol) are documented on the
[BeamletOptics site](https://github.com/JuliaPhysics/BeamletOptics.jl).

```@docs
BeamletOpticsGUI
```

## Live view functions

```@docs
live_view
retrace!
export_changes
export_script
add_panel!
add_controls!
add_tool!
```

## Adding and removing components

```@docs
add_component!
remove_component!
CatalogEntry
CatalogParam
CatalogGlass
component_catalog
catalog_glasses
```

## Detector views

```@docs
detector_view!
DetectorView
update_detector_view!
set_spot_colors!
```

## Interactive helpers

```@docs
kinematic_controls!
view_cube!
```

## Card API

```@docs
card_rows
pose_card_rows
beam_card_rows
card_actions
CardRow
CardWidget
card_input
card_show!
```

## Agent skill

```@docs
BeamletOpticsGUI.install_agent_skill
```
