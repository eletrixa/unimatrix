---
source: unimatrix
date: 2026-07-25
run: parity012
type: bug
severity: minor
triaged-to: backlog#49
---

Auto-detected: 1 branch(es) with outcome=timeout this run.

Affected (id lane): w5-rev-codex codex

Evidence: docs/ops/speedwars.jsonl (run-<id>.jsonl per id; res-<id>.txt if still present)
Ready-to-paste jq filter: jq -c 'select(.run == "parity012" and .outcome == "timeout")' docs/ops/speedwars.jsonl

Confirmed: direct evidence for backlog 49 — the 1200s watchdog kill on `w5-rev-codex`
matches the same card's repeated-timeout parking in atlas013 (a same-prompt direct
`codex exec` probe took ~840s, under the ceiling, pointing at wrapper overhead rather
than raw model latency).
