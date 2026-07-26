#!/usr/bin/env bats
# TDD RED-wave tests for the three cockpit redesign read endpoints that do not exist yet
# (plans/002-cockpit-redesign/PLAN.md §4.1–§4.4 + §5.3b items 1+4): GET /api/agents,
# GET /api/loop, GET /api/agent?id=. Every test runs against a fixture bus AND a fixture
# swarm.conf under $BATS_TEST_TMPDIR on a throwaway ephemeral port — never the real .bus,
# never the real swarm.conf, never port 4747.
#
# Project: unimatrix — multi-model swarm orchestrator driven from Claude Code
# Module:  tests/cockpit-api.bats
# Deps:    bats-core, site/server.mjs (node), curl, jq
# Tested:  n/a — this is the test file
#
# Key responsibilities:
# - end-to-end coverage of the new server.mjs API surfaces (/api/agents, /api/loop, /api/agent)
# - field recipes from PLAN §4.2–§4.4 (state, lease, provenance, run-log summary, loop envelope,
#   drawer bodies, ID_RE traversal rejects) plus §5.3b done_ms / run_started_ms / limits TTL
# - read-only bus guarantee for the three new GET routes
#
# Design constraints:
# - fixture-only: throwaway bus + swarm.conf copy under $BATS_TEST_TMPDIR, ephemeral port —
#   never the real .bus, real swarm.conf, port 4747, or systemd-run
# - bats files do not share helpers — _free_port / _start_server are local copies of the
#   ground-control.bats pattern
# - RED wave: endpoints are intentionally absent; every @test must FAIL until the green wave

REPO="$BATS_TEST_DIRNAME/.."
SERVER_JS="$REPO/site/server.mjs"

setup() {
  BUS="$BATS_TEST_TMPDIR/bus"
  mkdir -p "$BUS"/{queue,claimed,done,cancelled,limits,specs,pids}

  # fixture swarm.conf: a COPY of the real one so tests never touch the repo's own. LEASE_MIN is
  # pinned to 15 (the §4.2 heartbeat / stale threshold the stale-lease test asserts against).
  CONF="$BATS_TEST_TMPDIR/swarm.conf"
  cp "$REPO/swarm.conf" "$CONF"
  sed -i "s|^LEASE_MIN=.*|LEASE_MIN=15  # stale-lease reclaim threshold, in minutes|" "$CONF"
  sed -i "s|^EXEC_CHAIN=.*|EXEC_CHAIN=\"grok:grok-4.5 glm:glm-5.2 claude:haiku\"  # space-separated lane:model fallback chain, left to right|" "$CONF"

  SERVER_PID=""
}

teardown() {
  if [ -n "${SERVER_PID:-}" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  return 0
}

# _free_port — an ephemeral port derived from this shell's pid + the bats test number, never the
# real cockpit's port 4747 (docs/02-build-pitfalls.md-style hermeticity: no fixed port to collide
# on across parallel bats runs).
_free_port() {
  echo $(( 20000 + ( ($$ + ${BATS_TEST_NUMBER:-0} * 97) % 9000 ) ))
}

# _start_server — boots site/server.mjs against the fixture bus on a free port, polls /health up
# to 5s. Sets $PORT and $SERVER_PID for the calling test; teardown() kills $SERVER_PID.
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

# _agent — jq helper: pick one agent object by id from a saved /api/agents JSON file.
_agent() {
  local file="$1" id="$2"
  jq -c --arg id "$id" '.agents[] | select(.id == $id)' "$file"
}

# --- /api/agents --------------------------------------------------------------

# --- /health (P0-FR4) ----------------------------------------------------------

@test "health: /health returns root/branch/head/busdir, all four present and root+busdir absolute" {
  _start_server
  run curl -fsS "http://127.0.0.1:$PORT/health"
  [ "$status" -eq 0 ]
  echo "$output" > "$BATS_TEST_TMPDIR/health.json"

  local root branch head busdir
  root="$(jq -r '.root' "$BATS_TEST_TMPDIR/health.json")"
  branch="$(jq -r '.branch' "$BATS_TEST_TMPDIR/health.json")"
  head="$(jq -r '.head' "$BATS_TEST_TMPDIR/health.json")"
  busdir="$(jq -r '.busdir' "$BATS_TEST_TMPDIR/health.json")"

  [[ "$root" == /* ]]
  [[ "$busdir" == /* ]]
  [ "$busdir" = "$BUS" ]
  [ -n "$branch" ] && [ "$branch" != "null" ]
  [ -n "$head" ] && [ "$head" != "null" ]
  # root/branch/head come from the same git plumbing swarm-run.sh's _print_banner uses — assert
  # against the live repo's own git state rather than hardcoding it (a literal absolute checkout
  # path in this file would itself trip check.sh's PII/host-path gates).
  [ "$root" = "$(git -C "$REPO" rev-parse --show-toplevel)" ]
  [ "$branch" = "$(git -C "$REPO" rev-parse --abbrev-ref HEAD)" ]
  [ "$head" = "$(git -C "$REPO" rev-parse --short HEAD)" ]
}

@test "F6: /health resolves git state PER REQUEST — a commit after boot changes the served head" {
  # Runs a COPY of server.mjs inside a throwaway git repo (server.mjs derives its REPO_ROOT from
  # its own path, and Node resolves symlinks, so a copy is the only way to give it a fixture repo).
  # /health is git-only, so the copy needs nothing else from site/.
  local fix="$BATS_TEST_TMPDIR/fixrepo"
  mkdir -p "$fix/site"
  cp "$SERVER_JS" "$fix/site/server.mjs"
  git -c init.defaultBranch=public init -q "$fix"
  local g=(git -C "$fix" -c user.email=user@example.com -c user.name=t)
  "${g[@]}" add -A
  "${g[@]}" commit -qm one

  PORT="$(_free_port)"
  BUSDIR="$BUS" PORT="$PORT" SWARM_CONF="$CONF" node "$fix/site/server.mjs" >/dev/null 2>&1 &
  SERVER_PID=$!
  local tries=0
  until curl -fsS --max-time 1 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; do
    tries=$(( tries + 1 )); [ "$tries" -ge 50 ] && return 1
    sleep 0.1
  done

  local first; first="$(curl -fsS "http://127.0.0.1:$PORT/health" | jq -r '.head')"
  [ "$first" = "$("${g[@]}" rev-parse --short HEAD)" ]

  printf 'two\n' > "$fix/second.txt"
  "${g[@]}" add -A
  "${g[@]}" commit -qm two
  local want; want="$("${g[@]}" rev-parse --short HEAD)"
  [ "$want" != "$first" ]

  # boot-time caching would keep serving $first here — the whole reason mon_web_ensure's staleness
  # check (F7) cannot trust a cached field
  local second; second="$(curl -fsS "http://127.0.0.1:$PORT/health" | jq -r '.head')"
  [ "$second" = "$want" ]
  [ "$(curl -fsS "http://127.0.0.1:$PORT/health" | jq -r '.branch')" = "public" ]
}

@test "api-agents: state mapping queued/claimed/done/cancelled from bus dirs" {
  : > "$BUS/queue/a1.prompt"
  : > "$BUS/claimed/a2.claude:sonnet"
  printf '%s\n' '{"id":"a3","code":0,"lane":"glm"}' > "$BUS/done/a3"
  : > "$BUS/cancelled/a4.prompt"

  _start_server
  run curl -fsS "http://127.0.0.1:$PORT/api/agents"
  [ "$status" -eq 0 ]
  echo "$output" > "$BATS_TEST_TMPDIR/agents.json"

  [ "$(_agent "$BATS_TEST_TMPDIR/agents.json" a1 | jq -r '.state')" = "queued" ]
  [ "$(_agent "$BATS_TEST_TMPDIR/agents.json" a2 | jq -r '.state')" = "claimed" ]
  [ "$(_agent "$BATS_TEST_TMPDIR/agents.json" a3 | jq -r '.state')" = "done" ]
  [ "$(_agent "$BATS_TEST_TMPDIR/agents.json" a4 | jq -r '.state')" = "cancelled" ]
}

@test "api-agents: stale lease when claimed mtime older than LEASE_MIN" {
  : > "$BUS/claimed/a2.claude:sonnet"
  touch -d "-20 minutes" "$BUS/claimed/a2.claude:sonnet"

  _start_server
  run curl -fsS "http://127.0.0.1:$PORT/api/agents"
  [ "$status" -eq 0 ]
  echo "$output" > "$BATS_TEST_TMPDIR/agents.json"

  local a2
  a2="$(_agent "$BATS_TEST_TMPDIR/agents.json" a2)"
  [ "$(jq -r '.stale' <<<"$a2")" = "true" ]
  [ "$(jq -r '.lease_remaining_sec' <<<"$a2")" = "0" ]
}

@test "api-agents: parked wins over queued when limits/<id>.parked exists" {
  : > "$BUS/queue/a5.prompt"
  : > "$BUS/limits/a5.parked"

  _start_server
  run curl -fsS "http://127.0.0.1:$PORT/api/agents"
  [ "$status" -eq 0 ]
  echo "$output" > "$BATS_TEST_TMPDIR/agents.json"

  [ "$(_agent "$BATS_TEST_TMPDIR/agents.json" a5 | jq -r '.state')" = "parked" ]
}

@test "api-agents: verify flag true for v-* ids" {
  : > "$BUS/queue/v-a1.prompt"

  _start_server
  run curl -fsS "http://127.0.0.1:$PORT/api/agents"
  [ "$status" -eq 0 ]
  echo "$output" > "$BATS_TEST_TMPDIR/agents.json"

  [ "$(_agent "$BATS_TEST_TMPDIR/agents.json" v-a1 | jq -r '.verify')" = "true" ]
}

@test "api-agents: done provenance done_lane + done_code from done marker JSON" {
  printf '%s\n' '{"id":"a3","code":0,"lane":"glm"}' > "$BUS/done/a3"

  _start_server
  run curl -fsS "http://127.0.0.1:$PORT/api/agents"
  [ "$status" -eq 0 ]
  echo "$output" > "$BATS_TEST_TMPDIR/agents.json"

  local a3
  a3="$(_agent "$BATS_TEST_TMPDIR/agents.json" a3)"
  [ "$(jq -r '.done_lane' <<<"$a3")" = "glm" ]
  [ "$(jq -r '.done_code' <<<"$a3")" = "0" ]
}

@test "api-agents: claim filename parse lane=glm model=glm-5.2 (dots in model survive)" {
  : > "$BUS/claimed/a6.glm:glm-5.2"

  _start_server
  run curl -fsS "http://127.0.0.1:$PORT/api/agents"
  [ "$status" -eq 0 ]
  echo "$output" > "$BATS_TEST_TMPDIR/agents.json"

  local a6
  a6="$(_agent "$BATS_TEST_TMPDIR/agents.json" a6)"
  [ "$(jq -r '.lane' <<<"$a6")" = "glm" ]
  [ "$(jq -r '.model' <<<"$a6")" = "glm-5.2" ]
}

@test "api-agents: claim filename parse lane=kimi model=kimi-k3" {
  : > "$BUS/claimed/k6.kimi:kimi-k3"

  _start_server
  run curl -fsS "http://127.0.0.1:$PORT/api/agents"
  [ "$status" -eq 0 ]
  echo "$output" > "$BATS_TEST_TMPDIR/agents.json"

  local k6
  k6="$(_agent "$BATS_TEST_TMPDIR/agents.json" k6)"
  [ "$(jq -r '.lane' <<<"$k6")" = "kimi" ]
  [ "$(jq -r '.model' <<<"$k6")" = "kimi-k3" ]
}

@test "api-agents: .lane sidecar sets lane and pinned=true for queued agent" {
  : > "$BUS/queue/a7.prompt"
  printf '%s\n' 'grok:grok-4.5' > "$BUS/queue/a7.lane"

  _start_server
  run curl -fsS "http://127.0.0.1:$PORT/api/agents"
  [ "$status" -eq 0 ]
  echo "$output" > "$BATS_TEST_TMPDIR/agents.json"

  local a7
  a7="$(_agent "$BATS_TEST_TMPDIR/agents.json" a7)"
  [ "$(jq -r '.lane' <<<"$a7")" = "grok" ]
  [ "$(jq -r '.pinned' <<<"$a7")" = "true" ]
}

@test "api-agents: run-log summary tokens>0 and last_activity non-empty" {
  : > "$BUS/claimed/a2.claude:sonnet"
  cat > "$BUS/run-a2.jsonl" <<'JSONL'
{"type":"assistant","message":{"content":[{"type":"text","text":"working on the task"}]}}
{"type":"result","result":"done","usage":{"input_tokens":50,"output_tokens":25}}
JSONL

  _start_server
  run curl -fsS "http://127.0.0.1:$PORT/api/agents"
  [ "$status" -eq 0 ]
  echo "$output" > "$BATS_TEST_TMPDIR/agents.json"

  local a2
  a2="$(_agent "$BATS_TEST_TMPDIR/agents.json" a2)"
  [ "$(jq -r '.tokens > 0' <<<"$a2")" = "true" ]
  [ "$(jq -r '.last_activity | length > 0' <<<"$a2")" = "true" ]
}

@test "api-agents: errors count from run log and retries from limits/.retries-<id>" {
  : > "$BUS/claimed/a2.claude:sonnet"
  cat > "$BUS/run-a2.jsonl" <<'JSONL'
{"type":"error","error":"first boom"}
{"type":"turn.failed","error":"second boom"}
{"type":"assistant","message":{"content":[{"type":"text","text":"retrying"}]}}
JSONL
  printf '2' > "$BUS/limits/.retries-a2"

  _start_server
  run curl -fsS "http://127.0.0.1:$PORT/api/agents"
  [ "$status" -eq 0 ]
  echo "$output" > "$BATS_TEST_TMPDIR/agents.json"

  local a2
  a2="$(_agent "$BATS_TEST_TMPDIR/agents.json" a2)"
  [ "$(jq -r '.errors' <<<"$a2")" = "2" ]
  [ "$(jq -r '.retries' <<<"$a2")" = "2" ]
}

@test "api-agents: envelope paused=true when PAUSE exists and run_active=false without run.pgid" {
  : > "$BUS/queue/a1.prompt"
  : > "$BUS/PAUSE"
  # deliberately no run.pgid

  _start_server
  run curl -fsS "http://127.0.0.1:$PORT/api/agents"
  [ "$status" -eq 0 ]
  echo "$output" > "$BATS_TEST_TMPDIR/agents.json"

  [ "$(jq -r '.paused' "$BATS_TEST_TMPDIR/agents.json")" = "true" ]
  [ "$(jq -r '.run_active' "$BATS_TEST_TMPDIR/agents.json")" = "false" ]
}

@test "api-agents: spent_usd sums total_cost_usd from run-log result lines" {
  : > "$BUS/claimed/a2.claude:sonnet"
  cat > "$BUS/run-a2.jsonl" <<'JSONL'
{"type":"result","result":"ok","total_cost_usd":0.0313,"usage":{"input_tokens":10,"output_tokens":5}}
JSONL

  _start_server
  run curl -fsS "http://127.0.0.1:$PORT/api/agents"
  [ "$status" -eq 0 ]
  echo "$output" > "$BATS_TEST_TMPDIR/agents.json"

  # spent_usd must include the result line's total_cost_usd (0.0313)
  [ "$(jq -r '.spent_usd > 0.03 and .spent_usd < 0.04' "$BATS_TEST_TMPDIR/agents.json")" = "true" ]
}

@test "api-agents: chain_left counts tokens in limits/.chain-<id>" {
  : > "$BUS/queue/a1.prompt"
  printf '%s\n' 'grok:grok-4.5 claude:haiku' > "$BUS/limits/.chain-a1"

  _start_server
  run curl -fsS "http://127.0.0.1:$PORT/api/agents"
  [ "$status" -eq 0 ]
  echo "$output" > "$BATS_TEST_TMPDIR/agents.json"

  [ "$(_agent "$BATS_TEST_TMPDIR/agents.json" a1 | jq -r '.chain_left')" = "2" ]
}

@test "api-agents: frozen=true when limits/<id>.frozen exists" {
  : > "$BUS/claimed/a2.claude:sonnet"
  : > "$BUS/limits/a2.frozen"

  _start_server
  run curl -fsS "http://127.0.0.1:$PORT/api/agents"
  [ "$status" -eq 0 ]
  echo "$output" > "$BATS_TEST_TMPDIR/agents.json"

  [ "$(_agent "$BATS_TEST_TMPDIR/agents.json" a2 | jq -r '.frozen')" = "true" ]
}

@test "api-agents: done_ms on done agents and run_started_ms in envelope when a run log exists" {
  printf '%s\n' '{"id":"a3","code":0,"lane":"glm"}' > "$BUS/done/a3"
  : > "$BUS/claimed/a2.claude:sonnet"
  cat > "$BUS/run-a2.jsonl" <<'JSONL'
{"type":"assistant","timestamp":"2026-07-19T12:00:00.000Z","message":{"content":[{"type":"text","text":"hi"}]}}
{"type":"result","timestamp":"2026-07-19T12:00:01.000Z","result":"ok","usage":{"input_tokens":1,"output_tokens":1}}
JSONL

  _start_server
  run curl -fsS "http://127.0.0.1:$PORT/api/agents"
  [ "$status" -eq 0 ]
  echo "$output" > "$BATS_TEST_TMPDIR/agents.json"

  # done_ms = mtime of done/<id> in epoch ms — must be a positive number
  [ "$(_agent "$BATS_TEST_TMPDIR/agents.json" a3 | jq -r '.done_ms > 0')" = "true" ]
  # envelope run_started_ms present when any run log exists (§5.3b item 1)
  [ "$(jq -r '.run_started_ms > 0' "$BATS_TEST_TMPDIR/agents.json")" = "true" ]
}

@test "api-agents: malformed claimed filename (no lane:model suffix) is discarded, no error" {
  # regression: claimed entries that fail CLAIM_RE used to fall back to n.split(".")[0] and
  # enter the agent universe unvalidated — discard them instead; a valid claim still appears.
  : > "$BUS/claimed/orphan-no-lane"
  : > "$BUS/claimed/a-good.claude:sonnet"

  _start_server
  run curl -fsS "http://127.0.0.1:$PORT/api/agents"
  [ "$status" -eq 0 ]
  echo "$output" > "$BATS_TEST_TMPDIR/agents.json"

  # no error body / non-JSON: jq already succeeds via the checks below
  [ "$(jq -r --arg id "orphan-no-lane" '[.agents[] | select(.id == $id)] | length' "$BATS_TEST_TMPDIR/agents.json")" = "0" ]
  [ "$(_agent "$BATS_TEST_TMPDIR/agents.json" a-good | jq -r '.state')" = "claimed" ]
}

@test "api-agents: limits TTL envelope entry for lane.limited with expires_in_sec>0" {
  : > "$BUS/queue/a1.prompt"
  # content = TTL seconds; expiry = mtime + TTL − now → still active
  printf '18000' > "$BUS/limits/glm.limited"

  _start_server
  run curl -fsS "http://127.0.0.1:$PORT/api/agents"
  [ "$status" -eq 0 ]
  echo "$output" > "$BATS_TEST_TMPDIR/agents.json"

  [ "$(jq -r '[.limits[] | select(.lane=="glm")] | length' "$BATS_TEST_TMPDIR/agents.json")" = "1" ]
  [ "$(jq -r '.limits[] | select(.lane=="glm") | .expires_in_sec > 0' "$BATS_TEST_TMPDIR/agents.json")" = "true" ]
}

@test "api-agents: limits TTL envelope parses a spec-14 FR-7 reason-line marker's ttl= field (not the legacy flat default)" {
  : > "$BUS/queue/a2.prompt"
  # new-format marker: content is a reason line, not a bare digit — the ttl= field must drive the
  # countdown; naively Number()'ing this line yields NaN and the pre-fix code silently fell back
  # to the flat 18000s default for every new-format lane.
  printf '2026-07-25T10:00:00Z | rate-limit | retryable=1 | ttl=120 | session cap hit' \
    > "$BUS/limits/grok.limited"

  _start_server
  run curl -fsS "http://127.0.0.1:$PORT/api/agents"
  [ "$status" -eq 0 ]
  echo "$output" > "$BATS_TEST_TMPDIR/agents2.json"

  [ "$(jq -r '[.limits[] | select(.lane=="grok")] | length' "$BATS_TEST_TMPDIR/agents2.json")" = "1" ]
  local secs
  secs="$(jq -r '.limits[] | select(.lane=="grok") | .expires_in_sec' "$BATS_TEST_TMPDIR/agents2.json")"
  # a fresh marker with ttl=120 must read well under the legacy 18000s default
  [ "$secs" -gt 0 ]
  [ "$secs" -le 120 ]
}

@test "api-agents: limits/kimi.limited surfaces with expires_in_sec > 0" {
  : > "$BUS/claimed/k2.kimi:kimi-k3"
  # content = TTL seconds; expiry = mtime + TTL − now → still active
  printf '18000' > "$BUS/limits/kimi.limited"

  _start_server
  run curl -fsS "http://127.0.0.1:$PORT/api/agents"
  [ "$status" -eq 0 ]
  echo "$output" > "$BATS_TEST_TMPDIR/agents.json"

  [ "$(jq -r '[.limits[] | select(.lane=="kimi")] | length' "$BATS_TEST_TMPDIR/agents.json")" = "1" ]
  [ "$(jq -r '.limits[] | select(.lane=="kimi") | .expires_in_sec > 0' "$BATS_TEST_TMPDIR/agents.json")" = "true" ]
  # a limited kimi worker's own claim must still surface — kimi has to be a CLAIM_RE-recognized lane
  [ "$(_agent "$BATS_TEST_TMPDIR/agents.json" k2 | jq -r '.lane')" = "kimi" ]
}

# --- /api/loop ----------------------------------------------------------------

@test "api-loop: no loop dir yields run null" {
  # setup creates no BUS/loop/ — newest loop is absent
  _start_server
  run curl -fsS "http://127.0.0.1:$PORT/api/loop"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.run' <<<"$output")" = "null" ]
}

@test "api-loop: seeded loop reports run id, iter, max_iterations, cost_total, halted" {
  local loopdir="$BUS/loop/r-t"
  mkdir -p "$loopdir"
  cat > "$loopdir/criteria.md" <<'CRIT'
goal: hold the line
stops:
  max_iterations: 12
  budget_usd: 0
CRIT
  cat > "$loopdir/state.jsonl" <<'STATE'
{"iter":1,"tried":["e1"],"oracle_rc":1,"review":"fail","cost":0.10,"ts":"2026-07-19T12:00:00Z","sig":"s1"}
{"iter":2,"tried":["e2"],"oracle_rc":1,"review":"fail","cost":0.20,"ts":"2026-07-19T12:01:00Z","sig":"s2"}
{"iter":3,"tried":["e3"],"oracle_rc":1,"review":"fail","cost":0.30,"ts":"2026-07-19T12:02:00Z","sig":"s3"}
STATE
  printf '%s\n' 'max_iterations reached' > "$loopdir/HALTED.md"

  _start_server
  run curl -fsS "http://127.0.0.1:$PORT/api/loop"
  [ "$status" -eq 0 ]
  echo "$output" > "$BATS_TEST_TMPDIR/loop.json"

  [ "$(jq -r '.run' "$BATS_TEST_TMPDIR/loop.json")" = "r-t" ]
  [ "$(jq -r '.iter' "$BATS_TEST_TMPDIR/loop.json")" = "3" ]
  [ "$(jq -r '.max_iterations' "$BATS_TEST_TMPDIR/loop.json")" = "12" ]
  # cost_total = 0.10 + 0.20 + 0.30
  [ "$(jq -r '(.cost_total - 0.6) | fabs < 0.001' "$BATS_TEST_TMPDIR/loop.json")" = "true" ]
  [ "$(jq -r '.halted' "$BATS_TEST_TMPDIR/loop.json")" = "true" ]
}

@test "api-loop: max_iterations two-space line OUTSIDE stops: is ignored" {
  # regression: matchStop used to scan the whole criteria.md for `  key:` lines, so a stray
  # two-space-indented max_iterations outside the stops: block could win. Isolate stops: first.
  local loopdir="$BUS/loop/r-out"
  mkdir -p "$loopdir"
  cat > "$loopdir/criteria.md" <<'CRIT'
goal: hold the line
  max_iterations: 99
stops:
  budget_usd: 1.5
CRIT
  : > "$loopdir/state.jsonl"

  _start_server
  run curl -fsS "http://127.0.0.1:$PORT/api/loop"
  [ "$status" -eq 0 ]
  echo "$output" > "$BATS_TEST_TMPDIR/loop-out.json"

  # outside-block line must not surface; budget under stops: still parses
  [ "$(jq -r '.max_iterations' "$BATS_TEST_TMPDIR/loop-out.json")" = "null" ]
  [ "$(jq -r '.budget_usd' "$BATS_TEST_TMPDIR/loop-out.json")" = "1.5" ]
}

# --- /api/agent ---------------------------------------------------------------

@test "api-agent: done id returns res.text and spec.text from handoff + archived prompt" {
  printf '%s\n' '{"id":"a3","code":0,"lane":"glm"}' > "$BUS/done/a3"
  printf '%s\n' 'handoff answer for a3' > "$BUS/res-a3.txt"
  printf '%s\n' 'archived spec for a3' > "$BUS/prompt-a3.txt"

  _start_server
  run curl -fsS "http://127.0.0.1:$PORT/api/agent?id=a3"
  [ "$status" -eq 0 ]
  echo "$output" > "$BATS_TEST_TMPDIR/agent.json"

  [[ "$(jq -r '.res.text' "$BATS_TEST_TMPDIR/agent.json")" == *"handoff answer for a3"* ]]
  [[ "$(jq -r '.spec.text' "$BATS_TEST_TMPDIR/agent.json")" == *"archived spec for a3"* ]]
}

@test "api-agent: queued id returns spec.text from queue prompt and res null; unknown id is 404" {
  printf '%s\n' 'queued prompt body for a1' > "$BUS/queue/a1.prompt"

  _start_server
  run curl -fsS "http://127.0.0.1:$PORT/api/agent?id=a1"
  [ "$status" -eq 0 ]
  echo "$output" > "$BATS_TEST_TMPDIR/agent-q.json"

  [[ "$(jq -r '.spec.text' "$BATS_TEST_TMPDIR/agent-q.json")" == *"queued prompt body for a1"* ]]
  [ "$(jq -r '.res' "$BATS_TEST_TMPDIR/agent-q.json")" = "null" ]

  run curl -s -o "$BATS_TEST_TMPDIR/agent-unk.out" -w '%{http_code}' \
    "http://127.0.0.1:$PORT/api/agent?id=does-not-exist"
  [ "$output" = "404" ]
}

@test "api-agent: traversal ids ../x and .hidden are 400 with no file content leaked" {
  # plant a secret on the bus; a buggy handler that path-joins the raw id would surface it
  printf '%s\n' 'SECRET_BUS_CONTENT_SHOULD_NOT_LEAK' > "$BUS/queue/secret.prompt"
  printf '%s\n' 'SECRET_ROOT_MARKER' > "$BATS_TEST_TMPDIR/secret-outside.txt"

  _start_server

  run curl -s -o "$BATS_TEST_TMPDIR/trav1.out" -w '%{http_code}' \
    --get --data-urlencode 'id=../x' \
    "http://127.0.0.1:$PORT/api/agent"
  [ "$output" = "400" ]
  run cat "$BATS_TEST_TMPDIR/trav1.out"
  [[ "$output" != *"SECRET"* ]]

  run curl -s -o "$BATS_TEST_TMPDIR/trav2.out" -w '%{http_code}' \
    --get --data-urlencode 'id=.hidden' \
    "http://127.0.0.1:$PORT/api/agent"
  [ "$output" = "400" ]
  run cat "$BATS_TEST_TMPDIR/trav2.out"
  [[ "$output" != *"SECRET"* ]]
}

@test "api-agent: GET battery on all 3 new routes mutates nothing in the fixture bus" {
  : > "$BUS/queue/a1.prompt"
  : > "$BUS/claimed/a2.claude:sonnet"
  printf '%s\n' '{"id":"a3","code":0,"lane":"glm"}' > "$BUS/done/a3"
  printf '%s\n' 'spec body' > "$BUS/prompt-a3.txt"
  printf '%s\n' 'res body' > "$BUS/res-a3.txt"

  _start_server

  local before="$BATS_TEST_TMPDIR/before.tree"
  local after="$BATS_TEST_TMPDIR/after.tree"
  # mtime/inode/size, not just pathnames — an in-place mutation would keep the path but change this
  find "$BUS" -exec stat -c '%n %Y %i %s' {} \; | sort > "$before"

  curl -fsS "http://127.0.0.1:$PORT/api/agents" >/dev/null
  curl -fsS "http://127.0.0.1:$PORT/api/loop" >/dev/null
  curl -fsS "http://127.0.0.1:$PORT/api/agent?id=a3" >/dev/null

  find "$BUS" -exec stat -c '%n %Y %i %s' {} \; | sort > "$after"
  run diff "$before" "$after"
  [ "$status" -eq 0 ]
}

# --- /api/stream replay-done sentinel (backlog 24) ------------------------------
#
# The cockpit used to guess "the first 2s after connect is replay" (data.js backfillUntil). On a bus
# with real history the replay outlasts 2s, so its tail was counted as live and stamped a fresh
# lastEvtClient on agents that finished hours ago — silencing their stale/silent alerts. The server
# now says when replay is over, so the client never has to guess.

@test "api-stream: emits event: replay-done exactly once, after the replay and before live events" {
  printf '%s\n' '{"type":"result","result":"replayed-line"}' > "$BUS/run-w1.jsonl"

  _start_server
  local out="$BATS_TEST_TMPDIR/stream-sentinel.out"
  # the live line lands well after the initial glob pass (server polls every 500ms)
  ( sleep 1.5; printf '%s\n' '{"type":"result","result":"live-line"}' >> "$BUS/run-w1.jsonl" ) &
  local writer=$!
  curl -N -s --max-time 4 "http://127.0.0.1:$PORT/api/stream" > "$out" || true
  wait "$writer" 2>/dev/null || true

  [ "$(grep -c '^event: replay-done$' "$out")" -eq 1 ]
  local replayed sentinel live
  replayed="$(grep -n 'replayed-line' "$out" | head -1 | cut -d: -f1)"
  sentinel="$(grep -n '^event: replay-done$' "$out" | cut -d: -f1)"
  live="$(grep -n 'live-line' "$out" | head -1 | cut -d: -f1)"
  [ -n "$replayed" ] && [ -n "$sentinel" ] && [ -n "$live" ]
  [ "$replayed" -lt "$sentinel" ]
  [ "$sentinel" -lt "$live" ]
}

@test "api-stream: replay-done sentinel arrives on an empty bus (nothing to replay)" {
  # no run-*.jsonl at all — a sentinel gated on "some replay happened" would hang the client in
  # permanent replay mode and silence every live signal
  _start_server
  local out="$BATS_TEST_TMPDIR/stream-empty.out"
  curl -N -s --max-time 2 "http://127.0.0.1:$PORT/api/stream" > "$out" || true

  [ "$(grep -c '^event: replay-done$' "$out")" -eq 1 ]
}

# --- POST /api/ctl (spec 14 fix-round: hasBusFootprint must see an orphan .files sidecar) -------

@test "api-ctl: add of an id with only an orphan queue/<id>.files footprint returns 409 (no silent re-scope)" {
  # hasBusFootprint checked queue/<id>.lane and .write but not .files — an id with nothing but a
  # leftover manifest sidecar (e.g. from a cancelled prior publish some other bug left behind)
  # would sail through as "new" and silently re-scope the fresh card to the stale manifest.
  _start_server
  printf 'a.ts\n' > "$BUS/queue/orphanf1.files"
  run curl -s -o "$BATS_TEST_TMPDIR/orphanf1.out" -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' \
    -d '{"verb":"add","id":"orphanf1","prompt":"new card"}' "http://127.0.0.1:$PORT/api/ctl"
  [ "$output" = "409" ]
  [ "$(jq -r '.ok' "$BATS_TEST_TMPDIR/orphanf1.out")" = "false" ]
  [ ! -f "$BUS/queue/orphanf1.prompt" ]
}

# --- FR-14 anti-fake sweep -----------------------------------------------------

@test "FR-14 anti-fake sweep: shipped cockpit sources contain no mock literals" {
  # regression: QA screenshots / mock data (a fake run id "r-0719", a fake branch "b-23", a made-up
  # age "~18m", placeholder copy "retry storm", a fabricated dollar figure "$0.42") must never ship
  # in the actual cockpit sources — grep -v drops comment lines referencing these as examples.
  cd "$REPO"
  run bash -c 'grep -rn -E "r-0719|b-23|~18m|retry storm|\$0\.42" site/cockpit.html site/cockpit/ --include="*.js" --include="*.html" | grep -v "^[[:space:]]*//"'
  [ -z "$output" ]
}
