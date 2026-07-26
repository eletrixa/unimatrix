# UNIMATRIX — PRD: Plugin, Unified CLI, Online Cockpit, Fleetops Handshake

**Status: ACTIVE — decisions taken 2026-07-25 (Robert delegated; see 00-SYNTHESIS §Decisions):
unimatrix stays OUTSIDE the monorepo (sender/contract model, new D0); D1 = both engines,
sequenced — SQLite live now via sqlite3 CLI, psql push wired-but-dormant, contract
(`sql/uni-schema.sql` + `docs/fleetops-contract.md`) published UNGATED so Brain's fleetops builds
against it; D2 gate honored for the local reporting UI; D3 directory marketplace first. §3 below
preserved as the decision record.**
Repo: `unimatrix` · worktree `unimatrix-calldev` (branch `call-dev`) · Date: 2026-07-25
Feeds from: [synthesis](./synthesis.md) (the decided direction), [discovery](./discovery.md) (facts),
[pre-mortem](./pre-mortem.md) (tripwires — every acceptance criterion below is one), [brainstorm](./brainstorm.md).
Extends: [spec 15 — direct call](../../specs/15-direct-call.md), [spec 16 — unified CLI](../../specs/16-unified-cli.md)
(whose Non-Goals explicitly deferred the plugin half, spec 16 lines 32-33). Contradicts none of them.

**Decision in one line:** package the already-shipped commands + skill as an in-repo plugin so
`/u:*` works from any repo and any account, finish the `unimatrix` router into an installed tool,
and — only after a three-line push summary has demonstrably changed real decisions — project the
JSONL evidence into a droppable SQL mirror that the cockpit reads SELECT-only. The file-bus stays
the record; the database never enters the execution path.

---

## 1. Problem & context

**What unimatrix can do today:** run a swarm from any cwd (spec 15's `call` resolves its busdir
against the caller), route every verb through one `./unimatrix` front door (spec 16), and produce
rich per-branch evidence — `speed_row()` at `src/swarm-lib.sh:1885-1991`, `run_summary()` at
`:2006-2059`, failure classes from spec 12, lane-health markers from spec 13.

**What it cannot do, with evidence:**

- **Evidence dies with the busdir.** Everything under `.bus/` is ephemeral — including
  `audit.jsonl` and `notes-lessons.md`, which live *inside* `BUSDIR` (`site/server.mjs:46`, `:1600`)
  despite a comment that reads as durable. Only `docs/ops/speedwars.jsonl` survives a busdir cycle,
  and it is gitignored (`.gitignore:27`). `.gitignore:29` reserves `docs/ops/bus-archives/` but **no
  code writes there** — a grep across `*.sh`/`*.md`/`*.mjs` returns nothing.
- **Commands are repo-local.** The `/u-*` namespace is a filename prefix inside
  `.claude/commands/`; the skill is **copied** into 7 account dirs (`~/.claude-acct/*/skills/unimatrix/SKILL.md`
  — all one md5 *today*, kept in sync by hand). Spec 16 said so itself: no true `/u:call`, no
  cross-repo availability, "deferred to a future spec".
- **No cross-run reporting.** The cockpit is a pure view over one live bus plus one historical file;
  `swarm-mon.sh` is a second renderer over the identical reads, not a second truth. Nothing answers
  "which lane is cheapest per verified-done for C2 write cards over the last 30 days".
- **The run join key is already broken.** `speed_row`/`run_summary` label runs
  `basename(dirname busdir)` (`swarm-lib.sh:1972`, `:2010`); `feedback_stub` uses
  `basename(busdir)` (`:2081`). Three worktrees all produce `unimatrix*`-shaped parents. This is a
  bug **now**, with no database involved.
- **Absolute host paths are baked in.** `.claude/skills/unimatrix/SKILL.md:12` names a checkout path
  that a worktree promotion would silently invalidate.

**Single-operator reality.** One person, terminal-first, decisions made *during* runs. Dashboards
are a pull surface; the pre-mortem's highest-likelihood obituary (#16) is "everything worked and
nobody opened it". That shapes the whole phase order below: the cheap push surface ships before any
page or schema, and phase 2 is an honest place to cancel.

---

## 2. Goals / Non-goals

### Goals

1. **`/u:*` from any repo, any account, one version** — proven by a drift table, not by a snapshot.
2. **One body per command prompt**, everywhere else generated. Prompt text has no compiler.
3. **The engine stays one checkout** behind `$UNIMATRIX_HOME`; the plugin ships commands + skill only.
4. **Evidence outlives the busdir** and is queryable cross-run — *if and only if* phase 2 proves
   anyone acts on it.
5. **Every property that makes unimatrix cheap survives**: zero-dep cockpit boot, hermetic `check.sh`,
   no daemon, no DB in the execution path.

### Non-goals — what we do NOT build (synthesis §"What we explicitly do NOT build", pre-mortem-driven)

- **No standing sync daemon** (`uni-sink`) — on-close synchronous import + `mirror --since` catch-up.
- **No DB writes in `site/server.mjs`** — server keeps SELECT-only credentials; the importer is CLI-only.
- **No fleetops integration code, no files named `fleetops`** — join keys + a documented artifact only.
- **No statusline changes** — the session marker is a frozen external interface (chmod 444, locked).
- **No DB in the engine's execution path** — enforced by a `check.sh` grep over the four engine
  scripts, phase 0.
- **No prompt/task text in any table** — spec 08's strongest privacy rule, asserted by test.
- **No `0.0.0.0` bind, no tunnel** — remote viewing is `unimatrix report --html`, a static export.
- No new lane, no MCP, no migration tool, no npm dependency in the cockpit's default path.

---

## 3. Open decisions — **AWAITING ROBERT**

### D1 — SQL engine (blocks phase 3 only; phases 0-2 unaffected)

| Option | Evidence | Cost |
|---|---|---|
| (a) **MySQL**, as the brief asked | `grep -inE mysql` over the full credential index returns **zero**; no MySQL exists anywhere in the stack | First MySQL server in the environment: new engine family, new backup story |
| (b) **Postgres/Supabase** | Every project incl. Brain is Postgres; Brain's `ops.cockpit_run_telemetry` is the exact precedent (stable columns + `jsonb` payload, owner-pool-only, HTTP-API-only access) | A server to run and credential; earns its keep when the Brain join is real |
| (c) **SQLite-first** via `node:sqlite` | Verified working on this box: Node v24.18.0, `node:sqlite` exports `DatabaseSync`. One writer (`swarm-run.sh`), many readers — SQLite's sweet spot at today's volume (169 card rows / 15 runs) | Not the engine for a cross-repo join later |

**Recommendation: (c) now, (b) when fleetops materializes; (a) only if there is a MySQL constraint
we don't know about.** The schema is engine-portable either way (`uni_` prefix, ≤3 tables, JSON
payload) — deciding late is cheap, and phase 3 is gated behind phase 2 regardless.

### D2 — the phase-2 gate: honored or overruled?

Pre-mortem #16 (very-high likelihood, total damage) gates phases 3-5 behind: **3 weeks elapsed AND
≥2 decisions changed by the close-out summary, written down with dates.**
**Recommendation: honor it.** Phases 0-2 are worth shipping even if everything stops there, and the
gate is the only honest cancel point. Robert may overrule and order 3-4 immediately; the build order
is unchanged either way — only the go/no-go between P2 and P3 moves.

### D3 — marketplace source

Directory-sourced from the local checkout (instant iteration, single-operator; the `agnes`
marketplace on this machine is live proof that `{"source":"directory","path":"…"}` needs no GitHub
repo) vs GitHub-sourced (versioned, reproducible, works on a fresh box).
**Recommendation: directory now, GitHub at the first release after the plugin stabilizes.**

---

## 4. Users & stories

**Robert as operator (the only daily user).**
- *From any repo:* "`/u:call grok --files changed.txt --batch 25 --write .` on this checkout" — the
  command exists in the session because the plugin is installed per-account, and it dispatches into
  the one engine checkout, saying out loud which root/branch/bus it chose.
- *Across repos:* "show me the fleet wall" — one page, one row per live run across every registered
  bus, because `unimatrix here` wrote a registry entry when he bootstrapped each repo.
- *At decision time:* "which lane is cheapest for C2 write cards?" — answered by three lines printed
  at run close-out **first** (phase 2), by a page **only if** those lines earned it (phase 4).

**Robert as maintainer.**
- *Release:* bump one version, cut the changelog, run one idempotent install loop; `doctor --plugin`
  prints account / installed hash / repo hash / verdict and is green.
- *Diagnose:* a run behaved oddly → the banner names the worktree, `doctor` names the drift, and no
  hour is spent debugging a stale prompt body that presented as "the model did something dumb".

**Future Brain / fleetops as a consumer (phase 5, not before).**
- Reads **one documented artifact** with a written contract and stable join keys. No unimatrix code
  knows fleetops exists; the consumer lives in Brain, where the schema churn belongs.

---

## 5. Functional requirements by phase

Every acceptance criterion below is a pre-mortem tripwire, cited as *(#n)*. A phase does not start
until the prior phase's criteria are armed **and** passing.

### Phase 0 — hygiene (bugs that exist today; worth shipping even if everything else is cancelled)

| FR | Requirement | Acceptance criterion |
|---|---|---|
| **P0-FR1** | One `_run_label()` helper owns the run key; `swarm-lib.sh:1972`, `:2010`, `:2081` all call it. An explicit `SPEEDWARS_RUN` always wins; the default warns. | `jq -r '[.run,.id]\|@tsv' docs/ops/speedwars.jsonl \| sort \| uniq -d` is empty, or every duplicate is understood and the key extended *(#2)* |
| **P0-FR2** | The 7 account skill copies become symlinks to the canonical repo file (one inode; the accounts already symlink other skills, so the pattern exists). | `md5sum ~/.claude-acct/*/skills/unimatrix/SKILL.md \| awk '{print $1}' \| sort -u \| wc -l` = 1, wired into `unimatrix doctor` *(#6)* |
| **P0-FR3** | One path-resolution order, implemented once: `$UNIMATRIX_HOME` → the plugin's own dir → `git rev-parse --show-toplevel` → fail loudly naming every path tried. No absolute host path in `.claude/**`, `site/`, `src/`, `*.sh`. | A host-path grep over those trees is empty (it returns `SKILL.md:12` today) *(#7)* |
| **P0-FR4** | Every run prints one banner line and `GET /health` returns the same four fields: `{root, branch, head, busdir}` (absolute). | Banner + `/health` both emit all four; asserted in bats *(#8)* |
| **P0-FR5** | `check.sh` gains two greps: engine scripts (`swarm-run.sh`, `swarm-loop.sh`, `src/swarm-lib.sh`, `src/swarm-ctl`) must not match DB symbols; tracked content must not match host paths. | `check.sh` fails on a planted `UNI_DB` line in an engine script, and on a planted absolute host path *(#4, #7)* |
| **P0-FR6** | Ledger coverage measured once and written down: `run-meta` rows ÷ distinct runs. | The number exists in `docs/ops/`, dated. Under 80% means stratification is decoration and must carry its denominator forever after *(#17)* |

*Note (found while writing this PRD):* `check.sh`'s PII gate scans `plans/` among its `DIRS`, and its
`FORBIDDEN_RE` includes absolute host paths and the employer name. This plan folder is untracked, so
the gate does not see it yet — **committing these four documents as-written will fail the gate.**
Scrub or allowlist before committing. Cheap now, confusing later.

### Phase 1 — plugin + CLI finish

| FR | Requirement | Acceptance criterion |
|---|---|---|
| **P1-FR1** | In-repo `.claude-plugin/plugin.json` + `.claude-plugin/marketplace.json` (self-marketplace). Plugin ships **commands + skill only**; the engine stays a checkout reached via P0-FR3's resolution order. | `/plugin marketplace add <repo path>` then install yields working `/u:call` in a session opened in an unrelated repo *(D3)* |
| **P1-FR2** | Plugin `commands/` is **generated** from `.claude/commands/u-*.md` by a build script. One body; everything else a pointer. | The build script runs in `check.sh` and its output is diffed against what's committed; `sort \| uniq -d` over normalized command bodies finds no duplicated 20-word sentence; every stub is ≤3 lines and names a target that exists *(#18)* |
| **P1-FR3** | `unimatrix install`: symlink the router onto `$PATH`, write `~/.config/unimatrix/config` (`UNIMATRIX_HOME`, `ENV_MASTER_FILE`), add the marketplace + enable the plugin in every account. Idempotent, re-runnable after every version bump. | Running it twice changes nothing the second time; all target accounts end at the same version *(#6)* |
| **P1-FR4** | `unimatrix here`: bootstrap the current repo — create `.bus` **after verifying the filesystem is local POSIX** (`stat -f` must not report 9p/drvfs/fuseblk), seed `swarm.conf` from the example, add `.bus*` to `.gitignore`, write the `~/.config/unimatrix/fleet.json` registry entry, print the cockpit URL. | Run in a fresh repo on a `/mnt/*` path → refuses with the reason; run on a local path → registry entry exists and the fleet wall (P4-FR4) can see it |
| **P1-FR5** | `unimatrix doctor --plugin`: manifest parses, marketplace resolves, `UNIMATRIX_HOME` resolves, and an **install-drift table** prints account / installed hash / repo hash / verdict. Skill frontmatter carries a version stamp; a run whose plugin version ≠ repo version prints one warning line. | The drift table is green; planting a modified copy in one account turns it red *(#6)* |
| **P1-FR6** | Path resolution has exactly one implementation, tested from `/tmp` and from a foreign repo, with all three worktrees present. | Dispatch from a foreign repo lands in the intended worktree **and says so out loud** (P0-FR4's banner) *(#7, #8)* |
| **P1-FR7** | `run_summary()` stamps `session_id`, the statusline session marker as it already exists, and the orchestrating account. Read-only consumption of a frozen interface — **no statusline change**. | The three fields appear in `run-summary` rows; no design note anywhere contains "add X to the statusline" *(#11)* |
| **P1-FR8** | `/u-*` filename commands are deprecated one release after `/u:*` lands: deprecation line first, deletion in the following release. | Both surfaces exist for exactly one release; after that, one surface *(#18)* |

### Phase 2 — the push summary (**before** any DB work)

| FR | Requirement | Acceptance criterion |
|---|---|---|
| **P2-FR1** | Run close-out prints a **three-line lane summary** — $ per verified-done, p95 wall, false-done rate per lane — derived from the existing JSONL, zero new dependencies. | The lines print on a real run; `check.sh` wall time unchanged *(#16)* |
| **P2-FR2** | Every stratified figure prints its coverage denominator ("stratified over 31 of 104 runs — 30%"). Complexity falls back to observable signals (files touched, wall time, branch count) so NULL is rare. | No stratified figure renders without its denominator *(#17)* |
| **P2-FR3** | **The gate.** Three weeks elapsed AND ≥2 decisions changed by that summary, written down with dates. | Recorded in `docs/ops/`. **If not met — stop here. The project is done, and cheaply.** *(#16, D2)* |

### Phase 3 — the mirror (gated by P2-FR3 or an explicit overrule)

| FR | Requirement | Acceptance criterion |
|---|---|---|
| **P3-FR1** | All DB code in **one** file (`unimatrix mirror` verb); no engine script sources it. | Phase-0 engine grep still green *(#4)* |
| **P3-FR2** | The importer is a **pure function**: JSONL in → SQL text out, golden-file tested. | `check.sh` runs **zero** DB tests and its wall time did not grow measurably; no test `skip`s on a missing server *(#15)* |
| **P3-FR3** | ≤3 tables, `uni_` prefix, one JSON payload column. A new spec field requires no DDL. | Adding a field to a fixture row imports without a migration *(#9)* |
| **P3-FR4** | Correction rows (spec 08 FR-5 verdicts, FR-6 reviews) are **folded at import**. | A fixture with a false-done verdict is asserted to flip the aggregate *(#1)* |
| **P3-FR5** | PK is `(host, busdir_realpath, run, id, ts)` — never `(run, id)`. | A cross-worktree fixture import produces two rows, not one *(#2)* |
| **P3-FR6** | Import runs **synchronously in `run_summary()`**, guarded `\|\| true` like every ledger call. `unimatrix mirror --since` is the idempotent catch-up. | **No systemd unit added.** Watermark row present; staleness = `now − watermark` computed and displayed *(#3)* |
| **P3-FR7** | `unimatrix mirror --verify` re-derives into a temp schema and diffs aggregates against `src/speedwars-report.sh`. | A non-empty diff is a **hard failure** (red banner, nonzero rc), never a log line *(#1)* |
| **P3-FR8** | Work/personal split chosen from `busdir_realpath` at import time, with a **hard refuse** (nonzero, no partial write) on mismatch — not a warning. | A work-path fixture imported against the personal DB exits nonzero and writes nothing *(#12)* |
| **P3-FR9** | Zero prompt/task text in any table. DSN from env only — never `swarm.conf` (the cockpit can read it via `/api/config`), never in `ps` argv. `check.sh` PII gate rejects DSN-shaped strings. | Asserted by test, not by review *(#12)* |
| **P3-FR10** | The DB holds **zero original data**: every migration is drop-and-rebuild. Source JSONL retained compressed alongside every archive, and it — not the DB — is what gets backed up. | Drop + full rebuild exercised once, row counts diffed, result recorded; repeated monthly *(#19, #20)* |

### Phase 4 — cockpit online mode

| FR | Requirement | Acceptance criterion |
|---|---|---|
| **P4-FR1** | The zero-dep offline path is the contract. DB access sits behind `await import()` inside a function guarded by the DSN env var. | `node site/server.mjs` with a scrubbed env and no `node_modules` serves `/health`, `/api/bus`, `/api/agents` — asserted in bats. `package.json` still has no `dependencies` key (it has none today) *(#5)* |
| **P4-FR2** | The server's DB user has **SELECT only**. Startup attempts one write, expects failure, logs once, and **refuses to start if the write succeeds**. | No `INSERT\|UPDATE\|DELETE` string in `site/server.mjs`, grepped in `check.sh` *(#13)* |
| **P4-FR3** | Loopback bind hard-coded, with a comment naming this failure mode. Remote viewing is `unimatrix report --html` (a static file cannot kill a worker). | No non-loopback bind, no tunnel config anywhere in the repo *(#14)* |
| **P4-FR4** | **Fleet wall** — one row per live run across every bus in `fleet.json`, colored by state. Live panels read the bus; reporting panels read the mirror; the two read paths never cross. | With two buses registered and one run live, both appear; killing the DB leaves the wall's live half intact *(#4, #5)* |
| **P4-FR5** | **Run history browser** + **cost/lane analytics** + **failure-taxonomy** page + **operator inbox** (parked cards, budget gates, false-done verdicts, new `feedback/` drops), all reading the mirror. | Each view renders a staleness badge and a "derived from `<file>` up to byte N at `<ts>`" footer *(#1, #3)* |
| **P4-FR6** | DB stopped → every pre-existing panel still renders; only the reporting tab degrades, with a visible explanation. | Asserted with the DB down *(#4, #5)* |

*Known limit, stated up front:* only the SPEEDWARS panel is reproducible for a **past** run, because
only `docs/ops/speedwars.jsonl` survives a busdir cycle. BOARD/FIREHOSE/AGENTS history would
additionally require run-close archival of the raw `run-*.jsonl` transcripts and the `done/`/`limits/`
marker tree, which no code path does today. Out of scope here — see [NEEDS CLARIFICATION] §9.

### Phase 5 — fleetops handshake (starts only when the counterparty exists)

| FR | Requirement | Acceptance criterion |
|---|---|---|
| **P5-FR1** | **Entry gate.** `grep -ri fleetops "$BRAIN_ROOT"` returns **> 0** hits. It returns 0 today. Check monthly; it costs one grep. | Until then, phase 5 does not start *(#10)* |
| **P5-FR2** | Deliverable is **one documented artifact plus a written contract**. Consumer code lives in Brain. | Zero files in unimatrix named `fleetops`; deleting the artifact emitter leaves `check.sh` green (severability test) *(#10)* |
| **P5-FR3** | The join uses **only** fields the session marker already emits (P1-FR7 stamped them), documented before any code. | Join ambiguity quantified and printed on the page ("N% of runs matched to a session"); no proposal contains "add X to the statusline" *(#11)* |

---

## 6. Schema sketch

Three tables, `uni_` prefix, one JSON payload column each — the shape Brain's
`ops.cockpit_run_telemetry` already proves (stable columns promoted, variant detail in `jsonb`).
Column lists come from the real field inventory in [discovery §2](./discovery.md).

```
uni_run    -- 1 row per run, from run_summary() (swarm-lib.sh:2006-2059)
  host, busdir_realpath, run, ts, mode ('full'|'verify'),
  done_n, parked_n, fallback_hops, wall_secs, cost_usd, stderr_n,
  session_id, session_marker, account,          -- P1-FR7 join keys
  payload JSON                                   -- branches{}, lanes_limited[], lanes_dead[]
  PK (host, busdir_realpath, run)

uni_card   -- 1 row per finalized branch, from speed_row() (swarm-lib.sh:1885-1991)
  host, busdir_realpath, run, id, ts,
  requested, served_lane NULL, served_model, outcome, wrc, pinned, wall_secs,
  billing ('real'|'pool'), class NULL,           -- spec 12's fixed 9-value vocabulary
  verified BOOL NULL, verify_reason NULL,        -- folded from correction rows (P3-FR4)
  cost_usd NULL, tokens_in NULL, tokens_out NULL,
  payload JSON                                   -- the per-lane usage bucket, shape varies by lane
  PK (host, busdir_realpath, run, id, ts)

uni_event  -- everything else, verbatim; the escape valve that makes P3-FR3 true
  host, busdir_realpath, run, id NULL, ts, type, payload JSON
  -- type ∈ {verdict, review, run-review, run-meta, feedback, ...}; new spec rows land here
  -- with no DDL, and get promoted to a real column only after weeks of repeated querying
  PK (host, busdir_realpath, run, id, ts, type)
```

**Engine-portable DDL notes.** JSON column is `JSON` (MySQL), `jsonb` (Postgres), or `TEXT` with
`json_extract` (SQLite) — one `#ifdef`-shaped branch in the importer, nothing else changes. The
failure `class` is a controlled 9-value vocabulary and is a natural CHECK constraint everywhere.
Report SQL lives in **views**, so a shape change is one file, not N dashboards. `uni_probes` is
**not** in this sketch on purpose: spec 13's `doctor --live` writes a ledger row and an ephemeral
`limits/<lane>.broken` marker, and there is no JSONL evidence row backing it — a probes table would
be new capture, not a mirror.

---

## 7. Success metrics & risks

### Success metrics

1. `/u:call` works from any repo, any account, same version everywhere — `doctor --plugin` proves it.
2. A bulk `call` run's evidence survives busdir deletion and is queryable cross-run.
3. `check.sh` wall time roughly unchanged; still zero DB, zero network.
4. The phase-2 summary demonstrably changed ≥2 lane/spend decisions — **or the project stopped cheaply.**
5. Zero unimatrix files named `fleetops`; Brain can build its consumer from the contract alone.

### Top 5 risks (pre-mortem, expected damage × likelihood)

| # | Risk | Likelihood | Mitigation |
|---|---|---|---|
| 1 | **Nobody reads the reports** — the default outcome for a pull surface built for one operator who already has push surfaces | Very high | P2-FR1 ships the push line first; P2-FR3 is the honest cancel gate |
| 2 | **Mirror drift + join-key rot** — reports that lie get acted on; the key bug exists *today* at `swarm-lib.sh:1972`/`:2010` vs `:2081` | High | P0-FR1 (fix now, no DB involved), P3-FR4 (fold corrections), P3-FR5 (PK), P3-FR7 (`--verify` as hard failure) |
| 3 | **The zero-dep offline path rots** — one `import` line ends a currently-true property permanently | High | P4-FR1: guarded `await import()`, ten-line bats contract, no `dependencies` key |
| 4 | **Plugin skew / path fragility / wrong worktree** — failures here are silent and misattributed as "the model did something dumb" | High | P0-FR2 (symlinks), P0-FR3 (one resolution order), P0-FR4 (banner), P1-FR2 (generated commands), P1-FR5 (drift table) |
| 5 | **Fleetops vaporware + the locked marker** — verified-nonexistent counterparty, 100% waste if built early | Very high | P5-FR1 entry gate, P5-FR2 severability test, P1-FR7 reads the marker without changing it |

**Honorable mention — DB in the execution path.** Low likelihood, catastrophic if it fires (it
invalidates `bus-discipline.md`). P0-FR5's six-line grep makes it mechanically impossible for
roughly zero cost — build it in phase 0 and stop thinking about it.

---

## 8. Release & rollout

- **Semver continues** on the existing flow: `CHANGELOG.md` `[Unreleased]` accumulates 3-5
  user-facing features, then a release is cut with the plain-language "What's new (for humans)"
  block per `CLAUDE.md §Versioning`.
- **Plugin version = repo version.** `plugin.json.version` is bumped in the same commit as the
  changelog entry; the release checklist grows one line. Zero new release ceremony.
- **Multi-account install loop.** Every version bump ends with one idempotent `unimatrix install`
  run across the account set, then `unimatrix doctor --plugin` to confirm the drift table is green.
  Manual fan-out to N targets has a compounding per-update failure probability; the loop or it
  doesn't get done.
- **Deprecation schedule for `/u-*` filename commands.** Release N ships `/u:*` alongside `/u-*`
  plus a deprecation line in each `-` variant. Release N+1 deletes the `-` variants. The pre-spec-16
  bare names (`/swarm`, `/swarm-loop`, `/speedwars`, `/setup`) stay as ≤3-line stubs — they cost
  nothing and are what muscle memory types.
- **Rollback.** Phases 0-2 are ordinary commits. Phase 3+ rolls back by dropping the database: it
  holds zero original data by invariant (P3-FR10), so nothing is lost that the JSONL doesn't have.

---

## 9. [NEEDS CLARIFICATION]

1. **Version source of truth for `plugin.json`.** `package.json:3` says `0.1.0`; this worktree's
   `CHANGELOG.md` has only an `[Unreleased]` section (no cut release). `CLAUDE.md` names
   `docs/releasing.md` as the release checklist, but **that file does not exist in this worktree**.
   Which artifact does the plugin version mirror, and is `package.json` stale?
2. **Install target set.** Discovery found **11** settings files carrying the plugin block
   (`~/.claude` + 10 accounts); the pre-mortem found **7** account dirs with skill copies. Which set
   does `unimatrix install` (P1-FR3) and the drift table (P1-FR5) cover?
3. **Work/personal boundary definition.** P3-FR8 refuses on mismatch, but nothing in the code knows
   which side of the boundary a `busdir_realpath` is on. What is the authoritative prefix list, and
   where does it live (`~/.config/unimatrix/config`? `fleet.json`?)?
4. **Raw-log archival.** Reproducing BOARD/FIREHOSE/AGENTS for a *past* run needs run-close archival
   of `run-*.jsonl` + the marker tree (the reserved-but-unwritten `docs/ops/bus-archives/`). Not in
   the synthesis, not costed here. Wanted as a phase-3 companion, or explicitly out?
5. **`unimatrix report`/`export` verb family.** Synthesis lists `report` among the CLI verbs and
   P4-FR3 depends on `report --html`, but no phase FR specifies its subcommands or output contract.
   Assign to phase 2 (JSONL-only) or phase 4 (mirror-backed)?

### Orchestrator resolutions (Fable, 2026-07-25 — folded from repo context; #4 rides the architecture decision)

1. **Version truth = CHANGELOG release headings** (v1.0.0 was cut in the live tree's round-4 wave —
   `docs/releasing.md` is uncommitted there, which is why this worktree lacks both). `plugin.json`
   version is stamped from the newest CHANGELOG release at plugin-build time; `package.json:3` is
   stale and gets aligned in the same commit. Rebase over the live wave brings the checklist file in.
2. **Install target set = all of them**: `~/.claude/settings.json` + every `~/.claude-acct/*/settings.json`
   (the 11 discovery found). The 7 skill copies are a separate artifact and get **symlinked** in
   phase 0 — after which "accounts with copies" stops being a set anyone tracks.
3. **Boundary list lives in `~/.config/unimatrix/config`** (written by `unimatrix install`, read by
   the importer): `DOMAIN_WORK=<work-repos-prefix>` prefix rule, everything else → personal.
   `fleet.json` stays a registry, not a policy file.
4. **Raw-log archival** is settled by the architecture matrix (candidate C3 makes it core, C1 a
   companion, C2 optional) — see 00-SYNTHESIS.md, not re-decided here.
5. **`report` is phase 2, JSONL-only** — it is the push-summary's bigger sibling and must exist
   before any mirror so the gate can be judged on zero-infra output. Mirror-backed variants are a
   phase-4 extension of the same verb, same output contract.
