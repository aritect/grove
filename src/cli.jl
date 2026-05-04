const EXIT_OK = 0
const EXIT_ERR = 1
const EXIT_CHECKSUM = 2
const EXIT_INVARIANT = 3
const EXIT_GUARD = 4
const EXIT_NOTFOUND = 5

mutable struct CliCtx
    root::String
    quiet::Bool
    json::Bool
    no_render::Bool
end
CliCtx() = CliCtx(pwd(), false, false, false)

devdir(ctx::CliCtx) = joinpath(ctx.root, ".grove")
lockpath(ctx::CliCtx) = joinpath(devdir(ctx), "state.lock")
indexpath(ctx::CliCtx) = joinpath(devdir(ctx), "index.md")
glossarypath(ctx::CliCtx) = joinpath(devdir(ctx), "glossary.md")

function parse_args(args::Vector{String})::Tuple{CliCtx,Vector{String},Dict{String,String}}
    ctx = CliCtx()
    pos = String[]
    kw = Dict{String,String}()
    for a in args
        if startswith(a, "--")
            eq = findfirst('=', a)
            if eq === nothing
                key = a[3:end]; val = "true"
            else
                key = a[3:eq-1]; val = a[eq+1:end]
            end
            if key == "root"; ctx.root = abspath(val)
            elseif key == "quiet"; ctx.quiet = (val == "true")
            elseif key == "json"; ctx.json = (val == "true")
            elseif key == "no-render"; ctx.no_render = (val == "true")
            else; kw[key] = val
            end
        else
            push!(pos, a)
        end
    end
    ctx, pos, kw
end

function info(ctx::CliCtx, msg::AbstractString)
    ctx.quiet || println(stderr, msg)
end

function load(ctx::CliCtx; verify::Bool=true)::State
    p = lockpath(ctx)
    isfile(p) || (println(stderr, "lock not found: $p (run `grove init`)"); exit(EXIT_ERR))
    try
        return read_lock(p; verify=verify)
    catch e
        if e isa ChecksumMismatch
            println(stderr, sprint(showerror, e))
            exit(EXIT_CHECKSUM)
        end
        rethrow()
    end
end

function persist(ctx::CliCtx, st::State; journal::Union{Nothing,AbstractDict}=nothing)
    rederive_artifacts!(st)
    write_lock(lockpath(ctx), st)
    ctx.no_render || write_index(indexpath(ctx), st)
    journal !== nothing && append_journal_record!(journalpath(ctx), journal)
end

function cmd_init(ctx::CliCtx, pos, kw)
    isfile(lockpath(ctx)) && (println(stderr, "lock already exists at $(lockpath(ctx))"); return EXIT_ERR)
    isdir(devdir(ctx)) || mkpath(devdir(ctx))
    st = State()
    if haskey(kw, "id-stride")
        v = tryparse(Int, kw["id-stride"])
        v === nothing && (println(stderr, "bad --id-stride (expected integer)"); return EXIT_ERR)
        v < 1 && (println(stderr, "--id-stride must be ≥ 1"); return EXIT_ERR)
        st.id_stride = Int(v)
    end
    if haskey(kw, "id-offset")
        v = tryparse(Int, kw["id-offset"])
        v === nothing && (println(stderr, "bad --id-offset (expected integer)"); return EXIT_ERR)
        v < 1 && (println(stderr, "--id-offset must be ≥ 1"); return EXIT_ERR)
        st.id_offset = Int(v)
    end
    if haskey(kw, "id-width")
        w = tryparse(Int, kw["id-width"])
        w === nothing && (println(stderr, "bad --id-width (expected integer)"); return EXIT_ERR)
        w < 2 && (println(stderr, "--id-width must be ≥ 2"); return EXIT_ERR)
        st.id_pad_width = Int(w)
    elseif st.id_stride != 1 || st.id_offset != 1
        st.id_pad_width = max(st.id_pad_width, 3)
    end
    persist(ctx, st)
    isfile(glossarypath(ctx)) || open(glossarypath(ctx), "w") do io
        println(io, "# Glossary")
        println(io)
        println(io, "| Term | Definition | Source |")
        println(io, "| --- | --- | --- |")
    end
    info(ctx, "initialised: $(devdir(ctx))")
    EXIT_OK
end

function cmd_add(ctx::CliCtx, pos, kw)
    length(pos) >= 1 || (println(stderr, "usage: grove add <kind> [...]"); return EXIT_ERR)
    kind = Symbol(pos[1])
    kind in NODE_KINDS || (println(stderr, "unknown kind: $kind"); return EXIT_ERR)
    st = load(ctx)
    id = next_id!(st, kind)
    n = Node(kind, id)
    n.title = get(kw, "title", "")
    if kind === :w
        n.type = Symbol(get(kw, "type", "feature"))
        n.cynefin = Symbol(get(kw, "cynefin", "complicated"))
        n.status = Symbol(get(kw, "status", "proposed"))
        if haskey(kw, "goals"); n.fields[:goals] = String.(split(kw["goals"], ",")) end
        haskey(kw, "theme") && (n.fields[:theme] = kw["theme"])
    elseif kind === :g
        n.status = Symbol(get(kw, "status", "unverified"))
        haskey(kw, "fitness") && (n.attrs["fitness"] = kw["fitness"])
        if haskey(kw, "fitness-kind")
            fk = Symbol(lowercase(strip(kw["fitness-kind"])))
            fk in GOAL_FITNESS_KINDS || (println(stderr, "bad --fitness-kind"); return EXIT_ERR)
            n.attrs["fitness_kind"] = String(fk)
        end
        haskey(kw, "fitness-target") && (n.fields[:fitness_target] = kw["fitness-target"])
    elseif kind === :d
        n.status = Symbol(get(kw, "status", "proposed"))
    elseif kind === :q
        n.status = Symbol(get(kw, "status", "open"))
        n.cynefin = Symbol(get(kw, "cynefin", "complicated"))
    elseif kind === :b
        n.status = Symbol(get(kw, "status", "proposed"))
        n.cynefin = Symbol(get(kw, "cynefin", "complicated"))
    elseif kind === :r
        n.status = Symbol(get(kw, "status", "draft"))
        haskey(kw, "goal") && (n.attrs["goal"] = kw["goal"])
        haskey(kw, "date") && (n.attrs["date"] = kw["date"])
        if haskey(kw, "work-items"); n.fields[:work_items] = String.(split(kw["work-items"], ",")) end
    elseif kind === :a
        n.status = Symbol(get(kw, "status", "open"))
    end
    st.nodes[id] = n
    stamp_new_node!(n)

    rc = flush_add_edges!(kind, id, kw, st)
    rc !== nothing && return rc

    persist(ctx, st; journal=wrap_journal_record("add", journal_inverse_rm_node(id)))
    EXIT_OK
end

function flush_add_edges!(kind::Symbol, id::AbstractString, kw::Dict{String,String},
                          st::State)::Union{Nothing,Int}
    if kind === :d && haskey(kw, "supersedes")
        for oid in split(kw["supersedes"], ',')
            oid = strip(oid); isempty(oid) && continue
            r = validate_and_push_edge!(st, id, :supersedes, oid)
            if r !== nothing
                println(stderr, r); return EXIT_GUARD
            end
        end
    elseif kind === :q && haskey(kw, "targets")
        for tid in split(kw["targets"], ',')
            tid = strip(tid); isempty(tid) && continue
            r = validate_and_push_edge!(st, id, :asks, tid)
            if r !== nothing
                println(stderr, r); return EXIT_GUARD
            end
        end
    elseif kind === :b
        if haskey(kw, "tests")
            for qid in split(kw["tests"], ',')
                qid = strip(qid); isempty(qid) && continue
                r = validate_and_push_edge!(st, id, :tests, qid)
                if r !== nothing
                    println(stderr, r); return EXIT_GUARD
                end
            end
        end
        if haskey(kw, "targets")
            for wid in split(kw["targets"], ',')
                wid = strip(wid); isempty(wid) && continue
                r = validate_and_push_edge!(st, id, :targets, wid)
                if r !== nothing
                    println(stderr, r); return EXIT_GUARD
                end
            end
        end
    end
    nothing
end

function goal_notes_retro_deferred(g::Node)::Bool
    g.kind === :g || return false
    any(ln -> occursin("--retro-deferred", String(ln)), get(g.fields, :notes, String[]))
end

"""After `W → done`, if a linked goal has just become `verified`, remind stderr to capture a retrospective."""
function print_lazy_retro_prompt_on_newly_verified_goals!(
    io::IO, st::State, w::Node, old_goal_status::Dict{String,String},
)::Nothing
    w.kind === :w || return nothing
    for gid_raw in get(w.fields, :goals, String[])
        gid = String(strip(string(gid_raw)))
        isempty(gid) && continue
        ost = get(old_goal_status, gid, nothing)
        ost === nothing && continue
        Symbol(ost) === :verified && continue
        g = get(st.nodes, gid, nothing)
        (g === nothing || g.kind !== :g) && continue
        g.status !== :verified && continue
        goal_notes_retro_deferred(g) && continue
        println(io,
                "grove: goal ",
                gid,
                " (",
                g.title,
                ") is verified; capture learning with `grove add r --goal=",
                gid,
                "` when ready (lazy retro; see rules.md). To skip: add a `notes` prose line containing `--retro-deferred`.",
        )
    end
    nothing
end

function json_cli_out(obj::AbstractDict)::Nothing
    JSON.print(stdout, obj)
    println()
    nothing
end

function json_field_value(kind::Symbol, fname::Symbol, v::Any)::Any
    form = FIELD_CATALOG[(kind, fname)]
    if form === :prose || form === :reflist
        v === nothing && return String[]
        return String[v...]
    elseif form === :single
        return v === nothing ? "" : string(v)
    elseif form === :fitness
        v === nothing && return Dict{String,Int}()
        return Dict{String,Int}(v)
    end
    nothing
end

function json_node_snapshot(n::Node)::Dict{String,Any}
    fields = Dict{String,Any}()
    for fname in FIELD_ORDER[n.kind]
        haskey(n.fields, fname) || continue
        fields[string(fname)] = json_field_value(n.kind, fname, n.fields[fname])
    end
    d = Dict{String,Any}(
        "command" => "show",
        "record" => Dict{String,Any}(
            "kind" => string(n.kind),
            "id" => n.id,
            "title" => n.title,
            "status" => string(n.status),
            "archived" => n.archived,
            "attrs" => Dict{String,String}(string(k) => string(v) for (k, v) in n.attrs),
            "fields" => fields,
        ),
    )
    if n.type !== nothing
        d["record"]["type"] = string(n.type)
    end
    if n.cynefin !== nothing
        d["record"]["cynefin"] = string(n.cynefin)
    end
    d
end

function cmd_set(ctx::CliCtx, pos, kw)
    length(pos) >= 2 || (println(stderr, "usage: grove set <ID> <key>=<value>"); return EXIT_ERR)
    id = pos[1]
    eq = findfirst('=', pos[2])
    eq === nothing && (println(stderr, "expected key=value"); return EXIT_ERR)
    key = pos[2][1:eq-1]
    val = pos[2][eq+1:end]
    st = load(ctx)
    n = get(st.nodes, id, nothing)
    n === nothing && (println(stderr, "not found: $id"); return EXIT_NOTFOUND)
    eff = effective_session_token(ctx.root, kw)
    jr = nothing

    if key == "status"
        new_status = Symbol(val)
        if n.kind === :w && n.status === :progress && new_status !== :progress
            msg = session_denial_progress_release(n, eff)
            msg !== nothing && (println(stderr, msg); return EXIT_GUARD)
        end
        rc = guard_status_transition(st, n, new_status)
        rc != EXIT_OK && return rc
        old_status = n.status
        if n.kind === :w
            gs = Dict{String,String}()
            for gid in get(n.fields, :goals, String[])
                g = get(st.nodes, gid, nothing)
                g === nothing && continue
                gs[gid] = string(g.status)
            end
            inv = Dict{String,Any}(
                "op" => "set_w_status_with_goals",
                "id" => String(id),
                "old_w_status" => string(old_status),
                "goal_statuses" => gs,
            )
            merge!(inv, session_journal_snap(n))
            jr = wrap_journal_record("set", inv)
        else
            jr = wrap_journal_record("set", Dict{String,Any}(
                "op" => "set_status_plain",
                "id" => String(id),
                "old_status" => string(n.status),
            ))
        end
        n.status = new_status
        if n.kind === :w
            if new_status === :progress
                assign_w_claim_session!(n, eff)
            elseif old_status === :progress && new_status !== :progress
                clear_w_session_attrs!(n)
            end
            rederive_goals!(st, n)
            new_status === :done && print_lazy_retro_prompt_on_newly_verified_goals!(stderr, st, n, gs)
        end
        stamp_touch_node!(n)
        persist(ctx, st; journal=jr)
        return EXIT_OK
    end

    if n.kind === :w && n.status === :progress
        msg = session_denial_progress_mutate(n, eff)
        msg !== nothing && (println(stderr, msg); return EXIT_GUARD)
    end

    if key == "cynefin"
        jr = wrap_journal_record("set", Dict{String,Any}(
            "op" => "set_cynefin",
            "id" => String(id),
            "old" => n.cynefin === nothing ? "" : string(n.cynefin),
        ))
        n.cynefin = Symbol(val)
    elseif key == "type"
        jr = wrap_journal_record("set", Dict{String,Any}(
            "op" => "set_type",
            "id" => String(id),
            "old" => n.type === nothing ? "" : string(n.type),
        ))
        n.type = Symbol(val)
    elseif key == "title"
        jr = wrap_journal_record("set", Dict{String,Any}(
            "op" => "set_title",
            "id" => String(id),
            "old" => n.title,
        ))
        n.title = val
    elseif key == "fitness" && n.kind === :g
        jr = wrap_journal_record("set", Dict{String,Any}(
            "op" => "set_g_attr_fitness",
            "id" => String(id),
            "old" => get(n.attrs, "fitness", ""),
        ))
        n.attrs["fitness"] = val
        refresh_goal_structured_fitness!(st, n)
    elseif key == "fitness_kind" && n.kind === :g
        ks = Symbol(lowercase(strip(val)))
        ks in GOAL_FITNESS_KINDS || begin
                println(stderr,
                        "bad fitness_kind (expected one of: $(join(string.(GOAL_FITNESS_KINDS), ", ")))")
                return EXIT_ERR
            end
        hb = haskey(n.attrs, "fitness_kind")
        oldk = hb ? String(n.attrs["fitness_kind"]) : ""
        jr = wrap_journal_record("set", Dict{String,Any}(
            "op" => "set_g_attr_fitness_kind",
            "id" => String(id),
            "had_before" => hb,
            "old" => oldk,
            "new" => String(ks),
        ))
        n.attrs["fitness_kind"] = String(ks)
        refresh_goal_structured_fitness!(st, n)
    elseif key == "goal" && n.kind === :r
        had_before = haskey(n.attrs, "goal")
        restore_snap = had_before ? String(n.attrs["goal"]) : ""
        jr = wrap_journal_record("set", Dict{String,Any}(
            "op" => "set_r_attr_goal",
            "id" => String(id),
            "had_before" => had_before,
            "restore" => restore_snap,
        ))
        n.attrs["goal"] = val
    elseif key == "date" && n.kind === :r
        had_before = haskey(n.attrs, "date")
        restore_snap = had_before ? String(n.attrs["date"]) : ""
        jr = wrap_journal_record("set", Dict{String,Any}(
            "op" => "set_r_attr_date",
            "id" => String(id),
            "had_before" => had_before,
            "restore" => restore_snap,
        ))
        n.attrs["date"] = val
    else
        println(stderr, "unsupported key: $key"); return EXIT_ERR
    end
    stamp_touch_node!(n)
    persist(ctx, st; journal=jr)
    EXIT_OK
end

function guard_status_transition(st::State, n::Node, new::Symbol)::Int
    valid = STATUS[n.kind]
    new in valid || (println(stderr, "invalid status `$new` for $(n.kind)"); return EXIT_ERR)
    if n.kind === :a
        println(stderr, "artifact status is derived; cannot set manually")
        return EXIT_GUARD
    end
    if n.kind === :w && new === :progress
        dor(st, n) || (println(stderr, "DoR ≢ ⊤ for $(n.id); see `grove dor $(n.id)`"); return EXIT_GUARD)
        preds_clear(st, n.id) || (println(stderr, "I5: predecessors not cleared (goal blockers must be verified, not merely declined/partial/unverified)"); return EXIT_GUARD)
        wip = count(w -> w.status === :progress, listnodes(st, :w))
        wip >= WIP_LIMIT_DEFAULT && (println(stderr, "I4: WIP limit ($(WIP_LIMIT_DEFAULT)) reached"); return EXIT_GUARD)
    end
    if n.kind === :w && new === :done
        ev = get(n.fields, :evidence, String[])
        isempty(ev) && (println(stderr, "I3: $(n.id) has no evidence; use `grove evidence $(n.id) \"…\"`"); return EXIT_GUARD)
        gs = get(n.fields, :goals, String[])
        f = get(n.fields, :fitness, Dict{String,Int}())
        for g in gs
            haskey(f, g) || (println(stderr, "I10: missing fitness delta for $g; use `grove fitness $(n.id) $g <delta>`"); return EXIT_GUARD)
        end
    end
    if n.kind === :d && n.status === :accepted && new !== :superseded
        println(stderr, "decision $(n.id) is accepted; create a new D with --supersedes")
        return EXIT_GUARD
    end
    EXIT_OK
end

function cmd_field(ctx::CliCtx, pos, kw)
    length(pos) >= 3 || (println(stderr, "usage: grove field <ID> <field> add|rm|clear [value]"); return EXIT_ERR)
    id, fname, op = pos[1], Symbol(pos[2]), pos[3]
    st = load(ctx)
    n = get(st.nodes, id, nothing)
    n === nothing && (println(stderr, "not found: $id"); return EXIT_NOTFOUND)
    eff = effective_session_token(ctx.root, kw)
    if n.kind === :w && n.status === :progress
        msg = session_denial_progress_mutate(n, eff)
        msg !== nothing && (println(stderr, msg); return EXIT_GUARD)
    end
    form = get(FIELD_CATALOG, (n.kind, fname), nothing)
    form === nothing && (println(stderr, "unknown field $fname on $(n.kind)"); return EXIT_ERR)
    if n.kind === :g && fname === :fitness_current
        kg = goal_structured_kind(n)
        if kg !== nothing && kg !== :manual
            println(stderr,
                    "grove field: `fitness_current` is derived for structured goals; use kind=manual to author it")
            return EXIT_GUARD
        end
    end
    jr::Union{Nothing,Dict{String,Any}} = nothing
    if op == "clear"
        if form === :prose || form === :reflist
            oldv = String.(get_vector_field!(n, fname))
            jr = wrap_journal_record("field", Dict{String,Any}(
                "op" => "field_restore_lines",
                "id" => String(id),
                "field" => String(fname),
                "lines" => oldv,
            ))
            n.fields[fname] = String[]
        elseif form === :fitness
            oldd = Dict{String,Any}(k => Int(v) for (k, v) in copy(get!(n.fields, fname, Dict{String,Int}())))
            jr = wrap_journal_record("field", Dict{String,Any}(
                "op" => "field_restore_fitness",
                "id" => String(id),
                "field" => String(fname),
                "map" => oldd,
            ))
            n.fields[fname] = Dict{String,Int}()
        elseif form === :single
            prev = haskey(n.fields, fname) ? string(n.fields[fname]) : ""
            jr = wrap_journal_record("field", Dict{String,Any}(
                "op" => "field_restore_single",
                "id" => String(id),
                "field" => String(fname),
                "value" => prev,
            ))
            n.fields[fname] = ""
        end
    elseif op == "add"
        length(pos) >= 4 || (println(stderr, "missing value"); return EXIT_ERR)
        val = pos[4]
        if form === :prose
            jr = wrap_journal_record("field", Dict{String,Any}(
                "op" => "field_pop_last",
                "id" => String(id),
                "field" => String(fname),
            ))
            push!(get!(n.fields, fname, String[]), val)
        elseif form === :reflist
            jr = wrap_journal_record("field", Dict{String,Any}(
                "op" => "field_pop_last",
                "id" => String(id),
                "field" => String(fname),
            ))
            push!(get!(n.fields, fname, String[]), val)
        elseif form === :single
            prev = haskey(n.fields, fname) ? string(n.fields[fname]) : ""
            jr = wrap_journal_record("field", Dict{String,Any}(
                "op" => "field_restore_single",
                "id" => String(id),
                "field" => String(fname),
                "value" => prev,
            ))
            n.fields[fname] = val
        else
            println(stderr, "field $fname not addable"); return EXIT_ERR
        end
    elseif op == "rm"
        length(pos) >= 4 || (println(stderr, "missing index"); return EXIT_ERR)
        idx = parse(Int, pos[4])
        v = String.(copy(get_vector_field!(n, fname)))
        (idx < 1 || idx > length(v)) && (println(stderr, "index out of range"); return EXIT_ERR)
        removed = v[idx]
        jr = wrap_journal_record("field", Dict{String,Any}(
            "op" => "field_insert_line",
            "id" => String(id),
            "field" => String(fname),
            "index" => idx,
            "line" => removed,
        ))
        deleteat!(n.fields[fname], idx)
    else
        println(stderr, "unknown op: $op"); return EXIT_ERR
    end
    if n.kind === :g && fname === :fitness_target && op in ("add", "clear")
        refresh_goal_structured_fitness!(st, n)
    end
    stamp_touch_node!(n)
    persist(ctx, st; journal=jr)
    EXIT_OK
end

function guard_sessions_for_progress_endpoints!(io::IO, root::AbstractString, st::State, kw,
                                              from::AbstractString, to::AbstractString)::Int
    eff = effective_session_token(root, kw)
    for id in (from, to)
        n = get(st.nodes, id, nothing)
        n === nothing && continue
        n.kind !== :w && continue
        n.status !== :progress && continue
        msg = session_denial_progress_mutate(n, eff)
        msg !== nothing && (println(io, msg); return EXIT_GUARD)
    end
    EXIT_OK
end

function cmd_link(ctx::CliCtx, pos, kw)
    length(pos) >= 3 || (println(stderr, "usage: grove link <from> <label> <to>"); return EXIT_ERR)
    from, label, to = pos[1], Symbol(pos[2]), pos[3]
    label in EDGE_LABELS || (println(stderr, "unknown label: $label"); return EXIT_ERR)
    st = load(ctx)
    rc = guard_sessions_for_progress_endpoints!(stderr, ctx.root, st, kw, from, to)
    rc != EXIT_OK && return rc
    r = validate_and_push_edge!(st, from, label, to)
    if r !== nothing
        println(stderr, r)
        return EXIT_GUARD
    end
    jr = wrap_journal_record("link", journal_inverse_of_link_forward(label, from, to))
    persist(ctx, st; journal=jr)
    EXIT_OK
end

function cmd_unlink(ctx::CliCtx, pos, kw)
    length(pos) >= 3 || (println(stderr, "usage: grove unlink <from> <label> <to>"); return EXIT_ERR)
    from, label, to = pos[1], Symbol(pos[2]), pos[3]
    st = load(ctx)
    ee = nothing
    for e in st.edges
        if e.from == from && e.label === label && e.to == to
            ee = e
            break
        end
    end
    ee === nothing && (println(stderr, "no such edge"); return EXIT_NOTFOUND)
    rc = guard_sessions_for_progress_endpoints!(stderr, ctx.root, st, kw, from, to)
    rc != EXIT_OK && return rc
    jr = wrap_journal_record("unlink", journal_inverse_restore_edge(from, label, to, ee.t_created))
    filter!(e -> !(e.from == from && e.label === label && e.to == to), st.edges)
    haskey(st.nodes, from) && stamp_touch_node!(st.nodes[from])
    haskey(st.nodes, to) && stamp_touch_node!(st.nodes[to])
    persist(ctx, st; journal=jr)
    EXIT_OK
end

function cmd_evidence(ctx::CliCtx, pos, kw)
    length(pos) >= 2 || (println(stderr, "usage: grove evidence <W-NN> \"…\""); return EXIT_ERR)
    cmd_field(ctx, [pos[1], "evidence", "add", pos[2]], kw)
end

function cmd_fitness(ctx::CliCtx, pos, kw)
    length(pos) >= 3 || (println(stderr, "usage: grove fitness <W-NN> <G-NN> <±delta>"); return EXIT_ERR)
    wid, gid, delta = pos[1], pos[2], parse(Int, pos[3])
    st = load(ctx)
    w = get(st.nodes, wid, nothing); w === nothing && (println(stderr, "missing: $wid"); return EXIT_NOTFOUND)
    haskey(st.nodes, gid) || (println(stderr, "missing: $gid"); return EXIT_NOTFOUND)
    eff = effective_session_token(ctx.root, kw)
    msg = session_denial_progress_mutate(w, eff)
    msg !== nothing && (println(stderr, msg); return EXIT_GUARD)
    f = get!(w.fields, :fitness, Dict{String,Int}())
    had_key = haskey(f, gid)
    previous = had_key ? f[gid] : nothing
    f[gid] = delta
    stamp_touch_node!(w)
    jr = wrap_journal_record("fitness", journal_inverse_restore_fitness_key(wid, gid, had_key, previous))
    persist(ctx, st; journal=jr)
    EXIT_OK
end

function cmd_archive(ctx::CliCtx, pos, kw)
    length(pos) >= 1 || (println(stderr, "usage: grove archive <G-NN>"); return EXIT_ERR)
    gid = pos[1]
    st = load(ctx)
    g = get(st.nodes, gid, nothing); g === nothing && return EXIT_NOTFOUND
    g.status === :verified || (println(stderr, "goal must be verified"); return EXIT_GUARD)
    has_final_retro = any(r -> get(r.attrs, "goal", "") == gid && r.status === :final, listnodes(st, :r))
    has_final_retro || (println(stderr, "no final retrospective for $gid"); return EXIT_GUARD)
    eff = effective_session_token(ctx.root, kw)
    for w in listnodes(st, :w)
        gid in get(w.fields, :goals, String[]) || continue
        w.status !== :progress && continue
        msg = session_denial_progress_mutate(w, eff)
        msg !== nothing && (println(stderr, msg); return EXIT_GUARD)
    end
    ids = exclusive_archive_ids(st, gid)
    for id in ids
        n = st.nodes[id]
        n.archived = true
        stamp_touch_node!(n)
    end
    persist(ctx, st)
    EXIT_OK
end

function cmd_renumber(ctx::CliCtx, pos, kw)
    length(pos) >= 1 || (println(stderr, "usage: grove renumber <ID> --to=<NEW-ID>"); return EXIT_ERR)
    haskey(kw, "to") || (println(stderr, "missing --to=<NEW-ID>"); return EXIT_ERR)
    old_id = strip(pos[1])
    new_id = strip(kw["to"])
    isempty(new_id) && (println(stderr, "bad --to"); return EXIT_ERR)
    old_id == new_id && return EXIT_OK
    st = load(ctx)
    ow = get(st.nodes, old_id, nothing)
    eff = effective_session_token(ctx.root, kw)
    ow !== nothing &&
        ow.kind === :w &&
        ow.status === :progress && begin
                msg = session_denial_progress_mutate(ow, eff)
                msg !== nothing && begin println(stderr, msg); return EXIT_GUARD end
            end
    renumber_blocked_by_done_evidence(st, old_id) && begin
            println(stderr, "grove renumber: refusing; id occurs in evidence on a done W")
            return EXIT_GUARD
        end
    try
        apply_renumber!(st, old_id, new_id)
    catch e
        println(stderr, sprint(showerror, e))
        return EXIT_ERR
    end
    jr = wrap_journal_record("renumber",
                             Dict{String,Any}("op" => "renumber_swap", "from" => new_id,
                                               "to" => old_id))
    persist(ctx, st; journal=jr)
    EXIT_OK
end

function cmd_resume(ctx::CliCtx, pos, kw)
    length(pos) >= 1 || (println(stderr, "usage: grove resume <W-NN>"); return EXIT_ERR)
    id = pos[1]
    st = load(ctx)
    w = get(st.nodes, id, nothing)
    w === nothing && return EXIT_NOTFOUND
    w.kind === :w || (println(stderr, "not a work item"); return EXIT_ERR)
    w.status === :progress || (println(stderr, "$(id) is not in progress"); return EXIT_GUARD)
    eff = effective_session_token(ctx.root, kw)
    inv = merge(
        Dict{String,Any}("op" => "session_restore_claim", "id" => String(id)),
        session_journal_snap(w),
    )
    jr = wrap_journal_record("resume", inv)
    assign_w_claim_session!(w, eff)
    stamp_touch_node!(w)
    persist(ctx, st; journal=jr)
    EXIT_OK
end

function cmd_handoff(ctx::CliCtx, pos, kw)
    length(pos) >= 1 || (println(stderr, "usage: grove handoff <W-NN> --to=<token>"); return EXIT_ERR)
    haskey(kw, "to") || (println(stderr, "missing --to=<session-token>"); return EXIT_ERR)
    to_tok = strip(String(kw["to"]))
    isempty(to_tok) && (println(stderr, "empty --to"); return EXIT_ERR)
    id = pos[1]
    st = load(ctx)
    w = get(st.nodes, id, nothing)
    w === nothing && return EXIT_NOTFOUND
    w.kind === :w || (println(stderr, "not a work item"); return EXIT_ERR)
    w.status === :progress || (println(stderr, "$(id) is not in progress"); return EXIT_GUARD)
    eff = effective_session_token(ctx.root, kw)
    !progress_has_session_record(w) && (println(stderr, "$(id) has no session claim; use `grove resume`"); return EXIT_GUARD)
    !session_token_matches(w, eff) && (println(stderr, "only the holding session can hand off; use `grove resume` first"); return EXIT_GUARD)
    inv = merge(
        Dict{String,Any}("op" => "session_restore_claim", "id" => String(id)),
        session_journal_snap(w),
    )
    jr = wrap_journal_record("handoff", inv)
    assign_w_claim_session!(w, to_tok)
    stamp_touch_node!(w)
    persist(ctx, st; journal=jr)
    EXIT_OK
end

function cmd_revert(ctx::CliCtx, pos, kw)
    length(pos) >= 1 || (println(stderr, "usage: grove revert <W-NN>"); return EXIT_ERR)
    id = pos[1]
    st = load(ctx)
    w = get(st.nodes, id, nothing)
    w === nothing && return EXIT_NOTFOUND
    w.kind === :w || (println(stderr, "not a work item"); return EXIT_ERR)
    w.status === :progress || (println(stderr, "$(id) is not in progress"); return EXIT_GUARD)
    eff = effective_session_token(ctx.root, kw)
    msg = session_denial_progress_release(w, eff)
    msg !== nothing && (println(stderr, msg); return EXIT_GUARD)
    gs = Dict{String,String}()
    for gid in get(w.fields, :goals, String[])
        g = get(st.nodes, gid, nothing)
        g === nothing && continue
        gs[gid] = string(g.status)
    end
    inv = Dict{String,Any}(
        "op" => "set_w_status_with_goals",
        "id" => String(id),
        "old_w_status" => "progress",
        "goal_statuses" => gs,
    )
    merge!(inv, session_journal_snap(w))
    jr = wrap_journal_record("revert", inv)
    w.status = :ready
    clear_w_session_attrs!(w)
    rederive_goals!(st, w)
    stamp_touch_node!(w)
    persist(ctx, st; journal=jr)
    EXIT_OK
end

function cmd_render(ctx::CliCtx, pos, kw)
    st = load(ctx)
    write_index(indexpath(ctx), st)
    EXIT_OK
end

function cmd_undo(ctx::CliCtx, pos, kw)
    jp = journalpath(ctx)
    (!isfile(jp) || filesize(jp) == 0) && begin
            println(stderr, "grove undo: no journal at $jp"); return EXIT_ERR
        end
    steps = if haskey(kw, "steps")
            v = tryparse(Int, kw["steps"])
            v === nothing && begin println(stderr, "grove undo: bad --steps"); return EXIT_ERR end
            max(Int(v), 0)
        else
            1
        end
    steps == 0 && return EXIT_OK
    tail_recs = journal_tail_preview(jp, steps)
    tail_recs === nothing && begin
            println(stderr, "grove undo: journal has fewer than $steps entr$(steps == 1 ? "y" : "ies")"); return EXIT_ERR
        end
    st = load(ctx)
    for rec in reverse(tail_recs)
        inv = get(rec, "inv", nothing)
        inv isa AbstractDict || begin println(stderr, "grove undo: record missing inverse"); return EXIT_ERR end
        msg = journal_apply_inverse!(st, inv)
        msg !== nothing && begin println(stderr, msg); return EXIT_INVARIANT end
    end
    journal_reconcile_counters!(st)
    journal_truncate_tail_inplace!(jp, steps)
    persist(ctx, st)
    EXIT_OK
end

function cmd_repair(ctx::CliCtx, pos, kw)
    haskey(kw, "confirm") || (println(stderr, "refusing without --confirm"); return EXIT_ERR)
    p = lockpath(ctx)
    text = replace(read(p, String), "\r\n" => "\n")
    st, _, _ = parse_lock(text)
    persist(ctx, st)
    info(ctx, "repaired: $(p)")
    EXIT_OK
end

function cmd_ready(ctx::CliCtx, pos, kw)
    st = load(ctx)
    cp = Set(critical_path(st))
    rs = ready(st)
    sort!(rs; by=w -> ((w.id in cp) ? 0 : 1, -length(impact(st, w.id)), w.id))
    if ctx.json
        items = Dict{String,Any}[
            Dict("id" => w.id, "title" => w.title, "critical" => w.id in cp) for w in rs
        ]
        json_cli_out(Dict("command" => "ready", "items" => items))
        return EXIT_OK
    end
    for w in rs
        flag = w.id in cp ? " [crit]" : ""
        println(w.id, "  ", w.title, flag)
    end
    EXIT_OK
end

function cmd_next(ctx::CliCtx, pos, kw)
    st = load(ctx)
    rs = ready(st)
    isempty(rs) && (println(stderr, "no ready work items"); return EXIT_OK)
    cp = Set(critical_path(st))
    crit = filter(w -> w.id in cp, rs)
    pick = isempty(crit) ? first(rs) : first(crit)
    pkt = packet(st, pick)
    if ctx.json
        json_cli_out(Dict("command" => "next", "work" => pick.id, "packet_markdown" => pkt))
        return EXIT_OK
    end
    print(pkt)
    EXIT_OK
end

function cmd_packet(ctx::CliCtx, pos, kw)
    length(pos) >= 1 || (println(stderr, "usage: grove packet <W-NN>"); return EXIT_ERR)
    st = load(ctx)
    n = get(st.nodes, pos[1], nothing)
    n === nothing && (println(stderr, "not found"); return EXIT_NOTFOUND)
    n.kind === :w || (println(stderr, "not a work item"); return EXIT_ERR)
    pkt = packet(st, n)
    if ctx.json
        json_cli_out(Dict("command" => "packet", "work" => n.id, "packet_markdown" => pkt))
        return EXIT_OK
    end
    print(pkt)
    EXIT_OK
end

function cmd_deps(ctx::CliCtx, pos, kw)
    length(pos) >= 1 || return EXIT_ERR
    st = load(ctx)
    pred = deps(st, pos[1])
    if ctx.json
        json_cli_out(Dict(
            "command" => "deps",
            "id" => String(pos[1]),
            "predecessors" => pred,
        ))
        return EXIT_OK
    end
    for id in pred
        println(id)
    end
    EXIT_OK
end

function cmd_impact(ctx::CliCtx, pos, kw)
    length(pos) >= 1 || return EXIT_ERR
    st = load(ctx)
    succ = impact(st, pos[1])
    if ctx.json
        json_cli_out(Dict(
            "command" => "impact",
            "id" => String(pos[1]),
            "successors" => succ,
        ))
        return EXIT_OK
    end
    for id in succ
        println(id)
    end
    EXIT_OK
end

function cmd_path(ctx::CliCtx, pos, kw)
    st = load(ctx)
    chain = critical_path(st)
    if ctx.json
        json_cli_out(Dict("command" => "path", "chain" => chain))
        return EXIT_OK
    end
    for id in chain
        println(id)
    end
    EXIT_OK
end

function cmd_dor(ctx::CliCtx, pos, kw)
    length(pos) >= 1 || return EXIT_ERR
    st = load(ctx)
    n = get(st.nodes, pos[1], nothing)
    n === nothing && return EXIT_NOTFOUND
    if ctx.json
        conj = [
            Dict{String,Any}("label" => label, "ok" => ok, "detail" => detail)
            for (label, ok, detail) in dor_breakdown(st, n)
        ]
        json_cli_out(Dict(
            "command" => "dor",
            "work" => n.id,
            "conjuncts" => conj,
            "dor" => dor(st, n),
        ))
        return EXIT_OK
    end
    println(n.id, " DoR:")
    for (label, ok, detail) in dor_breakdown(st, n)
        sym = ok ? "⊤" : "⊥"
        if isempty(detail)
            println("  ", sym, "  ", label)
        else
            println("  ", sym, "  ", label, "  → ", detail)
        end
    end
    overall = dor(st, n) ? "⊤" : "⊥"
    println("result: ", overall)
    EXIT_OK
end

function cmd_show(ctx::CliCtx, pos, kw)
    length(pos) >= 1 || return EXIT_ERR
    st = load(ctx)
    n = get(st.nodes, pos[1], nothing)
    n === nothing && return EXIT_NOTFOUND
    if ctx.json
        json_cli_out(json_node_snapshot(n))
        return EXIT_OK
    end
    io = IOBuffer()
    serialize_node!(io, n)
    print(String(take!(io)))
    EXIT_OK
end

function cmd_list(ctx::CliCtx, pos, kw)
    length(pos) >= 1 || (println(stderr, "usage: grove list <kind>"); return EXIT_ERR)
    kind = Symbol(pos[1])
    st = load(ctx)
    rows = listnodes(st, kind)
    fstatus = get(kw, "status", "")
    fcynefin = get(kw, "cynefin", "")
    outrows = Dict{String,Any}[]
    for n in rows
        isempty(fstatus) || String(n.status) == fstatus || continue
        isempty(fcynefin) || (n.cynefin !== nothing && String(n.cynefin) == fcynefin) || continue
        row = Dict{String,Any}(
            "id" => n.id,
            "status" => string(n.status),
            "title" => n.title,
        )
        if n.cynefin !== nothing
            row["cynefin"] = string(n.cynefin)
        end
        push!(outrows, row)
    end
    if ctx.json
        d = Dict{String,Any}(
            "command" => "list",
            "kind" => String(kind),
            "rows" => outrows,
        )
        isempty(fstatus) || (d["filter_status"] = fstatus)
        isempty(fcynefin) || (d["filter_cynefin"] = fcynefin)
        json_cli_out(d)
        return EXIT_OK
    end
    for n in rows
        isempty(fstatus) || String(n.status) == fstatus || continue
        isempty(fcynefin) || (n.cynefin !== nothing && String(n.cynefin) == fcynefin) || continue
        println(n.id, "\t", n.status, "\t", n.title)
    end
    EXIT_OK
end

function cmd_graph(ctx::CliCtx, pos, kw)
    st = load(ctx)
    io = IOBuffer()
    render_graph!(io, st)
    text = String(take!(io))
    if ctx.json
        json_cli_out(Dict("command" => "graph", "mermaid" => text))
        return EXIT_OK
    end
    print(text)
    EXIT_OK
end

function cmd_log(ctx::CliCtx, pos, kw)
    st = load(ctx)
    lfilt = nothing
    if length(pos) >= 1
        id0 = pos[1]
        jp0 = journalpath(ctx)
        ok = haskey(st.nodes, id0) || any(e -> e.from == id0 || e.to == id0, st.edges)
        !ok && journal_file_mentions_id(jp0, id0) && (ok = true)
        !ok && (println(stderr, "not found: $id0"); return EXIT_NOTFOUND)
        lfilt = id0
    end
    lim = if haskey(kw, "limit")
        v = tryparse(Int, kw["limit"])
        v === nothing && begin
                println(stderr, "bad --limit (expected integer)")
                return EXIT_ERR
            end
        v::Int
    else
        200
    end
    rows = log_timeline(st; idfilt=lfilt, limit=lim, journal_path=journalpath(ctx))
    if ctx.json
        jr = [
            Dict{String,Any}("ts" => r.ts, "sort" => r.tiebreaker, "line" => r.line) for r in rows
        ]
        d = Dict{String,Any}(
            "command" => "log",
            "limit" => lim,
            "rows" => jr,
        )
        lfilt === nothing || (d["id_filter"] = lfilt)
        json_cli_out(d)
        return EXIT_OK
    end
    print_timeline(rows)
    EXIT_OK
end

function cmd_diff(ctx::CliCtx, pos, kw)
    ref = get(kw, "since", "HEAD")
    rp = abspath(ctx.root)
    git_repository_root(rp) || begin
            println(stderr, "grove diff: not a git repository (--root=`$rp`): cannot resolve `$ref:.grove/state.lock` via git")
            return EXIT_ERR
        end
    wt_path = lockpath(ctx)
    isfile(wt_path) || begin
            println(stderr, "lock not found: $wt_path")
            return EXIT_ERR
        end
    wt_text = read_worktree_lock_text(wt_path)
    st_wt = try
        parse_lock(wt_text)[1]
    catch e
        e isa LockParseError || rethrow()
        println(stderr, sprint(showerror, e))
        return EXIT_ERR
    end
    blob, gerr = git_show_path(rp, ref, ".grove/state.lock")
    blob === nothing && begin
            println(stderr, "grove diff: ", gerr)
            return EXIT_ERR
        end
    st_ref = try
        parse_lock(blob)[1]
    catch e
        e isa LockParseError || rethrow()
        println(stderr, sprint(showerror, e))
        println(stderr, " (while parsing `$ref:.grove/state.lock`)")
        return EXIT_ERR
    end
    if ctx.json
        pl = lock_structural_diff_payload(st_ref, st_wt)
        pl["command"] = "diff"
        pl["since"] = ref
        json_cli_out(pl)
        return EXIT_OK
    end
    print_lock_structural_diff(stdout, ref, st_ref, st_wt)
    EXIT_OK
end

function cmd_status(ctx::CliCtx, pos, kw)
    st = load(ctx)
    eff = effective_session_token(ctx.root, kw)
    prog = Node[w for w in listnodes(st, :w) if w.status === :progress]
    sort!(prog; by=w -> w.id)
    if ctx.json
        items = Dict{String,Any}[]
        for w in prog
            tok = progress_has_session_record(w) ? String(w.attrs["session"]) : ""
            stale = progress_session_display_stale(w, eff)
            line2 = if isempty(tok)
                        "  (no session= on record; I11 broken — use `grove resume $(w.id)` or re-claim progress)"
                    else
                        flag = session_token_matches(w, eff) ? "" : "  [!= this session]"
                        age = session_claim_age_stale(w) ? "  (claimed >$(SESSION_DISPLAY_STALE_AFTER_HOURS)h ago)" : ""
                        string("  session=", tok, flag, age)
                    end
            opts = stale ? "grove resume $(w.id) | grove revert $(w.id) | grove handoff $(w.id) --to=<token>" : ""
            push!(items, Dict{String,Any}(
                "id" => w.id,
                "title" => w.title,
                "session" => tok,
                "stale_for_agent" => stale,
                "session_detail" => line2,
                "options_hint" => opts,
            ))
        end
        al = alignment_triggers(st)
        inv = check_all(st)
        json_cli_out(Dict(
            "command" => "status",
            "progress" => items,
            "alignment_triggers" => al,
            "invariants" => Dict(
                "ok" => isempty(inv),
                "messages" => inv,
            ),
        ))
        return EXIT_OK
    end
    println("# grove status")
    println()
    println("## Work in `progress`")
    println()
    if isempty(prog)
        println("(none)")
    else
        for w in prog
            tok = progress_has_session_record(w) ? String(w.attrs["session"]) : ""
            stale = progress_session_display_stale(w, eff)
            line2 = if isempty(tok)
                        "  (no session= on record; I11 broken — use `grove resume $(w.id)` or re-claim progress)"
                    else
                        flag = session_token_matches(w, eff) ? "" : "  [!= this session]"
                        age = session_claim_age_stale(w) ? "  (claimed >$(SESSION_DISPLAY_STALE_AFTER_HOURS)h ago)" : ""
                        string("  session=", tok, flag, age)
                    end
            if stale
                println(w.id, "\t", w.title, "  (stale for this agent)\n", line2)
                println("  options: `grove resume $(w.id)` | `grove revert $(w.id)` | `grove handoff $(w.id) --to=<token>`")
            else
                println(w.id, "\t", w.title, "\n", line2)
            end
        end
    end
    println()
    println("## Alignment triggers (protocol 2.5)")
    println()
    al = alignment_triggers(st)
    if isempty(al)
        println("(none)")
    else
        for line in al
            println("- ", line)
        end
    end
    println()
    println("## Structure / invariants (same as `check`, non-blocking here)")
    println()
    inv = check_all(st)
    if isempty(inv)
        println("ok")
    else
        for e in inv
            println("- ", e)
        end
    end
    EXIT_OK
end

function cmd_check(ctx::CliCtx, pos, kw)
    st = try
        load(ctx; verify=true)
    catch e
        rethrow()
    end
    errs = check_all(st)
    if ctx.json
        json_cli_out(Dict(
            "command" => "check",
            "ok" => isempty(errs),
            "errors" => errs,
        ))
        return isempty(errs) ? EXIT_OK : EXIT_INVARIANT
    end
    if isempty(errs)
        info(ctx, "ok")
        return EXIT_OK
    end
    for e in errs; println(stderr, e); end
    EXIT_INVARIANT
end

const COMMANDS = Dict{String,Function}(
    "init" => cmd_init,
    "add" => cmd_add,
    "set" => cmd_set,
    "field" => cmd_field,
    "link" => cmd_link,
    "unlink" => cmd_unlink,
    "evidence" => cmd_evidence,
    "fitness" => cmd_fitness,
    "archive" => cmd_archive,
    "render" => cmd_render,
    "repair" => cmd_repair,
    "ready" => cmd_ready,
    "next" => cmd_next,
    "packet" => cmd_packet,
    "deps" => cmd_deps,
    "impact" => cmd_impact,
    "path" => cmd_path,
    "dor" => cmd_dor,
    "show" => cmd_show,
    "list" => cmd_list,
    "graph" => cmd_graph,
    "check" => cmd_check,
    "status" => cmd_status,
    "diff" => cmd_diff,
    "log" => cmd_log,
    "renumber" => cmd_renumber,
    "resume" => cmd_resume,
    "handoff" => cmd_handoff,
    "revert" => cmd_revert,
    "undo" => cmd_undo,
)

const HELP = """
grove (graph-driven reasoning over verified evidence)

Read:
  ready              list work items ready to start (critical first)
  next               propose single next W with full execution packet
  packet  <W-NN>     full execution packet for a W
  deps    <ID>       transitive blocks-predecessors
  impact  <ID>       transitive blocks-successors
  path               critical path (longest unfinished blocks chain)
  dor     <W-NN>     DoR conjunct breakdown
  show    <ID>       record dump
  list    <kind>     list nodes (g|w|d|q|b|r|a) [--status= --cynefin=]
  graph              print mermaid block
  status             summary: progress work, alignment triggers, invariant notes
  diff               structural diff vs git ref (--since=REF, default HEAD)
  log   [<ID>]      timeline from t_* on nodes/edges + journal.log (--limit=N, default 200; 0=unlimited)

Mutate:
  init                            create .grove/state.lock + index.md + glossary.md [--id-stride=N] [--id-offset=K] [--id-width=W]
  add <kind> --title="…" [...]    create node; prints assigned ID
  set <ID> <key>=<value>          guarded transitions
  field <ID> <field> add|rm|clear "…"
  link <from> <label> <to>        labels: blocks|implements|asks|tests|targets|produces|causes|supersedes
  unlink <from> <label> <to>
  evidence <W-NN> "…"             append evidence line
  fitness  <W-NN> <G-NN> <±N>     set per-goal delta
  archive  <G-NN>                 archive G + exclusive w/d/q/b/a
  renumber <ID> --to=<NEW-ID>      rewrite record + refs (not if id in done evidence)
  undo [--steps=N]                revert last N mutations (truncates `.grove/journal.log`)
  resume  <W-NN>                   adopt session token on a `progress` W (journal undo restores prior claim)
  handoff <W-NN> --to=<token>      transfer ownership (holder only)
  revert  <W-NN>                   `progress` -> `ready`, clear session (holder or stale claim)
  render                          regenerate index.md
  repair --confirm                accept current lock contents (recompute checksum)

Global flags: --root=<path> --quiet --json --no-render [--session=<token>]  (--since for diff; --limit for log; --steps for undo)
"""

const SESSION_READ_COMMANDS = Set([
    "ready", "next", "packet", "deps", "impact", "path", "dor",
    "show", "list", "graph", "check", "status", "diff", "log",
])

const SESSION_MUTATE_COMMANDS = Set([
    "init", "add", "set", "field", "link", "unlink", "evidence", "fitness",
    "archive", "repair", "render", "undo", "renumber",
    "resume", "handoff", "revert",
])

include("session_lock.jl")

function main(args::Vector{String})::Int
    isempty(args) && (print(HELP); return EXIT_OK)
    if args[1] in ("-h", "--help", "help")
        print(HELP); return EXIT_OK
    end
    cmd = args[1]
    rest = args[2:end]
    ctx, pos, kw = parse_args(rest)
    fn = get(COMMANDS, cmd, nothing)
    fn === nothing && (println(stderr, "unknown command: $cmd"); print(stderr, HELP); return EXIT_ERR)
    thunk = () -> fn(ctx, pos, kw)
    try
        rc = if cmd in SESSION_READ_COMMANDS
            with_session_shared(ctx, thunk)
        elseif cmd in SESSION_MUTATE_COMMANDS
            with_session_exclusive(ctx, thunk)
        else
            thunk()
        end
        return rc
    catch e
        if e isa SessionLockTimeoutError
            println(stderr, sprint(showerror, e))
            return EXIT_GUARD
        end
        if e isa LockParseError
            println(stderr, sprint(showerror, e))
            return EXIT_ERR
        end
        rethrow()
    end
end

main(args::AbstractVector) = main(String.(collect(args)))
