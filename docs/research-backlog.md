# Research backlog

Ranked, **not built**. Findings from multi-agent-failure research (MAST taxonomy, arXiv
2503.13657; vibe-kanban issue tracker; CrewAI/AutoGen production write-ups) that don't have code
behind them yet. Do not implement anything here without a spec first (`specs/README.md`) — this
file is the queue that spec-writing draws from, not a spec itself.

Ids are permanent; 8 was never assigned.

1. **Loop checkpointing into `.bus/loop/`.** `/swarm-loop` has no resume — a killed or crashed
   `run` restarts from iteration 1, re-litigating criteria already met. Checkpoint the last
   verified-passing criterion so a resumed run picks up from there. Rationale: CrewAI and AutoGen
   both lack this in production, and it's the single biggest wasted-iteration cost we can see
   coming.
2. **Stalled-worker detection, distinct from the wall-clock cap.** A worker can sit alive but
   silent — no `run-*.jsonl` append for N minutes on a claimed task — without ever hitting
   `WORKER_TIMEOUT_SEC`. Flip such a claim to `stalled` and requeue it rather than waiting out the
   full timeout. Rationale: silence isn't the same failure mode as "still working," and today both
   look identical to the reaper.
3. **Mandatory 4-field fan-out spec contract.** Every branch prompt should be forced to declare
   objective / output format / sources / negative scope before it's enqueued, not left as free
   text. Rationale: MAST found spec ambiguity responsible for 41.8% of observed multi-agent
   failures — the highest single category.
   Update 2026-07-29: item 73's `lint-specs` preflight now covers the sidecar-shape half
   (write targets exist, chain tokens well-formed); the prompt-field contract itself
   (objective/output/sources/negative-scope) stays open.
4. **Synthesis must cite dissent explicitly.** When verify-wave verdicts disagree across branches,
   today's synthesis can quietly pick a side. Force the synthesis step to name the dissenting
   branch and its claim, not just the majority read. Rationale: MAST FM-2.5 (ignored/buried minor-
   ity findings).
5. **HOTL per-worker pause/kill in the web cockpit.** **DONE** via spec 07 — delivered as
   `pause-worker`/`resume-worker` (per-worker SIGSTOP/SIGCONT freeze + `limits/<id>.frozen`,
   reaper skips a frozen claim's lease) plus KILL/KILL+CANCEL/CANCEL/NUDGE buttons in the agent
   drawer, all routed through `POST /api/ctl` → `swarm-ctl`. No blocking-approval distinction
   between write and read-only lanes was built — every verb is a direct click, not gated further.
6. **Cockpit turn-cards + deep-linkable records.** Firehose today is a flat SSE tail; grouping it
   into per-turn cards with a stable URL per record (`/cockpit.html#run-<id>/turn-<n>`) would make
   "look at what worker X said at step Y" a link instead of a scroll-and-search. Rationale: pure
   usability — no failure mode behind it, ranked last on purpose.
7. **Serial-by-default for concurrent write workers, with a codex merge gate.** Two FR-15 write
   branches against the same worktree today have no coordination — first writer wins, second can
   clobber. Default concurrent writers to serial execution, and when parallel writes are actually
   wanted, gate the merge through codex rather than last-write-wins. Rationale: this is the exact
   failure mode vibe-kanban hit and fixed the same way (issue #2472).

## Grok write mode broken (found 2026-07-19, calculator E2E)
**RESOLVED WITH CORRECTION:** grok write WORKS; the real residual is path-caging, not
`--permission-mode`, tracked as item 33 (cross-ref feedback archive item
`2026-07-24-unimatrix-codex-grok-write-containment.md`).
FR-15 write branch on the grok lane (`--permission-mode acceptEdits`) died after 1 turn with
`stopReason:"Cancelled"` — zero tool calls, zero files written (run c1-calc-build, $0.0058).
Suspect the grok CLI rejects/ignores `--permission-mode` in `-p` mode and cancels itself. Needs a
live probe of grok's headless write flags; until then treat grok as read-only-lane only.

## Finalize accepts a Cancelled run (id 40) (found 2026-07-19, calculator E2E)
**DONE** via spec 10 FR-R11 `answer_unusable` classifier + write-card diff gate — a terminal
`stopReason` of Cancelled/aborted (short-answer error-envelope signature) is now rejected at
finalize instead of accepted as success.
The same c1 run finalized as done/ with a "usable" res (one intent sentence) despite the envelope's
`stopReason:"Cancelled"` and `num_turns:1`. Finalize should treat a terminal
`stopReason` of Cancelled/aborted like an empty answer: retry/failover, not success.

## Write workers can't run their own tests (id 41) (observed 2026-07-19, calculator E2E)
`acceptEdits` grants file writes but Bash stays approval-gated headless — c1r wrote calc.sh +
tests then stalled asking approval to run bats. Working as contained-by-design; the oracle/verify
wave owns test execution. Document in specs/01 so branch prompts stop asking write workers to
self-test (they can't).

## Research-lane tool grant (found 2026-07-19, live run) (see 37)
`.claude/commands/swarm.md` routes research branches to a pinned `claude:<model>` lane, but
`lane_cmd` never passes `--allowedTools WebSearch,WebFetch` — headless worker stalls with
"I need permission to use WebSearch" (run b3r-web-evidence, res 103 bytes). Design needed:
`.research` sidecar (mirror of `.write`) granting read-only web tools to claude/glm lanes only.

## Finalize false-done: is_error result rows still finalize done/0 (id 42) (observed 2026-07-19, cockpit build)
**DONE** via spec 10 FR-R11 `answer_unusable` classifier (envelope `is_error` check is
unconditional) — an `is_error:true` result row is now rejected at finalize, not accepted as usable.
A result row with `is_error:true` (e.g. a Z.ai 429 quota hit) still finalizes as `done/0` instead
of failing over — observed live across 4 GLM branches during the cockpit build. `extract_answer`
should treat `is_error:true` / a non-null `api_error_status` as a failed attempt (retry/failover),
not a usable answer.

## Finalize false-done: grok Cancelled near-zero-output finalizes done/0 (id 43) (observed 2026-07-19, cockpit build)
**DONE** via spec 10 FR-R11 `answer_unusable` classifier + write-card diff gate — the composite
signature (short answer + zero tool calls / untouched target diff) is now caught at finalize.
A grok `end` event with near-zero output and `stopReason:"Cancelled"` still finalizes as `done/0`
with effectively nothing written — observed across 7 branches spanning two build waves. Pattern:
prose/meta branches fail this way, code-writing branches don't (see the speedwars ledger, spec 08,
for the evidence rows). Needs an output-bytes floor or a diff-presence check for `.write` branches
before finalize accepts the answer as usable.
**Amended 2026-07-19 (run aiact-054):** the code-cards-are-safe half is REFUTED — g1-snapshots
(a `.write` CODE card) false-doned with narration-only res and a zero-byte target diff. The
diff-presence check for `.write` branches is the fix that covers both variants; do that one.

## Run aiact-054 findings (2026-07-19, plan-054 brain build — first real cross-repo write run)

9. **Never run limit-detection on a watchdog-killed attempt (CRITICAL).** **DONE** via superseded
   by item 30 — spec 01 FR-12 amendment (2026-07-24, round3/backlog-30): a watchdog kill no
   longer flags the lane `.limited`; failover stays card-level. FR-12's SIGKILL at
   `WORKER_TIMEOUT_SEC` left a truncated stream that `limit_error` misread as a limit signal —
   spurious `.bus/limits/glm.limited` (5h TTL) while real Z.ai quota sat at 26%. One flag nearly
   starved the primary exec lane for 5h; orchestrator caught it by re-probing the quota endpoint.
10. **Timeout finalize must diff-check `.write` targets before discarding (MAJOR).** **DONE** via spec 01 FR-12 amendment (2026-07-25, backlog 17+10); timeout-salvaged outcome — r1-rows was
   killed at 613s during its handoff phase with ALL work already on disk (8 tests, 38 asserts) —
   logged `timeout`, adopted manually. Finalize now inspects on-disk diff for timeout attempts and keeps genuine work; see spec 01 §FR-12 timeout salvage (lines 63+) for the amendment.
11. **Per-run bus namespacing (MAJOR).** **DONE** via spec 20 (`--run <label>` derives BUSDIR+SPEEDWARS_RUN atomically + live-heartbeat collision refusal; shipped 3c8e21c, 2026-07-26). Two orchestrator sessions shared the default `.bus`:
   the other session's pool swept this run's specs at its enqueue, evicted six to `cancelled/`,
   ran one as an unpinned read-only stray, and its verify wave verified the foreign branch.
   Default the busdir to `.bus/<run-label>/` (or stamp specs with a run id the pool filters on).
12. **Lane auth preflight (MINOR).** → folded into 35 (doctor live-probe subsumes lane auth
   preflight). grok's OAuth token expired mid-day; four pinned branches
   parked on "Not signed in" — indistinguishable from generic failure on the board. Read
   `~/.grok/auth.json` `expires_at` (and equivalents) before claiming a pinned spec; distinct
   board flag "auth expired", plus a device-code re-auth hint. (Recovery that worked: orchestrator
   ran `grok login --device-code` in background + PushNotification with the code — 4 min to green.)
13. **Document mid-run spec adds land in `queue/`, not `specs/` (MINOR).** **DONE** via spec 01 FR-B sweep terminal-state guard (2026-07-25) — the enqueue sweep now skips done/cancelled/claimed/queued ids loudly; mid-run adds still land in queue/ via swarm-ctl add. The enqueue sweep of
   `specs/` runs once per swarm-run invocation; spec-01 FR-7's "added branches extend the gate"
   holds only for direct `queue/` drops. Bit us: a re-run card sat unswept until the next pool.
14. **Speed-row dedup on pool re-invocation (MINOR).** **DONE** via specs/09-speedwars-panel.md:79
   (shipped as report-side watch, not a write guard) — the panel documents the duplicate `id`
   within a run as a known data hazard to surface, not silently collapse: "duplicate within a run
   is the backlog-14 speed-row dedup bug — show it rather than silently collapsing it." A second
   swarm-run over a bus with
   completed branches appended a null-field duplicate speed row for an already-finalized id
   (g1-snapshots-r2). Guard `speed_row` against ids that already have a terminal row this run.

15. **grok scratch-HOME setup race at high FANOUT (MAJOR — caused a false-done).** **DONE** via
    CHANGELOG "Per-worker scratch-home cages" — `_scratch_home` now takes the branch id and
    builds `$busdir/home/<lane>.<id>`, so same-lane concurrent spawns no longer share (and
    spawn-time `rm -rf` no longer wipes) one `home/<lane>` dir. With 9+
    concurrent spawns, one worker's `install` of `~/.grok/auth.json` into the per-worker scratch
    HOME hit a not-yet-created directory (`.bus/home/grok/.grok/`), the worker died turn-1 with
    `stopReason:"Cancelled"`, and finalize accepted it (p53-migration, 2026-07-19). Pre-create
    the scratch-home tree with `mkdir -p` before `install`, or serialize per-lane home setup.

16. **grok false-done detector at finalize (MAJOR — same incident).** **DONE** via spec 10 FR-R11
    `answer_unusable` classifier + the write-card diff gate (`limits/<id>.stamp` / `find -newer`)
    — both run inside `_finalize_worker`'s success branch and reject false-dones at finalize.
    `stopReason:"Cancelled"`
    alone is NOT the signal (it appears on successful runs too — spec 08 finding). The
    discriminator is the composite signature: wall <30s + tokens_out <2.5k + ZERO tool-call
    events + (for `.write` cards) target-file mtimes untouched. Finalize should score that
    signature and treat a match as an unusable answer: chain-advance/park, count against
    MAX_LANE_RETRIES. Extends item 10's diff-check from timeouts to done-claims.

17. **Watchdog: extract-then-kill (MAJOR — false-timeout class).** **DONE** via spec 01 FR-12 amendment (2026-07-25, backlog 17+10); finalize timeout-salvage — FR-12 SIGKILLed
    p53-build-drift at 922s while it was composing its final answer — work on disk complete
    (14/0 tests), handoff lost. Finalize now inspects on-disk state before failing timeout attempts; speedwars outcome is `timeout-salvaged` (spec 01 line 87). See spec 01 §FR-12 timeout salvage for full amendment.

18. **`ledger_row` label = branch id, not prompt first line (MINOR).** 16 llm-runs.md rows all
    read "You are a headless worker in a multi-model swarm executing t…" — audit-useless. Use
    `<id>` (+ served lane) as the `what` column; prompt text is already archived per-branch.

19. **Verify-prompt scoping for multi-session trees (MINOR — verdict noise).** **DONE** via
    backlog-28 `_write_card_diff_section` (src/swarm-lib.sh) — write-card verify prompts now open
    with "THIS IS A WRITE CARD. Judge ONLY this card's diff below at its commit — other cards edit
    this tree concurrently; do not judge the tree's current state," scoped to files under the
    card's target newer than `limits/<id>.stamp`. 6 of 17 codex
    "refuted" verdicts on 2026-07-19 attacked claims that were true when the worker wrote them
    (tree moved) or worktree-cleanliness overclaims. write_verify_spec should instruct: judge
    ONLY this card's diff vs its prompt; other sessions edit this tree concurrently.

20. **Same-lane first-spawn auth herd (MAJOR — 4 parked branches).** **DONE** via spec 04 amendment 2026-07-26 (`_stagger_first_spawn`, `STAGGER_FIRST_SPAWN_SEC` default 10; shipped fc20bd0). brain-053-remed: 4
    simultaneous grok spawns all failed "Not signed in" at t=0 (burst), while the engine's
    staggered retries later all succeeded — the herd, not the token, was the blocker. Add a
    small same-lane spawn stagger (2-5s jitter) or serialize each lane's FIRST auth per run.
    (Distinct from #15's mkdir race and from the stale-master rotation both fixed in b876b76.)

21. **Run-namespaced bus as a first-class flag (MAJOR — cross-session interference).** **DONE** via spec 20 (shipped 3c8e21c; cockpit multi-bus fleet view staged as spec 20 FR-7, its own wave). Three
    swarms shared the default `.bus` on 2026-07-19; one orchestrator CANCELLED another's 7
    seeded cards, and the recovery cost manual busdir surgery + three cockpit ports
    (4747/4749/4750). `swarm-run --run <label>` should derive BUSDIR, SPEEDWARS_RUN, and the
    cockpit surface together, and the cockpit server should be multi-bus aware (bus picker),
    so N concurrent runs are the default topology, not an incident.

22. **Lane-affinity hints per card class (MINOR — prevents a known false-done class).** The
    R2 multi-pair spec-audit card false-doned on grok (0 tool calls, 517 tokens) and completed
    excellently on codex. Cards should carry an optional class hint (e.g. `.class: audit`) with
    a conf-level map (audit → glm/codex; code-write → any) so EXEC_CHAIN/pins respect the
    empirically bad pairings recorded in speedwars.

23. **Cross-bus grok token rotation race (MINOR — residual after b876b76).** The write-back
    syncs a cage's rotated OAuth token to `~/.grok` post-run, but two live buses can still
    rotate concurrently mid-run (last-writer-wins master). If it bites again: flock'd token
    store or a single grok-auth broker process per box.

24. **Cockpit SSE replay window is a fixed 2s wall-clock guess (MAJOR — D1, qa-3x).** **DONE** via spec 07 amendment (2026-07-25, backlog 24); replay-done sentinel — the server now emits a named `replay-done` SSE event (site/server.mjs line 643) after its first full glob pass, and the client gates `live` on having received that sentinel (site/cockpit/data.js ~699–705 per amendment text). This replaces the `backfillUntil = Date.now() + 2000` wall-clock guess with server-authoritative replay-vs-live policy. See spec 07 §Amendment 2026-07-25 (backlog 24) for full details (lines 225–236).
25. **Cockpit phantom "running" agents flash on fresh load (MINOR, self-healing — D4, qa-3x).**
    `site/cockpit/data.js:818` `ensureRec()` creates a record for any worker name seen in the SSE
    replay — including abandoned attempts that errored before ever reaching queue/claimed/done
    (e.g. a dead `grok login` line). `deriveState()` (data.js:184) falls through an unknown
    `srvState` to `'run'`, so these render as live "WORKING" agents at 0s age until the first
    `/api/agents` poll evicts them (reconcileAgents, data.js:505) — an FR-14 no-fake-data
    violation for a sub-2s window. Fix: gate render-as-running (or record creation) behind
    `store.agentsOk` so an SSE-only, server-unconfirmed worker never derives to `'run'` before the
    first poll resolves. Same SSE-replay-vs-server-truth family as D1. Confirmed live: 22 records
    vs 18 real branches, 4 dead grok ids flashed as running.
26. **Firehose event times render in browser-local timezone, not UTC (COSMETIC — D3, qa-3x).**
    `site/cockpit/format.js:47` `fmtTime()` uses `d.toTimeString()` (locale/tz-dependent) while
    every underlying `.timestamp` is UTC (`Z`) and every age in the cockpit is UTC-derived —
    so the firehose absolute clock disagrees with everything else for a non-UTC watcher. Left
    unchanged deliberately (direction is debatable — a Prague watcher may prefer local); if
    consistency wins, switch to `d.toISOString().slice(11,19)`.
27. **FR-R1 validation gap: EXEC_CHAIN/REVIEW tokens unvalidated** (rolecls final-review MED root cause) — **DONE** via src/swarm-lib.sh conf_load (~line 170 area, backlog-27 comment), spec 04 §Validation — widened the loud die-at-load lane-token check to cover EXEC_CHAIN/REVIEW (non-empty, bare-lane prefix per token) and VERIFY_MAP (both sides). The new lane-token regex covers CLASS_REVIEW/CLASS_EXEC/REVIEW_CHAIN only; a malformed EXEC_CHAIN/REVIEW entry still reaches lane_cmd/speed_row unchecked. Extend conf_load validation to their bare-lane prefixes.
28. **Verify prompts should carry the card's diff (write cards)** (rolecls: 6/11 verify verdicts were stale-claim noise) — **DONE** via `_write_card_diff_section` (src/swarm-lib.sh ~1309, wired at ~1461) — write_verify_spec judges the ANSWER text vs question; for .write cards attach `git diff` of the target scoped to the card, and pin "judge only this card's diff at its commit".
29. **`.claude/` write-card refusal** (rolecls: 3/3 false-dones on .claude/-target cards; diff gate caught all) — **DONE** via tests/swarm-run.bats "backlog-29: .write target inside .claude/ is refused at claim time" (~line 1290) — a `.write` target under `.claude/` parks loudly at claim time (`realpath`-canonicalized so a symlink can't slip the regex), never spawns, no lane cooled. claude write cage refuses self-modification of command/skill surfaces. Encoded in the unimatrix skill lessons; consider a loud lane_cmd refusal for .write targets under .claude/ (mirror the gemini-write refusal pattern).
30. **Watchdog-kill → spurious `<lane>.limited` STILL live** (backlog 9, bitten again in rolecls: glm 1200s timeout flipped glm.limited with no evidence file) — **DONE** via spec 01 FR-12 amendment (2026-07-24, round3/backlog-30) — timeout finalize calls limit_flag unconditionally; distinguish kill-truncation from a real limit envelope before flagging.
31. **`GLM_MAX_THINKING_TOKENS` may not reach chain-claimed spawns** **DONE** via conf_load implementation (src/swarm-lib.sh lines 115, 164–166); GLM_MAX_THINKING_TOKENS is a conf default passed into spawned env (line 789) — verified in place. Third thinking-flood incident (8.5MB stream, ~11.8k est. thinking tokens vs a 6000 conf cap, zero bytes written, C3 single-file card) from feedback `2026-07-24-unimatrix-glm-thinking-flood-c3.md`. The cap propagates correctly; the 11.8k estimate vs 6k cap gap is a Z.ai quota-accounting issue (not a breach of our conf). Plan-time mitigation in unimatrix skill (glm ≤C2 per-file scope) remains the containment workaround.
32. **codex lane is never read-only (MAJOR — containment gap)** (feedback:
    `2026-07-24-unimatrix-codex-grok-write-containment.md`) — **DONE** via src/swarm-lib.sh
    ~503/545 (backlog-32) — no `.write` sidecar now gets codex's native `-s read-only` sandbox;
    only a write card gets `workspace-write`, and then only against its own target,
    argv-pinned by bats. every codex spawn gets
    `-s workspace-write -C <target>` (swarm-lib.sh:543-547); no-sidecar only moves cwd to
    BUSDIR, so the REVIEW-default lane can write into the live bus. Fix: no `.write` sidecar →
    `-s read-only`; sidecar → workspace-write at the target. Needs a bats pair (review card
    cannot create a file in BUSDIR; write card still can at its target).
33. **grok write grants are tool-level, not path-caged** **DONE** via rules/unimatrix/model-lanes.md (2026-07-25); documented caveat — lines 125–138 state "No path confinement on the `--allow` rules — this is the accepted ceiling, not a gap to close" and "Write-mode containment caveat (operator)" explaining the env cage + scratch HOME + prompt trust boundary. Spec 01 FR-16 and model-lanes.md together encode: until grok CLI ships working path scoping, writes are tool-level and operators must keep write cards on tightly-scoped targets.
34. **grok silent fast-fail needs a classifier + lane marker** **DONE** via spec 13 FR-3 `.broken` marker (2026-07-25, backlog 34); lane-down class — `limits/<lane>.broken` is a TTL'd fast-fail marker (specs/13-lane-health.md lines 87–107, FR-3 section) written at finalize when a lane exhibits fast-fail signature (served_model empty + unusable answer). Detection lives in classifiers (spec 12 FR-1 vocabulary, class `lane-down`). Implementation in src/swarm-lib.sh: `lane_broken()` checks presence (line 417), `broken_flag()` writes marker (line 410).
35. **glm HTTP 400 on Z.ai compat endpoint + doctor must live-probe lanes** **DONE** via spec 13 FR-2 `doctor --live` (2026-07-25, backlog 35); auth probes — `swarm-run.sh doctor --live` now extends plain doctor with one minimal authenticated request per lane (10s timeout each, per specs/13-lane-health.md lines 60–85, FR-2 section). Probe calls `_env_master_key` for env-key lanes (glm/kimi/gemini), uses lane CLI for OAuth lanes. Exit code nonzero if any lane FAILs. Every probe that can bill is logged (no silent spend).
36. **ENV_MASTER_FILE default-path miss parks whole runs** **DONE** via spec 13 FR-1 preflight (2026-07-25, backlog 36); launch-time abort — `env_master_preflight()` (src/swarm-lib.sh line 596) called by `full_run` and `verify_run` aborts BEFORE fan-out if env-master is unreadable and the run's lane set intersects env-key lanes (gemini/glm/kimi). Specs/13-lane-health.md FR-1 section (lines 42–58) documents mode-aware behavior; preflight mode excludes VERIFY_MAP/PLAN_CHAIN/ORCH_CHAIN defaults so plain claude/codex runs are unaffected.
37. **Research-card verify wave has no web access — citation contract unverifiable** (feedback:
    `2026-07-24-grpn-refactor-verify-lane-no-web.md`) — same gap as unnumbered "Research-lane
    tool grant" section — one design. gemini→claude VERIFY_MAP judges get no
    WebFetch/curl in the cage; citation integrity is UNCHECKED by construction. Options:
    same-lane different-model judge (gemini-flash exec / gemini-pro verify, judge≠executor via
    model pin), a read-only `VERIFY_TOOLS=web` cage mode (container preferred), or at minimum a
    model-lanes.md note that gemini→claude verify is knowledge-only. Plus card-prompt rule:
    citations must be deep links, bare domains = failed card.
38. **Continuation-driver cage can't write the canonical FR-S4 handoff path** (feedback:
    `2026-07-24-unimatrix-driver-cage-handoff-path.md`, drill3) — driver wrote
    handoff-degraded.md in its worktree with a relocation header instead of
    `$busdir/loop/`. Grant `$busdir/loop` to the driver spawn (narrow --add-dir), or make the
    worktree path canonical with bus adoption at next heartbeat/disarm.
39. **BUDGET_USD=0 walks INTO kimi real-$ silently** **DONE** via spec 13 FR-4 PAYG fallback gate (2026-07-25, backlog 39); warn|allow|deny conf knob — `PAYG_FALLBACK` (src/swarm-lib.sh lines 114, 152, 267–272) gates a fallback hop onto kimi when `BUDGET_USD=0`. Specs/13-lane-health.md FR-4 section (lines 172–185) documents enum (warn|allow|deny default), fallback detection, and loud logging. With `BUDGET_USD=0`: `PAYG_FALLBACK=warn` (default) lets kimi fallback proceed with loud board flag; `allow` silent; `deny` rejects the hop. See spec 13 + CHANGELOG for deployment details.
44. **Read-denial (`cage-denied`) is a done/0 class the classifier can't see**
    (feedback: `2026-07-25-brain-leaf-write-cage-denies-briefing-reads.md`, run
    cockpit057b) — **DONE** via spec 14 FR-1 (2026-07-25) — cage_denials + CAGE_DENY_MAX gate first in finalize; parks cage-denied with limits/<id>.cage-denied evidence (paths+counts only); feedback_stubs class added. a leaf `.write` cage silently denies Read on briefings; workers
    finalize done/0 with partial artifacts. Text-signature proposal ("grant reads /
    re-run") CANNOT work: res-a-llm.txt is 2315 chars, 4x over answer_unusable's
    600-char window, which is the 2026-07-24 review-card-quoting false-positive
    protection. Use the structured field: `permission_denials[]` on the last result
    event, filtered to read-class tools (Read|Glob|Grep|NotebookRead). Measured on all
    24 runs of that bus: fires on exactly a-api/a-mon/a-llm (the 3 known partial-dones),
    silent on the other 21 incl. 12 with Bash-only denials (write cages deny process
    spawn BY DESIGN — a naive >0 gate would kill successful cards). Class `cage-denied`
    PARKS the card (env fault — every rung shares the cage, the walk is futile), never
    chain-advances. One knob `CAGE_DENY_MAX=0`. Register in spec 12 vocabulary +
    feedback_stubs. → spec 14.
45. **Write-card diff gate is per-CAGE, not per-CARD** (same feedback, addendum item 4)
    — **DONE** via spec 14 FR-2 (2026-07-25) — queue/<id>.files manifest scopes both the write-diff gate and the verify-wave diff section; publish+consume trust boundaries; absent manifest unchanged. `find "$wtarget" -newermt … -print -quit` passes if ANY sibling wrote.
    cockpit057b: 8 cards shared one portfolio dir, 12 shared the repo root; a grok
    zero-file false-done (240-byte narration) finalized done/0 on sibling writes.
    `_write_card_diff_section` has the identical blindness (its prompt preamble already
    apologizes for it) and its base→HEAD git range sweeps sibling commits. Fix:
    `queue/<id>.files` deliverable-manifest sidecar (mirrors .lane/.write/.chain
    lifecycle) scoping both the gate's find and the verify enumeration; absent sidecar =
    today's behavior. Rejected: Card-Id commit trailers — depend on worker compliance;
    the failure to catch IS a non-compliant worker. → spec 14. Corroborated cross-project
    by feedback `2026-07-25-refactor-shared-cage-diff-gate-false-done.md` (run
    ledger013): card W3D1 (claude:haiku) finalized `done` with a full before/after edit
    report and wrote nothing, while sibling cards W3D2/W3T1 wrote under the same shared
    `.write` cage dir; the per-card diff gate saw the siblings' change and passed W3D1 —
    identical signature to cockpit057b, confirming this isn't repo-specific.
46. **Park never resets chain position — a re-seeded card re-parks with no spawn** (same
    feedback, addendum item 5) — **DONE** via spec 14 FR-3 (2026-07-25) — chain_reset at the chain-exhausted park; _reset_card_state shared by add/nudge. CONFIRMED:
    `.bus-cockpit057b/limits/.chain-{a-asm,a-llm2,a-port-lenses}` are EMPTY files;
    `_chain_tokens` tests `[[ -f ]]` (true for empty) → chain_current "" → instant park.
    `chain_reset` runs on SUCCESS only. Half-covered: `swarm-ctl nudge` step (e) already
    clears .parked/.chain-/.retries-/.timedout/.frozen — the operator's manual rm sweep
    hand-rolled nudge, and the skill teaches the manual form. Fix (3 lines): chain_reset
    after each park-touch in the chain-exhausted branch (behavior-neutral in-run);
    cmd_add clears the same markers for the id it publishes; skill troubleshoot row
    points at nudge. Do NOT change -f to -s in _chain_tokens (exhaustion would walk
    forever). → spec 14. Pairs with 47.
47. **claude session-limit 429 is invisible to `limit_error`** (same feedback, addendum
    item 6) — **DONE** via spec 14 FR-4 (2026-07-25) — _rate_limit_signature + session-limit envelope arm for claude/glm/kimi, reset-clause TTL, single strike, .limited.evidence. envelope is
    `{"type":"result","subtype":"success","is_error":true,"result":"You've hit your
    session limit · resets 2:50am (Europe/Prague)","modelUsage":{}}` (run-a-asm.jsonl).
    limit_error extracts only type=="error"/"turn.failed" → no hit; the claude/gemini
    no-hit fallback sniffs auth-death ONLY → returns 0. claude.limited is NEVER set:
    every card independently burns MAX_LANE_RETRIES×2 rungs at ~1.8s each and parks.
    Spec 13 half-covers (empty modelUsage → lane-down broken_flag TTL 1800) but only
    after a full chain burn, mislabeled, 30m vs ~2h real reset. Fix (~10 lines): extend
    the no-hit result-text sniff from auth-death-only to auth-death-then-rate-limit
    reusing the claude arm's 429 regex; add glm|kimi to that case arm; parse `resets
    <h:mm><am|pm> (<TZ>)` into TTL (glm next_flush_time precedent), else 18000;
    single-strike. Blocked-lane chain walk stays destructive by design — 46's
    chain_reset makes it recoverable. → spec 14. Pairs with 46.
48. **`.read` sidecar (extra read roots) — no CLI in the fleet supports one** (same
    feedback, proposal 2) — **DEFERRED** (2026-07-25 triage) — spec 14 non-goal stands; needs a live probe of the scratch-home settings.json deny-rule idea before it earns a spec. LOW. Verified: claude `--add-dir` = tool ACCESS (write under
    acceptEdits); codex `--add-dir` = verbatim "should be writable" (codex sandbox
    restricts writes not reads — never had this bug); grok has no equivalent,
    path-scoped allow/deny probe-verified unsupported; gemini isn't write-capable. So
    `.read` == widening `.write` = item-44 doctrine with extra machinery. Only genuine
    decoupling: scratch-home `.claude/settings.json` with `permissions.deny:
    ["Edit(<root>/**)","Write(<root>/**)"]` per extra root (deny outranks acceptEdits) —
    unprobed, claude-family only. Needs a live probe before specing.
49. **Codex REVIEW-class cards routinely need timeout above the current default; repeated
    timeout-kills misreport as "retries exhausted"/false-done, masking the real root
    cause (MAJOR, needs verification)** **DONE (both halves)**: per-class timeout closed as spec 14 non-goal (per-lane `TIMEOUT_CODEX` already exists); the hidden quality half — bus-spawned codex running at `reasoning_effort:none` because the scratch cage lacked `config.toml` — shipped via spec 04 amendment 2026-07-26 (f7393a0). (feedback:
    `2026-07-25-grpn-refactor-codex-lane-wrapper-unusable.md`,
    `2026-07-25-grpn-refactor-glm-never-claims-codex-timeout.md`; runs atlas013,
    parity012; corroborated by auto-stubs `2026-07-25-unimatrix-atlas013-auto-parked.md`,
    `2026-07-25-unimatrix-parity012-auto-parked.md`,
    `2026-07-25-unimatrix-parity012-auto-timeout.md`) — **PARTIAL** (2026-07-25) — per-lane TIMEOUT_<LANE> conf keys (spec 04 FR-C) + run-jsonl rotation .jsonl.<n> (spec 12 FR-D) shipped; per-card timeout sidecar DEFERRED; codex scratch-home config probe remains a measurement task (results will be appended here). the same card id `w5-rev-codex`
    (read-only review over ~34 files, pinned `.lane codex`, no `.write`/no cage) failed
    in two separate runs: parity012 watchdog-killed it at 1200s (speedwars
    outcome=timeout); atlas013 exhausted MAX_LANE_RETRIES with "produced no usable
    answer 3 times" and no `run-<id>.jsonl` stream surviving to diagnose the wrapper's
    failure mode. A same-prompt direct probe (`timeout 1500 codex exec
    "$(cat prompt)"`) completed cleanly in ~840s (14 min, 10 findings) — under the 1200s
    ceiling already in use for this run, which suggests wrapper overhead (prompt
    staging, JSON-stream parsing, sandbox flags), not raw model latency, is eating the
    budget. `WORKER_TIMEOUT_SEC`'s committed default is 300s (swarm.conf) — this run had
    already bumped it to 1200s and it still wasn't enough. Needs verification: measure
    wrapper overhead vs a direct `codex exec` call on the same prompt before concluding
    it's purely a ceiling problem. Suggested fix (either): a per-class timeout (REVIEW
    cards get a higher `WORKER_TIMEOUT_SEC` than code-write cards), or a documented floor
    (`WORKER_TIMEOUT_SEC>=2400` for review fan-outs over >20 files) plus surfacing "N
    consecutive timeout-kills" as its own speedwars class distinct from generic
    "no-answer" retries-exhausted, so the timeout root cause isn't hidden behind a
    lane-retry message. **Probe result (2026-07-25):** three timed same-prompt runs
    (`codex exec -s read-only`, review `src/swarm-ctl`'s `_validate_files_manifest`) —
    (A) direct/real HOME: 1m32.6s, reasoning effort **high**, 36,386 tokens; (B) scratch
    HOME with only `auth.json` copied (matching `_scratch_home`'s codex arm,
    `src/swarm-lib.sh:769-772`): 1m20.9s, reasoning effort silently **none**, 42,444
    tokens; (C) scratch HOME + `~/.codex/config.toml` also copied in: 1m49.1s, reasoning
    effort **high** (restored), 45,286 tokens. `~/.codex/config.toml` DOES exist
    (`model="gpt-5.6-sol"`, `model_reasoning_effort="high"`) and `_scratch_home` DOES
    strip it (only `auth.json` is copied) — confirmed. But this does **not** explain the
    "bus cards slower than direct" complaint: stripping the config made the run *faster*
    (B < A < C), consistent with lower reasoning effort costing less wall time, not more.
    The real, distinct bug it exposes: bus-spawned codex REVIEW cards silently run at
    `reasoning effort: none` instead of the operator's configured `high` — a quality/
    consistency regression, not a speed one. Likelier speed/cost driver: B and C (fresh
    scratch HOME, no `~/.codex/{cache,sessions,memories_1.sqlite}`) both used *more*
    tokens than A (36k) despite B's lower effort — every scratch-home spawn starts fully
    cold with zero cached repo context, forcing more exploration per card; a persistent
    real-HOME session amortizes that across calls. Also answered: the read-only card's
    CWD (`cdir="$(dirname "$busdir")"`, `src/swarm-lib.sh:929`) is **not** a problem —
    `BUSDIR` is realpath-resolved under `$SCRIPT_DIR/.bus` by default
    (`swarm-run.sh:83`), so `dirname($busdir)` resolves to the repo root itself, same as
    direct usage. Verdict: a config-mirroring FR (copy `config.toml` alongside
    `auth.json` in `_scratch_home`'s codex arm, same one-file-copy pattern already used)
    is warranted for output-quality/consistency, but won't fix the timeout/slowness
    complaint this row tracks — that likely needs its own investigation into cold-start
    token cost, not config stripping. n=1 per condition (single timed run each, no
    repeats) — treat magnitudes as directional, not statistically tight.
50. **glm-pinned review card never claims despite a free, healthy pool — no
    `.limited`/`.dead`/`.broken` markers anywhere (MAJOR, needs verification)** (feedback:
    `2026-07-25-grpn-refactor-glm-never-claims-codex-timeout.md`; run parity012;
    corroborated by auto-stubs `2026-07-25-unimatrix-atlas013-auto-parked.md`,
    `2026-07-25-unimatrix-parity012-auto-parked.md` — both list `w5-rev-glm` among
    parked branches) — **CLOSED AS DIAGNOSED** (2026-07-25) — no bug: forensics showed the glm card WAS claimed and spawned; glm served an instant synthetic is_error envelope (0 tokens), hard pin → correct PIN_WAIT_SEC wait → park at 15:07 with markers present. Observability gap covered by row 52's fix (FR-7 reason lines). wave-5 seeded two read-only review cards on different lanes
    (codex, glm) with FANOUT=6; codex claimed immediately, glm sat unclaimed for 25+
    minutes (one unexplained empty `.parked` early on), then per the auto-stubs
    eventually parked in BOTH atlas013 and parity012 despite the lane showing none of
    the health flags `_try_claim_one`'s pin-wait branch (swarm-run.sh:232) would
    produce if it were actually lane-blocked. Needs verification against the
    `queue/*.prompt` glob scan: a leading candidate root cause is backlog-13 (mid-run
    spec adds land in `queue/`/`specs/`, and only the one-time startup sweep moves
    `specs/` → `queue/`) — if the wave-5 review cards were added after that sweep,
    `w5-rev-glm` may never have entered `queue/*.prompt` in a claimable form, while
    `w5-rev-codex` happened to be added early enough or via a different path.
    Cross-ref backlog-13 (still open, not DONE).
51. **`.write` sidecar pointing at a nonexistent directory kills the worker pre-byte;
    engine attributes the failure to the LANE, not the CARD (MAJOR, reproduced on two
    lanes)** (feedback: `2026-07-25-grpn-refactor-glm-broken-empty-diagnostics.md`
    Update section; run atlas013; corroborated by auto-stub
    `2026-07-25-unimatrix-atlas013-auto-lane-down.md`, glm.broken) — **DONE** via spec 14 FR-5 (2026-07-25) — claim-time bounded-wait then park write-target-missing; swarm-ctl add --write hard-refuses; zero-byte run log no longer lane evidence (-s + wrc 126/127 arm). wave-1 card
    `w1-rf-redaction` (glm) and wave-2b card `w2b-redact` (claude:haiku) both died with
    zero-byte answers from the SAME root cause: their `.write` sidecar pointed at a
    directory that did not exist yet at claim time. The worker dies before emitting a
    byte; the engine reads this as the LANE being unusable (flags `limits/<lane>.broken`
    / cools the lane) rather than a per-CARD environment fault — cooling a healthy lane
    (four concurrent claude:sonnet workers on the same account ran fine throughout).
    Recovery both times: `mkdir -p` the target, clear markers, reseed — the card then
    lands cleanly on the same "broken" lane, proving the lane was never actually broken.
    Proposed fixes (both, per the feedback): (a) `mkdir -p` the `.write` target at claim
    time, or refuse the claim with a named CARD-level error instead of spawning into a
    guaranteed-dead cage; (b) never flag a lane broken/limited off a zero-byte failure of
    one card while sibling cards on the same lane are mid-flight and healthy — attribute
    to the card first. Candidate spec-14 FR-5 (flagging for maintainer sign-off, not
    editing the spec here): spec 14 already reworks failure attribution (cage-denied,
    per-card manifests, chain-position hygiene, limit-signal fidelity) but has no FR for
    a nonexistent write-target directory — a distinct, arguably more severe, root cause
    in the same "lane blamed for a card fault" family as FR-1/FR-3.
52. **`.parked`/`.broken` markers (and sometimes the run stream itself) carry no reason
    text — recovery is guesswork every time (MINOR/friction, cross-run)** (feedback:
    `2026-07-25-grpn-refactor-glm-broken-empty-diagnostics.md` original body pre-Update,
    `2026-07-25-grpn-refactor-parked-marker-no-reason.md`,
    `2026-07-25-grpn-refactor-codex-lane-wrapper-unusable.md`; runs atlas013, parity012)
    — **DONE** via spec 14 FR-7 (2026-07-25) — one-line reason markers (ISO-ts | token | retryable | ttl | text) via shared _marker_line/_marker_ttl; legacy bare-digit TTL still parses everywhere incl. cockpit + lane-health preflight. three independent observations, two different runs, same gap: `limits/glm.broken`
    was 4 bytes with no reason text and `limits/w1-rf-redaction.parked` was zero bytes
    (atlas013); `limits/w1-r-b-normalize.parked` and `w1-r-d-verdict-latency.parked` were
    zero-byte pin-wait parks with no `.fbreason-*` (parity012); and a codex review card's
    `run-<id>.jsonl` didn't even survive to diagnose the wrapper's failure mode
    (atlas013, backlog-49). Every case cost the operator minutes of timing/state
    inference instead of seconds of reading a marker. Broader than spec-14 FR-1's
    `cage-denied`-only evidence marker (`limits/<id>.cage-denied`) — that pattern
    (one-line reason + affected paths, scrub-by-construction) generalizes cleanly to
    every park/broken class, not just cage-denied: `pin-wait: <lane> busy since <ts>,
    PIN_WAIT_SEC=<n> exceeded`, `chain-exhausted: last lane <x>, class <y>`,
    `lane-broken: zero-byte answer on card <id>`, etc. Suggest extending FR-1's
    marker-writing convention to every `_park_card`/`limit_flag`/`broken_flag` call site
    as a follow-on, not a spec-14 scope change.
53. **grok park-reclaim serves finalize `done`/0 with zero artifacts — needs verification
    against the write-diff gate (reported HIGH, needs verification)** (feedback:
    `2026-07-25-grpn-refactor-grok-park-reclaim-false-done.md`; run parity012) — **ROOT-CAUSED + DONE** via spec 14 FR-2 + spec 10 gate-find alignment (2026-07-25) — shared write cage confirmed (sibling bytes satisfied the gate); stamp hypothesis refuted (re-touched every spawn; wasn't a park-reclaim at all). NOTE the rejected detector: the grok Cancelled+zero-tool-call false-done detector was CUT at adversarial review — false-positives on zero-tool read cards, redundant for write cards (diff gate), breaks spec 01 FR-12 timeout salvage, contradicts spec 14 Non-Goals; any revival must be scoped to non-salvage write paths only (recorded in spec 10 §Amendment 2026-07-25). 2/2 grok
    cards reclaimed after a pin-wait park (`limits/*.parked` cleared, re-served to the
    same lane) finalized `done`/exit 0 with ~700 output tokens of narration only ("I'll
    write only the RED test file...") and zero new files under their `.write` target
    (~$0.154 wasted each); 2/2 FRESH first-serves to grok in the same run completed with
    full artifacts. Per the code (swarm-run.sh:682 `_write_target_changed`, spec 10
    FR-R11/backlog-16), a `done` claim on a card with a `.write` sidecar whose target
    shows no change since the pre-spawn stamp should already be rejected as
    `false-done` — this should have caught both reclaimed cards. Needs verification
    before speccing anything: (a) do these cards share a `.write` target with a sibling
    that was actively writing during the reclaim window (backlog-45's shared-cage
    blindness — if so, spec-14 FR-2's manifest sidecar already closes this once it
    ships), or (b) does the manual `limits/*.parked` clear-and-reseed path re-touch or
    lose `limits/<id>.stamp` in a way that makes the diff gate compare against the wrong
    baseline, or skip it entirely? The fix differs completely depending on which —
    confirm against the actual `.bus-parity012` evidence before writing an FR.
54. **Lane-level `.dead` written on simultaneous per-session auth blips while a sibling
    worker on the SAME lane streamed on (HIGH)** (feedback:
    `2026-07-25-grpn-gtm-studio-false-dead-lane-while-sibling-streams.md`; run
    refinery-01, evidence archived in `docs/ops/bus-archives/refinery-01-bus.tar.zst`) —
    **DONE** via spec 14 FR-6 (2026-07-25) — lane_has_live_worker sibling-liveness guard before every dead_flag/broken_flag; downgrade to short-TTL .limited with .limited.evidence. five R3.x claude workers died "Failed to authenticate" at 11:30 and the engine wrote
    `limits/claude.dead`, while R3.7 (same lane, same account) kept streaming 15 more
    minutes and finished its card; the marker then blocked all re-seeds until the
    orchestrator hand-verified and removed it. Ask: before any lane-level
    `.dead`/`.broken` write, cross-check sibling liveness (another `run-*.jsonl` on the
    lane with mtime fresher than the lease is proof the lane's auth is fine) — classify
    the blip as short-TTL `.limited`, not auth-death. Same lane-vs-card attribution
    family as 51; overlaps 47 (session-limit texts misclassified as auth-death).
    → spec 13 amendment or spec 14.
55. **Pool shutdown releases a still-RUNNING card's claim back to `queue/` (HIGH,
    duplicate-spawn risk)** (feedback:
    `2026-07-25-grpn-gtm-studio-pool-exit-releases-live-claim.md`; run refinery-01) —
    **DONE** via spec 01 FR-A reap liveness guard (2026-07-25) — Forensics on docs/ops/bus-archives/refinery-01-bus.tar.zst confirms the mover was reap() (src/swarm-lib.sh:322), not a finalize-tail requeue (swarm-run.sh:658/667/807). Architecturally, finalize-tail can only run after a worker's foreground CLI pipeline has already exited (_spawn_worker's tee blocks wait -n until then), so it cannot release a claim while that worker is still alive and writing — only reap()'s pure mtime-staleness check (no liveness signal) can do that, if a claim's heartbeat loop dies (e.g. its parent pool exits/is killed) while the underlying CLI survives as an orphan. R3.7's claim was freshly re-established at 11:14:44-45 local immediately after the incident window, consistent with a reap() sweep at the top of a relaunched pool's first loop iteration finding a stale (heartbeat-dead) claim and releasing it. The planned reap liveness guard is the correct fix for this row. pool-1 exited (its other cards terminal) and moved `claimed/R3.7.prompt` back to
    `queue/` while R3.7's worker was alive and writing files; a second pool with a free
    worker would have started a duplicate R3.7 against the same write target (orchestrator
    caught it within a minute). Ask: at shutdown, a claimed card whose worker pid is
    alive (or whose `run-<id>.jsonl` mtime is fresh) stays claimed — release only
    provably-dead claims. → spec 01 (scheduler/claim lifecycle).
56. **`swarm-run.sh` relaunch re-sweeps `specs/` and re-queues already-finished ids
    (MEDIUM)** (feedback:
    `2026-07-25-grpn-gtm-studio-relaunch-resweeps-finished-specs.md`; run refinery-01) —
    **DONE** via spec 01 FR-B (2026-07-25) — terminal-state guard at the top of the sweep loop, before any sidecar mv; done/cancelled consumed-and-discarded loudly, claimed/queued left non-destructively (OPERATOR HINT preserved). relaunching on the same bus re-copied R3.3–R3.8 from `specs/` into `queue/` although
    the same ids sat in `done/`/`cancelled/`; a claim would have rewritten completed work.
    Ask: the sweep skips ids already present in `done/`, `cancelled/`, or `claimed/` —
    or MOVES (not copies) specs on first ingest. Directly strengthens row 50's leading
    hypothesis (sweep semantics) and cross-refs backlog-13. → spec 01.
57. **Files a worker verifiably wrote (clean `Write` records in its stream) VANISHED from
    disk (HIGH, root cause unknown)** (feedback:
    `2026-07-25-grpn-gtm-studio-worker-writes-vanished.md`; run refinery-01, evidence in
    `docs/ops/bus-archives/refinery-01-bus.tar.zst` → `run-R3.8.jsonl`) — **CLOSED, NO ENGINE FR** (2026-07-25) — forensics: the worker's own final Bash call rm'd exactly the three vanished files, then died on an OAuth blip; earlier writes had succeeded. Salvage doctrine amended in the unimatrix skill instead: stream-replay must replay rm/mv occurring after Write in the same stream. See skill lessons ledger. R3.8's stream
    shows successful Write calls for three files at ~11:33; by 11:45 they were gone (no
    rm in any stream, no git op). Orchestrator restored them byte-perfectly by replaying
    the Write records out of `run-R3.8.jsonl` (recipe now in the unimatrix skill's
    salvage doctrine). Ask: investigate whether the write cage can drop completed writes
    when its process dies on an auth error (same 11:30 auth-blip window as row 54 —
    likely the same incident). → needs live repro before any FR.
58. **Doctor passes dead child-env-swap lanes (glm/kimi) — needs a live-probe rung (MAJOR)** **DONE** via spec 13 FR-6 (`_probe_lane_event` pre-claim + reactive, `PROBE_AUTO` default 1; shipped 9643800, 2026-07-26). The codex honest-refusal sniffer ask in the tail stays OPEN (not covered by FR-6).
    (feedback: `2026-07-25-unimatrix-gtm-a-auto-parked.md` +
    `2026-07-25-unimatrix-gtm-b-auto-parked.md`; runs gtm-a/gtm-b) — glm AND kimi both
    died at CLI/auth level (0-token `<synthetic>` errors, `is_error:true`) while doctor
    showed green, because doctor only checks CLI presence; 3 cards burned retries before
    parking. Ask: a cheap live-probe rung in doctor for the swap lanes (1-token ping or
    the Z.ai quota GET) + the same probe pre-claim when a lane's first serve of a run
    errors instantly. Also from gtm-b: codex honest-refusal text ("cannot read this
    file … no lasting changes") finalized done/0 — add the refusal class to the
    unusable-answer sniffer (scoped per spec 10 §Amendment to non-salvage paths).
59. **Per-card write-journal so shared cages can catch zero-write narration false-dones
    (MAJOR)** **DONE** via spec 14 FR-8 (`_write_journal` + shared-cage gate arm; claude-binary lanes — grok/codex/gemini streams carry no tool_use records, their cages keep the whole-cage sweep; shipped e316fe5, 2026-07-26). (feedback: `2026-07-25-unimatrix-gtm-c-auto-parked.md` + gtm-b report;
    runs gtm-a/b/c — 5 grok narration false-dones in one evening, all caught by
    orchestrator artifact-gates, none by the diff gate because sibling writes satisfied
    the shared-cage diff). Ask: journal each worker's own Write/Edit tool calls
    engine-side and gate a write card's done on ITS journal being non-empty — the
    per-card signal the shared cage diff cannot provide. (Distinct from the CUT
    Cancelled-detector: this keys on the card's own write activity, not lane telemetry.)

60. **Complexity fallback from observable signals (PRD 004 P2-FR2 prose)** — derive a complexity
    bucket from files touched / wall time / branch count when no run-meta row exists, so NULL is
    rare and stratified coverage climbs. Deferred at P2 (2026-07-26): the literal acceptance
    criterion (denominators everywhere) shipped instead; auto-inferred strata risk fabricating
    signal — needs a design pass on thresholds + a validation set of hand-bucketed runs first.

61. **Verify wave on shared-cage runs judges the COMBINED diff, not the card's own (plan005w0,
    2026-07-26)** — all 6 wave-0 verify verdicts came back raw-refuted on "edits other files"
    because every card shared one worktree cage; per-card scoping needs the spec 14 FR-8
    write-journal as its diff source. Until built, expect to adjudicate shared-cage verifies.

62. **glm HTTP-400 root cause — SOLVED 2026-07-26 (plan-005 E5 forensics): it IS the bare-token
    bug (spec 10 FR-R15)** — all 24 archived 400s carry `"model":"glm[1m]"` (bare lane token as
    model id); Z.ai answers code 1211 Unknown Model, deterministically, at healthy quota
    (pro, 5h 39% / weekly 42%). Same defect on kimi = Moonshot 404 `model_not_found` (the
    archived gtm-studio feedback mis-attributed 1211 to Moonshot — reversed); bare `default` on
    glm = Z.ai 500, which is why the fleet count looked mixed. `<synthetic>` zero-token rows are
    the CLI's own error envelope (symptom marker, not lane behavior). FIX SITE (better than
    lane_cmd): `_try_claim_one` swarm-run.sh:476 `lane="$(_call_lane_token "$lane")"` — one
    line, also fixes `_claim_meta`'s colon-requiring claim-filename regex (bare-token claims
    return lane="" and blind the reap/liveness guards). Wave 1 implements; FR-R15 wording
    updated alongside. Consequence: glm's ~44% retry rate was substantially self-inflicted —
    re-judge glm reliability after the fix before any lane-table demotion.
    Update 2026-07-29 (run unimatrix, feedback `2026-07-26-unimatrix-unimatrix-auto-
    timeout.md`): p53-build-drift finalized outcome=timeout on glm — one more data point for
    the re-judge, logged here rather than as its own row.

63. **Retroactive judged-coverage is unachievable on moved trees (plan-005 O1, 2026-07-26)** —
    verify waves over 36 historical done cards (gtm-runq/gtm-e/fleetops016, all ≤1 day old)
    returned 36/36 raw-refuted on pure tree drift (build artifacts like tsconfig.tsbuildinfo,
    wholesale later edits); zero valid verdicts writable. parity012 lesson (e) at full scale.
    Consequence: claude/kimi judged-coverage (7.5%/0%) can only be lifted AT RUN CLOSE while the
    card's diff basis still exists — candidate FR: auto-verify wave at run close (opt-out), which
    spec 14 FR-8's per-card write-journal would make diff-precise even on shared cages.

64. **Reactive probe arm (spec 13 FR-6) has no deterministically reachable path (plan-005 W5,
    2026-07-26)** — the pre-claim arm probes every lane at its first claim, and that marker
    suppresses the reactive event for the rest of the run (criterion 2); the reactive arm only
    fires on a resumed bus with pre-feature claims or after a health-marker-expiry edge. Watch
    the field: if `.probed-*` markers never show "reactive" across a few weeks of runs, simplify
    the arm out (spec amendment) — dead code in the finalize path is risk, not safety.

65. **Haiku prose trial incomplete: 6 of the 20-30 verified-clean card gate (O2, plan-005 wave
    0)** — 6/6 substantive spec cards at ~$0.11/card avg, all adjudicated clean. Next
    improvement wave should route its prose/spec cards through `.chain claude:haiku
    claude:sonnet` + mandatory verify to keep filling the gate; flip the prose default (skill
    lane table + EXEC_CHAIN guidance) only once the gate count is met — never on the 6-card
    sample (W3D1 precedent: small-sample done-rates lie).

66. **Dogfood spec 20 on the next multi-wave plan (plan-005 shipped it but ran pre-flag)** —
    next plan's swarm runs should use `--run <label>` end-to-end: exercises the collision gate,
    the loop pass-through, and spec 20's deferred concurrent-smoke acceptance (two live labeled
    runs, disjoint ledger rows) under real load. Also the first real-world check that
    `UNIMATRIX_BUS_OWNER=1` never leaks into an env where it masks a genuine collision.
    Update 2026-07-29: first field finding landed as item 72 (BUSDIR derived at the unimatrix
    checkout instead of the caller's cwd).

67. **Spec 20 FR-7 staged: Ground Control multi-bus fleet view (cockpit wave)** —
    `site/server.mjs` is single-bus (one BUSDIR env per instance); concurrent namespaced runs
    currently need one cockpit instance per bus (MON_PORT each). Build: enumerate live `.bus-*`
    dirs, one fleet row per bus keyed by `_run_label`, per spec 20 FR-7. Pairs naturally with 66.

68. **Codex honest-refusal false-done sniffer (carried out of 58's tail — the DONE there covers
    only the probe half)** — codex "cannot read this file … no lasting changes" refusal text
    finalized done/0 (run gtm-b); add the refusal class to `answer_unusable`'s signature list,
    scoped per spec 10 §Amendment to non-salvage paths. Small, engine-side, test-first.

69. **Auto-verify wave at run close (candidate FR from 63)** — judged coverage can only be
    captured while the card's diff basis exists; spec 14 FR-8's write-journal now makes it
    diff-precise even on shared cages. Proposal: opt-out verify wave folded into run close
    (`swarm-run.sh verify` invoked by the orchestrator close-out, or engine-side flag), lifting
    claude/kimi judged coverage from 7.5%/0% without retroactive noise. Also directly reduces
    the backlog-61 adjudication tax.

70. **Sweep-time empty-sidecar refusal + write-target-empty instant park (MAJOR).** Empty
    `.write` sidecars seeded straight into `specs/` bypassed `swarm-ctl add` validation, ate the
    full 120s FR-5 bounded wait per card at claim, then parked non-retryable — about 11 min of
    gtm-owners3 critical path across 4 cards. **DONE** via spec 01/14 amendments 2026-07-29
    (sweep refuses empty card files in place; empty `queue/.write` parks instantly, marker
    token `write-target-empty`). (feedback: `2026-07-28-gtm-studio-wave-speed-
    evidence.md`; run gtm-owners3)

71. **Non-journal shared-cage manifest gate — the grok false-done closer (MAJOR).** Both 07-28
    feedback files proposed a stream-edit-count finalize gate; REFUTED empirically — grok
    streams carry zero tool_use records even on honest write cards (gtm-owners3 t6/t8), so a
    stream gate cannot discriminate. Shipped instead: write cards on non-journal lanes
    (grok/codex/gemini) with a shared cage and no `queue/<id>.files` manifest are rejected at
    the diff gate (false-done, ordinary chain-walk). **DONE** via spec 14 FR-8 amendment
    2026-07-29. Grok returns to shared-cage C1 WITH mandatory manifest. (feedback:
    `2026-07-28-gtm-studio-wave-speed-evidence.md` +
    `2026-07-28-gtm-studio-grok-lane-review.md`; run gtm-owners3)

72. **`--run` BUSDIR derived at the unimatrix checkout, not the caller's cwd (MAJOR).**
    Launching `--run` from a target repo swept an empty `specs/` and closed clean — one whole
    gtm-owners3 launch lost. **DONE** via spec 20 amendment 2026-07-29: derivation moved to
    the caller's cwd (matches call's convention) + empty-run loud abort in
    `full_run`/`verify_run`. First field finding of item 66's dogfooding. (feedback:
    `2026-07-28-gtm-studio-run-flag-busdir-cwd.md`; run gtm-owners3)

73. **`swarm-ctl lint-specs` read-only preflight (MINOR).** Hand-seeded `specs/` had no
    validation path (only `swarm-ctl add` validated). **DONE** via spec 01 amendment
    2026-07-29. Partially addresses item 3's enqueue-time contract idea (the 4-field prompt
    contract itself stays open). (feedback: `2026-07-28-gtm-studio-wave-speed-
    evidence.md`)

74. **Pool-exit summary never reports an orphaned `claimed/` entry (MINOR).** `c8-http` sat in
    `claimed/` with its work already complete on disk when the wave-1 pool exited (res file
    never written, 12MB run stream) — the close checklist listed parked/incomplete cards but
    not the orphaned claim, so `ls claimed/` was the only tell. Add a one-line "N claims
    released/orphaned" to `_close_out_evidence`'s checklist. (Two other points in the same
    feedback file need no further action: the `finished: unbound variable` salvage-path crash
    matches the `wait -n -p` guard already shipped pre-1.0 [`[[ -n "$finished" ]] || continue`,
    swarm-run.sh:1305] and does not reproduce against current code; the grok false-done-via-
    shared-cage data point corroborates items 45/59/71.) (feedback:
    `2026-07-25-tokenomics-tok024-engine-bugs.md`; run tok024)
75. **Gemini lane instant API-error root cause unknown (MAJOR, needs verification).** tok024
    (2026-07-25): every gemini attempt died instantly ("[API Error: An unknown error occurred.]",
    duration_ms 0, total_tokens 0) even with GEMINI_CLI_TRUST_WORKSPACE=true in the launch env.
    Trust-workspace theory refuted 2026-07-29 (the var is hardcoded into every gemini spawn by
    lane_cmd, src/swarm-lib.sh:1051) — the real cause (key validity / quota / model tier) was
    never diagnosed. Ledger corroborates a sick lane: gemini 6 done / 31 attempts, 6
    lane-unusable, unpriced tier. Next: doctor-probe the gemini lane with the current key,
    record the key's tier per docs/lane-economics.md, then re-smoke. (feedback:
    archive/2026-07-25-tokenomics-tok024-gemini-lane-instant-apierror.md)

76. **Healthy lane benched 30 min by a 10s probe timeout at first spawn (MAJOR).** **DONE** via spec 21 FR-2/3/5 (2026-07-31; PROBE_TIMEOUT_SEC claude/codex 30s, probe-FAIL 600s + diag pointer, BROKEN_MIN_CARDS=2; doctor --live measured claude cold probe at 11.4s — would have FAILed the old 10s cap). pure064
    (2026-07-29): the claude pre-claim live probe spawns the real CLI in a cold `env -i`
    scratch-home under a hard `timeout 10`; a cold start >10s → rc 124 → generic
    `limits/claude.broken` (1800s TTL, probe FAIL text discarded, zero run-*.jsonl) while
    `claude -p ok` worked seconds before and after. Fix: PROBE_TIMEOUT_SEC (claude+codex 30s —
    codex already has the hardcoded exception), probe FAIL text + child stderr into the marker
    reason line, probe-fail writes the 600s short-TTL form, and BROKEN_MIN_CARDS=2 gates the
    1800s bench on ≥2 distinct-card failures. → spec 21.
    (feedback: archive/2026-07-29-brain-claude-lane-spawn-fastfail.md)

77. **cwd-derived `--run` BUSDIR mis-derives under a persistent-shell orchestrator (MAJOR).** **DONE** via spec 21 FR-6/7 (2026-07-31; --busdir flag + git-toplevel ancestor hint).
    bh065 (2026-07-30): subdir relaunch → "nothing to run" abort; a `cd` earlier in a compound
    command → nested `.bus-bh065/specs/.bus-bh065` junk inside the live bus. The loud abort
    guard caught both (working as designed). Fix: explicit `--busdir <path>` flag (slots into
    the option loop before precedence resolution) + `_refuse_empty_run` hint names an existing
    `.bus-<label>` at the git toplevel (suggest, never auto-prefer). → spec 21.
    (feedback: archive/2026-07-30-brain-bh065-cwd-busdir-footgun.md)

78. **env-master preflight ignores the house-standard secrets path (MINOR).** **DONE** via spec 21 FR-8 (2026-07-31; _env_master_path shared resolver + key-naming abort). bh065
    (2026-07-30): launch aborted on unreadable `~/.config/unimatrix/env.master` although
    `~/s/.env.master` (the box's documented standard since round-3) existed. Fix: single
    `_env_master_path` helper used by both twin defaults (preflight + `_env_master_key`),
    candidate order ENV_MASTER_FILE → XDG → `$HOME/s/.env.master`; abort names the needed
    key(s) and prints a copy-paste export line. → spec 21.
    (feedback: archive/2026-07-30-brain-bh065-env-master-default.md)

79. **DONE** via spec 21 FR-1 (2026-07-31; POOL_LINGER_SEC — live smoke: late add served 12s after swarm-ctl add, zero relaunch). **Pool closes on drain; late adds need a full engine relaunch (MINOR feedback, MAJOR
    wall-clock).** bh065: 4 invocations for one logical run; forensics show 24.5 min (60%) of
    the 41-min run was idle bus between relaunches — 16.2 min of it card w5 sitting unclaimed
    after invocation 1 closed. Fix: POOL_LINGER_SEC (default 0) — after drain the pool keeps
    polling `queue/` for N seconds before closing; mid-run adds already work (claim loop
    reglobs every tick). `add --serve` rejected (duplicates private spawn/finalize machinery,
    escapes run.pgid/abort/sweep coverage). → spec 21.
    (feedback: archive/2026-07-30-brain-bh065-midrun-add-after-close.md)

80. **Cage-denial detected only after burning the worker (MAJOR).** **DONE** via spec 21 FR-9 (2026-07-31; claim-time .files-vs-cage preflight, instant park). bh065 f1: 180s + $0.41 of
    glm work discarded at park class=cage-denied — the write list (`queue/<id>.write` +
    `.files`) is known before spawn. Fix: path-prefix preflight at claim time; out-of-cage
    write list parks instantly with class=cage-denied, no spawn. → spec 21. (source: bh065
    bus forensics 2026-07-31, orchestrator-filed)

81. **No per-card timeline; queue-wait unmeasurable (spec 08 FR-10 promotion) (MAJOR).** **DONE** via spec 21 FR-10/11/12 (2026-07-31; claim stamp + queue_wait_secs, swarm-ctl timeline — bh065 replay reproduces the 24.5-min idle forensics — top_wall in run-summary).
    Nothing renders per-card queued→claimed→spawn→finalize durations, invocation-boundary
    gaps, or critical path; claim time is recorded nowhere (claim-file mtime is
    heartbeat-clobbered — spec 08 declared queue-wait a non-goal pending claim stamping).
    Fix: `limits/<id>.claimed-at` stamp at claim + additive `queue_wait_secs`/`claim_ts`
    ledger keys + read-only `swarm-ctl timeline` + `top_wall` top-3 sinks in run-summary.
    → spec 21. (source: bh065 forensics — 60% idle was invisible until hand-reconstructed)

82. **Parallelism knobs: per-lane caps + claim ordering + FANOUT default (MINOR).** **DONE** via spec 21 FR-13/14/15 (2026-07-31; LANE_MAX_<lane>, longest-job-first, FANOUT 6). No
    per-lane in-flight cap exists (glm ceiling is prose-only; docs/larger-swarms.md R4
    unbuilt); claim order is lexicographic glob; FANOUT baked default still 4 though buses
    are namespaced and the skill advises ≥6. Fix: LANE_MAX_<lane> conf keys (capped lane
    skipped, never wedges pool), longest-job-first by prompt byte size (`ls -S`), FANOUT
    default 6. → spec 21. (source: recon 2026-07-31)
