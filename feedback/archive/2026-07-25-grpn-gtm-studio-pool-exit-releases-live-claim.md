---
source: grpn-gtm-studio
date: 2026-07-25
run: refinery-01
type: bug
severity: high
triaged-to: backlog#55
---
# Pool shutdown released a still-RUNNING card's claim back to queue/

What happened: pool-1 exited (its other cards terminal) and moved claimed/R3.7.prompt
back to queue/ while R3.7's worker process was alive and writing files. A second
pool with a free worker would have started a duplicate R3.7 against the same write
target; the orchestrator caught it within a minute and pulled the queue entry.

Expected: at shutdown, a claimed card whose worker pid is still alive (or whose
run-<id>.jsonl mtime is fresh) must stay claimed — release only provably-dead claims.

Evidence: .bus-refinery-01 run-R3.7.jsonl streaming past the pool-exit timestamp;
queue/R3.7.prompt reappearing at pool exit.
