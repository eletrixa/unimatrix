---
source: grpn/refactor
date: 2026-07-25
run: parity012
type: friction
severity: low
triaged-to: backlog#52
---

# .parked markers are empty; pin-wait parks carry no reason

## What happened
During parity012, `limits/w1-r-b-normalize.parked` and `limits/w1-r-d-verdict-latency.parked` (and later `w2-g-verdict-latency.parked`) were zero-byte files. No `.fbreason-*` existed for them. The orchestrator had to infer "bounded pin-wait while the pinned lane was busy" from timing and lane state. Diagnosis cost minutes per park; a one-line reason would make it seconds.

## Expected
Write the park reason into the marker file itself (e.g. `pin-wait: grok busy since <ts>, PIN_WAIT_SEC=<n> exceeded`), matching how `limits/<lane>.limited` carries TTL semantics via mtime.

## Evidence paths
- ~/code/unimatrix/.bus-parity012/limits/ (markers created ~13:05 and ~13:29 local, all 0 bytes)
