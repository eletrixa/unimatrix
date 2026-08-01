---
source: brain
date: 2026-07-29
run: pure064
type: friction
severity: minor
decision: apply-now (docs)
triaged-to: skill-ledger 2026-07-29
---

# Turbo cache on a shared worktree silently replays stale test results to reviewer seats

What happened: pure064's gate-RUNNER review seat ran the CI gate list in the run's shared
worktree. A plain `bun run test` replayed 17/17 CACHED turbo logs — including results
recorded before the seat had provisioned its database — and would have green-washed the
gate silently. The seat caught it and re-ran with `bunx turbo run test --force` (0 cached,
genuine). The orchestrator's own earlier gate run had primed the cache.

Expected: reviewer/gate guidance should pin `--force` (or `TURBO_FORCE=1`) for any
verification run on a bus/worktree where the orchestrator or workers already ran the same
turbo tasks.

Evidence: gate-RUNNER seat report in the pure064 run (brain repo,
<brain-repo checkout>); gate-notes.md §Gate facts. Suggest: add to the skill's
§4 gate guidance and/or the review-card template — "turbo-cached monorepos: verification
runs use --force; a cache replay is not a verification."
