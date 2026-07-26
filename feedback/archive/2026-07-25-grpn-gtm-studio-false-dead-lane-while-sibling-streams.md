---
source: grpn-gtm-studio
date: 2026-07-25
run: refinery-01
type: bug
severity: high
triaged-to: backlog#54
---
# claude lane marked .dead while a sibling worker on the SAME lane streamed on

What happened: at 11:30 five R3.x workers died with "Failed to authenticate" and the
engine wrote limits/claude.dead — while R3.7's worker (same lane, same account)
kept streaming for 15 more minutes and finished its card. The .dead marker then
blocked all re-seeds until the orchestrator hand-verified and removed it.

Expected: before writing a lane-level .dead marker, cross-check whether any OTHER
worker on that lane has a fresh stream mtime (< lease). A live stream is proof the
lane's auth is fine — the failures were per-session token-refresh blips, which
deserve a short TTL .limited, not auth-death.

Evidence: ~/code/unimatrix/.bus-refinery-01/run-R3.{3..8}.jsonl mtimes
(five stop 11:30:4x, R3.7 continues to 11:45), limits/claude.dead.evidence.
