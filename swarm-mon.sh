#!/usr/bin/env bash
# Read-only tmux cockpit for /swarm runs: BOARD/FIREHOSE/COST/CONTROL panes on an isolated
# tmux socket. Bootstraps idempotently; the monitor reads the bus and never writes to it outside
# the CONTROL pane (specs/02-cockpit.md).
#
# Project: unimatrix — multi-model swarm orchestrator driven from Claude Code
# Module:  swarm-mon.sh
# Deps:    src/swarm-lib.sh, swarm.conf, tmux 3.4, jq 1.7, coreutils, ccusage (optional), figlet
#          (optional), wezterm.exe (optional, Windows side)
# Tested:  tests/cockpit.bats (throwaway tmux socket + fixture bus, never -L swarm / real .bus)
#
# Key responsibilities:
# - Idempotent tmux session bootstrap (4 panes: BOARD, FIREHOSE, COST, CONTROL)
# - --render-board / --render-firehose / --render-cost(-once): the exact content each pane runs,
#   exposed as flags so both the live pane and bats can call the identical code path
# - Optional --wezterm read-only attach (a WSL-only convenience that shells out to a Windows-side
#   wezterm.exe under /mnt/c; non-fatal and simply skipped when that binary isn't present)
#
# Design constraints:
# - Never write to .bus outside of what the CONTROL pane's interactive shell does by hand
#   (swarm-ctl) — this script itself only reads
# - BUSDIR/CONF/SWARM_TMUX_SOCK are overridable via env so tests never touch the real
#   .bus/swarm.conf or the real `swarm` tmux socket
set -euo pipefail
# bash >= 5.1 gate — MUST precede `shopt -s inherit_errexit` (that option predates bash 4.4, so an
# ancient bash would die on the shopt line before this message).
if [ "${BASH_VERSINFO[0]}" -lt 5 ] || { [ "${BASH_VERSINFO[0]}" -eq 5 ] && [ "${BASH_VERSINFO[1]}" -lt 1 ]; }; then
  echo "unimatrix: bash >= 5.1 required (found $BASH_VERSION); on macOS: brew install bash" >&2
  exit 1
fi
shopt -s inherit_errexit

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=src/swarm-lib.sh
source "$SCRIPT_DIR/src/swarm-lib.sh"

SELF="$SCRIPT_DIR/swarm-mon.sh"
BUSDIR="${BUSDIR:-$SCRIPT_DIR/.bus}"
CONF="${CONF:-$SCRIPT_DIR/swarm.conf}"
SOCK="${SWARM_TMUX_SOCK:-swarm}"
FIREHOSE_WIDTH="${FIREHOSE_WIDTH:-180}"
export BUSDIR CONF

# --- BOARD: QUEUED/CLAIMED/DONE/CANCELLED, stale-lease alarm, active limits, parked branches ----

# ponytail: hand-rolled fallback banner (figlet isn't installed on this box) — upgrade path is
# automatic: the moment `figlet` is on PATH this renders the real block-letter wordmark instead.
_wordmark() {
  if command -v figlet >/dev/null 2>&1; then
    figlet -f standard UNIMATRIX 2>/dev/null | head -6
  else
    printf '%s\n' '=== U N I M A T R I X ===' '        swarm cockpit'
  fi
}

# _board <busdir> <lease_min> — single-shot render (reused verbatim by the live pane via
# `watch -n2 -t -- swarm-mon.sh --render-board`, and directly by bats — never re-derived).
_board() {
  local busdir="$1" lease_min="$2"
  printf '\033[36m%s\033[0m\n' "$(_wordmark)"

  local counts done_n queued_n claimed_n cancelled_n
  counts="$(gate_count "$busdir")"
  done_n="${counts%% *}"
  # only *.prompt is a unit of work — a pinned/write branch's <id>.lane/<id>.write sidecars share
  # queue/ but are not separate branches (matches gate_count's queue_n, src/swarm-lib.sh).
  queued_n="$(find "$busdir/queue" -maxdepth 1 -type f -name '*.prompt' 2>/dev/null | wc -l)"
  claimed_n="$(find "$busdir/claimed" -maxdepth 1 -type f 2>/dev/null | wc -l)"
  cancelled_n="$(find "$busdir/cancelled" -maxdepth 1 -type f 2>/dev/null | wc -l)"
  printf 'QUEUED %3s   CLAIMED %3s   DONE %3s   CANCELLED %3s\n' \
    "$queued_n" "$claimed_n" "$done_n" "$cancelled_n"

  local stale
  stale="$(find "$busdir/claimed" -maxdepth 1 -type f -mmin "+$lease_min" 2>/dev/null)" || true
  if [[ -n "$stale" ]]; then
    echo
    echo "STALE LEASES (>${lease_min}m, need reclaim):"
    echo "$stale"
  fi

  local f lane shown=0
  for f in "$busdir"/limits/*.limited; do
    [[ -e "$f" ]] || continue
    lane="$(basename "$f" .limited)"
    limit_active "$busdir" "$lane" || continue
    (( shown )) || { echo; echo "ACTIVE LIMITS:"; shown=1; }
    echo "  $lane"
  done

  shown=0
  for f in "$busdir"/limits/*.parked; do
    [[ -e "$f" ]] || continue
    (( shown )) || { echo; echo "PARKED BRANCHES:"; shown=1; }
    echo "  $(basename "$f" .parked)"
  done

  shown=0
  for f in "$busdir"/limits/*.dead; do
    [[ -e "$f" ]] || continue
    (( shown )) || { echo; echo "DEAD LANES:"; shown=1; }
    echo "  $(basename "$f" .dead)"
  done
  # Through lane_broken, not a bare glob: .broken is TTL'd (30m), so an expired marker is a lane
  # the router already considers healthy again — rendering it forever made the board contradict
  # routing.
  for f in "$busdir"/limits/*.broken; do
    [[ -e "$f" ]] || continue
    lane="$(basename "$f" .broken)"
    lane_broken "$busdir" "$lane" || continue
    (( shown )) || { echo; echo "DEAD LANES:"; shown=1; }
    echo "  $lane (broken)"
  done
}

# --- FIREHOSE: tail -F run-*.jsonl | jq (bus-discipline.md "Firehose" — jq -u mandatory) --------

_firehose() {
  local busdir="$1"
  local prog
  prog="$(jq_firehose_filter)"
  # nullglob so an empty bus yields an EMPTY list, not the literal 'run-*.jsonl' — feeding that to
  # `tail -F` (which is --follow=name --retry) wedges the pane retrying a filename with a real
  # asterisk in it that no worker ever creates, so the firehose stays blank for the whole run.
  shopt -s nullglob
  local files=("$busdir"/run-*.jsonl)
  # A cockpit opened just before the swarm has no run logs yet — poll briefly for the first one so
  # the pane isn't blank until manually restarted. NOTE (limitation, honest): `tail -F` follows the
  # files present when it starts, not new filenames created afterward — a worker whose run-<id>.jsonl
  # appears later than this glob is NOT auto-followed here. The WEB cockpit's /api/stream re-globs
  # every 500ms (specs/05-ground-control.md) and is the authoritative live-stream surface for that;
  # the tmux firehose is a glance overlay.
  local waited=0
  while (( ${#files[@]} == 0 )) && (( waited < 120 )); do
    sleep 0.25; waited=$(( waited + 1 )); files=("$busdir"/run-*.jsonl)
  done
  (( ${#files[@]} )) || return 0
  # stdbuf -oL: cut fully-buffers stdout when it isn't a tty, so a signal (timeout, tmux kill)
  # can drop already-processed lines before they're ever flushed — the "stdbuf -oL any extra
  # stage" rule (docs/02-build-pitfalls.md item 6) applies to this cut stage, not just jq.
  tail -n +1 -F "${files[@]}" 2>/dev/null \
    | jq -Rrc --unbuffered "$prog" \
    | stdbuf -oL cut -c1-"$FIREHOSE_WIDTH"
}

# --- COST: ccusage if present, else a best-effort per-lane token summary ------------------------

# _cost_summary <busdir> — ponytail: exact nested field names for gemini's stats.models / claude's
# result.usage are unverified against a live call (docs/02-build-pitfalls.md item 8) — sums
# whatever numeric fields it finds under each lane's known envelope shape rather than hardcoding
# unconfirmed paths. Upgrade to exact field paths once a real stream is captured and diffed.
_cost_summary() {
  local busdir="$1" f
  local -a files=()
  for f in "$busdir"/run-*.jsonl; do [[ -e "$f" ]] && files+=("$f"); done
  if [[ ${#files[@]} -eq 0 ]]; then
    echo "no run-*.jsonl yet"
    return 0
  fi

  jq -R -c 'fromjson? // empty' "${files[@]}" 2>/dev/null | jq -s -r '
    [ .[] |
      if .type == "turn.completed" and (.usage != null) then
        {lane: "codex", tokens: ([.usage[]?] | map(select(type == "number")) | add // 0)}
      elif .type == "result" and (.usage != null) then
        {lane: "claude/glm", tokens: ([.usage[]?] | map(select(type == "number")) | add // 0)}
      elif .type == "result" and (.stats.models != null) then
        (.stats.models | to_entries[]
          | {lane: ("gemini:" + .key), tokens: ([.value | .. | numbers] | add // 0)})
      else empty end
    ]
    | group_by(.lane)
    | map({lane: .[0].lane, tokens: (map(.tokens) | add)})
    | .[]
    | "\(.lane): \(.tokens) tokens"
  '
}

# --- dispatch --------------------------------------------------------------------------------

case "${1:-}" in
  --render-board)
    conf_load "$CONF"
    _board "$BUSDIR" "$LEASE_MIN"
    exit 0
    ;;
  --render-firehose)
    _firehose "$BUSDIR"
    exit 0
    ;;
  --render-cost-once)
    _cost_summary "$BUSDIR"
    exit 0
    ;;
  --render-cost)
    if command -v ccusage >/dev/null 2>&1; then
      exec watch -n10 ccusage
    fi
    exec watch -n10 -t -- "$SELF" --render-cost-once
    ;;
  --wezterm | "")
    ;;
  *)
    echo "usage: swarm-mon.sh [--wezterm]" >&2
    exit 1
    ;;
esac

conf_load "$CONF"
bus_init "$BUSDIR"

# idempotent: bail if the session already exists on this socket (FR-1)
if tmux -L "$SOCK" has-session -t mon 2>/dev/null; then
  exit 0
fi

control_cmd="PATH=\"$SCRIPT_DIR/src:\$PATH\" bash"

# BOARD (top-left) — the only pane so far.
tmux -L "$SOCK" new-session -d -s mon -n cockpit -x 200 -y 50 \
  "watch -n2 -t -- '$SELF' --render-board"
board_pane="$(tmux -L "$SOCK" list-panes -t mon:cockpit -F '#{pane_id}')"

# tmux renumbers pane_index by screen POSITION after every split (not creation order), so a
# hardcoded mon:cockpit.N target goes stale the moment a later split reflows the layout — capture
# each new pane's stable pane_id (-P -F) and target by that instead of by index.

# FIREHOSE (bottom, full width) — split off 65% of the window from BOARD.
firehose_pane="$(tmux -L "$SOCK" split-window -P -F '#{pane_id}' -v -t "$board_pane" -l 65% \
  "'$SELF' --render-firehose")"

# COST (top-right) — split off 40% of BOARD's row.
tmux -L "$SOCK" split-window -t "$board_pane" -h -l 40% \
  "'$SELF' --render-cost"

# CONTROL (bottom, full width) — carve a strip off the bottom of FIREHOSE.
tmux -L "$SOCK" split-window -t "$firehose_pane" -v -l 20% \
  "$control_cmd"

tmux -L "$SOCK" select-pane -t "$firehose_pane"

if [[ "${1:-}" == "--wezterm" ]]; then
  # SWARM_WEZTERM_BIN override: tests point this at a nonexistent path — on a box where the real
  # binary EXISTS, the hardcoded path made every suite run spawn a live WezTerm window attached
  # to a throwaway test socket that teardown then killed (2026-08-01, operator-visible litter).
  wez="${SWARM_WEZTERM_BIN:-/mnt/c/Program Files/WezTerm/wezterm.exe}"
  if [[ -x "$wez" ]]; then
    "$wez" cli spawn --new-window -- wsl.exe -- tmux -L "$SOCK" attach -r -t mon || true
  fi
fi
