#!/usr/bin/env bats
# RED-wave driver tests for spec 21 FR-10 (claim stamp) — NONE of this behavior exists in
# swarm-run.sh / src/swarm-lib.sh yet: _try_claim_one never writes limits/<id>.claimed-at, and
# speed_row emits no claim_ts / queue_wait_secs keys. Every test below drives swarm-run.sh full
# mode over PATH-shimmed fake CLIs (no real API calls) and asserts the speedwars attempt row
# carries the two new additive keys + the stamp is consumed — so each MUST currently fail on the
# claim_ts/queue_wait_secs assertion, not on a harness error. The run itself completes today;
# only the new-key assertions are RED.
#
# Project: unimatrix — multi-model swarm orchestrator driven from Claude Code
# Module:  tests/claim-stamp.bats
# Deps:    bats-core, src/swarm-lib.sh, swarm-run.sh, fake claude/codex/gemini/grok/docker/curl on PATH
# Tested:  n/a — this is the test file
#
# Key responsibilities:
# - FR-10: limits/<id>.claimed-at is written on claim and CONSUMED (rm'd) into the done row
# - FR-10: speed_row emits ADDITIVE claim_ts (ISO) + queue_wait_secs (numeric, >= 0) — existing
#   keys (ts/id/wall_secs) survive alongside them (nothing renamed/dropped)
# - FR-10: a re-queued card gets a FRESH stamp on its next claim (the retry's done row carries it)
#
# Design constraints:
# - Fakes read their behavior from $BIN/fake.conf (sourced via ${BASH_SOURCE[0]}'s own dirname),
#   NOT from inherited env vars — lane_cmd wraps every real invocation in `env -i` (containment),
#   which would otherwise strip every FAKE_* knob. Tests call `_fake NAME value`, not export.
# - SPEEDWARS_FILE + LEDGER_FILE both point into $BATS_TEST_TMPDIR so no row ever lands in the
#   repo's real docs/ops (run_summary also appends a trailing run-summary row to SPEEDWARS_FILE;
#   every jq assertion selects select(.id=="<id>") so that trailer never shadows the card row).

RUNSH="$BATS_TEST_DIRNAME/../swarm-run.sh"

setup() {
  BUS="$BATS_TEST_TMPDIR/bus"
  CONF="$BATS_TEST_TMPDIR/swarm.conf"
  BIN="$BATS_TEST_TMPDIR/bin"
  SW="$BATS_TEST_TMPDIR/speedwars.jsonl"
  mkdir -p "$BIN"
  export PATH="$BIN:$PATH"
  export BUSDIR="$BUS"
  export CONF
  export HEARTBEAT_SEC=1
  # full_run calls mon_web_ensure/mon_web_open (specs/05-ground-control.md) — default
  # MON_AUTOOPEN=1/MON_PORT=4747 would probe/spawn against the REAL port 4747 and the real .bus
  # default. Disable; ground-control.bats covers that surface in isolation on throwaway ports.
  export MON_AUTOOPEN=0
  # _scratch_home (src/swarm-lib.sh) reads $HOME/.claude, $HOME/.codex — never let a test touch
  # the real user's actual credentials; every test gets its own throwaway "real" home instead.
  export HOME="$BATS_TEST_TMPDIR/realhome"
  mkdir -p "$HOME"
  # _scratch_home also honors CLAUDE_CONFIG_DIR (multi-account setups) — unset so this box's own
  # ambient session dir never leaks real credentials into a test's throwaway scratch home.
  unset CLAUDE_CONFIG_DIR
  # spec 13 FR-1: env_master_preflight aborts a run whose lane set touches gemini/glm/kimi if
  # $ENV_MASTER_FILE is unreadable. Give every test a working default (all three keys present) so
  # the retry test's glm lane keeps working out of the box; a test wanting the missing-file
  # scenario overrides ENV_MASTER_FILE itself afterward (last export wins).
  printf 'Z_AI_CODING_KEY=default-glm-key\nMOONSHOT_API_KEY=default-kimi-key\nGEMINI_API_KEY=default-gem-key\n' \
    > "$BATS_TEST_TMPDIR/envmaster-default"
  export ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster-default"
  # spec 13 FR-6: auto live-probes default ON for operators — OFF for this suite (env outranks
  # conf per FR-1), or every test would fire a probe per lane (extra fake invocations + rows into
  # the real docs/ops file for tests that don't pin LEDGER_FILE). These tests aren't about probes.
  export PROBE_AUTO=0
  # FR-10's evidence lands in the speedwars ledger — point it at a tmp path (the surface asserted
  # below). LEDGER_FILE too, so the llm-runs ledger never touches the repo's real docs/ops.
  export SPEEDWARS_FILE="$SW"
  export LEDGER_FILE="$BATS_TEST_TMPDIR/llm-runs.md"
  BG_PIDS=()
  _install_fakes
}

teardown() {
  local p
  for p in "${BG_PIDS[@]:-}"; do
    [ -n "$p" ] && kill -9 "$p" 2>/dev/null
    [ -n "$p" ] && wait "$p" 2>/dev/null
  done
  # belt-and-braces: nothing from this test's bus/bin markers should survive it
  pkill -9 -f "$BATS_TEST_TMPDIR" 2>/dev/null || true
  return 0
}

# _fake <NAME> <value> — appends NAME="value" to $BIN/fake.conf (bash-%q-escaped), which every
# fake CLI sources on its own via ${BASH_SOURCE[0]}'s dirname. This is a FILE, not an env var, on
# purpose: it must survive lane_cmd's `env -i` wrapping around the real invocation.
_fake() { printf '%s=%q\n' "$1" "$2" >> "$BIN/fake.conf"; }

# Fake claude (also serves the GLM and kimi lanes, which re-invoke `claude -p` under a swapped env).
# Knobs (set via `_fake NAME value`): FAKE_CLAUDE_RESULT, FAKE_CLAUDE_EXIT, FAKE_CLAUDE_DELAY
# (always applied), FAKE_CLAUDE_ONCE_MARKER + FAKE_CLAUDE_ONCE_MODE (hang|answerhang|limit|slow),
# firing only while the marker file is absent — lets one fake simulate "fails/hangs/is-slow once,
# behaves normally on retry"). FAKE_CLAUDE_LIMIT_CODE / FAKE_CLAUDE_NEXT_FLUSH parameterize "limit".
# FAKE_CLAUDE_SLOW_SEC / FAKE_CLAUDE_SLOW_RESULT parameterize "slow". "autherr" emits a NORMAL
# result envelope (exit 0) whose text is FAKE_CLAUDE_AUTH_TEXT. "answerhang" emits a complete
# result envelope carrying FAKE_CLAUDE_SALVAGE_RESULT and then hangs forever. FAKE_CLAUDE_DUMP_ENV,
# if set, writes `env` to that path before anything else (env-scrub check). FAKE_CLAUDE_ERROR_JSON,
# if set, emits that event line verbatim then exits 1 (unconditionally, not gated on ONCE_MARKER).
# FAKE_CLAUDE_USAGE_JSON, if set, merges into the default-path result event's usage field.
_install_fakes() {
  : > "$BIN/fake.conf"
  cat > "$BIN/claude" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$_here/fake.conf" ]] && source "$_here/fake.conf"
[[ -n "${FAKE_CLAUDE_DUMP_ENV:-}" ]] && env > "$FAKE_CLAUDE_DUMP_ENV"
# spec14 FR-B test instrumentation: append this invocation's full argv so a test can prove which
# specs/ vs queue/ copy actually got spawned, without racing the pool's own claim timing. Append,
# not overwrite — several branches in the same run may share this lane concurrently (FANOUT>1).
[[ -n "${FAKE_CLAUDE_ARGV_FILE:-}" ]] && printf '%s\n' "$*" >> "$FAKE_CLAUDE_ARGV_FILE"
# spec14 FR-5 companion test fixture: exit with the given code having emitted ZERO bytes — models
# both a card-fault (silent exit 1) and a lane-fault (a missing/non-executable binary, rc 126/127).
if [[ -n "${FAKE_CLAUDE_SILENT_FAIL:-}" ]]; then
  exit "${FAKE_CLAUDE_SILENT_FAIL}"
fi
# FR-15: write-mode probe — writes a file relative to $PWD (never an absolute path baked into the
# knob), so a passing assertion proves lane_cmd actually chdir'd the worker into the write target.
if [[ -n "${FAKE_CLAUDE_WRITE_FILE:-}" ]]; then
  printf '%s' "${FAKE_CLAUDE_WRITE_CONTENT:-written}" > "$FAKE_CLAUDE_WRITE_FILE"
  if [[ -n "${FAKE_CLAUDE_WRITE_TOUCH_REF:-}" ]]; then
    touch -r "$FAKE_CLAUDE_WRITE_TOUCH_REF" "$FAKE_CLAUDE_WRITE_FILE" .
  fi
  [[ -n "${FAKE_CLAUDE_WRITE_THEN_RM:-}" ]] && rm -f "$FAKE_CLAUDE_WRITE_FILE"
fi
if [[ -n "${FAKE_CLAUDE_ONCE_MARKER:-}" ]] && mkdir "$FAKE_CLAUDE_ONCE_MARKER" 2>/dev/null; then
  # mkdir, not `[[ ! -e ]] && touch`: with FANOUT>1 two concurrent invocations both raced past the
  # -e check and BOTH took the once-mode — mkdir is atomic, exactly one invocation wins.
  case "${FAKE_CLAUDE_ONCE_MODE:-limit}" in
    hang)
      sleep 9999
      ;;
    answerhang)
      # emit a COMPLETE, valid result envelope and only THEN hang forever — the worker whose answer
      # is already on disk when the watchdog kills it. Distinct from "hang" (nothing on the wire).
      echo '{"type":"init"}'
      _ah_extra=""
      [[ -n "${FAKE_CLAUDE_DENIALS_JSON:-}" ]] && _ah_extra=",\"permission_denials\":$FAKE_CLAUDE_DENIALS_JSON"
      printf '{"type":"result","result":"%s"%s}\n' "${FAKE_CLAUDE_SALVAGE_RESULT:-salvaged answer}" "$_ah_extra"
      sleep 9999
      ;;
    limit)
      printf '{"type":"error","error":{"code":%s,"message":"limit","next_flush_time":%s}}\n' \
        "${FAKE_CLAUDE_LIMIT_CODE:-1308}" "${FAKE_CLAUDE_NEXT_FLUSH:-9999999999}"
      exit 1
      ;;
    slow)
      sleep "${FAKE_CLAUDE_SLOW_SEC:-4}"
      echo '{"type":"init"}'
      printf '{"type":"result","result":"%s"}\n' "${FAKE_CLAUDE_SLOW_RESULT:-stale answer}"
      exit 0
      ;;
    autherr)
      # a NORMAL result envelope whose text IS the auth-death signature — exit 0, no error event.
      echo '{"type":"init"}'
      printf '{"type":"result","result":"%s"}\n' "${FAKE_CLAUDE_AUTH_TEXT:-OAuth session expired · Please run /login}"
      exit 0
      ;;
    journalwrite)
      echo '{"type":"init"}'
      _jw_file="${FAKE_CLAUDE_WRITE_FILE:-journal-made.txt}"
      printf '%s' "journal write" > "$_jw_file"
      printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"%s/%s"}}]}}\n' "$PWD" "$_jw_file"
      printf '{"type":"result","result":"wrote %s"}\n' "$_jw_file"
      exit 0
      ;;
  esac
fi
# Unusable-output mode: appends one line to the knob's file, emits NO result event, exits 1 —
# extract_answer fails and limit_error sees no error envelope (rc 0), exercising the bounded
# same-lane retry path (MAX_LANE_RETRIES).
if [[ -n "${FAKE_CLAUDE_GARBAGE_COUNT:-}" ]]; then
  echo x >> "$FAKE_CLAUDE_GARBAGE_COUNT"
  echo '{"type":"init"}'
  exit 1
fi
# spec12 FR-D test fixture: each invocation increments a counter file and tags its output with the
# attempt number, then fails (exit 1, no result event) — retried on the same lane every time.
if [[ -n "${FAKE_CLAUDE_ATTEMPT_COUNTER:-}" ]]; then
  _n=$(( $(cat "$FAKE_CLAUDE_ATTEMPT_COUNTER" 2>/dev/null || echo 0) + 1 ))
  echo "$_n" > "$FAKE_CLAUDE_ATTEMPT_COUNTER"
  echo "{\"type\":\"init\",\"attempt\":$_n}"
  exit 1
fi
# FAKE_CLAUDE_ERROR_JSON: emit the given event line verbatim, then exit 1.
if [[ -n "${FAKE_CLAUDE_ERROR_JSON:-}" ]]; then
  printf '%s\n' "$FAKE_CLAUDE_ERROR_JSON"
  exit 1
fi
sleep "${FAKE_CLAUDE_DELAY:-0}"
echo '{"type":"init"}'
# FAKE_CLAUDE_USAGE_JSON / FAKE_CLAUDE_DENIALS_JSON merge into the ONE result envelope's fields.
_extra=""
[[ -n "${FAKE_CLAUDE_USAGE_JSON:-}" ]] && _extra="$_extra,\"usage\":$FAKE_CLAUDE_USAGE_JSON"
[[ -n "${FAKE_CLAUDE_DENIALS_JSON:-}" ]] && _extra="$_extra,\"permission_denials\":$FAKE_CLAUDE_DENIALS_JSON"
printf '{"type":"result","result":"%s"%s}\n' "${FAKE_CLAUDE_RESULT:-OK}" "$_extra"
exit "${FAKE_CLAUDE_EXIT:-0}"
FAKE

  cat > "$BIN/codex" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$_here/fake.conf" ]] && source "$_here/fake.conf"
outfile=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  if [[ "${args[$i]}" == "--output-last-message" ]]; then
    outfile="${args[$((i + 1))]}"
  fi
done
sleep "${FAKE_CODEX_DELAY:-0}"
if [[ -n "${FAKE_CODEX_LIMIT:-}" ]]; then
  echo '{"type":"turn.failed","error":{"code":"rate_limit_exceeded","message":"usage limit reached"}}'
  exit 1
fi
echo '{"type":"thread.started"}'
if [[ -n "${FAKE_CODEX_WRITE_FILE:-}" ]]; then
  printf '%s' "${FAKE_CODEX_WRITE_CONTENT:-written}" > "$FAKE_CODEX_WRITE_FILE"
fi
[[ -n "$outfile" ]] && printf '%s' "${FAKE_CODEX_RESULT:-codex OK}" > "$outfile"
echo '{"type":"turn.completed","usage":{"input_tokens":10}}'
exit "${FAKE_CODEX_EXIT:-0}"
FAKE

  # Real 0.49 stream-json shape: assistant message delta(s) carry the answer text; the result event
  # carries ONLY {stats,status,timestamp,type} — no `.response`.
  cat > "$BIN/gemini" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$_here/fake.conf" ]] && source "$_here/fake.conf"
[[ -n "${FAKE_GEMINI_DUMP_ENV:-}" ]] && env > "$FAKE_GEMINI_DUMP_ENV"
if [[ -n "${FAKE_GEMINI_ERROR:-}" ]]; then
  printf '{"type":"error","message":"%s"}\n' "${FAKE_GEMINI_ERROR}"
  exit 1
fi
sleep "${FAKE_GEMINI_DELAY:-0}"
echo '{"type":"init"}'
content="$(printf '%s' "${FAKE_GEMINI_RESULT:-gemini OK}" | jq -Rs .)"
printf '{"type":"message","role":"assistant","content":%s,"delta":true}\n' "$content"
echo '{"type":"result","stats":{"models":{"gemini-3.5-flash":{}}},"status":"ok","timestamp":0}'
exit "${FAKE_GEMINI_EXIT:-0}"
FAKE

  # FR-16: fake docker for the opt-in containerized gemini lane. Strips the `run --rm -i -e K=V
  # -e K=V <image>` prefix and execs the trailing `gemini ...` argv, which PATH-resolves to the
  # fake gemini above — so a GEMINI_SANDBOX=docker branch exercises the same round trip with no
  # real docker/network involved.
  cat > "$BIN/docker" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$_here/fake.conf" ]] && source "$_here/fake.conf"
[[ -n "${FAKE_DOCKER_ARGV_FILE:-}" ]] && printf '%s\n' "$*" > "$FAKE_DOCKER_ARGV_FILE"
shift  # drop 'run'
while [[ $# -gt 0 ]]; do
  case "$1" in
    --rm|-i) shift ;;
    -e) shift 2 ;;
    *) break ;;
  esac
done
shift  # drop the pinned image ref
exec "$@"
FAKE

  # xAI Grok Build CLI (OAuth file auth). streaming-json: a thought chunk (firehose spam, never the
  # answer), one text chunk honoring FAKE_GROK_RESULT, then the end event carrying usage + (when
  # FAKE_GROK_COST is set) total_cost_usd/modelUsage.cost — omitted otherwise.
  cat > "$BIN/grok" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$_here/fake.conf" ]] && source "$_here/fake.conf"
[[ -n "${FAKE_GROK_DUMP_ENV:-}" ]] && env > "$FAKE_GROK_DUMP_ENV"
[[ -n "${FAKE_GROK_ARGV_FILE:-}" ]] && printf '%s\n' "$*" > "$FAKE_GROK_ARGV_FILE"
[[ -n "${FAKE_GROK_CALL_COUNT:-}" ]] && echo x >> "$FAKE_GROK_CALL_COUNT"
sleep "${FAKE_GROK_DELAY:-0}"
if [[ -n "${FAKE_GROK_ERROR:-}" ]]; then
  printf '{"type":"error","message":"%s"}\n' "${FAKE_GROK_ERROR}"
  exit 1
fi
if [[ -n "${FAKE_GROK_WRITE_FILE:-}" ]]; then
  printf '%s' "${FAKE_GROK_WRITE_CONTENT:-written}" > "$FAKE_GROK_WRITE_FILE"
fi
echo '{"type":"thought","data":"thinking..."}'
content="$(printf '%s' "${FAKE_GROK_RESULT:-grok OK}" | jq -Rs .)"
printf '{"type":"text","data":%s}\n' "$content"
if [[ -n "${FAKE_GROK_COST:-}" ]]; then
  printf '{"type":"end","stopReason":"EndTurn","sessionId":"s1","requestId":"r1","usage":{"input_tokens":787,"cache_read_input_tokens":2432,"output_tokens":32,"reasoning_tokens":28,"total_tokens":3251},"num_turns":1,"total_cost_usd":%s,"modelUsage":{"grok-4.5-build":{"inputTokens":787,"outputTokens":32,"cacheReadInputTokens":2432,"modelCalls":1,"costUSD":%s}}}\n' \
    "${FAKE_GROK_COST}" "${FAKE_GROK_COST}"
else
  printf '{"type":"end","stopReason":"EndTurn","sessionId":"s1","requestId":"r1","usage":{"input_tokens":787,"cache_read_input_tokens":2432,"output_tokens":32,"reasoning_tokens":28,"total_tokens":3251},"num_turns":1,"modelUsage":{"grok-4.5-build":{"inputTokens":787,"outputTokens":32,"cacheReadInputTokens":2432,"modelCalls":1}}}\n'
fi
exit "${FAKE_GROK_EXIT:-0}"
FAKE

  # spec 13 FR-2: fake curl for the glm/kimi/gemini doctor --live probes — no real network call.
  cat > "$BIN/curl" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$_here/fake.conf" ]] && source "$_here/fake.conf"
[[ -n "${FAKE_CURL_CALLED_FILE:-}" ]] && echo "$*" >> "${FAKE_CURL_CALLED_FILE}"
# real curl reads headers from stdin for `-H @-`; drain it or the writing printf takes SIGPIPE.
if [[ ! -t 0 ]]; then
  if [[ -n "${FAKE_CURL_STDIN_FILE:-}" ]]; then cat >> "${FAKE_CURL_STDIN_FILE}"; else cat >/dev/null; fi
fi
outfile=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  [[ "${args[$i]}" == "-o" ]] && outfile="${args[$((i + 1))]}"
done
if [[ -n "${FAKE_CURL_RC:-0}" && "${FAKE_CURL_RC:-0}" != "0" ]]; then
  exit "${FAKE_CURL_RC}"
fi
[[ -n "$outfile" && "$outfile" != "/dev/null" ]] && printf '%s' "${FAKE_CURL_BODY:-{}}" > "$outfile"
printf '%s' "${FAKE_CURL_HTTP_CODE:-200}"
FAKE

  chmod +x "$BIN/claude" "$BIN/codex" "$BIN/gemini" "$BIN/docker" "$BIN/grok" "$BIN/curl"
}

_enqueue() {
  local id="$1" text="$2"
  mkdir -p "$BUS/specs"
  printf '%s' "$text" > "$BUS/specs/$id.prompt"
}

_write_conf() {
  cat > "$CONF" <<EOF
EXEC_CHAIN="${1:-claude:opus glm:glm-5.2}"
FANOUT=${2:-4}
LEASE_MIN=${3:-15}
EOF
}

# poll <max_seconds> <command...> — repeat command (0.2s apart) until it succeeds or times out.
_poll() {
  local max_seconds="$1"; shift
  local iterations=$(( max_seconds * 5 )) i
  for (( i = 0; i < iterations; i++ )); do
    "$@" >/dev/null 2>&1 && return 0
    sleep 0.2
  done
  return 1
}

# --- FR-10: claim stamp written on claim, consumed into the done row ---------------------------
# RED today: _try_claim_one writes no limits/<id>.claimed-at and speed_row emits no claim_ts /
# queue_wait_secs, so each test fails on the new-key assertion. The run itself completes normally
# (status 0, done/<id> present) — only the additive-key assertions are RED, never the harness.

@test "FR-10: stamp written + consumed — done row carries claim_ts (ISO) + queue_wait_secs >= 0, limits/<id>.claimed-at gone" {
  _write_conf "claude:opus" 4 15
  _fake FAKE_CLAUDE_RESULT "OK"
  _enqueue cs1 "claim stamp written and consumed"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/cs1" ]

  # the attempt row for cs1 carries an ISO-shaped claim_ts (decisive one-line grep on the raw JSONL)
  [ -s "$SW" ]
  grep -q '"claim_ts":"20' "$SW"
  # ...and a non-negative integer queue_wait_secs (jq the one key)
  local qws
  qws="$(jq -r 'select(.id=="cs1") | .queue_wait_secs' "$SW")"
  [[ "$qws" =~ ^[0-9]+$ ]]   # additive key present and numeric (today jq prints "null" — RED)
  (( qws >= 0 ))

  # consume-on-read (.fbreason pattern): the stamp file is GONE after speed_row read it
  [ ! -e "$BUS/limits/cs1.claimed-at" ]
}

@test "FR-10: claim_ts/queue_wait_secs are ADDITIVE — existing keys (ts, id, wall_secs) survive alongside them" {
  _write_conf "claude:opus" 4 15
  _fake FAKE_CLAUDE_RESULT "OK"
  _enqueue cs2 "additive row keys"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/cs2" ]

  # contract: additive, nothing renamed/dropped — an existing key is still present ...
  [ "$(jq -r 'select(.id=="cs2") | .ts' "$SW")" != "null" ]
  [ "$(jq -r 'select(.id=="cs2") | .id' "$SW")" = "cs2" ]
  [ "$(jq -r 'select(.id=="cs2") | has("wall_secs")' "$SW")" = "true" ]
  # ... alongside the new FR-10 keys (today has("claim_ts") == false — RED)
  [ "$(jq -r 'select(.id=="cs2") | has("claim_ts")' "$SW")" = "true" ]
  [ "$(jq -r 'select(.id=="cs2") | has("queue_wait_secs")' "$SW")" = "true" ]
}

@test "FR-10: queue_wait_secs is plausible — non-negative and bounded well under the test's own wall clock" {
  _write_conf "claude:opus" 4 15
  _fake FAKE_CLAUDE_RESULT "OK"
  _enqueue cs3 "queue wait plausibility"

  local t0 t1
  t0=$(date +%s)
  run timeout 20 "$RUNSH"
  t1=$(date +%s)
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/cs3" ]

  local qws
  qws="$(jq -r 'select(.id=="cs3") | .queue_wait_secs' "$SW")"
  [[ "$qws" =~ ^[0-9]+$ ]]   # numeric first (today "null" — RED)
  # sanity bound: a card enqueued at the start of a sub-second fake run cannot have waited longer
  # than the whole test took — a value past the test's own wall clock would mean the stamp/birth
  # math is reading the wrong file or the wrong epoch. +1 absorbs a second-boundary rounding.
  (( qws < 60 && qws <= (t1 - t0) + 1 ))
}

@test "FR-10: a re-queued card gets a FRESH stamp on its next claim — the retry's done row carries claim_ts too" {
  # Mirror of swarm-run.bats's FR-12 hang-once retry fixture: the first lane (claude) hangs once,
  # the WORKER_TIMEOUT_SEC watchdog kills it, the card is re-queued and chain-advanced onto glm
  # (same fake claude binary, but the once-marker now exists so it answers normally). FR-10 stamps
  # EVERY claim — so the retry's glm claim writes its own fresh limits/<id>.claimed-at, which the
  # done row's speed_row consumes into its own claim_ts. A single-lane chain would park on the
  # post-timeout empty chain instead of completing, so the second rung is required (same as FR-12).
  _write_conf "claude:opus glm:glm-5.2" 4 15
  cat >> "$CONF" <<'EOF'
WORKER_TIMEOUT_SEC=2
EOF
  _fake FAKE_CLAUDE_ONCE_MARKER "$BATS_TEST_TMPDIR/rf1-once"
  _fake FAKE_CLAUDE_ONCE_MODE hang
  _fake FAKE_CLAUDE_RESULT "OK"
  _enqueue rf1 "re-claim freshness retry"

  run timeout 30 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/rf1" ]

  # a retry happened: the timed-out claude attempt left a 'timeout' row and the successful glm
  # attempt a 'done' row — two attempt rows for rf1 (the trailing run-summary row has no id).
  # -s slurps the JSONL stream into one array so map/select|length yields a single count, not a
  # 0/1 per line (which would break the integer compare).
  [ "$(jq -s 'map(select(.id=="rf1")) | length' "$SW")" -ge 2 ]

  # the decisive assertion: the SECOND attempt (the retry that actually completed) carries its own
  # ISO-shaped claim_ts — proving the re-claim wrote a fresh stamp instead of reusing the consumed
  # first one. Today the field is absent -> jq prints "null" -> RED.
  local done_ts
  done_ts="$(jq -r 'select(.id=="rf1" and .outcome=="done") | .claim_ts' "$SW")"
  [ "$done_ts" != "null" ]
  [[ "$done_ts" == 20* ]]
}

@test "FR-10 amendment: a PINNED card's terminal park — BOTH the failed attempt row and the parked row carry claim_ts (no first-read consumption)" {
  # Review-round regression (2026-07-31): _finalize_worker writes the failed attempt's row, then
  # _park_card writes the terminal parked row — two speed_row calls for ONE claim. The original
  # consume-on-read deleted the stamp at the first call, leaving the parked row (the one
  # `swarm-ctl timeline` keeps, last-row-per-id) stamp-less. speed_row now only READS the stamp;
  # _park_card removes it after its own row.
  _write_conf "claude:opus" 4 15
  cat >> "$CONF" <<'EOF2'
MAX_LANE_RETRIES=1
EOF2
  # GARBAGE mode: init event only, exit 1, no result envelope — answer unusable on every retry
  # (a FAKE_CLAUDE_EXIT=1 with a result envelope would still finalize done: artifacts-as-truth).
  _fake FAKE_CLAUDE_GARBAGE_COUNT "$BATS_TEST_TMPDIR/pp1-garbage"
  _enqueue pp1 "pinned card that fails terminally"
  printf 'claude:opus\n' > "$BUS/specs/pp1.lane"

  run timeout 30 "$RUNSH"
  # pinned + failed -> parked; the run exits nonzero on parked cards — the rows are the assertion.
  [ -f "$BUS/limits/pp1.parked" ]

  # both rows for the single claim carry the SAME ISO claim_ts
  local att_ts park_ts
  att_ts="$(jq -r 'select(.id=="pp1" and .outcome!="parked" and .type==null) | .claim_ts' "$SW" | head -1)"
  park_ts="$(jq -r 'select(.id=="pp1" and .outcome=="parked") | .claim_ts' "$SW")"
  [[ "$att_ts" == 20* ]]
  [[ "$park_ts" == 20* ]]
  [ "$att_ts" = "$park_ts" ]

  # and the terminal transition removed the stamp (park owns cleanup now)
  [ ! -e "$BUS/limits/pp1.claimed-at" ]
}
