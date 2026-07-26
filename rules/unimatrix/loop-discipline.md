---
applies-to: unimatrix swarm-loop
---

# Loop Discipline

Rules specific to `/swarm-loop` — iterate until success criteria genuinely hold, not until an
executor claims "done."

## Criteria contract

- Written to `.bus/loop/<run>/criteria.md` **before iteration 1**. Read-only to workers — an
  executor cannot redefine its own success condition mid-loop.
- Declares the verification tier **honestly**: tiers 1-3 = deterministic oracle, tier 4 = LLM
  judge required, tier 5 = human gate. Never claim a higher tier than the check actually performed.
  If success is genuinely undefinable even for a human, refuse to start the loop and say so.

## Judge ≠ executor

- **Always true, no exceptions.** A lane other than the one that produced the diff (default:
  codex reviewing claude/GLM output) reviews every iteration. An executor never grades its own work.

## Stop rules — all active simultaneously, first to fire wins

- **Goal hit** — oracle green + reviewer pass, judged by the non-executor. (The checklist is
  advisory context in v1 — it steers exec/review but has no per-item auto-marking mechanism, so
  it is not a separate machine gate; oracle+review ARE the gate. See specs/03-swarm-loop.md.)
- **Plateau** — default 3 iterations with no measurable oracle_rc/review progress → halt;
  reset strategy, don't keep retrying the same step.
- **Oscillation** — the same file region flip-flopping across iterations (A→B→A) → halt, needs a
  human decision.
- **Max iterations** — default 10.
- **Budget** — per-iteration cost re-summed from result envelopes; a breach halts immediately.
- **Wall clock** — configured ceiling exceeded.

## Proof-of-action gate

- A completion claim is not evidence. Every claim of "done" must carry the **artifact path** plus
  an **excerpt of its actual content** — a worker asserting success in prose, with nothing else
  attached, is treated as unverified.
- The `--until` judge **runs the check command itself** and reads its exit code — it never accepts
  a worker's narration of having run the check. This is execution-hallucination (arXiv
  2503.13657; closest MAST code is FM-2.6 reasoning-action mismatch — no exact match exists):
  agents reporting a tool call or test run that didn't actually happen, or
  happened differently than claimed.

## Halting

- Every non-goal halt writes `.bus/loop/<run>/HALTED.md`: which rule fired, what was tried, and
  the suggested next move.
- **No promise-string exits.** The completion signal is adjudication (oracle + reviewer +
  checklist), never a string the executor emits asserting success.

## State

- Fresh worker context every iteration — no accumulated conversation state carries between
  iterations; anything that must persist lives in files.
- State lives in `.bus/loop/<run>/state.jsonl` (one line per iteration: tried/oracle/review/
  cost/files) plus a **git commit per iteration** — a derailed iteration is discarded via
  `git reset`, never argued with.
