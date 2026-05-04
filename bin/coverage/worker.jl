const ROOT = abspath(ARGS[1])

include(joinpath(@__DIR__, "trace_storage.jl"))

import Coverage as C_
import Coverage.LCOV as Lcov_

println(stderr, "[coverage/worker] ROOT=", ROOT)

function run_coverage_worker(root::AbstractString)::Int
    staged = materialize_src_traces!(root)
    try
        cov = C_.process_folder("src")
        hit, tot = C_.get_summary(cov)
        if tot == 0
            println(stderr, "[coverage/worker] ERROR: total_lines=0 (no usable .cov for src/?)")
            return 1
        end
        pct = 100 * hit / tot
        println(
            "COVERAGE_SUMMARY lines_hit=",
            hit,
            " lines_total=",
            tot,
            " pct=",
            round(Float64(pct); digits = 2),
            "%",
        )
        min_s = strip(get(ENV, "COVERAGE_MIN_PCT", ""))
        min_v = isempty(min_s) ? nothing : tryparse(Float64, min_s)
        if min_v !== nothing && Float64(pct) + 1.0e-9 < min_v
            println(
                stderr,
                "[coverage/worker] FAIL: ",
                round(Float64(pct); digits = 2),
                "% < COVERAGE_MIN_PCT ",
                min_v,
            )
            return 1
        end
        outdir = joinpath(root, "coverage")
        mkpath(outdir)
        lcov_path = joinpath(outdir, "lcov.info")
        Lcov_.writefile(lcov_path, cov)
        println(stderr, "[coverage/worker] wrote ", lcov_path)
        return 0
    finally
        cleanup_materialized_src!(staged)
    end
end

rc = Base.cd(ROOT) do
    run_coverage_worker(ROOT)
end
exit(rc)
