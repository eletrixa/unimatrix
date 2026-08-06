---
source: refactor (lead repo, rr-d13-payments run)
date: 2026-08-04
run: rr-d13-payments
type: observation
severity: medium
---

# Pool driver background process died mid-run; glm claims orphaned without heartbeat

## What happened

The rr-d13-payments pool (launched with `--busdir`, POOL_LINGER_SEC=600, 14 cards) died
~19 minutes in — the orchestrator's harness reported the background task "stopped" (not
completed). Post-mortem state: no live workers, no `heartbeat` file in the bus, `claimed/`
still holding three glm claims (b2/b5/b7) with `.claimed-at` markers, `done=5`. The b-cards
that had finished (b1/b3/b4/b6/b8) all left complete res files — nothing lost.

Cannot attribute root cause from this side: could be harness-side task kill or engine exit;
the driver's captured stdout tail was empty at kill time. Relaunch on the same busdir
re-served the orphaned claims cleanly (reap liveness guard worked).

## Ask

If the engine exits abnormally while lingering (POOL_LINGER_SEC set), a last-gasp line in the
bus (e.g. `limits/pool.exit-reason`) would make the next orchestrator's salvage cheaper than
inferring from process absence + marker mtimes.
