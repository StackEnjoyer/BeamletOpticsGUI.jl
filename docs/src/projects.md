# [Projects](@id projects_page)

A live view can be saved as a project of
[BeamletOpticsProjects](https://stackenjoyer.github.io/BeamletOpticsProjects.jl/dev/): a folder with
the setup as readable Julia code, which the window opens again, and which people in other windows
and coding agents change at the same time. The window writes every finished action to the files and
takes in what the others write there, without a reload.

!!! note
    A prototype: the format of the files may still change.

```julia
using BeamletOptics, BeamletOpticsGUI, GLMakie

gui = live_view(system, beam)
save_project(gui, "Bench")          # the view becomes the project in the folder Bench
gui = open_project("Bench")         # or "Bench/Bench.bmo"
```

## The folder

```text
Bench/
├── Bench.bmo           the project file, which people open: the versions it was saved with
├── system.jl           the setup: one line per component, source, group and system
├── src/Bench.jl        own code of the project (functions, components)
├── view.toml           how the view looks for a person without an own one
├── AGENTS.md           instructions for coding agents (CLAUDE.md points to it)
└── .bmo/               the files of the open windows (not versioned):
                        view-<person>.toml, session-<person>.md, presence-<id>.toml, claims/
```

Each line of `system.jl` has a readable id (`L1`, `D1`, `S1`), the label that the view shows and a
machine id that stays when the object is renamed. A project is data, not a Julia environment: it
opens from any environment that has BeamletOptics, BeamletOpticsProjects and the GUI. When the
project was saved with newer or other versions of these packages, or its own code needs a package
that is not installed, [`open_project`](@ref) warns, and the dialog of "Open" asks first.

How the view looks (camera, saved views, clip planes, table, the colors of the beams) is saved per
person in `.bmo/view-<person>.toml`. Objects whose constructor the GUI does not know, e.g. those a
script gave to [`live_view`](@ref), are not saved; a warning names them. The components and sources
from the catalog are saved with their constructors and can be edited on their page "Edit".

## Working in a project

- **Autosave.** Every finished action (a drag, a key step, an input on a card, adding, removing,
  grouping, undo) is written to `system.jl` shortly after it, without a key.
- **Changes of the others.** When the files change, e.g. by an agent, the window applies the change
  once the files settle: moved objects glide to their new poses (the objects of one change
  together, a group moved as a whole as one), new objects appear, changed ones are built again and
  removed ones go. The window is never replaced.
- **Versions.** `Ctrl+S` writes what is still pending and saves a version of the project (a git
  commit, without a git install). A card asks for its message, filled with what changed since the
  last version.
- **Taking the files.** `Ctrl+R` makes the window as in the files: everything that differs is
  taken from them, changes in the window that were not saved are lost.
- **Groups** made in the window are `@group` lines of the project.

## Conflicts

An object that was changed both in the window and in the files, differently, is a conflict. Only
that object waits: everything else is applied and saved, and the files keep their state of the
object until the person decides. A card lists the objects of the conflict, each with "theirs" (take
the state of the files) and "mine" (keep the window's), and offers "Save as…" to keep the window's
state in another folder. `Ctrl+S` saves no version while a conflict is open.

## Several people and agents

Several windows and agents can work on one project at once, also from a shared drive.

- **Presence.** Each window shows where the others work: a box at the object they selected, with
  their name and what they are doing, people and agents alike, each in a calm colour of its own.
- **What the others changed.** A change of another participant is shown where it happened: a thin
  frame in the participant's colour at the new place, a dashed ghost at the old one and a soft arc
  between them, a small chip with the name and the change ("claude · moved M2 by 12 mm"); new
  objects settle into a frame, removed ones leave a ghost. What an agent says it does next
  (`announce(...; doing)`) appears as a bubble at its object. The cues fade after about 3 s. When an
  agent changes things faster than one can follow, the setup changes at once, but the cues play one
  after the other at a readable pace; more than 3 s behind, the waiting ones become one cue
  ("claude · 14 changes").
- **Timeline.** Once another participant was there, a strip at the bottom of the 3D view lists who
  changed what and when, in one line, or, after a click, in a lane per participant. The mouse over
  a mark shows the change again, a click replays it, a double click frames its objects, dragging
  along the lanes shows ghosts of how the setup was at that time, and the eye of a lane makes the
  camera follow that participant.
- **Claims.** The first gesture on an object claims it for the person, until it is deselected or
  30 s pass without a gesture. A gesture on an object that another participant claims is refused,
  the status line names the holder ("Bob is editing M1"), and the object shows a lock. A change
  that lost the race to a claim is held like a conflict and written once the claim is gone.
- **Session file.** The window notes the selection and the recent changes of its person in
  `.bmo/session-<person>.md`, for the agents that work on the same project.
- **Versions of the packages.** The window says when another participant works with other versions
  of BeamletOptics, BeamletOpticsProjects or the GUI.

An agent needs no GUI: it works with BeamletOptics and BeamletOpticsProjects only. How it reads and
changes a project is in the agent skill of BeamletOpticsProjects
(`BeamletOpticsProjects.install_agent_skill()`).

## Keys and tools

| Key (`Cmd` on macOS) | Tool | Action |
|---|---|---|
| `Ctrl+S` | Save | write what is pending, save a version (without a project: like "Save as") |
| `Ctrl+Shift+S` | Save as | save the view as a project in a new folder, which becomes the project of the window |
| `Ctrl+O` | Open | open a project chosen in a dialog in place of the window |
| `Ctrl+N` | New project | make an empty project in a new or empty folder and open it in place of the window |
| `Ctrl+R` | | take the files as they are |

"New project" first writes what is pending of the current project. From code, see
[`open_project`](@ref) and [`save_project`](@ref save_project(::BeamletOpticsGUI.LiveView, ::AbstractString)).
