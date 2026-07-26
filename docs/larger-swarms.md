# Larger swarms — research synthesis + recommendations (2026-07-20)

Goal: FANOUT 16-32+, more agents, more speed. Sources: our own three real runs of 2026-07-19
(aiact-054, brain-053-remed, unimatrix/p53 — speedwars.jsonl + run-reviews.md), the research
backlog (items 1-23), a code audit of the engine, and external research (MAST taxonomy
arXiv 2503.13657, Anthropic multi-agent research system post, Cognition production write-up,
HiveMind arXiv 2604.17111, CONCUR arXiv 2601.22705, provider-limit community evidence).
Recommendations are ranked; each names the backlog items it covers. Nothing here is built —
spec first per `specs/README.md`.

## What the evidence actually says

| Run | Wall | Peak workers | Sum of work | Effective parallelism |
|-----|------|--------------|-------------|----------------------|
| aiact-054 | 40 min | ~9 exec (18 spawns incl. verify) | 123.8 min | 3.1× |
| brain-053-remed | 78 min | 9 | 95.9 min | **1.18×** |
| unimatrix/p53 | 28.4 min | 10 | 101.5 min | 3.57× |

The spread between 3.57× and 1.18× at the *same* worker count is the headline: **worker count is
not the limiter — serialization between waves is.** brain-053 lost ~73 min to sequential wave
gates (R1 glm 600s → R2 codex 520s → final review 190s) and verify→refute→refix ping-pong.
Doubling FANOUT on that run shape would have improved almost nothing.

Second finding: **no provider ever refused us for concurrency.** Every failure at 8-16 concurrent
was our own engineering: auth herd at t=0, scratch-home mkdir race (fixed, b876b76), shared-bus
collisions (3× in one day), false-done/false-timeout finalize trust. External evidence agrees the
lanes have headroom (codex: 25 parallel instances reported without denting quota; grok/claude:
OAuth races, not rate caps; glm: undocumented low in-flight ceiling reported by others, but our
own runs did 8-9 concurrent glm without provider pushback).

Third: **the file-bus is not the bottleneck and won't be.** ext4 O_APPEND single-`write(2)`
atomicity is inode-locked (not PIPE_BUF-bound on regular files), `mv`-claim is the textbook
maildir pattern, and done/ holds 47 files after months — 2-3 orders below where directory scaling
matters. The pool loop blocks on `wait -n` (no spin), so the per-iteration `find` scans are cold.

One engine race verified by code read: `_ledger_append_row` (src/swarm-lib.sh:963) is
grep+awk+tmp+mv — read-modify-write. Safe *within* a run (finalize is serialized by `wait -n`,
one per loop iteration), **races across concurrent runs**, which all share one
`docs/ops/llm-runs.md`. Becomes real the moment multi-bus runs are the default topology.

## Recommendations, ranked

**R1 — `swarm-run --run <label>` as a first-class flag** (backlog 11, 13, 14, 21, 23 + ledger
race above). Derive BUSDIR=`.bus-<label>`, SPEEDWARS_RUN, cockpit port together; make the cockpit
multi-bus aware; `flock` the two cross-run shared appends (llm-runs.md ledger, grok auth master
write-back). This is the actual scale path: **N medium swarms beat one giant one** — 3 concurrent
runs already happen organically and cost manual busdir surgery every time. Do this before raising
FANOUT at all.

**R2 — finalize trust pack** (backlog 9, 10, 16, 17 + the three unnumbered finalize entries).
One spec, four checks at finalize/watchdog:
- usable-answer score: `is_error:true`, terminal `stopReason:Cancelled` with wall <30s +
  tokens_out <2.5k + zero tool calls → failed attempt (chain-advance, count vs MAX_LANE_RETRIES);
- `.write` cards: zero-byte owned-files diff → never done, regardless of exit 0;
- watchdog extract-then-kill: SIGTERM + grace before SIGKILL for write branches, attempt handoff
  extraction, diff-adopt complete work instead of discarding (both false-timeouts had full work
  on disk);
- never run `limit_error` on a watchdog-killed stream (the spurious `glm.limited` nearly starved
  the primary lane 5h).
False-done count scales arithmetically with N — at 32 workers this fires every run.

**R3 — kill wave-gate serialization** (no backlog item — this is new, and the biggest wall-clock
lever per the 1.18× run). Three changes: (a) per-card dependency edges instead of global wave
gates, so independent GREEN cards launch while unrelated RED cards still run; (b) verify as a
pipeline, not a barrier — spawn each card's verifier the moment that card lands in done/, don't
wait for the full gate; (c) batch refute→fix cycles: collect all refutations for a wave into ONE
fix card + one re-verify, never per-finding ping-pong. Anthropic names synchronous batch-wait as
their own bottleneck; we measured it at 1.18×.

**R4 — per-lane concurrency budgets + backoff** (backlog 12, 20; HiveMind/CONCUR AIMD evidence).
`LANE_MAX_CONCURRENT` per lane in swarm.conf (codex high, glm conservative until probed higher);
2-5s same-lane spawn stagger at pool fill (Postfix slow-start analogy — the herd, not the token,
was the blocker); exponential backoff on retry (observed: 12 retries in 9s, no backoff); auth
preflight per lane (read `expires_at` before claiming a pinned spec, distinct "auth expired"
board flag). A burst of 429s must read "lane throttled", not N independent worker failures.

**R5 — heartbeat liveness alongside the wall clock** (backlog 2 + 17; Temporal pattern). Workers
already append run-*.jsonl continuously — the signal exists. Kill on heartbeat *staleness* (no
append for N min), keep WORKER_TIMEOUT_SEC only as the outer hard cap and raise it. Fixes both
directions at scale: hung workers die sooner, slow-but-alive workers (rate-limit backoff, big
files — glm p95 613-922s) stop getting false-killed.

**R6 — risk-tiered verify** (backlog 4, 19). Full judge≠executor verify on every `.write` card
and every card whose claim conflicts with a sibling; *sample* (~20%) read-only prose/research
cards. Keeps the guarantee where the blast radius is while making judge cost sublinear in N.
Verify prompt fixes: judge gets the card's diff + prompt as raw evidence, never the executor's
narrative summary (rubber-stamp risk), and is told the tree is shared (6/17 refutations on
07-19 were stale-tree noise).

**R7 — card discipline at plan time** (backlog 3, 22; MAST: spec ambiguity = 41.8% of failures).
Split C4 cards into parallel C2/C3s at decomposition — the 766s/922s long-tail card sets the
critical path no matter the FANOUT. `.class` sidecar hint (audit/prose → glm/codex, never grok)
per the empirical bad-pairings in speedwars. Enforce the 4-field prompt contract (objective /
output format / sources / negative scope) and a compact handoff schema — claim + evidence +
confidence, not transcripts — so synthesis context stays bounded at 32 workers.

**R8 — two-level hierarchy, only at 32+** (Cognition/Anthropic/fork-merge consensus: flat
coordination degrades past ~10 children). A "lead" is just a worker whose card says "fan out
these 8 sub-cards on your own bus shard and reduce" — same primitives, no new infra. Defer until
R1-R3 are shipped and FANOUT 16 is verified live; our current ceiling is gates, not coordination.

**R9 — re-smoke trigger: FANOUT past last-verified.** Evidence covers 9-10 concurrent, not 16-32.
Add to `docs/versions.md` re-smoke list: any FANOUT raise above the last live-verified level gets
a smoke swarm first (same as a CLI version bump). Provider ceilings above 9 are extrapolation.

## Deliberately NOT building (verified non-problems)

- **flock on the claim path** — `mv` to a unique destination is already race-free; a lock adds
  overhead on the hottest path for nothing.
- **Sharded/hashed bus directories** — 47 files in done/ lifetime; revisit at five figures.
- **inotify** — polling cost is trivial (loop blocks on `wait -n`); watches spend a shared 8192
  budget for no current gain.
- **Parallel finalize** — serial finalize is a real floor (one per loop iteration) but seconds
  per card; measure after R3 before touching `_run_pool`.
- **gate_count optimization** — the O(N) `find` scans run once per worker completion, not hot.

## Suggested build order

R1 + R2 together (they were already named as the FANOUT-16 blockers in run-reviews.md), then R4
(cheap, config + stagger), then a FANOUT-16 smoke run (R9), then R3 (orchestration redesign,
biggest payoff, most work), then R5/R6/R7 opportunistically, R8 only when a real 32+ need shows.

## Addendum — second research pass (2026-07-20)

Independent 11-agent workflow (3 haiku evidence miners, 4 sonnet web lanes, critic + 3 gap-fill
probe agents), run after the synthesis above landed. It converged on the same top-priority calls
(R1, R2, R4, R5) — this addendum records only what the first pass did NOT have: new measured
numbers and sharper provider evidence. Each item names the R-rec it feeds.

**A1 — decompose is a hidden orchestrator tax with a burst structure (feeds R3).** Mined the
Claude Code session transcripts (every `Write` of a `.bus*/specs/*.prompt` file carries a
timestamp): per-card write cost is flat 13-16s inside a contiguous burst (no upward drift to 9
cards), but Fable pauses 80-300s *between* bursts (~8 cards/burst empirically) re-reading
context. The 17-card p53 run amortized to 43.3s/card (735s first-to-last write) vs 11.1s/card
for a single-burst 7-card run — a 4x spread explained entirely by burst count, not card count.
Model: decompose ≈ N × 13s + ceil(N/8) × 100-300s — worse than linear at 24-48 cards. Fix: pre-
read all plan/spec context up front so a big batch emits in fewer bursts; when logging a
`type:decompose` speedwars row, include `bursts` + `max_burst_cards` or the number is
misleading. Ground truth is free: `~/.claude/projects/<project>/*.jsonl` already has it.

**A2 — the box, not providers, is the nearest FANOUT ceiling (gates R9).** Live probes
(`/usr/bin/time -v`, one trivial call per CLI): RSS floors ~330MB claude/glm, ~470-600MB gemini
(parent + worker child, each granted a ~24GB `--max-old-space-size` heap ceiling), ~220MB codex
(8KB Node launcher spawning a native Rust child — `ps -C node` misses the real process), ~95-150MB
grok (native ELF, no node at all). RAM math: FANOUT=24 ≈ 5-15GB worker RSS (fine); FANOUT=48 ≈
10-30GB stacked on the box's measured ~12-20GB non-swarm baseline → 42-50GB against the 47GB WSL
cap. CPU is the sharper wall: loadavg was already ~21 on 14 cores *before* any swarm load, and 6
trivial 2-8s worker calls pushed 1-min load to ~42. Sustained oversubscription amplifies exactly
the false-timeout class R2/R5 fight. Levers: loadavg-aware spawn pacing (skip filling a pool slot
while loadavg/nproc exceeds a threshold), and `.wslconfig` headroom is real — host is a 64GB/16-
thread 5700X3D; 48GB/14 is a deliberate partial allocation.

**A3 — GLM 10-way concurrency verified clean; the web "cap of 1" claim doesn't reproduce
(sharpens R4).** Sweep-line over speedwars.jsonl intervals: the three 2026-07-19 sessions peaked
at 10 simultaneous in-flight GLM calls on the single shared key (~21:03Z); zero is_error/429
across all 31 GLM rows, and tok/s + TTFT show no degradation trend from concurrency 1 → 9. The
web claim traces to GLM 4.7 + opencode (anomalyco/opencode#8618, Jan 2026) — plausibly model-
version drift, flagged unresolved rather than refuted outright. Caveat: the cockpit-build 429s
that day fall in a ledger window with no GLM rows, so before reading any future GLM 429 as a
concurrency cap, discriminate quota codes ({1308,1310,1316-1321,1113}) from rate/overload
({1302,1305}) per model-lanes.md; and glm-5.2 server-side overload storms (zai-org/GLM-5#83) hit
even single-concurrency users — our knobs can't protect against those.

**A4 — per-lane timeout = measured p95 × safety factor; the checked-in 300s default is a
landmine (sharpens R5).** SQS's canonical rule: visibility timeout ≈ 6× average processing time.
15 of 31 GLM done rows exceeded the checked-in `WORKER_TIMEOUT_SEC=300` (successes up to 852s) —
every run so far survived only because an env override was passed. A run that omits the override
kills good work at 300s. Raise the checked-in default per lane (glm ≥900s; grok/codex stay
short).

**A5 — ramp + jitter, with provider citations (feeds R4).** Anthropic documents an
"acceleration limit": a sharp usage ramp 429s below the steady-state RPM/TPM ceiling — on a
FANOUT jump, spawn 25%/50%/100% over the first 30-60s instead of releasing all workers at t=0.
Retries use Full Jitter (AWS canonical guidance), never bare exponential. xAI's own docs
recommend a client-side semaphore (~100-120 concurrent) and tier RPS by cumulative spend; a grok
wrapper in the wild (Hermes Agent) documents transient server overload being misread as auth
failure, causing the client to rotate and corrupt the shared token file — flock the grok token
refresh, one refresher per box (matches our observed t=0 auth herd + rotation race).

**A6 — verification: deterministic receipts before any judge call (feeds R2/R6).** Base rates
justify the paranoia: "false success" accounts for 44-52% of agent failures on tau2-bench and
75.8% on AppWorld even with explicit completion signals (arXiv 2606.09863); coding agents also
game tests — blocking test edits dropped bogus "rescue" rates from 36-51% to 19-24% (RepoRescue,
arXiv 2607.01213). Order the finalize gate accordingly: (1) free receipt predicates — tool-call
count > 0, wall-clock above a floor, non-empty diff restricted to the `.write` allowlist, and
reject diffs touching test files unless the card explicitly owns them; (2) codex judge only for
survivors (Agent-Sentry, arXiv 2603.22868: selective judging keeps verify cost sublinear in N).
Tag each failure with a MAST FM-x.x code in run-reviews.md for cross-run trend lines.

## Final merged stack (2026-07-20) — third pass: adversarial review of both passes

Both prior passes were Claude-family and converged, so this pass attacked the merged stack
instead of re-deriving it: four skeptic agents (high effort, told to default to *refuted*) plus
direct measurement of this repo's own transcripts and ledgers. Two proposed changes were refuted
by evidence, two survived and got sharper. **This section supersedes the two build orders above
where they disagree.**

### Corrections to the stack

**C1 — `.write` sidecars carry no allowlist, so A6's receipt check cannot be built as written.**
Every `.write` sidecar in the repo holds exactly one line: a repo root
(`.bus-aiact/queue/r1-rows-test.write` → `/path/to/your/target-repo`). There is no owned-path list
to confine a diff to. Upgrade the sidecar to *root + owned-path globs* and three things unlock
from one change: receipts (diff non-empty **and** confined, unowned test edits rejected — R2/A6),
concurrent-write safety (disjoint allowlists are parallel-safe, overlapping ones serialize —
closes backlog 7 without a merge gate), and dependency inference for de-serializing waves (R3).
Highest leverage single change in the stack; it is a prerequisite for R2, not a companion.

**C2 — codex is a verify monopoly and the one lane whose ceiling was never probed.** Measured:
49 of 52 verify rows in speedwars ran on codex; verify volume is 1:1 with exec cards (24 exec /
24 verify in aiact-054). `VERIFY_MAP` routes all three EXEC_CHAIN lanes to codex, and
`verify_lane_for`'s hardcoded final fallback (src/swarm-lib.sh:750) is *also* codex for every
non-codex generator. At FANOUT 24 that is ~48 serialized codex calls on an unprobed lane that is
simultaneously a throughput choke and a single point of failure — if codex auth expires, every
lane's verify wave dies at once. Fix: distribute `VERIFY_MAP` (glm→codex, grok→claude,
claude→codex), make the fallback rotate over non-self EXEC_CHAIN lanes instead of hardcoding
codex, and smoke-probe codex concurrency before any FANOUT-24 run.

**C3 — A4's per-lane timeout prescription is backwards for codex and grok.** A4 says "glm ≥900s;
grok/codex stay short." Measured over all 142 done rows in speedwars: codex has the *fattest*
tail (median 73s but max 2300s on legitimate audits), grok p95 646s / max 705s, claude 52% of
successes over 300s (median 385s, p95 790s), glm p95 766s / max 852s. Every lane needs more than
300s. Checked-in defaults should be glm 1200 / codex 2400 / claude 1200 / grok 900, paired with
R5 heartbeat-staleness kill so a generous wall cap never means waiting 40 minutes on a hung
worker. The wall clock stops being the liveness signal; it becomes the outer bound.

**C4 — parallel decomposition: REFUTED, by measurement and by card content.** Proposed fanning
card-authoring out to cheap subagents to kill A1's decompose tax. Mining this session's own
transcripts shows the tax isn't what A1 modeled: the aiact-054 decompose emitted **24 cards in
153s (6.6s/card) in a single burst**. A1's 43.3s/card is an artifact of dribbling cards between
other orchestrator work, not a per-card cost — the "worse than linear" model does not hold when
context is preloaded. Independently, the skeptic pass showed real cards encode cross-card
coupling that independent slice-authors cannot maintain: not-yet-written function signatures
(`wideJoin(pinDate)`), byte-exact shared fixture schemas, cross-wave "read what already landed"
dependencies, and "copy that idiom exactly" references to sibling files. Delegating that is
MAST's #1 failure category (spec ambiguity, 41.8%) bought for ~3 saved minutes. **Fix is a
discipline, not a mechanism:** read all plan/spec context first, then emit every card
back-to-back without interleaving reads. 48 cards single-burst ≈ 5 min. Revisit only past ~60
cards, and then as manifest-then-expand (Fable authors a one-row-per-card manifest holding every
coupling decision; cheap agents expand rows into prose), never as independent authorship.

**C5 — verify tiering: my two-stage gate was REFUTED for prose cards; R6's sample survives.**
Proposed replacing R6's 20% prose sample with "receipts on 100%, judge only survivors." Receipts
have no content-correctness signal where there is no diff — and 15 of 44 tagged cards (34%) are
read-only or human-judgment class with no test/tool receipt available at all. Worse, read-only
cards are typically singletons in their batch, so they never trigger a "contested" clause and
would reach a judge *never*. Confidently-wrong research, hallucinated citations, and subtly wrong
analysis all pass receipts cleanly. Corrected rule: **judge ⟺ receipt_fail OR contested/high-risk
OR (class == read-only-prose AND random 20% sample)**. Receipts are a free pre-filter on every
card, not a replacement for sampling the class they cannot see.

**C6 — R8 (two-level hierarchy): DELETE, and not merely as "deferred."** It is architecturally
impossible as written, not just premature. R8 claims a "lead" is "just a worker — same
primitives, no new infra." Code says otherwise: claude and glm workers run
`--permission-mode acceptEdits`, which auto-accepts Edit/Write and grants no Bash at all
(swarm-lib.sh:368,462); grok is capped to `--tools read_file,grep,list_dir --no-subagents`
(:489); gemini is not write-capable in v1. Only codex gets a real shell (`-s workspace-write`,
:375). And a nested `swarm-run.sh` inside a codex cage would resolve `_env_master_key` against
the *scratch* HOME (:313), which holds only OAuth files — every sub-lane needing a keyed
credential fails instantly. Implementing R8 needs a new secrets-forwarding path plus a
cross-run concurrency governor: the opposite of "no new infra." It is also the only rec in the
list with no backlog and no measured-run citation. Log it as *a literature pattern that does not
transfer to this architecture* — our coordination lives in the file-bus and compact handoffs, not
in the orchestrator's context window, which is the problem hierarchy actually solves. Re-open
only if a run proves Fable's own decompose cost (not worker count) is binding — and C4 shows it
is not.

**C7 — box-level governor: right instinct, wrong mechanism and wrong label.** Per-run bus
namespacing (R1) without a cross-run budget just relabels the collision: three namespaced runs at
FANOUT 16 = 48 workers on one 14-thread box, which is exactly A2's measured RAM/CPU wall. But the
proposal as first drafted was mislabeled (its target is A2's host contention, not A3's shared
provider key — GLM 10-way concurrency measured clean) and mis-mechanized: a maintained slot
counter reintroduces the read-modify-write hazard this project deliberately avoided on the claim
path, and `pids/<id>` leaks when a *driver* is killed since only the owning driver cleans it.
Corrected form: **recompute, never maintain** — match the codebase's existing `gate_count`/`reap`
pattern by scanning `.bus*/pids/*` across all buses with `kill -0` liveness each pool iteration,
and gate new spawns on live-worker count + RSS headroom, with loadavg as a secondary brake only
(93-97% of GLM wall time is API wait, so loadavg alone would throttle runs that are merely
waiting on the network).

### The final order

**Tier 0 — config only, no design work, do today.** Per-lane `WORKER_TIMEOUT_SEC` (C3); raise the
checked-in `FANOUT=4` to 12 (every real run already overrides it — same landmine class as the
timeout); distribute `VERIFY_MAP` (C2).

**Tier 1 — the FANOUT-16 unlock.** `.write` allowlist sidecar (C1) → R2 finalize trust pack built
on it → R1 `--run <label>` namespacing plus the recompute-style cross-run governor (C7).

**Tier 2 — speed.** R3 de-serialize the gates: per-card dependency edges derived from the C1
allowlists, verify as a pipeline instead of a barrier, batched refute→fix instead of per-finding
ping-pong. Then R4 per-lane budgets with A5's ramp (25/50/100% over 30-60s) and Full Jitter
retries, and R5 heartbeat liveness.

**Tier 3.** R6 with the C5 correction; R7 card discipline (single-burst decompose per C4, `.class`
hints, 4-field contract); codex concurrency smoke probe before FANOUT 24 (C2).

**Dropped for cause.** R8 hierarchy (C6). Parallel decomposition (C4). Plus the earlier verified
non-problems: flock on the claim path, sharded bus directories, inotify.

Expected effect: 3.1-3.6× effective parallelism today → ~8× at FANOUT 24, with the gates (R3) —
not the worker count — carrying most of that delta.
