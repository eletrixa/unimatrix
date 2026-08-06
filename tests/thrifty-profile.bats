#!/usr/bin/env bats
# Coverage for the thrifty profile: conf_load resolution, the speedwars-report "anthropic share"
# footer math (text + --run filter), the --json contract (unchanged by the footer), and the
# DOCTOR_LANES subset knob on `doctor --live`. Four already-shipped features, one test each pinning a
# distinct contract — no real network, no real ledger (every fixture lives in $BATS_TEST_TMPDIR).
#
# Project: unimatrix — multi-model swarm orchestrator driven from Claude Code
# Module:  tests/thrifty-profile.bats
# Deps:    bats-core, tests/helpers/swarm-run-fixture.bash (setup/teardown + lane-CLI/curl fakes),
#          src/swarm-lib.sh (conf_load), src/speedwars-report.sh, swarm-run.sh (doctor --live), jq
# Tested:  n/a — this is the test file
#
# Key responsibilities:
# - profiles/thrifty.conf resolves through conf_load to the documented cost-optimized lane set
#   (glm-led EXEC_CHAIN, codex<->glm verify pair, fable plan, FANOUT 6, claude capped at 1, PAYG deny)
# - speedwars-report.sh's text footer sums Anthropic-billed (served_lane=="claude") priced rows vs
#   all priced rows, in $ and tokens, with integer % — folded over the SAME attempt set as every
#   other figure, so --run narrows it too (two run labels prove the footer moves with the filter)
# - the --json branch stays the pinned per-lane contract: valid JSON, and "anthropic" never appears
#   (the footer is text-only) — the verdict-fold golden fixture (tests/fixtures/verdict-fold/) is left
#   untouched; this test only asserts on its own 4-row fixture
# - `doctor --live` honors DOCTOR_LANES (space-separated subset; unset = all six lanes)
#
# Design constraints:
# - fixture-only: the report tests build a 4-row ledger in $BATS_TEST_TMPDIR; the doctor test rides
#   the shared swarm-run-fixture's PATH-shimmed fakes (claude/codex/gemini/grok/curl) — no real CLIs,
#   no real network, exactly as tests/swarm-run-3.bats exercises `doctor --live`.
# - conf_load is sourced into the test shell for the resolution test, the same way
#   tests/helpers/swarm-lib-fixture.bash sources src/swarm-lib.sh for the swarm-lib shards.
# - the 4-row ledger's footer is hand-computed in the _report_fixture comment so a jq regression
#   turns the matching line red without re-deriving the formula.

load 'helpers/swarm-run-fixture'

REPO="$BATS_TEST_DIRNAME/.."
LIB="$REPO/src/swarm-lib.sh"
REPORT="$REPO/src/speedwars-report.sh"
PROFILE="$REPO/profiles/thrifty.conf"

# _report_fixture <path> — the shared 4-row ledger for the footer + --json tests. Two run labels
# (alpha/beta) so --run is observable; one null-cost row so "priced rows" (numeric cost_usd) is
# distinct from "all rows". Shape mirrors the real speedwars.jsonl card rows (no `type` field).
#
# Unfiltered footer (hand-computed): priced = c1+c2+c4 (c3 null-cost excluded). claude-priced =
# c1+c4 = $0.40+$0.10 = $0.50 of $1.10 total priced (0.50/1.10 = 45%); claude tokens = (100+200)+
# (10+20) = 330 of 930 (35%).
# --run alpha footer: priced = c1+c2. claude-priced = c1 = $0.40 of $1.00 (40%); claude tokens =
# 300 of 900 (33%).
_report_fixture() {
  cat > "$1" <<'JSONL'
{"run":"alpha","id":"c1","served_lane":"claude","outcome":"done","wall_secs":5,"cost_usd":0.40,"tokens_in":100,"tokens_out":200}
{"run":"alpha","id":"c2","served_lane":"glm","outcome":"done","wall_secs":9,"cost_usd":0.60,"tokens_in":300,"tokens_out":300}
{"run":"alpha","id":"c3","served_lane":"glm","outcome":"done","wall_secs":3,"cost_usd":null,"tokens_in":5,"tokens_out":5}
{"run":"beta","id":"c4","served_lane":"claude","outcome":"done","wall_secs":2,"cost_usd":0.10,"tokens_in":10,"tokens_out":20}
JSONL
}

@test "thrifty.conf resolves through conf_load" {
  # source the lib exactly as tests/helpers/swarm-lib-fixture.bash does, then load the real profile.
  # shellcheck source=/dev/null
  source "$LIB"
  CONF="$PROFILE"
  conf_load "$CONF"
  [ "$EXEC_CHAIN" = "glm:glm-5.2 grok:grok-4.5 codex:default claude:haiku" ]
  [[ "$VERIFY_MAP" == *"codex:glm"* ]]
  [ "$PLAN" = "fable" ]
  [ "$FANOUT" = "6" ]
  [ "$LANE_MAX_CLAUDE" = "1" ]
  [ "$PAYG_FALLBACK" = "deny" ]
}

@test "anthropic-share footer math + --run filter" {
  LEDGER="$BATS_TEST_TMPDIR/sw.jsonl"
  _report_fixture "$LEDGER"

  run bash "$REPORT" "$LEDGER"
  [ "$status" -eq 0 ]
  # $0.50 (claude-priced) of $1.10 (all priced) = 45%; 330 of 930 tokens = 35% — see _report_fixture.
  [[ "$output" == *'anthropic share: $0.50 of $1.10 priced cost (45%)'* ]]
  [[ "$output" == *'330 of 930 tokens (35%)'* ]]
  footer_all="$(grep '^anthropic share:' <<<"$output")"

  run bash "$REPORT" --run alpha "$LEDGER"
  [ "$status" -eq 0 ]
  # --run alpha narrows to c1+c2 (priced): $0.40 of $1.00 = 40%; 300 of 900 tokens = 33%.
  [[ "$output" == *'anthropic share: $0.40 of $1.00 priced cost (40%)'* ]]
  [[ "$output" == *'300 of 900 tokens (33%)'* ]]
  footer_alpha="$(grep '^anthropic share:' <<<"$output")"

  # the pre-filter moves the footer — the two run labels carry different claude/priced splits, so a
  # --run that drops beta must change every footer figure (not just the cost dollars).
  [ "$footer_all" != "$footer_alpha" ]
}

@test "--json branch unchanged" {
  LEDGER="$BATS_TEST_TMPDIR/sw.jsonl"
  _report_fixture "$LEDGER"

  run bash "$REPORT" --json "$LEDGER"
  [ "$status" -eq 0 ]
  echo "$output" > "$BATS_TEST_TMPDIR/sw.json"
  run jq -e . "$BATS_TEST_TMPDIR/sw.json"
  [ "$status" -eq 0 ]                     # (a) stdout parses as JSON
  [ "$(jq -r 'has("lanes")' "$BATS_TEST_TMPDIR/sw.json")" = "true" ]
  [[ "$output" != *"anthropic"* ]]        # (b) the footer is text-only; the contract stays per-lane
}

@test "DOCTOR_LANES subsets the live probe loop" {
  export LEDGER_FILE="$BATS_TEST_TMPDIR/dl-ledger.md"

  # subset: exactly glm is probed. A lane-probe line is `probe  <lane>  PASS|FAIL ...` (cmd_doctor's
  # own `probe env -C`/`probe stat` tool probes and `lane <name>` presence lines never match a bare
  # lane followed by PASS/FAIL), so counting them isolates the live probe loop's iteration set.
  export DOCTOR_LANES="glm"
  run "$RUNSH" doctor --live
  [ "$status" -eq 0 ]
  [ "$(grep -Ec '^probe +(claude|codex|gemini|grok|glm|kimi) +(PASS|FAIL)' <<<"$output")" -eq 1 ]
  grep -Eq '^probe +glm +(PASS|FAIL)' <<<"$output"

  # unset = the full six-lane roster (default order: claude codex gemini grok glm kimi).
  unset DOCTOR_LANES
  run "$RUNSH" doctor --live
  [ "$status" -eq 0 ]
  [ "$(grep -Ec '^probe +(claude|codex|gemini|grok|glm|kimi) +(PASS|FAIL)' <<<"$output")" -eq 6 ]
  for L in claude codex gemini grok glm kimi; do
    grep -Eq "^probe +$L +(PASS|FAIL)" <<<"$output"
  done
}
