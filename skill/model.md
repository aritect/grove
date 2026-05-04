# 1. Formal model

## 1.1 Node taxonomy

Development state is the tuple:

```text
Σ ≜ (G, W, D, Q, B, R, A, E)
```

| Set | Symbol | Meaning | ID prefix |
| --- | --- | --- | --- |
| Goals | G | Outcome / requirement; has fitness function. | `G-NN` |
| Work items | W | Executable unit with DoR + DoD. | `W-NN` |
| Decisions | D | ADR; long-lived design choice. | `D-NN` |
| Questions | Q | Open unknown. | `Q-NN` |
| Assumptions | B | Falsifiable assumption with validation method and result. | `B-NN` |
| Retrospectives | R | Post-goal learning capture. | `R-NN` |
| Artifacts (themes) | A | Grouping of related W (optional). | `A-NN` |
| Edges | E ⊆ N × LabelE × N | Typed graph edges (§1.3). | – |

with N ≜ G ∪ W ∪ D ∪ Q ∪ B ∪ R ∪ A.

All nodes and edges are stored in `./grove/state.lock` (see [Lockfile](lockfile.md)). There are no per-node files.

## 1.2 Work item type

```text
type(w) ∈ { feature, refactor, bug, spike }
```

- **feature**: new capability; needs hypothesis (HDD) and resolved assumptions when discovery exposed uncertainty.
- **refactor**: structural change, behaviour preserved; needs root cause (causation edge from A).
- **bug**: defect in shipped behaviour; needs reproducible evidence.
- **spike**: investigation only; produces D, Q, or B, not production code.

## 1.3 Edge labels

```text
LabelE = { blocks, causes, implements, asks, tests, supersedes, produces, targets }
```

| Label | Domain → Codomain | Meaning |
| --- | --- | --- |
| `blocks` | N → W | Predecessor must be terminal before successor may start. |
| `causes` | A → W (refactor/bug) | Root cause to symptom. |
| `implements` | W → D | Work item realises an accepted decision. |
| `asks` | Q → N | Open question is raised against the target node. |
| `tests` | B → Q | Assumption operationalises a question into falsifiable validation. |
| `targets` | B → W | Assumption is required by a work item (defines `assumptions(w)`). |
| `produces` | W → D ∪ Q ∪ B | Work item (typically a spike) produced this artifact. |
| `supersedes` | D → D | New decision replaces the old one. |

The graph (N, E) is acyclic on `blocks`. Cycles on other labels are allowed.

## 1.4 Status sets

```text
status(g) ∈ { unverified, partial, verified, declined }
status(w) ∈ { proposed, ready, progress, done, rejected, archived }
status(d) ∈ { proposed, accepted, rejected, superseded }
status(q) ∈ { open, deferred, answered, dropped }
status(b) ∈ { proposed, testing, validated, invalidated_acceptable, invalidated_blocking }
status(r) ∈ { draft, final }
status(a) ∈ { open, done }   (derived per I₆; never set manually)
```

## 1.5 Cynefin tag (mandatory on Q, B, and W)

```text
cynefin(n) ∈ { clear, complicated, complex, chaotic }
```

Drives agent behaviour ([Protocol](protocol.md) §5.2). If `chaotic`, stop and escalate.

## 1.6 Core invariants

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
terminal⁺(g ∈ G) ⟺ status(g) = verified            -- strict for blocks-edges
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

## 1.7 Definition of Ready

```text
DoR(w) ≜
  (goals(w) ≠ ∅) ∧
  (AC(w) ≠ ∅) ∧
  (∀ q ∈ asks(w), status(q) ∈ { answered, deferred, dropped }) ∧
  (type(w) = feature ⇒ ∀ b ∈ BChain(w), status(b) ∈ { validated, invalidated_acceptable }) ∧
  (∀ g ∈ goals(w), contributes_to_fitness(w, g) ≠ ⊥) ∧
  (evidence_strategy(w) ≠ ∅) ∧
  (type(w) = feature ⇒ hypothesis(w) ≠ ⊥) ∧
  (type(w) = bug ⇒ repro(w) has a non-empty prose line) ∧
  (type(w) = spike ⇒ exit(w) has a non-empty prose line) ∧
  (type(w) = refactor ⇒ ∃ a ∈ A, ¬archived(a) ∧ (a, causes, w) ∈ E) ∧
  (cynefin(w) ≠ chaotic)
```

`grove dor <ID>` evaluates DoR conjunct-by-conjunct.

## 1.8 Timestamps

Every node carries `t_created` and `t_updated` (RFC-3339, UTC, second precision).
Every edge carries `t_created`. The CLI assigns and bumps these; agents do not
set them. They are used by `grove log`, `grove diff`, and metric exports.

## 1.9 Type-specific obligations

`grove dor` implements the `type(w)` conjuncts in §1.7 (`hypothesis` + BChain for `feature`;
`repro` / `exit` prose fields for `bug` / `spike`; materialised `A` with `(a, causes, w)` for
`refactor`). Further norms (e.g. spike vs production code, failing-test-first for bugs) are
protocol guidance, not additional CLI conjuncts unless recorded in AC / evidence_strategy.

`repro` and `exit` are first-class prose fields on `w` (see lockfile §7.5).
