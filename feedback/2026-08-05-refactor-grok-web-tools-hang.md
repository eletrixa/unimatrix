---
source: refactor
date: 2026-08-05
run: rr-d06-getaways
severity: major
---

# grok web_search/web_fetch hang -> false-done skeletons under readyroom

grok:grok-4.5 cards (both write branch AND read-only branch w/ profile GROK_TOOLS web set)
streamed 1-2 intro sentences, then the first web tool call never returned; worker sat until
timeout kill ("Cancelled", num_turns:2, zero recorded toolName events), res captured the intro
text only. Six D06 web cards were marked done/ with 165-433 byte res files (verify wave never ran
- driver had exited). Doctor --live grok probe PASSES (no web tool involved). Suspect xAI
web-tool backend unreachable from this box (WARP?) or CLI tool-transport regression - the
2026-08-04 headless probe evidence no longer holds. Effect: readyroom Track A unusable on grok
today; rerouted to claude WebSearch agents. Wants: (a) doctor --live probe that exercises
web_search on grok, (b) min-bytes floor on res before done/ when the verify wave is deferred.
