# Refactor Synthesis — 2026-07-12

**Status: archived scratch note (2026-07-12)** — superseded by shipped specs; kept for history.

## Outcome

Autonomous audit + remediation of `unimatrix` complete. **45 confirmed findings** from a
10-dimension multi-model audit (0 P0, 0 P1, 17 P2, 28 P3, all adversarially verified) fixed across
**8 commits** on `refactor/2026-07-12-autonomous-codebase-cleanup`, deduped into 27 remediation
work-items. Final adversarial review (6 fresh Opus reviewers) found **no code defects** — only 3
doc/comment drifts introduced by the fixes, which were then corrected.

- **Branch:** `refactor/2026-07-12-autonomous-codebase-cleanup`
- **Base commit:** `a1aa7c5` (local `main`)
- **Final commit:** `84bd51a`
- **Final `git status`:** clean (all work committed)
- **Not pushed** (repo policy: push only to `main`; merge is the user's call).

## Initial state & baseline

Clean working tree, on `main`. Baseline verification (branch @ `a1aa7c5`):
`bats tests/` → **160/160 pass**; `shellcheck -x` (5 scripts) → **clean**. No baseline failures;
every finding below was pre-existing on `main`.

## Findings by priority (confirmed, adjudicated)

| Priority | Confirmed | Fixed | Notes |
|----------|-----------|-------|-------|
| P0 | 0 | 0 | none |
| P1 | 0 | 0 | none |
| P2 | 17 (→13 work-items) | 13 | duplicates merged (web-cockpit×4→1, judge×2→1, budget×2→1, config×3→1) |
| P3 | 28 (→14 work-items + 3 from final review) | 17 | doc/spec drift, hardening, test gaps |
| Refuted | 4 | — | rejected with reasons (below) |

## Changes completed

### Correctness fixes
- **`config` conf corruption** — `swarm-run.sh config <k> <v>` escaped sed-active chars (`&|\`) and
  refuses a `"` in the value; guards the missing-value crash. Was: `|` crashed sed, `&` injected
  the matched line, `"` produced an unsourceable `swarm.conf`.
- **Ledger row integrity** — `_ledger_append_row` passes the label via `awk ENVIRON` (was `-v`,
  which escape-processed `\n`/`\` and split the markdown row); `ledger_row` falls back to the spec
  id for `## Criteria` loop-spec banners.
- **No-silent-spend** — `ledger_failed_row` logs the timeout/limit/failover finalize paths (a
  spawned CLI that spent but never finalized), per `rules/unimatrix/model-lanes.md`.
- **judge ≠ executor under failover** — `_check_judge_ne_exec` now rejects a judge lane matching
  *any* `EXEC_CHAIN` entry, not just the head (a failover exec lane could otherwise grade itself).
- **Review sees the diff** — the cross-model review prompt now embeds the worktree `git diff` since
  base (staged, so new files show), not the executor's self-report (spec 03 FR-3, proof-of-action).
- **human_gate resume** — completes against the approved iteration without re-running exec (was
  mutating the human-reviewed worktree before completing).
- **Budget stop rule wired** — sums each iteration's claude/glm `total_cost_usd` into `state.jsonl`;
  `_budget_exceeded` halts on breach (was a permanent `return 1` stub).
- **Stop-rule ordering** — oscillation checked before plateau (an A→B→A flip-flop was mislabeled).
- **Git-reset safety net** — per-iteration `_git_checkpoint` default-on with an explicit throwaway
  identity, never fatal.
- **plan_only / abort** — `plan_only` no longer writes `run.pgid` (`$$`≠pgid); `_drive_pool` clears
  it after the pool; `swarm-ctl abort` liveness-guards the pgid (`kill -0`) before signalling.
- **Orphan sidecars** — `swarm-ctl cancel` / `kill --cancel` clear `.lane`/`.write` sidecars (a
  same-id `add` no longer inherits a stale lane pin or write-access to an old dir).
- **Queue count** — board + `/api/bus` count only `*.prompt` (sidecars no longer inflate the count).
- **tmux firehose** — nullglob + poll-for-first-file (an empty bus at cockpit-start no longer wedges
  the pane); late-new-id limitation documented (web `/api/stream` is the authoritative surface).

### Web cockpit (whole surface was inert/garbled — repaired end-to-end)
- BOARD reads snake_case `stale_leases`/`active_limits` (were always empty).
- COST reads the `{lanes:[{lane,tokens}]}` array (was one bogus "lanes — 0 tok" bar).
- FIREHOSE parses the SSE `{worker,line}` JSON envelope (was rendering raw JSON / mis-splitting).
- **Browser-verified** (Playwright CLI headless, Lane A) against a live server + fixture bus.

### Security improvements
- **DNS-rebinding guard** — `server.mjs` rejects a foreign `Host` header (loopback-only).
- **Caged oracle** — the loop oracle runs under `env -i` + scratch HOME (it executes worker-written
  worktree code; ambient creds/`~/s`/AWS/SSH now out of scope). Documented ceiling: `env -i` does
  not sandbox absolute-path filesystem reads (attended-v1 posture).
- **Gemini docker key out of argv** — FR-16 forwards the key via a bare `-e NAME` allowlist with the
  value in the caged docker-client env (was `-e KEY=value`, exposing the plaintext key in
  `/proc/<pid>/cmdline`). Identical container effect; spec 01 FR-16 + versions.md + tests updated.

### Performance / consistency
- `/api/cost` usage sum aligned to `swarm-mon.sh _cost_summary` (top-level only), so the web COST
  panel and the tmux cost pane can't disagree.

### Maintainability / DX / docs
- `npm run lint` (+ `CLAUDE.md`, `site/agents.md`) now lint all 5 scripts (was `src/*.sh` = 1 file).
- README key-source corrected; CHANGELOG dup `### DOCS` merged + this operation recorded.
- Spec/comment drift fixed: spec 02 FR-7 kill mechanics, spec 01/04 verification-command bats names,
  spec 03 oracle-every-tier + review-sees-diff + stop-rule order, checklist advisory-in-v1, stale
  FR-5/FR-12/FR-16 code comments, budget-stub prose in usage.md.
- Two bats files gained the required structured header; `.playwright-cli` excluded from the deploy;
  stray root-level `run-*.jsonl` test fixtures removed + gitignored.

### Tests
- **+27 tests (160 → 187)**, all red-green (a failing test demonstrating each defect before the fix)
  plus characterization tests locking in previously-unexercised guards (GLM `next_flush_time` TTL
  derivation, criteria-checksum die, review fail-closed, server `/api/cost` codex/gemini +
  `/api/bus` derived fields). No test weakened or removed.

## Final verification (evidence from this operation)

| Check | Command | Result |
|-------|---------|--------|
| Unit/integration | `bats tests/` | **187 pass, 0 fail** |
| Lint / static analysis | `shellcheck -x swarm-run.sh swarm-loop.sh swarm-mon.sh src/swarm-lib.sh src/swarm-ctl` | **clean** |
| JS syntax | `node --check site/server.mjs` | **clean** |
| Build / typecheck / e2e framework | n/a — bash tool, no build/type/e2e stack | — |
| Playwright CLI (Lane A headless) | cockpit.html vs live `server.mjs` + fixture bus | **BOARD/COST/FIREHOSE populate; 0 console errors; degraded-notice path works** |
| Playwright MCP (Lane B, Windows) | — | not run: box policy reserves Lane B for **attended** sessions ("Testing WITHOUT a human → Playwright CLI headless (Lane A), the default"). Equivalent QA performed via the mandated unattended lane. |

Diff hygiene: no skipped/focused tests, no debug artifacts (the one `console.log` in `server.mjs`
is the pre-existing startup listen message), no secrets in the diff, no unexpected generated files
(stray `run-*.jsonl` removed), no disabled checks, no incomplete migrations.

## Final adversarial review

6 fresh-context Opus reviewers over the complete diff (regression-correctness, security,
loop-semantics, bus-cockpit, web-contract, completeness), each finding verified by an independent
skeptic. **3 confirmed** — all doc/comment drift where the code was correct but neighboring prose
was stale (FR-16 `-e` comment, budget-stub text, stop-rule order). All fixed in `84bd51a`. **1
refuted** (`cmd_config` `$(...)` source-injection): pre-existing on `main`, and `swarm.conf` is
operator-authored config sourced into the operator's own shell — no privilege boundary crossed.
No code defect, regression, or unresolved material finding survived review.

## Remaining external blockers / accepted limitations

- **Live-fire lane behavior** (real 429 shapes, real CLI auth, real docker/API round trips) not
  exercised — requires LLM API spend + docker daemon, out of scope for an unattended run. Existing
  live-verified receipts (2026-07-08) remain valid; the docker key-forwarding change is standard
  docker semantics (re-smoke flagged in versions.md for the next gemini-cli bump).
- **Playwright MCP (Lane B) Windows QA** deferred to an attended session per box policy; equivalent
  browser QA done headless (Lane A).
- **Documented ceilings** (not silent): caged oracle doesn't block absolute-path reads; tmux
  firehose doesn't follow ids created after pane start (web cockpit does); stop rules evaluated
  between iterations (a `limit_active` pinned judge could stall an iteration — low frequency).
- **Branch not pushed / not merged** — the user's decision.

## Artifacts

- `plans/refactor-2026-07-12.md` — audit & master plan
- `plans/refactor-progress.md` — live ledger (findings, dispositions, commits)
- `plans/refactor-remediation-2026-07-12.md` — remediation plan (R1–R25 + deferred/refuted)
- `plans/refactor-synthesis-2026-07-12.md` — this file

## Completion conditions

All 53 completion conditions evaluated. Satisfied: branch from `main`, existing work preserved,
architecture mapped, instructions/rules/specs inspected, baseline run+recorded, parallel audits +
adversarial verify, all plan artifacts complete, **all confirmed P0/P1/P2 fixed & verified** (0
P0/P1 existed), P3 with value fixed, lint/static/tests/JS-syntax pass, rules/specs/optimization/
security/simplification reviews with no unresolved material findings, Playwright CLI QA passed,
Playwright MCP documented as attended-only per box policy, diff free of secrets/debug/generated/
disabled-checks/unrelated-changes/incomplete-migrations, every task carries verification evidence,
fresh-context Opus reviews completed and adjudicated by the Fable lead. Blocked conditions: none
(within-repo). External-only: live-fire lane smoke + Lane-B MCP + push/merge, documented above.
