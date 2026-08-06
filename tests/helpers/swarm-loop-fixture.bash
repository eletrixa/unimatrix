# Shared fixture for the swarm-loop.bats shards: setup/teardown, fake claude/codex installers,
# controllable fake oracle scripts, and cross-shard probe helpers — extracted verbatim from the
# former tests/swarm-loop.bats preamble so tests/swarm-loop-{1,2,3}.bats can `load` one copy.
#
# Project: unimatrix — multi-model swarm orchestrator driven from Claude Code
# Module:  tests/helpers/swarm-loop-fixture.bash
# Deps:    bats-core, swarm-loop.sh, swarm-run.sh, src/swarm-lib.sh, fake claude/codex on PATH
# Tested:  n/a — test fixture, exercised by tests/swarm-loop-{1,2,3}.bats

LOOPSH="$BATS_TEST_DIRNAME/../swarm-loop.sh"

setup() {
  BUS="$BATS_TEST_TMPDIR/bus"
  CONF="$BATS_TEST_TMPDIR/swarm.conf"
  BIN="$BATS_TEST_TMPDIR/bin"
  TARGET="$BATS_TEST_TMPDIR/target"
  mkdir -p "$BIN" "$TARGET"
  export PATH="$BIN:$PATH"
  export BUSDIR="$BUS"
  export CONF
  export HEARTBEAT_SEC=1
  export TARGET_DIR="$TARGET"
  # spec 13 auto-probes are OFF here (mirrors tests/swarm-run.bats setup): this file installs no
  # fake curl, so a first-claim live probe would hit the REAL provider API — kimi's suspended
  # Moonshot account turned that into a box-state-dependent kimi.broken and failed the FR-R2/R3
  # fallback tests (found 2026-07-29, latent since PROBE_AUTO shipped in v1.3.0).
  export PROBE_AUTO=0
  export SWARM_RUN="$BATS_TEST_DIRNAME/../swarm-run.sh"
  # crontab shim (defense in depth): attended cmd_run calls watchdog-disarm on close — without a
  # shim that reads the REAL crontab. The no-op-disarm guard makes it read-only, but the suite
  # must never touch the operator's crontab at all.
  export FAKE_CRONTAB_FILE="$BATS_TEST_TMPDIR/crontab"
  printf '#!/usr/bin/env bash\ncase "${1:-}" in\n  -l) [[ -s "$FAKE_CRONTAB_FILE" ]] && cat "$FAKE_CRONTAB_FILE" || exit 1 ;;\n  -) cat > "$FAKE_CRONTAB_FILE" ;;\nesac\n' > "$BIN/crontab"
  chmod +x "$BIN/crontab"
  # cmd_init now calls mon_web_ensure/mon_web_open (specs/05-ground-control.md) — default
  # MON_AUTOOPEN=1/MON_PORT=4747 would probe/spawn against the REAL port 4747 and real .bus
  # default from every test in this file. Disable; ground-control.bats covers that behavior
  # in isolation with its own throwaway ports.
  export MON_AUTOOPEN=0
  # _scratch_home (src/swarm-lib.sh) reads $HOME/.claude, $HOME/.codex — never the real user's home.
  export HOME="$BATS_TEST_TMPDIR/realhome"
  mkdir -p "$HOME"
  # _scratch_home also honors CLAUDE_CONFIG_DIR (multi-account setups) — unset so this box's own
  # ambient session dir never leaks real credentials into a test's throwaway scratch home.
  unset CLAUDE_CONFIG_DIR
  _write_conf
  _install_fakes
}

teardown() {
  pkill -9 -f "$BATS_TEST_TMPDIR" 2>/dev/null || true
  return 0
}

_write_conf() {
  cat > "$CONF" <<EOF
EXEC_CHAIN="${1:-claude:opus}"
FANOUT=4
LEASE_MIN=15
REVIEW="${2:-codex:default}"
MAX_ITERATIONS=${3:-10}
BUDGET_USD=0
EOF
}

_fake() { printf '%s=%q\n' "$1" "$2" >> "$BIN/fake.conf"; }

# Same fake claude/codex shapes as tests/swarm-run.bats (claude serves the exec chain default;
# codex serves the default judge/review lane) — copied, not shared, so this file has no runtime
# dependency on that one.
_install_fakes() {
  : > "$BIN/fake.conf"
  cat > "$BIN/claude" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$_here/fake.conf" ]] && source "$_here/fake.conf"
# FR-15: write-mode probe, same knob/shape as tests/swarm-run.bats's fake — writes relative to
# $PWD, proving lane_cmd actually chdir'd the worker into the write target (the worktree).
if [[ -n "${FAKE_CLAUDE_WRITE_FILE:-}" ]]; then
  printf '%s' "${FAKE_CLAUDE_WRITE_CONTENT:-written}" > "$FAKE_CLAUDE_WRITE_FILE"
fi
sleep "${FAKE_CLAUDE_DELAY:-0}"
echo '{"type":"init"}'
# spec10 FR-R2/R3: kimi is this SAME claude binary under a child-env swap (ANTHROPIC_BASE_URL
# points at Moonshot) — FAKE_KIMI_RESULT lets a test give a kimi-served card a different answer
# than the plain-claude exec branch, so the two are independently assertable in one iteration.
result="${FAKE_CLAUDE_RESULT:-exec answer}"
if [[ "${ANTHROPIC_BASE_URL:-}" == *moonshot* && -n "${FAKE_KIMI_RESULT:-}" ]]; then
  result="$FAKE_KIMI_RESULT"
fi
if [[ -n "${FAKE_CLAUDE_COST:-}" ]]; then
  printf '{"type":"result","result":"%s","total_cost_usd":%s,"usage":{"input_tokens":1,"output_tokens":1}}\n' \
    "$result" "$FAKE_CLAUDE_COST"
else
  printf '{"type":"result","result":"%s"}\n' "$result"
fi
exit "${FAKE_CLAUDE_EXIT:-0}"
FAKE

  cat > "$BIN/codex" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$_here/fake.conf" ]] && source "$_here/fake.conf"
outfile=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  if [[ "${args[$i]}" == "--output-last-message" ]]; then
    outfile="${args[$((i + 1))]}"
  fi
done
sleep "${FAKE_CODEX_DELAY:-0}"
echo '{"type":"thread.started"}'
if [[ -n "${FAKE_CODEX_WRITE_FILE:-}" ]]; then
  printf '%s' "${FAKE_CODEX_WRITE_CONTENT:-written}" > "$FAKE_CODEX_WRITE_FILE"
fi
[[ -n "$outfile" ]] && printf '%s' "${FAKE_CODEX_RESULT:-VERDICT: pass}" > "$outfile"
echo '{"type":"turn.completed","usage":{"input_tokens":10}}'
exit "${FAKE_CODEX_EXIT:-0}"
FAKE

  chmod +x "$BIN/claude" "$BIN/codex"
}

# _fake_oracle <name> — writes a controllable oracle script under $BIN and echoes its path.
# Reads its behavior from a per-test counter/mode file rather than env (the oracle runs as a
# plain `bash -c` inside TARGET_DIR, no env inherited from swarm-loop.sh beyond ambient PATH).
_fake_oracle_fails_then_passes() {
  local n="$1" counter="$BATS_TEST_TMPDIR/oracle-counter"
  local script="$BIN/oracle-fails-$n-then-passes.sh"
  cat > "$script" <<EOF
#!/usr/bin/env bash
counter="$counter"
c=\$(cat "\$counter" 2>/dev/null || echo 0)
c=\$((c + 1))
echo "\$c" > "\$counter"
if (( c < $n )); then
  echo "still failing, attempt \$c"
  exit 1
fi
echo "all good"
exit 0
EOF
  chmod +x "$script"
  echo "$script"
}

_fake_oracle_always_same_failure() {
  local script="$BIN/oracle-always-fails.sh"
  cat > "$script" <<'EOF'
#!/usr/bin/env bash
echo "always the same failure"
exit 7
EOF
  chmod +x "$script"
  echo "$script"
}

_fake_oracle_unique_each_time() {
  local counter="$BATS_TEST_TMPDIR/oracle-counter-unique"
  local script="$BIN/oracle-unique.sh"
  cat > "$script" <<EOF
#!/usr/bin/env bash
counter="$counter"
c=\$(cat "\$counter" 2>/dev/null || echo 0)
c=\$((c + 1))
echo "\$c" > "\$counter"
echo "attempt \$c failing"
exit \$(( (c % 3) + 1 ))
EOF
  chmod +x "$script"
  echo "$script"
}

_fake_oracle_alternating() {
  local counter="$BATS_TEST_TMPDIR/oracle-counter-alt"
  local script="$BIN/oracle-alternating.sh"
  cat > "$script" <<EOF
#!/usr/bin/env bash
counter="$counter"
c=\$(cat "\$counter" 2>/dev/null || echo 0)
c=\$((c + 1))
echo "\$c" > "\$counter"
if (( c % 2 == 1 )); then
  echo "STATE-A"
else
  echo "STATE-B"
fi
exit 1
EOF
  chmod +x "$script"
  echo "$script"
}

_git_init_target() {
  git -C "$TARGET" init -q
  git -C "$TARGET" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
}

# helper: read a criteria field from outside swarm-loop.sh
_criteria_field_probe() {
  local v; v="$(grep -m1 "^$2: " "$1" || true)"; echo "${v#*: }"
}

# limit_flag isn't on PATH as a command — probe it by sourcing the lib in a fresh bash, same
# technique tests/swarm-run.bats uses for limit_active_probe.
_limit_flag_probe() {
  bash -c "source '$BATS_TEST_DIRNAME/../src/swarm-lib.sh'; limit_flag '$1' '$2' '${3:-18000}'"
}

# crontab PATH shim (reads/writes $FAKE_CRONTAB_FILE) — same pattern as tests/swarm-ctl.bats'
# _spec11_install_fakes; copied, not shared, so this file has no runtime dependency on that one.
_install_fake_crontab() {
  export FAKE_CRONTAB_FILE="$BATS_TEST_TMPDIR/fake.crontab"
  rm -f "$FAKE_CRONTAB_FILE"
  cat > "$BIN/crontab" <<EOF
#!/usr/bin/env bash
set -euo pipefail
_file="$FAKE_CRONTAB_FILE"
case "\${1:-}" in
  -l) [[ -s "\$_file" ]] || exit 1; cat "\$_file"; exit 0 ;;
  -)  cat > "\$_file"; exit 0 ;;
  *)  echo "fake crontab: unsupported usage: \$*" >&2; exit 2 ;;
esac
EOF
  chmod +x "$BIN/crontab"
}
