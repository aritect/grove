const WIP_LIMIT_DEFAULT = 2

function i1_dor_on_progress(st::State)::Vector{String}
    out = String[]
    for w in listnodes(st, :w)
        w.status === :progress || continue
        dor(st, w) || push!(out, "I1: $(w.id) is `progress` but DoR ≢ ⊤")
    end
    out
end

function i2_spike_outputs(st::State)::Vector{String}
    out = String[]
    for w in listnodes(st, :w)
        (w.type === :spike && w.status === :done) || continue
        has_any = any(e -> e.label === :produces && e.from == w.id, st.edges)
        has_any || push!(out,
            "I2: $(w.id) is a done spike but `produces` is empty (no outgoing `produces` edges)")
    end
    out
end

function i3_done_has_evidence(st::State)::Vector{String}
    out = String[]
    for w in listnodes(st, :w)
        w.status === :done || continue
        ev = get(w.fields, :evidence, String[])
        isempty(ev) && push!(out, "I3: $(w.id) is `done` but `evidence` is empty")
    end
    out
end

function i4_wip_limit(st::State; limit::Int=WIP_LIMIT_DEFAULT)::Vector{String}
    n = count(w -> w.status === :progress, listnodes(st, :w))
    n > limit ? ["I4: WIP $(n) exceeds limit $(limit)"] : String[]
end

function i5_blocks_terminal(st::State)::Vector{String}
    out = String[]
    for w in listnodes(st, :w)
        w.status === :progress || continue
        for p in blocked_by(st, w.id)
            np = get(st.nodes, p, nothing)
            if np === nothing
                push!(out, "I5: $(w.id) blocked by missing $p"); continue
            end
            clears_blocks_predecessor(np) ||
                push!(out, "I5: $(w.id) is `progress` but blocker $(p) ($(np.status)) does not satisfy blocks clearance (goals must be verified)")
        end
    end
    out
end

function i7_blocks_dag(st::State)::Vector{String}
    succ = Dict{String,Vector{String}}()
    nodes = Set{String}()
    for e in st.edges
        e.label === :blocks || continue
        push!(get!(succ, e.from, String[]), e.to)
        push!(nodes, e.from); push!(nodes, e.to)
    end
    indeg = Dict{String,Int}(id => 0 for id in nodes)
    for (_, vs) in succ, v in vs
        indeg[v] = get(indeg, v, 0) + 1
    end
    q = [id for (id, d) in indeg if d == 0]
    visited = 0
    while !isempty(q)
        x = pop!(q)
        visited += 1
        for s in get(succ, x, String[])
            indeg[s] -= 1
            indeg[s] == 0 && push!(q, s)
        end
    end
    visited == length(nodes) ? String[] : ["I7: blocks graph contains a cycle"]
end

function i9_feature_bchain(st::State)::Vector{String}
    out = String[]
    for w in listnodes(st, :w)
        (w.type === :feature && w.status in (:ready, :progress)) || continue
        for b in bchain(st, w)
            n = get(st.nodes, b, nothing)
            n === nothing && continue
            n.status in (:validated, :invalidated_acceptable) ||
                push!(out, "I9: $(w.id) is `$(w.status)` but $(b) is `$(n.status)`")
        end
    end
    out
end

function i10_done_fitness(st::State)::Vector{String}
    out = String[]
    for w in listnodes(st, :w)
        w.status === :done || continue
        gs = get(w.fields, :goals, String[])
        f = get(w.fields, :fitness, Dict{String,Int}())
        for g in gs
            haskey(f, g) || push!(out, "I10: $(w.id) is `done` but no fitness delta for $g")
        end
    end
    out
end

function i11_progress_has_session_claim(st::State)::Vector{String}
    out = String[]
    for w in listnodes(st, :w)
        w.status === :progress || continue
        progress_has_session_record(w) ||
            push!(out, "I11: $(w.id) is `progress` but has no session token")
    end
    out
end

function check_orphan_edges(st::State)::Vector{String}
    out = String[]
    for e in st.edges
        haskey(st.nodes, e.from) || push!(out, "edge endpoint missing: $(e.from)")
        haskey(st.nodes, e.to) || push!(out, "edge endpoint missing: $(e.to)")
    end
    out
end

function check_edge_types(st::State)::Vector{String}
    out = String[]
    for e in st.edges
        from = get(st.nodes, e.from, nothing)
        to = get(st.nodes, e.to, nothing)
        (from === nothing || to === nothing) && continue
        ok = if e.label === :blocks
            to.kind === :w
        elseif e.label === :causes
            from.kind === :a && to.kind === :w
        elseif e.label === :implements
            from.kind === :w && to.kind === :d
        elseif e.label === :asks
            from.kind === :q
        elseif e.label === :tests
            from.kind === :b && to.kind === :q
        elseif e.label === :targets
            from.kind === :b && to.kind === :w
        elseif e.label === :produces
            from.kind === :w && to.kind in (:d, :q, :b)
        elseif e.label === :supersedes
            from.kind === :d && to.kind === :d
        else
            false
        end
        ok || push!(out, "edge type mismatch: $(e.from) -$(e.label)-> $(e.to)")
    end
    out
end

function check_all(st::State)::Vector{String}
    vcat(
        i1_dor_on_progress(st),
        i2_spike_outputs(st),
        i3_done_has_evidence(st),
        i4_wip_limit(st),
        i5_blocks_terminal(st),
        i7_blocks_dag(st),
        i9_feature_bchain(st),
        i10_done_fitness(st),
        i11_progress_has_session_claim(st),
        check_orphan_edges(st),
        check_edge_types(st),
    )
end

"""Return `nothing` on success, otherwise an error string (edge not added)."""
function validate_and_push_edge!(
    st::State, from::AbstractString, label::Symbol, to::AbstractString;
    bump_nodes::Bool=true,
)::Union{Nothing,String}
    from = String(strip(from))
    to = String(strip(to))
    label in EDGE_LABELS || return "unknown edge label: $(label)"
    haskey(st.nodes, from) || return "missing node $(from)"
    haskey(st.nodes, to) || return "missing node $(to)"
    if any(e -> e.from == from && e.label === label && e.to == to, st.edges)
        return nothing
    end
    e = Edge(from, label, to)
    push!(st.edges, e)
    stamp_new_edge!(e)
    if label === :blocks && !isempty(i7_blocks_dag(st))
        pop!(st.edges)
        return "I7: blocks introduces a cycle"
    end
    et = check_edge_types(st)
    if !isempty(et)
        pop!(st.edges)
        return et[end]
    end
    if bump_nodes
        stamp_touch_node!(getnode(st, from))
        stamp_touch_node!(getnode(st, to))
    end
    nothing
end

"""Move legacy reflist relation fields (`supersedes`, `targets` on q/b, …) onto edges."""
function migrate_legacy_relation_fields!(st::State)::Vector{String}
    msgs = String[]
    for (_, n) in st.nodes
        if n.kind === :d && haskey(n.fields, :supersedes)
            olds = pop!(n.fields, :supersedes)
            for oid in olds
                r = validate_and_push_edge!(st, n.id, :supersedes, String(oid); bump_nodes=false)
                r !== nothing && push!(msgs, "$(n.id) supersedes $(oid): $(r)")
            end
        end
        if n.kind === :q && haskey(n.fields, :targets)
            tg = pop!(n.fields, :targets)
            for tid in tg
                r = validate_and_push_edge!(st, n.id, :asks, String(tid); bump_nodes=false)
                r !== nothing && push!(msgs, "$(n.id) asks $(tid): $(r)")
            end
        end
        if n.kind === :b
            if haskey(n.fields, :tests)
                qs = pop!(n.fields, :tests)
                for qid in qs
                    r = validate_and_push_edge!(st, n.id, :tests, String(qid); bump_nodes=false)
                    r !== nothing && push!(msgs, "$(n.id) tests $(qid): $(r)")
                end
            end
            if haskey(n.fields, :targets)
                wids = pop!(n.fields, :targets)
                for wid in wids
                    r = validate_and_push_edge!(st, n.id, :targets, String(wid); bump_nodes=false)
                    r !== nothing && push!(msgs, "$(n.id) targets $(wid): $(r)")
                end
            end
        end
    end
    msgs
end
