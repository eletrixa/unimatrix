# Usage — Driving UNIMATRIX

Operator guide: how to actually run `/swarm` and `/swarm-loop` on this box (or any box with the
same CLIs installed). For design rationale see `specs/`; for what broke during the build see
`docs/02-build-pitfalls.md`. This doc only describes behavior that exists in the code today —
where a spec requirement isn't wired yet, it says so.

**Status: attended by default.** Every run in this doc assumes a human operator, in a Claude Code
session, is watching. An unattended/cron-driven run additionally REQUIRES the containerized gemini
lane (`GEMINI_SANDBOX=docker` in `swarm.conf` or the env, FR-16): build the pinned image once with
`docker build -t unimatrix-gemini-lane:0.49.0 -f docker/gemini-lane.Dockerfile docker/` — the lane
then runs in `docker run --rm` with only `GEMINI_API_KEY` + `GEMINI_CLI_TRUST_WORKSPACE` forwarded
and zero host mounts. With docker missing or the sandbox unset, run attended only.

---

## 1. One-time setup

Six lanes — `claude`, `codex`, `gemini`, `glm`, `grok`, `kimi` — three different auth shapes.
`lane_cmd` (`src/swarm-lib.sh`) builds every worker
invocation inside `env -i` — no lane ever sees your shell's ambient env, only what's listed below.

| Lane | Auth mechanism | What you do once |
|------|-----------------|-------------------|
| `claude` | OAuth session, copied into a scratch `$HOME` per spawn (`.claude/.credentials.json` + `.claude.json`) | Already logged in if `claude` works in your normal shell — nothing extra. |
| `codex` | `~/.codex/auth.json`, copied into a scratch `$HOME` per spawn | One-time: `printenv OPENAI_API_KEY | codex login --with-api-key` — the plain env var alone 401s on the current websocket Responses endpoint (`docs/02-build-pitfalls.md` #11). `OPENAI_API_KEY` itself only needs to exist in your shell for this one login command; workers never see it again. |
| `gemini` | `GEMINI_API_KEY`, grepped fresh from `$ENV_MASTER_FILE` at every spawn, injected into that one child process | Nothing to log in — just make sure `GEMINI_API_KEY=...` is a line in `$ENV_MASTER_FILE`. `GEMINI_CLI_TRUST_WORKSPACE=true` is set automatically by every gemini invocation the runner builds — you never set it yourself. |
| `glm` (Z.ai) | `Z_AI_CODING_KEY`, grepped fresh from `$ENV_MASTER_FILE` at every spawn, injected as `ANTHROPIC_AUTH_TOKEN` on a child-only `claude -p` | Nothing to log in — just make sure `Z_AI_CODING_KEY=...` is a line in `$ENV_MASTER_FILE`. |

Where keys live: **`$ENV_MASTER_FILE`** (default
`${XDG_CONFIG_HOME:-$HOME/.config}/unimatrix/env.master`). The
runner greps one `^NAME=` line per key it needs (`_env_master_key` in `src/swarm-lib.sh`) —
**never `source` the file** (an env-master file can hold lines that aren't bash-sourceable, and
sourcing the whole thing would leak every credential in it into whatever shell did the sourcing). If a key is missing, the
affected lane fails loudly (`_env_master_key: ... not found`, `rc=1`) rather than silently degrading.

Nothing else to install beyond the four CLIs + bash ≥5.1 + `jq` + `bats-core` — see
`docs/versions.md` for pinned versions and re-smoke triggers.

---

## 2. `/swarm` from Claude Code

This is the normal way to drive a run — you're talking to Fable (this session), not touching bash
directly. Full contract: `.claude/commands/swarm.md`.

### One-shot: `/swarm "<question>"`

Fable (this session):
1. Decomposes the question into 2–`FANOUT` independent branches.
2. Writes each branch as its own file at `.bus/specs/<id>.prompt` — never interpolated into a
   shell string or keystroke stream.
3. Runs `./swarm-run.sh` to move those specs into `queue/` and fan them out over the 6 lanes.
4. Waits for the completeness gate (every live branch has a `done/` marker, or is parked) before
   reading anything.
5. Runs `./swarm-run.sh verify` — a second wave that cross-checks each branch's answer on a
   *different* lane (`VERIFY_MAP` in `swarm.conf`), and waits for that gate too.
6. Reads each `res-<id>.txt` and its `res-v-<id>.txt` verify verdict (never `run-<id>.jsonl`
   prose), then synthesizes an answer in this conversation.

### Plan-first: bare `/swarm`

If you and Fable already agreed on a decomposition earlier in the conversation, bare `/swarm`
skips step 1 — it converts the already-agreed branches straight into `.bus/specs/<id>.prompt`
files and continues at step 3.

### Research branches

A branch that needs its own web research runs that research *inside* its own worker (one bus
file, one `done/` marker) — Fable pins it to a `claude:<model>` lane via a `<id>.lane` sidecar,
since only claude's bundled research workflow does deep multi-step research; gemini/codex/glm
don't get routed research branches.

### Hard rules Fable follows here (non-negotiable)

- Prompts travel as files only, never shell-interpolated.
- No synthesis before the gate — a partial result set is never adjudicated.
- Every spawned run gets a line in `docs/ops/llm-runs.md` (automatic — `LEDGER_AUTO=1`).
- Judge ≠ executor, both for `REVIEW` and for the verify wave's `VERIFY_MAP`.

---

## 3. Driving the engine directly (no Claude Code)

Useful for testing, or if you're scripting something outside a Fable session. Everything below is
plain bash + the bus.

### Bus layout (`.bus/`)

```
.bus/specs/<id>.prompt        # a branch, written by hand or by Fable
.bus/specs/<id>.lane          # optional: pin this branch to one lane:model (bypasses EXEC_CHAIN)
.bus/queue/<id>.prompt        # claimable work (enqueue moves specs/ -> here)
.bus/claimed/<id>.<lane>      # in-flight lease; mtime = heartbeat
.bus/done/<id>                # completion marker: {"id","code","lane"}
.bus/cancelled/<id>.prompt    # pulled branches — excluded from the gate
.bus/run-<id>.jsonl           # raw per-worker event stream (glance-only, never the answer)
.bus/res-<id>.txt             # the answer, extracted from the CLI's own handoff
.bus/prompt-<id>.txt          # archived original prompt (written on successful finalize)
.bus/limits/<lane>.limited    # active rate-limit flag + its TTL (file content = seconds)
.bus/limits/<id>.parked       # this branch's chain (or pinned lane) is exhausted — terminal
.bus/pids/<id>                # this worker's own pid, for swarm-ctl kill / the watchdog
.bus/run.pgid                 # the pool's process group id — swarm-ctl abort's target
.bus/PAUSE                    # presence blocks new claims; in-flight work is unaffected
```

### Writing a branch by hand

```bash
mkdir -p .bus/specs
printf '%s\n' "What is the capital of France?" > .bus/specs/geo.prompt

# optional: pin this branch to one lane, bypassing EXEC_CHAIN entirely
echo "codex:default" > .bus/specs/geo.lane
```

### Run it

```bash
./swarm-run.sh                # enqueues specs/, drains the pool, prints res-*.txt paths
./swarm-run.sh verify          # cross-model verify wave over every done/ branch since the last run
```

### Config

```bash
./swarm-run.sh config                       # print the fully resolved table (file over defaults)
./swarm-run.sh config EXEC_CHAIN "codex:default gemini:gemini-3-flash"   # edit swarm.conf in place
```

### Plan without running anything

```bash
./swarm-run.sh --plan-only "What is the capital of France?"
```
Prints the resolved config table + the lane map that *would* run — writes `run.pgid` and inits the
bus, but enqueues nothing.

### Reading answers

```bash
cat .bus/res-geo.txt          # the answer — never cat run-geo.jsonl for this
cat .bus/res-v-geo.txt        # if you ran `verify`, the cross-model verdict on that answer
```

### Exit codes

`swarm-run.sh` (both the default run and `verify`) exits **0** only if every live branch reached
`done/`. If anything ended up in `.bus/limits/*.parked` (its `EXEC_CHAIN` — or pinned lane —
exhausted before finishing), the run exits **nonzero** and lists each parked id on stderr. There
is no such thing as a silent partial run: partial completion is always loud and always nonzero.

### Direct call: `call`

One verb points a single lane at a prompt (or `@<file>`) through the unmodified engine — same
harness, gate, cockpit and evidence as any other run, just one staged card instead of a
decomposition:

```bash
unimatrix call glm "explain this diff"
./swarm-run.sh call glm "explain this diff"     # equivalent — the router just execs into this
```

Default is a **hard pin** (`.lane` sidecar): the card bypasses `EXEC_CHAIN` and, if its lane is
blocked, waits up to `PIN_WAIT_SEC` then parks loudly rather than ever silently switching lanes.
`--chain '<lane[:model]> ...'` writes a `.chain` sidecar instead — primary lane prepended, first
recognized limit hops to the next lane in that list — and no `.lane` is written (pin and chain
never coexist on one card).

**Bulk example — rewrite a header across 4000 files:**

```bash
find src -name '*.py' > /tmp/files.txt                       # 4000 paths

# probe-card-first: size --batch from one real card, never a guess
head -1 /tmp/files.txt > /tmp/probe.txt
unimatrix call glm "@rewrite-header.prompt" --files /tmp/probe.txt --batch 1 --id probe --write /path/to/repo
jq 'select(.id=="probe-001") | .wall_secs' docs/ops/speedwars.jsonl     # e.g. 42

# batch * per-file-secs <= WORKER_TIMEOUT_SEC/2 — write calls default WORKER_TIMEOUT_SEC=1200
# (FR-9), so the budget is 600s: floor(600/42) = 14
unimatrix call glm "@rewrite-header.prompt" --files /tmp/files.txt --batch 14 --id hdr --write /path/to/repo

# wall-clock estimate: cards = ceil(4000/14) = 286; ceil(286/FANOUT=4) = 72 rounds * ~9.8min/card ≈ 12h
```

Runbook notes:
- **Park-storm resume:** verify the provider window actually reset first — e.g. the z.ai quota
  endpoint (`GET api.z.ai/api/monitor/usage/quota/limit`) before a big GLM run — then
  `unimatrix unpark --all`, clear the stale `limits/<lane>.limited` flag, and re-run the same bus
  with `BUSDIR=<path> unimatrix run` so the now-unparked cards get picked back up.
- **Check for served-model mismatch** in the speedwars rows — a card's `served_lane`/`served_model`
  can differ from what you asked for on a chain hop, so don't assume the requested lane answered.
- Bulk buses live on a roomy local disk and are deletable after close-out — the evidence that
  matters persists in speedwars plus the one aggregate `docs/ops/llm-runs.md` row (FR-11), not
  the bus itself.
- Use the web cockpit (§7) for bulk runs — the tmux firehose does not follow logs born after it
  started watching.
- Bulk prompts must be idempotent: any retry (lease reap, chain hop, watchdog kill) re-runs the
  card's whole chunk from the top, including files it already touched.

### Unified CLI: `./unimatrix`

`./unimatrix <verb> [args...]` is a thin router: it `exec`s straight into `swarm-run.sh`,
`swarm-loop.sh`, `swarm-mon.sh`, or `src/swarm-ctl` with argv and env untouched, so every var in
§4 works exactly as if you'd called the target script yourself. All four scripts stay directly
invocable — the router is a front door, not a replacement. `alias u=unimatrix` is an operator
opt-in this repo documents but never installs.

---

## 4. `swarm.conf` reference

One flat bash-sourceable file. Precedence: **already-set env var > `swarm.conf` > baked-in
default** (`conf_load` in `src/swarm-lib.sh`), resolved independently per key.

| Key | Default | Effect |
|-----|---------|--------|
| `PLAN` | `fable` | Decomposition/spec-writing role. Always in-session — never spawned. |
| `ORCHESTRATOR` | `fable` | Gate/adjudicate/steer/synthesize role. Always in-session — never spawned. |
| `REVIEW` | `codex:default` | The audit/verify role for `/swarm`'s `REVIEW` key; must differ from the exec lane in use. |
| `EXEC_CHAIN` | `"claude:opus glm:glm-5.2"` | Space-separated `lane:model` fallback chain, tried left→right on a recognized limit signal. |
| `MAX_ITERATIONS` | `10` | `/swarm-loop` iteration cap (stop rule). |
| `BUDGET_USD` | `0` | `/swarm-loop` budget cap in USD; `0` = no cap. |
| `FANOUT` | `4` | Job-pool concurrency ceiling — max workers running at once. |
| `LEASE_MIN` | `15` | Minutes of heartbeat silence before the reaper reclaims a claim back to `queue/`. |
| `WORKER_TIMEOUT_SEC` | `300` | FR-12 wall-clock watchdog — a worker still running past this is SIGKILLed (whole subtree) and treated as a failed attempt. |
| `MAX_LANE_RETRIES` | `3` | Consecutive unusable-answer retries per lane before the spec fails over (chain-advance, or parks when pinned/exhausted) — bounds FR-6's retry-same-lane so a persistently broken lane can't respawn (and bill) forever. |
| `VERIFY_MAP` | `"claude:codex codex:claude gemini:claude glm:codex"` | Cross-model verify-wave rotation (generator lane → verifier lane); an unmapped generator still gets a lane that provably differs from it. |
| `LEDGER_AUTO` | `1` | Auto-append a `docs/ops/llm-runs.md` row on every successful branch finalize. Set `0` only for tests. |
| `GEMINI_SANDBOX` | *(empty)* | FR-16: `docker` runs the gemini lane in the `unimatrix-gemini-lane` container (no host mounts); empty = today's unsandboxed lane. |
| `MON_PORT` | `4747` | Web cockpit port (`site/server.mjs`, Ground Control unit `svc-unimatrix`, specs/05). |
| `MON_AUTOOPEN` | `1` | Auto-ensure the web cockpit + auto-open the browser on swarm start; `0` disables both. |

Edit directly or via `./swarm-run.sh config <KEY> <value>` (see §3).

---

## 5. Mid-run control — `src/swarm-ctl`

Bus-only verbs, no daemon. Run from a normal shell (or the cockpit's CONTROL pane, §6).

| Verb | Effect |
|------|--------|
| `swarm-ctl pause` | `touch .bus/PAUSE` — blocks new claims. In-flight workers keep running to completion untouched. |
| `swarm-ctl resume` | `rm .bus/PAUSE` — claiming resumes. |
| `swarm-ctl cancel <id>` | Pulls `<id>` out of `specs/` or `queue/` into `cancelled/` — removed from the gate's live count, doesn't block synthesis. |
| `swarm-ctl add <promptfile>` | Copies a new prompt file into `specs/`, then straight into `queue/` — injects a branch mid-run. |
| `swarm-ctl abort` | `kill -- "-$(cat .bus/run.pgid)"` — kills the whole pool process group, every in-flight worker included, in one shot. |
| `swarm-ctl status` | Prints `gate: done=<n> live=<n>` plus every currently-active `.limited` flag. |
| `swarm-ctl kill <id> [--cancel]` | Kills that one worker's whole process subtree (`kill_subtree`, from the pid registered at `.bus/pids/<id>`) and either requeues its claim (default) or moves it to `cancelled/`. |

**`.bus/PAUSE` semantics**: it's checked once per claim attempt (`_try_claim_one`), not per
worker — presence only stops *new* claims from starting. It does not pause, suspend, or signal
anything already running.

**The lease reaper** (`reap()` in `src/swarm-lib.sh`, called every pool loop iteration): any
`claimed/<id>.<lane>` file whose **mtime** (not creation time) is older than `LEASE_MIN` minutes
gets moved back to `queue/<id>.prompt` for re-claiming. Workers `touch` their own claim file
periodically (`HEARTBEAT_SEC`, default 30s in `swarm-run.sh`) precisely so a slow-but-alive worker
isn't mistaken for a dead one — the reaper only fires on silence, not on age.

---

## 6. Cockpit — `swarm-mon.sh`

Read-only tmux monitor on an isolated socket (`tmux -L swarm`) — it never writes to the bus except
through whatever you type by hand in the CONTROL pane.

```bash
./swarm-mon.sh              # bootstrap the 4-pane cockpit (idempotent — no-ops if already up)
./swarm-mon.sh --wezterm    # also spawn a read-only WezTerm window on the Windows side
```

### Pane map

| Pane | Position | Content |
|------|----------|---------|
| BOARD | top-left | `watch -n2` render of queued/claimed/done/cancelled counts, stale leases, active limit flags, parked branches. |
| COST | top-right | `ccusage` if installed, else a best-effort per-lane token summary from `run-*.jsonl`. |
| FIREHOSE | bottom, full width | `tail -F run-*.jsonl \| jq -Rrc --unbuffered ...` — glance-only event stream, never the source of truth for an answer. |
| CONTROL | strip under FIREHOSE | An interactive shell with `src/` on `PATH` — run `swarm-ctl` verbs here. |

### Attaching read-only

```bash
tmux -L swarm attach -r -t mon                 # from WSL — -r is read-only, no accidental keystrokes
wsl.exe -- tmux -L swarm attach -r -t mon       # from a Windows terminal/PowerShell
./swarm-mon.sh --wezterm                        # spawns that same WSL attach inside a new WezTerm window
```

**Detach safety**: `Ctrl-b d` (or `Ctrl-b D` from a read-only client) just detaches your viewing
client — the session and every pane's underlying process keep running. Nothing about detaching
stops a run; only `swarm-ctl abort`/`pause`, or killing the driver process directly, does that.

---

## 7. Web cockpit (Ground Control)

A second, browser-based cockpit alongside the tmux one (§6) — same bus-read discipline, but as of
the spec 07 redesign it also ships a real **control surface**: the server itself still never
writes under `BUSDIR` (every mutation is delegated to `src/swarm-ctl` via `execFile`, literal
argv, never a shell), but the browser is no longer read-only end to end. Ships as
`site/server.mjs`, a zero-dependency Node-stdlib server, serving an ES-module client under
`site/cockpit/*.js` (no build step, no npm).

### Four views

Keys `1`–`4` switch views (ignored while focus is in an input); `Esc` closes the agent drawer,
then the settings drawer, then any open dialog, in that order. The active view persists across
reload (`localStorage`).

| Key | View | Content |
|-----|------|---------|
| `1` | **OPS WALL** (default) | Verdict card, up to 3 alert cards, the bus pipeline (SPECS → QUEUE → lanes → HANDOFF → DONE → GATE → VERIFY → SYNTH), a per-agent heat strip, a burn-rate chart, and the MODELS notional-cost strip (spec 06) along the bottom. |
| `2` | **MISSION CONTROL** | A left attention rail (alert cards with inline verb buttons), state + per-lane filter chips, and an agent tile grid sorted trouble-first. |
| `3` | **FLIGHTPATHS** | A rolling time axis with a per-agent segment row (queued/executing/stale/retry/parked/verify), a sort toggle, a done-branches toggle, a zoom chip (5m/20m/60m), and 2 mini charts ($ burn, events/min). |
| `4` | **Firehose** | The original raw SSE tail, kept as the legacy view. |

### Status strip

Below the header: live queue/claimed/done/cancelled counts, a `CLAIMS BLOCKED` chip while paused,
stale/parked/erroring chips (shown only when non-zero), a gate mini-bar, a budget mini-bar
(`$spent / $cap`, or "no cap" / "budget —" when unknown), a burn rate, and per-lane cost chips.

### Agent drawer

Click any agent (heat cell, tile, or flightpath row) to open the right-hand drawer: header
(id/lane/claim age/tokens/notional cost), an amber alarm strip when stale, and 4 tabs — **events**,
**transcript**, **handoff** (`res-<id>.txt`), **spec**. Footer control buttons: **NUDGE**
(kill + requeue with an operator hint, resets park/chain/retry state), **PAUSE**/**RESUME**
(per-worker SIGSTOP/SIGCONT freeze — the reaper skips a frozen claim's lease, so a paused worker
is never double-claimed; note frozen wall-clock time still counts toward `WORKER_TIMEOUT_SEC`, so
a long pause can trip the watchdog immediately on resume), **KILL** / **KILL+CANCEL**, and
**CANCEL** (disabled while claimed). Done/cancelled agents disable every button.

### Header controls

`‖ PAUSE ALL` / `▶ RESUME` toggles `.bus/PAUSE` (same effect as `swarm-ctl pause`/`resume`, §5);
`+ ADD SPEC` opens a dialog to inject a branch mid-run, with an optional lane:model pin and a
write-target directory (grants that branch file-write capability exactly like a hand-written
`.write` sidecar, §8 — a gemini pin is refused, read-only-only lane); a red `ABORT` button is
behind a two-step confirm (`ABORT` → 5 s `CONFIRM ABORT` window → kills the whole pool). A live
text segment shows `run <id> · loop <iter>/<max> · <elapsed>` sourced from `/api/loop` — never an
invented clock; with no active loop it falls back to `run —` with the loop fields omitted.

### `/api/ctl` — the one write endpoint

`POST /api/ctl` is the only endpoint that mutates anything, and it never touches `BUSDIR` itself —
every verb (`pause`/`resume`/`cancel`/`kill`/`nudge`/`pause-worker`/`resume-worker`/`add`/`abort`)
is validated against a frozen verb table, then shelled out to `src/swarm-ctl` via `execFile` with
a literal argv array (same guard pattern as `/api/config`: loopback-only Origin check, body-size
cap, no shell interpolation). `GET /api/agents` (2 s poll), `GET /api/loop`, and
`GET /api/agent?id=<id>` (drawer bodies) are read-only additions alongside the unchanged
`/api/bus`, `/api/cost`, `/api/models`, `/api/stream`, `/api/config`.

### Settings drawer

The existing "⚙ AGENTS" config drawer (spec 05 — exec-chain slots, review lane, numeric run
limits) is unchanged in behavior, just re-homed into the new client under
`site/cockpit/settings.js`.

### Lifecycle, auto-open, degraded mode

- **Auto-opens on swarm start.** The first `swarm-run.sh` or `swarm-loop.sh` invocation of a
  session ensures the server is up and opens `http://localhost:4747/cockpit.html` in the browser
  automatically — no manual step. It opens once per bus lifetime (a marker file in `.bus/`
  suppresses repeat opens on later runs against the same bus).
- **Managed by `gc`** (Ground Control, the fleet server TUI) as unit `svc-unimatrix` on port
  4747 — start/stop/health exactly like any other fleet server. The auto-open path starts it the
  same way `gc` would, so `gc` adopts the already-running unit rather than fighting it.
- **Disabling it:** set `MON_AUTOOPEN=0` in `swarm.conf` to suppress both the auto-ensure and the
  auto-open. The tmux cockpit (§6) is unaffected.
- **Runs independently of the tmux cockpit** — either, both, or neither can be up at once; neither
  one's process ever writes to the other's state.
- **Degrades gracefully against an old server.** If `/api/agents` or `/api/loop` 404 (a server
  that predates spec 07), the cockpit still renders from `/api/bus` plus the SSE stream — agent
  state is rebuilt from SSE worker names with ages shown as `—` instead of failing outright.
- **No fake data** — every rendered number traces back to a bus file or endpoint; absent data
  renders as an em-dash, is hidden, or is explicitly labeled, never invented (FR-14).

Full design: `specs/05-ground-control.md`, `specs/07-cockpit-redesign.md`.

---

## 8. `/swarm-loop`

Second mode: define success criteria once, then iterate exec → oracle → cross-model review until
they genuinely hold or a stop rule fires. Full interview contract: `.claude/commands/swarm-loop.md`
and `rules/unimatrix/loop-discipline.md`.

### The criteria contract (env vars `init` reads)

| Var | Meaning | Required? |
|-----|---------|-----------|
| `LOOP_GOAL` | One sentence describing done. | Required. |
| `LOOP_TIER` | 1–5, the verification ladder — recorded honestly, not branched on (oracle + judge run at every tier regardless). | Optional, default `1`. |
| `LOOP_ORACLE` | The deterministic check command. If a tier genuinely has no real check, set it to `true` and let the judge carry the verdict. | Required (even if `true`). |
| `LOOP_JUDGE` | `lane:model` for the reviewer. Must differ from `EXEC_CHAIN`'s first entry — `init` refuses to write the contract otherwise. | Optional, defaults to `REVIEW`. |
| `LOOP_HUMAN_GATE` | `true`/`false` — `true` makes a goal-hit halt pending until a human touches `HUMAN_OK` (see below). | Optional, default `false`. |
| `LOOP_PLATEAU` | Iterations with no oracle/review progress before halting. | Optional, default `3`. |
| `LOOP_WALL_CLOCK_H` | Wall-clock cap in hours. | Optional, default `4`. |
| `LOOP_INVARIANTS` | Newline-separated list — things that must stay true across iterations. | Optional. |
| `LOOP_CHECKLIST` | Newline-separated list — every item starts `[FAILING]`. | Optional. |
| `TARGET_DIR` | Where the exec/oracle work happens. | Optional, defaults to `$PWD`. |
| `MAX_ITERATIONS` | From `swarm.conf` (see §4), not loop-specific. | — |

### Subcommands

```bash
LOOP_GOAL="fix the failing widget test" LOOP_ORACLE="bats tests/widget.bats" \
  LOOP_JUDGE="codex:default" LOOP_CHECKLIST="$(printf '%s\n' 'widget test passes')" \
  TARGET_DIR="/path/to/worktree" \
  ./swarm-loop.sh init my-run          # writes criteria.md/steering.md/state.jsonl once

./swarm-loop.sh iterate my-run         # runs exactly one exec->oracle->review increment
./swarm-loop.sh run my-run             # iterates until a stop rule fires
```

`init` refuses to re-init over an existing `criteria.md`, and refuses outright if
`LOOP_JUDGE`'s bare lane equals `EXEC_CHAIN`'s first lane (judge ≠ executor, no exceptions).
`criteria.md` is checksum-guarded (`.criteria.sha256`) — every `iterate` call re-verifies it's
byte-identical to what `init` wrote, so nothing (a worker included) can quietly redefine success
mid-run.

### Stop rules and exit codes

`run` checks, in this order, every iteration: **goal hit** (oracle rc 0 + review `pass`) →
oscillation (same oracle-output signature A→B→A over 3 iterations — checked before plateau so a
flip-flop is labelled correctly, not shadowed as "no progress") → plateau → `max_iterations` →
budget (sums each iteration's `.cost` in `state.jsonl` — the claude/glm `total_cost_usd`; codex and
gemini carry no dollar figure and contribute 0, so the USD cap enforces the real-USD claude-lane
spend; `BUDGET_USD=0` = no cap) → wall clock → `.bus/PAUSE` (human abort). First one to fire wins.

- **Exit 0** — goal hit (and, if `human_gate=false`, no further gate).
- **Exit 2** — halted (any non-goal stop rule, or a goal-hit pending human gate).
- **Exit 1** — hard error (bad run-id, missing `criteria.md`, judge==exec, etc. — `_die`).

Every halt writes `.bus/loop/<run-id>/HALTED.md` naming the rule, the last up-to-3 iterations
tried, and a suggested next move. A genuine goal hit writes `COMPLETE.md` instead (oracle output +
review verdict from the passing iteration).

### The `HUMAN_OK` marker

If `LOOP_HUMAN_GATE=true`, a run that would otherwise complete instead halts with rule
`human_gate_pending` (exit 2) and tells you to `touch .bus/loop/<run-id>/HUMAN_OK` once you've
verified it yourself, then re-run `swarm-loop.sh run <run-id>` — it completes on the next pass.

### Worktree behavior for write runs (FR-15)

Per `specs/01-swarm-core.md` FR-15, a branch with a `.bus/specs/<id>.write` sidecar naming a
target directory runs its worker **in that directory with file-write capability** — claude/GLM get
`--permission-mode acceptEdits` with CWD set to the target via `env -C` (no `--add-dir` needed —
the CWD itself is auto-trusted under `-p`; `--dangerously-skip-permissions` is forbidden), codex
uses its native `-C <target> -s workspace-write`, and gemini stays read-only (web/research lane
only) in v1 — a write sidecar on a gemini branch is a loud refusal, never a silent no-op. For
`/swarm-loop`, `init` creates that target as a **scratch git worktree** of `TARGET_DIR`
(`git worktree add -b loop-<run-id>`, base commit recorded as `base_sha` in `criteria.md`) —
never the orchestrator's own tree, so a bad iteration is undone with `git reset` in the worktree
and never touches this repo. `LOOP_GIT_CHECKPOINT=1` additionally commits the worktree once per
iteration. On goal, `COMPLETE.md` names the worktree path and a `git diff --stat` against
`base_sha` — review it there, then merge/cherry-pick into the real tree yourself. A `TARGET_DIR`
that isn't a usable git repo (or has no commits yet) falls back to running directly against it,
with a loud warning: no worktree isolation, no git-reset safety net.

Absent a `.write` sidecar, every branch runs read-only exactly as before — `/swarm` research
branches never get one, and `/swarm-loop`'s judge/review branches never do either.

---

## 9. Failover + limits

`EXEC_CHAIN` (`swarm.conf`, §4) is the fallback order for any branch **without** a `<id>.lane`
sidecar — tried left to right on a recognized limit signal. A branch **with** a `<id>.lane`
sidecar is pinned: no fallback at all — a limit-worthy failure on a pinned lane parks that branch
loudly instead of ever silently switching lanes (FR-2b).

- **`.bus/limits/<lane>.limited`** — created by `limit_flag`, file content is its TTL in seconds
  (default 18000 = 5h; GLM's TTL is read from the provider's own `next_flush_time` when present,
  so the flag expires exactly when the provider says the window resets, not on a guess).
  `limit_active` compares now vs the flag's **mtime** + that TTL — once it ages out, the lane is
  tried again automatically, no daemon, just a `stat` check on the next claim attempt.
- **A normal task error never flips a limit flag** — only a recognized provider signature does:
  GLM z.ai codes `1308/1310/1316-1321/1113` fail over, `1302/1305` retry-with-backoff on the same
  lane; codex needs **2 consecutive** `rate_limit_exceeded`/"usage limit" signals (guards against
  known false 429s near window edges). Same-lane retries are **bounded** by `MAX_LANE_RETRIES`
  (default 3, `.bus/limits/.retries-<id>` counter): a lane that keeps producing no usable answer
  (deprecated model, drifted output shape) chain-advances or parks instead of respawning — and
  billing — forever.
- **Parked branches** (`.bus/limits/<id>.parked`) happen when `EXEC_CHAIN` is exhausted (every
  entry limited) or a pinned lane hits a limit — terminal for that branch. The gate closes at
  `done + parked >= live` so a parked branch can't hang a run forever, but `_check_parked` always
  prints every parked id to stderr and the run exits nonzero — never a silent partial synthesis.

---

## 10. Troubleshooting

Full write-ups: `docs/02-build-pitfalls.md`.

- **gemini exits 55 or 41 headless.** 55 = missing `GEMINI_CLI_TRUST_WORKSPACE=true` (the runner
  sets this automatically — only bites you running gemini by hand outside `lane_cmd`); 41 =
  missing/bad auth. → `docs/02-build-pitfalls.md` item 12.
- **codex 401s even though `OPENAI_API_KEY` is set.** The env var alone doesn't auth the current
  websocket Responses endpoint — run the one-time `printenv OPENAI_API_KEY | codex login
  --with-api-key` (§1). → `docs/02-build-pitfalls.md` item 11.
- **GLM spawn billed the wrong account, or 401s against the z.ai base URL.** Missing `env -u
  ANTHROPIC_API_KEY` on the child spawn — if both `ANTHROPIC_API_KEY` and `ANTHROPIC_AUTH_TOKEN`
  are set, the API key wins. `lane_cmd`'s `env -i` already starts from nothing so this can't
  happen through the runner — only bites a hand-rolled GLM invocation. →
  `rules/unimatrix/model-lanes.md`.
- **Cockpit firehose lags or shows nothing.** The pipeline must be `jq -Rrc --unbuffered` exactly
  — plain `jq -c` (no `-R`, no unbuffered) either buffers ~8KB behind or silently drops every line
  (the filter's `fromjson?` needs raw string input). → `docs/02-build-pitfalls.md` item 6 /
  `rules/unimatrix/bus-discipline.md` "Firehose".
- **Never `source $ENV_MASTER_FILE`.** An env-master file can hold lines that break bash sourcing —
  grep the one key you need instead (`_env_master_key` does this for you already). →
  `docs/02-build-pitfalls.md` item 14.
- **Orphaned worker processes after a kill.** `swarm-ctl kill <id>` and the FR-12 watchdog both
  read the worker's pid from `.bus/pids/<id>` and kill its whole subtree via `kill_subtree` —
  killing just the top-level pid leaves children (e.g. a `codex`/`claude` binary's own forked
  helpers) running. If a pid file is stale/missing, `swarm-ctl kill` says so rather than silently
  no-opping.

## 11. Install as a plugin — `/u:*` from any repo

```bash
unimatrix install          # idempotent: PATH symlink, ~/.config/unimatrix/config,
                           # marketplace + plugin enabled in every account settings file
unimatrix here             # bootstrap the CURRENT repo: local-POSIX fs check (refuses 9p/drvfs/
                           # nfs/cifs), .bus subtree, swarm.conf seed, .gitignore, fleet.json entry
unimatrix report [--html]  # speedwars report; --html writes a self-contained static page
unimatrix doctor --plugin  # manifest/marketplace/UNIMATRIX_HOME checks + install-drift table
```

After `install`, the colon commands (`/u:call`, `/u:swarm`, `/u:loop`, `/u:speedwars`,
`/u:setup`) exist in every Claude Code session on the box, in any repo. Each is a generated
3-line pointer stub: it resolves the engine via `$UNIMATRIX_HOME`, then
`~/.config/unimatrix/config`, then `git rev-parse` — the run banner names the checkout it chose.
The `/u-*` filename forms are deprecated (deleted next release); the bare `/swarm`-style aliases
stay. At every run close the engine prints the three-line lane summary (spec 08's canonical
fold: unjudged is never verified) and archives the run's raw evidence to
`docs/ops/bus-archives/<run-label>/` (zstd/gzip; `BUS_ARCHIVE=0` skips).
