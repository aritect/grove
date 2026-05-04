# 8. Quality checklist

Before ending a session, run `grove check`. It enforces:

- [ ] Lock checksum is valid (no manual edits).
- [ ] `index.md` is in sync with the lock (rerun `grove render` if stale).
- [ ] Every `done` W has a non-empty `evidence` field (I₃).
- [ ] Every `done` W has fitness deltas applied to each linked G (I₁₀, atomic).
- [ ] Every `progress` W carries a `session` token; `grove status` surfaces stale claims (I₁₁).
- [ ] Every Q with `status = open` has cynefin tag and exit criteria.
- [ ] Every B linked to a `feature` W is `validated` or `invalidated_acceptable` before that W is `ready` (I₉).
- [ ] If a Goal is verified, a retro `R-NN` exists OR a `--retro-deferred` note is present in the goal's `notes` field (lazy retro policy, rules.md).
- [ ] `WIP count ≤ WIP_LIMIT` (I₄).
- [ ] No DoR violations on `progress` items (I₁).
- [ ] `blocks` graph is a DAG (I₇).
- [ ] No orphan edges (every endpoint exists).

Manual items the CLI cannot check:

- [ ] New domain terms added to `glossary.md`.
- [ ] Typography ([Typography](typography.md)) respected in prose fields.
- [ ] Rejection reasons recorded for `rejected` / `dropped` nodes.
