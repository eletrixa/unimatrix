#!/usr/bin/env bats
# RED-phase tests for spec 21 FR-9 (backlog 80) — cage preflight at claim time. A write card
# carrying a queue/<id>.files manifest must be checked BEFORE spawn: each manifest entry is resolved
# against the .write target cage, and any entry that escapes the cage (path-prefix test AFTER
# _abspath resolution) parks instantly with class=cage-denied and a reason line naming the offending
# path — no worker spawn, no lane retry burn. Cards without a .files manifest are unaffected.
#
# These assert behavior that is NOT YET IMPLEMENTED: _try_claim_one's .write block
# (swarm-run.sh:380-437) refuses empty/.claude/missing targets today but never reads queue/<id>.files,
# so an out-of-cage manifest spawns the worker normally. The new-behavior tests (out-of-cage,
# relative traversal) therefore fail today on their assertions (claude IS spawned, no cage-denied
# park) — never on harness mechanics: the file parses cleanly and setup() depends only on shipped
# behavior. The two in-cage / no-manifest cases are RED-wave CONTROLS (mirrors tests/swarm-run.bats's
# spec10 controls): they pass today and pin that a correct FR-9 does not over-reach into cards whose
# write list legitimately fits the cage.
#
# Project: unimatrix — multi-model swarm orchestrator driven from Claude Code
# Module:  tests/cage-preflight.bats
# Deps:    bats-core, src/swarm-lib.sh, swarm-run.sh, a PATH-shimmed fake claude under $BIN
# Tested:  n/a — this is the test file
#
# Design constraints:
# - Driver tests over a single claude:opus lane (write-capable, no env-master key, no child-env
#   swap). The fake claude sources $BIN/fake.conf via its own dirname (so it survives lane_cmd's
#   `env -i` containment wrap) and RECORDS every invocation to $BIN/calls.log — the no-spawn
#   assertion. PROBE_AUTO=0 keeps auto-probes from invoking the fake for an unrelated reason.
# - The .files manifest and .write sidecar are seeded DIRECTLY into queue/, not specs/: FR-9's only
#   claim-time .files consumer is the not-yet-built preflight, so relying on _enqueue_pending_specs
#   to move specs/<id>.files would couple the test to that move. Seeding queue/ directly exercises
#   the claim path's own read of queue/<id>.files regardless (same doctrine as the spec10 RED wave's
#   direct queue/<id>.chain seeds).

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
  # full_run calls mon_web_ensure/mon_web_open (ground control); disable so no test probes/spawns
  # against the REAL monitor port or the real default .bus.
  export MON_AUTOOPEN=0
  # _scratch_home reads $HOME/.claude — never let a test touch the real user's credentials; every
  # test gets its own throwaway "real" home. Unset CLAUDE_CONFIG_DIR so this box's ambient account
  # dir never leaks real creds into a throwaway scratch home.
  export HOME="$BATS_TEST_TMPDIR/realhome"
  mkdir -p "$HOME"
  unset CLAUDE_CONFIG_DIR
  # spec 13 FR-1 launch preflight aborts a run whose lane set touches gemini/glm/kimi without a
  # readable ENV_MASTER_FILE. claude:opus needs no key, but a working default keeps the preflight
  # quiet if a chain ever widens — mirror tests/swarm-run.bats's setup.
  printf 'Z_AI_CODING_KEY=default-glm-key\nMOONSHOT_API_KEY=default-kimi-key\nGEMINI_API_KEY=default-gem-key\n' \
    > "$BATS_TEST_TMPDIR/envmaster-default"
  export ENV_MASTER_FILE="$BATS_TEST_TMPDIR/envmaster-default"
  # finalize-side rows must never land in the repo's real docs/ops — redirect both ledgers to tmp.
  export LEDGER_FILE="$BATS_TEST_TMPDIR/llm-runs.md"
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/speedwars.jsonl"
  # auto live-probes default ON for operators — OFF here, or the pre-claim probe would invoke the
  # fake claude for unrelated reasons and pollute calls.log (these tests are not about probes).
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
  # belt-and-braces: nothing from this test's bus/bin should survive it
  pkill -9 -f "$BATS_TEST_TMPDIR" 2>/dev/null || true
  return 0
}

# _fake <NAME> <value> — appends NAME="value" to $BIN/fake.conf (bash-%q-escaped). A FILE, not an
# env var, on purpose: it must survive lane_cmd's `env -i` wrapping around the real invocation.
_fake() { printf '%s=%q\n' "$1" "$2" >> "$BIN/fake.conf"; }

# _install_fakes — a self-contained fake claude (the only lane these tests exercise), modeled on
# tests/swarm-run.bats's fake claude and stripped to just what FR-9 needs. It sources $BIN/fake.conf
# via its own dirname, RECORDS each invocation to $BIN/calls.log (the no-spawn assertion), writes a
# file relative to $PWD when FAKE_CLAUDE_WRITE_FILE is set (so the FR-R11 write-diff gate finalizes
# done on the in-cage control cards), and emits a claude-shaped result envelope extract_answer reads.
_install_fakes() {
  : > "$BIN/fake.conf"
  : > "$BIN/calls.log"
  cat > "$BIN/claude" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$_here/fake.conf" ]] && source "$_here/fake.conf"
# RECORD this invocation — the FR-9 no-spawn assertion greps this file. $_here is absolute (derived
# from BASH_SOURCE, not the inherited env), so the append survives lane_cmd's `env -i`/`env -C`
# containment wrap and lands in the same $BIN the test reads.
printf 'claude %s\n' "$*" >> "$_here/calls.log"
[[ -n "${FAKE_CLAUDE_DUMP_ENV:-}" ]] && env > "$FAKE_CLAUDE_DUMP_ENV"
# write-mode: create a file RELATIVE to $PWD (the env -C write cage) — proves the worker ran inside
# the cage and lets the FR-R11 diff gate finalize done on the in-cage control cards.
if [[ -n "${FAKE_CLAUDE_WRITE_FILE:-}" ]]; then
  printf '%s' "${FAKE_CLAUDE_WRITE_CONTENT:-written}" > "$FAKE_CLAUDE_WRITE_FILE"
fi
sleep "${FAKE_CLAUDE_DELAY:-0}"
echo '{"type":"init"}'
printf '{"type":"result","result":"%s"}\n' "${FAKE_CLAUDE_RESULT:-OK}"
exit "${FAKE_CLAUDE_EXIT:-0}"
FAKE
  chmod +x "$BIN/claude"
}

_enqueue() {
  local id="$1" text="$2"
  mkdir -p "$BUS/specs"
  printf '%s' "$text" > "$BUS/specs/$id.prompt"
}

_write_conf() {
  cat > "$CONF" <<EOF
EXEC_CHAIN="${1:-claude:opus}"
FANOUT=${2:-4}
LEASE_MIN=${3:-15}
EOF
}

# --- spec 21 FR-9: cage preflight at claim (backlog 80) -----------------------------------------
# RED wave: an out-of-cage .files entry must park at claim, BEFORE spawn. Today the claim path never
# reads queue/<id>.files, so the worker is spawned (calls.log non-empty) and no cage-denied park
# exists — the no-spawn + class assertions below fail first and loudest.

@test "FR-9: out-of-cage .files entry parks pre-spawn with class cage-denied, no worker invocation" {
  _write_conf "claude:opus"
  local cage="$BATS_TEST_TMPDIR/cage"
  mkdir -p "$cage"                      # the cage exists, so FR-5's missing-target wait never fires
  _enqueue cp1 "write card declaring an out-of-cage deliverable"
  mkdir -p "$BUS/queue"
  printf '%s' "$cage" > "$BUS/queue/cp1.write"
  printf '%s\n' "../outside/evil.txt" > "$BUS/queue/cp1.files"

  run timeout 25 "$RUNSH"

  # THE FR-9 promise — no worker spawn, no lane retry burn. Today claude IS spawned, so this fails
  # first and loudest.
  [ ! -s "$BIN/calls.log" ]
  # parked instantly at claim, through _park_card (a real _marker_line reason, not a bare touch)…
  [ -f "$BUS/limits/cp1.parked" ]
  grep -q 'ttl=' "$BUS/limits/cp1.parked"
  # …with the cage-denied class naming the offending path (substring matches both the manifest
  # entry "../outside/evil.txt" and its resolved form "<cage>/../outside/evil.txt").
  grep -q 'cage-denied' "$BUS/limits/cp1.parked"
  grep -q 'evil' "$BUS/limits/cp1.parked"
  # …and it never finalized.
  [ ! -e "$BUS/done/cp1" ]
}

@test "FR-9: in-cage .files manifest spawns normally and completes done (control — no over-reach)" {
  # Control: a manifest whose entries resolve INSIDE the cage must NOT trip FR-9. Today (no FR-9)
  # this spawns and completes done; the assertion pins that a correct FR-9 leaves in-cage cards
  # untouched — an over-reaching impl that parks any manifest card fails here.
  _write_conf "claude:opus"
  local cage="$BATS_TEST_TMPDIR/cage"
  mkdir -p "$cage"
  _fake FAKE_CLAUDE_RESULT "wrote the in-cage deliverable"
  # the worker writes the manifest-declared file (relative to the cage cwd) so the FR-R11 diff gate
  # finalizes done whether or not spec 14 FR-2's manifest-scoped gate is in play.
  _fake FAKE_CLAUDE_WRITE_FILE "inside.txt"
  _enqueue cp2 "write card with an in-cage deliverable manifest"
  mkdir -p "$BUS/queue"
  printf '%s' "$cage" > "$BUS/queue/cp2.write"
  printf '%s\n' "inside.txt" > "$BUS/queue/cp2.files"

  run timeout 25 "$RUNSH"

  [ -f "$BUS/done/cp2" ]
  # the worker WAS spawned — the positive control for the no-spawn assertion above
  [ -s "$BIN/calls.log" ]
  grep -q 'claude' "$BIN/calls.log"
}

@test "FR-9: a write card with no .files manifest is unaffected (control — manifest is the only source)" {
  # Control: FR-9's "the manifest is the only pre-spawn write-path source of truth" — a plain write
  # card with no .files sidecar behaves exactly as today (serves normally). Today this passes; the
  # assertion pins that FR-9 never parks a manifest-less card.
  _write_conf "claude:opus"
  local cage="$BATS_TEST_TMPDIR/cage"
  mkdir -p "$cage"
  _fake FAKE_CLAUDE_RESULT "wrote it"
  _fake FAKE_CLAUDE_WRITE_FILE "created.txt"
  _enqueue cp3 "plain write card, no files manifest"
  mkdir -p "$BUS/queue"
  printf '%s' "$cage" > "$BUS/queue/cp3.write"

  run timeout 25 "$RUNSH"

  [ -f "$BUS/done/cp3" ]
  [ -s "$BIN/calls.log" ]
  [ ! -e "$BUS/limits/cp3.parked" ]
}

@test "FR-9: relative traversal in .files (a/../../escape.txt) is caught — resolved outside the cage, parked, no spawn" {
  # The _abspath resolution is the point of this case. The raw join "<cage>/a/../../escape.txt"
  # starts with the cage prefix as a literal string, so a NAIVE prefix test (no resolution) would
  # WRONGLY allow it and spawn the worker. Proper resolution collapses it to "<tmpdir>/escape.txt"
  # (a sibling of the cage, outside it) → cage-denied park, no spawn. Today there is no preflight at
  # all, so claude is spawned and this fails on the no-spawn + class assertions.
  _write_conf "claude:opus"
  local cage="$BATS_TEST_TMPDIR/cage"
  mkdir -p "$cage"
  _enqueue cp4 "write card whose manifest traverses out of the cage"
  mkdir -p "$BUS/queue"
  printf '%s' "$cage" > "$BUS/queue/cp4.write"
  printf '%s\n' "a/../../escape.txt" > "$BUS/queue/cp4.files"

  run timeout 25 "$RUNSH"

  [ ! -s "$BIN/calls.log" ]
  [ -f "$BUS/limits/cp4.parked" ]
  grep -q 'ttl=' "$BUS/limits/cp4.parked"
  grep -q 'cage-denied' "$BUS/limits/cp4.parked"
  # names the offending path (matches both the entry "a/../../escape.txt" and its resolved form)
  grep -q 'escape' "$BUS/limits/cp4.parked"
  [ ! -e "$BUS/done/cp4" ]
}

@test "FR-9: a MIXED manifest (one escaping + one in-cage entry) is NOT parked — spec 14 FR-2 ignores the escaper at finalize" {
  # 2026-08-01 regression fix: park-on-first-escape turned spec 14 FR-2's ignore contract into a
  # denial. A manifest with at least one in-cage entry can still pass the finalize gate, so the
  # preflight must let it spawn; only the all-escaping (zero in-cage) manifest is doomed.
  _write_conf "claude:opus"
  local cage="$BATS_TEST_TMPDIR/cage"
  mkdir -p "$cage"
  _fake FAKE_CLAUDE_RESULT "wrote the one legitimate deliverable"
  _fake FAKE_CLAUDE_WRITE_FILE "inside.txt"
  _enqueue cp5 "write card with a mixed manifest"
  mkdir -p "$BUS/queue"
  printf '%s' "$cage" > "$BUS/queue/cp5.write"
  printf '%s\n' "../outside/evil.txt" "inside.txt" > "$BUS/queue/cp5.files"

  run timeout 25 "$RUNSH"

  [ -f "$BUS/done/cp5" ]
  [ -s "$BIN/calls.log" ]
  [ ! -e "$BUS/limits/cp5.parked" ]
}
