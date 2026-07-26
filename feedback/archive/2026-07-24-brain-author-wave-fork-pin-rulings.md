---
source: brain
date: 2026-07-24
run: cockpit057-prep
type: idea
severity: major
triaged-to: skill-ledger 2026-07-24
---

Parallel author waves WILL fork on a shared contested decision — pin it as an orchestrator ruling
BEFORE the wave, or budget a reconcile pass.

What happened: plan 057 design prep ran 5 design-brief authors in parallel (IA, direction, motion,
copy, architecture). One open product decision (standalone route vs fold-into-existing-page) was
marked "[NEEDS ROB RULING]" by the IA author — but the architecture author silently resolved it
the OPPOSITE way and produced a fully-worked-out incompatible plan. Both reviews flagged it P0:
"two different products, not one." Cost: one full fix-wave card to rewrite the architecture brief.

What worked (the flip side, confirming cal056 lesson f): after Fable wrote a BINDING rulings doc
(design/README.md, rulings R1–R10) and pinned it as the fix-wave authority, two fix agents working
on different docs independently chose the IDENTICAL mechanism (`?iteration=` query param) for the
same ruling — zero reconciliation needed, zero ping-pong. Pinned ruling text ≈ deterministic
convergence; open questions ≈ guaranteed fork.

Proposal for §1 (Decompose): add a pre-author-wave step — enumerate every decision more than one
card could resolve differently; each one either gets an orchestrator ruling pinned into ALL
affected cards, or is explicitly assigned to exactly ONE card with the others told to treat it
as an unresolved input.

Evidence paths:
- brain/plans/057-bet-cockpit-migration/design/README.md (rulings doc)
- brain/plans/057-bet-cockpit-migration/design/15-review-rules.md (P0-1/P0-2)
- brain/plans/057-bet-cockpit-migration/design/15-review-design.md (P0-1)
