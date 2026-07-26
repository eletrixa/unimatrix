# UNIMATRIX

Multi-model agent orchestration driven from Claude Code. `/swarm "<question>"` plans in-session
(the orchestrator model), fans the question out to headless worker CLIs (`codex exec` / `gemini -p` /
`claude -p` / GLM and Grok via a child-env swap on `claude -p`), and coordinates them over a JSONL
file-bus on a local POSIX filesystem — watched from a separate `tmux -L swarm` cockpit, optionally
fronted read-only by a terminal on the host. `/swarm-loop "<goal>" --until "<criteria>"` is the
second mode: iterate until success criteria genuinely hold, not until an executor claims done. Zero
MCP, zero new runtime dependency — everything is bash plus CLIs already installed and authed.

## Tech Stack

| Layer | Technology |
|-------|-----------|
| Runtime | Bash ≥5.1 (`wait -n -p` job pool — `xargs -P` doesn't forward INT/TERM) |
| Orchestrator | Claude Code slash commands (`/swarm`, `/swarm-loop`) — this session is the brain |
| Workers | Headless CLIs: `claude -p`, `codex exec`, `gemini -p`, GLM & Grok (`claude -p` + child-env swap) |
| Bus | JSONL file-bus on a local POSIX fs (`.bus/`) — no DB, no daemon, no MCP |
| Monitor | `tmux -L swarm` (isolated socket) + `jq` firehose; optional read-only terminal attach |
| Config | `swarm.conf` — bash-sourceable `KEY=VALUE`, no YAML/schema engine |
| Tests | bats-core 1.13.x |
| Lint | shellcheck -x |

## Commands

```bash
bats tests/                      # Run tests
shellcheck -x unimatrix swarm-run.sh swarm-loop.sh swarm-mon.sh src/swarm-lib.sh src/swarm-ctl check.sh plugin/gen-commands.sh   # Lint (all 8 scripts)
./swarm-run.sh "<question>"       # Run a swarm: fan out, gate, synthesize
tmux -L swarm attach -r -t mon    # Attach to the monitor cockpit (read-only)
```

## Rules

**Read before writing any code.**

- Project rules live in `rules/unimatrix/`: `bus-discipline.md`, `model-lanes.md`,
  `loop-discipline.md` — read all three before touching the bus, spawning a worker, or building
  `/swarm-loop`.
- Every source file must follow the file header standard in `rules/file-headers.md`.
- Check the `applies-to` field in each rule — skip rules that don't match this project's stack.

## Specs

**Development is spec-driven. Specs come before code.**

- All specs live in `specs/`. The index is `specs/README.md`.
- Before building any feature that touches 3+ files or has ambiguous requirements: **write a spec first**.
- Mark ambiguities with `[NEEDS CLARIFICATION]` — never guess.
- Specs have a lifecycle: **Draft** (don't implement yet) → **Active** (implement against this) → **Deprecated** (don't use).
- Do not change a spec's lifecycle status without explicit user approval.
- When implementation diverges from the spec, update the spec alongside the code.
- After completing work, verify all acceptance criteria in the spec pass.

## Versioning

- Maintain `CHANGELOG.md` at the repo root.
- After any user-facing change, add an entry to the `[Unreleased]` section.
- Releases are cut by the orchestrator automatically once `[Unreleased]` accumulates 3-5
  user-facing features (or on maintainer request). Semver. Every release section MUST open with a
  plain-language "What's new (for humans)" block — 1 line per feature, no jargon, written for an
  end user. See `docs/releasing.md` for the full checklist.
- Commit changelog entries alongside the code change, not separately.
- Update `docs/versions.md` (pinned CLI/model versions) at the end of any wave that changes a pin.

## Git

- **Single-branch: `public`.** All work commits directly to `public` (the working trunk) — **no
  `dev` branch, no feature branches.** The old `main` branch is disjoint pre-release history — never
  commit to it. Deliberate override of the global multi-branch standard: unimatrix is a
  single-operator bash tool with no deploy pipeline to protect, so branch ceremony has no payoff here.
- Never commit secrets, `.env*` files, or worker output that may contain fetched web content.

## Architecture

Read the answer from each worker CLI's handoff file, never the terminal. The bus lives on a local
POSIX filesystem (never a 9p/drvfs/NFS mount). Judge ≠ executor.

## Conventions

- One JSONL record = one `write(2)` call, including the trailing newline (`echo >>` is fine —
  `O_APPEND` is atomic for regular-file appends on a local POSIX fs).
- Every script starts with `set -euo pipefail` and `shopt -s inherit_errexit`.
- Every GLM/Grok spawn is `env -u ANTHROPIC_API_KEY` plus the full child-only provider env block
  (`rules/unimatrix/model-lanes.md`) — never exported into the orchestrator's own shell.
- Workers never `source "$ENV_MASTER_FILE"` — `grep` the individual key(s) a worker needs out of it,
  least-privilege per spawn. `ENV_MASTER_FILE` defaults to
  `${XDG_CONFIG_HOME:-$HOME/.config}/unimatrix/env.master`.

## Boundaries

- **Always**: Run `bats tests/` before committing. Follow `rules/unimatrix/*.md`. Update
  `CHANGELOG.md` and `docs/versions.md` per wave. Scrub credential/config dirs (`~/.aws`, `~/.ssh`,
  your `$ENV_MASTER_FILE` dir) from any unattended worker's env.
- **Ask first** (get maintainer sign-off before): Adding a new external dependency (CLI, npm/brew
  package). Adding a standing daemon. Any unattended/cron run (requires `GEMINI_SANDBOX=docker` —
  FR-16). Adding a new model lane beyond the current five.
- **Never**: Point `.bus` at a 9p/drvfs/NFS mount — it must be a local POSIX fs (`O_APPEND`/`flock`/
  `inotify` break otherwise). Run bare `gemini --yolo` with secrets in the spawning shell's env.
  Let a model verify its own output (reviewer lane = executor lane on any claim). Spend on a lane
  without logging it in your run-evidence ledger. Commit secrets. Push to any branch but `public`.

## Key Files

| File | Purpose |
|------|---------|
| `swarm.conf` | Bash-sourceable role/lane config (`PLAN`, `EXEC_CHAIN`, `MAX_ITERATIONS`, ...) |
| `.bus/` | File-bus tree: `specs/ queue/ claimed/ done/ limits/ loop/` + per-worker `run-*.jsonl` / `res-*.txt` |
| `specs/README.md` | Spec index — what exists and what's planned |
| `docs/versions.md` | Pinned CLI/model versions + re-smoke triggers |
| `docs/ops/llm-runs.example.md` | Optional run-evidence ledger template; your real one is gitignored |
| `feedback/` | Cross-repo feedback drop-box — agents in other repos file unimatrix bugs/friction/ideas here (see `feedback/README.md`); triaged into `docs/research-backlog.md` |
| `plans/001-multimodel-orchestration/PRD.md` | Winning architecture, build phases, exact invocations |
