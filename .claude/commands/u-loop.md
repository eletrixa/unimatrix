---
description: Iterate exec -> oracle -> cross-model review until success criteria genuinely hold, or a stop rule fires
argument-hint: "<goal>" --until "<criteria>"
---

# /u-loop

**Deprecated** (spec 17 FR-8): `/u-loop` is deprecated in favor of `/u:loop`; body stays canonical
here. `/u-loop` is deleted next release — `/swarm-loop` (below) and `/u:loop` both keep working.

Canonical body for the `/swarm-loop` slash command (spec 16 FR-5) — `/swarm-loop` is now a 2-line
alias pointing here.

You (Fable) plan and adjudicate every iteration — per `specs/03-swarm-loop.md` and
`plans/001-multimodel-orchestration/LOOP.md`. Read both before acting; this file only states the
invocation contract, not the engine design. The driver is `swarm-loop.sh` (`init`/`iterate`/`run`).

## Interview first (per `rules/unimatrix/loop-discipline.md`)

Before calling `init`, negotiate the criteria contract honestly:
1. **Maturity rung** — has this task ever been done manually? Rung 0-1 needs a validation gate as
   iteration 1 (`LOOP_HUMAN_GATE=true`).
2. **Verification tier (1-5)** — tiers 1-3 lean on a deterministic `LOOP_ORACLE` command; tier 4
   still gets one (set it to `true` if there's no real smoke check) but the `LOOP_JUDGE` lane
   carries the substantive verdict; tier 5 is `LOOP_HUMAN_GATE=true` (attended only).
3. **Judge != executor** — `LOOP_JUDGE`'s lane must differ from every `EXEC_CHAIN` lane. A
   collision no longer refuses outright: the script auto-substitutes the first qualified
   `CLASS_REVIEW` member (loud stderr) and refuses only when the whole class is disqualified
   (spec 10 §Amendment). Name the intended judge at interview time AND glance at
   `.bus/limits/*.{limited,dead}` (or the `/swarm config` class-state line) — a parked-judge
   surprise should be planned for, not discovered.
3b. **Cheapest-capable exec** — pick the cheapest exec lane you are ≥90% confident lands the
   goal and name its escalation rung up front (pre-generation routing). Escalation between
   iterations is justified ONLY by execution feedback (oracle red, diff-gate reject, reviewer
   refutation) — never by asking a lane how confident it is (spec 10 FR-R14).
4. **If success is genuinely undefinable, even for a human — refuse to start the loop and say so.**
   This is your judgment call, not something the script can detect.

## Invocation

```
/swarm-loop "<goal>" --until "<criteria>"     # one-shot: interview compresses into one turn
/swarm-loop                                    # plan-first: interview happens in-session first
```

Both forms end the same way:
```bash
LOOP_GOAL="<goal>" LOOP_TIER=<1-5> LOOP_ORACLE="<cmd>" LOOP_JUDGE="<lane:model>" \
  LOOP_HUMAN_GATE=<true|false> LOOP_CHECKLIST="$(printf '%s\n' "item one" "item two")" \
  TARGET_DIR="<path>" ./swarm-loop.sh init <run-id>
./swarm-loop.sh run <run-id>
```

`run` iterates until goal/plateau/oscillation/max_iterations/budget/wall_clock/human_abort fires
(exit 0 = goal, 2 = halted, 1 = error) — report from `.bus/loop/<run-id>/{COMPLETE.md,HALTED.md}`
and the tail of `state.jsonl`, never from your own memory of what happened.

## Hard rules (non-negotiable, see specs/03 Boundaries)

- `criteria.md` is written once and never edited again — not by you, not by a worker.
- Never take "done" on the executor's own assertion — oracle green + reviewer pass are the signal.
- Review verdicts are consumed by jq joins, not read as essays: demand a one-line
  `VERDICT: pass|findings` head plus short rationale in the criteria contract — answer length is
  not quality (verbosity bias is measured and real).
- Every spawned run gets a line in `docs/ops/llm-runs.md` — no silent spend.
- Do not run the unattended (headless, cron-able) form before Phase 2 containment ships — this
  session drives every `run` interactively, same as `/swarm`. The one sanctioned standing
  trigger is spec 11's takeover watchdog (one tagged crontab line, armed per run, provably
  disarmed at close).
- Succession (spec 11): touch `swarm-ctl heartbeat` at every gate; a takeover seats kimi as a
  **bounded continuation driver** (finish waves, run gates, park ambiguity — no new scope, no
  spec lifecycle changes, no pushes, no destructive ops). Its work lands `degraded:true` and
  stays provisional until Fable's re-audit clears `loop/handoff-degraded.md`.
