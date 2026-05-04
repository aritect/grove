@testset "lock: serialize body contains goals work and prose bullets" begin
    st = M.State()
    g = M.Node(:g, "G-01"; title="Migrate auth", status=:unverified)
    g.attrs["fitness"] = "5/5 modules"
    st.nodes["G-01"] = g
    M.record_id!(st, "G-01")

    w = M.Node(:w, "W-01"; title="Add login", type=:feature, status=:ready, cynefin=:clear)
    w.fields[:goals] = ["G-01"]
    w.fields[:fitness] = Dict("G-01" => 1)
    w.fields[:ac] = ["User signs in.", "Sessions expire after 24h."]
    w.fields[:hypothesis] = ["Email/password is enough for MVP."]
    w.fields[:evidence_strategy] = ["Integration test on /login."]
    st.nodes["W-01"] = w
    M.record_id!(st, "W-01")

    body = M.serialize_body(st)
    @test occursin("g G-01", body)
    @test occursin("w W-01", body)
    @test occursin("    | User signs in.", body)
    @test occursin("fitness: G-01=+1", body)

    tmp = tempname()
    M.write_lock(tmp, st)
    st2 = M.read_lock(tmp)
    @test haskey(st2.nodes, "G-01")
    @test haskey(st2.nodes, "W-01")
    @test st2.nodes["W-01"].fields[:ac] == ["User signs in.", "Sessions expire after 24h."]
    @test st2.nodes["W-01"].fields[:fitness] == Dict("G-01" => 1)
    rm(tmp)
end

@testset "lock: artifact spike edges targets produces round-trip" begin
    st = M.State()
    a = M.Node(:a, "A-01"; title="Codebase", status=:open)
    st.nodes["A-01"] = a
    M.record_id!(st, "A-01")
    w = M.Node(:w, "W-01"; title="Spike", type=:spike, status=:proposed, cynefin=:clear)
    st.nodes["W-01"] = w
    M.record_id!(st, "W-01")
    q = M.Node(:q, "Q-01"; title="Q", status=:open, cynefin=:clear)
    st.nodes["Q-01"] = q
    M.record_id!(st, "Q-01")
    b = M.Node(:b, "B-01"; title="B", status=:proposed, cynefin=:clear)
    st.nodes["B-01"] = b
    M.record_id!(st, "B-01")
    push!(st.edges, M.Edge("B-01", :targets, "W-01"))
    push!(st.edges, M.Edge("B-01", :tests, "Q-01"))
    push!(st.edges, M.Edge("Q-01", :asks, "W-01"))
    push!(st.edges, M.Edge("W-01", :produces, "Q-01"))
    tmp = tempname()
    M.write_lock(tmp, st)
    st2 = M.read_lock(tmp)
    @test st2.nodes["A-01"].kind === :a
    @test st2.nodes["A-01"].status === :open
    @test any(e -> e.label === :targets && e.from == "B-01" && e.to == "W-01", st2.edges)
    @test any(e -> e.label === :produces && e.from == "W-01" && e.to == "Q-01", st2.edges)
    rm(tmp)
end

@testset "lock: legacy reflists migrate to edges on write" begin
    st = M.State()
    st.nodes["D-01"] = M.Node(:d, "D-01"; title="old", status=:proposed)
    d2 = M.Node(:d, "D-02"; title="new", status=:proposed)
    d2.fields[:supersedes] = ["D-01"]
    st.nodes["D-02"] = d2
    M.record_id!(st, "D-01")
    M.record_id!(st, "D-02")
    tmp = tempname()
    M.write_lock(tmp, st)
    st2 = M.read_lock(tmp)
    @test !haskey(st2.nodes["D-02"].fields, :supersedes)
    @test any(e -> e.label === :supersedes && e.from == "D-02" && e.to == "D-01", st2.edges)
    rm(tmp)
end

@testset "lock: two serial writes preserve parseability" begin
    st = M.State()
    st.nodes["G-01"] = M.Node(:g, "G-01"; title="g", status=:unverified)
    M.record_id!(st, "G-01")
    tmp = mktempdir()
    p = joinpath(tmp, "state.lock")
    M.write_lock(p, st)
    st1 = M.read_lock(p)
    st1.nodes["G-01"].status = :verified
    M.write_lock(p, st1)
    st2 = M.read_lock(p)
    @test st2.nodes["G-01"].status === :verified
    rm(tmp; recursive=true)
end

@testset "lock: nodes and edges record timestamps on write" begin
    st = M.State()
    st.nodes["G-01"] = M.Node(:g, "G-01"; title="x", status=:unverified)
    st.nodes["W-01"] = M.Node(:w, "W-01"; title="y", type=:feature, status=:ready, cynefin=:clear)
    M.record_id!(st, "G-01")
    M.record_id!(st, "W-01")
    push!(st.edges, M.Edge("G-01", :blocks, "W-01"))
    tmp = tempname()
    M.write_lock(tmp, st)
    st2 = M.read_lock(tmp)
    rg = r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"
    tc = strip(st2.nodes["G-01"].attrs["t_created"])
    tu = strip(st2.nodes["G-01"].attrs["t_updated"])
    @test match(rg, tc) !== nothing
    @test tc == tu
    e = only(st2.edges)
    @test occursin("t_created=", read(tmp, String))
    ec = something(e.t_created, "")
    @test match(rg, String(ec)) !== nothing
    rm(tmp)
end

@testset "lock: checksum rejects tampered body" begin
    st = M.State()
    n = M.Node(:g, "G-01"; title="t", status=:unverified)
    st.nodes["G-01"] = n
    M.record_id!(st, "G-01")
    tmp = tempname()
    M.write_lock(tmp, st)
    txt = read(tmp, String)
    open(tmp, "w") do io
        print(io, replace(txt, "g G-01" => "g G-01 status=verified"; count=1))
    end
    @test_throws M.ChecksumMismatch M.read_lock(tmp)
    rm(tmp)
end

@testset "lock: id_allocation meta round-trip" begin
    st = M.State()
    st.id_stride = 4
    st.id_offset = 2
    st.id_pad_width = 3
    st.nodes["G-009"] = M.Node(:g, "G-009"; title="x", status=:unverified)
    M.record_id!(st, "G-009")
    tmp = tempname()
    M.write_lock(tmp, st)
    st2 = M.read_lock(tmp; verify=false)
    @test st2.id_stride == 4
    @test st2.id_offset == 2
    @test st2.id_pad_width == 3
    rm(tmp)
end

@testset "lock: parse rejects malformed headers fields and edges" begin
    magic = "@grove v1"
    hdr = "# AUTO-GENERATED. Do not edit. Use `grove` CLI."
    short_body = "g G-01 status=unverified \"x\""
    cks = M.checksum_of(short_body)

    good(sk::AbstractString) = join([magic, hdr, "# checksum: sha256:" * sk, "", short_body], "\n")

    err_parse(t::AbstractString) = try
        M.parse_lock(t)
        nothing
    catch e
        e
    end

    @test err_parse("") isa M.LockParseError
    @test err_parse("x\n$hdr\n# checksum: sha256:$cks\n\n$short_body") isa M.LockParseError
    @test err_parse("$magic\n(no comment)\n# checksum: sha256:$cks\n\n$short_body") isa M.LockParseError
    @test err_parse("$magic\n$hdr\n(no checksum)\n\n$short_body") isa M.LockParseError

    bad_prose = good(cks)[1:end]
    @test occursin(short_body, bad_prose)
    corrupt = replace(bad_prose, short_body => "    | orphan prose line"; count=1)
    @test err_parse(corrupt) isa M.LockParseError

    bad_field = good(cks)
    bad_field = replace(bad_field, short_body => "  typo_field: x"; count=1)
    @test err_parse(bad_field) isa M.LockParseError

    inline_prose = good(cks)
    inline_prose = replace(inline_prose, short_body => "w W-01 type=feature status=proposed cynefin=clear \"t\"\n  ac: nonempty"; count=1)
    ck2 = M.checksum_of(join(split(inline_prose, "\n")[5:end], "\n"))
    inline_prose = join([magic, hdr, "# checksum: sha256:" * ck2, "", join(split(inline_prose, "\n")[5:end], "\n")], "\n")
    @test err_parse(inline_prose) isa M.LockParseError

    bad_fit = join([
        magic, hdr,
        "# checksum: sha256:placeholder",
        "",
        "w W-01 type=feature status=proposed cynefin=clear \"t\"",
        "  goals: G-01",
        "  fitness: not_an_int",
    ], "\n")
    inner_bad = join(split(bad_fit, "\n")[5:end], "\n")
    bad_fit = replace(bad_fit, "# checksum: sha256:placeholder" => "# checksum: sha256:" * M.checksum_of(inner_bad))
    @test err_parse(bad_fit) isa M.LockParseError

    bad_edge = join([magic, hdr, "# checksum: sha256:placeholder", "", "e W-01 blocks"], "\n")
    inner_e = join(split(bad_edge, "\n")[5:end], "\n")
    bad_edge = replace(bad_edge, "placeholder" => M.checksum_of(inner_e))
    @test err_parse(bad_edge) isa M.LockParseError

    bad_kind = join([magic, hdr, "# checksum: sha256:placeholder", "", "z ZZ-01 \"bad\""], "\n")
    inner_z = join(split(bad_kind, "\n")[5:end], "\n")
    bad_kind = replace(bad_kind, "placeholder" => M.checksum_of(inner_z))
    @test err_parse(bad_kind) isa M.LockParseError

    dup_tc = join([
        magic, hdr,
        "# checksum: sha256:placeholder",
        "",
        "w W-01 type=feature status=proposed cynefin=clear \"t\"",
        "w W-02 type=feature status=proposed cynefin=clear \"u\"",
        "e W-01 blocks W-02 t_created=2020-01-01T00:00:00Z t_created=2020-01-02T00:00:00Z",
    ], "\n")
    inner_d = join(split(dup_tc, "\n")[5:end], "\n")
    dup_tc = replace(dup_tc, "placeholder" => M.checksum_of(inner_d))
    @test err_parse(dup_tc) isa M.LockParseError
end

@testset "lock: parse_qstring rejects unknown escapes" begin
    @test_throws ErrorException M.parse_qstring("\"\\q\"", 1)
end

@testset "lock: atomic_write_same_dir overwrites destination atomically" begin
    d = mktempdir()
    try
        p = joinpath(d, "blob")
        M.atomic_write_same_dir!(p, "one")
        @test read(p, String) == "one"
        M.atomic_write_same_dir!(p, "two")
        @test read(p, String) == "two"
    finally
        rm(d; recursive=true)
    end
end
