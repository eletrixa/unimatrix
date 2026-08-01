# Spec 20 — Per-Run Bus Namespacing

**Status:** Active (activated 2026-07-26 — Robert, explicit: "spec active", confirming the
plan-005 "complete all waves" directive that gates Wave 7 on this spec; backlog items 11 and 21,
both MAJOR — concurrent run collisions on shared bus)
**Date:** 2026-07-26
**Related specs:** [01-swarm-core](./01-swarm-core.md) (bus lifecycle), [04-settings](./04-settings.md) (precedence doctrine), [08-speedwars](./08-speedwars.md) (run-label amendment 2026-07-25), [02-cockpit](./02-cockpit.md) (monitor cockpit)

---

## Overview

Today when two swarm runs happen to share one bus (the default `.bus` or an explicit `$BUSDIR`), they collide — speedwars ledger rows fold into the same `run` key, queue markers and limits bleed across runs, and the cockpit monitor shows duplicate/tangled state. The operator hand-crafts `BUSDIR`/`SPEEDWARS_RUN` per run to work around this (`BUSDIR=.bus-foo SPEEDWARS_RUN=foo ./swarm-run.sh`), but these pieces can drift apart (one set, one forgotten), and the cockpit surface has no atomic identity to track.

Spec 20 introduces a single `--run <label>` command-line flag on `swarm-run.sh` that atomically derives:
- **`BUSDIR`** = `<repo>/.bus-<label>` (new namespaced layout, or `.bus` if label is empty)
- **`SPEEDWARS_RUN`** = `<label>` (run-label for ledger join keys)
- **Cockpit identity** = `<label>` (Ground Control registration, bus listing)

All three stay in lockstep from one token. Existing env-var overrides preserve spec 04's precedence doctrine (explicit env > flag derivation > baked default), and backward compatibility keeps bare `BUSDIR` env working unchanged.

## Goals

1. **Atomicity:** derive `BUSDIR`, `SPEEDWARS_RUN`, and cockpit identity from a single `--run <label>` token; operator cannot forget one.
2. **Precedence:** maintain spec 04 doctrine: per-run env overrides > `--run` derivation > baked config defaults. A user can still override any one (e.g., `BUSDIR=/tmp/custom ./swarm-run.sh --run foo`).
3. **Collision safety:** refuse to start whenever the target bus carries a LIVE heartbeat (two live pools on one busdir is never safe, same label included); a stale or absent heartbeat resumes/reclaims the bus.
4. **Cockpit visibility:** Ground Control lists one entry per live bus with the run label as the identity; a human can watch concurrent runs side-by-side.
5. **Backward compatibility:** bare `BUSDIR` env without `--run` continues to work unchanged for scripts/automation that pre-date this spec.

## Non-Goals

- No multi-bus scheduling or coordination logic (each run is independent).
- No cross-bus dedup or intelligent merging of limit state.
- No daemon to track live buses — liveness is the existing spec 11 heartbeat at each bus's root.
- No UI/interactive configuration — `--run` is a CLI flag only.

## Requirements

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-1 | `swarm-run.sh` accepts a `--run <label>` flag (before the `<question>` positional); when present, derive `BUSDIR` from `<label>` as `<cwd>/.bus-<label>` (the caller's working directory), and set `SPEEDWARS_RUN=<label>`. Both remain overrideable by explicit env (precedence: `$BUSDIR` env > derived; `$SPEEDWARS_RUN` env > derived). | Must |
| FR-2 | When `--run` is NOT supplied, `BUSDIR` defaults to `.bus` (today's behavior unchanged), and `SPEEDWARS_RUN` defaults per spec 08's amendment (empty, then `.run-label` file, then derived from busdir parent basename). | Must |
| FR-3 | Collision detection after the BUSDIR path is FINAL: check the bus's existing `heartbeat` file (bus root — the spec 11 succession heartbeat; age < 60s = live). A LIVE heartbeat always refuses with loud stderr and nonzero exit — a second live pool on one busdir is never safe, same label included (that case IS an accidental double-invocation). No heartbeat, or a stale one, proceeds — same-label re-invocation of a finished/dead run resumes the bus (idempotent re-entry, stale bus reclaimable). **Amended at activation 2026-07-26 (implementation findings):** (a) the gate applies at the NEW-WORK entries only — `full_run` and `cmd_call` (in `cmd_call`, after its own busdir default resolution); `verify` is exempt: it is an owner-invoked post-pass on an existing run's bus, and gating it would refuse the very orchestrator that keeps the heartbeat fresh. (b) The heartbeat file is a bare `touch` with no owner identity, so a parent that OWNS the live heartbeat and legitimately drives a child run on its own bus — swarm-loop iterations — asserts ownership with `UNIMATRIX_BUS_OWNER=1` in the child env (env-only, never a conf key; without it every loop iteration would refuse its own parent's bus). (c) Honesty bound: the gate is exactly as strong as heartbeat discipline — bare headless `swarm-run.sh` invocations never write the heartbeat (FR-4), so two bare runs hand-pointed at one busdir remain the operator's own foot-gun, unchanged from before this spec. | Must |
| FR-4 | Liveness derives from the EXISTING spec 11 orchestrator heartbeat (`<busdir>/heartbeat`, maintained by `swarm-ctl heartbeat`/the orchestrator loop) — spec 20 adds no second heartbeat file and no new writer; it only READS the existing one at `bus_init` collision check. | Must |
| FR-5 | `swarm-loop.sh` passes the `--run <label>` flag through on every `swarm-run.sh` invocation (per-iteration fork), so loop iterations share the same bus and ledger run key atomically. | Must |
| FR-6 | `unimatrix call` (`cmd_call` verb in swarm-run.sh) derives bus/ledger from the `--run <label>` flag (if supplied) or bare env BUSDIR/SPEEDWARS_RUN. The aggregate row (`docs/ops/llm-runs.md` or equivalent, spec 18 FR-R7) carries the resolved run label — never `n/a` when a label was derivable. | Must |
| FR-7 | Ground Control (`docs/ground-control/`, spec 05) registers each bus by its run label (from `_run_label($BUSDIR)` at startup). When multiple buses are live (e.g., `.bus-alpha` and `.bus-beta` on the same repo), the fleet view shows one row per bus with the label and current phase. **STAGED — not yet shipped (2026-07-26):** `site/server.mjs` is single-bus (one `BUSDIR` env per instance); the fleet view is this spec's own Migration Path wave 3 and lands as its own cockpit wave. Until then, concurrent runs are watched as one cockpit instance per bus (`MON_PORT` differs per run). | Must (staged) |
| FR-8 | Backward compatibility: an existing script/automation that sets `BUSDIR=/path/to/bus` without `--run` continues to work unchanged. The run derives its label from the bus as before (spec 08 amendment: `.run-label` file, then busdir parent basename). No forced flag, no error. | Must |
| FR-9 | Help text (`swarm-run.sh --help`) documents the `--run` flag: "Label for this run; derives BUSDIR=.bus-<label>, SPEEDWARS_RUN=<label>. Env vars override the derivation. Incompatible with explicit BUSDIR env (precedence: explicit env wins)." | Must |
| FR-10 | Bats coverage: flag parsing, derivation of BUSDIR/SPEEDWARS_RUN from `--run <label>`, collision detection (live heartbeat → refuse regardless of label, stale/absent → proceed), heartbeat write/reap, loop iteration preserves `--run`, aggregate row labeling. | Must |

## Design

### Flag Parsing & Derivation

`swarm-run.sh` argument parsing (before the positional `<question>`):

```bash
RUN_LABEL=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run)
      RUN_LABEL="$2"
      shift 2
      ;;
    --help|-h)
      show_help
      exit 0
      ;;
    -*)
      error "unknown flag: $1"
      ;;
    *)
      # positional arg (question) — stop parsing
      break
      ;;
  esac
done
QUESTION="$1"  # positional arg
```

After parsing, apply precedence ONCE at run start (`full_run` → `bus_init`):

```bash
# Precedence: explicit env > --run derivation > baked default
if [[ -z "${BUSDIR:-}" && -n "$RUN_LABEL" ]]; then
  BUSDIR="$(_abspath "$PWD/.bus-$RUN_LABEL")"
fi
BUSDIR="${BUSDIR:-$(_abspath "$PWD/.bus")}"  # final default

if [[ -z "${SPEEDWARS_RUN:-}" && -n "$RUN_LABEL" ]]; then
  SPEEDWARS_RUN="$RUN_LABEL"
fi
# SPEEDWARS_RUN default is handled by _run_label() per spec 08 amendment
```

This honors spec 04's doctrine: an explicit env var (`BUSDIR=/custom ./swarm-run.sh --run foo`) beats the derivation.

### Collision Detection & Heartbeat

At `bus_init` (after BUSDIR is resolved):

```bash
# Refuse on ANY live heartbeat (spec 11 file at bus root) — two live pools on one busdir is never safe
if [[ -f "$BUSDIR/heartbeat" ]] && _is_heartbeat_live "$BUSDIR/heartbeat"; then
  echo "swarm-run: bus $BUSDIR has a LIVE run (heartbeat age <60s) — refusing; use a different --run label" >&2
  exit 1
fi

Resume semantics: no heartbeat, or a stale one (age > 60s), proceeds — a same-label re-invocation of a finished/dead run resumes the bus; spec 20 never writes the heartbeat itself (spec 11 owns it).

### Heartbeat Maintenance

None added by this spec (FR-4): the file is written exclusively by spec 11's machinery —
`swarm-ctl heartbeat`, the orchestrator session, and swarm-loop's per-iteration refresh loop.
Spec 20 only reads it (`_heartbeat_live`, src/swarm-lib.sh).

## Boundaries

- **Always**: Check for a live heartbeat before proceeding on a busdir collision — refuse whenever one is live, regardless of label. Pass `--run` through in `swarm-loop.sh` iteration. Preserve env-var precedence per spec 04.
- **Ask first** (get maintainer sign-off before): Changing heartbeat TTL or collision semantics (e.g., "allow concurrent runs"). Adding a centralized bus registry (this spec intentionally avoids it).
- **Never**: Silently override an explicit env var with a `--run` derivation. Skip heartbeat checks (assume concurrent runs won't collide). Delete stale buses automatically (leave reclaim to the operator).

## Acceptance Criteria

- [x] Two swarms with distinct `--run` labels derive distinct `.bus-<label>` busdirs and distinct run labels (bats: derivation + `.run-label` pinning; concurrent live smoke deferred to first operational namespaced run).
- [x] A LIVE heartbeat on the target bus refuses the run with a clear error (bats, `touch heartbeat` fixture — refusal is label-independent per amended FR-3).
- [x] A stale heartbeat (>60s) proceeds silently on the same bus (resume; bats).
- [x] `swarm-loop --run alpha ...` derives `.bus-alpha` and passes `--run alpha` + `UNIMATRIX_BUS_OWNER=1` to each iteration's `swarm-run.sh` (bats: init derivation; pass-through is in the iteration invocation line).
- [x] An existing script that sets `BUSDIR=... ./swarm-run.sh` (no `--run`) works unchanged; env beats the derivation (bats).
- [x] Usage text documents the `--run` flag (bats).
- [x] `swarm-run.sh --run foo <mode>` resolves the derived bus for every mode incl. `call` (FR-6: the derivation matches `call`'s cwd default).
- [ ] Ground Control fleet view — STAGED with FR-7 (cockpit wave, not yet shipped).
- [x] Bats: flag parsing, invalid-label refusal, collision detection, owner bypass, loop integration.

## Dependencies

- Specs [01-swarm-core](./01-swarm-core.md) (bus lifecycle, heartbeat reap age), [04-settings](./04-settings.md) (precedence doctrine), [08-speedwars](./08-speedwars.md) (run-label amendment, `_run_label` function), [02-cockpit](./02-cockpit.md) (monitor board), [05-ground-control](./05-ground-control.md) (fleet registration).
- Bash ≥5.1 (already required by spec 01).
- No new external dependencies.

## Implementation Notes

### Code Anchors

- **Flag parsing:** `swarm-run.sh` top-level arg loop (before `full_run` / `verify_run` call).
- **Derivation:** `bus_init()` in `src/swarm-lib.sh` (called from `full_run`, `verify_run`, `cmd_call`), immediately before `bus_mkdir`.
- **Collision detection:** new helper `_heartbeat_live()` (src/swarm-lib.sh) + `_collision_gate()` guard at the new-work entries (`full_run`, `cmd_call` post-resolution) per amended FR-3.
- **Heartbeat write:** none — FR-4; the stale "write in bus_init / refresh in _spawn_worker" note from the draft was wrong and is removed.
- **Loop integration:** `swarm-loop.sh` → `swarm-run.sh` invocation passes `${RUN_LABEL:+--run "$RUN_LABEL"}`.
- **Cockpit registration:** `swarm-mon.sh` / Ground Control gc.js reads `_run_label($BUSDIR)` per live bus.
- **Ledger:** no changes to `speed_row` / `run_summary` / `_run_label` — they already work.

### Migration Path

1. **Immediate:** Ship `--run` flag parsing and derivation in `swarm-run.sh`, no cockpit changes yet. Runs without `--run` behave identically to today (FR-2, FR-8).
2. **Wave 2:** Add heartbeat liveness check (FR-3, FR-4) — ANY live heartbeat refuses, same label included (amended FR-3 is authoritative; the guard resumes only when the heartbeat is stale or absent).
3. **Wave 3:** Wire cockpit registration (FR-7) — Ground Control lists buses by label.
4. **Testing:** bats coverage (FR-10) at each wave; smoke-test concurrent runs before shipping Wave 2.

---

## Amendment — 2026-07-29 (caller-cwd derivation + empty-run abort)

1. **FR-1 derivation moved from checkout to caller's cwd.** The checkout-rooted derivation (`$SCRIPT_DIR/.bus-<label>`) silently swept an empty bus when `swarm-run.sh` was launched from a target repo (gtm-owners3; feedback 2026-07-28-gtm-studio-run-flag-busdir-cwd.md). The new derivation (`$PWD/.bus-<label>`) matches `call`'s existing cwd default, collects output in the caller's working directory where the orchestrator sits, and closes the misdirection trap. `UNIMATRIX_BUS_ROOT` stays the test seam; explicit `BUSDIR` env still overrides the derivation per spec 04 precedence.

2. **Empty-run abort after enqueue.** A run that finalizes enqueue with zero queued, claimed, and done cards aborts nonzero naming the resolved `BUSDIR` — a clean close over an empty sweep is a mis-derivation trap, never intent. Applies to `full_run` and `verify_run` (batch operations where the intent is always nonzero work; `cmd_call` single-card dispatch stays silent on empty).

---

## Backlog References

- **Backlog 11:** "Two concurrent swarm runs collide on shared bus — ledger rows fold, queue markers bleed."
- **Backlog 21:** "Operator can hand-craft BUSDIR and SPEEDWARS_RUN but they can drift (one set, one forgotten)."

Both resolved by atomic `--run` flag derivation + heartbeat liveness gate.

**Amendment pointer 2026-07-31 → [spec 21](./21-speed-observability.md):** explicit `--busdir <path>` flag + git-toplevel ancestor-bus hint on the empty-run abort.
