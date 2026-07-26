# agents.md — operating UNIMATRIX

Clone, run `bats tests/` before touching anything else, then invoke by writing a prompt file and
running `./swarm-run.sh` — that's the whole surface. Everything below is the contract for doing
that safely.

```bash
git clone https://github.com/eletrixa/unimatrix && cd unimatrix
bats tests/                                   # 160 tests must be green before you change anything
mkdir -p .bus/specs
echo "Your question here." > .bus/specs/b1.prompt
./swarm-run.sh && cat .bus/res-b1.txt         # the answer — never run-b1.jsonl
```

## 1. Setup & commands

Every step here is non-interactive — no prompts, no TTY assumptions.

```bash
shellcheck -x unimatrix swarm-run.sh swarm-loop.sh swarm-mon.sh src/swarm-lib.sh src/swarm-ctl check.sh plugin/gen-commands.sh   # lint (all 8 scripts), must be clean
./swarm-run.sh --plan-only "<question>"       # print the resolved plan, enqueue nothing
./swarm-run.sh config                         # print the resolved swarm.conf table
./swarm-run.sh config EXEC_CHAIN "codex:default gemini:gemini-3-flash"   # edit swarm.conf in place
./swarm-run.sh                                # drains .bus/specs -> queue -> claimed -> done
./swarm-run.sh verify                         # cross-model verify wave over every done/ branch
```

`./swarm-run.sh "<question>"` — the positional arg is **ignored** in default mode; this script
reads `.bus/specs/*.prompt`, it does not accept a question inline. Write the prompt file first.

Exit code: **0 only if every live branch reached `done/`.** Anything in `.bus/limits/*.parked`
(its lane chain exhausted) makes the run exit nonzero with every parked id on stderr — never a
silent partial run.

## 2. Bus contract

`.bus/` on **ext4 only** — never `/mnt/c` or `/mnt/f` (9p breaks `inotify`/`O_APPEND`/`flock`).

- **One JSONL record = one `write(2)` call, trailing newline included.** `echo >>` is a single
  syscall and fine. Never assemble a record across multiple writes.
- **Claim = atomic rename, not plain `mv` to a shared name.** `mv queue/<id> claimed/<id>.<lane>`
  — a per-worker-unique destination. The loser's `mv` fails `ENOENT`; that failure *is* the
  lost-race signal, on the same filesystem (rename isn't atomic across mounts).
- **Answers come ONLY from each CLI's own handoff file** — `res-<id>.txt`
  (`codex --output-last-message`, or extracted from the `stream-json` `result` envelope for
  claude/GLM/gemini). **Never** scrape terminal output or a captured pane — that's the one rule
  that makes delegation injection-safe.
- `run-<id>.jsonl` is glance-only firehose, never the source of truth for an answer.
- Workers `touch` their own claim file as a heartbeat; the reaper requeues on heartbeat silence
  past `LEASE_MIN` minutes, not claim age.

## 3. Lane invocations

Every spawn runs inside `env -i` — no lane inherits the orchestrator's ambient shell env.

```bash
# claude
env -i PATH="$PATH" HOME="$scratch_home" LANG=C.UTF-8 \
  claude -p --output-format stream-json --verbose --model "$model" "$prompt"

# codex
env -i PATH="$PATH" HOME="$scratch_home" LANG=C.UTF-8 \
  codex exec --json --output-last-message "$busdir/res-$id.txt" \
    -s workspace-write --skip-git-repo-check -C "$cdir" --ephemeral "$prompt"

# gemini (read-only lane, v1 — no write sidecar accepted)
env -i PATH="$PATH" HOME="$scratch_home" LANG=C.UTF-8 \
  GEMINI_CLI_TRUST_WORKSPACE=true GEMINI_API_KEY="$gkey" \
  gemini -m "$model" -o stream-json -p "$prompt"

# GLM — same claude binary, child-only Z.ai env swap
env -i PATH="$PATH" HOME="$scratch_home" LANG=C.UTF-8 \
    ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic \
    ANTHROPIC_AUTH_TOKEN="$Z_AI_CODING_KEY" \
    ANTHROPIC_DEFAULT_HAIKU_MODEL="$model" \
    ANTHROPIC_DEFAULT_SONNET_MODEL="$model" \
    ANTHROPIC_DEFAULT_OPUS_MODEL="$model" \
    API_TIMEOUT_MS=3000000 \
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
  claude -p --output-format stream-json --verbose "$prompt"

# grok — its own CLI; OAuth file (~/.grok/auth.json) copied into the caged HOME, no env key
env -i PATH="$PATH" HOME="$scratch_home" LANG=C.UTF-8 \
  grok -p "$prompt" --output-format streaming-json --no-auto-update \
    --tools read_file,grep,list_dir --no-subagents \
    $([[ "$model" != default ]] && echo -m "$model")
```

Six lanes total — `claude`, `codex`, `gemini`, `glm`, `grok`, `kimi`. The stranger-safe default exec
chain is `claude:haiku` → `codex:default`, so a fresh clone runs with no extra keys; add
`glm`/`grok`/`gemini` to `EXEC_CHAIN` only once their credentials are in place.

The GLM spawn starts from `env -i`, same as every other lane — the child env is built from
nothing, so `ANTHROPIC_API_KEY` is structurally absent, never present to begin with. All three
`ANTHROPIC_DEFAULT_*_MODEL` tier envs resolve to the same requested `$model` (not distinct
per-tier models) — hardcoding them differently let a pinned model get silently served by a
different one, 3x quota billed instead of 1x.
Write-capable branches (a `.bus/specs/<id>.write` sidecar) add `--permission-mode acceptEdits`
for claude/GLM (never `--dangerously-skip-permissions` — forbidden outright) with CWD set to the
target via `env -C`; codex is natively `-C <target> -s workspace-write`; grok swaps its read-only
`--tools` set for `--allow Write --allow Edit --allow Create` (never `--yolo`). gemini has no write
lane in v1 — a write sidecar on a gemini branch is a loud refusal, never a silent no-op.

## 4. Boundaries

- **Never** point `.bus` at `/mnt/c` or `/mnt/f`.
- **Judge ≠ executor, no exceptions.** A lane never reviews its own output — verify wave uses
  `VERIFY_MAP` (`swarm.conf`), loops pin `LOOP_JUDGE` distinct from `EXEC_CHAIN`'s first entry.
- **Log every spawned run** to `docs/ops/llm-runs.md`: when, what, lane (including any failover
  hop), actual billed cost re-summed from the result envelope — never per-event token counts
  (`LEDGER_AUTO=1` does this automatically on successful finalize).
- **Scrub `~/s`, `~/.aws`, `~/.ssh`** from any unattended worker's environment before it runs.
- Workers never `source "$ENV_MASTER_FILE"` — grep the one key you need
  (`_env_master_key` in `src/swarm-lib.sh` does this for you).
- Unattended/cron runs require the sandboxed gemini lane (`GEMINI_SANDBOX=docker`, FR-16) and an
  explicit human go — attended is the default and the only mode without it.

## 5. Conventions

- Every script: `set -euo pipefail` and `shopt -s inherit_errexit`.
- Every source file carries the header format in `rules/file-headers.md` (summary, Project,
  Module, Deps, Tested, responsibilities, constraints) — add on creation, update when you touch
  an existing file.
- Prompts travel as **files**, never shell-interpolated strings or `send-keys` streams.
- No synthesis before the completeness gate (`done + parked >= live`) — a partial result set is
  never adjudicated.

Full detail: `docs/usage.md` (operator guide), `rules/unimatrix/bus-discipline.md`,
`rules/unimatrix/model-lanes.md`, `rules/unimatrix/loop-discipline.md`, `specs/01-swarm-core.md`.
