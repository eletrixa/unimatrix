# UNIMATRIX — PRD: Role Classes & Universal Fallback

**Status: SHIPPED** as specs 10 (role classes) + 11 (succession).

**Every role — not just exec — gets an automatic, qualified, same-class-first fallback. Spec 10 candidate.**
Repo: `unimatrix` · Host: WSL2 on Windows (ext4 bus) · Date: 2026-07-24
Extends: [spec 04 — Settings/Roles/Lanes/Failover](../specs/04-settings.md) (FR-6…FR-15), [spec 08 — speedwars ledger], [rules/unimatrix/model-lanes.md]. Contradicts none of them.

**Decision in one line:** promote `REVIEW` from a single pinned lane to a **same-class-first fallback chain** by rewiring the *already-shipped* `chain_current/advance/reset` + `_verify_lane_pair_fallback` primitives onto a small, greppable **lane-class map** in `swarm.conf` — closing the one real gap (a limited judge lane can stall an unattended `/swarm-loop` for a 5h window today) — while keeping cheapest-capable exec selection a **planning-time** discipline, not new runtime auto-routing. Fable roles (`PLAN`/`ORCHESTRATOR`/`AUDIT`) get **no** lane fallback by design: a Fable-session outage parks the run and notifies, because no spawned lane may adjudicate.

---

## 1. Problem & motivation

Unimatrix has real, working failover — but it is **entirely lane-level inside one `EXEC_CHAIN` role**, plus one hand-rolled `codex↔kimi` pair scoped only to the Phase-E `verify` subcommand. Everything above bulk execution is a single point of failure. Grounded in the repo's own run evidence:

- **A limited judge lane can silently stall an entire unattended run.** `swarm-loop.sh` resolves `judge="${LOOP_JUDGE:-$REVIEW}"` **once** (`swarm-loop.sh:151`) and pins it with a hard `.lane` sidecar. `VERIFY_MAP`/pair-fallback is **never consulted on this path** — it only fires in `swarm-run.sh`'s separate `verify` subcommand. A worse detail: a pinned-but-limited judge lane isn't even parked — `_try_claim_one` just `continue`s past it every poll, so the pool gate (`done_n + parked_n >= live_n`) can never close and the run spins in its `sleep 1` branch for the lane's **full TTL — up to 18000s (5h) for codex** — with no loud signal and no `WORKER_TIMEOUT_SEC` coverage (that watchdog only bounds an *already-spawned* worker). **`codex` is a measured single point of failure for review: 53 of 56 verify-branch speed rows in the whole ledger ran on it** (audited 2026-07-24: `jq` over `docs/ops/speedwars.jsonl`). If codex auth expires mid-loop, every lane's review dies at once.

- **`claude` and `gemini` have zero limit detection.** Both are absent from `limit_error()`'s case statement and fall through the bare `*) return 0` catch-all. A claude-side or gemini-side 429 is **invisible to the failover machinery** — it just re-bangs the dead lane `MAX_LANE_RETRIES` times, then parks blind. (The `claude` lane alone booked **$98.92 real Anthropic-priced dollars across 59 cards** in the ledger — it is the most expensive aggregate lane, and today it can't even signal a limit.)

- **Auth/credential expiry is a cross-lane failure class, rediscovered three separate runs.** grok OAuth expired mid-run in `aiact-054` (4 branches parked on "Not signed in", ~4 min manual recovery); a grok "auth herd" hit `brain-053-remed` (4 simultaneous spawns all failed at t=0); claude-lane OAuth expired mid-wave in `cal056` and two long cards finalized **done/0 with "OAuth session expired" as their entire answer** — the same false-done shape as every external lane.

- **The `false-done` pattern spans every lane and is caught only by the artifact/diff gate, never by the lane's own claim.** grok stopReason:Cancelled + near-zero tokens (6+ incidents, one refuting the "code cards are safe" theory); GLM `is_error:true`/429-as-answer and 529-body-as-answer; claude "Failed to authenticate" text. Any fallback design that trusts a served lane's "done" inherits this bug.

The proposed role-tiered future ("Fable = Planner/Orchestrator/Auditor/Reviewer; Kimi+Codex = high-level review/verify/spec-critique; Grok+GLM = bulk exec; claude haiku→sonnet→opus = cheapest-capable ladder; **every role and lane has a fallback**") is, concretely, **the work of closing the review-role stall gap and generalizing the one shipped pair into a named class map** — reusing existing primitives, not building a subsystem.

---

## 2. Goals / Non-goals

### Goals

1. **Every spawnable role has an automatic, qualified, same-class-first fallback** — `REVIEW`/verify/spec-critique, not just `EXEC_CHAIN`.
2. **No single lane's rate-limit window silently stalls an unattended run.** A limited pinned judge parks *loudly and promptly*, it does not spin the gate for a 5h TTL.
3. **Fallback selection stays a pure config-over-existing-lanes rewire** — zero daemon, zero MCP, zero new dependency, one greppable `swarm.conf` block, reusing `chain_*`, `verify_lane_for`, `speed_row`.
4. **Cheapest-capable exec selection stays a Fable/human planning-time judgment** (extend the `unimatrix-plan` lane-assignment table with a claude-ladder row) — never new runtime auto-routing bash.
5. **Every fallback hop is reconstructable from existing artifacts** (`speedwars.jsonl` `requested`/`served_lane`, `.bus/limits/*.limited` mtimes, `run-reviews.md`) — no new telemetry.

### Non-goals

- **No learned/embedding router, no trained classifier.** The routing literature converges that static rules capture ~80% of the value in a few dozen lines and a learned router only pays off at traffic/labeled-data volumes a single-operator tool has not reached; it would also violate the zero-daemon/zero-dependency boundary and make "what will run" un-greppable. (Answered in §3.)
- **No per-branch model auto-routing heuristics** — spec 04's ratified non-goal stands. Config sets defaults; a human or Fable picks lanes per spec.
- **No live usage-polling / predictive switching** — reactive-only failover (the provider's 429 *is* the detector), same as `EXEC_CHAIN` today.
- ~~No `PLAN`/`ORCHESTRATOR`/`AUDIT` lane fallback~~ — **OVERRIDDEN by maintainer 2026-07-24 (v2).** Robert explicitly ordered a Fable succession ladder: `PLAN → codex → kimi`, `ORCHESTRATOR → kimi`. This consciously amends spec 03's "no unattended driver in v1" boundary (maintainer sign-off given in-conversation) — but only as a **bounded continuation driver** under hard ceilings, with every degraded-mode decision provisional until Fable re-audits on return. See FR-R12/R15/R16/R17 and the §5 matrix. What stays absolute: a lane seated as PLAN/ORCH is excluded from review for that run (FR-R16), and degraded mode never pushes, never ratifies, never expands scope.
- **No hedged/duplicate dispatch.** It doubles real spend on the exact traffic it fires on, needs live p90 tracking a daemon-free bus can't cheaply maintain, and cuts against "no silent spend."
- **No new lane** (the six are frozen; a seventh needs explicit sign-off per CLAUDE.md).
- **No rename of `tier`.** Spec 03 owns "tier" for the 1-5 verification-maturity ladder. This feature uses **"class"** for the lane grouping throughout — config keys, prose, bus files.

---

## 3. Decision — role classes + universal fallback

### 3.1 The chosen architecture

**Three role classes over the six frozen lanes, plus Fable at the apex with no fallback:**

| Class | Members | Duty | Fallback shape |
|-------|---------|------|----------------|
| **Apex (Fable)** | `fable` (never spawned) | plan · orchestrate · adjudicate/audit · synthesize | **v2 succession ladder:** PLAN → codex → kimi; ORCH → kimi (bounded continuation driver, FR-R12); ladder exhausted → park + notify |
| **`CLASS_REVIEW`** | `codex kimi` | review · verify · spec-critique · hard synthesis | same-class-first chain; never seats the author; never seats the acting PLAN/ORCH lane (FR-R16); kimi gated on `BUDGET_USD`; grok = emergency judge when the class is exhausted in degraded mode |
| **`CLASS_EXEC`** | `grok glm` (+ `claude` haiku→sonnet→opus ladder) | bulk execution of tightly-spec'd cards | **grok-first for code cards** (fastest lane: 88-115s medians vs glm 247-600s), then glm → claude:haiku → sonnet → opus; prose/meta cards still pin claude:sonnet (grok false-done prose class) |

Each assignment falls out of the repo's own evidence and the model landscape:

- **Fable at the apex** matches Anthropic's own multi-agent research architecture: the lead (strongest) model **never delegates** query analysis, decomposition, resource allocation, or final synthesis — only gather/execute work parallelizes to cheaper subagents (lead-Opus + Sonnet subagents beat single-agent Opus by 90.2% on their internal eval). Delegation-failure research says the dominant multi-agent failure mode is under-specified task routing (~48% delegation accuracy in one benchmark), not weak executors — so decomposition stays on the frontier model. Tiering is a **cost/throughput lever, not a quality play**: frontier-plans-cheap-executes is Pareto-optimal on cost (one study: −65% cost/−53% latency) but never beats top-tier on judgment-heavy steps — hence adjudication never leaves the apex.
- **codex + kimi as review** — codex is the most-trusted reviewer in unimatrix's evidence (scored 5,4,5,4; caught bugs no other lane found) and kimi is the shipped FR-15 cross-family partner. Pairing gives review a cross-family fallback — the only structural fix for the empirically confirmed self- and family-preference bias in LLM judges (arXiv 2508.06709: same-family judges inflate sibling outputs; self-enhancement alone is worth 10-25 preference points). A smarter judge is not a fairer judge.
- **grok + glm as bulk exec** — 5-12× cheaper per token than Opus, but grok "explains its reasoning less than competitors" (fatal for legible critique) and GLM is weakest at open-ended multi-step planning and degrades above ~64K context. Both fit tightly-spec'd codegen, not review.
- **claude haiku→sonnet→opus ladder** is a *pure `EXEC_CHAIN` ordering convention* (`MAX_LANE_RETRIES` already walks a chain) — Opus 4.8 reserved as the top rung because it is the priciest ($5/$25) and the only model with a vendor-reported ~4× reduction in letting its own defects pass unmentioned.

### 3.2 Steelman-against objections — answered or conceded

| # | Objection (pre-mortem / steelman-against) | Verdict | Response |
|---|---|---|---|
| O1 | "A learned router would route smarter than a static class map." | **Answered** | At 187 done rows + one $0.028 kimi ping, we are far below the volume that makes a learned router pay; it also needs perpetual re-calibration against outcome data the repo lacks, and violates zero-daemon/zero-dependency. Static + fallback chains is a strict *subset* of learned-router + fallback chains — same resilience, less machinery. |
| O2 | "Cascade-then-escalate captures the value; you don't need pre-assignment." | **Answered** | The 2026 decision-theoretic result found pre-generation routing beats run-cheap-then-escalate on 4/5 benchmarks precisely because cascading always pays the discarded cheap run. Fable assigns the lane at plan time (a pre-generation route), so the cheap lane runs first by config and the expensive lane runs only on genuine escalation. |
| O3 | "The class map is just a rename of EXEC_CHAIN — needless ceremony." | **Partly conceded** | For `EXEC` it *is* essentially the existing chain — so we don't rebuild it. The net-new value is **`CLASS_REVIEW` fallback on the judge path**, which does not exist today and is the actual gap. Scope is deliberately small. |
| O4 | "kimi is unproven for high-level review (one smoke ping); classing it as a trusted judge rests on zero real cards." | **Conceded — mitigated** | kimi stays **review-pair-in-training**: it opportunistically takes verify traffic when codex is limited, its verdicts are weighted provisional in run-reviews until speedwars accumulates rows to score it on the spec-08 1-5 rubric, and every kimi hop is BUDGET-gated (real PAYG $). |
| O5 | "grok is not purely bulk-exec — it reviews well (2-write/4-review in agentbench-008)." | **Conceded — encoded** | The class map is config, so grok's write-vs-review asymmetry is encoded directly: grok write lane stays leashed behind the diff gate; grok is *review-eligible* as an escalation target but is **not** in the default `CLASS_REVIEW` (which stays the proven codex+kimi pair). |
| O6 | "A drifting verifier can silently escalate everything." | **Answered** | This is a verifier-*quality* concern, orthogonal to transport-level fallback. The artifact/diff gate + judge≠executor review — needed regardless of routing — is the guard; class selection never changes the finalize/gate contract (FR-R11). |
| O7 | "Fable is itself a single point of failure — 'every role needs a fallback' implies auto-substituting the orchestrator." | **v2: accepted — maintainer override** | Robert ordered the succession ladder 2026-07-24 (amends spec 03's boundary with sign-off). Guardrails that keep it sane: bounded mandate (finish waves, no new scope, no pushes), FR-R16 role-exclusion from review, FR-R17 everything-provisional-until-Fable-re-audit, flock-guarded single takeover. The original objection survives as the *ceiling*: a continuation driver is a caretaker, never a peer — final ratification stays with Fable. |

---

## 4. Functional requirements

All FRs reuse existing primitives (`chain_current/advance/reset`, `verify_lane_for`, `_verify_lane_pair_fallback`, `speed_row`, `limit_error`, `.bus/limits/*`). New bus state inherits the local-POSIX-fs-only constraint. Every FR is testable in `tests/swarm-lib.bats` / `tests/swarm-loop.bats` unless noted.

**FR-R1 — Class map config (Must).** `swarm.conf` gains `CLASS_REVIEW` and `CLASS_EXEC` as space-separated bare-lane lists over the six existing lanes. Defaults: `CLASS_REVIEW="codex kimi"`, `CLASS_EXEC="grok glm"`. No new lane tokens, no new spawn contract — `lane_cmd` dispatch is unchanged; classes only choose *which* lane, never *how* it spawns.
- *Acceptance:* `conf_load` with the file absent yields the two defaults; with `CLASS_REVIEW="codex gemini"` set, `/swarm config` prints the merged value; a class naming a nonexistent lane token is a loud config-load error, not a silent drop.

**FR-R2 — `REVIEW_CHAIN` on the judge path (Must).** Promote `REVIEW` resolution in `swarm-loop.sh` from a once-baked single token to a per-id fallback chain walked via the existing `chain_current/chain_advance/chain_reset` primitives against a new `.bus/limits/.judge-chain-<id>` position file, seeded from `CLASS_REVIEW` (or an explicit `REVIEW_CHAIN` override). On a detected judge-lane limit, advance to the next qualified class member instead of holding one pinned lane for the run's lifetime.
- *Acceptance:* with codex `.limited` fresh, a `/swarm-loop` iteration whose judge resolves to codex claims review on kimi within one poll; `swarm-loop`'s judge-collision check auto-substitutes the next qualified member rather than `_die()`-ing (mirrors `verify_lane_for`'s self-map fallback).

**FR-R3 — judge ≠ executor is absolute across all class logic (Must).** Any class-fallback resolution reuses the *same* self-map guard code path as `verify_lane_for` (not a reimplementation that can drift). A review-class member equal to the card's `served_lane` is skipped; if skipping exhausts the class, FR-R7 park applies.
- *Acceptance:* a card authored (served) by codex whose review resolves to `CLASS_REVIEW="codex kimi"` is reviewed by kimi; a card authored by kimi is reviewed by codex; a card authored by codex *with* kimi also limited parks loudly (never falls back onto the author).

**FR-R4 — Fallback never lands review on the card's author, including cross-family (Must).** Beyond exact-lane identity (FR-R3), a review-class fallback must not seat a **same-model-family** judge over the work: `claude`/`fable` may never be the *final* verdict on `claude:*`/`opus`-authored branches. Route those verdicts through a `CLASS_REVIEW` member (codex/kimi); if the class is exhausted, park loudly (FR-R7) rather than demote to a same-family read.
- *Acceptance:* zero `type:"verdict"` speedwars rows where the verifying lane is same-family with the generator's `served_lane` without an accompanying loud-park log line proving the class was otherwise exhausted (one `jq` join over existing rows).

**FR-R5 — kimi fallback is `BUDGET_USD`-gated (Must).** kimi is the one real-PAYG lane. A class-fallback *into* kimi is permitted only when cumulative kimi real-dollar spend for the run (recomputed at Moonshot list per model-lanes.md Ledger, **never** the envelope's claude-priced `total_cost_usd`) plus this card's estimate is `< BUDGET_USD`. `BUDGET_USD=0` = no cap (current semantics) = kimi fallback unrestricted. If the gate blocks kimi and no other qualified class member is available, park loudly (FR-R7).
- *Acceptance:* with `BUDGET_USD=0.02` and one prior kimi row at $0.028 logged this run, the next codex-limited review does **not** hand off to kimi — it parks loudly with a `budget-gated` reason; with `BUDGET_USD=0` the same handoff proceeds.

**FR-R6 — Pinned (`.lane` sidecar) cards park loudly, never chain-switch (Must).** Explicit `.lane`/verify-`.lane` sidecar pins remain hard pins (spec 01 FR-2b, spec 04 FR-15). Class logic never rewrites a pinned lane. A pinned-but-limited lane parks loudly after a bounded wait — it must **not** spin the pool gate open indefinitely (closes the §1 stall gap: today it `continue`s silently for the full TTL).
- *Acceptance:* a verify spec pinned to codex with codex `.limited` fresh is parked (board red, `.parked` touched) within a bounded wait, not held for the 18000s TTL; a periodic "waiting on limited pinned lane" notice is logged if any wait is chosen.

**FR-R7 — Exhausted class parks loudly, never silently demotes (Must).** When every qualified member of a role's class is limited / budget-gated / would seat the author, the affected review/judge card parks loudly (touch `.bus/limits/<id>.parked`, board red), exactly matching today's `VERIFY_MAP` pinned-verifier park (spec 04 FR-15). It never falls through to a weaker or same-family judge.
- *Acceptance:* both codex and kimi `.limited` fresh ⇒ the review card parks loudly with an "class exhausted" reason line; the run exits nonzero via `_check_parked`; no verdict row is emitted for that branch.

**FR-R8 — `claude` and `gemini` gain limit detection (Must).** Add `claude` and `gemini` case arms to `limit_error()` so their 429/usage-limit signatures flip `.bus/limits/<lane>.limited` and participate in chain fallback — closing the catch-all gap. `claude`: match `rate_limit`/"usage limit"/"OAuth session expired"/"Failed to authenticate" (the last two are the cal056 false-done auth signatures) → limit + short park; `gemini`: match its rate/quota signatures. Auth-expiry signatures flip a distinct `.bus/limits/<lane>.dead` flag (no TTL, cleared by next invocation/operator) so a dead credential does not consume the transient strike budget.
- *Acceptance:* a synthesized claude "OAuth session expired" answer sets `claude.dead` and does **not** finalize as done/0; a claude `rate_limit_exceeded` flips `claude.limited` and routes the next spec to the fallback; today's silent `*) return 0` path no longer reached for these two lanes.

**FR-R9 — Every fallback hop logs identically to today's ledger contract (Must).** Extend the `speed_row()` emission point so judge/review branches emit the same `requested` vs `served_lane`, `pinned`, and a `fallback_reason` field (`limit`/`dead`/`budget-gated`/`author-collision`/`class-exhausted`) — today it fires only from `_finalize_worker` for exec-pool branches. Every hop is one ledger line: lane switched, why, cost (spec 04 FR-12).
- *Acceptance:* a codex→kimi review handoff produces a speedwars row with `requested:"codex"`, `served_lane:"kimi"`, `fallback_reason:"limit"`; a `jq` count of same-class vs cross-class vs served-on-requested is computable run-wide. Note: `type:"verdict"` rows today carry **no verifier-lane field at all** (audited 2026-07-24) — FR-R9 must add one (`verify_lane`) or metrics 2/6/7 are uncomputable.

**FR-R10 — Billing-lane marker on every fallback row (Must).** Tag each fallback ledger row with a billing-lane marker distinguishing **real-$** (kimi) from **pool-metered** (glm/grok/codex/claude-sub). A class-fallback landing repeatedly on kimi must be auditable as an actual-spend trend, not folded into a generic "a fallback happened" count.
- *Acceptance:* kimi rows carry `billing:"real"` with a Moonshot-recomputed `cost_usd`; a run's total real-$ is a single `jq` sum filtered on `billing=="real"`.

**FR-R11 — Class selection never changes the finalize/gate contract (Must, non-negotiable carry-over).** A branch's outcome is still decided by artifact/diff presence at the orchestrator gate (the documented grok/GLM false-done rule: "never trust bus state, diff the write target"), never by which class-member lane claims "done." One generic unusable-answer classifier — matching auth/error text (`OAuth session expired`, `Failed to authenticate`, `is_error:true`, 429/529-as-answer) **and** requiring a non-empty path-confined diff for any `.write` card — gates acceptance for *all* lanes and *all* roles, not per-lane patches.
- *Acceptance:* a served "done" whose write target's mtimes are untouched is rejected regardless of served lane/class; the classifier is a single shared function, exercised by a bats case per known false-done signature.

**FR-R12 — Fable succession ladder (v2, Must — maintainer-ordered 2026-07-24).** `PLAN_CHAIN="fable codex kimi"`, `ORCH_CHAIN="fable kimi"`. Fable stays sole apex while alive. When the Fable session is limited/dead mid-run (detected per FR-R15), a **continuation driver** takes over: kimi seats as ORCHESTRATOR (it rides the `claude` binary, so it inherits the full agentic harness — the natural stand-in), codex seats as PLAN for spec patches (→ kimi if codex limited). The continuation driver runs under a **bounded mandate**: finish in-flight waves, run the gates/tests, park anything ambiguous; **no new scope, no spec lifecycle changes, no pushes, no destructive ops**; `MAX_ITERATIONS`/`BUDGET_USD` ceilings apply unchanged. Ladder exhausted (kimi also limited) → park + notify, as v1.
- *Acceptance:* with Fable heartbeat stale (FR-R15) and codex/kimi live, the watchdog spawns the continuation driver with a handoff prompt built from bus state; a simulated all-limited state parks the run; a degraded-mode driver attempting `git push` or a spec status change is refused by its own mandate prompt + verified absent from the run transcript.

**FR-R15 — Orchestrator heartbeat + takeover watchdog (v2, Must).** Fable touches `.bus/heartbeat` at every gate/poll. A cron-armed watchdog (one-shot per run, installed at run start, removed at run close — precedent: agentbench-008's rate-limit wake-up cron) fires when heartbeat age > `ORCH_TAKEOVER_MIN` (default 20) with the run incomplete, and walks `ORCH_CHAIN`. This is the one sanctioned standing-trigger exception to the no-daemon rule (maintainer sign-off 2026-07-24); unattended-run containment rules (env scrub, `GEMINI_SANDBOX=docker` for any gemini card) apply to everything it spawns.
- *Acceptance:* bats-simulated stale heartbeat triggers exactly one takeover spawn (flock-guarded — no double-driver); a fresh heartbeat suppresses it; the cron entry is provably gone after run close.

**FR-R16 — Role-level judge ≠ executor: acting PLAN/ORCH lanes are excluded from review (v2, Must).** Whichever lane is seated as PLAN or ORCHESTRATOR for a run is removed from `CLASS_REVIEW` resolution for that run. Concretely: codex orchestrating/planning ⇒ review falls to kimi (then grok as emergency judge, then park); kimi orchestrating ⇒ review falls to codex (then grok, then park). This generalizes FR-R3 from card-level to role-level — the planner may not grade work executed under its own plan's judgment calls.
- *Acceptance:* with `PLAN=codex` seated, a review card resolving to codex is skipped to kimi with `fallback_reason:"role-collision"`; with both codex and kimi seated/limited, grok takes the review (degraded-mode promotion) or the card parks.

**FR-R17 — Degraded-mode work is provisional until Fable re-audit (v2, Must).** Every speedwars row and bus finalize written under a continuation driver carries `degraded:true`. Nothing lands as ratified: commits stay in the run's scratch worktree, verdicts count as provisional, `run-reviews.md` entry is deferred. On resume, Fable re-audits the degraded window first (diff the worktree, re-run gates, confirm or re-open verdicts) before any new work.
- *Acceptance:* a `jq` filter on `degraded==true` reproduces the exact degraded window; a resume checklist item in the handoff file blocks new-wave planning until the re-audit is logged.

**FR-R13 — `/swarm config` prints the resolved class map + live availability (Should).** `/swarm config` additionally prints each class, its ordered members, and each member's live `.limited`/`.dead`/available state (reading the same `.bus/limits/*` files) so "what will actually run" stays one command away, now covering classes.
- *Acceptance:* `./swarm-run.sh config` output includes a `CLASS_REVIEW: codex(available) kimi(limited 4m)` line derived from real flag mtimes.

**FR-R14 — Cheapest-capable exec stays a planning-time discipline (Must).** No runtime auto-selection bash. Selection is encoded by extending `unimatrix-plan`'s existing Step-2 lane-assignment table with a claude haiku→sonnet→opus row and a "pick the cheapest model you are ≥90% confident can do the card" note. Preserves spec 04's non-goal. Two routing-literature rules are pinned into the skill text: (a) the C1-C4 complexity label is **upfront/pre-generation routing** — the strongest 2026 result (arXiv 2605.06350) shows pre-generation routing beats try-cheap-then-escalate on 4/5 benchmarks because a cascade always pays for the discarded cheap run; (b) escalation, when it happens, is gated on **execution feedback** (tests/exit codes/diff gate/reviewer rejection) — never on a lane's self-reported confidence, which the 2025-26 calibration literature converges on as unreliable. Periodically recalibrate the C-label→lane mapping from speedwars outcome rows (the ledger *is* the held-out outcome dataset the threshold rule demands).
- *Acceptance:* the `unimatrix-plan` SKILL table contains the claude-ladder row + the two routing rules; no new selection branch appears in `swarm-run.sh`/`swarm-lib.sh` (grep).

---

## 5. Fallback matrix (per role)

Read left→right; the first qualified, non-limited, non-author, budget-passing lane wins. "Author" = the card's `served_lane` **and** its model family. All pins park loudly, never chain-switch.

| Role | Primary | Fallback chain (same-class first) | Terminal when exhausted |
|------|---------|-----------------------------------|-------------------------|
| **PLAN** | `fable` | → `codex` → `kimi` (FR-R12; bounded mandate, spec patches only) | **Park run + notify.** Manual resume. |
| **ORCHESTRATOR** | `fable` | → `kimi` (FR-R12/R15; claude-binary agentic harness, bounded continuation driver) | **Park run + notify.** |
| **AUDIT** (final synthesis) | `fable` | synthesis: → seated ORCH lane, **provisional only** (FR-R17); **final verdict on claude/opus work routes to `CLASS_REVIEW`** (codex→kimi) per FR-R4 | Verdict falls to FR-R7 park if class exhausted; Fable re-audits everything on resume. |
| **REVIEW / verify / spec-critique** | mapped `CLASS_REVIEW` member (default codex) | remaining `CLASS_REVIEW` members, skipping author + same-family + limited + `.dead` + **acting PLAN/ORCH lanes (FR-R16)**; kimi only if `BUDGET_USD` headroom; then grok as emergency judge (degraded mode only) | **Park card loudly** (never demote to weaker/same-family judge). |
| **EXEC (bulk)** | `grok` (code cards — fastest lane) | → `glm` → `claude:haiku` → `claude:sonnet` → `claude:opus`; prose/meta cards pin `claude:sonnet` from the start (grok false-done prose class); kimi tail only under `BUDGET_USD` headroom; codex stays reserved for review/plan seats | **Park card in `queue/`, board red** (spec 04 FR-10). |

Hard invariants baked into every row:
- **judge ≠ executor, absolute** (FR-R3) — reuses the one shared self-map guard.
- **fallback never lands review on the card's author**, exact-lane or same-family (FR-R3/FR-R4).
- **kimi fallback requires the `BUDGET_USD` gate** (FR-R5).
- **pinned `.lane` sidecars park loudly, never chain-switch** (FR-R6).
- **exhausted class parks loudly, never silently demotes** (FR-R7).
- **Fable roles never auto-substitute a spawned lane** (FR-R12).

---

## 6. Config surface

### New / changed `swarm.conf` keys

| Key | Purpose | Default | Change |
|-----|---------|---------|--------|
| `CLASS_REVIEW` | review/verify/spec-critique lane class (ordered) | `"codex kimi"` | **new** |
| `CLASS_EXEC` | bulk-exec lane class (documentation of `EXEC_CHAIN`'s membership) | `"grok glm"` | **new** |
| `REVIEW_CHAIN` | optional explicit override of the judge fallback order (else derived from `CLASS_REVIEW`) | *(unset → `CLASS_REVIEW`)* | **new, optional** |
| `REVIEW` | *(unchanged)* now the *primary* of the review chain, not the sole lane | `codex:default` | semantics widened |
| `EXEC_CHAIN` | *(unchanged)* — claude ladder is an ordering convention within it | `"claude:haiku codex:default"` (stranger-safe; grok/glm join it on boxes with those keys) | doc note only |
| `BUDGET_USD` | *(unchanged)* now also gates kimi *fallback-in* (FR-R5) | `0` (no cap) | reused |
| `VERIFY_MAP` | *(unchanged)* codex↔kimi pair generalizes to class rule (FR-R3) | `"claude:codex codex:kimi gemini:claude glm:codex grok:codex kimi:codex"` | reused |

| `PLAN_CHAIN` | v2 Fable succession for PLAN | `"fable codex kimi"` | **new (v2)** |
| `ORCH_CHAIN` | v2 Fable succession for ORCHESTRATOR | `"fable kimi"` | **new (v2)** |
| `ORCH_TAKEOVER_MIN` | heartbeat staleness before the FR-R15 watchdog fires | `20` | **new (v2)** |

New bus files (v2): `.bus/heartbeat` (Fable gate/poll touch), `degraded:true` field on speedwars rows written under a continuation driver.

### New / reused bus files (all local-POSIX-fs only)

| Path | Purpose | Status |
|------|---------|--------|
| `.bus/limits/.judge-chain-<id>` | per-id review fallback position (sibling to `.chain-<id>`) | **new** |
| `.bus/limits/<lane>.dead` | no-TTL auth-dead flag (claude/gemini/any), cleared by next invocation or operator | **new** |
| `.bus/limits/<lane>.limited` (+`.evidence`) | transient limit flag + TTL | reused (now also claude/gemini) |
| `.bus/limits/<id>.parked` | loud park marker (review + exec) | reused |
| `.bus/limits/<lane>.strikes` | per-lane strike ledger | reused |

`speed_row()` gains fields `fallback_reason`, `billing` (FR-R9/R10). No new files beyond the two above; everything else is a rewire.

---

## 7. Risks & mitigations (ranked)

| # | Risk | Sev | Mitigation |
|---|------|:---:|-----------|
| 1 | **Silent judge stall persists** — a rewire misses a pinned-limited path and the pool gate still spins for a 5h TTL. | **High** | FR-R6 bounded-wait-then-park + a `swarm-loop` bats case that asserts a limited pinned judge parks within N polls, not TTL; the pool gate must count parked-unclaimed judge specs toward closure. |
| 2 | **False-done ships through the new review path** — a class member returns auth-error-as-answer and is accepted. | **High** | FR-R11 single shared unusable-answer classifier (text-signature + diff-presence) gates *all* roles; bats case per known signature (grok-Cancelled, GLM is_error/529, claude OAuth-expired). |
| 3 | **kimi real-$ silently rises** — repeated codex-limited runs fall back onto PAYG kimi. | **High** | FR-R5 `BUDGET_USD` gate + FR-R10 `billing:"real"` marker; success-metric 5 tracks kimi $/run pre-vs-post and must stay flat or be explained. |
| 4 | **Correlated review blind spot** — kimi (unproven judge, one smoke ping) rubber-stamps when codex is limited. | Med | O4 mitigation: kimi verdicts weighted provisional in run-reviews until scored on the spec-08 rubric; cross-family pairing (codex/kimi) avoids same-family bias; artifact gate is the real backstop. |
| 5 | **Limit-detection misfire** — a watchdog-SIGKILL'd worker's truncated stream reads as a genuine limit (the aiact-054 item-9 near-miss), cooling a healthy lane for 5h. | Med | Distinguish `.dead` (auth, no-TTL) from `.limited` (transient, TTL); require the 2-strike rule (FR-9 carry-over) before flipping; never trust a killed process's truncated output as a limit signal. |
| 6 | **Config drift** — a class names a lane that lacks the role's capability. | Med | FR-R1 loud config-load validation (class member must be a real lane token); `/swarm config` (FR-R13) surfaces the resolved map. |
| 7 | **Naming collision with spec 03 `tier`.** | Low | Use "class" everywhere (config keys, prose, bus files) — enforced by this PRD and a grep in review. |
| 8 | **(v2) Runaway/rogue continuation driver** — a kimi orchestrator loops, spends PAYG dollars, or lands wrong work while nobody watches. | **High** | Bounded mandate prompt + `MAX_ITERATIONS`/`BUDGET_USD` ceilings + kimi spend is real-$ visible (FR-R10) + FR-R17 provisional-only + flock single-takeover + notify-on-takeover so Robert knows within one heartbeat window. |
| 9 | **(v2) Double-driver race** — Fable comes back while the continuation driver is mid-wave. | Med | Takeover flips `.bus/orch-seat` (flock-written, holds seated lane + pid); a resuming Fable reads it first, drains/stops the driver, re-audits (FR-R17), then reclaims the seat. |
| 10 | **(v2) grok-first exec raises false-done exposure** — fastest lane has the worst false-done record. | Med | FR-R11 artifact/diff finalize gate is a hard precondition for grok-first ordering (ship it in the same wave); prose/meta cards never route to grok; composite signature detector (wall<30s + tokens_out<2.5k + zero tool calls + untouched targets). |

---

## 8. Success metrics (all measurable today from bus/ledger/speedwars)

1. **Zero avoidable stalls** — 0 parked/failed `speedwars` outcomes traceable to a role whose same-class sibling's `.limited` flag was **not** set at that timestamp (join `outcome`+ts against `.bus/limits/*.limited` mtimes).
2. **Fallback three-way split** — per finalized branch: served-on-requested / same-class fallback / cross-class fallback, from `requested` vs `served_lane` — now populated run-wide (review + exec), not exec-only.
3. **Cheapest-capable hit rate** — % of C1/C2-complexity cards (spec-08 rubric, in run-meta rows) served by the cheapest class without escalation.
4. **Recovery latency** — median wall-clock between a `.limited` mtime and the next successful claim on the fallback lane for the *same role* — must beat the manually-logged `aiact-054` intervention times (grok device-code re-auth ~10 min) by definition once automated.
5. **kimi real-$ per run** (docs/ops/llm-runs.md) pre-vs-post — must stay flat or be explained by FR-R5/R10, never silently rise.
6. **Review coverage rate** — % of exec branches with a `type:"verdict"` speedwars row — must **not** drop after classes ship (no branch left unreviewed because both review-class lanes were busy without a loud park).
7. **Zero same-family verdicts** — 0 `type:"verdict"` rows where verifier is same-family with the generator's `served_lane` absent a loud-park line proving class exhaustion (one `jq` join).

---

## 9. Open questions

- **[NEEDS CLARIFICATION]** Should grok be *review-eligible as an escalation target* when both codex and kimi are exhausted (its agentbench-008 review score was 4/5), or does an exhausted `CLASS_REVIEW` always park (current FR-R7)? Default: **park** — grok's write lane is leashed and its review promotion is unproven at scale.
- **[NEEDS CLARIFICATION]** When `BUDGET_USD=0` (no cap) *and* codex is limited, is unrestricted kimi fallback acceptable, or should a soft default kimi ceiling apply even under "no cap"? Default: unrestricted (matches current `BUDGET_USD=0` semantics), FR-R10 marker makes it auditable.
- **[NEEDS CLARIFICATION]** Bounded-wait duration for a pinned-limited judge before FR-R6 park — a fixed small window (e.g. 120s), or `min(WORKER_TIMEOUT_SEC, provider retry-after)`? Default: fixed 120s, tuned from run-evidence.
- **[NEEDS CLARIFICATION]** Should `AUDIT`'s final-verdict-routing (FR-R4) reuse the same `.judge-chain-<id>` file as `REVIEW`, or a separate `.audit-chain-<id>`? Default: reuse — same class, same mechanism, less state.
- **[NEEDS CLARIFICATION]** Do we backfill `speedwars` review/judge rows for historical runs to establish metric-2/6 baselines, or baseline forward-only from the first post-ship run? Default: forward-only; the existing 359 rows already give an exec baseline.

---

## 10. Build phases (red-green-double-refactor)

Spec-driven, main-only, `bats tests/` green before every commit. This is a rewire of shipped primitives — small waves.

| Wave | Milestone (done = observable) | Gate |
|------|-------------------------------|------|
| **W0 — Spec** | Write `specs/10-role-classes.md` (Draft→Active on sign-off) with the FR-Rxx set, cross-referencing spec 04 FR-13/14/15 as precedent and spec 08 as measurement substrate. Resolve the §9 defaults with the maintainer. **Do not implement yet.** | Maintainer approves lifecycle Draft→Active. |
| **W1 — Red** | Failing bats for: FR-R2 judge-chain advance, FR-R3/R4 author + same-family skip, FR-R5 budget gate, FR-R6 pinned-limited park-not-spin, FR-R7 class-exhausted park, FR-R8 claude/gemini limit+dead detection, FR-R11 shared unusable-answer classifier (one case per known false-done signature). | All new tests present and red. |
| **W2 — Green** | Minimum code to pass: add `CLASS_REVIEW`/`CLASS_EXEC`/`REVIEW_CHAIN` to `conf_load`; rewire `swarm-loop` judge resolution onto `chain_*` + `.judge-chain-<id>`; generalize `_verify_lane_pair_fallback`→class rule reusing the self-map guard; add claude/gemini arms + `.dead` flag to `limit_error()`; add the shared unusable-answer classifier; extend `speed_row()` with `fallback_reason`+`billing`; `BUDGET_USD` kimi gate. | `bats tests/` green; `shellcheck -x` clean on all 5 scripts. |
| **W3 — Refactor #1 (specs-adherence)** | Re-read spec 10 + spec 04; verify no contradiction, every FR-Rxx acceptance criterion demonstrably met, `/swarm config` (FR-R13) prints the class map + live state. Fix any divergence in code **or** spec (update spec alongside code). | Every acceptance criterion checked. |
| **W4 — Refactor #2 (rules-adherence)** | Re-read `rules/unimatrix/model-lanes.md` + `bus-discipline.md` + `loop-discipline.md`: confirm judge≠executor is the *shared* guard (not a fork), pins never chain-switch, no worker sources `$ENV_MASTER_FILE`, `.bus` stays local-POSIX, file-header standard on any touched file. Extend `unimatrix-plan` table with the claude-ladder row (FR-R14). | Rules pass; no drift. |
| **W5 — Close-out** | `CHANGELOG.md [Unreleased]` entry; `docs/versions.md` if any pin moved; run `/simplify` then a **codex** review pass (cross-family, per delegation policy — codex reviews unimatrix builds), apply **all** findings; one real `/swarm-loop` smoke with codex forced-limited to prove kimi fallback fires under the budget gate and logs FR-R9/R10 rows; append a run-review + a lesson to `unimatrix-plan`'s Lessons ledger. | Green tests, applied findings, one live fallback proven end-to-end. |
| **W6 — Succession (v2, separate spec 11)** | FR-R12/R15/R16/R17 as their own spec + build: heartbeat touch, takeover watchdog (one-shot cron, flock-guarded), `.bus/orch-seat`, bounded-mandate handoff prompt template, `degraded:true` plumbing, Fable resume/re-audit checklist. Ships **after** W1-W5 are proven — the class-fallback layer is its dependency (FR-R16 resolves through it). Live drill: kill the session mid-toy-run, verify kimi takes over, finishes the wave, parks cleanly, and Fable's re-audit finds the full degraded window. | Takeover drill passes end-to-end; no double-driver; degraded work fully reconstructable. |

*Fable roles carry no fallback by architecture (FR-R12); this feature deliberately does not attempt to make the orchestrator resumable — that is a separate spec with explicit sign-off. Every assignment, gate, and park behavior above is a rewire of primitives already shipped and evidenced in `docs/ops/speedwars.jsonl` + `run-reviews.md`, not new machinery.*
