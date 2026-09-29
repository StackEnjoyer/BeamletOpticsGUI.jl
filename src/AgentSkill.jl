"""
    install_agent_skill(dest = joinpath(pwd(), ".claude", "skills"))

Copies the agent skill that ships with the installed BeamletOpticsGUI version into
`joinpath(dest, "beamletopticsgui")` and returns that path. The skill teaches AI coding assistants
(e.g. Claude Code) how to use the live view of BeamletOpticsGUI. It builds on the skill of
BeamletOptics, which teaches the optics and is installed by
`BeamletOptics.install_agent_skill()`.

The default `dest` is the project-level skill directory of Claude Code in the current working
directory. Use e.g. `joinpath(homedir(), ".claude", "skills")` for a personal installation.

An existing `beamletopticsgui` skill in `dest` is replaced, so calling this function again after
`Pkg.update` keeps the skill in sync with the installed package version. Local edits to the
copy are lost.

!!! info "File permissions"
    Pkg installs packages read-only. The copied files are made writable so that the copy can be
    edited and replaced later.
"""
function install_agent_skill(dest::AbstractString = joinpath(pwd(), ".claude", "skills"))
    src = joinpath(pkgdir(@__MODULE__), "skills", "beamletopticsgui")
    isdir(src) || throw(ErrorException("Agent skill not found at $src"))
    target = joinpath(dest, "beamletopticsgui")
    mkpath(dest)
    cp(src, target; force = true)
    for (root, _, files) in walkdir(target)
        chmod(root, 0o755)
        foreach(f -> chmod(joinpath(root, f), 0o644), files)
    end
    @info "Installed BeamletOpticsGUI agent skill (v$(pkgversion(@__MODULE__))) to $target"
    return target
end
