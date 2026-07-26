# 01 — Deep dive (research index)

The codebase dive and external research live in dedicated files; this is the index + the findings
that bind the decision. Full citations in the linked files.

## Codebase (internal facts)

→ [discovery.md](./discovery.md) — the complete PM-stage codebase dive (cockpit routes, evidence
schemas with file:line, plugin mechanics on this machine, fleetops absence, engine availability).

Binding facts: cockpit is a pure view over live bus + one historical file (only SPEEDWARS is
reproducible for past runs); `speed_row`/`run_summary` are the real schema (variable per-lane
usage bucket → JSON payload column, per Brain's `ops.cockpit_run_telemetry` precedent); the run
join key is inconsistent TODAY (`swarm-lib.sh:1972/:2010` vs `:2081`); directory-sourced local
marketplaces are proven live on this machine (`agnes`); **zero MySQL anywhere** in the stack;
fleetops = 0 grep hits in Brain.

## External research (evidence pack)

| File | What it establishes |
|---|---|
| [evidence/rules-distilled.md](./evidence/rules-distilled.md) | "Postgres-first" is a skill-constitution lens, **not a vault rule** (grep negative); bus-discipline + ask-first gates; design-twice demands DB vs no-DB vs archive as the real axis (not three engine flavors); plans-folder format; no `*.sqlite` artifacts under plans/ |
| [evidence/docs-research.md](./evidence/docs-research.md) | node:sqlite: builtin, flag-free ≥22.13, RC at 25.7 — **this box runs v24.18.0**; no WAL API (raw PRAGMA), `timeout` default 0ms (set busy_timeout); SQLite WAL = N readers/1 writer, banned on network fs (same class as the bus's 9p/NFS ban); psql simple-query protocol immune to Supabase pooler prepared-stmt limits, direct (non-pooled) connection is the documented lane for batch import; DuckDB single-process writer only + `read_ndjson_objects` reads compressed JSONL with zero projection; `CREATE SCHEMA uni` beats `uni_` prefix for the DROP-and-rebuild story |
| [evidence/experience-reports.md](./evidence/experience-reports.md) | Multi-writer SQLite loses rows even in WAL (ultrathink.art incident → single-writer discipline is load-bearing); bare `cp` of a live SQLite file corrupts (use `.backup`/`VACUUM INTO`/sqlite3_rsync); SQLite mirrors need an inspection story (Datasette) or go unread; simonw/git-history = shipped precedent for watermarked idempotent JSONL→SQLite import; Postgres-for-everything at single-operator scale is advocacy-rich, incident-poor (evidence-thin axis); DuckDB storage format not stable across versions (query engine, never projection target); official plugin docs: version resolution `plugin.json > marketplace entry > git SHA`, plugins execute from a **cache copy** (`${CLAUDE_PLUGIN_ROOT}`), directory marketplaces officially supported |
| [evidence/case-studies.md](./evidence/case-studies.md) | Named adopters per shape (atuin as the strongest C1 analog: CLI tool, local SQLite history, optional sync later; git-history; Litestream ops story; "just use Postgres" shops; log-as-source-of-truth practice; static-report longevity for solo operators) |

## Assumptions register (explicitly untraced claims)

- Robert's "MySQL" was shorthand for "an online SQL reporting store", not a hard engine
  constraint — inferred from zero MySQL presence anywhere; **confirmed nowhere; D1 remains his call**.
- `uni` schema-vs-prefix note in docs-research is reasoned from general namespacing docs, not a
  unimatrix-specific source (tagged in the file itself).
- Fleetops' eventual shape (Brain-side Postgres consumer) is a projection from Brain's existing
  `ops.*` patterns, not a committed design.
