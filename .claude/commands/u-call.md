---
description: Direct single-lane dispatch through the unimatrix harness
argument-hint: "<lane[:model]>" "<prompt>"|@<promptfile> [--write <dir>] [--files <list> --batch <N>] [--chain "..."] [--id <label>]
---

# /u-call

**Deprecated** (spec 17 FR-8): `/u-call` is deprecated in favor of `/u:call`; this body stays
canonical here and `/u:call` (the plugin command) points at it. `/u-call` is deleted next release.

Read `specs/15-direct-call.md` before your first use of this command — this file only states the
invocation contract, not the engine design.

## Invocation

```
unimatrix call <lane[:model]> "<prompt>"|@<promptfile> \
    [--write <dir>] [--files <listfile> --batch <N>] [--chain "<lane[:model]> ..."] [--id <label>]
```

(equivalently `./swarm-run.sh call ...` — the router just execs it, spec 16 FR-2). This is a real
dispatch arm: it stages cards, then runs the unmodified `full_run` — same harness, cockpit, gate
math and evidence as any other run. Leave `BUSDIR` at its default (`.bus-call-<label|$$>`) unless
the operator explicitly names one.

## What you must do

1. Run the command **in the foreground** and wait for it to exit — `call` is synchronous; there is
   no background mode to poll.
2. Read the answer(s) from `$BUSDIR/res-*.txt` (or `res-<id>-NNN.txt` for a bulk run) — **never**
   from terminal scrollback or `run-<id>.jsonl` prose.
3. Relay to the operator, verbatim: the close-out `<cid>: N/M files touched` lines plus the run
   total (FR-10), and the single aggregate ledger line (FR-11) — this is the loud spend record even
   when the gitignored global ledger is absent.

## On a parked exit

`_check_parked` prints one `swarm-run: <id> parked (lane exhausted) — never completed, run is
INCOMPLETE` line per parked card and the run exits nonzero. Quote those lines to the operator
verbatim, then offer the resume flow — never silently retry, and **never re-issue the call itself**
(`cmd_call` refuses a busdir with a non-empty `queue/`):

```
unimatrix unpark --all                    # or: unimatrix unpark <id>...
# verify/clear the expired limits/<lane>.limited marker if one caused the park
BUSDIR=<that call's bus> unimatrix run    # drains the still-queued card(s); not a fresh `call`
```

## Bulk mode (`--files` / `--batch`)

Before committing to a `--batch` size on a large file list, probe with a small card first — see
`docs/usage.md` §Direct call. Sizing blind on 400 files risks one bad prompt shape burning the
whole fan-out before anyone reads a single answer.
