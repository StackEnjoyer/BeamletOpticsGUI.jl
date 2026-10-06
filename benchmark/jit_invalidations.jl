# Logs which methods of BeamletOpticsGUI are invalidated by loading GLMakie after it, as raw entries
# of `jl_debug_method_invalidation`.
#
#   julia --project=test benchmark/jit_invalidations.jl
using BeamletOptics, BeamletOpticsGUI, Makie
const LOG = ccall(:jl_debug_method_invalidation, Any, (Cint,), 1)
using GLMakie
ccall(:jl_debug_method_invalidation, Any, (Cint,), 0)

println("entries: ", length(LOG))
# The log is a flat list: invalidated method instances and their depth, then the reason and the
# method whose definition caused them
hits = Dict{String, Int}()
last_gui = String[]
for x in LOG
    s = string(x)
    if x isa Core.MethodInstance || x isa Core.CodeInstance
        occursin("BeamletOpticsGUI", s) && push!(last_gui, first(s, 160))
    elseif x isa Method
        if !isempty(last_gui)
            key = first(s, 230)
            hits[key] = get(hits, key, 0) + length(last_gui)
            empty!(last_gui)
        end
    end
end
println("invalidated instances of BeamletOpticsGUI by the method that caused them:")
for (k, v) in sort(collect(hits); by = last, rev = true)[1:min(end, 25)]
    println(lpad(v, 5), "  ", k)
end
types = Dict{String, Int}()
foreach(x -> (t = string(typeof(x)); types[t] = get(types, t, 0) + 1), LOG)
println(types)
foreach(x -> x isa String && nothing, LOG)
println(unique(filter(x -> x isa String, LOG)))
