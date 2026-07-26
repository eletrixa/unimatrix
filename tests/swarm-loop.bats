#!/usr/bin/env bats
# Tests for swarm-loop.sh: criteria contract (write-once + checksum guard), one iteration
# (exec -> oracle -> review), and the `run` stop-rule ladder (goal/plateau/oscillation/
# max_iterations). Fake claude/codex on PATH (copied from tests/swarm-run.bats) plus a
# controllable fake oracle script — no real API calls, no real oracle command.
#
# Project: unimatrix — multi-model swarm orchestrator driven from Claude Code
# Module:  tests/swarm-loop.bats
# Deps:    bats-core, swarm-loop.sh, swarm-run.sh, src/swarm-lib.sh, fake claude/codex on PATH
# Tested:  n/a — this is the test file

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

# --- init --------------------------------------------------------------------------------------

@test "init: scaffolds criteria.md/steering.md/state.jsonl and refuses re-init" {
  LOOP_GOAL="toy goal" LOOP_ORACLE="true" run "$LOOPSH" init run1
  [ "$status" -eq 0 ]

  local loopdir="$BUS/loop/run1"
  [ -f "$loopdir/criteria.md" ]
  [ -f "$loopdir/steering.md" ]
  [ -f "$loopdir/state.jsonl" ]
  grep -q "^goal: toy goal$" "$loopdir/criteria.md"

  LOOP_GOAL="toy goal" LOOP_ORACLE="true" run "$LOOPSH" init run1
  [ "$status" -ne 0 ]
}

@test "init: judge==exec lane substitutes to CLASS_REVIEW member on collision (spec 10)" {
  LOOP_GOAL="g" LOOP_ORACLE="true" LOOP_JUDGE="claude:sonnet" run "$LOOPSH" init run2
  [ "$status" -eq 0 ]
  [ -f "$BUS/loop/run2/criteria.md" ]
  [[ "$output" == *"substitut"* ]]
}

# --- FR-15/FR-8: scratch git worktree ------------------------------------------------------

_git_init_target() {
  git -C "$TARGET" init -q
  git -C "$TARGET" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
}

@test "init: TARGET_DIR that is a git repo gets a scratch worktree; criteria.md target points at it" {
  _git_init_target
  LOOP_GOAL="g" LOOP_ORACLE="true" run "$LOOPSH" init runwt1
  [ "$status" -eq 0 ]

  local loopdir="$BUS/loop/runwt1"
  [ -d "$loopdir/worktree" ]
  [ -e "$loopdir/worktree/.git" ]
  grep -q "^target: $loopdir/worktree$" "$loopdir/criteria.md"
  grep -q "^base_sha: " "$loopdir/criteria.md"
  ! grep -q "^base_sha: $" "$loopdir/criteria.md"
}

@test "init: non-git TARGET_DIR uses it directly with a loud warning, no worktree" {
  LOOP_GOAL="g" LOOP_ORACLE="true" run "$LOOPSH" init runwt2
  [ "$status" -eq 0 ]
  [[ "$output" == *"not a usable git repo"* ]]
  grep -q "^target: $TARGET$" "$BUS/loop/runwt2/criteria.md"
  grep -q "^base_sha: $" "$BUS/loop/runwt2/criteria.md"
  [ ! -d "$BUS/loop/runwt2/worktree" ]
}

# --- iterate -----------------------------------------------------------------------------------

@test "iterate: criteria.md is unchanged (checksum) after several iterations" {
  local oracle; oracle="$(_fake_oracle_fails_then_passes 5)"
  LOOP_GOAL="g" LOOP_ORACLE="$oracle" run "$LOOPSH" init run3
  [ "$status" -eq 0 ]
  local before; before="$(sha256sum "$BUS/loop/run3/criteria.md" | cut -d' ' -f1)"

  run timeout 20 "$LOOPSH" iterate run3
  [ "$status" -eq 0 ]
  run timeout 20 "$LOOPSH" iterate run3
  [ "$status" -eq 0 ]

  local after; after="$(sha256sum "$BUS/loop/run3/criteria.md" | cut -d' ' -f1)"
  [ "$before" = "$after" ]
}

@test "iterate: criteria.md mutated mid-run is caught by the checksum guard and refuses (die)" {
  LOOP_GOAL="g" LOOP_ORACLE="true" run "$LOOPSH" init runchk
  [ "$status" -eq 0 ]
  # a worker (or anything) editing the read-only contract after init must be detected before adjudication
  echo "tampered: yes" >> "$BUS/loop/runchk/criteria.md"
  run timeout 20 "$LOOPSH" iterate runchk
  [ "$status" -ne 0 ]
  [[ "$output" == *"checksum mismatch"* ]]
  # no state line appended — the guard fired before the iteration ran
  [ ! -s "$BUS/loop/runchk/state.jsonl" ]
}

@test "iterate: an unparseable review verdict fails closed to 'findings' (never assumed pass)" {
  LOOP_GOAL="g" LOOP_ORACLE="true" run "$LOOPSH" init runfc
  [ "$status" -eq 0 ]
  # judge emits no recognizable "VERDICT: pass|findings" line
  _fake FAKE_CODEX_RESULT "I looked at it and it seems fine to me, ship it."

  run timeout 20 "$LOOPSH" iterate runfc
  [ "$status" -eq 0 ]
  [ "$(jq -r .review "$BUS/loop/runfc/state.jsonl")" = "findings" ]
}

@test "iterate: single happy-path call appends exactly one state line" {
  LOOP_GOAL="g" LOOP_ORACLE="true" run "$LOOPSH" init run4
  [ "$status" -eq 0 ]
  _fake FAKE_CODEX_RESULT "VERDICT: pass"

  run timeout 20 "$LOOPSH" iterate run4
  [ "$status" -eq 0 ]

  local sf="$BUS/loop/run4/state.jsonl"
  [ "$(wc -l < "$sf")" -eq 1 ]
  [ "$(jq -r .iter "$sf")" = "1" ]
  [ "$(jq -r .oracle_rc "$sf")" = "0" ]
  [ "$(jq -r .review "$sf")" = "pass" ]
}

@test "iterate: write sidecar points at the worktree — fake exec write lands there, oracle sees it" {
  _git_init_target
  LOOP_GOAL="g" LOOP_ORACLE="test -f answer.txt && grep -qx 42 answer.txt" run "$LOOPSH" init runwt3
  [ "$status" -eq 0 ]

  _fake FAKE_CLAUDE_WRITE_FILE "answer.txt"
  _fake FAKE_CLAUDE_WRITE_CONTENT "42"
  _fake FAKE_CODEX_RESULT "VERDICT: pass"

  run timeout 20 "$LOOPSH" iterate runwt3
  [ "$status" -eq 0 ]

  local loopdir="$BUS/loop/runwt3"
  [ -f "$loopdir/worktree/answer.txt" ]
  [ "$(<"$loopdir/worktree/answer.txt")" = "42" ]
  [ "$(jq -r .oracle_rc "$loopdir/state.jsonl")" = "0" ]
  [ "$(jq -r .review "$loopdir/state.jsonl")" = "pass" ]
}

@test "iterate: steering.md accrues findings across iterations" {
  LOOP_GOAL="g" LOOP_ORACLE="true" run "$LOOPSH" init run5
  [ "$status" -eq 0 ]
  _fake FAKE_CODEX_RESULT "VERDICT: findings"$'\n'"stub detected in helper()"

  run timeout 20 "$LOOPSH" iterate run5
  [ "$status" -eq 0 ]
  run timeout 20 "$LOOPSH" iterate run5
  [ "$status" -eq 0 ]

  grep -q "## iter 1 findings" "$BUS/loop/run5/steering.md"
  grep -q "## iter 2 findings" "$BUS/loop/run5/steering.md"
  [ "$(grep -c "stub detected in helper" "$BUS/loop/run5/steering.md")" -eq 2 ]
}

# --- run: stop rules -----------------------------------------------------------------------------

@test "run: goal hit — oracle passes + review pass writes COMPLETE.md, exit 0" {
  LOOP_GOAL="g" LOOP_ORACLE="true" run "$LOOPSH" init run6
  [ "$status" -eq 0 ]
  _fake FAKE_CODEX_RESULT "VERDICT: pass"

  run timeout 30 "$LOOPSH" run run6
  [ "$status" -eq 0 ]
  [ -f "$BUS/loop/run6/COMPLETE.md" ]
  [ "$(wc -l < "$BUS/loop/run6/state.jsonl")" -eq 1 ]
}

@test "run: goal hit in a worktree — COMPLETE.md names the worktree path and its diff-stat" {
  _git_init_target
  LOOP_GOAL="g" LOOP_ORACLE="test -f answer.txt" run "$LOOPSH" init runwt4
  [ "$status" -eq 0 ]
  _fake FAKE_CLAUDE_WRITE_FILE "answer.txt"
  _fake FAKE_CODEX_RESULT "VERDICT: pass"

  run timeout 30 "$LOOPSH" run runwt4
  [ "$status" -eq 0 ]

  local loopdir="$BUS/loop/runwt4"
  [ -f "$loopdir/COMPLETE.md" ]
  grep -q "$loopdir/worktree" "$loopdir/COMPLETE.md"
  grep -q "answer.txt" "$loopdir/COMPLETE.md"
  [ -f "$loopdir/worktree/answer.txt" ]
}

@test "run: plateau — same oracle failure repeated halts naming plateau, exit 2" {
  local oracle; oracle="$(_fake_oracle_always_same_failure)"
  LOOP_GOAL="g" LOOP_ORACLE="$oracle" LOOP_PLATEAU=3 run "$LOOPSH" init run7
  [ "$status" -eq 0 ]

  run timeout 60 "$LOOPSH" run run7
  [ "$status" -eq 2 ]
  [ -f "$BUS/loop/run7/HALTED.md" ]
  grep -q "^Rule fired: plateau$" "$BUS/loop/run7/HALTED.md"
  [ "$(wc -l < "$BUS/loop/run7/state.jsonl")" -eq 3 ]
}

@test "run: oscillation — alternating failure signature halts naming oscillation, exit 2" {
  local oracle; oracle="$(_fake_oracle_alternating)"
  # plateau window wider than 3 so the 3-iteration oscillation check fires first
  LOOP_GOAL="g" LOOP_ORACLE="$oracle" LOOP_PLATEAU=5 run "$LOOPSH" init run8
  [ "$status" -eq 0 ]

  run timeout 60 "$LOOPSH" run run8
  [ "$status" -eq 2 ]
  [ -f "$BUS/loop/run8/HALTED.md" ]
  grep -q "^Rule fired: oscillation$" "$BUS/loop/run8/HALTED.md"
  [ "$(wc -l < "$BUS/loop/run8/state.jsonl")" -eq 3 ]
}

@test "run: max_iterations — unique failure each time reaches the cap, exit 2" {
  local oracle; oracle="$(_fake_oracle_unique_each_time)"
  _write_conf "claude:opus" "codex:default" 4  # MAX_ITERATIONS=4
  LOOP_GOAL="g" LOOP_ORACLE="$oracle" LOOP_PLATEAU=3 run "$LOOPSH" init run9
  [ "$status" -eq 0 ]

  run timeout 90 "$LOOPSH" run run9
  [ "$status" -eq 2 ]
  [ -f "$BUS/loop/run9/HALTED.md" ]
  grep -q "^Rule fired: max_iterations$" "$BUS/loop/run9/HALTED.md"
  [ "$(wc -l < "$BUS/loop/run9/state.jsonl")" -eq 4 ]
}

@test "run: human_gate — goal-hit halts pending human ack; touching HUMAN_OK lets the next run complete" {
  LOOP_GOAL="g" LOOP_ORACLE="true" LOOP_HUMAN_GATE=true run "$LOOPSH" init run10
  [ "$status" -eq 0 ]
  _fake FAKE_CODEX_RESULT "VERDICT: pass"

  run timeout 30 "$LOOPSH" run run10
  [ "$status" -eq 2 ]
  [ -f "$BUS/loop/run10/HALTED.md" ]
  grep -q "^Rule fired: human_gate_pending$" "$BUS/loop/run10/HALTED.md"
  [ ! -f "$BUS/loop/run10/COMPLETE.md" ]

  touch "$BUS/loop/run10/HUMAN_OK"
  run timeout 30 "$LOOPSH" run run10
  [ "$status" -eq 0 ]
  [ -f "$BUS/loop/run10/COMPLETE.md" ]
}

# --- remediation 2026-07-12: judge!=executor across the whole chain, review-sees-diff, cage, etc ---

@test "R5: judge lane matching a NON-head EXEC_CHAIN entry substitutes to CLASS_REVIEW (spec 10)" {
  # EXEC_CHAIN head is claude, but glm is a fallback exec lane; a glm judge would grade glm's own
  # output the moment claude fails over. The guard substitutes to the first qualifying CLASS_REVIEW member.
  # spec 13 FR-1: EXEC_CHAIN now includes glm, so init's env_master_preflight needs a reachable file.
  printf 'Z_AI_CODING_KEY=test-glm-key\n' > "$BATS_TEST_TMPDIR/envmaster-r5"
  LOOP_GOAL="g" LOOP_ORACLE="true" LOOP_JUDGE="glm:glm-5.2" \
    EXEC_CHAIN="claude:opus glm:glm-5.2" ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster-r5" \
    run "$LOOPSH" init runjudge
  [ "$status" -eq 0 ]
  [ -f "$BUS/loop/runjudge/criteria.md" ]
  [[ "$output" == *"substitut"* ]]
}

@test "R6: review prompt includes the worktree diff, not just the executor's self-reported answer" {
  _git_init_target
  LOOP_GOAL="g" LOOP_ORACLE="true" run "$LOOPSH" init runrev
  [ "$status" -eq 0 ]
  # exec writes a real file but its ANSWER text never mentions it — only a diff would reveal it
  _fake FAKE_CLAUDE_WRITE_FILE "sneaky.txt"
  _fake FAKE_CLAUDE_WRITE_CONTENT "canary-content-xyz"
  _fake FAKE_CLAUDE_RESULT "I did some work."
  _fake FAKE_CODEX_RESULT "VERDICT: pass"

  run timeout 20 "$LOOPSH" iterate runrev
  [ "$status" -eq 0 ]

  local rp="$BUS/loop/runrev/iter-1/review.prompt"
  [ -f "$rp" ]
  # the diff of the file the executor stayed silent about must reach the reviewer
  grep -q "sneaky.txt" "$rp"
  grep -q "canary-content-xyz" "$rp"
}

@test "R7: human_gate resume completes against the approved state WITHOUT re-running exec" {
  LOOP_GOAL="g" LOOP_ORACLE="true" LOOP_HUMAN_GATE=true run "$LOOPSH" init runhg
  [ "$status" -eq 0 ]
  _fake FAKE_CODEX_RESULT "VERDICT: pass"
  # marker the fake exec drops every time it runs — must NOT be recreated on the resume
  _fake FAKE_CLAUDE_WRITE_FILE "$BATS_TEST_TMPDIR/exec-ran-marker"

  run timeout 30 "$LOOPSH" run runhg
  [ "$status" -eq 2 ]
  [ "$(wc -l < "$BUS/loop/runhg/state.jsonl")" -eq 1 ]
  rm -f "$BATS_TEST_TMPDIR/exec-ran-marker"

  touch "$BUS/loop/runhg/HUMAN_OK"
  run timeout 30 "$LOOPSH" run runhg
  [ "$status" -eq 0 ]
  [ -f "$BUS/loop/runhg/COMPLETE.md" ]
  # no fresh iteration: state stays at one line and the exec was not re-spawned
  [ "$(wc -l < "$BUS/loop/runhg/state.jsonl")" -eq 1 ]
  [ ! -e "$BATS_TEST_TMPDIR/exec-ran-marker" ]
}

@test "R8: oracle runs caged — a planted oracle cannot write to \$HOME" {
  # oracle writes a canary into its $HOME; under the cage $HOME is a scratch dir, so the real
  # home stays untouched (containment parity with worker spawns).
  local canary="canary-$$.txt"
  LOOP_GOAL="g" LOOP_ORACLE="touch \"\$HOME/$canary\"; true" run "$LOOPSH" init runcage
  [ "$status" -eq 0 ]
  _fake FAKE_CODEX_RESULT "VERDICT: pass"

  run timeout 20 "$LOOPSH" iterate runcage
  [ "$status" -eq 0 ]
  # the real (test) HOME must not have received the canary
  [ ! -e "$HOME/$canary" ]
  # positive proof the oracle actually RAN and was redirected — the canary landed in the cage's
  # scratch HOME (without this, "oracle never invoked" would also pass the negative check above)
  [ -e "$BUS/loop/runcage/.oracle-home/$canary" ]
}

@test "R9: budget cap halts once summed claude-lane cost exceeds BUDGET_USD" {
  local oracle; oracle="$(_fake_oracle_unique_each_time)"
  _write_conf "claude:opus" "codex:default" 10  # MAX_ITERATIONS=10 so budget, not the cap, fires
  # BUDGET_USD is read from criteria (init reads conf); set it small and make each exec cost $1
  sed -i 's/^BUDGET_USD=.*/BUDGET_USD=1.5/' "$CONF"
  _fake FAKE_CLAUDE_COST 1.0
  LOOP_GOAL="g" LOOP_ORACLE="$oracle" LOOP_PLATEAU=99 run "$LOOPSH" init runbudget
  [ "$status" -eq 0 ]

  run timeout 60 "$LOOPSH" run runbudget
  [ "$status" -eq 2 ]
  grep -q "^Rule fired: budget_usd$" "$BUS/loop/runbudget/HALTED.md"
  # halted after cost crossed 1.5 (i.e. by iteration 2), well before the iteration cap of 10
  [ "$(wc -l < "$BUS/loop/runbudget/state.jsonl")" -lt 10 ]
}

@test "R16: per-iteration git commit happens by default in a worktree (git-reset safety net)" {
  _git_init_target
  local oracle; oracle="$(_fake_oracle_always_same_failure)"
  LOOP_GOAL="g" LOOP_ORACLE="$oracle" LOOP_PLATEAU=3 run "$LOOPSH" init runck
  [ "$status" -eq 0 ]
  _fake FAKE_CLAUDE_WRITE_FILE "work.txt"

  run timeout 60 "$LOOPSH" run runck
  # a commit per iteration means the worktree branch has advanced past base_sha
  local wt="$BUS/loop/runck/worktree"
  local base; base="$(_criteria_field_probe "$BUS/loop/runck/criteria.md" base_sha)"
  local head; head="$(git -C "$wt" rev-parse HEAD)"
  [ "$base" != "$head" ]
}

# helper: read a criteria field from outside swarm-loop.sh
_criteria_field_probe() {
  local v; v="$(grep -m1 "^$2: " "$1" || true)"; echo "${v#*: }"
}

@test "R17: an A/B/A oscillation at the default plateau window halts as oscillation, not plateau" {
  local oracle; oracle="$(_fake_oracle_alternating)"
  # default plateau (3) — the pre-fix order let plateau shadow oscillation here
  LOOP_GOAL="g" LOOP_ORACLE="$oracle" run "$LOOPSH" init runosc
  [ "$status" -eq 0 ]

  run timeout 60 "$LOOPSH" run runosc
  [ "$status" -eq 2 ]
  grep -q "^Rule fired: oscillation$" "$BUS/loop/runosc/HALTED.md"
}

# --- spec10 (role-classes/rolecls): judge fallback via CLASS_REVIEW ---------------------------
# plans/003-role-tier-fallback/CONTRACT.md (swarm-loop.sh section) + specs/10-role-classes.md
# FR-R2/R3/R7. None of _resolve_judge / review_chain_for / CLASS_REVIEW / .chain seeding /
# .fbreason exist yet anywhere in src/swarm-lib.sh or swarm-loop.sh (RED wave) — every test below
# is hand-traced, not run.

# limit_flag isn't on PATH as a command — probe it by sourcing the lib in a fresh bash, same
# technique tests/swarm-run.bats uses for limit_active_probe.
_limit_flag_probe() {
  bash -c "source '$BATS_TEST_DIRNAME/../src/swarm-lib.sh'; limit_flag '$1' '$2' '${3:-18000}'"
}

@test "spec10 FR-R2: codex pre-limited before the review card is seeded — chain falls back to kimi within one poll, verdict recorded" {
  printf 'MOONSHOT_API_KEY=test-kimi-key\n' > "$BATS_TEST_TMPDIR/envmaster"
  export ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster"
  LOOP_GOAL="g" LOOP_ORACLE="true" run "$LOOPSH" init runr2a
  [ "$status" -eq 0 ]

  # codex (REVIEW's default judge, _write_conf's default second arg "codex:default") is
  # pre-limited BEFORE the review card is ever seeded — chain_current's new seed order
  # (queue/<id>.chain, derived from CLASS_REVIEW default "codex kimi") must skip it for kimi
  # instead of spinning/parking on the old hard .lane pin.
  _limit_flag_probe "$BUS" codex

  _fake FAKE_CLAUDE_RESULT "exec answer"
  _fake FAKE_KIMI_RESULT "VERDICT: pass"

  run timeout 20 "$LOOPSH" iterate runr2a
  [ "$status" -eq 0 ]

  [ "$(jq -r .oracle_rc "$BUS/loop/runr2a/state.jsonl")" = "0" ]
  [ "$(jq -r .review "$BUS/loop/runr2a/state.jsonl")" = "pass" ]
}
# Why this failed at RED time (W1 — green since W2): cmd_iterate (swarm-loop.sh:345) unconditionally hard-pins review via
# `echo "$judge" > specs/<review_id>.lane` — no CLASS_REVIEW/review_chain_for/chain-seed mechanism
# exists at all. With codex pre-limited, swarm-run.sh's PINNED claim branch
# (_try_claim_one, queue/<id>.lane path) does `limit_active && continue` FOREVER — no
# lane_blocked/bounded-wait/PIN_WAIT_SEC exists yet, so the branch is silently skipped on every
# poll and the pool's `done+parked>=live` gate never closes (this is exactly the motivation-section
# bug: "the claim loop just continues past it every poll ... spin ... for the lane's full TTL").
# `_run_pool_once`/swarm-run.sh therefore hangs until the outer `timeout 20` kills it — status 124,
# not 0 — and no review verdict is ever recorded.

@test "spec10 FR-R2: normal iterate seeds the review card via specs/<review_id>.chain, never a .lane pin (mechanism regression)" {
  LOOP_GOAL="g" LOOP_ORACLE="true" run "$LOOPSH" init runr2b
  [ "$status" -eq 0 ]

  # Stub the pool to a no-op so cmd_iterate's OWN writes under specs/ are inspectable afterward,
  # untouched by any consumption/cleanup a real pool run would do to them.
  SWARM_RUN=/bin/true run timeout 20 "$LOOPSH" iterate runr2b
  [ "$status" -eq 0 ]

  local review_id="runr2b-i1-review"
  [ -f "$BUS/specs/$review_id.chain" ]
  [ ! -f "$BUS/specs/$review_id.lane" ]
}
# Why this failed at RED time (W1 — green since W2): cmd_iterate (swarm-loop.sh:345) unconditionally writes
# `specs/<review_id>.lane` (`echo "$judge" > ...`) and never writes a `.chain` sidecar anywhere —
# `specs/$review_id.chain` is never created (first assertion fails) and `specs/$review_id.lane`
# always exists after a normal iterate (second assertion fails). Pure unit-level check of
# cmd_iterate's write behavior, independent of pool timing.

@test "spec10 FR-R2-init: judge==EXEC_CHAIN collision at init auto-substitutes a qualifying CLASS_REVIEW member instead of dying" {
  LOOP_GOAL="g" LOOP_ORACLE="true" LOOP_JUDGE="codex:default" \
    EXEC_CHAIN="codex:default" run "$LOOPSH" init runr2ia
  [ "$status" -eq 0 ]
  [[ "$output" == *"substitut"* ]]
  [ -f "$BUS/loop/runr2ia/criteria.md" ]
  local judge; judge="$(_criteria_field_probe "$BUS/loop/runr2ia/criteria.md" judge)"
  [[ "$judge" != codex:* ]]
}
# Why this failed at RED time (W1 — green since W2): cmd_init (swarm-loop.sh:157) calls `_check_judge_ne_exec "$judge"`, which
# `_die`s unconditionally the instant the judge's bare lane collides with any EXEC_CHAIN entry — no
# `_resolve_judge`/auto-substitution mechanism exists yet. Init exits nonzero, criteria.md is never
# written (`[[ -e "$loopdir/criteria.md" ]] && _die` at line 140 guards re-init, but init itself
# never gets that far) — every assertion here fails against current code.

@test "spec10 FR-R2-init: CLASS_REVIEW exhausted at init (single colliding member) — cmd_init still dies, no silent demotion" {
  LOOP_GOAL="g" LOOP_ORACLE="true" LOOP_JUDGE="codex:default" \
    EXEC_CHAIN="codex:default" CLASS_REVIEW="codex" run "$LOOPSH" init runr2ib
  [ "$status" -ne 0 ]
  [ ! -e "$BUS/loop/runr2ib/criteria.md" ]
  [[ "$output" == *"CLASS_REVIEW"* ]]
}
# Why this failed at RED time (W1 — green since W2): the status/no-criteria.md assertions alone would coincidentally already
# hold today (today's _check_judge_ne_exec dies unconditionally on ANY judge/EXEC_CHAIN collision,
# CLASS_REVIEW or not) — so this test additionally asserts the die message names CLASS_REVIEW,
# proving a fallback attempt was actually considered and exhausted, not just the old unconditional
# collision die. Today's fixed message ("judge lane 'codex:default' collides with EXEC_CHAIN lane
# 'codex:default' ... refusing") never mentions CLASS_REVIEW (conf_load doesn't even know that key
# yet — swarm-lib.sh:79-81's `keys` array has no CLASS_REVIEW/CLASS_EXEC/REVIEW_CHAIN/PIN_WAIT_SEC
# entries), so the third assertion fails against current code.

@test "spec10 FR-R3: exec served by codex — review excludes the author, served by another class member, fbreason starts with author-collision" {
  printf 'MOONSHOT_API_KEY=test-kimi-key\n' > "$BATS_TEST_TMPDIR/envmaster"
  export ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster"
  # codex is EXEC_CHAIN's only lane (exec is served by codex) AND, left at its default, REVIEW's
  # configured judge too — same collision FR-R2-init resolves at config-load time; this test checks
  # the PER-CARD exclusion recorded once THIS card's actual author is known, at review-seed time.
  _write_conf "codex:default" "codex:default" 10

  LOOP_GOAL="g" LOOP_ORACLE="true" run "$LOOPSH" init runr3
  [ "$status" -eq 0 ]

  _fake FAKE_CODEX_RESULT "exec answer from codex"
  # spec10 FR-R11 diff gate: the loop's exec card is a .write card — the fake must touch the target
  _fake FAKE_CODEX_WRITE_FILE "exec-artifact.txt"
  _fake FAKE_KIMI_RESULT "VERDICT: pass"

  run timeout 20 "$LOOPSH" iterate runr3
  [ "$status" -eq 0 ]

  local exec_id="runr3-i1-exec" review_id="runr3-i1-review"
  [ "$(jq -r .lane "$BUS/done/$exec_id")" = "codex" ]
  # .fbreason is CONSUMED into the speedwars row at review finalize (contract: provenance is
  # destroyed only once recorded) — assert the row, not the raw marker file.
  local row
  row="$(jq -c "select(.id==\"$review_id\")" "$BATS_TEST_TMPDIR/docs/ops/speedwars.jsonl")"
  [ "$(jq -r .fallback_reason <<<"$row")" = "author-collision" ]
  [ "$(jq -r .requested <<<"$row")" = "codex" ]
  [ "$(jq -r .verify_lane <<<"$row")" = "kimi" ]
  [ "$(jq -r .review "$BUS/loop/runr3/state.jsonl")" = "pass" ]
}
# Why this failed at RED time (W1 — green since W2): `_write_conf "codex:default" "codex:default" 10` makes EXEC_CHAIN and
# REVIEW both bare "codex" — cmd_init's unconditional `_check_judge_ne_exec` dies immediately on
# this collision (no auto-substitution exists yet, same gap as the FR-R2-init tests above), so
# `[ "$status" -eq 0 ]` fails at init, criteria.md is never written, and the whole author-collision/
# fbreason scenario this test targets is unreachable in current code.

@test "spec10 FR-R7: both CLASS_REVIEW members pre-limited — review card parks loudly, iteration fails closed, no complete" {
  LOOP_GOAL="g" LOOP_ORACLE="true" run "$LOOPSH" init runr7
  [ "$status" -eq 0 ]

  # default CLASS_REVIEW = "codex kimi" (spec10 FR-R1 baked default) — pre-limit BOTH before the
  # review card is even seeded, so the whole class is exhausted at claim time.
  _limit_flag_probe "$BUS" codex
  _limit_flag_probe "$BUS" kimi

  run timeout 20 "$LOOPSH" iterate runr7
  [ "$status" -eq 0 ]

  local review_id="runr7-i1-review"
  [ "$(jq -r .review "$BUS/loop/runr7/state.jsonl")" = "findings" ]
  [ -f "$BUS/limits/$review_id.parked" ]
  [ ! -f "$BUS/done/$review_id" ]
}
# Why this failed at RED time (W1 — green since W2): cmd_iterate unconditionally hard-pins review to codex regardless of kimi's
# state; codex is pre-limited, so — same gap as the FR-R2 pre-limited test above — swarm-run.sh's
# PINNED claim branch spins `limit_active && continue` forever (no bounded wait/park for a
# pre-existing limit flag), hanging `_run_pool_once` until `timeout 20` kills it: status 124, not 0.
# Even setting the hang aside, today's code never touches `limits/<id>.parked` for a pinned card
# whose limit predates the claim attempt (only a limit_error firing DURING a live attempt parks it)
# — so `$BUS/limits/$review_id.parked` would never exist regardless.

# --- spec 11 FR-S4: degraded-window gate ---------------------------------------------------------

@test "spec11 FR-S4: iterate refuses while loop/handoff-degraded.md exists; removing it unblocks" {
  LOOP_GOAL="g" LOOP_ORACLE="true" run "$LOOPSH" init rundeg
  [ "$status" -eq 0 ]
  echo "driver did things while fable was down" > "$BUS/loop/handoff-degraded.md"

  run timeout 20 "$LOOPSH" iterate rundeg
  [ "$status" -ne 0 ]
  [[ "$output" == *"degraded window un-audited"* ]]
  [[ "$output" == *"$BUS/loop/handoff-degraded.md"* ]]
  # the gate fired before the iteration ran — no state line appended
  [ ! -s "$BUS/loop/rundeg/state.jsonl" ]

  # removing the file logs the re-audit and unblocks — the refusal message is gone (a later
  # failure for unrelated fixture reasons is out of scope here; assert only the gate)
  rm "$BUS/loop/handoff-degraded.md"
  run timeout 20 "$LOOPSH" iterate rundeg
  [[ "$output" != *"degraded window un-audited"* ]]
}

# --- spec 11 closeout behaviors (pinning tests — shipped untested) -------------------------------

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

@test "spec11 FR-S2: pool-wait keepalive touches heartbeat during the pool and leaves no orphan behind" {
  # SWARM_CTL wrapper logs each verb before delegating — positive proof the keepalive FIRED
  # (heartbeat-exists alone would also pass if the keepalive were deleted outright).
  local ctl_log="$BATS_TEST_TMPDIR/ctl.calls"
  : > "$ctl_log"
  cat > "$BATS_TEST_TMPDIR/ctl-wrapper" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$1" >> "$ctl_log"
exec "$BATS_TEST_DIRNAME/../src/swarm-ctl" "\$@"
EOF
  chmod +x "$BATS_TEST_TMPDIR/ctl-wrapper"
  export SWARM_CTL="$BATS_TEST_TMPDIR/ctl-wrapper"

  LOOP_GOAL="g" LOOP_ORACLE="true" run "$LOOPSH" init runhb
  [ "$status" -eq 0 ]
  # slow pool: the exec (claude) and review (codex) waits are each long enough that the keepalive
  # subshell is genuinely alive DURING them (its first tick fires immediately, before sleep 60)
  _fake FAKE_CLAUDE_DELAY 3
  _fake FAKE_CODEX_DELAY 2
  _fake FAKE_CODEX_RESULT "VERDICT: pass"

  run timeout 30 "$LOOPSH" iterate runhb
  [ "$status" -eq 0 ]
  [ -f "$BUS/heartbeat" ]
  # 1 top-of-iterate + 1 first tick per pool keepalive (exec + review) = 3; the 60s prod interval
  # means no second tick lands inside the 3s fakes, so >= 3 proves the keepalive itself ran
  [ "$(grep -c '^heartbeat$' "$ctl_log")" -ge 3 ]
  # no orphaned keepalive loop after iterate returns (the subshell inherits the driver's argv);
  # a leftover would keep re-touching heartbeat for up to 60s, defeating spec 11's staleness signal.
  # run+status, not `! pgrep`: a !-negated pipeline is exempt from errexit/ERR-trap mid-test, so
  # its failure would be silently swallowed (bash manual; verified by mutation while writing these)
  run pgrep -f "swarm-loop.sh iterate runhb"
  [ "$status" -ne 0 ]
}

@test "spec11 FR-S4: iterate reclaims a non-fable orch-seat back to fable once the degraded file is removed" {
  LOOP_GOAL="g" LOOP_ORACLE="true" run "$LOOPSH" init runseat
  [ "$status" -eq 0 ]
  # a takeover seated kimi; the continuation driver handed back; Fable re-audited (file removed)
  printf 'kimi 1\n' > "$BUS/orch-seat"
  echo "driver did things while fable was down" > "$BUS/loop/handoff-degraded.md"
  rm "$BUS/loop/handoff-degraded.md"
  _fake FAKE_CODEX_RESULT "VERDICT: pass"

  run timeout 20 "$LOOPSH" iterate runseat
  [ "$status" -eq 0 ]
  # cmd_heartbeat never overwrites a seat — only iterate's reclaim can have flipped it back
  read -r seat _ < "$BUS/orch-seat"
  [ "$seat" = "fable" ]
  [[ "$output" == *"reclaimed"* ]]
}

@test "spec11 FR-S2: _die under LOOP_WATCHDOG=1 disarms — no tagged cron line survives an early die" {
  _install_fake_crontab
  mkdir -p "$BUS"
  local canon; canon="$(cd "$BUS" && pwd -P)"
  local tag="# unimatrix-watchdog $canon"
  printf '%s\n' \
    '15 4 * * * /usr/bin/true # other-job' \
    "*/5 * * * * true $tag" > "$FAKE_CRONTAB_FILE"

  # earliest _die in cmd_iterate that is still past the watchdog plumbing: nonexistent run id
  LOOP_WATCHDOG=1 run timeout 20 "$LOOPSH" iterate ghost
  [ "$status" -ne 0 ]
  [[ "$output" == *"no run 'ghost'"* ]]
  # deliberate close disarmed: this bus's tagged line is gone, the unrelated line survives.
  # run+status, not `! grep` (errexit-exempt mid-test — see the pgrep note in the keepalive test)
  run grep -F -- "$tag" "$FAKE_CRONTAB_FILE"
  [ "$status" -ne 0 ]
  grep -qF -- '15 4 * * * /usr/bin/true # other-job' "$FAKE_CRONTAB_FILE"
}

@test "spec11 FR-S2: attended run (no LOOP_WATCHDOG) clears a crashed unattended run's leftover cron line" {
  _install_fake_crontab
  LOOP_GOAL="g" LOOP_ORACLE="true" run "$LOOPSH" init runatt
  [ "$status" -eq 0 ]
  _fake FAKE_CODEX_RESULT "VERDICT: pass"
  local canon; canon="$(cd "$BUS" && pwd -P)"
  local tag="# unimatrix-watchdog $canon"
  # a crashed unattended run skipped disarm by design — its tagged line is still standing
  printf '%s\n' \
    '15 4 * * * /usr/bin/true # other-job' \
    "*/5 * * * * true $tag" > "$FAKE_CRONTAB_FILE"

  run timeout 30 "$LOOPSH" run runatt
  [ "$status" -eq 0 ]
  [ -f "$BUS/loop/runatt/COMPLETE.md" ]
  # run+status, not `! grep` (errexit-exempt mid-test — see the pgrep note in the keepalive test)
  run grep -F -- "$tag" "$FAKE_CRONTAB_FILE"
  [ "$status" -ne 0 ]
  grep -qF -- '15 4 * * * /usr/bin/true # other-job' "$FAKE_CRONTAB_FILE"
}

# --- spec 13 FR-1: env_master_preflight before the run's first iteration ------------------------

@test "spec13 FR-1: init aborts loudly before any iteration when EXEC_CHAIN needs an env-key lane and ENV_MASTER_FILE is unreadable" {
  LOOP_GOAL="g" LOOP_ORACLE="true" EXEC_CHAIN="claude:opus glm:glm-5.2" \
    ENV_MASTER_FILE="$BATS_TEST_TMPDIR/no-such-envmaster" run "$LOOPSH" init runpf1
  [ "$status" -ne 0 ]
  [ ! -f "$BUS/loop/runpf1/criteria.md" ]
  [[ "$output" == *"ENV_MASTER_FILE"* ]]
}

@test "spec13 FR-1: init proceeds normally for a claude/codex-only EXEC_CHAIN even with an unreadable ENV_MASTER_FILE" {
  LOOP_GOAL="g" LOOP_ORACLE="true" ENV_MASTER_FILE="$BATS_TEST_TMPDIR/no-such-envmaster" \
    run "$LOOPSH" init runpf2
  [ "$status" -eq 0 ]
  [ -f "$BUS/loop/runpf2/criteria.md" ]
}
