# Shared fixture for the swarm-lib.bats shards: setup/teardown plus the _claim_prompt helper
# used on both sides of the split — extracted verbatim from the former tests/swarm-lib.bats
# preamble so tests/swarm-lib-{1,2}.bats can `load` one copy.
#
# Project: unimatrix — multi-model swarm orchestrator driven from Claude Code
# Module:  tests/helpers/swarm-lib-fixture.bash
# Deps:    bats-core, src/swarm-lib.sh
# Tested:  n/a — test fixture, exercised by tests/swarm-lib-{1,2}.bats

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

_claim_prompt() {
  local worker="$1" id="$2" text="$3"
  mkdir -p "$BUS/claimed"
  printf '%s' "$text" > "$BUS/claimed/$id.$worker"
}
