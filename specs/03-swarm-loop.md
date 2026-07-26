# Swarm Loop — `/swarm-loop`

**Status:** Active
**Date:** 2026-07-08
**Related specs:** [01-swarm-core](./01-swarm-core.md), [04-settings](./04-settings.md)

---

## Overview

`/swarm-loop` is the second operating mode: define success criteria once, then iterate — exec,
oracle, cross-model review, adjudicate — until the criteria are genuinely met or a stop rule
fires. It reuses `/swarm`'s wave machinery (fresh headless spawn per role, file-bus state, atomic
claim) run repeatedly with an accumulating state file, rather than introducing new coordination
primitives. The design synthesizes Boris Cherny's loop principles, the Ralph Wiggum technique and
its community fixes, the `loop-engineer` skill, and the operator's own loop-engineering course chapter
(`LOOP.md` §1, full digest in `research/loop-research.md`).

The one non-negotiable structural rule: **judge ≠ executor.** Models reliably overrate their own
output, so the reviewer role is always a different lane than the one that produced the diff.

## Goals

1. A written, worker-immutable done-condition (`criteria.md`) that exists before iteration 1 —
   never a self-graded promise string.
2. Every iteration is independently verified by a non-executor lane before being counted as
   progress.
3. Every halt — goal or non-goal — is honest: state.jsonl plus, on non-goal halts, a `HALTED.md`
   naming which rule fired and what was tried.

## Non-Goals

- Not `/goal` (single-session, single-model, Haiku-evaluator, no cross-model review) — right tool
  for in-session polish, wrong chassis for multi-model loops.
- Not the Ralph Stop-hook shape — couples the loop to session lifecycle, exits on a self-graded
  promise string; both are what this design avoids.
- No unattended/cron driver in v1 — Fable drives every iteration directly; the headless
  `swarm-loop.sh` while-loop form is gated on Phase 2 containment, same as `/swarm`.
- No measurement-lag scraper in v1 — the state schema reserves a `score` field so it bolts on
  later without migration.

---

## Requirements

### Criteria contract (`.bus/loop/<run>/criteria.md`, written before iteration 1, read-only to workers)

| Field | Meaning |
|-------|---------|
| `goal` | one sentence |
| `tier` | 1-5, the verification ladder, declared honestly — **recorded, not branched on**: the shipped design runs oracle + judge review at EVERY tier (LOOP.md's iron rule beats tier-conditional review; amended 2026-07-08) |
| `oracle` | **mandatory at every tier** — the deterministic check command; a tier with no real deterministic check uses `true` as placeholder (review then carries the verification) |
| `judge` | the LLM-judge lane, runs whenever the oracle is green — **must differ from the exec lane** (enforced loudly at init and per-iteration; amended by spec 10 §Amendment: a collision auto-substitutes the first qualified `CLASS_REVIEW` member with a loud warning, and only refuses when none qualifies) |
| `human_gate` | tier 5 or rung-0/1 (never done manually before) → `true`, makes the loop attended |
| `invariants` | things that must stay true across iterations (e.g. "no other test file modified") |
| `checklist` | feature list, every item starts `[FAILING]`. **Advisory in v1**: fed to exec/review as context to steer the work — there is no per-item auto-marking mechanism, so the machine goal gate is `oracle green + review pass` (below), not per-item `[PASSING]`. Human-readable success list, not a separate machine gate. |
| `stops` | `{max_iterations, budget_usd, plateau, wall_clock_h}` |

### Functional

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-1 | `/swarm-loop "<goal>" --until "<criteria>"` (one-shot) or bare `/swarm-loop` (plan-first: Fable interviews per maturity rung + verification tier, then writes the contract). | Must |
| FR-2 | If success is genuinely undefinable even for a human, Fable refuses to start the loop and says so. | Must |
| FR-3 | One iteration = plan one increment (Fable) → exec (fresh spawn, exec chain) → oracle (deterministic, **run at every tier** — a tier with no real check uses `true`; amended 2026-07-08, matches the criteria table above) → review (codex, fresh spawn, sees the worktree **diff** + criteria + oracle output, executor answer as context only) → Fable adjudicates → `state.jsonl` append + git commit (per-iteration, default-on). | Must |
| FR-4 | `criteria.md` is never edited after being written; `steering.md` accrues review findings and learned rules across iterations (fix-or-defend, not blind-obey). | Must |
| FR-5 | The exec worker must supply command output/diff evidence for its increment; "done" is never taken on the executor's assertion alone. | Must |
| FR-6 | All stop rules are active simultaneously; first to fire wins (table below). | Must |
| FR-7 | Any non-goal halt writes `.bus/loop/<run>/HALTED.md` naming the rule, what was tried, and a suggested next move. | Must |
| FR-8 | Code-editing loops run in a scratch git worktree so a `git reset --hard` recovery never touches the main tree. | Should |

### Stop rules

| Rule | Trigger |
|------|---------|
| Goal hit | oracle green + reviewer pass, judged by the non-executor (checklist is advisory context in v1, not a separate machine gate — see the criteria table's `checklist` row) |
| Oscillation | same oracle-output signature flip-flops across iterations (A→B→A) — **checked before plateau** (the more specific condition; else plateau's "no progress" window shadows it at `plateau` ≤ 3) |
| Plateau | `plateau` (default 3) iterations with no oracle_rc/review progress |
| Iteration cap | `max_iterations` (default 10) |
| Budget cap | cumulative cost (per-iteration claude/glm `total_cost_usd` summed from `state.jsonl`; other lanes contribute 0) exceeds `budget_usd` (`0` = no cap) |
| Wall clock | `wall_clock_h` exceeded |
| Human abort | `.bus/PAUSE` / `swarm-ctl abort` / Esc in the Fable session |

---

## Design

```
.bus/loop/<run-id>/
├── criteria.md     # contract — written first, never edited by workers
├── steering.md     # accumulated review findings + learned rules (grows)
├── state.jsonl     # one line per iteration: tried/oracle/review/cost/files/score
├── HALTED.md        # only on non-goal halt
└── iter-<N>/        # per-iteration specs + res files (standard bus naming, 01-swarm-core.md)
```

Monitor integration: the cockpit board gains one line — `LOOP iter 4/10 · oracle FAIL(2) ·
plateau 1/3 · $3.20/$10` — read from `state.jsonl` (`02-cockpit.md`).

---

## Boundaries

- **Always**: write `criteria.md` before touching the exec chain; route review to a lane
  different from the exec chain's current lane; commit per iteration.
- **Ask first**: starting a loop at tier 5 or maturity rung 0-1 without a human gate; raising
  `max_iterations`/`budget_usd` mid-run.
- **Never**: let a worker modify `criteria.md`; treat an executor's self-report as the completion
  signal; run the headless (unattended) loop driver before Phase 2 containment ships.

---

## Acceptance Criteria

- [ ] **Toy tier-1 loop:** seed a failing test as the goal; the loop iterates, the oracle goes
      green, checklist reaches all `[PASSING]`, and the loop stops on "goal hit" with a
      non-executor judgment.
- [ ] **Impossible-goal loop:** an intentionally undefinable/unreachable goal halts via plateau or
      the iteration cap, writing an honest `HALTED.md` that names the rule that fired — never a
      fabricated success.
- [ ] **Criteria immutability:** an exec worker's attempt to write to `criteria.md` mid-run is
      detected (write fails or is flagged by a checksum/diff check before adjudication) — the
      contract is provably unchanged from what was written before iteration 1.
- [ ] Judge ≠ executor is enforced structurally: a run where the configured review lane equals
      the current exec lane refuses to start (or reroutes) rather than silently self-reviewing.

**Verification commands:**
```bash
bats tests/swarm-loop.bats
```

---

## Open Questions

None.

---

## Dependencies

**Internal:** `LOOP.md` (full spec — condensed here), `research/loop-research.md`,
`01-swarm-core.md` (wave machinery, bus mechanics, gate), `04-settings.md` (`EXEC_CHAIN`,
`MAX_ITERATIONS`, `BUDGET_USD`).
**External:** none beyond the lanes already required by `01-swarm-core.md`.
