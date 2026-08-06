---
source: unimatrix-thrifty
date: 2026-08-04
run: thrifty1
type: bug
severity: major
---

Auto-detected: 1 card(s) whose reads were denied by the permission cage this run: t1-profile-conf

Denied paths (first 5 per card):
- t1-profile-conf: ~/code/unimatrix-thrifty/swarm.conf
- t1-profile-conf: ~/code/unimatrix-thrifty/rules/file-headers.md

Evidence: .bus-thrifty1/limits/*.cage-denied

Consequence: the same card then parked (lane exhausted). The companion auto-parked stub was folded into this one on 2026-08-04; root cause is the cage denial, the park is downstream.
Evidence: .bus-thrifty1/limits/*.parked
