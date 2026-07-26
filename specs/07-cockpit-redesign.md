# Cockpit Redesign — Three-View Agent Cockpit + Control Surface

**Status:** Active
**Date:** 2026-07-19
**Related specs:** [02-cockpit](./02-cockpit.md), [05-ground-control](./05-ground-control.md), [06-live-model-cost](./06-live-model-cost.md)

---

## Overview

The current firehose-first single page (`site/cockpit.html`, served by `site/server.mjs` on
:4747) is replaced by a three-view agent-centric cockpit — **OPS WALL / MISSION CONTROL /
FLIGHTPATHS** — plus the legacy firehose retained as view 4, with a per-agent drill-in drawer and
real control actions. The visual source of truth is the approved Claude Design handoff
(`Unimatrix Cockpit.dc.html`); this spec recreates the rendered output pixel-faithfully in the
cockpit's existing vanilla-JS style — the handoff's mini React-like DSL (`sc-if`/`sc-for`/
`DCLogic`) and `support.js` are **not** ported, only the `renderVals()` derived-value formulas
are, fed from real bus/JSONL data instead of `_rnd()`.

The redesign wires **as much real functionality as possible**: real bus counts, real per-agent
state derived from `run-*.jsonl`, real staleness/lease math from `swarm.conf`, real budget/burn
from the existing cost parser, and real control verbs through a new `POST /api/ctl` endpoint that
shells out to `src/swarm-ctl` via `execFile` (literal argv, never a shell). This flips spec 05's
"no control surface in the web UI (read-only)" non-goal — control lands via `/api/ctl` under the
guards in FR-7. The tmux cockpit (spec 02, `swarm-mon.sh`) is untouched; this is the web surface
only. Same discipline as spec 05: the server reads the bus and delegates every mutation to
`src/swarm-ctl` — the server process itself never writes under `BUSDIR`.

Full implementation detail lives in `plans/002-cockpit-redesign/PLAN.md` (§4 server, §5 client,
§1.1 tokens, §5.3/§5.3b element→data mapping); this spec is the canonical requirements/acceptance
contract and condenses that plan.

## Goals

1. Replace the single firehose page with three agent-centric views (Ops Wall / Mission Control /
   Flightpaths) + legacy firehose as view 4, pixel-faithful to the approved handoff design.
2. Wire real data end-to-end: per-agent state, staleness/lease math, budget/burn, and control
   verbs — every rendered number traceable to a bus file or endpoint.
3. Ship a real control surface (pause/resume claims, per-worker freeze, nudge, kill, cancel,
   abort, add-spec) via `POST /api/ctl` → `src/swarm-ctl`, with spec-05-grade security guards.
4. Hold the line on dependencies: ES-module split served by the existing zero-dep Node server —
   no build step, no npm, no framework, no WebSockets (SSE + polling only).

## Non-Goals

- No framework, no build step, no npm dependencies — vanilla JS ES modules (`<script type="module">`)
  served as static files by the existing `site/server.mjs` (Node stdlib only).
- No WebSockets — SSE (`/api/stream`) plus 2–10 s pollers is sufficient at this scale.
- The tmux cockpit (spec 02, `swarm-mon.sh`) is untouched — this redesign is the web surface only.
- Existing endpoints `/api/bus`, `/api/cost`, `/api/models`, `/api/stream`, `/api/config` are
  **unchanged** (their response shapes are pinned by tests); new consumers use new routes.
- No public live control surface — `/api/*` stays local-only (server binds `127.0.0.1`); on the
  public deploy `/cockpit.html` degrades to the local-only notice and `server.mjs` is excluded
  from asset upload (`.assetsignore`), exactly as in spec 05.
- No porting of the handoff bundle's prototype DSL or `support.js` — only rendered output and
  derived-value formulas are ported.

## Requirements

### Functional

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-1 | Three views — **OPS WALL** (default), **MISSION CONTROL**, **FLIGHTPATHS** — selectable via header nav tabs (active = green text + 2px green bottom border) or keyboard `1`/`2`/`3`; the legacy firehose is retained as **view 4** (`4`). `Esc` closes the agent drawer, then the settings drawer, then any open dialog (in that order). Active view is persisted in `localStorage` (`unimatrix-view`); digit/Esc keys are ignored while focus is in an input. | Must |
| FR-2 | **Header** (52 px, always visible): brand + `▚ Cockpit` badge; the 3 nav tabs; a live text segment `run <loop.run> · loop <iter>/<max> · <elapsed>` (sourced from `/api/loop`; no loop → `run —`, loop/elapsed omitted — never an invented clock); a hint line `1–4 views · esc closes`; a blink-dot SSE-health indicator (green blinking when SSE seen <20 s, amber solid reconnecting, red degraded); a `‖ PAUSE ALL` / `▶ RESUME` toggle (label from server-truth `paused`, optimistic flip reconciled on next poll); a `+ ADD SPEC` button opening a native `<dialog>`; and a red `ABORT` button behind a **two-step confirm** (button → solid-red `CONFIRM ABORT` 5 s window → `ctl abort{confirm:true}`). | Must |
| FR-3 | **Status strip** (below header, wraps): count chips `N queued · N claimed · N done · N cancelled`; a `‖ CLAIMS BLOCKED` amber chip when paused; `⚠ N stale · N parked` amber and `✕ N erroring` red chips shown only when non-zero; a **gate mini-bar** (label `NN/NN`, green fill = done%, amber fill = parked%, `den = gate.live`, `num = done+parked`); a **budget mini-bar** (green→amber >60 %→red >80 %, label `$spent / $cap`, `cap = Number(config.BUDGET_USD)`; `cap==0` → `$spent spent · no cap`, no bar; unknown → `budget —`); and on the right `burn $X.XX/min` plus per-lane letter chips (`C $0.18 · X $0.13 · …`) in lane colors. Per plan §5.3. | Must |
| FR-4 | **`GET /api/agents`** (polled 2 s — the grid snapshot), per plan §4.2. Envelope `{now, lease_min, paused, run_active, budget_usd, spent_usd, gate:{done,parked,live}, run_started_ms, limits:[{lane,expires_in_sec}], agents:[…]}`. Agent universe = union of ids from `queue/*.prompt`, `claimed/*` (parsed by `CLAIM_RE`), `done/*`, `cancelled/*.prompt`, `limits/*.parked`. Per-agent fields include `state` (precedence done → cancelled → claimed → parked → queued), `stale`, `verify`, `lane`/`model`/`pinned`, `heartbeat_age_sec`/`lease_remaining_sec`, `claim_age_sec`, `last_event_age_sec`, `last_activity`, `tokens`/`dollars`/`cost_usd`/`errors`, `retries`/`timedout`, `chain_left`, `done_lane`/`done_code`, plus the expansion fields `frozen`, `done_ms` (stat mtime of `done/<id>`), and envelope `run_started_ms` (min `runSummary.first_ts` across run logs). "Erroring" is **client**-derived (`errors>0 \|\| retries>0 \|\| timedout`); the server ships raw counts only. | Must |
| FR-5 | **`GET /api/loop`**, per plan §4.3. Returns the newest `BUSDIR/loop/<run>/` by `state.jsonl` mtime (none → `{"run":null}`): `{run, iter, max_iterations, budget_usd, cost_total, last, halted, halted_reason, complete, started_ms, steering_bytes}`. `max_iterations`/`budget_usd` are regex-parsed from `criteria.md`'s two-space-indented `stops:` block; `started_ms` is `criteria.md` mtime (written once). | Must |
| FR-6 | **`GET /api/agent?id=<id>`** (query parameter, **not** a path segment), per plan §4.4. Returns drawer bodies `{id, spec:{text,size,truncated,source}, res:{…}, stderr:{…}}` — spec @32 KiB (first of `queue/`, `claimed/`, `prompt-<id>.txt`, `specs/`, `cancelled/`), res @64 KiB (`res-<id>.txt`), stderr = last 8 KiB (tail) of `run-<id>.jsonl.stderr`. `400` on `ID_RE` failure (before any fs), `404` when all three are null. | Must |
| FR-7 | **`POST /api/ctl`**, per plan §4.5. Guards in order (mirrors `/api/config`): `hostAllowed` → `originAllowed` (else `403`) → 10 s timeout → `readJsonBody` 64 KiB cap (else `400`). Body `{verb, id?, hint?, prompt?, cancel?, confirm?, lane?, write?}`. Verbs resolved through a frozen `CTL_VERBS` table via `Object.hasOwn` (proto-pollution guard): `pause`/`resume`, `cancel` (ID_RE), `kill` (ID_RE + optional `cancel`), `nudge` (ID_RE + optional hint ≤16 KiB, no NUL), `pause-worker`/`resume-worker` (ID_RE), `add` (ID_RE + non-empty prompt ≤60000 ch; `409` if id has any bus footprint), `abort` (`confirm===true` else `400`). Invocation is `execFile(src/swarm-ctl, args, {cwd:REPO_ROOT, env:{...process.env, BUSDIR}, timeout:15000, maxBuffer:256 KiB})` — **literal argv array, never a shell**; `ID_RE`'s first-char-alnum rule blocks `-`-option injection. Responses: `200 {ok,verb,id?,stdout,stderr}` on exit 0; `409 {ok:false,error,code,stderr}` on nonzero exit (bus refused); `400` validation; `403` origin; `405` non-POST; `500` spawn error/timeout. Synchronous — no `202`. The ADD-SPEC flow uses `mkdtempSync` under `os.tmpdir()` and always cleans up before responding, so **the server process never writes under `BUSDIR`** — `src/swarm-ctl` remains the sole bus writer. | Must |
| FR-8 | **`swarm-ctl nudge <id> [hint]`** (plan §4.6) and **`pause-worker`/`resume-worker <id>`** (plan §4.6b). `nudge`: kill_subtree via `pids/<id>` (absent = fine), `mv` the prompt to hidden `queue/.nudge-<id>` (invisible to the `*.prompt` claim scan), append `\n\n## OPERATOR HINT (nudge <UTC-ts>)\n<hint>` if given, `rm -f limits/<id>.parked .chain-<id> .retries-<id> <id>.timedout` (fresh start from the top), atomic `mv` → `queue/<id>.prompt` keeping `.lane`/`.write` sidecars; idempotent (second nudge appends a second hint block); done/unknown id → rc1. `pause-worker`: snapshot the worker subtree and send **SIGSTOP**, `touch claimed/<id>.*` (fresh lease), `touch limits/<id>.frozen`. `resume-worker`: SIGCONT the snapshot, `rm -f limits/<id>.frozen`, `touch claimed/<id>.*`. The reaper (`reap()` in `src/swarm-lib.sh`) **skips requeue for any id with `limits/<id>.frozen`** (a frozen worker's heartbeat loop is stopped too — without the skip the lease would expire and the reaper would requeue a still-frozen claim, a double-claim disaster). `kill`/`nudge`/`cancel` on a frozen worker send **SIGCONT before TERM** (a STOPped process ignores TERM until continued) and always `rm -f limits/<id>.frozen`. | Must |
| FR-9 | **OPS WALL** view (default): verdict card (`ALL CLEAR — N WORKING` green or `⚠ N NEED ATTENTION` amber + sub-line `N running · N queued · N/TOTAL done · est ~Xm left`), up to 3 alert cards (else dashed `no alerts — swarm humming` empty state), the **BUS pipeline** panel (SPECS → QUEUE with pause-valve → lane node rows → HANDOFF → DONE → GATE → VERIFY → SYNTH, with `▣ PARKED N` / `⊘ CANCELLED N` / `↻ reaper requeues` chips), the **heat strip** (one cell per agent, colored by state, click → drawer), a **burn bar chart** (`$/min`, red bucket = ≥3 errors/30 s), and the **MODELS strip** (ported `.mcell`, per spec 06) at the bottom. | Must |
| FR-10 | **MISSION CONTROL** view: a 262 px left **attention rail** (`NEEDS ATTENTION (N)` + compact alert cards with verb + inspect buttons, empty state `nothing needs you.`, footer stating the alert rules), **filter chips** (`ALL n / ATTN n / RUN n / QUEUED n / DONE n` plus per-lane chips from FR-18, active = green bg/dark text), and an **agent tile grid** (`repeat(auto-fill,minmax(112px,1fr))`) — each tile shows id + lane chip + blue pulse sparkline + one-line activity + state glyph & age + token count, border colored by state, sorted trouble-first (err → stale → park → run → q → done); click → drawer. | Must |
| FR-11 | **FLIGHTPATHS** view: a time axis (5 ticks + red `NOW ▾` at 86 % + vertical dashed NOW line) and per-agent rows (`id + lane letter` \| segment track \| right age cell). Segments render queued wait (gray-dashed), executing (solid lane-tinted), silence/stale (amber-dashed), chain-retry gap (red-dashed + new solid), parked stub (amber), and verify hatch (purple); blue/red event dots are **live-only** (cap 24/agent). A **sort toggle** (quietest-first ↔ bus order), a **done toggle** (`▸ show N done branches`), and **2 mini charts** sharing the x-axis (`$ burn (cumulative) — budget line` and `events / min — red spike = ≥3 errors/30 s`). Window is a rolling 20 min (extendable per FR-21). | Must |
| FR-12 | **Agent drawer** (fixed right, 352 px, z-40): header (id + lane chip + meta `claimed <age> · <tok>k tok · $<cost> notional` + ✕ close); an **amber alarm strip** when stale (`last event <age> ago` + `lease expires in <t> → reaper requeues`); **4 tabs** — `events` (per-agent buffer, replay rows rendered dimmer, synthetic silent divider when age >60 s), `transcript` (client-assembled agent_message/text/thinking), `handoff` (`res-<id>.txt` body via `/api/agent`), `spec` (spec body); and footer buttons **NUDGE** (solid green), **PAUSE/RESUME** (toggles on `frozen`, FR-8), **KILL** + **KILL+CANCEL** (amber), **CANCEL** (red; disabled while claimed). Footnote: `controls → POST /api/ctl → swarm-ctl · bus-only · NUDGE = kill + requeue with hint; pause: frozen time still counts toward WORKER_TIMEOUT_SEC; a long pause may trip the watchdog on resume`. Done/cancelled agents disable all buttons. | Must |
| FR-13 | **Alert rules** derived client-side over `/api/agents` + config thresholds (never magic numbers): **error** (`retries≥2` or `errorStreak≥2`), **silent/stale** (`age > LEASE_MIN/2`), **budget** (`cap>0 && spent > 80 % cap`), **starved** (`queued>0 && !paused && some EXEC_CHAIN lane 0-claimed continuously >60 s`). Severity ranks err > silent > budget > starved; max 3 on OPS WALL with a `+N more →` chip into MISSION CONTROL's ATTN filter. Thresholds come from `swarm.conf` via `/api/config`. | Must |
| FR-14 | **No-fake-data rule**: every rendered number is traceable to a bus file or endpoint. Absent data renders as an em-dash (`—`), is hidden, or is explicitly labeled (e.g. `collecting… (needs ~1 min)`, `$ since page load`, `no handoff yet — written on finalize`) — **never invented**. The ETA is shown only when the done-rate is >0; it is omitted otherwise. The QA anti-fake sweep greps the shipped sources for mock literals and asserts zero hits outside comments. | Must |
| FR-15 | **ES-module split** (plan §5.1) with **zero build step**: `site/cockpit.html` becomes a thin shell; logic moves to `site/cockpit/*.js` ES modules served as static files (`.js` MIME already correct). The legacy machinery is ported byte-compatible — `summarize`/`summarizeBlocks`/`classifyBlock`/`toolUseText`/`looksFailed`/`usageStr`, the coalescing engine (`NEVER_COALESCE_TYPES`/`ACCUMULATE_TYPES`/`coalesceKeyOf`), the SSE client + zombie watchdog (ping listener, 45 s silence → close+reopen), and the `localStorage` keys (`unimatrix-fh-kinds`/`unimatrix-fh-workers` byte-identical; new `unimatrix-view`/`unimatrix-fp-sort`/`unimatrix-fp-done`/`unimatrix-fp-zoom`/`unimatrix-beep` via the existing `loadJSON`/`saveJSON`). Old `cockpit.html` is replaced in place (same URL; auto-open + `.assetsignore` untouched). | Must |
| FR-16 | **Lanes and verify text are always config-driven** — derived from `EXEC_CHAIN` and `VERIFY_MAP` (`/api/config`), never hardcoded. Six lanes are supported including **grok** (letter `K`, color `#f0abfc`) and **kimi** (letter `M`, color `#fb923c`), distinct from semantic red `#f97066` and amber `#e0b34a`. Pipeline lane rows render one per `EXEC_CHAIN` entry in order; VERIFY letters render from `VERIFY_MAP` (e.g. `C→X X→G G→Z Z→C`). | Must |
| FR-17 | **Real ETA + done ages** (plan §5.3b item 1): `done_ms` per done agent (stat mtime of `done/<id>`) and `run_started_ms` in the `/api/agents` envelope (min `runSummary.first_ts` across run logs — real elapsed even for plain `/swarm` runs, not just loops). The DONE pipeline node shows `newest <id> · <age>` for real; the verdict `est ~Xm left` is computed as `remaining/rate` where `rate` = dones in the trailing 10 min (from `done_ms`), and is shown **only when `rate>0`** (omitted otherwise — no fabricated ETA). Header elapsed falls back to `run_started_ms` when there is no loop. | Must |
| FR-18 | **Pipeline nodes are click-filters** into MISSION CONTROL (plan §5.3b item 2): QUEUE → grid + QUEUED filter; DONE → grid + DONE; PARKED chip → grid + ATTN; a lane row → grid + that lane's filter. The grid gains **per-lane filter chips** (one per `EXEC_CHAIN` lane, letter + color) that compose with the state filter. | Must |
| FR-19 | **Parked alert card + limit TTL countdown** (plan §5.3b items 3+4): alert type `parked` → title `▣ parked`, sub `<lane> lane .limited (<TTL left>)`, verb `NUDGE (requeue)` → `ctl nudge` (nudge resets the chain to the `EXEC_CHAIN` head = requeue onto the first healthy lane). The `/api/agents` envelope ships `limits:[{lane,expires_in_sec}]` (content of `limits/<lane>.limited` = TTL secs; expiry = mtime + TTL − now); lane rows render `.limited · 4h12m left` and parked cards reuse the countdown. | Must |
| FR-20 | **New-alert notification** (plan §5.3b item 5): when alerts gain a new id, flash `document.title` (`⚠ N — UNIMATRIX` ↔ normal, 3×) and swap the favicon to an amber-dot variant while any alert is active. An optional **beep** via a WebAudio oscillator is **off by default**, toggled by a bell chip in the header, persisted as `unimatrix-beep`. | Should |
| FR-21 | **Flightpaths zoom + follow** (plan §5.3b item 6): a window-preset chip cycling `5m / 20m / 60m` (persisted `unimatrix-fp-zoom`) plus a `follow NOW` checkbox (default on; off freezes the window end for inspection while the dashed NOW line keeps moving). | Should |
| FR-22 | **ADD SPEC with lane pin + write grant + drawer dollars + loop tooltip + cancelled tiles** (plan §5.3b items 7–10): the ADD SPEC dialog gains an optional lane:model select (from `EXEC_CHAIN` + `default`) and a write-dir field; `swarm-ctl add` is extended to `add <promptfile> [--lane lane:model] [--write <dir>]` writing the `<id>.lane`/`<id>.write` sidecars, and `/api/ctl add` validates `lane?`/`write?` server-side (lane against the LANE_MODEL regex; `write` must be an existing directory via `fs.statSync`; a **gemini pin is refused** server-side as the read-only lane). The drawer meta renders per-agent notional dollars (`· $X.XX notional`, from `/api/agents dollars`). The header loop segment carries a hover tooltip (criteria stops, halted/complete state, steering_bytes from `/api/loop`). Cancelled agents appear in the grid under a **FINISHED** filter chip (`DONE+CANCELLED`, `⊘` glyph, dim). | Must |

## Design

Condensed from `plans/002-cockpit-redesign/PLAN.md` §4 (server) and §5 (client). The plan is
authoritative for any detail this section compresses.

### Design tokens (verbatim from plan §1.1)

```
Background page:        #070b09
Panel bg:               #0c120e
Inset/chip bg:          #101812
Drawer event-log bg:    #050807
Text primary:           #e6f1ea
Text dim:               #93a89c
Accent green:           #34d399   (hover #4ae0a8, dark #1d8a63, selection bg on #052e1e text)
Amber (warn):           #e0b34a   (borders rgba(224,179,74,.4/.5))
Red (error):            #f97066   (borders rgba(249,112,102,.4/.5))
Blue (tool pulse):      #7dd3fc
Purple (verify/codex):  #c084fc
Border faint:           rgba(94,234,166,.13)
Border strong:          rgba(94,234,166,.28)
Grid overlay:           56px grid, rgba(94,234,166,.04) lines, radial mask ellipse 90% 70% at 50% 0%, opacity .5
Font:                   'Share Tech Mono', ui-monospace fallback chain; 13px base, line-height 1.45
Scrollbar:              10px, thumb #101812 + 1px rgba(94,234,166,.13) border, radius 5
Animations:             blink 2s (opacity .2↔1), rise .18s ease-out (toast entry)
Lane colors:            claude #7dd3fc (C) · codex #c084fc (X) · gemini #e0b34a (G) · glm #34d399 (Z)
                        grok = NEW (not in design): letter K, color #f0abfc (must not collide with
                        semantic red #f97066 / amber #e0b34a; MODEL_COLORS.grok family chip color
                        stays as-is — separate concern)
Min viewport:           min-width:1280px, 100vh column flex, page never scrolls horizontally except inner rails
```

### Server blueprint (site/server.mjs — additions only; Node stdlib)

Zero-dep; new imports `node:child_process` (`execFile`) and `node:os` (`tmpdir`). Existing
endpoints `/api/bus`, `/api/cost`, `/api/models`, `/api/stream`, `/api/config` are unchanged.

**Shared primitives (module-level):**
- `ID_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/` — every route/verb validates ids against this
  before any fs or spawn; rejects `..`, `.hidden`, `-flag`, anything with `/`. First char is
  alnum ⇒ no `-`-option injection into argv.
- `CLAIM_RE = /^(.+)\.((?:claude|codex|gemini|glm|grok):[A-Za-z0-9._-]+)$/` — parses
  `claimed/<id>.<lane:model>` (tolerates dots in ids and models like `glm-5.2`).
- `RUN_CACHE: Map<filename,{size,mtimeMs,summary}>` — run logs are append-only (a failover
  re-run truncates, changing size), so `(size,mtimeMs)` is a sound cache key; keeps the 2 s poll
  cheap at 50+ agents. `runSummary(name)` parses once per change into `{tokens, dollars,
  cost_usd, errors, model, first_ts, last_type, last_excerpt (≤120 ch)}`; malformed lines are
  skipped, vanished files evicted.
- `readCapped(file, capBytes, {tail=false})` → `{text,size,truncated}|null`.

**`GET /api/agents`** (FR-4): envelope as specified; `state` precedence done → cancelled → claimed
→ parked (`limits/<id>.parked` wins over queued) → queued; `stale` is claimed-only (claim mtime <
`now − lease_min·60s`); `claim_age_sec` uses `runSummary.first_ts ?? run-log birthtime ?? claim
mtime` (NOT claim mtime — heartbeat refreshes it); `last_event_age_sec` from
`stat(run-<id>.jsonl).mtimeMs`; `frozen` = `limits/<id>.frozen` exists; `done_ms` = `done/<id>`
mtime; `limits:[{lane,expires_in_sec}]` from `limits/<lane>.limited` content + mtime. Server ships
raw counts; events/min, queue trend, per-lane burn, elapsed, ETA are all client-side.

**`GET /api/loop`** (FR-5): newest `loop/<run>/` by `state.jsonl` mtime; `iter` = non-empty line
count; `max_iterations`/`budget_usd` regexed from `criteria.md`'s `stops:` block; `cost_total` =
Σ `.cost`; `started_ms` = `criteria.md` mtime; `halted`/`halted_reason` from `HALTED.md`;
`complete` from `COMPLETE.md`.

**`GET /api/agent?id=<id>`** (FR-6): `400` on `ID_RE` fail before any fs; `{spec @32 KiB, res
@64 KiB, stderr @8 KiB tail}`; all-null → `404`.

**`POST /api/ctl`** (FR-7) — verb table (frozen, `Object.hasOwn` lookup):

| verb | validation | swarm-ctl argv |
|---|---|---|
| pause / resume | — | `["pause"]` / `["resume"]` |
| cancel | ID_RE | `["cancel", id]` |
| kill | ID_RE; optional bool `cancel` | `["kill", id]` (+`"--cancel"`) |
| nudge | ID_RE; hint optional ≤16 KiB, no `\0` | `["nudge", id(, hint)]` |
| pause-worker | ID_RE | `["pause-worker", id]` |
| resume-worker | ID_RE | `["resume-worker", id]` |
| add | ID_RE; prompt non-empty ≤60000 ch; 409 if id has any bus footprint; optional `lane`/`write` validated server-side (gemini pin refused) | tmpdir flow |
| abort | `confirm===true` else 400 | `["abort"]` |

Invocation: `execFile(REPO_ROOT/src/swarm-ctl, args, {cwd:REPO_ROOT, env:{...process.env, BUSDIR},
timeout:15000, maxBuffer:256*1024})` — literal argv, never a shell. Responses 200/409/400/403/405/500
(per FR-7). ADD-SPEC uses `mkdtempSync(os.tmpdir()/swarm-add-)` → write `<id>.prompt` →
`execFile(ctl,["add",tmpfile])` → always `rmSync(dir,{recursive,force})` before responding. A
`guardedPost(req,res,maxBytes,handler)` helper is extracted from the existing `/api/config` POST
branch (Origin + timeout + readJsonBody + try/catch); both POST routes use it. No locking — verbs
are mv/rm-based and race-tolerant.

**`swarm-ctl nudge` semantics** (bash, FR-8): kill pidfile subtree (absent = fine) → find prompt
(`claimed/<id>.*` else `queue/<id>.prompt`) → `mv` to hidden `queue/.nudge-<id>` → append OPERATOR
HINT block → `rm` parked/chain/retries/timedout → atomic `mv` to `queue/<id>.prompt`, keeping
sidecars. Idempotent.

**Per-worker SIGSTOP freeze** (FR-8): `pause-worker` snapshots the subtree (same pgrep walk as
`kill_subtree`; a `signal_subtree <pid> <SIG>` helper signals only the snapshot with no
escalation), sends SIGSTOP, touches the claim + `limits/<id>.frozen`; `resume-worker` SIGCONTs,
removes the frozen flag, touches the claim. **Reaper change** (`reap()` in `src/swarm-lib.sh`):
skip requeue for any id with `limits/<id>.frozen`. `kill`/`nudge`/`cancel` on a frozen worker send
SIGCONT before TERM and always clear the frozen flag. **Wall-clock watchdog caveat (documented in
spec + code comment + drawer footnote):** the worker watchdog's `sleep WORKER_TIMEOUT_SEC` runs on
wall-clock, so time spent frozen still counts against the timeout — a long pause can trip the
watchdog immediately on resume. Acceptable v1.

### Client blueprint (site/cockpit/* — ES modules, zero build)

**Module split (plan §5.1)** — each file has exactly one owner; view modules export
`{init(rootEl), render()}`, read `store`/`ui`, subscribe to `bus`, call `ctl()`; **only `main.js`
touches header/strip; only `data.js` fetches**; every file carries the `rules/file-headers.md`
JSDoc header.

| File | Responsibility | Slot |
|---|---|---|
| `site/cockpit.html` | Shell: head (noindex, self-hosted font, css links), header chrome, status-strip skeleton, 4 empty view containers (`#view-ops #view-grid #view-flight #view-fire`), `#agent-drawer`, `#settings-drawer`, `#toast`, `#notice`, `<script type=module src=cockpit/main.js>`. | chrome |
| `cockpit/base.css` | Tokens (`:root` + light-scheme verbatim), field-grid bg, header/tabs, strip, shared atoms (`.btn-ctl .chip .badge .pulse .lane-tag toast`), blink/rise keyframes. | chrome |
| `cockpit/main.js` | Boot, header+strip rendering, view registry/switching, keyboard map, `unimatrix-view` persistence, degrade wiring, 1 s tick. | chrome |
| `cockpit/format.js` | PURE functions (no DOM/fetch): ported summarize/coalesce helpers; `normalizeModel`/`modelOf`/`MODEL_COLORS`/`colorFor`; `esc`/`fmtTok`/`fmtTime`; `fmtAge`, `pulseStr` (▁–▇), `LANES` map (C/X/G/Z/K + colors), `STATE_RANK`, tile/heat style maps. | data |
| `cockpit/data.js` | Store + ALL I/O: SSE client + zombie watchdog + replay/live discrimination, pollers, reconciliation, per-agent records, pulse buckets, ring buffers, coalescing at buffer level, alert derivation, `degrade()`. Exposes `store`, `bus` (EventTarget), `ui`. | data |
| `cockpit/ctl.js` | `ctl(verb,id,extra)` → POST /api/ctl; toast singleton (pending → ok green 2.6 s / fail red 6 s); `armAbort()` two-step confirm. | data |
| `cockpit/ops.js` + `ops.css` | OPS WALL: verdict, alerts, pipeline, heat, burn chart, MODELS strip. | V1 |
| `cockpit/grid.js` + `grid.css` | MISSION CONTROL: attention rail + rules footer, filter chips, tile grid. | V2 |
| `cockpit/flight.js` + `flight.css` | FLIGHTPATHS: axis/NOW, rows/segments/dots, sort+done+zoom toggles, 2 mini charts. | V3 |
| `cockpit/firehose.js` + `firehose.css` | Legacy firehose as view 4 (key `4`): renders from `data.js` buffer via `feed:*`; kind/worker chips (localStorage byte-identical), 500-row cap, hover-pause, click-to-expand (32 KiB), spinner rows; feed element stays mounted (`display:none`) across switches. | V4 |
| `cockpit/drawer.js` + `drawer.css` | Agent drawer: header/meta, alarm strip, 4 tabs, ctl buttons. | V5 |
| `cockpit/settings.js` | AGENTS config drawer ported verbatim (exec-chain slots/review/limits → POST /api/config); on save calls `data.refreshConfig()`. | V6 |

**Store + reconciliation (`data.js`, plan §5.2):** `store = {ok, paused, config{}, loop{},
counts{}, staleLeases[], parked[], activeLimits[], doneRecent[], agents:Map, lanes:Map, models[],
costLanes[], alerts[], series{evtPerBucket, burnPerBucket, spentCum, queueLen}, feed[] (cap 500)}`;
`ui = {view, sel, dtab, mcFilter, fpSort, fpShowDone, fpZoom, fpFollow, armAbort}`. Agent record
holds server snapshot fields + client-only `buckets:Uint8Array(6)` (10 s pulse), `spans[]`,
`dots[]` (cap 24), `events[]` (cap 200). Rules: (1) **server snapshot wins** for state/lane/
tokens/lease; SSE only refines between polls; (2) displayed age = `min((now−srvAgeAt)/1000+srvAgeSec,
lastEvtClient ? (now−lastEvtClient)/1000 : ∞)`; (3) derived state for claimed → `err` if
`retries≥2 || errorStreak≥2 || errors>0&&timedout`, else `stale` if age > `LEASE_MIN/2·60`, else
`run`; (4) replay-vs-live policy below; (5) coalescing happens in the buffer (not the DOM) — same
key tables; (6) graceful 404 fallback: if `/api/agents` or `/api/loop` 404 against an old server,
the page still renders from `/api/bus` + SSE (agents built from SSE worker names, `srvState
'unknown'`, ages `—`); `degrade()` fires on first `/api/bus` failure (unchanged).

**Amendment 2026-07-25 (backlog 24) — replay-vs-live is server-authoritative.** The
`backfillUntil = now+2000` wall-clock guess below is **superseded**: on a bus with real history the
replay outlasts 2 s, so its tail crossed the mark and was counted as live — stamping `lastEvtClient
= now` (and `dots`/`evtPerBucket`) for agents that finished hours ago. Ages then counted up from a
false zero, and because `deriveState()` reads the same age, genuinely stale/silent workers stopped
raising alerts. `/api/stream` now emits a named `replay-done` SSE event (`event: replay-done\ndata: {}`)
immediately after its first full glob pass — exactly once per connection, unconditionally (an empty
bus still gets one). The client gates `live` on having received that sentinel and resets its flag on
every `onopen`/`onerror`, so an EventSource auto-reconnect (a new connection, replayed from byte 0)
gets a fresh sentinel. This adds a named event to the stream; the `data:` envelope shape is
unchanged. Everything else in the paragraph below (what replay may and may not touch, the `backfill`
flag, the watchdog) still holds verbatim.

**Replay-vs-live policy (the foolproof bit):** on SSE open, `backfillUntil = now+2000`; reconnect
clears the feed + per-agent events + coalesce state (the server replays from byte 0). Replay
events populate `feed`/`events`/`lastSummary`/model carry-forward (free drawer history) but
**never touch** `buckets`, `dots`, `evtPerBucket`, or `lastEvtClient` (replay arrival time is
meaningless). Replay entries carry a `backfill` flag and render dimmer in the drawer, titled
"time = replay receipt". Zombie watchdog is kept verbatim.

## Boundaries

- **Always**: keep `.bus` on a local POSIX filesystem only (never a 9p/drvfs/NFS mount); every rendered number
  traceable to a bus file or endpoint (FR-14); honor the ES-module contract (one file per concern,
  view modules export `{init, render}`, only `data.js` fetches, only `main.js` touches header/
  strip); carry the `rules/file-headers.md` header on every source file; route `POST /api/ctl`
  through the same guard pattern as `/api/config` (Host, Origin, body cap, allowlist); record a
  `docs/ops/llm-runs.md` ledger row per spawned build wave (no silent spend).
- **Ask first**: adding any new external dependency (CLI, npm/brew package); adding a standing
  daemon; bumping `FANOUT` beyond the configured ceiling for the build swarm.
- **Never**: render fake/invented data; invoke `swarm-ctl` via a shell string (execFile literal
  argv only); write under `BUSDIR` from the server process (`src/swarm-ctl` is the sole bus writer)
  — **one exception, added by spec 12**: the server appends its own `BUSDIR/audit.jsonl` control
  trail, of which it is the sole writer and which no other component reads back as bus state;
  point `.bus` at `/mnt/*`; hardcode the lane list (always derive from `EXEC_CHAIN`/
  `VERIFY_MAP`); let a model verify its own output (reviewer lane ≠ executor lane on any claim);
  change the response shapes of `/api/bus`, `/api/cost`, `/api/models`, `/api/stream`, `/api/config`.

## Acceptance Criteria

- [ ] **FR-1** — Three views + firehose view 4 render; keys `1`/`2`/`3`/`4` switch views (ignored
      in inputs); `Esc` closes drawer → settings → dialog; active view persists across reload.
- [ ] **FR-2** — Header shows `run <id> · loop <iter>/<max> · <elapsed>` from `/api/loop` (never an
      invented id/clock); PAUSE ALL toggles claims; ADD SPEC opens a `<dialog>`; ABORT is two-step.
- [ ] **FR-3** — Status strip shows counts, stale/parked/erroring chips (only when non-zero), gate
      mini-bar, budget mini-bar (with cap/no-cap/unknown cases), burn + per-lane chips.
- [ ] **FR-4** — `/api/agents` returns the envelope + per-agent fields incl. `frozen`, `done_ms`,
      `run_started_ms`, and `limits:[{lane,expires_in_sec}]`; state mapping + stale/lease math hold.
- [ ] **FR-5** — `/api/loop` returns `run:null` without a loop dir; iter/stops/last/cost_total/
      halted/started_ms from a seeded fixture.
- [ ] **FR-6** — `/api/agent?id=` round-trips spec+res for a done id; oversize res truncated;
      traversal ids (`../x`, `..`, `.hidden`) → `400` with no file content; unknown → `404`.
- [ ] **FR-7** — `/api/ctl`: foreign Origin → `403` + bus untouched; unknown/proto-key verb →
      `400`; malformed id → `400` without invoking ctl; oversized body → `400`; GET → `405`;
      pause/resume/cancel/kill/nudge/abort round-trip; add lands `queue/<id>.prompt`; execFile
      argv is literal (no shell).
- [ ] **FR-8** — `swarm-ctl nudge` kills+requeues+appends hint, resets park/chain/retries/timedout,
      keeps sidecars, idempotent; `pause-worker` SIGSTOPs the subtree (ps `T`) + writes frozen flag;
      `resume-worker` SIGCONTs (ps `S`) + clears flag; `reap()` skips a stale-but-frozen claim and
      reaps once thawed; kill on a frozen worker still dies (CONT-before-TERM).
- [ ] **FR-9** — OPS WALL renders verdict, ≤3 alert cards (else empty state), the bus pipeline,
      heat strip, burn chart, MODELS strip.
- [ ] **FR-10** — MISSION CONTROL renders the attention rail + rules footer, filter chips, and the
      agent tile grid (trouble-first sort, state-colored borders).
- [ ] **FR-11** — FLIGHTPATHS renders the axis/NOW line, per-agent segment rows with live-only
      dots, sort + done toggles, and the 2 mini charts.
- [ ] **FR-12** — Agent drawer renders 4 tabs (events/transcript/handoff/spec), alarm strip when
      stale, and NUDGE/PAUSE-RESUME/KILL(+CANCEL)/CANCEL buttons; done/cancelled disables all;
      drawer footnote includes the wall-clock caveat: "pause: frozen time still counts toward
      WORKER_TIMEOUT_SEC; a long pause may trip the watchdog on resume".
- [ ] **FR-13** — Alert rules fire from config thresholds (age > LEASE_MIN/2, retries ≥2, budget
      >80 %, starved queue while a lane idles); severity ranking holds.
- [ ] **FR-14** — No-fake-data sweep: `grep -rn -E "r-0719|b-23|~18m|retry storm|\$0\.42" site/cockpit.html site/cockpit/ --include="*.js" --include="*.html" | grep -v "^\s*//"` (expected zero hits; comments are excluded by the trailing filter); absent data renders as `—`/hidden/labeled.
- [ ] **FR-15** — `node --check` passes on every module; legacy summarize/coalesce/watchdog/
      localStorage keys behave byte-compatibly; old `cockpit.html` replaced in place at the same URL.
- [ ] **FR-16** — Lane rows + VERIFY letters render from `EXEC_CHAIN`/`VERIFY_MAP`; 6 lanes incl.
      grok (`K`, `#f0abfc`) and kimi (`M`, `#fb923c`) appear when configured.
- [ ] **FR-17** — DONE node shows real `newest <id> · <age>`; verdict ETA shown only when rate>0;
      header elapsed falls back to `run_started_ms`.
- [ ] **FR-18** — Clicking QUEUE/DONE/PARKED/a lane node jumps to MISSION CONTROL with the matching
      filter; per-lane filter chips compose with the state filter.
- [ ] **FR-19** — Parked alert card shows `NUDGE (requeue)` and the `.limited · <TTL> left`
      countdown; `limits:[{lane,expires_in_sec}]` drives both lane rows and cards.
- [ ] **FR-20** — New alert flashes the title + swaps the favicon; beep is off by default, toggled
      by the bell chip, persisted as `unimatrix-beep`.
- [ ] **FR-21** — Flightpaths zoom chip cycles 5m/20m/60m (persisted); follow-NOW checkbox freezes
      the window end when off while the NOW line keeps moving.
- [ ] **FR-22** — ADD SPEC with a lane pin lands `queue/<id>.lane` (gemini pin refused); drawer
      shows `· $X.XX notional`; header loop tooltip renders criteria/halted/steering; cancelled
      agents appear under the grid FINISHED chip.

**Verification commands:**
```bash
# Full suite (incl. ~42 new ground-control.bats + swarm-ctl.bats tests for FR-4..FR-8).
bats tests/

# All client modules parse + server syntax check (zero-build contract).
node --check site/server.mjs site/cockpit/*.js

# Lint the 5 shell scripts (swarm-ctl gains nudge + pause-worker/resume-worker + add --lane/--write;
# swarm-lib.sh gains the reap() frozen-skip + signal_subtree helper).
shellcheck -x swarm-run.sh swarm-loop.sh swarm-mon.sh src/swarm-lib.sh src/swarm-ctl

# Lane-A fixture QA: 18-step checklist (plan §5.5) against a fixture bus on a free port,
# exercising every visual state + every ctl verb against the real swarm-ctl on the fixture bus.
BUSDIR=<fixture> SWARM_CONF=<fixture-conf> PORT=4799 node site/server.mjs &
playwright-cli --config ~/.claude/helpers/playwright-cli-headless.config.json open http://127.0.0.1:4799/cockpit.html
# (then flagless snapshot/goto/click verbs; run the §5.5 18-step checklist)
```

## Open Questions

None — the design tokens, the ES-module split, the per-worker SIGSTOP freeze (FR-8), and the full
§5.3b functionality expansion (FR-17..FR-22) are locked with the operator in
`plans/002-cockpit-redesign/PLAN.md`. The wall-clock-watchdog ceiling on long pauses (FR-8) is an
accepted v1 caveat, documented in code + drawer footnote.

## Dependencies

**Internal:** `plans/002-cockpit-redesign/PLAN.md` §4/§5 (authoritative detail); specs
[02-cockpit](./02-cockpit.md) (FR-7 verb list gains `nudge`), [05-ground-control](./05-ground-control.md)
(server + serving contract unchanged; "no control surface" non-goal superseded here),
[06-live-model-cost](./06-live-model-cost.md) (MODELS strip → OPS WALL bottom); `site/server.mjs`;
`src/swarm-ctl`; `src/swarm-lib.sh` (`reap()`).
**External:** Node stdlib (`http`, `fs`, `child_process.execFile`, `os.tmpdir`); bats-core 1.13.x;
shellcheck `-x`; playwright-cli 0.1.15 (headless Lane-A config) + playwright MCP (Windows Chrome
:9222, Lane B) for QA.
