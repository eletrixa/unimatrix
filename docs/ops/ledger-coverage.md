# Ledger Coverage Measurement

**Date:** 2026-07-25 (corrected same day — cross-review finding #1: the first pass divided
run-meta ROW count by distinct runs; one run can carry many run-meta rows, so the honest
numerator is distinct runs *covered by* at least one run-meta row.)

## Coverage Metrics

| Metric | Count |
|--------|-------|
| run-meta rows (raw) | 34 |
| Distinct runs covered by ≥1 run-meta row | 20 |
| Distinct run labels in the ledger | 38 |
| **Coverage** | **52% (20 ÷ 38)** |

## Coverage Assessment

**Coverage: 52% — BELOW the 80% threshold.**

### PRD Rule (P0-FR6)

> The number exists in `docs/ops/`, dated. Under 80% means stratification is decoration and must
> carry its denominator forever after (#17).

**Status:** Under 80%. Effective immediately, **every stratified figure must carry its coverage
denominator** ("stratified over N of M runs — X%"). P2-FR2 implements exactly this in the push
summary and report; until coverage crosses 80%, no stratified number renders bare anywhere.

## Per-Type Row Counts (Context)

| Type | Count |
|------|-------|
| (null = card attempt rows) | 780 |
| verdict | 134 |
| run-summary | 68 |
| run-meta | 34 |
| review | 24 |
| run-review | 1 |
| **Total** | **1041** |

## Measurement Method (Re-runnable)

```bash
L=docs/ops/speedwars.jsonl
covered=$(jq -r 'select(.type=="run-meta") | .run' "$L" | sort -u | wc -l)
total=$(jq -r '.run' "$L" | sort -u | wc -l)
echo "Coverage: $((covered * 100 / total))% ($covered / $total)"
```

## Notes

- The ledger (`docs/ops/speedwars.jsonl`) is gitignored per project policy; this file documents
  the result as of the date above.
- A run is "covered" iff at least one `run-meta` row exists for its exact `.run` label —
  counting rows instead of covered runs overstates coverage whenever a run carries several
  run-meta rows (one run contributed 7 of the 34 rows at measurement time).
- The threshold of 80% comes from P0-FR6 in `plans/004-plugin-cli-cockpit-fleetops/PRD.md`.

**Addendum (2026-07-26, post-P2):** the report now computes this coverage LIVE from the rows in
hand and prints it above every stratified table ("stratified over N of M runs — X%"), so this
file is the dated measurement of record, not the live number. Live value at P2 close: 20 of 48
runs — 42% (coverage moved further below the bar as unlabelled runs landed). The PRD's
complexity-fallback idea (derive a bucket from files-touched/wall-time when run-meta is absent)
is deliberately NOT built — inferred strata would fabricate the very signal the denominator
exists to keep honest; see docs/research-backlog.md.
