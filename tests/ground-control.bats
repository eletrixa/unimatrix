#!/usr/bin/env bats
# Tests for the Ground Control lane (specs/05-ground-control.md): the zero-dependency web server
# (site/server.mjs — /health, /api/bus, /api/cost, /api/stream, /api/config, static+
# path-traversal-safe serve, read-only on the bus / allowlist-only writes to swarm.conf) and the
# auto-ensure/auto-open lib entry points in src/swarm-lib.sh (mon_web_ensure, mon_web_open).
# Every test runs against a fixture bus AND a fixture swarm.conf (copy) under $BATS_TEST_TMPDIR
# on a throwaway ephemeral port — never the real .bus, never the real swarm.conf, never port
# 4747, never systemd-run (the mon_web_ensure test only exercises the already-healthy no-op path).
#
# Project: unimatrix — multi-model swarm orchestrator driven from Claude Code
# Module:  tests/ground-control.bats
# Deps:    bats-core, site/server.mjs (node), src/swarm-lib.sh, curl, jq
# Tested:  n/a — this is the test file
#
# Key responsibilities:
# - end-to-end coverage of server.mjs API surfaces (/health /api/bus /api/cost /api/models
#   /api/stream /api/config) incl. model-family attribution + notional pricing
# - mon_web_ensure / mon_web_open no-op paths in src/swarm-lib.sh
#
# Design constraints:
# - fixture-only: throwaway bus + swarm.conf copy under $BATS_TEST_TMPDIR, ephemeral port —
#   never the real .bus, real swarm.conf, port 4747, or systemd-run

REPO="$BATS_TEST_DIRNAME/.."
LIB="$REPO/src/swarm-lib.sh"
SERVER_JS="$REPO/site/server.mjs"

setup() {
  # shellcheck source=/dev/null
  source "$LIB"

  BUS="$BATS_TEST_TMPDIR/bus"
  mkdir -p "$BUS"/{queue,claimed,done,cancelled,limits}

  # 2 queued, 1 claimed, 3 done, 0 cancelled — matches the counts this file asserts against.
  : > "$BUS/queue/a1.prompt"
  : > "$BUS/queue/a2.prompt"
  : > "$BUS/claimed/c1.claude:opus"
  : > "$BUS/done/d1"
  : > "$BUS/done/d2"
  : > "$BUS/done/d3"

  # run-w1.jsonl: 2 lines, one a claude "result" envelope with .usage numbers (site/server.mjs
  # costSummary buckets type=result+.usage under lane "claude/glm"; 50+25 = 75 nonzero tokens).
  cat > "$BUS/run-w1.jsonl" <<'JSONL'
{"type":"assistant","message":{"content":[{"text":"thinking"}]}}
{"type":"result","result":"final answer","usage":{"input_tokens":50,"output_tokens":25}}
JSONL

  # fixture swarm.conf: a COPY of the real one, so /api/config tests never touch the repo's own.
  # EXEC_CHAIN is pinned to a known value right after the copy — a real swarm can be running
  # concurrently against the repo's actual swarm.conf (e.g. via the cockpit's settings drawer),
  # which would otherwise make the exact-value assertions below flaky.
  CONF="$BATS_TEST_TMPDIR/swarm.conf"
  cp "$REPO/swarm.conf" "$CONF"
  sed -i "s|^EXEC_CHAIN=.*|EXEC_CHAIN=\"grok:grok-4.5 glm:glm-5.2 claude:haiku\"  # space-separated lane:model fallback chain, left to right|" "$CONF"

  SERVER_PID=""
}

teardown() {
  if [ -n "${SERVER_PID:-}" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  return 0
}

# _free_port — an ephemeral port derived from this shell's pid + the bats test number, never the
# real cockpit's port 4747 (docs/02-build-pitfalls.md-style hermeticity: no fixed port to collide
# on across parallel bats runs).
_free_port() {
  echo $(( 20000 + ( ($$ + ${BATS_TEST_NUMBER:-0} * 97) % 9000 ) ))
}

# _start_server — boots site/server.mjs against the fixture bus on a free port, polls /health up
# to 5s. Sets $PORT and $SERVER_PID for the calling test; teardown() kills $SERVER_PID.
_start_server() {
  PORT="$(_free_port)"
  BUSDIR="$BUS" PORT="$PORT" SWARM_CONF="$CONF" node "$SERVER_JS" >/dev/null 2>&1 &
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

# --- server: /health ----------------------------------------------------------

@test "server: GET /health returns ok:true and the busdir" {
  _start_server
  run curl -fsS "http://127.0.0.1:$PORT/health"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"ok":true'* ]]
  [[ "$output" == *"$BUS"* ]]
}

# --- server: /api/bus -----------------------------------------------------------

@test "server: GET /api/bus counts match the fixture bus (2 queued, 1 claimed, 3 done, 0 cancelled)" {
  _start_server
  run curl -fsS "http://127.0.0.1:$PORT/api/bus"
  [ "$status" -eq 0 ]
  echo "$output" > "$BATS_TEST_TMPDIR/bus.json"

  [ "$(jq -r '.counts.queued' "$BATS_TEST_TMPDIR/bus.json")" = "2" ]
  [ "$(jq -r '.counts.claimed' "$BATS_TEST_TMPDIR/bus.json")" = "1" ]
  [ "$(jq -r '.counts.done' "$BATS_TEST_TMPDIR/bus.json")" = "3" ]
  [ "$(jq -r '.counts.cancelled' "$BATS_TEST_TMPDIR/bus.json")" = "0" ]
}

@test "server: /api/bus queued count counts only *.prompt — .lane/.write sidecars don't inflate it" {
  echo "gemini:gemini-3-flash" > "$BUS/queue/a1.lane"
  echo "/tmp/target" > "$BUS/queue/a1.write"
  _start_server
  run curl -fsS "http://127.0.0.1:$PORT/api/bus"
  [ "$status" -eq 0 ]
  # still 2 units of work (a1, a2), not 4 — matches gate_count / the tmux board
  [ "$(jq -r '.counts.queued' <<<"$output")" = "2" ]
}

# --- server: /api/cost -----------------------------------------------------------

@test "server: GET /api/cost mentions a lane with nonzero tokens from the fixture run" {
  _start_server
  run curl -fsS "http://127.0.0.1:$PORT/api/cost"
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude"* || "$output" == *"glm"* ]]
  [[ "$output" =~ [1-9][0-9]* ]]
}

@test "server: /api/cost buckets codex (turn.completed) and gemini (stats.models) lanes too" {
  printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":30,"output_tokens":7}}' > "$BUS/run-cx.jsonl"
  printf '%s\n' '{"type":"result","stats":{"models":{"gemini-3.5-flash":{"tokens":{"input":11,"output":4}}}},"status":"ok"}' > "$BUS/run-ge.jsonl"
  _start_server
  run curl -fsS "http://127.0.0.1:$PORT/api/cost"
  [ "$status" -eq 0 ]
  echo "$output" > "$BATS_TEST_TMPDIR/cost.json"
  # codex bucket = top-level usage sum 37 (matches swarm-mon.sh _cost_summary, not a deep recurse)
  [ "$(jq -r '.lanes[] | select(.lane=="codex") | .tokens' "$BATS_TEST_TMPDIR/cost.json")" = "37" ]
  # a gemini:<model> bucket exists with the summed stats.models leaves (11+4)
  [ "$(jq -r '.lanes[] | select(.lane|startswith("gemini:")) | .tokens' "$BATS_TEST_TMPDIR/cost.json")" = "15" ]
}

@test "server: /api/models attributes tokens to the carried model family, prices notionally, and windows by time" {
  local now old
  now="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
  old="$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S.000Z)"
  # fresh sonnet run: assistant carries the model, the result carries the usage (1M input, notional $3)
  {
    printf '%s\n' "{\"type\":\"assistant\",\"timestamp\":\"$now\",\"message\":{\"model\":\"claude-sonnet-5\",\"content\":[{\"type\":\"text\",\"text\":\"hi\"}]}}"
    printf '%s\n' "{\"type\":\"result\",\"timestamp\":\"$now\",\"usage\":{\"input_tokens\":1000000,\"output_tokens\":0}}"
  } > "$BUS/run-sn.jsonl"
  # old opus run: same shape but an hour ago — counts to total, NOT to the 5-min window
  {
    printf '%s\n' "{\"type\":\"assistant\",\"timestamp\":\"$old\",\"message\":{\"model\":\"claude-opus-4-8\",\"content\":[{\"type\":\"text\",\"text\":\"hi\"}]}}"
    printf '%s\n' "{\"type\":\"result\",\"timestamp\":\"$old\",\"usage\":{\"input_tokens\":1000000,\"output_tokens\":0}}"
  } > "$BUS/run-op.jsonl"
  _start_server
  run curl -fsS "http://127.0.0.1:$PORT/api/models"
  [ "$status" -eq 0 ]
  echo "$output" > "$BATS_TEST_TMPDIR/models.json"
  [ "$(jq -r '.notional' "$BATS_TEST_TMPDIR/models.json")" = "true" ]
  [ "$(jq -r '.window_min' "$BATS_TEST_TMPDIR/models.json")" = "5" ]
  # sonnet: in-window, priced at $3/Mtok input ⇒ dollars_5m ≈ 3, per_hour = dollars_5m*12
  [ "$(jq -r '.models[] | select(.model=="claude-sonnet") | .tokens_5m' "$BATS_TEST_TMPDIR/models.json")" = "1000000" ]
  [ "$(jq -r '.models[] | select(.model=="claude-sonnet") | (.dollars_5m > 2.9 and .dollars_5m < 3.1)' "$BATS_TEST_TMPDIR/models.json")" = "true" ]
  [ "$(jq -r '.models[] | select(.model=="claude-sonnet") | ((.dollars_per_hour - (.dollars_5m*12))|fabs < 0.001)' "$BATS_TEST_TMPDIR/models.json")" = "true" ]
  # opus: counted in total but the hour-old event is OUT of the 5-min window
  [ "$(jq -r '.models[] | select(.model=="claude-opus") | .tokens_total' "$BATS_TEST_TMPDIR/models.json")" = "1000000" ]
  [ "$(jq -r '.models[] | select(.model=="claude-opus") | .tokens_5m' "$BATS_TEST_TMPDIR/models.json")" = "0" ]
  [ "$(jq -r '.models[] | select(.model=="claude-opus") | .dollars_per_hour' "$BATS_TEST_TMPDIR/models.json")" = "0" ]
}

@test "server: /api/models extracts the grok model from the end event's modelUsage key and prices it" {
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
  # grok stream events carry no model field; the served model is the first KEY of end.modelUsage
  printf '%s\n' "{\"type\":\"end\",\"timestamp\":\"$now\",\"modelUsage\":{\"grok-4.5-build\":{\"tokens\":1000000}},\"usage\":{\"input_tokens\":1000000,\"output_tokens\":0}}" > "$BUS/run-gk.jsonl"
  _start_server
  run curl -fsS "http://127.0.0.1:$PORT/api/models"
  [ "$status" -eq 0 ]
  echo "$output" > "$BATS_TEST_TMPDIR/models.json"
  [ "$(jq -r '.models[] | select(.model=="grok") | .tokens_5m' "$BATS_TEST_TMPDIR/models.json")" = "1000000" ]
  [ "$(jq -r '.models[] | select(.model=="grok") | .unpriced' "$BATS_TEST_TMPDIR/models.json")" = "false" ]
  # notional $3/Mtok input
  [ "$(jq -r '.models[] | select(.model=="grok") | (.dollars_5m > 2.9 and .dollars_5m < 3.1)' "$BATS_TEST_TMPDIR/models.json")" = "true" ]
}

@test "server: /api/models normalizes claude-fable-5 to the claude-fable family and prices it" {
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
  {
    printf '%s\n' "{\"type\":\"assistant\",\"timestamp\":\"$now\",\"message\":{\"model\":\"claude-fable-5\",\"content\":[{\"type\":\"text\",\"text\":\"hi\"}]}}"
    printf '%s\n' "{\"type\":\"result\",\"timestamp\":\"$now\",\"usage\":{\"input_tokens\":1000000,\"output_tokens\":0}}"
  } > "$BUS/run-fb.jsonl"
  _start_server
  run curl -fsS "http://127.0.0.1:$PORT/api/models"
  [ "$status" -eq 0 ]
  echo "$output" > "$BATS_TEST_TMPDIR/models.json"
  [ "$(jq -r '.models[] | select(.model=="claude-fable") | .tokens_5m' "$BATS_TEST_TMPDIR/models.json")" = "1000000" ]
  [ "$(jq -r '.models[] | select(.model=="claude-fable") | .unpriced' "$BATS_TEST_TMPDIR/models.json")" = "false" ]
  # notional $10/Mtok input
  [ "$(jq -r '.models[] | select(.model=="claude-fable") | (.dollars_5m > 9.9 and .dollars_5m < 10.1)' "$BATS_TEST_TMPDIR/models.json")" = "true" ]
}

@test "server: /api/models normalizes kimi-k3 to the kimi family and prices it" {
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
  {
    printf '%s\n' "{\"type\":\"assistant\",\"timestamp\":\"$now\",\"message\":{\"model\":\"kimi-k3\",\"content\":[{\"type\":\"text\",\"text\":\"hi\"}]}}"
    printf '%s\n' "{\"type\":\"result\",\"timestamp\":\"$now\",\"usage\":{\"input_tokens\":1000000,\"output_tokens\":0}}"
  } > "$BUS/run-ki.jsonl"
  _start_server
  run curl -fsS "http://127.0.0.1:$PORT/api/models"
  [ "$status" -eq 0 ]
  echo "$output" > "$BATS_TEST_TMPDIR/models.json"
  [ "$(jq -r '.models[] | select(.model=="kimi") | .tokens_5m' "$BATS_TEST_TMPDIR/models.json")" = "1000000" ]
  [ "$(jq -r '.models[] | select(.model=="kimi") | .unpriced' "$BATS_TEST_TMPDIR/models.json")" = "false" ]
  # notional $3/Mtok input (Moonshot kimi-k3 list price)
  [ "$(jq -r '.models[] | select(.model=="kimi") | (.dollars_5m > 2.9 and .dollars_5m < 3.1)' "$BATS_TEST_TMPDIR/models.json")" = "true" ]
}

@test "server: /api/models buckets a model-less turn.completed as codex, and an unknown as unpriced" {
  printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":300,"output_tokens":7}}' > "$BUS/run-cx.jsonl"
  printf '%s\n' '{"type":"end","usage":{"input_tokens":100,"output_tokens":10,"total_tokens":110}}' > "$BUS/run-uk.jsonl"
  _start_server
  run curl -fsS "http://127.0.0.1:$PORT/api/models"
  [ "$status" -eq 0 ]
  echo "$output" > "$BATS_TEST_TMPDIR/models.json"
  # no model string on a turn.completed ⇒ codex fallback (priced)
  [ "$(jq -r '.models[] | select(.model=="codex") | .unpriced' "$BATS_TEST_TMPDIR/models.json")" = "false" ]
  # no model + not turn.completed ⇒ unknown, flagged unpriced (never silently $0-as-free)
  [ "$(jq -r '.models[] | select(.model=="unknown") | .unpriced' "$BATS_TEST_TMPDIR/models.json")" = "true" ]
  [ "$(jq -r '.models[] | select(.model=="unknown") | .dollars_per_hour' "$BATS_TEST_TMPDIR/models.json")" = "0" ]
}

@test "server: /api/models tolerates a malformed line without crashing (HTTP 200, best-effort)" {
  printf '%s\n' 'this is not json {{{' > "$BUS/run-bad.jsonl"
  printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":30,"output_tokens":7}}' >> "$BUS/run-bad.jsonl"
  _start_server
  run curl -fsS "http://127.0.0.1:$PORT/api/models"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"codex"'* ]]
}

@test "server: /api/stream envelope carries a server receive-time ts for the firehose clock" {
  _start_server
  run curl -fsS --max-time 3 "http://127.0.0.1:$PORT/api/stream"
  # SSE never closes; --max-time makes curl exit 28 after collecting the buffered fixture lines
  echo "$output" > "$BATS_TEST_TMPDIR/stream.txt"
  grep -q '"ts":[0-9]' "$BATS_TEST_TMPDIR/stream.txt"
}

@test "server: /api/bus derived fields (stale_leases, active_limits, parked, done) reflect the bus" {
  # age the claimed lease past LEASE_MIN (default 15m) so it counts as stale
  touch -d "-30 minutes" "$BUS/claimed/c1.claude:opus"
  printf '18000' > "$BUS/limits/glm.limited"
  : > "$BUS/limits/pin9.parked"
  _start_server
  run curl -fsS "http://127.0.0.1:$PORT/api/bus"
  [ "$status" -eq 0 ]
  echo "$output" > "$BATS_TEST_TMPDIR/bus2.json"
  [ "$(jq -r '.stale_leases | index("c1.claude:opus") | type' "$BATS_TEST_TMPDIR/bus2.json")" = "number" ]
  [ "$(jq -r '.active_limits | index("glm") | type' "$BATS_TEST_TMPDIR/bus2.json")" = "number" ]
  [ "$(jq -r '.parked | index("pin9") | type' "$BATS_TEST_TMPDIR/bus2.json")" = "number" ]
  [ "$(jq -r '.done | length' "$BATS_TEST_TMPDIR/bus2.json")" -ge 3 ]
}

# --- server: /api/config -----------------------------------------------------------

@test "server: GET /api/config returns EXEC_CHAIN from the fixture swarm.conf" {
  _start_server
  run curl -fsS "http://127.0.0.1:$PORT/api/config"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.EXEC_CHAIN' <<<"$output")" = "grok:grok-4.5 glm:glm-5.2 claude:haiku" ]
}

@test "server: POST /api/config with a valid FANOUT change persists to swarm.conf and the response reflects it" {
  _start_server
  run curl -fsS -X POST -H 'Content-Type: application/json' -d '{"key":"FANOUT","value":"7"}' \
    "http://127.0.0.1:$PORT/api/config"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.FANOUT' <<<"$output")" = "7" ]
  grep -qE '^FANOUT=7' "$CONF"
}

@test "server: POST /api/config rejects a non-allowlisted key (400)" {
  _start_server
  run curl -s -o "$BATS_TEST_TMPDIR/cfg.out" -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' -d '{"key":"PLAN","value":"codex"}' \
    "http://127.0.0.1:$PORT/api/config"
  [ "$output" = "400" ]
  ! grep -q '^PLAN=codex' "$CONF"
}

@test "server: POST /api/config rejects a malformed EXEC_CHAIN value (400)" {
  _start_server
  run curl -s -o "$BATS_TEST_TMPDIR/cfg2.out" -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' -d '{"key":"EXEC_CHAIN","value":"not-a-lane-chain"}' \
    "http://127.0.0.1:$PORT/api/config"
  [ "$output" = "400" ]
  grep -q '^EXEC_CHAIN="grok:grok-4.5 glm:glm-5.2 claude:haiku"' "$CONF"
}

@test "server: POST /api/config preserves comments and other lines in swarm.conf" {
  _start_server
  curl -fsS -X POST -H 'Content-Type: application/json' -d '{"key":"BUDGET_USD","value":"5"}' \
    "http://127.0.0.1:$PORT/api/config" >/dev/null
  grep -qE '^BUDGET_USD=5\s+# loop/run budget cap in USD; 0 = no cap' "$CONF"
  grep -q '^PLAN=fable' "$CONF"
  grep -q '^# swarm.conf' "$CONF"
}

@test "server: POST /api/config with an Object.prototype key (toString) is rejected, not a crash" {
  _start_server
  run curl -s -o "$BATS_TEST_TMPDIR/cfg3.out" -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' -d '{"key":"toString","value":"x"}' \
    "http://127.0.0.1:$PORT/api/config"
  [ "$output" = "400" ]
  # the process must still be alive and answering afterwards
  run curl -fsS "http://127.0.0.1:$PORT/health"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"ok":true'* ]]
}

@test "server: POST /api/config from a foreign Origin is rejected (403), same-origin/no-Origin still works" {
  _start_server
  run curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
    -H 'Origin: http://evil.example' -d '{"key":"FANOUT","value":"3"}' \
    "http://127.0.0.1:$PORT/api/config"
  [ "$output" = "403" ]
  ! grep -qE '^FANOUT=3' "$CONF"

  run curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
    -H "Origin: http://localhost:$PORT" -d '{"key":"FANOUT","value":"3"}' \
    "http://127.0.0.1:$PORT/api/config"
  [ "$output" = "200" ]
  grep -qE '^FANOUT=3' "$CONF"
}

@test "server: POST /api/config rejects a leading-zero FANOUT (\"08\") and a zero FANOUT (\"0\")" {
  _start_server
  run curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
    -d '{"key":"FANOUT","value":"08"}' "http://127.0.0.1:$PORT/api/config"
  [ "$output" = "400" ]
  run curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
    -d '{"key":"FANOUT","value":"0"}' "http://127.0.0.1:$PORT/api/config"
  [ "$output" = "400" ]
}

@test "server: POST /api/config accepts a decimal BUDGET_USD (1.5)" {
  _start_server
  run curl -fsS -X POST -H 'Content-Type: application/json' -d '{"key":"BUDGET_USD","value":"1.5"}' \
    "http://127.0.0.1:$PORT/api/config"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.BUDGET_USD' <<<"$output")" = "1.5" ]
  grep -qE '^BUDGET_USD=1\.5' "$CONF"
}

# --- server: /api/stream (SSE) ----------------------------------------------------

@test "server: GET /api/stream emits a fixture line from run-w1.jsonl" {
  _start_server
  local out="$BATS_TEST_TMPDIR/stream.out"
  curl -N -s --max-time 3 "http://127.0.0.1:$PORT/api/stream" > "$out" || true
  run grep -F "final answer" "$out"
  [ "$status" -eq 0 ]
}

@test "server: /api/stream emits a record written across two flushes as ONE record, never two fragments" {
  _start_server
  local out="$BATS_TEST_TMPDIR/stream-split.out"
  # simulate tee flushing mid-record: first half lands with no newline, a poll tick (500ms) later
  # the rest arrives — the poller must NOT consume the fragment and advance past it
  ( sleep 1; printf '{"type":"result","result":"split-reco' >> "$BUS/run-w1.jsonl"
    sleep 1; printf 'rd-token"}\n' >> "$BUS/run-w1.jsonl" ) &
  local writer=$!
  curl -N -s --max-time 4 "http://127.0.0.1:$PORT/api/stream" > "$out" || true
  wait "$writer" 2>/dev/null || true
  # pre-fix the record arrived as two garbage halves ('…split-reco' / 'rd-token"}') and the
  # reassembled token never appeared anywhere in the stream
  run grep -F 'split-record-token' "$out"
  [ "$status" -eq 0 ]
}

@test "server: /api/stream re-streams a run file that was truncated and rewritten (same-id failover re-run)" {
  _start_server
  local out="$BATS_TEST_TMPDIR/stream-trunc.out"
  # FR-6 failover re-runs the same id; tee (no -a) truncates run-w1.jsonl and writes fresh,
  # SMALLER output — the byte cursor must reset like tail -F does on rotation
  ( sleep 1; printf '{"type":"result","result":"second-attempt"}\n' > "$BUS/run-w1.jsonl" ) &
  local writer=$!
  curl -N -s --max-time 4 "http://127.0.0.1:$PORT/api/stream" > "$out" || true
  wait "$writer" 2>/dev/null || true
  # pre-fix `st.size <= sent` skipped the shrunken file forever — the whole re-run never streamed
  run grep -F 'second-attempt' "$out"
  [ "$status" -eq 0 ]
}

# --- server: static serving --------------------------------------------------------

@test "server: GET / serves the site's index.html" {
  _start_server
  run curl -fsS "http://127.0.0.1:$PORT/"
  [ "$status" -eq 0 ]
  [[ "$output" == *"UNIMATRIX"* ]]
}

@test "server: rejects a foreign Host header (DNS-rebinding guard) but allows localhost" {
  _start_server
  # a browser rebound to 127.0.0.1 would carry the attacker's Host — must be refused
  run curl -s -o /dev/null -w '%{http_code}' -H "Host: evil.example.com" "http://127.0.0.1:$PORT/api/bus"
  [ "$output" = "403" ]
  # the normal loopback Host is still allowed
  run curl -s -o /dev/null -w '%{http_code}' -H "Host: localhost:$PORT" "http://127.0.0.1:$PORT/api/bus"
  [ "$output" = "200" ]
}

# --- server: path traversal -----------------------------------------------------

@test "server: path traversal request does not leak file contents" {
  _start_server
  # literal ../ is normalized away by WHATWG URL before the app-level guard ever runs, so the
  # payload that actually exercises the guard is the percent-encoded slash (%2F) — decoded after
  # URL parsing, reintroducing the traversal.
  run curl -s -o "$BATS_TEST_TMPDIR/traversal.out" -w '%{http_code}' --path-as-is \
    "http://127.0.0.1:$PORT/..%2F..%2F..%2Fetc%2Fpasswd"
  [ "$output" = "403" ]
  run cat "$BATS_TEST_TMPDIR/traversal.out"
  [[ "$output" != *"root:"* ]]
}

# --- server: strictly read-only on the bus --------------------------------------

@test "server: fixture bus tree is unchanged after a battery of requests (read-only)" {
  _start_server
  local before="$BATS_TEST_TMPDIR/before.tree"
  local after="$BATS_TEST_TMPDIR/after.tree"
  # mtime/inode/size, not just pathnames (specs/05-ground-control.md line 118-119) — an in-place
  # mutation of an existing file would keep the same path listing but change this.
  find "$BUS" -exec stat -c '%n %Y %i %s' {} \; | sort > "$before"

  curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null
  curl -fsS "http://127.0.0.1:$PORT/api/bus" >/dev/null
  curl -fsS "http://127.0.0.1:$PORT/api/cost" >/dev/null
  curl -N -s --max-time 1 "http://127.0.0.1:$PORT/api/stream" >/dev/null || true
  curl -fsS "http://127.0.0.1:$PORT/" >/dev/null
  curl -s --path-as-is "http://127.0.0.1:$PORT/../../../etc/passwd" >/dev/null || true

  find "$BUS" -exec stat -c '%n %Y %i %s' {} \; | sort > "$after"
  run diff "$before" "$after"
  [ "$status" -eq 0 ]
}

# --- lib: mon_web_open ------------------------------------------------------------

@test "mon_web_open: no-ops and creates no marker when MON_AUTOOPEN=0" {
  export BUSDIR="$BUS"
  export MON_AUTOOPEN=0
  run mon_web_open
  [ "$status" -eq 0 ]
  [ ! -e "$BUS/.cockpit-opened" ]
}

@test "mon_web_open: opens once per bus lifetime via MON_OPEN_CMD, marker gates the second call" {
  export BUSDIR="$BUS"
  export MON_AUTOOPEN=1
  export MON_PORT=4747
  local stub="$BATS_TEST_TMPDIR/stub-open.sh"
  local log="$BATS_TEST_TMPDIR/stub.log"
  cat > "$stub" <<STUB
#!/usr/bin/env bash
echo "\$@" >> "$log"
STUB
  chmod +x "$stub"
  export MON_OPEN_CMD="$stub"

  run mon_web_open
  [ "$status" -eq 0 ]
  [ -e "$BUS/.cockpit-opened" ]
  [ -s "$log" ]
  run cat "$log"
  [[ "$output" == *"http://localhost:4747/cockpit.html"* ]]

  : > "$log"
  run mon_web_open
  [ "$status" -eq 0 ]
  [ ! -s "$log" ]
}

# --- lib: mon_web_ensure -----------------------------------------------------------

@test "mon_web_ensure: no-ops fast and spawns nothing when MON_AUTOOPEN=0, even with no healthy server" {
  export MON_PORT="$(_free_port)"
  export MON_AUTOOPEN=0

  local before after start_ns end_ns elapsed_ms
  before="$(pgrep -f "site/server.mjs" | wc -l || true)"

  start_ns="$(date +%s%N)"
  run mon_web_ensure
  end_ns="$(date +%s%N)"

  [ "$status" -eq 0 ]
  elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
  # 8s, not 2s (2026-08-01: a ~10ms no-op blew 2s of pure fork latency under a saturated box +
  # parallel suite). The property is "did NOT sit in the probe/retry loop" — that loop takes 10s+,
  # so 8s still discriminates.
  [ "$elapsed_ms" -lt 8000 ]

  after="$(pgrep -f "site/server.mjs" | wc -l || true)"
  [ "$before" -eq "$after" ]
}

@test "mon_web_ensure: no-ops fast and spawns nothing when MON_PORT already answers healthy" {
  _start_server
  export MON_PORT="$PORT"
  export MON_AUTOOPEN=1

  local before after start_ns end_ns elapsed_ms
  before="$(pgrep -f "site/server.mjs" | wc -l)"

  start_ns="$(date +%s%N)"
  run mon_web_ensure
  end_ns="$(date +%s%N)"

  [ "$status" -eq 0 ]
  elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
  [ "$elapsed_ms" -lt 2000 ]

  after="$(pgrep -f "site/server.mjs" | wc -l)"
  [ "$before" -eq "$after" ]
}
