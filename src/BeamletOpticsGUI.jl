"""
    BeamletOpticsGUI

The interactive GUI of BeamletOptics: [`live_view`](@ref), [`kinematic_controls!`](@ref),
[`view_cube!`](@ref) and the cards and widgets of the live view. The components and beams are drawn
by the live rendering of BeamletOptics (`live_render!`), via its render handle protocol.
"""
module BeamletOpticsGUI

using BeamletOptics
import BeamletOptics: live_render!, update_render!, remove_render!, pick_object, pickable_plots,
                      rendered, render_plots, render_children, render_parent, render_settings,
                      look_colors, AbstractRenderHandle, AbstractObjectRenderHandle,
                      AbstractSystemRenderHandle, AbstractBeamRenderHandle
import BeamletOptics: translate3d!, translate_to3d!, rotate3d!

const BMO = BeamletOptics

export live_view, kinematic_controls!, view_cube!, export_changes, export_script, card_rows,
       pose_card_rows, beam_card_rows, card_actions, CardRow, CardWidget, card_input, card_show!,
       add_panel!, add_controls!, add_tool!, retrace!, add_component!, remove_component!, open_system,
       CatalogEntry, CatalogParam, CatalogGlass, component_catalog, catalog_glasses, select!,
       spectator!, wait_solve

import Makie
using Makie: Figure, Axis3, LScene, mesh!, lines!, linesegments!, RGBf, RGBAf, scatter!, text!,
             update_cam!, cameracontrols, arrows3d!, translate!, rotate!, Quaternion, AbstractPlot,
             Plane3f, Observable, notify
using PrecompileTools: @setup_workload, @compile_workload
import GeometryBasics
using GeometryBasics: Point2, Point3, Point3f, Point3d, Vec3f, Vec3d, GLTriangleFace, Mesh
using Base.ScopedValues: ScopedValue, with
import AbstractTrees
using AbstractTrees: PreOrderDFS
using LinearAlgebra: dot, cross, normalize, norm
using Trapz: trapz

"""The 3D axes that the live view draws into."""
const _Axis = Union{Axis3, LScene}

# include order dependant!
include("API.jl")
include("LiveHandles.jl")
include("LiveMarkers.jl")
include("LiveInteraction.jl")
include("LiveTree.jl")
include("LiveProgress.jl")
include("LiveIcons.jl")
include("ViewCube.jl")
include("LiveWidgets.jl")
include("LiveDetectorView.jl")
include("LiveCardPages.jl")
include("LiveCard.jl")
include("LiveView.jl")
include("LiveLayout.jl")
include("LiveScroll.jl")
include("LiveDetectors.jl")
include("LiveTrace.jl")
include("LiveBeamSwitch.jl")
include("LivePolarization.jl")
include("LiveBeamOverlays.jl")
include("LiveClip.jl")
include("LiveExport.jl")
include("LiveCards.jl")
include("LiveMeasure.jl")
include("LiveCamera.jl")
include("LiveCompact.jl")
include("LiveOverlay.jl")
include("LiveHelp.jl")
include("LiveCardRows.jl")
include("LiveExtras.jl")
include("LiveApp.jl")
include("LiveSelection.jl")
include("LiveAppTree.jl")
include("LiveDock.jl")
include("LiveInspector.jl")
include("LiveInfo.jl")
include("LiveBackground.jl")
include("LiveHighlight.jl")
include("LiveSelectionCard.jl")
include("LiveSolveError.jl")
include("LiveCustom.jl")
include("LiveComponents.jl")
include("LiveSources.jl")
include("LiveBeamColor.jl")
include("LiveEdit.jl")
include("LivePlacement.jl")
include("LiveSnap.jl")
include("LiveTable.jl")
include("LiveAlign.jl")
include("LiveAim.jl")
include("LiveLinks.jl")
include("LiveScripting.jl")
include("LiveRecord.jl")
include("LiveGlasses.jl")
include("LiveSurfaces.jl")
include("LiveCatalogEntries.jl")
include("LiveCatalog.jl")
include("LiveCatalogWindow.jl")
include("LiveCopy.jl")
# agent skill of the package
include("AgentSkill.jl")
# precompiles the live view and the interaction call paths, must come last
include("LivePrecompile.jl")

end
