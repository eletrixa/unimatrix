# Settings — agent/role configuration for `/swarm` and `/swarm-loop`

Design spec (documentation phase — no code). How you set which model plays which role,
and what happens when a lane hits its limit.

## Roles

Four roles, not four models — a role maps to a `lane:model` pair and lanes can repeat.

| Role | What it does | Default |
|------|-------------|---------|
| **plan** | Decompose the goal, write specs, independence-check | **Fable** (in-session — this Claude Code session, no spawn) |
| **orchestrator** | Gate, adjudicate, steer loops, synthesize | **Fable** (in-session, same as plan) |
| **review** | Audit diffs/claims each wave or loop iteration; verify wave | **codex : gpt-newest** (whatever the installed codex defaults to — gpt-5.5 today; pin only if a run must be reproducible) |
| **exec** | Do the work: code, research grind, transformations | **claude : opus** while the subscription window has headroom → **glm : glm-5.2** when the limit hits |

Hard rule carried over from the PRD: **reviewer lane ≠ executor lane** for any claim/diff it audits.
The defaults satisfy this by construction (codex reviews what opus/glm produced).

## Config file — `swarm.conf` at the repo root

Bash-sourceable KEY=VALUE (the runner is bash; `source swarm.conf` is the whole parser —
no YAML/JSON library, no schema engine):

```bash
# roles — lane:model pairs. "fable" = in-session, never spawned.
PLAN=fable
ORCHESTRATOR=fable
REVIEW=codex:default            # default = codex's current newest (gpt-5.5 today)
EXEC_CHAIN="claude:opus glm:glm-5.2"   # try left to right; advance on rate/limit error

# loop + safety knobs (used by /swarm-loop, see LOOP.md)
MAX_ITERATIONS=10
BUDGET_USD=0                    # 0 = no cap (attended); set for unattended
FANOUT=4                        # xargs -P ceiling
LEASE_MIN=15                    # stale-lease reclaim threshold
```

**Precedence:** per-run flag → `swarm.conf` → baked-in defaults (the table above).
Per-run override examples: `/swarm --exec glm:glm-5.2 "<Q>"`, `/swarm-loop --review claude:sonnet …`.

`/swarm config` (subcommand) prints the resolved table — file values merged over defaults,
so what-will-actually-run is always one command away. `/swarm config exec glm:glm-5.2` edits
the file. That is the whole settings interface; no TUI, no wizard.

## Lane→invocation mapping (resolved at spawn time)

| Lane token | Spawns | Notes |
|-----------|--------|-------|
| `fable` | nothing — the current session | plan/orchestrator only; a spec routed to `fable` is an error |
| `claude:<m>` | `claude -p --model <m>` | subscription auth; `opus`/`sonnet` aliases resolve to current IDs |
| `codex:<m>` | `codex exec -m <m>` (`default` omits `-m`) | `OPENAI_API_KEY` |
| `gemini:<m>` | `gemini -p -m <m>` | `GEMINI_API_KEY` |
| `glm:<m>` | `claude -p` + child-only `ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic` | gated on `Z_AI_CODING_KEY`; absent key = lane skipped with a loud board flag |

## Fallback semantics — "Opus until the limit, then GLM"

Reactive, not predictive (usage APIs are unreliable; the error is the truth):

1. Worker exits with a rate/limit error (claude result envelope `error` subtype, HTTP 429, or the
   subscription-window message). The runner recognizes the limit signature, not generic failure —
   a normal task error must NOT silently switch models.
2. Runner touches `.bus/limits/<lane>.limited` (mtime = when) and **re-queues the same spec** on the
   next lane in `EXEC_CHAIN`. Answer still lands in the same `res-<id>.txt`; loop/gate logic unchanged.
3. While `<lane>.limited` is fresher than the window TTL (Anthropic 5h window → TTL 5h, checked via
   `find -mmin`), new exec specs skip straight to the fallback lane — no repeated banging on a closed door.
4. Flag expires by mtime → next exec spec tries the primary lane again. Recovery is automatic;
   no daemon, no timer, just `find` on a flag file. The BOARD pane shows active `.limited` flags,
   so a degraded run is visible, not silent.
5. Every fallback hop is a ledger line (lane switched, why, cost) — run evidence stays honest.

Same mechanism covers GLM quota (prompts-per-5h) — `glm.limited` falls back to the next chain
entry if one exists, else the spec parks in `queue/` and the board goes red.

## What deliberately does not exist

- No per-branch model auto-routing heuristics (a human or Fable picks lanes per spec; the config
  only sets defaults).
- No live usage polling / predictive switching — the 429 IS the detector.
- No settings UI beyond `/swarm config` — it's a 6-line file.
