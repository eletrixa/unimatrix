# Role Classes & Universal Fallback

**Status:** Active
**Date:** 2026-07-24 (maintainer sign-off given 2026-07-24)
**Related specs:** [04-settings](./04-settings.md) (extends FR-6/7/13/14/15), [08-speedwars](./08-speedwars.md)
(measurement substrate), [03-swarm-loop](./03-swarm-loop.md) (amends the judge-collision init
contract — see §Amendment below)

---

## Overview

Unimatrix's failover today is entirely lane-level inside `EXEC_CHAIN`, plus one hand-rolled
codex↔kimi pair scoped only to the `verify` subcommand (spec 04 FR-15). Everything above bulk
execution — the `/swarm-loop` judge in particular — is a single pinned lane with no fallback.
This spec promotes `REVIEW` from one pinned lane to a **same-class-first fallback chain**, reusing
the *already-shipped* `chain_current`/`chain_advance`/`chain_reset` primitives and a small,
greppable **lane-class map** in `swarm.conf`. It also closes two adjacent gaps the same evidence
surfaced: `claude`/`gemini` have zero limit detection, and a served "done" is trusted without a
generic cross-lane usability check.

This is a rewire of shipped primitives, not a new subsystem: no daemon, no MCP, no new lane, no
runtime auto-router. The word for the lane grouping is **"class"** — never "tier" (spec 03 owns
"tier" for the 1–5 verification-maturity ladder).

## Motivation

Grounded in the repo's own run evidence (audited 2026-07-24):

- **A limited judge lane can silently stall an entire unattended run.** `swarm-loop.sh` resolves
  `judge="${LOOP_JUDGE:-$REVIEW}"` once and pins it with a hard `.lane` sidecar; `VERIFY_MAP`/pair
  fallback is never consulted on this path. A pinned-but-limited judge isn't even parked — the
  claim loop just `continue`s past it every poll, so the pool gate can spin in its `sleep 1`
  branch for the lane's full TTL — up to 18000s (5h) for codex — with no loud signal. **codex is a
  measured single point of failure for review: 53 of 56 verify-branch speed rows in the whole
  ledger ran on it** (`jq` over `docs/ops/speedwars.jsonl`).
- **`claude` and `gemini` have zero limit detection.** Both fall through `limit_error()`'s bare
  `*) return 0` catch-all — a 429 on either lane is invisible to failover; it just re-bangs the
  dead lane `MAX_LANE_RETRIES` times, then parks blind.
- **The false-done pattern spans every lane and is caught only by the artifact/diff gate, never by
  a lane's own claim.** Three distinct classes are on record: grok `stopReason:Cancelled` +
  near-zero tokens (a shape that also appears on successful grok runs — never a standalone
  signal), GLM `is_error:true`/429-as-answer and 5xx-body-as-answer, and claude "OAuth session
  expired"/"Failed to authenticate" text served as a complete "done" answer (two long cards
  finalized `done/0` on exactly this in run `cal056`).

## Goals

1. Every spawnable role in scope (REVIEW/verify/spec-critique, EXEC) has an automatic, qualified,
   same-class-first fallback.
2. No single lane's rate-limit window silently stalls an unattended run — a limited pinned judge
   parks loudly and promptly, never spins the gate for a 5h TTL.
3. Fallback selection stays a pure config-over-existing-lanes rewire: one greppable `swarm.conf`
   block, reusing `chain_*`, `verify_lane_for`, `speed_row`.
4. Every fallback hop is reconstructable from existing artifacts (`speedwars.jsonl`
   `requested`/`served_lane`, `.bus/limits/*` mtimes) — no new telemetry surface.

## Non-goals

- **No learned/embedding router, no trained classifier.** At the repo's current traffic volume a
  static rule set captures the bulk of the value in a few dozen lines; a learned router would need
  perpetual re-calibration this bus has no outcome-labeling machinery for, and would make "what
  will run" un-greppable.
- **No runtime cheapest-capable auto-selection.** Selection stays a **planning-time** discipline
  in the `unimatrix` skill (FR-R14; renamed from `unimatrix-plan` 2026-07-24) — a human or Fable picks lanes per spec at seed time; no
  new selection branch appears in `swarm-run.sh`/`swarm-lib.sh`.
- **No hedged/duplicate dispatch.** It doubles real spend on exactly the traffic it fires on and
  cuts against the no-silent-spend rule.
- **No new lane.** The six lanes are frozen; a seventh needs explicit sign-off per CLAUDE.md.
- **No rename of "tier."** Spec 03 owns "tier" for the verification-maturity ladder; this feature
  uses "class" throughout — config keys, prose, bus files.

## Deferred (out of scope for this spec)

The following PRD items are **not** covered here — they extend the Fable apex role (PLAN /
ORCHESTRATOR / AUDIT succession, an unattended continuation driver, and a standing-cron
watchdog) and carry a materially different risk profile (runaway/rogue driver, double-driver
race). They are deferred to a future **spec 11**, to be built only after this spec's W1–W5 land
and prove the class-fallback layer they depend on:

- **FR-R12** — Fable succession ladder (`PLAN_CHAIN`, `ORCH_CHAIN`, bounded continuation driver).
- **FR-R15** — orchestrator heartbeat + cron takeover watchdog.
- **FR-R17** — degraded-mode provisional work + Fable re-audit-on-resume.
- The **grok composite false-done detector** (wall<30s + tokens_out<2.5k + zero tool calls +
  untouched write targets) and any grok-as-emergency-judge promotion — this spec's class
  exhaustion always parks loudly (§Fallback matrix, decision below).
- Any other succession/heartbeat/degraded-mode content from the PRD's v2 section.

`FR-R16` is **partially** in scope: only its config-level judge-exclusion guard ships here (see
FR-R16 below); the seat-file/heartbeat-driven "acting" dynamic ships with spec 11.

---

## Requirements

All FRs reuse existing primitives (`chain_current`/`chain_advance`/`chain_reset`,
`verify_lane_for`, `_verify_lane_pair_fallback`, `speed_row`, `limit_error`, `.bus/limits/*`). New
bus state inherits the local-POSIX-fs-only constraint (rules/unimatrix/bus-discipline.md).

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-R1 | `swarm.conf` gains `CLASS_REVIEW`/`CLASS_EXEC` (space-separated bare-lane lists) and `REVIEW_CHAIN` (optional explicit override). Loud config-load validation: every token must be one of `claude\|codex\|gemini\|glm\|grok\|kimi`. | Must |
| FR-R2 | `REVIEW` resolution on the `/swarm-loop` judge path becomes a same-class-first fallback chain, walked by the existing `chain_current`/`chain_advance`/`chain_reset` primitives against the existing `limits/.chain-<id>` position file — **not** a new position-file format (deviation from the PRD, see §Deviation from PRD below). | Must |
| FR-R3 | Judge ≠ executor is enforced by one shared guard, `_judge_ok(candidate, author)`, reused by every class-fallback resolution and by `verify_lane_for`/`_verify_lane_pair_fallback` (refactored onto it — behavior byte-identical for today's inputs). Its first clause: `candidate != author` (exact lane token). | Must |
| FR-R4 | `_judge_ok`'s second clause: candidate's model family must differ from the author's (`_lane_family`: `claude`/`fable` → `anthropic`; every other lane is its own family). A same-family fallback is never seated as final verdict; class exhaustion parks instead (FR-R7). | Must |
| FR-R5 | kimi fallback is gated by `kimi_budget_ok`, which compares cumulative `limits/kimi.spend` (real-$, Moonshot list recompute — same formula `speed_row` already uses) against `BUDGET_USD`. `BUDGET_USD=0`/unset = unrestricted. `_kimi_spend_add` accumulates `limits/kimi.spend` on every kimi finalize. No per-card spend estimate. | Must |
| FR-R6 | A pinned (`.lane` sidecar) card whose lane is blocked (limited, `.dead`, or kimi-budget-blocked) is bounded-waited via `limits/<id>.waiting`, mtime-aged on every pool scan (~1s cadence), then parked loudly — it never chain-switches. New conf key `PIN_WAIT_SEC` (default 120). | Must |
| FR-R7 | When every qualified `CLASS_REVIEW` member is disqualified (limited / `.dead` / budget-gated / fails `_judge_ok`), the affected review/judge card parks loudly (`touch limits/<id>.parked`) — it never silently demotes to a weaker or disqualified judge. | Must |
| FR-R8 | `claude` and `gemini` gain case arms in `limit_error()`. `claude`: `rate_limit`/"usage limit" → `.limited` (transient, TTL); "OAuth session expired"/"Failed to authenticate" → `.dead` (no TTL, cleared by next successful finalize). `gemini`: its rate/quota signatures → `.limited`. | Must |
| FR-R9 | `speed_row()` gains `fallback_reason` (`limit\|dead\|budget-gated\|author-collision\|role-collision\|class-exhausted`) and `verify_lane` (verdict rows today carry no verifier-lane field at all — this adds one), emitted for review/judge branches exactly as it already is for exec-pool branches. | Must |
| FR-R10 | Every fallback ledger row carries a `billing` marker: `"real"` (kimi, with a Moonshot-recomputed `cost_usd`) vs `"pool"` (every other lane) — so a fallback trend landing repeatedly on kimi is auditable as real spend, not folded into a generic fallback count. | Must |
| FR-R11 | One shared `answer_unusable(...)` classifier (auth-death text signatures: "OAuth session expired", "Failed to authenticate", "Not signed in", "Please run /login"; last result event `is_error==true`; GLM 5xx/429-error-body-as-answer). Text signatures apply only to answers ≤600 chars — every observed false-done of this class is the error dump AS the whole answer; a long healthy answer quoting these strings (e.g. a review of this very feature — live false-positive 2026-07-24) must never match. The envelope `is_error` check is unconditional. plus a write-card diff gate (`limits/<id>.stamp` touched pre-spawn when a `.write` sidecar exists; finalize requires `find <target> -newer <stamp>` non-empty). Both run inside `_finalize_worker`'s existing success branch; a failure of either falls through to the existing retry/park machinery — no new outcome paths. `extract_answer` is untouched. | Must |
| FR-R13 | `/swarm config` additionally prints each class, its ordered members, and each member's live `.limited`/`.dead`/available state, reading the same `.bus/limits/*` files. | Should |
| FR-R14 | No runtime auto-selection bash. Cheapest-capable exec selection is encoded by extending the `unimatrix` skill's Step-2 lane-assignment table with a claude haiku→sonnet→opus row and the pre-generation-routing / execution-feedback-gated-escalation notes. | Must |
| FR-R16 (config-guard) | `_judge_ok`'s third clause: a candidate is disqualified if it is the current (bare) value of `$PLAN` or `$ORCHESTRATOR` **and** that value is not `fable`. Pure config read — no seat file, no heartbeat, no watchdog (those ship with spec 11). Since `PLAN`/`ORCHESTRATOR` default to `fable` (never a review candidate — it's never spawned), this clause is a no-op today unless a `swarm.conf` override manually seats a spawnable lane in either role; it lands now so `_judge_ok` needs no later signature change when spec 11 ships. | Must |

### Deviation from the PRD (FR-R2)

The PRD (`plans/003-role-tier-fallback/PRD.md` FR-R2) specifies a new
`.bus/limits/.judge-chain-<id>` position file, sibling to `.chain-<id>`. The ratified design
instead **reuses `.chain-<id>` directly** via a new seed-resolution order, generalized into
`chain_current`/`chain_advance`/`chain_reset`:

1. `limits/.chain-<id>` — current walk position, if a walk is already in progress (existing
   behavior, unchanged).
2. `queue/<id>.chain` — a new **orchestrator-pin sidecar**: a space-separated `lane:model` list,
   written by `/swarm-loop` when it seeds a review/judge card, resolved from `CLASS_REVIEW` (or an
   explicit `REVIEW_CHAIN` override) via the existing per-lane default-model helper
   (`_verify_default_model`). Absent for ordinary exec cards.
3. `$EXEC_CHAIN` — the existing global default, unchanged, and the only fallback ordinary exec
   cards ever reach.

Same semantics as the PRD's proposal (a per-id fallback chain, walkable and TTL-aware), one fewer
bus-file primitive. `queue/<id>.lane` — the **hard user pin** (spec 01 FR-2b, spec 04 FR-15) — is
untouched: it is a wholly separate, park-not-switch mechanism and never participates in this
chain walk. A judge card is either hard-pinned (`.lane`, FR-R6 bounded-wait-then-park applies) or
chain-eligible (`.chain` seed, this FR's walk applies) — never both.

### Amendment to spec 03 (judge-collision init contract)

`swarm-loop.sh`'s `_check_judge_ne_exec` (called from `cmd_init` and `cmd_iterate`) today calls
`_die` outright — "judge lane collides with EXEC_CHAIN lane ... refusing" — the moment the
configured judge shares a bare lane with any `EXEC_CHAIN` entry. This spec **amends** that
contract: a judge/exec collision (or a judge/card-author collision on the review path) now
**auto-substitutes** the first qualified `CLASS_REVIEW` member in its place, logging a loud
stderr line (matching `verify_lane_for`'s existing self-map fallback pattern), and only calls
`_die`/parks when no `CLASS_REVIEW` member passes `_judge_ok`. This also generalizes spec 04
FR-15's narrower codex↔kimi pair rule (which already declines to hard-fail, handing off to the
partner lane) into the same one-guard mechanism. See [specs/03-swarm-loop.md](./03-swarm-loop.md)
`_check_judge_ne_exec` / `cmd_init`.

---

## Fallback matrix (per role, W1–W5 scope only)

Read left→right; the first candidate that passes `_judge_ok` (FR-R3/R4/R16) and, for kimi,
`kimi_budget_ok` (FR-R5) wins. All hard pins (`.lane`) park loudly, never chain-switch (FR-R6).

| Role | Primary | Fallback chain (same-class first) | Terminal when exhausted |
|------|---------|------------------------------------|--------------------------|
| **REVIEW / verify / spec-critique** | mapped `CLASS_REVIEW` member (default `codex`) | remaining `CLASS_REVIEW` members, skipping author (exact-lane + same-family, FR-R3/R4), limited, `.dead`, budget-blocked, and seated non-fable `PLAN`/`ORCHESTRATOR` lanes (FR-R16 config-guard) | **Park card loudly** (FR-R7) — never demote to a weaker/same-family/disqualified judge; grok is **not** promoted to emergency judge in this spec's scope (deferred). |
| **EXEC (bulk)** | `EXEC_CHAIN` head (unchanged) | `EXEC_CHAIN` walk via `chain_current`/`chain_advance` (unchanged), with `.chain` sidecar support for orchestrator-seeded chains (FR-R2) | **Park card in `queue/`, board red** (spec 04 FR-10, unchanged). |
| Pinned (`.lane` sidecar) cards, any role | the pinned lane | none — bounded wait (`limits/<id>.waiting`, `PIN_WAIT_SEC`) then loud park (FR-R6) | **Park loudly** — never chain-switches, regardless of role. |
| **PLAN / ORCHESTRATOR / AUDIT** | `fable` | none in this spec's scope | N/A — Fable succession is deferred to spec 11 (FR-R12/R15/R17). |

Hard invariants baked into every row:

- **judge ≠ executor, absolute** (FR-R3) — one shared `_judge_ok` guard, no reimplementation.
- **fallback never lands review on the card's author**, exact-lane or same-family (FR-R3/FR-R4).
- **kimi fallback requires the `BUDGET_USD` gate** (FR-R5).
- **pinned `.lane` sidecars park loudly, never chain-switch** (FR-R6).
- **exhausted class parks loudly, never silently demotes** (FR-R7).
- **Fable roles carry no lane fallback in this spec** — see Deferred.

---

## Config surface

### New / changed `swarm.conf` keys

| Key | Purpose | Default | Change |
|-----|---------|---------|--------|
| `CLASS_REVIEW` | review/verify/spec-critique lane class (ordered, bare lane names) | `"codex kimi"` | **new** |
| `CLASS_EXEC` | bulk-exec lane class (documents `EXEC_CHAIN`'s membership) | `"grok glm"` | **new** |
| `REVIEW_CHAIN` | optional explicit override of the judge fallback order | *(unset → derived from `CLASS_REVIEW`)* | **new, optional** |
| `PIN_WAIT_SEC` | bounded wait (seconds) before a blocked pinned spec parks (FR-R6) | `120` | **new** |
| `BUDGET_USD` | *(unchanged key)* now also gates fallback **into** kimi (FR-R5) | `0` (unrestricted) | semantics widened |
| `REVIEW` | *(unchanged)* now the primary of the review chain, not the sole lane | `codex:default` | semantics widened |
| `EXEC_CHAIN` | *(unchanged)* | `"claude:haiku codex:default"` (shipped; baked fallback `claude:opus glm:glm-5.2` — see spec 04) | doc note only |
| `VERIFY_MAP` | *(unchanged)* the codex↔kimi pair generalizes onto the shared `_judge_ok` guard (FR-R3) | `"claude:codex codex:kimi gemini:claude glm:codex grok:codex kimi:codex"` | reused |

`CLASS_REVIEW`/`CLASS_EXEC` tokens are bare lane names; `REVIEW_CHAIN` tokens are `lane:model`
(the validated part is the bare-lane prefix before `:`). In all three, the bare lane must be one
of the six lane tokens (`claude`, `codex`, `gemini`, `glm`, `grok`, `kimi`); a class naming a
nonexistent lane token is a loud config-load error, not a silent drop (FR-R1).

### New / reused bus state (all under the run's bus dir, local POSIX fs only)

| Path | Purpose | Status |
|------|---------|--------|
| `queue/<id>.chain` | orchestrator-pin chain seed (§Deviation) | **new** |
| `limits/.chain-<id>` | per-id chain walk position — now also walked for judge/review ids, not just exec | reused, generalized |
| `limits/<lane>.dead` | no-TTL auth-death flag, cleared on that lane's next successful finalize | **new** |
| `limits/<id>.waiting` | bounded-wait marker for a blocked pinned card (FR-R6) | **new** |
| `limits/.fbreason-<id>` | `"<reason> <original_lane>"` — first-writer-wins fallback provenance, read+removed by `speed_row` | **new** |
| `limits/kimi.spend` | cumulative real-$ kimi spend this run (FR-R5) | **new** |
| `limits/<id>.stamp` | pre-spawn mtime stamp for the write-card diff gate (FR-R11) | **new** |
| `limits/<id>.parked` | loud park marker (review + exec) | reused |
| `limits/<lane>.limited` (+`.evidence`) | transient limit flag + TTL — now also `claude`/`gemini` | reused, generalized |
| `queue/<id>.lane` | hard user pin — untouched, orthogonal to `.chain` (§Deviation) | reused, unchanged |

### Speedwars fields (FR-R9/R10)

`speed_row()` gains:

- `fallback_reason` — one of `limit \| dead \| lane-down \| payg-denied \| budget-gated \| author-collision \| role-collision \| class-exhausted`, (`lane-down` = the spec-13 FR-3 `.broken` route-around, added round 4: a lane-HEALTH hop, never a spend gate; `payg-denied` = spec-13 FR-4) sourced from `limits/.fbreason-<id>` (first-writer-wins for hop reasons; `class-exhausted` is terminal and OVERRIDES a prior hop reason; consumed only when a row is actually emitted). A chain-exhausted park emits its own `outcome:"parked"` row at park time — a parked card never finalizes, so the park site is the only producer (amended 2026-07-24, r3glm review: the value previously had no producer).
- `billing` — `"real"` for kimi rows, `"pool"` for every other lane.
- `verify_lane` on `type:"verdict"` rows — today these rows carry no verifier-lane field at all;
  this is a net-new field, not a rename. **Producer split (amended 2026-07-24, r3codex):** the
  ENGINE emits `verify_lane` on review/verify-branch speed rows (`v-*` / `*-review` ids);
  `type:"verdict"` rows are ORCHESTRATOR-written at run close (spec 08) and must carry
  `verify_lane` per the `unimatrix` skill §5 — the engine never writes verdict rows.
  FR-R4/metric-7 joins run over BOTH row kinds.
- `requested` on a fallback row reflects the **original** chain head, not the intermediate hop, so
  a two-hop fallback (e.g. codex → kimi via one skipped-limited member) is still readable as one
  `requested`/`served_lane` pair per `jq` join.

---

## Boundaries

- **Always**: resolve `_judge_ok` through the one shared function (FR-R3/R4/R16) — never a
  parallel reimplementation that can drift from `verify_lane_for`'s guard; log every fallback hop
  to the run-evidence ledger (CLAUDE.md rule) and to `speedwars.jsonl` (FR-R9); keep `.chain` and
  `.lane` semantics disjoint (§Deviation).
- **Ask first**: promoting grok to an emergency judge when `CLASS_REVIEW` is exhausted (out of
  scope here by design — decision, not oversight); raising `PIN_WAIT_SEC` or widening
  `BUDGET_USD`'s kimi-gate semantics beyond what FR-R5 states.
- **Never**: let a pinned (`.lane`) card chain-switch, under any fallback reason; let a
  class-fallback resolution seat the card's author (exact-lane or same-family); let kimi fallback
  run unmetered against `BUDGET_USD`; treat a served "done" as trusted without the FR-R11
  classifier + diff gate.

---

## Acceptance Criteria

- [ ] **FR-R1:** `conf_load` with `swarm.conf` absent yields `CLASS_REVIEW="codex kimi"`,
      `CLASS_EXEC="grok glm"`; setting `CLASS_REVIEW="codex gemini"` is reflected in
      `/swarm config`; a class naming a nonexistent lane token is a loud config-load error.
- [ ] **FR-R2:** with `codex.limited` fresh, a `/swarm-loop` iteration whose judge chain seed
      resolves first to codex claims review on kimi within one poll via `chain_advance`; an exec
      card with no `.chain` seed is unaffected (regression guard on `chain_current`'s new
      fallback order).
- [ ] **FR-R3:** a card authored by codex under `CLASS_REVIEW="codex kimi"` is reviewed by kimi;
      author kimi → review by codex; author codex with kimi also limited parks loudly, never
      falls back onto the author. Existing `verify_lane_for`/`_verify_lane_pair_fallback` bats
      cases pass unchanged after being refactored onto `_judge_ok`.
- [ ] **FR-R4:** zero `type:"verdict"` speedwars rows where `verify_lane` is same-family with the
      generator's `served_lane`, absent an accompanying loud-park log line proving the class was
      otherwise exhausted (one `jq` join over rows).
- [ ] **FR-R5:** with `BUDGET_USD=0.02` and `limits/kimi.spend` already at `$0.028`, the next
      codex-limited review does not hand off to kimi — it parks loudly with
      `fallback_reason:"budget-gated"`; with `BUDGET_USD=0` the same handoff proceeds and
      `limits/kimi.spend` accumulates further.
- [ ] **FR-R6:** a verify spec pinned to codex with `codex.limited` fresh is parked within
      `PIN_WAIT_SEC` (bats: simulate elapsed `limits/<id>.waiting` mtime), not held for the
      18000s TTL; exactly one "waiting on limited pinned lane" stderr notice is logged, at marker
      creation.
- [ ] **FR-R7:** both `codex.limited` and `kimi.limited` fresh ⇒ the review card parks loudly
      with `fallback_reason:"class-exhausted"`; the run exits nonzero via `_check_parked`; no
      verdict row is emitted for that branch.
- [ ] **FR-R8:** a synthesized claude "OAuth session expired" answer sets `claude.dead` and does
      not finalize as `done`; a claude `rate_limit_exceeded` flips `claude.limited` and routes the
      next spec to the fallback; a gemini quota signature flips `gemini.limited`; the bare
      `*) return 0` path is no longer reached for either lane on these signatures.
- [ ] **FR-R9:** a codex→kimi review handoff produces a speedwars row with `requested:"codex"`,
      `served_lane:"kimi"`, `fallback_reason:"limit"`, `verify_lane:"kimi"`; a `jq` count of
      same-class vs cross-class vs served-on-requested is computable run-wide.
- [ ] **FR-R10:** kimi rows carry `billing:"real"` with a Moonshot-recomputed `cost_usd`; a run's
      total real-$ is a single `jq` sum filtered on `billing=="real"`.
- [ ] **FR-R11:** a served "done" whose answer matches an `answer_unusable` signature is rejected
      regardless of served lane; a served "done" on a `.write` card whose target's mtimes are
      untouched (`find -newer stamp` empty) is rejected regardless of served lane/class; one bats
      case per known false-done signature (grok `stopReason:Cancelled` is explicitly excluded —
      it appears on successful grok runs and is not an `answer_unusable` signature); a rejection
      falls through to the existing retry/park machinery, no new outcome path observed in bats.
- [ ] **FR-R13:** `./swarm-run.sh config` output includes a
      `CLASS_REVIEW: codex(available) kimi(limited 4m)`-shaped line derived from real
      `.bus/limits/*` mtimes.
- [ ] **FR-R14:** the `unimatrix` skill's lane-assignment table contains the claude-ladder
      row and the pre-generation-routing / execution-feedback-gated-escalation notes; `grep` over
      `swarm-run.sh`/`swarm-lib.sh` finds no new runtime selection branch.
- [ ] **FR-R16 (config-guard):** with `PLAN=codex` set (manual override), a review card resolving
      to codex is skipped to kimi with `fallback_reason:"role-collision"`; with `PLAN=fable`
      (default) `_judge_ok` never disqualifies any lane on this clause (regression guard); both
      codex and kimi seated/limited under a role-collision scenario parks — no promotion to any
      emergency judge.

**Verification commands:**

```bash
# Class map, chain-seed resolution, judge guard, budget gate, pin-wait, and the unusable-answer
# classifier are covered in tests/swarm-lib.bats; judge-collision auto-substitution and the
# .chain-vs-.lane split are covered in tests/swarm-loop.bats.
bats tests/swarm-lib.bats tests/swarm-loop.bats tests/swarm-run.bats
./swarm-run.sh config
```

---

## Open Questions

Resolved by the ratified decisions above (2026-07-24): grok is not promoted to emergency judge on
class exhaustion (default: park); `BUDGET_USD=0` means unrestricted kimi fallback; the pinned-wait
bound is a fixed `PIN_WAIT_SEC` (default 120), not a dynamic `min(WORKER_TIMEOUT_SEC,
retry-after)`. Remaining PRD open questions (AUDIT chain-file reuse, historical speedwars
backfill) apply only to the deferred Fable-succession scope (spec 11) or are non-blocking
(`Should`, forward-only baselining) — none block this spec's Active status.

None outstanding for the W1–W5 scope in this spec.

---

## Dependencies

**Internal:** [04-settings](./04-settings.md) FR-6/FR-7 (limit detection + TTL skip), FR-13
(kimi lane), FR-14 (kimi failover), FR-15 (codex↔kimi review pair — generalized here onto
`_judge_ok`); [08-speedwars](./08-speedwars.md) as the measurement substrate (`speed_row`,
`fallback_reason`/`billing`/`verify_lane` fields); [03-swarm-loop](./03-swarm-loop.md) (amended —
see §Amendment); `rules/unimatrix/model-lanes.md` (spawn/failover contracts this spec does not
contradict); `plans/003-role-tier-fallback/PRD.md` (source FR set — W1–W5 subset only, §5/§6
matrix and config surface condensed here with the deviations noted above).
**External:** none beyond the six lanes' existing credentials (`OPENAI_API_KEY`,
`GEMINI_API_KEY`, `Z_AI_CODING_KEY`, `MOONSHOT_API_KEY`, grok's `~/.grok/auth.json`, claude
subscription auth) — already required by spec 04.

## Round-3 amendments (2026-07-24, backlog 27-29)

Three deltas ratified in the round-3 plan; code lands in the same wave as this note (specs first,
red-green-double-refactor):

1. **FR-R1 widened (backlog-27):** `conf_load` validation also covers `EXEC_CHAIN` (non-empty,
   bare-lane prefixes ∈ the six lanes), `REVIEW` (non-empty, bare prefix validated), and
   `VERIFY_MAP` (both sides of every pair; empty map valid). Same loud die-at-load contract —
   details in [04-settings](./04-settings.md) §Validation.
2. **FR-R11 verify-side (backlog-28):** success finalize of a `.write` card archives its target
   path to `write-<id>.txt` and **keeps** `limits/<id>.stamp` (removed from the success rm list),
   so `write_verify_spec` can scope the card's own diff: the verify prompt embeds the
   stamp-newer changed files as a `git diff` (+ `NEW FILE:` contents for untracked ones, capped
   50000 chars with `[diff truncated]`) plus the pin line "Judge ONLY this card's diff below at its
   commit — other cards edit this tree concurrently". Kills the moved-tree refutation-noise
   class (6/11 verify verdicts in the rolecls run).
3. **Orchestrator-owned surface refusal (backlog-29):** `_try_claim_one` refuses (parks loudly,
   never spawns) any card whose `.write` target path contains a `.claude` component — the claude
   write cage denies self-modification of command/skill surfaces, so such cards can only
   false-done (3/3 observed). No lane flag is set by the refusal: it is card-shaped, not
   lane-shaped.

## Amendment 2026-07-25 (backlog 53) — FR-R11 gate-`find` alignment

FR-R11's write-card diff gate and its verify-side twin walk the same tree with **different**
`find` predicates, and the gate's is the loose one:

| consumer | site | predicates |
|---|---|---|
| gate — `_write_target_changed` | `swarm-run.sh:478-484` | `find "$wtarget" -newermt "@$((stamp-1))" -print -quit` |
| verify — `_write_card_diff_section` | `src/swarm-lib.sh:1515-1518` | `find "$target" -type f -newermt "@$((stamp-1))" -not -path '*/.git/*' -not -path "$busdir/*" -not -path '*/.bus*/*' -print0` |

Without `-type f`, the write **target directory's own mtime bump** satisfies the gate — and a
directory's mtime changes when *anything* is created or removed inside it, including by a
concurrent sibling card. Without the `.git` exclusion, a `git status` refreshing `.git/index`, or
any background `git` process in the target, passes the gate with **zero artifacts produced**. The
gate is supposed to answer "did this worker write real bytes"; today it answers "did anything at all
touch this tree".

The gate's `find` adopts the twin's predicates verbatim: `-type f`, `-not -path '*/.git/*'`,
`-not -path "$BUSDIR/*"`, `-not -path '*/.bus*/*'`. `-print -quit` stays (the gate only needs
existence, not the list). Spec 14 FR-2 then narrows the same call further when a `.files` manifest
is present; this amendment fixes the whole-cage default that FR-2 falls back to.

The gate is shared by the success path and spec 01 FR-12's timeout-salvage path (one function, by
design) — so the fix tightens both at once, and the salvage path stops adopting cards that produced
nothing but a `.git/index` refresh.

**Acceptance:** a fixture where only `.git/index` was touched under the write target no longer
passes the gate (today it does); a fixture where only the target directory's own mtime was bumped —
by creating and removing a file inside it — no longer passes; a fixture with one real changed file
still passes; the timeout-salvage path exhibits the same three results, asserted through its own
call.

**Recorded decision — grok `Cancelled`+zero-tool-call detector: CUT.** Backlog-53 triage first
proposed a false-done detector keyed on a stream ending `{"type":"end","stopReason":"Cancelled"}`
with zero tool-call records. It was **rejected at adversarial review** and must not be revived in
this form: it false-positives on legitimate zero-tool read cards, is redundant for write cards (this
gate already rejects them), breaks spec 01 FR-12's timeout salvage (a killed worker's stream is
Cancelled by construction), and contradicts spec 14's Non-Goals. Backlog 53's actual root cause was
a **shared write cage** plus this loose `find` — closed by spec 14 FR-2 and the alignment above. Any
future revival must be scoped to non-salvage write paths only.

## Amendment — 2026-07-26 (FR-R15 defense-in-depth: bare sidecar tokens resolve at consumption)

A `.lane`/`.chain` sidecar can hold a BARE lane token (e.g., `codex`, `kimi` — no `:<model>` pair). When
such a token reaches `lane_cmd()` in `src/swarm-lib.sh:906`, the line

```bash
model="${lanemodel#*:}"
```

degenerates a bare token to itself: parameter expansion removes everything up to and including a
colon, but with no colon present, the token is unchanged. The lane CLI is then invoked with the lane
name as a literal MODEL id (e.g., `claude -p --model codex`), yielding:
- **codex**: `'codex' model is not supported`
- **kimi**: Moonshot 400 Unknown Model error

This burns all retries and marks the lane `.broken` after 3 strikes. Recurred in two independent runs
on 2026-07-26 (gtm-runq, fleetops016) **after** feedback was filed from the first, proving the
gap is not self-healing.

**FR-R2's sidecar contract is unchanged:** tokens SHOULD be full `lane:model` pairs. **FR-R15 (new
requirement)** is a defense-in-depth resolution layer at the one choke point ALL sidecar paths pass
through:

1. The **dispatch choke point MUST detect a colon-less token** before any claim is written.
   (Shipped 2026-07-26 in `_try_claim_one`, swarm-run.sh — one step upstream of `lane_cmd()`, which
   the E5 forensics showed is strictly better than in-`lane_cmd` detection: normalizing before
   `claim` also keeps the claim filename parseable by `_claim_meta`, whose regex requires the
   colon — a bare-token claim otherwise returns `lane=""` and blinds the reap/liveness guards.)
2. **Resolve it through `_call_lane_token`** (which resolves a bare lane via
   `_verify_default_model` — the same canonical lane→model table FR-R2's `.chain` seed resolution
   already uses), yielding a full `lane:model` pair.
3. **Emit ONE loud stderr line** naming the card id, the bare token, and the resolved model:
   ```
   lane_cmd: card <id>: bare token '<token>' resolved to '<resolved_lane:model>' (sidecar malformed; consider fixing the source)
   ```
4. **Never silently accept a token-as-model.** Rationale: one hand-written sidecar must not park a
   card when the canonical default is knowable; the loud line preserves the signal that the sidecar
   is malformed and the source should fix it.

After resolution, the full pair is used for all downstream invocations — the lane CLI sees the
correct model, the work proceeds, and the issue is logged for operator inspection.

**Acceptance criteria:**
- [ ] **Bare-token resolution:** A bats case per lane class (codex, kimi, claude, grok) writes a
      `.chain` sidecar with a BARE token, invokes `lane_cmd`, and asserts that the bare token is
      resolved to the table default (e.g., bare `codex` → `codex:default`, bare `kimi` → `kimi:kimi-k3`)
      and never to the token itself as a model.
- [ ] **Loud signal:** Each resolution emits an stderr line matching the pattern above, carrying the
      card id, original bare token, and resolved pair.
- [ ] **No degradation of full pairs:** Existing `.chain` sidecars with full `lane:model` pairs and
      hard `.lane` pins behave exactly as before — zero new stderr lines for these cases, and the
      model is not re-resolved.
- [ ] **Validator remains:** `_call_lane_token()` in `swarm-run.sh` (the cmd_call input guard) is
      unchanged and remains the planning-time validator; this amendment moves the consumption-time
      invariant to the runtime choke point, orthogonal to pre-validation.

**Relationship:** This amendment operationalizes the _one_ place every sidecar path converges
(`lane_cmd`, src/swarm-lib.sh:906) as a guard. The validator `_call_lane_token()` (swarm-run.sh) remains the
cmd_call input guard; this amendment fixes the invariant the executor never violates — a bare
token is never passed to a lane CLI as a model literal.
