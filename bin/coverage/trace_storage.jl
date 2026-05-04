const TRACE_TREE_PREFIXES = ("src", "test", "bin")

"""True for typical Julia source coverage filenames (`*.jl.<digits>.cov`)."""
function is_julia_cov_trace_file(name::AbstractString)::Bool
    endswith(name, ".cov") || return false
    return occursin(r"\.jl\.\d+\.cov$", name)
end

"""
Clear `coverage/traces/`, then move every trace file from `src/` and `test/` into mirrored paths under
`coverage/traces/<prefix>/…`.
"""
function relocate_cov_traces!(root::AbstractString)::Nothing
    traces = joinpath(root, "coverage", "traces")
    rm(traces; recursive = true, force = true)
    mkpath(traces)
    for prefix in TRACE_TREE_PREFIXES
        tree = joinpath(root, prefix)
        isdir(tree) || continue
        for (base, _, files) in walkdir(tree)
            for f in files
                is_julia_cov_trace_file(f) || continue
                src_path = joinpath(base, f)
                rel_within = relpath(base, tree)
                dest_prefix = joinpath(traces, prefix)
                dest_dir = rel_within == "." ? dest_prefix : joinpath(dest_prefix, rel_within)
                mkpath(dest_dir)
                mv(src_path, joinpath(dest_dir, f); force = true)
            end
        end
    end
    return nothing
end

"""Copy traces from `coverage/traces/src/` beside `src/**/*.jl` for Coverage.process_folder; return paths created."""
function materialize_src_traces!(root::AbstractString)::Vector{String}
    traces_src = joinpath(root, "coverage", "traces", "src")
    pkg_src = joinpath(root, "src")
    staged = String[]
    isdir(traces_src) || return staged
    for (base, _, files) in walkdir(traces_src)
        for f in files
            is_julia_cov_trace_file(f) || continue
            tpath = joinpath(base, f)
            rel = relpath(tpath, traces_src)
            dest = joinpath(pkg_src, rel)
            mkpath(dirname(dest))
            cp(tpath, dest; force = true)
            push!(staged, dest)
        end
    end
    return staged
end

"""Remove paths previously returned by materialize_src_traces!."""
function cleanup_materialized_src!(paths::Vector{String})::Nothing
    for p in paths
        isfile(p) && rm(p)
    end
    return nothing
end
