# Rules distilled for plan 004 (mirror / cockpit / plugin decision)

Vault root: `/mnt/f/OH/Notes/Global Code Settings/Coding Rules/`. Read: `_index.md`, `crossroads.md`,
`architecture/*`, `clean-code/{design-twice,deep-modules,general-purpose,obvious-design}.md`,
`testing/trophy-model.md`, `tools/plans.md`, plus repo-local `rules/unimatrix/*` and
`rules/file-headers.md`.

## Postgres-first — NOT a vault rule

- **No file in the vault states a Postgres-first or Postgres-default policy.**
  `grep -rn -i "postgres.first\|postgres-first\|default.*database"` over the whole vault returned
  nothing. The vault's `database/` category (2 files: `rls-security.md`, `supabase-types.md`) is
  scoped `applies-to: [Supabase/PostgreSQL work]` — i.e. it governs *how* to use Postgres/Supabase
  once chosen, it does not mandate choosing it. **ASSUMPTION** (from the calling agent's framing,
  not the vault): "Postgres-first" is an operator preference derived from the rest of the stack
  (Brain, the work monorepo) being Postgres, not a written rule that binds unimatrix.
- No MySQL rule exists anywhere in the vault (`database/`, `database-dwh/` are Postgres/Supabase and
  Kimball-DWH scoped respectively) — nothing to cite for or against MySQL; it would be a bare new
  dependency with zero precedent in this environment.

## Repo-local: this project is already a "no DB, no daemon" system by design

- `CLAUDE.md` (repo root, "Tech Stack" table): Bus = "JSONL file-bus on a local POSIX fs (`.bus/`)
  — no DB, no daemon, no MCP." This is the project's own architecture declaration, not a vault rule
  — but it is binding on this decision because CLAUDE.md instructions override defaults.
- `rules/unimatrix/bus-discipline.md:1-4`: "The `.bus/` file-bus is the entire coordination
  layer — no DB, no MCP, no daemon. These rules are load-bearing; violating any one silently
  corrupts the bus, usually without an error to notice." → any evidence-mirror design that requires
  a live daemon writing into `.bus/`, or a second process racing bus writers, violates this
  directly. A pure post-hoc JSONL→SQL *importer* that only reads `.bus`/archived JSONL and never
  writes into `.bus/run-*.jsonl` does not violate it.
- `CLAUDE.md` "Boundaries → Ask first": "Adding a new external dependency (CLI, npm/brew package)."
  and "Adding a standing daemon." Both require maintainer sign-off *before* building — this directly
  gates axis (A) database choice (any of sqlite/Postgres/MySQL is a new dependency to ask about) and
  axis (B)/(C) any daemon-shaped cockpit change.
- `CLAUDE.md` "Boundaries → Never": "Point `.bus` at a 9p/drvfs/NFS mount" — same constraint
  `bus-discipline.md` states; relevant if a fleet-view cockpit is tempted to watch bus dirs over a
  network/Windows-drive mount.
- `site/server.mjs:1-9` (file header, Deps line): "node:http, node:fs, node:path, node:url,
  node:child_process (execFile), node:os (tmpdir) — stdlib only, zero npm deps, no build." No
  `package.json` exists under `site/` (`find`/`grep` for one turned up nothing) — the zero-dep
  cockpit server is a **fact**, not aspiration, today. Any fleet-view/history feature must preserve
  this or it breaks the "zero-dependency offline path" requirement stated in the task.

## design-twice.md — applies to this decision

- `clean-code/design-twice.md`: "Before implementing a major feature, consider at least 2-3
  radically different approaches... pick the simplest that meets requirements" — mandates the
  decision matrix already being built (mirror axis needs ≥3 genuinely different candidates: no-DB,
  sqlite, Postgres — not 3 flavors of the same idea). "Don't design twice for... well-established
  patterns" does not apply here — this is exactly a "new services/data models" case the rule calls
  out as requiring it.
- Same file's "Mistake 1: Variations, Not Alternatives" — a caution against listing "sqlite" and
  "Postgres" and "MySQL" as if they were 3 different approaches when they're the same shape (one
  relational DB); the genuinely different axis is DB vs. no-DB vs. compressed-archive+ad-hoc-query.

## obvious-design.md / deep-modules.md / general-purpose.md — general pressure toward the plain answer

- `clean-code/obvious-design.md` "Change Amplification" / "Cognitive Load" symptoms: an importer +
  schema + migration + a second runtime to keep alive is more surface than a JSONL archive a human
  can `jq` — pushes toward the no-DB or embedded-file-DB end of the spectrum unless the fleet-view
  query need genuinely can't be met by files.
- `clean-code/deep-modules.md`: "simple interface, rich functionality" — favors one narrow
  importer script (JSONL in, droppable/rebuildable SQL out) over a bespoke sync layer with its own
  API surface; matches the task's own constraint ("importer must be a pure JSONL->SQL projection,
  droppable+rebuildable, engine scripts never touch the DB").
- `clean-code/general-purpose.md`: caution against a special-purpose one-off schema per report; if a
  DB is added at all, the projection should be general enough to answer future questions, not one
  table per today's report.

## testing/trophy-model.md

- Scoped `applies-to: [typescript, javascript]` — this repo is bash/Node-stdlib, not a TS/JS app
  framework, so the rule's specific guidance (mock at boundaries, integration > unit ratio) applies
  loosely at best. Repo's own test tool is bats-core (`CLAUDE.md` Tech Stack: `Tests | bats-core
  1.13.x`), already following the rule's spirit: `tests/cockpit-api.bats` exercises `site/server.mjs`
  behaviorally (HTTP in, JSON out) rather than unit-testing internals — any new mirror/cockpit code
  should get an equivalent bats integration test, not a unit-test suite.
- Trophy model's "mock at boundaries, not internal code" → an importer's test seam should mock the
  filesystem (temp `.bus` dir + fixture JSONL) and, if a DB is added, the DB connection — never mock
  the JSONL parser itself.

## tools/plans.md — exact frontmatter contract for this plan folder

- Folder form: `plans/NNN-<kebab-topic>(-vN)?` — this plan is already correctly `004-plugin-cli-
  cockpit-fleetops` (`tools/plans.md:29-33`).
- **Frontmatter — exactly 5 required fields, 2 optional, no more** (`tools/plans.md:171-181`):
  `plan` (must equal folder name exactly), `status: draft|active|superseded|archived`, `owner`
  (single human, not "team"), `created: YYYY-MM-DD`, `type: feature|research|rule|cleanup|
  investigation|other`; optional `supersedes` / `superseded_by`.
- Multi-doc shape required here (≥2 docs already exist): `README.md` mandatory,
  `00-SYNTHESIS.md` OR `00-INDEX.md` (not both) as anchor, `evidence/` subfolder is an explicitly
  sanctioned name for spike data (`tools/plans.md:120-124`) — this file's path is correctly placed.
- "What never lives in plans/": no runnable code with its own dependency manager, no compiled
  artifacts (`*.duckdb`, `*.sqlite` explicitly named, `tools/plans.md:169`) — so if a sqlite/DuckDB
  prototype is spiked for this decision, the actual `.sqlite`/`.duckdb` file must NOT be committed
  under `plans/004-.../evidence/`; keep only the importer script and a sample query output.
- Lifecycle: number and topic are frozen once `status: active`; this folder should stay `draft`
  until the decision matrix concludes.

## Net constraints on the three axes

- **(A) Evidence mirror**: no vault mandate for Postgres; repo's own rules mandate no-daemon,
  no-DB-by-default, ask-first before adding any DB/daemon. A pure droppable/rebuildable JSONL→SQL
  importer that never runs as a daemon and that engine scripts never touch is the only DB option
  compatible with `bus-discipline.md` and `CLAUDE.md` boundaries without a sign-off detour; "no
  database" (compressed JSONL + static HTML + optional ad-hoc DuckDB) needs no sign-off at all and
  satisfies obvious-design's anti-complexity pressure most directly.
- **(B) Cockpit topology**: zero-dep stdlib-only server is a committed fact (`site/server.mjs`
  header + absent `package.json`) — a fleet/history view must extend it without adding an npm dep or
  a daemon, or it needs explicit maintainer ask-first per `CLAUDE.md`.
- **(C) Plugin packaging**: no vault or repo rule found bearing directly on Claude Code plugin/
  marketplace packaging specifically — outside the read scope's coverage; not addressed by these
  rules (say so rather than guess).
