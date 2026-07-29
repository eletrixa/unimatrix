# Spec 12 — Failure Evidence & the Self-Learning Loop

**Status:** Active (round-4 plan approved 2026-07-25: "check the feedback, suggest anything that
would increase observability + bug reporting so we have an even better self-learning loop")
**Date:** 2026-07-25
**Related specs:** 01 (finalize paths), 03 (loop), 08/09 (speedwars ledger), 10 (answer_unusable),
11 (succession evidence), 14 (**extends** FR-1's class vocabulary; reuses it as FR-7's marker
reason-token set)

---

## Overview

`_finalize_worker` is the one choke point that knows every branch's fate — id, lane, real worker
rc, and *why* it failed — the instant it happens. Today that knowledge degrades on the way out:
`answer_unusable` classifies three failure shapes internally and returns a bare 0/1; the `done/<id>`
record hardcodes `code:0`; outcomes land as free-text strings in a gitignored ledger; and nothing a
run learns survives into the feedback loop unless a human types it up. Spec 12 makes failure
evidence typed, aggregated, and self-filing: a controlled failure-class vocabulary, one
machine-readable `run-summary` record per run, auto-drafted `feedback/` stubs (`status: draft`,
human-confirmed, never auto-triaged), and the operator verbs to read it all back
(`swarm-ctl report | postmortem | review-stub`).

## Goals

- Zero-effort capture: failure class + run summary appear with no operator action, from signals
  the code already detects — no new detectors in this spec.
- Controlled vocabulary: every non-done branch outcome carries exactly one class from the table
  below; grep-able, join-able across runs.
- Self-filing loop: a run that parks, kills, or rejects work leaves a draft feedback item a human
  can confirm or delete — the drop-box protocol (`feedback/README.md`) gains a machine entry point
  without losing human triage.
- Scrub by construction: no generated record or stub ever embeds prompt text, answer text, or
  stderr content — ids, lanes, classes, counts, and paths only.

## Non-Goals

- No auto `verdict`/`run-review` speedwars rows — judge ≠ executor: the run driver must never
  classify its own branches as verified (spec 08 FR-5 unchanged; those rows stay
  orchestrator/operator-written).
- No cockpit failure tab — `swarm-ctl postmortem` is the surface for now; revisit if the terminal
  stops being where runs are driven.
- No stderr content aggregation — only a count (`stderr_n`); the files themselves are the drill-down
  (fetched web content / credential text must never propagate into evidence surfaces).
- No `stall` class — nothing detects stalls today except succession takeover; adding a detector is
  a separate spec (backlog 2).
- No code ever writes to `docs/research-backlog.md` or the skill's lessons ledger — judgment
  surfaces stay human.

## FR-1 — Failure-class vocabulary

Fixed set; every value maps 1:1 to a signal the code already detects:

| class | detected by | site |
|---|---|---|
| `auth-death` | `_auth_death_signature` hit; or mid-flight `lane_dead` at failover | swarm-lib `answer_unusable`; swarm-run failover path |
| `api-error` | last result event `is_error == true` | swarm-lib `answer_unusable` |
| `server-error` | 5xx/429/529/`overloaded_error` envelope regex | swarm-lib `answer_unusable` |
| `rate-limit` | `limit_error` rc 1 (lane not dead) or rc 2 | swarm-run failover path |
| `timeout-watchdog` | `limits/<id>.timedout` marker | swarm-run timeout path |
| `spawn-fail` | `wrc == 9` (lane_cmd refused) | swarm-run lane-unusable path |
| `false-done` | write-card diff gate reject | swarm-run reject path |
| `no-answer` | `extract_answer` failed / bounded same-lane retry | swarm-run fallthrough |
| `lane-down` | lane RAN but `served_model` empty at genuine failover (spec 13 FR-3) | swarm-run failover path |
| `parked-env` | pinned park in the blocked-pin wait paths | swarm-run pool wait paths |

**Extended 2026-07-25 by [spec 14](./14-write-cage-attribution.md):** `cage-denied` (FR-1) and
`write-target-missing` (FR-5) join this table — see spec 14 for their detection and sites, which are
specified there rather than duplicated here. Spec 14 FR-7 additionally reuses this vocabulary as the
**reason-token** set for `limits/` markers, adding four marker-only tokens (`chain-exhausted`,
`pinned-lane-blocked`, `session-limit`, and `write-target-empty` added 2026-07-29 via spec 14 FR-5
amendment) that describe a marker but do not change any row's `class`. There is one taxonomy; markers
and speedwars rows draw from it.

Every **park** is terminal for the gate, so it also emits a final `outcome:"parked"` row
carrying the class that caused it (round-4 MAJ: several pinned park paths previously wrote only
the `.parked` marker, or left a `timeout`/`retry` row as the branch's last row, so `parked_n`
and the bus disagreed). One helper (`_park_card`) owns the transition.

A `timeout-salvaged` branch has a done/ marker and therefore counts toward `done_n`; its done
record carries `"salvaged": true` so consumers reading markers rather than the ledger
(`write_verify_spec`) can treat it as higher-suspicion.

`answer_unusable` **echoes the matched class on stdout** on rc 0 (empty output on rc 1); its rc
contract is unchanged, callers capture via command substitution. `speed_row` gains an optional 7th
positional arg `class`, emitted as a `class` key using the absence-means-absent pattern
(`fallback_reason` precedent) — never an empty string in JSON. All six `_finalize_worker` call
sites pass their class; the failover site maps `lrc`/`lane_dead` → `auth-death` | `rate-limit`,
else the captured unusable class, else `no-answer`.

## FR-2 — Real rc in `done/<id>`

The done record's `code` field carries the real worker rc (`$wrc`), not hardcoded `0`. Consumers
(`ledger_row`, cockpit `server.mjs`) already read the record as arbitrary JSON.

## FR-3 — `run-summary` record

New `run_summary <busdir> <mode>` (swarm-lib, beside `speed_row`; shared `_speedwars_file` helper
extracted from `speed_row`'s file-resolution block — same no-op-without-evidence-surface doctrine).
One jq pass over this run's branch rows (`.type == null and .run == $run`), **last row per id
wins**, then one JSONL append (one `write(2)`):

```json
{"type":"run-summary","ts":"…","run":"…","mode":"full|verify",
 "branches":{"<id>":{"lane":"…","outcome":"…","class":"…?"}},
 "done_n":0,"parked_n":0,"fallback_hops":0,
 "lanes_limited":[],"lanes_dead":[],
 "wall_secs":0,"cost_usd":0,"stderr_n":0}
```

Ids/lanes/classes/numbers only — never prompt, answer, or stderr content. `lanes_limited`/
`lanes_dead` come from `limits/*.limited` / `*.dead` globs at call time; `fallback_hops` counts
branch rows carrying `fallback_reason`; `stderr_n` counts non-empty `run-*.jsonl.stderr`;
`cost_usd` sums the run's branch-row `cost_usd` fields; `wall_secs` = now − oldest branch-row `ts`
for the run (ledger-derived, no bus-birth stat dependency).

Call sites: `full_run` and `verify_run`, immediately **before** `_check_parked` (whose rc must
remain the run's rc), guarded by `SPEEDWARS_AUTO` + `2>/dev/null || true` like every ledger call.
`speedwars-report.sh` is unaffected (`.type == null` branch filter). The record contains nothing
commit-unsafe; the ledger stays gitignored by default, and an operator may repoint
`SPEEDWARS_FILE` at a tracked path — no code change.

## FR-4 — Auto-drafted feedback stubs

New `feedback_stubs <busdir> [extra-class …]` (swarm-lib), gated by conf key `FEEDBACK_AUTO`
(default `1`; added to `conf_load` keys + `swarm.conf.example`). Called from the same insertion
point as FR-3, and from `swarm-loop._halt` (after `HALTED.md` is written) with extra class
`loop-halted`.

- Classes, **one stub max per class per run**, detected from durable surfaces only:
  `parked` (`limits/*.parked`), `lane-down` (`limits/*.dead` or `*.broken`), `timeout`
  (`outcome=="timeout"` rows for this run), `unusable` (`outcome=="lane-unusable"` rows),
  `loop-halted` (passed by `_halt`).
- Filename `feedback/<YYYY-MM-DD>-<repo>-<run>-auto-<class>.md`, where repo = basename of
  `git rev-parse --show-toplevel` (fallback: busdir-parent basename) and run =
  `${SPEEDWARS_RUN:-$(basename $(dirname busdir))}` — the SAME derivation `speed_row`/`run_summary`
  use (corrected round 4: the busdir's own basename never matched the ledger's `run` field, so the
  ledger-driven `timeout`/`unusable` classes silently never fired on a default bus). Target dir override `FEEDBACK_DIR` (testability); default
  `<repo-root>/feedback`. Skip silently when the file already exists in `feedback/` **or**
  `feedback/archive/` — idempotent across re-invocation and the full→verify sequence.
- Frontmatter matches the drop-box schema (`source/date/run/type/severity`) **plus
  `status: draft`**; severity pre-filled by class (`major` for parked/lane-down/loop-halted,
  `minor` for timeout/unusable) — a pre-fill, never a triage.
- Body is a fixed template interpolating only: class, affected ids, lane names, counts, outcomes,
  and evidence *paths*, always **repo-relative** (`limits/`, `run-<id>.jsonl`, a ready-to-paste
  speedwars jq filter); `source:` is the repo NAME, not its absolute path. Stubs are tracked files
  in a public repo — `check.sh`'s PII gate scans `feedback/` for exactly this reason. The
  function never reads `res-*` / `run-*` / `prompt-*` content — scrub by construction.
- `feedback/README.md` gains draft semantics: a `status: draft` file is machine-drafted; the
  triager either confirms (delete the `status:` line, adjust severity/type, triage normally) or
  deletes the file (a draft is a nudge, not a commitment); drafts never count as pending and are
  never archived with `status: draft` intact.

## FR-5 — Operator surfaces

- `swarm-ctl report [file]` — exec `src/speedwars-report.sh` (its first wired caller).
- `swarm-ctl postmortem [run]` — pretty-print the newest `run-summary` row (or all rows for a
  named run) from the ledger; nonzero + message when none.
- `swarm-ctl review-stub [busdir]` — print (stdout only, writes nothing) a `run-reviews.md`
  skeleton with the mechanical fields pre-filled from ledger + bus: run label, date, card count,
  lanes used, wall clock, done/timeout/parked histogram, median wall per lane. Subjective sections
  left blank on purpose.
- Run-close checklist: after FR-3/FR-4 fire, `full_run`/`verify_run` print 4 checklist lines to
  stderr — run-reviews entry (`swarm-ctl review-stub`), backlog DONE sweep, distill
  `notes-lessons.md`, confirm `feedback/*-auto-*` drafts.

## FR-6 — Small durable-evidence fixes

- tmux `_board` renders a `DEAD LANES:` section from `limits/*.dead` (today only `.limited` and
  `.parked` show).
- Cockpit `auditLog` also appends each control-verb record to `<busdir>/audit.jsonl` (single
  append per record; the server is that file's sole writer — server.mjs's "never writes under
  BUSDIR" header constraint is amended to "owns exactly one append-only file" in the same change).
- `bus_init` seeds `notes-lessons.md` (3-line header) if absent — the orchestrator's per-run
  "observation → candidate lesson" notebook, blessed in the skill + `rules/unimatrix/`
  bus-discipline (orchestrator-only writer; workers never touch it).

## Amendment 2026-07-25 (backlog 49) — FR-D, `run-<id>.jsonl` rotation

Every retry attempt for an id spawns into the **same** `run-<id>.jsonl`, and `tee` truncates it
(`swarm-run.sh:431`). The prior attempt's stream — the only evidence of *why* the first attempt
failed — is destroyed by the attempt that replaces it. Backlog 49's report is literally "no stream
survived": three attempts, one log, and it belongs to the last one. Spec 01 FR-14 already flags
this as a known gap; this amendment closes it.

**Rotate before the `tee`.** Immediately ahead of the spawn at `swarm-run.sh:431`, move a
**non-empty** existing `run-<id>.jsonl` to `run-<id>.jsonl.<attempt>`, lowest unused `<attempt>`
starting at 1. Empty files are not rotated — a zero-byte log is not evidence (spec 14 FR-5), and
rotating it would only litter the bus.

**The suffix shape is load-bearing: `.jsonl.<n>` exactly.** Every consumer is
*extension-anchored*, so a rotated file must not end in `.jsonl`:

- `site/server.mjs` — `/^run-.*\.jsonl$/` at `:313`, `:496`, `:584`, `:956`
- `swarm-mon.sh` — `"$busdir"/run-*.jsonl` globs at `:125`, `:134`, `:154`
- `run_summary`'s `stderr_n` — `"$busdir"/run-*.jsonl.stderr` glob at `src/swarm-lib.sh:2114`

`run-<id>.jsonl.1` matches none of them, exactly as `run-<id>.jsonl.stderr` (the existing
precedent) matches none of them. A `run-<id>.<n>.jsonl` naming — the shape spec 01 FR-14's gap note
speculated about — would match all of them and make every rotated attempt appear in the cockpit as
a live worker. **No reader changes are needed, and none should be made:** every consumer hardcodes
the unsuffixed name.

**`.stderr` is deliberately not rotated.** `run-<id>.jsonl.stderr` is opened with `>>`
(`swarm-run.sh:431`) and has always accumulated across attempts; that is the correct behavior for a
diagnostic sidecar and it is worth a comment at the rotation site saying so, since the asymmetry
with the rotated stream looks like an oversight otherwise.

**Consumers of the rotated files:** none automatic. Feedback stubs (FR-4) and `postmortem` output
(FR-5) may cite `run-<id>.jsonl.<n>` as an evidence **path** — a path is not content, and the
scrub-by-construction rule is unaffected.

**Acceptance (amendment):** a fixture card that fails once and is retried leaves
`run-<id>.jsonl.1` holding attempt 1's bytes and `run-<id>.jsonl` holding attempt 2's only; a third
attempt produces `.jsonl.2`; a zero-byte log is not rotated; the rotated files match neither
`/^run-.*\.jsonl$/` nor a `run-*.jsonl` glob (asserted directly, so a future rename of the suffix
fails the test); `run-<id>.jsonl.stderr` contains **both** attempts' stderr.

## Acceptance criteria

1. `answer_unusable` echoes `api-error` / `auth-death` / `server-error` on rc 0, nothing on rc 1;
   existing rc-only tests stay green.
2. Every non-done `speed_row` written by `_finalize_worker` carries a `class` from FR-1's table;
   `done` rows carry none. jq-asserted in bats for timeout, spawn-fail, false-done, unusable,
   rate-limit, and parked paths.
3. `done/<id>` carries the real worker rc.
4. After a fixture `full_run`, the ledger's last row is a valid `run-summary` whose `branches`,
   `done_n`, `parked_n` match the bus; `_check_parked`'s rc still decides the run's rc; no record
   is written when no evidence surface exists.
5. A fixture run with a parked card + dead lane + timeout leaves exactly three `status: draft`
   stubs (one per class), idempotent on re-run; a canary string planted in `res-*.txt` /
   `run-*.jsonl` / stderr appears in **no** stub; stubs pass `check.sh`'s PII gate.
6. `swarm-ctl report`, `postmortem`, `review-stub` behave per FR-5 against a seeded ledger, and
   fail loudly (nonzero) when the ledger is absent.
7. `_board` shows dead lanes; `POST /api/ctl` appends one line to `audit.jsonl` containing verb +
   status and no request-body values.
8. `bus_init` seeds `notes-lessons.md` exactly once.

## Open questions

None outstanding.
