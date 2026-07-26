---
source: unimatrix
date: 2026-07-25
run: refinery-01
type: bug
severity: minor
triaged-to: backlog#46 backlog#47
---

Auto-detected: 1 branch(es) with outcome=timeout this run.

Affected (id lane): R3.7 claude

Evidence: docs/ops/speedwars.jsonl (run-<id>.jsonl per id; res-<id>.txt if still present)
Ready-to-paste jq filter: jq -c 'select(.run == "refinery-01" and .outcome == "timeout")' docs/ops/speedwars.jsonl

Confirmed: same fingerprint as cockpit057b — empty limits/.chain-* files (backlog 46) + session-limit/auth-death-classed claude failovers (backlog 47). See the main cockpit057b item.
