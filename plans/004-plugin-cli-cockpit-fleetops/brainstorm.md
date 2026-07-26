# UNIMATRIX — Brainstorm: Plugin + Unified CLI + Cockpit-as-Product + Fleetops

**Stage:** BRAINSTORM (divergent — no filtering, no costing, no decisions)
Repo: `unimatrix` (worktree `unimatrix-calldev`, branch `call-dev`) · Date: 2026-07-25
Feeds: discovery → pre-mortem → Fable synthesis → PRD → oh-architecture.
Baseline: spec 15 (`call` verb) + spec 16 (`./unimatrix` router + `/u-*` commands), commit `822aee6`.

**Standing constraints these ideas must not break** (repeated so no downstream reader has to
re-derive them): the engine's `.bus/` stays a local POSIX filesystem — no DB, no daemon, no MCP in
the execution path; MySQL is only ever a downstream evidence mirror; judge ≠ executor; no silent
spend; every new dependency/daemon stays **optional** — cockpit must still boot with zero deps and
no database.

Tags: size `[cheap|medium|big]` · orbit `[core|adjacent|wild]`. 58 ideas across 6 axes; the only
filtering is the top-10 shortlist at the bottom.

---

## A. Plugin packaging shapes

1. **In-repo `.claude-plugin/plugin.json`** — the repo IS the plugin: existing `.claude/commands/u-*.md`
   + `.claude/skills/unimatrix/` move (or symlink) under the plugin manifest, so `/u:call` colon
   namespacing finally works. `[cheap] [core]`
2. **Self-marketplace** — add `.claude-plugin/marketplace.json` to this same repo so
   `/plugin marketplace add <path-or-repo>` then `/plugin install unimatrix` works from any session,
   no second repo to maintain. `[cheap] [core]`
3. **Local-path marketplace vs GitHub marketplace** — install from `~/code/unimatrix` (edit-in-place,
   instant iteration, single-operator) *or* from the public GitHub remote (reproducible, versioned,
   shareable). Pick per-account, or run local on the dev box and GitHub everywhere else. `[cheap] [core]`
4. **Plugin ships commands + skill only; the engine stays a repo checkout** — `plugin.json` gives you
   `/u:*` and the skill everywhere, and every command shells out to a configured
   `UNIMATRIX_HOME=~/code/unimatrix`. Avoids vendoring 5.4k lines of bash into a plugin payload. `[cheap] [core]`
5. **Plugin ships the engine too (bash under `scripts/`)** — one install unit, `${CLAUDE_PLUGIN_ROOT}`
   resolves the scripts; the plugin becomes self-contained and installable on a fresh box with no
   git clone. Costs: two copies of the engine if the repo is also checked out. `[medium] [core]`
6. **Hooks in the plugin** — a `SessionStart` hook that registers the current repo into a fleet registry,
   and/or a `PreToolUse` guard that refuses `.bus` on a `/mnt/*` path. Ships doctrine as enforcement,
   not documentation. `[medium] [adjacent]`
7. **Bundled subagent(s)** — plugin `agents/` carrying a `unimatrix-operator` (monitor/troubleshoot a live
   run) and `unimatrix-planner` (decompose → wave plan), so `/u:*` isn't the only entry point. `[medium] [adjacent]`
8. **Multi-account rollout script** — `install.sh --all-accounts` loops `~/.claude-acct/*/`, adds the
   marketplace + installs the plugin into each account's config, idempotent, re-runnable after every
   version bump. `[cheap] [core]`
9. **Plugin version = repo semver, cut by the existing release flow** — `plugin.json.version` bumped in
   the same commit as `CHANGELOG.md`; `docs/releasing.md` grows one line. Zero new release ceremony. `[cheap] [core]`
10. **`unimatrix doctor --plugin`** — checks: manifest parses, marketplace reachable, every account has
    the plugin enabled at the same version, `UNIMATRIX_HOME` resolves, skill file not diverged between
    repo copy and installed copy. Catches "it works in this session only". `[medium] [core]`
11. **Deprecate the `/u-*` filename-prefix commands once `/u:*` lands** — keep both for one release with
    a deprecation line in the `-` variants, then delete. Prevents two divergent command surfaces. `[cheap] [core]`
12. **Split plugins: `unimatrix` (engine+commands) and `unimatrix-cockpit` (server+UI+sink)** — so a
    lightweight account can have the commands without the reporting stack. Probably premature, but it
    is the natural seam if the cockpit grows deps. `[medium] [wild]`

## B. CLI evolution

13. **`unimatrix install`** — one verb that does the whole box: symlink `unimatrix` onto `$PATH`
    (`~/.local/bin`), write `~/.config/unimatrix/config` (`UNIMATRIX_HOME`, `ENV_MASTER_FILE`), add the
    marketplace to every account. The lazy alternative to a README with 9 manual steps. `[cheap] [core]`
14. **Bash + zsh completion** — a single `unimatrix completion bash|zsh` emitting a completer for verbs,
    lane names (`glm:glm-5.2`, `grok`, …), and live run ids read from `.bus*/`. Lane-name typos are a real
    recurring failure. `[medium] [adjacent]`
15. **`unimatrix doctor` grows an install/plugin section** — today it probes lanes (spec 13); extend to the
    *installation* itself: PATH, config, plugin, bus filesystem type (`stat -f -c %T` must not be
    `9p`/`fuseblk`), node version for the cockpit, `mysql` client presence when the sink is enabled. `[medium] [core]`
16. **`unimatrix here`** — bootstrap the current repo for swarm use: create `.bus` on a verified local fs,
    seed `swarm.conf` from the example, add `.bus*` to `.gitignore`, print the cockpit URL. The
    "any-cwd" promise finished. `[cheap] [core]`
17. **`unimatrix cockpit [--port] [--open]`** — a first-class verb that starts/attaches `site/server.mjs`
    (systemd-run or plain background), instead of the operator remembering the invocation. `[cheap] [core]`
18. **`unimatrix report`/`export`** — one verb family over the evidence: `report speedwars`, `report cost`,
    `report failures`, `export --json|--sql|--csv`. Everything downstream (MySQL, brain, a static page)
    consumes this one output, so there is exactly one reader of the JSONL. `[medium] [core]`
19. **Single self-contained `unimatrix` launcher that can bootstrap itself** — `curl … | bash` clones the
    repo to `UNIMATRIX_HOME` and runs `install`. Only worth it if the repo ever goes public-public. `[medium] [wild]`
20. **Man page / `--help` per verb from the specs** — generate `unimatrix help call` out of
    `specs/15-direct-call.md` headings so help can never drift from the spec. `[medium] [wild]`

## C. Cockpit-as-product (single operator, fleets of swarms)

21. **Multi-bus view ("fleet wall")** — today the server serves one `BUSDIR`; scan a registry (or
    `~/code/*/.bus*`) and show every live run across every repo on one wall, one row per run, colored by
    state. This is the single biggest jump from "one run's cockpit" to "an operator's cockpit". `[big] [core]`
22. **Run history browser** — a fourth/fifth view listing *finished* runs (from `.bus/archive/` +
    `speedwars.jsonl`) with drill-in to the same drawer that live runs use. Cross-run memory is the thing
    the cockpit structurally lacks today. `[medium] [core]`
23. **Cost/lane analytics page** — $ per verified-done by lane and complexity, pool-vs-real-$ split, burn
    over time, "which lane would have been cheaper for this card class". Speedwars already stores the
    columns; nothing renders them cross-run. `[medium] [core]`
24. **Failure taxonomy dashboard** — spec 12 already writes failure evidence; render it: top failure
    classes by count over the last N runs, per-lane false-done rate, park reasons, time-to-first-park. `[medium] [core]`
25. **Lane health timeline** — a strip chart per lane: usable / limited / dead / broken over time,
    overlaid with quota resets (the Z.ai quota endpoint is already known). Answers "is glm shaky again
    or is it me". `[medium] [adjacent]`
26. **Run diff / replay** — pick two runs of the same card set and diff outcomes, wall time, cost,
    files-touched. Turns speedwars from a table into an argument. `[big] [adjacent]`
27. **Operator inbox** — one merged feed of things that want a human: parked cards, budget gates hit,
    false-done verdicts, new `feedback/` drops, untriaged backlog items. The cockpit becomes the place
    you *start*, not the place you check. `[medium] [core]`
28. **"Should I have run this?" retro card** — per finished run: claimed vs verified, $ spent, human-time
    saved estimate (complexity rubric already has `est_human_min`), verdict. One card, honest. `[cheap] [adjacent]`
29. **Cockpit as a static export** — `unimatrix report --html` writes a self-contained page (no server)
    for archiving a run's evidence next to the commit, or pasting into a Claude Artifact. `[cheap] [adjacent]`
30. **Mobile/phone view** — the ops wall degraded to a single-column "what needs me" list; Robert walks
    away from the desk while a 40-minute wave runs. `[medium] [wild]`
31. **Push notifications on run close / park** — reuse the existing push channel rather than building
    one; the cockpit stops being a thing you must be watching. `[cheap] [adjacent]`
32. **Cockpit auth appears only when exposure does** — stays `127.0.0.1` by default; going remote means a
    Cloudflare Tunnel + Access in front, never app-level auth code in `server.mjs`. `[medium] [adjacent]`

## D. MySQL mirror designs

33. **Event-sourced ingest from `run-*.jsonl`** — the JSONL files stay the source of truth; MySQL is a
    projection that can be dropped and rebuilt from `.bus/archive/` at any time. Rebuildability is the
    property that keeps the DB from becoming load-bearing. `[medium] [core]`
34. **Schema sketch** — `uni_run` (run id, repo, mode, started, ended, done_n, parked_n, cost),
    `uni_branch` (card id, lane, model, outcome, wall_secs, tokens, cost, wrc, pinned),
    `uni_event` (raw JSONL row: run, card, ts, type, json payload), `uni_verdict` (claimed vs verified),
    `uni_review` (subjective score/tags), `uni_lane_health` (lane, state, ts), `uni_feedback`
    (drop-box items + triage state). Natural key everywhere = `(run, id, ts)` so ingest is idempotent. `[medium] [core]`
35. **On-close batch export (no daemon)** — `_finalize_run` calls `unimatrix export --sql` and pipes it to
    the `mysql` client; if the client or credentials are absent it's a silent no-op. Zero daemon, zero npm
    dependency, exactly the doctrine-shaped answer. `[cheap] [core]`
36. **Cockpit-server-side writer** — the already-running `server.mjs` also tails and writes to MySQL.
    One process, but it makes the cockpit stateful and couples "am I watching" to "is it recorded". `[medium] [adjacent]`
37. **Standing sync daemon (`uni-sink`, systemd user unit)** — watches all registered bus dirs and
    streams into MySQL continuously; gives near-live cross-repo reporting at the cost of a standing
    process (explicitly "ask first" territory). `[big] [adjacent]`
38. **`.sql` spool directory** — runs write `evidence/<run>.sql` and *something else* (cron, brain, the
    operator) loads them. Fully decoupled, survives the DB being down, trivially auditable. `[cheap] [adjacent]`
39. **HTTP ingest instead of a DB driver** — POST the run-summary JSON to a fleetops endpoint in brain and
    let brain own the schema, migrations, and MySQL entirely. Unimatrix never learns SQL. `[cheap] [core]`
40. **`mysql` CLI over an npm driver** — heredoc/`--defaults-extra-file`, no `mysql2` dependency, keeps
    the cockpit's zero-dep property intact. Credentials come from `~/s/.env.master` via the existing
    least-privilege grep, never sourced. `[cheap] [core]`
41. **Idempotent replay + content hash** — every row carries a hash of the source JSONL line; re-ingesting
    an archive is a no-op. Makes "backfill everything from 2026-07-19 onward" a safe single command. `[medium] [core]`
42. **Retention/rollup** — keep `uni_event` raw for 90 days, keep `uni_branch`/`uni_run` forever. Prevents
    the mirror becoming the biggest table in the brain DB. `[cheap] [adjacent]`

## E. Fleetops integration

43. **Session marker as the join key** — the statusline already derives a deterministic per-session emoji
    from the session id; stamp `session_id` + marker into every run's `run-summary` so a swarm run joins
    to the session that launched it. One column, huge payoff. `[cheap] [core]`
44. **Per-repo fleet registry** — `~/.config/unimatrix/fleet.json`: repo path, bus dir(s), default
    `swarm.conf`, cockpit port. Written by `unimatrix here`, read by the fleet wall, the sink, and doctor. `[cheap] [core]`
45. **Account dimension** — every run records which `~/.claude-acct/*` orchestrated it, so quota burn is
    attributable per account (the actual scarce resource in a multi-account setup). `[cheap] [core]`
46. **Brain reporting join** — `/monitoring/swarms` in brain-web next to the existing `/monitoring/llm`,
    joining `uni_*` to brain's own LLM run tables so one page answers "what did all my agents cost me
    today". `[big] [adjacent]`
47. **Feed the manual-run ledger** — unimatrix spend rows become entries in brain's
    `llm-manual-runs.ts` / `docs/ops/llm-manual-runs.md` lockstep pair, satisfying the global
    run-evidence rule automatically instead of by hand. `[medium] [core]`
48. **Fleetops → unimatrix direction (remote trigger)** — fleetops can *start* a swarm in a registered
    repo (queue a card, not spawn a worker) — the bus is a directory, so "enqueue" is a file write. Big
    security surface; note it, don't build it yet. `[big] [wild]`
49. **Shared taxonomy** — unimatrix's failure taxonomy (spec 12) and fleetops' session/incident vocabulary
    should be one enum, defined once, or the joins produce two languages for the same event. `[cheap] [adjacent]`

## F. Wild cards

50. **SQLite via `node:sqlite` (Node ≥22 built-in) instead of MySQL for local history** — durable
    cross-run reporting with *zero* new dependencies and no server; MySQL then only earns its keep for
    the cross-repo fleet join in brain. Strongest ponytail candidate in the whole doc. `[cheap] [wild]`
51. **DuckDB over the raw JSONL** — no ingest step at all: `duckdb -c "select … from
    read_json_auto('**/speedwars.jsonl')"`. Analytics without a schema, at the cost of a new binary. `[cheap] [wild]`
52. **Grafana/Metabase on the `uni_*` tables** — don't build charts, point an existing tool at the mirror.
    Trades cockpit polish for zero chart code. `[medium] [wild]`
53. **Webhooks out** — a `WEBHOOK_URL` fired on run close/park; lets anything (fleetops, Slack, a phone)
    subscribe without unimatrix knowing about it. `[cheap] [wild]`
54. **Public speedwars leaderboard** — the existing static site (`site/`, already Cloudflare-deployed)
    publishes anonymized lane-vs-lane results. Marketing for the tool, and an honest public benchmark. `[medium] [wild]`
55. **The cockpit becomes the plugin's UI** — a `/u:cockpit` command that opens the local URL and the
    skill teaches Claude to read `/api/*` directly, so the model can *see* the run state instead of
    parsing bus files. `[cheap] [wild]`
56. **Self-hosted feedback→backlog loop in the DB** — `uni_feedback` + a triage view replaces the manual
    `feedback/` → `docs/research-backlog.md` sweep. Risk: the markdown drop-box works *because* agents in
    other repos can write it with no infrastructure. `[medium] [wild]`
57. **Anomaly alerts** — "this lane's false-done rate doubled this week", "glm cost/token drifted"; the
    ledger has enough history to make these boring statistical checks, not ML. `[medium] [wild]`
58. **Cost forecast before spend** — pre-run estimate from historical speedwars medians for the same
    complexity+lane, shown at plan time; the budget gate stops being a surprise. `[medium] [wild]`

---

## Top 10 shortlist (my own picks — divergent stage, so these are bets not decisions)

| # | Idea | Why it earns a slot |
|---|------|---------------------|
| 1 | **#1 + #2 in-repo `.claude-plugin` + self-marketplace** | Unlocks true `/u:*` and cross-repo availability — the literal ask — and the files already exist; this is a manifest, not a rewrite. |
| 2 | **#4 plugin ships commands+skill, engine stays a checkout** | Keeps one copy of 5.4k lines of bash. Vendoring the engine into a plugin is how the two surfaces drift. |
| 3 | **#8 multi-account install loop** | Five accounts × manual install = guaranteed version skew. Idempotent script or it doesn't get done. |
| 4 | **#43 session marker as the join key** | One field in `run-summary`. Without it, no swarm run can ever be attributed to a session, and every fleetops idea downstream is blocked. |
| 5 | **#44 fleet registry** | The one shared artifact the fleet wall, the sink, and doctor all need. Cheap now, expensive to retrofit. |
| 6 | **#33 + #41 event-sourced, rebuildable, idempotent mirror** | The only mirror design that keeps the JSONL authoritative. Non-negotiable if the DB is ever going to be dropped and rebuilt (it will be). |
| 7 | **#35 + #40 on-close export via the `mysql` CLI** | No daemon, no npm dep, no-op when absent. Delivers durable reporting while every hard constraint stays intact. |
| 8 | **#21 multi-bus fleet wall** | The actual product jump. Everything else is one run's cockpit; this is an operator's. |
| 9 | **#22 + #23 run history + cost/lane analytics** | Speedwars already writes the columns and nothing reads them cross-run. Highest value per line of new code in the whole cockpit. |
| 10 | **#50 `node:sqlite` for local history** | Must be *tested* before the MySQL work, not after. If a built-in gives durable cross-run reporting for free, MySQL's scope shrinks to the brain join alone — a much smaller, safer build. |

**Honourable mentions:** #39 (HTTP ingest — could delete the entire MySQL scope from this repo),
#27 (operator inbox), #15 (doctor covering the install itself), #24 (failure taxonomy dashboard).

**Explicitly parked as traps:** #37 standing sync daemon (violates "ask first" for marginal gain over
#35), #48 fleetops→unimatrix remote trigger (real security surface, no demand yet), #56 DB-backed
feedback loop (the markdown drop-box works *because* it needs zero infrastructure).
