---
source: unimatrix
date: 2026-07-25
run: parity012
type: bug
severity: major
triaged-to: backlog#49 backlog#50
---

Auto-detected: 2 branch(es) parked (lane exhausted) this run: w5-rev-codex w5-rev-glm

Evidence: .bus-parity012/limits/*.parked

Confirmed: same run as `2026-07-25-grpn-refactor-glm-never-claims-codex-timeout.md` —
`w5-rev-codex` parked after the review-timeout signature (backlog 49), `w5-rev-glm`
parked after never claiming a free, healthy pool (backlog 50).
