---
source: unimatrix
date: 2026-07-25
run: gtm-c
type: bug
severity: minor
triaged-to: backlog#59
---

Confirmed (was auto-draft). c8.2 (test-wave write card) parked after grok lane
exhaustion — the known grok narration false-done class (stopReason Cancelled,
prose answer, zero write-tool calls), third recurrence this evening after
gtm-a/gtm-b (see those reports). Orchestrator did NOT reclaim on grok
(parity012 lesson) — reseeded as c8.2b pinned to glm, which landed it clean;
c8.5/c8.6 got the same treatment proactively (c8.5b/c8.6b, both landed).

Downgraded to minor: the park was the engine doing its job; the recurring
engine-side ask stays the per-card write-journal from the gtm-b report so the
diff gate can see zero-write narration on shared cages without an orchestrator
artifact-gate.

Evidence: .bus-gtm-c/limits/c8.2.parked, .bus-gtm-c/run-c8.2*.jsonl,
.bus-gtm-c/done/c8.2b (glm reland). $0 spend on the failed attempts.
