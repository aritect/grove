#!/usr/bin/env julia

const ROOT = abspath(joinpath(@__DIR__, "..", ".."))

include(joinpath(@__DIR__, "trace_storage.jl"))

using Pkg
Pkg.activate(ROOT)

println(stderr, "[coverage] ROOT=", ROOT)
println(stderr, "[coverage] Pkg.test(; coverage=true) …")
Pkg.test(; coverage=true)
relocate_cov_traces!(ROOT)

function list_cov(tree::AbstractString)::Vector{String}
    out = String[]
    isdir(tree) || return out
    for (base, _, files) in walkdir(tree)
        for f in files
            endswith(f, ".cov") || continue
            push!(out, joinpath(base, f))
        end
    end
    sort!(out)
end

for suffix in ("src", "test")
    subt = joinpath(ROOT, "coverage", "traces", suffix)
    traces = list_cov(subt)
    println(stderr, "[coverage] traces/", suffix, ": ", length(traces), " trace(s)")
    for p in traces
        println(stderr, "  ", relpath(p, ROOT))
    end
end
