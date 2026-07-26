<!--
Project: unimatrix — multi-model agent-swarm orchestrator driven from Claude Code
Module:  docs/fleetops-contract.md
Deps:    sql/uni-schema.sql (normative DDL), specs/08-speedwars.md, specs/12-failure-evidence.md,
         specs/17-plugin.md, tests/fixtures/verdict-fold/README.md (normative
         fold semantics), plans/004-plugin-cli-cockpit-fleetops/PRD.md (source decision record)
Tested:  tests/uni-schema.bats (schema + golden-file emitter contract), tests/verdict-fold.bats
         (fold semantics both renderers must reproduce)

Key responsibilities:
- Versioned statement of what unimatrix, as PRODUCER, publishes for the fleetops consumer to build
  against — join keys, row shapes, transport, domain split, and privacy invariants.
- The single place a future consumer reads instead of unimatrix source code.

Design constraints:
- No unimatrix code may reference the consumer by name or import path — severable by construction.
- This file must itself pass the repo's PII gate: no employer name, no absolute host paths.
-->

# unimatrix -> fleetops evidence contract

**Contract version:** 1.0.0
**Date:** 2026-07-26
**Status:** PUBLISHED (2026-07-26) — phase P2 of `plans/004-plugin-cli-cockpit-fleetops/PRD.md`.

Publication is **ungated**: it does not wait on the D2 decision gate (`docs/ops/d2-gate.md`), which
governs only whether phase P3 (the DB mirror) is ever built. Everything below describes what has
actually shipped as of this date — where a field, table, or code path is still dormant or unbuilt,
this document says so explicitly rather than describing it as done.

**Producer:** unimatrix (this repo). unimatrix owns the schema, the emitter, and this document.

**Consumer:** a fleetops feature inside the Brain monorepo. **It does not exist yet** — as of this
publication, no code anywhere in the Brain monorepo mentions "fleetops" (that grep returning a
positive hit is literally the entry gate for phase 5 of the PRD above). This contract, plus the
three other files listed in "How the consumer starts" below, is everything the consumer needs —
without reading a line of unimatrix source. Nothing in unimatrix — no file name, no code comment, no
config key — references the consumer; deleting the (currently dormant) emitter leaves unimatrix's
own test suite green. That severability is deliberate: if the consumer never materializes, this
contract costs unimatrix nothing to have published, and nothing to delete.

---

## Join keys

A row is uniquely identified by, and joinable across systems on, these fields:

- **`session_id`** — **LIVE.** `run_summary()` stamps this verbatim from `$CLAUDE_CODE_SESSION_ID`
  onto every `uni_run` row it produces (spec 17 FR-7, `_session_stamp()` in `src/swarm-lib.sh`).
  Read-only, never invented. **Null when:** the run was driven headless (no Claude Code session env
  set), or the row predates spec 17 FR-7 landing (any run closed before 2026-07-26).
- **`session_marker`** — **LIVE.** The statusline's per-session emoji, computed by a bash mirror of
  `sessionEmoji()` (`~/.claude/helpers/statusline-lcars.mjs`, locked `chmod 444`) hashing
  `session_id` — pure 32-bit arithmetic, no runtime dependency, verified byte-identical against the
  real formula for pinned session ids (`tests/swarm-lib.bats`). This is a **FROZEN external
  interface**: unimatrix reads it read-only and this contract never causes it to be extended,
  reshaped, or given new fields. **Null exactly when `session_id` is null** — there is no marker
  without a session id to hash. If the marker doesn't carry enough information to join cleanly to
  whatever session record the consumer already keeps, that is a fact this contract reports (see the
  join-hit-rate paragraph below), not a reason to touch the marker.
- **`account`** — **LIVE.** `$CLAUDE_ACCOUNT` verbatim if set, else `basename($CLAUDE_CONFIG_DIR)`,
  else `null` (same `_session_stamp()` call site as the two fields above). Identifies which
  multi-account install drove the run — a coarser grain than `session_id`, and independently
  nullable: a run under a plain single-account install with neither env var set yields
  `account: null` even when `session_id` is present.
- **The run join key** (`uni_run.run` / `uni_card.run` / `uni_event.run`) — resolved by
  `_run_label()` (`src/swarm-lib.sh`, P0-FR1 as amended 2026-07-25), first hit wins:
  1. `$SPEEDWARS_RUN` — an explicit operator override.
  2. The bus's own persisted `$BUSDIR/.run-label`, pinned once at run start by the run that used it.
  3. A derived default: a bus dir named `.bus-<suffix>` yields `<suffix>`; any other layout (the
     plain `.bus` dir) yields the bus dir's **parent** directory's basename.

  **Consumer warning:** this resolution order (steps 1-2, and the persistence in step 2) landed
  2026-07-26. Rows written before that date may carry a *collapsed* label from the pre-fix
  behavior — every sibling bus in one checkout deriving the same parent-directory default and
  folding into a single run key. `docs/ops/ledger-coverage.md` (2026-07-25) measures a related
  symptom of the same pre-fix gap in the live ledger — only 52% of distinct run labels (20 of 38)
  are covered by even one `run-meta` annotation row — as a concrete illustration that ledger join
  keys before this fix are not reliably complete. A consumer joining on `run` for historical data
  should expect, measure, and print its own hit-rate rather than assume 100%.
- **Row identity — the primary key, not a convenience key:**
  - `uni_run`: `(host, busdir_realpath, run, ts)` — `ts` is a PK member so a re-run of the same bus
    under the same persisted run label (`.run-label`) produces a new row instead of colliding with
    the prior run-summary for that `(host, busdir_realpath, run)`.
  - `uni_card`: `(host, busdir_realpath, run, id, ts, seq)`
  - `uni_event`: `(host, busdir_realpath, run, id, ts, type, seq)`

  **Why `seq` is on `uni_card` and `uni_event`:** `ts` is second-precision. A same-second retry of
  the same `id` (a real shape — bounded same-lane retries and pinned-lane fallbacks can both re-emit
  a row for the same id inside one wall-clock second) would otherwise collide the PK and silently
  drop a row on import. `seq` is an **importer-assigned monotonic counter per input JSONL line** —
  not sourced from the JSONL row itself, which carries no such field — added purely to keep the PK
  unique. Consumers order rows by `(ts, seq)`, never `ts` alone.

  **Why `host` and `busdir_realpath` are stamped by the importer, not the producer:** neither
  `speed_row()` nor `run_summary()` emits either field — a JSONL row has no notion of the machine or
  bus-dir path that will eventually import it. The phase-3 importer stamps both at import time:
  `host` from the importing context, `busdir_realpath` from the run's own archive
  (`docs/ops/bus-archives/<run>/MANIFEST.txt`'s `bus:` line, written by `bus_archive()` in
  `src/swarm-lib.sh` — see "Archival" below), combined with that archive's own directory context to
  stay distinct per archived run. This is why the cross-worktree case in
  `tests/fixtures/uni-mirror/golden.sql` (two different `busdir_realpath` values for the same
  `run`/`id`, from "alpha" vs "bravo" worktrees) is still valid after this change — different
  archives still stamp different values, so the PK still needs both fields to stay unique.

  **Why `busdir_realpath` is load-bearing and not decorative:** a bare `run` label collides across
  worktrees. Three worktrees of the same repo (or the same repo checked out under different names on
  different hosts) each derive their run label the same way — `basename(dirname(busdir))` or
  `basename(busdir)`, depending on the call site — so it is entirely possible for two *different*
  runs, produced by two *different* worktrees, to carry the identical `run` string. A primary key of
  `(run, id)` alone would silently merge those into one row and quietly lose evidence. `host` plus
  the **realpath** of the bus directory (not a display path, not a symlink-following-optional path —
  the fully resolved path) makes the key unique again without asking any run-producing code to change
  how it names itself.

`session_id` / `session_marker` / `account` are join **conveniences** for cross-referencing against
whatever the consumer already knows about a human's working session; the PK above is the only field
set the contract guarantees uniqueness on. Expect — and the consumer's build-out should measure and
print, not assume — some percentage of rows that fail to join cleanly to a session, because the row
predates these fields or because a run was driven headless. A contract that can't state its own join
hit-rate is not trustworthy; state it.

---

## Row shapes

Three tables, `uni_` prefix, one JSON payload column each. **`sql/uni-schema.sql` is the normative
DDL** — this section is a summary for orientation, not a second source of truth. If this section and
the SQL ever disagree, the SQL wins and this file has drifted and needs fixing.

| Table | One row per | Source |
|---|---|---|
| `uni_run` | a finished run | `run_summary()` |
| `uni_card` | a finalized branch | `speed_row()` |
| `uni_event` | everything else, verbatim | any other typed row (verdict, review, run-review, run-meta, feedback, ...) |

`uni_event` is the escape valve: a new spec introducing a new row type needs zero DDL changes on
either side of this contract — it lands as a typed row in `uni_event` and only earns a promoted,
named column in `uni_card`/`uni_run` after weeks of the consumer actually querying it that way.

### Column reference

Every column, every table, matching `sql/uni-schema.sql` exactly. **Stable** means the column keeps
its current name/type/meaning going forward; **payload** means the value lives inside the JSON
`payload` blob today and may or may not ever get promoted to a named column (see the escape-valve
paragraph above) — don't build against a payload key name as if it were pinned.

**`uni_run`** — PK `(host, busdir_realpath, run, ts)`

| Column | Type | Nullable | Note |
|---|---|---|---|
| `host` | TEXT | NOT NULL | Stable. Stamped by the phase-3 importer (see "Join keys") — never emitted by `run_summary()` itself. |
| `busdir_realpath` | TEXT | NOT NULL | Stable. Stamped by the phase-3 importer from the run's archive `MANIFEST.txt`. |
| `run` | TEXT | NOT NULL | Stable. The run label (`_run_label()`). |
| `ts` | TEXT | NOT NULL | Stable. ISO-8601 UTC; PK member so a re-run of the same label doesn't collide. |
| `mode` | TEXT | NOT NULL, CHECK `full`\|`verify` | Stable. |
| `done_n` | INTEGER | NOT NULL DEFAULT 0 | Stable. |
| `parked_n` | INTEGER | NOT NULL DEFAULT 0 | Stable. |
| `fallback_hops` | INTEGER | NOT NULL DEFAULT 0 | Stable. |
| `wall_secs` | REAL | NOT NULL DEFAULT 0 | Stable. |
| `cost_usd` | REAL | NOT NULL DEFAULT 0 | Stable. |
| `stderr_n` | INTEGER | NOT NULL DEFAULT 0 | Stable. Count only — never stderr content. |
| `session_id` | TEXT | nullable | Stable join key (P1-FR7). Null pre-phase-1 or headless. |
| `session_marker` | TEXT | nullable | Stable, FROZEN external interface (statusline emoji). Null iff `session_id` is null. |
| `account` | TEXT | nullable | Stable join key (P1-FR7). Independently nullable. |
| `payload` | TEXT (jsonb on Postgres) | NOT NULL | Payload: `{branches:{}, lanes_limited:[], lanes_dead:[]}`. |

**`uni_card`** — PK `(host, busdir_realpath, run, id, ts, seq)`

| Column | Type | Nullable | Note |
|---|---|---|---|
| `host` | TEXT | NOT NULL | Stable. Importer-stamped, same as `uni_run.host`. |
| `busdir_realpath` | TEXT | NOT NULL | Stable. Importer-stamped, same as `uni_run.busdir_realpath`. |
| `run` | TEXT | NOT NULL | Stable. |
| `id` | TEXT | NOT NULL | Stable. Branch id. |
| `ts` | TEXT | NOT NULL | Stable. Second-precision — order by `(ts, seq)`, not `ts` alone. |
| `requested` | TEXT | nullable | Stable. `"<lane>:<model>"` as requested, post fbreason-override. |
| `served_lane` | TEXT | nullable | Stable. Null for a parked card (never served by any lane). |
| `served_model` | TEXT | nullable | Stable. |
| `outcome` | TEXT | NOT NULL | Stable name, **free-text value at source** (`done`, `parked`, `timeout`, `lane-unusable`, ... — not an enum). |
| `wrc` | INTEGER | nullable | Stable. Real worker rc. |
| `pinned` | INTEGER | NOT NULL DEFAULT 0, CHECK 0/1 | Stable. SQLite boolean convention. |
| `wall_secs` | REAL | nullable | Stable. |
| `billing` | TEXT | nullable, CHECK NULL\|`real`\|`pool` | Stable enum, but nullable: 226 of 914 live rows predate the field (up to 2026-07-24T10:49Z). |
| `class` | TEXT | nullable, CHECK NULL or one of the 12-value vocabulary below | Stable **column**, but the vocabulary is a living list — see the CHECK constraint in `sql/uni-schema.sql` and its comment. Current values: `auth-death`, `api-error`, `server-error`, `rate-limit`, `timeout-watchdog`, `spawn-fail`, `false-done`, `no-answer`, `lane-down`, `parked-env`, `cage-denied`, `write-target-missing`. |
| `verified` | INTEGER | nullable, CHECK NULL\|0\|1 | Stable. Folded at import from `uni_event` verdict rows — never set by `speed_row()`. |
| `verify_reason` | TEXT | nullable | Stable. Same fold as `verified`. |
| `cost_usd` | REAL | nullable | Stable. |
| `tokens_in` | INTEGER | nullable | Stable. |
| `tokens_out` | INTEGER | nullable | Stable. |
| `payload` | TEXT (jsonb on Postgres) | NOT NULL | Payload: the remaining per-lane usage bucket — shape varies by lane, never pinned. |
| `seq` | INTEGER | NOT NULL DEFAULT 0 | Stable. Importer-assigned monotonic counter per input line — disambiguates same-second rows. |

**`uni_event`** — PK `(host, busdir_realpath, run, id, ts, type, seq)`

| Column | Type | Nullable | Note |
|---|---|---|---|
| `host` | TEXT | NOT NULL | Stable. Importer-stamped, same as the other two tables. |
| `busdir_realpath` | TEXT | NOT NULL | Stable. Importer-stamped, same as the other two tables. |
| `run` | TEXT | NOT NULL | Stable. |
| `id` | TEXT | nullable | Stable. Some event types (e.g. a run-scoped `review`) carry no per-branch id. |
| `ts` | TEXT | NOT NULL | Stable. Order by `(ts, seq)`, same as `uni_card`. |
| `type` | TEXT | NOT NULL | Stable **column**; the value set is open (`verdict`, `review`, `run-review`, `run-meta`, `feedback`, ... — this table is the escape valve, so new types need no DDL change). |
| `payload` | TEXT (jsonb on Postgres) | NOT NULL | Payload: the source row, verbatim. |
| `seq` | INTEGER | NOT NULL DEFAULT 0 | Stable. Same disambiguator as `uni_card.seq`. |

---

## Verdict fold — the normative semantics (not this file's to redefine)

`uni_card.verified` / `uni_card.verify_reason` are **folded in at import** from correction rows
(`uni_event` rows of `type: verdict`) — a phase-3 importer behavior, not something `sql/uni-schema.sql`
enforces itself (both columns are NULL-able and NULL by default; see that file's own comment on
them). The fold's semantics are not this contract's to define per-consumer: **the canonical rules
live in `tests/fixtures/verdict-fold/README.md`** (13 numbered rules), replayed against
`tests/fixtures/verdict-fold/ledger.jsonl` / `expected.json` by `tests/verdict-fold.bats`, and are
the exact contract `src/speedwars-report.sh --json` and the cockpit's `site/cockpit/fold.js` both
implement today.

Any consumer computing verified-done / false-done / unjudged / `$` per verified-done from
`uni_card` + `uni_event` rows **must reproduce those rules**, most load-bearing among them:

- Join key is `run/id`, never lane-scoped (a verdict row carries no executor lane).
- The **last** verdict row for a key wins (append-only ledger, corrections are appended not edited).
- A card with no verdict row is **unjudged** — never counted verified, regardless of its claimed
  `outcome`.
- `verified: null` (gate inconclusive) is also unjudged, reported separately as `inconclusive` —
  not the same bucket as a refutation.
- **The full observed `verified` value set in the live ledger** is `true`, `false`, `null`, and the
  strings `"pass"`, `"fail"`, `"partial"`, `"pass-with-flag"`. Only two of those five non-boolean
  spellings fold to a judgment: v0 rows encode `verified` as the strings `"pass"` / `"fail"` on some
  lanes, and these fold as their boolean counterparts, case-exact. Every other non-boolean value —
  `null`, `"partial"`, `"pass-with-flag"`, or any spelling not in this list — is **not** a judgment:
  it stays unjudged/inconclusive per rule 6, same as a missing verdict row (fixture rule 11,
  `tests/fixtures/verdict-fold/README.md`). A consumer that treats `"partial"` or
  `"pass-with-flag"` as truthy will overcount `verified_done`.
- `$ per verified-done`'s numerator is the lane's **entire** priced spend, failed attempts included;
  the denominator is `verified_done` count, never done-claims, never attempts.

Re-deriving a different fold produces a verified/false-done count that silently disagrees with
unimatrix's own reports over the identical source rows. Read the rules file; don't reverse-engineer
them from one example row.

---

## Transport: JSONL is live today, SQL is a phase-3 shape

**What is actually live today: the JSONL transport, nothing more.** The speedwars ledger JSONL
(`docs/ops/speedwars.jsonl`) is the one artifact a consumer can ingest right now — the addendum
below documents the first real consumer doing exactly that, reading the JSONL directly and using
line-sha256 for idempotency. **No SQL emitter exists, and no database — local or work-side — is
written by anything in this repo today.** There is no `unimatrix mirror` code path at all yet; grep
this repo for `sqlite3`/sql-applier code and you will find none outside `tests/` (which reads
`sql/uni-schema.sql` and the pinned golden fixture directly, to pin the *shape*, not to exercise a
real emitter).

The SQL side of this contract is a **phase-3 deliverable whose shape this contract pins in
advance**, not a running system:

1. **The emitter (not built):** a pure function, JSONL evidence in, SQL text out, against the DDL in
   `sql/uni-schema.sql`. `tests/fixtures/uni-mirror/golden.sql`, pinned against
   `tests/fixtures/uni-mirror/run-close.jsonl`, is the golden file a real implementation must match —
   written and tested before the emitter exists, so the shape can't drift once it's built.
2. **Local applier (not built):** would apply the emitted SQL via the system `sqlite3` CLI against a
   local SQLite file.
3. **Work-side mirror applier (`unimatrix mirror --push`, not built):** would apply the *identical*
   emitted SQL via `psql` against a work-side Postgres database. This path stays dormant until
   **both** (a) the D2 gate (`docs/ops/d2-gate.md`) is met or explicitly overruled, and (b) the
   consumer has accepted this contract. Turning it on before that point would be shipping a write
   path with nobody reading the other end.

Because both appliers, once built, would run the same emitted SQL, there is exactly one place a
future schema bug could hide — the emitter — and exactly one file that defines what correct output
must look like: `tests/fixtures/uni-mirror/golden.sql`. Until phase 3 ships, that file's job is
purely to prove `sql/uni-schema.sql` itself is sound (applies clean, PK collisions are caught, row
shapes match what the JSONL evidence would map to) — not to prove any emitter, because none exists.

---

## Archival — raw evidence, DB-independent

**`docs/ops/bus-archives/<run>/`** is the raw-evidence backup target, and it is **live today**:
`bus_archive()` (`src/swarm-lib.sh`), fired from every `full_run`/`verify_run` close-out
(`swarm-run.sh`), freezes one directory per run label there. Per P3-FR10 doctrine, **the database
holds zero original data** — every table in `sql/uni-schema.sql` is a rebuildable projection, so a
migration is always drop-and-rebuild, never an in-place transform of data that exists nowhere else —
and these archives, not the database, are the actual backup target.

**Layout** (full reference: `docs/ops/bus-archives/README.md`), one directory per run label:

```
docs/ops/bus-archives/<run-label>/
  run-<id>.jsonl.<ext>          # every worker transcript
  run-<id>.jsonl.<n>.<ext>      # its rotated predecessors
  run-<id>.jsonl.stderr.<ext>   # per-worker stderr
  res-<id>.txt.<ext>            # handoff answer files
  write-<id>.txt.<ext>          # write-card target provenance
  speedwars.jsonl.<ext>         # this run's ledger rows (filtered on .run)
  markers.tar.<ext>             # done/ + limits/ marker trees, one tar (thousands of tiny files)
  run-summary.json              # the run's last run-summary ledger row, uncompressed
  MANIFEST.txt                  # run, timestamp, bus BASENAME (never an absolute path), compressor, member list
```

This closes what used to be a known gap: reproducing a *past* run's full BOARD / FIREHOSE / AGENTS
view needs the raw per-worker `run-*.jsonl` transcripts and the `done/`/`limits/` marker tree, and
`bus_archive()` now captures exactly those (`markers.tar.<ext>` for `done/`+`limits/`, plus the raw
transcripts), archived at run close.

**Gitignored, deliberately — not a tracked backup.** `res-*.txt`, `run-*.jsonl`, and `write-*.txt`
hold worker output (answer text, tool transcripts, anything a worker fetched from the web while
producing it); `CLAUDE.md` §Git forbids committing worker output for exactly that reason. Everything
under `docs/ops/bus-archives/` except its own `README.md` is excluded in `.gitignore`
(`docs/ops/bus-archives/*` / `!docs/ops/bus-archives/README.md`) — this directory is the **backup**
target precisely because it stays out of git; back it up out-of-band.

**Compression — zero new runtime dependency.** `gzip` is always present and is the guaranteed
fallback; `zstd` is used when installed (smaller archives, same idempotent shape). Check
`command -v zstd` before assuming it — do not fail an archive step for its absence, and record which
one produced a given archive rather than assume: **`.jsonl.gz` is the recorded extension when zstd
is unavailable**, `.jsonl.zst` when it is. This is not hypothetical — the existing ad hoc
`docs/ops/bus-archives/*-bus.tar.{zst,gz}` snapshots already show both extensions in the wild (most
`.tar.zst`, two `.tar.gz` from a run made without `zstd` installed); this contract makes that
substitution rule explicit for any future structured archiver instead of leaving it implicit.

---

## Domain split rule

Work-domain runs may **only ever** push to the work-side Postgres. Personal runs may **only ever**
push to the personal Supabase project. There is no third option and no run that pushes to both.

The split is chosen from **`busdir_realpath`** at push time, against a prefix rule:

- `DOMAIN_WORK=<work-repos-prefix>` — a key in `~/.config/unimatrix/config` (not `swarm.conf`, not
  `fleet.json` — `fleet.json` stays a pure registry, never a policy file).
- A `busdir_realpath` starting with that prefix is work-domain; everything else is personal-domain.

**On mismatch, the push HARD REFUSES: nonzero exit, zero partial writes.** Not a warning, not a
best-effort partial import that lands half a run in the wrong database. If the domain can't be
determined confidently, or the target the caller asked for doesn't match the domain the path implies,
nothing is written anywhere. A silent misroute here is strictly worse than a loud no-op — it would
put one person's work-side evidence in a personal database (or vice versa), and the DB holding "zero
original data" (see below) is only a safe invariant if every write that *did* land is known to be in
the right place.

---

## Privacy invariants

These hold for every row, in every table, in both the local SQLite mirror and the (dormant) work-side
Postgres mirror:

- **Zero prompt/task text in any table.** This is spec 08's strongest rule (`specs/08-speedwars.md`),
  inherited unchanged: ids, lanes, classes, counts, and paths only — never the content a worker
  produced or was asked to produce. `uni_event`'s payload is "everything else, verbatim" from the
  *evidence* rows the engine already writes (speedwars ledger rows, verdicts, reviews) — it is not a
  general-purpose sink for arbitrary JSONL, and none of the engine's evidence rows carry prompt or
  answer text today (spec 12's scrub-by-construction guarantee).
- **Paths and tokens only.** Where a value must identify something, it identifies it by path, id, lane
  name, or class — never by pasting the thing itself.
- **DSN from env only.** No database connection string is ever written into `swarm.conf`, into this
  repo, into a config file meant to be read by the cockpit's `/api/config`, or passed as a `ps`
  argv-visible argument. It comes from the process environment at push time and nowhere else.
- **The database holds zero original data.** Every table here is a rebuildable projection of the
  JSONL evidence the engine already writes; a migration is always drop-and-rebuild, never an
  in-place transform of data that exists nowhere else. The JSONL archives — not the database — are
  the thing that gets backed up. If both mirrors (local SQLite and the dormant work-side Postgres)
  vanished tonight, the only loss is query convenience; re-running the emitter against the retained
  JSONL reproduces every row.

---

## How the consumer starts

Everything the fleetops consumer needs to build against is these four files — no unimatrix source
required:

1. **This document** — join keys, row shapes, transport, domain split, privacy invariants.
2. **`sql/uni-schema.sql`** — the normative DDL; wins over this document's summary on any conflict.
3. **`tests/fixtures/uni-mirror/{run-close.jsonl,golden.sql}`** — the golden emitter fixture: JSONL
   evidence in, exact SQL out, byte-for-byte pinned by `tests/uni-schema.bats`.
4. **`tests/fixtures/verdict-fold/{README.md,ledger.jsonl,expected.json}`** — the normative
   verified-done / false-done fold, required only if the consumer computes either.

**Severability, restated:** no file in this repo is named `fleetops`, no code path here imports or
calls anything Brain-side, and deleting the (currently dormant) mirror/emitter leaves this repo's own
`check.sh` green. If the consumer never materializes, publishing this contract cost unimatrix nothing
to have written, and nothing to delete.

---

## Non-goals of this document

- This is not an announcement that fleetops exists — it doesn't (see "Consumer" above).
- This is not a migration guide, an API reference, or a client library — the consumer reads SQL
  tables directly, SELECT-only, same access shape as `ops.cockpit_run_telemetry` on the Brain side.
- This does not authorize turning `unimatrix mirror --push` on. That switch is the consumer's
  acceptance of this contract AND the D2 gate being met or overruled — not a unimatrix-side decision
  made by publishing this file.

---

## Addendum 2026-07-26 — first consumer materialized (not Brain)

Robert's ruling (work-side refactor plan 016, delegated): no Brain in play. The first consumer of
this producer's telemetry is **the work-side refactor monorepo's tooling database** (Postgres,
loopback-only), plan-014 shape — `bronze.speedwars_row` JSONB landing ingests the speedwars JSONL
transport directly (line-sha256 idempotent), and `gold.run_wide` / `gold.card_wide` borrow this
contract's `uni_run`/`uni_card` column semantics (done_n, parked_n, fallback_hops, stderr_n;
latest-card-wins + verdict fold). The SQL emitter / `mirror --push` lane of this contract stays
dormant, producer-side; the JSONL remains the transport. Full reconciliation:
`<work-refactor-repo>/plans/016-fleetops-db/01-RESOLUTIONS.md`.
