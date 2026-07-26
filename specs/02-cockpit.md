# Cockpit — Swarm Monitor

**Status:** Active
**Date:** 2026-07-08
**Related specs:** [01-swarm-core](./01-swarm-core.md)

---

## Overview

A separate, read-only monitoring window for `/swarm` runs: a `tmux -L swarm` session
(`swarm-mon.sh`) showing live board/firehose/cost panes plus an interactive control pane, and an
optional read-only WezTerm attach from Windows. The monitor **reads the bus, never the pane** —
results always come from each CLI's handoff file (`01-swarm-core.md`), so the monitor is
disposable: it can be killed, detached, or reattached at any point without touching the run
(`monitoring-runbook.md` §0).

## Goals

1. Give a human live visibility into queue/claimed/done state, per-worker events, and cost —
   without ever being on the run's critical path.
2. Survive CLI version drift and malformed stream output without crashing a pane.
3. Provide a control surface (`swarm-ctl`) for pause/resume/cancel/kill/add/abort that is
   separate from the read-only view.

## Non-Goals

- Not a second driver — control happens via the bus (Level 2/3, `monitoring-runbook.md` §8), and
  the Fable session remains Level 1 control. The monitor pane itself never sends input to a
  worker.
- No dynamic per-worker pane splitting by default — fixed 3 panes regardless of fan-out width
  (avoids the classic tmux pane-renumbering race). A per-worker split is available manually.
- No browser/SSE dashboard (rejected candidate `a9` — pays for UI nobody asked for over the
  preferred tmux/WezTerm/starship stack).

---

## Requirements

### Functional

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-1 | `swarm-mon.sh` builds a `tmux -L swarm` session (`mon`) on first dispatch; idempotent — bails if the session already exists on that socket. | Must |
| FR-2 | **Board pane:** `QUEUED/CLAIMED/DONE/CANCELLED` counts every 2s, a stale-lease alarm (`find claimed -mmin +$LEASE_MIN`), any active `.bus/limits/*.limited` flags, and a PARKED BRANCHES section (pinned branches that hit their lane limit). *(Amended 2026-07-08: cancelled/ + parked markers postdate the original wording. Amended 2026-07-19: the stale-lease reaper `reap()` in `src/swarm-lib.sh` skips any id with `limits/<id>.frozen` — a `pause-worker`-frozen worker's heartbeat is stopped too, so its lease must not expire into a requeue (double-claim); `kill`/`nudge`/`cancel` send SIGCONT before TERM on a frozen worker, and always clear `limits/<id>.frozen` in those paths.)* | Must |
| FR-3 | **Firehose pane:** `tail -n +1 -F .bus/run-*.jsonl \| jq -Rrc --unbuffered '…'` — unbuffered is mandatory or the cockpit lags ~8KB; `-R` (raw input) is mandatory because the filter starts with `fromjson?`, which needs string input — without `-R` every line is silently dropped. Any extra pipeline stage (e.g. `cut`) gets `stdbuf -oL`. *(Amended 2026-07-08 per step-3 build findings.)* | Must |
| FR-4 | **Cost pane:** `watch -n10 ccusage` — reads canonical session logs, never sums per-`stream_event` usage (inflated 3-8×, claude-code #6805). | Must |
| FR-5 | **Interactive control pane** (4th pane, plain bash, starship-visible): runs `swarm-ctl`. | Should |
| FR-6 | WezTerm read-only attach (WSL-only convenience): `wezterm.exe cli spawn --new-window -- wsl.exe -- tmux -L swarm attach -r -t mon`, called by full `/mnt/c/Program Files/WezTerm/wezterm.exe` path (not on WSL PATH). Non-fatal if blocked (e.g. sandboxed Bash denies the `/mnt/c` binary, or you're not on WSL) — `tmux -L swarm` alone satisfies the monitoring requirement. | Must |
| FR-7 | `swarm-ctl` verbs: `pause` (`touch .bus/PAUSE`), `resume` (`rm .bus/PAUSE`), `status` (read-only; report gate counts and active limit flags), `cancel <id>` (move the spec **and its `.lane`/`.write` sidecars** from `specs/`\|`queue/` to `cancelled/`), `kill <id> [--cancel]` (read the worker pid from `.bus/pids/<id>` — written by `_spawn_worker` — and kill its **whole subtree** via `kill_subtree`, then requeue by default or `--cancel` into `cancelled/`, clearing sidecars), `nudge <id> [hint]` (kill the worker subtree via `kill_subtree` if `pids/<id>` is present, then requeue the spec — found at `claimed/<id>.*` else `queue/<id>.prompt` — appending a `## OPERATOR HINT (nudge <UTC-ts>)` block when a hint is given; resets `limits/<id>.parked`/`.chain-<id>`/`.retries-<id>`/`<id>.timedout` for a fresh run from the top; keeps the `.lane`/`.write` sidecars; a done or unknown id fails rc1), `pause-worker <id>` (SIGSTOP the worker subtree — snapshot only, no TERM→KILL escalation — then `touch limits/<id>.frozen` and refresh the claim lease), `resume-worker <id>` (SIGCONT the subtree, `rm -f limits/<id>.frozen`, refresh the lease), `add <promptfile> [--lane lane:model] [--write <dir>]` (drop a new prompt into `queue/`, writing sidecar `<id>.lane` and `<id>.write` alongside via the specs/→queue/ two-step when those options are given), `abort` (liveness-check then `kill -- "-$(cat run.pgid)"`). *(Amended 2026-07-12: the shipped design uses `.bus/pids/<id>` + subtree kill, not `claimed/<id>.pid`; sidecar cleanup + abort liveness-guard postdate the original wording. Amended 2026-07-19: `nudge`, `pause-worker`, `resume-worker`, `status` added; `add` extended with lane/write sidecars — exact semantics in §4.6/§4.6b/§4.5 of plans/002-cockpit-redesign/PLAN.md.)* | Must |
| FR-8 | The firehose jq filter tolerates unknown `type` values and non-JSON lines (`fromjson? // empty`) so a CLI upgrade that drifts the stream-json schema doesn't kill the pane. | Must |

---

## Design

```
┌───────────────────────────┬──────────────────┐
│ 0 BOARD  queued/claimed/  │ 2 COST           │
│   done + stale leases +   │   watch ccusage  │
│   active .limited flags   │                  │
├───────────────────────────┴──────────────────┤
│ 1 EVENT FIREHOSE — tail -F run-*.jsonl | jq   │
├────────────────────────────────────────────────┤
│ 3 CONTROL (interactive, writable) — swarm-ctl │
└────────────────────────────────────────────────┘
```

Socket isolation (`-L swarm`) keeps this off your everyday tmux server entirely. `tail -F`
(capital F) re-follows files that appear after the pane starts, so late-spawned workers show up
automatically without a pane restart.

---

## Boundaries

- **Always**: bootstrap idempotently (no duplicate session); `2>/dev/null` on gemini before any
  jq pipe (stderr banner is not JSON and corrupts the stream); keep the WezTerm attach `-r`
  (read-only) by default.
- **Ask first**: opening a writable (`attach -t mon`, no `-r`) WezTerm window — deliberate only,
  so watching stays fat-finger-proof.
- **Never**: have the monitor write to `.bus` outside the dedicated control pane/`swarm-ctl`; let
  the monitor become a dependency the run blocks on (it must degrade to "no monitor, run still
  completes" if `swarm-mon.sh` can't launch).

---

## Acceptance Criteria

- [ ] **Malformed-stream survival:** feed the firehose a fixture `run-*.jsonl` containing unknown
      `type` values and non-JSON lines interleaved with valid events — the pane keeps running and
      silently drops the bad lines (no crash, no pane exit).
- [ ] **Detach-safety:** `Ctrl-b d` (or closing the WezTerm window) leaves the `mon` tmux session
      alive; the run and its monitor keep going untouched.
- [ ] **Idempotent bootstrap:** running `swarm-mon.sh` twice results in exactly one `mon` session
      (second call is a no-op).
- [ ] **Ctl verbs test:** each `swarm-ctl` verb produces the correct bus mutation — `pause`
      creates `.bus/PAUSE` and blocks the next claim; `resume` removes it and claiming continues;
      `cancel <id>` moves the spec to `cancelled/` and the gate's live count drops accordingly
      (`01-swarm-core.md` gate math); `kill <id>` signals the recorded pid's whole subtree
      (`.bus/pids/<id>`); `add <file>` is picked up by the claim loop; `abort` terminates the full
      process group via `run.pgid` (after a liveness check).
- [ ] **WezTerm non-fatal:** with the `/mnt/c` binary unreachable (simulated), the monitor still
      builds and is reachable via plain `tmux -L swarm attach -r -t mon` from any WSL shell.

**Verification commands:**
```bash
bats tests/cockpit.bats
./swarm-mon.sh && tmux -L swarm attach -r -t mon
```

---

## Open Questions

None.

---

## Dependencies

**Internal:** `plans/001-multimodel-orchestration/monitoring-runbook.md` (full spec — this file
condenses §1-8), `01-swarm-core.md` (bus layout, gate math, `run.pgid`).
**External:** tmux 3.4, `jq` 1.7 (`-u` flag), `ccusage`, starship 1.26 (cosmetic only), WezTerm
20260705+ at `/mnt/c/Program Files/WezTerm/wezterm.exe` (optional, WSL-only).
