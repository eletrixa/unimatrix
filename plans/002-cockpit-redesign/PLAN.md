# Unimatrix Cockpit Redesign — Full Implementation Plan

**Status: SHIPPED** as spec 07.

> Decisions locked with the operator: ES-module file split ✓ · per-worker PAUSE = real SIGSTOP
> freeze verb (§4.6b) ✓ · functionality EXPANDED beyond the mock (§5.3b) ✓.

## Context

The operator mocked up a full cockpit redesign in Claude Design (claude.ai/design) and exported a
handoff bundle (a design export zip, extracted to a scratchpad `handoff/` dir).
The current cockpit (`site/cockpit.html`, ~firehose-first single page served by `site/server.mjs`
on :4747) is to be replaced by the redesign: a three-view agent-centric cockpit (Ops Wall /
Mission Control / Flightpaths) with a per-agent drill-in drawer and real control actions.

Goal: apply the design **pixel-faithfully** (dark LCARS-ish green terminal aesthetic) AND wire
**as much real functionality as possible** — real bus counts, real per-agent state from
`run-*.jsonl`, real staleness/lease math from `swarm.conf`, real budget/burn from the existing
cost parser, and real control verbs via a new `POST /api/ctl` endpoint that shells out to
`src/swarm-ctl`.

Method (the canonical red-green-double-refactor):
wave 0 specs → red (failing tests) → green (implement) → refactor #1 (specs adherence) →
refactor #2 (rules adherence) → changelog → code-simplifier + code-reviewer (apply ALL findings,
even low priority) → playwright CLI + playwright MCP full QA.

Executed by lesser-level models → this plan is deliberately over-specified: exact colors, exact
DOM structure, exact API shapes, exact test names, exact commands.

---

## 1. Design source of truth

Bundle files (read these IN FULL before coding):

| File | Role |
|------|------|
| `<scratch>/handoff/unimatrix-agent-cockpit-redesign/project/Unimatrix Cockpit.dc.html` | PRIMARY hi-fi design. 3 views + drawer + toast + header/status strip. Recreate pixel-faithfully. |
| `<scratch>/handoff/unimatrix-agent-cockpit-redesign/project/Cockpit Wireframes.dc.html` | Wireframes + annotations. Use ONLY for intent notes (alert rules, interaction notes). Not visual truth. |
| `<scratch>/handoff/unimatrix-agent-cockpit-redesign/README.md` | Handoff instructions. |

The `.dc.html` files are prototypes in a mini React-like DSL (`sc-if`/`sc-for`/`{{expr}}`,
`DCLogic` class with `renderVals()`). **Do not port the DSL or `support.js`** — recreate the
rendered output in the cockpit's existing vanilla-JS style. The `renderVals()` mock-data logic is
the spec for DERIVED VALUES (how ages, pulses, colors, filters, sorts are computed) — port those
formulas, but feed them from REAL bus/JSONL data instead of `_rnd()`.

### 1.1 Design tokens (exact values from the primary design)

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

### 1.2 Screens/components in the primary design (complete inventory)

**A. Header (52px, always visible)**
- Brand: `UNIMATRIX` + `▚ Cockpit` badge.
- 3 nav tabs: `OPS WALL` / `MISSION CONTROL` / `FLIGHTPATHS` — active = green text + 2px green
  bottom border; keyboard `1`/`2`/`3` switch views; `Esc` closes drawer.
- Right cluster: `run r-XXXX · loop N/M · <elapsed>` live text · hint text `1·2·3 views · esc
  closes` · blinking green status dot · `‖ PAUSE ALL`/`▶ RESUME` toggle button · `+ ADD SPEC`
  button · red `ABORT` button.

**B. Status strip (below header, wraps)**
- Counts: `N queued · N claimed · N done (green) · N cancelled`.
- `‖ CLAIMS BLOCKED` amber chip when paused.
- `⚠ N stale · N parked` amber (only when >0); `✕ N erroring` red (only when >0).
- Gate mini-bar: 110px, green fill = done%, amber fill = parked%, label `NN/NN`.
- Budget mini-bar: 90px, fill color green→amber(>60%)→red(>80%), label `$X.XX / $BUDGET`.
- Right: `burn $X.XX/min` + per-lane letter chips `C $0.18 · X $0.13 · …` in lane colors.

**C. View 1 — OPS WALL (default)**
- Row 1: verdict card (400px): `swarm status` label, big verdict `ALL CLEAR — N WORKING` (green)
  or `⚠ N NEED ATTENTION` (amber), sub-line `N running · N queued · N/TOTAL done · est ~Xm left`.
- Row 1 right: up to 3 alert cards (id + title + sub + action button + `inspect →`); if none:
  dashed empty state `no alerts — swarm humming, go make coffee`.
- Row 2: THE BUS pipeline panel — nodes left→right: SPECS(count, "by Fable") → arrow → QUEUE
  (count, trend, pause-valve chip toggling `‖ pause valve`/`‖ PAUSED — claims blocked`) →
  "atomic rename" arrow → 4-5 lane node rows (lane color left border: name, ×count, pulse
  sparkline, $burn/min, extra status e.g. `⚠ b-17 silent`/`read-only lane`/`.limited · 2 parked`)
  → HANDOFF (dashed, `res-*.txt`, "never scraped") → DONE (count green, `newest <id> · <age>`) →
  GATE (`done+parked ≥ live`, `NN/NN — holding`) → VERIFY (hatched bg, `C→X X→G G→Z Z→C`,
  "judge ≠ executor") → SYNTH (`Fable`, "adjudicates"). Below: chips `▣ PARKED N (lane caps)`,
  `⊘ CANCELLED N`, `↻ reaper requeues dead leases`.
- Row 3 left: heat strip — one 17px cell per agent, bg by state: fresh green `#34d399`, aging
  `#1d8a63` (age>30s), stale amber, error red, parked `rgba(224,179,74,.35)`, done dim
  `#101812`+faint border, queued transparent+gray border. Tooltip `id · age · activity`. Click →
  drawer. Legend line below.
- Row 3 right (420px): burn bar chart `$/min` (52px tall bars) + x labels + red annotation
  `spike = retry storm <id>`.

**D. View 2 — MISSION CONTROL**
- Left rail (262px): `NEEDS ATTENTION (N)` + alert cards (compact: id/title/sub/verb btn/inspect
  btn); empty state `nothing needs you.`; footer note: alert rules `age > LEASE_MIN/2 · retries
  ≥ 2 · budget > 80% · queue starved while a lane idles. Thresholds from swarm.conf.`
- Main: filter chips `ALL n / ATTN n / RUN n / QUEUED n / DONE n` (active = green bg, dark text).
- Agent tile grid `repeat(auto-fill,minmax(112px,1fr))`: tile = id + lane chip (lane color
  border/text) + blue pulse sparkline + one-line activity (latest event humanized, ellipsis) +
  state glyph & age (`● 12s` green run / `◌ queued` / `✓` done dim / `⚠ 14m` amber stale / `✕`
  red err / `▣ parked`) + token count. Border color = state; done tiles opacity .4, queued .5.
  Selected tile: 2px green ring (box-shadow). Sort: trouble first (err→stale→park→run→q→done).
  Click → drawer.

**E. View 3 — FLIGHTPATHS**
- Header row: title, `sort: quietest first ⇅` toggle (quietest-first ↔ bus order), legend
  (solid = executing · dashed = queued · amber dash = silent · bar tint = lane · hatch = verify ·
  dots = tool(blue)/error(red) · click row → inspect).
- Time axis: 5 ticks + red `NOW ▾` at 86% + vertical dashed red NOW line.
- Rows (22px): `id + lane letter` (104px) | segment track (dashed-gray queued wait segment, solid
  lane-tinted executing segment, amber-dashed silence segment for stale, red-dashed retry gap +
  new solid segment for chain-retry, amber parked stub, hatch verify segment; blue/red event
  dots) | right age cell (amber `14m!` stale, `✓` done, `—` queued, `parked`).
- Stale rows get faint amber row bg; err rows faint red bg.
- Verify wave rows: `v-NN X⊢C` purple hatched segments (from VERIFY_MAP).
- `▸ show N done branches` toggle row at bottom.
- Below: 2 mini charts sharing x-axis — `$ burn (cumulative) — budget line $10` and
  `events / min — spike = retry storm` (red spike bars).

**F. Agent drawer (fixed right, 352px, top:96px→bottom, over content, z-40)**
- Header: agent id, lane chip, meta `claimed <age> · <tok>k tok · $<cost>`, ✕ close.
- Amber alarm strip when stale: `last event <age> ago` + `lease expires in <t> → reaper requeues`.
- Tabs: `events / transcript / handoff / spec` (chips, active green).
- Events tab: rows `HH:MM:SS | badge | text` — badge colors: claim/dim, tool_use/blue,
  tool_result/dim, agent_message/green, error/red, result/green, silence row amber italics.
- transcript / handoff / spec tabs: pre-wrap text body (real file contents).
- Footer buttons: `NUDGE` (solid green), `PAUSE`, `KILL` (amber), `CANCEL` (red).
- Footnote: `controls → POST /api/ctl → swarm-ctl · bus-only, never touches the worker pane ·
  NUDGE = kill + requeue with hint`.

**G. Toast (bottom right, z-60)** — `$ <message>`, green border, rise animation, auto-hide ~2.6s.
Used for every ctl action: e.g. `swarm-ctl kill b-23 · POST /api/ctl 202`.

**H. Behaviors**
- 2s UI tick for live ages/elapsed (design uses 2000ms interval).
- View switch: tabs or keys 1/2/3. Esc closes drawer. Abort → confirm (design: toast
  `abort requires confirm — kills run.pgid subtree` — real impl must confirm then call ctl).
- Pause toggles claims + flips button label + shows CLAIMS BLOCKED chip + pause-valve chip state.

### 1.3 Intent notes from wireframes (design rationale that must hold)

- Alert rules (the "needs attention" ranking): `age > LEASE_MIN/2` (stale), `retries ≥ 2`
  (erroring), `budget > 80%`, `queue starved while a lane idles`. Thresholds FROM swarm.conf, not
  magic numbers.
- "age since last event = THE stuck detector"; pulse = tool-calls/min.
- The old firehose SURVIVES as the per-agent events tab in the drawer ("scoped to ONE agent.
  full stream = a tab behind 'all events'").
- Controls map to existing swarm-ctl verbs; web needs one new `POST /api/ctl`.
- NUDGE = kill + requeue with a hint appended to the spec.
- Flightpaths killer feature: "a flat bar with no dots = stuck agent — silence is literally
  visible."

## 2. Current state

### 2.1 `site/server.mjs` (~700 lines, Node stdlib only, zero deps)

- Constants: `PORT` env or **4747**, `BUSDIR` env or `<repo>/.bus`, `SWARM_CONF` env or
  `<repo>/swarm.conf` (server.mjs:30-35). Binds **127.0.0.1 only** (:697).
- Endpoints (router :610-695):
  - `GET /health` → `{ok:true, busdir}`
  - `GET /api/bus` → `busSnapshot()` (:174-214): `{counts:{queued,claimed,done,cancelled},
    lease_min, stale_leases:[name], active_limits:[name], parked:[name], done:[newest≤50 names]}`.
    queued counts only `*.prompt`; stale = claimed/ files with mtime older than LEASE_MIN min.
  - `GET /api/cost` → `{lanes:[{lane,tokens}]}` (:236-269)
  - `GET /api/models` → `{models:[{model,tokens_total,tokens_5m,input_5m,output_5m,dollars_5m,
    dollars_per_hour,running,unpriced}], window_min:5, notional:true}` (:359-437). PRICES table
    :276-285, `normalizeModel` :288-300, `modelOf` :305-314 (incl. grok `modelUsage` key),
    `usageBuckets` :319-333, `parseTs` :347-354.
  - `GET /api/stream` → SSE (:441-516): tails all `BUSDIR/run-*.jsonl`, 500ms poll, per-file byte
    offsets, truncation reset, partial-line safety; emits `data:{worker,ts,line}`; named
    `event: ping` heartbeat every 15s; worker id = filename minus `run-`/`.jsonl`.
  - `GET/POST /api/config` (:638-681): allowlist = `CONFIG_VALIDATORS` (:74-84): FANOUT,
    MAX_ITERATIONS, WORKER_TIMEOUT_SEC, LEASE_MIN, MAX_LANE_RETRIES (positive int), BUDGET_USD
    (decimal), EXEC_CHAIN, REVIEW, VERIFY_MAP (lane-regex). POST: Origin loopback check (:598-608),
    8KiB body cap (:122-148), `Object.hasOwn` proto guard (:659), atomic tmp+rename conf rewrite
    of ALL matching KEY= lines preserving comments (:100-116).
- Security in place: Host header guard (DNS-rebinding, :586-591), Origin guard on POST, path
  traversal + symlink realpath guard in serveStatic (:530-573), `server.mjs` itself never served,
  read-only on BUSDIR (config is sole write surface).
- File header style: JSDoc banner Project/Module/Deps/Tested + Key responsibilities + Design
  constraints; `// --- section ---` dividers.

### 2.2 `site/cockpit.html` (~1088 lines, vanilla JS IIFE, no build step)

Current layout: nav header → hero → `#notice` degraded panel → `#board` count strip (+ warn chips
+ `#cost-inline` + ⚙ AGENTS toggle) → `#drawer` settings accordion (exec chain slots / review
lane / run limits → POST /api/config) → `#models` MODELS strip → `#firehose` panel (kind chips +
worker chips + `#feed`) → footer.

Reusable machinery (KEEP, port into redesign):
- SSE client + zombie watchdog: `startStream()` :863-878, reconnect clears feed (server replays
  from byte 0), `ping` listener, 10s watchdog reconnects after >45s silence :884-889.
- `summarize(o)` :571-618 + `summarizeBlocks`/`classifyBlock` :552-569 + `toolUseText`
  :531-534 + `looksFailed` :538-547 + `usageStr` :621-626 — per-schema humanized one-liners for
  every lane's event shapes (assistant/user, tool_use/tool_result/tool_progress, system,
  result, turn.completed, error/turn.failed, thought/text, end, item.completed).
- Coalescing engine :739-858: `NEVER_COALESCE_TYPES`, `ACCUMULATE_TYPES={thought,text}`,
  `coalesceKeyOf`, live spinner row, `finalizeCoalesce`.
- `normalizeModel`/`modelOf` client mirrors :470-499 (MUST stay in sync with server),
  `MODEL_COLORS` :483-486, `colorFor(id)` hash palette :458-465, `lastModelByWorker` :502.
- Filter chip persistence: localStorage keys `unimatrix-fh-kinds` (default thinking/progress
  OFF), `unimatrix-fh-workers`.
- Pollers: board 2s, cost 10s, models 5s; `degrade()` local-only notice on first-fetch failure.
- Feed cap 500 rows, click-to-expand raw JSON (32KiB cap), RAW pretty-print.
- Settings drawer logic :947-1076 (`postConfig`, `applyDrawerConfig`, exec-chain slot editor).

### 2.3 Server start / lifecycle

- `mon_web_ensure()` src/swarm-lib.sh:966-993: health-probe :4747, else `systemd-run --user
  --unit=svc-unimatrix … node site/server.mjs` (fallback setsid nohup), 5s health poll,
  non-fatal. `mon_web_open()` :998-1022: opens `http://localhost:4747/cockpit.html` once per bus
  lifetime (`.cockpit-opened` O_EXCL marker) via wslview/powershell. Config keys `MON_PORT=4747`,
  `MON_AUTOOPEN=1` (swarm.conf:17-18). Called from swarm-run.sh:462 and swarm-loop.sh:118.

### 2.4 Tests

- `tests/ground-control.bats` — 31 tests; `_free_port`/`_start_server` helpers (:76-88) boot the
  real server on a free port with fixture BUSDIR + fixture swarm.conf copy (EXEC_CHAIN re-pinned
  post-copy to dodge live-conf flake). Covers every endpoint incl. security guards and
  mon_web_ensure/open.
- `tests/cockpit.bats` — tmux monitor + JS-logic mirror tests (not the HTML DOM).
- `site/.assetsignore` excludes server.mjs from public deploy.

### 2.5 Docs anchored to current cockpit

- `specs/05-ground-control.md` (Active — server+cockpit), `specs/06-live-model-cost.md` (Active —
  MODELS strip), `docs/usage.md:239-252` §7 Web cockpit, `docs/research-backlog.md:26-32` (HOTL
  per-worker pause/kill buttons = exactly what this redesign delivers).

### 2.6 Specs / rules / docs conventions (for wave 0 + refactor passes)

- **Spec format** (specs 01-05): H1 → `**Status:**`/`**Date:**`/`**Related specs:**` → `---` →
  Overview → Goals → Non-Goals → Requirements (`| ID | Requirement | Priority |` FR table,
  Must/Should) → Design → Boundaries (Always/Ask first/Never) → Acceptance Criteria (checkboxes
  + Verification bash block) → Open Questions → Dependencies. Spec 06 is a looser variant.
  `specs/README.md` index table `| Spec | Status | Description |` + dependency graph —
  **spec 06 is missing from the index** (fix in wave 0).
- **Spec 05 non-goals that this redesign CHANGES**: "no control surface in web UI (read-only)"
  (specs/05:32-38) — the redesign adds POST /api/ctl. Spec lifecycle rule: only user approves
  status changes; the redesign spec must be a NEW spec (07) + amendments to 05/06, keeping 05/06
  Active but superseding the layout sections.
- **Rules that bind this work**:
  - `rules/file-headers.md` (required, all source files): structured header — summary, Project,
    Module, Deps, Tested, Key responsibilities, Design constraints. server.mjs/cockpit.html
    already carry it; keep updated.
  - `rules/security/owasp-compliance.md` (required, applies-to all): CORS/Origin strictness,
    input validation — POST /api/ctl must match /api/config's guards (Host, Origin, body cap,
    allowlist verbs, no shell injection).
  - `rules/unimatrix/bus-discipline.md`: bus read-only for monitor; answers from handoff files
    only; firehose = monitor-only, never authoritative; jq filter LOCKSTEP with
    `jq_firehose_filter` in swarm-lib.sh.
  - `rules/unimatrix/model-lanes.md`: lane env contracts, ledger no-silent-spend (every agent
    run in this build gets a `docs/ops/llm-runs.md` row).
  - `rules/unimatrix/loop-discipline.md`: judge ≠ executor for review waves.
  - `rules/web/design-quality.md` (recommended): anti-template; the handoff design satisfies it.
  - React/Tailwind rules N/A (`applies-to` gates them; cockpit is vanilla JS single-file).
- **CHANGELOG.md**: Keep-a-Changelog, single `## [Unreleased]`, UPPERCASE groups (ADDED/CHANGED/
  FIXES/DOCS/MAINTENANCE), bold-lead bullets citing spec: `- **<thing> (spec NN).** …`.
  (Ignore `rules/tools/changelog-workflow.md`'s divergent format — repo convention wins.)
- **docs/versions.md**: pinned CLI/model versions — update only if a pin changes (none expected).
- **docs/ops/llm-runs.md**: `| When | What | Lane | Billed |` rows, oldest-first append.

### 2.7 Environment facts (verified)

- playwright-cli 0.1.15 on PATH; headless config at
  `~/.claude/helpers/playwright-cli-headless.config.json` (chromium, isolated, headless,
  1440×900) — Lane A testing per global rules; playwright MCP attaches to Windows Chrome :9222
  (Lane B) for the final human-visible QA.
- Live server: transient systemd unit `svc-unimatrix` running `node site/server.mjs` on
  127.0.0.1:4747 against `./.bus`. Tests must NEVER assume :4747 free —
  always `_free_port` (existing pattern). QA against live :4747 (restart unit to pick up new
  code: `systemctl --user restart svc-unimatrix` — it's transient; if gone, re-launch via
  `mon_web_ensure` mirror argv).
- tmux cockpit (spec 02, swarm-mon.sh) is UNTOUCHED by this redesign.

### 2.8 Bus tree + swarm-ctl (control-surface raw material)

**swarm-ctl verbs** (src/swarm-ctl, dispatch :135-144):
- `pause` → `touch .bus/PAUSE` (:38); `resume` → `rm -f .bus/PAUSE` (:39). PAUSE blocks new
  claims (claim rc2, swarm-lib.sh:102/:120).
- `cancel <id>` → mv specs/|queue/ prompt → cancelled/ + `_rm_sidecars` (:51-63; rc1 if absent).
- `add <promptfile>` → cp into specs/, mv → queue/ (:65-72).
- `abort` → `kill -- -$(cat .bus/run.pgid)` with `kill -0` liveness guard (:74-85).
- `status` → gate counts + limit flags, read-only (:87-102).
- `kill <id> [--cancel]` → kill_subtree via `.bus/pids/<id>`, then requeue claimed→queue (default)
  or → cancelled (:104-129).
- **No `nudge` verb exists** — must be added (kill + requeue + hint append).

**Bus files a UI can derive state from**:
- `queue/*.prompt` queued (sidecars `<id>.lane`/`<id>.write` excluded); `claimed/<id>.<lane:model>`
  — filename encodes lane+model; **mtime = heartbeat (30s touch), NOT claim time**;
  `done/<id>` = one-line JSON `{"id","code":0,"lane":"<served-lane>"}` (provenance);
  `cancelled/*.prompt`; `limits/<lane>.limited` (TTL content, active = mtime+ttl>now),
  `<id>.parked`, `<id>.timedout`, `.chain-<id>` (remaining fallback chain), `<lane>.strikes`,
  `<id>.retries-*`; `pids/<id>` (worker pid); `run-<id>.jsonl` (**mtime = last event time** — the
  stuck detector), `res-<id>.txt` (handoff answer), `prompt-<id>.txt` (archived spec);
  `run.pgid` (run active); `PAUSE`; verify branches = `v-<id>` ids everywhere.
- Loop state (`.bus/loop/<run-id>/`): `state.jsonl` 1 line/iter `{iter,tried,oracle_rc,review,
  cost,ts,sig}` → iter counter; `criteria.md` `stops:` block → max_iterations (the "/12");
  `HALTED.md`/`COMPLETE.md` terminal. **Not exposed by any /api endpoint today.**
- Also not exposed today: per-agent claim/lease detail beyond the stale flag, res/prompt bodies,
  cancelled names, run.pgid liveness, tokens per agent.
- Gate math: `done_n + parked_n >= live_n` where live = queue prompts + claimed + done
  (swarm-lib.sh:135-141, swarm-run.sh:338).
- Ids are spec-authored (`s1-spec`, `s4r-api`, …), loop ids `<run-id>-iN-exec/-review`, verify
  `v-<id>`. No `r-0719`-style run id exists — header shows busdir/loop run-id instead.

## 3. Gap analysis: design mock → real data

| Design element | Real source | Status |
|---|---|---|
| queued/claimed/done/cancelled counts | `/api/bus` counts | exists |
| stale / parked / erroring chips | `/api/bus` stale_leases/parked + retries flags | partially (erroring needs per-agent retry state → new `/api/agents`) |
| gate bar `NN/NN` | gate math done+parked/live | derivable from /api/bus (add live/gate fields) |
| budget bar `$X/$N` | notional dollars total vs BUDGET_USD (/api/config) | needs total-dollars field (extend /api/models or /api/agents) |
| burn $/min total+per-lane | `/api/models` dollars_5m/5 per family | exists (map family→lane) |
| per-agent tiles/heat/rows (age, activity, tok, state) | new `GET /api/agents` (server derives from bus files + jsonl tails) + SSE live updates | NEW endpoint |
| run id / loop N/M / elapsed | `.bus/loop/*/state.jsonl` + criteria stops + run.pgid | NEW endpoint (or /api/agents envelope) |
| pause state / valve | `.bus/PAUSE` existence | NEW field |
| alert cards (rules: age>LEASE_MIN/2, retries≥2, budget>80%, starved queue) | client-side over /api/agents + config thresholds | client logic |
| pulse sparklines, events/min chart, queue trend | client-side ring buffers over SSE arrivals + /api/bus samples | client logic (live-observed, seeded from server ages) |
| flightpath segments/dots | live-observed SSE arrivals per agent + coarse server ages (JSONL event timestamps unreliable across lanes) | client logic, honest live-window rendering |
| drawer events tab | existing SSE + summarize()/coalescing scoped per worker | port existing |
| drawer handoff/spec tabs | `res-<id>.txt` / `prompt-<id>.txt` bodies | NEW detail endpoint (size-capped, id-validated) |
| drawer transcript tab | assistant-message events from SSE (client-collected) | client logic |
| NUDGE/PAUSE/KILL/CANCEL, PAUSE ALL, ABORT, ADD SPEC | new `POST /api/ctl` → execFile swarm-ctl; new `swarm-ctl nudge` verb | NEW (flips spec-05 "read-only web UI" non-goal → spec amendment) |
| verify wave rows `X⊢C` | `v-*` ids + VERIFY_MAP from /api/config | derivable |
| lane nodes (5 lanes incl. grok) | EXEC_CHAIN/VERIFY_MAP config + per-lane aggregates | derive from config, never hardcode 4 lanes |
| ETA "est ~18m" | naive: remaining × median done-duration | best-effort or "—" (no fake data) |

## 4. Server-side blueprint (exact)

Zero-dep Node stdlib throughout; new imports allowed: `node:child_process` (`execFile`),
`node:os` (tmpdir). **Existing endpoints `/api/bus`, `/api/cost`, `/api/models`, `/api/stream`,
`/api/config` are NOT changed** — tests pin their shapes. New consumers use new routes.

### 4.1 Shared primitives (module-level in server.mjs)

- `ID_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/` — every route/verb validates ids against this
  BEFORE touching fs or spawning. Rejects `..`, `.hidden`, `-flag`, anything with `/`.
- `CLAIM_RE = /^(.+)\.((?:claude|codex|gemini|glm|grok):[A-Za-z0-9._-]+)$/` — parses
  `claimed/<id>.<lane:model>` (handles dots in ids and models like `glm-5.2`).
- `RUN_CACHE: Map<filename,{size,mtimeMs,summary}>` — run logs are append-only (truncate-rewrite
  on failover changes size), so `(size,mtimeMs)` is a sound cache key; makes the 2s poll cheap at
  50+ agents. `runSummary(name)` parses a run log once per change into:
  `{tokens, dollars (notional via existing priceBuckets), cost_usd (Σ total_cost_usd on result
  lines), errors (error|turn.failed count), model (last modelOf), first_ts (first parseTs else
  birthtime), last_type, last_excerpt (≤120 chars: message content | grok .data | .result |
  codex .item.text | type)}`. Malformed lines skipped; evict vanished files.
- `readCapped(file, capBytes, {tail=false})` → `{text,size,truncated}|null`.

### 4.2 `GET /api/agents` (polled 2s — the grid snapshot)

Envelope: `{now, lease_min, paused (PAUSE exists), run_active (run.pgid + process.kill(-pgid,0)
try/catch; EPERM=true, ESRCH/absent=false), budget_usd (conf string, "0"=no cap), spent_usd
(Σ runSummary.cost_usd), gate:{done,parked,live} (exact gate_count math), agents:[…]}`.

Agent universe = union of ids from queue/*.prompt, claimed/* (CLAIM_RE), done/*,
cancelled/*.prompt, limits/*.parked. Per agent:

| field | recipe |
|---|---|
| `state` | precedence done → cancelled → claimed → parked (limits/<id>.parked wins over queued) → queued |
| `stale` | claimed only: claim mtime < now − lease_min·60s (heartbeat rule) |
| `verify` | `id.startsWith("v-")` |
| `lane`/`model`/`pinned` | claimed: CLAIM_RE. done: done-marker lane. queued/parked: `.lane` sidecar (pinned=true) → `.chain-<id>` head → EXEC_CHAIN head |
| `heartbeat_age_sec`/`lease_remaining_sec` | claimed only; from claim mtime + lease_min |
| `claim_age_sec` | claimed only: now − (runSummary.first_ts ?? run-log birthtime ?? claim mtime) — NOT claim mtime (heartbeat refreshes it) |
| `last_event_age_sec` | now − stat(run-<id>.jsonl).mtimeMs; null if no log |
| `last_activity` | `last_type · last_excerpt` |
| `tokens`/`dollars`/`cost_usd`/`errors` | runSummary |
| `retries` | int(limits/.retries-<id>) else 0; `timedout` = limits/<id>.timedout exists |
| `chain_left` | token count of limits/.chain-<id> content; null = untouched |
| `done_lane`/`done_code` | JSON.parse(done/<id>), tolerate garbage → nulls |

"Erroring" is CLIENT-derived: `errors>0 || retries>0 || timedout`. Server ships raw counts only.
Client-side (never server): events/min histogram, queue trend, per-lane burn (from /api/models),
elapsed clocks, ETA.

### 4.3 `GET /api/loop`

Newest `BUSDIR/loop/<run>/` by state.jsonl mtime; none → `{"run":null}`. Fields:
`run, iter (non-empty line count of state.jsonl), max_iterations + budget_usd (regex
`/^ {2}max_iterations:\s*(\S+)/m` on criteria.md — two-space indent per _criteria_stop),
cost_total (Σ .cost), last (last parseable state line), halted + halted_reason (HALTED.md first
line ≤200ch), complete (COMPLETE.md), started_ms (criteria.md mtime — written once), steering_bytes`.

### 4.4 `GET /api/agent?id=<id>` (drawer bodies)

400 on ID_RE fail before any fs. `{id, spec:{text,size,truncated,source}, res:{…}, stderr:{…}}`
— spec: first of queue/<id>.prompt, claimed/<id>.* (CLAIM_RE glob), prompt-<id>.txt,
specs/<id>.prompt, cancelled/<id>.prompt @32KiB; res: res-<id>.txt @64KiB; stderr:
run-<id>.jsonl.stderr last 8KiB (tail). All three null → 404.

### 4.5 `POST /api/ctl`

Guards in order (mirrors /api/config): hostAllowed (global) → originAllowed → 403 →
setTimeout(10000) → readJsonBody 64KiB → 400. Body `{verb, id?, hint?, prompt?, cancel?,
confirm?}`. Verb table `CTL_VERBS` (frozen, `Object.hasOwn` lookup — proto-pollution guard):

| verb | validation | swarm-ctl argv |
|---|---|---|
| pause / resume | — | `["pause"]` / `["resume"]` |
| cancel | ID_RE | `["cancel", id]` |
| kill | ID_RE; optional bool `cancel` | `["kill", id]` (+`"--cancel"`) |
| nudge | ID_RE; hint optional ≤16KiB, no `\0` | `["nudge", id(, hint)]` |
| pause-worker | ID_RE | `["pause-worker", id]` |
| resume-worker | ID_RE | `["resume-worker", id]` |
| add | ID_RE; prompt non-empty ≤60000 ch; 409 if id has ANY bus footprint | tmpdir flow below |
| abort | `confirm===true` else 400 | `["abort"]` |

Invocation: `execFile(REPO_ROOT/src/swarm-ctl, args, {cwd:REPO_ROOT, env:{...process.env,
BUSDIR}, timeout:15000, maxBuffer:256*1024})` — literal argv array, NEVER a shell; ID_RE first
char alnum ⇒ no `-`-option injection. Responses: 200 `{ok:true,verb,id?,stdout,stderr}` on exit
0; **409** `{ok:false,error:"swarm-ctl failed",code,stderr}` on nonzero exit (bus refused); 400
validation; 403 origin; 405 non-POST; 500 spawn error/timeout. Synchronous — no 202.

ADD-SPEC flow (server never writes BUSDIR; swarm-ctl stays the one bus writer):
`mkdtempSync(os.tmpdir()/swarm-add-)` → write `<id>.prompt` → `execFile(ctl,["add",tmpfile])` →
always `rmSync(dir,{recursive,force})` before responding.

Header-comment update: "read-only on BUSDIR" constraint becomes "…except bus mutations delegated
to src/swarm-ctl as an execFile child with a fixed argv table; the server process itself never
writes under BUSDIR". No locking for concurrent ctl calls — verbs are mv/rm-based,
race-tolerant; note in route comment.

### 4.6b `swarm-ctl pause-worker <id>` / `resume-worker <id>` (SIGSTOP freeze — the operator's pick)

Per-worker pause via signal freeze of the worker subtree:
- `cmd_pause_worker <id>`: pidfile `pids/<id>` required (rc1 loud if absent). Snapshot the
  subtree (same pgrep walk as kill_subtree — if kill_subtree escalates TERM→KILL, add a
  `signal_subtree <pid> <SIG>` helper that ONLY signals the snapshot, no escalation) and send
  **SIGSTOP**. Then `touch claimed/<id>.*` (fresh lease) and `touch limits/<id>.frozen` flag.
- `cmd_resume_worker <id>`: send **SIGCONT** to the subtree snapshot, `rm -f limits/<id>.frozen`,
  `touch claimed/<id>.*` (fresh lease again).
- **Reaper change (src/swarm-lib.sh `reap()`)**: skip requeue for any id with
  `limits/<id>.frozen` — a frozen worker's heartbeat loop is stopped too; without the skip the
  lease would expire and the reaper would requeue a still-frozen claim (double-claim disaster).
- Known ceiling (document in spec + code comment): the worker watchdog's `sleep
  WORKER_TIMEOUT_SEC` runs on wall-clock — time spent frozen still counts against the timeout,
  so a long pause can trip the watchdog immediately on resume. Acceptable v1; note it in the
  drawer footnote.
- `swarm-ctl kill`/`nudge`/`cancel` on a frozen worker: send SIGCONT first, then proceed
  (a STOPped process ignores TERM until continued) — and always `rm -f limits/<id>.frozen` in
  those paths.
- /api/agents: new per-agent field `frozen` (= limits/<id>.frozen exists); client renders state
  `paused` (glyph `‖`, amber-dim border) ranked between park and run in STATE_RANK; drawer
  button toggles PAUSE ↔ RESUME on `frozen`.
- Tests (tests/swarm-ctl.bats): pause-worker STOPs the marker-sleep (ps state `T`) + writes
  frozen flag + touches claim; resume-worker CONTs (state back to `S`) + clears flag; reap
  skips a stale-but-frozen claim, reaps it once thawed; kill on frozen worker still dies
  (CONT-before-TERM); pause-worker without pidfile fails loudly. ground-control.bats: /api/agents
  frozen field; /api/ctl pause-worker/resume-worker round-trip; frozen agent shown state paused.

### 4.6 `swarm-ctl nudge <id> [hint]` (bash — NOT composed in server)

Semantics (exact, in `cmd_nudge`):
1. If `pids/<id>` exists: `kill_subtree $(<pidfile) TERM`; rm pidfile. Absent = fine.
2. Find prompt: `claimed/<id>.*` first, else `queue/<id>.prompt`; neither → rc1 loud stderr.
3. `mv` to hidden `queue/.nudge-<id>` (invisible to the `*.prompt` claim scan — appending in
   place would race the pool's claim rename).
4. If hint: append `\n\n## OPERATOR HINT (nudge <UTC-ts>)\n<hint>\n`.
5. Fresh start: `rm -f limits/<id>.parked limits/.chain-<id> limits/.retries-<id>
   limits/<id>.timedout` (nudge = "run again from the top").
6. Atomic `mv` → `queue/<id>.prompt`. Keep `.lane`/`.write` sidecars (requeue semantics).
Idempotent (second nudge appends second hint block). Done/unknown id → rc1.
Dispatch + usage line added to src/swarm-ctl; add `nudge` to spec 02 FR-7 verb list.

### 4.7 server.mjs refactors (bundled with the change, minimal)

- Extract `guardedPost(req,res,maxBytes,handler)` from the /api/config POST branch (Origin +
  timeout + readJsonBody + try/catch); both POST routes use it.
- Router stays the if-chain (~10 routes; abstraction unearned).
- `/api/models` NOT folded onto RUN_CACHE in this change (its tests pin behavior; follow-up).
- Implementation order (each lands green): (1) swarm-ctl nudge + swarm-ctl.bats, (2) server
  helpers + 3 read endpoints + read tests, (3) /api/ctl + guardedPost + ctl tests + read-only
  battery update, (4) header docs.

### 4.8 Test wave (exact @test names)

`tests/ground-control.bats` additions — 30+ tests:
- /api/agents: state mapping (queued/claimed/done/cancelled), stale lease → lease_remaining 0,
  parked-wins-over-queued, v-* verify flag, done provenance lane+code, claim filename lane:model
  parse, `.lane` sidecar pinned lane, tokens/dollars/last_activity from run log, error count +
  retries file, PAUSE + dead run.pgid, spent_usd from total_cost_usd, chain_left count.
- /api/loop: run:null without loop dir; iter/stops/last/cost_total/halted from seeded fixture.
- /api/agent: spec+res round-trip for done id; queued fallback + null res; oversize res
  truncated; traversal ids (`../x`, `..`, `.hidden`) → 400 with no file content; unknown → 404.
- /api/ctl: foreign Origin 403 + bus untouched; unknown verb + prototype-key verb 400; malformed
  id 400 without invoking ctl; oversized body 400; GET 405; pause creates PAUSE + resume removes;
  cancel queued→cancelled; cancel unknown id → 409 with stderr; kill terminates recorded worker
  + requeues; kill cancel:true cancels; nudge appends OPERATOR HINT block; add lands
  queue/<id>.prompt via ctl with round-trip text; add of existing id 409; abort without confirm
  400 + stale pgid 409.
- Modify existing read-only battery test: add the 3 new GET routes.

`tests/swarm-ctl.bats` additions — 8 tests: nudge kills+requeues+appends hint; queued id no
pidfile needed; no hint = plain kill+requeue; un-parks + resets chain/retries/timedout; keeps
sidecars; done/unknown id fails loudly; idempotent double-nudge = 2 hint blocks; no `.nudge-*`
temp left behind.

## 5. Client-side blueprint (exact)

### 5.1 File architecture — split into native ES modules (zero build, browser-native)

`site/cockpit.html` becomes a thin shell; logic moves to `site/cockpit/*.js` ES modules
(`<script type="module">`). Each parallel agent owns exactly one JS file (+ ≤1 CSS) — no two
agents ever edit the same file. server.mjs already serves `.js` with correct MIME. Modules need
HTTP (not file://) — cockpit is only ever served over HTTP. Old cockpit.html replaced IN PLACE
(same URL; auto-open + .assetsignore untouched; git history keeps the old version).

| File | Responsibility | ~L | Build slot |
|---|---|---|---|
| `site/cockpit.html` | Shell: head (noindex, self-hosted font, css links), header chrome, status-strip skeleton (ID'd slots), 4 empty view containers `#view-ops #view-grid #view-flight #view-fire`, `#agent-drawer`, `#settings-drawer`, `#toast`, `#notice`, `<script type=module src=cockpit/main.js>`. Written in phase 0, never edited by view agents. | 230 | chrome |
| `site/cockpit/base.css` | Tokens (port `:root` + light-scheme block verbatim), field grid bg, header/tabs, strip, shared atoms (.btn-ctl .chip .badge .pulse .lane-tag toast), blink/rise keyframes. | 280 | chrome |
| `site/cockpit/main.js` | Boot, header+strip rendering (owns those regions), view registry/switching, keyboard map, `unimatrix-view` persistence, degrade wiring, 1s tick. | 220 | chrome |
| `site/cockpit/format.js` | PURE functions, no DOM/fetch: ported summarize/summarizeBlocks/classifyBlock/toolUseText/looksFailed/usageStr/kindFromBadge; normalizeModel/modelOf (sync with server) + MODEL_COLORS + colorFor; esc/fmtTok/fmtTime; NEW fmtAge, pulseStr(▁-▇), `LANES` {claude:C/#7dd3fc, codex:X/#c084fc, gemini:G/#e0b34a, glm:Z/#34d399, grok:K/#f0abfc}, STATE_RANK {err:0,stale:1,park:2,run:3,q:4,done:5,cancelled:6}, tile/heat style maps. | 380 | data |
| `site/cockpit/data.js` | Store + ALL I/O: SSE client + zombie watchdog + replay/live discrimination, pollers (bus 2s, agents 2s, models 5s, cost 10s, loop 5s, config on load+save), reconciliation, per-agent records, pulse buckets, ring buffers, coalescing at BUFFER level (moved from DOM), alert derivation, degrade(). Exposes `store`, `bus` (EventTarget: data/tick/feed:append/feed:update/feed:reset/degrade), `ui`. | 520 | data |
| `site/cockpit/ctl.js` | `ctl(verb,id,extra)` → POST /api/ctl; toast singleton (pending → ok green 2.6s / fail red 6s); armAbort() two-step confirm. | 80 | data |
| `site/cockpit/ops.js` + `ops.css` | OPS WALL: verdict, alerts, pipeline (lane rows from config), heat, burn chart, MODELS strip row (ported .mcell). | 320+130 | V1 |
| `site/cockpit/grid.js` + `grid.css` | MISSION CONTROL: attention rail + rules footer, filter chips, tile grid. | 240+100 | V2 |
| `site/cockpit/flight.js` + `flight.css` | FLIGHTPATHS: axis/NOW, rows/segments/dots, sort+done toggles, 2 mini charts. | 340+110 | V3 |
| `site/cockpit/firehose.js` + `firehose.css` | Legacy firehose as view 4 (key `4`): renders from data.js buffer via feed:* events; kind/worker chips (localStorage keys byte-identical), 500-row cap, hover-pause, click-to-expand (32KiB), spinner rows. Feed element stays mounted (display:none) so scroll/expand survive switches. | 260+90 | V4 |
| `site/cockpit/drawer.js` + `drawer.css` | Agent drawer: header/meta, alarm strip, 4 tabs, ctl buttons. | 290+110 | V5 |
| `site/cockpit/settings.js` | AGENTS config drawer ported verbatim (exec-chain slots/review/limits → POST /api/config); on save calls data.refreshConfig(). Opened via `⚙` header button. | 210 | V6 |

Hard contract: view modules export `{init(rootEl), render()}`; read store/ui, subscribe to bus,
call ctl(); NEVER touch DOM outside own container. Only main.js touches header/strip. Only
data.js fetches. Every file gets the rules/file-headers.md JSDoc header.

### 5.2 Store + reconciliation (data.js contract)

Store: `{ok, paused, config{}, loop{run,iter,max,started_ms,halted,complete}, counts{},
staleLeases[], parked[], activeLimits[], doneRecent[], agents:Map<id,rec>, lanes:Map,
models[], costLanes[], alerts[], series{evtPerBucket:ring(40×30s), burnPerBucket:ring(40),
spentCum:ring(40), queueLen:ring(30)}, feed[] (cap 500)}`. `ui = {view, sel, dtab, mcFilter,
fpSort, fpShowDone, armAbort}`.

Agent record: `{id, lane, model, srvState, state, srvAgeSec, srvAgeAt, lastEvtClient,
claimAgeSec, leaseRemainSec, tokens, retries, errors, timedout, verify, doneLane, lastSummary,
errorStreak, buckets:Uint8Array(6) (10s pulse buckets), spans[], dots[] (cap 24),
events[] (cap 200)}`.

Rules (critical — the foolproof bits):
1. **Server snapshot wins** (state/lane/tokens/lease); SSE only refines between polls.
2. Displayed age = `min((now−srvAgeAt)/1000+srvAgeSec, lastEvtClient? (now−lastEvtClient)/1000 : ∞)`.
3. Derived state: done/cancelled/parked/queued = srvState; claimed → `err` if `retries≥2 ||
   errorStreak≥2 || errors>0&&timedout`, else `stale` if age > LEASE_MIN/2·60, else `run`.
4. **Replay vs live**: onopen sets `backfillUntil = now+2000`; re-connect clears feed +
   per-agent events + coalesce state (server replays from byte 0). Replay events DO populate
   feed/events/lastSummary/model carry-forward (free drawer history) but NEVER touch buckets,
   dots, evtPerBucket, lastEvtClient (replay arrival time is meaningless). Entries get a
   `backfill` flag (drawer renders those dimmer, title "time = replay receipt"). Zombie
   watchdog kept verbatim (ping listener, 45s silence → close+reopen).
5. Coalescing moved into the buffer (not DOM): same NEVER_COALESCE_TYPES/ACCUMULATE_TYPES/
   coalesceKeyOf; continuation mutates last entry (live:true) + feed:update; break finalizes +
   feed:append. Firehose view AND drawer render from the same pipeline.
6. Graceful 404 fallbacks: if /api/agents or /api/loop 404 (old server), page must still fully
   render from /api/bus + SSE (agents built from SSE worker names, srvState 'unknown', ages "—").
   degrade() trigger unchanged (first /api/bus failure).

### 5.3 Element→data mapping (deltas beyond §1.2; NO FAKE DATA anywhere)

- Header run segment: `run <loop.run> · loop <iter>/<max> · <elapsed since started_ms>`; no loop
  → `run —`, omit loop/elapsed (never invent a clock). Hint text: `1–4 views · esc closes`.
  Blink dot: green blinking when SSE seen <20s; amber solid reconnecting; red degraded.
  PAUSE ALL label from `store.paused` (server truth), optimistic flip reconciled next poll.
  ADD SPEC → native `<dialog>`: id input (validated `^[A-Za-z0-9][A-Za-z0-9._-]*$`) + textarea →
  `ctl('add',{id,prompt})`.
- Status strip: stale chip = derived-stale count (softer client threshold; fallback
  staleLeases.length); gate `den = gate.live`, `num = done+parked`, green/amber segments;
  budget: cap=Number(config.BUDGET_USD); cap>0 && spent_usd!=null → bar (thresholds >60% amber,
  >80% red) + `$spent / $cap`; cap==0 → `$spent spent · no cap`, no bar; spent unknown →
  `budget —`.
- Alerts (severity err > silent > budget > starved, max 3 on ops + `+N more →` chip → grid ATTN):
  1. error: retries≥2 or errorStreak≥2 → `✕ error ×N` / verb KILL+CANCEL → ctl kill{cancel:true}.
  2. silent: derived stale → `silent <age>` / `lease dies in <lease_remaining>` / verb NUDGE NOW.
  3. budget: cap>0 && spent>0.8cap → `N% burned` / verb PAUSE QUEUE → ctl pause.
  4. starved: queued>0 && !paused && some EXEC_CHAIN lane 0 claimed continuously >60s
     (lane.idleSince tracking) → inspect-only card (no ctl verb exists).
- Pipeline: SPECS = gate.live (∅ sum of counts); QUEUE trend from queueLen ring (∅ `···`); lane
  rows = one per EXEC_CHAIN entry in order (+ REVIEW lane if extra) — ×n claimed count, lane
  pulse (sum of member buckets), $burn/min (models families → lane via normalizeModel), extra:
  `.limited` red / `⚠ <id> silent` amber / `N parked` amber / blank; DONE newest = doneRecent[0]
  (age only if server ships mtime); GATE holding/open per num≥den; VERIFY letters from
  config.VERIFY_MAP (never hardcoded); PARKED/CANCELLED chips real counts.
- Heat cells: done #101812+faint border / queued transparent+gray border / err #f97066 / stale
  #e0b34a / parked rgba(224,179,74,.35) / run: ≤30s #34d399, >30s #1d8a63. Tooltip
  `id · age · activity`.
- Burn chart: burnPerBucket bars; bar red when that bucket errN≥3; legend `red bucket = ≥3
  errors/30s` (the mock's "spike = retry storm b-23" caption is fake — dropped); empty →
  `collecting… (needs ~1 min)`.
- Tiles: activity line = run→lastSummary.text (∅ `working…`), q→`waiting for claim`,
  done→`handoff written ✓`, park→`parked (.limited)`, err→lastSummary (∅ `error — retrying`),
  stale→`no events — nudge?`; tok from /api/agents (∅ `—`); legend says "pulse = tool-calls
  observed since page load".
- Flightpaths: window = rolling 20min, NOW at 86%; x(t)=clamp((t−(now−20m))/20m,0,1)×86. Seed
  spans at load from /api/agents (exec span [now−claimAge, now−srvAge]; stale → amber-dashed
  silent tail; queued → gray-dashed). After load: live SSE extends exec span; gap>60s opens
  silent span; lane change between polls → red-dashed gap + new exec. Dots LIVE ONLY (blue
  tool_use, red error, cap 24/agent), legend `dots since page load`. Done rows w/o ages → ✓ age
  column + 2%-wide stub at NOW−age (no invented takeoff). Verify rows: `v-x <J>⊢<G>` purple
  hatch. Sort quiet (STATE_RANK then age desc) ↔ bus order; done toggle; both persisted
  (`unimatrix-fp-sort/done`). Mini charts: spentCum (real spent_usd when known; else
  client-integrated and LABELED `$ since page load`), events/min (red = errN≥3).
- Drawer: meta `claimed <age> · <tok> tok` — mock's per-agent `$` dropped unless /api/agents
  ships dollars (it does — `dollars` field → show `· $X.XX notional`); events tab = per-agent
  buffer (replay = full history — improvement over mock), synthetic silent divider row when
  age>60s; transcript = client-assembled agent_message/text/thinking entries; handoff/spec tabs
  = GET `/api/agent?id=<id>` res/spec bodies (∅ `no handoff yet — written on finalize` /
  `spec body unavailable`); buttons NUDGE (ctl nudge) / KILL (kill) / KILL+CANCEL
  (kill,cancel:true) / CANCEL (cancel; disabled while claimed — queue/spec verb). Mock's
  per-agent PAUSE button has no ctl verb → replaced by KILL+CANCEL. Done/cancelled → all
  disabled. Footnote static.
- Toast: every ctl() call; pending → `swarm-ctl <verb> <id> · ok` / red `✕ <verb> failed:
  <stderr|network>` 6s.
- ABORT: two-step (button → `CONFIRM ABORT` solid red 5s window → ctl abort{confirm:true}).
- Keyboard: 1/2/3/4 views (ignored in inputs), Esc closes agent drawer → settings → dialog.
- localStorage: existing `unimatrix-fh-kinds`/`unimatrix-fh-workers` unchanged; new
  `unimatrix-view`, `unimatrix-fp-sort`, `unimatrix-fp-done` (via legacy loadJSON/saveJSON).
- Legacy home: firehose = view 4; settings = ⚙ header button; MODELS strip = bottom of OPS WALL;
  degrade() unchanged (hides views+strip, shows #notice, clears timers).

### 5.3b Functionality EXPANSION beyond the mock (operator: "expand the functionality based on
the design provided" — every wireframe annotation becomes a real wired feature)

1. **Real ETA + done ages.** /api/agents done entries gain `done_ms` (stat mtime of done/<id>)
   and the envelope gains `run_started_ms` (min runSummary.first_ts across run logs — real
   elapsed even for plain /swarm runs, not just loops). Client: DONE node `newest <id> · <age>`
   real; ops verdict `est ~Xm left` becomes REAL: rate = dones in trailing 10min (from done_ms),
   eta = remaining/rate, shown only when rate>0 (else omitted). Header elapsed falls back to
   run_started_ms when no loop.
2. **Pipeline nodes are click-filters** (wireframe 1e note). Clicking QUEUE → grid view +
   QUEUED filter; DONE → grid + DONE; PARKED chip → grid + ATTN; a lane row → grid + NEW
   per-lane filter. Grid gains lane filter chips (one per EXEC_CHAIN lane, letter+color) that
   compose with the state filter.
3. **Parked alert card** (wireframe 1a shows `b-41 parked · REQUEUE → C`). Alert type 5:
   state parked → title `▣ parked`, sub `<lane> lane .limited (<TTL left>)`, verb
   `NUDGE (requeue)` → ctl nudge (nudge already resets the chain to EXEC_CHAIN head = requeue
   onto the first healthy lane).
4. **Limit TTL countdowns.** /api/agents envelope gains `limits:[{lane, expires_in_sec}]`
   (content of limits/<lane>.limited = TTL secs, expiry = mtime+TTL−now). Lane rows render
   `.limited · 4h12m left`; parked cards reuse it.
5. **New-alert notification** (wireframe 1d note "flash tab title + beep"). When alerts gain a
   NEW id: flash `document.title` (`⚠ N — UNIMATRIX` ↔ normal, 3×) + swap favicon to an amber
   dot variant while any alert active. Beep via WebAudio oscillator, OFF by default, toggled by
   a bell chip in the header, persisted `unimatrix-beep`.
6. **Flightpaths zoom + follow** (design 1c header "zoom: drag · □ follow NOW"). Window preset
   chip cycling 5m/20m/60m (persisted `unimatrix-fp-zoom`) + `follow NOW` checkbox (default on;
   off freezes the window end for inspection, dashed NOW line keeps moving).
7. **ADD SPEC with lane pin + write grant.** Dialog gains optional lane:model select (from
   EXEC_CHAIN + `default`) and a write-dir field. `swarm-ctl add` extended:
   `add <promptfile> [--lane lane:model] [--write <dir>]` writes the `<id>.lane`/`<id>.write`
   sidecars alongside (specs/ then mv'd with the prompt — same two-step). /api/ctl add body
   gains `lane?`, `write?` (validated: lane against LANE_MODEL regex, write must be an existing
   directory — validated server-side via fs.statSync, and gemini pin refused (read-only lane,
   mirrors lane_cmd)). Tests for both.
8. **Per-agent notional $ in drawer meta** (`· $0.42 notional`) — /api/agents `dollars` field
   already ships; render it.
9. **Loop header tooltip.** Header loop segment gets a hover tooltip: criteria stops
   (max_iterations, budget), halted/complete state, steering_bytes — all from /api/loop.
10. **Cancelled list.** /api/bus already counts; /api/agents includes cancelled agents —
    grid DONE filter becomes `DONE+CANCELLED` chip label `FINISHED n`; cancelled tiles get `⊘`
    glyph, dim.

Spec 07 gains FR-17..FR-22 covering items 1-7 (Should priority for 5/6, Must for the rest).
QA checklist gains steps: click QUEUE node → grid QUEUED filter active; parked card NUDGE
requeues b-41 (fixture asserts queue/b-41.prompt reappears + .chain reset); title flashes on
alert appearance; zoom chip cycles + follow-NOW freeze; ADD SPEC with lane pin lands
queue/<id>.lane; drawer PAUSE freezes (fixture pid state `T`) and RESUME thaws.

### 5.4 API contract reconciliation (server §4 is authoritative)

- Drawer bodies: `GET /api/agent?id=<id>` (query param, NOT path segment).
- Header state: `/api/agents` envelope (paused, run_active, gate, spent_usd, budget_usd) +
  `/api/loop` (run, iter, max_iterations, started_ms, halted, complete). specs_total = gate.live.
- Kill+cancel: `{verb:"kill", id, cancel:true}` (no separate kill-cancel verb).
- ctl success = HTTP 200 `{ok:true,...}` (synchronous), failure 409 carries stderr → toast text.
- Field names: `lease_remaining_sec`, `done_lane` (server names win over UI blueprint variants).

## 6. Wave plan — MAX-PARALLEL, EXECUTED VIA /swarm (dogfood)

**The build itself runs through unimatrix's own bus.** Each work unit below = one bus spec
(`.bus/specs/<id>.prompt` + `<id>.write` sidecar pointing at the repo, optional `<id>.lane`
pin), fanned out by `./swarm-run.sh` (FR-15 write workers). Fable (this session) = PLAN +
ORCHESTRATOR roles only — writes the specs, drives waves, gates, adjudicates, commits. Never
executes build work itself.

Swarm mechanics for this build:
- **One spec = one owned file (or disjoint file set).** The ES-module split (§5.1) exists
  exactly so parallel write workers never touch the same file — zero merge conflicts without
  worktree isolation. Spec text MUST name its owned files and forbid touching anything else,
  and forbid `git` commands (Fable commits).
- **FANOUT bumped for the big wave**: `FANOUT=8 ./swarm-run.sh …` (env > file precedence).
  Lanes: current EXEC_CHAIN `glm:glm-5.2 grok:grok-4.5 claude:haiku`; pin harder specs
  (`flight.js`, `data.js`, server.mjs) to stronger lanes via `.lane` sidecars
  (e.g. `codex:default` or `claude:sonnet`), leave ports/CSS to the cheap chain. gemini never
  gets a `.write` spec (read-only lane, refuses loudly).
- **Every spec prompt embeds**: the plan-section slice it implements (§ refs below), the
  design-file path, file-ownership list, "handoff = write a summary of what you changed +
  test results to your res file", and the no-fake-data rule.
- **Verify wave** after each swarm run: `./swarm-run.sh verify` (VERIFY_MAP judge≠executor)
  on doubtful branches; Fable reads `res-*.txt` handoffs (never terminal), runs the local gate,
  fixes-or-respecs failures as new specs.
- **Gate after every wave** (Fable, local): `bats tests/ && shellcheck -x swarm-run.sh
  swarm-loop.sh swarm-mon.sh src/swarm-lib.sh src/swarm-ctl` + `node --check site/server.mjs
  site/cockpit/*.js`. Commit to main per wave. Known flake: ground-control test 43 (pgrep race
  with live :4747) — re-run in isolation before judging red.
- **Ledger**: LEDGER_AUTO=1 auto-appends a row per finalized branch; Fable verifies rows exist
  per wave (no silent spend).
- **Bonus dogfood**: keep the LIVE cockpit at :4747 open during the build — the old cockpit
  monitors the swarm building its replacement.
- Fallback: if a lane parks (.limited) mid-wave, chain failover handles it; if the whole bus
  wedges, Fable falls back to direct Agent-tool subagents for the remainder of that wave (same
  spec text), noting it in the ledger.

### Wave 0 — Specs (Fable writes directly; PLAN role — not swarmed)

1. Create `specs/07-cockpit-redesign.md` (**Active** — approval of this plan = approval), format
   per spec 01-05 template: Status/Date/Related(02,05,06) → Overview → Goals → Non-Goals (no
   framework/build/npm; no WebSockets; tmux cockpit untouched; no per-agent PAUSE verb) →
   FR table:
   - FR-1 three views + firehose view 4 + keyboard 1-4/Esc (Must)
   - FR-2 header (run/loop/elapsed from /api/loop, pause toggle, add-spec dialog, abort
     2-step) (Must)
   - FR-3 status strip (counts/gate/budget/burn per §5.3) (Must)
   - FR-4 `GET /api/agents` per §4.2 (Must)
   - FR-5 `GET /api/loop` per §4.3 (Must)
   - FR-6 `GET /api/agent?id=` per §4.4 (Must)
   - FR-7 `POST /api/ctl` per §4.5 incl. security guards (Must)
   - FR-8 `swarm-ctl nudge` per §4.6 (Must)
   - FR-9 ops wall (verdict/alerts/pipeline/heat/burn/MODELS) (Must)
   - FR-10 mission control (rail/filters/tiles) (Must)
   - FR-11 flightpaths (spans/dots live-window policy, sort/done toggles, mini charts) (Must)
   - FR-12 agent drawer (4 tabs + 4 ctl buttons + alarm strip) (Must)
   - FR-13 alert rules from config thresholds (Must)
   - FR-14 no-fake-data rule: every rendered number traceable to a bus file/endpoint; absent →
     "—"/hidden/labeled (Must)
   - FR-15 ES-module split per §5.1, legacy machinery ported (summarize/coalesce/watchdog/
     localStorage keys) (Must)
   - FR-16 lanes/verify text always config-driven, 5 lanes incl. grok K/#f0abfc (Must)
   → Design (condensed §4+§5 with design-token table §1.1) → Boundaries (Never: fake data,
   shell-string ctl invocation, bus writes from server process, touching /mnt bus) → Acceptance
   Criteria (checkbox per FR + verification commands: bats, node --check, playwright-cli QA
   script §8) → Dependencies.
2. Amend `specs/05-ground-control.md`: non-goal "no control surface" → superseded-by-07 note
   (control lands via /api/ctl with 07's guards); cockpit.html layout section → "superseded by
   spec 07 layout; API + serving contract unchanged". Status stays Active.
3. Amend `specs/06-live-model-cost.md`: MODELS panel placement → "ops-wall bottom strip (spec
   07)"; everything else unchanged.
4. `specs/README.md`: add 06 (missing) + 07 rows to index + dependency graph.
5. Amend `specs/02-cockpit.md` FR-7 verb list: + `nudge <id> [hint]`.

### Wave 1 — RED — swarm run #1 (2 write specs, parallel; new tests must FAIL)

Specs (both `.write` → repo root):
- `w1-red-server.prompt` (pin `.lane` → `claude:sonnet` or codex): append §4.8
  ground-control.bats tests (~38 incl. pause-worker + expansion fields) — fixtures per test,
  _free_port/_start_server pattern, marker-sleep pid pattern for ctl kill tests. Owns ONLY
  tests/ground-control.bats.
- `w1-red-ctl.prompt` (cheap chain): append §4.8 + §4.6b swarm-ctl.bats tests (~13) (+
  reap-frozen test in swarm-lib.bats if cleaner there). Owns tests/swarm-ctl.bats
  (+ tests/swarm-lib.bats).
Run: `./swarm-run.sh` after `swarm-ctl add` of both. Gate: new tests RED, old suite GREEN.
Commit `test(cockpit): red wave for spec 07`.

### Wave 2 — GREEN server — swarm run #2 (2 write specs, PARALLEL — disjoint files)

- `w2-ctl.prompt` (pin strong lane): src/swarm-ctl (nudge §4.6, pause-worker/resume-worker
  §4.6b, add --lane/--write §5.3b·7, usage) + src/swarm-lib.sh (reap frozen-skip,
  signal_subtree if needed). Owns those 2 files. Target: swarm-ctl.bats + swarm-lib.bats green,
  shellcheck clean.
- `w2-server.prompt` (pin strong lane, e.g. codex:default): site/server.mjs — helpers
  (ID_RE/CLAIM_RE/RUN_CACHE/runSummary/readCapped), /api/agents (+frozen, done_ms,
  run_started_ms, limits TTL §5.3b), /api/loop, /api/agent, guardedPost, /api/ctl (§4.5 + both
  pause-worker verbs + add lane/write validation), header update. Owns server.mjs only. ctl
  execFile integration tests may stay red until w2-ctl lands — Fable re-runs the suite after
  BOTH finish.
Gate: full bats green. Commit.

### Wave 3 — GREEN client — swarm runs #3a then #3b (peak parallelism)

- Run #3a (2 write specs, parallel, disjoint): `w3-chrome.prompt` → cockpit.html shell +
  base.css + main.js + empty view stubs. `w3-data.prompt` (pin strong lane) → format.js +
  data.js + ctl.js per §5.2/§5.4 (port legacy pure functions VERBATIM via
  `git show HEAD:site/cockpit.html`).
- Run #3b (**6 write specs in one swarm run, FANOUT=8** — zero shared files):
  `w3-ops.prompt` (ops.js/ops.css), `w3-grid.prompt`, `w3-flight.prompt` (pin strongest lane —
  hardest math), `w3-fire.prompt` (cheap — port), `w3-drawer.prompt`, `w3-settings.prompt`
  (cheap — verbatim port). Each spec embeds: design path, its §5.3/§5.3b slice, store contract
  §5.2, ownership list, "pixel-faithful, no fake data, file header required".
- Gate: node --check all; bats green; smoke = fixture-bus server + playwright-cli open/snapshot
  each view, zero console errors. Commit.

### Wave 4 — REFACTOR 1: specs adherence — swarm run #4 (3 read-only specs, parallel)

No `.write` sidecars (audit = read-only; gemini lane usable here):
`w4-audit-server.prompt` (server vs spec 07 FR-4..8 + 05/06 byte-identical endpoints),
`w4-audit-ui.prompt` (views vs FRs + §1.2 element-by-element pixel pass vs the .dc.html),
`w4-audit-specs.prompt` (07 acceptance tickable, README index). Handoffs = findings lists.
Fable triages → fix specs (`w4f-*.prompt`, `.write`, pinned to each file's owner scope) →
swarm run #4f. Gate + commit.

### Wave 5 — REFACTOR 2: rules adherence — swarm run #5 (2 read-only audits → fix specs)

`w5-audit-rules.prompt` (file-headers on every touched file; owasp checklist on /api/ctl;
bus-discipline: server never writes bus, ctl sole mutator, SSE monitor-only; design-quality) +
`w5-audit-conventions.prompt` (bash strictness, shellcheck, changelog rows per wave,
versions.md). Fix specs as needed. Gate + commit.

### Wave 6 — Docs + changelog — swarm run #6 (1 cheap write spec)

`w6-docs.prompt`: CHANGELOG `[Unreleased]` ADDED `**Cockpit redesign — 3-view agent cockpit +
control surface (spec 07).**` (+ CHANGED for 05/06/02 amendments); docs/usage.md §7 rewrite;
docs/research-backlog.md HOTL item marked done; specs/README cross-refs.

### Wave 7 — Simplifier + reviewers (apply ALL findings, even low)

1. code-simplifier agent (Claude Code Agent tool — skill-specific, not swarmed) over
   site/cockpit/* + server.mjs + swarm-ctl deltas.
2. code-reviewer agent over the full diff.
3. codex review (policy: codex reviews unimatrix builds): manual `codex exec -s read-only`
   over the diff. Ledger row.
4. Optionally mirror 2-3 as read-only swarm specs on the REVIEW lane for a second opinion
   (judge ≠ executor: reviewer lane must differ from the lane that wrote each file — check
   done/-marker provenance).
5. APPLY EVERYTHING incl. low-priority (the operator's explicit instruction); genuinely-wrong
   findings get a written refutation in wave notes. Fixes via `w7f-*.prompt` write specs or
   direct edits for one-liners. Gate + commit.

### Wave 8 — QA (playwright CLI fixture pass, then live MCP pass; fix on the way)

Fixture pass (Lane A headless):
1. Build `tests/fixtures/cockpit-bus/` + `cockpit-swarm.conf` per §5.5-QA fixture spec below.
2. `BUSDIR=<fixture> SWARM_CONF=<fixture-conf> PORT=4799 node site/server.mjs &`
3. `playwright-cli --config ~/.claude/helpers/playwright-cli-headless.config.json open
   http://127.0.0.1:4799/cockpit.html` then flagless verbs; run the 18-step checklist §5.5.
   Fix issues as found; re-run until clean.

Live pass (Lane B — playwright MCP → Windows Chrome :9222):
4. `systemctl --user restart svc-unimatrix` (transient; if gone, mirror mon_web_ensure argv).
5. Start a real cheap run: `FANOUT=2 ./swarm-run.sh "<trivial question>"` (ledger row).
6. `~/.claude/helpers/debug-chrome.sh`; playwright MCP attach; navigate
   http://localhost:4747/cockpit.html; run live checklist §5.5 (first-5s seed behavior, tick,
   done transition, nudge round-trip toast+flightpath, server restart replay no-dupes, MODELS
   live, grok K color if in chain). Fix issues on the way; screenshot each view.

### Wave 9 — Close

- Ledger check: LEDGER_AUTO rows for every swarm branch (all waves) present in
  docs/ops/llm-runs.md; manual rows for codex review + any Agent-tool work (Spawned agents
  lane) + the live QA run.
- Final gate: full `bats tests/` + shellcheck + playwright fixture pass re-run.
- Final commit + push to main.
- Purge `.bus/` build specs (or `swarm-ctl cancel` leftovers) so the build swarm's bus state
  doesn't pollute the next real run.

### §5.5 QA fixture + checklist (verbatim for the QA agent)

Fixture bus must exercise EVERY visual state: `queue/b-44.prompt b-45.prompt` (queued);
`claimed/b-03.claude:sonnet` mtime now + run-b-03.jsonl (system init w/ model, assistant
tool_use Bash, tool_result, assistant text) (running); `claimed/b-17.codex:default` mtime −10min
+ run-b-17.jsonl mtime −10min (stale; LEASE_MIN=15 → 10m > 7.5m); `claimed/b-23.glm:glm-5.2` +
run-b-23.jsonl with 3 `{"type":"error","message":"ETIMEDOUT api.z.ai"}` + limits/.retries-b-23=2
(erroring); `queue/v-01.prompt` + done provenance for its target (verify row);
`done/b-01 done/b-35` staggered mtimes as `{"id","code":0,"lane":"glm"}` + res-b-35.txt +
prompt-b-35.txt (done + drawer bodies); `cancelled/b-09.prompt`; `limits/glm.limited` (content
18000) + `limits/b-41.parked` + queue/b-41.prompt (parked); loop/r-t/{criteria.md with stops
block max_iterations: 12, state.jsonl 3 lines} (header loop 3/12); conf: LEASE_MIN=15
BUDGET_USD=10 EXEC_CHAIN with all 5 lanes incl grok, full VERIFY_MAP. PAUSE toggled mid-test.
ctl verbs run against the REAL swarm-ctl on the fixture bus (kill test seeds a marker-sleep pid
like swarm-ctl.bats; a missing-pid kill asserts the 409 red-toast path).

18-step Lane-A checklist: (1) open, wait `2 queued`, zero console errors; (2) 4 tabs + blink
dot + `run r-t · loop 3/12` (never `r-0719`); (3) verdict `⚠ 2 NEED ATTENTION` amber; b-17 card
`silent 10m`+NUDGE NOW; b-23 card `×2`+KILL+CANCEL; (4) QUEUE 2·jump-chips; lane rows == 5 with
grok K; glm `.limited`; VERIFY letters == fixture VERIFY_MAP; GATE `3/8`-shaped; PARKED 1
CANCELLED 1; (5) heat cell colors (b-23 rgb(249,112,102), b-17 rgb(224,179,74), b-01 dim);
(6) key 2 → grid; ATTN filter isolates trouble; done tiles faded+last; b-44 `waiting for claim`;
(7) tile b-17 → drawer alarm strip + replay events; b-35 handoff shows res body; b-17 handoff
`no handoff yet`; (8) NUDGE toast ok; KILL on pid-less id → red failed toast; CANCEL disabled
while claimed; (9) Esc closes; (10) key 3 → flight rows + amber dash b-17 `10m` + dashed b-44
`—` + b-41 `parked` + v-01 hatch; (11) append a live tool_use line to run-b-03.jsonl → within 2s
blue dot + pulse rise + events/min bar + age reset; (12) sort toggle + done toggle; (13) key 4 →
firehose replay rows, worker chips, TOOLS chip off hides rows, persists across reload,
click-to-expand raw; (14) touch PAUSE → CLAIMS BLOCKED + valve PAUSED + ▶ RESUME within 3s;
rm → reverts; (15) reload → view persisted; (16) degrade: static serve without /api → notice
shown, no console storm; (17) anti-fake sweep: `grep -rn "r-0719\|b-23\|~18m\|retry storm\|
0\.42" site/cockpit/ site/cockpit.html` → zero hits outside comments; (18) screenshot each view
1440×900.

## 7. Files touched (complete)

- NEW: `specs/07-cockpit-redesign.md`, `site/cockpit/{base.css,main.js,format.js,data.js,ctl.js,
  ops.js,ops.css,grid.js,grid.css,flight.js,flight.css,firehose.js,firehose.css,drawer.js,
  drawer.css,settings.js}`, `tests/fixtures/cockpit-bus/*` + `cockpit-swarm.conf`.
- REWRITTEN: `site/cockpit.html` (shell).
- MODIFIED: `site/server.mjs`, `src/swarm-ctl` (nudge, pause-worker/resume-worker, add
  --lane/--write), `src/swarm-lib.sh` (reap() frozen-skip + signal_subtree helper if needed),
  `tests/ground-control.bats`, `tests/swarm-ctl.bats` (+ possibly `tests/swarm-lib.bats` for
  reap-frozen), `specs/05|06|02|README`, `CHANGELOG.md`, `docs/usage.md`,
  `docs/research-backlog.md`, `docs/ops/llm-runs.md`.
- UNTOUCHED: swarm-run.sh, swarm-loop.sh, swarm-mon.sh (tmux cockpit), swarm.conf,
  site/index.html, site/.assetsignore (server.mjs already excluded; `cockpit/` modules are
  public-safe static).

## 8. Verification (end-to-end)

1. `bats tests/` — all green (incl. ~42 new tests; flaky test 43 re-run in isolation if red).
2. `shellcheck -x swarm-run.sh swarm-loop.sh swarm-mon.sh src/swarm-lib.sh src/swarm-ctl`.
3. `node --check site/server.mjs site/cockpit/*.js`.
4. Playwright Lane-A 18-step fixture checklist clean.
5. Live playwright-MCP pass on :4747 with a real run — controls round-trip, replay no-dupes.
6. Spec 07 acceptance checkboxes all tick; CHANGELOG + ledger rows present.

## 4. Wave plan (TBD)

TBD
