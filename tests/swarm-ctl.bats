#!/usr/bin/env bats
# Happy-path tests for src/swarm-ctl: bus-only control verbs.
#
# Project: unimatrix — multi-model swarm orchestrator driven from Claude Code
# Module:  tests/swarm-ctl.bats
# Deps:    bats-core, src/swarm-lib.sh, src/swarm-ctl
# Tested:  n/a — this is the test file

setup() {
  CTL="$BATS_TEST_DIRNAME/../src/swarm-ctl"
  LIB="$BATS_TEST_DIRNAME/../src/swarm-lib.sh"
  # shellcheck source=/dev/null
  source "$LIB"
  BUS="$BATS_TEST_TMPDIR/bus"
  bus_init "$BUS"
}

teardown() {
  # kill tests background a real marker sleep — belt-and-braces cleanup if a test fails uncleanly
  pkill -9 -f "swarm-ctl-kill-test-marker" 2>/dev/null || true
  return 0
}

@test "swarm-ctl pause: creates the PAUSE flag" {
  BUSDIR="$BUS" run "$CTL" pause
  [ "$status" -eq 0 ]
  [ -f "$BUS/PAUSE" ]
}

@test "swarm-ctl resume: removes the PAUSE flag" {
  touch "$BUS/PAUSE"
  BUSDIR="$BUS" run "$CTL" resume
  [ "$status" -eq 0 ]
  [ ! -f "$BUS/PAUSE" ]
}

@test "swarm-ctl cancel: moves a queued spec into cancelled/" {
  echo "x" > "$BUS/queue/c1.prompt"
  BUSDIR="$BUS" run "$CTL" cancel c1
  [ "$status" -eq 0 ]
  [ -f "$BUS/cancelled/c1.prompt" ]
  [ ! -f "$BUS/queue/c1.prompt" ]
}

@test "swarm-ctl cancel: moves a still-unqueued spec (in specs/) into cancelled/" {
  echo "x" > "$BUS/specs/c2.prompt"
  BUSDIR="$BUS" run "$CTL" cancel c2
  [ "$status" -eq 0 ]
  [ -f "$BUS/cancelled/c2.prompt" ]
  [ ! -f "$BUS/specs/c2.prompt" ]
}

@test "swarm-ctl cancel: unknown id fails loudly" {
  BUSDIR="$BUS" run "$CTL" cancel nope
  [ "$status" -ne 0 ]
}

@test "swarm-ctl cancel: also removes the .lane/.write sidecars so a later same-id add can't inherit them" {
  echo "x" > "$BUS/queue/cs1.prompt"
  echo "gemini:gemini-3-flash" > "$BUS/queue/cs1.lane"
  echo "/some/secret/dir" > "$BUS/queue/cs1.write"
  BUSDIR="$BUS" run "$CTL" cancel cs1
  [ "$status" -eq 0 ]
  [ -f "$BUS/cancelled/cs1.prompt" ]
  # no orphan sidecars left in queue/ to poison a future same-id spec
  [ ! -e "$BUS/queue/cs1.lane" ]
  [ ! -e "$BUS/queue/cs1.write" ]
}

@test "swarm-ctl add: cp's the promptfile into specs/ then mv's it to queue/" {
  echo "task" > "$BATS_TEST_TMPDIR/new.prompt"
  BUSDIR="$BUS" run "$CTL" add "$BATS_TEST_TMPDIR/new.prompt"
  [ "$status" -eq 0 ]
  [ -f "$BUS/queue/new.prompt" ]
  [ ! -f "$BUS/specs/new.prompt" ]
  [ -f "$BATS_TEST_TMPDIR/new.prompt" ]  # source untouched — it was cp'd, not mv'd
}

@test "swarm-ctl status: prints gate counts, no limit lines when none active" {
  echo "x" > "$BUS/queue/s1.prompt"
  BUSDIR="$BUS" run "$CTL" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"gate: done=0 live=1"* ]]
  [[ "$output" != *"limit:"* ]]
}

@test "swarm-ctl status: reports an active limit flag" {
  limit_flag "$BUS" glm 100
  BUSDIR="$BUS" run "$CTL" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"limit: glm ACTIVE"* ]]
}

@test "swarm-ctl kill: unknown id (no pid recorded) fails loudly" {
  BUSDIR="$BUS" run "$CTL" kill someid
  [ "$status" -ne 0 ]
}

@test "swarm-ctl kill: terminates the registered worker and requeues its claim by default" {
  echo "task" > "$BUS/claimed/k1.claude:opus"
  ( exec -a swarm-ctl-kill-test-marker sleep 9999 ) 3>&- &
  wpid=$!
  echo "$wpid" > "$BUS/pids/k1"

  BUSDIR="$BUS" run "$CTL" kill k1
  [ "$status" -eq 0 ]
  [ -f "$BUS/queue/k1.prompt" ]
  [ ! -f "$BUS/claimed/k1.claude:opus" ]
  [ ! -f "$BUS/pids/k1" ]
  for _ in $(seq 1 20); do pgrep -f swarm-ctl-kill-test-marker >/dev/null || break; sleep 0.1; done
  run pgrep -f swarm-ctl-kill-test-marker
  [ "$status" -ne 0 ]
}

@test "swarm-ctl kill --cancel: terminates the worker and cancels instead of requeuing" {
  echo "task" > "$BUS/claimed/k2.claude:opus"
  ( exec -a swarm-ctl-kill-test-marker sleep 9999 ) 3>&- &
  wpid=$!
  echo "$wpid" > "$BUS/pids/k2"

  BUSDIR="$BUS" run "$CTL" kill k2 --cancel
  [ "$status" -eq 0 ]
  [ -f "$BUS/cancelled/k2.prompt" ]
  [ ! -f "$BUS/claimed/k2.claude:opus" ]
  [ ! -f "$BUS/queue/k2.prompt" ]
  for _ in $(seq 1 20); do pgrep -f swarm-ctl-kill-test-marker >/dev/null || break; sleep 0.1; done
  run pgrep -f swarm-ctl-kill-test-marker
  [ "$status" -ne 0 ]
}

@test "swarm-ctl kill --cancel: also clears the .lane/.write sidecars (no orphan for a same-id add)" {
  echo "task" > "$BUS/claimed/k3.gemini:gemini-3-flash"
  echo "gemini:gemini-3-flash" > "$BUS/queue/k3.lane"
  echo "/some/secret/dir" > "$BUS/queue/k3.write"
  ( exec -a swarm-ctl-kill-test-marker sleep 9999 ) 3>&- &
  echo "$!" > "$BUS/pids/k3"

  BUSDIR="$BUS" run "$CTL" kill k3 --cancel
  [ "$status" -eq 0 ]
  [ -f "$BUS/cancelled/k3.prompt" ]
  [ ! -e "$BUS/queue/k3.lane" ]
  [ ! -e "$BUS/queue/k3.write" ]
}

@test "swarm-ctl abort: refuses a stale run.pgid whose process group is already dead" {
  # a stale/bogus pgid must not be blindly TERM'd (pid reuse could hit an innocent group)
  echo "999999" > "$BUS/run.pgid"
  BUSDIR="$BUS" run "$CTL" abort
  [ "$status" -ne 0 ]
  [[ "$output" == *"stale"* || "$output" == *"not running"* || "$output" == *"no live"* ]]
}

@test "swarm-ctl abort: no run.pgid means nothing to abort" {
  BUSDIR="$BUS" run "$CTL" abort
  [ "$status" -ne 0 ]
}

# --- spec 07 RED wave: nudge / pause-worker / resume-worker / add --lane|--write ----------
# These verbs don't exist in src/swarm-ctl yet (dispatch has no nudge / pause-worker /
# resume-worker, and `add` takes no --lane / --write). Every test below is deliberately RED
# against the current tree — it asserts the post-implementation behavior (plan §4.6 nudge,
# §4.6b SIGSTOP freeze, §5.3b·7 add sidecars) so the GREEN wave flips it. Existing tests
# above are untouched.

@test "nudge: kills the running worker's marker pid and requeues its claim to queue/<id>.prompt" {
  # §4.6 nudge step 1+2+6: kill_subtree the pids/<id> pid, then requeue claimed/<id>.* -> queue/<id>.prompt
  echo "task" > "$BUS/claimed/n1.claude:opus"
  ( exec -a swarm-ctl-kill-test-marker sleep 9999 ) 3>&- &
  wpid=$!
  echo "$wpid" > "$BUS/pids/n1"
  for _ in $(seq 1 20); do kill -0 "$wpid" 2>/dev/null && break; sleep 0.1; done

  BUSDIR="$BUS" run "$CTL" nudge n1
  [ "$status" -eq 0 ]
  [ -f "$BUS/queue/n1.prompt" ]
  [ ! -f "$BUS/claimed/n1.claude:opus" ]
  [ ! -f "$BUS/pids/n1" ]
  for _ in $(seq 1 20); do pgrep -f swarm-ctl-kill-test-marker >/dev/null || break; sleep 0.1; done
  run pgrep -f swarm-ctl-kill-test-marker
  [ "$status" -ne 0 ]
}

@test "nudge: a queued id requeues fine without any pids/<id> pidfile" {
  # §4.6 step 1 "absent = fine": nudge, unlike kill, must NOT require a recorded pid.
  printf 'queued body' > "$BUS/queue/n2.prompt"
  BUSDIR="$BUS" run "$CTL" nudge n2
  [ "$status" -eq 0 ]
  [ -f "$BUS/queue/n2.prompt" ]
  [[ "$(<"$BUS/queue/n2.prompt")" == *"queued body"* ]]
  [[ "$(<"$BUS/queue/n2.prompt")" != *"## OPERATOR HINT (nudge "* ]]
}

@test "nudge: no hint = plain kill+requeue, no OPERATOR HINT block, body preserved" {
  printf 'original body line1\nline2' > "$BUS/claimed/n3.claude:opus"
  BUSDIR="$BUS" run "$CTL" nudge n3
  [ "$status" -eq 0 ]
  [ -f "$BUS/queue/n3.prompt" ]
  [[ "$(<"$BUS/queue/n3.prompt")" != *"## OPERATOR HINT (nudge "* ]]
  [[ "$(<"$BUS/queue/n3.prompt")" == *"original body line1"* ]]
}

@test "nudge: a hint appends an '## OPERATOR HINT (nudge ...)' block carrying the hint text" {
  printf 'original body' > "$BUS/claimed/n4.claude:opus"
  BUSDIR="$BUS" run "$CTL" nudge n4 "check the upstream API contract"
  [ "$status" -eq 0 ]
  [ -f "$BUS/queue/n4.prompt" ]
  [[ "$(<"$BUS/queue/n4.prompt")" == *"## OPERATOR HINT (nudge "* ]]
  [[ "$(<"$BUS/queue/n4.prompt")" == *"check the upstream API contract"* ]]
}

@test "nudge: resets per-id state — drops .parked, .chain-<id>, .retries-<id>, <id>.timedout" {
  # §4.6 step 5: nudge = "run again from the top", so all prior failure/chain state is wiped.
  echo "task" > "$BUS/claimed/n5.claude:opus"
  touch "$BUS/limits/n5.parked"
  printf 'glm:glm-5.2' > "$BUS/limits/.chain-n5"
  printf '2' > "$BUS/limits/.retries-n5"
  touch "$BUS/limits/n5.timedout"

  BUSDIR="$BUS" run "$CTL" nudge n5
  [ "$status" -eq 0 ]
  [ -f "$BUS/queue/n5.prompt" ]
  [ ! -e "$BUS/limits/n5.parked" ]
  [ ! -e "$BUS/limits/.chain-n5" ]
  [ ! -e "$BUS/limits/.retries-n5" ]
  [ ! -e "$BUS/limits/n5.timedout" ]
}

@test "nudge: keeps the .lane and .write sidecars (requeue semantics, not cancel)" {
  echo "task" > "$BUS/claimed/n6.claude:opus"
  echo "grok:grok-4.5" > "$BUS/queue/n6.lane"
  printf '%s' "$BATS_TEST_TMPDIR/wtarget6" > "$BUS/queue/n6.write"

  BUSDIR="$BUS" run "$CTL" nudge n6
  [ "$status" -eq 0 ]
  [ -f "$BUS/queue/n6.prompt" ]
  [ -f "$BUS/queue/n6.lane" ]
  [ -f "$BUS/queue/n6.write" ]
  [ "$(<"$BUS/queue/n6.lane")" = "grok:grok-4.5" ]
}

@test "nudge: unknown / already-done id fails loudly (rc1) — not via the no-verb usage banner" {
  # id is done (neither claimed/ nor queue/ has it) -> §4.6 "neither -> rc1 loud stderr".
  printf '{"id":"n7","code":0,"lane":"claude"}\n' > "$BUS/done/n7"
  BUSDIR="$BUS" run "$CTL" nudge n7
  [ "$status" -ne 0 ]
  [ -n "$output" ]
  [[ "$output" != *"usage: swarm-ctl"* ]]
}

@test "nudge: double nudge with hints leaves exactly two OPERATOR HINT blocks and no .nudge-* temp" {
  # §4.6: idempotent — a second nudge appends a second hint block; the queue/.nudge-<id> staging
  # name must not survive the atomic mv back to queue/<id>.prompt.
  printf 'base body' > "$BUS/claimed/dn1.claude:opus"
  BUSDIR="$BUS" run "$CTL" nudge dn1 "first nudge reason"
  [ "$status" -eq 0 ]
  BUSDIR="$BUS" run "$CTL" nudge dn1 "second nudge reason"
  [ "$status" -eq 0 ]
  [ -f "$BUS/queue/dn1.prompt" ]
  count="$(grep -c '## OPERATOR HINT (nudge ' "$BUS/queue/dn1.prompt")"
  [ "$count" -eq 2 ]
  [ -z "$(find "$BUS/queue" -maxdepth 1 -name '.nudge-*' -print)" ]
}

@test "pause-worker: STOPs the marker (ps state T), writes limits/<id>.frozen, refreshes the claim lease" {
  # §4.6b cmd_pause_worker: SIGSTOP the subtree, touch claimed/<id>.* (fresh lease), touch frozen flag.
  echo "task" > "$BUS/claimed/p1.claude:opus"
  ( exec -a swarm-ctl-kill-test-marker sleep 9999 ) 3>&- &
  wpid=$!
  echo "$wpid" > "$BUS/pids/p1"
  for _ in $(seq 1 20); do kill -0 "$wpid" 2>/dev/null && break; sleep 0.1; done
  touch -d "-5 minutes" "$BUS/claimed/p1.claude:opus"
  old="$(stat -c %Y "$BUS/claimed/p1.claude:opus")"

  BUSDIR="$BUS" run "$CTL" pause-worker p1
  [ "$status" -eq 0 ]
  state=""
  for _ in $(seq 1 30); do
    state="$(ps -o state= -p "$wpid" 2>/dev/null)"
    [[ "$state" == T* ]] && break
    sleep 0.1
  done
  [[ "$state" == T* ]]
  [ -f "$BUS/limits/p1.frozen" ]
  new="$(stat -c %Y "$BUS/claimed/p1.claude:opus")"
  [ "$new" -gt "$old" ]

  kill -CONT "$wpid" 2>/dev/null || true
  kill -9 "$wpid" 2>/dev/null || true
}

@test "pause-worker: resume-worker CONTs the marker (state back to S) and removes the frozen flag" {
  # §4.6b cmd_resume_worker: SIGCONT the subtree snapshot, rm limits/<id>.frozen, touch the claim.
  echo "task" > "$BUS/claimed/p2.claude:opus"
  ( exec -a swarm-ctl-kill-test-marker sleep 9999 ) 3>&- &
  wpid=$!
  echo "$wpid" > "$BUS/pids/p2"
  for _ in $(seq 1 20); do kill -0 "$wpid" 2>/dev/null && break; sleep 0.1; done
  kill -STOP "$wpid"                       # freeze it ourselves (the prior pause-worker's effect)
  for _ in $(seq 1 20); do [[ "$(ps -o state= -p "$wpid" 2>/dev/null)" == T* ]] && break; sleep 0.1; done
  [[ "$(ps -o state= -p "$wpid" 2>/dev/null)" == T* ]]   # precondition: really STOPped
  touch "$BUS/limits/p2.frozen"

  BUSDIR="$BUS" run "$CTL" resume-worker p2
  [ "$status" -eq 0 ]
  state=""
  for _ in $(seq 1 30); do
    state="$(ps -o state= -p "$wpid" 2>/dev/null)"
    [[ "$state" == S* ]] && break
    sleep 0.1
  done
  [[ "$state" == S* ]]
  [ ! -f "$BUS/limits/p2.frozen" ]

  kill -9 "$wpid" 2>/dev/null || true
}

@test "pause-worker: kill on a frozen worker still terminates it (SIGCONT before TERM) and clears the frozen flag" {
  # §4.6b: a STOPped process ignores TERM until continued, so kill/nudge/cancel must SIGCONT first
  # and always rm limits/<id>.frozen in those paths.
  echo "task" > "$BUS/claimed/kf1.claude:opus"
  ( exec -a swarm-ctl-kill-test-marker sleep 9999 ) 3>&- &
  wpid=$!
  echo "$wpid" > "$BUS/pids/kf1"
  for _ in $(seq 1 20); do kill -0 "$wpid" 2>/dev/null && break; sleep 0.1; done
  kill -STOP "$wpid"
  for _ in $(seq 1 20); do [[ "$(ps -o state= -p "$wpid" 2>/dev/null)" == T* ]] && break; sleep 0.1; done
  touch "$BUS/limits/kf1.frozen"

  BUSDIR="$BUS" run "$CTL" kill kf1
  [ "$status" -eq 0 ]
  [ -f "$BUS/queue/kf1.prompt" ]
  [ ! -f "$BUS/claimed/kf1.claude:opus" ]
  [ ! -f "$BUS/limits/kf1.frozen" ]
  for _ in $(seq 1 20); do kill -0 "$wpid" 2>/dev/null || break; sleep 0.1; done
  run kill -0 "$wpid"
  [ "$status" -ne 0 ]
}

@test "pause-worker: without a pids/<id> pidfile fails loudly (rc1)" {
  # §4.6b cmd_pause_worker: pidfile required — nothing to SIGSTOP otherwise.
  echo "task" > "$BUS/claimed/pw1.claude:opus"
  BUSDIR="$BUS" run "$CTL" pause-worker pw1
  [ "$status" -ne 0 ]
  [[ "$output" != *"usage: swarm-ctl"* ]]
}

# --- audit fix: cancel on a CLAIMED id must terminate the worker, not just thaw-and-error --------
# MAJOR live finding: cmd_cancel used to CONT a frozen worker (via _cont_if_frozen) and then, since
# claimed/ ids never live in specs/ or queue/, fall through to the "no spec" error — leaving the
# now-thawed worker RUNNING. Fix: a claimed id with pids/<id> is cancelled like `kill --cancel`.

@test "cancel: on a claimed FROZEN worker, terminates it and lands cancelled/<id>.prompt" {
  echo "task" > "$BUS/claimed/cf1.claude:opus"
  ( exec -a swarm-ctl-kill-test-marker sleep 9999 ) 3>&- &
  wpid=$!
  echo "$wpid" > "$BUS/pids/cf1"
  for _ in $(seq 1 20); do kill -0 "$wpid" 2>/dev/null && break; sleep 0.1; done
  kill -STOP "$wpid"
  for _ in $(seq 1 20); do [[ "$(ps -o state= -p "$wpid" 2>/dev/null)" == T* ]] && break; sleep 0.1; done
  touch "$BUS/limits/cf1.frozen"

  BUSDIR="$BUS" run "$CTL" cancel cf1

  [ "$status" -eq 0 ]
  [ -f "$BUS/cancelled/cf1.prompt" ]
  [ ! -f "$BUS/claimed/cf1.claude:opus" ]
  [ ! -f "$BUS/pids/cf1" ]
  [ ! -f "$BUS/limits/cf1.frozen" ]
  for _ in $(seq 1 20); do kill -0 "$wpid" 2>/dev/null || break; sleep 0.1; done
  run kill -0 "$wpid"
  [ "$status" -ne 0 ]
}

@test "add: --lane <lane:model> lands queue/<id>.lane; --write <dir> lands queue/<id>.write" {
  # §5.3b·7: `add <promptfile> [--lane lane:model] [--write <dir>]` writes the sidecars alongside.
  echo "do the work" > "$BATS_TEST_TMPDIR/add13.prompt"
  mkdir -p "$BATS_TEST_TMPDIR/writedir13"
  BUSDIR="$BUS" run "$CTL" add "$BATS_TEST_TMPDIR/add13.prompt" \
    --lane grok:grok-4.5 --write "$BATS_TEST_TMPDIR/writedir13"
  [ "$status" -eq 0 ]
  [ -f "$BUS/queue/add13.prompt" ]
  [ -f "$BUS/queue/add13.lane" ]
  [ "$(<"$BUS/queue/add13.lane")" = "grok:grok-4.5" ]
  [ -f "$BUS/queue/add13.write" ]
  [ "$(<"$BUS/queue/add13.write")" = "$BATS_TEST_TMPDIR/writedir13" ]
}

# --- audit fix: cmd_add's cp+mv is not an atomic publish (bus-discipline.md) ---------------------
# A pre-existing same-id prompt in specs/ or queue/ (concurrent writer, or a stale leftover) must
# never be silently clobbered by a later `add` — the fix swaps cp+mv for a hidden-temp + same-
# directory `ln` (EEXIST-race-safe) ahead of the existing mv-to-queue step.

@test "add: pre-existing specs/<id>.prompt makes add fail loudly and not clobber it" {
  echo "ORIGINAL SPECS CONTENT" > "$BUS/specs/dup1.prompt"
  echo "new content" > "$BATS_TEST_TMPDIR/dup1.prompt"
  BUSDIR="$BUS" run "$CTL" add "$BATS_TEST_TMPDIR/dup1.prompt"
  [ "$status" -ne 0 ]
  [ "$(<"$BUS/specs/dup1.prompt")" = "ORIGINAL SPECS CONTENT" ]
  [ ! -f "$BUS/queue/dup1.prompt" ]
}

@test "add: pre-existing queue/<id>.prompt makes add fail loudly and not clobber it" {
  echo "ORIGINAL QUEUE CONTENT" > "$BUS/queue/dup2.prompt"
  echo "new content" > "$BATS_TEST_TMPDIR/dup2.prompt"
  BUSDIR="$BUS" run "$CTL" add "$BATS_TEST_TMPDIR/dup2.prompt"
  [ "$status" -ne 0 ]
  [ "$(<"$BUS/queue/dup2.prompt")" = "ORIGINAL QUEUE CONTENT" ]
  [ ! -f "$BUS/specs/dup2.prompt" ]
}

@test "add: --lane sidecar is written before the prompt is published (wave-7 finding 4 ordering)" {
  echo "do the work" > "$BATS_TEST_TMPDIR/add14.prompt"
  BUSDIR="$BUS" run "$CTL" add "$BATS_TEST_TMPDIR/add14.prompt" --lane codex:default
  [ "$status" -eq 0 ]
  [ -f "$BUS/queue/add14.prompt" ]
  [ -f "$BUS/queue/add14.lane" ]
  # order proxy: the sidecar's mtime is never newer than the prompt's (it was written first)
  lane_mtime="$(stat -c %Y "$BUS/queue/add14.lane")"
  prompt_mtime="$(stat -c %Y "$BUS/queue/add14.prompt")"
  [ "$lane_mtime" -le "$prompt_mtime" ]
}

# --- spec 14 FR-2/FR-3/FR-5: write-cage attribution wave (swarm-ctl publish-time half) ------------
# FR-2: `add --files <listfile>` writes queue/<id>.files, sidecars-before-prompt, refusing an
# absolute or write-target-escaping entry; nudge keeps it, cancel/kill --cancel drop it (mirrors
# .write exactly). FR-3: `add` on a previously parked id clears .parked/.chain-<id>/.retries-<id>
# via the same _reset_card_state nudge already uses. FR-5: `add --write <nonexistent>` hard-refuses,
# never mkdir's the target.

@test "add: --files <listfile> lands queue/<id>.files verbatim, written before the prompt (mtime ordering)" {
  mkdir -p "$BATS_TEST_TMPDIR/wtargetF1"
  printf 'a.ts\nsub/b.ts\n' > "$BATS_TEST_TMPDIR/f1.files"
  echo "do the work" > "$BATS_TEST_TMPDIR/addF1.prompt"
  BUSDIR="$BUS" run "$CTL" add "$BATS_TEST_TMPDIR/addF1.prompt" \
    --write "$BATS_TEST_TMPDIR/wtargetF1" --files "$BATS_TEST_TMPDIR/f1.files"
  [ "$status" -eq 0 ]
  [ -f "$BUS/queue/addF1.prompt" ]
  [ -f "$BUS/queue/addF1.files" ]
  [[ "$(<"$BUS/queue/addF1.files")" == *"a.ts"* ]]
  [[ "$(<"$BUS/queue/addF1.files")" == *"sub/b.ts"* ]]
  files_mtime="$(stat -c %Y "$BUS/queue/addF1.files")"
  prompt_mtime="$(stat -c %Y "$BUS/queue/addF1.prompt")"
  [ "$files_mtime" -le "$prompt_mtime" ]
}

@test "add: --files without --write is refused loud, nothing written" {
  printf 'a.ts\n' > "$BATS_TEST_TMPDIR/f2.files"
  echo "do the work" > "$BATS_TEST_TMPDIR/addF2.prompt"
  BUSDIR="$BUS" run "$CTL" add "$BATS_TEST_TMPDIR/addF2.prompt" --files "$BATS_TEST_TMPDIR/f2.files"
  [ "$status" -ne 0 ]
  [ ! -e "$BUS/queue/addF2.prompt" ]
  [ ! -e "$BUS/specs/addF2.prompt" ]
}

@test "add: --files refuses an absolute entry (/etc/passwd) — nonzero, nothing written" {
  mkdir -p "$BATS_TEST_TMPDIR/wtargetF3"
  printf '/etc/passwd\n' > "$BATS_TEST_TMPDIR/f3.files"
  echo "do the work" > "$BATS_TEST_TMPDIR/addF3.prompt"
  BUSDIR="$BUS" run "$CTL" add "$BATS_TEST_TMPDIR/addF3.prompt" \
    --write "$BATS_TEST_TMPDIR/wtargetF3" --files "$BATS_TEST_TMPDIR/f3.files"
  [ "$status" -ne 0 ]
  [ ! -e "$BUS/queue/addF3.prompt" ]
  [ ! -e "$BUS/queue/addF3.files" ]
  [ ! -e "$BUS/specs/addF3.prompt" ]
}

@test "add: --files refuses an entry that escapes the write target (../escape.ts) — nonzero, nothing written" {
  mkdir -p "$BATS_TEST_TMPDIR/wtargetF4"
  printf '../escape.ts\n' > "$BATS_TEST_TMPDIR/f4.files"
  echo "do the work" > "$BATS_TEST_TMPDIR/addF4.prompt"
  BUSDIR="$BUS" run "$CTL" add "$BATS_TEST_TMPDIR/addF4.prompt" \
    --write "$BATS_TEST_TMPDIR/wtargetF4" --files "$BATS_TEST_TMPDIR/f4.files"
  [ "$status" -ne 0 ]
  [ ! -e "$BUS/queue/addF4.prompt" ]
  [ ! -e "$BUS/queue/addF4.files" ]
}

@test "nudge: keeps the .files sidecar (requeue semantics, same as .lane/.write)" {
  echo "task" > "$BUS/claimed/nf1.claude:opus"
  printf 'a.ts\n' > "$BUS/queue/nf1.files"

  BUSDIR="$BUS" run "$CTL" nudge nf1
  [ "$status" -eq 0 ]
  [ -f "$BUS/queue/nf1.prompt" ]
  [ -f "$BUS/queue/nf1.files" ]
}

@test "cancel: also removes the .files sidecar (no orphan for a same-id add)" {
  echo "x" > "$BUS/queue/cf2.prompt"
  printf 'a.ts\n' > "$BUS/queue/cf2.files"
  BUSDIR="$BUS" run "$CTL" cancel cf2
  [ "$status" -eq 0 ]
  [ -f "$BUS/cancelled/cf2.prompt" ]
  [ ! -e "$BUS/queue/cf2.files" ]
}

@test "kill --cancel: also clears the .files sidecar" {
  echo "task" > "$BUS/claimed/kfc1.gemini:gemini-3-flash"
  printf 'a.ts\n' > "$BUS/queue/kfc1.files"
  ( exec -a swarm-ctl-kill-test-marker sleep 9999 ) 3>&- &
  echo "$!" > "$BUS/pids/kfc1"

  BUSDIR="$BUS" run "$CTL" kill kfc1 --cancel
  [ "$status" -eq 0 ]
  [ -f "$BUS/cancelled/kfc1.prompt" ]
  [ ! -e "$BUS/queue/kfc1.files" ]
}

@test "add: on a previously parked id, clears .parked / .chain-<id> / .retries-<id> (FR-3)" {
  echo "do the work" > "$BATS_TEST_TMPDIR/reparkA.prompt"
  touch "$BUS/limits/reparkA.parked"
  printf 'glm:glm-5.2' > "$BUS/limits/.chain-reparkA"
  printf '2' > "$BUS/limits/.retries-reparkA"

  BUSDIR="$BUS" run "$CTL" add "$BATS_TEST_TMPDIR/reparkA.prompt"
  [ "$status" -eq 0 ]
  [ -f "$BUS/queue/reparkA.prompt" ]
  [ ! -e "$BUS/limits/reparkA.parked" ]
  [ ! -e "$BUS/limits/.chain-reparkA" ]
  [ ! -e "$BUS/limits/.retries-reparkA" ]
}

@test "add: --write refuses a nonexistent directory — rc 1, loud, no queue/<id>.write, no queue/<id>.prompt, never mkdir's it" {
  missing="$BATS_TEST_TMPDIR/does-not-exist-wtarget"
  echo "do the work" > "$BATS_TEST_TMPDIR/addW1.prompt"
  BUSDIR="$BUS" run "$CTL" add "$BATS_TEST_TMPDIR/addW1.prompt" --write "$missing"
  [ "$status" -ne 0 ]
  [ ! -e "$BUS/queue/addW1.prompt" ]
  [ ! -e "$BUS/queue/addW1.write" ]
  [ ! -e "$missing" ]
}

# --- cross-review fix round: _reset_card_state widened + cancel calls it (spec 14 MAJOR finding) --
# Codex + structural-seat review found: (a) _reset_card_state's wipe list was missing .waiting,
# .waiting-write (FR-5's bounded-wait marker), and .cage-denied (FR-1) — a stale one of these
# insta-parks or mis-classifies a re-published id. (b) cmd_cancel never called it at all — a
# cancelled parked card left a phantom .parked behind, inflating parked_n against a shrunk live_n
# and risking an early gate close.

@test "add: on a previously parked id, also clears .waiting / .waiting-write / .cage-denied (widened FR-3 reset)" {
  echo "do the work" > "$BATS_TEST_TMPDIR/reparkB.prompt"
  touch "$BUS/limits/reparkB.parked"
  touch "$BUS/limits/reparkB.waiting"
  # aged mtime — matches the reported repro shape (10-min-old marker); the fix must remove the
  # file outright, not merely leave a stale mtime for the claim-time bounded wait to misread.
  touch -d "-10 minutes" "$BUS/limits/reparkB.waiting-write"
  printf 'denials=3\n/some/path\n' > "$BUS/limits/reparkB.cage-denied"

  BUSDIR="$BUS" run "$CTL" add "$BATS_TEST_TMPDIR/reparkB.prompt"
  [ "$status" -eq 0 ]
  [ -f "$BUS/queue/reparkB.prompt" ]
  [ ! -e "$BUS/limits/reparkB.parked" ]
  [ ! -e "$BUS/limits/reparkB.waiting" ]
  [ ! -e "$BUS/limits/reparkB.waiting-write" ]
  [ ! -e "$BUS/limits/reparkB.cage-denied" ]
}

@test "cancel: a parked queued id has .parked/.waiting/.waiting-write/.cage-denied all cleared (no phantom parked_n)" {
  echo "task" > "$BUS/queue/pk1.prompt"
  touch "$BUS/limits/pk1.parked"
  touch "$BUS/limits/pk1.waiting"
  touch "$BUS/limits/pk1.waiting-write"
  printf 'denials=1\n' > "$BUS/limits/pk1.cage-denied"

  BUSDIR="$BUS" run "$CTL" cancel pk1
  [ "$status" -eq 0 ]
  [ -f "$BUS/cancelled/pk1.prompt" ]
  [ ! -e "$BUS/limits/pk1.parked" ]
  [ ! -e "$BUS/limits/pk1.waiting" ]
  [ ! -e "$BUS/limits/pk1.waiting-write" ]
  [ ! -e "$BUS/limits/pk1.cage-denied" ]
}

@test "cancel: on a claimed (in-flight) id, also clears stale .waiting/.cage-denied (both cancel exit paths call _reset_card_state)" {
  echo "task" > "$BUS/claimed/pk3.claude:opus"
  touch "$BUS/limits/pk3.waiting"
  printf 'denials=1\n' > "$BUS/limits/pk3.cage-denied"

  BUSDIR="$BUS" run "$CTL" cancel pk3
  [ "$status" -eq 0 ]
  [ -f "$BUS/cancelled/pk3.prompt" ]
  [ ! -e "$BUS/limits/pk3.waiting" ]
  [ ! -e "$BUS/limits/pk3.cage-denied" ]
}

# --- cross-review fix round: empty/directory manifest entries (MINOR findings) --------------------

@test "add: --files refuses an empty manifest (zero usable entries) — nonzero, nothing written" {
  mkdir -p "$BATS_TEST_TMPDIR/wtargetE1"
  : > "$BATS_TEST_TMPDIR/e1.files"
  echo "do the work" > "$BATS_TEST_TMPDIR/addE1.prompt"
  BUSDIR="$BUS" run "$CTL" add "$BATS_TEST_TMPDIR/addE1.prompt" \
    --write "$BATS_TEST_TMPDIR/wtargetE1" --files "$BATS_TEST_TMPDIR/e1.files"
  [ "$status" -ne 0 ]
  [ ! -e "$BUS/queue/addE1.prompt" ]
  [ ! -e "$BUS/queue/addE1.files" ]
}

@test "add: --files refuses a manifest of only blank lines (zero usable entries after skipping blanks)" {
  mkdir -p "$BATS_TEST_TMPDIR/wtargetE2"
  printf '\n\n' > "$BATS_TEST_TMPDIR/e2.files"
  echo "do the work" > "$BATS_TEST_TMPDIR/addE2.prompt"
  BUSDIR="$BUS" run "$CTL" add "$BATS_TEST_TMPDIR/addE2.prompt" \
    --write "$BATS_TEST_TMPDIR/wtargetE2" --files "$BATS_TEST_TMPDIR/e2.files"
  [ "$status" -ne 0 ]
  [ ! -e "$BUS/queue/addE2.prompt" ]
}

@test "add: --files refuses an entry resolving to an existing directory (manifest entries must be files)" {
  mkdir -p "$BATS_TEST_TMPDIR/wtargetD1/subdir"
  printf 'subdir\n' > "$BATS_TEST_TMPDIR/d1.files"
  echo "do the work" > "$BATS_TEST_TMPDIR/addD1.prompt"
  BUSDIR="$BUS" run "$CTL" add "$BATS_TEST_TMPDIR/addD1.prompt" \
    --write "$BATS_TEST_TMPDIR/wtargetD1" --files "$BATS_TEST_TMPDIR/d1.files"
  [ "$status" -ne 0 ]
  [ ! -e "$BUS/queue/addD1.prompt" ]
}

@test "add: --files accepts an entry naming a not-yet-existing file under the write target (a card may create its own deliverable)" {
  mkdir -p "$BATS_TEST_TMPDIR/wtargetD2"
  printf 'not-yet-created.ts\n' > "$BATS_TEST_TMPDIR/d2.files"
  echo "do the work" > "$BATS_TEST_TMPDIR/addD2.prompt"
  BUSDIR="$BUS" run "$CTL" add "$BATS_TEST_TMPDIR/addD2.prompt" \
    --write "$BATS_TEST_TMPDIR/wtargetD2" --files "$BATS_TEST_TMPDIR/d2.files"
  [ "$status" -eq 0 ]
  [ -f "$BUS/queue/addD2.prompt" ]
  [ -f "$BUS/queue/addD2.files" ]
}

# --- wave-7 finding 1: exact claim resolution (bare glob prefix-matches dotted ids) ---------------
# claimed/<id>.<lane:model> filenames make a bare `claimed/"$id".*` glob ambiguous: id "a" also
# matches a DIFFERENT id "a.b"'s claim file "a.b.<lane:model>". Every verb below must resolve via
# the same exact-match logic reap() uses (_claim_of, src/swarm-lib.sh) and touch ONLY its own id's
# claim, leaving a sibling dotted id's claim completely untouched.

@test "cancel: exact id resolution — dotted sibling id a.b's claim is untouched by cancel a" {
  echo "task a" > "$BUS/claimed/a.claude:opus"
  echo "task a.b" > "$BUS/claimed/a.b.claude:opus"
  BUSDIR="$BUS" run "$CTL" cancel a
  [ "$status" -eq 0 ]
  [ -f "$BUS/cancelled/a.prompt" ]
  [ ! -f "$BUS/claimed/a.claude:opus" ]
  [ -f "$BUS/claimed/a.b.claude:opus" ]
  [ ! -e "$BUS/cancelled/a.b.prompt" ]
}

@test "kill: exact id resolution — dotted sibling id a.b's claim is untouched by kill a" {
  echo "task a" > "$BUS/claimed/a.claude:opus"
  echo "task a.b" > "$BUS/claimed/a.b.claude:opus"
  ( exec -a swarm-ctl-kill-test-marker sleep 9999 ) 3>&- &
  wpid=$!
  echo "$wpid" > "$BUS/pids/a"
  for _ in $(seq 1 20); do kill -0 "$wpid" 2>/dev/null && break; sleep 0.1; done

  BUSDIR="$BUS" run "$CTL" kill a
  [ "$status" -eq 0 ]
  [ -f "$BUS/queue/a.prompt" ]
  [ ! -f "$BUS/claimed/a.claude:opus" ]
  [ -f "$BUS/claimed/a.b.claude:opus" ]
  [ ! -e "$BUS/queue/a.b.prompt" ]
}

@test "nudge: exact id resolution — dotted sibling id a.b's claim is untouched by nudge a" {
  echo "task a" > "$BUS/claimed/a.claude:opus"
  echo "task a.b" > "$BUS/claimed/a.b.claude:opus"
  BUSDIR="$BUS" run "$CTL" nudge a
  [ "$status" -eq 0 ]
  [ -f "$BUS/queue/a.prompt" ]
  [ ! -f "$BUS/claimed/a.claude:opus" ]
  [ -f "$BUS/claimed/a.b.claude:opus" ]
  [ ! -e "$BUS/queue/a.b.prompt" ]
}

@test "pause-worker: exact id resolution — dotted sibling id a.b's claim is untouched by pause-worker a" {
  echo "task a" > "$BUS/claimed/a.claude:opus"
  echo "task a.b" > "$BUS/claimed/a.b.claude:opus"
  ( exec -a swarm-ctl-kill-test-marker sleep 9999 ) 3>&- &
  wpid=$!
  echo "$wpid" > "$BUS/pids/a"
  for _ in $(seq 1 20); do kill -0 "$wpid" 2>/dev/null && break; sleep 0.1; done
  touch -d "-5 minutes" "$BUS/claimed/a.b.claude:opus"
  old_b="$(stat -c %Y "$BUS/claimed/a.b.claude:opus")"

  BUSDIR="$BUS" run "$CTL" pause-worker a
  [ "$status" -eq 0 ]
  [ -f "$BUS/limits/a.frozen" ]
  [ ! -e "$BUS/limits/a.b.frozen" ]
  new_b="$(stat -c %Y "$BUS/claimed/a.b.claude:opus")"
  [ "$new_b" -eq "$old_b" ]

  kill -CONT "$wpid" 2>/dev/null || true
  kill -9 "$wpid" 2>/dev/null || true
}

# --- wave-7 finding 2: freeze/reap ordering (frozen flag survives until the claim is disposed) ----

@test "cancel: on a claimed frozen worker, the frozen flag is never observed cleared while the claim still sits in claimed/ (ordering)" {
  echo "task" > "$BUS/claimed/cford1.claude:opus"
  ( exec -a swarm-ctl-kill-test-marker sleep 9999 ) 3>&- &
  wpid=$!
  echo "$wpid" > "$BUS/pids/cford1"
  for _ in $(seq 1 20); do kill -0 "$wpid" 2>/dev/null && break; sleep 0.1; done
  kill -STOP "$wpid"
  for _ in $(seq 1 20); do [[ "$(ps -o state= -p "$wpid" 2>/dev/null)" == T* ]] && break; sleep 0.1; done
  touch "$BUS/limits/cford1.frozen"

  BUSDIR="$BUS" "$CTL" cancel cford1 &
  ctlpid=$!
  bad_window=0
  for _ in $(seq 1 5000); do
    kill -0 "$ctlpid" 2>/dev/null || break
    if [[ ! -f "$BUS/limits/cford1.frozen" && -e "$BUS/claimed/cford1.claude:opus" ]]; then
      bad_window=1
      break
    fi
  done
  wait "$ctlpid"
  ctlstatus=$?

  [ "$ctlstatus" -eq 0 ]
  [ "$bad_window" -eq 0 ]
  [ -f "$BUS/cancelled/cford1.prompt" ]
  [ ! -f "$BUS/claimed/cford1.claude:opus" ]
  [ ! -f "$BUS/limits/cford1.frozen" ]
}

# --- spec 11 succession (round3 red wave) ---
# FR-S1/FR-S2 verbs (heartbeat, watchdog-arm/check/disarm) are not in src/swarm-ctl yet —
# unknown verbs fall through to usage (rc 1). Every assertion below is the post-implementation
# contract so the GREEN wave flips these. crontab/claude are PATH-shimmed; never the real ones.

# Install executable PATH shims: crontab (reads/writes $FAKE_CRONTAB_FILE) and claude (appends
# argv to $FAKE_CLAUDE_CALLS). Paths are baked into the shims so env -i spawns still record.
_spec11_install_fakes() {
  local bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  export PATH="$bin:$PATH"
  export FAKE_CRONTAB_FILE="$BATS_TEST_TMPDIR/fake.crontab"
  export FAKE_CLAUDE_CALLS="$BATS_TEST_TMPDIR/fake.claude.calls"
  rm -f "$FAKE_CRONTAB_FILE" "$FAKE_CLAUDE_CALLS"
  : > "$FAKE_CLAUDE_CALLS"
  # never the operator's real secrets file (_env_master_key contract) — same pattern as
  # swarm-run.bats' lane-key tests
  printf 'MOONSHOT_API_KEY=test-kimi-key\n' > "$BATS_TEST_TMPDIR/envmaster"
  export ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster"
  # never the operator's real gitignored ./swarm.conf — empty conf = baked defaults, and the
  # tests' env exports (ORCH_CHAIN/ORCH_TAKEOVER_MIN) still outrank it
  export CONF="$BATS_TEST_TMPDIR/swarm.conf"
  : > "$CONF"

  cat > "$bin/crontab" <<EOF
#!/usr/bin/env bash
set -euo pipefail
_file="$FAKE_CRONTAB_FILE"
case "\${1:-}" in
  -l)
    if [[ ! -s "\$_file" ]]; then
      exit 1
    fi
    cat "\$_file"
    exit 0
    ;;
  -)
    cat > "\$_file"
    exit 0
    ;;
  *)
    echo "fake crontab: unsupported usage: \$*" >&2
    exit 2
    ;;
esac
EOF
  chmod +x "$bin/crontab"

  cat > "$bin/claude" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >> "$FAKE_CLAUDE_CALLS"
exit 0
EOF
  chmod +x "$bin/claude"
}

@test "spec11: heartbeat touches heartbeat + seeds orch-seat fable; preserves non-fable seat" {
  # FR-S2: heartbeat <busdir> touches .bus/heartbeat; writes orch-seat "fable <epoch>" only when
  # missing — never overwrites an existing non-fable seat.
  run "$CTL" heartbeat "$BUS"
  [ "$status" -eq 0 ]
  [ -f "$BUS/heartbeat" ]
  [ -f "$BUS/orch-seat" ]
  read -r seat _epoch < "$BUS/orch-seat"
  [ "$seat" = "fable" ]

  printf 'kimi 1\n' > "$BUS/orch-seat"
  run "$CTL" heartbeat "$BUS"
  [ "$status" -eq 0 ]
  [ -f "$BUS/heartbeat" ]
  read -r seat2 _epoch2 < "$BUS/orch-seat"
  [ "$seat2" = "kimi" ]
  [[ "$(<"$BUS/orch-seat")" == kimi* ]]
}

@test "spec11: watchdog-arm is idempotent — one tagged crontab line; unrelated survives" {
  # FR-S2: arm installs exactly one line tagged "# unimatrix-watchdog <busdir>" that invokes
  # watchdog-check; re-arm is a no-op; pre-existing unrelated lines are preserved.
  _spec11_install_fakes
  printf '%s\n' '0 3 * * * /usr/bin/true # nightly-unrelated' > "$FAKE_CRONTAB_FILE"

  run "$CTL" watchdog-arm "$BUS"
  [ "$status" -eq 0 ]
  run "$CTL" watchdog-arm "$BUS"
  [ "$status" -eq 0 ]

  local tag="# unimatrix-watchdog $BUS"
  local tagged_n tagged_line
  tagged_n="$(grep -cF -- "$tag" "$FAKE_CRONTAB_FILE" || true)"
  [ "$tagged_n" -eq 1 ]
  tagged_line="$(grep -F -- "$tag" "$FAKE_CRONTAB_FILE")"
  [[ "$tagged_line" == *watchdog-check* ]]
  grep -qF '0 3 * * * /usr/bin/true # nightly-unrelated' "$FAKE_CRONTAB_FILE"
}

@test "spec11: watchdog-check silent no-op — fresh heartbeat + non-empty queue" {
  # FR-S2: age ≤ ORCH_TAKEOVER_MIN → rc 0, no stdout/stderr, orch-seat untouched.
  _spec11_install_fakes
  export ORCH_TAKEOVER_MIN=20
  export ORCH_CHAIN="fable kimi"
  touch "$BUS/heartbeat"
  echo "work" > "$BUS/queue/fresh1.prompt"
  printf 'fable 111\n' > "$BUS/orch-seat"
  local before
  before="$(<"$BUS/orch-seat")"

  run "$CTL" watchdog-check "$BUS"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(<"$BUS/orch-seat")" = "$before" ]
  [ ! -s "$FAKE_CLAUDE_CALLS" ]
}

@test "spec11: watchdog-check silent no-op — stale heartbeat but empty queue+claimed (run complete)" {
  # FR-S2: complete run (nothing in queue/ or claimed/) → silent no-op even if heartbeat is stale.
  _spec11_install_fakes
  export ORCH_TAKEOVER_MIN=20
  export ORCH_CHAIN="fable kimi"
  touch -d "-30 minutes" "$BUS/heartbeat"
  printf 'fable 222\n' > "$BUS/orch-seat"
  local before
  before="$(<"$BUS/orch-seat")"
  # queue/ and claimed/ already empty from bus_init

  run "$CTL" watchdog-check "$BUS"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(<"$BUS/orch-seat")" = "$before" ]
  [ ! -s "$FAKE_CLAUDE_CALLS" ]
}

@test "spec11: watchdog-check silent no-op — orch-seat already non-fable (takeover at most once)" {
  # FR-S2: orch-seat already a non-fable lane → no second takeover even with stale heartbeat + work.
  _spec11_install_fakes
  export ORCH_TAKEOVER_MIN=20
  export ORCH_CHAIN="fable kimi"
  touch -d "-30 minutes" "$BUS/heartbeat"
  echo "still running" > "$BUS/queue/once1.prompt"
  printf 'kimi 333\n' > "$BUS/orch-seat"
  local before
  before="$(<"$BUS/orch-seat")"

  run "$CTL" watchdog-check "$BUS"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(<"$BUS/orch-seat")" = "$before" ]
  [ ! -s "$FAKE_CLAUDE_CALLS" ]
}

@test "spec11: takeover fires — stale heartbeat + queued card seats kimi and spawns driver" {
  # FR-S1/FR-S2: stale apex + incomplete run walks ORCH_CHAIN, rewrites orch-seat, spawns the
  # continuation driver once, writes loop/handoff-prompt.md with the bounded-mandate phrases.
  _spec11_install_fakes
  export ORCH_TAKEOVER_MIN=20
  export ORCH_CHAIN="fable kimi"
  touch -d "-30 minutes" "$BUS/heartbeat"
  printf 'fable 1\n' > "$BUS/orch-seat"
  echo "in-flight work" > "$BUS/queue/card42.prompt"

  run "$CTL" watchdog-check "$BUS"
  [ "$status" -eq 0 ]
  read -r seat _epoch < "$BUS/orch-seat"
  [ "$seat" = "kimi" ]
  # the driver is backgrounded (reparented) — spin until the claude shim has appended
  for _ in $(seq 1 20); do [ -s "$FAKE_CLAUDE_CALLS" ] && break; sleep 0.1; done
  local calls
  calls="$(wc -l < "$FAKE_CLAUDE_CALLS" | tr -d ' ')"
  [ "$calls" -eq 1 ]
  [ -f "$BUS/loop/handoff-prompt.md" ]
  local handoff
  handoff="$(<"$BUS/loop/handoff-prompt.md")"
  [[ "$handoff" == *"continuation driver"* ]]
  [[ "$handoff" == *"No new scope."* ]]
  [[ "$handoff" == *"No spec lifecycle changes."* ]]
  [[ "$handoff" == *"No pushes."* ]]
  [[ "$handoff" == *"No destructive ops."* ]]
  [[ "$handoff" == *"card42"* ]]
}

@test "spec14 FR-7: a parked id's reason-line marker renders verbatim in the ctl-state (watchdog bus-state) output" {
  # AC-9: swarm-ctl's non-empty .parked rendering (_watchdog_bus_state, exercised here via
  # watchdog-check's handoff prompt) already prints whatever content sits in limits/<id>.parked —
  # no code change needed, just proof a spec-14-format reason line survives that render intact.
  _spec11_install_fakes
  export ORCH_TAKEOVER_MIN=20
  export ORCH_CHAIN="fable kimi"
  touch -d "-30 minutes" "$BUS/heartbeat"
  printf 'fable 1\n' > "$BUS/orch-seat"
  echo "in-flight work" > "$BUS/queue/card77.prompt"
  local reason_line='2026-07-25T10:00:00Z | write-target-missing | retryable=0 | ttl=0 | write target missing for card77'
  printf '%s' "$reason_line" > "$BUS/limits/card77.parked"

  run "$CTL" watchdog-check "$BUS"
  [ "$status" -eq 0 ]
  [ -f "$BUS/loop/handoff-prompt.md" ]
  grep -qF "card77.parked: $reason_line" "$BUS/loop/handoff-prompt.md"
}

@test "spec11: flock single-takeover — two concurrent watchdog-check yield one spawn" {
  # FR-S2: flock on limits/takeover.lock + re-check under lock → concurrent ticks spawn once.
  _spec11_install_fakes
  export ORCH_TAKEOVER_MIN=20
  export ORCH_CHAIN="fable kimi"
  touch -d "-30 minutes" "$BUS/heartbeat"
  printf 'fable 1\n' > "$BUS/orch-seat"
  echo "in-flight work" > "$BUS/queue/race1.prompt"

  "$CTL" watchdog-check "$BUS" &
  local p1=$!
  "$CTL" watchdog-check "$BUS" &
  local p2=$!
  wait "$p1" || true
  wait "$p2" || true

  # wait covers only the two watchdog-check pids, not the reparented claude shim — spin
  for _ in $(seq 1 20); do [ -s "$FAKE_CLAUDE_CALLS" ] && break; sleep 0.1; done
  local calls
  calls="$(wc -l < "$FAKE_CLAUDE_CALLS" | tr -d ' ')"
  [ "$calls" -eq 1 ]
}

@test "spec11: chain exhausted parks — kimi.limited → no spawn, takeover.parked, loud stderr" {
  # FR-S1/FR-S2: ORCH_CHAIN walked past fable with remaining lane limited → park, no driver.
  _spec11_install_fakes
  export ORCH_TAKEOVER_MIN=20
  export ORCH_CHAIN="fable kimi"
  touch -d "-30 minutes" "$BUS/heartbeat"
  printf 'fable 1\n' > "$BUS/orch-seat"
  echo "in-flight work" > "$BUS/queue/park1.prompt"
  touch "$BUS/limits/kimi.limited"

  run "$CTL" watchdog-check "$BUS"
  [ "$status" -eq 0 ]
  [ ! -s "$FAKE_CLAUDE_CALLS" ]
  [ -f "$BUS/limits/takeover.parked" ]
  [[ "$output" == *"ORCH_CHAIN exhausted"* ]]
}

@test "spec11: watchdog-disarm removes tagged line only; idempotent when absent" {
  # FR-S2: disarm drops only "# unimatrix-watchdog <busdir>"; unrelated survives; absent = rc 0.
  _spec11_install_fakes
  local tag="# unimatrix-watchdog $BUS"
  {
    printf '%s\n' '15 4 * * * /usr/bin/true # other-job'
    printf '%s\n' "*/5 * * * * $CTL watchdog-check $BUS $tag"
  } > "$FAKE_CRONTAB_FILE"

  run "$CTL" watchdog-disarm "$BUS"
  [ "$status" -eq 0 ]
  [ -f "$FAKE_CRONTAB_FILE" ]
  # run+status idiom: a bare mid-test `! grep` is exempt from bats' errexit and can never fail
  run grep -qF -- "$tag" "$FAKE_CRONTAB_FILE"
  [ "$status" -ne 0 ]
  grep -qF '15 4 * * * /usr/bin/true # other-job' "$FAKE_CRONTAB_FILE"

  # idempotent: no tagged line left → still rc 0; unrelated still present
  run "$CTL" watchdog-disarm "$BUS"
  [ "$status" -eq 0 ]
  run grep -qF -- "$tag" "$FAKE_CRONTAB_FILE"
  [ "$status" -ne 0 ]
  grep -qF '15 4 * * * /usr/bin/true # other-job' "$FAKE_CRONTAB_FILE"
}


@test "spec11: budget-gated succession — over-budget kimi is skipped, chain parks, no spawn" {
  # FR-S2 "skipping limited/dead/budget-gated": a kimi whose limits/kimi.spend already exceeds
  # BUDGET_USD must never be seated as continuation driver — it bills real Moonshot dollars.
  _spec11_install_fakes
  export ORCH_TAKEOVER_MIN=20
  export ORCH_CHAIN="fable kimi"
  export BUDGET_USD=0.01
  touch -d "-30 minutes" "$BUS/heartbeat"
  printf 'fable 1\n' > "$BUS/orch-seat"
  echo "in-flight work" > "$BUS/queue/budget1.prompt"
  printf '0.02' > "$BUS/limits/kimi.spend"

  run "$CTL" watchdog-check "$BUS"
  [ "$status" -eq 0 ]
  [ ! -s "$FAKE_CLAUDE_CALLS" ]
  [ -f "$BUS/limits/takeover.parked" ]
  [[ "$output" == *"ORCH_CHAIN exhausted"* ]]
  read -r seat _epoch < "$BUS/orch-seat"
  [ "$seat" = "fable" ]
}

# --- spec 11 cron contract: the closeout only smoke-verified these; lock them in ------------------

@test "spec11 cron contract: the installed crontab line takes over from a bare cron env (env -i)" {
  # The real trigger is cron: no exported env, minimal PATH, cwd=$HOME. Everything the check needs
  # must ride the installed line itself (baked PATH) + <busdir>/watchdog.env (resolved config).
  _spec11_install_fakes
  export ORCH_TAKEOVER_MIN=20
  export ORCH_CHAIN="fable kimi"

  run "$CTL" watchdog-arm "$BUS"
  [ "$status" -eq 0 ]
  [ -f "$BUS/watchdog.env" ]

  local line cmd
  line="$(grep -F "# unimatrix-watchdog $BUS" "$FAKE_CRONTAB_FILE")"
  cmd="${line#"*/5 * * * * "}"

  touch -d "-30 minutes" "$BUS/heartbeat"
  printf 'fable 1\n' > "$BUS/orch-seat"
  echo "in-flight work" > "$BUS/queue/cron1.prompt"

  run env -i PATH=/usr/bin:/bin HOME="$BATS_TEST_TMPDIR" sh -c "$cmd"
  [ "$status" -eq 0 ]
  read -r seat _epoch < "$BUS/orch-seat"
  [ "$seat" = "kimi" ]
  [ ! -f "$BUS/limits/takeover.parked" ]
  for _ in $(seq 1 20); do [ -s "$FAKE_CLAUDE_CALLS" ] && break; sleep 0.1; done
  local calls
  calls="$(wc -l < "$FAKE_CLAUDE_CALLS" | tr -d ' ')"
  [ "$calls" -eq 1 ]
}

@test "spec11 cron contract: watchdog-arm persists the resolved config plane to watchdog.env" {
  _spec11_install_fakes
  export ORCH_TAKEOVER_MIN=7
  export ORCH_CHAIN="fable kimi"
  export BUDGET_USD=2.50

  run "$CTL" watchdog-arm "$BUS"
  [ "$status" -eq 0 ]
  [ -f "$BUS/watchdog.env" ]
  # source it the way watchdog-check does and assert the ARMING run's resolved values landed
  source "$BUS/watchdog.env"
  [ "$ORCH_CHAIN" = "fable kimi" ]
  [ "$ORCH_TAKEOVER_MIN" = "7" ]
  [ "$BUDGET_USD" = "2.50" ]
  [ "$ENV_MASTER_FILE" = "$BATS_TEST_TMPDIR/envmaster" ]
  [ "$CONF" = "$BATS_TEST_TMPDIR/swarm.conf" ]
}

@test "spec11 cron contract: watchdog-arm refuses a busdir a crontab line cannot carry (% / quote)" {
  # cron reads a literal % as newline; quotes break the line's sh -c parse — refuse, never install
  # a line that dead-ticks forever.
  _spec11_install_fakes
  local bad1="$BATS_TEST_TMPDIR/bus%pct" bad2="$BATS_TEST_TMPDIR/bus'quote"
  mkdir -p "$bad1" "$bad2"

  run "$CTL" watchdog-arm "$bad1"
  [ "$status" -eq 1 ]
  [[ "$output" == *"refusing to arm"* ]]
  [ ! -e "$bad1/watchdog.env" ]

  run "$CTL" watchdog-arm "$bad2"
  [ "$status" -eq 1 ]
  [[ "$output" == *"refusing to arm"* ]]
  [ ! -e "$bad2/watchdog.env" ]

  [ ! -s "$FAKE_CRONTAB_FILE" ]
}

@test "spec11: open loop run — empty queue+claimed but open loop/*/criteria.md still fires takeover" {
  # Between pool runs a /swarm-loop bus has an empty queue/ and claimed/ for most of the wall
  # clock — completeness additionally requires no still-open loop run (no COMPLETE.md/HALTED.md).
  _spec11_install_fakes
  export ORCH_TAKEOVER_MIN=20
  export ORCH_CHAIN="fable kimi"
  touch -d "-30 minutes" "$BUS/heartbeat"
  printf 'fable 1\n' > "$BUS/orch-seat"
  mkdir -p "$BUS/loop/run1"
  printf 'goal: keep iterating until green\n' > "$BUS/loop/run1/criteria.md"

  run "$CTL" watchdog-check "$BUS"
  [ "$status" -eq 0 ]
  read -r seat _epoch < "$BUS/orch-seat"
  [ "$seat" = "kimi" ]
  for _ in $(seq 1 20); do [ -s "$FAKE_CLAUDE_CALLS" ] && break; sleep 0.1; done
  local calls
  calls="$(wc -l < "$FAKE_CLAUDE_CALLS" | tr -d ' ')"
  [ "$calls" -eq 1 ]
  [ -f "$BUS/loop/handoff-prompt.md" ]
  [[ "$(<"$BUS/loop/handoff-prompt.md")" == *"keep iterating until green"* ]]
}

@test "spec11 FR-S4: handoff prompt carries ON HANDOFF-BACK block; resume checklist opens with Fable re-audit" {
  # Same fixture as the takeover test above: stale apex + queued card → watchdog-check seats kimi
  # and writes loop/handoff-prompt.md; here we pin the FR-S4 handoff-back contract in that file.
  _spec11_install_fakes
  export ORCH_TAKEOVER_MIN=20
  export ORCH_CHAIN="fable kimi"
  touch -d "-30 minutes" "$BUS/heartbeat"
  printf 'fable 1\n' > "$BUS/orch-seat"
  echo "in-flight work" > "$BUS/queue/card43.prompt"

  run "$CTL" watchdog-check "$BUS"
  [ "$status" -eq 0 ]
  local prompt="$BUS/loop/handoff-prompt.md"
  [ -f "$prompt" ]
  grep -qF "ON HANDOFF-BACK" "$prompt"
  grep -qF "handoff-degraded.md" "$prompt"
  grep -qF "## Resume checklist" "$prompt"
  # FR-S4 acceptance: ordering, not just presence — the "1. Fable re-audit" line must appear
  # BEFORE any "2." checklist line (grep -n line numbers).
  local reaudit_ln next_ln
  reaudit_ln="$(grep -n '^1\. Fable re-audit' "$prompt" | head -1 | cut -d: -f1)"
  next_ln="$(grep -n '^2\.' "$prompt" | head -1 | cut -d: -f1)"
  [ -n "$reaudit_ln" ]
  [ -n "$next_ln" ]
  [ "$reaudit_ln" -lt "$next_ln" ]
}

# --- spec 11 cron-line hardening (live-drill red wave): minimal-PATH line + verified install -------
# Live bug: arm baked the caller's ENTIRE $PATH into the crontab line; a real dev-box PATH blew
# crontab's per-line limit ('"-":1: command too long ... can't install') and the failure was
# swallowed — the run continued with NO armed watchdog. Contract now: the line carries only a short
# fixed PATH; the full resolved runtime plane (PATH, CLAUDE_BIN) rides <busdir>/watchdog.env.

@test "spec11 cron line: huge caller PATH stays off the line — fixed minimal PATH; full PATH + CLAUDE_BIN ride watchdog.env" {
  _spec11_install_fakes
  # ~3500 chars of dummy dirs prepended — the real-drill shape that overflowed crontab's line limit
  local junk="" i
  for i in $(seq 1 100); do junk+="/nonexistent-dummy-path-segment-$i:"; done
  export PATH="$junk$PATH"

  run "$CTL" watchdog-arm "$BUS"
  [ "$status" -eq 0 ]

  local line
  line="$(grep -F "# unimatrix-watchdog $BUS" "$FAKE_CRONTAB_FILE")"
  [ "${#line}" -lt 900 ]
  [[ "$line" != *nonexistent-dummy-path-segment* ]]
  [[ "$line" == *"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin "* ]]

  # the FULL resolved PATH (incl. the dummy segment) + an absolute CLAUDE_BIN land in watchdog.env
  [ -f "$BUS/watchdog.env" ]
  local envpath cbin
  envpath="$(bash -c 'source "$1"; printf %s "$PATH"' _ "$BUS/watchdog.env")"
  [[ "$envpath" == *nonexistent-dummy-path-segment-1:* ]]
  cbin="$(bash -c 'source "$1"; printf %s "${CLAUDE_BIN:-}"' _ "$BUS/watchdog.env")"
  [ "$cbin" = "$BATS_TEST_TMPDIR/bin/claude" ]
}

@test "spec11 cron line: crontab install rejection → arm rc 1 + loud stderr; re-arm after fix succeeds" {
  _spec11_install_fakes
  # break the shim the way a per-line-limit rejection breaks real crontab: reject `crontab -`
  cat > "$BATS_TEST_TMPDIR/bin/crontab" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  -l) exit 1 ;;
  -) cat >/dev/null; echo '"-":1: command too long' >&2; exit 1 ;;
esac
exit 2
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/crontab"

  run "$CTL" watchdog-arm "$BUS"
  [ "$status" -eq 1 ]
  [[ "$output" == *"crontab install failed"* ]]

  # no half-armed state: with a working crontab again, a plain re-arm installs the tagged line
  _spec11_install_fakes
  run "$CTL" watchdog-arm "$BUS"
  [ "$status" -eq 0 ]
  grep -qF "# unimatrix-watchdog $BUS" "$FAKE_CRONTAB_FILE"
}

@test "spec11 cron line: crontab that swallows the install (rc 0, line absent from -l) → arm rc 1" {
  # rc alone is not proof: arm must re-snapshot `crontab -l` and find its tagged line.
  _spec11_install_fakes
  cat > "$BATS_TEST_TMPDIR/bin/crontab" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  -l) exit 1 ;;
  -) cat >/dev/null; exit 0 ;;
esac
exit 2
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/crontab"

  run "$CTL" watchdog-arm "$BUS"
  [ "$status" -eq 1 ]
  [[ "$output" == *"crontab install failed"* ]]
}

@test "spec11 cron line: composed line over 900 chars (very long busdir) → refuse, nothing installed" {
  _spec11_install_fakes
  local deep="$BATS_TEST_TMPDIR/deep" i
  for i in $(seq 1 40); do deep+="/dddddddddddddd"; done
  mkdir -p "$deep"

  run "$CTL" watchdog-arm "$deep"
  [ "$status" -eq 1 ]
  [[ "$output" == *"refusing to arm"* ]]
  [ ! -s "$FAKE_CRONTAB_FILE" ]
}

# --- spec 12 FR-5: operator surfaces (report / postmortem / review-stub) --------------------------
# These verbs don't exist in src/swarm-ctl yet — unknown verbs fall through to usage (rc 1). Every
# assertion below is the post-implementation contract (specs/12-failure-evidence.md FR-5,
# acceptance criterion 6) so the GREEN wave flips these.

@test "spec12 report: renders the speedwars LANE table from an explicit ledger file" {
  local ledger="$BATS_TEST_TMPDIR/lw.jsonl"
  cat > "$ledger" <<'EOF'
{"ts":"2026-07-24T22:00:00Z","run":"r1","id":"a1","requested":"glm:glm-5.2","served_lane":"glm","outcome":"done","wall_secs":42,"billing":"pool"}
{"ts":"2026-07-24T22:01:00Z","run":"r1","id":"a2","requested":"grok:grok-4.5","served_lane":"grok","outcome":"done","wall_secs":30,"billing":"pool"}
EOF
  BUSDIR="$BUS" run "$CTL" report "$ledger"
  [ "$status" -eq 0 ]
  [[ "$output" == *"LANE"* ]]
  [[ "$output" == *"glm"* ]]
  [[ "$output" == *"grok"* ]]
}

@test "spec12 report: nonzero + loud stderr when the ledger file is missing" {
  BUSDIR="$BUS" run "$CTL" report "$BATS_TEST_TMPDIR/no-such-ledger.jsonl"
  [ "$status" -ne 0 ]
  [ -n "$output" ]
}

@test "spec12 postmortem: no arg pretty-prints the NEWEST run-summary row" {
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/pm.jsonl"
  cat > "$SPEEDWARS_FILE" <<'EOF'
{"type":"run-summary","ts":"2026-07-24T22:00:00Z","run":"r1","mode":"full","branches":{"a":{"lane":"glm","outcome":"done"}},"done_n":1,"parked_n":0}
{"type":null,"run":"r1","id":"a","outcome":"done"}
{"type":"run-summary","ts":"2026-07-24T23:00:00Z","run":"r2","mode":"full","branches":{"b":{"lane":"grok","outcome":"done"}},"done_n":1,"parked_n":0}
EOF
  BUSDIR="$BUS" run "$CTL" postmortem
  [ "$status" -eq 0 ]
  [[ "$output" == *'"run": "r2"'* ]]
  [[ "$output" != *'"run": "r1"'* ]]
}

@test "spec12 postmortem: <run> arg prints every run-summary row for that run" {
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/pm2.jsonl"
  cat > "$SPEEDWARS_FILE" <<'EOF'
{"type":"run-summary","ts":"2026-07-24T22:00:00Z","run":"r1","mode":"full","branches":{},"done_n":1,"parked_n":0}
{"type":"run-summary","ts":"2026-07-24T23:00:00Z","run":"r1","mode":"verify","branches":{},"done_n":2,"parked_n":0}
{"type":"run-summary","ts":"2026-07-24T21:00:00Z","run":"r2","mode":"full","branches":{},"done_n":0,"parked_n":0}
EOF
  BUSDIR="$BUS" run "$CTL" postmortem r1
  [ "$status" -eq 0 ]
  local n
  n="$(grep -c '"run": "r1"' <<<"$output")"
  [ "$n" -eq 2 ]
  [[ "$output" != *'"run": "r2"'* ]]
}

@test "spec12 postmortem: nonzero + message when the ledger is absent" {
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/no-such-pm.jsonl"
  BUSDIR="$BUS" run "$CTL" postmortem
  [ "$status" -ne 0 ]
  [ -n "$output" ]
}

@test "spec12 postmortem: nonzero + message when no run-summary rows match a named run" {
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/pm3.jsonl"
  cat > "$SPEEDWARS_FILE" <<'EOF'
{"type":"run-summary","ts":"2026-07-24T22:00:00Z","run":"r1","mode":"full","branches":{},"done_n":0,"parked_n":0}
EOF
  BUSDIR="$BUS" run "$CTL" postmortem no-such-run
  [ "$status" -ne 0 ]
  [ -n "$output" ]
}

@test "spec12 review-stub: prints a pre-filled histogram/lanes/wall-clock skeleton and writes NOTHING" {
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/rs.jsonl"
  export SPEEDWARS_RUN="stubrun"
  cat > "$SPEEDWARS_FILE" <<'EOF'
{"type":null,"run":"stubrun","id":"c1","served_lane":"glm","outcome":"done","wall_secs":42,"ts":"2026-07-24T22:00:00Z"}
{"type":null,"run":"stubrun","id":"c2","served_lane":"grok","outcome":"timeout","wall_secs":30,"ts":"2026-07-24T22:01:00Z"}
{"type":null,"run":"stubrun","id":"c3","served_lane":"glm","outcome":"parked","wall_secs":null,"ts":"2026-07-24T22:02:00Z"}
{"type":null,"run":"other-run","id":"z1","served_lane":"codex","outcome":"done","wall_secs":9,"ts":"2026-07-24T22:03:00Z"}
EOF
  touch "$BUS/done/c1" "$BUS/done/c2"

  local before after
  before="$(find "$BUS" -type f | sort)"
  BUSDIR="$BUS" run "$CTL" review-stub "$BUS"
  [ "$status" -eq 0 ]
  after="$(find "$BUS" -type f | sort)"
  [ "$before" = "$after" ]

  [[ "$output" == *"stubrun"* ]]
  [[ "$output" == *"glm"* ]]
  [[ "$output" == *"grok"* ]]
  [[ "$output" != *"codex"* ]]  # other-run's rows must not leak into this bus's stub
  [[ "$output" == *"done=1 timeout=1 parked=1 lane-unusable=0"* ]]
  # Assert the RENDERED ROW, not a bare "2" anywhere in the template — the old form matched the
  # date ("2026-…"), the wall-clock row, and the literal "2 needed rescue" blurb, so it passed for
  # any card_n at all.
  [[ "$output" == *"| Card count (done/) | 2 |"* ]]
}

@test "P0-FR1 review-stub: default run label (no SPEEDWARS_RUN) matches _run_label's own derivation" {
  unset SPEEDWARS_RUN
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/rs-default.jsonl"
  local expected; expected="$(_run_label "$BUS")"
  printf '{"type":null,"run":"%s","id":"c1","served_lane":"glm","outcome":"done","wall_secs":1,"ts":"2026-07-24T22:00:00Z"}\n' \
    "$expected" > "$SPEEDWARS_FILE"
  BUSDIR="$BUS" run "$CTL" review-stub "$BUS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$expected"* ]]
}

@test "F2 review-stub: a bus with a persisted .run-label harvests THAT run, not a re-derived one" {
  # The F2 repro: swarm-run stamped the ledger under the run label it persisted at run start; a
  # later `swarm-ctl review-stub` from a FRESH shell (no SPEEDWARS_RUN) must read the same label
  # off the bus instead of re-deriving one from the busdir's path and harvesting a foreign run.
  unset SPEEDWARS_RUN
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/rs-persisted.jsonl"
  echo "wave-42" > "$BUS/.run-label"
  printf '{"type":null,"run":"wave-42","id":"mine","served_lane":"glm","outcome":"done","wall_secs":1,"ts":"2026-07-25T10:00:00Z"}\n' \
    > "$SPEEDWARS_FILE"
  printf '{"type":null,"run":"%s","id":"theirs","served_lane":"codex","outcome":"done","wall_secs":1,"ts":"2026-07-25T10:00:00Z"}\n' \
    "$(basename "$(dirname "$BUS")")" >> "$SPEEDWARS_FILE"

  BUSDIR="$BUS" run "$CTL" review-stub "$BUS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"wave-42"* ]]
  [[ "$output" == *"glm"* ]]
  [[ "$output" != *"codex"* ]]  # the re-derived label's rows must not be harvested into this stub
}

@test "spec12 review-stub: defaults busdir to \$BUSDIR when no arg is given" {
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/rs2.jsonl"
  export SPEEDWARS_RUN="defaultrun"
  : > "$SPEEDWARS_FILE"
  BUSDIR="$BUS" run "$CTL" review-stub
  [ "$status" -eq 0 ]
  [[ "$output" == *"defaultrun"* ]]
}

# --- spec 15 RED wave: unpark (bulk park-storm resume) ------------------------------------
# `unpark` doesn't exist in src/swarm-ctl yet (dispatch has no unpark verb). Every test below
# is deliberately RED against the current tree — it asserts the post-implementation behavior
# (spec 15 park-storm resume: rm limits/<id>.parked for one or more ids, or --all except the
# spec-11 watchdog marker limits/takeover.parked, which must never be touched).

@test "unpark <id>: removes exactly that id's marker, leaves an unrelated one in place" {
  touch "$BUS/limits/u1.parked" "$BUS/limits/u2.parked"
  BUSDIR="$BUS" run "$CTL" unpark u1
  [ "$status" -eq 0 ]
  [ ! -e "$BUS/limits/u1.parked" ]
  [ -e "$BUS/limits/u2.parked" ]
}

@test "unpark --all: removes every limits/*.parked EXCEPT takeover.parked" {
  touch "$BUS/limits/u3.parked" "$BUS/limits/u4.parked" "$BUS/limits/takeover.parked"
  BUSDIR="$BUS" run "$CTL" unpark --all
  [ "$status" -eq 0 ]
  [ ! -e "$BUS/limits/u3.parked" ]
  [ ! -e "$BUS/limits/u4.parked" ]
  [ -e "$BUS/limits/takeover.parked" ]
  [[ "$output" == *"2"* ]]  # count removed
}

@test "unpark --all: idempotent rc0 with count 0 when there is nothing parked" {
  BUSDIR="$BUS" run "$CTL" unpark --all
  [ "$status" -eq 0 ]
  [[ "$output" == *"0"* ]]
}

@test "unpark <id>: missing marker warns to stderr, rc1, nothing removed" {
  touch "$BUS/limits/u5.parked"
  BUSDIR="$BUS" run "$CTL" unpark no-such-id
  [ "$status" -eq 1 ]
  [ -n "$output" ]
  [ -e "$BUS/limits/u5.parked" ]
}

@test "unpark <id> <id>: one hit + one miss still removes the hit and exits rc0, warning for the miss" {
  touch "$BUS/limits/u6.parked"
  BUSDIR="$BUS" run "$CTL" unpark u6 no-such-id
  [ "$status" -eq 0 ]
  [ ! -e "$BUS/limits/u6.parked" ]
  [[ "$output" == *"no-such-id"* ]]
}

# --- codex review fixes: id validation, takeover guard, stale-chain reset -------------------

@test "unpark: rejects a path-traversal id before building any path — decoy file outside limits/ survives" {
  touch "$BATS_TEST_TMPDIR/evil.parked"
  BUSDIR="$BUS" run "$CTL" unpark "../../evil"
  [ "$status" -eq 1 ]
  [ -e "$BATS_TEST_TMPDIR/evil.parked" ]
}

@test "unpark takeover: refuses the literal id 'takeover' — apex marker survives" {
  touch "$BUS/limits/takeover.parked"
  BUSDIR="$BUS" run "$CTL" unpark takeover
  [ "$status" -eq 1 ]
  [ -e "$BUS/limits/takeover.parked" ]
}

@test "unpark <id>: also resets stale chain state (limits/.chain-<id> removed)" {
  touch "$BUS/limits/u7.parked"
  echo "codex kimi" > "$BUS/limits/.chain-u7"
  BUSDIR="$BUS" run "$CTL" unpark u7
  [ "$status" -eq 0 ]
  [ ! -e "$BUS/limits/u7.parked" ]
  [ ! -e "$BUS/limits/.chain-u7" ]
}
