# Spec 22 — Thrifty Profile (minimum-Anthropic operation)

**Status:** Active (activated 2026-08-04 — Robert, plan approval "lets-develop-with-unimatrix-rippling-dahl": ratifies a second operating profile that minimizes Anthropic frontier-token spend while keeping swarm speed — zero engine change, profile conf selected via the existing `CONF` env precedence)
**Date:** 2026-08-04
**Related specs:** [01-swarm-core](./01-swarm-core.md) (bus lifecycle, lane invocations), [04-settings](./04-settings.md) (env > conf-file > baked precedence), [08-speedwars](./08-speedwars.md) (ledger rows, report footer), [10-role-classes](./10-role-classes.md) (`_judge_ok` role classes, judge ≠ executor), [13-lane-health](./13-lane-health.md) (`doctor --live` probes), [15-direct-call](./15-direct-call.md) (delegated single-lane cards), [20-bus-namespacing](./20-bus-namespacing.md) (`--run` derivation), [21-speed-observability](./21-speed-observability.md) (lane caps, linger, probe fidelity)

---

## Overview

A second operating profile for unimatrix that minimizes Anthropic frontier-token spend while keeping swarm speed. Under thrifty, the orchestrator session (fable) orchestrates **only**; codex holds the planning and review seats; glm + grok are the exec class; cards are materialized by glm. The mechanism is deliberately cheap: a profile conf file selected via the existing `CONF` env var (zero engine change — spec 04 precedence: env > conf-file > baked defaults), plus two prompt templates, one doctor knob, and one report footer. Nothing here adds a model lane or touches the bus engine.

## Goals

1. **Cut Anthropic spend:** drive the orchestrator out of prose generation and verification; target <10% of priced cost per run on the Anthropic (claude) lane.
2. **Keep swarm speed:** FANOUT 6, generous glm/grok lane caps (4 each), 120s pool linger — thrifty is cheap, not slow.
3. **Zero engine change:** the profile is pure configuration riding the spec 04 precedence chain; `swarm.conf` is never edited.
4. **Keep the verify wave honest:** codex (not fable) reviews exec output; glm never judges its own work (`VERIFY_MAP` routes glm→codex).

## Non-Goals

Captured as FR-8 (out-of-scope row) rather than duplicated here — kimi exclusion, six-lane freeze, and the deferred cockpit share-metric surface all live there.

## Requirements

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-1 | **Profile file** `profiles/thrifty.conf`, selected via `CONF=$UNIMATRIX_HOME/profiles/thrifty.conf`; `swarm.conf` is never edited. Values: `PLAN=fable`, `ORCHESTRATOR=fable`, `REVIEW=codex:default`, `EXEC_CHAIN="glm:glm-5.2 grok:grok-4.5 codex:default claude:haiku"`, `CLASS_EXEC="glm grok"`, `CLASS_REVIEW="codex glm"`, `VERIFY_MAP="glm:codex grok:codex claude:codex gemini:codex kimi:codex codex:glm"`, `FANOUT=6`, `LANE_MAX_GLM=4`, `LANE_MAX_GROK=4`, `LANE_MAX_CLAUDE=1`, `WORKER_TIMEOUT_SEC=900`, `TIMEOUT_CODEX=300`, `MAX_LANE_RETRIES=2`, `BUDGET_USD=5`, `PAYG_FALLBACK=deny`, `POOL_LINGER_SEC=120`, `MON_AUTOOPEN=0`. | Must |
| FR-2 | **PLAN stays `fable` by design.** `_judge_ok` (spec 10) disqualifies a seated non-fable PLAN lane from all judging — seating codex at PLAN would ban it from the verify wave. Codex instead plans via a delegated read-only card (FR-3); it never holds the PLAN seat. | Must |
| FR-3 | **Delegated planning** via template `profiles/thrifty/plan-request.md`: codex receives a context-file manifest plus an appended TASK and returns exactly one JSON object — waves → cards, each card carrying `id`/`title`/`complexity`/`chain`/`write`/`files`/`timeout_sec`/`prompt`. Card prompts must be self-contained; write paths are disjoint across cards; waves exist only as dependency barriers; `.claude/` cages are forbidden. | Must |
| FR-4 | **Card materialization** via template `profiles/thrifty/card-writer.md`: glm (the write-capable lane; cage = the bus `specs/` dir) expands the JSON into `<id>.prompt` plus `.chain`/`.write`/`.files` sidecars. Wave ≥2 cards are staged with a `.waveN` suffix and promoted at barriers by the orchestrator via `swarm-ctl add`. Failure ladder: lint-specs fail → one haiku retry with the lint errors appended → fable hand-writes only the failing cards; codex plan failure → one retry → fable in-session planning (terminal fallback). | Must |
| FR-5 | **`DOCTOR_LANES` env knob** (env-only, deliberately not in `CONF_KEYS`): a space-separated subset for the doctor `--live` probe loop; unset = all six lanes. Thrifty preflight gate: `DOCTOR_LANES="glm grok codex claude" unimatrix doctor --live` must exit 0 before any thrifty run, so a dead kimi balance does not fail the gate. | Must |
| FR-6 | **Anthropic-share footer.** The text report (speedwars fold) closes its fold summary — after the lane tables, before the trailing reviews section — with one tab-less line: `anthropic share: $X of $Y priced cost (Z%) · A of B tokens (C%) — claude lane only; fable session + doctor probes not ledgered`. Computed over the report's row set (so a `--run` prefilter applies): priced rows = non-null `cost_usd`; Anthropic-billed = `served_lane=="claude"`. The `--json` branch stays byte-identical to pre-change output — pinned three-way contract with tests/fixtures and the cockpit fold. | Must |
| FR-7 | **Orchestrator token diet** (operating rule, enforced by the `/u:thrifty` command body at `.claude/commands/u-thrifty.md`): take status only via `swarm-ctl` verbs; never read raw worker streams or card bodies; delegate all prose deliverables to glm cards; target anthropic share <10% of priced cost per run. | Must |
| FR-8 | **Out of scope / non-goals.** kimi stays out of the exec chain and review class (dead balance 2026-07-26, Rob-ratified 2026-08-04); no new lanes (six-lane freeze per spec 10 / CLAUDE.md); no cockpit surface for the share metric (would require changing the pinned `--json` contract + fold fixtures together — future work). | — |

## Boundaries

- **Always**: run the `DOCTOR_LANES="glm grok codex claude" doctor --live` gate before any thrifty run. Keep thrifty in its own profile file — never edit `swarm.conf`. Keep the `--json` report byte-identical (three-way contract: code + fixtures + cockpit fold). Log every card attempt's spend in the run-evidence ledger.
- **Ask first**: adding a lane beyond the six-lane freeze; changing the pinned `--json` contract or the fold; seating a non-fable PLAN lane.
- **Never**: let glm judge its own output (`VERIFY_MAP` routes glm→codex). Point the orchestrator at raw worker streams or card bodies (breaks the token diet). Spend on a card lane without ledgering it (doctor probes and the fable session are the two documented un-ledgered exceptions — FR-6).

## Acceptance Criteria

- [ ] The doctor gate exits 0 with `DOCTOR_LANES="glm grok codex claude"` while kimi is dead (bats fixture / live check).
- [ ] A pilot thrifty run completes the full protocol — codex plan card → glm card-writer → lint-specs → run → verify wave — with anthropic share <10% of priced cost.
- [ ] The `--json` report is byte-identical pre/post the footer change (three-way pinned contract).
- [ ] `tests/thrifty-profile.bats` covers conf resolution, footer math + `--run` filter, json byte-identity, and the `DOCTOR_LANES` subset.

## Dependencies

- Specs 01 (bus/lane invocations), 04 (CONF precedence), 08 (ledger + report), 10 (`_judge_ok` role classes), 13 (`doctor --live` probes), 15 (delegated cards), 20 (`--run`), 21 (lane caps, linger, probe fidelity).
- No new external dependencies — thrifty is conf + two templates + one env knob + one footer, all over existing engine surfaces.
