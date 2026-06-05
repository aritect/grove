# 6. Lockfile specification

`.grove/state.lock` is the single source of truth for GROVE state. It is written and read only by the `grove` cli ([cli reference](cli.md)). Manual edits are detected and rejected.

## 6.1 File envelope

```text
@grove v1
# AUTO-GENERATED. Do not edit. Use `grove` cli.
# checksum: sha256:<64-hex>

<id-allocation-meta optional>
<records...>
```

Optional first body line (always a comment parsed by the CLI, included in `checksum body`):

```text
# @grove-id stride=<N> offset=<K> pad=<W>
```

When present (`N`,`K`,`W` are decimal integers ≥ 1, with `pad ≥ 2`), new IDs allocate as: first suffix equals `offset` for an empty allocator lane, thereafter `prior_numeric_max + stride` per letter family (`W`, `G`, …). Omitting this line preserves legacy semantics (`stride=1`, `offset=1`, `pad=2`).

- Line 1 is the format magic. Exactly `@grove v1`.
- Lines 2 and 3 are mandatory comments; line 3 carries the SHA-256 checksum of the canonical body (everything from the first blank line onward, with `\n` line endings, NFC, no trailing whitespace).
- All file IO uses UTF-8, `\n` line endings, final newline mandatory.

The CLI rejects any file whose recomputed checksum disagrees with line 3. `grove repair --confirm` recomputes and writes the new checksum.

## 6.2 Lexical structure

- One logical record per "block": a header line plus zero or more indented field lines.
- Indentation is exactly two spaces. Nested prose lines (the `|` form) use four spaces.
- Comments start with `#` at column 0 only. They are preserved on read but never created by the CLI outside the envelope.
- Blank lines separate records. Multiple blank lines collapse to one on serialize.

## 6.3 Record grammar

```ebnf
file       = magic NL comment NL checksum NL { NL } { record } [ archive ]
record     = node | edge
node       = nodeKind SP id { SP attr } [ SP qstring ] NL { field }
nodeKind   = "g" | "w" | "d" | "q" | "b" | "r"
edge       = "e" SP id SP label SP id { SP attr } NL
label      = "blocks" | "causes" | "implements" | "asks" | "tests"
           | "targets" | "produces" | "supersedes"
attr       = key "=" attrValue
attrValue  = bareWord | qstring | iso8601
field      = "  " key ":" [ SP listValue ] NL { proseLine }
proseLine  = "    | " text NL                ; text is any UTF-8 except NL
listValue  = ref { "," SP ref }
qstring    = '"' { qchar | escape } '"'
escape     = "\\\"" | "\\\\" | "\\n"
id         = ( "G" | "W" | "D" | "Q" | "B" | "R" | "A" ) "-" digit digit { digit }
ref        = id | id "=" signedInt   ; signedInt only for fitness deltas
iso8601    = ; RFC-3339, UTC, second precision, e.g. 2026-05-04T22:13:09Z
archive    = ":archive" NL { record }
```

`text` inside a prose line is any UTF-8 sequence excluding NL. No escaping is
performed; the `    | ` (four spaces, pipe, space) prefix is the unambiguous
delimiter. Raw `|`, `\`, `"` are literal inside prose lines.

`bareWord` matches `[a-zA-Z_][a-zA-Z0-9_-]*`. Quoted strings are required for any value that contains whitespace, `"`, or `\`. The CLI always quotes titles.

## 6.4 Header attributes per kind

| Kind | Required attrs | Optional attrs | Trailing title |
| --- | --- | --- | --- |
| `g` | `status` | `fitness_kind` | yes |
| `w` | `type`, `status`, `cynefin` | `session`, `session_at` | yes |
| `d` | `status` | – | yes |
| `q` | `status`, `cynefin` | – | yes |
| `b` | `status`, `cynefin` | – | yes |
| `r` | `status`, `goal`, `date` | – | no (title optional) |

Every node also carries `t_created` and `t_updated` (ISO-8601 attrs). Every
edge carries `t_created`. The CLI assigns and updates these; agents do not
set them by hand.

Kind `a` (artifact) is materialised: it appears as a node record but its
title and tags are user-set; its `status` is always derived (I₆) and is
rejected by `grove set`.

## 6.5 Field catalog

Recognised fields per node kind. Unknown fields are a parse error.

**Common (any node):** `tags` (list of bare words).

**`w` (work item):**

| Field | Form | Meaning |
| --- | --- | --- |
| `goals` | list of `G-NN` | Targeted goals. |
| `theme` | single `A-NN` | Membership in an artifact. |
| `fitness` | list of `G-NN=±N` | Per-goal fitness deltas (staged for I₁₀). |
| `surface` | list of paths | Files the W reads or writes; populated by `grove packet`. |
| `ac` | prose | Acceptance criteria, one per `\|` line. |
| `hypothesis` | prose | HDD statement (`feature` only). |
| `repro` | prose | Reproducer (`bug` only). |
| `exit` | prose | Exit criteria (`spike` only). |
| `evidence_strategy` | prose | Plan for collecting evidence. |
| `evidence` | prose | Actual evidence (filled before `done`). |
| `plan` | prose | Approach notes. |
| `why` | prose | Why this work item exists. |
| `why_no_repro_test` | prose | Reason for skipping failing-test-first (`bug` only, optional). |

**`d` (decision):**

| Field | Form | Meaning |
| --- | --- | --- |
| `context` | prose | – |
| `options` | prose | One option per line, prefixed `OC1:`, `OC2:`, … |
| `decision` | prose | – |
| `consequences` | prose | – |
| `validation` | prose | – |

**`q` (question):**

| Field | Form | Meaning |
| --- | --- | --- |
| `why` | prose | – |
| `hypothesis` | prose | Optional. |
| `exit` | prose | Exit criteria. |
| `log` | prose | Investigation log. |
| `outcome` | prose | – |

**`b` (assumption):**

| Field | Form | Meaning |
| --- | --- | --- |
| `vm` | prose | Validation method. |
| `threshold` | prose | Acceptance threshold. |
| `result` | prose | – |

**`g` (goal):**

| Field | Form | Meaning |
| --- | --- | --- |
| `fitness_target` | single line | Threshold / notation; semantics depend on header **`fitness_kind`** (§6.5.1). |
| `fitness_current` | single line | CLI-derived sums for structured kinds (**except `manual`**); user-authored only for **`manual`**. |
| `notes` | prose | Any goal notes; a line containing **`--retro-deferred`** suppresses the post-`done` lazy-retro stderr hint ([rules.md](rules.md)). |

### 6.5.1 Structured fitness (goals)

Optional header attr **`fitness_kind`** ∈ **`count` \| `ratio` \| `boolean` \| `metric` \| `manual`**. Missing **`fitness_kind`** ⇒ legacy **`fitness="…"`** header string: denominator of first `d/d` token sets the integral threshold versus the sum of **`done`** work-item deltas (unchanged pre–structured behaviour).

With **`fitness_kind`**, **`fitness_target`** and **`fitness_current`** are single-string fields (**§6** `single` form). **`grove fitness W-NN G-NN ±δ`** still stages on **`W`**; when **`W`** becomes **`done`**, the CLI refreshes each linked goal’s **`fitness_current`** (except **`manual`**) and may update **`status(g)`**.

| `fitness_kind` | `fitness_target` | Auto `status(g)` from sum of done deltas |
| --- | --- | --- |
| `count` | Non‑negative integer **N** | **`verified`** if **sum ≥ N**; **`partial`** if **0 \< sum \< N** (only when **N** parsed). |
| `ratio` | `a/b` or plain integer | Same as **`count`** (denominator of `a/b`, else integer). |
| `boolean` | (ignored) | **`verified`** if **sum ≥ 1**. |
| `metric` | Non‑negative integer **N** | Same inequality as **`count`**. |
| `manual` | Optional label | **Never** auto-derived; use **`grove set G-NN status=…`**. |

**`grove field G-NN fitness_target`** on a structured goal triggers a refresh. **`grove field G-NN fitness_current`** is **rejected** unless **`fitness_kind=manual`**.

The header **`fitness="…"`** string may still be used as a display subtitle next to structured data.

**`r` (retrospective):**

| Field | Form | Meaning |
| --- | --- | --- |
| `work_items` | list of `W-NN` | – |
| `held` | prose | – |
| `not_held` | prose | – |
| `surprises` | prose | – |
| `glossary_updates` | prose | – |
| `skill_updates` | prose | – |

**`a` (artifact):** `notes` (prose) only. Title is set on creation; status
is derived (I₆).

ALL edge labels (`blocks`, `causes`, `implements`, `asks`, `tests`, `targets`,
`produces`, `supersedes`) live ONLY in `e` records. They are NEVER duplicated
into node fields. Earlier drafts of this spec listed `targets`, `tests`,
`supersedes` as node fields; they are removed. Per-node convenience views
(e.g., "all questions asking against W-12") are reconstructed by the CLI on
read.

This is the single normalisation rule: **edges are edges, fields are fields.**
A field that names another node by ID exists only when it carries
information *beyond* the edge (e.g., `goals` on W carries semantic targeting
that drives DoR; `theme` is a single-A membership that affects derivation
I₆; `fitness` carries deltas, not a relationship). Any pure relationship
(B tests Q, B targets W, D supersedes D) is an edge.

## 6.6 Canonical ordering

Serialization is deterministic so git diffs are stable:

1. `g` records sorted by ID.
2. `w` records sorted by ID.
3. `d` records sorted by ID.
4. `q` records sorted by ID.
5. `b` records sorted by ID.
6. `r` records sorted by ID.
7. `a` records sorted by ID.
8. Edge records sorted by `(from, label, to)` lexicographically.
9. Optional `:archive` block, then archived records in the same order.

Within a record, fields appear in the order listed in §6.5 tables. Prose lines preserve insertion order.

## 6.7 Example

```text
@grove v1
# AUTO-GENERATED. Do not edit. Use `grove` CLI.
# checksum: sha256:0000000000000000000000000000000000000000000000000000000000000000

g G-01 status=verified fitness_kind=count fitness="5/5 modules" t_created=2026-01-10T08:00:00Z t_updated=2026-05-04T22:13:09Z "Migrate auth"
  fitness_target: 5
  fitness_current: 5

w W-12 type=feature status=ready cynefin=clear t_created=2026-04-01T10:00:00Z t_updated=2026-05-01T11:22:00Z "Add login flow"
  goals: G-01
  fitness: G-01=+1
  surface: src/auth/login.ts, tests/auth/login_test.ts
  ac:
    | User signs in with email/password.
    | Sessions expire after 24h.
  hypothesis:
    | Email/password is enough for MVP.
  evidence_strategy:
    | Integration test on /login.

d D-02 status=accepted t_created=2026-04-02T09:00:00Z t_updated=2026-04-02T09:30:00Z "Use bcrypt"
  context:
    | bcrypt has wide ecosystem support.
  decision:
    | bcrypt for ecosystem maturity.

q Q-03 status=answered cynefin=complicated t_created=2026-04-01T11:00:00Z t_updated=2026-04-02T09:30:00Z "Which hash algo?"
  outcome:
    | bcrypt; see D-02.

b B-01 status=validated cynefin=complicated t_created=2026-04-01T12:00:00Z t_updated=2026-04-03T15:00:00Z "users prefer email"
  vm:
    | survey n=50, 5-point likert.
  threshold:
    | ≥ 70% prefer email.
  result:
    | 82% preferred email.

e B-01 blocks      W-12 t_created=2026-04-01T12:01:00Z
e B-01 tests       Q-03 t_created=2026-04-01T12:02:00Z
e B-01 targets     W-12 t_created=2026-04-01T12:03:00Z
e Q-03 asks        W-12 t_created=2026-04-01T11:01:00Z
e W-12 blocks      W-15 t_created=2026-04-05T08:00:00Z
e W-12 implements  D-02 t_created=2026-04-02T09:31:00Z
```
