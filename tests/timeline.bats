#!/usr/bin/env bats
# RED-wave tests for spec 21 FR-11/FR-12: swarm-ctl `timeline` (read-only per-card wall-clock
# timeline reconstructed from existing bus artifacts) and run_summary's additive `top_wall` key.
# NEITHER exists in the tree yet — `timeline` is an unknown verb (falls through to usage, rc 1)
# and run_summary emits no top_wall key — so every assertion below fails on a TEST ASSERTION,
# not a harness error: the file parses cleanly under `bats --count`, and setup() touches only
# already-implemented primitives (bus_init + a hand-built synthetic bus). The GREEN wave lands
# cmd_timeline in src/swarm-ctl and the top_wall jq in run_summary (src/swarm-lib.sh) and flips
# every test here. Existing tests and source files are untouched.
#
# Project: unimatrix — multi-model swarm orchestrator driven from Claude Code
# Module:  tests/timeline.bats
# Deps:    bats-core, src/swarm-lib.sh, src/swarm-ctl, jq, coreutils (find/sha1sum/stat)
# Tested:  n/a — this is the test file
#
# Design constraints:
# - The synthetic bus is built BY HAND under $BATS_TEST_TMPDIR (done/ markers, one-line
#   run-<id>.jsonl logs, a hand-written speedwars JSONL ledger, a limits/<id>.parked FR-7
#   reason-line marker) — never a real .bus, never a .bus-* directory.
# - The ledger is pinned to a tmp $SPEEDWARS_FILE so no row ever reaches the repo's real
#   docs/ops/speedwars.jsonl; $SPEEDWARS_RUN pins the run-join key so _run_label is
#   deterministic (it wins over path derivation and never warns to stderr).
# - timeline is driven as a swarm-ctl verb (tests/swarm-ctl.bats idiom: BUSDIR=... run "$CTL").
# - top_wall is exercised IN-PROCESS (tests/swarm-lib.bats idiom: source the lib, call
#   run_summary directly) — no process spawn, no dependency on the unimplemented timeline verb.

CTL="$BATS_TEST_DIRNAME/../src/swarm-ctl"
LIB="$BATS_TEST_DIRNAME/../src/swarm-lib.sh"

setup() {
  # shellcheck source=/dev/null
  source "$LIB"
  BUS="$BATS_TEST_TMPDIR/bus"
  bus_init "$BUS"
  # _session_stamp (called by run_summary) reads CLAUDE_CONFIG_DIR/CLAUDE_ACCOUNT; unset so this
  # box's own ambient multi-account dir never leaks into a throwaway test (swarm-run.bats idiom).
  unset CLAUDE_CONFIG_DIR
  # Pin the speedwars ledger to a tmp file + a fixed run key: every test's synthetic ledger lives
  # here (no row reaches the repo's real docs/ops), and _run_label returns "tl-run" deterministically.
  export SPEEDWARS_FILE="$BATS_TEST_TMPDIR/speedwars.jsonl"
  export SPEEDWARS_RUN="tl-run"
}

# _build_tl_bus — hand-assemble the synthetic bus timeline reads from. Idempotent (truncates the
# ledger each call) so test order never leaks. The ledger carries the FR-11 coverage shapes:
#   cardA  — single attempt, claude lane, done, wall 120 (the highest wall → top_wall #1)
#   cardB  — single attempt, grok lane, done, wall 90
#   cardC  — RETRY: two rows (timeout then done), glm lane, walls 40/55 (neither digit is '2')
#   cardE  — LANE WALK: requested codex, served claude, fallback_reason "limit", wall 60
#   cardD  — PARKED: served_lane null, wall null; limits/cardD.parked carries the park reason token
# top_wall (FR-12) by per-id final wall_secs: cardA 120 > cardB 90 > cardE 60 > cardC 55; cardD null.
_build_tl_bus() {
  : > "$SPEEDWARS_FILE"
  cat >> "$SPEEDWARS_FILE" <<'EOF'
{"ts":"2026-07-31T10:00:00Z","run":"tl-run","id":"cardA","requested":"claude:opus","served_lane":"claude","served_model":"opus","outcome":"done","wrc":null,"pinned":false,"wall_secs":120,"billing":"pool"}
{"ts":"2026-07-31T10:00:10Z","run":"tl-run","id":"cardB","requested":"grok:grok-4.5","served_lane":"grok","served_model":"grok-4.5-build","outcome":"done","wrc":null,"pinned":false,"wall_secs":90,"billing":"pool"}
{"ts":"2026-07-31T10:00:20Z","run":"tl-run","id":"cardC","requested":"glm:glm-5.2","served_lane":"glm","served_model":"glm-5.2","outcome":"timeout","wrc":124,"pinned":false,"wall_secs":40,"billing":"pool"}
{"ts":"2026-07-31T10:00:50Z","run":"tl-run","id":"cardC","requested":"glm:glm-5.2","served_lane":"glm","served_model":"glm-5.2","outcome":"done","wrc":0,"pinned":false,"wall_secs":55,"billing":"pool"}
{"ts":"2026-07-31T10:01:00Z","run":"tl-run","id":"cardE","requested":"codex:default","served_lane":"claude","served_model":"opus","outcome":"done","wrc":null,"pinned":false,"wall_secs":60,"billing":"pool","fallback_reason":"limit"}
{"ts":"2026-07-31T10:01:10Z","run":"tl-run","id":"cardD","requested":"gemini:gemini-3-flash","served_lane":null,"served_model":null,"outcome":"parked","wrc":null,"pinned":false,"wall_secs":null,"billing":"pool"}
EOF
  # completed cards: a done/ marker (JSON, the shape swarm-run writes) + a one-line run log whose
  # birth time (%W) is the per-attempt spawn stamp timeline reconstructs.
  printf '{"id":"cardA","code":0,"lane":"claude"}\n' > "$BUS/done/cardA"
  printf '{"id":"cardB","code":0,"lane":"grok"}\n'  > "$BUS/done/cardB"
  printf '{"id":"cardC","code":0,"lane":"glm"}\n'    > "$BUS/done/cardC"
  printf '{"id":"cardE","code":0,"lane":"claude"}\n' > "$BUS/done/cardE"
  local id
  for id in cardA cardB cardC cardE; do
    printf '{"type":"result","result":"ok"}\n' > "$BUS/run-$id.jsonl"
  done
  # parked card: never spawned (no done/, no run-log); its prompt sits in queue/ and its FR-7
  # reason-line marker (limits/<id>.parked) carries the park token timeline must surface verbatim.
  printf 'parked task body\n' > "$BUS/queue/cardD.prompt"
  printf '2026-07-31T10:01:05Z | cage-denied | retryable=0 | ttl=0 | write path escapes cage for cardD\n' \
    > "$BUS/limits/cardD.parked"
}

# _snapshot_bus — content+name fingerprint of the whole bus tree (sha1sum prints "<hash>  <path>").
# Reading files never changes their bytes, so two snapshots of a read-only timeline pass are
# byte-identical; any add/remove/content-change (a write) shows up as a diff. This is the
# "checksum before/after" the spec's read-only acceptance criterion asks for.
_snapshot_bus() { find "$BUS" -type f -exec sha1sum {} + 2>/dev/null | sort; }

# --- FR-11: swarm-ctl timeline -----------------------------------------------------------

@test "timeline: renders per-card rows — each id, its lane, a duration, the retry's 2 attempts, the park reason" {
  _build_tl_bus
  BUSDIR="$BUS" run "$CTL" timeline "$BUS"
  [ "$status" -eq 0 ]

  # every card id surfaces (cardA/B/C are completed, cardE lane-walked, cardD parked)
  for id in cardA cardB cardC cardD cardE; do
    [[ "$output" == *"$id"* ]]
  done

  # cardA's own row carries its served lane + its serve duration (wall_secs 120)
  aline="$(grep -F 'cardA' <<<"$output" || true)"
  [[ "$aline" == *"claude"* ]]
  [[ "$aline" == *"120"* ]]

  # cardC retried (two ledger rows) — its entry shows 2 attempts. cardC's walls (40/55), lane
  # (glm) and id hold no '2', so a '2' on its line is unambiguously the attempt count.
  cline="$(grep -F 'cardC' <<<"$output" || true)"
  [[ "$cline" == *"2"* ]]

  # cardD's park reason token (from limits/cardD.parked) is rendered verbatim
  [[ "$output" == *"cage-denied"* ]]

  # cardE's lane walk surfaces its fallback_reason (codex -> claude, "limit")
  eline="$(grep -F 'cardE' <<<"$output" || true)"
  [[ "$eline" == *"limit"* ]]
}

@test "timeline: degrades gracefully — no claim stamps -> queue-wait '-', exit 0 (never an error)" {
  _build_tl_bus
  # FR-10 claim stamps (limits/<id>.claimed-at) don't exist on this bus (nor anywhere yet) — the
  # queue-wait field must degrade to a placeholder, not crash. Precondition: no stamps present.
  [[ -z "$(find "$BUS/limits" -maxdepth 1 -name '*.claimed-at' -print -quit)" ]]

  BUSDIR="$BUS" run "$CTL" timeline "$BUS"
  [ "$status" -eq 0 ]                # graceful: a stamp-less bus is not an error
  [[ "$output" == *"queue-wait"* ]]  # the field is still rendered...
  aline="$(grep -F 'cardA' <<<"$output" || true)"
  [[ "$aline" == *"-"* ]]            # ...and shows '-' where a stamp would go
}

@test "timeline: footer reports total span + an idle invocation gap between two activity clusters" {
  _build_tl_bus
  # Overwrite the dense ledger with TWO activity clusters >5 min apart: cluster 1 at 10:00:00–
  # 10:00:20, cluster 2 at 10:08:00 (a 460s / ~7.7min idle gap between them). Total span = 480s.
  : > "$SPEEDWARS_FILE"
  cat >> "$SPEEDWARS_FILE" <<'EOF'
{"ts":"2026-07-31T10:00:00Z","run":"tl-run","id":"cardA","requested":"claude:opus","served_lane":"claude","outcome":"done","wall_secs":120,"billing":"pool"}
{"ts":"2026-07-31T10:00:20Z","run":"tl-run","id":"cardB","requested":"grok:grok-4.5","served_lane":"grok","outcome":"done","wall_secs":90,"billing":"pool"}
{"ts":"2026-07-31T10:08:00Z","run":"tl-run","id":"cardE","requested":"codex:default","served_lane":"claude","outcome":"done","wall_secs":60,"billing":"pool"}
EOF

  BUSDIR="$BUS" run "$CTL" timeline "$BUS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"total span"* ]]                              # run footer: whole-run span line
  [[ "$output" == *"idle"* || "$output" == *"invocation"* ]]     # footer: idle gap / invocation boundary
}

@test "timeline: read-only — leaves the synthetic bus tree byte-identical" {
  _build_tl_bus
  before="$(_snapshot_bus)"

  BUSDIR="$BUS" run "$CTL" timeline "$BUS"
  [ "$status" -eq 0 ]

  after="$(_snapshot_bus)"
  [ "$before" = "$after" ]
}

# --- FR-12: run_summary additive top_wall key (exercised in-process, no timeline dependency) ---

@test "top_wall (FR-12): run_summary emits top-3 by wall_secs (highest first); postmortem surfaces it unchanged" {
  _build_tl_bus
  # run_summary IS implemented today but emits NO top_wall key — this is the additive-key RED
  # assertion. Called in-process (swarm-lib.bats idiom); it appends one run-summary row (the
  # LAST line of the ledger) carrying every existing field but not yet top_wall.
  run_summary "$BUS" full
  row="$(tail -n1 "$SPEEDWARS_FILE")"

  # FR-12: additive top_wall key, top 3 cards by wall_secs, highest first, at most 3 entries.
  [ "$(jq -r 'has("top_wall")' <<<"$row")" = "true" ]
  [ "$(jq -r '(.top_wall // []) | length' <<<"$row")" -le 3 ]
  [ "$(jq -r '.top_wall[0].id' <<<"$row")" = "cardA" ]          # highest wall_secs (120) first
  [ "$(jq -r '.top_wall[0].wall_secs' <<<"$row")" = "120" ]
  [ "$(jq -r '.top_wall[0].lane' <<<"$row")" = "claude" ]

  # "no reader change": cmd_postmortem already pretty-prints the newest run-summary row, so the
  # moment run_summary emits top_wall it appears in postmortem output with zero postmortem edits.
  BUSDIR="$BUS" run "$CTL" postmortem
  [ "$status" -eq 0 ]
  [[ "$output" == *"top_wall"* ]]
}
