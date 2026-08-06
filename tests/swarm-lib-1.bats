#!/usr/bin/env bats
# Unit tests for src/swarm-lib.sh (shard 1 of 2 — loads tests/helpers/swarm-lib-fixture.bash):
# bus primitives (bus_init/claim/heartbeat/reap/gate_count), config precedence (conf_load),
# limit flags, jq firehose filter, kill_subtree, _scratch_home, _write_journal,
# _stagger_first_spawn, per-lane invocation (lane_cmd), answer normalization (extract_answer),
# served_model, rate-limit detection (limit_error), EXEC_CHAIN tracking, verify_lane_for,
# write_verify_spec, ledger_row, frozen-claim reap, _run_label, doctor_skill_drift.
#
# Project: unimatrix — multi-model swarm orchestrator driven from Claude Code
# Module:  tests/swarm-lib-1.bats
# Deps:    bats-core, src/swarm-lib.sh, tests/helpers/swarm-lib-fixture.bash
# Tested:  n/a — this is the test file (fixtures live under $BATS_TEST_TMPDIR, docs/02-build-pitfalls.md §9)

load 'helpers/swarm-lib-fixture'



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
  # spec 21 FR-15: 6 since 2026-07-31 (was 4 pre-namespacing)
  [ "$FANOUT" = "6" ]
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

@test "_scratch_home: codex mirrors config.toml when present — codex arm ONLY (spec 04 amendment 2026-07-26)" {
  bus_init "$BUS"
  mkdir -p "$HOME/.codex" "$HOME/.claude" "$HOME/.grok"
  echo '{"key":"real-codex-auth"}' > "$HOME/.codex/auth.json"
  echo 'model_reasoning_effort = "high"' > "$HOME/.codex/config.toml"
  echo '{"token":"real-session"}' > "$HOME/.claude/.credentials.json"
  echo '{"token":"real-grok-oauth"}' > "$HOME/.grok/auth.json"
  echo '[mcp_servers]' > "$HOME/.grok/config.toml"

  codex_home="$(_scratch_home "$BUS" codex)"
  [ "$(<"$codex_home/.codex/config.toml")" = 'model_reasoning_effort = "high"' ]
  [ "$(<"$codex_home/.codex/auth.json")" = '{"key":"real-codex-auth"}' ]

  # scope fence: grok's config.toml exclusion is a locked containment decision; claude untouched
  grok_home="$(_scratch_home "$BUS" grok)"
  [ ! -e "$grok_home/.grok/config.toml" ]
  claude_home="$(_scratch_home "$BUS" claude)"
  [ ! -e "$claude_home/.claude/config.toml" ]
}

@test "_scratch_home: codex without a real config.toml stays auth-only" {
  bus_init "$BUS"
  mkdir -p "$HOME/.codex"
  echo '{"key":"a"}' > "$HOME/.codex/auth.json"

  codex_home="$(_scratch_home "$BUS" codex)"
  [ "$(<"$codex_home/.codex/auth.json")" = '{"key":"a"}' ]
  [ ! -e "$codex_home/.codex/config.toml" ]
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

# --- _write_journal (spec 14 FR-8, backlog 59) ------------------------------------

@test "_write_journal: unique write-class paths from the worker stream, read-class noise ignored" {
  bus_init "$BUS"
  {
    printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/cage/readme.md"}}]}}'
    printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/cage/a.txt"}}]}}'
    printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/cage/a.txt"}},{"type":"tool_use","name":"Edit","input":{"file_path":"/cage/b.txt"}}]}}'
    printf '%s\n' '{"type":"result","result":"done"}'
  } > "$BUS/run-j1.jsonl"

  run _write_journal "$BUS" j1
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "/cage/a.txt" ]
  [ "${lines[1]}" = "/cage/b.txt" ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "_write_journal: empty or missing stream yields an empty journal, rc 0" {
  bus_init "$BUS"
  run _write_journal "$BUS" nolog
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- _stagger_first_spawn (spec 04 amendment 2026-07-26, backlog 20) --------------

@test "_stagger_first_spawn: first caller per lane claims the marker and returns immediately" {
  bus_init "$BUS"
  STAGGER_FIRST_SPAWN_SEC=10 _stagger_first_spawn "$BUS" grok g1
  [ -d "$BUS/limits/.first-grok" ]
  [ "$(<"$BUS/limits/.first-grok/id")" = "g1" ]
}

@test "_stagger_first_spawn: follower returns promptly once the first worker's run log has bytes" {
  bus_init "$BUS"
  STAGGER_FIRST_SPAWN_SEC=10 _stagger_first_spawn "$BUS" grok g1
  echo '{"type":"init"}' > "$BUS/run-g1.jsonl"
  local t0 t1
  t0=$(date +%s%N)
  STAGGER_FIRST_SPAWN_SEC=10 _stagger_first_spawn "$BUS" grok g2
  t1=$(date +%s%N)
  # first already produced output — follower must not sit out the bound
  (( (t1 - t0) / 1000000 < 3000 ))
}

@test "_stagger_first_spawn: follower actually waits for the first worker's output, then proceeds" {
  bus_init "$BUS"
  STAGGER_FIRST_SPAWN_SEC=10 _stagger_first_spawn "$BUS" grok g1
  ( sleep 0.6; echo '{"type":"init"}' > "$BUS/run-g1.jsonl" ) &
  PIDA=$!
  local t0 t1 ms
  t0=$(date +%s%N)
  STAGGER_FIRST_SPAWN_SEC=10 _stagger_first_spawn "$BUS" grok g2
  t1=$(date +%s%N)
  ms=$(( (t1 - t0) / 1000000 ))
  # waited for the bytes (>=400ms) but nowhere near the 10s bound
  (( ms >= 400 && ms < 5000 ))
  wait "$PIDA" 2>/dev/null || true
}

@test "_stagger_first_spawn: bound expires without first-worker output — returns 0, never parks the lane" {
  bus_init "$BUS"
  STAGGER_FIRST_SPAWN_SEC=1 _stagger_first_spawn "$BUS" grok g1
  run env STAGGER_FIRST_SPAWN_SEC=1 bash -c "source '$LIB'; _stagger_first_spawn '$BUS' grok g2"
  [ "$status" -eq 0 ]
}

@test "_stagger_first_spawn: STAGGER_FIRST_SPAWN_SEC=0 disables the gate entirely (no marker)" {
  bus_init "$BUS"
  STAGGER_FIRST_SPAWN_SEC=0 _stagger_first_spawn "$BUS" grok g1
  [ ! -e "$BUS/limits/.first-grok" ]
}

@test "_stagger_first_spawn: cross-lane parallelism untouched — lane B's first ignores lane A's marker" {
  bus_init "$BUS"
  STAGGER_FIRST_SPAWN_SEC=10 _stagger_first_spawn "$BUS" grok g1
  # no run-g1.jsonl bytes — a same-lane follower would wait; a different lane must not
  local t0 t1
  t0=$(date +%s%N)
  STAGGER_FIRST_SPAWN_SEC=10 _stagger_first_spawn "$BUS" claude c1
  t1=$(date +%s%N)
  (( (t1 - t0) / 1000000 < 3000 ))
  [ -d "$BUS/limits/.first-claude" ]
}

@test "conf_load: PROBE_AUTO baked default is 1 (spec 13 FR-6 auto-probes on for operators)" {
  run env -u PROBE_AUTO bash -c "source '$LIB'; conf_load /nonexistent; echo \$PROBE_AUTO"
  [ "$output" = "1" ]
}

@test "conf_load: STAGGER_FIRST_SPAWN_SEC baked default is 10 and file value overrides it" {
  conf_load /nonexistent
  [ "$STAGGER_FIRST_SPAWN_SEC" = "10" ]
  echo 'STAGGER_FIRST_SPAWN_SEC=0' > "$BATS_TEST_TMPDIR/conf"
  run env -u STAGGER_FIRST_SPAWN_SEC bash -c "source '$LIB'; conf_load '$BATS_TEST_TMPDIR/conf'; echo \$STAGGER_FIRST_SPAWN_SEC"
  [ "$output" = "0" ]
}

# --- lane_cmd ----------------------------------------------------------------
# lane_cmd populates the global LANE_ARGV array with the exact exec argv for a lane:model
# token (specs/01-swarm-core.md "Lane invocations"). The claim step has already moved the
# prompt file to claimed/<id>.<lane:model>, which is where lane_cmd reads it from.


@test "lane_cmd: claude lane — env -i'd, scratch HOME, no key injection" {
  bus_init "$BUS"
  _claim_prompt "claude:opus" c1 "hello claude"
  lane_cmd "claude:opus" c1 "$BUS"
  [ "${LANE_ARGV[0]}" = "env" ]
  [ "${LANE_ARGV[1]}" = "-i" ]
  expected="env -i PATH=$PATH HOME=$BUS/home/claude.c1 LANG=C.UTF-8 claude -p --output-format stream-json --verbose --model opus hello claude"
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
  expected="env -i -C $BUS/home/gemini.g1 PATH=$PATH HOME=$BUS/home/gemini.g1 LANG=C.UTF-8 GEMINI_CLI_TRUST_WORKSPACE=true GEMINI_API_KEY=test-gem-key gemini -m gemini-3-flash -o stream-json -p hello gemini"
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
  expected="env -i -C $BUS/home/gemini.gs0 PATH=$PATH HOME=$BUS/home/gemini.gs0 LANG=C.UTF-8 GEMINI_CLI_TRUST_WORKSPACE=true GEMINI_API_KEY=test-gem-key gemini -m gemini-3-flash -o stream-json -p hello gemini"
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
  expected="env -i PATH=$PATH HOME=$BUS/home/gemini.gs1 LANG=C.UTF-8 GEMINI_API_KEY=test-gem-key GEMINI_CLI_TRUST_WORKSPACE=true docker run --rm -i -e GEMINI_API_KEY -e GEMINI_CLI_TRUST_WORKSPACE unimatrix-gemini-lane:0.49.0 gemini -m gemini-3-flash -o stream-json -p hello gemini"
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
  expected="env -i PATH=$PATH HOME=$BUS/home/glm.m1 LANG=C.UTF-8 ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic ANTHROPIC_AUTH_TOKEN=test-glm-key ANTHROPIC_DEFAULT_HAIKU_MODEL=glm-5.2 ANTHROPIC_DEFAULT_SONNET_MODEL=glm-5.2 ANTHROPIC_DEFAULT_OPUS_MODEL=glm-5.2 API_TIMEOUT_MS=3000000 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 MAX_THINKING_TOKENS=${GLM_MAX_THINKING_TOKENS:-6000} claude -p --output-format stream-json --verbose hello glm"
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
  expected="env -i -C $BATS_TEST_TMPDIR/target1 PATH=$PATH HOME=$BUS/home/claude.cw1 LANG=C.UTF-8 claude -p --output-format stream-json --verbose --model opus --permission-mode acceptEdits write something"
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
  expected="env -i -C $BATS_TEST_TMPDIR/target2 PATH=$PATH HOME=$BUS/home/codex.cw2 LANG=C.UTF-8 codex exec --json --output-last-message $BUS/res-cw2.txt -s workspace-write --skip-git-repo-check -C $BATS_TEST_TMPDIR/target2 --ephemeral hello"
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
  expected="env -i PATH=$PATH HOME=$BUS/home/grok.gk1 LANG=C.UTF-8 grok -p hello grok --output-format streaming-json --no-auto-update --effort medium --tools read_file,grep,list_dir --no-subagents -m grok-4.5"
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
  expected="env -i -C $BATS_TEST_TMPDIR/targetgrok PATH=$PATH HOME=$BUS/home/grok.gkw1 LANG=C.UTF-8 grok -p write something --output-format streaming-json --no-auto-update --effort medium --allow Write --allow Edit --allow Create -m grok-4.5"
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
  expected="env -i PATH=$PATH HOME=$BUS/home/kimi.k1 LANG=C.UTF-8 ANTHROPIC_BASE_URL=https://api.moonshot.ai/anthropic ANTHROPIC_AUTH_TOKEN=test-kimi-key ANTHROPIC_DEFAULT_HAIKU_MODEL=kimi-k3 ANTHROPIC_DEFAULT_SONNET_MODEL=kimi-k3 ANTHROPIC_DEFAULT_OPUS_MODEL=kimi-k3 API_TIMEOUT_MS=3000000 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 MAX_THINKING_TOKENS=6000 claude -p --output-format stream-json --verbose hello kimi"
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
