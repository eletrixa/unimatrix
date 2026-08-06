#!/usr/bin/env bats
# Tests for swarm-loop.sh (shard 3/3 of the former tests/swarm-loop.bats): the iterate verb
# (criteria checksum guard, fail-closed review, state.jsonl, steering accrual) and spec 11
# (degraded-window gate, pool-wait keepalive, orch-seat reclaim, watchdog cron disarm). Loads the
# shared fixture (fake claude/codex + fake oracles) — no real API calls.
#
# Project: unimatrix — multi-model swarm orchestrator driven from Claude Code
# Module:  tests/swarm-loop-3.bats
# Deps:    bats-core, swarm-loop.sh, swarm-run.sh, src/swarm-lib.sh, fake claude/codex on PATH
# Tested:  n/a — this is the test file

load 'helpers/swarm-loop-fixture'

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
