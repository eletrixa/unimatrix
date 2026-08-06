#!/usr/bin/env bats
# Tests for swarm-loop.sh (shard 1/3 of the former tests/swarm-loop.bats): init scaffolding,
# scratch git worktrees, the `run` stop-rule ladder (goal/plateau/oscillation/max_iterations/
# human_gate), spec 13 env-master preflight, and spec 20 --run pass-through. Loads the shared
# fixture (fake claude/codex + fake oracles) — no real API calls.
#
# Project: unimatrix — multi-model swarm orchestrator driven from Claude Code
# Module:  tests/swarm-loop-1.bats
# Deps:    bats-core, swarm-loop.sh, swarm-run.sh, src/swarm-lib.sh, fake claude/codex on PATH
# Tested:  n/a — this is the test file

load 'helpers/swarm-loop-fixture'

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

# --- spec 20 FR-5: --run pass-through ------------------------------------------------------------

@test "spec20 FR-5: swarm-loop --run derives the namespaced busdir for init" {
  export UNIMATRIX_BUS_ROOT="$BATS_TEST_TMPDIR"
  LOOP_GOAL="ns goal" LOOP_ORACLE="true" run env -u BUSDIR -u SPEEDWARS_RUN "$LOOPSH" --run nsalpha init nsr1
  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/.bus-nsalpha/loop/nsr1/criteria.md" ]
}

@test "spec20 FR-5: an invalid --run label is refused at parse time" {
  run "$LOOPSH" --run "../evil" init x1
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid --run label"* ]]
}
