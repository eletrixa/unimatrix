# Spec 16 — Unified CLI: `./unimatrix` Router + `u-` Slash-Command Namespace

**Status:** Active (approved 2026-07-25, plan sign-off)
**Date:** 2026-07-25
**Related specs:** [01-swarm-core](./01-swarm-core.md), [02-cockpit](./02-cockpit.md),
[03-swarm-loop](./03-swarm-loop.md), [15-direct-call](./15-direct-call.md) (the `call` verb this router fronts)

---

## Overview

Today the project is invoked as four separate entry points (`swarm-run.sh`, `swarm-loop.sh`,
`swarm-mon.sh`, `src/swarm-ctl`) plus four slash commands whose real content lives inline in
`.claude/commands/*.md`. Spec 16 adds one thin router, `./unimatrix`, that dispatches a verb to
the right script with argv and env untouched, and moves the slash-command bodies into a `u-`
prefixed namespace so a colon-free plugin-style front door exists without a plugin. No script
gains logic — this spec is pure routing and pure file movement. *(Scoped to spec 16 itself: spec
17 and plan-004 P2, 2026-07-25/26, later gave the router a handful of verbs with real logic of
their own — `install`, `here`, `report --html` — so the router does not stay pure-dispatch
forever, only for the duration of this spec.)*

## Goals

- One command to remember: `unimatrix <verb> ...` instead of four scripts + `src/swarm-ctl`.
- Zero behavior change: every existing script stays directly invocable, unmodified, forever.
- A slash-command namespace (`/u-swarm`, `/u-loop`, `/u-speedwars`, `/u-setup`, `/u-call`) that
  reads as a family without needing plugin packaging.

## Non-Goals

- No rewrite of `swarm-run.sh`, `swarm-loop.sh`, `swarm-mon.sh`, or `src/swarm-ctl` — the router
  execs them as-is.
- No global `u` binary or shell alias installed by this repo — document `alias u=unimatrix` as an
  operator opt-in, not something this spec ships.
- No true `/u:call` colon-namespaced plugin command and no cross-repo command availability — both
  require plugin packaging, deferred to a future spec.

## FR-1 — Verb map

`./unimatrix <verb> [args...]` dispatches on `<verb>`:

| Verb(s) | Target |
|---|---|
| `call`, `run`, `verify`, `doctor`, `config` | `swarm-run.sh <verb> <args...>` |
| `plan "<q>"` | `swarm-run.sh --plan-only "<q>"` |
| `loop <init\|iterate\|run> <id> ...` | `swarm-loop.sh <args...>` |
| `mon ...` | `swarm-mon.sh <args...>` |
| `pause`, `resume`, `cancel`, `add`, `abort`, `status`, `kill`, `nudge`, `pause-worker`, `resume-worker`, `unpark`, `heartbeat`, `watchdog-arm`, `watchdog-check`, `watchdog-disarm`, `postmortem`, `review-stub` | `src/swarm-ctl <verb> <args...>` |
| `report [--html]` | router-local `cmd_report` *(amended plan-004 P2: not `src/swarm-ctl` — the router execs `src/speedwars-report.sh` directly, or renders a self-contained static page for `--html`)* |

The ctl verb list is flattened into the top-level namespace (no `unimatrix ctl <verb>` indirection)
— none collide with a `run`/`loop`/`mon` verb name, so the flat map is unambiguous by construction.
`unimatrix run` with no further args passes an empty string positional through to `swarm-run.sh`,
matching `full_run`'s documented no-arg entry (the positional is ignored by the dispatch case
either way). A bare `unimatrix` with no verb at all is a usage error per FR-4 — draining the bus
requires the explicit `run` verb, never an accident.

## FR-2 — Exec semantics

The router `exec`s the resolved target — no fork-and-wait, no argv rewriting beyond consuming the
leading verb token, no env mutation. `BUSDIR`, `CONF`, `LOOP_*`, `WORKER_TIMEOUT_SEC`,
`SPEEDWARS_RUN`, `LEDGER_FILE`, and every other env var the four scripts already read keep working
exactly as if that script had been invoked directly — the router is invisible to them. Exit code is
the target's exit code (guaranteed by `exec`, not manual `$?` plumbing).

## FR-3 — Any-cwd resolution, scripts stay directly invocable

`./unimatrix` resolves its own script directory (`dirname`/`readlink` on `$0`, the same pattern the
four scripts already use for `SCRIPT_DIR`) before dispatch, so `/path/to/unimatrix call ...` works
from any cwd, not just the repo root. Pure routing cuts both ways: `swarm-run.sh`, `swarm-loop.sh`,
`swarm-mon.sh`, and `src/swarm-ctl` stay fully functional as direct invocations with no dependency
on the router ever having run — no shared state file, no env var the router sets that a script
needs.

## FR-4 — Help, usage, exit codes

- `unimatrix help` / `-h` / `--help` (with or without a following verb) → usage to stdout, rc 0.
- No arguments at all → usage to stderr, rc 2.
- Unknown verb → an error line naming the bad verb plus usage, both to stderr, rc 2.

## FR-5 — `u-` slash-command namespace

Subdirectories don't rename a slash command (`.claude/commands/foo/bar.md` is still `/bar`, not
`/foo:bar`), and the colon prefix (`/plugin:cmd`) is reserved for actual plugin packaging — so the
namespace is a flat filename prefix instead:

- `.claude/commands/u-swarm.md`, `u-loop.md`, `u-speedwars.md`, `u-setup.md` receive the full
  canonical body currently in `swarm.md`, `swarm-loop.md`, `speedwars.md`, `setup.md` (frontmatter
  + content, verbatim move).
- The four originals shrink to alias stubs (5-line files: frontmatter + one sentence): `alias of
  /u-X — read and follow .claude/commands/u-X.md`. Old names stay live (nothing that types
  `/swarm` breaks) while the canonical content has exactly one home.
- `u-call.md` is new — the slash-command front door for the `call` verb (spec 15); no old name to
  alias since it never existed as a bare command before.

## Acceptance criteria

1. `tests/unimatrix.bats` verifies the routing table (FR-1) via a copied-router-plus-stub-targets
   harness: copy `unimatrix` into a scratch dir alongside four executable stub scripts named
   `swarm-run.sh`, `swarm-loop.sh`, `swarm-mon.sh`, and `src/swarm-ctl` that each echo their own
   name + received argv, then assert each verb reaches the right stub with argv intact.
2. Unknown verb → rc 2, stderr non-empty (bad-verb line + usage).
3. Absolute-path invocation from a foreign cwd (`cd /tmp && /path/to/unimatrix doctor`) resolves
   and dispatches correctly.
4. `help`/`-h`/`--help` → rc 0, usage on stdout; no-args → rc 2, usage on stderr.
5. `/swarm`, `/swarm-loop`, `/speedwars`, `/setup` still work as one-line pointers; `/u-swarm`,
   `/u-loop`, `/u-speedwars`, `/u-setup`, `/u-call` carry the real content.
6. `check.sh` green (shellcheck, full bats, PII gate).

## Open questions

None outstanding.
