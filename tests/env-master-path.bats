#!/usr/bin/env bats
# RED-wave tests for spec 21 FR-8 (env-master candidate resolution). FR-8 introduces ONE helper,
# _env_master_path, used by BOTH _env_master_key and env_master_preflight so the twin defaults may
# never disagree. Candidate order: explicit $ENV_MASTER_FILE (authoritative even if unreadable — loud
# abort, no silent fallback); else the first READABLE of $XDG_CONFIG_HOME/unimatrix/env.master,
# $HOME/s/.env.master. The preflight abort names the env key(s) the tripping lane(s) need (e.g.
# Z_AI_CODING_KEY for glm) and prints a copy-paste "export ENV_MASTER_FILE=…" line for any readable
# candidate found elsewhere.
#
# RED-phase: _env_master_path and the twin-default refactor do NOT exist yet, so every test below
# fails on its ASSERTIONS, never on a harness error — setup() sources the lib and points HOME/
# XDG_CONFIG_HOME at throwaway dirs only; it never calls an unimplemented symbol, and the file
# parses cleanly under `bats --count`.
#
# Project: unimatrix — multi-model swarm orchestrator driven from Claude Code
# Module:  tests/env-master-path.bats
# Deps:    bats-core, src/swarm-lib.sh
# Tested:  n/a — this is the test file
#
# Design constraints:
# - Pure-function tests (source src/swarm-lib.sh, same idiom as tests/swarm-lib.bats); no fakes, no
#   pool, no real CLI. Each test binds its own HOME + XDG_CONFIG_HOME so candidate resolution never
#   touches the real user's ~/.config or ~/s secrets nor inherits this box's ambient values.
# - ENV_MASTER_FILE is unset in setup (in case the host exported it) and set explicitly only by the
#   two cases that exercise the explicit-is-authoritative arm.
# - Lane-set seeding (_glm_lane_set) binds REVIEW/REVIEW_CHAIN too, so env_master_preflight's
#   unquoted `$REVIEW` read can't trip `set -u` when conf_load hasn't run in this test.
# - Calls into not-yet-implemented symbols go through `run`, so a missing _env_master_path surfaces
#   as a failed `[ "$status" -eq 0 ]` assertion (status 127), not an errexit abort of the test body.

setup() {
  LIB="$BATS_TEST_DIRNAME/../src/swarm-lib.sh"
  # shellcheck source=/dev/null
  source "$LIB"
  BUS="$BATS_TEST_TMPDIR/bus"
  # Throwaway HOME + XDG_CONFIG_HOME per test (BATS_TEST_TMPDIR is unique per test): candidate
  # resolution reads exactly these, never the real user's dirs. Empty by default — a test that wants
  # a readable candidate creates the file itself.
  export HOME="$BATS_TEST_TMPDIR/home"
  export XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/xdg"
  mkdir -p "$HOME" "$XDG_CONFIG_HOME"
  unset ENV_MASTER_FILE
  # _scratch_home honors CLAUDE_CONFIG_DIR (multi-account); unset so this box's ambient account dir
  # can't leak — matches the swarm-lib.bats containment idiom (not needed for path resolution itself).
  unset CLAUDE_CONFIG_DIR
}

# _glm_lane_set — seed env_master_preflight's lane union (EXEC_CHAIN ∪ REVIEW ∪ REVIEW_CHAIN ∪
# *.lane pins) with a single glm token so its needs_key check trips on the env-key lane glm. Binds
# REVIEW/REVIEW_CHAIN to empty (set, not unset) so the function's unquoted `$REVIEW` read is safe
# under set -u without a conf_load call.
_glm_lane_set() {
  EXEC_CHAIN="glm:glm-5.2"
  REVIEW=""
  REVIEW_CHAIN=""
}

# --- _env_master_path: candidate resolution order --------------------------------------------

@test "_env_master_path: explicit ENV_MASTER_FILE returned verbatim even when unreadable" {
  # Explicit is authoritative: the helper returns the set path WITHOUT checking readability
  # (readability is the caller's concern — _env_master_key errors loudly, preflight aborts loudly,
  # but neither silently falls through to another candidate). Today _env_master_path doesn't exist.
  export ENV_MASTER_FILE="/nonexistent/env.master"
  run _env_master_path
  [ "$status" -eq 0 ]
  [ "$output" = "/nonexistent/env.master" ]
}

@test "_env_master_path: unset ENV_MASTER_FILE, XDG candidate readable -> XDG path returned" {
  mkdir -p "$XDG_CONFIG_HOME/unimatrix"
  printf 'Z_AI_CODING_KEY=x\n' > "$XDG_CONFIG_HOME/unimatrix/env.master"
  run _env_master_path
  [ "$status" -eq 0 ]
  [ "$output" = "$XDG_CONFIG_HOME/unimatrix/env.master" ]
}

@test "_env_master_path: unset ENV_MASTER_FILE, XDG missing, HOME/s readable -> HOME/s path returned" {
  mkdir -p "$HOME/s"
  printf 'Z_AI_CODING_KEY=x\n' > "$HOME/s/.env.master"
  # XDG candidate deliberately absent — second candidate wins.
  run _env_master_path
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/s/.env.master" ]
}

@test "_env_master_path: unset ENV_MASTER_FILE, neither readable -> XDG default path returned (abort-message default)" {
  # No candidate exists anywhere. The helper still echoes the XDG default path (never empty, never an
  # error) so env_master_preflight's abort message can name a concrete "expected here" location.
  run _env_master_path
  [ "$status" -eq 0 ]
  [ "$output" = "$XDG_CONFIG_HOME/unimatrix/env.master" ]
}

# --- twin-default agreement: _env_master_key and env_master_preflight share one resolver ------

@test "FR-8 twin defaults agree: key only at HOME/s, glm lane -> preflight passes AND _env_master_key finds it there" {
  # The key file exists ONLY at $HOME/s/.env.master — NOT at the XDG default. Both _env_master_key
  # and env_master_preflight must resolve through the SAME _env_master_path to that one readable
  # candidate (the "twin defaults may never disagree" invariant): preflight passes, and the key is
  # grepped out of that same file. Today both still use the old XDG-only default, so neither finds
  # it — preflight aborts (status 1) and _env_master_key returns 1.
  _glm_lane_set
  bus_init "$BUS"
  mkdir -p "$HOME/s"
  printf 'Z_AI_CODING_KEY=twin-key\n' > "$HOME/s/.env.master"

  run env_master_preflight "$BUS"
  [ "$status" -eq 0 ]

  run _env_master_key Z_AI_CODING_KEY
  [ "$status" -eq 0 ]
  [ "$output" = "twin-key" ]
}

# --- preflight abort fidelity ----------------------------------------------------------------

@test "FR-8 abort: no readable candidate anywhere, glm lane -> nonzero, stderr names Z_AI_CODING_KEY + carries an export line" {
  # No XDG file, no HOME/s file, no ENV_MASTER_FILE — nothing readable anywhere. The abort must (a)
  # return nonzero, (b) name the SPECIFIC env key the tripping lane needs (Z_AI_CODING_KEY for glm,
  # not just "gemini/glm/kimi"), and (c) still carry a copy-paste export line. Today the abort names
  # only the lane family, never the key, so the Z_AI_CODING_KEY assertion fails.
  _glm_lane_set
  bus_init "$BUS"
  run env_master_preflight "$BUS"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Z_AI_CODING_KEY"* ]]
  [[ "$output" == *"export ENV_MASTER_FILE="* ]]
}

@test "FR-8 explicit-unreadable: ENV_MASTER_FILE=/nonexistent + readable HOME/s -> still aborts (no silent fallback) and export line names the readable candidate" {
  # Explicit $ENV_MASTER_FILE is authoritative even when unreadable: preflight must NOT silently
  # fall through to the readable $HOME/s candidate (it still aborts, status nonzero) — but the abort
  # SHOULD point the operator at that readable candidate via the export line. Today the export line
  # is generic ("export ENV_MASTER_FILE=<your secrets file>"), never the discovered candidate path,
  # so the candidate-path assertion fails.
  _glm_lane_set
  bus_init "$BUS"
  export ENV_MASTER_FILE="/nonexistent/env.master"
  mkdir -p "$HOME/s"
  printf 'Z_AI_CODING_KEY=x\n' > "$HOME/s/.env.master"

  run env_master_preflight "$BUS"
  [ "$status" -ne 0 ]                                  # explicit authoritative: NO silent fallback
  local want="$HOME/s/.env.master"
  [[ "$output" == *"export ENV_MASTER_FILE=$want"* ]]  # quoted $want -> literal path in the pattern
}
