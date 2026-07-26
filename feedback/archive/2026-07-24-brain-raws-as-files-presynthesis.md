---
source: brain
date: 2026-07-24
run: cockpit057-prep
type: idea
severity: minor
triaged-to: skill-ledger 2026-07-24
---

Land per-agent raw outputs as FILES before any synthesis stage — file paths beat context piping
for every downstream card.

What happened: plan 057 research swarm (14 parallel readers over a 3.1MB handoff zip + repo +
Asana) returned ~245KB of structured markdown. Orchestrator dumped each reader's raw output to
`research/raw/<key>.md` BEFORE spawning synthesis. Payoffs, all realized same-day:
- 4 synthesis agents addressed exactly the raws they needed by path (no token-expensive piping,
  no truncation);
- a later spike agent (bet-id crosswalk) cited raws by path;
- 14 design-prep agents hours later briefed themselves from the same files;
- the raws are committed, so next SESSION's agents get them free.

The bus already has this shape (res-<id>.txt) but session-side Workflow swarms return results
in-memory by default — the dump-to-files step is manual orchestrator discipline. Proposal: add
one line to §5 (Evidence) or §1: "multi-reader sweeps: persist each reader's return as
<plan>/research/raw/<key>.md before synthesis — downstream cards address raws by path."

Evidence paths:
- brain/plans/057-bet-cockpit-migration/research/raw/ (14 files)
- brain/plans/057-bet-cockpit-migration/research/06-betid-crosswalk.md (cites raws)
