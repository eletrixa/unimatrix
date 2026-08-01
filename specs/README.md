# Specs

UNIMATRIX — a Claude Code slash-command (`/swarm`, `/swarm-loop`) that fans out a question or
goal across six headless CLI model lanes (Claude, Codex, Gemini, GLM, Grok, Kimi) over a file-based bus, with
a read-only tmux/WezTerm monitoring cockpit. No MCP, no daemon, no DB.

## Index

| Spec | Status | Description |
|------|--------|-------------|
| [04-settings](./04-settings.md) | Active | `swarm.conf` roles/lanes, precedence, GLM tier-env mechanism, reactive limit failover |
| [01-swarm-core](./01-swarm-core.md) | Active | `/swarm` engine: bus lifecycle, 6 lane invocations, job-pool scheduler, completeness gate |
| [02-cockpit](./02-cockpit.md) | Active | tmux/WezTerm monitor: board/firehose/cost panes, `swarm-ctl` control verbs |
| [03-swarm-loop](./03-swarm-loop.md) | Active | `/swarm-loop`: criteria contract, iterate-until-met, judge ≠ executor, stop rules |
| [05-ground-control](./05-ground-control.md) | Active | Web cockpit server on :4747, `gc` fleet registration, swarm auto-open, dual-audience site guides |
| [06-live-model-cost](./06-live-model-cost.md) | Active | live per-model notional cost panel + `/api/models` endpoint |
| [07-cockpit-redesign](./07-cockpit-redesign.md) | Active | 3-view agent cockpit redesign + web control surface `/api/ctl` |
| [08-speedwars](./08-speedwars.md) | Active | per-branch lane speed-evidence JSONL ledger + `/speedwars` report |
| [09-speedwars-panel](./09-speedwars-panel.md) | Active | SPEEDWARS cockpit tab: `/api/speedwars` + TOTAL/SPEED/COST/RELIABILITY/TOKENS/RUNS sub-tabs |
| [10-role-classes](./10-role-classes.md) | Active | Role classes (CLASS_REVIEW/CLASS_EXEC), judge fallback chain, claude/gemini limit detection, bounded pin-wait, kimi budget gate, unusable-answer classifier |
| [11-succession](./11-succession.md) | Active | Orchestrator succession: heartbeat + one-shot cron watchdog, kimi continuation driver under bounded mandate, `orch-seat`, `degraded:true` provisional work |
| [12-failure-evidence](./12-failure-evidence.md) | Active | Failure-class vocabulary, `run-summary` ledger record, auto-drafted `feedback/` stubs (`status: draft`), `swarm-ctl report/postmortem/review-stub`, durable audit log |
| [13-lane-health](./13-lane-health.md) | Active | Launch-time env-master preflight, `doctor --live` auth probes, TTL'd `.broken` fast-fail lane marker, `PAYG_FALLBACK` gate at `BUDGET_USD=0` |
| [14-write-cage-attribution](./14-write-cage-attribution.md) | Active | Per-card write attribution (`.files` manifest), cage-denial evidence markers, lane-limit fidelity, write-target existence check, sibling-liveness guard, structured marker reason lines |
| [15-direct-call](./15-direct-call.md) | Active | `call` verb: direct single-lane dispatch (pin/chain), bulk file-list sharding, chunk-manifest close-out report, bus-local + aggregate ledger |
| [16-unified-cli](./16-unified-cli.md) | Active | `unimatrix` umbrella CLI: thin git-style router over the four scripts, flattened ctl verbs, `u-` slash-command namespace with alias stubs |
| [17-plugin](./17-plugin.md) | Active | Plugin packaging: `/u:*` colon namespace from any repo/account via self-marketplace, generated pointer commands, `unimatrix install`/`here`, `doctor --plugin` drift table |
| [18-evidence-contract](./18-evidence-contract.md) | Active | Push summary + bus archives + `report --html` + fleetops producer contract (`sql/uni-schema.sql`, D1 contract-first) + D2 gate; executable mirror reserved for spec 19 |
| [20-bus-namespacing](./20-bus-namespacing.md) | Active | Per-run bus namespacing: one `--run <label>` atomically derives BUSDIR + SPEEDWARS_RUN + cockpit identity; live-heartbeat collision refusal (backlog 11/21; FR-7 fleet view staged) |
| [21-speed-observability](./21-speed-observability.md) | Active | Speed + timeline observability: `POOL_LINGER_SEC`, probe/bench fidelity (`PROBE_TIMEOUT_SEC`, 600s probe-FAIL, `BROKEN_MIN_CARDS`), claim-time cage preflight, `--busdir`, env-master candidates, claim stamp + `queue_wait_secs`, `swarm-ctl timeline`, `top_wall`, `LANE_MAX_<lane>`, longest-first claiming, FANOUT 6 (backlog 76-82) |

## Dependency Graph

```
04-settings ──▶ 01-swarm-core ──▶ 02-cockpit ──▶ 05-ground-control ──▶ 06-live-model-cost
                     │                  │                │                      │
                     │                  └────────────────┴──────────────────────┴──▶ 07-cockpit-redesign
                     └──────────▶ 03-swarm-loop

04-settings ────┐
                ├──▶ 08-speedwars ──▶ 09-speedwars-panel
03-swarm-loop ──┘                          ▲
                                           │
07-cockpit-redesign ───────────────────────┘

04-settings ──┐
              ├──▶ 10-role-classes ──▶ 11-succession
08-speedwars ─┘  (measurement substrate)

01-swarm-core ─┐
04-settings ───┼──▶ 15-direct-call
10-role-classes┘

01-swarm-core ─┐
02-cockpit ────┼──▶ 16-unified-cli
03-swarm-loop ─┘

10-role-classes ───┐
                   ├──▶ 13-lane-health ──▶ 14-write-cage-attribution
12-failure-evidence┘

15-direct-call ─┐
                ├──▶ 17-plugin
16-unified-cli ─┘
```
