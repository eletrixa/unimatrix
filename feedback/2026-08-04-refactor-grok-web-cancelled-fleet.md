---
source: refactor (lead repo, rr-d13-payments run)
date: 2026-08-04
run: rr-d13-payments
type: bug
severity: high
---

# grok readyroom write cards: 12/12 Cancelled at first web tool invocation

## What happened

Six pre-seeded grok write cards (readyroom profile, `CONF=profiles/readyroom.conf`,
`.chain` = `grok:grok-4.5`, `.write` + `.files` sidecars present) each failed twice with the
same signature, then parked `chain-exhausted` at 12:07:05Z:

- Worker starts, produces a healthy preamble ("Starting with targeted searches and page
  fetches"), then `{"type":"end","stopReason":"Cancelled"}` at ~700 output tokens, exactly at
  the point the model moves to invoke web fetches ("fetch the key Adyen docs pages in
  parallel" is the last thought).
- 12/12 identical across all six cards and both attempts. Deterministic, not transient.
- Evidence: `refactor/.bus-rr-d13-payments/run-a1-psp-adyen.jsonl` (+ `.1`, and siblings
  a2..a6); usage shows ~6.6k in / ~723 out, 2 turns, $0.054/attempt.

This contradicts the 2026-08-04 probe note "both tools fire headless, no prompt" — that probe
was presumably a read-only card via GROK_TOOLS; the WRITE-branch web path is what died here.

## Expected

Write cards on the readyroom grok chain carry web_search+web_fetch per spec 23; the card
should complete or fail with a diagnosable error, not silent Cancelled at tool-use time.

## Also observed (separate defect?)

`swarm-run.sh call grok:grok-4.5 "<web probe>"` on the same box/profile crashed the driver:
`swarm-run.sh: line 1470: pid_id[$finished]: unbound variable`, then printed the close
checklist with rc 0 and a ledger row `1 card(s), 0 file(s), rc 0` — a green-looking row for a
crashed call.

## Recovery used

Cards cancelled; the six briefs re-ran as claude session agents (WebSearch/WebFetch), $0
marginal. Note for speedwars: web-research lane availability on grok should be a doctor rung
(write-branch probe, not just read-branch).
