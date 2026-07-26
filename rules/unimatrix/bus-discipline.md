---
applies-to: unimatrix bash orchestration
---

# Bus Discipline

The `.bus/` file-bus is the entire coordination layer — no DB, no MCP, no daemon. These rules are
load-bearing; violating any one silently corrupts the bus, usually without an error to notice.

## Filesystem

- **Local POSIX fs only.** The bus lives under `<repo>/.bus` — **never** a 9p/drvfs/NFS mount
  (e.g. a WSL Windows-drive mount under `/mnt/*`). Those mounts break `inotify`, `O_APPEND`
  atomicity, and `flock`. Pointing `.bus` at such a path is a silent, hard-to-diagnose failure
  class — check the path before wiring any new bus location.
- **One writer per JSONL file.** Each worker owns exactly one `run-<id>.jsonl`. No two processes
  ever append to the same file — that single invariant is what makes `O_APPEND` safe without a DB.
- **Orchestrator-only files:** `notes-lessons.md` at bus root is orchestrator-owned (single writer).
  Workers must never write or modify it.

## Writes

- **One JSONL record = one `write(2)` call, including the trailing newline.** Bash `echo >>` /
  `printf '%s\n' >>` are each a single syscall and fine as-is. Never assemble a record across
  multiple writes — a partial flush interleaved with another writer corrupts the line for every
  reader downstream.

## Reading answers

- **Answers come ONLY from each CLI's structured handoff file** — `codex --output-last-message
  <file>`, the `stream-json` `result` envelope. **Never** scrape the terminal or a captured pane.
  This is the one rule that makes delegation injection-safe and immune to the send-keys/ANSI
  failure class.

## Claiming (atomic, race-free)

- **`mv queue/<id> claimed/<id>` is NOT a race-safe claim.** `mv` silently overwrites an existing
  destination — two workers can both `mv` to the same shared name and both believe they won.
- **Correct claim:** rename to a **per-worker unique** destination:
  `mv queue/<id> claimed/<id>.<worker>`. The loser's `mv` fails with `ENOENT` (source already
  gone by the winner) — that failure IS the lost-race signal; check for it explicitly rather than
  assuming success.
- Same-filesystem only — rename is not atomic across mounts. `mkdir` (fails `EEXIST`) or a
  hardlink (fails `EEXIST`) are equivalent-guarantee alternatives if the rename shape doesn't fit.

## Invariants (explicit)

Already practiced by the code above; stated here as invariants so a future change can't drift off
them silently:

- **Claim = atomic `mv` from `queue/` to `claimed/`.** Rename is atomic on the same filesystem
  (ext4) — this is what makes the claim race-free without a lock file or a DB.
- **Every record carries a unique task id.** A duplicate claim or replay of the same id is a
  no-op, not a double-execution — the id, not the file's existence, is the identity a reader
  checks.
- **Serialize writes per session, throttle work globally.** One writer per JSONL file (above) is
  the per-session half; `FANOUT` (`swarm.conf`) is the global-throttle half — both exist so
  concurrent workers can never race the same bytes or overrun the box.

## Leases

- Workers `touch` their own claim file as a heartbeat while running.
- The reaper requeues based on **heartbeat age**, not claim age — and the TTL must be **much
  greater than** the max expected job runtime, or a slow-but-alive worker gets robbed mid-run.

## Firehose (monitor-only, never authoritative)

- Pipeline must be exactly: `tail -n +1 -F .bus/run-*.jsonl | jq -Rrc --unbuffered '...'`.
  **Unbuffered is mandatory** — without it the cockpit lags roughly 8KB behind the live stream.
  **`-R` (raw input) is mandatory** — the filter starts with `fromjson?`, which requires string
  input; without `-R`, jq pre-parses each line and silently drops every one. Add `stdbuf -oL` to
  any extra stage inserted into the pipe (`cut` included — it block-buffers to pipes).
- **Canonical filter program** (single source of truth — `src/swarm-lib.sh`'s `jq_firehose_filter`
  echoes this exact string; LOCKSTEP: a change to one is a change to both):
  ```
  fromjson? // empty | select(.type as $t | ["tool_use","tool_result","result","error","message","assistant","system","turn.completed","turn.failed","item.completed","text","end"] | index($t))
  ```
  `"text"`/`"end"` are the grok lane's answer-chunk and final-envelope event types — without them
  every grok branch is invisible in the cockpit. `"thought"` (grok's token-chunk reasoning spam) is
  deliberately NOT whitelisted — noise, never part of the answer (see "Reading answers" above).
- The firehose is a human glance-only overlay. It is never read for the answer — see "Reading
  answers" above.
