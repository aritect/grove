@testset "render: artifacts table lists causes and themed columns" begin
    st = M.State()
    a = M.Node(:a, "A-01"; title="Codebase", status=:open)
    w1 = M.Node(:w, "W-01"; title="U", type=:feature, status=:proposed, cynefin=:clear)
    w1.fields[:theme] = "A-01"
    w2 = M.Node(:w, "W-02"; title="V", type=:feature, status=:proposed, cynefin=:clear)
    b = M.Node(:b, "B-01"; title="Hyp", status=:proposed, cynefin=:clear)
    d = M.Node(:d, "D-01"; title="ADR", status=:proposed)
    q = M.Node(:q, "Q-01"; title="?", status=:open, cynefin=:clear)
    g = M.Node(:g, "G-01"; title="Goal", status=:unverified)
    r = M.Node(:r, "R-01"; title="Retro", status=:draft)
    st.nodes["A-01"] = a
    st.nodes["W-01"] = w1
    st.nodes["W-02"] = w2
    st.nodes["B-01"] = b
    st.nodes["D-01"] = d
    st.nodes["Q-01"] = q
    st.nodes["G-01"] = g
    st.nodes["R-01"] = r
    push!(st.edges, M.Edge("A-01", :causes, "W-01"))
    push!(st.edges, M.Edge("W-01", :blocks, "W-02"))
    push!(st.edges, M.Edge("B-01", :targets, "W-02"))
    push!(st.edges, M.Edge("W-02", :produces, "D-01"))
    txt = M.render_index(st)
    @test occursin("## Artifacts", txt)
    @test occursin("| Causes work | Themed work |", txt)
    @test occursin("W-01", txt)
    @test occursin("==>|blocks|", txt)
    @test occursin("-.->|targets|", txt)
    @test occursin("-->|produces|", txt)
    @test occursin(":::retro", txt)
    m = match(r"classDef retro fill:#[0-9a-fA-F]+", txt)
    m2 = match(r"classDef decision fill:#[0-9a-fA-F]+", txt)
    @test m !== nothing && m2 !== nothing
    @test m.match != m2.match
end

@testset "render: index lists sections tables and mermaid edge styles with critical path" begin
    st = M.State()
    st.nodes["G-01"] = M.Node(:g, "G-01"; title="Goal \"A\"", status=:unverified)
    st.nodes["G-01"].attrs["fitness"] = "1/1 x"
    st.nodes["D-01"] = M.Node(:d, "D-01"; title="Decide", status=:proposed)
    st.nodes["Q-01"] = M.Node(:q, "Q-01"; title="Question", status=:open, cynefin=:clear)
    st.nodes["B-01"] = M.Node(:b, "B-01"; title="Assume", status=:proposed, cynefin=:clear)
    st.nodes["A-01"] = M.Node(:a, "A-01"; title="Artifact", status=:open)
    st.nodes["R-01"] = M.Node(:r, "R-01"; title="Retro", status=:open)
    st.nodes["R-01"].attrs["goal"] = "G-01"
    st.nodes["R-01"].attrs["date"] = "2026-05-05"
    st.nodes["Wf"] = M.Node(:w, "Wf"; title="Feat", type=:feature, status=:ready, cynefin=:clear)
    st.nodes["Ws"] = M.Node(:w, "Ws"; title="Spk", type=:spike, status=:proposed, cynefin=:clear)
    st.nodes["Wd"] = M.Node(:w, "Wd"; title="Done", type=:feature, status=:done, cynefin=:clear)
    st.nodes["Wp"] = M.Node(:w, "Wp"; title="Prog", type=:feature, status=:progress, cynefin=:clear)
    st.nodes["Wrj"] = M.Node(:w, "Wrj"; title="No", type=:feature, status=:rejected, cynefin=:clear)
    for w in ("Wf", "Ws", "Wd", "Wp", "Wrj")
        st.nodes[w].fields[:goals] = ["G-01"]
        st.nodes[w].fields[:fitness] = Dict("G-01" => 1)
        st.nodes[w].fields[:ac] = ["a"]
        st.nodes[w].fields[:hypothesis] = ["h"]
        st.nodes[w].fields[:evidence_strategy] = ["e"]
    end
    st.nodes["Wd"].fields[:evidence] = ["done"]
    push!(st.edges, M.Edge("Q-01", :asks, "Wf"))
    push!(st.edges, M.Edge("B-01", :targets, "Wf"))
    push!(st.edges, M.Edge("B-01", :tests, "Q-01"))
    push!(st.edges, M.Edge("D-01", :supersedes, "D-01"))
    push!(st.edges, M.Edge("A-01", :causes, "Wf"))
    st.nodes["Wt"] = M.Node(:w, "Wt"; title="Themed", type=:feature, status=:proposed, cynefin=:clear)
    st.nodes["Wt"].fields[:goals] = ["G-01"]
    st.nodes["Wt"].fields[:theme] = "A-01"
    st.nodes["Wt"].fields[:fitness] = Dict("G-01" => 1)
    st.nodes["Wt"].fields[:ac] = ["a"]
    st.nodes["Wt"].fields[:hypothesis] = ["h"]
    st.nodes["Wt"].fields[:evidence_strategy] = ["e"]
    push!(st.edges, M.Edge("Wf", :blocks, "Wt"))
    md = M.render_index(st)
    @test occursin("## Goals", md)
    @test occursin("| G-01 |", md)
    @test occursin("## Decisions", md)
    @test occursin("## Open questions", md)
    @test occursin("| Q-01 |", md)
    @test occursin("## Assumptions", md)
    @test occursin("| B-01 |", md)
    @test occursin("Q-01", md) && occursin("Wf", md)
    @test occursin("## Artifacts", md)
    @test occursin("| A-01 |", md)
    @test occursin("## Retrospectives", md) || occursin("Retro", md)
    @test occursin("==>|blocks|", md)
    @test occursin("-.->|targets|", md)
    @test occursin("-->|tests|", md)
    @test occursin("-->|asks|", md)
    @test occursin("-->|supersedes|", md)
    @test occursin("-->|causes|", md)
    @test occursin("class Wf", md) || occursin("Wf[", md)
    @test occursin(":::spike", md)
    @test occursin(":::done", md)
    @test occursin(":::progress", md)
    @test occursin(":::rejected", md)
    @test occursin(":::theme", md)
    @test occursin(":::goal", md)
    @test occursin("class Wf,Wt critical", md)
end

@testset "render: mermaid_safe maps hyphens and edge_line selects arrow style" begin
    @test M.mermaid_safe("W-01") == "W_01"
    @test M.mermaid_edge_line("A", "B", :blocks) == "  A ==>|blocks| B"
    @test M.mermaid_edge_line("A", "B", :targets) == "  A -.->|targets| B"
    @test M.mermaid_edge_line("A", "B", :implements) == "  A -->|implements| B"
end
