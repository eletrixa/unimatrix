# 06 — Live per-model cost panel + firehose v2

**Status:** Active
**Date:** 2026-07-19
**Related specs:** [02-cockpit](./02-cockpit.md), [05-ground-control](./05-ground-control.md)

---

## Overview

Builds on [05-ground-control](./05-ground-control.md) (the `site/server.mjs` web cockpit) and
reworks the firehose surface of [02-cockpit](./02-cockpit.md). Adds a live **per-model** usage +
**notional** $/hour panel above the firehose (placement superseded by spec 07 to bottom of OPS WALL),
and improves firehose readability with real wall-clock timestamps for all events.

## Goals

1. Display which **models** are burning and at what $/hour rate — so an accidental Opus run or a
   runaway lane is obvious at a glance.
2. Use **notional** dollars as a proxy (matching `docs/ops/llm-runs.md` discipline), never real
   billed amounts.
3. Provide accurate model attribution via carry-forward heuristics from event stream.
4. Enable per-lane letter chips and per-lane token/burn summary for cost visibility.

---

## Data grounding (verified against the live `.bus/run-*.jsonl`, 2026-07-19)

- Token usage rides on summary events per lane, with **different schemas**: claude `result`
  (`input_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens`, `output_tokens`),
  codex `turn.completed` (`input_tokens`, `cached_input_tokens`, `output_tokens`,
  `reasoning_output_tokens`), and claude-family `end` (`input_tokens`, `cache_read_input_tokens`,
  `output_tokens`, `reasoning_tokens`, `total_tokens`). `sumUsageTopLevel` already tolerates all of
  these; the new code reuses the same field-name-agnostic summing where it can and names buckets
  explicitly only for pricing.
- **Model identity is NOT on the token event.** It appears on *other* events in the same run:
  claude `system`/`assistant` carry `model` (`claude-sonnet-5`, and by the same path
  `claude-opus-*`, `glm-*`, `claude-haiku-*`), gemini `init` carries `model` (`gemini-3-flash`).
  Codex/verify lanes frequently emit **no** model string at all.
- Most events carry an ISO-8601 `timestamp`; the **token summary events often do not** (that is why
  the firehose clock reads `--:--:--` on those rows).

---

## Requirements

### Functional

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-1 | `GET /api/models` endpoint (polled on cost cadence ~10 s) returns per-family rows with fields `{model, tokens_total, tokens_5m, input_5m, output_5m, dollars_5m, dollars_per_hour, running, unpriced}`. | Must |
| FR-2 | Model attribution: within one run file, carry forward the last-seen `model` and `timestamp`; attribute token-bearing events to the carried model/time. | Must |
| FR-3 | Model family normalization: `*fable*`→`claude-fable`, `*opus*`→`claude-opus`, `*sonnet*`→`claude-sonnet`, `*haiku*`→`claude-haiku`, `*glm*`→`glm`, `*gemini*`→`gemini`, `*grok*`→`grok`, `*gpt*`/`*codex*`→`codex`; anything else lowercased. Fallback: `turn.completed` ⇒ `codex`, else `unknown`. | Must |
| FR-4 | Notional pricing: per-family `{in, out, cache}` in USD per million tokens; `cache` defaults to `in * 0.1` when omitted; unpriced families flag `unpriced:true` with $0 cost. | Must |
| FR-5 | Per-event dollars: `(input_noncache*in + cache_read*cache + cache_creation*in + output*out)/1e6`, summing only buckets the schema exposes. | Must |
| FR-6 | Rolling 5-minute window: `tokens_5m`, `dollars_5m`, `dollars_per_hour = dollars_5m * 12`; `running=true` when model had an event within trailing 30s. Response carries `window_min: 5` and `notional: true`. | Must |
| FR-7 | `/api/stream` SSE envelope gains `ts` field (send-time) so client renders real wall-clock even for events lacking `timestamp`; fall back to `—` only when genuinely unknown. | Must |
| FR-8 | Firehose row gains **model chip** (normalized family, colored per family) between lane and badge. | Must |
| FR-9 | Models panel placement (superseded by spec 07): sits above firehose on cockpit.html; content per-model cells (MODEL · tok/5m · $/hr · ● running), polling on cost cadence; notional stated in header. | Must |

---

## Design

### A. Attribution (server, pure)

- Parse each `run-*.jsonl` line-by-line (reusing the `/api/cost` reader). Within one run file,
  **carry forward** the last-seen `model` and last-seen `timestamp`; attribute a token-bearing event
  to the carried model and carried time.
- Normalize a raw model string to a family key: `*fable*`→`claude-fable`, `*opus*`→`claude-opus`,
  `*sonnet*`→`claude-sonnet`, `*haiku*`→`claude-haiku`, `*glm*`→`glm`, `*gemini*`→`gemini`,
  `*grok*`→`grok`, `*gpt*`/`*codex*`→`codex`; anything else passes through lowercased.
- Fallback when no model was ever seen in the run: a `turn.completed`-shaped event ⇒ `codex`
  (that envelope is codex's signature); otherwise `unknown`. This is a documented **best-effort**
  heuristic — the panel labels an `unknown` bucket honestly, never invents a model.

### B. Notional pricing (server, seeded + tunable)

- A `PRICES` table maps family key → `{ in, out, cache }` in **USD per million tokens**, seeded with
  public list prices and clearly commented `NOTIONAL`. `cache` defaults to `in * 0.1` (cache-read is
  ~10% of input list) when a family omits it. A family with no entry prices at $0 and is flagged
  `unpriced: true` so the UI can mark it rather than imply free.
- Seeds re-checked against current public list 2026-07-19: `claude-fable` 10/50, `claude-opus` 5/25,
  `claude-sonnet` 3/15, `claude-haiku` 1/5 (glm/gemini/codex/grok unchanged).
- Per event: `dollars = (input_noncache*in + cache_read*cache + cache_creation*in + output*out)/1e6`,
  summing whichever buckets that event's schema exposes (missing buckets = 0).

### C. Rolling window → $/hour (server)

- `GET /api/models` returns, for each model family seen:
  `{ model, tokens_total, tokens_5m, input_5m, output_5m, dollars_5m, dollars_per_hour, running,
  unpriced }`.
- The window is the trailing **5 minutes** of carried-timestamp; `dollars_per_hour = dollars_5m * 12`.
  `running = true` when the model had an attributed event within the trailing 30s.
- Response also carries `window_min: 5` and `notional: true` so the client never has to hardcode
  either. Sorted by `dollars_per_hour` desc, then `tokens_5m` desc.
- Reads are best-effort and never throw (malformed line skipped, unreadable file skipped) — same
  contract as `costSummary`.

### D. Firehose v2 (client + a server stamp)

- `/api/stream` SSE envelope gains a `ts` field (`Date.now()` at send) so the client can show a real
  wall-clock time even for the token events that lack their own `timestamp`. Client time =
  `obj.timestamp ?? envelope.ts`; the `--:--:--` fallback only survives when genuinely unknown.
- Each firehose row gains a **model chip** (the normalized family, colored per family) between the
  lane and the badge, so it is readable which model produced a line.
- Column alignment tightened (fixed-width time + lane + model + badge; summary flexes). No schema or
  data change beyond the added chip and the receive-time stamp.

### E. Panel placement (client)

- A new **Models** panel sits directly above the firehose (a compact row of per-model cells:
  `MODEL  ·  tok/5m  ·  $/hr  ·  ● running`), polling `/api/models` on the existing cost cadence.
  Notional is stated in the panel header. Degrades with the rest of the cockpit on the public deploy
  (no API). The existing per-lane `#cost-inline` strip stays (cumulative), unchanged.
- **Placement note (per [07-cockpit-redesign](./07-cockpit-redesign.md), 3-view redesign):** the
  Models panel moves to the **bottom strip of the OPS WALL view**. The `/api/models` endpoint
  contract and the panel content (per-model cells, fields, poll cadence, notional header) are
  unchanged — only the on-page placement moves. The "directly above the firehose" placement above
  is superseded.

## Non-Goals

- Real/billed dollars, invoices, or reconciliation with `docs/ops/llm-runs.md`.
- Historical charts or persistence — everything is derived live from the bus on each poll.
- Per-event model attribution beyond the carry-forward heuristic (no back-parsing provider APIs).
- Any write to the bus on model/cost data paths (the cockpit stays strictly read-only for cost data; bus mutations are delegated through `POST /api/ctl` to `swarm-ctl`, per spec 07).

---

## Boundaries

- **Always**: keep model attribution honest — `unknown` when genuinely unknown, never invent; use
  notional pricing only (never bill-reconciliation); make `/api/models` best-effort (malformed
  lines/files never crash).
- **Ask first**: adding new model families to the PRICES table; changing the rolling window
  duration from 5 minutes.
- **Never**: persist historical cost data; invoke a provider API for model attribution; write to
  `.bus` from the server process.

---

## Open Questions

None.

---

## Acceptance Criteria

- [ ] `GET /api/models` on a fixture bus returns per-family rows with correct carried-model attribution
      (a claude `result` preceded by a `claude-sonnet-5` assistant lands under `claude-sonnet`; a bare
      `turn.completed` with no model lands under `codex`; a run with no model ever ⇒ `unknown`).
- [ ] `dollars_per_hour = dollars_5m * 12`; an event older than 5 min contributes to `tokens_total` but
      not to `tokens_5m`/`dollars_5m`; `running` reflects the trailing-30s test.
- [ ] A family absent from `PRICES` returns `dollars_* = 0` with `unpriced: true` (never silently free).
- [ ] Malformed lines / unreadable files never crash `/api/models` (HTTP 200, best-effort).
- [ ] `/api/stream` envelope includes `ts`; the firehose renders a real time for a token event that
      lacks its own `timestamp`, and a model chip per row.
- [ ] The public deploy (no `/api/*`) still degrades to the local-only notice (no console errors).
- [ ] `bats tests/` green (new cases in `tests/ground-control.bats`); `shellcheck -x` unaffected.

---

## Dependencies

**Internal:** [05-ground-control](./05-ground-control.md) (server.mjs base, `/api/stream` contract),
[02-cockpit](./02-cockpit.md) (firehose layout).
**External:** Node stdlib; bats-core 1.13.x.
