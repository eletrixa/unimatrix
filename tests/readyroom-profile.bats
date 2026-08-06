#!/usr/bin/env bats
# Coverage for the readyroom profile (spec 23): conf_load judge-seat resolution (opus default vs
# READYROOM_JUDGE=codex), the GROK_TOOLS read-only tool-allowlist knob on lane_cmd's grok arm
# (read-only substitutes the value; the write branch is unaffected), and FR-1 env-over-conf
# precedence over the conf conditional. Five already-shipped features, one test each pinning a
# distinct contract — no real network, no real OAuth file, no real ledger (every fixture lives in
# $BATS_TEST_TMPDIR).
#
# Project: unimatrix — multi-model swarm orchestration driven from Claude Code
# Module:  tests/readyroom-profile.bats
# Deps:    bats-core, tests/helpers/swarm-lib-fixture.bash (setup/teardown + _claim_prompt, sources
#          src/swarm-lib.sh), profiles/readyroom.conf
# Tested:  n/a — this is the test file
#
# Key responsibilities:
# - profiles/readyroom.conf resolves through conf_load to the deep-research/decision lane set with
#   READYROOM_JUDGE unset → opus judge seats (REVIEW=claude:opus, the codex:claude verify pair,
#   web-capable read-only GROK_TOOLS, empty GROK_EFFORT restoring grok's own high-effort default,
#   the long-card TIMEOUT_GROK=1500 / WORKER_TIMEOUT_SEC=1200)
# - READYROOM_JUDGE=codex flips every judge seat at load (codex review + the codex:glm verify pair,
#   and the codex:claude pair is GONE — one env var moves the whole bench)
# - lane_cmd's grok arm substitutes GROK_TOOLS into the read-only --tools allowlist when set, and
#   stays byte-identical to the pre-knob default (read_file,grep,list_dir + --no-subagents) when
#   unset — the value is one argv element, immediately followed by --no-subagents, so a longer list
#   cannot falsely satisfy the substring
# - the grok WRITE branch carries no --tools at all (a write sidecar takes --allow Write/Edit/Create,
#   never the read-only allowlist) — the knob is read-only-only by construction
# - FR-1: an env-set REVIEW survives the conf conditional (env is re-laid over the sourced file, so
#   `export REVIEW=codex:default` beats the opus branch the conf itself just set)
#
# Design constraints:
# - fixture-only: the conf tests source profiles/readyroom.conf through the real conf_load (no swarm
#   run); the lane_cmd tests build a throwaway bus under $BATS_TEST_TMPDIR and assert on LANE_ARGV
#   without ever spawning a real grok binary — _scratch_home's OAuth copy is a no-op against the
#   throwaway $HOME, exactly as tests/swarm-lib-1.bats exercises the grok arm.
# - conf_load is sourced into the test shell by tests/helpers/swarm-lib-fixture.bash (the same loader
#   tests/swarm-lib-{1,2}.bats use), so each conf test just sets CONF=$PROFILE and calls conf_load —
#   the same CONF="$PROFILE"; conf_load "$CONF" shape tests/thrifty-profile.bats uses for its profile.
# - every conf test unsets the keys it asserts on first: REVIEW/CLASS_REVIEW/VERIFY_MAP/GROK_EFFORT/
#   GROK_TOOLS/TIMEOUT_GROK/WORKER_TIMEOUT_SEC ARE CONF_KEYS, so conf_load captures an ambient export
#   BEFORE sourcing and re-lays it AFTER (the FR-1 dance) — without the unset, a stray env value
#   would silently beat the very conf value under test (backwards). READYROOM_JUDGE is NOT a CONF_KEY
#   (read at source time only), so it just needs to be unset/exported directly. The lane_cmd tests
#   unset GROK_TOOLS (pre-knob default) or export it (the knob under test) the same way. LANG=C.UTF-8
#   is baked into lane_cmd's envbase literally (src/swarm-lib.sh:1082), so the argv pins need no
#   ambient-LANG coupling.

load 'helpers/swarm-lib-fixture'

REPO="$BATS_TEST_DIRNAME/.."
LIB="$REPO/src/swarm-lib.sh"
PROFILE="$REPO/profiles/readyroom.conf"

@test "readyroom conf: default branch resolves opus judge seats" {
  unset READYROOM_JUDGE REVIEW CLASS_REVIEW VERIFY_MAP GROK_EFFORT GROK_TOOLS TIMEOUT_GROK WORKER_TIMEOUT_SEC
  CONF="$PROFILE"
  conf_load "$CONF"
  [ "$REVIEW" = "claude:opus" ]
  [ "$CLASS_REVIEW" = "claude codex" ]
  [[ "$VERIFY_MAP" == *"codex:claude"* ]]
  [ "$GROK_TOOLS" = "read_file,grep,list_dir,web_search,web_fetch" ]
  [ "$GROK_EFFORT" = "" ]
  [ "$TIMEOUT_GROK" = "1500" ]
  [ "$WORKER_TIMEOUT_SEC" = "1200" ]
}

@test "readyroom conf: READYROOM_JUDGE=codex flips the judge seats" {
  unset READYROOM_JUDGE REVIEW CLASS_REVIEW VERIFY_MAP
  export READYROOM_JUDGE=codex
  CONF="$PROFILE"
  conf_load "$CONF"
  [ "$REVIEW" = "codex:default" ]
  [ "$CLASS_REVIEW" = "codex glm" ]
  [[ "$VERIFY_MAP" == *"codex:glm"* ]]
  [[ "$VERIFY_MAP" != *"codex:claude"* ]]
}

@test "lane_cmd: grok read-only argv is byte-identical with GROK_TOOLS unset" {
  # no conf_load (so GROK_TOOLS is whatever we leave it as) — unset it and the grok arm falls back to
  # its own read-only default allowlist, exactly the pre-knob shape.
  unset GROK_TOOLS
  bus_init "$BUS"
  _claim_prompt "grok:grok-4.5" rr1 "hello grok"
  lane_cmd "grok:grok-4.5" rr1 "$BUS"
  # Element-exact assertion (not a flattened-substring match): find the --tools element and pin the
  # NEXT element to exactly the pre-knob default, and the one after to --no-subagents — proves the
  # allowlist is ONE argv element with correct boundaries, byte-identical to the pre-knob argv.
  local -i ti=-1 i
  for i in "${!LANE_ARGV[@]}"; do [[ "${LANE_ARGV[$i]}" == "--tools" ]] && ti=$i && break; done
  (( ti >= 0 ))
  [ "${LANE_ARGV[$((ti+1))]}" = "read_file,grep,list_dir" ]
  [ "${LANE_ARGV[$((ti+2))]}" = "--no-subagents" ]
  # The cage's literal LANG pin (src/swarm-lib.sh envbase) is present as its own element.
  local lang_seen=0; for i in "${!LANE_ARGV[@]}"; do [[ "${LANE_ARGV[$i]}" == "LANG=C.UTF-8" ]] && lang_seen=1; done
  (( lang_seen == 1 ))
}

@test "lane_cmd: grok read-only argv substitutes GROK_TOOLS when set" {
  export GROK_TOOLS=read_file,grep,list_dir,web_search,web_fetch
  bus_init "$BUS"

  # (a) read-only spawn: GROK_TOOLS is substituted verbatim as the single element after --tools
  # (element-exact, so no flattening ambiguity and no trailing content can hide in the value).
  _claim_prompt "grok:grok-4.5" rr2 "research card"
  lane_cmd "grok:grok-4.5" rr2 "$BUS"
  local -i ti=-1 i
  for i in "${!LANE_ARGV[@]}"; do [[ "${LANE_ARGV[$i]}" == "--tools" ]] && ti=$i && break; done
  (( ti >= 0 ))
  [ "${LANE_ARGV[$((ti+1))]}" = "read_file,grep,list_dir,web_search,web_fetch" ]
  [ "${LANE_ARGV[$((ti+2))]}" = "--no-subagents" ]

  # (b) write-target sidecar takes the write branch (--allow Write/Edit/Create), which passes NO
  # --tools at all — the knob is read-only-only, so a write card is unaffected by GROK_TOOLS.
  _claim_prompt "grok:grok-4.5" rrw2 "write card"
  printf '%s' "$BATS_TEST_TMPDIR/write-tgt-rrw2" > "$BUS/queue/rrw2.write"
  lane_cmd "grok:grok-4.5" rrw2 "$BUS"
  [[ "${LANE_ARGV[*]}" != *"--tools"* ]]
}

@test "readyroom conf: env wins over the conf conditional" {
  # FR-1 precedence: conf_load captures the env REVIEW before sourcing readyroom.conf (whose default
  # branch would set REVIEW=claude:opus) and re-lays codex:default back over it afterward.
  unset READYROOM_JUDGE REVIEW
  export REVIEW=codex:default
  CONF="$PROFILE"
  conf_load "$CONF"
  [ "$REVIEW" = "codex:default" ]
}
