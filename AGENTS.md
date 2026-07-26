# Agents

## Runtime lanes

Who `/swarm` and `/swarm-loop` spawn at runtime, per `plans/001-multimodel-orchestration/SETTINGS.md`.
Five worker lanes are wired: `claude`, `codex`, `gemini`, `glm`, `grok`.

| Role | Lane | Notes |
|------|------|-------|
| plan | orchestrator (in-session) | Never spawned — a spec routed to a worker outside plan/orchestrator is an error |
| orchestrator | in-session | Gate, adjudicate, steer loops, synthesize |
| review | `codex:default` | Reviewer lane must differ from executor lane, always |
| exec | `EXEC_CHAIN` in `swarm.conf` (default `claude:haiku codex:default`) | Ordered failover — reactive on 429/limit, not predictive |
| research/web | `gemini` | Long-context / grounding / >200K branches |
| verify | any lane ≠ the claim's generator | Cross-model verify wave — the one place heterogeneous models measurably cut correlated hallucination |

The default `EXEC_CHAIN="claude:haiku codex:default"` is stranger-safe: it only assumes the two most
commonly installed CLIs and the cheapest Claude model. Add `glm`/`grok`/heavier Claude models to the
chain once you've authed those lanes.

## Agent rules

- Work on `public` — the single working trunk; no `dev` branch, no feature branches (project
  override, see `CLAUDE.md` §Git). The old `main` branch is disjoint pre-release history: never
  commit to it.
- TDD: red → green → refactor ×2. **Refactor pass 1** = spec adherence. **Refactor pass 2** =
  rules adherence (`rules/unimatrix/*.md`).
- Update `CHANGELOG.md` and `docs/versions.md` at the end of every wave, in the same commit as the code.
- The orchestrator never writes implementation code — it plans, reviews, and adjudicates only; a
  builder lane writes the diff.
- Reviewer lane must differ from executor lane for every diff or claim it audits — no exceptions,
  even under time pressure.
