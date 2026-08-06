---
source: refactor
date: 2026-08-06
run: rr-d14-finance
type: friction
severity: medium
---
Two coupled frictions on judge-seat cards. (1) Cage geometry: a scorer card with `.write = <output dir>` is READ-caged to that dir too; judge seats need the widest evidence tree readable, and both opus scorers in this run worked citation-restricted (they declared it and the refuter closed the gap, but the class is silent when a seat does not declare). Consider a `.read` sidecar or a documented judge-seat cage convention (cage = evidence root, `.files` scopes the write). (2) Sidecar precedence: updating `specs/<id>.write` for a card already in `queue/` is a no-op (queue sidecars win as operator hints) and the nudge re-serves with the OLD cage; the working recovery is cancel + reseed under a new id. Evidence: .bus-rr-d14-finance run-score-solutions.jsonl (cage-denied park listing raw/ and rulings paths), driver logs bu7xz2gfa/bfxj7eoap outputs.
