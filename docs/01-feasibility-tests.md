# Unimatrix — Feasibility Tests (run live 2026-07-08)

These are **real runs on the development host**, not web claims. They prove the delegation + monitoring core works non-MCP before a line of the harness is written.

## A. Delegation — all three workers run headless & return parseable output ✅

| Worker | Exact command | Observed | Notes |
|--------|---------------|----------|-------|
| **Gemini** | `gemini -p "…" -m gemini-2.5-flash -o json --approval-mode yolo` | `{"session_id":…,"response":"PONG","stats":{"models":{"gemini-2.5-flash":{"tokens":{"input":9541,…}}}}}` exit 0 | JSON incl. token stats. `--approval-mode {yolo,auto_edit,plan}`. ~9.5k input tokens even for 1 word (loads context). |
| **Codex** | `codex exec --sandbox read-only --skip-git-repo-check "…"` | exit 0. Banner: `model: gpt-5.5, provider: openai, approval: never, sandbox: read-only` | **Default model now gpt-5.5.** Flags: `-m/--model`, `-s/--sandbox`, `-c key=val`, `--output-schema <jsonschema-file>` (structured final response), `--dangerously-bypass-approvals-and-sandbox`, `resume`, `review`. |
| **Claude** | `claude -p "…" --model claude-haiku-4-5-20251001 --output-format json` | `{"type":"result","result":"PONG","total_cost_usd":0.0313,"usage":{…}}` exit 0 | Per-call `total_cost_usd` + usage — best cost telemetry of the three. Also `--json-schema`, `--agents <json>`, `--output-format stream-json`. |

**Conclusion**: a Bash-spawned worker per model, capturing stdout JSON, fully satisfies non-MCP delegation. Each emits machine-readable results + token/cost stats a monitor can parse.

## B. Monitoring substrate ✅

### B1. File-bus (JSONL) + tmux — WSL-native
- Worker launched **as the pane's command** (not `send-keys`) appends JSONL to a shared bus file; a monitor pane runs `tail -F bus.jsonl`. Verified: 4 status events written & tailed.
- **Op-learnings**:
  - Launch workers as the pane command: `tmux new-session -d -s cockpit 'worker-cmd'` — robust.
  - **Avoid `send-keys` into an interactive shell** — did not render in this sandboxed pty. (Not needed anyway.)
  - The operator's `~/.tmux.conf` uses **pane-base-index / base-index = 1**; target panes by unambiguous `#{pane_id}` (`%0`, `%1`), not by `.0`.

### B2. WezTerm cross-boundary cockpit — the premium path ✅✅
From **inside WSL**, driving the **real Windows WezTerm** at `/mnt/c/Program Files/WezTerm/wezterm.exe`:
```
wezterm.exe cli list                       # sees your live panes (works from WSL!)
PANE=$(wezterm.exe cli spawn --new-window -- wsl.exe -e bash -lc '<worker>')
wezterm.exe cli get-text  --pane-id $PANE  # READ live worker output  -> got UNIMATRIX-PANE-ALIVE, worker-tick-1..3
wezterm.exe cli send-text --pane-id $PANE $'cmd\n'   # DRIVE the worker
wezterm.exe cli kill-pane --pane-id $PANE  # tear down
```
All verified end-to-end. **The WSL orchestrator can spawn worker panes into the Windows WezTerm, read their output, inject input, and kill them — entirely without MCP.** This is the standout finding: the monitoring "separate window" and the process manager can be the same WezTerm mux, scripted from WSL.

## C. Not yet testable
- **GLM**: no key on the box, CLI not installed. Access path (Z.ai Anthropic-compatible endpoint vs OpenAI-compatible vs claude-code-router) is a research output + a prerequisite before GLM can join the fleet.

## LLM run evidence (manual/offline test spend, per global rule)
| When | What | Lane | Billed |
|------|------|------|--------|
| 2026-07-08 | claude `-p` haiku PONG | Anthropic API (Claude Code session auth) | $0.0314 |
| 2026-07-08 | gemini flash PONG | Google AI Studio (`GEMINI_API_KEY`) | ~9.5k in / 44 out ≈ <$0.01 |
| 2026-07-08 | codex exec PONG | OpenAI (codex `~/.codex` auth, gpt-5.5) | negligible |
| — | Research workflow (~55 agents, Opus) | Spawned agents (this session) | metered to session |

Total ad-hoc test spend < **$0.05**.

## D. Phase-A re-smoke — fresh toolchain (2026-07-08, post-upgrade)

Upgrades: codex 0.142.5→**0.143.0** (npm), gemini 0.28.2→**0.49.0** (npm; brew formula deprecated,
uninstalled), claude 2.1.204 (already latest), bats 1.13.0 installed. All receipts from live runs.

| Lane | Command core | Result |
|------|--------------|--------|
| claude | `claude -p PONG --model claude-haiku-4-5-20251001 --output-format json` | exit 0, `result:"PONG"`, $0.0315 |
| codex | `codex exec --json --output-last-message <f> --sandbox read-only --skip-git-repo-check` | exit 0, last-message file `PONG`, events `thread.started/turn.started/item.completed/turn.completed`, usage `{input_tokens:13310, cached:10112, output:6}` |
| gemini | `gemini -p PONG -m gemini-3-flash -o json` (+`-o stream-json`) | exit 0, `response:"PONG"`, stats keys `{files,models,tools}`; stream events `init/message/result` |

**Live-discovered gotchas (beyond the research digests):**
1. **codex 0.143 auth**: 401 on `wss://api.openai.com/v1/responses` even with `OPENAI_API_KEY` exported.
   Fix: `printenv OPENAI_API_KEY | codex login --with-api-key` (the `--api-key` flag was removed).
   Auth persists in `~/.codex/auth.json` — do this once per box, re-check after codex upgrades.
2. **gemini 0.49 trust gate**: exit **55** `"not running in a trusted directory"` headless.
   Fix: `GEMINI_CLI_TRUST_WORKSPACE=true` in every gemini worker env (or `--skip-trust`).
3. **gemini model aliasing**: requested `-m gemini-3-flash`, stats show **`gemini-3.5-flash`** served it.
   Log the *served* model from `stats.models` keys, not the requested one.
4. **gemini fixed overhead** re-measured: ~8.5k input tokens on a trivial prompt (was ~7.9k on 0.28).
5. **gemini exit 41** = auth missing (undocumented alongside 0/1/42/53); error envelope still valid JSON
   on stdout with `error.code` — parseable.
6. Workers must grep individual keys out of `$ENV_MASTER_FILE`, never `source` the whole file —
   an env-master file can contain lines that aren't bash-sourceable, and per-key grep is also
   better for least-privilege env building.

## LLM run evidence — Phase A re-smoke
| When | What | Lane | Billed |
|------|------|------|--------|
| 2026-07-08 | claude haiku PONG re-smoke | Anthropic API (session auth) | $0.0315 |
| 2026-07-08 | codex PONG re-smoke ×3 (2 failed auth, 1 ok) | OpenAI API key (svc acct) | negligible (6 out tokens) |
| 2026-07-08 | gemini PONG re-smoke ×4 (2 failed, json+stream ok) | Google AI Studio | ~17k in / ~50 out ≈ <$0.01 |

## E. GLM lane — LIVE (2026-07-08, Phase B)

Key stored as `Z_AI_CODING_KEY` in `$ENV_MASTER_FILE` (grepped fresh per spawn). Worker env
contract (exact, from research + live-verified):

```bash
env -u ANTHROPIC_API_KEY \
  ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic \
  ANTHROPIC_AUTH_TOKEN="$Z_AI_CODING_KEY" \
  ANTHROPIC_DEFAULT_HAIKU_MODEL=glm-4.7 \
  ANTHROPIC_DEFAULT_SONNET_MODEL=glm-5.2 \
  ANTHROPIC_DEFAULT_OPUS_MODEL=glm-5.2 \
  API_TIMEOUT_MS=3000000 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
  claude -p "<prompt>" --model haiku|sonnet --output-format json|stream-json
```

| Test | Result |
|------|--------|
| glm-4.7 (haiku tier) PONG, `-p` json | exit 0, `result:"PONG"`, modelUsage `glm-4.7` (34k in/95 out) |
| glm-5.2 (sonnet tier) PONG | exit 0, `result:"PONG"`, modelUsage `["glm-5.2"]` |
| **Tool-use fidelity** (open unknown → CLOSED) | `Read probe.txt` via stream-json: well-formed `tool_use` block, correct file contents returned |
| OAuth-conflict warning (#67861) | stderr warning only ("connectors disabled") — does NOT block headless |

## LLM run evidence — Phase B GLM smoke
| When | What | Lane | Billed |
|------|------|------|--------|
| 2026-07-08 | GLM PONG ×2 + tool-use test | Z.ai Coding Plan (prompt-metered, Anthropic-compat) | 3 prompts of 5h window (Lite=80) |

## F. Drift re-smoke — 2026-07-19 (claude 2.1.204→2.1.215, codex 0.143.0→0.144.6, gemini 0.49.0→0.51.0)

| Lane | Command core | Result |
|------|--------------|--------|
| claude | `claude -p PONG --model claude-haiku-4-5-20251001 --output-format json` | exit 0, `result:"PONG"`, $0.0387 |
| codex | `codex exec --json --output-last-message <f> --sandbox read-only --skip-git-repo-check` | exit 0, last-message `PONG`, events `turn.started/item.completed/turn.completed`, usage `{input:14030, cached:9984, output:6}` |
| gemini | `gemini -p PONG -m gemini-3-flash -o json` | exit 0, `response:"PONG"`, served **gemini-3.5-flash** (aliasing unchanged) |
| GLM | child-env swap (§E contract), `--model sonnet` | exit 0, `result:"PONG"`, glm-5.2, $0.0204 notional |

Drift found: **claude 2.1.215 prints the #67861 OAuth-conflict warning on stdout** (was stderr)
before the JSON on the GLM lane. `extract_answer`'s `jq -R 'fromjson? // empty'` skips it —
no code change needed — but raw `lane | jq` pipes break; documented in `docs/versions.md`.
Not re-smoked: FR-16 docker image (still `:0.49.0` — rebuild owed before next sandboxed run);
grok (probe-verified same day, §versions.md).

Ledger rows: `docs/ops/llm-runs.md` (4 rows, 2026-07-19 drift re-smoke).
