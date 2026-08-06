#!/usr/bin/env bats
# Integration tests for swarm-run.sh full mode — shard 4/4 of the former tests/swarm-run.bats,
# split so check.sh's CHECK_JOBS per-file fan-out gets a shorter critical path. No real API calls —
# every claude/codex/gemini invocation resolves to a fake script under $BATS_TEST_TMPDIR/bin,
# installed by the shared fixture this file loads.
#
# Project: unimatrix — multi-model swarm orchestrator driven from Claude Code
# Module:  tests/swarm-run-4.bats
# Deps:    bats-core, tests/helpers/swarm-run-fixture.bash (setup/teardown + fakes + helpers), src/swarm-lib.sh, swarm-run.sh
# Tested:  n/a — this is the test file
#
# Design constraints:
# - All file-scope state, setup()/teardown(), fake installers, and probe/fixture helpers live in
#   tests/helpers/swarm-run-fixture.bash — pulled in by the `load` below (bats resolves it against
#   this file's own dir and picks setup/teardown up from the fixture).
# - Test bodies are verbatim from the original file; original order is preserved within the shard.

load 'helpers/swarm-run-fixture'

# --- spec 14 FR-2: per-card deliverable manifest (queue/<id>.files) ----------------------------


@test "spec14 FR-2: a manifest listing a.ts REJECTS a card that only changed b.ts (the neighbour's edit no longer satisfies this gate)" {
  _write_conf "claude:opus" 4 15
  local target="$BATS_TEST_TMPDIR/fm1"
  _fake FAKE_CLAUDE_RESULT "claims done, wrote the wrong file"
  _fake FAKE_CLAUDE_WRITE_FILE "b.ts"
  _files_card fm1 "$target" 'a.ts
'

  run timeout 25 "$RUNSH"
  [ "$status" -ne 0 ]
  [ ! -e "$BUS/done/fm1" ]
  [ -f "$BUS/limits/fm1.parked" ]
  # the neighbour's byte really did land — the gate rejected on SCOPE, not on an empty target
  [ "$(<"$target/b.ts")" = "written" ]
}

@test "spec14 FR-2: the same manifest PASSES when the listed file itself changed, and the sidecar is archived to files-<id>.txt" {
  _write_conf "claude:opus" 4 15
  local target="$BATS_TEST_TMPDIR/fm2"
  _fake FAKE_CLAUDE_RESULT "wrote the deliverable"
  _fake FAKE_CLAUDE_WRITE_FILE "a.ts"
  _files_card fm2 "$target" 'a.ts
'

  run timeout 25 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/fm2" ]
  # lifecycle mirrors .write byte-for-byte: archived beside write-<id>.txt, dropped from queue/
  [ -f "$BUS/files-fm2.txt" ]
  [ "$(<"$BUS/files-fm2.txt")" = "a.ts" ]
  [ ! -e "$BUS/queue/fm2.files" ]
  [ ! -e "$BUS/specs/fm2.files" ]
}

@test "spec14 FR-2: no manifest = today's whole-cage gate, byte-identical — a change to any file under the target still passes" {
  _write_conf "claude:opus" 4 15
  local target="$BATS_TEST_TMPDIR/fm3"
  _fake FAKE_CLAUDE_RESULT "wrote something under the cage"
  _fake FAKE_CLAUDE_WRITE_FILE "b.ts"
  _files_card fm3 "$target" 'a.ts
'
  rm -f "$BUS/specs/fm3.files"   # same fixture as fm1, manifest deleted

  run timeout 25 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/fm3" ]
  [ ! -e "$BUS/files-fm3.txt" ]
}

@test "spec14 FR-2 trust boundary: absolute and target-escaping manifest entries are IGNORED with a loud line, never widening the cage" {
  _write_conf "claude:opus" 4 15
  local target="$BATS_TEST_TMPDIR/fm4"
  _fake FAKE_CLAUDE_RESULT "wrote the one legitimate deliverable"
  _fake FAKE_CLAUDE_WRITE_FILE "a.ts"
  _files_card fm4 "$target" '/etc/passwd
../escape.ts
a.ts
'
  # a real, freshly-written file at the escaping path — if the gate honored the entry it would
  # "pass" on bytes outside the cage even when a.ts never changed
  printf 'not mine\n' > "$BATS_TEST_TMPDIR/escape.ts"

  run timeout 25 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/fm4" ]
  [[ "$output" == *"ignoring manifest entry"*"/etc/passwd"* ]]
  [[ "$output" == *"ignoring manifest entry"*"../escape.ts"* ]]
}

@test "spec14 FR-2: the sweep moves specs/<id>.files into queue/ with the other sidecars, and the done/cancelled discard arms drop it" {
  _write_conf "claude:opus" 4 15
  mkdir -p "$BUS/done" "$BUS/cancelled" "$BUS/queue" "$BUS/specs"
  _fake FAKE_CLAUDE_RESULT "fresh answer"

  # done/<id> and cancelled/<id>: consume-and-discard — a sidecar the sweep can MOVE but not
  # DISCARD is the FR-B bug reborn (an orphan .files in queue/ scoping a later card's gate).
  printf '{"id":"fs1","code":0,"lane":"claude"}\n' > "$BUS/done/fs1"
  _enqueue fs1 "already done"
  printf 'a.ts\n' > "$BUS/specs/fs1.files"
  printf 'pulled' > "$BUS/cancelled/fs2.prompt"
  _enqueue fs2 "already cancelled"
  printf 'a.ts\n' > "$BUS/specs/fs2.files"

  # a fresh read card carrying a manifest — proves the sweep moves it at all
  _enqueue fs3 "fresh card carrying a manifest"
  printf 'a.ts\n' > "$BUS/specs/fs3.files"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]

  [ ! -e "$BUS/specs/fs1.files" ]; [ ! -e "$BUS/queue/fs1.files" ]
  [ ! -e "$BUS/specs/fs2.files" ]; [ ! -e "$BUS/queue/fs2.files" ]
  [ -f "$BUS/done/fs3" ]
  [ -f "$BUS/files-fs3.txt" ]
  [ ! -e "$BUS/specs/fs3.files" ]; [ ! -e "$BUS/queue/fs3.files" ]
}

# --- spec 14 FR-6: sibling-liveness guard on the retries-exhausted broken_flag -----------------

@test "spec14 FR-6: a retries-exhausted lane-down with a LIVE sibling on the lane downgrades to a short-TTL .broken, not the long-TTL default" {
  _write_conf "claude:opus" 4 15
  cat >> "$CONF" <<'EOF2'
MAX_LANE_RETRIES=1
EOF2
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-f6.jsonl"
  mkdir -p "$BUS/claimed"
  # A sibling claim on the SAME lane with a fresh run log — provably alive by reap's own LEASE_MIN
  # clock. No real worker behind it (that's what makes the fixture deterministic), so the pool's
  # gate can never close and the run is aborted below rather than waited out.
  printf 'sibling prompt' > "$BUS/claimed/f6sib.claude:opus"
  printf '{"type":"init"}\n' > "$BUS/run-f6sib.jsonl"
  _fake FAKE_CLAUDE_SILENT_FAIL 126
  _enqueue f6a "card that fast-fails the lane while a sibling is still streaming"

  local logf="$BATS_TEST_TMPDIR/f6.log"
  "$RUNSH" >"$logf" 2>&1 3>&- &
  BG_PIDS+=("$!")

  _poll 20 test -f "$BUS/limits/f6a.parked"
  [ -f "$BUS/limits/f6a.parked" ]
  # positive liveness evidence outranks the failure counter: the class is still lane-down (the card
  # really did fast-fail), but the LANE stays a `.broken` flag — just a short-TTL one, not the
  # long-TTL default — never `.limited` (cross-review MAJOR: `.limited` is never cleared by any
  # code path but its own TTL; `.broken` IS cleared by this lane's next successful finalize, which
  # is imminent exactly when this downgrade fires — a live sibling).
  [ ! -e "$BUS/limits/claude.limited" ]
  [ -f "$BUS/limits/claude.broken" ]
  [[ "$(<"$BUS/limits/claude.broken")" == *"sibling live"* ]]
  [[ "$(<"$BUS/limits/claude.broken")" == *"ttl=600"* ]]
  [ "$(jq -r 'select(.id=="f6a" and .outcome=="retry") | .class' "$SPEEDWARS_FILE")" = "lane-down" ]

  if [ -f "$BUS/run.pgid" ]; then
    kill -- "-$(cat "$BUS/run.pgid")" 2>/dev/null || true
  fi
  wait "${BG_PIDS[0]}" 2>/dev/null || true
  BG_PIDS=()
}

# --- cross-review fix round (codex + structural seat), 2026-07-25 ------------------------------

@test "cross-review CRITICAL: a pinned write card with an EXISTING target on a blocked lane accumulates wait time and parks at PIN_WAIT_SEC with exactly one stderr notice" {
  # Pre-fix: FR-5's write-target-existence check and FR-R6's pinned-lane-blocked wait shared the
  # SAME filename (limits/<id>.waiting). With an EXISTING target, FR-5's own `rm -f` on that shared
  # file fired on every poll and wiped out the timer FR-R6 had just started moments earlier — the
  # "waiting" notice printed every poll and PIN_WAIT_SEC was never actually reached, so the card
  # never parked (the whole run just hung until the outer `timeout` killed it, status 124).
  _write_conf "claude:opus" 4 15
  cat >> "$CONF" <<'EOF2'
PIN_WAIT_SEC=2
EOF2
  printf 'Z_AI_CODING_KEY=test-glm-key\n' > "$BATS_TEST_TMPDIR/envmaster"
  export ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster"
  local target="$BATS_TEST_TMPDIR/f5r6-target"
  mkdir -p "$target"
  mkdir -p "$BUS/limits"
  printf '18000' > "$BUS/limits/glm.limited"
  _enqueue f5r6 "pinned write card, target exists, lane blocked"
  echo "glm:glm-5.2" > "$BUS/specs/f5r6.lane"
  printf '%s' "$target" > "$BUS/specs/f5r6.write"

  run timeout 20 "$RUNSH"
  [ "$status" -ne 0 ]
  [ -f "$BUS/limits/f5r6.parked" ]
  local waits; waits="$(grep -c "pinned to glm:glm-5.2 which is" <<<"$output" || true)"
  [ "$waits" -eq 1 ]
}

@test "cross-review MAJOR: a downgraded auth-death envelope (live sibling) still yields class auth-death and fbreason dead" {
  # Pre-fix: the lib's FR-6 downgrade path never writes .dead at all (a live sibling downgrades
  # straight to a short-TTL .broken carrying the auth-death reason token) — swarm-run's class
  # keying and fallback-provenance both keyed ONLY on `lane_dead`, so a downgraded auth-death
  # silently reclassified as a generic rate-limit and its fbreason as "limit", not "dead".
  _write_conf "claude:opus codex:default" 4 15
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-f6ad.jsonl"
  mkdir -p "$BUS/claimed"
  # sibling claim on the SAME lane with a fresh run log — provably alive by reap's LEASE_MIN clock.
  # No real worker behind it (deterministic fixture), so the pool's gate can never close and the
  # run is aborted below rather than waited out (same shape as the adjacent FR-6 test).
  printf 'sibling prompt' > "$BUS/claimed/f6adsib.claude:opus"
  printf '{"type":"init"}\n' > "$BUS/run-f6adsib.jsonl"
  _fake FAKE_CLAUDE_ONCE_MARKER "$BATS_TEST_TMPDIR/f6ad-once"
  _fake FAKE_CLAUDE_ONCE_MODE autherr
  _fake FAKE_CODEX_RESULT "codex rescued it"
  _enqueue f6ad "claude auth-death branch while a sibling is live"

  local logf="$BATS_TEST_TMPDIR/f6ad.log"
  "$RUNSH" >"$logf" 2>&1 3>&- &
  BG_PIDS+=("$!")

  _poll 20 test -f "$BUS/done/f6ad"
  [ -f "$BUS/done/f6ad" ]
  [ "$(jq -r '.lane' "$BUS/done/f6ad")" = "codex" ]
  [ ! -e "$BUS/limits/claude.dead" ]
  [ -f "$BUS/limits/claude.broken" ]
  [[ "$(<"$BUS/limits/claude.broken")" == *"| auth-death |"* ]]
  [ "$(jq -r 'select(.id=="f6ad" and .served_lane=="claude") | .class' "$SPEEDWARS_FILE")" = "auth-death" ]
  # the "done" speedwars row is written AFTER the done/ marker (chain_reset/ledger/speed_row all
  # follow it in _finalize_worker) — poll for the row itself, not just the marker, to avoid a race.
  _poll 10 jq -e --arg i f6ad 'select(.id==$i and .outcome=="done")' "$SPEEDWARS_FILE"
  run jq -r 'select(.id=="f6ad" and .outcome=="done") | .fallback_reason' "$SPEEDWARS_FILE"
  [[ "$output" == *"dead"* ]]

  if [ -f "$BUS/run.pgid" ]; then
    kill -- "-$(cat "$BUS/run.pgid")" 2>/dev/null || true
  fi
  wait "${BG_PIDS[0]}" 2>/dev/null || true
  BG_PIDS=()
}

@test "cross-review MAJOR (codex): a manifest entry that resolves to a DIRECTORY is ignored loudly — the gate rejects when it was the only entry" {
  # Pre-fix: _manifest_roots treated every entry as a find ROOT with no file-vs-directory check —
  # a directory entry let find recurse into it and match any file changed inside, even ones the
  # manifest never literally named (the verify-side twin only ever accepts files).
  _write_conf "claude:opus" 4 15
  local target="$BATS_TEST_TMPDIR/fm-dir"
  mkdir -p "$target/subdir"
  touch -d '30 seconds ago' "$target" "$target/subdir"
  _fake FAKE_CLAUDE_RESULT "claims done, wrote inside the manifest's directory entry"
  _fake FAKE_CLAUDE_WRITE_FILE "subdir/sneaky.ts"
  _enqueue fmdir "write card whose manifest names a directory, not a file"
  printf '%s' "$target" > "$BUS/specs/fmdir.write"
  printf 'subdir\n' > "$BUS/specs/fmdir.files"

  run timeout 25 "$RUNSH"
  [ "$status" -ne 0 ]
  [ ! -e "$BUS/done/fmdir" ]
  [ -f "$BUS/limits/fmdir.parked" ]
  [[ "$output" == *"ignoring manifest entry 'subdir'"*"must be files"* ]]
  # the byte really did land inside the directory the manifest named — rejected on SCOPE (the
  # directory root was ignored, not resolved), not because nothing changed at all
  [ -f "$target/subdir/sneaky.ts" ]
}

@test "cross-review MINOR: a watchdog-killed cage-denied WRITE card parks cage-denied, not a chain-advanced timeout" {
  # Pre-fix: the .timedout branch never ran the FR-1 cage-denied gate at all — a card that answered
  # (describing the denial) and then hung post-answer would salvage-fail (nothing written) and fall
  # straight through to the ordinary timeout failover, chain-advancing through every rung of a
  # guaranteed-futile cage instead of parking once.
  _write_conf "claude:opus codex:gpt-5" 4 15
  cat >> "$CONF" <<'EOF2'
WORKER_TIMEOUT_SEC=2
EOF2
  local target="$BATS_TEST_TMPDIR/tdcg-target"
  mkdir -p "$target"
  touch -d '10 seconds ago' "$target"
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-tdcg.jsonl"
  _fake FAKE_CLAUDE_ONCE_MARKER "$BATS_TEST_TMPDIR/tdcg-once"
  _fake FAKE_CLAUDE_ONCE_MODE answerhang
  _fake FAKE_CLAUDE_SALVAGE_RESULT "CANARYLEAK I was denied every read and cannot proceed"
  _fake FAKE_CLAUDE_DENIALS_JSON "$(_cage_denials_fixture)"
  _fake FAKE_CODEX_RESULT "the fallback lane must never be reached"
  _enqueue tdcg "write card whose cage-denied answer lands, then the worker hangs — nothing written"
  printf '%s' "$target" > "$BUS/specs/tdcg.write"

  run timeout 20 "$RUNSH"
  [ "$status" -ne 0 ]
  [ -f "$BUS/limits/tdcg.parked" ]
  [ -f "$BUS/limits/tdcg.cage-denied" ]
  [ ! -e "$BUS/done/tdcg" ]
  [ ! -e "$BUS/limits/.chain-tdcg" ]
  [ "$(jq -r 'select(.id=="tdcg" and .outcome=="parked") | .class' "$SPEEDWARS_FILE")" = "cage-denied" ]
  # one spawn total — never chain-advanced to codex, never a separate "timeout" row either
  [ "$(jq -s '[.[] | select(.id=="tdcg")] | length' "$SPEEDWARS_FILE")" = "1" ]
}

@test "cross-review MINOR: a stale .cage-denied marker is cleared once the same id later finalizes done" {
  # Pre-fix: _archive_and_release's rm list never included limits/<id>.cage-denied — a card nudged
  # past a cage-denied park and re-run successfully left the stale marker behind forever.
  _write_conf "claude:opus" 4 15
  mkdir -p "$BUS/limits"
  printf 'denials=3\n/some/denied/path\n' > "$BUS/limits/cgclear.cage-denied"
  _fake FAKE_CLAUDE_RESULT "answered cleanly this time"
  _enqueue cgclear "card that previously parked cage-denied, now nudged and re-run"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/cgclear" ]
  [ ! -e "$BUS/limits/cgclear.cage-denied" ]
}

@test "cross-review NOTE: _check_parked prints the marker's own reason token for a cage-denied park, not a hardcoded 'lane exhausted'" {
  _write_conf "claude:opus codex:gpt-5" 4 15
  _fake FAKE_CLAUDE_RESULT "CANARYLEAK denied every read"
  _fake FAKE_CLAUDE_DENIALS_JSON "$(_cage_denials_fixture)"
  _fake FAKE_CODEX_RESULT "fallback must never run"
  _enqueue cgtok "card the cage denies"

  run timeout 20 "$RUNSH"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cgtok parked (cage-denied)"* ]]
  [[ "$output" != *"cgtok parked (lane exhausted)"* ]]
}

# --- spec 15: call verb ------------------------------------------------------------------------
# RED wave — `call` does not exist yet: swarm-run.sh's dispatch case falls through `*)` to
# full_run, which IGNORES its positional arg entirely, so every invocation below currently drains
# an empty bus and exits 0 with nothing staged. Each test therefore fails on either the exit code
# (the refusal cases) or the missing artifacts (the happy paths).
#
# Every test pins BUSDIR (setup()'s fresh $BUS under $BATS_TEST_TMPDIR) plus its own SPEEDWARS_FILE
# and LEDGER_FILE so no evidence surface outside the tmpdir is ever touched — the ONE exception is
# the deliberate default-BUSDIR test at the bottom, which cds into $BATS_TEST_TMPDIR first.

@test "call: happy path — one glm card staged and drained, .lane/speedwars/run-summary all recorded" {
  _write_conf "claude:opus" 4 15
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-call1.jsonl"
  export LEDGER_FILE="$BATS_TEST_TMPDIR/call1-ledger.md"
  _fake FAKE_CLAUDE_RESULT "hi from glm"

  run timeout 25 "$RUNSH" call glm "say hi"
  [ "$status" -eq 0 ]

  # id defaults to call-$$ (unknown to the test) — assert the SHAPE of the bus instead: exactly one
  # card, served by glm, with a non-empty answer.
  [ "$(find "$BUS/done" -maxdepth 1 -type f | wc -l)" -eq 1 ]
  local d; d="$(find "$BUS/done" -maxdepth 1 -type f | head -1)"
  [ "$(jq -r '.lane' "$d")" = "glm" ]
  local r; r="$(find "$BUS" -maxdepth 1 -name 'res-*.txt' | head -1)"
  [ -s "$r" ]
  # bare lane -> _verify_default_model (glm -> glm-5.2), recorded as the REQUESTED lane:model
  [ "$(jq -r 'select(.type==null) | .requested' "$SPEEDWARS_FILE")" = "glm:glm-5.2" ]
  # SPEEDWARS_RUN is stamped call-<label|$$>, and full_run's close-out appends the summary row
  [[ "$(jq -r 'select(.type=="run-summary") | .run' "$SPEEDWARS_FILE")" == call-* ]]
  [ "$(jq -r 'select(.type=="run-summary") | .done_n' "$SPEEDWARS_FILE")" = "1" ]
}

@test "F4 call: the aggregate ledger row joins on _run_label and re-sums a REAL cost, never a filter-missed 0" {
  _write_conf "claude:opus" 4 15
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-f4.jsonl"
  export LEDGER_FILE="$BATS_TEST_TMPDIR/f4-ledger.md"
  _fake FAKE_CLAUDE_RESULT "hi"

  run timeout 25 "$RUNSH" call glm "say hi" --id cf4
  [ "$status" -eq 0 ]
  # cmd_call resolved the label and pinned it into the bus, so any later harvest agrees with it
  [ "$(<"$BUS/.run-label")" = "call-cf4" ]
  [[ "$output" == *"swarm-run call call-cf4"* ]]

  # the aggregate's cost is this run's own rows re-summed under THAT label — recompute it the same
  # way and demand the printed row carries it (an unjoined filter would print a real-looking 0)
  local want
  want="$(jq -rs '[.[] | select(.type == null and .run == "call-cf4") | .cost_usd // 0] | add // 0' \
    "$SPEEDWARS_FILE")"
  [[ "$output" == *"| $want |"* ]]
}

@test "#8/F5 call: the auto-started cockpit is told THIS call's busdir, not the engine's default .bus" {
  # A foreign-repo `unimatrix call` rewrites BUSDIR to .bus-call-<id> under the CALLER's cwd. The
  # systemd --user unit inherits nothing from this shell, so the busdir has to travel in the argv —
  # otherwise /health vouches for a bus the cockpit isn't watching. curl always fails (nothing is
  # up), systemd-run only records what it was asked to launch: no port, no server, no real unit.
  _write_conf "claude:opus" 4 15
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-f5e.jsonl"
  export LEDGER_FILE="$BATS_TEST_TMPDIR/f5e-ledger.md"
  _fake FAKE_CLAUDE_RESULT "hi"

  local stub="$BATS_TEST_TMPDIR/stub-cockpit"
  mkdir -p "$stub"
  printf '#!/usr/bin/env bash\nexit 7\n' > "$stub/curl"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> %q\nprintf "env:%%s\\n" "${BUSDIR:-UNSET}" >> %q\nexit 0\n' \
    "$BATS_TEST_TMPDIR/systemd-run.argv" "$BATS_TEST_TMPDIR/systemd-run.argv" > "$stub/systemd-run"
  chmod +x "$stub/curl" "$stub/systemd-run"

  unset BUSDIR
  cd "$BATS_TEST_TMPDIR"
  # MON_OPEN_CMD=true: opener stubbed inert — MON_AUTOOPEN=1 without it fell through to the real
  # powershell.exe branch and popped a dead localhost:39999 tab on the operator's browser every
  # suite run (2026-08-01).
  PATH="$stub:$PATH" MON_AUTOOPEN=1 MON_PORT=39999 MON_OPEN_CMD=true \
    run timeout 40 "$RUNSH" call glm "say hi" --id cf5
  [ "$status" -eq 0 ]

  local want="$BATS_TEST_TMPDIR/.bus-call-cf5"
  grep -qF -- "--setenv=BUSDIR=$want" "$BATS_TEST_TMPDIR/systemd-run.argv"
  # ...and the rewritten BUSDIR is EXPORTED, which is all the systemd-less fallback branch (a bare
  # `setsid nohup node`, no argv to carry it) has to go on.
  grep -qF "env:$want" "$BATS_TEST_TMPDIR/systemd-run.argv"
}

@test "call: explicit lane:model is passed through verbatim (no default-model substitution)" {
  _write_conf "claude:opus" 4 15
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-call2.jsonl"
  export LEDGER_FILE="$BATS_TEST_TMPDIR/call2-ledger.md"
  _fake FAKE_CLAUDE_RESULT "hi from kimi"

  run timeout 25 "$RUNSH" call kimi:kimi-k2.7-code "say hi" --id c2
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/c2" ]
  [ "$(jq -r '.lane' "$BUS/done/c2")" = "kimi" ]
  [ "$(jq -r 'select(.id=="c2") | .requested' "$SPEEDWARS_FILE")" = "kimi:kimi-k2.7-code" ]
}

@test "call: bare grok resolves to grok:default and the spawn carries no -m flag" {
  _write_conf "claude:opus" 4 15
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-call3.jsonl"
  export LEDGER_FILE="$BATS_TEST_TMPDIR/call3-ledger.md"
  _fake FAKE_GROK_RESULT "hi from grok"
  _fake FAKE_GROK_ARGV_FILE "$BATS_TEST_TMPDIR/grok-argv"

  run timeout 25 "$RUNSH" call grok "say hi" --id c3
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/c3" ]
  [ "$(jq -r 'select(.id=="c3") | .requested' "$SPEEDWARS_FILE")" = "grok:default" ]
  # "default" must mean "omit -m", not "pass the literal string default" (lane_cmd's grok arm)
  [ -f "$BATS_TEST_TMPDIR/grok-argv" ]
  [[ "$(<"$BATS_TEST_TMPDIR/grok-argv")" != *" -m "* ]]
}

@test "call: unknown lane is a usage error — nonzero and NOTHING staged" {
  _write_conf "claude:opus" 4 15
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-call4.jsonl"
  export LEDGER_FILE="$BATS_TEST_TMPDIR/call4-ledger.md"

  run timeout 25 "$RUNSH" call llama "x" --id c4
  [ "$status" -ne 0 ]
  # refusal happens at parse time — no card ever reaches specs/ or queue/ (bus may not even exist)
  [ -z "$(find "$BUS" -name '*.prompt' 2>/dev/null)" ]
  [ -z "$(find "$BUS" -name '*.lane' 2>/dev/null)" ]
}

@test "call: --write puts the worker's cwd in the target dir; gemini + --write is refused before staging" {
  _write_conf "claude:opus" 4 15
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-call5.jsonl"
  export LEDGER_FILE="$BATS_TEST_TMPDIR/call5-ledger.md"
  local target="$BATS_TEST_TMPDIR/calltarget"
  mkdir -p "$target"
  _fake FAKE_CLAUDE_RESULT "wrote it"
  # relative path — landing at $target/probe.txt proves the worker was chdir'd, not just that the
  # string appeared somewhere in argv
  _fake FAKE_CLAUDE_WRITE_FILE "probe.txt"
  _fake FAKE_CLAUDE_WRITE_CONTENT "from the write card"

  run timeout 25 "$RUNSH" call claude "x" --write "$target" --id c5
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/c5" ]
  [ -f "$target/probe.txt" ]
  [ "$(<"$target/probe.txt")" = "from the write card" ]

  # gemini is not write-capable (FR-15) — refuse at PARSE time, never stage a card that can only park
  local target2="$BATS_TEST_TMPDIR/calltarget2"
  mkdir -p "$target2"
  run timeout 25 "$RUNSH" call gemini "x" --write "$target2" --id c5b
  [ "$status" -ne 0 ]
  [ -z "$(find "$BUS/specs" "$BUS/queue" -name 'c5b*' 2>/dev/null)" ]
}

@test "call: --chain writes a .chain sidecar (primary prepended, bare tokens normalized) — no hard pin, so a failing primary falls over" {
  _write_conf "claude:opus" 4 15
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-call6.jsonl"
  export LEDGER_FILE="$BATS_TEST_TMPDIR/call6-ledger.md"
  # glm == the fake claude binary; garbage mode = no usable answer, so the card burns its
  # MAX_LANE_RETRIES budget on glm and then advances the chain.
  _fake FAKE_CLAUDE_GARBAGE_COUNT "$BATS_TEST_TMPDIR/c6-garbage"
  _fake FAKE_CODEX_RESULT "codex rescued it"

  run timeout 30 "$RUNSH" call glm "x" --chain "codex" --id c6
  [ "$status" -eq 0 ]

  # A .lane HARD pin would have parked here (pinned lanes never chain-switch) — reaching codex is
  # itself proof the sidecar written was .chain, not .lane.
  [ -f "$BUS/done/c6" ]
  [ "$(jq -r '.lane' "$BUS/done/c6")" = "codex" ]
  [ "$(<"$BUS/res-c6.txt")" = "codex rescued it" ]
  # queue/<id>.chain is consumed (rm'd) on success, so assert the chain's CONTENT via the durable
  # evidence rows instead: the failed attempts name the prepended primary with its default model,
  # the winning row names the normalized bare fallback token.
  [ -n "$(jq -r 'select(.id=="c6" and .served_lane=="glm" and .requested=="glm:glm-5.2") | .id' "$SPEEDWARS_FILE")" ]
  [ "$(jq -r 'select(.id=="c6" and .outcome=="done") | .requested' "$SPEEDWARS_FILE")" = "codex:default" ]
}

@test "call: --files/--batch splits into ceil(M/N) cards, each prompt carrying only its own chunk" {
  _write_conf "claude:opus" 4 15
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-call7.jsonl"
  export LEDGER_FILE="$BATS_TEST_TMPDIR/call7-ledger.md"
  _fake FAKE_CLAUDE_RESULT "batched OK"
  local fdir="$BATS_TEST_TMPDIR/files"
  mkdir -p "$fdir"
  local n
  for n in one two three four five; do : > "$fdir/$n.txt"; done
  printf '%s\n' "$fdir/one.txt" "$fdir/two.txt" "$fdir/three.txt" "$fdir/four.txt" "$fdir/five.txt" \
    > "$BATS_TEST_TMPDIR/filelist"

  run timeout 30 "$RUNSH" call claude "tidy these" --files "$BATS_TEST_TMPDIR/filelist" --batch 2 --id bx
  [ "$status" -eq 0 ]

  [ "$(find "$BUS/done" -maxdepth 1 -type f | wc -l)" -eq 3 ]
  [ -f "$BUS/done/bx-001" ]; [ -f "$BUS/done/bx-002" ]; [ -f "$BUS/done/bx-003" ]
  # each card sees ONLY its own chunk
  grep -q 'one.txt' "$BUS/prompt-bx-001.txt"
  grep -q 'two.txt' "$BUS/prompt-bx-001.txt"
  ! grep -q 'three.txt' "$BUS/prompt-bx-001.txt"
  grep -q 'five.txt' "$BUS/prompt-bx-003.txt"
  ! grep -q 'four.txt' "$BUS/prompt-bx-003.txt"
  # per-card manifest for the close-out report (engine never reads it)
  [ -f "$BUS/chunks/bx-001.files" ]
  [ -f "$BUS/chunks/bx-003.files" ]
  # close-out report: one files-touched line per card
  printf '%s\n' "$output" | grep -qE 'bx-001.*[0-9]+/2 files touched'
}

@test "call: --files without --batch is a usage error — nonzero, nothing staged" {
  _write_conf "claude:opus" 4 15
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-call8.jsonl"
  export LEDGER_FILE="$BATS_TEST_TMPDIR/call8-ledger.md"
  printf '%s\n' "$BATS_TEST_TMPDIR/a.txt" > "$BATS_TEST_TMPDIR/filelist8"

  run timeout 25 "$RUNSH" call claude "tidy these" --files "$BATS_TEST_TMPDIR/filelist8" --id c8
  [ "$status" -ne 0 ]
  [ -z "$(find "$BUS" -name '*.prompt' 2>/dev/null)" ]
}

@test "call: an id whose prefix already has a bus footprint is refused — nonzero, nothing staged" {
  _write_conf "claude:opus" 4 15
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-call9.jsonl"
  export LEDGER_FILE="$BATS_TEST_TMPDIR/call9-ledger.md"
  mkdir -p "$BUS/done"
  printf '{"id":"x1","code":0,"lane":"claude"}\n' > "$BUS/done/x1"

  run timeout 25 "$RUNSH" call glm "p" --id x1
  [ "$status" -ne 0 ]
  [ -z "$(find "$BUS" -name '*.prompt' 2>/dev/null)" ]
  # the pre-existing footprint is untouched, and no second card was ever born
  [ "$(find "$BUS/done" -maxdepth 1 -type f | wc -l)" -eq 1 ]
}

@test "call: an unreadable ENV_MASTER_FILE aborts an env-key lane before any spawn" {
  _write_conf "claude:opus" 4 15
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-call10.jsonl"
  export LEDGER_FILE="$BATS_TEST_TMPDIR/call10-ledger.md"
  export ENV_MASTER_FILE="$BATS_TEST_TMPDIR/nonexistent/env.master"

  run timeout 25 "$RUNSH" call kimi "x" --id c10
  [ "$status" -ne 0 ]
  # preflight fires before the pool: nothing was ever claimed or spawned
  [ -z "$(find "$BUS" -maxdepth 1 -name 'run-*.jsonl' 2>/dev/null)" ]
  [ -z "$(find "$BUS/claimed" -maxdepth 1 -type f 2>/dev/null)" ]
  [ ! -e "$BUS/done/c10" ]
}

@test "call: default BUSDIR (.bus-call-<label>) with a non-empty done/ is refused, nothing staged" {
  _write_conf "claude:opus" 4 15
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-call11.jsonl"
  export LEDGER_FILE="$BATS_TEST_TMPDIR/call11-ledger.md"
  unset BUSDIR
  cd "$BATS_TEST_TMPDIR"
  mkdir -p .bus-call-dflt/done
  printf '{"id":"old","code":0,"lane":"claude"}\n' > .bus-call-dflt/done/old

  run timeout 25 "$RUNSH" call claude "p" --id dflt
  [ "$status" -ne 0 ]
  [ -z "$(find .bus-call-dflt -name '*.prompt' 2>/dev/null)" ]
}

# --- spec 15 review fixes: parse-time guards found by the codex cross-model review ---------------

@test "call: a model with a slash or whitespace is refused before staging (claim filenames embed it)" {
  _write_conf "claude:opus" 4 15
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-call12.jsonl"
  export LEDGER_FILE="$BATS_TEST_TMPDIR/call12-ledger.md"

  run timeout 25 "$RUNSH" call glm:a/b "x" --id c12
  [ "$status" -ne 0 ]
  [ -z "$(find "$BUS" -name '*.prompt' 2>/dev/null)" ]

  run timeout 25 "$RUNSH" call glm "x" --chain "codex:bad model" --id c12b
  [ "$status" -ne 0 ]
  [ -z "$(find "$BUS" -name '*.prompt' 2>/dev/null)" ]
}

@test "call: --batch without --files is a usage error — they are a pair" {
  _write_conf "claude:opus" 4 15
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-call13.jsonl"
  export LEDGER_FILE="$BATS_TEST_TMPDIR/call13-ledger.md"

  run timeout 25 "$RUNSH" call claude "x" --batch 3 --id c13
  [ "$status" -ne 0 ]
  [ -z "$(find "$BUS" -name '*.prompt' 2>/dev/null)" ]
}

@test "call: a bulk list that climbs out of the --write root is refused before staging" {
  _write_conf "claude:opus" 4 15
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-call14.jsonl"
  export LEDGER_FILE="$BATS_TEST_TMPDIR/call14-ledger.md"
  local target="$BATS_TEST_TMPDIR/fence-target"
  mkdir -p "$target"
  printf '%s\n' "good.txt" "../outside.txt" > "$BATS_TEST_TMPDIR/filelist14"

  run timeout 25 "$RUNSH" call claude "tidy" --files "$BATS_TEST_TMPDIR/filelist14" --batch 2 \
      --write "$target" --id c14
  [ "$status" -ne 0 ]
  [ -z "$(find "$BUS" -name '*.prompt' 2>/dev/null)" ]

  # absolute path outside the root — same fence, same refusal
  printf '%s\n' "$BATS_TEST_TMPDIR/elsewhere.txt" > "$BATS_TEST_TMPDIR/filelist14b"
  run timeout 25 "$RUNSH" call claude "tidy" --files "$BATS_TEST_TMPDIR/filelist14b" --batch 2 \
      --write "$target" --id c14b
  [ "$status" -ne 0 ]
  [ -z "$(find "$BUS" -name '*.prompt' 2>/dev/null)" ]

  # a live pool marker refuses staging outright (run.pgid liveness guard). Must be a REAL process
  # group id — the guard probes `kill -0 -- -pgid`, and a bare pid that isn't a group leader is
  # (correctly) treated as a dead pool. Our own test process's group is guaranteed alive.
  mkdir -p "$BUS"
  ps -o pgid= -p $$ | tr -d ' ' > "$BUS/run.pgid"
  run timeout 25 "$RUNSH" call claude "x" --id c14c
  [ "$status" -ne 0 ]
  rm -f "$BUS/run.pgid"
}

# --- plan 004 P2: close-out lane summary + bus archive -------------------------------------------

@test "P2-FR1: run close prints the three-line lane summary on stderr, after the ledger row" {
  _write_conf "claude:opus" 2 15
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/docs/ops/speedwars.jsonl"
  mkdir -p "$(dirname "$SPEEDWARS_FILE")"
  : > "$SPEEDWARS_FILE"
  _fake FAKE_CLAUDE_RESULT "p2 answer"
  _enqueue p2a "close-out summary check"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/p2a" ]
  # exactly three summary lines, each a headline metric across lanes, each with a denominator
  [ "$(grep -c '^swarm: lane ' <<<"$output")" = "3" ]
  [[ "$output" == *'swarm: lane $/verified-done'* ]]
  [[ "$output" == *'swarm: lane p95 wall'* ]]
  [[ "$output" == *'swarm: lane false-done rate'* ]]
  [[ "$output" == *"[vdone "*"cards, priced "*"att]"* ]]
  [[ "$output" == *"[n "*" att]"* ]]
  [[ "$output" == *"judged]"* ]]
  # the ledger row it folds is already on disk when it prints
  [ "$(jq -r 'select(.type=="run-summary") | .mode' "$SPEEDWARS_FILE")" = "full" ]
}

@test "P2: run close archives the raw bus evidence under docs/ops/bus-archives/<run>/" {
  _write_conf "claude:opus" 2 15
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/docs/ops/speedwars.jsonl"
  mkdir -p "$(dirname "$SPEEDWARS_FILE")"
  : > "$SPEEDWARS_FILE"
  export SPEEDWARS_RUN=p2arch
  _fake FAKE_CLAUDE_RESULT "p2 archived answer"
  _enqueue p2b "archive check"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  local d="$BATS_TEST_TMPDIR/docs/ops/bus-archives/p2arch" ext=gz
  command -v zstd >/dev/null 2>&1 && ext=zst
  [ -d "$d" ]
  [ -f "$d/run-p2b.jsonl.$ext" ]
  [ -f "$d/res-p2b.txt.$ext" ]
  [ -f "$d/markers.tar.$ext" ]
  [ -f "$d/speedwars.jsonl.$ext" ]
  [ -f "$d/MANIFEST.txt" ]
  grep -q "^run: p2arch" "$d/MANIFEST.txt"
}

@test "P2: an unwritable archive root does not fail the run (evidence is best-effort)" {
  _write_conf "claude:opus" 2 15
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/docs/ops/speedwars.jsonl"
  mkdir -p "$BATS_TEST_TMPDIR/docs/ops/bus-archives"
  : > "$SPEEDWARS_FILE"
  export SPEEDWARS_RUN=p2ro
  chmod 500 "$BATS_TEST_TMPDIR/docs/ops/bus-archives"
  _fake FAKE_CLAUDE_RESULT "p2 answer"
  _enqueue p2c "archive failure check"

  run timeout 20 "$RUNSH"
  chmod 700 "$BATS_TEST_TMPDIR/docs/ops/bus-archives"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/p2c" ]
  [ ! -d "$BATS_TEST_TMPDIR/docs/ops/bus-archives/p2ro" ]
  # the summary still printed — one best-effort step failing must not silence the others
  [ "$(grep -c '^swarm: lane ' <<<"$output")" = "3" ]
}

@test "P2: SPEEDWARS_AUTO=0 suppresses both the lane summary and the archive" {
  _write_conf "claude:opus" 2 15
  mkdir -p "$BATS_TEST_TMPDIR/docs/ops"
  _fake FAKE_CLAUDE_RESULT "p2 answer"
  _enqueue p2d "auto-off check"

  SPEEDWARS_AUTO=0 SPEEDWARS_FILE="$BATS_TEST_TMPDIR/docs/ops/speedwars.jsonl" \
    run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^swarm: lane ' <<<"$output" || true)" = "0" ]
  [ ! -d "$BATS_TEST_TMPDIR/docs/ops/bus-archives" ]
}

# --- spec 10 FR-R15 (amendment 2026-07-26): bare sidecar tokens resolve at dispatch -------------

@test "spec10 FR-R15: bare .lane pin 'glm' resolves to glm:glm-5.2 at dispatch — worker env gets the real model, loud stderr names the resolution" {
  # Backlog 62 root cause: a bare token reaches lane_cmd, ${lanemodel#*:} degenerates to the lane
  # name, and Z.ai answers 400 [1211] Unknown Model. After FR-R15 the dispatch choke point
  # (_try_claim_one) normalizes via _call_lane_token BEFORE claim, so the worker env carries the
  # canonical model and the claim filename keeps _claim_meta parseable.
  _write_conf "claude:opus" 1 15
  printf 'Z_AI_CODING_KEY=test-glm-key\n' > "$BATS_TEST_TMPDIR/envmaster"
  export ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster"
  _fake FAKE_CLAUDE_DUMP_ENV "$BATS_TEST_TMPDIR/bare-glm.env"
  _fake FAKE_CLAUDE_RESULT "served on resolved glm"
  _enqueue bt1 "bare glm pin"
  mkdir -p "$BUS/queue"
  printf 'glm' > "$BUS/queue/bt1.lane"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/bt1" ]
  [ "$(jq -r '.lane' "$BUS/done/bt1")" = "glm" ]
  grep -q "^ANTHROPIC_DEFAULT_SONNET_MODEL=glm-5.2$" "$BATS_TEST_TMPDIR/bare-glm.env"
  # loud, exactly-once resolution line naming id, bare token, and resolved pair
  [[ "$output" == *"bt1"*"bare"*"glm:glm-5.2"* ]]
}

@test "spec10 FR-R15: bare .chain head 'kimi' resolves to kimi:kimi-k3 — never token-as-model" {
  _write_conf "claude:opus" 1 15
  printf 'MOONSHOT_API_KEY=test-kimi-key\nZ_AI_CODING_KEY=test-glm-key\n' > "$BATS_TEST_TMPDIR/envmaster"
  export ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster"
  _fake FAKE_CLAUDE_DUMP_ENV "$BATS_TEST_TMPDIR/bare-kimi.env"
  _fake FAKE_CLAUDE_RESULT "served on resolved kimi"
  _enqueue bt2 "bare kimi chain head"
  mkdir -p "$BUS/queue"
  printf 'kimi' > "$BUS/queue/bt2.chain"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/bt2" ]
  grep -q "^ANTHROPIC_DEFAULT_SONNET_MODEL=kimi-k3$" "$BATS_TEST_TMPDIR/bare-kimi.env"
  grep -vq "^ANTHROPIC_DEFAULT_SONNET_MODEL=kimi$" "$BATS_TEST_TMPDIR/bare-kimi.env"
  [[ "$output" == *"bt2"*"bare"*"kimi:kimi-k3"* ]]
}

@test "spec10 FR-R15: a full lane:model pin passes through untouched — zero resolution chatter" {
  _write_conf "claude:opus" 1 15
  printf 'Z_AI_CODING_KEY=test-glm-key\n' > "$BATS_TEST_TMPDIR/envmaster"
  export ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster"
  _fake FAKE_CLAUDE_DUMP_ENV "$BATS_TEST_TMPDIR/full-pair.env"
  _fake FAKE_CLAUDE_RESULT "served on explicit pin"
  _enqueue bt3 "explicit pin"
  mkdir -p "$BUS/queue"
  printf 'glm:glm-4.7' > "$BUS/queue/bt3.lane"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/bt3" ]
  grep -q "^ANTHROPIC_DEFAULT_SONNET_MODEL=glm-4.7$" "$BATS_TEST_TMPDIR/full-pair.env"
  [[ "$output" != *"bare"* ]]
}

# --- spec 04 amendment 2026-07-26 (backlog 20): same-lane first-spawn stagger --------------------

@test "backlog-20: a run leaves the per-lane first-spawn marker — stagger is wired into _spawn_worker" {
  _write_conf "claude:opus" 4 15
  _fake FAKE_CLAUDE_RESULT "OK"
  _enqueue sg1 "stagger one"
  _enqueue sg2 "stagger two"

  run timeout 30 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/sg1" ]
  [ -f "$BUS/done/sg2" ]
  [ -d "$BUS/limits/.first-claude" ]
  # the marker records which worker went first, and it was one of this run's cards
  first="$(cat "$BUS/limits/.first-claude/id")"
  [[ "$first" == sg1 || "$first" == sg2 ]]
}


# --- spec 13 FR-6 (backlog 58): event-fired auto live-probes -------------------------------------

@test "spec13 FR-6: pre-claim probe FAIL marks the lane .broken before any spawn — card fails over without burning retries" {
  cat > "$CONF" <<CONFEOF
EXEC_CHAIN="glm:glm-5.2 claude:opus"
FANOUT=2
LEASE_MIN=15
CONFEOF
  export PROBE_AUTO=1
  export FAKE_CURL_HTTP_CODE=401
  export LEDGER_FILE="$BATS_TEST_TMPDIR/fr6-ledger.md"
  _fake FAKE_CLAUDE_RESULT "OK"
  _enqueue pb1 "probe route-around"

  run timeout 40 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/pb1" ]
  grep -q '"lane":"claude"' "$BUS/done/pb1"
  [ -f "$BUS/limits/glm.broken" ]
  grep -q '^FAIL pre-claim' "$BUS/limits/.probed-glm"
  [[ "$output" == *"failed its pre-claim live probe"* ]]
  grep -q "doctor-probe (glm)" "$LEDGER_FILE"
}

@test "spec13 FR-6: exactly one probe per lane per run — three cards, one probe invocation" {
  cat > "$CONF" <<CONFEOF
EXEC_CHAIN="claude:opus"
FANOUT=2
LEASE_MIN=15
CONFEOF
  export PROBE_AUTO=1
  export LEDGER_FILE="$BATS_TEST_TMPDIR/fr6-ledger2.md"
  _fake FAKE_CLAUDE_RESULT "OK"
  _fake FAKE_CLAUDE_ARGV_FILE "$BATS_TEST_TMPDIR/fr6-argv"
  _enqueue m1 "one"
  _enqueue m2 "two"
  _enqueue m3 "three"

  run timeout 40 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/m1" ]
  [ -f "$BUS/done/m2" ]
  [ -f "$BUS/done/m3" ]
  grep -q '^PASS pre-claim' "$BUS/limits/.probed-claude"
  # 3 worker invocations + exactly 1 probe invocation = 4 fake-claude calls
  [ "$(wc -l < "$BATS_TEST_TMPDIR/fr6-argv")" -eq 4 ]
}

@test "spec13 FR-6: PROBE_AUTO=0 disables auto probes entirely — no marker written" {
  _write_conf "claude:opus" 2 15
  _fake FAKE_CLAUDE_RESULT "OK"
  _enqueue off1 "no probe"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/off1" ]
  [ ! -e "$BUS/limits/.probed-claude" ]
}

@test "spec13 FR-6 criterion 2+4: a healthy pre-claim outcome suppresses the reactive probe — marker never rewritten by a later instant-error" {
  cat > "$CONF" <<CONFEOF
EXEC_CHAIN="glm:glm-5.2 claude:opus"
FANOUT=2
LEASE_MIN=15
CONFEOF
  export PROBE_AUTO=1
  export LEDGER_FILE="$BATS_TEST_TMPDIR/fr6-ledger3.md"
  # glm's pre-claim probe goes over fake curl (healthy 200 -> PASS marker); the glm WORKER rides
  # the fake claude binary, whose first invocation serves the auth-death text shape (instant-error
  # class at finalize) — the reactive arm fires, sees the PASS marker, and must not rewrite it.
  _fake FAKE_CLAUDE_RESULT "OK"
  _fake FAKE_CLAUDE_ONCE_MARKER "$BATS_TEST_TMPDIR/fr6-once"
  _fake FAKE_CLAUDE_ONCE_MODE "autherr"
  _enqueue sup1 "reactive suppression"

  run timeout 40 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/sup1" ]
  grep -q '^PASS pre-claim' "$BUS/limits/.probed-glm"
  [[ "$(<"$BUS/limits/.probed-glm")" != *reactive* ]]
  # exactly one glm probe ledger row — the reactive event added none
  [ "$(grep -c 'doctor-probe (glm)' "$LEDGER_FILE")" -eq 1 ]
}

# --- spec 14 FR-8 (backlog 59): per-card write-journal in shared cages ---------------------------

@test "spec14 FR-8: shared cage — the journal-owning writer passes the gate, the narration-only sibling fails with the W3D1 signature" {
  # Both cards target ONE cage, concurrently live (FANOUT=2). The once-mode makes exactly one
  # worker a real writer (file + Write tool_use record); the other narrates and writes nothing.
  # Pre-FR-8 the narrator finalized done on the WRITER's bytes (the W3D1 blind spot); now its own
  # empty journal fails the gate and it parks after retries.
  _write_conf "claude:opus" 2 15
  local cage="$BATS_TEST_TMPDIR/sharedcage"
  mkdir -p "$cage"
  _fake FAKE_CLAUDE_RESULT "narrated a great success, wrote nothing"
  _fake FAKE_CLAUDE_ONCE_MARKER "$BATS_TEST_TMPDIR/j-once"
  _fake FAKE_CLAUDE_ONCE_MODE "journalwrite"
  _fake FAKE_CLAUDE_WRITE_FILE "made.txt"
  _enqueue wa "shared-cage card A"
  printf '%s' "$cage" > "$BUS/specs/wa.write"
  _enqueue wb "shared-cage card B"
  printf '%s' "$cage" > "$BUS/specs/wb.write"

  run timeout 40 "$RUNSH"
  # exactly ONE of the two finalizes done (the writer — once-mode picks whichever spawned first);
  # the other parks after its retries, never credited with the sibling's bytes
  local done_n parked_n
  done_n=$(ls "$BUS/done" 2>/dev/null | wc -l)
  [ "$done_n" -eq 1 ]
  [ -f "$cage/made.txt" ]
  [[ -f "$BUS/limits/wa.parked" || -f "$BUS/limits/wb.parked" ]]
  [[ "$output" == *"W3D1"* ]]
}

@test "spec14 FR-8: a SOLE unmanifested write card keeps the whole-cage sweep — no journal required (out-of-scope guard)" {
  _write_conf "claude:opus" 2 15
  local cage="$BATS_TEST_TMPDIR/solecage"
  mkdir -p "$cage"
  # writes a real file but emits NO tool_use records (the legacy fake write path) — a single-card
  # cage must still pass on bytes alone, exactly as before FR-8
  _fake FAKE_CLAUDE_RESULT "did the work"
  _fake FAKE_CLAUDE_WRITE_FILE "solo.txt"
  _enqueue solo1 "sole write card"
  printf '%s' "$cage" > "$BUS/specs/solo1.write"

  run timeout 25 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/solo1" ]
  [ -f "$cage/solo.txt" ]
  [[ "$output" != *"W3D1"* ]]
}

# --- spec14 FR-8 non-journal lanes (2026-07-29): grok/codex/gemini streams carry no tool_use
# journal at all (verified empirically 2026-07-28) — a shared cage with no queue/<id>.files
# manifest must reject outright, never silently trust a sibling's bytes. Mirrors the claude/glm/kimi
# journal fixtures just above, for the non-journal side of the same gate.

@test "spec14 FR-8 non-journal: grok-pinned write card sharing a cage with a finished sibling and no manifest is rejected — false-done, never done" {
  _write_conf "claude:opus" 2 15
  cat >> "$CONF" <<'EOF2'
MAX_LANE_RETRIES=1
EOF2
  local cage="$BATS_TEST_TMPDIR/grok-shared-cage"
  mkdir -p "$cage" "$BUS"
  # finished-sibling archive (what _archive_and_release drops at success) naming the same cage
  printf '%s' "$cage" > "$BUS/write-sib.txt"
  _fake FAKE_GROK_RESULT "grok really wrote it"
  _fake FAKE_GROK_WRITE_FILE "grokmade.txt"
  _enqueue gw1 "grok-pinned write card, shared cage, no manifest"
  echo "grok:default" > "$BUS/specs/gw1.lane"
  printf '%s' "$cage" > "$BUS/specs/gw1.write"

  run timeout 30 "$RUNSH"
  [ "$status" -ne 0 ]
  [ ! -f "$BUS/done/gw1" ]
  [ -f "$cage/grokmade.txt" ]      # grok genuinely wrote — rejected anyway, absent a manifest
  [ -f "$BUS/limits/gw1.parked" ]
  [[ "$output" == *"files manifest"* ]]
}

@test "spec14 FR-8 non-journal: the same shared-cage fixture with a valid .files manifest naming grok's own output lets the card finish done" {
  _write_conf "claude:opus" 2 15
  local cage="$BATS_TEST_TMPDIR/grok-shared-cage-ok"
  mkdir -p "$cage" "$BUS"
  printf '%s' "$cage" > "$BUS/write-sib.txt"
  _fake FAKE_GROK_RESULT "grok wrote it, and this time it's provable"
  _fake FAKE_GROK_WRITE_FILE "grokmade.txt"
  _enqueue gw2 "grok-pinned write card, shared cage, WITH manifest"
  echo "grok:default" > "$BUS/specs/gw2.lane"
  printf '%s' "$cage" > "$BUS/specs/gw2.write"
  printf 'grokmade.txt\n' > "$BUS/specs/gw2.files"

  run timeout 30 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/gw2" ]
  [ -f "$cage/grokmade.txt" ]
}

@test "spec14 FR-8 non-journal: a sole grok write card in an unshared cage finishes done with no manifest — whole-cage sweep regression guard" {
  _write_conf "claude:opus" 2 15
  local cage="$BATS_TEST_TMPDIR/grok-solo-cage"
  mkdir -p "$cage"
  _fake FAKE_GROK_RESULT "grok did the work, alone"
  _fake FAKE_GROK_WRITE_FILE "grokmade.txt"
  _enqueue gw3 "sole grok write card, unshared cage"
  echo "grok:default" > "$BUS/specs/gw3.lane"
  printf '%s' "$cage" > "$BUS/specs/gw3.write"

  run timeout 30 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/gw3" ]
  [ -f "$cage/grokmade.txt" ]
}

# --- spec 20 (backlog 11/21): per-run bus namespacing via --run ----------------------------------

@test "spec20 FR-1: --run derives BUSDIR=.bus-<label> and the run label, atomically" {
  _write_conf "claude:opus" 2 15
  _fake FAKE_CLAUDE_RESULT "OK"
  export UNIMATRIX_BUS_ROOT="$BATS_TEST_TMPDIR"
  mkdir -p "$BATS_TEST_TMPDIR/.bus-alpha/specs"
  printf '%s' "namespaced card" > "$BATS_TEST_TMPDIR/.bus-alpha/specs/na1.prompt"

  run env -u BUSDIR -u SPEEDWARS_RUN timeout 30 "$RUNSH" --run alpha ""
  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/.bus-alpha/done/na1" ]
  [ "$(<"$BATS_TEST_TMPDIR/.bus-alpha/.run-label")" = "alpha" ]
}

@test "spec20 FR-1 precedence: explicit BUSDIR env beats the --run derivation" {
  _write_conf "claude:opus" 2 15
  _fake FAKE_CLAUDE_RESULT "OK"
  export UNIMATRIX_BUS_ROOT="$BATS_TEST_TMPDIR"
  _enqueue pv1 "env wins"

  run timeout 30 "$RUNSH" --run beta ""
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/pv1" ]
  [ ! -d "$BATS_TEST_TMPDIR/.bus-beta" ]
}

@test "spec20 FR-1: an invalid --run label (path characters) is refused at parse time" {
  run "$RUNSH" --run "../evil" ""
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid --run label"* ]]
}

@test "spec20 FR-3: a LIVE heartbeat refuses the run loudly; UNIMATRIX_BUS_OWNER=1 (loop child) bypasses" {
  _write_conf "claude:opus" 2 15
  _fake FAKE_CLAUDE_RESULT "OK"
  mkdir -p "$BUS"
  touch "$BUS/heartbeat"
  _enqueue hb1 "collision card"

  run timeout 20 "$RUNSH" ""
  [ "$status" -ne 0 ]
  [[ "$output" == *"LIVE"* ]]
  [ ! -e "$BUS/done/hb1" ]

  run env UNIMATRIX_BUS_OWNER=1 timeout 30 "$RUNSH" ""
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/hb1" ]
}

@test "spec20 FR-3: a STALE heartbeat (>60s) resumes the bus silently" {
  _write_conf "claude:opus" 2 15
  _fake FAKE_CLAUDE_RESULT "OK"
  mkdir -p "$BUS"
  touch -d '-2 minutes' "$BUS/heartbeat"
  _enqueue hb2 "resume card"

  run timeout 30 "$RUNSH" ""
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/hb2" ]
}

@test "spec20 FR-9: usage text documents the --run flag" {
  run "$RUNSH" --plan-only
  [[ "$output" == *"--run <label>"* ]]
}

# --- spec 20 amendment 2026-07-29 (gtm-owners3): _refuse_empty_run — a bus with zero queued/
# claimed/done cards after enqueue is a mis-derivation/mis-seeding trap, never intent -----------

@test "spec20 amendment 2026-07-29: an empty bus (nothing queued/claimed/done) aborts nonzero naming the busdir" {
  _write_conf "claude:opus" 4 15

  run timeout 20 "$RUNSH" ""
  [ "$status" -ne 0 ]
  [[ "$output" == *"nothing to run"* ]]
  [[ "$output" == *"$BUS"* ]]
}

@test "spec20 amendment 2026-07-29: a bus resumed with only done/ entries (empty queue) still closes clean, no false empty-run abort" {
  _write_conf "claude:opus" 4 15
  mkdir -p "$BUS/done"
  printf '{"id":"already","code":0,"lane":"claude"}\n' > "$BUS/done/already"

  run timeout 20 "$RUNSH" ""
  [ "$status" -eq 0 ]
  [[ "$output" != *"nothing to run"* ]]
}

@test "spec20 amendment 2026-07-29: verify on an empty bus (no done/ entries) aborts nonzero naming the trap" {
  _write_conf "claude:opus" 4 15

  run timeout 20 "$RUNSH" verify
  [ "$status" -ne 0 ]
  [[ "$output" == *"nothing to run"* ]]
}

@test "spec20 FR-1 amendment 2026-07-29: --run derives BUSDIR at the CALLER's cwd — the empty-run abort proves both the derivation and the trap message" {
  _write_conf "claude:opus" 4 15
  local scratch="$BATS_TEST_TMPDIR/cwd-scratch"
  mkdir -p "$scratch"

  run timeout 20 env -u BUSDIR -u UNIMATRIX_BUS_ROOT bash -c "cd '$scratch' && exec '$RUNSH' --run cwdtest ''"
  [ "$status" -ne 0 ]
  [[ "$output" == *"nothing to run"* ]]
  [[ "$output" == *"$scratch/.bus-cwdtest"* ]]
}
