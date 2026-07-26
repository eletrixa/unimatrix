---
source: grpn/refactor (swarm B atlas013 orchestrator)
date: 2026-07-25
run: atlas013
type: bug
severity: medium
triaged-to: backlog#49 backlog#52
---

# codex bus lane: 3x unusable answers while `codex exec` direct works perfectly

## What happened
Review card `w5-rev-codex` (read-only, no `.write` sidecar, pinned `.lane codex`) was
parked: "produced no usable answer 3 times on lane 'codex' - retries exhausted". No
run stream survived on the bus to diagnose the wrapper's failure mode.

Direct probe minutes later: `codex exec "Reply with exactly: CODEX-OK"` returned
CODEX-OK (16.6k tokens), and running the SAME card prompt via
`timeout 1500 codex exec "$(cat prompt)"` produced a complete, high-quality
10-finding review (exit 0, ~14 min). The model and auth were fine; the lane wrapper
is what failed.

## Expected
Either the wrapper serves what the CLI serves, or the park diagnostics say WHY the
answer was unusable (empty? classifier hit? timeout mid-stream? cwd issue on a
read-only card with no cage?). Note the possibly related class: read-only cards with
NO `.write` sidecar also killed glm/claude workers in this run when a cage dir was
missing - the codex card had no cage at all, which may be the same seam.

## Evidence paths
- ~/code/unimatrix/.bus-atlas013/ (limits markers as left by the run)
- scratchpad wave5rev-run.log lines: "w5-rev-codex produced no usable answer 3 times
  on lane 'codex'" / "parked (lane exhausted) - run is INCOMPLETE"
- Working direct output: scratchpad codex-review.txt (10 findings, model gpt-5.6-sol)

## Recovery used (worked)
Fable fallback lane: ran the card prompt through `codex exec` directly and folded the
findings into the panel adjudication. Zero coverage lost.
