# Plan 001 — Multi-Model Orchestration + Monitoring (UNIMATRIX)

**Status: SHIPPED (historical).** Built as specs 01-09; this folder is the original research record
— do not implement from it.

**Decision: build `/swarm`** — a Claude Code slash command that plans with Opus/Fable, decomposes via the built-in **deep-research** workflow, and fans work out to **headless worker CLIs** (`codex exec` / `gemini -p` / `claude -p`, + GLM once keyed). Results read from each CLI's **structured handoff file**, coordinated over a **JSONL file-bus on ext4**, watched from a **separate `tmux -L swarm` window** optionally fronted by **WezTerm** from Windows. **Zero MCP. Zero new dependency.**

Winner **a1** — *Headless spawn + JSONL bus + tmux/WezTerm tail cockpit* — score **8.18/10**, verify verdict *strong*, all 6 hard constraints satisfied, no fatal flaw.

## Read in this order
| Doc | What it is |
|-----|-----------|
| [`SYNTHESIS.md`](SYNTHESIS.md) | **One-page digest + re-review verdict**: a1 confirmed, 3 adjustments adopted (Fable decomposes directly; GLM smoke-first; a5 revisit trigger). Start here. |
| [`DECISIONS.md`](DECISIONS.md) | **Locked choices** (2026-07-08): 4-lane day-one, attended v1, Fable brain. Revised build order + the one blocking action (buy Z.ai key). |
| [`PRD.md`](PRD.md) | Winning solution, architecture diagram, `/swarm` UX, exact CLI invocations, GLM access path, build phases, risks, open questions (Q1-Q3 now answered in DECISIONS). |
| [`LOOP.md`](LOOP.md) | **`/swarm-loop` mode** — iterate until success criteria hold: criteria contract, oracle + codex review gate per iteration, stop rules (plateau/caps/oscillation). Synthesis of Cherny loops + Ralph + loop-engineer skill + your loop-engineering course notes. |
| [`SETTINGS.md`](SETTINGS.md) | **Agent/role settings** — `swarm.conf`, role defaults (Fable plan/orchestrate, codex review, Opus→GLM-5.2 exec fallback), reactive limit-flag mechanism. |
| [`decision-matrix.md`](decision-matrix.md) | All 10 finalists scored by 3 judges; why a1 beat a8/a9; when you'd pick a different one. |
| [`monitoring-runbook.md`](monitoring-runbook.md) | Concrete cockpit — tmux/WezTerm/starship panes, jq filters, copy-paste command sketches. |
| landscape brief | 14-facet landscape brief with sources (GLM/Codex/Gemini headless, orchestrators buy-vs-build, tmux vs WezTerm, WSL vs Windows). *(Raw research artifacts kept out of the public tree.)* |
| research artifacts | 30 ideas, 10-shortlist, adversarial/premortem, judge scores, verifications. *(Raw research artifacts kept out of the public tree.)* |
| [`../../docs/00-environment-facts.md`](../../docs/00-environment-facts.md) | Verified ground truth of the box. |
| [`../../docs/01-feasibility-tests.md`](../../docs/01-feasibility-tests.md) | **Live receipts** — all 3 workers run headless; WezTerm cli drives the Windows cockpit from WSL; tmux file-bus works. |

## How this was produced
47-agent research workflow (Landscape ×14 → Ideate ×10 angles = 30 candidates → Shortlist 10 → Steelman+Red-team+Premortem → 3-judge weighted matrix → Verify top 5 → Synthesis). 2.76M tokens, ~35 min. Plus live plumbing tests on the box.

## Immediate next step
Answer the **8 open questions** in `PRD.md §11` (esp. Q1 GLM-now-or-later, Q2 attended-vs-overnight). Then Phase 0 scaffolds `.claude/commands/swarm.md` + `swarm-run.sh` + the `.bus` tree. **No code has been written — this is research only, per the brief.**
**Correction (historical note):** that was true when written (2026-07-08); code was subsequently built from this research as specs 01-09 — see the status line at the top of this file.

## The one thing to remember
**Read the answer from the CLI's handoff file, never scrape the terminal.** That single choice makes delegation injection-safe, non-MCP, and immune to the send-keys/ANSI failure class that kills every tmux-orchestrator clone. Everything else is plumbing.
