#!/usr/bin/env bats
# Integration tests for swarm-run.sh full mode: the FANOUT-bounded job pool driving EXEC_CHAIN
# fallback (or a per-branch pinned lane, FR-2b) over PATH-shimmed fake CLIs. No real API calls —
# every claude/codex/gemini invocation in this file resolves to a fake script under
# $BATS_TEST_TMPDIR/bin.
#
# Project: unimatrix — multi-model swarm orchestrator driven from Claude Code
# Module:  tests/swarm-run.bats
# Deps:    bats-core, src/swarm-lib.sh, swarm-run.sh, fake claude/codex/gemini on PATH
# Tested:  n/a — this is the test file
#
# Design constraints:
# - Fakes read their behavior from $BIN/fake.conf (sourced via ${BASH_SOURCE[0]}'s own dirname),
#   NOT from inherited env vars — lane_cmd wraps every real invocation in `env -i` (containment,
#   FR-12/13 step), which would otherwise strip every FAKE_* knob the old env-var mechanism relied
#   on. Tests call `_fake NAME value` instead of `export FAKE_NAME=value`.

RUNSH="$BATS_TEST_DIRNAME/../swarm-run.sh"

setup() {
  BUS="$BATS_TEST_TMPDIR/bus"
  CONF="$BATS_TEST_TMPDIR/swarm.conf"
  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN"
  export PATH="$BIN:$PATH"
  export BUSDIR="$BUS"
  export CONF
  export HEARTBEAT_SEC=1
  # full_run now calls mon_web_ensure/mon_web_open (specs/05-ground-control.md) — default
  # MON_AUTOOPEN=1/MON_PORT=4747 would probe/spawn against the REAL port 4747 and real .bus
  # default from every test in this file. Disable; ground-control.bats covers that behavior
  # in isolation with its own throwaway ports.
  export MON_AUTOOPEN=0
  # _scratch_home (src/swarm-lib.sh) reads $HOME/.claude, $HOME/.codex — never let a test touch
  # the real user's actual credentials; every test gets its own throwaway "real" home instead.
  export HOME="$BATS_TEST_TMPDIR/realhome"
  mkdir -p "$HOME"
  # _scratch_home also honors CLAUDE_CONFIG_DIR (multi-account setups) — unset so this box's own
  # ambient session dir never leaks real credentials into a test's throwaway scratch home.
  unset CLAUDE_CONFIG_DIR
  # spec 13 FR-1: env_master_preflight now aborts a run whose lane set touches gemini/glm/kimi
  # (in EXEC_CHAIN/REVIEW/REVIEW_CHAIN, or a queue/*.lane pin) if $ENV_MASTER_FILE is unreadable —
  # give every test a working default (all three env-key lanes present) so this file's many
  # glm/kimi/gemini fixtures keep working out of the box; a test that specifically wants the
  # missing/broken-file scenario overrides ENV_MASTER_FILE itself afterward (last export wins).
  printf 'Z_AI_CODING_KEY=default-glm-key\nMOONSHOT_API_KEY=default-kimi-key\nGEMINI_API_KEY=default-gem-key\n' \
    > "$BATS_TEST_TMPDIR/envmaster-default"
  export ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster-default"
  # spec 13 FR-6: auto live-probes default ON for operators — OFF for this suite (env outranks
  # conf per FR-1), or every legacy run test would fire a probe per lane (extra fake invocations,
  # ledger rows into the repo's real docs/ops file for tests that don't set LEDGER_FILE). The FR-6
  # tests re-export PROBE_AUTO=1 themselves.
  export PROBE_AUTO=0
  BG_PIDS=()
  _install_fakes
}

teardown() {
  local p
  for p in "${BG_PIDS[@]:-}"; do
    [ -n "$p" ] && kill -9 "$p" 2>/dev/null
    [ -n "$p" ] && wait "$p" 2>/dev/null
  done
  # belt-and-braces: nothing from this test's bus/bin markers should survive it
  pkill -9 -f "$BATS_TEST_TMPDIR" 2>/dev/null || true
  return 0
}

# _fake <NAME> <value> — appends NAME="value" to $BIN/fake.conf (bash-%q-escaped), which every
# fake CLI sources on its own via ${BASH_SOURCE[0]}'s dirname. This is a FILE, not an env var, on
# purpose: it must survive lane_cmd's `env -i` wrapping around the real invocation.
_fake() { printf '%s=%q\n' "$1" "$2" >> "$BIN/fake.conf"; }

# Fake claude (also serves the GLM and kimi lanes, which re-invoke `claude -p` under a swapped env).
# Knobs (set via `_fake NAME value`): FAKE_CLAUDE_RESULT, FAKE_CLAUDE_EXIT, FAKE_CLAUDE_DELAY
# (always applied), FAKE_CLAUDE_ONCE_MARKER + FAKE_CLAUDE_ONCE_MODE (hang|answerhang|limit|slow),
# firing only
# while the marker file is absent — lets one fake simulate "fails/hangs/is-slow once, behaves
# normally on retry"). FAKE_CLAUDE_LIMIT_CODE / FAKE_CLAUDE_NEXT_FLUSH parameterize "limit".
# FAKE_CLAUDE_SLOW_SEC / FAKE_CLAUDE_SLOW_RESULT parameterize "slow" (FR-14: a bounded-but-slow
# first attempt that finishes AFTER a retry has already completed, unlike "hang" which never
# finishes on its own). "autherr" (spec10 FR-R8) emits a NORMAL result envelope (exit 0) whose
# text is FAKE_CLAUDE_AUTH_TEXT (default "OAuth session expired · Please run /login") — the
# cal056 false-done shape, distinct from "limit"'s real error envelope + exit 1. "answerhang"
# (backlog 17+10) emits a complete result envelope carrying FAKE_CLAUDE_SALVAGE_RESULT and then
# hangs forever — a worker whose answer is already on disk when the watchdog kills it.
# FAKE_CLAUDE_DUMP_ENV, if set, writes `env` to that path before anything else (env-scrub check).
# FAKE_CLAUDE_ERROR_JSON, if set, emits that event line verbatim then exits 1 (unconditionally,
# not gated on ONCE_MARKER). FAKE_CLAUDE_USAGE_JSON, if set, merges into the default-path result
# event's usage field. FAKE_GEMINI_ERROR (fake gemini, below), if set, emits
# {"type":"error","message":"..."} then exits 1.
_install_fakes() {
  : > "$BIN/fake.conf"
  cat > "$BIN/claude" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$_here/fake.conf" ]] && source "$_here/fake.conf"
[[ -n "${FAKE_CLAUDE_DUMP_ENV:-}" ]] && env > "$FAKE_CLAUDE_DUMP_ENV"
# spec14 FR-B test instrumentation: append this invocation's full argv (the CLI's own copy of the
# prompt text lands here, positional) so a test can prove which specs/ vs queue/ copy actually got
# spawned, without racing the pool's own claim timing. Append, not overwrite — several branches in
# the same run may share this lane concurrently (FANOUT>1).
[[ -n "${FAKE_CLAUDE_ARGV_FILE:-}" ]] && printf '%s\n' "$*" >> "$FAKE_CLAUDE_ARGV_FILE"
# spec14 FR-5 companion test fixture: exit with the given code having emitted ZERO bytes — models
# both a card-fault (silent exit 1, e.g. env -C on a target that vanished after the claim-time
# check) and a lane-fault (a missing/non-executable binary dies with rc 126/127, zero stdout).
if [[ -n "${FAKE_CLAUDE_SILENT_FAIL:-}" ]]; then
  exit "${FAKE_CLAUDE_SILENT_FAIL}"
fi
# FR-15: write-mode probe — writes a file relative to $PWD (never an absolute path baked into the
# knob), so a passing assertion proves lane_cmd actually chdir'd the worker into the write target
# via `env -C`, not just that it passed the right string somewhere in argv.
if [[ -n "${FAKE_CLAUDE_WRITE_FILE:-}" ]]; then
  printf '%s' "${FAKE_CLAUDE_WRITE_CONTENT:-written}" > "$FAKE_CLAUDE_WRITE_FILE"
  # FR-R11 granularity probe: pin the written file's AND the cwd's mtime to a reference file (the
  # pre-spawn stamp) — models a write landing in the stamp's own mtime granule on a coarse-mtime fs.
  if [[ -n "${FAKE_CLAUDE_WRITE_TOUCH_REF:-}" ]]; then
    touch -r "$FAKE_CLAUDE_WRITE_TOUCH_REF" "$FAKE_CLAUDE_WRITE_FILE" .
  fi
  # spec10 FR-E test fixture: create-then-remove — leaves only the write target DIRECTORY's own
  # mtime bumped, no file surviving under it (models a concurrent-churn false positive on the OLD,
  # unfixed find, which had no `-type f`).
  [[ -n "${FAKE_CLAUDE_WRITE_THEN_RM:-}" ]] && rm -f "$FAKE_CLAUDE_WRITE_FILE"
fi
if [[ -n "${FAKE_CLAUDE_ONCE_MARKER:-}" ]] && mkdir "$FAKE_CLAUDE_ONCE_MARKER" 2>/dev/null; then
  # mkdir, not `[[ ! -e ]] && touch`: with FANOUT>1 two concurrent invocations both raced past the
  # -e check and BOTH took the once-mode (seen live in the spec14 FR-8 fixture) — mkdir is atomic,
  # exactly one invocation wins. Existence checks on the marker still work (it's a dir now).
  case "${FAKE_CLAUDE_ONCE_MODE:-limit}" in
    hang)
      sleep 9999
      ;;
    answerhang)
      # backlog 17+10 salvage fixture: emit a COMPLETE, valid result envelope (already flushed
      # through the driver's tee into run-<id>.jsonl) and only THEN hang forever — the
      # p53-build-drift shape, where the work was finished but the process never exited and the
      # watchdog SIGKILLed it. Distinct from "hang" (nothing on the wire at all) and from "slow"
      # (finishes on its own, just late).
      echo '{"type":"init"}'
      # spec14 cross-review MINOR fixture: FAKE_CLAUDE_DENIALS_JSON on this envelope models a
      # cage-denied worker that answered before the watchdog killed it (contrast the plain
      # answerhang shape, which has no denials).
      _ah_extra=""
      [[ -n "${FAKE_CLAUDE_DENIALS_JSON:-}" ]] && _ah_extra=",\"permission_denials\":$FAKE_CLAUDE_DENIALS_JSON"
      printf '{"type":"result","result":"%s"%s}\n' "${FAKE_CLAUDE_SALVAGE_RESULT:-salvaged answer}" "$_ah_extra"
      sleep 9999
      ;;
    limit)
      printf '{"type":"error","error":{"code":%s,"message":"limit","next_flush_time":%s}}\n' \
        "${FAKE_CLAUDE_LIMIT_CODE:-1308}" "${FAKE_CLAUDE_NEXT_FLUSH:-9999999999}"
      exit 1
      ;;
    slow)
      sleep "${FAKE_CLAUDE_SLOW_SEC:-4}"
      echo '{"type":"init"}'
      printf '{"type":"result","result":"%s"}\n' "${FAKE_CLAUDE_SLOW_RESULT:-stale answer}"
      exit 0
      ;;
    autherr)
      # spec10 FR-R8 (cal056 false-done shape): a NORMAL result envelope whose text IS the
      # auth-death signature — exit 0, no error/turn.failed event at all. Distinguishes this from
      # "limit" mode, which emits a real error envelope and exit 1.
      echo '{"type":"init"}'
      printf '{"type":"result","result":"%s"}\n' "${FAKE_CLAUDE_AUTH_TEXT:-OAuth session expired · Please run /login}"
      exit 0
      ;;
    journalwrite)
      # spec14 FR-8 fixture: a worker that REALLY writes — file on disk (relative to cwd, i.e.
      # the env -C write cage) AND the matching Write tool_use record in its stream, so a journal
      # can be derived. The non-once siblings sharing the fake stay narration-only (plain result,
      # no writes, no tool_use records) — the W3D1 shape.
      echo '{"type":"init"}'
      _jw_file="${FAKE_CLAUDE_WRITE_FILE:-journal-made.txt}"
      printf '%s' "journal write" > "$_jw_file"
      printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"%s/%s"}}]}}\n' "$PWD" "$_jw_file"
      printf '{"type":"result","result":"wrote %s"}\n' "$_jw_file"
      exit 0
      ;;
  esac
fi
# Unusable-output mode: appends one line to the knob's file (an invocation counter), emits NO
# result event, exits 1 — extract_answer fails and limit_error sees no error envelope (rc 0),
# exercising the bounded same-lane retry path (MAX_LANE_RETRIES).
if [[ -n "${FAKE_CLAUDE_GARBAGE_COUNT:-}" ]]; then
  echo x >> "$FAKE_CLAUDE_GARBAGE_COUNT"
  echo '{"type":"init"}'
  exit 1
fi
# spec12 FR-D test fixture: each invocation increments a counter file and tags its output with the
# attempt number, then fails (exit 1, no result event) — retried on the same lane every time
# (MAX_LANE_RETRIES), giving each attempt's run-<id>.jsonl DISTINCT content so a test can prove
# rotation preserved attempt N's bytes rather than every attempt looking identical.
if [[ -n "${FAKE_CLAUDE_ATTEMPT_COUNTER:-}" ]]; then
  _n=$(( $(cat "$FAKE_CLAUDE_ATTEMPT_COUNTER" 2>/dev/null || echo 0) + 1 ))
  echo "$_n" > "$FAKE_CLAUDE_ATTEMPT_COUNTER"
  echo "{\"type\":\"init\",\"attempt\":$_n}"
  exit 1
fi
# FAKE_CLAUDE_ERROR_JSON: emit the given event line verbatim, then exit 1 — a caller-shaped error
# envelope (limit_error's claude auth-death/rate-limit sniffing) without the fixed "limit" mode's
# hardcoded shape.
if [[ -n "${FAKE_CLAUDE_ERROR_JSON:-}" ]]; then
  printf '%s\n' "$FAKE_CLAUDE_ERROR_JSON"
  exit 1
fi
sleep "${FAKE_CLAUDE_DELAY:-0}"
echo '{"type":"init"}'
# FAKE_CLAUDE_USAGE_JSON: merge into the result event's usage field (spec10 FR-R10 kimi spend
# recompute needs real token counts on the envelope). FAKE_CLAUDE_DENIALS_JSON: same, for
# permission_denials (spec14 FR-1 — the cage-denied fixture). Both optional, both on the ONE result
# envelope, because cage_denials only ever reads the LAST type=="result" event.
_extra=""
[[ -n "${FAKE_CLAUDE_USAGE_JSON:-}" ]] && _extra="$_extra,\"usage\":$FAKE_CLAUDE_USAGE_JSON"
[[ -n "${FAKE_CLAUDE_DENIALS_JSON:-}" ]] && _extra="$_extra,\"permission_denials\":$FAKE_CLAUDE_DENIALS_JSON"
printf '{"type":"result","result":"%s"%s}\n' "${FAKE_CLAUDE_RESULT:-OK}" "$_extra"
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
if [[ -n "${FAKE_CODEX_LIMIT:-}" ]]; then
  echo '{"type":"turn.failed","error":{"code":"rate_limit_exceeded","message":"usage limit reached"}}'
  exit 1
fi
echo '{"type":"thread.started"}'
if [[ -n "${FAKE_CODEX_WRITE_FILE:-}" ]]; then
  printf '%s' "${FAKE_CODEX_WRITE_CONTENT:-written}" > "$FAKE_CODEX_WRITE_FILE"
fi
[[ -n "$outfile" ]] && printf '%s' "${FAKE_CODEX_RESULT:-codex OK}" > "$outfile"
echo '{"type":"turn.completed","usage":{"input_tokens":10}}'
exit "${FAKE_CODEX_EXIT:-0}"
FAKE

  # Real 0.49 stream-json shape (live-verified 2026-07-08): assistant message delta(s) carry the
  # answer text; the result event carries ONLY {stats,status,timestamp,type} — no `.response`.
  cat > "$BIN/gemini" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$_here/fake.conf" ]] && source "$_here/fake.conf"
[[ -n "${FAKE_GEMINI_DUMP_ENV:-}" ]] && env > "$FAKE_GEMINI_DUMP_ENV"
# FAKE_GEMINI_ERROR: spec10 FR-R8 gemini arm — a quota/rate error envelope, exit 1.
if [[ -n "${FAKE_GEMINI_ERROR:-}" ]]; then
  printf '{"type":"error","message":"%s"}\n' "${FAKE_GEMINI_ERROR}"
  exit 1
fi
sleep "${FAKE_GEMINI_DELAY:-0}"
echo '{"type":"init"}'
content="$(printf '%s' "${FAKE_GEMINI_RESULT:-gemini OK}" | jq -Rs .)"
printf '{"type":"message","role":"assistant","content":%s,"delta":true}\n' "$content"
echo '{"type":"result","stats":{"models":{"gemini-3.5-flash":{}}},"status":"ok","timestamp":0}'
exit "${FAKE_GEMINI_EXIT:-0}"
FAKE

  # FR-16: fake docker for the opt-in containerized gemini lane. Strips the `run --rm -i -e K=V
  # -e K=V <image>` prefix it was called with and execs the trailing `gemini ...` argv — which
  # PATH-resolves to the fake gemini above — so a GEMINI_SANDBOX=docker branch exercises the SAME
  # full round trip (claim -> spawn -> tee -> extract_answer -> done) as every other lane, with no
  # real docker/network involved.
  cat > "$BIN/docker" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$_here/fake.conf" ]] && source "$_here/fake.conf"
[[ -n "${FAKE_DOCKER_ARGV_FILE:-}" ]] && printf '%s\n' "$*" > "$FAKE_DOCKER_ARGV_FILE"
shift  # drop 'run'
while [[ $# -gt 0 ]]; do
  case "$1" in
    --rm|-i) shift ;;
    -e) shift 2 ;;
    *) break ;;
  esac
done
shift  # drop the pinned image ref
exec "$@"
FAKE

  # xAI Grok Build CLI (OAuth file auth, ~/.grok/auth.json — no env-var key). streaming-json:
  # a thought chunk (firehose spam, never the answer), one text chunk honoring FAKE_GROK_RESULT,
  # then the end event carrying usage + (when FAKE_GROK_COST is set) total_cost_usd/modelUsage.cost
  # — omitted otherwise, mirroring the real CLI's OAuth-pool cost-omission behavior.
  # FAKE_GROK_ERROR short-circuits to a bare {"type":"error",...} + exit 1, no text/end at all.
  cat > "$BIN/grok" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$_here/fake.conf" ]] && source "$_here/fake.conf"
[[ -n "${FAKE_GROK_DUMP_ENV:-}" ]] && env > "$FAKE_GROK_DUMP_ENV"
# spec 15 test support: record this spawn's argv (same shape as FAKE_DOCKER_ARGV_FILE above) so a
# test can assert on FLAGS the engine did/didn't pass — e.g. model=="default" must omit -m entirely.
[[ -n "${FAKE_GROK_ARGV_FILE:-}" ]] && printf '%s\n' "$*" > "$FAKE_GROK_ARGV_FILE"
# spec 13 FR-3 test support: one line per invocation, proves a routed-around .broken lane is never
# spawned again (distinct from FAKE_GROK_ERROR, which has no call-count signal of its own).
[[ -n "${FAKE_GROK_CALL_COUNT:-}" ]] && echo x >> "$FAKE_GROK_CALL_COUNT"
sleep "${FAKE_GROK_DELAY:-0}"
if [[ -n "${FAKE_GROK_ERROR:-}" ]]; then
  printf '{"type":"error","message":"%s"}\n' "${FAKE_GROK_ERROR}"
  exit 1
fi
# write-mode probe (2026-07-29, mirrors fake claude's FAKE_CLAUDE_WRITE_FILE at :114-115): writes a
# file RELATIVE to $PWD (never an absolute path baked into the knob), so a passing assertion proves
# lane_cmd's `env -C`/CDWRAP actually chdir'd this worker into the write target. Grok's own stream
# shape is otherwise unchanged.
if [[ -n "${FAKE_GROK_WRITE_FILE:-}" ]]; then
  printf '%s' "${FAKE_GROK_WRITE_CONTENT:-written}" > "$FAKE_GROK_WRITE_FILE"
fi
echo '{"type":"thought","data":"thinking..."}'
content="$(printf '%s' "${FAKE_GROK_RESULT:-grok OK}" | jq -Rs .)"
printf '{"type":"text","data":%s}\n' "$content"
if [[ -n "${FAKE_GROK_COST:-}" ]]; then
  printf '{"type":"end","stopReason":"EndTurn","sessionId":"s1","requestId":"r1","usage":{"input_tokens":787,"cache_read_input_tokens":2432,"output_tokens":32,"reasoning_tokens":28,"total_tokens":3251},"num_turns":1,"total_cost_usd":%s,"modelUsage":{"grok-4.5-build":{"inputTokens":787,"outputTokens":32,"cacheReadInputTokens":2432,"modelCalls":1,"costUSD":%s}}}\n' \
    "${FAKE_GROK_COST}" "${FAKE_GROK_COST}"
else
  printf '{"type":"end","stopReason":"EndTurn","sessionId":"s1","requestId":"r1","usage":{"input_tokens":787,"cache_read_input_tokens":2432,"output_tokens":32,"reasoning_tokens":28,"total_tokens":3251},"num_turns":1,"modelUsage":{"grok-4.5-build":{"inputTokens":787,"outputTokens":32,"cacheReadInputTokens":2432,"modelCalls":1}}}\n'
fi
exit "${FAKE_GROK_EXIT:-0}"
FAKE

  # spec 13 FR-2: fake curl for the glm/kimi/gemini doctor --live probes — no real network call.
  # Mirrors the real invocation's shape (-o <bodyfile>, -w '%{http_code}' on stdout): writes
  # FAKE_CURL_BODY to the -o target (when given) and prints FAKE_CURL_HTTP_CODE (default 200) on
  # stdout, or exits FAKE_CURL_RC (default 0, e.g. 28 = curl's own timeout code) before printing
  # anything — modeling a network failure distinct from a non-2xx HTTP response.
  cat > "$BIN/curl" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$_here/fake.conf" ]] && source "$_here/fake.conf"
[[ -n "${FAKE_CURL_CALLED_FILE:-}" ]] && echo "$*" >> "${FAKE_CURL_CALLED_FILE}"
# real curl reads headers from stdin for `-H @-`; drain it or the writing printf takes SIGPIPE and
# `set -o pipefail` in the caller reports a phantom failure. Headers land in FAKE_CURL_STDIN_FILE
# so a test can assert the key travelled OFF the command line.
if [[ ! -t 0 ]]; then
  if [[ -n "${FAKE_CURL_STDIN_FILE:-}" ]]; then cat >> "${FAKE_CURL_STDIN_FILE}"; else cat >/dev/null; fi
fi
outfile=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  [[ "${args[$i]}" == "-o" ]] && outfile="${args[$((i + 1))]}"
done
if [[ -n "${FAKE_CURL_RC:-0}" && "${FAKE_CURL_RC:-0}" != "0" ]]; then
  exit "${FAKE_CURL_RC}"
fi
[[ -n "$outfile" && "$outfile" != "/dev/null" ]] && printf '%s' "${FAKE_CURL_BODY:-{}}" > "$outfile"
printf '%s' "${FAKE_CURL_HTTP_CODE:-200}"
FAKE

  chmod +x "$BIN/claude" "$BIN/codex" "$BIN/gemini" "$BIN/docker" "$BIN/grok" "$BIN/curl"
}

_enqueue() {
  local id="$1" text="$2"
  mkdir -p "$BUS/specs"
  printf '%s' "$text" > "$BUS/specs/$id.prompt"
}

_write_conf() {
  cat > "$CONF" <<EOF
EXEC_CHAIN="${1:-claude:opus glm:glm-5.2}"
FANOUT=${2:-4}
LEASE_MIN=${3:-15}
EOF
}

# poll <max_seconds> <command...> — repeat command (0.2s apart) until it succeeds or times out.
_poll() {
  local max_seconds="$1"; shift
  local iterations=$(( max_seconds * 5 )) i
  for (( i = 0; i < iterations; i++ )); do
    "$@" >/dev/null 2>&1 && return 0
    sleep 0.2
  done
  return 1
}

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

# limit_active isn't on PATH as a command — probe it by sourcing the lib in a fresh bash.
limit_active_probe() {
  bash -c "source '$BATS_TEST_DIRNAME/../src/swarm-lib.sh'; limit_active '$1' '$2'"
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

  "$RUNSH" 3>&- &
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

@test "spec01 FR-A attribution: the generic retry/failover finalize-tail requeue names its own mover" {
  _write_conf "claude:opus gemini:gemini-3-flash"
  printf 'GEMINI_API_KEY=test-gem-key\n' > "$BATS_TEST_TMPDIR/envmaster"
  export ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster"
  _fake FAKE_CLAUDE_GARBAGE_COUNT "$BATS_TEST_TMPDIR/garbage-count-rc3"
  _fake FAKE_GEMINI_RESULT "rescued by gemini"
  _enqueue rc3 "spec rescued by failover, requeued via the generic finalize-tail"

  run timeout 25 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/rc3" ]
  [[ "$output" == *"mover=finalize-tail requeued rc3"*"retry/failover"* ]]
}

@test "SPEEDWARS_AUTO=0: a successful run writes no speedwars row even with SPEEDWARS_FILE set" {
  _write_conf "claude:opus" 4 15
  _fake FAKE_CLAUDE_RESULT "OK"
  _enqueue sw0 "speedwars off check"

  SPEEDWARS_AUTO=0 SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-off.jsonl" run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/sw-off.jsonl" ]
}

# --- spec10: role classes & universal fallback (plans/003-role-tier-fallback) -------------------
# RED wave (W1) — none of this exists in src/swarm-lib.sh or swarm-run.sh yet. queue/<id>.chain is
# never consulted by chain_current/chain_advance (only limits/.chain-<id> or $EXEC_CHAIN);
# kimi_budget_ok, lane_blocked, dead_flag, answer_unusable, and the write-card diff gate don't
# exist; limit_error has no claude/gemini arms; _print_config_table has no CLASS_REVIEW line.
# Every test below writes queue/<id>.chain DIRECTLY (mkdir -p "$BUS/queue" first) rather than via
# specs/<id>.chain + enqueue-time move — _enqueue_pending_specs only moves .lane/.write sidecars
# today, and seeding queue/ directly is robust either way once W2 adds .chain to that move too.

@test "spec10 FR-R2: queue/<id>.chain seed is honored — codex pre-limited, walk resolves to claude" {
  # Today: chain_current ignores queue/<id>.chain entirely and reads EXEC_CHAIN ("claude:opus")
  # instead, so codex is never even considered — the id claims straight onto claude:opus with no
  # skip/advance ever happening. "served by claude" and "run completes" pass by COINCIDENCE (single-
  # entry EXEC_CHAIN happens to be claude); the row assertions below are what actually catch the
  # missing behavior: today's speed_row `requested` field is the raw lane:model token it was called
  # with ("claude:opus"), never "codex", and it carries no fallback_reason field at all (FR-R9's
  # limits/.fbreason-<id> read doesn't exist in speed_row yet) — both jq assertions fail.
  _write_conf "claude:opus" 4 15
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-r2.jsonl"
  _fake FAKE_CLAUDE_RESULT "claude via chain seed"
  _enqueue r2a "chain seed check"
  mkdir -p "$BUS/queue" "$BUS/limits"
  printf '%s' "codex:default claude:sonnet" > "$BUS/queue/r2a.chain"
  printf '18000' > "$BUS/limits/codex.limited"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/r2a" ]
  [ "$(jq -r '.lane' "$BUS/done/r2a")" = "claude" ]
  [ "$(<"$BUS/res-r2a.txt")" = "claude via chain seed" ]
  # spec 12 FR-3: full_run now appends a trailing run-summary row (.type=="run-summary") to this
  # SAME file — select this branch's own row by id so that trailer never shadows the assertion.
  [ "$(jq -r 'select(.id=="r2a") | .requested' "$SPEEDWARS_FILE")" = "codex" ]
  [ "$(jq -r 'select(.id=="r2a") | .served_lane' "$SPEEDWARS_FILE")" = "claude" ]
  [ "$(jq -r 'select(.id=="r2a") | .fallback_reason' "$SPEEDWARS_FILE")" = "limit" ]
}

@test "spec10 FR-R5: kimi fallback declines when BUDGET_USD is already exceeded — parks loudly mentioning budget" {
  # Today: chain_current still ignores queue/<id>.chain and reads EXEC_CHAIN ("claude:opus", a
  # single entry). claude is pre-limited, so the existing skip loop in _try_claim_one advances past
  # it, finds the (single-entry) chain exhausted, and parks the id immediately — kimi_budget_ok
  # doesn't exist, "budget" never appears anywhere in swarm-run.sh/swarm-lib.sh output, so the
  # `[[ "$output" == *"budget"* ]]` assertion fails outright regardless of the (coincidentally
  # correct-looking) park/nonzero outcome.
  _write_conf "claude:opus" 4 15
  cat >> "$CONF" <<'EOF'
BUDGET_USD=0.02
EOF
  printf 'MOONSHOT_API_KEY=test-kimi-key\n' > "$BATS_TEST_TMPDIR/envmaster"
  export ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster"
  _enqueue r5a "budget gated review"
  mkdir -p "$BUS/queue" "$BUS/limits"
  printf '%s' "claude:sonnet kimi:kimi-k3" > "$BUS/queue/r5a.chain"
  printf '18000' > "$BUS/limits/claude.limited"
  printf '0.028' > "$BUS/limits/kimi.spend"

  run timeout 20 "$RUNSH"
  [ "$status" -ne 0 ]
  [[ "$output" == *"budget"* ]]
  [ -f "$BUS/limits/r5a.parked" ]
  [ ! -e "$BUS/done/r5a" ]
}

@test "spec10 FR-R5: BUDGET_USD=0 (unrestricted) — the same chain completes on kimi despite claude being limited" {
  # Today: chain_current ignores queue/<id>.chain and reads EXEC_CHAIN ("claude:opus" only) —
  # kimi is never even in the chain it walks. claude limited -> the single-entry chain is
  # exhausted -> the id parks (status nonzero, no done/). Test expects status 0 with done/r5b
  # served by kimi, so this fails outright on both the exit status and the missing done marker.
  _write_conf "claude:opus" 4 15
  cat >> "$CONF" <<'EOF'
BUDGET_USD=0
EOF
  printf 'MOONSHOT_API_KEY=test-kimi-key\n' > "$BATS_TEST_TMPDIR/envmaster"
  export ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster"
  _fake FAKE_CLAUDE_RESULT "kimi via budget-open chain"
  _enqueue r5b "budget open review"
  mkdir -p "$BUS/queue" "$BUS/limits"
  printf '%s' "claude:sonnet kimi:kimi-k3" > "$BUS/queue/r5b.chain"
  printf '18000' > "$BUS/limits/claude.limited"
  printf '0.028' > "$BUS/limits/kimi.spend"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/r5b" ]
  [ "$(jq -r '.lane' "$BUS/done/r5b")" = "kimi" ]
  [ "$(<"$BUS/res-r5b.txt")" = "kimi via budget-open chain" ]
}

@test "spec10 FR-R6: pinned card whose lane is limited bounded-waits then parks within PIN_WAIT_SEC, not the TTL" {
  # Today: the PINNED branch of _try_claim_one only checks limit_active (not the new lane_blocked)
  # and, on a hit, just `continue`s — no waiting marker, no stderr notice, no park. With glm.limited
  # fresh (TTL 18000s) it silently re-polls (sleep 1) forever; `timeout 20` kills the run at ~20s
  # (SIGTERM — _sweep_on_driver_term's trap exits the script itself, so $status ends up nonzero
  # incidentally, same as a genuine park would look). The assertions that actually catch the missing
  # behavior are the ones below the exit-status check: limits/r6a.parked never appears and neither
  # "waiting" nor "parking" is ever printed, since the engine never reaches that new code path at all.
  _write_conf "claude:opus" 4 15
  cat >> "$CONF" <<'EOF'
PIN_WAIT_SEC=2
EOF
  printf 'Z_AI_CODING_KEY=test-glm-key\n' > "$BATS_TEST_TMPDIR/envmaster"
  export ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster"
  _enqueue r6a "pinned glm, pre-limited"
  echo "glm:glm-5.2" > "$BUS/specs/r6a.lane"
  mkdir -p "$BUS/limits"
  printf '18000' > "$BUS/limits/glm.limited"

  run timeout 20 "$RUNSH"
  [ "$status" -ne 0 ]
  [ -f "$BUS/limits/r6a.parked" ]
  [[ "$output" == *"waiting"* || "$output" == *"parking"* ]]
  [ ! -e "$BUS/done/r6a" ]
}

@test "spec10 FR-R6: pinned lane's TTL expiring under a generous PIN_WAIT_SEC lets the run complete, never parked" {
  # Today: PIN_WAIT_SEC doesn't exist as a concept at all — the pinned branch relies solely on
  # limit_active's own TTL (5s here — 1s flaked under full-suite load: startup could outlive the
  # TTL before the engine's first limit_active check, so the waiting notice never printed), which
  # ALREADY makes this scenario complete without parking
  # under current code (no new behavior needed for that half). The one assertion that's actually new
  # and fails today: FR-R6 requires exactly one "waiting on limited pinned lane"-style stderr notice
  # AT MARKER CREATION regardless of how quickly the TTL then clears — that text does not exist
  # anywhere in swarm-run.sh today, so `[[ "$output" == *"waiting"* ]]` fails deterministically.
  _write_conf "claude:opus" 4 15
  cat >> "$CONF" <<'EOF'
PIN_WAIT_SEC=60
EOF
  printf 'Z_AI_CODING_KEY=test-glm-key\n' > "$BATS_TEST_TMPDIR/envmaster"
  export ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster"
  _fake FAKE_CLAUDE_RESULT "glm via child-env swap"
  _enqueue r6b "pinned glm, TTL expires fast"
  echo "glm:glm-5.2" > "$BUS/specs/r6b.lane"
  mkdir -p "$BUS/limits"
  printf '5' > "$BUS/limits/glm.limited"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/r6b" ]
  [ ! -e "$BUS/limits/r6b.parked" ]
  [[ "$output" == *"waiting"* ]]
}

@test "spec10 FR-R7: class-exhausted review chain (both members limited) parks loudly with 'exhausted' in stderr, no res file" {
  # Today: same root cause as FR-R2/R5 — chain_current ignores queue/<id>.chain and falls back to
  # EXEC_CHAIN ("claude:opus"), which contains neither codex nor kimi and isn't limited at all. The
  # id claims straight onto claude, the fake answers "OK" by default, and the branch completes
  # normally (status 0, res-r7a.txt written) — the exact opposite of every assertion below, and
  # "exhausted" never appears in the output since chain_advance's real exhaustion path is never hit.
  _write_conf "claude:opus" 4 15
  _enqueue r7a "both review lanes limited"
  mkdir -p "$BUS/queue" "$BUS/limits"
  printf '%s' "codex:default kimi:kimi-k3" > "$BUS/queue/r7a.chain"
  printf '18000' > "$BUS/limits/codex.limited"
  printf '18000' > "$BUS/limits/kimi.limited"

  run timeout 20 "$RUNSH"
  [ "$status" -ne 0 ]
  [[ "$output" == *"exhausted"* ]]
  [ -f "$BUS/limits/r7a.parked" ]
  [ ! -e "$BUS/res-r7a.txt" ]
}

@test "spec10 FR-R8: claude OAuth-death answer (cal056 false-done shape) sets claude.dead and fails over to codex, not trusted as done" {
  # Today: limit_error's claude case doesn't exist (falls into the bare `*) return 0` catch-all) and
  # answer_unusable/dead_flag don't exist at all. The fake's "autherr" once-mode (added by this wave)
  # emits a NORMAL result envelope with no error/turn.failed event, so extract_answer succeeds and
  # _finalize_worker's success branch takes it as a real "done" — on claude, with the auth-error text
  # as the "answer". limits/claude.dead is never created; done/r8a.lane is "claude", not "codex".
  _write_conf "claude:opus codex:default" 4 15
  _fake FAKE_CLAUDE_ONCE_MARKER "$BATS_TEST_TMPDIR/r8-once"
  _fake FAKE_CLAUDE_ONCE_MODE autherr
  _fake FAKE_CODEX_RESULT "codex rescued it"
  _enqueue r8a "claude auth-death branch"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/r8a" ]
  [ "$(jq -r '.lane' "$BUS/done/r8a")" = "codex" ]
  [ "$(<"$BUS/res-r8a.txt")" = "codex rescued it" ]
  [ -f "$BUS/limits/claude.dead" ]
}

@test "spec10 FR-R11: write-card diff gate rejects a served 'done' that touched nothing under the target — retries then parks" {
  # Today: _finalize_worker's success branch has no diff gate at all (no limits/<id>.stamp, no
  # `find -newer`) — extract_answer succeeds trivially on the fake's claimed-done text and the
  # branch is finalized as done regardless of whether the write target was ever touched. done/r11a
  # exists, status is 0, and the target stays empty — the opposite of every assertion below.
  _write_conf "claude:opus" 4 15
  local target="$BATS_TEST_TMPDIR/r11target"
  mkdir -p "$target"
  # The gate tolerates ~2s of pre-spawn mtime slack (backdated stamp + granule-safe -newermt) so
  # same-second WRITES are never missed; a target dir mkdir'd microseconds before spawn would sit
  # inside that window and read as "changed". This card's scenario is a PRE-EXISTING target the
  # worker never touched — pin the fixture's mtime accordingly.
  touch -d '10 seconds ago' "$target"
  _fake FAKE_CLAUDE_RESULT "claims done but wrote nothing"
  _enqueue r11a "write card whose worker writes nothing"
  printf '%s' "$target" > "$BUS/specs/r11a.write"

  run timeout 25 "$RUNSH"
  [ "$status" -ne 0 ]
  [ ! -e "$BUS/done/r11a" ]
  [ -f "$BUS/limits/r11a.parked" ]
  [ -z "$(find "$target" -mindepth 1 2>/dev/null)" ]
}

@test "spec10 FR-R11: write-card diff-gate stamp is touched pre-spawn, and a real write still finalizes done" {
  # Today: limits/<id>.stamp (FR-R11's "touch immediately before invoking the lane command") is
  # never created anywhere in _spawn_worker — the poll below times out (stamp file never appears)
  # and the first assertion fails. This is the RED-wave-valid form of the "control" case from the
  # build contract: a plain "FAKE_CLAUDE_WRITE_FILE set -> done normally" assertion would already
  # pass unmodified today (no diff gate exists to reject anything yet), so it wouldn't demonstrate
  # anything new — polling for the pre-spawn stamp is what actually exercises FR-R11's new plumbing.
  _write_conf "claude:opus" 4 15
  local target="$BATS_TEST_TMPDIR/r11target-ok"
  mkdir -p "$target"
  _fake FAKE_CLAUDE_DELAY 2
  _fake FAKE_CLAUDE_RESULT "wrote it for real"
  _fake FAKE_CLAUDE_WRITE_FILE "created.txt"
  _enqueue r11b "write card whose worker writes for real"
  printf '%s' "$target" > "$BUS/specs/r11b.write"

  "$RUNSH" 3>&- &
  BG_PIDS+=("$!")

  _poll 15 test -f "$BUS/limits/r11b.stamp"
  [ -f "$BUS/limits/r11b.stamp" ]

  _poll 20 test -f "$BUS/done/r11b"
  [ -f "$BUS/done/r11b" ]
  [ -f "$target/created.txt" ]

  wait "${BG_PIDS[0]}"
  BG_PIDS=()
}

@test "spec10 FR-R10: a completed kimi-pinned card accumulates real-dollar limits/kimi.spend and speedwars billing:real" {
  # Today: _kimi_spend_add doesn't exist and _finalize_worker's success branch never touches
  # limits/kimi.spend at all — the file is never created, so the existence check fails outright.
  # speed_row also emits no "billing" field today (FR-R10 in src/swarm-lib.sh not yet wired), so the
  # jq read on a missing field returns "null", never "real".
  _write_conf "claude:opus" 4 15
  printf 'MOONSHOT_API_KEY=test-kimi-key\n' > "$BATS_TEST_TMPDIR/envmaster"
  export ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster"
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-r10.jsonl"
  _fake FAKE_CLAUDE_RESULT "kimi spend check"
  _fake FAKE_CLAUDE_USAGE_JSON '{"input_tokens":100000,"output_tokens":10000,"cache_read_input_tokens":0}'
  _enqueue r10a "kimi spend accumulation check"
  echo "kimi:kimi-k3" > "$BUS/specs/r10a.lane"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/r10a" ]
  [ -f "$BUS/limits/kimi.spend" ]
  awk -v s="$(<"$BUS/limits/kimi.spend")" 'BEGIN { exit !(s > 0) }'
  # spec 12 FR-3: full_run's trailing run-summary row shares this file — select by id.
  [ "$(jq -r 'select(.id=="r10a") | .billing' "$SPEEDWARS_FILE")" = "real" ]
}

@test "spec10 FR-R13: swarm-run config prints CLASS_REVIEW members' live limited/available state" {
  # Today: _print_config_table (swarm-run.sh) prints only the existing PLAN/ORCHESTRATOR/REVIEW/
  # EXEC_CHAIN/... table — no CLASS_REVIEW line at all, and CLASS_REVIEW isn't even a conf_load key
  # yet. The regex match below finds nothing in $output and fails outright.
  _write_conf "claude:opus" 4 15
  mkdir -p "$BUS/limits"
  printf '18000' > "$BUS/limits/kimi.limited"

  run "$RUNSH" config
  [ "$status" -eq 0 ]
  [[ "$output" =~ CLASS_REVIEW:\ codex\(available\)\ kimi\(limited\ [0-9]+m\) ]]
}

@test "spec14 FR-7 regression: _flag_mins_left computes minutes-left from a new-format reason-line marker as well as a legacy bare-digit one" {
  # Before the fix, _flag_mins_left read the whole marker file as the raw TTL — a FR-7 reason line
  # ("<ISO8601> | <token> | retryable=.. | ttl=.. | text") is not all-digits, so the arithmetic
  # context `$(( ttl - ... ))` died outright ("value too great for base"), crashing `config` under
  # errexit the moment any lane carried a new-format marker.
  _write_conf "claude:opus" 4 15
  mkdir -p "$BUS/limits"
  printf '2026-01-01T00:00:00Z | session-limit | retryable=1 | ttl=3600 | lane kimi rate-limited\n' > "$BUS/limits/kimi.limited"
  printf '1800' > "$BUS/limits/codex.broken"

  run "$RUNSH" config
  [ "$status" -eq 0 ]
  [[ "$output" =~ CLASS_REVIEW:\ codex\(broken\ [0-9]+m\)\ kimi\(limited\ [0-9]+m\) ]]
}

@test "spec10 CRIT-regression: mid-flight auth-death on a chain-SEEDED card fails over without crashing the pool driver" {
  # final-reviewer CRITICAL 2026-07-24: queue/<id>.chain files carry no trailing newline
  # (printf '%s'), and _orig_chain_bare's bare `read -r < file` returned rc1 at newline-less
  # EOF — under set -e via _finalize_worker's UNGUARDED call, the whole pool driver died on the
  # first mid-flight limit/dead of a chain-seeded card, orphaning every other in-flight worker.
  # Every other FR-R2/R5/R6/R7 test pre-blocks the lane BEFORE claim; this one fails DURING.
  _write_conf "claude:opus" 4 15
  printf 'MOONSHOT_API_KEY=test-kimi-key\n' > "$BATS_TEST_TMPDIR/envmaster"
  export ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster"
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/speedwars.jsonl"
  _enqueue crm "chain-seeded card whose first lane dies mid-run"
  # No trailing newline — the exact on-disk shape swarm-loop's cmd_iterate produces.
  printf '%s' "claude:opus codex:default" > "$BUS/specs/crm.chain"
  _fake FAKE_CLAUDE_ONCE_MARKER "$BATS_TEST_TMPDIR/crm-once"
  _fake FAKE_CLAUDE_ONCE_MODE autherr
  _fake FAKE_CODEX_RESULT "codex rescued it"

  run timeout 30 "$RUNSH"
  [ "$status" -eq 0 ]                                   # driver survived — no errexit crash
  [ -f "$BUS/done/crm" ]
  [ "$(jq -r '.lane' "$BUS/done/crm")" = "codex" ]      # failed over mid-flight
  [ -f "$BUS/limits/claude.dead" ]                      # auth-death flagged
  run jq -r 'select(.id=="crm" and .outcome=="done") | .fallback_reason' "$SPEEDWARS_FILE"
  [[ "$output" == *"dead"* ]]                           # mid-flight provenance survived (FR-R9)
}

# --- backlog 28/29/30 (round3 red wave) ---
# No existing test in this file asserted the OLD FR-12 timeout contract text ("killed, flagging")
# or that a timeout ever created limits/<lane>.limited — grepped the whole file before writing
# these; nothing pre-existing needed updating for backlog-30's contract change.

@test "backlog-29: .write target inside .claude/ is refused at claim time — parks loudly, never spawns, no lane cooled" {
  _write_conf "claude:opus" 4 15
  local target="$BATS_TEST_TMPDIR/tgt/.claude/skills/foo"
  mkdir -p "$target"
  _enqueue cw1 "attempt to write into .claude"
  printf '%s' "$target" > "$BUS/specs/cw1.write"

  run timeout 20 "$RUNSH"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cw1 refused — write target '$target' is an orchestrator-owned .claude/ surface; parking"* ]]
  [ -f "$BUS/limits/cw1.parked" ]
  [ ! -e "$BUS/done/cw1" ]
  [ ! -e "$BUS/run-cw1.jsonl" ]
  [ -z "$(find "$BUS/limits" -maxdepth 1 -name '*.limited' 2>/dev/null)" ]
}

@test "backlog-29: control — a .write target containing a .claude-lookalike path component is not refused" {
  _write_conf "claude:opus" 4 15
  local target="$BATS_TEST_TMPDIR/.claudette"
  mkdir -p "$target"
  _fake FAKE_CLAUDE_RESULT "wrote it"
  _fake FAKE_CLAUDE_WRITE_FILE "created.txt"
  _fake FAKE_CLAUDE_WRITE_CONTENT "hello from worker"
  _enqueue cw2 "write into a lookalike dir"
  printf '%s' "$target" > "$BUS/specs/cw2.write"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/cw2" ]
  [ "$(<"$BUS/res-cw2.txt")" = "wrote it" ]
  [ -f "$target/created.txt" ]
  [ "$(<"$target/created.txt")" = "hello from worker" ]
}

@test "backlog-29: .write target reaching .claude/ THROUGH a symlink is refused at claim time (realpath canonicalization)" {
  # Pins the symlink-hardening arm of the claim-time refusal: the raw path 'cc' never matches the
  # literal .claude regex — only the realpath-canonicalized spelling does. Without canonicalization
  # this card would spawn a worker into an orchestrator-owned surface.
  _write_conf "claude:opus" 4 15
  local repo="$BATS_TEST_TMPDIR/symtgt"
  mkdir -p "$repo/.claude"
  ln -s .claude "$repo/cc"
  _enqueue cw3 "attempt to write into .claude through a symlink"
  printf '%s' "$repo/cc" > "$BUS/specs/cw3.write"

  run timeout 20 "$RUNSH"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cw3 refused — write target '$repo/cc' is an orchestrator-owned .claude/ surface; parking"* ]]
  [ -f "$BUS/limits/cw3.parked" ]
  [ ! -e "$BUS/done/cw3" ]
  [ ! -e "$BUS/run-cw3.jsonl" ]
}

@test "backlog-30: watchdog-killed attempt never cools the lane — no .limited flag, branch still fails over" {
  # Mirrors the FR-12 hung-worker test's 2-lane chain/knobs, but asserts the NEW contract: the
  # killed lane must come out of this with no limits/<lane>.limited (a kill-truncated stream isn't
  # limit evidence), and the stderr wording drops "flagging" for "failing over".
  _write_conf "claude:opus glm:glm-5.2" 4 15
  cat >> "$CONF" <<'EOF'
WORKER_TIMEOUT_SEC=2
EOF
  printf 'Z_AI_CODING_KEY=test-glm-key\n' > "$BATS_TEST_TMPDIR/envmaster"
  export ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster"
  _fake FAKE_CLAUDE_ONCE_MARKER "$BATS_TEST_TMPDIR/b30-once"
  _fake FAKE_CLAUDE_ONCE_MODE hang
  _enqueue b30a "branch whose claude hangs forever"

  run timeout 25 "$RUNSH"
  [ "$status" -eq 0 ]

  [ -f "$BUS/done/b30a" ]
  [ "$(jq -r '.lane' "$BUS/done/b30a")" = "glm" ]
  [ "$(<"$BUS/res-b30a.txt")" = "OK" ]
  [ ! -e "$BUS/limits/claude.limited" ]
  [[ "$output" == *"exceeded WORKER_TIMEOUT_SEC — killed, failing over"* ]]
  [[ "$output" != *"killed, flagging"* ]]
}

# --- backlog 17+10: watchdog timeout salvage (specs/01 FR-12 amendment 2026-07-25) -------------
# A SIGKILLed worker's on-disk work is salvaged FINALIZE-side: best-effort handoff extraction over
# the partial run log + the success path's own write-card diff gate. Genuine work -> done with
# outcome "timeout-salvaged"; nothing usable -> today's failover, byte-identical.

@test "backlog 17+10: a read card that answered before the watchdog kill is salvaged as done, not discarded" {
  # Today: the timeout path discards everything on disk unconditionally — the branch chain-advances
  # off the (single-lane) chain, parks, and the answer that WAS already in run-sv1.jsonl is lost.
  _write_conf "claude:opus" 4 15
  cat >> "$CONF" <<'EOF'
WORKER_TIMEOUT_SEC=2
EOF
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-sv1.jsonl"
  _fake FAKE_CLAUDE_ONCE_MARKER "$BATS_TEST_TMPDIR/sv1-once"
  _fake FAKE_CLAUDE_ONCE_MODE answerhang
  _fake FAKE_CLAUDE_SALVAGE_RESULT "answer landed before the kill"
  _enqueue sv1 "read card whose worker answers then hangs"

  run timeout 25 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/sv1" ]
  [ ! -e "$BUS/limits/sv1.parked" ]
  [ "$(<"$BUS/res-sv1.txt")" = "answer landed before the kill" ]
  [ "$(jq -r '.lane' "$BUS/done/sv1")" = "claude" ]
  # FR-2: the REAL worker rc — a SIGKILLed subtree is never 0
  [ "$(jq -r '.code' "$BUS/done/sv1")" -ne 0 ]
  [ -f "$BUS/prompt-sv1.txt" ]
  # qualified success: its own outcome, and NO failure class (absence-means-absent, like done rows)
  [ "$(jq -r 'select(.id=="sv1") | .outcome' "$SPEEDWARS_FILE")" = "timeout-salvaged" ]
  [ "$(jq -r 'select(.id=="sv1") | has("class")' "$SPEEDWARS_FILE")" = "false" ]
  # the bus is fully cleaned, exactly as on the success path — no claim, no sidecar, nothing requeued
  [ -z "$(find "$BUS/claimed" "$BUS/queue" -mindepth 1 2>/dev/null)" ]
}

@test "backlog 17+10: a timed-out partial whose answer is unusable is discarded — failover, never salvaged" {
  # The salvage gate must not resurrect an auth-death dump as an answer: extract_answer succeeds on
  # that envelope (it IS a well-formed result), answer_unusable rejects it, res is discarded and the
  # branch takes today's timeout failover to codex.
  _write_conf "claude:opus codex:default" 4 15
  cat >> "$CONF" <<'EOF'
WORKER_TIMEOUT_SEC=2
EOF
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-sv2.jsonl"
  _fake FAKE_CLAUDE_ONCE_MARKER "$BATS_TEST_TMPDIR/sv2-once"
  _fake FAKE_CLAUDE_ONCE_MODE answerhang
  _fake FAKE_CLAUDE_SALVAGE_RESULT "OAuth session expired - Please run /login"
  _fake FAKE_CODEX_RESULT "codex rescued it"
  _enqueue sv2 "read card whose partial answer is an auth-death dump"

  run timeout 25 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/sv2" ]
  [ "$(jq -r '.lane' "$BUS/done/sv2")" = "codex" ]
  [ "$(<"$BUS/res-sv2.txt")" = "codex rescued it" ]
  [ "$(jq -r 'select(.id=="sv2" and .served_lane=="claude") | .outcome' "$SPEEDWARS_FILE")" = "timeout" ]
  [ "$(jq -r 'select(.id=="sv2" and .served_lane=="claude") | .class' "$SPEEDWARS_FILE")" = "timeout-watchdog" ]
}

@test "backlog 17+10: a timed-out write card whose target changed is salvaged done with provenance archived" {
  # backlog-10's exact incident: killed during handoff with ALL work already on disk. No handoff
  # ever landed (no res file) — the diff against limits/<id>.stamp IS the evidence.
  _write_conf "claude:opus" 4 15
  cat >> "$CONF" <<'EOF'
WORKER_TIMEOUT_SEC=2
EOF
  local target="$BATS_TEST_TMPDIR/sv3target"
  mkdir -p "$target"
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-sv3.jsonl"
  _fake FAKE_CLAUDE_ONCE_MARKER "$BATS_TEST_TMPDIR/sv3-once"
  _fake FAKE_CLAUDE_ONCE_MODE hang
  _fake FAKE_CLAUDE_WRITE_FILE "created.txt"
  _fake FAKE_CLAUDE_WRITE_CONTENT "real work on disk"
  _enqueue sv3 "write card killed after its work landed"
  printf '%s' "$target" > "$BUS/specs/sv3.write"

  run timeout 25 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/sv3" ]
  [ "$(<"$target/created.txt")" = "real work on disk" ]
  [ ! -e "$BUS/res-sv3.txt" ]
  # verify-wave provenance, same as the success path archives it
  [ "$(<"$BUS/write-sv3.txt")" = "$target" ]
  [ -f "$BUS/prompt-sv3.txt" ]
  [ -f "$BUS/limits/sv3.stamp" ]
  [ ! -e "$BUS/queue/sv3.write" ]
  [ -z "$(find "$BUS/claimed" "$BUS/queue" -mindepth 1 2>/dev/null)" ]
  [ "$(jq -r 'select(.id=="sv3") | .outcome' "$SPEEDWARS_FILE")" = "timeout-salvaged" ]
}

@test "backlog 17+10: a timed-out write card whose target never changed keeps today's failover" {
  _write_conf "claude:opus" 4 15
  cat >> "$CONF" <<'EOF'
WORKER_TIMEOUT_SEC=2
EOF
  local target="$BATS_TEST_TMPDIR/sv4target"
  mkdir -p "$target"
  # pre-existing, untouched target — outside the gate's ~2s pre-spawn mtime slack
  touch -d '10 seconds ago' "$target"
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-sv4.jsonl"
  _fake FAKE_CLAUDE_ONCE_MARKER "$BATS_TEST_TMPDIR/sv4-once"
  _fake FAKE_CLAUDE_ONCE_MODE hang
  _enqueue sv4 "write card killed having written nothing"
  printf '%s' "$target" > "$BUS/specs/sv4.write"

  run timeout 25 "$RUNSH"
  [ "$status" -ne 0 ]
  [ ! -e "$BUS/done/sv4" ]
  [ -f "$BUS/limits/sv4.parked" ]
  [ "$(jq -r 'select(.id=="sv4" and .outcome=="timeout") | .class' "$SPEEDWARS_FILE")" = "timeout-watchdog" ]
}

@test "backlog 17+10: TIMEOUT_SALVAGE=0 restores today's discard-everything timeout behavior" {
  _write_conf "claude:opus" 4 15
  cat >> "$CONF" <<'EOF'
WORKER_TIMEOUT_SEC=2
EOF
  export TIMEOUT_SALVAGE=0
  _fake FAKE_CLAUDE_ONCE_MARKER "$BATS_TEST_TMPDIR/sv5-once"
  _fake FAKE_CLAUDE_ONCE_MODE answerhang
  _fake FAKE_CLAUDE_SALVAGE_RESULT "answer landed before the kill"
  _enqueue sv5 "read card whose worker answers then hangs, salvage disabled"

  run timeout 25 "$RUNSH"
  [ "$status" -ne 0 ]
  [ ! -e "$BUS/done/sv5" ]
  [ ! -e "$BUS/res-sv5.txt" ]
  [ -f "$BUS/limits/sv5.parked" ]
}

@test "backlog-28-run: success finalize archives write-card provenance — write-<id>.txt saved, limits/<id>.stamp survives" {
  _write_conf "claude:opus" 4 15
  local target="$BATS_TEST_TMPDIR/writetarget-b28"
  mkdir -p "$target"
  _fake FAKE_CLAUDE_RESULT "wrote it"
  _fake FAKE_CLAUDE_WRITE_FILE "created.txt"
  _fake FAKE_CLAUDE_WRITE_CONTENT "hello"
  _enqueue b28a "write card for provenance archive"
  printf '%s' "$target" > "$BUS/specs/b28a.write"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]

  [ -f "$BUS/done/b28a" ]
  [ -f "$BUS/write-b28a.txt" ]
  [ "$(<"$BUS/write-b28a.txt")" = "$target" ]
  [ -f "$BUS/limits/b28a.stamp" ]
  # non-repo target: the spawn-time git-baseline capture is best-effort — leaves NO .base file
  [ ! -e "$BUS/limits/b28a.base" ]
}

@test "backlog-28-run: write card on a git-repo target records pre-spawn HEAD as limits/<id>.base (diff baseline)" {
  # Today: _spawn_worker only touches limits/<id>.stamp — no .base is ever written, so
  # _write_card_diff_section falls back to deriving the baseline from commit dates. The exact
  # pre-spawn sha is the lossless form; assert the spawner records it.
  _write_conf "claude:opus" 4 15
  local target="$BATS_TEST_TMPDIR/basetgt"
  mkdir -p "$target"
  git -C "$target" init -q
  git -C "$target" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  local head; head="$(git -C "$target" rev-parse HEAD)"
  _fake FAKE_CLAUDE_RESULT "wrote it"
  _fake FAKE_CLAUDE_WRITE_FILE "created.txt"
  _enqueue gb1 "write card into a git repo"
  printf '%s' "$target" > "$BUS/specs/gb1.write"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/gb1" ]
  [ -f "$BUS/limits/gb1.base" ]
  [ "$(<"$BUS/limits/gb1.base")" = "$head" ]
}

@test "spec10 FR-R11 granularity: a write landing in the stamp's own mtime granule still finalizes done" {
  # Models a coarse-mtime fs: the fake pins its written file's AND the target dir's mtime to
  # exactly the stamp's (touch -r) — with the strictly-newer `find -newer stamp` gate, nothing in
  # the target reads as changed and a GENUINE write is false-rejected into a park. The fixed gate
  # (-newermt against stamp-epoch-minus-1s, stamp itself backdated 1s at spawn) must finalize done.
  _write_conf "claude:opus" 4 15
  local target="$BATS_TEST_TMPDIR/grantgt"
  mkdir -p "$target"
  _fake FAKE_CLAUDE_RESULT "wrote it in the same second"
  _fake FAKE_CLAUDE_WRITE_FILE "created.txt"
  _fake FAKE_CLAUDE_WRITE_TOUCH_REF "$BUS/limits/gr1.stamp"
  _enqueue gr1 "write card whose write lands in the stamp's mtime granule"
  printf '%s' "$target" > "$BUS/specs/gr1.write"

  run timeout 25 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/gr1" ]
  [ ! -e "$BUS/limits/gr1.parked" ]
  [ -f "$target/created.txt" ]
}

# --- spec 11 degraded finalize (round3 red wave) ---
# FR-S4: while $BUSDIR/orch-seat exists with a non-fable first field, every finalize record and
# speedwars row carries degraded:true; under fable (or no seat file) the key is entirely absent.
# Today: neither done/<id> nor speed_row emit a degraded field at all, and the FR-R6 pinned-park
# path never writes a speedwars parked row — so the positive-degraded assertions fail.

@test "spec11: degraded done — non-fable orch-seat stamps done record and speedwars done row" {
  # Today: finalize writes '{"id","code","lane"}' only (no degraded), and speed_row's jq object
  # has no degraded key — both `== true` checks fail even though the one-lane happy path completes.
  _write_conf "claude:opus" 4 15
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-s11-done.jsonl"
  _fake FAKE_CLAUDE_RESULT "OK"
  _enqueue s11d "degraded done under kimi seat"
  mkdir -p "$BUS"
  printf 'kimi 1753000000' > "$BUS/orch-seat"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/s11d" ]
  [ "$(jq -r '.degraded' "$BUS/done/s11d")" = "true" ]
  [ "$(jq -r 'select(.id=="s11d" and .outcome=="done") | .degraded' "$SPEEDWARS_FILE")" = "true" ]
}

@test "spec11: non-degraded control — no orch-seat omits degraded key on done and speedwars" {
  # Contract half under Fable / no seat: the key must be entirely absent (not false). Today this
  # already holds because no producer emits degraded — kept as the RED-wave control so a GREEN
  # that always stamps degraded:true is caught.
  _write_conf "claude:opus" 4 15
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-s11-ctrl.jsonl"
  _fake FAKE_CLAUDE_RESULT "OK"
  _enqueue s11c "non-degraded control, no seat file"
  [ ! -e "$BUS/orch-seat" ]

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/s11c" ]
  [ "$(jq 'has("degraded")' "$BUS/done/s11c")" = "false" ]
  [ "$(jq 'select(.id=="s11c" and .outcome=="done") | has("degraded")' "$SPEEDWARS_FILE")" = "false" ]
}

@test "spec11: degraded park — non-fable orch-seat stamps speedwars parked row" {
  # Must use a park path that actually emits a speedwars row: FR-R7 class-exhaust (chain both
  # members limited) calls speed_row with outcome=parked. The FR-R6 pinned-park path only touches
  # limits/<id>.parked and never writes SPEEDWARS_FILE — wiring SPEEDWARS_FILE there would assert
  # against a file the engine never creates (red-wave wrinkle). speed_row itself stamps degraded
  # when orch-seat is non-fable (parallel FR-S4 card); this test only needs the seat + exhaust.
  _write_conf "claude:opus" 4 15
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-s11-park.jsonl"
  _enqueue s11p "chain exhausted, degraded park"
  mkdir -p "$BUS/queue" "$BUS/limits"
  printf '%s' "codex:default kimi:kimi-k3" > "$BUS/queue/s11p.chain"
  printf '18000' > "$BUS/limits/codex.limited"
  printf '18000' > "$BUS/limits/kimi.limited"
  printf 'kimi 1753000000' > "$BUS/orch-seat"

  run timeout 20 "$RUNSH"
  [ "$status" -ne 0 ]
  [ -f "$BUS/limits/s11p.parked" ]
  [ ! -e "$BUS/done/s11p" ]
  [ "$(jq -r 'select(.id=="s11p" and .outcome=="parked") | .degraded' "$SPEEDWARS_FILE")" = "true" ]
}

# --- spec 12: failure-class vocabulary (FR-1), real done rc (FR-2), run_summary (FR-3) -----------

@test "spec12 FR-1: a timed-out worker's speedwars row carries class timeout-watchdog" {
  _write_conf "claude:opus glm:glm-5.2" 4 15
  cat >> "$CONF" <<'EOF'
WORKER_TIMEOUT_SEC=2
EOF
  printf 'Z_AI_CODING_KEY=test-glm-key\n' > "$BATS_TEST_TMPDIR/envmaster"
  export ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster"
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-c12wd.jsonl"
  _fake FAKE_CLAUDE_ONCE_MARKER "$BATS_TEST_TMPDIR/c12wd-once"
  _fake FAKE_CLAUDE_ONCE_MODE hang
  _enqueue c12wd "branch whose claude hangs forever"

  run timeout 25 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/c12wd" ]
  [ "$(jq -r 'select(.id=="c12wd" and .outcome=="timeout") | .class' "$SPEEDWARS_FILE")" = "timeout-watchdog" ]
}

@test "spec12 FR-1: a lane_cmd spawn failure (wrc==9, no usable key) speedwars row carries class spawn-fail" {
  _write_conf "glm:glm-5.2 claude:opus"
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-c12sf.jsonl"
  _enqueue c12sf "branch with no glm key"
  # spec 13 FR-1: a READABLE file simply missing glm's key (not an unreadable path — that's the
  # dedicated launch-preflight scenario now) is still this test's own intent: a normal spawn-time
  # lane_cmd failure.
  printf 'UNRELATED_KEY=x\n' > "$BATS_TEST_TMPDIR/envmaster-nk"
  export ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster-nk"
  _fake FAKE_CLAUDE_RESULT "fallback answer"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/c12sf" ]
  [ "$(jq -r 'select(.id=="c12sf" and .outcome=="lane-unusable") | .class' "$SPEEDWARS_FILE")" = "spawn-fail" ]
}

@test "spec12 FR-1: write-card diff-gate rejection rows carry class false-done" {
  _write_conf "claude:opus" 4 15
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-c12fd.jsonl"
  local target="$BATS_TEST_TMPDIR/c12fd-target"
  mkdir -p "$target"
  touch -d '10 seconds ago' "$target"
  _fake FAKE_CLAUDE_RESULT "claims done but wrote nothing"
  _enqueue c12fd "write card whose worker writes nothing"
  printf '%s' "$target" > "$BUS/specs/c12fd.write"

  run timeout 25 "$RUNSH"
  [ "$status" -ne 0 ]
  [ -f "$BUS/limits/c12fd.parked" ]
  [ -n "$(jq -r 'select(.id=="c12fd" and .class=="false-done") | .id' "$SPEEDWARS_FILE")" ]
}

@test "spec12 FR-1: a mid-flight auth-death failover row carries class auth-death; the eventual done row carries none" {
  _write_conf "claude:opus codex:default" 4 15
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-c12ad.jsonl"
  _fake FAKE_CLAUDE_ONCE_MARKER "$BATS_TEST_TMPDIR/c12ad-once"
  _fake FAKE_CLAUDE_ONCE_MODE autherr
  _fake FAKE_CODEX_RESULT "codex rescued it"
  _enqueue c12ad "claude auth-death branch"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/c12ad" ]
  [ "$(jq -r 'select(.id=="c12ad" and .served_lane=="claude") | .class' "$SPEEDWARS_FILE")" = "auth-death" ]
  [ "$(jq -r 'select(.id=="c12ad" and .outcome=="done") | has("class")' "$SPEEDWARS_FILE")" = "false" ]
}

@test "spec12 FR-1: a rate-limited (not dead) failover row carries class rate-limit" {
  _write_conf "glm:glm-5.2 claude:opus"
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-c12rl.jsonl"
  _enqueue c12rl "branch needing failover"
  printf 'Z_AI_CODING_KEY=test-glm-key\n' > "$BATS_TEST_TMPDIR/envmaster"
  export ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster"
  _fake FAKE_CLAUDE_ONCE_MARKER "$BATS_TEST_TMPDIR/c12rl-once"
  _fake FAKE_CLAUDE_ONCE_MODE limit
  _fake FAKE_CLAUDE_LIMIT_CODE 1308
  _fake FAKE_CLAUDE_NEXT_FLUSH "$(( $(date +%s) + 500 ))"
  _fake FAKE_CLAUDE_RESULT "claude answer"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/c12rl" ]
  [ "$(jq -r 'select(.id=="c12rl" and .served_lane=="glm") | .class' "$SPEEDWARS_FILE")" = "rate-limit" ]
}

@test "spec12 FR-1: a chain-exhausted parked row carries class parked-env" {
  _write_conf "claude:opus" 4 15
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-c12pk.jsonl"
  _enqueue c12pk "chain exhausted"
  mkdir -p "$BUS/queue" "$BUS/limits"
  printf '%s' "codex:default kimi:kimi-k3" > "$BUS/queue/c12pk.chain"
  printf '18000' > "$BUS/limits/codex.limited"
  printf '18000' > "$BUS/limits/kimi.limited"

  run timeout 20 "$RUNSH"
  [ "$status" -ne 0 ]
  [ -f "$BUS/limits/c12pk.parked" ]
  [ "$(jq -r 'select(.id=="c12pk" and .outcome=="parked") | .class' "$SPEEDWARS_FILE")" = "parked-env" ]
}

@test "spec12 FR-2: done/<id>'s code field carries the real worker rc, not hardcoded 0" {
  _write_conf "claude:opus" 4 15
  _fake FAKE_CLAUDE_RESULT "OK but nonzero exit"
  _fake FAKE_CLAUDE_EXIT 3
  _enqueue c12rc "worker exits nonzero after a valid envelope"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/c12rc" ]
  [ "$(jq -r '.code' "$BUS/done/c12rc")" = "3" ]
}

@test "spec12 FR-3/FR-5: full_run appends a run-summary row last; _check_parked's rc still governs the run's exit status" {
  _write_conf "claude:opus" 4 15
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-c12fr.jsonl" SPEEDWARS_RUN="c12-fr"
  _fake FAKE_CLAUDE_RESULT "OK"
  _enqueue c12d1 "branch one"
  _enqueue c12d2 "branch two"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/c12d1" ]; [ -f "$BUS/done/c12d2" ]

  local last; last="$(tail -n1 "$SPEEDWARS_FILE")"
  [ "$(jq -r '.type' <<<"$last")" = "run-summary" ]
  [ "$(jq -r '.run' <<<"$last")" = "c12-fr" ]
  [ "$(jq -r '.mode' <<<"$last")" = "full" ]
  [ "$(jq -r '.done_n' <<<"$last")" = "2" ]
}

# --- F11: a FAILing skill-drift row must not decapitate doctor --------------------------------
# `doctor` documents itself as "purely diagnostic; never fatal, always exits 0" — under set -e an
# unguarded FAILing helper broke that contract AND, because cmd_doctor_live opens by calling
# cmd_doctor, aborted `doctor --live` before a single probe ran.

# _plant_drifted_skill — a hand-copied (non-symlink) SKILL.md under the test's throwaway $HOME,
# which is exactly what doctor_skill_drift is built to FAIL on.
_plant_drifted_skill() {
  mkdir -p "$HOME/.claude/skills/unimatrix"
  printf 'a hand copy, not a symlink\n' > "$HOME/.claude/skills/unimatrix/SKILL.md"
}

@test "F11 doctor: a FAILing skill-drift row still prints and doctor still exits 0" {
  _plant_drifted_skill
  run "$RUNSH" doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"skill-drift  FAIL"* ]]
  [[ "$output" == *"not a symlink"* ]]
  # the row is the LAST thing doctor prints — proof it did not abort mid-report either
  [[ "$output" == *"bus fs"* ]]
}

@test "F11 doctor --live: a FAILing skill-drift row does not decapitate the probe section" {
  _plant_drifted_skill
  export LEDGER_FILE="$BATS_TEST_TMPDIR/doctor-f11-ledger.md"
  run "$RUNSH" doctor --live
  [[ "$output" == *"skill-drift  FAIL"* ]]
  [[ "$output" == *"doctor --live (auth probes)"* ]]
  [[ "$output" == *"probe       claude"* ]]
  [[ "$output" == *"probe       kimi"* ]]
}

# --- spec 13 FR-2: doctor --live -----------------------------------------------------------------

@test "doctor: plain (no --live) makes zero network calls — fake curl never invoked, always exits 0" {
  export FAKE_CURL_CALLED_FILE="$BATS_TEST_TMPDIR/curl-called"
  run "$RUNSH" doctor
  [ "$status" -eq 0 ]
  [ ! -e "$FAKE_CURL_CALLED_FILE" ]
  [[ "$output" != *"doctor --live"* ]]
}

@test "doctor --live: all six lanes PASS by default (fakes healthy, env-master fully keyed) — exits 0, one ledger row per lane" {
  export LEDGER_FILE="$BATS_TEST_TMPDIR/doctor-ledger.md"
  run "$RUNSH" doctor --live
  [ "$status" -eq 0 ]
  for lane in claude codex gemini grok glm kimi; do
    [[ "$output" == *"probe       $lane"*"PASS"* ]]
    grep -q "doctor-probe ($lane)" "$LEDGER_FILE"
  done
}

@test "doctor --live: a glm curl HTTP failure prints FAIL with the HTTP code, exits nonzero, writes limits/glm.broken when a busdir exists" {
  export LEDGER_FILE="$BATS_TEST_TMPDIR/doctor-ledger2.md"
  export FAKE_CURL_HTTP_CODE=401
  bus_init_probe() { bash -c "source '$BATS_TEST_DIRNAME/../src/swarm-lib.sh'; bus_init '$1'"; }
  bus_init_probe "$BUS"

  run "$RUNSH" doctor --live
  [ "$status" -ne 0 ]
  [[ "$output" == *"probe       glm"*"FAIL HTTP 401"* ]]
  [ -f "$BUS/limits/glm.broken" ]
  grep -q "doctor-probe (glm)" "$LEDGER_FILE"
}

@test "doctor --live: a kimi curl network failure (rc!=0) prints FAIL with the curl rc, exits nonzero" {
  export LEDGER_FILE="$BATS_TEST_TMPDIR/doctor-ledger3.md"
  export FAKE_CURL_RC=28
  run "$RUNSH" doctor --live
  [ "$status" -ne 0 ]
  [[ "$output" == *"probe       kimi"*"FAIL curl rc 28"* ]]
}

@test "doctor --live: a missing env-master key for gemini prints FAIL naming the missing key, no curl invoked for that lane" {
  export LEDGER_FILE="$BATS_TEST_TMPDIR/doctor-ledger4.md"
  export FAKE_CURL_CALLED_FILE="$BATS_TEST_TMPDIR/curl-called2"
  export ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster-no-gemini"
  printf 'Z_AI_CODING_KEY=k\nMOONSHOT_API_KEY=k\n' > "$ENV_MASTER_FILE"
  run "$RUNSH" doctor --live
  [ "$status" -ne 0 ]
  [[ "$output" == *"probe       gemini"*"FAIL no GEMINI_API_KEY"* ]]
  ! grep -q "generativelanguage" "$FAKE_CURL_CALLED_FILE" 2>/dev/null
}

@test "doctor --live: claude CLI probe exiting nonzero (dead OAuth session) prints FAIL with the exit code" {
  # Deliberately NOT testing 'CLI missing from PATH' here: this box's real PATH (appended after
  # $BIN) has a real claude/codex/grok binary further down, so removing the fake from $BIN would
  # NOT actually hide the CLI from `command -v` — it would fall through to invoking the REAL CLI,
  # which this suite must never do. Exercise the sibling FAIL path (CLI runs, exits nonzero)
  # instead — same "FAIL <reason>" contract, network-free either way.
  export LEDGER_FILE="$BATS_TEST_TMPDIR/doctor-ledger5.md"
  _fake FAKE_CLAUDE_EXIT 1
  run "$RUNSH" doctor --live
  [ "$status" -ne 0 ]
  [[ "$output" == *"probe       claude"*"FAIL exit 1"* ]]
}

@test "doctor --live: PASS latency is reported in ms" {
  export LEDGER_FILE="$BATS_TEST_TMPDIR/doctor-ledger6.md"
  run "$RUNSH" doctor --live
  [ "$status" -eq 0 ]
  [[ "$output" =~ probe\ +claude\ +PASS\ [0-9]+ms ]]
}

# --- spec 17 FR-5: doctor --plugin (plan-004 P1-FR5) -------------------------------------------
# $HOME is already the throwaway "$BATS_TEST_TMPDIR/realhome" from setup() above — every account
# dir/settings.json planted below lives under THAT fake tree, never the real ~/.claude*.
# $RUNSH is invoked as a real subprocess (never sourced), so $SCRIPT_DIR inside it resolves to the
# REAL checkout under test — plugin.json/marketplace.json/SKILL.md are this repo's real, valid
# files, so the manifest/marketplace/skill-version checks exercise real content, not fixtures.

@test "doctor --plugin: manifest/marketplace/UNIMATRIX_HOME/skill-version all PASS against the real repo; no accounts -> notes none found, drift table is green" {
  run "$RUNSH" doctor --plugin
  [ "$status" -eq 0 ]
  [[ "$output" == *"=== unimatrix doctor --plugin ==="* ]]
  [[ "$output" == *"manifest    plugin.json"*"PASS"* ]]
  [[ "$output" == *"manifest    marketplace.json"*"PASS"* ]]
  [[ "$output" == *"marketplace resolves"*"PASS"* ]]
  [[ "$output" == *"UNIMATRIX_HOME resolves"*"PASS"* ]]
  [[ "$output" == *"skill-version"*"PASS"* ]]
  [[ "$output" != *"WARNING: plugin.json version"* ]]
  [[ "$output" == *"no accounts found"* ]]
  [[ "$output" == *"install-drift: GREEN"* ]]
}

@test "doctor --plugin: no cached copy anywhere is an informational row, not a failure" {
  run "$RUNSH" doctor --plugin
  [ "$status" -eq 0 ]
  [[ "$output" == *"cache        -          -          INFO"* ]]
  [[ "$output" == *"install-drift: GREEN"* ]]
}

@test "doctor --plugin: a stale cached plugin.json (real install/enable copy, not the marketplace source) is a red cache row, rc still 0" {
  local mkt_name plugin_name
  mkt_name="$(jq -r '.name' "$BATS_TEST_DIRNAME/../.claude-plugin/marketplace.json")"
  plugin_name="$(jq -r '.name' "$BATS_TEST_DIRNAME/../plugin/.claude-plugin/plugin.json")"
  local cache="$HOME/.claude/plugins/cache/$mkt_name/$plugin_name/9.9.9"
  mkdir -p "$cache/.claude-plugin"
  printf '{"name":"%s","version":"0.0.1-stale"}\n' "$plugin_name" > "$cache/.claude-plugin/plugin.json"

  run "$RUNSH" doctor --plugin
  [ "$status" -eq 0 ]
  [[ "$output" == *"cache:9.9.9"*"FAIL"*"(plugin.json (cache))"* ]]
  [[ "$output" == *"install-drift: RED"* ]]
}

@test "doctor --plugin: a cached copy that matches the repo (plugin.json + every command) is all-PASS" {
  local mkt_name plugin_name repo_root
  repo_root="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  mkt_name="$(jq -r '.name' "$repo_root/.claude-plugin/marketplace.json")"
  plugin_name="$(jq -r '.name' "$repo_root/plugin/.claude-plugin/plugin.json")"
  local cache="$HOME/.claude/plugins/cache/$mkt_name/$plugin_name/1.1.0"
  mkdir -p "$cache/.claude-plugin" "$cache/commands"
  cp "$repo_root/plugin/.claude-plugin/plugin.json" "$cache/.claude-plugin/plugin.json"
  cp "$repo_root/plugin/commands/"*.md "$cache/commands/"

  run "$RUNSH" doctor --plugin
  [ "$status" -eq 0 ]
  [[ "$output" == *"cache:1.1.0"*"PASS"*"(plugin.json (cache))"* ]]
  [[ "$output" == *"cache:1.1.0"*"PASS"*"(commands (cache))"* ]]
}

@test "doctor --plugin: install-drift PASS row when an account's settings.json points its marketplace at this checkout" {
  local repo_root; repo_root="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  mkdir -p "$HOME/.claude-acct/goodacct"
  jq -n --arg p "$repo_root" \
    '{extraKnownMarketplaces:{unimatrix:{source:{source:"directory",path:$p}}},enabledPlugins:{"u@unimatrix":true}}' \
    > "$HOME/.claude-acct/goodacct/settings.json"

  run "$RUNSH" doctor --plugin
  [ "$status" -eq 0 ]
  [[ "$output" == *"goodacct"*"PASS"*"(plugin)"* ]]
  [[ "$output" == *"install-drift: GREEN"* ]]
}

@test "doctor --plugin: install-drift table is RED on a planted mismatch, naming the drifted account" {
  local stale="$BATS_TEST_TMPDIR/stale-marketplace"
  mkdir -p "$stale/.claude-plugin"
  echo '{"name":"u","version":"0.0.1-drifted"}' > "$stale/.claude-plugin/plugin.json"

  mkdir -p "$HOME/.claude-acct/staleacct"
  jq -n --arg p "$stale" \
    '{extraKnownMarketplaces:{unimatrix:{source:{source:"directory",path:$p}}},enabledPlugins:{"u@unimatrix":true}}' \
    > "$HOME/.claude-acct/staleacct/settings.json"

  run "$RUNSH" doctor --plugin
  [ "$status" -eq 0 ]
  [[ "$output" == *"staleacct"*"FAIL"*"(plugin)"* ]]
  [[ "$output" == *"install-drift: RED"* ]]
}

@test "doctor --plugin: an account with no marketplace entry falls back to the skill-copy surface; SKIP when no copy exists" {
  mkdir -p "$HOME/.claude-acct/noplugin"
  echo '{}' > "$HOME/.claude-acct/noplugin/settings.json"

  run "$RUNSH" doctor --plugin
  [ "$status" -eq 0 ]
  [[ "$output" == *"noplugin"*"SKIP"*"(skill not installed)"* ]]
}

@test "doctor --plugin: never fatal — a doctor invocation with no --plugin flag is unaffected" {
  run "$RUNSH" doctor
  [ "$status" -eq 0 ]
  [[ "$output" != *"doctor --plugin"* ]]
  [[ "$output" != *"install-drift"* ]]
}

# --- P1-FR5: _plugin_version_banner_line ------------------------------------------------------
# A standalone throwaway engine dir (swarm-run.sh + its sourced src/swarm-lib.sh, copied — SCRIPT_DIR
# resolves via BASH_SOURCE to wherever swarm-run.sh itself lives) with a hand-built plugin.json/
# CHANGELOG.md pair, so the version comparison can be pushed out of sync without touching the real
# repo's own (currently in-sync) files.
_banner_engine() {
  local dir="$1" version="$2" changelog_version="$3"
  mkdir -p "$dir/src" "$dir/plugin/.claude-plugin" "$dir/.claude-plugin" "$dir/.claude/skills/unimatrix"
  cp "$RUNSH" "$dir/swarm-run.sh"
  cp "$BATS_TEST_DIRNAME/../src/swarm-lib.sh" "$dir/src/swarm-lib.sh"
  printf '{"name":"u","version":"%s"}\n' "$version" > "$dir/plugin/.claude-plugin/plugin.json"
  printf '{"name":"unimatrix","plugins":[{"name":"u","source":"./plugin","version":"%s"}]}\n' \
    "$version" > "$dir/.claude-plugin/marketplace.json"
  printf '# Changelog\n\n## [%s] - 2026-01-01\n' "$changelog_version" > "$dir/CHANGELOG.md"
}

@test "P1-FR5: _plugin_version_banner_line warns on stderr when plugin.json and CHANGELOG disagree; rc of the banner path stays 0" {
  local eng="$BATS_TEST_TMPDIR/bannereng-mismatch"
  _banner_engine "$eng" "1.1.0" "9.9.9"

  run "$eng/swarm-run.sh" doctor --plugin
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING: plugin.json version (1.1.0) differs from repo version (9.9.9)"* ]]
}

@test "P1-FR5: _plugin_version_banner_line is silent when plugin.json and CHANGELOG agree" {
  local eng="$BATS_TEST_TMPDIR/bannereng-match"
  _banner_engine "$eng" "1.1.0" "1.1.0"

  run "$eng/swarm-run.sh" doctor --plugin
  [ "$status" -eq 0 ]
  [[ "$output" != *"WARNING: plugin.json version"* ]]
}

# --- spec 13 FR-3: .broken fast-fail marker (integration) -------------------------------------

@test "spec13 FR-3: a lane that ran but served nothing gets limits/<lane>.broken (class lane-down) once its bounded retries exhaust" {
  _write_conf "grok:default claude:opus"
  cat >> "$CONF" <<'EOF2'
MAX_LANE_RETRIES=1
EOF2
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-fr3a.jsonl"
  _fake FAKE_GROK_ERROR "kaboom internal crash"
  _fake FAKE_CLAUDE_RESULT "claude rescued it"
  _enqueue fr3a "card that fast-fails on grok, rescued by claude"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/fr3a" ]
  [ "$(<"$BUS/res-fr3a.txt")" = "claude rescued it" ]
  [ -f "$BUS/limits/grok.broken" ]
  [ "$(jq -r 'select(.id=="fr3a" and .served_lane=="grok") | .class' "$SPEEDWARS_FILE")" = "lane-down" ]
}

@test "spec13 FR-3: a routed-around .broken lane is never spawned again while the flag is active" {
  _write_conf "grok:default claude:opus"
  cat >> "$CONF" <<'EOF2'
MAX_LANE_RETRIES=1
EOF2
  FAKE_GROK_CALL_COUNT="$BATS_TEST_TMPDIR/grok-calls"
  _fake FAKE_GROK_CALL_COUNT "$FAKE_GROK_CALL_COUNT"
  _fake FAKE_GROK_ERROR "kaboom internal crash"
  _fake FAKE_CLAUDE_RESULT "claude rescued it"
  _enqueue fr3b1 "first card exhausts and marks grok broken"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/limits/grok.broken" ]
  calls_after_first="$(wc -l < "$FAKE_GROK_CALL_COUNT")"
  [ "$calls_after_first" -ge 1 ]

  # a SEPARATE run against the same bus: a fresh card pinned to grok-only (no fallback lane) must
  # park WITHOUT ever spawning grok — proves routing-around, not just the marker's existence.
  _write_conf "grok:default"
  _enqueue fr3b2 "second card must route around the still-broken grok"
  run timeout 20 "$RUNSH"
  [ "$status" -ne 0 ]
  [ -f "$BUS/limits/fr3b2.parked" ]
  [ "$(wc -l < "$FAKE_GROK_CALL_COUNT")" -eq "$calls_after_first" ]
}

@test "spec13 FR-3: the .broken marker expires by TTL — a later card can use the lane again" {
  _write_conf "grok:default claude:opus"
  cat >> "$CONF" <<'EOF2'
MAX_LANE_RETRIES=1
EOF2
  _fake FAKE_GROK_ERROR "kaboom internal crash"
  _fake FAKE_CLAUDE_RESULT "claude rescued it"
  _enqueue fr3c1 "first card exhausts and marks grok broken"
  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/limits/grok.broken" ]

  touch -d "-1900 seconds" "$BUS/limits/grok.broken"  # past the 1800s default TTL
  _fake FAKE_GROK_ERROR ""
  _fake FAKE_GROK_RESULT "grok healthy again"
  _write_conf "grok:default"
  _enqueue fr3c2 "second card, grok TTL expired"
  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/fr3c2" ]
  [ "$(<"$BUS/res-fr3c2.txt")" = "grok healthy again" ]
}

@test "spec13 FR-3: a successful finalize on a previously-broken lane clears its .broken marker file" {
  _write_conf "grok:default claude:opus"
  cat >> "$CONF" <<'EOF2'
MAX_LANE_RETRIES=1
EOF2
  _fake FAKE_GROK_ERROR "kaboom internal crash"
  _fake FAKE_CLAUDE_RESULT "claude rescued it"
  _enqueue fr3d1 "first card exhausts and marks grok broken"
  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/limits/grok.broken" ]

  touch -d "-1900 seconds" "$BUS/limits/grok.broken"
  _fake FAKE_GROK_ERROR ""
  _fake FAKE_GROK_RESULT "grok healthy again"
  _write_conf "grok:default"
  _enqueue fr3d2 "second card succeeds on grok — should clear the stale marker file, not just outlast its TTL"
  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/fr3d2" ]
  [ ! -e "$BUS/limits/grok.broken" ]
}

# --- spec 13 FR-4: PAYG fallback gate (BUDGET_USD=0 fallback onto kimi) ------------------------

@test "spec13 FR-4: PAYG_FALLBACK=warn (default) lets a kimi fallback hop proceed under BUDGET_USD=0, with a loud stderr line" {
  _write_conf "glm:glm-5.2 kimi:kimi-k3"
  _enqueue payg1 "glm limited, fallback hop lands on kimi"
  _fake FAKE_CLAUDE_ONCE_MARKER "$BATS_TEST_TMPDIR/payg1-once"
  _fake FAKE_CLAUDE_ONCE_MODE limit
  _fake FAKE_CLAUDE_LIMIT_CODE 1308
  _fake FAKE_CLAUDE_NEXT_FLUSH "$(( $(date +%s) + 500 ))"
  _fake FAKE_CLAUDE_RESULT "kimi rescued it"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/payg1" ]
  [ "$(<"$BUS/res-payg1.txt")" = "kimi rescued it" ]
  [[ "$output" == *"PAYG fallback: payg1 hopping to kimi with no budget cap set"* ]]
}

@test "spec13 FR-4: PAYG_FALLBACK=deny routes around a kimi fallback hop under BUDGET_USD=0 — parks when kimi was the last lane" {
  _write_conf "glm:glm-5.2 kimi:kimi-k3"
  cat >> "$CONF" <<'EOF2'
PAYG_FALLBACK=deny
EOF2
  _enqueue payg2 "glm limited, kimi hop denied, nothing left"
  _fake FAKE_CLAUDE_ONCE_MARKER "$BATS_TEST_TMPDIR/payg2-once"
  _fake FAKE_CLAUDE_ONCE_MODE limit
  _fake FAKE_CLAUDE_LIMIT_CODE 1308
  _fake FAKE_CLAUDE_NEXT_FLUSH "$(( $(date +%s) + 500 ))"
  _fake FAKE_CLAUDE_RESULT "should never be seen"

  run timeout 20 "$RUNSH"
  [ "$status" -ne 0 ]
  [ ! -f "$BUS/done/payg2" ]
  [ -f "$BUS/limits/payg2.parked" ]
  [[ "$output" == *"fallback hop to kimi refused"* ]]
  [[ "$output" == *"PAYG_FALLBACK=deny"* ]]
}

@test "spec13 FR-4: PAYG_FALLBACK=allow is byte-identical to today — kimi hop proceeds silently (no PAYG stderr line)" {
  _write_conf "glm:glm-5.2 kimi:kimi-k3"
  cat >> "$CONF" <<'EOF2'
PAYG_FALLBACK=allow
EOF2
  _enqueue payg3 "glm limited, kimi hop allowed silently"
  _fake FAKE_CLAUDE_ONCE_MARKER "$BATS_TEST_TMPDIR/payg3-once"
  _fake FAKE_CLAUDE_ONCE_MODE limit
  _fake FAKE_CLAUDE_LIMIT_CODE 1308
  _fake FAKE_CLAUDE_NEXT_FLUSH "$(( $(date +%s) + 500 ))"
  _fake FAKE_CLAUDE_RESULT "kimi rescued it"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/payg3" ]
  [ "$(<"$BUS/res-payg3.txt")" = "kimi rescued it" ]
  [[ "$output" != *"PAYG fallback:"* ]]
  [[ "$output" != *"fallback hop to kimi refused"* ]]
}

@test "spec13 FR-4: with BUDGET_USD>0, PAYG_FALLBACK=deny does NOT block a kimi fallback hop (existing kimi budget gate governs instead, unchanged)" {
  _write_conf "glm:glm-5.2 kimi:kimi-k3"
  cat >> "$CONF" <<'EOF2'
BUDGET_USD=5
PAYG_FALLBACK=deny
EOF2
  _enqueue payg4 "glm limited, kimi hop under a real budget cap — deny must not apply"
  _fake FAKE_CLAUDE_ONCE_MARKER "$BATS_TEST_TMPDIR/payg4-once"
  _fake FAKE_CLAUDE_ONCE_MODE limit
  _fake FAKE_CLAUDE_LIMIT_CODE 1308
  _fake FAKE_CLAUDE_NEXT_FLUSH "$(( $(date +%s) + 500 ))"
  _fake FAKE_CLAUDE_RESULT "kimi rescued it"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/payg4" ]
  [ "$(<"$BUS/res-payg4.txt")" = "kimi rescued it" ]
  [[ "$output" != *"fallback hop to kimi refused"* ]]
}

# --- round-4 review fixes ------------------------------------------------------------------------

@test "round4: the resolved-config table prints EVERY conf_load key, not a hand-maintained subset" {
  _write_conf "claude:opus" 4 15
  run "$RUNSH" config
  [ "$status" -eq 0 ]
  for k in PLAN ORCHESTRATOR REVIEW EXEC_CHAIN MAX_ITERATIONS BUDGET_USD FANOUT LEASE_MIN \
           WORKER_TIMEOUT_SEC MAX_LANE_RETRIES VERIFY_MAP LEDGER_AUTO GEMINI_SANDBOX MON_PORT \
           MON_AUTOOPEN REVIEW_CHAIN PIN_WAIT_SEC PLAN_CHAIN ORCH_CHAIN ORCH_TAKEOVER_MIN \
           FEEDBACK_AUTO PAYG_FALLBACK GLM_MAX_THINKING_TOKENS KIMI_MAX_THINKING_TOKENS GROK_EFFORT; do
    [[ "$output" == *"$k"* ]] || { echo "missing conf key in config table: $k" >&2; false; }
  done
  # the class rows keep their live-availability rendering, not a bare value line
  [[ "$output" == *"CLASS_REVIEW:"* ]]
  [[ "$output" == *"CLASS_EXEC:"* ]]
}

@test "round4: the config table reports an actively-broken class member as broken, not available" {
  _write_conf "claude:opus" 4 15
  mkdir -p "$BUS/limits"
  printf '1800' > "$BUS/limits/grok.broken"

  run "$RUNSH" config
  [ "$status" -eq 0 ]
  [[ "$output" =~ CLASS_EXEC:\ grok\(broken\ [0-9]+m\) ]]
}

@test "round4: a .broken lane is routed around with fallback_reason lane-down, never budget-gated" {
  _write_conf "claude:opus codex:default" 4 15
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-broken.jsonl"
  mkdir -p "$BUS/limits"
  printf '1800' > "$BUS/limits/claude.broken"
  _fake FAKE_CODEX_RESULT "codex served it"
  _enqueue lb1 "claude is broken — the chain must hop and say why"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/lb1" ]
  [ "$(jq -r 'select(.id=="lb1") | .fallback_reason' "$SPEEDWARS_FILE")" = "lane-down" ]
  [[ "$output" == *"blocked (lane-down)"* ]]
}

@test "round4: a pinned park emits a TERMINAL parked row so parked_n matches the bus" {
  _write_conf "claude:opus" 4 15
  cat >> "$CONF" <<'EOF'
PIN_WAIT_SEC=0
EOF
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-pinpark.jsonl"
  mkdir -p "$BUS/limits"
  printf '18000' > "$BUS/limits/glm.limited"
  _enqueue pp1 "pinned to a limited lane — must park loudly WITH a row"
  printf 'glm:glm-5.2' > "$BUS/specs/pp1.lane"

  run timeout 25 "$RUNSH"
  [ "$status" -ne 0 ]
  [ -f "$BUS/limits/pp1.parked" ]
  # last row for this id is the park itself
  [ "$(jq -rs 'map(select(.id=="pp1")) | last | .outcome' "$SPEEDWARS_FILE")" = "parked" ]
  [ "$(jq -rs 'map(select(.type=="run-summary")) | last | .parked_n' "$SPEEDWARS_FILE")" = "1" ]
}

@test "round4: a timed-out write card rejected by the diff gate leaves NO stale res-<id>.txt" {
  _write_conf "claude:opus" 4 15
  cat >> "$CONF" <<'EOF'
WORKER_TIMEOUT_SEC=2
EOF
  local target="$BATS_TEST_TMPDIR/staleres-target"
  mkdir -p "$target"
  touch -d '10 seconds ago' "$target"
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-sr.jsonl"
  # answers (so extract_answer succeeds + writes res-*) but never touches the write target
  _fake FAKE_CLAUDE_ONCE_MARKER "$BATS_TEST_TMPDIR/sr-once"
  _fake FAKE_CLAUDE_ONCE_MODE answerhang
  _fake FAKE_CLAUDE_SALVAGE_RESULT "I talked instead of editing"
  _enqueue sr1 "write card that answers but writes nothing, then hangs"
  printf '%s' "$target" > "$BUS/specs/sr1.write"

  run timeout 25 "$RUNSH"
  [ "$status" -ne 0 ]
  [ ! -e "$BUS/done/sr1" ]
  [ ! -e "$BUS/res-sr1.txt" ]   # the rejected answer must never survive to launder a later attempt
}

@test "round4: a salvaged done marker is stamped salvaged:true (code alone no longer distinguishes it)" {
  _write_conf "claude:opus" 4 15
  cat >> "$CONF" <<'EOF'
WORKER_TIMEOUT_SEC=2
EOF
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-salvflag.jsonl"
  _fake FAKE_CLAUDE_ONCE_MARKER "$BATS_TEST_TMPDIR/sf-once"
  _fake FAKE_CLAUDE_ONCE_MODE answerhang
  _fake FAKE_CLAUDE_SALVAGE_RESULT "answer landed before the kill"
  _enqueue sf1 "read card salvaged after a kill"

  run timeout 25 "$RUNSH"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.salvaged' "$BUS/done/sf1")" = "true" ]
  # a PLAIN completion carries no such key (absence-means-absent)
  _enqueue sf2 "ordinary card"
  run timeout 20 "$RUNSH"
  [ "$(jq -r 'has("salvaged")' "$BUS/done/sf2")" = "false" ]
}

@test "round4: doctor --live probe cages live outside BUSDIR and leave no credentials behind" {
  export LEDGER_FILE="$BATS_TEST_TMPDIR/dl-ledger.md"
  mkdir -p "$HOME/.claude"
  printf '{"token":"secret"}' > "$HOME/.claude/.credentials.json"
  [ ! -d "$BUS" ]

  run "$RUNSH" doctor --live
  [ "$status" -eq 0 ]
  # the probe must not conjure a bus (which would also satisfy the .broken guard by itself)
  [ ! -d "$BUS" ]
}

@test "round4: doctor --live: a FAIL does NOT write .broken into a bus the probe itself created" {
  export LEDGER_FILE="$BATS_TEST_TMPDIR/dl-ledger2.md"
  export FAKE_CURL_HTTP_CODE=401
  [ ! -d "$BUS" ]
  run "$RUNSH" doctor --live
  [ "$status" -ne 0 ]
  [ ! -e "$BUS/limits/glm.broken" ]
}

@test "round4: doctor --live never puts a provider key in curl's argv (stdin headers only)" {
  export LEDGER_FILE="$BATS_TEST_TMPDIR/dl-ledger3.md"
  export FAKE_CURL_CALLED_FILE="$BATS_TEST_TMPDIR/curl-argv"
  export FAKE_CURL_STDIN_FILE="$BATS_TEST_TMPDIR/curl-stdin"
  run "$RUNSH" doctor --live
  [ "$status" -eq 0 ]
  [ -s "$FAKE_CURL_CALLED_FILE" ]
  ! grep -q 'default-glm-key\|default-kimi-key\|default-gem-key' "$FAKE_CURL_CALLED_FILE"
  grep -q "default-gem-key" "$FAKE_CURL_STDIN_FILE"
  # and no `?key=` query-string form for gemini
  ! grep -q '?key=' "$FAKE_CURL_CALLED_FILE"
}

@test "round4: doctor --live probes the CONFIGURED glm model, not a hardcoded one" {
  export LEDGER_FILE="$BATS_TEST_TMPDIR/dl-ledger4.md"
  export FAKE_CURL_CALLED_FILE="$BATS_TEST_TMPDIR/curl-argv4"
  _write_conf "claude:opus glm:glm-4.7" 4 15
  run "$RUNSH" doctor --live
  [ "$status" -eq 0 ]
  grep -q 'glm-4.7' "$FAKE_CURL_CALLED_FILE"
  ! grep -q 'glm-4.6' "$FAKE_CURL_CALLED_FILE"
}

# --- spec 14 fix wave (RUN-1: swarm-run.sh foundations) ------------------------------------------
# backlog 44-57, 2026-07-25. FR numbers below are spec 14's unless noted; spec01/04/10/12 carry
# their own 2026-07-25 amendments (FR-A/FR-B, FR-C, FR-E, FR-D respectively).

@test "spec14 FR-7: a chain-exhausted park's marker matches the fixed reason-line format, reason chain-exhausted, retryable=1, ttl=0" {
  _write_conf "claude:opus" 4 15
  _enqueue f7a "chain exhausted, no fallback"
  mkdir -p "$BUS/queue" "$BUS/limits"
  printf '%s' "codex:default kimi:kimi-k3" > "$BUS/queue/f7a.chain"
  printf '18000' > "$BUS/limits/codex.limited"
  printf '18000' > "$BUS/limits/kimi.limited"

  run timeout 20 "$RUNSH"
  [ "$status" -ne 0 ]
  [ -f "$BUS/limits/f7a.parked" ]
  local line; line="$(<"$BUS/limits/f7a.parked")"
  [[ "$line" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[^\ ]*\ \|\ chain-exhausted\ \|\ retryable=1\ \|\ ttl=0\ \|\ .*$ ]]
  # speed_row's own `class` output is unchanged (parked-env) — the existing regression guard at
  # "spec12 FR-1: a chain-exhausted parked row carries class parked-env" pins that separately.
}

@test "spec14 FR-7: a retries-exhausted park's marker carries a token from the fixed set and no leaked answer text" {
  _write_conf "claude:opus" 4 15
  cat >> "$CONF" <<'EOF2'
MAX_LANE_RETRIES=1
EOF2
  _fake FAKE_CLAUDE_GARBAGE_COUNT "$BATS_TEST_TMPDIR/f7b-count"
  _enqueue f7b "SUPER-SECRET-CANARY-STRING must never leak into a marker"

  run timeout 20 "$RUNSH"
  [ "$status" -ne 0 ]
  [ -f "$BUS/limits/f7b.parked" ]
  local line token; line="$(<"$BUS/limits/f7b.parked")"
  [[ "$line" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[^\ ]*\ \|\ ([a-z-]+)\ \|\ retryable=[01]\ \|\ ttl=[0-9]+\ \|\ .*$ ]]
  token="${BASH_REMATCH[1]}"
  case "$token" in
    auth-death | api-error | server-error | rate-limit | timeout-watchdog | spawn-fail \
      | false-done | no-answer | lane-down | parked-env | cage-denied | write-target-missing \
      | write-target-empty | chain-exhausted | pinned-lane-blocked | session-limit) ;;
    *) echo "unknown reason token: $token" >&2; false ;;
  esac
  ! grep -q "SUPER-SECRET-CANARY-STRING" "$BUS/limits/f7b.parked"
}

@test "spec14 FR-3 regression guard: an EMPTY limits/.chain-<id> reads as exhausted, never falls back to EXEC_CHAIN ([[ -f ]], never [[ -s ]])" {
  mkdir -p "$BUS/limits"
  : > "$BUS/limits/.chain-guard1"
  run bash -c "
    set -euo pipefail
    source '$BATS_TEST_DIRNAME/../src/swarm-lib.sh'
    EXEC_CHAIN='claude:opus codex:default'
    chain_current '$BUS' guard1
  "
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "spec14 FR-3: after a chain-exhausted park, limits/.chain-<id> no longer exists (today: a zero-byte file remains)" {
  _write_conf "claude:opus" 4 15
  _enqueue f3a "chain exhausted, no fallback"
  mkdir -p "$BUS/queue" "$BUS/limits"
  printf '%s' "codex:default kimi:kimi-k3" > "$BUS/queue/f3a.chain"
  printf '18000' > "$BUS/limits/codex.limited"
  printf '18000' > "$BUS/limits/kimi.limited"

  run timeout 20 "$RUNSH"
  [ "$status" -ne 0 ]
  [ -f "$BUS/limits/f3a.parked" ]
  [ ! -e "$BUS/limits/.chain-f3a" ]
}

@test "spec14 FR-5: a .write target that does not exist is never spawned into — waits, then parks write-target-missing, never mkdir'd" {
  _write_conf "claude:opus" 4 15
  cat >> "$CONF" <<'EOF2'
PIN_WAIT_SEC=2
EOF2
  local target="$BATS_TEST_TMPDIR/fr5-missing"
  local argvfile="$BATS_TEST_TMPDIR/fr5-argv"
  _fake FAKE_CLAUDE_ARGV_FILE "$argvfile"
  _fake FAKE_CLAUDE_RESULT "should never run"
  _enqueue fr5a "write card targeting a directory that doesn't exist yet"
  printf '%s' "$target" > "$BUS/specs/fr5a.write"

  run timeout 20 "$RUNSH"
  [ "$status" -ne 0 ]
  [ -f "$BUS/limits/fr5a.parked" ]
  [[ "$output" == *"does not exist yet"*"waiting"* ]]
  [[ "$output" == *"still missing after"*"parking"* ]]
  [ ! -e "$argvfile" ]     # the fake CLI was NEVER invoked
  [ ! -d "$target" ]       # never mkdir'd
  [[ "$(<"$BUS/limits/fr5a.parked")" == *"write-target-missing"* ]]
}

@test "spec14 FR-5: a .write target that appears mid-wait clears limits/<id>.waiting-write and the card claims and runs normally" {
  _write_conf "claude:opus" 4 15
  cat >> "$CONF" <<'EOF2'
PIN_WAIT_SEC=30
EOF2
  local target="$BATS_TEST_TMPDIR/fr5-appears"
  _fake FAKE_CLAUDE_RESULT "ran once the target showed up"
  _fake FAKE_CLAUDE_WRITE_FILE "created.txt"
  _enqueue fr5b "write card whose target appears mid-wait"
  printf '%s' "$target" > "$BUS/specs/fr5b.write"

  "$RUNSH" 3>&- &
  BG_PIDS+=("$!")

  # cross-review CRITICAL fix: FR-5 owns its own marker name (.waiting-write), distinct from
  # FR-R6's shared .waiting — the two used to collide and reset each other's timer every poll.
  _poll 10 test -f "$BUS/limits/fr5b.waiting-write"
  [ -f "$BUS/limits/fr5b.waiting-write" ]
  mkdir -p "$target"

  _poll 25 test -f "$BUS/done/fr5b"
  [ -f "$BUS/done/fr5b" ]
  [ ! -e "$BUS/limits/fr5b.waiting-write" ]
  [ -f "$target/created.txt" ]

  wait "${BG_PIDS[0]}"
  BG_PIDS=()
}

@test "spec14 FR-5 companion (2026-07-29): an EMPTY queue/<id>.write parks INSTANTLY, never waiting PIN_WAIT_SEC" {
  _write_conf "claude:opus" 4 15
  cat >> "$CONF" <<'EOF2'
PIN_WAIT_SEC=60
EOF2
  local argvfile="$BATS_TEST_TMPDIR/empty-write-argv"
  _fake FAKE_CLAUDE_ARGV_FILE "$argvfile"
  _fake FAKE_CLAUDE_RESULT "should never run"
  # seeded directly into queue/, bypassing the sweep's own empty-card refusal (spec01 FR-B) — this
  # test is about _try_claim_one's claim-time instant park, a distinct code path
  mkdir -p "$BUS/queue"
  printf '%s' "empty write card, queued directly" > "$BUS/queue/ew1.prompt"
  : > "$BUS/queue/ew1.write"

  run timeout 20 "$RUNSH"
  [ "$status" -ne 0 ]
  [ -f "$BUS/limits/ew1.parked" ]
  [[ "$(<"$BUS/limits/ew1.parked")" == *"write-target-empty"* ]]
  [ ! -e "$argvfile" ]     # the fake CLI was NEVER invoked — the 20s timeout beating PIN_WAIT_SEC=60
                           # proves the park was instant, not a bounded wait that happened to time out
}

@test "spec14 FR-5 companion: a zero-byte run-jsonl on the exhausting attempt does NOT flag lane-down/.broken" {
  _write_conf "claude:opus" 4 15
  cat >> "$CONF" <<'EOF2'
MAX_LANE_RETRIES=1
EOF2
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-zb.jsonl"
  _fake FAKE_CLAUDE_SILENT_FAIL 1
  _enqueue zb1 "worker dies with zero stdout on a card-fault exit code"

  run timeout 20 "$RUNSH"
  [ "$status" -ne 0 ]
  [ -f "$BUS/limits/zb1.parked" ]
  [ ! -e "$BUS/limits/claude.broken" ]
  [ "$(jq -r 'select(.id=="zb1" and .outcome=="retry") | .class' "$SPEEDWARS_FILE")" = "no-answer" ]
}

@test "spec14 FR-5 companion: a zero-byte run-jsonl with wrc 126 still flags lane-down/.broken" {
  _write_conf "claude:opus" 4 15
  cat >> "$CONF" <<'EOF2'
MAX_LANE_RETRIES=1
EOF2
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-zb126.jsonl"
  _fake FAKE_CLAUDE_SILENT_FAIL 126
  _enqueue zb126 "worker exits 126 (exec-permission failure) with zero stdout"

  run timeout 20 "$RUNSH"
  [ "$status" -ne 0 ]
  [ -f "$BUS/limits/zb126.parked" ]
  [ -f "$BUS/limits/claude.broken" ]
  [ "$(jq -r 'select(.id=="zb126" and .outcome=="retry") | .class' "$SPEEDWARS_FILE")" = "lane-down" ]
}

@test "spec14 FR-5 companion: a zero-byte run-jsonl with wrc 127 still flags lane-down/.broken" {
  _write_conf "claude:opus" 4 15
  cat >> "$CONF" <<'EOF2'
MAX_LANE_RETRIES=1
EOF2
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-zb127.jsonl"
  _fake FAKE_CLAUDE_SILENT_FAIL 127
  _enqueue zb127 "worker exits 127 (command-not-found shape) with zero stdout"

  run timeout 20 "$RUNSH"
  [ "$status" -ne 0 ]
  [ -f "$BUS/limits/zb127.parked" ]
  [ -f "$BUS/limits/claude.broken" ]
  [ "$(jq -r 'select(.id=="zb127" and .outcome=="retry") | .class' "$SPEEDWARS_FILE")" = "lane-down" ]
}

@test "spec01 FR-B: sweep discards done/cancelled ids, preserves an already-queued OPERATOR HINT, and still sweeps a fresh id sidecars-first" {
  _write_conf "claude:opus" 4 15
  mkdir -p "$BUS/done" "$BUS/cancelled" "$BUS/queue" "$BUS/specs"

  # done/<id>: consume-and-discard — specs/ entry (+ sidecars) vanish, done/ marker untouched
  printf '{"id":"b1","code":0,"lane":"claude"}\n' > "$BUS/done/b1"
  _enqueue b1 "already done, must not re-run"
  echo "claude:opus" > "$BUS/specs/b1.lane"

  # cancelled/<id>.prompt: consume-and-discard
  printf 'pulled' > "$BUS/cancelled/b2.prompt"
  _enqueue b2 "already cancelled, must not resurrect"

  # queue/<id>.prompt already present (e.g. reap-requeued, carrying an OPERATOR HINT):
  # non-destructive skip — the queued copy (with its hint) must survive, not the pristine one
  _enqueue b4 "pristine specs copy — must NOT clobber the queued hint"
  printf 'requeued original\n\n## OPERATOR HINT (nudge 2026-01-01T00:00:00Z)\ndo it differently\n' > "$BUS/queue/b4.prompt"

  # a genuinely fresh id — sidecars still move before the prompt, exactly as today
  local argvfile="$BATS_TEST_TMPDIR/b4-b5.argv"
  _fake FAKE_CLAUDE_RESULT "fresh answer"
  _fake FAKE_CLAUDE_ARGV_FILE "$argvfile"
  _enqueue b5 "brand new spec"
  echo "claude:opus" > "$BUS/specs/b5.lane"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]

  # b1 — done, discarded
  [ ! -e "$BUS/specs/b1.prompt" ]
  [ ! -e "$BUS/specs/b1.lane" ]
  [ ! -e "$BUS/run-b1.jsonl" ]
  [[ "$output" == *"b1"*"done"* ]]

  # b2 — cancelled, discarded, never resurrected
  [ ! -e "$BUS/specs/b2.prompt" ]
  [ ! -e "$BUS/queue/b2.prompt" ]
  [ ! -e "$BUS/run-b2.jsonl" ]
  [[ "$output" == *"b2"*"cancelled"* ]]

  # b4 — already queued; the hinted copy must survive to spawn time (proven via the CLI's own argv)
  [ -e "$BUS/specs/b4.prompt" ]
  [ -f "$BUS/done/b4" ]
  grep -q "OPERATOR HINT" "$argvfile"
  [[ "$output" == *"b4"*"already queued"* ]]

  # b5 — fresh id, sidecars-first, completes normally
  [ -f "$BUS/done/b5" ]
  [ "$(<"$BUS/res-b5.txt")" = "fresh answer" ]
}

@test "spec01 FR-B: an id already claimed keeps its specs/ entry in place (non-destructive skip), never a second queue/ prompt" {
  _write_conf "claude:opus" 4 15
  mkdir -p "$BUS/claimed"
  _enqueue b3 "already claimed elsewhere — must not get a second prompt in queue/"
  : > "$BUS/claimed/b3.claude:opus"

  local logf="$BATS_TEST_TMPDIR/b3.log"
  "$RUNSH" >"$logf" 2>&1 3>&- &
  BG_PIDS+=("$!")

  # _enqueue_pending_specs runs at the very start, before the pool ever polls — this orphan claim
  # is a deliberate fixture (no real worker behind it) and would gate-hang forever, so the run is
  # aborted below rather than waited out; a short sleep is enough to observe the sweep's decision.
  sleep 1
  [ -e "$BUS/specs/b3.prompt" ]
  [ ! -e "$BUS/queue/b3.prompt" ]
  grep -q "b3 is currently claimed" "$logf"

  if [ -f "$BUS/run.pgid" ]; then
    kill -- "-$(cat "$BUS/run.pgid")" 2>/dev/null || true
  fi
  wait "${BG_PIDS[0]}" 2>/dev/null || true
  BG_PIDS=()
}

@test "spec01 FR-B dotted ids: a stale claim on 'foo.bar' does not falsely skip sweeping a fresh 'foo'" {
  _write_conf "claude:opus" 4 15
  _fake FAKE_CLAUDE_RESULT "OK"
  mkdir -p "$BUS/claimed"
  # foo.bar's claim predates this run and is stale (past LEASE_MIN=15m) — reap() reclaims + re-runs
  # it normally once the pool starts, so THIS run's own gate still closes; what's under test is
  # _enqueue_pending_specs' decision at sweep time, which runs BEFORE reap ever touches it — a bare
  # glob (claimed/"foo".*) would prefix-match this and wrongly skip "foo" too.
  printf 'stale dotted-id claim' > "$BUS/claimed/foo.bar.claude:opus"
  touch -d '-20 minutes' "$BUS/claimed/foo.bar.claude:opus"
  _enqueue foo "a fresh id sharing a glob prefix with the dotted claim"

  run timeout 25 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/foo" ]
  [ -f "$BUS/done/foo.bar" ]
  [ ! -e "$BUS/specs/foo.prompt" ]
}

@test "spec01 FR-B empty-card refusal (2026-07-29): sweep refuses an empty .write sidecar, leaves both card files in specs/, good sibling still completes" {
  _write_conf "claude:opus" 4 15
  _fake FAKE_CLAUDE_RESULT "good sibling answer"
  _enqueue e1 "card whose .write sidecar is whitespace-only"
  printf '   \n\t\n' > "$BUS/specs/e1.write"
  _enqueue g1 "good sibling card, unaffected by e1's refusal"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/g1" ]
  [ "$(<"$BUS/res-g1.txt")" = "good sibling answer" ]
  # e1 stays put — both files, not swept into queue/ — for the operator to fix or remove
  [ -f "$BUS/specs/e1.prompt" ]
  [ -f "$BUS/specs/e1.write" ]
  [ ! -e "$BUS/queue/e1.prompt" ]
  [ ! -e "$BUS/queue/e1.write" ]
  [[ "$output" == *"refused at sweep"* ]]
}

@test "spec04 FR-C: TIMEOUT_GLM overrides WORKER_TIMEOUT_SEC for the glm lane only; the claude lane keeps using the global default" {
  _write_conf "claude:opus" 4 15
  cat >> "$CONF" <<'EOF2'
WORKER_TIMEOUT_SEC=60
EOF2
  export TIMEOUT_GLM=1
  printf 'Z_AI_CODING_KEY=test-glm-key\n' > "$BATS_TEST_TMPDIR/envmaster"
  export ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster"

  _fake FAKE_CLAUDE_ONCE_MARKER "$BATS_TEST_TMPDIR/tc-once"
  _fake FAKE_CLAUDE_ONCE_MODE hang
  _enqueue tc1 "glm branch that hangs — TIMEOUT_GLM=1 must kill it fast, not wait the 60s default"
  echo "glm:glm-5.2" > "$BUS/specs/tc1.lane"

  _fake FAKE_CLAUDE_DELAY 3
  _fake FAKE_CLAUDE_RESULT "claude survived"
  _enqueue tc2 "claude branch — slower than TIMEOUT_GLM=1 but well under WORKER_TIMEOUT_SEC=60"

  run timeout 15 "$RUNSH"
  [ "$status" -ne 0 ]                    # tc1 parked (pinned, no fallback lane)
  [ -f "$BUS/limits/tc1.parked" ]
  [ -f "$BUS/done/tc2" ]
  [ "$(<"$BUS/res-tc2.txt")" = "claude survived" ]
}

@test "spec04 FR-C: an unset TIMEOUT_<LANE> falls back to WORKER_TIMEOUT_SEC" {
  _write_conf "claude:opus" 4 15
  cat >> "$CONF" <<'EOF2'
WORKER_TIMEOUT_SEC=2
EOF2
  unset TIMEOUT_GLM || true
  printf 'Z_AI_CODING_KEY=test-glm-key\n' > "$BATS_TEST_TMPDIR/envmaster"
  export ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster"
  _fake FAKE_CLAUDE_ONCE_MARKER "$BATS_TEST_TMPDIR/tc3-once"
  _fake FAKE_CLAUDE_ONCE_MODE hang
  _enqueue tc3 "glm branch, no TIMEOUT_GLM override — must fall back to the global 2s"
  echo "glm:glm-5.2" > "$BUS/specs/tc3.lane"

  run timeout 15 "$RUNSH"
  [ "$status" -ne 0 ]
  [ -f "$BUS/limits/tc3.parked" ]
}

@test "spec12 FR-D: run-<id>.jsonl rotates per retry attempt — .jsonl.1/.jsonl.2 keep earlier attempts, current file is the last attempt only" {
  _write_conf "claude:opus" 4 15
  cat >> "$CONF" <<'EOF2'
MAX_LANE_RETRIES=3
EOF2
  local counter="$BATS_TEST_TMPDIR/fr-d-attempts"
  _fake FAKE_CLAUDE_ATTEMPT_COUNTER "$counter"
  _enqueue frd1 "card that fails every attempt on the same lane, retried 3 times"

  run timeout 25 "$RUNSH"
  [ "$status" -ne 0 ]
  [ -f "$BUS/limits/frd1.parked" ]

  [ -f "$BUS/run-frd1.jsonl.1" ]
  [ -f "$BUS/run-frd1.jsonl.2" ]
  [ "$(jq -r '.attempt' "$BUS/run-frd1.jsonl.1")" = "1" ]
  [ "$(jq -r '.attempt' "$BUS/run-frd1.jsonl.2")" = "2" ]
  [ "$(jq -r '.attempt' "$BUS/run-frd1.jsonl")" = "3" ]

  # extension-anchored consumers (server.mjs /^run-.*\.jsonl$/, swarm-mon.sh run-*.jsonl globs)
  # must never mistake a rotated attempt for a live worker's current stream.
  local rotname; rotname="$(basename "$BUS/run-frd1.jsonl.1")"
  [[ "$rotname" != run-*.jsonl ]]
  [[ ! "$rotname" =~ ^run-.*\.jsonl$ ]]
}

@test "spec12 FR-D: a zero-byte run-<id>.jsonl from a failed attempt is not rotated" {
  _write_conf "claude:opus" 4 15
  cat >> "$CONF" <<'EOF2'
MAX_LANE_RETRIES=2
EOF2
  _fake FAKE_CLAUDE_SILENT_FAIL 1
  _enqueue frdz "attempt produces zero bytes — nothing to rotate"

  run timeout 20 "$RUNSH"
  [ "$status" -ne 0 ]
  [ -f "$BUS/limits/frdz.parked" ]
  [ ! -e "$BUS/run-frdz.jsonl.1" ]
}

@test "spec10 FR-E: a write landing only under .git/ does not satisfy the diff gate — rejected and parked" {
  _write_conf "claude:opus" 4 15
  local target="$BATS_TEST_TMPDIR/r-e-git"
  mkdir -p "$target/.git"
  touch -d '10 seconds ago' "$target" "$target/.git"
  _fake FAKE_CLAUDE_RESULT "claims done, only touched .git/index"
  _fake FAKE_CLAUDE_WRITE_FILE ".git/index"
  _enqueue reg1 "write card whose only touched path is under .git/"
  printf '%s' "$target" > "$BUS/specs/reg1.write"

  run timeout 25 "$RUNSH"
  [ "$status" -ne 0 ]
  [ ! -e "$BUS/done/reg1" ]
  [ -f "$BUS/limits/reg1.parked" ]
}

@test "spec10 FR-E: bumping only the write target's own directory mtime (create+rm a file) does not satisfy the diff gate" {
  _write_conf "claude:opus" 4 15
  local target="$BATS_TEST_TMPDIR/r-e-dirbump"
  mkdir -p "$target"
  touch -d '10 seconds ago' "$target"
  _fake FAKE_CLAUDE_RESULT "claims done, only bumped the dir's own mtime"
  _fake FAKE_CLAUDE_WRITE_FILE "transient.txt"
  _fake FAKE_CLAUDE_WRITE_THEN_RM 1
  _enqueue reg2 "write card that creates then deletes a file, leaving only a dir mtime bump"
  printf '%s' "$target" > "$BUS/specs/reg2.write"

  run timeout 25 "$RUNSH"
  [ "$status" -ne 0 ]
  [ ! -e "$BUS/done/reg2" ]
  [ -f "$BUS/limits/reg2.parked" ]
  [ -z "$(find "$target" -mindepth 1 2>/dev/null)" ]
}

@test "spec10 FR-E: a real file change under the write target still satisfies the diff gate alongside incidental .git churn" {
  _write_conf "claude:opus" 4 15
  local target="$BATS_TEST_TMPDIR/r-e-real"
  mkdir -p "$target/.git"
  touch -d '10 seconds ago' "$target" "$target/.git"
  _fake FAKE_CLAUDE_RESULT "wrote a real file"
  _fake FAKE_CLAUDE_WRITE_FILE "real.txt"
  _enqueue reg3 "write card with one real change plus a pre-existing .git dir"
  printf '%s' "$target" > "$BUS/specs/reg3.write"

  run timeout 25 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/reg3" ]
  [ -f "$target/real.txt" ]
}

@test "spec10 FR-E: the timeout-salvage path rejects .git-only churn the same way the success path does" {
  _write_conf "claude:opus" 4 15
  cat >> "$CONF" <<'EOF2'
WORKER_TIMEOUT_SEC=2
EOF2
  local target="$BATS_TEST_TMPDIR/sv-e-git"
  mkdir -p "$target/.git"
  touch -d '10 seconds ago' "$target" "$target/.git"
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-sve.jsonl"
  _fake FAKE_CLAUDE_ONCE_MARKER "$BATS_TEST_TMPDIR/sve-once"
  _fake FAKE_CLAUDE_ONCE_MODE hang
  _fake FAKE_CLAUDE_WRITE_FILE ".git/index"
  _enqueue sve "write card killed after touching only .git/ — salvage must still reject it"
  printf '%s' "$target" > "$BUS/specs/sve.write"

  run timeout 25 "$RUNSH"
  [ "$status" -ne 0 ]
  [ ! -e "$BUS/done/sve" ]
  [ -f "$BUS/limits/sve.parked" ]
  [ "$(jq -r 'select(.id=="sve" and .outcome=="timeout") | .class' "$SPEEDWARS_FILE")" = "timeout-watchdog" ]
}

@test "spec14 AC-5 pairing: a card parked via FR-4 session-limit + FR-3 chain-exhaustion is claimed on the seed chain's head after re-publish" {
  # Cross-agent pairing constraint (spec 14 AC-5): needs LIB-1's FR-4 (limit_error session-limit
  # detection, src/swarm-lib.sh) and CTL-1's swarm-ctl add/_reset_card_state — both had landed as
  # of this wave, but this test is written to the spec'd behavior regardless of build order.
  _write_conf "claude:opus" 4 15
  local ctl="$BATS_TEST_DIRNAME/../src/swarm-ctl"
  _fake FAKE_CLAUDE_ERROR_JSON '{"type":"result","subtype":"success","is_error":true,"result":"You'"'"'ve hit your session limit · resets 2:50am (Europe/Prague)"}'
  _enqueue ac5 "card whose only lane hits its session limit and exhausts the chain"

  run timeout 20 "$RUNSH"
  [ "$status" -ne 0 ]
  [ -f "$BUS/limits/ac5.parked" ]
  [ -f "$BUS/limits/claude.limited" ]
  [[ "$(<"$BUS/limits/claude.limited")" == *"session-limit"* ]]

  # operator recovery: cancel the stuck queue entry, clear the (long-TTL) lane flag by hand, then
  # re-publish the SAME id fresh — swarm-ctl add's own _reset_card_state (spec 14 FR-3) clears
  # .parked/.chain-<id>/.retries-<id>.
  run "$ctl" cancel ac5
  [ "$status" -eq 0 ]
  rm -f "$BUS/limits/claude.limited" "$BUS/limits/claude.limited.evidence"
  _fake FAKE_CLAUDE_ERROR_JSON ""
  _fake FAKE_CLAUDE_RESULT "answered on the seed chain's head after re-publish"

  local promptfile="$BATS_TEST_TMPDIR/ac5.prompt"
  printf 'retry from the top' > "$promptfile"
  run "$ctl" add "$promptfile"
  [ "$status" -eq 0 ]

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/ac5" ]
  [ "$(jq -r '.lane' "$BUS/done/ac5")" = "claude" ]
}

# --- spec 14 FR-1: cage-denied failure class ---------------------------------------------------

# The mixed AC-6 denial array, verbatim in shape: two identical read-class denials (dedupe proof),
# one Grep carrying .pattern instead of .file_path, one Bash that must NOT be counted.
_cage_denials_fixture() {
  printf '%s' '[{"tool_name":"Read","tool_use_id":"toolu_1","tool_input":{"file_path":"/tgt/apps/brain-api/src/cockpit/contract.ts"}},{"tool_name":"Read","tool_use_id":"toolu_2","tool_input":{"file_path":"/tgt/apps/brain-api/src/cockpit/contract.ts"}},{"tool_name":"Grep","tool_use_id":"toolu_3","tool_input":{"pattern":"MartCockpitBetWideRowSchema"}},{"tool_name":"Bash","tool_use_id":"toolu_4","tool_input":{"command":"grep -r MartCockpit /tgt/packages/shared"}}]'
}

@test "spec14 FR-1: a read-denied card parks cage-denied — one spawn, no chain walk, paths evidenced, answer text never leaked" {
  _write_conf "claude:opus codex:gpt-5" 4 15
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/sw-cage.jsonl"
  _fake FAKE_CLAUDE_RESULT "CANARYLEAK I was denied every read under the target and cannot proceed"
  _fake FAKE_CLAUDE_DENIALS_JSON "$(_cage_denials_fixture)"
  _fake FAKE_CODEX_RESULT "the fallback lane must never be reached"
  _enqueue cg1 "card the permission cage denies every read to"

  run timeout 20 "$RUNSH"
  [ "$status" -ne 0 ]
  [ -f "$BUS/limits/cg1.parked" ]
  [ -f "$BUS/limits/cg1.cage-denied" ]
  [ ! -e "$BUS/done/cg1" ]

  # NEVER chain-advanced: chain_advance is the only writer of limits/.chain-<id>, and FR-3's
  # chain_reset runs at the chain-exhausted park only — so a cage-denied park leaves that state
  # exactly as it found it (absent here).
  [ ! -e "$BUS/limits/.chain-cg1" ]
  # one spawn, not one per chain rung: the park is this branch's ONLY speedwars row
  [ "$(jq -s '[.[] | select(.id=="cg1")] | length' "$SPEEDWARS_FILE")" = "1" ]
  [ "$(jq -r 'select(.id=="cg1" and .outcome=="parked") | .class' "$SPEEDWARS_FILE")" = "cage-denied" ]

  # marker: line 1 is the count (Bash denial excluded -> 3, not 4), then DEDUPED denied paths
  [ "$(head -1 "$BUS/limits/cg1.cage-denied")" = "denials=3" ]
  [ "$(grep -c . "$BUS/limits/cg1.cage-denied")" = "3" ]
  grep -q '^/tgt/apps/brain-api/src/cockpit/contract.ts$' "$BUS/limits/cg1.cage-denied"
  grep -q '^MartCockpitBetWideRowSchema$' "$BUS/limits/cg1.cage-denied"

  # PII: paths and counts only — no answer text in either marker, and no laundered res file left
  ! grep -q CANARYLEAK "$BUS/limits/cg1.cage-denied"
  ! grep -q CANARYLEAK "$BUS/limits/cg1.parked"
  [ ! -e "$BUS/res-cg1.txt" ]

  # loud: names the count and the denied paths
  [[ "$output" == *"cage denied 3 read-class"* ]]
  [[ "$output" == *"contract.ts"* ]]
}

@test "spec14 FR-1: CAGE_DENY_MAX=20 opts out — the same cage-denied fixture finalizes through the existing gates unchanged" {
  _write_conf "claude:opus codex:gpt-5" 4 15
  cat >> "$CONF" <<'EOF2'
CAGE_DENY_MAX=20
EOF2
  _fake FAKE_CLAUDE_RESULT "denied some reads but delivered anyway"
  _fake FAKE_CLAUDE_DENIALS_JSON "$(_cage_denials_fixture)"
  _enqueue cg2 "card the cage denies a few reads to, which still delivers"

  run timeout 20 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/cg2" ]
  [ ! -e "$BUS/limits/cg2.parked" ]
  [ ! -e "$BUS/limits/cg2.cage-denied" ]
  [ "$(<"$BUS/res-cg2.txt")" = "denied some reads but delivered anyway" ]
}

# --- spec 14 FR-2: per-card deliverable manifest (queue/<id>.files) ----------------------------

# _files_card <id> <target> <manifest-lines> — a write card with a deliverable manifest, plus two
# pre-existing files whose mtimes sit safely OUTSIDE the gate's ~2s pre-spawn slack window.
_files_card() {
  local id="$1" target="$2" manifest="$3"
  mkdir -p "$target"
  printf 'old\n' > "$target/a.ts"
  printf 'old\n' > "$target/b.ts"
  touch -d '30 seconds ago' "$target/a.ts" "$target/b.ts" "$target"
  _enqueue "$id" "write card with a deliverable manifest"
  printf '%s' "$target" > "$BUS/specs/$id.write"
  printf '%s' "$manifest" > "$BUS/specs/$id.files"
}

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
  PATH="$stub:$PATH" MON_AUTOOPEN=1 MON_PORT=39999 \
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
