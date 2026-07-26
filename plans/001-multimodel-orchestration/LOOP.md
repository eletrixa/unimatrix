# `/swarm-loop` — iterate until success criteria hold

Design spec (documentation phase — no code). Second operating mode beside `/swarm`:
define success criteria, and the agents work until the criteria are genuinely met or a stop
rule fires. Fable orchestrates and plans, **codex (GPT newest) reviews every iteration**,
execution runs on the exec chain (**Opus → GLM-5.2 on limit**, per `SETTINGS.md`).

Sources synthesized: Boris Cherny's loop principles + official Claude Code best practices,
the Ralph Wiggum technique and its community fixes, the `loop-engineer` skill's method, and
your own loop-engineering course notes. *(Raw research artifacts kept out of the public tree.)*

---

## 1. The five design laws (non-negotiable, source-backed)

1. **Verification is the loop.** "Give the model a way to verify its work" is Cherny's #1
   principle (worth 2-3× quality, and what makes long unattended runs possible). A loop
   without a real check is a token furnace.
2. **The done-condition is written BEFORE the run, in a file the agents cannot redefine.**
   Anthropic's harness marks every feature "failing" up front; done = criteria pass, never
   "code written". Promise-strings alone are explicitly insufficient (ralph plugin's own docs).
3. **Judge ≠ executor. Iron rule.** Models reliably overrate their own output. Our default
   makes this structural: codex reviews what Opus/GLM produced. (This is the same principle
   as the PRD's cross-model verify wave — the loop is that principle applied over time.)
4. **Fresh context per iteration; memory in files + git.** The unanimous convergence point
   (Ralph, Anthropic harness posts, Osmani). Our architecture gets this free: every worker
   is a fresh headless spawn; state lives on the bus; each iteration commits.
5. **Caps are insurance, not strategy.** Iteration cap + budget cap always present, whatever
   the criteria. `/goal`'s Stop hook force-exits after 8 consecutive blocks for a reason.

## 2. Invocation

```
/swarm-loop "<goal>" --until "<criteria>"        # one-shot form
/swarm-loop                                       # plan-first: criteria negotiated in-session, then loop
```

Plan-first is the default for anything non-trivial: Fable interviews per the `loop-engineer`
method — **maturity rung** (has this task ever been done manually? rung 0-1 gets a validation
gate as iteration 1) and **verification tier** — then writes the criteria contract and starts.

**Criteria contract** — `.bus/loop/<run>/criteria.md`, written before iteration 1, read-only
to workers (Anthropic pattern: features initialized "failing"):

```markdown
goal: <one sentence>
tier: 1|2|3|4|5          # the 5-tier verification ladder — declared honestly
oracle: <command>         # tiers 1-3: the deterministic check, e.g. "pnpm test && pnpm lint"
judge: codex              # tier 4: LLM judge lane (MUST differ from exec lane)
human_gate: false         # tier 5 / rung 0-1 validation gate → true (attended only)
invariants:               # things that must stay true ("no other test file modified")
checklist:                # feature list, every item starts [FAILING]
stops: { max_iterations: 10, budget_usd: X, plateau: 3, wall_clock_h: 4 }
```

Tier rules (from the ladder): tiers 1-3 loop happily on the oracle alone + review. Tier 4
**requires** the judge lane and it must differ from the executor. Tier 5 or unvalidated tasks
get a human gate — which makes the loop attended by definition. If success is genuinely
undefinable even for a human, **Fable refuses to start the loop** and says so (the
`loop-engineer` skill's honest halt).

## 3. One iteration = one bus cycle

Reuses a1 unchanged — the loop is `/swarm`'s wave machinery run repeatedly with state:

```
┌─ FABLE (in-session orchestrator) ──────────────────────────────────────────┐
│ read criteria.md + state.jsonl + steering.md                                │
│ plan ONE increment (Ralph fix: one item per iteration)                      │
│ write .bus/specs/<iter>-exec.prompt  (goal + criteria + signs + last state) │
└──────────────┬─────────────────────────────────────────────────────────────┘
               ▼
  EXEC worker (fresh spawn: claude:opus → glm:glm-5.2 on limit flag)
  does the increment · answer → res-<iter>.txt · git commit = checkpoint
               ▼
  ORACLE (deterministic, tiers 1-3): run criteria.oracle, capture exit + output
  — backpressure: a failing oracle short-circuits straight to the next iteration
               ▼
  REVIEW worker (codex, fresh spawn, sees ONLY diff + criteria + oracle output)
  verdict: pass | findings[P0/P1/P2]  → res-<iter>-review.txt
               ▼
┌─ FABLE adjudicates ────────────────────────────────────────────────────────┐
│ oracle green + review pass + checklist all [PASSING] → DONE                 │
│ findings → append to steering.md → next iteration (fix-or-defend, not obey) │
│ stop rule fired → HALT with honest status                                   │
│ append state.jsonl line: {iter, tried, oracle, review, cost, files}         │
└─────────────────────────────────────────────────────────────────────────────┘
```

Key mechanics, each mapped to a research finding:

- **Prompt = fixed goal + accumulated steering.** Pure Ralph re-feeds an identical prompt;
  the cross-model PR-loop pattern showed reviewer findings carried forward converge faster.
  We hybridize: `criteria.md` never changes, `steering.md` accrues review findings and
  learned rules ("write rules, don't correct" — every recurring mistake becomes a standing
  line, Cherny's compounding-engineering move).
- **Fix-or-defend, not obey.** The exec worker may rebut a finding with evidence; Fable
  arbitrates. Prevents reviewer-driven over-engineering (official docs: a reviewer asked
  for gaps will always report some — scope it to correctness).
- **Evidence, not assertions.** The exec worker must include the command output/diff proving
  its increment; Fable never takes "done" on faith (Cherny principle 6, and Ralph failure
  mode #5, premature done).
- **Signs in every exec prompt** (Ralph community fix): "SEARCH THE CODEBASE BEFORE ASSUMING
  NOT IMPLEMENTED", "NO PLACEHOLDER/STUB IMPLEMENTATIONS", "DO NOT WEAKEN TESTS TO PASS".
  The reviewer explicitly checks for stub-that-satisfies-the-oracle (Ralph failure mode #2).
- **Commit per iteration; `git reset --hard` is the recovery lever.** A derailed iteration
  is discarded, not argued with (ZeroSync/Ralph practice). Code loops run in a scratch
  worktree (PRD Q6) so the reset never touches the main tree.

## 4. Stop rules (all active, first to fire wins)

| Rule | Trigger | From |
|------|---------|------|
| **Goal hit** | oracle green + reviewer pass + all checklist `[PASSING]` — judged by non-executor | ladder tiers, `/goal` semantics |
| **Plateau** | `plateau` (default 3) iterations with no checklist/oracle-score progress → halt + honest report, "reset strategy, don't retry the step" | course chapter; Osmani |
| **Oscillation** | same file region flip-flopping across iterations (A→B→A) → halt, needs a human decision | Stop-hook 8-block guard, generalized |
| **Iteration cap** | `max_iterations` (default 10) | ralph plugin: the primary safety net |
| **Budget cap** | per-iteration cost re-summed from result envelopes/ccusage; `budget_usd` breached → halt | CLAUDE.md run-evidence rule + canonical list |
| **Wall clock** | `wall_clock_h` exceeded | canonical list |
| **Human abort** | `.bus/PAUSE` / `swarm-ctl abort` / Esc in the Fable session — all level-2 controls work unchanged | runbook §8 |

Halt is always honest: state.jsonl + a `HALTED.md` naming which rule fired, what was tried,
and the suggested next move (Ralph escape-hatch pattern). No fake `<promise>` exits — the
completion signal is the adjudication, not a string the executor emits.

## 5. Loop driver — how it actually runs

- **v1 (attended):** the Fable session drives the loop directly — the same gate-block pattern
  as `/swarm`, repeated. Interruptible at every adjudication (control story unchanged). This
  is deliberately Cherny's "escalating gate hardness" middle rung: orchestrator-checked
  criteria without new machinery.
- **Later (unattended, Phase 2+ containment mandatory):** a `swarm-loop.sh` while-loop drives
  iterations headless (Ralph shape, but with the oracle+review gate instead of a bare re-feed);
  Fable is invoked per-adjudication as a fresh `claude -p` call. Session-independent, cron-able.
- **Not `/goal`:** single-session, single-model, evaluator on Haiku — no cross-model review
  lane, no exec chain. Right tool for in-session polish; wrong chassis for multi-model loops.
- **Not the ralph Stop hook:** couples the loop to session lifecycle and exits on a
  self-graded promise string — both things this design exists to avoid.

## 6. State layout (bus extension)

```
.bus/loop/<run-id>/
├── criteria.md        # the contract — written first, never edited by workers
├── steering.md        # accumulated review findings + learned rules (grows)
├── state.jsonl        # one line per iteration: tried/oracle/review/cost/files
├── HALTED.md          # only on non-goal halt: which rule, why, next move
└── iter-<N>/          # per-iteration specs + res files (standard bus naming)
```

Monitor: the cockpit gains one BOARD line — `LOOP iter 4/10 · oracle FAIL(2) · plateau 1/3 ·
$3.20/$10` — read from state.jsonl. Firehose/cost panes unchanged.

Measurement-lag note (course chapter): loops whose score arrives later (engagement metrics,
deploy health) need a second scraper loop backfilling state.jsonl. Out of scope for v1;
the state schema already carries a `score` field so the scraper bolts on without migration.

## 7. Fit with the phase plan

Loop mode is **Phase 4.5** — after the cockpit and cross-model verify exist, before overnight
autonomy. It adds: criteria contract writer, oracle runner, review-gate spec type, state
appender, stop-rule checks in the orchestrator — all thin layers over Phase 1-3 machinery.
Unattended `/swarm-loop` (the cron/overnight form) is gated on Phase 2 containment exactly
like everything else. Default fan-out within a loop iteration is 1 exec + 1 review; wide
fan-out inside an iteration (parallel sub-branches) reuses plain `/swarm` semantics.
