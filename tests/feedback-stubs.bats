#!/usr/bin/env bats
# Unit tests for feedback_stubs (spec 12 FR-4): auto-drafted feedback/ stubs generated from
# DURABLE bus surfaces only — limits/ flag files and this run's own speedwars ledger rows — never
# from res-*/run-*/prompt-* worker-output CONTENT. Scrub-by-construction is asserted directly: a
# canary string planted in every worker-output surface must leak into NO generated stub.
#
# Project: unimatrix — multi-model swarm orchestrator driven from Claude Code
# Module:  tests/feedback-stubs.bats
# Deps:    bats-core, src/swarm-lib.sh
# Tested:  n/a — this is the test file

setup() {
  LIB="$BATS_TEST_DIRNAME/../src/swarm-lib.sh"
  # shellcheck source=/dev/null
  source "$LIB"
  # BUS sits one level below FBDIR's parent (both under $BATS_TEST_TMPDIR) so the default
  # (no-FEEDBACK_DIR-override) target dir ($BATS_TEST_TMPDIR/work/feedback) is a DIFFERENT path
  # from FBDIR ($BATS_TEST_TMPDIR/feedback) — otherwise the "no-op when the target dir is absent"
  # test below would find FBDIR already `mkdir -p`'d here and false-pass.
  BUS="$BATS_TEST_TMPDIR/work/bus"
  FBDIR="$BATS_TEST_TMPDIR/feedback"
  mkdir -p "$FBDIR"
  export FEEDBACK_DIR="$FBDIR"
  bus_init "$BUS"
}

# _seed_bus — a fake bus with three durable failure surfaces (a parked card, a dead lane, and a
# speedwars ledger row recording a timeout), plus a canary string planted in every worker-output
# surface feedback_stubs must never read — a leak into any stub fails the scrub-by-construction
# test at the bottom of this file.
_seed_bus() {
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw.jsonl" SPEEDWARS_RUN="fb-run"
  touch "$BUS/limits/x.parked"
  touch "$BUS/limits/grok.dead"
  printf '{"ts":"2026-07-25T00:00:00Z","run":"fb-run","id":"t1","requested":"claude:opus","served_lane":"claude","outcome":"timeout","class":"timeout-watchdog"}\n' >> "$SPEEDWARS_FILE"
  printf 'CANARY-DO-NOT-LEAK' > "$BUS/res-c1.txt"
  printf '{"type":"result","result":"CANARY-DO-NOT-LEAK"}\n' > "$BUS/run-c1.jsonl"
  printf 'CANARY-DO-NOT-LEAK' > "$BUS/run-c1.jsonl.stderr"
}

@test "feedback_stubs: writes one draft stub per detected class (parked, lane-down, timeout)" {
  _seed_bus
  feedback_stubs "$BUS"

  local files; files=("$FBDIR"/*-auto-*.md)
  [ "${#files[@]}" -eq 3 ]
  [ -n "$(find "$FBDIR" -maxdepth 1 -name '*-auto-parked.md')" ]
  [ -n "$(find "$FBDIR" -maxdepth 1 -name '*-auto-lane-down.md')" ]
  [ -n "$(find "$FBDIR" -maxdepth 1 -name '*-auto-timeout.md')" ]
}

@test "feedback_stubs: frontmatter carries status: draft plus the drop-box schema keys" {
  _seed_bus
  feedback_stubs "$BUS"

  local f; f="$(find "$FBDIR" -maxdepth 1 -name '*-auto-parked.md')"
  [ -n "$f" ]
  run grep -c '^status: draft$' "$f"; [ "$output" = "1" ]
  run grep -c '^source: ' "$f"; [ "$output" = "1" ]
  run grep -c '^date: ' "$f"; [ "$output" = "1" ]
  run grep -c '^run: fb-run$' "$f"; [ "$output" = "1" ]
  run grep -c '^type: bug$' "$f"; [ "$output" = "1" ]
  run grep -c '^severity: major$' "$f"; [ "$output" = "1" ]
}

@test "feedback_stubs: timeout/unusable classes are severity minor, parked/lane-down/loop-halted are major" {
  _seed_bus
  feedback_stubs "$BUS"

  run grep '^severity:' "$FBDIR"/*-auto-timeout.md
  [ "$output" = "severity: minor" ]
}

@test "feedback_stubs: idempotent — a second call on the same run writes no new/duplicate files" {
  _seed_bus
  feedback_stubs "$BUS"
  local before; before="$(find "$FBDIR" -maxdepth 1 -name '*.md' | sort)"

  feedback_stubs "$BUS"
  local after; after="$(find "$FBDIR" -maxdepth 1 -name '*.md' | sort)"
  [ "$before" = "$after" ]
}

@test "feedback_stubs: skips a class whose file already exists in feedback/archive/" {
  _seed_bus
  mkdir -p "$FBDIR/archive"
  local repo; repo="$(basename "$(dirname "$BUS")")"
  local today; today="$(date -u +%F)"
  : > "$FBDIR/archive/$today-$repo-fb-run-auto-parked.md"

  feedback_stubs "$BUS"

  [ ! -e "$FBDIR/$today-$repo-fb-run-auto-parked.md" ]
  [ -n "$(find "$FBDIR" -maxdepth 1 -name '*-auto-lane-down.md')" ]
}

@test "feedback_stubs: an extra-class arg (loop-halted) gets its own draft stub, severity major" {
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-lh.jsonl" SPEEDWARS_RUN="lh-run"

  feedback_stubs "$BUS" loop-halted

  [ -n "$(find "$FBDIR" -maxdepth 1 -name '*-auto-loop-halted.md')" ]
  run grep '^severity:' "$FBDIR"/*-auto-loop-halted.md
  [ "$output" = "severity: major" ]
}

@test "feedback_stubs: FEEDBACK_AUTO=0 disables all stub generation" {
  _seed_bus
  FEEDBACK_AUTO=0 feedback_stubs "$BUS"
  [ -z "$(find "$FBDIR" -maxdepth 1 -name '*.md')" ]
}

@test "feedback_stubs: no-op (never scaffolds feedback/ into an arbitrary parent) when the target dir doesn't exist" {
  _seed_bus
  unset FEEDBACK_DIR
  # repo_root falls back to dirname(busdir) ($BATS_TEST_TMPDIR/work — not a git repo under bats
  # tmp) whose /feedback subdir was never created — this must be a silent no-op, not a scaffold.
  feedback_stubs "$BUS"
  [ ! -e "$(dirname "$BUS")/feedback" ]
}

@test "feedback_stubs: scrub-by-construction — a canary planted in res-*.txt/run-*.jsonl/.stderr leaks into NO stub" {
  _seed_bus
  feedback_stubs "$BUS"

  run grep -rl 'CANARY-DO-NOT-LEAK' "$FBDIR"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

# --- wave-0 audit guard: every archived feedback item in the REAL repo carries triaged-to: -------

@test "repo audit: every feedback/archive/*.md file carries a triaged-to: frontmatter key" {
  local real_archive="$BATS_TEST_DIRNAME/../feedback/archive" f
  local -a missing=()
  for f in "$real_archive"/*.md; do
    grep -q '^triaged-to:' "$f" || missing+=("$f")
  done
  [ "${#missing[@]}" -eq 0 ]
}
