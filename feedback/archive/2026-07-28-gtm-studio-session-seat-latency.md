---
source: gtm-studio
date: 2026-07-28
run: gtm-owners3
type: performance
severity: high
triaged-to: skill-ledger 2026-07-28
---

# Session-seat phase forensics — where the POST-swarm hours went (run gtm-owners3)

The bus waves were profiled earlier today (2026-07-28-gtm-studio-wave-speed-evidence.md).
This file covers the phase AFTER the bus: the simplify pass, review panel, and fix waves run as
SESSION subagents (Agent tool seats) rather than bus cards — wall clock 15:29 → 19:15, of which
the review→fix→verify tail (16:45 → 19:15) is the slow part the operator flagged. Three cost
classes, each with an engine/skill-shaped fix.

## 1. Report-delivery round-trips: idle-without-delivering, ~6 nudges × 1–3 min each

Session seats end their turn WITHOUT their findings reaching the orchestrator unless the spawn
prompt makes SendMessage-to-main the explicit final action — and even then, roughly half of this
run's seats idled first and delivered only after a nudge. Observed: 4/4 simplify reviewers idled
silently (all four needed a "deliver via SendMessage" round-trip, two needed TWO), seat-ts needed
a status poke ~25 min in. Every nudge is a full re-wake plus my own turn latency.

**Fix (skill):** pin a standard trailer into every seat prompt — "call SendMessage to:'main' with
<deliverable>; the SendMessage call IS the delivery; do not just end your turn" (this run's later
seats carried it and still idled-first ~30% of the time, so ALSO:) **Fix (pattern):** don't chase
individual seats — spawn seats with the trailer, then treat idle-notifications-without-summary as
a batch: one sweep message to all outstanding seats at once, not one round-trip per seat as I did.

## 2. Shared-checkout fleet collisions: the single biggest tail cost (~45–60 min)

A concurrent operator fleet worked the SAME checkout the whole evening (room-lens promotion, then
its own review-fix wave converging on the same findings). Measured costs:
- fix4-lens waited out a full 10-min cold window mid-card (18:47→18:57) after the fleet landed
  inside room-lens.tsx under it, and re-applied a label the fleet had reverted (L10).
- fix4-urlagg held 3 findings for 13–21-min cold windows, and burned a round-trip asking who owns
  a file mid-flight; my first fix-app-url agent hit the same wall an hour earlier (BLOCKER report,
  redirect, partial re-scope).
- Two agents applied work the fleet had ALREADY applied (verify-not-reapply overhead on 4
  findings), and one finding (codex-12) was half-landed by each side in the same file.
- One transient: a gate run red-failed on the fleet's 51-second-old in-flight edit, cost a
  diagnose cycle before re-running green.
The 10-min-cold rule + never-fight-a-hot-file discipline WORKED (zero lost work, zero git
clobbers this phase) but it converts collision into pure wall-clock wait.

**Fix (structural, known pattern):** when two fleets must work one repo, give each its own git
worktree and merge at gates (rolecls lesson already says this for engine self-builds — extend the
recommendation to ANY concurrent-fleet situation; the shared-checkout mode should be the
exception, not the default). A cheap middle: a `.fleet-lease` registry file naming dir-level
ownership per fleet, checked before every write, so waits are targeted instead of blanket 10-min
mtimes.

## 3. Per-agent full-gate repetition (~15–20 min aggregate)

Every fix seat independently ran its own scoped vitest + repo-wide `tsc --noEmit` (correctly, per
card rules), and several re-ran after the fleet's edits invalidated results. Aggregate: ≥9
full-tsc runs (~60–90s each on this tree) + ≥7 multi-hundred-file vitest sweeps in the tail
phase.

**Fix (pattern):** seats verify their OWN files with targeted vitest only; the orchestrator owns
exactly two repo-wide gates per wave (entry baseline + exit). Pin "do NOT run repo-wide tsc; the
orchestrator gates" into fix-seat prompts unless the card's change is type-contract-shaped.

## Context numbers

Panel yield for the cost: 39 findings (16 codex, 14 design judge, 9 session seats), of which 3
CRIT were real production-facing defects (unwired harvest ports, redirect allow-list bypass,
Suspense fallback rendering raw-id chips) — the panel phase itself is emphatically worth its
tokens; the waste was concentrated in delivery round-trips and collision waits, not in review
compute.
