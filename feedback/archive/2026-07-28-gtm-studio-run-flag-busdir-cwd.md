---
source: gtm-studio
date: 2026-07-28
run: gtm-owners3
type: bug
severity: medium
triaged-to: backlog#72
---

# `--run <label>` derives BUSDIR from the unimatrix repo root, not the caller's cwd

What happened: launched `~/code/unimatrix/swarm-run.sh --run gtm-owners3 ""` from
<studio checkout> with 13 pre-seeded cards in
`$PWD/.bus-gtm-owners3/specs/`. The run printed
`busdir=<unimatrix checkout>/.bus-gtm-owners3`, swept an EMPTY specs/ dir there, and
closed in seconds looking like a successful (empty) run.

Expected: `--run` to namespace against the CALLER's working directory (`$PWD/.bus-<label>`),
matching the documented mental model "run the swarm from the target repo", or at minimum a
loud warning when the derived bus has no specs while `$OLDPWD/.bus-<label>/specs` is non-empty.

Recovery: relaunch with explicit `BUSDIR=$PWD/.bus-gtm-owners3 SPEEDWARS_RUN=gtm-owners3` —
works as documented for the pre-`--run` form.

Evidence: task output shows `root=<unimatrix checkout> ... busdir=<unimatrix checkout>/.bus-gtm-owners3`
followed immediately by the close checklist; the studio repo's bus was untouched.
