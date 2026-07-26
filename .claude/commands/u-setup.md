---
description: First-run setup — check prerequisites, configure lanes and secrets, smoke-test the bus (multiplatform)
---

# /u-setup — UNIMATRIX first-run setup

**Deprecated** (spec 17 FR-8): `/u-setup` is deprecated in favor of `/u:setup`; body stays
canonical here. `/u-setup` is deleted next release — `/setup` (below) and `/u:setup` both keep working.

Canonical body for the `/setup` slash command (spec 16 FR-5) — `/setup` is now a 2-line alias
pointing here.

You are setting up UNIMATRIX for a new user on their machine. Work through the phases in order,
report each check as pass/fail, and stop with a clear fix instruction on any hard failure. Never
guess — probe.

## Security rules for this session (non-negotiable)

- **Never ask the user to paste an API key into this conversation**, and never read key VALUES
  from any env file. To verify a key exists use presence checks only:
  `grep -c '^GEMINI_API_KEY=' "$ENV_MASTER_FILE"` — count, not value.
- Never `cat`, `source`, or open the secrets file. Never echo a key into shell history.
- The user edits their secrets file themselves in their own editor. You only tell them what line
  to add.

## Phase 1 — platform gate

1. `uname -s` — Linux and macOS are supported natively. On Windows this must be WSL2
   (`grep -qi microsoft /proc/version`); native Windows / Git Bash is **not supported** (process
   groups, signals, bash 5.1). Stop with that message if so.
2. Bash: `bash -c 'echo ${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}'` — need **≥ 5.1** (`wait -n -p`).
   macOS ships 3.2: instruct `brew install bash` and confirm `bash` on PATH resolves to it
   (`command -v bash` → the brew path, not /bin/bash).
3. Required tools: `jq`, `tmux`, `git`. macOS: `brew install jq tmux`. Debian/Ubuntu:
   `sudo apt install jq tmux`.
4. GNU/BSD probes (macOS): run `stat -c %Y . ; env -C / true ; realpath -m / ; sha256sum
   --version` — each `2>/dev/null`. If any fail, report which, and state plainly: these paths are
   not yet portable on this platform (finalize fencing, write-mode spawns, `/swarm-loop`); a
   read-only `/swarm` on the claude/codex lanes may still work, but do not claim full support.
5. Filesystem: the repo (and `.bus/`) must live on a **local** filesystem — atomic `rename(2)` and
   `O_APPEND` are the coordination primitives. `df -T . 2>/dev/null || df .` — refuse `9p`, `drvfs`
   (`/mnt/c`, `/mnt/f`), `nfs`, `cifs`, `fuse*` network mounts. WSL2: use the ext4 side (`~/...`).

## Phase 2 — lanes (all optional except one)

Ask the user which lanes they want. **Minimum one; `claude` is the easiest start.** For each
chosen lane, check the CLI and its auth:

| Lane | CLI check | Auth (one-time, done by the user) |
|------|-----------|------------------------------------|
| claude | `claude --version` | `claude login` (subscription OAuth). Works if `claude -p "ping"` answers. |
| codex | `codex --version` | `printenv OPENAI_API_KEY \| codex login --with-api-key` — the key is needed only for this one command, in the user's own shell. |
| gemini | `gemini --version` | `GEMINI_API_KEY=` line in the secrets file (Phase 3). |
| glm | uses the `claude` binary | `Z_AI_CODING_KEY=` line in the secrets file (Phase 3). Z.ai Coding Plan. |
| grok | `grok --version` | `grok` interactive login once (OAuth → `~/.grok/auth.json`). |

Install hints: `npm i -g @openai/codex @google/gemini-cli`; claude per
https://claude.com/claude-code; grok per xAI's Grok Build CLI docs. Pin expectations:
`docs/versions.md`.

## Phase 3 — secrets file (only if gemini or glm chosen)

1. Default path: `${XDG_CONFIG_HOME:-$HOME/.config}/unimatrix/env.master`. Create the directory,
   `touch` the file, `chmod 600` it.
2. Tell the user to add, in their own editor, one `NAME=value` line per key (`GEMINI_API_KEY`,
   `Z_AI_CODING_KEY`). Wait for them to confirm.
3. Presence-check each expected key (grep -c, per the security rules above).
4. If the path differs from the built-in default, have the user export
   `ENV_MASTER_FILE=<path>` in their shell profile.

How the file is used (tell the user this): workers spawn under `env -i` — an empty environment —
and each lane gets **only its own key**, grepped from this file at spawn time. The file is never
sourced. Your shell's env (AWS creds, SSH agent, other keys) is never visible to any worker.
Honest limits: workers run as your OS user — the environment is caged, the filesystem is not; the
web-fetching gemini lane should use `GEMINI_SANDBOX=docker` for anything unattended.

## Phase 4 — config

1. `cp swarm.conf swarm.conf.bak` if the user has local edits, else edit in place.
2. Set `EXEC_CHAIN` to only the lanes configured in Phase 2, best-first — e.g. two lanes:
   `EXEC_CHAIN="claude:haiku codex:default"`.
3. Set `VERIFY_MAP` so every configured lane's verifier is a *different* configured lane
   (judge ≠ executor). Single-lane setups: warn that the verify wave degrades to same-family
   checking and cross-model verification needs a second lane.
4. Leave `FANOUT`, `LEASE_MIN`, timeouts at defaults.

## Phase 5 — smoke test

```bash
mkdir -p .bus/specs
printf 'Reply with exactly: PONG\n' > .bus/specs/setup-smoke.prompt
./swarm-run.sh
cat .bus/res-setup-smoke.txt        # expect PONG
./swarm-run.sh verify               # only if ≥2 lanes configured
```

Pass = `res-setup-smoke.txt` contains PONG and the run exits 0. Then show the user the cockpit:
`./swarm-mon.sh && tmux -L swarm attach -r -t mon`.

## Phase 6 — wrap-up

Report a one-screen summary: platform, bash version, lanes live, secrets path, EXEC_CHAIN,
smoke result. Point to `docs/usage.md` (driving `/swarm` and `/swarm-loop`) and SECURITY.md
(threat model: what is enforced in code vs what is policy).
