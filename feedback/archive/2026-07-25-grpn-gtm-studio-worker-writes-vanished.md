---
source: grpn-gtm-studio
date: 2026-07-25
run: refinery-01
type: bug
severity: high
triaged-to: backlog#57 skill-ledger 2026-07-25
---
# Files a worker wrote (clean Write records in its stream) VANISHED from disk

What happened: R3.8's stream shows successful Write tool calls for
redesign/app/api/stations/prospect/{engine-client.ts,types.ts,engine-client.test.ts}
at ~11:33; by 11:45 the files were gone from disk (no rm in any stream; no git
operation touched them). The orchestrator restored them by replaying the Write
records out of run-R3.8.jsonl — which worked byte-perfectly and should be a
documented salvage recipe regardless of the root cause.

Expected: unknown root cause (worker crash mid-flush? cage cleanup?). Two asks:
(1) investigate whether the write cage can drop completed writes when its process
dies on an auth error; (2) add the stream-replay restore to the skill's salvage
doctrine — it turned a lost-work incident into a 2-minute fix.

Evidence: .bus-refinery-01/run-R3.8.jsonl Write records vs. find(1) listings at
11:33 and 11:45 (both in the grpn-gtm-studio session transcript 7b7aeaac).
