# Swarm Core — `/swarm` Engine

**Status:** Active
**Date:** 2026-07-08
**Related specs:** [04-settings](./04-settings.md), [02-cockpit](./02-cockpit.md), [03-swarm-loop](./03-swarm-loop.md),
[14-write-cage-attribution](./14-write-cage-attribution.md) (FR-6 shares this spec's amendment FR-A
claim-parse/freshness helper)

---

## Overview

`/swarm "<question>"` is a Claude Code slash command where the current session (Fable, per
`DECISIONS.md` Q3) plans a decomposition, fans it out to headless CLI workers across four model
lanes, and adjudicates the results. Delegation is CLI/file/pipe only — no MCP, no send-keys,
no pane-scraping. Prompts travel as files; answers come back from each CLI's own structured
handoff file, never the terminal buffer. This is the winning design (`PRD.md` §1-6, `a1`,
score 8.18).

This spec covers the engine: command modes, the file-bus lifecycle, the six lane invocations,
the scheduler, and the completeness gate. Monitoring lives in `02-cockpit.md`; settings/failover
in `04-settings.md`; the iterate-until-criteria mode in `03-swarm-loop.md`.

---

## Goals

1. Fan out N independent branches to 4 model lanes headless, with zero synthesis from a partial
   result set — ever.
2. Race-free claiming and crash reclaim using only filesystem primitives (no daemon, no DB).
3. Survive a killed/OOMed/rate-limited worker: stale lease reaped, branch re-queued, run continues.

## Non-Goals

- No MCP server, no `tmux send-keys` into a worker, no ANSI screen-scraping for results.
- No SQLite/daemon-based work queue (rejected candidate `a5` — over-built for 2-4 branch reality).
- No predictive rate-limit polling — the 429 is the detector (`04-settings.md`).
- No cockpit UI (`02-cockpit.md`) and no long-running loop iteration (`03-swarm-loop.md`).

---

## Requirements

### Functional

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-1 | `/swarm "<Q>"` (one-shot) plans + fans out in one turn; bare `/swarm` after an in-session plan-mode conversation converts the agreed branches into specs and starts at enqueue. | Must |
| FR-2 | Each branch is a prompt **file** at `.bus/specs/<id>.prompt` — never interpolated into a shell string or keystroke stream. | Must |
| FR-2b | Optional per-branch lane pin: sidecar `.bus/specs/<id>.lane` containing one `lane:model` token (e.g. `codex:default`, `gemini:gemini-3-flash`). Enqueue moves it alongside the prompt; claim-time the pool reads it and pins that branch's lane, bypassing EXEC_CHAIN (failover for a pinned branch: park loudly, don't silently switch lanes). Absent sidecar → EXEC_CHAIN. | Must |
| FR-3 | Specs move `specs/ → queue/ → claimed/<id>.<worker> → done/` via atomic rename only. | Must |
| FR-4 | Claiming renames to a **per-worker unique destination** (`claimed/<id>.<worker>`); a losing claimer's rename fails `ENOENT` (source already gone) — that failure IS the lost-race signal. Plain `mv` to a shared name is not a valid claim (it silently overwrites). | Must |
| FR-5 | Scheduler is a bash `wait -n` job pool (bash ≥ 5.1), run in its own process group, `trap 'kill 0' INT TERM` — **deliberately NOT `EXIT`**: on bash 5.2.21 a group leader's EXIT trap firing self-inclusive `kill 0` segfaults bash (live-reproduced 2026-07-08; pitfalls §15). Clean exit needs no mop-up (pool exits only at running==0); external abort = TERM. Guard `wait -n -p` against errexit (it returns the reaped job's exit code — pitfalls §16). Not `xargs -P` — it doesn't forward INT/TERM to children. | Must |
| FR-6 | Workers heartbeat their claim file (`touch`) periodically; the lease reaper keys on heartbeat age, not claim age, so a slow-but-alive worker isn't reclaimed. | Must |
| FR-7 | Synthesis is gated: blocked until `done/` + **parked** count ≥ count of **live** specs (everything not moved to `cancelled/`) — cancelled branches don't deadlock the gate, added branches extend it. **Parked branches are terminal for the gate** (a pinned branch whose lane is exhausted must not hang the run forever — found by step-4.5 build 2026-07-08); a run that closes with parked > 0 exits nonzero and lists the parked branches loudly — never a silent partial synthesis. | Must |
| FR-8 | The answer for each branch is read from that CLI's own handoff file, never `run-<id>.jsonl` prose. | Must |
| FR-9 | `.bus/run.pgid` records the scheduler's process group id at start, enabling a single `kill -- "-$(cat run.pgid)"` full abort. | Must |
| FR-10 | The claim loop checks `.bus/PAUSE` before every new claim; its presence blocks new claims without touching in-flight workers. | Should |
| FR-12 | **Per-worker wall-clock watchdog** (live E2E finding 2026-07-08): a worker exceeding `WORKER_TIMEOUT_SEC` (default 300) is killed (whole subtree — `pkill -P` children first) and treated as a failed attempt (chain-advance or park). Rationale: gemini hit a 503 and its retry loop hung the worker forever; heartbeat kept the lease fresh, so the reaper could never reclaim it — hangs must be bounded by wall clock, not lease age. *(Amended 2026-07-24, round3/backlog-30: a watchdog kill must **not** flag the lane `.limited` — a kill-truncated stream is not limit evidence (two live incidents cooled a healthy lane 5h); the failed attempt stays card-level: chain-advance or park, ledger+speedwars `timeout` rows unchanged.)* *(Amended 2026-07-25, backlog 17+10: **timeout salvage** — before the kill is treated as a failed attempt, finalize inspects what the worker already put on disk and keeps it if it is genuine work; see §FR-12 timeout salvage below.)* | Must |
| FR-13 | **Driver death sweeps the pool** (live E2E finding 2026-07-08): external TERM/kill of `swarm-run.sh` must terminate all in-flight workers and their subtrees — verified twice that workers survive the driver today. Whatever mechanism (pool as own session + pgid kill on TERM, PR_SET_PDEATHSIG wrapper, or explicit pid registry swept by trap), the acceptance test is: TERM the driver mid-run → zero surviving worker processes. FR-12's watchdog kills with **SIGKILL directly** — workers are stateless CLI calls (handoffs land via the pipeline, not the process), so a TERM grace period adds latency without benefit, and a wedged child ignores TERM anyway. *(Reconciled 2026-07-08 to match the shipped design.)* | Must |
| FR-14 | **Fencing against lease-steal double-finalize** (found by the swarm's own first E2E output, codex lane): a slow-but-alive worker whose lease was reaped can finish AFTER the retry and overwrite `res-<id>.txt`/re-write the done marker with stale output. Finalize must be fenced by the claim file's **identity, not its path**: `reap()` requeues to the same lane often enough that a retry recreates the IDENTICAL `claimed/<id>.<lane>` path, defeating a path-existence check. Token = `stat -c '%d:%i'` (dev:inode) captured immediately after a successful `claim()`; finalize compares current vs captured and on mismatch/absence becomes a no-op (`stale-finalize` event in its jsonl — no done marker, no res write, no chain-advance), uniformly across ALL finalize paths. *(Amended 2026-07-08 to the shipped identity-token design.)* **Known gap (backlog):** `run-<id>.jsonl` is shared across retry attempts (each attempt's `tee` truncates it) — a retry legitimately wipes the prior attempt's stream, including its stale-finalize record. Per-attempt jsonl naming (`run-<id>.<n>.jsonl`) would restore strict one-writer-per-file across attempts; not v1-blocking since res/done integrity doesn't depend on it. | Must |
| FR-15 | **Write-capable exec branches** (closes the plan's §4.5 toy-loop-to-GREEN acceptance): a branch with a `.bus/specs/<id>.write` sidecar containing a target directory path runs its worker **in that directory** with file-write capability — claude/GLM lanes add `--permission-mode acceptEdits` and are `cd`'d into the target via `env -C <target>` (live-verified 2026-07-08 against claude 2.1.204, both with a real HOME and under the full `env -i` + scratch-HOME cage: writes land, `permission_denials: []`, exit 0; `--add-dir` is **not** needed — the CWD itself is auto-trusted under `-p`); `--dangerously-skip-permissions` is FORBIDDEN — containment. Codex uses its native `-C <target> -s workspace-write` **only when the sidecar is present**; a plain codex card spawns with `-s read-only` *(amended 2026-07-24, backlog-32 — the REVIEW-default lane previously got workspace-write unconditionally, letting a read-only review card write into the busdir parent)*. Gemini is NOT write-capable in v1 (web/research lane) — `lane_cmd` refuses loudly and the branch chain-advances/parks exactly like a missing key would. The target must be a **scratch git worktree** when driven by swarm-loop (created at `init` via `git worktree add -b loop-<run> <path> <base-sha>`, committed per iteration when `LOOP_GIT_CHECKPOINT=1`, never the orchestrator's own tree; a non-git or unborn-HEAD `TARGET_DIR` falls back to running directly against it with a loud warning). Absent sidecar → read-only behavior exactly as today. Env cage (env -i + scratch HOME) unchanged — write capability comes from flags + CWD, never from loosening the env. | Must |
| FR-16 | **Opt-in containerized gemini lane** (closes the before-unattended containment gate, DECISIONS.md Q2, for the one web-facing lane): with `GEMINI_SANDBOX=docker` (swarm.conf key / env override, default **off** = today's behavior), `lane_cmd`'s gemini branch wraps the invocation in `docker run --rm -i` with ONLY the contract env forwarded via a **bare `-e NAME` allowlist** (`-e GEMINI_API_KEY -e GEMINI_CLI_TRUST_WORKSPACE`) whose values live in the caged docker-client env (`env -i` base — so bare `-e` forwards exactly our value, never an ambient one, AND keeps the plaintext key out of `docker`'s argv / `/proc/<pid>/cmdline`; amended 2026-07-12 from the earlier `-e NAME=value` form for that reason), **no host filesystem mounts** (the lane is read-only research — it needs no repo access; prompt-injected web content must find an empty container, not the host), and a **pinned image** recorded in `docs/versions.md` (re-smoke trigger on bump). gemini's own `--sandbox` flag stays FORBIDDEN — it re-execs the whole CLI inside its own Docker and strips the contract env (live finding, pitfalls). The handoff path is unchanged: stdout is still the stream the driver tees to `run-<id>.jsonl`, `extract_answer` unchanged. `GEMINI_SANDBOX=docker` with docker missing, image unpullable, or the container failing to start = **loud lane_cmd/worker failure** (chain-advance or park) — never a silent fallback to an unsandboxed spawn. FR-15 interaction: gemini remains non-write-capable; a `.write` sidecar still refuses before any sandbox logic runs. Acceptance: bats (fake docker shim) assert the argv shape — explicit `-e` allowlist only, zero `-v`/`--mount` args, pinned image ref, gemini argv preserved after the image; plus one live sandboxed PONG receipt. | Should |

**Amendment 2026-07-25 (backlog 17+10) — FR-12 timeout salvage.** A `WORKER_TIMEOUT_SEC` SIGKILL
says the process ran out of wall clock, **not** that its work is worthless. Two live incidents:
`p53-build-drift` killed at 922 s with 14/0 tests already written to the target, `r1-rows` killed at
613 s with 8 tests + 38 asserts on disk — both logged `timeout`, both were re-done or adopted by
hand. Discarding on-disk work is the bug; the kill itself is correct.

Salvage is **finalize-side only** — the watchdog is untouched, still a bare SIGKILL (FR-13). On the
timed-out path, *before* the failover, `_finalize_worker` looks at what is actually on disk (`tee`
has already flushed every event the CLI emitted):

1. Best-effort `extract_answer` over the **partial** `run-<id>.jsonl`. If it yields an answer that
   `answer_unusable` rejects (auth-death dump, error envelope served as text), the `res` file is
   deleted and today's failover runs — a truncated stream must never launder a bad answer into a
   `done`.
2. **Write card** (`queue/<id>.write` present): the decision is the success path's own FR-R11 diff
   gate, verbatim (`_write_target_changed` — one shared function, not a copy). Real bytes newer than
   the pre-spawn baseline = real work, even with no handoff at all (backlog-10's exact shape).
   **Read card:** a usable extracted answer is the evidence.
3. Neither holds → **byte-identical** to today's timeout failover.

A salvaged card finalizes as **`done`** with the worker's real (nonzero, killed) rc, and the bus
transition is literally the success path's (`_archive_and_release`): prompt + write-target
provenance archived for the verify wave, claim file and `.lane`/`.write`/`.chain` sidecars and the
wait marker dropped, chain reset, `.dead`/`.broken` cleared, kimi spend accumulated, `ledger_row`
written. Speedwars outcome is **`timeout-salvaged`** with **no `class`** — spec 12 FR-1's vocabulary
types non-`done` outcomes, and this branch has a done marker (absence-means-absent). The distinct
outcome keeps it out of `feedback_stubs`' exact `outcome=="timeout"` match: a salvaged card is
evidence, not an incident to file. The lane is still never `.limited` (round-3 amendment above
stands) — salvage adds no lane-level penalty in either direction.

`TIMEOUT_SALVAGE=0` (env only, **not** a `conf_load` key — it is an escape hatch for reproducing
pre-salvage behavior during an incident, not a tuning knob an operator should be encouraged to bake
into `swarm.conf`) restores the discard-everything path exactly.

**Deliberately not built (ponytail ceiling):** no TERM-then-KILL grace window and no partial-stream
repair. Salvage only rescues what the CLI had already flushed — a worker killed mid-write of its
handoff is still lost. If that proves too narrow, the upgrade path is a grace window in the
watchdog (`kill_subtree $mypid TERM`, sleep `WORKER_TERM_GRACE_SEC`, then KILL), which lets a
well-behaved CLI finish its handoff; FR-13's "SIGKILL directly" rationale would have to be revisited
alongside it.

## Amendment 2026-07-25 — claim-lifecycle guards (backlog 55, 56)

Two ways the bus loses or duplicates work, both surfaced by the `refinery-01` archive and both
ranked MUST-fix against 2025-26 lease practice (SQS visibility timeouts, Temporal/Sidekiq/BullMQ
heartbeat leases; MAST FM-1.3 puts this failure family at 15.7% of observed multi-agent failures).
Neither is a new mechanism — both are guards on movers that already exist.

### FR-A — Reap must not release a live claim (backlog 55)

`reap` (`src/swarm-lib.sh:309-324`) requeues any claim file whose mtime is older than `LEASE_MIN`,
and the heartbeat that keeps that mtime fresh dies with the pool that owns it. So when a pool exits
while a worker's CLI grandchild is still running — or the heartbeat subshell is otherwise lost —
the next pool's reap hands a **still-executing** card to a second worker. Two workers, one id, one
write target.

Before the `mv "$f" "$busdir/queue/$id.prompt"` at `src/swarm-lib.sh:322`, skip the release when
**either**:

- `kill -0 "$(<"$busdir/pids/$id")"` succeeds (the pid registry written at `swarm-run.sh:398`,
  cleared at `:444`), **or**
- `run-<id>.jsonl`'s mtime is fresher than `LEASE_MIN` — a stream still being written is a live
  worker whatever the pid table says.

The single-host bus makes the pid check valid across pools; the mtime check covers pid reuse.

**Binding mitigations** — the guard is unsafe without all three:

1. **Hard age cap.** NEVER skip a claim older than the cap, regardless of pid or
   mtime evidence. Pid reuse makes `kill -0` succeed forever, and a SIGKILLed spawn never reaches
   its `rm -f "$BUSDIR/pids/$id"` at `swarm-run.sh:444` — so without the cap a stale claim becomes
   **immortal**, and every subsequent relaunch hangs at the completeness gate with the card neither
   done nor reclaimable. The cap is what keeps a liveness guard from becoming a deadlock.
   **Amended at cross-review (2026-07-25):** the cap is measured **past the lease** —
   `LEASE_MIN×60 + 2× the resolved per-lane timeout` (FR-C's `${TIMEOUT_<LANE>:-$WORKER_TIMEOUT_SEC}`)
   — not a bare `2× timeout` from the claim's mtime. Reap only ever *sees* claims already
   ≥ `LEASE_MIN` stale, so at shipped defaults (lease 900 s, timeout 300 s) a bare 2×-timeout cap
   (600 s) fired before any liveness evidence was consulted and the entire guard was dead code
   (reproduced: a claim with a live pid and a fresh run log was age-capped). Measured past the
   lease, the guard protects an orphan worker for its plausible remaining runtime, and the cap
   still breaks pid-reuse immortality.
2. **Vacuous pass.** A missing `pids/<id>` file or a missing `run-<id>.jsonl` means *no evidence of
   life*, not *evidence of death* — the guard passes and reap proceeds exactly as today. This also
   keeps every existing bats fixture green without editing it.
3. **Say who moved it.** One stderr line naming the mover, in **both** movers — `reap` here, and
   the finalize-tail requeues at `swarm-run.sh:658`, `:667`, `:807`. The `refinery-01` incident may
   have been the finalize-tail mover (an escaped CLI grandchild plus a fence-valid finalize), which
   this guard cannot fix; without attribution in the log the next incident is un-diagnosable and
   the guard gets credited for a fix it did not make. **Pre-flight evidence verdict (2026-07-25,
   refinery-01 archive forensics):** the mover WAS `reap` — finalize-tail is structurally ruled out
   (it only runs after the worker's foreground CLI pipeline has exited; the tee pipe blocks
   `wait -n` until then, so it cannot release a claim whose worker is still writing). FR-A is the
   correct fix for backlog 55; the attribution lines stay binding regardless, for the next incident.

**Heartbeat fix (same change).** `heartbeat`'s bare `touch` (`src/swarm-lib.sh:295-298`) becomes
`touch -c`. A heartbeat firing after its claim was released currently **re-creates** the claim file
— resurrecting a lease for a card that is already back in `queue/` and claimable, which is the
double-claim this FR exists to prevent arriving through the back door. One flag.

### FR-B — The spec sweep must skip terminal and in-flight ids (backlog 56, closes backlog 13)

`_enqueue_pending_specs` (`swarm-run.sh:891-909`) moves every `specs/<id>.prompt` plus its sidecars
into `queue/`, unconditionally. Re-run the driver against a bus whose seeder re-wrote `specs/` and
finished work is enqueued again: a card already in `done/` is re-executed, a card in `cancelled/`
is resurrected, and a card currently **claimed** gets a second prompt in `queue/` under the same id.

The **terminal-state guard runs at the top of the loop body, before any sidecar `mv`.** Position is
load-bearing: sidecars move first by design (comment at `:886-890`), and an orphan `.write` landing
in `queue/` silently re-grants write access to a stale target (`src/swarm-ctl:82-90`) — a guard
placed after the first `mv` has already done the damage it exists to prevent.

**Amendment 2026-07-29:** the specs/-to-queue/ sweep refuses (loud stderr, all of the card's files left in specs/, sweep continues) any card whose prompt or existing .lane/.write/.chain/.files sidecar is empty or whitespace-only — direct specs/ seeding bypasses swarm-ctl add's validation, and an existing-but-empty card file is never legitimate. Refusal runs AFTER the done/cancelled discard arms (stale empty sidecars of terminal ids are still discarded).

**New verb (2026-07-29): lint-specs [busdir].** Read-only preflight over specs/ and queue/ — validates non-empty prompt, non-empty .write naming an existing directory, .files valid per spec 14 FR-2's publish-time validator, .lane/.chain tokens on the six-lane roster (bare tokens pass; claim-time normalization per spec 10 FR-R15 resolves them). Per-card OK/FAIL lines; exits nonzero when any card fails; writes nothing.

**Skip set** — four states, and the resolution method matters for the third:

- `done/<id>` — the card finished.
- `cancelled/<id>.prompt` — the card was deliberately pulled.
- **claimed**, resolved via `_claim_of` (`src/swarm-lib.sh:326-345`) — **never a bare glob**.
  `claimed/"$id".*` prefix-matches, so id `foo` also matches a claim for dotted id `foo.bar`
  (documented at `swarm-lib.sh:326-332`); a glob here would skip the wrong card and enqueue the one
  that is actually running.
- `queue/<id>.prompt` — already queued. Not merely redundant: a reap-requeued prompt may carry a
  `cmd_nudge` OPERATOR HINT block, and the sweep's `mv` would clobber it with the pristine `specs/`
  copy, silently discarding the operator's instruction.

**Disposition** differs by state, and neither option is a re-run:

- `done/` or `cancelled/` → **consume and discard** the `specs/` entry, with one stderr line naming
  the id and the state. The work is over; leaving the file would re-trigger the same line on every
  relaunch forever.
- claimed or queued → **non-destructive skip**: leave the `specs/` file exactly where it is, plus
  one **loud** stderr line. The card is in flight and the seeder may still be mid-write; deleting
  its source is not the sweep's call to make.

`swarm-ctl add` and `swarm-ctl nudge` are the redo verbs. Re-running the driver is not one, and
this guard is what makes that true — belt-and-braces beside `swarm-ctl add`'s own EEXIST
reservation, standard idempotent-enqueue practice (BullMQ/Quartz). The same guard closes backlog 13.

`queue/<id>.files` (spec 14 FR-2) joins the skip-everything list **in the same commit as FR-2** — a
sidecar the sweep knows how to move but not how to skip is the next instance of this bug.

### Acceptance criteria (amendment)

- [ ] **FR-A reap matrix:** stale claim mtime + live pid → **not** reaped; stale claim +
      `run-<id>.jsonl` fresher than `LEASE_MIN` → **not** reaped; dead pid + stale everything →
      requeued (today's behavior); missing `pids/<id>` → requeued; missing run log → requeued; a
      claim older than the age cap → **reaped even with a live pid** (pid-reuse case). A heartbeat
      fired against an already-released claim leaves `claimed/` empty.
- [ ] **FR-A attribution:** every requeue — `reap` and all three finalize-tail movers — emits
      exactly one stderr line identifying the mover and the id.
- [ ] **FR-B skip set:** an id in `done/`, in `cancelled/`, or holding a live claim is not
      enqueued; `done`/`cancelled` ids leave no `specs/` file and log one line; claimed/queued ids
      leave the `specs/` file in place and log one loud line; a queued prompt carrying an OPERATOR
      HINT block is not overwritten; a fresh id is swept exactly as today, sidecars first.
- [ ] **FR-B dotted ids:** with claims present for both `foo` and `foo.bar`, the guard resolves each
      id's own claim — bats asserts the wrong-card skip does not occur.
- [ ] **Live drill:** a sleeping worker holding a claim survives a second pool's reap; killing the
      worker releases the claim after the lease expires.

---

## Design

### Bus lifecycle

```
.bus/specs/<id>.prompt        authored by Fable (files, never strings)
     │ mv
     ▼
.bus/queue/<id>.prompt        claimable work
     │ rename to unique dest (loser: ENOENT)
     ▼
.bus/claimed/<id>.<worker>    lease; mtime = heartbeat clock
     │ worker exits, marker dropped
     ▼
.bus/done/<id>                completion marker (gates synthesis)

.bus/cancelled/<id>.prompt    pulled from specs/ or queue/ — excluded from the gate's live count
.bus/run-<id>.jsonl           one append-only JSONL per worker (glance-only firehose)
.bus/res-<id>.txt             the answer — from the CLI's own handoff, one writer
.bus/run.pgid                 scheduler's process group id (abort target)
.bus/PAUSE                    presence blocks new claims
```

### Lane invocations (live-verified, `01-feasibility-tests.md` §D/E, corrected per `02-build-pitfalls.md`)

```bash
# CODEX — answer is the --output-last-message file itself, never parsed from jsonl
codex exec --json --output-last-message .bus/res-$ID.txt \
  -s workspace-write --skip-git-repo-check -C "$WORKTREE" -m "$MODEL" --ephemeral \
  "$(cat .bus/specs/$ID.prompt)" | tee .bus/run-$ID.jsonl >/dev/null

# GEMINI — trust gate + explicit model mandatory (0.49 exits 55 without it); 2>/dev/null before jq, always
GEMINI_CLI_TRUST_WORKSPACE=true gemini -m gemini-3-flash -o stream-json \
  -p "$(cat .bus/specs/$ID.prompt)" 2>/dev/null | tee .bus/run-$ID.jsonl >/dev/null
# answer: concatenate assistant delta contents — jq -rj 'select(.type=="message" and .role=="assistant") | .content'
# LIVE-VERIFIED 2026-07-08: the 0.49 stream-json result event carries ONLY {stats,status,timestamp,type} —
# NO .response field (the research digest was wrong). Log SERVED model from stats.models keys (aliasing).

# CLAUDE (native lane, incl. verify) — answer from the last stream-json `type=="result"` event's .result
claude -p --output-format stream-json --verbose --model "$MODEL" \
  "$(cat .bus/specs/$ID.prompt)" | tee .bus/run-$ID.jsonl >/dev/null

# GLM — child-env ONLY (never global — hijacks Fable's own Anthropic auth). Model via tier envs, not --model.
env -u ANTHROPIC_API_KEY \
    ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic \
    ANTHROPIC_AUTH_TOKEN="$Z_AI_CODING_KEY" \
    ANTHROPIC_DEFAULT_HAIKU_MODEL=glm-4.7 ANTHROPIC_DEFAULT_SONNET_MODEL=glm-5.2 ANTHROPIC_DEFAULT_OPUS_MODEL=glm-5.2 \
    API_TIMEOUT_MS=3000000 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
  claude -p --output-format stream-json --verbose "$(cat .bus/specs/$ID.prompt)" \
  | tee .bus/run-$ID.jsonl >/dev/null
```

Every jq consumer of `run-*.jsonl` parses defensively: `fromjson? // empty` — tolerates unknown
`type` values and non-JSON banner lines across CLI-version drift. Handoff extraction is per-lane
(comments above): codex reads its `res-<id>.txt` file directly; claude/GLM/gemini extract from the
last `type=="result"` jsonl line (`.result` / `.response` respectively).

---

## Boundaries

- **Always**: keep `.bus` on a local POSIX filesystem only (never a 9p/drvfs/NFS mount); write
  prompts as files, never shell-interpolate or send-keys them; one writer per `run-<id>.jsonl`;
  record `run.pgid` at scheduler start; grep individual keys from `$ENV_MASTER_FILE` (never
  `source` the whole file).
- **Ask first**: raising `FANOUT` beyond the configured ceiling for a single run; adding a 5th
  lane.
- **Never**: synthesize before every live spec has a `done/` marker; run unattended before Phase 2
  containment (env scrub + sandboxed web worker) ships (`DECISIONS.md` Q2); let `ANTHROPIC_API_KEY`
  leak into a GLM child env.
- **Containment state (2026-07-08):** env-cage (env -i + scratch HOME + single granted key) SHIPPED
  for all 6 lanes. **Container sandbox for the web-facing gemini lane SHIPPED, opt-in (FR-16,
  `GEMINI_SANDBOX=docker`, default off)** — `docker run --rm -i` + explicit `-e` allowlist + the
  pinned `unimatrix-gemini-lane:0.49.0` image (`docker/gemini-lane.Dockerfile`), no host mounts,
  live-verified end to end. gemini's own `--sandbox` flag is still never used (unchanged finding —
  it re-execs the CLI inside its own Docker with its own env allowlist, stripping our contract
  vars). **Policy (ruled at review 2026-07-08):** the before-unattended gate (`DECISIONS.md` Q2)
  is satisfied ONLY when the gemini lane runs sandboxed — any unattended/cron-driven run MUST set
  `GEMINI_SANDBOX=docker` (with the pinned image built); the attended default stays off so the
  zero-dependency path keeps working when the docker daemon isn't up. Flipping the default to
  `docker` outright is the operator's call, not a build decision.

---

## Acceptance Criteria

- [ ] **Kill-a-worker test:** start a run, `kill -9` a claimed worker mid-execution. The lease's
      heartbeat goes stale, the reaper reclaims it back to `queue/`, it gets re-claimed and
      re-run, and synthesis stays blocked until all N branches show a `done/` marker.
- [ ] **Claim-race test:** two claimers attempt `queue/<id> → claimed/<id>.<worker>` for the same
      `<id>` simultaneously. Exactly one rename succeeds; the other fails `ENOENT` and does not
      duplicate work.
- [ ] **PAUSE test:** `touch .bus/PAUSE` before a new claim attempt — no new spec is claimed while
      the flag exists; in-flight workers are unaffected; `rm .bus/PAUSE` resumes claiming.
- [ ] **Gate math test:** with N=4 specs, cancel one (moved to `cancelled/`) and add one mid-run
      (dropped into `queue/`) — the gate unblocks at `done/` count 4 (3 original survivors + 1
      added), not 4 of the original N, and not 5.
- [ ] Abort test: `kill -- "-$(cat .bus/run.pgid)"` terminates the scheduler and all in-flight
      workers; no orphaned processes remain.
- [x] **Timeout-salvage test** (FR-12 amendment 2026-07-25): a worker that emits a complete answer
      and then hangs past `WORKER_TIMEOUT_SEC` finalizes `done` with outcome `timeout-salvaged`,
      real nonzero rc, no `class`, and a fully cleaned bus; a write card whose target changed does
      the same with provenance archived; an unusable partial, an unchanged write target, and
      `TIMEOUT_SALVAGE=0` each keep today's failover. `bats tests/swarm-run.bats -f 'backlog 17'`

**Verification commands:**
```bash
# bats-core 1.13.x suite exercises claim races, lease reclaim, gate math, and PAUSE — see 02-build-pitfalls.md §9.
# Engine unit tests live in tests/swarm-lib.bats; the driver/pool integration tests in tests/swarm-run.bats.
bats tests/swarm-lib.bats tests/swarm-run.bats
```

---

## Open Questions

None — GLM-now, attended-v1, Fable-as-orchestrator resolved in `DECISIONS.md`.

---

## Dependencies

**Internal:** `PRD.md` §3-6, `DECISIONS.md`, `docs/02-build-pitfalls.md` (PLAN DELTAS §1-2,4-8),
`docs/01-feasibility-tests.md` §D-E, `docs/versions.md`.
**External:** `claude` 2.1.204+, `codex` 0.143.0+, `gemini-cli` 0.49.0+ (npm channel only), bash
≥5.1, `Z_AI_CODING_KEY` for the GLM lane.
