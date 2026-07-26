---
source: grpn-gtm-studio
date: 2026-07-25
run: refinery-01
type: friction
severity: medium
triaged-to: backlog#47 backlog#52
---
# "lane exhausted" parks carry no reset time — account session limits are schedulable

What happened: S1/S4 parked "lane exhausted" when the main account hit its session
limit; the failure surface (a spawned session agent) reported the precise reset
("resets 4:10pm Europe/Prague"). The bus marker carried nothing, so the orchestrator
could only poll or reroute; work resumed the minute the window reset — by hand.

Expected: when the lane failure text carries a reset time, park WITH it
(limits/<lane>.limited mtime-TTL set to the reset) so a sleeping pool can relaunch
itself, and so orchestrators can ScheduleWakeup instead of polling.

Evidence: fix-s1/fix-s4 failure messages 13:53Z; bmu0vv31c pool log "lane exhausted".
