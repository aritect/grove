using JSON

const GROVE_JOURNAL_NAME = "journal.log"

journal_file(devdir_path::AbstractString)::String =
    joinpath(String(devdir_path), GROVE_JOURNAL_NAME)

"""After structural undo edits, rebuild `st.counters` from remaining ids / edges."""
function journal_reconcile_counters!(st::State)::Nothing
    empty!(st.counters)
    for nid in keys(st.nodes)
        record_id!(st, nid)
    end
    for e in st.edges
        record_id!(st, e.from)
        record_id!(st, e.to)
    end
    nothing
end

function append_journal_record!(journal_path::AbstractString, rec::AbstractDict)::Nothing
    mkpath(dirname(journal_path))
    open(journal_path, "a") do io
        println(io, JSON.json(rec))
    end
    nothing
end

"""Non-empty stripped lines and parsed records (paired 1:1)."""
function journal_read_nonempty_pairs(journal_path::AbstractString)::Tuple{Vector{String}, Vector{Dict{String,Any}}}
    rawlines = String[]
    recs = Dict{String,Any}[]
    !isfile(journal_path) && return (rawlines, recs)
    for line in eachline(journal_path)
        s = strip(line)
        isempty(s) && continue
        push!(rawlines, s)
        push!(recs, JSON.parse(s))
    end
    (rawlines, recs)
end

"""Last `n` journal records (chronological order). Returns nothing if unavailable."""
function journal_tail_preview(journal_path::AbstractString, n::Int)::Union{Nothing,Vector{Dict{String,Any}}}
    (n <= 0) && return nothing
    _, recs = journal_read_nonempty_pairs(journal_path)
    m = length(recs)
    (n > m || m == 0) && return nothing
    collect(recs[m-n+1:end])
end

"""Drop the last `n` nonempty JSON-lines (after successful in-memory undo)."""
function journal_truncate_tail_inplace!(journal_path::AbstractString, n::Int)::Nothing
    (n <= 0) && return nothing
    rawlines, recs = journal_read_nonempty_pairs(journal_path)
    m = length(recs)
    @assert n <= m
    if m == n
        rm(journal_path; force=true)
    else
        write(journal_path, join(rawlines[1:m-n], "\n") * "\n")
    end
    nothing
end

function wrap_journal_record(cmd::AbstractString, inv::AbstractDict)::Dict{String,Any}
    Dict{String,Any}("v" => 1, "ts" => utc_stamp_second(), "cmd" => String(cmd), "inv" => inv)
end

journal_inverse_rm_node(id::AbstractString)::Dict{String,Any} =
    Dict{String,Any}("op" => "rm_node", "id" => String(id))

journal_inverse_of_link_forward(label::Symbol, from::AbstractString, to::AbstractString)::Dict =
    Dict("op" => "unlink_edge", "from" => String(from), "label" => String(label), "to" => String(to))

function journal_inverse_restore_edge(from::AbstractString, label::Symbol, to::AbstractString,
                                     tc)::Dict
    d = Dict{String,Any}(
        "op" => "restore_edge",
        "from" => String(from),
        "label" => String(label),
        "to" => String(to),
    )
    if tc isa AbstractString && !isempty(strip(tc))
        d["t_created"] = String(tc)
    else
        d["t_created"] = ""
    end
    d
end

journal_inverse_restore_fitness_key(wid::AbstractString, gid::AbstractString,
                                    had_key::Bool, previous::Union{Nothing,Int})::Dict =
    Dict{String,Any}(
        "op" => "restore_fitness_key",
        "wid" => String(wid),
        "gid" => String(gid),
        "had_key" => had_key,
        "previous" => previous === nothing ? nothing : Int(previous),
    )

"""Restore `session` / `session_at` attrs from a journal `inv` (no-op if keys absent)."""
function journal_restore_w_session_attrs_if_present!(w::Node, inv)::Nothing
    haskey(inv, "had_session_before") || return nothing
    if Bool(inv["had_session_before"])
        w.attrs["session"] = String(get(inv, "old_session", "")::Union{String,Any})
    else
        delete!(w.attrs, "session")
    end
    if haskey(inv, "had_session_at_before")
        if Bool(inv["had_session_at_before"])
            w.attrs["session_at"] = String(get(inv, "old_session_at", "")::Union{String,Any})
        else
            delete!(w.attrs, "session_at")
        end
    end
    nothing
end

function journal_apply_inverse!(st::State, inv)::Union{Nothing,String}
    op = get(inv, "op", "")::String

    function fail(msg::AbstractString)::String
        string("journal undo: ", msg)
    end

    if op == "rm_node"
        id = String(inv["id"])
        !haskey(st.nodes, id) && return nothing
        delete!(st.nodes, id)
        filter!(e -> !(e.from == id || e.to == id), st.edges)
        journal_reconcile_counters!(st)
        return nothing
    elseif op == "unlink_edge"
        from, lb, to = String(inv["from"]), Symbol(inv["label"]), String(inv["to"])
        n0 = length(st.edges)
        filter!(e -> !(e.from == from && e.label === lb && e.to == to), st.edges)
        length(st.edges) == n0 && return fail("unlink_edge: missing edge $(from) $(lb) $(to)")
        haskey(st.nodes, from) && stamp_touch_node!(st.nodes[from])
        haskey(st.nodes, to) && stamp_touch_node!(st.nodes[to])
        return nothing
    elseif op == "restore_edge"
        from, lb, to = String(inv["from"]), Symbol(inv["label"]), String(inv["to"])
        if any(e -> e.from == from && e.label === lb && e.to == to, st.edges)
            return nothing
        end
        r = validate_and_push_edge!(st, from, lb, to)
        r !== nothing && return fail(r)
        ee = nothing
        for ed in reverse(st.edges)
            if ed.from == from && ed.label === lb && ed.to == to
                ee = ed
                break
            end
        end
        ee === nothing && return fail("restore_edge: edge missing after validate")
        tc = strip(String(get(inv, "t_created", "")))
        if isempty(tc)
            ee.t_created = nothing
        else
            ee.t_created = tc
        end
        return nothing
    elseif op == "set_cynefin"
        n = st.nodes[String(inv["id"])]
        o = inv["old"]
        n.cynefin = (!haskey(inv, "old") || o === nothing || isempty(String(o))) ? nothing : Symbol(String(o))
        stamp_touch_node!(n)
        return nothing
    elseif op == "set_type"
        n = st.nodes[String(inv["id"])]
        o = inv["old"]
        n.type = (!haskey(inv, "old") || o === nothing || isempty(String(o))) ? nothing : Symbol(String(o))
        stamp_touch_node!(n)
        return nothing
    elseif op == "set_title"
        n = st.nodes[String(inv["id"])]
        n.title = String(get(inv, "old", "")::Union{String,Any})
        stamp_touch_node!(n)
        return nothing
    elseif op == "set_g_attr_fitness"
        n = st.nodes[String(inv["id"])]
        n.attrs["fitness"] = String(get(inv, "old", "")::Union{String,Any})
        stamp_touch_node!(n)
        return nothing
    elseif op == "set_g_attr_fitness_kind"
        n = st.nodes[String(inv["id"])]
        if Bool(inv["had_before"])
            n.attrs["fitness_kind"] = String(inv["old"])
        else
            delete!(n.attrs, "fitness_kind")
        end
        stamp_touch_node!(n)
        return nothing
    elseif op == "set_r_attr_goal"
        n = st.nodes[String(inv["id"])]
        if haskey(inv, "had_before") && !Bool(inv["had_before"])
            delete!(n.attrs, "goal")
        else
            n.attrs["goal"] = String(inv["restore"])
        end
        stamp_touch_node!(n)
        return nothing
    elseif op == "set_r_attr_date"
        n = st.nodes[String(inv["id"])]
        if haskey(inv, "had_before") && !Bool(inv["had_before"])
            delete!(n.attrs, "date")
        else
            n.attrs["date"] = String(inv["restore"])
        end
        stamp_touch_node!(n)
        return nothing
    elseif op == "set_status_plain"
        n = st.nodes[String(inv["id"])]
        n.status = Symbol(String(inv["old_status"]))
        stamp_touch_node!(n)
        n.kind === :w && rederive_goals!(st, n)
        return nothing
    elseif op == "set_w_status_with_goals"
        gs = inv["goal_statuses"]
        gs isa AbstractDict || return fail("missing goal_statuses")
        for (gidv, sv) in gs
            gid = String(gidv)
            haskey(st.nodes, gid) || return fail("goal node missing $(gid)")
            st.nodes[gid].status = Symbol(String(sv))
            stamp_touch_node!(st.nodes[gid])
        end
        w = st.nodes[String(inv["id"])]
        w.status = Symbol(String(inv["old_w_status"]))
        journal_restore_w_session_attrs_if_present!(w, inv)
        stamp_touch_node!(w)
        rederive_goals!(st, w)
        return nothing
    elseif op == "session_restore_claim"
        w = st.nodes[String(inv["id"])]
        journal_restore_w_session_attrs_if_present!(w, inv)
        stamp_touch_node!(w)
        return nothing
    elseif op == "field_pop_last"
        n = st.nodes[String(inv["id"])]
        fsym = Symbol(String(inv["field"]))
        v = get_vector_field!(n, fsym)
        isempty(v) && return fail("field_pop_last empty $(fsym)")
        pop!(v)
        stamp_touch_node!(n)
        return nothing
    elseif op == "field_restore_lines"
        n = st.nodes[String(inv["id"])]
        fsym = Symbol(String(inv["field"]))
        arr = map(String, collect(inv["lines"]))
        form = FIELD_CATALOG[(n.kind, fsym)]
        (form === :prose || form === :reflist) || return fail("field_restore_lines wrong form")
        n.fields[fsym] = arr
        stamp_touch_node!(n)
        return nothing
    elseif op == "field_restore_fitness"
        n = st.nodes[String(inv["id"])]
        fsym = Symbol(String(inv["field"]))
        d = Dict{String,Int}()
        for (k0, vv) in inv["map"]
            d[String(k0)] = Int(round(vv))
        end
        n.fields[fsym] = d
        stamp_touch_node!(n)
        return nothing
    elseif op == "field_restore_single"
        n = st.nodes[String(inv["id"])]
        fsym = Symbol(String(inv["field"]))
        n.fields[fsym] = String(inv["value"])
        stamp_touch_node!(n)
        return nothing
    elseif op == "field_insert_line"
        n = st.nodes[String(inv["id"])]
        fsym = Symbol(String(inv["field"]))
        idx = Int(round(inv["index"]))
        v = get_vector_field!(n, fsym)
        (idx < 1 || idx > length(v) + 1) && return fail("field_insert_line bad index $(idx)")
        insert!(v, idx, String(inv["line"]))
        stamp_touch_node!(n)
        return nothing
    elseif op == "restore_fitness_key"
        w = st.nodes[String(inv["wid"])]
        gid = String(inv["gid"])
        fid = get!(w.fields, :fitness, Dict{String,Int}())
        if Bool(inv["had_key"])
            prev = inv["previous"]
            prev === nothing && return fail("restore_fitness_key missing previous")
            fid[gid] = Int(round(prev))
        else
            delete!(fid, gid)
        end
        stamp_touch_node!(w)
        return nothing
    elseif op == "renumber_swap"
        apply_renumber!(st, String(inv["from"]), String(inv["to"]))
        return nothing
    else
        return fail("unknown inverse op `$op`")
    end
end

function get_vector_field!(n::Node, fname::Symbol)::Vector{String}
    v = get(n.fields, fname, nothing)
    v isa Vector || (get!(n.fields, fname, String[]); v = n.fields[fname]::Vector)
    vv = String[e isa String ? e : string(e) for e in v]
    n.fields[fname] = vv
    vv
end
