# Discovery — plugin/CLI unification, cockpit MySQL mirror, fleetops hook

**Role:** PM-stage discovery (facts only, read-only research). Companion docs in this same plan
folder (brainstorm, pre-mortem, PRD) synthesize on top of this.

**Scope note:** repo worktree `~/code/unimatrix-calldev` (branch `call-dev`). The live
checkout `~/code/unimatrix` is another agent's — not read here. State as of commit
`822aee6` (spec 15 "call" verb + spec 16 umbrella CLI, both shipped; spec 16's plugin packaging is
explicitly deferred, see §3).

---

## 1. Cockpit today

### Routes (`site/server.mjs`)

All routes are read-only GETs over the file-bus except the two guarded POSTs. Every route is a
plain `if (pathname === ...)` dispatch in one `http.createServer` handler (`site/server.mjs:1636-1755`).

| Route | Function | What it derives, from what |
|---|---|---|
| `GET /health` | inline | `{ok:true, busdir}` |
| `GET /api/bus` | `busSnapshot` (`server.mjs:245-285`) | counts (queued/claimed/done/cancelled — only `*.prompt` counts as a queued unit, `server.mjs:274`), `stale_leases` (claimed/ mtimes older than `LEASE_MIN`), `active_limits`/`parked` (`limits/*.limited`/`*.parked` filename suffix), last 50 `done/` entries by mtime |
| `GET /api/cost` | `costSummary` (`server.mjs:307-340`) | sums top-level numeric `.usage` fields across every `run-*.jsonl`, bucketed by lane heuristics ported from `swarm-mon.sh _cost_summary` |
| `GET /api/models` | `modelsSummary` (`server.mjs:489-567`) | live per-model 5-min-window token/dollar view, `PRICES` table is a hardcoded notional price sheet (`server.mjs:347-357`) |
| `GET /api/speedwars` | `speedwarsSnapshot` (`server.mjs:438-484`) | parses `docs/ops/speedwars.jsonl` (NOT the live bus — the one route whose subject is history), splits rows by `.type` (absent = card, per spec 08 FR-1's discriminator) |
| `GET /api/stream` | `startStream` (`server.mjs:571-647`) | SSE tail of `run-*.jsonl`, 500ms poll, byte-offset `Map` held in server memory |
| `GET/POST /api/config` | `configSnapshot`/`writeConfigValue` (`server.mjs:75-128`, `1668-1698`) | allowlisted `swarm.conf` keys only (`CONFIG_VALIDATORS`, `server.mjs:86-96`) |
| `GET /api/agents` | `agentsSummary`/`buildAgent` (`server.mjs:863-1097`) | 2s grid snapshot: unions ids across `queue/claimed/done/cancelled/limits`, resolves state precedence (done→cancelled→claimed→parked→queued, `server.mjs:991-996`), merges a cached per-run-log summary |
| `GET /api/loop` | `loopSummary` (`server.mjs:1119-1218`) | newest `.bus/loop/<run>/{criteria.md,state.jsonl,HALTED.md,COMPLETE.md,steering.md}` |
| `GET /api/agent?id=` | `agentDetail` (`server.mjs:1258-1282`) | drawer bodies: first-present prompt/spec candidate (32KiB cap), `res-<id>.txt` (64KiB cap), `run-<id>.jsonl.stderr` tail (8KiB cap) |
| `POST /api/ctl` | `handleCtlBody`/`execCtl` (`server.mjs:1284-1502`) | delegates to `src/swarm-ctl` via `execFile` with a fixed argv table (`CTL_VERBS`, `server.mjs:1288-1298`); server never writes under `BUSDIR` itself except one line to `audit.jsonl` per call (`auditLog`, `server.mjs:1587-1605`) |
| everything else | `serveStatic` (`server.mjs:1516-1559`) | path-traversal-safe static file serving of `site/`, symlink-realpath double-checked, never serves `server.mjs` itself |

`/api/agents`'s per-run-log parse is cached in an in-memory `RUN_CACHE` Map keyed by
`(size, mtimeMs)` per filename (`server.mjs:711-730`) — cheap at 50+ agents, but the cache itself
is server-process memory, not disk.

**Implication:** the cockpit is a pure view over the live bus tree plus one historical file
(`docs/ops/speedwars.jsonl`); it has no database, no ORM, no schema migration today — a MySQL
mirror would be net-new plumbing, not a swap of an existing storage layer.

### `site/cockpit/` views

`data.js` (`site/cockpit/data.js:1-120`) is the single fetcher/store for every view — pollers for
`/api/bus` (2s), `/api/agents` (2s), `/api/models` (5s), `/api/cost` (10s), `/api/loop` (5s),
`/api/config` (on load), plus the `/api/stream` SSE with a 45s zombie-watchdog. Views (`grid.js`,
`firehose.js`, `flight.js`, `ops.js`, `speed.js`, `ctl.js`, `drawer.js`) only read `store`/`ui` and
subscribe to the `bus` EventTarget — none of them fetch independently. `speed.js` is the one view
whose backing data (`/api/speedwars`) is historical rather than live-bus (spec 09).

### Ephemeral vs. durable state

**Ephemeral — dies with the busdir, or with the server process:**
- Everything under `.bus/` (or a run-scoped `.bus-<name>/`, e.g. `.bus-cockpit057b/` seen in
  `feedback/2026-07-25-unimatrix-cockpit057b-auto-parked.md`): `queue/`, `claimed/`, `done/`,
  `cancelled/`, `limits/*` (`.limited/.parked/.dead/.broken/.timedout/.retries-<id>/.chain-<id>/.fbreason-<id>`),
  `run-<id>.jsonl(.stderr)`, `res-<id>.txt`, `prompt-<id>.txt`, `run.pgid`, `PAUSE`.
- `.bus/audit.jsonl` and `.bus/notes-lessons.md` — both live *inside* `BUSDIR` (`server.mjs:46`,
  `1600`; spec 12 FR-6) despite the "durable copy" wording in `server.mjs:1597`'s comment — that
  comment means durable-across-server-restart (it's a file, not memory), **not** durable across a
  busdir wipe/reuse. Worth flagging precisely because it reads as more durable than it is.
- The `/api/stream` byte-offset `Map` (`server.mjs:579`) and `RUN_CACHE` (`server.mjs:711`) —
  server-process memory, rebuilt from disk on restart, gone on process death.
- `.gitignore` line 29 has a `docs/ops/bus-archives/` entry, but **no code writes there** — grep
  across `*.sh`/`*.md`/`*.mjs` for `bus-archives` returns nothing. It is a reserved/aspirational
  path, not a working archival mechanism.

**Durable on disk, but gitignored (survives a busdir wipe, not a fresh clone):**
`docs/ops/speedwars.jsonl` (`.gitignore:27`), `docs/ops/run-reviews.md` (`.gitignore:26`),
`docs/ops/llm-runs.md` (`.gitignore:25`, copied by hand from the tracked
`docs/ops/llm-runs.example.md` template).

**Durable and git-tracked:** `feedback/*.md` stubs (auto-drafted per spec 12 FR-4) and
`feedback/README.md` — these are real files in the repo, not bus artifacts.

**Implication for "what would a MySQL mirror need to capture to reproduce today's panels for PAST
runs":** only the SPEEDWARS tab is answerable for a past run today, because only its backing file
(`docs/ops/speedwars.jsonl`) survives a busdir cycle. The BOARD/FIREHOSE/AGENTS-grid panels are
inherently live-bus views — reproducing them for a past run would additionally require archiving
the raw `run-*.jsonl` transcripts and the `done/`/`limits/` marker tree at run-close time, which no
current code path does. A mirror that only ports `speedwars.jsonl` reproduces the SPEEDWARS tab for
history; it does not and cannot reproduce a past AGENTS/FIREHOSE session unless raw-log archival is
built as a companion feature.

### `swarm-mon.sh` (tmux fallback)

Four panes on an isolated `tmux -L swarm` socket (`swarm-mon.sh:1-241`): BOARD (`_board`,
`swarm-mon.sh:58-108` — counts + stale leases + `limits/*.limited/.parked/.dead/.broken`, same
ephemeral bus reads as `/api/bus`), FIREHOSE (`_firehose`, `swarm-mon.sh:112-138` — `tail -F
run-*.jsonl | jq`), COST (`_cost_summary`, `swarm-mon.sh:146-171` — a **second, independently
maintained** implementation of the same lane-bucketing heuristic as `server.mjs`'s `costSummary`;
the two are deliberately kept byte-for-byte aligned per `server.mjs:298-301`'s comment, but they are
two codebases, not one shared module), CONTROL (a raw shell with `src/swarm-ctl` on `PATH`). It
holds zero state of its own — every render is a fresh read of the same bus tree the web cockpit
reads.

**Implication:** `swarm-mon.sh` is not a second source of truth to reconcile — it's a second
renderer over the identical read surface. Any MySQL-backed reporting layer only needs to intercept
the write side (`speed_row`/`run_summary`/done markers), not either renderer.

---

## 2. Evidence schemas — the natural `uni_` table candidates

### `speed_row()` — one row per finalized branch (`src/swarm-lib.sh:1885-1991`)

Called from `swarm-run.sh`'s `_finalize_worker` (the sole choke point with the real lane:model and
worker rc still in scope). Fields actually emitted:

```
ts, run, id, requested, served_lane (null if outcome=="parked"), served_model,
outcome, wrc, pinned (bool), wall_secs, billing ("real"|"pool")
+ fallback_reason?   (absence-means-absent, not "")
+ verify_lane?        (bare served lane, only on "v-*" / "*-review" ids)
+ degraded?: true     (only during succession/non-fable orch seat, spec 11 FR-S4)
+ class?              (one of spec 12 FR-1's 9 values, absent on a "done" row)
+ per-lane usage bucket (varies by lane — see below)
```

Per-lane usage fields (`src/swarm-lib.sh:1936-1967`, jq branch on `$lane`): codex →
`tokens_in/out/cached/reasoning, turns`; grok → `tokens_in/out/cached/reasoning, cost_usd, turns,
stop`; gemini → `tokens_in/out/cached, duration_api_ms`; claude/glm/kimi (default branch) →
`tokens_in/out/cached, cost_usd (kimi recomputed at Moonshot list price, not Anthropic-list
total_cost_usd), turns, duration_ms, duration_api_ms, ttft_ms, is_error, api_error_status`.

**Implication:** the usage sub-object's shape genuinely varies by lane — a normalized column set
would either null out most columns per row or need a lane-conditional schema. The Brain precedent
(§4) resolves the identical problem by keeping the variable part as a single `jsonb` column
(`stage_results`) and only promoting the stable fields to real columns — worth reusing that pattern
here rather than inventing wide nullable columns.

### `run_summary()` — one row per run (`src/swarm-lib.sh:2006-2059`, spec 12 FR-3)

```json
{"type":"run-summary","ts":"…","run":"…","mode":"full|verify",
 "branches":{"<id>":{"lane":"…","outcome":"…","class":"…?"}},
 "done_n":0,"parked_n":0,"fallback_hops":0,
 "lanes_limited":[],"lanes_dead":[],
 "wall_secs":0,"cost_usd":0,"stderr_n":0}
```
`stderr_n` is a bare count — content never enters the ledger (spec 12 §Non-Goals, "no stderr
content aggregation"). `branches` = last-row-per-id (a retry's earlier failed rows don't count).

### `done/<id>` marker (`swarm-run.sh:563`)

`{"id":"<id>","code":<real wrc since spec 12 FR-2>,"lane":"<bare lane>"[,"degraded":true]}` — one
line, written once per branch.

### Failure-class vocabulary (`specs/12-failure-evidence.md` FR-1, lines 49-70)

Fixed 9-value set, each mapped to one detector: `auth-death`, `api-error`, `server-error`,
`rate-limit`, `timeout-watchdog`, `spawn-fail`, `false-done`, `no-answer`, `parked-env`. This is
already a controlled vocabulary — a natural CHECK-constraint/enum column, not free text.

### Orchestrator/human-written speedwars rows (never machine-generated — spec 12 §Non-Goals is
explicit: "No auto verdict/run-review rows — judge ≠ executor")

- `run-meta` (specs/08-speedwars.md FR-4, line 48): per-card complexity, written by the
  orchestrator at seed time — `{run, cards:{...C1-C5 rubric, est_human_min, verify_cost}, fanout?}`.
- `verdict` (FR-5, line 49): `{run,id,verified:bool,reason}`, appended when the file-gate
  contradicts a claimed outcome — append-only corrections, never edits.
- `review` (FR-6, line 50): `{run,lane,score:1-5,tags:[fixed vocab],note:≤140 chars}`.
- `run-review`: aggregate per-run review; `swarm-ctl review-stub` (spec 12 FR-5) prints a
  **stdout-only skeleton** (writes nothing) that a human fills in and pastes — so any `run-review`
  row that exists today was 100% hand-typed from that skeleton, never machine-appended. Only 1 of
  15 historical runs has one (specs/09-speedwars-panel.md line 81).

### `GET /api/speedwars` data contract (specs/09-speedwars-panel.md lines 59-68)

```json
{ "available": true, "generated_at": "...",
  "cards": [...], "verdicts": [...], "run_meta": [...], "reviews": [...], "run_reviews": [...] }
```

### Minimal `uni_` table sketch (my synthesis from the above — not an existing schema)

| Table | Grain | Source |
|---|---|---|
| `uni_run_summary` | 1 row / run | `run_summary()` row verbatim (branches as JSON) |
| `uni_branches` (aka `uni_cards`) | 1 row / finalized branch | `speed_row()` row; keep the per-lane usage bucket as one JSON column, promote `outcome`/`class`/`billing`/`wall_secs`/`cost_usd` to real columns |
| `uni_verdicts` | 1 row / gate-contradicted claim | orchestrator-written verdict rows |
| `uni_run_meta` | 1 row / card at seed time | orchestrator-written run-meta rows |
| `uni_reviews` | 1 row / lane review | human-written review rows |
| `uni_run_reviews` | 1 row / run (sparse: 1/15 today) | hand-typed from `review-stub`'s skeleton |
| `uni_feedback` | 1 row / stub | mirrors `feedback/*.md` frontmatter (source/date/run/type/severity/status) — files stay canonical, this is reporting-only |
| `uni_probes` | **no existing row backs this** | see below |

**`uni_probes` is aspirational, not a mirror of a real schema.** Spec 13's `doctor --live`
(`specs/13-lane-health.md` FR-2, lines 54-70) logs one billable probe via the existing
`ledger_row`-style LLM-run-evidence helper (`"doctor-probe (<lane>)"`, into `docs/ops/llm-runs.md`,
**not** speedwars) and writes a TTL'd `limits/<lane>.broken` marker (ephemeral bus state, FR-3,
lines 72-85) on a FAIL. There is no dedicated JSONL evidence row for probes today — a `uni_probes`
table would be new capture, not a port of something that already exists. Say so plainly rather than
inventing a row shape for it.

---

## 3. Plugin mechanics — how this machine actually wires plugins

Read-only findings from `~/.claude/settings.json` and every `~/.claude-acct/*/settings.json`
(11 accounts checked: Gmail, eletrixa, gmail, <work>, post, rob7, soulfire, plus the bare
`~/.claude` config — all carry the identical `enabledPlugins`/`extraKnownMarketplaces` block, so
plugin config is duplicated per-account, not centrally shared).

### The two settings.json keys

- `enabledPlugins`: `{"<plugin-name>@<marketplace-name>": true, ...}` — e.g.
  `"ponytail@ponytail": true`, `"grpn-eng@<work>-ai-marketplace": true`.
- `extraKnownMarketplaces`: `{"<marketplace-name>": {"source": {...}}, ...}` — three source kinds
  observed: `{"source":"github","repo":"owner/repo"}` (ponytail, caveman, cloudflare, karpathy),
  `{"source":"git","url":"https://..."}` (not in `extraKnownMarketplaces` here but present in the
  system-level `~/.claude/plugins/known_marketplaces.json` for `<work>-ai-marketplace`), and —
  load-bearing for this project — **`{"source":"directory","path":"/abs/path"}`**, observed live in
  `~/.claude-acct/rob7/settings.json`'s `"agnes"` marketplace pointing at
  `~/.agnes/marketplace`. A directory-sourced marketplace needs no GitHub repo at all.

### Physical layout (`~/.claude/plugins/`)

- `known_marketplaces.json` — the resolved registry: `{source, installLocation, lastUpdated}` per
  marketplace (this is system-managed, distinct from the user-declared `extraKnownMarketplaces`).
- `installed_plugins.json` — per-plugin install records: `{scope, installPath, version,
  installedAt, lastUpdated, gitCommitSha?}`.
- `marketplaces/<name>/` — the cloned/linked marketplace root, containing
  `.claude-plugin/marketplace.json`.
- `cache/<marketplace>/<plugin>/<version>/` — the resolved plugin content actually loaded (github-
  or git-sourced marketplaces get version-pinned cache dirs; a `directory`-sourced marketplace like
  `agnes` is read straight from its path, no cache needed).
- `data/<plugin>-<marketplace>/` — per-plugin runtime data dir (empty in the ponytail case checked).

### `marketplace.json` shape (`.claude-plugin/marketplace.json` at the marketplace root)

```json
{ "name": "...", "owner": {...},
  "plugins": [ { "name": "...", "description": "...", "source": "./" | "./plugins/<dir>",
                 "category": "...", "version"?: "..." } ] }
```
Verified on both a real single-plugin marketplace (`ponytail`, plugin `source: "./"` — plugin root
== marketplace root) and a real multi-plugin-capable one (`agnes`, plugin
`source: "./plugins/<work>-marketplace-grpn-foundryai"` — plugin root is a subdirectory).

### `plugin.json` shape (`.claude-plugin/plugin.json` at the plugin root)

```json
{ "name": "...", "version": "...", "description": "...", "author": {...}, "homepage"?: "...",
  "hooks"?: "./hooks/<file>.json" }
```
Verified on `ponytail` (`.claude-plugin/plugin.json`) and the `agnes`-hosted `grpn-foundryai`
plugin. Alongside `.claude-plugin/`, a plugin root carries `commands/` (one file per slash command
— `.toml` with `description`+`prompt` keys observed in `ponytail/commands/*.toml`, e.g.
`ponytail.toml`; unimatrix's own `.claude/commands/*.md` frontmatter+body form is the other
supported shape) and `skills/<skill-name>/` (one subdir per skill, matching this session's own
`Skill` tool listing — entries like `caveman:caveman-commit` prove the `plugin:skill` colon prefix
*is* how a real installed plugin's skills present, confirming the `TRUE /u:call` claim in the
mission brief).

### What this means for unimatrix specifically

Spec 16 (`specs/16-*.md`, shipped) already did the routing half (`./unimatrix` verb dispatch) and
explicitly deferred the plugin half: its own Non-Goals say "No true `/u:call` colon-namespaced
plugin command... both require plugin packaging, deferred to a future spec" (spec 16 lines 27-29).
The `agnes` directory-sourced marketplace is the concrete existing proof that packaging unimatrix
as `{"source":"directory","path":"<home>/code/unimatrix"}` in every account's
`extraKnownMarketplaces` — no GitHub repo required — is a mechanism already proven to work on this
exact machine.

**Implication:** the plugin config is per-account (11 files to touch, not one), and a
directory-sourced local marketplace is the lowest-friction path to real `/u:*` colon commands +
skill-everywhere without inventing new packaging or publishing anywhere.

---

## 4. fleetops

**Direct search result: nothing.** `grep -rliE "fleetops|fleet-ops|fleetview|session_marker"` across
all non-`node_modules`/non-`.git` files in `$BRAIN_ROOT` returns zero matches. A broader
`\bfleet\b` grep returns only unrelated hits (AI-fluency "fleet management" maturity-rubric prose,
narrative fixtures, migration-plan mentions of Railway/Fly "fleet" infra options) — none are a
fleetops feature, service, or table. **Fleetops does not exist in Brain today; it is aspirational,**
exactly as the mission brief allows for.

**What does exist and is the real hook shape:**

- `~/.claude/helpers/statusline-lcars.mjs` lines 106-114, 317-343: a deterministic
  `sessionEmoji(sid)` — hashes `session_id` into one of 24 emoji
  (`🦊🐙🦉🐢🐝🦈🐋🦜🐞🦕🍄🌵🍒🍋🥝🍩🎲🎯🚀🔮🧲🌋🪐🛸`) and renders it in place of a "SESSION" label on
  status-line 1. This is the literal "session marker" the mission brief says fleetops mirrors — it
  is a pure client-side visual, not a piece of persisted evidence today. There's no code anywhere
  (statusline or Brain) that writes this emoji, or the session id it's derived from, to any store.
- The nearest **real, shipped, structurally analogous** precedent inside Brain is
  `packages/db/src/schema/ops/cockpit-run-telemetry.ts` (Postgres `ops.cockpit_run_telemetry`,
  plan 057 "Bet Portfolio Cockpit" — an unrelated work-side product that happens to share the word
  "cockpit"): one row per pipeline run, `runId uuid PK`, `kind` (daily|weekly-rescore|manual,
  CHECK-enforced), `startedAt/finishedAt`, `success bool`, **`stageResults jsonb`** (untyped variant
  detail, exactly the pattern §2 recommends for `speed_row`'s per-lane usage bucket), plus
  `betsCount/rowsWritten/llmTokensIn/llmTokensOut/llmCostUsd/error` and a `_loadId/_source/_loadedAt`
  DWH trio. It is deliberately **excluded from `authenticated`/RLS grants** — "owner-pool-only,
  fail-closed RLS... brain-api's DB pool is the sole reader/writer" (file header, lines 18-26) —
  read only through an HTTP API, never a direct client query. That access posture is the right
  precedent for a unimatrix mirror too: single-operator tool, no reason to expose a browser-facing
  RLS surface.
- `plans/052-cli-audit-trail/` is Brain's own (separate, Postgres-backed, `ops.request_audit_log`)
  CLI-invocation audit trail — same genre of problem (who ran what, when, from a CLI) as a
  "fleetops" idea, but scoped to Brain's own `brain` CLI, not to unimatrix or any other repo's
  agent sessions. No cross-repo or cross-tool aggregation layer exists anywhere in the monorepo.

**Implication:** there is no fleetops schema, service, or table to "join" today — a unimatrix→Brain
reporting connection would be inventing the join key (most plausibly a `run_id`/`session_id`
correlation column) from scratch, not wiring into existing infrastructure. The `ops.*`
owner-pool-only/HTTP-API-only access pattern is worth copying if this ever lands inside Brain's own
Postgres; it does not, by itself, argue for MySQL (see §5).

---

## 5. MySQL availability

**No MySQL instance exists anywhere in Robert's documented stack.** `grep -inE "mysql"` over
`~/s/.env.master.md` (377 lines, the full credential index) returns zero matches — every
database-shaped entry in that file is Supabase/Postgres (`SUPABASE_URL_*`, `DATABASE_URL_*_POOLER`,
`DATABASE_URL_*_DIRECT`, across STAGE/PROD/ATODA/VEJCE projects). Brain's own DB layer
(`$BRAIN_ROOT/packages/db/drizzle.config.ts`) is explicit:
`dialect: "postgresql"`, 6 named Postgres schemas (`public, bronze, silver, gold, vec, graph,
ingest_raw`), `DATABASE_URL` sourced from a Supabase env file. Brain's `package.json` depends on
the `postgres` npm driver, not `mysql2`. **The entire observed stack — Soulfire, ATODA, Vejce, and
Brain (the work monorepo) — is Postgres/Supabase; there is no MySQL anywhere to mirror into.**

**Implication:** the vision brief's "MySQL, tables prefixed `uni_`/`unimatrix_`" would be net-new
infrastructure in a literal sense (a new engine family, not just a new schema) — every existing
precedent on this machine, including the one directly-comparable Brain table found in §4, is
Postgres. If durable cross-run reporting is the actual goal rather than MySQL specifically,
Postgres/Supabase (matching Brain and every other project) or a zero-infra embedded engine are both
lower-friction than standing up the first MySQL server in this whole environment.

**SQLite/DuckDB as the zero-infra alternative:** both ship as a single file with no server process,
no daemon, no new "ask first" infra item, and no auth surface to reason about — a genuine fit for
"single operator, MySQL optional, cockpit must keep working with zero deps when it's absent." SQLite
is the safer default for this shape of data (small write volume, one writer — the `swarm-run.sh`
process — many readers, exactly SQLite's sweet spot, and `node:sqlite`/`bun:sqlite` avoid adding a
dependency at all); DuckDB would only earn its keep if the reporting side needed real OLAP-style
ad-hoc analytical queries across many runs (window functions, columnar scans) that outgrow what
`jq`-over-JSONL or SQLite already does adequately at today's data volumes (169 card rows across 15
runs, per specs/09) — at this scale that overhead isn't justified yet, but it's the natural upgrade
path if the ledger grows two or three orders of magnitude.

---

## Files read (evidence index)

- `site/server.mjs` (full, 1760 lines)
- `site/cockpit/data.js` (lines 1-120; store/ui shape)
- `swarm-mon.sh` (full, 241 lines)
- `src/swarm-lib.sh` (lines 1840-2059; `_speedwars_file`, `speed_row`, `run_summary`)
- `swarm-run.sh:563` (done marker write)
- `specs/12-failure-evidence.md` (full)
- `specs/08-speedwars.md` (lines 40-84)
- `specs/09-speedwars-panel.md` (lines 1-90)
- `specs/16-*.md` (full — umbrella CLI, plugin packaging explicitly deferred)
- `.gitignore` (lines 6, 18-29)
- `feedback/2026-07-25-unimatrix-cockpit057b-auto-parked.md`
- `docs/ops/llm-runs.example.md`
- `swarm.conf.example:29` (`FEEDBACK_AUTO`)
- `~/.claude/settings.json`, all 11 `~/.claude-acct/*/settings.json` (`enabledPlugins`,
  `extraKnownMarketplaces`)
- `~/.claude/plugins/{known_marketplaces.json,installed_plugins.json}`
- `~/.claude/plugins/marketplaces/ponytail/.claude-plugin/{marketplace.json,plugin.json}`,
  `commands/ponytail.toml`
- `~/.agnes/marketplace/.claude-plugin/marketplace.json` +
  `plugins/<work>-marketplace-grpn-foundryai/.claude-plugin/plugin.json` (directory-sourced
  marketplace, live proof)
- `~/.claude/plugins/marketplaces/<work>-ai-marketplace/` (repo-hosted eng plugin, for contrast)
- `$BRAIN_ROOT` — full-repo `fleetops`/`fleet`/`session_marker` grep; read
  `packages/db/drizzle.config.ts`, `packages/db/src/schema/ops/cockpit-run-telemetry.ts`,
  `apps/brain-api/src/cockpit/contract.ts` (lines 1-40), `plans/052-cli-audit-trail/README.md`
- `~/.claude/helpers/statusline-lcars.mjs` (lines 100-120, 315-345 — `sessionEmoji`)
- `~/s/.env.master.md` (full-file grep for `mysql`/db-shaped keys)
