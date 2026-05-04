# grove

Graph-driven reasoning over verified evidence. A formal workflow protocol for AI coding agents: deterministic Definition of Ready, falsifiable assumption gates, atomic done-transitions; state lives in a single line-oriented lock file; the agent reads only what the current step demands. Designed to let weak agents go deep without hallucinating.

```mermaid
flowchart LR
    G[Goals] --> W[Work Items]
    W --> E[Evidence]
    W --> A[Assumptions]
    A --> Q[Questions]
    W --> D[Decisions]
```

**Core ideas (analogues in brackets):**

- Discovery and Delivery run in parallel \[Dual-Track Agile, Cagan].
- Every executable unit has explicit acceptance criteria before code is written \[HDD, Definition of Ready].
- Long-lived design choices are first-class artifacts \[ADR, Nygard].
- Open unknowns are first-class artifacts; agents declare them rather than pretend to know \[Continuous Discovery; Cynefin].
- Refactoring uses a Mikado-style dependency graph distinguishing causation, sequencing, implementation, and inquiry.

## Core invariants

```text
I₁:  ∀ w ∈ W with status = progress, DoR(w) ≡ ⊤.
I₂:  ∀ w with type = spike ∧ status = done,
      produces(w) ⊆ D ∪ Q ∪ B  ∧  produces(w) ≠ ∅.
I₃:  ∀ w with status = done, ∃ ev ∈ Evidence, satisfies(ev, AC(w)).
I₄:  |{ w ∈ W : status(w) = progress }| ≤ WIP_LIMIT (default 2).
I₅:  ∀ (n₁, blocks, n₂) ∈ E, terminal⁺(n₁) before status(n₂) may transition to progress.
I₆:  ∀ a ∈ A, status(a) = done ⟺ ∀ w ∈ WI(a), status(w) ∈ { done, rejected, archived }.
I₇:  graph (N, E ∩ (· × {blocks} × ·)) is a DAG.
I₈:  ∀ q ∈ Q with cynefin(q) = chaotic, status transitions only via human.
I₉:  ∀ w ∈ W with type = feature, DoR(w) ⇒
      ∀ b ∈ BChain(w), status(b) ∈ { validated, invalidated_acceptable }.
I₁₀: status transition w → done is atomic with applying fitness deltas
      to each g ∈ goals(w) and re-deriving status(g). Either both succeed or
      neither does. The CLI rejects status=done unless deltas are staged
      in the same call (or pre-staged via `grove fitness` since the last
      status mutation of w).
I₁₁: ∀ w ∈ W with status = progress, the session that set it is the only
      session permitted to mutate w until terminal(w) or w leaves `progress`
      (e.g. `revert` or another guarded status change). Persisted as header
      attrs `session` and `session_at` (UTC); `check` rejects a missing token
      (`grove resume` adopts; see protocol §2.6).
```

with terminality:

```text
terminal(w ∈ W)  ⟺ status(w) ∈ { done, rejected, archived }
terminal⁺(g ∈ G) ⟺ status(g) = verified (strict for blocks-edges)
terminal(g ∈ G)  ⟺ status(g) ∈ { verified, declined }
terminal(d ∈ D)  ⟺ status(d) ∈ { accepted, rejected, superseded }
terminal(q ∈ Q)  ⟺ status(q) ∈ { answered, deferred, dropped }
terminal(b ∈ B)  ⟺ status(b) ∈ { validated, invalidated_acceptable, invalidated_blocking }
terminal(a ∈ A)  ⟺ status(a) = done
```

`terminal⁺` is the strict variant used for `blocks` edges: a `declined` goal
does not unblock dependents. Other relations use the lax `terminal`.

```text
assumptions(w) ≜ { b ∈ B | (b, targets, w) ∈ E }
BChain(w)      ≜ assumptions(w) ∪ { b ∈ B | ∃ q, (q, asks, w) ∈ E ∧ (b, tests, q) ∈ E }
produces(w)    ≜ { n ∈ D ∪ Q ∪ B | (w, produces, n) ∈ E }
goals(w)       ≜ as recorded in `goals` field of w
WI(a)          ≜ { w ∈ W | theme(w) = a }
```

## Formal model

### Node taxonomy

Development state is the tuple:

```text
Σ ≜ (G, W, D, Q, B, R, A, E)
```

| Set                | Symbol             | Meaning                                                   | ID prefix |
| ------------------ | ------------------ | --------------------------------------------------------- | --------- |
| Goals              | G                  | Outcome / requirement; has fitness function.              | `G-NN`    |
| Work items         | W                  | Executable unit with DoR + DoD.                           | `W-NN`    |
| Decisions          | D                  | ADR; long-lived design choice.                            | `D-NN`    |
| Questions          | Q                  | Open unknown.                                             | `Q-NN`    |
| Assumptions        | B                  | Falsifiable assumption with validation method and result. | `B-NN`    |
| Retrospectives     | R                  | Post-goal learning capture.                               | `R-NN`    |
| Artifacts (themes) | A                  | Grouping of related W (optional).                         | `A-NN`    |
| Edges              | E ⊆ N × LabelE × N | Typed graph edges (§1.3).                                 | –         |

with N ≜ G ∪ W ∪ D ∪ Q ∪ B ∪ R ∪ A.

### Edge labels

```text
LabelE = { blocks, causes, implements, asks, tests, supersedes, produces, targets }
```

| Label        | Domain → Codomain    | Meaning                                                            |
| ------------ | -------------------- | ------------------------------------------------------------------ |
| `blocks`     | N → W                | Predecessor must be terminal before successor may start.           |
| `causes`     | A → W (refactor/bug) | Root cause to symptom.                                             |
| `implements` | W → D                | Work item realises an accepted decision.                           |
| `asks`       | Q → N                | Open question is raised against the target node.                   |
| `tests`      | B → Q                | Assumption operationalises a question into falsifiable validation. |
| `targets`    | B → W                | Assumption is required by a work item (defines `assumptions(w)`).  |
| `produces`   | W → D ∪ Q ∪ B        | Work item (typically a spike) produced this artifact.              |
| `supersedes` | D → D                | New decision replaces the old one.                                 |

The graph (N, E) is acyclic on `blocks`. Cycles on other labels are allowed.

### Status sets

```text
status(g) ∈ { unverified, partial, verified, declined }
status(w) ∈ { proposed, ready, progress, done, rejected, archived }
status(d) ∈ { proposed, accepted, rejected, superseded }
status(q) ∈ { open, deferred, answered, dropped }
status(b) ∈ { proposed, testing, validated, invalidated_acceptable, invalidated_blocking }
status(r) ∈ { draft, final }
status(a) ∈ { open, done }   (derived per I₆; never set manually)
```

### Cynefin tag (mandatory on Q, B, and W)

```text
cynefin(n) ∈ { clear, complicated, complex, chaotic }
```

Drives agent behaviour ([Protocol](skill/protocol.md) §5.2). If `chaotic`, stop and escalate.

## What it is not

- Not a task manager. Linear / Jira / Taskmaster cover that surface and Grove does not compete on UX.
- Not a code-context tool. Aider, Continue, Cursor itself handle code maps; Grove handles process state.
- Not a multi-agent orchestrator. Single writer per repo; multi-agent via worktrees + ID striding.

## Install

```bash
git clone https://github.com/alexshelepenok/grove.git ~/.local/grove
echo "alias grove='julia --project=$HOME/.local/grove $HOME/.local/grove/bin/grove.jl'" >> ~/.bashrc
```

Requires Julia 1.10+.

## Influences

Dual-Track Agile (Cagan), Hypothesis-Driven Development, ADRs (Nygard), Continuous Discovery, Cynefin (Snowden), Mikado method. Grove takes the fragments that survive contact with LLM agents and makes them machine-checkable.

## License

MIT License

Copyright (c) 2026 Alexander Shelepenok

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
