#!/usr/bin/env bats
# RED-wave tests for the NEW POST /api/ctl control surface (specs/07-cockpit-redesign.md §4.5 /
# PLAN.md §4.5–§4.8). The endpoint does not exist yet — site/server.mjs currently falls through to
# the `/api/` catch-all (404) for it — so EVERY test in this file is expected to FAIL until the
# GREEN wave adds the route. Once implemented, /api/ctl shells out to src/swarm-ctl over a fixed
# argv table (literal execFile, never a shell) with the same Host/Origin/body guards as /api/config.
#
# Project: unimatrix — multi-model swarm orchestrator driven from Claude Code
# Module:  tests/cockpit-ctl.bats
# Deps:    bats-core, site/server.mjs (node), src/swarm-lib.sh (bus_init), curl, jq, coreutils
# Tested:  n/a — this is the test file
#
# Key responsibilities:
# - RED coverage of the full /api/ctl verb table: pause/resume, cancel, kill (+cancel), nudge,
#   pause-worker/resume-worker, add (+lane/write), abort — plus every guard (Host/Origin, verb
#   allowlist incl. prototype-key, ID_RE, body cap, method, confirm-gate).
#
# Design constraints:
# - Fixture-only: throwaway bus (bus_init) + fixture swarm.conf COPY under $BATS_TEST_TMPDIR on an
#   ephemeral _free_port — never the real .bus, real swarm.conf, or port 4747. Kill/pause-worker
#   tests spawn a real marker sleep (copied from tests/swarm-ctl.bats' pattern) and the per-test
#   teardown reaps it so a failing (RED) test never leaks a process.
# - _free_port/_start_server are COPIED from tests/ground-control.bats (bats shares no helpers
#   between files); the marker-sleep pid pattern is COPIED from tests/swarm-ctl.bats.

REPO="$BATS_TEST_DIRNAME/.."
LIB="$REPO/src/swarm-lib.sh"
SERVER_JS="$REPO/site/server.mjs"

setup() {
  # shellcheck source=/dev/null
  source "$LIB"

  BUS="$BATS_TEST_TMPDIR/bus"
  bus_init "$BUS"   # specs/ queue/ claimed/ done/ cancelled/ limits/ pids/

  # fixture swarm.conf: a COPY of the real one so no test ever touches the repo's own. EXEC_CHAIN is
  # re-pinned post-copy (a live swarm can be running against the repo conf and would otherwise make
  # exact-value assertions flaky) — mirrors tests/ground-control.bats.
  CONF="$BATS_TEST_TMPDIR/swarm.conf"
  cp "$REPO/swarm.conf" "$CONF"
  sed -i "s|^EXEC_CHAIN=.*|EXEC_CHAIN=\"grok:grok-4.5 glm:glm-5.2 claude:haiku\"  # fixture: re-pinned post-copy to dodge live-conf flake|" "$CONF"

  SERVER_PID=""
}

teardown() {
  if [ -n "${SERVER_PID:-}" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  # kill/pause-worker tests background a real marker sleep — reap any a failing (RED) test leaves.
  pkill -9 -f "cockpit-ctl-marker" 2>/dev/null || true
  return 0
}

# _free_port — ephemeral port from this shell's pid + the bats test number, never the real cockpit's
# 4747 (copied verbatim from tests/ground-control.bats).
_free_port() {
  echo $(( 20000 + ( ($$ + ${BATS_TEST_NUMBER:-0} * 97) % 9000 ) ))
}

# _start_server — boots site/server.mjs against the fixture bus + fixture conf on a free port,
# polling /health up to 5s. Sets $PORT and $SERVER_PID; teardown() kills $SERVER_PID. (Copied
# verbatim from tests/ground-control.bats.)
_start_server() {
  PORT="$(_free_port)"
  BUSDIR="$BUS" PORT="$PORT" SWARM_CONF="$CONF" node "$SERVER_JS" >/dev/null 2>&1 &
  SERVER_PID=$!

  local tries=0
  until curl -fsS --max-time 1 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; do
    tries=$(( tries + 1 ))
    if [ "$tries" -ge 50 ]; then
      echo "server.mjs did not become healthy within 5s" >&2
      return 1
    fi
    sleep 0.1
  done
}

# --- guards: Origin / verb / id / body / method ---------------------------------------------

@test "api-ctl: foreign Origin (http://evil.example) is rejected with 403 and leaves the bus untouched" {
  echo "task" > "$BUS/queue/keep.prompt"
  _start_server
  local before="$BATS_TEST_TMPDIR/before.tree" after="$BATS_TEST_TMPDIR/after.tree"
  find "$BUS" -exec stat -c '%n %Y %i %s' {} \; | sort > "$before"

  run curl -s -o "$BATS_TEST_TMPDIR/o.out" -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' -H 'Origin: http://evil.example' \
    -d '{"verb":"pause"}' "http://127.0.0.1:$PORT/api/ctl"
  [ "$output" = "403" ]
  # the verb never ran — no PAUSE flag, and the queue file is intact
  [ ! -e "$BUS/PAUSE" ]
  [ -f "$BUS/queue/keep.prompt" ]
  find "$BUS" -exec stat -c '%n %Y %i %s' {} \; | sort > "$after"
  run diff "$before" "$after"
  [ "$status" -eq 0 ]
}

@test "api-ctl: unknown verb is rejected with 400, and a prototype-key verb (__proto__) too" {
  _start_server
  run curl -s -o "$BATS_TEST_TMPDIR/v1.out" -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' \
    -d '{"verb":"frobnicate"}' "http://127.0.0.1:$PORT/api/ctl"
  [ "$output" = "400" ]
  # __proto__ must NOT resolve to Object.prototype via the verb lookup (Object.hasOwn guard)
  run curl -s -o "$BATS_TEST_TMPDIR/v2.out" -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' \
    -d '{"verb":"__proto__"}' "http://127.0.0.1:$PORT/api/ctl"
  [ "$output" = "400" ]
}

@test "api-ctl: malformed id (../x) is rejected with 400 without invoking swarm-ctl" {
  echo "task" > "$BUS/queue/keep.prompt"
  _start_server
  run curl -s -o "$BATS_TEST_TMPDIR/mid.out" -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' \
    -d '{"verb":"cancel","id":"../x"}' "http://127.0.0.1:$PORT/api/ctl"
  [ "$output" = "400" ]
  # no traversal up from the bus — no cancelled/x.prompt, and the seeded queue file is untouched
  [ ! -e "$BUS/cancelled/x.prompt" ]
  [ -e "$BUS/queue/keep.prompt" ]
}

@test "api-ctl: oversized body (>64KiB) is rejected with 400" {
  _start_server
  local big="$BATS_TEST_TMPDIR/big.json"
  # 70000 'x' chars in the prompt field -> a ~70KiB body, well over the 64KiB cap
  { printf '{"verb":"add","id":"big1","prompt":"'; head -c 70000 /dev/zero | tr '\0' 'x'; printf '"}'; } > "$big"
  run curl -s -o "$BATS_TEST_TMPDIR/big.out" -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' --data-binary @"$big" \
    "http://127.0.0.1:$PORT/api/ctl"
  [ "$output" = "400" ]
  [ ! -f "$BUS/queue/big1.prompt" ]
}

@test "api-ctl: GET /api/ctl is rejected with 405 (POST-only)" {
  _start_server
  run curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/api/ctl"
  [ "$output" = "405" ]
}

# --- verbs: pause / resume -------------------------------------------------------------------

@test "api-ctl: pause creates .bus/PAUSE and resume removes it" {
  _start_server
  run curl -s -o "$BATS_TEST_TMPDIR/p.out" -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' \
    -d '{"verb":"pause"}' "http://127.0.0.1:$PORT/api/ctl"
  [ "$output" = "200" ]
  [ -e "$BUS/PAUSE" ]

  run curl -s -o "$BATS_TEST_TMPDIR/r.out" -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' \
    -d '{"verb":"resume"}' "http://127.0.0.1:$PORT/api/ctl"
  [ "$output" = "200" ]
  [ ! -e "$BUS/PAUSE" ]
}

# --- verbs: cancel ---------------------------------------------------------------------------

@test "api-ctl: cancel moves a queued id's prompt to cancelled/" {
  _start_server
  echo "task-q7" > "$BUS/queue/c7.prompt"
  run curl -s -o "$BATS_TEST_TMPDIR/c7.out" -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' \
    -d '{"verb":"cancel","id":"c7"}' "http://127.0.0.1:$PORT/api/ctl"
  [ "$output" = "200" ]
  [ -f "$BUS/cancelled/c7.prompt" ]
  [ ! -f "$BUS/queue/c7.prompt" ]
  [ "$(cat "$BUS/cancelled/c7.prompt")" = "task-q7" ]
}

@test "api-ctl: cancel of an unknown id returns 409 with stderr in the body" {
  _start_server
  run curl -s -o "$BATS_TEST_TMPDIR/u8.out" -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' \
    -d '{"verb":"cancel","id":"nope8"}' "http://127.0.0.1:$PORT/api/ctl"
  [ "$output" = "409" ]
  [ "$(jq -r '.ok' "$BATS_TEST_TMPDIR/u8.out")" = "false" ]
  # swarm-ctl cancel echoes the id in its stderr; the 409 body carries that stderr verbatim
  [[ "$(jq -r '.stderr' "$BATS_TEST_TMPDIR/u8.out")" == *"nope8"* ]]
}

# --- verbs: kill ---------------------------------------------------------------------------

@test "api-ctl: kill terminates the recorded worker and requeues its claim to queue/" {
  _start_server
  echo "task-k9" > "$BUS/claimed/k9.claude:opus"
  ( exec -a cockpit-ctl-marker sleep 9999 ) 3>&- &
  local wpid=$!
  echo "$wpid" > "$BUS/pids/k9"

  run curl -s -o "$BATS_TEST_TMPDIR/k9.out" -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' \
    -d '{"verb":"kill","id":"k9"}' "http://127.0.0.1:$PORT/api/ctl"
  [ "$output" = "200" ]
  [ -f "$BUS/queue/k9.prompt" ]
  [ ! -f "$BUS/claimed/k9.claude:opus" ]
  [ ! -f "$BUS/pids/k9" ]
  for _ in $(seq 1 20); do kill -0 "$wpid" 2>/dev/null || break; sleep 0.1; done
  run kill -0 "$wpid"
  [ "$status" -ne 0 ]
}

@test "api-ctl: kill with cancel:true cancels the claim instead of requeuing" {
  _start_server
  echo "task-k10" > "$BUS/claimed/k10.glm:glm-5.2"
  ( exec -a cockpit-ctl-marker sleep 9999 ) 3>&- &
  local wpid=$!
  echo "$wpid" > "$BUS/pids/k10"

  run curl -s -o "$BATS_TEST_TMPDIR/k10.out" -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' \
    -d '{"verb":"kill","id":"k10","cancel":true}' "http://127.0.0.1:$PORT/api/ctl"
  [ "$output" = "200" ]
  [ -f "$BUS/cancelled/k10.prompt" ]
  [ ! -f "$BUS/queue/k10.prompt" ]
  [ ! -f "$BUS/claimed/k10.glm:glm-5.2" ]
  for _ in $(seq 1 20); do kill -0 "$wpid" 2>/dev/null || break; sleep 0.1; done
  run kill -0 "$wpid"
  [ "$status" -ne 0 ]
}

@test "api-ctl: kill with cancel:\"yes\" (string) returns 400" {
  # regression: cancel present but non-boolean used to be treated as silent false (no --cancel,
  # no error). Refuse with 400 so the client cannot believe a cancel was applied.
  _start_server
  echo "task-kstr" > "$BUS/claimed/kstr.claude:opus"

  run curl -s -o "$BATS_TEST_TMPDIR/kstr.out" -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' \
    -d '{"verb":"kill","id":"kstr","cancel":"yes"}' "http://127.0.0.1:$PORT/api/ctl"
  [ "$output" = "400" ]
  # verb never ran — claim still on the bus
  [ -f "$BUS/claimed/kstr.claude:opus" ]
  [ ! -f "$BUS/cancelled/kstr.prompt" ]
  [ ! -f "$BUS/queue/kstr.prompt" ]
}

# --- verbs: nudge ---------------------------------------------------------------------------

@test "api-ctl: nudge with a hint appends an OPERATOR HINT block to the requeued prompt" {
  _start_server
  printf 'original spec body\n' > "$BUS/claimed/n11.claude:sonnet"
  run curl -s -o "$BATS_TEST_TMPDIR/n11.out" -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' \
    -d '{"verb":"nudge","id":"n11","hint":"check the API timeout"}' "http://127.0.0.1:$PORT/api/ctl"
  [ "$output" = "200" ]
  [ -f "$BUS/queue/n11.prompt" ]
  [ ! -f "$BUS/claimed/n11.claude:sonnet" ]
  run cat "$BUS/queue/n11.prompt"
  [[ "$output" == *"OPERATOR HINT"* ]]
  [[ "$output" == *"check the API timeout"* ]]
  [[ "$output" == *"original spec body"* ]]
}

# --- audit.jsonl durable append (spec 12 FR-6 / acceptance 7) --------------------------------

@test "api-ctl: a ctl verb appends one line to BUSDIR/audit.jsonl with verb+status, never body values" {
  _start_server
  printf 'original spec body\n' > "$BUS/claimed/n20.claude:sonnet"
  run curl -s -o "$BATS_TEST_TMPDIR/n20.out" -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' \
    -d '{"verb":"nudge","id":"n20","hint":"check the API timeout"}' "http://127.0.0.1:$PORT/api/ctl"
  [ "$output" = "200" ]

  [ -f "$BUS/audit.jsonl" ]
  [ "$(wc -l < "$BUS/audit.jsonl")" -eq 1 ]
  run cat "$BUS/audit.jsonl"
  [[ "$output" == *'"verb":"nudge"'* ]]
  [[ "$output" == *'"status":200'* ]]
  # scrub by construction: request-body values (the hint text) never land in the audit line
  [[ "$output" != *"check the API timeout"* ]]
}

# --- verbs: add -----------------------------------------------------------------------------

@test "api-ctl: add {id,prompt} lands queue/<id>.prompt and round-trips the text" {
  _start_server
  run curl -s -o "$BATS_TEST_TMPDIR/a12.out" -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' \
    -d '{"verb":"add","id":"a12","prompt":"hello round trip"}' "http://127.0.0.1:$PORT/api/ctl"
  [ "$output" = "200" ]
  [ -f "$BUS/queue/a12.prompt" ]
  [ ! -f "$BUS/specs/a12.prompt" ]
  [ "$(cat "$BUS/queue/a12.prompt")" = "hello round trip" ]
}

@test "api-ctl: add of an id that already has bus footprint returns 409" {
  _start_server
  echo "already here" > "$BUS/queue/dup13.prompt"
  run curl -s -o "$BATS_TEST_TMPDIR/dup13.out" -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' \
    -d '{"verb":"add","id":"dup13","prompt":"overwrite attempt"}' "http://127.0.0.1:$PORT/api/ctl"
  [ "$output" = "409" ]
  [ "$(jq -r '.ok' "$BATS_TEST_TMPDIR/dup13.out")" = "false" ]
  # original prompt untouched — the add was refused before swarm-ctl ran
  [ "$(cat "$BUS/queue/dup13.prompt")" = "already here" ]
}

@test "api-ctl: add with a writable lane pin writes the .lane sidecar; gemini:default is refused (400)" {
  _start_server
  # grok is a writable lane -> sidecar lands alongside the prompt
  run curl -s -o "$BATS_TEST_TMPDIR/l14a.out" -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' \
    -d '{"verb":"add","id":"l14a","prompt":"p","lane":"grok:grok-4.5"}' "http://127.0.0.1:$PORT/api/ctl"
  [ "$output" = "200" ]
  [ -f "$BUS/queue/l14a.prompt" ]
  [ -f "$BUS/queue/l14a.lane" ]
  [ "$(cat "$BUS/queue/l14a.lane")" = "grok:grok-4.5" ]
  # gemini is read-only -> the pin is refused before swarm-ctl is invoked
  run curl -s -o "$BATS_TEST_TMPDIR/l14b.out" -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' \
    -d '{"verb":"add","id":"l14b","prompt":"p","lane":"gemini:default"}' "http://127.0.0.1:$PORT/api/ctl"
  [ "$output" = "400" ]
  [ ! -f "$BUS/queue/l14b.prompt" ]
}

@test "api-ctl: add with a write dir that does not exist is rejected (400)" {
  _start_server
  run curl -s -o "$BATS_TEST_TMPDIR/w15.out" -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' \
    -d '{"verb":"add","id":"w15","prompt":"p","write":"/no/such/dir/anywhere"}' "http://127.0.0.1:$PORT/api/ctl"
  [ "$output" = "400" ]
  [ ! -f "$BUS/queue/w15.prompt" ]
}

# --- verbs: abort ---------------------------------------------------------------------------

@test "api-ctl: abort without confirm:true is 400; abort with a stale run.pgid is 409" {
  _start_server
  # no confirm -> 400, never reaches swarm-ctl
  run curl -s -o "$BATS_TEST_TMPDIR/ab1.out" -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' \
    -d '{"verb":"abort"}' "http://127.0.0.1:$PORT/api/ctl"
  [ "$output" = "400" ]
  # a stale/bogus pgid names no live group -> swarm-ctl abort exits nonzero -> 409 w/ stderr
  echo "999999" > "$BUS/run.pgid"
  run curl -s -o "$BATS_TEST_TMPDIR/ab2.out" -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' \
    -d '{"verb":"abort","confirm":true}' "http://127.0.0.1:$PORT/api/ctl"
  [ "$output" = "409" ]
  [ "$(jq -r '.ok' "$BATS_TEST_TMPDIR/ab2.out")" = "false" ]
  local body; body="$(cat "$BATS_TEST_TMPDIR/ab2.out")"
  [[ "$body" == *"stale"* || "$body" == *"not running"* || "$body" == *"no live"* ]]
}

# --- verbs: pause-worker / resume-worker (SIGSTOP freeze — §4.6b) ---------------------------

@test "api-ctl: pause-worker SIGSTOP-freezes a worker (state T + frozen flag); resume-worker thaws it" {
  _start_server
  echo "task-pw" > "$BUS/claimed/pw17.claude:haiku"
  ( exec -a cockpit-ctl-marker sleep 9999 ) 3>&- &
  local wpid=$!
  echo "$wpid" > "$BUS/pids/pw17"

  run curl -s -o "$BATS_TEST_TMPDIR/pw.out" -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' \
    -d '{"verb":"pause-worker","id":"pw17"}' "http://127.0.0.1:$PORT/api/ctl"
  [ "$output" = "200" ]
  [ -f "$BUS/limits/pw17.frozen" ]
  # SIGSTOP -> process state is T (stopped); trim any whitespace
  [ "$(ps -o stat= -p "$wpid" 2>/dev/null | tr -d '[:space:]')" = "T" ]

  run curl -s -o "$BATS_TEST_TMPDIR/rw.out" -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' \
    -d '{"verb":"resume-worker","id":"pw17"}' "http://127.0.0.1:$PORT/api/ctl"
  [ "$output" = "200" ]
  [ ! -f "$BUS/limits/pw17.frozen" ]
  # SIGCONT -> back to an S (interruptible sleep) state, whatever its suffix flags
  [[ "$(ps -o stat= -p "$wpid" 2>/dev/null)" == S* ]]

  # cleanup the now-thawed marker so teardown has nothing to find on the GREEN path
  kill "$wpid" 2>/dev/null || true
}
