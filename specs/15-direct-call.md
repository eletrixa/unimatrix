# Spec 15 — Direct Call: One-Shot Lane Invocation over the Existing Engine

**Status:** Active (approved 2026-07-25, plan sign-off — "one verb to point a named lane at a
prompt, or at 400 files, without hand-authoring bus cards")
**Date:** 2026-07-25
**Related specs:** 01 (bus lifecycle, `.lane`/`.write` sidecars, pool + gate), 04 (conf, chains,
`WORKER_TIMEOUT_SEC`), 10 (chain semantics, lane classes)

---

## Overview

Running one lane against one prompt today means hand-writing `.bus/specs/<id>.prompt`, guessing the
sidecar spelling, and remembering which model string a lane wants — or calling the CLI directly and
losing every piece of evidence the engine produces. The dispatch case makes it worse than it looks:
the catch-all arm ignores its positional argument, so `./swarm-run.sh "do X"` runs whatever is
already in the bus and silently drops the prompt.

Spec 15 adds one verb, `call`, that **stages cards and then runs the existing pipeline unmodified**.
It is a front door, not an engine. The bulk mode (`--files`/`--batch`) exists because the realistic
use is not one prompt — it is "apply this instruction to these 400 files with this lane", which is
N cards, not N shell loops.

## Goals

- One command from prompt to evidence: no bus hand-authoring, no new evidence surface.
- Bulk work shards into ordinary cards, so pool parallelism and failover apply to it unchanged.
- Every refusal is a parse-time usage error — a bad invocation stages nothing.

## Non-Goals

- No new scheduler, no new close-out, no new monitoring path — `call` calls `full_run` and stops.
- No auto-retry/auto-requeue of under-touched chunks (FR-10 reports; a human decides).
- No prompt templating language — the chunk block is appended text, nothing more.
- No new lane, no new dependency: coreutils `split`/`stat` only.

## FR-1 — `call` stages, then runs the unmodified `full_run`

```
./swarm-run.sh call <lane[:model]> '<prompt>'|@<promptfile> \
    [--write <dir>] [--files <listfile> --batch <N>] [--chain '<lane[:model]> ...'] [--id <label>]
```

`call` is a real dispatch arm (it consumes its own argv, unlike the catch-all). It validates
everything first, writes cards + sidecars into `$BUSDIR/specs/`, then invokes `full_run` with no
changes: `conf_load` + `bus_init` → `env_master_preflight` → `mon_web_ensure`/`mon_web_open` →
`_enqueue_pending_specs` → `_drive_pool` → `=== results ===` → `_close_out_evidence` →
`_check_parked`. Harness, cockpit, gate math and evidence are therefore identical to any other run,
and `call` inherits future engine changes for free. A prompt starting with `@` reads the rest as a
file path.

Busdir: `BUSDIR` from the environment wins, else `.bus-call-<label|$$>` **resolved against the
caller's cwd** (unlike the engine's `SCRIPT_DIR`-relative `.bus` default — a direct call may be
issued from any repo via the spec 16 router, and its bus belongs where the operator stands, not
silently inside the unimatrix checkout). `call` **refuses**
(nonzero rc, nothing staged) if that directory already exists with a non-empty `queue/` or `done/`
— overlaying a live or finished run's bus is never what the operator meant — and likewise if the
bus holds a **live pool** (`run.pgid` whose process group still answers `kill -0`), since a
mid-flight run can have an empty queue with every card claimed. `SPEEDWARS_RUN` is set to
`call-<label|$$>` so the run's rows join on one key.

## FR-2 — Lane and model resolution

`<lane[:model]>` takes an explicit `lane:model` verbatim. A **bare lane** resolves via the existing
`_verify_default_model` (`claude`→`opus`, `codex`→`default`, `gemini`→`gemini-3-flash`,
`glm`→`glm-5.2`, `kimi`→`kimi-k3`, `grok`→`default`, i.e. `-m` omitted) — one resolution table, not
a second copy. An unknown lane is a usage error: nonzero rc, usage on stderr, nothing staged. The
model half of every token (primary and `--chain` alike) must match `[A-Za-z0-9._-]+` — it is
embedded verbatim in the claim filename (`claimed/<id>.<lane>:<model>`), where a slash or
whitespace would corrupt bus state at claim time, long after parse.

## FR-3 — Pin by default, `--chain` swaps to fallback

Default is a **hard pin**: each card gets a `.lane` sidecar (spec 01 FR-2b), bypassing `EXEC_CHAIN`;
a pinned card whose lane is blocked waits up to `PIN_WAIT_SEC`, then parks loudly — never a silent
lane switch. `--chain '<lane[:model]> ...'` writes a `.chain` sidecar instead: the primary lane is
prepended and bare tokens normalized per FR-2, so `call glm --chain "codex kimi"` yields
`glm:glm-5.2 codex:default kimi:kimi-k3`. With `--chain`, **no `.lane` is written** — pin and chain
never coexist on one card.

## FR-4 — `--write <dir>` sidecar, gemini refused at parse

`--write <dir>` writes one absolute write-target directory per card as the `.write` sidecar (spec 01
FR-15 semantics unchanged — flags + CWD, never a loosened env cage). One target per call. `gemini`
with `--write` is **refused at parse time** (nonzero rc, nothing staged): gemini is not
write-capable, and staging would turn a typo into a fan-out that parks every card. The refusal
holds for the whole normalized `--chain`, not just the primary — a gemini fallback on a write card
would only fail at spawn time, after real work began.

## FR-5 — Bulk sharding and the chunk manifest

`--files <listfile> --batch <N>` shards M paths into `ceil(M/N)` cards `<id>-001 … <id>-NNN`. Each
card's prompt is the template verbatim followed by:

```
FILES (operate on exactly these, nothing else):
<its N-line chunk>
```

The same chunk is copied to `$BUSDIR/chunks/<cid>.files`. That manifest is **evidence, not a
sidecar** — no claim, spawn, finalize or gate path reads `chunks/`; only the FR-10 report does.
`--files` without `--batch` is a usage error, and so is `--batch` without `--files` — they are a
pair. On a write call the list is fenced to the `--write` root at parse time (lexical: an absolute
path must sit under the root, a relative one may not climb with `..`) — the list is an edit
instruction and write-capable lanes carry no filesystem fence of their own. A run-level stamp
`$BUSDIR/call.stamp` is touched immediately before enqueue, giving FR-10 one "everything after
this is ours" mark.

## FR-6 — Id hygiene and collision refusal

Card ids come from `--id <label>`, else `call-$$`. Every resulting id (including the `-NNN` bulk
suffix) must match `ID_RE` `^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`. If the id prefix already has a
footprint in the target busdir's `specs/`, `queue/`, `claimed/` or `done/`, `call` refuses (nonzero
rc, nothing staged) rather than colliding with an in-flight or completed card.

## FR-7 — Pre-existing pending specs: warn and proceed

If `$BUSDIR/specs/` already holds unenqueued cards, `call` prints a loud stderr warning naming the
count and proceeds — `_enqueue_pending_specs` sweeps them into this run. Surfacing it is the
requirement; refusing would break the legitimate "stage extra cards by hand, then call" flow.

## FR-8 — Oversized prompt warning

A per-card prompt over 100 KB gets a loud stderr warning (`MAX_ARG_STRLEN` is 128 KB per argv
element and every lane receives its prompt as a single argument). Warning only — the card still
stages; the ceiling is the kernel's, and the operator may know their chunk is fine.

## FR-9 — Write calls default `WORKER_TIMEOUT_SEC=1200`

When `--write` is present and neither env nor conf sets it, `WORKER_TIMEOUT_SEC` defaults to
**1200** (not 300); an explicit value always wins. Rationale: a write card does real edits and the
spec 01 FR-12 watchdog kills on wall clock — a 300 s kill mid-edit leaves a **silent partial
change** under the write target that a directory-level diff gate reads as "done".

## FR-10 — Close-out "N/M files touched" report

After `full_run` returns, for each card with a chunk manifest, `call` counts manifest paths whose
mtime is newer than `$BUSDIR/call.stamp` and prints one stderr line per card
(`<cid>: N/M files touched`) plus a run total, beside the existing close-out evidence. A relative
manifest path is resolved against the `--write` root — the same anchoring the chdir'd worker used —
an absolute path passes through. It is
**report-only**: never requeues, never re-spawns, never changes the exit code. Caveat, stated in the
output: an already-conformant file is legitimately untouched, so `N < M` is a prompt to look, not
proof of failure.

## FR-11 — Bus-local ledger, one aggregate row globally

`LEDGER_FILE` defaults to `$BUSDIR/llm-runs.md` (an explicit `LEDGER_FILE` in the environment wins),
keeping per-card `ledger_row` writes with the run's bus. At close, exactly **one aggregate row**
(verb, lane or chain, card count, file count, rc) is appended to the unimatrix checkout's
`docs/ops/llm-runs.md` **iff that file already exists** — the same never-scaffold posture as
`ledger_row` — and the identical aggregate line always prints to stderr regardless, so the spend is
loud even when the gitignored global ledger is absent. The global ledger gains one line per `call`
run, never 400. No silent spend either way: every card is still ledgered bus-locally.

## Acceptance criteria

1. `./swarm-run.sh call codex "reply PONG"` in a clean tree: one card walks `specs/ → queue/ →
   done/`, `res-<id>.txt` holds the answer, and the run leaves **one speedwars row**, a run-summary
   row, bus-local ledger rows and exactly one aggregate row in `docs/ops/llm-runs.md`; rc 0.
2. Each of: unknown lane, `gemini … --write`, `--files` without `--batch`, id collision, busdir with
   non-empty `queue/`/`done/` → nonzero rc, reason + usage on stderr, **zero** files staged.
3. `call glm --chain "codex kimi"` writes `.chain` = `glm:glm-5.2 codex:default kimi:kimi-k3` and no
   `.lane`; plain `call glm` writes `.lane` = `glm:glm-5.2` and no `.chain`.
4. A 7-path list with `--batch 3` produces cards `-001/-002/-003` (3/3/1), each prompt ending with
   the FILES block listing exactly its chunk, `chunks/<cid>.files` matching that chunk, and one
   close-out line per card; `call.stamp` predates every card's enqueue.
5. With an env-key lane and an unreadable `ENV_MASTER_FILE` the call aborts at
   `env_master_preflight` before any spawn, nonzero rc — inherited, not re-implemented.
6. A pinned lane blocked past `PIN_WAIT_SEC` parks its card and the call exits nonzero via
   `_check_parked` — no new exit path.
7. `check.sh` green (shellcheck, full bats, PII gate).

## Known limits

- **Shared-target diff gate is weak in bulk.** With N cards writing into one `--write` target,
  "done" means the worker exited with a usable answer *and* something under the target changed — the
  gate cannot attribute that change to the card that claimed it. Per-card truth is the FR-10 report.
- **`.chain` fallback tokens are not preflighted.** `env_master_preflight` resolves the lane set
  from conf plus `.lane` pins; a `--chain` whose *fallback* is an env-key lane still fails at spawn
  time rather than at launch.
- **Bulk prompts must be idempotent.** Any retry — lease reap, chain hop, watchdog kill — re-runs
  the card's whole chunk from the top, including files it already edited.
- **Newline-in-path is unsupported.** Chunking and the report are line-oriented; a path containing
  a newline corrupts both the manifest and the FILES block.
- **The write fence is lexical.** The FR-5 path fence refuses absolute-outside and `..`-climbing
  paths but does not resolve symlinks (per-path `realpath` at 4000 paths is 4000 forks) — a
  symlink inside the root that points outside it is not caught.
- **Same-id concurrency is unguarded.** Two simultaneous `call`s with the same `--id` against the
  same bus can race the collision checks (classic TOCTOU). The live-pool `run.pgid` guard catches
  staging into a *running* bus; the simultaneous-staging window is accepted — per-run default
  busdirs (`$$`-unique) make it a deliberate-operator-error case, not an accident.

## Dependencies

**Internal:** spec 01 (bus lifecycle, `.lane`/`.write` sidecars, pool, gate, watchdog), spec 04
(`swarm.conf`, chains, `WORKER_TIMEOUT_SEC`), spec 10 (chain semantics, lane classes). Launch
preflight and close-out evidence are consumed unchanged from the shipped engine.
**External:** none beyond the current stack (bash ≥ 5.1, coreutils `split`/`stat`).

## Open questions

None outstanding.
