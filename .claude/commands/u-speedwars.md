---
description: Render the lane speed-evidence report (spec 08) and optionally record a subjective review row
---

# /u-speedwars — lane speed evidence (spec 08)

**Deprecated** (spec 17 FR-8): `/u-speedwars` is deprecated in favor of `/u:speedwars`; body stays
canonical here. `/u-speedwars` is deleted next release — `/speedwars` (below) and `/u:speedwars`
both keep working.

Canonical body for the `/speedwars` slash command (spec 16 FR-5) — `/speedwars` is now a 2-line
alias pointing here.

1. Run `src/speedwars-report.sh` and show the operator its output verbatim (per-lane table —
   ATTEMPTS/CARDS/VDONE/FALSE-DONE/UNJUDGED/FAIL, medians, $/VDONE — complexity strata, review
   lines). Ledger default: `docs/ops/speedwars.jsonl`; a file argument overrides the path;
   `--json` emits the canonical per-lane aggregates (the verdict-fold contract shape) instead.
   UNJUDGED means no verdict row exists — such cards are never counted verified (spec 08
   amendment 2026-07-25).
2. Read the table before commenting. Call out: false-done counts per lane, any lane whose
   subjective review rank disagrees with its cost/latency numbers (that disagreement — not the
   averages — is what should reorder `EXEC_CHAIN`), and lanes with n too small to compare
   (n < 5 per pairing: say so, don't rank).
3. If the operator gives a subjective verdict ("grok felt fast but sloppy"), append a review
   row — score anchored 1–5 (1 unusable · 2 needed rescue · 3 did the job · 4 beats cost
   peers · 5 promote in EXEC_CHAIN), tags ONLY from {flaky, thorough, verbose, terse, fast,
   slow, hallucinated, ignored-instructions, over-eager, good-value, false-done}, note ≤140
   chars:
   `jq -cn --arg ts "$(date -u +%FT%TZ)" '{ts:$ts,type:"review",run:"<run>",lane:"<lane>",score:N,tags:[...],note:"..."}' >> docs/ops/speedwars.jsonl`
4. Never average review scores into the objective columns; they render side-by-side only.
   Never edit existing rows — corrections are new rows (same run/id).
