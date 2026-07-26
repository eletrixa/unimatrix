#!/usr/bin/env bats
# Coverage for GET /api/speedwars — the read-only evidence-ledger route behind the SPEEDWARS
# cockpit panel (specs/09-speedwars-panel.md FR-1). Every test runs against a FIXTURE ledger under
# $BATS_TEST_TMPDIR (via $SPEEDWARS_FILE) on a throwaway ephemeral port — never the real
# docs/ops/speedwars.jsonl, never the real .bus, never port 4747.
#
# Project: unimatrix — multi-model swarm orchestrator driven from Claude Code
# Module:  tests/speedwars-api.bats
# Deps:    bats-core, site/server.mjs (node), curl, jq
# Tested:  n/a — this is the test file
#
# Key responsibilities:
# - row-type split: card rows (no `type` field) vs verdict/run-meta/review/run-review buckets
# - the never-crash contract: malformed lines skipped, missing file → available:false, not 500
# - unknown future row types are dropped rather than guessed into a bucket
# - the route stays read-only (the ledger is byte-identical after a request)
#
# Design constraints:
# - fixture-only: $SPEEDWARS_FILE points at a temp ledger; the repo's real ledger is never read
# - bats files do not share helpers — _free_port / _start_server are local copies of the
#   cockpit-api.bats pattern

REPO="$BATS_TEST_DIRNAME/.."
SERVER_JS="$REPO/site/server.mjs"

setup() {
  BUS="$BATS_TEST_TMPDIR/bus"
  mkdir -p "$BUS"/{queue,claimed,done,cancelled,limits,specs,pids}
  LEDGER="$BATS_TEST_TMPDIR/speedwars.jsonl"
  SERVER_PID=""
}

teardown() {
  if [ -n "${SERVER_PID:-}" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  return 0
}

_free_port() {
  echo $(( 20000 + ( ($$ + ${BATS_TEST_NUMBER:-0} * 97) % 9000 ) ))
}

# _start_server — boots site/server.mjs against the fixture bus + fixture ledger on a free port.
# SPEEDWARS_FILE is deliberately exported even when the fixture is absent (the missing-file test).
_start_server() {
  PORT="$(_free_port)"
  BUSDIR="$BUS" PORT="$PORT" SPEEDWARS_FILE="$LEDGER" node "$SERVER_JS" >/dev/null 2>&1 &
  SERVER_PID=$!

  local tries=0
  until curl -fsS --max-time 1 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; do
    tries=$(( tries + 1 ))
    if [ "$tries" -ge 50 ]; then
      echo "server.mjs did not become healthy within 5s" >&2
      return 1
    fi
    sleep 0.1
  done
}

_seed_ledger() {
  cat > "$LEDGER" <<'JSONL'
{"ts":"2026-07-19T18:35:04Z","run":"r1","id":"c1","served_lane":"grok","outcome":"done","wall_secs":17,"cost_usd":0.086}
{"ts":"2026-07-19T18:36:24Z","run":"r1","id":"c2","served_lane":"codex","outcome":"done","wall_secs":2153}
{"ts":"2026-07-19T18:46:21Z","type":"verdict","run":"r1","id":"c1","verified":false,"reason":"false-done"}
{"ts":"2026-07-19T18:46:21Z","type":"run-meta","run":"r1","cards":2,"fanout":12}
{"ts":"2026-07-19T21:42:23Z","type":"review","run":"r1","lane":"grok","score":3,"tags":["fast"],"note":"n"}
{"ts":"2026-07-19T21:46:09Z","type":"run-review","run":"r1","speedup":3.65}
JSONL
}

@test "api-speedwars: splits rows by type; cards are the rows WITHOUT a type field" {
  _seed_ledger
  _start_server
  run curl -fsS "http://127.0.0.1:$PORT/api/speedwars"
  [ "$status" -eq 0 ]
  echo "$output" > "$BATS_TEST_TMPDIR/sw.json"

  [ "$(jq -r '.available' "$BATS_TEST_TMPDIR/sw.json")" = "true" ]
  [ "$(jq -r '.cards | length' "$BATS_TEST_TMPDIR/sw.json")" = "2" ]
  [ "$(jq -r '.verdicts | length' "$BATS_TEST_TMPDIR/sw.json")" = "1" ]
  [ "$(jq -r '.run_meta | length' "$BATS_TEST_TMPDIR/sw.json")" = "1" ]
  [ "$(jq -r '.reviews | length' "$BATS_TEST_TMPDIR/sw.json")" = "1" ]
  [ "$(jq -r '.run_reviews | length' "$BATS_TEST_TMPDIR/sw.json")" = "1" ]

  # card payload survives verbatim (the panel aggregates client-side — FR-2)
  [ "$(jq -r '.cards[0].id' "$BATS_TEST_TMPDIR/sw.json")" = "c1" ]
  [ "$(jq -r '.cards[0].wall_secs' "$BATS_TEST_TMPDIR/sw.json")" = "17" ]
  # absent cost stays absent — never coerced to 0 (FR-7: codex is not billed here)
  [ "$(jq -r '.cards[1] | has("cost_usd")' "$BATS_TEST_TMPDIR/sw.json")" = "false" ]
}

@test "api-speedwars: malformed and blank lines are skipped, not fatal" {
  printf '%s\n' \
    '{"ts":"2026-07-19T18:35:04Z","run":"r1","id":"ok","served_lane":"glm","outcome":"done"}' \
    'not json at all' \
    '{"truncated":' \
    '' \
    '{"ts":"2026-07-19T18:46:21Z","type":"verdict","run":"r1","id":"ok","verified":true}' \
    > "$LEDGER"

  _start_server
  run curl -fsS "http://127.0.0.1:$PORT/api/speedwars"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.cards | length')" = "1" ]
  [ "$(echo "$output" | jq -r '.verdicts | length')" = "1" ]
}

@test "api-speedwars: unknown row types are dropped, never bucketed as cards" {
  printf '%s\n' \
    '{"ts":"2026-07-19T18:35:04Z","type":"some-future-row","run":"r1","id":"x"}' \
    '{"ts":"2026-07-19T18:35:05Z","run":"r1","id":"real","served_lane":"glm","outcome":"done"}' \
    > "$LEDGER"

  _start_server
  run curl -fsS "http://127.0.0.1:$PORT/api/speedwars"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.cards | length')" = "1" ]
  [ "$(echo "$output" | jq -r '.cards[0].id')" = "real" ]
}

@test "api-speedwars: missing ledger yields available:false with empty collections, not 500" {
  [ ! -f "$LEDGER" ]
  _start_server
  run curl -fsS "http://127.0.0.1:$PORT/api/speedwars"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.available')" = "false" ]
  [ "$(echo "$output" | jq -r '.cards | length')" = "0" ]
  [ "$(echo "$output" | jq -r '.run_reviews | length')" = "0" ]
}

@test "api-speedwars: route is read-only — the ledger is byte-identical after a request" {
  _seed_ledger
  local before after
  before="$(md5sum < "$LEDGER")"
  _start_server
  run curl -fsS "http://127.0.0.1:$PORT/api/speedwars"
  [ "$status" -eq 0 ]
  after="$(md5sum < "$LEDGER")"
  [ "$before" = "$after" ]
}
