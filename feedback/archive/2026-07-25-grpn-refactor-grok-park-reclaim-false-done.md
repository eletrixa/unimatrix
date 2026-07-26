---
source: grpn/refactor
date: 2026-07-25
run: parity012
type: bug
severity: high
triaged-to: backlog#53
---

# grok false-dones reliably on the park-reclaim path

## What happened
Wave 1 of run parity012 pinned 3 cards to `grok:grok-4.5` (`.lane` sidecars). Card A was served first and completed with full artifacts (11 files). Cards B and D parked on bounded pin-wait while grok was busy. After the orchestrator cleared `limits/*.parked`, the live pool re-served both to grok; both finalized `done`/code 0 with ZERO artifacts: ~700 output tokens of narration ("I'll write only the RED test file..."), stopReason "Cancelled", 2-3 turns, ~$0.154 wasted. Same signature repeated in wave 2b: `w2-g-verdict-latency` parked on pin-wait again (grok busy with the sibling card); orchestrator pulled it to a session agent instead of risking a third reclaim.

Pattern across the run: grok fresh first-serves 2/2 succeeded (w1-r-a, w2-g-normalize); park-reclaim serves 2/2 false-doned.

## Expected
Either the reclaim path serves grok a fresh, complete context (it looks like the reclaimed serve starts mid-flight or with a truncated budget), or the engine's artifact gate hard-fails a write-card `done` whose `.write` target gained zero new files since spawn.

## Evidence paths (no secrets)
- ~/code/unimatrix/.bus-parity012/run-w1-r-b-normalize.jsonl (end record: Cancelled, 725 output tokens)
- ~/code/unimatrix/.bus-parity012/run-w1-r-d-verdict-latency.jsonl (573 output tokens)
- ~/code/unimatrix/.bus-parity012/res-w1-r-b-normalize.txt (narration-only answer)
- Contrast: res-w1-r-a-schema-fixtures.txt + 11 files on disk from the same lane, first serve
