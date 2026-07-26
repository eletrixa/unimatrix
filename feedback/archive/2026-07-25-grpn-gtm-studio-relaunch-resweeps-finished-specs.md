---
source: grpn-gtm-studio
date: 2026-07-25
run: refinery-01
type: bug
severity: medium
triaged-to: backlog#56
---
# swarm-run.sh relaunch re-sweeps specs/ and re-queues already-finished cards

What happened: relaunching `swarm-run.sh ""` on the same bus (to drain a mid-run
completion card) re-copied R3.3–R3.8 from specs/ into queue/ although the same ids
sat in done//cancelled/. A worker claiming one would have rewritten completed work
on disk. Orchestrator purged the duplicates before any claim; the specs/ originals
then had to be deleted manually to make relaunches safe.

Expected: the specs/ sweep skips any id already present in done/, cancelled/, or
claimed/. (Alternatively: sweep specs/ entries are MOVED, not copied, on first
ingest — mid-run adds already go straight to queue/ per the skill.)

Evidence: .bus-refinery-01 queue/ listing at 11:39 (R3.3–R3.8 back alongside R3.3c).
