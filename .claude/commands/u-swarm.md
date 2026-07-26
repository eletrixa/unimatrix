---
description: Fan a question out to headless multi-model workers over the file-bus and adjudicate the results
argument-hint: "<question>"
---

# /u-swarm

**Deprecated** (spec 17 FR-8): `/u-swarm` is deprecated in favor of `/u:swarm`; body stays
canonical here. `/u-swarm` is deleted next release — `/swarm` (below) and `/u:swarm` both keep
working.

Canonical body for the `/swarm` slash command (spec 16 FR-5) — `/swarm` is now a 2-line alias
pointing here.

You (Fable) are the plan/orchestrator role for this run — per `specs/01-swarm-core.md` and
`specs/04-settings.md`. Read both specs before acting; this file only states the invocation
contract, not the engine design.

## Mode 1 — one-shot: `/swarm "<question>"`

1. Decompose `$ARGUMENTS` into independent branches (2-`FANOUT` per `swarm.conf`). Effort scales
   by stated rule, never by feel (uncontrolled spawn depth is the documented #1 orchestrator
   failure): simple factual question = 1-2 branches; comparison/multi-angle = 2-4; genuinely
   broad research = up to `FANOUT`.
2. Write each branch as its own prompt **file** at `.bus/specs/<id>.prompt` — never interpolate a
   branch into a shell string, a `send-keys` stream, or this conversation. One file per branch.
3. Run `./swarm-run.sh` to initialize the bus and fan the branches out to their lanes.
4. Wait for the completeness gate (`done/` count == live spec count) before reading any answer.
5. Run `./swarm-run.sh verify` — the cross-model verify wave (judge ≠ executor via `VERIFY_MAP` in
   `swarm.conf`, PRD §4 step 7); wait for its own gate before reading `res-v-*.txt`.
6. Read each answer + its verify verdict (never `run-<id>.jsonl` prose), adjudicate, and
   synthesize — only after every live branch AND its verifier has landed.

## Mode 2 — plan-first: bare `/swarm`

If this session already agreed on a decomposition earlier in the conversation, convert those
agreed branches directly into `.bus/specs/<id>.prompt` files and continue at step 3 above. Do not
re-decompose from scratch.

## Research branches

A branch that needs full web research runs its OWN deep-research pass **inside** its worker — the
fan-out stays inside that one CLI process, one bus file, one `done/` marker (`PRD.md` §8). Say so
explicitly in its prompt file ("run your own deep-research workflow — search, fetch, verify —
before answering") and pin it to a `claude:<model>` lane via the `<id>.lane` sidecar: only
claude's bundled Workflow does this, never `gemini`/`codex`/`glm`.

## Judge preflight (spec 10)

Before the verify wave, run `/swarm config` and read the `CLASS_REVIEW:` live-state line
(FR-R13 — `codex(available) kimi(limited 4m)` / `(dead)`). A limited primary judge auto-falls
back along the class chain; a fully exhausted class parks loudly and never demotes — plan the
wave accordingly instead of discovering a parked review mid-run.

## Succession (spec 11)

- On every gate/poll of a long run, `src/swarm-ctl heartbeat` — a stale heartbeat is what the
  takeover watchdog keys on. Arm/disarm the watchdog per run: `watchdog-arm` at start,
  `watchdog-disarm` at close (disarm is mandatory cleanup, normal or degraded).
- If you resume a bus and `orch-seat` is non-fable: a continuation driver acted here. Every
  `degraded:true` row is provisional — re-audit first (diff the scratch worktree, re-run gates,
  confirm/re-open verdicts per `loop/handoff-degraded.md`) before planning any new wave.

## Hard rules (non-negotiable, see `specs/01-swarm-core.md` Boundaries)

- Prompts travel as **files only** — never as shell-interpolated strings or keystrokes.
- **No synthesis before the gate.** A partial result set is never adjudicated, ever.
- Every spawned run gets a line in `docs/ops/llm-runs.md` (lane, cost, why any failover fired) —
  no silent spend. Automatic on success (`LEDGER_AUTO=1`, `swarm.conf`) — disable only for tests.
- Judge ≠ executor: `REVIEW` (per-run) and the verify wave's `VERIFY_MAP` (per-branch) both must
  differ from the lane that produced the answer being audited.
- Identity masking (spec 10 FR-R4): review/verify prompts you write must never name which lane
  authored the answer under review — same-family judge bias is measured and real.
- Review never lands on the card's author or its model family — the engine enforces it
  (`_judge_ok`); Fable-written ad-hoc review cards must honor it too.

## Config

`/swarm config` prints the fully resolved role/lane table (`swarm.conf` merged over defaults,
per-run flags win). `/swarm config <key> <value>` edits `swarm.conf` in place.
