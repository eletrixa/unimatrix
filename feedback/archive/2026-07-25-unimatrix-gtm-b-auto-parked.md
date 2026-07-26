---
source: unimatrix
date: 2026-07-25
run: gtm-b
type: bug
severity: major
triaged-to: backlog#58
---

Confirmed (was auto-draft). b2-ladder-gmb and b3-verify-rung parked after glm:default
false-doned (same 0-token synthetic-error signature as gtm-a — see that report for the
full diagnosis: Z.ai child-env swap dead at CLI/auth level, doctor green because it
only checks CLI presence). kimi:default showed the identical signature on
b5-e2e-tests (3 instant api-errors, pinned card parked loudly per PIN_WAIT design).

Two additional observations from this run worth engine attention:

1. codex read-refusal false-done: b5-e2e-tests (codex retry) finalized done/0 with a
   prose answer "I'm blocked ... cannot read this TypeScript file ... I made no lasting
   changes" — an honest refusal, but it landed in done/ as a success. The refusal text
   class ("cannot read", "no lasting changes") belongs in the unusable-answer sniffer.
2. grok zero-artifact narration false-done recurred on a SHARED .write cage
   (a2-e2e on gtm-a: stopReason Cancelled, 6k tokens of narration, zero Edit/Write
   calls) — sibling writes blinded the per-card diff gate again (known cockpit057b
   class). Orchestrator artifact-gates caught it; a per-card write-journal would
   catch it engine-side.

Evidence: .bus-gtm-b/run-b{2,3}*.jsonl, .bus-gtm-b/res-b5-e2e-tests.txt,
.bus-gtm-a/run-a2-e2e.jsonl. All recovered by re-lane/reseed; $0 spend.
