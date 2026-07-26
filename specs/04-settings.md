# Settings — Roles, Lanes & Failover

**Status:** Active
**Date:** 2026-07-08
**Related specs:** [01-swarm-core](./01-swarm-core.md), [03-swarm-loop](./03-swarm-loop.md)

---

## Overview

How you configure which model plays which role in `/swarm` and `/swarm-loop`, and what
happens automatically when a lane hits its rate/usage limit mid-run. The whole interface is one
bash-sourceable file (`swarm.conf`) plus a `/swarm config` subcommand — no YAML/JSON schema
engine, no wizard, no TUI (`SETTINGS.md`).

## Goals

1. A single flat config file resolves four roles (plan/orchestrator/review/exec) to `lane:model`
   pairs, with per-run override.
2. Lane failover is reactive: the 429/limit error from the provider is the detector. No
   predictive usage polling.
3. `/swarm config` makes "what will actually run" one command away, always.

## Non-Goals

- No per-branch model auto-routing heuristics — a human or Fable picks lanes per spec; config
  only sets defaults.
- No live usage-polling / predictive switching.
- No settings UI beyond `/swarm config` — it's a 6-line file.

---

## Requirements

### `swarm.conf` keys

| Key | Purpose | Default |
|-----|---------|---------|
| `PLAN` | decomposition/spec-writing role | `fable` (in-session, never spawned) |
| `ORCHESTRATOR` | gate/adjudicate/steer/synthesize role | `fable` |
| `REVIEW` | audit/verify role, must ≠ exec lane | `codex:default` (installed codex's current newest — gpt-5.5 today) |
| `EXEC_CHAIN` | space-separated `lane:model` fallback chain, tried left→right on limit | `"claude:haiku codex:default"` (shipped stranger-safe default) |
| `MAX_ITERATIONS` | loop iteration cap (`03-swarm-loop.md`) | `10` |
| `BUDGET_USD` | loop/run budget cap; `0` = no cap | `0` |
| `FANOUT` | job-pool concurrency ceiling | `4` |
| `LEASE_MIN` | stale-lease reclaim threshold (minutes) | `15` |
| `WORKER_TIMEOUT_SEC` | per-worker wall-clock watchdog — kill a hung worker after this long (semantics: `01-swarm-core.md` FR-12) | `300` |
| `MAX_LANE_RETRIES` | consecutive unusable-answer retries per lane before failing over (FR-6 bound) | `3` |
| `VERIFY_MAP` | verify-wave rotation — space-separated `generator:verifier` pairs; judge ≠ executor always (codex↔kimi mutual fallback under FR-15) | `"claude:codex codex:kimi gemini:claude glm:codex grok:codex kimi:codex"` |
| `LEDGER_AUTO` | auto-append a `docs/ops/llm-runs.md` row on every successful branch finalize; `0` only for tests | `1` |
| `GEMINI_SANDBOX` | `docker` = containerized gemini lane, no host mounts; empty = unsandboxed (semantics: `01-swarm-core.md` FR-16) | empty (off) |
| `MON_PORT` | web cockpit port (semantics: `05-ground-control.md` FR-13) | `4747` |
| `MON_AUTOOPEN` | auto-ensure + auto-open the web cockpit on a bus's first swarm; `0` disables both (`05-ground-control.md` FR-13) | `1` |
| `PLAN_CHAIN` | PLAN-seat succession ladder — first token must be `fable` (semantics: `11-succession.md` §config) | `"fable codex kimi"` |
| `ORCH_CHAIN` | ORCHESTRATOR-seat succession ladder, walked by the takeover watchdog (`11-succession.md` §config) | `"fable kimi"` |
| `ORCH_TAKEOVER_MIN` | heartbeat staleness (minutes) before the watchdog seats a continuation driver (`11-succession.md` §config) | `20` |
| `GLM_MAX_THINKING_TOKENS` | cap GLM's `MAX_THINKING_TOKENS` (thinking-flood guard); `0` disables thinking outright | `6000` |
| `KIMI_MAX_THINKING_TOKENS` | cap kimi's `MAX_THINKING_TOKENS` (runaway thinking bills real $ at $15/M out) | `6000` |
| `GROK_EFFORT` | grok CLI reasoning effort; empty restores the CLI's own default (`high`) | `medium` |

Baked `conf_load` fallbacks and the shipped `swarm.conf` values are identical since spec 10's sync (2026-07-24) — `EXEC_CHAIN="claude:haiku codex:default"` and the six-pair `VERIFY_MAP` above. A future divergence is a bug, not a convention. Spec 10's four keys (`CLASS_REVIEW`, `CLASS_EXEC`, `REVIEW_CHAIN`, `PIN_WAIT_SEC`) are part of the same triplet but are specified in `specs/10-role-classes.md`'s own config table rather than duplicated here.

**Amended 2026-07-25 (backlog-31):** `GLM_MAX_THINKING_TOKENS`/`KIMI_MAX_THINKING_TOKENS`/
`GROK_EFFORT` are now `conf_load` keys (previously deliberately excluded, on the theory that
excluding them let an operator set them as bare env vars without conf_load's involvement). That
excluded them from FR-1's precedence machinery instead: a `swarm.conf` file value silently
clobbered an already-set env override (file beat env, backwards from FR-1), and the value was
never `export`ed, so it could be lost across a subprocess boundary (`swarm-loop.sh`'s per-iteration
fork of `swarm-run.sh`) unless the operator's own shell happened to export it. Root-caused while
investigating a GLM thinking-token flood report (`feedback/archive/2026-07-24-unimatrix-glm-thinking-flood-c3.md`):
the trace found the cap DOES reach every spawn's child env within a single live run (the value is
substituted into `LANE_ARGV` at build time, in-process, before any fork) — this fix closes a real
but narrower precedence/export gap, not the flood itself. The flood's likelier explanation:
`MAX_THINKING_TOKENS` bounds thinking per model turn, not cumulative across a long agentic
session's many turns — a C3 multi-file card can still rat-hole across turns with the cap correctly
applied on each one. Not fixable client-side beyond the existing mitigations (bench GLM to ≤C2
single-file cards at plan time; `WORKER_TIMEOUT_SEC` as the wall-clock backstop, which did fire in
the reported incident).

**Recommended full-lane order (2026-07-24, maintainer decision):** on a box with all lanes
configured, `EXEC_CHAIN="grok:grok-4.5 glm:glm-5.2 claude:haiku kimi:kimi-k3 codex:default"` —
grok first for code cards (fastest; its false-done class is now caught by the spec 10 FR-R11 diff
gate + classifier, 3/3 live-proven), kimi late (real PAYG $, `BUDGET_USD`-gated). The shipped
default stays stranger-safe (keyless lanes only). Prose/meta cards still pin `claude:sonnet` via
`<id>.lane`.

**Amendment 2026-07-25 (backlog 49) — FR-C, per-lane `TIMEOUT_<LANE>`.** One global
`WORKER_TIMEOUT_SEC` cannot fit six lanes: a codex review card routinely needs longer than the
default 300 s while a grok read card that has not answered in 300 s is hung, and the only knob today
raises the ceiling for everything at once. Six new conf keys — `TIMEOUT_CLAUDE`, `TIMEOUT_CODEX`,
`TIMEOUT_GEMINI`, `TIMEOUT_GLM`, `TIMEOUT_GROK`, `TIMEOUT_KIMI` — resolve per lane with
`WORKER_TIMEOUT_SEC` as the fallback.

| Key | Purpose | Default |
|-----|---------|---------|
| `TIMEOUT_<LANE>` (six keys, one per lane) | per-lane wall-clock watchdog override; falls back to `WORKER_TIMEOUT_SEC` when empty | **empty** |

- **Defaults are EMPTY — pure fallback.** `docs/larger-swarms.md:219-225` finding C3 suggests
  glm 1200 / codex 2400 / claude 1200 / grok 900, and those values ship in `swarm.conf.example` as
  **commented suggestions only**. Baking them would silently multiply the effective timeout 4-8×
  for every conf that relies on the 300 default — a behavior change nobody's conf asked for, on the
  one knob whose entire job is bounding runaway spend.
- **All six join `CONF_KEYS`** (`src/swarm-lib.sh:111-115`). Not optional: a key outside that array
  is excluded from `conf_load`'s capture-before-source / re-overlay-after-source dance, so a
  `swarm.conf` value silently clobbers an already-set env override (file beats env, backwards from
  FR-1) and never reaches `export "${keys[@]}"`, so it is lost across the
  `swarm-loop.sh` → `swarm-run.sh` fork. This is exactly the backlog-31 defect, documented in the
  comment at `src/swarm-lib.sh:154-165` — do not re-create it.
- **Positive-integer validation at `conf_load` for all six, and retrofitted onto
  `WORKER_TIMEOUT_SEC`.** A non-numeric `WORKER_TIMEOUT_SEC` today makes the watchdog's
  `sleep "$WORKER_TIMEOUT_SEC"` (`swarm-run.sh:409`) die instantly: the watchdog subshell exits
  before the `kill -0` guard, and hang protection is **silently disarmed** for the whole run. Empty
  stays valid for the six new keys (that is their default); empty is *not* valid for
  `WORKER_TIMEOUT_SEC`.
- **Resolved once, at the single enforcement site.** `_spawn_worker` computes
  `${!var:-$WORKER_TIMEOUT_SEC}` where `var="TIMEOUT_${bare^^}"`, and uses it for the watchdog
  `sleep` at `swarm-run.sh:409`. There is exactly one watchdog; there is exactly one resolution.
  Spec 01's amendment FR-A reap age cap consumes the **same resolved value** — a per-lane timeout
  that the reap cap does not know about would reap live long-running workers on that lane.
- **`swarm.conf.example` carries a kimi warning** beside `TIMEOUT_KIMI`: kimi is real-PAYG, so a
  long per-lane timeout widens the real-dollar exposure of every hung card on that lane, unlike the
  subscription lanes where a hung card costs only wall clock.

Precedence is FR-1's, unchanged: per-run env > `swarm.conf` > baked default (empty) > `WORKER_TIMEOUT_SEC`.

**Acceptance (amendment):** `TIMEOUT_GLM=1` kills a sleeping glm fake worker while a claude fake
under `WORKER_TIMEOUT_SEC=60` survives; unsetting `TIMEOUT_GLM` falls back to `WORKER_TIMEOUT_SEC`
for both; an env `TIMEOUT_CODEX` beats a `swarm.conf` `TIMEOUT_CODEX` (FR-1 precedence, the
backlog-31 regression guard); a non-numeric `TIMEOUT_CODEX` **or** `WORKER_TIMEOUT_SEC` dies loudly
at `conf_load`; `./swarm-run.sh config` lists all six keys (they are in `CONF_KEYS`, so the
resolved-config table renders them by construction).

**Validation (round3/backlog-27):** `conf_load`'s loud lane-token validation (spec 10 FR-R1)
also covers `EXEC_CHAIN` (must be non-empty; each token's bare-lane prefix must be one of the six
lanes), `REVIEW` (non-empty, bare prefix validated), and `VERIFY_MAP` (both sides of every
`generator:verifier` pair validated; empty map stays valid) — a malformed token dies at load, and
never reaches `lane_cmd`/`speed_row`.

### Functional

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-1 | Precedence: **per-run flag > `swarm.conf` > baked-in default** — resolved independently per key. | Must |
| FR-2 | `/swarm config` prints the fully resolved table (file values merged over defaults). `/swarm config <key> <value>` edits `swarm.conf` in place. | Must |
| FR-3 | Lane token resolution at spawn time (table below); a spec routed to `fable` is a hard error (plan/orchestrator only, never spawned). | Must |
| FR-4 | GLM model selection is via the three `ANTHROPIC_DEFAULT_*_MODEL` tier envs, per-process — **not** a `--model` flag (z.ai has no documented model flag path). | Must |
| FR-5 | Every GLM child spawn sets `env -u ANTHROPIC_API_KEY` — if both `ANTHROPIC_API_KEY` and `ANTHROPIC_AUTH_TOKEN` are set, the API key wins and either 401s against the swapped base URL or bills the wrong account. | Must |
| FR-6 | On a worker limit error, the runner touches `.bus/limits/<lane>.limited` (mtime = when) and re-queues the same spec on the next `EXEC_CHAIN` entry. A normal task error must **not** trigger a lane switch — only a recognized limit signature does; it retries the same lane, **bounded by `MAX_LANE_RETRIES`** (default 3 consecutive unusable-answer attempts, then chain-advance/park — never an unbounded same-lane respawn loop; the counter resets on a lane change or completion). *(Amended 2026-07-12: the bound.)* Under spec 10 (Active), chain-seed resolution is `limits/.chain-<id>` → `queue/<id>.chain` → `EXEC_CHAIN`. | Must |
| FR-7 | While `<lane>.limited` is fresher than its TTL, new specs for that lane skip straight to the fallback — no repeated banging on a closed door. TTL comes from the provider's own retry-after / `next_flush_time` when available, else a window default (Anthropic 5h). | Must |
| FR-8 | GLM failover codes: **fail over** on `1308` (window), `1310` (weekly/monthly), `1316`-`1321` (windowed variants), `1113` (no balance). **Retry with backoff, do not fail over** on `1302` (rate) / `1305` (overloaded). | Must |
| FR-9 | Codex failover requires **2 consecutive** `rate_limit_exceeded`/"usage limit" signals (or one retry after the stated delay) before flipping `codex.limited` — guards against known false 429s near window edges. | Must |
| FR-10 | If `EXEC_CHAIN` is exhausted (all lanes limited), the spec parks in `queue/` and the board goes red rather than silently dropping it. | Must |
| FR-11 | If `glm:*` is configured but `Z_AI_CODING_KEY` is absent, the lane is skipped **loudly** — a board flag, not a silent no-op. | Must |
| FR-12 | Every fallback hop is logged as a ledger line (lane switched, why, cost) — per the CLAUDE.md run-evidence rule. | Must |
| FR-13 | Kimi lane: `claude -p` + child-only `ANTHROPIC_BASE_URL=https://api.moonshot.ai/anthropic` + the same three tier-model envs as FR-4 (the selector is claude-CLI-side, provider-agnostic). Gated on `MOONSHOT_API_KEY` in the env master; absent key = loud skip (FR-11 parity). Write-capable under FR-15 exactly as claude/GLM. | Must |
| FR-14 | Kimi failover: quota/balance signatures (`exceeded_current_quota_error`, insufficient balance, `quota`) park the lane 5h immediately; plain 429/rate-limit signatures use the codex 2-strike rule then a SHORT 300s park (PAYG per-minute RPM window, not a subscription window). Ledger rows recompute real $ from envelope usage × Moonshot list prices ($3.00/M in, $0.30/M cache-hit, $15.00/M out for kimi-k3) — never the envelope's claude-priced `total_cost_usd`. | Must |
| FR-15 | **Review pair (codex ↔ kimi):** `verify_lane_for` takes an optional busdir arg; when the resolved verifier is one of `{codex, kimi}` and its `.limited` flag is active, review hands off to the other lane in the pair — unless that partner is the generator itself (judge != executor stays absolute) or the partner is also limited, in which case the mapped verifier is kept as-is and the pinned verify spec parks loudly (verify `.lane` sidecars are hard pins — they never chain-switch). `write_verify_spec` passes its busdir through so the written pin reflects the fallback. Default `VERIFY_MAP` pairs them: `codex:kimi` and `kimi:codex`. | Must |

**Role classes (spec 10, Active).** **Spec 10** (`specs/10-role-classes.md`) extends this failover model beyond `EXEC_CHAIN`. It introduces `CLASS_REVIEW`/`CLASS_EXEC` lane classes so every spawnable role has a same-class-first fallback (not just exec), a per-spec `queue/<id>.chain` orchestrator-pin sidecar that the existing `chain_*` primitives walk to give the pinned review/judge lane its own fallback, and a bounded pin-wait (`PIN_WAIT_SEC`, default 120s) that parks a pinned-but-limited spec loudly instead of waiting out the lane TTL. It also adds `claude`/`gemini` arms to `limit_error()` (previously both fell through the catch-all). See `specs/10-role-classes.md`.

### Lane→invocation mapping

| Lane token | Spawns | Notes |
|-----------|--------|-------|
| `fable` | nothing — the current session | plan/orchestrator only |
| `claude:<m>` | `claude -p --model <m>` | subscription auth; `opus`/`sonnet` aliases resolve to current IDs |
| `codex:<m>` | `codex exec -m <m>` (`default` omits `-m`) | `OPENAI_API_KEY`; one-time `codex login --with-api-key` required per box |
| `gemini:<m>` | `gemini -p -m <m>` + `GEMINI_CLI_TRUST_WORKSPACE=true` | `GEMINI_API_KEY`; explicit `-m` always (no `auto`) |
| `glm:<m>` | `claude -p` + child-only `ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic` + tier-model envs | gated on `Z_AI_CODING_KEY`; absent key = lane skipped with a loud board flag |
| `grok:<m>` | `grok -p --output-format streaming-json --tools read_file,grep,list_dir --no-subagents` (`-m <m>` omitted when `m == default`) | OAuth file `~/.grok/auth.json` (not an env key); read-only tool allowlist by default, `--permission-mode acceptEdits` under an FR-15 write sidecar |
| `kimi:<m>` | `claude -p` + child-only `ANTHROPIC_BASE_URL=https://api.moonshot.ai/anthropic` + tier-model envs | gated on `MOONSHOT_API_KEY`; PAYG (real $, ledger recomputes at Moonshot list); sub variant (api.kimi.com/coding/, `ANTHROPIC_API_KEY`) documented-only |

---

## Boundaries

- **Always**: resolve precedence independently per key (a per-run `--exec` flag shouldn't clobber
  a `swarm.conf` `REVIEW` value); `env -u ANTHROPIC_API_KEY` on every GLM spawn; log every
  fallback hop to the run-evidence ledger.
- **Ask first**: hardcoding a GLM model ID inline instead of `swarm.conf` (IDs rotate ~yearly —
  1-token ping before a batch run is the cheap check).
- **Never**: source `$ENV_MASTER_FILE` wholesale in a worker env — grep individual keys; treat a
  normal task error as a limit signal; poll for usage predictively.

---

## Acceptance Criteria

- [ ] **Resolution order test:** set a per-run flag for key A, a `swarm.conf` value for key B,
      rely on the baked default for key C — `/swarm config` shows flag-wins for A, file-wins for
      B, default for C.
- [ ] **Limit-flag flip + expiry test:** simulate a z.ai `1308` response with a `next_flush_time`
      — `.bus/limits/glm.limited` is created with that TTL; exec specs route to the next
      `EXEC_CHAIN` entry while fresh; once the flag's mtime ages past the TTL, the primary lane is
      tried again automatically (no daemon, just `find -mmin`).
- [ ] **GLM skipped-loudly test:** with `Z_AI_CODING_KEY` unset and `glm:*` configured in
      `EXEC_CHAIN`, a spec routed there produces a visible board flag, never a silent drop.
- [ ] **Retry-vs-failover test:** a `1302`/`1305` GLM response triggers backoff-retry on the same
      lane, not a chain hop; a `1308`/`1113` response triggers the hop.
- [ ] **Codex 2-strike test:** a single `rate_limit_exceeded` does not flip `codex.limited`; two
      consecutive ones (or one plus an honored retry delay) do.

**Verification commands:**
```bash
# Settings/precedence + failover behavior is covered in tests/swarm-lib.bats (conf_load, limit_*,
# chain_*) and tests/swarm-run.bats (EXEC_CHAIN failover, GLM/codex limit routing, config edit).
bats tests/swarm-lib.bats tests/swarm-run.bats
./swarm-run.sh config
```

---

## Open Questions

None.

---

## Dependencies

**Internal:** `plans/001-multimodel-orchestration/SETTINGS.md` (full spec — this file condenses
its tables), `plans/001-multimodel-orchestration/DECISIONS.md` (batch 2, Q4), `docs/02-build-pitfalls.md`
(GLM/codex failover codes), `01-swarm-core.md` (lane invocations this config resolves into).
**External:** `Z_AI_CODING_KEY` (GLM lane), `OPENAI_API_KEY`, `GEMINI_API_KEY`, `MOONSHOT_API_KEY` (kimi lane).
