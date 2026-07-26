---
source: unimatrix
date: 2026-07-25
run: atlas013
type: bug
severity: major
triaged-to: backlog#49 backlog#50
---

Auto-detected: 2 branch(es) parked (lane exhausted) this run: w5-rev-codex w5-rev-glm

Evidence: .bus-atlas013/limits/*.parked

Confirmed: same card ids as parity012's `w5-rev-codex`/`w5-rev-glm` parks — corroborates
the codex review-timeout finding (backlog 49) and the glm claim-starvation finding
(backlog 50); see `2026-07-25-grpn-refactor-codex-lane-wrapper-unusable.md` and
`2026-07-25-grpn-refactor-glm-never-claims-codex-timeout.md`.
