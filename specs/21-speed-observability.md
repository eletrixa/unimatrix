# Spec 21 — Speed + Timeline Observability

**Status:** Active (activated 2026-07-31 — Robert, plan approval "jiggly-scribbling-allen":
triage decisions backlog 76-82 apply-now + red-green-double-refactor build directive; the
claim-stamp FR explicitly consumes spec 08's "ask first — capture beyond finalize" sign-off)
**Date:** 2026-07-31
**Related specs:** [01-swarm-core](./01-swarm-core.md) (job pool, claim loop),
[08-speedwars](./08-speedwars.md) (ledger rows, FR-10 claim stamping),
[13-lane-health](./13-lane-health.md) (probes, `.broken` marker),
[14-write-cage-attribution](./14-write-cage-attribution.md) (cage denial evidence),
[20-bus-namespacing](./20-bus-namespacing.md) (`--run` derivation)

---

## Overview

bh065 forensics (2026-07-30, brain): a 41-minute logical run spent only ~16 minutes (39%)
in worker serve time — 24.5 minutes (60%) was an idle bus waiting for engine relaunches,
16.2 minutes of it one late-added card sitting unclaimed after the pool closed. pure064
(2026-07-29): a demonstrably healthy claude lane was benched 30 minutes by a 10-second
probe timeout in a cold `env -i` cage, with the probe's actual failure text discarded.
Nothing in the toolchain renders where a run's wall-clock went — the forensics above took
hand-reconstruction from file mtimes.

Spec 21 closes the three biggest wall-clock sinks (pool linger, probe/bench fidelity,
claim-time cage preflight), adds the launch-ergonomics fixes the same runs paid for
(`--busdir`, env-master candidates), and makes run time visible (claim stamps →
queue-wait in the ledger, `swarm-ctl timeline`, top wall sinks in run-summary) plus
parallelism knobs (per-lane caps, longest-first claiming, FANOUT 6).

Backlog: 76 (probe/bench), 77 (`--busdir`), 78 (env-master), 79 (linger), 80 (cage
preflight), 81 (timeline/claim stamp), 82 (parallelism knobs).

## Goals

1. **Kill idle-bus time:** a drained pool can wait a configurable window for late adds
   instead of forcing a full engine relaunch per wave.
2. **Bench lanes honestly:** a lane marker must carry the real failure text, use a TTL
   proportional to the evidence, and require more than one card's burst to earn a
   30-minute bench.
3. **Fail before spending:** a card whose write list cannot fit its cage parks at claim
   time, not after minutes of worker spend.
4. **Launch ergonomics:** explicit `--busdir`, ancestor-bus hint on empty-run abort,
   house-standard env-master fallback with actionable abort text.
5. **See the run:** per-card queued→claimed→spawned→finalized timing from bus artifacts,
   queue-wait in the ledger, top wall sinks at run close — "know what to improve next
   time" without hand-forensics.
6. **Max parallelism:** per-lane in-flight caps, longest-job-first claiming, FANOUT
   default matching current guidance.

## Non-Goals

- No standing daemon, no `add --serve` detached workers (rejected: duplicates private
  claim/spawn/finalize machinery; escapes `run.pgid`/abort/sweep coverage).
- No cross-busdir probe cache (within-bus caching already exists via persistent
  `limits/.probed-<lane>`).
- No `.prio` sidecar (prompt byte size is the job-length proxy; revisit only if evidence
  demands an explicit hint).
- No web-cockpit timeline view (terminal `swarm-ctl timeline` only; Ground Control keeps
  its live-ages surface).
- No change to the fleetops ledger contract version — all new row keys are additive via
  the spec 18 payload escape valve.

## Requirements

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-1 | **`POOL_LINGER_SEC`** (conf key, default 0): when the pool's close condition (`done_n + parked_n >= live_n && running == 0`) first holds, record the drain time; keep polling `queue/` (existing 1s tick) and only break once the condition has held continuously for `POOL_LINGER_SEC` seconds. Any new work (condition false again — e.g. a mid-run `swarm-ctl add` raised `live_n`) resets the drain timer. Default 0 preserves today's immediate close exactly. Close-out (`_close_out_evidence`, `_check_parked`, `run.pgid` cleanup) is untouched. | Must |
| FR-2 | **`PROBE_TIMEOUT_SEC`** (conf key): replaces the hardcoded per-arm probe timeouts in `_doctor_probe_lane`. Baked default 10; lanes `claude` and `codex` default to 30 (cold-start profile: the probe spawns the real CLI in a cold `env -i` scratch-home). An explicit conf/env value applies to all lanes. Timeout messages quote the resolved cap. | Must |
| FR-3 | **Probe FAIL fidelity:** an auto-probe FAIL writes the `.broken` marker with TTL **600s** (one probe is one data point, not a lane verdict) and a reason line carrying the probe's actual failure text (`$out`, e.g. `FAIL timeout (30s)`) plus a `diag=limits/<lane>.probe-stderr` PATH; the ≤200-byte stderr tail itself is persisted to that bus-local diag file — for EVERY probe transport, curl lanes included (codex round 2026-08-01). A PASS, or a FAIL with no stderr, removes any prior diag file (staleness guard). *(Amended at GREEN 2026-07-31: spec 14 FR-7 marker lines are scrub-by-construction — paths/ids/tokens only, never stderr content, because markers are quoted into tracked feedback stubs. The original draft's "stderr tail in the reason line" violated that; pointer-to-diag-file preserves the operator evidence without the leak.)* | Must |
| FR-4 | **Finalize `.broken` fidelity:** the finalize-path lane-down bench points at the card's stderr file by PATH (`stderr=run-<id>.jsonl.stderr`) in the marker reason line when the file is non-empty — the drill-down evidence already lives on the bus; its content never enters a marker (same scrub amendment as FR-3). | Must |
| FR-5 | **`BROKEN_MIN_CARDS`** (conf key, default 2): the finalize lane-down arm appends the card id to `limits/.failcards-<bare>` (one `echo >>` per failure); the 1800s bench fires only when ≥ `BROKEN_MIN_CARDS` distinct card ids have fast-failed on that lane this run — below threshold it writes the 600s short-TTL form. The counter resets on the lane's next successful finalize (recovery clears evidence, like `.broken`) AND decays when no `.broken` marker is currently active at append time (codex round 2026-08-01: two isolated transients hours apart must not pair into a 1800s bench). The existing live-sibling downgrade stays. | Must |
| FR-6 | **`--busdir <path>` flag** on `swarm-run.sh`: sets `BUSDIR` explicitly (absolutized via `_abspath`), participating in spec 04 precedence as an explicit assignment (beats `--run` derivation; explicit `BUSDIR` env and `--busdir` are equivalent — last writer in the option loop wins over env). Documented in usage text. | Must |
| FR-7 | **Ancestor-bus hint:** when `_refuse_empty_run` aborts and `--run <label>` was given, probe `git rev-parse --show-toplevel`; if `<toplevel>/.bus-<label>` exists and differs from the resolved `BUSDIR`, name it in the hint ("found existing … — launch from there or pass --busdir"). Suggest only — the abort still exits nonzero, never auto-prefers. | Must |
| FR-8 | **Env-master candidates:** one helper `_env_master_path` used by BOTH `_env_master_key` and `env_master_preflight` (the twin defaults may never disagree): explicit `$ENV_MASTER_FILE` if set (authoritative even if unreadable — loud abort, no silent fallback); else first readable of `$XDG_CONFIG_HOME/unimatrix/env.master`, `$HOME/s/.env.master`. The preflight abort names the env keys the tripping lane(s) need and prints a copy-paste `export ENV_MASTER_FILE=…` line for any readable candidate found elsewhere. | Must |
| FR-9 | **Cage preflight at claim:** for a write card, before spawn, resolve the card's declared write paths (`queue/<id>.files` manifest entries) against the `.write` target — if ZERO entries land in-cage (path-prefix test after `_abspath`), the card is doomed: park instantly with `class=cage-denied` and a reason line naming an offending path. No worker spawn, no lane retry burn. *(Amended 2026-08-01: park-on-first-escape broke spec 14 FR-2's trust boundary — escaping entries are IGNORED loudly at the finalize gate, never a denial, so a MIXED manifest proceeds and only the all-escaping manifest parks.)* Cards without a `.files` manifest are unaffected (the manifest is the only pre-spawn write-path source of truth). | Must |
| FR-10 | **Claim stamp** (spec 08 FR-10 promotion; "ask first" sign-off recorded in Status): `_try_claim_one` writes `limits/<id>.claimed-at` via `_marker_line` immediately after a successful `claim()`. `speed_row` READS it and emits additive keys `claim_ts` (ISO) and `queue_wait_secs` (claim time − claimed-file birth `%W`; omitted when birth is unavailable). *(Amended at review 2026-07-31: consume-on-FIRST-read dropped — a pinned terminal failure writes TWO rows for one claim, attempt then parked, and first-read consumption left the terminal row (the one `timeline` keeps) stamp-less. Deletion lives inside `speed_row` itself, fired only when the row's outcome is terminal (`done`/`timeout-salvaged`/`parked`) — it cannot live in `_archive_and_release`, which runs BEFORE the done row's `speed_row` reads the stamp. Non-terminal attempt rows read without deleting; a re-claim overwrites with `>`; `swarm-ctl` cancel/nudge/kill clear the stamp with the rest of per-card state so a re-added id can never read an ended claim's stamp.)* The stamp (like every FR-10/12 surface) is part of the `SPEEDWARS_AUTO` evidence plane — `SPEEDWARS_AUTO=0` disables writer and reader together (adjudicated vs codex finding 10: an unconditional write would be evidence nobody consumes). One stamp per claim; a re-queued card gets a fresh stamp on its next claim. | Must |
| FR-11 | **`swarm-ctl timeline <run\|busdir>`:** read-only per-card timeline from existing artifacts — per-attempt spawn derived as ledger `ts − wall_secs` *(amended at GREEN 2026-07-31: the ledger already encodes spawn; deriving from it, not run-log births, makes timeline work on archived/ledger-only buses)*, finalize (ledger row `ts`), serve duration (`wall_secs`), retries (rows per id, with each earlier attempt rendered as its own indented line — lane, outcome, wall, finalize ts), lane walks (`requested`→`served_lane` + `fallback_reason`), park reason+time (FR-7 marker ISO lines), queue-wait (FR-10 keys when present), plus a run footer over merged serve intervals: total span (first spawn → last finalize), summed serve time, idle gaps >60s between activity clusters (invocation boundaries), and the critical-path card — serve sums and critical path computed over ALL attempt rows, not final rows only (codex round 2026-08-01). Degrades gracefully on buses predating this spec (missing stamps → fields shown as `-`). | Must |
| FR-12 | **`top_wall` in run-summary:** `run_summary` adds an additive `top_wall` key — top 3 cards by `wall_secs` (id, lane, wall_secs, outcome) — surfaced by `cmd_postmortem` with no reader change. | Must |
| FR-13 | **`LANE_MAX_<LANE>`** conf keys (CLAUDE/CODEX/GEMINI/GLM/KIMI/GROK; empty = unlimited): `_try_claim_one` counts the lane's in-flight claims (`claimed/<id>.<lane>:*` filenames) and skips cards resolving to a lane at its cap (same skip semantics as `lane_blocked` — the pool moves on to other cards/lanes; a capped lane never wedges the pool). | Must |
| FR-14 | **Longest-job-first claiming:** `_try_claim_one` iterates `queue/*.prompt` in descending byte-size order (prompt size as job-length proxy) instead of lexicographic glob order. Deterministic tie-break (name). | Should |
| FR-15 | **FANOUT baked default 4 → 6** (`swarm.conf.example` updated to match; buses are namespaced since spec 20, and operating guidance already says ≥6). | Should |

## Design

### FR-1 linger (swarm-run.sh `_run_pool`)

```bash
# inside the pool loop, replacing the unconditional break:
if (( done_n + parked_n >= live_n )) && (( running == 0 )); then
  drained_at="${drained_at:-$SECONDS}"
  if (( SECONDS - drained_at >= ${POOL_LINGER_SEC:-0} )); then break; fi
else
  drained_at=""
fi
```

Mid-run adds already work while the pool lives: `_try_claim_one` re-globs
`queue/*.prompt` and `gate_count` recomputes `live_n` every tick — linger only delays
the moment the pool stops looking.

Known bound (adjudicated, codex finding 6 REJECTED): an add landing between the expiry
tick's final `gate_count` and the `break` (a sub-second window) misses the pool and falls
back to today's relaunch path — the failure mode IS the pre-linger default. A bus-local
close/add lock would trade that one-tick miss for lock machinery on every add and every
pool tick; not worth it.

### FR-2/3 probe cap + fidelity (`_doctor_probe_lane`, `_probe_lane_event`)

One resolved cap per probe: `PROBE_TIMEOUT_SEC` explicit value wins; otherwise 30 for
claude/codex, 10 for the rest (subsumes the previous hardcoded codex exception). CLI
probe arms redirect stderr to `$cage/probe.stderr` (instead of `/dev/null`); on FAIL the
event handler writes `broken_flag "$BUSDIR" "$bare" 600 lane-down "<trigger> probe: $out
[· stderr tail]"`.

### FR-5 distinct-card threshold (finalize lane-down arm)

`limits/.failcards-<bare>` accumulates ids; `sort -u | wc -l` decides 1800s vs 600s.
The file lives in `limits/` (never wiped by `bus_init`) — per-run scope matches the
per-run bus.

### FR-9 cage preflight (claim path)

The `.files` manifest (spec 14) is authoritative and known pre-spawn. For each manifest
path: absolutize against the `.write` target; require `$path == $cage` or
`$path == $cage/*`. Zero in-cage entries → `_park_card` with `class=cage-denied` naming
an offending path. (bh065 f1: 180s + $0.41 of doomed glm work becomes an instant park.)
A mixed manifest is NOT parked: spec 14 FR-2's finalize gate ignores the escaping
entries with a loud line and judges the in-cage ones — the preflight only catches the
card that cannot possibly pass that gate.

### FR-10/11 timing (claim stamp + timeline)

Claim stamp is the ONE new engine write; everything else in `timeline` reads artifacts
that already exist (run-log birth `%W` per attempt via `_rotate_run_log` rotation,
ledger row `ts`/`wall_secs`, FR-7 marker ISO lines, done/ mtimes). Queue-wait =
`claim_ts − birth(claimed file)` — birth survives both the claim `mv` and the
heartbeat's `touch -c` mtime clobber.

### FR-13 lane caps (`_try_claim_one`)

Claim filenames are `<id>.<lane>:<model>` — `count=$(find claimed/ -name "*.$bare:*" |
wc -l)`; at cap, `continue` to the next queued card. Registered in `CONF_KEYS` following
the `TIMEOUT_<LANE>` per-lane pattern.

## Boundaries

- **Always**: keep `POOL_LINGER_SEC` default 0 (loop mode inherits env — a nonzero
  default would slow every `swarm-loop` iteration). Keep probe-FAIL TTL ≤ finalize bench
  TTL. Keep all new ledger keys additive (spec 18 contract, no version bump). One
  `write(2)` per JSONL/marker record.
- **Ask first**: raising the 1800s bench TTL; adding any further engine-side capture
  beyond the claim stamp; a `.prio` sidecar; web-cockpit timeline surface.
- **Never**: auto-prefer an ancestor bus on `--run` mismatch (hint only). Silently fall
  back when an explicit `ENV_MASTER_FILE` is unreadable. Let a capped lane wedge the
  pool. Bench a lane on a single probe FAIL for 1800s.

## Acceptance Criteria

- [x] FR-1: drained pool with `POOL_LINGER_SEC=60` serves a card added post-drain
  without relaunch; `POOL_LINGER_SEC=0` (and unset) closes immediately (bats).
- [x] FR-2: probe timeout resolves 30s for claude/codex, 10s others, explicit override
  wins (bats on the resolver).
- [x] FR-3: probe FAIL marker carries 600 TTL + probe text (bats fixture).
- [x] FR-4: finalize bench marker carries stderr tail when present (bats).
- [x] FR-5: one fast-failed card → 600s marker; two distinct cards → 1800s (bats).
- [x] FR-6: `--busdir` overrides `--run` derivation; usage documents it (bats).
- [x] FR-7: empty-run abort names an existing toplevel `.bus-<label>` (bats, git fixture).
- [x] FR-8: candidate order honored; explicit unreadable `ENV_MASTER_FILE` still aborts;
  abort names keys + export line (bats).
- [x] FR-9: out-of-cage `.files` entry parks at claim with `class=cage-denied`, no spawn;
  in-cage manifest spawns normally (bats).
- [x] FR-10: `.claimed-at` written on claim; row carries `claim_ts` + `queue_wait_secs`;
  stamp consumed (bats).
- [x] FR-11: `timeline` renders a synthetic bus (durations, retries, parks, gaps) and
  degrades on a stamp-less bus (bats); read-only against
  the archived bh065 bus (brain repo) reproduces the 16.2-min invocation gap (live check).
- [x] FR-12: run-summary row carries `top_wall` top-3; postmortem prints it (bats).
- [x] FR-13: lane at cap is skipped, other lanes fill slots, pool never wedges (bats).
- [x] FR-14: larger prompt claimed first (bats).
- [x] FR-15: baked default 6 asserted (bats — update existing baked-default asserts).
- [x] Full `bats tests/` + `shellcheck -x` on all 8 scripts green.
- [x] Live smoke: linger + timeline + top_wall on a scratch namespaced bus;
  `doctor --live` green; Ground Control panels unbroken with additive keys.

## Dependencies

- Specs 01 (pool/claim), 08 (ledger + FR-10), 13 (probes/markers), 14 (`.files`
  manifest), 20 (`--run`). Bash ≥5.1, GNU stat `%W` (birth-time; degrade when 0/absent).
  No new external dependencies.

## Implementation Notes — Code Anchors

- Linger: `swarm-run.sh` `_run_pool` break condition (~:1288).
- Probe cap/fidelity: `swarm-run.sh` `_doctor_probe_lane` (~:1721-1837),
  `_probe_lane_event` (~:347-364); `broken_flag` (src/swarm-lib.sh ~:620).
- Finalize bench: `swarm-run.sh` ~:1160-1216.
- `--busdir`: option loop `swarm-run.sh` ~:115-127; hint: `_refuse_empty_run` ~:1423.
- Env-master: `src/swarm-lib.sh` `_env_master_key` ~:865 + `env_master_preflight` ~:932.
- Cage preflight: claim path in `_try_claim_one` (`swarm-run.sh` ~:366-566), reusing
  spec 14 manifest parsing + `_park_card`.
- Claim stamp: `_try_claim_one` post-`claim()` (~:565); consume in `speed_row`
  (src/swarm-lib.sh ~:2495-2502 `.fbreason` pattern).
- Timeline: new `cmd_timeline` in `src/swarm-ctl` beside `cmd_postmortem` (~:1165),
  registered in the verb case.
- `top_wall`: `run_summary` jq (src/swarm-lib.sh ~:2717-2724).
- Lane caps + ordering: `_try_claim_one` glob (~:370) + `CONF_KEYS`
  (src/swarm-lib.sh ~:132-137, defaults ~:200).
- FANOUT: src/swarm-lib.sh ~:158 + swarm.conf.example.
