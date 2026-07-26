# Remediation Plan — 2026-07-12

**Status: archived scratch note (2026-07-12)** — superseded by shipped specs; kept for history.

Source: 10-dimension Opus 4.8 audit + adversarial per-finding verification (59 agents, 0 errors).
45 confirmed (17 P2, 28 P3), 4 refuted. Fable lead adjudicated: merged duplicates, rejected
refuted + immaterial, prioritized. No P0/P1. Refuted rejections at bottom.

Method per issue: red-green-double-refactor (rules + specs pass), `bats tests/` after each file,
fresh-Opus review after. All work on `refactor/2026-07-12-autonomous-codebase-cleanup`.

## P2 — confirmed, actionable (deduped)

| ID | Issue | Files | Fix |
|----|-------|-------|-----|
| R1 | `cmd_config` unescaped `sed`/quote/missing-arg corrupts `swarm.conf` (breaks `source`) | swarm-run.sh:87-92 | escape `&\|\\` in replacement; refuse a `"` in value; guard missing value → usage |
| R2 | Ledger `awk -v row=` escape-processes prompt text → re-breaks the table pipe-escape protects | swarm-lib.sh:738 | pass `row` via `ENVIRON` not `-v` |
| R3 | Ledger label = `## Criteria…` for loop specs (documented backlog) | swarm-lib.sh:760 | fall back to spec id when first line starts with `#` |
| R4 | Ledger logs only successful finalizes — timeout/limit/wrc9 spends leave no row (silent spend) | swarm-run.sh:234-277 | append a ledger row (partial/failed cost note) on every path where a run log exists |
| R5 | swarm-loop judge==executor after EXEC_CHAIN failover; guard checks only chain head | swarm-loop.sh:65-74 | `_check_judge_ne_exec` must reject judge matching ANY chain lane |
| R6 | Cross-model review sees executor's self-reported answer, not the worktree diff (FR-3, proof-of-action) | swarm-loop.sh:201-223,267 | include `git diff base_sha..` of the worktree in the review prompt |
| R7 | `human_gate` resume runs a fresh exec iteration, mutating the approved worktree before completing | swarm-loop.sh:442-459 | on resume, if last state is goal-hit + HUMAN_OK, complete without re-iterating |
| R8 | Oracle runs worktree (worker-written) code in the orchestrator's un-caged env (secrets in scope) | swarm-loop.sh:276 | run oracle under `env -i PATH LANG HOME=<scratch>` — scrub creds/`$HOME`-rooted secrets |
| R9 | Budget stop-rule is a permanent no-op; spec/loop-discipline list it "Must / halts immediately" | swarm-loop.sh:312-320,362-367 | sum this run's claude/glm `total_cost_usd` per iteration into `state.jsonl`; wire `_budget_exceeded` |
| R10 | Web cockpit COST/BOARD/FIREHOSE all consume wrong server shapes — whole web cockpit is broken | site/cockpit.html:282-291,323-341,348-360 | fix client to match server.mjs: `d.lanes[]`, snake_case `stale_leases`/`active_limits`, SSE JSON `{worker,line}` |
| R11 | tmux firehose glob resolves once; empty bus at cockpit-start ⇒ firehose never populates | swarm-mon.sh:91-101 | `nullglob` + poll until first run file, then tail; document late-new-id limit (web is authoritative) |
| R12 | `swarm-ctl abort` acts on stale/bogus `run.pgid`; `plan_only` writes `$$` (a PID) | swarm-run.sh:66,395; src/swarm-ctl:63-67 | drop plan_only pgid write; `rm run.pgid` after pool; liveness-guard `abort` |
| R13 | `npm run lint` covers only 1 of 5 scripts (README claims "5 scripts clean") | package.json:8, CLAUDE.md:28, site/agents.md | lint all 5 scripts in lockstep |

## P3 — confirmed, actionable

| ID | Issue | Files |
|----|-------|-------|
| R14 | `cancel`/`kill --cancel` orphan `.lane`/`.write` sidecars → poison same-id `add` | src/swarm-ctl:41-52,86-108 |
| R15 | Board/`/api/bus` QUEUED count includes `.lane`/`.write` sidecars (inflated) | swarm-mon.sh:58, site/server.mjs:108 |
| R16 | Per-iteration git commit default-off ⇒ FR-8 git-reset safety net absent by default | swarm-loop.sh:312 |
| R17 | Oscillation stop shadowed by plateau at default plateau=3 | swarm-loop.sh:461-471 |
| R18 | Two bats files miss the required structured header | tests/cockpit.bats, tests/ground-control.bats |
| R19 | `site/.playwright-cli` QA artifacts not in `.assetsignore` (deploy leak) | site/.assetsignore |
| R20 | server.mjs no Host-header guard (DNS-rebind reads bus metadata) | site/server.mjs |
| R21 | README quickstart says set gemini/GLM keys as env vars; code reads only `$ENV_MASTER_FILE` | README.md:60-62 |
| R22 | CHANGELOG `[Unreleased]` has two `### DOCS` headers | CHANGELOG.md |
| R23 | Spec drifts: 02 FR-7 kill doc, 01/04 nonexistent bats names, 03 "tiers 1-3", swarm-run FR-5 comment, swarm-lib FR-12 header | specs/*, swarm-run.sh:380, swarm-lib.sh:16 |
| R24 | Checklist `[PASSING]` goal clause unimplemented (decorative) — document as advisory in v1 | swarm-loop.sh, specs/03, loop-discipline.md |
| R25 | Test gaps for real guards: GLM next_flush TTL, criteria-mismatch `_die`, review fail-closed, server cost/bus fields | tests/* |

## Deferred / documented-limitation (not silent — recorded here)

- **Docker `-e KEY=value` argv exposure (P3, #24):** the FR-16 lane's key is visible in
  `/proc/<pid>/cmdline`. On this single-operator box, and given the spec + a live-verified receipt
  lock in the explicit `-e NAME=value` form, the practical risk is negligible; changing to
  child-env + bare `-e NAME` is a strict improvement but churns a live-verified contract. **Applied**
  only if it does not break the FR-16 argv-shape test; else documented here as accepted.
- **Stop rules only checked between iterations (P3, #23):** a rate-limited *pinned* judge lane can
  stall an iteration past `wall_clock`. Requires the judge lane to be `limit_active`; low frequency.
  Documented as a known bound; `WORKER_TIMEOUT_SEC` bounds any *claimed* spawn.
- **`/api/cost` deep-sum vs `_cost_summary` top-level-sum (P3, #41):** minor numeric divergence in a
  best-effort, ponytail-caveated token estimate. Aligned if trivial, else noted.
- **Oracle absolute-path secret read (refuted finding):** `env -i` + scratch HOME (R8) closes
  `$HOME`-rooted + env-var creds but not a hardcoded absolute path read. Documented ceiling in
  loop-discipline.md; matches attended-v1 posture.

## Refuted by adversarial verify — rejected (agree with refutation)

1. LOOP_GOAL newline shadowing criteria — real mechanics, immaterial (checksum over post-write file; single-line contract by design).
2. `env -i` doesn't block absolute-path fs reads — true but out of `env -i`'s remit; folded into R8's documented ceiling.
3. stale-finalize `>>` shared run log — the documented FR-14 v1 backlog gap; res/done integrity fenced by dev:inode.
4. Fake CLIs omit model/cost envelopes so provenance untested — contradicted by code (fakes do drive it); R25 still adds explicit assertions.

## Disposition log

Filled as each R# lands (status, commit, review). See `plans/refactor-progress.md` task ledger.
