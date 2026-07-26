# MONITORING & RUNBOOK — Swarm Cockpit (approach a1)

**Scope:** how the *separate live-monitoring window* is built and driven for the `/swarm` orchestrator, using only what is installed and verified on this box: **tmux 3.4** (WSL), **starship 1.26**, **ccusage**, **jq**, and **`wezterm.exe`** on the Windows side at `/mnt/c/Program Files/WezTerm/wezterm.exe`. No MCP anywhere — the monitor reads files, never the TUI.

Verified on-box before writing: `tmux 3.4`; `wezterm.exe --version` → `20260705…` and `wezterm.exe cli list` returns live panes (its mux is already running and reachable from WSL); `starship`, `jq`, `ccusage` on PATH; the repo root is on a **local POSIX fs**.

---

## 0. The one load-bearing rule

**The monitor reads the bus, never the pane.** Panes run `tail -F … | jq` purely so a human can glance at them. The orchestrator's *answers* come from each CLI's own structured handoff file (`codex --output-last-message`, the `stream-json` `result` envelope) — so a noisy/redrawing TUI can never corrupt a result, and the monitor window is disposable, read-only, and can be killed or reattached at any time without touching the run.

Consequences that drive every command below:
- **Bus lives on a local POSIX fs** at `./.bus` — **never** a 9p/drvfs mount (`/mnt/c`, `/mnt/f`), which breaks `inotify`/`tail -F`/`O_APPEND`.
- **One writer per file.** Each worker owns exactly one `run-<id>.jsonl`; no interleave at fleet size 3–6, so no DB.
- **The monitor window is created detached by the orchestrator.** It exists and keeps tailing whether or not anyone is attached. Attaching (from WezTerm or anything else) is optional and read-only.

---

## 1. Bus layout (what the panes watch)

```
./.bus/
├── specs/      <id>.prompt        queued work (one prompt file per branch)
├── claimed/    <id>.lease         atomic mv on claim; mtime = lease clock
├── done/       <id>.done          completion marker (mandatory, see §5)
├── run-<id>.jsonl                 per-worker append-only event stream (the firehose)
└── res-<id>.txt                   per-worker final answer (--output-last-message / result envelope)
```

Create it once (orchestrator does this on first dispatch):

```bash
mkdir -p ./.bus/{specs,claimed,done}
```

## 2. How workers stream status — no MCP

Delegation is spawn → stdout → file. Prompts travel as **files** (never a `send-keys` string or `sh -c` interpolation), so it is injection-safe and MCP-free by construction. Each lane, spawned headless under `xargs -P<N>`:

```bash
# codex lane — answer in res, events in run
codex exec --json --output-last-message .bus/res-$ID.txt \
  -s workspace-write --skip-git-repo-check -C "$WT" -m "$MODEL" \
  "$(cat .bus/specs/$ID.prompt)" \
  | tee .bus/run-$ID.jsonl >/dev/null

# gemini lane — NOTE 2>/dev/null: the stderr banner is not JSON and corrupts jq
gemini -m "$MODEL" -o stream-json -p "$(cat .bus/specs/$ID.prompt)" \
  2>/dev/null | tee .bus/run-$ID.jsonl >/dev/null

# claude lane (and GLM via child-only env-swap, once a Z.ai key exists)
ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic ANTHROPIC_AUTH_TOKEN="$Z_AI_KEY" \
  claude -p --output-format stream-json --verbose \
  "$(cat .bus/specs/$ID.prompt)" \
  | tee .bus/run-$ID.jsonl >/dev/null

# on exit, drop the completion marker (mandatory — see §5)
echo "{\"id\":\"$ID\",\"code\":$?}" > .bus/done/$ID.done
```

The monitor only ever **reads** `run-*.jsonl` (glance) and counts `specs/ claimed/ done/` (state). It never writes to the bus.

## 3. Build the monitoring window (tmux 3.4, isolated socket)

Use a **dedicated socket** `-L swarm` so this never collides with your everyday tmux server. The orchestrator calls this on first dispatch; it is idempotent.

`./swarm-mon.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
BUS="$PWD/.bus"
S=swarm            # socket + session name

# idempotent: bail if the session already exists on this socket
if tmux -L "$S" has-session -t mon 2>/dev/null; then exit 0; fi

# pane 0 (top-left): BOARD — queued/claimed/done + stale-lease alarms
tmux -L "$S" new-session -d -s mon -n cockpit -x 200 -y 50 \
  "watch -n2 -t bash -c '
    cd $BUS
    printf \"QUEUED  %3s   CLAIMED %3s   DONE %3s\n\n\" \
      \"\$(ls specs/*.prompt 2>/dev/null | wc -l)\" \
      \"\$(ls claimed/    2>/dev/null | wc -l)\" \
      \"\$(ls done/       2>/dev/null | wc -l)\"
    echo \"stale leases (>15m, need reclaim):\"
    find claimed -name \"*.lease\" -mmin +15 2>/dev/null || true'"

# pane 1 (bottom): EVENT FIREHOSE — all workers merged, defensively parsed
tmux -L "$S" split-window -v -t mon:cockpit -l 65% \
  "cd $BUS; tail -n +1 -F run-*.jsonl 2>/dev/null \
   | jq -Rrc 'fromjson? // empty
       | select(.type|IN(\"assistant\",\"tool_use\",\"tool_result\",\"result\",\"error\"))
       | \"[\(.type)] \((.message.content[0].text // .result // .error // .subtype // \"\")|tostring)\"' \
   | cut -c1-180"

# pane 2 (top-right): COST — ccusage reads canonical session logs (dodges stream-json #6805)
tmux -L "$S" split-window -h -t mon:cockpit.0 -l 40% \
  "watch -n10 ccusage"

tmux -L "$S" select-pane -t mon:cockpit.1
```

Layout produced:

```
┌───────────────────────────┬──────────────────┐
│ 0 BOARD  queued/claimed/  │ 2 COST           │
│   done + stale leases     │   watch ccusage  │
├───────────────────────────┴──────────────────┤
│ 1 EVENT FIREHOSE                              │
│   tail -F run-*.jsonl | jq  (all lanes)       │
└───────────────────────────────────────────────┘
```

**Why this shape:** fixed 3 panes regardless of fan-out width — 3 or 6 workers all merge into the one firehose, so no dynamic pane splitting/renumbering (the classic tmux race). The firehose `jq` uses `fromjson? // empty`, so **unknown `type` values and non-JSON banner lines are silently dropped** — the parser survives a CLI upgrade that drifts the stream-json schema. `tail -F` (capital F) re-follows files that appear *after* the pane starts, so late-spawned workers show up automatically.

Per-worker split (optional, when you want one lane isolated):

```bash
tmux -L swarm split-window -v -t mon:cockpit \
  "tail -F ./.bus/run-<id>.jsonl 2>/dev/null | jq -Rrc 'fromjson? // empty'"
```

**starship** shows automatically in any *interactive* shell pane (it loads from your shell profile); the `watch`/`tail` panes are non-interactive so they show no prompt, which is what you want. The tmux status bar shows session `mon`, so you always know you're on the `swarm` socket, not your main one.

## 4. Attach from a Windows WezTerm into the WSL tmux session

The mux is already up (verified), so a single spawn drops a **read-only** view into a fresh WezTerm window. `-r` means you cannot fat-finger a keystroke into a worker.

```bash
"/mnt/c/Program Files/WezTerm/wezterm.exe" cli spawn --new-window -- \
  wsl.exe -- tmux -L swarm attach -r -t mon
```

Notes:
- Call WezTerm by its **full `/mnt/c/...` path** — it is not on the WSL `PATH`.
- If you run multiple WSL distros, pin one: `wsl.exe -d <distro> -- tmux -L swarm attach -r -t mon`.
- `wezterm.exe cli spawn` talks to the running GUI mux; if you'd rather use a native WezTerm **WSL domain** window instead of `wsl.exe`, `wezterm.exe cli spawn --new-window --domain-name WSL:<distro> -- tmux -L swarm attach -r -t mon` works the same way.
- Detaching (`Ctrl-b d`) or closing the WezTerm window leaves the tmux session **alive** — the run and its monitor keep going.

## 5. Completeness / liveness (mandatory, not optional)

For any overnight/unattended run the completeness gate is **non-negotiable**: the orchestrator must block synthesis until every branch has a `done/` marker, and must reclaim stale leases. The BOARD pane (pane 0) is the human view of that gate — a lane whose worker died shows up as `CLAIMED` that never becomes `DONE`, and its lease crosses the 15-minute `find … -mmin +15` alarm. The orchestrator's own assertion (not the human) is what actually holds the line:

```bash
# orchestrator blocks here before Opus synthesizes
while [ "$(ls .bus/done/ | wc -l)" -lt "$N" ]; do
  # reclaim: any lease older than the timeout goes back to specs/
  find .bus/claimed -name '*.lease' -mmin +15 -exec sh -c '
    id=$(basename "$1" .lease); mv ".bus/claimed/$id.lease" ".bus/specs/$id.prompt"
  ' _ {} \;
  sleep 5
done
```

If the BOARD ever shows `DONE < N` with no `CLAIMED` and no stale lease, a branch was dropped silently — never let Opus synthesize from that.

## 6. Fallback if WezTerm is unavailable

The monitor window is a detached tmux session on the `swarm` socket — **who attaches is irrelevant to whether it runs.** Fallbacks, cheapest first:

1. **Any shell already in WSL** (VS Code terminal, plain bash): `tmux -L swarm attach -r -t mon`.
2. **Windows Terminal / plain wsl.exe** (no WezTerm): `wsl.exe -- tmux -L swarm attach -r -t mon`.
3. **No multiplexer usable at all** — run the two views as bare processes in any two shells:
   ```bash
   cd ./.bus
   tail -F run-*.jsonl 2>/dev/null | jq -Rrc 'fromjson? // empty'   # shell A: firehose
   watch -n2 'ls specs done claimed | ...; ls done | wc -l'          # shell B: board
   watch -n10 ccusage                                                # shell C: cost
   ```
4. **Control mode** (drive tmux from an outer program without a GUI): `tmux -L swarm -CC attach -r -t mon` — useful if a wrapper wants to render the panes itself. Not needed for normal use.

The orchestrator never depends on the monitor existing: if `swarm-mon.sh` can't run (e.g. sandboxed Bash blocks the `/mnt/c` WezTerm binary), the run still completes and results still land in `res-*.txt`. The monitor is a convenience, not a dependency.

## 7. What you see

You run `/swarm "<question>"` in your Claude Code (Opus/Fable) session. A **new WezTerm window** pops open beside it, split three ways:

- **Top-left (BOARD):** a live counter — `QUEUED 4  CLAIMED 2  DONE 1` — ticking every 2s as branches move `specs → claimed → done`. A red-flag line lists any lease older than 15 minutes (a stalled/crashed worker), so a silently-dropped branch is *visible*, not hidden as "healthy backlog."
- **Top-right (COST):** `watch ccusage` refreshing every 10s — real per-model spend pulled from the canonical session logs, so the numbers are trustworthy (not the inflated per-event stream-json figures).
- **Bottom (FIREHOSE):** a merged, color-of-your-shell scroll of `[tool_use] …`, `[tool_result] …`, `[result] …` lines from *all* lanes at once — a glanceable "what are the workers touching right now," truncated to one line each so it never wraps.

It is **read-only** (`-r`): you can watch, scroll, and detach, but can't accidentally type into a worker. When the BOARD hits `DONE N`, the orchestrator pane back in Claude Code unblocks and prints the synthesized cited report. You can close the WezTerm window whenever; the run doesn't care.

## 8. Control — making adjustments mid-run

The monitor is read-only by design; **control is a separate concern with three levels**, cheapest first:

**Level 1 — the Fable session IS the control window (attended v1 default).** While the gate blocks, the orchestrator session in Claude Code is idle and interruptible: hit `Esc`, tell Fable "drop branch 3, add a branch on X, tighten branch 2's prompt" — it edits the bus (cancel/re-queue/spawn) and re-enters the gate. No new machinery; this is why attended v1 needs nothing extra.

**Level 2 — the bus is the control API.** Every mutation is a file op any shell can do; the scheduler only believes the directories:

```bash
touch .bus/PAUSE                                  # pause: claim loop checks this before each claim
rm .bus/PAUSE                                     # resume
mv .bus/specs/<id>.prompt .bus/cancelled/         # cancel a queued branch
kill "$(cat .bus/claimed/<id>.pid)"               # stop a RUNNING branch (worker writes its pid on claim)
  # then: mv claimed/<id>.lease → specs/ (retry) or → cancelled/ (drop)
$EDITOR .bus/specs/<id>.prompt                    # adjust a queued prompt — it's just a file
cp new.prompt .bus/specs/<newid>.prompt           # add a branch mid-run (claim loop picks it up)
kill -- "-$(cat .bus/run.pgid)"                   # ABORT ALL — spawner records its process-group id at start
```

Two wrinkles the implementation must honor: (a) the **gate counts live specs, not the original N** — `done ≥ specs+claimed remaining`, so cancelled branches don't deadlock it and added branches extend it; (b) mid-run *add* requires the claim-loop scheduler (Phase 2 mailbox), not a static `xargs -P` batch — in Phase 1 attended mode, "add" = ask Fable (level 1).

**Level 3 — `swarm-ctl` + an interactive cockpit pane.** A ~20-line wrapper (`swarm-ctl pause|resume|cancel <id>|kill <id>|add <file>|abort`) over the level-2 ops, runnable from any shell. Optionally give the cockpit a 4th *interactive* pane running plain bash (starship prompt appears) for it — but keep the WezTerm attach `-r`; open a writable attach (`tmux -L swarm attach -t mon`, no `-r`) only deliberately, so watching stays fat-finger-proof.

---

### Gotchas baked into the commands above
- `gemini … 2>/dev/null` **before** the pipe — its stderr banner is not JSON and will break `jq` if merged.
- `fromjson? // empty` in every `jq` — tolerates unknown `type` values and non-JSON lines across CLI-version drift; re-smoke after any `claude`/`codex`/`gemini` upgrade.
- Bus stays on a **local POSIX fs**; pointing `.bus` at a 9p/drvfs mount (`/mnt/c`, `/mnt/f`) silently breaks `tail -F`.
- `-L swarm` isolates the socket so the cockpit never disturbs your main tmux server.
- `ccusage` for cost, **never** summing `usage` per stream-json event (bug #6805 inflates 3–8×).

