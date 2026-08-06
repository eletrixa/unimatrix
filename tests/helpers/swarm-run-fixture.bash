# Shared fixture for the tests/swarm-run-*.bats shards: setup/teardown, PATH-shimmed fake CLIs
# (claude/codex/gemini/docker/grok/curl), enqueue/conf/poll helpers, and the mid-file probe/fixture
# helpers the shards' tests call. Loaded by every shard via `load 'helpers/swarm-run-fixture'`.
#
# Project: unimatrix — multi-model swarm orchestrator driven from Claude Code
# Module:  tests/helpers/swarm-run-fixture.bash
# Deps:    bats-core, src/swarm-lib.sh, swarm-run.sh, fake claude/codex/gemini on PATH
# Tested:  n/a — test fixture (exercised by tests/swarm-run-1.bats .. tests/swarm-run-4.bats)
#
# Design constraints:
# - Fakes read their behavior from $BIN/fake.conf (sourced via ${BASH_SOURCE[0]}'s own dirname),
#   NOT from inherited env vars — lane_cmd wraps every real invocation in `env -i` (containment,
#   FR-12/13 step), which would otherwise strip every FAKE_* knob the old env-var mechanism relied
#   on. Tests call `_fake NAME value` instead of `export FAKE_NAME=value`.
# - Extracted VERBATIM from the former tests/swarm-run.bats preamble + its mid-file helper
#   functions; $BATS_TEST_DIRNAME still resolves to tests/ (the loading .bats file's dir).

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

# limit_active isn't on PATH as a command — probe it by sourcing the lib in a fresh bash.
limit_active_probe() {
  bash -c "source '$BATS_TEST_DIRNAME/../src/swarm-lib.sh'; limit_active '$1' '$2'"
}

# _plant_drifted_skill — a hand-copied (non-symlink) SKILL.md under the test's throwaway $HOME,
# which is exactly what doctor_skill_drift is built to FAIL on.
_plant_drifted_skill() {
  mkdir -p "$HOME/.claude/skills/unimatrix"
  printf 'a hand copy, not a symlink\n' > "$HOME/.claude/skills/unimatrix/SKILL.md"
}

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

# The mixed AC-6 denial array, verbatim in shape: two identical read-class denials (dedupe proof),
# one Grep carrying .pattern instead of .file_path, one Bash that must NOT be counted.
_cage_denials_fixture() {
  printf '%s' '[{"tool_name":"Read","tool_use_id":"toolu_1","tool_input":{"file_path":"/tgt/apps/brain-api/src/cockpit/contract.ts"}},{"tool_name":"Read","tool_use_id":"toolu_2","tool_input":{"file_path":"/tgt/apps/brain-api/src/cockpit/contract.ts"}},{"tool_name":"Grep","tool_use_id":"toolu_3","tool_input":{"pattern":"MartCockpitBetWideRowSchema"}},{"tool_name":"Bash","tool_use_id":"toolu_4","tool_input":{"command":"grep -r MartCockpit /tgt/packages/shared"}}]'
}

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
