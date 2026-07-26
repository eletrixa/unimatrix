---
source: unimatrix
date: 2026-07-25
run: gtm-a
type: bug
severity: major
triaged-to: backlog#58
---

Confirmed (was auto-draft). a1-adapter parked after glm:default false-doned repeatedly.

What happened: every glm attempt died instantly at the CLI level — `is_error:true`,
0 input/0 output tokens, model `<synthetic>`, `stop_reason: stop_sequence` — i.e. the
Z.ai child-env swap never reached a real model (auth/quota/endpoint failure), and the
worker finalized done/0 with no artifacts. The engine's false-done detection parked the
card correctly after retries. Same signature as kimi on `.bus-gtm-b` the same evening
(see the gtm-b report): both claude-CLI child-env-swap lanes were dead while claude,
grok, and codex lanes on the same box ran fine.

Expected: `doctor` (and/or a pre-claim probe) should catch a dead swap-lane BEFORE
cards burn retries on it. Doctor passed both lanes because it only checks that the
claude CLI exists — the skill's own preflight note ("probe Z.ai quota GET") is manual
and was skipped. A cheap live-probe rung in doctor for glm/kimi (1-token ping or the
Z.ai quota endpoint) would have rerouted 3 cards' worth of retries at seed time.

Evidence: .bus-gtm-a/run-a1-adapter.jsonl{,.1,.2} (0-token synthetic error records),
.bus-gtm-a/limits/a1-adapter.parked (false-done marker). No spend (0 tokens billed).
