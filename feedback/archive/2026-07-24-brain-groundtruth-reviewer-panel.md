---
source: brain
date: 2026-07-24
run: cockpit057-prep
type: idea
severity: minor
triaged-to: skill-ledger 2026-07-24
---

Review panels over DESIGN artifacts need at least one ground-truthing reviewer (greps the real
codebase/CI config) and one "paged engineer" (feasibility/perf) — taste-only critique panels miss
whole finding classes.

Evidence from plan 057's 3-reviewer panel over 5 design briefs (14 verified P0/P1 findings total):
- The "rules cop" reviewer live-grepped the actual CI ratchet regex (impeccable-lint.ts) and
  found 3 proposed components that would fail CI on FILE LOCATION alone; also ground-truthed a
  false claim about an existing page's auth shape. Doc-only review cannot catch either.
- The "paged engineer" reviewer caught a LIVE OS-triggered bug in a proposed token block
  (prefers-color-scheme dark pairs in a light-only product — would flip bands for any dark-OS
  viewer on day one), plus an award-headline feature with NO data contract behind it.
- The taste reviewer caught the cross-doc product fork and disclosure-model contradictions.
  Three DISJOINT unique-catch sets — same complementarity pattern as agentbench-008 lesson (d)
  and cal056 lesson (c), now confirmed on design-doc reviews, not just code reviews.

Proposal: extend §4 (Gates + review wave) — for design/prose builds, the review panel template is
taste critic + rules cop (must RUN greps against the target repo's real gates) + feasibility
engineer. Same judge≠executor rule applies.

Evidence paths:
- brain/plans/057-bet-cockpit-migration/design/15-review-design.md
- brain/plans/057-bet-cockpit-migration/design/15-review-rules.md
- brain/plans/057-bet-cockpit-migration/design/15-review-feasibility.md
