#!/usr/bin/env bats
# Unit tests for src/swarm-lib.sh (shard 2 of 2 — loads tests/helpers/swarm-lib-fixture.bash):
# cockpit staleness (_mon_web_fresh), speedwars evidence (speed_row/run_summary/lane_summary),
# spec 10 role-classes (review chains, _judge_ok, budgets, answer_unusable), spec 11 succession,
# spec 12/17 run meta, spec 14 (manifest scoping, marker reason lines, session-limit visibility,
# sibling-liveness, cage denials), backlog-27/28 validation, broken_flag, _payg_denied,
# env_master_preflight, round4 fixes, spec 04 per-lane timeouts, bus_archive.
#
# Project: unimatrix — multi-model swarm orchestrator driven from Claude Code
# Module:  tests/swarm-lib-2.bats
# Deps:    bats-core, src/swarm-lib.sh, tests/helpers/swarm-lib-fixture.bash
# Tested:  n/a — this is the test file (fixtures live under $BATS_TEST_TMPDIR, docs/02-build-pitfalls.md §9)

load 'helpers/swarm-lib-fixture'

# --- F6/F7: cockpit staleness — _mon_web_fresh ---------------------------------------------------
# curl is stubbed on PATH rather than booting a real server: mon_web_ensure's relaunch branch would
# create the operator's REAL `svc-unimatrix` user unit on a systemd box, which no unit test may do.

# _stub_curl <body> [exit-rc] — a PATH curl that ignores its argv and prints <body>.
_stub_curl() {
  local bin="$BATS_TEST_TMPDIR/stubbin"
  mkdir -p "$bin"
  { printf '#!/usr/bin/env bash\n'
    printf 'printf %%s %q\n' "$1"
    printf 'exit %s\n' "${2:-0}"
  } > "$bin/curl"
  chmod +x "$bin/curl"
  printf '%s' "$bin"
}

@test "_mon_web_fresh: a cockpit serving THIS checkout's HEAD is fresh (rc 0)" {
  local repo="$BATS_TEST_DIRNAME/.." head bin
  head="$(git -C "$repo" rev-parse --short HEAD)"
  bin="$(_stub_curl "{\"ok\":true,\"head\":\"$head\"}")"
  PATH="$bin:$PATH" run _mon_web_fresh 4747 "$repo"
  [ "$status" -eq 0 ]
}

@test "F7: a cockpit booted at an OLDER commit is stale (rc 2), not adopted as already-up" {
  local bin; bin="$(_stub_curl '{"ok":true,"head":"0000dead"}')"
  PATH="$bin:$PATH" run _mon_web_fresh 4747 "$BATS_TEST_DIRNAME/.."
  [ "$status" -eq 2 ]
}

@test "F7: a pre-FR-4 cockpit whose /health carries no head field is stale (rc 2)" {
  local bin; bin="$(_stub_curl '{"ok":true}')"
  PATH="$bin:$PATH" run _mon_web_fresh 4747 "$BATS_TEST_DIRNAME/.."
  [ "$status" -eq 2 ]
}

@test "_mon_web_fresh: nothing listening is rc 1 (nothing to stop), distinct from stale" {
  local bin; bin="$(_stub_curl '' 7)"
  PATH="$bin:$PATH" run _mon_web_fresh 4747 "$BATS_TEST_DIRNAME/.."
  [ "$status" -eq 1 ]
}

@test "F5: the systemd-run cockpit launch passes BUSDIR through --setenv, not just PORT" {
  # Brittle-but-honest: a systemd --user unit does NOT inherit the spawning shell's env, so the
  # only proof that the non-default bus reaches server.mjs is the argv itself. bats cannot run
  # systemd-run against the real user manager, so this greps the one line that carries it.
  run grep -n 'setenv=BUSDIR' "$BATS_TEST_DIRNAME/../src/swarm-lib.sh"
  [ "$status" -eq 0 ]
  run grep -n 'setenv=SWARM_CONF' "$BATS_TEST_DIRNAME/../src/swarm-lib.sh"
  [ "$status" -eq 0 ]
  # every other env server.mjs reads and the fallback branch inherits for free
  run grep -n 'setenv=SPEEDWARS_FILE' "$BATS_TEST_DIRNAME/../src/swarm-lib.sh"
  [ "$status" -eq 0 ]
}

# --- speedwars: speed_row per-branch evidence (specs/08-speedwars.md FR-8) ----------------------

@test "speed_row: grok end-envelope — row lands with usage, outcome, served model, stop reason" {
  bus_init "$BUS"
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw.jsonl" SPEEDWARS_RUN="t-run"
  {
    echo '{"type":"thought","data":"x"}'
    echo '{"type":"end","stopReason":"Cancelled","num_turns":3,"total_cost_usd":0.12,"modelUsage":{"grok-4.5-build":{"costUSD":0.12}},"usage":{"input_tokens":100,"output_tokens":20,"cache_read_input_tokens":50,"reasoning_tokens":5}}'
  } > "$BUS/run-sp1.jsonl"

  speed_row "$BUS" sp1 "grok:grok-4.5" done 0 1

  run jq -c . "$SPEEDWARS_FILE"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.run' "$SPEEDWARS_FILE")" = "t-run" ]
  [ "$(jq -r '.requested' "$SPEEDWARS_FILE")" = "grok:grok-4.5" ]
  [ "$(jq -r '.served_lane' "$SPEEDWARS_FILE")" = "grok" ]
  [ "$(jq -r '.served_model' "$SPEEDWARS_FILE")" = "grok-4.5-build" ]
  [ "$(jq -r '.outcome' "$SPEEDWARS_FILE")" = "done" ]
  [ "$(jq -r '.pinned' "$SPEEDWARS_FILE")" = "true" ]
  [ "$(jq -r '.tokens_out' "$SPEEDWARS_FILE")" = "20" ]
  [ "$(jq -r '.tokens_reasoning' "$SPEEDWARS_FILE")" = "5" ]
  [ "$(jq -r '.stop' "$SPEEDWARS_FILE")" = "Cancelled" ]
  [ "$(jq -r '.cost_usd' "$SPEEDWARS_FILE")" = "0.12" ]
}

@test "speed_row: claude result-envelope — timing + error fields extracted" {
  bus_init "$BUS"
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw2.jsonl"
  {
    echo '{"type":"assistant","message":{"model":"claude-sonnet-5"}}'
    echo '{"type":"result","num_turns":7,"total_cost_usd":0.5,"duration_ms":9000,"duration_api_ms":8500,"ttft_ms":1200,"is_error":false,"api_error_status":null,"usage":{"input_tokens":10,"output_tokens":200,"cache_read_input_tokens":999}}'
  } > "$BUS/run-sp2.jsonl"

  speed_row "$BUS" sp2 "claude:sonnet" done 0 0

  [ "$(jq -r '.ttft_ms' "$SPEEDWARS_FILE")" = "1200" ]
  [ "$(jq -r '.duration_api_ms' "$SPEEDWARS_FILE")" = "8500" ]
  [ "$(jq -r '.is_error' "$SPEEDWARS_FILE")" = "false" ]
  [ "$(jq -r '.turns' "$SPEEDWARS_FILE")" = "7" ]
  [ "$(jq -r '.pinned' "$SPEEDWARS_FILE")" = "false" ]
}

@test "speed_row: kimi result-envelope falls into the claude/glm default branch (tokens + served model extracted)" {
  bus_init "$BUS"
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-kimi.jsonl"
  {
    echo '{"type":"assistant","message":{"model":"kimi-k3"}}'
    echo '{"type":"result","num_turns":2,"duration_ms":4000,"usage":{"input_tokens":1000000,"output_tokens":100000,"cache_read_input_tokens":1000000}}'
  } > "$BUS/run-spk1.jsonl"

  speed_row "$BUS" spk1 "kimi:kimi-k3" done 0 1

  [ "$(jq -r '.tokens_in' "$SPEEDWARS_FILE")" = "1000000" ]
  [ "$(jq -r '.tokens_out' "$SPEEDWARS_FILE")" = "100000" ]
  [ "$(jq -r '.served_lane' "$SPEEDWARS_FILE")" = "kimi" ]
  [ "$(jq -r '.served_model' "$SPEEDWARS_FILE")" = "kimi-k3" ]
}

@test "speed_row: kimi cost_usd is RECOMPUTED at Moonshot list price, never the claude-priced total_cost_usd" {
  bus_init "$BUS"
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-kimi-cost.jsonl"
  {
    echo '{"type":"assistant","message":{"model":"kimi-k3"}}'
    echo '{"type":"result","num_turns":1,"usage":{"input_tokens":1000000,"cache_read_input_tokens":1000000,"output_tokens":100000},"total_cost_usd":9.99}'
  } > "$BUS/run-spk2.jsonl"

  speed_row "$BUS" spk2 "kimi:kimi-k3" done 0 1

  [ "$(jq -r '.cost_usd == 4.8' "$SPEEDWARS_FILE")" = "true" ]
  [ "$(jq -r '.cost_usd == 9.99' "$SPEEDWARS_FILE")" = "false" ]
}

@test "speed_row: default path never scaffolds docs/ops into the busdir-parent (FR-3)" {
  bus_init "$BUS"
  unset SPEEDWARS_FILE
  printf '{"type":"end","usage":{}}\n' > "$BUS/run-sp3.jsonl"

  speed_row "$BUS" sp3 "grok:grok-4.5" done 0 0

  [ ! -e "$(dirname "$BUS")/docs" ]
}

@test "speed_row: codex turn.completed envelope — tokens + turn count + gpt-5-codex list recompute (fresh = in − cached)" {
  bus_init "$BUS"
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw4.jsonl"
  {
    echo '{"type":"thread.started","thread_id":"t1"}'
    echo '{"type":"turn.completed","usage":{"input_tokens":500,"cached_input_tokens":300,"output_tokens":40,"reasoning_output_tokens":10}}'
    echo '{"type":"turn.completed","usage":{"input_tokens":600,"cached_input_tokens":300,"output_tokens":50,"reasoning_output_tokens":12}}'
  } > "$BUS/run-sp4.jsonl"

  speed_row "$BUS" sp4 "codex:default" done 0 0

  [ "$(jq -r '.tokens_in' "$SPEEDWARS_FILE")" = "600" ]
  [ "$(jq -r '.tokens_reasoning' "$SPEEDWARS_FILE")" = "12" ]
  [ "$(jq -r '.turns' "$SPEEDWARS_FILE")" = "2" ]
  # spec 08 2026-07-26 amendment: (600-300)*1.25 + 300*0.125 + 50*10 = 912.5 → /1e6
  [ "$(jq -r '.cost_usd == 0.0009125' "$SPEEDWARS_FILE")" = "true" ]
  [ "$(jq -r '.cost_basis' "$SPEEDWARS_FILE")" = "recomputed-list" ]
}

@test "speed_row: glm cost_usd is ALWAYS recomputed at Z.ai list — the claude-priced envelope figure never survives" {
  bus_init "$BUS"
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-glm-cost.jsonl"
  {
    echo '{"type":"assistant","message":{"model":"glm-5.2"}}'
    echo '{"type":"result","num_turns":1,"usage":{"input_tokens":1000000,"cache_creation_input_tokens":500000,"cache_read_input_tokens":1000000,"output_tokens":100000},"total_cost_usd":9.99}'
  } > "$BUS/run-spg1.jsonl"

  speed_row "$BUS" spg1 "glm:glm-5.2" done 0 1

  # (1.0M + 0.5M fresh-class) * 1.40 + 1.0M * 0.26 + 0.1M * 4.40 = 2.10 + 0.26 + 0.44 = 2.80
  [ "$(jq -r '.cost_usd == 2.8' "$SPEEDWARS_FILE")" = "true" ]
  [ "$(jq -r '.cost_usd == 9.99' "$SPEEDWARS_FILE")" = "false" ]
  [ "$(jq -r '.cost_basis' "$SPEEDWARS_FILE")" = "recomputed-list" ]
}

@test "speed_row: cost_basis vocabulary — grok envelope-pool, grok recomputed fallback, gemini unpriced, claude envelope-list" {
  bus_init "$BUS"
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-basis.jsonl"

  printf '%s\n' '{"type":"end","total_cost_usd":0.05,"usage":{"input_tokens":100,"output_tokens":10},"num_turns":1,"stopReason":"done"}' > "$BUS/run-b1.jsonl"
  speed_row "$BUS" b1 "grok:grok-4.5" done 0 0
  printf '%s\n' '{"type":"end","usage":{"input_tokens":30000,"cache_read_input_tokens":20000,"output_tokens":1000},"num_turns":1,"stopReason":"done"}' > "$BUS/run-b2.jsonl"
  speed_row "$BUS" b2 "grok:grok-4.5" done 0 0
  printf '%s\n' '{"type":"result","stats":{"input_tokens":900,"output_tokens":80,"cached":400,"duration_ms":1}}' > "$BUS/run-b3.jsonl"
  speed_row "$BUS" b3 "gemini:gemini-2.5-pro" done 0 0
  printf '%s\n' '{"type":"result","num_turns":1,"usage":{"input_tokens":10,"output_tokens":5},"total_cost_usd":0.01}' > "$BUS/run-b4.jsonl"
  speed_row "$BUS" b4 "claude:sonnet" done 0 0

  [ "$(jq -rs '.[0].cost_basis' "$SPEEDWARS_FILE")" = "envelope-pool" ]
  [ "$(jq -rs '.[1].cost_basis' "$SPEEDWARS_FILE")" = "recomputed-list" ]
  # (30000-20000)*2.0 + 20000*0.30 + 1000*6.0 = 32000 → /1e6
  [ "$(jq -rs '.[1].cost_usd == 0.032' "$SPEEDWARS_FILE")" = "true" ]
  [ "$(jq -rs '.[2].cost_basis' "$SPEEDWARS_FILE")" = "unpriced-tier-unknown" ]
  [ "$(jq -rs '.[2] | has("cost_usd")' "$SPEEDWARS_FILE")" = "false" ]
  [ "$(jq -rs '.[3].cost_basis' "$SPEEDWARS_FILE")" = "envelope-list" ]
  [ "$(jq -rs '.[3].cost_usd == 0.01' "$SPEEDWARS_FILE")" = "true" ]
}

@test "speed_row: gemini result.stats envelope + non-done outcome recorded" {
  bus_init "$BUS"
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw5.jsonl"
  {
    echo '{"type":"init","session_id":"g1"}'
    echo '{"type":"result","stats":{"input_tokens":900,"output_tokens":80,"cached":400,"duration_ms":4200}}'
  } > "$BUS/run-sp5.jsonl"

  speed_row "$BUS" sp5 "gemini:gemini-2.5-pro" timeout 124 0

  [ "$(jq -r '.outcome' "$SPEEDWARS_FILE")" = "timeout" ]
  [ "$(jq -r '.wrc' "$SPEEDWARS_FILE")" = "124" ]
  [ "$(jq -r '.tokens_in' "$SPEEDWARS_FILE")" = "900" ]
  [ "$(jq -r '.duration_api_ms' "$SPEEDWARS_FILE")" = "4200" ]
}

# --- speedwars: report reader tolerates mixed run-meta schemas (FR-7 crash regression) ----------

@test "speedwars-report: scalar 'cards' run-meta row does not crash the reader" {
  # A summary-style run-meta row carrying a scalar count (cards:N) instead of the FR-4 object
  # shape must be skipped, not iterated — else `to_entries` errors and the whole report dies
  # ('number (N) has no keys'). Append-only ledger mixes schemas; the reader must survive it.
  local F="$BATS_TEST_TMPDIR/sw-report.jsonl"
  {
    echo '{"ts":"2026-07-19T20:00:00Z","run":"r","id":"b1","served_lane":"glm","outcome":"done","wall_secs":100,"tokens_out":500}'
    echo '{"ts":"2026-07-19T20:00:01Z","type":"run-meta","run":"r","cards":17,"complexity":{"C2":6}}'
  } > "$F"

  run bash "$BATS_TEST_DIRNAME/../src/speedwars-report.sh" "$F"
  [ "$status" -eq 0 ]
  [[ "$output" == *"glm"* ]]
}

# --- spec 10: role classes & universal fallback (RED — plans/003-role-tier-fallback/CONTRACT.md) --

# --- FR-R1: conf_load gains CLASS_REVIEW/CLASS_EXEC/REVIEW_CHAIN/PIN_WAIT_SEC ---------------------

@test "spec10 FR-R1: conf_load defaults CLASS_REVIEW/CLASS_EXEC/REVIEW_CHAIN/PIN_WAIT_SEC with no conf file" {
  unset CLASS_REVIEW CLASS_EXEC REVIEW_CHAIN PIN_WAIT_SEC
  conf_load "$BATS_TEST_TMPDIR/nonexistent.conf"
  [ "$CLASS_REVIEW" = "codex kimi" ]
  [ "$CLASS_EXEC" = "grok glm" ]
  [ "$REVIEW_CHAIN" = "" ]
  [ "$PIN_WAIT_SEC" = "120" ]
}

@test "spec10 FR-R1: conf_load env value for CLASS_REVIEW wins over a conflicting file value (env > file precedence)" {
  echo 'CLASS_REVIEW="grok glm"' > "$BATS_TEST_TMPDIR/swarm.conf"
  export CLASS_REVIEW="codex gemini"
  conf_load "$BATS_TEST_TMPDIR/swarm.conf"
  [ "$CLASS_REVIEW" = "codex gemini" ]
}

@test "spec10 FR-R1: conf_load rejects a bad token in CLASS_REVIEW (loud config-load error naming key + token)" {
  unset CLASS_REVIEW
  echo 'CLASS_REVIEW="codex bogus-lane"' > "$BATS_TEST_TMPDIR/swarm.conf"
  run conf_load "$BATS_TEST_TMPDIR/swarm.conf"
  [ "$status" -ne 0 ]
  [[ "$output" == *"CLASS_REVIEW"* ]]
  [[ "$output" == *"bogus-lane"* ]]
}

@test "spec10 FR-R1: conf_load rejects an empty CLASS_REVIEW as a validation error" {
  unset CLASS_REVIEW
  echo 'CLASS_REVIEW=""' > "$BATS_TEST_TMPDIR/swarm.conf"
  run conf_load "$BATS_TEST_TMPDIR/swarm.conf"
  [ "$status" -ne 0 ]
}

# --- FR-R3/R4: _judge_ok shared guard + review_chain_for ------------------------------------------

@test "spec10 FR-R3: _judge_ok rejects a candidate that is the exact author lane" {
  run _judge_ok codex codex
  [ "$status" -eq 1 ]
}

@test "spec10 FR-R4: _judge_ok rejects a same-family candidate (claude vs fable, both anthropic)" {
  run _judge_ok claude fable
  [ "$status" -eq 1 ]
}

@test "spec10 FR-R3/R4: _judge_ok accepts a different-lane, different-family candidate (codex vs glm)" {
  unset PLAN ORCHESTRATOR
  run _judge_ok codex glm
  [ "$status" -eq 0 ]
}

@test "spec10 FR-R3: review_chain_for drops the author from the default CLASS_REVIEW chain (author=codex -> kimi:kimi-k3)" {
  bus_init "$BUS"
  CLASS_REVIEW="codex kimi"
  REVIEW_CHAIN=""
  unset PLAN ORCHESTRATOR
  [ "$(review_chain_for codex "$BUS")" = "kimi:kimi-k3" ]
}

@test "spec10 FR-R3: review_chain_for puts codex:default first when the author is kimi" {
  bus_init "$BUS"
  CLASS_REVIEW="codex kimi"
  REVIEW_CHAIN=""
  unset PLAN ORCHESTRATOR
  local chain
  chain="$(review_chain_for kimi "$BUS")"
  [ "${chain%% *}" = "codex:default" ]
}

# --- FR-R16: _judge_ok config-guard clause (candidate == non-fable PLAN/ORCHESTRATOR) --------------

@test "spec10 FR-R16: _judge_ok rejects a candidate that is the current non-fable PLAN (role-collision guard)" {
  export PLAN=codex
  unset ORCHESTRATOR
  run _judge_ok codex glm
  [ "$status" -eq 1 ]
}

@test "spec10 FR-R16: _judge_ok does not reject on the PLAN clause when PLAN=fable (regression guard)" {
  export PLAN=fable
  unset ORCHESTRATOR
  run _judge_ok codex glm
  [ "$status" -eq 0 ]
}

# --- FR-R5: kimi_budget_ok — BUDGET_USD gate on kimi fallback --------------------------------------

@test "spec10 FR-R5: kimi_budget_ok rc0 (unrestricted) when BUDGET_USD=0" {
  bus_init "$BUS"
  export BUDGET_USD=0
  run kimi_budget_ok "$BUS"
  [ "$status" -eq 0 ]
}

@test "spec10 FR-R5: kimi_budget_ok rc1 when accumulated kimi.spend already exceeds BUDGET_USD" {
  bus_init "$BUS"
  printf '0.028' > "$BUS/limits/kimi.spend"
  export BUDGET_USD=0.02
  run kimi_budget_ok "$BUS"
  [ "$status" -eq 1 ]
}

@test "spec10 FR-R5: kimi_budget_ok rc0 when accumulated kimi.spend is still under BUDGET_USD" {
  bus_init "$BUS"
  printf '0.01' > "$BUS/limits/kimi.spend"
  export BUDGET_USD=0.02
  run kimi_budget_ok "$BUS"
  [ "$status" -eq 0 ]
}

# --- FR-R8: limit_error gains claude/gemini arms; lane_dead is existence-only ----------------------

@test "spec10 FR-R8: limit_error claude — OAuth-death text served as a normal result sets claude.dead, not claude.limited" {
  bus_init "$BUS"
  echo '{"type":"result","result":"OAuth session expired · Please run /login"}' > "$BUS/run-r8cl1.jsonl"
  run limit_error claude "$BUS" r8cl1
  [ "$status" -eq 1 ]
  [ -f "$BUS/limits/claude.dead" ]
  [ ! -f "$BUS/limits/claude.limited" ]
}

@test "spec10 FR-R8: limit_error claude — rate_limit_exceeded is a 2-strike sequence (rc2 then rc1+claude.limited)" {
  bus_init "$BUS"
  echo '{"type":"error","error":{"code":"rate_limit_exceeded","message":"rate limit exceeded"}}' > "$BUS/run-r8cl2.jsonl"
  run limit_error claude "$BUS" r8cl2
  [ "$status" -eq 2 ]
  [ ! -f "$BUS/limits/claude.limited" ]

  echo '{"type":"error","error":{"code":"rate_limit_exceeded","message":"rate limit exceeded"}}' > "$BUS/run-r8cl2b.jsonl"
  run limit_error claude "$BUS" r8cl2b
  [ "$status" -eq 1 ]
  [ -f "$BUS/limits/claude.limited" ]
}

@test "spec10 FR-R8: limit_error gemini — quota-exceeded error event parks (rc1 + gemini.limited)" {
  bus_init "$BUS"
  echo '{"type":"error","message":"Quota exceeded for quota metric generativelanguage.googleapis.com"}' > "$BUS/run-r8ge1.jsonl"
  run limit_error gemini "$BUS" r8ge1
  [ "$status" -eq 1 ]
  [ -f "$BUS/limits/gemini.limited" ]
}

@test "spec10 FR-R8: limit_error gemini — auth-death signature sets gemini.dead" {
  bus_init "$BUS"
  echo '{"type":"error","message":"Failed to authenticate: invalid credentials"}' > "$BUS/run-r8ge2.jsonl"
  run limit_error gemini "$BUS" r8ge2
  [ "$status" -eq 1 ]
  [ -f "$BUS/limits/gemini.dead" ]
}

@test "spec10 FR-R8: lane_dead is existence-only — a backdated .dead mtime still reports dead (rc0)" {
  bus_init "$BUS"
  dead_flag "$BUS" claude
  touch -d "-99999 seconds" "$BUS/limits/claude.dead"
  run lane_dead "$BUS" claude
  [ "$status" -eq 0 ]
}

# --- FR-R11: answer_unusable — cross-lane false-done classifier (rc0 = unusable) --------------------

@test "spec10 FR-R11: answer_unusable rc0 — OAuth session expired text in the served answer" {
  bus_init "$BUS"
  printf 'OAuth session expired · Please run /login' > "$BUS/res-r11au1.txt"
  run answer_unusable claude "$BUS" r11au1
  [ "$status" -eq 0 ]
  # spec 12 FR-1: rc0 also echoes the matched failure class on stdout — the auth-death substring
  # match, not the is_error/envelope-regex arms.
  [ "$output" = "auth-death" ]
}

@test "spec10 FR-R11: answer_unusable rc0 — Failed to authenticate text in the served answer" {
  bus_init "$BUS"
  printf 'Failed to authenticate with the provider' > "$BUS/res-r11au2.txt"
  run answer_unusable claude "$BUS" r11au2
  [ "$status" -eq 0 ]
  [ "$output" = "auth-death" ]
}

@test "spec10 FR-R11: answer_unusable rc0 — Not signed in text in the served answer" {
  bus_init "$BUS"
  printf 'Not signed in. Please run /login to continue.' > "$BUS/res-r11au3.txt"
  run answer_unusable codex "$BUS" r11au3
  [ "$status" -eq 0 ]
  [ "$output" = "auth-death" ]
}

@test "spec10 FR-R11: answer_unusable rc0 — last result event has is_error true" {
  bus_init "$BUS"
  printf 'looks like a normal answer' > "$BUS/res-r11au4.txt"
  echo '{"type":"result","result":"looks like a normal answer","is_error":true}' > "$BUS/run-r11au4.jsonl"
  run answer_unusable claude "$BUS" r11au4
  [ "$status" -eq 0 ]
  # spec 12 FR-1: the unconditional is_error==true arm classifies as api-error, even though this
  # text would otherwise be too long/benign to match any text signature.
  [ "$output" = "api-error" ]
}

@test "spec10 FR-R11: answer_unusable rc0 — GLM 5xx/429 error body served as the whole answer" {
  bus_init "$BUS"
  printf 'API Error: 529 {"error":{"type":"overloaded_error","message":"Overloaded"}}' > "$BUS/res-r11au5.txt"
  run answer_unusable glm "$BUS" r11au5
  [ "$status" -eq 0 ]
  [ "$output" = "server-error" ]
}

@test "spec10 FR-R11: answer_unusable rc1 — a healthy answer that merely mentions the word 'error' in prose (false-positive guard)" {
  bus_init "$BUS"
  printf 'The root cause was a null-pointer error in the parser; the fix adds a guard clause.' > "$BUS/res-r11au6.txt"
  run answer_unusable claude "$BUS" r11au6
  [ "$status" -eq 1 ]
  # spec 12 FR-1: rc1 (healthy) means NO class is echoed — empty stdout.
  [ -z "$output" ]
}

# --- FR-R2: chain_current/chain_advance seed resolution gains queue/<id>.chain --------------------

@test "spec10 FR-R2: chain_current reads the queue/<id>.chain orchestrator-pin seed when no walk position exists" {
  bus_init "$BUS"
  EXEC_CHAIN="claude:opus glm:glm-5.2"
  printf 'kimi:kimi-k3 codex:default' > "$BUS/queue/r2cc1.chain"
  [ "$(chain_current "$BUS" r2cc1)" = "kimi:kimi-k3" ]
}

@test "spec10 FR-R2: chain_advance walks the queue/<id>.chain seed and persists the new position in limits/.chain-<id>" {
  bus_init "$BUS"
  EXEC_CHAIN="claude:opus glm:glm-5.2"
  printf 'kimi:kimi-k3 codex:default' > "$BUS/queue/r2cc2.chain"
  chain_advance "$BUS" r2cc2
  [ "$(chain_current "$BUS" r2cc2)" = "codex:default" ]
  [ "$(<"$BUS/limits/.chain-r2cc2")" = "codex:default" ]
}

@test "spec10 FR-R2: chain_current with no .chain seed and no walk position still falls back to EXEC_CHAIN's head" {
  # passes today: regression guard
  bus_init "$BUS"
  EXEC_CHAIN="claude:opus glm:glm-5.2"
  [ "$(chain_current "$BUS" r2cc3)" = "claude:opus" ]
}

# --- FR-R9/R10: speed_row gains fallback_reason + billing -------------------------------------------

@test "spec10 FR-R9: speed_row reads limits/.fbreason-<id>, overrides requested to the original chain head, and consumes the file" {
  bus_init "$BUS"
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-fb.jsonl"
  printf 'limit codex' > "$BUS/limits/.fbreason-r9fb1"
  {
    echo '{"type":"assistant","message":{"model":"kimi-k3"}}'
    echo '{"type":"result","usage":{"input_tokens":1,"output_tokens":1}}'
  } > "$BUS/run-r9fb1.jsonl"

  speed_row "$BUS" r9fb1 "kimi:kimi-k3" done 0 0

  [ "$(jq -r '.requested' "$SPEEDWARS_FILE")" = "codex" ]
  [ "$(jq -r '.fallback_reason' "$SPEEDWARS_FILE")" = "limit" ]
  [ ! -f "$BUS/limits/.fbreason-r9fb1" ]
}

@test "spec10 FR-R10: speed_row marks a kimi-served row billing:real" {
  bus_init "$BUS"
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-bill-kimi.jsonl"
  {
    echo '{"type":"assistant","message":{"model":"kimi-k3"}}'
    echo '{"type":"result","usage":{"input_tokens":1,"output_tokens":1}}'
  } > "$BUS/run-r10bk1.jsonl"

  speed_row "$BUS" r10bk1 "kimi:kimi-k3" done 0 0

  [ "$(jq -r '.billing' "$SPEEDWARS_FILE")" = "real" ]
}

@test "spec10 FR-R10: speed_row marks a non-kimi (glm) served row billing:pool" {
  bus_init "$BUS"
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-bill-glm.jsonl"
  echo '{"type":"result","usage":{"input_tokens":1,"output_tokens":1}}' > "$BUS/run-r10bg1.jsonl"

  speed_row "$BUS" r10bg1 "glm:glm-5.2" done 0 0

  [ "$(jq -r '.billing' "$SPEEDWARS_FILE")" = "pool" ]
}

# --- spec 12 FR-1: speed_row gains an optional 7th `class` positional arg ------------------------

@test "spec12 FR-1: speed_row with a 7th class arg emits a .class key" {
  bus_init "$BUS"
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-class1.jsonl"
  echo '{"type":"end","usage":{}}' > "$BUS/run-c12a.jsonl"

  speed_row "$BUS" c12a "claude:opus" timeout 124 0 "timeout-watchdog"

  [ "$(jq -r '.class' "$SPEEDWARS_FILE")" = "timeout-watchdog" ]
}

@test "spec12 FR-1: speed_row with NO 7th arg omits the class key entirely (absence-means-absent, never empty string)" {
  bus_init "$BUS"
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-class2.jsonl"
  echo '{"type":"end","usage":{}}' > "$BUS/run-c12b.jsonl"

  speed_row "$BUS" c12b "claude:opus" done 0 0

  [ "$(jq 'has("class")' "$SPEEDWARS_FILE")" = "false" ]
}

# --- spec 12 FR-3: run_summary aggregates a run's speedwars rows into one ledger record ----------

@test "spec12 FR-3: run_summary aggregates branches/done_n/parked_n/lanes from seeded ledger rows + limits/" {
  bus_init "$BUS"
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-rs1.jsonl" SPEEDWARS_RUN="rs-run"
  # Seed the ledger directly (run_summary must never re-derive from run-*.jsonl itself, only from
  # already-written speedwars rows) — two branches done, one parked, one retried (first row
  # superseded by its later done row: last-row-per-id wins).
  {
    echo '{"ts":"2026-07-25T00:00:00Z","run":"rs-run","id":"a1","requested":"claude:opus","served_lane":"claude","outcome":"done"}'
    echo '{"ts":"2026-07-25T00:00:01Z","run":"rs-run","id":"a2","requested":"codex:default","served_lane":"codex","outcome":"rate-limited","class":"rate-limit","fallback_reason":"limit"}'
    echo '{"ts":"2026-07-25T00:00:02Z","run":"rs-run","id":"a2","requested":"codex:default","served_lane":"claude","outcome":"done"}'
    echo '{"ts":"2026-07-25T00:00:03Z","run":"rs-run","id":"a3","requested":"grok:grok-4.5","served_lane":null,"outcome":"parked"}'
  } >> "$SPEEDWARS_FILE"
  mkdir -p "$BUS/limits"
  printf '18000' > "$BUS/limits/glm.limited"
  touch "$BUS/limits/grok.dead"

  run_summary "$BUS" full

  local last; last="$(tail -n1 "$SPEEDWARS_FILE")"
  [ "$(jq -r '.type' <<<"$last")" = "run-summary" ]
  [ "$(jq -r '.run' <<<"$last")" = "rs-run" ]
  [ "$(jq -r '.mode' <<<"$last")" = "full" ]
  [ "$(jq -r '.done_n' <<<"$last")" = "2" ]
  [ "$(jq -r '.parked_n' <<<"$last")" = "1" ]
  [ "$(jq -r '.fallback_hops' <<<"$last")" = "1" ]
  [ "$(jq -r '.lanes_limited | sort | join(",")' <<<"$last")" = "glm" ]
  [ "$(jq -r '.lanes_dead | sort | join(",")' <<<"$last")" = "grok" ]
  # a2's LAST row wins — done via claude, not the earlier rate-limited codex attempt
  [ "$(jq -r '.branches.a2.lane' <<<"$last")" = "claude" ]
  [ "$(jq -r '.branches.a2.outcome' <<<"$last")" = "done" ]
  [ "$(jq 'has("branches") and (.branches | has("a1") and has("a2") and has("a3"))' <<<"$last")" = "true" ]
}

@test "spec12 FR-3: run_summary is a no-op (rc 0, no write) when no evidence surface exists" {
  bus_init "$BUS"
  unset SPEEDWARS_FILE
  # default path resolves under a busdir-parent whose docs/ dir was never scaffolded — same
  # no-op-without-evidence-surface doctrine as speed_row.

  run run_summary "$BUS" full
  [ "$status" -eq 0 ]
  [ ! -e "$(dirname "$BUS")/docs" ]
}

# --- spec 17 FR-7: run_summary stamps session_id/account/session_marker (P1-FR7) -----------------
#
# Pinned session_id -> marker pairs, computed by running the statusline's OWN sessionEmoji() body
# (~/.claude/helpers/statusline-lcars.mjs:106-115, chmod 444) verbatim in node BEFORE this test was
# written, so any future drift between that file and _session_stamp's bash mirror turns this red:
#
#   node -e '
#   const SESSION_EMOJI = ["🦊","🐙","🦉","🐢","🐝","🦈","🐋","🦜","🐞","🦕","🍄","🌵","🍒","🍋",
#     "🥝","🍩","🎲","🎯","🚀","🔮","🧲","🌋","🪐","🛸"];
#   function sessionEmoji(sid) {
#     if (!sid) return "🎲";
#     let h = 0;
#     for (let i = 0; i < sid.length; i++) h = (h * 31 + sid.charCodeAt(i)) >>> 0;
#     return SESSION_EMOJI[h % SESSION_EMOJI.length];
#   }
#   console.log(sessionEmoji("sess-fixture-001"), sessionEmoji("abc123"));'
#   => 🍄 🦊
@test "spec17 FR-7: _session_stamp mirrors the statusline's sessionEmoji() for two pinned session ids" {
  local out
  out="$(CLAUDE_CODE_SESSION_ID="sess-fixture-001" CLAUDE_ACCOUNT="" CLAUDE_CONFIG_DIR="" _session_stamp)"
  [ "$(sed -n '3p' <<<"$out")" = "🍄" ]
  out="$(CLAUDE_CODE_SESSION_ID="abc123" CLAUDE_ACCOUNT="" CLAUDE_CONFIG_DIR="" _session_stamp)"
  [ "$(sed -n '3p' <<<"$out")" = "🦊" ]
}

@test "spec17 FR-7: run_summary stamps session_id/account/session_marker from env into the row" {
  bus_init "$BUS"
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-sess1.jsonl" SPEEDWARS_RUN="rs-sess"
  echo '{"ts":"2026-07-25T00:00:00Z","run":"rs-sess","id":"a1","requested":"claude:opus","served_lane":"claude","outcome":"done"}' >> "$SPEEDWARS_FILE"
  export CLAUDE_CODE_SESSION_ID="sess-fixture-001" CLAUDE_ACCOUNT="acct-fixture"
  unset CLAUDE_CONFIG_DIR

  run_summary "$BUS" full

  local last; last="$(tail -n1 "$SPEEDWARS_FILE")"
  [ "$(jq -r '.session_id' <<<"$last")" = "sess-fixture-001" ]
  [ "$(jq -r '.account' <<<"$last")" = "acct-fixture" ]
  [ "$(jq -r '.session_marker' <<<"$last")" = "🍄" ]
}

@test "spec17 FR-7: run_summary stamps account from basename(CLAUDE_CONFIG_DIR) when CLAUDE_ACCOUNT is unset" {
  bus_init "$BUS"
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-sess2.jsonl" SPEEDWARS_RUN="rs-sess2"
  echo '{"ts":"2026-07-25T00:00:00Z","run":"rs-sess2","id":"a1","requested":"claude:opus","served_lane":"claude","outcome":"done"}' >> "$SPEEDWARS_FILE"
  unset CLAUDE_ACCOUNT
  export CLAUDE_CODE_SESSION_ID="abc123" CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/acct-dirs/soulfire"

  run_summary "$BUS" full

  local last; last="$(tail -n1 "$SPEEDWARS_FILE")"
  [ "$(jq -r '.account' <<<"$last")" = "soulfire" ]
  [ "$(jq -r '.session_marker' <<<"$last")" = "🦊" ]
}

@test "spec17 FR-7: run_summary nulls session_id/account/session_marker when the env is absent — row still valid" {
  bus_init "$BUS"
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-sess3.jsonl" SPEEDWARS_RUN="rs-sess3"
  echo '{"ts":"2026-07-25T00:00:00Z","run":"rs-sess3","id":"a1","requested":"claude:opus","served_lane":"claude","outcome":"done"}' >> "$SPEEDWARS_FILE"
  unset CLAUDE_CODE_SESSION_ID CLAUDE_ACCOUNT CLAUDE_CONFIG_DIR

  run_summary "$BUS" full

  local last; last="$(tail -n1 "$SPEEDWARS_FILE")"
  [ "$(jq -r '.type' <<<"$last")" = "run-summary" ]
  [ "$(jq -r '.done_n' <<<"$last")" = "1" ]
  [ "$(jq 'has("session_id") and has("account") and has("session_marker")' <<<"$last")" = "true" ]
  [ "$(jq -r '.session_id' <<<"$last")" = "null" ]
  [ "$(jq -r '.account' <<<"$last")" = "null" ]
  [ "$(jq -r '.session_marker' <<<"$last")" = "null" ]
}

# --- spec 12 FR-6: bus_init seeds notes-lessons.md -----------------------------------------------

@test "spec12 FR-6: bus_init seeds notes-lessons.md exactly once" {
  bus_init "$BUS"
  [ -f "$BUS/notes-lessons.md" ]
  local first; first="$(<"$BUS/notes-lessons.md")"
  [ -n "$first" ]

  # a second bus_init call (idempotent bus setup, e.g. every full_run/verify_run call site) must
  # NOT clobber a notebook the orchestrator has since written into.
  printf '\nobservation -> lesson\n' >> "$BUS/notes-lessons.md"
  local appended; appended="$(<"$BUS/notes-lessons.md")"
  bus_init "$BUS"
  [ "$(<"$BUS/notes-lessons.md")" = "$appended" ]
}

@test "spec10 FR-R11: answer_unusable rc1 — a LONG healthy answer quoting auth/error signatures (review-card false-positive guard)" {
  # Live incident 2026-07-24: a codex spec-adherence review QUOTING "OAuth session expired" and
  # "API error" was rejected 3x and parked. Text signatures only apply to short (<=600 char)
  # answers — the observed false-done class is always the error dump AS the whole answer.
  source "$LIB"
  local bus="$BATS_TEST_TMPDIR/bus-r11long"; bus_init "$bus"
  { printf 'FINDINGS: the classifier must catch "OAuth session expired" and "Failed to authenticate" '
    printf 'text plus GLM bodies like API error 529 overloaded and status 429 responses. '
    for i in $(seq 1 30); do printf 'Long healthy review prose line %s with substantive analysis. ' "$i"; done
  } > "$bus/res-r11long.txt"
  run answer_unusable claude "$bus" r11long
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

# --- backlog 27/28 (round3 red wave) ---

# --- backlog-27: conf_load validation extension (mirrors spec 10 FR-R1 loud style) -----------------
# conf_load additionally validates EXEC_CHAIN/REVIEW/VERIFY_MAP, AFTER the env re-overlay, BEFORE
# export — a bad or empty lane token in any of the three is a loud rc=1, never a silent bad spawn.

@test "backlog-27: conf_load rejects an invalid EXEC_CHAIN lane token" {
  unset EXEC_CHAIN
  echo 'EXEC_CHAIN="bogus:x claude:haiku"' > "$BATS_TEST_TMPDIR/swarm.conf"
  run conf_load "$BATS_TEST_TMPDIR/swarm.conf"
  [ "$status" -eq 1 ]
  [[ "$output" == *"EXEC_CHAIN has invalid lane token 'bogus:x'"* ]]
}

@test "backlog-27: conf_load rejects an empty EXEC_CHAIN" {
  unset EXEC_CHAIN
  echo 'EXEC_CHAIN=""' > "$BATS_TEST_TMPDIR/swarm.conf"
  run conf_load "$BATS_TEST_TMPDIR/swarm.conf"
  [ "$status" -eq 1 ]
  [[ "$output" == *"EXEC_CHAIN must not be empty"* ]]
}

@test "backlog-27: conf_load rejects an invalid REVIEW lane token" {
  unset REVIEW
  echo 'REVIEW="nope:default"' > "$BATS_TEST_TMPDIR/swarm.conf"
  run conf_load "$BATS_TEST_TMPDIR/swarm.conf"
  [ "$status" -eq 1 ]
  [[ "$output" == *"REVIEW has invalid lane token 'nope:default'"* ]]
}

@test "backlog-27: conf_load rejects an invalid VERIFY_MAP lane token (either side of the pair)" {
  unset VERIFY_MAP
  echo 'VERIFY_MAP="claude:codex glm:bogus"' > "$BATS_TEST_TMPDIR/swarm.conf"
  run conf_load "$BATS_TEST_TMPDIR/swarm.conf"
  [ "$status" -eq 1 ]
  [[ "$output" == *"VERIFY_MAP has invalid lane token 'glm:bogus'"* ]]
}

@test "backlog-27: conf_load accepts a fully-valid config spanning all six lanes (guard against over-validation)" {
  unset EXEC_CHAIN REVIEW VERIFY_MAP
  {
    echo 'EXEC_CHAIN="claude:haiku codex:default gemini:pro glm:glm-5.2 grok:grok-4.5 kimi:kimi-k3"'
    echo 'REVIEW="codex:default"'
    echo 'VERIFY_MAP="claude:codex codex:kimi gemini:claude glm:codex grok:codex kimi:codex"'
  } > "$BATS_TEST_TMPDIR/swarm.conf"
  run conf_load "$BATS_TEST_TMPDIR/swarm.conf"
  [ "$status" -eq 0 ]
}

# --- backlog-28-lib: write_verify_spec embeds the card's own diff for write cards ------------------
# If BOTH write-<id>.txt (archived write-target path) AND limits/<id>.stamp exist, the generated
# v-<id>.prompt gets a CARD DIFF section scoped to this card's own commit — never the tree's
# current (possibly concurrently-edited-by-other-cards) state.

@test "backlog-28: write_verify_spec embeds the card's own git diff for a write card (git-repo target)" {
  bus_init "$BUS"
  local repo="$BATS_TEST_TMPDIR/repo-w1"
  mkdir -p "$repo"
  git -C "$repo" init -q
  printf 'line one\n' > "$repo/tracked.txt"
  git -C "$repo" add tracked.txt
  git -C "$repo" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m init

  printf 'the original question' > "$BUS/prompt-w1.txt"
  printf 'branch answer text' > "$BUS/res-w1.txt"
  printf '{"id":"w1","code":0,"lane":"claude"}\n' > "$BUS/done/w1"
  printf '%s' "$repo" > "$BUS/write-w1.txt"
  touch -d "-1 minute" "$BUS/limits/w1.stamp"

  # changes happen AFTER the stamp: modify the tracked file, add one untracked file
  printf 'line one\nline two\n' > "$repo/tracked.txt"
  printf 'new content' > "$repo/untracked.txt"

  write_verify_spec "$BUS" w1
  local prompt; prompt="$(<"$BUS/specs/v-w1.prompt")"
  [[ "$prompt" == *"THIS IS A WRITE CARD. Judge ONLY this card's diff below at its commit — other cards edit this tree concurrently; do not judge the tree's current state."* ]]
  [[ "$prompt" == *"CARD DIFF (target: $repo):"* ]]
  [[ "$prompt" == *"+line two"* ]]
  [[ "$prompt" == *"NEW FILE:"* ]]
  [[ "$prompt" == *"untracked.txt"* ]]
}

@test "backlog-28: write_verify_spec prompt has no write-card section when write-<id>.txt is absent (byte-identical to today's)" {
  bus_init "$BUS"
  printf 'the original question' > "$BUS/prompt-w2.txt"
  printf 'branch answer text' > "$BUS/res-w2.txt"
  printf '{"id":"w2","code":0,"lane":"claude"}\n' > "$BUS/done/w2"

  write_verify_spec "$BUS" w2
  local prompt; prompt="$(<"$BUS/specs/v-w2.prompt")"
  [[ "$prompt" != *"THIS IS A WRITE CARD"* ]]
  [[ "$prompt" != *"CARD DIFF"* ]]
}

@test "backlog-28: write_verify_spec degrades to a changed-file listing (no crash, rc 0) when the target is not a git repo" {
  bus_init "$BUS"
  local target="$BATS_TEST_TMPDIR/nongit-w3"
  mkdir -p "$target"
  printf 'the original question' > "$BUS/prompt-w3.txt"
  printf 'branch answer text' > "$BUS/res-w3.txt"
  printf '{"id":"w3","code":0,"lane":"claude"}\n' > "$BUS/done/w3"
  printf '%s' "$target" > "$BUS/write-w3.txt"
  touch -d "-1 minute" "$BUS/limits/w3.stamp"

  printf 'fresh content' > "$target/changed.txt"

  run write_verify_spec "$BUS" w3
  [ "$status" -eq 0 ]
  [[ "$(<"$BUS/specs/v-w3.prompt")" == *"changed.txt"* ]]
}

# --- spec14 FR-2: _write_card_diff_section manifest scoping (backlog 45) ------------------------
# A helper to keep these fixtures short: a two-file git repo, one committed base, then both files
# modified in the working tree (uncommitted — mirrors the existing backlog-28 fixture style).

_fr2_two_file_repo() {
  local repo="$1" id="$2"
  mkdir -p "$repo"
  git -C "$repo" init -q
  printf 'a original\n' > "$repo/a.ts"
  printf 'b original\n' > "$repo/b.ts"
  git -C "$repo" add a.ts b.ts
  git -C "$repo" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m init
  touch -d "-1 minute" "$BUS/limits/$id.stamp"
  printf 'a original\na changed\n' > "$repo/a.ts"
  printf 'b original\nb changed\n' > "$repo/b.ts"
}

@test "spec14 FR-2: manifest (files-<id>.txt post-finalize archive) scopes the diff to listed entries only" {
  bus_init "$BUS"
  local repo="$BATS_TEST_TMPDIR/repo-m1"
  _fr2_two_file_repo "$repo" m1
  printf 'a.ts\n' > "$BUS/files-m1.txt"

  local out; out="$(_write_card_diff_section "$BUS" m1 "$repo")"
  [[ "$out" == *"+a changed"* ]]
  [[ "$out" != *"+b changed"* ]]
}

@test "spec14 FR-2: falls back to queue/<id>.files when the post-finalize archive is absent" {
  bus_init "$BUS"
  local repo="$BATS_TEST_TMPDIR/repo-m2"
  _fr2_two_file_repo "$repo" m2
  printf 'a.ts\n' > "$BUS/queue/m2.files"

  local out; out="$(_write_card_diff_section "$BUS" m2 "$repo")"
  [[ "$out" == *"+a changed"* ]]
  [[ "$out" != *"+b changed"* ]]
}

@test "spec14 FR-2: the post-finalize archive takes precedence over a stale queue/ sidecar when both exist" {
  bus_init "$BUS"
  local repo="$BATS_TEST_TMPDIR/repo-m3"
  _fr2_two_file_repo "$repo" m3
  printf 'a.ts\n' > "$BUS/files-m3.txt"
  printf 'b.ts\n' > "$BUS/queue/m3.files"   # wrong/stale list -- the archive must win

  local out; out="$(_write_card_diff_section "$BUS" m3 "$repo")"
  [[ "$out" == *"+a changed"* ]]
  [[ "$out" != *"+b changed"* ]]
}

@test "spec14 FR-2: manifest absent -> both changed files show (today's whole-target sweep, byte-identical)" {
  bus_init "$BUS"
  local repo="$BATS_TEST_TMPDIR/repo-m4"
  _fr2_two_file_repo "$repo" m4

  local out; out="$(_write_card_diff_section "$BUS" m4 "$repo")"
  [[ "$out" == *"+a changed"* ]]
  [[ "$out" == *"+b changed"* ]]
}

@test "spec14 FR-2: an absolute or escaping manifest entry is ignored with a loud line, never included" {
  bus_init "$BUS"
  local repo="$BATS_TEST_TMPDIR/repo-m5"
  mkdir -p "$repo"
  git -C "$repo" init -q
  printf 'a original\n' > "$repo/a.ts"
  git -C "$repo" add a.ts
  git -C "$repo" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m init
  touch -d "-1 minute" "$BUS/limits/m5.stamp"
  printf 'a original\na changed\n' > "$repo/a.ts"
  printf 'secret content, never shown' > "$BATS_TEST_TMPDIR/escape-target.txt"
  {
    printf '/etc/passwd\n'
    printf '../escape-target.txt\n'
    printf 'a.ts\n'
  } > "$BUS/files-m5.txt"

  run _write_card_diff_section "$BUS" m5 "$repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"absolute"* ]]
  [[ "$output" == *"escapes"* ]]
  [[ "$output" == *"+a changed"* ]]
  [[ "$output" != *"secret content"* ]]
}

@test "spec14 FR-2 (cross-review fix): an EMPTY files-<id>.txt is authoritative empty evidence — no fallback to the whole-cage sweep" {
  bus_init "$BUS"
  local repo="$BATS_TEST_TMPDIR/repo-m6"
  _fr2_two_file_repo "$repo" m6
  : > "$BUS/files-m6.txt"   # present but empty -- must NOT read as "no manifest"

  local out; out="$(_write_card_diff_section "$BUS" m6 "$repo")"
  [[ "$out" != *"+a changed"* ]]
  [[ "$out" != *"+b changed"* ]]
}

@test "spec14 FR-2 (cross-review fix): a manifest entry that resolves to an existing directory is loud-ignored, never included" {
  bus_init "$BUS"
  local repo="$BATS_TEST_TMPDIR/repo-m7"
  mkdir -p "$repo"
  git -C "$repo" init -q
  printf 'a original\n' > "$repo/a.ts"
  git -C "$repo" add a.ts
  git -C "$repo" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m init
  touch -d "-1 minute" "$BUS/limits/m7.stamp"
  printf 'a original\na changed\n' > "$repo/a.ts"
  mkdir -p "$repo/subdir"
  {
    printf 'subdir\n'
    printf 'a.ts\n'
  } > "$BUS/files-m7.txt"

  run _write_card_diff_section "$BUS" m7 "$repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"directory"* ]]
  [[ "$output" == *"+a changed"* ]]
}

@test "verify-wave: _write_card_diff_section caps the whole section INCLUDING the truncation marker at 50000 chars" {
  bus_init "$BUS"
  local target="$BATS_TEST_TMPDIR/captarget"
  mkdir -p "$target"
  touch -d "-1 minute" "$BUS/limits/cap1.stamp"
  # non-git target -> NEW FILE arm embeds contents verbatim; 60000 chars busts the cap
  head -c 60000 /dev/zero | tr '\0' x > "$target/big.txt"
  local out; out="$(_write_card_diff_section "$BUS" cap1 "$target")"
  [ "${#out}" -eq 50000 ]
  [[ "$out" == *"[diff truncated]" ]]
}

# --- spec 11 succession (round3 red wave) ---

@test "spec11: conf_load defaults PLAN_CHAIN/ORCH_CHAIN/ORCH_TAKEOVER_MIN on empty conf" {
  unset PLAN_CHAIN ORCH_CHAIN ORCH_TAKEOVER_MIN
  : > "$BATS_TEST_TMPDIR/swarm.conf"
  conf_load "$BATS_TEST_TMPDIR/swarm.conf"
  [ "$PLAN_CHAIN" = "fable codex kimi" ]
  [ "$ORCH_CHAIN" = "fable kimi" ]
  [ "$ORCH_TAKEOVER_MIN" = "20" ]
}

@test "spec11: conf_load rejects PLAN_CHAIN not starting with fable" {
  unset PLAN_CHAIN ORCH_CHAIN ORCH_TAKEOVER_MIN
  echo 'PLAN_CHAIN="codex kimi"' > "$BATS_TEST_TMPDIR/swarm.conf"
  run conf_load "$BATS_TEST_TMPDIR/swarm.conf"
  [ "$status" -eq 1 ]
  [[ "$output" == *"conf_load: PLAN_CHAIN must start with 'fable'"* ]]
}

@test "spec11: conf_load rejects ORCH_CHAIN with invalid lane token" {
  unset PLAN_CHAIN ORCH_CHAIN ORCH_TAKEOVER_MIN
  echo 'ORCH_CHAIN="fable bogus"' > "$BATS_TEST_TMPDIR/swarm.conf"
  run conf_load "$BATS_TEST_TMPDIR/swarm.conf"
  [ "$status" -eq 1 ]
  [[ "$output" == *"conf_load: ORCH_CHAIN has invalid lane token 'bogus'"* ]]
}

@test "spec11: conf_load rejects ORCH_TAKEOVER_MIN=0 as non-positive" {
  unset PLAN_CHAIN ORCH_CHAIN ORCH_TAKEOVER_MIN
  echo 'ORCH_TAKEOVER_MIN="0"' > "$BATS_TEST_TMPDIR/swarm.conf"
  run conf_load "$BATS_TEST_TMPDIR/swarm.conf"
  [ "$status" -eq 1 ]
  [[ "$output" == *"conf_load: ORCH_TAKEOVER_MIN must be a positive integer"* ]]
}

@test "spec11: conf_load rejects ORCH_TAKEOVER_MIN=abc as non-integer" {
  unset PLAN_CHAIN ORCH_CHAIN ORCH_TAKEOVER_MIN
  echo 'ORCH_TAKEOVER_MIN="abc"' > "$BATS_TEST_TMPDIR/swarm.conf"
  run conf_load "$BATS_TEST_TMPDIR/swarm.conf"
  [ "$status" -eq 1 ]
  [[ "$output" == *"conf_load: ORCH_TAKEOVER_MIN must be a positive integer"* ]]
}

@test "spec11: conf_load accepts valid PLAN_CHAIN/ORCH_CHAIN/ORCH_TAKEOVER_MIN" {
  unset PLAN_CHAIN ORCH_CHAIN ORCH_TAKEOVER_MIN
  {
    echo 'PLAN_CHAIN="fable codex kimi"'
    echo 'ORCH_CHAIN="fable kimi"'
    echo 'ORCH_TAKEOVER_MIN=5'
  } > "$BATS_TEST_TMPDIR/swarm.conf"
  run conf_load "$BATS_TEST_TMPDIR/swarm.conf"
  [ "$status" -eq 0 ]
}

@test "spec11: orch_seat prints first field of orch-seat file" {
  bus_init "$BUS"
  printf 'kimi 1753000000' > "$BUS/orch-seat"
  run orch_seat "$BUS"
  [ "$status" -eq 0 ]
  [ "$output" = "kimi" ]
}

@test "spec11: orch_seat prints fable when orch-seat file is absent" {
  bus_init "$BUS"
  run orch_seat "$BUS"
  [ "$status" -eq 0 ]
  [ "$output" = "fable" ]
}

@test "spec11: orch_degraded rc0 when seat is non-fable" {
  bus_init "$BUS"
  printf 'kimi 1753000000' > "$BUS/orch-seat"
  run orch_degraded "$BUS"
  [ "$status" -eq 0 ]
}

@test "spec11: orch_degraded rc1 when orch-seat file is absent" {
  bus_init "$BUS"
  run orch_degraded "$BUS"
  [ "$status" -eq 1 ]
}

@test "spec11: orch_degraded rc1 when seat is fable" {
  bus_init "$BUS"
  printf 'fable 1753000000' > "$BUS/orch-seat"
  run orch_degraded "$BUS"
  [ "$status" -eq 1 ]
}

@test "spec11: _judge_ok with busdir disqualifies acting orch-seat kimi as judge" {
  bus_init "$BUS"
  unset PLAN ORCHESTRATOR
  printf 'kimi 1753000000' > "$BUS/orch-seat"
  run _judge_ok kimi glm "$BUS"
  [ "$status" -eq 1 ]
}

@test "spec11: _judge_ok with busdir accepts non-seat candidate when orch-seat is kimi" {
  bus_init "$BUS"
  unset PLAN ORCHESTRATOR
  printf 'kimi 1753000000' > "$BUS/orch-seat"
  run _judge_ok codex glm "$BUS"
  [ "$status" -eq 0 ]
}

@test "spec11: _judge_ok with busdir does not disqualify kimi when orch-seat is absent (regression)" {
  bus_init "$BUS"
  unset PLAN ORCHESTRATOR
  # orch-seat ABSENT — 3-arg form must match pre-spec-11 2-arg behavior
  run _judge_ok kimi glm "$BUS"
  [ "$status" -eq 0 ]
}

@test "spec11: _judge_ok 2-arg form still works (no busdir)" {
  unset PLAN ORCHESTRATOR
  run _judge_ok codex glm
  [ "$status" -eq 0 ]
}

# --- spec 11 FR-S3: review_chain_for against the LIVE orch-seat (card-level chain shape) ----------
# The fbreason:"role-collision" write and the loud park are swarm-loop.sh's seeding block / the
# pool's chain-walk — asserted in tests/swarm-loop.bats, not here. These cover the lib half: the
# chain review_chain_for hands the card when the live seat collides.

@test "spec11 FR-S3: review_chain_for with orch-seat kimi drops kimi — chain head is codex (live role-collision)" {
  bus_init "$BUS"
  CLASS_REVIEW="codex kimi"
  REVIEW_CHAIN=""
  unset PLAN ORCHESTRATOR
  printf 'kimi 1753000000' > "$BUS/orch-seat"
  local chain
  chain="$(review_chain_for glm "$BUS")"
  [ "${chain%% *}" = "codex:default" ]
  [[ "$chain" != *kimi* ]]
}

@test "spec11 FR-S3: review_chain_for empty when codex (PLAN) and kimi (orch-seat) are both seated — no emergency-judge promotion" {
  bus_init "$BUS"
  CLASS_REVIEW="codex kimi"
  REVIEW_CHAIN=""
  export PLAN=codex
  unset ORCHESTRATOR
  printf 'kimi 1753000000' > "$BUS/orch-seat"
  # author=glm so both drops are attributable to the seats, not author-collision
  run review_chain_for glm "$BUS"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "spec11: speed_row emits degraded:true when orch-seat is non-fable" {
  bus_init "$BUS"
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-s11-deg.jsonl"
  printf 'kimi 1753000000' > "$BUS/orch-seat"
  {
    echo '{"type":"assistant","message":{"model":"claude-sonnet-5"}}'
    echo '{"type":"result","usage":{"input_tokens":1,"output_tokens":1}}'
  } > "$BUS/run-s11d1.jsonl"

  speed_row "$BUS" s11d1 "claude:sonnet" done 0 0

  [ "$(jq -r '.degraded' "$SPEEDWARS_FILE")" = "true" ]
}

@test "spec11: speed_row omits degraded key entirely when orch-seat is absent" {
  bus_init "$BUS"
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-s11-nodeg.jsonl"
  # orch-seat ABSENT
  {
    echo '{"type":"assistant","message":{"model":"claude-sonnet-5"}}'
    echo '{"type":"result","usage":{"input_tokens":1,"output_tokens":1}}'
  } > "$BUS/run-s11d2.jsonl"

  speed_row "$BUS" s11d2 "claude:sonnet" done 0 0

  [ "$(jq 'has("degraded")' "$SPEEDWARS_FILE")" = "false" ]
}

# --- spec 13 FR-3: broken_flag / lane_broken / lane_blocked ------------------------------------

@test "broken_flag / lane_broken: active within TTL, expired once aged past it (mirrors limit_flag/limit_active)" {
  bus_init "$BUS"
  broken_flag "$BUS" grok 100
  run lane_broken "$BUS" grok
  [ "$status" -eq 0 ]

  touch -d "-200 seconds" "$BUS/limits/grok.broken"
  run lane_broken "$BUS" grok
  [ "$status" -eq 1 ]
}

@test "broken_flag: default TTL is 1800s (30m), shorter than limit_flag's 5h default" {
  bus_init "$BUS"
  broken_flag "$BUS" grok
  [ "$(_marker_ttl "$BUS/limits/grok.broken" 0)" = "1800" ]
}

@test "lane_broken: no flag file means not broken" {
  bus_init "$BUS"
  run lane_broken "$BUS" grok
  [ "$status" -eq 1 ]
}

@test "lane_blocked: an active .broken flag blocks the lane, same as .limited/.dead" {
  bus_init "$BUS"
  run lane_blocked "$BUS" grok
  [ "$status" -eq 1 ]

  broken_flag "$BUS" grok 100
  run lane_blocked "$BUS" grok
  [ "$status" -eq 0 ]
}

# --- spec 13 FR-4: _payg_denied ------------------------------------------------------------------

@test "_payg_denied: deny + budget 0 + fallback hop onto kimi -> denied" {
  export PAYG_FALLBACK=deny BUDGET_USD=0
  run _payg_denied kimi claude
  [ "$status" -eq 0 ]
}

@test "_payg_denied: warn (default) never denies, even under budget 0 fallback" {
  export PAYG_FALLBACK=warn BUDGET_USD=0
  run _payg_denied kimi claude
  [ "$status" -eq 1 ]
}

@test "_payg_denied: allow never denies" {
  export PAYG_FALLBACK=allow BUDGET_USD=0
  run _payg_denied kimi claude
  [ "$status" -eq 1 ]
}

@test "_payg_denied: deny does not apply when kimi is the ORIGINAL seed lane (not a fallback hop)" {
  export PAYG_FALLBACK=deny BUDGET_USD=0
  run _payg_denied kimi kimi
  [ "$status" -eq 1 ]
}

@test "_payg_denied: deny does not apply once BUDGET_USD > 0 (existing kimi budget gate governs instead)" {
  export PAYG_FALLBACK=deny BUDGET_USD=5
  run _payg_denied kimi claude
  [ "$status" -eq 1 ]
}

@test "_payg_denied: never applies to a non-kimi lane" {
  export PAYG_FALLBACK=deny BUDGET_USD=0
  run _payg_denied glm claude
  [ "$status" -eq 1 ]
}

# --- spec 13 FR-4: conf_load validates PAYG_FALLBACK -----------------------------------------

@test "conf_load: PAYG_FALLBACK default is warn" {
  unset PAYG_FALLBACK
  conf_load "$BATS_TEST_TMPDIR/nonexistent.conf"
  [ "$PAYG_FALLBACK" = "warn" ]
}

@test "conf_load: PAYG_FALLBACK accepts allow/deny from file" {
  echo 'PAYG_FALLBACK=deny' > "$BATS_TEST_TMPDIR/swarm.conf"
  conf_load "$BATS_TEST_TMPDIR/swarm.conf"
  [ "$PAYG_FALLBACK" = "deny" ]
}

@test "conf_load: PAYG_FALLBACK rejects an unknown value loudly" {
  echo 'PAYG_FALLBACK=maybe' > "$BATS_TEST_TMPDIR/swarm.conf"
  run conf_load "$BATS_TEST_TMPDIR/swarm.conf"
  [ "$status" -eq 1 ]
  [[ "$output" == *"PAYG_FALLBACK"* ]]
}

# --- spec 13 FR-1: env_master_preflight ---------------------------------------------------------

@test "env_master_preflight: claude/codex-only EXEC_CHAIN is unaffected by a missing env-master file" {
  unset EXEC_CHAIN REVIEW REVIEW_CHAIN VERIFY_MAP PLAN_CHAIN ORCH_CHAIN
  conf_load "$BATS_TEST_TMPDIR/nonexistent.conf"
  bus_init "$BUS"
  export ENV_MASTER_FILE="$BATS_TEST_TMPDIR/no-such-envmaster"
  run env_master_preflight "$BUS"
  [ "$status" -eq 0 ]
}

@test "env_master_preflight: an EXEC_CHAIN lane needing an env key aborts loudly when the file is unreadable" {
  export EXEC_CHAIN="glm:glm-5.2 claude:opus"
  unset REVIEW REVIEW_CHAIN VERIFY_MAP PLAN_CHAIN ORCH_CHAIN
  conf_load "$BATS_TEST_TMPDIR/nonexistent.conf"
  bus_init "$BUS"
  export ENV_MASTER_FILE="$BATS_TEST_TMPDIR/no-such-envmaster"
  run env_master_preflight "$BUS"
  [ "$status" -eq 1 ]
  [[ "$output" == *"$BATS_TEST_TMPDIR/no-such-envmaster"* ]]
  [[ "$output" == *"export ENV_MASTER_FILE="* ]]
}

@test "env_master_preflight: a readable env-master file passes regardless of which keys it holds (reachability only)" {
  export EXEC_CHAIN="kimi:kimi-k3 claude:opus"
  unset REVIEW REVIEW_CHAIN VERIFY_MAP PLAN_CHAIN ORCH_CHAIN
  conf_load "$BATS_TEST_TMPDIR/nonexistent.conf"
  bus_init "$BUS"
  : > "$BATS_TEST_TMPDIR/envmaster"
  export ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster"
  run env_master_preflight "$BUS"
  [ "$status" -eq 0 ]
}

@test "env_master_preflight: VERIFY_MAP/PLAN_CHAIN/ORCH_CHAIN's baked-in kimi default never trips the abort on their own (would false-positive on every run otherwise)" {
  # All three default to naming an env-key lane (VERIFY_MAP's verifier side, PLAN_CHAIN/ORCH_CHAIN's
  # succession fallback) regardless of EXEC_CHAIN — deliberately excluded from the computed set
  # (see env_master_preflight's own header comment) so a plain claude/codex EXEC_CHAIN still passes.
  export EXEC_CHAIN="claude:opus codex:default"
  unset REVIEW REVIEW_CHAIN VERIFY_MAP PLAN_CHAIN ORCH_CHAIN
  conf_load "$BATS_TEST_TMPDIR/nonexistent.conf"
  bus_init "$BUS"
  export ENV_MASTER_FILE="$BATS_TEST_TMPDIR/no-such-envmaster"
  run env_master_preflight "$BUS"
  [ "$status" -eq 0 ]
}

@test "env_master_preflight: an env-key lane reachable only via a queue/*.lane pin still triggers the abort" {
  export EXEC_CHAIN="claude:opus codex:default"
  unset REVIEW REVIEW_CHAIN VERIFY_MAP PLAN_CHAIN ORCH_CHAIN
  conf_load "$BATS_TEST_TMPDIR/nonexistent.conf"
  bus_init "$BUS"
  echo "gemini:gemini-3-flash" > "$BUS/queue/pin1.lane"
  export ENV_MASTER_FILE="$BATS_TEST_TMPDIR/no-such-envmaster"
  run env_master_preflight "$BUS"
  [ "$status" -eq 1 ]
}

# --- round-4 review fixes ------------------------------------------------------------------------

@test "round4: GROK_EFFORT exported EMPTY omits --effort entirely (the documented CLI-default restore)" {
  bus_init "$BUS"
  _claim_prompt "grok:default" ge1 "x"
  GROK_EFFORT="" lane_cmd "grok:default" ge1 "$BUS"
  [[ " ${LANE_ARGV[*]} " != *" --effort "* ]]
}

@test "round4: GROK_EFFORT unset still defaults to --effort medium" {
  bus_init "$BUS"
  _claim_prompt "grok:default" ge2 "x"
  ( unset GROK_EFFORT; lane_cmd "grok:default" ge2 "$BUS"; [[ " ${LANE_ARGV[*]} " == *" --effort medium "* ]] )
}

@test "round4: conf_load does NOT rewrite an explicitly-empty GROK_EFFORT back to medium" {
  export GROK_EFFORT=""
  conf_load "$BATS_TEST_TMPDIR/no-such.conf"
  [ "$GROK_EFFORT" = "" ]
}

@test "round4: run_summary counts a timeout-salvaged branch toward done_n (it has a done/ marker)" {
  bus_init "$BUS"
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/rs-salv.jsonl"
  export SPEEDWARS_RUN=rsalv
  cat > "$SPEEDWARS_FILE" <<'JSONL'
{"ts":"2026-07-25T10:00:00Z","run":"rsalv","id":"a","outcome":"done","served_lane":"claude"}
{"ts":"2026-07-25T10:00:01Z","run":"rsalv","id":"b","outcome":"timeout-salvaged","served_lane":"claude"}
JSONL
  run_summary "$BUS" full
  [ "$(jq -r 'select(.type=="run-summary") | .done_n' "$SPEEDWARS_FILE")" = "2" ]
}

@test "round4: run_summary survives a torn ledger line instead of silently no-op'ing forever" {
  bus_init "$BUS"
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/rs-torn.jsonl"
  export SPEEDWARS_RUN=rtorn
  cat > "$SPEEDWARS_FILE" <<'JSONL'
{"ts":"2026-07-25T10:00:00Z","run":"rtorn","id":"a","outcome":"done","served_lane":"claude"}
this is a truncated line {"ts":
{"ts":"2026-07-25T10:00:01Z","run":"rtorn","id":"b","outcome":"parked","served_lane":"claude"}
JSONL
  run_summary "$BUS" full
  local sum
  sum="$(jq -R -c 'fromjson? // empty' "$SPEEDWARS_FILE" | jq -c 'select(.type=="run-summary")')"
  [ "$(jq -r '.done_n' <<<"$sum")" = "1" ]
  [ "$(jq -r '.parked_n' <<<"$sum")" = "1" ]
}

@test "round4: feedback_stubs matches ledger rows on the SAME run label speed_row stamps" {
  local root="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$root/feedback" "$root/docs/ops"
  local bus="$root/.bus"
  bus_init "$bus"
  export FEEDBACK_DIR="$root/feedback"
  export SPEEDWARS_FILE="$root/docs/ops/speedwars.jsonl"
  unset SPEEDWARS_RUN
  # run label = basename of the busdir's PARENT ("repo"), exactly as speed_row would stamp it
  printf '{"ts":"2026-07-25T10:00:00Z","run":"repo","id":"a","outcome":"timeout","served_lane":"claude"}\n' \
    > "$SPEEDWARS_FILE"
  feedback_stubs "$bus"
  local stub="$root/feedback/$(date -u +%F)-repo-repo-auto-timeout.md"
  [ -f "$stub" ]
  # repo-relative evidence paths + repo NAME as source — never an absolute operator path
  grep -q '^source: repo$' "$stub"
  grep -q 'docs/ops/speedwars.jsonl' "$stub"
  ! grep -q "$root" "$stub"
}

@test "round4: write_verify_spec verifies a salvaged write card that has NO handoff file (diff-only)" {
  bus_init "$BUS"
  local target="$BATS_TEST_TMPDIR/wvtarget"
  mkdir -p "$target"
  printf 'hello\n' > "$target/made.txt"
  printf '{"id":"w1","code":137,"lane":"claude","salvaged":true}\n' > "$BUS/done/w1"
  printf 'do the write\n' > "$BUS/prompt-w1.txt"
  printf '%s' "$target" > "$BUS/write-w1.txt"
  touch -d '1 minute ago' "$BUS/limits/w1.stamp"

  write_verify_spec "$BUS" w1
  [ -f "$BUS/specs/v-w1.prompt" ]
  [ -f "$BUS/specs/v-w1.lane" ]
  grep -q 'no handoff file' "$BUS/specs/v-w1.prompt"
  grep -q 'KILLED by the wall-clock watchdog' "$BUS/specs/v-w1.prompt"
}

@test "round4: write_verify_spec still no-ops for a non-write card with no answer file" {
  bus_init "$BUS"
  printf '{"id":"w2","code":0,"lane":"claude"}\n' > "$BUS/done/w2"
  printf 'q\n' > "$BUS/prompt-w2.txt"
  run write_verify_spec "$BUS" w2
  [ "$status" -ne 0 ]
  [ ! -e "$BUS/specs/v-w2.prompt" ]
}

@test "round4: env_master_preflight verify mode folds in the verifier actually resolved for a done branch" {
  bus_init "$BUS"
  EXEC_CHAIN="claude:opus"; REVIEW="codex:default"; REVIEW_CHAIN=""
  VERIFY_MAP="claude:kimi"
  export ENV_MASTER_FILE="$BATS_TEST_TMPDIR/definitely-missing"
  printf '{"id":"d1","code":0,"lane":"claude"}\n' > "$BUS/done/d1"

  # full mode: claude/codex only -> proceeds
  run env_master_preflight "$BUS"
  [ "$status" -eq 0 ]
  # verify mode: the verifier for a claude branch is kimi (env-key lane) -> refuses up front
  run env_master_preflight "$BUS" verify
  [ "$status" -ne 0 ]
  [[ "$output" == *"env-master file is unreadable"* ]]
}

@test "round4: _ledger_append_row keeps every row under concurrent writers (flock + per-writer tmp)" {
  local f="$BATS_TEST_TMPDIR/ledger.md"
  printf '| When | What | Lane | Billed |\n|------|------|------|--------|\n' > "$f"
  local i
  for i in 1 2 3 4 5 6 7 8; do
    ( _ledger_append_row "$f" "2026-07-25" "row$i" "claude" "n/a" ) &
  done
  wait
  [ "$(grep -c '^| 2026-07-25 |' "$f")" -eq 8 ]
  [ -z "$(find "$BATS_TEST_TMPDIR" -name 'ledger.md.tmp*' 2>/dev/null)" ]
}

@test "round4: bus_init never clobbers an existing notes-lessons.md" {
  bus_init "$BUS"
  printf 'operator notes\n' > "$BUS/notes-lessons.md"
  bus_init "$BUS"
  grep -q 'operator notes' "$BUS/notes-lessons.md"
}

# --- spec 14 FR-7: reason lines on every marker (AC-9) ------------------------------------------

# The FIXED token set (spec 14 FR-7 "Reason tokens — reuse the taxonomy, never mint a second one"):
# spec 12 FR-1's failure classes + FR-1/FR-5's two new ones + the three marker-only tokens. Inlined
# here on purpose — a newly minted token must fail this file, not quietly join the vocabulary.
FR7_TOKENS="auth-death api-error server-error rate-limit timeout-watchdog spawn-fail false-done no-answer lane-down parked-env cage-denied write-target-missing chain-exhausted pinned-lane-blocked session-limit"
FR7_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[^ ]* \| [a-z-]+ \| retryable=[01] \| ttl=[0-9]+ \| .*$'

# _fr7_token <file> — echo the reason token of a marker line.
_fr7_token() { cut -d'|' -f2 <"$1" | tr -d ' '; }

@test "spec14 FR-7: _marker_line emits exactly one line in the fixed format" {
  run _marker_line rate-limit 1 300 "lane glm cooling"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" =~ $FR7_RE ]]
  [[ "$output" == *"| rate-limit | retryable=1 | ttl=300 | lane glm cooling" ]]
}

@test "spec14 FR-7: _marker_line flattens multi-line text — a marker is always one line" {
  run _marker_line lane-down 0 1800 "$(printf 'first\nsecond')"
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" =~ $FR7_RE ]]
}

@test "spec14 FR-7: limit_flag defaults to the rate-limit token and carries its own TTL" {
  bus_init "$BUS"
  limit_flag "$BUS" glm 300
  [ "$(wc -l <"$BUS/limits/glm.limited")" -eq 1 ]
  grep -Eq "$FR7_RE" "$BUS/limits/glm.limited"
  [ "$(_fr7_token "$BUS/limits/glm.limited")" = "rate-limit" ]
  grep -q 'retryable=1 | ttl=300' "$BUS/limits/glm.limited"
}

@test "spec14 FR-7: limit_flag takes an explicit reason token and free text" {
  bus_init "$BUS"
  limit_flag "$BUS" kimi 600 session-limit "kimi: session limit on card k1"
  [ "$(_fr7_token "$BUS/limits/kimi.limited")" = "session-limit" ]
  grep -q 'kimi: session limit on card k1' "$BUS/limits/kimi.limited"
}

@test "spec14 FR-7: dead_flag writes an auth-death reason line with ttl=0 retryable=0" {
  bus_init "$BUS"
  dead_flag "$BUS" claude
  grep -Eq "$FR7_RE" "$BUS/limits/claude.dead"
  [ "$(_fr7_token "$BUS/limits/claude.dead")" = "auth-death" ]
  grep -q 'retryable=0 | ttl=0' "$BUS/limits/claude.dead"
}

@test "spec14 FR-7: lane_dead stays existence-only — it never parses the new reason line" {
  bus_init "$BUS"
  dead_flag "$BUS" claude
  run lane_dead "$BUS" claude
  [ "$status" -eq 0 ]
  # backdated far past any TTL a parser might invent: existence alone is still the signal
  touch -d "-30 days" "$BUS/limits/claude.dead"
  run lane_dead "$BUS" claude
  [ "$status" -eq 0 ]
}

@test "spec14 FR-7: broken_flag defaults to the lane-down token" {
  bus_init "$BUS"
  broken_flag "$BUS" grok
  [ "$(_fr7_token "$BUS/limits/grok.broken")" = "lane-down" ]
  grep -q 'retryable=0 | ttl=1800' "$BUS/limits/grok.broken"
}

@test "spec14 FR-7: every default marker token is a member of the fixed set" {
  bus_init "$BUS"
  limit_flag "$BUS" glm 300
  dead_flag "$BUS" claude
  broken_flag "$BUS" grok
  local f tok
  for f in "$BUS"/limits/glm.limited "$BUS"/limits/claude.dead "$BUS"/limits/grok.broken; do
    tok="$(_fr7_token "$f")"
    [[ " $FR7_TOKENS " == *" $tok "* ]]
  done
}

@test "spec14 FR-7: limit_active reads the ttl= field of a new-format marker" {
  bus_init "$BUS"
  limit_flag "$BUS" glm 100
  run limit_active "$BUS" glm
  [ "$status" -eq 0 ]
  touch -d "-200 seconds" "$BUS/limits/glm.limited"
  run limit_active "$BUS" glm
  [ "$status" -eq 1 ]
}

@test "spec14 FR-7: lane_broken reads the ttl= field of a new-format marker" {
  bus_init "$BUS"
  broken_flag "$BUS" grok 100
  run lane_broken "$BUS" grok
  [ "$status" -eq 0 ]
  touch -d "-200 seconds" "$BUS/limits/grok.broken"
  run lane_broken "$BUS" grok
  [ "$status" -eq 1 ]
}

@test "spec14 FR-7: a LEGACY bare-digits .limited still parses (in-flight bus from the old build)" {
  bus_init "$BUS"
  printf '100' > "$BUS/limits/glm.limited"
  run limit_active "$BUS" glm
  [ "$status" -eq 0 ]
  touch -d "-200 seconds" "$BUS/limits/glm.limited"
  run limit_active "$BUS" glm
  [ "$status" -eq 1 ]
}

@test "spec14 FR-7: a LEGACY bare-digits .broken still parses" {
  bus_init "$BUS"
  printf '100' > "$BUS/limits/grok.broken"
  run lane_broken "$BUS" grok
  [ "$status" -eq 0 ]
  touch -d "-200 seconds" "$BUS/limits/grok.broken"
  run lane_broken "$BUS" grok
  [ "$status" -eq 1 ]
}

@test "spec14 FR-7: an unparseable marker falls back to the reader's own baked default" {
  bus_init "$BUS"
  printf 'garbage with no ttl field\n' > "$BUS/limits/glm.limited"
  printf 'garbage with no ttl field\n' > "$BUS/limits/grok.broken"
  run limit_active "$BUS" glm        # baked default 18000 — fresh mtime, still active
  [ "$status" -eq 0 ]
  touch -d "-19000 seconds" "$BUS/limits/glm.limited"
  run limit_active "$BUS" glm
  [ "$status" -eq 1 ]
  touch -d "-2000 seconds" "$BUS/limits/grok.broken"   # baked default 1800
  run lane_broken "$BUS" grok
  [ "$status" -eq 1 ]
}

# --- spec 14 FR-4: session-limit envelope visibility (AC-4, fixtures per AC-6) -------------------

# AC-6 fixture, verbatim from .bus-cockpit057b/run-a-asm.jsonl — inlined as a heredoc, never read
# from the (gitignored) bus tree. A claude-binary session limit arrives as an ordinary result
# envelope: no error/turn.failed event anywhere in the run log, so limit_error's extraction misses
# it entirely and the lane was never flagged.
_fr4_fixture() {  # _fr4_fixture <path> [replacement-result-text]
  local out="$1" text="${2:-}"
  if [[ -z "$text" ]]; then
    cat > "$out" <<'JSON'
{"type":"result","subtype":"success","is_error":true,"result":"You've hit your session limit · resets 2:50am (Europe/Prague)","modelUsage":{}}
JSON
  else
    jq -c -n --arg r "$text" \
      '{type:"result",subtype:"success",is_error:true,result:$r,modelUsage:{}}' > "$out"
  fi
}

@test "spec14 FR-4: _rate_limit_signature matches the session-limit text the claude arm's old pattern missed" {
  run _rate_limit_signature "You've hit your session limit · resets 2:50am (Europe/Prague)"
  [ "$status" -eq 0 ]
  run _rate_limit_signature "usage limit reached"
  [ "$status" -eq 0 ]
  run _rate_limit_signature "HTTP 429 too many requests"
  [ "$status" -eq 0 ]
  run _rate_limit_signature "the deploy has no limit on session length"
  [ "$status" -eq 1 ]
}

@test "spec14 FR-4: session-limit envelope flags the lane for claude, glm and kimi" {
  bus_init "$BUS"
  local lane
  for lane in claude glm kimi; do
    _fr4_fixture "$BUS/run-sl-$lane.jsonl"
    run limit_error "$lane" "$BUS" "sl-$lane"
    [ "$status" -eq 1 ]
    [ -f "$BUS/limits/$lane.limited" ]
    [ -s "$BUS/limits/$lane.limited.evidence" ]
  done
}

@test "spec14 FR-4: the marker's TTL comes from the reset clause and is bounded (0 < ttl <= 86400)" {
  bus_init "$BUS"
  _fr4_fixture "$BUS/run-sl1.jsonl"
  run limit_error claude "$BUS" sl1
  [ "$status" -eq 1 ]
  local ttl; ttl="$(_marker_ttl "$BUS/limits/claude.limited" 0)"
  [ "$ttl" -gt 0 ]
  [ "$ttl" -le 86400 ]
  [ "$(_fr7_token "$BUS/limits/claude.limited")" = "session-limit" ]
}

@test "spec14 FR-4: a session limit is a SINGLE strike — limits/<lane>.strikes is never created" {
  bus_init "$BUS"
  _fr4_fixture "$BUS/run-sl2.jsonl"
  run limit_error claude "$BUS" sl2
  [ "$status" -eq 1 ]
  [ ! -e "$BUS/limits/claude.strikes" ]
}

@test "spec14 FR-4: the same envelope with the reset clause stripped falls back to TTL 18000" {
  bus_init "$BUS"
  _fr4_fixture "$BUS/run-sl3.jsonl" "You've hit your session limit"
  run limit_error kimi "$BUS" sl3
  [ "$status" -eq 1 ]
  [ "$(_marker_ttl "$BUS/limits/kimi.limited" 0)" = "18000" ]
}

@test "spec14 FR-4: an unrelated is_error result with no rate-limit signature is still rc 0" {
  bus_init "$BUS"
  _fr4_fixture "$BUS/run-sl4.jsonl" "Tool execution failed: file not found"
  run limit_error claude "$BUS" sl4
  [ "$status" -eq 0 ]
  [ ! -e "$BUS/limits/claude.limited" ]
  [ ! -e "$BUS/limits/claude.dead" ]
}

@test "spec14 FR-4: a rate-limit signature WITHOUT is_error is not a session limit (rc 0)" {
  bus_init "$BUS"
  jq -c -n '{type:"result",subtype:"success",is_error:false,result:"I could not find any rate limit in the config"}' \
    > "$BUS/run-sl5.jsonl"
  run limit_error glm "$BUS" sl5
  [ "$status" -eq 0 ]
  [ ! -e "$BUS/limits/glm.limited" ]
}

@test "spec14 FR-4/FR-7: a canary in res-<id>.txt reaches no marker" {
  bus_init "$BUS"
  _fr4_fixture "$BUS/run-sl6.jsonl"
  printf 'CANARY-e8f1a2-do-not-leak\n' > "$BUS/res-sl6.txt"
  run limit_error claude "$BUS" sl6
  [ "$status" -eq 1 ]
  ! grep -rq 'CANARY-e8f1a2' "$BUS/limits/claude.limited"
}

# --- spec 14 FR-6: sibling-liveness guard on lane-level flags (AC-8) -----------------------------

# _fr6_sibling <id> <worker> <log-age-min> — plant a claimed card plus its run log at a given age.
_fr6_sibling() {
  local id="$1" worker="$2" age="$3"
  : > "$BUS/claimed/$id.$worker"
  : > "$BUS/run-$id.jsonl"
  touch -d "-$age minutes" "$BUS/run-$id.jsonl"
}

@test "spec14 FR-6: _claim_meta splits a dotted id from its lane:model suffix" {
  bus_init "$BUS"
  run _claim_meta "$BUS" "$BUS/claimed/s4r.api.glm:glm-5.2"
  [ "$status" -eq 0 ]           # no freshness arg = pure parse, always rc 0
  [ "$output" = "s4r.api glm" ]
}

@test "spec14 FR-6: _claim_meta rc 0 only while the run log is fresher than the threshold" {
  bus_init "$BUS"
  _fr6_sibling live1 "glm:glm-5.2" 1
  run _claim_meta "$BUS" "$BUS/claimed/live1.glm:glm-5.2" 15
  [ "$status" -eq 0 ]
  [ "$output" = "live1 glm" ]
  touch -d "-20 minutes" "$BUS/run-live1.jsonl"
  run _claim_meta "$BUS" "$BUS/claimed/live1.glm:glm-5.2" 15
  [ "$status" -eq 1 ]
  [ "$output" = "live1 glm" ]   # the parse still prints; only the freshness verdict flips
}

@test "spec14 FR-6: _claim_meta rc 1 when the card has no run log at all (no evidence of life)" {
  bus_init "$BUS"
  : > "$BUS/claimed/nolog.glm:glm-5.2"
  run _claim_meta "$BUS" "$BUS/claimed/nolog.glm:glm-5.2" 15
  [ "$status" -eq 1 ]
}

@test "spec14 FR-6: lane_has_live_worker rc 0 — a sibling on the lane is streaming inside LEASE_MIN" {
  bus_init "$BUS"; LEASE_MIN=15
  _fr6_sibling sib1 "glm:glm-5.2" 1
  run lane_has_live_worker "$BUS" glm dying1
  [ "$status" -eq 0 ]
}

@test "spec14 FR-6: lane_has_live_worker rc 1 — the sibling's run log is aged past LEASE_MIN" {
  bus_init "$BUS"; LEASE_MIN=15
  _fr6_sibling sib2 "glm:glm-5.2" 30
  run lane_has_live_worker "$BUS" glm dying1
  [ "$status" -eq 1 ]
}

@test "spec14 FR-6: lane_has_live_worker rc 1 — no other claim on the lane at all" {
  bus_init "$BUS"; LEASE_MIN=15
  run lane_has_live_worker "$BUS" glm dying1
  [ "$status" -eq 1 ]
}

@test "spec14 FR-6: lane_has_live_worker keys on the claim's lane token — glm/kimi/claude never vouch for each other" {
  bus_init "$BUS"; LEASE_MIN=15
  _fr6_sibling sibg "glm:glm-5.2" 1
  run lane_has_live_worker "$BUS" kimi dying1
  [ "$status" -eq 1 ]
  run lane_has_live_worker "$BUS" claude dying1
  [ "$status" -eq 1 ]
  run lane_has_live_worker "$BUS" glm dying1
  [ "$status" -eq 0 ]
}

@test "spec14 FR-6: lane_has_live_worker rc 1 — only the dying card's own claim is present" {
  bus_init "$BUS"; LEASE_MIN=15
  _fr6_sibling dying1 "glm:glm-5.2" 1
  run lane_has_live_worker "$BUS" glm dying1
  [ "$status" -eq 1 ]
}

@test "spec14 FR-6: auth-death with a live sibling downgrades to a short .broken, never .dead/.limited" {
  bus_init "$BUS"; LEASE_MIN=15
  _fr6_sibling sib3 "claude:opus" 1
  echo '{"type":"result","result":"OAuth session expired · Please run /login"}' > "$BUS/run-d1.jsonl"
  run limit_error claude "$BUS" d1
  [ "$status" -eq 1 ]
  [ ! -e "$BUS/limits/claude.dead" ]
  [ ! -e "$BUS/limits/claude.dead.evidence" ]
  [ ! -e "$BUS/limits/claude.limited" ]
  [ ! -e "$BUS/limits/claude.limited.evidence" ]
  [ -s "$BUS/limits/claude.broken.evidence" ]
  local ttl; ttl="$(_marker_ttl "$BUS/limits/claude.broken" 0)"
  [ "$ttl" -ge 300 ]
  [ "$ttl" -le 600 ]
  [ "$(_fr7_token "$BUS/limits/claude.broken")" = "auth-death" ]
}

@test "spec14 FR-6: auth-death with NO live sibling still produces today's .dead + .dead.evidence" {
  bus_init "$BUS"; LEASE_MIN=15
  echo '{"type":"result","result":"OAuth session expired · Please run /login"}' > "$BUS/run-d2.jsonl"
  run limit_error claude "$BUS" d2
  [ "$status" -eq 1 ]
  [ -f "$BUS/limits/claude.dead" ]
  [ -s "$BUS/limits/claude.dead.evidence" ]
  [ ! -e "$BUS/limits/claude.limited" ]
  [ ! -e "$BUS/limits/claude.broken" ]
}

@test "spec14 FR-6: the ERROR-envelope auth-death arm downgrades too (claude and gemini)" {
  bus_init "$BUS"; LEASE_MIN=15
  _fr6_sibling sib4 "gemini:default" 1
  echo '{"type":"error","message":"Failed to authenticate: invalid credentials"}' > "$BUS/run-d3.jsonl"
  run limit_error gemini "$BUS" d3
  [ "$status" -eq 1 ]
  [ ! -e "$BUS/limits/gemini.dead" ]
  [ -f "$BUS/limits/gemini.broken" ]
}

@test "spec14 FR-6: downgraded .broken is cleared by the lane's next successful finalize (unlike .limited, which only a TTL clears)" {
  # _archive_and_release (swarm-run.sh) rm's limits/<lane>.dead and limits/<lane>.broken on any
  # successful finalize but has no analogous rm for .limited — this is the exact reason the
  # downgrade must land on .broken, not .limited (cross-review fix). Simulate that cleanup here
  # directly against the two marker kinds to pin the contract without dragging in swarm-run.sh.
  bus_init "$BUS"; LEASE_MIN=15
  _fr6_sibling sib5 "claude:opus" 1
  echo '{"type":"result","result":"OAuth session expired · Please run /login"}' > "$BUS/run-d5.jsonl"
  limit_error claude "$BUS" d5 || true
  [ -f "$BUS/limits/claude.broken" ]
  rm -f "$BUS/limits/claude.dead" "$BUS/limits/claude.broken"   # mirrors _archive_and_release's rm -f list
  [ ! -e "$BUS/limits/claude.broken" ]
}

# --- spec 14 FR-1: cage-denied failure class (AC-1, AC-6's mixed fixture) ------------------------

@test "spec14 FR-1: cage_denials counts read-class denials in the last result event" {
  bus_init "$BUS"
  # 10 read-class denials, the shape the cockpit057b a-api card produced
  jq -c -n '{type:"result",subtype:"success",is_error:false,
             permission_denials:[range(10) | {tool_name:"Read",tool_input:{file_path:"src/f\(.).ts"}}]}' \
    > "$BUS/run-c1.jsonl"
  run cage_denials "$BUS" c1
  [ "$status" -eq 0 ]
  [ "$output" = "10" ]
}

@test "spec14 FR-1: cage_denials excludes Bash denials — a write cage denies Bash by design" {
  bus_init "$BUS"
  jq -c -n '{type:"result",subtype:"success",is_error:false,
             permission_denials:[{tool_name:"Bash",tool_input:{command:"grep -r x ."}},
                                 {tool_name:"Bash",tool_input:{command:"ls"}}]}' > "$BUS/run-c2.jsonl"
  run cage_denials "$BUS" c2
  [ "$output" = "0" ]
}

@test "spec14 FR-1: cage_denials is 0 when the result event has no permission_denials field" {
  bus_init "$BUS"
  echo '{"type":"result","subtype":"success","is_error":false,"result":"done"}' > "$BUS/run-c3.jsonl"
  run cage_denials "$BUS" c3
  [ "$output" = "0" ]
  # ...and 0 for a card with no run log at all (rc 0 always)
  run cage_denials "$BUS" c-missing
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "spec14 FR-1: cage_denials counts 1 for AC-6's deliberately MIXED fixture (one Read, one Bash)" {
  bus_init "$BUS"
  cat > "$BUS/run-c4.jsonl" <<'JSON'
{"type":"result","subtype":"success","is_error":false,"permission_denials":[{"tool_name":"Read","tool_use_id":"toolu_018UWfSK5fYukadEDY6x2aXu","tool_input":{"file_path":"<target-repo>/apps/brain-api/src/cockpit/contract.ts"}},{"tool_name":"Bash","tool_use_id":"toolu_011aErW9MfVNg2mAP8heiLtf","tool_input":{"command":"grep -r \"MartCockpitBetWideRowSchema\" <target-repo>/packages/shared","description":"Search shared package"}}]}
JSON
  run cage_denials "$BUS" c4
  [ "$output" = "1" ]
}

@test "spec14 FR-1: cage_denials counts Glob/Grep/NotebookRead too, and reads the LAST result event" {
  bus_init "$BUS"
  {
    jq -c -n '{type:"result",permission_denials:[{tool_name:"Read",tool_input:{file_path:"a.ts"}}]}'
    jq -c -n '{type:"result",permission_denials:[{tool_name:"Glob",tool_input:{pattern:"**/*.ts"}},
                                                 {tool_name:"Grep",tool_input:{pattern:"foo"}},
                                                 {tool_name:"NotebookRead",tool_input:{file_path:"n.ipynb"}},
                                                 {tool_name:"Edit",tool_input:{file_path:"b.ts"}}]}'
  } > "$BUS/run-c5.jsonl"
  run cage_denials "$BUS" c5
  [ "$output" = "3" ]
}

@test "spec14 FR-1: CAGE_DENY_MAX default is 0 and it is a real conf_load key (env > file)" {
  unset CAGE_DENY_MAX
  conf_load "$BATS_TEST_TMPDIR/nonexistent.conf"
  [ "$CAGE_DENY_MAX" = "0" ]

  printf 'CAGE_DENY_MAX=5\n' > "$BATS_TEST_TMPDIR/cage.conf"
  unset CAGE_DENY_MAX
  conf_load "$BATS_TEST_TMPDIR/cage.conf"
  [ "$CAGE_DENY_MAX" = "5" ]

  CAGE_DENY_MAX=9
  conf_load "$BATS_TEST_TMPDIR/cage.conf"
  [ "$CAGE_DENY_MAX" = "9" ]
}

@test "cross-review fix: conf_load dies loudly on a non-numeric CAGE_DENY_MAX (would otherwise crash the finalize gate under set -u)" {
  export CAGE_DENY_MAX=abc
  run conf_load "$BATS_TEST_TMPDIR/nonexistent.conf"
  [ "$status" -ne 0 ]
  [[ "$output" == *"CAGE_DENY_MAX"* ]]
}

@test "cross-review fix: conf_load accepts CAGE_DENY_MAX=0 and a positive value" {
  export CAGE_DENY_MAX=0
  conf_load "$BATS_TEST_TMPDIR/nonexistent.conf"
  [ "$CAGE_DENY_MAX" = "0" ]

  export CAGE_DENY_MAX=5
  conf_load "$BATS_TEST_TMPDIR/nonexistent.conf"
  [ "$CAGE_DENY_MAX" = "5" ]
}

@test "cross-review fix: conf_load dies loudly on a negative CAGE_DENY_MAX" {
  export CAGE_DENY_MAX=-1
  run conf_load "$BATS_TEST_TMPDIR/nonexistent.conf"
  [ "$status" -ne 0 ]
  [[ "$output" == *"CAGE_DENY_MAX"* ]]
}

@test "cross-review fix: conf_load dies loudly on an explicitly-empty CAGE_DENY_MAX (unlike TIMEOUT_<LANE>, empty is not its default)" {
  export CAGE_DENY_MAX=""
  run conf_load "$BATS_TEST_TMPDIR/nonexistent.conf"
  [ "$status" -ne 0 ]
  [[ "$output" == *"CAGE_DENY_MAX"* ]]
}

@test "spec14 FR-1: feedback_stubs drafts a cage-denied stub from the durable marker glob" {
  bus_init "$BUS"
  mkdir -p "$BATS_TEST_TMPDIR/feedback"
  printf 'denials=3\nsrc/a.ts\nsrc/b.ts\n' > "$BUS/limits/a-api.cage-denied"
  FEEDBACK_DIR="$BATS_TEST_TMPDIR/feedback" SPEEDWARS_RUN=cagerun feedback_stubs "$BUS"
  local f; f="$(find "$BATS_TEST_TMPDIR/feedback" -name '*-auto-cage-denied.md')"
  [ -n "$f" ]
  grep -q 'severity: major' "$f"
  grep -q 'a-api' "$f"
  grep -q 'src/a.ts' "$f"
}

@test "spec14 FR-1: the cage-denied stub never leaks an absolute operator path" {
  bus_init "$BUS"
  mkdir -p "$BATS_TEST_TMPDIR/feedback"
  printf 'denials=1\n%s/secret/place.ts\n' "$HOME" > "$BUS/limits/a-mon.cage-denied"
  FEEDBACK_DIR="$BATS_TEST_TMPDIR/feedback" SPEEDWARS_RUN=cagerun2 feedback_stubs "$BUS"
  local f; f="$(find "$BATS_TEST_TMPDIR/feedback" -name '*-auto-cage-denied.md')"
  [ -n "$f" ]
  ! grep -q "$HOME" "$f"
  grep -q '~/secret/place.ts' "$f"
}

# --- spec 04 §Amendment 2026-07-25 FR-C: per-lane TIMEOUT_<LANE> conf keys -----------------------

@test "spec04 FR-C: all six TIMEOUT_<LANE> keys default to EMPTY (pure fallback onto WORKER_TIMEOUT_SEC)" {
  local k
  for k in TIMEOUT_CLAUDE TIMEOUT_CODEX TIMEOUT_GEMINI TIMEOUT_GLM TIMEOUT_GROK TIMEOUT_KIMI; do
    unset "$k"
  done
  conf_load "$BATS_TEST_TMPDIR/nonexistent.conf"
  for k in TIMEOUT_CLAUDE TIMEOUT_CODEX TIMEOUT_GEMINI TIMEOUT_GLM TIMEOUT_GROK TIMEOUT_KIMI; do
    [ "${!k}" = "" ]
  done
}

@test "spec04 FR-C: all six join CONF_KEYS — a key outside it silently loses FR-1 precedence" {
  local k
  for k in TIMEOUT_CLAUDE TIMEOUT_CODEX TIMEOUT_GEMINI TIMEOUT_GLM TIMEOUT_GROK TIMEOUT_KIMI; do
    [[ " ${CONF_KEYS[*]} " == *" $k "* ]]
  done
}

@test "spec04 FR-C: an env TIMEOUT_CODEX beats a swarm.conf value (the backlog-31 regression guard)" {
  printf 'TIMEOUT_CODEX=2400\n' > "$BATS_TEST_TMPDIR/t.conf"
  unset TIMEOUT_CODEX
  conf_load "$BATS_TEST_TMPDIR/t.conf"
  [ "$TIMEOUT_CODEX" = "2400" ]

  TIMEOUT_CODEX=900
  conf_load "$BATS_TEST_TMPDIR/t.conf"
  [ "$TIMEOUT_CODEX" = "900" ]
}

@test "spec04 FR-C: a non-numeric TIMEOUT_CODEX dies loudly at conf_load" {
  printf 'TIMEOUT_CODEX=soon\n' > "$BATS_TEST_TMPDIR/bad.conf"
  unset TIMEOUT_CODEX
  run conf_load "$BATS_TEST_TMPDIR/bad.conf"
  [ "$status" -eq 1 ]
  [[ "$output" == *"TIMEOUT_CODEX must be a positive integer"* ]]
}

@test "spec04 FR-C: a zero or negative TIMEOUT_GLM dies too" {
  local v
  for v in 0 -5; do
    printf 'TIMEOUT_GLM=%s\n' "$v" > "$BATS_TEST_TMPDIR/bad2.conf"
    unset TIMEOUT_GLM
    run conf_load "$BATS_TEST_TMPDIR/bad2.conf"
    [ "$status" -eq 1 ]
  done
}

@test "spec04 FR-C: WORKER_TIMEOUT_SEC gains the same validation — non-numeric disarmed the watchdog silently" {
  printf 'WORKER_TIMEOUT_SEC=none\n' > "$BATS_TEST_TMPDIR/bad3.conf"
  unset WORKER_TIMEOUT_SEC
  run conf_load "$BATS_TEST_TMPDIR/bad3.conf"
  [ "$status" -eq 1 ]
  [[ "$output" == *"WORKER_TIMEOUT_SEC must be a positive integer"* ]]

  # ...and EMPTY is valid for the six but NOT for WORKER_TIMEOUT_SEC
  printf 'WORKER_TIMEOUT_SEC=\n' > "$BATS_TEST_TMPDIR/bad4.conf"
  unset WORKER_TIMEOUT_SEC
  run conf_load "$BATS_TEST_TMPDIR/bad4.conf"
  [ "$status" -eq 1 ]
}

@test "spec04 FR-C: a valid per-lane timeout loads and survives (positive int)" {
  printf 'TIMEOUT_GLM=1200\nTIMEOUT_KIMI=900\n' > "$BATS_TEST_TMPDIR/ok.conf"
  unset TIMEOUT_GLM TIMEOUT_KIMI
  conf_load "$BATS_TEST_TMPDIR/ok.conf"
  [ "$TIMEOUT_GLM" = "1200" ]
  [ "$TIMEOUT_KIMI" = "900" ]
  [ "$TIMEOUT_GROK" = "" ]
}

# --- plan 004 P2: lane_summary (P2-FR1) + bus_archive --------------------------------------------

# _p2_bus — a bus with one worker transcript, marker trees, an answer file, and a ledger holding
# two runs (only "p2run" is ours). Exports SPEEDWARS_FILE so _speedwars_file resolves into the
# test tmpdir and docs/ops/ is a throwaway tree, never the real one.
_p2_bus() {
  bus_init "$BUS"
  printf 'p2run\n' > "$BUS/.run-label"
  printf '{"type":"result","total_cost_usd":0.1}\n' > "$BUS/run-a1.jsonl"
  printf '{"type":"result","total_cost_usd":0.2}\n' > "$BUS/run-a2.jsonl"
  printf 'rotated\n' > "$BUS/run-a1.jsonl.1"
  printf 'boom\n' > "$BUS/run-a2.jsonl.stderr"
  printf 'the answer text, which may contain fetched web content\n' > "$BUS/res-a1.txt"
  printf '{"lane":"glm"}\n' > "$BUS/done/a1"
  : > "$BUS/limits/glm.limited"

  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/docs/ops/speedwars.jsonl"
  mkdir -p "$(dirname "$SPEEDWARS_FILE")"
  cat > "$SPEEDWARS_FILE" <<'LEDGER'
{"ts":"2026-07-25T10:00:00Z","run":"p2run","id":"a1","served_lane":"glm","outcome":"done","wall_secs":10,"cost_usd":0.10}
{"ts":"2026-07-25T10:01:00Z","run":"p2run","id":"a2","served_lane":"glm","outcome":"done","wall_secs":90,"cost_usd":0.20}
{"ts":"2026-07-25T10:02:00Z","run":"p2run","id":"a3","served_lane":"grok","outcome":"done","wall_secs":5,"cost_usd":0.05}
{"ts":"2026-07-25T10:03:00Z","run":"other","id":"z1","served_lane":"codex","outcome":"done","wall_secs":7,"cost_usd":9.99}
{"type":"verdict","run":"p2run","id":"a1","verified":true}
{"type":"verdict","run":"p2run","id":"a2","verified":false}
{"type":"verdict","run":"p2run","id":"a3","verified":true}
{"type":"run-summary","run":"p2run","ts":"2026-07-25T10:04:00Z","mode":"full","done_n":3}
LEDGER
}

# _p2_summary — run lane_summary capturing stdout and stderr SEPARATELY into $P2_OUT/$P2_ERR
# (plain redirection, not `run --separate-stderr`, which would need a bats version gate this file
# does not set). $P2_RC is its exit status.
_p2_summary() {
  P2_RC=0
  lane_summary "$BUS" > "$BATS_TEST_TMPDIR/p2.out" 2> "$BATS_TEST_TMPDIR/p2.err" || P2_RC=$?
  P2_OUT="$(<"$BATS_TEST_TMPDIR/p2.out")"
  P2_ERR="$(<"$BATS_TEST_TMPDIR/p2.err")"
}

@test "lane_summary: prints exactly three lines on stderr, one per headline metric" {
  _p2_bus
  _p2_summary
  [ "$P2_RC" -eq 0 ]
  [ -z "$P2_OUT" ]                       # stdout stays clean for the results block
  [ "$(grep -c '^swarm: lane ' <<<"$P2_ERR")" = "3" ]
  [[ "$P2_ERR" == *'$/verified-done'* ]]
  [[ "$P2_ERR" == *'p95 wall'* ]]
  [[ "$P2_ERR" == *'false-done rate'* ]]
}

@test "lane_summary: is scoped to THIS run — a foreign run's lane never appears" {
  _p2_bus
  _p2_summary
  [ "$P2_RC" -eq 0 ]
  [[ "$P2_ERR" == *"glm"* ]]
  [[ "$P2_ERR" == *"grok"* ]]
  [[ "$P2_ERR" != *"codex"* ]]           # run "other" is filtered out before the fold
  [[ "$P2_ERR" != *"9.99"* ]]
}

@test "lane_summary: P2-FR2 — every figure carries its denominator" {
  _p2_bus
  _p2_summary
  [ "$P2_RC" -eq 0 ]
  # glm: 0.30 spent over 1 verified-done card of 2, both attempts priced; 1 of 2 judged is false.
  [[ "$P2_ERR" == *"glm 0.3 [vdone 1/2 cards, priced 2/2 att]"* ]]
  [[ "$P2_ERR" == *"glm 90 [n 2 att]"* ]]
  [[ "$P2_ERR" == *"glm 50% [1/2 judged]"* ]]
  [[ "$P2_ERR" == *"grok 0% [0/1 judged]"* ]]
}

@test "lane_summary: derives from the canonical fold, never a private aggregation" {
  # The numbers must be the ones src/speedwars-report.sh --json --run emits for this run.
  _p2_bus
  local want
  want="$(bash "$BATS_TEST_DIRNAME/../src/speedwars-report.sh" --json --run p2run "$SPEEDWARS_FILE" \
          | jq -r '.lanes.glm.cost_per_verified_done')"
  [ "$want" = "0.3" ]
  _p2_summary
  [[ "$P2_ERR" == *"glm 0.3 "* ]]
}

@test "lane_summary: no evidence surface (no ledger) is a silent no-op, rc 0" {
  bus_init "$BUS"
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/nope/speedwars.jsonl"
  _p2_summary
  [ "$P2_RC" -eq 0 ]
  [ -z "$P2_OUT" ]
  [ -z "$P2_ERR" ]
}

@test "bus_archive: freezes the run's raw evidence into bus-archives/<run>/" {
  _p2_bus
  run bus_archive "$BUS"
  [ "$status" -eq 0 ]
  local d="$BATS_TEST_TMPDIR/docs/ops/bus-archives/p2run"
  [ -d "$d" ]
  local ext=gz
  command -v zstd >/dev/null 2>&1 && ext=zst
  [ -f "$d/run-a1.jsonl.$ext" ]
  [ -f "$d/run-a2.jsonl.$ext" ]
  [ -f "$d/run-a1.jsonl.1.$ext" ]
  [ -f "$d/run-a2.jsonl.stderr.$ext" ]
  [ -f "$d/res-a1.txt.$ext" ]
  [ -f "$d/markers.tar.$ext" ]
  [ -f "$d/speedwars.jsonl.$ext" ]
  [ -f "$d/run-summary.json" ]
  [ -f "$d/MANIFEST.txt" ]
  grep -q "^run: p2run" "$d/MANIFEST.txt"
  grep -q "^compressor: " "$d/MANIFEST.txt"
  # no absolute operator path leaked into the manifest
  ! grep -qE '(^|[^A-Za-z])/(home|Users)/' "$d/MANIFEST.txt"
}

@test "bus_archive: members round-trip and the ledger slice holds only this run" {
  _p2_bus
  bus_archive "$BUS"
  local d="$BATS_TEST_TMPDIR/docs/ops/bus-archives/p2run" ext=gz decomp=(gzip -dc)
  if command -v zstd >/dev/null 2>&1; then ext=zst; decomp=(zstd -dc); fi
  run "${decomp[@]}" "$d/res-a1.txt.$ext"
  [[ "$output" == *"the answer text"* ]]
  run bash -c "'${decomp[0]}' ${decomp[1]} '$d/speedwars.jsonl.$ext' | jq -r '.run' | sort -u"
  [ "$output" = "p2run" ]
  [ "$(jq -r '.done_n' "$d/run-summary.json")" = "3" ]
  # the marker tree is intact inside the tar
  run bash -c "'${decomp[0]}' ${decomp[1]} '$d/markers.tar.$ext' | tar -tf -"
  [[ "$output" == *"done/a1"* ]]
  [[ "$output" == *"limits/glm.limited"* ]]
}

@test "bus_archive: re-close is idempotent — replaces its own dir, never a sibling run's" {
  _p2_bus
  mkdir -p "$BATS_TEST_TMPDIR/docs/ops/bus-archives/otherrun"
  : > "$BATS_TEST_TMPDIR/docs/ops/bus-archives/otherrun/keepme"
  bus_archive "$BUS"
  local d="$BATS_TEST_TMPDIR/docs/ops/bus-archives/p2run"
  : > "$d/stale-member"
  bus_archive "$BUS"
  [ ! -e "$d/stale-member" ]                                            # own dir replaced
  [ -e "$BATS_TEST_TMPDIR/docs/ops/bus-archives/otherrun/keepme" ]      # sibling untouched
  [ -f "$d/MANIFEST.txt" ]
}

@test "bus_archive: an unwritable archive root is a no-op, rc 0 — a run never fails on it" {
  _p2_bus
  chmod 500 "$BATS_TEST_TMPDIR/docs/ops"
  run bus_archive "$BUS"
  chmod 700 "$BATS_TEST_TMPDIR/docs/ops"
  [ "$status" -eq 0 ]
  [ ! -d "$BATS_TEST_TMPDIR/docs/ops/bus-archives/p2run" ]
}

@test "bus_archive: BUS_ARCHIVE=0 turns it off; a path-shaped run label cannot escape the tree" {
  _p2_bus
  BUS_ARCHIVE=0 run bus_archive "$BUS"
  [ "$status" -eq 0 ]
  [ ! -d "$BATS_TEST_TMPDIR/docs/ops/bus-archives/p2run" ]

  printf '../escape\n' > "$BUS/.run-label"
  run bus_archive "$BUS"
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/docs/ops/escape" ]
  # sanitizing "../escape" changes it (the "/" becomes "_"), so per the collision fix below the
  # dirname carries a checksum suffix rather than landing on the bare ".._escape" name verbatim.
  local hit
  hit="$(find "$BATS_TEST_TMPDIR/docs/ops/bus-archives" -maxdepth 1 -type d -name '.._escape-*')"
  [ -n "$hit" ]
  [ ! -d "$BATS_TEST_TMPDIR/docs/ops/bus-archives/.._escape" ]
}

@test "bus_archive: sanitized-collision — two labels that sanitize to the same string land in two distinct dirs" {
  _p2_bus
  export SPEEDWARS_RUN="foo/bar"
  run bus_archive "$BUS"
  [ "$status" -eq 0 ]
  export SPEEDWARS_RUN="foo_bar"
  run bus_archive "$BUS"
  [ "$status" -eq 0 ]
  unset SPEEDWARS_RUN

  local root="$BATS_TEST_TMPDIR/docs/ops/bus-archives"
  # "foo_bar" needed no sanitizing: plain, historical dirname, no checksum suffix.
  [ -d "$root/foo_bar" ]
  grep -q '^run: foo_bar$' "$root/foo_bar/MANIFEST.txt"

  # "foo/bar" sanitizes to the SAME string "foo_bar" — collision avoided via the checksum suffix,
  # landing in its own dir rather than clobbering (or being clobbered by) the one above.
  local hashed
  hashed="$(find "$root" -maxdepth 1 -type d -name 'foo_bar-*')"
  [ -n "$hashed" ]
  grep -q '^run: foo/bar$' "$hashed/MANIFEST.txt"
}
