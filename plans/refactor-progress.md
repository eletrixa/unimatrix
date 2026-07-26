# Refactor Progress Ledger — 2026-07-12

**Status: archived scratch note (2026-07-12)** — superseded by shipped specs; kept for history.

Operation branch: `refactor/2026-07-12-autonomous-codebase-cleanup` (base `a1aa7c5`).
Statuses: discovered → validating → validated/rejected/superseded → planned → in progress →
fixed → reviewing → verified. Blocked tasks carry the exact blocker.

## Phase 0 — setup (done)

- Working tree clean at start; no stash created (nothing to preserve).
- Accidental transient branch `refactor/2026-07-12-autonomous-codebaseup` (typo) was created
  empty at `a1aa7c5` and deleted seconds later — never contained work.
- Branch `refactor/2026-07-12-autonomous-codebase-cleanup` created from local `main` @ `a1aa7c5`.
- Local `main` is 3 commits ahead of `origin/main` (a1aa7c5 vs 4ea5a14); fetch performed; nothing to fast-forward.

## Phase 1 — baseline (done)

- `bats tests/` → 160/160 ok (exit 0).
- `shellcheck -x src/swarm-lib.sh src/swarm-ctl swarm-run.sh swarm-loop.sh swarm-mon.sh` → clean.
- Sources of truth read by lead: CLAUDE.md (global+project), rules/_index + rules/unimatrix/*
  (bus-discipline, model-lanes, loop-discipline), specs/README + implementation files
  (swarm-lib.sh, swarm-run.sh, swarm-loop.sh, swarm-ctl, swarm-mon.sh, swarm.conf).

## Phase 1 — parallel audit (in progress)

10 Opus 4.8 read-only auditors launched via Workflow. Findings adjudicated by Fable lead
land in the Task table below.

## Task ledger

Lead-confirmed (independently reproduced by Fable with concrete failing evidence, before/besides
the audit fleet):

| ID | Pri | Category | Description | Status | Files | Evidence |
|----|-----|----------|-------------|--------|-------|----------|
| T1 | P2 | correctness/security | `swarm-run.sh config <KEY> <val>` uses `sed s\|…\|…\|` with an unescaped replacement — a value containing `\|` crashes sed (rc1, no write), `&` injects the whole matched line, `"` corrupts the line; result breaks `conf_load`'s `source swarm.conf`. | validated | swarm-run.sh:88-92 | reproduced: `config EXEC_CHAIN 'a\|b'`→sed error; `'a & b'`→line mangled; `config`→`source: command not found` |
| T2 | P2 | correctness/security | `swarm-ctl cancel <id>` / `kill --cancel` move only `<id>.prompt`, orphaning `<id>.lane`/`<id>.write` sidecars in `queue/`. A later `add` of the same id silently inherits the stale lane-pin AND write-access to the old target dir. | validated | src/swarm-ctl:41-52,86-108 | reproduced: cancel leaves `foo.lane`+`foo.write`; re-add inherits `gemini:…` pin + `/some/secret/dir` write |
| T3 | P2 | correctness/DX | `ledger_row` derives the "What" label from the prompt file's first line; for loop-generated specs that is always `## Criteria (read-only contract…)`. Documented backlog in CHANGELOG; auto-rows were hand-curated to work around it. Fixable now: fall back to spec id when the first line starts with `#`. | validated | src/swarm-lib.sh:759-765 | CHANGELOG "Auto-ledger label bug (backlog)"; code path confirmed |
| T4 | P3 | DX | `npm run lint` = `shellcheck -x src/*.sh` covers only `swarm-lib.sh` — misses `swarm-run.sh`, `swarm-loop.sh`, `swarm-mon.sh`, and `src/swarm-ctl` (no `.sh`). README badge claims "5 scripts shellcheck-clean" but the script only checks one. | validated | package.json:8 | shellcheck run manually covers all 5; npm script does not |
| T5 | P3 | correctness | `plan_only` writes `echo "$$" > run.pgid`; `$$` is the script PID, not a pgid, and plan_only spawns no pool. A later `swarm-ctl abort` does `kill -- -$$` (dead PID → pid-reuse risk on an innocent group). | validated | swarm-run.sh:66 | plan_only exits immediately; run.pgid left stale/meaningless |
| T6 | P3 | docs | CHANGELOG `[Unreleased]` has two separate `### DOCS` subsections (should be one). | validated | CHANGELOG.md:16,22 | two `### DOCS` headers under one Unreleased |

### Fleet-sourced findings — adjudicated & remediated

10-dimension Opus audit + adversarial verify (59 agents): 45 confirmed (17 P2, 28 P3), 4 refuted.
Deduped into remediation IDs R1–R25 (see `plans/refactor-remediation-2026-07-12.md`). Disposition:

| R# | Pri | Fix (all `verified`: red-green + full-suite + shellcheck; browser QA where applicable) | Commit |
|----|-----|------|--------|
| R1 | P2 | config sed-escape + quote-refusal + missing-arg guard | a69eb67 |
| R2 | P2 | ledger awk ENVIRON (no escape-processing) | a69eb67 |
| R3 | P2 | ledger label falls back to spec id for `#` prompts | a69eb67 |
| R4 | P2 | no-silent-spend: ledger_failed_row on timeout/limit/failover | a69eb67 |
| R5/R7-judge | P2 | judge≠executor vs whole EXEC_CHAIN | 9219c6c |
| R6 | P2 | review sees worktree diff, not self-report | 9219c6c |
| R7-humangate | P2 | human_gate resume completes without re-iterating | 9219c6c |
| R8 | P2 | oracle runs caged (env -i + scratch HOME) | 9219c6c |
| R9 | P2 | budget stop wired (sum claude/glm total_cost_usd) | 9219c6c |
| R10 | P2 | web cockpit BOARD/COST/FIREHOSE match server shapes | 519e5c2 |
| R11 | P2 | tmux firehose nullglob + poll-first (+ documented late-id limit) | 519e5c2 |
| R12 | P2/P3 | plan_only no run.pgid; _drive_pool clears it; abort liveness-guard | a69eb67, 519e5c2 |
| R13 | P2 | lint covers all 5 scripts (package.json/CLAUDE.md/agents.md) | 211788e |
| R14 | P3 | cancel/kill --cancel clear .lane/.write sidecars | 519e5c2 |
| R15 | P3 | queued count only *.prompt (board + /api/bus) | 519e5c2 |
| R16 | P3 | git checkpoint default-on + explicit identity + non-fatal | 9219c6c |
| R17 | P3 | oscillation checked before plateau | 9219c6c |
| R18 | P3 | bats file headers (cockpit + ground-control) | 211788e |
| R19 | P3 | .assetsignore excludes .playwright-cli | 211788e |
| R20 | P3 | server.mjs Host-header (DNS-rebind) guard | 519e5c2 |
| R21 | P3 | README key-source corrected ($ENV_MASTER_FILE) | 211788e |
| R22 | P3 | CHANGELOG dup ### DOCS merged | 211788e |
| R23 | P3 | spec/comment drift (02 FR-7, 01/04 bats names, 03 tiers, FR-5/FR-12 comments) | 211788e |
| R24 | P3 | checklist documented advisory-in-v1 | 211788e |
| R24-docker | P3 | gemini docker key via bare -e (out of /proc argv) | d3d1c0b |
| R25 | P3 | characterization tests (GLM TTL, criteria die, review fail-closed, server cost/bus) | d3d1c0b |
| R41 | P3 | /api/cost aligned to _cost_summary top-level sum | 519e5c2 |
| — | — | stray run-*.jsonl fixtures removed + gitignored | d91c516 |

Refuted (rejected, agree): LOOP_GOAL newline shadowing; env -i not blocking absolute-path reads
(folded into R8's documented ceiling); stale-finalize shared-log write (documented FR-14 backlog);
fakes-omit-envelopes (contradicted by code). Deferred-and-documented: stop-rules-between-iterations
pinned-judge stall (P3, requires limit_active judge lane — noted).

Verification: `bats tests/` 187/187 pass; `shellcheck -x` (all 5 scripts) clean; `node --check
site/server.mjs` clean. Browser QA (Playwright CLI headless, Lane A): cockpit BOARD/COST/FIREHOSE
populate correctly against a live server+fixture bus, 0 console errors, degraded-notice path works.

## Second pass — fresh-eyes audit (2026-07-12, post-remediation review)

8 fresh Opus finders (simplification ×2, correctness, concurrency/bus, web-cockpit, test-quality,
security, consolidation), 13 raw findings, each adversarially verified (21 agents total).
11 confirmed / 2 refuted. Adjudicated by Fable lead: 6 fixed, 5 confirmed-but-skipped
(verifier-rated not worth diff churn — chain-prologue dedup, envbase rewrite,
criteria_field/stop merge, env-cage centralization, `_last_event` jq-idiom dedup: all
line-neutral or adding regression surface on sensitive paths).

| ID | Pri | Fix | Commit |
|----|-----|-----|--------|
| R26 | P2 | bounded same-lane retry (`MAX_LANE_RETRIES=3`, counter `.retries-<id>`, cleared on chain_advance/chain_reset) — was an unbounded respawn/spend loop that also bypassed every `/swarm-loop` stop rule | (this pass) |
| R27 | P2 | /api/stream advances only past complete lines — mid-write records no longer split into permanent fragments | (this pass) |
| R28 | P3 | /api/stream resets cursor on file truncation (same-id failover re-run via `tee`) | (this pass) |
| R29 | P3 | `_ledger_lane_fields` dedups the lane→provider/billed mapping out of ledger_row/ledger_failed_row | (this pass) |
| R30 | P3 | board test assertions pin count digits to their labels (regex, was anywhere-in-line globs) | (this pass) |
| R31 | P3 | caged-oracle test also asserts the canary landed in the cage (positive proof the oracle ran) | (this pass) |

Refuted (agree): FR-14 fencing-token inode claim (headline defect wrong — heartbeat, not the
token, is the live-worker guard; only the comment nuance stands, and the proposed "fix" would
regress the working `-z` path check); scratch-home credential copies as a NEW exfiltration
surface (env -i scrubs env, not the filesystem — same-UID workers can already read the originals;
the real gate is FR-16 docker, which ships and is documented policy).

Verification (second pass): `bats tests/` **191/191** pass (187 + 2 retry-cap + 2 SSE);
`shellcheck -x` all 5 scripts clean; `node --check site/server.mjs` clean.

## Commands run (milestones)

- 2026-07-12: `bats tests/` (baseline) — 160 ok.
- 2026-07-12: `shellcheck -x` all five shell entry points — clean.
- 2026-07-12 (second pass): 4 RED tests demonstrated (retry-cap hang rc124, SSE split, SSE
  truncation, retry-cap failover) → all GREEN post-fix; full suite 191 ok.
