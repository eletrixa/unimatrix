---
source: unimatrix
date: 2026-07-24
run: round3
type: friction
severity: major
triaged-to: backlog#31
---

GLM lane hit the thinking-flood rat-hole again on a C3 two-feature single-file card
(`a5green-lib`): 8.5 MB `run-*.jsonl`, ~11.8k estimated thinking tokens, **zero bytes written to
the write target** before the orchestrator killed it at ~7 min (would have burned the full
1200s watchdog otherwise). `GLM_MAX_THINKING_TOKENS=6000` was set in `swarm.conf` but the stream
sailed past it — either the cap wasn't applied to this spawn path or the cap doesn't bound the
`estimated_tokens` counter the stream reports.

Expected: glm either lands the card or fails fast; the conf cap actually bounds thinking output.

Evidence paths: `.bus-round3/run-a5green-lib.jsonl` (before cleanup), speedwars `round3` rows,
skill Lessons ledger entry (f) from run `rolecls` (same class, second recurrence).

Suggested: bench glm to ≤C2 single-feature cards at plan time (already in the skill), AND verify
`GLM_MAX_THINKING_TOKENS` reaches the child env on chain-claimed (non-pinned) spawns — the two
prior floods were both chain-claimed cards.
