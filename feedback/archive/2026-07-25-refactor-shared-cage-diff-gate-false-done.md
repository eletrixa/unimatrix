---
source: grpn/refactor
date: 2026-07-25
run: ledger013
type: bug
severity: major
triaged-to: backlog#45
---

# Shared .write cage dir makes the per-card diff gate blind to report-only false-dones

## What happened

Wave-3 card `W3D1` (claude:haiku, read-modify card on `README.md` + `OWNERSHIP.md`)
finalized `done` with a detailed before/after edit report — and wrote NOTHING to disk.
Its `.write` sidecar pointed at the shared module dir
(`repos/monorepo-development/_refactor/work-ledger`), the same cage as sibling cards
`W3D2` and `W3T1`, which did write. The engine's per-card diff gate saw change under the
cage (siblings') and let the card finalize.

## Expected

A card whose own named targets show zero diff should be flagged (answer_unusable or a
loud `zero-diff-on-write-card` marker), even when siblings changed other files under the
same cage dir.

## Evidence paths

- `.bus-ledger013/res-W3D1.txt` — full before/after edit descriptions, no writes
- `docs/ops/speedwars.jsonl` — `{"run":"ledger013","id":"W3D1"}` verdict row (verified:false)
- Recovery: orchestrator applied the edits from the report text (salvage-first), cost one
  gate round.

## Suggestion

Per-card write journal or manifest: workers declare the files they wrote (or the engine
snapshots per-card mtimes/hashes of the card's NAMED targets from the prompt), so the
diff gate compares the card's own artifact set, not "anything under the cage changed
since spawn". Same class as cockpit057b lesson (b) — second occurrence, now
cross-project.
