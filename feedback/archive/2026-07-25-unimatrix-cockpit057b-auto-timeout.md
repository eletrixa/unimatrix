---
source: unimatrix
date: 2026-07-25
run: cockpit057b
type: bug
severity: minor
triaged-to: backlog#46 backlog#47
---

Confirmed: symptom of backlog 46/47 (chain-position + session-limit classes) — see the
main cockpit057b item.

Auto-detected: 7 branch(es) with outcome=timeout this run.

Affected (id lane): a-cron claude, a-port-l1 claude, a-port-lenses claude, a-port-norm claude, a-port-gaps claude, a-llm2 claude, a-port-lenses claude

Evidence: docs/ops/speedwars.jsonl (run-<id>.jsonl per id; res-<id>.txt if still present)
Ready-to-paste jq filter: jq -c 'select(.run == "cockpit057b" and .outcome == "timeout")' docs/ops/speedwars.jsonl
