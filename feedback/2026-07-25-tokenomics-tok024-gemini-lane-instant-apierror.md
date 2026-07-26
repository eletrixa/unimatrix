---
source: tokenomics
date: 2026-07-25
run: tok024
type: bug
severity: major
---

# Gemini lane dies instantly with "[API Error: An unknown error occurred.]" — 0 tokens, <1s

## What happened

All 3 pre-seeded gemini research cards (`s1/s2/s3-*-schema`, `.lane` pinned) failed 3× each
across TWO launches and parked. Every attempt: `{"type":"result","status":"error","error":
{"type":"unknown","message":"[API Error: An unknown error occurred.]"}}` with `duration_ms:0`,
`total_tokens:0` — the CLI dies before any request lands.

Direct probe found ONE cause layer: `gemini -p` refuses headless outside a trusted directory
("Gemini CLI is not running in a trusted directory… set GEMINI_CLI_TRUST_WORKSPACE=true").
Relaunching the pool with `GEMINI_CLI_TRUST_WORKSPACE=true` in the launch env did NOT fix the
worker failures — either the engine doesn't pass launch-env vars through to the gemini child
env swap, or a second failure (key/quota/model) hides beneath. `ENV_MASTER_FILE=~/s/.env.master`
was set (grpnrev lesson applied).

## Expected

Either the doctor preflight or the first claim should surface a concrete cause (trust gate,
missing key, quota) instead of 6 park-cycles of "unknown error"; and the gemini child env
should inherit `GEMINI_CLI_TRUST_WORKSPACE` (or the engine should set it — headless workers
are by definition not interactive-trusted).

## Evidence

- `~/code/unimatrix/.bus-tok024/run-s1-anthropic-schema.jsonl` (both attempts, 3-line streams)
- `~/code/unimatrix/.bus-tok024/limits/` park markers from both launches
- Recovery used: Fable did the research via WebFetch; cards moved to `cancelled/`.
