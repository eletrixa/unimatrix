---
source: unimatrix (orchestrator, thrifty1 close-out)
date: 2026-08-04
type: bug
severity: major
status: draft
---

Pre-existing test failures on the new Omarchy box (all reproduced on pristine 1dd835c
via a throwaway worktree — NOT thrifty regressions):

- tests/swarm-run-1.bats #14 "PAUSE mid-run blocks new claims; resume lets the run
  finish" — `_poll 20 test -f done/p3` times out, solo and under load.
- tests/unimatrix.bats install/here family (#17, #18, #19, #24) — fresh-fake-HOME
  install never creates `.config/unimatrix/config`; `here` fixture also red.
- Same class as the LANG=en_US.UTF-8 argv mismatch fixed in c07900e (tests assumed
  the WSL box's locale); these remaining ones need their own root-cause pass.
- Also: a full `./check.sh` (CHECK_JOBS=6) run gets externally killed on this box
  under the Claude Code background harness — chunked `bats` runs complete fine.
  Suspect memory pressure at 6-way fan-out; not investigated.

Everything else is green post-c07900e: 1000+ tests across all other files pass.

Update 2026-08-06: install/here family root-caused — the host XDG_CONFIG_HOME leaked through
the fake-HOME env spawns (tests overrode HOME only), so cmd_install/cmd_here wrote the real
~/.config/unimatrix. Fixed in v1.6.0 (env -u XDG_CONFIG_HOME at all 15 spawn sites). PAUSE poll
(swarm-run-1 #14) and swarm-run-4 #47 pass solo/serial — load flakes under CHECK_JOBS=6 remain
the open item on this box.
