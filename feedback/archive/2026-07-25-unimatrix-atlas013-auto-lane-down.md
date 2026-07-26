---
source: unimatrix
date: 2026-07-25
run: atlas013
type: bug
severity: major
triaged-to: backlog#51
---

Auto-detected: lane(s) marked dead/broken this run: glm.broken

Evidence: .bus-atlas013/limits/*.dead, .bus-atlas013/limits/*.broken

Confirmed: corroborates `2026-07-25-grpn-refactor-glm-broken-empty-diagnostics.md` — root
cause was a `.write` sidecar pointing at a nonexistent directory, killing the worker
pre-byte and wrongly flagging the lane instead of the card (backlog 51).
