---
source: unimatrix
date: 2026-07-24
run: drill3 (spec-11 live takeover drill)
type: bug
severity: minor
triaged-to: backlog#38
---

The continuation driver's write cage (cwd = loop worktree, acceptEdits) cannot write the
FR-S4 handoff file at its canonical path `$busdir/loop/handoff-degraded.md` — the drill3 kimi
driver was permission-blocked and (correctly) wrote the file in its worktree with a
self-describing relocation header + kept the re-audit-first checklist. Machinery held, but the
FR-S4 gate then only arms after a human/Fable moves the file.

Options: spawn the driver with an --add-dir (or equivalent) grant for `$busdir/loop` only;
or the mandate names the worktree-relative path as canonical and watchdog-disarm/next-heartbeat
adopts it into the bus; or accept + document (the relocation header worked perfectly in the
drill). Evidence: .bus-drill archive, run-takeover.jsonl session 4a38a1be, drill3 worktree.
