#!/usr/bin/env bats
# RED-phase tests for spec 21 FR-6/FR-7: the --busdir flag and the ancestor-bus hint. These assert
# behavior that is NOT YET IMPLEMENTED — there is no --busdir arm in swarm-run.sh's option loop and
# no FR-7 hint in _refuse_empty_run today — so the positive cases below fail now on a test ASSERTION
# (never a harness error: the file parses under `bats --count` and setup() touches only features that
# already exist). The one negative case (no hint when no ancestor bus) is a regression guard: it is
# vacuously green until the hint exists, then pins it to the conditional branch (it would only fail if
# an implementation printed the hint unconditionally).
#
# Project: unimatrix — multi-model swarm orchestrator driven from Claude Code
# Module:  tests/busdir-flag.bats
# Deps:    bats-core, src/swarm-lib.sh, swarm-run.sh, fake claude on PATH, git (FR-7 fixtures)
# Tested:  n/a — this is the test file
#
# Design constraints:
# - Driver tests modeled on tests/swarm-run.bats's spec-20 --run fixtures: PATH-shimmed fake CLIs
#   under $BATS_TEST_TMPDIR/bin reading $BIN/fake.conf (never inherited env — lane_cmd wraps real
#   invocations in `env -i` for containment, which would strip every FAKE_* env knob), BUSDIR/CONF/
#   HOME exported to tmp, MON_AUTOOPEN=0 + HEARTBEAT_SEC=1, PROBE_AUTO=0 (none of these tests are
#   about probes), a working ENV_MASTER_FILE default, and LEDGER_FILE pinned to tmp so a finalized
#   card can never land a row in the repo's real docs/ops.
# - Assert on the DECISIVE fact (the done marker in the named bus; the ancestor path substring in the
#   abort text) — never full-output equality.
# - FR-6 precedence under test: --busdir is an explicit assignment that beats --run derivation AND
#   beats an ambient BUSDIR env (spec 21: "last writer in the option loop wins over env"). Test 2 keeps
#   the suite's tmp BUSDIR exported on purpose so the run aborts on a known-empty tmp bus under RED
#   instead of the repo's real .bus, and so GREEN proves --busdir routed past the env.

RUNSH="$BATS_TEST_DIRNAME/../swarm-run.sh"

setup() {
  BUS="$BATS_TEST_TMPDIR/bus"
  CONF="$BATS_TEST_TMPDIR/swarm.conf"
  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN"
  export PATH="$BIN:$PATH"
  export BUSDIR="$BUS"
  export CONF
  export HEARTBEAT_SEC=1
  # full_run calls mon_web_ensure/mon_web_open (specs/05-ground-control.md); default MON_AUTOOPEN=1
  # would probe/spawn against the REAL port 4747. Disable; ground-control.bats covers it in isolation.
  export MON_AUTOOPEN=0
  # _scratch_home (src/swarm-lib.sh) reads $HOME/.claude, $HOME/.codex — never let a test touch the
  # real user's credentials; every test gets its own throwaway "real" home instead.
  export HOME="$BATS_TEST_TMPDIR/realhome"
  mkdir -p "$HOME"
  # _scratch_home also honors CLAUDE_CONFIG_DIR (multi-account setups) — unset so this box's ambient
  # session dir never leaks real credentials into a test's throwaway scratch home.
  unset CLAUDE_CONFIG_DIR
  # claude:opus (the only lane these fixtures exercise) needs no env-master key, but give a working
  # default anyway so env_master_preflight never trips should a later fixture here add an env-key lane.
  printf 'Z_AI_CODING_KEY=default-glm-key\nMOONSHOT_API_KEY=default-kimi-key\nGEMINI_API_KEY=default-gem-key\n' \
    > "$BATS_TEST_TMPDIR/envmaster-default"
  export ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster-default"
  # spec 13 FR-6: auto live-probes default ON for operators — OFF for this suite, or every test would
  # fire a probe per lane (extra fake invocations, real-provider API touches). None of these tests are
  # about probes.
  export PROBE_AUTO=0
  # Tests 1+2 finalize a card and LEDGER_AUTO defaults on — pin the ledger to tmp so no row ever lands
  # in the repo's real docs/ops/llm-runs.md.
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

# _fake <NAME> <value> — appends NAME="value" to $BIN/fake.conf (bash-%q-escaped), which the fake CLI
# sources on its own via ${BASH_SOURCE[0]}'s dirname. A FILE, not an env var, on purpose: it must
# survive lane_cmd's `env -i` wrapping of the real invocation.
_fake() { printf '%s=%q\n' "$1" "$2" >> "$BIN/fake.conf"; }

# Focused subset of tests/swarm-run.bats's _install_fakes: only the fake claude is exercised here
# (EXEC_CHAIN="claude:opus"), so only it is installed. Default-path only — emit an init event then a
# result carrying FAKE_CLAUDE_RESULT (default "OK"), exit FAKE_CLAUDE_EXIT (default 0). That is all the
# pool needs to claim → spawn → tee → extract_answer → finalize a non-write card to done/.
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
FANOUT=${2:-2}
LEASE_MIN=${3:-15}
EOF
}

# --- FR-6: --busdir <path> flag (spec 21) -------------------------------------------------------

@test "FR-6: --busdir beats --run derivation — run serves the --busdir bus, no .bus-<label> created in the cwd" {
  # Today: the option loop only arms `--run`, so `--busdir` is left in argv, drops to the `*)` case as
  # full_run's (ignored) question, and BUSDIR still derives to $cwd/.bus-lbl — an empty bus, so the run
  # aborts "nothing to run" (status nonzero) and the xbus card is never served. The decisive assertion
  # (done marker in xbus) fails outright.
  _write_conf "claude:opus" 2 15
  _fake FAKE_CLAUDE_RESULT "xbus answer"
  local xbus="$BATS_TEST_TMPDIR/xbus"
  mkdir -p "$xbus/specs"
  printf '%s' "busdir card" > "$xbus/specs/xb1.prompt"
  local scratch="$BATS_TEST_TMPDIR/cwd-scratch"
  mkdir -p "$scratch"

  # Unset every OTHER BUSDIR source (env, UNIMATRIX_BUS_ROOT, SPEEDWARS_RUN) so the only resolution
  # left is the flag pair; run from a scratch cwd so a stray --run derivation would create
  # $scratch/.bus-lbl and the negative assertion below can catch it.
  run env -u BUSDIR -u SPEEDWARS_RUN -u UNIMATRIX_BUS_ROOT \
    bash -c "cd '$scratch' && exec '$RUNSH' --run lbl --busdir '$xbus' ''"
  [ "$status" -eq 0 ]
  [ -f "$xbus/done/xb1" ]
  [ "$(<"$xbus/res-xb1.txt")" = "xbus answer" ]
  # --run derivation must NOT have created .bus-lbl in the caller's cwd (--busdir won)
  [ ! -d "$scratch/.bus-lbl" ]
}

@test "FR-6: --busdir alone (no --run) — bus dirs created at the given path, card served" {
  # Today: `--busdir` is unparseable, so it falls to full_run's (ignored) question and BUSDIR stays at
  # the suite's exported tmp default ($BUS, empty) — the run aborts "nothing to run" before serving the
  # xbus2 card. Keeping BUSDIR exported (rather than unsetting it) makes the RED path deterministic:
  # it aborts on a known-empty tmp bus instead of the repo's real .bus. Under GREEN, FR-6's "last
  # writer in the option loop wins over env" routes the run to xbus2 — the seeded card is served there,
  # not in $BUS — so the done marker in xbus2 is the decisive assertion.
  _write_conf "claude:opus" 2 15
  _fake FAKE_CLAUDE_RESULT "xbus2 answer"
  local xbus2="$BATS_TEST_TMPDIR/xbus2"
  mkdir -p "$xbus2/specs"
  printf '%s' "busdir alone card" > "$xbus2/specs/xb2.prompt"

  run timeout 30 "$RUNSH" --busdir "$xbus2" ""
  [ "$status" -eq 0 ]
  [ -f "$xbus2/done/xb2" ]
  [ "$(<"$xbus2/res-xb2.txt")" = "xbus2 answer" ]
}

@test "FR-6: usage text documents the --busdir flag" {
  # Today: `--help` is not a recognized subcommand (no case arm), so it drops to `*)` → full_run and
  # the empty $BUS aborts "nothing to run" — output has no "--busdir" anywhere, so the assertion fails.
  # GREEN requires both wiring --help to usage() AND adding a --busdir line to the usage text.
  run "$RUNSH" --help
  [[ "$output" == *"--busdir"* ]]
}

# --- FR-7: ancestor-bus hint on empty-run abort (spec 21) ---------------------------------------

@test "FR-7: empty-run abort with --run names an existing toplevel .bus-<label> as a hint (git fixture)" {
  # Today: _refuse_empty_run prints only "nothing to run" + the existing --run note — it never probes
  # git for an ancestor bus, so the toplevel path repo/.bus-lbl appears nowhere in the abort text and
  # the decisive path assertion fails (the run DOES still abort nonzero with "nothing to run", so those
  # two assertions pass under RED — it's the hint-line assertion that catches the missing feature).
  _write_conf "claude:opus" 4 15
  local repo="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$repo"
  git -C "$repo" init -q
  # an existing ancestor bus at the repo toplevel, non-empty (a done/ card) — the hint target
  mkdir -p "$repo/.bus-lbl/done"
  printf '{"id":"anc1","code":0,"lane":"claude"}\n' > "$repo/.bus-lbl/done/anc1"
  mkdir -p "$repo/sub"

  # Run --run lbl from a SUBDIR so the derived bus ($PWD/.bus-lbl = repo/sub/.bus-lbl) is empty and
  # DIFFERS from the toplevel ancestor repo/.bus-lbl. Unset BUSDIR/UNIMATRIX_BUS_ROOT so --run truly
  # derives at the caller's cwd (no env short-circuiting the derivation). The abort must still exit
  # nonzero (hint is suggest-only, never auto-prefers) and name the ancestor bus.
  run env -u BUSDIR -u UNIMATRIX_BUS_ROOT \
    bash -c "cd '$repo/sub' && exec '$RUNSH' --run lbl ''"
  [ "$status" -ne 0 ]
  [[ "$output" == *"nothing to run"* ]]
  # FR-7 hint: the abort names the existing toplevel ancestor bus (this path can ONLY come from the hint)
  [[ "$output" == *"$repo/.bus-lbl"* ]]
  # spec 21 quotes the hint wording: "found existing … — launch from there or pass --busdir"
  [[ "$output" == *"found existing"* ]]
}

@test "FR-7 negative: with NO toplevel ancestor bus, the empty-run abort prints no 'found existing' hint" {
  # Regression guard (vacuously green until the hint exists): same shape as the positive case but the
  # toplevel .bus-lbl is never created, so the conditional hint must stay silent. It passes under RED
  # (no hint is ever printed yet) and under a correct GREEN; it only fails if an implementation prints
  # the hint unconditionally instead of gating it on the ancestor bus existing.
  _write_conf "claude:opus" 4 15
  local repo="$BATS_TEST_TMPDIR/repo2"
  mkdir -p "$repo"
  git -C "$repo" init -q
  mkdir -p "$repo/sub"
  # deliberately NO $repo/.bus-lbl — nothing for the hint to name

  run env -u BUSDIR -u UNIMATRIX_BUS_ROOT \
    bash -c "cd '$repo/sub' && exec '$RUNSH' --run lbl ''"
  [ "$status" -ne 0 ]
  [[ "$output" == *"nothing to run"* ]]
  # no ancestor bus exists -> the conditional hint must stay silent
  [[ "$output" != *"found existing"* ]]
}
