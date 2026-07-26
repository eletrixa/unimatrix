# Spec 08 — Speedwars: per-run lane speed evidence

**Status:** Active (the operator ordered the build 2026-07-19: "lets do /speedwars … put to evidence
every run … Complexity, What agents run, Time, etc. and subjective review how fast was it")
**Date:** 2026-07-19
**Related specs:** 03 (bus), 04 (lanes), 07 (cockpit — future surface)

---

## Overview

Every swarm branch already spends real money/quota on a lane; speedwars makes every one of
those runs a comparable evidence row. One append-only JSONL ledger
(`docs/ops/speedwars.jsonl`) collects: auto-captured per-branch speed/usage rows at finalize,
run-level metadata (complexity rubric, what ran), post-gate verdicts (claimed done vs verified
— the false-done killer), and the operator's subjective speed review. Design grounded in a
2026-07-19 research sweep: aider per-run YAML, terminal-bench FailureMode + trial stats,
SWE-rebench fixed-scaffold token/cost columns, HAL cost-first reporting, SWE-Effi
budget-capped AUC, Artificial Analysis / OpenRouter timing definitions, LMSYS style-control;
per-lane extractable fields verified against the 2026-07-19 cockpit-build bus archives.

## Goals

- Zero-effort capture: a row per finalized branch with no operator action.
- Claimed ≠ verified, stored separately (Harness-Bench/HAL pattern; unimatrix's false-done
  reality — 7 grok false-dones observed 2026-07-19 alone).
- Complexity-stratified comparison (C1–C5 rubric anchored to SWE-bench-Verified time buckets).
- Subjective review beside — never averaged into — the numbers (aider Notes-column pattern).

## Non-Goals

- No daemon, no DB, no new dependency (jq + bash only).
- No Elo/Glicko/Bradley-Terry in v1 — at tens of runs per pairing every rating interval
  overlaps; a W-L table stratified by complexity carries the same information honestly. Fit
  offline BT in a script if pair counts ever reach hundreds.
- No TTFT/turn timing for grok/codex lanes (their event streams carry no timestamps — verified
  unrecoverable) and no queue-wait latency (claim mtime is heartbeat-clobbered; needs
  claim-time stamping first — backlog).
- Rows never carry prompt/task text (privacy + size; the id joins to prompt-<id>.txt).

## Requirements

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-1 | `speed_row()` in src/swarm-lib.sh appends one JSONL row per finalized branch from every `_finalize_worker` outcome: `done`, `timeout`, `lane-unusable`, `retry`, `rate-limited,-failover`. Guarded `2>/dev/null \|\| true` — never fails a run. | Must |
| FR-2 | Row fields: ts, run (`$SPEEDWARS_RUN` else busdir-parent basename), id, requested lane:model, served_lane, served_model, outcome, wrc, pinned, wall_secs (runlog birth→now; retried-id caveat documented) + per-lane usage: tokens in/out/cached/reasoning, cost_usd (claude/glm real-notional, grok notional; codex/gemini absent from envelope), turns, and claude/glm-only duration_ms/duration_api_ms/ttft_ms/is_error/api_error_status; grok stopReason. | Must |
| FR-3 | Env contract: `SPEEDWARS_FILE` (default `<busdir-parent>/docs/ops/speedwars.jsonl` — default path appends only when `docs/ops/` already exists, never scaffolds it into a temp busdir-parent; explicit `SPEEDWARS_FILE` creates its dir), `SPEEDWARS_AUTO=0` disables, `SPEEDWARS_RUN` labels the run. One row = one `write(2)` append. | Must |
| FR-4 | Run-meta rows (`type:"run-meta"`): per-run complexity per card — C1–C5 rubric below, est_human_min bucket, verify_cost enum — written by the orchestrator at seed time. | Must |
| FR-5 | Verdict rows (`type:"verdict"`): after the file-level gate, the orchestrator appends `{run,id,verified:bool,reason}` for any row whose claimed outcome the gate contradicts (false-done) or confirms when it matters. Append-only corrections — never edit prior rows. | Must |
| FR-6 | Review rows (`type:"review"`): subjective speed review per run (optionally per lane): score 1–5 anchored (1 unusable · 2 needed rescue · 3 did the job · 4 beats cost peers · 5 promote in EXEC_CHAIN), tags from the fixed vocab {flaky, thorough, verbose, terse, fast, slow, hallucinated, ignored-instructions, over-eager, good-value, false-done}, note ≤140 chars. Skipping is data (unremarkable). | Must |
| FR-7 | `/speedwars` reader (`.claude/commands/speedwars.md` + `src/speedwars-report.sh`): per-lane table stratified by complexity — n, done vs false-done vs failed counts, median + p95 wall_secs, median tokens_out/s where derivable, $ per verified-done; split every average by verified-pass vs fail (SWE-Effi "expensive failures"); medians never means. | Must |
| FR-8 | bats coverage: speed_row row shape per lane fixture (grok end-event, claude/glm result-event, codex turn.completed, gemini stats), outcome mapping, SPEEDWARS_AUTO=0 silence. | Must |
| FR-9 | Backfill of the 2026-07-19 cockpit-build archive (`.bus/archive/2026-07-19-cockpit-build/`) into the ledger with wall_secs from the per-wave speed.csv (archive copies lost birth times). | Should |
| FR-10 | Claim-time stamping (`queue-wait` + `claim→spawn` latency) — requires touching `_try_claim_one`; do not build without a fresh look at FR-14 fencing. | Should (backlog) |

## Complexity rubric (run-meta `complexity`)

Anchored to SWE-bench-Verified human-time buckets; score = the HIGHEST level any dimension
hits. C1 trivial (<15 min human: 1 file, ≤10-line diff, mechanical). C2 simple (15–60 min:
1-2 files, ≤50 lines, known pattern, no design choices). C3 moderate (1–4 h: 2-3 files,
50–150 lines, one judgment call, needs a new test). C4 complex (half-day+: 3+ files or
cross-cutting, 150–500 lines, design decisions, new tests + manual run). C5 open-ended
(>1 day: architecture-level, success criteria need defining — /swarm-loop territory).
Expect lane divergence only at C3+ (that's where racing lanes is worth double spend).

## Design

Capture point: `_finalize_worker` in swarm-run.sh — the only choke point where the requested
lane:model, real wrc, and pin flag are still in scope (done markers hardcode `code:0`; the
`.lane` sidecar dies on success). Per-lane terminal-event paths (verified against real
archives): claude/glm = last `type:"result"`, grok = last `type:"end"` (stopReason
"Cancelled" appears on SUCCESSFUL grok runs — never treat it as failure), codex = last
`type:"turn.completed"` (no cost/model/timestamps in envelope), gemini = last `type:"result"`
`.stats`. Wall clock = `stat -c %W run-<id>.jsonl` → now; on a retried id the birth is the
first attempt's spawn while usage is the last attempt's (tee reuses the inode) — documented,
accepted for v1.

## Boundaries

- **Always**: append-only; one write(2) per row; verdict rows for every gate-contradicted
  claim; run-meta before or at seed time.
- **Ask first**: schema changes to existing row fields; adding capture beyond finalize
  (claim-time stamping — FR-10); any rating-system math.
- **Never**: block or fail a run on speedwars errors; store prompt/task text or handoff bodies
  in rows; average subjective scores into objective columns; bare means in reports.

## Acceptance Criteria

- [ ] FR-1..3: live rows observed from real runs (zora-w0 + cockpit-w5, 2026-07-19) ✓ shipped v0
- [ ] FR-4/5: run-meta + verdict rows present for zora-w0 (incl. 3 grok false-done verdicts)
- [ ] FR-6: at least one review row after a completed run
- [ ] FR-7: /speedwars renders the stratified table from the live ledger
- [ ] FR-8: bats green (`bats tests/swarm-lib.bats`)
- [ ] Verification: `jq -s 'map(select(.type==null)) | length' docs/ops/speedwars.jsonl` grows
      by exactly the number of finalized branches in any new run

## Dependencies

specs 03/04 (bus + lane envelopes); jq ≥1.6; bash ≥5.1. No new external dependencies.

## Amendment — 2026-07-25 (P0-FR7: one canonical verdict-fold; plan 004 phase 0)

Two fold implementations existed (this report's jq and the cockpit client's `speed.js`) and
disagreed on five axes. The canonical semantics now live in **`tests/fixtures/verdict-fold/README.md`**
(numbered rules) with one shared contract fixture both renderers replay in tests — divergence turns
a test red. Where this amendment contradicts FR-7's original text, the amendment wins:

- **Verdict join key is `run/id`** (FR-5's own schema — verdict rows carry no executor lane;
  `verify_lane` names the verifier, spec 10 FR-R9). The report's old lane-scoped join dropped
  lane-less verdicts, silently un-refuting them.
- **Unjudged ≠ verified.** A done-claim with no verdict row is UNJUDGED — never counted verified,
  never in the $/verified-done denominator (spec 09 FR-7 doctrine; absence of a verdict means
  nobody judged).
- **Unit is the card (run+id), not the attempt row**; lane credit goes to the final attempt
  (latest ts; a ts-less attempt loses the tie-break).
- **Per-lane table columns now:** ATTEMPTS / CARDS / VDONE / FALSE-DONE / UNJUDGED / FAIL /
  median + p95 wall / median tok-out/s / $/VDONE — superseding FR-7's "n, done vs false-done vs
  failed" list.
- **$ per verified-done = the lane's ENTIRE bill (failed and unjudged attempts included) ÷
  verified-done count** — expensive failures priced in (SWE-Effi), superseding the old
  verified-rows-only numerator. Medians never means, unchanged.
- `src/speedwars-report.sh --json` emits the canonical per-lane aggregates (the exact shape the
  contract fixture pins) for machine consumers.

## Amendment — 2026-07-25 (P0-FR1 follow-up: run-label resolution & persistence)

FR-1's run-join key (`.run`) was derived fresh at every hop and persisted nowhere. Two consequences
in live evidence: every sibling bus in one checkout (`.bus`, `.bus-gtm-a`, `.bus-tok024`, ...)
derived the SAME label from the checkout's directory name and folded into one ledger run; and a
later `swarm-ctl review-stub` from a fresh shell re-derived a different label than the run had used
and harvested a foreign run's rows. Where this amendment contradicts FR-1's original text, the
amendment wins. FR-2/FR-3 row schemas are unchanged.

**Resolution order** (`_run_label`, `src/swarm-lib.sh` — still the ONE derivation every writer calls):

1. `$SPEEDWARS_RUN` — the operator/run override, always first.
2. `$BUSDIR/.run-label` — the label this bus's last run pinned. Written at run start ONLY
   (`_run_label_persist`, immediately after `bus_init` in `full_run` / `verify_run` / `cmd_call`);
   overwritten each run, so the latest run owns the bus.
3. Derived default: a busdir named `.bus-<suffix>` yields `<suffix>`; anything else (the plain
   `.bus` layout) yields the busdir's PARENT basename — the pre-amendment value, so existing rows
   stay joinable.

**Warning discipline.** The derived-default path prints ONE stderr line per process, naming the real
hazard (sibling buses sharing a ledger run key, so a later harvest folds their rows together) and
the `$SPEEDWARS_RUN` override. The old once-per-bus-LIFETIME marker file (`.run-label-warned`) is
removed: read-only callers must not write into a bus at all, and it silenced every run after the
first on a reused bus.

**Consumers.** `speed_row`, `run_summary`, `feedback_stubs`, `swarm-ctl review-stub` and
`swarm-run.sh`'s `call` aggregate ledger row all resolve through `_run_label`. An unresolvable label
prints `n/a` in the aggregate row and skips the cost sum — never a real-looking `$0`.
