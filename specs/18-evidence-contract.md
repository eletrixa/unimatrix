# Spec 18 — Evidence Contract: Push Summary, Bus Archives, and the fleetops Producer Contract

**Status:** Active (retroactive spec-of-record — every FR below describes an artifact that shipped
in commits `deafc8f` and `f81eba3` **before** this document existed; approval basis: Robert's plan-B
execution order of 2026-07-25/26, which sequenced plan-004 phase 2's build ahead of writing its
spec, plus the **D1 contract-first decision**
(`plans/004-plugin-cli-cockpit-fleetops/PRD.md` header: "D1 = both engines, sequenced — SQLite live
now via sqlite3 CLI, psql push wired-but-dormant, contract (`sql/uni-schema.sql` +
`docs/fleetops-contract.md`) published UNGATED so Brain's fleetops builds against it"))
**Date:** 2026-07-26
**Related specs:** [08-speedwars](./08-speedwars.md) (the ledger + canonical verdict fold this
spec's summary and contract both read, never re-derive), [12-failure-evidence](./12-failure-evidence.md)
(`run_summary()`, the fixed failure-class vocabulary `sql/uni-schema.sql` reproduces verbatim as a
CHECK constraint), [17-plugin](./17-plugin.md) FR-7 (`session_id` / `session_marker` / `account` —
the join keys this contract documents as LIVE).
**Plan of record:** [plans/004-plugin-cli-cockpit-fleetops/PRD.md](../plans/004-plugin-cli-cockpit-fleetops/PRD.md)
§5 Phase 2 (P2-FR1…P2-FR3) and §3 D1/D2. FR-1…FR-6 below map onto P2-FR1…P2-FR3 plus the
phase-2-adjacent artifacts the same commit shipped (bus archives, `report --html`, the contract
document itself) that the PRD's phase table names in prose but does not number as separate FRs.

---

## Overview

Plan 004 phase 2 shipped as one commit (`deafc8f`) before this spec was written: a three-line lane
summary at every run close, coverage denominators on every stratified figure, a structured raw-
evidence backup target (`docs/ops/bus-archives/`), a static-HTML report export, the versioned
fleetops producer contract (`docs/fleetops-contract.md` + `sql/uni-schema.sql` + golden fixtures),
and the D2 gate that decides whether any of that ever grows a database. A follow-up commit
(`f81eba3`) amended the contract once a real consumer named itself. This spec is the spec-of-record
those two commits should have had — it describes what shipped, cites the code and tests that prove
it, and does not propose new behavior.

**Why phase 2 exists at all:** pre-mortem finding #16 ("nobody read the reports") is the highest-
likelihood, highest-damage failure mode for a single-operator reporting surface. The project's
answer is to ship the cheapest possible push line first (FR-1/FR-2) and gate everything with a pull
surface — a database, a cockpit tab, a mirror — behind proof that the push line actually changed a
decision (FR-6, the D2 gate). Phase 2 is deliberately allowed to be the entire project: **if the
gate is never met, phases 3-5 never start, and that is success, not failure** (`docs/ops/d2-gate.md`,
"Honest-cancel clause").

**Naming note — why this is 18 and not the reserved "mirror" spec.** The plan-004 dossier's forward
references (spec 17's Non-Goals, its Open Questions) reserved "specs 18/19" for the un-numbered rest
of the dossier without distinguishing which half goes where. This spec claims 18 for the
**contract-and-evidence half**: the producer contract, the archive layout, the push summary, and the
gate that governs whether a mirror ever gets built. The **executable mirror** — `unimatrix mirror
--push`/`--verify`, the SQL emitter, the psql applier (PRD phase 3, P3-FR1…FR10) — remains
unbuilt and unspecified, reserved for spec 19 or a numbered amendment to this one, and only after
the D2 gate (`docs/ops/d2-gate.md`) is met or explicitly overruled in writing.

## Goals

- **A push surface cheap enough that shipping it costs nothing if nobody reads it** — zero new
  dependency, derived entirely from the existing JSONL ledger, never a second aggregation.
- **Evidence that outlives the busdir** — the raw per-run transcripts, answers, and marker tree
  survive a bus cycle in a backup-shaped location, without becoming a database.
- **A versioned contract a future consumer can build against without reading unimatrix source** —
  join keys, row shapes, transport, domain split, and privacy invariants, all in one document plus
  one DDL file plus one golden fixture pair.
- **An honest, dated gate** that stops the DB mirror from being built on vibes — the criterion is
  written down before the clock starts, not reconstructed to justify a decision already made.

## Non-Goals

- **No emitter or applier code ships under this spec.** The SQL emitter (JSONL in, INSERT text
  out), `unimatrix mirror --push`/`--verify`, and the psql applier are phase-3 concerns
  (`plans/004-plugin-cli-cockpit-fleetops/PRD.md` P3-FR1…FR10) and start only when the D2 gate
  (FR-6 below) is met or overruled in writing. `sql/uni-schema.sql` is DDL only — its own header
  says so: "No DSN, no ATTACH, no engine-execution-path code lives here."
- **No database anywhere in the engine's execution path.** `swarm-run.sh`, `swarm-loop.sh`,
  `swarm-mon.sh`, and `src/swarm-lib.sh` stay DB-free; `check.sh`'s DB-symbol gate (step 2, "DB
  reference in the engine path silently invalidates" the file-bus as the entire coordination layer)
  enforces this mechanically, not by convention.
- **JSONL is the live transport, full stop, as of this spec.** No SQL row produced by this spec's
  FRs is read by any running code today — `docs/fleetops-contract.md`'s addendum
  (2026-07-26) records that the first real consumer (the reforge tooling database in a separate
  work-side monorepo) ingests the **speedwars JSONL directly** into a `bronze.speedwars_row` landing
  table, not through this contract's SQL emitter. The emitter and the two appliers this contract
  describes remain dormant; nothing in this spec changes that or asks it to.
- **No fleetops code, no file named `fleetops`, anywhere in this repo.** Severability is asserted in
  `docs/fleetops-contract.md` itself: deleting the (dormant) emitter leaves `check.sh` green.
- **No statusline change.** FR-5's join keys are read-only consumption of spec 17 FR-7's fields; this
  spec extends nothing on the statusline side.

## FR-1 — Three-line lane summary at run close (P2-FR1)

`lane_summary()` (`src/swarm-lib.sh:2643`) prints **exactly three lines on stderr** at the close of
every `full_run`/`verify_run` — $ per verified-done, p95 wall, and false-done rate, one line per
metric, every lane across it (the densest shape for the actual close-out question: "which lane won
on cost / speed / trust"). Every figure is **shelled from `src/speedwars-report.sh --json --run
<label>`**, the canonical verdict fold — `lane_summary()` never re-aggregates the ledger itself, so
this line and `speedwars-report`'s own table can never silently disagree. Wired into
`_close_out_evidence()` (`swarm-run.sh:1316`), guarded so a summary failure never fails the run
(`|| true`-shaped, returns 0 on a missing ledger or missing file).

> **Acceptance criterion (PRD P2-FR1, verbatim):** The lines print on a real run; `check.sh` wall
> time unchanged *(#16)*

## FR-2 — Coverage denominator on every stratified figure (P2-FR2)

Every stratified figure `lane_summary()` prints carries its own denominator inline — $/verified-done
its verified/cards and priced/attempts counts, p95 its lane attempt count, false-done rate its
judged-card count — so a reader never mistakes a thin sample for a solid one. No stratified number
renders without the count it was computed over sitting next to it.

> **Acceptance criterion (PRD P2-FR2, verbatim):** No stratified figure renders without its
> denominator *(#17)*

## FR-3 — Bus archives: raw evidence outlives the busdir

`bus_archive()` (`src/swarm-lib.sh:2701`), fired from `_close_out_evidence()` at the end of every
run, freezes `docs/ops/bus-archives/<run-label>/` — the per-worker transcripts and rotations, per-
worker stderr, handoff answer files, write-target provenance, this run's ledger slice, the
`done/`+`limits/` marker tree as one tar, and the run's last `run-summary.json` row uncommitted —
plus a `MANIFEST.txt` naming the compressor used. Compression is decided **per run**: `zstd` when
installed, `gzip` (always present) otherwise — zero new runtime dependency either way, and
`MANIFEST.txt` records which one ran. Idempotent per run label (re-closing replaces only that run's
own directory); never fatal (an unwritable target, a missing tool, or a compressor error is a silent
no-op, per the same doctrine as the speedwars ledger itself — evidence capture may never fail an
otherwise-good run); opt-out via `BUS_ARCHIVE=0`.

**Gitignored, and deliberately so.** `res-*.txt`, `run-*.jsonl`, and `write-*.txt` hold worker
output — answer text, tool transcripts, anything a worker fetched from the web — which `CLAUDE.md`
§Git forbids committing. `.gitignore` excludes everything under the directory except the tracked
`README.md` (`docs/ops/bus-archives/README.md`, which documents the layout above). This directory
is the **backup target**, not a tracked one: back it up out-of-band.

> **Acceptance criterion:** every run leaves a well-formed archive directory (or a documented no-op)
> that a full backup rotation can pick up; nothing here is tracked in git.

## FR-4 — `unimatrix report [--html]`

`cmd_report()` (`unimatrix:416`) execs `src/speedwars-report.sh` unmodified in its plain form (argv
and rc passed straight through — the same shape `swarm-ctl report` already used). `--html`
additionally renders a **self-contained static page**: the canonical table plus the embedded
canonical JSON (`_html_esc()`, `unimatrix:406`, escapes the three markup-significant characters),
written to `<home>/docs/ops/report-<date>.html` with zero external assets, zero network calls, and
zero new dependency. This is the answer to remote/asynchronous viewing without a server: "a static
file cannot kill a worker" (PRD P4-FR3's framing) — there is no listening socket to secure or forget
to close.

> **Acceptance criterion:** `unimatrix report --html [ledger]` writes a self-contained HTML file and
> prints its path; passthrough flags (`--run <label>`) reach the underlying fold unchanged.

## FR-5 — fleetops producer contract v1.0.0 (D1 contract-first)

`docs/fleetops-contract.md` (contract version 1.0.0, published 2026-07-26) plus `sql/uni-schema.sql`
(the normative DDL — three tables, `uni_` prefix, one JSON payload column each) plus the golden
emitter fixture pair (`tests/fixtures/uni-mirror/run-close.jsonl` / `golden.sql`) are the **entire**
artifact set a future consumer needs — no unimatrix source required. This ships **ungated** by D1
(the phase-3 mirror code stays gated by D2; the contract *document* does not wait on it), because a
contract costs nothing to publish and nothing to delete if no consumer ever appears.

The contract states, and this FR reproduces as requirements:

- **Join keys are LIVE, not aspirational:** `session_id`, `session_marker`, `account` are stamped by
  spec 17 FR-7's `_session_stamp()` onto every `run_summary()` row **today**; the run join key
  resolves via `_run_label()`'s documented precedence (`$SPEEDWARS_RUN` → the bus's own persisted
  `.run-label` → a derived default), with the contract stating plainly that pre-2026-07-26 rows may
  carry a collapsed label and a consumer must measure, not assume, its own join hit-rate.
- **Row identity is `(host, busdir_realpath, run[, id[, ts[, type]]])`**, never a bare `run`/`id`
  pair — three worktrees of the same repo can and do derive the identical `run` label, and only the
  realpath of the bus directory disambiguates them.
- **The verdict fold is normative and lives in exactly one place** —
  `tests/fixtures/verdict-fold/README.md`'s 13 numbered rules, replayed by `tests/verdict-fold.bats`
  — and any consumer computing verified-done / false-done / unjudged from `uni_card`/`uni_event`
  rows must reproduce those rules rather than re-derive its own.
- **Domain split is a hard refuse, not a warning:** work-domain and personal-domain evidence never
  share a database; a `busdir_realpath` prefix mismatch at push time writes nothing anywhere.
- **Privacy invariants bind every row in both mirrors, live and dormant alike:** zero prompt/task
  text ever, paths and tokens only, DSN from env only, and the database holds zero original data —
  every table is a rebuildable projection of the JSONL evidence, so a migration is always
  drop-and-rebuild, never an in-place transform of data that exists nowhere else.

> **Acceptance criterion:** `tests/uni-schema.bats` asserts the schema applies cleanly, the golden
> fixture round-trips byte-for-byte, the failure-class CHECK constraint rejects an out-of-vocabulary
> value, and the fixture files carry no PII token and no `prompt` JSON key.

## FR-6 — The D2 gate (phase 2 → phase 3 decision criterion)

`docs/ops/d2-gate.md` is the dated, written-down criterion phases 3 (mirror) and 4 (cockpit online)
must clear before a single line of DB code exists: **three weeks elapsed from 2026-07-26 (deadline
2026-08-16) AND at least two real operating decisions changed by the FR-1 summary, each logged with
its date in that file's decisions log** — or an explicit, dated, written maintainer overrule of the
gate. Silence, a verbal go-ahead, or phase-3 code simply appearing satisfies neither condition. If
the deadline arrives with fewer than two dated rows, the criterion is unmet by design, and per the
file's own "Honest-cancel clause," that is the project working correctly — phases 0-2 stay shipped
and useful regardless of the outcome.

> **Acceptance criterion (PRD P2-FR3, verbatim):** Recorded in `docs/ops/`. **If not met — stop
> here. The project is done, and cheaply.** *(#16, D2)*

---

## Acceptance criteria

1. **FR-1** — `lane_summary()` prints exactly three lines on stderr at every run close, every figure
   traceable to `speedwars-report.sh --json`'s canonical fold; `check.sh` wall time unaffected.
2. **FR-2** — every stratified figure in that summary carries its denominator inline; none renders
   bare.
3. **FR-3** — `bus_archive()` leaves a well-formed `docs/ops/bus-archives/<run>/` directory (or a
   documented no-op) at every close; the directory is gitignored except its tracked `README.md`.
4. **FR-4** — `unimatrix report --html` writes a self-contained static page and prints its path;
   `--run`/ledger passthrough reaches the real fold.
5. **FR-5** — `docs/fleetops-contract.md` + `sql/uni-schema.sql` + the golden fixture pair are
   internally consistent (schema applies, golden round-trips, CHECK constraints hold, no PII/prompt
   text in fixtures) and require no unimatrix source to consume.
6. **FR-6** — `docs/ops/d2-gate.md` exists, states the criterion and deadline, and phases 3-5 have
   not started as of this spec's date.
7. `check.sh` green (shellcheck, full bats, PII gate — no addition here changes any of those gates'
   shape).

## Test plan

**bats-testable — already landed, this spec cites rather than adds:**

| Criterion | Test |
|---|---|
| FR-1 three-line shape | `tests/swarm-lib.bats` — "lane_summary: prints exactly three lines on stderr, one per headline metric" |
| FR-1 run scoping | `tests/swarm-lib.bats` — "lane_summary: is scoped to THIS run — a foreign run's lane never appears" |
| FR-1 derives from canonical fold | `tests/swarm-lib.bats` — "lane_summary: derives from the canonical fold, never a private aggregation" |
| FR-1 never-fatal | `tests/swarm-lib.bats` — "lane_summary: no evidence surface (no ledger) is a silent no-op, rc 0" |
| FR-2 denominators | `tests/swarm-lib.bats` — "lane_summary: P2-FR2 — every figure carries its denominator" |
| FR-3 archive contents | `tests/swarm-lib.bats` — "bus_archive: freezes the run's raw evidence into bus-archives/<run>/" |
| FR-3 round-trip + scoping | `tests/swarm-lib.bats` — "bus_archive: members round-trip and the ledger slice holds only this run" |
| FR-3 idempotence | `tests/swarm-lib.bats` — "bus_archive: re-close is idempotent — replaces its own dir, never a sibling run's" |
| FR-3 never-fatal / opt-out / label sanitization | `tests/swarm-lib.bats` — "bus_archive: an unwritable archive root is a no-op, rc 0" and "bus_archive: BUS_ARCHIVE=0 turns it off; a path-shaped run label cannot escape the tree" |
| FR-4 static export | `tests/unimatrix.bats` — "unimatrix report --html writes a self-contained page and prints its path" |
| FR-4 passthrough | `tests/unimatrix.bats` — "unimatrix report --html is redeployable and passes --run through to the fold" |
| FR-5 schema shape | `tests/uni-schema.bats` — "creates exactly the three uni_ tables", "golden.sql applies cleanly on top of the schema" |
| FR-5 row identity / cross-worktree | `tests/uni-schema.bats` — "row counts match run-close.jsonl, including the cross-worktree pair", "applying golden.sql twice fails (PK enforcement)" |
| FR-5 failure-class vocabulary | `tests/uni-schema.bats` — "uni_card.class rejects a value outside spec 12's vocabulary" |
| FR-5 privacy | `tests/uni-schema.bats` — "no forbidden PII tokens in run-close.jsonl or golden.sql", "no 'prompt' JSON key in run-close.jsonl" |
| FR-5 verdict fold normative rules | `tests/verdict-fold.bats` (all cases, replaying `tests/fixtures/verdict-fold/{ledger.jsonl,expected.json}`) |

**Not bats-testable — evidenced by the file itself, checked by inspection:**

1. **FR-6** — `docs/ops/d2-gate.md` exists with a dated deadline and an empty decisions log at
   publication; whether phases 3-5 have started is a repo-state fact (no `unimatrix mirror`
   subcommand, no DB code in any engine script — the same `check.sh` DB-symbol gate that protects
   the engine path today also happens to prove this true for as long as it stays green).
2. **Severability (FR-5)** — no file in this repo is named `fleetops`; deleting the dormant emitter
   (there is none to delete yet) would leave `check.sh` green by construction, since no engine
   script sources anything under this spec.

## Known limits

- **Only SPEEDWARS is reproducible for a past run.** Only `docs/ops/speedwars.jsonl` (and now the
  per-run slice inside `bus_archive()`'s output) survives a busdir cycle; BOARD/FIREHOSE/AGENTS
  history for a finished run is not reconstructable from anything this spec ships. Stated up front
  in the PRD (Phase 4 footnote) — not a gap introduced here, but one this spec's archive does not
  close either.
- **The contract's join hit-rate is unmeasured, not assumed 100%.** `docs/ops/ledger-coverage.md`
  found only 52% of distinct run labels covered by even one `run-meta` row before the 2026-07-25
  run-label fix landed. A consumer joining on `run` against historical rows will see gaps; the
  contract says so rather than hiding it.
- **The emitter and both appliers are dormant.** Nothing in this spec's FRs exercises
  `sql/uni-schema.sql` against a live database outside `tests/uni-schema.bats`'s `:memory:` runs;
  "LIVE" in FR-5 describes the join-key *fields on the JSONL rows*, not a running SQL pipeline.
- **The D2 gate's decisions log is empty at publication** (`docs/ops/d2-gate.md`) — by design; a
  populated log before any real decision has changed would defeat the gate's own honesty.
- **Bus archives are best-effort, not a guaranteed backup.** "Never fatal" means a broken archive
  step degrades silently rather than failing a run — an operator who never checks
  `docs/ops/bus-archives/` for a given run has no other signal that its evidence didn't land there.

## Dependencies

**Internal:** spec 08 (the speedwars ledger and canonical fold FR-1/FR-5 both read, never
re-derive), spec 12 (`run_summary()`, the failure-class vocabulary `sql/uni-schema.sql` reproduces),
spec 17 FR-7 (`session_id`/`session_marker`/`account`, the join keys FR-5's contract documents).
**External:** `zstd` (optional, `gzip` fallback) for FR-3; `sqlite3` CLI for FR-5's test suite
(`tests/uni-schema.bats`); no new runtime dependency in the engine path.
**Phase order:** this spec is plan-004 phase 2. Phase 1 (spec 17) landed first and supplies FR-5's
join keys. Phase 3 (the mirror — reserved for spec 19 or an amendment here) is gated behind FR-6.

## Open questions — [NEEDS CLARIFICATION]

None outstanding for the scope this spec covers (the contract and the evidence surfaces that shipped
2026-07-26). The one structural question — whether the eventual mirror is spec 19 or an amendment to
this spec — is deliberately left open above ("Naming note") rather than guessed, since the answer
depends on how much phase-3 work the D2 gate ever authorizes.

## Resolutions

### 2026-07-26 — first consumer materialized, and it is not the emitter this contract describes

Recorded in `docs/fleetops-contract.md`'s own addendum (reproduced here as this spec's resolution,
since it changes an assumption the contract shipped with hours earlier): Robert's ruling on a
work-side refactor plan removed Brain from consideration entirely. The actual first consumer is the
reforge tooling database in a separate monorepo, and it ingests the **speedwars JSONL transport
directly** (line-sha256 idempotent landing into `bronze.speedwars_row`) rather than through this
contract's SQL emitter — the emitter and `mirror --push` stay dormant, exactly as FR-5's Non-Goal
already stated before this consumer had a name. This spec's contract cost nothing to have published
and needed no revision to remain accurate: `uni_run`/`uni_card`'s column semantics are the ones the
new consumer's `gold.run_wide`/`gold.card_wide` borrow, even though the transport it actually reads
is the JSONL, not this contract's SQL.
