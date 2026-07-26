#!/usr/bin/env bats
# The canonical verdict fold (plan 004 P0-FR7): "$ per verified-done" has ONE definition, written
# down in tests/fixtures/verdict-fold/README.md and implemented twice — in jq
# (src/speedwars-report.sh) and in JS (site/cockpit/fold.js, used by the cockpit SPEEDWARS panel).
# Both replay the SAME fixture ledger and must produce the SAME aggregates; the fixture is the
# contract, so any future divergence between the two renderers turns this file red.
#
# Project: unimatrix — multi-model swarm orchestrator driven from Claude Code
# Module:  tests/verdict-fold.bats
# Deps:    bats-core, jq, node (ESM), src/speedwars-report.sh, site/cockpit/fold.js
# Tested:  n/a — this is the test file
#
# Key responsibilities:
# - shell renderer replays tests/fixtures/verdict-fold/ledger.jsonl → expected.json
# - client renderer replays the identical ledger → the identical aggregates
# - the tripwires behind the canon: run/id join (never lane-scoped), lane-less v0 verdict rows
#   honored, unjudged claims never counted as verified, $/verified-done denominator
#
# Design constraints:
# - fixture-only; never reads the real docs/ops/speedwars.jsonl
# - the two implementations stay in two languages on purpose — do NOT "fix" this by making the
#   report shell out to node

REPO="$BATS_TEST_DIRNAME/.."
FIX="$BATS_TEST_DIRNAME/fixtures/verdict-fold"
REPORT="$REPO/src/speedwars-report.sh"

setup() {
  GOT_SH="$BATS_TEST_TMPDIR/shell.json"
  GOT_JS="$BATS_TEST_TMPDIR/client.json"
  WANT="$BATS_TEST_TMPDIR/want.json"
  jq -S . "$FIX/expected.json" > "$WANT"
  bash "$REPORT" --json "$FIX/ledger.jsonl" | jq -S . > "$GOT_SH"
  # The cockpit's fold, loaded standalone (fold.js is pure data — no DOM, no imports).
  node --input-type=module -e "
    import { canonicalFold } from '$REPO/site/cockpit/fold.js';
    import { readFileSync } from 'node:fs';
    const rows = readFileSync('$FIX/ledger.jsonl', 'utf8')
      .split('\n').filter((l) => l.trim()).map((l) => JSON.parse(l));
    process.stdout.write(JSON.stringify({ lanes: canonicalFold(rows).lanes }));
  " 2>/dev/null | jq -S . > "$GOT_JS"
}

@test "verdict-fold: the shell report replays the fixture to the canonical aggregates" {
  run diff -u "$WANT" "$GOT_SH"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "verdict-fold: the cockpit fold replays the SAME fixture to the SAME aggregates" {
  run diff -u "$WANT" "$GOT_JS"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "verdict-fold: lane-less v0 verdict rows are honored (r1/c2 is a false-done, not a done)" {
  # The refutation of r1/c2 carries no lane. A lane-scoped join drops it and glm's retry lands as
  # a verified done — the exact bug this fixture exists to prevent.
  run jq '.lanes.glm.false_done' "$GOT_SH"
  [ "$output" = "1" ]
  run jq '.lanes.glm.false_done' "$GOT_JS"
  [ "$output" = "1" ]
}

@test "verdict-fold: an unjudged done-claim is unjudged, never verified" {
  # codex's r1/c4 claims done and nobody judged it: it must not inflate verified_done (and must
  # therefore leave $/verified-done null rather than fabricating a rate).
  for expr in '.lanes.codex.verified_done == 0' '.lanes.codex.unjudged_done == 1' \
              '.lanes.codex.cost_total == null' '.lanes.codex.cost_per_verified_done == null'; do
    run jq -e "$expr" "$GOT_SH"
    [ "$status" -eq 0 ]
    run jq -e "$expr" "$GOT_JS"
    [ "$status" -eq 0 ]
  done
}

@test "verdict-fold: \$/verified-done divides the lane's whole bill by verified-done CARDS" {
  # glm: 0.05 + 0.30 + 0.20 = 0.55 spent, exactly one verified-done card (three done-claims).
  run jq -e '.lanes.glm.cost_per_verified_done == 0.55' "$GOT_SH"
  [ "$status" -eq 0 ]
  run jq -e '.lanes.glm.cost_per_verified_done == 0.55' "$GOT_JS"
  [ "$status" -eq 0 ]
  # grok spent real money and verified nothing: a rate, not zero, is the honest absence.
  run jq -e '.lanes.grok.cost_total == 0.12 and .lanes.grok.cost_per_verified_done == null' "$GOT_SH"
  [ "$status" -eq 0 ]
}

@test "verdict-fold: the join key includes the run (r2/c1 does not inherit r1/c1's refutation)" {
  for f in "$GOT_SH" "$GOT_JS"; do
    run jq -e '.lanes.claude.verified_done == 1 and .lanes.claude.false_done == 0' "$f"
    [ "$status" -eq 0 ]
  done
}

@test "verdict-fold: the cockpit consumes the shared fold instead of keeping its own" {
  grep -q "from './fold.js'" "$REPO/site/cockpit/speed.js"
  # no second verdict index in the view layer
  run grep -c "vIndex" "$REPO/site/cockpit/speed.js"
  [ "$output" = "0" ]
}

@test "verdict-fold: the human table still renders and keeps medians (never means)" {
  run bash "$REPORT" "$FIX/ledger.jsonl"
  [ "$status" -eq 0 ]
  [[ "$output" == *"MED-WALL"* ]]
  [[ "$output" == *"P95-WALL"* ]]
  [[ "$output" != *"AVG"* ]]
  [[ "$output" == *"UNJUDGED"* ]]
}

# --- plan 004 P2: --run pre-filter + the P2-FR2 coverage denominator ------------------------------

@test "verdict-fold: --run narrows the fold to one run without changing the contract shape" {
  # r2 carries exactly one row: claude/c1, verified. Every other lane disappears.
  run bash "$REPORT" --json --run r2 "$FIX/ledger.jsonl"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.lanes | keys | join(",")' <<<"$output")" = "claude" ]
  [ "$(jq -r '.lanes.claude.verified_done' <<<"$output")" = "1" ]
  # same key set as the unfiltered contract — a pre-filter, never a second shape
  local want got
  want="$(jq -S '.lanes.claude | keys' "$FIX/expected.json")"
  got="$(jq -S '.lanes.claude | keys' <<<"$output")"
  [ "$want" = "$got" ]
}

@test "verdict-fold: --run= form and an unknown run fold to an empty lane set, not an error" {
  run bash "$REPORT" --json --run=nosuchrun "$FIX/ledger.jsonl"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.lanes | length' <<<"$output")" = "0" ]
}

@test "verdict-fold: --json is byte-identical with and without a no-op --run flag order" {
  # --json may come before or after --run; neither changes the emitted contract.
  local a b
  a="$(bash "$REPORT" --json --run r2 "$FIX/ledger.jsonl" | jq -S .)"
  b="$(bash "$REPORT" --run r2 --json "$FIX/ledger.jsonl" | jq -S .)"
  [ "$a" = "$b" ]
}

@test "verdict-fold: P2-FR2 — the complexity table never renders without its coverage denominator" {
  run bash "$REPORT" "$FIX/ledger.jsonl"
  [ "$status" -eq 0 ]
  # only r1 carries a run-meta row; the ledger has two run labels.
  [[ "$output" == *"stratified over 1 of 2 runs"* ]]
  [[ "$output" == *"50%"* ]]
  [[ "$output" == *"cards carry a complexity bucket"* ]]
  # the denominator sits above the stratified table it qualifies
  local rendered strat_line cx_line
  rendered="$(bash "$REPORT" "$FIX/ledger.jsonl")"
  strat_line="$(grep -n 'stratified over' <<<"$rendered" | head -1 | cut -d: -f1)"
  cx_line="$(grep -n '^LANE:CX' <<<"$rendered" | head -1 | cut -d: -f1)"
  [ -n "$strat_line" ] && [ -n "$cx_line" ]
  [ "$strat_line" -lt "$cx_line" ]
}

@test "verdict-fold: the coverage caption does not blow out the table's column widths" {
  # The caption is prose, not a row — fed through `column -t` it would pad column 1 of BOTH
  # tables to ~70 chars. The lane column must stay narrow.
  run bash "$REPORT" "$FIX/ledger.jsonl"
  [ "$status" -eq 0 ]
  local header
  header="$(grep -m1 '^LANE ' <<<"$output")"
  [ "${#header}" -lt 120 ]
  [[ "$header" =~ ^LANE[[:space:]]{1,6}ATTEMPTS ]]
}
