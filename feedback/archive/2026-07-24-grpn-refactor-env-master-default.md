---
source: refactor
date: 2026-07-24
run: grpnrev (.bus-grpnrev, 6 gemini research cards)
type: friction
severity: medium
triaged-to: backlog#36
---

# ENV_MASTER_FILE default path doesn't exist on the primary box — first launch of a gemini run parks everything

**What happened:** First `swarm-run.sh ""` launch of a 6-card gemini research swarm failed
instantly: `_env_master_key: ~/.config/unimatrix/env.master not found (need
GEMINI_API_KEY)` × 6, all cards parked (lane exhausted, hard-pinned gemini), run exited 0-ish
as INCOMPLETE. Operator had to know from memory that `ENV_MASTER_FILE=~/s/.env.master`
must be exported, clear `limits/*.parked` + `limits/gemini.limited` by hand, and relaunch.

**Expected:** Any of:
1. `swarm-run.sh doctor` / preflight refuses to launch env-var-auth lanes (gemini/glm/kimi)
   when the env-master file is missing — fail BEFORE claiming cards, not per-card.
2. A documented fallback chain for the secrets path (e.g. also try `~/s/.env.master`), or a
   one-time `swarm-run.sh config env_master <path>` persisted in swarm.conf.
3. On lane-exhausted-at-launch, print the exact recovery commands (which limits markers to rm).

**Evidence:** .bus-grpnrev (first-launch park markers since cleared);
session transcript refactor 2026-07-24. Relaunch with ENV_MASTER_FILE set claimed all
6 cards in seconds — pure config-discovery tax, ~4 min lost.
