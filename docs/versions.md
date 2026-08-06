# Pinned versions

Single source of truth for tool/model pins. Update at the end of every wave that changes a pin,
then re-smoke per `01-feasibility-tests.md` §re-smoke. CHANGELOG.md records the bump.

## CLIs (verified 2026-07-19, drift re-smoke — PONG all 6 lanes: claude/codex/gemini/glm/grok/kimi, see `docs/ops/llm-runs.md`)

| Tool | Version | Channel | Re-smoke trigger |
|------|---------|---------|------------------|
| claude | 2.1.215 | native installer (`~/.local/bin`) | any upgrade — stream-json drift + GLM lane. 2.1.215 gotcha: the #67861 OAuth-conflict warning on the GLM lane now prints on **stdout** before the JSON (was stderr) — `extract_answer`'s `fromjson? // empty` is immune, but never pipe raw lane stdout straight into `jq` |
| codex | 0.146.0 | static musl binary at `~/.local/opt/codex-bin/codex` (symlinked from `~/.local/bin/codex`; replaced the Omarchy mise/npx shim, which died exit-127 inside the `env -i` cage — shim kept as `~/.local/bin/codex.mise-shim.bak`) | any upgrade — `--json` threads/turns schema is experimental; re-copy the static binary, don't restore the shim |
| gemini | 0.51.0 | `npm i -g @google/gemini-cli` (brew DEPRECATED) | any upgrade — envelope fields + trust gate. **Sandbox image rebuild owed**: `unimatrix-gemini-lane` is still `:0.49.0` — rebuild/retag to 0.51.0 + PONG round trip before the next `GEMINI_SANDBOX=docker` run |
| grok | 0.2.103 (stable) | xAI Grok Build CLI | any upgrade — streaming-json envelope drift; model retirement or a new silent alias (`grok-4.5` → `grok-4.5-build`) |
| bats | 1.14.0 | bats-core `install.sh ~/.local` (linuxbrew gone with the WSL box) | — |
| shellcheck | 0.11.0 | static binary in `~/.local/bin` | — |
| jq | 1.7 | system | — |
| tmux | 3.4 | system | — |
| bash | ≥5.1 required (`wait -n -p`) | system | — |

## FR-16 gemini sandbox image (opt-in, `GEMINI_SANDBOX=docker`)

| Image | Base | Built from | Re-smoke trigger |
|-------|------|-----------|-------------------|
| `unimatrix-gemini-lane:0.49.0` | `node:22-slim` | `docker/gemini-lane.Dockerfile` (`npm i -g @google/gemini-cli@0.49.0`) | any gemini-cli version bump (rebuild + retag to match) — `ghcr.io/google/gemini-cli:latest` (gemini's own `--sandbox` default image) is NOT publicly pullable (`denied` on anonymous pull, verified 2026-07-08), hence the custom image |

Live-verified 2026-07-08: `docker run --rm -i -e GEMINI_API_KEY=… -e GEMINI_CLI_TRUST_WORKSPACE=true
unimatrix-gemini-lane:0.49.0 gemini -m gemini-3-flash -o stream-json -p "reply with exactly: PONG"`
→ served gemini-3.5-flash (same aliasing as the unsandboxed lane), answer "PONG". Full round trip
through `swarm-run.sh` (pinned `gemini:gemini-3-flash` branch, `GEMINI_SANDBOX=docker`) confirmed:
`res-<id>.txt` normalized correctly, ledger row auto-appended (`docs/ops/llm-runs.md`).

**Amended 2026-07-12 (security):** the lane now forwards the contract env with a **bare `-e NAME`
allowlist** (`-e GEMINI_API_KEY -e GEMINI_CLI_TRUST_WORKSPACE`), with the values set in the caged
`env -i` docker-client env — identical container effect to the `-e NAME=value` form verified above
(bare `-e NAME` is standard docker env-forwarding), but the plaintext key no longer appears in
`docker`'s argv / `/proc/<pid>/cmdline`. Re-smoke the PONG round trip on the next gemini-cli bump.

## Lane model pins (see swarm.conf for runtime values)

| Lane | Model | Note |
|------|-------|------|
| claude exec | opus (current alias) | subscription; Sonnet/Haiku for cheaper tiers |
| claude verify | opus (`_verify_default_model`, same as exec) | cheaper tiers only via explicit `VERIFY_MAP` pin |
| kimi exec/verify | `kimi-k3` (cheaper: `kimi-k2.7-code`) | rides the claude binary via child-env swap (like GLM); real-$ PAYG — `PAYG_FALLBACK` + budget gates govern |
| codex review | default (no `-m`) = gpt-5.5 documented; confirm per run | gpt-5.6 exists (newest) |
| gemini web/long-ctx | `gemini-3-flash` (cheap) / `gemini-3-pro` (heavy) | **2.5-flash EOL 2026-10-16**; NOTE: `-m gemini-3-flash` was served by `gemini-3.5-flash` (silent aliasing, verified in smoke) |
| GLM exec fallback | `glm-5.2` (grind: `glm-4.7`) | via `ANTHROPIC_DEFAULT_*_MODEL` tier envs, per-process |
| grok exec | `grok-4.5` (requested) → served as `grok-4.5-build` | silent alias, probe-verified 2026-07-19; log the served key, not the requested one |

## Auth state

- claude: OAuth (subscription) — untouched by GLM swap (child-only env).
- codex: **ChatGPT OAuth** (`codex login status` → "Logged in using ChatGPT"; auth.json migrated from the WSL box 2026-08-04 — the earlier API-key mode note is obsolete).
- gemini: `GEMINI_API_KEY` env (AI Studio) + `GEMINI_CLI_TRUST_WORKSPACE=true`.
- GLM: `ANTHROPIC_AUTH_TOKEN` (child env only, `env -u ANTHROPIC_API_KEY`).
- grok: OAuth file `~/.grok/auth.json` (mode 600, copied into the caged scratch HOME) — not an env
  key; SuperGrok weekly pool, metered jointly across Grok chat/Build/API.
- kimi: `MOONSHOT_API_KEY` from env-master (child env only, same `env -u ANTHROPIC_API_KEY` swap as
  GLM) — real-dollar PAYG, the one lane with genuine marginal cost (`docs/lane-economics.md`).
