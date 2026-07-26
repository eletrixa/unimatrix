-- golden.sql — the exact SQL the phase-3 emitter must produce for run-close.jsonl in this same
-- directory. Byte-for-byte pin: tests/uni-schema.bats applies this file over sql/uni-schema.sql
-- and asserts row counts, including the cross-worktree (run, id) collision case.
--
-- Project: unimatrix — multi-model agent-swarm orchestrator driven from Claude Code
-- Module:  tests/fixtures/uni-mirror/golden.sql
-- Deps:    sql/uni-schema.sql (applied first); sqlite3 CLI
-- Tested:  tests/uni-schema.bats
--
-- Key responsibilities:
-- - Pin the emitter contract: run-close.jsonl (JSONL in) -> this file (SQL out), byte-for-byte,
--   so a future phase-3 importer implementation has a golden file to match against.
--
-- Design constraints:
-- - One INSERT per source row. Column values map straight across; anything not promoted to a named
--   column lands in that row's `payload` (host/busdir_realpath/run/id/ts/type themselves never
--   appear a second time inside payload — they are already columns).
-- - The verdict and review rows (run-close.jsonl lines 6-7) land in uni_event verbatim ONLY. Folding
--   a correction row's `verified`/`reason` into the matching uni_card row (PRD 004 P3-FR4) is a
--   phase-3 importer behavior this pre-merge golden file does not yet exercise — uni_card.verified /
--   verify_reason are NULL here by design; add the fold (and a golden fixture for it) when phase 3
--   actually builds the importer, not before.

INSERT INTO uni_run
  (host, busdir_realpath, run, ts, mode, done_n, parked_n, fallback_hops, wall_secs, cost_usd,
   stderr_n, session_id, session_marker, account, payload)
VALUES
  ('host-a', '/data/example/alpha/.bus/run-42', 'run-42', '2026-07-25T00:00:00Z', 'full',
   2, 0, 0, 184.5, 0.0421, 1, 'sess-fixture-001', '🍄', 'acct-fixture',
   '{"branches":{"c1":{"lane":"claude","outcome":"done"},"c2":{"lane":"codex","outcome":"done"},"c3":{"lane":"grok","outcome":"timeout","class":"timeout-watchdog"}},"lanes_limited":[],"lanes_dead":["grok"]}');

INSERT INTO uni_card
  (host, busdir_realpath, run, id, ts, requested, served_lane, served_model, outcome, wrc, pinned,
   wall_secs, billing, class, verified, verify_reason, cost_usd, tokens_in, tokens_out, payload)
VALUES
  ('host-a', '/data/example/alpha/.bus/run-42', 'run-42', 'c1', '2026-07-25T00:00:01Z',
   'claude:sonnet', 'claude', 'claude-sonnet-5', 'done', 0, 0, 42, 'pool', NULL, NULL, NULL,
   0.0091, 1200, 340, '{"turns":3,"duration_ms":18400}');

INSERT INTO uni_card
  (host, busdir_realpath, run, id, ts, requested, served_lane, served_model, outcome, wrc, pinned,
   wall_secs, billing, class, verified, verify_reason, cost_usd, tokens_in, tokens_out, payload)
VALUES
  ('host-a', '/data/example/alpha/.bus/run-42', 'run-42', 'c2', '2026-07-25T00:00:02Z',
   'codex:gpt-5.1-codex', 'codex', 'gpt-5.1-codex', 'done', 0, 0, 57, 'pool', NULL, NULL, NULL,
   NULL, 980, 410, '{"turns":2}');

INSERT INTO uni_card
  (host, busdir_realpath, run, id, ts, requested, served_lane, served_model, outcome, wrc, pinned,
   wall_secs, billing, class, verified, verify_reason, cost_usd, tokens_in, tokens_out, payload)
VALUES
  ('host-a', '/data/example/alpha/.bus/run-42', 'run-42', 'c3', '2026-07-25T00:00:03Z',
   'grok:grok-4', 'grok', NULL, 'timeout', 124, 0, 900, 'pool', 'timeout-watchdog', NULL, NULL,
   NULL, NULL, NULL, '{}');

-- Cross-worktree collision: same (run, id) = ('run-42', 'c1') as the FIRST uni_card row above, but a
-- DIFFERENT busdir_realpath (a second worktree, "bravo" vs "alpha") — this is exactly the case
-- (host, busdir_realpath, run, id, ts) in the primary key exists to keep distinct (see
-- docs/fleetops-contract.md "Why busdir_realpath is load-bearing"). Must land as its OWN row.
INSERT INTO uni_card
  (host, busdir_realpath, run, id, ts, requested, served_lane, served_model, outcome, wrc, pinned,
   wall_secs, billing, class, verified, verify_reason, cost_usd, tokens_in, tokens_out, payload)
VALUES
  ('host-a', '/data/example/bravo/.bus/run-42', 'run-42', 'c1', '2026-07-25T00:05:01Z',
   'claude:opus', 'claude', 'claude-opus-4.1', 'done', 0, 0, 38, 'pool', NULL, NULL, NULL,
   0.021, 1100, 300, '{"turns":4}');

INSERT INTO uni_event (host, busdir_realpath, run, id, ts, type, payload)
VALUES
  ('host-a', '/data/example/alpha/.bus/run-42', 'run-42', 'c1', '2026-07-25T00:10:00Z', 'verdict',
   '{"verified":false,"reason":"gate-contradicted: no diff produced"}');

INSERT INTO uni_event (host, busdir_realpath, run, id, ts, type, payload)
VALUES
  ('host-a', '/data/example/alpha/.bus/run-42', 'run-42', NULL, '2026-07-25T00:11:00Z', 'review',
   '{"score":4,"tags":["fast","good-value"],"note":"steady lane, no rescues needed"}');
