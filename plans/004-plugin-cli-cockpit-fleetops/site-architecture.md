# Site architecture — cockpit IA (phase 4) + presentation site

## Part 1 — Web cockpit (localhost:4747)

Single-operator ops tool, loopback-only, no auth, hash-routed SPA views (extends today's
`VIEWS`/keys-1-5 model). Two data planes, never crossed: **live** (bus reads; always works,
zero-dep) and **history** (SQLite mirror via `sqlite3 -json` child; degrades to a visible badge).

### View hierarchy

```
Cockpit (/#)
├── FLEET (/#fleet)                       ← default when >1 registered bus; hidden when 1
│   └── [tile per live bus] → opens RUN scoped to that bus
├── RUN (/#run/<bus>/…)                   ← today's per-run cockpit, bus-scoped
│   ├── ops     (/#run/<bus>/ops)        OPS WALL          [key 1]
│   ├── grid    (/#run/<bus>/grid)       MISSION CONTROL   [key 2]
│   ├── flight  (/#run/<bus>/flight)     FLIGHTPATHS       [key 3]
│   ├── speed   (/#run/<bus>/speed)      SPEEDWARS         [key 4]
│   └── fire    (/#run/<bus>/fire)       FIREHOSE (hidden) [key 5]
├── HISTORY (/#history)                   ← mirror-backed, staleness badge
│   └── run detail (/#history/<host>/<run>)  summary · cards · verdicts · cost · archived links
├── ANALYTICS (/#analytics)               ← mirror-backed, staleness badge
│   ├── lanes    $/verified-done × lane × complexity, p95 wall, coverage denominators
│   ├── burn     cost over time, account dimension
│   └── failures failure-taxonomy: class counts, per-lane false-done rate, park reasons
└── INBOX (/#inbox)                       ← "what needs me": mixed-plane aggregator
    parked cards (live) · budget gates (live) · false-done verdicts (mirror) ·
    untriaged feedback/ files (repo) · mirror.failed markers (fs)
```

### Data source per view (the never-crossed rule, enforced by code location)

| View | Reads | Offline behavior |
|---|---|---|
| FLEET | `~/.config/unimatrix/fleet.json` + per-bus live probes | always works |
| RUN/* | selected bus dir only (today's code, bus param added) | always works |
| HISTORY, ANALYTICS | `sqlite3 -json` child over uni-*.db, SELECT only | tab renders "mirror unavailable — enable via unimatrix mirror" card; never blocks other views |
| INBOX | each item tagged with its plane; live items always, mirror items degrade | partial render + badge |

Every mirror-fed view carries: staleness badge (`now − watermark`) + footer
"derived from <file> up to <ts>" (pre-mortem #1/#3 mitigations).

### Navigation spec

- Header (left→right): wordmark · FLEET · RUN · HISTORY · ANALYTICS · INBOX(n) · status chips
  (bus fs, gate, budget, burn — today's strip) · gear. ≤6 items, no dropdowns.
- RUN keeps keyboard 1-5 verbatim (muscle memory is load-bearing); FLEET/HISTORY/ANALYTICS/INBOX
  get keys 6-9; `g` = fleet, `i` = inbox.
- Breadcrumb only inside HISTORY detail (`HISTORY > <run>`); everything else is one level.
- Deep links: every view hash-addressable (already the pattern); `/#run/<bus>/…` makes multi-bus
  bookmarkable.
- No URL changes to existing single-bus flows: with one bus registered the cockpit boots exactly
  as today (RUN view, same keys) — the refactor is additive.

### Server route additions (all GET, read-only)

| Route | Backs | Source |
|---|---|---|
| `/api/fleet` | FLEET | fleet.json + per-bus snapshot (reuses busSnapshot per registered dir) |
| `/api/history/runs?filter…` | HISTORY list | sqlite3 child |
| `/api/history/run?host=&run=` | HISTORY detail | sqlite3 child |
| `/api/analytics/<lanes|burn|failures>` | ANALYTICS | sqlite3 child (SQL lives in views, one file) |
| `/api/inbox` | INBOX | live markers + mirror verdicts + feedback/ glob |

`POST /api/ctl` unchanged (fixed argv table). Server gains zero DB code beyond the execFile
child; zero writes (audit.jsonl aside); loopback bind hard-coded.

## Part 2 — Presentation site (single Artifact page for Robert)

One self-contained page, anchor nav, mermaid inline, dark/light. Structure:

```
unimatrix — plugin · CLI · cockpit · reporting (Artifact)
├── §0 TL;DR — what ships, what's gated, what needs your call (3 status rows)
├── §1 DECISIONS D1-D3 — engine / gate / marketplace: evidence, recommendation, "overrule" cost
├── §2 Repo structure after — annotated tree (plugin dir, generated commands, mirror, archives)
├── §3 CLI — full verb tree incl. new install/here/cockpit/report/mirror/unpark + examples
├── §4 Plugin surface — every /u:* command, syntax, when-to-use, account rollout story
├── §5 Cockpit IA — Part-1 sitemap + degradation matrix + fleet-wall sketch
├── §6 Architecture — decision matrix, container diagram, risk register (from 00-SYNTHESIS)
├── §7 Phase plan — 0→5 with gates as a timeline; tripwire checklists collapsed
└── §8 Dossier index — file paths into plans/004 for the full record
```
