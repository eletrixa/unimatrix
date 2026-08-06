#!/usr/bin/env bats
# Integration tests for swarm-run.sh full mode — shard 3/4 of the former tests/swarm-run.bats,
# split so check.sh's CHECK_JOBS per-file fan-out gets a shorter critical path. No real API calls —
# every claude/codex/gemini invocation resolves to a fake script under $BATS_TEST_TMPDIR/bin,
# installed by the shared fixture this file loads.
#
# Project: unimatrix — multi-model swarm orchestrator driven from Claude Code
# Module:  tests/swarm-run-3.bats
# Deps:    bats-core, tests/helpers/swarm-run-fixture.bash (setup/teardown + fakes + helpers), src/swarm-lib.sh, swarm-run.sh
# Tested:  n/a — this is the test file
#
# Design constraints:
# - All file-scope state, setup()/teardown(), fake installers, and probe/fixture helpers live in
#   tests/helpers/swarm-run-fixture.bash — pulled in by the `load` below (bats resolves it against
#   this file's own dir and picks setup/teardown up from the fixture).
# - Test bodies are verbatim from the original file; original order is preserved within the shard.

load 'helpers/swarm-run-fixture'

# --- P1-FR5: _plugin_version_banner_line ------------------------------------------------------

@test "P1-FR5: _plugin_version_banner_line warns on stderr when plugin.json and CHANGELOG disagree; rc of the banner path stays 0" {
  local eng="$BATS_TEST_TMPDIR/bannereng-mismatch"
  _banner_engine "$eng" "1.1.0" "9.9.9"

  run "$eng/swarm-run.sh" doctor --plugin
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING: plugin.json version (1.1.0) differs from repo version (9.9.9)"* ]]
}

@test "P1-FR5: _plugin_version_banner_line is silent when plugin.json and CHANGELOG agree" {
  local eng="$BATS_TEST_TMPDIR/bannereng-match"
  _banner_engine "$eng" "1.1.0" "1.1.0"

  run "$eng/swarm-run.sh" doctor --plugin
  [ "$status" -eq 0 ]
  [[ "$output" != *"WARNING: plugin.json version"* ]]
}

# --- spec 13 FR-3: .broken fast-fail marker (integration) -------------------------------------

@test "spec13 FR-3: a lane that ran but served nothing gets limits/<lane>.broken (class lane-down) once its bounded retries exhaust" {
  _write_conf "grok:default claude:opus"
  cat >> "$CONF" <<'EOF2'
MAX_LANE_RETRIES=1
EOF2
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-fr3a.jsonl"
  _fake FAKE_GROK_ERROR "kaboom internal crash"
  _fake FAKE_CLAUDE_RESULT "claude rescued it"
  _enqueue fr3a "card that fast-fails on grok, rescued by claude"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/fr3a" ]
  [ "$(<"$BUS/res-fr3a.txt")" = "claude rescued it" ]
  [ -f "$BUS/limits/grok.broken" ]
  [ "$(jq -r 'select(.id=="fr3a" and .served_lane=="grok") | .class' "$SPEEDWARS_FILE")" = "lane-down" ]
}

@test "spec13 FR-3: a routed-around .broken lane is never spawned again while the flag is active" {
  _write_conf "grok:default claude:opus"
  cat >> "$CONF" <<'EOF2'
MAX_LANE_RETRIES=1
EOF2
  FAKE_GROK_CALL_COUNT="$BATS_TEST_TMPDIR/grok-calls"
  _fake FAKE_GROK_CALL_COUNT "$FAKE_GROK_CALL_COUNT"
  _fake FAKE_GROK_ERROR "kaboom internal crash"
  _fake FAKE_CLAUDE_RESULT "claude rescued it"
  _enqueue fr3b1 "first card exhausts and marks grok broken"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/limits/grok.broken" ]
  calls_after_first="$(wc -l < "$FAKE_GROK_CALL_COUNT")"
  [ "$calls_after_first" -ge 1 ]

  # a SEPARATE run against the same bus: a fresh card pinned to grok-only (no fallback lane) must
  # park WITHOUT ever spawning grok — proves routing-around, not just the marker's existence.
  _write_conf "grok:default"
  _enqueue fr3b2 "second card must route around the still-broken grok"
  run timeout 20 "$RUNSH"
  [ "$status" -ne 0 ]
  [ -f "$BUS/limits/fr3b2.parked" ]
  [ "$(wc -l < "$FAKE_GROK_CALL_COUNT")" -eq "$calls_after_first" ]
}

@test "spec13 FR-3: the .broken marker expires by TTL — a later card can use the lane again" {
  _write_conf "grok:default claude:opus"
  cat >> "$CONF" <<'EOF2'
MAX_LANE_RETRIES=1
EOF2
  _fake FAKE_GROK_ERROR "kaboom internal crash"
  _fake FAKE_CLAUDE_RESULT "claude rescued it"
  _enqueue fr3c1 "first card exhausts and marks grok broken"
  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/limits/grok.broken" ]

  touch -d "-1900 seconds" "$BUS/limits/grok.broken"  # past the 1800s default TTL
  _fake FAKE_GROK_ERROR ""
  _fake FAKE_GROK_RESULT "grok healthy again"
  _write_conf "grok:default"
  _enqueue fr3c2 "second card, grok TTL expired"
  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/fr3c2" ]
  [ "$(<"$BUS/res-fr3c2.txt")" = "grok healthy again" ]
}

@test "spec13 FR-3: a successful finalize on a previously-broken lane clears its .broken marker file" {
  _write_conf "grok:default claude:opus"
  cat >> "$CONF" <<'EOF2'
MAX_LANE_RETRIES=1
EOF2
  _fake FAKE_GROK_ERROR "kaboom internal crash"
  _fake FAKE_CLAUDE_RESULT "claude rescued it"
  _enqueue fr3d1 "first card exhausts and marks grok broken"
  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/limits/grok.broken" ]

  touch -d "-1900 seconds" "$BUS/limits/grok.broken"
  _fake FAKE_GROK_ERROR ""
  _fake FAKE_GROK_RESULT "grok healthy again"
  _write_conf "grok:default"
  _enqueue fr3d2 "second card succeeds on grok — should clear the stale marker file, not just outlast its TTL"
  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/fr3d2" ]
  [ ! -e "$BUS/limits/grok.broken" ]
}

# --- spec 13 FR-4: PAYG fallback gate (BUDGET_USD=0 fallback onto kimi) ------------------------

@test "spec13 FR-4: PAYG_FALLBACK=warn (default) lets a kimi fallback hop proceed under BUDGET_USD=0, with a loud stderr line" {
  _write_conf "glm:glm-5.2 kimi:kimi-k3"
  _enqueue payg1 "glm limited, fallback hop lands on kimi"
  _fake FAKE_CLAUDE_ONCE_MARKER "$BATS_TEST_TMPDIR/payg1-once"
  _fake FAKE_CLAUDE_ONCE_MODE limit
  _fake FAKE_CLAUDE_LIMIT_CODE 1308
  _fake FAKE_CLAUDE_NEXT_FLUSH "$(( $(date +%s) + 500 ))"
  _fake FAKE_CLAUDE_RESULT "kimi rescued it"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/payg1" ]
  [ "$(<"$BUS/res-payg1.txt")" = "kimi rescued it" ]
  [[ "$output" == *"PAYG fallback: payg1 hopping to kimi with no budget cap set"* ]]
}

@test "spec13 FR-4: PAYG_FALLBACK=deny routes around a kimi fallback hop under BUDGET_USD=0 — parks when kimi was the last lane" {
  _write_conf "glm:glm-5.2 kimi:kimi-k3"
  cat >> "$CONF" <<'EOF2'
PAYG_FALLBACK=deny
EOF2
  _enqueue payg2 "glm limited, kimi hop denied, nothing left"
  _fake FAKE_CLAUDE_ONCE_MARKER "$BATS_TEST_TMPDIR/payg2-once"
  _fake FAKE_CLAUDE_ONCE_MODE limit
  _fake FAKE_CLAUDE_LIMIT_CODE 1308
  _fake FAKE_CLAUDE_NEXT_FLUSH "$(( $(date +%s) + 500 ))"
  _fake FAKE_CLAUDE_RESULT "should never be seen"

  run timeout 20 "$RUNSH"
  [ "$status" -ne 0 ]
  [ ! -f "$BUS/done/payg2" ]
  [ -f "$BUS/limits/payg2.parked" ]
  [[ "$output" == *"fallback hop to kimi refused"* ]]
  [[ "$output" == *"PAYG_FALLBACK=deny"* ]]
}

@test "spec13 FR-4: PAYG_FALLBACK=allow is byte-identical to today — kimi hop proceeds silently (no PAYG stderr line)" {
  _write_conf "glm:glm-5.2 kimi:kimi-k3"
  cat >> "$CONF" <<'EOF2'
PAYG_FALLBACK=allow
EOF2
  _enqueue payg3 "glm limited, kimi hop allowed silently"
  _fake FAKE_CLAUDE_ONCE_MARKER "$BATS_TEST_TMPDIR/payg3-once"
  _fake FAKE_CLAUDE_ONCE_MODE limit
  _fake FAKE_CLAUDE_LIMIT_CODE 1308
  _fake FAKE_CLAUDE_NEXT_FLUSH "$(( $(date +%s) + 500 ))"
  _fake FAKE_CLAUDE_RESULT "kimi rescued it"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/payg3" ]
  [ "$(<"$BUS/res-payg3.txt")" = "kimi rescued it" ]
  [[ "$output" != *"PAYG fallback:"* ]]
  [[ "$output" != *"fallback hop to kimi refused"* ]]
}

@test "spec13 FR-4: with BUDGET_USD>0, PAYG_FALLBACK=deny does NOT block a kimi fallback hop (existing kimi budget gate governs instead, unchanged)" {
  _write_conf "glm:glm-5.2 kimi:kimi-k3"
  cat >> "$CONF" <<'EOF2'
BUDGET_USD=5
PAYG_FALLBACK=deny
EOF2
  _enqueue payg4 "glm limited, kimi hop under a real budget cap — deny must not apply"
  _fake FAKE_CLAUDE_ONCE_MARKER "$BATS_TEST_TMPDIR/payg4-once"
  _fake FAKE_CLAUDE_ONCE_MODE limit
  _fake FAKE_CLAUDE_LIMIT_CODE 1308
  _fake FAKE_CLAUDE_NEXT_FLUSH "$(( $(date +%s) + 500 ))"
  _fake FAKE_CLAUDE_RESULT "kimi rescued it"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/payg4" ]
  [ "$(<"$BUS/res-payg4.txt")" = "kimi rescued it" ]
  [[ "$output" != *"fallback hop to kimi refused"* ]]
}

# --- round-4 review fixes ------------------------------------------------------------------------

@test "round4: the resolved-config table prints EVERY conf_load key, not a hand-maintained subset" {
  _write_conf "claude:opus" 4 15
  run "$RUNSH" config
  [ "$status" -eq 0 ]
  for k in PLAN ORCHESTRATOR REVIEW EXEC_CHAIN MAX_ITERATIONS BUDGET_USD FANOUT LEASE_MIN \
           WORKER_TIMEOUT_SEC MAX_LANE_RETRIES VERIFY_MAP LEDGER_AUTO GEMINI_SANDBOX MON_PORT \
           MON_AUTOOPEN REVIEW_CHAIN PIN_WAIT_SEC PLAN_CHAIN ORCH_CHAIN ORCH_TAKEOVER_MIN \
           FEEDBACK_AUTO PAYG_FALLBACK GLM_MAX_THINKING_TOKENS KIMI_MAX_THINKING_TOKENS GROK_EFFORT; do
    [[ "$output" == *"$k"* ]] || { echo "missing conf key in config table: $k" >&2; false; }
  done
  # the class rows keep their live-availability rendering, not a bare value line
  [[ "$output" == *"CLASS_REVIEW:"* ]]
  [[ "$output" == *"CLASS_EXEC:"* ]]
}

@test "round4: the config table reports an actively-broken class member as broken, not available" {
  _write_conf "claude:opus" 4 15
  mkdir -p "$BUS/limits"
  printf '1800' > "$BUS/limits/grok.broken"

  run "$RUNSH" config
  [ "$status" -eq 0 ]
  [[ "$output" =~ CLASS_EXEC:\ grok\(broken\ [0-9]+m\) ]]
}

@test "round4: a .broken lane is routed around with fallback_reason lane-down, never budget-gated" {
  _write_conf "claude:opus codex:default" 4 15
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-broken.jsonl"
  mkdir -p "$BUS/limits"
  printf '1800' > "$BUS/limits/claude.broken"
  _fake FAKE_CODEX_RESULT "codex served it"
  _enqueue lb1 "claude is broken — the chain must hop and say why"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/lb1" ]
  [ "$(jq -r 'select(.id=="lb1") | .fallback_reason' "$SPEEDWARS_FILE")" = "lane-down" ]
  [[ "$output" == *"blocked (lane-down)"* ]]
}

@test "round4: a pinned park emits a TERMINAL parked row so parked_n matches the bus" {
  _write_conf "claude:opus" 4 15
  cat >> "$CONF" <<'EOF'
PIN_WAIT_SEC=0
EOF
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-pinpark.jsonl"
  mkdir -p "$BUS/limits"
  printf '18000' > "$BUS/limits/glm.limited"
  _enqueue pp1 "pinned to a limited lane — must park loudly WITH a row"
  printf 'glm:glm-5.2' > "$BUS/specs/pp1.lane"

  run timeout 25 "$RUNSH"
  [ "$status" -ne 0 ]
  [ -f "$BUS/limits/pp1.parked" ]
  # last row for this id is the park itself
  [ "$(jq -rs 'map(select(.id=="pp1")) | last | .outcome' "$SPEEDWARS_FILE")" = "parked" ]
  [ "$(jq -rs 'map(select(.type=="run-summary")) | last | .parked_n' "$SPEEDWARS_FILE")" = "1" ]
}

@test "round4: a timed-out write card rejected by the diff gate leaves NO stale res-<id>.txt" {
  _write_conf "claude:opus" 4 15
  cat >> "$CONF" <<'EOF'
WORKER_TIMEOUT_SEC=2
EOF
  local target="$BATS_TEST_TMPDIR/staleres-target"
  mkdir -p "$target"
  touch -d '10 seconds ago' "$target"
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-sr.jsonl"
  # answers (so extract_answer succeeds + writes res-*) but never touches the write target
  _fake FAKE_CLAUDE_ONCE_MARKER "$BATS_TEST_TMPDIR/sr-once"
  _fake FAKE_CLAUDE_ONCE_MODE answerhang
  _fake FAKE_CLAUDE_SALVAGE_RESULT "I talked instead of editing"
  _enqueue sr1 "write card that answers but writes nothing, then hangs"
  printf '%s' "$target" > "$BUS/specs/sr1.write"

  run timeout 25 "$RUNSH"
  [ "$status" -ne 0 ]
  [ ! -e "$BUS/done/sr1" ]
  [ ! -e "$BUS/res-sr1.txt" ]   # the rejected answer must never survive to launder a later attempt
}

@test "round4: a salvaged done marker is stamped salvaged:true (code alone no longer distinguishes it)" {
  _write_conf "claude:opus" 4 15
  cat >> "$CONF" <<'EOF'
WORKER_TIMEOUT_SEC=2
EOF
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-salvflag.jsonl"
  _fake FAKE_CLAUDE_ONCE_MARKER "$BATS_TEST_TMPDIR/sf-once"
  _fake FAKE_CLAUDE_ONCE_MODE answerhang
  _fake FAKE_CLAUDE_SALVAGE_RESULT "answer landed before the kill"
  _enqueue sf1 "read card salvaged after a kill"

  run timeout 25 "$RUNSH"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.salvaged' "$BUS/done/sf1")" = "true" ]
  # a PLAIN completion carries no such key (absence-means-absent)
  _enqueue sf2 "ordinary card"
  run timeout 20 "$RUNSH"
  [ "$(jq -r 'has("salvaged")' "$BUS/done/sf2")" = "false" ]
}

@test "round4: doctor --live probe cages live outside BUSDIR and leave no credentials behind" {
  export LEDGER_FILE="$BATS_TEST_TMPDIR/dl-ledger.md"
  mkdir -p "$HOME/.claude"
  printf '{"token":"secret"}' > "$HOME/.claude/.credentials.json"
  [ ! -d "$BUS" ]

  run "$RUNSH" doctor --live
  [ "$status" -eq 0 ]
  # the probe must not conjure a bus (which would also satisfy the .broken guard by itself)
  [ ! -d "$BUS" ]
}

@test "round4: doctor --live: a FAIL does NOT write .broken into a bus the probe itself created" {
  export LEDGER_FILE="$BATS_TEST_TMPDIR/dl-ledger2.md"
  export FAKE_CURL_HTTP_CODE=401
  [ ! -d "$BUS" ]
  run "$RUNSH" doctor --live
  [ "$status" -ne 0 ]
  [ ! -e "$BUS/limits/glm.broken" ]
}

@test "round4: doctor --live never puts a provider key in curl's argv (stdin headers only)" {
  export LEDGER_FILE="$BATS_TEST_TMPDIR/dl-ledger3.md"
  export FAKE_CURL_CALLED_FILE="$BATS_TEST_TMPDIR/curl-argv"
  export FAKE_CURL_STDIN_FILE="$BATS_TEST_TMPDIR/curl-stdin"
  run "$RUNSH" doctor --live
  [ "$status" -eq 0 ]
  [ -s "$FAKE_CURL_CALLED_FILE" ]
  ! grep -q 'default-glm-key\|default-kimi-key\|default-gem-key' "$FAKE_CURL_CALLED_FILE"
  grep -q "default-gem-key" "$FAKE_CURL_STDIN_FILE"
  # and no `?key=` query-string form for gemini
  ! grep -q '?key=' "$FAKE_CURL_CALLED_FILE"
}

@test "round4: doctor --live probes the CONFIGURED glm model, not a hardcoded one" {
  export LEDGER_FILE="$BATS_TEST_TMPDIR/dl-ledger4.md"
  export FAKE_CURL_CALLED_FILE="$BATS_TEST_TMPDIR/curl-argv4"
  _write_conf "claude:opus glm:glm-4.7" 4 15
  run "$RUNSH" doctor --live
  [ "$status" -eq 0 ]
  grep -q 'glm-4.7' "$FAKE_CURL_CALLED_FILE"
  ! grep -q 'glm-4.6' "$FAKE_CURL_CALLED_FILE"
}

# --- spec 14 fix wave (RUN-1: swarm-run.sh foundations) ------------------------------------------
# backlog 44-57, 2026-07-25. FR numbers below are spec 14's unless noted; spec01/04/10/12 carry
# their own 2026-07-25 amendments (FR-A/FR-B, FR-C, FR-E, FR-D respectively).

@test "spec14 FR-7: a chain-exhausted park's marker matches the fixed reason-line format, reason chain-exhausted, retryable=1, ttl=0" {
  _write_conf "claude:opus" 4 15
  _enqueue f7a "chain exhausted, no fallback"
  mkdir -p "$BUS/queue" "$BUS/limits"
  printf '%s' "codex:default kimi:kimi-k3" > "$BUS/queue/f7a.chain"
  printf '18000' > "$BUS/limits/codex.limited"
  printf '18000' > "$BUS/limits/kimi.limited"

  run timeout 20 "$RUNSH"
  [ "$status" -ne 0 ]
  [ -f "$BUS/limits/f7a.parked" ]
  local line; line="$(<"$BUS/limits/f7a.parked")"
  [[ "$line" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[^\ ]*\ \|\ chain-exhausted\ \|\ retryable=1\ \|\ ttl=0\ \|\ .*$ ]]
  # speed_row's own `class` output is unchanged (parked-env) — the existing regression guard at
  # "spec12 FR-1: a chain-exhausted parked row carries class parked-env" pins that separately.
}

@test "spec14 FR-7: a retries-exhausted park's marker carries a token from the fixed set and no leaked answer text" {
  _write_conf "claude:opus" 4 15
  cat >> "$CONF" <<'EOF2'
MAX_LANE_RETRIES=1
EOF2
  _fake FAKE_CLAUDE_GARBAGE_COUNT "$BATS_TEST_TMPDIR/f7b-count"
  _enqueue f7b "SUPER-SECRET-CANARY-STRING must never leak into a marker"

  run timeout 20 "$RUNSH"
  [ "$status" -ne 0 ]
  [ -f "$BUS/limits/f7b.parked" ]
  local line token; line="$(<"$BUS/limits/f7b.parked")"
  [[ "$line" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[^\ ]*\ \|\ ([a-z-]+)\ \|\ retryable=[01]\ \|\ ttl=[0-9]+\ \|\ .*$ ]]
  token="${BASH_REMATCH[1]}"
  case "$token" in
    auth-death | api-error | server-error | rate-limit | timeout-watchdog | spawn-fail \
      | false-done | no-answer | lane-down | parked-env | cage-denied | write-target-missing \
      | write-target-empty | chain-exhausted | pinned-lane-blocked | session-limit) ;;
    *) echo "unknown reason token: $token" >&2; false ;;
  esac
  ! grep -q "SUPER-SECRET-CANARY-STRING" "$BUS/limits/f7b.parked"
}

@test "spec14 FR-3 regression guard: an EMPTY limits/.chain-<id> reads as exhausted, never falls back to EXEC_CHAIN ([[ -f ]], never [[ -s ]])" {
  mkdir -p "$BUS/limits"
  : > "$BUS/limits/.chain-guard1"
  run bash -c "
    set -euo pipefail
    source '$BATS_TEST_DIRNAME/../src/swarm-lib.sh'
    EXEC_CHAIN='claude:opus codex:default'
    chain_current '$BUS' guard1
  "
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "spec14 FR-3: after a chain-exhausted park, limits/.chain-<id> no longer exists (today: a zero-byte file remains)" {
  _write_conf "claude:opus" 4 15
  _enqueue f3a "chain exhausted, no fallback"
  mkdir -p "$BUS/queue" "$BUS/limits"
  printf '%s' "codex:default kimi:kimi-k3" > "$BUS/queue/f3a.chain"
  printf '18000' > "$BUS/limits/codex.limited"
  printf '18000' > "$BUS/limits/kimi.limited"

  run timeout 20 "$RUNSH"
  [ "$status" -ne 0 ]
  [ -f "$BUS/limits/f3a.parked" ]
  [ ! -e "$BUS/limits/.chain-f3a" ]
}

@test "spec14 FR-5: a .write target that does not exist is never spawned into — waits, then parks write-target-missing, never mkdir'd" {
  _write_conf "claude:opus" 4 15
  cat >> "$CONF" <<'EOF2'
PIN_WAIT_SEC=2
EOF2
  local target="$BATS_TEST_TMPDIR/fr5-missing"
  local argvfile="$BATS_TEST_TMPDIR/fr5-argv"
  _fake FAKE_CLAUDE_ARGV_FILE "$argvfile"
  _fake FAKE_CLAUDE_RESULT "should never run"
  _enqueue fr5a "write card targeting a directory that doesn't exist yet"
  printf '%s' "$target" > "$BUS/specs/fr5a.write"

  run timeout 20 "$RUNSH"
  [ "$status" -ne 0 ]
  [ -f "$BUS/limits/fr5a.parked" ]
  [[ "$output" == *"does not exist yet"*"waiting"* ]]
  [[ "$output" == *"still missing after"*"parking"* ]]
  [ ! -e "$argvfile" ]     # the fake CLI was NEVER invoked
  [ ! -d "$target" ]       # never mkdir'd
  [[ "$(<"$BUS/limits/fr5a.parked")" == *"write-target-missing"* ]]
}

@test "spec14 FR-5: a .write target that appears mid-wait clears limits/<id>.waiting-write and the card claims and runs normally" {
  _write_conf "claude:opus" 4 15
  cat >> "$CONF" <<'EOF2'
PIN_WAIT_SEC=30
EOF2
  local target="$BATS_TEST_TMPDIR/fr5-appears"
  _fake FAKE_CLAUDE_RESULT "ran once the target showed up"
  _fake FAKE_CLAUDE_WRITE_FILE "created.txt"
  _enqueue fr5b "write card whose target appears mid-wait"
  printf '%s' "$target" > "$BUS/specs/fr5b.write"

  "$RUNSH" 3>&- &
  BG_PIDS+=("$!")

  # cross-review CRITICAL fix: FR-5 owns its own marker name (.waiting-write), distinct from
  # FR-R6's shared .waiting — the two used to collide and reset each other's timer every poll.
  _poll 10 test -f "$BUS/limits/fr5b.waiting-write"
  [ -f "$BUS/limits/fr5b.waiting-write" ]
  mkdir -p "$target"

  _poll 25 test -f "$BUS/done/fr5b"
  [ -f "$BUS/done/fr5b" ]
  [ ! -e "$BUS/limits/fr5b.waiting-write" ]
  [ -f "$target/created.txt" ]

  wait "${BG_PIDS[0]}"
  BG_PIDS=()
}

@test "spec14 FR-5 companion (2026-07-29): an EMPTY queue/<id>.write parks INSTANTLY, never waiting PIN_WAIT_SEC" {
  _write_conf "claude:opus" 4 15
  cat >> "$CONF" <<'EOF2'
PIN_WAIT_SEC=60
EOF2
  local argvfile="$BATS_TEST_TMPDIR/empty-write-argv"
  _fake FAKE_CLAUDE_ARGV_FILE "$argvfile"
  _fake FAKE_CLAUDE_RESULT "should never run"
  # seeded directly into queue/, bypassing the sweep's own empty-card refusal (spec01 FR-B) — this
  # test is about _try_claim_one's claim-time instant park, a distinct code path
  mkdir -p "$BUS/queue"
  printf '%s' "empty write card, queued directly" > "$BUS/queue/ew1.prompt"
  : > "$BUS/queue/ew1.write"

  run timeout 20 "$RUNSH"
  [ "$status" -ne 0 ]
  [ -f "$BUS/limits/ew1.parked" ]
  [[ "$(<"$BUS/limits/ew1.parked")" == *"write-target-empty"* ]]
  [ ! -e "$argvfile" ]     # the fake CLI was NEVER invoked — the 20s timeout beating PIN_WAIT_SEC=60
                           # proves the park was instant, not a bounded wait that happened to time out
}

@test "spec14 FR-5 companion: a zero-byte run-jsonl on the exhausting attempt does NOT flag lane-down/.broken" {
  _write_conf "claude:opus" 4 15
  cat >> "$CONF" <<'EOF2'
MAX_LANE_RETRIES=1
EOF2
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-zb.jsonl"
  _fake FAKE_CLAUDE_SILENT_FAIL 1
  _enqueue zb1 "worker dies with zero stdout on a card-fault exit code"

  run timeout 20 "$RUNSH"
  [ "$status" -ne 0 ]
  [ -f "$BUS/limits/zb1.parked" ]
  [ ! -e "$BUS/limits/claude.broken" ]
  [ "$(jq -r 'select(.id=="zb1" and .outcome=="retry") | .class' "$SPEEDWARS_FILE")" = "no-answer" ]
}

@test "spec14 FR-5 companion: a zero-byte run-jsonl with wrc 126 still flags lane-down/.broken" {
  _write_conf "claude:opus" 4 15
  cat >> "$CONF" <<'EOF2'
MAX_LANE_RETRIES=1
EOF2
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-zb126.jsonl"
  _fake FAKE_CLAUDE_SILENT_FAIL 126
  _enqueue zb126 "worker exits 126 (exec-permission failure) with zero stdout"

  run timeout 20 "$RUNSH"
  [ "$status" -ne 0 ]
  [ -f "$BUS/limits/zb126.parked" ]
  [ -f "$BUS/limits/claude.broken" ]
  [ "$(jq -r 'select(.id=="zb126" and .outcome=="retry") | .class' "$SPEEDWARS_FILE")" = "lane-down" ]
}

@test "spec14 FR-5 companion: a zero-byte run-jsonl with wrc 127 still flags lane-down/.broken" {
  _write_conf "claude:opus" 4 15
  cat >> "$CONF" <<'EOF2'
MAX_LANE_RETRIES=1
EOF2
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-zb127.jsonl"
  _fake FAKE_CLAUDE_SILENT_FAIL 127
  _enqueue zb127 "worker exits 127 (command-not-found shape) with zero stdout"

  run timeout 20 "$RUNSH"
  [ "$status" -ne 0 ]
  [ -f "$BUS/limits/zb127.parked" ]
  [ -f "$BUS/limits/claude.broken" ]
  [ "$(jq -r 'select(.id=="zb127" and .outcome=="retry") | .class' "$SPEEDWARS_FILE")" = "lane-down" ]
}

@test "spec01 FR-B: sweep discards done/cancelled ids, preserves an already-queued OPERATOR HINT, and still sweeps a fresh id sidecars-first" {
  _write_conf "claude:opus" 4 15
  mkdir -p "$BUS/done" "$BUS/cancelled" "$BUS/queue" "$BUS/specs"

  # done/<id>: consume-and-discard — specs/ entry (+ sidecars) vanish, done/ marker untouched
  printf '{"id":"b1","code":0,"lane":"claude"}\n' > "$BUS/done/b1"
  _enqueue b1 "already done, must not re-run"
  echo "claude:opus" > "$BUS/specs/b1.lane"

  # cancelled/<id>.prompt: consume-and-discard
  printf 'pulled' > "$BUS/cancelled/b2.prompt"
  _enqueue b2 "already cancelled, must not resurrect"

  # queue/<id>.prompt already present (e.g. reap-requeued, carrying an OPERATOR HINT):
  # non-destructive skip — the queued copy (with its hint) must survive, not the pristine one
  _enqueue b4 "pristine specs copy — must NOT clobber the queued hint"
  printf 'requeued original\n\n## OPERATOR HINT (nudge 2026-01-01T00:00:00Z)\ndo it differently\n' > "$BUS/queue/b4.prompt"

  # a genuinely fresh id — sidecars still move before the prompt, exactly as today
  local argvfile="$BATS_TEST_TMPDIR/b4-b5.argv"
  _fake FAKE_CLAUDE_RESULT "fresh answer"
  _fake FAKE_CLAUDE_ARGV_FILE "$argvfile"
  _enqueue b5 "brand new spec"
  echo "claude:opus" > "$BUS/specs/b5.lane"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]

  # b1 — done, discarded
  [ ! -e "$BUS/specs/b1.prompt" ]
  [ ! -e "$BUS/specs/b1.lane" ]
  [ ! -e "$BUS/run-b1.jsonl" ]
  [[ "$output" == *"b1"*"done"* ]]

  # b2 — cancelled, discarded, never resurrected
  [ ! -e "$BUS/specs/b2.prompt" ]
  [ ! -e "$BUS/queue/b2.prompt" ]
  [ ! -e "$BUS/run-b2.jsonl" ]
  [[ "$output" == *"b2"*"cancelled"* ]]

  # b4 — already queued; the hinted copy must survive to spawn time (proven via the CLI's own argv)
  [ -e "$BUS/specs/b4.prompt" ]
  [ -f "$BUS/done/b4" ]
  grep -q "OPERATOR HINT" "$argvfile"
  [[ "$output" == *"b4"*"already queued"* ]]

  # b5 — fresh id, sidecars-first, completes normally
  [ -f "$BUS/done/b5" ]
  [ "$(<"$BUS/res-b5.txt")" = "fresh answer" ]
}

@test "spec01 FR-B: an id already claimed keeps its specs/ entry in place (non-destructive skip), never a second queue/ prompt" {
  _write_conf "claude:opus" 4 15
  mkdir -p "$BUS/claimed"
  _enqueue b3 "already claimed elsewhere — must not get a second prompt in queue/"
  : > "$BUS/claimed/b3.claude:opus"

  local logf="$BATS_TEST_TMPDIR/b3.log"
  "$RUNSH" >"$logf" 2>&1 3>&- &
  BG_PIDS+=("$!")

  # _enqueue_pending_specs runs at the very start, before the pool ever polls — this orphan claim
  # is a deliberate fixture (no real worker behind it) and would gate-hang forever, so the run is
  # aborted below rather than waited out; a short sleep is enough to observe the sweep's decision.
  sleep 1
  [ -e "$BUS/specs/b3.prompt" ]
  [ ! -e "$BUS/queue/b3.prompt" ]
  grep -q "b3 is currently claimed" "$logf"

  if [ -f "$BUS/run.pgid" ]; then
    kill -- "-$(cat "$BUS/run.pgid")" 2>/dev/null || true
  fi
  wait "${BG_PIDS[0]}" 2>/dev/null || true
  BG_PIDS=()
}

@test "spec01 FR-B dotted ids: a stale claim on 'foo.bar' does not falsely skip sweeping a fresh 'foo'" {
  _write_conf "claude:opus" 4 15
  _fake FAKE_CLAUDE_RESULT "OK"
  mkdir -p "$BUS/claimed"
  # foo.bar's claim predates this run and is stale (past LEASE_MIN=15m) — reap() reclaims + re-runs
  # it normally once the pool starts, so THIS run's own gate still closes; what's under test is
  # _enqueue_pending_specs' decision at sweep time, which runs BEFORE reap ever touches it — a bare
  # glob (claimed/"foo".*) would prefix-match this and wrongly skip "foo" too.
  printf 'stale dotted-id claim' > "$BUS/claimed/foo.bar.claude:opus"
  touch -d '-20 minutes' "$BUS/claimed/foo.bar.claude:opus"
  _enqueue foo "a fresh id sharing a glob prefix with the dotted claim"

  run timeout 25 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/foo" ]
  [ -f "$BUS/done/foo.bar" ]
  [ ! -e "$BUS/specs/foo.prompt" ]
}

@test "spec01 FR-B empty-card refusal (2026-07-29): sweep refuses an empty .write sidecar, leaves both card files in specs/, good sibling still completes" {
  _write_conf "claude:opus" 4 15
  _fake FAKE_CLAUDE_RESULT "good sibling answer"
  _enqueue e1 "card whose .write sidecar is whitespace-only"
  printf '   \n\t\n' > "$BUS/specs/e1.write"
  _enqueue g1 "good sibling card, unaffected by e1's refusal"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/g1" ]
  [ "$(<"$BUS/res-g1.txt")" = "good sibling answer" ]
  # e1 stays put — both files, not swept into queue/ — for the operator to fix or remove
  [ -f "$BUS/specs/e1.prompt" ]
  [ -f "$BUS/specs/e1.write" ]
  [ ! -e "$BUS/queue/e1.prompt" ]
  [ ! -e "$BUS/queue/e1.write" ]
  [[ "$output" == *"refused at sweep"* ]]
}

@test "spec04 FR-C: TIMEOUT_GLM overrides WORKER_TIMEOUT_SEC for the glm lane only; the claude lane keeps using the global default" {
  _write_conf "claude:opus" 4 15
  cat >> "$CONF" <<'EOF2'
WORKER_TIMEOUT_SEC=60
EOF2
  export TIMEOUT_GLM=1
  printf 'Z_AI_CODING_KEY=test-glm-key\n' > "$BATS_TEST_TMPDIR/envmaster"
  export ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster"

  _fake FAKE_CLAUDE_ONCE_MARKER "$BATS_TEST_TMPDIR/tc-once"
  _fake FAKE_CLAUDE_ONCE_MODE hang
  _enqueue tc1 "glm branch that hangs — TIMEOUT_GLM=1 must kill it fast, not wait the 60s default"
  echo "glm:glm-5.2" > "$BUS/specs/tc1.lane"

  _fake FAKE_CLAUDE_DELAY 3
  _fake FAKE_CLAUDE_RESULT "claude survived"
  _enqueue tc2 "claude branch — slower than TIMEOUT_GLM=1 but well under WORKER_TIMEOUT_SEC=60"

  # 30s bound, not 15 (2026-08-01: the load-flakiest test in the suite — engine startup + the 3s
  # worker overran 15s on a saturated box). Still far under WORKER_TIMEOUT_SEC=60: if TIMEOUT_GLM=1
  # were ignored and tc1 waited the 60s default, this bound still fails the test — the property
  # proven is unchanged.
  run timeout 30 "$RUNSH"
  [ "$status" -ne 0 ]                    # tc1 parked (pinned, no fallback lane)
  [ -f "$BUS/limits/tc1.parked" ]
  [ -f "$BUS/done/tc2" ]
  [ "$(<"$BUS/res-tc2.txt")" = "claude survived" ]
}

@test "spec04 FR-C: an unset TIMEOUT_<LANE> falls back to WORKER_TIMEOUT_SEC" {
  _write_conf "claude:opus" 4 15
  cat >> "$CONF" <<'EOF2'
WORKER_TIMEOUT_SEC=2
EOF2
  unset TIMEOUT_GLM || true
  printf 'Z_AI_CODING_KEY=test-glm-key\n' > "$BATS_TEST_TMPDIR/envmaster"
  export ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster"
  _fake FAKE_CLAUDE_ONCE_MARKER "$BATS_TEST_TMPDIR/tc3-once"
  _fake FAKE_CLAUDE_ONCE_MODE hang
  _enqueue tc3 "glm branch, no TIMEOUT_GLM override — must fall back to the global 2s"
  echo "glm:glm-5.2" > "$BUS/specs/tc3.lane"

  run timeout 15 "$RUNSH"
  [ "$status" -ne 0 ]
  [ -f "$BUS/limits/tc3.parked" ]
}

@test "spec12 FR-D: run-<id>.jsonl rotates per retry attempt — .jsonl.1/.jsonl.2 keep earlier attempts, current file is the last attempt only" {
  _write_conf "claude:opus" 4 15
  cat >> "$CONF" <<'EOF2'
MAX_LANE_RETRIES=3
EOF2
  local counter="$BATS_TEST_TMPDIR/fr-d-attempts"
  _fake FAKE_CLAUDE_ATTEMPT_COUNTER "$counter"
  _enqueue frd1 "card that fails every attempt on the same lane, retried 3 times"

  run timeout 25 "$RUNSH"
  [ "$status" -ne 0 ]
  [ -f "$BUS/limits/frd1.parked" ]

  [ -f "$BUS/run-frd1.jsonl.1" ]
  [ -f "$BUS/run-frd1.jsonl.2" ]
  [ "$(jq -r '.attempt' "$BUS/run-frd1.jsonl.1")" = "1" ]
  [ "$(jq -r '.attempt' "$BUS/run-frd1.jsonl.2")" = "2" ]
  [ "$(jq -r '.attempt' "$BUS/run-frd1.jsonl")" = "3" ]

  # extension-anchored consumers (server.mjs /^run-.*\.jsonl$/, swarm-mon.sh run-*.jsonl globs)
  # must never mistake a rotated attempt for a live worker's current stream.
  local rotname; rotname="$(basename "$BUS/run-frd1.jsonl.1")"
  [[ "$rotname" != run-*.jsonl ]]
  [[ ! "$rotname" =~ ^run-.*\.jsonl$ ]]
}

@test "spec12 FR-D: a zero-byte run-<id>.jsonl from a failed attempt is not rotated" {
  _write_conf "claude:opus" 4 15
  cat >> "$CONF" <<'EOF2'
MAX_LANE_RETRIES=2
EOF2
  _fake FAKE_CLAUDE_SILENT_FAIL 1
  _enqueue frdz "attempt produces zero bytes — nothing to rotate"

  run timeout 20 "$RUNSH"
  [ "$status" -ne 0 ]
  [ -f "$BUS/limits/frdz.parked" ]
  [ ! -e "$BUS/run-frdz.jsonl.1" ]
}

@test "spec10 FR-E: a write landing only under .git/ does not satisfy the diff gate — rejected and parked" {
  _write_conf "claude:opus" 4 15
  local target="$BATS_TEST_TMPDIR/r-e-git"
  mkdir -p "$target/.git"
  touch -d '10 seconds ago' "$target" "$target/.git"
  _fake FAKE_CLAUDE_RESULT "claims done, only touched .git/index"
  _fake FAKE_CLAUDE_WRITE_FILE ".git/index"
  _enqueue reg1 "write card whose only touched path is under .git/"
  printf '%s' "$target" > "$BUS/specs/reg1.write"

  run timeout 25 "$RUNSH"
  [ "$status" -ne 0 ]
  [ ! -e "$BUS/done/reg1" ]
  [ -f "$BUS/limits/reg1.parked" ]
}

@test "spec10 FR-E: bumping only the write target's own directory mtime (create+rm a file) does not satisfy the diff gate" {
  _write_conf "claude:opus" 4 15
  local target="$BATS_TEST_TMPDIR/r-e-dirbump"
  mkdir -p "$target"
  touch -d '10 seconds ago' "$target"
  _fake FAKE_CLAUDE_RESULT "claims done, only bumped the dir's own mtime"
  _fake FAKE_CLAUDE_WRITE_FILE "transient.txt"
  _fake FAKE_CLAUDE_WRITE_THEN_RM 1
  _enqueue reg2 "write card that creates then deletes a file, leaving only a dir mtime bump"
  printf '%s' "$target" > "$BUS/specs/reg2.write"

  run timeout 25 "$RUNSH"
  [ "$status" -ne 0 ]
  [ ! -e "$BUS/done/reg2" ]
  [ -f "$BUS/limits/reg2.parked" ]
  [ -z "$(find "$target" -mindepth 1 2>/dev/null)" ]
}

@test "spec10 FR-E: a real file change under the write target still satisfies the diff gate alongside incidental .git churn" {
  _write_conf "claude:opus" 4 15
  local target="$BATS_TEST_TMPDIR/r-e-real"
  mkdir -p "$target/.git"
  touch -d '10 seconds ago' "$target" "$target/.git"
  _fake FAKE_CLAUDE_RESULT "wrote a real file"
  _fake FAKE_CLAUDE_WRITE_FILE "real.txt"
  _enqueue reg3 "write card with one real change plus a pre-existing .git dir"
  printf '%s' "$target" > "$BUS/specs/reg3.write"

  run timeout 25 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/reg3" ]
  [ -f "$target/real.txt" ]
}

@test "spec10 FR-E: the timeout-salvage path rejects .git-only churn the same way the success path does" {
  _write_conf "claude:opus" 4 15
  cat >> "$CONF" <<'EOF2'
WORKER_TIMEOUT_SEC=2
EOF2
  local target="$BATS_TEST_TMPDIR/sv-e-git"
  mkdir -p "$target/.git"
  touch -d '10 seconds ago' "$target" "$target/.git"
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-sve.jsonl"
  _fake FAKE_CLAUDE_ONCE_MARKER "$BATS_TEST_TMPDIR/sve-once"
  _fake FAKE_CLAUDE_ONCE_MODE hang
  _fake FAKE_CLAUDE_WRITE_FILE ".git/index"
  _enqueue sve "write card killed after touching only .git/ — salvage must still reject it"
  printf '%s' "$target" > "$BUS/specs/sve.write"

  run timeout 25 "$RUNSH"
  [ "$status" -ne 0 ]
  [ ! -e "$BUS/done/sve" ]
  [ -f "$BUS/limits/sve.parked" ]
  [ "$(jq -r 'select(.id=="sve" and .outcome=="timeout") | .class' "$SPEEDWARS_FILE")" = "timeout-watchdog" ]
}

@test "spec14 AC-5 pairing: a card parked via FR-4 session-limit + FR-3 chain-exhaustion is claimed on the seed chain's head after re-publish" {
  # Cross-agent pairing constraint (spec 14 AC-5): needs LIB-1's FR-4 (limit_error session-limit
  # detection, src/swarm-lib.sh) and CTL-1's swarm-ctl add/_reset_card_state — both had landed as
  # of this wave, but this test is written to the spec'd behavior regardless of build order.
  _write_conf "claude:opus" 4 15
  local ctl="$BATS_TEST_DIRNAME/../src/swarm-ctl"
  _fake FAKE_CLAUDE_ERROR_JSON '{"type":"result","subtype":"success","is_error":true,"result":"You'"'"'ve hit your session limit · resets 2:50am (Europe/Prague)"}'
  _enqueue ac5 "card whose only lane hits its session limit and exhausts the chain"

  run timeout 20 "$RUNSH"
  [ "$status" -ne 0 ]
  [ -f "$BUS/limits/ac5.parked" ]
  [ -f "$BUS/limits/claude.limited" ]
  [[ "$(<"$BUS/limits/claude.limited")" == *"session-limit"* ]]

  # operator recovery: cancel the stuck queue entry, clear the (long-TTL) lane flag by hand, then
  # re-publish the SAME id fresh — swarm-ctl add's own _reset_card_state (spec 14 FR-3) clears
  # .parked/.chain-<id>/.retries-<id>.
  run "$ctl" cancel ac5
  [ "$status" -eq 0 ]
  rm -f "$BUS/limits/claude.limited" "$BUS/limits/claude.limited.evidence"
  _fake FAKE_CLAUDE_ERROR_JSON ""
  _fake FAKE_CLAUDE_RESULT "answered on the seed chain's head after re-publish"

  local promptfile="$BATS_TEST_TMPDIR/ac5.prompt"
  printf 'retry from the top' > "$promptfile"
  run "$ctl" add "$promptfile"
  [ "$status" -eq 0 ]

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/ac5" ]
  [ "$(jq -r '.lane' "$BUS/done/ac5")" = "claude" ]
}

# --- spec 14 FR-1: cage-denied failure class ---------------------------------------------------


@test "spec14 FR-1: a read-denied card parks cage-denied — one spawn, no chain walk, paths evidenced, answer text never leaked" {
  _write_conf "claude:opus codex:gpt-5" 4 15
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-cage.jsonl"
  _fake FAKE_CLAUDE_RESULT "CANARYLEAK I was denied every read under the target and cannot proceed"
  _fake FAKE_CLAUDE_DENIALS_JSON "$(_cage_denials_fixture)"
  _fake FAKE_CODEX_RESULT "the fallback lane must never be reached"
  _enqueue cg1 "card the permission cage denies every read to"

  run timeout 20 "$RUNSH"
  [ "$status" -ne 0 ]
  [ -f "$BUS/limits/cg1.parked" ]
  [ -f "$BUS/limits/cg1.cage-denied" ]
  [ ! -e "$BUS/done/cg1" ]

  # NEVER chain-advanced: chain_advance is the only writer of limits/.chain-<id>, and FR-3's
  # chain_reset runs at the chain-exhausted park only — so a cage-denied park leaves that state
  # exactly as it found it (absent here).
  [ ! -e "$BUS/limits/.chain-cg1" ]
  # one spawn, not one per chain rung: the park is this branch's ONLY speedwars row
  [ "$(jq -s '[.[] | select(.id=="cg1")] | length' "$SPEEDWARS_FILE")" = "1" ]
  [ "$(jq -r 'select(.id=="cg1" and .outcome=="parked") | .class' "$SPEEDWARS_FILE")" = "cage-denied" ]

  # marker: line 1 is the count (Bash denial excluded -> 3, not 4), then DEDUPED denied paths
  [ "$(head -1 "$BUS/limits/cg1.cage-denied")" = "denials=3" ]
  [ "$(grep -c . "$BUS/limits/cg1.cage-denied")" = "3" ]
  grep -q '^/tgt/apps/brain-api/src/cockpit/contract.ts$' "$BUS/limits/cg1.cage-denied"
  grep -q '^MartCockpitBetWideRowSchema$' "$BUS/limits/cg1.cage-denied"

  # PII: paths and counts only — no answer text in either marker, and no laundered res file left
  ! grep -q CANARYLEAK "$BUS/limits/cg1.cage-denied"
  ! grep -q CANARYLEAK "$BUS/limits/cg1.parked"
  [ ! -e "$BUS/res-cg1.txt" ]

  # loud: names the count and the denied paths
  [[ "$output" == *"cage denied 3 read-class"* ]]
  [[ "$output" == *"contract.ts"* ]]
}

@test "spec14 FR-1: CAGE_DENY_MAX=20 opts out — the same cage-denied fixture finalizes through the existing gates unchanged" {
  _write_conf "claude:opus codex:gpt-5" 4 15
  cat >> "$CONF" <<'EOF2'
CAGE_DENY_MAX=20
EOF2
  _fake FAKE_CLAUDE_RESULT "denied some reads but delivered anyway"
  _fake FAKE_CLAUDE_DENIALS_JSON "$(_cage_denials_fixture)"
  _enqueue cg2 "card the cage denies a few reads to, which still delivers"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/cg2" ]
  [ ! -e "$BUS/limits/cg2.parked" ]
  [ ! -e "$BUS/limits/cg2.cage-denied" ]
  [ "$(<"$BUS/res-cg2.txt")" = "denied some reads but delivered anyway" ]
}
