---
source: atoda-copilot
date: 2026-07-24
run: atoda-toollock
type: friction
severity: minor
triaged-to: backlog#39
---

# BUDGET_USD=0 lets the fallback chain walk into kimi real-$ silently

What happened: card `R1-specadhere` (a multi-file "verify spec adherence and fix drift" card) failed grok ×3 retries and glm (lane-unusable), then claude ×3 retries, then attempted kimi — which was also lane-unusable but the attempt still billed **$0.2590749 real PAYG** (limits/kimi.spend) — before finally landing on codex. With `BUDGET_USD=0` (uncapped) there was no gate and no loud marker at claim time; the spend was only visible post-hoc in speedwars/ledger rows.

Expected: either (a) fallback INTO kimi requires explicit per-run opt-in even when BUDGET_USD=0, or (b) a loud `limits/` warn marker + board flag the moment a chain walk reaches a real-PAYG lane.

Evidence paths (no secrets): docs/ops/speedwars.jsonl (run=atoda-toollock, id=R1-specadhere rows), docs/ops/llm-runs.md (RUN SUMMARY atoda-toollock row), .bus-atoda-toollock/limits/.

Side observation from the same walk: "verify N files + fix drift" cards are audit-shaped prose-adjacent work — grok/glm fumbled them exactly as rules/unimatrix/model-lanes.md predicts for prose audits; consider a card-template hint that verify-scoped cards default to codex.
