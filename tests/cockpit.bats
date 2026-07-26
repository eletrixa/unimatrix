#!/usr/bin/env bats
# Tests for swarm-mon.sh: the read-only tmux cockpit (specs/02-cockpit.md, monitoring-runbook.md
# §3/§7/§8). Every test runs on a THROWAWAY tmux socket (never `-L swarm`) and a fixture bus under
# $BATS_TEST_TMPDIR — never the real .bus, never a live worker CLI. Panes call back into
# `swarm-mon.sh --render-*` for their actual content, which lets this file exercise the exact same
# board/firehose/cost logic the live panes run, directly and bounded (no tmux, no race on
# tail -F timing — docs/02-build-pitfalls.md §9).
#
# Project: unimatrix — multi-model swarm orchestrator driven from Claude Code
# Module:  tests/cockpit.bats
# Deps:    bats-core, swarm-mon.sh, src/swarm-lib.sh, tmux, jq
# Tested:  n/a — this is the test file

MON="$BATS_TEST_DIRNAME/../swarm-mon.sh"

setup() {
  BUS="$BATS_TEST_TMPDIR/bus"
  CONF="$BATS_TEST_TMPDIR/swarm.conf"
  SOCK="swarm-test-$$-${BATS_TEST_NUMBER:-0}"
  export BUSDIR="$BUS"
  export CONF
  export SWARM_TMUX_SOCK="$SOCK"
  printf 'LEASE_MIN=15\n' > "$CONF"
  mkdir -p "$BUS"/{specs,queue,claimed,done,cancelled,limits}
}

teardown() {
  tmux -L "$SOCK" kill-server 2>/dev/null || true
  return 0
}

# --- session bootstrap --------------------------------------------------------

@test "swarm-mon.sh: builds a tmux session with exactly 4 panes" {
  run "$MON"
  [ "$status" -eq 0 ]

  run tmux -L "$SOCK" has-session -t mon
  [ "$status" -eq 0 ]

  run tmux -L "$SOCK" list-panes -t mon:cockpit
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 4 ]
}

@test "swarm-mon.sh: idempotent — second run is a no-op, still exactly one session/4 panes" {
  run "$MON"
  [ "$status" -eq 0 ]
  run "$MON"
  [ "$status" -eq 0 ]

  run tmux -L "$SOCK" list-sessions
  [ "${#lines[@]}" -eq 1 ]

  run tmux -L "$SOCK" list-panes -t mon:cockpit
  [ "${#lines[@]}" -eq 4 ]
}

@test "swarm-mon.sh: --wezterm is non-fatal when the /mnt/c binary is unreachable" {
  # This box has no /mnt/c WezTerm binary in a bats sandbox either way — asserts the documented
  # fallback (specs/02-cockpit.md FR-6): the tmux session still builds even if the attach fails.
  run "$MON" --wezterm
  [ "$status" -eq 0 ]
  run tmux -L "$SOCK" has-session -t mon
  [ "$status" -eq 0 ]
}

# --- firehose pipeline (run directly, bounded — NOT inside tmux) --------------

_write_run_fixture() {
  # One event per line: known types (incl. the newly-added assistant/system), an unknown type,
  # and a non-JSON banner line (e.g. gemini's stderr-shaped junk that leaked onto stdout).
  cat > "$BUS/run-fx.jsonl" <<'JSONL'
{"type":"tool_use","message":{"content":[{"text":"reading file"}]}}
{"type":"assistant","message":{"content":[{"text":"thinking"}]}}
{"type":"system","subtype":"init"}
not json at all
{"type":"nope","result":"should be dropped"}
{"type":"result","result":"final answer"}
JSONL
}

@test "firehose: known types (incl. assistant/system) pass, unknown types and non-JSON are dropped" {
  _write_run_fixture
  run timeout 2 "$MON" --render-firehose
  # tail -F never exits on its own; timeout's kill is expected, not a failure of the pipeline itself.
  [[ "$status" -eq 0 || "$status" -eq 124 ]]

  [[ "$output" == *"tool_use"* ]]
  [[ "$output" == *"assistant"* ]]
  [[ "$output" == *"system"* ]]
  [[ "$output" == *"result"* ]]
  [[ "$output" != *"nope"* ]]
  [[ "$output" != *"not json"* ]]
}

@test "firehose: started against an empty bus doesn't wedge on the unmatched glob and picks up a run file created just after" {
  # no run-*.jsonl yet — pre-fix this tailed the literal 'run-*.jsonl' and never showed the real file
  ( timeout 6 "$MON" --render-firehose > "$BATS_TEST_TMPDIR/fh.out" 2>&1 ) &
  local fhjob=$!
  sleep 1
  printf '{"type":"result","result":"late fixture answer"}\n' > "$BUS/run-late.jsonl"
  for _ in $(seq 1 30); do grep -q "late fixture answer" "$BATS_TEST_TMPDIR/fh.out" && break; sleep 0.2; done
  kill "$fhjob" 2>/dev/null || true
  pkill -f "render-firehose" 2>/dev/null || true
  grep -q "late fixture answer" "$BATS_TEST_TMPDIR/fh.out"
}

# --- board (run directly, bounded — NOT inside tmux) --------------------------

_claim() { : > "$BUS/claimed/$1"; }
_done() { : > "$BUS/done/$1"; }
_queue() { : > "$BUS/queue/$1.prompt"; }

@test "board: renders QUEUED/CLAIMED/DONE/CANCELLED counts for a fixture bus state" {
  _queue b1
  _queue b2
  _claim c1.claude:opus
  _done d1
  : > "$BUS/cancelled/e1.prompt"

  run "$MON" --render-board
  [ "$status" -eq 0 ]
  # regex pins each count to ITS label (all four render on one line — a `*LABEL*N*` glob would
  # match the digit anywhere later in the line, passing green on a wrong/swapped count)
  [[ "$output" =~ QUEUED[[:space:]]+2 ]]
  [[ "$output" =~ CLAIMED[[:space:]]+1 ]]
  [[ "$output" =~ DONE[[:space:]]+1 ]]
  [[ "$output" =~ CANCELLED[[:space:]]+1 ]]
}

@test "board: QUEUED count is one unit of work per spec — .lane/.write sidecars do not inflate it" {
  _queue p1
  echo "gemini:gemini-3-flash" > "$BUS/queue/p1.lane"
  echo "/tmp/target" > "$BUS/queue/p1.write"
  _queue p2

  run "$MON" --render-board
  [ "$status" -eq 0 ]
  # two prompts = QUEUED 2, not 4 (sidecars are not separate work units — matches gate_count)
  [[ "$output" =~ QUEUED[[:space:]]+2 ]]
}

@test "board: flags a stale lease past LEASE_MIN" {
  _claim stale1.claude:opus
  touch -d "-20 minutes" "$BUS/claimed/stale1.claude:opus"
  _claim fresh1.claude:opus

  run "$MON" --render-board
  [ "$status" -eq 0 ]
  [[ "$output" == *"stale1"* ]]
  [[ "$output" != *"fresh1"* ]]
}

@test "board: lists an active limit flag and a parked branch" {
  printf '18000' > "$BUS/limits/glm.limited"
  : > "$BUS/limits/pin2.parked"

  run "$MON" --render-board
  [ "$status" -eq 0 ]
  [[ "$output" == *"glm"* ]]
  [[ "$output" == *"pin2"* ]]
}

@test "board: an expired limit flag is not reported as active" {
  printf '5' > "$BUS/limits/codex.limited"
  touch -d "-1 hour" "$BUS/limits/codex.limited"

  run "$MON" --render-board
  [ "$status" -eq 0 ]
  [[ "$output" != *"codex"* ]]
}

@test "board: lists a dead lane under DEAD LANES (spec 12 FR-6)" {
  : > "$BUS/limits/claude.dead"

  run "$MON" --render-board
  [ "$status" -eq 0 ]
  [[ "$output" == *"DEAD LANES:"* ]]
  [[ "$output" == *"claude"* ]]
}

@test "board: no DEAD LANES section when no lane is dead" {
  run "$MON" --render-board
  [ "$status" -eq 0 ]
  [[ "$output" != *"DEAD LANES:"* ]]
}

@test "board: lists a broken lane under DEAD LANES as (broken) (spec 13 FR-3)" {
  touch "$BUS/limits/grok.broken"

  run "$MON" --render-board
  [ "$status" -eq 0 ]
  [[ "$output" == *"DEAD LANES:"* ]]
  [[ "$output" == *"grok (broken)"* ]]
}

@test "board: lists dead and broken lanes together under one DEAD LANES section" {
  : > "$BUS/limits/claude.dead"
  touch "$BUS/limits/grok.broken"

  run "$MON" --render-board
  [ "$status" -eq 0 ]
  [[ "$(echo "$output" | grep -c "^DEAD LANES:$")" -eq 1 ]]
  [[ "$output" == *"  claude"* ]]
  [[ "$output" == *"  grok (broken)"* ]]
}

# --- cost fallback (run directly, single-shot) --------------------------------

@test "cost fallback: sums per-lane tokens from codex/claude/gemini envelope shapes" {
  cat > "$BUS/run-cx.jsonl" <<'JSONL'
{"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":10,"output_tokens":20}}
{"type":"result","usage":{"input_tokens":5,"output_tokens":7}}
{"type":"result","stats":{"models":{"gemini-3-flash":{"input":3,"output":4}}}}
JSONL

  run "$MON" --render-cost-once
  [ "$status" -eq 0 ]
  [[ "$output" == *"codex"*"130"* ]]
  [[ "$output" == *"claude/glm"*"12"* ]]
  [[ "$output" == *"gemini"*"7"* ]]
}

# --- .broken TTL: the board must agree with the router (round-4 MED) ----------

@test "board: an EXPIRED .broken marker is not rendered — routing already treats the lane as healthy" {
  printf '1' > "$BUS/limits/glm.broken"      # 1s TTL
  touch -d '1 minute ago' "$BUS/limits/glm.broken"
  touch "$BUS/limits/grok.broken"            # fresh, default TTL — still broken

  run "$MON" --render-board
  [ "$status" -eq 0 ]
  [[ "$output" == *"grok (broken)"* ]]
  [[ "$output" != *"glm (broken)"* ]]
}

# --- client replay->live boundary (round-4 MAJ, site/cockpit/data.js) ---------
#
# Runs the node harness that imports data.js with stubbed EventSource/fetch/localStorage: no
# browser, no server, no network. Skipped (not failed) where node is absent.

@test "cockpit client: replay-done finalizes backfill coalesces so the first live event counts" {
  command -v node >/dev/null 2>&1 || skip "node not installed"
  run node "$BATS_TEST_DIRNAME/cockpit-replay-boundary.mjs"
  [ "$status" -eq 0 ]
  [[ "$output" == *"replay->live boundary"* ]]
}
