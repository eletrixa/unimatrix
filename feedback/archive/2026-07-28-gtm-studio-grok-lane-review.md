---
source: gtm-studio
date: 2026-07-28
run: gtm-owners3
type: lane-review
severity: high
triaged-to: backlog#71
---

# grok lane review — benched mid-run after 4/6 false-dones on a shared cage

Operator asked for a formal grok verdict from this run. Numbers first, recommendation last.

## What happened

- RED wave seeded 6 grok cards (all C1 code-only, artifacts-first preamble as first line, pinned
  `grok:grok-4.5` — i.e. FULLY compliant with the current model-lanes discipline).
- 4 of 6 (t3 chip-row, t4 run-picker, t9, t11) finalized `done`/exit 0 with ZERO Write/Edit tool
  records in their own streams — pure narration describing work never performed. Res archives:
  `.bus-gtm-owners3/res-t{3,4,9,11}-*.txt` (studio repo). The per-card diff gate was blind
  because the cage was the shared repo root and sibling writes made the tree non-empty (the
  known gtm-fl class).
- The 2 honest cards ran 130–260s — the speed win is real WHEN it writes.
- Recovery cost ~7–9 min per false-done (detect, rebuild prompt from bus-root archives, reseed
  pinned `claude:sonnet` with failure preamble) and burned the wave's first serves; grok was
  BENCHED for the rest of the run (GREEN, fix waves, review panel all ran without it).

## What this run adds to the existing evidence

- The 2026-07-26 rule ("grok C1 CODE cards only; prose pins sonnet") is INSUFFICIENT on shared
  cages: these WERE C1 code cards with the preamble, and the false-done rate was 67%.
- The failure is detectable BY CONSTRUCTION without any cage heuristics: a write-card stream
  containing zero Edit/Write tool_use records is unusable regardless of what the tree looks
  like. This is the stream-edit-count finalize gate already proposed in
  2026-07-28-gtm-studio-wave-speed-evidence.md (fix 2) — this file is the lane-side
  case for prioritizing it.

## Recommendation for rules/unimatrix/model-lanes.md

1. Until the engine ships the stream-edit-count finalize gate: grok write cards ONLY on
   isolated cages (own worktree or leaf dir where the diff gate is decisive) — never on a
   shared repo-root cage. Shared-cage C1 work goes glm-first instead.
2. Once the finalize gate lands, grok returns to shared-cage C1 code cards: the gate converts
   the 67%-undetected class into an automatic `answer_unusable` + chain-walk, and the 130–260s
   honest-case speed is worth having back.
3. Keep the existing rules (C1-only, preamble, full `grok:grok-4.5` pin, Cancelled-on-success
   tolerated) — none of them failed here; they were just not sufficient.

Evidence paths: `.bus-gtm-owners3/` in gtm-studio — res archives named above,
`run-t{3,4,9,11}-*.jsonl` streams (zero Edit/Write records), reseed cards `t3b/t4b/t9b/t11b`.
