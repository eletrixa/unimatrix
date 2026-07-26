---
source: brain
date: 2026-07-25
run: cockpit057b
type: friction
severity: major
triaged-to: backlog#44 backlog#45 backlog#46 backlog#47 backlog#48
---

Triage note: item 1 (cage-geometry doctrine) is doc-only — landed in
rules/unimatrix/model-lanes.md §Write-capable lanes + SKILL.md §3 (skill-ledger
2026-07-25). Items 3→44, 4→45, 5→46, 6→47, 2→48.

The claude/glm write cage (CWD = `.write` target + acceptEdits, env -i) denies READS outside the
target dir — a card whose `.write` sidecar points at a LEAF directory cannot read its own briefing
docs, the repo it ports from, or shared contracts. Headless deny = silent: workers soldier on and
finalize `done` with whatever they could build read-blind.

What happened (cockpit057b first launch, 18 cards): every `.write` was a leaf dir
(apps/brain-api/src/cockpit/value, packages/db, …). All 8 first-claim workers hit Read/Bash
denials on the rulings doc, parity manifest, and port sources. Outcome mix, all from ONE cause:
- 3 cards finalized done/0 with PARTIAL artifacts (a-llm built only the public-API-knowledge
  batch client and explicitly wrote "grant reads + re-run" in its answer — honest, but done/0);
- the spec-10 diff gate correctly rejected the pure no-write answers, walked chains
  (sonnet→opus), exhausted them, and PARKED 2 cards; driver exited INCOMPLETE.
The gate + unusable-answer machinery did its job — the plan-time cage geometry was the bug.

Recovery that worked (keep as doctrine): pause → kill claimed → re-point `.write` at the widest
dir the card may READ (repo root for trusted lanes; a subtree for external lanes) → mirror
out-of-repo read deps INTO the cage (gitignored `.cockpit-port/` copy of the Python sources +
goldens; anonymized spec docs copied inside the UI subtree) → append a CAGE NOTE to every prompt
("cage is wide; write discipline unchanged") → v2 completion cards for the partial dones
(keep-and-fix preamble) → clear `.chain-*` positions → relaunch. Silver lining: the external-lane
cage got STRONGER — grok's cwd subtree physically contains only anonymized spec + synthetic
fixtures, so the confidentiality boundary is now filesystem-enforced, not prompt-enforced.

Proposals:
1. §3 (Bus + env hygiene) rule: "`.write` = the widest tree the card must READ, not the narrowest
   it should write — write discipline is prompt + diff-gate + review; READ scope is the cage."
   Corollary: out-of-cage read deps get mirrored inside before launch.
2. Engine idea: a `<id>.read` sidecar (extra `--add-dir`-style read roots) would decouple read
   scope from write scope and make leaf write cages viable again.
3. Unusable-answer classifier idea: a done/0 answer whose text asks for permission grants
   ("grant reads on", "re-run the card") is a cage-failure signature — auto-flag it like the
   OAuth-expiry text class instead of trusting exit 0.

Evidence paths:
- .bus-cockpit057b/run-a-llm.jsonl (permission_denials: Read on rulings/manifest/contract)
- .bus-cockpit057b/res-a-llm.txt ("To unblock: grant reads on …")
- brain/plans/057-bet-cockpit-migration/execution-plan.md (original leaf-cage card table)

---

ADDENDUM (same run, later that night) — three more items:

4. **Shared-cage diff-gate blindness.** With multiple cards sharing one wide cage dir (the fix
   for item 1), sibling writes register as "change since spawn" for EVERY card in that dir — a
   grok zero-file false-done (a-ui-l2: 0 files, 240-byte narration) finalized done/0 because
   siblings had written meanwhile. Per-card artifact attribution needs a write-journal or
   manifest-diff (hash the card's OWN claimed deliverable paths at spawn + finalize), not a
   whole-dir mtime diff. Orchestrator per-card artifact checks were the real gate this run.

5. **Stale `.chain-<id>` position survives account-level 429 parks.** The claude lane hit a
   provider session limit (429 "You've hit your session limit"); both chain rungs burned in
   774ms each and the card parked. After the window reset, re-seeding the card did nothing —
   the driver read `limits/.chain-<id>` (rungs exhausted) and re-parked INSTANTLY without a
   spawn. Recovery: rm `limits/.chain-<id>` + `limits/<id>.parked`, relaunch. Proposal: an
   account-limit park (429 class) should TTL its chain-position marker like `<lane>.limited`,
   or the driver should reset chain position when the park marker is cleared.

6. **429-class instant rung burn.** Both rungs of a sonnet→opus chain burned on the SAME
   account-level 429 (same session pool) — chain failover assumes rung independence, but
   claude:sonnet and claude:opus share the account limit, so the walk is guaranteed futile.
   Proposal: on api_error_status 429 with "session limit" text, flag `claude.limited` (TTL to
   the reset time in the message) instead of consuming per-card chain rungs.

Evidence: .bus-cockpit057b/run-a-port-lenses2.jsonl (429 result record, duration_ms 774),
res-a-ui-l2.txt (zero-file narration), bus limits/ state after the 03:33 recovery sweep.
