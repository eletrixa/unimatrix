---
source: grpn-gtm-studio
date: 2026-07-26
run: gtm-runq
type: bug
severity: major
---

Bare lane tokens in `.chain`/`.lane` sidecars resolve to INVALID model ids on kimi and codex — both fail instantly, burning all 3 MAX_LANE_RETRIES per card before failover.

What happened: wave-1 sidecars pinned `kimi` (bare) and review cards pinned `codex` (bare). The driver passed the bare token through as the model id: Moonshot answered `400 [1211][Unknown Model]` on every kimi attempt (3 cards x 3 retries, $0 but ~9 wasted spawns + failovers), and codex answered `The 'codex' model is not supported when using Codex with a ChatGPT account` (2 cards parked on a pinned lane). Re-seeding with `kimi:kimi-k3` / `codex:default` worked first try — kimi 2/2 clean, codex 2/2 clean.

Expected: a bare lane token should resolve to that lane's KNOWN-GOOD default model (the same one `doctor`'s `_doctor_probe_model` uses), or the enqueue step should refuse a bare token for lanes whose CLIs require an explicit model. EXEC_CHAIN in swarm.conf already carries the correct pairs (`kimi:kimi-k3`, `codex:default`) — the per-card sidecar path just doesn't inherit those defaults.

Evidence paths: .bus-gtm-runq/run-c3-verify.jsonl (kimi 400 rows), .bus-gtm-runq/run-r1-diff-review.jsonl (codex model error), .bus-gtm-runq/limits/ (park markers), swarm.conf EXEC_CHAIN.
