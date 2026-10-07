# Summarizes a trace of `jit_probe.jl`: per step the compile time by the module of the compiled
# function, and the most expensive methods.
#
#   julia benchmark/jit_trace_summary.jl trace.txt [number of methods per step]
const FILE = ARGS[1]
const TOP = parse(Int, get(ARGS, 2, "6"))

owner(sig) = begin
    m = match(r"^Tuple\{(?:typeof\()?(?:Core\.kwcall\), [^,]*, typeof\()?([A-Za-z_][A-Za-z0-9_]*)", sig)
    isnothing(m) ? "?" : m.captures[1]
end

steps = Pair{String, Vector{Tuple{Float64, String, Bool}}}[]
for line in eachline(FILE)
    if startswith(line, "### ")
        push!(steps, line[5:end] => Tuple{Float64, String, Bool}[])
        continue
    end
    m = match(r"^#=\s*([0-9.]+) ms =# precompile\((.*)\)(.*)$", line)
    (isnothing(m) || isempty(steps)) && continue
    push!(last(steps).second, (parse(Float64, m.captures[1]), m.captures[2], occursin("recompile", m.captures[3])))
end

short(s, n = 150) = length(s) > n ? first(s, n) * "…" : s
total = Dict{String, Float64}()
for (name, rows) in steps
    isempty(rows) && continue
    t = sum(first, rows)
    t < 20 && continue
    by = Dict{String, Float64}()
    for (ms, sig, _) in rows
        by[owner(sig)] = get(by, owner(sig), 0.0) + ms
        total[owner(sig)] = get(total, owner(sig), 0.0) + ms
    end
    re = sum(r -> r[3] ? r[1] : 0.0, rows)
    println("\n== ", name, ": ", round(Int, t), " ms in ", length(rows), " methods",
        re > 0 ? " (recompiled: $(round(Int, re)) ms)" : "")
    println("   ", join(("$k $(round(Int, v))" for (k, v) in sort(collect(by); by = last, rev = true)[1:min(end, 5)]), ", "))
    for (ms, sig, r) in sort(rows; by = first, rev = true)[1:min(end, TOP)]
        println("   ", lpad(round(ms; digits = 1), 7), r ? " R " : "   ", short(sig))
    end
end
println("\n== by module, all steps")
for (k, v) in sort(collect(total); by = last, rev = true)[1:min(end, 12)]
    println("   ", rpad(k, 20), round(Int, v), " ms")
end
