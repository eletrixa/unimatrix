---
source: grpn/refactor
date: 2026-07-25
run: parity012
type: bug
severity: medium
triaged-to: backlog#49 backlog#50
---

# glm card never claims while codex runs; codex review card needs >1200s

## What happened
Wave-5 review seeded two read-only cards: `w5-rev-codex` (.lane codex) and `w5-rev-glm` (.lane glm). Codex claimed immediately and ran until the 1200s watchdog killed it (claim released back to queue, res file empty). glm was NEVER claimed across the whole window (25+ minutes, FANOUT=6, no .limited/.dead markers, one unexplained empty .parked early on) despite a free pool. Earlier in the same run glm-pinned cards parked the same way while a sibling lane was busy.

## Expected
- With FANOUT=6 and two queued cards on different lanes, both should claim concurrently.
- A read-only review card over ~34 files on codex routinely needs more than 1200s; either a per-class timeout (REVIEW cards get a higher default) or documentation that review fan-outs should set WORKER_TIMEOUT_SEC=2400+.

## Evidence paths
- ~/code/unimatrix/.bus-parity012/cancelled/w5-rev-{codex,glm}.* (cards moved out after the stall)
- ~/code/unimatrix/.bus-parity012/run-w5-rev-codex.jsonl (truncated stream, watchdog kill)
- Contrast: five session-side seats over the same tree returned 31 findings in 8-12 min each.
