#!/usr/bin/env bash
# /swarm-loop driver: init writes the criteria.md contract once; iterate runs exec->oracle->review
# for one increment and appends one state.jsonl line; run iterates until a stop rule fires.
#
# Project: unimatrix — multi-model swarm orchestrator driven from Claude Code
# Module:  swarm-loop.sh
# Deps:    src/swarm-lib.sh (conf_load/bus_init only), swarm-run.sh (invoked as a FANOUT=1
#          subprocess), swarm.conf, jq
# Tested:  tests/swarm-loop-*.bats (PATH-shimmed fake CLIs + a fake oracle — no real API calls)
#
# Key responsibilities:
# - criteria.md contract: written once at init, checksum-guarded on every iterate() so a worker
#   (or anything else) editing it mid-run is caught before adjudication, never silently trusted
# - FR-15/FR-8: init creates a scratch git worktree of TARGET_DIR (else runs directly against it
#   with a loud warning) — criteria.md's `target`/`base_sha` fields record it; every exec spec
#   gets a <id>.write sidecar pointing at it, so oracle/checkpoint/COMPLETE.md all operate on the
#   worktree, never the orchestrator's own tree
# - one iteration: exec spec on EXEC_CHAIN (write-capable, FR-15) -> oracle (deterministic) -> if
#   green, review seeded as a fallback CHAIN (spec 10 FR-R2: specs/<id>.chain, author-excluded via
#   review_chain_for, read-only) -> ONE state.jsonl append -> steering.md accrual on findings
# - stop-rule evaluation in `run`: goal, oscillation, plateau, max_iterations, budget, wall_clock,
#   human_abort — first to fire wins, exactly the table order in specs/03-swarm-loop.md
#   (oscillation is checked before plateau: the more specific A->B->A condition, else plateau's
#   broader "no progress" window shadows it at plateau <= 3)
# - spec 11 FR-S2 succession wiring: iterate touches .bus/heartbeat via swarm-ctl (the
#   ORCHESTRATOR-side liveness signal) and keeps it fresh through each pool wait (background
#   keepalive in _run_pool_once — one touch per iterate goes stale whenever a chain walk outlives
#   ORCH_TAKEOVER_MIN); the FR-S4 gate passing also reclaims a non-fable orch-seat back to fable
#   (closes the degraded window; re-arms takeover for a second crash). LOOP_WATCHDOG=1 makes `run`
#   arm the cron takeover watchdog at start and disarm it on every deliberate close (_halt,
#   _complete, and every _die); an attended `run` clears a crashed unattended run's leftover line
# - spec 13 FR-1: cmd_init aborts loudly (env_master_preflight, right after bus_init) before this
#   run's first iteration if the lane set needs an env-key lane and $ENV_MASTER_FILE is unreachable
#
# Design constraints:
# - Reuses swarm-run.sh/swarm-lib.sh by INVOCATION only — never edits either file
# - Judge != executor is enforced twice: at init and again at the top of every iterate()
#   (belt-and-braces against a config change mid-run). Spec 10 §Amendment: a collision
#   auto-SUBSTITUTES the first qualified CLASS_REVIEW member (loud stderr) and only refuses
#   when none qualifies — the iron rule itself has no exceptions,
#   rules/unimatrix/loop-discipline.md
# - criteria.md is a flat line-based format: `key: value` fields must be single-line (an oracle
#   command with an embedded newline will not roundtrip — chain with && instead, per the spec's
#   own examples) plus two bulleted sections (invariants, checklist)
# - BUSDIR/CONF/SWARM_RUN are overridable via env so tests never touch the real .bus/swarm.conf
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

# spec 20 FR-5: `--run <label>` before the subcommand — same one-token derivation as swarm-run.sh
# (BUSDIR=.bus-<label> + SPEEDWARS_RUN=<label>, explicit env still winning), so every iteration of
# a loop shares one bus and one ledger key atomically. The label is also passed through to each
# iteration's swarm-run.sh invocation (belt and braces — the env already pins both).
RUN_LABEL=""
while [[ "${1:-}" == --run ]]; do
  if [[ $# -lt 2 ]]; then echo "swarm-loop: --run needs a label" >&2; exit 1; fi
  RUN_LABEL="$2"; shift 2
done
if [[ -n "$RUN_LABEL" && ! "$RUN_LABEL" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "swarm-loop: invalid --run label '$RUN_LABEL' (allowed: A-Za-z0-9._-)" >&2
  exit 1
fi
if [[ -z "${BUSDIR:-}" && -n "$RUN_LABEL" ]]; then
  BUSDIR="${UNIMATRIX_BUS_ROOT:-$PWD}/.bus-$RUN_LABEL"
fi
if [[ -n "$RUN_LABEL" && -z "${SPEEDWARS_RUN:-}" ]]; then
  export SPEEDWARS_RUN="$RUN_LABEL"
fi
# realpath -m: same normalization as swarm-run.sh, same reason (FR-15's env -C write-target chdir
# would otherwise re-resolve a relative $BUSDIR against the worktree downstream).
# realpath -m is GNU-only; BSD/macOS realpath has no -m. Feature-detect and hand-normalize otherwise.
if realpath -m / >/dev/null 2>&1; then
  BUSDIR="$(realpath -m "${BUSDIR:-$SCRIPT_DIR/.bus}")"
else
  _b="${BUSDIR:-$SCRIPT_DIR/.bus}"
  case "$_b" in /*) BUSDIR="$_b";; *) BUSDIR="$PWD/$_b";; esac
fi
CONF="${CONF:-$SCRIPT_DIR/swarm.conf}"
SWARM_RUN="${SWARM_RUN:-$SCRIPT_DIR/swarm-run.sh}"
SWARM_CTL="${SWARM_CTL:-$SCRIPT_DIR/src/swarm-ctl}"

usage() {
  cat >&2 <<'EOF'
usage: swarm-loop.sh [--run <label>] init <run-id>      # scaffold criteria.md/steering.md/state.jsonl from env
       swarm-loop.sh [--run <label>] iterate <run-id>   # run exactly one iteration
       swarm-loop.sh [--run <label>] run <run-id>       # iterate until a stop rule fires

--run <label> (spec 20): derives BUSDIR=.bus-<label> + SPEEDWARS_RUN=<label>, and is passed through
to every iteration's swarm-run.sh invocation. Explicit env vars override the derivation.
EOF
  exit 1
}

# A deliberate die is a run close too (spec 11 "disarm on every deliberate close"): route through
# _watchdog_close (a no-op unless LOOP_WATCHDOG=1) so only genuine crashes — kill -9/OOM — leave
# the takeover cron line armed. Best-effort: a failed disarm must never mask the real error.
_die() { _watchdog_close 2>/dev/null || true; echo "swarm-loop: $*" >&2; exit 1; }

_loopdir() { echo "$BUSDIR/loop/$1"; }

_valid_run_id() { [[ "$1" =~ ^[a-z0-9][a-z0-9-]*$ ]]; }

_bare_lane() { echo "${1%%:*}"; }

# _judge_collides_exec <bare_lane> — rc 0 iff <bare_lane> equals the bare part of SOME EXEC_CHAIN
# entry. The judge-must-differ-from-every-exec-lane iron rule (loop-discipline.md): a fresh iteration
# starts on the chain head, but a limit/timeout failover moves exec onto a later lane mid-run
# (chain_advance), and a judge sharing that lane would grade its own output — the self-review
# loop-discipline.md forbids ("Always true, no exceptions"). Walking the WHOLE chain (checking only
# the head was the original gap). Split out of _resolve_judge so the configured judge and every
# substitute candidate clear the one identical check (the substitute is held to the same bar).
_judge_collides_exec() {
  local bare="$1" e
  local -a chain_arr
  read -ra chain_arr <<<"$EXEC_CHAIN"
  for e in "${chain_arr[@]}"; do
    [[ "$bare" == "${e%%:*}" ]] && return 0
  done
  return 1
}

# _judge_qualifies <bare_lane> <author_bare> — the two guards a candidate judge must clear (shared by
# _resolve_judge's configured-judge check and its substitute-loop, so both stay in lockstep): no
# EXEC_CHAIN collision (_judge_collides_exec) AND _judge_ok against the author.
_judge_qualifies() {
  local bare="$1" author="$2"
  _judge_collides_exec "$bare" && return 1
  _judge_ok "$bare" "$author"
}

# _resolve_judge <configured_judge> <author_bare_or_empty> — spec 10 §Amendment / FR-R2-init: the
# iron rule (judge != every exec lane) and the shared _judge_ok guard (vs the card author) still
# bind, but a judge that trips EITHER no longer _die's outright — it auto-substitutes the FIRST
# CLASS_REVIEW member that passes the SAME two checks, logging one loud stderr line (mirrors
# verify_lane_for's self-map fallback pattern). _die (naming CLASS_REVIEW) only when no member
# qualifies — never a silent demotion to a weaker/disqualified judge. <author_bare> is empty at
# BOTH call sites — init AND the top-of-iterate re-check both run BEFORE this iteration's exec
# card, so the author isn't known yet and only an EXEC_CHAIN collision can disqualify here;
# per-card author-collision is enforced downstream by review_chain_for at review-seed time (once
# done/<exec_id> exists). Echoes the resolved lane:model on stdout — the configured judge unchanged when it
# qualifies, else the substitute — so the caller bakes/uses the SUBSTITUTE downstream. Replaces the
# old _check_judge_ne_exec's unconditional die-on-collision at both call sites.
_resolve_judge() {
  local configured="$1" author="${2:-}"
  local judge_bare="${configured%%:*}"

  # Configured judge qualifies iff it clears BOTH the exec-chain collision rule and _judge_ok. The
  # predicate sits in an `if` condition, so a failing guard is the signal, never an errexit trip.
  if _judge_qualifies "$judge_bare" "$author"; then
    printf '%s' "$configured"
    return 0
  fi

  # Disqualified — substitute the first CLASS_REVIEW member that clears the identical two checks.
  local -a members
  local member sub=""
  read -ra members <<<"${CLASS_REVIEW:-}"
  for member in "${members[@]}"; do
    if _judge_qualifies "$member" "$author"; then
      sub="$member:$(_verify_default_model "$member")"
      break
    fi
  done

  if [[ -n "$sub" ]]; then
    echo "swarm-loop: judge '$configured' disqualified by exec-chain/author collision — substituting CLASS_REVIEW member '$sub'" >&2
    printf '%s' "$sub"
    return 0
  fi

  _die "no CLASS_REVIEW member qualifies as judge (every member collides with EXEC_CHAIN or the card author) — refusing to silently demote; fix CLASS_REVIEW/EXEC_CHAIN/REVIEW"
}

# _criteria_field <file> <key> — reads a top-level `key: value` line (empty if absent/no match).
_criteria_field() {
  local file="$1" key="$2" val
  val="$(grep -m1 "^${key}: " "$file" 2>/dev/null || true)"
  val="${val#*: }"
  printf '%s' "$val"
}

# _criteria_stop <file> <key> — reads a nested `  key: value` line under the `stops:` block.
_criteria_stop() {
  local file="$1" key="$2" val
  val="$(grep -m1 "^  ${key}: " "$file" 2>/dev/null || true)"
  val="${val#*: }"
  printf '%s' "$val"
}

# sha256sum is GNU/Linux coreutils; macOS/BSD ships `shasum -a 256` instead. Same hex digest either way.
_criteria_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# _verify_criteria_unchanged <loopdir> — the immutability guard (FR-4 / acceptance criteria #3).
_verify_criteria_unchanged() {
  local loopdir="$1" stored current
  stored="$(<"$loopdir/.criteria.sha256")"
  current="$(_criteria_sha256 "$loopdir/criteria.md")"
  [[ "$stored" == "$current" ]] \
    || _die "criteria.md checksum mismatch under $loopdir — refusing to continue (the contract must never change mid-run)"
}

_SIGNS=$'SEARCH THE CODEBASE BEFORE ASSUMING NOT IMPLEMENTED\nNO PLACEHOLDER/STUB IMPLEMENTATIONS\nDO NOT WEAKEN TESTS TO PASS'

# --- init ----------------------------------------------------------------------------------

cmd_init() {
  local run_id="$1"
  _valid_run_id "$run_id" || _die "run-id must match [a-z0-9][a-z0-9-]* (bus id contract is dot-free)"
  conf_load "$CONF"
  bus_init "$BUSDIR"
  # spec 13 FR-1: abort before the run's first iteration ever plans/spawns anything if this run's
  # lane set needs an env-key lane and $ENV_MASTER_FILE is unreachable — env_master_preflight
  # prints its own loud path+fix message; _die adds the loop-specific halt framing.
  env_master_preflight "$BUSDIR" || _die "env-master preflight failed (see above) — aborting before first iteration"
  { mon_web_ensure && mon_web_open; } || true

  local loopdir; loopdir="$(_loopdir "$run_id")"
  [[ -e "$loopdir/criteria.md" ]] \
    && _die "run '$run_id' already initialized ($loopdir/criteria.md exists) — refusing to re-init"

  [[ -n "${LOOP_GOAL:-}" ]] || _die "LOOP_GOAL is required"
  local tier="${LOOP_TIER:-1}"
  [[ "$tier" =~ ^[1-5]$ ]] || _die "LOOP_TIER must be 1-5 (got '$tier')"
  local oracle="${LOOP_ORACLE:-}"
  # ponytail: oracle is required at every tier, even 4/5 — a tier-5 human-gated loop that has no
  # deterministic smoke check at all can set LOOP_ORACLE=true and let the judge/human carry the
  # real verdict. Keeps parsing/logic uniform instead of a tier-conditional oracle requirement.
  [[ -n "$oracle" ]] || _die "LOOP_ORACLE is required (set to 'true' if this tier has no deterministic check)"
  local judge="${LOOP_JUDGE:-$REVIEW}"
  local human_gate="${LOOP_HUMAN_GATE:-false}"
  local target="${TARGET_DIR:-$PWD}"
  local plateau_n="${LOOP_PLATEAU:-3}"
  local wall_clock_h="${LOOP_WALL_CLOCK_H:-4}"

  judge="$(_resolve_judge "$judge" "")"

  mkdir -p "$loopdir"

  # FR-15/FR-8 (specs/03-swarm-loop.md): a code-editing loop runs in a scratch git worktree of
  # TARGET_DIR, never the orchestrator's own tree — a derailed iteration's `git reset --hard`
  # recovery then can't touch anything outside the worktree. base_sha is recorded so a completed
  # run can print a diff-stat against the exact commit the worktree branched from. Not a git repo
  # (or a repo with no commits yet — unborn HEAD) falls back to running directly against
  # TARGET_DIR with a loud warning: no worktree isolation, no git-reset safety net.
  local base_sha
  if base_sha="$(git -C "$target" rev-parse HEAD 2>/dev/null)"; then
    git -C "$target" worktree add -b "loop-$run_id" "$loopdir/worktree" "$base_sha" >&2
    target="$loopdir/worktree"
  else
    base_sha=""
    echo "swarm-loop: TARGET_DIR '$target' is not a usable git repo (not a repo, or no commits yet) — running directly against it, no worktree isolation, no git-reset safety net" >&2
  fi

  {
    printf 'goal: %s\n' "$LOOP_GOAL"
    printf 'tier: %s\n' "$tier"
    printf 'oracle: %s\n' "$oracle"
    printf 'judge: %s\n' "$judge"
    printf 'human_gate: %s\n' "$human_gate"
    printf 'target: %s\n' "$target"
    printf 'base_sha: %s\n' "$base_sha"
    printf 'stops:\n'
    printf '  max_iterations: %s\n' "$MAX_ITERATIONS"
    printf '  plateau: %s\n' "$plateau_n"
    printf '  budget_usd: %s\n' "$BUDGET_USD"
    printf '  wall_clock_h: %s\n' "$wall_clock_h"
    printf '\n## invariants\n'
    if [[ -n "${LOOP_INVARIANTS:-}" ]]; then
      while IFS= read -r line; do
        [[ -n "$line" ]] && printf -- '- %s\n' "$line"
      done <<<"$LOOP_INVARIANTS"
    fi
    printf '\n## checklist\n'
    if [[ -n "${LOOP_CHECKLIST:-}" ]]; then
      while IFS= read -r line; do
        [[ -n "$line" ]] && printf -- '- [FAILING] %s\n' "$line"
      done <<<"$LOOP_CHECKLIST"
    fi
  } > "$loopdir/criteria.md"

  _criteria_sha256 "$loopdir/criteria.md" > "$loopdir/.criteria.sha256"
  : > "$loopdir/steering.md"
  : > "$loopdir/state.jsonl"

  echo "swarm-loop: initialized run '$run_id' at $loopdir" >&2
}

# --- iterate ---------------------------------------------------------------------------------

_write_exec_prompt() {
  local loopdir="$1"
  cat <<EOF
## Criteria (read-only contract — do not attempt to change this)
$(cat "$loopdir/criteria.md")

## Signs
$_SIGNS

## Steering (accumulated findings from prior iterations)
$(cat "$loopdir/steering.md")
EOF
}

_write_review_prompt() {
  local loopdir="$1" exec_res="$2" oracle_file="$3" oracle_rc="$4" evidence
  if [[ -f "$exec_res" ]]; then
    evidence="$(cat "$exec_res")"
  else
    evidence="(no executor answer captured)"
  fi

  # The judge must review the ACTUAL change, not the executor's self-narration (specs/03 FR-3:
  # "sees only diff + criteria + oracle output"; loop-discipline.md proof-of-action gate). Compute
  # the worktree diff since base so a reviewer catches work the executor's prose omitted or
  # misrepresented. `git add -A` first so a brand-new file (outside the index) still shows in the
  # diff — the worktree is scratch, staging is harmless (the per-iteration checkpoint commits it).
  local target base_sha diff=""
  target="$(_criteria_field "$loopdir/criteria.md" target)"
  base_sha="$(_criteria_field "$loopdir/criteria.md" base_sha)"
  if [[ -n "$base_sha" ]] && git -C "$target" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$target" add -A >/dev/null 2>&1 || true
    diff="$(git -C "$target" diff --cached "$base_sha" 2>/dev/null | head -c 20000 || true)"
  fi
  [[ -n "$diff" ]] || diff="(no git worktree diff available — review the executor's answer above)"

  cat <<EOF
## Criteria
$(cat "$loopdir/criteria.md")

## Worktree diff since base ($base_sha) — the actual change, verify claims against THIS
$diff

## Executor's answer / self-report (context only — do not trust over the diff above)
$evidence

## Oracle output (rc=$oracle_rc)
$(cat "$oracle_file")

## Your task
Check for stub implementations, weakened tests, or claims not backed by the diff/oracle evidence
above — trust the diff, not the executor's prose. Respond with exactly one line "VERDICT: pass" or
"VERDICT: findings" (verbatim), followed by any details on subsequent lines.
EOF
}

_run_pool_once() {
  # spec 11 FR-S2: keep .bus/heartbeat fresh for the WHOLE pool wait, not once per iterate — a
  # single chain walk can legitimately outlive ORCH_TAKEOVER_MIN (EXEC_CHAIN lanes ×
  # WORKER_TIMEOUT_SEC), and an armed watchdog would then seat a paid continuation driver
  # alongside this perfectly healthy driver. Mirrors _spawn_worker's claim-heartbeat pattern.
  # kill -0 "$$" gates each tick on the driver still being alive: if this process is SIGKILLed
  # mid-pool the orphaned loop stops within a minute, so a genuine crash still goes stale and
  # the watchdog still fires (a heartbeat that outlives its driver would defeat spec 11 entirely).
  local _hb_pid
  ( while kill -0 "$$" 2>/dev/null; do "$SWARM_CTL" heartbeat "$BUSDIR"; sleep 60; done ) \
    </dev/null >/dev/null 2>&1 &
  _hb_pid=$!
  # ponytail: swarm-run.sh's own exit code isn't ours to rely on (specs/01 FR-7: a parked branch
  # now makes it exit nonzero instead of hanging forever, per the gap flagged from this build) —
  # the caller already checks for the res-<id>.txt file either way, so tolerate any exit here.
  # UNIMATRIX_BUS_OWNER=1 (spec 20 FR-3 amendment): the heartbeat keeping this bus "live" is OUR
  # OWN, refreshed by the loop above — without the ownership assertion the child run would refuse
  # its own parent's bus. ${RUN_LABEL:+--run} passes the label through per FR-5.
  # shellcheck disable=SC2086
  # POOL_LINGER_SEC=0 forced (spec 21 review round): loop iterations relaunch by design — there
  # is never a live pool for a late add to land in, so a conf-file linger would tax every
  # iteration N seconds for zero benefit (same active-override doctrine as FANOUT=1 here).
  BUSDIR="$BUSDIR" CONF="$CONF" FANOUT=1 UNIMATRIX_BUS_OWNER=1 POOL_LINGER_SEC=0 \
    "$SWARM_RUN" ${RUN_LABEL:+--run "$RUN_LABEL"} || true
  kill "$_hb_pid" 2>/dev/null || true
  wait "$_hb_pid" 2>/dev/null || true
}

_git_checkpoint() {
  local target="$1" run_id="$2" iter="$3" tried="$4"
  git -C "$target" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  [[ -n "$(git -C "$target" status --porcelain 2>/dev/null || true)" ]] || return 0
  git -C "$target" add -A
  # Explicit committer identity via -c: the checkpoint is a throwaway safety-net commit on a scratch
  # branch, so it must not depend on (or fatal without) an ambient user.name/user.email — an
  # identity-less environment would otherwise abort the whole iteration under errexit. A commit that
  # still fails for any other reason warns but never fails the iteration (the safety net is
  # best-effort; the iteration's real result already landed).
  git -C "$target" -c user.email=swarm-loop@unimatrix -c user.name=swarm-loop \
    commit -q -m "loop $run_id iter $iter: ${tried:0:72}" \
    || echo "swarm-loop: git checkpoint commit failed for $run_id iter $iter (safety-net only, continuing)" >&2
  return 0
}

cmd_iterate() {
  local run_id="$1"
  conf_load "$CONF"
  bus_init "$BUSDIR"
  # spec 11 FR-S2: the loop driver is the ORCHESTRATOR-side gate/poll — touch .bus/heartbeat here
  # (never from the exec pool) so a stale mtime means this driver itself is dead; first call also
  # seeds orch-seat "fable".
  "$SWARM_CTL" heartbeat "$BUSDIR"
  # spec 11 FR-S4: a continuation driver's handoff-back file blocks all new-wave planning until
  # Fable's re-audit is logged — no iteration may plan or run while the degraded window is
  # un-audited.
  [[ -f "$BUSDIR/loop/handoff-degraded.md" ]] \
    && _die "degraded window un-audited: $BUSDIR/loop/handoff-degraded.md exists — a continuation driver ran while Fable was down. Re-audit first (diff the scratch worktree, re-run the gates, confirm or re-open every verdict), then REMOVE the file to log the re-audit and unblock (the next iterate reclaims .bus/orch-seat back to fable automatically)."
  # spec 11 FR-S4: the gate passed, so the degraded window is closed (or never opened) — reclaim
  # the orchestrator seat if a takeover left it non-fable. cmd_heartbeat never overwrites an
  # existing seat, so without this every post-re-audit done record and speed row would stay
  # degraded:true (violating FR-S4's "no row outside that window carries the field as true"), the
  # ex-driver lane would stay judge-disqualified forever, and _watchdog_should_skip's non-fable
  # clause would silently swallow a SECOND crash. Atomic tmp+mv, same pattern as the takeover's
  # own seat write (bus-discipline.md: same-fs rename, never a `>` truncate a concurrent
  # orch_degraded read could catch empty).
  if [[ -s "$BUSDIR/orch-seat" ]]; then
    local _seat
    read -r _seat _ < "$BUSDIR/orch-seat"
    if [[ "$_seat" != fable ]]; then
      printf 'fable %s\n' "$(date +%s)" > "$BUSDIR/orch-seat.tmp"
      mv -f "$BUSDIR/orch-seat.tmp" "$BUSDIR/orch-seat"
      echo "swarm-loop: degraded window closed — orch-seat reclaimed from '$_seat' back to fable" >&2
    fi
  fi
  local loopdir; loopdir="$(_loopdir "$run_id")"
  [[ -f "$loopdir/criteria.md" ]] || _die "no run '$run_id' — run init first"
  _verify_criteria_unchanged "$loopdir"

  local oracle judge target
  oracle="$(_criteria_field "$loopdir/criteria.md" oracle)"
  judge="$(_criteria_field "$loopdir/criteria.md" judge)"
  target="$(_criteria_field "$loopdir/criteria.md" target)"
  judge="$(_resolve_judge "$judge" "")"

  local iter_n; iter_n=$(( $(wc -l < "$loopdir/state.jsonl") + 1 ))
  local iterdir="$loopdir/iter-$iter_n"
  mkdir -p "$iterdir"

  local exec_id="${run_id}-i${iter_n}-exec"
  _write_exec_prompt "$loopdir" > "$BUSDIR/specs/$exec_id.prompt"
  cp "$BUSDIR/specs/$exec_id.prompt" "$iterdir/exec.prompt"
  # FR-15: every exec increment gets write access scoped to `target` (the worktree, or TARGET_DIR
  # directly if init couldn't make one) — review/judge specs never get this sidecar, read-only.
  printf '%s' "$target" > "$BUSDIR/specs/$exec_id.write"

  _run_pool_once

  local exec_res="$BUSDIR/res-$exec_id.txt" tried
  if [[ -f "$exec_res" ]]; then
    cp "$exec_res" "$iterdir/exec.res"
    tried="$(head -c 200 "$exec_res" | tr '\n' ' ')"
  else
    tried="(no executor answer — lane exhausted/parked)"
  fi

  # The oracle executes code the worker just wrote into the worktree (test files, Makefiles, …), so
  # it runs under the SAME containment cage as a worker spawn (rules/unimatrix/model-lanes.md
  # least-privilege): env -i blanks the orchestrator's ambient env (API creds, AWS/SSH tokens) and
  # a scratch HOME keeps $HOME-rooted secrets out of reach. PATH/LANG are preserved so
  # the oracle's own tooling still resolves. Ceiling (documented, not solved): env -i does not
  # sandbox the filesystem — an oracle can still read a hardcoded absolute path; matches the
  # attended-v1 posture, and a fully sandboxed oracle is the unattended-run gate (spec 03 Non-Goals).
  local oracle_rc=0 oracle_out oracle_home="$loopdir/.oracle-home"
  mkdir -p "$oracle_home"
  oracle_out="$(env -i "PATH=$PATH" "LANG=${LANG:-C.UTF-8}" "HOME=$oracle_home" \
    bash -c "cd $(printf %q "$target") && ( $oracle )" 2>&1)" || oracle_rc=$?
  printf '%s\n' "$oracle_out" | tail -n 20 > "$iterdir/oracle.txt"

  local review="skipped"
  if (( oracle_rc == 0 )); then
    local review_id="${run_id}-i${iter_n}-review"
    _write_review_prompt "$loopdir" "$exec_res" "$iterdir/oracle.txt" "$oracle_rc" \
      > "$BUSDIR/specs/$review_id.prompt"
    cp "$BUSDIR/specs/$review_id.prompt" "$iterdir/review.prompt"

    # spec 10 FR-R2/FR-R3: the review/judge card is no longer hard-pinned (.lane) to one lane — it
    # gets a fallback CHAIN (.chain), walked by chain_current/chain_advance in the pool against the
    # same limits/.chain-<id> position file as EXEC_CHAIN. The chain is review_chain_for seeded
    # against THIS card's actual author (the exec's served lane, read from done/<exec_id>), so review
    # never lands on the executor (judge != executor stays absolute). The resolved judge is moved to
    # the chain head when it qualifies; a judge dropped by _judge_ok (author/role collision) is
    # recorded first-writer-wins for speed_row's fallback_reason BEFORE the pool can record an
    # availability reason — author/role (known now) takes precedence. author is empty when exec did
    # not finalize, in which case review_chain_for admits every qualifying member.
    local author chain
    author="$(jq -r '.lane // empty' "$BUSDIR/done/$exec_id" 2>/dev/null || true)"
    chain="$(review_chain_for "$author" "$BUSDIR")"

    # review_chain_for filters ONLY by _judge_ok, so a missing first source member is exactly that
    # filter excluding it — the author/role-collision provenance speed_row attributes this branch to.
    local -a _src=()
    if [[ -n "${REVIEW_CHAIN:-}" ]]; then read -ra _src <<<"$REVIEW_CHAIN"
    else read -ra _src <<<"${CLASS_REVIEW:-}"; fi
    if (( ${#_src[@]} )); then
      local _pb="${_src[0]%%:*}"
      # spec 11 FR-S3: pass $BUSDIR so the live orch-seat clause matches review_chain_for's own
      # filter — a first member dropped for holding the acting seat still records role-collision.
      if ! _judge_ok "$_pb" "$author" "$BUSDIR"; then
        local _reason
        if [[ "$_pb" == "$author" || "$(_lane_family "$_pb")" == "$(_lane_family "$author")" ]]; then
          _reason="author-collision"
        else
          _reason="role-collision"
        fi
        [[ -e "$BUSDIR/limits/.fbreason-$review_id" ]] \
          || printf '%s %s' "$_reason" "$_pb" > "$BUSDIR/limits/.fbreason-$review_id"
      fi
    fi

    # Move the resolved judge to the chain head when it qualifies (it usually already is —
    # review_chain_for's first survivor — but an explicit REVIEW_CHAIN override can order a different
    # member first; honoring the resolved judge keeps the operator's chosen judge primary when it can
    # serve). Falls back to the raw review_chain_for output unchanged when the resolved judge can't.
    local _jb="${judge%%:*}"
    # spec 11 FR-S3: $BUSDIR keeps the live orch-seat clause active here too — a judge the chain
    # filter just disqualified as the acting seat must never be re-promoted to the chain head.
    if [[ -n "$_jb" ]] && _judge_ok "$_jb" "$author" "$BUSDIR"; then
      local -a _carr=()
      [[ -n "$chain" ]] && read -ra _carr <<<"$chain"
      local _tok _tb _new="$judge"
      for _tok in "${_carr[@]}"; do
        _tb="${_tok%%:*}"
        [[ "$_tb" == "$_jb" ]] && continue
        _new+=" $_tok"
      done
      chain="${_new# }"
    fi

    printf '%s' "$chain" > "$BUSDIR/specs/$review_id.chain"

    _run_pool_once

    local review_res="$BUSDIR/res-$review_id.txt"
    if [[ -f "$review_res" ]]; then
      cp "$review_res" "$iterdir/review.res"
      local verdict
      verdict="$(grep -m1 -o 'VERDICT: *\(pass\|findings\)' "$review_res" 2>/dev/null || true)"
      case "$verdict" in
        *pass) review="pass" ;;
        *findings) review="findings" ;;
        *) review="findings" ;;  # unparseable verdict — fail closed, never assume pass
      esac
      if [[ "$review" != "pass" ]]; then
        {
          printf '\n## iter %s findings\n' "$iter_n"
          cat "$review_res"
        } >> "$loopdir/steering.md"
      fi
    else
      review="findings"  # no review answer at all — fail closed
      # spec10 FR-R7 (r3codex MAJ): distinguish "class exhausted, review parked" from an ordinary
      # findings verdict LOUDLY — _run_pool_once tolerates swarm-run's nonzero (a parked branch is
      # a valid pool outcome), so this stderr line + steering note are the loop-level signal.
      if [[ -e "$BUSDIR/limits/$review_id.parked" ]]; then
        echo "swarm-loop: iter $iter_n review PARKED (review class exhausted — no qualified judge served it); failing closed" >&2
        printf '\n## iter %s review PARKED — class exhausted, no verdict\n' "$iter_n" >> "$loopdir/steering.md"
      fi
    fi
  fi

  local sig; sig="$(_criteria_sha256 "$iterdir/oracle.txt")"

  # Per-iteration git commit is the loop's git-reset safety net (specs/03 FR-3/FR-8,
  # loop-discipline.md State): a derailed iteration is discarded via `git reset`, never argued with.
  # Default ON (opt OUT with LOOP_GIT_CHECKPOINT=0). No-ops harmlessly when target isn't a work tree.
  if [[ "${LOOP_GIT_CHECKPOINT:-1}" == "1" ]]; then
    _git_checkpoint "$target" "$run_id" "$iter_n" "$tried"
  fi

  # This iteration's real spend: total_cost_usd summed from the exec + review run logs. Only
  # claude/glm result envelopes carry a dollar figure (codex/gemini are dashboard/quota-metered and
  # contribute 0 here) — so the USD budget enforces the claude-lane cost, the one real-USD lane.
  local cost; cost="$(_run_cost_usd "$BUSDIR/run-$exec_id.jsonl" "$BUSDIR/run-${run_id}-i${iter_n}-review.jsonl")"

  local line
  line="$(jq -nc --argjson iter "$iter_n" --arg tried "$tried" --argjson oracle_rc "$oracle_rc" \
    --arg review "$review" --argjson cost "${cost:-0}" \
    --argjson ts "$(date +%s)" --arg sig "$sig" \
    '{iter:$iter, tried:$tried, oracle_rc:$oracle_rc, review:$review, cost:$cost, ts:$ts, sig:$sig}')"
  printf '%s\n' "$line" >> "$loopdir/state.jsonl"
}

# _run_cost_usd <runlog>... — sum .total_cost_usd across the last result event of each run log
# (claude/glm carry it; others don't → contribute 0). Echoes a bare number.
_run_cost_usd() {
  local f total=0 c
  for f in "$@"; do
    [[ -f "$f" ]] || continue
    c="$(jq -R -c 'fromjson? // empty' "$f" \
      | jq -s -r 'map(select(.type == "result") | .total_cost_usd // empty) | add // 0' 2>/dev/null || echo 0)"
    total="$(awk -v a="$total" -v b="${c:-0}" 'BEGIN{printf "%.6f", a + b}')"
  done
  printf '%s' "$total"
}

# --- run -----------------------------------------------------------------------------------

# spec 11 FR-S2: LOOP_WATCHDOG=1 declares this an unattended run — cmd_run then arms the one
# sanctioned cron takeover watchdog at run start, and _watchdog_close (called by _halt AND
# _complete, the two run-close funnels) disarms it on every deliberate close, normal or degraded —
# "disarm is not optional cleanup". Attended runs (knob unset) never ARM — cmd_run's start path
# only clears a leftover tagged line a crashed unattended run left behind. A driver CRASH
# deliberately skips disarm: the stale heartbeat + armed watchdog is exactly the FR-S2
# takeover trigger.
_watchdog_close() {
  if [[ "${LOOP_WATCHDOG:-0}" == "1" ]]; then
    "$SWARM_CTL" watchdog-disarm "$BUSDIR"
  fi
}

# _plateau_check <loopdir> <n> — true if the last n iterations show no progress: oracle_rc never
# changed and review never reached pass. ponytail: progress is (oracle_rc, review) equality, not
# full checklist-item diffing — upgrade to per-item tracking if this proves too coarse in practice.
_plateau_check() {
  local loopdir="$1" n="$2" total
  total="$(wc -l < "$loopdir/state.jsonl")"
  (( total >= n )) || return 1
  local lines first_rc all_same=1 rc rv
  lines="$(tail -n "$n" "$loopdir/state.jsonl")"
  first_rc="$(jq -r .oracle_rc <<<"$(head -n1 <<<"$lines")" 2>/dev/null || true)"
  while IFS= read -r ln; do
    [[ -z "$ln" ]] && continue
    rc="$(jq -r .oracle_rc <<<"$ln" 2>/dev/null || true)"
    rv="$(jq -r .review <<<"$ln" 2>/dev/null || true)"
    if [[ "$rc" != "$first_rc" || "$rv" == "pass" ]]; then
      all_same=0
      break
    fi
  done <<<"$lines"
  (( all_same == 1 ))
}

# _oscillation_check <loopdir> — true if the last 3 iterations' oracle-output signature alternates
# A/B/A (same file-region flip-flop, LOOP.md §4).
_oscillation_check() {
  local loopdir="$1" total
  total="$(wc -l < "$loopdir/state.jsonl")"
  (( total >= 3 )) || return 1
  local lines sig1 sig2 sig3
  lines="$(tail -n3 "$loopdir/state.jsonl")"
  sig1="$(jq -r .sig <<<"$(sed -n '1p' <<<"$lines")" 2>/dev/null || true)"
  sig2="$(jq -r .sig <<<"$(sed -n '2p' <<<"$lines")" 2>/dev/null || true)"
  sig3="$(jq -r .sig <<<"$(sed -n '3p' <<<"$lines")" 2>/dev/null || true)"
  [[ -n "$sig1" && "$sig1" == "$sig3" && "$sig1" != "$sig2" ]]
}

# _budget_exceeded <budget_usd> <loopdir> — rc 0 (halt) once this run's summed cost exceeds the cap.
# Cost is the sum of every state.jsonl iteration's `cost` (claude/glm total_cost_usd; other lanes
# are dashboard/quota-metered and read as 0), so the USD cap enforces the real-USD claude-lane
# spend. `0`/empty budget = no cap (swarm.conf convention). Not per-token — envelope totals only,
# never per-stream-event usage (inflates 3-8×, model-lanes.md).
_budget_exceeded() {
  local budget="$1" loopdir="$2" total
  [[ -z "$budget" || "$budget" == "0" ]] && return 1
  [[ -s "$loopdir/state.jsonl" ]] || return 1
  total="$(jq -s 'map(.cost // 0) | add // 0' "$loopdir/state.jsonl" 2>/dev/null || echo 0)"
  awk -v t="${total:-0}" -v b="$budget" 'BEGIN{ exit !(t > b) }'
}

_halt() {
  local loopdir="$1" rule="$2" iter="$3" suggestion="$4" tried_lines
  _watchdog_close
  tried_lines="$(tail -n3 "$loopdir/state.jsonl" | jq -r '"- iter " + (.iter|tostring) + ": " + .tried' 2>/dev/null || true)"
  cat > "$loopdir/HALTED.md" <<EOF
# Loop halted

Rule fired: $rule
Iterations run: $iter

## What was tried (last up to 3)
$tried_lines

## Suggested next move
$suggestion
EOF
  echo "swarm-loop: HALTED ($rule) after $iter iteration(s) — see $loopdir/HALTED.md" >&2
  # spec 12 FR-4: every deliberate halt is a self-filing signal — draft one feedback stub (class
  # loop-halted, extra to whatever durable-surface classes feedback_stubs detects on its own).
  # $BUSDIR is the top-level global set once at script start (never locally shadowed) — every
  # halt site routes through this one function, so this is the single choke point for the hookup.
  [[ "${FEEDBACK_AUTO:-1}" == "1" ]] && feedback_stubs "$BUSDIR" loop-halted 2>/dev/null || true
}

_complete() {
  local loopdir="$1" run_id="$2" iter="$3" oracle_out review_out target base_sha diffstat
  _watchdog_close
  oracle_out="$(cat "$loopdir/iter-$iter/oracle.txt" 2>/dev/null || true)"
  review_out="$(cat "$loopdir/iter-$iter/review.res" 2>/dev/null || true)"
  target="$(_criteria_field "$loopdir/criteria.md" target)"
  base_sha="$(_criteria_field "$loopdir/criteria.md" base_sha)"
  diffstat=""
  if [[ -n "$base_sha" ]]; then
    # `git diff <ref>` never includes untracked files (they're outside the index entirely) — stage
    # everything first so a brand-new file the exec worker created still shows up in the stat. This
    # worktree is scratch/throwaway for operator review before merge, so staging here is harmless.
    git -C "$target" add -A >/dev/null 2>&1 || true
    diffstat="$(git -C "$target" diff --stat "$base_sha" 2>/dev/null || true)"
  fi
  cat > "$loopdir/COMPLETE.md" <<EOF
# Loop complete: $run_id

Iterations: $iter

## Worktree
$target

## Diff since base ($base_sha)
${diffstat:-(no git worktree — diff not available)}

## Oracle output (last iteration, PASS)
$oracle_out

## Review verdict: pass
$review_out
EOF
  echo "swarm-loop: GOAL reached after $iter iteration(s) — see $loopdir/COMPLETE.md" >&2
  echo "swarm-loop: worktree: $target" >&2
  # `return 0` is load-bearing, not decoration (docs/02-build-pitfalls.md #18, same class as
  # _enqueue_pending_specs' own note): a bare `[[ ]] && echo` as the LAST command of a function
  # trips errexit under inherit_errexit whenever the condition is false (diffstat empty — the
  # common non-worktree case) — this function has already done its job by this point.
  [[ -n "$diffstat" ]] && echo "swarm-loop: $diffstat" >&2
  return 0
}

cmd_run() {
  local run_id="$1"
  local loopdir; loopdir="$(_loopdir "$run_id")"
  [[ -f "$loopdir/criteria.md" ]] || _die "no run '$run_id' — run init first"

  local max_iter plateau_n budget wall_h human_gate
  max_iter="$(_criteria_stop "$loopdir/criteria.md" max_iterations)"
  plateau_n="$(_criteria_stop "$loopdir/criteria.md" plateau)"
  budget="$(_criteria_stop "$loopdir/criteria.md" budget_usd)"
  wall_h="$(_criteria_stop "$loopdir/criteria.md" wall_clock_h)"
  human_gate="$(_criteria_field "$loopdir/criteria.md" human_gate)"

  # spec 11 FR-S2: unattended runs (LOOP_WATCHDOG=1) arm the takeover watchdog at run start —
  # every close path below funnels through _halt/_complete, which disarm it (_watchdog_close).
  # An ATTENDED resume (knob unset) after a crashed unattended run instead clears that run's
  # leftover tagged cron line: the crash skipped disarm by design, and nothing else ever would —
  # the standing entry must not outlive the run (spec 11 "disarm on every deliberate close").
  # watchdog-disarm is rc-0 and tag-scoped when no line exists, so a never-armed run is a no-op.
  if [[ "${LOOP_WATCHDOG:-0}" == "1" ]]; then
    "$SWARM_CTL" watchdog-arm "$BUSDIR"
  else
    "$SWARM_CTL" watchdog-disarm "$BUSDIR" 2>/dev/null || true
  fi

  local start_ts; start_ts="$(date +%s)"

  # Resume-after-human-gate: if the LAST recorded iteration already hit the goal (oracle green +
  # review pass), do NOT run a fresh exec first — that would mutate the very worktree the human is
  # reviewing before completing against it. Adjudicate the existing state instead: HUMAN_OK present
  # → complete against that iteration; still absent → re-halt pending. A fresh run (empty state)
  # falls straight through to the loop.
  if [[ -s "$loopdir/state.jsonl" ]]; then
    local rlast rorc rrev rit
    rlast="$(tail -n1 "$loopdir/state.jsonl")"
    rorc="$(jq -r .oracle_rc <<<"$rlast")"; rrev="$(jq -r .review <<<"$rlast")"; rit="$(jq -r .iter <<<"$rlast")"
    if [[ "$rorc" == "0" && "$rrev" == "pass" ]]; then
      if [[ "$human_gate" == "true" && ! -e "$loopdir/HUMAN_OK" ]]; then
        _halt "$loopdir" "human_gate_pending" "$rit" \
          "Oracle+review both pass but this run is human_gate=true — have a human verify and touch '$loopdir/HUMAN_OK', then re-run."
        return 2
      fi
      rm -f "$loopdir/HALTED.md"
      _complete "$loopdir" "$run_id" "$rit"
      return 0
    fi
  fi

  while true; do
    cmd_iterate "$run_id"

    local last iter oracle_rc review
    last="$(tail -n1 "$loopdir/state.jsonl")"
    iter="$(jq -r .iter <<<"$last")"
    oracle_rc="$(jq -r .oracle_rc <<<"$last")"
    review="$(jq -r .review <<<"$last")"

    if (( oracle_rc == 0 )) && [[ "$review" == "pass" ]]; then
      if [[ "$human_gate" == "true" && ! -e "$loopdir/HUMAN_OK" ]]; then
        _halt "$loopdir" "human_gate_pending" "$iter" \
          "Oracle+review both pass but this run is human_gate=true — have a human verify and touch '$loopdir/HUMAN_OK', then re-run."
        return 2
      fi
      _complete "$loopdir" "$run_id" "$iter"
      return 0
    fi

    # Oscillation is the more SPECIFIC condition (A→B→A flip-flop) and needs a different remedy
    # (human decision) than plateau (reset strategy), so it is checked FIRST — otherwise plateau's
    # broader "no oracle_rc/review progress" window shadows it whenever plateau_n <= 3 (an A/B/A
    # oscillation is also "no progress"), and the run would mislabel a flip-flop as a plateau.
    if _oscillation_check "$loopdir"; then
      _halt "$loopdir" "oscillation" "$iter" \
        "The same failure signature is flip-flopping across iterations — needs a human decision."
      return 2
    fi

    if _plateau_check "$loopdir" "$plateau_n"; then
      _halt "$loopdir" "plateau" "$iter" \
        "$plateau_n iterations with no progress — reset strategy rather than retrying the same step."
      return 2
    fi

    if (( iter >= max_iter )); then
      _halt "$loopdir" "max_iterations" "$iter" \
        "Iteration cap reached — raise max_iterations only with explicit approval, or re-scope the goal into smaller increments."
      return 2
    fi

    if _budget_exceeded "$budget" "$loopdir"; then
      _halt "$loopdir" "budget_usd" "$iter" \
        "Budget cap reached — review spend before raising budget_usd."
      return 2
    fi

    if (( wall_h > 0 )) && (( $(date +%s) - start_ts >= wall_h * 3600 )); then
      _halt "$loopdir" "wall_clock_h" "$iter" \
        "Wall-clock cap reached — resume in a fresh run or extend wall_clock_h explicitly."
      return 2
    fi

    if [[ -e "$BUSDIR/PAUSE" ]]; then
      _halt "$loopdir" "human_abort" "$iter" \
        "Run was paused/aborted by a human — resume with 'swarm-loop.sh run $run_id' once ready."
      return 2
    fi
  done
}

case "${1:-}" in
  init)    [[ $# -ge 2 ]] || usage; cmd_init "$2" ;;
  iterate) [[ $# -ge 2 ]] || usage; cmd_iterate "$2" ;;
  run)     [[ $# -ge 2 ]] || usage; cmd_run "$2" ;;
  *) usage ;;
esac
