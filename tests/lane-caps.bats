#!/usr/bin/env bats
# RED-phase tests for spec 21 FR-13/14/15 (parallelism knobs). NONE of these features exist in
# today's code, so every assertion below is expected to FAIL on the current tree — the GREEN wave
# flips them:
#   FR-13 — _try_claim_one (swarm-run.sh:366) has NO per-lane in-flight counting; LANE_MAX_<LANE>
#           is not in CONF_KEYS (src/swarm-lib.sh:132), so the conf line is silently ignored. A
#           lane's claims are bounded only by FANOUT.
#   FR-14 — _try_claim_one iterates `for f in "$BUSDIR"/queue/*.prompt` (swarm-run.sh:370) in
#           LEXICOGRAPHIC glob order; FR-14 reorders that to DESCENDING prompt byte-size.
#   FR-15 — src/swarm-lib.sh:158 is `: "${FANOUT:=4}"`; FR-15 raises the baked default to 6.
#
# Project: unimatrix — multi-model swarm orchestrator driven from Claude Code
# Module:  tests/lane-caps.bats
# Deps:    bats-core, src/swarm-lib.sh, swarm-run.sh, fake claude/codex on PATH
# Tested:  n/a — this is the test file
#
# Design constraints:
# - Driver tests mirror tests/swarm-run.bats: PATH-shimmed fakes under $BATS_TEST_TMPDIR/bin that
#   read $BIN/fake.conf (sourced via the fake's own dirname), NEVER inherited env — lane_cmd wraps
#   every real invocation in `env -i` (containment), which strips env-var knobs. Tests call
#   `_fake NAME value`. Assert on the DECISIVE line/field (one awk key, one mtime), never full output.
# - FR-15 is a pure-function test mirroring tests/swarm-lib.bats: it sources src/swarm-lib.sh and
#   calls conf_load directly. The existing 4-asserts in swarm-lib.bats/swarm-run.bats are untouched
#   (the GREEN wave owns updating those).

RUNSH="$BATS_TEST_DIRNAME/../swarm-run.sh"
LIB="$BATS_TEST_DIRNAME/../src/swarm-lib.sh"

setup() {
  BUS="$BATS_TEST_TMPDIR/bus"
  CONF="$BATS_TEST_TMPDIR/swarm.conf"
  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN"
  export PATH="$BIN:$PATH"
  export BUSDIR="$BUS"
  export CONF
  export HEARTBEAT_SEC=1
  # Disable the same-lane first-spawn stagger gate (specs/04, default 10s). These tests put MULTIPLE
  # cards on ONE lane (FR-13: three claude cards) to exercise the cap; with stagger ON, a same-lane
  # follower waits for the first worker's output before spawning — which would serialize the START
  # lines even with NO cap, masking today's RED (peak in-flight would read as 1, not 3). Stagger=0
  # removes that confound so cap-enforcement is the ONLY thing throttling same-lane concurrency.
  export STAGGER_FIRST_SPAWN_SEC=0
  # full_run calls mon_web_ensure/mon_web_open (specs/05-ground-control.md) — a default MON_AUTOOPEN
  # would probe/spawn the REAL port 4747 against the real .bus. Disable; this suite is lane-mechanics
  # only, no ground control.
  export MON_AUTOOPEN=0
  # spec 13 FR-6: auto live-probes default ON for operators — OFF here, or every run would fire a
  # probe per lane (extra fake invocations, real-provider API risk). None of these tests are probes.
  export PROBE_AUTO=0
  # _scratch_home (src/swarm-lib.sh) reads $HOME/.claude, $HOME/.codex — never let a test touch the
  # real user's credentials; every test gets its own throwaway "real" home.
  export HOME="$BATS_TEST_TMPDIR/realhome"
  mkdir -p "$HOME"
  # _scratch_home also honors CLAUDE_CONFIG_DIR (multi-account) — unset so this box's ambient
  # account dir never leaks real credentials into a test's scratch home.
  unset CLAUDE_CONFIG_DIR
  # spec 13 FR-1: env_master_preflight aborts a run whose lane set touches gemini/glm/kimi if
  # $ENV_MASTER_FILE is unreadable. These tests pin only claude/codex (no env-master key needed),
  # but keep a readable default so any lane_cmd sanity read is satisfied.
  printf 'Z_AI_CODING_KEY=default-glm-key\nMOONSHOT_API_KEY=default-kimi-key\nGEMINI_API_KEY=default-gem-key\n' \
    > "$BATS_TEST_TMPDIR/envmaster-default"
  export ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster-default"
  # LEDGER_AUTO defaults to 1 — never let a finalized card's run-evidence row land in the repo's real
  # docs/ops; force every row into a throwaway tmp path (the default resolves under the tmp busdir
  # anyway, but this is belt-and-braces).
  export LEDGER_FILE="$BATS_TEST_TMPDIR/ledger.md"
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
# CLI sources via its own dirname. A FILE, not an env var, on purpose: it must survive lane_cmd's
# `env -i` wrapping of the real invocation.
_fake() { printf '%s=%q\n' "$1" "$2" >> "$BIN/fake.conf"; }

# Lean, self-contained fake installer (modeled on tests/swarm-run.bats's _install_fakes). Only the
# two lanes these tests touch — claude and codex — are shimmed; no gemini/docker/grok/curl fakes are
# needed (no probe, no sandbox, no other lane is exercised).
_install_fakes() {
  : > "$BIN/fake.conf"
  # Fake claude: when $FAKE_CLAUDE_LOG is set, records a timestamped `START <prompt-bytes>` line on
  # entry and a `STOP` line on exit — the [START,STOP] pair brackets one in-flight serve, so a test
  # can prove cap-enforced serialization (no two serves ever overlap) AND serve ordering (START lines
  # carry the prompt byte-size, in serve order). Sleeps $FAKE_CLAUDE_DELAY, then emits the claude-
  # shaped result envelope extract_answer reads.
  cat > "$BIN/claude" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$_here/fake.conf" ]] && source "$_here/fake.conf"
_log="${FAKE_CLAUDE_LOG:-}"
# prompt text is the trailing argv; with no spaces it is a single word, so this is its exact byte size
_sz="$(printf '%s' "$*" | wc -c)"
[[ -n "$_log" ]] && printf '%s START %s\n' "$(date +%s.%N)" "$_sz" >> "$_log"
sleep "${FAKE_CLAUDE_DELAY:-0}"
echo '{"type":"init"}'
printf '{"type":"result","result":"%s"}\n' "${FAKE_CLAUDE_RESULT:-OK}"
[[ -n "$_log" ]] && printf '%s STOP\n' "$(date +%s.%N)" >> "$_log"
exit "${FAKE_CLAUDE_EXIT:-0}"
FAKE
  # Fake codex: fast by default; honors --output-last-message (writes the handoff file the codex
  # lane's extract_answer validates) and emits a turn.completed envelope. No env-master key needed.
  cat > "$BIN/codex" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$_here/fake.conf" ]] && source "$_here/fake.conf"
_outfile=""
_args=("$@")
for ((i = 0; i < ${#_args[@]}; i++)); do
  if [[ "${_args[$i]}" == "--output-last-message" ]]; then _outfile="${_args[$((i + 1))]}"; fi
done
sleep "${FAKE_CODEX_DELAY:-0}"
echo '{"type":"thread.started"}'
[[ -n "$_outfile" ]] && printf '%s' "${FAKE_CODEX_RESULT:-codex OK}" > "$_outfile"
echo '{"type":"turn.completed","usage":{"input_tokens":10}}'
exit "${FAKE_CODEX_EXIT:-0}"
FAKE
  chmod +x "$BIN/claude" "$BIN/codex"
}

# _enqueue <id> <text> — drop a specs/<id>.prompt (swarm-run.sh's _enqueue_pending_specs moves it to
# queue/ at run start).
_enqueue() {
  local id="$1" text="$2"
  mkdir -p "$BUS/specs"
  printf '%s' "$text" > "$BUS/specs/$id.prompt"
}

# _pin <id> <lane:model> — drop a specs/<id>.lane sidecar (FR-2b pin); _enqueue_pending_specs moves
# it to queue/ alongside the prompt, so the card bypasses EXEC_CHAIN and runs on this one lane.
_pin() { printf '%s' "$2" > "$BUS/specs/$1.lane"; }

# _repeat <n> <ch> — n copies of ch, no spaces (so the prompt is a single argv word and its byte
# count is exact — FR-14's job-length proxy).
_repeat() { printf "%${1}s" "" | tr ' ' "$2"; }

_write_conf() {
  cat > "$CONF" <<EOF
EXEC_CHAIN="${1:-claude:opus}"
FANOUT=${2:-4}
LEASE_MIN=${3:-15}
EOF
}

# --- FR-13: per-lane in-flight caps (LANE_MAX_<LANE>) ------------------------------------------
# NOT YET IMPLEMENTED. _try_claim_one has no per-lane in-flight counting today, and LANE_MAX_CLAUDE
# is not a CONF_KEYS entry, so the conf line below is silently ignored — claude's claims are bounded
# only by FANOUT.

@test "FR-13: LANE_MAX_CLAUDE=1 serializes three claude-pinned cards — no two claude serves overlap" {
  _write_conf "claude:opus" 4 15
  cat >> "$CONF" <<'EOF'
LANE_MAX_CLAUDE=1
EOF
  _fake FAKE_CLAUDE_LOG "$BIN/calls.log"
  _fake FAKE_CLAUDE_DELAY 2
  _enqueue c1 "claude card one";   _pin c1 "claude:opus"
  _enqueue c2 "claude card two";   _pin c2 "claude:opus"
  _enqueue c3 "claude card three"; _pin c3 "claude:opus"

  run timeout 30 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/c1" ]; [ -f "$BUS/done/c2" ]; [ -f "$BUS/done/c3" ]

  # all three were actually served — the cap serializes, it never starves a card
  starts="$(awk '$2=="START"{n++} END{print n+0}' "$BIN/calls.log")"
  [ "$starts" -eq 3 ]
  # DECISIVE RED assertion: the cap means claude serves NEVER overlap — at no instant are two claude
  # workers in flight. Today (no cap, FANOUT=4) all three spawn in the first pool tick and overlap for
  # the full 2s sleep, so peak in-flight is 3, not 1. (starts==3 above rules out a vacuous 0 pass.)
  peak_inflight="$(awk '
    $2=="START" { c++; if (c>m) m=c }
    $2=="STOP"  { c-- }
    END         { print m+0 }
  ' "$BIN/calls.log")"
  echo "peak concurrent claude serves: $peak_inflight (cap=1 wants <=1; today gives 3)" >&2
  [ "$peak_inflight" -le 1 ]
}

@test "FR-13: a capped claude lane never wedges the pool — a codex card finishes alongside it, not after both claude cards" {
  # Regression guard for the GREEN cap impl. FR-13's skip (not block) semantics mean a capped lane
  # never serializes the WHOLE pool: when claude is at its cap, _try_claim_one `continue`s to other
  # cards/lanes instead of waiting. A naive cap that blocks the claim loop would force the fast codex
  # card to sit behind the serialized claude pair and finish LAST. This asserts that does not happen:
  # codex's done-marker mtime is NOT strictly after BOTH claude cards'. Pure integer-second ordering,
  # no tight slack. (Passes today — there is no cap, hence no wedge — and stays green for a correct
  # GREEN; it fails only for a wedging GREEN impl, which is exactly the regression it guards.)
  _write_conf "claude:opus" 3 15
  cat >> "$CONF" <<'EOF'
LANE_MAX_CLAUDE=1
EOF
  _fake FAKE_CLAUDE_DELAY 2
  _enqueue w1 "claude slow one"; _pin w1 "claude:opus"
  _enqueue w2 "claude slow two"; _pin w2 "claude:opus"
  _enqueue x1 "codex fast card"; _pin x1 "codex:default"

  run timeout 30 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/w1" ]; [ -f "$BUS/done/w2" ]; [ -f "$BUS/done/x1" ]

  mw1="$(stat -c %Y "$BUS/done/w1")"
  mw2="$(stat -c %Y "$BUS/done/w2")"
  mx="$(stat -c %Y "$BUS/done/x1")"
  echo "done-marker mtimes: w1=$mw1 w2=$mw2 x1(codex)=$mx" >&2
  # codex is NOT strictly after BOTH claude cards — the capped lane did not serialize the pool.
  ! (( mx > mw1 && mx > mw2 ))
}

# --- FR-14: longest-job-first claiming ---------------------------------------------------------
# NOT YET IMPLEMENTED. _try_claim_one iterates queue/*.prompt in LEXICOGRAPHIC glob order; FR-14
# reorders to DESCENDING prompt byte-size (deterministic name tie-break). FANOUT=1 makes the pool
# serve strictly one card at a time, so serve order == claim order — fully deterministic.

@test "FR-14: with FANOUT=1 the larger prompt is claimed and served FIRST (descending byte-size)" {
  _write_conf "claude:opus" 1 15
  _fake FAKE_CLAUDE_LOG "$BIN/calls.log"
  # small (~50B) with an id that sorts LEXICOGRAPHICALLY FIRST; large (~5000B) sorting second. No
  # spaces => single argv word => exact byte count recorded by the fake. Today's glob order serves
  # a01small first; FR-14 serves z99large first.
  _enqueue a01small "$(_repeat 50 a)"
  _enqueue z99large "$(_repeat 5000 a)"

  run timeout 30 "$RUNSH"
  [ "$status" -eq 0 ]
  [ -f "$BUS/done/a01small" ]; [ -f "$BUS/done/z99large" ]

  # serve order = START lines' prompt byte-sizes, in order. DECISIVE RED assertion: the FIRST served
  # prompt is the LARGE one (~5000). Today (lex glob) serves a01small (~50) first, so this is < 4000.
  first_served="$(awk '$2=="START"{print $3; exit}' "$BIN/calls.log")"
  echo "first-served prompt byte-size: $first_served (FR-14 wants ~5000; today's glob gives ~50)" >&2
  [ "$first_served" -ge 4000 ]
}

# --- FR-15: FANOUT baked default 4 -> 6 ---------------------------------------------------------
# NOT YET IMPLEMENTED — src/swarm-lib.sh:158 is `: "${FANOUT:=4}"`. Pure-function assert mirroring
# the conf_load default tests in tests/swarm-lib.bats (which still pin 4; the GREEN wave updates
# THOSE — this file asserts the NEW 6 and leaves the existing asserts untouched).

@test "FR-15: conf_load baked default for FANOUT is 6 (was 4)" {
  unset FANOUT
  # shellcheck source=/dev/null
  source "$LIB"
  conf_load "$BATS_TEST_TMPDIR/nonexistent.conf"
  [ "$FANOUT" = "6" ]
}
