# Spec-10 build contract — exact signatures (W1 tests and W2 code MUST both follow this)

**Status: SHIPPED** as specs 10 (role classes) + 11 (succession).

Authoritative companion to specs/10-role-classes.md for the rolecls build. If this file and the
spec disagree, STOP and say so in your reply — do not improvise.

## New/changed swarm.conf keys (conf_load, src/swarm-lib.sh:77-119)
- keys array gains: CLASS_REVIEW CLASS_EXEC REVIEW_CHAIN PIN_WAIT_SEC
- Baked defaults: CLASS_REVIEW="codex kimi" · CLASS_EXEC="grok glm" · REVIEW_CHAIN="" ·
  PIN_WAIT_SEC=120
- Validation (runs after the env re-overlay, before export): every whitespace token in
  CLASS_REVIEW and CLASS_EXEC, and the bare-lane part (before ":") of every REVIEW_CHAIN token,
  must match ^(claude|codex|gemini|glm|grok|kimi)$. Violation: one stderr line naming the key and
  the bad token, then `return 1`. Empty/unset REVIEW_CHAIN is valid (means: derive from
  CLASS_REVIEW). Empty CLASS_* is a validation error.

## New lib helpers (src/swarm-lib.sh)
- `dead_flag <busdir> <lane>` — touch `<busdir>/limits/<lane>.dead` (no TTL content needed).
- `lane_dead <busdir> <lane>` — rc 0 iff the .dead flag file exists (existence only, NO TTL).
- `lane_blocked <busdir> <lane>` — rc 0 iff `limit_active` OR `lane_dead` OR
  (lane == kimi AND ! kimi_budget_ok).
- `_lane_family <bare_lane>` — echoes: claude|fable -> "anthropic"; any other input echoes
  itself (codex -> codex, glm -> glm, ...).
- `_judge_ok <candidate_bare> <author_bare>` — rc 0 iff ALL of: candidate != author;
  `_lane_family candidate` != `_lane_family author`; NOT (candidate == bare of $PLAN and
  $PLAN != fable); NOT (candidate == bare of $ORCHESTRATOR and $ORCHESTRATOR != fable).
  QUALIFICATION ONLY — availability (limited/dead/budget) is deliberately NOT checked here.
- `review_chain_for <author_bare> <busdir>` — echoes a space-separated `lane:model` chain.
  Source order: $REVIEW_CHAIN tokens if non-empty, else each CLASS_REVIEW member paired with
  `_verify_default_model <member>`. Filters by `_judge_ok <member> <author>` ONLY (availability
  is the pool's job at claim time). If the FIRST source member was dropped by _judge_ok, write
  `limits/.fbreason-<id>` is NOT this function's job (it takes no id) — the caller records it.
  Echoes empty string (rc 0) when nothing qualifies.
- `kimi_budget_ok <busdir>` — rc 0 iff BUDGET_USD unset/empty/0 OR the float in
  `limits/kimi.spend` (0 if absent) is strictly < BUDGET_USD. awk for float compare.
- `_kimi_spend_add <busdir> <id>` — parse the LAST result envelope in run-<id>.jsonl, recompute
  real $ at Moonshot list (same jq/pricing as speed_row's kimi branch: $3.00/M input uncached,
  $0.30/M cache-read, $15.00/M output), add to the float in `limits/kimi.spend` (create if
  absent). Single write via temp+mv or printf > (single-writer context: _finalize_worker).
- `answer_unusable <bare_lane> <busdir> <id>` — rc 0 = answer IS unusable (same polarity as
  limit_active). Checks res-<id>.txt text and/or the last result event of run-<id>.jsonl for:
  "OAuth session expired" · "Failed to authenticate" · "Not signed in" · "Please run /login"
  (case-insensitive, anchored substrings — NEVER bare "error"/"limit") · last result event has
  `is_error == true` · the whole answer text is itself an API-error envelope matching
  (API Error|"code":\s*5[0-9][0-9]|status.{0,10}(429|529)|overloaded) heuristics for the GLM
  5xx/429-body-as-answer class. TEXT signatures apply only when the combined answer text is
  <=600 chars (amended 2026-07-24 — live false-positive: a codex review QUOTING these strings
  was rejected 3x; every real false-done of this class is the error dump AS the whole answer);
  the envelope is_error check is unconditional. Healthy answers MUST pass (rc 1).
  grok stopReason:Cancelled is NOT a signature (appears on success).

## Chain seed resolution (chain_current + chain_advance, src/swarm-lib.sh:805-827)
Token-list source when no walk position exists yet: `limits/.chain-<id>` (existing position) ->
else `queue/<id>.chain` (NEW orchestrator-pin sidecar, space-separated lane:model) -> else
$EXEC_CHAIN. Guard reads with [[ -f ]]. chain_reset additionally `rm -f limits/<id>.waiting`.

## Pool changes (swarm-run.sh)
- `_try_claim_one` PINNED branch (queue/<id>.lane): lane blocked (`lane_blocked`) ->
  bounded wait: if `limits/<id>.waiting` absent: touch it + ONE stderr notice
  "swarm-run: <id> pinned to <lane> which is limited/dead — waiting up to <PIN_WAIT_SEC>s before parking";
  else if now - mtime(waiting) >= PIN_WAIT_SEC: rm waiting, stderr park line, touch
  limits/<id>.parked; in both cases `continue`. Lane NOT blocked: rm -f the waiting marker,
  claim normally.
- `_try_claim_one` CHAIN branch: skip on `lane_blocked` (not just limit_active); before each
  chain_advance caused by a blocked lane, record first-writer-wins
  `limits/.fbreason-<id>` = "<reason> <original_bare_lane>" where reason is one of
  limit|dead|budget-gated (pick by which check tripped) and original lane = the FIRST chain
  head for this id. Exhausted chain: loud stderr "chain exhausted — parked <id>" + existing park.
- `_spawn_worker`: when queue/<id>.write exists, `touch limits/<id>.stamp` immediately before
  invoking the lane command.
- `_finalize_worker` success branch, in order after extract_answer succeeds:
  (1) diff gate: if a .write target was set for <id> and `find <target> -newer limits/<id>.stamp
  -print -quit` is empty -> REJECT; (2) `answer_unusable <bare> <busdir> <id>` rc0 -> REJECT.
  A REJECT: rm res-<id>.txt, one stderr line naming the reason, then fall through to the
  EXISTING limit_error/retry block exactly as an extract_answer failure does today (no new
  outcome paths, requeue preserved). On ACCEPT: also rm -f queue/<id>.chain limits/<id>.waiting
  limits/<id>.stamp limits/<bare>.dead, and if bare == kimi run `_kimi_spend_add`.
- `_print_config_table`: one line per class, format exactly:
  `CLASS_REVIEW: codex(available) kimi(limited 4m)` — states: available | limited <N>m
  (ceil minutes remaining from flag mtime+TTL) | dead.

## limit_error new arms (src/swarm-lib.sh:671-801)
- The function must ALSO sniff the last result-event text for claude (an OAuth-death run has NO
  error/turn.failed event — it looks like a normal result whose text is the auth error).
- `claude)` arm: auth-death signatures (same list as answer_unusable) -> write
  limits/claude.limited.evidence-style evidence file (limits/claude.dead.evidence), `dead_flag`,
  rc 1. rate signatures (`rate_limit`/"usage limit"/429) -> codex-style 2-strike via
  limits/claude.strikes, then `limit_flag 18000`, rc 1 (first strike rc 2). Else rc 0.
- `gemini)` arm: quota/rate signatures (quota|resource_exhausted|rate limit|429|too many
  requests, case-insensitive) -> `limit_flag 18000` rc 1 (single-strike, grok-style). Auth
  signatures -> `dead_flag` rc 1. Else rc 0.
- Catch-all `*)` stays for genuinely unknown lanes.

## speed_row (src/swarm-lib.sh:1230-1304)
- Read `limits/.fbreason-<id>`; if present: field `fallback_reason` = first word; `requested`
  output = SECOND word (the original chain head, keeping requested:original vs served_lane:actual
  readable); then rm the file.
- New field `billing`: "real" when served lane == kimi, else "pool".
- Verdict rows (type:"verdict" — written by orchestrator tooling, not speed_row) gain
  `verify_lane`; in-engine, ANY speed_row emitted for a review/judge branch id (v-* or loop
  review ids) carries `verify_lane` = served bare lane.
- fallback_reason vocabulary: limit | dead | budget-gated | author-collision | role-collision |
  class-exhausted.

## swarm-loop.sh
- `_resolve_judge <configured_judge> <author_bare_or_empty>` replaces _check_judge_ne_exec's
  die-on-collision behavior at BOTH call sites (init + top-of-iterate). Both call sites run
  BEFORE the iteration's exec card, so author is empty there and only an EXEC_CHAIN collision
  can disqualify; per-card author-collision is enforced by review_chain_for at review-seed time
  (amended 2026-07-24 per r4rules review — the original sentence overpromised an iterate-time
  author pass). Substitute = FIRST CLASS_REVIEW member passing the same checks, one loud stderr
  line; `_die` only when none qualifies.
- `cmd_iterate` review block (:341-345): author = `jq -r .lane` from done/<exec_id>; chain =
  `review_chain_for <author> <busdir>` with the resolved judge moved to the chain head if it
  qualifies; write `specs/<review_id>.chain` (NOT .lane); if the configured judge was dropped,
  record `limits/.fbreason-<review_id>` = "author-collision <judge_bare>" (or role-collision).

## Test conventions (W1)
- Every new test title starts with `spec10 FR-Rn:`. Copy the existing patterns: chain-failover
  test at tests/swarm-run.bats:252-280, pinned-park at :330-351, retry-cap at :902-934.
- New fake knobs (fake.conf mechanism, run + loop fake copies): FAKE_CLAUDE_ONCE_MODE=autherr
  (+FAKE_CLAUDE_AUTH_TEXT default "OAuth session expired · Please run /login") — emits a NORMAL
  result envelope whose text is the auth error, exit 0; FAKE_CLAUDE_ERROR_JSON — emit the given
  event line verbatim then exit 1; FAKE_CLAUDE_USAGE_JSON — merge into the result event's usage;
  FAKE_GEMINI_ERROR — emit {"type":"error","message":"<text>"} then exit 1.
- Each new test must fail against CURRENT code for the RIGHT reason (asserting the new
  behavior/function), not incidentally. Timing tests: PIN_WAIT_SEC=2, timeout 20.
