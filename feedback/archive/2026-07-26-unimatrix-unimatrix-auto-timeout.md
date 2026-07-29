---
source: unimatrix
date: 2026-07-26
run: unimatrix
type: bug
severity: minor
triaged-to: backlog#62
---

Auto-detected: 1 branch(es) with outcome=timeout this run.

Affected (id lane): p53-build-drift glm

Evidence: docs/ops/speedwars.jsonl (run-<id>.jsonl per id; res-<id>.txt if still present)
Ready-to-paste jq filter: jq -c 'select(.run == "unimatrix" and .outcome == "timeout")' docs/ops/speedwars.jsonl
