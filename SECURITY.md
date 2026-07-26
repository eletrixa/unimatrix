# Security Policy

## Reporting a vulnerability

Please report security issues through GitHub's [private vulnerability
reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)
for this repository. **Do not open a public issue for a vulnerability.**

This is a passively-maintained personal project. Reports are handled on a
**best-effort** basis with **no SLA** — there is no guaranteed response or fix
time. Fixes land when time allows.

## Threat model

Be honest about what unimatrix actually protects. It is an orchestrator that
spawns local CLI agents (`claude`, `codex`, `gemini`, `glm`, `grok`) as child
processes on your machine. Some containment is **enforced in code**; a lot is
**policy / trust only**. The table below separates the two so you don't
mistake one for the other.

### What "env cage" is and is NOT

Every worker is spawned under `env -i` (empty environment) plus an explicit
allowlist of `PATH` / `HOME` (a per-lane scratch home) / `LANG`, and secrets
are injected **one key at a time via per-key grep** from the env-master file —
the file is never sourced, and `run-*.jsonl` never captures the environment.
See `src/swarm-lib.sh` (`lane_cmd`, `envbase=(env -i ...)`).

This scrubs **environment variables** only. It is **not** a kernel, filesystem,
or namespace sandbox. A worker still runs as **your OS user** and can read any
file it has permission to by **absolute path** — `~/.ssh`, `~/.aws`, the
env-master file itself. The cage stops secret *env vars* from leaking into
child processes; it does not stop a process from reading secret *files*.

### Per-lane containment

| Lane | Enforced in code | Policy / trust only |
|------|------------------|---------------------|
| `claude` | `env -i` cage + scratch HOME; writes scoped to CWD = target dir | `--permission-mode acceptEdits` is CLI-trust, **not** a path fence — no filesystem boundary stops reads/writes outside the target |
| `glm` | Same as `claude` (GLM is the `claude` binary with a child-env swap) | Same `acceptEdits` CLI-trust caveat |
| `codex` | `env -i` cage + real `-s workspace-write` sandbox scoped to the target dir | — |
| `gemini` (v1) | `env -i` cage + scratch HOME; **refuses writes** (read-only lane) | Web-capable: can be **prompt-injected to read local files by absolute path and exfiltrate** them. Runs with `cwd` = an empty scratch home to limit blast radius |
| `gemini` (docker) | Opt-in `GEMINI_SANDBOX=docker`: `docker run --rm -i`, explicit `-e` allowlist only, no `-v`/`--mount`; refuses to run if `docker` is absent (never a silent unsandboxed fallback) | This is the recommended mitigation for the web-lane injection risk above |
| `grok` | `env -i` cage + scratch HOME | `--allow Write/Edit/Create` is CLI-trust, **not** a path fence |

### Other surfaces

- **`.bus/`** is gitignored, so bus traffic and prompts are not committed.
  Keep it on a local POSIX filesystem (not a 9p/drvfs/NFS mount, which break
  `O_APPEND`/`flock`/`inotify`).
- **Credential cages** under `.bus/home/` are **same-UID readable** — they
  hide secrets from *other* users, not from other processes you run.
- **Cockpit** binds `127.0.0.1` with Host/Origin guards (enforced), but has
  **no authentication** — anyone with local access to that port can drive it.

### Single-user machine assumption

unimatrix assumes it runs on a **single-user machine you control**. Everything
above holds *within* that assumption: containment is same-UID, the cockpit
trusts localhost, and the "cage" is about hygiene (no secret env vars, no
committed bus, no sourced secrets file) — not about isolating a hostile worker
from your files. Do **not** run untrusted lanes, untrusted prompts, or the
cockpit on a shared or multi-tenant host.
