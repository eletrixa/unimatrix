---
source: refactor
date: 2026-08-05
run: rr-ads
type: bug
severity: major
---

# grok write cards: skeleton-done passes the diff gate

## What happened
Run rr-ads (plan 040 CEO decision), two grok write cards (`f-revenue-external`,
`j-consumer-surface`, lane `grok:grok-4.5`). First two attempts ended after ~50 output tokens
with no tool calls and no writes — the existing false-done class, correctly caught by the
"write target shows no change since spawn" diff gate and requeued.

The orchestrator then nudged with "your FIRST action must be creating the output file". Third
attempt: grok created the file containing ONLY the return-format skeleton (9/17 lines, empty
sections, "headline TBD") and finalized. The diff gate saw a changed write target and accepted
done. Zero substantive content reached the evidence set; caught only by an orchestrator wc/head
audit.

## Expected
A write card whose produced artifact is an empty skeleton should not clear the diff gate. The
gate proves mutation, not content.

## Evidence paths
- refactor `.bus-rr-ads` archive: `docs/ops/bus-archives/rr-ads/res-f-revenue-external.txt`,
  `run-f-revenue-external.jsonl` (6.9KB stream: ~50 text tokens then end)
- Skeleton file as accepted (deleted after, reproduced in the run-review entry): 9 lines,
  headings only.
- Recovery: cards cancelled, lanes re-run as session claude agents (evidence files 100+ lines).

## Suggestion
Diff gate addendum for write cards: after mutation check, fail finalize when the produced
file(s) match the card's own return-format headings with no body lines (or fall under a
min-content-bytes floor, e.g. 500B of non-heading text). Alternatively: a placeholder scan
("TBD", empty `##` sections) on `.files`-manifest targets.
