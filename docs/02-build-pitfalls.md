# Build pitfalls — pre-execution research (2026-07-08)

Findings from 4 research agents run before the build started. Each section = one agent's verified
digest, distilled to what changes our implementation. Sources listed per section.

## PLAN DELTAS (what the research changes, authoritative)

1. **Claim protocol corrected (design bug):** `mv queue/<id> claimed/<id>` is NOT a race-safe claim —
   `mv` silently overwrites an existing dest, so two claimers can both think they won. Correct:
   **rename to a per-worker unique destination** (`mv queue/<id> claimed/<id>.<worker>`); the loser's
   `mv` fails ENOENT (source gone) — that failure IS the lost-race signal. Same guarantee alternatives:
   `mkdir` (EEXIST) or hardlink (EEXIST). Same-filesystem only.
2. **Scheduler: bash `wait -n` job pool, not `xargs -P`.** xargs doesn't forward INT/TERM to children.
   Pool runs in own process group, `trap 'kill 0' INT TERM EXIT`; requires **bash ≥ 5.1** (`wait -n -p`).
3. **Gemini install channel: npm** (`npm i -g @google/gemini-cli@0.49.0`); **brew formula deprecated** —
   uninstall brew's gemini-cli so the stale 0.28.2 binary can't shadow. Lane models: `gemini-3-flash` /
   `gemini-3-pro` (2.5-flash EOL 2026-10-16).
4. **GLM spawn contract:** `env -u ANTHROPIC_API_KEY` + `ANTHROPIC_AUTH_TOKEN` + tier-model envs
   (`ANTHROPIC_DEFAULT_*_MODEL`), `API_TIMEOUT_MS=3000000`. Failover on 429 + z.ai code
   {1308,1310,1316–1321,1113}; retry-only on {1302,1305}; TTL from `next_flush_time`.
5. **Codex:** flags unchanged; `--json` schema now threads/turns (re-map parser); adopt `--ephemeral`
   (batch workers) + `--profile` (per-lane pins); failover on `rate_limit_exceeded`/"usage limit" with
   **2-strike rule** (false 429s near window edges).
6. **Firehose pipeline buffering (exact):** `tail -n +1 -F .bus/run-*.jsonl | jq -u -c '…'` — `jq -u`
   is mandatory or the cockpit lags ~8KB; `stdbuf -oL` any extra stage; never `--debug` on gemini.
7. **Bus writes:** one JSONL record = one `write(2)` incl. `\n` (bash `echo >>` is fine). O_APPEND is
   atomic for regular-file appends (the 4096/PIPE_BUF limit is pipes-only). ext4 only, never NFS/9p.
8. **Lease reaper:** mtime TTL must be >> max job runtime, or slow-alive workers get robbed — workers
   `touch` their claim file as heartbeat; reaper keys on heartbeat age, not claim age.
9. **Tests:** bats-core pinned 1.11.x; PATH-shim fakes as primary mock (bats-mock for call-count
   assertions); **`3>&-` on every backgrounded spawn** (FD-3 inheritance = suite hang); kill+`wait` own
   pids in teardown; per-test bus in `$BATS_TEST_TMPDIR`; no `--jobs` until suite is race-clean.
10. **Script strictness:** `set -euo pipefail` + `shopt -s inherit_errexit`; never `local var=$(cmd)`
    (split declaration/assignment); guard tee/SIGPIPE consumers; shellcheck -x in CI.

**Live-verified additions (Phase-A smoke, beyond the research):**
11. **codex 0.143 needs one-time `printenv OPENAI_API_KEY | codex login --with-api-key`** — env var
    alone 401s on the new websocket Responses endpoint; `--api-key` flag removed.
12. **gemini 0.49 trust gate:** headless runs exit 55 without `GEMINI_CLI_TRUST_WORKSPACE=true` —
    bake into every gemini worker env. Exit 41 = missing auth (undocumented code; JSON error envelope
    still on stdout).
13. **gemini serves aliased models** (`-m gemini-3-flash` → served by `gemini-3.5-flash`) — ledger must
    log the served model from `stats.models`, not the requested flag.
14. **Never `source $ENV_MASTER_FILE`** — an env-master file can hold lines that break bash
    sourcing; grep individual keys per worker (least-privilege env anyway).
15. **bash 5.2.21 segfault (live-reproduced, step 1):** a process-group leader whose **EXIT** trap
    runs self-inclusive `kill 0` crashes bash outright (same with `set -m` or `setsid` groups).
    Use `trap 'kill 0' INT TERM` only — a clean pool exit (running==0) has nothing to mop up.
16. **`wait -n -p var` returns the reaped job's exit code** — under `set -e` an ordinary worker
    failure kills the whole pool unless the call is guarded (`wait -n -p pid || rc=$?`).
17. **`local a="$1" c="$a/x"` is unbound under `set -u` (live-reproduced, step 2):** a later
    assignment in the SAME `local` statement can't see an earlier one from that same statement —
    bash evaluates the right-hand sides before any of them become visible to each other. Split
    into two `local` statements instead. Not the same bug as PLAN DELTA #10 (`local var=$(cmd)`
    masking a command's exit code) — this one is a straight nounset failure, reproducible with
    `bash -c 'set -u; f(){ local a=$1 b=$a; }; f x'`.
18. **A failing command substitution trips `errexit` under `inherit_errexit` — in ANY assignment
    context, not just array-append (live-reproduced, step 2, twice — once via `kill_subtree`'s
    `pgrep -P`, once via a plain `var="$(stat ...)"` on a since-removed claim file):** `cmd`'s
    normal "nothing found" outcome (e.g. `pgrep -P` on a leaf process, `stat` on a gone-by-now
    file) is a nonzero exit that silently kills the whole function/script — no error printed, just
    stops, whether the assignment is `arr+=($(cmd))` or plain `var="$(cmd)"`. Guard every command
    substitution whose target might legitimately not exist with `$(cmd || true)`. Reproduce (either
    form): `bash -c 'set -euo pipefail; shopt -s inherit_errexit; f(){ local -a a=(); a+=($(pgrep -P 99999999)); echo reached; }; f'`
    or `bash -c 'set -euo pipefail; shopt -s inherit_errexit; f(){ local x; x="$(stat -c %i /nope 2>/dev/null)"; echo reached; }; f'`
    — neither prints `reached`.
19. **Multi-account `CLAUDE_CONFIG_DIR` (live-reproduced 2026-07-08, FR-15 review):** on a box
    running a multi-account claude setup, the orchestrator session exports `CLAUDE_CONFIG_DIR`
    pointing at the LIVE account — `~/.claude` can be a
    different/stale account whose token happens to still be valid at some moments and expired at
    others, so a build relying on it can pass one run and fail the next with no code change.
    `_scratch_home` (`src/swarm-lib.sh`) now sources claude credentials from
    `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json`; symptom of the bug this fixes: every
    caged claude exec `served by claude:<synthetic>`, handoff body "Not logged in · Please run
    /login", loop plateaus after `LOOP_PLATEAU` iterations with no real progress. Runs made under
    the un-fixed code may have silently billed the wrong account.

## GLM / Z.ai lane (research-glm)

Sources: docs.z.ai/devpack/tool/claude · docs.z.ai/api-reference/api-code · docs.z.ai/devpack/overview ·
support.claude.com/en/articles/12304248 · code.claude.com/docs/en/authentication · claude-code#67861 ·
hboon.com/using-z-ai-with-claude-code-for-cheaper/

**The worker env contract (exact):**
```bash
env -u ANTHROPIC_API_KEY \
    ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic \
    ANTHROPIC_AUTH_TOKEN="$Z_AI_CODING_KEY" \
    ANTHROPIC_DEFAULT_HAIKU_MODEL=glm-4.7 \
    ANTHROPIC_DEFAULT_SONNET_MODEL=glm-5.2 \
    ANTHROPIC_DEFAULT_OPUS_MODEL=glm-5.2 \
    API_TIMEOUT_MS=3000000 \
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
  claude -p ... 
```

1. **`ANTHROPIC_API_KEY` WINS over `AUTH_TOKEN` if both set** — sent as `x-api-key`, request goes to
   the swapped BASE_URL with the wrong header, or worse bills the Anthropic account. Our shell env has
   Anthropic keys exported → **every GLM spawn must `env -u ANTHROPIC_API_KEY`.** Highest-severity trap.
2. **Auth token header:** `ANTHROPIC_AUTH_TOKEN` → `Authorization: Bearer` — the one z.ai accepts.
3. **Model selection is via the three `ANTHROPIC_DEFAULT_*_MODEL` tier envs, per-process** — no
   documented `--model` path for z.ai. Live IDs (Jul 2026): `glm-4.7`, `glm-5.2`, `glm-5-turbo`
   (also seen: 4.6, 5, 5.1, 5v-turbo; `glm-5.2[1m]` = 1M-context variant). IDs rotate ~yearly —
   keep in `swarm.conf`, never hardcode; 1-token ping before batch runs.
4. **Quota = prompts (not tokens), 5h rolling window + weekly cap.** Lite 80/5h + 400/wk, Pro 400 + 2k,
   Max 1600 + 8k. One "prompt" ≈ a whole agent turn (15-20 invocations). **GLM-5.2 burns 3× peak /
   2× off-peak.** Budget by the multiplier.
5. **Limit detection for failover** — HTTP 429 with z.ai `error.code`:
   - **Fail over** (lane exhausted): `1308` (window limit), `1310` (weekly/monthly), `1316`–`1321`
     (windowed variants), `1113` (no balance). Message carries `next_flush_time` → schedule lane return
     (sets the `.bus/limits/glm.limited` TTL precisely instead of guessing 5h).
   - **Retry with backoff, do NOT fail over**: `1302` (request rate), `1305` (overloaded).
6. **Auth-conflict false warning (claude-code#67861):** third-party BASE_URL + existing claude.ai OAuth
   login can prompt interactively — in headless it can block. Workers run with a clean env; if auth
   errors appear, `/logout` + retry is the known fix.
7. **No native images** through the z.ai Anthropic endpoint (text/code only — fine for us).
8. **Slower turns**: set `API_TIMEOUT_MS=3000000` or long GLM turns abort.

Open unknowns: key format `{id}.{secret}` widely reported, unconfirmed officially (irrelevant — it's an
opaque string in AUTH_TOKEN); GLM tool-use fidelity in headless stream-json — smoke test with a
tool-using prompt (`claude -p "list files" --output-format stream-json`) and inspect tool_use blocks.

## gemini-cli 0.28.2 → 0.49.0 (research-gemini)

Sources: geminicli.com/docs/cli/{cli-reference,headless,model-routing} · github google-gemini/gemini-cli
v0.49.0 release + changelogs · formulae.brew.sh/formula/gemini-cli · npm @google/gemini-cli ·
issues #14921 #2946 #18816 #19592

**Verdict: flag surface survives; install channel and model IDs change.**

1. **Install via npm, NOT Homebrew.** Brew formula deprecated (disable date 2026-12-18, steers to
   antigravity-cli) and lags at 0.46.0. Pin: `npm i -g @google/gemini-cli@0.49.0`. *(Plan Phase A
   updated: was `brew upgrade gemini-cli`.)*
2. **Model EOL:** `gemini-2.5-flash`/`-pro` shut down **2026-10-16**. Lanes move to `gemini-3-flash`
   (cheap) / `gemini-3-pro` (heavy) / `gemini-3.5-flash` (GA, 1M ctx). Default is now `auto` routing —
   we always pass an explicit model. Precedence: `--model` > `GEMINI_MODEL` env > settings.json > auto.
3. **Unchanged:** `-p`, `-m`, `-o json|stream-json`, `--approval-mode yolo` (recommended form; `-y`
   deprecated — don't switch). `GEMINI_API_KEY` auth unchanged; gemini-3-* reachable on plain AI Studio key.
4. **stream-json event names now:** `init, message, tool_use, tool_result, error, result` — `result`
   carries aggregated stats + per-model token usage (**ready-made run-evidence ledger hook**). Re-map
   the defensive jq filter to these names.
5. **Keep `2>/dev/null` forever** — stderr leaks confirmed in 0.4x (#14921 OpenTelemetry shutdown line,
   #2946 ImportProcessor warnings). Never pass `--debug` in a JSON lane.
6. **Exit codes granular:** 0 ok, 1 general/API, **42 input error, 53 turn-limit** — runner may branch.
7. **Headless yolo regression (#18816/#19592):** tool-granting lanes can still prompt in 0.4x headless.
   Pure `-p … -o json` text calls unaffected. Smoke a tool-using call; if it hangs, that lane needs a
   pty workaround or different approval mode.
8. **~7900-token overhead figure is stale** — re-measure from `stats` on a real 0.49 call; nested
   `stats.*` field paths unpublished, dump one real call and diff before trusting the parser.

## codex CLI 0.142.5 → 0.143.x (research-codex)

Sources: developers.openai.com/codex/cli/{reference,noninteractive,config-reference,changelog} ·
github openai/codex rust-v0.143.0 (2026-07-08) · issues #15451 (closed 2026-04-03), #19816 (open),
#9135/#12299/#16909 (false 429s)

**Verdict: invocation survives unchanged; the `--json` event schema is the only re-verify item.**

1. **All our flags intact:** `--output-last-message/-o`, `-s workspace-write`, `-C`,
   `--skip-git-repo-check`, `-m`. `--json` now aliased `--experimental-json` (schema still experimental).
2. **Event schema is now threads/turns:** `thread.started`, `turn.started`, `turn.completed` (carries
   `usage:{input_tokens,cached_input_tokens,output_tokens}` — ledger hook), `turn.failed`, `error`,
   plus `item.*` (agent_message, command_execution, file_change, …). Re-map the jq filter; capture one
   live stream and diff first.
3. **#15451 FIXED** (synthetic `__codex_submit_result__` interceptor) — `--output-schema` now works with
   tools active. We still read `--output-last-message` as source of truth; schema optional. Caveat
   #19816 (open): without tools, schema constrains ALL assistant text — only use schema tools-active.
4. **NEW `--ephemeral`** — no session-file persistence; adopt for batch workers (less disk churn,
   cleaner parallel runs). NEW-ish `--profile` — pin model+reasoning+sandbox per lane in config.toml.
5. **Models mid-2026:** `gpt-5.5` (documented default), `gpt-5.6` newest, `gpt-5.4`, `gpt-5.3-codex`.
   Confirm actual default with a no-`-m` run. Reasoning: `model_reasoning_effort=minimal…xhigh`.
6. **Auth modes:** `chatgpt` (subscription, 5h+weekly windows) vs `api` (metered) — config
   `forced_login_method` (supersedes `preferred_auth_method`). Models not hard-gated by mode; billing differs.
7. **Limit detection for failover:** parse JSONL for `type=="error"` or `turn.failed`; fail over when
   `error.code=="rate_limit_exceeded"` OR message contains "usage limit"; honor "try again after N
   seconds". **Known false-positive 429s near window edges** (#9135 #12299 #16909) — require 2
   consecutive limit errors (or retry once after the stated delay) before flipping `.bus/limits/codex.limited`.
8. **0.143.x ships alphas frequently** — pin exact version in `docs/versions.md`; re-smoke on bump.

## bash TDD + file-queue mechanics (research-bash)

Sources: bats-core.readthedocs.io (writing-tests, usage) · bats-core#1020 #419 #524 ·
jasonkarns/bats-mock · shellspec.info/comparison · jvns.ca (pipe buffering) · pvk.ca (O_APPEND) ·
rcrowley.org (atomic unix ops) · mywiki.wooledge.org/BashFAQ/105 · veithen.io (signal propagation)

**Framework verdict: bats-core** (pin 1.11.x). shellspec = credible alternative, smaller mindshare;
shunit2 unsuitable.

**Testing the orchestrator (bats):**
- **FD-3 hang** is the #1 trap: any backgrounded child inheriting FD 3 blocks the whole suite —
  `worker 3>&- &` always. `run` can't wrap background commands (it waits).
- `BATS_TEST_TIMEOUT` doesn't kill `run`-spawned children (#1020) → teardown must
  `kill "$PID"; wait "$PID" || true`. Wrap readers in `timeout`.
- `run foo | jq` pipes run's result, not foo — use `bats_pipe` or assert on `$output`.
- `run -N` / `run !` for exit codes (bare `! cmd` doesn't trip errexit).
- Mocks: PATH-shim scripts in `$BATS_TEST_TMPDIR/bin` (primary — full control of exit codes/delays/
  streams); jasonkarns/bats-mock for call-plan assertions (`unstub` = the assertion; shell functions
  shadow binstubs — `unset -f` first).
- Tmpdirs: `$BATS_TEST_TMPDIR` per test (bus fixtures), `$BATS_FILE_TMPDIR` per file. Never hand-mktemp.
- `--jobs` needs GNU parallel; bus tests must be race-isolated before enabling.
- Streaming tests: separate parser from I/O loop; unit-test parser on fixture JSONL; loop tests use
  bounded input + sentinel + `timeout`, never race live `tail -F` timing.

**Queue mechanics:**
- Atomic claim = rename **to unique dest** (loser: ENOENT) / mkdir (EEXIST) / hardlink (EEXIST).
  Plain `mv` to a shared dest name overwrites — not a claim. Same-fs only.
- `xargs -P` ignores INT/TERM for children → bash job pool: own process group,
  `trap 'kill 0' INT TERM EXIT`, `wait -n -p` (bash ≥5.1), reap every pid (zombies).
- Background jobs ignore SIGINT by default — explicit trap + group kill, not Ctrl-C hope.
- Stale leases: heartbeat-touch pattern (worker touches claim file; reaper on heartbeat age).
  flock only for coordinator/summary-file serialization — never held across a job.
- `set -e` blind spots: conditions, `&&/||`, `!`, command substitution (→ `shopt -s inherit_errexit`),
  `local var=$(…)` masks failure. `pipefail`+`tee`: early-exit consumer → SIGPIPE 141, guard it.
- O_APPEND appends are syscall-atomic on regular files (~2GB practical limit — PIPE_BUF 4096 rule is
  pipes only); the real risk is userspace flush splitting a record: **one line = one write().**
- Buffering: `tail -n +1 -F` (fine as-is) → `jq -u -c` (mandatory) → `stdbuf -oL` extra stages;
  per-tool flags (`grep --line-buffered`, `sed -u`, awk `fflush()`); stdbuf useless on static binaries.
