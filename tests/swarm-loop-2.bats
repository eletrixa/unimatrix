#!/usr/bin/env bats
# Tests for swarm-loop.sh (shard 2/3 of the former tests/swarm-loop.bats): the 2026-07-12
# remediation suite (judge!=executor, review-sees-diff, oracle cage, budget cap, per-iteration
# commit, oscillation ordering) and spec 10 role-classes judge fallback (FR-R2/R3/R7). Loads the
# shared fixture (fake claude/codex + fake oracles) — no real API calls.
#
# Project: unimatrix — multi-model swarm orchestrator driven from Claude Code
# Module:  tests/swarm-loop-2.bats
# Deps:    bats-core, swarm-loop.sh, swarm-run.sh, src/swarm-lib.sh, fake claude/codex on PATH
# Tested:  n/a — this is the test file

load 'helpers/swarm-loop-fixture'

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
