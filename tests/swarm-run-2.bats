#!/usr/bin/env bats
# Integration tests for swarm-run.sh full mode — shard 2/4 of the former tests/swarm-run.bats,
# split so check.sh's CHECK_JOBS per-file fan-out gets a shorter critical path. No real API calls —
# every claude/codex/gemini invocation resolves to a fake script under $BATS_TEST_TMPDIR/bin,
# installed by the shared fixture this file loads.
#
# Project: unimatrix — multi-model swarm orchestrator driven from Claude Code
# Module:  tests/swarm-run-2.bats
# Deps:    bats-core, tests/helpers/swarm-run-fixture.bash (setup/teardown + fakes + helpers), src/swarm-lib.sh, swarm-run.sh
# Tested:  n/a — this is the test file
#
# Design constraints:
# - All file-scope state, setup()/teardown(), fake installers, and probe/fixture helpers live in
#   tests/helpers/swarm-run-fixture.bash — pulled in by the `load` below (bats resolves it against
#   this file's own dir and picks setup/teardown up from the fixture).
# - Test bodies are verbatim from the original file; original order is preserved within the shard.

load 'helpers/swarm-run-fixture'

@test "spec01 FR-A attribution: the generic retry/failover finalize-tail requeue names its own mover" {
  _write_conf "claude:opus gemini:gemini-3-flash"
  printf 'GEMINI_API_KEY=test-gem-key\n' > "$BATS_TEST_TMPDIR/envmaster"
  export ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster"
  _fake FAKE_CLAUDE_GARBAGE_COUNT "$BATS_TEST_TMPDIR/garbage-count-rc3"
  _fake FAKE_GEMINI_RESULT "rescued by gemini"
  _enqueue rc3 "spec rescued by failover, requeued via the generic finalize-tail"

  run timeout 25 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/rc3" ]
  [[ "$output" == *"mover=finalize-tail requeued rc3"*"retry/failover"* ]]
}

@test "SPEEDWARS_AUTO=0: a successful run writes no speedwars row even with SPEEDWARS_FILE set" {
  _write_conf "claude:opus" 4 15
  _fake FAKE_CLAUDE_RESULT "OK"
  _enqueue sw0 "speedwars off check"

  SPEEDWARS_AUTO=0 SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-off.jsonl" run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/sw-off.jsonl" ]
}

# --- spec10: role classes & universal fallback (plans/003-role-tier-fallback) -------------------
# RED wave (W1) — none of this exists in src/swarm-lib.sh or swarm-run.sh yet. queue/<id>.chain is
# never consulted by chain_current/chain_advance (only limits/.chain-<id> or $EXEC_CHAIN);
# kimi_budget_ok, lane_blocked, dead_flag, answer_unusable, and the write-card diff gate don't
# exist; limit_error has no claude/gemini arms; _print_config_table has no CLASS_REVIEW line.
# Every test below writes queue/<id>.chain DIRECTLY (mkdir -p "$BUS/queue" first) rather than via
# specs/<id>.chain + enqueue-time move — _enqueue_pending_specs only moves .lane/.write sidecars
# today, and seeding queue/ directly is robust either way once W2 adds .chain to that move too.

@test "spec10 FR-R2: queue/<id>.chain seed is honored — codex pre-limited, walk resolves to claude" {
  # Today: chain_current ignores queue/<id>.chain entirely and reads EXEC_CHAIN ("claude:opus")
  # instead, so codex is never even considered — the id claims straight onto claude:opus with no
  # skip/advance ever happening. "served by claude" and "run completes" pass by COINCIDENCE (single-
  # entry EXEC_CHAIN happens to be claude); the row assertions below are what actually catch the
  # missing behavior: today's speed_row `requested` field is the raw lane:model token it was called
  # with ("claude:opus"), never "codex", and it carries no fallback_reason field at all (FR-R9's
  # limits/.fbreason-<id> read doesn't exist in speed_row yet) — both jq assertions fail.
  _write_conf "claude:opus" 4 15
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-r2.jsonl"
  _fake FAKE_CLAUDE_RESULT "claude via chain seed"
  _enqueue r2a "chain seed check"
  mkdir -p "$BUS/queue" "$BUS/limits"
  printf '%s' "codex:default claude:sonnet" > "$BUS/queue/r2a.chain"
  printf '18000' > "$BUS/limits/codex.limited"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/r2a" ]
  [ "$(jq -r '.lane' "$BUS/done/r2a")" = "claude" ]
  [ "$(<"$BUS/res-r2a.txt")" = "claude via chain seed" ]
  # spec 12 FR-3: full_run now appends a trailing run-summary row (.type=="run-summary") to this
  # SAME file — select this branch's own row by id so that trailer never shadows the assertion.
  [ "$(jq -r 'select(.id=="r2a") | .requested' "$SPEEDWARS_FILE")" = "codex" ]
  [ "$(jq -r 'select(.id=="r2a") | .served_lane' "$SPEEDWARS_FILE")" = "claude" ]
  [ "$(jq -r 'select(.id=="r2a") | .fallback_reason' "$SPEEDWARS_FILE")" = "limit" ]
}

@test "spec10 FR-R5: kimi fallback declines when BUDGET_USD is already exceeded — parks loudly mentioning budget" {
  # Today: chain_current still ignores queue/<id>.chain and reads EXEC_CHAIN ("claude:opus", a
  # single entry). claude is pre-limited, so the existing skip loop in _try_claim_one advances past
  # it, finds the (single-entry) chain exhausted, and parks the id immediately — kimi_budget_ok
  # doesn't exist, "budget" never appears anywhere in swarm-run.sh/swarm-lib.sh output, so the
  # `[[ "$output" == *"budget"* ]]` assertion fails outright regardless of the (coincidentally
  # correct-looking) park/nonzero outcome.
  _write_conf "claude:opus" 4 15
  cat >> "$CONF" <<'EOF'
BUDGET_USD=0.02
EOF
  printf 'MOONSHOT_API_KEY=test-kimi-key\n' > "$BATS_TEST_TMPDIR/envmaster"
  export ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster"
  _enqueue r5a "budget gated review"
  mkdir -p "$BUS/queue" "$BUS/limits"
  printf '%s' "claude:sonnet kimi:kimi-k3" > "$BUS/queue/r5a.chain"
  printf '18000' > "$BUS/limits/claude.limited"
  printf '0.028' > "$BUS/limits/kimi.spend"

  run timeout 20 "$RUNSH"
  [ "$status" -ne 0 ]
  [[ "$output" == *"budget"* ]]
  [ -f "$BUS/limits/r5a.parked" ]
  [ ! -e "$BUS/done/r5a" ]
}

@test "spec10 FR-R5: BUDGET_USD=0 (unrestricted) — the same chain completes on kimi despite claude being limited" {
  # Today: chain_current ignores queue/<id>.chain and reads EXEC_CHAIN ("claude:opus" only) —
  # kimi is never even in the chain it walks. claude limited -> the single-entry chain is
  # exhausted -> the id parks (status nonzero, no done/). Test expects status 0 with done/r5b
  # served by kimi, so this fails outright on both the exit status and the missing done marker.
  _write_conf "claude:opus" 4 15
  cat >> "$CONF" <<'EOF'
BUDGET_USD=0
EOF
  printf 'MOONSHOT_API_KEY=test-kimi-key\n' > "$BATS_TEST_TMPDIR/envmaster"
  export ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster"
  _fake FAKE_CLAUDE_RESULT "kimi via budget-open chain"
  _enqueue r5b "budget open review"
  mkdir -p "$BUS/queue" "$BUS/limits"
  printf '%s' "claude:sonnet kimi:kimi-k3" > "$BUS/queue/r5b.chain"
  printf '18000' > "$BUS/limits/claude.limited"
  printf '0.028' > "$BUS/limits/kimi.spend"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/r5b" ]
  [ "$(jq -r '.lane' "$BUS/done/r5b")" = "kimi" ]
  [ "$(<"$BUS/res-r5b.txt")" = "kimi via budget-open chain" ]
}

@test "spec10 FR-R6: pinned card whose lane is limited bounded-waits then parks within PIN_WAIT_SEC, not the TTL" {
  # Today: the PINNED branch of _try_claim_one only checks limit_active (not the new lane_blocked)
  # and, on a hit, just `continue`s — no waiting marker, no stderr notice, no park. With glm.limited
  # fresh (TTL 18000s) it silently re-polls (sleep 1) forever; `timeout 20` kills the run at ~20s
  # (SIGTERM — _sweep_on_driver_term's trap exits the script itself, so $status ends up nonzero
  # incidentally, same as a genuine park would look). The assertions that actually catch the missing
  # behavior are the ones below the exit-status check: limits/r6a.parked never appears and neither
  # "waiting" nor "parking" is ever printed, since the engine never reaches that new code path at all.
  _write_conf "claude:opus" 4 15
  cat >> "$CONF" <<'EOF'
PIN_WAIT_SEC=2
EOF
  printf 'Z_AI_CODING_KEY=test-glm-key\n' > "$BATS_TEST_TMPDIR/envmaster"
  export ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster"
  _enqueue r6a "pinned glm, pre-limited"
  echo "glm:glm-5.2" > "$BUS/specs/r6a.lane"
  mkdir -p "$BUS/limits"
  printf '18000' > "$BUS/limits/glm.limited"

  run timeout 20 "$RUNSH"
  [ "$status" -ne 0 ]
  [ -f "$BUS/limits/r6a.parked" ]
  [[ "$output" == *"waiting"* || "$output" == *"parking"* ]]
  [ ! -e "$BUS/done/r6a" ]
}

@test "spec10 FR-R6: pinned lane's TTL expiring under a generous PIN_WAIT_SEC lets the run complete, never parked" {
  # Today: PIN_WAIT_SEC doesn't exist as a concept at all — the pinned branch relies solely on
  # limit_active's own TTL (5s here — 1s flaked under full-suite load: startup could outlive the
  # TTL before the engine's first limit_active check, so the waiting notice never printed), which
  # ALREADY makes this scenario complete without parking
  # under current code (no new behavior needed for that half). The one assertion that's actually new
  # and fails today: FR-R6 requires exactly one "waiting on limited pinned lane"-style stderr notice
  # AT MARKER CREATION regardless of how quickly the TTL then clears — that text does not exist
  # anywhere in swarm-run.sh today, so `[[ "$output" == *"waiting"* ]]` fails deterministically.
  _write_conf "claude:opus" 4 15
  cat >> "$CONF" <<'EOF'
PIN_WAIT_SEC=60
EOF
  printf 'Z_AI_CODING_KEY=test-glm-key\n' > "$BATS_TEST_TMPDIR/envmaster"
  export ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster"
  _fake FAKE_CLAUDE_RESULT "glm via child-env swap"
  _enqueue r6b "pinned glm, TTL expires fast"
  echo "glm:glm-5.2" > "$BUS/specs/r6b.lane"
  mkdir -p "$BUS/limits"
  printf '5' > "$BUS/limits/glm.limited"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/r6b" ]
  [ ! -e "$BUS/limits/r6b.parked" ]
  [[ "$output" == *"waiting"* ]]
}

@test "spec10 FR-R7: class-exhausted review chain (both members limited) parks loudly with 'exhausted' in stderr, no res file" {
  # Today: same root cause as FR-R2/R5 — chain_current ignores queue/<id>.chain and falls back to
  # EXEC_CHAIN ("claude:opus"), which contains neither codex nor kimi and isn't limited at all. The
  # id claims straight onto claude, the fake answers "OK" by default, and the branch completes
  # normally (status 0, res-r7a.txt written) — the exact opposite of every assertion below, and
  # "exhausted" never appears in the output since chain_advance's real exhaustion path is never hit.
  _write_conf "claude:opus" 4 15
  _enqueue r7a "both review lanes limited"
  mkdir -p "$BUS/queue" "$BUS/limits"
  printf '%s' "codex:default kimi:kimi-k3" > "$BUS/queue/r7a.chain"
  printf '18000' > "$BUS/limits/codex.limited"
  printf '18000' > "$BUS/limits/kimi.limited"

  run timeout 20 "$RUNSH"
  [ "$status" -ne 0 ]
  [[ "$output" == *"exhausted"* ]]
  [ -f "$BUS/limits/r7a.parked" ]
  [ ! -e "$BUS/res-r7a.txt" ]
}

@test "spec10 FR-R8: claude OAuth-death answer (cal056 false-done shape) sets claude.dead and fails over to codex, not trusted as done" {
  # Today: limit_error's claude case doesn't exist (falls into the bare `*) return 0` catch-all) and
  # answer_unusable/dead_flag don't exist at all. The fake's "autherr" once-mode (added by this wave)
  # emits a NORMAL result envelope with no error/turn.failed event, so extract_answer succeeds and
  # _finalize_worker's success branch takes it as a real "done" — on claude, with the auth-error text
  # as the "answer". limits/claude.dead is never created; done/r8a.lane is "claude", not "codex".
  _write_conf "claude:opus codex:default" 4 15
  _fake FAKE_CLAUDE_ONCE_MARKER "$BATS_TEST_TMPDIR/r8-once"
  _fake FAKE_CLAUDE_ONCE_MODE autherr
  _fake FAKE_CODEX_RESULT "codex rescued it"
  _enqueue r8a "claude auth-death branch"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/r8a" ]
  [ "$(jq -r '.lane' "$BUS/done/r8a")" = "codex" ]
  [ "$(<"$BUS/res-r8a.txt")" = "codex rescued it" ]
  [ -f "$BUS/limits/claude.dead" ]
}

@test "spec10 FR-R11: write-card diff gate rejects a served 'done' that touched nothing under the target — retries then parks" {
  # Today: _finalize_worker's success branch has no diff gate at all (no limits/<id>.stamp, no
  # `find -newer`) — extract_answer succeeds trivially on the fake's claimed-done text and the
  # branch is finalized as done regardless of whether the write target was ever touched. done/r11a
  # exists, status is 0, and the target stays empty — the opposite of every assertion below.
  _write_conf "claude:opus" 4 15
  local target="$BATS_TEST_TMPDIR/r11target"
  mkdir -p "$target"
  # The gate tolerates ~2s of pre-spawn mtime slack (backdated stamp + granule-safe -newermt) so
  # same-second WRITES are never missed; a target dir mkdir'd microseconds before spawn would sit
  # inside that window and read as "changed". This card's scenario is a PRE-EXISTING target the
  # worker never touched — pin the fixture's mtime accordingly.
  touch -d '10 seconds ago' "$target"
  _fake FAKE_CLAUDE_RESULT "claims done but wrote nothing"
  _enqueue r11a "write card whose worker writes nothing"
  printf '%s' "$target" > "$BUS/specs/r11a.write"

  run timeout 25 "$RUNSH"
  [ "$status" -ne 0 ]
  [ ! -e "$BUS/done/r11a" ]
  [ -f "$BUS/limits/r11a.parked" ]
  [ -z "$(find "$target" -mindepth 1 2>/dev/null)" ]
}

@test "spec10 FR-R11: write-card diff-gate stamp is touched pre-spawn, and a real write still finalizes done" {
  # Today: limits/<id>.stamp (FR-R11's "touch immediately before invoking the lane command") is
  # never created anywhere in _spawn_worker — the poll below times out (stamp file never appears)
  # and the first assertion fails. This is the RED-wave-valid form of the "control" case from the
  # build contract: a plain "FAKE_CLAUDE_WRITE_FILE set -> done normally" assertion would already
  # pass unmodified today (no diff gate exists to reject anything yet), so it wouldn't demonstrate
  # anything new — polling for the pre-spawn stamp is what actually exercises FR-R11's new plumbing.
  _write_conf "claude:opus" 4 15
  local target="$BATS_TEST_TMPDIR/r11target-ok"
  mkdir -p "$target"
  _fake FAKE_CLAUDE_DELAY 2
  _fake FAKE_CLAUDE_RESULT "wrote it for real"
  _fake FAKE_CLAUDE_WRITE_FILE "created.txt"
  _enqueue r11b "write card whose worker writes for real"
  printf '%s' "$target" > "$BUS/specs/r11b.write"

  "$RUNSH" 3>&- &
  BG_PIDS+=("$!")

  _poll 15 test -f "$BUS/limits/r11b.stamp"
  [ -f "$BUS/limits/r11b.stamp" ]

  _poll 20 test -f "$BUS/done/r11b"
  [ -f "$BUS/done/r11b" ]
  [ -f "$target/created.txt" ]

  wait "${BG_PIDS[0]}"
  BG_PIDS=()
}

@test "spec10 FR-R10: a completed kimi-pinned card accumulates real-dollar limits/kimi.spend and speedwars billing:real" {
  # Today: _kimi_spend_add doesn't exist and _finalize_worker's success branch never touches
  # limits/kimi.spend at all — the file is never created, so the existence check fails outright.
  # speed_row also emits no "billing" field today (FR-R10 in src/swarm-lib.sh not yet wired), so the
  # jq read on a missing field returns "null", never "real".
  _write_conf "claude:opus" 4 15
  printf 'MOONSHOT_API_KEY=test-kimi-key\n' > "$BATS_TEST_TMPDIR/envmaster"
  export ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster"
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-r10.jsonl"
  _fake FAKE_CLAUDE_RESULT "kimi spend check"
  _fake FAKE_CLAUDE_USAGE_JSON '{"input_tokens":100000,"output_tokens":10000,"cache_read_input_tokens":0}'
  _enqueue r10a "kimi spend accumulation check"
  echo "kimi:kimi-k3" > "$BUS/specs/r10a.lane"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/r10a" ]
  [ -f "$BUS/limits/kimi.spend" ]
  awk -v s="$(<"$BUS/limits/kimi.spend")" 'BEGIN { exit !(s > 0) }'
  # spec 12 FR-3: full_run's trailing run-summary row shares this file — select by id.
  [ "$(jq -r 'select(.id=="r10a") | .billing' "$SPEEDWARS_FILE")" = "real" ]
}

@test "spec10 FR-R13: swarm-run config prints CLASS_REVIEW members' live limited/available state" {
  # Today: _print_config_table (swarm-run.sh) prints only the existing PLAN/ORCHESTRATOR/REVIEW/
  # EXEC_CHAIN/... table — no CLASS_REVIEW line at all, and CLASS_REVIEW isn't even a conf_load key
  # yet. The regex match below finds nothing in $output and fails outright.
  _write_conf "claude:opus" 4 15
  mkdir -p "$BUS/limits"
  printf '18000' > "$BUS/limits/kimi.limited"

  run "$RUNSH" config
  [ "$status" -eq 0 ]
  [[ "$output" =~ CLASS_REVIEW:\ codex\(available\)\ kimi\(limited\ [0-9]+m\) ]]
}

@test "spec14 FR-7 regression: _flag_mins_left computes minutes-left from a new-format reason-line marker as well as a legacy bare-digit one" {
  # Before the fix, _flag_mins_left read the whole marker file as the raw TTL — a FR-7 reason line
  # ("<ISO8601> | <token> | retryable=.. | ttl=.. | text") is not all-digits, so the arithmetic
  # context `$(( ttl - ... ))` died outright ("value too great for base"), crashing `config` under
  # errexit the moment any lane carried a new-format marker.
  _write_conf "claude:opus" 4 15
  mkdir -p "$BUS/limits"
  printf '2026-01-01T00:00:00Z | session-limit | retryable=1 | ttl=3600 | lane kimi rate-limited\n' > "$BUS/limits/kimi.limited"
  printf '1800' > "$BUS/limits/codex.broken"

  run "$RUNSH" config
  [ "$status" -eq 0 ]
  [[ "$output" =~ CLASS_REVIEW:\ codex\(broken\ [0-9]+m\)\ kimi\(limited\ [0-9]+m\) ]]
}

@test "spec10 CRIT-regression: mid-flight auth-death on a chain-SEEDED card fails over without crashing the pool driver" {
  # final-reviewer CRITICAL 2026-07-24: queue/<id>.chain files carry no trailing newline
  # (printf '%s'), and _orig_chain_bare's bare `read -r < file` returned rc1 at newline-less
  # EOF — under set -e via _finalize_worker's UNGUARDED call, the whole pool driver died on the
  # first mid-flight limit/dead of a chain-seeded card, orphaning every other in-flight worker.
  # Every other FR-R2/R5/R6/R7 test pre-blocks the lane BEFORE claim; this one fails DURING.
  _write_conf "claude:opus" 4 15
  printf 'MOONSHOT_API_KEY=test-kimi-key\n' > "$BATS_TEST_TMPDIR/envmaster"
  export ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster"
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/speedwars.jsonl"
  _enqueue crm "chain-seeded card whose first lane dies mid-run"
  # No trailing newline — the exact on-disk shape swarm-loop's cmd_iterate produces.
  printf '%s' "claude:opus codex:default" > "$BUS/specs/crm.chain"
  _fake FAKE_CLAUDE_ONCE_MARKER "$BATS_TEST_TMPDIR/crm-once"
  _fake FAKE_CLAUDE_ONCE_MODE autherr
  _fake FAKE_CODEX_RESULT "codex rescued it"

  run timeout 30 "$RUNSH"
  [ "$status" -eq 0 ]                                   # driver survived — no errexit crash
  [ -f "$BUS/done/crm" ]
  [ "$(jq -r '.lane' "$BUS/done/crm")" = "codex" ]      # failed over mid-flight
  [ -f "$BUS/limits/claude.dead" ]                      # auth-death flagged
  run jq -r 'select(.id=="crm" and .outcome=="done") | .fallback_reason' "$SPEEDWARS_FILE"
  [[ "$output" == *"dead"* ]]                           # mid-flight provenance survived (FR-R9)
}

# --- backlog 28/29/30 (round3 red wave) ---
# No existing test in this file asserted the OLD FR-12 timeout contract text ("killed, flagging")
# or that a timeout ever created limits/<lane>.limited — grepped the whole file before writing
# these; nothing pre-existing needed updating for backlog-30's contract change.

@test "backlog-29: .write target inside .claude/ is refused at claim time — parks loudly, never spawns, no lane cooled" {
  _write_conf "claude:opus" 4 15
  local target="$BATS_TEST_TMPDIR/tgt/.claude/skills/foo"
  mkdir -p "$target"
  _enqueue cw1 "attempt to write into .claude"
  printf '%s' "$target" > "$BUS/specs/cw1.write"

  run timeout 20 "$RUNSH"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cw1 refused — write target '$target' is an orchestrator-owned .claude/ surface; parking"* ]]
  [ -f "$BUS/limits/cw1.parked" ]
  [ ! -e "$BUS/done/cw1" ]
  [ ! -e "$BUS/run-cw1.jsonl" ]
  [ -z "$(find "$BUS/limits" -maxdepth 1 -name '*.limited' 2>/dev/null)" ]
}

@test "backlog-29: control — a .write target containing a .claude-lookalike path component is not refused" {
  _write_conf "claude:opus" 4 15
  local target="$BATS_TEST_TMPDIR/.claudette"
  mkdir -p "$target"
  _fake FAKE_CLAUDE_RESULT "wrote it"
  _fake FAKE_CLAUDE_WRITE_FILE "created.txt"
  _fake FAKE_CLAUDE_WRITE_CONTENT "hello from worker"
  _enqueue cw2 "write into a lookalike dir"
  printf '%s' "$target" > "$BUS/specs/cw2.write"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/cw2" ]
  [ "$(<"$BUS/res-cw2.txt")" = "wrote it" ]
  [ -f "$target/created.txt" ]
  [ "$(<"$target/created.txt")" = "hello from worker" ]
}

@test "backlog-29: .write target reaching .claude/ THROUGH a symlink is refused at claim time (realpath canonicalization)" {
  # Pins the symlink-hardening arm of the claim-time refusal: the raw path 'cc' never matches the
  # literal .claude regex — only the realpath-canonicalized spelling does. Without canonicalization
  # this card would spawn a worker into an orchestrator-owned surface.
  _write_conf "claude:opus" 4 15
  local repo="$BATS_TEST_TMPDIR/symtgt"
  mkdir -p "$repo/.claude"
  ln -s .claude "$repo/cc"
  _enqueue cw3 "attempt to write into .claude through a symlink"
  printf '%s' "$repo/cc" > "$BUS/specs/cw3.write"

  run timeout 20 "$RUNSH"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cw3 refused — write target '$repo/cc' is an orchestrator-owned .claude/ surface; parking"* ]]
  [ -f "$BUS/limits/cw3.parked" ]
  [ ! -e "$BUS/done/cw3" ]
  [ ! -e "$BUS/run-cw3.jsonl" ]
}

@test "backlog-30: watchdog-killed attempt never cools the lane — no .limited flag, branch still fails over" {
  # Mirrors the FR-12 hung-worker test's 2-lane chain/knobs, but asserts the NEW contract: the
  # killed lane must come out of this with no limits/<lane>.limited (a kill-truncated stream isn't
  # limit evidence), and the stderr wording drops "flagging" for "failing over".
  _write_conf "claude:opus glm:glm-5.2" 4 15
  cat >> "$CONF" <<'EOF'
WORKER_TIMEOUT_SEC=2
EOF
  printf 'Z_AI_CODING_KEY=test-glm-key\n' > "$BATS_TEST_TMPDIR/envmaster"
  export ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster"
  _fake FAKE_CLAUDE_ONCE_MARKER "$BATS_TEST_TMPDIR/b30-once"
  _fake FAKE_CLAUDE_ONCE_MODE hang
  _enqueue b30a "branch whose claude hangs forever"

  run timeout 25 "$RUNSH"
  [ "$status" -eq 0 ]

  [ -f "$BUS/done/b30a" ]
  [ "$(jq -r '.lane' "$BUS/done/b30a")" = "glm" ]
  [ "$(<"$BUS/res-b30a.txt")" = "OK" ]
  [ ! -e "$BUS/limits/claude.limited" ]
  [[ "$output" == *"exceeded WORKER_TIMEOUT_SEC — killed, failing over"* ]]
  [[ "$output" != *"killed, flagging"* ]]
}

# --- backlog 17+10: watchdog timeout salvage (specs/01 FR-12 amendment 2026-07-25) -------------
# A SIGKILLed worker's on-disk work is salvaged FINALIZE-side: best-effort handoff extraction over
# the partial run log + the success path's own write-card diff gate. Genuine work -> done with
# outcome "timeout-salvaged"; nothing usable -> today's failover, byte-identical.

@test "backlog 17+10: a read card that answered before the watchdog kill is salvaged as done, not discarded" {
  # Today: the timeout path discards everything on disk unconditionally — the branch chain-advances
  # off the (single-lane) chain, parks, and the answer that WAS already in run-sv1.jsonl is lost.
  _write_conf "claude:opus" 4 15
  cat >> "$CONF" <<'EOF'
WORKER_TIMEOUT_SEC=2
EOF
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-sv1.jsonl"
  _fake FAKE_CLAUDE_ONCE_MARKER "$BATS_TEST_TMPDIR/sv1-once"
  _fake FAKE_CLAUDE_ONCE_MODE answerhang
  _fake FAKE_CLAUDE_SALVAGE_RESULT "answer landed before the kill"
  _enqueue sv1 "read card whose worker answers then hangs"

  run timeout 25 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/sv1" ]
  [ ! -e "$BUS/limits/sv1.parked" ]
  [ "$(<"$BUS/res-sv1.txt")" = "answer landed before the kill" ]
  [ "$(jq -r '.lane' "$BUS/done/sv1")" = "claude" ]
  # FR-2: the REAL worker rc — a SIGKILLed subtree is never 0
  [ "$(jq -r '.code' "$BUS/done/sv1")" -ne 0 ]
  [ -f "$BUS/prompt-sv1.txt" ]
  # qualified success: its own outcome, and NO failure class (absence-means-absent, like done rows)
  [ "$(jq -r 'select(.id=="sv1") | .outcome' "$SPEEDWARS_FILE")" = "timeout-salvaged" ]
  [ "$(jq -r 'select(.id=="sv1") | has("class")' "$SPEEDWARS_FILE")" = "false" ]
  # the bus is fully cleaned, exactly as on the success path — no claim, no sidecar, nothing requeued
  [ -z "$(find "$BUS/claimed" "$BUS/queue" -mindepth 1 2>/dev/null)" ]
}

@test "backlog 17+10: a timed-out partial whose answer is unusable is discarded — failover, never salvaged" {
  # The salvage gate must not resurrect an auth-death dump as an answer: extract_answer succeeds on
  # that envelope (it IS a well-formed result), answer_unusable rejects it, res is discarded and the
  # branch takes today's timeout failover to codex.
  _write_conf "claude:opus codex:default" 4 15
  cat >> "$CONF" <<'EOF'
WORKER_TIMEOUT_SEC=2
EOF
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-sv2.jsonl"
  _fake FAKE_CLAUDE_ONCE_MARKER "$BATS_TEST_TMPDIR/sv2-once"
  _fake FAKE_CLAUDE_ONCE_MODE answerhang
  _fake FAKE_CLAUDE_SALVAGE_RESULT "OAuth session expired - Please run /login"
  _fake FAKE_CODEX_RESULT "codex rescued it"
  _enqueue sv2 "read card whose partial answer is an auth-death dump"

  run timeout 25 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/sv2" ]
  [ "$(jq -r '.lane' "$BUS/done/sv2")" = "codex" ]
  [ "$(<"$BUS/res-sv2.txt")" = "codex rescued it" ]
  [ "$(jq -r 'select(.id=="sv2" and .served_lane=="claude") | .outcome' "$SPEEDWARS_FILE")" = "timeout" ]
  [ "$(jq -r 'select(.id=="sv2" and .served_lane=="claude") | .class' "$SPEEDWARS_FILE")" = "timeout-watchdog" ]
}

@test "backlog 17+10: a timed-out write card whose target changed is salvaged done with provenance archived" {
  # backlog-10's exact incident: killed during handoff with ALL work already on disk. No handoff
  # ever landed (no res file) — the diff against limits/<id>.stamp IS the evidence.
  _write_conf "claude:opus" 4 15
  cat >> "$CONF" <<'EOF'
WORKER_TIMEOUT_SEC=2
EOF
  local target="$BATS_TEST_TMPDIR/sv3target"
  mkdir -p "$target"
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-sv3.jsonl"
  _fake FAKE_CLAUDE_ONCE_MARKER "$BATS_TEST_TMPDIR/sv3-once"
  _fake FAKE_CLAUDE_ONCE_MODE hang
  _fake FAKE_CLAUDE_WRITE_FILE "created.txt"
  _fake FAKE_CLAUDE_WRITE_CONTENT "real work on disk"
  _enqueue sv3 "write card killed after its work landed"
  printf '%s' "$target" > "$BUS/specs/sv3.write"

  run timeout 25 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/sv3" ]
  [ "$(<"$target/created.txt")" = "real work on disk" ]
  [ ! -e "$BUS/res-sv3.txt" ]
  # verify-wave provenance, same as the success path archives it
  [ "$(<"$BUS/write-sv3.txt")" = "$target" ]
  [ -f "$BUS/prompt-sv3.txt" ]
  [ -f "$BUS/limits/sv3.stamp" ]
  [ ! -e "$BUS/queue/sv3.write" ]
  [ -z "$(find "$BUS/claimed" "$BUS/queue" -mindepth 1 2>/dev/null)" ]
  [ "$(jq -r 'select(.id=="sv3") | .outcome' "$SPEEDWARS_FILE")" = "timeout-salvaged" ]
}

@test "backlog 17+10: a timed-out write card whose target never changed keeps today's failover" {
  _write_conf "claude:opus" 4 15
  cat >> "$CONF" <<'EOF'
WORKER_TIMEOUT_SEC=2
EOF
  local target="$BATS_TEST_TMPDIR/sv4target"
  mkdir -p "$target"
  # pre-existing, untouched target — outside the gate's ~2s pre-spawn mtime slack
  touch -d '10 seconds ago' "$target"
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-sv4.jsonl"
  _fake FAKE_CLAUDE_ONCE_MARKER "$BATS_TEST_TMPDIR/sv4-once"
  _fake FAKE_CLAUDE_ONCE_MODE hang
  _enqueue sv4 "write card killed having written nothing"
  printf '%s' "$target" > "$BUS/specs/sv4.write"

  run timeout 25 "$RUNSH"
  [ "$status" -ne 0 ]
  [ ! -e "$BUS/done/sv4" ]
  [ -f "$BUS/limits/sv4.parked" ]
  [ "$(jq -r 'select(.id=="sv4" and .outcome=="timeout") | .class' "$SPEEDWARS_FILE")" = "timeout-watchdog" ]
}

@test "backlog 17+10: TIMEOUT_SALVAGE=0 restores today's discard-everything timeout behavior" {
  _write_conf "claude:opus" 4 15
  cat >> "$CONF" <<'EOF'
WORKER_TIMEOUT_SEC=2
EOF
  export TIMEOUT_SALVAGE=0
  _fake FAKE_CLAUDE_ONCE_MARKER "$BATS_TEST_TMPDIR/sv5-once"
  _fake FAKE_CLAUDE_ONCE_MODE answerhang
  _fake FAKE_CLAUDE_SALVAGE_RESULT "answer landed before the kill"
  _enqueue sv5 "read card whose worker answers then hangs, salvage disabled"

  run timeout 25 "$RUNSH"
  [ "$status" -ne 0 ]
  [ ! -e "$BUS/done/sv5" ]
  [ ! -e "$BUS/res-sv5.txt" ]
  [ -f "$BUS/limits/sv5.parked" ]
}

@test "backlog-28-run: success finalize archives write-card provenance — write-<id>.txt saved, limits/<id>.stamp survives" {
  _write_conf "claude:opus" 4 15
  local target="$BATS_TEST_TMPDIR/writetarget-b28"
  mkdir -p "$target"
  _fake FAKE_CLAUDE_RESULT "wrote it"
  _fake FAKE_CLAUDE_WRITE_FILE "created.txt"
  _fake FAKE_CLAUDE_WRITE_CONTENT "hello"
  _enqueue b28a "write card for provenance archive"
  printf '%s' "$target" > "$BUS/specs/b28a.write"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]

  [ -f "$BUS/done/b28a" ]
  [ -f "$BUS/write-b28a.txt" ]
  [ "$(<"$BUS/write-b28a.txt")" = "$target" ]
  [ -f "$BUS/limits/b28a.stamp" ]
  # non-repo target: the spawn-time git-baseline capture is best-effort — leaves NO .base file
  [ ! -e "$BUS/limits/b28a.base" ]
}

@test "backlog-28-run: write card on a git-repo target records pre-spawn HEAD as limits/<id>.base (diff baseline)" {
  # Today: _spawn_worker only touches limits/<id>.stamp — no .base is ever written, so
  # _write_card_diff_section falls back to deriving the baseline from commit dates. The exact
  # pre-spawn sha is the lossless form; assert the spawner records it.
  _write_conf "claude:opus" 4 15
  local target="$BATS_TEST_TMPDIR/basetgt"
  mkdir -p "$target"
  git -C "$target" init -q
  git -C "$target" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  local head; head="$(git -C "$target" rev-parse HEAD)"
  _fake FAKE_CLAUDE_RESULT "wrote it"
  _fake FAKE_CLAUDE_WRITE_FILE "created.txt"
  _enqueue gb1 "write card into a git repo"
  printf '%s' "$target" > "$BUS/specs/gb1.write"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/gb1" ]
  [ -f "$BUS/limits/gb1.base" ]
  [ "$(<"$BUS/limits/gb1.base")" = "$head" ]
}

@test "spec10 FR-R11 granularity: a write landing in the stamp's own mtime granule still finalizes done" {
  # Models a coarse-mtime fs: the fake pins its written file's AND the target dir's mtime to
  # exactly the stamp's (touch -r) — with the strictly-newer `find -newer stamp` gate, nothing in
  # the target reads as changed and a GENUINE write is false-rejected into a park. The fixed gate
  # (-newermt against stamp-epoch-minus-1s, stamp itself backdated 1s at spawn) must finalize done.
  _write_conf "claude:opus" 4 15
  local target="$BATS_TEST_TMPDIR/grantgt"
  mkdir -p "$target"
  _fake FAKE_CLAUDE_RESULT "wrote it in the same second"
  _fake FAKE_CLAUDE_WRITE_FILE "created.txt"
  _fake FAKE_CLAUDE_WRITE_TOUCH_REF "$BUS/limits/gr1.stamp"
  _enqueue gr1 "write card whose write lands in the stamp's mtime granule"
  printf '%s' "$target" > "$BUS/specs/gr1.write"

  run timeout 25 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/gr1" ]
  [ ! -e "$BUS/limits/gr1.parked" ]
  [ -f "$target/created.txt" ]
}

# --- spec 11 degraded finalize (round3 red wave) ---
# FR-S4: while $BUSDIR/orch-seat exists with a non-fable first field, every finalize record and
# speedwars row carries degraded:true; under fable (or no seat file) the key is entirely absent.
# Today: neither done/<id> nor speed_row emit a degraded field at all, and the FR-R6 pinned-park
# path never writes a speedwars parked row — so the positive-degraded assertions fail.

@test "spec11: degraded done — non-fable orch-seat stamps done record and speedwars done row" {
  # Today: finalize writes '{"id","code","lane"}' only (no degraded), and speed_row's jq object
  # has no degraded key — both `== true` checks fail even though the one-lane happy path completes.
  _write_conf "claude:opus" 4 15
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-s11-done.jsonl"
  _fake FAKE_CLAUDE_RESULT "OK"
  _enqueue s11d "degraded done under kimi seat"
  mkdir -p "$BUS"
  printf 'kimi 1753000000' > "$BUS/orch-seat"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/s11d" ]
  [ "$(jq -r '.degraded' "$BUS/done/s11d")" = "true" ]
  [ "$(jq -r 'select(.id=="s11d" and .outcome=="done") | .degraded' "$SPEEDWARS_FILE")" = "true" ]
}

@test "spec11: non-degraded control — no orch-seat omits degraded key on done and speedwars" {
  # Contract half under Fable / no seat: the key must be entirely absent (not false). Today this
  # already holds because no producer emits degraded — kept as the RED-wave control so a GREEN
  # that always stamps degraded:true is caught.
  _write_conf "claude:opus" 4 15
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-s11-ctrl.jsonl"
  _fake FAKE_CLAUDE_RESULT "OK"
  _enqueue s11c "non-degraded control, no seat file"
  [ ! -e "$BUS/orch-seat" ]

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/s11c" ]
  [ "$(jq 'has("degraded")' "$BUS/done/s11c")" = "false" ]
  [ "$(jq 'select(.id=="s11c" and .outcome=="done") | has("degraded")' "$SPEEDWARS_FILE")" = "false" ]
}

@test "spec11: degraded park — non-fable orch-seat stamps speedwars parked row" {
  # Must use a park path that actually emits a speedwars row: FR-R7 class-exhaust (chain both
  # members limited) calls speed_row with outcome=parked. The FR-R6 pinned-park path only touches
  # limits/<id>.parked and never writes SPEEDWARS_FILE — wiring SPEEDWARS_FILE there would assert
  # against a file the engine never creates (red-wave wrinkle). speed_row itself stamps degraded
  # when orch-seat is non-fable (parallel FR-S4 card); this test only needs the seat + exhaust.
  _write_conf "claude:opus" 4 15
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-s11-park.jsonl"
  _enqueue s11p "chain exhausted, degraded park"
  mkdir -p "$BUS/queue" "$BUS/limits"
  printf '%s' "codex:default kimi:kimi-k3" > "$BUS/queue/s11p.chain"
  printf '18000' > "$BUS/limits/codex.limited"
  printf '18000' > "$BUS/limits/kimi.limited"
  printf 'kimi 1753000000' > "$BUS/orch-seat"

  run timeout 20 "$RUNSH"
  [ "$status" -ne 0 ]
  [ -f "$BUS/limits/s11p.parked" ]
  [ ! -e "$BUS/done/s11p" ]
  [ "$(jq -r 'select(.id=="s11p" and .outcome=="parked") | .degraded' "$SPEEDWARS_FILE")" = "true" ]
}

# --- spec 12: failure-class vocabulary (FR-1), real done rc (FR-2), run_summary (FR-3) -----------

@test "spec12 FR-1: a timed-out worker's speedwars row carries class timeout-watchdog" {
  _write_conf "claude:opus glm:glm-5.2" 4 15
  cat >> "$CONF" <<'EOF'
WORKER_TIMEOUT_SEC=2
EOF
  printf 'Z_AI_CODING_KEY=test-glm-key\n' > "$BATS_TEST_TMPDIR/envmaster"
  export ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster"
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-c12wd.jsonl"
  _fake FAKE_CLAUDE_ONCE_MARKER "$BATS_TEST_TMPDIR/c12wd-once"
  _fake FAKE_CLAUDE_ONCE_MODE hang
  _enqueue c12wd "branch whose claude hangs forever"

  run timeout 25 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/c12wd" ]
  [ "$(jq -r 'select(.id=="c12wd" and .outcome=="timeout") | .class' "$SPEEDWARS_FILE")" = "timeout-watchdog" ]
}

@test "spec12 FR-1: a lane_cmd spawn failure (wrc==9, no usable key) speedwars row carries class spawn-fail" {
  _write_conf "glm:glm-5.2 claude:opus"
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-c12sf.jsonl"
  _enqueue c12sf "branch with no glm key"
  # spec 13 FR-1: a READABLE file simply missing glm's key (not an unreadable path — that's the
  # dedicated launch-preflight scenario now) is still this test's own intent: a normal spawn-time
  # lane_cmd failure.
  printf 'UNRELATED_KEY=x\n' > "$BATS_TEST_TMPDIR/envmaster-nk"
  export ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster-nk"
  _fake FAKE_CLAUDE_RESULT "fallback answer"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/c12sf" ]
  [ "$(jq -r 'select(.id=="c12sf" and .outcome=="lane-unusable") | .class' "$SPEEDWARS_FILE")" = "spawn-fail" ]
}

@test "spec12 FR-1: write-card diff-gate rejection rows carry class false-done" {
  _write_conf "claude:opus" 4 15
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-c12fd.jsonl"
  local target="$BATS_TEST_TMPDIR/c12fd-target"
  mkdir -p "$target"
  touch -d '10 seconds ago' "$target"
  _fake FAKE_CLAUDE_RESULT "claims done but wrote nothing"
  _enqueue c12fd "write card whose worker writes nothing"
  printf '%s' "$target" > "$BUS/specs/c12fd.write"

  run timeout 25 "$RUNSH"
  [ "$status" -ne 0 ]
  [ -f "$BUS/limits/c12fd.parked" ]
  [ -n "$(jq -r 'select(.id=="c12fd" and .class=="false-done") | .id' "$SPEEDWARS_FILE")" ]
}

@test "spec12 FR-1: a mid-flight auth-death failover row carries class auth-death; the eventual done row carries none" {
  _write_conf "claude:opus codex:default" 4 15
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-c12ad.jsonl"
  _fake FAKE_CLAUDE_ONCE_MARKER "$BATS_TEST_TMPDIR/c12ad-once"
  _fake FAKE_CLAUDE_ONCE_MODE autherr
  _fake FAKE_CODEX_RESULT "codex rescued it"
  _enqueue c12ad "claude auth-death branch"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/c12ad" ]
  [ "$(jq -r 'select(.id=="c12ad" and .served_lane=="claude") | .class' "$SPEEDWARS_FILE")" = "auth-death" ]
  [ "$(jq -r 'select(.id=="c12ad" and .outcome=="done") | has("class")' "$SPEEDWARS_FILE")" = "false" ]
}

@test "spec12 FR-1: a rate-limited (not dead) failover row carries class rate-limit" {
  _write_conf "glm:glm-5.2 claude:opus"
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-c12rl.jsonl"
  _enqueue c12rl "branch needing failover"
  printf 'Z_AI_CODING_KEY=test-glm-key\n' > "$BATS_TEST_TMPDIR/envmaster"
  export ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster"
  _fake FAKE_CLAUDE_ONCE_MARKER "$BATS_TEST_TMPDIR/c12rl-once"
  _fake FAKE_CLAUDE_ONCE_MODE limit
  _fake FAKE_CLAUDE_LIMIT_CODE 1308
  _fake FAKE_CLAUDE_NEXT_FLUSH "$(( $(date +%s) + 500 ))"
  _fake FAKE_CLAUDE_RESULT "claude answer"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/c12rl" ]
  [ "$(jq -r 'select(.id=="c12rl" and .served_lane=="glm") | .class' "$SPEEDWARS_FILE")" = "rate-limit" ]
}

@test "spec12 FR-1: a chain-exhausted parked row carries class parked-env" {
  _write_conf "claude:opus" 4 15
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-c12pk.jsonl"
  _enqueue c12pk "chain exhausted"
  mkdir -p "$BUS/queue" "$BUS/limits"
  printf '%s' "codex:default kimi:kimi-k3" > "$BUS/queue/c12pk.chain"
  printf '18000' > "$BUS/limits/codex.limited"
  printf '18000' > "$BUS/limits/kimi.limited"

  run timeout 20 "$RUNSH"
  [ "$status" -ne 0 ]
  [ -f "$BUS/limits/c12pk.parked" ]
  [ "$(jq -r 'select(.id=="c12pk" and .outcome=="parked") | .class' "$SPEEDWARS_FILE")" = "parked-env" ]
}

@test "spec12 FR-2: done/<id>'s code field carries the real worker rc, not hardcoded 0" {
  _write_conf "claude:opus" 4 15
  _fake FAKE_CLAUDE_RESULT "OK but nonzero exit"
  _fake FAKE_CLAUDE_EXIT 3
  _enqueue c12rc "worker exits nonzero after a valid envelope"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/c12rc" ]
  [ "$(jq -r '.code' "$BUS/done/c12rc")" = "3" ]
}

@test "spec12 FR-3/FR-5: full_run appends a run-summary row last; _check_parked's rc still governs the run's exit status" {
  _write_conf "claude:opus" 4 15
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-c12fr.jsonl" SPEEDWARS_RUN="c12-fr"
  _fake FAKE_CLAUDE_RESULT "OK"
  _enqueue c12d1 "branch one"
  _enqueue c12d2 "branch two"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/c12d1" ]; [ -f "$BUS/done/c12d2" ]

  local last; last="$(tail -n1 "$SPEEDWARS_FILE")"
  [ "$(jq -r '.type' <<<"$last")" = "run-summary" ]
  [ "$(jq -r '.run' <<<"$last")" = "c12-fr" ]
  [ "$(jq -r '.mode' <<<"$last")" = "full" ]
  [ "$(jq -r '.done_n' <<<"$last")" = "2" ]
}

# --- F11: a FAILing skill-drift row must not decapitate doctor --------------------------------
# `doctor` documents itself as "purely diagnostic; never fatal, always exits 0" — under set -e an
# unguarded FAILing helper broke that contract AND, because cmd_doctor_live opens by calling
# cmd_doctor, aborted `doctor --live` before a single probe ran.


@test "F11 doctor: a FAILing skill-drift row still prints and doctor still exits 0" {
  _plant_drifted_skill
  run "$RUNSH" doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"skill-drift  FAIL"* ]]
  [[ "$output" == *"not a symlink"* ]]
  # the row is the LAST thing doctor prints — proof it did not abort mid-report either
  [[ "$output" == *"bus fs"* ]]
}

@test "F11 doctor --live: a FAILing skill-drift row does not decapitate the probe section" {
  _plant_drifted_skill
  export LEDGER_FILE="$BATS_TEST_TMPDIR/doctor-f11-ledger.md"
  run "$RUNSH" doctor --live
  [[ "$output" == *"skill-drift  FAIL"* ]]
  [[ "$output" == *"doctor --live (auth probes)"* ]]
  [[ "$output" == *"probe       claude"* ]]
  [[ "$output" == *"probe       kimi"* ]]
}

# --- spec 13 FR-2: doctor --live -----------------------------------------------------------------

@test "doctor: plain (no --live) makes zero network calls — fake curl never invoked, always exits 0" {
  export FAKE_CURL_CALLED_FILE="$BATS_TEST_TMPDIR/curl-called"
  run "$RUNSH" doctor
  [ "$status" -eq 0 ]
  [ ! -e "$FAKE_CURL_CALLED_FILE" ]
  [[ "$output" != *"doctor --live"* ]]
}

@test "doctor --live: all six lanes PASS by default (fakes healthy, env-master fully keyed) — exits 0, one ledger row per lane" {
  export LEDGER_FILE="$BATS_TEST_TMPDIR/doctor-ledger.md"
  run "$RUNSH" doctor --live
  [ "$status" -eq 0 ]
  for lane in claude codex gemini grok glm kimi; do
    [[ "$output" == *"probe       $lane"*"PASS"* ]]
    grep -q "doctor-probe ($lane)" "$LEDGER_FILE"
  done
}

@test "doctor --live: a glm curl HTTP failure prints FAIL with the HTTP code, exits nonzero, writes limits/glm.broken when a busdir exists" {
  export LEDGER_FILE="$BATS_TEST_TMPDIR/doctor-ledger2.md"
  export FAKE_CURL_HTTP_CODE=401
  bus_init_probe() { bash -c "source '$BATS_TEST_DIRNAME/../src/swarm-lib.sh'; bus_init '$1'"; }
  bus_init_probe "$BUS"

  run "$RUNSH" doctor --live
  [ "$status" -ne 0 ]
  [[ "$output" == *"probe       glm"*"FAIL HTTP 401"* ]]
  [ -f "$BUS/limits/glm.broken" ]
  grep -q "doctor-probe (glm)" "$LEDGER_FILE"
}

@test "doctor --live: a kimi curl network failure (rc!=0) prints FAIL with the curl rc, exits nonzero" {
  export LEDGER_FILE="$BATS_TEST_TMPDIR/doctor-ledger3.md"
  export FAKE_CURL_RC=28
  run "$RUNSH" doctor --live
  [ "$status" -ne 0 ]
  [[ "$output" == *"probe       kimi"*"FAIL curl rc 28"* ]]
}

@test "doctor --live: a missing env-master key for gemini prints FAIL naming the missing key, no curl invoked for that lane" {
  export LEDGER_FILE="$BATS_TEST_TMPDIR/doctor-ledger4.md"
  export FAKE_CURL_CALLED_FILE="$BATS_TEST_TMPDIR/curl-called2"
  export ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster-no-gemini"
  printf 'Z_AI_CODING_KEY=k\nMOONSHOT_API_KEY=k\n' > "$ENV_MASTER_FILE"
  run "$RUNSH" doctor --live
  [ "$status" -ne 0 ]
  [[ "$output" == *"probe       gemini"*"FAIL no GEMINI_API_KEY"* ]]
  ! grep -q "generativelanguage" "$FAKE_CURL_CALLED_FILE" 2>/dev/null
}

@test "doctor --live: claude CLI probe exiting nonzero (dead OAuth session) prints FAIL with the exit code" {
  # Deliberately NOT testing 'CLI missing from PATH' here: this box's real PATH (appended after
  # $BIN) has a real claude/codex/grok binary further down, so removing the fake from $BIN would
  # NOT actually hide the CLI from `command -v` — it would fall through to invoking the REAL CLI,
  # which this suite must never do. Exercise the sibling FAIL path (CLI runs, exits nonzero)
  # instead — same "FAIL <reason>" contract, network-free either way.
  export LEDGER_FILE="$BATS_TEST_TMPDIR/doctor-ledger5.md"
  _fake FAKE_CLAUDE_EXIT 1
  run "$RUNSH" doctor --live
  [ "$status" -ne 0 ]
  [[ "$output" == *"probe       claude"*"FAIL exit 1"* ]]
}

@test "doctor --live: PASS latency is reported in ms" {
  export LEDGER_FILE="$BATS_TEST_TMPDIR/doctor-ledger6.md"
  run "$RUNSH" doctor --live
  [ "$status" -eq 0 ]
  [[ "$output" =~ probe\ +claude\ +PASS\ [0-9]+ms ]]
}

# --- spec 17 FR-5: doctor --plugin (plan-004 P1-FR5) -------------------------------------------
# $HOME is already the throwaway "$BATS_TEST_TMPDIR/realhome" from setup() above — every account
# dir/settings.json planted below lives under THAT fake tree, never the real ~/.claude*.
# $RUNSH is invoked as a real subprocess (never sourced), so $SCRIPT_DIR inside it resolves to the
# REAL checkout under test — plugin.json/marketplace.json/SKILL.md are this repo's real, valid
# files, so the manifest/marketplace/skill-version checks exercise real content, not fixtures.

@test "doctor --plugin: manifest/marketplace/UNIMATRIX_HOME/skill-version all PASS against the real repo; no accounts -> notes none found, drift table is green" {
  run "$RUNSH" doctor --plugin
  [ "$status" -eq 0 ]
  [[ "$output" == *"=== unimatrix doctor --plugin ==="* ]]
  [[ "$output" == *"manifest    plugin.json"*"PASS"* ]]
  [[ "$output" == *"manifest    marketplace.json"*"PASS"* ]]
  [[ "$output" == *"marketplace resolves"*"PASS"* ]]
  [[ "$output" == *"UNIMATRIX_HOME resolves"*"PASS"* ]]
  [[ "$output" == *"skill-version"*"PASS"* ]]
  [[ "$output" != *"WARNING: plugin.json version"* ]]
  [[ "$output" == *"no accounts found"* ]]
  [[ "$output" == *"install-drift: GREEN"* ]]
}

@test "doctor --plugin: no cached copy anywhere is an informational row, not a failure" {
  run "$RUNSH" doctor --plugin
  [ "$status" -eq 0 ]
  [[ "$output" == *"cache        -          -          INFO"* ]]
  [[ "$output" == *"install-drift: GREEN"* ]]
}

@test "doctor --plugin: a stale cached plugin.json (real install/enable copy, not the marketplace source) is a red cache row, rc still 0" {
  local mkt_name plugin_name
  mkt_name="$(jq -r '.name' "$BATS_TEST_DIRNAME/../.claude-plugin/marketplace.json")"
  plugin_name="$(jq -r '.name' "$BATS_TEST_DIRNAME/../plugin/.claude-plugin/plugin.json")"
  local cache="$HOME/.claude/plugins/cache/$mkt_name/$plugin_name/9.9.9"
  mkdir -p "$cache/.claude-plugin"
  printf '{"name":"%s","version":"0.0.1-stale"}\n' "$plugin_name" > "$cache/.claude-plugin/plugin.json"

  run "$RUNSH" doctor --plugin
  [ "$status" -eq 0 ]
  [[ "$output" == *"cache:9.9.9"*"FAIL"*"(plugin.json (cache))"* ]]
  [[ "$output" == *"install-drift: RED"* ]]
}

@test "doctor --plugin: a cached copy that matches the repo (plugin.json + every command) is all-PASS" {
  local mkt_name plugin_name repo_root
  repo_root="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  mkt_name="$(jq -r '.name' "$repo_root/.claude-plugin/marketplace.json")"
  plugin_name="$(jq -r '.name' "$repo_root/plugin/.claude-plugin/plugin.json")"
  local cache="$HOME/.claude/plugins/cache/$mkt_name/$plugin_name/1.1.0"
  mkdir -p "$cache/.claude-plugin" "$cache/commands"
  cp "$repo_root/plugin/.claude-plugin/plugin.json" "$cache/.claude-plugin/plugin.json"
  cp "$repo_root/plugin/commands/"*.md "$cache/commands/"

  run "$RUNSH" doctor --plugin
  [ "$status" -eq 0 ]
  [[ "$output" == *"cache:1.1.0"*"PASS"*"(plugin.json (cache))"* ]]
  [[ "$output" == *"cache:1.1.0"*"PASS"*"(commands (cache))"* ]]
}

@test "doctor --plugin: install-drift PASS row when an account's settings.json points its marketplace at this checkout" {
  local repo_root; repo_root="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  mkdir -p "$HOME/.claude-acct/goodacct"
  jq -n --arg p "$repo_root" \
    '{extraKnownMarketplaces:{unimatrix:{source:{source:"directory",path:$p}}},enabledPlugins:{"u@unimatrix":true}}' \
    > "$HOME/.claude-acct/goodacct/settings.json"

  run "$RUNSH" doctor --plugin
  [ "$status" -eq 0 ]
  [[ "$output" == *"goodacct"*"PASS"*"(plugin)"* ]]
  [[ "$output" == *"install-drift: GREEN"* ]]
}

@test "doctor --plugin: install-drift table is RED on a planted mismatch, naming the drifted account" {
  local stale="$BATS_TEST_TMPDIR/stale-marketplace"
  mkdir -p "$stale/.claude-plugin"
  echo '{"name":"u","version":"0.0.1-drifted"}' > "$stale/.claude-plugin/plugin.json"

  mkdir -p "$HOME/.claude-acct/staleacct"
  jq -n --arg p "$stale" \
    '{extraKnownMarketplaces:{unimatrix:{source:{source:"directory",path:$p}}},enabledPlugins:{"u@unimatrix":true}}' \
    > "$HOME/.claude-acct/staleacct/settings.json"

  run "$RUNSH" doctor --plugin
  [ "$status" -eq 0 ]
  [[ "$output" == *"staleacct"*"FAIL"*"(plugin)"* ]]
  [[ "$output" == *"install-drift: RED"* ]]
}

@test "doctor --plugin: an account with no marketplace entry falls back to the skill-copy surface; SKIP when no copy exists" {
  mkdir -p "$HOME/.claude-acct/noplugin"
  echo '{}' > "$HOME/.claude-acct/noplugin/settings.json"

  run "$RUNSH" doctor --plugin
  [ "$status" -eq 0 ]
  [[ "$output" == *"noplugin"*"SKIP"*"(skill not installed)"* ]]
}

@test "doctor --plugin: never fatal — a doctor invocation with no --plugin flag is unaffected" {
  run "$RUNSH" doctor
  [ "$status" -eq 0 ]
  [[ "$output" != *"doctor --plugin"* ]]
  [[ "$output" != *"install-drift"* ]]
}
