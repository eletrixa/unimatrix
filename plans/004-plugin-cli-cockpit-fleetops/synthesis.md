# Synthesis — plugin + unified CLI + online cockpit + fleetops

**Author:** Fable (orchestrator synthesis over brainstorm.md / discovery.md / pre-mortem.md, 2026-07-25)
**Feeds:** PRD.md (this folder), oh-architecture dossier, site-architecture, presentation site.

---

## Verdict in five lines

1. **Plugin: build it now.** In-repo `.claude-plugin/` + self-marketplace, directory-sourced
   (the `agnes` marketplace on this machine proves the mechanism). Commands + skill ship in the
   plugin; the engine stays a single checkout behind `$UNIMATRIX_HOME`. True `/u:*` everywhere.
2. **CLI: keep and finish.** `unimatrix install | here | cockpit | report | doctor --plugin` —
   the router exists; these verbs make it an installed tool instead of a checkout habit.
3. **Reporting: JSONL stays the record; SQL is a droppable projection.** Importer = pure function
   (JSONL → SQL text), on-close synchronous call, no daemon, ≤3 tables, `uni_` prefix kept.
4. **Engine choice needs Robert's call** — the brief said MySQL; discovery found **zero MySQL
   anywhere in the stack** (everything incl. Brain is Postgres/Supabase; `node:sqlite` is the
   zero-infra local option). Recommendation below.
5. **Fleetops: emit, don't integrate.** `grep -ri fleetops "$BRAIN_ROOT"` = 0 hits today. We
   stamp the join keys and publish one documented artifact; consumer code lives in Brain, later.

## The three decisions that are Robert's (everything else is settled by evidence)

**D1 — SQL engine.** Options: (a) **MySQL** as asked — first MySQL server in the entire
environment, new engine family, new backup story; (b) **Postgres/Supabase** — matches Brain
(`ops.cockpit_run_telemetry` precedent: stable columns + jsonb payload, owner-pool-only access)
and every other project; the eventual Brain join becomes same-engine; (c) **SQLite-first**
(`node:sqlite`, Node ≥22 built-in) for local history at zero infra, with Postgres added only for
the Brain join when fleetops exists. **Recommendation: (c) now, (b) when fleetops materializes;
(a) only if there is a MySQL constraint we don't know about.** The schema is engine-portable
either way (`uni_` prefix, 3 tables, JSON payload column) — deciding late is cheap.

**D2 — the phase-2 gate.** Pre-mortem's top risk (very-high likelihood): nobody reads pull
dashboards. Its gate: ship a 3-line push summary at run close first ($/verified-done, p95 wall,
false-done rate per lane); build the reporting pages only after that summary has changed ≥2 real
decisions. **Recommendation: honor the gate** — phases 0-2 are useful even if everything stops
there. Robert may overrule and order phases 3-4 immediately; the build order still works.

**D3 — marketplace source.** Directory-sourced from the local checkout (instant iteration,
single-operator) vs GitHub-sourced (versioned, reproducible, works on a fresh box).
**Recommendation: directory now, GitHub at the first release after the plugin stabilizes.**

## What we explicitly do NOT build (pre-mortem-driven)

- No standing sync daemon (`uni-sink`) — on-close synchronous import + `mirror --since` catch-up.
- No DB writes in `site/server.mjs` — server keeps SELECT-only credentials; importer is CLI-only.
- No fleetops integration code, no files named `fleetops` — join keys + documented artifact only.
- No statusline changes — the session marker is a frozen external interface (chmod 444, locked).
- No DB in the engine's execution path — enforced by a `check.sh` grep over the four engine
  scripts, phase 0.
- No prompt/task text in any table — spec 08's strongest privacy rule, asserted by test.
- No `0.0.0.0` bind, no tunnel — remote viewing = `unimatrix report --html` static export.

## Phase plan (each gated by pre-mortem tripwires; 0-2 need zero new infra)

**Phase 0 — hygiene (bugs that exist today).** `_run_label()` unifies the run key
(swarm-lib.sh:1972/:2010 vs :2081 disagree NOW); symlink the 7 account skill copies to one inode;
kill hardcoded `~/code/unimatrix` paths (SKILL.md:12) via `$UNIMATRIX_HOME` resolution order;
run banner + `/health` emit `{root, branch, head, busdir}`; check.sh gains the engine-DB-grep and
path-ban greps. *Worth shipping even if everything else is cancelled.*

**Phase 1 — plugin + CLI finish.** `.claude-plugin/{plugin.json,marketplace.json}`; plugin
`commands/` **generated** from `.claude/commands/u-*.md` by a build script (one body, generated
pointers — never hand-copied); skill moves into the plugin; `unimatrix install` (PATH symlink +
`~/.config/unimatrix/config` + marketplace add across all `~/.claude-acct/*`, idempotent);
`unimatrix here` (fleet.json registry entry + .bus bootstrap); `doctor --plugin` (drift table:
account, hash, repo hash, verdict). Deprecate `/u-*` filename commands one release after `/u:*`.
Stamp `session_id` + statusline marker + orchestrating account into `run_summary` (cheap now,
blocked-forever later).

**Phase 2 — push summary.** 3-line lane summary appended to run close-out, derived from existing
JSONL, coverage denominators printed. **Gate:** 3 weeks + ≥2 decisions changed, written down.

**Phase 3 — mirror (if gated through or overruled).** One file (`src/uni-mirror.*` or CLI verb
`unimatrix mirror`), pure JSONL→SQL, golden-file tests (zero DB in check.sh), correction-row
folding (spec 08 FR-5/6 verdicts flip aggregates), PK `(host, busdir_realpath, run, id, ts)`,
watermark + staleness badge, work/personal DB split by `busdir_realpath` with hard refuse,
`mirror --verify` re-derive-and-diff as a hard failure, monthly drop-and-rebuild drill.

**Phase 4 — cockpit online mode.** Fleet wall (multi-bus registry view), run history browser,
cost/lane analytics, failure-taxonomy page, operator inbox — all reading the mirror through
SELECT-only credentials, every DB view carrying staleness + "derived from" footers; zero-dep
offline path asserted in bats (scrubbed env, no node_modules → `/health`,`/api/bus`,`/api/agents`
still 200). Loopback bind hard-coded.

**Phase 5 — fleetops handshake.** Starts only when `grep -ri fleetops "$BRAIN_ROOT"` > 0.
Deliverable: the documented artifact contract; consumer lives in Brain.

## Cockpit refactor shape (for oh-architecture to pressure-test)

Today: one server, one BUSDIR, pure view over live bus + one historical file; tmux fallback is a
second renderer over the same reads (not a second truth). Refactor axes: (a) **multi-bus** via
`~/.config/unimatrix/fleet.json`; (b) **history** via the mirror (SPEEDWARS tab is the only panel
reproducible for past runs today — BOARD/FIREHOSE/AGENTS need run-close raw-log archival as a
companion feature if wanted); (c) **read path split**: live panels read the bus, reporting panels
read the mirror, never crossed; (d) server stays zero-dep by default (`await import()` behind
`UNI_DB_URL`), write-free (audit.jsonl aside), loopback-only.

## Success criteria

- `/u:call` works from any repo, any account, same version everywhere (doctor proves it).
- A bulk `call` run's evidence survives busdir deletion and is queryable cross-run.
- `check.sh` wall time roughly unchanged; still zero DB, zero network.
- Phase-2 summary demonstrably changed ≥2 lane/spend decisions — or the project stopped cheaply.
- Zero unimatrix files named fleetops; Brain can build its consumer from the artifact contract alone.
