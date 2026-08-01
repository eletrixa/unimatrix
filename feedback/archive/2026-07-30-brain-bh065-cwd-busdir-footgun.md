---
source: brain
date: 2026-07-30
run: bh065
type: friction
severity: major
decision: apply-now
triaged-to: backlog#77
---

# cwd-derived BUSDIR mis-derives twice per run under a persistent-shell orchestrator

What happened: `--run <label>` derives BUSDIR from the caller's cwd. Under Claude Code the
shell cwd is persistent-but-surprising (a prior `cd` in a compound command survives; a tool cwd
reset note appears AFTER the fact). In run bh065 this mis-derived BUSDIR twice:
(1) relaunch from `apps/brain-api` → `apps/brain-api/.bus-bh065` — "nothing to run" abort;
(2) launch from a compound command that had `cd .bus-bh065/specs` earlier → NESTED
`.bus-bh065/specs/.bus-bh065` created inside the real bus (junk dirs left behind, needed rm).
The loud abort + hint line saved both runs — that guard is working as designed.

Expected/suggestion: when `--run <label>` is given and `./.bus-<label>` does NOT exist at cwd
but DOES exist in a git-toplevel ancestor (walk `git rev-parse --show-toplevel`), prefer the
ancestor's bus (or abort telling the caller the ancestor path). Alternatively support
`--busdir <path>` explicitly so orchestrators can pin it and stop caring about cwd.

Evidence: bh065 task outputs 2026-07-30 (~01:40, ~02:05 CEST), nested dir removed by hand.
