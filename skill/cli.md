# 6. CLI reference

Invocation: `julia --project=<grove-root> <grove-root>/bin/grove.jl <command> [args...]`. For brevity, all examples below use `grove` as the bound name. Recommended shell alias:

```bash
alias grove='julia --project=/path/to/grove /path/to/grove/bin/grove.jl'
```

The CLI reads and writes `.grove/state.lock` and `.grove/index.md` relative to the current working directory. Override with `--root=<path>` (root must contain or will contain `.grove/`).

## 6.1 Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Success. |
| 1 | Generic error (bad args, file missing). |
| 2 | Lock checksum mismatch. Use `grove repair --confirm`. |
| 3 | Invariant violation (`grove check`). |
| 4 | Guard failure (DoR, WIP, evidence missing, etc.). |
| 5 | Not found (unknown ID). |

## 6.2 Read commands

**`grove status`:** session-aware overview. Lists: stale-token `progress` W's
(see [protocol §2.6](protocol.md#26-session-tokens-and-interrupted-work)),
open alignment triggers (§2.5), invariant warnings short of full check.
Run this first in every session.

**`grove ready`:** list work items ready to start. Sorted: critical-path members first, then by descending downstream-blocks count. Output is one line per W: `W-NN  <title>  [crit]`.

**`grove next`:** single proposed W from `Ready ∩ critical_path`. Falls back to any `Ready` member if the intersection is empty. Prints the same packet as `grove packet <ID>` (see below).

**`grove packet <W-NN>`:** execution packet. Self-contained markdown bundle:

- The W record (header + all fields, prose rendered as markdown).
- Every `D-NN` linked by `implements`.
- Every `B-NN` in `BChain(W)`.
- The `outcome` of every `Q-NN` linked by `asks`.
- A DoR breakdown (same as `grove dor`).

This is the only context the agent needs to implement the W.

**`grove deps <ID>`:** transitive predecessors on `blocks`. One ID per line, in topological order.

**`grove impact <ID>`:** transitive successors on `blocks` (what does this unblock?).

**`grove path`:** critical path: longest chain of unfinished W on `blocks`, head to tail.

**`grove dor <W-NN>`:** DoR conjunct breakdown:

```text
W-12 DoR:
  ⊤  goals(w) ≠ ∅                      → G-01
  ⊤  AC(w) ≠ ∅                          → 2 entries
  ⊤  ∀ q ∈ asks(w), q terminal          → Q-03 (answered)
  ⊥  BChain validated                   → B-01 testing
  ⊤  fitness deltas set                 → G-01=+1
  ⊤  evidence_strategy ≠ ∅
  ⊤  hypothesis ≠ ⊥
  ⊤  repro(w) ≠ ∅                    → (non-bug)
  ⊤  exit(w) ≠ ∅                     → (non-spike)
  ⊤  (A, causes, w) via materialised A → (non-refactor)
  ⊤  cynefin ≠ chaotic                  → clear
result: ⊥
```

**`grove show <ID>`:** pretty-print one record.

**`grove list <kind> [--status=…] [--cynefin=…]`:** kinds: `w`, `d`, `q`, `b`, `g`, `r`, `a`. Tabular output.

**`grove graph`:** print the mermaid block to stdout.

**`grove diff [--since=<git-ref>]`:** structured diff of `state.lock`
between the current working copy and `<git-ref>` (default `HEAD`). Output
groups changes by record kind and shows added / removed / changed nodes and
edges, ignoring pure reordering. Designed for PR review.

**`grove log [<ID>] [--limit=N]`:** newest-first merged timeline from node/edge
`t_created`/`t_updated` attrs and `.grove/journal.log` (one tab-separated row per
source; journal rows use middle field `journal`). An `<ID>` filter also matches
inverse payloads in journal records (so IDs only referenced there still work).
`--limit=0` disables the cap.

**`grove check`:** run all invariants I₁..I₁₁ plus checksum and stale-index checks. Exit code 0 / 2 / 3 as listed in §6.1.

**`--json` on read commands:** every read command in §6.2 prints **one JSON object** on stdout (UTF-8) instead of the human-oriented text. Keys always include **`command`** (string, same as the subcommand). Mutate commands ignore `--json`. Exit codes are unchanged; for **`check`**, failures still return **3** with **`"ok": false`** and an **`errors`** array in the JSON body (no duplicate error lines on stderr). Schema details: §6.4.1.

## 6.3 Mutate commands

**All mutate commands** re-serialize the lock with a fresh checksum and call `render` implicitly.

**`grove init`:** creates `.grove/state.lock`, `.grove/index.md`, `.grove/glossary.md`. Idempotent: refuses if the lock already exists.

Optional allocation tuning (persisted once in the optional `# @grove-id stride=…` lock comment; see [§7.1 Lockfile envelope](lockfile.md#71-file-envelope)):

- `--id-stride=<N>` (default `1`): additive gap between successive numeric suffixes (`N≥1`).
- `--id-offset=<K>` (default `1`): first suffix when a family allocator is empty (`K≥1`).
- `--id-width=<W>` (default `2`, or bumped to ≥`3` when stride/offset are non-default without an explicit `--id-width`): minimum digit padding for new IDs (`W≥2`).

**`grove renumber <ID> --to=<NEW-ID>`:** rewrites one record ID and every structured reference (`edges`, structural list fields keyed by IDs, `:fitness` map keys against goals, `:goal`/`:work-items` payloads, `:theme`, etc.). Refuses when the token appears verbatim in prose on **any done** `w` (`evidence` field), signalling that downstream consumers may have anchored on the exported string — resolve manually ([merge protocol](rules.md#merge--rebase-protocol)).

**`grove add <kind> [...]`:** kind ∈ `g w d q b r`.

| Kind | Required flags | Optional |
| --- | --- | --- |
| `g` | `--title="…"` | `--fitness="…"` (legacy label), `--fitness-kind=count|ratio|boolean|metric|manual`, `--fitness-target=…`, `--status=unverified` |
| `w` | `--title="…"`, `--type=feature\|refactor\|bug\|spike`, `--cynefin=…` | `--goals=G-01,G-02`, `--theme=A-01`, `--status=proposed` |
| `d` | `--title="…"` | `--supersedes=D-01`, `--status=proposed` |
| `q` | `--title="…"`, `--cynefin=…` | `--targets=W-01`, `--status=open` |
| `b` | `--title="…"`, `--cynefin=…` | `--tests=Q-01`, `--targets=W-01`, `--status=proposed` |
| `r` | `--goal=G-01`, `--date=YYYY-MM-DD` | `--work-items=W-01,W-02`, `--status=draft` |

The CLI prints the assigned ID.

**`grove set <ID> <key>=<value>`:** keys: `status`, `cynefin`, `type`, `title`, `goal` (R only), `date` (R only), `fitness` (G only, legacy display string), `fitness_kind` (G only). Status transitions are guarded:

- `W status=progress`: I₁ DoR ≡ ⊤, I₄ WIP, I₅ predecessors `terminal⁺`, I₁₁ no other session holds the token. Records the session token.
- `W status=done`: I₃ evidence non-empty, I₅ predecessors `terminal⁺`, I₁₀ atomic — fitness deltas for every linked goal must be staged via `grove fitness` since the last status mutation; otherwise rejected. On success, applies deltas, re-derives `status(g)` and `status(a)`, runs `grove render`. If a linked goal **newly** reaches `verified`, the CLI prints a **lazy retro** hint to stderr (`grove add r --goal=…`); goals with a `notes` line containing `--retro-deferred` suppress the hint (see [rules](rules.md) § lazy retros).
- `D status=accepted`: locks the record from further field edits (rule "Decision immutability"); use `supersedes` to revise.
- `B status=invalidated_blocking`: warns about every dependent W; does not auto-reject.
- `A status=…`: rejected (derived per I₆).

**`grove field <ID> <field> add "…"`:** append one prose line (or one list element) to a field.
**`grove field <ID> <field> rm <index>`:** remove the Nth (1-based) entry.
**`grove field <ID> <field> clear`:** empty the field.

**`grove link <from> <label> <to>`:** adds an edge. Labels: `blocks`, `implements`, `asks`, `tests`, `targets`, `produces`, `causes`, `supersedes`. Validates domain/codomain per [Formal model](model.md) §1.3 and DAG-ness for `blocks` (I₇).

**`grove unlink <from> <label> <to>`:** removes the edge.

**`grove evidence <W-NN> "…"`:** appends a line to the W's `evidence` field. Sugar for `grove field W-NN evidence add "…"`.

**`grove fitness <W-NN> <G-NN> <±delta>`:** stages a delta on **`W`** toward **`G`** (I₁₀ at `done`). If **`G`** carries structured **`fitness_kind`**, `index` / lock fields **`fitness_current`** and **`status(G)`** refresh when **`W`** completes (see [lockfile §7.5.1](lockfile.md#751-structured-fitness-goals)). Multiple calls overwrite the staged delta for the same (W, G) pair. Use `+0` for enabling work (CLI requires a non-empty `why` in W when delta=0).

**`grove archive <G-NN>`:** moves the goal and every `w` / `d` / `q` / `b` / `a` whose **goal-reference set equals `{G-NN}`** (`goals` fields + propagation along `implements`, `produces`, `asks`, `tests`, `targets`, `causes`, `theme`, bidirectional `supersedes`) and that is **affinity-connected** to `G-NN` (`goals` backlinks + undirected structural edges among those nodes only). Shared resources (one `d` tied to work under two goals via `implements`, etc.) **stay active**. `:r` records remain outside `:archive`. Refuses when `status(G) ≠ verified`, there is no `final` retrospective with `goal=G-NN`, or session guards fail on `progress` work listing `G-NN`.

**`grove render`:** regenerate `.grove/index.md`. Called automatically by every mutate command; explicit invocation is for after a `repair`.

**`grove repair --confirm`:** re-parse the lock under relaxed checksum, re-canonicalise, write fresh checksum. Use after a deliberate manual edit OR after any git operation that combined two histories of `state.lock` (merge, rebase, cherry-pick); see [rules.md merge protocol](rules.md#merge--rebase-protocol).

**`grove resume <W-NN>`** / **`grove handoff <W-NN> --to=<token>`** / **`grove revert <W-NN>`:** session-token operations on a `progress` W (journal undo restores prior claim tokens). See [protocol §2.6](protocol.md#26-session-tokens-and-interrupted-work).

**`grove undo [--steps=N]`:** reverts the last N journaled mutate operations applied in inverse order by replaying stored inverse ops onto the lock state, then **truncates** the last N lines off `.grove/journal.log` (default `N=1`). Undo does **not** append another journal entry; there is no built-in redo. Other mutators (`init`, `archive`, `repair`) do not write journal lines.

## 6.4 Global flags

- `--root=<path>`: base directory containing `.grove/`.
- `--quiet`: suppress info; only errors.
- `--json`: machine-readable output for read commands (§6.4.1).
- `--no-render`: skip auto-render after a mutate (debugging only).
- `--session=<token>`: override the session token (default: `GROVE_SESSION` if set, else `host:hex16(sha256(norm_root))` from env `COMPUTERNAME`/`HOSTNAME`/`HOST`).
- `--id-stride=<N>` / `--id-offset=<N>`: only valid on `grove init`; sets
  the worktree's ID allocator to step `N` starting from `offset` to avoid
  collisions on parallel branches (see merge protocol).

### 6.4.1 `--json` command shapes

Each response is a single JSON object. Types: **string**, **bool**, **array**, **object** (string keys).

| Subcommand | Extra keys (besides `command`) |
| --- | --- |
| `ready` | `items`: array of `{ id, title, critical }`. |
| `next` | `work`, `packet_markdown`. |
| `packet` | `work`, `packet_markdown`. |
| `deps` | `id`, `predecessors` (strings, topological order). |
| `impact` | `id`, `successors`. |
| `path` | `chain` (W ids on critical path). |
| `dor` | `work`, `conjuncts`: `[{ label, ok, detail }]`, `dor` (bool, overall ⊤/⊥). |
| `show` | `record`: `{ kind, id, title, status, archived?, type?, cynefin?, attrs: { … }, fields: { … } }` (present `fields` keys follow the lockfile catalog; prose/reflists are JSON arrays of strings). |
| `list` | `kind`, `rows`: `[{ id, status, title, cynefin? }]`, optional `filter_*`. |
| `graph` | `mermaid` (full mermaid block text). |
| `log` | `limit`, `rows`: `[{ ts, sort, line }]`, optional `id_filter`. |
| `check` | `ok`, `errors` (strings; empty when `ok`). |
| `status` | `progress`: session rows; `alignment_triggers`; `invariants`: `{ ok, messages }`. |
| `diff` | `since` (git ref), `semantic_change`, `nodes` (per-kind `added` / `removed` / `changed`), `edges`: `{ added, removed }` with `{ from, label, to }`; same semantic rules as textual diff (`lock_structural_lines`). |

## 6.5 Examples

```bash
grove init
grove add g --title="Migrate auth" --fitness="5/5 modules"
grove add w --type=feature --cynefin=clear --goals=G-01 \
          --title="Add login flow"
grove add q --cynefin=complicated --targets=W-01 \
          --title="Which hash algo?"
grove link Q-01 asks W-01
grove field Q-01 outcome add "bcrypt; see D-01"
grove set Q-01 status=answered

grove dor W-01
grove next
grove packet W-01

grove fitness W-01 G-01 +1
grove evidence W-01 "tests/login_test.jl green; commit abc123"
grove set W-01 status=done           # I₁₀ atomic: applies fitness, derives g, renders

grove check
```

Note the order: stage `fitness` before `evidence` before `status=done`. The
`done` transition is the single atomic point that applies everything.

