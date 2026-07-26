#!/usr/bin/env bats
# Pins the fleetops evidence contract (docs/fleetops-contract.md, sql/uni-schema.sql): the DDL
# applies clean to a plain `sqlite3` CLI, the golden-file emitter fixture applies on top of it with
# the row counts the contract promises (including the cross-worktree PK collision case), the primary
# key actually enforces uniqueness on a second apply, and the fixtures themselves stay PII-clean and
# prompt-free — same scrub-by-construction posture as tests/feedback-stubs.bats.
#
# Project: unimatrix — multi-model swarm orchestrator driven from Claude Code
# Module:  tests/uni-schema.bats
# Deps:    bats-core, sqlite3 CLI (skip-with-warning if absent), sql/uni-schema.sql,
#          tests/fixtures/uni-mirror/{run-close.jsonl,golden.sql}
# Tested:  n/a — this is the test file

setup() {
  if ! command -v sqlite3 >/dev/null 2>&1; then
    echo "# WARNING: sqlite3 CLI not installed — skipping uni-schema contract tests" >&3
    skip "sqlite3 CLI not installed"
  fi
  SCHEMA="$BATS_TEST_DIRNAME/../sql/uni-schema.sql"
  FIXDIR="$BATS_TEST_DIRNAME/fixtures/uni-mirror"
  GOLDEN="$FIXDIR/golden.sql"
  FIXTURE="$FIXDIR/run-close.jsonl"
}

# _apply <sql> — fresh :memory: DB, schema + golden fixture applied, then the caller's query.
_apply() {
  sqlite3 :memory: ".read $SCHEMA" ".read $GOLDEN" "$1"
}

@test "uni-schema: applies clean to a fresh :memory: db" {
  run sqlite3 :memory: ".read $SCHEMA"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "uni-schema: creates exactly the three uni_ tables" {
  run sqlite3 :memory: ".read $SCHEMA" "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name;"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'uni_card\nuni_event\nuni_run')" ]
}

@test "uni-schema: golden.sql applies cleanly on top of the schema" {
  run _apply "SELECT 1;"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "uni-schema: row counts match run-close.jsonl, including the cross-worktree pair" {
  run _apply "SELECT count(*) FROM uni_run;"
  [ "$output" = "1" ]

  run _apply "SELECT count(*) FROM uni_card;"
  [ "$output" = "4" ]

  run _apply "SELECT count(*) FROM uni_event;"
  [ "$output" = "2" ]

  # The cross-worktree case: run-close.jsonl carries two branch rows with the SAME (run, id) =
  # ('run-42', 'c1') but DIFFERENT busdir_realpath (alpha vs bravo worktrees) — the PK
  # (host, busdir_realpath, run, id, ts) must keep both as distinct rows, never collapse them.
  run _apply "SELECT count(*) FROM uni_card WHERE run = 'run-42' AND id = 'c1';"
  [ "$output" = "2" ]
  run _apply "SELECT count(DISTINCT busdir_realpath) FROM uni_card WHERE run = 'run-42' AND id = 'c1';"
  [ "$output" = "2" ]
}

@test "uni-schema: applying golden.sql twice fails (PK enforcement)" {
  run sqlite3 :memory: ".bail on" ".read $SCHEMA" ".read $GOLDEN" ".read $GOLDEN"
  [ "$status" -ne 0 ]
}

@test "uni-schema: uni_card.class rejects a value outside the current vocabulary" {
  run sqlite3 :memory: ".read $SCHEMA" "
    INSERT INTO uni_card
      (host, busdir_realpath, run, id, ts, outcome, pinned, billing, class, payload)
    VALUES
      ('h', '/data/example/x', 'r', 'c9', '2026-07-25T00:00:00Z', 'timeout', 0, 'pool',
       'not-a-real-class', '{}');
  "
  [ "$status" -ne 0 ]
}

@test "uni-schema: uni_card accepts a lane-down class with NULL billing (live ledger shape)" {
  # 11 live ledger rows carry class=lane-down (missing from the pre-fix CHECK list — spec 12 FR-1's
  # vocabulary plus spec 14's cage-denied/write-target-missing extension), and 226 of 914 live card
  # rows predate the billing field entirely (up to 2026-07-24T10:49Z) and so carry no billing at
  # all. Both must import clean.
  run sqlite3 :memory: ".read $SCHEMA" "
    INSERT INTO uni_card
      (host, busdir_realpath, run, id, ts, outcome, pinned, billing, class, payload)
    VALUES
      ('h', '/data/example/x', 'r', 'c10', '2026-07-19T18:35:04Z', 'timeout', 0, NULL,
       'lane-down', '{}');
    SELECT billing IS NULL, class FROM uni_card WHERE id = 'c10';
  "
  [ "$status" -eq 0 ]
  [ "$output" = "1|lane-down" ]
}

@test "uni-schema: uni_card.seq disambiguates a same-second retry that would otherwise collide the PK" {
  run sqlite3 :memory: ".read $SCHEMA" "
    INSERT INTO uni_card
      (host, busdir_realpath, run, id, ts, outcome, pinned, billing, payload, seq)
    VALUES
      ('h', '/data/example/x', 'r', 'c11', '2026-07-25T00:00:00Z', 'timeout', 0, 'pool', '{}', 0);
    INSERT INTO uni_card
      (host, busdir_realpath, run, id, ts, outcome, pinned, billing, payload, seq)
    VALUES
      ('h', '/data/example/x', 'r', 'c11', '2026-07-25T00:00:00Z', 'done', 0, 'pool', '{}', 1);
    SELECT count(*) FROM uni_card WHERE id = 'c11';
  "
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
}

@test "uni-schema: uni_run PK includes ts — a re-run of the same bus/label does not collide" {
  run sqlite3 :memory: ".read $SCHEMA" "
    INSERT INTO uni_run
      (host, busdir_realpath, run, ts, mode, payload)
    VALUES
      ('h', '/data/example/x', 'r', '2026-07-25T00:00:00Z', 'full', '{}');
    INSERT INTO uni_run
      (host, busdir_realpath, run, ts, mode, payload)
    VALUES
      ('h', '/data/example/x', 'r', '2026-07-25T01:00:00Z', 'full', '{}');
    SELECT count(*) FROM uni_run WHERE run = 'r';
  "
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
}

@test "uni-schema fixtures: no forbidden PII tokens in run-close.jsonl or golden.sql" {
  # Pull the live pattern out of check.sh itself (never duplicate it as a literal here — this file
  # lives under tests/, which check.sh's OWN gate scans, and the pattern's substrings ARE the
  # forbidden tokens; hardcoding it would make this test trip the very gate it asserts).
  local forbidden
  forbidden="$(sed -n "s/^[[:space:]]*FORBIDDEN_RE='\(.*\)'\$/\1/p" "$BATS_TEST_DIRNAME/../check.sh")"
  [ -n "$forbidden" ]
  run grep -inE "$forbidden" "$FIXTURE" "$GOLDEN"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "uni-schema fixtures: no 'prompt' JSON key in run-close.jsonl" {
  run grep -n '"prompt"' "$FIXTURE"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}
