#!/usr/bin/env bats
# RED wave for spec 21 (speed/timeline observability) — FR-2/3/4/5: probe timeout cap, probe FAIL
# fidelity, finalize bench stderr tail, and the distinct-card bench threshold. None of this is
# implemented yet (see specs/21-speed-observability.md), so every test below currently FAILS on its
# assertions — but the file parses cleanly and setup() depends on no unimplemented feature.
#
# Project: unimatrix — multi-model swarm orchestrator driven from Claude Code
# Module:  tests/probe-bench.bats
# Deps:    bats-core, src/swarm-lib.sh, swarm-run.sh, fake claude/codex/grok on PATH
# Tested:  n/a — this is the test file
#
# Design constraints:
# - Self-contained _install_fakes modeled on tests/swarm-run.bats: fakes source $BIN/fake.conf (a
#   FILE, never inherited env) because lane_cmd wraps every real invocation in `env -i`, which would
#   otherwise strip every FAKE_* knob. Tests call `_fake NAME value` to set a knob.
# - Driver tests: invoke swarm-run.sh as a real subprocess over PATH-shimmed fakes (no real API
#   calls). PROBE_AUTO=1 only in the probe tests; the bench/finalize tests keep PROBE_AUTO=0 so a
#   pre-claim probe can't mark the lane .broken before the worker ever runs (which would route the
#   card around it and defeat the finalize-path fixture).
# - Marker assertions reuse the production _marker_ttl parser (sourced in a fresh bash, same idiom as
#   swarm-run.bats's limit_active_probe) rather than re-implementing the FR-7 reason-line parse — one
#   producer, one parser, no drift.

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
  # full_run calls mon_web_ensure/mon_web_open (specs/05-ground-control.md); the default
  # MON_AUTOOPEN=1/MON_PORT=4747 would probe/spawn against the REAL port 4747 and the real .bus.
  export MON_AUTOOPEN=0
  # _scratch_home (src/swarm-lib.sh) reads $HOME/.claude, $HOME/.codex — never let a test touch the
  # real user's actual credentials; every test gets its own throwaway "real" home instead.
  export HOME="$BATS_TEST_TMPDIR/realhome"
  mkdir -p "$HOME"
  # _scratch_home honors CLAUDE_CONFIG_DIR (multi-account) — unset so this box's own ambient session
  # dir never leaks real credentials into a test's throwaway scratch home.
  unset CLAUDE_CONFIG_DIR
  # env_master_preflight (spec 13 FR-1) aborts a run whose lane set touches gemini/glm/kimi when
  # $ENV_MASTER_FILE is unreadable — give every test a working default (all three env-key lanes
  # present) so fixtures keep working out of the box; a test wanting the missing-file scenario
  # overrides ENV_MASTER_FILE itself afterward.
  printf 'Z_AI_CODING_KEY=default-glm-key\nMOONSHOT_API_KEY=default-kimi-key\nGEMINI_API_KEY=default-gem-key\n' \
    > "$BATS_TEST_TMPDIR/envmaster-default"
  export ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster-default"
  # spec 13 FR-6: auto live-probes default ON for operators — OFF for this suite (env outranks conf
  # per FR-1), or every non-probe test would fire a probe per lane. The probe tests re-export
  # PROBE_AUTO=1 themselves.
  export PROBE_AUTO=0
  # never let a finalized card's ledger row land in the repo's real docs/ops — pin it to tmp.
  export LEDGER_FILE="$BATS_TEST_TMPDIR/probe-bench-ledger.md"
  BG_PIDS=()
  _install_fakes
}

teardown() {
  local p
  for p in "${BG_PIDS[@]:-}"; do
    [ -n "$p" ] && kill -9 "$p" 2>/dev/null
    [ -n "$p" ] && wait "$p" 2>/dev/null
  done
  # belt-and-braces: nothing from this test's bus/bin should survive it
  pkill -9 -f "$BATS_TEST_TMPDIR" 2>/dev/null || true
  return 0
}

# _fake <NAME> <value> — appends NAME="value" to $BIN/fake.conf (bash-%q-escaped), which every fake
# CLI sources on its own via ${BASH_SOURCE[0]}'s dirname. A FILE, not an env var, on purpose: it must
# survive lane_cmd's `env -i` wrapping around the real invocation (and the probe's own `env -i` cage).
_fake() { printf '%s=%q\n' "$1" "$2" >> "$BIN/fake.conf"; }

# Minimal self-contained fakes — only the three lanes these tests exercise (claude, codex, grok) and
# only the knobs they need. Each mirrors the corresponding fake in tests/swarm-run.bats but is trimmed
# to the probe/bench behaviors under test.
_install_fakes() {
  : > "$BIN/fake.conf"

  # Fake claude (also serves the probe cage for the claude lane). Knobs: FAKE_CLAUDE_RESULT,
  # FAKE_CLAUDE_EXIT (default 0), FAKE_CLAUDE_DELAY (always applied), FAKE_CLAUDE_STDERR (writes a
  # distinctive line to fd 2 BEFORE anything else — FR-3's probe child stderr, which the probe must
  # capture rather than discard).
  cat > "$BIN/claude" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$_here/fake.conf" ]] && source "$_here/fake.conf"
[[ -n "${FAKE_CLAUDE_STDERR:-}" ]] && printf '%s\n' "$FAKE_CLAUDE_STDERR" >&2
sleep "${FAKE_CLAUDE_DELAY:-0}"
echo '{"type":"init"}'
printf '{"type":"result","result":"%s"}\n' "${FAKE_CLAUDE_RESULT:-OK}"
exit "${FAKE_CLAUDE_EXIT:-0}"
FAKE

  # Fake codex. The probe arm invokes it WITHOUT --output-last-message (so outfile stays empty); the
  # worker arm passes --output-last-message <res-file>, which is where the handoff answer is written.
  cat > "$BIN/codex" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$_here/fake.conf" ]] && source "$_here/fake.conf"
outfile=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  [[ "${args[$i]}" == "--output-last-message" ]] && outfile="${args[$((i + 1))]}"
done
sleep "${FAKE_CODEX_DELAY:-0}"
echo '{"type":"thread.started"}'
[[ -n "$outfile" ]] && printf '%s' "${FAKE_CODEX_RESULT:-codex OK}" > "$outfile"
echo '{"type":"turn.completed","usage":{"input_tokens":10}}'
exit "${FAKE_CODEX_EXIT:-0}"
FAKE

  # Fake grok. FAKE_GROK_ERROR short-circuits to an error event + exit 1 with NO end/modelUsage
  # event — served_model is then empty, the lane-down arm fires at retries-exhausted (the spec13 FR-3
  # fast-fail shape). FAKE_GROK_STDERR writes a distinctive line to fd 2 — FR-4's run-<id>.jsonl.stderr
  # tail (captured at spawn via 2>>), which the finalize bench must include in the marker.
  cat > "$BIN/grok" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$_here/fake.conf" ]] && source "$_here/fake.conf"
[[ -n "${FAKE_GROK_STDERR:-}" ]] && printf '%s\n' "$FAKE_GROK_STDERR" >&2
if [[ -n "${FAKE_GROK_ERROR:-}" ]]; then
  printf '{"type":"error","message":"%s"}\n' "${FAKE_GROK_ERROR}"
  exit 1
fi
echo '{"type":"thought","data":"thinking..."}'
content="$(printf '%s' "${FAKE_GROK_RESULT:-grok OK}" | jq -Rs .)"
printf '{"type":"text","data":%s}\n' "$content"
printf '{"type":"end","stopReason":"EndTurn","usage":{"input_tokens":1},"modelUsage":{"grok-4.5-build":{"inputTokens":1}}}\n'
exit "${FAKE_GROK_EXIT:-0}"
FAKE

  chmod +x "$BIN/claude" "$BIN/codex" "$BIN/grok"
}

_enqueue() {
  local id="$1" text="$2"
  mkdir -p "$BUS/specs"
  printf '%s' "$text" > "$BUS/specs/$id.prompt"
}

_write_conf() {
  cat > "$CONF" <<EOF
EXEC_CHAIN="${1:-claude:opus codex:default}"
FANOUT=${2:-4}
LEASE_MIN=${3:-15}
EOF
}

# _marker_ttl_probe <file> <default> — reuse the production _marker_ttl parser (the FR-7 reason-line
# reader) by sourcing swarm-lib in a fresh bash. Same idiom as swarm-run.bats's limit_active_probe:
# these helpers aren't on PATH in a driver test, so source the lib to call them rather than fork a
# second copy of the parse rule. Echoes exactly one value (the resolved ttl) on stdout.
_marker_ttl_probe() {
  bash -c 'source "$1"; _marker_ttl "$2" "$3"' _ \
    "$BATS_TEST_DIRNAME/../src/swarm-lib.sh" "$1" "$2"
}

# --- FR-3: probe FAIL marker fidelity ----------------------------------------------------------
# _probe_lane_event calls `broken_flag "$BUSDIR" "$bare"` with NO args today -> default ttl=1800,
# reason text "lane claude fast-failed", and the probe arm redirects the CLI's 2>&1 to /dev/null, so
# the child's actual stderr is discarded entirely. Spec FR-3 (as amended for spec 14 FR-7
# scrub-by-construction — marker text carries paths/tokens, never stderr CONTENT): ttl=600, the
# reason line carries the probe's failure text ($out) plus a diag= PATH, and the <=200-byte stderr
# tail itself lands in the bus-local limits/<lane>.probe-stderr diag file.

@test "spec21 FR-3: an auto-probe FAIL writes limits/<lane>.broken with ttl=600 (NOT 1800), the probe FAIL text + diag path in the reason, stderr tail in the diag file" {
  _write_conf "claude:opus codex:default" 4 15
  export PROBE_AUTO=1
  _fake FAKE_CLAUDE_EXIT 1
  _fake FAKE_CLAUDE_STDERR "PROBEFAIL_STDERR_ZZ"
  _fake FAKE_CODEX_RESULT "codex rescued it"
  _enqueue pb1 "card whose claude lane probe-fails"

  run timeout 30 "$RUNSH"
  # claude probe-fails -> .broken -> the card failovers to codex and completes either way (today and
  # under spec); the decisive assertions are on the marker body below.
  [ "$status" -eq 0 ]
  [ -f "$BUS/limits/claude.broken" ]
  # today this is 1800 (broken_flag's default); spec FR-3 is 600.
  [ "$(_marker_ttl_probe "$BUS/limits/claude.broken" 1800)" = "600" ]
  m="$(<"$BUS/limits/claude.broken")"
  # today the text is "lane claude fast-failed" — no probe-failure text, no diag pointer.
  [[ "$m" == *"FAIL exit 1"* ]]
  [[ "$m" == *"diag=limits/claude.probe-stderr"* ]]
  # the stderr CONTENT lives in the diag file, never in the marker (spec 14 FR-7 scrub doctrine)
  grep -q "PROBEFAIL_STDERR_ZZ" "$BUS/limits/claude.probe-stderr"
  [[ "$m" != *"PROBEFAIL_STDERR_ZZ"* ]]
}

# --- FR-2: probe timeout cap resolution --------------------------------------------------------
# _doctor_probe_lane hardcodes `timeout 10` for claude (only codex gets 30). Spec FR-2: a
# PROBE_TIMEOUT_SEC conf key; claude and codex default to 30 (cold-start), an explicit value applies
# to all lanes, and timeout messages quote the resolved cap.

@test "spec21 FR-2: a claude probe that takes 12s PASSES under the new 30s cold-start default — no .broken, card completes" {
  # Today the 10s cap kills the 12s probe -> rc 124 -> "timeout (10s)" FAIL -> claude.broken, and with
  # claude the only lane the card parks (nonzero exit, no done marker). Spec FR-2's 30s claude default
  # lets the same probe PASS (12s < 30s): no marker, card served by claude. The double 12s sleep
  # (probe then worker) is why the timeout margin is generous.
  _write_conf "claude:opus" 4 15
  export PROBE_AUTO=1
  _fake FAKE_CLAUDE_DELAY 12
  _enqueue pb2 "card served by a slow-but-healthy claude"

  run timeout 60 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/pb2" ]
  [ ! -e "$BUS/limits/claude.broken" ]
}

@test "spec21 FR-2: PROBE_TIMEOUT_SEC=1 overrides all lanes — a 5s claude probe FAILs and the marker quotes (1s)" {
  # Today PROBE_TIMEOUT_SEC is not a conf key and _doctor_probe_lane ignores it (hardcoded 10s for
  # claude); a 5s probe is UNDER 10s -> PASS -> no .broken (the card runs on claude). Spec FR-2: an
  # explicit PROBE_TIMEOUT_SEC applies to every lane; 5s > 1s -> "timeout (1s)" FAIL -> .broken whose
  # reason line quotes the resolved cap.
  _write_conf "claude:opus codex:default" 4 15
  export PROBE_AUTO=1
  export PROBE_TIMEOUT_SEC=1
  _fake FAKE_CLAUDE_DELAY 5
  _fake FAKE_CODEX_RESULT "codex rescued it"
  _enqueue pb3 "card whose claude probe is capped at 1s"

  run timeout 30 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/limits/claude.broken" ]
  m="$(<"$BUS/limits/claude.broken")"
  # the resolved cap quoted in the probe's FAIL text ("FAIL timeout (1s)")
  [[ "$m" == *"(1s)"* ]]
  [ "$(_marker_ttl_probe "$BUS/limits/claude.broken" 1800)" = "600" ]
}

# --- FR-4: finalize bench stderr pointer -------------------------------------------------------
# The retries-exhausted lane-down arm calls `broken_flag "$BUSDIR" "$bare"` with the default text
# "lane grok fast-failed" — it never references run-<id>.jsonl.stderr (captured at spawn via 2>>).
# Spec FR-4 (as amended for spec 14 FR-7 scrub-by-construction): the marker points at that stderr
# file BY PATH (stderr=run-<id>.jsonl.stderr) when it is non-empty — the drill-down evidence is on
# the bus already; its CONTENT never enters a marker line. Mirrors the spec13 FR-3 fast-fail
# fixture (grok errors, claude rescues) plus a distinctive stderr string proving capture.

@test "spec21 FR-4: the finalize lane-down bench points at run-<id>.jsonl.stderr in the marker reason line" {
  _write_conf "grok:default claude:opus" 4 15
  cat >> "$CONF" <<'EOF2'
MAX_LANE_RETRIES=1
EOF2
  _fake FAKE_GROK_ERROR "kaboom internal crash"
  _fake FAKE_GROK_STDERR "STDERR_TAIL_FR4"
  _fake FAKE_CLAUDE_RESULT "claude rescued it"
  _enqueue pb4 "card that fast-fails on grok with a stderr tail"

  run timeout 30 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/limits/grok.broken" ]
  # sanity: the worker's stderr was actually captured to the sidecar (the spawn redirects fd 2 there)
  [ -s "$BUS/run-pb4.jsonl.stderr" ]
  m="$(<"$BUS/limits/grok.broken")"
  # today the text is "lane grok fast-failed" — no stderr pointer; content stays OUT of the marker
  [[ "$m" == *"stderr=run-pb4.jsonl.stderr"* ]]
  [[ "$m" != *"STDERR_TAIL_FR4"* ]]
}

# --- FR-5: BROKEN_MIN_CARDS distinct-card bench threshold --------------------------------------
# Today the lane-down arm always benches at the broken_flag default (1800s) and there is no
# .failcards-<lane> accumulation at all. Spec FR-5: append the card id to limits/.failcards-<bare> per
# fast-fail; the 1800s bench fires only at >= BROKEN_MIN_CARDS (default 2) DISTINCT fast-failed ids on
# that lane this run; below threshold write the 600s short-TTL form.

@test "spec21 FR-5: ONE fast-failed card is below BROKEN_MIN_CARDS(2) — marker is the 600s short-TTL form, id recorded in .failcards" {
  _write_conf "grok:default claude:opus" 4 15
  cat >> "$CONF" <<'EOF2'
MAX_LANE_RETRIES=1
EOF2
  _fake FAKE_GROK_ERROR "kaboom internal crash"
  _fake FAKE_CLAUDE_RESULT "claude rescued it"
  _enqueue pb5a "single card that fast-fails on grok"

  run timeout 30 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/limits/grok.broken" ]
  # today: broken_flag's default 1800; spec FR-5: 1 distinct id < 2 -> short-TTL 600
  [ "$(_marker_ttl_probe "$BUS/limits/grok.broken" 1800)" = "600" ]
  # today: no .failcards file is ever written
  [ -f "$BUS/limits/.failcards-grok" ]
  grep -qx "pb5a" "$BUS/limits/.failcards-grok"
}

@test "spec21 FR-5: TWO distinct fast-failed cards reach BROKEN_MIN_CARDS(2) — marker is the 1800s bench, both ids in .failcards" {
  # The ttl=1800 half already matches today by coincidence (today always benches at 1800); the
  # .failcards-<lane> file is what never exists today, so its assertion is the RED driver. Both cards
  # spawn grok in the pool's initial claim burst (FANOUT=4, two cards) before either finalizes and
  # marks the lane, so both genuinely fast-fail on grok this run — deterministically, no polling.
  _write_conf "grok:default claude:opus" 4 15
  cat >> "$CONF" <<'EOF2'
MAX_LANE_RETRIES=1
EOF2
  _fake FAKE_GROK_ERROR "kaboom internal crash"
  _fake FAKE_CLAUDE_RESULT "claude rescued it"
  _enqueue pb5b1 "first of two cards that fast-fail on grok"
  _enqueue pb5b2 "second of two cards that fast-fail on grok"

  run timeout 40 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/pb5b1" ]
  [ -f "$BUS/done/pb5b2" ]
  [ -f "$BUS/limits/grok.broken" ]
  # today: limits/.failcards-<lane> is never written
  [ -f "$BUS/limits/.failcards-grok" ]
  grep -qx "pb5b1" "$BUS/limits/.failcards-grok"
  grep -qx "pb5b2" "$BUS/limits/.failcards-grok"
  # spec FR-5: >= 2 distinct ids -> 1800s bench (the second finalize always sees both ids and is the
  # last writer, so the final marker ttl is 1800 regardless of which card finalizes first)
  [ "$(_marker_ttl_probe "$BUS/limits/grok.broken" 1800)" = "1800" ]
}
