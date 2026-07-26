# Docs research: evidence mirror + cockpit topology decision axes

Scope: (A) durable cross-run reporting DB choice, (B) cockpit fleet-view topology, (C) plugin
packaging (not researched here — no external docs gap, skipped). Facts cited with source URL;
anything not directly verifiable is marked ASSUMPTION.

## 1. node:sqlite (Node built-in)

- **Stability**: Release Candidate (stability index 1.2) as of Node **v25.7.0** (2026-02-24, PR
  #61262). Still marked experimental/RC, not "Stable," in the current docs.
  https://nodejs.org/api/sqlite.html · https://nodejs.org/api/sqlite.md
- **Version gating**: Introduced behind `--experimental-sqlite` at v22.5.0. Flag requirement
  **removed** at v22.13.0 / v23.4.0 — usable without a flag on any LTS from v22.13.0 up.
  https://nodejs.org/api/sqlite.html
- **Current LTS lineup (mid-2026)**: v22 "Jod" and v24 "Krypton" are both LTS; v23 and v25 were
  Current-only and already EOL (v25 EOL 2026-03-31). v26 is the current "Current" line and also
  ships node:sqlite. https://nodejs.org/en/about/previous-releases
  → **Practical floor for this repo: Node ≥22.13.0** (matches the flag-free cutover) if pinning to
  the LTS unimatrix already targets (`docs/versions.md` — not re-verified here, check that file).
- **API surface**: `DatabaseSync` (sync-only, no async variant for the core CRUD path),
  `StatementSync`, `.exec()`, `.prepare()`, `.isTransaction`, `.isOpen`. `timeout` constructor
  option (added v24.0.0/v22.18.0) sets SQLite's `busy_timeout`; **default is 0 ms** (no wait —
  callers must set this explicitly or expect immediate `SQLITE_BUSY` under any lock contention).
  https://nodejs.org/api/sqlite.html
- **WAL mode**: no dedicated node:sqlite API/pragma wrapper is documented; it's just a raw pragma
  through `.exec('PRAGMA journal_mode=WAL')` — same as any SQLite client, no node-specific gate.
  https://nodejs.org/api/sqlite.html
- **Defensive mode**: `defensive` option (v25.1.0/v24.12.0), **on by default since v25.5.0** —
  disables SQL features that can deliberately corrupt a DB. Worth enabling explicitly if pinning
  to a version before it defaulted on. https://nodejs.org/api/sqlite.html
- **vs better-sqlite3**: better-sqlite3 is faster (native addon, more mature sync engine, no RC
  caveat); node:sqlite trades that for zero install/zero native-compile, per third-party
  benchmarks (no official Node-team comparison exists). https://sqg.dev/blog/sqlite-driver-benchmark/ ·
  https://www.pkgpulse.com/guides/better-sqlite3-vs-libsql-vs-sql-js-sqlite-nodejs-2026
  — **Zero-dep constraint**: better-sqlite3 needs `npm install` + a native build step, breaking
  unimatrix's "stdlib only, zero npm deps, no build" invariant (`site/server.mjs:6`). node:sqlite
  is the only SQLite option that preserves it.

## 2. bun:sqlite

- Built into Bun, synchronous-only API, "inspired by better-sqlite3." No minimum-Bun-version
  number is stated on the current docs page (mature/stable feature, not gated behind a flag).
  https://bun.com/docs/runtime/sqlite
- WAL is a first-class recommendation, not an afterthought: `db.run("PRAGMA journal_mode = WAL;")`
  is called out as improving "many concurrent readers and a single writer," recommended "for most
  applications." https://bun.com/docs/runtime/sqlite
- Platform quirk: on macOS the `-wal`/`-shm` sidecar files persist after `.close()` (Apple's SQLite
  build); Linux/Windows clean these up normally. Not relevant to this repo's Linux/WSL target but
  worth knowing if any contributor is on a Mac. https://bun.com/docs/runtime/sqlite
- Perf claims (3–6x better-sqlite3, 8–9x deno sqlite on reads) are Bun's own marketing copy /
  community benchmarks, not independently reproduced here — treat as directional.
  https://bun.com/reference/bun/sqlite

## 3. SQLite core semantics (applies to node:sqlite, bun:sqlite, and CLI `sqlite3` alike)

- **WAL concurrency model**: "readers do not block writers and a writer does not block readers.
  Reading and writing can proceed concurrently" — but only **one writer at a time**; a second
  writer gets `SQLITE_BUSY` (or waits, per `busy_timeout`). Readers get **snapshot isolation** of
  the DB state as of when their read transaction began. https://sqlite.org/wal.html
- **Checkpointing**: writer appends to a `-wal` file; SQLite auto-checkpoints (folds WAL back into
  the main file) at ~1000 pages (~4MB) by default; checkpoint types PASSIVE/FULL/RESTART trade off
  blocking vs thoroughness. https://sqlite.org/wal.html
- **Durability knob**: `PRAGMA synchronous` — `NORMAL` skips fsync on every writer commit (only
  checkpoints sync), `FULL` fsyncs every commit. NORMAL is the practical default for a
  single-operator batch importer where losing the last few uncommitted rows on an OS crash is
  acceptable; use FULL only if every write must survive a hard power loss.
  https://sqlite.org/wal.html
- **Network filesystem = hard ban, matches existing repo doctrine**: "All processes using a
  database must be on the same host computer; WAL does not work over a network filesystem" — the
  `-shm` file needs true shared memory, which cross-host mounts cannot provide.
  https://sqlite.org/wal.html
  Separately, SQLite's own corruption guide: "This is especially true of network filesystems and
  NFS in particular... if two or more threads or processes try to access the same database at the
  same time, then database corruption might result." https://www.sqlite.org/howtocorrupt.html
  → **This is the same constraint the repo already enforces for the bus** — `rules/unimatrix/
  bus-discipline.md:12`: "Local POSIX fs only. The bus lives under `<repo>/.bus` — never a
  9p/drvfs/NFS mount." Any SQLite file (evidence DB) must live under the same local-POSIX-fs rule,
  not on a Windows-mounted drvfs/9p path — consistent with, not an exception to, existing doctrine.
- **Locking-protocol consistency**: "It is important that all connections to the same database
  file use the same locking protocol" — mixing e.g. POSIX advisory locks and dot-file locking
  across processes touching the same file corrupts it. Relevant if any tool ever opens the
  evidence DB with a different SQLite build/VFS than the importer. https://www.sqlite.org/howtocorrupt.html

## 4. Postgres, lightweight/no-driver usage

- **psql-only, no client library**: shell scripts can run SQL with no driver dependency via
  `psql -c "<SQL>"`, `psql -f file.sql`, `echo "SQL" | psql`, or heredocs — all documented psql
  idioms, no npm/pip package required. (Practitioner Q&A / mailing list evidence, not a single
  canonical doc page.) https://www.postgresql.org/message-id/2F1DE8CC97C00645B9FEA539982DA22401900D5A%40USEA-EXCH4.na.uis.unisys.com
  — This is the only way to keep "psql client only" as a dependency-free import path; anything
  using `pg`/`postgres.js` reintroduces an npm dependency, same tradeoff as better-sqlite3 above.
- **Supabase pooler topology**: Supavisor is Supabase's own pooler (all tiers); PgBouncer is a
  paid-tier alternative. **Session mode = port 5432** (long-lived, IPv4-friendly, supports
  prepared statements). **Transaction mode = port 6543** (both Supavisor and PgBouncer), meant for
  short-lived/serverless connections. https://supabase.com/docs/guides/database/connecting-to-postgres
- **Prepared-statement trap in transaction mode**: "Transaction mode does not support prepared
  statements" — because pooled connections aren't pinned to one backend, so a statement PREPAREd
  on one physical connection may not exist on the next one handed out. Confirmed independently:
  PgBouncer 1.21+ added *some* prepared-statement support in transaction mode, and Supavisor added
  broadcast-PREPARE support, but this is a recent/partial fix, not the historical default.
  https://supabase.com/docs/guides/database/connecting-to-postgres ·
  https://www.crunchydata.com/blog/prepared-statements-in-transaction-mode-for-pgbouncer ·
  https://github.com/supabase/supabase/issues/39227
  → **Relevant to tiny batch inserts via psql**: `psql -c` issues simple-protocol queries, not
  named prepared statements, so this trap mostly doesn't bite a psql-only importer — it bites ORM/
  driver clients (asyncpg, node-postgres) that PREPARE implicitly.
- **CLI vs driver guidance from Supabase itself**: direct (non-pooled) connections are recommended
  for `psql`/`pg_dump`/migrations; pooled (Supavisor) connections are for app drivers managing many
  concurrent short connections. https://supabase.com/docs/guides/database/connecting-to-postgres
  → For an occasional single-operator batch importer, direct connection is the documented-correct
  choice, sidestepping the prepared-statement quirk entirely. ASSUMPTION: requires this operator's
  Supabase project to allow direct (non-pooled) connect from this host — not verified here.
- **Schema-prefix (`uni_`) vs dedicated schema**: multi-tenancy literature frames three tiers —
  database-per-tenant (strongest isolation, worst pooling), schema-per-tenant (`tenant_1.things`,
  still one pool), shared-schema with a table-name/column discriminator (simplest, weakest).
  https://hackernoon.com/your-guide-to-schema-based-multi-tenant-systems-and-postgresql-implementation-gm433589 ·
  https://blog.arkency.com/multitenancy-with-postgres-schemas-key-concepts-explained/
  → ASSUMPTION (inferred, not directly sourced): the same taxonomy maps to "one tool's tables in a
  shared operator DB" — `CREATE SCHEMA uni;` + unprefixed table names gets a clean
  `DROP SCHEMA uni CASCADE` rebuild story (matches the droppable+rebuildable constraint) without a
  `uni_`-prefix convention cluttering the shared `public` schema.

## 5. DuckDB over JSONL

- **`read_json_auto`**: auto-detects JSON reader config and column types; accepts a glob or a list
  of files directly in the `FROM` clause — no explicit schema needed for exploratory queries.
  https://duckdb.org/docs/lts/data/json/loading_json
- **JSONL specifically**: `read_ndjson_objects` is the alias for `read_json_objects` with
  `format='newline_delimited'` pre-set — the correct entry point for `.jsonl` files as opposed to
  single-document `.json`. https://duckdb.org/docs/lts/data/json/loading_json
- **Concurrency model**: single-writer/multiple-reader **within one process**; cross-process
  concurrent writes to the same `.duckdb` file are **not supported** in standard embedded mode
  (multi-process write requires "Quack," a beta client/server protocol as of v1.5.2 — not the
  embedded story this decision is about). https://duckdb.org/docs/current/connect/concurrency
- **Network storage caution**: DuckDB's own docs warn to "exercise extra caution when accessing a
  DuckDB database file in a shared directory... on network attached storage" — the same class of
  risk as SQLite over NFS, independently confirmed for DuckDB.
  https://duckdb.org/docs/current/connect/concurrency
- **When DuckDB beats SQLite here**: DuckDB is a columnar OLAP engine — better for ad-hoc
  aggregations/joins across many run records directly over compressed JSONL archives with **no
  import/projection step**: `SELECT * FROM read_ndjson_objects('archive/*.jsonl.gz')` works cold,
  no schema, no daemon, nothing to drop-and-rebuild. SQLite wins for a **live single-writer append
  workload** other processes must read concurrently with low latency — not DuckDB's per-query
  file-scan model. ASSUMPTION (inferred): for the "pure JSONL→SQL projection, droppable+
  rebuildable, no daemon" constraint, DuckDB-over-raw-archive is a legitimate zero-import
  alternative to "import into SQLite then query it" — worth scoring as a distinct matrix option.

## Sources (deduplicated)

- https://nodejs.org/api/sqlite.html
- https://nodejs.org/api/sqlite.md
- https://nodejs.org/en/about/previous-releases
- https://nodejs.org/en/blog/release/v25.7.0
- https://sqg.dev/blog/sqlite-driver-benchmark/
- https://www.pkgpulse.com/guides/better-sqlite3-vs-libsql-vs-sql-js-sqlite-nodejs-2026
- https://bun.com/docs/runtime/sqlite
- https://bun.com/reference/bun/sqlite
- https://sqlite.org/wal.html
- https://www.sqlite.org/howtocorrupt.html
- https://supabase.com/docs/guides/database/connecting-to-postgres
- https://www.crunchydata.com/blog/prepared-statements-in-transaction-mode-for-pgbouncer
- https://github.com/supabase/supabase/issues/39227
- https://hackernoon.com/your-guide-to-schema-based-multi-tenant-systems-and-postgresql-implementation-gm433589
- https://blog.arkency.com/multitenancy-with-postgres-schemas-key-concepts-explained/
- https://duckdb.org/docs/lts/data/json/loading_json
- https://duckdb.org/docs/current/connect/concurrency
- `rules/unimatrix/bus-discipline.md:12` (repo-internal, local-POSIX-fs-only precedent)
- `site/server.mjs:6` (repo-internal, zero-npm-dep precedent for the cockpit server)
