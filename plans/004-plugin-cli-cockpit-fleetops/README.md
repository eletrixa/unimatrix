---
plan: 004-plugin-cli-cockpit-fleetops
status: active
owner: Robert
created: 2026-07-25
type: research
---

# Plan 004 — Plugin + Unified CLI + Online Cockpit (+ fleetops hook)

Architecture + PM dossier for packaging unimatrix as a Claude Code plugin, finishing the CLI,
adding durable cross-run reporting (evidence mirror), and refactoring the cockpit — while the
file-bus stays the only execution-path truth.

## Read order

| # | File | What |
|---|---|---|
| 1 | [synthesis.md](./synthesis.md) | Decided direction, D1-D3 open decisions, phase plan (5-min read) |
| 2 | [00-SYNTHESIS.md](./00-SYNTHESIS.md) | Architecture decision: matrix, recommendation, risks, first TDD steps |
| 3 | [PRD.md](./PRD.md) | Product requirements by phase, tripwires as acceptance criteria |
| 4 | [03-options.md](./03-options.md) | The 3 architecture candidates + diagrams |
| 5 | [04-steelman.md](./04-steelman.md) | Advocate/Prosecutor per candidate + rebuttals |
| 6 | [01-deep-dive.md](./01-deep-dive.md) | Research index: codebase facts + docs evidence |
| 7 | [02-case-studies.md](./02-case-studies.md) | Named real-world adopters per candidate |
| — | [brainstorm.md](./brainstorm.md) / [discovery.md](./discovery.md) / [pre-mortem.md](./pre-mortem.md) | PM stage (divergent / facts / failure analysis) |
| — | [evidence/](./evidence/) | Raw research dumps (rules-distilled, docs, experience, cases) |

`status: active` since 2026-07-25 — Robert delegated and the decisions are taken (00-SYNTHESIS
§Decisions): unimatrix stays outside the monorepo (sender/contract model); engine = both,
sequenced (SQLite live now, psql push wired-but-dormant, contract published first); gate honored;
directory marketplace first.

Placeholder legend (PII-scrubbed): `$BRAIN_ROOT` = the Brain monorepo checkout (work side);
`$DOMAIN_WORK` = the work-repos path prefix from `~/.config/unimatrix/config`; `<home>`/`<work>`
= literal home-dir / work-account placeholders in factual citations.
