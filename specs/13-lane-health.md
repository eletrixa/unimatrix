# Spec 13 — Lane Health: Preflight, Live Probes, Broken-Lane Markers, PAYG Fallback Gate

**Status:** Active (round-4 plan approved 2026-07-25; backlog 34/35/36/39 — the dead-lane-launch
incident family: brain058 burned ~$12.7 falling through two dead lanes card-by-card; grpnrev parked
an entire run on a missing env-master path)
**Date:** 2026-07-25
**Related specs:** 01 (spawn/finalize), 04 (lanes/conf), 10 (limit/dead flags, kimi budget),
12 (failure classes, feedback stubs)

---

## Overview

Today lane health is discovered mid-run, card by card, at full spawn cost: a dead grok lane
fast-fails every card that probes it (~20–30s churn each, no marker written); a missing
`ENV_MASTER_FILE` parks every env-key card only after fan-out; `doctor` checks CLI presence but
never auth; and an uncapped run (`BUDGET_USD=0`) lets a fallback chain walk onto real-PAYG lanes
with zero gate and zero marker. Spec 13 moves discovery to launch time (preflight, opt-in live
probes) and makes mid-run lane death cheap (a `.broken` marker consulted before spawn) and PAYG
fallback spend loud.

## Goals

- Fail at launch, not per-card: a run that cannot possibly complete (missing secrets file for a
  configured env-key lane) refuses to fan out.
- Pay once per lane, not per card: a fast-failing lane gets a TTL'd `.broken` marker at the first
  GENUINE failover (see FR-3); subsequent cards route around it like `.limited`.
- Opt-in live auth probes (`doctor --live`) that would have caught brain058 (grok dead, glm 400)
  and grpnrev (env-master missing) before any card spawned — each probe logged (no silent spend).
- Real-$ fallback is never silent: at `BUDGET_USD=0` (uncapped), a fallback hop onto a PAYG lane
  is loudly evidenced, and deniable by conf.

## Non-Goals

- No standing daemon, no periodic health poller — probes run at launch or on demand only.
- No auto-retry/backoff logic changes — `.broken` reuses the existing `lane_blocked` routing;
  chain semantics (spec 01/10) unchanged.
- No new CLI dependency: probes use `curl` (already required by the stack) for env-key endpoints
  and the lane CLIs themselves for OAuth lanes.
- Plain `doctor` stays read-only and free — probes never run without `--live`.

## FR-1 — ENV_MASTER_FILE launch preflight (backlog 36)

`full_run` (and `swarm-loop` before its first iteration) computes the set of bare lanes in play
(union of `EXEC_CHAIN`, `REVIEW`/`REVIEW_CHAIN`, plus any `specs/*.lane`/`queue/*.lane` pins). If
that set intersects the env-key lanes (`gemini`, `glm`, `kimi`) and the env-master file
(`$ENV_MASTER_FILE`, default `${XDG_CONFIG_HOME:-$HOME/.config}/unimatrix/env.master`) is
unreadable, the run **aborts before fan-out** (nonzero rc, loud stderr naming the resolved path and
the fix: `export ENV_MASTER_FILE=<your secrets file>`). Runs whose lane set needs no env key are
unaffected. Per-key absence (file readable, key missing) stays a spawn-time `lane_cmd` failure —
preflight checks reachability, not contents.

**Mode-aware (amended round 4).** `VERIFY_MAP`/`PLAN_CHAIN`/`ORCH_CHAIN` are excluded from the
default (`full`) mode: all three BAKE an env-key lane into their conf defaults, so folding them in
would abort every plain claude/codex run — contradicting acceptance criterion 1. `verify_run`
instead calls the preflight in `verify` mode, which adds the verifier `verify_lane_for` **actually
resolves** for each already-done branch, so a verify wave can no longer pass preflight and then fan
out env-key verifiers against an unreadable env-master one parked card at a time.

## FR-2 — `doctor --live` auth probes (backlog 35, subsumes 12)

`swarm-run.sh doctor --live` extends plain doctor with one minimal authenticated request per lane,
10s timeout each (codex: 30s — see the CLI-probe bullet), printing `PASS <latency>` /
`FAIL <reason>` per lane:

- `glm` / `kimi`: 1-token `POST /v1/messages` against their Anthropic-compat endpoints, key via
  `_env_master_key` (`Z_AI_CODING_KEY` / `MOONSHOT_API_KEY`), curl, no CLI spawn.
- `gemini`: 1-token `generateContent` REST call with `GEMINI_API_KEY` from env-master.
  **Alias fallback (amended 2026-07-25, live drill):** the config's model name may be a
  gemini-CLI alias the REST API doesn't serve (default `gemini-3-flash` → REST 404 while the key
  is fine). On HTTP 404 the probe retries with an auth-only `models?pageSize=1` GET — 2xx is a
  PASS annotated `auth ok; model '<m>' is a CLI alias unknown to REST` (zero tokens); anything
  else reports both codes.
- `claude` / `codex` / `grok`: cheapest possible CLI no-op prompt (OAuth-file lanes have no
  public token endpoint worth special-casing) — reuse `lane_cmd`'s own invocation with a 1-word
  prompt. Timeout 10s, **except codex: 30s** (amended 2026-07-25 — codex exec's cold start alone
  regularly exceeds 10s; a healthy authed lane FAILed the drill at 10s).
- **Probe hygiene (amended round 4):** keys reach `curl` over **stdin** (`-H @-`), never argv or a
  `?key=` query string — same doctrine as specs/01 FR-16's `-e NAME` amendment (`/proc/<pid>/cmdline`
  is world-readable to the same uid, and URLs land in proxy logs). The CLI probes cage in a
  **temporary** home cleaned by a `RETURN` trap, never `$BUSDIR/home/*` — the cage holds copied OAuth
  credentials, nothing cleaned it up, and creating it also created `$BUSDIR`, silently satisfying
  the "bus already exists" guard on the `.broken` write. The grok probe writes its refreshed
  single-use OAuth token back to the master exactly as a worker spawn does. Each lane is probed with
  the model this config would actually spawn (first `<lane>:<model>` token in the resolved chains,
  else the pinned verify default), overridable via `<LANE>_PROBE_MODEL`.
- Every probe that can bill is a logged LLM spend: one `ledger_row`-style line per probed lane
  (`doctor-probe (<lane>)`) via the existing ledger helpers — no silent spend, per
  `rules/unimatrix/model-lanes.md`.
- `doctor --live` exit code: nonzero if any probed lane FAILs (plain `doctor` stays always-0).
- A FAILed probe writes the corresponding busdir marker when a busdir exists (`.broken`, FR-3) so
  a launch immediately following the probe routes around the lane.

## FR-3 — `.broken` fast-fail marker (backlog 34)

New marker `limits/<lane>.broken`, TTL'd like `.limited` (same payload/`_stat_mtime` mechanics as
`limit_flag`/`limit_active`; default TTL 1800s — a broken lane is worth re-testing sooner than a
5h rate limit):

- Written at finalize when a lane exhibits the fast-fail signature: worker exited, answer
  unusable/absent, **and** `served_model` returns empty/null for a lane that ran (`run-<id>.jsonl`
  exists but no model ever served) — the observed grok brain058 shape. Detection lives beside the
  existing classifiers; class `lane-down` (spec 12 FR-1 vocabulary, replacing per-card re-probing).
- **Timing (amended round 4, deliberate):** the marker is written at the first *genuine failover*
  for this card — i.e. when the bounded same-lane retry budget (`MAX_LANE_RETRIES`) is about to be
  exhausted — not on the very first noisy attempt. Flagging on attempt 1 would defeat
  `MAX_LANE_RETRIES` outright: the pool would route around a lane after one transient failure, and
  a lane could never earn its retries back. "First detection" in Goals means first *confirmed*
  detection, once per lane, not once per attempt.
- The signature is only consulted when the failure is otherwise **unclassified**: an already-known
  per-card class (`false-done`, `api-error`, `server-error`) keeps its own class and never cools the
  lane — one card talking instead of editing is not evidence the lane is down.
- `codex` is excluded: `served_model` captures no field from its stream shape, so "empty" there
  carries no signal.
- `lane_blocked` treats an active `.broken` exactly like `.limited`/`.dead` — chains route around
  it; pinned cards park with the existing loud park path.
- Cleared by TTL expiry or by that lane's next successful finalize (same self-heal as `.dead`).
- tmux board renders `.broken` in the DEAD LANES section (spec 12 FR-6 board change).

## FR-4 — PAYG fallback gate at `BUDGET_USD=0` (backlog 39)

`BUDGET_USD=0` means "uncapped" for pinned/deliberate lanes (unchanged). What changes: a
**fallback hop** (chain_advance) onto a real-PAYG lane (today: kimi — the `billing:"real"` set)
while `BUDGET_USD=0` consults new conf key `PAYG_FALLBACK` (`warn` default | `allow` | `deny`):

- `warn` (default): the hop proceeds, but writes one loud stderr line
  (`PAYG fallback: <id> hopping to <lane> with no budget cap set`) and ensures the hop is
  evidenced — `limits/.fbreason-<id>` (existing FR-R9 provenance) plus the ledger row it already
  gets. Never silent.
- `deny`: the hop is refused — the chain advances past the PAYG lane as if blocked
  (`lane_blocked`-style), parking if nothing remains.
- `allow`: today's behavior, no extra output (operator explicitly accepts uncapped PAYG).
- With `BUDGET_USD > 0` the existing kimi budget gate (spec 10 FR-R5/R10) already governs; this
  FR only closes the `=0` hole.

## Acceptance criteria

1. A run whose lane set includes glm/kimi/gemini with an unreadable env-master aborts before any
   spawn, nonzero rc, stderr names path + fix; a claude/codex-only run with the same missing file
   proceeds.
2. `doctor --live` with a fake curl fixture prints PASS/latency per healthy lane, FAIL per broken
   one, exits nonzero on any FAIL, and appends one ledger line per billable probe; plain `doctor`
   makes zero network calls and still exits 0.
3. A fixture lane that runs but serves no model (empty `served_model`, unusable answer) gets
   `limits/<lane>.broken` written once; the next card's chain routes around the lane without
   spawning it; the marker expires by TTL; a later successful finalize clears it.
4. With `BUDGET_USD=0`: `PAYG_FALLBACK=warn` (default) lets a kimi fallback hop proceed with the
   loud stderr line + fbreason evidence; `deny` skips kimi in the chain (parks if last);
   `allow` is byte-identical to today. With `BUDGET_USD>0` behavior is unchanged in all modes.
5. `check.sh` green (shellcheck, full bats, PII gate).

## Open questions

None outstanding.

---

## Amendment — 2026-07-26 (FR-2 auto-wire: event-fired live probes)

**Motivation:** `doctor --live` (FR-2, shipped 2026-07-25) is opt-in; runs still burn 3 strikes per lane
on dead cheap lanes before failover — run brain058 seeded 8 cards grok/glm-first and executed 0 there,
defeating cost offload (backlog 58, MAJOR). Live probes must fire automatically to catch dead lanes
before any worker spawns.

*(Shipped 2026-07-26: `_probe_lane_event` in `swarm-run.sh` — pre-claim arm in `_try_claim_one`
immediately before `claim()`, reactive arm in `_finalize_worker` on the api-error/auth-death/
server-error classes. Marker `limits/.probed-<lane>` enforces once-per-lane-per-run; any existing
marker — including a healthy pre-claim PASS — suppresses later events (criterion 2), and a lane
already carrying `.broken`/`.dead`/`.limited` is never probed (criterion 4). New conf knob
`PROBE_AUTO`, baked default 1.)*

**NEW requirement (FR-6):** The live probe fires automatically at exactly two EVENTS, once per lane per
run:

1. **Pre-claim:** When a lane is about to receive its FIRST card of the run and has no probe result
   yet — immediately before `_try_claim_one` would spawn into it.
2. **Reactively:** On a lane's first instant-error (a 0-token synthetic result with `is_error:true`
   during finalize) — catches auth/endpoint failures that slipped the preflight.

Probe outcome feeds the EXISTING `.broken`/`.dead`/`.limited` marker machinery — nothing new consumes
it. Probes remain non-billable (event-fired, not cards); only probes that can bill are logged via
`ledger_row` (e.g., `doctor-probe (lane)`), same as FR-2 `doctor --live`.

**Non-Goals (reaffirmed, verbatim-in-spirit):**

- No standing daemon, no periodic health poller — probes run at launch (pre-claim), on demand
  (`doctor --live`), or reactively (first instant-error) only; no background polling or scheduled
  re-probes between events.
- No change to marker TTL semantics — `.limited` aging, `.dead` no-TTL, and clear conditions are untouched.
- No auto-retry/backoff logic changes — `.broken` reuses the existing `lane_blocked` routing;
  chain semantics (spec 01/10) unchanged.
- No new CLI dependency: probes use `curl` (already required by the stack) for env-key endpoints
  and the lane CLIs themselves for OAuth lanes.
- Plain `doctor` stays read-only and free — probes never run without `--live` or event trigger;
  no silent spend outside established `doctor --live` or worker-spawn paths.

**Acceptance criteria (FR-6):**

1. Kill a lane's auth (e.g., env var unset), seed a chain-first card → lane marked `.broken`
   before any worker spawn; card fails over without burning `MAX_LANE_RETRIES`.
2. A healthy-lane run performs at most one probe per lane (pre-claim fires once; healthy outcome
   suppresses reactive probe on later instant-errors).
3. SPEEDWARS ledger shows no probe rows (probes are not cards); only billable probes land in the
   ledger via existing `doctor-probe (<lane>)` entry.
4. A reactive probe on a lane that already carries a `.broken`/`.dead`/`.limited` marker is a
   no-op — probes never re-write, refresh, or clear existing markers.
