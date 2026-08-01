# Changelog

All notable changes to this project are documented in this file.
Format based on [Keep a Changelog](https://keepachangelog.com/), versioned with [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.5.0] - 2026-08-01

### What's new (for humans)
- **The swarm no longer goes idle between waves**: finished pools can wait around for
  late-added tasks instead of forcing you to relaunch the whole engine — on a real run this
  idle waiting was 60% of the total time.
- **A healthy AI lane can't be benched for 30 minutes by one slow health check anymore** —
  checks get realistic time budgets, a failed check is a short 10-minute flag with the real
  error attached, and a long bench now needs two separate tasks to fail.
- **You can now see exactly where a run's time went**: a new `timeline` command shows each
  task's waiting time, work time, retries and pauses, plus the gaps and the slowest task —
  no more detective work with file timestamps.
- **Tasks that were doomed to fail their folder rules are stopped instantly** at hand-out,
  before any AI time or money is spent.
- **Launching from the wrong folder is now recoverable in one step** — a new `--busdir`
  flag pins the workspace explicitly, and error messages point at the workspace you
  probably meant, name the missing key, and print the exact fix line to copy-paste.

### Added
- **`POOL_LINGER_SEC`** (spec 21 FR-1, backlog 79) — a drained pool keeps polling `queue/` for N seconds before closing, so late adds (dependent cards, review/fix waves) are served by the same invocation instead of a full engine relaunch. Default 0 = today's behavior; `swarm-loop` force-overrides 0 (relaunch-per-iteration is its design). bh065 evidence: 60% of a 41-min run was idle bus between relaunches; live smoke: late add served 12s after `swarm-ctl add`.
- **`--busdir <path>` flag** (spec 21 FR-6, backlog 77) — pins the bus by path with env-var authority, for orchestrators whose shell cwd cannot be trusted; the empty-run abort now also names an existing `.bus-<label>` at the git toplevel as a hint (FR-7). `--help`/`-h` now actually print usage (and exit 0).
- **`PROBE_TIMEOUT_SEC` + probe/bench fidelity** (spec 21 FR-2..5, backlog 76) — claude joins codex at a 30s cold-start probe cap; a probe FAIL benches 600s (not 1800s) with the probe's failure text + a `diag=limits/<lane>.probe-stderr` pointer; the finalize bench points at `run-<id>.jsonl.stderr`; **`BROKEN_MIN_CARDS`** (default 2) gates the 1800s bench on distinct-card evidence, and the `.failcards` counter resets on the lane's next successful finalize (recovery clears evidence, like `.broken`).
- **Claim-time cage preflight** (spec 21 FR-9, backlog 80) — a write card whose `.files` manifest resolves outside its cage parks instantly as `cage-denied`, before any worker spend.
- **Claim stamp + `queue_wait_secs`** (spec 21 FR-10; spec 08 FR-10 promoted) — every claim writes `limits/<id>.claimed-at`; speedwars rows gain additive `claim_ts` + `queue_wait_secs` keys. Only the claim's terminal row (done/timeout-salvaged/parked) consumes the stamp, so a pinned card's failed-attempt AND parked rows both carry the keys.
- **`swarm-ctl timeline <run|busdir>`** (spec 21 FR-11, backlog 81) — read-only per-card timeline (queue-wait, serve, attempts, lane walks, park reasons) plus run footer: total span, idle invocation gaps, critical-path card.
- **`top_wall` in run-summary rows** (spec 21 FR-12) — top-3 wall-clock sinks, surfaced by `swarm-ctl postmortem` with no reader change.
- **`LANE_MAX_<LANE>` per-lane in-flight caps** (spec 21 FR-13, backlog 82) — a capped lane is skipped at claim (never wedges the pool).

### Changed
- **Longest-job-first claiming** (spec 21 FR-14) — `queue/*.prompt` is claimed in descending byte-size order (long cards stop becoming the accidental critical path).
- **`FANOUT` baked default 4 → 6** (spec 21 FR-15) — buses are per-run namespaced since spec 20.
- **env-master resolution** (spec 21 FR-8, backlog 78) — one `_env_master_path` resolver for preflight and per-key grep: explicit `ENV_MASTER_FILE`, else `$XDG_CONFIG_HOME/unimatrix/env.master`, else `$HOME/s/.env.master`; the preflight abort names the needed key(s) and prints a copy-paste export line.

## [1.4.0] - 2026-07-29

### What's new (for humans)
- **Starting a swarm from the wrong folder can no longer silently do nothing**: the run now
  lives where you launch it, and a run that finds no work refuses loudly instead of quietly
  "finishing" an empty list.
- **A task with a blank "where to write" note is caught the moment it's seeded** — previously
  it burned a two-minute wait per task before failing in a way only an expert could read.
- **Fast-but-sloppy AI lanes can't take credit for a teammate's edits anymore**: in a shared
  folder they must name the files they will deliver up front, or work in their own folder —
  "done" with nothing written now fails on the spot.
- **A new one-command preflight checks every queued task card for mistakes** (blank fields,
  missing folders, misspelled lane names) before any AI is spawned or any money is spent.
- **The operator guide now says which AI to use for what**: an evidence-backed cheat sheet per
  lane — real speed and reliability numbers, not vibes.

### Added
- **`swarm-ctl lint-specs [busdir]`** — read-only preflight over specs/ + queue/ cards: empty prompts/sidecars, missing write targets, invalid `.files` manifests, bad lane/chain tokens — catches seeding mistakes before any spawn.

### Changed
- **`--run <label>` now derives the bus at the caller's cwd** (`PWD/.bus-<label>`, matching the call verb) — launch from the target repo; explicit `BUSDIR` still wins (spec 20 amendment).
- **A run whose bus holds zero queued, claimed, or done cards after enqueue now aborts loudly** instead of closing clean — the cross-repo empty-sweep trap (spec 20 amendment).
- **Shared-cage write cards on lanes without tool-use journals** (grok/codex/gemini) are rejected at the diff gate unless they carry a `.files` manifest — closes the narration false-done class the write-journal gate cannot see on those lanes (spec 14 FR-8 amendment).
- **The specs/ sweep refuses cards with empty prompt or sidecar files**, and an empty `.write` in queue/ parks instantly (`write-target-empty`) instead of waiting out the 120s target wait (spec 01/14 amendments).

## [1.3.0] - 2026-07-26

### What's new (for humans)
- **Run several swarms at once without them trampling each other**: start each with
  `--run <name>` and every run gets its own workspace, its own cost ledger, and a guard that
  refuses to start on top of a run that's still alive.
- **Dead AI lanes are caught in seconds, not minutes**: before the first task goes to a lane,
  a one-token health check runs automatically — a lane whose login expired is routed around
  instead of eating three failed attempts per task.
- **A worker can no longer take credit for a teammate's work**: when two tasks share one
  folder, each must show its own edits to count as done — "I did it" with nothing written now
  fails loudly.
- **Honest prices on every lane**: costs are now computed at each provider's own price list
  (one lane was billed at ~3× the right price at the wrong provider), and every cost row says
  where its number came from.
- **Fewer mystery failures**: a hand-written shorthand lane name no longer crashes the
  provider, simultaneous logins no longer trip each other at startup, and the codex reviewer
  now runs at full reasoning strength instead of silently at none.

### Added
- **Plan-005 wave 0 — six spec rulings landed** (all authored by the haiku prose-trial lane,
  cross-verified by codex, adjudicated + gate-fixed by the orchestrator): spec 10 FR-R15 (bare
  sidecar tokens resolve loudly at `lane_cmd`), spec 13 FR-6 (event-fired auto live-probes,
  once per lane per run), spec 04 amendment (codex scratch-home `config.toml` mirror — fixes
  silent `reasoning_effort:none` on bus-spawned review cards — plus same-lane first-spawn
  stagger), spec 08 amendment 2026-07-26b (uniform `tokens_reasoning` extraction), spec 14
  FR-8 (per-card write-journal so shared cages stop blessing zero-write cards), and NEW spec
  20 (Draft then, activated same day — see the `--run` entry below): per-run bus namespacing via
  one `--run <label>` with live-heartbeat collision refusal (backlog 11/21).
- **USD-as-proxy pricing on every lane** (spec 08 amendment 2026-07-26, operator directive):
  every speedwars row now carries a `cost_usd` at the serving provider's OWN list price plus a
  `cost_basis` tag (`envelope-list` / `envelope-pool` / `recomputed-list` /
  `unpriced-tier-unknown`) — subscription and quota lanes included, so dollars become the
  cross-lane proxy for pool draw. codex is now priced (gpt-5-codex list, fresh-vs-cached input
  split); grok gets a recomputed fallback when the envelope omits its pool estimate; gemini
  stays deliberately unpriced until the key's tier is recorded.
- **`--run <label>` — concurrent swarms stop colliding on one bus** (spec 20, Active; backlog
  11/21): one flag atomically derives `BUSDIR=.bus-<label>` and `SPEEDWARS_RUN=<label>` on both
  `swarm-run.sh` and `swarm-loop.sh` (loop iterations pass it through), so the two can never
  drift apart again; explicit env vars still win per the spec 04 precedence doctrine. A bus whose
  spec-11 heartbeat is live (<60s) refuses new work loudly — accidental double-invocations die at
  the door, while stale buses resume; swarm-loop's own iterations assert ownership of their
  parent's bus via `UNIMATRIX_BUS_OWNER=1`. `call` honors the derivation too (it no longer
  clobbers it with its cwd-local default). Ground Control's multi-bus fleet view is staged as its
  own cockpit wave (spec 20 FR-7).
- **Dead lanes are caught before any worker spawns** (spec 13 FR-6, backlog 58): `doctor
  --live`'s probes now fire automatically — once per lane per run, at the lane's first claim
  (pre-claim) and on a lane's first instant-error (reactive) — feeding the existing
  `.broken`/`.dead`/`.limited` routing. A card seeded onto a dead cheap lane fails over
  immediately instead of burning `MAX_LANE_RETRIES` there first (run brain058 seeded 8 cards
  grok/glm-first and executed 0 there — this closes that hole). New conf knob `PROBE_AUTO`
  (default 1); probes never rewrite existing health markers; each billable probe lands in the
  run ledger.

### Fixed
- **Shared write cages no longer bless narration-only cards** (spec 14 FR-8, backlog 59): two
  cards sharing one `.write` target used to satisfy each other's diff gate — a worker that only
  talked finalized `done` on its sibling's bytes (the W3D1 false-done shape). The gate now derives
  each card's own write-journal from its archived worker stream (claude-binary lanes) and, in a
  shared cage, requires the card's OWN surviving in-cage writes; an empty journal fails loudly
  with the W3D1 signature named. Finished siblings count as sharing too (their archived
  `write-*.txt` sidecars), closing the fast-writer race.
- **Same-lane auth herd tamed** (spec 04 amendment 2026-07-26, backlog 20): N simultaneous first
  spawns on one lane used to hit the provider's auth gate at t=0 ("Not signed in" ×4, grok,
  live). The first worker per lane per run now starts alone; same-lane followers wait — bounded
  by new conf knob `STAGGER_FIRST_SPAWN_SEC` (default 10s, 0 = off) — until the first worker
  produces output, then launch unrestricted. Cross-lane parallelism untouched.
- **Bus-spawned codex workers no longer run at `reasoning_effort:none`** (spec 04 amendment
  2026-07-26, backlog 49): the codex scratch-home cage copied only `auth.json`, so the caged CLI
  ignored the operator's `~/.codex/config.toml` and silently fell back to no reasoning — a
  quality downgrade on every REVIEW-lane card. The codex arm of `_scratch_home` now mirrors
  `config.toml` when present. Codex arm ONLY: grok's config exclusion stays a locked containment
  decision (its config wires MCP servers into the cage), claude's arm is untouched.
- **Bare sidecar lane tokens no longer 400 the lane** (spec 10 FR-R15, backlog 62): a `.lane`/
  `.chain` sidecar holding `glm` or `kimi` without `:model` used to reach the provider as a
  literal model id (Z.ai 1211 / Moonshot 404), burn all retries, and mark the lane broken —
  this was the entire "glm HTTP-400 unreliability" cluster. `_try_claim_one` now normalizes
  bare tokens through `_call_lane_token` with one loud stderr line before any claim, which also
  keeps claim filenames parseable by `_claim_meta` (bare-token claims used to return an empty
  lane and blind the reap/liveness guards).
- **glm cost was priced at the wrong provider**: the lane rides the claude binary, so its
  envelope `total_cost_usd` is Anthropic-list pricing against a swapped base URL. glm rows are
  now always recomputed at Z.ai API list ($1.40/$0.26/$4.40 per M) — the operator's local
  ledger backfill showed the old figures overstated glm ~3× ($109.41 claude-priced → $34.89
  Z.ai-list across 130 rows).
- `docs/lane-economics.md` decision table: claude and gemini rows claimed "no dedicated
  failover arm" — those arms shipped with spec 10 FR-R8 (`limit_error()`); table now points at
  the live code, and ledger-wording column updated for dollars-as-proxy.

## [1.2.0] - 2026-07-26

### What's new (for humans)
- The swarm's commands now work from **any project on your machine** — type `/u:call` or
  `/u:swarm` in any repo and the one installed engine answers; a single `unimatrix install`
  sets everything up and keeps every account in sync.
- Every run now ends with a three-line answer to "which AI was worth it": cost per **verified**
  result, how slow the slowest typical task was, and how often each AI claimed "done" falsely.
- A task nobody double-checked is now honestly labeled "unjudged" instead of quietly counted as
  a success — the cost numbers stop flattering unverified work.
- Every run's raw evidence (transcripts, answers, status markers) is automatically archived
  compressed, so you can audit any past run even after its workspace is deleted.
- A new `unimatrix report --html` produces a single self-contained web page of the speed/cost
  report you can open or send anywhere.
- New repos join the swarm with one command (`unimatrix here`), which also refuses unsafe
  network filesystems before they can corrupt coordination.
- The system now tells you when something is stale: a run banner and the dashboard can no
  longer disagree about which checkout is running, and an outdated dashboard restarts itself.
- For the data-minded: the evidence database contract is published (versioned, with fixtures),
  so external tooling can consume run telemetry without reading unimatrix source.

### ADDED
- **One canonical verdict-fold for speed evidence (P0-FR7).** The `/speedwars` report and the
  cockpit's SPEEDWARS tab computed "$ per verified-done" differently — the report even counted
  every unchecked done-claim as verified. One contract fixture (`tests/fixtures/verdict-fold/`) now
  pins the semantics and both renderers replay it in tests. Operator-visible: cards without a
  verdict now show as UNJUDGED (never verified), the join accepts lane-less verdict rows, the unit
  is the card not the retry-attempt, and $/verified-done prices in failed attempts. New
  `src/speedwars-report.sh --json` emits the canonical aggregates.
- **Run banner + cockpit `/health` now report the same four fields** `{root, branch, head,
  busdir}` (P0-FR4) — a wrong-worktree dispatch is visible in one line on both surfaces.
- **`check.sh` gains a DB-symbol gate over the four engine scripts and a general host-path gate
  over tracked content** (P0-FR5), both proven by planted-line tests (`tests/check-gates.bats`).
  The three security gates always run first, unconditionally, ahead of shellcheck/bats (a red
  test suite or a lint error must never short-circuit them via `set -e`); the test-only escape
  hatch `CHECK_SKIP_BATS=1` prints a loud triple-line warning naming exactly what it skips
  (including the traversal/write-cage security tests bats itself carries).
- **Three-line lane summary at every run close (P2-FR1).** $/verified-done, p95 wall, and
  false-done rate per lane, derived from the canonical verdict-fold (`speedwars-report.sh --json
  --run <label>` — never a second aggregation), every figure with its denominator. Never fails a
  run. Live-proven on a real run. `SPEEDWARS_AUTO=0` additionally suppresses this summary and the
  bus archive below, not just per-card ledger rows — turning it off silences the whole run
  close-out.
- **Bus archives (P2).** Run close now archives raw evidence to `docs/ops/bus-archives/<run>/`
  (zstd, gzip fallback): run JSONL + rotations + stderr, answers, the marker tree as one tar, the
  run's ledger slice, a MANIFEST. Gitignored (worker output may carry fetched content); tracked
  README documents the layout. `BUS_ARCHIVE=0` opts out. This directory is THE backup target —
  the future mirror DB holds zero original data.
- **`unimatrix report [--html]`** — the speedwars report from the router; `--html` writes a
  self-contained static page (embedded canonical JSON + rendered table, zero deps, no network).
- **Stratified figures carry their coverage denominator (P2-FR2)** — "stratified over N of M
  runs — X%" printed live above the complexity strata; coverage was 52% at the 2026-07-25
  measurement (corrected method), well under the 80% bar (`docs/ops/ledger-coverage.md`) —
  the live figure moves and is not quoted here for that reason.
- **fleetops contract v1.0.0 PUBLISHED (D1 contract-first).** `docs/fleetops-contract.md` +
  `sql/uni-schema.sql` + golden emitter fixtures are the versioned producer contract: live
  session join keys (spec 17 FR-7), the run-label resolution rule, the canonical fold as
  normative semantics, domain-split hard-refuse, zero-prompt-text invariants. The Brain-side
  consumer builds against these files; no unimatrix code knows it exists.
- **D2 gate recorded** (`docs/ops/d2-gate.md`): phases P3 (mirror) and P4 (cockpit-online) refuse
  to start unless the 3-line summary changes ≥2 written-down decisions by 2026-08-16 — or the
  project stops cheaply at P2, as designed.
- **`/u:call`, `/u:swarm`, `/u:loop`, `/u:speedwars`, `/u:setup` from ANY repo and any account
  (spec 17, Active).** The checkout is now a self-marketplace (`.claude-plugin/marketplace.json`
  sourcing `./plugin`); the plugin ships generated 3-line pointer stubs + the unimatrix skill
  (symlink — same single inode as the account copies) and never vendors the engine. Live-proven:
  headless `/u:speedwars` from an unrelated repo resolved the engine via
  `~/.config/unimatrix/config` and ran the real report.
- **`unimatrix install`** — one idempotent command: PATH symlink (`~/.local/bin`, overridable via
  `--prefix <dir>`), `~/.config/unimatrix/config` (read-merge-write), marketplace + plugin enabled
  across `~/.claude` and every `~/.claude-acct/*` settings file (single `.bak.unimatrix-install`
  backups, `--dry-run` supported). Second run: zero changes, byte-identical settings.
- **`unimatrix here`** — bootstrap any repo: local-POSIX fs check first (hard refuse on
  9p/drvfs/nfs/cifs naming the fstype), `.bus` subtree, `swarm.conf` seeded, `.bus*` gitignored,
  `~/.config/unimatrix/fleet.json` registry entry, cockpit URL printed.
- **`doctor --plugin`** — manifest/marketplace/UNIMATRIX_HOME resolution checks + per-account
  install-drift table (installed hash vs repo hash), never fatal; runs also print a one-line
  warning when the shipped plugin version drifts from the newest CHANGELOG release.
- **Run rows now carry session identity (spec 17 FR-7):** `run_summary()` stamps `session_id`,
  `session_marker` (bash mirror of the locked statusline formula, drift-pinned by tests), and
  `account` — the fleetops-contract join keys — null-safe when absent.
- `/u-*` filename commands are deprecated in favor of `/u:*` (deletion next release; bare
  `/swarm`-style aliases stay). `check.sh` now regenerates plugin commands into a temp dir and
  fails on drift (generated-commands step).
- **`call` verb (spec 15):** `./swarm-run.sh call <lane[:model]>` — direct single-lane dispatch
  through the full harness (pin or `--chain` fallback, `--write` cage, bulk `--files`/`--batch`
  sharding with per-card files-touched close-out report, bus-local ledger + one aggregate row); an
  unresolvable/empty run label prints `n/a` in that aggregate row rather than a blank or a guess.
- **`unimatrix` umbrella CLI (spec 16):** one git-style router over
  swarm-run/swarm-loop/swarm-mon/swarm-ctl, flattened control verbs, works from any cwd; `/u-*`
  slash-command namespace with alias stubs for the old names.
- **`swarm-ctl unpark <id>...|--all`:** bulk park-storm resume (spares the spec-11
  `takeover.parked` marker).

### FIXED
- **Run join-key derived in one place (P0-FR1)** — `_run_label()` owns the `SPEEDWARS_RUN` /
  busdir-parent rule for speed rows, run summaries, feedback stubs, and review stubs; the default
  derivation warns once per PROCESS (not per bus) with the override hint — a read-only caller
  (review-stub, a report) must not write into the bus at all to record "already warned".
- **One path-resolution order for the `unimatrix` router (P0-FR3):** `$UNIMATRIX_HOME` → its own
  (symlink-resolved) checkout → `git rev-parse`, else a loud failure naming every path tried; zero
  absolute host paths remain in `.claude/`, `site/`, `src/`, or the shell entrypoints. Sourcing the
  router (as its bats harness does) only defines the resolver function — no argv consumption, no
  `set -e`/`shopt`, no exit; dispatch runs solely when the file is executed directly.
- **`unimatrix doctor` never fails the run — diagnostics only.** Account skill copies are now
  converted to symlinks to the canonical repo file (P0-FR2), and doctor gained a `skill-drift`
  row: the ROW can print FAIL (mismatched hash, a copy that isn't a symlink, a broken symlink now
  visible instead of silently counting as "no copies found", or a link resolved outside the repo —
  a sibling git worktree of the same repo is correctly treated as in-repo, not drift), and the
  check is portable (GNU/BSD `readlink`/hashing) — but `unimatrix doctor`'s own exit code always
  stays 0, a diagnostic report, never a gate. Ledger run-meta coverage measured and recorded
  (P0-FR6: 20/38 runs = 52% at the 2026-07-25 measurement, corrected method — UNDER the 80% bar,
  so every stratified figure now carries its coverage denominator; `docs/ops/ledger-coverage.md`).
- **Ground-Control cockpit auto-ensure no longer adopts a stale or foreign process.**
  `mon_web_ensure`'s systemd-run launch now forwards `BUSDIR`/`SWARM_CONF`/`SPEEDWARS_FILE`
  explicitly (a user-manager unit inherits none of the launching shell's env, so `/health` had been
  reporting a busdir the cockpit wasn't actually watching); `/health` (`site/server.mjs`) resolves
  its git head per request instead of once at boot, so a freshness check against it means
  something; a cockpit found running an older HEAD is now stopped and replaced (loud stderr line)
  instead of silently adopted forever.

### DOCS
- **Ops docs refreshed at run close-out.** `docs/fleetops-contract.md` gained a dated addendum
  recording the schema's actual first consumer; no producer-side code changed.

## [1.1.0] - 2026-07-25

### What's new (for humans)
- The swarm now tells you *why* something stopped: every parked or benched marker carries a
  plain one-line reason with a timestamp — no more guessing from file names.
- "You've hit your session limit" is finally understood: the affected model is benched until the
  limit actually resets, instead of silently burning through every fallback.
- A parked task can be re-run with one command (`swarm-ctl nudge`) — no more hand-deleting
  internal files to recover.
- A typo'd or missing output folder now parks just that one task, loudly — it no longer takes a
  whole model lane down with it.
- One busy healthy worker now proves its model lane is alive: a hiccup on a sibling task can't
  bench a working lane for half an hour anymore.
- A task can declare exactly which files it will deliver, so a neighbour's edits are never
  mistaken for its work — and its reviewer sees only its own changes.
- Each model lane can get its own time limit (long reviews, short quick reads) instead of one
  global number.
- Logs from failed attempts are kept, not overwritten — the evidence of *why* attempt one failed
  survives attempt two.
- Restarting the swarm no longer re-runs work that already finished or was cancelled.
- A crashed coordinator can no longer hand a still-running task to a second worker.

### FIXED
- **`doctor --live` false-FAILs on healthy lanes (live drill 2026-07-25, spec 13 amended).**
  *gemini:* the configured model name may be a gemini-CLI alias the REST API doesn't serve
  (default `gemini-3-flash` → REST 404 while the key is fine); on HTTP 404 the probe now falls
  back to an auth-only `models?pageSize=1` GET — 2xx is a PASS annotated
  `auth ok; model '<m>' is a CLI alias unknown to REST` (zero tokens), anything else reports both
  codes. *codex:* probe cap raised 10s → 30s — `codex exec`'s cold start alone regularly exceeds
  10s, so a healthy authed lane FAILed the drill; all other lanes keep 10s.
- **A single non-UTF-8 byte silently corrupted ledger appends.** A stray non-UTF-8 byte in a
  prompt-derived label makes `grep` classify the whole markdown ledger as binary and print
  `binary file matches` instead of line numbers, so `_ledger_append_unlocked` parsed garbage and
  the row landed in the wrong place (observed live, doctor `--live` drill). Text mode is now
  forced (`grep -a`).
- **Parked/limited/dead/broken markers now carry structured one-line reasons.** Every marker
  under `limits/` is written as `ISO-ts | reason-token | retryable=0/1 | ttl=sec | text` (one
  shared producer, fixed token set). Legacy bare-digit TTL markers still parse everywhere
  including the cockpit (spec 14 FR-7).
- **Claude/GLM/Kimi session-limit envelopes now flag lanes with parsed TTL.** When a worker
  encounters a "You've hit your session limit" message, the lane is flagged with a TTL parsed from
  the reset clause, preventing silent chain-walks onto exhausted lanes (spec 14 FR-4).
- **Parking a chain-exhausted card resets its chain position.** `swarm-ctl add`/`nudge` clear
  parked/chain/retry state, so re-published ids no longer insta-park (spec 14 FR-3).
- **Missing `.write` targets now park the card instead of spawning a doomed worker.** A
  `.write` target that doesn't exist bounded-waits then parks the card as `write-target-missing`;
  `swarm-ctl add --write` refuses nonexistent directories (spec 14 FR-5).
- **Lane-level `.dead` flags downgraded when a sibling is provably live.** An auth-death flag is
  downgraded to a short-TTL `.broken` (600s, self-clears on the lane's next successful finalize)
  when another worker on that lane is confirmed healthy, so one bad card stops cooling a working
  lane; the downgraded marker keeps the `auth-death` reason token so classification and feedback
  stubs stay truthful (spec 14 FR-6, amended at cross-review).
- **`swarm-ctl add --files` publishes per-card deliverable manifest sidecars.** Manifests include
  a publish-time trust boundary that refuses absolute paths and escaping entries (spec 14 FR-2,
  publish half).
- **Per-lane `TIMEOUT_<LANE>` conf keys override `WORKER_TIMEOUT_SEC` per lane.** Defaults empty
  (no behavior change); non-numeric timeout values now die loudly at conf load instead of silently
  disarming the watchdog (spec 04 FR-C).
- **Retry attempts rotate `run-<id>.jsonl` to `.jsonl.<n>` instead of truncating.** The prior
  attempt's stream is preserved rather than overwritten (spec 12 FR-D).
- **Spec sweep now skips already-done/cancelled/claimed/queued ids.** Driver re-runs no longer
  re-execute finished work or clobber operator hints (spec 01 FR-B, closes backlog 13).
- **Write-card diff gate now ignores `.git/` churn and directory-mtime bumps.** Uses `-type f` +
  exclusions, aligned with the verify-side twin (spec 10 FR-R11 amendment).
- **Cage-denied cards now park after ONE spawn instead of walking their whole chain.** A worker
  whose read-class tool calls (Read/Glob/Grep/NotebookRead) were denied by the permission cage
  parks as `cage-denied` with a `limits/<id>.cage-denied` evidence marker (count + denied paths,
  never answer text) — every chain rung shares the same cage, so the walk was guaranteed futile
  metered spend (spec 14 FR-1).
- **The write-diff gate and the verify-wave diff are now scoped to the card's own manifest when one exists.** With `queue/<id>.files` present, a neighbouring card's concurrent edit can no longer
  satisfy this card's gate, and the verify prompt shows only this card's deliverables; the manifest
  is archived to `files-<id>.txt` on success. Absent manifest = whole-cage behavior unchanged
  (spec 14 FR-2, both consumers).
- **Reap no longer releases a still-running worker's claim.** Before requeuing a stale-lease claim,
  reap checks the pid table and the run-log freshness — fenced by a hard age cap of
  lease + 2x the lane's resolved timeout, so pid reuse can't make a claim immortal — and every
  requeue (reap and finalize-tail) now names its mover on stderr; heartbeat can no longer
  resurrect a released claim (spec 01 FR-A, backlog 55).
- **A retries-exhausted fast-fail no longer cools a lane for 30 minutes while a sibling worker on
  it is live.** Same sibling-liveness downgrade as the `.dead` guard: the `.broken` TTL drops to
  600s and self-clears on the sibling's finalize (spec 14 FR-6, broken half).

### DOCS
- **Repo cleanup sweep (2026-07-25).** `docs/versions.md` finally documents the kimi lane
  (model pin `kimi-k3`, `MOONSHOT_API_KEY` auth bullet — it had been a fully-wired 6th lane since
  2026-07-23 with no row) and corrects the claude-verify default to `opus`, matching
  `_verify_default_model()`. `specs/README.md` indexes spec 14 (Draft). README links
  `docs/lane-economics.md` (previously unreachable from any index). Deleted: a stale 317KB
  `plans/003-role-tier-fallback/review/w0-w2.diff` working artifact and the unreferenced
  `docs/assets/unimatrix-logo.png` duplicate (`site/assets/` owns the live copy). Run-bus evidence
  dirs (`.bus`, `.bus-*`, 3.3GB) archived to `docs/ops/bus-archives/*.tar.zst` (operator-local,
  gitignored). Feedback drop-box: 2026-07-25 batch (atlas013/parity012/ledger013) triaged to
  backlog 49-53 and archived, filenames + paths scrubbed for the public trunk.

## [1.0.0] - 2026-07-25

### What's new (for humans)
- Ask one question and get it answered by up to six different AI models at once, working in
  parallel.
- A second "keep going until done" mode that iterates on a task through revisions until your
  actual success criteria pass — not until an AI just says it's finished.
- Watch a run live from a terminal dashboard or a browser cockpit — see every agent's status,
  cost, and output as it happens.
- Every run produces a speed-and-cost report, so you can see which AI was fastest, cheapest, and
  most reliable for the job.
- A second AI always double-checks the first AI's work before it's accepted, catching false
  "I'm done" claims.
- When something fails, the system automatically figures out why and drafts a bug report for
  you instead of leaving you to dig through logs.
- Before a run starts, every AI lane gets a quick health check so you don't waste time on one
  that's down, with an optional live check that pings each one for real.
- If a task times out partway through, its partial work is rescued and reused instead of thrown
  away.
- New spending guards stop pay-as-you-go AI lanes from quietly racking up a bill, and you can
  cap total spend per run.
- If the AI running the whole show crashes mid-run, another AI automatically takes over and
  finishes the job.

### ADDED
- **Lane health: preflight, live probes, broken-lane markers, PAYG gate (spec 13, Active —
  `specs/13-lane-health.md`).** `env_master_preflight` (FR-1, backlog 36): `full_run`/`verify_run`/
  `swarm-loop init` now abort loudly (nonzero, resolved path + `export ENV_MASTER_FILE=...` fix)
  BEFORE any spawn when this run's lane set (`EXEC_CHAIN`/`REVIEW`/`REVIEW_CHAIN` tokens + any
  `*.lane` pin) needs an env-key lane (gemini/glm/kimi) and `$ENV_MASTER_FILE` is unreadable — the
  grpnrev incident (a missing env-master path parked an entire run one card at a time). Deliberately
  excludes `VERIFY_MAP`/`PLAN_CHAIN`/`ORCH_CHAIN` despite the spec prose listing them: all three
  bake an env-key lane into their conf_load DEFAULT regardless of `EXEC_CHAIN`, which would trip the
  preflight on every run out of the box — see the function's own header comment. `swarm-run.sh
  doctor --live` (FR-2, backlog 35): plain `doctor` unchanged (always exit 0, zero network calls);
  `--live` adds one minimal authenticated probe per lane — curl `POST /v1/messages` for glm/kimi and
  a `generateContent` REST call for gemini (no CLI spawn), the real CLI under a 10s cap for
  claude/codex/grok — printing `PASS <ms>` / `FAIL <reason>`, exiting nonzero on any FAIL, and
  logging one ledger row per probed lane (no-silent-spend). `broken_flag`/`lane_broken` (spec-lib,
  FR-3, backlog 34): TTL'd `limits/<lane>.broken` marker (1800s default), same mechanics as
  `limit_flag`/`limit_active`, now consulted by `lane_blocked`; a FAILed `doctor --live` probe
  writes it when a busdir exists, and `_finalize_worker` writes it (class `lane-down`) when a lane
  RAN but served no model at all across its bounded `MAX_LANE_RETRIES` budget (the grok brain058
  fast-fail shape) — never on an intermediate retry, only at the genuine failover moment; cleared on
  that lane's next successful finalize, same as `.dead`. `_board`'s `DEAD LANES:` section (spec 12
  FR-6) renders it alongside `*.dead`, suffixed `(broken)`. `PAYG_FALLBACK` conf key (FR-4, backlog
  39, default `warn`): gates a chain-walk FALLBACK hop onto kimi (the one real-PAYG lane) while
  `BUDGET_USD=0` (uncapped) — `warn` proceeds with a loud stderr line + `.fbreason` provenance,
  `deny` routes around kimi exactly like any blocked lane (parking if nothing remains), `allow` is
  today's behavior, byte-identical; `BUDGET_USD>0` is unaffected in every mode (the existing kimi
  budget gate already governs there).
- **Failure evidence & self-learning loop (spec 12, Active — `specs/12-failure-evidence.md`).**
  Failure-class vocabulary (`auth-death`/`api-error`/`server-error`/`rate-limit`/
  `timeout-watchdog`/`spawn-fail`/`false-done`/`no-answer`/`parked-env`): `answer_unusable` now
  echoes its matched class, every non-done speedwars row carries a `class` key. One `run-summary`
  JSONL record per run (branches, done/parked counts, fallback hops, lane flags, wall/cost/stderr
  aggregates) appended at run close. Auto-drafted `feedback/` stubs (`status: draft`, one per
  failure class per run, scrub-by-construction — never embeds worker output; `FEEDBACK_AUTO`
  conf key) from `full_run`/`verify_run` close and `swarm-loop` halts. New `swarm-ctl` verbs:
  `report` (first wired caller of `speedwars-report.sh`), `postmortem` (run-summary reader),
  `review-stub` (pre-filled run-review skeleton, stdout-only). Run-close checklist on stderr.
  `done/<id>` now records the real worker rc (was hardcoded `0`). tmux board shows `DEAD LANES:`.
  Cockpit control verbs additionally audit to `<busdir>/audit.jsonl` (server's single owned
  bus file). `bus_init` seeds `notes-lessons.md`, the orchestrator-only per-run lessons notebook
  (blessed in bus-discipline + skill). Drop-box protocol: machine-drafted stubs are
  confirm-or-delete (`feedback/README.md` §Draft stubs).
- **Orchestrator succession spec (spec 11, Active — `specs/11-succession.md`).** Ratified design
  for the apex fallback: `.bus/heartbeat` + `orch-seat`, `swarm-ctl heartbeat`/`watchdog-arm`/
  `watchdog-check`/`watchdog-disarm` (one tagged crontab line — the sanctioned one-shot-cron
  exception, sign-off 2026-07-24), flock-guarded at-most-once takeover walking `ORCH_CHAIN`
  (`fable kimi`), bounded-mandate kimi continuation driver, `degraded:true` provisional rows +
  `handoff-degraded.md` re-audit gate. New conf keys `PLAN_CHAIN`/`ORCH_CHAIN`/
  `ORCH_TAKEOVER_MIN`. Implementation shipped same round: `swarm-ctl heartbeat` + the three
  watchdog verbs (cron line with baked PATH + absolute script path; spawn-first-seat-on-success
  so a failed driver spawn can never consume the one-shot takeover), PLAN_CHAIN walked and
  logged in the handoff prompt (goal file embedded), driver spawn ledgered (kimi real-$),
  `degraded:true` stamped on done records + every speedwars row under a non-fable seat, and the
  FR-S4 re-audit gate (`swarm-loop` refuses to iterate while `loop/handoff-degraded.md` exists).
  `/swarm-loop` wires it end-to-end: heartbeat every iterate; `LOOP_WATCHDOG=1` arms at run
  start and disarms on every deliberate close — a driver crash deliberately leaves it armed
  (that IS the takeover trigger). ~45 new bats (439 total green), shellcheck ×5 clean.
  Close-out hardening, same round: a background 60s heartbeat keepalive through each pool wait
  (`kill -0`-gated, so a chain walk outliving `ORCH_TAKEOVER_MIN` no longer seats a paid driver
  beside a healthy one, while a real crash still goes stale); the FR-S4 gate passing reclaims a
  non-fable `orch-seat` back to fable (atomic tmp+mv — no permanently-degraded rows, second crash
  detectable again); `_die` and attended resume both clean up a leftover watchdog cron line;
  `watchdog-arm` persists the resolved config plane to `<busdir>/watchdog.env` (`%q`-quoted,
  sourced by env-less cron ticks — right chains/budget/keys, not defaults); cron-line hardening
  (baked quoting, refusal on `%`/quote/newline in PATH or busdir, one `_wd_canon` rule +
  per-user flock across arm/check/disarm); `.claude/`-target refusal now canonicalizes via
  `realpath` so a symlink can't slip the literal regex (backlog-29); write-card verify-diff
  embeds prune the bus tree (`-not -path` on busdir/`.bus*`) so copied worker credentials and
  run logs never ship inside a third-party verify prompt; the succession walk is
  budget-gated (a `BUDGET_USD`-exhausted kimi is skipped, exhaustion parks loudly); and the
  codex lane is read-only by default (backlog-32 — `-s read-only` without a `.write` sidecar,
  `workspace-write` only at a write card's own target; argv-pinned by bats). Live takeover drill
  caught one more: the cron line baked the session's full `PATH` and blew crontab's per-line
  limit ("command too long") with a silent arm loss — the line now carries a fixed minimal PATH
  (session PATH + `CLAUDE_BIN` ride `watchdog.env`), arm verifies the install (rc + re-snapshot,
  loud rc-1) and refuses composed lines over 900 chars.
- **`unimatrix` skill (renamed from `unimatrix-plan`).** Now covers operation, not just
  planning: §6 Operate (invocations, config cheat-sheet, bus layout, monitor/control verbs,
  evidence-first troubleshooting table) and §7 Feedback. Canonical at
  `.claude/skills/unimatrix/SKILL.md`.
- **Cross-repo feedback drop-box (`feedback/`).** Agents in other repos file unimatrix
  bugs/friction/ideas as one markdown file per item (format in `feedback/README.md`); triage
  goes to `docs/research-backlog.md` with attribution, processed files move to
  `feedback/archive/`. The skill §7 carries the absolute path so any repo's agent can find it.
- **Review pair (codex ↔ kimi).** `verify_lane_for` now takes an optional busdir arg and, when the
  resolved verifier is codex or kimi and its limit flag is active, hands review to the other lane
  in the pair — unless the partner is the generator itself (judge != executor stays absolute) or
  also limited, in which case the mapped verifier stays pinned and parks loudly. `write_verify_spec`
  passes its busdir through so the pin reflects the fallback. Default `VERIFY_MAP` now pairs
  `codex:kimi` (was `codex:claude`) alongside the existing `kimi:codex`. Spec: 04-settings FR-15;
  contract: `rules/unimatrix/model-lanes.md` §Review pair. 7 new bats tests.
- **Kimi lane (Moonshot, PAYG Anthropic-compat).** Sixth lane `kimi:<model>` riding the claude
  binary via a child-env swap (the GLM mechanism pointed at Moonshot's endpoint; default model
  kimi-k3, cheaper kimi-k2.7-code). Gated on `MOONSHOT_API_KEY` in the env master; write-capable
  under FR-15 exactly as claude/GLM. The one REAL-dollar lane: ledger and speedwars rows recompute
  cost from envelope usage at Moonshot list prices ($3.00/M in, $0.30/M cache-hit, $15.00/M out) —
  never the envelope's claude-priced `total_cost_usd`. Failover splits quota-vs-rate: quota/balance
  signatures (`exceeded_current_quota_error`, insufficient balance) park 5h with an evidence file;
  plain 429/rate signatures ride a codex-style 2-strike then a short 300s park (PAYG RPM windows
  clear in ~a minute — a 5h park would be self-inflicted downtime). `KIMI_MAX_THINKING_TOKENS`
  caps thinking flood (GLM rat-hole class, but billed as real output dollars here). Cockpit: lane
  chip `M` (#fb923c), kimi model-family pricing, per-lane burn attribution. 21 new bats tests.
  Spec: 04-settings FR-13/FR-14; contract: `rules/unimatrix/model-lanes.md` §Kimi (incl. the
  documented-only subscription variant delta and the ×0.6 temperature quirk); economics:
  `docs/lane-economics.md` (new — subscription-vs-API decision doc for all six lanes).
- **SPEEDWARS cockpit panel (spec 09).** The run-evidence ledger is now a first-class cockpit tab
  instead of a `jq`-only surface: `GET /api/speedwars` (read-only split of
  `docs/ops/speedwars.jsonl` by row type; malformed lines skipped, missing ledger →
  `available:false`, never a 500) plus `site/cockpit/speed.{js,css}` and a 4th header tab.
  Sub-tabs are TOTAL first then one per field — SPEED, COST, RELIABILITY, TOKENS, RUNS — with the
  selection persisted (`unimatrix-sw-tab`). Aggregation is client-side so server and browser can
  never drift into two implementations. Highlights: a narrative verdict line ("fastest grok 17s ·
  cheapest metered grok $0.22 · most refuted grok 6 of 21 judged"), best-in-column ★ guarded by a
  minimum-sample rule, a per-attempt log-scale distribution strip with true decade ticks, the
  refutation wall, a run-over-run trend strip whose missing measurements render as dim gap-ticks
  (never height 0), and a dedup watch for cards that finalized "done" on two lanes (backlog-14).
  Design settled by a 3-proposal judge panel; the ledger's own uneven coverage is shown as absence
  (`not billed` never `$0`, `unjudged` never `verified`, every rate carries its denominator).
  A ledger row is an ATTEMPT, not a card — the panel reports 138 cards across 169 attempts and
  scores trust per card on the lane that delivered its final attempt.
  New tests: `tests/speedwars-api.bats`.

- **Larger-swarms research synthesis.** `docs/larger-swarms.md` — evidence-based recommendations
  R1-R9 for FANOUT 16-32+ (per-run bus namespacing, finalize trust pack, wave-gate
  de-serialization, per-lane budgets, heartbeat liveness, risk-tiered verify) plus a verified
  do-NOT-build list; synthesized from the 2026-07-19 runs, backlog items 1-23, an engine code
  audit, and external research (MAST, Anthropic, Cognition, HiveMind, CONCUR). Addendum A1-A6
  (second independent pass) adds measured numbers: decompose burst tax, host RAM/CPU ceiling,
  GLM 10-way concurrency verified clean, per-lane timeout landmine, ramp/jitter citations,
  deterministic-receipts-before-judge. **Final merged stack (third, adversarial pass)** adds
  corrections C1-C7 and supersedes both build orders: `.write` sidecars carry no allowlist so the
  receipt check can't be built as specified (C1); codex is a verify monopoly on an unprobed lane
  (C2); the per-lane timeout prescription was backwards for codex/grok (C3); parallel
  decomposition refuted by measurement — 24 cards emit in 153s single-burst (C4); receipts can't
  replace prose sampling (C5); R8 hierarchy deleted as architecturally impossible under the
  current permission posture, not merely deferred (C6); the cross-run governor must recompute
  from `pids/*` liveness rather than maintain a counter (C7).
- **Run reviews — standardized post-run review ledger.** `docs/ops/run-reviews.md`: one
  fixed-dimension entry per swarm run (waves×cards, wall/concurrency, done vs false-done vs
  false-timeout vs parked, reviewer findings, orchestrator interventions, lane scorecards,
  backlog filed, next-run change) so runs compare directly; companion to the speedwars JSONL.
  Seeded with aiact-054 (brain plan 054 — first real cross-repo write run: 48 branches, 4 lanes,
  ~40 min wall). Backlog items 9-14 filed from its findings (`docs/research-backlog.md`).
- **Speedwars — per-branch speed-evidence ledger (spec 08).** `speed_row()` appends one JSONL
  row per finalized branch (`docs/ops/speedwars.jsonl`) from every `_finalize_worker` outcome:
  requested vs served lane:model, outcome, real worker rc, pinned flag, wall clock (run-log
  birth→finalize), per-lane usage (tokens in/out/cached/reasoning, notional cost, turns, and
  claude/glm-only duration/TTFT/is_error/api_error_status). Env contract `SPEEDWARS_FILE` /
  `SPEEDWARS_RUN` / `SPEEDWARS_AUTO=0`. Typed side-rows: `run-meta` (C1–C5 complexity rubric),
  `verdict` (claimed-done vs gate-verified — the false-done ledger), `review` (anchored 1–5
  subjective + fixed tag vocab). Grounded in the 2026-07-19 benchmarking-practice research
  sweep; field paths verified against real wave archives of all five lane envelopes.
- **Cockpit redesign — 3-view agent cockpit + control surface (spec 07).** OPS WALL / MISSION
  CONTROL / FLIGHTPATHS + firehose as view 4 (keys `1`-`4`/`Esc`); `GET /api/agents` /
  `/api/loop` / `/api/agent`; `POST /api/ctl` → `execFile` `swarm-ctl` (frozen verb table,
  literal argv); `swarm-ctl nudge` (kill+requeue+OPERATOR HINT), `pause-worker`/`resume-worker`
  (SIGSTOP freeze + frozen-flag reaper skip), `add --lane`/`--write`; agent drawer
  (events/transcript/handoff/spec tabs + NUDGE/KILL/CANCEL); ES-module split `site/cockpit/*`
  (16 files); no-fake-data FR-14.
- **Agent settings drawer + `/api/config` (spec 05).** `site/server.mjs` gains the cockpit's one
  write surface: `GET /api/config` returns an ALLOWLISTED slice of `swarm.conf`
  (`EXEC_CHAIN`, `REVIEW`, `VERIFY_MAP`, `FANOUT`, `MAX_ITERATIONS`, `BUDGET_USD`,
  `WORKER_TIMEOUT_SEC`, `LEASE_MIN`, `MAX_LANE_RETRIES`); `POST /api/config` (`{key, value}`, 8KB
  cap) validates the key against that allowlist and the value against a per-key regex (numeric
  keys, `lane:model` for `EXEC_CHAIN`/`REVIEW`, `lane:lane` pairs for `VERIFY_MAP`; lanes limited
  to `claude|codex|gemini|glm|grok`), then rewrites only the matching `KEY=...` line in
  `swarm.conf` in place (comments and ordering preserved) via a tmp-file + rename. `BUSDIR` stays
  strictly read-only; `swarm.conf` (overridable via `SWARM_CONF` for tests) is the only path ever
  written. The cockpit (`site/cockpit.html`) adds a collapsed-by-default "⚙ AGENTS" drawer in the
  top strip — exec-chain lane/model slots with add/remove, a review lane/model, and numeric run
  limits — each section POSTs its own save and reloads from `GET /api/config`.
- **Live per-model notional cost panel + firehose model chips (spec 06).** New `GET /api/models`
  in `site/server.mjs` returns per-**model** usage (not just per-lane): it parses each
  `run-*.jsonl`, carries the last-seen `model` + `timestamp` forward within a run (the token
  summary events carry neither), normalizes to a family (`claude-opus`/`claude-sonnet`/
  `claude-haiku`/`glm`/`gemini`/`codex`/`grok`; a model-less `turn.completed` ⇒ `codex`, otherwise
  `unknown`), and reports `tokens_5m`/`dollars_5m`/`dollars_per_hour` over a rolling 5-minute window
  (`dollars_per_hour = dollars_5m × 12`) plus a `running` flag (event in the trailing 30s). Dollars
  come from a seeded, tunable `PRICES` table ($/Mtok, **NOTIONAL — a labeled proxy, never a bill**,
  since most lanes are subscription/OAuth pools); a family with no price is flagged `unpriced`, never
  silently free. The cockpit renders a compact **MODELS** strip above the firehose (per-model $/hr +
  tok/5m + a live dot), polled every 5s. The firehose gains a **model chip per row** (carried-forward
  per worker) and now shows a real clock even for the token events that carry no `timestamp` of their
  own — `/api/stream` envelopes gained a server receive-time `ts`, and rows fall back to it. All still
  strictly read-only; degrades with the rest of the cockpit on the public (no-API) deploy.

### CHANGED
- **Grok-first exec order is now the recommended full-lane `EXEC_CHAIN`** (spec 04
  §recommended; maintainer decision 2026-07-24) — the spec-10 diff gate + classifier catch
  grok's false-done class (3/3 live), so speed wins on code cards; prose still pins
  `claude:sonnet`. Shipped stranger-safe default unchanged.
- **Spec 01 FR-12 amended (backlog-30):** a watchdog kill no longer flags the lane `.limited` —
  kill-truncation is not limit evidence; failover stays card-level. Spec 04 gains
  §Validation (backlog-27: `EXEC_CHAIN`/`REVIEW`/`VERIFY_MAP` loud token validation); spec 10
  gains §Round-3 amendments (verify prompts embed the card-scoped diff; `.claude/`-target write
  cards refused at claim). Code for all three lands in the round3 green wave.
- **CLAUDE.md branch docs fixed:** the working trunk is `public` (old `main` is disjoint
  pre-release history).
- **Role classes & universal fallback (spec 10, Active — `specs/10-role-classes.md`).** Every
  spawnable role now has an automatic, qualified fallback: `CLASS_REVIEW`/`CLASS_EXEC`/
  `REVIEW_CHAIN`/`PIN_WAIT_SEC` conf keys (loud validation); the `/swarm-loop` judge is seeded as
  a fallback **chain** (`queue/<id>.chain` orchestrator-pin sidecar walked by the existing chain
  primitives) instead of a hard pin — a limited judge fails over within one poll instead of
  silently stalling the pool gate for up to 5h; judge collisions auto-substitute the first
  qualified class member (amends spec 03's refuse-at-init contract). One shared `_judge_ok`
  guard (author + model-family + role-seat) backs every judge decision incl. `verify_lane_for`'s
  off-map default. `claude`/`gemini` gain `limit_error()` arms + a no-TTL `<lane>.dead`
  auth-death flag (the cal056 OAuth false-done class); pinned-but-blocked cards bounded-wait
  (`PIN_WAIT_SEC`, default 120s) then park loudly. Cross-lane `answer_unusable` classifier
  (short-answer error-envelope signatures) + write-card diff gate (`<id>.stamp`/`find -newer`)
  reject false-dones at finalize. Kimi fallback is `BUDGET_USD`-gated with real-dollar
  `limits/kimi.spend` accumulation (Moonshot-list recompute). `speed_row` gains
  `fallback_reason`/`billing`/`verify_lane`; chain exhaustion emits an auditable
  `outcome:"parked"` row; `/swarm config` prints live per-class lane state. 50 new bats
  (394 total green), shellcheck-clean; live-proven: forced codex-limit → real kimi review
  fallback ($0.0665 metered) and budget-gated park, both end-to-end. Built by the swarm itself
  (dogfood: sonnet/glm/haiku write lanes, codex+glm review, worktree-isolated), reviewed by
  11 codex verify verdicts + 2 lane reviews + codex deep re-review + session code-reviewer +
  simplifier — all findings applied, including a driver-crashing mid-flight-failover CRITICAL
  caught only by the final session review.
- **PRD: role classes & universal fallback (`plans/003-role-tier-fallback/PRD.md`).** Research-backed
  plan for promoting `REVIEW` to a same-class-first fallback chain (codex+kimi), closing the
  pinned-limited-judge 5h stall gap, adding claude/gemini limit detection (`limit_error()` today has
  no arm for either), FR-Rxx set + fallback matrix + spec-10 build phases. Fable roles keep no lane
  fallback by design (park + notify). Research provenance in `plans/003-role-tier-fallback/research/`
  (13-agent swarm digests + 2 late replacement reports). Docs only — no behavior change.
  v2 same day (maintainer-ordered): Fable succession ladder (`PLAN_CHAIN="fable codex kimi"`,
  `ORCH_CHAIN="fable kimi"`, heartbeat + takeover watchdog, role-level judge≠executor exclusion,
  degraded-work-provisional-until-re-audit) + grok-first exec ordering for code cards (spec 11 / W6).
- **Lane speed defaults (2026-07-19 slowness research + telemetry).** GLM lane child env gains
  `MAX_THINKING_TOKENS` (knob `GLM_MAX_THINKING_TOKENS`, default 6000, 0 = no thinking) — live
  telemetry showed GLM wall time 93-97% API wait, dominated by single turns rat-holing into
  60-200k-char thinking blocks (one 629s gap = 68% of a 15.5-min run). Grok lane gains
  `--effort` (knob `GROK_EFFORT`, default `medium`, empty = CLI default high) — grok's default
  `high` costs 10-17s time-to-first-token per turn. ~~Known limit: z.ai Coding Plan enforces ~1
  concurrent request, so parallel GLM branches serialize server-side — schedule one GLM branch at
  a time.~~ **Retracted 2026-07-20:** measured false. A sweep-line over `speedwars.jsonl` shows
  the three 2026-07-19 sessions peaked at 10 simultaneous in-flight GLM calls on one shared key
  with zero 429s and no tok/s or TTFT degradation from concurrency 1→9. The claim traced to a
  third-party GLM-4.7 + opencode report (Jan 2026), not to our own lane. GLM stays the primary
  exec lane at full fan-out; discriminate quota codes ({1308,1310,1316-1321,1113}) from
  rate/overload ({1302,1305}) before ever reading a future GLM 429 as a concurrency cap.

- **MODELS panel: full family coverage + honest notional rates (spec 06).** `normalizeModel`
  (server + cockpit mirror) learns the `claude-fable` family, so a `claude-fable-5` run renders
  as a priced, colored chip instead of a gray raw-string `unpriced` bucket; `MODEL_COLORS` gains
  `'claude-fable':'#f0abfc'`. `PRICES` re-seeded to current public list (2026-07-19): fable 10/50,
  opus 15/75 → 5/25, haiku 0.8/4 → 1/5 (sonnet/glm/gemini/codex/grok unchanged — still NOTIONAL,
  never a bill). New bats coverage pins grok's `end.modelUsage`-key model extraction through
  `/api/models` (family `grok`, priced) and the fable normalization + $10/Mtok pricing.
- **Cockpit hardening + firehose signal-to-noise (spec 05).** `POST /api/config` now rejects a
  hostile-origin write (loopback-only `Origin` check — a page on any site can otherwise fire a
  no-preflight POST at 127.0.0.1:4747), guards against a `key` that shadows `Object.prototype`
  (`Object.hasOwn` instead of bracket lookup, plus a try/catch around the whole async body
  handler so a future throw there can never kill the process), rejects leading-zero/zero numeric
  values, and rewrites every matching `KEY=` line (not just the first) so a duplicate key can't
  leave the written value disagreeing with bash's last-assignment-wins semantics. The cockpit
  (`site/cockpit.html`) now spans the full viewport instead of a centered 1180px column, the
  three AGENTS-drawer sections are a collapsed-by-default accordion, and the firehose collapses
  consecutive `thinking_tokens`/`tool_progress` heartbeats per worker into one row that updates
  in place instead of spamming hundreds of raw-JSON lines — every event type now renders a
  humanized one-line summary (Bash tool_use shows just the command, tool results show their
  first line, `system` events show subtype + salient number) instead of ever falling back to
  raw JSON. New TOOLS/TEXT/THINKING/SYSTEM/PROGRESS + per-worker filter chips (THINKING/PROGRESS
  off by default) are persisted in `localStorage`. Coalescing generalized beyond those two types:
  any rapid same-type run from one worker (matching type + `tool_use_id`/`subtype` where present —
  e.g. grok's `thought`/`text` delta stream) merges into one live row with a blinking spinner that
  freezes the moment a different event breaks the streak; delta-fragment types accumulate their
  text instead of overwriting it. `server.mjs`'s `modelsSummary` (and the cockpit's mirrored
  client-side `modelOf`) also now reads a model name from an event's `modelUsage` object
  key when no `model`/`message.model` field exists — grok's `end` events only ever carried the
  model there, so grok usage was silently landing in the `unknown`/unpriced bucket on the MODELS
  strip.
- **Specs 02/05/06 amendments (spec 07).** Spec 02 FR-7's control-verb list gains `nudge` and
  `pause-worker`/`resume-worker`; spec 05's "no control surface in the web UI (read-only)"
  non-goal is superseded by spec 07's `POST /api/ctl`; spec 06's MODELS strip is relocated to the
  bottom of the OPS WALL view.
- **Cockpit redesign — firehose-first (`site/cockpit.html`):** board + cost collapsed into one
  compact top strip (inline count chips; stale/limits/parked chips hidden unless non-empty; cost
  as an inline per-lane token summary); firehose now takes all remaining viewport height. Firehose
  rows are parsed and humanized (time, branch color, event-type badge, one-line summary — mixed
  claude tool_use/tool_result/text blocks in one record now summarize all of them, not just the
  first; `result`/`item.completed` badges go red on `is_error`/`subtype`/`status`/`exit_code`
  failure signals instead of always green) instead of raw JSON dumps — click a row to expand the
  full record. The feed now clears itself on an SSE reconnect (the server replays the whole bus
  from byte 0 on every new `/api/stream` connection, so a dropped/reopened connection used to
  duplicate every row seen so far). Presentation-only; SSE/API wiring unchanged.

### FIXED
- **Round-4 cross-model review sweep — 30+ findings applied (CRITICAL→LOW).** *Salvage/bus
  integrity:* `_salvage_timeout` is invoked from an `&&` condition, which disables `set -e` for its
  whole body, so every critical bus mutation (archive, done marker, chain reset) is now checked by
  hand and a mid-transition failure returns a distinct rc the caller reports loudly instead of
  reporting a salvage that never happened; the watchdog's `limits/<id>.timedout` marker carries the
  attempt's claim token, so a stale marker can no longer finalize a newer healthy claim as timed
  out; every unsuccessful salvage path now deletes `res-<id>.txt` (a rejected answer could
  previously be inherited verbatim by a later codex attempt, and was listed under `=== results ===`
  as if the branch had produced one); a salvaged `done/<id>` is stamped `"salvaged": true` (spec 12
  FR-2 made a nonzero `code` legal on plain successes too, so `code` alone no longer distinguished
  them) and `write_verify_spec` now builds a **diff-only** verify prompt for a salvaged write card
  with no handoff file — those cards used to skip the mandatory cross-model verify wave entirely.
  *Evidence fidelity:* every park transition goes through one `_park_card` helper that appends a
  final classified `parked` row (several pinned paths wrote only the marker, so `parked_n` and the
  bus disagreed); `run_summary`/`swarm-ctl review-stub` count `timeout-salvaged` toward done;
  `feedback_stubs` derives its run label the same way `speed_row` does (on a default bus the two
  ledger-driven classes silently never fired); every ledger read goes through the codebase's own
  tolerant `fromjson? // empty` reader, so one torn line no longer disables `run_summary`,
  `feedback_stubs`, `postmortem` and `review-stub` permanently and silently. *Lane health:* a
  `.broken` route-around is recorded as `fallback_reason: "lane-down"`, not `budget-gated` (a lane
  event was being logged as a spend event); an already-classified per-card failure
  (`false-done`, api/server error) is no longer overwritten by the lane-down inference, which also
  stops one bad card cooling a working lane for 30 minutes; the tmux board filters `.broken`
  through its TTL; the resolved-config table shows `broken <N>m` and now prints **every**
  `conf_load` key from one shared `CONF_KEYS` list (five had drifted out of it).
  *Security/robustness:* `doctor --live` no longer copies OAuth credentials into `$BUSDIR/home/`
  and leaves them there — probes cage in a temp dir cleaned by a `RETURN` trap, and the
  "bus already existed" guard is captured **before** the probe loop (creating the cage used to
  satisfy it); provider keys travel to `curl` over **stdin** (`-H @-`) instead of argv, and gemini
  uses the `x-goog-api-key` header instead of a `?key=` query string (`/proc/<pid>/cmdline` and
  proxy logs); the grok probe syncs its refreshed single-use OAuth token back to the master like a
  real spawn does; probes hit the **configured** model rather than a hardcoded `glm-4.6`;
  `_ledger_append_row` is `flock`-serialized with a per-writer temp file; `bus_init` creates
  `notes-lessons.md` with `noclobber` instead of check-then-truncate. *Public-repo hygiene:*
  `check.sh`'s PII gate now scans `feedback/` — the one content dir whose files are
  machine-generated at every run close — and `feedback_stubs` emits repo-relative paths with the
  repo NAME as `source:` (existing stubs scrubbed). *Cockpit:* `replay-done` finalizes open backfill
  coalesces, so the first live event on a still-open key stamps `lastEvtClient`/dots/pulses instead
  of vanishing into the coalesce fast path, with a 30s deadline fallback if the sentinel never
  arrives; covered by a new node-based client test (`tests/cockpit-replay-boundary.mjs`).
  *Config:* `GROK_EFFORT=` (empty) finally restores the grok CLI's own high-effort default —
  `${VAR:-default}` substitutes on empty as well as unset, so the documented behaviour was
  unreachable in both `conf_load` and `lane_cmd`. *Docs:* `docs/releasing.md` spells out the exact
  branch + tag push commands per remote and `AGENTS.md` says `public` (it said `main`); spec 07's
  cockpit boundary records the `audit.jsonl` sole-writer exception; spec 12 gains `lane-down` +
  terminal-park semantics; spec 13 documents the deliberate exhaustion-based `.broken` timing and
  the mode-aware preflight (`verify_run` now resolves the verifier actually picked per done branch,
  so a verify wave can no longer pass preflight and then fan out env-key verifiers).
- **`GLM_MAX_THINKING_TOKENS`/`KIMI_MAX_THINKING_TOKENS`/`GROK_EFFORT` excluded from `conf_load`'s
  FR-1 precedence (backlog 31, specs/04-settings.md amendment).** Investigated a reported GLM
  thinking-token flood (`feedback/archive/2026-07-24-unimatrix-glm-thinking-flood-c3.md`, 8.5MB
  stream, ~11.8k est. thinking tokens vs a 6000 conf cap). Traced every spawn path (direct
  `lane_cmd`, chain-claimed re-spawn, the `swarm-loop.sh` → `swarm-run.sh` subprocess boundary):
  the cap reaches every same-run child env correctly — these three knobs were deliberately kept out
  of `conf_load`'s `keys` array, which meant a `swarm.conf` file value could silently clobber an
  already-set env override (backwards from FR-1's env > file > default) and the value was never
  `export`ed for a subprocess boundary. Folded all three into `keys` with their existing baked
  defaults (`6000`/`6000`/`medium`), restoring standard precedence/export. The flood itself is
  likely NOT a cap-not-applied bug: `MAX_THINKING_TOKENS` bounds thinking per model turn, not
  cumulative across a long agentic session — not fixable client-side beyond the existing mitigation
  (bench GLM to ≤C2 single-file cards; `WORKER_TIMEOUT_SEC` as the wall-clock backstop, which did
  fire in the reported incident). Bats coverage: `tests/swarm-lib.bats` (conf_load precedence +
  export, `lane_cmd` LANE_ARGV threading under both a fresh and a conf-loaded env, glm and kimi).
- **Speedwars report reader crashed on the real ledger (spec 08 FR-7, D2).**
  `src/speedwars-report.sh` iterated `run-meta.cards` with `to_entries` assuming the FR-4 object
  shape; a summary-style row carrying a scalar count (`"cards": 17`, written by a sibling session)
  made jq abort with `number (17) has no keys`, so `/speedwars` printed nothing at all. The
  complexity join now skips any non-object `cards` (append-only ledger legitimately mixes
  schemas — the reader's own design contract). Regression test added (`tests/swarm-lib.bats`).
  Found by the qa-3x post-ship QA run.
- **Per-worker scratch-home cages (same-lane fan-out stomp).** `_scratch_home` now takes the
  branch id and builds `$busdir/home/<lane>.<id>` — with same-lane `FANOUT > 1`, concurrent
  spawns previously shared one `home/<lane>` dir and the grok branch's spawn-time `rm -rf`
  wiped a sibling's live cage mid-run ("Not signed in" ×4, live finding brain-053-remed
  2026-07-19). id-less callers keep the old per-lane path.
- **Grok OAuth token write-back.** Grok rotates its (single-use-refresh) OAuth token inside the
  caged HOME, so `~/.grok/auth.json` went stale the moment any cage refreshed and every later
  spawn from the master copy failed auth. `_spawn_worker` now syncs a newer cage
  `auth.json` back to `~/.grok/` after each grok worker exits (last-writer-wins across
  concurrent buses; never fails the worker).
- **Wave-8 QA: parked alert card no longer misattributes the lane cap (spec 07 FR-14).**
  A parked agent's lane is only the chain-head guess, so the card could read
  "claude lane .limited" while glm held the flag (caught live on the §5.5 fixture). The card
  now names a lane only when that lane is actually limit-flagged, else falls back to the
  first flagged lane or plain "parked (lane caps)". Full 18-step Lane-A checklist passed on
  the checked-in fixture (tests/fixtures/cockpit-bus/), plus a live Lane-B pass on :4747
  with a real 2-branch run — zero console errors, controls round-trip (nudge ok-toast +
  requeue, pid-less kill red-toast), degrade static-serve shows the notice with no poll
  storm.
- **Wave-7 review fixes (specs 07/08) — 15 findings applied from a 3-reviewer pass (codex ×10,
  code-reviewer ×1, code-simplifier ×5), 1 refuted in writing.** Highlights: exact claim
  resolution — every `swarm-ctl` verb and the verify-idempotency check resolved
  `claimed/<id>.*` by glob, so a dotted sibling (`a.b`) could be cancelled/killed/nudged/
  frozen when targeting `a` (shared `_claim_of` resolver + 5 regression tests); freeze/reap
  ordering — `.frozen` now brackets the whole pause/kill/cancel claim disposition and lease
  touches precede signals, closing reaper double-claim windows; verify-bundle publish order —
  `.lane` sidecar lands before the prompt (both in `write_verify_spec` and enqueue) and torn
  prompt-only verify footprints are repaired, so an interrupted publish can no longer run a
  verify on the generator's own lane; `add` publishes sidecars before the prompt becomes
  claimable; cockpit `errorStreak` now clears on clean snapshots/reconnect (no permanent
  phantom `err`), failed config fetches retry instead of caching empty, and flightpath verify
  rows label the real generator lane from done-provenance. Refuted: dropping the pipeline's
  REVIEW lane row (plan §5.3 orders it explicitly). Dedup pass: shared `ageSecOf` in
  format.js, `execCtl` helper in server.mjs, badge colors hoisted to base.css. FR-14
  anti-fake grep is now an automated bats test; `speed_row` gained all-five-lane envelope
  fixtures + the `SPEEDWARS_AUTO=0` kill-switch test. Suite: 310 green.
- **Pool crash on signal-interrupted `wait -n` (swarm-run.sh).** `wait -n -p finished` leaves
  the var UNSET when interrupted or when no child remains — under `set -u` the finalize line
  then aborted the whole pool mid-run (observed live: SIGKILLed w5 workers → "finished: unbound
  variable", run left INCOMPLETE with a stale claim). Now guarded: empty → re-enter the loop.
- **Second-pass audit (2026-07-12, fresh-eyes):** 11 confirmed findings, 6 fixed (rest adjudicated
  not-worth-churn), +4 bats tests → 191 green.
  - **Bounded same-lane retry** (`MAX_LANE_RETRIES`, default 3): a lane that persistently produced
    no usable answer with no recognized limit signature (deprecated model, drifted stream-json
    shape) re-queued onto itself **forever** — the spec was never done nor parked, the pool gate
    never closed, and in `/swarm-loop` even the budget/wall-clock stop rules could not fire.
    Now: 3 consecutive unusable-answer attempts → chain-advance (or park when pinned/exhausted);
    counter resets on lane change/completion (spec 04 FR-6 amended).
  - `/api/stream` SSE is now line-safe like the tmux firehose: the byte cursor advances only past
    complete lines (a mid-write partial record was emitted as two permanent garbage fragments on
    essentially every run) and resets when a run file shrinks (a same-id failover re-run truncates
    it via `tee` — the whole re-run was silently absent from the live feed).
  - `_ledger_lane_fields`: the lane→(provider string, billed shape) mapping deduplicated out of
    `ledger_row`/`ledger_failed_row` (byte-identical copies that could drift).
  - Tests strengthened: board count assertions pin each digit to its label (were
    anywhere-in-line globs that passed on wrong counts); the caged-oracle test now also proves
    the oracle *ran* (canary present in the cage's scratch HOME, not just absent from `$HOME`).
- **Autonomous audit remediation (2026-07-12):** 45 confirmed findings from a 10-dimension
  multi-model audit fixed via red-green-double-refactor (+21 bats tests → 181 green, shellcheck
  clean on all 5 scripts).
  - `swarm-run.sh config`: escape sed-active chars (`&|\`) and refuse a `"` in the value so a
    config edit can no longer crash sed or corrupt the bash-sourced `swarm.conf`; guard the
    missing-value case (was an unbound-var crash).
  - `ledger_row`: label via `awk ENVIRON` not `-v` (a backslash/`\n` in a prompt no longer splits
    the markdown row); fall back to the spec id for `## Criteria` loop-spec banners.
  - No-silent-spend: `ledger_failed_row` logs the timeout/limit/failover finalize paths too
    (a spawned CLI that spent but never finalized), per `rules/unimatrix/model-lanes.md`.
  - `plan_only` no longer writes `run.pgid` (`$$` is not a pgid); `_drive_pool` clears it once the
    pool group is gone; `swarm-ctl abort` liveness-guards the pgid before signalling.
  - `swarm-loop`: judge≠executor now checked against the *whole* EXEC_CHAIN (a failover exec lane
    could grade its own output); cross-model review now sees the worktree **diff**, not the
    executor's self-report; the oracle runs under the worker containment cage (`env -i` + scratch
    HOME); the **budget** stop rule is wired (sums claude/glm `total_cost_usd` per iteration);
    per-iteration git checkpoint is default-on (git-reset safety net); `human_gate` resume no
    longer re-runs exec against the approved worktree; oscillation is checked before plateau.
  - Web cockpit (`site/cockpit.html`) repaired end-to-end: BOARD/COST/FIREHOSE now consume the
    real `server.mjs` shapes (snake_case bus keys, `{lanes:[…]}` cost array, SSE `{worker,line}`
    JSON envelope) — the whole panel set was inert/garbled.
  - `swarm-ctl cancel`/`kill --cancel` clear `.lane`/`.write` sidecars (a same-id `add` no longer
    inherits a stale lane pin or write target); QUEUED count (board + `/api/bus`) counts only
    `*.prompt`; tmux firehose no longer wedges on an empty bus.
  - `site/server.mjs`: DNS-rebinding Host-header guard; `/api/cost` sum aligned to
    `swarm-mon.sh _cost_summary`.
- `site/index.html`: `.field` background no longer uses `mask-image` for its radial edge fade —
  Chromium ghosts page text when `backdrop-filter` (glass nav) blurs over a masked fixed layer.
  Replaced with a bg-colored cover gradient of the same ellipse geometry, matching the fix already
  shipped on the sibling collective site.
- Sticky glass nav actually sticks now: `main,header.nav,footer{position:relative}` out-specified
  `.nav{position:sticky}` (0,1,1 beats 0,1,0), pinning the nav static since launch. Selector list
  is `main,footer` on all three pages.

### MAINTENANCE
- **Drift re-smoke + pin bump (2026-07-19):** claude 2.1.204→2.1.215, codex 0.143.0→0.144.6,
  gemini 0.49.0→0.51.0 — PONG green on all 4 lanes (`docs/01-feasibility-tests.md` §F). Gotcha:
  2.1.215 emits the #67861 OAuth-conflict warning on stdout before the JSON on the GLM lane
  (parser immune; raw `jq` pipes are not). FR-16 sandbox image rebuild to 0.51.0 still owed.
  Stale `.bus/` state from the 07-08 run purged (~166MB, mostly cached CLI home trees).

### DOCS
- Round-4 hygiene (2026-07-25): feedback triage protocol now records a `triaged-to:` frontmatter
  key (`backlog#NN` | `skill-ledger <date>` | `dismissed (<why>)`) on every archived item — all 11
  archive files backfilled; research-backlog DONE sweep (9, 14, 15, 16, 19, 27–30, 32 + four
  resolved prose sections), item 12 folded into 35, legacy sections given permanent ids 40–43;
  `plans/` marked with SHIPPED/archived status headers; duplicate `[Unreleased]` headings merged;
  absolute home paths scrubbed from tracked docs (pre-existing PII-gate reds — gate green again).
- Autonomous-audit doc/spec fixes (2026-07-12): `README` quickstart corrected (non-claude lane
  keys come from `~/s/.env.master`/`ENV_MASTER_FILE`, not ambient env vars); `npm run lint` +
  `CLAUDE.md`/`site/agents.md` lint commands now cover all 5 scripts (was `src/*.sh` = 1 file);
  bats file headers added to `tests/cockpit.bats` + `tests/ground-control.bats`;
  `site/.assetsignore` excludes `.playwright-cli`; spec drift corrected (spec 02 FR-7 `kill`
  mechanics, spec 01/04 verification-command bats names, spec 03 oracle-tier wording, stale
  FR-5/FR-12 code comments); loop checklist documented as advisory-in-v1. Full remediation record
  in `plans/refactor-remediation-2026-07-12.md` + `plans/refactor-synthesis-2026-07-12.md`.
- Family cross-links to the sister site: nav + footer link to
  [collective.asajj.cz](https://collective.asajj.cz) (The Collective — the cockpit), and
  `site/llms.txt` gains a Family section both ways.
- Site de-indexed from search engines: `robots.txt` (Disallow all), `_headers`
  (`X-Robots-Tag: noindex, nofollow` on every route), and `<meta name="robots">` in all three
  HTML pages. Site stays reachable by direct link only.
- Rules sharpened from multi-agent failure research (MAST taxonomy, arXiv 2503.13657; LLM-judge
  family bias, arXiv 2508.06709): `loop-discipline.md` gets a "Proof-of-action gate" subsection
  (a completion claim must carry the artifact path + a content excerpt; `--until` judges run the
  check command themselves, never accept worker narration); `model-lanes.md` gets a "Same-family
  audit residue" subsection (Fable still adjudicates the claude:opus exec leg despite codex being
  a correctly cross-vendor reviewer — documented as a known limitation, not solved); `bus-discipline.md`
  states claim-atomicity + unique-task-id + serialize-writes-per-session as explicit invariants.
  New `docs/research-backlog.md`: ranked, not-yet-built backlog from the same research pass (loop
  checkpointing, stalled-worker detection, mandatory fan-out spec contract, dissent-citing
  synthesis, HOTL pause/kill in the cockpit, serial-by-default concurrent writers).
- Dual-audience site guides: `guide.html` for humans (prompt-first — copy-paste `/swarm` and
  `/swarm-loop` prompts to run from inside Claude Code, zero bash) and `agents.md` + `llms.txt`
  for agents (contract-first — repo layout, bus discipline digest, exact lane invocations, judge
  != executor, rules pointers). `index.html` nav links to both, plus a "Why this shape"
  differentiators section.
- Site lanes section reframed role-first ("Five models, four roles"): Fable 5 = planner,
  Codex = reviewer, Gemini = web research, Opus → GLM = execution with weekly-limit failover;
  notes every seat is one `swarm.conf` line and any model can take any role (matches the
  shipped defaults — `PLAN=fable`, `REVIEW=codex:default`, `EXEC_CHAIN="claude:opus glm:glm-5.2"`).
- Public overview page at [unimatrix.asajj.cz](https://unimatrix.asajj.cz) (`site/` — single
  self-contained HTML, Borg-styled dark theme with tuned light variant, self-hosted Share Tech
  Mono, IntersectionObserver reveals gated behind a `.js` class so no-JS/crawlers always see
  content). Deployed as a Cloudflare Worker with static assets (`site/wrangler.toml`,
  `custom_domain=true` route auto-provisioned DNS + TLS); `.assetsignore` keeps wrangler.toml
  and build dirs out of the public tree. Every command on the page fact-checked against the
  code by an adversarial reviewer (caught a wrong `swarm-ctl add` signature, an overclaimed
  write-lane description, a wrong cockpit-pane claim, and an AA contrast failure — all fixed).
  README test-count badge and layout table refreshed to 149.
- Promotion-ready README (hero banner, badges, mermaid architecture diagram, quickstart for
  direct-bus / `/swarm` / `/swarm-loop`, honest status + limitations) and a full operator guide at
  `docs/usage.md` (9 sections, every command verified against the code). New social-preview asset
  `docs/assets/unimatrix-social.png` (upload manually at GitHub → Settings → Social preview).
- Run-evidence ledger: curated the auto-appended loop-run rows; filed the `ledger_row`
  first-line-label bug (loop specs all label as `## Criteria …`) as backlog.

### FEATURES
- 5th exec lane: **Grok (xAI Grok Build CLI)** — `grok:<model>` joins the exec chain. Auth is an
  OAuth file (`~/.grok/auth.json`, copied into the caged scratch HOME), not an env key; billing
  rides the SuperGrok weekly pool (metered jointly across Grok chat/Build/API), so ledger `$` for
  this lane are reported as notional, never as an API line item. Read-only by default
  (`--tools read_file,grep,list_dir --no-subagents`); an FR-15 write sidecar drops the allowlist
  and adds `--permission-mode acceptEdits`, mirroring the claude/GLM write contract exactly
  (`--yolo`/skip-permissions stays forbidden). Handoff is `streaming-json` NDJSON — the answer is
  the concatenation of every `type=="text"` event's `.data`, and the served model is read from the
  last `type=="end"` event's `.modelUsage` keys, never the requested `-m` (probe-verified
  2026-07-19: `grok-4.5` silently served as `grok-4.5-build`). `.total_cost_usd` is omitted on
  some OAuth/pool paths per grok's own headless doc — absence falls back to reported token counts,
  never treated as free. Limit failover is a generic error-message match (`rate limit`/
  `usage limit`/`quota`/`too many requests`, TTL 18000) — no documented 429 envelope has been
  observed live yet, so this is a placeholder heuristic pending a real capture. `EXEC_CHAIN` now
  leads with `grok:grok-4.5`. Contract in `rules/unimatrix/model-lanes.md`, lane table in
  `specs/04-settings.md`, pins in `docs/versions.md`.
- Ground Control lane (specs/05, Active): `site/server.mjs`, a zero-dependency Node-stdlib web
  server serving the public site locally plus a live web cockpit (`/cockpit.html`) that reads
  `.bus/` — `/api/bus` (queue/claimed/done/cancelled counts, stale leases, limits, parked
  branches), `/api/stream` (SSE tail of `run-*.jsonl`), `/api/cost` (per-lane token summary).
  Read-only on the bus, same discipline as the tmux cockpit. Registered in Ground Control (`gc`,
  the fleet TUI) on reserved port 4747 as unit `svc-unimatrix`; the first swarm of a session
  auto-ensures the server is up and auto-opens `/cockpit.html` in the browser (`mon_web_ensure` /
  `mon_web_open` in `src/swarm-lib.sh`), once per bus lifetime, non-fatal on any failure.
  `MON_AUTOOPEN=0` in `swarm.conf` disables both calls.
- Opt-in containerized gemini lane (specs/01 FR-16) — closes the before-unattended containment gate
  for the one web-facing lane. `GEMINI_SANDBOX=docker` (`swarm.conf` key, default off = today's
  behavior) wraps the gemini invocation in `docker run --rm -i` with ONLY the contract env
  forwarded explicitly (`-e GEMINI_API_KEY=…`, `-e GEMINI_CLI_TRUST_WORKSPACE=true` — never a bare
  `-e NAME`, which would forward the host's ambient value) and zero `-v`/`--mount` args — this
  lane needs no repo access, so prompt-injected web content lands in an empty container, not the
  host filesystem. Runs a pinned custom image, `unimatrix-gemini-lane:0.49.0`
  (`docker/gemini-lane.Dockerfile`, `node:22-slim` + `npm i -g @google/gemini-cli@0.49.0`) —
  `ghcr.io/google/gemini-cli:latest` (gemini's own `--sandbox` default image) turned out NOT
  publicly pullable (`denied` on anonymous pull), so a custom image was built and pinned instead.
  gemini's own `--sandbox` flag stays forbidden (unchanged finding from Phase E step 2 — it
  re-execs the whole CLI in its own container and strips the contract env). Docker missing from
  PATH is a loud `lane_cmd` failure (never a silent unsandboxed fallback); an unpullable image or a
  failed container start surfaces as the worker's own nonzero exit, already covered by the existing
  chain-advance/park handling. FR-15 interaction unchanged: a `.write` sidecar still refuses before
  any sandbox logic runs. Handoff path unchanged — `extract_answer` reads the same stream-json
  shape regardless of sandboxing. Live-verified: real sandboxed PONG through the built image, then
  one full `swarm-run.sh` round trip (pinned `gemini:gemini-3-flash` branch, `GEMINI_SANDBOX=docker`)
  — `res-<id>.txt` normalized correctly, ledger row auto-appended. 6 new unit tests
  (`swarm-lib.bats`: argv shape on/off/write-refusal/missing-docker) + 1 new integration test
  (`swarm-run.bats`: full round trip through a fake docker+gemini pair), 149 total green,
  shellcheck -x clean across all 5 scripts + the new Dockerfile.
- Write-capable exec branches (specs/01 FR-15) — closes the plan's §4.5 toy-loop-to-GREEN
  acceptance, making `/swarm-loop` actually converge instead of running read-only forever. A
  branch with a `.bus/specs/<id>.write` sidecar (mirrors the FR-2b `.lane` sidecar's own
  lifecycle exactly) runs its worker in that target directory with file-write capability:
  claude/GLM get `--permission-mode acceptEdits` + `env -C <target>` (live-verified against real
  claude 2.1.204, both with a real HOME and under the full `env -i` + scratch-HOME containment
  cage — writes land, no prompt, `--add-dir` turned out unnecessary; `--dangerously-skip-permissions`
  stays forbidden), codex gets its native `-C <target> -s workspace-write`, gemini refuses loudly
  (not a write lane in v1) and chain-advances/parks like a missing key would. `swarm-loop.sh init`
  now creates a scratch git worktree of `TARGET_DIR` (`git worktree add -b loop-<run> <path>
  <base-sha>`) when it's a usable git repo — else runs directly against `TARGET_DIR` with a loud
  warning — and every exec increment's `.write` sidecar points at it, so the oracle and the
  existing `LOOP_GIT_CHECKPOINT` commits both operate on the worktree, never the orchestrator's
  own tree. `COMPLETE.md` now names the worktree path and a `git diff --stat` summary against the
  recorded `base_sha` so the operator can review and merge. Live end-to-end convergence verified:
  a toy git repo + failing oracle (`grep -qx 42 answer.txt`), `EXEC_CHAIN=claude:haiku`,
  `LOOP_JUDGE=codex:default` — `swarm-loop.sh init` then `run` reached `COMPLETE.md` with the
  oracle genuinely green. 11 new bats tests (5 unit in `swarm-lib.bats`, 2 integration in
  `swarm-run.bats`, 4 in `swarm-loop.bats`), 140 total green, shellcheck -x clean across all 5
  scripts.

  <sub>**Review fixes (2 more, TDD, 2 more bats tests, 142 total green):** (1) `_scratch_home`'s
  claude branch hardcoded `$HOME/.claude/.credentials.json` — wrong source on a multi-account box
  where the orchestrator session runs under `CLAUDE_CONFIG_DIR` pointing at the LIVE account;
  `~/.claude` can be a different/stale account whose token happens to still validate sometimes and
  not others (docs/02-build-pitfalls.md §19). Now sources from
  `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json`; the scratch-home copy's destination stays
  `.claude/` either way, since `env -i` strips `CLAUDE_CONFIG_DIR` from the caged worker so the
  caged claude binary falls back to its own default `$HOME/.claude` lookup. All three bats files
  now `unset CLAUDE_CONFIG_DIR` in `setup()` so the ambient session's real credentials never leak
  into a test's throwaway scratch home. (2) `BUSDIR` was only absolute by default
  (`$SCRIPT_DIR/.bus`); an operator-exported relative override broke under FR-15's `env -C <target>`
  chdir — codex's `--output-last-message "$busdir/res-<id>.txt"` resolved against the WORKTREE
  instead of the real busdir once the worker chdir'd. `swarm-run.sh`/`swarm-loop.sh` now normalize
  once at assignment: `BUSDIR="$(realpath -m "${BUSDIR:-$SCRIPT_DIR/.bus}")"`.</sub>
- `/swarm-loop` (Phase E step 4.5): iterate-until-criteria driver (`swarm-loop.sh` init/iterate/run) — criteria contract written once + checksum-guarded immutable, exec increment on the chain, mandatory oracle + judge review (judge ≠ exec enforced), `state.jsonl` one-record-per-iteration, `steering.md` accrual, all stop rules (goal / plateau / oscillation / max-iterations / wall-clock / human-gate / PAUSE), `HALTED.md`/`COMPLETE.md`. Slash command with honest-refusal on undefinable success. Live-verified: real workers, real oracle, correct plateau halt (exit 2).
- Cross-model verify wave + run-evidence ledger (Phase E step 4): `swarm-run.sh verify` — for
  every completed generate-wave branch, `write_verify_spec` builds a `v-<id>` spec (original
  question + the branch's own answer + a `VERDICT: confirmed|refuted|unverifiable` instruction)
  pinned via the FR-2b sidecar to a lane picked by the new `VERIFY_MAP` rotation (`swarm.conf`,
  default `claude:codex codex:claude gemini:claude glm:codex`) — judge != executor is enforced even
  off the map (an unmapped generator still gets a provably-different fallback lane). The verify
  wave reuses the SAME pool/gate mechanics as the generate wave (`_enqueue_pending_specs` /
  `_drive_pool`, factored out of `full_run`); idempotent, so re-running `verify` after new branches
  complete only picks up the new ones. Every branch's `done/<id>` marker now carries a `"lane"`
  provenance field (the SERVED lane, extending the `{"id","code"}` shape), and its prompt is
  archived to `prompt-<id>.txt` before the claim file is dropped — both needed by the verify wave,
  since the original question doesn't survive anywhere else once a branch finalizes. `ledger_row`
  auto-appends one `docs/ops/llm-runs.md` row per successfully finalized branch (`LEDGER_AUTO=1`
  default, `swarm.conf`) using the REAL captured per-lane envelope shapes: claude `.total_cost_usd`
  + `.usage`, codex `turn.completed.usage`, gemini `result.stats.models` (recursive sum, tolerant of
  schema drift); GLM deliberately reports prompts-consumed language rather than a dollar figure
  (see file for the `.modelUsage`-shape caveat). `.claude/commands/swarm.md` documents the verify
  step and a research-branches convention (a research-heavy branch runs its own deep-research pass
  *inside* its claude-lane worker — one bus file, one `done/` marker, per `PRD.md` §8). 22 new bats
  tests (16 unit in `swarm-lib.bats` + 6 integration on fakes in `swarm-run.bats`), 125 total green
  across the suite, shellcheck -x clean.
- Parked-branch gate fix (specs/01 FR-7 addendum, found by the `/swarm-loop` build): a pinned
  branch whose lane parks (exhausted, no fallback) used to stay "live" in `queue/` forever —
  `done/` count could never reach `live/` count and the pool hung until an external `swarm-ctl
  abort`. `_run_pool`'s gate now closes at `done + parked >= live` (parked is terminal, never
  silently dropped: `_check_parked` prints every parked id to stderr and the driver exits nonzero).
  Root cause underneath: `gate_count` was counting a pinned branch's `<id>.lane` sidecar as a
  SECOND live unit alongside `<id>.prompt` — harmless for a normal completion (the sidecar is
  removed alongside the done marker) but permanent for a parked one (never cleaned up), which is
  what actually blocked the gate from closing even after adding the parked count. Fixed at the
  source: `gate_count` counts only `*.prompt` files in `queue/`. Also fixed `_ledger_append_row`
  (found in the same live-verification pass): its insertion anchor `^| ` (pipe-space) skipped the
  table separator row `|---|` (pipe, no space), so appending to a freshly self-healed ledger
  (header + separator, zero data rows yet) landed the new row BEFORE the separator — malformed
  markdown. Anchor is now `^|`, so the separator counts as the table's last line when there's
  nothing after it yet. 4 new bats tests (2 gate_count/FR-7, 2 ledger append-position), 129 total
  green, shellcheck -x clean.
- `/swarm-loop` (Phase E step 4.5): `swarm-loop.sh init/iterate/run` — a criteria-gated loop that
  reuses `/swarm`'s bus machinery rather than new coordination primitives. `init` writes the
  `criteria.md` contract once (goal/tier/oracle/judge/human_gate/checklist/invariants/stops) and
  refuses to re-init over an existing run; `iterate` runs one increment (exec spec on `EXEC_CHAIN`
  -> deterministic oracle -> if green, review pinned to the judge lane via the FR-2b sidecar) and
  appends exactly one `state.jsonl` line, accruing findings into `steering.md` on anything short of
  a pass verdict. `run` iterates until a stop rule fires, checked in the spec's own table order —
  goal, plateau (no oracle/review progress for N iterations), oscillation (failure signature
  alternating A/B/A), max_iterations, budget (stub — no ledger to sum against yet), wall_clock,
  human_abort (`.bus/PAUSE`) — writing an honest `COMPLETE.md` or `HALTED.md` (naming the rule,
  what was tried, a suggested next move) either way; never a self-graded promise string. Judge !=
  executor is enforced twice (init refuses to write the contract if they match; iterate re-checks
  every call) and `criteria.md` is checksum-guarded so nothing can rewrite the contract mid-run.
  `/swarm-loop` command file. 9 new bats tests (fake claude/codex + a controllable fake oracle).
  Tolerates `swarm-run.sh`'s now-nonzero exit on a parked branch (specs/01 FR-7, fixed off this
  build's flagged gap) — the pool-run helper no longer trips `errexit` on that exit code, since the
  caller already falls back gracefully off the presence of `res-<id>.txt`.
- Completeness + containment (Phase E step 2): FR-12 per-worker wall-clock watchdog
  (`WORKER_TIMEOUT_SEC`, default 300) kills a hung worker's whole subtree and forces
  chain-advance/park, never masked by a live heartbeat; FR-13 driver-death sweep — TERM/kill sent
  directly to `swarm-run.sh`'s own pid (not just via `swarm-ctl abort`) now terminates every
  in-flight worker. Worker env scrub: every lane invocation is `env -i` (PATH + a per-lane scratch
  HOME + LANG + the lane's own key) — claude/codex get only the one credential file each needs
  copied fresh per spawn, gemini/glm get a bare empty home. `swarm-ctl kill <id> [--cancel]`
  completed (pid registry at `.bus/pids/<id>`, `kill_subtree` primitive shared with the watchdog
  and driver sweep). FR-14 fencing against lease-steal double-finalize — a worker's claim-file
  identity (dev:inode, captured at claim time) is the fencing token, so a stale-but-alive worker
  whose lease was reaped can never overwrite a retry's result even when the retry reclaims the
  identical `claimed/<id>.<lane>` path. Four live E2E fixes folded in: gemini's real 0.49 answer
  shape (assistant message-delta concatenation, the `result` event has no `.response` field — the
  original research shape doesn't exist live); GLM model-pin (all three `ANTHROPIC_DEFAULT_*_MODEL`
  tier envs now resolve to the REQUESTED model, not hardcoded per-tier — a `glm-4.7` pin was
  silently served by `glm-5.2`, 3x quota); `served_model` (extracts the actually-served model from
  the envelope for both lanes, since neither can be trusted to serve what was requested); gemini's
  `--sandbox` **removed** — per its own bundled docs it re-execs the whole CLI inside a
  Docker/Podman container (pulling `ghcr.io/google/gemini-cli:latest` over the network on first
  use) whose own env allowlist doesn't forward `GEMINI_CLI_TRUST_WORKSPACE`, so every sandboxed
  attempt exited 55 live — this IS the docker dependency the original task said not to add, just
  not visible until a real invocation exercised it. 93 bats tests green.

<sub>**Bugfixes**: `local a="$1" c="$a/x"` in one `local` statement is unbound under `set -u` —
split into two statements (pitfalls §17); `arr+=($(cmd))` trips `errexit` under `inherit_errexit`
when `cmd`'s normal "nothing found" exit is nonzero (`pgrep -P` in `kill_subtree`) — guard with
`|| true` (pitfalls §18); `wait PID` after killing a subshell returns 143 and trips `errexit`
under `set -e`, silently skipping every cleanup line after it — orphaned the heartbeat loop, which
then kept recreating a just-deleted claim file forever (gate never closed); heartbeat/watchdog
subshells inherit the caller's stdout/stderr (a bats-owned pipe under test) — any that outlives its
parent holds that pipe open forever, hanging anything waiting for EOF on it — now explicit
`</dev/null >/dev/null 2>&1`. Two FR-2b tests relied on the real `~/s/.env.master` (HOME wasn't
sandboxed yet) — now set up their own `ENV_MASTER_FILE` like every other lane test.</sub>
- Monitoring cockpit (Phase E step 3): `swarm-mon.sh` — idempotent `tmux -L swarm` session with
  BOARD (QUEUED/CLAIMED/DONE/CANCELLED, stale-lease alarm, active limit flags, parked branches),
  FIREHOSE (`tail -F run-*.jsonl | jq`, tolerant of unknown types/non-JSON), COST (`ccusage` or a
  best-effort per-lane token fallback), and an interactive CONTROL pane with `src/` on `PATH`;
  optional non-fatal `--wezterm` read-only attach. `jq_firehose_filter` now also passes
  claude-lane `assistant`/`system` events. 9 new bats tests (throwaway socket + fixture bus), 75
  total green.
- 4-lane MVP (Phase E step 1): full worker pool in `swarm-run.sh` — `wait -n` job pool (FANOUT-bounded, own process group), per-lane invocations (claude / codex / gemini / GLM child-env), handoff-file answer extraction normalized to `res-<id>.txt`, limit-error detection with EXEC_CHAIN failover, FR-2b sidecar lane pinning (`<id>.lane` — pinned branches park loudly, never switch), missing-key sentinel (FR-11), `config` subcommand. 65 bats tests green against PATH-shim fakes.

<sub>**Bugfixes**: bash 5.2.21 segfault dodged (EXIT trap + self-inclusive `kill 0` — now INT/TERM only, pitfalls §15); bare function call under errexit killed the pool silently; full `lane:model` token passed to bare-lane dispatchers caused infinite requeue; reap id-extraction corrupted dotted worker names. **Review/live-smoke fixes**: gemini answer extracted from assistant deltas (0.49 result event has no `.response`); GLM served the wrong model on a pinned branch (tier-env fix); gemini `--sandbox` dropped (silently re-execs in Docker, strips contract env); `_ledger_append_row` mis-placed rows on a header-only table (anchor `^|` not `^| `); FR-7 parked-branch gate deadlock — a parked pinned branch hung the pool forever (root cause: `gate_count` counted the `.lane` sidecar as a second live unit); loop `_run_pool_once` crashed on swarm-run's new nonzero parked-exit under errexit.</sub>
- Swarm scaffold (Phase E step 0): bus primitives (`src/swarm-lib.sh` — atomic unique-dest claim, heartbeat lease reaper, live-count gate, limit flags), `swarm.conf` defaults, `swarm-run.sh --plan-only`, `swarm-ctl` (pause/resume/cancel/add/abort/status), `/swarm` command file. 28 bats tests, TDD red→green→refactor×2. Review caught + fixed a reap id-extraction bug with dotted worker names.
- Project setup per the global standard: rules/ (30 vault folders + 3 unimatrix rules), specs/ (01-04, Active), CLAUDE.md, AGENTS.md, run-evidence ledger (`docs/ops/llm-runs.md`), PowerShell jumper/cheat scripts. Main-only branching (project override).
- 4-lane worker fleet verified live: Claude, Codex 0.143.0, Gemini 0.49.0, **GLM via Z.ai** (glm-4.7 + glm-5.2 + headless tool-use all proven). Toolchain refreshed and pinned (`docs/versions.md`).
- Pre-build pitfalls research (4 agents) folded into `docs/02-build-pitfalls.md` — includes a claim-protocol correction and scheduler change (bash `wait -n` pool) over the original PRD.
- UNIMATRIX branding: banner + logo (`docs/assets/`), generated via PIG.
