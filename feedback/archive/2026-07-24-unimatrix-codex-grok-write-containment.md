---
source: unimatrix
date: 2026-07-24
run: (live lane probe, separate session)
type: bug
severity: major
triaged-to: backlog#32 backlog#33
---

Live cage-identical probes of the lanes (env -i, scratch HOME, single grepped key) surfaced two
write-containment gaps in `lane_cmd` (FR-15), plus confirmations worth recording:

1. **codex is never read-only.** Every codex spawn gets `-s workspace-write -C <target>`
   (src/swarm-lib.sh:543-547); the `.write` sidecar only changes the cwd — BUSDIR when absent,
   target when present. Since codex is the REVIEW default, a read-only review card can write
   into the live bus directory. Every other lane's no-sidecar posture is enforced read-only;
   codex's isn't. Expected: no sidecar → `-s read-only` (codex supports it), sidecar →
   workspace-write at the target.

2. **grok write mode is tool-level, not path-caged.** `--allow Write/Edit/Create` permits
   writing anywhere the process can reach — the CLI's path globs (`/dir/**`) match nothing
   (noted at src/swarm-lib.sh:686). Containment today = env -i cage + scratch HOME + prompt
   only. Expected (if the CLI ever ships working path scoping): re-pin write grants to the
   sidecar target; until then the caveat belongs in rules/unimatrix/model-lanes.md and the
   unimatrix skill §2 confidentiality note.

Confirmations (no action): gemini auth + google_web_search grounding work under the cage;
gemini `.write` refusal fires loudly → chain-advance/park; verify pair gemini:claude honored;
gemini reachable only by pin (not in EXEC_CHAIN) — correct per config.

Evidence: probe transcript in the other session; code refs above at commit 907fe78.
