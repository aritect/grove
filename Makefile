.PHONY: test coverage

test:
	julia --project=. -e "using Pkg; Pkg.test()"

coverage:
	julia --project=. -e "using Pkg; Pkg.test(; coverage=true)"
	julia --project=. -e "ENV[\"COVERAGE_MIN_PCT\"]=\"70\"; include(\"bin/coverage/summary.jl\")"

notebooklm:
	julia --project=. bin/notebooklm.jl