#!/usr/bin/env bash
# Sourceable bus primitives for /swarm: init, config load, atomic claim, heartbeat, reap, gate count, limit flags, jq firehose filter, per-lane invocation/answer-extraction/limit-detection, and per-id EXEC_CHAIN position tracking.
#
# Project: unimatrix — multi-model swarm orchestrator driven from Claude Code
# Module:  src/swarm-lib.sh
# Deps:    coreutils (mv/touch/find/stat/date), jq, git (write-card diff sections), bash >=5.1
# Tested:  tests/swarm-lib.bats
#
# Key responsibilities:
# - Bus directory lifecycle (specs/queue/claimed/done/cancelled/limits/pids)
# - Config precedence resolution (env > file > default) + loud lane-token validation at load
#   (spec 10 FR-R1, widened round3/backlog-27 to EXEC_CHAIN/REVIEW/VERIFY_MAP pairs and spec 11
#   PLAN_CHAIN/ORCH_CHAIN/ORCH_TAKEOVER_MIN)
# - Race-free claim/heartbeat/reap primitives; gate math; rate-limit flag primitives
# - lane_cmd (build the exec argv per lane:model, `env -i`-scrubbed with a per-lane scratch HOME —
#   containment gate, DECISIONS.md Q2 (env cage) / FR-16 (opt-in docker for the web lane),
#   docs/02-build-pitfalls.md; FR-15 write mode via the queue/<id>.write
#   sidecar — claude/glm/kimi get --permission-mode acceptEdits + CWD=target, codex its native -C/-s
#   workspace-write (plain cards stay -s read-only, backlog-32), gemini a loud refusal; FR-16
#   opt-in containerized gemini lane via
#   GEMINI_SANDBOX=docker — docker run --rm -i, explicit -e allowlist only, zero -v/--mount,
#   pinned image), extract_answer (normalize each lane's handoff to res-<id>.txt), limit_error
#   (GLM/codex/kimi/claude/gemini rate-limit + auth-death (.dead) signature detection — spec 10)
# - spec-10 role-class primitives: dead_flag/lane_dead/lane_blocked, _lane_family/_judge_ok,
#   review_chain_for, kimi_budget_ok/_kimi_spend_add, answer_unusable, _chain_tokens
# - spec-21 speed/observability primitives: _env_master_path (shared env-master resolver:
#   explicit > XDG > ~/s/.env.master), claim-stamp consumption in speed_row (additive
#   claim_ts/queue_wait_secs row keys), run_summary's additive top_wall (top-3 wall sinks),
#   POOL_LINGER_SEC/PROBE_TIMEOUT_SEC/BROKEN_MIN_CARDS/LANE_MAX_<lane> conf keys, FANOUT
#   baked default 6
# - spec-11 succession primitives: orch_seat/orch_degraded (busdir/orch-seat acting-seat read),
#   seat-aware _judge_ok/review_chain_for/verify_lane_for (FR-S3 role exclusion), and speed_row's
#   degraded:true field under a non-fable seat (FR-S4)
# - spec-13 lane-health primitives: env_master_preflight (launch-time abort when this run's lane
#   set needs an env-key lane and $ENV_MASTER_FILE is unreadable — FR-1), broken_flag/lane_broken
#   (TTL'd .broken fast-fail marker, same mechanics as limit_flag/limit_active — FR-3, consulted by
#   lane_blocked), and _payg_denied (the BUDGET_USD=0 PAYG-fallback-onto-kimi gate — FR-4)
# - spec-14 attribution/fidelity primitives: _marker_line/_marker_ttl (the one producer and the one
#   parser of every limits/ marker's `<ISO> | <reason-token> | retryable | ttl | <text>` line, with
#   legacy bare-digit TTL compat — FR-7), cage_denials (read-class permission_denials count, the
#   cage-denied class — FR-1), _rate_limit_signature + limit_error's session-limit envelope fallback
#   for claude/glm/kimi (FR-4), _claim_meta (THE claim-filename split + run-log freshness primitive,
#   shared by reap/_claim_of/lane_has_live_worker and spec 01 FR-A) with lane_has_live_worker /
#   _flag_dead_or_downgrade on top of it (FR-6), and FR-2's manifest scoping in
#   _write_card_diff_section (below)
# - chain_current/chain_advance/chain_reset (per-id fallback position; seed .chain-<id> ->
#   queue/<id>.chain -> EXEC_CHAIN)
# - kill_subtree / signal_subtree (pid + every descendant, snapshot-before-signal) — shared by the
#   FR-12 watchdog, FR-13 driver-death sweep, and swarm-ctl kill / pause-worker / resume-worker
# - reap() skips limits/<id>.frozen claims (SIGSTOP freeze — cockpit redesign §4.6b); spec 01
#   Amendment 2026-07-25 FR-A adds a liveness guard (live pid or fresh run log skips the release)
#   fenced by a hard 2x-per-lane-timeout age cap, plus mover=reap stderr attribution on every actual
#   requeue — heartbeat() becomes `touch -c` in the same change so it can never resurrect a released
#   claim
# - Phase E step 4: verify_lane_for/write_verify_spec (cross-model verify wave, judge != executor
#   via swarm.conf VERIFY_MAP; backlog-28 _write_card_diff_section scopes a write card's verify
#   prompt to its own stamp-newer diff, spec 14 FR-2 amends it to prefer an explicit deliverable
#   manifest — files-<id>.txt or queue/<id>.files — over that stamp-newer sweep when one exists)
#   and ledger_row (auto-appends docs/ops/llm-runs.md per finalized run)
# - specs/05-ground-control.md: mon_web_ensure/mon_web_open — idempotent web-cockpit bootstrap
#   (systemd-run, so `gc` adopts the same unit, else nohup/setsid) + once-per-bus browser
#   auto-open; both are non-fatal by construction, never allowed to fail a run
# - plan-004 PRD phase 0: _run_label (P0-FR1) — THE one speedwars run-join-key derivation, called
#   by speed_row/run_summary/feedback_stubs below and swarm-ctl's cmd_review_stub, replacing 4
#   independent copies of the same inline expression; and doctor_skill_drift (P0-FR2 repo half) —
#   the account-skill-copy hash/symlink check `unimatrix doctor` (swarm-run.sh) wires in
# - plan-004 PRD phase 2: lane_summary (P2-FR1) — the three-line close-out lane summary, derived by
#   SHELLING src/speedwars-report.sh (the canonical fold) scoped to this run, never re-aggregated
#   here; and bus_archive — the raw-evidence freeze into docs/ops/bus-archives/<run>/ (zstd if on
#   PATH, else gzip), the structured backup target documented in that dir's README.md
#
# Design constraints:
# - No side effects on source; every function takes its busdir explicitly
# - <worker> is always <lane>:<model> (lane in claude|codex|gemini|glm|grok|kimi, model may contain
#   dots, e.g. glm-5.2) — claimed/<id>.<worker> is unambiguous because reap() strips that exact
#   trailing ".<lane>:<model>" suffix via regex, so a dotted <id> (e.g. "s4r.api") is never
#   mis-split. Older/foreign claim names without a recognized lane:model suffix fall back to a
#   first-dot split (dot-free ids only) for backward compatibility.
# - Keys are grepped per-lane from $ENV_MASTER_FILE (default
#   $XDG_CONFIG_HOME/unimatrix/env.master) at spawn time only —
#   never sourced, never exported into the caller's own env
# - Every worker's child env is `env -i` (blank slate) + PATH + a per-lane scratch HOME + LANG +
#   the lane's own key(s) — never the orchestrator's ambient env (containment gate, DECISIONS.md
#   Q2). claude/codex have no env-only auth path, so their scratch HOME gets ONLY the one
#   credential file each needs, copied fresh per spawn — never the whole real $HOME.
set -euo pipefail
# bash >= 5.1 gate. This file is sourced, so `return` when the guard trips (fall back to `exit` if
# it was somehow run directly). MUST precede `shopt -s inherit_errexit`: that option does not exist
# before bash 4.4, so an ancient bash would die on the shopt line before ever printing this message.
if [ "${BASH_VERSINFO[0]}" -lt 5 ] || { [ "${BASH_VERSINFO[0]}" -eq 5 ] && [ "${BASH_VERSINFO[1]}" -lt 1 ]; }; then
  echo "unimatrix: bash >= 5.1 required (found $BASH_VERSION); on macOS: brew install bash" >&2
  # shellcheck disable=SC2317  # reachable: `return` when sourced (the norm), `exit` if run directly
  return 1 2>/dev/null || exit 1
fi
shopt -s inherit_errexit

# Portability probes resolved ONCE at source time (BSD/macOS coreutils differ from GNU) --------------
# ENV_HAS_C: does `env` support `-C <dir>` (chdir)? GNU coreutils yes; BSD/macOS env no. Callers that
# need a worker chdir'd fall back to a portable `bash -c 'cd …'` wrapper when this is 0.
ENV_HAS_C=0
if env -C / true 2>/dev/null; then ENV_HAS_C=1; fi

# _stat_devino <path> -> "<dev>:<inode>" (fencing token); _stat_mtime <path> -> mtime epoch seconds.
# GNU `stat -c` first, BSD/macOS `stat -f` fallback. CRITICAL: on BSD stat the GNU `-c` form silently
# prints nothing, so an unwrapped `stat -c` yields an empty fencing token / mtime — which downstream
# reads as "claim vanished" and can spin an infinite worker respawn loop.
_stat_devino() { stat -c '%d:%i' "$1" 2>/dev/null || stat -f '%d:%i' "$1" 2>/dev/null; }
_stat_mtime()  { stat -c %Y "$1"     2>/dev/null || stat -f %m    "$1" 2>/dev/null; }
_stat_birth()  { stat -c %W "$1" 2>/dev/null || echo 0; }

# bus_init <busdir> — create the file-bus directory tree.
bus_init() {
  local busdir="$1"
  mkdir -p "$busdir"/{specs,queue,claimed,done,cancelled,limits,pids}
  # spec 12 FR-6: seed the orchestrator's own per-run "observation -> candidate lesson" notebook
  # if absent — one write, never touched again by bus_init once it exists (an operator/orchestrator
  # may already have written into it; a repeat bus_init, e.g. every full_run/verify_run call site,
  # must never clobber that). Workers never write here (orchestrator-only surface, bus-discipline.md).
  # `set -C` (noclobber) in a SUBSHELL makes the create atomic (O_EXCL): a check-then-`>` sequence
  # loses the file another initializer created — or an operator edited — in the window between the
  # two. A losing racer just fails the redirect, hence the `|| true`.
  ( set -C
    {
      printf '# %s — running lessons notebook (orchestrator-only)\n' "$(basename "$busdir")"
      printf 'Format: observation -> candidate lesson.\n'
      printf 'Distilled into the skill lessons ledger + run-reviews at close.\n'
    } > "$busdir/notes-lessons.md"
  ) 2>/dev/null || true
}

# CONF_KEYS — every settable swarm.conf key, in display order. Global (not conf_load-local) so the
# resolved-config table (swarm-run.sh's _print_config_table) renders from the SAME list conf_load
# resolves: a new conf key can no longer be silently absent from `config`/`--plan-only` output
# (specs/04-settings.md FR-2's fully-resolved-config contract).
#
# conf_load <conffile> — load swarm.conf KEY=VALUE over baked defaults.
# Precedence: already-set env > conffile > baked default (specs/04-settings.md FR-1).
CONF_KEYS=(PLAN ORCHESTRATOR REVIEW EXEC_CHAIN MAX_ITERATIONS BUDGET_USD FANOUT LEASE_MIN
           WORKER_TIMEOUT_SEC MAX_LANE_RETRIES VERIFY_MAP LEDGER_AUTO GEMINI_SANDBOX
           MON_PORT MON_AUTOOPEN CLASS_REVIEW CLASS_EXEC REVIEW_CHAIN PIN_WAIT_SEC
           PLAN_CHAIN ORCH_CHAIN ORCH_TAKEOVER_MIN FEEDBACK_AUTO PAYG_FALLBACK
           GLM_MAX_THINKING_TOKENS KIMI_MAX_THINKING_TOKENS GROK_EFFORT CAGE_DENY_MAX
           STAGGER_FIRST_SPAWN_SEC PROBE_AUTO
           TIMEOUT_CLAUDE TIMEOUT_CODEX TIMEOUT_GEMINI TIMEOUT_GLM TIMEOUT_GROK TIMEOUT_KIMI
           POOL_LINGER_SEC PROBE_TIMEOUT_SEC BROKEN_MIN_CARDS
           LANE_MAX_CLAUDE LANE_MAX_CODEX LANE_MAX_GEMINI LANE_MAX_GLM LANE_MAX_GROK LANE_MAX_KIMI)

conf_load() {
  local conffile="$1"
  local keys=("${CONF_KEYS[@]}")
  local -A env_val=()
  local k

  for k in "${keys[@]}"; do
    if [[ -n "${!k+x}" ]]; then
      env_val[$k]="${!k}"
    fi
  done

  : "${PLAN:=fable}"
  : "${ORCHESTRATOR:=fable}"
  : "${REVIEW:=codex:default}"
  : "${EXEC_CHAIN:=claude:haiku codex:default}"
  : "${MAX_ITERATIONS:=10}"
  : "${BUDGET_USD:=0}"
  # spec 21 FR-15: 6, not 4 — buses are per-run namespaced (spec 20) so wide pools no longer
  # collide, and operating guidance has said FANOUT>=6 since round 3.
  : "${FANOUT:=6}"
  : "${LEASE_MIN:=15}"
  : "${WORKER_TIMEOUT_SEC:=300}"
  : "${MAX_LANE_RETRIES:=3}"
  : "${VERIFY_MAP:=claude:codex codex:kimi gemini:claude glm:codex grok:codex kimi:codex}"
  : "${LEDGER_AUTO:=1}"
  : "${GEMINI_SANDBOX:=}"
  : "${MON_PORT:=4747}"
  : "${MON_AUTOOPEN:=1}"
  : "${CLASS_REVIEW:=codex kimi}"
  : "${CLASS_EXEC:=grok glm}"
  : "${REVIEW_CHAIN:=}"
  : "${PIN_WAIT_SEC:=120}"
  : "${PLAN_CHAIN:=fable codex kimi}"
  : "${ORCH_CHAIN:=fable kimi}"
  : "${ORCH_TAKEOVER_MIN:=20}"
  : "${FEEDBACK_AUTO:=1}"  # spec 12 FR-4: gates feedback_stubs's auto-drafted draft stubs
  : "${PAYG_FALLBACK:=warn}"  # spec 13 FR-4: warn|allow|deny — gates a fallback hop onto kimi
                               # (real-PAYG) while BUDGET_USD=0 (uncapped)
  # backlog-31 (round3, specs/04-settings.md §Validation amendment): these three used to be
  # deliberately EXCLUDED from `keys` (swarm.conf.example still says so) so an operator could set
  # them as bare env vars with no conf_load involvement at all. That reasoning broke FR-1 instead
  # of avoiding it: excluded from `keys` means excluded from the env_val capture-before-source /
  # re-overlay-after-source dance below, so a swarm.conf file value SILENTLY CLOBBERS an
  # already-set env override (the opposite of "env > file > default"), and the value never reaches
  # `export "${keys[@]}"` — fine for a same-process lane_cmd call (bash var scoping needs no
  # export), but lost across the swarm-loop.sh -> swarm-run.sh subprocess boundary unless the
  # operator's shell happened to export it itself. Folding them into `keys` gives them the exact
  # same FR-1 precedence and export guarantee as every other knob; lane_cmd's own
  # `${GLM_MAX_THINKING_TOKENS:-6000}`-style fallbacks stay as defense in depth for any caller that
  # invokes lane_cmd without ever calling conf_load (e.g. a bare unit test).
  : "${GLM_MAX_THINKING_TOKENS:=6000}"   # cap GLM thinking-token flood; 0 = disable thinking
  : "${KIMI_MAX_THINKING_TOKENS:=6000}"  # cap kimi thinking-token flood (real $ at $15/M out)
  # `=` not `:=` (round-4 MIN): `:=` also assigns on EMPTY, so an explicitly-empty GROK_EFFORT —
  # the documented way to restore the grok CLI's own high-effort default — was silently rewritten
  # back to "medium" here before lane_cmd ever saw it.
  : "${GROK_EFFORT=medium}"              # grok reasoning effort; empty = restore the CLI default
  # spec 14 FR-1: ceiling, not a toggle — a run that knowingly cages out a few reads raises it;
  # absurdly high is the opt-out. 0 = any read-class denial parks the card.
  : "${CAGE_DENY_MAX:=0}"
  # spec 04 amendment 2026-07-26 (backlog 20): bound (seconds) a same-lane follower waits for the
  # lane's FIRST worker to produce output before spawning its own CLI. 0 = stagger off.
  : "${STAGGER_FIRST_SPAWN_SEC:=10}"
  # spec 13 FR-6 (backlog 58): event-fired auto live-probes (pre-claim + reactive), once per lane
  # per run. 0 = off (tests, or an operator who wants doctor --live only).
  : "${PROBE_AUTO:=1}"
  # spec 04 §Amendment 2026-07-25 FR-C: per-lane watchdog overrides, resolved at the single
  # enforcement site as ${TIMEOUT_<LANE>:-$WORKER_TIMEOUT_SEC}. Defaults are EMPTY on purpose —
  # baking docs/larger-swarms.md's C3 suggestions would silently multiply the effective timeout
  # 4-8x for every conf that relies on the 300 default, on the one knob whose whole job is bounding
  # runaway spend. `=` not `:=`: empty IS the value, not an unset to be filled in.
  : "${TIMEOUT_CLAUDE=}"
  : "${TIMEOUT_CODEX=}"
  : "${TIMEOUT_GEMINI=}"
  : "${TIMEOUT_GLM=}"
  : "${TIMEOUT_GROK=}"
  : "${TIMEOUT_KIMI=}"
  # spec 21 FR-1: seconds a DRAINED pool keeps polling queue/ before closing, so late adds
  # (dependent cards, review/fix waves) are served by the same invocation instead of a full
  # relaunch (bh065: 60% of a 41-min run was idle bus between relaunches). 0 = close on drain,
  # today's exact behavior — and the right value for swarm-loop iterations, which relaunch by
  # design.
  : "${POOL_LINGER_SEC:=0}"
  # spec 21 FR-2: probe timeout override, all lanes. Empty = per-lane resolve at the probe site
  # (30s claude/codex cold-start, 10s the rest). `=` not `:=`: empty IS the value.
  : "${PROBE_TIMEOUT_SEC=}"
  # spec 21 FR-5: distinct fast-failed CARDS required before a lane earns the 1800s bench;
  # below the threshold the marker is the 600s short-TTL form (one card's burst is one data
  # point, not a lane verdict — pure064: a healthy lane benched 30 min on one probe timeout).
  : "${BROKEN_MIN_CARDS:=2}"
  # spec 21 FR-13: per-lane in-flight ceilings, counted against claimed/ at claim time. Empty
  # (or <=0) = unlimited; a capped lane is SKIPPED (lane_blocked semantics), never a pool wedge.
  : "${LANE_MAX_CLAUDE=}"
  : "${LANE_MAX_CODEX=}"
  : "${LANE_MAX_GEMINI=}"
  : "${LANE_MAX_GLM=}"
  : "${LANE_MAX_GROK=}"
  : "${LANE_MAX_KIMI=}"

  if [[ -f "$conffile" ]]; then
    # shellcheck source=/dev/null
    source "$conffile"
  fi

  for k in "${keys[@]}"; do
    if [[ -n "${env_val[$k]+x}" ]]; then
      printf -v "$k" '%s' "${env_val[$k]}"
    fi
  done

  # Loud lane-token validation (spec 10 FR-R1): every whitespace token in CLASS_REVIEW/CLASS_EXEC,
  # and the bare-lane part (before ":") of every REVIEW_CHAIN token, must be one of the six lanes.
  # Runs after the env re-overlay (so an env override is validated too) and before export (a bad
  # config must never reach a spawned worker). Empty/unset REVIEW_CHAIN is valid (derive from
  # CLASS_REVIEW instead); empty CLASS_REVIEW/CLASS_EXEC is itself a validation error.
  # One lane roster, hoisted once — every lane-token check below matches against these, so adding
  # a lane is a single edit here (bash =~ with an unquoted variable applies it as the same ERE).
  local lanes='claude|codex|gemini|glm|grok|kimi'
  local lane_re="^($lanes)\$" pair_re="^($lanes):($lanes)\$"
  local vkey vtok vbare
  local -a vtoks
  for vkey in CLASS_REVIEW CLASS_EXEC; do
    if [[ -z "${!vkey}" ]]; then
      echo "conf_load: $vkey must not be empty" >&2
      return 1
    fi
    read -ra vtoks <<<"${!vkey}"
    for vtok in "${vtoks[@]}"; do
      if [[ ! "$vtok" =~ $lane_re ]]; then
        echo "conf_load: $vkey has invalid lane token '$vtok'" >&2
        return 1
      fi
    done
  done
  read -ra vtoks <<<"${REVIEW_CHAIN:-}"
  for vtok in "${vtoks[@]}"; do
    vbare="${vtok%%:*}"
    if [[ ! "$vbare" =~ $lane_re ]]; then
      echo "conf_load: REVIEW_CHAIN has invalid lane token '$vtok'" >&2
      return 1
    fi
  done

  # backlog-27 (round3, specs/04-settings.md §Validation): same loud die-at-load contract, widened
  # to EXEC_CHAIN/REVIEW (non-empty, bare-lane prefix per token) and VERIFY_MAP (gen:verifier pairs
  # — BOTH sides validated; empty map stays valid, same as REVIEW_CHAIN above).
  for vkey in EXEC_CHAIN REVIEW; do
    if [[ -z "${!vkey}" ]]; then
      echo "conf_load: $vkey must not be empty" >&2
      return 1
    fi
    read -ra vtoks <<<"${!vkey}"
    for vtok in "${vtoks[@]}"; do
      vbare="${vtok%%:*}"
      if [[ ! "$vbare" =~ $lane_re ]]; then
        echo "conf_load: $vkey has invalid lane token '$vtok'" >&2
        return 1
      fi
    done
  done
  read -ra vtoks <<<"${VERIFY_MAP:-}"
  for vtok in "${vtoks[@]}"; do
    # The alternation contains no colon, so pair_re accepts exactly the well-formed
    # generator:verifier pairs (colon-less, empty-side, and multi-colon tokens all fail).
    if [[ ! "$vtok" =~ $pair_re ]]; then
      echo "conf_load: VERIFY_MAP has invalid lane token '$vtok'" >&2
      return 1
    fi
  done

  # spec 11 FR-S1/FR-S3 (succession): PLAN_CHAIN/ORCH_CHAIN are ordered bare-lane succession
  # chains — the FIRST token is always the seated authority itself ("fable"; fable is never
  # spawned, lane_cmd's fable arm refuses outright), every remaining token must be one of the six
  # spawnable lanes, same as the rest of this loud die-at-load contract.
  for vkey in PLAN_CHAIN ORCH_CHAIN; do
    read -ra vtoks <<<"${!vkey}"
    if [[ "${vtoks[0]:-}" != fable ]]; then
      echo "conf_load: $vkey must start with 'fable'" >&2
      return 1
    fi
    for vtok in "${vtoks[@]:1}"; do
      if [[ ! "$vtok" =~ $lane_re ]]; then
        echo "conf_load: $vkey has invalid lane token '$vtok'" >&2
        return 1
      fi
    done
  done

  if [[ ! "$ORCH_TAKEOVER_MIN" =~ ^[1-9][0-9]*$ ]]; then
    echo "conf_load: ORCH_TAKEOVER_MIN must be a positive integer" >&2
    return 1
  fi

  # spec 04 §Amendment 2026-07-25 FR-C: the six per-lane timeouts are positive-int-OR-EMPTY (empty
  # is their default and means "fall back to WORKER_TIMEOUT_SEC"). WORKER_TIMEOUT_SEC itself is
  # positive-int, non-empty — this validation is retrofitted onto it because a non-numeric value
  # made the watchdog's `sleep "$WORKER_TIMEOUT_SEC"` die instantly, silently DISARMING hang
  # protection for the whole run instead of failing loudly.
  local tkey
  for tkey in WORKER_TIMEOUT_SEC TIMEOUT_CLAUDE TIMEOUT_CODEX TIMEOUT_GEMINI TIMEOUT_GLM \
              TIMEOUT_GROK TIMEOUT_KIMI; do
    [[ -z "${!tkey}" && "$tkey" != WORKER_TIMEOUT_SEC ]] && continue
    if [[ ! "${!tkey}" =~ ^[1-9][0-9]*$ ]]; then
      echo "conf_load: $tkey must be a positive integer (got '${!tkey}')" >&2
      return 1
    fi
  done

  # spec 14 FR-1 (cross-review fix): CAGE_DENY_MAX is a NONNEGATIVE integer, never empty — 0 is
  # its valid default (any read-class denial parks), unlike the TIMEOUT_<LANE> keys above where
  # empty is the valid default. Unvalidated, a garbage value (e.g. `CAGE_DENY_MAX=abc`) reached
  # bash arithmetic in the finalize gate under `set -u` and aborted finalize with the card still
  # claimed — the same class of silent-disarm bug WORKER_TIMEOUT_SEC's own validation above exists
  # to prevent.
  if [[ ! "$CAGE_DENY_MAX" =~ ^[0-9]+$ ]]; then
    echo "conf_load: CAGE_DENY_MAX must be a nonnegative integer (got '$CAGE_DENY_MAX')" >&2
    return 1
  fi

  # spec 21 keys (codex review 2026-08-01): all four families reach bash arithmetic — garbage or
  # leading-zero (octal) values would hang the linger comparison or abort the pool subshell, the
  # exact silent-disarm class the validations above exist for. POOL_LINGER_SEC nonneg (0 = its
  # default, close on drain); BROKEN_MIN_CARDS positive; PROBE_TIMEOUT_SEC and LANE_MAX_* empty
  # (= per-lane default / unlimited) or a positive integer.
  if [[ ! "$POOL_LINGER_SEC" =~ ^(0|[1-9][0-9]*)$ ]]; then
    echo "conf_load: POOL_LINGER_SEC must be a nonnegative integer (got '$POOL_LINGER_SEC')" >&2
    return 1
  fi
  if [[ ! "$BROKEN_MIN_CARDS" =~ ^[1-9][0-9]*$ ]]; then
    echo "conf_load: BROKEN_MIN_CARDS must be a positive integer (got '$BROKEN_MIN_CARDS')" >&2
    return 1
  fi
  local s21key
  for s21key in PROBE_TIMEOUT_SEC LANE_MAX_CLAUDE LANE_MAX_CODEX LANE_MAX_GEMINI LANE_MAX_GLM \
                LANE_MAX_GROK LANE_MAX_KIMI; do
    [[ -z "${!s21key}" ]] && continue
    if [[ ! "${!s21key}" =~ ^[1-9][0-9]*$ ]]; then
      echo "conf_load: $s21key must be empty or a positive integer (got '${!s21key}')" >&2
      return 1
    fi
  done

  # spec 13 FR-4: PAYG_FALLBACK is a closed enum (warn|allow|deny) — same loud die-at-load
  # contract as every other config guard above, a bad value must never reach a live run.
  case "$PAYG_FALLBACK" in
    warn | allow | deny) ;;
    *)
      echo "conf_load: PAYG_FALLBACK must be warn|allow|deny (got '$PAYG_FALLBACK')" >&2
      return 1
      ;;
  esac

  export "${keys[@]}"
}

# claim <busdir> <id> <worker> — atomic rename-to-unique-dest claim (bus-discipline.md).
# rc 0 = claimed, rc 1 = lost the race (ENOENT, no error spam), rc 2 = blocked by PAUSE.
# Contract: <id> is ours and dot-free ([a-z0-9-]+); <worker> may contain dots (glm-5.2, w1.codex).
claim() {
  local busdir="$1" id="$2" worker="$3"
  local src="$busdir/queue/$id.prompt" dst="$busdir/claimed/$id.$worker"
  [[ -e "$busdir/PAUSE" ]] && return 2
  if ! mv "$src" "$dst" 2>/dev/null; then
    # Lost race: source already gone (ENOENT) — that failure IS the signal, no error spam.
    [[ -e "$src" ]] || return 1
    # Anything else (perms, bad busdir, disk full, ...) is a real error — let it surface.
    mv "$src" "$dst"
  fi
  # FR-14 fence (spec 01, amended 2026-08-01): re-mint the claim file's inode. mv-based
  # claim/reap/re-claim cycles PRESERVE the inode, so a raw re-claim handed a reaped-but-alive
  # stale worker a still-matching dev:inode token — the exact double-finalize the fence exists
  # to stop. Copy-then-rename-over gives every claim a unique token; the dot-name keeps the
  # tmp file out of claimed/ globs (gate math, lane caps) if a crash strands it. Residual
  # race: a stale finalize landing inside this two-syscall window still sees the old inode —
  # microseconds, vs the whole worker runtime before this fix.
  local mint="$busdir/claimed/.$id.$worker.mint.$$"
  { cp "$dst" "$mint" 2>/dev/null && mv -f "$mint" "$dst" 2>/dev/null; } || { rm -f "$mint"; return 1; }
  return 0
}

# _heartbeat_live <heartbeat-file> — spec 20 FR-3/FR-4: rc 0 iff the spec 11 orchestrator
# heartbeat at a bus root is LIVE (mtime age < 60s). Read-only — spec 20 adds no writer; the file
# is maintained by swarm-ctl heartbeat / the orchestrator loop (spec 11 owns it). Missing file =
# not live.
_heartbeat_live() {
  local f="$1" mt now
  [[ -f "$f" ]] || return 1
  mt="$(_stat_mtime "$f" 2>/dev/null)" || return 1
  now="$(date +%s)"
  (( now - mt < 60 ))
}

# heartbeat <busdir> <id> <worker> — touch the claim file's mtime.
# `-c` (spec 01 Amendment 2026-07-25 FR-A): a bare touch RE-CREATES a claim file that reap() (or a
# finalize-tail mover) already released back to queue/ — resurrecting a lease for a card that's
# already claimable again, the exact double-claim this FR exists to prevent, arriving through the
# back door. `-c` is a no-op against a path that doesn't exist.
heartbeat() {
  local busdir="$1" id="$2" worker="$3"
  touch -c "$busdir/claimed/$id.$worker"
}

# reap <busdir> <ttl_min> — requeue claims whose heartbeat is older than ttl_min.
# Claim filenames are <id>.<worker>, worker == <lane>:<model> — strip exactly that trailing
# ".<lane>:<model>" suffix via regex (never a first-dot split: a dotted <id> like "s4r.api" would
# otherwise be mis-split into id "s4r", silently missing limits/s4r.api.frozen and double-claiming
# a still-frozen worker — CRITICAL, live audit finding). Falls back to a first-dot split only when
# the trailing token isn't a recognized lane:model (older/foreign claim names, dot-free ids only).
# Skips any id with limits/<id>.frozen: a SIGSTOP'd worker's heartbeat is stopped too; requeuing
# it would double-claim a still-frozen worker. Caveat: WORKER_TIMEOUT_SEC is wall-clock — time
# spent frozen still counts against the watchdog (a long pause can trip it on resume).
#
# spec 01 Amendment 2026-07-25 FR-A (backlog 55): a bare heartbeat-age reap can release a claim
# whose worker is still executing — the pool that owned its heartbeat subshell exited, or the
# grandchild simply outlived it. Before releasing, EITHER of two liveness checks skips the
# release: a live pid in pids/<id>, or a run-<id>.jsonl fresher than ttl_min (same clock reap
# already uses). Three binding mitigations, all load-bearing (spec's own wording):
#   1. HARD AGE CAP FIRST — a claim older than ttl_min (the lease itself) PLUS 2x this lane's
#      resolved timeout (${TIMEOUT_<LANE>:-$WORKER_TIMEOUT_SEC}) is reaped NO MATTER WHAT the
#      pid/run-log evidence says. The lease term has to be added, not just the 2x timeout alone:
#      `find`'s own `-mmin +$ttl_min` filter means the YOUNGEST claim this loop ever sees is
#      already ttl_min old, so a cap of bare `2*resolved` (600s at shipped defaults) is already
#      behind a 900s-old claim (LEASE_MIN=15) before any pid/log check runs — the cap fired first
#      on every single claim and the liveness checks were dead code (found at cross-review,
#      repro'd with a live pid + fresh log at shipped defaults). Pid reuse makes `kill -0` lie
#      forever, and a SIGKILLed spawn never reaches its own `rm -f pids/<id>` — without a cap a
#      stale claim "protected" by stale evidence would be IMMORTAL, hanging the completeness gate
#      on every future relaunch.
#   2. VACUOUS PASS — a missing pids/<id> AND a missing/stale run log is *no evidence of life*,
#      not evidence of death: the guard passes and reap proceeds exactly as it did before this FR
#      (keeps every pre-existing fixture green).
#   3. SAY WHO MOVED IT — every actual requeue this function performs logs one stderr line naming
#      mover=reap, the id, and why (age cap vs lease expiry); swarm-run.sh's finalize-tail movers
#      carry the matching mover= line on their own requeues.
reap() {
  local busdir="$1" ttl_min="$2"
  local f meta id lane
  while IFS= read -r -d '' f; do
    meta="$(_claim_meta "$busdir" "$f")"   # shared claim-filename split (spec 14 FR-6)
    id="${meta% *}"
    lane="${meta#* }"
    # frozen workers are intentionally silent — leave the claim in claimed/ until resume-worker
    # (or kill/nudge) clears limits/<id>.frozen
    [[ -f "$busdir/limits/$id.frozen" ]] && continue

    # Mitigation 1: hard age cap, checked before any liveness evidence. Empty lane token (an
    # older/foreign claim name with no recognized lane:model suffix) resolves straight to
    # WORKER_TIMEOUT_SEC — there's no per-lane key to look up.
    local var resolved age_cap mtime now
    var="TIMEOUT_${lane^^}"
    resolved="${!var:-${WORKER_TIMEOUT_SEC:-300}}"
    age_cap=$(( ttl_min * 60 + resolved * 2 ))   # cap measured PAST the lease, not from claim-mtime zero
    # `|| true`: reap races other movers by design (a concurrent swarm-ctl kill/cancel can remove
    # $f between find's snapshot and here) — a vanished claim must not take the whole pool down
    # via errexit on a failed stat.
    mtime="$(_stat_mtime "$f" || true)"
    now="$(date +%s)"
    if [[ -n "$mtime" ]] && (( now - mtime > age_cap )); then
      mv "$f" "$busdir/queue/$id.prompt"
      echo "swarm-lib: mover=reap requeued $id (lane '$lane') to queue/ — age cap (${age_cap}s)" >&2
      continue
    fi

    # Mitigation 2: skip the release when either liveness check finds evidence of a still-running
    # worker. Guard the pids/<id> read — the file may be missing or (crash mid-write) empty.
    local pid_file="$busdir/pids/$id" pid
    if [[ -s "$pid_file" ]]; then
      pid="$(<"$pid_file")"
      if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        continue
      fi
    fi
    # fresh_min given -> rc 1 on a stale/missing run log, which under `if` never trips errexit
    # (header comment on _claim_meta: only a bare `x="$(...)"` assignment needs the no-arg form).
    if _claim_meta "$busdir" "$f" "$ttl_min" >/dev/null; then
      continue
    fi

    mv "$f" "$busdir/queue/$id.prompt"
    echo "swarm-lib: mover=reap requeued $id (lane '$lane') to queue/ — lease expired" >&2
  done < <(find "$busdir/claimed" -maxdepth 1 -type f -mmin "+$ttl_min" -print0)
}

# _claim_of <busdir> <id> — resolve <id>'s claim file in claimed/, EXACTLY. A bare glob
# (claimed/"$id".*) prefix-matches: id "foo" also matches a claim named "foo.bar.claude:opus"
# (dotted id "foo.bar"), so a caller acting on "foo"'s claim could dispose of the WRONG worker's
# claim — CRITICAL, wave-7 finding 1. Splits each glob candidate via _claim_meta (below — the ONE
# place that split lives, shared with reap()) and returns only the one whose recovered id exactly
# equals <id>. Prints the matching path and returns 0; returns 1 (nothing printed) if no
# candidate's recovered id matches.
_claim_of() {
  local busdir="$1" id="$2"
  local f meta cand
  for f in "$busdir"/claimed/"$id".*; do
    [[ -e "$f" ]] || continue
    meta="$(_claim_meta "$busdir" "$f")"
    cand="${meta% *}"
    if [[ "$cand" == "$id" ]]; then
      printf '%s' "$f"
      return 0
    fi
  done
  return 1
}

# _claim_meta <busdir> <claimfile> [fresh_min] — spec 14 FR-6's shared primitive, and the ONE place
# the anchored lane-suffix split lives (reap and _claim_of above both route through it; spec 01's
# Amendment 2026-07-25 FR-A reap guard is the third consumer). A second copy of that regex anywhere
# is how reap/_claim_of drift back out of lockstep.
#
# Prints "<id> <lane>" for a claimed/<id>.<lane>:<model> filename — <lane> is empty for an
# older/foreign claim name with no recognized suffix (first-dot id split, dot-free ids only).
#
# rc encodes RUN-LOG FRESHNESS, so one call answers both questions a liveness guard has:
#   - no <fresh_min> argument  -> rc 0 always (pure parse; safe in a plain `x="$(...)"` under
#     errexit, which is why reap/_claim_of can call it bare);
#   - <fresh_min> given        -> rc 0 iff run-<id>.jsonl exists and its mtime is younger than
#     <fresh_min> MINUTES (the units reap takes). A missing run log is *no evidence of life*, not
#     evidence of death — rc 1, and the caller decides what that means.
_claim_meta() {
  local busdir="$1" claim="$2" fresh_min="${3:-}"
  local base id lane="" runlog mtime now
  base="$(basename "$claim")"
  if [[ "$base" =~ ^(.+)\.((claude|codex|gemini|glm|grok|kimi):[A-Za-z0-9._-]+)$ ]]; then
    id="${BASH_REMATCH[1]}"
    lane="${BASH_REMATCH[2]%%:*}"
  else
    id="${base%%.*}"
  fi
  printf '%s %s' "$id" "$lane"
  [[ -n "$fresh_min" ]] || return 0
  runlog="$busdir/run-$id.jsonl"
  [[ -f "$runlog" ]] || return 1
  mtime="$(_stat_mtime "$runlog")"
  [[ -n "$mtime" ]] || return 1
  now="$(date +%s)"
  (( now - mtime < fresh_min * 60 ))
}

# gate_count <busdir> — prints "<done> <live>"; live = queue/+claimed/+done/ (everything not
# cancelled). queue_n counts only *.prompt files, NOT a pinned branch's <id>.lane sidecar (FR-2b) —
# two files, one live unit of work. Counting raw files there was a real bug: it self-corrected for
# a NORMAL completion (the sidecar is rm'd alongside the done marker) but permanently over-counted
# a PARKED branch (whose sidecar is never cleaned up), so a gate keyed on done+parked>=live could
# never close. claimed/ has no analogous sidecar (one file per claim, <id>.<lane:model>).
gate_count() {
  local busdir="$1" done_n queue_n claimed_n
  done_n="$(find "$busdir/done" -maxdepth 1 -type f | wc -l)"
  queue_n="$(find "$busdir/queue" -maxdepth 1 -type f -name '*.prompt' | wc -l)"
  claimed_n="$(find "$busdir/claimed" -maxdepth 1 -type f | wc -l)"
  echo "$done_n $((queue_n + claimed_n + done_n))"
}

# _marker_line <reason-token> <retryable> <ttl> <text> — spec 14 FR-7: the ONE producer of every
# limits/ marker's body, so the format cannot drift between the library and the driver:
#
#   <ISO8601> | <reason-token> | retryable=<0|1> | ttl=<sec> | <text>
#
# <reason-token> comes from FR-7's fixed set (spec 12 FR-1's failure classes + cage-denied /
# write-target-missing + the three marker-only tokens chain-exhausted / pinned-lane-blocked /
# session-limit) — a new failure shape extends that table first and inherits a token from it.
# <text> carries repo-relative paths, ids, lane names, counts and tokens ONLY — never answer text,
# prompt text or stderr content (spec 12's scrub-by-construction doctrine; these lines get quoted
# into feedback stubs and handoff prompts, which are tracked files in a public repo). Embedded
# newlines are flattened: ALWAYS one line, or both the legacy-digit parse below and every
# `$(<file)` reader break.
_marker_line() {
  local text="${4//$'\n'/ }"
  printf '%s | %s | retryable=%s | ttl=%s | %s\n' "$(date -u +%FT%TZ)" "$1" "$2" "$3" "$text"
}

# _marker_ttl <file> <default_ttl> — spec 14 FR-7's shared parse rule, in this order:
#   1. content is all digits -> legacy TTL (an in-flight bus written by the previous build);
#   2. else the line's ttl=<sec> field;
#   3. else the caller's own baked default.
# The mirror of _marker_line: one producer, one parser (site/server.mjs:900-912 carries the same
# three rules for the cockpit countdown — LOCKSTEP, a change here is a change there).
_marker_ttl() {
  local content
  content="$(<"$1")"
  content="${content%%$'\n'*}"
  if [[ "$content" =~ ^[0-9]+$ ]]; then printf '%s' "$content"; return 0; fi
  if [[ "$content" =~ ttl=([0-9]+) ]]; then printf '%s' "${BASH_REMATCH[1]}"; return 0; fi
  printf '%s' "$2"
}

# limit_flag <busdir> <lane> [ttl_seconds] [reason-token] [text] — flip .bus/limits/<lane>.limited;
# ttl defaults to 5h, reason to `rate-limit` (spec 12 FR-1's class for this site, so the ~15
# existing call sites need no edit). Only a site with something sharper to say passes a token: FR-4's
# session-limit envelope and FR-6's downgrade path. retryable is always 1 — a .limited marker is
# TTL'd by construction, so a clock expiry can always plausibly make the lane work again (that holds
# for FR-6's `auth-death`-token downgrade too: the marker only exists because a sibling worker is
# provably serving that lane right now).
limit_flag() {
  local busdir="$1" lane="$2" ttl_seconds="${3:-18000}" reason="${4:-rate-limit}"
  local text="${5:-lane $lane rate-limited}"
  mkdir -p "$busdir/limits"
  _marker_line "$reason" 1 "$ttl_seconds" "$text" > "$busdir/limits/$lane.limited"
}

# limit_active <busdir> <lane> — rc 0 if the flag exists and is within its stored TTL (mtime-based).
limit_active() {
  local busdir="$1" lane="$2" ttl mtime now
  local f="$busdir/limits/$lane.limited"
  [[ -f "$f" ]] || return 1
  ttl="$(_marker_ttl "$f" 18000)"
  mtime="$(_stat_mtime "$f")"
  now="$(date +%s)"
  (( now - mtime < ttl ))
}

# dead_flag <busdir> <lane> [reason-token] [text] — write .bus/limits/<lane>.dead (spec 10 FR-R8).
# The file now carries an FR-7 reason line, but it is still NOT a TTL payload: lane_dead below is
# existence-only and must never learn to parse this content — an auth death does not self-heal on a
# clock, and giving it one via the back door would let a revoked credential silently return to
# rotation. Hence ttl=0, retryable=0. Cleared by that lane's own next successful finalize.
dead_flag() {
  local busdir="$1" lane="$2" reason="${3:-auth-death}" text="${4:-lane $2 auth-dead}"
  mkdir -p "$busdir/limits"
  _marker_line "$reason" 0 0 "$text" > "$busdir/limits/$lane.dead"
}

# lane_dead <busdir> <lane> — rc 0 iff the .dead flag file exists. Existence-only, deliberately NO
# TTL (unlike limit_active) — an auth-death signature doesn't self-heal on a clock, only on a
# verified successful finalize clearing the flag.
lane_dead() {
  local busdir="$1" lane="$2"
  [[ -f "$busdir/limits/$lane.dead" ]]
}

# broken_flag <busdir> <lane> [ttl_seconds] [reason-token] [text] — spec 13 FR-3 (backlog 34): flip
# .bus/limits/<lane>.broken. Same TTL'd payload/mtime mechanics as limit_flag/limit_active
# (deliberately NOT mirrored into a shared helper — two ~5-line functions is less to read than one
# parameterized one), but a much shorter default (1800s = 30m, not 5h): a lane that fast-failed
# because it's genuinely down is worth re-testing sooner than a rate-limit window. Reason defaults
# to spec 12 FR-1's class for this site, `lane-down`; retryable=0 — the lane binary/endpoint has to
# come back before the retry means anything, the TTL only bounds how long we stop asking.
broken_flag() {
  local busdir="$1" lane="$2" ttl_seconds="${3:-1800}" reason="${4:-lane-down}"
  local text="${5:-lane $lane fast-failed}"
  mkdir -p "$busdir/limits"
  _marker_line "$reason" 0 "$ttl_seconds" "$text" > "$busdir/limits/$lane.broken"
}

# lane_broken <busdir> <lane> — rc 0 if the .broken flag exists and is within its stored TTL
# (mtime-based, identical mechanics to limit_active).
lane_broken() {
  local busdir="$1" lane="$2" ttl mtime now
  local f="$busdir/limits/$lane.broken"
  [[ -f "$f" ]] || return 1
  ttl="$(_marker_ttl "$f" 1800)"
  mtime="$(_stat_mtime "$f")"
  now="$(date +%s)"
  (( now - mtime < ttl ))
}

# lane_blocked <busdir> <lane> — rc 0 iff the lane is unavailable for any reason a fallback
# resolution must route around: rate-limited (limit_active), auth-dead (lane_dead), fast-fail-
# broken (lane_broken, spec 13 FR-3), or, for kimi only, over its real-$ BUDGET_USD cap
# (kimi_budget_ok). One combined predicate so callers (pinned-wait, chain-walk, class-fallback)
# never have to remember to check budget only for kimi themselves.
lane_blocked() {
  local busdir="$1" lane="$2"
  limit_active "$busdir" "$lane" && return 0
  lane_dead "$busdir" "$lane" && return 0
  lane_broken "$busdir" "$lane" && return 0
  [[ "$lane" == kimi ]] && ! kimi_budget_ok "$busdir" && return 0
  return 1
}

# lane_has_live_worker <busdir> <lane> [exclude-id] — spec 14 FR-6: rc 0 iff the lane is PROVABLY
# alive, i.e. some OTHER claimed card on it has a run log fresher than LEASE_MIN. Three details are
# load-bearing:
# - the lane match keys on the CLAIM FILENAME's lane token, never on the model: glm/kimi/claude are
#   all the same `claude` binary under a child-env swap, and a live glm worker says nothing about
#   kimi's credentials;
# - the freshness threshold is LEASE_MIN, reap's own clock — "provably alive" then means exactly
#   "not reapable", one definition of liveness on the bus instead of two that can disagree;
# - <exclude-id> drops the dying card itself: a card is not evidence of its own lane's health.
lane_has_live_worker() {
  local busdir="$1" lane="$2" exclude="${3:-}" f meta cid clane
  for f in "$busdir"/claimed/*; do
    [[ -e "$f" ]] || continue
    # rc 1 = that sibling's run log is stale or absent -> no evidence of life, skip it.
    meta="$(_claim_meta "$busdir" "$f" "${LEASE_MIN:-15}")" || continue
    read -r cid clane <<<"$meta"
    [[ "$clane" == "$lane" ]] || continue
    [[ -n "$exclude" && "$cid" == "$exclude" ]] && continue
    return 0
  done
  return 1
}

# _flag_dead_or_downgrade <busdir> <lane> <id> <evidence> — spec 14 FR-6's one decision point, used
# by every dead_flag site in limit_error. With a live sibling on the lane the flag is DOWNGRADED,
# not skipped: the card still failed and that deserves a record, so the lane gets a short-TTL
# .broken (600s) plus .broken.evidence — never .dead.evidence, which reads to an operator as an
# auth death someone hand-cleared. `.broken`, not `.limited` (cross-review fix, backlog 54): a
# `.limited` marker is cleared by NOTHING but its own TTL, while `.broken` is also cleared the
# instant this lane finalizes ANY card successfully (_archive_and_release's `rm -f .../$bare.broken`)
# — and that finalize is imminent exactly when this guard's precondition holds (a sibling is live
# RIGHT NOW). The `.limited` form cooled a working lane for the full 600s regardless, which is the
# very harm backlog 54 was filed about. The auth-death reason token is kept on the downgraded
# marker (unchanged) so class fidelity survives the marker-type swap. Positive liveness evidence
# outranks a failure counter (Envoy's outlier-detection doctrine). Self-correcting against a
# genuine revocation: with real siblings live a truly dead lane costs one failed spawn per short
# window until they drain, after which the guard stops firing and .dead sticks with its normal
# semantics.
_flag_dead_or_downgrade() {
  local busdir="$1" lane="$2" id="$3" evidence="$4"
  mkdir -p "$busdir/limits"
  if lane_has_live_worker "$busdir" "$lane" "$id"; then
    printf '%s\n' "$evidence" > "$busdir/limits/$lane.broken.evidence"
    broken_flag "$busdir" "$lane" 600 auth-death \
      "$lane: auth-death on card $id downgraded — a sibling worker on this lane is live"
    return 0
  fi
  printf '%s\n' "$evidence" > "$busdir/limits/$lane.dead.evidence"
  dead_flag "$busdir" "$lane" auth-death "$lane: auth-death signature on card $id"
}

# _auth_death_signature <text> — spec 10 FR-R8/FR-R11: the shared auth-death substring list, reused
# everywhere a dead OAuth session might masquerade as a normal message/answer (limit_error's no-hit
# sniff and claude/gemini arms, answer_unusable). rc 0 = text matches.
_auth_death_signature() {
  grep -Eqi 'oauth session expired|failed to authenticate|not signed in|please run /login' <<<"$1"
}

# _rate_limit_signature <text> — spec 14 FR-4: the shared rate/session-limit substring list, the
# mirror of _auth_death_signature. Extracted from limit_error's claude ERROR-envelope arm and
# widened with `session limit`: the live cockpit057b envelope ("You've hit your session limit ·
# resets 2:50am") matched NONE of the original alternatives, so a claude/glm/kimi lane that had run
# out of session capacity was never flagged and every following card queued straight back onto it.
# One list, two callers (the error arm and the no-hit result-text fallback) — a future signature
# lands in one place. rc 0 = text matches.
_rate_limit_signature() {
  grep -Eqi 'usage limit|session limit|rate.?limit|too many requests|(^|[^0-9])429([^0-9]|$)' <<<"$1"
}

# jq_firehose_filter — echoes the canonical defensive jq program (bus-discipline.md "Firehose").
jq_firehose_filter() {
  cat <<'JQ'
fromjson? // empty | select(.type as $t | ["tool_use","tool_result","result","error","message","assistant","system","turn.completed","turn.failed","item.completed","text","end"] | index($t))
JQ
}

# signal_subtree <pid> <SIG> — deliver <SIG> to <pid> and every descendant. Same breadth-first
# pgrep walk as kill_subtree: snapshot the FULL pid set BEFORE signalling anything, exclude the
# caller's $BASHPID. ONLY signals — no TERM→KILL escalation, no wait. Used by pause-worker
# (SIGSTOP), resume-worker (SIGCONT), and CONT-before-TERM paths on frozen workers.
signal_subtree() {
  local root="$1" sig="$2" self="$BASHPID"
  local -a all=("$root") frontier=("$root") next
  local pid
  while (( ${#frontier[@]} )); do
    next=()
    for pid in "${frontier[@]}"; do
      # `|| true` is load-bearing, not decoration: pgrep's normal "no children" outcome is rc 1,
      # and under `shopt -s inherit_errexit` a failing command SUBSTITUTION trips errexit even
      # inside an array-append assignment — reproduced live, docs/02-build-pitfalls.md territory.
      # shellcheck disable=SC2207  # pgrep prints bare pids, one per line — safe to word-split
      next+=($(pgrep -P "$pid" 2>/dev/null || true))
    done
    (( ${#next[@]} )) || break
    all+=("${next[@]}")
    frontier=("${next[@]}")
  done
  # Plain while + `i=$(( i - 1 ))` on purpose, not a C-style `for ((...))`: its update clause
  # evaluates to 0 (falsy) on the last iteration, which trips `set -e` on this bash (the same
  # class of gotcha as `((var++))` at var=0 — an assignment's own exit status is always 0,
  # regardless of the computed value, so it doesn't trigger errexit).
  local i=$(( ${#all[@]} - 1 ))
  while (( i >= 0 )); do
    if [[ "${all[i]}" != "$self" ]]; then
      kill -s "$sig" "${all[i]}" 2>/dev/null || true
    fi
    i=$(( i - 1 ))
  done
}

# kill_subtree <pid> [signal, default TERM] — signal <pid> and every descendant (via
# signal_subtree). Used by the FR-12 watchdog, the FR-13 driver-death sweep, and `swarm-ctl kill`.
kill_subtree() {
  signal_subtree "$1" "${2:-TERM}"
}

# _scratch_home <busdir> <lane> — an isolated $HOME for this lane's worker, created under the bus,
# never the real $HOME (containment gate, DECISIONS.md Q2). gemini and glm authenticate purely via
# an env-var token (GEMINI_API_KEY / ANTHROPIC_AUTH_TOKEN), so they get a bare empty scratch home.
# claude (native) and codex have no env-only auth path — codex's --api-key flag is gone (auth.json
# only, docs/02-build-pitfalls.md #11), claude native is OAuth-session-based — so for those two we
# copy in ONLY the one credential file each CLI actually needs, fresh on every spawn, never the
# whole real $HOME (~/.claude has project history, agents, helpers, ... none of which a worker
# needs or should be able to read).
# [NEEDS CLARIFICATION]: never live-smoke-tested against a real headless run — if either CLI's own
# startup needs anything else under $HOME (onboarding checks, ...) it will surface as a
# lane_cmd/worker failure here rather than us silently widening to the real $HOME. (codex
# config.toml graduated from this list to a deliberate mirror — spec 04 amendment 2026-07-26.)
# Multi-account gotcha (found live, docs/02-build-pitfalls.md #19): the orchestrator session may
# run under CLAUDE_CONFIG_DIR (multi-account claude setups) — that account's credentials are the
# LIVE ones, not necessarily $HOME/.claude's (which can be a different/stale account). claude
# credentials are sourced from CLAUDE_CONFIG_DIR when set, but the copy's DESTINATION inside the
# scratch home stays .claude/ regardless: lane_cmd's `env -i` strips CLAUDE_CONFIG_DIR from the
# caged worker's env, so the caged claude binary falls back to its own default lookup ($HOME/.claude
# — which IS the scratch home there). A caged claude that fails auth can rewrite this copy
# (expiresAt -> 0) — harmless, since every spawn re-copies fresh from the real source.
_scratch_home() {
  local busdir="$1" lane="$2" id="${3:-}"
  # Per-WORKER cage when an id is given ($lane.$id), not per-lane: with same-lane FANOUT > 1,
  # concurrent spawns sharing one $busdir/home/$lane stomp each other via the grok branch's
  # rm -rf (live finding: 4 parallel grok spawns sharing one home -> "Not signed
  # in" x4). id-less callers keep the old per-lane path.
  local home="$busdir/home/$lane${id:+.$id}"  # separate `local` on purpose — see kill_subtree's
                                              # note above: `local a=$1 c=$a/x` in one statement
                                              # is unbound under set -u
  mkdir -p "$home"
  chmod 700 "$home" 2>/dev/null || true  # cage holds copied OAuth credential files — owner-only
  case "$lane" in
    claude)
      mkdir -p "$home/.claude"
      local claude_src="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
      [[ -f "$claude_src/.credentials.json" ]] \
        && cp -f "$claude_src/.credentials.json" "$home/.claude/.credentials.json"
      [[ -f "$HOME/.claude.json" ]] && cp -f "$HOME/.claude.json" "$home/.claude.json"
      ;;
    codex)
      mkdir -p "$home/.codex"
      [[ -f "$HOME/.codex/auth.json" ]] && cp -f "$HOME/.codex/auth.json" "$home/.codex/auth.json"
      # config.toml carries reasoning effort + output tuning; without it the caged CLI falls back
      # to reasoning_effort:none — a silent quality downgrade (spec 04 amendment 2026-07-26,
      # backlog 49). CODEX arm only: grok's config exclusion is a locked containment decision.
      [[ -f "$HOME/.codex/config.toml" ]] && cp -f "$HOME/.codex/config.toml" "$home/.codex/config.toml"
      ;;
    grok)
      # xAI Grok Build CLI: OAuth file auth (~/.grok/auth.json, mode 600), not an env-var key —
      # same "copy the one needed credential file" posture as claude/codex. Deliberately NOT
      # config.toml (wires MCP servers into the caged worker — scope creep past the containment
      # gate) or trusted_folders.toml (probe-verified 2026-07-19: a caged run in an untrusted dir
      # succeeded without it, so it's dead weight, not a requirement). The scratch home dir is
      # reused across spawns — rm -rf before mkdir so stale state from a prior spawn never
      # survives; install -m 600 sets the OAuth file's mode explicitly rather than inheriting
      # whatever mode the source happens to have.
      rm -rf "$home/.grok"
      mkdir -p "$home/.grok"
      [[ -f "$HOME/.grok/auth.json" ]] && install -m 600 "$HOME/.grok/auth.json" "$home/.grok/auth.json"
      ;;
    gemini | glm | kimi) : ;;  # pure env-var auth — nothing to copy
  esac
  printf '%s' "$home"
}

# _stagger_first_spawn <busdir> <bare_lane> <id> — spec 04 amendment 2026-07-26 (backlog 20):
# same-lane first-spawn auth herd. N simultaneous FIRST spawns on one lane all hit the provider's
# auth/rate gate at t=0 (live incident: 4 parallel grok first-spawns, "Not signed in" ×4). The
# first caller per bare lane per run claims the marker atomically (mkdir) and proceeds at once;
# every later same-lane caller waits — bounded by STAGGER_FIRST_SPAWN_SEC — until that first
# worker's run log shows output bytes (auth demonstrably works) or the bound expires. Always
# returns 0: the stagger's job is de-simultaneity, never health — a wedged first spawn must not
# park the lane (spec 13's markers own that). Cross-lane parallelism untouched (per-lane marker);
# only the run's FIRST spawn per lane ever waits — once run-<first>.jsonl has bytes, every later
# caller falls through on its first poll.
_stagger_first_spawn() {
  local busdir="$1" bare="$2" id="$3" mark="$1/limits/.first-$2"
  (( ${STAGGER_FIRST_SPAWN_SEC:-10} > 0 )) || return 0
  if mkdir "$mark" 2>/dev/null; then
    printf '%s' "$id" > "$mark/id"
    return 0
  fi
  local firstid i ticks=$(( ${STAGGER_FIRST_SPAWN_SEC:-10} * 4 ))
  for (( i = 0; i < ticks; i++ )); do
    firstid="$(cat "$mark/id" 2>/dev/null || true)"
    [[ -n "$firstid" && -s "$busdir/run-$firstid.jsonl" ]] && return 0
    sleep 0.25
  done
  return 0
}

# _env_master_path — spec 21 FR-8 (backlog 78): THE env-master path resolver, shared by
# _env_master_key and env_master_preflight so the twin defaults can never disagree (bh065: the
# preflight aborted on the XDG default while the box's documented secrets master sat readable at
# ~/s/.env.master). Resolution order:
#   1. explicit $ENV_MASTER_FILE — returned VERBATIM even when unreadable (an explicit override is
#      authoritative; silently falling back would hand a run a secrets file the operator did not
#      name, which is worse than a loud abort);
#   2. $XDG_CONFIG_HOME/unimatrix/env.master (the baked default), if readable;
#   3. $HOME/s/.env.master (the house-standard secrets mirror), if readable;
#   4. the XDG default path again — unreadable, but the right path for an abort message to name.
_env_master_path() {
  if [[ -n "${ENV_MASTER_FILE:-}" ]]; then
    printf '%s' "$ENV_MASTER_FILE"
    return 0
  fi
  local xdg="${XDG_CONFIG_HOME:-$HOME/.config}/unimatrix/env.master"
  if [[ -r "$xdg" ]]; then printf '%s' "$xdg"; return 0; fi
  if [[ -r "$HOME/s/.env.master" ]]; then printf '%s' "$HOME/s/.env.master"; return 0; fi
  printf '%s' "$xdg"
}

# _env_master_key <NAME> — grep one key out of the env-master file into stdout (least-privilege;
# never `source` the whole file — a KEY=VALUE secrets dump often isn't safely bash-sourceable, and
# a worker needs only its own key). Path resolution: _env_master_path (spec 21 FR-8) — explicit
# $ENV_MASTER_FILE, else the first readable candidate. rc 1 (loud) if missing.
_env_master_key() {
  local name="$1" f val
  f="$(_env_master_path)"
  if [[ ! -f "$f" ]]; then
    echo "_env_master_key: $f not found (need $name)" >&2
    return 1
  fi
  val="$(grep -m1 "^${name}=" "$f" | cut -d= -f2-)"
  val="${val%\"}"; val="${val#\"}"
  val="${val%\'}"; val="${val#\'}"
  if [[ -z "$val" ]]; then
    echo "_env_master_key: $name not found in $f" >&2
    return 1
  fi
  printf '%s' "$val"
}

# env_master_preflight <busdir> [mode] — spec 13 FR-1 (backlog 36): launch-time abort, BEFORE any spawn,
# when this run's lane set needs an env-key lane and $ENV_MASTER_FILE isn't even reachable — the
# grpnrev incident (a missing env-master path parked an entire run one card at a time instead of
# refusing up front). Computes the bare-lane set in play as the union of EXEC_CHAIN, REVIEW/
# REVIEW_CHAIN tokens, and any *.lane pin sidecars (checked in both specs/ and queue/ — this can run
# before OR after _enqueue_pending_specs has moved a wave's pins across that boundary). If that set
# intersects {gemini, glm, kimi} (the three env-key lanes) and the file is unreadable, prints the
# resolved path plus the fix and returns 1; a claude/codex-only lane set is unaffected regardless of
# the file's state. Reachability only, not contents — a readable file simply missing one lane's key
# is still a normal spawn-time lane_cmd/_env_master_key failure (unchanged, this function's
# non-goal).
# Deliberately does NOT fold in VERIFY_MAP/PLAN_CHAIN/ORCH_CHAIN despite FR-1's prose listing them:
# all three BAKE an env-key lane (kimi) into their conf_load DEFAULT regardless of EXEC_CHAIN
# content (VERIFY_MAP's default verifier side names glm/gemini/kimi; PLAN_CHAIN/ORCH_CHAIN both
# default to "... kimi" as the succession fallback) — including them would trip this preflight on
# every run out of the box, even a plain claude/codex EXEC_CHAIN, which directly contradicts
# acceptance criterion 1's own worked example ("a claude/codex-only run... proceeds").
# PLAN_CHAIN/ORCH_CHAIN only spawn via the succession watchdog outside this run's own fan-out.
# mode=="verify" (round-4 MAJ) is the exception FR-1 always intended: the verify wave DOES spawn
# VERIFY_MAP lanes, so it folds in the verifier ACTUALLY resolved for each already-done branch
# (verify_lane_for against done/<id>'s served lane) — not the raw VERIFY_MAP table, whose baked
# kimi/glm/gemini entries would trip every claude/codex run for lanes it will never spawn.
env_master_preflight() {
  local busdir="$1" mode="${2:-full}"
  local -a bare=()
  local tok f lane
  for tok in $EXEC_CHAIN $REVIEW ${REVIEW_CHAIN:-}; do
    bare+=("${tok%%:*}")
  done
  if [[ "$mode" == verify ]]; then
    local d gen v
    for d in "$busdir"/done/*; do
      [[ -f "$d" ]] || continue
      [[ "$(basename "$d")" == v-* ]] && continue
      gen="$(jq -r '.lane // empty' "$d" 2>/dev/null || true)"
      [[ -n "$gen" ]] || continue
      v="$(verify_lane_for "$gen" "$busdir" 2>/dev/null || true)"
      [[ -n "$v" ]] && bare+=("${v%%:*}")
    done
  fi
  for f in "$busdir"/specs/*.lane "$busdir"/queue/*.lane; do
    [[ -e "$f" ]] || continue
    lane="$(<"$f")"
    bare+=("${lane%%:*}")
  done

  local b
  local -a needkeys=()
  for b in "${bare[@]}"; do
    case "$b" in
      gemini) needkeys+=(GEMINI_API_KEY) ;;
      glm) needkeys+=(Z_AI_CODING_KEY) ;;
      kimi) needkeys+=(MOONSHOT_API_KEY) ;;
    esac
  done
  (( ${#needkeys[@]} > 0 )) || return 0

  local envf
  envf="$(_env_master_path)"
  if [[ ! -r "$envf" ]]; then
    # spec 21 FR-8: name the key(s) the tripping lane(s) actually grep for — the operator's next
    # move is "which file has THESE" — and print a copy-paste export line, pointed at a readable
    # candidate elsewhere when one exists (the explicit-override-unreadable case: _env_master_path
    # honored $ENV_MASTER_FILE verbatim, but a usable candidate may still sit at a default path).
    local keylist
    keylist="$(printf '%s\n' "${needkeys[@]}" | sort -u | paste -sd' ' -)"
    echo "swarm: this run's lane set needs an env-key lane (gemini/glm/kimi) but the env-master file is unreadable: $envf" >&2
    echo "swarm: the lane(s) need: $keylist" >&2
    local cand="" c
    for c in "${XDG_CONFIG_HOME:-$HOME/.config}/unimatrix/env.master" "$HOME/s/.env.master"; do
      [[ -r "$c" && "$c" != "$envf" ]] && { cand="$c"; break; }
    done
    echo "swarm: fix: export ENV_MASTER_FILE=${cand:-<your secrets file>}" >&2
    return 1
  fi
  return 0
}

# lane_cmd <lane:model> <id> <busdir> — populates the global array LANE_ARGV with the exact
# worker invocation for this lane (specs/01-swarm-core.md "Lane invocations", source of truth).
# Reads the prompt from claimed/<id>.<lane:model> (claim() already moved it there). rc 1 (loud,
# stderr) on an unknown/unspawnable lane or a missing per-lane key — never a silent no-op.
# Every invocation is wrapped in `env -i PATH=... HOME=<scratch> LANG=...` (containment gate,
# DECISIONS.md Q2) — the worker never sees the orchestrator's ambient env, only what's listed here.
# FR-15: a queue/<id>.write sidecar (mirrors the .lane pin sidecar's own lifecycle exactly — a
# plain file left sitting in queue/ for the whole claim, since claim() only ever renames the
# .prompt file) scopes claude/glm to `--permission-mode acceptEdits` + CWD = the target dir (via
# GNU env's own -C — neither lane has a per-invocation cwd flag of its own), codex to its native
# -C/-s workspace-write against the same target, and gemini to a loud refusal (not a write-capable
# lane in v1). Absent sidecar -> read-only behavior; for codex that means its native `-s read-only`
# sandbox (backlog-32 — a plain card must never get workspace-write against the busdir parent).
lane_cmd() {
  local lanemodel="$1" id="$2" busdir="$3"
  local lane="${lanemodel%%:*}" model="${lanemodel#*:}"
  local prompt_file="$busdir/claimed/$id.$lanemodel" prompt
  prompt="$(<"$prompt_file")" 2>/dev/null || {
    echo "lane_cmd: no claim file $prompt_file" >&2
    return 1
  }

  local write_target=""
  [[ -f "$busdir/queue/$id.write" ]] && write_target="$(<"$busdir/queue/$id.write")"

  local home
  home="$(_scratch_home "$busdir" "$lane" "$id")"
  # shellcheck disable=SC2034  # consumed by swarm-run.sh's _spawn_worker (grok token write-back)
  LANE_HOME="$home"  # global, like LANE_ARGV
  # CDWRAP: portable chdir for the write-capable lanes. GNU env has `-C <dir>` (used directly in
  # envbase); BSD/macOS env doesn't, so there we keep envbase without -C and instead splice a
  # `bash -c 'cd …'` wrapper in right before the worker binary (after any lane VAR=VAL assignments).
  # On GNU (ENV_HAS_C=1) CDWRAP stays empty and every lane's argv is byte-for-byte what it was.
  local -a envbase=(env -i "PATH=$PATH" "HOME=$home" "LANG=C.UTF-8") CDWRAP=()
  if [[ -n "$write_target" ]]; then
    if (( ENV_HAS_C )); then
      envbase=(env -i -C "$write_target" "PATH=$PATH" "HOME=$home" "LANG=C.UTF-8")
    else
      # shellcheck disable=SC2016  # $1/$@ are for the INNER bash -c, must NOT expand here
      CDWRAP=(bash -c 'cd "$1" && shift && exec "$@"' _ "$write_target")
    fi
  fi

  LANE_ARGV=()
  case "$lane" in
    claude)
      LANE_ARGV=("${envbase[@]}" "${CDWRAP[@]}" claude -p --output-format stream-json --verbose --model "$model")
      # acceptEdits, never --dangerously-skip-permissions (containment) — live-verified 2026-07-08
      # under this exact env -i + scratch-HOME cage: writes land, no prompt, no --add-dir needed
      # (the CWD itself is auto-trusted under -p).
      [[ -n "$write_target" ]] && LANE_ARGV+=(--permission-mode acceptEdits)
      LANE_ARGV+=("$prompt")
      ;;
    codex)
      # backlog-32 (containment): no sidecar -> codex's native read-only sandbox; only a write
      # card gets workspace-write, and then only against its own target.
      local cdir sandbox=read-only
      cdir="$(dirname "$busdir")"
      [[ -n "$write_target" ]] && { cdir="$write_target"; sandbox=workspace-write; }
      LANE_ARGV=("${envbase[@]}" codex exec --json --output-last-message "$busdir/res-$id.txt"
                 -s "$sandbox" --skip-git-repo-check -C "$cdir")
      [[ "$model" == "default" ]] || LANE_ARGV+=(-m "$model")
      LANE_ARGV+=(--ephemeral "$prompt")
      ;;
    gemini)
      # gemini is NOT a write-capable lane in v1 (web/research lane) — refuse loudly rather than
      # silently ignoring the sidecar. The caller's existing "lane_cmd failed" handling (wrc=9 in
      # swarm-run.sh) chain-advances or parks this exactly like a missing key would.
      if [[ -n "$write_target" ]]; then
        echo "lane_cmd: gemini is not a write-capable lane in v1 — refusing write request for $id (target $write_target)" >&2
        return 1
      fi
      local gkey
      gkey="$(_env_master_key GEMINI_API_KEY)" || return 1
      # NO --sandbox (live E2E finding 2026-07-08, reverses the earlier speculative addition):
      # gemini's `--sandbox` isn't a lightweight isolation flag — per its own bundled docs
      # (docs/cli/sandbox.md), it re-execs the ENTIRE CLI inside a Docker/Podman container
      # (default image `ghcr.io/google/gemini-cli:latest`, pulled over the network on first use),
      # and that re-exec only forwards its OWN internal env allowlist into the container — NOT
      # GEMINI_CLI_TRUST_WORKSPACE. Live: every sandboxed attempt exited 55 ("not running in a
      # trusted directory") because the trust var never reached the containerized process, even
      # though it's correctly present in the argv we build below. This IS the "docker dependency"
      # the original task said not to add — it just wasn't visible until a real invocation
      # exercised it. Fixed by dropping --sandbox rather than chasing an opaque container
      # launcher's env-forwarding; containment for this lane is still the scratch HOME + the one
      # granted key + no ambient env (this file's `env -i`). A real container sandbox for the
      # web-facing lane — custom image + explicit env-forwarding, not gemini's own opaque
      # launcher — is now FR-16 below (GEMINI_SANDBOX=docker), opt-in.
      # FR-16: opt-in containerized gemini lane (GEMINI_SANDBOX=docker, swarm.conf key, default
      # off). ONLY the contract env is forwarded, via a BARE `-e NAME` allowlist whose values are
      # set in the caged docker-client env below (the `env -i` base scrubbed the orchestrator's
      # ambient env, so bare `-e NAME` forwards exactly our value, never an ambient one — AND keeps
      # the plaintext key out of docker's argv / /proc/<pid>/cmdline; see the detailed note at the
      # LANE_ARGV assignment). No -v/--mount, ever: this lane needs no repo access, and
      # prompt-injected web content must land in an empty container, not the host filesystem.
      # Docker missing/unusable is a loud lane_cmd failure
      # here; an unpullable image or a container that fails to start surfaces later as the
      # worker's own nonzero exit, which the existing chain-advance/park handling already covers
      # — never a silent fallback to an unsandboxed spawn either way.
      if [[ "${GEMINI_SANDBOX:-}" == docker ]]; then
        command -v docker >/dev/null 2>&1 || {
          echo "lane_cmd: GEMINI_SANDBOX=docker requested but 'docker' not found on PATH — refusing (never a silent unsandboxed fallback)" >&2
          return 1
        }
        # The key is set in the CAGED docker-client env (the env -i base already scrubbed the
        # orchestrator's ambient env, so the only GEMINI_API_KEY the client sees is this one) and
        # forwarded with a BARE `-e NAME` — never `-e NAME=value`, which would put the plaintext key
        # in docker's argv, i.e. in /proc/<pid>/cmdline for the whole container lifetime. Under the
        # cage, bare `-e NAME` forwards exactly our value (there is no ambient value to leak), so it
        # keeps the FR-16 explicit-allowlist guarantee while keeping the secret out of argv.
        LANE_ARGV=("${envbase[@]}" "GEMINI_API_KEY=$gkey" GEMINI_CLI_TRUST_WORKSPACE=true
                   docker run --rm -i
                   -e GEMINI_API_KEY -e GEMINI_CLI_TRUST_WORKSPACE
                   unimatrix-gemini-lane:0.49.0
                   gemini -m "$model" -o stream-json -p "$prompt")
      else
        # Prompt-injection hardening: run gemini with CWD = the empty scratch home, never the
        # caller's repo. GEMINI_CLI_TRUST_WORKSPACE=true trusts the CWD, so an untrusted CWD = the
        # repo would let injected web content read local files. GNU env's -C sets it directly; on
        # BSD/macOS env (no -C) a portable `bash -c 'cd …'` wrapper does. Read-only branch only —
        # the docker branch above already isolates in a mount-less container.
        if (( ENV_HAS_C )); then
          LANE_ARGV=(env -i -C "$home" "PATH=$PATH" "HOME=$home" "LANG=C.UTF-8"
                     GEMINI_CLI_TRUST_WORKSPACE=true "GEMINI_API_KEY=$gkey"
                     gemini -m "$model" -o stream-json -p "$prompt")
        else
          # shellcheck disable=SC2016  # $1/$@ are for the INNER bash -c cd wrapper, not this shell
          LANE_ARGV=(env -i "PATH=$PATH" "HOME=$home" "LANG=C.UTF-8"
                     GEMINI_CLI_TRUST_WORKSPACE=true "GEMINI_API_KEY=$gkey"
                     bash -c 'cd "$1" && shift && exec "$@"' _ "$home"
                     gemini -m "$model" -o stream-json -p "$prompt")
        fi
      fi
      ;;
    glm)
      # There's no --model flag for z.ai (specs/04-settings.md FR-4) — claude -p picks a TIER
      # (haiku/sonnet/opus, default sonnet) internally and resolves it via these three envs. Live
      # E2E finding 2026-07-08: hardcoding distinct per-tier models (haiku=glm-4.7, sonnet/opus=
      # glm-5.2) meant a `glm:glm-4.7` pin was silently served by glm-5.2 (whatever tier claude
      # picked) — 3x quota billed instead of 1x. Fix: all three envs = the ONE requested model, so
      # whichever tier gets picked resolves to the model that was actually pinned.
      # rules/unimatrix/model-lanes.md's `env -u ANTHROPIC_API_KEY` requirement is superseded, not
      # violated: `env -i` starts from nothing, so ANTHROPIC_API_KEY can never be present to begin
      # with — no `-u` needed to subtract it.
      local zkey
      zkey="$(_env_master_key Z_AI_CODING_KEY)" || return 1
      LANE_ARGV=("${envbase[@]}"
                 ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic
                 "ANTHROPIC_AUTH_TOKEN=$zkey"
                 "ANTHROPIC_DEFAULT_HAIKU_MODEL=$model"
                 "ANTHROPIC_DEFAULT_SONNET_MODEL=$model"
                 "ANTHROPIC_DEFAULT_OPUS_MODEL=$model"
                 API_TIMEOUT_MS=3000000
                 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
                 "MAX_THINKING_TOKENS=${GLM_MAX_THINKING_TOKENS:-6000}"
                 "${CDWRAP[@]}" claude -p --output-format stream-json --verbose)
      # Thinking cap: 2026-07-19 telemetry — GLM wall time was 93-97% API wait, dominated by
      # single turns rat-holing into 60-200k-char thinking blocks (one 629s gap = 68% of a run).
      # 6000 default keeps some reasoning; GLM_MAX_THINKING_TOKENS=0 disables thinking outright.
      # GLM IS the claude binary underneath (child-env swap only) — same acceptEdits contract.
      [[ -n "$write_target" ]] && LANE_ARGV+=(--permission-mode acceptEdits)
      LANE_ARGV+=("$prompt")
      ;;
    kimi)
      # Moonshot AI, Anthropic-compat PAYG endpoint — same env-i + tier-env-selector trick as glm,
      # pointed at a different base URL/key (rules/unimatrix/model-lanes.md "Kimi spawn contract").
      # Temperature quirk (do not "fix"): Moonshot's endpoint rescales temperature x0.6 server-side;
      # claude -p exposes no per-run temperature knob here, so there's nothing to configure for it.
      # Sub (ANTHROPIC_API_KEY) variant delta lives in model-lanes.md, not implemented (not live).
      local kkey
      kkey="$(_env_master_key MOONSHOT_API_KEY)" || return 1
      LANE_ARGV=("${envbase[@]}"
                 ANTHROPIC_BASE_URL=https://api.moonshot.ai/anthropic
                 "ANTHROPIC_AUTH_TOKEN=$kkey"
                 "ANTHROPIC_DEFAULT_HAIKU_MODEL=$model"
                 "ANTHROPIC_DEFAULT_SONNET_MODEL=$model"
                 "ANTHROPIC_DEFAULT_OPUS_MODEL=$model"
                 API_TIMEOUT_MS=3000000
                 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
                 # Same claude-binary thinking rat-hole class as GLM (2026-07-19 telemetry), but
                 # here runaway thinking bills REAL $ at $15/M out, not pool quota — operator
                 # override via KIMI_MAX_THINKING_TOKENS.
                 "MAX_THINKING_TOKENS=${KIMI_MAX_THINKING_TOKENS:-6000}"
                 "${CDWRAP[@]}" claude -p --output-format stream-json --verbose)
      [[ -n "$write_target" ]] && LANE_ARGV+=(--permission-mode acceptEdits)
      LANE_ARGV+=("$prompt")
      ;;
    grok)
      # xAI Grok Build CLI — OAuth file auth (~/.grok/auth.json, copied into the scratch HOME by
      # _scratch_home above), NOT an env-var key like gemini/glm, so no _env_master_key lookup
      # here. Read-only default: --tools read_file,grep,list_dir --no-subagents (containment,
      # mirrors gemini's read-only lane posture). model=="default" omits -m (mirrors codex — grok's
      # own default is already correct, nothing to override). FR-15 write mode: explicit
      # `--allow Write/Edit/Create` rules — NOT `--permission-mode acceptEdits`, which silently
      # dies with stopReason "Cancelled" on turn 1 whenever $HOME is not the real OS home (the
      # write-tool path hard-checks it; probe-verified 2026-07-19: real HOME works, any scratch/
      # symlinked HOME cancels; explicit allow rules bypass the check; path-scoped rule args like
      # `Write(/dir/**)` are NOT supported — they match nothing and everything gets denied).
      # KNOWN TRADEOFF: the allow rules are tool-level, not path-fenced — grok write workers are
      # contained by the env -i cage + scratch HOME + controlled prompts, not by a write-path
      # fence. --yolo/bypassPermissions/--always-approve remain FORBIDDEN outright (containment
      # gate, no exceptions, same as every other lane). CWD is handled by the generic `env -C
      # <write_target>` already built into envbase above — no lane-specific cwd flag needed.
      LANE_ARGV=("${envbase[@]}" "${CDWRAP[@]}" grok -p "$prompt" --output-format streaming-json --no-auto-update)
      # Reasoning effort: grok's CLI defaults to "high" — 10-17s time-to-first-token per turn
      # (2026-07-19 speed research). "medium" is the speed default; GROK_EFFORT= (empty) restores
      # the CLI default for hard tasks. `${VAR-default}` (no colon) is load-bearing: `:-` also
      # substitutes on EMPTY, so the guard could never be false and --effort was always emitted —
      # the documented "empty restores the CLI's own high default" was unreachable.
      [[ -n "${GROK_EFFORT-medium}" ]] && LANE_ARGV+=(--effort "${GROK_EFFORT-medium}")
      if [[ -n "$write_target" ]]; then
        LANE_ARGV+=(--allow Write --allow Edit --allow Create)
      else
        # shellcheck disable=SC2054  # commas are the grok CLI's own --tools list syntax, one
        # array element, not a (missing) bash array separator
        LANE_ARGV+=(--tools read_file,grep,list_dir --no-subagents)
      fi
      [[ "$model" == "default" ]] || LANE_ARGV+=(-m "$model")
      ;;
    fable)
      echo "lane_cmd: 'fable' is plan/orchestrator only — never spawned" >&2
      return 1
      ;;
    *)
      echo "lane_cmd: unknown lane '$lane'" >&2
      return 1
      ;;
  esac
}

# extract_answer <lane> <id> <busdir> — normalize this lane's own handoff shape down to a single
# .bus/res-<id>.txt so downstream (the gate, synthesis) is lane-agnostic. rc 1 if no result found.
extract_answer() {
  local lane="$1" id="$2" busdir="$3"
  local runlog="$busdir/run-$id.jsonl" resfile="$busdir/res-$id.txt" field ans

  case "$lane" in
    codex)
      [[ -s "$resfile" ]] || return 1
      return 0
      ;;
    gemini)
      # Real 0.49 stream-json (live-verified 2026-07-08, corrects the research digest this was
      # originally built on): the `result` event carries ONLY {stats,status,timestamp,type} — no
      # `.response` field. The answer is the concatenation of the assistant `message` deltas.
      [[ -f "$runlog" ]] || return 1
      ans="$(jq -R -c 'fromjson? // empty' "$runlog" \
        | jq -j 'select(.type == "message" and .role == "assistant") | .content')"
      [[ -n "$ans" ]] || return 1
      printf '%s' "$ans" > "$resfile"
      return 0
      ;;
    grok)
      # streaming-json NDJSON (probe-verified 2026-07-19, grok CLI 0.2.103): the answer is the
      # concatenation of every type=="text" event's .data, in order — gemini-pattern jq (thought
      # chunks are firehose-only noise, never part of the answer, deliberately excluded here).
      [[ -f "$runlog" ]] || return 1
      # A worker that dies mid-answer still emits text chunks before its type=="error" event —
      # only trust the answer if the stream's last terminal event (end or error) is "end".
      local terminal
      terminal="$(jq -R -c 'fromjson? // empty' "$runlog" \
        | jq -s -r '[.[] | select(.type == "end" or .type == "error")] | last | .type')"
      [[ "$terminal" == "end" ]] || return 1
      ans="$(jq -R -c 'fromjson? // empty' "$runlog" \
        | jq -j 'select(.type == "text") | .data')"
      [[ -n "$ans" ]] || return 1
      printf '%s' "$ans" > "$resfile"
      return 0
      ;;
    claude | glm | kimi) field=result ;;
    *)
      echo "extract_answer: unknown lane '$lane'" >&2
      return 1
      ;;
  esac

  [[ -f "$runlog" ]] || return 1
  ans="$(jq -R -c 'fromjson? // empty' "$runlog" \
    | jq -s -r --arg f "$field" 'map(select(.type == "result")) | last | if . then (.[$f] // empty) else empty end')"
  [[ -n "$ans" ]] || return 1
  printf '%s' "$ans" > "$resfile"
}

# served_model <lane> <busdir> <id> — the model that ACTUALLY answered, read from the CLI's own
# envelope, never the requested lane:model token: both gemini and z.ai are known to silently
# alias/upgrade the requested model (rules/unimatrix/model-lanes.md; live E2E finding 2026-07-08 —
# a glm-4.7 pin was served by glm-5.2). Echoes empty if this lane's envelope doesn't carry a
# determinable served model (codex: no such field in our captured shape).
served_model() {
  local lane="$1" busdir="$2" id="$3"
  local runlog="$busdir/run-$id.jsonl"
  [[ -f "$runlog" ]] || return 0
  case "$lane" in
    claude | glm | kimi)
      jq -R -c 'fromjson? // empty' "$runlog" \
        | jq -s -r 'map(select(.type == "assistant")) | last | (.message.model // empty)'
      ;;
    gemini)
      jq -R -c 'fromjson? // empty' "$runlog" \
        | jq -s -r 'map(select(.type == "result")) | last | (.stats.models // {} | keys | .[0] // empty)'
      ;;
    grok)
      # Probe: requested grok-4.5, served grok-4.5-build — the CLI silently aliases (same class of
      # aliasing as gemini/z.ai above). Served model lives in the keys of .modelUsage on the LAST
      # type=="end" event — write mode permits subagents, which land under their own modelUsage
      # key, so join ALL keys rather than taking just the first (jq keys are sorted, so the join
      # order is deterministic).
      jq -R -c 'fromjson? // empty' "$runlog" \
        | jq -s -r 'map(select(.type == "end")) | last | ((.modelUsage // {} | keys | join(",")) // empty)'
      ;;
    *) : ;;
  esac
}

# limit_error <lane> <busdir> <id> — scan run-<id>.jsonl for a rate/usage-limit signature.
# rc 0 = no limit signal (normal task outcome either way — caller decides success/retry).
# rc 1 = fail over now (this call already flipped .bus/limits/<lane>.limited).
# rc 2 = transient/first-strike — retry the SAME lane, do not fail over yet.
# NOTE: the exact nested field path z.ai/codex use to surface a 429 through claude/codex's own
# stream-json envelope has not been captured live (docs/01-feasibility-tests.md never hit a real
# rate limit) — this parses the structured shape documented in research (error.code/.code,
# error.message/.message, error.next_flush_time/.next_flush_time) defensively either nested or
# top-level. Recommend a live-fire smoke test once a real 429 can be observed.
limit_error() {
  local lane="$1" busdir="$2" id="$3"
  local runlog="$busdir/run-$id.jsonl"
  [[ -f "$runlog" ]] || return 0

  local hit code_num code_str msg next_flush
  hit="$(jq -R -c 'fromjson? // empty' "$runlog" \
    | jq -s -c 'map(select(.type == "error" or .type == "turn.failed")) | last // empty')"

  if [[ -z "$hit" || "$hit" == "null" ]]; then
    # claude/gemini (spec 10 FR-R8): an OAuth-death run emits NO error/turn.failed event at all —
    # it looks like a normal result whose text IS the auth error. Sniff the last result event's
    # text here (same signature list as answer_unusable) before falling through to the plain
    # no-signal return, or a dead lane would never be flagged for these two.
    # spec 14 FR-4 widens this arm twice: glm and kimi join it (same `claude` binary under a
    # child-env swap — identical envelope), and after auth-death misses, the same text is tested for
    # a rate/session limit. SINGLE strike, no .strikes counter: is_error:true PLUS the literal
    # session-limit text is unambiguous, unlike the bare rate messages the codex/kimi 2-strike rule
    # exists for.
    case "$lane" in
      claude | gemini | glm | kimi)
        local last_result last_text last_is_error
        last_result="$(jq -R -c 'fromjson? // empty' "$runlog" \
          | jq -s -c 'map(select(.type == "result")) | last // empty')"
        if [[ -n "$last_result" && "$last_result" != "null" ]]; then
          last_text="$(jq -r '.result // empty' <<<"$last_result")"
          if _auth_death_signature "$last_text"; then
            _flag_dead_or_downgrade "$busdir" "$lane" "$id" "$last_result"
            return 1
          fi
          last_is_error="$(jq -r '.is_error // empty' <<<"$last_result")"
          if [[ "$last_is_error" == "true" ]] && _rate_limit_signature "$last_text"; then
            # TTL from the envelope's own "resets <h:mm><am|pm> (<TZ>)" clause — same precedent as
            # the glm arm's next_flush_time. A reset that already passed is tomorrow's (the clause
            # carries no date); absent/unparseable/nonpositive falls back to the 5h window default.
            local sl_ttl=18000 sl_when sl_tz sl_target sl_now
            # ERE held in a variable, not written inline: an unquoted `)` inside a bracket
            # expression is a bash CONDITIONAL-EXPRESSION parse error in [[ =~ ]].
            local sl_re='resets[[:space:]]+([0-9]{1,2}:[0-9]{2}[[:space:]]*[aApP][mM])[[:space:]]*\(([^)]+)\)'
            if [[ "$last_text" =~ $sl_re ]]; then
              sl_when="${BASH_REMATCH[1]}"; sl_tz="${BASH_REMATCH[2]}"
              sl_target="$(date -d "TZ=\"$sl_tz\" $sl_when" +%s 2>/dev/null || echo 0)"
              sl_now="$(date +%s)"
              if (( sl_target > 0 )); then
                (( sl_target <= sl_now )) && sl_target=$(( sl_target + 86400 ))
                sl_ttl=$(( sl_target - sl_now ))
                (( sl_ttl > 0 )) || sl_ttl=18000
              fi
            fi
            printf '%s\n' "$last_result" > "$busdir/limits/$lane.limited.evidence"
            limit_flag "$busdir" "$lane" "$sl_ttl" session-limit "$lane: session limit reported on card $id"
            return 1
          fi
        fi
        ;;
    esac
    case "$lane" in codex | kimi | claude) rm -f "$busdir/limits/$lane.strikes" ;; esac
    return 0
  fi

  code_num="$(jq -r '(.error.code? // .code? // empty) | select(type == "number")' <<<"$hit" 2>/dev/null)"
  code_str="$(jq -r '(.error.code? // .code? // empty) | select(type == "string")' <<<"$hit" 2>/dev/null)"
  msg="$(jq -r '(.error.message? // .message? // empty)' <<<"$hit" 2>/dev/null)"
  next_flush="$(jq -r '(.error.next_flush_time? // .next_flush_time? // empty)' <<<"$hit" 2>/dev/null)"

  case "$lane" in
    glm)
      case "$code_num" in
        1308 | 1310 | 1316 | 1317 | 1318 | 1319 | 1320 | 1321 | 1113)
          # Evidence first: 2026-07-19 a glm 5h park fired while the Z.ai dashboard showed 21%/4%
          # quota — the code list alone is not proof of exhaustion. Keep the raw triggering event
          # next to the flag so the next false park is diagnosable.
          printf '%s\n' "$hit" > "$busdir/limits/$lane.limited.evidence"
          if [[ -z "$next_flush" ]]; then
            # No flush timestamp = ambiguous signal (real quota exhaustion carries one). First
            # strike retries the SAME lane (codex-style); the park only lands on a repeat.
            local sfile="$busdir/limits/glm.strikes" strikes=0
            [[ -f "$sfile" ]] && strikes="$(<"$sfile")"
            strikes=$(( strikes + 1 ))
            if (( strikes < 2 )); then
              printf '%s' "$strikes" > "$sfile"
              return 2
            fi
            rm -f "$sfile"
          fi
          local ttl=18000
          if [[ -n "$next_flush" ]]; then
            if [[ "$next_flush" =~ ^[0-9]+$ ]]; then
              ttl=$(( next_flush - $(date +%s) ))
            else
              ttl=$(( $(date -d "$next_flush" +%s 2>/dev/null || echo 0) - $(date +%s) ))
            fi
            (( ttl > 0 )) || ttl=18000
          fi
          limit_flag "$busdir" "$lane" "$ttl"
          return 1
          ;;
        1302 | 1305) return 2 ;;
        *) rm -f "$busdir/limits/glm.strikes"; return 0 ;;
      esac
      ;;
    codex)
      if [[ "$code_str" == "rate_limit_exceeded" || "$msg" == *"usage limit"* ]]; then
        local sfile="$busdir/limits/codex.strikes" strikes=0
        [[ -f "$sfile" ]] && strikes="$(<"$sfile")"
        strikes=$(( strikes + 1 ))
        if (( strikes >= 2 )); then
          rm -f "$sfile"
          limit_flag "$busdir" "$lane" 18000
          return 1
        fi
        printf '%s' "$strikes" > "$sfile"
        return 2
      fi
      rm -f "$busdir/limits/codex.strikes"
      return 0
      ;;
    kimi)
      # Moonshot (model-lanes.md "Failover detection" Kimi paragraph): claude-shaped envelope, no
      # z.ai-style numeric codes, so this sniffs .error.type plus the shared .message/.code text.
      # Quota/balance signatures never self-heal inside a run -> park immediately, TTL 18000. Plain
      # rate signatures are codex-style 2-strike, but the park is SHORT (300s): PAYG rate limits are
      # per-minute RPM windows, not 5h subscription windows — a 5h park here would be self-inflicted
      # downtime on a funded live lane. Quota patterns are checked FIRST since a quota message often
      # also mentions "429"/"rate", which would otherwise be mis-caught by the rate-limit arm.
      local etype lower
      etype="$(jq -r '(.error.type? // empty)' <<<"$hit" 2>/dev/null)"
      lower="$(tr '[:upper:]' '[:lower:]' <<<"$msg $etype $code_str")"
      case "$lower" in
        *"exceeded_current_quota"* | *"insufficient"*"balance"* | *quota*)
          printf '%s\n' "$hit" > "$busdir/limits/$lane.limited.evidence"
          rm -f "$busdir/limits/kimi.strikes"
          limit_flag "$busdir" "$lane" 18000
          return 1
          ;;
        *"rate limit"* | *"rate-limit"* | *rate_limit* | *"too many requests"* | *429*)
          local sfile="$busdir/limits/kimi.strikes" strikes=0
          [[ -f "$sfile" ]] && strikes="$(<"$sfile")"
          strikes=$(( strikes + 1 ))
          if (( strikes >= 2 )); then
            rm -f "$sfile"
            printf '%s\n' "$hit" > "$busdir/limits/$lane.limited.evidence"
            # ponytail: 300s park, not 18000 — PAYG RPM window; bump if telemetry disagrees
            limit_flag "$busdir" "$lane" 300
            return 1
          fi
          printf '%s' "$strikes" > "$sfile"
          return 2
          ;;
        *)
          rm -f "$busdir/limits/kimi.strikes"
          return 0
          ;;
      esac
      ;;
    claude)
      # spec 10 FR-R8: claude had zero limit detection before this — a 429 fell through the bare
      # `*) return 0` catch-all invisibly. Auth-death signatures (same list as answer_unusable)
      # checked first since a dead session's error text can also mention "limit"/"429" in prose;
      # rate signatures are codex-style 2-strike (claude.strikes), TTL 18000 (subscription window).
      if _auth_death_signature "$msg"; then
        _flag_dead_or_downgrade "$busdir" "$lane" "$id" "$hit"
        return 1
      fi
      if [[ "$code_str" == "rate_limit_exceeded" || "$code_num" == "429" ]] \
        || _rate_limit_signature "$msg"; then
        local sfile="$busdir/limits/claude.strikes" strikes=0
        [[ -f "$sfile" ]] && strikes="$(<"$sfile")"
        strikes=$(( strikes + 1 ))
        if (( strikes >= 2 )); then
          rm -f "$sfile"
          limit_flag "$busdir" "$lane" 18000
          return 1
        fi
        printf '%s' "$strikes" > "$sfile"
        return 2
      fi
      rm -f "$busdir/limits/claude.strikes"
      return 0
      ;;
    gemini)
      # spec 10 FR-R8: gemini had zero limit detection before this. Quota/rate signatures are
      # single-strike (grok-style — no strikes counter, straight to limit_flag); auth-death checked
      # first for the same reason as claude above.
      if _auth_death_signature "$msg"; then
        _flag_dead_or_downgrade "$busdir" "$lane" "$id" "$hit"
        return 1
      fi
      if [[ "$code_str" == "RESOURCE_EXHAUSTED" || "$code_num" == "429" ]] \
        || grep -Eqi 'quota|resource_exhausted|rate limit|429|too many requests' <<<"$msg"; then
        limit_flag "$busdir" "$lane" 18000
        return 1
      fi
      return 0
      ;;
    grok)
      # No observed 429 envelope yet (probe-verified 2026-07-19, grok CLI 0.2.103) — message-sniff
      # fallback on the generic error/turn.failed extraction above. Refine TTL/codes once a real
      # limit envelope is captured live, same caveat as the header note on this function.
      local lower
      lower="$(tr '[:upper:]' '[:lower:]' <<<"$msg")"
      case "$lower" in
        # bare *quota*/*429* can false-positive on an unrelated message that happens to mention
        # those words — acceptable: the only cost is a 5h lane-skip, since the chain falls over
        # to the next lane rather than failing the run.
        *"rate limit"* | *"rate-limit"* | *"rate_limit"* | *"usage limit"* | *"weekly limit"* | *quota* | *429* | *"too many requests"*)
          limit_flag "$busdir" "$lane" 18000
          return 1
          ;;
        *) return 0 ;;
      esac
      ;;
    *)
      return 0
      ;;
  esac
}

# _chain_tokens <busdir> <id> — spec 10 FR-R2 seed resolution shared by chain_current/chain_advance:
# limits/.chain-<id> (existing walk position) -> else queue/<id>.chain (orchestrator-pin chain seed,
# a review/judge card's own lane:model list) -> else $EXEC_CHAIN, the only fallback an ordinary exec
# card ever reaches. Guard every read with [[ -f ]] (deviation-from-PRD note, specs/10-role-classes.md).
_chain_tokens() {
  local busdir="$1" id="$2"
  local cf="$busdir/limits/.chain-$id" qf="$busdir/queue/$id.chain"
  if [[ -f "$cf" ]]; then
    cat "$cf"
  elif [[ -f "$qf" ]]; then
    cat "$qf"
  else
    printf '%s' "$EXEC_CHAIN"
  fi
}

# chain_current <busdir> <id> — echoes the lane:model this id should try next (empty = chain
# exhausted, per FR-10 the spec then parks in queue/ rather than being silently dropped).
chain_current() {
  local busdir="$1" id="$2" tokens arr
  tokens="$(_chain_tokens "$busdir" "$id")"
  read -ra arr <<<"$tokens"
  echo "${arr[0]:-}"
}

# chain_advance <busdir> <id> — drops the current lane, so the next chain_current call returns
# the next chain entry (or empty once exhausted).
chain_advance() {
  local busdir="$1" id="$2" tokens arr
  tokens="$(_chain_tokens "$busdir" "$id")"
  read -ra arr <<<"$tokens"
  arr=("${arr[@]:1}")
  printf '%s' "${arr[*]:-}" > "$busdir/limits/.chain-$id"
  # the same-lane retry counter (MAX_LANE_RETRIES, swarm-run.sh _finalize_worker) is per CURRENT
  # lane — a lane change gives the next lane a fresh budget
  rm -f "$busdir/limits/.retries-$id"
}

# chain_reset <busdir> <id> — clears per-id chain state back to the chain's first entry (called
# once a spec finally completes, so its bookkeeping doesn't linger under limits/). Also clears the
# FR-R6 pinned bounded-wait marker: a completed id has nothing left to wait on.
chain_reset() {
  local busdir="$1" id="$2"
  rm -f "$busdir/limits/.chain-$id" "$busdir/limits/.retries-$id" "$busdir/limits/$id.waiting"
}

# _verify_lane_pair_fallback <gen_lane> <v> [busdir] — the codex<->kimi review-pair rule: if v is
# one of {codex, kimi} and its limit flag is active in busdir, hand review to its partner instead
# — UNLESS the partner fails _judge_ok against the generator (judge != executor stays absolute,
# spec 10 FR-R3/R4/R16, refactored onto the shared guard — byte-identical to the old bare
# `!= gen_lane` check for today's inputs) or the partner is itself unavailable (limited, spec 10
# FR-R8 lane_dead, or kimi over its FR-R5 budget cap), in which case v is kept as-is and the
# caller's verify pin parks loudly (unpinned lanes never chain-switch). No busdir means no
# availability awareness at all — echoes v unchanged, byte-identical to plain mapping.
_verify_lane_pair_fallback() {
  local gen_lane="$1" v="$2" busdir="$3" partner=""
  case "$v" in
    codex) partner="kimi" ;;
    kimi) partner="codex" ;;
  esac
  if [[ -n "$busdir" && -n "$partner" ]] && limit_active "$busdir" "$v" \
     && _judge_ok "$partner" "$gen_lane" "$busdir" && ! lane_blocked "$busdir" "$partner"; then
    echo "swarm: verify lane $v is limited — review-pair fallback to $partner for $gen_lane branch" >&2
    echo "$partner"
    return 0
  fi
  echo "$v"
}

# _lane_family <bare_lane> — spec 10 FR-R4: the model-family grouping same-family fallback must
# never seat as final verdict. claude and fable are one Anthropic-model family (fable is Claude
# under the hood, judge != executor must reject fable-vs-claude same as claude-vs-claude); every
# other lane is its own family (codex, gemini, glm, grok, kimi each a distinct provider/model).
_lane_family() {
  case "$1" in
    claude | fable) echo anthropic ;;
    *) echo "$1" ;;
  esac
}

# orch_seat <busdir> — spec 11 FR-S3: the currently seated orchestrator lane, succession-aware.
# Prints the first whitespace-field of busdir/orch-seat if that file exists and is non-empty
# (a takeover writes its bare lane there); else prints "fable" (default seat, pre-succession).
# Always rc 0 — a missing/empty seat file is the normal pre-succession state, not an error.
orch_seat() {
  local busdir="$1"
  local f="$busdir/orch-seat" seat
  if [[ -s "$f" ]]; then
    # || true: read returns rc 1 at newline-less EOF (vars still populated) — without it, a
    # hand-edited seat file kills errexit-live callers (command substitution) → empty → "fable".
    read -r seat _ < "$f" || true
    [[ -n "$seat" ]] && { printf '%s' "$seat"; return 0; }
  fi
  printf 'fable'
}

# orch_degraded <busdir> — spec 11 FR-S3: rc 0 iff a non-fable lane currently holds the
# orchestrator seat (succession has occurred), rc 1 while fable is still seated.
orch_degraded() {
  local busdir="$1"
  [[ "$(orch_seat "$busdir")" != fable ]]
}

# _judge_ok <candidate_bare> <author_bare> [busdir] — spec 10 FR-R3/R4/R16 (+ spec 11 FR-S3): the
# one shared judge != executor guard, reused by every class-fallback resolution (verify_lane_for/
# _verify_lane_pair_fallback are refactored onto this in a later card). rc 0 iff ALL of: candidate
# differs from author (exact lane); candidate's _lane_family differs from author's; candidate is
# not the seated non-fable $PLAN; candidate is not the ACTING non-fable orchestrator seat — per
# FR-S3 that is busdir/orch-seat when present and non-fable, falling back to the static
# $ORCHESTRATOR read only if orch-seat is absent or still fable (REPLACE, not additive).
# QUALIFICATION ONLY — availability (limited/dead/budget) is deliberately not checked here, that's
# the claiming pool's job. $PLAN/$ORCHESTRATOR default to "fable" when unset (bare callers, outside
# conf_load) so the config-guard clauses are a no-op unless a swarm.conf override manually seats a
# spawnable lane. The optional busdir arg is likewise a no-op (2-arg calls stay byte-identical)
# unless a succession takeover has actually seated a non-fable lane there.
_judge_ok() {
  local candidate="$1" author="$2" busdir="${3:-}"
  [[ "$candidate" != "$author" ]] || return 1
  [[ "$(_lane_family "$candidate")" != "$(_lane_family "$author")" ]] || return 1
  local plan_bare="${PLAN:-fable}" orch_bare="${ORCHESTRATOR:-fable}"
  plan_bare="${plan_bare%%:*}"
  orch_bare="${orch_bare%%:*}"
  [[ "$plan_bare" == fable || "$candidate" != "$plan_bare" ]] || return 1
  if [[ -n "$busdir" ]]; then
    local seat_bare
    seat_bare="$(orch_seat "$busdir")"
    [[ "$seat_bare" != fable ]] && orch_bare="$seat_bare"
  fi
  [[ "$orch_bare" == fable || "$candidate" != "$orch_bare" ]] || return 1
  return 0
}

# review_chain_for <author_bare> <busdir> — spec 10 FR-R3: echoes a space-separated "lane:model"
# fallback chain for a review/judge card authored by <author_bare>. Source order: $REVIEW_CHAIN
# tokens if non-empty, else each $CLASS_REVIEW member paired with its _verify_default_model. Every
# candidate is filtered by `_judge_ok candidate author busdir` ONLY — availability (limited/dead/
# budget) is the claiming pool's job at claim time, not this function's. Echoes empty (rc 0) when
# nothing qualifies. <busdir> is forwarded to _judge_ok so a spec 11 succession takeover (a
# non-fable orch_seat) disqualifies that lane as a candidate here too — the caller records any
# first-member-dropped provenance into limits/.fbreason-<id> itself; this function takes no id.
review_chain_for() {
  local author="$1" busdir="${2:-}"
  local -a src=() out=()
  local tok member bare
  if [[ -n "${REVIEW_CHAIN:-}" ]]; then
    read -ra src <<<"$REVIEW_CHAIN"
    for tok in "${src[@]}"; do
      bare="${tok%%:*}"
      _judge_ok "$bare" "$author" "$busdir" && out+=("$tok")
    done
  else
    read -ra src <<<"${CLASS_REVIEW:-}"
    for member in "${src[@]}"; do
      _judge_ok "$member" "$author" "$busdir" && out+=("$member:$(_verify_default_model "$member")")
    done
  fi
  echo "${out[*]:-}"
}

# kimi_budget_ok <busdir> — spec 10 FR-R5: rc 0 iff BUDGET_USD is unset/empty/0 (unrestricted) OR
# the accumulated real-$ spend in limits/kimi.spend (0 if the file is absent) is strictly less than
# BUDGET_USD. Float compare via awk — bash arithmetic is integer-only and both sides are dollars.
kimi_budget_ok() {
  local busdir="$1"
  # Numeric zero test, not string compare — "0.0"/"0.00"/"0." must also mean unrestricted (FR-R5).
  awk -v b="${BUDGET_USD:-0}" 'BEGIN { exit !(b + 0 <= 0) }' && return 0
  local f="$busdir/limits/kimi.spend" spend=0
  [[ -f "$f" ]] && spend="$(<"$f")"
  awk -v s="$spend" -v b="$BUDGET_USD" 'BEGIN { exit !(s < b) }'
}

# _payg_denied <bare_lane> <orig_bare_lane> — spec 13 FR-4 (backlog 39): rc 0 iff a chain-walk
# landing on <bare_lane> is a PAYG fallback hop that PAYG_FALLBACK=deny must route around: the
# candidate is kimi (the one billing:"real" lane today), it differs from the chain's ORIGINAL seed
# head (a first claim / pinned lane is never a "fallback" — kimi_budget_ok/lane_blocked already
# govern a deliberately-requested kimi card), BUDGET_USD is unrestricted (same numeric-zero test as
# kimi_budget_ok — "0"/"0.0"/empty all mean uncapped), and the conf key is actually "deny". warn/
# allow never route around anything here — the caller's own post-walk check handles warn's loud
# stderr line, and allow is a deliberate no-op (today's behavior, operator explicitly accepted).
_payg_denied() {
  local bare="$1" orig="$2"
  [[ "$bare" == kimi && "$bare" != "$orig" ]] || return 1
  [[ "${PAYG_FALLBACK:-warn}" == deny ]] || return 1
  awk -v b="${BUDGET_USD:-0}" 'BEGIN { exit !(b + 0 <= 0) }'
}

# _kimi_spend_add <busdir> <id> — spec 10 FR-R5: parse the LAST result envelope in run-<id>.jsonl,
# recompute its real $ at Moonshot list price (same formula speed_row's kimi branch already uses:
# $3.00/M input+cache-write, $0.30/M cache-read, $15.00/M output — never the envelope's own
# total_cost_usd, which is claude-CLI Anthropic-list pricing against the swapped base URL, wrong
# provider), and add it to the float in limits/kimi.spend (0 if absent). Single write(2) via
# temp+mv — safe under this call's single-writer context (_finalize_worker, later card).
_kimi_spend_add() {
  local busdir="$1" id="$2"
  local runlog="$busdir/run-$id.jsonl"
  local added=0
  if [[ -f "$runlog" ]]; then
    added="$(jq -R -c 'fromjson? // empty' "$runlog" \
      | jq -s -r '(map(select(.type == "result")) | last) as $e |
        if $e == null then 0 else
          ((($e.usage.input_tokens // 0) + ($e.usage.cache_creation_input_tokens // 0)) * 3.0
           + ($e.usage.cache_read_input_tokens // 0) * 0.30
           + ($e.usage.output_tokens // 0) * 15.0) / 1e6
        end')" || added=0
  fi
  [[ -n "$added" ]] || added=0
  mkdir -p "$busdir/limits"
  local f="$busdir/limits/kimi.spend" prior=0
  [[ -f "$f" ]] && prior="$(<"$f")"
  awk -v p="$prior" -v a="$added" 'BEGIN { printf "%.10f", p + a }' > "$f.tmp"
  mv "$f.tmp" "$f"
}

# answer_unusable <bare_lane> <busdir> <id> — spec 10 FR-R11: the cross-lane false-done classifier.
# rc 0 = the served answer is UNUSABLE (same polarity as limit_active — "rc 0 means the bad
# condition is true"), rc 1 = healthy, trust it. spec 12 FR-1: on rc 0 also ECHOES the matched
# failure class on stdout — one of "api-error" (is_error==true), "auth-death" (the anchored
# OAuth/auth-death substring signature), or "server-error" (the 5xx/429/529/overloaded_error
# envelope regex); rc 1 echoes nothing. The rc contract itself is unchanged — callers that only
# care about usable/unusable keep testing rc; callers that also want the class capture stdout via
# command substitution used AS the conditional (`class="$(answer_unusable ...)"` inside an `if`),
# which preserves rc under `set -e` (a plain assignment would instead trip errexit on the healthy
# rc-1 case). Checks res-<id>.txt AND the last result event's
# text in run-<id>.jsonl (an auth-death run often looks like a normal result whose text IS the
# error) for the anchored, case-insensitive auth-death substrings — never bare "error"/"limit",
# which would false-positive on ordinary prose. Also rc 0 when the last result event carries
# is_error == true, or when the combined text matches the GLM 5xx/429-error-body-served-as-answer
# heuristic. grok's stopReason:Cancelled is deliberately NOT checked here — it also appears on
# successful grok runs, so it is not a reliable signature (spec 10 non-goal, deferred). <bare_lane>
# is accepted for signature symmetry with the rest of this fallback family (every check here is
# lane-agnostic today).
answer_unusable() {
  local busdir="$2" id="$3"
  local resfile="$busdir/res-$id.txt" runlog="$busdir/run-$id.jsonl"
  local text="" last="" last_text="" is_error=""
  [[ -f "$resfile" ]] && text="$(<"$resfile")"

  if [[ -f "$runlog" ]]; then
    last="$(jq -R -c 'fromjson? // empty' "$runlog" \
      | jq -s -c 'map(select(.type == "result")) | last // empty')" || last=""
    if [[ -n "$last" && "$last" != "null" ]]; then
      last_text="$(jq -r '.result // empty' <<<"$last")"
      is_error="$(jq -r '.is_error // empty' <<<"$last")"
    fi
  fi

  if [[ "$is_error" == "true" ]]; then echo api-error; return 0; fi

  # Text signatures apply ONLY to short answers: every observed false-done of this class (cal056
  # OAuth text, GLM 5xx-body) is the error dump AS the whole answer — a few hundred bytes. A long
  # healthy answer (e.g. a review card QUOTING these very strings — live false-positive
  # 2026-07-24, codex spec-adherence review rejected 3x) must never match. is_error above stays
  # unconditional: the envelope's own flag is authoritative at any length.
  # ONE canonical text, not res+result concatenated — the two are usually identical, and doubling
  # the measured length would let a 301-600-char error dump evade the bound (r3codex MAJ).
  local canonical="$text"
  [[ -n "$canonical" ]] || canonical="$last_text"
  if (( ${#canonical} <= 600 )); then
    if _auth_death_signature "$canonical"; then echo auth-death; return 0; fi
    # Error-ENVELOPE shapes only, never bare prose words: "API Error" anchored at answer start,
    # structured 5xx codes, status-adjacent 429/529, or the overloaded_error type — a healthy
    # short answer saying "the service is not overloaded" must pass (r3codex MAJ).
    if grep -Eqi '^[[:space:]]*api error|"code":[[:space:]]*5[0-9][0-9]|status.{0,10}(429|529)|overloaded_error' <<<"$canonical"; then
      echo server-error; return 0
    fi
  fi

  return 1
}

# _cage_denials_jq_filter — echoes the shared jq selector for spec 14 FR-1: the LAST `type:"result"`
# event's permission_denials[] narrowed to READ-CLASS tools (Read/Glob/Grep/NotebookRead). One
# definition (same `cat <<'JQ'` idiom as jq_firehose_filter above) so cage_denials' count and
# swarm-run.sh's _check_cage_denied path list can't drift on what "read-class" means.
_cage_denials_jq_filter() {
  cat <<'JQ'
map(select(.type == "result")) | last // {}
| (.permission_denials // [])
| map(select((.tool_name // "") | test("^(Read|Glob|Grep|NotebookRead)$")))
JQ
}

# cage_denials <busdir> <id> — spec 14 FR-1: how many READ-CLASS tools the permission cage denied
# this card. One jq pass over the LAST `type:"result"` event of run-<id>.jsonl, counting
# permission_denials[] whose tool_name is Read/Glob/Grep/NotebookRead. Echoes the count; rc 0 always
# (an absent run log, an absent field, or a torn line is 0 — never an error the caller must handle).
#
# Bash denials are excluded BY DESIGN: a write cage denies Bash on purpose and cards route around it
# (8 of the 21 healthy cockpit057b cards carried Bash-only denials and every one delivered). Only
# read-class denials indicate a cage that cannot be worked around.
#
# codex/gemini/grok silently no-op on a denied tool and emit no such field at all, so those lanes
# are never gated by this — documented behavior, not a gap to patch here. Deliberately NOT a text
# signature: answer_unusable's sniffs are bounded to answers <=600 chars to avoid false positives,
# and the observed cage-denied answers run to ~2300 chars of articulate explanation.
cage_denials() {
  # Two statements, not one `local`: bash expands every word of a `local` list BEFORE any of its
  # assignments take effect, so `local a="$1" b="$a/x"` trips `set -u` on $a.
  local busdir="$1" id="$2" n=0
  local runlog="$busdir/run-$id.jsonl"
  if [[ -f "$runlog" ]]; then
    n="$(jq -R -c 'fromjson? // empty' "$runlog" \
      | jq -s "$(_cage_denials_jq_filter) | length" 2>/dev/null || echo 0)"
  fi
  printf '%s\n' "${n:-0}"
}

# verify_lane_for <gen_lane> [busdir] — Phase E step 4: the VERIFY_MAP rotation (swarm.conf key,
# space-separated gen:verifier bare-lane tokens; conf_load default "claude:codex codex:kimi
# gemini:claude glm:codex grok:codex kimi:codex"). Judge != executor is enforced even OFF the map:
# a generator with no entry still gets a verifier that is provably not itself, never a silent
# same-lane self-check — the guard is the shared _judge_ok (spec 10 FR-R3/R4/R16), not a bare
# `!= gen_lane` check; behavior is byte-identical to the old check for today's inputs (no VERIFY_MAP
# entry ever names fable or a seated PLAN/ORCHESTRATOR lane). A VERIFY_MAP entry that fails
# _judge_ok against gen_lane (e.g. codex:codex) is never honored: logs a loud stderr warning and
# falls back to the first EXEC_CHAIN lane that passes _judge_ok against gen_lane; rc 1 (no
# qualifying lane available — caller must skip the verify, never self-review) if no such lane
# exists. Optional busdir arg: applies the codex<->kimi review-pair fallback
# (_verify_lane_pair_fallback) to whichever lane this function resolves — mapped, self-map
# fallback, or off-map default alike — and (spec 11 FR-S3) is forwarded to every _judge_ok call so
# a succession takeover's non-fable orch_seat disqualifies that lane as a verifier too. Omitting
# busdir keeps behavior byte-identical to before the pair rule/succession existed.
verify_lane_for() {
  local gen_lane="$1" busdir="${2:-}" tokens="${VERIFY_MAP:-}" t g v fb
  for t in $tokens; do
    g="${t%%:*}"; v="${t#*:}"
    [[ "$g" == "$gen_lane" ]] || continue
    if _judge_ok "$v" "$gen_lane" "$busdir"; then
      _verify_lane_pair_fallback "$gen_lane" "$v" "$busdir"; return 0
    fi
    echo "swarm: VERIFY_MAP maps $gen_lane to itself — judge must differ from executor; picking fallback" >&2
    for fb in $EXEC_CHAIN; do
      fb="${fb%%:*}"
      _judge_ok "$fb" "$gen_lane" "$busdir" || continue
      _verify_lane_pair_fallback "$gen_lane" "$fb" "$busdir"; return 0
    done
    return 1
  done
  # Off-map default is held to the SAME shared guard as mapped verifiers (r3codex MAJ: a manually
  # seated non-fable PLAN/ORCHESTRATOR lane must not become a verifier through this path either).
  if [[ "$gen_lane" == "codex" ]]; then v="claude"; else v="codex"; fi
  if ! _judge_ok "$v" "$gen_lane" "$busdir"; then
    if [[ "$v" == "claude" ]]; then v="codex"; else v="claude"; fi
    if ! _judge_ok "$v" "$gen_lane" "$busdir"; then
      echo "swarm: no qualified off-map verifier for $gen_lane (_judge_ok rejects both defaults)" >&2
      return 1
    fi
  fi
  _verify_lane_pair_fallback "$gen_lane" "$v" "$busdir"
}

# _verify_default_model <lane> — VERIFY_MAP only names the verifier LANE; a spawnable lane:model
# token still needs a model, so this is a fixed sane default per lane (not user-tunable — a second
# config surface for this isn't worth it at 4 lanes).
_verify_default_model() {
  case "$1" in
    claude) echo opus ;;
    codex) echo default ;;
    gemini) echo gemini-3-flash ;;
    glm) echo glm-5.2 ;;
    kimi) echo kimi-k3 ;;
    *) echo default ;;
  esac
}

# _write_journal <busdir> <id> — spec 14 FR-8 (backlog 59): the set of paths THIS card's worker
# actually wrote, derived post-hoc from the already-archived worker stream (run-<id>.jsonl) — no
# watcher, no daemon. Claude-binary lanes only (claude/glm/kimi): their stream carries assistant
# tool_use records with input.file_path for the write-class tools; grok/codex/gemini streams have
# no such records, so their journal is underivable and callers must not require one there.
# One path per line, first-seen order, deduped. Empty output = the stream shows no write-class
# call at all (the W3D1 narration-only shape). rc 0 always — evidence extraction, not a gate.
_write_journal() {
  local busdir="$1" id="$2"
  local log="$busdir/run-$id.jsonl"  # separate `local` — same set -u pitfall kill_subtree documents
  [[ -s "$log" ]] || return 0
  jq -r '
    .message.content[]? | select(.type == "tool_use")
    | select(.name == "Write" or .name == "Edit" or .name == "MultiEdit" or .name == "NotebookEdit")
    | (.input.file_path // .input.notebook_path) // empty
  ' "$log" 2>/dev/null | awk '!seen[$0]++' || true
}

# _write_card_diff_section <busdir> <id> <target> — backlog-28 (specs/10-role-classes.md Round-3
# amendments #2): builds the CARD DIFF section of a write card's verify prompt, scoped to files
# under <target> newer than limits/<id>.stamp (the diff-gate baseline, kept alive on success
# finalize) — never the tree's current possibly-concurrently-edited state. Tracked changes render
# as `git diff <base>` where <base> is the pre-spawn HEAD (limits/<id>.base sha if the spawner
# recorded one, else the last commit at/before the stamp's mtime) — never bare `git diff HEAD`,
# which is empty once the worker COMMITS its change (the normal write-card pattern) and would ship
# the verifier an evidence-free prompt. Untracked files get a `NEW FILE: <relpath>` header + their
# content. Degrades to NEW FILE entries with contents (no git diff) when <target> is not a git repo
# — every sub-command that can fail on a non-repo/non-tracked/unborn-HEAD input is guarded so a
# failure never trips `set -e`. The bus itself is pruned from the enumeration: when target ⊇ busdir
# (write target = the repo itself), copied worker credentials ($busdir/home/*/.claude/
# .credentials.json etc.) and run logs are gitignored, so the NEW FILE arm would otherwise embed
# them verbatim into a prompt shipped to a third-party provider. Caps the whole section at 50000
# chars INCLUDING the literal "[diff truncated]" marker it ends with when truncated.
#
# spec 14 FR-2 (backlog 45): when this card published a deliverable manifest, enumerate THAT list
# instead of the whole-target find sweep — a neighbouring card's concurrent edit under the same
# target must never satisfy THIS card's evidence. Checked in the same order the archive is
# written: files-<id>.txt (the post-finalize archive, spec 14 FR-2's mirror of write-<id>.txt)
# first, queue/<id>.files (the still-live sidecar) as a fallback for a call made before finalize or
# against an older bus that never archived it. Absent BOTH -> today's stamp-newer find sweep,
# byte-identical (FR-2's own non-goal: no removal of the whole-directory mtime gate). Presence is
# `-f`, not `-s` (cross-review fix): an EMPTY manifest is still a manifest — the gate treats "the
# card listed zero files" as authoritative empty evidence, never as "no manifest, fall back to the
# whole-cage sweep" (that fallback would let a neighbour's edit satisfy a card that explicitly
# published nothing). Manifest entries are relative to <target>; the mtime/stamp gate does not
# apply to them at all — a listed file's git diff (or lack of one) against base_ref is already the
# precise scope FR-2 asks for.
_write_card_diff_section() {
  local busdir="$1" id="$2" target="$3"
  local stamp="$busdir/limits/$id.stamp"
  local section
  section="THIS IS A WRITE CARD. Judge ONLY this card's diff below at its commit — other cards edit this tree concurrently; do not judge the tree's current state."
  section+=$'\n'"CARD DIFF (target: $target):"

  local is_repo=0
  if git -C "$target" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    is_repo=1
  fi

  # find's -newer is strictly-newer on mtime: compare against stamp mtime minus 1s so a worker
  # write landing in the same timestamp granule (coarse-mtime target fs) is never silently
  # dropped — the per-file git scoping below tolerates the over-inclusion. base_ref (below) still
  # uses stamp_epoch even on the manifest path, so it's computed unconditionally.
  local stamp_epoch
  stamp_epoch="$(stat -c %Y "$stamp" 2>/dev/null || true)"

  local manifest=""
  if [[ -f "$busdir/files-$id.txt" ]]; then
    manifest="$busdir/files-$id.txt"
  elif [[ -f "$busdir/queue/$id.files" ]]; then
    manifest="$busdir/queue/$id.files"
  fi

  local -a files=()
  local f
  if [[ -n "$manifest" ]]; then
    # Consume-time trust boundary — mirrors swarm-ctl's _validate_files_manifest canonicalization
    # exactly (same realpath -m rule), so the two checks can never disagree on what "escapes"
    # means. A bad entry is ignored with one loud line, never a hard failure: a single bad line
    # must not blank the whole card's evidence.
    local tcanon entry canon
    tcanon="$(realpath -m -- "$target" 2>/dev/null || printf '%s' "$target")"
    while IFS= read -r entry || [[ -n "$entry" ]]; do
      [[ -z "$entry" ]] && continue
      if [[ "$entry" == /* ]]; then
        echo "_write_card_diff_section: $id manifest entry '$entry' is absolute — ignored" >&2
        continue
      fi
      # Fail CLOSED on realpath failure (same rule as _manifest_roots and swarm-ctl's validator):
      # the literal-path fallback would let "a/../../x" pass the string-prefix check below.
      canon="$(realpath -m -- "$target/$entry" 2>/dev/null || true)"
      if [[ -z "$canon" || "$canon" != "$tcanon"/* ]]; then
        echo "_write_card_diff_section: $id manifest entry '$entry' escapes target — ignored" >&2
        continue
      fi
      # A directory is a card-authoring mistake, not merely a not-yet-written entry — loud, like
      # the other two rejections above (mirrors the write-diff gate's own rule). A plain missing
      # path stays a silent skip: the manifest may legitimately list a file the worker hasn't
      # produced yet.
      if [[ -d "$target/$entry" ]]; then
        echo "_write_card_diff_section: $id manifest entry '$entry' is a directory — ignored (manifest entries must be files)" >&2
        continue
      fi
      [[ -f "$target/$entry" ]] || continue
      files+=("$target/$entry")
    done < "$manifest"
  elif [[ -n "$stamp_epoch" ]]; then
    while IFS= read -r -d '' f; do
      files+=("$f")
    done < <(find "$target" -type f -newermt "@$((stamp_epoch - 1))" \
      -not -path '*/.git/*' -not -path "$busdir/*" -not -path '*/.bus*/*' -print0 2>/dev/null)
  fi

  # Baseline for tracked diffs: pre-spawn HEAD sha from limits/<id>.base when present (exact),
  # else derived from commit dates ("last commit at/before the stamp" — clock-skew tolerant
  # enough for a fallback), else today's HEAD (uncommitted-only worker: identical diff).
  local base_ref="HEAD"
  if [[ "$is_repo" -eq 1 ]]; then
    if [[ -s "$busdir/limits/$id.base" ]] \
       && git -C "$target" cat-file -e "$(<"$busdir/limits/$id.base")^{commit}" 2>/dev/null; then
      base_ref="$(<"$busdir/limits/$id.base")"
    elif [[ -n "$stamp_epoch" ]]; then
      base_ref="$(git -C "$target" rev-list -1 --before="@$stamp_epoch" HEAD 2>/dev/null || true)"
      [[ -n "$base_ref" ]] || base_ref="HEAD"
    fi
  fi

  local rel diff body
  for f in "${files[@]}"; do
    rel="${f#"$target"/}"
    if [[ "$is_repo" -eq 1 ]] && git -C "$target" ls-files --error-unmatch -- "$rel" >/dev/null 2>&1; then
      diff="$(git -C "$target" diff "$base_ref" -- "$rel" 2>/dev/null || true)"
      [[ -n "$diff" ]] && section+=$'\n'"$diff"
    else
      section+=$'\n'"NEW FILE: $rel"
      body="$(cat -- "$f" 2>/dev/null || true)"
      section+=$'\n'"$body"
    fi
    if [[ "${#section}" -gt 50000 ]]; then
      # marker INCLUDED in the 50000 cap: truncate to 50000 minus the marker's own length
      local marker=$'\n'"[diff truncated]"
      section="${section:0:50000 - ${#marker}}$marker"
      break
    fi
  done

  printf '%s\n' "$section"
}

# write_verify_spec <busdir> <id> — Phase E step 4: builds .bus/specs/v-<id>.prompt (original
# question + the branch's own answer + a VERDICT instruction) and its v-<id>.lane sidecar, pinned
# to verify_lane_for's mapped lane — so the pool (full_run mechanics, reused as-is) claims it onto
# a model that did NOT generate the answer it's checking. The .lane sidecar is published BEFORE
# the prompt (prompt = visibility marker, last) — wave-7 finding 3: the pool only ever claims
# *.prompt out of queue/, so publishing the pin first means a claim can never observe an unpinned
# prompt. rc 1 (no-op, not an error) when: <id> is itself a verify branch (never verify a
# verifier); its done/<id> marker is missing or carries no provenance "lane" field (older/foreign
# marker); its prompt-<id>.txt or res-<id>.txt archive is missing (nothing to verify); or v-<id>
# already has a full bus footprint (idempotent re-run safety — callers may invoke
# generate_verify_specs-style loops repeatedly as more branches complete). EXCEPTION: a TORN
# footprint — v-<id>.prompt present in specs/ or queue/ with no matching .lane sidecar (crash
# between the two publish steps, or a pre-finding-3 leftover) — is REPAIRED in place (loud stderr
# note) rather than skipped: an unpinned verify prompt left live would be free to claim on the
# generator's own lane, defeating judge != executor.
write_verify_spec() {
  local busdir="$1" id="$2"
  [[ "$id" == v-* ]] && return 1

  local donefile="$busdir/done/$id"
  [[ -f "$donefile" ]] || return 1
  local gen_lane
  gen_lane="$(jq -r '.lane // empty' "$donefile" 2>/dev/null)"
  [[ -n "$gen_lane" ]] || return 1

  local vid="v-$id" f
  for f in "$busdir/done/$vid" "$busdir/res-$vid.txt"; do
    [[ -e "$f" ]] && return 1
  done
  # exact match only (finding 5): a claimed v-foo.bar must not suppress verify for foo.
  _claim_of "$busdir" "$vid" >/dev/null && return 1

  local repair_dir=""
  if [[ -e "$busdir/specs/$vid.prompt" ]]; then
    [[ -e "$busdir/specs/$vid.lane" ]] && return 1
    repair_dir="$busdir/specs"
  elif [[ -e "$busdir/queue/$vid.prompt" ]]; then
    [[ -e "$busdir/queue/$vid.lane" ]] && return 1
    repair_dir="$busdir/queue"
  fi

  local vlane vmodel
  vlane="$(verify_lane_for "$gen_lane" "$busdir")" || return 1
  vmodel="$(_verify_default_model "$vlane")"

  if [[ -n "$repair_dir" ]]; then
    echo "swarm: repairing torn verify footprint — $vid.prompt exists in ${repair_dir##*/}/ with no .lane sidecar; re-writing it" >&2
    printf '%s:%s' "$vlane" "$vmodel" > "$repair_dir/$vid.lane"
    return 0
  fi

  local qfile="$busdir/prompt-$id.txt" afile="$busdir/res-$id.txt"
  [[ -f "$qfile" ]] || return 1
  # Round-4 MAJ: a timeout-salvaged WRITE card is finalized on its on-disk diff alone — the handoff
  # file never landed before the SIGKILL. Requiring res-<id>.txt silently skipped the mandatory
  # cross-model verify wave for exactly the cards that most need it. Diff-only verification is
  # allowed iff the write provenance (write-<id>.txt) AND the baseline stamp both exist — i.e. there
  # IS card-scoped evidence to hand the verifier below.
  local diff_only=0
  if [[ ! -f "$afile" ]]; then
    [[ -f "$busdir/write-$id.txt" && -e "$busdir/limits/$id.stamp" ]] || return 1
    diff_only=1
  fi
  local question answer
  question="$(<"$qfile")"
  answer="(no handoff file — this card was salvaged after a watchdog kill; judge it from the CARD
DIFF below, which is the only evidence of what it actually did.)"
  (( diff_only )) || answer="$(<"$afile")"
  # Round-4 MIN: a salvaged card is higher-suspicion by construction — the diff gate accepts ANY
  # byte newer than the pre-spawn stamp, so a kill landing after edit 1 of 5 looks identical to a
  # finished card. Tell the verifier that, so "partially applied" is on its checklist.
  local salvage_note=""
  if [[ "$(jq -r '.salvaged // empty' "$donefile" 2>/dev/null || true)" == "true" ]]; then
    salvage_note="NOTE: this card was KILLED by the wall-clock watchdog and salvaged from what was
already on disk. Treat partially-applied work as a likely failure mode."
  fi

  mkdir -p "$busdir/specs"
  printf '%s:%s' "$vlane" "$vmodel" > "$busdir/specs/$vid.lane"
  cat > "$busdir/specs/$vid.prompt" <<VERIFYPROMPT
You are adversarially verifying a claim produced by another model. Do not trust it by default.

ORIGINAL QUESTION:
$question

CANDIDATE ANSWER (from lane: $gen_lane):
$answer
$salvage_note

Check the candidate answer's factual claims. Be skeptical — actively look for errors, unsupported
claims, or missing caveats. End your response with exactly one line, verbatim:
VERDICT: confirmed|refuted|unverifiable
Then a short rationale (2-4 sentences).
VERIFYPROMPT

  # backlog-28 (specs/10-role-classes.md Round-3 amendments #2): a write card's success finalize
  # archives its target to write-<id>.txt and keeps limits/<id>.stamp alive (spec10 amendment to
  # _finalize_worker) precisely so this can scope the verify prompt to the card's OWN diff — other
  # write cards may be editing the same target tree concurrently. Absent either file, the prompt
  # stays byte-identical to the no-write-card contract above.
  if [[ -f "$busdir/write-$id.txt" && -e "$busdir/limits/$id.stamp" ]]; then
    local wtarget
    wtarget="$(<"$busdir/write-$id.txt")"
    {
      echo
      _write_card_diff_section "$busdir" "$id" "$wtarget"
    } >> "$busdir/specs/$vid.prompt"
  fi
}

# --- ledger_row: per-lane run-evidence, rules/unimatrix/model-lanes.md "Ledger — no silent spend" -

# _ledger_claude_cost <runlog> — the last type==result event's REAL .total_cost_usd + .usage
# (docs/01-feasibility-tests.md: `{"type":"result","result":"PONG","total_cost_usd":0.0313,
# "usage":{...}}`). "n/a" if the envelope carries no cost field at all.
_ledger_claude_cost() {
  local runlog="$1"
  [[ -f "$runlog" ]] || { echo "n/a"; return; }
  local last
  last="$(jq -R -c 'fromjson? // empty' "$runlog" | jq -s -c 'map(select(.type == "result")) | last // empty')"
  [[ -n "$last" && "$last" != "null" ]] || { echo "n/a"; return; }
  local cost
  cost="$(jq -r '.total_cost_usd // empty' <<<"$last")"
  [[ -n "$cost" ]] || { echo "n/a"; return; }
  local inp out
  inp="$(jq -r '.usage.input_tokens // empty' <<<"$last")"
  out="$(jq -r '.usage.output_tokens // empty' <<<"$last")"
  printf '$%s (%s in / %s out)' "$cost" "${inp:-?}" "${out:-?}"
}

# _ledger_codex_usage <runlog> — the last turn.completed event's .usage (docs/02-build-pitfalls.md:
# input_tokens/cached_input_tokens/output_tokens). Codex's captured envelope carries no dollar
# figure at all — report the real token counts, never a fabricated $.
_ledger_codex_usage() {
  local runlog="$1"
  [[ -f "$runlog" ]] || { echo "n/a"; return; }
  local last
  last="$(jq -R -c 'fromjson? // empty' "$runlog" | jq -s -c 'map(select(.type == "turn.completed")) | last // empty')"
  [[ -n "$last" && "$last" != "null" ]] || { echo "n/a"; return; }
  local inp cached out
  inp="$(jq -r '.usage.input_tokens // empty' <<<"$last")"
  cached="$(jq -r '.usage.cached_input_tokens // empty' <<<"$last")"
  out="$(jq -r '.usage.output_tokens // empty' <<<"$last")"
  if [[ -n "$cached" ]]; then
    printf 'cost unavailable in envelope (%s in, %s cached / %s out — see OpenAI dashboard)' \
      "${inp:-0}" "$cached" "${out:-0}"
  else
    printf 'cost unavailable in envelope (%s in / %s out — see OpenAI dashboard)' "${inp:-0}" "${out:-0}"
  fi
}

# _ledger_gemini_usage <runlog> — the last result event's .stats.models (docs/02-build-pitfalls.md
# "gemini result .stats.models with served-model keys"). Sums every numeric leaf recursively so it
# tolerates schema drift in the per-model stat shape (same defensive posture as jq_firehose_filter).
# No dollar figure — the envelope carries none.
_ledger_gemini_usage() {
  local runlog="$1"
  [[ -f "$runlog" ]] || { echo "n/a"; return; }
  local total
  total="$(jq -R -c 'fromjson? // empty' "$runlog" \
    | jq -s -r '(map(select(.type == "result")) | last) as $r
                | ($r.stats.models // {} | [.. | numbers] | add) // 0')"
  if [[ -z "$total" || "$total" == "0" ]]; then echo "n/a"; return; fi
  printf '~%s tokens total (stats.models sum — $ not in envelope, see AI Studio dashboard)' "$total"
}

# _ledger_glm_prompts <runlog> — GLM (glm lane) is literally the claude binary under a z.ai env
# swap, so its envelope is claude-shaped, but a z.ai-routed call's dollar figure (if the envelope
# even carries one) isn't real billing: z.ai meters by PROMPT count on a rolling window, not
# tokens (rules/unimatrix/model-lanes.md). Report prompts-consumed language, never a fake $.
# [NEEDS CLARIFICATION]: docs/01-feasibility-tests.md's live GLM smoke mentions a `modelUsage`
# field in prose ("modelUsage glm-4.7 (34k in/95 out)") whose raw JSON shape was never captured —
# this reads `.usage` (claude-native's own field) since GLM IS the claude binary underneath;
# revisit against a real GLM run if token counts turn out to live under `.modelUsage` instead.
_ledger_glm_prompts() {
  local runlog="$1" last=""
  if [[ -f "$runlog" ]]; then
    last="$(jq -R -c 'fromjson? // empty' "$runlog" | jq -s -c 'map(select(.type == "result")) | last // empty')"
  fi
  if [[ -z "$last" || "$last" == "null" ]]; then
    echo "1 prompt (5h window — Z.ai quota-metered, no reliable \$ in envelope)"
    return
  fi
  local inp out
  inp="$(jq -r '.usage.input_tokens // empty' <<<"$last")"
  out="$(jq -r '.usage.output_tokens // empty' <<<"$last")"
  if [[ -n "$inp" || -n "$out" ]]; then
    printf '1 prompt (5h window — %s in / %s out; Z.ai quota-metered, not $-billed)' "${inp:-?}" "${out:-?}"
  else
    echo "1 prompt (5h window — Z.ai quota-metered, no reliable \$ in envelope)"
  fi
}

# _ledger_kimi_cost <runlog> — kimi (Moonshot) is the ONE lane billed in REAL PAYG dollars. The
# envelope's own .total_cost_usd is claude-CLI Anthropic-list pricing computed against the swapped
# base URL — WRONG provider, never reported. Recompute from .usage at kimi-k3 list prices instead
# (rules/unimatrix/model-lanes.md "Ledger"): $3.00/M input+cache-write, $0.30/M cache-read,
# $15.00/M output.
# ponytail: single-price table — kimi-k2.7-code over-reports; switch on served model when that
# model sees real use.
_ledger_kimi_cost() {
  local runlog="$1"
  [[ -f "$runlog" ]] || { echo "n/a"; return; }
  local last
  last="$(jq -R -c 'fromjson? // empty' "$runlog" | jq -s -c 'map(select(.type == "result")) | last // empty')"
  [[ -n "$last" && "$last" != "null" ]] || { echo "n/a"; return; }
  local inp cache_in cache_read out
  inp="$(jq -r '.usage.input_tokens // 0' <<<"$last")"
  cache_in="$(jq -r '.usage.cache_creation_input_tokens // 0' <<<"$last")"
  cache_read="$(jq -r '.usage.cache_read_input_tokens // 0' <<<"$last")"
  out="$(jq -r '.usage.output_tokens // 0' <<<"$last")"
  if (( inp == 0 && cache_in == 0 && cache_read == 0 && out == 0 )); then
    echo "usage missing — Moonshot PAYG, see provider console"
    return
  fi
  local amount
  amount="$(jq -n --argjson inp "$inp" --argjson cin "$cache_in" --argjson cread "$cache_read" \
    --argjson out "$out" \
    '(($inp + $cin) * 3.0 + $cread * 0.30 + $out * 15.0) / 1e6')"
  printf '$%.4f real PAYG (recomputed @ kimi-k3 list — %s in / %s cached / %s out)' \
    "$amount" "$inp" "$cache_read" "$out"
}

# _ledger_grok_cost <runlog> — the last type==end event's usage + (when present) .total_cost_usd.
# Per grok's own headless doc (~/.grok/docs/user-guide/14-headless-mode.md): cost floats are
# OMITTED whenever cost_is_partial/usage_is_incomplete or on a pool/OAuth-metered path until the
# server stamps cost — absence means UNREPORTED, never free, so this never substitutes a fake $0.
# Three shapes: real cost -> notional dollar figure + token breakdown; cost omitted but usage
# present -> token-only fallback labeled "cost omitted"; no usage at all -> "n/a" (never a bare
# guess). All grok $ figures are notional (SuperGrok weekly pool, not API-billed) per model-lanes.md.
_ledger_grok_cost() {
  local runlog="$1"
  [[ -f "$runlog" ]] || { echo "n/a"; return; }
  local last
  last="$(jq -R -c 'fromjson? // empty' "$runlog" | jq -s -c 'map(select(.type == "end")) | last // empty')"
  [[ -n "$last" && "$last" != "null" ]] || { echo "n/a"; return; }
  local cost inp cached out
  cost="$(jq -r '.total_cost_usd // empty' <<<"$last")"
  inp="$(jq -r '.usage.input_tokens // empty' <<<"$last")"
  cached="$(jq -r '.usage.cache_read_input_tokens // empty' <<<"$last")"
  out="$(jq -r '.usage.output_tokens // empty' <<<"$last")"
  if [[ -n "$cost" ]]; then
    printf '$%s notional (%s in / %s cached / %s out — OAuth weekly pool)' \
      "$cost" "${inp:-0}" "${cached:-0}" "${out:-0}"
    return
  fi
  if [[ -n "$inp" || -n "$cached" || -n "$out" ]]; then
    printf 'cost omitted — OAuth pool-metered (%s in / %s cached / %s out)' \
      "${inp:-0}" "${cached:-0}" "${out:-0}"
    return
  fi
  echo "n/a"
}

# _ledger_append_row <file> <when> <what> <lane> <billed> — inserts one markdown row immediately
# after the LAST existing table line, matching "^|" (any line starting with a pipe: header, the
# separator "|---|", AND data rows all qualify). Matching only "^| " (pipe-SPACE) was a live bug —
# the separator has no space after its opening pipe, so on a header+separator-only table (a freshly
# self-healed ledger's first real append) the anchor found only the header and inserted the new row
# BEFORE the separator, producing malformed markdown. "^|" makes the separator itself count as the
# last table line when there are no data rows yet. Self-heals a missing file with a fresh header —
# lets tests point LEDGER_FILE at a not-yet-existing path without pre-seeding a fixture.
_ledger_append_row() {
  local file="$1" when="$2" what="$3" lane="$4" billed="$5"
  local row="| $when | $what | $lane | $billed |"
  mkdir -p "$(dirname "$file")"
  # This is a read-modify-write over a file every concurrent worker, doctor probe and takeover
  # writer appends to — unlocked, they interleave and the loser's rows vanish. flock on a sidecar
  # lock file serializes the whole RMW; the temp file is per-writer ($$) and in the SAME directory,
  # so the closing rename stays atomic even if two writers somehow overlap.
  # ponytail: one global lock per ledger file — fine at swarm fan-out scale (a handful of appends
  # per run); per-row locking only if a ledger ever becomes a hot path.
  local lock="$file.lock" tmp="$file.tmp.$$"
  exec {_lfd}>>"$lock" || { _ledger_append_unlocked "$file" "$row" "$tmp"; return 0; }
  flock "$_lfd" 2>/dev/null || true
  _ledger_append_unlocked "$file" "$row" "$tmp"
  exec {_lfd}>&-
}

# _ledger_append_unlocked <file> <row> <tmp> — the actual insert; callers hold the lock.
_ledger_append_unlocked() {
  local file="$1" row="$2" tmp="$3"
  if [[ ! -f "$file" ]]; then
    printf '| When | What | Lane | Billed |\n|------|------|------|--------|\n%s\n' "$row" > "$file"
    return 0
  fi
  local lastrow
  # -a is load-bearing: a single stray non-UTF-8 byte in a prompt-derived label makes grep classify
  # the whole ledger as binary and print "binary file matches" INSTEAD of line numbers — lastrow
  # then parses garbage and the row lands in the wrong place (observed live, doctor --live drill
  # 2026-07-25). Text mode unconditionally.
  lastrow="$(grep -an '^|' "$file" | tail -1 | cut -d: -f1 || true)"
  if [[ -z "$lastrow" ]]; then
    printf '%s\n' "$row" >> "$file"
    return 0
  fi
  # `row` goes through ENVIRON, NOT `-v`: GNU awk escape-processes every `-v var=value` assignment,
  # so a `\` / `\n` / `\t` in the prompt-derived label would be turned into a real backslash-escape
  # (a literal newline splits the row across two lines, re-breaking the very table the pipe-escaping
  # in ledger_row protects). ENVIRON values are passed verbatim, no escape processing.
  row="$row" awk -v n="$lastrow" 'NR==n{print; print ENVIRON["row"]; next} {print}' "$file" > "$tmp"
  mv "$tmp" "$file"
}

# _ledger_lane_fields <bare_lane> <runlog> — sets LEDGER_LANE_STR (provider string) and
# LEDGER_BILLED (per-lane cost/usage shape read from the run log). Single owner of the
# lane -> provider/billed mapping: ledger_row and ledger_failed_row must render a lane
# identically, or the ledger's lane column drifts by which finalize path happened to log it.
_ledger_lane_fields() {
  local bare="$1" runlog="$2"
  case "$bare" in
    claude) LEDGER_LANE_STR="Anthropic API (session auth)"; LEDGER_BILLED="$(_ledger_claude_cost "$runlog")" ;;
    glm)    LEDGER_LANE_STR="Z.ai Coding Plan (Anthropic-compat)"; LEDGER_BILLED="$(_ledger_glm_prompts "$runlog")" ;;
    kimi)   LEDGER_LANE_STR="Moonshot PAYG (Anthropic-compat)"; LEDGER_BILLED="$(_ledger_kimi_cost "$runlog")" ;;
    codex)  LEDGER_LANE_STR="ChatGPT session auth (auth.json)"; LEDGER_BILLED="$(_ledger_codex_usage "$runlog")" ;;
    gemini) LEDGER_LANE_STR="Google AI Studio"; LEDGER_BILLED="$(_ledger_gemini_usage "$runlog")" ;;
    grok)   LEDGER_LANE_STR="xAI Grok Build CLI (grok.com OAuth, weekly pool)"; LEDGER_BILLED="$(_ledger_grok_cost "$runlog")" ;;
    *)      LEDGER_LANE_STR="$bare"; LEDGER_BILLED="n/a" ;;
  esac
}

# ledger_row <busdir> <id> — Phase E step 4: one ledger row per successfully finalized branch.
# Reads the SERVED lane from done/<id>'s provenance field (never the requested lane:model — same
# reasoning as served_model), "What" from prompt-<id>.txt (archived on success by
# _finalize_worker's success path, first 60 chars), and the per-lane cost/usage shape from
# run-<id>.jsonl. Target file: $LEDGER_FILE env override, else <busdir's parent>/docs/ops/
# llm-runs.md — deriving it from busdir (never a hardcoded absolute path) means a test's own
# throwaway busdir never touches the real repo ledger by accident. Always writes when called (even
# if LEDGER_AUTO=0) — the AUTOMATIC call site in swarm-run.sh's _finalize_worker is what the
# LEDGER_AUTO gate controls; this function itself has no opinion, so tests can call it directly.
ledger_row() {
  local busdir="$1" id="$2"
  local donefile="$busdir/done/$id"
  [[ -f "$donefile" ]] || return 1
  local lane
  lane="$(jq -r '.lane // empty' "$donefile" 2>/dev/null)"
  [[ -n "$lane" ]] || return 1

  local runlog="$busdir/run-$id.jsonl" promptfile="$busdir/prompt-$id.txt" what
  if [[ -f "$promptfile" ]]; then
    what="$(head -c 60 "$promptfile" | tr '\n' ' ')"
    # A loop-generated exec spec's prompt always starts with `## Criteria (read-only contract …)`,
    # so its first-60-chars label is useless boilerplate identical across every iteration. Fall
    # back to the spec id (which encodes run/iter/role) when the first line is a markdown heading.
    [[ "$what" == \#* ]] && what="$id"
  else
    what="$id"
  fi
  what="${what//|/\\|}"

  _ledger_lane_fields "$lane" "$runlog"
  local file="${LEDGER_FILE:-$(dirname "$busdir")/docs/ops/llm-runs.md}"
  _ledger_append_row "$file" "$(date +%F)" "$what" "$LEDGER_LANE_STR" "$LEDGER_BILLED"
}

# ledger_failed_row <busdir> <id> <bare_lane> <reason> — no-silent-spend companion to ledger_row
# for a spawn that ran a CLI but did NOT finalize successfully (timeout / limit fail-over /
# unusable output). model-lanes.md "Ledger — no silent spend" requires EVERY spawned run to be
# logged, including the lane that served it and why it failed over — not just successful branches.
# A run-<id>.jsonl exists iff a CLI was actually invoked (the tee target); its absence (lane_cmd
# refused before spawn, wrc=9) means zero spend, so this no-ops there. Reads whatever partial usage
# the truncated log carries via the same per-lane shape helpers ("n/a" when the CLI died before
# emitting a usage envelope). rc 0 always (never allowed to fail a finalize path).
ledger_failed_row() {
  local busdir="$1" id="$2" bare="$3" reason="$4"
  local runlog="$busdir/run-$id.jsonl"
  [[ -f "$runlog" ]] || return 0
  _ledger_lane_fields "$bare" "$runlog"
  local file="${LEDGER_FILE:-$(dirname "$busdir")/docs/ops/llm-runs.md}"
  _ledger_append_row "$file" "$(date +%F)" "$id ($reason)" "$LEDGER_LANE_STR" "$LEDGER_BILLED"
  return 0
}

# --- speedwars: per-branch speed-evidence JSONL (spec 08, v0) -----------------------------------

# _run_label <busdir> — P0-FR1 (as amended 2026-07-25, specs/08 §Amendment): THE one derivation of
# the speedwars run-join key (the ledger's `.run` field). Every writer of that field — speed_row,
# run_summary, feedback_stubs below, and swarm-ctl's cmd_review_stub — calls this instead of
# repeating the expression inline, so the key can never drift between writers (PRD plan-004
# pre-mortem #2). Resolution order, first hit wins:
#   1. $SPEEDWARS_RUN — the operator/run override, always first.
#   2. $busdir/.run-label — what THIS bus's own last run pinned (_run_label_persist, written once
#      at run start). Without it the label was re-derived at every hop and persisted nowhere, so a
#      `swarm-ctl review-stub` from a fresh shell re-derived a DIFFERENT key and harvested a
#      foreign run's rows into this bus's stub.
#   3. The derived default: a busdir named ".bus-<suffix>" yields "<suffix>"; anything else (the
#      plain ".bus" layout) yields the busdir's PARENT basename — today's value, so existing
#      ledger rows stay joinable. The suffix rule is what stops every sibling bus in one checkout
#      (.bus, .bus-gtm-a, .bus-tok024, ...) from collapsing onto the single checkout name.
# The default path prints ONE stderr warning per process. Not per busdir-marker-file: a read-only
# caller (review-stub, a report) must not write into the bus at all, and a once-per-bus-LIFETIME
# marker meant the second run against a reused bus was warned about nothing.
_run_label() {
  local busdir="$1"
  if [[ -n "${SPEEDWARS_RUN:-}" ]]; then
    printf '%s' "$SPEEDWARS_RUN"
    return 0
  fi
  local saved=""
  [[ -s "$busdir/.run-label" ]] && IFS= read -r saved < "$busdir/.run-label"
  if [[ -n "$saved" ]]; then
    printf '%s' "$saved"
    return 0
  fi
  local base label; base="$(basename "$busdir")"
  case "$base" in
    .bus-?*) label="${base#.bus-}" ;;
    *)       label="$(basename "$(dirname "$busdir")")" ;;
  esac
  if [[ -z "${_RUN_LABEL_WARNED:-}" ]]; then
    _RUN_LABEL_WARNED=1
    echo "unimatrix: no run label pinned for $busdir — deriving '$label'. Sibling buses in one" \
         "checkout that derive the same label share one ledger run key, so a later harvest" \
         "(review-stub/postmortem) folds their rows together. Set \$SPEEDWARS_RUN to override." >&2
  fi
  printf '%s' "$label"
}

# _run_label_persist <busdir> — pin the RESOLVED label into the bus, at run start only (full_run /
# verify_run / cmd_call, right after bus_init — a write context by definition). Latest run owns the
# bus: this overwrites, so re-running a bus under a new $SPEEDWARS_RUN re-keys it. Every later
# read — including from another shell with no env at all — then agrees with the rows this run wrote.
# Never fatal: an unwritable bus loses the pin and falls back to the derived default, which is
# exactly the pre-amendment behavior.
_run_label_persist() {
  local busdir="$1" label
  label="$(_run_label "$busdir")"
  printf '%s\n' "$label" > "$busdir/.run-label" 2>/dev/null || true
  return 0
}

# _speedwars_file <busdir> — resolve the ledger path speed_row/run_summary both write to:
# $SPEEDWARS_FILE if set (mkdir -p its dirname — an explicit override earns the scaffold), else
# <busdir-parent>/docs/ops/speedwars.jsonl IF that docs/ops dir already exists. Echoes the path on
# stdout; rc 1 (nothing echoed) when no override was given and the default surface doesn't exist —
# never scaffold docs/ops into an arbitrary busdir-parent (temp buses in tests/loops would grow
# real docs trees; same doctrine as llm-runs.md: the evidence surface must exist before a run
# counts). Extracted from speed_row so run_summary (spec 12 FR-3) shares the exact same resolution.
_speedwars_file() {
  local busdir="$1" file
  if [[ -n "${SPEEDWARS_FILE:-}" ]]; then
    file="$SPEEDWARS_FILE"
    mkdir -p "$(dirname "$file")"
  else
    file="$(dirname "$busdir")/docs/ops/speedwars.jsonl"
    [[ -d "$(dirname "$file")" ]] || return 1
  fi
  printf '%s' "$file"
}

# speed_row <busdir> <id> <requested-lane:model> <outcome> [wrc] [pinned] [class] — append one
# JSONL row of speed evidence for a finalized branch. Called from swarm-run.sh's _finalize_worker,
# the only choke point where the requested lane:model and real worker rc are still in scope (the
# done marker hardcodes code:0 and the .lane sidecar is removed on success). Target file: see
# _speedwars_file above. One row = one write(2) append (bus-discipline.md). Never fatal — call
# sites guard with `2>/dev/null || true`.
# Wall clock = now - runlog birth time (ext4 statx %W; caveat: on a retried id the birth is the
# FIRST attempt's spawn while usage reflects the LAST attempt — tee reuses the inode).
# spec 10 FR-R9/R10: if limits/.fbreason-<id> exists (first-writer-wins fallback provenance —
# "<reason> <original_bare_lane>", written by the pool before a blocked-lane chain_advance),
# `fallback_reason` = the first word and `requested` is OVERRIDDEN to the second word (the
# original chain head), so a two-hop fallback still reads as one requested/served_lane pair
# rather than the intermediate hop; the file is consumed (rm'd) on read, first-writer-wins.
# `billing` is "real" iff the SERVED (bare) lane is kimi, else "pool" (every other lane is
# pool-metered, not real-$ per this run). `verify_lane` (= served bare lane) is added on rows for
# a review/judge branch — recognized by id shape: write_verify_spec's "v-*" prefix, or
# swarm-loop.sh's "*-review" per-iteration judge id.
# spec 12 FR-1: optional 7th `class` — one of the failure-class vocabulary values (specs/12), added
# as a `class` key via the SAME absence-means-absent pattern as fallback_reason/verify_lane above —
# never an empty string in JSON. A "done" row passes no 7th arg at all (no class — success has none).
speed_row() {
  local busdir="$1" id="$2" requested="$3" outcome="$4" wrc="${5:-}" pinned="${6:-0}" class="${7:-}"
  # bare (served lane) is derived from the SERVED worker's lane:model — the actual 3rd arg — before
  # any fbreason override below touches `requested`. Only the JSON `requested` field is rewritten;
  # served_lane/billing/verify_lane must all keep reflecting who really served this branch.
  local bare="${requested%%:*}"
  local billing="pool"
  [[ "$bare" == kimi ]] && billing="real"
  local verify_lane=""
  case "$id" in
    v-* | *-review) verify_lane="$bare" ;;
  esac
  # A parked card was never served by ANY lane — served_lane/verify_lane on that row would be a
  # false claim (r3codex MIN); requested still names the seed head, which is real provenance.
  # The null substitution happens INSIDE the jq filter via --arg (never hand-built --argjson —
  # bash-interpolated quotes bypass jq's escaping; final-reviewer MEDIUM).
  if [[ "$outcome" == "parked" ]]; then
    verify_lane=""
    billing="pool"
  fi
  # spec 11 FR-S4: a row struck while a non-fable lane holds the orch_seat carries "degraded":true
  # (succession-era evidence) — absent entirely otherwise, same absence-means-absent pattern as
  # fallback_reason/verify_lane above, never a bare false/null.
  local degraded=false
  orch_degraded "$busdir" && degraded=true
  local file
  file="$(_speedwars_file "$busdir")" || return 0
  # Consume fallback provenance ONLY once a row is guaranteed to be written — a no-op'd
  # speed_row (no evidence surface) must never destroy .fbreason without recording it.
  local fbfile="$busdir/limits/.fbreason-$id" fallback_reason=""
  if [[ -f "$fbfile" ]]; then
    local fbline
    fbline="$(<"$fbfile")"
    fallback_reason="${fbline%% *}"
    requested="${fbline#* }"
    rm -f "$fbfile"
  fi
  # spec 21 FR-10 (spec 08 FR-10 promotion): read the claim stamp; delete it ONLY when THIS row
  # is the claim's TERMINAL row (review round 2026-07-31: a pinned terminal failure writes TWO
  # rows for one claim — the failed attempt, then _park_card's parked row — and
  # consume-on-first-read left the terminal row, the one timeline keeps, stamp-less; and the done
  # path calls _archive_and_release BEFORE its own speed_row, so deletion cannot live there
  # either). Non-terminal rows (retry/timeout attempts) read without deleting; a re-claim
  # overwrites with `>`. Stamp is one _marker_line whose ISO field is the claim time and whose
  # text carries qws=<queue-wait-seconds>, both computed AT claim (swarm-run.sh _try_claim_one) —
  # computing here would race the claim file's archival.
  local stampf="$busdir/limits/$id.claimed-at" claim_ts="" queue_wait=null
  if [[ -f "$stampf" ]]; then
    local sline
    sline="$(<"$stampf")"
    claim_ts="${sline%% *}"
    [[ "$sline" =~ qws=([0-9]+) ]] && queue_wait="${BASH_REMATCH[1]}"
    case "$outcome" in
      done | timeout-salvaged | parked) rm -f "$stampf" ;;
    esac
  fi
  local log="$busdir/run-$id.jsonl"
  local now spawn wall=null sm usage='{}'
  now=$(date +%s)
  spawn=$(stat -c %W "$log" 2>/dev/null || echo 0)
  (( spawn > 0 && spawn <= now )) && wall=$(( now - spawn ))
  sm="$(served_model "$bare" "$busdir" "$id" 2>/dev/null || true)"
  if [[ -s "$log" ]]; then
    # Per-lane terminal-event usage paths verified against 2026-07-19 wave archives:
    # claude/glm last type=result, grok last type=end, codex last type=turn.completed,
    # gemini last type=result (.stats). Timing fields exist on claude/glm only. kimi is the claude
    # binary underneath (child-env swap) so it falls into this same claude/glm default branch below
    # for TOKEN extraction — but its cost_usd is RECOMPUTED at Moonshot list price (same formula as
    # _ledger_kimi_cost), never taken from $e.total_cost_usd, which is claude-CLI Anthropic-list
    # pricing against the swapped base URL — wrong provider.
    #
    # USD-as-proxy pricing (operator directive 2026-07-26; spec 08 FR-2 amendment): every lane that
    # CAN be priced carries a cost_usd at its OWN provider's list price plus a cost_basis tag —
    # subscription/quota lanes included, because the flat fee is still paid and dollars are the
    # cross-lane proxy for pool draw. $/M list prices pinned 2026-07-26 (re-verify on any
    # docs/versions.md model re-pin):
    #   glm-5.2   Z.ai API:  in 1.40 / cache-read 0.26 / out 4.40   (docs.z.ai pricing)
    #   grok-4.5  <200k tier: in 2.00 / cache-read 0.30 / out 6.00  (docs.x.ai/docs/models)
    #   gpt-5-codex:          in 1.25 / cache-read 0.125 / out 10.0 (developers.openai.com; the
    #     ChatGPT-auth default gpt-5.2-codex has no published per-token price — this is the
    #     closest published proxy, and the row is tagged notional either way)
    #   kimi-k3:              in 3.00 / cache-hit 0.30 / out 15.0   (platform.kimi.ai — unchanged)
    # claude keeps the envelope figure (accurate Anthropic list per docs/lane-economics.md);
    # glm's envelope figure is claude-priced garbage and is ALWAYS recomputed (never null-checked —
    # presence of a wrong number must not preserve it); gemini stays unpriced until the key's tier
    # (free vs paid) is recorded — a fabricated nonzero would mislead. cost_basis vocabulary:
    # envelope-list | envelope-pool | recomputed-list | unpriced-tier-unknown.
    usage=$(jq -cs --arg lane "$bare" '
      (if $lane == "grok" then [.[] | select(.type == "end")][-1]
       elif $lane == "codex" then [.[] | select(.type == "turn.completed")][-1]
       else [.[] | select(.type == "result")][-1] end) as $e |
      if $e == null then {} else
        if $lane == "codex" then
          # OpenAI usage.input_tokens INCLUDES cached_input_tokens — split fresh vs cached before
          # pricing or the recompute overstates 3-6x at observed 0.66-0.91 cache ratios.
          ((($e.usage.input_tokens // 0) - ($e.usage.cached_input_tokens // 0)) | if . < 0 then 0 else . end) as $fresh |
          { tokens_in: $e.usage.input_tokens, tokens_out: $e.usage.output_tokens,
            tokens_cached: $e.usage.cached_input_tokens,
            tokens_reasoning: $e.usage.reasoning_output_tokens,
            cost_usd: (($fresh * 1.25
                        + ($e.usage.cached_input_tokens // 0) * 0.125
                        + ($e.usage.output_tokens // 0) * 10.0) / 1e6),
            cost_basis: "recomputed-list",
            turns: ([.[] | select(.type == "turn.completed")] | length) }
        elif $lane == "grok" then
          { tokens_in: $e.usage.input_tokens, tokens_out: $e.usage.output_tokens,
            tokens_cached: $e.usage.cache_read_input_tokens,
            tokens_reasoning: $e.usage.reasoning_tokens,
            cost_usd: ($e.total_cost_usd //
              (((($e.usage.input_tokens // 0) - ($e.usage.cache_read_input_tokens // 0)
                 | if . < 0 then 0 else . end) * 2.0
                + ($e.usage.cache_read_input_tokens // 0) * 0.30
                + ($e.usage.output_tokens // 0) * 6.0) / 1e6)),
            cost_basis: (if $e.total_cost_usd != null then "envelope-pool" else "recomputed-list" end),
            turns: $e.num_turns, stop: $e.stopReason }
        elif $lane == "gemini" then
          { tokens_in: $e.stats.input_tokens, tokens_out: $e.stats.output_tokens,
            tokens_cached: $e.stats.cached, duration_api_ms: $e.stats.duration_ms,
            cost_basis: "unpriced-tier-unknown" }
        else
          { tokens_in: $e.usage.input_tokens, tokens_out: $e.usage.output_tokens,
            tokens_cached: $e.usage.cache_read_input_tokens,
            cost_usd: (if $lane == "kimi" then
                ((($e.usage.input_tokens // 0) + ($e.usage.cache_creation_input_tokens // 0)) * 3.0
                 + ($e.usage.cache_read_input_tokens // 0) * 0.30
                 + ($e.usage.output_tokens // 0) * 15.0) / 1e6
              elif $lane == "glm" then
                ((($e.usage.input_tokens // 0) + ($e.usage.cache_creation_input_tokens // 0)) * 1.40
                 + ($e.usage.cache_read_input_tokens // 0) * 0.26
                 + ($e.usage.output_tokens // 0) * 4.40) / 1e6
              else $e.total_cost_usd end),
            cost_basis: (if $lane == "kimi" or $lane == "glm" then "recomputed-list"
                         else "envelope-list" end),
            turns: $e.num_turns,
            duration_ms: $e.duration_ms, duration_api_ms: $e.duration_api_ms,
            ttft_ms: $e.ttft_ms, is_error: $e.is_error,
            api_error_status: $e.api_error_status }
        end
      end' "$log" 2>/dev/null) || usage='{}'
    [[ -n "$usage" ]] || usage='{}'
  fi
  jq -cn \
    --arg ts "$(date -u +%FT%TZ)" \
    --arg run "$(_run_label "$busdir")" \
    --arg id "$id" --arg requested "$requested" --arg served_lane "$bare" \
    --arg served_model "$sm" --arg outcome "$outcome" \
    --arg fallback_reason "$fallback_reason" --arg billing "$billing" \
    --arg verify_lane "$verify_lane" --arg class "$class" \
    --arg claim_ts "$claim_ts" \
    --argjson wall "$wall" --argjson wrc "${wrc:-null}" --argjson pinned "$pinned" \
    --argjson degraded "$degraded" --argjson queue_wait "$queue_wait" \
    --argjson u "$usage" \
    '{ ts: $ts, run: $run, id: $id, requested: $requested,
       served_lane: (if $outcome == "parked" then null else $served_lane end),
       served_model: (if $served_model == "" then null else $served_model end),
       outcome: $outcome, wrc: $wrc, pinned: ($pinned == 1), wall_secs: $wall,
       billing: $billing }
     + (if $claim_ts == "" then {} else { claim_ts: $claim_ts } end)
     + (if $queue_wait == null then {} else { queue_wait_secs: $queue_wait } end)
     + (if $fallback_reason == "" then {} else { fallback_reason: $fallback_reason } end)
     + (if $verify_lane == "" then {} else { verify_lane: $verify_lane } end)
     + (if $degraded then { degraded: true } else {} end)
     + (if $class == "" then {} else { class: $class } end)
     + $u' \
    >> "$file"
  return 0
}

# _session_stamp — spec 17 FR-7: prints session_id, account, session_marker as three lines
# (empty string, never absent, when a value can't be determined — run_summary's jq turns "" into
# JSON null, the same convention as fallback_reason/verify_lane above). Read-only from the
# environment; touches nothing on disk.
#   session_id     — $CLAUDE_CODE_SESSION_ID verbatim, else empty (verified live: Claude Code sets
#                     this in every child process's env — spec 17 open question 4a).
#   account        — $CLAUDE_ACCOUNT, else basename of $CLAUDE_CONFIG_DIR, else empty
#                     (open question 4c: the multi-account config-dir env var is the fallback).
#   session_marker — the statusline's per-session emoji. LOCKSTEP MIRROR of sessionEmoji() in the
#                     LOCKED (chmod 444) ~/.claude/helpers/statusline-lcars.mjs:106-115 — per the
#                     statusline-lock doctrine (CLAUDE.md), a read-only consumer keeps its own copy
#                     of the formula rather than touch that file. The formula is pure 32-bit
#                     arithmetic over the session-id string (h = h*31 + charcode, masked to
#                     unsigned 32-bit every step, mirroring JS's `>>> 0`), so it ports to bash
#                     exactly with no node dependency — verified byte-identical against the real
#                     .mjs file for two pinned session ids in tests/swarm-lib.bats. If this array,
#                     the modulus, or the hash step ever changes in the .mjs file, this copy must
#                     be updated by hand to match (nothing here may edit the statusline itself).
#                     Empty when session_id is empty.
_session_stamp() {
  local sid="${CLAUDE_CODE_SESSION_ID:-}" acct="${CLAUDE_ACCOUNT:-}" marker=""
  [[ -n "$acct" ]] || acct="${CLAUDE_CONFIG_DIR:+$(basename "$CLAUDE_CONFIG_DIR")}"
  if [[ -n "$sid" ]]; then
    # statusline-lcars.mjs:109 SESSION_EMOJI — 24 single-codepoint entries, in this exact order.
    local -a emoji=('🦊' '🐙' '🦉' '🐢' '🐝' '🦈' '🐋' '🦜' '🐞' '🦕' '🍄' '🌵' '🍒' '🍋' '🥝' '🍩' '🎲' '🎯' '🚀' '🔮' '🧲' '🌋' '🪐' '🛸')
    local h=0 i c code
    for (( i = 0; i < ${#sid}; i++ )); do
      c="${sid:i:1}"
      printf -v code '%d' "'$c"
      h=$(( (h * 31 + code) & 0xFFFFFFFF ))
    done
    marker="${emoji[$(( h % ${#emoji[@]} ))]}"
  fi
  printf '%s\n%s\n%s\n' "$sid" "$acct" "$marker"
}

# run_summary <busdir> <mode> — spec 12 FR-3: one aggregated JSONL row appended to the SAME
# speedwars ledger speed_row writes ($SPEEDWARS_FILE, else <busdir-parent>/docs/ops/speedwars.jsonl
# via the shared _speedwars_file resolver above — same no-op-without-evidence-surface doctrine: a
# temp bus with no ledger file/dir gets no run-summary row, never a scaffolded docs/ tree). Reads
# this run's own branch rows (.type == null and .run == $run) with ONE jq -s pass, last row per id
# wins (a retried id's earlier failed rows don't count toward done_n/parked_n — only its final fate
# does), computed into a shell variable first (never read-and-append the SAME file in one pipeline —
# jq is given the file as an argument to slurp, and only the RESULT, not the read, is appended) —
# then ONE printf append (one write(2), bus-discipline.md). Ids/lanes/classes/counts/paths ONLY —
# never prompt, answer, or stderr CONTENT (FR-3 scrub-by-construction; stderr gets a bare COUNT).
# Called from full_run/verify_run (swarm-run.sh) immediately BEFORE _check_parked, guarded by
# SPEEDWARS_AUTO + `2>/dev/null || true` like every other ledger call site. Never fatal.
run_summary() {
  local busdir="$1" mode="$2" file
  file="$(_speedwars_file "$busdir")" || return 0
  [[ -f "$file" ]] || return 0
  local run; run="$(_run_label "$busdir")"

  # limits/*.limited / *.dead globs AT CALL TIME — lane names are the file basename minus suffix.
  local lanes_limited='[]' lanes_dead='[]' f names
  names=()
  for f in "$busdir"/limits/*.limited; do
    [[ -e "$f" ]] && names+=("$(basename "$f" .limited)")
  done
  (( ${#names[@]} )) && lanes_limited="$(printf '%s\n' "${names[@]}" | jq -R . | jq -sc .)"
  names=()
  for f in "$busdir"/limits/*.dead; do
    [[ -e "$f" ]] && names+=("$(basename "$f" .dead)")
  done
  (( ${#names[@]} )) && lanes_dead="$(printf '%s\n' "${names[@]}" | jq -R . | jq -sc .)"

  # stderr_n: a bare COUNT of non-empty run-*.jsonl.stderr files — the files themselves are the
  # drill-down; content never enters the ledger (spec 12 non-goal: no stderr aggregation).
  local stderr_n=0
  for f in "$busdir"/run-*.jsonl.stderr; do
    [[ -s "$f" ]] && stderr_n=$(( stderr_n + 1 ))
  done

  # spec 17 FR-7: session_id/account/session_marker join keys — read-only, never fatal to the row.
  local sess_id sess_acct sess_marker
  { read -r sess_id; read -r sess_acct; read -r sess_marker; } < <(_session_stamp)

  local summary
  # The ledger is append-only, long-lived and written by concurrent processes, so ONE torn line
  # would make a strict `jq -s` exit nonzero — and `|| return 0` below would silently disable
  # run-summary for that ledger FOREVER. Read it through the codebase's own tolerant reader
  # (extract_answer/served_model/limit_error all use it) so a bad line is skipped, not fatal.
  summary="$(jq -R -c 'fromjson? // empty' "$file" | jq -cs \
    --arg ts "$(date -u +%FT%TZ)" --arg run "$run" --arg mode "$mode" \
    --argjson lanes_limited "$lanes_limited" --argjson lanes_dead "$lanes_dead" \
    --argjson stderr_n "$stderr_n" \
    --arg session_id "$sess_id" --arg account "$sess_acct" --arg session_marker "$sess_marker" \
    '
    map(select(type == "object" and .type == null and .run == $run)) as $rows |
    (reduce $rows[] as $r ({}; .[$r.id] = $r)) as $last |
    ($last | to_entries | map({
        key: .key,
        value: ({ lane: (.value.served_lane // .value.requested), outcome: .value.outcome }
                + (if .value.class then { class: .value.class } else {} end))
      }) | from_entries) as $branches |
    # done_n counts every branch that ended with a done/ MARKER — `timeout-salvaged` writes one
    # too (swarm-run.sh _salvage_timeout), so excluding it broke the FR-3 acceptance criterion
    # that done_n match the bus. The per-branch `outcome` in $branches still distinguishes them.
    ([$last[] | select(.outcome == "done" or .outcome == "timeout-salvaged")] | length) as $done_n |
    ([$last[] | select(.outcome == "parked")] | length) as $parked_n |
    ([$rows[] | select(.fallback_reason != null)] | length) as $fallback_hops |
    ([$rows[].ts] | min) as $mints |
    (if $mints then (now - ($mints | fromdateiso8601)) else 0 end) as $wall |
    (([$rows[] | (.cost_usd // 0)] | add) // 0) as $cost_usd |
    # spec 21 FR-12: top 3 wall-clock sinks, additive key (spec 18 payload escape valve — no
    # contract version bump). Last-row-per-id, so a retried card is judged by its final attempt.
    ([$last[] | select(.wall_secs != null)] | sort_by(-.wall_secs) | .[0:3]
     | map({ id, lane: (.served_lane // .requested), wall_secs, outcome })) as $top_wall |
    { type: "run-summary", ts: $ts, run: $run, mode: $mode,
      branches: $branches, done_n: $done_n, parked_n: $parked_n,
      fallback_hops: $fallback_hops, top_wall: $top_wall,
      lanes_limited: $lanes_limited, lanes_dead: $lanes_dead,
      wall_secs: $wall, cost_usd: $cost_usd, stderr_n: $stderr_n,
      session_id: (if $session_id == "" then null else $session_id end),
      account: (if $account == "" then null else $account end),
      session_marker: (if $session_marker == "" then null else $session_marker end) }
    ')" || return 0
  [[ -n "$summary" && "$summary" != "null" ]] || return 0
  printf '%s\n' "$summary" >> "$file"
  return 0
}

# --- plan 004 P2: close-out lane summary + bus archive ------------------------------------------

# lane_summary <busdir> — P2-FR1: the three-line per-lane summary printed at run close, on STDERR
# (same convention as every other operator notice — stdout stays the machine-parseable results
# block). Layout: ONE LINE PER HEADLINE METRIC with every lane across it, which is the densest
# 3-line shape for a terminal-first reader — the question at close-out is "which lane won on cost /
# on speed / on trust", and that comparison is horizontal.
#
# Every figure is derived by SHELLING src/speedwars-report.sh, the canonical fold — nothing here
# re-aggregates the ledger:
#   - `--json --run <label>` gives the pinned per-lane contract aggregates for THIS run's rows.
#   - p95 wall comes from the same script's human table (column 9). The `--json` object is a
#     PINNED CONTRACT (tests/fixtures/verdict-fold/expected.json, replayed through
#     site/cockpit/fold.js) and must not grow a `p95_wall` field just to feed this line.
# P2-FR2: every figure carries its denominator — $/verified-done its verified/cards and
# priced/attempts counts, p95 its lane attempt count, false-done its judged-card count.
# Never fatal: every step is guarded and returns 0, so a summary failure cannot fail a run.
lane_summary() {
  local busdir="$1" file run rep
  file="$(_speedwars_file "$busdir" 2>/dev/null)" || return 0
  [[ -f "$file" ]] || return 0
  rep="$(dirname "${BASH_SOURCE[0]}")/speedwars-report.sh"
  [[ -f "$rep" ]] || return 0
  run="$(_run_label "$busdir" 2>/dev/null)" || return 0
  [[ -n "$run" ]] || return 0

  local json
  json="$(bash "$rep" --json --run "$run" "$file" 2>/dev/null)" || return 0
  [[ -n "$json" ]] || return 0

  # lane=p95 pairs off the human table. Guard: a data row is a colon-free lane name followed by two
  # integer columns — which the LANE/LANE:CX headers, the coverage caption and the reviews tail all
  # fail, so none of them can be mistaken for a lane.
  local walls
  walls="$(bash "$rep" --run "$run" "$file" 2>/dev/null \
    | awk 'NF >= 11 && $1 !~ /:/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ { printf "%s=%s ", $1, $9 }')" \
    || walls=""

  local out
  out="$(jq -r --arg walls "$walls" '
    def usd: if . == null then "-" else ((. * 1000 | round) / 1000 | tostring) end;
    ($walls | split(" ") | map(select(length > 0) | split("=") | {key: .[0], value: .[1]})
            | from_entries) as $w
    | (.lanes | to_entries | map(select(.value.cards > 0)) | sort_by(.key)) as $L
    | if ($L | length) == 0 then empty else
      "swarm: lane $/verified-done - " + ($L | map(
        "\(.key) \(.value.cost_per_verified_done | usd) [vdone \(.value.verified_done)/\(.value.cards) cards, priced \(.value.cost_priced)/\(.value.attempts) att]")
        | join("  ")),
      "swarm: lane p95 wall (s)    - " + ($L | map(
        "\(.key) \($w[.key] // "-") [n \(.value.attempts) att]") | join("  "))
        + "   (untimed attempts excluded from the percentile)",
      "swarm: lane false-done rate - " + ($L | map(
        (.value.verified_done + .value.false_done) as $j
        | "\(.key) \(if $j == 0 then "-" else ((.value.false_done / $j * 100) | round | tostring) + "%" end) [\(.value.false_done)/\($j) judged]")
        | join("  "))
      end' <<<"$json" 2>/dev/null)" || return 0
  [[ -n "$out" ]] || return 0
  printf '%s\n' "$out" >&2
  return 0
}

# bus_archive <busdir> — plan 004 P2: freeze this run's RAW evidence into
# <ledger-dir>/bus-archives/<run-label>/ at close-out, so a busdir cycle stops destroying it
# (PRD §1: everything under .bus/ is ephemeral; only the speedwars ledger survived). Layout and
# privacy posture are documented in docs/ops/bus-archives/README.md.
#
# Compression is detected PER RUN: zstd if the binary is on PATH, else gzip (always present) — the
# member extension records which, and so does MANIFEST.txt. ZERO new runtime dependency either way.
# Members are globbable: run-*.jsonl.<ext>, *.stderr.<ext>, res-*.txt.<ext>, speedwars.jsonl.<ext>,
# plus markers.tar.<ext> (done/ + limits/ are thousands of tiny files — one tar, not one member
# each) and run-summary.json.
#
# Idempotent per run label: the run's OWN directory is replaced, never another's — the label is
# sanitized to [A-Za-z0-9._-] and "."/".." refused, so a hostile/odd label cannot escape the tree.
# ATOMIC replace (cross-review finding): every member is written into a mktemp SIBLING dir under
# bus-archives/, never into $dir in place — a reader (or a concurrent close-out of the SAME run)
# can then never observe a half-written mix of old and new members. The live $dir is removed only
# in the instant right before the rename into place, so the window a reader could see "no dir at
# all" is as small as one syscall, and "a MIXED dir" never happens at all. Two same-label
# close-outs racing each other still resolve last-writer-wins (acceptable, single operator) but
# each one's members land as one atomic unit, never interleaved.
# Sanitization is LOSSY — "foo/bar" and "foo_bar" both sanitize to "foo_bar" — so whenever
# sanitizing actually CHANGED the label, a short checksum of the RAW label is appended to the
# dirname; a label that needed no sanitizing keeps its plain, historical dirname untouched.
# Never fatal: an unwritable target, a missing tool or a compressor error all return 0.
bus_archive() {
  local busdir="$1" file label run dir root
  [[ "${BUS_ARCHIVE:-1}" == "1" ]] || return 0
  file="$(_speedwars_file "$busdir" 2>/dev/null)" || return 0
  label="$(_run_label "$busdir" 2>/dev/null)" || return 0
  run="${label//[^A-Za-z0-9._-]/_}"
  case "$run" in ""|"."|"..") return 0 ;; esac
  if [[ "$run" != "$label" ]]; then
    run="${run}-$(cksum <<<"$label" | cut -d' ' -f1)"
  fi
  root="$(dirname "$file")/bus-archives"
  dir="$root/$run"

  local -a comp; local ext note=""
  if command -v zstd >/dev/null 2>&1; then
    comp=(zstd -q -T0 -c); ext=zst
  else
    comp=(gzip -c); ext=gz; note='  [zstd not on PATH — gzip substituted]'
  fi

  mkdir -p "$root" 2>/dev/null || return 0
  local tmp; tmp="$(mktemp -d "$root/.archive-XXXXXX" 2>/dev/null)" || return 0

  local f base
  for f in "$busdir"/run-*.jsonl "$busdir"/run-*.jsonl.[0-9]* "$busdir"/run-*.stderr \
           "$busdir"/res-*.txt "$busdir"/write-*.txt; do
    [[ -f "$f" ]] || continue
    base="$(basename "$f")"
    "${comp[@]}" < "$f" > "$tmp/$base.$ext" 2>/dev/null || rm -f "$tmp/$base.$ext"
  done

  local -a mdirs=()
  [[ -d "$busdir/done" ]] && mdirs+=("done")
  [[ -d "$busdir/limits" ]] && mdirs+=("limits")
  if (( ${#mdirs[@]} )); then
    tar -C "$busdir" -cf - "${mdirs[@]}" 2>/dev/null | "${comp[@]}" > "$tmp/markers.tar.$ext" \
      || rm -f "$tmp/markers.tar.$ext"
  fi

  # This run's own ledger slice + its last run-summary row. Read through the tolerant reader (same
  # reason as run_summary): one torn line in a long-lived append-only ledger must not void the
  # archive.
  local rows
  rows="$(jq -R -c 'fromjson? // empty' "$file" 2>/dev/null || true)"
  if [[ -n "$rows" ]]; then
    jq -c --arg run "$label" 'select(.run == $run)' <<<"$rows" 2>/dev/null \
      | "${comp[@]}" > "$tmp/speedwars.jsonl.$ext" || rm -f "$tmp/speedwars.jsonl.$ext"
    jq -s -c --arg run "$label" \
      '[.[] | select(.type == "run-summary" and .run == $run)] | last // {}' <<<"$rows" \
      > "$tmp/run-summary.json" 2>/dev/null || rm -f "$tmp/run-summary.json"
  fi

  # MANIFEST.txt: what is in here, and which compressor produced it. Bus BASENAME only — never an
  # absolute operator path (archives are gitignored, but evidence should still be portable).
  {
    printf 'run: %s\n' "$label"
    printf 'archived: %s\n' "$(date -u +%FT%TZ)"
    printf 'bus: %s\n' "$(basename "$busdir")"
    printf 'compressor: %s (.%s)%s\n' "${comp[0]}" "$ext" "$note"
    printf 'members:\n'
    ( cd "$tmp" && ls -1 ) 2>/dev/null | sed 's/^/  /'
  } > "$tmp/MANIFEST.txt" 2>/dev/null || true

  rm -rf "$dir" 2>/dev/null || true
  mv "$tmp" "$dir" 2>/dev/null || rm -rf "$tmp" 2>/dev/null || true
  return 0
}

# feedback_stubs <busdir> [extra-class ...] — spec 12 FR-4: auto-drafted feedback/ stubs, one per
# detected failure class per run, `status: draft` (a nudge, never a triage — the human triager
# confirms or deletes it, see feedback/README.md "Draft stubs"). Classes are detected from DURABLE
# SURFACES only — limits/ flag files and this run's own speedwars ledger rows — NEVER
# res-*/run-*/prompt-* worker-output CONTENT, so a fetched-web/credential-bearing answer can never
# leak into a committed file. Gated by FEEDBACK_AUTO (conf_load default 1). Idempotent: skips a
# class whose target filename already exists in feedback/ or feedback/archive/ (safe across
# re-invocation and the full->verify sequence, same idempotence contract as write_verify_spec).
feedback_stubs() {
  local busdir="$1"; shift
  [[ "${FEEDBACK_AUTO:-1}" == "1" ]] || return 0

  local repo_root
  repo_root="$(git -C "$(dirname "$busdir")" rev-parse --show-toplevel 2>/dev/null || dirname "$busdir")"
  local feedback_dir="${FEEDBACK_DIR:-$repo_root/feedback}"
  # Never scaffold feedback/ into an arbitrary parent — same no-op-without-evidence-surface
  # doctrine as _speedwars_file's default path: the drop-box must already exist for a run to count.
  [[ -d "$feedback_dir" ]] || return 0
  local repo; repo="$(basename "$repo_root")"
  # _run_label (P0-FR1): THE SAME derivation speed_row/run_summary/swarm-ctl review-stub call — it
  # used to be the busdir's basename here, so on the default BUSDIR=<repo>/.bus the ledger probes
  # below queried run=".bus" against rows stamped run="<repo>" and the timeout/unusable classes
  # silently never fired.
  local run; run="$(_run_label "$busdir")"
  local today; today="$(date -u +%F)"
  # Stubs are TRACKED repo files in a repo whose trunk is public — every interpolated path is made
  # repo-relative so an absolute operator path can never be auto-committed (check.sh's PII gate
  # covers feedback/ too now, but the generator must not produce hits in the first place).
  local busrel="${busdir#"$repo_root"/}"

  local classes=() f
  for f in "$busdir"/limits/*.parked; do [[ -e "$f" ]] && { classes+=(parked); break; }; done
  for f in "$busdir"/limits/*.dead "$busdir"/limits/*.broken; do
    [[ -e "$f" ]] && { classes+=(lane-down); break; }
  done
  # spec 14 FR-1: an environment fault that voided real spend — durable marker, so no ledger probe.
  for f in "$busdir"/limits/*.cage-denied; do [[ -e "$f" ]] && { classes+=(cage-denied); break; }; done

  local sw_file swrel=""; sw_file="$(_speedwars_file "$busdir" 2>/dev/null || true)"
  if [[ -n "$sw_file" && -f "$sw_file" ]]; then
    swrel="${sw_file#"$repo_root"/}"
    # Tolerant reader first (same reason as run_summary): one torn ledger line must not silently
    # switch these two detections off forever.
    local swrows; swrows="$(jq -R -c 'fromjson? // empty' "$sw_file" 2>/dev/null || true)"
    [[ "$(jq -s --arg run "$run" 'any(.[]; type == "object" and .run == $run and .outcome == "timeout")' \
          <<<"$swrows" 2>/dev/null)" == "true" ]] && classes+=(timeout)
    [[ "$(jq -s --arg run "$run" 'any(.[]; type == "object" and .run == $run and .outcome == "lane-unusable")' \
          <<<"$swrows" 2>/dev/null)" == "true" ]] && classes+=(unusable)
  fi
  classes+=("$@")  # extra classes the caller already knows fired (e.g. swarm-loop's "loop-halted")

  local class fname severity body
  for class in "${classes[@]}"; do
    fname="$today-$repo-$run-auto-$class.md"
    [[ -e "$feedback_dir/$fname" || -e "$feedback_dir/archive/$fname" ]] && continue

    case "$class" in
      parked | lane-down | loop-halted | cage-denied) severity=major ;;
      *) severity=minor ;;
    esac
    body="$(_feedback_stub_body "$busdir" "$class" "$run" "$sw_file" "$busrel" "$swrel")"

    {
      # `source:` is the repo NAME, never its absolute path (the name is already in the filename).
      printf -- '---\nsource: %s\ndate: %s\nrun: %s\ntype: bug\nseverity: %s\nstatus: draft\n---\n\n' \
        "$repo" "$today" "$run" "$severity"
      printf '%s\n' "$body"
    } > "$feedback_dir/$fname"
  done
  return 0
}

# _feedback_stub_body <busdir> <class> <run> <sw_file> <busrel> <swrel> — the fixed per-class body
# template (feedback_stubs' private helper). Interpolates ONLY ids/lanes/counts/paths pulled from
# durable surfaces (limits/ flags, speedwars ledger METADATA rows — never res-*/run-*/prompt-*
# content), and only the REPO-RELATIVE spellings of those paths: the stub is a TRACKED file in a
# public repo, so an absolute operator path in it is a leak, not evidence.
_feedback_stub_body() {
  local busdir="$1" class="$2" run="$3" sw_file="$4" busrel="${5:-$1}" swrel="${6:-$4}" f ids=()
  case "$class" in
    parked)
      for f in "$busdir"/limits/*.parked; do [[ -e "$f" ]] && ids+=("$(basename "$f" .parked)"); done
      printf 'Auto-detected: %d branch(es) parked (lane exhausted) this run: %s\n\n' \
        "${#ids[@]}" "${ids[*]:-none}"
      printf 'Evidence: %s/limits/*.parked\n' "$busrel"
      ;;
    lane-down)
      for f in "$busdir"/limits/*.dead "$busdir"/limits/*.broken; do
        [[ -e "$f" ]] && ids+=("$(basename "$f")")
      done
      printf 'Auto-detected: lane(s) marked dead/broken this run: %s\n\n' "${ids[*]:-none}"
      printf 'Evidence: %s/limits/*.dead, %s/limits/*.broken\n' "$busrel" "$busrel"
      ;;
    cage-denied)
      # Marker body is `denials=<n>` + one denied path per line (swarm-run's gate writes it). The
      # paths name the card's WRITE TARGET, which routinely lives outside this repo, so every one is
      # re-anchored on ~ before it reaches a tracked file — check.sh's PII gate is the backstop, not
      # the design.
      local p
      for f in "$busdir"/limits/*.cage-denied; do
        [[ -e "$f" ]] && ids+=("$(basename "$f" .cage-denied)")
      done
      printf 'Auto-detected: %d card(s) whose reads were denied by the permission cage this run: %s\n\n' \
        "${#ids[@]}" "${ids[*]:-none}"
      printf 'Denied paths (first 5 per card):\n'
      for f in "$busdir"/limits/*.cage-denied; do
        [[ -e "$f" ]] || continue
        while IFS= read -r p; do
          printf -- '- %s: %s\n' "$(basename "$f" .cage-denied)" "${p/#$HOME/\~}"
        done < <(grep -v '^denials=' "$f" | head -5)
      done
      printf '\nEvidence: %s/limits/*.cage-denied\n' "$busrel"
      ;;
    timeout | unusable)
      local oc="lane-unusable"; [[ "$class" == timeout ]] && oc="timeout"
      local rows='[]'
      if [[ -n "$sw_file" && -f "$sw_file" ]]; then
        rows="$(jq -R -c 'fromjson? // empty' "$sw_file" 2>/dev/null | jq -sc --arg run "$run" --arg oc "$oc" \
          '[.[] | select(type == "object" and .run == $run and .outcome == $oc)
                | {id, lane: (.served_lane // .requested)}]' 2>/dev/null || echo '[]')"
      fi
      printf 'Auto-detected: %s branch(es) with outcome=%s this run.\n\n' "$(jq 'length' <<<"$rows")" "$oc"
      printf 'Affected (id lane): %s\n\n' "$(jq -r '[.[] | "\(.id) \(.lane)"] | join(", ")' <<<"$rows")"
      printf 'Evidence: %s (run-<id>.jsonl per id; res-<id>.txt if still present)\n' "${swrel:-<speedwars ledger>}"
      printf 'Ready-to-paste jq filter: jq -c '"'"'select(.run == "%s" and .outcome == "%s")'"'"' %s\n' \
        "$run" "$oc" "${swrel:-<speedwars.jsonl>}"
      ;;
    loop-halted)
      local halted
      # `|| true` is load-bearing, not decoration: under `set -o pipefail` (this file's own
      # set -euo pipefail), `find` failing (e.g. $busdir/loop absent — this class can fire from a
      # context with no loop/ dir at all) makes the WHOLE pipeline's exit status nonzero, which
      # would trip errexit on this plain assignment and abort the caller (same failure class as
      # docs/02-build-pitfalls.md #18).
      halted="$(find "$busdir/loop" -maxdepth 2 -name HALTED.md -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn | head -1 | cut -d' ' -f2-)" || true
      halted="${halted:+$busrel/${halted#"$busdir"/}}"  # find returns absolute — re-anchor on busrel
      printf 'Auto-detected: swarm-loop halted this run.\n\n'
      printf 'Evidence: %s\n' "${halted:-$busrel/loop/}"
      ;;
    *)
      printf 'Auto-detected: class %s fired this run.\n' "$class"
      ;;
  esac
}

# --- ground-control: web-cockpit auto-ensure + auto-open (specs/05-ground-control.md) -----------

# mon_web_ensure — start the local web cockpit (site/server.mjs) the same way `gc` would, so `gc`
# adopts the unit, unless it's already up. Deliberately takes no args (unlike every other function
# above): it's wired verbatim as `mon_web_ensure && mon_web_open` right after bus_init in
# swarm-run.sh/swarm-loop.sh, which by then already have a global $BUSDIR in scope — mon_web_open
# needs it for the marker path. Never allowed to fail the caller: every branch ends `return 0`.

# _mon_web_fresh <port> <repo_dir> — is the cockpit on <port> one we can adopt? rc 0 = yes (live and
# serving <repo_dir>'s current HEAD), rc 1 = nothing live (nothing to stop), rc 2 = live but STALE.
# "Live" was the whole test before, which meant a cockpit booted at an older commit — or a pre-FR-4
# one whose /health carries no `head` at all — was adopted forever and never picked up new server
# code. /health resolves its git state per request (site/server.mjs) precisely so this comparison
# means something.
_mon_web_fresh() {
  local port="$1" repo_dir="$2" health head_got head_want
  health="$(curl -fsS --max-time 2 "http://127.0.0.1:$port/health" 2>/dev/null)" || return 1
  head_got="$(jq -r '.head // empty' <<<"$health" 2>/dev/null || true)"
  head_want="$(git -C "$repo_dir" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  [[ -n "$head_got" && "$head_got" == "$head_want" ]] && return 0
  return 2
}

mon_web_ensure() {
  local MON_PORT="${MON_PORT:-4747}"
  [[ "${MON_AUTOOPEN:-1}" == "0" ]] && return 0

  local repo_dir
  repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

  local fresh=0
  _mon_web_fresh "$MON_PORT" "$repo_dir" || fresh=$?
  (( fresh == 0 )) && return 0
  if (( fresh == 2 )); then
    echo "unimatrix: cockpit on :$MON_PORT is not this checkout's HEAD — replacing it" >&2
    # Exact on the systemd branch (we own the unit name). The fallback branch below spawns a bare
    # setsid/nohup child with no unit and no recorded pid, and a pkill on "node site/server.mjs"
    # would take out an unrelated checkout's cockpit — so on a systemd-less box the replace is
    # best-effort: the relaunch loses the port bind, the stale cockpit survives, and the operator
    # keeps it until they restart it by hand. Loud line above, never a silent adoption.
    systemctl --user stop svc-unimatrix >/dev/null 2>&1 || true
  fi

  if command -v systemd-run >/dev/null 2>&1; then
    systemctl --user reset-failed svc-unimatrix >/dev/null 2>&1 || true
    # A systemd --user unit inherits the USER MANAGER's environment, never this shell's — so every
    # var server.mjs reads must be forwarded explicitly. The fallback branch below gets them for
    # free by inheritance, which is exactly how BUSDIR went missing here and made /health report a
    # busdir the cockpit wasn't actually watching. An unset var forwards as empty, which server.mjs
    # already treats as "use the default".
    systemd-run --user --unit=svc-unimatrix --working-directory="$repo_dir" \
      --setenv=PORT="$MON_PORT" --setenv=BUSDIR="${BUSDIR:-}" \
      --setenv=SWARM_CONF="${SWARM_CONF:-}" --setenv=SPEEDWARS_FILE="${SPEEDWARS_FILE:-}" \
      -p KillMode=control-group -p TimeoutStopSec=10 -p Restart=no \
      -- node site/server.mjs >/dev/null 2>&1 || true
  else
    ( cd "$repo_dir" && PORT="$MON_PORT" setsid nohup node site/server.mjs >/dev/null 2>&1 & )
  fi

  # Plain counter + while, not `for ((i++))` — kill_subtree's own comment above explains why a
  # C-style post-increment trips errexit on its first iteration (the expression evaluates to the
  # OLD value, 0, which is falsy).
  # Same freshness test as the adoption check above, not a bare liveness probe: on the best-effort
  # replace path a surviving stale cockpit still answers /health, and treating that as "started"
  # would report success for the very server we just tried to evict.
  local tries=0
  while (( tries < 10 )); do
    _mon_web_fresh "$MON_PORT" "$repo_dir" && return 0
    sleep 0.5
    tries=$(( tries + 1 ))
  done
  return 0
}

# mon_web_open — open the cockpit in a browser, once per bus lifetime (marker file, not a bus
# record — a plain dotfile touch is fine here). No args; reads the caller's global $BUSDIR, same
# reasoning as mon_web_ensure above. Never allowed to fail the caller: every branch ends `return 0`.
mon_web_open() {
  local MON_PORT="${MON_PORT:-4747}"
  [[ "${MON_AUTOOPEN:-1}" == "0" ]] && return 0
  # shellcheck disable=SC2153  # deliberate global, not a typo for local `busdir` — see the
  # function comment above: this reads the caller's own top-level $BUSDIR (swarm-run.sh/
  # swarm-loop.sh set it before sourcing this file).
  # create-exclusive (noclobber, subshell so set -C never leaks to the caller) so two swarms
  # racing on a fresh bus can't both open a tab — the O_EXCL winner opens, the loser returns.
  ( set -C; : > "$BUSDIR/.cockpit-opened" ) 2>/dev/null || return 0

  local url="http://localhost:$MON_PORT/cockpit.html"
  if [[ -n "${MON_OPEN_CMD:-}" ]]; then
    # shellcheck disable=SC2086  # MON_OPEN_CMD is an intentionally word-split opener command
    # (tests stub it with e.g. "true"; real use is a single binary name) — never a quoted string.
    $MON_OPEN_CMD "$url" >/dev/null 2>&1 || true
  elif command -v wslview >/dev/null 2>&1; then
    wslview "$url" >/dev/null 2>&1 || true
  elif command -v powershell.exe >/dev/null 2>&1; then
    powershell.exe -NoProfile -Command "Start-Process '$url'" >/dev/null 2>&1 || true
  elif [[ -x /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe ]]; then
    /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -NoProfile -Command \
      "Start-Process '$url'" >/dev/null 2>&1 || true
  fi
  return 0
}

# --- P0-FR2 (repo half): doctor skill-drift check ------------------------------------------------
# Account-side symlinking of the 7 skill copies is a separate change (owned elsewhere); this is
# the read-only mechanical check `unimatrix doctor` gains so "are all accounts in sync" is asked
# every run instead of assumed once and never re-checked (plan-004 PRD P0-FR2).

# doctor_skill_drift <repo_root> — one PASS/FAIL row named "skill-drift" for cmd_doctor (swarm-
# run.sh; not this file, so it stays a plain function callers wire in rather than a hook this
# file invokes itself — same reasoning as _doctor_ledger_row et al. living beside their own
# caller). Globs every installed copy of the skill file: $HOME/.claude/skills/unimatrix/SKILL.md
# plus $HOME/.claude-acct/*/skills/unimatrix/SKILL.md — EITHER glob may legitimately match nothing
# (a bare box with no accounts configured yet), so zero copies found is PASS, not a false alarm.
# PASS requires BOTH: every copy's hash reduces to exactly one unique value (content identical),
# AND every copy is a symlink resolving to the CANONICAL skill file of this same repository — a
# hand-copy that HAPPENS to currently match content still FAILs, because content-equality is not
# what prevents drift going forward; the symlink is (spec 17's whole P0-FR2 point, and the tripwire
# the PRD names: "accounts already symlink other skills, so the pattern exists"). A link pointing
# at some other in-repo file, and a link pointing at nothing at all, are both drift too.

# _resolve_link <path> — `readlink -f` without needing it: BSD/macOS readlink has no -f, and this
# file's callers run on both (doctor already feature-detects GNU-vs-BSD for stat/sed/realpath).
# Follows the symlink chain with plain POSIX `readlink`, re-anchoring relative targets, then
# canonicalizes the containing directory with cd + `pwd -P`. Bounded at 20 hops so a symlink loop
# cannot hang doctor.
_resolve_link() {
  local p="$1" n=0 t d
  while [[ -L "$p" ]] && (( n < 20 )); do
    t="$(readlink "$p")" || break
    if [[ "$t" == /* ]]; then p="$t"; else p="$(dirname "$p")/$t"; fi
    n=$(( n + 1 ))
  done
  d="$(cd "$(dirname "$p")" 2>/dev/null && pwd -P)" || return 1
  printf '%s/%s' "$d" "$(basename "$p")"
}

# _hash_file <path> — a content fingerprint using whatever this box has: GNU md5sum, BSD `md5 -q`,
# else shasum (doctor's own sha256 probe already assumes one of the last two exists). Only equality
# ACROSS the copies matters here, never which algorithm produced it — one process, one tool.
# Prints nothing when the file can't be read, which the caller reads as "no hash".
_hash_file() {
  local out
  if out="$(md5sum "$1" 2>/dev/null)" || out="$(md5 -q "$1" 2>/dev/null)" \
     || out="$(shasum "$1" 2>/dev/null)"; then
    printf '%s' "${out%% *}"
  fi
}

# _git_common_dir <dir> — the absolute, resolved path of <dir>'s shared .git directory, or nothing
# when <dir> is not in a repo. Every worktree of one repository reports the SAME common dir while
# their checkouts (and `--show-toplevel`) differ, which is what makes it the right identity test in
# doctor_skill_drift below. `--path-format=absolute` is git >= 2.31 only, so the relative form is
# re-anchored by hand instead.
_git_common_dir() {
  local d="$1" out
  out="$(git -C "$d" rev-parse --git-common-dir 2>/dev/null)" || return 0
  [[ -n "$out" ]] || return 0
  [[ "$out" == /* ]] || out="$d/$out"
  realpath -m "$out" 2>/dev/null || printf '%s' "$out"
}

doctor_skill_drift() {
  local repo_root="$1" canon_real canon_common
  canon_real="$(cd "$repo_root" 2>/dev/null && pwd)" || canon_real="$repo_root"
  canon_common="$(_git_common_dir "$canon_real")"

  # -L as well as -e: `-e` follows the link, so a box where every installed copy is a BROKEN
  # symlink inventoried zero copies and reported the all-clear "no copies found" PASS.
  local files=() f
  for f in "$HOME/.claude/skills/unimatrix/SKILL.md" "$HOME"/.claude-acct/*/skills/unimatrix/SKILL.md; do
    [[ -e "$f" || -L "$f" ]] && files+=("$f")
  done

  if (( ${#files[@]} == 0 )); then
    echo "skill-drift  PASS (no installed copies found)"
    return 0
  fi

  local hashes=() bad=() target
  for f in "${files[@]}"; do
    if [[ ! -L "$f" ]]; then
      bad+=("$f (not a symlink)")
      hashes+=("$(_hash_file "$f")")
      continue
    fi
    if [[ ! -e "$f" ]]; then
      bad+=("$f (broken symlink)")   # nothing to hash; the dangling link is the finding
      continue
    fi
    hashes+=("$(_hash_file "$f")")
    target="$(_resolve_link "$f" 2>/dev/null || true)"
    # The link must land on the canonical skill FILE, not merely somewhere inside the repo —
    # SKILL.md -> CHANGELOG.md would otherwise pass while every account served the wrong content.
    if [[ "$target" != */.claude/skills/unimatrix/SKILL.md ]]; then
      bad+=("$f (symlink target is not the canonical skill file: ${target:-unresolvable})")
      continue
    fi
    [[ "$target" == "$canon_real"/* ]] && continue
    # A sibling git WORKTREE of the same repository is not drift: the links point at the main
    # checkout, so their target is outside THIS worktree's path while still being the same repo.
    # Same git-common-dir = same repository, any worktree = PASS; a genuinely foreign checkout
    # (or no repo at all on either side) still FAILs.
    if [[ -n "$canon_common" ]] \
       && [[ "$(_git_common_dir "$(dirname "$target")")" == "$canon_common" ]]; then
      continue
    fi
    bad+=("$f (symlink target outside the repo)")
  done

  local unique_n=0
  (( ${#hashes[@]} )) && unique_n="$(printf '%s\n' "${hashes[@]}" | sort -u | wc -l)"

  if (( unique_n == 1 )) && (( ${#bad[@]} == 0 )); then
    echo "skill-drift  PASS (${#files[@]} copies, 1 hash, all symlinked into the repo)"
    return 0
  fi

  local detail="$unique_n distinct hash(es) across ${#files[@]} copies"
  if (( ${#bad[@]} > 0 )); then
    local joined; joined="$(printf '%s, ' "${bad[@]}")"
    detail+="; ${joined%, }"
  fi
  echo "skill-drift  FAIL ($detail)"
  return 1
}
