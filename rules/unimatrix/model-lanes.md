---
applies-to: unimatrix worker spawning
---

# Model Lanes

Every spawned worker's environment is **child-only** — set on the subprocess invocation, never
exported globally into the orchestrator's own shell. Get this wrong and you either hijack Fable's
real Anthropic auth or bill the wrong account.

## GLM spawn contract (exact)

```bash
env -i PATH="$PATH" HOME="$scratch_home" LANG=C.UTF-8 \
    ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic \
    ANTHROPIC_AUTH_TOKEN="$Z_AI_CODING_KEY" \
    ANTHROPIC_DEFAULT_HAIKU_MODEL="$model" \
    ANTHROPIC_DEFAULT_SONNET_MODEL="$model" \
    ANTHROPIC_DEFAULT_OPUS_MODEL="$model" \
    API_TIMEOUT_MS=3000000 \
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
  claude -p --output-format stream-json --verbose "$prompt"
```

- **Starts from `env -i`, not a real env with `ANTHROPIC_API_KEY` subtracted.** `env -i` builds the
  child env from nothing, so `ANTHROPIC_API_KEY` (and everything else in the orchestrator's own
  shell) is structurally absent — never present to begin with, so there's nothing to `-u` away.
  Superseded, not violated.
- All three `ANTHROPIC_DEFAULT_*_MODEL` tier envs resolve to the **same** requested `$model` — a
  live E2E finding (2026-07-08) showed hardcoding distinct per-tier models (haiku=glm-4.7,
  sonnet/opus=glm-5.2) meant a `glm:glm-4.7` pin was silently served by glm-5.2 (whichever tier
  `claude -p` picked internally) — 3x quota billed instead of 1x. There is no documented `--model`
  path for the z.ai endpoint, so this tier-env trick is the only selector.

## Kimi spawn contract (exact)

Kimi (Moonshot) rides the `claude` binary with a child-env swap — the same mechanism as GLM,
pointed at Moonshot's Anthropic-compat PAYG endpoint:

```bash
env -i PATH="$PATH" HOME="$scratch_home" LANG=C.UTF-8 \
    ANTHROPIC_BASE_URL=https://api.moonshot.ai/anthropic \
    ANTHROPIC_AUTH_TOKEN="$MOONSHOT_API_KEY" \
    ANTHROPIC_DEFAULT_HAIKU_MODEL="$model" \
    ANTHROPIC_DEFAULT_SONNET_MODEL="$model" \
    ANTHROPIC_DEFAULT_OPUS_MODEL="$model" \
    API_TIMEOUT_MS=3000000 \
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
  claude -p --output-format stream-json --verbose "$prompt"
```

- **Same `env -i` cage and tier-env model selector as GLM.** The three
  `ANTHROPIC_DEFAULT_*_MODEL` envs are a claude-CLI-side selector (they choose which model NAME
  the CLI sends), so the trick is provider-agnostic — it works against any Anthropic-compat base
  URL, not just z.ai's.
- **Models:** `kimi-k3` (1M context, default) and `kimi-k2.7-code` (cheaper). Pin via the lane
  token (`kimi:kimi-k3`), same as GLM.
- **Write-capable** under an FR-15 sidecar: `--permission-mode acceptEdits` + `env -C <target>`,
  identical to the claude/GLM write contract (it IS the claude binary underneath).
- **Temperature quirk (do not "fix"):** Moonshot's Anthropic-compat endpoint rescales
  temperature — real temperature = requested × 0.6 (staff-corroborated). `claude -p` sends its
  own defaults and exposes no per-run temperature knob here, so there is nothing to configure —
  documented so nobody misreads determinism/creativity drift as a lane bug.
- **Billing is REAL dollars (PAYG), unlike glm/grok/codex pools.** List prices (kimi-k3):
  $3.00/M input, $0.30/M cache-hit, $15.00/M output. The envelope's `total_cost_usd` is computed
  by the claude CLI at Anthropic list prices against the swapped base URL — it is WRONG for this
  lane; the ledger recomputes from `.usage` × Moonshot list (see Ledger below).
- **Subscription variant (NOT live — signups paused as of 2026-07):** base URL
  `https://api.kimi.com/coding/` and the key rides `ANTHROPIC_API_KEY` (NOT
  `ANTHROPIC_AUTH_TOKEN`). If it ever becomes purchasable, that is the entire delta: two env
  lines in `lane_cmd`'s kimi branch. Its quota-exceeded 429 envelope carries
  `error.type == "exceeded_current_quota_error"` — already matched by the failover sniff below,
  so failover needs no change for the sub variant.

## Grok spawn contract (exact)

Read-only (default):

```bash
env -i PATH="$PATH" HOME="$scratch_home" LANG=C.UTF-8 \
  grok -p "$prompt" --output-format streaming-json --no-auto-update \
    $([[ -n "${GROK_EFFORT-medium}" ]] && echo --effort "${GROK_EFFORT-medium}") \
    --tools read_file,grep,list_dir --no-subagents \
    $([[ "$model" != default ]] && echo -m "$model")
```

Write-capable (FR-15 sidecar):

```bash
env -i PATH="$PATH" HOME="$scratch_home" LANG=C.UTF-8 \
  grok -p "$prompt" --output-format streaming-json --no-auto-update \
    $([[ -n "${GROK_EFFORT-medium}" ]] && echo --effort "${GROK_EFFORT-medium}") \
    --allow Write --allow Edit --allow Create \
    $([[ "$model" != default ]] && echo -m "$model")
```

This is the ratified contract as actually implemented (`src/swarm-lib.sh` ~:432-460) — it
intentionally diverges from a naive claude/GLM-style write contract; see the two bullets below for
why. Do not "correct" the implementation back toward `--permission-mode acceptEdits` — that was
tried and it breaks (see below).

- **Auth is an OAuth file, not an env key.** `~/.grok/auth.json` (mode 600) is copied into the
  caged scratch HOME, same shape as the claude-lane credential-copy — never exported, never baked
  into argv.
- **`config.toml` and `trusted_folders.toml` are deliberately NOT copied.** `config.toml` wires
  MCP servers — copying it would hand a spawned worker an MCP surface, breaking the zero-MCP
  containment gate every other lane already respects. `trusted_folders.toml` was probe-verified
  unnecessary (2026-07-19): a caged run in an untrusted scratch dir succeeded without it.
- Read-only form pins `--tools read_file,grep,list_dir --no-subagents` — read-only tool allowlist
  plus no subagent spawning, the same posture every lane has before an FR-15 sidecar grants write
  access.
- **Reasoning effort.** grok's own CLI default is `high` — 10-17s time-to-first-token per turn
  (2026-07-19 speed research). `GROK_EFFORT` defaults to `medium` (the speed default) and is
  passed as `--effort` on **both** the read-only and write-capable forms. Setting
  `GROK_EFFORT=` (empty) omits the flag entirely, restoring the CLI's own `high` default for hard
  tasks. Both the guard and the value use `${GROK_EFFORT-medium}` (**no colon**): `:-` substitutes
  on empty as well as unset, which made the guard unfalsifiable and the documented empty behaviour
  unreachable.
- **Write form uses `--allow Write --allow Edit --allow Create`, NOT `--permission-mode
  acceptEdits`.** This is a deliberate divergence from the claude/GLM write contract, not an
  oversight: `--permission-mode acceptEdits` silently dies with stopReason `"Cancelled"` on turn 1
  whenever `$HOME` is not the real OS home (probe-verified 2026-07-19) — the write-tool path hard-
  checks it, and every worker HOME here is a scratch/symlinked cage by design, so that mode is
  unusable for this lane. The explicit `--allow` rules bypass the check.
- **No path confinement on the `--allow` rules — this is the accepted ceiling, not a gap to close.**
  The grok CLI has no allowedTools path-glob syntax (`Write(/dir/**)`-style rule args are NOT
  supported — they match nothing and everything gets denied), so `--allow Write/Edit/Create` grants
  tool-level access with no per-path fence. Write workers on this lane are trusted to the
  OWNED-FILES list stated in their own spec prompt; Fable's file-level diff gate (reviewing the
  actual changed files before anything lands) is the backstop, not a CLI-enforced boundary.
  `--yolo` / `--dangerously-skip-permissions` / `--always-approve` (grok's own bypass-approval
  flag, however spelled) remain **forbidden outright** — containment gate, no exceptions.
- **Write-mode containment caveat (operator):** Because `--allow Write/Edit/Create` is tool-level
  with no path fence, containment relies on env -i cage + scratch HOME + prompt trust only.
  Do not hand grok write cards targeting directories with unrelated sensitive content or config.
  If the card's write scope and sensitive data must share a parent, prefer codex — it confines
  writes to the `-C <target>` directory natively, making it the safer lane for tightly-scoped
  writes where confidentiality matters.
  **Shared-cage detection ceiling (2026-07-29):** grok's stream carries no `tool_use` records
  (verified across honest AND false-done cards, grok CLI 0.2.103), so the spec 14 FR-8 per-card
  write-journal gate cannot cover this lane. The engine therefore REJECTS a grok write card whose
  cage is shared (live sibling sidecar or finished `write-*.txt` archive) unless it carries a
  `queue/<id>.files` manifest — plan manifests for shared-cage grok write cards, or give the card
  its own cage.
- `-m "$model"` is omitted when `model == default` (same convention as codex's `default`).
- CWD for the write form rides the generic `env -C <write_target>` logic already in `envbase`
  (`src/swarm-lib.sh` ~:293) — verify it still applies before relying on it blind on this lane-add.
- **Output is `streaming-json`, NDJSON, one event per line**: `{"type":"thought","data":"..."}`
  (reasoning chunks — discard), `{"type":"text","data":"..."}` (answer chunks), a final
  `{"type":"end","stopReason":"EndTurn","sessionId":"...","usage":{...},"total_cost_usd":...,
  "modelUsage":{...}}`. Failure is a `{"type":"error","message":"..."}` event plus a **nonzero
  exit**.
- **Answer = concatenation of `.data` over every `type=="text"` event, in order** — same
  delta-concat pattern as the gemini lane, not a single `.response` field.
- **Served model = the key(s) of `.modelUsage` on the last `type=="end"` event, never the
  requested `-m`.** Probe (2026-07-19): requested `grok-4.5`, served `grok-4.5-build` — the CLI
  silently aliases, same class of drift as gemini's `gemini-3-flash` → `gemini-3.5-flash`. Log the
  served key.
- **Cost may be legitimately absent — absence never means free.** `.total_cost_usd` on the `end`
  event is present only once the server has stamped it; per grok's own headless doc
  (`~/.grok/docs/user-guide/14-headless-mode.md`), the cost float is omitted when
  `cost_is_partial`/`usage_is_incomplete`, or generally on pool/OAuth paths until the server
  finalizes cost. Fallback when `.total_cost_usd` is missing: report token counts instead
  (`input_tokens` uncached + `cache_read_input_tokens` + `output_tokens`) with ledger wording
  `"cost omitted — OAuth pool-metered"` — never a bare `n/a` when usage is present.
- **Ledger `$` for grok are notional, not billed.** Grok Build CLI auth rides the SuperGrok weekly
  pool, metered per-account jointly across Grok chat/Build/API — a dollar figure here is a
  cost-equivalent estimate, not an invoice line item. Same spirit as GLM's
  prompts-consumed-not-dollars caveat, spelled out explicitly per the no-silent-spend rule.

## Failover detection

**GLM (Z.ai):** HTTP 429 with `error.code` in `{1308, 1310, 1316-1321, 1113}` → lane exhausted;
flip `.bus/limits/glm.limited` with TTL read from the error's `next_flush_time` (not a guessed 5h
window). Codes `{1302, 1305}` (rate/overload) → retry with backoff, do **not** fail over.

**Codex:** `error.code == "rate_limit_exceeded"` OR message contains "usage limit" →
candidate failover. **2-strike rule**: require two consecutive limit signals (or one retry after
the stated delay) before flipping `.bus/limits/codex.limited` — false 429s near subscription
window edges are a known codex behavior.

**Grok (xAI):** no observed 429 envelope yet (2026-07-19) — grok gets no dedicated code/field
parse. Falls through the generic pre-parse (`limit_error`'s last `type=="error"`/`turn.failed`
event, same extraction every lane shares): lowercase `.message` and match `rate limit` /
`usage limit` / `quota` / `too many requests` → flip `.bus/limits/grok.limited`, default TTL
`18000` (5h — no `next_flush_time`-equivalent field observed yet to read a real one from). Any
other error string → `return 0`, normal bounded retry (`MAX_LANE_RETRIES`), not a failover. This
is a placeholder heuristic, not a documented contract like GLM's numeric codes — refine the match
list and TTL the moment a real limit envelope is captured live.

**Kimi (Moonshot):** claude-shaped envelope, no z.ai-style numeric codes. Two signal classes,
matched on the last `type=="error"`/`turn.failed` event (same shared extraction):
quota/balance signatures (`exceeded_current_quota_error` in `error.type`/message, or an
insufficient-balance message, or any `quota` mention) → park immediately, TTL 18000 — these do
not self-heal inside a run. Plain rate signatures (`rate limit` / `too many requests` / `429`)
→ codex-style 2-strike, then a SHORT park (TTL 300): PAYG rate limits are per-minute RPM
windows, not 5h subscription windows — a 5h park on a funded live lane would be self-inflicted
downtime. Evidence file `limits/kimi.limited.evidence` mirrors GLM's. The insufficient-balance
string is UNVERIFIED live — an unmatched balance error degrades to normal bounded retry
(MAX_LANE_RETRIES) then park, which is safe.

## Review pair (codex ↔ kimi)

The verify wave's two workhorse judges are codex and kimi. Whichever one is the mapped verifier
for a branch and is currently limited hands review to the other — unless that would seat the
generator as its own judge, or both are limited, in which case the mapped verifier stays pinned
and the verify card parks loudly. This matters because a verify `.lane` sidecar is a hard pin —
pins never chain-switch — so without pair-aware fallback, one lane's usage window would silently
stall every review in the swarm rather than just its own generation work.

## Gemini

- `GEMINI_CLI_TRUST_WORKSPACE=true` is mandatory in every gemini worker env — headless runs
  otherwise exit 55 ("not running in a trusted directory").
- **Never bare `gemini --yolo`.** A gemini lane that needs write/tool access still goes through
  the containment rules (env scrub, sandboxed/network-restricted worker) before it runs unattended.
- Log the **served** model from `stats.models` keys, not the requested `-m` flag — gemini silently
  aliases (`gemini-3-flash` was observed served by `gemini-3.5-flash` in live smoke).

## Write-capable lanes (FR-15)

- A branch is write-capable only via a `.bus/specs/<id>.write` sidecar (one absolute target
  directory, mirrors the `.lane` pin sidecar's lifecycle). Absent sidecar → every lane stays
  read-only, exactly as before FR-15.
- claude/GLM/kimi: `--permission-mode acceptEdits`, never `--dangerously-skip-permissions` — the latter
  is forbidden outright, containment gate, no exceptions. The worker's CWD is `env -C <target>`
  (neither lane has a per-invocation cwd flag); `--add-dir` is not needed — live-verified 2026-07-08
  that the CWD itself is auto-trusted under `-p`.
- codex: native `-C <target> -s workspace-write` **only under a `.write` sidecar**; a plain card
  spawns `-s read-only` (backlog-32, 2026-07-24 — the REVIEW-default lane must never hold write
  capability against the busdir parent).
- **Manifest requirement for non-journal lanes:** All write-capable non-journal lanes (grok/codex;
  gemini excluded because it is not write-capable in v1) require a `queue/<id>.files` manifest when the
  write cage is shared (live sidecar or finished archive). Codex's native `-C` confinement scopes writes
  but does not journal them; the manifest gates false-done detection across all non-journal lanes, not
  just grok.
- gemini is **not** write-capable in v1 (web/research lane) — a write sidecar on a gemini branch
  is a loud refusal (`lane_cmd` returns 1), never a silent no-op.
- `/swarm-loop` is the only caller that sets this sidecar today, always pointing at that run's
  scratch git worktree (never `TARGET_DIR` itself when a worktree could be created).
- **Cage geometry (feedback: `2026-07-25-brain-leaf-write-cage-denies-briefing-reads.md`,
  archived).** `.write` is the READ cage, not the write fence — set it to the widest tree the
  card must READ; write discipline comes from the prompt, the diff gate, and the review wave,
  never from a narrow target. A leaf-dir target blinds the worker to its own briefing, and the
  deny is silent under `-p`. Corollary: out-of-cage read deps get mirrored inside the cage
  before launch (gitignored copy). External/untrusted lanes are the deliberate exception — a
  narrow cage there is filesystem-enforced confidentiality; copy its inputs in.

## Same-family audit residue

- `REVIEW=codex:default` is correctly cross-vendor against the `claude:opus` exec leg — that pair
  is fine. The residue is one layer up: **Fable (Claude) is the session that synthesizes and
  adjudicates** over opus-authored work, and Fable and opus are the same model family. Route
  pass/fail verdicts on opus-authored branches through codex's verdict, not Fable's own read of
  the diff — Fable synthesizes, it doesn't re-grade.
- GLM rides the `claude -p` binary (child-env swap, see above) but is genuinely different
  weights — z.ai's own models, not Anthropic's — so `claude:opus`-vs-`glm` pairs are real
  cross-family audits despite sharing a CLI.
- This is a **known limitation, documented not solved**: same-family LLM judges show measurable
  self-preference/family bias (arXiv 2508.06709). No mitigation is implemented beyond routing
  opus verdicts through codex; do not claim this gap is closed.

## Ledger — no silent spend

- Every spawned run gets a line in `docs/ops/llm-runs.md`: when, what, lane, and the **actual
  billed cost re-summed from the result envelope / `ccusage`** — never per-stream-event token
  counts, which inflate 3-8× (claude-code#6805).
- Log the lane that actually served the run, including any failover hop and why it fired.
- Kimi is the one PAYG lane: its ledger dollar figure is REAL spend, recomputed from the result
  envelope's `.usage` at Moonshot list prices — never the envelope's `total_cost_usd` (claude-CLI
  Anthropic pricing, wrong provider). Single-price assumption: rows price at kimi-k3 list even if
  kimi-k2.7-code served (over-reports; add a per-model table when that model sees real use).
- Bulk `call` runs (spec 15) may aggregate the global markdown row: per-spawn rows land in the bus-local ledger (`$BUSDIR/llm-runs.md`) and per-card usage lands in speedwars, so `docs/ops/llm-runs.md` gains exactly one aggregate row per call run. The bus-local detail is run-lifetime evidence; speedwars is the committed record.

## Least-privilege env

- Workers **never** `source $ENV_MASTER_FILE` — `grep` the individual key(s) a worker actually
  needs.
- Before any unattended spawn, scrub the secrets dir, `~/.aws`, `~/.ssh` from the worker's environment. This
  is mandatory before the first unattended run, not optional hardening.
