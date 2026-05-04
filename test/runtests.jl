using Test
using JSON
using grove

const M = grove

include("test_ids.jl")
include("test_lock.jl")
include("test_goal_fitness.jl")
include("test_algebra.jl")
include("test_invariants_edges.jl")
include("test_invariants_guards.jl")
include("test_dor.jl")
include("test_render_dashboard.jl")
include("test_cli_workspace.jl")
include("test_cli_integrity.jl")
include("test_repo_attributes.jl")
include("test_archive_exclusive.jl")
include("test_cli_retro_prompt.jl")
include("test_cli_core.jl")
include("test_lockdiff.jl")
include("test_cli_diff.jl")
include("test_log_timeline.jl")
include("test_cli_undo_log_session.jl")
include("test_coverage_trace_storage.jl")
