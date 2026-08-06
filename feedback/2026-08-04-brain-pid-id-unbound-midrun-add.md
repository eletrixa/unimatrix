---
source: brain
date: 2026-08-04
run: pq077
type: bug
severity: high
---

# Driver dies with `pid_id[$finished]: unbound variable` after a mid-run `swarm-ctl add`

## What happened
15 pre-seeded cards launched clean (`--run pq077 --busdir ~/brain/.bus-pq077`, FANOUT=8, POOL_LINGER_SEC=600). Mid-run, one card (`pq3fix`) was added via `swarm-ctl add` while ~6 workers were in flight. On the next worker completion the driver hit:

```
~/code/unimatrix/swarm-run.sh: line 1470: pid_id[$finished]: unbound variable
```

then fell through to run-close (printed lane stats + close checklist, exit 0) while **6 claimed cards were still live** (pq3fix, pq4, pq5, pq7b, pq8, sb1). Workers survived (own process groups) and kept writing `run-*.jsonl`; the run closed with `vdone 0/…` everywhere and no driver to finalize/timeout the survivors.

## Expected
`wait -n` pool accounting tolerates pids that aren't in `pid_id` (or the add path registers the new card's worker pid before it can be reaped). Driver must not treat a crashed wait-loop as a drained pool — 6 live claims + exit 0 is a silent-orphan class.

## Evidence paths
- bus: `~/brain/.bus-pq077` (claimed/ retained the 6, done/ had 10 incl. earlier normal completions AFTER the same-invocation add — so the add itself was served fine; the crash came later)
- driver stdout: session task output `bpx6rxxiu` (brain repo session c40de5b1), error line verbatim above
- swarm-run.sh @ 44382f7, line 1470

## Note
POOL_LINGER_SEC + mid-run add is the documented pattern (spec 21) — this run followed it. Orchestrator recovered by watching orphan streams to completion and salvaging from disk.
