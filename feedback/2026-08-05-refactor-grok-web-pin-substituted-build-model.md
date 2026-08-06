---
source: refactor
date: 2026-08-05
run: rr-d10-clo
type: bug
severity: high
status: draft
---

# grok write-card pin `grok:grok-4.5` silently served by `grok:grok-4.5-build` — web research cards false-done as skeletons

## What happened
7 pre-seeded write cards on bus `.bus-rr-d10-clo` (research memos needing web_search/web_fetch),
each pinned `<id>.lane` = `grok:grok-4.5` (the web-capable chain per spec 23 / readyroom).
Driver log: `swarm-run: a1-visa-exit served by grok:grok-4.5-build (requested grok:grok-4.5)`
— all 7 cards. The -build variant has no (working) web tooling, so each card wrote only the
instructed crash-insurance skeleton (900–2,600 bytes, zero deep links) and finalized done/0.
Diff gate passed because the .files manifest was satisfied by the skeletons.

## Expected
A hard `.lane` pin should park loudly rather than substitute a different model; or the
substitution should at least be surfaced as a warning the orchestrator can gate on. A
"requested X, served Y" line exists but nothing fails.

## Evidence paths
- ~/refactor/.bus-rr-d10-clo (run-*.jsonl, res-*.txt, limits/*.stamp)
- task output: swarm-run lines quoted above
- Recovery: 7 session sonnet agents re-ran the research (workflow wf_4cdc5f41-6e4)

## Note
Same downstream symptom class as the 2026-08-04 D13 "12/12 stopReason:Cancelled at first
web-tool invocation" — different mechanism (model substitution vs tool cancellation). Both
end as skeleton/zero-artifact false-dones on the grok web lane.
