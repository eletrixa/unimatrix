#!/usr/bin/env bats
# Integration tests for swarm-run.sh full mode — shard 1/4 of the former tests/swarm-run.bats,
# split so check.sh's CHECK_JOBS per-file fan-out gets a shorter critical path. No real API calls —
# every claude/codex/gemini invocation resolves to a fake script under $BATS_TEST_TMPDIR/bin,
# installed by the shared fixture this file loads.
#
# Project: unimatrix — multi-model swarm orchestrator driven from Claude Code
# Module:  tests/swarm-run-1.bats
# Deps:    bats-core, tests/helpers/swarm-run-fixture.bash (setup/teardown + fakes + helpers), src/swarm-lib.sh, swarm-run.sh
# Tested:  n/a — this is the test file
#
# Design constraints:
# - All file-scope state, setup()/teardown(), fake installers, and probe/fixture helpers live in
#   tests/helpers/swarm-run-fixture.bash — pulled in by the `load` below (bats resolves it against
#   this file's own dir and picks setup/teardown up from the fixture).
# - Test bodies are verbatim from the original file; original order is preserved within the shard.

load 'helpers/swarm-run-fixture'
@test "happy path: 3 branches complete, res-*.txt normalized (claude-shaped)" {
  _write_conf
  _enqueue b1 "branch one"
  _enqueue b2 "branch two"
  _enqueue b3 "branch three"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]

  [ -f "$BUS/done/b1" ]; [ -f "$BUS/done/b2" ]; [ -f "$BUS/done/b3" ]
  [ "$(<"$BUS/res-b1.txt")" = "OK" ]
  [ "$(<"$BUS/res-b2.txt")" = "OK" ]
  [ "$(<"$BUS/res-b3.txt")" = "OK" ]
  # no duplicate/leftover claims — every branch resolved to exactly one done marker
  [ -z "$(find "$BUS/claimed" -maxdepth 1 -type f 2>/dev/null)" ]
}

@test "P0-FR4: full_run prints one banner naming root/branch/head/busdir, matching git and \$BUS" {
  _write_conf "claude:opus" 4 15
  _fake FAKE_CLAUDE_RESULT "OK"
  _enqueue bn1 "banner check"

  # Computed via git, never hardcoded (a literal absolute checkout path in this file would itself
  # trip check.sh's own PII/host-path gates) — same plumbing _print_banner (swarm-run.sh) uses.
  local exp_root exp_branch exp_head
  exp_root="$(git -C "$BATS_TEST_DIRNAME" rev-parse --show-toplevel)"
  exp_branch="$(git -C "$exp_root" rev-parse --abbrev-ref HEAD)"
  exp_head="$(git -C "$exp_root" rev-parse --short HEAD)"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"unimatrix: root=$exp_root branch=$exp_branch head=$exp_head busdir=$BUS"* ]]
}

@test "P0-FR4: verify_run prints the same banner shape as full_run" {
  _write_conf "claude:opus" 4 15
  # spec20 amendment 2026-07-29: verify_run now refuses an EMPTY bus (_refuse_empty_run) — this
  # test only wants the banner line, so a done/ marker with no matching prompt-<id>.txt satisfies
  # the trap (gate_count counts it) while write_verify_spec no-ops on it (missing qfile), same
  # doctrine as "a bus resumed with only done/ entries... still closes clean" above.
  mkdir -p "$BUS/done"
  printf '{"id":"x","code":0,"lane":"claude"}\n' > "$BUS/done/x"

  local exp_root exp_branch exp_head
  exp_root="$(git -C "$BATS_TEST_DIRNAME" rev-parse --show-toplevel)"
  exp_branch="$(git -C "$exp_root" rev-parse --abbrev-ref HEAD)"
  exp_head="$(git -C "$exp_root" rev-parse --short HEAD)"

  run timeout 10 "$RUNSH" verify
  [ "$status" -eq 0 ]
  [[ "$output" == *"unimatrix: root=$exp_root branch=$exp_branch head=$exp_head busdir=$BUS"* ]]
}

@test "F1: full_run pins the resolved run label into \$BUSDIR/.run-label at run start" {
  _write_conf "claude:opus" 4 15
  _fake FAKE_CLAUDE_RESULT "OK"
  _enqueue rl1 "label check"
  export SPEEDWARS_RUN="wave-pinned"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  [ "$(<"$BUS/.run-label")" = "wave-pinned" ]
}

@test "F1: verify_run pins the run label too — a verify-only bus is still harvestable later" {
  _write_conf "claude:opus" 4 15
  export SPEEDWARS_RUN="wave-verify"
  # spec20 amendment 2026-07-29: verify_run now refuses an EMPTY bus — a done/ marker with no
  # matching prompt-<id>.txt satisfies gate_count while write_verify_spec no-ops on it.
  mkdir -p "$BUS/done"
  printf '{"id":"x","code":0,"lane":"claude"}\n' > "$BUS/done/x"

  run timeout 10 "$RUNSH" verify
  [ "$status" -eq 0 ]
  [ "$(<"$BUS/.run-label")" = "wave-verify" ]
}

@test "GLM limit error: fails over to the next EXEC_CHAIN lane and completes there" {
  # glm is deliberately first in the chain here: limit_error's z.ai-code detection is keyed on the
  # lane name (only "glm" and "codex" get special-cased; "claude" native has no spec'd limit
  # signature of its own and always falls through to a generic retry) — so the lane whose
  # invocation actually emits the fake limit code must be "glm" for this to exercise that path.
  _write_conf "glm:glm-5.2 claude:opus"
  _enqueue g1 "branch needing failover"
  printf 'Z_AI_CODING_KEY=test-glm-key\n' > "$BATS_TEST_TMPDIR/envmaster"
  export ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster"
  _fake FAKE_CLAUDE_ONCE_MARKER "$BATS_TEST_TMPDIR/g1-once"
  _fake FAKE_CLAUDE_ONCE_MODE limit
  _fake FAKE_CLAUDE_LIMIT_CODE 1308
  _fake FAKE_CLAUDE_NEXT_FLUSH "$(( $(date +%s) + 500 ))"
  _fake FAKE_CLAUDE_RESULT "claude answer"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]

  [ -f "$BUS/done/g1" ]
  [ "$(<"$BUS/res-g1.txt")" = "claude answer" ]
  # glm was actually flagged limited by the failover
  run limit_active_probe "$BUS" glm
  [ "$status" -eq 0 ]
}


# --- FR-2b: sidecar lane pin (.bus/specs/<id>.lane) --------------------------------------------

@test "FR-2b: pinned branch runs on its own lane, bypassing EXEC_CHAIN" {
  _write_conf "claude:opus" 4 15
  printf 'GEMINI_API_KEY=test-gem-key\n' > "$BATS_TEST_TMPDIR/envmaster"
  export ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster"
  _fake FAKE_CLAUDE_RESULT "chain answer"
  _fake FAKE_GEMINI_RESULT "pinned answer"
  _enqueue pin1 "pinned to gemini"
  echo "gemini:gemini-3-flash" > "$BUS/specs/pin1.lane"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/pin1" ]
  [ "$(<"$BUS/res-pin1.txt")" = "pinned answer" ]
}

@test "grok lane: pinned branch runs on grok, res file matches the fake answer, auto-ledger row records Grok" {
  _write_conf "claude:opus" 4 15
  export LEDGER_FILE="$BATS_TEST_TMPDIR/grok-ledger.md"
  _fake FAKE_GROK_RESULT "grok pinned answer"
  _fake FAKE_GROK_COST "0.0024956"
  _enqueue gk1 "pinned to grok"
  echo "grok:grok-4.5" > "$BUS/specs/gk1.lane"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/gk1" ]
  [ "$(<"$BUS/res-gk1.txt")" = "grok pinned answer" ]
  grep -q 'Grok' "$LEDGER_FILE"
}

@test "kimi lane: pinned branch runs on kimi (fake claude), res matches, auto-ledger row records Moonshot" {
  _write_conf "claude:opus" 4 15
  printf 'MOONSHOT_API_KEY=test-kimi-key\n' > "$BATS_TEST_TMPDIR/envmaster"
  export ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster"
  export LEDGER_FILE="$BATS_TEST_TMPDIR/kimi-ledger.md"
  _fake FAKE_CLAUDE_RESULT "kimi pinned answer"
  _enqueue ki1 "pinned to kimi"
  echo "kimi:kimi-k3" > "$BUS/specs/ki1.lane"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/ki1" ]
  [ "$(<"$BUS/res-ki1.txt")" = "kimi pinned answer" ]
  grep -q 'Moonshot' "$LEDGER_FILE"
}

@test "FR-2b/FR-7: pinned branch that hits a limit error parks loudly, gate closes on its own, run exits nonzero naming it" {
  # Pre-fix, a parked branch stayed "live" (still sitting in queue/) forever, so done>=live never
  # held and the pool hung until an external `swarm-ctl abort` — that was the bug, not the spec.
  # Fixed: parked counts as terminal for the gate (done+parked>=live closes it), and the driver
  # itself exits nonzero + names the parked branch (never a silent partial completion either).
  _write_conf "claude:opus" 4 15
  _enqueue pin2 "pinned branch that always limits"
  echo "glm:glm-5.2" > "$BUS/specs/pin2.lane"
  printf 'Z_AI_CODING_KEY=test-glm-key\n' > "$BATS_TEST_TMPDIR/envmaster"
  export ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster"
  _fake FAKE_CLAUDE_ONCE_MARKER "$BATS_TEST_TMPDIR/pin2-once"
  _fake FAKE_CLAUDE_ONCE_MODE limit
  _fake FAKE_CLAUDE_LIMIT_CODE 1308
  _fake FAKE_CLAUDE_NEXT_FLUSH "$(( $(date +%s) + 500 ))"

  run timeout 20 "$RUNSH"
  [ "$status" -ne 0 ]
  [[ "$output" == *"pin2"* ]]
  [ -f "$BUS/limits/pin2.parked" ]
  [ ! -e "$BUS/done/pin2" ]
  [ ! -e "$BUS/res-pin2.txt" ]
}

@test "FR-7: a run with nothing parked still exits 0" {
  _write_conf "claude:opus" 4 15
  _fake FAKE_CLAUDE_RESULT "OK"
  _enqueue np1 "nothing parked here"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
}

@test "FR-2b: mixed run — 2 pinned + 1 chain branch all complete" {
  _write_conf "claude:opus" 4 15
  printf 'GEMINI_API_KEY=test-gem-key\n' > "$BATS_TEST_TMPDIR/envmaster"
  export ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster"
  _fake FAKE_CLAUDE_RESULT "chain answer"
  _fake FAKE_GEMINI_RESULT "gemini pinned answer"
  _fake FAKE_CODEX_RESULT "codex pinned answer"

  _enqueue c1 "chain branch"

  _enqueue pg "pinned to gemini"
  echo "gemini:gemini-3-flash" > "$BUS/specs/pg.lane"

  _enqueue pc "pinned to codex"
  echo "codex:default" > "$BUS/specs/pc.lane"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]

  [ -f "$BUS/done/c1" ]; [ "$(<"$BUS/res-c1.txt")" = "chain answer" ]
  [ -f "$BUS/done/pg" ]; [ "$(<"$BUS/res-pg.txt")" = "gemini pinned answer" ]
  [ -f "$BUS/done/pc" ]; [ "$(<"$BUS/res-pc.txt")" = "codex pinned answer" ]
}

@test "kill-a-worker: a killed branch is retried and the run still completes" {
  # LEASE_MIN stays generous (default-ish) here on purpose: killing the leaf CLI process closes
  # its pipe, so _spawn_worker's pipeline finishes and the normal retry-on-failure path (not the
  # reaper) re-queues it almost immediately. A short LEASE_MIN against HEARTBEAT_SEC=1 would race
  # the reaper against the retry's own heartbeat — reap()'s own timing is already covered by its
  # dedicated unit test in tests/swarm-lib.bats.
  _write_conf "claude:opus" 4 15
  _enqueue k1 "branch that gets killed"
  _fake FAKE_CLAUDE_ONCE_MARKER "$BATS_TEST_TMPDIR/k1-once"
  _fake FAKE_CLAUDE_ONCE_MODE hang
  _fake FAKE_CLAUDE_RESULT "survived"

  "$RUNSH" 3>&- &
  BG_PIDS+=("$!")

  _poll 15 pgrep -f "branch that gets killed" || {
    echo "fake claude never started" >&2; false
  }
  # The fake CLI's `sleep 9999` (its "hang") is a CHILD process, not the matched wrapper itself —
  # killing only the wrapper leaves the sleep orphaned, still holding tee's pipe open forever.
  # Kill children first, then the wrapper.
  for wpid in $(pgrep -f "branch that gets killed"); do
    pkill -9 -P "$wpid" 2>/dev/null || true
  done
  pkill -9 -f "branch that gets killed" || true

  _poll 30 test -f "$BUS/done/k1"
  [ -f "$BUS/done/k1" ]
  [ "$(<"$BUS/res-k1.txt")" = "survived" ]

  wait "${BG_PIDS[0]}"
  BG_PIDS=()
}

@test "PAUSE mid-run blocks new claims; resume lets the run finish" {
  _write_conf "claude:opus" 1 15
  _fake FAKE_CLAUDE_DELAY 1
  _enqueue p1 "first"
  _enqueue p2 "second"

  # POOL_LINGER_SEC=10: with the 0 default the pool exits the INSTANT p1+p2 drain, racing this
  # test's PAUSE+p3 injection below — under load the first _poll's tick can land after BOTH cards
  # finished, the pool is already gone, and p3 sits in queue/ forever (the suite's chronic
  # not-ok-713: res-p1/res-p2 present, done/p3 poll times out). The linger window is the spec 21
  # FR-1 feature built for exactly this late-add shape; the test must opt in like an operator would.
  POOL_LINGER_SEC=10 "$RUNSH" 3>&- &
  BG_PIDS+=("$!")

  _poll 15 test -f "$BUS/done/p1" || _poll 15 test -e "$BUS/claimed/p1.claude:opus"
  touch "$BUS/PAUSE"
  _enqueue p3 "added-while-paused"
  mv "$BUS/specs/p3.prompt" "$BUS/queue/p3.prompt"

  sleep 2
  # p3 must never be claimed while PAUSE is set
  [ -f "$BUS/queue/p3.prompt" ]

  rm -f "$BUS/PAUSE"
  _poll 20 test -f "$BUS/done/p3"
  [ -f "$BUS/done/p1" ]; [ -f "$BUS/done/p2" ]; [ -f "$BUS/done/p3" ]

  wait "${BG_PIDS[0]}"
  BG_PIDS=()
}

@test "gate math: cancel one mid-run, add one mid-run — run completes with the right survivors" {
  _write_conf "claude:opus" 1 15
  _fake FAKE_CLAUDE_DELAY 1
  # e1 is deliberately the longest prompt: spec 21 longest-job-first claiming takes it first,
  # so e2 verifiably sits in queue/ for the mid-run cancel below (a shorter e1 made this race).
  _enqueue e1 "keep-1-longest-prompt-so-longest-first-claiming-takes-this-card-first"
  _enqueue e2 "cancel-me"
  _enqueue e3 "keep-3"

  "$RUNSH" 3>&- &
  BG_PIDS+=("$!")

  _poll 15 test -f "$BUS/queue/e2.prompt"
  mv "$BUS/queue/e2.prompt" "$BUS/cancelled/e2.prompt" 2>/dev/null || true
  _enqueue e4 "added-mid-run"
  mkdir -p "$BUS/queue"
  mv "$BUS/specs/e4.prompt" "$BUS/queue/e4.prompt"

  wait "${BG_PIDS[0]}"
  BG_PIDS=()

  [ -f "$BUS/done/e1" ]; [ -f "$BUS/done/e3" ]; [ -f "$BUS/done/e4" ]
  [ ! -e "$BUS/done/e2" ]
  [ -f "$BUS/cancelled/e2.prompt" ]
}

@test "abort via run.pgid kills the whole tree — no orphaned fake-CLI processes remain" {
  _write_conf "claude:opus" 2 15
  _enqueue a1 "abort-branch-one"
  _enqueue a2 "abort-branch-two"
  _fake FAKE_CLAUDE_DELAY 30

  "$RUNSH" 3>&- &
  BG_PIDS+=("$!")

  _poll 15 test -f "$BUS/run.pgid"
  _poll 15 pgrep -f "abort-branch-one"

  "$BATS_TEST_DIRNAME/../src/swarm-ctl" abort

  sleep 1
  run pgrep -f "abort-branch-one"
  [ "$status" -ne 0 ]
  run pgrep -f "abort-branch-two"
  [ "$status" -ne 0 ]

  wait "${BG_PIDS[0]}" 2>/dev/null || true
  BG_PIDS=()
}

@test "FR-13: TERM'ing the driver directly (not via swarm-ctl abort) still sweeps every worker" {
  # Reproduces the live E2E finding (docs/02-build-pitfalls.md): TERM-killing swarm-run.sh's own
  # pid (as opposed to `swarm-ctl abort`, which targets the pool's pgid directly) used to leave
  # workers running as orphans, because the driver process itself had no trap forwarding the
  # signal into the pool's group. See full_run's `_sweep_on_driver_term` trap.
  _write_conf "claude:opus" 2 15
  _enqueue td1 "driver-term-branch-one"
  _enqueue td2 "driver-term-branch-two"
  _fake FAKE_CLAUDE_DELAY 30

  "$RUNSH" 3>&- &
  BG_PIDS+=("$!")
  driver_pid="${BG_PIDS[0]}"

  _poll 15 pgrep -f "driver-term-branch-one"

  kill -TERM "$driver_pid"

  sleep 1
  run pgrep -f "driver-term-branch-one"
  [ "$status" -ne 0 ]
  run pgrep -f "driver-term-branch-two"
  [ "$status" -ne 0 ]

  wait "$driver_pid" 2>/dev/null || true
  BG_PIDS=()
}

@test "FR-12: a hung worker is killed at WORKER_TIMEOUT_SEC and the branch fails over to the next lane" {
  # claude:opus hangs (once) — the watchdog kills its whole subtree after WORKER_TIMEOUT_SEC=2,
  # forcing a chain-advance to glm:glm-5.2 (which re-invokes the SAME fake claude binary, but by
  # then the once-marker is already touched, so it answers normally).
  _write_conf "claude:opus glm:glm-5.2" 4 15
  cat >> "$CONF" <<'EOF'
WORKER_TIMEOUT_SEC=2
EOF
  printf 'Z_AI_CODING_KEY=test-glm-key\n' > "$BATS_TEST_TMPDIR/envmaster"
  export ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster"
  _fake FAKE_CLAUDE_ONCE_MARKER "$BATS_TEST_TMPDIR/wd1-once"
  _fake FAKE_CLAUDE_ONCE_MODE hang
  _enqueue wd1 "branch whose claude hangs forever"

  run timeout 25 "$RUNSH"
  [ "$status" -eq 0 ]

  [ -f "$BUS/done/wd1" ]
  [ "$(<"$BUS/res-wd1.txt")" = "OK" ]
  # the hung claude attempt (and any child it forked) was actually killed, not left orphaned
  run pgrep -f "branch whose claude hangs forever"
  [ "$status" -ne 0 ]
}

@test "spec01 FR-A attribution: the timeout finalize-tail requeue names its own mover" {
  _write_conf "claude:opus glm:glm-5.2" 4 15
  cat >> "$CONF" <<'EOF'
WORKER_TIMEOUT_SEC=2
EOF
  printf 'Z_AI_CODING_KEY=test-glm-key\n' > "$BATS_TEST_TMPDIR/envmaster"
  export ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster"
  _fake FAKE_CLAUDE_ONCE_MARKER "$BATS_TEST_TMPDIR/wda-once"
  _fake FAKE_CLAUDE_ONCE_MODE hang
  _enqueue wda "branch whose claude hangs, requeued via the timeout finalize-tail"

  run timeout 25 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/wda" ]
  [[ "$output" == *"mover=finalize-tail requeued wda"*"timeout"* ]]
}

@test "FR-11: a lane with no usable key is flagged loudly and failed over, not silently retried forever" {
  _write_conf "glm:glm-5.2 claude:opus"
  _enqueue nk1 "branch with no glm key"
  # spec 13 FR-1: an UNREADABLE env-master file for a glm-touching run now aborts at launch
  # preflight, before any spawn — that exact scenario has its own dedicated preflight test below.
  # This test's own intent (FR-11: a READABLE file simply missing glm's key is a normal spawn-time
  # lane_cmd failure, flagged + failed over) still needs a file that EXISTS but lacks the key.
  printf 'UNRELATED_KEY=x\n' > "$BATS_TEST_TMPDIR/envmaster"
  export ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster"
  _fake FAKE_CLAUDE_RESULT "fallback answer"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]

  [ -f "$BUS/done/nk1" ]
  [ "$(<"$BUS/res-nk1.txt")" = "fallback answer" ]
  run limit_active_probe "$BUS" glm
  [ "$status" -eq 0 ]
}

@test "spec01 FR-A attribution: the spawn-fail finalize-tail requeue names its own mover" {
  _write_conf "glm:glm-5.2 claude:opus"
  _enqueue nk2 "branch with no glm key, requeued via the spawn-fail finalize-tail"
  printf 'UNRELATED_KEY=x\n' > "$BATS_TEST_TMPDIR/envmaster"
  export ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster"
  _fake FAKE_CLAUDE_RESULT "fallback answer"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/nk2" ]
  [[ "$output" == *"mover=finalize-tail requeued nk2"*"spawn-fail"* ]]
}

@test "env scrub: GLM worker env is env -i'd — only ANTHROPIC_AUTH_TOKEN present, no ANTHROPIC_API_KEY, no real-HOME paths" {
  _write_conf "glm:glm-5.2" 1 15
  printf 'Z_AI_CODING_KEY=test-glm-key\n' > "$BATS_TEST_TMPDIR/envmaster"
  export ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster"
  _fake FAKE_CLAUDE_DUMP_ENV "$BATS_TEST_TMPDIR/dumped.env"
  export ANTHROPIC_API_KEY="leaked-fable-key"
  mkdir -p "$HOME/s"
  echo "SUPER_SECRET=leak" > "$HOME/s/.env.master"
  _enqueue sc1 "scrub check"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]

  [ -f "$BATS_TEST_TMPDIR/dumped.env" ]
  ! grep -q "^ANTHROPIC_API_KEY=" "$BATS_TEST_TMPDIR/dumped.env"
  ! grep -q "leaked-fable-key" "$BATS_TEST_TMPDIR/dumped.env"
  ! grep -q "$HOME/s" "$BATS_TEST_TMPDIR/dumped.env"
  grep -q "^ANTHROPIC_AUTH_TOKEN=test-glm-key$" "$BATS_TEST_TMPDIR/dumped.env"
  grep -q "^HOME=$BUS/home/glm.sc1$" "$BATS_TEST_TMPDIR/dumped.env"
}

@test "gemini contract survives env -i: trust var + key present, no --sandbox (live E2E finding: --sandbox re-exec strips the trust var, exit 55)" {
  _write_conf "gemini:gemini-3-flash" 1 15
  printf 'GEMINI_API_KEY=test-gem-key\n' > "$BATS_TEST_TMPDIR/envmaster"
  export ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster"
  _fake FAKE_GEMINI_DUMP_ENV "$BATS_TEST_TMPDIR/gemini.env"
  _enqueue gm1 "gemini contract check"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]

  [ -f "$BATS_TEST_TMPDIR/gemini.env" ]
  grep -q "^GEMINI_CLI_TRUST_WORKSPACE=true$" "$BATS_TEST_TMPDIR/gemini.env"
  grep -q "^GEMINI_API_KEY=test-gem-key$" "$BATS_TEST_TMPDIR/gemini.env"
}

@test "FR-16: GEMINI_SANDBOX=docker — full round trip through the fake docker wrap, exact -e allowlist, no -v/--mount, pinned image, branch still completes" {
  _write_conf "gemini:gemini-3-flash" 1 15
  printf 'GEMINI_API_KEY=test-gem-key\n' > "$BATS_TEST_TMPDIR/envmaster"
  export ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster"
  export GEMINI_SANDBOX=docker
  _fake FAKE_DOCKER_ARGV_FILE "$BATS_TEST_TMPDIR/docker.argv"
  _fake FAKE_GEMINI_RESULT "sandboxed gemini answer"
  _enqueue gd1 "gemini sandboxed check"
  echo "gemini:gemini-3-flash" > "$BUS/specs/gd1.lane"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]

  [ -f "$BUS/done/gd1" ]
  [ "$(<"$BUS/res-gd1.txt")" = "sandboxed gemini answer" ]

  [ -f "$BATS_TEST_TMPDIR/docker.argv" ]
  argv="$(<"$BATS_TEST_TMPDIR/docker.argv")"
  # bare `-e NAME` allowlist (value comes from the caged docker-client env), pinned image, gemini argv
  [[ "$argv" == "run --rm -i -e GEMINI_API_KEY -e GEMINI_CLI_TRUST_WORKSPACE unimatrix-gemini-lane:0.49.0 gemini -m gemini-3-flash -o stream-json -p gemini sandboxed check" ]]
  # the plaintext key VALUE must never appear in docker's argv (/proc/<pid>/cmdline)
  [[ "$argv" != *"test-gem-key"* ]]
  [[ "$argv" != *" -v "* ]]
  [[ "$argv" != *"--mount"* ]]
}

@test "GLM model pin: all three tier envs match the pinned model, not hardcoded per-tier (live E2E finding: glm-4.7 pin served by glm-5.2)" {
  _write_conf "glm:glm-4.7" 1 15
  printf 'Z_AI_CODING_KEY=test-glm-key\n' > "$BATS_TEST_TMPDIR/envmaster"
  export ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster"
  _fake FAKE_CLAUDE_DUMP_ENV "$BATS_TEST_TMPDIR/dumped.env"
  _enqueue g1 "model pin check"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]

  grep -q "^ANTHROPIC_DEFAULT_HAIKU_MODEL=glm-4.7$" "$BATS_TEST_TMPDIR/dumped.env"
  grep -q "^ANTHROPIC_DEFAULT_SONNET_MODEL=glm-4.7$" "$BATS_TEST_TMPDIR/dumped.env"
  grep -q "^ANTHROPIC_DEFAULT_OPUS_MODEL=glm-4.7$" "$BATS_TEST_TMPDIR/dumped.env"
}

@test "FR-14: a stale (lease-reaped) worker's late finish never overwrites the retry's result" {
  # Simulates the exact race the codex lane hit in the swarm's own first E2E run: a worker is
  # slow but genuinely alive (not hung — "slow" finishes on its own, unlike "hang"). Its lease
  # gets reaped (here: a direct mv, the same move reap() itself does — deterministic, no reliance
  # on real minute-granularity mtime timing) WHILE it's still mid-sleep. The pool's own `wait -n`
  # only re-scans queue/ once the in-flight job actually completes, so the concrete order here is:
  # the stolen original wakes up first and its OWN finalize gets fenced out (its claim file is
  # gone — nothing recreated it yet); the pool then re-claims and completes a fresh attempt. Either
  # ordering exercises the same guarantee: a worker whose claim-file token no longer matches at
  # finalize time must never write res-<id>.txt/done, no matter which one runs "second."
  _write_conf "claude:opus" 2 15
  _fake FAKE_CLAUDE_ONCE_MARKER "$BATS_TEST_TMPDIR/f1-once"
  _fake FAKE_CLAUDE_ONCE_MODE slow
  _fake FAKE_CLAUDE_SLOW_SEC 4
  _fake FAKE_CLAUDE_SLOW_RESULT "stale answer"
  _fake FAKE_CLAUDE_RESULT "fresh answer"
  _enqueue f1 "lease-steal race branch"

  "$RUNSH" 3>&- &
  BG_PIDS+=("$!")

  _poll 15 test -e "$BUS/claimed/f1.claude:opus"
  # Wait for the fake's once-marker (mkdir'd at slow-arm START, before its 4s sleep) — proof the
  # original worker actually READ the prompt and is now mid-sleep. Stealing on the claim file
  # alone raced the worker's own prompt read (claim→spawn latency): a too-early steal killed the
  # original with "no claim file" BEFORE it consumed the slow-once arm, handing the retry the
  # "stale answer" as its legitimate result (2026-08-01 flake).
  _poll 15 test -d "$BATS_TEST_TMPDIR/f1-once"
  # "Steal" the lease exactly the way reap() would (mv claimed -> queue) while the original
  # (still sleeping its bounded 4s) is genuinely still running as a real process.
  mv "$BUS/claimed/f1.claude:opus" "$BUS/queue/f1.prompt"

  _poll 15 test -f "$BUS/done/f1"
  [ "$(<"$BUS/res-f1.txt")" = "fresh answer" ]
  done_mtime_1="$(stat -c %Y "$BUS/done/f1")"

  # Let the stale original actually finish and attempt to finalize — must be fenced out as a no-op.
  # NOTE: not asserting the stale-finalize jsonl record's survival here — run-<id>.jsonl is a
  # single shared path across retry attempts (each attempt's `tee` truncates it), so this retry's
  # OWN successful tee can legitimately wipe out a marker the stale attempt wrote moments earlier.
  # That's a separate, pre-existing gap (same file shared across attempts), not a fencing bug — the
  # guarantee this test protects is res-<id>.txt/done never getting the stale attempt's answer.
  sleep 4
  [ "$(<"$BUS/res-f1.txt")" = "fresh answer" ]
  # done/f1 written exactly once: the stale finalize must not have touched it a second time.
  [ "$(stat -c %Y "$BUS/done/f1")" = "$done_mtime_1" ]

  wait "${BG_PIDS[0]}"
  BG_PIDS=()
}

@test "provenance: done marker records the lane that actually generated the answer" {
  _write_conf "claude:opus" 4 15
  _fake FAKE_CLAUDE_RESULT "OK"
  _enqueue pv1 "provenance check"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.lane' "$BUS/done/pv1")" = "claude" ]
}

@test "LEDGER_AUTO default: a successful run auto-appends a ledger row at the default (busdir-relative) path" {
  _write_conf "claude:opus" 4 15
  _fake FAKE_CLAUDE_RESULT "OK"
  _enqueue la1 "ledger default path check"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/docs/ops/llm-runs.md" ]
  grep -q 'ledger default path check' "$BATS_TEST_TMPDIR/docs/ops/llm-runs.md"
  grep -q 'Anthropic API (session auth)' "$BATS_TEST_TMPDIR/docs/ops/llm-runs.md"
}

@test "LEDGER_AUTO=0: a successful run never touches the ledger file" {
  _write_conf "claude:opus" 4 15
  cat >> "$CONF" <<'EOF'
LEDGER_AUTO=0
EOF
  _fake FAKE_CLAUDE_RESULT "OK"
  _enqueue la2 "ledger off check"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/docs" ]
}

# --- verify wave (Phase E step 4) ------------------------------------------------------------

@test "verify: with nothing done yet, verify subcommand aborts nonzero (spec20 amendment 2026-07-29: an empty bus is a trap, not a silent no-op)" {
  _write_conf "claude:opus" 4 15
  run timeout 10 "$RUNSH" verify
  [ "$status" -ne 0 ]
  [[ "$output" == *"nothing to run"* ]]
}

@test "verify wave: 2 branches on different lanes get verified by the VERIFY_MAP-mapped opposite lane" {
  _write_conf "claude:opus" 4 15
  printf 'GEMINI_API_KEY=test-gem-key\nMOONSHOT_API_KEY=test-kimi-key\n' > "$BATS_TEST_TMPDIR/envmaster"
  export ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster"
  _fake FAKE_CLAUDE_RESULT "claude generated answer"
  _fake FAKE_CODEX_RESULT "codex generated answer"

  _enqueue gc "generated by claude"
  echo "claude:opus" > "$BUS/specs/gc.lane"
  _enqueue gx "generated by codex"
  echo "codex:default" > "$BUS/specs/gx.lane"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/gc" ]; [ -f "$BUS/done/gx" ]

  # Distinguish a verify-wave answer from the generate-wave one on the SAME fakes.
  _fake FAKE_CLAUDE_RESULT "claude verify answer"
  _fake FAKE_CODEX_RESULT "codex verify answer"

  run timeout 20 "$RUNSH" verify
  [ "$status" -eq 0 ]

  [ -f "$BUS/done/v-gc" ]
  [ "$(<"$BUS/res-v-gc.txt")" = "codex verify answer" ]   # default VERIFY_MAP: claude -> codex
  [[ "$(<"$BUS/specs/gc.prompt" 2>/dev/null || echo gone)" == "gone" ]]  # original spec consumed

  [ -f "$BUS/done/v-gx" ]
  # default VERIFY_MAP (spec 10 sync): codex -> kimi; the kimi lane rides the fake claude binary
  [ "$(<"$BUS/res-v-gx.txt")" = "claude verify answer" ]
  [ "$(jq -r '.lane' "$BUS/done/v-gx")" = "kimi" ]
}

@test "verify wave: re-running verify after it already completed is a harmless no-op (idempotent)" {
  _write_conf "claude:opus" 4 15
  _fake FAKE_CLAUDE_RESULT "gen answer"
  _enqueue iv1 "idempotent verify check"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]

  run timeout 20 "$RUNSH" verify
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/v-iv1" ]
  first_mtime="$(stat -c %Y "$BUS/done/v-iv1")"

  run timeout 20 "$RUNSH" verify
  [ "$status" -eq 0 ]
  [ "$(stat -c %Y "$BUS/done/v-iv1")" = "$first_mtime" ]
}

# --- FR-15: write-capable exec branches (.bus/specs/<id>.write sidecar) ------------------------

@test "FR-15: write sidecar — claude runs in the target dir, creates a file there, sidecar cleaned up on finalize" {
  _write_conf "claude:opus" 4 15
  local target="$BATS_TEST_TMPDIR/writetarget"
  mkdir -p "$target"
  _fake FAKE_CLAUDE_RESULT "wrote it"
  _fake FAKE_CLAUDE_WRITE_FILE "created.txt"
  _fake FAKE_CLAUDE_WRITE_CONTENT "hello from worker"
  _enqueue w1 "write something to the target dir"
  printf '%s' "$target" > "$BUS/specs/w1.write"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]

  [ -f "$BUS/done/w1" ]
  [ "$(<"$BUS/res-w1.txt")" = "wrote it" ]
  [ -f "$target/created.txt" ]
  [ "$(<"$target/created.txt")" = "hello from worker" ]
  [ ! -e "$BUS/queue/w1.write" ]
}

@test "FR-15: gemini pinned + write sidecar refuses loudly and parks (not a write-capable lane in v1)" {
  _write_conf "claude:opus" 4 15
  printf 'GEMINI_API_KEY=test-gem-key\n' > "$BATS_TEST_TMPDIR/envmaster"
  export ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster"
  local target="$BATS_TEST_TMPDIR/writetarget2"
  mkdir -p "$target"
  _enqueue wg1 "gemini pinned write attempt"
  echo "gemini:gemini-3-flash" > "$BUS/specs/wg1.lane"
  printf '%s' "$target" > "$BUS/specs/wg1.write"

  run timeout 20 "$RUNSH"
  [ "$status" -ne 0 ]
  [[ "$output" == *"wg1"* ]]
  [ -f "$BUS/limits/wg1.parked" ]
  [ ! -e "$BUS/done/wg1" ]
}

@test "FIX 2: a relative BUSDIR still resolves the codex handoff to the real busdir under a write sidecar's env -C chdir" {
  cd "$BATS_TEST_TMPDIR"
  export BUSDIR="relbus"
  mkdir -p "$BUSDIR/specs"
  cat > "$CONF" <<EOF
EXEC_CHAIN="codex:default"
FANOUT=4
LEASE_MIN=15
EOF
  local target="$BATS_TEST_TMPDIR/writetarget3"
  mkdir -p "$target"
  _fake FAKE_CODEX_RESULT "codex wrote it"
  # spec10 FR-R11 diff gate: a .write card must actually touch its target to finalize done
  _fake FAKE_CODEX_WRITE_FILE "handoff-artifact.txt"
  printf '%s' "write something" > "$BUSDIR/specs/rb1.prompt"
  printf '%s' "$target" > "$BUSDIR/specs/rb1.write"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]

  [ -f "$BATS_TEST_TMPDIR/relbus/done/rb1" ]
  [ -f "$BATS_TEST_TMPDIR/relbus/res-rb1.txt" ]
  [ "$(<"$BATS_TEST_TMPDIR/relbus/res-rb1.txt")" = "codex wrote it" ]
}

@test "config subcommand: prints the resolved table and edits swarm.conf in place" {
  _write_conf "claude:opus" 4 15
  run "$RUNSH" config
  [ "$status" -eq 0 ]
  [[ "$output" == *"FANOUT"* ]]

  run "$RUNSH" config FANOUT 9
  [ "$status" -eq 0 ]
  grep -q '^FANOUT="9"$' "$CONF"
}

@test "config: value with sed-active chars (&, |) is written literally and the conf still sources" {
  _write_conf "claude:opus" 4 15
  run "$RUNSH" config EXEC_CHAIN 'a&b|c'
  [ "$status" -eq 0 ]
  grep -qF 'EXEC_CHAIN="a&b|c"' "$CONF"
  # the whole conf must remain bash-sourceable (conf_load does `source "$conffile"`)
  run bash -n "$CONF"
  [ "$status" -eq 0 ]
  run bash -c "source '$CONF'"
  [ "$status" -eq 0 ]
}

@test "config: a value containing a double-quote is refused loudly (would corrupt the conf's own quoting)" {
  _write_conf "claude:opus" 4 15
  local before; before="$(cat "$CONF")"
  run "$RUNSH" config REVIEW 'say "hi"'
  [ "$status" -ne 0 ]
  # conf untouched
  [ "$(cat "$CONF")" = "$before" ]
}

@test "config: KEY with no value fails with usage, not an unbound-variable crash" {
  _write_conf "claude:opus" 4 15
  run "$RUNSH" config FANOUT
  [ "$status" -ne 0 ]
  [[ "$output" != *"unbound variable"* ]]
}

@test "plan_only: writes no run.pgid (it starts no pool — a stale PID there would mis-target swarm-ctl abort)" {
  _write_conf "claude:opus" 4 15
  run "$RUNSH" --plan-only "some question"
  [ "$status" -eq 0 ]
  [ ! -e "$BUS/run.pgid" ]
}

@test "ledger no-silent-spend: a timed-out worker still lands a ledger row (a CLI was spawned and spent)" {
  _write_conf "claude:opus" 1 15
  export LEDGER_FILE="$BATS_TEST_TMPDIR/spend-ledger.md"
  export WORKER_TIMEOUT_SEC=1
  _fake FAKE_CLAUDE_ONCE_MARKER "$BATS_TEST_TMPDIR/to-once"
  _fake FAKE_CLAUDE_ONCE_MODE hang
  _fake FAKE_CLAUDE_RESULT "eventual answer"
  _enqueue to1 "branch whose first attempt hangs then times out"

  run timeout 30 "$RUNSH"
  # a ledger row must exist mentioning the timed-out spawn (no silent spend), even though the
  # branch later completed on retry
  [ -f "$LEDGER_FILE" ]
  grep -q 'to1' "$LEDGER_FILE"
  grep -qi 'timeout\|timed out\|failed\|partial' "$LEDGER_FILE"
}

# --- bounded same-lane retry (FR-6 addendum: MAX_LANE_RETRIES) ---------------------------------

@test "retry cap: a lane that never yields a usable answer parks after MAX_LANE_RETRIES — never loops forever" {
  _write_conf "claude:opus"
  _fake FAKE_CLAUDE_GARBAGE_COUNT "$BATS_TEST_TMPDIR/garbage-count"
  _enqueue rc1 "spec that can never complete"

  run timeout 25 "$RUNSH"
  # pre-fix this hung until `timeout` killed it (rc 124): the unrecognized-failure path re-queued
  # the same lane unbounded, so the spec was never done nor parked and the pool gate never closed
  [ "$status" -ne 124 ]
  [ "$status" -ne 0 ]  # parked branch -> loud nonzero naming it, same as FR-7
  [[ "$output" == *"rc1"* ]]
  [ -f "$BUS/limits/rc1.parked" ]
  [ ! -e "$BUS/done/rc1" ]
  # exactly MAX_LANE_RETRIES (default 3) spawns — bounded spend, not one-shot, not unbounded
  [ "$(wc -l < "$BATS_TEST_TMPDIR/garbage-count")" -eq 3 ]
}

@test "retry cap: after same-lane retries exhaust, the chain advances and the next lane completes" {
  _write_conf "claude:opus gemini:gemini-3-flash"
  printf 'GEMINI_API_KEY=test-gem-key\n' > "$BATS_TEST_TMPDIR/envmaster"
  export ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster"
  _fake FAKE_CLAUDE_GARBAGE_COUNT "$BATS_TEST_TMPDIR/garbage-count"
  _fake FAKE_GEMINI_RESULT "rescued by gemini"
  _enqueue rc2 "spec rescued by failover"

  run timeout 25 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/rc2" ]
  [ "$(<"$BUS/res-rc2.txt")" = "rescued by gemini" ]
  [ "$(wc -l < "$BATS_TEST_TMPDIR/garbage-count")" -eq 3 ]
  # counter cleared on lane change / completion — no stale budget for a later same-id run
  [ ! -e "$BUS/limits/.retries-rc2" ]
}
