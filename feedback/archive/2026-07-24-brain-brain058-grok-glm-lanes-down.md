---
source: brain
date: 2026-07-24
run: brain058
type: bug
severity: major
triaged-to: backlog#34 backlog#35
---

# Both external write lanes (grok + glm) failed every claim on brain058 → 100% claude fallback

## What happened

brain058 = Brain plan-058 security hardening + PIN-lane removal. 11 cards (3 spec pins on
`claude:sonnet`, 8 build cards). Five build cards were deliberately chain-seeded to offload
contained CODE work to the cheap lanes:

- `b3.chain = "grok glm claude:sonnet"` (admin-console React trim, C2)
- `b6.chain = "grok glm"` (single-file next.config headers, C1)
- `b4.chain = "glm claude:sonnet"` (brain-api deletes + SQL migration, C2)
- `b5.chain = "glm claude:sonnet"` (require-pat limiter + boot guard, C2)
- `b8.chain = "glm claude:haiku claude:sonnet"` (QA session-mint helper, C1)

**Every grok and glm attempt failed; all five cards walked their chain to a claude rung.** Net
result: 11/11 cards executed on claude lanes (10 sonnet, 1 haiku). Zero external-lane execution
despite grok-first `EXEC_CHAIN` in swarm.conf, a fresh `~/.grok/auth.json` (mtime 19:40, run
started 19:47), and a healthy Z.ai quota (probed `GET api.z.ai/api/monitor/usage/quota/limit`
before launch → TOKENS_LIMIT percentage 1/16, well under cap). The chain-fallback machinery
worked perfectly and saved the run — but the cost-offload intent was fully defeated.

## Two distinct failure signatures (both in speedwars rows)

**grok — silent fast-fail, `served_model: null`.** Every grok claim returns in 1–3s wall with
`served_lane:"grok"`, `served_model:null`, `outcome:"retry"`, and **no `api_error_status` and no
token/cost fields at all** (the row is truncated after `billing`). It spawns and produces
nothing — no model, no error code, no artifact. Retried repeatedly (b3, b6) before falling
through. This is not a rate-limit (no `limits/grok.limited` written) and not an auth-death (no
`.dead`); it's a lane that claims, no-ops, and emits an unclassifiable empty row.

**glm — clean HTTP 400 on every request, `served_model:"<synthetic>"`.** Every glm claim:
`served_lane:"glm"`, `served_model:"<synthetic>"`, `is_error:true`, `api_error_status:400`,
`tokens_in/out:0`, ~2s, `duration_api_ms:0`. A real 400 from the Z.ai Anthropic-compat endpoint
before any tokens flow — payload/model-id rejected, not a quota or content issue (quota was
confirmed healthy pre-run). Same class as the ledger's "GLM 5xx-error-text-as-answer", but here
it surfaced as a structured 400 and the retry/diff-gate correctly refused to finalize it `done`
— good. The `<synthetic>` served_model suggests the row was stamped by the error path, not a
real model response.

## What I expected

At least the C1/C2 single-file cards (b6 headers, b8 helper) to land on grok/glm as routed, so
the run mixed lanes and cost less. Instead the effective chain for every card collapsed to
"claude", making the grok/glm rungs dead weight that only added ~20–30s of retry latency per
card before fallback.

## Impact

- **Cost:** run billed entirely on the claude pool (sonnet-heavy) instead of the intended
  grok/glm offload for 5 of 8 build cards. Spec+build cards observed so far ≈ **$12.7** API-equiv
  (9 of 11 cards; b2/b5 still finishing at capture). Had the 5 chain cards served on grok/glm the
  metered figure would have been materially lower.
- **Latency:** each chain card paid ~2–4 retry cycles (grok 1–3s + glm ~2s each, several rounds)
  before the claude rung claimed — ~20–30s of pure fallback churn per card.
- **Not a correctness risk:** the diff-gate + chain fallback held; no false-done slipped through
  (glm's 400 and grok's null-model were both correctly refused).

## Evidence paths (no secrets)

- Bus: `.bus-brain058/`
- speedwars rows (grep `brain058`): `docs/ops/speedwars.jsonl` — see the
  19:49:xx `id:b3/b4/b5/b6/b8` rows with `served_model:null` (grok) and
  `api_error_status:400 served_model:"<synthetic>"` (glm).
- Per-card worker streams: `.bus-brain058/run-b{3,4,5,6,8}.jsonl` — init
  records show `model:"claude-sonnet-5"`/`claude-haiku-*` only; no grok/glm model ever spawned
  (`grep -lE "grok-4|glm-5" run-*.jsonl` → empty).
- swarm.conf in use: `EXEC_CHAIN="grok:grok-4.5 glm:glm-5.2 claude:haiku kimi:kimi-k3 codex:default"`.

## Suggested triage

1. **glm 400 is the actionable one** — a fixed HTTP 400 with 0 tokens on the Z.ai
   Anthropic-compat endpoint, with healthy quota, points at a request-shape or model-id mismatch
   (`glm-5.2` — is that the current Z.ai coding-plan model code, or has it moved?). A `doctor`
   probe that actually POSTs a 1-token completion per external lane (not just "CLI on PATH")
   would have caught both of these before launch — the current doctor reports grok/glm "OK if
   claude present" without ever exercising them.
2. **grok null-model needs a classifier** — a claim that returns `served_model:null` with no
   `api_error_status` should write a `limits/grok.limited` (or a distinct `.broken`) marker after
   N such rounds, so later cards skip the lane instead of each paying the full retry walk. Right
   now every card re-probes the dead lane from scratch.
3. Consider a **pre-run live-lane gate**: if a lane fails a 1-token smoke POST at `doctor`/launch,
   auto-drop it from `EXEC_CHAIN` for that run and log it once, rather than letting every chain
   card discover it independently.
