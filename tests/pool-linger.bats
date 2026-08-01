#!/usr/bin/env bats
# RED-phase driver tests for spec 21 FR-1 (POOL_LINGER_SEC): a drained pool keeps polling queue/
# for a configurable window (default 0) before breaking, so a mid-run add is served by the SAME
# invocation without a full engine relaunch. None of this exists in _run_pool yet — today it breaks
# unconditionally the tick the close condition (`done_n + parked_n >= live_n && running == 0`) first
# holds. The NEW-behavior test (post-drain add served) therefore FAILS today on a plain assertion;
# the default-0 and self-exit tests pin behavior FR-1 must PRESERVE, so they pass today and must stay
# green after implementation (mirrors the control/guard cases in tests/swarm-run.bats's spec10 wave).
#
# Project: unimatrix — multi-model swarm orchestrator driven from Claude Code
# Module:  tests/pool-linger.bats
# Deps:    bats-core, src/swarm-lib.sh, swarm-run.sh, fake claude on PATH
# Tested:  n/a — this is the test file
#
# Design constraints:
# - Fakes read behavior from $BIN/fake.conf (sourced off the fake's OWN dirname), NOT inherited env —
#   lane_cmd wraps every real invocation in `env -i`, which would strip any FAKE_* env knob a bare
#   export relied on. Tests call `_fake NAME value`, exactly as tests/swarm-run.bats does.
# - POOL_LINGER_SEC is set per-test as a conf line (FR-1 is a conf key) and is NEVER exported in
#   setup — a global export would contaminate the default-0 test. It reaches _run_pool through
#   conf_load's `source "$conffile"` (which sets the shell var) plus the pool's own subshell
#   inheritance; today's _run_pool simply never reads it.
# - "the pool exited" is observed via $BUS/run.pgid going away (written by _drive_pool, removed the
#   instant _run_pool breaks), NOT via `kill -0` on the driver pid — a reaped-but-unwaited driver
#   stays a zombie and `kill -0` would keep succeeding, producing a false "still alive".

RUNSH="$BATS_TEST_DIRNAME/../swarm-run.sh"

setup() {
  BUS="$BATS_TEST_TMPDIR/bus"
  CONF="$BATS_TEST_TMPDIR/swarm.conf"
  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN"
  export PATH="$BIN:$PATH"
  export BUSDIR="$BUS"
  export CONF
  # HEARTBEAT_SEC=1 drives the pool's existing ~1s tick — the same cadence FR-1's linger rides on.
  export HEARTBEAT_SEC=1
  # full_run calls mon_web_ensure/mon_web_open (specs/05); the default MON_AUTOOPEN=1/MON_PORT=4747
  # would probe/spawn against the REAL port 4747 — disable for every test in this file.
  export MON_AUTOOPEN=0
  # _scratch_home (src/swarm-lib.sh) reads $HOME/.claude, $HOME/.codex — never let a test touch the
  # real user's credentials; every test gets its own throwaway "real" home instead.
  export HOME="$BATS_TEST_TMPDIR/realhome"
  mkdir -p "$HOME"
  # _scratch_home honors CLAUDE_CONFIG_DIR (multi-account setups) — unset so this box's ambient
  # session dir never leaks real credentials into a test's throwaway scratch home.
  unset CLAUDE_CONFIG_DIR
  # spec 13 FR-1: env_master_preflight aborts a run whose lane set touches gemini/glm/kimi when
  # $ENV_MASTER_FILE is unreadable. This file's conf is claude-only (no env-key lane), so preflight
  # is a no-op pass regardless — but seed the default anyway to match the swarm-run.bats idiom and
  # stay safe the day a test here adds an env-key lane.
  printf 'Z_AI_CODING_KEY=default-glm-key\nMOONSHOT_API_KEY=default-kimi-key\nGEMINI_API_KEY=default-gem-key\n' \
    > "$BATS_TEST_TMPDIR/envmaster-default"
  export ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster-default"
  # auto live-probes default ON for operators — OFF for this suite, or every test would fire a probe
  # per lane (extra fake invocations, ledger rows into the repo's real docs/ops for unguarded runs).
  export PROBE_AUTO=0
  # Every test here finalizes at least one card; LEDGER_AUTO=1 (default) would auto-append run-
  # evidence rows. Pin LEDGER_FILE to a tmp path so none can ever land in the repo's real docs/ops.
  # (The default path is already busdir-parent-relative → tmp, but the task asks for this explicitly.)
  export LEDGER_FILE="$BATS_TEST_TMPDIR/ledger.md"
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

# _fake <NAME> <value> — appends NAME="value" to $BIN/fake.conf (bash-%q-escaped), which the fake
# CLI sources on its own via ${BASH_SOURCE[0]}'s dirname. A FILE, not an env var, on purpose: it must
# survive lane_cmd's `env -i` wrapping of the real invocation.
_fake() { printf '%s=%q\n' "$1" "$2" >> "$BIN/fake.conf"; }

# Minimal fake claude (the only lane this suite's single-lane conf exercises): the default path of
# tests/swarm-run.bats's fake — source fake.conf, optional delay, emit init + one result event whose
# .result field is the answer extract_answer normalizes into res-<id>.txt.
_install_fakes() {
  : > "$BIN/fake.conf"
  cat > "$BIN/claude" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$_here/fake.conf" ]] && source "$_here/fake.conf"
sleep "${FAKE_CLAUDE_DELAY:-0}"
echo '{"type":"init"}'
printf '{"type":"result","result":"%s"}\n' "${FAKE_CLAUDE_RESULT:-OK}"
exit "${FAKE_CLAUDE_EXIT:-0}"
FAKE
  chmod +x "$BIN/claude"
}

_write_conf() {
  cat > "$CONF" <<EOF
EXEC_CHAIN="${1:-claude:opus}"
FANOUT=${2:-4}
LEASE_MIN=${3:-15}
EOF
}

_enqueue() {
  local id="$1" text="$2"
  mkdir -p "$BUS/specs"
  printf '%s' "$text" > "$BUS/specs/$id.prompt"
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

@test "FR-1 default-0: unset linger closes immediately — a card dropped in queue/ AFTER the run exited is never served" {
  # Regression guard for FR-1's invariant: POOL_LINGER_SEC default 0 MUST preserve today's exact
  # behavior (close the instant the gate first holds). PASSES today and must stay green post-impl —
  # a nonzero default is explicitly rejected by the spec (it would slow every swarm-loop iteration).
  _write_conf "claude:opus" 4 15
  # POOL_LINGER_SEC deliberately absent from the conf -> ${POOL_LINGER_SEC:-0} -> 0 (immediate close)
  _fake FAKE_CLAUDE_RESULT "first answer"
  _enqueue d1 "single card that drains the pool"

  run timeout 30 "$RUNSH" ""
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/d1" ]

  # The run already exited (foreground); a brand-new card landed in queue/ now has no live pool to
  # claim it — it stays put, unserved, with no done marker and no res file.
  mkdir -p "$BUS/queue"
  printf '%s' "arrived after close" > "$BUS/queue/d2.prompt"
  [ -f "$BUS/queue/d2.prompt" ]
  [ ! -e "$BUS/done/d2" ]
  [ ! -e "$BUS/res-d2.txt" ]
}

@test "FR-1 linger: POOL_LINGER_SEC=8 — a card added to queue/ AFTER drain is served by the SAME invocation, no relaunch" {
  # RED today: _run_pool's close-check sits BEFORE the claim loop and breaks unconditionally, so the
  # tick pl1's done marker lands in is the tick the pool exits. By the time _poll observes done/pl1
  # and we drop pl2 into queue/, the pool is already gone — pl2 is never claimed and done/pl2 never
  # appears. PASSES once _run_pool records a drain time and keeps polling queue/ for POOL_LINGER_SEC
  # seconds before breaking.
  _write_conf "claude:opus" 4 15
  cat >> "$CONF" <<'EOF'
POOL_LINGER_SEC=8
EOF
  _fake FAKE_CLAUDE_RESULT "served by lingering pool"
  _enqueue pl1 "first card drains the pool"
  # pl2 is NOT pre-seeded into specs/ — it is dropped straight into queue/ mid-run (the post-drain
  # `swarm-ctl add` shape linger exists to absorb), so only pl1 is in flight at launch.

  "$RUNSH" "" 3>&- &
  BG_PIDS+=("$!")

  _poll 15 test -f "$BUS/done/pl1" || { echo "FR-1 linger: pl1 never drained" >&2; false; }
  [ -f "$BUS/done/pl1" ]

  # The post-drain add: a brand-new card straight into queue/, no second $RUNSH launched.
  mkdir -p "$BUS/queue"
  printf '%s' "second card added after drain" > "$BUS/queue/pl2.prompt"

  # Decisive: the SAME invocation is still polling queue/ and serves pl2.
  _poll 15 test -f "$BUS/done/pl2" \
    || { echo "FR-1 linger: pl2 was NOT served under POOL_LINGER_SEC=8 — pool closed immediately on drain" >&2; false; }
  [ -f "$BUS/done/pl2" ]
  [ "$(<"$BUS/res-pl2.txt")" = "served by lingering pool" ]
  # The bg $RUNSH was still alive the instant pl2 landed (it lingered; it did NOT exit at pl1's drain
  # the way today's unconditional break does). Safe to assert here: done/pl2 only exists because the
  # pool claimed it, and the driver is still blocked in _drive_pool's wait on the lingering pool.
  kill -0 "${BG_PIDS[0]}" 2>/dev/null \
    || { echo "FR-1 linger: bg invocation was gone when pl2 landed — it did not linger" >&2; false; }

  # Let the reset drain window expire (run.pgid is dropped the instant _run_pool breaks) then reap.
  # Bounded so a buggy close can never hang the suite; the decisive assertions above already passed.
  _poll 25 test ! -e "$BUS/run.pgid" \
    || { echo "FR-1 linger: pool did not self-close within 25s after pl2" >&2; kill -9 "${BG_PIDS[0]}" 2>/dev/null || true; false; }
  wait "${BG_PIDS[0]}" 2>/dev/null || true
  BG_PIDS=()
}

@test "FR-1 linger: POOL_LINGER_SEC=2 with no new work — the pool still self-exits (never hangs)" {
  # Hang guard for FR-1: a nonzero linger must still BREAK once the window expires with no new work,
  # not spin forever polling an empty queue. PASSES today (the unconditional break exits even faster)
  # and must stay green post-impl. The point is "it exits at all"; the 10s ceiling generously absorbs
  # the 2s linger + close-out + suite load — deliberately not a tight lower bound on the 2s, which a
  # sleep-based assertion would flake on under load.
  _write_conf "claude:opus" 4 15
  cat >> "$CONF" <<'EOF'
POOL_LINGER_SEC=2
EOF
  _fake FAKE_CLAUDE_RESULT "OK"
  _enqueue l1 "single card, no late adds"

  "$RUNSH" "" 3>&- &
  BG_PIDS+=("$!")

  _poll 15 test -f "$BUS/done/l1" || { echo "FR-1 linger: l1 never drained" >&2; false; }

  # Once the 2s window expires with no new work, _run_pool breaks and _drive_pool drops run.pgid —
  # the file-based "pool gone" signal (kill -0 on the driver would false-positive on its zombie).
  _poll 10 test ! -e "$BUS/run.pgid" \
    || { echo "FR-1 linger: pool still alive 10s after drain — did not self-close (hang)" >&2; false; }

  wait "${BG_PIDS[0]}" 2>/dev/null || true
  BG_PIDS=()
}
