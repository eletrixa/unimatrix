---
source: unimatrix
date: 2026-07-25
run: refinery-01
type: bug
severity: major
triaged-to: backlog#46 backlog#47
---

Auto-detected: 4 branch(es) parked (lane exhausted) this run: R2.2 R2.3 R2.4 R2.6

Evidence: .bus-refinery-01/limits/*.parked

Confirmed: same fingerprint as cockpit057b — empty limits/.chain-* files (backlog 46) + session-limit/auth-death-classed claude failovers (backlog 47). See the main cockpit057b item.
