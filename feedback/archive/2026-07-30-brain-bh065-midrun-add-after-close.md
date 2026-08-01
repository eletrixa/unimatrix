---
source: brain
date: 2026-07-30
run: bh065
type: friction
severity: minor
decision: apply-now
triaged-to: backlog#79
---

# swarm-ctl add lands a card on a closed bus with no way to serve it but a full relaunch

What happened: run bh065's wave-1 pool drained fast; a dependent card (w5, needed a sibling's
rendered markup) was held back and `swarm-ctl add`-ed into `queue/` mid-run — but the invocation
had already closed its pool, so the card sat unclaimed until a fresh `swarm-run --run bh065 ""`
invocation was launched purely to drain one card (plus once more for the review wave, plus once
more for the fix wave — four invocations for one logical run).

Expected/suggestion: either (a) `swarm-ctl add --serve` that spawns a single detached worker
for the new card when no live orchestrator holds the bus, or (b) a `swarm-run --wave` mode that
stays resident N minutes after drain waiting for late adds, or (c) document the
one-invocation-per-wave pattern as the intended shape (it works — it's just 4 launches and 4
sets of close-checklist noise for one run label).

Evidence: bh065 bus history 2026-07-30 (w5 queued ~00:40, drained by relaunch ~01:55 CEST).
