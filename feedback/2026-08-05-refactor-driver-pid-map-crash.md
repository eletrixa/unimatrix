---
source: refactor
date: 2026-08-05
run: rr-d07-live-events
severity: major
---

# swarm-run driver crash: `pid_id[$finished]: unbound variable` (line 1470)

Mid-run `swarm-ctl cancel` of queued cards + `swarm-ctl add` of replacement cards (-ro variants)
while the driver's pool was serving. Driver aborted with
`swarm-run.sh: line 1470: pid_id[$finished]: unbound variable`, leaving live claimed workers
orphaned (their SIGTERM propagated on the crashed pgid — every in-flight grok card ended
"Cancelled" at 2 turns). Reproduce shape: seed N cards, start driver, cancel a queued card and
add a new id while >=1 worker is claimed. Guard `pid_id[$finished]` reads with a default
(`${pid_id[$finished]:-}`) or skip unknown pids in the reap loop.
