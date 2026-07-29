---
source: gtm-studio
date: 2026-07-28
run: gtm-owners3
type: performance
severity: high
triaged-to: backlog#70 backlog#71 backlog#73
---

# Wave wall-clock forensics — where the time actually went (run gtm-owners3)

Operator perception: "the waves are so slow." Measured (stream birth→mtime on every
`run-*.jsonl`, 60s-bucket concurrency profile, this repo's bus): the ENGINE was not the
bottleneck — recovery latency and inter-wave turnaround were. Numbers below; the four
proposed fixes are ranked by measured minutes saved.

## Measured timeline

- RED wave 15:52–16:15 (23 min for 13 cards + 4 reseeds), GREEN wave 16:20–16:53
  (33 min for 14 cards). Between them a 5-min idle gap (orchestrator gate + reseed + relaunch).
- GREEN ran a sustained **8-wide** (full FANOUT, 16:20–16:33, all claude:sonnet, one shared
  repo-root write cage) — so the shared cage does NOT serialize same-cage claude cards.
  The RED wave's apparent 2–3-wide crawl was CARD SUPPLY, not engine throttle:
  4 of its cards sat parked and 4 more had burned their first serve on false-dones.
- Long-tail card sizes were honest: g7 1791s (vs 1800 cap — a near-miss kill), g13 1442s,
  g6 1178s; median claude card ~380s; grok cards 130–260s.

## Where the minutes went (ranked)

1. **Empty `.write` sidecar → spawn-kill → park → manual nudge: ~11 min × 4 cards.**
   Orchestrator seeded four sidecars as empty files (a `cd &&` short-circuit left `$ROOT`
   unset). Engine killed each worker at spawn (`write-target-missing`, retryable=0) and
   parked; recovery waited on a human-noticing loop. These were also the wave's four
   longest cards, so the loss compounded into the critical path.
   **Fix (engine): validate sidecars at SWEEP time** — empty or nonexistent `.write` refuses
   the card loudly at enqueue (naming the sidecar and its content) instead of park-after-kill.
   A `swarm-ctl lint-specs` preflight verb (write targets exist + non-empty, chain tokens are
   `lane:model` pairs, prompt non-empty) would have caught this AND the bare-token class
   (gtm-runq (a)) before any spawn. Estimated saving this run: ~11 min of critical path.

2. **grok false-done discovery latency: first serve wasted + ~7–9 min to reseed, × 4 cards.**
   4 of 6 grok RED cards finalized done/0 with ZERO Write/Edit tool records in their own
   stream (pure narration; res archives confirm). The per-card diff gate was blind because
   the shared cage sees sibling writes (known class, gtm-fl (b)) — but the STREAM is
   cage-independent: a write-card stream containing zero Edit/Write tool_use records is
   unusable BY CONSTRUCTION.
   **Fix (engine): stream-edit-count gate at finalize** — write cards (`.write` present)
   whose stream has zero Edit/Write records reclass `answer_unusable` and auto-walk the
   chain immediately, no orchestrator round-trip. Estimated saving: ~15–20 min + 4 wasted
   serves.

3. **Inter-wave turnaround: ~5 min of full idle (16:15–16:20).** Gate + reseed + fresh
   launcher spin-up. Orchestration lesson rather than engine: keep ONE pool alive and drop
   the next wave into `queue/` after the gate (staged-specs already supports it); or an
   engine `--hold-open <min>` that idles the pool awaiting queue drops instead of exiting.

4. **Near-miss timeout on the biggest card:** g7 finished at 1791s under a 1800s cap.
   Had it crossed, the known false-timeout/salvage tax (~10+ min) would have fired on the
   run's most expensive card. Sizing rule worth pinning in the skill: complex PAGE cards
   (multi-component adoption + new laws) are L cards — 2400s, not 1800s.

Context that inflated perception but isn't engine: kimi lane dead (Moonshot balance $0)
pushed every C2+ card to claude:sonnet (median ~380s vs grok's 130–260s on C1); and one
whole launch was lost to the `--run` BUSDIR-derivation bug (filed separately today:
2026-07-28-gtm-studio-run-flag-busdir-cwd.md).

Evidence paths: `.bus-gtm-owners3/` in the studio repo — `limits/*.parked` reason lines
(`write-target-missing`), `res-t{3,4,9,11}-*.txt` (narration-only), `run-*.jsonl`
birth/mtime spans, the two launcher outputs in the session task logs.
