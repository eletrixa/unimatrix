---
source: refactor (rfg-dxx-research D16 run rr-d16-search)
date: 2026-08-06
run: rr-d16-search
type: bug
severity: high
---

# codex lane dead: CLI refuses helper binaries under /tmp cage HOME

What happened: pre-claim probe FAIL exit 1 marked `codex.broken` at 2026-08-06T02:03:36Z; the
pinned judge card `ref2` sat `pinned-lane-blocked` for hours (parked, never served). Diag
(limits/codex.probe-stderr): `ld not create PATH aliases: Refusing to create helper binaries
under temporary dir "/tmp" (codex_home: AbsolutePathBuf("/tmp/tmp.FRnNRiEaco/home/codex/.codex"))`.

Expected: codex serves read-only judge cards under the env-i scratch-HOME cage (it did on
2026-08-05 — 9 prosecutor cards + earlier runs all clean).

Likely cause: a codex CLI update now refuses CODEX_HOME under /tmp (security hardening upstream).
The cage builds scratch HOME in /tmp by design, so the lane is structurally dead until the cage
gives codex a non-/tmp scratch home (e.g. under ~/.cache/unimatrix/cages/) or sets whatever
override the new CLI honors.

Evidence paths: ~/refactor/.bus-rr-d16-search/limits/codex.broken,
.../limits/codex.probe-stderr, .../limits/ref2.parked. No secrets in any of them.
