# Pre-mortem — Plugin + Unified CLI + Online Cockpit + Fleetops

**Role:** convergent pessimist. **Date written:** 2026-07-25. **Date imagined:** 2026-01-25 (T+6mo).
**Premise:** the project shipped and is now regretted shelfware, or died mid-build. This is the
post-mortem, written before the fact.

Baseline state at time of writing (verified, not assumed):

| Fact | Evidence |
|---|---|
| Skill is **copied**, not linked, into 7 accounts | `~/.claude-acct/{Gmail,eletrixa,gmail,<work>,post,rob7,soulfire}/skills/unimatrix/SKILL.md` — all md5 `fa647784…`, in sync *today* |
| Three live worktrees | `unimatrix` (public), `unimatrix-calldev` (call-dev), `unimatrix-stable` (detached @ ba42183) |
| Cockpit is a transient systemd unit pinned to one path | `WorkingDirectory=<home>/code/unimatrix`, `Restart=no`, `PORT=4747` |
| Cockpit writes exactly one bus file | `site/server.mjs:27`, `:1600` — `audit.jsonl`; all mutations delegated to `src/swarm-ctl` via a fixed `execFile` argv table (`:1308`) |
| Evidence files are gitignored, per-worktree | `.gitignore`: `docs/ops/llm-runs.md`, `docs/ops/speedwars.jsonl`, `docs/ops/bus-archives/`, `.bus/` |
| The run join key is **already inconsistent** | `src/swarm-lib.sh:1972` & `:2010` use `basename(dirname busdir)`; `:2081` uses `basename busdir` |
| **fleetops does not exist** | `grep -ri fleetops "$BRAIN_ROOT"` → **0 hits** |
| Statusline (marker source) is locked | global CLAUDE.md: chmod 444, "changes only on Robert's request"; fleetops mirrors its 24-emoji hash |
| Spec 16 explicitly deferred the plugin | "No true `/u:call` … and no cross-repo command availability — both require plugin packaging, deferred" |

---

## The 20 ways it died

### 1. The mirror and the bus disagreed, and the mirror won the argument

**What died.** `uni_speedwars` said grok's p95 was 4 minutes; `src/speedwars-report.sh` over the
same JSONL said 11. Robert re-ordered `EXEC_CHAIN` off the dashboard number. Two months of lane
policy was built on a number the file-bus never said.

**Why.** The ledger is append-only *with corrections* — spec 08 FR-5 verdict rows and FR-6 review
rows amend earlier rows and "never edit prior rows". A naive `INSERT` mirror stores the original
claim as a row and the correction as a second row; every aggregate that forgot the correction
join reports claimed-done as done. That is exactly the false-done class spec 08 exists to kill,
resurrected inside the reporting layer.

**Earliest signal.** The *first* time a dashboard figure and `/speedwars` disagree — including by
one row. Not "when it's badly wrong": the first disagreement.

**Cheapest prevention.** The mirror is a **derived view, never an authority**: one importer that
folds correction rows at import time, a `uni_sync_state` watermark (file, byte offset, mtime,
sha), and every report page footer printing "derived from `<file>` up to byte N at `<ts>`". Ship
`unimatrix mirror --verify` that re-derives into a temp schema and diffs aggregates; make a
non-empty diff a red banner, not a log line.

---

### 2. The join key rotted — and it was already rotten before the DB existed

**What died.** Runs from `unimatrix-calldev` and `unimatrix` collapsed into the same `run`
bucket; feedback stubs joined to nothing. Cross-run reporting — the entire point — produced tables
where the interesting rows were merged strangers.

**Why.** `run` defaults to `basename(dirname busdir)` in `speed_row`/`run_summary`
(`src/swarm-lib.sh:1972`, `:2010`) and to `basename(busdir)` in `feedback_stub` (`:2081`). Three
worktrees all produce `unimatrix*`-shaped parents; `.bus-*` alt buses produce a third shape. Task
`id`s are small integers scoped to one bus, reused across every run. `(run, id)` was never unique
and nobody noticed while the consumer was a human reading one file.

**Earliest signal.** `SELECT run, id, COUNT(*) … HAVING COUNT(*) > 1` returning anything on the
very first import. Before the DB: `jq -r .run docs/ops/speedwars.jsonl | sort -u` showing two
labels that mean the same thing, or one label meaning two things.

**Cheapest prevention.** Fix the two call sites into one `_run_label()` helper **now**, in the
current codebase, with no DB involved. Then make the mirror's primary key
`(host, busdir_realpath, run, id, ts)` — never `(run, id)` — and require an explicit
`SPEEDWARS_RUN` at seed time (warn loudly on the default).

---

### 3. The sync daemon became the standing daemon the doctrine warned about

**What died.** A `uni-sync.service` alongside `svc-unimatrix.service`. It OOM'd during a 12-branch
wave in September, `Restart=no` (copied from the existing transient unit), and nobody looked at
the dashboard for five weeks. When they did, the last row was from September.

**Why.** "Ask first: adding a standing daemon" got answered once, for the sync, and the answer
carried an implicit "and it'll be fine". Silent staleness is the daemon failure mode — the page
still renders, the numbers just stop moving, and a single-operator tool has no second pair of eyes
to notice.

**Earliest signal.** `MAX(ts)` in the DB more than one completed run behind the newest bus row.
Cheap to compute; nobody computes it unless it's on the page.

**Cheapest prevention.** **No daemon.** `run_summary()` already fires at run close — call the
importer there, synchronously, guarded `|| true` like every other ledger call. Add
`unimatrix mirror --since` as an idempotent catch-up you run before reporting. Put a staleness
badge on every page computed from watermark-vs-bus-mtime, so stale reads look broken instead of
looking fine.

---

### 4. MySQL crept into the execution path

**What died.** `swarm-run.sh` gained a "have we already run this task id" check against the DB
(cheap dedupe, felt harmless). Six weeks later the DB was down and no swarm could start. The
file-bus was no longer the coordination layer; it was a cache in front of MySQL.

**Why.** Accretion, one reasonable-looking commit at a time. Nobody decided to violate
`rules/unimatrix/bus-discipline.md`; three people each moved one inch. Read paths go first
("faster"), then a write, then an invariant.

**Earliest signal.** The first `mysql`/`UNI_DB` symbol appearing in `swarm-run.sh`,
`swarm-loop.sh`, `src/swarm-lib.sh`, or `src/swarm-ctl`. Or: the cockpit failing to render the
agents grid with the DB stopped.

**Cheapest prevention.** A structural gate, not a rule in a doc: all DB code in **one** file that
no engine script sources, and a `check.sh` step that greps the engine sources for DB symbols and
fails the build. Six lines of bash that make the doctrine mechanically enforced.

---

### 5. The zero-dep offline path — the one used daily — broke

**What died.** `node site/server.mjs` on a fresh clone threw `Cannot find package 'mysql2'`. The
cockpit that had worked with zero `npm install` since day one now needed a dependency tree to show
a bus that was sitting right there on disk.

**Why.** A top-level `import mysql from "mysql2/promise"` in `server.mjs`. Today that file imports
only `node:*` (`server.mjs:36-41`) and `package.json` has no `dependencies` key at all. One import
line ends that property permanently, and it is the single most-used property of the whole tool.

**Earliest signal.** `package.json` gaining a `dependencies` key. Or `node --input-type=module -e
'import("./site/server.mjs")'` failing in a container with no `node_modules`.

**Cheapest prevention.** DB access behind `await import()` inside a function guarded by
`process.env.UNI_DB_URL`. A bats test that boots the server with a scrubbed env and asserts
`/health`, `/api/bus`, `/api/agents` all 200 — that test is the contract, and it is ten lines.

---

### 6. Plugin update skew: one account ran last month's commands

**What died.** A run launched from the work account used a `/u:call` body that still passed a
flag `swarm-run.sh` had dropped. It failed at branch 3 of 9, after ~$4 of lane spend, with an
error that named neither the account nor the stale file.

**Why.** Skills are **copied** into 7 account dirs (verified: 7 identical copies today, kept in
sync by hand). The plugin adds an eighth distribution channel with its own update cadence. Manual
fan-out to 7 targets has a per-update failure probability that compounds; "all 7 in sync" is a
snapshot, not a property.

**Earliest signal.** `md5sum ~/.claude-acct/*/skills/unimatrix/SKILL.md` producing more than one
hash. Available today, checked never.

**Cheapest prevention.** Symlink the 7 account copies at the canonical repo dir (one inode, skew
impossible) — the accounts already symlink other skills to `/mnt/c/...`, so the pattern exists.
Where a real copy is unavoidable (plugin packaging), stamp a version in the frontmatter and have
`unimatrix doctor` print an install-drift table: account, hash, repo hash, verdict.

---

### 7. The checkout moved and every command broke at once

**What died.** `unimatrix-stable` was promoted to `~/code/unimatrix` and the old dir renamed. The
systemd unit pointed at a directory that no longer existed; the skill's hard-coded
`~/code/unimatrix/feedback/` silently dropped feedback into nowhere; `/u:call` from other repos
resolved to a path that was now a different branch.

**Why.** Absolute paths in three independent places, none of which validate: the systemd unit
(`WorkingDirectory=<home>/code/unimatrix`, transient — regenerated from a command line nobody
version-controls), the skill body, and whatever the plugin bakes in. A plugin *increases* this,
because it must know where the CLI lives from a session that is in some other repo entirely.

**Earliest signal.** `grep -rn "$HOME\|~/code/unimatrix" .claude/ site/ src/` returning
anything. It returns something today (`SKILL.md:12`).

**Cheapest prevention.** One resolution order, implemented once: `$UNIMATRIX_HOME` → plugin's own
dir → `git rev-parse --show-toplevel` → fail loudly with the tried paths. Ban absolute host paths
in `.claude/**` and plugin files via a `check.sh` grep. Convert the transient systemd unit into a
checked-in unit file with the path in exactly one place.

---

### 8. The plugin dispatched to the wrong worktree

**What died.** A "stable" run from another repo executed call-dev code; a wave wrote its bus into
`unimatrix-calldev/.bus` while the cockpit on :4747 watched `unimatrix/.bus` and showed an empty
grid. Twenty minutes of debugging a run that was working perfectly, somewhere else.

**Why.** Three worktrees, one plugin, one cockpit, and no run banner that says which. `BUSDIR`
defaults to `REPO_ROOT/.bus` (`server.mjs:52`) and `REPO_ROOT` is wherever the process started.
Nothing in the current output tells an operator which checkout, which branch, which bus.

**Earliest signal.** Two `.bus` dirs with mtimes inside the same hour. Or the cockpit showing zero
agents while a run is provably live.

**Cheapest prevention.** Every run prints one banner line: resolved root, branch, HEAD short sha,
absolute BUSDIR. `/health` returns the same four fields. Cost: one `printf`, one JSON key. This
also solves half of #7's diagnosis cost.

---

### 9. The `uni_` schema churned with every spec, and the queries rotted

**What died.** Between specs 15 and 19 the schema took nine `ALTER TABLE`s. Saved dashboard
queries broke on renames; the ones that didn't break silently excluded new lanes because they had
a hard-coded lane `IN (...)` list. Reports stopped being trusted, then stopped being opened.

**Why.** Specs 10–16 each added fields to the evidence rows (role classes, succession, failure
classes, lane health, call metadata). The JSONL absorbed that for free — a new key is just a new
key. A normalized SQL schema charges a migration for each one, and every report that named columns
pays again.

**Earliest signal.** The second schema change inside one month. Or any report query needing an
edit to keep working after a spec landed.

**Cheapest prevention.** Three tables, maximum, one of them `uni_event(host, busdir, run, id, ts,
type, payload JSON)`. New fields land in `payload`; a field gets promoted to a real column only
after it has been queried repeatedly for weeks. Keep report SQL in **views**, so a shape change is
one file, not N dashboards.

---

### 10. Fleetops never happened, and the integration was dead weight

**What died.** `uni_fleet_session`, the marker-join code, and the "fleet" panel in the cockpit —
all built against a fleetops that, six months on, still does not exist in brain. The panel showed
an empty table. It was deleted in a cleanup, along with the tests, along with the spec.

**Why.** `grep -ri fleetops "$BRAIN_ROOT"` returns **0 hits today**. The integration was
designed against a system that lives in one person's head and a statusline emitter. Integrations
against unbuilt counterparties are the highest-variance work in any plan and the easiest to
mistake for progress, because the code compiles.

**Earliest signal.** Phase 1 lands and brain still has zero fleetops surface. Check it monthly;
it costs one grep.

**Cheapest prevention.** Build **no** integration. Emit one documented, stable artifact (a table
or a JSONL with a written contract) that a future fleetops can consume, and stop. Zero unimatrix
files named `fleetops`. If fleetops materializes, the consumer lives in brain, where the schema
churn belongs to the party that can absorb it.

---

### 11. The join to fleetops needed one more field from a locked file

**What died.** The session↔run join was 80% reliable. Closing it needed one extra token in the
status line's session marker. The statusline is `chmod 444`, its 24-emoji set and hash are
load-bearing, and its change protocol requires Robert's explicit ask in-conversation. The join
stayed 80% reliable forever, which meant every fleet-level number carried a footnote nobody read.

**Why.** Designing a join against an interface you are not allowed to change, and only discovering
the missing field after the rest is built.

**Earliest signal.** Any design note containing "add X to the statusline". That sentence is the
tripwire.

**Cheapest prevention.** Treat the marker as a **frozen external interface**: write down exactly
what it emits *before* designing any join, and if the join isn't clean with what's already there,
don't build the join. Join on wall-clock + cwd + pid instead, accept the ambiguity explicitly, and
label the number "approximate" on the page.

---

### 12. Work data and personal data ended up in the same database

**What died.** A personal `uni_` database on the soulfire side contained work-repo paths,
branch names, and ticket references from brain runs. Separately, a MySQL DSN with a password got
into a run's environment and then into a worker's log, which is in `.bus/`, which is in an archive,
which got attached to a bug report.

**Why.** One DB was simpler than two. The boundary is a convention (`~/s/<work>/` vs `~/s/`,
`.claude-acct/<work>` vs `.claude-acct/soulfire`), not a mechanism — and the swarm harness is
explicitly cross-repo (spec 15 `call` runs against any checkout). Nothing in the code knows which
side of the boundary a run is on.

**Earliest signal.** The first row whose `busdir_realpath` starts with the work prefix (`$DOMAIN_WORK`), in a
personal DB. Trivially checkable, checked never unless it's a startup assertion.

**Cheapest prevention.** Two DBs, split by owner, chosen from `busdir_realpath` at import time
with a hard refuse (not a warning) on mismatch. Keep spec 08's existing rule that rows **never**
carry prompt/task text — that rule is already the strongest privacy control in the design; do not
let "the DB could store the prompt for context" survive review. DSN comes from `~/s/…` env only,
never from `swarm.conf` (which the cockpit can read via `/api/config`), never in `ps` argv. Extend
the `check.sh` PII gate with a DSN regex.

---

### 13. The cockpit got a write connection, and its blast radius grew by three orders of magnitude

**What died.** A path-handling bug in a new `/api/report` route became an arbitrary write against
the evidence store. Nothing catastrophic happened — the operator noticed — but the incident ended
trust in the online cockpit, and it went back to read-only-offline permanently.

**Why.** Today's server writes exactly one file (`audit.jsonl`) and delegates every mutation to
`swarm-ctl` through a fixed argv table — a deliberately tiny, auditable surface documented in its
own header (`server.mjs:24-30`). "The importer might as well live in the server, it's already
running" trades that entire property for convenience.

**Earliest signal.** The first `INSERT`/`UPDATE`/`DELETE` string inside `site/server.mjs`.

**Cheapest prevention.** The server gets a MySQL user with `SELECT` only. Writes happen in the CLI
importer, never in the HTTP process. Prove it at startup: attempt one write, expect failure, log
once, refuse to start if the write succeeds. Ten lines, and it converts a policy into a fact.

---

### 14. "Online" turned into "exposed"

**What died.** :4747 got bound to `0.0.0.0` so it could be seen from the Windows side, then
tunneled so it could be seen from a phone. The cockpit has no authentication and a `POST /api/ctl`
that can kill workers. It was reachable for eleven days.

**Why.** "Online reporting" is an ambiguous phrase. It can mean "durable across runs" or "reachable
from elsewhere"; the plan says the former, the implementation drifts to the latter because the
former made a web page and web pages want to be visited.

**Earliest signal.** Any bind address other than loopback, any tunnel/ngrok/cloudflared config, any
`_headers`/CSP discussion about remote origins.

**Cheapest prevention.** Hard-code the loopback bind with a comment naming this failure. For remote
viewing, `unimatrix report --html > out.html` (a static file, no live control plane) — a dead file
cannot be used to kill a worker.

---

### 15. The test surface exploded and the gate got skipped

**What died.** `check.sh` went from ~seconds to minutes, needed a running `mysqld` for a third of
its assertions, and started failing on a laptop without the service. Someone added a skip. The skip
spread. The gate stopped being a gate.

**Why.** 12 bats files today, all pure-bash and hermetic. DB tests want a server, fixtures,
teardown, port allocation, and they flake. The doctrine "must be green before anything is
considered done" survives exactly as long as green is cheap.

**Earliest signal.** The first test that `skip`s when `mysqld` is absent. Or `check.sh` wall time
doubling.

**Cheapest prevention.** Make the importer a **pure function**: JSONL in → SQL statements out.
Golden-file the SQL text; zero DB in `check.sh`. One optional live-DB smoke behind `UNI_DB_TEST=1`,
run by hand before a schema change, never part of the gate.

---

### 16. Nobody read the reports

**What died.** Everything. The plugin works, the mirror is correct, the dashboards are pretty, and
the cockpit's reporting tab was opened four times in six months — twice by the person who built it,
to check it still rendered.

**Why.** Single operator. Dashboards are a **pull** surface: they assume someone with a question
goes looking. Robert's actual decisions (which lane goes first in `EXEC_CHAIN`, whether kimi's PAYG
spend is worth it, whether grok false-dones again) get made *during* runs, in the terminal, from
`/speedwars` and the run close-out — surfaces that push. A durable DB doesn't change where the
decision happens; it just adds a place the answer also exists.

**Earliest signal.** Three weeks after phase 1, no decision has been made *because of* a report.
Ask the question explicitly and write the answer down — it's the only honest metric here.

**Cheapest prevention.** Identify the ONE query that changes behavior — most likely "$ per
verified-done and p95 wall, per lane, stratified by complexity, last 30 days" — and deliver it as
**three lines appended to the run close-out**, pushed into the terminal where the decision is
already being made. Build the page only after that line has changed a decision at least twice. If
it never does, the project was correctly cancelled at zero cost.

---

### 17. The reports were stratified over data nobody entered

**What died.** Every complexity-stratified table was computed over the ~30% of runs that had a
`run-meta` row. The C1 bucket looked cheap and fast because trivial runs are the ones an
orchestrator bothers to annotate. Conclusions were drawn from a biased 30% and presented as 100%.

**Why.** Spec 08 FR-4/5/6 rows (complexity, verdict, review) are written **by the orchestrator by
hand**. Optional human-entered fields decay toward zero, and they decay *non-randomly* — which is
worse than missing, because the bias points the same way as the hypothesis.

**Earliest signal.** `jq 'select(.type=="run-meta")' | wc -l` versus distinct runs, in the first
month. Under 80%, the stratification is decoration.

**Cheapest prevention.** Print coverage as a first-class number on every stratified view
("stratified over 31 of 104 runs — 30%"), auto-derive a fallback complexity from observable
signals (files touched, wall time, branch count) so NULL is rare, and never let a stratified chart
render without its denominator.

---

### 18. Three copies of every command body, and the stale one won

**What died.** `/swarm` and `/u:swarm` behaved differently depending on the account. Debugging
took an hour each time because the *symptom* was model behavior ("the swarm planned it wrong"),
not an error.

**Why.** Spec 16 already made `.claude/commands/swarm.md` a stub pointing at `u-swarm.md` — good.
Plugin packaging adds a third home for the same prose (repo `.claude/commands/`, plugin
`commands/`, 7 account dirs). Prompt text has no compiler; a stale copy produces plausible wrong
behavior instead of a crash.

**Earliest signal.** Any two files in the tree containing the same 20-word prompt sentence. One
`sort | uniq -d` over normalized command bodies finds it.

**Cheapest prevention.** One body, everything else a generated pointer. The plugin dir is **built**
from the repo by a script, never hand-copied. `check.sh` asserts every stub is ≤ 3 lines and names
a target that exists.

---

### 19. The first schema migration had no story

**What died.** A hand-typed `ALTER TABLE uni_speedwars ADD COLUMN …` against a live DB holding six
months of rows, at 23:40, with no backup. It half-applied. The rebuild path had never been
exercised.

**Why.** A migration tool is a new dependency (`ask first`), so none was adopted; the DB
accumulated rows nobody could regenerate; and a mirror that can't be rebuilt is a primary store
wearing a mirror's badge.

**Earliest signal.** The first `ALTER TABLE` typed by a human. Before that: the first row in the DB
that does not exist anywhere in a JSONL file.

**Cheapest prevention.** Make "the DB holds **zero** original data" a stated invariant, so every
migration is `DROP DATABASE` + re-import — no migration tool, no new dependency, no 23:40. Prove
it monthly: rebuild into a temp schema and diff row counts.

---

### 20. The archives were pruned, and the rebuild story died with them

**What died.** #19's invariant, silently. `.bus/`, `docs/ops/speedwars.jsonl` and
`docs/ops/bus-archives/` are all gitignored and local. A disk cleanup removed archives from
before October. The rebuild now produced 40% fewer rows than the live DB, so nobody dared run it,
so the DB became the primary store by attrition — and the only copy of a year of lane evidence sat
in an unbackedup MySQL on a WSL2 box.

**Why.** The JSONL was treated as scratch because it is gitignored; the DB was treated as durable
because it is a database. Backwards: the JSONL is the record and the DB is the cache.

**Earliest signal.** `unimatrix mirror --verify` (from #19) producing a row-count deficit —
whenever it is first run.

**Cheapest prevention.** Retain the source JSONL compressed alongside every archive (it's text, it
costs nothing), make the rebuild-and-diff a monthly one-liner, and back up the JSONL — not the
database. Whatever you back up is what you believe is the truth; make those the same thing.

---

## Top 5 by expected damage × likelihood

| # | Failure | Likelihood | Damage | Why it tops the list |
|---|---|---|---|---|
| **1** | **#16 — nobody reads the reports** | Very high | Total (project = shelfware) | This is the default outcome for a pull-surface built for a single operator who already has push surfaces (`/speedwars`, run close-out, cockpit) that answer the same question mid-decision. Nothing else on this list matters if this one fires. Mitigation is also the cheapest on the list: ship the three-line close-out summary first and see whether it changes a decision, before building any page or schema. |
| **2** | **#1 + #2 — mirror drift and join-key rot** | High (the key bug **exists today** at `swarm-lib.sh:1972/2010` vs `:2081`) | Severe | Reports that lie are strictly worse than no reports: they get acted on. `EXEC_CHAIN` ordering and PAYG spend decisions ride on these numbers, and the correction-row semantics (spec 08 FR-5) mean the naive import specifically re-buries false-dones — the exact failure the ledger was built to expose. |
| **3** | **#5 — zero-dep offline path rots** | High (one `import` line does it) | Severe | Breaks the surface used *daily* in service of the surface used *monthly*. `package.json` has no dependencies at all today and `server.mjs` imports only `node:*`; that is a real, currently-true property that one careless commit ends permanently, on every machine, forever. |
| **4** | **#6 + #7 + #8 — plugin skew, path fragility, wrong worktree** | High (7 accounts × 3 worktrees, manual copy) | Moderate–severe | Failures here are *silent and misattributed*: a stale prompt body or a wrong-worktree dispatch presents as "the model did something dumb", burning debugging hours and real lane spend before anyone suspects the install. It also erodes trust in the plugin — the one deliverable meant to make unimatrix reachable from everywhere. |
| **5** | **#10 + #11 — fleetops vaporware and the locked marker** | Very high (0 hits in brain today) | Moderate (bounded, but 100% waste) | Verified non-existent counterparty. Every hour spent here has expected value near zero and cannot be salvaged by later effort. Bounded only because it's severable — *if* it stays severable, which is what the "emit an artifact, build no integration" rule buys. |

**Honorable mention — #4 (MySQL in the execution path).** Low likelihood (doctrine is strong and
explicit) but catastrophic if it fires: it invalidates `bus-discipline.md`, the property that makes
the whole tool dependency-free. Rated 6th only because the six-line `check.sh` grep makes it
mechanically impossible for roughly zero cost — so build that grep in phase 0 and stop thinking
about it.

---

## Tripwires — the checks that gate each phase

Each is a command or an observation. A phase does not start until the prior phase's tripwires are
armed *and* passing. Every tripwire is cheap enough to run in `check.sh` or in one shell line.

### Phase 0 — hygiene, before any new feature (nothing here needs a DB or a plugin)

- [ ] `_run_label()` exists as one helper; `swarm-lib.sh:1972`, `:2010`, `:2081` all call it. *(#2)*
- [ ] `jq -r '[.run,.id]|@tsv' docs/ops/speedwars.jsonl | sort | uniq -d` is empty, or the
      duplicates are understood and the key is extended. *(#2)*
- [ ] `md5sum ~/.claude-acct/*/skills/unimatrix/SKILL.md | awk '{print $1}' | sort -u | wc -l` = 1,
      wired into `unimatrix doctor`. *(#6)*
- [ ] `grep -rn "$HOME\|~/code/unimatrix" .claude/ site/ src/ *.sh` is empty. *(#7)*
- [ ] Run banner + `/health` both emit `{root, branch, head, busdir}`. *(#8)*
- [ ] `check.sh` fails if any engine script (`swarm-run.sh`, `swarm-loop.sh`, `src/swarm-lib.sh`,
      `src/swarm-ctl`) matches `mysql|UNI_DB|SELECT `. *(#4)*
- [ ] Ledger coverage measured and written down: `run-meta` rows ÷ distinct runs. *(#17)*

### Phase 1 — plugin packaging

- [ ] Plugin `commands/` is **generated** by a script from the repo; the script is in `check.sh`
      and its output is diffed against what's committed. *(#18)*
- [ ] No command body text appears twice in the tree (`sort | uniq -d` over normalized bodies). *(#18)*
- [ ] Path resolution has exactly one implementation, with a test that runs it from `/tmp` and from
      a foreign repo. *(#7)*
- [ ] Install drift table in `unimatrix doctor`: account, hash, repo hash, verdict — green. *(#6)*
- [ ] Version stamp in the skill frontmatter; a run whose plugin version ≠ repo version prints one
      warning line. *(#6)*
- [ ] Dispatch from a foreign repo, with all three worktrees present, lands in the intended one and
      says so out loud. *(#8)*

### Phase 2 — the push summary (**before** any DB work)

- [ ] Run close-out prints the three-line lane summary ($/verified-done, p95 wall, false-done rate),
      derived from the existing JSONL, zero new dependencies. *(#16)*
- [ ] Coverage denominator printed beside every stratified figure. *(#17)*
- [ ] **Gate to phase 3:** three weeks elapsed AND at least two decisions were changed by that
      summary, written down with dates. **If not — stop here. The project is done, and cheaply.** *(#16)*

### Phase 3 — the MySQL mirror (CLI importer only, no HTTP, no daemon)

- [ ] All DB code in one file; no engine script sources it; phase-0 grep still green. *(#4)*
- [ ] Importer is a pure function (JSONL → SQL text) with golden-file tests; `check.sh` runs **zero**
      DB tests and its wall time did not grow measurably. *(#15)*
- [ ] `unimatrix mirror --verify` re-derives and diffs aggregates against
      `src/speedwars-report.sh`; a non-empty diff is a hard failure. *(#1)*
- [ ] Correction rows (spec 08 FR-5/FR-6) are folded at import; a fixture with a false-done verdict
      is asserted to flip the aggregate. *(#1)*
- [ ] PK includes `host` + `busdir_realpath`; a cross-worktree fixture import produces two rows,
      not one. *(#2)*
- [ ] Import runs synchronously in `run_summary()`, guarded `|| true`; **no systemd unit added**. *(#3)*
- [ ] Watermark row present; staleness = `now − watermark` is exposed and displayed. *(#3)*
- [ ] Import refuses (non-zero, no partial write) when `busdir_realpath` crosses the
      work/personal boundary for the target DB. *(#12)*
- [ ] `check.sh` PII gate rejects DSN-shaped strings; DSN read from env only, never `swarm.conf`,
      never argv. *(#12)*
- [ ] Zero prompt/task text in any table — asserted by a test, not by review. *(#12)*
- [ ] Schema is ≤ 3 tables with a JSON payload column; a new spec field requires no DDL. *(#9)*
- [ ] `DROP` + full rebuild exercised once, row counts diffed, result recorded. *(#19, #20)*
- [ ] Source JSONL retained (compressed) alongside every archive, and it — not the DB — is what
      gets backed up. *(#20)*

### Phase 4 — cockpit online mode

- [ ] `node site/server.mjs` with a scrubbed env and no `node_modules` serves `/health`,
      `/api/bus`, `/api/agents` — asserted in bats. *(#5)*
- [ ] `package.json` still has no `dependencies` key, or the DB driver is `optionalDependencies`
      loaded via `await import()` only. *(#5)*
- [ ] Server's DB user has `SELECT` only; startup write-probe fails as expected and the server
      refuses to start if it succeeds. *(#13)*
- [ ] No `INSERT|UPDATE|DELETE` string in `site/server.mjs` — grepped in `check.sh`. *(#13)*
- [ ] Bind address is loopback, hard-coded, with a comment naming this failure; no tunnel config
      anywhere in the repo. *(#14)*
- [ ] Every DB-backed view renders a staleness badge and a "derived from … up to …" footer. *(#1, #3)*
- [ ] DB stopped → cockpit still renders every pre-existing panel; only the reporting tab degrades,
      with a visible explanation. *(#4, #5)*

### Phase 5 — fleetops handshake (only if fleetops actually exists)

- [ ] `grep -ri fleetops "$BRAIN_ROOT"` returns **> 0** hits. Until then, phase 5 does
      not start. *(#10)*
- [ ] Zero files in unimatrix named `fleetops`; the deliverable is one documented artifact plus a
      written contract, and the consumer code lives in brain. *(#10)*
- [ ] The join uses **only** fields the session marker already emits, documented before any code;
      no proposal anywhere contains "add X to the statusline". *(#11)*
- [ ] Join ambiguity quantified and printed on the page ("N% of runs matched to a session"). *(#11)*
- [ ] Severability test: delete the fleetops artifact emitter and everything else still passes
      `check.sh`. *(#10)*

---

## The one-paragraph version

The most likely obituary is not technical. It is: *the plugin worked, the mirror was correct, the
dashboards were accurate, and nobody opened them* — because a single operator with a terminal
already gets his answers where the decision happens. The second most likely is that the reports
were wrong in a way that got acted on, because the run join key is inconsistent in the code
**today** and the ledger's correction rows re-bury exactly the false-dones the ledger exists to
expose. Everything else on this list is bounded by cheap, mechanical gates — a grep, a hash, a
row-count diff. Do phase 0 and phase 2 first; they cost days, they're useful even if the project
stops there, and phase 2's gate is the honest place to cancel.
