function blocked_by(st::State, id::AbstractString)::Vector{String}
    [e.from for e in st.edges if e.label === :blocks && e.to == id]
end

function blocks_of(st::State, id::AbstractString)::Vector{String}
    [e.to for e in st.edges if e.label === :blocks && e.from == id]
end

function deps(st::State, id::AbstractString)::Vector{String}
    seen = Set{String}()
    order = String[]
    function visit(x)
        for p in blocked_by(st, x)
            if !(p in seen)
                push!(seen, p)
                visit(p)
                push!(order, p)
            end
        end
    end
    visit(String(id))
    order
end

function impact(st::State, id::AbstractString)::Vector{String}
    seen = Set{String}()
    order = String[]
    function visit(x)
        for s in blocks_of(st, x)
            if !(s in seen)
                push!(seen, s)
                push!(order, s)
                visit(s)
            end
        end
    end
    visit(String(id))
    order
end

function preds_clear(st::State, id::AbstractString)::Bool
    for p in blocked_by(st, id)
        n = get(st.nodes, p, nothing)
        n === nothing && return false
        clears_blocks_predecessor(n) || return false
    end
    true
end

ac_of(n::Node) = get(n.fields, :ac, String[])
goals_of(n::Node) = get(n.fields, :goals, String[])

"""True if prose field has at least one non-empty (after strip) line."""
function prose_field_nonempty(lines)::Bool
    for s in lines
        !isempty(strip(string(s))) && return true
    end
    return false
end

"""Refactor DoR: some non-archived A has (A, causes, w)."""
function refactor_materialised_root_cause(st::State, w::Node)::Tuple{Bool,String}
    parts = String[]
    for e in st.edges
        e.label === :causes || continue
        e.to != w.id && continue
        a = get(st.nodes, e.from, nothing)
        a === nothing && continue
        a.kind !== :a && continue
        a.archived && continue
        push!(parts, e.from)
    end
    isempty(parts) && return (false, "")
    return (true, join(sort!(unique(parts)), ", "))
end

function asks_of(st::State, w::Node)::Vector{String}
    [e.from for e in st.edges if e.label === :asks && e.to == w.id]
end

function implements_of(st::State, w::Node)::Vector{String}
    [e.to for e in st.edges if e.label === :implements && e.from == w.id]
end

function bchain(st::State, w::Node)::Vector{String}
    out = Set{String}()
    for e in st.edges
        e.label === :targets || continue
        e.to == w.id || continue
        fromn = get(st.nodes, e.from, nothing)
        fromn !== nothing && fromn.kind === :b && push!(out, e.from)
    end
    for e in st.edges
        e.label === :tests || continue
        bf = get(st.nodes, e.from, nothing)
        qt = get(st.nodes, e.to, nothing)
        (bf === nothing || qt === nothing) && continue
        (bf.kind === :b && qt.kind === :q) || continue
        if any(ed -> ed.label === :asks && ed.from == e.to && ed.to == w.id, st.edges)
            push!(out, e.from)
        end
    end
    sort!(collect(out))
end

"""Re-derive artifact `status` from themed work items (I₆)."""
function rederive_artifacts!(st::State)
    for a in listnodes(st, :a)
        prev = a.status
        ws = Node[w for w in listnodes(st, :w) if get(w.fields, :theme, "") == a.id]
        if isempty(ws)
            a.status = :open
        else
            a.status = all(w -> isterminal(:w, w.status), ws) ? :done : :open
        end
        a.status !== prev && stamp_touch_node!(a)
    end
    nothing
end

function dor_breakdown(st::State, w::Node)::Vector{Tuple{String,Bool,String}}
    out = Tuple{String,Bool,String}[]
    g = goals_of(w)
    push!(out, ("goals(w) ≠ ∅", !isempty(g), join(g, ", ")))
    ac = ac_of(w)
    push!(out, ("AC(w) ≠ ∅", !isempty(ac), string(length(ac), " entries")))
    asks = asks_of(st, w)
    asks_ok = all(q -> begin
            n = get(st.nodes, q, nothing)
            n !== nothing && isterminal(:q, n.status)
        end, asks)
    push!(out, ("∀ q ∈ asks(w), q terminal", asks_ok, join(asks, ", ")))
    if w.type === :feature
        chain = bchain(st, w)
        chain_ok = all(b -> begin
                n = get(st.nodes, b, nothing)
                n !== nothing && n.status in (:validated, :invalidated_acceptable)
            end, chain)
        push!(out, ("BChain validated", chain_ok, join(chain, ", ")))
    else
        push!(out, ("BChain validated", true, "(non-feature)"))
    end
    fitness = get(w.fields, :fitness, Dict{String,Int}())
    fit_ok = !isempty(g) && all(gid -> haskey(fitness, gid), g)
    push!(out, ("fitness deltas set ∀ g", fit_ok,
        join([string(k, "=", v >= 0 ? "+" : "", v) for (k, v) in fitness], ", ")))
    es = get(w.fields, :evidence_strategy, String[])
    push!(out, ("evidence_strategy ≠ ∅", !isempty(es), string(length(es), " entries")))
    if w.type === :feature
        hyp = get(w.fields, :hypothesis, String[])
        push!(out, ("hypothesis ≠ ⊥", !isempty(hyp), ""))
    else
        push!(out, ("hypothesis ≠ ⊥", true, "(non-feature)"))
    end
    if w.type === :bug
        rp = get(w.fields, :repro, String[])
        r_ok = prose_field_nonempty(rp)
        push!(out, ("repro(w) ≠ ∅", r_ok, r_ok ? string(length(rp), " entries") : ""))
    else
        push!(out, ("repro(w) ≠ ∅", true, "(non-bug)"))
    end
    if w.type === :spike
        ex = get(w.fields, :exit, String[])
        e_ok = prose_field_nonempty(ex)
        push!(out, ("exit(w) ≠ ∅", e_ok, e_ok ? string(length(ex), " entries") : ""))
    else
        push!(out, ("exit(w) ≠ ∅", true, "(non-spike)"))
    end
    if w.type === :refactor
        rc_ok, rc_detail = refactor_materialised_root_cause(st, w)
        push!(out, ("(A, causes, w) via materialised A", rc_ok, rc_detail))
    else
        push!(out, ("(A, causes, w) via materialised A", true, "(non-refactor)"))
    end
    push!(out, ("cynefin ≠ chaotic", w.cynefin !== :chaotic,
        w.cynefin === nothing ? "" : String(w.cynefin)))
    out
end

dor(st::State, w::Node)::Bool = all(t -> t[2], dor_breakdown(st, w))
dor(st::State, id::AbstractString)::Bool = dor(st, getnode(st, id))

function ready(st::State)::Vector{Node}
    out = Node[]
    for w in listnodes(st, :w)
        w.status === :ready || continue
        preds_clear(st, w.id) || continue
        dor(st, w) || continue
        push!(out, w)
    end
    out
end

function critical_path(st::State)::Vector{String}
    active = Set(w.id for w in listnodes(st, :w) if !isterminal(:w, w.status))
    succ = Dict{String,Vector{String}}()
    indeg = Dict{String,Int}(id => 0 for id in active)
    for e in st.edges
        e.label === :blocks || continue
        e.from in active || continue
        e.to in active || continue
        push!(get!(succ, e.from, String[]), e.to)
        indeg[e.to] = get(indeg, e.to, 0) + 1
    end
    queue = sort!([id for (id, d) in indeg if d == 0])
    topo = String[]
    indeg_w = copy(indeg)
    while !isempty(queue)
        x = popfirst!(queue)
        push!(topo, x)
        for s in get(succ, x, String[])
            indeg_w[s] -= 1
            if indeg_w[s] == 0
                push!(queue, s)
                sort!(queue)
            end
        end
    end
    dist = Dict{String,Int}(id => 1 for id in active)
    parent = Dict{String,Union{String,Nothing}}(id => nothing for id in active)
    for x in topo
        for s in get(succ, x, String[])
            if dist[x] + 1 > dist[s]
                dist[s] = dist[x] + 1
                parent[s] = x
            end
        end
    end
    isempty(dist) && return String[]
    tail = first(sort(collect(active); by=id -> (-dist[id], id)))
    chain = String[]
    cur::Union{String,Nothing} = tail
    while cur !== nothing
        push!(chain, cur)
        cur = parent[cur]
    end
    reverse(chain)
end

function packet(st::State, w::Node)::String
    io = IOBuffer()
    println(io, "# Execution packet: ", w.id, " (", w.title, ")")
    println(io)
    println(io, "type=", w.type, "  status=", w.status, "  cynefin=", w.cynefin)
    println(io)
    if !isempty(goals_of(w))
        println(io, "**Goals:** ", join(goals_of(w), ", "))
    end
    fitness = get(w.fields, :fitness, Dict{String,Int}())
    if !isempty(fitness)
        parts = [string(k, "=", v >= 0 ? "+" : "", v) for (k, v) in fitness]
        println(io, "**Fitness contribution:** ", join(parts, ", "))
    end
    println(io)
    for (label, fname) in (("Why", :why), ("Repro", :repro), ("Hypothesis", :hypothesis), ("Exit (spike)", :exit),
        ("Acceptance criteria", :ac),
        ("Evidence strategy", :evidence_strategy),
        ("Plan", :plan), ("Evidence", :evidence))
        lines = get(w.fields, fname, String[])
        isempty(lines) && continue
        println(io, "## ", label)
        println(io)
        for ln in lines
            println(io, "- ", ln)
        end
        println(io)
    end
    # Linked decisions.
    for did in implements_of(st, w)
        d = get(st.nodes, did, nothing)
        d === nothing && continue
        println(io, "## Decision ", d.id, ": ", d.title, "  (", d.status, ")")
        println(io)
        for fname in (:context, :options, :decision, :consequences, :validation)
            lines = get(d.fields, fname, String[])
            isempty(lines) && continue
            println(io, "**", String(fname), ":**")
            for ln in lines
                println(io, "- ", ln)
            end
            println(io)
        end
    end
    for bid in bchain(st, w)
        b = get(st.nodes, bid, nothing)
        b === nothing && continue
        println(io, "## Assumption ", b.id, ": ", b.title, "  (", b.status, ", ", b.cynefin, ")")
        for fname in (:vm, :threshold, :result)
            lines = get(b.fields, fname, String[])
            isempty(lines) && continue
            println(io, "**", String(fname), ":**")
            for ln in lines
                println(io, "- ", ln)
            end
        end
        println(io)
    end
    for qid in asks_of(st, w)
        q = get(st.nodes, qid, nothing)
        q === nothing && continue
        println(io, "## Question ", q.id, ": ", q.title, "  (", q.status, ", ", q.cynefin, ")")
        outcome = get(q.fields, :outcome, String[])
        if !isempty(outcome)
            println(io, "**outcome:**")
            for ln in outcome
                println(io, "- ", ln)
            end
        end
        println(io)
    end
    println(io, "## Definition of Ready")
    println(io)
    for (label, ok, detail) in dor_breakdown(st, w)
        sym = ok ? "⊤" : "⊥"
        if isempty(detail)
            println(io, "- ", sym, "  ", label, ".")
        else
            println(io, "- ", sym, "  ", label, " (", detail, ").")
        end
    end
    overall = dor(st, w) ? "⊤" : "⊥"
    println(io)
    println(io, "**result: ", overall, "**")
    String(take!(io))
end
