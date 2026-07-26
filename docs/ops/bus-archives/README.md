# Bus archives — the structured backup target

Written by `bus_archive()` (`src/swarm-lib.sh`), fired from `_close_out_evidence()`
(`swarm-run.sh`) at the end of every `full_run` / `verify_run`. This directory is what you back up:
everything under a `.bus/` tree is ephemeral, and only the speedwars ledger used to survive a bus
cycle.

## Layout

One directory per run label, globbable by design:

```
docs/ops/bus-archives/<run-label>/
  run-<id>.jsonl.<ext>          # every worker transcript
  run-<id>.jsonl.<n>.<ext>      # its rotated predecessors
  run-<id>.jsonl.stderr.<ext>   # per-worker stderr
  res-<id>.txt.<ext>            # handoff answer files
  write-<id>.txt.<ext>          # write-card target provenance
  speedwars.jsonl.<ext>         # this run's ledger rows (filtered on .run)
  markers.tar.<ext>             # done/ + limits/ marker trees, one tar (thousands of tiny files)
  run-summary.json              # the run's last run-summary ledger row, uncompressed
  MANIFEST.txt                  # run, timestamp, bus basename, compressor, member list
```

`<ext>` is decided **per run, at runtime**: `zst` when a `zstd` binary is on `PATH`, otherwise
`gz`. gzip is always present, so the archive never depends on a tool the box may not have — zero
new runtime dependency either way. `MANIFEST.txt` records which one ran, and says so explicitly
when gzip was substituted. Do not assume an extension when consuming these — glob
`*.jsonl.zst *.jsonl.gz`, or read `MANIFEST.txt`.

Older archives here are whole-bus tarballs made by hand (`<run>-bus.tar.zst`) and predate this
layout.

## Rules

- **Idempotent per run label.** Re-closing a run replaces its own directory and nothing else. The
  label is sanitized to `[A-Za-z0-9._-]`, and `.` / `..` are refused, so no label can write outside
  this tree.
- **Never fatal.** An unwritable directory, a missing tool, or a compressor error is a silent
  no-op — evidence capture may never fail an otherwise-good run.
- **No archive without an evidence surface.** Same doctrine as the speedwars ledger itself: the
  resolved `docs/ops/` directory must already exist, or nothing is written. Set `BUS_ARCHIVE=0`
  to turn archiving off entirely.

## Privacy — why these files are gitignored

`res-*.txt`, `run-*.jsonl` and `write-*.txt` hold **worker output**: answer text, tool transcripts,
and anything a worker fetched from the web while producing it. `CLAUDE.md` §Git forbids committing
worker output for exactly that reason, so everything in this directory except this README is
excluded in `.gitignore`:

```
docs/ops/bus-archives/*
!docs/ops/bus-archives/README.md
```

That is deliberate and load-bearing — it is also why archives are the **backup** target rather than
a tracked one. Back this directory up out-of-band; do not "fix" the ignore rule to get it into git.
