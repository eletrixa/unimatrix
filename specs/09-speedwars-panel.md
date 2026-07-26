# Spec 09 — Speedwars panel: run evidence on the cockpit

**Status:** Active (build ordered 2026-07-20: put it on the website with polished UX/UI, plus a tab
showing the TOTAL and then tabs per field)
**Date:** 2026-07-20
**Related specs:** 08 (the ledger this renders), 07 (cockpit shell + view-module contract),
05 (Ground Control server), 06 (`/api/models` — the closest existing read-only route)

---

## Overview

Spec 08 built the evidence ledger (`docs/ops/speedwars.jsonl`) and its prose companion
(`docs/ops/run-reviews.md`). Both are `jq`-only surfaces today: 169 card rows, 59 verdicts,
22 run-meta, 12 lane reviews and 1 run-review across 15 runs, readable exclusively from a
terminal. The ledger's stated purpose is a review after **every** run "for comparison" — a job
that needs a comparison surface, which does not exist.

This spec adds **SPEEDWARS**, a fourth cockpit tab: a read-only, historical, cross-run evidence
board rendered from the ledger. It is the first cockpit view whose subject is not the live bus.

## Goals

- One glance answers "which lane should this card go to" and "is this run better than the last".
- Sub-tabbed: **TOTAL** first (everything rolled up), then one tab per field dimension.
- Honest under uneven coverage — the ledger's row types are sparsely populated and the panel must
  show absence as absence (FR-14, no fake data).
- Native to the cockpit's design language, not a bolted-on report.

## Non-Goals

- No mutation from the browser — no POST route, no editing the ledger, no re-running a card.
- No new runtime dependency: no chart library, no framework, no build step, no external asset.
  Charts are hand-built from DOM + CSS the way `flight.js` already draws its tracks (that view
  uses zero SVG — positioned divs and `repeating-linear-gradient` only).
- No live streaming. The ledger is append-only history; the panel fetches on demand, not via SSE.
- No statistics beyond order statistics (median/p90/rate). Spec 08 already ruled out Elo/BT at
  these sample sizes; the panel must not smuggle them back in as a chart.

## Requirements

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-1 | `GET /api/speedwars` in `site/server.mjs` parses `docs/ops/speedwars.jsonl` (path from `REPO_ROOT`) and returns the ledger split by row type plus `generated_at`. Malformed lines are skipped, never fatal. Missing file → `200` with empty collections and an `available:false` flag, never a 500. | Must |
| FR-2 | Aggregation happens **client-side** in the panel module. 169 rows is trivial; a single raw payload keeps server and client from drifting into two aggregation implementations. | Must |
| FR-3 | New view module `site/cockpit/speed.js` + `site/cockpit/speed.css`, exporting `init(rootEl)` + `render()`, touching DOM only inside `#view-speed`. Registered in `main.js` `VIEWS`/`VIEW_CONTAINER_ID`; new `<button class="tab" data-view="speed">SPEEDWARS</button>` and `<section id="view-speed" class="view" hidden>` in `cockpit.html`. | Must |
| FR-4 | Sub-tab bar inside the panel: **TOTAL**, then per-field tabs — **SPEED**, **COST**, **RELIABILITY**, **TOKENS**, **RUNS**. TOTAL is the default and shows the rolled-up scoreboard; each field tab is a focused deep view of that one dimension across lanes and runs. | Must |
| FR-5 | Selected sub-tab persists across reloads via `saveJSON`/`loadJSON` (`unimatrix-sw-tab`), matching how `flight.js` persists its own controls. | Should |
| FR-6 | Lane identity uses `laneColor()`/`laneLetter()` from `format.js` verbatim — never a new palette. Design tokens come from `base.css` `:root`. | Must |
| FR-7 | Degraded states are explicit: a lane with no `cost_usd` (codex bills to a ChatGPT subscription and emits none) renders "not billed", never `$0`; a run with no `run-review` row says so; a card with no verdict is "unjudged", never "verified". | Must |
| FR-8 | Because coverage is uneven, every derived rate shows its denominator (e.g. "21/27 judged"), so a 100% rate over 2 samples can never read as a 100% rate over 50. | Must |
| FR-9 | Panel is keyboard reachable: sub-tabs are real `<button>`s in focus order with `aria-selected`; the tab list carries `role="tablist"`. Contrast follows the existing token pairs. | Should |
| FR-10 | Data fetch is on first view activation and on an explicit refresh control — not on every cockpit tick (the ledger changes once per run, not per second). | Should |

## Data contract

`GET /api/speedwars` →

```json
{
  "available": true,
  "generated_at": "2026-07-20T09:41:00Z",
  "cards":       [ { "ts": "...", "run": "...", "id": "...", "served_lane": "grok", "outcome": "done", "wall_secs": 17, "cost_usd": 0.086, "...": "..." } ],
  "verdicts":    [ { "run": "...", "id": "...", "verified": false, "reason": "..." } ],
  "run_meta":    [ { "run": "...", "cards": {}, "fanout": 12 } ],
  "reviews":     [ { "run": "...", "lane": "glm", "score": 4, "tags": [], "note": "..." } ],
  "run_reviews": [ { "run": "...", "speedup": 3.65, "waves": {}, "...": "..." } ]
}
```

Card rows carry no `type` field — that absence *is* the discriminator (spec 08 FR-1). The join key
between a card and its verdict is `run + "/" + id`; ids are only unique within a run.

### Known data hazards the panel must survive

- `cost_usd` absent on every codex row (subscription-billed) and on some others.
- `served_model` null on codex rows.
- `wall_secs` present on all current rows, but treat missing/0 as unknown rather than instant.
- Duplicate `id` across different runs is normal; duplicate within a run is the backlog-14
  speed-row dedup bug — show it rather than silently collapsing it.
- Only 1 of 15 runs has a `run-review` row; only some have `run-meta`/`review`.
- `fanout` is recorded on exactly one `run-meta` row.
- All current rows fall inside a single day, so a date axis must not assume multi-day spread.

## Acceptance criteria

- [ ] `GET /api/speedwars` returns all five collections with counts matching `jq` over the ledger.
- [ ] Missing/unreadable ledger yields `available:false` and the panel renders an empty state.
- [ ] SPEEDWARS tab appears in the header, switches views, and survives reload with its sub-tab.
- [ ] TOTAL shows: run count, card count, per-lane scoreboard, and totals whose sums reconcile
      with `jq` computed values.
- [ ] Each field tab renders its dimension across lanes and runs with visible denominators.
- [ ] No lane shows `$0` for absent cost; no unjudged card shows as verified.
- [ ] `bats tests/` green, including a new server test for the route.
- [ ] Page never scrolls horizontally at 1280px; the view scrolls internally.
- [ ] Zero external requests from the panel (no CDN, no font, no image).

## Open questions

None blocking. "Impeccable UX/UI" is resolved by the design brief produced by the 2026-07-20
judge-panel (3 independent proposals scored and synthesized); its locked brief governs section
order, proportions and motion, and is summarized in `docs/larger-swarms.md`'s sibling design note
rather than duplicated here.
