---
name: unimatrix
version: 1.2.0
description: Plan AND operate unimatrix swarm runs — decomposition, lane assignment, bus setup, gates, monitoring, troubleshooting, evidence, and the cross-repo feedback drop-box. Use when Fable is about to orchestrate work through the unimatrix file-bus (/swarm, /swarm-loop, swarm-run.sh, write-capable lanes, cross-model review), when the user says "use unimatrix", "swarm this", "plan the swarm", "check the swarm", when operating or debugging a live run, or when any agent in any repo wants to send unimatrix feedback. Self-improving — append lessons after every run.
---

<!--
Fable's skill for unimatrix swarm runs — plan (decomposition → lanes → bus → gates → evidence)
AND operate (run, monitor, control, troubleshoot) AND the cross-repo feedback drop-box.

Project: unimatrix — multi-model swarm orchestrator driven from Claude Code
Module:  .claude/skills/unimatrix/SKILL.md (canonical; install copies to
         ~/.claude-acct/<acct>/skills/unimatrix/ — repo copy wins on conflict)
Deps:    swarm-run.sh, swarm-loop.sh, src/swarm-ctl, swarm.conf, rules/unimatrix/model-lanes.md,
         docs/ops/run-reviews.md, feedback/README.md
Tested:  n/a (process skill)

Key responsibilities:
- Turn a goal into a max-parallel wave plan with correct lane assignment + fallbacks
- Encode the hard rules (judge ≠ executor, confidentiality boundaries, bus hygiene)
- One-stop operate reference: invocations, config, bus layout, control verbs, troubleshooting
- Route cross-repo feedback into ~/code/unimatrix/feedback/
- Accumulate run lessons so every plan is better than the last (§Lessons ledger)

Design constraints:
- Append-only Lessons ledger — never rewrite history, add dated entries
- This skill plans + operates; execution contracts live in rules/unimatrix/model-lanes.md
-->

# unimatrix — plan the swarm, run the swarm

You are Fable: PLAN + ORCHESTRATOR (never spawned). Executors and reviewers are lanes.
Planning a run: work §1–§5 in order — every step has a hard rule learned from a real run.
Operating/debugging a live run: jump to §6. Sending feedback from another repo: §7.

## 1. Decompose for parallelism

- Cards = independently landable units with **disjoint write paths** (file-level, not
  "probably won't collide"). Two cards touching one file = one card or two waves.
- **Split any card you'd estimate >600s** of worker wall-clock (aiact-054: two C4 cards
  became the critical path; one was watchdog-killed mid-answer with the work complete).
- Waves are dependency barriers ONLY. A "conceptual phase" is not a barrier. Cheap
  critics/tests between waves are the orchestrator's job, not extra cards.
- Spike-first: any load-bearing unverified assumption (cost fields, id joins, timing)
  gets a cheap spike card BEFORE the wave that depends on it.
- Complexity-mix the run label (C1×n C2×n …, spec-08 rubric) at plan time — it drives
  timeout + lane choices and makes speedwars rows comparable.

## 2. Assign lanes

| Task smell | Lane | Why |
|---|---|---|
| Needs on-box private data (transcripts, credentials, browser, repos/ clones) | claude session agents / Fable | data never leaves the box |
| Pure-function code from a tight spec | glm write lane | cheap, good at contained TDD |
| Self-contained UI/render/CLI code | grok write lane (CODE cards only — prose/meta cards pin claude:sonnet, grok false-done prose class) or glm | speed |
| Review / audit / adversarial verify | codex (REVIEW default) + the lanes that did NOT write the card | judge ≠ executor, always |
| Web research | gemini (read-only; docker sandbox if unattended) | its niche |
| Highest-wreckage-risk core (process lifecycle, orchestration) | strongest claude tier in session | blast radius |
| Cheapest-capable exec (pick the cheapest model you are ≥90% confident lands the card) | claude haiku→sonnet→opus ladder (EXEC_CHAIN rung order) | escalate only on execution feedback |

**Routing rules (spec 10 FR-R14):**
- The C1-C4 complexity label is **pre-generation routing** — assign the lane at plan time; never
  run-cheap-then-escalate by default (a cascade always pays for the discarded cheap run —
  arXiv 2605.06350: upfront routing beat cascading on 4/5 benchmarks).
- Escalation, when it fires, is gated on **execution feedback only** (test failure, diff-gate
  reject, reviewer refutation) — never on a lane's self-reported confidence (2025-26 calibration
  literature: verbalized confidence is unreliable).
- Recalibrate the C-label→lane mapping periodically from speedwars outcome rows — the ledger IS
  the held-out outcome dataset the calibration rule demands.

- Every swarm card gets a **fallback**: next lane in chain, then Fable executes directly.
  Pin with `<id>.lane` only when you mean "park loudly rather than switch".
- Confidentiality boundary is per-card, explicit: external lanes (glm/grok/codex/gemini)
  see only the paths you list in the prompt. Name the forbidden paths in the card.
- **grok write cards:** No path confinement on write tools — the CLI doesn't support path-scoped
  allowlists, only env cage + prompt trust. Keep write scopes narrow and isolated. If sensitive
  content or config must share the write target's parent directory, use codex instead — it
  confines writes to the `-C <target>` path natively.

## 3. Bus + env hygiene

- **Per-run bus namespace**: `BUSDIR=<unimatrix>/.bus-<runlabel>` (ext4 only, never
  /mnt/*). Two runs on one bus = renumber collisions, verify noise, cleanup cards
  (aiact-054 + brain-053 both paid this tax).
- Env per run: `FANOUT` (≥6 once bus is namespaced), `WORKER_TIMEOUT_SEC` ≥900 for
  write/TDD cards (600 killed real work), `MON_AUTOOPEN=0` when unattended.
- Write cards: `<id>.write` sidecar = target dir. Before parking a timed-out write
  card, **diff-check the target first** — the work may be complete on disk
  (false-timeout class); salvage beats re-run.
- Grok: `stopReason:"Cancelled"` on SUCCESS is normal; false-done exists — gate on
  produced artifacts (diff/handoff), never on the lane's own claim. Auth expiry mid-run
  is real: probe `~/.grok/auth.json` freshness before a long run.
- **Cage geometry:** `.write` is the READ cage, not the write fence — size it to the
  widest tree the card must read, not the narrowest it should write. A leaf-dir target
  silently denies reads on briefings/contracts and the worker finalizes done/0 blind.
  Mirror out-of-cage read deps into the cage before launch; write discipline is the
  prompt + diff gate + review wave, not a narrow target.

## 4. Gates + review wave

- Orchestrator gate between waves: run the tests yourself; never trust "done" markers.
- Verify wave: scope the judge prompt to **this card's diff only** (multi-card trees
  produce verify noise otherwise). Judge ≠ executor is absolute.
- Cross-model review of a build: one read-only card per reviewer lane over the same
  diff + specs; findings come back as structured lists; Fable adjudicates, fix wave
  applies ALL accepted findings, re-test, re-sweep.

## 5. Evidence (non-negotiable, before "done")

- `docs/ops/llm-runs.md` row(s) in the TARGET project (lane + actual billed cost
  re-summed) + unimatrix auto-ledger stays on (`LEDGER_AUTO=1`).
- speedwars: run-meta + verdict + review rows (spec 08) on the namespaced bus. Verdict rows
  carry `verify_lane` (spec 10 FR-R9) — populate it on every run-close verdict row.
- `docs/ops/run-reviews.md` entry (template verbatim) — every run, newest last. Use `swarm-ctl
  review-stub` to pre-fill the skeleton, `swarm-ctl postmortem` to print the run-summary.
- Append to §Lessons ledger below: what you'd plan differently.
- Confirm all `feedback/*-auto-*` draft stubs (status:draft frontmatter): confirm (strip status line,
  adjust type/severity, triage normally) or delete.

## 6. Operate

Everything below runs from the unimatrix repo (`~/code/unimatrix`). Deep semantics live
in `specs/` (01 core, 03 loop, 04 settings, 10 role classes, 11 succession) and
`rules/unimatrix/` — this section is the cheat-sheet, not the contract.

### Run

```bash
# One-shot swarm (Fable pre-seeds specs/, or pass a question for the generate wave):
BUSDIR=$PWD/.bus-<label> FANOUT=8 WORKER_TIMEOUT_SEC=1200 LEDGER_AUTO=1 MON_AUTOOPEN=0 \
  SPEEDWARS_RUN=<label> ./swarm-run.sh ""          # "" = drain pre-seeded specs only
./swarm-run.sh --plan-only "<question>"             # plan, don't spawn
./swarm-run.sh verify                               # cross-model verify wave over done/ (idempotent)
./swarm-run.sh config [<key> [<value>]]             # print/edit swarm.conf
./swarm-run.sh doctor                               # lane/CLI health preflight

# Iterate-until-criteria (judge ≠ executor, stop rules: goal/oscillation/plateau/caps):
./swarm-loop.sh init "<goal>" --until "<criteria>"  # writes the criteria contract
./swarm-loop.sh run <run_id>                        # iterate until a stop rule fires
./swarm-loop.sh iterate <run_id>                    # single increment
```

### Direct call (spec 15)

Direct single-lane dispatch: `unimatrix call glm "<prompt>"` (or via `./swarm-run.sh call`). Bulk via `--files <list> --batch <N> --write <dir>`, shards N-line chunks into cards with per-card ledger rows + one aggregate row in `docs/ops/llm-runs.md`. Pin via `lane:model` (or `--chain` fallback). Full sizing/runbook: `docs/usage.md §Direct call`. Entry point: `/u-call` slash command.

Seeding a card by hand: drop `specs/<id>.prompt` (+ optional sidecars, see §Bus) before launch;
**mid-run adds go into `queue/` directly** (the `specs/` sweep runs once per invocation) — or use
`swarm-ctl add <promptfile> [--lane <lane:model>] [--write <dir>]`.

### Config (`swarm.conf`, full semantics specs/04 + spec 10)

`PLAN`/`ORCHESTRATOR` (fable, never spawned) · `REVIEW` · `EXEC_CHAIN` (lane:model fallback
chain; grok-first recommended on a fully-authed box, prose pins claude:sonnet) · `CLASS_REVIEW`/
`CLASS_EXEC`/`REVIEW_CHAIN` (spec 10 classes) · `PIN_WAIT_SEC` (bounded pin-wait) · `BUDGET_USD`
(0 = uncapped; also gates fallback INTO kimi — the one real-PAYG lane) · `FANOUT` · `LEASE_MIN` ·
`WORKER_TIMEOUT_SEC` · `MAX_LANE_RETRIES` · `VERIFY_MAP` · `LEDGER_AUTO` · `GEMINI_SANDBOX`
(docker for unattended) · `MON_PORT`/`MON_AUTOOPEN` · `GLM_MAX_THINKING_TOKENS`/
`KIMI_MAX_THINKING_TOKENS` (thinking-flood caps) · `GROK_EFFORT` · spec 11: `PLAN_CHAIN`/
`ORCH_CHAIN`/`ORCH_TAKEOVER_MIN` (succession). Precedence: env > swarm.conf > baked default.

### Bus layout (`$BUSDIR`)

| Path | Meaning |
|---|---|
| `specs/ → queue/ → claimed/ → done/` | card lifecycle (plus `cancelled/`; parked = limits marker) |
| `queue/<id>.lane` | HARD user pin — park loudly rather than switch |
| `queue/<id>.chain` | orchestrator pin — chain-eligible fallback walk (spec 10) |
| `queue/<id>.write` | write-card target dir (`.claude/`-component targets are refused at claim) |
| `limits/<lane>.limited` | TTL cooldown (mtime-aged); `limits/<lane>.dead` = auth-death, no TTL |
| `limits/<id>.parked / .waiting / .stamp / .fbreason-<id>` | park marker / bounded pin-wait / diff-gate stamp / fallback provenance |
| `limits/kimi.spend` | cumulative real-$ vs `BUDGET_USD` |
| `run-<id>.jsonl / res-<id>.txt / prompt-<id>.txt / write-<id>.txt` | worker stream / answer / archived prompt / archived write target |
| `heartbeat` / `orch-seat` / `notes-lessons.md` | orchestrator liveness + seat (spec 11 succession) / per-run observation→lesson notebook (orchestrator-only, seeded by bus_init) |
| `loop/` | swarm-loop state (criteria.md contract, state.jsonl, handoff-degraded.md) |

Bus MUST be a local POSIX fs (ext4) — never 9p/drvfs/NFS. One JSONL record = one write(2).

### Monitor + control

```bash
tmux -L swarm attach -r -t mon        # read-only tmux cockpit (board/firehose/cost)
# web cockpit: http://localhost:4747 (Ground Control; MON_AUTOOPEN=1 ensures it on first swarm)
src/swarm-ctl status                  # gate count + limit flags
src/swarm-ctl pause | resume          # block/allow new claims
src/swarm-ctl kill <id> [--cancel] · nudge <id> [hint] · cancel <id> · abort
src/swarm-ctl pause-worker <id> · resume-worker <id>     # SIGSTOP/SIGCONT freeze
src/swarm-ctl heartbeat · watchdog-arm|watchdog-check|watchdog-disarm   # spec 11 succession
```

### Troubleshoot (evidence first — never trust bus state or lane claims)

| Symptom | Likely class | Move |
|---|---|---|
| Card `done` but nothing changed | false-done (grok Cancelled / GLM 5xx-as-answer / OAuth text) | diff the write target; the spec-10 diff gate + `answer_unusable` should have caught it — if not, file feedback |
| Timeout kill on a write card | false-timeout — work often complete on disk | **salvage first**: diff target, adopt or write a narrow completion card; never re-run whole |
| Lane skipped unexpectedly | `limits/<lane>.limited` (TTL) or `.dead` (auth) | `swarm-ctl status`; verify against the provider's real quota before clearing; `.dead` clears only on proven re-auth |
| Pinned card sits then parks | bounded pin-wait (`PIN_WAIT_SEC`) did its job | unpin, re-seed with `.chain`, or fix the lane |
| Parked card needs a re-run | chain exhausted / stale park / cage-denied | `swarm-ctl nudge <id>` — clears `.parked`/`.chain-<id>`/`.retries` and requeues (spec 14 FR-3). Manual `rm limits/*` is no longer the documented recovery; the marker's reason line (FR-7) says why it parked |
| Pool gate never closes | orphaned claim / frozen worker | `swarm-ctl status`, check `claimed/` vs live pids, `nudge` the stuck id |
| Worker stalls asking permission | write cages deny process spawn (by design) | card prompt must say "write code+tests hand-verified; orchestrator runs suites" |
| Kimi cards parked | `BUDGET_USD` gate (real PAYG $) | check `limits/kimi.spend`; raise budget deliberately, never reflexively |
| Orchestrator died mid-run | spec 11 succession | check `orch-seat`; degraded work (`degraded:true` rows) is provisional until Fable re-audits |

Auth preflight before long runs: claude session, `~/.grok/auth.json` freshness, Z.ai quota
(`GET api.z.ai/api/monitor/usage/quota/limit`, raw key auth), codex login. Never draw
limit conclusions from a watchdog-killed attempt's truncated stream (spec 01 FR-12 amendment).

## 7. Feedback (cross-repo drop-box)

Any agent in ANY repo that hits a unimatrix bug/friction/idea files it at:

**`~/code/unimatrix/feedback/`** — one markdown file per item, named
`YYYY-MM-DD-<source-repo>-<slug>.md`, frontmatter `source/date/run/type/severity`, body =
what happened / expected / evidence **paths** (no secrets, no fetched web content — the folder is
committed). Full format: `feedback/README.md` in that repo.

Triage (unimatrix side, orchestrator-owned): sweep `feedback/*.md` at session start → log each
into `docs/research-backlog.md` with attribution → move the file to `feedback/archive/`.

Standing rules:
- Every archived file carries a `triaged-to:` frontmatter key (`backlog#NN`, `skill-ledger
  <YYYY-MM-DD>`, or `dismissed (<why>)`) written **before** the `mv` — never archive un-triaged.
- A file with `status: draft` in its frontmatter is a machine-drafted stub, not a finished report:
  confirm it (strip the `status` line, triage normally) or delete it — never silently archive a
  draft as-is.
- Backlog ids are permanent — never renumber or delete a row, mark it `**DONE** via spec NN` at
  spec close instead. A backlog DONE-sweep is part of run close-out evidence (§5).

## Lessons ledger (append-only, newest last)

- **2026-07-19 aiact-054/brain-053 (seed):** per-run bus namespace + grok-Cancelled
  handling kill the false-done class; split >600s cards; salvage handoffs before
  declaring timeout; sequential review ping-pong (3 rounds on prose) — batch findings
  into one fix wave instead; stalled local agents cost 40 min before substitution —
  set a substitution timer at plan time.
- **2026-07-23 agentbench-008:** (a) artifact gate saved the run twice — grok
  zero-artifact false-done (28s wall) AND GLM 529-error-text-as-answer both
  finalized `done` code 0; never trust bus state, diff the write target.
  (b) Write cages (claude/glm acceptEdits) DENY process spawn — TDD cards must
  say "write code+tests hand-verified; orchestrator runs them"; GLM still
  landed 58/58-green hand-traced code from a tight spec. (c) Read-only review
  cards on claude-binary lanes need an explicit cwd (run swarm from the target
  repo or sidecar) — GLM's honest refusal beats fabricated findings; keep that
  norm. (d) Cross-model review panels are complementary, not redundant: session
  reviewer APPROVEd verified guarantees while codex/grok found 5 CRITs it
  missed. (e) Card FORBIDDEN lists must include DATA dirs (runs/, evidence),
  not just source partitions — an overbroad rm deleted live evidence.
  (f) 3 of 9 agent final reports were lost to a rate-limit stall; disk-state
  checkpoints + cron wake-up (one-shot at window reset + 2h watchdog) resumed
  everything — design reports as courtesy, artifacts as truth.
- **2026-07-23 cal056 (brain, all-claude-lane):** (a) claude-lane OAuth can expire MID-WAVE —
  long cards finalize done/0 with "Failed to authenticate…" as their whole answer while partial
  work sits correctly on disk; salvage-first recovered both (diff the target, then write a
  narrow completion card — never re-run whole). Add auth-error text to the unusable-answer
  class; probe claude auth before waves with >10-min cards. (b) RED-wave briefs must list the
  keys later waves add to shared output-typed fixtures — 3 of 4 micro-fix round-trips were
  fixture-completeness, preventable at brief time. (c) At least one reviewer card/agent must
  RUN every CI gate, not read code — the only reviewer that ran `lint` caught a ratchet
  CI-blocker (gate list comes from CI config at plan time, not CLAUDE.md prose). (d) QA against
  a shared dev box: preflight `/health/db` + check server start-time vs newest source mtime —
  a day-old wedged server invalidates QA silently. (e) Verify every path named in a card brief
  exists (a .js-vs-.ts guess sent one worker hunting; it recovered, cheaper not to gamble).
  (f) Pinning ratified contract text INTO cards (not "read the plan") gave zero
  clarification round-trips across 37 cards.
- **2026-07-24 rolecls (spec-10 build, swarm builds swarm):** (a) NEVER let workers edit the
  running engine — worktree write target + Fable lands at gates worked flawlessly; keep it for
  any self-build. (b) `.claude/` paths are ORCHESTRATOR-OWNED: the claude write cage refuses
  self-modification of command/skill surfaces — 3 cards false-doned on exactly those targets
  (the new diff gate caught all 3); never card them out. (c) Every existing test file whose
  EXPECTATIONS a code card invalidates needs an explicitly-owned update card — the one unowned
  file (swarm-run.bats baked-default asserts) cost a gate round. (d) Review cards that QUOTE
  error signatures will trip text classifiers — the 600-char bound exists now, but keep review
  answers out of any string-sniff path. (e) A verify wave judging point-in-time claims against
  a MOVED tree produces refutation noise (6/11 here) — pin "judge only this card's diff at its
  commit" into verify prompts, or expect to adjudicate. (f) glm >C2 single-file cards still hit
  the thinking-flood timeout (20 min, zero bytes) — bench glm to ≤C2 per-file scope or pin
  sonnet. (g) Mid-run spec adds: drop sidecars-then-prompt straight into queue/ of a LIVE pool —
  worked twice, no restart needed. (h) The deepest bug (driver-crash on mid-flight failover of a
  chain-seeded card) survived 11 verifies + 2 lane reviews + 393 bats and fell only to a session
  reviewer hunting bash-semantics classes — keep one "what would every prior pass structurally
  miss" review in every close-out.
- **2026-07-24 cockpit057-prep (brain, session-side Workflow swarm — no bus):** (a) NEW STALL CLASS:
  claude session agents reliably die at the "background step exited → resume remaining steps" seam
  (3 stalls / 2 agents on one 7-step lane, even after explicit "do not idle" briefs) — long
  multi-step lanes get ONE step per card, or a deterministic shell driver, or an orchestrator
  wake-timer; idle notifications are not completion signals; artifacts-as-truth diagnosed every
  stall with zero data loss. (b) Parallel AUTHOR waves fork on any unpinned shared decision (two
  authors produced mutually exclusive IAs); pre-wave, every decision multiple cards could resolve
  differently gets an orchestrator ruling pinned into all affected cards — and the converse held:
  a pinned rulings doc made two fix agents independently choose the identical mechanism (cal056-f
  confirmed at design altitude). (c) Design-review panels need a rules cop that GREPS the target
  repo's real CI gates (caught 3 components failing a ratchet on file location + a live
  OS-triggered token bug) and a paged-engineer lane, alongside taste — three disjoint catch sets
  again. (d) Persist multi-reader raws as files (research/raw/<key>.md) before synthesis —
  every downstream card addresses raws by path, and the next session gets them free.
- **2026-07-24 grpnrev (refactor, first research-only swarm):** (a) `ENV_MASTER_FILE=~/s/.env.master`
  is REQUIRED in the launch env on this box — default `~/.config/unimatrix/env.master` doesn't exist;
  first launch parked all 6 pinned gemini cards in seconds. Recovery: rm `limits/*.parked` +
  `limits/<lane>.limited`, relaunch (feedback filed: preflight should catch this pre-claim).
  (b) Research fan-outs work as pre-seeded specs + `.lane` pins on a namespaced bus — 6 cards,
  11-16 searches each, ~$0.38 metered, cleanest run to date. (c) The gemini→claude verify wave is
  knowledge-only (no web in the cage) yet caught 5 real errors across 6 cards — ALWAYS run it on
  research swarms, but treat citation integrity as UNCHECKED (feedback filed for a web-capable
  research verifier). (d) Card prompts must demand deep-link citations — one card returned
  bare-domain-root "citations" (post-hoc signature); make it self-policing. (e) LEDGER_AUTO wrote
  claude verify rows but zero gemini rows — hand-log env-var-auth research lanes in the target
  project until the engine covers them. (f) Session-side schema-validated Workflow agents can
  still return placeholder junk ("test") through a satisfied schema — spot-check content, re-run
  the seat; schema validation ≠ content validation.
- **2026-07-24 atoda-toollock (atoda-copilot, first run on grok-first default):** (a) grok-4.5-build 4/5 code cards clean at 35-72s — tight single-file TDD cards are its lane; but a "verify N files + fix drift" card is AUDIT-shaped, and it walked grok×3→glm→claude×3→kimi→codex, burning $0.26 real kimi PAYG silently (BUDGET_USD=0 has no kimi gate — feedback filed). Seed verify-shaped cards with .lane codex from the start. (b) A session reviewer that RUNS things (bundled CLI --help) beats doc-reading: it live-verified --tools "" semantics AND found the setting_sources auto-default trap every other pass missed — keep one tool-running reviewer per close-out. (c) swarm-run.sh resets the caller cwd — orchestrator gates must cd absolutely before pytest or they green-wash on "no tests ran". (d) Plan-mode Explore agents feeding a pinned RATIFIED CONTRACT into every card again gave zero clarification round-trips (cal056-f holds at swarm scale).
- **2026-07-24 round3 (spec-11 succession build — swarm + ultracode hybrid, unimatrix builds
  unimatrix):** (a) The hybrid works: bus cards for repo-file work (worktree write targets),
  session Workflow agents for review/fix fan-outs — 32 session agents applied 50+ findings with
  per-FILE ownership; the one recurring seam is cross-file findings dropped by per-file owners —
  ALWAYS harvest every "needs other file" note into a final sweep wave, they carried 2 CRITs
  here. (b) A "structural miss" lens (what would every prior pass structurally miss — trace real
  end-to-end lifecycles across files) found the false-takeover keepalive bug + cron-env
  resolution + NO-BUS-LEAK; keep it a standing seat in every close-out panel. (c) LIVE DRILLS
  find what 460 bats can't: drill1 instantly caught the cron-line-too-long silent arm loss
  (session PATH baked into crontab); drill3's driver cage-block on the canonical handoff path
  (backlog-38). Budget one real drill per lifecycle feature. (d) Killing a process for a drill:
  `pgrep -f` matches the WRAPPER and YOUR OWN shell — select by exact cmdline (`ps -o cmd=`)
  before kill, or you drill the wrong death (cost two attempts here). (e) Parallel review/docs
  agents race on freshly-edited files — a docs agent read pre-fix code and skipped a true
  changelog claim; sequence docs-sync AFTER code owners in the same workflow, or re-verify
  skips at the gate. (f) Adjudicated verify verdicts belong in speedwars as `verified:BOOL +
  raw_verdict + adjudication` (canonical spec-08 shape — my first hand-written rows used the
  wrong field and rendered "not recorded" in RUNS). (g) Author-wave doctrine confirmed by brain
  feedback ×2 (cockpit057): enumerate every decision multiple cards could resolve differently
  and pin an orchestrator RULING into all affected cards pre-wave (open question = guaranteed
  fork); design-review panels need taste + rules-cop-that-RUNS-greps + paged-engineer; persist
  multi-reader raws as FILES before synthesis; session agents stall at background-step seams —
  one step per card, or a deterministic driver script, or wake-timers (never trust idle pings).
- **2026-07-25 cockpit057b/r/f (brain plan 057, 35 cards, 3 buses):** (a) `.write` cage = READ
  scope — leaf-dir targets blind workers to briefings; wide cage + prompt-enforced write
  discipline + per-card artifact gates is the working geometry (external lanes keep narrow
  cages = filesystem confidentiality). (b) Shared cage dirs DEFEAT the engine's per-card diff
  gate (sibling writes = "change since spawn") — a grok zero-file false-done finalized done/0;
  orchestrator artifact checks are the real gate until a write-journal exists. (c) Account-level
  429 burns BOTH claude chain rungs in <1s each (rungs share the session pool — walk is futile)
  AND leaves a stale `limits/.chain-<id>` that instantly re-parks the reseed after the window
  resets; recovery = rm `.chain-*` + `.parked`, relaunch. Pre-authorize a watchdog cron BEFORE
  hitting limits ("if limited, resume in 2h") — it resumed the whole night unattended.
  (d) Preflight EVERY lane incl. codex (0/2 unusable, never probed — review wave lost its
  cross-vendor leg silently). (e) NUL bytes in source files make bare `grep` silently report
  zero — TWO reviewer false-positives in one night; `grep -a` goes into every card prompt for
  trees with golden-derived string constants. (f) bun `mock.module` restore RACES sibling test
  files' static import graphs — even faithful namespace restores lose; mock only leaf/narrow
  specifiers, run widely-imported modules real with injected fakes (bets.test.ts idiom).
  (g) The "what would every prior pass structurally miss" closer earned its seat AGAIN: 5
  BLOCKERs, all in the shape-crosses-a-boundary-on-faith class (produced-set ∩ read-set = ∅,
  four-mirror drift, snake-vs-camel fabrication) — cheapest systemic prevention is one shared
  row type imported by producer AND consumer, pinned by a parity test, at every seam.

- **2026-07-25 round-4 (specs 12+13 build + v1.0.0 release):** (a) A live drill after every
  new probe surface is non-negotiable: `doctor --live`'s first firing found three bugs the
  535-green suite couldn't — gemini's default model is a CLI alias REST 404s (fallback:
  auth-only models-list GET), codex cold start needs a 30s cap (healthy lane FAILed at 10s),
  and one stray non-UTF-8 byte in the ledger flipped grep to binary mode (`grep -a`
  everywhere the ledger is parsed). (b) The self-learning loop proved itself day one: spec-12
  auto-stubs fired organically on two real runs (cockpit057b, refinery-01) before the round
  even closed, and both stubs traced to the same two engine bugs (backlog 46/47) their
  triage confirmed. (c) Dual review (codex cross-model + opus adversarial) over a parallel
  multi-agent build is the right gate: codex caught an errexit-swallow CRITICAL in code a
  green suite blessed; adversarial caught the run-label mismatch that silently disabled
  ledger-driven stubs. (d) Parallel implementation agents with disjoint file ownership +
  one shared barrier gate scale cleanly (4-way concurrent, zero conflicts); the one agent
  loss (login expiry at report time) cost nothing because its edits were already on disk —
  judge agents by tree state, not by their final message. (e) Smoke contract: bus specs are
  `specs/<id>.prompt`, not `.md` — a silent no-op enqueue looks like a hung run.
- **2026-07-25 ledger013 (refactor, work-ledger+grw swarm C):** (a) Session-agent panel seats + bus review
  cards mix well, but idle pings ≠ reports held AGAIN — 3 of 6 seats needed an explicit nudge; budget the
  nudge round into every panel. (b) Report-only false-done RECURRED on a shared .write cage (haiku doc card
  described edits, wrote nothing; sibling writes blinded the diff gate) — feedback filed; salvage-from-report
  beat re-run. (c) NEW: bash test-harness helpers that return paths via stdout are a debris-dir factory — any
  inner git command that prints corrupts the captured path (a git-status-named directory appeared in the LIVE
  tree); card briefs for bash harnesses must pin "inner commands >&2, one echo on stdout, [ -d ] guard".
  (d) NEW: fix-wave agents over-simplify test assertions toward full-output equality; pin "assert on the
  decisive line" or the fix wave reintroduces noise-fragile asserts (cost one gate round). (e) The
  structural-miss seat (opus, sandbox-RUNNING, production topology) was again top yield: repo-wide reset
  --hard wipeout on the shared robert-begin checkout, template-placeholder COLLISION making every second
  `grw new` fail, ownerless claims — all invisible verb-by-verb. (f) External review lanes need "verify
  against the dependency SOURCE before claiming MAJOR" pinned — glm confidently mis-modeled board.sh and its
  one MAJOR died on a source read. (g) Serial one-file verb waves (ONE bin/grw owner per barrier) + pinned
  rulings gave 10/10 first-pass exec cards, zero clarification round-trips — the cal056-f/atoda pattern
  holds for CLI builds; the panel, not the exec waves, is where all the defects surfaced.
- **2026-07-25 atlas013 (refactor swarm B, 24 build cards + 9-seat close panel):** (a) NEW
  ENGINE FAULT CLASS: a `.write` cage pointing at a NONEXISTENT dir kills the worker at
  spawn with zero bytes, and after 3 strikes the engine marks the LANE broken/parked —
  it killed glm (wave 1) and claude:haiku (wave 2b) identically while sibling cards on the
  same lane ran fine. Recovery: mkdir the target, rm the markers, reseed — lands clean.
  Pre-create every narrow cage dir at seed time; treat `<lane>.broken` with empty
  diagnostics as a CARD fault until proven otherwise (feedback filed).
  (b) The bus codex lane produced 3x unusable answers while `codex exec` direct worked
  perfectly (10-finding review) — when a cross-model seat dies, fall back to the CLI
  directly before dropping the seat; the model is rarely the fault.
  (c) A committed-file COUNT in a commit message lied (11 files) because a file vanished
  from disk between the artifact check and `git add` — the worker's res archive carried
  the full file body and restored it byte-perfect. Artifact-gate at COMMIT time (diff
  tracked-vs-disk), not just at card-done time; res archives are a real recovery lane.
  (d) encore.dev/api imports CRASH vitest fork workers unless another file primed the
  native runtime first — controller tests must mock the framework boundary
  (api → handler passthrough + APIError substitute); services stay mock-free of it.
  (e) Account-level 529 waves kill ALL session subagents at once, including ones that
  already finished but had not delivered (report stuck in transcript). Stand the agents
  down explicitly BEFORE taking over their partitions, or their queued resumes collide
  with the orchestrator's direct edits when the API recovers.
  (f) Deferred-infra criticals hide behind mocked repositories: pg_trgm was used by SQL
  no test ever executed. Every repo method with hand-written SQL needs one opt-in
  real-Postgres integration test (migration replay + mirrored SQL shapes) even when the
  app cannot boot; it proved the extension bootstrap, a unique-index race, superseded
  exclusion, and exactly-once claiming in 463ms.
  (g) The 9-seat close panel earned its cost: 4 session reviewers + structural-miss +
  gate-runner + adversarial + codex found a CRITICAL (missing extension), 5 distinct
  MAJORs, and three independent seats converged on the same two bugs (attachment drop,
  dedup race) — convergence is the strongest confirmation signal a panel produces.
- **2026-07-25 parity012 (refactor, swarm A parity harness — 6 waves, 30 bus cards + 12 session agents):**
  (a) grok park-reclaim false-done class: fresh first-serves 2/2 succeeded, park-reclaim
  serves 2/2 false-doned (~700-token narration, stopReason Cancelled, zero files); clearing
  .parked and letting the pool reclaim is NOT a safe grok recovery — pull the card to a
  session agent instead. (b) Panel geometry that worked: 3 specialist reviewers + the
  structural-miss seat + a gate-RUNNER seat = 31 findings incl. 2 CRITs every spec-adherence
  pass structurally missed because both were consistent-with-spec-but-wrong (HTTP status
  captured yet never compared, so a wrong-baseURL suite reported 100% PARITY; the
  minimize-bound mapping inverted the exit-code signal so the worst divergences exited
  softer) — specs themselves need an adversarial pass, not just the code. (c) Read-only
  codex review of a ~34-file package exceeds 1200s; budget 2400s+ for review cards, and
  stale limits/*.parked markers block the lane NEXT card (engine reported "lane exhausted"
  and never claimed the reseed) — rm them before reseeding. (d) Amendment-driven fix waves:
  ratify spec amendments FIRST, have fix cards cite amendment ids — three parallel fix
  agents shared a schema barrier with zero contradictions (cal056-f holds for fixes too).
  (e) A fix card that must touch shared fixtures to keep its OWN tests green will do so
  despite "touch nothing else" — assign fixture ownership explicitly in every fix brief.
  (f) On a shared single-branch clone (CR-12 style), pnpm-lock.yaml accumulates OTHER
  swarms in-flight manifest edits; committing it mid-run desyncs lock vs committed
  manifests — leave it for the closing sweep and say so in the commit body.
- **2026-07-25 refinery-01 (gtm-studio, cross-repo write run — triaged from feedback):**
  (a) **Stream-replay salvage:** when a worker's written files vanish from disk but its
  `run-<id>.jsonl` carries clean `Write` tool records, replay the Write records out of the
  stream — byte-perfect restore, turns a lost-work incident into a 2-minute fix (R3.8;
  backlog 57, root cause still unknown — suspect cage teardown on auth-death). (b) A lane
  `.dead` marker written during a burst of per-session auth blips can be FALSE: check for a
  sibling `run-*.jsonl` on the same lane with a fresh mtime before honoring it — a live
  stream proves lane auth is fine; recovery is rm the marker + short-TTL `.limited`
  (backlog 54). (c) Pool exit and relaunch both need a queue audit before trusting the bus:
  exit can release a still-running card's claim (duplicate-spawn risk, backlog 55), and
  relaunch re-sweeps `specs/` back into `queue/` over finished ids (backlog 56) — scan
  `queue/` against `done/`/`cancelled/`/live streams before letting any pool claim.
- **2026-07-25 fix-wave (backlog 44-57 → spec 14 FR-1..7 + amendments 01/04/10/12):**
  (a) **Salvage doctrine correction** (supersedes refinery-01 (a)'s "root cause unknown"):
  R3.8's "vanished" files were deleted by the worker's OWN final Bash `rm` before it died on
  an auth blip — stream-replay MUST replay `rm`/`mv` records occurring after `Write` in the
  same stream, not Write records alone, or the salvage resurrects files the worker
  deliberately deleted. (b) Backlog 54/55/56 engine fixes shipped: sibling-liveness guard
  (`lane_has_live_worker`) before any lane `.dead`/`.broken`; reap liveness guard (live pid
  or fresh run log, 2x-per-lane-timeout age cap); sweep terminal-state guard. The manual
  queue-audit choreography in refinery-01 (c) is now engine-enforced. (c) Recovery verb for
  any park is `swarm-ctl nudge` (FR-3 clears state); markers carry reason lines (FR-7) —
  read the marker before touching the bus. (d) Engine self-build pattern held again: 6
  session agents on disjoint files, 2 waves, Fable gates, zero file collisions; one
  cross-file break (FR-7 marker format vs a 4th parser in swarm-run.sh) was caught by the
  owning agent's own red run — the "run only your own bats file" rule surfaced it before the
  gate did.
- **2026-07-25 tok024 (tokenomics, Rust TDD swarm):** (a) gemini lane is DEAD on this box for
  headless workers — instant "[API Error: unknown]", 0 tokens; `GEMINI_CLI_TRUST_WORKSPACE=true`
  in the launch env did NOT reach the child (feedback filed). Don't pin research cards to gemini
  until fixed; Fable WebFetch was the faster recovery. (b) glm-first EXEC_CHAIN for contract-pinned
  Rust TDD: 9/9 single-file cards usable; workers can't run cargo, so budget an orchestrator
  fmt+clippy+barrier-reconcile pass per wave (~15 min of mechanical fixes is normal, not failure).
  (c) A review seat's plausible-but-wrong CRIT survived every textual argument and died to one
  live measurement (units cross-check vs an independent API). When a finding contests a FACT about
  an external system, adjudicate with a probe, not with reasoning — cheapest decisive check first.
  (d) Same-wave sibling briefs must never say "LANDED" for same-wave outputs — an honest agent
  greps, finds nothing, and correctly blocks (c15 did). Label same-wave contracts PINNED, and
  expect one re-serve when a card races its sibling. (e) grok false-done recurred on a shared-cage
  write card (narration, zero files) — pull to sonnet immediately; don't let the pool re-serve grok.
- **2026-07-25 gtm-a/gtm-b (grpn-gtm-studio plan 033, swarms A+B, one session two buses):**
  (a) BOTH claude-CLI child-env-swap lanes (glm AND kimi) died the same evening with the same
  signature — instant `is_error`, 0 tokens, model `<synthetic>` — while claude/grok/codex ran
  fine; doctor stayed green because it only checks CLI presence. Live-probe glm/kimi (Z.ai quota
  GET / 1-token ping) at preflight or lose 3 cards × retries to guaranteed false-dones (feedback
  filed for a doctor rung). (b) NEW false-done flavor: codex finalizing done/0 with an honest
  refusal ("cannot read this TypeScript file … I made no lasting changes") — read-refusal text
  belongs in the unusable-answer class next to grok Cancelled and OAuth errors. The same card
  re-served on grok with a read-clarification preamble ("you CAN read files; no-process only
  forbids spawning") landed clean — cage rules confuse lanes; say what IS allowed, not just what
  isn't. (c) grok narration false-done (Cancelled, 6k tokens, zero Edit/Write) recurred on a
  shared cage; the artifacts-first retry preamble ("your ONLY deliverable is Edit/Write calls;
  prior attempt narrated and was scored FAILURE") landed 2/2 re-serves — cheaper than re-laning.
  (d) Running two buses from one orchestrator session works (A gated while B ran) — but stagger
  gates: both pools draining at once queues two full check runs back-to-back. (e) Plan-doc
  enumerations of compile-coupled tests WILL miss one (a reader test hard-coding the enum count
  cost a gate round) — grep the enum's consumers at seed time, don't trust the plan's list.
  (f) An audit contract written too literally flags its own paper trail ("no Yelp references"
  hit the amendment notes documenting the Yelp cut) — exempt ruling documentation in audit
  criteria, and budget one adjudication per audit.
- **2026-07-26 gtm-c/d/e (plan 033 C+D build + E review panel):** (a) kimi as THE high-level
  exec lane went 20/20 first-serve clean across spec amendments, multi-file compose work, fix
  waves, and /simplify consolidation — promote it above glm for C2+ multi-file cards when
  BUDGET_USD is armed; but review/fix cards holding a 7k-line diff in context ran ~3× the $/card
  of build cards ($33.30 for the E wave vs $8.49 for C's 8) — budget E-style panels at 3×.
  (b) grok finished 1-for-4 on write+test cards and false-doned a READ-ONLY review card with
  9k tokens of narration — its ceiling in this repo class is C1 code-only; review cards never.
  (c) Running /simplify OVER a fix wave caught 2 regressions the fix wave itself introduced
  (a stale parallel-type proxy and a lock ruling that broke failure recovery) — a fix wave is
  new code and gets the same consolidation pass as a build wave, always.
  (d) Pinning cross-card seam contracts (exact type shape, exact refusal string) into every
  fix-wave card prevented ALL merge conflicts across 7 concurrent cards editing one subsystem —
  the cockpit057b pinned-rulings lesson holds at fix-wave granularity too.
  (e) Session review seats stall-class recurrence: ~6 idle-≠-report nudges needed across 11
  agents; keep seats single-deliverable and let the orchestrator own all sequencing.
  (f) TS flow-narrowing rejects closure-assigned `let x: T | null = null` callback captures
  (TS2349 at the use site) — lanes writing test fixtures with Promise-executor captures should
  use definite-assignment (`let x!: T`); recurred twice across C and E test cards.
- **2026-07-26 reforge015/015r (refactor, design-system swap + embed-to-shell, 5 lanes in one wave):**
  (a) A rulings doc that pins VALUES (palette in hex AND the OKLCH the gate demands, the exact
  masthead markup, the new function signature, a 22-row hex remap table) gave 10 parallel cards
  across grok/glm/kimi/codex/sonnet zero clarification round-trips and zero conflicts — but it is
  also now a proven DEFECT SOURCE, and both of its defects had one shape: it hand-enumerated call
  sites from an orchestrator grep that was narrower than the truth. A rename ruling must say
  "grep EVERY form of this symbol and fix them all", never list the sites; and its gate must
  assert the old symbol's absence in USAGE, not only in DECLARATION. Here `var(--color-ember*)`
  survived inside page `<style>` blocks as dangling CSS that no build, type-check, screenshot or
  declaration-check surfaces. (b) Mechanical mass edits (a 22-mapping sed over 2300 lines) belong
  to the ORCHESTRATOR, not a card: deterministic, instantly re-runnable, and the 121-test suite
  stayed green through it — carding it only buys a chance for a model to mangle it. (c) grok
  truncated a review card to its preamble (prose class, 2-for-2 across projects now): keep grok
  on code-only cards, pin review seats to glm/codex/kimi/sonnet. But its ONE stated claim before
  dying was real, and the orchestrator's own grep appeared to refute it — a truncated card is not
  a wrong card, verify against source before dismissing it. (d) Tell review seats they MAY CONTEST
  THE BRIEF: the re-served glm seat found the brief's contrast method wrong (it proposed OKLCH
  lightness; WCAG is sRGB relative luminance), recomputed correctly, and deliberately declined to
  report the false positives the bad method would have produced. (e) Two seats converging on the
  same finding from different lenses (hand-copied font/nav lists: the gate seat called it MINOR
  coverage, the structural-miss seat called it MAJOR fail-open) is the strongest confirmation
  signal a panel gives — and the fix is always the same shape: derive the list from the source
  module at run time. (f) MEASURE responsive invariants, never reason about them: a wrapping
  nav made the bar 63px against a 56px reservation that three separate consumers shared. One
  playwright eval at four widths found it; no amount of CSS reading would have.
- **2026-07-26 gtm-runq (refinery run-quality build, 14 bus cards + 8 session seats):** (a) BARE
  LANE TOKENS in `.chain`/`.lane` sidecars are a trap: `kimi` (bare) → Moonshot 400 Unknown Model,
  `codex` (bare) → ChatGPT-account model refusal — both burn all retries instantly; ALWAYS write
  the full pair (`kimi:kimi-k3`, `codex:default`, `grok:grok-4.5`) exactly as EXEC_CHAIN spells it
  (feedback filed: driver should default bare tokens to the doctor probe model). (b) With correct
  tokens kimi went 2/2 on C3-class engine fix cards and codex 2/2 on review cards; grok's spawn
  fast-fail was transient (TTL clear → 3/3 clean UI/door cards) — probe once before re-laning a
  whole wave off grok. (c) A gate exit code piped through `echo "GATE:$?"` inside an `&&` chain
  masks failure — the echo succeeds, the commit proceeds on red. Capture rc in a variable or gate
  the commit on the check command itself, never on the echo. (d) `npm run check` in a worktree
  with a LIVE `next dev` writing `.next/dev/types` races typecheck into phantom TS1005 errors in
  generated files — stop the dev server (or rm .next) before gating. (e) vitest+TS cannot see
  Next bundler boundaries: a value import from a server-only module (pg-backed readers) into a
  newly-client component 500s only on a real dev-server render — keep one curl/dev-server smoke
  in every close-out that touches the client/server seam (this run's only post-review defect).
- **2026-07-26 fleetops016 (refactor plan 016, DB platform + site page, 14 exec cards + 3-seat panel):**
  (a) `.lane` pin format is `lane:model`, NEVER a bare lane name — bare `codex`/`grok` pass the
  string as a MODEL id (codex 400s "'codex' model not supported", grok "unknown model id") and
  3 strikes mark the LANE broken. Canonical pins: `codex:default`, `grok:grok-4.5`. Recovery:
  fix pin, rm `limits/<lane>.broken`, `swarm-ctl nudge`. A `.broken` whose run stream shows a
  model-id error is a PIN fault, not a lane fault. (b) Frozen-seam contracts (DDL + zod + fixture
  committed pre-wave) again gave ~zero clarification round-trips — but the ORCHESTRATOR'S OWN
  fixture became the defect source: 3 of 3 CRITs traced to my fixture showing non-null where live
  data has null (session tails, lane costs, activity trio). Fixture rule: for every nullable
  contract field, the frozen fixture must show at least one null, or downstream cards will pin
  non-null zod and the first live quiet-day crashes the build. (c) DB-boundary lesson for pg
  cards: pin "numeric/bigint arrive as STRINGS, timestamptz as Date — coerce at the read
  boundary" into any card that SELECTs; string-concat cost sums reached a numeric column before
  the E2E caught it. (d) Live E2E between waves (not after all waves) caught 6 contract-level
  defects while the relevant cards were still cheap to steer — run load/fold/capture against
  real data the moment the pipeline half-exists. (e) 3-seat session panel (specialist ×2 +
  structural-miss) on a $0 subscription found what 85 green tests + 18 green site checks
  couldn't: transactions riding a bare pg.Pool by accidental sequential client reuse, and a
  produced-set ∩ read-set = ∅ table (card_wide). Structural-miss earns its standing seat again.
