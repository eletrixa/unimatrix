# Succession — Orchestrator Heartbeat, Takeover & Degraded Mode

**Status:** Active
**Date:** 2026-07-24 (maintainer sign-off given 2026-07-24, including the one-shot-cron exception
to the no-daemon boundary; source PRD `plans/003-role-tier-fallback/PRD.md` v2)
**Related specs:** [10-role-classes](./10-role-classes.md) (dependency closure — this spec builds
on the class-fallback layer and completes FR-R16's seat-file/heartbeat-driven "acting" dynamic),
[04-settings](./04-settings.md) (new `swarm.conf` keys), [03-swarm-loop](./03-swarm-loop.md)
(amended — see §Amendments below), [08-speedwars](./08-speedwars.md) (`degraded` row field)

---

## Overview

Every role in unimatrix has a fallback except the apex. `PLAN` and `ORCHESTRATOR` are pinned to
`fable` with no succession: if the Fable session goes limited or dies mid unattended run, nothing
below it notices — the run just stalls with no loud signal, because nothing is watching Fable the
way spec 10 now watches `REVIEW`/`EXEC_CHAIN`. This spec is the deferred Fable-succession scope
that spec 10 explicitly carved out (its §Deferred: FR-R12, FR-R15, FR-R17, and the seat-file half
of FR-R16). It adds a **succession ladder** for PLAN/ORCHESTRATOR, a **heartbeat + one-shot-cron
takeover watchdog** that detects a stale apex and spawns a **bounded continuation driver**, and a
**degraded-mode** contract so work done under a non-Fable seat is always provisional until Fable
re-audits it.

The word for the apex-succession slot is **"seat"** (who is currently acting in a role) and for
the mechanism as a whole **"succession"** — never "tier" (spec 03 owns "tier" for its 1–5
verification-maturity ladder; this spec does not touch that ladder).

This is a rewire-and-extend of shipped primitives (`chain_current`/`chain_advance`, `flock`,
`speed_row`, `_judge_ok`), plus exactly one new standing trigger: a single crontab line, tagged and
provably removable, which is the one sanctioned exception to the no-daemon rule (maintainer
sign-off 2026-07-24). No new lane, no MCP, no learned router.

## Motivation

- **Fable is a measured single point of failure at the apex.** Spec 10's own class-fallback layer
  only covers `REVIEW`/`EXEC_CHAIN`; a Fable outage mid-`/swarm-loop` run has no detector and no
  successor today — the loop just goes quiet.
- **A silent stall is worse than a loud degrade.** An unattended run with a dead orchestrator and
  no watchdog burns wall-clock and possibly budget with zero forward progress and zero signal.
- **Succession work must not silently outrank Fable's judgment.** A continuation driver that
  quietly pushes, changes spec status, or expands scope while Fable is unreachable would violate
  "judge ≠ executor" at the worst possible level (the apex reviewing itself by default). Every hop
  down the ladder must be bounded, logged, and provisional.

## Goals

1. A dead/limited Fable mid-run does not silently stall an unattended run — a stale apex is
   detected and handed to a bounded continuation driver within `ORCH_TAKEOVER_MIN` minutes.
2. The takeover trigger needs no standing daemon: one idempotent, tagged crontab line, provably
   installed and provably removed.
3. Continuation work is contained by construction: finish in-flight waves, run the gates, park
   ambiguity — never new scope, never a push, never a spec lifecycle change, never a destructive
   op, and always under the run's existing `MAX_ITERATIONS`/`BUDGET_USD` ceilings.
4. Every bus record produced while a non-Fable seat is acting is marked `degraded:true`, and no new
   wave plans until Fable has re-audited the degraded window.
5. Spec 10's config-level judge-exclusion guard (FR-R16) is wired to the real acting seat, not just
   a static `$PLAN`/`$ORCHESTRATOR` read.

## Non-goals

- **No new lane.** The continuation driver only ever seats an existing lane (kimi for
  ORCHESTRATOR, codex or kimi for PLAN) — the six lanes stay frozen.
- **No standing daemon beyond the one sanctioned crontab line.** `watchdog-check` is a stateless,
  idempotent, `flock`-guarded poll — it is not a long-lived process.
- **No unbounded continuation authority.** The driver never gains push rights, spec lifecycle
  authority, or scope beyond finishing what was already in flight — this is a hard boundary, not a
  default that can be widened without a fresh sign-off.
- **No automatic trust of degraded work.** Degraded output is provisional by construction; it
  becomes trusted only after Fable's logged re-audit (FR-S4), never on a timer or a vote.
- **No AUDIT lane/chain.** `swarm.conf` has no standalone `AUDIT` role (spec 04) — audit/adjudicate
  duties live inside `ORCHESTRATOR`, so `ORCH_CHAIN` already covers them; this spec does not
  introduce a fifth chain key.
- **No change to spec 10's `CLASS_REVIEW`/`CLASS_EXEC` fallback logic** — this spec only supplies
  the real seat source that FR-R16's guard reads.

---

## Config keys

New `swarm.conf` keys (loud config-load validation, mirroring spec 10 FR-R1's style — a token that
isn't one of the six lanes, or a chain that doesn't open on `fable`, is a config-load error, never
a silent drop or a silent default substitution):

| Key | Purpose | Default | Validation rule |
|-----|---------|---------|------------------|
| `PLAN_CHAIN` | PLAN succession order | `"fable codex kimi"` | first token MUST be `fable`; remaining tokens ∈ `{claude, codex, gemini, glm, grok, kimi}` |
| `ORCH_CHAIN` | ORCHESTRATOR succession order | `"fable kimi"` | same rule as `PLAN_CHAIN` |
| `ORCH_TAKEOVER_MIN` | heartbeat staleness threshold (minutes) before the watchdog acts | `20` | positive integer |

`PLAN`/`ORCHESTRATOR` (spec 04) remain the single-value role keys read by everything that doesn't
need succession context; `PLAN_CHAIN`/`ORCH_CHAIN` are additive — they are only consulted by the
watchdog (FR-S2) when Fable's heartbeat has gone stale. Neither chain changes what `PLAN`/
`ORCHESTRATOR` resolve to while Fable is alive.

## Bus state additions

All new bus state lives under the run's bus dir, on a local POSIX filesystem only (rules/
unimatrix/bus-discipline.md's constraint applies unchanged — never a 9p/drvfs/NFS mount).

| Path | Purpose | Status |
|------|---------|--------|
| `.bus/heartbeat` | mtime touched by the ORCHESTRATOR (never the exec pool) at every gate/poll | **new** |
| `.bus/orch-seat` | single line `<seat> <epoch>` — `fable` while Fable is alive, or a bare lane once the watchdog hands off | **new** |
| `.bus/limits/takeover.lock` | `flock` guard around the watchdog's check-then-spawn critical section | **new** |
| `.bus/loop/handoff-degraded.md` | continuation driver's account of what it did; blocks new-wave planning until Fable's re-audit is logged | **new** |
| `.bus/watchdog.env` | resolved config plane persisted by `watchdog-arm` (`CONF`, `ORCH_CHAIN`, `PLAN_CHAIN`, `ORCH_TAKEOVER_MIN`, `BUDGET_USD`, opt. `ENV_MASTER_FILE`/`KIMI_MAX_THINKING_TOKENS`/`LEDGER_FILE`; `%q`-quoted, atomic tmp+mv) — `watchdog-check` sources it so an env-less cron tick sees the arming run's real chains/budget/keys, not stale defaults | **new** |
| `degraded` field on speedwars finalize/verdict rows | `true` while orch-seat is non-fable; omitted (or `false`) under Fable | **new field on existing rows (spec 08)** |
| `queue/<id>.chain`, `limits/.chain-<id>`, `_judge_ok`, `CLASS_REVIEW` | reused unchanged from spec 10 as the driver's own review/verify substrate — the continuation driver's in-flight waves still resolve review through spec 10's guard | reused |

---

## Requirements

### FR-S1 — Fable succession ladder

*(PRD FR-R12, Must)* `PLAN_CHAIN="fable codex kimi"`, `ORCH_CHAIN="fable kimi"`. Fable stays the
sole apex while alive — nothing in this FR changes normal-path behavior. When the Fable session is
limited or dead mid-run (detected per FR-S2), a **continuation driver** takes over: kimi seats as
ORCHESTRATOR (kimi rides the `claude` binary via the child-env swap, so it inherits the full
agentic harness — the only lane that can plausibly stand in for Fable's own session), and codex
seats as PLAN for spec patches, falling back to kimi if codex is also limited.

The continuation driver runs under a **bounded mandate**, enforced by the handoff prompt and by
convention, not by a new sandbox: finish in-flight waves, run the existing gates/tests, park
anything ambiguous. It never takes on new scope, never changes a spec's lifecycle status, never
pushes, and never runs a destructive op. The run's existing `MAX_ITERATIONS`/`BUDGET_USD` ceilings
apply to it unchanged — the ladder does not reset or extend either budget.

If the ladder is exhausted (kimi also limited/dead/budget-gated), the run parks loudly and
notifies — there is no promotion past kimi and no silent demotion to a weaker or disqualified seat,
the same terminal discipline spec 10 already uses for `CLASS_REVIEW` exhaustion.

**Acceptance:**
- With Fable's heartbeat stale and codex/kimi both live, the watchdog spawns the continuation
  driver with a handoff prompt built from bus state (queue/claimed/done listing + parked reasons +
  the goal file).
- A simulated all-limited state (codex and kimi both `.limited`/`.dead`/budget-gated) parks the run
  instead of spawning a driver.
- The mandate prompt handed to the continuation driver explicitly forbids push and spec
  lifecycle-status changes — a bats/grep check over the generated prompt confirms both phrases are
  present.

### FR-S2 — Orchestrator heartbeat + takeover watchdog

*(PRD FR-R15, Must)* Detection and takeover are split into five small, greppable pieces, all new
`swarm-ctl` verbs:

| Verb | Behavior |
|------|----------|
| `swarm-ctl heartbeat <busdir>` | touches `.bus/heartbeat`; if `.bus/orch-seat` is missing, writes `fable <epoch>` — called by the ORCHESTRATOR at every gate/poll, never by the exec pool |
| `swarm-ctl watchdog-arm <busdir>` | idempotent: installs exactly one crontab line tagged `# unimatrix-watchdog <busdir>` running `swarm-ctl watchdog-check <busdir>` every 5 minutes; re-arming with the tag already present is a no-op — no duplicate lines ever |
| `swarm-ctl watchdog-check <busdir>` | the poll body (below) |
| `swarm-ctl watchdog-disarm <busdir>` | removes the tagged crontab line; provable — after disarm, `crontab -l` contains no line tagged for this busdir |

The loop driver additionally keeps the heartbeat fresh through each pool wait with a background
keepalive: a 60-second toucher started per pool run, each tick gated on `kill -0 $$` so it stops
within a minute of the driver itself dying. A single chain walk can legitimately outlive
`ORCH_TAKEOVER_MIN` (one touch per iterate would then trigger a false takeover against a healthy
driver), but a heartbeat that outlived a crashed driver would defeat the watchdog entirely — the
`kill -0` gate keeps a genuine crash going stale on schedule.

`watchdog-check` exits 0 silently (no action, no log noise) when any of: heartbeat age ≤
`ORCH_TAKEOVER_MIN` minutes; the run is already complete (no files in `queue/` and `claimed/` and
no open loop run — a `loop/<run-id>/criteria.md` without a sibling `COMPLETE.md`/`HALTED.md`; an
empty bus alone is not completion, because a loop driver spends most of its wall clock between
pool runs with `queue/`/`claimed/` empty); or
`orch-seat` is already a non-fable lane (a takeover fires **at most once per run** — no repeat
handoffs down the same ladder). Otherwise it takes `flock` on `.bus/limits/takeover.lock`,
**re-checks heartbeat age under the lock** (so two concurrent cron ticks can never both spawn a
driver), walks `ORCH_CHAIN` past `fable`, skipping limited/dead/budget-gated lanes, rewrites
`orch-seat` to `<lane> <epoch>`, and spawns the continuation driver on that lane (kimi = the
claude-binary child-env swap per `rules/unimatrix/model-lanes.md`) with the bounded-mandate handoff
prompt from FR-S1. If `ORCH_CHAIN` is exhausted, it touches a loud park marker and writes to
stderr — no driver is spawned.

`watchdog-disarm` is part of every run close, normal or degraded — an armed watchdog left running
past a finished run is exactly the kind of silent standing trigger the no-daemon rule exists to
prevent, so disarm is not optional cleanup.

This is the one sanctioned standing-trigger exception to the project's no-daemon rule (maintainer
sign-off 2026-07-24); the unattended-run containment CLAUDE.md already requires applies to
everything the watchdog spawns unchanged — env scrub of credential/config dirs before spawn, and
`GEMINI_SANDBOX=docker` for any gemini card the continuation driver's waves touch.

**Acceptance:**
- A bats-simulated stale heartbeat triggers exactly one takeover spawn, proven flock-guarded (two
  concurrent `watchdog-check` invocations against the same stale heartbeat produce one spawn, not
  two).
- A fresh heartbeat suppresses the takeover entirely (no lock taken, no log line).
- After `watchdog-disarm`, `crontab -l` provably contains no line tagged for that busdir.
- `crontab` is faked in tests via the same PATH-shim pattern the existing fakes already use (see
  `tests/swarm-run.bats`) — no real crontab is touched by the test suite.

### FR-S3 — Role-exclusion seat wiring

*(PRD FR-R16, the half deferred by spec 10)* Spec 10's `_judge_ok` already disqualifies a lane
seated as a non-fable PLAN/ORCHESTRATOR from reviewing (its config-only guard clause). This spec
wires that clause to the real, live seat: the acting ORCHESTRATOR seat comes from `.bus/orch-seat`
when present and non-fable (falling back to the static `$ORCHESTRATOR` read only if `orch-seat` is
absent or still `fable`); the acting PLAN seat comes from `$PLAN` unchanged (PLAN has no
seat-file — a spec patch author is always attributable to the static config value or, once FR-S1
hands off, to the continuation driver's `codex`/`kimi` choice, which is itself logged in the
handoff prompt, not a separate seat file).

With `PLAN` (or the live orch-seat) resolved to `codex`, a review card that would otherwise
resolve to codex skips to kimi with `fallback_reason:"role-collision"` — the same mechanism and
field spec 10 already defined, now driven by live state instead of a static read. With codex and
kimi both seated/limited under a role-collision scenario, the card parks loudly — no promotion to
any emergency judge, matching spec 10's terminal discipline.

**Acceptance:**
- With `orch-seat` rewritten to `kimi` (simulating a live takeover) and a review card resolving to
  kimi, the card skips to codex with `fallback_reason:"role-collision"`.
- With `orch-seat` absent or still `fable`, `_judge_ok`'s role-collision clause never disqualifies
  any lane (regression guard — identical behavior to spec 10 FR-R16 before this spec).
- Both codex and kimi seated/limited simultaneously under a role-collision scenario parks the
  card — no emergency-judge promotion is observed in bats.

### FR-S4 — Degraded-mode provisionality

*(PRD FR-R17, Must)* Every bus finalize record and every speedwars row written while `orch-seat`
is a non-fable lane carries `degraded:true`. Rows written while Fable holds the seat carry no
`degraded` field at all (or `false`) — the field's mere presence-as-true is the signal, not its
absence. All commits made under a non-Fable seat stay in the run's scratch worktree (spec 03
FR-8's containment, unchanged) — a degraded continuation never lands directly on a shared branch.

The continuation driver writes `.bus/loop/handoff-degraded.md` on handoff-back (session end or
ladder exhaustion), describing what it did. That file **blocks new-wave planning** until Fable's
re-audit is logged: re-audit means Fable diffs the scratch worktree, re-runs the gates, and either
confirms or re-opens each verdict the driver produced. The handoff file's resume checklist always
opens with the re-audit step — nothing else on the checklist is actionable before it.

**Seat reclaim.** Once the re-audit is logged (the handoff file removed) and the next
`swarm-loop iterate` passes the handoff-degraded gate, the driver reclaims a non-fable
`orch-seat` back to `fable <epoch>` — atomically, tmp+mv same-dir rename, never a `>` truncate a
concurrent `orch_degraded` read could catch empty. Without the reclaim, every post-re-audit row
would stay `degraded:true` (violating this FR's exact-window invariant), the ex-driver lane would
stay judge-disqualified, and the watchdog's non-fable skip clause would silently swallow a second
crash. `swarm-ctl heartbeat` itself never overwrites an existing seat — reclaim happens only here,
behind the passed gate.

**Acceptance:**
- `jq 'select(.degraded==true)'` over the speedwars ledger reproduces the exact window of rows
  written under the non-fable seat — no row outside that window carries the field as `true`.
- The generated `handoff-degraded.md` contains a resume checklist whose first item is the Fable
  re-audit (diff + re-run gates + confirm/re-open verdicts) — a bats/grep check confirms the
  ordering, not just the presence of the step.

---

## Succession matrix

Read left→right; the first candidate that is live (not limited/dead/budget-gated) wins. Both rows
are the deferred continuation of spec 10's Fallback matrix, whose PLAN/ORCHESTRATOR/AUDIT row was
explicitly marked "N/A — deferred to spec 11."

| Role | Primary | Succession ladder | Terminal when exhausted |
|------|---------|--------------------|---------------------------|
| **ORCHESTRATOR** | `fable` | `kimi` (`ORCH_CHAIN`) — seated only after a heartbeat-stale takeover (FR-S2), never on a normal poll | **Park + notify** — no promotion past kimi, no silent demotion. |
| **PLAN** | `fable` | `codex` → `kimi` (`PLAN_CHAIN`) — same takeover trigger, spec-patch authorship only | **Park + notify** — same terminal rule. |
| Any card resolved through a non-fable acting seat | — | reviewed via spec 10's `CLASS_REVIEW` chain with `_judge_ok`'s role-collision clause now live (FR-S3) | **Park** — spec 10's existing class-exhaustion terminal rule, unchanged. |

Hard invariants carried over from spec 10 and extended here:

- **A takeover fires at most once per run** — no repeat handoffs down the same ladder mid-run.
- **The continuation driver never outranks Fable** — everything it produces is `degraded:true`
  until re-audited (FR-S4); nothing it does is "done" in the sense spec 03's stop rules mean.
- **Ladder exhaustion always parks loudly** — never a silent demotion to a weaker or disqualified
  seat, matching spec 10's `CLASS_REVIEW`-exhaustion discipline exactly.

---

## Test matrix

Build must include bats coverage for:

- `watchdog-arm` is idempotent — re-arming with the tag already present adds no second crontab
  line.
- `watchdog-check` is a no-op on: a fresh heartbeat; a complete run (empty `queue/` and
  `claimed/` **and** no open loop run — a `loop/<run-id>/criteria.md` without a sibling
  `COMPLETE.md`/`HALTED.md`); an already non-fable `orch-seat`.
- A stale heartbeat triggers exactly one takeover under a concurrent double-check (two
  `watchdog-check` calls racing the same stale state, guarded by `flock` on
  `.bus/limits/takeover.lock`).
- `watchdog-disarm` removes only the tagged line for its own busdir — a differently-tagged line
  (another concurrent run's watchdog) survives.
- Chain-exhausted (`ORCH_CHAIN` walked past `fable` with every remaining lane
  limited/dead/budget-gated) parks loudly with no driver spawned.
- `conf_load` validates all three new keys: a `PLAN_CHAIN`/`ORCH_CHAIN` not opening on `fable` is a
  loud config-load error; a non-lane token in either is a loud config-load error;
  `ORCH_TAKEOVER_MIN` must be a positive integer.
- `degraded` field is present (`true`) on rows written under a non-fable `orch-seat` and absent (or
  `false`) on rows written under `fable`.
- `handoff-degraded.md` is written on driver handoff-back and its resume checklist opens with the
  re-audit step.

**Verification commands:**
```bash
# Heartbeat/watchdog/seat-wiring/degraded-mode coverage lives in tests/swarm-lib.bats
# (conf_load, degraded field) and tests/swarm-ctl.bats (heartbeat, watchdog-arm/check/disarm,
# crontab faked via the existing PATH-shim fake pattern).
bats tests/swarm-lib.bats tests/swarm-ctl.bats tests/swarm-loop.bats
./swarm-run.sh config
```

---

## Boundaries

- **Always**: touch `.bus/heartbeat` from the ORCHESTRATOR at every gate/poll (never the pool);
  re-check heartbeat age under `flock` before spawning a driver; mark every degraded-window row
  `degraded:true`; disarm the watchdog at run close, normal or degraded; open the resume checklist
  with the Fable re-audit.
- **Ask first**: raising `ORCH_TAKEOVER_MIN`; widening the continuation driver's mandate beyond
  "finish in-flight, run gates, park ambiguity"; adding a fourth chain key (e.g. a standalone
  `AUDIT_CHAIN`) beyond `PLAN_CHAIN`/`ORCH_CHAIN`.
- **Never**: let the continuation driver push, change a spec's lifecycle status, expand scope, or
  run a destructive op; let a takeover fire more than once per run; leave a watchdog crontab line
  armed past run close; trust degraded-window work before Fable's logged re-audit; promote grok (or
  any lane outside `PLAN_CHAIN`/`ORCH_CHAIN`) into either apex role.

---

## Open Questions

None outstanding for this spec's scope. Spec 10's deferred open items this spec resolves: the
seat-file/heartbeat-driven "acting" dynamic for FR-R16 (FR-S3), the Fable succession ladder
(FR-S1), and the cron takeover watchdog (FR-S2). The AUDIT chain-file-reuse question spec 10 left
open is resolved by this spec's Non-goals: there is no standalone AUDIT role in `swarm.conf`
(spec 04), so no `AUDIT_CHAIN` is introduced — audit/adjudicate duties are covered by
`ORCH_CHAIN`.

---

## Amendments & Cross-refs

**Amendment to spec 03 (unattended-driver boundary).** Spec 03's Boundaries section states
"Never: run the headless (unattended) loop driver before Phase 2 containment ships." This spec
**amends** that boundary with one narrow, sign-off-recorded exception: the bounded continuation
driver defined in FR-S1 may run unattended, specifically because its mandate is structurally
bounded (no new scope, no push, no spec-status change, existing budget ceilings apply) and every
line it writes is `degraded:true` and gated behind a Fable re-audit before counting as done
(FR-S4). This is not a general lift of spec 03's containment gate — any other unattended driver
still needs Phase 2 containment before it may run.

**Cross-refs:**
- [10-role-classes](./10-role-classes.md) — dependency closure. This spec cannot ship before
  spec 10's W1–W5 land: `_judge_ok`, `CLASS_REVIEW`, and `speed_row`'s `fallback_reason`/
  `degraded`-adjacent fields are the substrate FR-S3/FR-S4 build on. FR-R16's config-only clause is
  completed here by wiring it to `.bus/orch-seat` instead of a static `$PLAN`/`$ORCHESTRATOR` read.
- [04-settings](./04-settings.md) — `PLAN_CHAIN`/`ORCH_CHAIN`/`ORCH_TAKEOVER_MIN` are additive to
  its `swarm.conf` key table; `PLAN`/`ORCHESTRATOR` keep their existing single-value semantics
  while Fable is alive.
- [08-speedwars](./08-speedwars.md) — the ledger's row schema gains one optional field, `degraded`;
  no existing field's meaning changes, and speedwars' append-only/never-fail-a-run boundaries
  apply to the new field exactly as to every other.
- `rules/unimatrix/model-lanes.md` — the kimi child-env spawn contract (`ANTHROPIC_BASE_URL`,
  tier-model envs, `MOONSHOT_API_KEY` gate) is reused unchanged for the continuation driver; this
  spec adds no new spawn shape.
- `plans/003-role-tier-fallback/PRD.md` v2 — source FR set (FR-R12/R15/R16/R17); this spec is the
  ratified, condensed W-scope those FRs land as, with the deviations and terminal-discipline notes
  spelled out above.
