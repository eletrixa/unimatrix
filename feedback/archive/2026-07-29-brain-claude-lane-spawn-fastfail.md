---
source: brain
date: 2026-07-29
run: pure064
type: bug
severity: major
decision: apply-now
triaged-to: backlog#76
---

# claude lane fast-failed at first spawn while the lane was demonstrably healthy

What happened: pure064 launch (12 cards, FANOUT=8, STAGGER default). Within ~20s the
engine wrote `limits/claude.broken` — `lane-down | retryable=0 | ttl=1800 | lane claude
fast-failed` — with ZERO run-*.jsonl for any claude card (died at spawn/probe, no stream).
Both `.chain`-pinned sonnet cards (c07, c09) chain-exhausted and parked. A direct
`claude -p "ok" --model claude-sonnet-5` succeeded seconds BEFORE launch (preflight ping)
and seconds AFTER the marker appeared.

Expected: a healthy lane should not be benched for 30 minutes on a spawn-time transient,
or at minimum the marker should carry the child's actual stderr so the operator can tell
cold-start-timeout from auth-death.

Evidence (paths, on the brain box): <brain-repo>/.bus-pure064/limits/
(markers since cleared + nudged; recovery worked: rm marker, swarm-ctl nudge ×2, both
cards then served clean). Engine stdout for the run: no claude/probe diagnostic lines at all.

Suspects: PROBE_AUTO live-probe or spawn racing the 8-way first-spawn herd; cf. round-4
lesson — codex cold start needed a 30s probe cap when a healthy lane FAILed at 10s. Same
class, claude flavor.

Ask: (a) probe/spawn cap sized for cold start under spawn herd; (b) `.broken` written from
a spawn-time failure should carry the child's last stderr line; (c) consider retryable=1
for zero-stream spawn deaths (nothing was attempted, nothing can be poisoned).
