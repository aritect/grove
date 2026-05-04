#!/usr/bin/env julia
import Pkg
const ROOT = normpath(joinpath(@__DIR__, ".."))
Pkg.activate(ROOT; io=devnull)
using grove
exit(grove.main(ARGS))
