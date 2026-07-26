---
source: brain
date: 2026-07-24
run: cockpit057-prep
type: friction
severity: major
triaged-to: skill-ledger 2026-07-24
---

Session-side swarm (Agent-tool executors, no bus): claude session agents RELIABLY stall at the
"background step exited → resume remaining steps" seam on long multi-step lanes. 3 stalls across
2 agents on one ingest lane (plan 057 wave-0 S0b, a 7-step Python pipeline):

1. `s0-ingest` launched step 3 (long crawl) in background bash, then idled instead of babysitting
   (~15 min before nudge); after an orchestrator nudge it armed a correct heartbeat waiter — and
   STILL went silent after the waiter fired (43 min → substituted per the 40-min rule).
2. Substitute `s0-ingest2` fixed the babysitting (60s heartbeat loop, correct), but stalled at the
   NEXT seam: step 5's subprocess exited cleanly and the agent did nothing for ~52 min until nudged.
   One nudge later it finished everything in one wake, perfectly.

Expected: agent resumes the scripted remaining steps when its awaited background command exits
(the harness re-invokes on background-bash exit — the wake happens, the continuation doesn't).
Explicit brief text ("do NOT idle between steps", "finish in this one wake" worked only on the
final nudge) does not reliably survive the wake boundary.

Doctrine proposals for the skill/planning layer (this is a lane-behavior class, not an engine bug):
- Long multi-step lanes: ONE step per card, orchestrator sequences (the bus pattern already does
  this — session-side swarms should mirror it instead of "run steps 3–7" briefs).
- Or: the driver is a deterministic shell script; the agent only launches + reports it.
- Or: orchestrator sets a wake-timer at spawn matched to the step's expected duration instead of
  trusting idle notifications (idle fired 3× here while work was pending).
- Artifacts-as-truth held throughout: every stall was diagnosed from disk (progress log, WAL
  mtime, pid table), never from agent claims. Zero data loss all 3 stalls.

Evidence paths:
- brain/plans/057-bet-cockpit-migration/unimatrix-feedback.md (dated entry)
- cockpit-rehost/S0B-PROGRESS.log (timestamped stall gaps: 17:47:35Z→18:31Z, 18:43:23Z→19:35Z)
- cockpit-rehost/S0-REPORT.md (the substitute's own stall confession, "top 3 surprises")
