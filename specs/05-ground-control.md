# Ground Control Lane — Web Cockpit, gc Registration, Auto-Open

**Status:** Active
**Date:** 2026-07-09
**Related specs:** [01-swarm-core](./01-swarm-core.md), [02-cockpit](./02-cockpit.md)

---

## Overview

A zero-dependency local web server (`site/server.mjs`, Node stdlib only) that serves the public
site locally **plus** a live web cockpit (`/cockpit.html`) reading the `.bus/` — registered in
Ground Control (`gc`, the TUIservers fleet TUI at `~/.config/groundcontrol/servers.toml`) on
reserved port **4747**, and auto-ensured + auto-opened in a browser whenever a swarm starts.
Also ships the site's dual-audience guides: `guide.html` (humans, prompt-first) and
`agents.md` + `llms.txt` (agents, contract-first — agents want executable markdown, not HTML).

The tmux cockpit (02-cockpit) is unchanged and remains the terminal surface; this adds the web
surface. Same discipline: **reads the bus, never writes it**, never on the run's critical path.

## Goals

1. `gc` can start/stop/monitor the unimatrix server like any other fleet server (unit
   `svc-unimatrix`, port 4747, `/health` probe).
2. First swarm of a session auto-opens the web cockpit in the Windows browser — no manual step.
3. Live board (queue/claimed/done/cancelled, stale leases, limits, parked), firehose (SSE tail of
   `run-*.jsonl`), and per-lane token summary in the browser.
4. Site guides: humans get copy-paste prompts for driving `/swarm` and `/swarm-loop` from inside
   Claude Code (no bash commands); agents get the exact contract (`llms.txt`, `agents.md`).

## Non-Goals

- No control surface in the web UI (read-only; control stays `swarm-ctl` / Fable session).
  Superseded by spec 07: a control surface lands via POST /api/ctl with spec 07's guards; the
  server process itself still never writes the bus — mutations are delegated to `src/swarm-ctl`
  as an execFile child.
- No public live cockpit — on unimatrix.asajj.cz, `/cockpit.html` degrades to a "local-only"
  notice (no `/api/*` there; `server.mjs` excluded from asset upload via `.assetsignore`).
- No npm dependencies, no build step, no framework. Node stdlib http + fs only.
- No WebSockets — SSE with poll-based tailing is enough at this scale.

---

## Requirements

### Functional

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-1 | `site/server.mjs` binds `127.0.0.1` only on port configurable via `PORT` env (gc injects it; default 4747), with `BUSDIR` env override (default `<repo>/.bus`). | Must |
| FR-2 | `GET /health` → `200 {"ok":true,"busdir":"..."}`; health probes trigger gc adoption. | Must |
| FR-3 | `GET /api/bus` → JSON: counts (queued/claimed/done/cancelled), stale leases, active `.bus/limits/*.limited` flags, parked branches, done-file names (newest first, capped 50). | Must |
| FR-4 | `GET /api/stream` → SSE tailing all `.bus/run-*.jsonl` (500 ms poll), one event per JSONL line, prefixed with worker id; malformed lines pass through raw, never crash. | Must |
| FR-5 | `GET /api/cost` → per-lane token sums porting `_cost_summary` envelope heuristics from `swarm-mon.sh`. | Must |
| FR-6 | `GET /api/config` → JSON of allowlisted `swarm.conf` slice (`EXEC_CHAIN`, `REVIEW`, `VERIFY_MAP`, `FANOUT`, `MAX_ITERATIONS`, `BUDGET_USD`, `WORKER_TIMEOUT_SEC`, `LEASE_MIN`, `MAX_LANE_RETRIES`). | Must |
| FR-7 | `POST /api/config` → `{key, value}` (8 KiB cap); validate per-key regex; rewrite matching line in `swarm.conf` (tmp + rename, atomic); preserve comments and other lines; respond with snapshot. | Must |
| FR-8 | Static file serving from `site/` (path-traversal-safe: resolve + prefix check); read-only on `BUSDIR` (`O_RDONLY`, never creates/writes). | Must |
| FR-9 | `mon_web_ensure` — curl healthcheck or start server via systemd-run (with gc-compatible unit) or nohup fallback; wait ≤5 s; non-fatal on failure. | Must |
| FR-10 | `mon_web_open` — open `http://localhost:PORT/cockpit.html` once per bus lifetime (marker `.cockpit-opened`); resolution: `$MON_OPEN_CMD` env → `wslview` → `powershell.exe -NoProfile Start-Process`; never fails the run. | Must |
| FR-11 | `site/cockpit.html` (superseded by spec 07): firehose-first layout with board counts + cost strip, firehose panel, optional AGENTS settings drawer for config edit. | Must |
| FR-12 | Site guides: `guide.html` (humans, prompt-first, copy-paste cookbook), `agents.md` + `llms.txt` (agents, contract-first, <150 lines), `index.html` nav gains links. | Must |
| FR-13 | Config: `MON_PORT=4747` and `MON_AUTOOPEN=1` in `swarm.conf`; wired at swarm entry (`full_run`, `swarm-loop.sh`); guarded so failure never blocks the run. | Must |

---

## Design

### server.mjs (site/server.mjs)

- `PORT` env (gc injects it; default 4747), binds `127.0.0.1` only.
- `BUSDIR` env override (default `<repo>/.bus`) — tests point it at a fixture bus.
- Routes:
  - `GET /health` → `200 {"ok":true,"busdir":"..."}`
  - `GET /api/bus` → JSON: counts (queued/claimed/done/cancelled), stale leases (> `LEASE_MIN`
    min, read from `swarm.conf` via a tolerant line parser), active limits, parked branches,
    done-file names (newest first, capped 50).
  - `GET /api/stream` → SSE. Tails all `.bus/run-*.jsonl` (500 ms poll; picks up files created
    after connect), one SSE `data:` event per JSONL line, prefixed with the worker id (filename
    stem). Line-safe like `tail -F | jq -R`: the cursor advances only past complete lines (a
    mid-write partial record is held for the next poll, never emitted as fragments) and resets
    when a run file shrinks (a same-id failover re-run truncates it via `tee`). Malformed lines
    pass through raw — never crash the stream.
  - `GET /api/cost` → per-lane token sums, porting `_cost_summary`'s envelope heuristics from
    `swarm-mon.sh` (codex `turn.completed`/`.usage`, claude/glm `result`/`.usage`, gemini
    `result`/`.stats.models`).
  - `GET /api/config` → JSON of an ALLOWLISTED slice of `swarm.conf`: `EXEC_CHAIN`, `REVIEW`,
    `VERIFY_MAP`, `FANOUT`, `MAX_ITERATIONS`, `BUDGET_USD`, `WORKER_TIMEOUT_SEC`, `LEASE_MIN`,
    `MAX_LANE_RETRIES`. Parsed with the same tolerant KEY=VALUE line parser as the stale-lease
    reader (strips comments, unquotes).
  - `POST /api/config` → body `{key, value}` (8KB cap). `key` must be in the allowlist above;
    `value` must match a per-key regex — numeric keys `^[0-9]+$`; `EXEC_CHAIN` a space-separated
    `lane:model` chain; `REVIEW` a single `lane:model`; `VERIFY_MAP` space-separated `lane:lane`
    pairs — lanes always restricted to `claude|codex|gemini|glm|grok`. Anything else → `400`.
    On success, rewrites only the matching `KEY=...` line in `swarm.conf` (tmp file + rename,
    same directory — atomic), preserving every other line and that line's trailing ` #` inline
    comment verbatim; a value containing whitespace is double-quoted. Responds with the new
    `configSnapshot()`. `CONF_FILE` honors a `SWARM_CONF` env override so tests never touch the
    repo's own `swarm.conf`.
  - Static: everything else from `site/` (path-traversal-safe: resolve + prefix check).
- Read-only on `BUSDIR`: opens files `O_RDONLY`, never creates/renames/writes under it.
  `swarm.conf` is the ONE write surface, and only through `POST /api/config`'s allowlist —
  no other path on disk is ever written by this process.

### cockpit.html (site/cockpit.html)

Layout superseded by spec 07 (3-view agent cockpit); the API and static-serving contract in this
spec are unchanged.

- Same visual language as `index.html` (dark, mono accents). Firehose-first layout: a fixed-height
  top strip (board counts + cost, poll `/api/bus` every 2 s / `/api/cost` every 10 s) and a
  firehose panel (SSE `/api/stream`) that fills all remaining viewport height.
- Top strip: queued/claimed/done/cancelled as inline count chips; stale-leases/active-limits/
  parked as warning chips shown **only when non-empty** (hover for the item list); per-lane token
  cost as a compact inline summary (hover for the exact per-lane counts).
- Firehose: each JSONL record is parsed and rendered as one row — time (`HH:MM:SS`, from
  `.timestamp`), branch id (color hashed per branch), an event-type badge (color-coded: results/
  messages green, errors red, tool_use blue, tool_result/other dim), and a one-line humanized
  summary (tool name + params, truncated result text, error message, etc.). Click a row to expand
  the full pretty-printed record inline; click again to collapse. Lines that don't parse as JSON
  render dim and raw. Capped at 500 rows; hover pauses auto-scroll (unchanged).
- First fetch failure → replace the strip+firehose with a static notice: "Live cockpit is
  local-only — start it with Ground Control (`gc`) or just run a swarm" + link to `guide.html`.
  This is the exact behavior on the public deploy.
- **AGENTS settings drawer** — a "⚙ AGENTS" toggle in the top strip expands a collapsed-by-default
  drawer (does not shrink the firehose); closed by default, loads `GET /api/config` on open.
  Three sections, each with its own save button and inline ok/error status: exec-chain (ordered
  lane-dropdown + model-input slots, add/remove, serialized to `EXEC_CHAIN` on save), review
  (lane dropdown + model input → `REVIEW`), and run limits (`FANOUT`/`MAX_ITERATIONS`/
  `WORKER_TIMEOUT_SEC`/`BUDGET_USD` number inputs, posted independently per changed field). Every
  save round-trips through `POST /api/config` and re-renders from its response — this is the only
  place on the page that writes anything.

### gc registration

Append to `~/.config/groundcontrol/servers.toml`:

```toml
[[server]]
name        = "unimatrix"
dir         = "~/code/unimatrix"
cmd         = ["node", "site/server.mjs"]
port        = 4747
health_url  = "http://127.0.0.1:4747/health"
health_kind = "http_200"
notes       = "Swarm web cockpit + site · zero-dep node stdlib"
```

`gc validate` must pass after the edit. 4747 collides with nothing in the current fleet.

### Auto-ensure + auto-open (src/swarm-lib.sh)

- `mon_web_ensure` — `curl -fsS http://127.0.0.1:$MON_PORT/health` OK → return. Else start it
  exactly the way gc would, so gc adopts the unit: `systemctl --user reset-failed
  svc-unimatrix 2>/dev/null; systemd-run --user --unit=svc-unimatrix
  --working-directory=<repo> --setenv=PORT=$MON_PORT -p KillMode=control-group
  -p TimeoutStopSec=10 -p Restart=no -- node site/server.mjs`. If `systemd-run` is missing,
  fall back to `nohup setsid node site/server.mjs`. Wait for `/health` (≤ 5 s), non-fatal on
  failure.
- `mon_web_open` — open `http://localhost:$MON_PORT/cockpit.html` once per bus lifetime: skip if
  marker `$BUSDIR/.cockpit-opened` exists, else create marker and open. Opener resolution:
  `$MON_OPEN_CMD` env (tests stub with `true`) → `wslview` → `powershell.exe -NoProfile
  Start-Process <url>`. Never fails the run (`|| true`).
- Config: `MON_PORT=4747` and `MON_AUTOOPEN=1` in `swarm.conf`; `MON_AUTOOPEN=0` disables both
  calls. Wired at the top of `full_run` (swarm-run.sh) and the loop entry (swarm-loop.sh),
  after `bus_init`, guarded so a failure can never block the run.

### Site guides

- `guide.html` — **humans**. Prompt-first: what to type inside Claude Code (`/swarm "…"`,
  `/swarm-loop "…" --until "…"`, and plain-English asks). When the swarm beats a single agent
  and when it wastes money. A copy-paste prompt cookbook (≥ 8 prompts). What you'll see
  (cockpit auto-opens; `gc` manages the server). Zero bash commands.
- `agents.md` + `llms.txt` — **agents**. Contract: repo layout, bus layout + discipline
  digest, exact lane invocations, judge ≠ executor, where results land (handoff files, never
  the terminal), rules pointers. Under 150 lines, most load-bearing instruction first.
  `llms.txt` follows the llms.txt convention (plain markdown pointer index, links into the
  site).
- `index.html`: nav gains Guide / Agents links; quickstart section links to both.

---

## Boundaries

- **Always**: bind to `127.0.0.1` only (never expose to LAN); read-only on `BUSDIR` (no file writes
  outside the dedicated control pane via spec 07); make the monitor non-blocking (it must degrade
  to "no monitor, run still completes" if `mon_web_ensure` can't launch).
- **Ask first**: opening a writable (`attach -t mon`, no `-r`) WezTerm window — deliberate only, so
  watching stays fat-finger-proof.
- **Never**: have the server write to `.bus` outside the dedicated `/api/ctl` endpoint; let the
  server become a dependency the run blocks on.

---

## Open Questions

None.

---

## Acceptance Criteria

- [ ] `bats tests/ground-control.bats` green: health, `/api/bus` counts against a fixture bus,
      SSE emits a fixture line, static serve, path traversal rejected, bus untouched after
      requests (mtime/inode check), `/api/config` GET returns the allowlisted keys and POST
      persists a valid change / rejects a non-allowlisted key / rejects a malformed value / leaves
      `swarm.conf`'s comments intact, `mon_web_ensure` no-ops when healthy, `mon_web_open` is
      once-per-marker and honors `MON_AUTOOPEN=0`.
- [ ] `gc validate` passes with the new entry; `gc` TUI shows unimatrix; start/stop from gc works.
- [ ] Fresh swarm run auto-opens the cockpit; second run in the same bus does not re-open.
- [ ] `shellcheck -x` clean; existing 149 tests stay green.
- [ ] Public deploy serves `guide.html`, `agents.md`, `llms.txt`, `cockpit.html` (degraded
      notice), and does **not** serve `server.mjs`.
