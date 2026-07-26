# 04 — Steelman court record

Six independent agents (advocate + prosecutor per candidate, disjoint prompts, no shared
conclusions; prosecutors ran on the stronger model). Full briefs with complete citations are in
the workflow journal; this file preserves every argument that moved the decision, plus the
cross-examination. Every claim below carries its citation in the original brief.

## C1 — node:sqlite local files + one server

**Advocate's strongest:** the only candidate that clears the ask-first dependency bar for free
(stdlib, no install) while foreclosing nothing — engine-portable schema keeps the Postgres/Brain
door open at near-zero cost. Supporting: zero-npm invariant preserved (better-sqlite3 breaks it);
extends the declared pattern (JSONL truth → droppable projection); atuin = years-shipped precedent
of exactly this evolution; WAL sweet spot = this workload; same local-fs rule the bus already
enforces; offline-complete where C2 fails; per-domain files = harder privacy boundary than schemas
in one reachable server; pure importer keeps check.sh DB-free.

**Prosecutor's strongest:** `|| true` at the call site + node:sqlite's **busy_timeout default
0 ms** = silent row loss on the most routine condition (two overlapping run closes), with only a
hand-run monthly `mirror --verify` as detector — an evidence store with no automatic completeness
check. Supporting attacks: `DatabaseSync` is sync-only and the server is one process with no
worker_threads → a year-of-rows history query blocks the live SSE firehose; **no Node floor is
pinned anywhere** (docs/versions.md has no Node row, no `engines` key, no `process.version` check)
on an API still Release-Candidate — and correctness needs ≥24 with `timeout` + `defensive` set
deliberately; `~/.local/share` on an unbacked-up WSL2 box is pre-mortem #20 verbatim, and the
obvious `cp` backup corrupts live SQLite files; the per-domain split is the same path convention
pre-mortem #12 already called out, and it deletes the cross-domain query; C1 = C3's archives + the
pull surface #16 rates as the project's #1 death, built before the gate designed to cancel it.

**Prosecutor's material concessions:** the Postgres/constitution argument is habit not law
(vault grep negative); C1's packaging claim is the cleanest of the three — **psql is ABSENT on
this machine** (verified) so C2's client is an ask-first install while node:sqlite is not; the
single-writer architecture is exactly what the multi-writer incident taught; exit cost really is
near zero; if not C1 then C3-now-C2-later, **not C2 today**.

## C2 — Postgres/Supabase uni_*, psql-client export

**Advocate's strongest:** the fleetops join is a `CREATE VIEW`, not a migration — Brain already
runs the structurally identical table (`ops.cockpit_run_telemetry`: stable columns + jsonb,
owner-pool-only) in the same engine family. Supporting: proven schema shape; psql simple-protocol
immunity to pooler traps; schema-per-tenant as a real primitive for the work/personal split;
managed durability erases #20; durability-sensitive data pulls toward Postgres.

**Advocate's material concessions:** the vault has NO Postgres-first policy; the synthesis itself
recommends deferring C2; #12's boundary problem isn't fixed by engine choice, and C2's mis-route
blast radius is *worse*; the offline history hit is real; build cost ≥ C1.

**Prosecutor's strongest:** **strictly dominated on timing** — the one real advantage is an
option on a counterparty verified to have zero code today, the schema is engine-portable so that
option stays near-free to buy later, and in exchange C2 pays immediately and permanently in the
three declared load-bearing currencies: network in front of the daily surface, a password inside
an `env -i`-caged harness, and a work/personal boundary spread across two cloud projects where a
mis-route is a PITR question instead of an `rm`. Supporting: "DB down" becomes the machine's
default state (train/plane/WSL2 loopback); the only candidate that *requires a credential to
exist* (#12's kill chain: DSN → env → worker log → .bus → archive → bug report); the
"(constitution default)" subtitle taxed C1 for deviating from a rule that does not exist;
single-operator Postgres evidence is structurally empty (nobody at n=1 writes the regret report);
per-statement WAN cost lands on the routine operation (monthly drop-and-rebuild, `--since`
backfills), with direct-connect availability an unverified ASSUMPTION; a Supabase project brings
its own API surface — the loopback-bind defence stops mattering once the data lives somewhere
reachable from anywhere; the live smoke is structurally outside check.sh forever (#15's skip-rot);
**169 rows do not justify the apparatus**.

**Prosecutor's material concessions:** durability is C2's real win and if the JSONL archives are
not actually backed up, "I do not have a counter"; if fleetops materializes with Brain as
consumer, C2 is straightforwardly simpler *then*; most attacks target cloud placement, not the
architecture (structure is identical to C1 — "a deployment-location decision wearing an
architecture decision's clothes").

## C3 — no DB: archives + static report, SQL deferred past the gate

**Advocate's strongest:** C3 is the literal build order the synthesis already recommended —
honoring the phase-2 gate instead of silently pre-empting it; C1/C2 shipping a DB now is choosing
Robert's override for him. Supporting: #16 is the top-ranked risk and C3 is architected around
it; zero sign-offs needed; cheapest to build and unwind; archival solves the rebuild corpus (#20)
as a byproduct; #15/#19 (test-gate erosion, hand-typed migration) structurally impossible;
DuckDB reads compressed JSONL with no projection; GoAccess/git-quick-stats prove the shape; 169
rows sit far below where a database pays.

**Prosecutor's strongest:** C3 is not the cheap option — it is a different build whose
differential deliverable is the worst part: a **third** independent derivation of
"$ per verified-done" in a repo where the two existing derivations **already disagree today**
(`src/speedwars-report.sh` joins verdicts on run/id/lane and counts unjudged cards as verified;
`site/cockpit/speed.js` joins on run/id and refuses — same ledger, two live answers). Supporting:
the phase-2 gate is candidate-independent, so C3 saves nothing pre-gate and spends more (archival
+ HTML renderer + history tab); spec 09 FR-2 wrote down the anti-drift principle C3 violates;
killing the mirror kills `mirror --verify` — the only proposed detector for the #2-ranked
failure; **duckdb is not installed** (ask-first) while sqlite3 and node:sqlite are both present;
`bus-archives/<run>.tar.zst` defeats DuckDB's globbing (needs `*.jsonl.zst`, which is what
pre-mortem #20 actually prescribed); ad-hoc raw queries are correction-blind — the escape hatch
resurrects the false-dones the ledger exists to expose; archives are gitignored/local/unbacked —
#20 already falsified "archives = durable"; **this repo's own history proves deferred infra
doesn't get built** (`bus-archives/` reserved and never written; spec 16's deferral is why this
plan exists); prompt-bearing tarballs become a first-class artifact — a privacy blast radius the
DB candidates exclude by construction (spec 08's zero-prompt-text rule has no C3 equivalent);
the "unchanged deps" framing overstates savings (a second served root or CLI-writes-into-served-
tree vs C1's `await import()` + SELECT).

**Prosecutor's material concessions:** #16 is the best-evidenced claim in the pack — any pro-DB
case that waves it away is dishonest; scale genuinely never needs SQL here — the case must be
made on correction-folding, join-key integrity and a verify harness, or not at all; **run-close
archival is C3's real contribution and should be adopted by whichever candidate wins**; C3 is
safest on the zero-dep-rot risk; the drift attack cuts at C1 too — a database does not delete
`speed.js`; the honest C3 mitigation (renderer shells out to speedwars-report.sh) recreates the
"one projection" concept C3 claims to avoid.

## Cross-examination (orchestrator pass)

**C1-adv strongest vs C1-pros strongest.** The advocate's "requires no permission, forecloses
nothing" survives only if the silent-loss attack is answered in the design, not in prose. It can
be — but the cleanest answer abandons node:sqlite: apply the projection through the **system
`sqlite3` CLI** (present on this box; `.timeout` set; single transaction; execFile'd from the
server for reads exactly like `swarm-ctl` already is). That one substitution deletes the
busy_timeout default, the sync-driver event-loop fusion, the unpinned Node floor, and the
RC-stability exposure in a single move, while keeping every advocate point intact. The `|| true`
attack is answered by "loud non-fatal": import failure writes a durable marker the cockpit
surfaces + stderr, and `mirror --verify` gains an automatic row-count completeness check at
import time. Rebuttal verdict: **C1's shape survives; C1's specified implementation does not.**

**C2-adv strongest vs C2-pros strongest.** `CREATE VIEW` vs "dominated on timing": the advocate
has no answer to the verified absence of the counterparty plus the near-zero deferral cost his
own side conceded — and the psql-absent finding converts C2's "no new dep" premise into an
ask-first install today. Rebuttal verdict: **C2 is the right endgame if fleetops materializes,
wrong as a first move. Defer intact.**

**C3-adv strongest vs C3-pros strongest.** "Honor the gate" survives — but the prosecutor showed
honoring the gate does not require C3's differential build (third renderer), and C3's archive
format was wrong (`*.jsonl.zst`, not tarballs) while its privacy posture was unexamined. The
gate, the archival (corrected format, prompt-text caveat documented), and the push summary all
transfer to the winner; the static-HTML report shrinks to a `report --html` convenience that
shells the canonical fold rather than re-deriving. Rebuttal verdict: **C3's discipline and
archival are adopted; C3 as a destination is not.**

**Court-discovered defect owned by no candidate:** the existing fold divergence
(speedwars-report.sh vs speed.js). Unifying to ONE canonical verdict-fold semantic — with a
shared fixture asserting both surfaces produce identical numbers — is prerequisite work for ANY
candidate and lands in phase 0/2.

**Verdict input to scoring:** C1 amended (sqlite3-CLI application, loud non-fatal import,
archives adopted from C3, gate honored) is the shape the court converged on. The matrix in
00-SYNTHESIS.md scores the candidates as written; the recommendation's deviation from as-written
C1 is argued there.
