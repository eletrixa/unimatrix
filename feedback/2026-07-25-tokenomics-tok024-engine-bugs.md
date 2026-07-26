---
source: tokenomics
date: 2026-07-25
run: tok024
type: bug
severity: minor
---

# Two engine nits from tok024

1. **`swarm-run.sh: line 854: finished: unbound variable`** — fired right after the salvage
   path ("c3-store exceeded WORKER_TIMEOUT_SEC … salvaging as done") on the wave-1 pool exit.
   Salvage itself worked; the unbound variable suggests the post-salvage accounting path never
   ran. Evidence: wave-1 launch output (task log), around the c3-store timeout line.

2. **Orphaned claim on pool exit isn't reported** — `c8-http` was still in `claimed/` when the
   wave-1 pool exited (its work was complete on disk; res file never written, run stream 12MB).
   The exit summary listed the parked/incomplete cards but not the orphaned claim, so the
   only tell was `ls claimed/`. A one-line "N claims released/orphaned" in the close checklist
   would make the refinery-01 §b sweep automatic. Evidence:
   `~/code/unimatrix/.bus-tok024/run-c8-http.jsonl` + `claimed/` state before manual adoption.

Also one data point, not a bug: grok false-done (narration-only, zero writes, 8.8KB stream) on
`c14-view` — known class, engine's diff gate didn't catch it because the shared worktree cage
had sibling writes (cockpit057b §b geometry). Re-serve on claude:sonnet landed clean.
