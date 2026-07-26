# D2 Gate — phase 2 -> phase 3 decision criterion

**Date opened:** 2026-07-26
**Deadline:** 2026-08-16 (three weeks from the date opened)

## Criterion (P2-FR3 / decision D2), verbatim

From `plans/004-plugin-cli-cockpit-fleetops/PRD.md` §5, Phase 2 table:

> **P2-FR3** | **The gate.** Three weeks elapsed AND ≥2 decisions changed by that summary, written
> down with dates. | Recorded in `docs/ops/`. **If not met — stop here. The project is done, and
> cheaply.** *(#16, D2)*

From `plans/004-plugin-cli-cockpit-fleetops/pre-mortem.md` #16, "Nobody read the reports" (the
finding P2-FR3 exists to guard against):

> Identify the ONE query that changes behavior... deliver it as three lines appended to the run
> close-out... Build the page only after that line has changed a decision at least twice. If it
> never does, the project was correctly cancelled at zero cost.

**In one sentence:** phase 3 (the DB mirror) starts only if, by the deadline above, the three-line
lane summary (P2-FR1) has demonstrably changed at least two real operating decisions — each written
down here with its date — after at least three weeks running in the real close-out.

## Decisions log

Empty until a decision actually changes because of the summary. Add a row **when it happens**, not
retroactively at the deadline — "written down with dates" means the entry predates the deadline
check, not that it's reconstructed for it.

| date | decision changed | which summary line drove it |
|------|-------------------|------------------------------|
| | | |

## The rule

Phases **P3 (mirror)** and **P4 (cockpit online)** of
`plans/004-plugin-cli-cockpit-fleetops/PRD.md` **must not start** unless one of the following holds:

1. By 2026-08-16, the decisions log above carries **≥ 2 rows**, each with a real date on or before
   the check and a real decision — the criterion is met and recorded in this file, or
2. The maintainer explicitly overrules this gate **in writing** — a dated note added to this file,
   or a dated commit message that references this file. Silence, a verbal go-ahead, or phase-3 code
   simply appearing without either of the above does not satisfy this rule.

## Honest-cancel clause

If 2026-08-16 arrives and the decisions log above has fewer than 2 dated rows, **the criterion is
unmet and phase 3 does not start.** Per the PRD's own framing (pre-mortem #16; PRD §7 risk #1,
"nobody reads the reports"), that outcome is not a failure of this project — it is the project
working as designed: a pull-surface (DB mirror, cockpit reporting tab, dashboards) that nobody's
actual decisions needed gets identified and cancelled at the cheapest possible point, phase 2,
before a single line of DB code is written. Phases 0-2 (plugin, CLI, the push summary itself) stay
shipped and useful regardless of this gate's outcome.
