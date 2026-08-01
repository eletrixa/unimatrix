---
source: brain
date: 2026-07-29
run: pure064
type: ops-lesson
severity: major
decision: apply-now (docs)
triaged-to: skill-ledger 2026-07-29
---

# Account session limit killed all 3 session-side fix agents simultaneously mid-partition

What happened: pure064's fix wave ran as 3 parallel claude session agents (disjoint file
partitions). The account hit its session limit; all three died within 10s of each other
("You've hit your session limit · resets 4:10pm"), each mid-partition. One partition had
fully landed queries.ts + the assemble redaction helper, one had landed nothing, one
nothing — recovery was salvage-first (grep the tree per partition for landed markers) +
3 FRESH respawns with salvage-aware briefs (never resume the killed agents — atlas013-e
collision class). Total loss: ~20 min + one human unblock ("go, limit just reset").

Expected/ask: the cockpit057b lesson ("pre-authorize a watchdog cron BEFORE hitting
limits — if limited, resume in 2h") applies to SESSION-SIDE agent waves too, not just bus
lanes — but nothing operationalizes it for the hybrid (bus + session agents) pattern.
Suggest a skill §Lessons/§6 line: before spawning a session-agent wave, note the reset
time and pre-authorize the resume plan (salvage-audit checklist per partition + fresh
respawn briefs), so recovery is mechanical instead of orchestrator-improvised.

Evidence: pure064 run, brain repo; salvage audit + respawn briefs in the session
transcript; fix-wave manifests all-green post-respawn.
