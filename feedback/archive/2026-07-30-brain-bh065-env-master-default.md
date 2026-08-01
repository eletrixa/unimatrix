---
source: brain
date: 2026-07-30
run: bh065
type: friction
severity: minor
decision: apply-now
triaged-to: backlog#78
---

# env-master preflight fails on a box where the key file exists at the house-standard path

What happened: first `swarm-run.sh --run bh065` launch aborted with
"env-master file is unreadable: ~/.config/unimatrix/env.master" although the box's standard
secrets master (`~/s/.env.master`, carrying Z_AI_CODING_KEY) existed and every prior documented
run used it. Cost: one aborted launch + a diagnose loop grepping swarm-run/swarm-lib for the
expected key name.

Expected: either (a) the default candidate list probes `~/s/.env.master` after
`$XDG_CONFIG_HOME/unimatrix/env.master`, or (b) the abort message names the key(s) the lane set
needs AND suggests the house-standard path, or (c) `doctor` prints a copy-paste
`export ENV_MASTER_FILE=...` line when it finds a readable candidate elsewhere.

Evidence: bh065 launch log (brain repo, task output 2026-07-30 ~01:10 CEST); fix that worked:
`ENV_MASTER_FILE=$HOME/s/.env.master`.
