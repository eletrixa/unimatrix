-- uni-schema.sql — engine-portable DDL for the unimatrix fleetops evidence contract.
--
-- Project: unimatrix — multi-model agent-swarm orchestrator driven from Claude Code
-- Module:  sql/uni-schema.sql
-- Deps:    sqlite3 CLI (validated engine, `sqlite3 :memory: ".read sql/uni-schema.sql"`); the
--          Postgres variant is the phase-3 `unimatrix mirror --push` target and is not this file
-- Tested:  tests/uni-schema.bats
--
-- Key responsibilities:
-- - Define the three normative tables of the fleetops producer contract (docs/fleetops-contract.md,
--   this repo is the PRODUCER — see that doc for the transport, join-key, and privacy rules).
-- - Stay engine-portable with zero DDL churn as new spec rows appear: uni_ prefix, exactly 3 tables,
--   exactly one JSON payload column each (plans/004-plugin-cli-cockpit-fleetops/PRD.md §6).
--
-- Design constraints:
-- - DDL only. No DSN, no ATTACH, no engine-execution-path code lives here — the emitter that
--   produces INSERT statements against this shape, and the two appliers (sqlite3 CLI now, psql via
--   `unimatrix mirror --push` once dormant->live) are phase-3 concerns, not this file's.
-- - JSON payload columns are TEXT here — SQLite has no native JSON type; json_extract() works over
--   TEXT. The Postgres variant of this same DDL uses `jsonb` for those columns; that substitution is
--   the ONE branch the importer owns (PRD §6 "Engine-portable DDL notes") — nothing else changes.
-- - No views yet. Reporting views are a phase-4 cockpit concern, gated behind D2 (three weeks
--   elapsed AND >=2 real decisions changed by the phase-2 push summary — PRD §3 D2, §Phase 2).
--   Shipping a view against a contract the consumer hasn't even accepted yet (Status: PUBLISHED, see
--   docs/fleetops-contract.md) would spend effort on a report shape that can still change for free.
-- - Column names are kept honest against the real JSONL emitters: speed_row() and run_summary() in
--   src/swarm-lib.sh (read-only reference for this file — this file does not modify either).
--
-- Contract version: this DDL's shape is versioned in lockstep with docs/fleetops-contract.md's
-- "Contract version" header — bump both together, never one alone.
PRAGMA user_version = 10000;  -- contract 1.0.0 (MAJOR*10000+MINOR*100+PATCH)

-- host / busdir_realpath — LOAD-BEARING PK members on all three tables below, but NO current
-- producer (speed_row, run_summary) emits either: both are runtime-JSONL emitters with no
-- knowledge of the machine hostname or the bus dir's resolved path at write time. DECIDED
-- provenance (not this DDL's to implement, but pinned here so no importer improvises a different
-- answer): the phase-3 importer STAMPS both at import time, never reading them off the source
-- JSONL row —
--   host            <- the importing context (the hostname of the machine running the import)
--   busdir_realpath <- the run's archive, specifically docs/ops/bus-archives/<run>/MANIFEST.txt's
--                       `bus:` line (src/swarm-lib.sh bus_archive() — deliberately a BASENAME, not
--                       an absolute path, per that function's own privacy comment), combined with
--                       the archive's own directory context to produce a value that stays distinct
--                       per archived run. This is why the cross-worktree golden-fixture case (two
--                       different busdir_realpath values for the same run/id from "alpha" vs
--                       "bravo" worktrees) remains valid after this change: different archives
--                       still stamp different values, so the PK still needs both host AND
--                       busdir_realpath to stay unique — see docs/fleetops-contract.md's "Join
--                       keys" section for the full rationale.

-- uni_run — one row per run, sourced from run_summary(). session_id / session_marker / account are
-- the P1-FR7 join keys: LIVE since spec 17 FR-7 (_session_stamp, src/swarm-lib.sh) — every
-- run-summary row stamps them from CLAUDE_CODE_SESSION_ID / the mirrored statusline marker formula /
-- CLAUDE_ACCOUNT (fallback: basename of CLAUDE_CONFIG_DIR). session_marker is the statusline session
-- marker — a FROZEN external interface, read-only here and never extended for this contract. All
-- three stay nullable: the env can be absent (headless/older run), and rows written before spec 17
-- FR-7 landed carry no value for any of the three — null is a real, expected state, not a bug.
CREATE TABLE uni_run (
  host            TEXT    NOT NULL,  -- stamped by the phase-3 importer, not the JSONL row — see top-of-file note
  busdir_realpath TEXT    NOT NULL,  -- stamped by the phase-3 importer from the run's archive MANIFEST.txt — see top-of-file note
  run             TEXT    NOT NULL,  -- SPEEDWARS_RUN / run label
  ts              TEXT    NOT NULL,  -- ISO-8601 UTC timestamp of the run-summary row; part of the PK
                                      -- (below) so a re-run of the same bus under the same persisted
                                      -- run label produces a new row instead of colliding with the
                                      -- prior run-summary for that (host, busdir_realpath, run)
  mode            TEXT    NOT NULL CHECK (mode IN ('full', 'verify')),
  done_n          INTEGER NOT NULL DEFAULT 0,
  parked_n        INTEGER NOT NULL DEFAULT 0,
  fallback_hops   INTEGER NOT NULL DEFAULT 0,
  wall_secs       REAL    NOT NULL DEFAULT 0,
  cost_usd        REAL    NOT NULL DEFAULT 0,
  stderr_n        INTEGER NOT NULL DEFAULT 0,
  session_id      TEXT,               -- P1-FR7 join key; nullable pre-phase-1
  session_marker  TEXT,               -- P1-FR7 join key; nullable pre-phase-1 (frozen statusline marker)
  account         TEXT,               -- P1-FR7 join key; nullable pre-phase-1
  payload         TEXT    NOT NULL,   -- JSON (Postgres: jsonb): {branches:{}, lanes_limited:[], lanes_dead:[]}
  PRIMARY KEY (host, busdir_realpath, run, ts)
);

-- uni_card — one row per finalized branch, sourced from speed_row(). `class` is the CURRENT
-- failure-class vocabulary — spec 12 FR-1's original 10 values, EXTENDED 2026-07-25 by spec 14
-- FR-1 (`cage-denied`) and FR-5 (`write-target-missing`) — reproduced here as a CHECK constraint;
-- this is a living list, not "spec 12 FR-1 verbatim" any more, and must be re-checked against
-- specs/12-failure-evidence.md + specs/14-write-cage-attribution.md (and swarm-run.sh /
-- src/swarm-lib.sh, the actual emitters) whenever either spec's FR-1 table grows. NULL means "done"
-- (success carries no failure class — speed_row's own absence-means-absent pattern). `verified` /
-- `verify_reason` are folded in at import time from correction rows (spec 08 FR-5/FR-6 verdicts and
-- reviews, which land in uni_event) — speed_row itself never sets either column; that fold is a
-- phase-3 importer concern, not this DDL's.
CREATE TABLE uni_card (
  host            TEXT    NOT NULL,  -- stamped by the phase-3 importer, not the JSONL row — see top-of-file note
  busdir_realpath TEXT    NOT NULL,  -- stamped by the phase-3 importer from the run's archive MANIFEST.txt — see top-of-file note
  run             TEXT    NOT NULL,
  id              TEXT    NOT NULL,
  ts              TEXT    NOT NULL,  -- second-precision; see `seq` below for same-second disambiguation
  requested       TEXT,               -- "<lane>:<model>" as requested (post fbreason-override)
  served_lane     TEXT,               -- NULL for a parked card — never served by any lane
  served_model    TEXT,
  outcome         TEXT    NOT NULL,   -- e.g. done | parked | timeout | lane-unusable | ... (free text at source)
  wrc             INTEGER,            -- real worker rc
  pinned          INTEGER NOT NULL DEFAULT 0 CHECK (pinned IN (0, 1)),  -- SQLite boolean convention
  wall_secs       REAL,
  billing         TEXT    CHECK (billing IS NULL OR billing IN ('real', 'pool')),
                          -- nullable like session_id: speed_row's `billing` field is unconditional
                          -- TODAY, but 226 of 914 live card rows predate the code that added it
                          -- (every row up to 2026-07-24T10:49Z has no `billing` key at all) — NOT
                          -- NULL here would hard-fail importing that historical evidence for no gain.
  class           TEXT    CHECK (class IS NULL OR class IN (
                    'auth-death', 'api-error', 'server-error', 'rate-limit', 'timeout-watchdog',
                    'spawn-fail', 'false-done', 'no-answer', 'lane-down', 'parked-env',
                    'cage-denied', 'write-target-missing'
                  )),
  verified        INTEGER CHECK (verified IS NULL OR verified IN (0, 1)),  -- folded from correction rows (phase 3)
  verify_reason   TEXT,               -- folded from correction rows (phase 3)
  cost_usd        REAL,
  tokens_in       INTEGER,
  tokens_out      INTEGER,
  payload         TEXT    NOT NULL,   -- JSON (Postgres: jsonb): the remaining per-lane usage bucket, shape varies by lane
  seq             INTEGER NOT NULL DEFAULT 0,  -- importer-assigned monotonic counter per input JSONL
                                                -- line (NOT sourced from the row itself — speed_row
                                                -- has no concept of it). ts is second-precision, so a
                                                -- same-second retry of the same id would otherwise
                                                -- collide on the PK; consumers order by (ts, seq).
  PRIMARY KEY (host, busdir_realpath, run, id, ts, seq)
);

-- uni_event — everything else, verbatim: the escape valve so a new spec row type (verdict, review,
-- run-review, run-meta, feedback, ...) never requires a DDL change. `id` is nullable — some event
-- types carry no per-branch id. SQLite does not enforce NOT NULL on non-INTEGER PRIMARY KEY columns,
-- and treats each NULL as distinct in the PK's unique index, so multiple id-less event rows coexist
-- without colliding; Postgres has no such carve-out for a real PRIMARY KEY, so the phase-3 importer
-- owns either a NOT NULL sentinel value or a UNIQUE index in place of a literal PK on that engine —
-- not this DDL's problem to solve today.
CREATE TABLE uni_event (
  host            TEXT NOT NULL,  -- stamped by the phase-3 importer, not the JSONL row — see top-of-file note
  busdir_realpath TEXT NOT NULL,  -- stamped by the phase-3 importer from the run's archive MANIFEST.txt — see top-of-file note
  run             TEXT NOT NULL,
  id              TEXT,               -- nullable by design, see comment above
  ts              TEXT NOT NULL,
  type            TEXT NOT NULL,
  payload         TEXT NOT NULL,      -- JSON (Postgres: jsonb): the source row, verbatim
  seq             INTEGER NOT NULL DEFAULT 0,  -- same disambiguator as uni_card.seq — see that
                                                -- column's comment; consumers order by (ts, seq)
  PRIMARY KEY (host, busdir_realpath, run, id, ts, type, seq)
);
