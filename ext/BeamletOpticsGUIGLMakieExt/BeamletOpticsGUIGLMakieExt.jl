"""
    BeamletOpticsGUIGLMakieExt

Precompiles the live view for GLMakie: its workload replays sessions of simulated mouse and key
actions in an invisible window (see `session.jl`), such that the first hover, click and drag of a
user compiles nothing. The workload of the package itself runs without a backend: it can not
compile the drawing of GLMakie, and loading GLMakie invalidates a part of what it compiled.
"""
module BeamletOpticsGUIGLMakieExt

using BeamletOpticsGUI, BeamletOptics, GLMakie, Makie
using PrecompileTools: @setup_workload, @compile_workload

const GUI = BeamletOpticsGUI
const BMO = BeamletOptics

include("session.jl")

@setup_workload begin
    # A step that fails only loses its part of the precompilation; `test/TestPrecompileSession.jl`
    # runs the sessions with their errors. With `JULIA_DEBUG = BeamletOpticsGUIGLMakieExt`, the
    # workload names the steps that failed
    failed = String[]
    quiet(@nospecialize(f), name) =
        try
            f()
        catch
            push!(failed, name)
            nothing
        end
    @compile_workload begin
        # Without an OpenGL context, e.g. on a headless machine, the package loads all the same and
        # the window works, only its first actions compile
        try
            _precompile_sessions(quiet)
            isempty(failed) || @debug "BeamletOpticsGUI: steps of the precompile workload failed" failed
        catch e
            @warn "BeamletOpticsGUI: the precompile workload for GLMakie did not run, the first " *
                  "actions in a window will compile. Precompile again with a display to avoid that." exception = e
        finally
            GLMakie.closeall()
        end
    end
end

end
