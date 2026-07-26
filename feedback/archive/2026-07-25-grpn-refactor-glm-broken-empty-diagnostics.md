---
source: grpn/refactor (swarm B atlas013 orchestrator)
date: 2026-07-25
run: atlas013
type: bug
severity: medium
triaged-to: backlog#51 backlog#52
---

# glm lane died with empty diagnostics; .broken marker carries no reason

## What happened
Wave 1 card `w1-rf-redaction` was `.lane`-pinned to glm (pure-function TDD card,
zero repo context - exactly glm's niche per model-lanes). The engine parked it after
"produced no usable answer 3 times on lane 'glm' - retries exhausted" and wrote
`limits/glm.broken`. Evidence trail was empty everywhere:

- `limits/glm.broken` content: 4 bytes, no reason text
- `limits/w1-rf-redaction.parked`: zero bytes
- no `run-w1-rf-redaction.jsonl` stream on the bus at diagnosis time

Z.ai quota was probed healthy at preflight ~30 min earlier (18% of TOKENS_LIMIT,
level pro, via GET api.z.ai/api/monitor/usage/quota/limit).

## Expected
When a lane exhausts retries, the bus should keep SOMETHING diagnosable per attempt:
the classifier verdict that made each answer unusable (empty? 5xx-as-text? auth
text? thinking-flood timeout?), and `.broken`/`.parked` markers should carry a
one-line reason. Recovery decisions (reseed vs fix lane vs raise timeout) currently
require guessing.

## Evidence paths
- ~/code/unimatrix/.bus-atlas013/limits/ (markers as left by the run)
- /tmp scratchpad wave1-run.log line: "swarm-run: w1-rf-redaction produced no usable
  answer 3 times on lane 'glm' - retries exhausted"

## Recovery used (worked)
Repointed queue/<id>.lane to claude:haiku (the plan's named fallback), removed the
.parked marker; the still-live pool claimed and landed the card. Zero work lost.

## Update (same run, ~90 min later): root cause likely NOT the lane
Wave 2b reproduced the identical signature on claude:haiku (card `w2b-redact`:
3 zero-byte answers, `limits/claude.broken` written) while FOUR concurrent
claude:sonnet workers on the same account ran fine. Common factor of both dead cards:
their `.write` sidecar pointed at a directory that DID NOT EXIST yet
(`services/atlas/tests/services` at wave-1 start, `services/atlas/services` at
wave-2b start). Hypothesis: cage setup fails on a nonexistent write-target dir, the
worker dies before emitting a byte, and the engine attributes the failure to the LANE
(marking it .broken/.limited) instead of the CARD. Recovery both times: mkdir the
target, clear markers, reseed - card then lands cleanly on the same "broken" lane.
Suggested fixes: (a) mkdir -p the write target at claim time, or refuse the claim
with a named CARD error; (b) never mark a lane broken on zero-byte failures of a
single card while sibling cards on the same lane are mid-flight and healthy.
