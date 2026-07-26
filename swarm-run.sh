#!/usr/bin/env bash
# /swarm driver: --plan-only prints the resolved plan; config reads/edits swarm.conf; the default
# mode runs the FANOUT-bounded pool (EXEC_CHAIN, or a per-branch pinned lane) over whatever is
# sitting in the bus.
#
# Project: unimatrix — multi-model swarm orchestrator driven from Claude Code
# Module:  swarm-run.sh
# Deps:    src/swarm-lib.sh, swarm.conf
# Tested:  tests/swarm-run.bats (PATH-shimmed fake CLIs — no real API calls)
#
# Key responsibilities:
# - Enqueue (specs/ -> queue/, moving optional <id>.lane (FR-2b), <id>.write (FR-15), and <id>.chain
#   (spec10 FR-R2, orchestrator-pinned fallback chain seed) sidecars alongside), run the
#   claim/spawn/finalize pool, gate on done+parked >= live (FR-7), exit 0 unless something parked
# - Own process group for the pool so `swarm-ctl abort` can kill the whole tree at once (FR-9)
# - FR-12 per-worker wall-clock watchdog (WORKER_TIMEOUT_SEC) + FR-13 driver-death sweep (a TERM
#   sent to this script's own pid, not the pool's pgid, still terminates every in-flight worker)
# - spec10 FR-R6: a pinned lane that's limited/dead bounded-waits up to PIN_WAIT_SEC before parking
#   loudly, rather than either silently spinning forever or parking on the lane's own (much
#   longer) limit TTL; FR-R9 records first-writer-wins fallback provenance
#   (limits/.fbreason-<id>) whenever the chain-walk skips a blocked lane, for speed_row to surface
# - spec10 FR-R11: write-card diff gate + cross-lane false-done classifier (answer_unusable) reject
#   a served "done" that never touched its write target or looks like an auth/API-error envelope
#   masquerading as an answer — folded into the existing extract_answer-failure retry/failover path
# - spec10 FR-R10: a completed kimi branch accumulates real Moonshot PAYG $ into limits/kimi.spend
# - backlog-29: _try_claim_one refuses (parks, never spawns) any card whose .write target has a
#   .claude/ path component — orchestrator-owned surface, no worker writes there
# - On successful finalize: archive the prompt to prompt-<id>.txt and the write card to
#   write-<id>.txt (provenance; limits/<id>.stamp deliberately survives finalize), stamp the done
#   marker with the SERVED lane — plus degraded:true while a non-fable orch-seat is acting
#   (spec 11 FR-S4) — and (LEDGER_AUTO=1, default) auto-append a run-evidence ledger row
# - `verify` subcommand — Phase E step 4 cross-model verify wave: write_verify_spec (per completed
#   branch) + the SAME pool/gate mechanics (_enqueue_pending_specs/_drive_pool, shared with the
#   generate wave via full_run)
# - spec 13 FR-1: full_run/verify_run abort loudly (env_master_preflight, before any fan-out) when
#   this run's lane set needs an env-key lane and $ENV_MASTER_FILE is unreachable
# - spec 13 FR-2: `doctor --live` — plain doctor plus one minimal authenticated probe per lane
#   (curl for glm/kimi/gemini, the real CLI under a 10s cap for claude/grok, 30s for codex), each probe
#   logged (no-silent-spend) and a FAIL writing limits/<lane>.broken when a busdir exists
# - spec 17 FR-5: `doctor --plugin` — manifest/marketplace/UNIMATRIX_HOME checks, a plugin-cache
#   drift table (the actual ~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/ copy Claude
#   Code serves, hashed against the repo — the marketplace-source row alone self-compares whenever
#   a directory marketplace points at this checkout), a per-account install-drift table (installed
#   hash vs repo hash vs verdict), and a skill-version-stamp check; zero spend, always exits 0,
#   same never-fatal contract as plain doctor
# - spec 13 FR-3: _finalize_worker flags limits/<lane>.broken (class lane-down) when a lane RAN but
#   served no model at all across its bounded retry budget (the grok brain058 fast-fail shape);
#   cleared on that lane's next successful finalize, same as .dead
# - spec 13 FR-4: _try_claim_one's chain-walk gates a fallback hop onto kimi (real-$) while
#   BUDGET_USD=0 via PAYG_FALLBACK (warn: loud + evidenced, default; deny: routed around like any
#   blocked lane; allow: today's behavior)
# - spec 14 FR-1: a worker the permission cage read-denied (cage_denials > CAGE_DENY_MAX) PARKS —
#   checked first in _finalize_worker's success branch, never chain-advanced (every rung shares the
#   cage), evidenced as limits/<id>.cage-denied (count + denied paths, never answer text)
# - spec 14 FR-2: optional queue/<id>.files deliverable manifest scopes the write-diff gate to THIS
#   card's files (absent = today's whole-target sweep); sidecar lifecycle mirrors .write exactly,
#   archived to files-<id>.txt on success
# - spec 14 FR-5/FR-7: claim-time bounded wait on a missing .write target (parks
#   write-target-missing, never mkdir); every limits/ marker written through _park_card carries a
#   one-line reason (token + retryable + ttl)
# - spec 14 FR-6: the retries-exhausted broken_flag downgrades to a short-TTL .limited while a
#   sibling worker on that lane is provably live — a card fault must never cool a working lane
# - P0-FR4: full_run/verify_run print one "unimatrix: root=... branch=... head=... busdir=..."
#   banner line (_print_banner) — the same four fields GET /health returns (site/server.mjs),
#   so a run and the cockpit can never disagree about which checkout/branch/bus it's against
# - P2-FR1: _close_out_evidence additionally fires lane_summary (three-line per-lane close-out
#   summary off the canonical fold) and bus_archive (raw-evidence freeze into
#   docs/ops/bus-archives/<run>/) — both guarded, neither may ever fail a run
#
# Design constraints:
# - A spec with a queue/<id>.lane sidecar (FR-2b) is pinned to that one lane:model — no
#   EXEC_CHAIN fallback; a limit-worthy failure parks it loudly instead of switching lanes.
#   Absent sidecar -> EXEC_CHAIN exactly as before. lane_cmd itself stays lane-agnostic either way.
# - BUSDIR/CONF/HEARTBEAT_SEC are overridable via env so tests never touch the real .bus/swarm.conf
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

# realpath -m: a relative BUSDIR override resolves against the CALLER's cwd here, once, up front —
# without this, FR-15's `env -C <write-target>` chdir means every downstream relative use of
# $BUSDIR (e.g. codex's `--output-last-message "$busdir/res-<id>.txt"`) re-resolves against the
# WORKTREE instead, silently misplacing the handoff. -m tolerates a not-yet-existing path (bus_init
# creates it).
# realpath -m is GNU-only; BSD/macOS realpath has no -m. Feature-detect and hand-normalize otherwise.
# _abspath <path> — absolutize (and, on GNU, lexically normalize) a possibly not-yet-existing path
# against the CALLER's cwd. Shared by the BUSDIR resolution below, spec 15's `call` busdir default
# and its --write target check, so the three can never drift on the BSD fallback.
_abspath() {
  if realpath -m / >/dev/null 2>&1; then
    realpath -m "$1"
  else
    case "$1" in /*) printf '%s\n' "$1";; *) printf '%s\n' "$PWD/$1";; esac
  fi
}
# spec 15 FR-1: remember whether BUSDIR came from the ENVIRONMENT before the default below erases
# the distinction — `call` overrides only the default (its bus belongs at the caller's cwd, not
# inside the unimatrix checkout), never an explicit operator/test override.
_BUSDIR_FROM_ENV="${BUSDIR:+1}"
BUSDIR="$(_abspath "${BUSDIR:-$SCRIPT_DIR/.bus}")"
CONF="${CONF:-$SCRIPT_DIR/swarm.conf}"
HEARTBEAT_SEC="${HEARTBEAT_SEC:-30}"

usage() {
  cat >&2 <<'EOF'
usage: swarm-run.sh --plan-only "<question>"
       swarm-run.sh config [KEY value]
       swarm-run.sh doctor [--live|--plugin]
       swarm-run.sh verify
       swarm-run.sh call <lane[:model]> '<prompt>'|@<promptfile> [--write <dir>]
              [--files <listfile> --batch <N>] [--chain '<lane[:model]> ...'] [--id <label>]
       swarm-run.sh ["<question — ignored, this mode reads .bus/specs>"]
EOF
  exit 1
}

# _print_config_table — specs/04 FR-2's fully-resolved-config contract: EVERY conf_load key, no
# hand-maintained subset (five keys had already drifted out of it). CONF_KEYS (src/swarm-lib.sh) is
# the one list both this and conf_load read, so a new key can't be silently missing here again.
# CLASS_REVIEW/CLASS_EXEC are skipped in the plain loop — _print_class_row renders them with live
# per-member availability instead.
_print_config_table() {
  local k
  for k in "${CONF_KEYS[@]}"; do
    case "$k" in CLASS_REVIEW | CLASS_EXEC) continue ;; esac
    printf '%-24s %s\n' "$k" "${!k}"
  done
  _print_class_row CLASS_REVIEW "$CLASS_REVIEW"
  _print_class_row CLASS_EXEC "$CLASS_EXEC"
}

# _print_class_row <label> <members> — spec10 FR-R13: one line per role class, each member
# annotated with its live availability. Display precedence is dead > limited > broken > available
# (the stronger, non-self-healing fact wins the label; lane_blocked's own check ORDER differs but
# any of them resolves to blocked all the same). "limited <N>m"/"broken <N>m" is the ceiling of the
# minutes left on the flag's mtime+TTL window, never the raw TTL — a stale-looking "300m" that's
# actually seconds from expiring would be a misleading config snapshot otherwise.
# The `broken` arm (spec 13 FR-3) is not cosmetic: without it an actively-.broken lane that
# lane_blocked refuses printed as "available" — the config table contradicting the router.
_print_class_row() {
  local label="$1" members="$2" member state line
  line="$label:"
  for member in $members; do
    if lane_dead "$BUSDIR" "$member"; then
      state="dead"
    elif limit_active "$BUSDIR" "$member"; then
      state="limited $(_flag_mins_left "$BUSDIR/limits/$member.limited" 18000)m"
    elif lane_broken "$BUSDIR" "$member"; then
      state="broken $(_flag_mins_left "$BUSDIR/limits/$member.broken" 1800)m"
    else
      state="available"
    fi
    line="$line $member($state)"
  done
  echo "$line"
}

# _flag_mins_left <flagfile> <default-ttl> — whole minutes (ceiling) left on a TTL'd limits/ flag.
# ttl via _marker_ttl (src/swarm-lib.sh, spec14 FR-7): a bare `<"$f"` read dies on a reason-line
# marker ("resets ..." isn't all-digits) — _marker_ttl handles legacy bare-digits, the new
# `ttl=<sec>` field, and the default, in that order.
_flag_mins_left() {
  local f="$1" ttl mtime now remaining
  ttl="$(_marker_ttl "$f" "$2")"
  mtime="$(_stat_mtime "$f")"
  now="$(date +%s)"
  remaining=$(( ttl - (now - mtime) ))
  (( remaining > 0 )) || remaining=0
  echo $(( (remaining + 59) / 60 ))
}

# _print_banner — P0-FR4: one line, every run (full_run/verify_run, and transitively `call`,
# which ends in full_run). Byte-shape-matched to GET /health's JSON (site/server.mjs) — same four
# fields, same values — so a human staring at this terminal and the cockpit's /health probe can
# never disagree about which checkout/branch/head/bus a run is against (pre-mortem #8/#4: plugin
# skew and wrong-worktree failures are silent and misattributed as "the model did something
# dumb"). root is resolved from SCRIPT_DIR via git, exactly like /health resolves it from its own
# file's dirname — never a hardcoded path, so a worktree promotion can't silently invalidate it.
# Falls back to "unknown"/SCRIPT_DIR rather than aborting the run if git is unavailable/detached.
_print_banner() {
  local root branch head
  root="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || echo "$SCRIPT_DIR")"
  branch="$(git -C "$root" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
  head="$(git -C "$root" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  echo "unimatrix: root=$root branch=$branch head=$head busdir=$BUSDIR" >&2
  # spec 17 FR-5: one warning line at run start when the shipped plugin version has drifted from
  # the repo's newest release — never fatal, the banner must print for every run regardless.
  _plugin_version_banner_line || true
}

plan_only() {
  local question="$1"
  conf_load "$CONF"
  bus_init "$BUSDIR"
  # Deliberately does NOT write run.pgid: plan_only starts no pool, and `$$` is this script's PID,
  # not a process-group id — a later `swarm-ctl abort` would `kill -- -$$` against a dead PID (pid
  # reuse could then signal an unrelated group). run.pgid is written only by _drive_pool, which is
  # the only path that actually has a group to abort.

  echo "=== resolved config ==="
  _print_config_table

  echo "=== planned lane map ==="
  echo "plan:         $PLAN (in-session)"
  echo "orchestrator: $ORCHESTRATOR (in-session)"
  echo "review:       $REVIEW"
  echo "exec chain:   $EXEC_CHAIN"
  echo
  echo "question: $question"
}

# config [] | config <KEY> <value> — spec-04 FR-2: resolved table one command away, or edit in place.
cmd_config() {
  conf_load "$CONF"
  if [[ $# -eq 0 ]]; then
    _print_config_table
    return 0
  fi
  [[ $# -ge 2 ]] || usage  # `config KEY` with no value would deref an unset $2 under set -u
  local key="$1" val="$2"
  # A `"` in the value corrupts the conf's own bash quoting (`KEY="...""..."`) — no amount of sed
  # escaping fixes that, and a swarm.conf value is meant to be a single shell token anyway. Refuse
  # loudly rather than write an unsourceable file (conf_load `source`s this).
  if [[ "$val" == *'"'* ]]; then
    echo "swarm-run: config value for '$key' must not contain a double-quote (conf is bash-sourced)" >&2
    return 1
  fi
  if [[ -f "$CONF" ]] && grep -q "^${key}=" "$CONF"; then
    # Escape sed replacement metacharacters in $val: `&` (whole-match backref), `|` (our delimiter),
    # and `\` (escape lead-in). Without this, `config EXEC_CHAIN 'a|b'` crashes sed and `a&b`
    # silently injects the matched line — either way corrupting swarm.conf.
    local esc="${val//\\/\\\\}"; esc="${esc//&/\\&}"; esc="${esc//|/\\|}"
    # Portable in-place edit (BSD sed's `-i` needs a mandatory backup-suffix arg; GNU's doesn't) —
    # sidestep the incompatibility entirely by writing to a temp file and mv'ing it over.
    sed "s|^${key}=.*|${key}=\"${esc}\"|" "$CONF" > "$CONF.tmp.$$" && mv "$CONF.tmp.$$" "$CONF"
  else
    printf '%s="%s"\n' "$key" "$val" >> "$CONF"
  fi
}

# _orig_chain_bare <busdir> <id> — spec10 FR-R9: the SEED chain's first head (queue/<id>.chain else
# EXEC_CHAIN) — never chain_current, which after a failed attempt has already advanced past the seed
# head and would mis-report `requested` in speed_row's fallback provenance.
_orig_chain_bare() {
  local busdir="$1" id="$2" seed_head=""
  # `|| true` is load-bearing (final-reviewer CRITICAL): .chain files are written with
  # `printf '%s'` — no trailing newline — and `read -r` returns rc1 at newline-less EOF while
  # still populating the variable. Bare under set -e in _finalize_worker's unguarded call, that
  # rc1 crashed the whole pool driver on the first MID-FLIGHT limit/dead of a chain-seeded card.
  if [[ -f "$busdir/queue/$id.chain" ]]; then
    read -r seed_head _ < "$busdir/queue/$id.chain" || true
  else
    read -r seed_head _ <<<"$EXEC_CHAIN" || true
  fi
  printf '%s' "${seed_head%%:*}"
}

# --- the pool: claim -> spawn -> finalize, EXEC_CHAIN fallback ---------------------------------

# _reason_retryable <reason-token> — spec 14 FR-7: whether a TTL expiry or `swarm-ctl nudge` can
# plausibly make this card work again with nothing outside the bus changing. Fixed per the token
# (spec text, not a bash heuristic): retryable=1 for rate-limit, session-limit, timeout-watchdog,
# chain-exhausted, pinned-lane-blocked, api-error, server-error, no-answer, false-done; everything
# else (auth-death, spawn-fail, cage-denied, write-target-missing, parked-env, lane-down, and any
# token outside this list) is retryable=0.
_reason_retryable() {
  case "$1" in
    rate-limit | session-limit | timeout-watchdog | chain-exhausted | pinned-lane-blocked \
      | api-error | server-error | no-answer | false-done) echo 1 ;;
    *) echo 0 ;;
  esac
}

# _park_card <id> <requested-lane> <pinned> [class] [reason-token] — THE park transition. Every
# park in this file goes through it, because a park is terminal for the gate and must therefore
# also be the branch's LAST speedwars row: several pinned paths used to write only the .parked
# marker (or leave a `timeout`/`retry` row as the final one), so run_summary's parked_n and the bus
# disagreed about the branch's fate. run_summary keeps the last row per id, so this row is what a
# branch's outcome reads as. `class` defaults to spec 12 FR-1's parked-env (an environment/route
# gate, never a lane-fallover signature). spec 14 FR-7's reason-token defaults to `class` itself —
# a call site with nothing sharper to say needs no edit at all, and speed_row's `class` output
# stays byte-identical; only the marker's CONTENT gains the sharper token.
_park_card() {
  local id="$1" lane="$2" pinned="${3:-0}" class="${4:-parked-env}"
  local reason="${5:-$class}"
  local retryable; retryable="$(_reason_retryable "$reason")"
  _marker_line "$reason" "$retryable" 0 "lane=$lane pinned=$pinned" > "$BUSDIR/limits/$id.parked"
  [[ "${SPEEDWARS_AUTO:-1}" == "1" ]] \
    && speed_row "$BUSDIR" "$id" "$lane" "parked" "" "$pinned" "$class" 2>/dev/null || true
}

# Scans queue/ for the first claimable spec: skips ids already parked (chain exhausted, or a
# pinned lane that failed) and lanes currently limit_active (FR-7 — new specs skip a known-bad
# lane, no wasted attempts). A spec with a queue/<id>.lane sidecar (FR-2b) is PINNED to that one
# lane:model, bypassing EXEC_CHAIN entirely — no fallback, so a pinned lane that's limit_active
# just waits (not parked; the flag is temporary) rather than being marked exhausted.
# Sets CLAIMED_ID/CLAIMED_LANE on success. rc 0 = claimed, 1 = nothing claimable now, 2 = PAUSEd.
_try_claim_one() {
  CLAIMED_ID=""; CLAIMED_LANE=""
  [[ -e "$BUSDIR/PAUSE" ]] && return 2
  local f id lane bare_lane
  for f in "$BUSDIR"/queue/*.prompt; do
    [[ -e "$f" ]] || continue
    id="$(basename "$f" .prompt)"
    [[ -e "$BUSDIR/limits/$id.parked" ]] && continue

    # spec10 round-3 amendment: a .write card targeting anything under a .claude/ path component
    # is refused BEFORE any spawn — that surface is orchestrator-owned, and letting a worker touch
    # it (even a "successful" one) would be indistinguishable from the orchestrator's own state.
    # Checked ahead of pinned/chain resolution: the refusal is a property of the write target
    # itself, independent of which lane would have served it.
    if [[ -e "$BUSDIR/queue/$id.write" ]]; then
      local wtarget wcanon; wtarget="$(<"$BUSDIR/queue/$id.write")"
      # backlog-29 symlink hardening: match BOTH spellings — raw catches not-yet-existing paths,
      # realpath resolves symlinks/.. (a link to .claude/ must not slip past the literal regex).
      wcanon="$(realpath -m -- "$wtarget" 2>/dev/null || printf '%s' "$wtarget")"
      if [[ "$wtarget" =~ (^|/)\.claude(/|$) || "$wcanon" =~ (^|/)\.claude(/|$) ]]; then
        echo "swarm-run: $id refused — write target '$wtarget' is an orchestrator-owned .claude/ surface; parking" >&2
        local orig_bare; orig_bare="$(_orig_chain_bare "$BUSDIR" "$id")"
        # spec 12 FR-1: parked-env — never a lane fallover/rejection signature, purely an
        # environment gate (the write target itself is refused, whatever lane would have served it).
        _park_card "$id" "$orig_bare" 0
        continue
      fi
      # spec 14 FR-5: a .write target that doesn't exist yet spawns a worker that cannot possibly
      # succeed (`env -C <missing>` exits 125 before the CLI emits a byte) and blames the wrong
      # thing for it — the zero-byte run log this produces used to read as lane-down evidence (see
      # the companion `-s`/wrc 126|127 fix at the retries-exhausted classification below). Bounded
      # wait, same idiom as the FR-R6 pinned-lane-blocked wait a few lines down: re-check every
      # poll, one stderr notice at marker creation, park only once PIN_WAIT_SEC elapses — an
      # instant park would permanently kill the legitimate wave-1-creates-the-directory /
      # wave-2-writes-into-it card dependency that limps through today. NEVER mkdir — a typo'd
      # target manifesting as a real (empty) directory would let the FR-R11 diff gate silently
      # "pass" against whatever lands in it.
      if [[ ! -d "$wcanon" ]]; then
        # CRITICAL fix (cross-review round 2026-07-25): this used to share limits/<id>.waiting with
        # the FR-R6 pinned-lane-blocked wait below. A pinned write card on a blocked lane, with an
        # EXISTING target, hit this block's own `rm -f` on every poll (target exists -> clear) right
        # before the pinned-wait block below re-touched the SAME filename fresh — the pinned timer
        # was reset to zero every single poll and never reached PIN_WAIT_SEC, so the card never
        # parked (pool hang, repro'd by two reviewers). Own marker name, `.waiting-write`, so the
        # two bounded waits can never collide.
        local wtfile="$BUSDIR/limits/$id.waiting-write" wtmtime now
        if [[ ! -e "$wtfile" ]]; then
          touch "$wtfile"
          echo "swarm-run: $id .write target '$wtarget' does not exist yet — waiting up to ${PIN_WAIT_SEC}s before parking" >&2
        else
          wtmtime="$(_stat_mtime "$wtfile")"
          now="$(date +%s)"
          if (( now - wtmtime >= PIN_WAIT_SEC )); then
            rm -f "$wtfile"
            echo "swarm-run: $id .write target '$wtarget' still missing after ${PIN_WAIT_SEC}s — parking" >&2
            local orig_bare; orig_bare="$(_orig_chain_bare "$BUSDIR" "$id")"
            _park_card "$id" "$orig_bare" 0 write-target-missing
          fi
        fi
        continue
      fi
      rm -f "$BUSDIR/limits/$id.waiting-write"
    fi

    if [[ -f "$BUSDIR/queue/$id.lane" ]]; then
      lane="$(<"$BUSDIR/queue/$id.lane")"
      bare_lane="${lane%%:*}"
      if lane_blocked "$BUSDIR" "$bare_lane"; then
        # spec10 FR-R6: a pinned lane that's limited/dead bounded-waits up to PIN_WAIT_SEC (not
        # the lane's own limit_active TTL, which can be hours) before parking loudly — one stderr
        # notice at marker creation, then silent re-polls until the wait expires.
        local wfile="$BUSDIR/limits/$id.waiting" wmtime now wreason
        if limit_active "$BUSDIR" "$bare_lane"; then wreason="limited"
        elif lane_dead "$BUSDIR" "$bare_lane"; then wreason="dead"
        elif lane_broken "$BUSDIR" "$bare_lane"; then wreason="lane-down"
        else wreason="budget-gated"; fi
        if [[ ! -e "$wfile" ]]; then
          touch "$wfile"
          echo "swarm-run: $id pinned to $lane which is $wreason — waiting up to ${PIN_WAIT_SEC}s before parking" >&2
        else
          wmtime="$(_stat_mtime "$wfile")"
          now="$(date +%s)"
          if (( now - wmtime >= PIN_WAIT_SEC )); then
            rm -f "$wfile"
            echo "swarm-run: $id pinned lane '$lane' still blocked after ${PIN_WAIT_SEC}s — parking" >&2
            # _park_card, not a bare touch: a pinned park used to leave NO terminal row at all, so
            # run_summary counted the branch as neither done nor parked. spec 14 FR-7: reason token
            # pinned-lane-blocked (class stays parked-env — speed_row's class output is unchanged).
            _park_card "$id" "$lane" 1 parked-env pinned-lane-blocked
          fi
        fi
        continue
      fi
      rm -f "$BUSDIR/limits/$id.waiting"
    else
      lane="$(chain_current "$BUSDIR" "$id")"
      # spec10 FR-R9: first-writer-wins provenance for speed_row's fallback_reason/requested
      # fields — original_bare is the SEED chain's first head (queue/<id>.chain else EXEC_CHAIN),
      # NOT chain_current: after a failed attempt already advanced the walk (and speed_row consumed
      # the first .fbreason), chain_current is an intermediate hop and would mis-report `requested`.
      local orig_bare fbfile="$BUSDIR/limits/.fbreason-$id" reason
      orig_bare="$(_orig_chain_bare "$BUSDIR" "$id")"
      while [[ -n "$lane" ]]; do
        bare_lane="${lane%%:*}"
        if lane_blocked "$BUSDIR" "$bare_lane"; then
          if limit_active "$BUSDIR" "$bare_lane"; then
            reason="limit"
          elif lane_dead "$BUSDIR" "$bare_lane"; then
            reason="dead"
          elif lane_broken "$BUSDIR" "$bare_lane"; then
            # spec 13 FR-3 route-around. Without its own arm this fell into "budget-gated" and a
            # lane-HEALTH event was recorded (fbreason + the successor's speedwars row) as a SPEND
            # event — the one place the failure vocabulary lied about why a hop happened.
            reason="lane-down"
          else
            reason="budget-gated"
          fi
          [[ -e "$fbfile" ]] || printf '%s %s' "$reason" "$orig_bare" > "$fbfile"
          echo "swarm-run: $id lane '$bare_lane' blocked ($reason) — advancing chain" >&2
          chain_advance "$BUSDIR" "$id"
          lane="$(chain_current "$BUSDIR" "$id")"
          continue
        fi
        # spec 13 FR-4 (backlog 39): PAYG_FALLBACK=deny treats a fallback hop onto kimi (real-$,
        # never pooled) under BUDGET_USD=0 (uncapped) exactly like any other blocked lane — route
        # around it instead of silently spending unbounded real dollars.
        if _payg_denied "$bare_lane" "$orig_bare"; then
          [[ -e "$fbfile" ]] || printf '%s %s' "payg-denied" "$orig_bare" > "$fbfile"
          echo "swarm-run: $id fallback hop to kimi refused — PAYG_FALLBACK=deny and BUDGET_USD=0 (uncapped); routing around it" >&2
          chain_advance "$BUSDIR" "$id"
          lane="$(chain_current "$BUSDIR" "$id")"
          continue
        fi
        break
      done

      if [[ -z "$lane" ]]; then
        # spec10 FR-R7: exhaustion is the TERMINAL fact — it overrides any first-writer hop reason
        # so the parked row is auditable via fallback_reason=="class-exhausted" (r3glm review: the
        # vocabulary value had no producer). A parked card never finalizes, so emit its speedwars
        # row here — the only place that knows the park happened.
        # Write provenance only when its sole consumer (speed_row) will run — otherwise the
        # unconsumed marker lingers in limits/ for the run's lifetime (final-reviewer LOW).
        [[ "${SPEEDWARS_AUTO:-1}" == "1" ]] && printf '%s %s' "class-exhausted" "$orig_bare" > "$fbfile" || true
        echo "swarm-run: chain exhausted — parked $id" >&2
        # spec 12 FR-1: parked-env — same class as the pinned-wait park above (a blocked-pin wait
        # path); spec 14 FR-7's reason token is chain-exhausted (the marker's sharper token; the
        # fbfile's "class-exhausted" fallback_reason already distinguishes it for humans, unchanged).
        _park_card "$id" "$orig_bare" 0 parked-env chain-exhausted
        # spec 14 FR-3: reset this id's chain position on the spot — otherwise a parked id leaves
        # an EMPTY limits/.chain-<id> behind, and a later re-publish of the same id (swarm-ctl add)
        # resolves against an already-exhausted walk and parks again on the very first poll.
        chain_reset "$BUSDIR" "$id"
        continue
      fi

      # spec 13 FR-4 (backlog 39): PAYG_FALLBACK=warn (default) — the chain settled on kimi via an
      # actual fallback hop (bare_lane != orig_bare) while BUDGET_USD=0 (uncapped). Never silent:
      # one loud stderr line plus fbreason provenance (a no-op if the walk above already wrote one
      # first — first-writer-wins, same doctrine as every other fbreason write in this function).
      # deny already routed around kimi inside the walk (bare_lane can't be kimi here in that mode);
      # allow is a deliberate no-op — today's behavior, byte-identical.
      if [[ "$bare_lane" == kimi && "$bare_lane" != "$orig_bare" ]] \
         && awk -v b="${BUDGET_USD:-0}" 'BEGIN { exit !(b + 0 <= 0) }' \
         && [[ "${PAYG_FALLBACK:-warn}" == warn ]]; then
        echo "PAYG fallback: $id hopping to kimi with no budget cap set" >&2
        [[ -e "$fbfile" ]] || printf '%s %s' "limit" "$orig_bare" > "$fbfile"
      fi
    fi

    local crc=0
    claim "$BUSDIR" "$id" "$lane" || crc=$?
    if (( crc == 0 )); then
      CLAIMED_ID="$id"; CLAIMED_LANE="$lane"
      return 0
    elif (( crc == 2 )); then
      return 2
    fi
    # crc 1: lost the race — keep scanning the rest of queue/
  done
  return 1
}

# Builds the lane invocation, runs it with a background heartbeat AND a wall-clock watchdog
# (FR-12), returns the worker's exit code. Registers this process's own pid under
# .bus/pids/<id> so swarm-ctl kill (and the watchdog itself) can target this worker's whole
# subtree via kill_subtree — heartbeat keeps the LEASE fresh but must never mask a genuine hang
# (docs/02-build-pitfalls.md live E2E finding: a stuck gemini retry loop kept heartbeating forever).
# _rotate_run_log <busdir> <id> — spec 12 Amendment 2026-07-25 FR-D (backlog 49): every retry
# attempt for an id spawns into the SAME run-<id>.jsonl, and `tee` truncates it — the prior
# attempt's stream, the only evidence of why it failed, is destroyed by the attempt that replaces
# it. Rotate a NON-EMPTY existing log to run-<id>.jsonl.<n> (lowest unused n, starting at 1)
# immediately ahead of this attempt's tee. An empty log is not rotated — a zero-byte log is not
# evidence (spec 14 FR-5) and rotating it would only litter the bus.
# The suffix shape is load-bearing: EVERY consumer is extension-anchored on the unsuffixed name
# (site/server.mjs's `/^run-.*\.jsonl$/`, swarm-mon.sh's `run-*.jsonl` globs, run_summary's
# `run-*.jsonl.stderr` stderr_n glob) — `.jsonl.<n>` matches none of them, exactly like the
# existing `.jsonl.stderr` precedent. No reader changes are needed, and none should be made.
# `run-<id>.jsonl.stderr` is deliberately NOT rotated here — it's opened with `>>` below and has
# always accumulated across attempts; that's correct for a diagnostic sidecar, not an oversight.
_rotate_run_log() {
  local busdir="$1" id="$2"
  local log="$busdir/run-$id.jsonl" n=1
  [[ -s "$log" ]] || return 0
  while [[ -e "$log.$n" ]]; do n=$(( n + 1 )); done
  mv "$log" "$log.$n"
}

_spawn_worker() {
  local id="$1" lane="$2" bare="${2%%:*}"
  lane_cmd "$lane" "$id" "$BUSDIR" || return 9

  # spec04 FR-C: per-lane TIMEOUT_<LANE> overrides WORKER_TIMEOUT_SEC (six keys, one per lane;
  # empty/unset is pure fallback). Resolved ONCE, here — the single enforcement site for the
  # watchdog sleep below; spec01 Amendment FR-A's reap age cap must consume this SAME resolved
  # value, or a per-lane timeout the cap doesn't know about would reap a live long-running worker.
  local _to_var="TIMEOUT_${bare^^}"
  local worker_timeout="${!_to_var:-$WORKER_TIMEOUT_SEC}"

  local mypid=$BASHPID

  # `</dev/null >/dev/null 2>&1` is load-bearing, not decoration: without it this subshell (and
  # every `sleep` it forks each loop iteration) inherits the CALLER's stdout/stderr — which, under
  # bats, is itself a pipe `run`/command-substitution reads until EOF. If this subshell ever
  # outlives its parent (orphaned — the only way that can happen is the watchdog racing normal
  # completion, or an external kill), it keeps that pipe's write end open FOREVER, and anything
  # waiting for EOF on it (bats' `run`, `$(...)`) hangs indefinitely even though the actual work
  # already finished — reproduced live (2026-07-08). Same failure class as the FD-3 rule, one fd
  # over. `kill_subtree` (not plain `kill`) on cleanup so a subshell's own momentary `sleep` child
  # never survives it as an orphan either.
  ( while :; do heartbeat "$BUSDIR" "$id" "$lane"; sleep "$HEARTBEAT_SEC"; done ) </dev/null >/dev/null 2>&1 3>&- &
  local hbpid=$!

  mkdir -p "$BUSDIR/pids"
  echo "$mypid" > "$BUSDIR/pids/$id"

  # The watchdog is a descendant of THIS process — it kills THIS process's own subtree (itself
  # included, via kill_subtree's snapshot-then-kill, self-safe by construction) rather than
  # trying to track the CLI/tee pids individually. A narrow TOCTOU race exists between normal
  # completion and the watchdog firing at the exact same instant; harmless in practice given the
  # gap is microseconds against a multi-second-to-minutes WORKER_TIMEOUT_SEC.
  # The marker carries THIS attempt's claim token (FR-14 dev:inode), not just the id: the path is
  # shared across every retry of the same id, so a marker left by an earlier attempt could
  # otherwise make a newer, healthy claim finalize as timed out.
  local ctoken; ctoken="$(_stat_devino "$BUSDIR/claimed/$id.$lane" 2>/dev/null || true)"
  ( sleep "$worker_timeout"
    kill -0 "$mypid" 2>/dev/null || exit 0
    printf '%s' "$ctoken" > "$BUSDIR/limits/$id.timedout"
    kill_subtree "$mypid" KILL
  ) </dev/null >/dev/null 2>&1 3>&- &
  local wdpid=$!

  # spec10 FR-R11: pre-spawn baseline for the write-card diff gate (_finalize_worker) — must be
  # touched AFTER the watchdog/heartbeat are up but BEFORE the CLI itself can touch anything under
  # the write target, or a genuinely fast write would race the stamp and false-reject. Backdated 1s
  # so a write landing in the stamp's own mtime granule (coarse-mtime fs) can never read as
  # not-newer-than it. When the target is a git repo, its pre-spawn HEAD sha is recorded as the
  # exact diff baseline (_write_card_diff_section reads limits/<id>.base) — best-effort: a
  # non-repo/unborn-HEAD target leaves no .base file and the consumer falls back to commit dates.
  if [[ -e "$BUSDIR/queue/$id.write" ]]; then
    touch -d '1 second ago' "$BUSDIR/limits/$id.stamp"
    local wtarget; wtarget="$(<"$BUSDIR/queue/$id.write")"
    git -C "$wtarget" rev-parse HEAD > "$BUSDIR/limits/$id.base" 2>/dev/null \
      || rm -f "$BUSDIR/limits/$id.base"
  fi

  _rotate_run_log "$BUSDIR" "$id"
  set +e
  "${LANE_ARGV[@]}" 2>>"$BUSDIR/run-$id.jsonl.stderr" | tee "$BUSDIR/run-$id.jsonl" >/dev/null
  local rc=$?
  set -e

  # `|| true` on every wait here is load-bearing, not decoration: `wait PID` returns the WAITED
  # PROCESS's own exit code, and a subshell we just TERM'd exits 143 — under `set -e` (restored
  # above) that nonzero return trips errexit and aborts THIS function immediately, skipping every
  # line after it. Reproduced live: the second wait (hbpid) was never reached, orphaning the
  # heartbeat loop — same failure class as pitfalls #16 (`wait -n -p`), just on a plain `wait PID`.
  kill_subtree "$wdpid" TERM
  wait "$wdpid" 2>/dev/null || true
  kill_subtree "$hbpid" TERM
  wait "$hbpid" 2>/dev/null || true
  rm -f "$BUSDIR/pids/$id"

  [[ "$lane" == grok* ]] && _grok_token_sync "${LANE_HOME:-}"
  return "$rc"
}

# _grok_token_sync <cage-home> — grok rotates its OAuth token inside the caged HOME, and the
# refresh is SINGLE-USE: the master copy under ~/.grok goes stale the moment any cage refreshes
# (live finding 2026-07-19 — a sibling bus's refresh bricked every later spawn with "Not signed
# in"). Sync the cage token back so the next spawn anywhere starts from the live one. Shared by the
# worker spawn path and doctor --live's grok probe (which cages identically and so owes the same
# write-back). Never fails its caller.
# ponytail: last-writer-wins across concurrent buses; a real token-store lock only if this bites.
_grok_token_sync() {
  local cage="${1:-}"
  [[ -n "$cage" && -f "$cage/.grok/auth.json" ]] || return 0
  [[ "$cage/.grok/auth.json" -nt "$HOME/.grok/auth.json" ]] || return 0
  cmp -s "$cage/.grok/auth.json" "$HOME/.grok/auth.json" 2>/dev/null && return 0
  install -m 600 "$cage/.grok/auth.json" "$HOME/.grok/auth.json" 2>/dev/null || true
  return 0
}

# _write_target_changed <id> — spec10 FR-R11 diff gate, shared by the success path and the
# timeout-salvage path so the two can never drift: rc 0 iff anything under this write card's target
# is newer than the pre-spawn baseline. find's -newer is strictly-newer on mtime, so compare
# against the stamp's mtime minus 1s — a write landing in the stamp's own timestamp granule
# (coarse-mtime fs) is never silently missed. A missing stamp rejects, exactly as the old
# `find -newer <missing>` (empty output) did.
# spec 14 FR-2: with a queue/<id>.files manifest the sweep is scoped to THAT card's deliverables
# instead of the whole cage, so a concurrently-running sibling card's edit can no longer satisfy
# this card's gate. Absent manifest = the whole-target sweep, byte-identical — and that stays the
# default, so the cage-granular ceiling below still describes every card without one.
# ponytail: KNOWN CEILING (unmanifested cards only) — cage-granular, not card-granular. Two write
# cards sharing one .write target satisfy each other's gate (a no-op card can be salvaged on a
# sibling's bytes). Upgrade path: give those cards a manifest.
_write_target_changed() {
  local id="$1" wtarget stamp_epoch
  wtarget="$(<"$BUSDIR/queue/$id.write")"
  stamp_epoch="$(_stat_mtime "$BUSDIR/limits/$id.stamp" 2>/dev/null || true)"
  [[ -n "$stamp_epoch" ]] || return 1
  # spec 10 Amendment 2026-07-25 (backlog 53): predicates adopted verbatim from the verify-side
  # twin (_write_card_diff_section, src/swarm-lib.sh). Without `-type f` the target DIRECTORY's own
  # mtime bump (anything created/removed inside it, including by a concurrent sibling card)
  # satisfies this gate with zero artifacts produced; without the .git/busdir exclusions, a `git
  # status` refreshing `.git/index` does the same. `-print -quit` stays — the gate only needs
  # existence, never the list.
  local -a roots=("$wtarget")
  if [[ -f "$BUSDIR/queue/$id.files" ]]; then
    _manifest_roots "$id" "$wtarget" || return 1
    roots=("${MANIFEST_ROOTS[@]}")
  fi
  # A listed path the worker never created simply doesn't exist; find's complaint goes to the
  # already-suppressed stderr and it contributes no match — exactly right, an undelivered
  # deliverable is not a change.
  [[ -n "$(find "${roots[@]}" -type f -newermt "@$((stamp_epoch - 1))" \
            -not -path '*/.git/*' -not -path "$BUSDIR/*" -not -path '*/.bus*/*' \
            -print -quit 2>/dev/null)" ]]
}

# _manifest_roots <id> <wtarget> — spec 14 FR-2's consume-time half of the trust boundary. Resolves
# each queue/<id>.files entry against the write target and sets MANIFEST_ROOTS to the survivors;
# rc 1 (nothing usable) when the manifest is empty or every entry was refused, which the gate reads
# as "this card proved nothing" — never as "scan the whole cage", which would silently restore the
# very blind spot the manifest exists to close.
# An entry that is absolute, or that escapes the target once resolved with `realpath -m`, is IGNORED
# with a loud line rather than honored: swarm-ctl add refuses those at publish time, and a manifest
# that reached the bus anyway (hand-written sidecar, older publisher) is a scoping aid, never a way
# to widen the cage. Set as a global rather than echoed because a path list round-tripped through
# command substitution loses entries containing whitespace.
_manifest_roots() {
  local id="$1" wtarget="$2" tcanon rel abs
  MANIFEST_ROOTS=()
  tcanon="$(realpath -m -- "$wtarget" 2>/dev/null || printf '%s' "$wtarget")"
  while IFS= read -r rel || [[ -n "$rel" ]]; do
    [[ -n "$rel" ]] || continue
    abs="$(realpath -m -- "$tcanon/$rel" 2>/dev/null || true)"
    if [[ "$rel" == /* || -z "$abs" || "$abs" != "$tcanon"/* ]]; then
      echo "swarm-run: $id — ignoring manifest entry '$rel': absolute or escapes write target '$wtarget'" >&2
      continue
    fi
    # cross-review MAJOR: find() treats every root as a traversal start, not a leaf — an entry that
    # resolves to an EXISTING DIRECTORY would let `find "$abs" -type f -newermt ...` recurse into it
    # and match ANY file changed inside, including ones the manifest never named (the verify-side
    # twin only ever accepts files — this closes the asymmetry).
    if [[ -d "$abs" ]]; then
      echo "swarm-run: $id — ignoring manifest entry '$rel': manifest entries must be files, not directories" >&2
      continue
    fi
    MANIFEST_ROOTS+=("$abs")
  done < "$BUSDIR/queue/$id.files"
  (( ${#MANIFEST_ROOTS[@]} > 0 ))
}

# _archive_and_release <id> <lane> <bare> — the shared "this card finished" bus transition, used by
# BOTH the success path and the timeout-salvage path so the two can never drift. A half-cleaned bus
# is the failure mode to fear (a surviving claim file or .chain sidecar re-enters the pool behind an
# already-written done marker), so this is one function, not two copies of the same rm.
# Order is load-bearing: archive the verify wave's provenance BEFORE dropping the files it reads —
# the claim file is the only surviving copy of the prompt text, queue/<id>.write the only copy of
# the target path. limits/<id>.stamp is deliberately NOT dropped (spec10 round-3 amendment): it is
# the verify wave's diff baseline. Clearing this lane's .dead/.broken flags belongs here too — a
# card that genuinely finished (answered, or wrote real bytes) is live proof the lane is neither
# auth-dead nor down, and a stale flag would keep the pool routing around a working lane.
# Every step's status is checked explicitly (rc 1 on failure) rather than left to `set -e`: the
# salvage caller invokes this from an `if ... && ...` condition, where errexit is DISABLED for the
# whole call tree — a failed write-provenance copy or a half-done cleanup would otherwise be
# swallowed and the card still reported as finalized.
_archive_and_release() {
  local id="$1" lane="$2" bare="$3"
  cp -f "$BUSDIR/claimed/$id.$lane" "$BUSDIR/prompt-$id.txt" 2>/dev/null || true
  if [[ -e "$BUSDIR/queue/$id.write" ]]; then
    cp -f "$BUSDIR/queue/$id.write" "$BUSDIR/write-$id.txt" || return 1
  fi
  # spec 14 FR-2: the verify wave scopes its diff to this card's manifest, and reads it AFTER
  # queue/ is cleared — so it gets archived beside write-<id>.txt, same guarded-cp idiom.
  if [[ -e "$BUSDIR/queue/$id.files" ]]; then
    cp -f "$BUSDIR/queue/$id.files" "$BUSDIR/files-$id.txt" || return 1
  fi
  rm -f "$BUSDIR/claimed/$id.$lane" "$BUSDIR/queue/$id.lane" "$BUSDIR/queue/$id.write" \
        "$BUSDIR/queue/$id.chain" "$BUSDIR/queue/$id.files" "$BUSDIR/limits/$id.waiting" \
        "$BUSDIR/limits/$id.waiting-write" "$BUSDIR/limits/$id.cage-denied" \
        "$BUSDIR/limits/$bare.dead" "$BUSDIR/limits/$bare.broken" || return 1
  return 0
}

# _salvage_timeout <id> <lane> <bare> <wrc> <pinned> — spec 01 FR-12 amendment (2026-07-25,
# backlog 17+10). A watchdog SIGKILL says the process ran out of wall clock, NOT that its work is
# worthless: p53-build-drift was killed at 922s having finished 14/0 tests, r1-rows at 613s with 8
# tests + 38 asserts already on disk — both logged `timeout` and were re-done or adopted by hand.
# Before failing the attempt over, look at what's actually on disk (the tee already flushed it):
#   1. best-effort extract_answer over the PARTIAL run log; if it yields an answer that
#      answer_unusable rejects (auth-death dump, error envelope served as text), discard it and
#      take today's failover — a truncated stream must never launder a bad answer into a done.
#   2. write card -> the SAME diff gate as the success path decides (real bytes under the target).
#      read card -> a usable extracted answer decides.
# rc 0 = finalized as done with outcome `timeout-salvaged` (the bus transition is literally the
# success path's — _archive_and_release); rc 1 = nothing worth keeping, caller proceeds with today's
# timeout failover unchanged. The lane is still never `.limited` here (FR-12's round-3 amendment: a
# kill-truncated stream is not limit evidence) — salvage adds no lane-level penalty in either
# direction, it only rescues the card.
# ponytail: no TERM-grace window, no partial-stream repair. Ceiling: this only rescues work the CLI
# had already flushed; the upgrade path if that proves too narrow is TERM-then-KILL in the watchdog
# (spec 01 FR-12 amendment names it, deliberately unbuilt).
_salvage_timeout() {
  local id="$1" lane="$2" bare="$3" wrc="$4" pinned="$5"
  local answer_ok=0
  if extract_answer "$bare" "$id" "$BUSDIR" 2>/dev/null; then
    if answer_unusable "$bare" "$BUSDIR" "$id" >/dev/null; then
      rm -f "$BUSDIR/res-$id.txt"
      return 1
    fi
    answer_ok=1
  fi
  # EVERY unsuccessful salvage path drops res-<id>.txt. Leaving it behind was a real laundering
  # hole: `extract_answer codex` trusts any non-empty pre-existing res file, so a later codex
  # attempt on the same id would inherit the KILLED lane's rejected text as its own answer (and
  # full_run's `=== results ===` would list the branch as if it had produced one).
  if [[ -e "$BUSDIR/queue/$id.write" ]]; then
    _write_target_changed "$id" || { rm -f "$BUSDIR/res-$id.txt"; return 1; }
  else
    (( answer_ok )) || { rm -f "$BUSDIR/res-$id.txt"; return 1; }
  fi

  echo "swarm-run: $id exceeded WORKER_TIMEOUT_SEC on lane '$lane' — killed, but its work is on disk; salvaging as done" >&2
  # This function is called from an `if ... && _salvage_timeout` CONDITION, which disables errexit
  # for its whole body — a failed archive/marker write would otherwise be swallowed and the card
  # reported as salvaged anyway. The three mutations that make a card "done" are therefore checked
  # by hand, and a failure returns the distinct rc 2 the caller reports loudly.
  _archive_and_release "$id" "$lane" "$bare" || return 2
  local deg=""
  if orch_degraded "$BUSDIR"; then deg=',"degraded":true'; fi
  # `salvaged:true` (round-4 MIN): spec 12 FR-2 lets a PLAIN success carry a nonzero code too, so
  # `code != 0` no longer distinguishes a salvage from a completion. Consumers that read done/
  # markers rather than the ledger (write_verify_spec) need the flag to treat the card as
  # higher-suspicion — the diff gate accepts any byte newer than the stamp, so a kill landing after
  # edit 1 of 5 looks identical to a finished card.
  printf '{"id":"%s","code":%s,"lane":"%s","salvaged":true%s}\n' "$id" "$wrc" "$bare" "$deg" \
    > "$BUSDIR/done/$id" || return 2
  chain_reset "$BUSDIR" "$id" || return 2
  # A killed kimi worker still burned real PAYG dollars on the tokens it did produce — undercounting
  # spend is the worse error, so accumulate exactly as the success path does.
  [[ "$bare" == kimi ]] && _kimi_spend_add "$BUSDIR" "$id"
  [[ "${LEDGER_AUTO:-1}" == "1" ]] && ledger_row "$BUSDIR" "$id" 2>/dev/null || true
  # spec 12 FR-1: no `class` — the vocabulary types NON-done outcomes, and this branch has a done
  # marker. Absence-means-absent, same as a plain `done` row; `timeout-salvaged` in `outcome` is
  # what distinguishes it (and keeps it out of feedback_stubs' exact `outcome=="timeout"` match —
  # a salvaged card is evidence, not an incident to file).
  [[ "${SPEEDWARS_AUTO:-1}" == "1" ]] && speed_row "$BUSDIR" "$id" "$lane" "timeout-salvaged" "$wrc" "$pinned" 2>/dev/null || true
  return 0
}

# _check_cage_denied <id> <lane> <bare> <pinned> — spec 14 FR-1's cage-denied gate, extracted so
# BOTH the success-path finalize check and the timeout branch (cross-review MINOR: a watchdog-
# killed cage-denied card used to chain-advance through every rung instead of parking, since only
# the success path ran this check) share one implementation. rc 0 = the card was parked here and
# the caller must `return 0` immediately; rc 1 = not tripped, caller proceeds with its own
# classification. Meaningless on a worker killed before it ever emitted a `type:"result"` event —
# cage_denials reads 0 and this is a harmless no-op, exactly as intended.
_check_cage_denied() {
  local id="$1" lane="$2" bare="$3" pinned="$4"
  local denied_n; denied_n="$(cage_denials "$BUSDIR" "$id")"
  (( denied_n > ${CAGE_DENY_MAX:-0} )) || return 1
  # Deduped in first-seen order (awk, not jq's sorting `unique`) — the order the worker hit the
  # cage is the order an operator retraces it in. Paths and counts ONLY reach the marker: spec
  # 12's scrub-by-construction doctrine, and the observed cage-denied answers are ~2300 chars of
  # articulate prose that feedback_stubs would otherwise quote into a tracked file.
  local -a dpaths=()
  mapfile -t dpaths < <(jq -R -c 'fromjson? // empty' "$BUSDIR/run-$id.jsonl" 2>/dev/null \
    | jq -r -s "$(_cage_denials_jq_filter) | .[] | (.tool_input // {}) | (.file_path // .path // .pattern // empty)" \
        2>/dev/null | awk '!seen[$0]++' || true)
  printf 'denials=%s\n' "$denied_n" > "$BUSDIR/limits/$id.cage-denied"
  (( ${#dpaths[@]} )) && printf '%s\n' "${dpaths[@]}" >> "$BUSDIR/limits/$id.cage-denied"
  local shown="${dpaths[*]:0:5}"
  (( ${#dpaths[@]} > 5 )) && shown="$shown (+$(( ${#dpaths[@]} - 5 )) more)"
  echo "swarm-run: $id — the permission cage denied $denied_n read-class tool call(s) on lane '$lane'; parking (an environment fault, so every chain rung would repeat it)" >&2
  echo "swarm-run: $id denied: $shown" >&2
  # Same laundering hole every other rejection gate closes: `extract_answer codex` trusts any
  # non-empty pre-existing res file, so a later nudge onto codex would inherit this cage's
  # explanation as its own answer.
  rm -f "$BUSDIR/res-$id.txt"
  # no-silent-spend (model-lanes.md): the worker ran and billed before the cage stopped it.
  [[ "${LEDGER_AUTO:-1}" == "1" ]] && ledger_failed_row "$BUSDIR" "$id" "$bare" "cage-denied" 2>/dev/null || true
  _park_card "$id" "$lane" "$pinned" cage-denied
  if [[ -e "$BUSDIR/claimed/$id.$lane" ]]; then
    echo "swarm-run: mover=finalize-tail requeued $id (lane '$lane') to queue/ — cage-denied park" >&2
    mv "$BUSDIR/claimed/$id.$lane" "$BUSDIR/queue/$id.prompt"
  fi
  return 0
}

# On success: done marker (one write) + drop the claim + reset chain state.
# On failure: limit_error decides fail-over (advance chain) vs retry-same-lane; either way the
# spec goes back to queue/ under its own id (FR-6 — a normal error never triggers a lane switch).
# A PINNED spec (queue/<id>.lane, FR-2b) has no chain to advance — a fail-over-worthy signal parks
# it loudly instead of silently switching lanes. wrc=9 (lane_cmd itself failed — e.g. a missing
# key) is handled up front: with no CLI ever invoked there's no run-<id>.jsonl for limit_error to
# inspect, so left to the generic path this would retry the same broken lane forever, silently.
# FR-11 requires loud, not silent — flag the lane limited immediately and fail over (or park, if
# pinned) instead.
# FR-12 (amended): a `.timedout` marker (dropped by _spawn_worker's watchdog right before it kills
# the worker's subtree) ALWAYS forces chain-advance/park, same as wrc==9 — a hang isn't a
# rate-limit signature limit_error would recognize, and just re-queuing onto the SAME lane would
# likely hang again on the very next attempt. UNLIKE wrc==9, it does NOT limit_flag the lane — a
# kill-truncated stream is not limit evidence, only a signal this ONE branch couldn't finish in time.
# FR-14: <token> is this worker's claim file identity (dev:inode, captured by _run_pool at claim
# time) — the fencing token against lease-steal double-finalize. A slow-but-alive worker whose
# lease got reaped is re-queued and re-claimed (often onto the SAME lane, since reap doesn't touch
# EXEC_CHAIN state — same path, a NEW file/inode); if the stale original finishes later and this
# check only looked at the PATH, it would still find "a file there" and clobber the retry's
# result. Comparing the inode catches that a same-path claim has since been recreated out from
# under it. Applies to every finalize path uniformly: whatever this worker thinks happened, a
# fenced-out worker's view of id's fate is moot — something newer already owns it.
# _lane_auth_dead <bare> — spec 14 FR-6 cross-review MAJOR: an auth-death envelope that got
# downgraded (a live sibling was on the lane) never writes `.dead` at all — the lib's own downgrade
# path writes a `.broken` marker whose reason token IS `auth-death` instead. `lane_dead` alone misses
# that downgraded case, so both places below that need to know "is this lane really auth-dead" (the
# class-keying arm and the fallback-provenance arm, which must agree with each other) share this one
# check instead of carrying the same compound condition twice.
_lane_auth_dead() {
  lane_dead "$BUSDIR" "$1" || grep -q -- '| auth-death |' "$BUSDIR/limits/$1.broken" 2>/dev/null
}
_finalize_worker() {
  local id="$1" lane="$2" wrc="$3" token="$4" bare="${2%%:*}"
  local pinned=0
  [[ -e "$BUSDIR/queue/$id.lane" ]] && pinned=1
  rm -f "$BUSDIR/pids/$id"  # worker is done (however it ended) — always clear its registry entry

  local current_token
  current_token="$(_stat_devino "$BUSDIR/claimed/$id.$lane" 2>/dev/null || true)"
  if [[ -z "$current_token" || "$current_token" != "$token" ]]; then
    printf '{"type":"stale-finalize","id":"%s","lane":"%s"}\n' "$id" "$lane" >> "$BUSDIR/run-$id.jsonl"
    return 0  # fenced out — a NEWER worker may own this id's cage right now; must NOT delete it here
  fi
  # A (fence-validated) worker RAN, so its pin wasn't blocked this attempt — clear any stale FR-R6
  # wait marker (left by an earlier blocked phase), or a later blocked poll would age against the
  # old mtime and park prematurely. AFTER the fence: a stale finalizer must not erase a newer
  # requeue's live wait marker (r3codex MIN). `.waiting-write` (FR-5's own marker, distinct from
  # FR-R6's `.waiting`) is belt-and-braces here — a worker only ever spawns once its write target
  # exists, which already clears it, but a fenced-out stale finalizer must not leave it behind.
  rm -f "$BUSDIR/limits/$id.waiting" "$BUSDIR/limits/$id.waiting-write"

  # Credential cage cleanup: this worker has exited and we still own the claim (fenced-in above), so
  # its per-worker scratch home is dead weight now — copied OAuth credential files must not linger
  # readable by a later same-bus spawn. A requeue/retry re-creates the cage fresh on the next spawn.
  # Single choke point: every non-stale path below (timeout / lane-unusable / success / failover)
  # flows through here, none of them re-reads the cage.
  rm -rf "${BUSDIR:?}/home/$bare.$id" 2>/dev/null || true

  # Fence the watchdog marker the same way the claim itself is fenced: a NON-EMPTY token that isn't
  # ours belongs to an earlier attempt on this id (the marker path carries no attempt identity),
  # and consuming it would finalize a live, healthy claim as timed out. Drop it and carry on.
  if [[ -e "$BUSDIR/limits/$id.timedout" ]]; then
    local tdtok; tdtok="$(<"$BUSDIR/limits/$id.timedout")"
    [[ -n "$tdtok" && "$tdtok" != "$token" ]] && rm -f "$BUSDIR/limits/$id.timedout"
  fi

  if [[ -e "$BUSDIR/limits/$id.timedout" ]]; then
    rm -f "$BUSDIR/limits/$id.timedout"
    # spec 01 FR-12 amendment (2026-07-25, backlog 17+10): salvage genuine on-disk work before
    # declaring the attempt failed. TIMEOUT_SALVAGE=0 restores the discard-everything behavior
    # everywhere (env-only knob — not a conf_load key, see the spec amendment).
    if [[ "${TIMEOUT_SALVAGE:-1}" == "1" ]]; then
      local srx=0
      _salvage_timeout "$id" "$lane" "$bare" "$wrc" "$pinned" || srx=$?
      (( srx == 0 )) && return 0
      # rc 2 = a critical bus mutation failed PART-WAY through the salvage (see _salvage_timeout's
      # explicit checks). Loud, then fall through to the ordinary timeout failover — a re-queued
      # card is recoverable, a silently half-finalized one is not.
      if (( srx == 2 )); then
        echo "swarm-run: $id salvage FAILED mid-transition (archive/done-marker write) — bus may be inconsistent for this id" >&2
      fi
    fi
    # cross-review MINOR: a watchdog-killed cage-denied card (e.g. the FR-1 gate's answer landed,
    # then the worker hung post-answer instead of exiting) used to skip straight to the ordinary
    # timeout failover and chain-advance through every rung of a guaranteed-futile cage. Same check,
    # same park, as the success path.
    _check_cage_denied "$id" "$lane" "$bare" "$pinned" && return 0
    # spec 01 FR-12 amendment: a kill-truncated stream is not limit evidence — do NOT limit_flag
    # the lane here (contrast wrc==9 below, a genuine lane-unusable signal, which still does).
    echo "swarm-run: worker for $id on lane '$lane' exceeded WORKER_TIMEOUT_SEC — killed, failing over" >&2
    # no-silent-spend: a timed-out worker ran a CLI and spent before it was killed (model-lanes.md).
    [[ "${LEDGER_AUTO:-1}" == "1" ]] && ledger_failed_row "$BUSDIR" "$id" "$bare" "timeout" 2>/dev/null || true
    [[ "${SPEEDWARS_AUTO:-1}" == "1" ]] && speed_row "$BUSDIR" "$id" "$lane" "timeout" "$wrc" "$pinned" "timeout-watchdog" 2>/dev/null || true
    # A pinned park is TERMINAL — _park_card appends the final `parked` row after the attempt row
    # above, so the branch's last-row fate matches its .parked marker (run_summary reads the last).
    if (( pinned )); then _park_card "$id" "$lane" 1 "timeout-watchdog"; else chain_advance "$BUSDIR" "$id"; fi
    # spec01 Amendment 2026-07-25 FR-A binding mitigation #3: name the mover in every finalize-tail
    # requeue, alongside reap()'s own note — without attribution, a future double-claim incident
    # can't tell whether reap or this finalize-tail path moved the claim.
    if [[ -e "$BUSDIR/claimed/$id.$lane" ]]; then
      echo "swarm-run: mover=finalize-tail requeued $id (lane '$lane') to queue/ — timeout" >&2
      mv "$BUSDIR/claimed/$id.$lane" "$BUSDIR/queue/$id.prompt"
    fi
    return 0
  fi

  if (( wrc == 9 )); then
    echo "swarm-run: lane '$lane' unusable for $id (lane_cmd failed — see stderr above); flagging" >&2
    limit_flag "$BUSDIR" "$bare" 18000
    [[ "${SPEEDWARS_AUTO:-1}" == "1" ]] && speed_row "$BUSDIR" "$id" "$lane" "lane-unusable" "$wrc" "$pinned" "spawn-fail" 2>/dev/null || true
    if (( pinned )); then _park_card "$id" "$lane" 1 "spawn-fail"; else chain_advance "$BUSDIR" "$id"; fi
    if [[ -e "$BUSDIR/claimed/$id.$lane" ]]; then
      echo "swarm-run: mover=finalize-tail requeued $id (lane '$lane') to queue/ — spawn-fail" >&2
      mv "$BUSDIR/claimed/$id.$lane" "$BUSDIR/queue/$id.prompt"
    fi
    return 0
  fi

  if extract_answer "$bare" "$id" "$BUSDIR"; then
    # spec 14 FR-1 (backlog 44): the cage-denied check runs FIRST — ahead of the write-diff gate and
    # answer_unusable both. A read-denied worker typically also wrote nothing AND produced an
    # error-shaped answer, so leaving it to those gates classifies the run as false-done/api-error
    # and CHAIN-ADVANCES: every rung shares the same permission cage, so the walk is guaranteed
    # futile and every rung is metered spend. Park instead, pinned or not — and never chain_advance
    # (FR-3's chain_reset belongs to the chain-exhausted park only; this card's .chain state must
    # come out exactly as it went in, so a later `swarm-ctl nudge` resumes from where it stood).
    _check_cage_denied "$id" "$lane" "$bare" "$pinned" && return 0
    # spec 12 FR-1: fail_class carries the failure-class vocabulary value for whichever gate below
    # rejects this "done" — read by the failover/retry speed_row call further down (this id may
    # still fall through to there if reject_reason ends up set). unusable_class holds
    # answer_unusable's own echoed class separately so fail_class can distinguish "false-done" (the
    # write-gate) from the auth/api/server-error classes (answer_unusable) sharing this same block.
    local reject_reason="" fail_class="" unusable_class=""
    # spec10 FR-R11 write-card diff gate: a served "done" that never touched anything under its
    # pinned write target is a false completion (a CLI can exit 0 having only talked, never
    # edited) — `find -newer` against the pre-spawn stamp (_spawn_worker) is the same signal a
    # `git status`-style check uses to detect "nothing changed here".
    if [[ -e "$BUSDIR/queue/$id.write" ]] && ! _write_target_changed "$id"; then
      reject_reason="write target '$(<"$BUSDIR/queue/$id.write")' shows no change since spawn"
      fail_class="false-done"
    fi
    # spec10 FR-R8/FR-R11 cross-lane false-done classifier: an auth-death or API-error-as-answer
    # run looks like a normal completion to extract_answer (no error/turn.failed event ever
    # fires) — never trust it as done. The assignment-as-if-condition form (spec 12 FR-1) captures
    # answer_unusable's echoed class on stdout while still routing rc through the `if` — a plain
    # `class=$(...)` assignment would instead trip errexit under `set -e` on the healthy rc-1 case.
    if [[ -z "$reject_reason" ]] && unusable_class="$(answer_unusable "$bare" "$BUSDIR" "$id")"; then
      reject_reason="served answer from '$bare' is unusable (auth/error signature)"
      fail_class="$unusable_class"
    fi

    if [[ -n "$reject_reason" ]]; then
      rm -f "$BUSDIR/res-$id.txt"
      echo "swarm-run: $id rejected on lane '$lane' — $reject_reason" >&2
    else
      # Both gemini and z.ai are known to silently alias/upgrade the requested model
      # (rules/unimatrix/model-lanes.md) — log what actually served this, not just the pin, so a
      # future aliasing surprise shows up in the run log rather than only in the billing dashboard.
      local sm; sm="$(served_model "$bare" "$BUSDIR" "$id" 2>/dev/null || true)"
      [[ -n "$sm" ]] && echo "swarm-run: $id served by $bare:$sm (requested $lane)" >&2
      # Archive the verify wave's provenance, then drop claim + sidecars + lane-health flags —
      # shared with the timeout-salvage path so the two can never drift (see _archive_and_release).
      _archive_and_release "$id" "$lane" "$bare"
      # spec 11 FR-S4: while a non-fable orch-seat is acting, every done record is provisional —
      # stamp degraded:true. Under fable (or absent seat) the key is entirely omitted, not false.
      # One printf = one write(2) per record (bus-discipline.md).
      local deg=""
      if orch_degraded "$BUSDIR"; then deg=',"degraded":true'; fi
      # spec 12 FR-2: the real worker rc, not a hardcoded 0 — $wrc is always numeric (the pool's
      # own `wait` exit code), so it's safe to interpolate unquoted into the JSON number position.
      printf '{"id":"%s","code":%s,"lane":"%s"%s}\n' "$id" "$wrc" "$bare" "$deg" > "$BUSDIR/done/$id"
      chain_reset "$BUSDIR" "$id"
      # spec10 FR-R10: kimi is real PAYG $ (not pooled subscription capacity) — accumulate actual
      # spend against BUDGET_USD only on a lane this card confirms genuinely finished.
      [[ "$bare" == kimi ]] && _kimi_spend_add "$BUSDIR" "$id"
      # Ledger — no silent spend (rules/unimatrix/model-lanes.md). Trailing `|| true` is
      # load-bearing, not decoration: under `set -e`, a false LEDGER_AUTO check (short-circuited
      # `&&`, itself nonzero) or a ledger-write hiccup would otherwise trip errexit and abort a run
      # that had ALREADY succeeded (same class of bug as pitfalls #18).
      [[ "${LEDGER_AUTO:-1}" == "1" ]] && ledger_row "$BUSDIR" "$id" 2>/dev/null || true
      [[ "${SPEEDWARS_AUTO:-1}" == "1" ]] && speed_row "$BUSDIR" "$id" "$lane" "done" "$wrc" "$pinned" 2>/dev/null || true
      return 0
    fi
  fi

  local lrc=0
  limit_error "$bare" "$BUSDIR" "$id" || lrc=$?
  # no-silent-spend: a CLI ran (run-<id>.jsonl exists) but produced no usable answer — log the
  # spend and why it's being re-queued (fail-over vs retry-same-lane), per model-lanes.md.
  local reason="retry"; (( lrc == 1 )) && reason="rate-limited, failover"
  [[ "${LEDGER_AUTO:-1}" == "1" ]] && ledger_failed_row "$BUSDIR" "$id" "$bare" "$reason" 2>/dev/null || true

  # spec 13 FR-3: peek whether THIS attempt is about to actually chain_advance for a NON-limit
  # reason (retries exhausted) — a real failover, not just another bounded same-lane retry. Read-
  # only against the SAME counter file the retry bookkeeping below reads/writes, so the two stay in
  # lockstep without double-incrementing. lrc==1/2 already have their own dedicated classes below
  # (rate-limit/auth-death), so this only matters when lrc==0 (limit_error saw no signal at all).
  local exhausting=0
  if (( lrc != 1 && lrc != 2 )); then
    local _rpeek_f="$BUSDIR/limits/.retries-$id" _rpeek=0
    [[ -f "$_rpeek_f" ]] && _rpeek="$(<"$_rpeek_f")"
    (( _rpeek + 1 >= ${MAX_LANE_RETRIES:-3} )) && exhausting=1
  fi

  # spec 12 FR-1: classify this failed branch for speed_row's optional class field. A mid-flight
  # auth-death (lrc==1 AND lane_dead — checked here, BEFORE chain_advance below touches anything)
  # takes priority over a plain rate-limit (lrc==1 or 2, lane not dead); otherwise this branch fell
  # through from the extract_answer block above with whatever gate rejected it there (false-done or
  # answer_unusable's own class, captured in $fail_class), or genuinely produced no usable answer
  # at all (extract_answer itself failed — $fail_class stays unset, "no-answer").
  # spec 13 FR-3 (backlog 34): a lane that RAN (run-<id>.jsonl exists) but served NO model at all —
  # the observed grok brain058 fast-fail shape — gets flagged .broken right at the genuine-failover
  # moment (exhausting==1), never on an intermediate bounded retry (that would defeat
  # MAX_LANE_RETRIES by making the pool route around the lane after its first noisy attempt). codex
  # is excluded: served_model has no signal for it at all (no field captured in its stream shape
  # today, model-lanes.md), so "empty" there is meaningless, not evidence of a dead lane.
  # The arm is gated on `-z "$fail_class"` (round-4 MIN): an ALREADY-classified rejection
  # (false-done from the write-diff gate, or answer_unusable's api-/server-error) is per-CARD
  # behaviour and must keep its own class — inferring "lane served no model" over it both loses the
  # stronger fact and cools a working lane for 30 minutes over one bad card.
  # spec 14 FR-5 companion (backlog 51): `-f` was replaced with `-s`, grouped with `|| wrc 126|127`.
  # `env -C` on a missing .write target exits 125 before the CLI emits a byte, leaving a run log
  # that EXISTS but is empty — that's a CARD fault (the target was refused/waited on above, never
  # spawned into) and must never masquerade as this lane being down. `-s` alone would be wrong,
  # though: a missing/non-executable lane binary also dies with zero stdout, and THAT genuinely is
  # a lane fault deserving `.broken` — the 126/127 arm keeps that case flagged.
  local class
  # _lane_auth_dead (above): an auth-death envelope downgraded by spec 14 FR-6 (a live sibling was on
  # this lane) never writes `.dead` at all, only a `.broken` marker whose reason token is
  # `auth-death` — `lane_dead` alone would miss it and fall through to the generic rate-limit class.
  if (( lrc == 1 )) && _lane_auth_dead "$bare"; then
    class="auth-death"
  elif (( lrc == 1 || lrc == 2 )); then
    class="rate-limit"
  elif [[ -z "${fail_class:-}" ]] && (( exhausting )) && [[ "$bare" != codex ]] \
       && { [[ -s "$BUSDIR/run-$id.jsonl" ]] || (( wrc == 126 || wrc == 127 )); } \
       && [[ -z "$(served_model "$bare" "$BUSDIR" "$id" 2>/dev/null)" ]]; then
    class="lane-down"
    # spec 14 FR-6 (backlog 54): positive liveness evidence outranks a failure counter. If ANOTHER
    # card on this lane is provably still streaming, the lane is not down whatever this card just
    # reported — cooling it for 30 minutes would route every following card around a working lane
    # until that sibling happens to finalize. Downgraded, never skipped: the card still failed and
    # that deserves a record, so the lane takes a short-TTL .limited instead of .broken. The CLASS
    # stays lane-down either way — the card's own fate is unchanged, only the lane's.
    if lane_has_live_worker "$BUSDIR" "$bare" "$id"; then
      # cross-review MAJOR: this downgrade stays a SHORT-TTL `.broken`, never `.limited` — `.broken`
      # is cleared by the lane's own next successful finalize (_archive_and_release), which is
      # imminent exactly when this guard fires (a live sibling); `.limited` is never cleared by any
      # code path except its own TTL, so switching families here would make the downgrade outlive
      # the very evidence (a healthy sibling) that justified it.
      echo "swarm-run: $bare fast-fail on $id NOT flagged .broken (long) — a sibling worker on this lane is live; short-TTL .broken instead" >&2
      broken_flag "$BUSDIR" "$bare" 600 lane-down "$bare: fast-fail on card $id downgraded — sibling live"
    else
      broken_flag "$BUSDIR" "$bare"
    fi
  else
    class="${fail_class:-no-answer}"
  fi
  [[ "${SPEEDWARS_AUTO:-1}" == "1" ]] && speed_row "$BUSDIR" "$id" "$lane" "${reason// /-}" "$wrc" "$pinned" "$class" 2>/dev/null || true
  if (( lrc == 1 )); then
    # spec10 FR-R9 (r3codex MAJ): a MID-FLIGHT limit/dead signal is fallback provenance too —
    # record it (first-writer-wins, AFTER the failed attempt's own row above consumed any prior
    # marker) so the successor lane's done row carries fallback_reason + the original requested.
    local fbfile="$BUSDIR/limits/.fbreason-$id" fbreason="limit" orig_bare
    # same _lane_auth_dead detection as the class keying above — the fallback provenance must agree
    # with the class it accompanies.
    _lane_auth_dead "$bare" && fbreason="dead"
    orig_bare="$(_orig_chain_bare "$BUSDIR" "$id")"
    [[ -e "$fbfile" ]] || printf '%s %s' "$fbreason" "$orig_bare" > "$fbfile"
    if (( pinned )); then _park_card "$id" "$lane" 1 "$class"; else chain_advance "$BUSDIR" "$id"; fi
  else
    # FR-6's retry-same-lane is BOUNDED (MAX_LANE_RETRIES). Without a cap, a lane that
    # persistently fails with no recognized limit signature (deprecated model, drifted stream-json
    # shape) re-queues onto itself forever: the spec is never done nor parked, the pool gate never
    # closes, and in /swarm-loop even the budget/wall-clock stop rules can't fire (they run
    # between iterations, and the iteration never returns) — unbounded spend. Consecutive
    # unusable-answer failures on the CURRENT lane count against the cap; chain_advance clears the
    # counter, so each fail-over lane gets a fresh budget (mirrors the codex.strikes pattern).
    local rfile="$BUSDIR/limits/.retries-$id" retries=0
    [[ -f "$rfile" ]] && retries="$(<"$rfile")"
    retries=$(( retries + 1 ))
    if (( retries >= ${MAX_LANE_RETRIES:-3} )); then
      rm -f "$rfile"
      echo "swarm-run: $id produced no usable answer $retries times on lane '$lane' — retries exhausted" >&2
      if (( pinned )); then _park_card "$id" "$lane" 1 "$class"; else chain_advance "$BUSDIR" "$id"; fi
    else
      printf '%s' "$retries" > "$rfile"
    fi
  fi
  # spec01 Amendment 2026-07-25 FR-A binding mitigation #3: same mover attribution as the timeout
  # and spawn-fail requeues above — this is the generic retry/failover finalize-tail path.
  if [[ -e "$BUSDIR/claimed/$id.$lane" ]]; then
    echo "swarm-run: mover=finalize-tail requeued $id (lane '$lane') to queue/ — retry/failover" >&2
    mv "$BUSDIR/claimed/$id.$lane" "$BUSDIR/queue/$id.prompt"
  fi
}

# bash wait -n job pool, bounded by FANOUT (specs/01 FR-5). Runs inside its own process group
# (full_run backgrounds this under `set -m`), so `swarm-ctl abort` can kill it in one shot.
_run_pool() {
  local -A pid_id=() pid_lane=() pid_token=()
  local running=0

  while true; do
    reap "$BUSDIR" "$LEASE_MIN"

    local counts done_n live_n parked_n
    counts="$(gate_count "$BUSDIR")"
    done_n="${counts%% *}"; live_n="${counts##* }"
    # FR-7 addendum: a parked branch (EXEC_CHAIN exhausted, or a pinned lane that can't proceed)
    # stays sitting in queue/ forever — it will NEVER get a done/ marker, so without counting it
    # here `done_n >= live_n` would never hold and the pool would hang forever waiting on it. A
    # spec that's genuinely still pending (not done, not parked) is neither counted here, so this
    # can't mask real in-flight work — it only unblocks the gate once EVERY live spec is one or the
    # other. _check_parked (called after the pool returns) is what makes this loud, not silent.
    parked_n="$(find "$BUSDIR/limits" -maxdepth 1 -name '*.parked' 2>/dev/null | wc -l)"
    if (( done_n + parked_n >= live_n )) && (( running == 0 )); then
      break
    fi

    while (( running < FANOUT )); do
      local crc=0
      _try_claim_one || crc=$?  # rc 1/2 are expected outcomes, not errors — must not trip -e
      (( crc == 0 )) || break
      # FR-14 fencing token: this exact claim FILE's identity (dev:inode), captured the instant
      # after claim() creates it — not just its path, which a same-lane retry after a lease-steal
      # would recreate identically.
      local ctoken
      ctoken="$(_stat_devino "$BUSDIR/claimed/$CLAIMED_ID.$CLAIMED_LANE" 2>/dev/null || true)"
      _spawn_worker "$CLAIMED_ID" "$CLAIMED_LANE" &
      local pid=$!
      pid_id[$pid]="$CLAIMED_ID"; pid_lane[$pid]="$CLAIMED_LANE"; pid_token[$pid]="$ctoken"
      running=$(( running + 1 ))
    done

    if (( running > 0 )); then
      local finished="" wrc=0
      wait -n -p finished || wrc=$?  # a worker's own nonzero exit must not trip our -e
      # -p leaves the var UNSET when wait -n is interrupted by a signal or finds no child
      # (rc 127) — observed live 2026-07-19 (w5: SIGKILLed workers -> "finished: unbound
      # variable" aborted the whole pool). Nothing finalized; just re-enter the loop.
      [[ -n "$finished" ]] || continue
      _finalize_worker "${pid_id[$finished]}" "${pid_lane[$finished]}" "$wrc" "${pid_token[$finished]}"
      unset 'pid_id[$finished]' 'pid_lane[$finished]' 'pid_token[$finished]'
      running=$(( running - 1 ))
    else
      sleep 1
    fi
  done
}

# _sweep_on_driver_term <pool_pid> — FR-13 driver-death sweep. Group-kill the pool (primary
# mechanism — covers every worker, verified they share its pgid) plus a belt-and-braces sweep of
# every registered .bus/pids/* entry (covers a worker that, for any reason, ever escapes that
# shared group). Not an EXIT trap — pitfalls §15 (a group leader's own EXIT trap self-inclusive
# `kill 0` segfaults this bash); this trap runs in the driver, which is not that leader.
_sweep_on_driver_term() {
  local pool_pid="$1" f
  kill -- "-$pool_pid" 2>/dev/null || true
  for f in "$BUSDIR"/pids/*; do
    [[ -e "$f" ]] || continue
    kill_subtree "$(<"$f")" KILL
  done
  # Credential cage sweep: the run is terminating and every worker is being killed, so wipe the
  # per-worker scratch homes wholesale — copied OAuth credential files must not survive the run.
  rm -rf "${BUSDIR:?}/home" 2>/dev/null || true
  exit 143
}

# _enqueue_pending_specs — mv every .bus/specs/<id>.prompt (+ optional <id>.lane sidecar, FR-2b,
# and <id>.write sidecar, FR-15) into queue/. Shared by full_run (generate wave) and verify_run
# (verify wave, Phase E step 4) — a verify spec is ordinary bus work once written, not a special
# case for the pool (verify specs never carry a .write sidecar — review is always read-only).
# Sidecars move BEFORE the prompt (prompt = visibility marker, last) — wave-7 finding 3: the pool
# only ever claims *.prompt out of queue/, so a crash between the two mv's used to be able to
# leave a prompt-only footprint there, claimable UNPINNED (judge == executor risk for a verify
# spec). Moving sidecars first means a crash mid-way leaves, at worst, orphan sidecars with no
# prompt yet — never a live, unpinned prompt.
#
# spec01 Amendment 2026-07-25 FR-B (backlog 56, closes backlog 13): a terminal-state guard runs at
# the TOP of the loop body, before ANY sidecar mv — position is load-bearing, since an orphan
# .write landing in queue/ silently re-grants write access to a stale target (src/swarm-ctl:82-90).
# Re-running the driver against a bus whose seeder re-wrote specs/ must never re-execute a done
# card, resurrect a cancelled one, or hand a claimed/queued card a second prompt. `done`/`cancelled`
# ids are consumed-and-discarded (the work is over; leaving the file re-triggers the same line on
# every relaunch forever); claimed/queued ids are a non-destructive skip (the card is in flight, or
# a reap-requeued prompt may carry a `cmd_nudge` OPERATOR HINT block this sweep's own mv would
# otherwise clobber) — `swarm-ctl add`/`nudge` are the redo verbs, not a driver re-run.
_enqueue_pending_specs() {
  local f id
  for f in "$BUSDIR"/specs/*.prompt; do
    [[ -e "$f" ]] || continue
    id="$(basename "$f" .prompt)"

    if [[ -e "$BUSDIR/done/$id" ]]; then
      echo "swarm-run: $id already in done/ — discarding stale specs/ entry (re-run guard)" >&2
      rm -f "$f" "$BUSDIR/specs/$id.lane" "$BUSDIR/specs/$id.write" "$BUSDIR/specs/$id.chain" \
            "$BUSDIR/specs/$id.files"
      continue
    fi
    if [[ -e "$BUSDIR/cancelled/$id.prompt" ]]; then
      echo "swarm-run: $id already in cancelled/ — discarding stale specs/ entry (re-run guard)" >&2
      rm -f "$f" "$BUSDIR/specs/$id.lane" "$BUSDIR/specs/$id.write" "$BUSDIR/specs/$id.chain" \
            "$BUSDIR/specs/$id.files"
      continue
    fi
    # _claim_of, never a bare glob (claimed/"$id".* prefix-matches a dotted id like "$id.bar" onto
    # the WRONG worker's claim — the exact wave-7 bug _claim_of exists to avoid repeating).
    if _claim_of "$BUSDIR" "$id" >/dev/null; then
      echo "swarm-run: $id is currently claimed — leaving specs/ entry in place, NOT re-enqueuing" >&2
      continue
    fi
    if [[ -e "$BUSDIR/queue/$id.prompt" ]]; then
      echo "swarm-run: $id is already queued — leaving specs/ entry in place, NOT re-enqueuing (would clobber a live OPERATOR HINT)" >&2
      continue
    fi

    [[ -e "$BUSDIR/specs/$id.lane" ]] && mv "$BUSDIR/specs/$id.lane" "$BUSDIR/queue/$id.lane"
    [[ -e "$BUSDIR/specs/$id.write" ]] && mv "$BUSDIR/specs/$id.write" "$BUSDIR/queue/$id.write"
    [[ -e "$BUSDIR/specs/$id.chain" ]] && mv "$BUSDIR/specs/$id.chain" "$BUSDIR/queue/$id.chain"
    # spec 14 FR-2: the deliverable manifest is a sidecar like the other three — same order, same
    # discard arms above. A sidecar the sweep can MOVE but not DISCARD is the FR-B bug reborn.
    [[ -e "$BUSDIR/specs/$id.files" ]] && mv "$BUSDIR/specs/$id.files" "$BUSDIR/queue/$id.files"
    mv "$f" "$BUSDIR/queue/$id.prompt"
  done
  # Explicit, load-bearing: without it, this function's return status is whatever the LAST loop
  # iteration's `[[ ]] && mv` left behind — false (no .lane sidecar) is errexit-EXEMPT inline (a
  # non-final && component with more code after it), but once that's the last thing a whole
  # FUNCTION executes, the bare call site (`_enqueue_pending_specs`, not itself in an if/&&/||
  # context) is NOT exempt — a plain function call returning nonzero trips errexit same as any
  # other command. (Same failure class as docs/02-build-pitfalls.md #18, one layer up: extraction
  # into a function changes what's "the last command" for errexit purposes.)
  return 0
}

# _drive_pool — launch the wait -n job pool in its own process group (so `swarm-ctl abort` / a
# direct TERM to the driver can reach every worker at once), block until its gate closes, then
# return. Shared by full_run and verify_run — same pool, same gate semantics (spec-01 FR-7),
# just a different set of queue/ entries to drain.
_drive_pool() {
  # NOTE: trap deliberately omits EXIT here — verified (2026-07-08) that on this bash build
  # (5.2.21), a process-group leader's own EXIT trap firing `kill 0` (self-inclusive) segfaults
  # bash, reproducibly, regardless of whether the group came from `set -m` or `setsid`. INT/TERM
  # (the actual `swarm-ctl abort` path) fire `kill 0` in response to a signal from OUTSIDE this
  # process and do not crash. Since _run_pool only returns once running==0 (no jobs left), the
  # EXIT trap's only real job — mopping up orphans after an uncaught internal error — is a rare
  # edge case traded for not crashing on every normal completion. This matches specs/01 FR-5, which
  # was reconciled to "trap 'kill 0' INT TERM — deliberately NOT EXIT" (the segfault finding); the
  # code and the spec now agree.
  set -m
  ( trap 'kill 0' INT TERM; _run_pool ) &
  local pool_pid=$!
  set +m
  echo "$pool_pid" > "$BUSDIR/run.pgid"

  # FR-13: TERM/INT delivered directly to THIS (driver) process — not via `swarm-ctl abort`, which
  # targets the pool's pgid directly and already works today (verified live: workers spawned
  # inside the pool subshell share ITS pgid, so a single `kill -- "-$pool_pid"` already reaches
  # every worker and its descendants) — must still sweep every in-flight worker. This process is
  # an ordinary member of ITS OWN parent's group, not the pool's, so nothing propagates to the pool
  # without an explicit trap here (live E2E finding 2026-07-08: workers survived a TERM'd driver
  # twice before this trap existed).
  trap '_sweep_on_driver_term "$pool_pid"' INT TERM
  wait "$pool_pid" || true
  trap - INT TERM
  # The pool (and its group) is gone now — drop the abort target so a later `swarm-ctl abort`
  # can't `kill -- -<stale-pgid>` an unrelated process group after pid reuse.
  rm -f "$BUSDIR/run.pgid"
}

# _check_parked <busdir> — FR-7 addendum: parked branches are terminal for the gate (_run_pool's
# done+parked>=live break above) so they never hang a run forever, but they are NEVER a silent
# partial completion either — this is the "loud" half of that fix. Prints each parked id to stderr
# and returns nonzero when any exist; rc 0 (silent) otherwise. Called as the LAST statement of
# full_run/verify_run specifically so it can run AFTER their results section prints — whatever DID
# complete is still reported before the run declares itself incomplete.
_check_parked() {
  local busdir="$1" f id rc=0 line token
  for f in "$busdir"/limits/*.parked; do
    [[ -e "$f" ]] || continue
    id="$(basename "$f" .parked)"
    # cross-review NOTE: read the FR-7 reason line's token (field 2 of
    # "<ISO8601> | <token> | retryable=.. | ttl=.. | text") instead of a hardcoded "lane exhausted"
    # for every park — falls back to the legacy wording for an empty/digit-only/unmatched marker.
    # $(<"$f") is bash's fast-read builtin form — NOT a `cat` invocation, so it takes no
    # redirection of its own; the loop's own `[[ -e "$f" ]]` guard above already ensures the read
    # is safe. Appending `2>/dev/null` here silently breaks the special parse into a no-op
    # substitution (verified: `echo $(<file 2>/dev/null)` prints nothing) — a real bug, not
    # defensive.
    line="$(<"$f")"; token=""
    [[ "$line" =~ ^[^\|]*\|[[:space:]]*([a-z-]+)[[:space:]]*\| ]] && token="${BASH_REMATCH[1]}"
    echo "swarm-run: $id parked (${token:-lane exhausted}) — never completed, run is INCOMPLETE" >&2
    rc=1
  done
  return "$rc"
}

# _close_out_evidence <mode> — spec 12 FR-3/FR-4/FR-5: fires the run-summary ledger row + the
# auto-drafted feedback stubs, then the 4-line run-close checklist. Shared by full_run/verify_run
# so the two call sites can never drift; called BEFORE _check_parked (whose rc must stay the run's
# own rc — evidence capture must never influence it). Every step here is best-effort by
# construction (`2>/dev/null || true`): evidence gathering must never fail an otherwise-good run.
_close_out_evidence() {
  local mode="$1"
  [[ "${SPEEDWARS_AUTO:-1}" == "1" ]] && run_summary "$BUSDIR" "$mode" 2>/dev/null || true
  # plan 004 P2-FR1: the three-line lane summary, straight off the canonical fold (src/
  # speedwars-report.sh) scoped to this run. NOT `2>/dev/null` like its neighbours — the summary IS
  # stderr output; it silences its own internals instead. P2 archive follows it (raw evidence
  # freeze), so the operator sees the numbers before the slow step runs.
  [[ "${SPEEDWARS_AUTO:-1}" == "1" ]] && lane_summary "$BUSDIR" || true
  [[ "${SPEEDWARS_AUTO:-1}" == "1" ]] && bus_archive "$BUSDIR" 2>/dev/null || true
  [[ "${FEEDBACK_AUTO:-1}" == "1" ]] && feedback_stubs "$BUSDIR" 2>/dev/null || true
  # The checklist prints to STDERR (not stdout) — same convention as every other operator notice in
  # this file (park/exhaustion/failover lines above), keeping stdout free for `=== results ===`/
  # `=== verify results ===` machine-parseable output.
  {
    echo "swarm-run: run close checklist —"
    echo "  1. run-reviews entry: swarm-ctl review-stub"
    echo "  2. backlog DONE sweep (docs/research-backlog.md)"
    echo "  3. distill notes-lessons.md into the skill lessons ledger"
    echo "  4. confirm feedback/*-auto-*.md drafts (feedback/README.md)"
  } >&2
}

full_run() {
  conf_load "$CONF"
  bus_init "$BUSDIR"
  # Pin THIS run's ledger key into the bus while we still have a write context, so every later
  # reader — including `swarm-ctl review-stub` from a fresh shell with no env — joins on the same
  # label these rows are about to be written under (specs/08 §Amendment 2026-07-25).
  _run_label_persist "$BUSDIR"
  _print_banner
  # spec 13 FR-1: abort before any fan-out if this run's lane set needs an env-key lane
  # (gemini/glm/kimi) and $ENV_MASTER_FILE is unreachable — env_master_preflight prints its own
  # loud path+fix message.
  env_master_preflight "$BUSDIR" || return 1
  { mon_web_ensure && mon_web_open; } || true

  # "starts at enqueue" (specs/01 FR-1): anything Fable wrote to specs/ moves to queue/ now.
  _enqueue_pending_specs
  _drive_pool

  echo "=== results ==="
  local r
  for r in "$BUSDIR"/res-*.txt; do
    [[ -e "$r" ]] || continue
    echo "$r"
  done

  _close_out_evidence full
  _check_parked "$BUSDIR"
}

# verify_run — Phase E step 4: cross-model verify wave. For every completed generate-wave branch
# (done/<id>, provenance "lane" field), write_verify_spec (src/swarm-lib.sh) builds a v-<id> spec
# pinned to a lane != its generator via VERIFY_MAP, then the SAME pool mechanics drain it — a
# verify spec is ordinary bus work, gate semantics unchanged. Safe to call repeatedly: idempotent
# per write_verify_spec (no-ops for any <id> whose v-<id> already has a bus footprint), so a second
# `swarm-run.sh verify` after new branches complete only generates/runs the NEW ones.
verify_run() {
  conf_load "$CONF"
  bus_init "$BUSDIR"
  _run_label_persist "$BUSDIR"   # same run-start pin as full_run above
  _print_banner
  # spec 13 FR-1: same launch-time abort as full_run — but in `verify` mode, which additionally
  # resolves the verifier ACTUALLY picked for each done branch (verify_lane_for) instead of ignoring
  # VERIFY_MAP entirely. Without it a verify wave could pass preflight and then fan out env-key
  # verifiers against an unreadable env-master, one parked card at a time.
  env_master_preflight "$BUSDIR" verify || return 1

  local f id
  for f in "$BUSDIR"/done/*; do
    [[ -e "$f" ]] || continue
    id="$(basename "$f")"
    write_verify_spec "$BUSDIR" "$id" || true
  done

  _enqueue_pending_specs
  _drive_pool

  echo "=== verify results ==="
  local r
  for r in "$BUSDIR"/res-v-*.txt; do
    [[ -e "$r" ]] || continue
    echo "$r"
  done

  _close_out_evidence verify
  _check_parked "$BUSDIR"
}

# doctor — read-only environment probe: bash version, core-tool presence, GNU-vs-BSD quirks, worker
# CLIs on PATH, secrets-file readability, and the bus filesystem type (warns on 9p/drvfs/nfs, where
# O_APPEND/flock/inotify are unreliable). Purely diagnostic; never fatal, always exits 0.
cmd_doctor() {
  echo "=== unimatrix doctor ==="

  if [ "${BASH_VERSINFO[0]}" -gt 5 ] || { [ "${BASH_VERSINFO[0]}" -eq 5 ] && [ "${BASH_VERSINFO[1]}" -ge 1 ]; }; then
    printf 'bash        %s  PASS (>= 5.1)\n' "$BASH_VERSION"
  else
    printf 'bash        %s  FAIL (need >= 5.1)\n' "$BASH_VERSION"
  fi

  local t
  for t in jq tmux git node; do
    if command -v "$t" >/dev/null 2>&1; then printf 'tool        %-8s present\n' "$t"
    else printf 'tool        %-8s MISSING\n' "$t"; fi
  done

  if env -C / true 2>/dev/null; then echo 'probe       env -C        GNU (chdir supported)'
  else echo 'probe       env -C        BSD (fallback: bash -c cd wrapper)'; fi
  if stat -c %Y / >/dev/null 2>&1; then echo 'probe       stat          GNU (stat -c)'
  elif stat -f %m / >/dev/null 2>&1; then echo 'probe       stat          BSD (stat -f)'
  else echo 'probe       stat          UNKNOWN'; fi
  if sed --version >/dev/null 2>&1; then echo 'probe       sed           GNU'
  else echo 'probe       sed           BSD (config edit uses temp+mv, portable either way)'; fi
  if command -v sha256sum >/dev/null 2>&1; then echo 'probe       sha256        sha256sum'
  elif command -v shasum >/dev/null 2>&1; then echo 'probe       sha256        shasum -a 256'
  else echo 'probe       sha256        MISSING (swarm-loop checksum guard unavailable)'; fi
  if realpath -m / >/dev/null 2>&1; then echo 'probe       realpath -m   supported'
  else echo 'probe       realpath -m   absent (fallback path normalization)'; fi

  for t in claude codex gemini grok; do
    if command -v "$t" >/dev/null 2>&1; then printf 'lane        %-8s CLI on PATH\n' "$t"
    else printf 'lane        %-8s CLI missing\n' "$t"; fi
  done
  echo 'lane        glm      uses the claude CLI (Z.ai child-env swap) — OK if claude is present'
  echo 'lane        kimi     uses the claude CLI (Moonshot child-env swap) — OK if claude is present'

  local envf="${ENV_MASTER_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/unimatrix/env.master}"
  if [[ -r "$envf" ]]; then echo "env-master  readable: $envf"
  else echo "env-master  NOT readable: $envf (set \$ENV_MASTER_FILE; lanes needing keys will fail)"; fi

  local busref="$BUSDIR"; [[ -d "$busref" ]] || busref="$(dirname "$BUSDIR")"
  local fstype=""
  fstype="$(stat -f -c %T "$busref" 2>/dev/null || true)"
  [[ -n "$fstype" ]] || fstype="$(df -PT "$busref" 2>/dev/null | awk 'NR==2{print $2}' || true)"
  [[ -n "$fstype" ]] || fstype="unknown"
  case "$fstype" in
    9p|v9fs|drvfs|nfs|nfs4|cifs|smbfs)
      echo "bus fs      $fstype — WARNING: not a local POSIX fs; O_APPEND/flock/inotify can break the bus. Point \$BUSDIR at a local disk." ;;
    *)
      echo "bus fs      $fstype ($busref)" ;;
  esac

  # P0-FR2: account skill copies must be symlinks to the one canonical repo file (md5-uniq + link
  # target both checked in the lib helper — a hand-copy that happens to match still FAILs).
  # `|| true` is the contract above, not politeness: the helper returns 1 on FAIL, and under
  # `set -e` that aborted cmd_doctor mid-report — and with it cmd_doctor_live, which opens by
  # calling cmd_doctor, so a single drifted skill copy meant no auth probe ever ran.
  doctor_skill_drift "$SCRIPT_DIR" || true
  return 0
}

# _ms_now — epoch milliseconds for probe latency. GNU `date +%s%N` gives nanoseconds; BSD/macOS
# date has no %N (echoes the literal "N"), so this falls back to second-granularity (still a valid,
# if coarser, "PASS <ms>" figure) rather than erroring — same GNU-first/BSD-fallback posture as
# every other doctor probe above.
_ms_now() {
  local n; n="$(date +%s%N 2>/dev/null)"
  if [[ "$n" =~ ^[0-9]+$ ]]; then
    echo $(( n / 1000000 ))
  else
    echo $(( $(date +%s) * 1000 ))
  fi
}

# _doctor_ledger_row <lane> <billed> — spec 13 FR-2: no-silent-spend for doctor --live probes
# (model-lanes.md). doctor has no busdir-scoped run to derive a ledger path from the way ledger_row
# does (that's ${LEDGER_FILE:-$(dirname busdir)/docs/ops/llm-runs.md}) — this uses the repo-relative
# default ($SCRIPT_DIR/docs/ops/llm-runs.md) instead, but keeps the SAME never-scaffold doctrine as
# _speedwars_file: an explicit $LEDGER_FILE override always earns the write (a test/operator asked
# for it), the unset default only writes when docs/ops already exists — a doctor probe run from a
# throwaway checkout must never conjure a docs/ops tree that wasn't there before.
_doctor_ledger_row() {
  local lane="$1" billed="$2" file
  if [[ -n "${LEDGER_FILE:-}" ]]; then
    file="$LEDGER_FILE"
  else
    file="$SCRIPT_DIR/docs/ops/llm-runs.md"
    [[ -d "$(dirname "$file")" ]] || return 0
  fi
  _ledger_append_row "$file" "$(date +%F)" "doctor-probe ($lane)" "$lane" "$billed"
}

# _doctor_probe_model <lane> — the model this run would actually USE for <lane>: the first
# `<lane>:<model>` token in the resolved chains, else the same pinned default the verify wave uses
# (_verify_default_model). A hardcoded probe model is worse than no probe — it reports PASS/FAIL for
# a model nothing in this config ever spawns (glm-4.6 vs the configured glm-5.2/glm-4.7).
# <LANE>_PROBE_MODEL still overrides, for probing a model deliberately not in the chain.
_doctor_probe_model() {
  local lane="$1" tok
  for tok in ${EXEC_CHAIN:-} ${REVIEW:-} ${REVIEW_CHAIN:-}; do
    [[ "${tok%%:*}" == "$lane" && "$tok" == *:* ]] || continue
    [[ "${tok#*:}" == default ]] && continue
    printf '%s' "${tok#*:}"; return 0
  done
  _verify_default_model "$lane"
}

# _doctor_probe_lane <lane> — spec 13 FR-2: one minimal authenticated request, 10s timeout (codex:
# 30s — cold start alone regularly exceeds 10s), printed
# as "PASS <ms>ms" or "FAIL <reason>" on stdout (rc mirrors PASS/FAIL so the caller can tally
# failures without re-parsing its own output). glm/kimi/gemini go over curl against their real
# REST endpoints (never a CLI spawn — this file's own `curl` call is the ONLY thing bats needs to
# fake to keep this network-free in tests, mirroring how tests/swarm-run.bats already fakes
# claude/codex/gemini/grok on PATH). claude/codex/grok have no bare-key REST probe worth
# special-casing (OAuth-file lanes) — reuse the real lane CLI with a 1-word prompt under the same
# cap (10s; codex 30s), in an isolated _scratch_home cage (never the real $HOME) so a probe never
# pollutes a real session's local state.
_doctor_probe_lane() {
  local lane="$1" t0 t1 ms status="FAIL" reason="unknown" note=""
  t0="$(_ms_now)"
  case "$lane" in
    glm | kimi)
      local envkey base model key
      if [[ "$lane" == glm ]]; then
        envkey=Z_AI_CODING_KEY; base=https://api.z.ai/api/anthropic
        model="${GLM_PROBE_MODEL:-$(_doctor_probe_model glm)}"
      else
        envkey=MOONSHOT_API_KEY; base=https://api.moonshot.ai/anthropic
        model="${KIMI_PROBE_MODEL:-$(_doctor_probe_model kimi)}"
      fi
      if ! key="$(_env_master_key "$envkey" 2>/dev/null)"; then
        reason="no $envkey in env-master"
      else
        local bodyfile http crc=0
        bodyfile="$(mktemp)"
        # Headers over STDIN (`-H @-`), never argv: a key in `curl`'s command line is readable via
        # ps / /proc/<pid>/cmdline by any same-uid process. specs/01 FR-16 already amended the
        # gemini docker lane away from exactly this (`-e NAME=value` -> bare `-e NAME`); the probe
        # path must not reintroduce it.
        http="$(printf 'x-api-key: %s\nanthropic-version: 2023-06-01\ncontent-type: application/json\n' "$key" \
          | curl -sS -m 10 -o "$bodyfile" -w '%{http_code}' -X POST "$base/v1/messages" -H @- \
          -d "$(jq -nc --arg m "$model" '{model:$m,max_tokens:1,messages:[{role:"user",content:"hi"}]}')" \
          2>/dev/null)" || crc=$?
        rm -f "$bodyfile"
        if (( crc != 0 )); then reason="curl rc $crc"
        elif [[ "$http" == 2* ]]; then status=PASS
        else reason="HTTP $http"; fi
      fi
      ;;
    gemini)
      local gkey
      if ! gkey="$(_env_master_key GEMINI_API_KEY 2>/dev/null)"; then
        reason="no GEMINI_API_KEY in env-master"
      else
        local http crc=0 gmodel
        gmodel="${GEMINI_PROBE_MODEL:-$(_doctor_probe_model gemini)}"
        # Same stdin-header rule as glm/kimi, and the x-goog-api-key HEADER instead of the `?key=`
        # query parameter — a key in a URL also lands in proxy/access logs and shell history.
        http="$(printf 'x-goog-api-key: %s\ncontent-type: application/json\n' "$gkey" \
          | curl -sS -m 10 -o /dev/null -w '%{http_code}' -H @- \
          "https://generativelanguage.googleapis.com/v1beta/models/$gmodel:generateContent" \
          -d '{"contents":[{"parts":[{"text":"hi"}]}],"generationConfig":{"maxOutputTokens":1}}' \
          2>/dev/null)" || crc=$?
        if (( crc != 0 )); then reason="curl rc $crc"
        elif [[ "$http" == 2* ]]; then status=PASS
        elif [[ "$http" == 404 ]]; then
          # 404 here almost always means the resolved model name is a CLI-side ALIAS the REST API
          # doesn't know (live drill 2026-07-25: default gemini-3-flash is a gemini-CLI name; REST
          # only serves models/gemini-2.5-* ids). That's a model-naming mismatch, not a lane-health
          # signal — fall back to an auth-only models-list GET: 2xx proves the key works (PASS,
          # annotated), anything else is the real failure. Costs zero tokens.
          local http2 crc2=0
          http2="$(printf 'x-goog-api-key: %s\n' "$gkey" \
            | curl -sS -m 10 -o /dev/null -w '%{http_code}' -H @- \
            "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1" 2>/dev/null)" || crc2=$?
          if (( crc2 == 0 )) && [[ "$http2" == 2* ]]; then
            status=PASS; note="auth ok; model '$gmodel' is a CLI alias unknown to REST"
          else
            reason="HTTP $http (model probe), HTTP ${http2:-curl-rc-$crc2} (auth probe)"
          fi
        else reason="HTTP $http"; fi
      fi
      ;;
    claude | codex | grok)
      if ! command -v "$lane" >/dev/null 2>&1; then
        reason="$lane CLI not on PATH"
      else
        local home rc=0 cage
        # The probe cage lives in a TEMP dir, never under $BUSDIR: _scratch_home copies real OAuth
        # credential files into it, nothing here cleaned them up afterwards (contrast
        # _finalize_worker, which rm -rf's the per-worker cage for exactly that reason), and
        # `mkdir -p $BUSDIR/home/<lane>` also CREATED $BUSDIR — silently satisfying cmd_doctor_live's
        # own "only flag .broken when a bus already existed" guard. RETURN trap = one cleanup for
        # every exit path out of this function.
        cage="$(mktemp -d)"
        trap 'rm -rf "$cage"' RETURN
        home="$(_scratch_home "$cage" "$lane")"
        case "$lane" in
          claude)
            env -i "PATH=$PATH" "HOME=$home" LANG=C.UTF-8 timeout 10 \
              claude -p --output-format stream-json --verbose "hi" >/dev/null 2>&1 || rc=$?
            ;;
          codex)
            # 30s, not the 10s the other lanes get: codex exec's cold start alone regularly
            # exceeds 10s (measured live 2026-07-25 — a healthy authed lane FAILed "timeout (10s)").
            env -i "PATH=$PATH" "HOME=$home" LANG=C.UTF-8 timeout 30 \
              codex exec --json -s read-only --skip-git-repo-check -C "$SCRIPT_DIR" --ephemeral "hi" \
              >/dev/null 2>&1 || rc=$?
            ;;
          grok)
            env -i "PATH=$PATH" "HOME=$home" LANG=C.UTF-8 timeout 10 \
              grok -p "hi" --output-format streaming-json --no-auto-update \
              --tools read_file,grep,list_dir --no-subagents >/dev/null 2>&1 || rc=$?
            ;;
        esac
        # grok's OAuth refresh is SINGLE-USE: the moment the caged CLI refreshes, the master copy
        # under ~/.grok is stale and every later spawn anywhere dies "Not signed in". A probe
        # refreshes exactly like a worker spawn does, so it owes the same write-back — on FAIL too
        # (the token may have rotated before whatever made the probe fail).
        [[ "$lane" == grok ]] && _grok_token_sync "$home"
        local cap=10; [[ "$lane" == codex ]] && cap=30
        if (( rc == 124 )); then reason="timeout (${cap}s)"
        elif (( rc != 0 )); then reason="exit $rc"
        else status=PASS; fi
      fi
      ;;
    *) reason="unknown lane '$lane'" ;;
  esac
  t1="$(_ms_now)"
  ms=$(( t1 - t0 ))
  if [[ "$status" == PASS ]]; then
    printf 'PASS %sms%s\n' "$ms" "${note:+ ($note)}"
    return 0
  fi
  printf 'FAIL %s\n' "$reason"
  return 1
}

# doctor --live — spec 13 FR-2 (backlog 35): plain `doctor` (unchanged, always exits 0, zero
# network calls) followed by one minimal authenticated probe per lane. Exits nonzero iff any probe
# FAILs (plain doctor stays always-0). Every probed lane gets one ledger row (no-silent-spend); a
# FAILed probe also writes limits/<lane>.broken (spec 13 FR-3) WHEN a busdir already exists, so a
# launch immediately following the probe routes around the lane without spawning it.
cmd_doctor_live() {
  cmd_doctor
  # conf_load so the probes hit the model this config would actually spawn (_doctor_probe_model),
  # not a hardcoded one — and so EXEC_CHAIN/REVIEW are defined at all under `set -u`.
  conf_load "$CONF"
  echo "=== unimatrix doctor --live (auth probes) ==="
  # Captured BEFORE the probe loop: the guard means "don't scaffold lane-health state into a bus
  # that doesn't exist", and a probe must not be able to satisfy it by creating one itself.
  local bus_existed=0
  [[ -d "$BUSDIR" ]] && bus_existed=1
  local lane result rc overall=0
  for lane in claude codex gemini grok glm kimi; do
    rc=0
    result="$(_doctor_probe_lane "$lane")" || rc=$?
    printf 'probe       %-8s %s\n' "$lane" "$result"
    if (( rc == 0 )); then
      _doctor_ledger_row "$lane" "doctor probe (1-token, $result)"
    else
      overall=1
      _doctor_ledger_row "$lane" "doctor probe FAILED — $result"
      (( bus_existed )) && broken_flag "$BUSDIR" "$lane"
    fi
  done
  return "$overall"
}

# --- spec 17 FR-5: `doctor --plugin` -------------------------------------------------------------
# Flag-gated section beside cmd_doctor/cmd_doctor_live above: manifest parses, marketplace
# resolves, UNIMATRIX_HOME resolves, an install-drift table (one row per account), and the skill's
# version-stamp check. Zero spend — no probes, no network, purely static file reads — so it never
# touches the ledger/broken-flag machinery cmd_doctor_live owns. Never fatal: cmd_doctor_plugin
# itself always returns 0 (same discipline as doctor_skill_drift's `|| true` callers, applied here
# by not needing a caller to guard it at all), and every internal check that can legitimately fail
# on a stale/foreign file is defended against `set -e`/pipefail (`|| true` on the risky pipes).

# _plugin_version_banner_line — compares plugin.json's stamped version against the newest
# `## [x.y.z]` CHANGELOG heading (PRD §9 resolution 1: the changelog heading IS version truth;
# plugin.json is what FR-1/FR-2's generator stamps FROM it). Silent, returns 0, when they match or
# either side is unreadable (no false alarm on a not-yet-cut release); prints exactly one line to
# stderr and returns 1 on a genuine mismatch. Cheap (two file reads, no spawn) — safe to call every
# run. NOT YET wired into _print_banner's own call sites (outside this section's file-scope for
# this wave — see specs/17-plugin.md Resolutions for the follow-up).
_plugin_version_banner_line() {
  # Manifest lives under plugin/ (spec 17 open-question-1 resolution: marketplace sources ./plugin).
  local pj="$SCRIPT_DIR/plugin/.claude-plugin/plugin.json" cl="$SCRIPT_DIR/CHANGELOG.md"
  local pv rv
  pv="$(jq -r '.version // empty' "$pj" 2>/dev/null || true)"
  rv="$(grep -m1 -oE '^## \[[0-9]+\.[0-9]+\.[0-9]+\]' "$cl" 2>/dev/null \
        | sed -E 's/^## \[(.*)\]$/\1/' || true)"
  [[ -n "$pv" && -n "$rv" ]] || return 0
  [[ "$pv" == "$rv" ]] && return 0
  echo "unimatrix: WARNING: plugin.json version ($pv) differs from repo version ($rv) — rerun plugin/gen-commands.sh and re-stamp" >&2
  return 1
}

# _plugin_json_path <marketplace_root> — resolves marketplace.json's OWN declared plugin source
# (`plugins[0].source`, e.g. "." or "./plugin") into an absolute plugin.json path. Never hardcode
# where plugin.json lives relative to the marketplace root: specs/17-plugin.md's own open question
# 1 (source "." vs a "./plugin" subdirectory) is still being settled elsewhere in this same wave —
# reading it live from marketplace.json is what keeps this check correct regardless of which
# resolution lands. Falls back to the marketplace root itself when marketplace.json is missing,
# unreadable, or declares no source (self-marketplace default).
_plugin_json_path() {
  local root="$1"
  local mj="$root/.claude-plugin/marketplace.json" src
  src="$(jq -r '.plugins[0].source // empty' "$mj" 2>/dev/null || true)"
  src="${src#./}"
  if [[ -z "$src" || "$src" == "." ]]; then
    printf '%s/.claude-plugin/plugin.json\n' "$root"
  else
    printf '%s/%s/.claude-plugin/plugin.json\n' "$root" "$src"
  fi
}

# _doctor_plugin_manifest <file> <jq-filter> <label> — one PASS/FAIL line for a manifest file;
# shared by plugin.json and marketplace.json below, which need different required-key filters.
_doctor_plugin_manifest() {
  local file="$1" filter="$2" label="$3"
  if [[ -f "$file" ]] && jq -e "$filter" "$file" >/dev/null 2>&1; then
    printf 'manifest    %s PASS (%s)\n' "$label" "$file"
    return 0
  fi
  printf 'manifest    %s FAIL (%s missing or does not parse / missing required keys)\n' "$label" "$file"
  return 1
}

# _doctor_plugin_row <account> <installed_file> <repo_file> <surface> — one install-drift table
# row. A missing installed_file is SKIP (the account hasn't picked up the plugin/skill at all yet),
# never a false FAIL — only a content mismatch against an artifact that DOES exist is drift.
_doctor_plugin_row() {
  local account="$1" installed_file="$2" repo_file="$3" surface="$4"
  local ih rh verdict
  if [[ ! -e "$installed_file" && ! -L "$installed_file" ]]; then
    printf '%-14s %-10s %-10s %-6s (%s not installed)\n' "$account" "-" "-" "SKIP" "$surface"
    return 0
  fi
  ih="$(_hash_file "$installed_file")"
  rh="$(_hash_file "$repo_file")"
  if [[ -n "$ih" && "$ih" == "$rh" ]]; then verdict="PASS"; else verdict="FAIL"; fi
  printf '%-14s %-10s %-10s %-6s (%s)\n' "$account" "${ih:-none}" "${rh:-none}" "$verdict" "$surface"
  [[ "$verdict" == PASS ]]
}

# cmd_doctor_plugin — spec 17 FR-5 (plan-004 P1-FR5): manifest parses, marketplace resolves,
# UNIMATRIX_HOME resolves, the plugin-cache drift table, the install-drift table, and the skill
# frontmatter version-stamp check. Always exits 0 — this is a read-only report, same contract as
# plain `doctor`.
cmd_doctor_plugin() {
  echo "=== unimatrix doctor --plugin ==="
  local overall=0

  local mj="$SCRIPT_DIR/.claude-plugin/marketplace.json" pj
  pj="$(_plugin_json_path "$SCRIPT_DIR")"
  _doctor_plugin_manifest "$pj" '.name and .version' "plugin.json     " || true
  _doctor_plugin_manifest "$mj" '.name and .plugins' "marketplace.json" || true

  if [[ -f "$mj" && -f "$pj" ]]; then
    echo "marketplace resolves        PASS (directory-sourced, plugin at $(dirname "$pj"))"
  else
    echo "marketplace resolves        FAIL (no plugin.json resolves from $mj)"
  fi

  echo "UNIMATRIX_HOME resolves     PASS ($SCRIPT_DIR)"
  if [[ -n "${UNIMATRIX_HOME:-}" && "$UNIMATRIX_HOME" != "$SCRIPT_DIR" ]]; then
    echo "UNIMATRIX_HOME resolves     NOTE: \$UNIMATRIX_HOME env ($UNIMATRIX_HOME) differs from this checkout — this run used $SCRIPT_DIR"
  fi

  local skill="$SCRIPT_DIR/.claude/skills/unimatrix/SKILL.md" repo_version skill_version
  repo_version="$(jq -r '.version // empty' "$pj" 2>/dev/null || true)"
  skill_version="$(sed -n '/^---$/,/^---$/{/^version:/p}' "$skill" 2>/dev/null \
                    | head -1 | sed -E 's/^version:[[:space:]]*//' || true)"
  if [[ -n "$skill_version" && "$skill_version" == "$repo_version" ]]; then
    echo "skill-version               PASS (SKILL.md version=$skill_version)"
  else
    echo "skill-version               FAIL (SKILL.md version='${skill_version:-none}', plugin.json version='${repo_version:-none}')"
  fi

  _plugin_version_banner_line || true

  # --- plugin-cache drift (cross-review finding) --------------------------------------------
  # The install-drift table below hashes the MARKETPLACE SOURCE (a directory-sourced marketplace
  # can point straight at this checkout) against this same checkout — when it does, that row is a
  # self-comparison, always PASS, and says nothing about what Claude Code actually SERVES. What it
  # serves is the version-keyed COPY under ~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/
  # (specs/17-plugin.md's "residual risk" note: install/enable copies the source there, and
  # whether that copy stays live or goes stale on a later edit was never confirmed on this box).
  # Hash that copy's plugin.json + every plugin/commands/*.md against the repo instead — the one
  # comparison that can actually catch a stale-cache drift. No cache found at all is informational
  # (the plugin may simply never have been enabled anywhere on this box), never a failure.
  echo "--- plugin-cache ---"
  local mkt_name plugin_name cache_root="" cache_dirs=() cdir
  mkt_name="$(jq -r '.name // empty' "$mj" 2>/dev/null || true)"
  plugin_name="$(jq -r '.name // empty' "$pj" 2>/dev/null || true)"
  if [[ -n "$mkt_name" && -n "$plugin_name" ]]; then
    cache_root="$HOME/.claude/plugins/cache/$mkt_name/$plugin_name"
    for cdir in "$cache_root"/*/; do
      [[ -d "$cdir" ]] && cache_dirs+=("${cdir%/}")
    done
  fi

  if (( ${#cache_dirs[@]} == 0 )); then
    echo "cache        -          -          INFO   (no cached copy found${cache_root:+ at $cache_root} — plugin not enabled anywhere on this box yet)"
  else
    local cver cf cbase cmd_verdict
    for cdir in "${cache_dirs[@]}"; do
      cver="$(basename "$cdir")"
      _doctor_plugin_row "cache:$cver" "$cdir/.claude-plugin/plugin.json" "$pj" "plugin.json (cache)" || overall=1

      cmd_verdict="PASS"
      for cf in "$SCRIPT_DIR/plugin/commands/"*.md; do
        [[ -f "$cf" ]] || continue
        cbase="$(basename "$cf")"
        [[ "$(_hash_file "$cdir/commands/$cbase")" == "$(_hash_file "$cf")" ]] || cmd_verdict="FAIL"
      done
      printf '%-14s %-10s %-10s %-6s (%s)\n' "cache:$cver" "-" "-" "$cmd_verdict" "commands (cache)"
      [[ "$cmd_verdict" == PASS ]] || overall=1
    done
  fi

  echo "--- install-drift ---"
  printf '%-14s %-10s %-10s %-6s\n' "account" "installed" "repo" "verdict"

  local roots=() root name
  [[ -d "$HOME/.claude" ]] && roots+=("$HOME/.claude")
  for root in "$HOME"/.claude-acct/*/; do
    [[ -d "$root" ]] && roots+=("${root%/}")
  done

  if (( ${#roots[@]} == 0 )); then
    echo "(no accounts found under \$HOME/.claude or \$HOME/.claude-acct)"
  fi

  for root in "${roots[@]}"; do
    if [[ "$root" == "$HOME/.claude" ]]; then name="default"; else name="$(basename "$root")"; fi

    local mkt_path=""
    if [[ -f "$root/settings.json" ]]; then
      mkt_path="$(jq -r '.extraKnownMarketplaces.unimatrix.source.path // empty' "$root/settings.json" 2>/dev/null || true)"
    fi

    if [[ -n "$mkt_path" ]]; then
      _doctor_plugin_row "$name" "$(_plugin_json_path "$mkt_path")" "$pj" "plugin" || overall=1
    else
      _doctor_plugin_row "$name" "$root/skills/unimatrix/SKILL.md" "$skill" "skill" || overall=1
    fi
  done

  if (( overall )); then
    echo "install-drift: RED — at least one account differs from the repo (see FAIL rows above)"
  else
    echo "install-drift: GREEN — every installed account matches the repo"
  fi

  return 0
}

# --- spec 15: the `call` verb — one-shot lane invocation over the existing engine ---------------

# _call_refuse <reason> — spec 15 FR-1: every bad `call` invocation is a PARSE-TIME usage error
# (reason + usage on stderr, nonzero rc) that has staged nothing. usage() exits, so this never
# returns — which is exactly why it must NEVER be invoked from inside a command substitution:
# there the exit would only kill the subshell and the caller would sail on with an empty value.
_call_refuse() {
  echo "swarm-run: call — $1" >&2
  usage
}

# _call_lane_ok <bare-lane> — spec 15 FR-2: the six spawnable lanes. `fable` is plan/orchestrator
# only (lane_cmd refuses to spawn it), so it is deliberately not callable here either.
_call_lane_ok() {
  case "$1" in claude | codex | gemini | glm | grok | kimi) return 0 ;; *) return 1 ;; esac
}

# _call_lane_token <lane[:model]> — spec 15 FR-2: normalize one token to lane:model. An explicit
# lane:model passes through verbatim; a bare lane resolves via _verify_default_model (the ONE
# resolution table — codex/grok resolve to "default", which lane_cmd reads as "omit -m"). The
# caller validates the lane first (_call_lane_ok); see _call_refuse's subshell caveat.
_call_lane_token() {
  local spec="$1"
  if [[ "$spec" == *:* ]]; then
    printf '%s' "$spec"
  else
    printf '%s:%s' "$spec" "$(_verify_default_model "$spec")"
  fi
}

# _call_files_report [write-root] — spec 15 FR-10: after full_run returns, one stderr line per
# chunk manifest ("<cid>: N/M files touched", N = manifest paths whose mtime beats
# $BUSDIR/call.stamp), then a run total and the caveat. A RELATIVE manifest path is resolved
# against the --write root — the worker is chdir'd there (FR-15 cage geometry), so that is the only
# anchoring under which the report sees the same file the worker touched; an absolute path passes
# through. Report-only by construction: never requeues, never re-spawns, never touches the run's
# rc. No manifests (a non-bulk call) -> no output at all.
_call_files_report() {
  local root="${1:-}" f cid p abs n m total_n=0 total_m=0 any=0
  for f in "$BUSDIR"/chunks/*.files; do
    [[ -e "$f" ]] || continue
    any=1
    cid="$(basename "$f" .files)"
    n=0; m=0
    while IFS= read -r p; do
      [[ -n "$p" ]] || continue
      m=$(( m + 1 ))
      if [[ "$p" == /* || -z "$root" ]]; then abs="$p"; else abs="$root/$p"; fi
      if [[ "$abs" -nt "$BUSDIR/call.stamp" ]]; then n=$(( n + 1 )); fi
    done < "$f"
    echo "$cid: $n/$m files touched" >&2
    total_n=$(( total_n + n )); total_m=$(( total_m + m ))
  done
  if (( any )); then
    echo "swarm-run: call — $total_n/$total_m files touched across the run" >&2
    echo "swarm-run: call — caveat: an already-conformant file is legitimately untouched, so N < M is a prompt to look, not proof of failure" >&2
  fi
  return 0
}

# _call_ledger_aggregate <rc> <lane-or-chain> <cards> <files> — spec 15 FR-11: exactly ONE
# aggregate row per `call` run in the GLOBAL ledger (never one per card — per-card ledger_row
# writes stay bus-local via LEDGER_FILE). Cost is re-summed from this run's own speedwars rows
# (never a pre-run estimate); "n/a" when there is no speedwars surface to sum. The row ALWAYS
# prints to stderr so the spend is loud even when the gitignored global ledger is absent, and is
# appended to the checkout's docs/ops/llm-runs.md only IFF that file already exists — the same
# never-scaffold posture as ledger_row. One printf = one write(2) (bus-discipline.md).
_call_ledger_aggregate() {
  local rc="$1" lanes="$2" cards="$3" nfiles="$4"
  # _run_label (src/swarm-lib.sh), not a bare ${SPEEDWARS_RUN:-}: the join key must be the SAME one
  # speed_row stamped on the rows being summed. An empty key would make the jq filter match nothing
  # and land a real-looking $0 in the spend ledger — so an unresolvable label prints "n/a" and the
  # sum is not attempted at all.
  local run; run="$(_run_label "$BUSDIR")"
  local cost="n/a" swfile
  if [[ -n "$run" ]] && swfile="$(_speedwars_file "$BUSDIR" 2>/dev/null)" && [[ -f "$swfile" ]]; then
    cost="$(jq -rs --arg run "$run" \
      '[.[] | select(.type == null and .run == $run) | .cost_usd // 0] | add // 0' \
      "$swfile" 2>/dev/null)" || cost="n/a"
    [[ -n "$cost" ]] || cost="n/a"
  fi
  local row
  row="| $(date +%F) | swarm-run call ${run:-n/a} | $lanes | $cards card(s), $nfiles file(s), rc $rc | $cost |"
  echo "swarm-run: call — ledger: $row" >&2
  local global="$SCRIPT_DIR/docs/ops/llm-runs.md"
  [[ -f "$global" ]] && printf '%s\n' "$row" >> "$global"
  return 0
}

# cmd_call <lane[:model]> '<prompt>'|@<promptfile> [--write <dir>] [--files <listfile> --batch <N>]
#          [--chain '<lane[:model]> ...'] [--id <label>]
# spec 15 FR-1: the direct-call front door. It is a front door, not an engine — it validates
# everything FIRST (so a bad invocation stages nothing), writes ordinary cards + sidecars into
# $BUSDIR/specs/, then invokes the UNMODIFIED full_run, so harness, cockpit, gate math and evidence
# are identical to any other run and `call` inherits future engine changes for free.
# FR-1 busdir: an env BUSDIR wins; otherwise .bus-call-<label> resolved against the CALLER's cwd
#   (not SCRIPT_DIR — a direct call may be issued from any repo, and its bus belongs where the
#   operator stands); refused if that bus already holds a non-empty queue/ or done/.
# FR-3 pin-by-default (.lane) vs --chain (.chain); the two never coexist on one card.
# FR-4 --write sidecar, gemini refused at parse. FR-5 bulk shard + chunks/ manifest + call.stamp.
# FR-6 ID_RE + collision refusal. FR-7 pre-existing specs/ cards warn-and-proceed. FR-8 oversized
# prompt warning. FR-9 write calls default WORKER_TIMEOUT_SEC=1200. FR-10/FR-11 run AFTER full_run
# and never change its rc.
cmd_call() {
  [[ $# -ge 2 ]] || usage
  local lanespec="$1" prompt_arg="$2"
  shift 2

  local write_dir="" files_list="" batch="" chain_spec="" id_opt=""
  while (( $# )); do
    case "$1" in
      --write) [[ $# -ge 2 && -n "$2" ]] || _call_refuse "--write needs a directory"; write_dir="$2"; shift 2 ;;
      --files) [[ $# -ge 2 && -n "$2" ]] || _call_refuse "--files needs a list file";  files_list="$2"; shift 2 ;;
      --batch) [[ $# -ge 2 && -n "$2" ]] || _call_refuse "--batch needs a count";      batch="$2";      shift 2 ;;
      --chain) [[ $# -ge 2 && -n "$2" ]] || _call_refuse "--chain needs at least one lane"; chain_spec="$2"; shift 2 ;;
      --id)    [[ $# -ge 2 && -n "$2" ]] || _call_refuse "--id needs a label";          id_opt="$2";     shift 2 ;;
      *) _call_refuse "unknown option '$1'" ;;
    esac
  done

  # --- validation: everything below refuses BEFORE a single file is staged (FR-1) ---------------
  # FR-2: the model half of every token is embedded verbatim in the claim FILENAME
  # (claimed/<id>.<lane>:<model>) — a slash, whitespace or empty model would corrupt bus state at
  # claim time, long after parse. Same charset the cockpit's CLAIM_RE accepts.
  local model_re='^[a-z]+:[A-Za-z0-9._-]+$'
  local bare="${lanespec%%:*}"
  _call_lane_ok "$bare" || _call_refuse "unknown lane '$bare' (claude|codex|gemini|glm|grok|kimi)"
  local primary; primary="$(_call_lane_token "$lanespec")"
  [[ "$primary" =~ $model_re ]] || _call_refuse "model in '$lanespec' must match [A-Za-z0-9._-]+"

  # FR-4: gemini is not write-capable — refuse at parse rather than fan out cards that can only park.
  [[ "$bare" == gemini && -n "$write_dir" ]] \
    && _call_refuse "gemini is not a write-capable lane — refusing --write"

  # FR-3: --chain replaces the hard pin. Primary prepended, bare fallback tokens normalized per
  # FR-2. read -ra (not bare word-splitting) so a token like 'codex:*' can never pathname-expand
  # into a filename from the caller's cwd.
  local chain_str="" tok tbare norm
  local -a chain_toks=()
  if [[ -n "$chain_spec" ]]; then
    read -ra chain_toks <<<"$chain_spec"
    chain_str="$primary"
    for tok in "${chain_toks[@]}"; do
      tbare="${tok%%:*}"
      _call_lane_ok "$tbare" || _call_refuse "unknown lane '$tbare' in --chain"
      norm="$(_call_lane_token "$tok")"
      [[ "$norm" =~ $model_re ]] || _call_refuse "model in --chain token '$tok' must match [A-Za-z0-9._-]+"
      chain_str="$chain_str $norm"
    done
  fi

  # FR-5: bulk mode is --files AND --batch — one without the other is a usage error.
  if [[ -n "$files_list" && -z "$batch" ]]; then
    _call_refuse "--files needs --batch <N> (size the batch so N x per-file-seconds stays under half WORKER_TIMEOUT_SEC)"
  fi
  if [[ -n "$batch" && -z "$files_list" ]]; then
    _call_refuse "--batch without --files does nothing — they are a pair"
  fi
  if [[ -n "$batch" ]] && ! [[ "$batch" =~ ^[1-9][0-9]*$ ]]; then
    _call_refuse "--batch must be a positive integer (got '$batch')"
  fi
  [[ -z "$files_list" || -r "$files_list" ]] || _call_refuse "--files list '$files_list' is unreadable"

  local write_abs=""
  if [[ -n "$write_dir" ]]; then
    write_abs="$(_abspath "$write_dir")"
    [[ -d "$write_abs" ]] || _call_refuse "--write target '$write_dir' is not an existing directory"
    # FR-4: the gemini refusal must hold for the WHOLE normalized chain, not just the primary — a
    # gemini fallback on a write card would only fail at spawn time, after real work began.
    [[ "$chain_str" =~ (^|[[:space:]])gemini: ]] \
      && _call_refuse "--chain contains gemini, which is not write-capable — refusing with --write"
  fi

  # A prompt starting with @ reads the rest as a file path (FR-1).
  local prompt
  if [[ "$prompt_arg" == @* ]]; then
    local pfile="${prompt_arg#@}"
    [[ -r "$pfile" ]] || _call_refuse "prompt file '$pfile' is unreadable"
    prompt="$(<"$pfile")"
  else
    prompt="$prompt_arg"
  fi

  # FR-6: ids come from --id, else call-$$; the label (busdir/run key) is the raw --id, else $$.
  local id_re='^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'
  local label="${id_opt:-$$}" id="${id_opt:-call-$$}"
  [[ "$id" =~ $id_re ]] || _call_refuse "id '$id' is not a valid card id ($id_re)"
  # The bulk suffix is part of the resulting id, so it must survive the same gate.
  if [[ -n "$files_list" ]]; then
    [[ "$id-001" =~ $id_re ]] || _call_refuse "id '$id' is too long once the bulk -NNN suffix is appended"
  fi

  # FR-1 busdir + FR-11 bus-local ledger + the run key every evidence row joins on.
  if [[ -z "$_BUSDIR_FROM_ENV" ]]; then
    BUSDIR="$(_abspath "$PWD/.bus-call-$label")"
  fi
  : "${SPEEDWARS_RUN:=call-$label}"
  : "${LEDGER_FILE:=$BUSDIR/llm-runs.md}"
  # BUSDIR is exported too: it was just REWRITTEN above, and the cockpit mon_web_ensure auto-starts
  # right after is a child process — on the systemd-less branch a bare `setsid nohup node` with no
  # argv to carry it, so inheritance is all it has. Unexported, /health vouched for the engine's
  # default .bus while the run used .bus-call-<label>.
  export BUSDIR SPEEDWARS_RUN LEDGER_FILE

  # FR-1: overlaying a live or finished run's bus is never what the operator meant.
  if [[ -d "$BUSDIR" ]]; then
    local hit pgid
    # A live POOL is the strongest signal — queue/ can be momentarily empty (all cards claimed)
    # while a run is very much in flight. Same pgid-liveness probe swarm-ctl abort relies on.
    if [[ -f "$BUSDIR/run.pgid" ]] && pgid="$(<"$BUSDIR/run.pgid")" \
       && kill -0 -- "-$pgid" 2>/dev/null; then
      _call_refuse "busdir '$BUSDIR' has a LIVE pool (run.pgid $pgid) — refusing to stage into a running bus"
    fi
    hit="$(find "$BUSDIR/queue" -maxdepth 1 -name '*.prompt' -print -quit 2>/dev/null || true)"
    [[ -z "$hit" ]] || _call_refuse "busdir '$BUSDIR' already has a live queue/ — refusing to overlay it"
    hit="$(find "$BUSDIR/done" -maxdepth 1 -type f -print -quit 2>/dev/null || true)"
    [[ -z "$hit" ]] || _call_refuse "busdir '$BUSDIR' already holds a finished run's done/ — refusing to overlay it"
  fi

  # FR-6: an id prefix with any footprint in the bus would collide with an in-flight/completed card.
  local d f
  for d in specs queue claimed "done"; do
    for f in "$BUSDIR/$d/$id"*; do
      [[ -e "$f" ]] || continue
      _call_refuse "id '$id' already has a footprint in $d/ ($(basename "$f")) — refusing to collide"
    done
  done

  # FR-7: pre-existing unenqueued cards are swept into THIS run by _enqueue_pending_specs — surface
  # it loudly rather than refusing (staging extra cards by hand, then calling, is legitimate).
  local pending=0
  for f in "$BUSDIR"/specs/*.prompt; do
    [[ -e "$f" ]] && pending=$(( pending + 1 ))
  done
  if (( pending )); then
    echo "swarm-run: call — WARNING: $pending pre-existing card(s) in $BUSDIR/specs/ will be swept into this run" >&2
  fi

  # FR-9: a write card does real edits and the FR-12 watchdog kills on wall clock — a 300s kill
  # mid-edit leaves a silent partial change. Env/conf always win (conf_load re-overlays env last).
  if [[ -n "$write_abs" && -z "${WORKER_TIMEOUT_SEC+x}" ]] \
     && ! grep -q '^WORKER_TIMEOUT_SEC=' "$CONF" 2>/dev/null; then
    export WORKER_TIMEOUT_SEC=1200
  fi

  # --- staging ---------------------------------------------------------------------------------
  bus_init "$BUSDIR"
  _run_label_persist "$BUSDIR"   # same run-start pin as full_run/verify_run
  local -a cids=()
  local files_n=0 cid
  if [[ -n "$files_list" ]]; then
    # FR-5: pure-bash sharding — coreutils split(1) numbers suffixes from 000 and its
    # --numeric-suffixes=1 is GNU-only, neither of which matches the spec'd <id>-001 ids.
    local -a raw=() paths=() chunk=()
    mapfile -t raw < "$files_list"
    local p
    for p in "${raw[@]}"; do
      [[ -n "$p" ]] || continue
      # FR-5: on a write call the file list is an EDIT instruction — fence it to the --write root.
      # Lexical check only (an absolute path must sit under the root; a relative one may not climb
      # with ..) — write-capable lanes have no filesystem fence of their own, so a stray
      # ../outside/file in a machine-generated list would otherwise become a real edit outside the
      # cage. Symlinks inside the root are NOT resolved (per-path realpath at 4000 paths is 4000
      # forks); that residual is documented in the spec's Known limits.
      if [[ -n "$write_abs" ]]; then
        case "$p" in
          /*) [[ "$p" == "$write_abs"/* ]] \
                || _call_refuse "--files path '$p' lies outside the --write root $write_abs" ;;
          *)  [[ "/$p/" != *"/../"* && "$p" != ../* ]] \
                || _call_refuse "--files path '$p' climbs with .. — refusing to escape the --write root" ;;
        esac
      fi
      paths+=("$p")
    done
    (( ${#paths[@]} )) || _call_refuse "--files list '$files_list' has no paths"
    files_n=${#paths[@]}
    mkdir -p "$BUSDIR/chunks"
    local i=0 seq=1
    while (( i < files_n )); do
      printf -v cid '%s-%03d' "$id" "$seq"
      chunk=("${paths[@]:i:batch}")
      # The manifest is EVIDENCE, not a sidecar: no claim/spawn/finalize/gate path reads chunks/,
      # only _call_files_report does.
      printf '%s\n' "${chunk[@]}" > "$BUSDIR/chunks/$cid.files"
      { printf '%s\n\nFILES (operate on exactly these, nothing else):\n' "$prompt"
        printf '%s\n' "${chunk[@]}"; } > "$BUSDIR/specs/$cid.prompt"
      cids+=("$cid")
      i=$(( i + batch )); seq=$(( seq + 1 ))
    done
  else
    printf '%s' "$prompt" > "$BUSDIR/specs/$id.prompt"
    cids=("$id")
  fi

  for cid in "${cids[@]}"; do
    # FR-3: pin and chain never coexist on one card.
    if [[ -n "$chain_str" ]]; then
      printf '%s' "$chain_str" > "$BUSDIR/specs/$cid.chain"
    else
      printf '%s' "$primary" > "$BUSDIR/specs/$cid.lane"
    fi
    if [[ -n "$write_abs" ]]; then
      printf '%s' "$write_abs" > "$BUSDIR/specs/$cid.write"
    fi
    # FR-8: MAX_ARG_STRLEN is 128 KB per argv element and every lane takes its prompt as ONE
    # argument. Warning only — the ceiling is the kernel's, and the operator may know their chunk
    # is fine.
    local psize; psize="$(wc -c < "$BUSDIR/specs/$cid.prompt")"
    if (( psize > 102400 )); then
      echo "swarm-run: call — WARNING: $cid prompt is ${psize} bytes (>100KB); the kernel's per-argv-element limit is 128KB" >&2
    fi
  done

  echo "swarm-run: call — staged ${#cids[@]} card(s) as ${chain_str:-$primary} in $BUSDIR" >&2
  # FR-5: one "everything after this is ours" mark for the FR-10 report, taken immediately before
  # full_run's enqueue so no staging write of ours can look like a worker's edit.
  touch "$BUSDIR/call.stamp"

  local rc=0
  full_run || rc=$?
  # FR-10/FR-11 are close-out EVIDENCE: both run even when the run failed, neither changes rc.
  _call_files_report "$write_abs"
  _call_ledger_aggregate "$rc" "${chain_str:-$primary}" "${#cids[@]}" "$files_n"
  return "$rc"
}

case "${1:-}" in
  --plan-only)
    [[ $# -ge 2 ]] || usage
    plan_only "$2"
    ;;
  config)
    shift
    cmd_config "$@"
    ;;
  verify)
    verify_run
    ;;
  doctor)
    case "${2:-}" in
      --live) cmd_doctor_live ;;
      --plugin) cmd_doctor_plugin ;;
      *) cmd_doctor ;;
    esac
    ;;
  call)
    shift
    cmd_call "$@"
    ;;
  *)
    full_run "${1:-}"
    ;;
esac
