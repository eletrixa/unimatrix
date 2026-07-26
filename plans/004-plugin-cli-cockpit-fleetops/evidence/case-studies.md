# Case Studies — Evidence Mirror & Cockpit Storage Shapes

Research for decision axis (A) evidence mirror + axis (B) cockpit topology. Facts are cited
with URLs; anything I could not verify is labeled `ASSUMPTION`. Era tag = pre/post 2024 (this
matters because SQLite tooling maturity — `node:sqlite`, Syncthing's rewrite, WAL improvements —
is a recent (2024-2026) wave; the Postgres/log-as-db doctrine is older and more battle-tested).

## (a) SQLite as application-history / metrics store

1. **Atuin** (shell-history CLI) — era: pre-2024 core design (2021-2023), still the shipping
   shape in 2026. Local history lives in a SQLite DB at `~/.local/share/atuin/history.db`,
   written by every shell on the machine; sync is optional and end-to-end encrypted client-side,
   and the self-hosted sync server is "a small Rust binary backed by Postgres" — i.e. SQLite for
   the single-node/local case, Postgres only once you add a multi-writer server tier. Direct
   analog to unimatrix: SQLite per-bus/local, Postgres only if a shared server tier is ever added.
   Citations: https://docs.atuin.sh/main/ , https://github.com/atuinsh/atuin ,
   HN discussion (2023-05, community reaction to the SQLite move):
   https://news.ycombinator.com/item?id=35839470

2. **Litestream / Fly.io** — era: pre-2024 (published 2022-05-09), still the reference essay for
   this shape in 2026. Ben Johnson (BoltDB author) built Litestream to stream-replicate SQLite to
   S3-compatible storage for disaster recovery, then joined Fly.io to productionize it. Important
   caveat, stated directly in the piece: Litestream "won't work well on ephemeral, serverless
   platforms or when using rolling deployments," and restores "can make database restores take
   minutes to complete." This is a vision/advocacy essay, not Fly.io's own audited production
   post-mortem — treat the operational claims as directional, not measured.
   Citation: https://fly.io/blog/all-in-on-sqlite-litestream/ (2022-05-09)

3. **Syncthing 2.0** — era: post-2024 (migration testing began March 2025, 2.0 shipped August
   2025). Switched its on-disk index database from LevelDB to SQLite. Stated reason: "the
   database layer has been a source of real or potential bugs" — LevelDB lacks real transactions,
   and index maintenance had been a source of inconsistencies. Cost paid: SQLite's C toolchain
   dropped prebuilt binaries for Windows-on-ARM, NetBSD, and Solaris (cross-compilation
   complexity). This is the closest same-era precedent for "swap an ad-hoc append store for
   SQLite and eat a portability tax."
   Citations: https://github.com/syncthing/syncthing/pull/9965 ,
   https://linuxiac.com/syncthing-2-0-launches-with-major-database-overhaul/ ,
   https://forum.syncthing.net/t/syncthing-on-sqlite-help-test/23981

4. **Datasette (Simon Willison)** — era: pre-2024 origin (2017-2018), actively used through
   2026. Ships SQLite files as the unit of publication for journalism datasets — "bake it into a
   blob of a SQLite file and ship it" — specifically because serverless/static hosting can't run
   Postgres but can serve a read-only SQLite file. Bellingcat (investigative journalism) is the
   named adopter for managing small/medium newsroom datasets without standing up a database
   server. Fits the "static export + queryable" hybrid unimatrix could use for archived runs.
   Citations: https://simonwillison.net/2018/Aug/19/instantly-publish-datasette/ ,
   https://github.com/simonw/datasette , https://architecturenotes.co/p/datasette-simon-willison

## (b) Postgres-for-everything shops

5. **RudderStack** — era: spans pre- and post-2024 (six years in production as of the May 2026
   post, so roughly 2020-2026). Runs their event-streaming queue/pipeline system on Postgres
   instead of Kafka, at a reported 100,000 events/sec. What broke at scale: table bloat, query
   degradation, index bottlenecks, and "retry storms" from rapidly-expanding job-status tables;
   write amplification of ~3MB/s physical WAL writes per 1MB/s logical writes. What they changed:
   intelligent compaction logic (replacing simple percentage triggers), multi-layer caching, and
   aggressive autovacuum/WAL tuning — not a rip-and-replace, a tuning campaign.
   Citation: https://www.rudderstack.com/blog/scaling-postgres-queue/ (2026-05-26)

6. **PlanetScale for Postgres — "Traffic Control"** — era: post-2024 (2026-04-10). Documents the
   canonical failure mode of mixing a job queue and analytics workload in one Postgres instance:
   dead tuples from MVCC accumulate faster than autovacuum can reclaim them once slow analytics
   queries pin the vacuum horizon, producing a "death spiral" — one cited backlog example hit
   155,000 queued jobs with 300ms+ lock waits. `FOR UPDATE SKIP LOCKED` and batch processing
   "lifted the floor but not the ceiling"; their fix was workload isolation (throttling
   concurrent analytics), not abandoning Postgres. Direct relevance to unimatrix: the plan's own
   constraint — engine scripts never touch the DB, importer is a droppable/rebuildable projection
   — sidesteps this exact failure mode by keeping OLTP-ish writes (the JSONL bus) and analytics
   reads (the SQL projection) in physically separate stores.
   Citation: https://planetscale.com/blog/keeping-a-postgres-queue-healthy (2026-04-10)

7. **Instagram** — era: pre-2024 (the canonical "Postgres scales further than you think" citation,
   originally ~2012, still invoked in 2025-era essays). Weaker fit for this project: Instagram's
   published story is about scaling Postgres as the *primary* datastore with custom sharding, not
   about replacing queue/cache/search with it. It is cited by "Postgres for everything" advocacy
   (e.g. Stephan Schmidt's essay, updated 2025-12-13: "Instagram uses Postgres. They have more
   users than you.") as a scale existence-proof, not as a like-for-like case study — flagging this
   distinction rather than overclaiming it.
   Citation: https://www.amazingcto.com/postgres-for-everything/ (updated 2025-12-13)

## (c) Log-file-as-source-of-truth, derived stores rebuilt from the log

8. **LMAX Exchange architecture** — era: pre-2024 (2011), the founding case study for this shape
   and still cited constantly. A retail financial trading platform: every inbound event is
   appended to a durable input journal *before* processing; the single-threaded business-logic
   processor holds all state in memory; on crash, state is rebuilt by replaying the input journal
   from the last snapshot. The journal is the source of truth — in-memory state and any derived
   views are disposable/rebuildable. This is the strongest same-shape precedent for "JSONL bus is
   truth, SQL projection is a droppable cache."
   Citations: https://martinfowler.com/articles/lmax.html (via
   https://mechanical-sympathy.blogspot.com/2011/07/lmax-architecture-by-martin-fowler.html),
   Disruptor project: https://github.com/LMAX-Exchange/disruptor

9. **Jay Kreps, "The Log"** (LinkedIn Engineering) — era: pre-2024 (2013-12), the doctrinal essay
   behind Kafka and behind every "log is the database, everything else is a derived view"
   argument since. Written from direct experience running LinkedIn's Databus/Voldemort systems,
   where downstream stores were rebuilt from a change-log rather than treated as sources of
   truth. Conceptual grounding, not itself a small-scale case study — cite for the argument, not
   for adoption evidence.
   Citation: https://engineering.linkedin.com/distributed-systems/log-what-every-software-engineer-should-know-about-real-time-datas-unifying (2013-12)

10. **Nubank / Datomic** — era: pre-2024 adoption (~2014), still the flagship story through 2025
    DevBcn talks. Core banking built on Datomic, an immutable-facts (datom) database whose
    transaction log is explicitly "like a Git repository" of every fact ever asserted — current
    state and query indexes are derived/rebuildable views over that log, giving full audit/​
    time-travel for free. Reported scale: 3,000+ Datomic databases, 4,000 microservices. Caveat:
    Nubank is *not* Kafka-less — they also run ~70 billion Kafka events/day alongside Datomic —
    so cite this for "immutable log as source of truth, views derived and rebuilt," not for
    "avoided a broker entirely."
    Citations: https://www.datomic.com/nubanks-story.html ,
    https://www.cognitect.com/blog/2015/9/14/nubank ,
    https://www.devbcn.com/2025/talks/949215

11. **rqlite** (Philip O'Toole) — era: pre-2024 design (~2016), maintained through 2026.
    Replicates SQLite by treating the *stream of SQL statements* as the Raft log and SQLite
    itself as the deterministic, rebuildable materialization of that log — structurally identical
    to "JSONL bus is truth, SQLite/SQL projection is derived." `ASSUMPTION`: I could not verify
    named production adopters at a specific scale from public sources in this pass (aggregator
    sites list a handful of companies but without attributable detail) — cite for the mechanism,
    not for adoption proof.
    Citations: https://philipotoole.com/replicating-sqlite-using-raft-consensus/ ,
    https://github.com/rqlite/rqlite

## (d) Static-report tooling used long-term by solo operators

12. **GoAccess** — era: originated pre-2024 (~2010), features cited here are current through
    2026. Real-time terminal log analyzer that also emits fully self-contained static HTML
    reports ("scripts and styles all inlined... copy or share/email without any fuss") and
    supports incremental on-disk persistence — append new log data without re-parsing from
    scratch. No database server, no daemon; matches the "no-DB, compressed-archive" candidate for
    axis (A) almost exactly.
    Citations: https://goaccess.io/ , https://goaccess.io/features ,
    https://github.com/allinurl/goaccess

13. **git-quick-stats** — era: pre-2024 tool, actively maintained forks through 2026. A single
    Bash script (coreutils + `git log` + `awk`/`column`/`sort`) that produces interactive or
    piped-to-file statistics directly from git history — zero storage layer at all, the git log
    itself *is* the database, queried fresh every run. The purest "no DB, source log is enough at
    this scale" precedent among the four (d) candidates; it only works because the workload
    (one repo, one operator, infrequent queries) never needs an index.
    Citation: https://github.com/git-quick-stats/git-quick-stats

14. **Munin + RRDtool** — era: pre-2024 (Munin ~2002, RRDtool by Tobi Oetiker), still deployed by
    solo sysadmins through 2026 per current docs. Master polls nodes on a cron interval and
    stores each metric in a round-robin database — a fixed-size flat file per metric, so disk
    footprint never grows regardless of retention — then `munin-graph` renders static PNGs on the
    same cron tick. No query engine, no server process serving live queries; a plain file server
    can host the output indefinitely. Distinct mechanism from GoAccess/git-quick-stats (fixed-size
    binary time-series file vs. re-derive-from-source-on-demand) but the same operating
    posture: unattended, solo-operator, years-long uptime, no DB to administer.
    Citations: https://munin-monitoring.org/ ,
    https://guide.munin-monitoring.org/en/latest/reference/munin-graph.html

## Reading across the shapes

- **(a) and (c) point the same direction for unimatrix**: durable source-of-truth stays a
  cheap, local, append-only artifact (JSONL bus / SQLite file / Raft-replicated log); anything
  queryable is an explicitly rebuildable projection, never hand-edited. LMAX (#8) and rqlite (#11)
  are the two most structurally identical precedents found.
- **(b)'s cautionary tale (PlanetScale, #6) is exactly the failure the plan's own constraint
  avoids** — it only bites when writes-you-must-not-lose and analytics-you-can-re-run share one
  MVCC engine. Keeping the bus and the projection in separate stores/processes sidesteps it by
  construction, not by tuning discipline.
- **(d) is the fallback proof, not a strawman**: GoAccess, git-quick-stats, and Munin are all
  still-maintained, still-deployed-by-solo-operators tools in 2026 — "no database, derive from
  the log/export static HTML" is a genuine long-lived shape, not merely the option nobody picked.
