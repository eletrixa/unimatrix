# Decisions — locked 2026-07-08

Authoritative deltas over `PRD.md §11` (open questions). PRD architecture unchanged; these fix the variables.

| # | Question | **Decision** | Consequence |
|---|----------|--------------|-------------|
| Q1 | GLM now or later? | **Buy the Z.ai key first — 4 lanes from day one.** | GLM moves **onto** the critical path. Phase 5 (GLM) folds into Phase 1. Building waits on the key (your action — see below). |
| Q2 | Autonomy for v1? | **Attended v1; overnight later.** | Phase 2 containment (completeness-gating + secret-scrub + sandboxed web worker) is **NOT a v1 blocker** — but is **mandatory the first time a run is unattended.** Don't run `/swarm` AFK until Phase 2 ships. |
| Q3 | Orchestrator brain? | **Fable.** | Fable does plan · independence-check · adjudicate · synthesize (persona/output-style over the same Anthropic auth). Opus stays available as a per-run override if a decomposition is unusually hard. |

## Revised build order (supersedes PRD §9 phase numbering)

| Phase | Milestone | Blocked on |
|-------|-----------|------------|
| **0** Scaffold | `.claude/commands/swarm.md` (invokes **Fable**) + `swarm-run.sh` skeleton + `.bus/{specs,queue,claimed,done}` on ext4 + pinned CLI versions + defensive `jq` filter. `/swarm` echoes a plan, builds the bus. | — (can start now) |
| **1** 4-lane MVP | Spawns **codex + gemini + claude + GLM** headless, answer from handoff file, `xargs -P` scheduler, single `tail` pane, Fable synthesizes from `.txt` handoffs. Attended, end-to-end. | **Z.ai key** (GLM lane) |
| **2** Completeness + containment | done-marker gating (block synthesis until all N report) + lease reaper; worker env scrubbed of `$ENV_MASTER_FILE`/`~/.aws`/`~/.ssh`; web worker sandboxed (docker present). **Required before the first unattended run.** | — |
| **3** Cockpit | `tmux -L swarm` board + firehose + `ccusage`, starship, WezTerm read-only attach. | — |
| **4** Deep-research wrap + cross-model verify + ledger | Fable invokes deep-research to decompose; verify wave routes each claim to a model ≠ its generator; per-lane cost logged to unimatrix run-evidence. | — |

## Decisions batch 2 — locked 2026-07-08 (later same day)

| # | Question | **Decision** | Consequence |
|---|----------|--------------|-------------|
| Q4 | Default role→model map | **Plan = Fable · Orchestrator = Fable · Review/audit = GPT newest (codex default, gpt-5.5 today) · Exec = Opus while subscription has headroom → GLM-5.2 when the limit hits.** | Settings interface specced in `SETTINGS.md`: `swarm.conf` (bash-sourceable), `EXEC_CHAIN="claude:opus glm:glm-5.2"`, reactive limit-fallback via `.bus/limits/<lane>.limited` flag files. `/swarm config` is the whole UI. |
| Q5 | Second operating mode | **`/swarm-loop`** — define success criteria, agents iterate until met. Fable orchestrates + plans, codex reviews every iteration, execution on the exec chain (GLM ideally / Opus / Sonnet). Design per Boris Cherny loop principles + the `loop-engineer` skill + your own loop-engineering course notes. | Specced in `LOOP.md`. Key imports: 5-tier verification ladder, judge ≠ executor iron rule, plateau + hard-cap stop rules, state read-before-run, measurement-lag scraper. |

Still documentation/research phase — **no code**.

## Batch 3 — build kickoff defaults (2026-07-08, build greenlit)

PRD §11 Q4–Q8 resolved by default (flag if wrong): **Q4** monitor = tmux + WezTerm read-only
outer window (runbook exists for both). **Q5** default fan-out `FANOUT=4`. **Q6** scratch git worktree
for code/edit branches, repo-root for research branches. **Q7** verify wave runs sync in attended v1
(Batch −50% revisited for overnight). **Q8** run-evidence surface = **`docs/ops/llm-runs.md`**.

Build-time roles: Fable = plan/orchestrate/review/audit only; Sonnet default builder, Haiku mechanical,
Opus escalation. TDD red→green→refactor×2 (specs pass, then rules pass). Main branch only.
Pre-build research: 4 agents; findings + authoritative PLAN DELTAS in `docs/02-build-pitfalls.md`
(claim-protocol fix, wait -n pool over xargs -P, npm gemini channel, GLM env contract, jq -u firehose).

## Your one blocking action — get the Z.ai (GLM) key

Nothing in `$ENV_MASTER_FILE` matches GLM/Zhipu/Z.ai/BigModel (re-verified). To unblock Phase 1:

1. **Buy** a Z.ai **Coding Plan** (Lite ~$18/mo is enough to validate; Pro if fan-out is wide) at the Z.ai / Zhipu open-platform console, mint an API key.
   - *Alt:* BigModel/Zhipu mainland open-platform (separate account + billing).
2. **Store it:** add `Z_AI_CODING_KEY=<key>` to `$ENV_MASTER_FILE`.
3. Tell me it's set — I'll wire the **child-only** env swap on the spawned GLM worker (never global, or it hijacks Fable's real Anthropic auth):
   ```bash
   env ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic \
       ANTHROPIC_AUTH_TOKEN="$Z_AI_CODING_KEY" \
     claude -p --output-format stream-json --verbose "$(cat .bus/specs/<id>.prompt)"
   ```
   - Endpoint discipline: Anthropic-compat base = `…/api/anthropic`. Pin cheap subtasks to **`glm-4.7`**; GLM-5.2 burns ~3× quota. Metering is **prompts-per-5h** → size fan-out to the tier.

**Until the key lands:** Phase 0 (scaffold) can proceed; Phase 1 runs **3-lane** as a stopgap and the GLM lane activates the moment `Z_AI_CODING_KEY` exists — no code change, just the env being present.
