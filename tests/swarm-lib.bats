#!/usr/bin/env bats
# Unit tests for src/swarm-lib.sh: bus primitives, config precedence, per-lane invocation
# (lane_cmd), answer normalization (extract_answer), rate-limit detection (limit_error), and
# per-id EXEC_CHAIN position tracking (chain_current/advance/reset).
#
# Project: unimatrix — multi-model swarm orchestrator driven from Claude Code
# Module:  tests/swarm-lib.bats
# Deps:    bats-core, src/swarm-lib.sh
# Tested:  n/a — this is the test file (fixtures live under $BATS_TEST_TMPDIR, docs/02-build-pitfalls.md §9)

setup() {
  LIB="$BATS_TEST_DIRNAME/../src/swarm-lib.sh"
  # shellcheck source=/dev/null
  source "$LIB"
  BUS="$BATS_TEST_TMPDIR/bus"
  # _scratch_home reads $HOME/.claude, $HOME/.codex — never let a test touch the real user's
  # actual credentials; every test in this file gets its own throwaway "real" home instead.
  export HOME="$BATS_TEST_TMPDIR/realhome"
  mkdir -p "$HOME"
  # _scratch_home also honors CLAUDE_CONFIG_DIR (multi-account setups) — this box's own ambient
  # session sets it to a REAL account dir, which would otherwise leak real credentials into a
  # test's throwaway scratch home. Unset here; tests that want to exercise the override set it
  # explicitly to their own fixture.
  unset CLAUDE_CONFIG_DIR
}

teardown() {
  # kill+wait any stray backgrounded pids this test file may have left running
  [ -n "${PIDA:-}" ] && kill "$PIDA" 2>/dev/null; [ -n "${PIDA:-}" ] && wait "$PIDA" 2>/dev/null
  [ -n "${PIDB:-}" ] && kill "$PIDB" 2>/dev/null; [ -n "${PIDB:-}" ] && wait "$PIDB" 2>/dev/null
  return 0
}

# --- bus_init ---------------------------------------------------------------

@test "bus_init: creates the full bus directory tree" {
  bus_init "$BUS"
  for d in specs queue claimed done cancelled limits pids; do
    [ -d "$BUS/$d" ]
  done
}

# --- conf_load precedence: env > file > default -----------------------------

@test "conf_load: baked default wins when unset and no file" {
  unset FANOUT
  conf_load "$BATS_TEST_TMPDIR/nonexistent.conf"
  [ "$FANOUT" = "4" ]
}

@test "conf_load: EXEC_CHAIN default is the two-lane fallback chain" {
  unset EXEC_CHAIN
  conf_load "$BATS_TEST_TMPDIR/nonexistent.conf"
  [ "$EXEC_CHAIN" = "claude:haiku codex:default" ]
}

@test "conf_load: WORKER_TIMEOUT_SEC default is 300 (FR-12)" {
  unset WORKER_TIMEOUT_SEC
  conf_load "$BATS_TEST_TMPDIR/nonexistent.conf"
  [ "$WORKER_TIMEOUT_SEC" = "300" ]
}

@test "conf_load: VERIFY_MAP default is the cross-model rotation (Phase E step 4)" {
  unset VERIFY_MAP
  conf_load "$BATS_TEST_TMPDIR/nonexistent.conf"
  [ "$VERIFY_MAP" = "claude:codex codex:kimi gemini:claude glm:codex grok:codex kimi:codex" ]
}

@test "conf_load: LEDGER_AUTO default is 1 (Phase E step 4)" {
  unset LEDGER_AUTO
  conf_load "$BATS_TEST_TMPDIR/nonexistent.conf"
  [ "$LEDGER_AUTO" = "1" ]
}

@test "conf_load: GEMINI_SANDBOX default is empty/off (FR-16)" {
  unset GEMINI_SANDBOX
  conf_load "$BATS_TEST_TMPDIR/nonexistent.conf"
  [ "${GEMINI_SANDBOX:-}" = "" ]
}

@test "conf_load: GEMINI_SANDBOX file value overrides the default" {
  unset GEMINI_SANDBOX
  echo 'GEMINI_SANDBOX=docker' > "$BATS_TEST_TMPDIR/swarm.conf"
  conf_load "$BATS_TEST_TMPDIR/swarm.conf"
  [ "$GEMINI_SANDBOX" = "docker" ]
}

@test "conf_load: file value overrides baked default" {
  unset FANOUT
  echo 'FANOUT=8' > "$BATS_TEST_TMPDIR/swarm.conf"
  conf_load "$BATS_TEST_TMPDIR/swarm.conf"
  [ "$FANOUT" = "8" ]
}

@test "conf_load: pre-set env overrides file value" {
  echo 'FANOUT=8' > "$BATS_TEST_TMPDIR/swarm.conf"
  export FANOUT=99
  conf_load "$BATS_TEST_TMPDIR/swarm.conf"
  [ "$FANOUT" = "99" ]
}

@test "conf_load: resolves independently per key (mixed env/file/default)" {
  unset ORCHESTRATOR REVIEW
  echo 'REVIEW=codex:gpt-5.6' > "$BATS_TEST_TMPDIR/swarm.conf"
  export MAX_ITERATIONS=3
  conf_load "$BATS_TEST_TMPDIR/swarm.conf"
  [ "$MAX_ITERATIONS" = "3" ]       # env wins
  [ "$REVIEW" = "codex:gpt-5.6" ]  # file wins
  [ "$ORCHESTRATOR" = "fable" ]     # default wins
}

# --- backlog-31: GLM_MAX_THINKING_TOKENS/KIMI_MAX_THINKING_TOKENS/GROK_EFFORT are conf_load keys --
# Root cause: these three were deliberately excluded from `keys` (see swarm.conf.example's old
# comment) so they'd be settable as bare env vars — but excluded from `keys` also means excluded
# from the env-capture-before-source / re-overlay-after-source dance, so a swarm.conf file value
# silently clobbered an already-set env override (backwards from FR-1's env > file > default), and
# the value was never `export`ed for a subprocess boundary (swarm-loop.sh's fork of swarm-run.sh).
# lane_cmd itself was never the bug (its `${VAR:-6000}`-style substitution happens in-process,
# before any fork, so a same-process spawn always saw a sourced conf value) — these tests pin the
# now-correct precedence/export contract, matching every other conf_load key.

@test "backlog-31: conf_load defaults GLM_MAX_THINKING_TOKENS/KIMI_MAX_THINKING_TOKENS/GROK_EFFORT with no conf file" {
  unset GLM_MAX_THINKING_TOKENS KIMI_MAX_THINKING_TOKENS GROK_EFFORT
  conf_load "$BATS_TEST_TMPDIR/nonexistent.conf"
  [ "$GLM_MAX_THINKING_TOKENS" = "6000" ]
  [ "$KIMI_MAX_THINKING_TOKENS" = "6000" ]
  [ "$GROK_EFFORT" = "medium" ]
}

@test "backlog-31: conf_load env override wins over a conflicting swarm.conf GLM_MAX_THINKING_TOKENS value (FR-1)" {
  echo 'GLM_MAX_THINKING_TOKENS=6000' > "$BATS_TEST_TMPDIR/swarm.conf"
  export GLM_MAX_THINKING_TOKENS=1500
  conf_load "$BATS_TEST_TMPDIR/swarm.conf"
  [ "$GLM_MAX_THINKING_TOKENS" = "1500" ]
}

@test "backlog-31: conf_load env override wins over a conflicting swarm.conf KIMI_MAX_THINKING_TOKENS value (FR-1)" {
  echo 'KIMI_MAX_THINKING_TOKENS=6000' > "$BATS_TEST_TMPDIR/swarm.conf"
  export KIMI_MAX_THINKING_TOKENS=2500
  conf_load "$BATS_TEST_TMPDIR/swarm.conf"
  [ "$KIMI_MAX_THINKING_TOKENS" = "2500" ]
}

@test "backlog-31: conf_load file value overrides the GROK_EFFORT baked default" {
  unset GROK_EFFORT
  echo 'GROK_EFFORT=high' > "$BATS_TEST_TMPDIR/swarm.conf"
  conf_load "$BATS_TEST_TMPDIR/swarm.conf"
  [ "$GROK_EFFORT" = "high" ]
}

@test "backlog-31: conf_load exports GLM_MAX_THINKING_TOKENS/KIMI_MAX_THINKING_TOKENS/GROK_EFFORT — reaches a real subprocess" {
  unset GLM_MAX_THINKING_TOKENS KIMI_MAX_THINKING_TOKENS GROK_EFFORT
  conf_load "$BATS_TEST_TMPDIR/nonexistent.conf"
  [ "$(bash -c 'echo "$GLM_MAX_THINKING_TOKENS"')" = "6000" ]
  [ "$(bash -c 'echo "$KIMI_MAX_THINKING_TOKENS"')" = "6000" ]
  [ "$(bash -c 'echo "$GROK_EFFORT"')" = "medium" ]
}

# --- claim: atomic, race-free -------------------------------------------------

@test "claim: moves queue/<id>.prompt to claimed/<id>.<worker>" {
  bus_init "$BUS"
  echo "do the thing" > "$BUS/queue/abc123.prompt"
  run claim "$BUS" abc123 workerA
  [ "$status" -eq 0 ]
  [ -f "$BUS/claimed/abc123.workerA" ]
  [ ! -f "$BUS/queue/abc123.prompt" ]
}

@test "claim: a sequential loser returns 1 without duplicating the claim" {
  bus_init "$BUS"
  echo "x" > "$BUS/queue/dup1.prompt"
  claim "$BUS" dup1 winner
  run claim "$BUS" dup1 loser
  [ "$status" -eq 1 ]
  [ ! -f "$BUS/claimed/dup1.loser" ]
  [ -f "$BUS/claimed/dup1.winner" ]
}

@test "claim: two true-concurrent claimers — exactly one wins" {
  bus_init "$BUS"
  echo "x" > "$BUS/queue/race1.prompt"

  ( set +e; claim "$BUS" race1 workerA; echo $? > "$BATS_TEST_TMPDIR/rcA" ) 3>&- &
  PIDA=$!
  ( set +e; claim "$BUS" race1 workerB; echo $? > "$BATS_TEST_TMPDIR/rcB" ) 3>&- &
  PIDB=$!
  wait "$PIDA"
  wait "$PIDB"

  rcA="$(cat "$BATS_TEST_TMPDIR/rcA")"
  rcB="$(cat "$BATS_TEST_TMPDIR/rcB")"
  winners=0
  [ "$rcA" -eq 0 ] && winners=$((winners + 1))
  [ "$rcB" -eq 0 ] && winners=$((winners + 1))
  [ "$winners" -eq 1 ]

  count="$(find "$BUS/claimed" -maxdepth 1 -type f | wc -l)"
  [ "$count" -eq 1 ]
}

@test "claim: refuses while .bus/PAUSE exists (rc=2), spec untouched" {
  bus_init "$BUS"
  echo "x" > "$BUS/queue/paused1.prompt"
  touch "$BUS/PAUSE"
  run claim "$BUS" paused1 workerA
  [ "$status" -eq 2 ]
  [ -f "$BUS/queue/paused1.prompt" ]
  [ ! -f "$BUS/claimed/paused1.workerA" ]
}

# --- heartbeat / reap ---------------------------------------------------------

@test "heartbeat: touches the claim file's mtime" {
  bus_init "$BUS"
  echo "x" > "$BUS/queue/hb1.prompt"
  claim "$BUS" hb1 workerA
  touch -d "-1 hour" "$BUS/claimed/hb1.workerA"
  old="$(stat -c %Y "$BUS/claimed/hb1.workerA")"
  heartbeat "$BUS" hb1 workerA
  new="$(stat -c %Y "$BUS/claimed/hb1.workerA")"
  [ "$new" -gt "$old" ]
}

@test "reap: requeues only claims whose heartbeat is older than the TTL" {
  bus_init "$BUS"
  echo "x" > "$BUS/queue/stale1.prompt"
  echo "y" > "$BUS/queue/fresh1.prompt"
  claim "$BUS" stale1 workerA
  claim "$BUS" fresh1 workerB
  touch -d "-20 minutes" "$BUS/claimed/stale1.workerA"

  reap "$BUS" 15

  [ -f "$BUS/queue/stale1.prompt" ]
  [ ! -f "$BUS/claimed/stale1.workerA" ]
  [ -f "$BUS/claimed/fresh1.workerB" ]
  [ ! -f "$BUS/queue/fresh1.prompt" ]
}

@test "reap: requeues to the exact id when the worker token itself contains dots" {
  bus_init "$BUS"
  echo "x" > "$BUS/queue/b1.prompt"
  claim "$BUS" b1 glm-5.2
  touch -d "-20 minutes" "$BUS/claimed/b1.glm-5.2"

  reap "$BUS" 15

  [ -f "$BUS/queue/b1.prompt" ]
  [ ! -e "$BUS/claimed/b1.glm-5.2" ]
}

# --- reap FR-A: liveness guard + hard age cap (spec 01 Amendment 2026-07-25, backlog 55) --------
# Every test below sets WORKER_TIMEOUT_SEC explicitly so the age cap (2x the resolved per-lane
# timeout) is under the test's own control instead of drifting with the 300s baked default.

@test "reap FR-A: stale claim + live pid -> not reaped" {
  bus_init "$BUS"
  export WORKER_TIMEOUT_SEC=3600   # age cap 7200s, well past this test's 8-minute stale mtime
  echo "x" > "$BUS/queue/live1.prompt"
  claim "$BUS" live1 codex:default
  touch -d "-8 minutes" "$BUS/claimed/live1.codex:default"
  sleep 60 &
  PIDA=$!
  echo "$PIDA" > "$BUS/pids/live1"

  reap "$BUS" 5

  [ -f "$BUS/claimed/live1.codex:default" ]
  [ ! -f "$BUS/queue/live1.prompt" ]
}

@test "reap FR-A: stale claim + run log fresher than ttl_min -> not reaped (no pid registry at all)" {
  bus_init "$BUS"
  export WORKER_TIMEOUT_SEC=3600
  echo "x" > "$BUS/queue/freshlog1.prompt"
  claim "$BUS" freshlog1 codex:default
  touch -d "-8 minutes" "$BUS/claimed/freshlog1.codex:default"
  : > "$BUS/run-freshlog1.jsonl"   # fresh mtime (just created)

  reap "$BUS" 5

  [ -f "$BUS/claimed/freshlog1.codex:default" ]
  [ ! -f "$BUS/queue/freshlog1.prompt" ]
}

@test "reap FR-A: dead pid + stale run log -> requeued (today's behavior)" {
  bus_init "$BUS"
  export WORKER_TIMEOUT_SEC=3600
  echo "x" > "$BUS/queue/dead1.prompt"
  claim "$BUS" dead1 codex:default
  touch -d "-8 minutes" "$BUS/claimed/dead1.codex:default"
  echo 999999 > "$BUS/pids/dead1"   # not a real pid on this box -- kill -0 fails
  : > "$BUS/run-dead1.jsonl"
  touch -d "-30 minutes" "$BUS/run-dead1.jsonl"

  reap "$BUS" 5

  [ ! -f "$BUS/claimed/dead1.codex:default" ]
  [ -f "$BUS/queue/dead1.prompt" ]
}

@test "reap FR-A: missing pids/<id> and no run log at all -> requeued (vacuous pass)" {
  bus_init "$BUS"
  export WORKER_TIMEOUT_SEC=3600
  echo "x" > "$BUS/queue/nopid1.prompt"
  claim "$BUS" nopid1 codex:default
  touch -d "-8 minutes" "$BUS/claimed/nopid1.codex:default"

  reap "$BUS" 5

  [ ! -f "$BUS/claimed/nopid1.codex:default" ]
  [ -f "$BUS/queue/nopid1.prompt" ]
}

@test "reap FR-A: missing run log (dead pid present) -> requeued" {
  bus_init "$BUS"
  export WORKER_TIMEOUT_SEC=3600
  echo "x" > "$BUS/queue/norun1.prompt"
  claim "$BUS" norun1 codex:default
  touch -d "-8 minutes" "$BUS/claimed/norun1.codex:default"
  echo 999999 > "$BUS/pids/norun1"

  reap "$BUS" 5

  [ ! -f "$BUS/claimed/norun1.codex:default" ]
  [ -f "$BUS/queue/norun1.prompt" ]
}

@test "reap FR-A: claim older than the age cap is reaped even with a live pid (pid-reuse case)" {
  bus_init "$BUS"
  export WORKER_TIMEOUT_SEC=60   # age cap = 120s
  echo "x" > "$BUS/queue/agecap1.prompt"
  claim "$BUS" agecap1 codex:default
  touch -d "-10 minutes" "$BUS/claimed/agecap1.codex:default"   # 600s stale > 120s age cap
  sleep 60 &
  PIDA=$!
  echo "$PIDA" > "$BUS/pids/agecap1"

  reap "$BUS" 5

  [ ! -f "$BUS/claimed/agecap1.codex:default" ]
  [ -f "$BUS/queue/agecap1.prompt" ]
}

@test "reap FR-A: age cap resolves TIMEOUT_<LANE> over WORKER_TIMEOUT_SEC" {
  bus_init "$BUS"
  export WORKER_TIMEOUT_SEC=3600   # would give a 7200s age cap if the lane override were ignored
  export TIMEOUT_CODEX=60          # age cap = 120s for the codex lane specifically
  echo "x" > "$BUS/queue/lanecap1.prompt"
  claim "$BUS" lanecap1 codex:default
  touch -d "-10 minutes" "$BUS/claimed/lanecap1.codex:default"

  reap "$BUS" 5

  [ ! -f "$BUS/claimed/lanecap1.codex:default" ]
  [ -f "$BUS/queue/lanecap1.prompt" ]
}

@test "reap FR-A: age cap is measured PAST the lease (cross-review fix) — at shipped defaults a live pid inside the 1500s window survives, past it doesn't" {
  # Regression for the cross-review finding: with the old `age_cap = resolved*2` formula (600s at
  # WORKER_TIMEOUT_SEC=300), find's own `-mmin +15` floor means the YOUNGEST claim this loop ever
  # sees is already 900s stale — past the old 600s cap before any pid/log check ran, so the
  # liveness checks were unreachable dead code at shipped defaults. The fixed formula adds the
  # lease term: cap = ttl_min*60 + resolved*2 = 15*60 + 300*2 = 1500s.
  bus_init "$BUS"
  export WORKER_TIMEOUT_SEC=300
  echo "x" > "$BUS/queue/defcap1.prompt"
  claim "$BUS" defcap1 codex:default
  touch -d "-1000 seconds" "$BUS/claimed/defcap1.codex:default"   # > 900s lease floor, < 1500s cap
  sleep 60 & PIDA=$!
  echo "$PIDA" > "$BUS/pids/defcap1"

  echo "x" > "$BUS/queue/defcap2.prompt"
  claim "$BUS" defcap2 codex:default
  touch -d "-1600 seconds" "$BUS/claimed/defcap2.codex:default"   # > 1500s cap
  sleep 60 & PIDB=$!
  echo "$PIDB" > "$BUS/pids/defcap2"

  reap "$BUS" 15

  [ -f "$BUS/claimed/defcap1.codex:default" ]      # inside the cap, live pid -> survives
  [ ! -f "$BUS/queue/defcap1.prompt" ]
  [ ! -f "$BUS/claimed/defcap2.codex:default" ]     # past the cap -> reaped despite the live pid
  [ -f "$BUS/queue/defcap2.prompt" ]
}

@test "reap FR-A: emits a mover=reap stderr line naming the id on every actual requeue" {
  bus_init "$BUS"
  echo "x" > "$BUS/queue/moverline1.prompt"
  claim "$BUS" moverline1 codex:default
  touch -d "-20 minutes" "$BUS/claimed/moverline1.codex:default"

  run reap "$BUS" 15

  [ "$status" -eq 0 ]
  [[ "$output" == *"mover=reap"* ]]
  [[ "$output" == *"moverline1"* ]]
}

@test "reap FR-A: heartbeat -c never recreates an already-released claim file" {
  bus_init "$BUS"
  echo "x" > "$BUS/queue/relb1.prompt"
  claim "$BUS" relb1 workerA
  rm -f "$BUS/claimed/relb1.workerA"   # simulate: reap already released this claim

  heartbeat "$BUS" relb1 workerA

  [ ! -e "$BUS/claimed/relb1.workerA" ]
  count="$(find "$BUS/claimed" -maxdepth 1 -type f | wc -l)"
  [ "$count" -eq 0 ]
}

@test "reap FR-A: a claim file that vanishes between find's snapshot and the stat call does not abort the whole reap" {
  # cross-review fix: reap races other movers by design (a concurrent swarm-ctl kill/cancel can
  # remove a claim between find's snapshot and this loop's stat). Without `|| true` on the mtime
  # assignment, the FIRST such failure aborts the whole reap under errexit and any later claim in
  # the same pass is never even considered. Force every _stat_mtime call to fail, as it would for a
  # vanished file, and assert reap still finishes and still processes every claim.
  bus_init "$BUS"
  echo "x" > "$BUS/queue/gone1.prompt"; claim "$BUS" gone1 codex:default
  touch -d "-20 minutes" "$BUS/claimed/gone1.codex:default"
  echo "x" > "$BUS/queue/gone2.prompt"; claim "$BUS" gone2 codex:default
  touch -d "-20 minutes" "$BUS/claimed/gone2.codex:default"

  # shellcheck disable=SC2317  # invoked indirectly by reap, not called directly in this test body
  _stat_mtime() { return 1; }

  run reap "$BUS" 15

  [ "$status" -eq 0 ]
  [ -f "$BUS/queue/gone1.prompt" ]
  [ -f "$BUS/queue/gone2.prompt" ]
}

# --- gate_count ------------------------------------------------------------

@test "gate_count: live excludes cancelled, includes added (spec-01 acceptance case)" {
  bus_init "$BUS"
  for id in a b c d; do echo "x" > "$BUS/queue/$id.prompt"; done
  mv "$BUS/queue/d.prompt" "$BUS/cancelled/d.prompt"   # cancelled — excluded from live
  claim "$BUS" a workerA
  mv "$BUS/claimed/a.workerA" "$BUS/done/a"             # a completes
  echo "x" > "$BUS/queue/e.prompt"                      # added mid-run

  read -r done_n live_n < <(gate_count "$BUS")
  [ "$done_n" -eq 1 ]
  [ "$live_n" -eq 4 ]
}

@test "gate_count: a pinned branch's <id>.lane sidecar in queue/ does NOT double-count it as 2 live units" {
  # FR-2b pins a branch by dropping BOTH <id>.prompt and <id>.lane into queue/ — two FILES, one
  # live unit of work. Root cause of a real bug (found live, Phase E step 4 FR-7 addendum): a
  # parked pinned branch never gets its sidecar cleaned up (that only happens on SUCCESS), so
  # counting raw files inflated live_n forever and the done+parked>=live gate could never close.
  bus_init "$BUS"
  echo "x" > "$BUS/queue/p1.prompt"
  echo "glm:glm-5.2" > "$BUS/queue/p1.lane"

  read -r done_n live_n < <(gate_count "$BUS")
  [ "$done_n" -eq 0 ]
  [ "$live_n" -eq 1 ]
}

# --- limit_flag / limit_active ----------------------------------------------

@test "limit_active: no flag file means not active" {
  bus_init "$BUS"
  run limit_active "$BUS" codex
  [ "$status" -eq 1 ]
}

@test "limit_flag / limit_active: active within TTL, expired once aged past it" {
  bus_init "$BUS"
  limit_flag "$BUS" glm 100
  run limit_active "$BUS" glm
  [ "$status" -eq 0 ]

  touch -d "-200 seconds" "$BUS/limits/glm.limited"
  run limit_active "$BUS" glm
  [ "$status" -eq 1 ]
}

# --- jq_firehose_filter -------------------------------------------------------

@test "jq_firehose_filter: echoes the defensive fromjson guard and every known type" {
  run jq_firehose_filter
  [ "$status" -eq 0 ]
  [[ "$output" == *"fromjson?"* ]]
  for t in tool_use tool_result result error message assistant system turn.completed turn.failed item.completed text end; do
    [[ "$output" == *"$t"* ]]
  done
}

@test "jq_firehose_filter: passes grok's text/end events and still drops thought (token-chunk spam)" {
  prog="$(jq_firehose_filter)"
  run bash -c "printf '%s\n' '{\"type\":\"text\",\"data\":\"hi\"}' '{\"type\":\"end\",\"stopReason\":\"EndTurn\"}' '{\"type\":\"thought\",\"data\":\"thinking\"}' | jq -R -c '$prog'"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"type":"text"'* ]]
  [[ "$output" == *'"type":"end"'* ]]
  [[ "$output" != *'"type":"thought"'* ]]
}

@test "jq_firehose_filter: is valid jq that tolerates non-JSON and filters unknown types" {
  prog="$(jq_firehose_filter)"
  run bash -c "printf '%s\n' '{\"type\":\"result\",\"result\":\"ok\"}' 'not json' '{\"type\":\"nope\"}' | jq -R -c '$prog'"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"type":"result"'* ]]
  [[ "$output" != *'"type":"nope"'* ]]
}

@test "jq_firehose_filter: passes claude-lane assistant and system event types" {
  prog="$(jq_firehose_filter)"
  run bash -c "printf '%s\n' '{\"type\":\"assistant\",\"message\":{}}' '{\"type\":\"system\",\"subtype\":\"init\"}' | jq -R -c '$prog'"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"type":"assistant"'* ]]
  [[ "$output" == *'"type":"system"'* ]]
}

@test "jq_firehose_filter: LOCKSTEP — exactly matches the canonical program documented in bus-discipline.md" {
  local doc="$BATS_TEST_DIRNAME/../rules/unimatrix/bus-discipline.md"
  local doc_prog
  doc_prog="$(grep '^  fromjson? ' "$doc" | sed 's/^  //')"
  [ -n "$doc_prog" ]
  [ "$doc_prog" = "$(jq_firehose_filter)" ]
}

# --- kill_subtree --------------------------------------------------------------
# Shared by the FR-12 watchdog, the FR-13 driver-death sweep, and swarm-ctl kill.

@test "kill_subtree: kills a process and its backgrounded child" {
  bash -c '
    sleep 9999 &
    echo $! > "'"$BATS_TEST_TMPDIR"'/child.pid"
    echo $$ > "'"$BATS_TEST_TMPDIR"'/parent.pid"
    wait
  ' 3>&- &
  PIDA=$!

  for _ in $(seq 1 30); do [ -s "$BATS_TEST_TMPDIR/child.pid" ] && break; sleep 0.1; done
  parent="$(<"$BATS_TEST_TMPDIR/parent.pid")"
  child="$(<"$BATS_TEST_TMPDIR/child.pid")"

  kill_subtree "$parent" TERM
  for _ in $(seq 1 30); do kill -0 "$parent" 2>/dev/null || break; sleep 0.1; done

  run kill -0 "$parent"
  [ "$status" -ne 0 ]
  run kill -0 "$child"
  [ "$status" -ne 0 ]
}

@test "kill_subtree: a pid with no descendants is just killed, no error" {
  sleep 9999 3>&- &
  PIDA=$!
  run kill_subtree "$PIDA" TERM
  [ "$status" -eq 0 ]
  for _ in $(seq 1 30); do kill -0 "$PIDA" 2>/dev/null || break; sleep 0.1; done
  run kill -0 "$PIDA"
  [ "$status" -ne 0 ]
}

# --- _scratch_home ---------------------------------------------------------------

@test "_scratch_home: claude/codex copy in only their one needed credential file" {
  bus_init "$BUS"
  mkdir -p "$HOME/.claude" "$HOME/.codex" "$HOME/s"
  echo '{"token":"real-session"}' > "$HOME/.claude/.credentials.json"
  echo '{"cfg":true}' > "$HOME/.claude.json"
  echo '{"key":"real-codex-auth"}' > "$HOME/.codex/auth.json"
  echo "SECRET=leak" > "$HOME/s/.env.master"

  claude_home="$(_scratch_home "$BUS" claude)"
  [ "$claude_home" = "$BUS/home/claude" ]
  [ "$(<"$claude_home/.claude/.credentials.json")" = '{"token":"real-session"}' ]
  [ "$(<"$claude_home/.claude.json")" = '{"cfg":true}' ]
  [ ! -e "$claude_home/s" ]

  codex_home="$(_scratch_home "$BUS" codex)"
  [ "$(<"$codex_home/.codex/auth.json")" = '{"key":"real-codex-auth"}' ]
}

@test "_scratch_home: claude sources credentials from CLAUDE_CONFIG_DIR when set, not \$HOME/.claude (multi-account)" {
  bus_init "$BUS"
  mkdir -p "$HOME/.claude"
  echo '{"token":"wrong-account"}' > "$HOME/.claude/.credentials.json"
  local cfgdir="$BATS_TEST_TMPDIR/altconfig"
  mkdir -p "$cfgdir"
  echo '{"token":"right-account"}' > "$cfgdir/.credentials.json"

  claude_home="$(CLAUDE_CONFIG_DIR="$cfgdir" _scratch_home "$BUS" claude)"
  [ "$(<"$claude_home/.claude/.credentials.json")" = '{"token":"right-account"}' ]
}

@test "_scratch_home: grok copies ONLY auth.json — never config.toml or trusted_folders.toml" {
  # config.toml wires MCP servers, trusted_folders.toml is probe-proven unnecessary (a caged run
  # in an untrusted dir succeeded) — neither belongs in a least-privilege scratch HOME.
  bus_init "$BUS"
  mkdir -p "$HOME/.grok"
  echo '{"token":"real-grok-oauth"}' > "$HOME/.grok/auth.json"
  chmod 644 "$HOME/.grok/auth.json"
  echo '[mcp_servers]' > "$HOME/.grok/config.toml"
  echo 'trusted=true' > "$HOME/.grok/trusted_folders.toml"
  # simulate stale state left behind by a prior spawn reusing this same scratch home
  mkdir -p "$BUS/home/grok/.grok"
  echo 'stale' > "$BUS/home/grok/.grok/config.toml"

  grok_home="$(_scratch_home "$BUS" grok)"
  [ "$grok_home" = "$BUS/home/grok" ]
  [ "$(<"$grok_home/.grok/auth.json")" = '{"token":"real-grok-oauth"}' ]
  [ ! -e "$grok_home/.grok/config.toml" ]
  [ ! -e "$grok_home/.grok/trusted_folders.toml" ]
  [ "$(stat -c %a "$grok_home/.grok/auth.json")" = "600" ]
}

@test "_scratch_home: gemini/glm get a bare empty scratch home" {
  bus_init "$BUS"
  mkdir -p "$HOME/.claude"
  echo secret > "$HOME/.claude/.credentials.json"

  gemini_home="$(_scratch_home "$BUS" gemini)"
  [ -z "$(ls -A "$gemini_home" 2>/dev/null)" ]
  glm_home="$(_scratch_home "$BUS" glm)"
  [ -z "$(ls -A "$glm_home" 2>/dev/null)" ]
}

@test "_scratch_home: kimi gets a bare empty scratch home" {
  bus_init "$BUS"
  mkdir -p "$HOME/.claude"
  echo secret > "$HOME/.claude/.credentials.json"

  kimi_home="$(_scratch_home "$BUS" kimi)"
  [ -z "$(ls -A "$kimi_home" 2>/dev/null)" ]
}

# --- lane_cmd ----------------------------------------------------------------
# lane_cmd populates the global LANE_ARGV array with the exact exec argv for a lane:model
# token (specs/01-swarm-core.md "Lane invocations"). The claim step has already moved the
# prompt file to claimed/<id>.<lane:model>, which is where lane_cmd reads it from.

_claim_prompt() {
  local worker="$1" id="$2" text="$3"
  mkdir -p "$BUS/claimed"
  printf '%s' "$text" > "$BUS/claimed/$id.$worker"
}

@test "lane_cmd: claude lane — env -i'd, scratch HOME, no key injection" {
  bus_init "$BUS"
  _claim_prompt "claude:opus" c1 "hello claude"
  lane_cmd "claude:opus" c1 "$BUS"
  [ "${LANE_ARGV[0]}" = "env" ]
  [ "${LANE_ARGV[1]}" = "-i" ]
  expected="env -i PATH=$PATH HOME=$BUS/home/claude.c1 LANG=${LANG:-C.UTF-8} claude -p --output-format stream-json --verbose --model opus hello claude"
  [ "${LANE_ARGV[*]}" = "$expected" ]
}

@test "lane_cmd: codex lane — env -i baseline, --ephemeral, --output-last-message, omits -m for 'default'" {
  bus_init "$BUS"
  _claim_prompt "codex:default" c2 "hello codex"
  lane_cmd "codex:default" c2 "$BUS"
  [ "${LANE_ARGV[0]}" = "env" ]
  [[ " ${LANE_ARGV[*]} " == *" HOME=$BUS/home/codex.c2 "* ]]
  [[ " ${LANE_ARGV[*]} " == *" codex exec --json "* ]]
  [[ " ${LANE_ARGV[*]} " == *" --output-last-message $BUS/res-c2.txt "* ]]
  [[ " ${LANE_ARGV[*]} " == *" --ephemeral "* ]]
  [[ " ${LANE_ARGV[*]} " != *" -m "* ]]
  [[ "${LANE_ARGV[*]}" == *"hello codex" ]]
}

@test "lane_cmd: codex lane — explicit model includes -m" {
  bus_init "$BUS"
  _claim_prompt "codex:gpt-5.6" c3 "x"
  lane_cmd "codex:gpt-5.6" c3 "$BUS"
  [[ " ${LANE_ARGV[*]} " == *" -m gpt-5.6 "* ]]
}

@test "lane_cmd: gemini lane — env -i'd, scratch HOME, trust flag + explicit model + key from env-master, NO --sandbox" {
  # Live E2E finding 2026-07-08: --sandbox re-execs gemini inside a container whose own env
  # allowlist doesn't include GEMINI_CLI_TRUST_WORKSPACE — every attempt exited 55. Dropped.
  bus_init "$BUS"
  _claim_prompt "gemini:gemini-3-flash" g1 "hello gemini"
  printf 'GEMINI_API_KEY=test-gem-key\n' > "$BATS_TEST_TMPDIR/envmaster"
  ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster" lane_cmd "gemini:gemini-3-flash" g1 "$BUS"
  # cwd hardened to the empty scratch HOME (-C) so a prompt-injected web page can't read the caller's repo (GNU env form)
  expected="env -i -C $BUS/home/gemini.g1 PATH=$PATH HOME=$BUS/home/gemini.g1 LANG=${LANG:-C.UTF-8} GEMINI_CLI_TRUST_WORKSPACE=true GEMINI_API_KEY=test-gem-key gemini -m gemini-3-flash -o stream-json -p hello gemini"
  [ "${LANE_ARGV[*]}" = "$expected" ]
  [[ "${LANE_ARGV[*]}" != *"--sandbox"* ]]
}

@test "lane_cmd: gemini lane fails loudly when the key is missing from env-master" {
  bus_init "$BUS"
  _claim_prompt "gemini:gemini-3-flash" g2 "x"
  ENV_MASTER_FILE="$BATS_TEST_TMPDIR/nope" run lane_cmd "gemini:gemini-3-flash" g2 "$BUS"
  [ "$status" -ne 0 ]
  [[ "$output" == *"GEMINI_API_KEY"* ]]
}

# --- FR-16: opt-in containerized gemini lane (GEMINI_SANDBOX=docker) -----------

@test "lane_cmd: gemini lane — GEMINI_SANDBOX unset/off is identical to today's argv, no docker" {
  bus_init "$BUS"
  _claim_prompt "gemini:gemini-3-flash" gs0 "hello gemini"
  printf 'GEMINI_API_KEY=test-gem-key\n' > "$BATS_TEST_TMPDIR/envmaster"
  unset GEMINI_SANDBOX
  ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster" lane_cmd "gemini:gemini-3-flash" gs0 "$BUS"
  expected="env -i -C $BUS/home/gemini.gs0 PATH=$PATH HOME=$BUS/home/gemini.gs0 LANG=${LANG:-C.UTF-8} GEMINI_CLI_TRUST_WORKSPACE=true GEMINI_API_KEY=test-gem-key gemini -m gemini-3-flash -o stream-json -p hello gemini"
  [ "${LANE_ARGV[*]}" = "$expected" ]
  [[ "${LANE_ARGV[*]}" != *"docker"* ]]
}

@test "lane_cmd: gemini lane — GEMINI_SANDBOX=docker wraps in 'docker run --rm -i', exact -e allowlist, zero -v/--mount, pinned image, gemini argv preserved after the image" {
  bus_init "$BUS"
  _claim_prompt "gemini:gemini-3-flash" gs1 "hello gemini"
  printf 'GEMINI_API_KEY=test-gem-key\n' > "$BATS_TEST_TMPDIR/envmaster"
  GEMINI_SANDBOX=docker ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster" lane_cmd "gemini:gemini-3-flash" gs1 "$BUS"
  # key set in the caged docker-client env; forwarded with a BARE `-e NAME` (never `-e NAME=value`)
  # so the plaintext key stays out of docker's argv / /proc/<pid>/cmdline.
  expected="env -i PATH=$PATH HOME=$BUS/home/gemini.gs1 LANG=${LANG:-C.UTF-8} GEMINI_API_KEY=test-gem-key GEMINI_CLI_TRUST_WORKSPACE=true docker run --rm -i -e GEMINI_API_KEY -e GEMINI_CLI_TRUST_WORKSPACE unimatrix-gemini-lane:0.49.0 gemini -m gemini-3-flash -o stream-json -p hello gemini"
  [ "${LANE_ARGV[*]}" = "$expected" ]
  # the key VALUE must not appear as a `-e KEY=value` docker CLI arg (it may appear once as the
  # caged env assignment before `docker`, but never after it in docker's own argv)
  [[ "${LANE_ARGV[*]}" != *"-e GEMINI_API_KEY=test-gem-key"* ]]
  [[ "${LANE_ARGV[*]}" != *" -v "* ]]
  [[ "${LANE_ARGV[*]}" != *"--mount"* ]]
}

@test "lane_cmd: gemini lane — write sidecar still refuses loudly with GEMINI_SANDBOX=docker (FR-15 fires before any sandbox logic, no docker invocation)" {
  bus_init "$BUS"
  _claim_prompt "gemini:gemini-3-flash" gsw1 "x"
  printf 'GEMINI_API_KEY=test-gem-key\n' > "$BATS_TEST_TMPDIR/envmaster"
  mkdir -p "$BUS/queue"
  printf '%s' "$BATS_TEST_TMPDIR/target5" > "$BUS/queue/gsw1.write"
  GEMINI_SANDBOX=docker ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster" run lane_cmd "gemini:gemini-3-flash" gsw1 "$BUS"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a write-capable lane"* ]]
  [[ "$output" != *"docker"* ]]
}

@test "lane_cmd: gemini lane — GEMINI_SANDBOX=docker with no docker binary on PATH is a loud failure, never a silent unsandboxed fallback" {
  bus_init "$BUS"
  _claim_prompt "gemini:gemini-3-flash" gsd1 "x"
  printf 'GEMINI_API_KEY=test-gem-key\n' > "$BATS_TEST_TMPDIR/envmaster"
  local nodocker="$BATS_TEST_TMPDIR/nodocker-bin"
  mkdir -p "$nodocker"
  local tool
  for tool in mkdir grep cut; do ln -s "$(command -v "$tool")" "$nodocker/$tool"; done
  GEMINI_SANDBOX=docker ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster" PATH="$nodocker" \
    run lane_cmd "gemini:gemini-3-flash" gsd1 "$BUS"
  [ "$status" -ne 0 ]
  [[ "$output" == *"docker"* ]]
  [[ "$output" != *"gemini -m"* ]]
}

@test "lane_cmd: glm lane — env -i'd child-env contract, never leaks ANTHROPIC_API_KEY" {
  bus_init "$BUS"
  _claim_prompt "glm:glm-5.2" m1 "hello glm"
  printf 'Z_AI_CODING_KEY=test-glm-key\n' > "$BATS_TEST_TMPDIR/envmaster"
  ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster" lane_cmd "glm:glm-5.2" m1 "$BUS"
  expected="env -i PATH=$PATH HOME=$BUS/home/glm.m1 LANG=${LANG:-C.UTF-8} ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic ANTHROPIC_AUTH_TOKEN=test-glm-key ANTHROPIC_DEFAULT_HAIKU_MODEL=glm-5.2 ANTHROPIC_DEFAULT_SONNET_MODEL=glm-5.2 ANTHROPIC_DEFAULT_OPUS_MODEL=glm-5.2 API_TIMEOUT_MS=3000000 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 MAX_THINKING_TOKENS=${GLM_MAX_THINKING_TOKENS:-6000} claude -p --output-format stream-json --verbose hello glm"
  [ "${LANE_ARGV[*]}" = "$expected" ]
  [[ "${LANE_ARGV[*]}" != *"ANTHROPIC_API_KEY="* ]]
}

@test "lane_cmd: glm lane — ALL THREE tier envs match the pinned model, not hardcoded per-tier (live E2E finding: glm-4.7 pin was served by glm-5.2)" {
  bus_init "$BUS"
  _claim_prompt "glm:glm-4.7" m3 "x"
  printf 'Z_AI_CODING_KEY=test-glm-key\n' > "$BATS_TEST_TMPDIR/envmaster"
  ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster" lane_cmd "glm:glm-4.7" m3 "$BUS"
  [[ " ${LANE_ARGV[*]} " == *" ANTHROPIC_DEFAULT_HAIKU_MODEL=glm-4.7 "* ]]
  [[ " ${LANE_ARGV[*]} " == *" ANTHROPIC_DEFAULT_SONNET_MODEL=glm-4.7 "* ]]
  [[ " ${LANE_ARGV[*]} " == *" ANTHROPIC_DEFAULT_OPUS_MODEL=glm-4.7 "* ]]
}

@test "lane_cmd: glm lane fails loudly when Z_AI_CODING_KEY is missing (FR-11)" {
  bus_init "$BUS"
  _claim_prompt "glm:glm-5.2" m2 "x"
  ENV_MASTER_FILE="$BATS_TEST_TMPDIR/nope" run lane_cmd "glm:glm-5.2" m2 "$BUS"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Z_AI_CODING_KEY"* ]]
}

@test "backlog-31: lane_cmd glm — MAX_THINKING_TOKENS lands in LANE_ARGV under a fresh env (no conf_load call, inline lane_cmd fallback)" {
  bus_init "$BUS"
  _claim_prompt "glm:glm-5.2" tt1 "x"
  printf 'Z_AI_CODING_KEY=test-glm-key\n' > "$BATS_TEST_TMPDIR/envmaster"
  unset GLM_MAX_THINKING_TOKENS
  ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster" lane_cmd "glm:glm-5.2" tt1 "$BUS"
  [[ " ${LANE_ARGV[*]} " == *" MAX_THINKING_TOKENS=6000 "* ]]
}

@test "backlog-31: lane_cmd glm — a conf_load-resolved GLM_MAX_THINKING_TOKENS value threads through to LANE_ARGV" {
  bus_init "$BUS"
  _claim_prompt "glm:glm-5.2" tt2 "x"
  printf 'Z_AI_CODING_KEY=test-glm-key\n' > "$BATS_TEST_TMPDIR/envmaster"
  unset GLM_MAX_THINKING_TOKENS
  echo 'GLM_MAX_THINKING_TOKENS=1500' > "$BATS_TEST_TMPDIR/swarm.conf"
  conf_load "$BATS_TEST_TMPDIR/swarm.conf"
  ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster" lane_cmd "glm:glm-5.2" tt2 "$BUS"
  [[ " ${LANE_ARGV[*]} " == *" MAX_THINKING_TOKENS=1500 "* ]]
}

@test "backlog-31: lane_cmd kimi — MAX_THINKING_TOKENS lands in LANE_ARGV under a fresh env (no conf_load call, inline lane_cmd fallback)" {
  bus_init "$BUS"
  _claim_prompt "kimi:kimi-k3" tt3 "x"
  printf 'MOONSHOT_API_KEY=test-kimi-key\n' > "$BATS_TEST_TMPDIR/envmaster"
  unset KIMI_MAX_THINKING_TOKENS
  ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster" lane_cmd "kimi:kimi-k3" tt3 "$BUS"
  [[ " ${LANE_ARGV[*]} " == *" MAX_THINKING_TOKENS=6000 "* ]]
}

@test "backlog-31: lane_cmd kimi — a conf_load-resolved KIMI_MAX_THINKING_TOKENS value threads through to LANE_ARGV" {
  bus_init "$BUS"
  _claim_prompt "kimi:kimi-k3" tt4 "x"
  printf 'MOONSHOT_API_KEY=test-kimi-key\n' > "$BATS_TEST_TMPDIR/envmaster"
  unset KIMI_MAX_THINKING_TOKENS
  echo 'KIMI_MAX_THINKING_TOKENS=2500' > "$BATS_TEST_TMPDIR/swarm.conf"
  conf_load "$BATS_TEST_TMPDIR/swarm.conf"
  ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster" lane_cmd "kimi:kimi-k3" tt4 "$BUS"
  [[ " ${LANE_ARGV[*]} " == *" MAX_THINKING_TOKENS=2500 "* ]]
}

@test "lane_cmd: fable is plan/orchestrator only — hard error if ever asked to spawn it" {
  bus_init "$BUS"
  _claim_prompt "fable:x" f1 "x"
  run lane_cmd "fable:x" f1 "$BUS"
  [ "$status" -eq 1 ]
  [[ "$output" == *"fable"* ]]
  [[ "$output" == *"never spawned"* ]]
}

@test "lane_cmd: unknown lane token is a hard error" {
  bus_init "$BUS"
  _claim_prompt "carrierpigeon:x" p1 "x"
  run lane_cmd "carrierpigeon:x" p1 "$BUS"
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown lane"* ]]
}

# --- FR-15: write sidecar (.bus/queue/<id>.write) -------------------------------
# Mirrors the .lane sidecar's own lifecycle: a plain file that sits in queue/ for the whole
# claim, read here by id alone. Absent -> read-only, exactly as before FR-15.

@test "lane_cmd: claude lane — write sidecar adds -C <target> + --permission-mode acceptEdits, never --dangerously-skip-permissions" {
  bus_init "$BUS"
  _claim_prompt "claude:opus" cw1 "write something"
  mkdir -p "$BUS/queue"
  printf '%s' "$BATS_TEST_TMPDIR/target1" > "$BUS/queue/cw1.write"
  lane_cmd "claude:opus" cw1 "$BUS"
  expected="env -i -C $BATS_TEST_TMPDIR/target1 PATH=$PATH HOME=$BUS/home/claude.cw1 LANG=${LANG:-C.UTF-8} claude -p --output-format stream-json --verbose --model opus --permission-mode acceptEdits write something"
  [ "${LANE_ARGV[*]}" = "$expected" ]
  [[ "${LANE_ARGV[*]}" != *"--dangerously-skip-permissions"* ]]
}

@test "lane_cmd: claude lane — no write sidecar means no -C, no --permission-mode (unchanged read-only behavior)" {
  bus_init "$BUS"
  _claim_prompt "claude:opus" cw0 "read only"
  lane_cmd "claude:opus" cw0 "$BUS"
  [[ "${LANE_ARGV[*]}" != *" -C "* ]]
  [[ "${LANE_ARGV[*]}" != *"--permission-mode"* ]]
}

@test "lane_cmd: codex lane — write sidecar uses the write target for -C instead of the busdir parent" {
  bus_init "$BUS"
  _claim_prompt "codex:default" cw2 "hello"
  printf '%s' "$BATS_TEST_TMPDIR/target2" > "$BUS/queue/cw2.write"
  lane_cmd "codex:default" cw2 "$BUS"
  expected="env -i -C $BATS_TEST_TMPDIR/target2 PATH=$PATH HOME=$BUS/home/codex.cw2 LANG=${LANG:-C.UTF-8} codex exec --json --output-last-message $BUS/res-cw2.txt -s workspace-write --skip-git-repo-check -C $BATS_TEST_TMPDIR/target2 --ephemeral hello"
  [ "${LANE_ARGV[*]}" = "$expected" ]
}

# backlog-32 (MAJOR containment): a plain codex card (no .write sidecar) must run under codex's
# native read-only sandbox — never workspace-write against the busdir parent. Asserted on the
# argv the codex binary actually RECEIVES (PATH-shim fake records "$*"), not just LANE_ARGV.
_codex_argv_shim() {
  local shimbin="$BATS_TEST_TMPDIR/shimbin"
  mkdir -p "$shimbin"
  printf '#!/usr/bin/env bash\nprintf "%%s" "$*" > %q\n' "$BATS_TEST_TMPDIR/codex.argv" \
    > "$shimbin/codex"
  chmod +x "$shimbin/codex"
  printf '%s' "$shimbin"
}

@test "backlog-32: codex lane — plain card spawns with -s read-only, never workspace-write (recorded argv)" {
  bus_init "$BUS"
  local shimbin; shimbin="$(_codex_argv_shim)"
  _claim_prompt "codex:default" b32a "plain read card"
  PATH="$shimbin:$PATH" lane_cmd "codex:default" b32a "$BUS"
  "${LANE_ARGV[@]}"
  local argv; argv="$(<"$BATS_TEST_TMPDIR/codex.argv")"
  [[ " $argv " == *" -s read-only "* ]]
  [[ "$argv" != *"workspace-write"* ]]
}

@test "backlog-32: codex lane — write sidecar keeps -s workspace-write -C <target> unchanged (recorded argv)" {
  bus_init "$BUS"
  local shimbin; shimbin="$(_codex_argv_shim)"
  local target="$BATS_TEST_TMPDIR/target-b32"
  mkdir -p "$target"
  _claim_prompt "codex:default" b32b "write card"
  printf '%s' "$target" > "$BUS/queue/b32b.write"
  PATH="$shimbin:$PATH" lane_cmd "codex:default" b32b "$BUS"
  "${LANE_ARGV[@]}"
  local argv; argv="$(<"$BATS_TEST_TMPDIR/codex.argv")"
  [[ " $argv " == *" -s workspace-write "* ]]
  [[ " $argv " == *" -C $target "* ]]
  [[ "$argv" != *"read-only"* ]]
}

@test "lane_cmd: gemini lane refuses loudly when a write sidecar is present (not a write-capable lane in v1)" {
  bus_init "$BUS"
  _claim_prompt "gemini:gemini-3-flash" gw1 "x"
  printf 'GEMINI_API_KEY=test-gem-key\n' > "$BATS_TEST_TMPDIR/envmaster"
  printf '%s' "$BATS_TEST_TMPDIR/target3" > "$BUS/queue/gw1.write"
  ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster" run lane_cmd "gemini:gemini-3-flash" gw1 "$BUS"
  [ "$status" -ne 0 ]
  [[ "$output" == *"gemini"* ]]
  [[ "$output" == *"not a write-capable lane"* ]]
}

@test "lane_cmd: glm lane — write sidecar adds -C <target> + --permission-mode acceptEdits (same claude binary underneath)" {
  bus_init "$BUS"
  _claim_prompt "glm:glm-5.2" gmw1 "x"
  printf 'Z_AI_CODING_KEY=test-glm-key\n' > "$BATS_TEST_TMPDIR/envmaster"
  printf '%s' "$BATS_TEST_TMPDIR/target4" > "$BUS/queue/gmw1.write"
  ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster" lane_cmd "glm:glm-5.2" gmw1 "$BUS"
  [[ " ${LANE_ARGV[*]} " == *" -C $BATS_TEST_TMPDIR/target4 "* ]]
  [[ " ${LANE_ARGV[*]} " == *" --permission-mode acceptEdits "* ]]
  [[ "${LANE_ARGV[*]}" != *"ANTHROPIC_API_KEY="* ]]
}

# --- grok lane (xAI Grok Build CLI, OAuth file auth) ---------------------------

@test "lane_cmd: grok lane — env -i'd, scratch HOME, streaming-json, read-only tool allowlist, no-subagents, explicit model" {
  bus_init "$BUS"
  _claim_prompt "grok:grok-4.5" gk1 "hello grok"
  lane_cmd "grok:grok-4.5" gk1 "$BUS"
  expected="env -i PATH=$PATH HOME=$BUS/home/grok.gk1 LANG=${LANG:-C.UTF-8} grok -p hello grok --output-format streaming-json --no-auto-update --effort medium --tools read_file,grep,list_dir --no-subagents -m grok-4.5"
  [ "${LANE_ARGV[*]}" = "$expected" ]
}

@test "lane_cmd: grok lane — model 'default' omits -m (grok's own default is correct)" {
  bus_init "$BUS"
  _claim_prompt "grok:default" gk2 "x"
  lane_cmd "grok:default" gk2 "$BUS"
  [[ " ${LANE_ARGV[*]} " != *" -m "* ]]
  [[ "${LANE_ARGV[*]}" == *"--no-subagents"* ]]
}

@test "lane_cmd: grok lane — write sidecar drops the tool allowlist, adds --allow Write/Edit/Create (NOT acceptEdits — cancels under scratch HOME), never --yolo/bypassPermissions/always-approve" {
  bus_init "$BUS"
  _claim_prompt "grok:grok-4.5" gkw1 "write something"
  mkdir -p "$BUS/queue"
  printf '%s' "$BATS_TEST_TMPDIR/targetgrok" > "$BUS/queue/gkw1.write"
  lane_cmd "grok:grok-4.5" gkw1 "$BUS"
  expected="env -i -C $BATS_TEST_TMPDIR/targetgrok PATH=$PATH HOME=$BUS/home/grok.gkw1 LANG=${LANG:-C.UTF-8} grok -p write something --output-format streaming-json --no-auto-update --effort medium --allow Write --allow Edit --allow Create -m grok-4.5"
  [ "${LANE_ARGV[*]}" = "$expected" ]
  [[ "${LANE_ARGV[*]}" != *"acceptEdits"* ]]
  [[ "${LANE_ARGV[*]}" != *"--tools"* ]]
  [[ "${LANE_ARGV[*]}" != *"--no-subagents"* ]]
  [[ "${LANE_ARGV[*]}" != *"--yolo"* ]]
  [[ "${LANE_ARGV[*]}" != *"bypassPermissions"* ]]
  [[ "${LANE_ARGV[*]}" != *"always-approve"* ]]
}

# --- kimi lane (Moonshot AI, Anthropic-compatible endpoint — rides the claude binary) -----------

@test "lane_cmd: kimi lane — env -i'd Moonshot child-env contract, never leaks ANTHROPIC_API_KEY, carries thinking cap" {
  bus_init "$BUS"
  _claim_prompt "kimi:kimi-k3" k1 "hello kimi"
  printf 'MOONSHOT_API_KEY=test-kimi-key\n' > "$BATS_TEST_TMPDIR/envmaster"
  ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster" lane_cmd "kimi:kimi-k3" k1 "$BUS"
  expected="env -i PATH=$PATH HOME=$BUS/home/kimi.k1 LANG=${LANG:-C.UTF-8} ANTHROPIC_BASE_URL=https://api.moonshot.ai/anthropic ANTHROPIC_AUTH_TOKEN=test-kimi-key ANTHROPIC_DEFAULT_HAIKU_MODEL=kimi-k3 ANTHROPIC_DEFAULT_SONNET_MODEL=kimi-k3 ANTHROPIC_DEFAULT_OPUS_MODEL=kimi-k3 API_TIMEOUT_MS=3000000 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 MAX_THINKING_TOKENS=6000 claude -p --output-format stream-json --verbose hello kimi"
  [ "${LANE_ARGV[*]}" = "$expected" ]
  [[ "${LANE_ARGV[*]}" != *"ANTHROPIC_API_KEY="* ]]
  [[ " ${LANE_ARGV[*]} " == *" MAX_THINKING_TOKENS=6000 "* ]]
}

@test "lane_cmd: kimi lane — all three tier envs match the pinned model (kimi-k2.7-code)" {
  bus_init "$BUS"
  _claim_prompt "kimi:kimi-k2.7-code" k3 "x"
  printf 'MOONSHOT_API_KEY=test-kimi-key\n' > "$BATS_TEST_TMPDIR/envmaster"
  ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster" lane_cmd "kimi:kimi-k2.7-code" k3 "$BUS"
  [[ " ${LANE_ARGV[*]} " == *" ANTHROPIC_DEFAULT_HAIKU_MODEL=kimi-k2.7-code "* ]]
  [[ " ${LANE_ARGV[*]} " == *" ANTHROPIC_DEFAULT_SONNET_MODEL=kimi-k2.7-code "* ]]
  [[ " ${LANE_ARGV[*]} " == *" ANTHROPIC_DEFAULT_OPUS_MODEL=kimi-k2.7-code "* ]]
}

@test "lane_cmd: kimi lane fails loudly when MOONSHOT_API_KEY missing" {
  bus_init "$BUS"
  _claim_prompt "kimi:kimi-k3" k4 "x"
  ENV_MASTER_FILE="$BATS_TEST_TMPDIR/nope" run lane_cmd "kimi:kimi-k3" k4 "$BUS"
  [ "$status" -eq 1 ]
  [[ "$output" == *"MOONSHOT_API_KEY"* ]]
}

@test "lane_cmd: kimi lane — write sidecar adds -C <target> + --permission-mode acceptEdits" {
  bus_init "$BUS"
  _claim_prompt "kimi:kimi-k3" kw1 "x"
  printf 'MOONSHOT_API_KEY=test-kimi-key\n' > "$BATS_TEST_TMPDIR/envmaster"
  printf '%s' "$BATS_TEST_TMPDIR/targetkimi" > "$BUS/queue/kw1.write"
  ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster" lane_cmd "kimi:kimi-k3" kw1 "$BUS"
  [[ " ${LANE_ARGV[*]} " == *" -C $BATS_TEST_TMPDIR/targetkimi "* ]]
  [[ " ${LANE_ARGV[*]} " == *" --permission-mode acceptEdits "* ]]
  [[ "${LANE_ARGV[*]}" != *"ANTHROPIC_API_KEY="* ]]
}

# --- extract_answer ------------------------------------------------------------
# Normalizes each lane's own handoff shape down to a single .bus/res-<id>.txt.

@test "extract_answer: codex — res-<id>.txt already written directly, just validated" {
  bus_init "$BUS"
  printf 'codex answer' > "$BUS/res-cx1.txt"
  extract_answer codex cx1 "$BUS"
  [ "$(<"$BUS/res-cx1.txt")" = "codex answer" ]
}

@test "extract_answer: codex — missing/empty res file is rc 1" {
  bus_init "$BUS"
  run extract_answer codex cx2 "$BUS"
  [ "$status" -eq 1 ]
}

@test "extract_answer: claude — last type==result .result wins over a banner line and an earlier result" {
  bus_init "$BUS"
  {
    echo 'not json banner line'
    echo '{"type":"result","result":"first"}'
    echo '{"type":"tool_use","name":"Read"}'
    echo '{"type":"result","result":"the real answer"}'
  } > "$BUS/run-cl1.jsonl"
  extract_answer claude cl1 "$BUS"
  [ "$(<"$BUS/res-cl1.txt")" = "the real answer" ]
}

@test "extract_answer: glm — same claude-shaped envelope, .result field" {
  bus_init "$BUS"
  echo '{"type":"result","result":"glm answer"}' > "$BUS/run-gm1.jsonl"
  extract_answer glm gm1 "$BUS"
  [ "$(<"$BUS/res-gm1.txt")" = "glm answer" ]
}

@test "extract_answer: kimi — claude-shaped envelope, .result field" {
  bus_init "$BUS"
  echo '{"type":"result","result":"kimi answer"}' > "$BUS/run-ki1.jsonl"
  extract_answer kimi ki1 "$BUS"
  [ "$(<"$BUS/res-ki1.txt")" = "kimi answer" ]
}

@test "extract_answer: gemini — concatenates assistant message deltas (real 0.49 shape, no .response field)" {
  bus_init "$BUS"
  {
    echo '{"type":"init"}'
    echo '{"type":"message","role":"assistant","content":"gemini ","delta":true}'
    echo '{"type":"message","role":"assistant","content":"answer","delta":true}'
    echo '{"type":"result","stats":{"models":{"gemini-3.5-flash":{}}},"status":"ok","timestamp":123}'
  } > "$BUS/run-ge1.jsonl"
  extract_answer gemini ge1 "$BUS"
  [ "$(<"$BUS/res-ge1.txt")" = "gemini answer" ]
}

@test "extract_answer: gemini — the result event carrying no .response field is not treated as the answer" {
  bus_init "$BUS"
  {
    echo '{"type":"message","role":"assistant","content":"real answer","delta":true}'
    echo '{"type":"result","stats":{},"status":"ok","timestamp":0}'
  } > "$BUS/run-ge2.jsonl"
  extract_answer gemini ge2 "$BUS"
  [ "$(<"$BUS/res-ge2.txt")" = "real answer" ]
}

@test "extract_answer: no result event found is rc 1, no res file written" {
  bus_init "$BUS"
  echo '{"type":"tool_use"}' > "$BUS/run-cl2.jsonl"
  run extract_answer claude cl2 "$BUS"
  [ "$status" -eq 1 ]
  [ ! -f "$BUS/res-cl2.txt" ]
}

@test "extract_answer: grok — concatenates type==text .data chunks in order (thought chunks ignored)" {
  bus_init "$BUS"
  {
    echo '{"type":"thought","data":"thinking, ignore me"}'
    echo '{"type":"text","data":"grok "}'
    echo '{"type":"text","data":"answer"}'
    echo '{"type":"end","stopReason":"EndTurn","usage":{"input_tokens":1}}'
  } > "$BUS/run-gk3.jsonl"
  extract_answer grok gk3 "$BUS"
  [ "$(<"$BUS/res-gk3.txt")" = "grok answer" ]
}

@test "extract_answer: grok — error-only log (no text events) is rc 1, no res file written" {
  bus_init "$BUS"
  echo '{"type":"error","message":"boom"}' > "$BUS/run-gk4.jsonl"
  run extract_answer grok gk4 "$BUS"
  [ "$status" -eq 1 ]
  [ ! -f "$BUS/res-gk4.txt" ]
}

@test "extract_answer: grok — text chunks then a type==error event (worker died mid-answer) is rc 1, no res file" {
  bus_init "$BUS"
  {
    echo '{"type":"text","data":"partial "}'
    echo '{"type":"text","data":"answer"}'
    echo '{"type":"error","message":"worker died"}'
  } > "$BUS/run-gk5.jsonl"
  run extract_answer grok gk5 "$BUS"
  [ "$status" -eq 1 ]
  [ ! -f "$BUS/res-gk5.txt" ]
}

@test "extract_answer: grok — text chunks with NO end event at all is rc 1, no res file" {
  bus_init "$BUS"
  echo '{"type":"text","data":"dangling"}' > "$BUS/run-gk6.jsonl"
  run extract_answer grok gk6 "$BUS"
  [ "$status" -eq 1 ]
  [ ! -f "$BUS/res-gk6.txt" ]
}

@test "extract_answer: unknown lane is rc 1" {
  bus_init "$BUS"
  run extract_answer carrierpigeon cx3 "$BUS"
  [ "$status" -eq 1 ]
}

# --- served_model ---------------------------------------------------------------
# The model that ACTUALLY answered, from the envelope — never the requested lane:model token.

@test "served_model: GLM — reports the model from the assistant envelope, not the requested token" {
  bus_init "$BUS"
  {
    echo '{"type":"assistant","message":{"model":"glm-5.2","content":[]}}'
    echo '{"type":"result","result":"ok"}'
  } > "$BUS/run-sm1.jsonl"
  [ "$(served_model glm "$BUS" sm1)" = "glm-5.2" ]
}

@test "served_model: kimi — reports the model from the assistant envelope, not the requested token" {
  bus_init "$BUS"
  # requested kimi:kimi-k2.7-code — served kimi-k3 (Moonshot aliasing, same class as glm/gemini)
  {
    echo '{"type":"assistant","message":{"model":"kimi-k3","content":[]}}'
    echo '{"type":"result","result":"ok"}'
  } > "$BUS/run-sm7.jsonl"
  [ "$(served_model kimi "$BUS" sm7)" = "kimi-k3" ]
}

@test "served_model: gemini — reports the served model from stats.models keys (aliasing)" {
  bus_init "$BUS"
  echo '{"type":"result","stats":{"models":{"gemini-3.5-flash":{}}},"status":"ok"}' > "$BUS/run-sm2.jsonl"
  [ "$(served_model gemini "$BUS" sm2)" = "gemini-3.5-flash" ]
}

@test "served_model: grok — reports the served model from the last end event's modelUsage keys (aliasing)" {
  bus_init "$BUS"
  {
    echo '{"type":"text","data":"hi"}'
    echo '{"type":"end","modelUsage":{"grok-4.5-build":{"inputTokens":1}}}'
  } > "$BUS/run-sm4.jsonl"
  [ "$(served_model grok "$BUS" sm4)" = "grok-4.5-build" ]
}

@test "served_model: grok — two end events, only the LAST one's modelUsage wins" {
  bus_init "$BUS"
  {
    echo '{"type":"end","modelUsage":{"grok-4.5-build":{"inputTokens":1}}}'
    echo '{"type":"end","modelUsage":{"grok-4.6":{"inputTokens":2}}}'
  } > "$BUS/run-sm5.jsonl"
  [ "$(served_model grok "$BUS" sm5)" = "grok-4.6" ]
}

@test "served_model: grok — one end event, two modelUsage keys (write-mode subagent) join sorted as \"a,b\"" {
  bus_init "$BUS"
  echo '{"type":"end","modelUsage":{"b":{"inputTokens":1},"a":{"inputTokens":2}}}' \
    > "$BUS/run-sm6.jsonl"
  [ "$(served_model grok "$BUS" sm6)" = "a,b" ]
}

@test "served_model: no determinable model is a clean empty echo, not an error" {
  bus_init "$BUS"
  echo '{"type":"turn.completed","usage":{"input_tokens":1}}' > "$BUS/run-sm3.jsonl"
  [ "$(served_model codex "$BUS" sm3)" = "" ]
}

# --- limit_error ---------------------------------------------------------------

@test "limit_error: GLM fail-over code (1308) flips the limit flag using next_flush_time" {
  bus_init "$BUS"
  local next_flush=$(( $(date +%s) + 500 ))
  printf '{"type":"error","error":{"code":1308,"message":"window limit","next_flush_time":%d}}\n' "$next_flush" \
    > "$BUS/run-lg1.jsonl"
  run limit_error glm "$BUS" lg1
  [ "$status" -eq 1 ]
  run limit_active "$BUS" glm
  [ "$status" -eq 0 ]
}

@test "limit_error: GLM next_flush_time (epoch) sets the stored TTL to the real window, not the 18000 fallback" {
  bus_init "$BUS"
  local next_flush=$(( $(date +%s) + 500 ))
  printf '{"type":"error","error":{"code":1308,"message":"window limit","next_flush_time":%d}}\n' "$next_flush" \
    > "$BUS/run-lgt1.jsonl"
  run limit_error glm "$BUS" lgt1
  [ "$status" -eq 1 ]
  # the stored TTL is the seconds-until-flush (~500), provably NOT the 18000 window default
  local ttl; ttl="$(_marker_ttl "$BUS/limits/glm.limited" 18000)"   # FR-7 reason line, ttl= field
  [ "$ttl" -gt 400 ]
  [ "$ttl" -lt 600 ]
}

@test "limit_error: GLM next_flush_time as an ISO date string is parsed to a TTL" {
  bus_init "$BUS"
  local flush_iso; flush_iso="$(date -d '+400 seconds' '+%Y-%m-%dT%H:%M:%S')"
  printf '{"type":"error","error":{"code":1310,"message":"weekly","next_flush_time":"%s"}}\n' "$flush_iso" \
    > "$BUS/run-lgt2.jsonl"
  run limit_error glm "$BUS" lgt2
  [ "$status" -eq 1 ]
  local ttl; ttl="$(_marker_ttl "$BUS/limits/glm.limited" 18000)"   # FR-7 reason line, ttl= field
  # ~400s (allow slack for parsing/second boundaries); the point is it's the parsed window, not 18000
  [ "$ttl" -gt 300 ]
  [ "$ttl" -lt 500 ]
}

@test "limit_error: GLM transient code (1302) is retry-only, no flag" {
  bus_init "$BUS"
  echo '{"type":"error","error":{"code":1302,"message":"rate"}}' > "$BUS/run-lg2.jsonl"
  run limit_error glm "$BUS" lg2
  [ "$status" -eq 2 ]
  run limit_active "$BUS" glm
  [ "$status" -eq 1 ]
}

@test "limit_error: GLM no error event present is a clean rc 0" {
  bus_init "$BUS"
  echo '{"type":"result","result":"ok"}' > "$BUS/run-lg3.jsonl"
  run limit_error glm "$BUS" lg3
  [ "$status" -eq 0 ]
}

@test "limit_error: codex — a single strike is retry-only (2-strike rule), no flag" {
  bus_init "$BUS"
  echo '{"type":"turn.failed","error":{"code":"rate_limit_exceeded","message":"usage limit reached"}}' \
    > "$BUS/run-cx4.jsonl"
  run limit_error codex "$BUS" cx4
  [ "$status" -eq 2 ]
  run limit_active "$BUS" codex
  [ "$status" -eq 1 ]
  [ "$(<"$BUS/limits/codex.strikes")" = "1" ]
}

@test "limit_error: codex — second consecutive strike flips the flag and clears the counter" {
  bus_init "$BUS"
  printf '1' > "$BUS/limits/codex.strikes"
  echo '{"type":"error","code":"rate_limit_exceeded","message":"usage limit"}' > "$BUS/run-cx5.jsonl"
  run limit_error codex "$BUS" cx5
  [ "$status" -eq 1 ]
  run limit_active "$BUS" codex
  [ "$status" -eq 0 ]
  [ ! -f "$BUS/limits/codex.strikes" ]
}

@test "limit_error: codex — a clean run resets the strike counter" {
  bus_init "$BUS"
  printf '1' > "$BUS/limits/codex.strikes"
  echo '{"type":"turn.completed","usage":{"input_tokens":10}}' > "$BUS/run-cx6.jsonl"
  run limit_error codex "$BUS" cx6
  [ "$status" -eq 0 ]
  [ ! -f "$BUS/limits/codex.strikes" ]
}

@test "limit_error: grok — 'rate limit' in the message flips the limit flag (no observed 429 envelope yet, message-sniff fallback)" {
  bus_init "$BUS"
  echo '{"type":"error","message":"Rate limit exceeded, try later"}' > "$BUS/run-gklim1.jsonl"
  run limit_error grok "$BUS" gklim1
  [ "$status" -eq 1 ]
  run limit_active "$BUS" grok
  [ "$status" -eq 0 ]
}

@test "limit_error: grok — 'usage limit' in the message flips the limit flag" {
  bus_init "$BUS"
  echo '{"type":"error","message":"weekly usage limit reached"}' > "$BUS/run-gklim2.jsonl"
  run limit_error grok "$BUS" gklim2
  [ "$status" -eq 1 ]
  run limit_active "$BUS" grok
  [ "$status" -eq 0 ]
}

@test "limit_error: grok — unrelated error returns 0 (normal bounded retry), no flag" {
  bus_init "$BUS"
  echo '{"type":"error","message":"tool execution failed: file not found"}' > "$BUS/run-gklim3.jsonl"
  run limit_error grok "$BUS" gklim3
  [ "$status" -eq 0 ]
  run limit_active "$BUS" grok
  [ "$status" -eq 1 ]
}

@test "limit_error: grok — 'Rate-Limit hit' (hyphenated variant) flips the limit flag" {
  bus_init "$BUS"
  echo '{"type":"error","message":"Rate-Limit hit, back off"}' > "$BUS/run-gklim4.jsonl"
  run limit_error grok "$BUS" gklim4
  [ "$status" -eq 1 ]
  run limit_active "$BUS" grok
  [ "$status" -eq 0 ]
}

@test "limit_error: grok — 'HTTP 429' status code flips the limit flag" {
  bus_init "$BUS"
  echo '{"type":"error","message":"Request failed with status 429"}' > "$BUS/run-gklim5.jsonl"
  run limit_error grok "$BUS" gklim5
  [ "$status" -eq 1 ]
  run limit_active "$BUS" grok
  [ "$status" -eq 0 ]
}

# --- kimi lane (Moonshot) failover: quota/balance park immediately, plain rate is 2-strike --------

@test "limit_error: kimi — first plain 429 strike is retry-only (rc 2), no flag" {
  bus_init "$BUS"
  echo '{"type":"error","error":{"message":"rate limit exceeded, too many requests"}}' > "$BUS/run-ki9.jsonl"
  run limit_error kimi "$BUS" ki9
  [ "$status" -eq 2 ]
  run limit_active "$BUS" kimi
  [ "$status" -eq 1 ]
  [ "$(<"$BUS/limits/kimi.strikes")" = "1" ]
}

@test "limit_error: kimi — second consecutive rate strike parks with SHORT TTL (limits/kimi.limited content == 300)" {
  bus_init "$BUS"
  printf '1' > "$BUS/limits/kimi.strikes"
  echo '{"type":"error","error":{"message":"429 too many requests"}}' > "$BUS/run-ki10.jsonl"
  run limit_error kimi "$BUS" ki10
  [ "$status" -eq 1 ]
  run limit_active "$BUS" kimi
  [ "$status" -eq 0 ]
  [ ! -f "$BUS/limits/kimi.strikes" ]
  [ "$(_marker_ttl "$BUS/limits/kimi.limited" 18000)" = "300" ]
}

@test "limit_error: kimi — a clean run resets the strike counter" {
  bus_init "$BUS"
  printf '1' > "$BUS/limits/kimi.strikes"
  echo '{"type":"result","result":"ok"}' > "$BUS/run-ki11.jsonl"
  run limit_error kimi "$BUS" ki11
  [ "$status" -eq 0 ]
  [ ! -f "$BUS/limits/kimi.strikes" ]
}

@test "limit_error: kimi — exceeded_current_quota_error parks immediately (rc 1, TTL 18000, evidence file written)" {
  bus_init "$BUS"
  echo '{"type":"error","error":{"type":"exceeded_current_quota_error","message":"quota exhausted"}}' > "$BUS/run-ki12.jsonl"
  run limit_error kimi "$BUS" ki12
  [ "$status" -eq 1 ]
  run limit_active "$BUS" kimi
  [ "$status" -eq 0 ]
  [ "$(_marker_ttl "$BUS/limits/kimi.limited" 0)" = "18000" ]
  [ -s "$BUS/limits/kimi.limited.evidence" ]
}

@test "limit_error: kimi — 'insufficient balance' message parks immediately" {
  bus_init "$BUS"
  echo '{"type":"error","error":{"message":"insufficient balance in account"}}' > "$BUS/run-ki13.jsonl"
  run limit_error kimi "$BUS" ki13
  [ "$status" -eq 1 ]
  run limit_active "$BUS" kimi
  [ "$status" -eq 0 ]
}

@test "limit_error: kimi — unrelated error is rc 0, no flag" {
  bus_init "$BUS"
  printf '1' > "$BUS/limits/kimi.strikes"
  echo '{"type":"error","error":{"message":"tool execution failed: file not found"}}' > "$BUS/run-ki14.jsonl"
  run limit_error kimi "$BUS" ki14
  [ "$status" -eq 0 ]
  run limit_active "$BUS" kimi
  [ "$status" -eq 1 ]
  [ ! -f "$BUS/limits/kimi.strikes" ]
}

# --- chain_current / chain_advance / chain_reset --------------------------------
# Per-id EXEC_CHAIN position tracking so a failed-over spec resumes at the next lane,
# not back at the front, on its next claim attempt.

@test "chain_current: with no prior state, returns EXEC_CHAIN's first token" {
  bus_init "$BUS"
  EXEC_CHAIN="claude:opus glm:glm-5.2"
  [ "$(chain_current "$BUS" ch1)" = "claude:opus" ]
}

@test "chain_advance: drops the first token; chain_current then returns the second" {
  bus_init "$BUS"
  EXEC_CHAIN="claude:opus glm:glm-5.2"
  chain_advance "$BUS" ch2
  [ "$(chain_current "$BUS" ch2)" = "glm:glm-5.2" ]
}

@test "chain_advance: exhausting the last token leaves chain_current empty" {
  bus_init "$BUS"
  EXEC_CHAIN="claude:opus glm:glm-5.2"
  chain_advance "$BUS" ch3
  chain_advance "$BUS" ch3
  [ "$(chain_current "$BUS" ch3)" = "" ]
}

@test "chain_reset: clears per-id state back to EXEC_CHAIN's first token" {
  bus_init "$BUS"
  EXEC_CHAIN="claude:opus glm:glm-5.2"
  chain_advance "$BUS" ch4
  chain_reset "$BUS" ch4
  [ "$(chain_current "$BUS" ch4)" = "claude:opus" ]
}

# --- verify_lane_for ------------------------------------------------------------
# Phase E step 4: cross-model verify wave rotation. Judge != executor, always — even off the map.

@test "verify_lane_for: default VERIFY_MAP maps every known generator to a different lane" {
  VERIFY_MAP="claude:codex codex:kimi gemini:claude glm:codex grok:codex kimi:codex"
  [ "$(verify_lane_for claude)" = "codex" ]
  [ "$(verify_lane_for codex)" = "kimi" ]
  [ "$(verify_lane_for gemini)" = "claude" ]
  [ "$(verify_lane_for glm)" = "codex" ]
  [ "$(verify_lane_for grok)" = "codex" ]
  [ "$(verify_lane_for kimi)" = "codex" ]
}

@test "verify_lane_for: unmapped generator still gets a lane that is provably not itself" {
  VERIFY_MAP="claude:codex"
  local result
  result="$(verify_lane_for mystery)"
  [ -n "$result" ]
  [ "$result" != "mystery" ]
}

@test "verify_lane_for: empty VERIFY_MAP falls back but never maps codex to itself" {
  VERIFY_MAP=""
  [ "$(verify_lane_for codex)" != "codex" ]
}

# --- verify_lane_for: review-pair fallback (codex <-> kimi), busdir-aware ------------------------
# Optional 2nd arg (busdir): {codex,kimi} are mutual review-pair fallbacks. If the mapped/default
# verifier is one of the pair and its .limited flag is active, review hands off to the OTHER lane
# in the pair — unless that partner is the generator itself (judge != executor stays absolute) or
# the partner is ALSO limited, in which case the mapped verifier is kept as-is (the pin parks
# loudly elsewhere; verify pins never chain-switch). Without a busdir arg, behavior is byte-
# identical to plain mapping (no limit awareness).

@test "verify_lane_for: limited codex verifier falls back to kimi (review pair)" {
  bus_init "$BUS"
  VERIFY_MAP="glm:codex"
  limit_flag "$BUS" codex 18000
  local result warning
  result="$(verify_lane_for glm "$BUS" 2>/dev/null)"
  warning="$(verify_lane_for glm "$BUS" 2>&1 1>/dev/null)"
  [ "$result" = "kimi" ]
  [[ "$warning" == *"review-pair fallback to kimi"* ]]
}

@test "verify_lane_for: limited kimi verifier falls back to codex (review pair)" {
  bus_init "$BUS"
  VERIFY_MAP="glm:kimi"
  limit_flag "$BUS" kimi 18000
  [ "$(verify_lane_for glm "$BUS" 2>/dev/null)" = "codex" ]
}

@test "verify_lane_for: pair fallback refuses to seat the generator as its own judge" {
  bus_init "$BUS"
  VERIFY_MAP="kimi:codex"
  limit_flag "$BUS" codex 18000
  [ "$(verify_lane_for kimi "$BUS" 2>/dev/null)" = "codex" ]
}

@test "verify_lane_for: both pair lanes limited keeps the mapped verifier (parks loudly)" {
  bus_init "$BUS"
  VERIFY_MAP="glm:codex"
  limit_flag "$BUS" codex 18000
  limit_flag "$BUS" kimi 18000
  [ "$(verify_lane_for glm "$BUS" 2>/dev/null)" = "codex" ]
}

@test "verify_lane_for: no busdir arg keeps pure mapping behavior" {
  bus_init "$BUS"
  VERIFY_MAP="glm:codex"
  limit_flag "$BUS" codex 18000
  [ "$(verify_lane_for glm)" = "codex" ]
}

@test "verify_lane_for: expired limit flag does not trigger pair fallback" {
  bus_init "$BUS"
  VERIFY_MAP="glm:codex"
  limit_flag "$BUS" codex 100
  touch -d "-200 seconds" "$BUS/limits/codex.limited"
  [ "$(verify_lane_for glm "$BUS")" = "codex" ]
}

# --- write_verify_spec -----------------------------------------------------------
# Builds .bus/specs/v-<id>.prompt (original question + branch answer + VERDICT instruction) and
# its .lane sidecar (pinned to VERIFY_MAP's mapped lane), from a COMPLETED generate-wave branch.

@test "write_verify_spec: builds v-<id> spec + lane sidecar per VERIFY_MAP" {
  bus_init "$BUS"
  printf 'the original question' > "$BUS/prompt-b1.txt"
  printf 'branch answer text' > "$BUS/res-b1.txt"
  printf '{"id":"b1","code":0,"lane":"claude"}\n' > "$BUS/done/b1"
  VERIFY_MAP="claude:codex codex:kimi gemini:claude glm:codex grok:codex kimi:codex"

  write_verify_spec "$BUS" b1
  [ -f "$BUS/specs/v-b1.prompt" ]
  [[ "$(<"$BUS/specs/v-b1.prompt")" == *"the original question"* ]]
  [[ "$(<"$BUS/specs/v-b1.prompt")" == *"branch answer text"* ]]
  [[ "$(<"$BUS/specs/v-b1.prompt")" == *"VERDICT: confirmed|refuted|unverifiable"* ]]
  [ "$(<"$BUS/specs/v-b1.lane")" = "codex:default" ]
}

@test "write_verify_spec: pins the pair-fallback lane when the mapped verifier is limited" {
  bus_init "$BUS"
  printf 'the original question' > "$BUS/prompt-b14.txt"
  printf 'branch answer text' > "$BUS/res-b14.txt"
  printf '{"id":"b14","code":0,"lane":"glm"}\n' > "$BUS/done/b14"
  VERIFY_MAP="glm:codex"
  limit_flag "$BUS" codex 18000

  write_verify_spec "$BUS" b14
  [ "$(<"$BUS/specs/v-b14.lane")" = "kimi:kimi-k3" ]
}

@test "write_verify_spec: never verifies a verify branch (id already starts with v-)" {
  bus_init "$BUS"
  printf '{"id":"v-x","code":0,"lane":"codex"}\n' > "$BUS/done/v-x"
  run write_verify_spec "$BUS" v-x
  [ "$status" -eq 1 ]
  [ ! -f "$BUS/specs/v-v-x.prompt" ]
}

@test "write_verify_spec: no-ops when the done marker is missing" {
  bus_init "$BUS"
  run write_verify_spec "$BUS" ghost
  [ "$status" -eq 1 ]
}

@test "write_verify_spec: no-ops when the done marker carries no provenance lane" {
  bus_init "$BUS"
  printf 'q' > "$BUS/prompt-b9.txt"
  printf 'a' > "$BUS/res-b9.txt"
  printf '{"id":"b9","code":0}\n' > "$BUS/done/b9"
  run write_verify_spec "$BUS" b9
  [ "$status" -eq 1 ]
  [ ! -f "$BUS/specs/v-b9.prompt" ]
}

@test "write_verify_spec: idempotent — no-ops if v-<id> already has any bus footprint" {
  bus_init "$BUS"
  printf 'q' > "$BUS/prompt-b2.txt"
  printf 'a' > "$BUS/res-b2.txt"
  printf '{"id":"b2","code":0,"lane":"gemini"}\n' > "$BUS/done/b2"
  echo '{"id":"v-b2","code":0}' > "$BUS/done/v-b2"

  run write_verify_spec "$BUS" b2
  [ "$status" -eq 1 ]
  [ ! -f "$BUS/specs/v-b2.prompt" ]
}

# --- wave-7 finding 3: publish ordering (.lane sidecar before the prompt) + torn-footprint repair -

@test "write_verify_spec: writes the .lane sidecar before the prompt (order proxy: sidecar mtime <= prompt mtime)" {
  bus_init "$BUS"
  printf 'the original question' > "$BUS/prompt-b10.txt"
  printf 'branch answer text' > "$BUS/res-b10.txt"
  printf '{"id":"b10","code":0,"lane":"claude"}\n' > "$BUS/done/b10"

  write_verify_spec "$BUS" b10
  [ -f "$BUS/specs/v-b10.lane" ]
  [ -f "$BUS/specs/v-b10.prompt" ]
  lane_mtime="$(stat -c %Y "$BUS/specs/v-b10.lane")"
  prompt_mtime="$(stat -c %Y "$BUS/specs/v-b10.prompt")"
  [ "$lane_mtime" -le "$prompt_mtime" ]
}

@test "write_verify_spec: repairs a torn footprint — v-<id>.prompt in specs/ with no .lane sidecar gets one" {
  bus_init "$BUS"
  printf 'the original question' > "$BUS/prompt-b11.txt"
  printf 'branch answer text' > "$BUS/res-b11.txt"
  printf '{"id":"b11","code":0,"lane":"claude"}\n' > "$BUS/done/b11"
  # simulate a crash between the two publish steps of a PRIOR write_verify_spec call: the
  # prompt landed, its sidecar never did.
  printf 'torn prompt body' > "$BUS/specs/v-b11.prompt"

  run write_verify_spec "$BUS" b11
  [ "$status" -eq 0 ]
  [ -f "$BUS/specs/v-b11.lane" ]
  [ "$(<"$BUS/specs/v-b11.lane")" = "codex:default" ]
  # repair must not clobber the torn prompt body itself
  [ "$(<"$BUS/specs/v-b11.prompt")" = "torn prompt body" ]
  [[ "$output" == *"repairing torn verify footprint"* ]]
}

@test "write_verify_spec: repairs a torn footprint — v-<id>.prompt in queue/ with no .lane sidecar gets one" {
  bus_init "$BUS"
  printf 'the original question' > "$BUS/prompt-b12.txt"
  printf 'branch answer text' > "$BUS/res-b12.txt"
  printf '{"id":"b12","code":0,"lane":"claude"}\n' > "$BUS/done/b12"
  printf 'torn prompt body' > "$BUS/queue/v-b12.prompt"

  run write_verify_spec "$BUS" b12
  [ "$status" -eq 0 ]
  [ -f "$BUS/queue/v-b12.lane" ]
  [ ! -f "$BUS/specs/v-b12.lane" ]
  [ "$(<"$BUS/queue/v-b12.prompt")" = "torn prompt body" ]
}

@test "write_verify_spec: a fully-published v-<id> (prompt + sidecar both present) still no-ops" {
  bus_init "$BUS"
  printf 'q' > "$BUS/prompt-b13.txt"
  printf 'a' > "$BUS/res-b13.txt"
  printf '{"id":"b13","code":0,"lane":"claude"}\n' > "$BUS/done/b13"
  printf 'complete prompt' > "$BUS/specs/v-b13.prompt"
  printf 'codex:default' > "$BUS/specs/v-b13.lane"

  run write_verify_spec "$BUS" b13
  [ "$status" -eq 1 ]
  [ "$(<"$BUS/specs/v-b13.prompt")" = "complete prompt" ]
  [ "$(<"$BUS/specs/v-b13.lane")" = "codex:default" ]
}

# --- wave-7 finding 5: exact claim resolution (shares _claim_of with swarm-ctl) -------------------

@test "write_verify_spec: a claimed v-<id>.<sibling-with-dots> does NOT suppress verify for <id>" {
  bus_init "$BUS"
  printf 'the original question' > "$BUS/prompt-a.txt"
  printf 'branch answer text' > "$BUS/res-a.txt"
  printf '{"id":"a","code":0,"lane":"claude"}\n' > "$BUS/done/a"
  # a DIFFERENT id, "v-a.b", is claimed — its claim filename ("v-a.b.codex:default") prefix-
  # matches a bare glob on "v-a".*, which must NOT suppress verification of "a".
  echo "unrelated in-flight verify for a different id" > "$BUS/claimed/v-a.b.codex:default"

  run write_verify_spec "$BUS" a
  [ "$status" -eq 0 ]
  [ -f "$BUS/specs/v-a.prompt" ]
  [ -f "$BUS/specs/v-a.lane" ]
  # the sibling's claim must be untouched
  [ -f "$BUS/claimed/v-a.b.codex:default" ]
}

# --- ledger_row --------------------------------------------------------------------
# Phase E step 4: one markdown row per successfully finalized branch, per-lane cost/usage shape
# from the REAL captured envelopes (docs/01-feasibility-tests.md): claude .total_cost_usd+.usage,
# codex turn.completed.usage, gemini result.stats.models, GLM the same claude .usage but no fake $.

_ledger_fixture() {
  cat > "$BATS_TEST_TMPDIR/ledger.md" <<'EOF'
# Fixture Ledger

## Ledger

| When | What | Lane | Billed |
|------|------|------|--------|
| 2026-07-01 | existing row | Anthropic API (session auth) | $0.01 |

Total ad-hoc test spend so far ≈ **$0.01**.
EOF
}

@test "ledger_row: claude — real cost+usage envelope produces a dollar figure, row lands before the trailing prose" {
  bus_init "$BUS"
  _ledger_fixture
  export LEDGER_FILE="$BATS_TEST_TMPDIR/ledger.md"
  printf 'the prompt text' > "$BUS/prompt-lc1.txt"
  printf '{"id":"lc1","code":0,"lane":"claude"}\n' > "$BUS/done/lc1"
  {
    echo '{"type":"init"}'
    echo '{"type":"result","result":"answer","total_cost_usd":0.0314,"usage":{"input_tokens":100,"output_tokens":20}}'
  } > "$BUS/run-lc1.jsonl"

  ledger_row "$BUS" lc1

  grep -q 'the prompt text' "$LEDGER_FILE"
  grep -q '\$0.0314' "$LEDGER_FILE"
  grep -q '100 in / 20 out' "$LEDGER_FILE"
  grep -q 'Anthropic API (session auth)' "$LEDGER_FILE"
  # row inserted right after the prior data row, trailing prose preserved and still last
  [ "$(tail -1 "$LEDGER_FILE")" = "Total ad-hoc test spend so far ≈ **\$0.01**." ]
  [ "$(grep -c '^| ' "$LEDGER_FILE")" -eq 3 ]  # header + old row + new row (separator excluded)
}

@test "ledger_row: codex — turn.completed usage, no fabricated dollar figure" {
  bus_init "$BUS"
  export LEDGER_FILE="$BATS_TEST_TMPDIR/ledger2.md"
  printf 'codex branch prompt' > "$BUS/prompt-cx1.txt"
  printf '{"id":"cx1","code":0,"lane":"codex"}\n' > "$BUS/done/cx1"
  {
    echo '{"type":"thread.started"}'
    echo '{"type":"turn.completed","usage":{"input_tokens":13310,"cached_input_tokens":10112,"output_tokens":6}}'
  } > "$BUS/run-cx1.jsonl"

  ledger_row "$BUS" cx1

  grep -q 'ChatGPT session auth (auth.json)' "$LEDGER_FILE"
  grep -q '13310 in, 10112 cached / 6 out' "$LEDGER_FILE"
  ! grep -q '| \$' "$LEDGER_FILE"
}

@test "ledger_row: gemini — sums stats.models leaves, no fabricated dollar figure" {
  bus_init "$BUS"
  export LEDGER_FILE="$BATS_TEST_TMPDIR/ledger3.md"
  printf 'gemini branch prompt' > "$BUS/prompt-ge1.txt"
  printf '{"id":"ge1","code":0,"lane":"gemini"}\n' > "$BUS/done/ge1"
  {
    echo '{"type":"init"}'
    echo '{"type":"result","stats":{"models":{"gemini-3.5-flash":{"tokens":{"input":9541,"output":44}}}},"status":"ok"}'
  } > "$BUS/run-ge1.jsonl"

  ledger_row "$BUS" ge1

  grep -q 'Google AI Studio' "$LEDGER_FILE"
  grep -q '9585 tokens total' "$LEDGER_FILE"
}

@test "ledger_row: GLM — prompts-consumed language, never a dollar figure" {
  bus_init "$BUS"
  export LEDGER_FILE="$BATS_TEST_TMPDIR/ledger4.md"
  printf 'glm branch prompt' > "$BUS/prompt-gm1.txt"
  printf '{"id":"gm1","code":0,"lane":"glm"}\n' > "$BUS/done/gm1"
  echo '{"type":"result","result":"answer","usage":{"input_tokens":34000,"output_tokens":95}}' > "$BUS/run-gm1.jsonl"

  ledger_row "$BUS" gm1

  grep -q 'Z.ai Coding Plan (Anthropic-compat)' "$LEDGER_FILE"
  grep -q '1 prompt' "$LEDGER_FILE"
  ! grep -q '| \$' "$LEDGER_FILE"
}

@test "ledger_row: kimi — real \$ recomputed from usage × Moonshot list, envelope total_cost_usd ignored" {
  bus_init "$BUS"
  export LEDGER_FILE="$BATS_TEST_TMPDIR/ledger-kimi.md"
  printf 'kimi branch prompt' > "$BUS/prompt-ki15.txt"
  printf '{"id":"ki15","code":0,"lane":"kimi"}\n' > "$BUS/done/ki15"
  # 1M in x $3 + 1M cache_read x $0.30 + 0.1M out x $15 = $4.80 — the decoy total_cost_usd (9.99)
  # must never surface; kimi-k3 list pricing is recomputed from raw usage, not read off the envelope.
  echo '{"type":"result","result":"answer","total_cost_usd":9.99,"usage":{"input_tokens":1000000,"cache_read_input_tokens":1000000,"output_tokens":100000}}' > "$BUS/run-ki15.jsonl"

  ledger_row "$BUS" ki15

  grep -q '\$4.8' "$LEDGER_FILE"
  grep -q 'Moonshot' "$LEDGER_FILE"
  ! grep -q '9.99' "$LEDGER_FILE"
}

@test "_ledger_grok_cost: cost present — dollar notional string with in/cached/out breakdown, labeled notional" {
  bus_init "$BUS"
  echo '{"type":"end","usage":{"input_tokens":787,"cache_read_input_tokens":2432,"output_tokens":32},"total_cost_usd":0.0024956,"modelUsage":{"grok-4.5-build":{"costUSD":0.0024956}}}' \
    > "$BUS/run-gc1.jsonl"
  result="$(_ledger_grok_cost "$BUS/run-gc1.jsonl")"
  [[ "$result" == *'$0.0024956'* ]]
  [[ "$result" == *'notional'* ]]
  [[ "$result" == *'787'* ]]
  [[ "$result" == *'2432'* ]]
  [[ "$result" == *'32'* ]]
}

@test "_ledger_grok_cost: cost omitted (OAuth pool-metered) — token-only fallback, never a fabricated \$" {
  bus_init "$BUS"
  echo '{"type":"end","usage":{"input_tokens":500,"cache_read_input_tokens":100,"output_tokens":15}}' \
    > "$BUS/run-gc2.jsonl"
  result="$(_ledger_grok_cost "$BUS/run-gc2.jsonl")"
  [[ "$result" == *'cost omitted'* ]]
  [[ "$result" == *'500'* ]]
  [[ "$result" != *'$'* ]]
}

@test "_ledger_grok_cost: no usage at all — n/a, never a bare guess" {
  bus_init "$BUS"
  echo '{"type":"init"}' > "$BUS/run-gc3.jsonl"
  [ "$(_ledger_grok_cost "$BUS/run-gc3.jsonl")" = "n/a" ]
}

@test "_ledger_grok_cost: end event present but no usage object and no cost — n/a" {
  bus_init "$BUS"
  echo '{"type":"end","stopReason":"EndTurn"}' > "$BUS/run-gc4.jsonl"
  [ "$(_ledger_grok_cost "$BUS/run-gc4.jsonl")" = "n/a" ]
}

@test "ledger_row: missing done marker is a clean no-op (rc 1)" {
  bus_init "$BUS"
  export LEDGER_FILE="$BATS_TEST_TMPDIR/ledger5.md"
  run ledger_row "$BUS" nope
  [ "$status" -eq 1 ]
  [ ! -f "$LEDGER_FILE" ]
}

@test "_ledger_append_row: header+separator-only table (zero data rows) — new row lands AFTER the separator, not before it" {
  bus_init "$BUS"
  cat > "$BATS_TEST_TMPDIR/empty-ledger.md" <<'EOF'
| When | What | Lane | Billed |
|------|------|------|--------|
EOF
  export LEDGER_FILE="$BATS_TEST_TMPDIR/empty-ledger.md"
  printf 'q' > "$BUS/prompt-ez1.txt"
  printf '{"id":"ez1","code":0,"lane":"claude"}\n' > "$BUS/done/ez1"
  echo '{"type":"result","result":"a","total_cost_usd":0.01,"usage":{"input_tokens":1,"output_tokens":1}}' \
    > "$BUS/run-ez1.jsonl"

  ledger_row "$BUS" ez1

  local sep_line row_line
  sep_line="$(grep -n '^|-' "$LEDGER_FILE" | head -1 | cut -d: -f1)"
  row_line="$(grep -n '| q |' "$LEDGER_FILE" | cut -d: -f1)"
  [ -n "$sep_line" ]
  [ -n "$row_line" ]
  [ "$row_line" -gt "$sep_line" ]
}

@test "_ledger_append_row: table with existing data rows still appends after the LAST data row" {
  bus_init "$BUS"
  _ledger_fixture
  export LEDGER_FILE="$BATS_TEST_TMPDIR/ledger.md"
  printf 'q2' > "$BUS/prompt-ez2.txt"
  printf '{"id":"ez2","code":0,"lane":"claude"}\n' > "$BUS/done/ez2"
  echo '{"type":"result","result":"a","total_cost_usd":0.02,"usage":{"input_tokens":1,"output_tokens":1}}' \
    > "$BUS/run-ez2.jsonl"

  ledger_row "$BUS" ez2

  [ "$(tail -1 "$LEDGER_FILE")" = "Total ad-hoc test spend so far ≈ **\$0.01**." ]
  local old_row new_row
  old_row="$(grep -n 'existing row' "$LEDGER_FILE" | cut -d: -f1)"
  new_row="$(grep -n '| q2 |' "$LEDGER_FILE" | cut -d: -f1)"
  [ "$new_row" -gt "$old_row" ]
}

@test "ledger_row: no existing ledger file self-heals with a fresh header + row" {
  bus_init "$BUS"
  export LEDGER_FILE="$BATS_TEST_TMPDIR/fresh-ledger.md"
  printf 'q' > "$BUS/prompt-fr1.txt"
  printf '{"id":"fr1","code":0,"lane":"claude"}\n' > "$BUS/done/fr1"
  echo '{"type":"result","result":"a","total_cost_usd":0.01,"usage":{"input_tokens":1,"output_tokens":1}}' \
    > "$BUS/run-fr1.jsonl"

  ledger_row "$BUS" fr1
  [ -f "$LEDGER_FILE" ]
  grep -q '| When | What | Lane | Billed |' "$LEDGER_FILE"
  grep -q '| q |' "$LEDGER_FILE"
}

@test "ledger_row: prompt containing backslash escapes lands one clean row (awk -v escape-processing does not mangle it)" {
  bus_init "$BUS"
  export LEDGER_FILE="$BATS_TEST_TMPDIR/ledger-esc.md"
  # first 60 chars carry a backslash-n and a pipe — awk -v would escape-process \n into a newline,
  # splitting the row across two lines and breaking the 4-cell markdown table.
  printf 'path C:\\new | tab\\there literal end' > "$BUS/prompt-esc1.txt"
  printf '{"id":"esc1","code":0,"lane":"claude"}\n' > "$BUS/done/esc1"
  echo '{"type":"result","result":"a","total_cost_usd":0.01,"usage":{"input_tokens":1,"output_tokens":1}}' \
    > "$BUS/run-esc1.jsonl"

  ledger_row "$BUS" esc1
  # header + exactly one row for a fresh file = 2 pipe-prefixed lines; if awk had escape-processed
  # the `\n` into a real newline the row would have split into a 3rd line.
  [ "$(grep -c '^| ' "$LEDGER_FILE")" -eq 2 ]
  # the backslash survives literally (not turned into a real newline/tab)
  grep -qF 'C:\new' "$LEDGER_FILE"
  grep -qF 'tab\there' "$LEDGER_FILE"
}

@test "ledger_row: loop spec whose prompt starts with '#' falls back to the spec id, not the '## Criteria' banner" {
  bus_init "$BUS"
  export LEDGER_FILE="$BATS_TEST_TMPDIR/ledger-loop.md"
  printf '## Criteria (read-only contract — do not attempt to change this)\ngoal: x\n' \
    > "$BUS/prompt-myrun-i1-exec.txt"
  printf '{"id":"myrun-i1-exec","code":0,"lane":"claude"}\n' > "$BUS/done/myrun-i1-exec"
  echo '{"type":"result","result":"a","total_cost_usd":0.01,"usage":{"input_tokens":1,"output_tokens":1}}' \
    > "$BUS/run-myrun-i1-exec.jsonl"

  ledger_row "$BUS" myrun-i1-exec

  grep -q 'myrun-i1-exec' "$LEDGER_FILE"
  ! grep -q 'Criteria' "$LEDGER_FILE"
}

# --- spec 07 RED wave: reap() frozen-skip (§4.6b) ---------------------------------------
# reap() currently requeues EVERY stale claim; §4.6b adds a skip for ids with limits/<id>.frozen
# (a SIGSTOP'd worker's heartbeat loop is stopped too — without the skip the lease would expire and
# the reaper would requeue a still-frozen claim = double-claim disaster). Both tests below are RED
# against the current tree.

@test "reap: skips a stale claim whose limits/<id>.frozen exists (claim stays claimed)" {
  bus_init "$BUS"
  echo "x" > "$BUS/queue/r1.prompt"
  claim "$BUS" r1 workerA
  touch -d "-20 minutes" "$BUS/claimed/r1.workerA"
  touch "$BUS/limits/r1.frozen"

  reap "$BUS" 15

  [ -f "$BUS/claimed/r1.workerA" ]   # frozen -> NOT requeued (FAILS now: current reap requeues it)
  [ ! -f "$BUS/queue/r1.prompt" ]
}

@test "reap: a stale claim frozen then thawed (flag removed) gets requeued on the next reap" {
  bus_init "$BUS"
  echo "x" > "$BUS/queue/r2.prompt"
  claim "$BUS" r2 workerA
  touch -d "-20 minutes" "$BUS/claimed/r2.workerA"
  touch "$BUS/limits/r2.frozen"

  reap "$BUS" 15
  [ -f "$BUS/claimed/r2.workerA" ]   # while frozen: skipped (FAILS now: current reap requeues it)

  rm -f "$BUS/limits/r2.frozen"      # thaw — resume-worker clears the flag
  reap "$BUS" 15
  [ ! -f "$BUS/claimed/r2.workerA" ] # same claim, now thawed -> requeued
  [ -f "$BUS/queue/r2.prompt" ]
}

# --- audit fix: reap() must split on the LAST ".<lane:model>" suffix, not the first dot ----------
# CRITICAL live finding: a dotted <id> (e.g. "a.b", claimed as "a.b.glm:glm-5.2") was mis-split by
# the old first-dot logic into id "a" — limits/a.b.frozen was never consulted, so a still-frozen
# claim for "a.b" could be requeued out from under it (double-claim). The fix strips exactly the
# trailing ".<lane>:<model>" suffix via regex instead.

@test "reap: a stale FROZEN claim with a dotted id is NOT requeued (double-claim regression)" {
  bus_init "$BUS"
  echo "x" > "$BUS/queue/a.b.prompt"
  claim "$BUS" "a.b" "glm:glm-5.2"
  touch -d "-20 minutes" "$BUS/claimed/a.b.glm:glm-5.2"
  touch "$BUS/limits/a.b.frozen"

  reap "$BUS" 15

  # frozen -> NOT requeued; correctly resolved id is "a.b", not "a" (old first-dot bug)
  [ -f "$BUS/claimed/a.b.glm:glm-5.2" ]
  [ ! -f "$BUS/queue/a.b.prompt" ]
}

@test "reap: a stale claim with a dotted id, once thawed, requeues to the exact dotted id" {
  bus_init "$BUS"
  echo "x" > "$BUS/queue/a.b.prompt"
  claim "$BUS" "a.b" "glm:glm-5.2"
  touch -d "-20 minutes" "$BUS/claimed/a.b.glm:glm-5.2"
  touch "$BUS/limits/a.b.frozen"

  reap "$BUS" 15
  [ -f "$BUS/claimed/a.b.glm:glm-5.2" ]

  rm -f "$BUS/limits/a.b.frozen"
  reap "$BUS" 15
  [ ! -f "$BUS/claimed/a.b.glm:glm-5.2" ]
  [ -f "$BUS/queue/a.b.prompt" ]
}

@test "reap: requeues claimed/<id>.kimi:kimi-k2.7-code to the exact id" {
  bus_init "$BUS"
  echo "x" > "$BUS/queue/a.b.prompt"
  claim "$BUS" "a.b" "kimi:kimi-k2.7-code"
  touch -d "-20 minutes" "$BUS/claimed/a.b.kimi:kimi-k2.7-code"

  reap "$BUS" 15

  [ -f "$BUS/queue/a.b.prompt" ]
  [ ! -e "$BUS/claimed/a.b.kimi:kimi-k2.7-code" ]
}

# --- audit fix: VERIFY_MAP must never let a lane verify its own output (loop-discipline.md) ------
# CRITICAL live finding: a mapping like "codex:codex" in VERIFY_MAP was honored as-is, letting a
# lane judge its own answer. Fix: verify_lane_for detects a self-mapped entry, logs a loud stderr
# warning, and falls back to the first EXEC_CHAIN lane whose bare name differs from the generator
# — or returns nonzero (no self-review) when every EXEC_CHAIN lane matches the generator too.

@test "verify_lane_for: VERIFY_MAP self-pair falls back to a differing EXEC_CHAIN lane and warns loudly" {
  VERIFY_MAP="codex:codex"
  EXEC_CHAIN="codex:default claude:opus"
  local result warning
  result="$(verify_lane_for codex 2>/dev/null)"
  warning="$(verify_lane_for codex 2>&1 1>/dev/null)"
  [ "$result" = "claude" ]
  [[ "$warning" == *"VERIFY_MAP maps codex to itself"* ]]
}

@test "verify_lane_for: VERIFY_MAP self-pair with no differing EXEC_CHAIN lane returns nonzero and warns" {
  VERIFY_MAP="codex:codex"
  EXEC_CHAIN="codex:default"
  local warning
  warning="$(verify_lane_for codex 2>&1 1>/dev/null)" || true
  run verify_lane_for codex
  [ "$status" -ne 0 ]
  [[ "$warning" == *"VERIFY_MAP maps codex to itself"* ]]
}

# --- P0-FR1: _run_label — THE one run-join-key derivation (plan-004 PRD phase 0) ------------------

@test "_run_label: explicit SPEEDWARS_RUN always wins over the derived default" {
  export SPEEDWARS_RUN="custom-run"
  local busdir="$BATS_TEST_TMPDIR/somewhere-else/.bus"
  mkdir -p "$busdir"
  [ "$(_run_label "$busdir")" = "custom-run" ]
}

@test "_run_label: SPEEDWARS_RUN beats a persisted .run-label — the operator override stays first" {
  export SPEEDWARS_RUN="env-wins"
  local busdir="$BATS_TEST_TMPDIR/prec/.bus"
  mkdir -p "$busdir"
  echo "persisted-loses" > "$busdir/.run-label"
  [ "$(_run_label "$busdir")" = "env-wins" ]
}

@test "_run_label: a persisted \$BUSDIR/.run-label wins over the derived default and warns nothing" {
  unset SPEEDWARS_RUN
  local busdir="$BATS_TEST_TMPDIR/some-checkout/.bus"
  mkdir -p "$busdir"
  echo "pinned-run" > "$busdir/.run-label"
  [ "$(_run_label "$busdir")" = "pinned-run" ]
  local err; err="$(_run_label "$busdir" 2>&1 1>/dev/null)"
  [ -z "$err" ]
}

@test "_run_label: an empty or whitespace-only .run-label is ignored, falling through to the default" {
  unset SPEEDWARS_RUN
  local busdir="$BATS_TEST_TMPDIR/empty-label/.bus"
  mkdir -p "$busdir"
  : > "$busdir/.run-label"
  [ "$(_run_label "$busdir" 2>/dev/null)" = "empty-label" ]
  printf '\n' > "$busdir/.run-label"
  [ "$(_run_label "$busdir" 2>/dev/null)" = "empty-label" ]
}

@test "_run_label: default for a plain .bus is the busdir's PARENT basename, never the busdir's own" {
  unset SPEEDWARS_RUN
  local busdir="$BATS_TEST_TMPDIR/my-repo/.bus"
  mkdir -p "$busdir"
  [ "$(_run_label "$busdir" 2>/dev/null)" = "my-repo" ]
  [ "$(_run_label "$busdir" 2>/dev/null)" != ".bus" ]
}

@test "F1: sibling buses in ONE checkout derive DISTINCT default labels from the .bus-<suffix> name" {
  unset SPEEDWARS_RUN
  local root="$BATS_TEST_TMPDIR/one-checkout"
  mkdir -p "$root/.bus-gtm-a" "$root/.bus-tok024" "$root/.bus"
  [ "$(_run_label "$root/.bus-gtm-a" 2>/dev/null)" = "gtm-a" ]
  [ "$(_run_label "$root/.bus-tok024" 2>/dev/null)" = "tok024" ]
  # ...and the plain .bus keeps today's parent-basename value, so existing ledger rows stay joinable
  [ "$(_run_label "$root/.bus" 2>/dev/null)" = "one-checkout" ]
  [ "$(_run_label "$root/.bus-gtm-a" 2>/dev/null)" != "$(_run_label "$root/.bus-tok024" 2>/dev/null)" ]
}

@test "_run_label: SPEEDWARS_RUN set never writes a warning to stderr" {
  export SPEEDWARS_RUN="quiet-run"
  local busdir="$BATS_TEST_TMPDIR/quiet/.bus"
  mkdir -p "$busdir"
  local err
  err="$(_run_label "$busdir" 2>&1 1>/dev/null)"
  [ -z "$err" ]
}

@test "_run_label: the derived-default warning names the shared-label hazard + the override, once per process" {
  unset SPEEDWARS_RUN
  local busdir="$BATS_TEST_TMPDIR/warn-repo/.bus"
  mkdir -p "$busdir"
  local out
  out="$( { _run_label "$busdir" >/dev/null; _run_label "$busdir" >/dev/null; _run_label "$busdir" >/dev/null; } 2>&1 )"
  [ "$(grep -c 'SPEEDWARS_RUN' <<<"$out")" -eq 1 ]
  [[ "$out" == *"warn-repo"* ]]
  [[ "$out" == *"SPEEDWARS_RUN"* ]]
  # the REAL hazard, not "two worktrees could collide": sibling buses sharing one ledger label
  [[ "$out" == *"ledger"* ]]
}

@test "F3: a read-only _run_label call writes NOTHING into the bus (no .run-label-warned marker)" {
  unset SPEEDWARS_RUN
  local busdir="$BATS_TEST_TMPDIR/readonly-repo/.bus"
  bus_init "$busdir"
  local before; before="$(find "$busdir" | sort)"
  _run_label "$busdir" >/dev/null 2>&1
  local after; after="$(find "$busdir" | sort)"
  [ "$before" = "$after" ]
  [ ! -e "$busdir/.run-label-warned" ]
}

@test "_run_label_persist: pins the resolved label into the bus; later reads need no env and no warning" {
  local busdir="$BATS_TEST_TMPDIR/persist-repo/.bus-w7"
  bus_init "$busdir"
  SPEEDWARS_RUN="wave7" _run_label_persist "$busdir"
  [ "$(<"$busdir/.run-label")" = "wave7" ]

  unset SPEEDWARS_RUN
  local err; err="$(_run_label "$busdir" 2>&1 1>/dev/null)"
  [ -z "$err" ]
  [ "$(_run_label "$busdir")" = "wave7" ]
}

@test "_run_label_persist: the LATEST run owns the bus — a second persist overwrites the first" {
  local busdir="$BATS_TEST_TMPDIR/reown/.bus"
  bus_init "$busdir"
  SPEEDWARS_RUN="run-one" _run_label_persist "$busdir"
  SPEEDWARS_RUN="run-two" _run_label_persist "$busdir"
  [ "$(<"$busdir/.run-label")" = "run-two" ]
  unset SPEEDWARS_RUN
  [ "$(_run_label "$busdir")" = "run-two" ]
}

@test "P0-FR1 acceptance: speed_row/run_summary/feedback_stubs all stamp the SAME .run join key with SPEEDWARS_RUN unset — jq [.run,.id]|sort|uniq -d over the fixture ledger is empty" {
  unset SPEEDWARS_RUN
  local root="$BATS_TEST_TMPDIR/join-repo"
  mkdir -p "$root/docs/ops" "$root/feedback"
  local bus="$root/.bus"
  bus_init "$bus"
  export SPEEDWARS_FILE="$root/docs/ops/speedwars.jsonl"

  echo '{"type":"end","stopReason":"EndTurn","num_turns":1,"total_cost_usd":0.01,"usage":{"input_tokens":1,"output_tokens":1}}' \
    > "$bus/run-c1.jsonl"
  speed_row "$bus" c1 "grok:grok-4.5" done 0 0
  run_summary "$bus" full
  touch "$bus/limits/x.parked"
  FEEDBACK_DIR="$root/feedback" feedback_stubs "$bus"

  run bash -c "jq -r '[.run,.id] | @tsv' '$SPEEDWARS_FILE' | sort | uniq -d"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  local runs
  runs="$(jq -r 'select(.run != null) | .run' "$SPEEDWARS_FILE" | sort -u)"
  [ "$(wc -l <<<"$runs")" -eq 1 ]
  [ "$runs" = "join-repo" ]
}

# --- P0-FR2 (repo half): doctor_skill_drift --------------------------------------------------------

@test "doctor_skill_drift: no installed copies anywhere -> PASS, not a false alarm on a bare box" {
  run doctor_skill_drift "$BATS_TEST_DIRNAME/.."
  [ "$status" -eq 0 ]
  [[ "$output" == "skill-drift  PASS"* ]]
}

@test "doctor_skill_drift: two differing regular-file copies -> FAIL naming the hash count" {
  mkdir -p "$HOME/.claude/skills/unimatrix" "$HOME/.claude-acct/acct1/skills/unimatrix"
  printf 'version A\n' > "$HOME/.claude/skills/unimatrix/SKILL.md"
  printf 'version B\n' > "$HOME/.claude-acct/acct1/skills/unimatrix/SKILL.md"

  run doctor_skill_drift "$BATS_TEST_DIRNAME/.."
  [ "$status" -ne 0 ]
  [[ "$output" == "skill-drift  FAIL"* ]]
  [[ "$output" == *"2 distinct hash"* ]]
}

@test "doctor_skill_drift: identical content but a hand-copy (not a symlink) still FAILs" {
  mkdir -p "$HOME/.claude/skills/unimatrix" "$HOME/.claude-acct/acct1/skills/unimatrix"
  printf 'same content\n' > "$HOME/.claude/skills/unimatrix/SKILL.md"
  printf 'same content\n' > "$HOME/.claude-acct/acct1/skills/unimatrix/SKILL.md"

  run doctor_skill_drift "$BATS_TEST_DIRNAME/.."
  [ "$status" -ne 0 ]
  [[ "$output" == "skill-drift  FAIL"* ]]
  [[ "$output" == *"not a symlink"* ]]
}

@test "doctor_skill_drift: every copy symlinked into the repo, one hash -> PASS" {
  local repo="$BATS_TEST_TMPDIR/fake-repo"
  mkdir -p "$repo/.claude/skills/unimatrix" "$HOME/.claude/skills/unimatrix" \
    "$HOME/.claude-acct/acct1/skills/unimatrix"
  printf 'canonical\n' > "$repo/.claude/skills/unimatrix/SKILL.md"
  ln -s "$repo/.claude/skills/unimatrix/SKILL.md" "$HOME/.claude/skills/unimatrix/SKILL.md"
  ln -s "$repo/.claude/skills/unimatrix/SKILL.md" "$HOME/.claude-acct/acct1/skills/unimatrix/SKILL.md"

  run doctor_skill_drift "$repo"
  [ "$status" -eq 0 ]
  [[ "$output" == "skill-drift  PASS"* ]]
}

@test "doctor_skill_drift: a symlink pointing OUTSIDE the repo (stale sibling worktree) FAILs even with a matching hash" {
  local repo="$BATS_TEST_TMPDIR/fake-repo2"
  local other="$BATS_TEST_TMPDIR/other-worktree"
  mkdir -p "$repo/.claude/skills/unimatrix" "$other/.claude/skills/unimatrix" \
    "$HOME/.claude/skills/unimatrix" "$HOME/.claude-acct/acct1/skills/unimatrix"
  printf 'canonical\n' > "$repo/.claude/skills/unimatrix/SKILL.md"
  printf 'canonical\n' > "$other/.claude/skills/unimatrix/SKILL.md"
  ln -s "$repo/.claude/skills/unimatrix/SKILL.md" "$HOME/.claude/skills/unimatrix/SKILL.md"
  ln -s "$other/.claude/skills/unimatrix/SKILL.md" "$HOME/.claude-acct/acct1/skills/unimatrix/SKILL.md"

  run doctor_skill_drift "$repo"
  [ "$status" -ne 0 ]
  [[ "$output" == "skill-drift  FAIL"* ]]
  [[ "$output" == *"outside the repo"* ]]
}

@test "#9 doctor_skill_drift: a symlink to some OTHER in-repo file (not the skill) FAILs" {
  local repo="$BATS_TEST_TMPDIR/repo9"
  mkdir -p "$repo/.claude/skills/unimatrix" "$HOME/.claude/skills/unimatrix"
  printf 'canonical\n' > "$repo/.claude/skills/unimatrix/SKILL.md"
  printf 'changelog\n' > "$repo/CHANGELOG.md"
  ln -s "$repo/CHANGELOG.md" "$HOME/.claude/skills/unimatrix/SKILL.md"

  run doctor_skill_drift "$repo"
  [ "$status" -ne 0 ]
  [[ "$output" == "skill-drift  FAIL"* ]]
}

@test "#10 doctor_skill_drift: a BROKEN symlink is a FAIL row, never 'no installed copies found'" {
  mkdir -p "$HOME/.claude/skills/unimatrix"
  ln -s "$BATS_TEST_TMPDIR/gone/SKILL.md" "$HOME/.claude/skills/unimatrix/SKILL.md"

  run doctor_skill_drift "$BATS_TEST_DIRNAME/.."
  [ "$status" -ne 0 ]
  [[ "$output" == "skill-drift  FAIL"* ]]
  [[ "$output" == *"broken symlink"* ]]
  [[ "$output" != *"no installed copies found"* ]]
}

@test "#12 doctor_skill_drift: still works with no GNU md5sum and no readlink -f (BSD/macOS)" {
  local repo="$BATS_TEST_TMPDIR/repo12"
  mkdir -p "$repo/.claude/skills/unimatrix" "$HOME/.claude/skills/unimatrix"
  printf 'canonical\n' > "$repo/.claude/skills/unimatrix/SKILL.md"
  ln -s "$repo/.claude/skills/unimatrix/SKILL.md" "$HOME/.claude/skills/unimatrix/SKILL.md"

  # BSD shims: md5sum absent entirely, readlink present but with no -f (macOS's own behavior)
  local stub="$BATS_TEST_TMPDIR/stub12"
  mkdir -p "$stub"
  printf '#!/usr/bin/env bash\nexit 127\n' > "$stub/md5sum"
  cat > "$stub/readlink" <<'STUB'
#!/usr/bin/env bash
[ "$1" = "-f" ] && { echo "readlink: illegal option -- f" >&2; exit 1; }
exec /bin/readlink "$@"
STUB
  chmod +x "$stub/md5sum" "$stub/readlink"

  PATH="$stub:$PATH" run doctor_skill_drift "$repo"
  [ "$status" -eq 0 ]
  [[ "$output" == "skill-drift  PASS"* ]]
}

@test "F11: doctor run from a sibling git WORKTREE of the same repo PASSes — links point at the main checkout" {
  local main="$BATS_TEST_TMPDIR/wt-main" wt="$BATS_TEST_TMPDIR/wt-side"
  mkdir -p "$main/.claude/skills/unimatrix"
  printf 'canonical\n' > "$main/.claude/skills/unimatrix/SKILL.md"
  git -c init.defaultBranch=public init -q "$main"
  git -C "$main" -c user.email=user@example.com -c user.name=t add -A
  git -C "$main" -c user.email=user@example.com -c user.name=t commit -qm init
  git -C "$main" worktree add -q -b side "$wt"

  mkdir -p "$HOME/.claude/skills/unimatrix"
  ln -s "$main/.claude/skills/unimatrix/SKILL.md" "$HOME/.claude/skills/unimatrix/SKILL.md"

  # repo_root is the WORKTREE, the link target lives in the main checkout: different paths, one
  # repository (same git-common-dir) — that is not drift.
  run doctor_skill_drift "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" == "skill-drift  PASS"* ]]
}

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

@test "speed_row: codex turn.completed envelope — tokens + turn count, no cost field" {
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
  [ "$(jq -r '.cost_usd // "absent"' "$SPEEDWARS_FILE")" = "absent" ]
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
