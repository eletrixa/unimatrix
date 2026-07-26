# Experience reports — evidence for plan 004 decision axes

Real-world reports (blogs, HN, GitHub issues, official docs) for the five research areas. Facts
are cited inline; unsourced judgment is marked ASSUMPTION. Both classic- and agentic-era sources
included where they exist.

## 1. SQLite as a local observability/history store — patterns and regrets

- **Multi-writer SQLite on a shared volume loses rows, even in WAL mode.** A Rails/Kamal shop
  running four SQLite DBs on one Docker volume lost two Stripe-paid orders when 11 rapid deploys
  left three containers holding the same WAL file open at once; `sqlite_sequence` proved rows were
  assigned IDs and then vanished. Fix was procedural (stop overlapping writers), not a SQLite
  patch. https://ultrathink.art/blog/sqlite-in-production-lessons — directly validates unimatrix's
  own rule (one importer, engine scripts never touch the DB): single-writer discipline is exactly
  the mitigation this report arrived at the hard way.
- **WAL-across-containers is fs-dependent, not container-boundary-dependent.** HN consensus: WAL's
  wal-index is an mmapped file, so it works across containers sharing a proper local fs, but breaks
  on NFS/broken-lock filesystems (SQLite docs cited directly). https://news.ycombinator.com/item?id=47637353,
  https://sqlite.org/howtocorrupt.html#_filesystems_with_broken_or_missing_lock_implementations —
  validates unimatrix's existing hard rule against 9p/drvfs/NFS for `.bus`, and by extension any
  SQLite file.
- **`cp` on a live SQLite file risks a corrupt copy**; use `.backup`/`vacuum into`/`sqlite3_rsync`.
  A SQLite core dev confirmed this on the same thread and the article was corrected mid-discussion.
  https://news.ycombinator.com/item?id=47641494, https://sqlite.org/rsync.html — any SQLite
  evidence mirror needs real backup tooling, not a bare `cp`.
- **"We lack tools to access/maintain SQLite databases" is a named recurring friction** — no
  DataGrip-style remote browsing; Simon Willison's Datasette (`uvx datasette data.db`) is the
  community's answer. https://news.ycombinator.com/item?id=47680941, https://datasette.io/ — a
  SQLite mirror needs an explicit "how do I look at it" story or it goes unread.
- **`node:sqlite` is genuinely new**: builtin since Node 22, experimental through v22–23, stable in
  Node 24+. https://nodejs.org/api/sqlite.html, https://kloubot.com/blog/nodejs-24-sqlite-esm-production-ready
  — usable with zero new dependency in `site/server.mjs`, but only on a Node pin ≥24.
- **A shipped CLI already does "JSONL/CSV history → SQLite, rebuild-safe, idempotent"**:
  `simonw/git-history` projects every version of a git-tracked JSON/CSV file into SQLite,
  de-duplicating by an `--id` key and skipping already-processed commits (a git-hash watermark).
  https://github.com/simonw/git-history — closest existing precedent to the exact importer shape
  axis (A) asks for; its `item`/`item_version`/`item_changed` schema is worth reading before
  designing unimatrix's own.

## 2. "Postgres for everything" — single-operator experience vs. ops cost

- **Advocacy case from a credentialed author**: "Just use Postgres for everything" (40-year CTO
  consultant) argues Postgres replaces Redis/Kafka/Mongo/Elasticsearch up to millions of users,
  citing Instagram. https://www.amazingcto.com/postgres-for-everything/ — a consulting sales page,
  not an incident report; treat as argument, not measured experience.
- **First-person single-operator SaaS on one Postgres instance** (UserJot): job queue via
  `SKIP LOCKED`, KV via JSONB, search via `tsvector`, real-time via `LISTEN`/`NOTIFY` — "fewer
  moving parts to debug." https://dev.to/shayy/postgres-is-too-good-and-why-thats-actually-a-problem-4imc
  — closest thing found to a genuine solo-operator report rather than a vendor pitch.
  ASSUMPTION: single anecdote at modest scale, not validated at unimatrix's run-evidence volume.
- **Local Postgres is treated as functionally free even by SQLite-thread critics**: "Spinning up
  Postgresql is easy once you know how… a PG Docker container is basically magic."
  https://news.ycombinator.com/item?id=47637353 (talkingtab/kaibee/crazygringo) — the standard
  "Postgres = ops burden" objection is mostly about *managed/networked* Postgres, and may not
  transfer to unimatrix's single-operator/local-fs case.
- **Counter-signal, same thread**: "the cost of running pgsql in some cloud dwarfs the cost of lost
  orders… Just setup postgresql" (https://news.ycombinator.com/item?id=47691695) — even in a
  SQLite-friendly comment section, durability-sensitive data (money, audit trails) pulls people
  toward Postgres, relevant to a run-evidence ledger specifically.
- No negative "Postgres for everything, regretted it" incident report at single-operator scale was
  found — only advocacy pieces and Postgres-vs-SQLite threads turned up. ASSUMPTION: the realistic
  failure mode here is administrative friction (backup discipline, a daemon to keep alive), not a
  documented incident — this axis is evidence-thin next to axis 1.

## 3. JSONL/event-log → SQL projection pipelines — rebuild-from-log discipline

- **Canonical rebuild strategies**: truncate-and-replay (drop the projection, replay the whole
  log, accept downtime) vs. blue-green (build the new projection elsewhere, catch up, cut over) —
  both require idempotent projection logic. https://event-driven.io/en/projections_and_read_models_in_event_driven_architecture/,
  https://www.architecture-weekly.com/p/rebuilding-event-driven-read-models (Oskar Dudycz) — the
  textbook shape axis (A)'s "droppable+rebuildable" requirement maps onto directly.
- **A real CLI embodies this at small scale**: `git-history` uses each git commit as a watermark
  (skips already-imported commits), de-dupes by content hash, and supports correction folding via
  `--skip <hash>` / `--start-after <hash>` for corrupted source commits — a human escape hatch, not
  just a replay button. https://github.com/simonw/git-history — strong precedent that watermark +
  correction-folding are solved problems at exactly unimatrix's operating scale.
- **NDJSON → SQL is well-worn, but destination-engine storage stability matters**: DuckDB infers a
  schema straight from NDJSON with zero setup, but "storage is not stable — newer DuckDB versions
  cannot read old database files," so the author's own rule is "only use DuckDB for computation,
  reload from JSON for long-term storage." https://tersesystems.com/blog/2023/03/04/ad-hoc-structured-log-analysis-with-sqlite-and-duckdb/
  — if DuckDB is the projection target, "rebuild from the JSONL archive" is mandatory, not a safety
  net, because the `.duckdb` file itself isn't durable across engine upgrades (SQLite's format is).
- ASSUMPTION: no source documents "what actually breaks" in homegrown JSONL→SQL rebuild pipelines
  beyond the generic idempotency/watermark advice above — public failure-mode writeups are at
  Kafka/CDC scale (exactly-once semantics, dead-letter queues), not this single-file scale.

## 4. Claude Code plugin/marketplace ecosystem (2025–2026)

- **Version resolution and path rules are documented and load-bearing**: version resolves
  `plugin.json.version` → marketplace-entry `version` → git commit SHA; omitting `version` on a
  git source makes every commit a new version (simplest for an actively-developed internal plugin
  — a stale hardcoded version string silently freezes the cache). `${CLAUDE_PLUGIN_ROOT}` is
  required in hooks/MCP configs since plugins run from a version-scoped cache copy, not in place;
  `${CLAUDE_PLUGIN_DATA}` is for state that must survive an upgrade.
  https://code.claude.com/docs/en/plugin-marketplaces — directly answers axis (C): local
  directory-sourced marketplaces (`/plugin marketplace add ./my-marketplace`) are the officially
  documented way to test before distributing, matching unimatrix's proven pattern.
- **Relative-path plugin sources only work when the marketplace itself is a git/local-directory
  source, not a bare `marketplace.json` URL** (a URL source downloads only that file). Same docs
  page, "Plugins with relative paths fail in URL-based marketplaces" — confirms the directory-
  sourced local marketplace is the *correct* choice here, not just the convenient one.
- **Update skew is a real, currently open bug class**: after `/plugin` auto-upgrades, the UI can
  keep reporting `skills path not found` against the *previous* version's now-incomplete cache dir
  even though `installed_plugins.json`/marketplace manifest/live MCP are already on the new
  version — the stale path lives in session memory, so `/reload-plugins` doesn't clear it; only a
  full restart plus manually deleting the old cache dir does.
  https://github.com/anthropics/claude-code/issues/59206 (filed against 2.1.141) — expect a
  stale-path false error immediately after any version bump; worth a one-line documented fix.
- **No native "check for plugin updates" command exists**; a user built the missing piece as a
  SessionStart hook + skill (diff `gitCommitSha` vs. remote HEAD, ≤once/day, then a confirm-and-pull
  `/upgrade-plugins`) and argued it belongs in the CLI itself.
  https://github.com/anthropics/claude-code/issues/31462 — no first-party update-notification
  primitive to lean on yet; plan for a bespoke hook of this shape if one is needed.
- **Monorepo-friendly distribution is designed in**: `git-subdir` sources sparse-clone one
  subdirectory of a larger repo, so a plugin doesn't need its own repository. Same docs page, "Git
  subdirectories" — unimatrix's commands/skill could ship from a subdirectory of the main repo
  instead of a dedicated plugin repo, if preferred over the calldev worktree split.

## 5. Static-HTML-export dashboards for single operators — do they actually get used?

- **Vendor framing is consistent but generic and self-interested**: static exports are "good for
  archival/sharing/offline analysis," live dashboards for "active monitoring."
  https://mapline.com/static-vs-dynamic-dashboards-whats-best-for-your-business/,
  https://coefficient.io/use-cases/static-dashboards-visibility-rules-limitations — take as prior,
  not evidence; no independent (non-vendor) usage study was found. ASSUMPTION beyond this point.
- **In practice, teams keep both, split by purpose, not one instead of the other**: Playwright/
  pytest test reports ship as one self-contained static HTML file (assets inlined) for archiving/
  emailing *a specific run*, while CI systems separately keep a live aggregate dashboard across
  runs. https://dev.to/rodrigoodhin/playwright-html-report-49o1,
  https://testomat.io/blog/playwright-reporting-generation/ — suggests the real answer for
  unimatrix's cockpit is "static per-run export alongside the live multi-bus cockpit," not a static
  replacement for it.
- **"Static site hosting a live-queryable SQLite database" is a proven, adopted pattern**: WASM SQL
  engines (sql.js) let a plain static host (GitHub Pages) serve an actual queryable database with
  no backend server. https://phiresky.github.io/blog/2021/hosting-sqlite-databases-on-github-pages/,
  referenced from a live Datasette feature request for exactly this
  (https://github.com/simonw/datasette/issues/1662) — the strongest concrete precedent for axis
  (B)'s "no database" candidate: a genuine zero-dependency way to ship *queryable* run history as
  static files, not just a flat report.
- ASSUMPTION: no source directly measures whether a single operator, given both a static export and
  a live dashboard, actually re-opens the static one later ("do they get used" as asked) — evidence
  supports that people build and keep using static-export tooling for per-run/archival purposes,
  not a return-visit comparison.
