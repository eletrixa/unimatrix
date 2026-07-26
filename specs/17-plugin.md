# Spec 17 — Plugin Packaging: `/u:*` from Any Repo, `unimatrix` install/here/doctor

**Status:** Active (maintainer approval basis: Robert's plan-B execution order of 2026-07-25/26,
which mandates implementing P1 against this spec; flipped 2026-07-26 with FR-1..8 implemented and
both live proofs recorded below)
**Date:** 2026-07-25
**Related specs:** [15-direct-call](./15-direct-call.md) (the `call` verb the plugin fronts),
[16-unified-cli](./16-unified-cli.md) — **direct lineage**: spec 16's Non-Goals deferred exactly
this work ("No true `/u:call` colon-namespaced plugin command and no cross-repo command
availability — both require plugin packaging, deferred to a future spec", lines 32-33). Spec 17 is
that future spec. Also: 01 (bus lifecycle, `.bus` layout), 04 (`swarm.conf`), 12 (`run_summary`
ledger record), 13 (`doctor`, env-master preflight).
**Plan of record:** [plans/004-plugin-cli-cockpit-fleetops/PRD.md](../plans/004-plugin-cli-cockpit-fleetops/PRD.md)
§5 Phase 1. FR-1…FR-8 below map **1:1** onto P1-FR1…P1-FR8; each FR quotes its PRD acceptance
criterion verbatim, tripwire citation `(#n)` included — the tripwires are
[pre-mortem.md](../plans/004-plugin-cli-cockpit-fleetops/pre-mortem.md) §"The 20 ways it died".

---

## Overview

Today the `u-` namespace is a **filename prefix** inside one repo's `.claude/commands/`, and the
skill is **copied** into every account directory by hand. Both facts stop at the repo boundary:
a session opened anywhere else has no `/u-call`, and "all accounts are in sync" is a snapshot
someone took once, not a property anything enforces. Spec 16 said so itself and deferred the fix.

Spec 17 packages the already-shipped commands and skill as an **in-repo Claude Code plugin** served
from a **self-marketplace**, so `/u:call` exists in every session on this box regardless of cwd, and
finishes the `unimatrix` router (spec 16) into an installed tool with `install`, `here`, and
`doctor --plugin`. The engine is **not** packaged: the plugin ships prompt text and a skill, and
every command body resolves the one engine checkout at invocation time through a single path
resolution order. Distribution is the deliverable; behavior is unchanged.

The load-bearing risk is not "does the plugin install" — it is that a plugin adds a **third home**
for the same prompt prose (repo `.claude/commands/`, `plugin/commands/`, per-account copies) and a
**fourth** way to point at the wrong checkout. Prompt text has no compiler: a stale copy produces
plausible wrong behavior instead of a crash, and presents as "the model did something dumb" (#18,
#6, #8). Every FR below is therefore either a generation rule, a drift check, or a banner.

Pre-merge scaffolds already landed on this branch (commit `7b0dda1`) and are **drafts this spec
codifies**, not settled design: `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`,
`plugin/gen-commands.sh`, `plugin/README.md`.

## Goals

- **`/u:*` in any repo, any account, one version** — proven by a drift table, not by a snapshot.
- **One body per command prompt**; every other copy is generated and diffed in `check.sh`.
- **The engine stays one checkout** behind `$UNIMATRIX_HOME` — the plugin never vendors it.
- **Install and bootstrap are idempotent one-liners**, re-runnable after every version bump, because
  manual fan-out to N targets has a compounding per-update failure probability.
- **Every run says which checkout it chose, out loud**, so a wrong-worktree dispatch is a visible
  line rather than twenty minutes of debugging a run that was working perfectly, somewhere else.

## Non-Goals

- **No engine vendoring.** The plugin carries commands + skill only; `swarm-run.sh`,
  `swarm-loop.sh`, `swarm-mon.sh`, `src/swarm-lib.sh`, `src/swarm-ctl` stay in the checkout and are
  never copied into a plugin payload, an account dir, or a marketplace artifact.
- **No statusline change, ever.** The session marker is a **frozen external interface** (chmod 444,
  changes only on the maintainer's explicit in-conversation ask). FR-7 reads it; nothing in this
  spec, or in any note written under it, proposes adding a field to it *(#11)*.
- **No MCP, no daemon, no new runtime dependency.** Install and doctor use bash, `git`, `jq`, and
  `stat` — all already required by the stack.
- **No GitHub-sourced marketplace yet.** D3 resolves to directory-sourced from the local checkout
  now; GitHub-sourced at the first stable release after the plugin has settled.
- **No database, no cross-run mirror, no cockpit reporting tab, no fleetops artifact.** Those are
  phases 3-5 of the dossier; phase 2 (the push summary, the evidence contract, the D2 gate) is now
  [spec 18](./18-evidence-contract.md), and the still-unbuilt executable mirror (phase 3, gated
  behind D2) is reserved for spec 19 or a numbered amendment to spec 18. **Dated clause,
  2026-07-26:** spec 18 FR-5 ships the fleetops **evidence contract document**
  (`docs/fleetops-contract.md` + `sql/uni-schema.sql` + golden fixtures) *ungated*, per the D1
  contract-first decision — that is a document, not code, and does not contradict this Non-Goal.
  This Non-Goal continues to bind **engine code paths**: no DB reference in
  `swarm-run.sh`/`swarm-loop.sh`/`swarm-mon.sh`/`src/swarm-lib.sh`, enforced mechanically by
  `check.sh`'s DB-symbol gate. Nothing in this spec, or in spec 18, writes SQL from inside the
  engine; the `fleet.json` registry FR-4 writes is a *registry*, not a policy file or a store.
- **No behavior change to any verb.** `call`, `run`, `loop`, `mon` and the ctl verbs behave exactly
  as specs 15/16 define them whether reached through a slash command, the router, or a direct
  script invocation.

## FR-1 — In-repo plugin + self-marketplace; the engine stays a checkout

**As shipped** (Open question 1, below, resolved to option (b) — see its dated Resolution entry for
the evidence): `.claude-plugin/marketplace.json` at the **repo root** — required to stay there,
since `/plugin marketplace add <repo path>` looks for it exactly there — is a **self-marketplace**
sourcing its one plugin entry at `"source": "./plugin"`. `plugin/.claude-plugin/plugin.json` is the
plugin manifest itself, declaring the plugin **`u`** (so its commands surface as `/u:call`,
`/u:swarm`, `/u:loop`, `/u:speedwars`, `/u:setup` — the colon namespace comes from the plugin name,
which is why the name is one letter). The checkout is both the marketplace and the plugin and there
is no publish step between an edit and a session that sees it (D3 — the precedent for a
directory-sourced marketplace on this box is live and working). The root-level
`.claude-plugin/plugin.json` this FR originally described does not exist on the shipped tree — it
moved under `plugin/`, not duplicated there.

The plugin payload is **commands + skill only**. No engine script, no `swarm.conf`, no `.bus`
template is copied into it. Every command body reaches the engine through FR-6's resolution order at
invocation time, which is what makes "one engine, many sessions" true rather than aspirational.

`plugin.json.version` and the marketplace entry's `version` carry the **release version** — both are
updated by hand as one line of the release checklist (`docs/releasing.md`'s version-stamp table),
alongside `package.json` and the skill's frontmatter, at every version cut. There is no build-time
stamper: `plugin/gen-commands.sh` (FR-2) regenerates command stubs but never touches either
manifest's `version` field, and `check.sh`'s drift step does not check it either — a release cut
that skips that checklist line ships a manifest whose version lags the changelog until the next
release remembers to fix it. Both manifests read `1.1.0` today, matching the newest cut release
heading in `CHANGELOG.md` at time of writing — kept in sync by hand, not by a generator.

> **Acceptance criterion (PRD P1-FR1, verbatim):** `/plugin marketplace add <repo path>` then
> install yields working `/u:call` in a session opened in an unrelated repo *(D3)*

## FR-2 — Plugin commands are generated, never hand-copied

One canonical body per command lives in `.claude/commands/u-<name>.md` (spec 16 FR-5 put it there).
`plugin/gen-commands.sh` is the **only** producer of `plugin/commands/<name>.md`, and each generated
file is a **≤3-line pointer stub** that names an existing target and carries no frontmatter, no
absolute host path, and no prose that could go stale independently. Generation is deterministic
(sorted source order, no timestamps) and idempotent (a second run with no source change leaves the
tree byte-identical).

`check.sh` gains a step that regenerates into a temp dir and **diffs against what is committed**; a
mismatch fails the gate. That is what makes "generated" a property rather than a convention — a
hand-edited stub cannot survive a green check. The same step asserts the ≤3-line bound and that each
stub's named target exists, and runs the duplicate-prose detector: normalize command bodies across
`.claude/commands/`, `plugin/commands/`, and any account skill/command file, then
`sort | uniq -d` — a duplicated 20-word sentence means a body got copied instead of pointed at.

**Where the generated commands live must satisfy plugin discovery.** With `"source": "."` the plugin
root is the repo root, so a `commands/` directory at the plugin root is what a session loads —
`plugin/commands/` is discovered only if `plugin.json` declares the path explicitly. See
[NEEDS CLARIFICATION] 1; the generator's output path follows that resolution, and FR-1's live proof
is what settles it.

> **Acceptance criterion (PRD P1-FR2, verbatim):** The build script runs in `check.sh` and its
> output is diffed against what's committed; `sort | uniq -d` over normalized command bodies finds
> no duplicated 20-word sentence; every stub is ≤3 lines and names a target that exists *(#18)*

## FR-3 — `unimatrix install`

One idempotent verb that makes the tool reachable, run again after every version bump:

1. **PATH symlink** — symlink the `unimatrix` router (spec 16) into a PATH directory, defaulting to
   `~/.local/bin/unimatrix`, overridable with `--prefix <dir>`. If the chosen directory is not on
   `$PATH`, install says so and continues (the symlink is still correct; only reachability is the
   operator's to fix). An existing symlink pointing at this checkout is a no-op; an existing
   **regular file** at the target is a hard refuse — install never overwrites something it did not
   create. See [NEEDS CLARIFICATION] 2.
2. **`~/.config/unimatrix/config`** — write `UNIMATRIX_HOME` (this checkout, absolute, resolved) and
   `ENV_MASTER_FILE` (defaulting to `${XDG_CONFIG_HOME:-$HOME/.config}/unimatrix/env.master`,
   per CLAUDE.md §Conventions). The file is bash-sourceable `KEY=VALUE`, the same shape as
   `swarm.conf`, and is the home of the work/personal boundary prefix a later phase reads
   (PRD §9 resolution 3) — this spec writes the file and the two keys, nothing more.
3. **Marketplace + plugin enablement across every target account** — add the self-marketplace and
   enable plugin `u` in **`~/.claude/settings.json` plus every `~/.claude-acct/*/settings.json`**
   (PRD §9 resolution 2: all of them — the 11 files discovery found; the separate set of accounts
   holding *skill copies* stops being a set anyone tracks once phase 0 symlinks them). Each file is
   edited by a **`jq` merge that preserves every unrelated key**, never a rewrite, and the pre-edit
   content is backed up beside the file. The block written matches the shape those settings files
   already carry, read from a live file at implementation time — install does not invent a schema.
4. **Idempotence** — a second run makes no change to any of the four surfaces. Install prints one
   line per target with `added` / `unchanged`, so "nothing happened" is visible rather than assumed.

> **Acceptance criterion (PRD P1-FR3, verbatim):** Running it twice changes nothing the second time;
> all target accounts end at the same version *(#6)*

## FR-4 — `unimatrix here`

Bootstrap the current repo as a swarm target, in this order, refusing before it writes anything:

1. **Local-POSIX filesystem verification, first and blocking.** `stat -f -c %T .` (with the
   `-f%T`/BSD spelling as fallback) must not report `9p`, `drvfs`, `fuseblk`, `nfs`, `cifs`, or
   `smb`. On a hit, `here` **refuses**: nonzero rc, nothing created, and an error naming the
   detected filesystem type and the reason — `O_APPEND` atomicity, `flock`, and `inotify` all break
   on those mounts, which is the invariant `rules/unimatrix/bus-discipline.md` exists to protect and
   CLAUDE.md §Boundaries lists under **Never**.
2. **`.bus`** created with the spec 01 subtree (`specs/ queue/ claimed/ done/ limits/ loop/`).
3. **`swarm.conf`** seeded from `swarm.conf.example` **only if absent** — an existing conf is never
   touched, since it carries the operator's lane choices.
4. **`.gitignore`** gains `.bus*` if not already covered, so a bus never reaches a commit.
5. **`~/.config/unimatrix/fleet.json`** gains a registry entry for this repo: absolute realpath,
   repo name, and the bus path. Re-running updates the existing entry in place rather than
   appending a duplicate — the registry is keyed by realpath.
6. **Cockpit URL printed** (the loopback `:4747` address, spec 05), so the operator's next action is
   a click and not a lookup.

The registry is what a later fleet view reads; this spec's obligation ends at "the entry exists and
is well-formed". See [NEEDS CLARIFICATION] 3 on the half of the PRD criterion that names a
phase-4 consumer.

> **Acceptance criterion (PRD P1-FR4, verbatim):** Run in a fresh repo on a `/mnt/*` path → refuses
> with the reason; run on a local path → registry entry exists and the fleet wall (P4-FR4) can see it

## FR-5 — `unimatrix doctor --plugin`

Extends spec 13's `doctor` with a plugin lane. Plain `doctor` stays read-only and free; `--plugin`
adds no spend either — it is four checks and a table:

1. **Manifest parses** — `plugin.json` and `marketplace.json` are valid JSON with the expected keys.
2. **Marketplace resolves** — the configured marketplace source points at a directory that exists
   and contains this plugin.
3. **`UNIMATRIX_HOME` resolves** — FR-6's order runs and reports the chosen root, the rule that
   chose it, and the paths it skipped.
4. **Install-drift table** — one row per target account: `account | installed hash | repo hash |
   verdict`. Green means every account's installed artifact hashes equal to the repo's canonical
   file. The table is the answer to "are all accounts in sync", asked mechanically instead of
   assumed; `md5sum` over the account skill files producing more than one hash is the tripwire that
   was available every day and checked never *(#6)*.

The skill's frontmatter carries a **version stamp** (today it carries only `name` and `description`),
stamped by the same FR-2 generator from the same changelog source as FR-1. At run start, a session
whose plugin version differs from the resolved checkout's version prints **exactly one warning
line** naming both versions — one line, because a warning that repeats stops being read.

> **Acceptance criterion (PRD P1-FR5, verbatim):** The drift table is green; planting a modified copy
> in one account turns it red *(#6)*

## FR-6 — Exactly one path-resolution implementation

One function, one file, every caller. The order is:

1. **`$UNIMATRIX_HOME`** if set and it contains the engine (`swarm-run.sh` present).
2. **The plugin's own directory** (`${CLAUDE_PLUGIN_ROOT}` when a plugin command is the caller),
   walked up to the checkout root.
3. **`git rev-parse --show-toplevel`** from the caller's cwd, if that toplevel contains the engine.
4. **Loud failure** — nonzero rc and an error that names **every path tried and why each was
   rejected**. Never a silent fallback to a guess; a wrong-checkout dispatch that runs is strictly
   worse than a refusal that doesn't *(#7)*.

No absolute host path appears anywhere in `.claude/**`, `plugin/**`, `site/`, `src/`, or any `*.sh`
— phase 0's `check.sh` grep enforces that, and this spec must not reintroduce one (the skill's
`Module:` header line is the known offender phase 0 removes).

Every run prints the phase-0 banner — resolved root, branch, HEAD short sha, absolute BUSDIR — and
`GET /health` returns the same four fields. That banner is how "landed in the intended worktree" is
observed rather than inferred, with all three worktrees (`~/code/unimatrix`,
`~/code/unimatrix-calldev`, `~/code/unimatrix-stable`) present and resolvable *(#8)*.

> **Acceptance criterion (PRD P1-FR6, verbatim):** Dispatch from a foreign repo lands in the intended
> worktree **and says so out loud** (P0-FR4's banner) *(#7, #8)*

## FR-7 — `run_summary()` stamps session identity — read-only, frozen interface

`run_summary()` (spec 12's run-level ledger record) gains three fields: **`session_id`**, the
**statusline session marker exactly as it already exists**, and the **orchestrating account**
(derived from the account config directory in the environment). They are join keys for a future
consumer; nothing in this spec reads them back.

**The statusline is a frozen locked interface.** It is `chmod 444`, its 24-emoji marker set and hash
are load-bearing for an external mirror, and its change protocol requires the maintainer's explicit
in-conversation request. Consumption here is **read-only and one-directional**. If a future join is
not clean with what the marker already emits, the correct answer is to accept the ambiguity and
label the number approximate — **not** to add a field. Any note, spec, comment, or commit message
containing the sentence "add X to the statusline" is a spec violation, and the acceptance criterion
below is written to catch exactly that sentence *(#11)*.

Where the three values come from at spawn time is not yet settled — see [NEEDS CLARIFICATION] 4.

> **Acceptance criterion (PRD P1-FR7, verbatim):** The three fields appear in `run-summary` rows;
> no design note anywhere contains "add X to the statusline" *(#11)*

## FR-8 — `/u-*` filename-command deprecation, two releases, then done

Three generations of command surface exist; this FR retires exactly one of them on a fixed schedule:

- **Release N** (the release that ships `/u:*`): the `/u-*` filename commands from spec 16 keep
  their canonical bodies and gain **one deprecation line** each, naming the `/u:` replacement. Both
  surfaces live simultaneously for exactly this one release.
- **Release N+1**: the `/u-*` files are **deleted**. The canonical bodies move to wherever FR-2's
  generation resolves, and one surface remains.
- **Forever**: the pre-spec-16 bare names — `/swarm`, `/swarm-loop`, `/speedwars`, `/setup` — stay
  as **≤3-line stubs**. They cost nothing, they are what muscle memory types, and deleting them
  buys a keystroke back from the only user.

The release checklist (`docs/releasing.md`) grows one line for the stamp-and-install loop:
bump the changelog, regenerate + re-stamp (FR-2), run `unimatrix install`, confirm
`doctor --plugin` is green.

> **Acceptance criterion (PRD P1-FR8, verbatim):** Both surfaces exist for exactly one release;
> after that, one surface *(#18)*

---

## Acceptance criteria

Each FR's verbatim PRD criterion above is the criterion; this list is the gate-level roll-up.

1. **FR-1** — marketplace add + install yields a working `/u:call` in a session opened in an
   unrelated repo *(D3)*.
2. **FR-2** — `check.sh` regenerates and diffs; no duplicated 20-word command sentence anywhere in
   the tree; every stub ≤3 lines and names an existing target *(#18)*.
3. **FR-3** — `unimatrix install` run twice changes nothing the second time; every target account
   ends at the same version *(#6)*.
4. **FR-4** — `unimatrix here` refuses on a non-local filesystem with the reason and writes nothing;
   on a local path it leaves a well-formed `fleet.json` entry.
5. **FR-5** — `doctor --plugin`'s drift table is green; a modified copy planted in one account turns
   it red *(#6)*.
6. **FR-6** — dispatch from a foreign repo with all three worktrees present lands in the intended
   worktree and the banner says which *(#7, #8)*.
7. **FR-7** — `session_id`, session marker, and orchestrating account appear in `run-summary` rows;
   no artifact in the repo contains "add X to the statusline" *(#11)*.
8. **FR-8** — both command surfaces exist for exactly one release; one surface after that *(#18)*.
9. `check.sh` green (shellcheck, full bats, PII gate, plus FR-2's regenerate-and-diff step).

## Test plan

**bats-testable** — hermetic, no network, no live session, runs in `check.sh`:

| Criterion | Test shape |
|---|---|
| FR-2 generation | Run the generator into a temp dir, diff against `plugin/commands/`; assert byte-identical on a second run (idempotence); assert every stub ≤3 lines; assert each named target exists. |
| FR-2 duplicate prose | Normalize + `sort \| uniq -d` over command bodies; assert empty. A planted duplicated sentence must fail it. |
| FR-1 manifests | Assert `plugin.json`/`marketplace.json` parse and that their `version` equals the newest `## [x.y.z]` heading in `CHANGELOG.md`. |
| FR-3 idempotence | Point `HOME` at a temp dir seeded with fake settings files, run install twice, assert the second run's diff is empty and that unrelated keys survived the `jq` merge. Assert a regular file at the symlink target is refused. |
| FR-4 refusal | Stub `stat -f` (or inject the detected type) to report `9p`/`drvfs`/`fuseblk`; assert nonzero rc **and** that no `.bus`, no conf, and no registry entry were created. |
| FR-4 happy path | Run in a temp git repo on a local path; assert the `.bus` subtree, the seeded conf, the `.gitignore` line, and a well-formed `fleet.json` entry; assert re-running updates in place rather than duplicating. |
| FR-5 drift table | Seed two fake account dirs, one matching and one modified; assert green then red, and that the verdict column names the drifted account. |
| FR-6 resolution | Run the resolver from `/tmp`, from a foreign git repo, and with `UNIMATRIX_HOME` set/unset/pointing at a non-engine dir; assert the chosen root each time and that the failure case names every path tried. |
| FR-6 banner | Assert the banner's four fields and that `/health` returns the same four. |
| FR-7 stamping | Feed a fixture environment; assert the three fields appear in the `run-summary` row. |
| FR-7 / Non-Goals | Grep the tracked tree for "add X to the statusline" — shaped as a phrase match on statusline-mutation language; assert zero hits. |
| FR-8 | Assert the bare-name stubs are ≤3 lines and resolve; per-release, assert the deprecation line is present (release N) then that the files are gone (release N+1). |

**Live-proof only** — cannot be asserted in bats, must be exercised by hand and the result recorded
in the changelog entry for the release that ships this spec:

1. **FR-1 end-to-end**: `/plugin marketplace add <this checkout>`, install plugin `u`, then open a
   session in an **unrelated repo** and run `/u:call` — it must exist, dispatch, and the banner must
   name this checkout. This is the one criterion the whole spec exists for and no test can fake it.
2. **FR-3 across real accounts**: run `install` against the real settings-file set, then
   `doctor --plugin`, and confirm the drift table is green for every account.
3. **FR-6 with three real worktrees**: dispatch from a foreign repo with all three checkouts
   present, confirm the banner names the intended one — the failure mode is silent, so the check is
   observation, not assertion.
4. **FR-5 version warning**: with a deliberately mismatched plugin/repo version, confirm exactly one
   warning line at run start.

## Known limits

- **The install writes outside the repo.** `~/.local/bin`, `~/.config/unimatrix/`, and every
  settings file are host state that `check.sh` cannot gate and `git` cannot revert. Idempotence,
  the `jq` merge, the backup, and the never-overwrite-a-regular-file rule are the whole mitigation;
  a hand-edit between installs is not detected until `doctor --plugin` next runs.
- **Drift is detected, not prevented, wherever a real copy is unavoidable.** Symlinked skill files
  cannot skew; a plugin payload that a session materializes as a copy can. FR-5's table is the
  compensating control, and it only reports when someone runs it.
- **The version stamp is only as honest as the changelog.** Version truth is the newest release
  heading; a release cut without regenerating fails the gate, but a changelog heading that does not
  reflect what shipped is not detectable by any check here.
- **`stat -f` type names are platform-specific.** The refusal list is the set observed on this
  stack; an unlisted-but-unsuitable filesystem passes. The check is a tripwire against the known
  mistakes (a `/mnt/*` Windows mount, an NFS home), not a proof of POSIX semantics.
- **`/u:*` collides with any other plugin named `u`.** The one-letter name is what makes the
  namespace short; if a second `u` plugin ever exists on this box, one of them must be renamed.

## Dependencies

**Internal:** spec 16 (the `unimatrix` router this extends, and the `u-` bodies FR-2 generates from),
spec 15 (the `call` verb `/u:call` fronts), spec 01 (`.bus` subtree FR-4 creates), spec 04
(`swarm.conf` FR-4 seeds), spec 12 (`run_summary()` FR-7 extends), spec 13 (`doctor` FR-5 extends).
**Phase order:** phase 0 of the PRD (one `_run_label()`, symlinked account skills, one resolution
order, the run banner, `check.sh`'s host-path and DB greps) is a **prerequisite** — FR-5's drift
table and FR-6's banner both assume it landed.
**External:** none beyond the current stack — bash ≥ 5.1, `git`, `jq`, coreutils `stat`. No npm
package, no MCP server, no daemon.

## Open questions — [NEEDS CLARIFICATION]

1. **Generated-command discovery path vs. `"source": "."`.** With the marketplace entry sourced at
   the repo root, the plugin root *is* the repo root, so a session loads `<repo>/commands/` — while
   the landed scaffold generates into `<repo>/plugin/commands/`. Two valid resolutions: (a) keep
   `source: "."` and declare an explicit commands path in `plugin.json` pointing at
   `./plugin/commands`; or (b) move the manifest under `plugin/` and source the marketplace at
   `./plugin`. Both are one-line changes, and FR-1's live install proves which one Claude Code
   actually honors — but the choice changes where committed files live, so it is not being guessed
   here.
   **RESOLVED 2026-07-26 → option (b).** See "Resolutions — 2026-07-26 — Open question 1" below for
   the evidence survey; FR-1 above now describes the shipped layout.
2. **PATH symlink target directory.** The PRD says "symlink the router onto `$PATH`" without naming
   a directory. FR-3 proposes `~/.local/bin` with a `--prefix` override; confirm that directory is
   on the operator's `$PATH` on this box, or name the intended one.
   **RESOLVED 2026-07-26 → `~/.local/bin`, no fallback needed.** See "Resolutions — 2026-07-26 —
   Open question 2 (PATH symlink target directory), tested and closed" below.
3. **FR-4's acceptance criterion references a phase-4 deliverable.** "the fleet wall (P4-FR4) can
   see it" cannot be satisfied while phase 4 is unbuilt and gated behind the D2 decision. Proposed
   P1-verifiable substitute: the `fleet.json` entry exists, is valid JSON, contains the repo
   realpath + bus path, and re-running updates in place. Confirm that substitution, or defer the
   second half of the criterion to whichever spec builds the wall.
   **RESOLVED 2026-07-26 → the proposed substitute, accepted unchanged.** See "Resolutions —
   2026-07-26 — Open question 3 (FR-4's phase-4-shaped acceptance criterion), accepted substitute"
   below.
4. **Provenance of FR-7's three fields.** (a) `session_id`: a swarm is spawned as a subprocess of a
   Claude Code session, and it is not established that a session identifier reaches that
   subprocess's environment. If it does not, where does the value come from? (b) The **session
   marker**: it is derived by the locked statusline from a hash of the session id over a 24-emoji
   set. Does unimatrix **re-derive** it with a copy of that hash (a copy that can silently drift from
   a file nobody may edit), or **read** it from an artifact the statusline already writes? (c) The
   **orchestrating account**: confirm the account config directory environment variable is the
   intended source. This is precisely the tripwire-#11 shape — the answer must not require touching
   the statusline, and if no clean answer exists, FR-7 should stamp what is available and label the
   join approximate rather than grow the frozen interface.
5. **Deprecation timing vs. release cadence.** FR-8 spends two releases; releases are cut once
   `[Unreleased]` accumulates 3-5 user-facing features. Confirm that "release N+1" means the next
   cut release however soon it lands (and not a minimum elapsed time), so `/u-*` deletion is not
   accidentally same-week.

## Resolutions

### 2026-07-26 — Open question 4 (provenance of FR-7's three fields), tested and closed

Tested live on the maintainer's own box (not guessed) before writing `_session_stamp()`
(`src/swarm-lib.sh`) or its tests (`tests/swarm-lib.bats`, "spec17 FR-7" block):

- **(a) `session_id` reaches a run's environment.** `env | grep CLAUDE_CODE_SESSION_ID` inside a
  live Claude Code session prints a UUID that matches the session's own id — Claude Code sets this
  var, and it is inherited by every child process, including `run_summary`'s own shell (which
  executes in the orchestrator's process tree, never inside a lane's `env -i`-scrubbed cage — the
  scrubbing in `rules/unimatrix/model-lanes.md` applies to spawned lane workers, not to the
  orchestrator calling `run_summary`). **Resolution: read `$CLAUDE_CODE_SESSION_ID` verbatim, else
  `null`.** No derivation, no fallback source — spec 17's own framing ("if it does not reach the
  subprocess, where does the value come from?") turned out not to apply: it does reach it.
- **(b) `session_marker` — re-derive vs. read an existing artifact.** Read was checked first and
  ruled out: the statusline computes the emoji fresh on every render from the session id and an
  in-memory array (`~/.claude/helpers/statusline-lcars.mjs:106-115`, `sessionEmoji()`) and persists
  no per-session marker file. The ONE artifact that file does write to disk,
  `~/.cache/claude-statusline/mode-<sid>`, carries the live permission-mode string (`liveMode()`,
  same file, a few lines below `sessionEmoji()`) — not the emoji — so "read it instead of
  re-deriving" is not an available option; there is nothing on disk holding the marker to read.
  **Resolution: re-derive, via a LOCKSTEP bash mirror**, per the statusline-lock doctrine's
  sanctioned pattern for read-only consumers (the fleetops mirror already sets this precedent).
  The formula is pure 32-bit-masked arithmetic over the session-id string (`h = h*31 + charcode`,
  masked to unsigned 32-bit every step, mirroring JS's `>>> 0`; `charCodeAt` is a plain byte lookup
  for the ASCII session-id alphabet Claude Code uses) — no node builtin beyond that, so it ports to
  bash exactly with zero new runtime dependency (`_session_stamp` in `src/swarm-lib.sh`). Verified
  byte-identical against the *live* `.mjs` file's own `sessionEmoji()`, run verbatim in `node`,
  for two pinned session ids **before** the bash mirror was written — the exact node invocation and
  its output (`🍄 🦊`) are pasted as a comment directly above the pinning test in
  `tests/swarm-lib.bats` ("spec17 FR-7" block), so any future drift between the two copies turns
  that test red rather than silently diverging. The statusline file itself was only ever *read*
  (chmod 444 preserved, zero writes) — satisfying the Non-Goal that nothing here may propose or
  perform a statusline change.
- **(c) `account`.** Confirmed live: `$CLAUDE_ACCOUNT` and `$CLAUDE_CONFIG_DIR` are both present in
  a real multi-account session's environment, with `$CLAUDE_CONFIG_DIR` resolving to an
  account-scoped config directory whose basename equals the account name — matching
  `swarm-lib.sh`'s own existing multi-account note ("the orchestrator session may run under
  `CLAUDE_CONFIG_DIR`", line ~757-759). **Resolution: `$CLAUDE_ACCOUNT`, else
  `basename($CLAUDE_CONFIG_DIR)`, else `null`** — exactly the fallback FR-7's prose already named,
  confirmed rather than assumed.

All three fields are `null`, never a guessed value, when their source is absent — `run_summary`'s
JSON row always carries the three keys (`has("session_id") and has("account") and
has("session_marker")` is asserted `true` even in the all-absent case), so a reader can distinguish
"ran with no session context" from "this row predates FR-7" by key presence, not by a missing key.
Consumers verified not to break on the new keys: `src/speedwars-report.sh` never selects
`.type == "run-summary"` rows at all (only `type == null` branch rows, `"verdict"`, and
`"run-meta"`); `src/swarm-ctl`'s `cmd_postmortem` (spec 12 FR-5) does an unfiltered `jq .` over the
whole row, so the new keys simply print alongside the existing ones; `site/server.mjs` never
destructures a fixed set of top-level JSONL keys — it `JSON.parse`s and forwards lines generically.
No design note, comment, or commit message proposes touching the statusline; `_session_stamp`'s own
header comment says so explicitly.

### 2026-07-26 — Open question 1: generated-command discovery path vs. `"source": "."`

**Resolved to option (b).** `.claude-plugin/marketplace.json` (repo root — required to stay there,
`/plugin marketplace add <repo path>` looks for it exactly there) now sources its one plugin entry
at `"source": "./plugin"`. `plugin/.claude-plugin/plugin.json` is the plugin manifest; the old
root-level `.claude-plugin/plugin.json` is gone (moved, not duplicated). `plugin/commands/*.md`
needed no move — it was already sitting where the new plugin root expects `commands/`. A new
`plugin/skills/unimatrix/SKILL.md` was added at the matching convention path (see the next
resolution).

**Evidence — surveyed every `.claude-plugin/plugin.json` reachable on this box**
(`~/.claude/plugins/marketplaces/*`, `~/.claude/plugins/cache/*`, `~/.agnes/marketplace/*`; 30+
manifests spanning `cloudflare`, `caveman`, `karpathy-skills`, `frontend-design`, `skill-creator`,
`ponytail`, `grpn-foundryai`, the official `claude-plugins-official` set, …):

- **Zero** of them declare a `"commands"` path field, in either direction (default location or
  overridden). Every plugin that ships commands (`cloudflare`, `caveman` — both installed and
  enabled) has a `commands/` directory sitting directly under whatever its marketplace entry's
  `"source"` points at. Discovery is convention-over-configuration, full stop, for commands.
- Path fields DO exist in Claude Code manifests for OTHER payload kinds — `ponytail`'s real
  `.claude-plugin/plugin.json` carries `"hooks": "./hooks/claude-codex-hooks.json"` (verified via
  jq against the installed marketplace copy; its `.codex-plugin`/`.devin-plugin` siblings are
  different products' shapes and irrelevant). But no installed Claude Code manifest anywhere on
  this box declares a `"commands"` path field — the observed path fields are hooks (a file
  reference, not a discovery dir) and a redundant `"skills"` array (next bullet). Commands remain
  convention-over-configuration.
- `karpathy-skills`'s real, installed, enabled (`andrej-karpathy-skills@karpathy-skills: true` in
  one of this box's per-account `settings.json` files) `.claude-plugin/plugin.json` DOES carry
  `"skills": ["./skills/karpathy-guidelines"]` — a "commands"-shaped field is at least tolerated by
  the schema. But it is redundant: `skills/karpathy-guidelines/` already sits at the plugin root,
  the default location, so the field provably changes nothing observable (no installed plugin uses
  such a field to point somewhere non-default). No evidence a `"commands"` field would actually be
  *honored* to relocate discovery, only that a same-shaped `"skills"` key doesn't error.
- The load-bearing precedent for directory-sourced marketplaces where plugin root ≠ marketplace
  root is **agnes**: `~/.claude/plugins/known_marketplaces.json` →
  `"agnes": {"source": {"source": "directory", "path": "~/.agnes/marketplace"}, "installLocation":
  "~/.agnes/marketplace"}` (identical path — no clone, confirming D3's "directory-sourced needs no
  git repo" claim for the *marketplace* itself). Its `marketplace.json` plugin entry sources a
  named subdirectory (an employer-internal plugin; the exact name is withheld — it fails this
  repo's own PII gate) — marketplace root and plugin root are
  **different directories**, exactly shape (b). That plugin's own
  `.claude-plugin/plugin.json` has no `"commands"`/`"skills"` field; its `skills/report/SKILL.md`
  is discovered purely by sitting at `<plugin-root>/skills/report/SKILL.md`.

**Conclusion:** no working precedent anywhere on this box shows Claude Code's
`.claude-plugin/plugin.json` supporting an explicit commands-path override; convention (a
`commands/` dir directly under whatever `source` resolves to) is the only proven mechanism. Option
(a) — keep `source: "."` and add an unverified field — was rejected for exactly the reason FR-1's
own text worried about: it would ship on a guess. Option (b) ships on the same shape every working
plugin on this box already uses. FR-1's live-install test (`/plugin marketplace add`, open a
session in an unrelated repo, run `/u:call`) is still the final word — it is unbats-able and stays
a live-proof item — but this is the best evidence-based bet absent that run, and it is now what's
committed.

### 2026-07-26 — Item 3 (P1-FR1 "commands + skill only"): does the plugin ship the skill?

**Resolved: yes, via the convention directory.** `plugin/skills/unimatrix/SKILL.md` is a relative
symlink — `../../../.claude/skills/unimatrix/SKILL.md` — to the same canonical file P0-FR2 already
symlinks into all 7 account directories. One inode owns the bytes; the plugin payload is the 8th
symlinked "installation," not a 9th copy. No `"skills"` field was added to `plugin.json` — same
evidence as above: no installed plugin on this box uses one to point at a non-default location, so
there is nothing to gain from adding an unverified field when the convention path already works.

**Residual risk, recorded rather than hidden (not decided here — deferred to FR-1/FR-5's live
proof, out of this stream's scope):** every plugin payload observed on this box — including
`agnes`'s directory-sourced employer-internal plugin (name withheld, same PII-gate reason as
above; the closest analog to this plugin) — is **copied** into
a version-keyed cache directory at install/enable time (its `~/.claude/plugins/cache/agnes/<plugin>/<version>/`
copy and its `~/.agnes/marketplace/plugins/<plugin>/` source are confirmed **different
inodes** via `stat -c %i` on the same file), even though the marketplace source is a plain local
directory with no git clone involved. Whether that internal copy step preserves a symlink as a
symlink (stays live — an edit to `.claude/skills/unimatrix/SKILL.md` shows up on next enable) or
dereferences it into a plain file (ships correct content once, then goes stale until the next
install/enable cycle) was **not** determined on this box — installing this exact plugin and
inspecting its own cache entry is the only way to know, and that is FR-1's live-install proof, not
a bats-testable claim. Either outcome ships correct content at install time; only the
"stays-live-forever" property is unconfirmed. This is exactly the class of thing already named in
this spec's Known limits section ("Drift is detected, not prevented, wherever a real copy is
unavoidable") — FR-5's drift table is the compensating control if the symlink does not survive.

### 2026-07-26 — Open question 2 (PATH symlink target directory), tested and closed

**Confirmed: `~/.local/bin` is on this operator's `$PATH` — no fallback dir needed.** Checked on
the live box before writing `_install_symlink` (`unimatrix`, FR-3): `echo "$PATH" | tr ':' '\n' |
grep -c '\.local/bin$'` returned 2 (the shell profile sources it twice, harmlessly) — `~/.local/bin`
is present, ahead of `/usr/local/bin`/`/usr/bin`, in the resolved `$PATH`. FR-3's proposed default
stands as specified: `~/.local/bin`, overridable via `--prefix <dir>`. No fallback-directory
selection logic was needed or built — the "if absent, pick the first user-writable PATH dir" branch
this open question asked
for is *unreachable* on this box and is not implemented; `_install_symlink` prints an explicit
`install: note` line (not a hard failure) on any box where the resolved prefix is NOT on `$PATH`,
so the gap is visible rather than silently assumed on a future box where this doesn't hold.

### 2026-07-26 — Open question 3 (FR-4's phase-4-shaped acceptance criterion), accepted substitute

**Accepted as proposed, unchanged.** `unimatrix here` (FR-4) is verified against exactly the
P1-verifiable substitute this question itself proposed: a well-formed
`~/.config/unimatrix/fleet.json` entry keyed by the repo's realpath, containing `{repo, bus, added}`
(realpath, bus realpath, ISO-8601 timestamp), valid JSON, and a rerun in the same repo updates that
one entry **in place** rather than appending a duplicate (`tests/unimatrix.bats` "#16 here" block —
one test asserts the shape on a fresh repo, one asserts `keys | length == 1` after a second run).
No phase-4 fleet-wall code exists yet to "see it" in the literal sense the PRD's criterion names —
that half is explicitly deferred to whichever spec builds P4-FR4, per this question's own proposal.
`fleet.json` stays a plain registry: FR-4 writes an entry and stops; nothing in this stream reads it
back, and no policy (e.g. the work/personal boundary from PRD §9 resolution 3) was added to it.

### 2026-07-26 — FR-3/FR-4/FR-5 install-shape evidence (supporting note, not a numbered question)

Two live-box findings that shaped the FR-3/FR-5 implementation, recorded here since they weren't
already covered by another stream's resolution above:

- **`~/.claude-acct/<acct>/plugins` is a symlink to the shared `~/.claude/plugins`** (verified via
  `readlink -f` on every account dir) — `known_marketplaces.json`/`installed_plugins.json` are one
  physical file shared across every account, populated by Claude Code itself at session-start when
  it resolves a marketplace a `settings.json` declares. `unimatrix install` (FR-3) therefore writes
  **only** the per-account `settings.json` (`extraKnownMarketplaces` + `enabledPlugins`, which are
  genuinely separate files per account, unlike `plugins/`) — never `known_marketplaces.json` or
  `installed_plugins.json` directly; those are system-managed, exactly as discovery.md §3 flagged.
- **The live `agnes` directory-marketplace shape, confirmed** (`~/.claude-acct/rob7/settings.json`):
  `extraKnownMarketplaces.agnes = {"source":{"source":"directory","path":"<path>"}}`,
  `enabledPlugins["<plugin>@agnes"] = true`. `_install_settings_one` (FR-3) writes the identical
  shape for `unimatrix`/`u@unimatrix` via a `.foo = X` jq merge, never a whole-object rewrite.
- **FR-5's install-drift table resolves `plugin.json`'s path from `marketplace.json`'s own declared
  `plugins[0].source` at check time** (`_plugin_json_path`, swarm-run.sh), rather than assuming a
  fixed layout — this was load-bearing in practice: mid-implementation, open question 1's resolution
  (above) moved `plugin.json` from `.claude-plugin/` to `plugin/.claude-plugin/` on this same branch,
  and the dynamic lookup absorbed that move with no code change needed on this stream's side.

### Resolution — 2026-07-26, FR-6 leg 2 (`${CLAUDE_PLUGIN_ROOT}`) as implemented

FR-6's leg 2 names `${CLAUDE_PLUGIN_ROOT}`; the shipped router (`./unimatrix`) implements leg 2 as
**its own symlink-resolved script directory** instead, and `CLAUDE_PLUGIN_ROOT` appears nowhere in
the router or any command body. This is deliberate, not a gap: the plugin ships **pointer stubs
only** — the engine never executes from the plugin cache dir, so a `CLAUDE_PLUGIN_ROOT`-relative
walk would resolve into the version-keyed cache copy, exactly the wrong checkout. The stub bodies
route through `$UNIMATRIX_HOME` (leg 1) and the router's self-location covers the
invoked-directly-or-via-PATH-symlink cases (leg 2's real intent: "where the code actually lives").
Leg 2's text stands as written for any FUTURE payload that executes from inside the plugin; for
the pointer-stub architecture the script-dir implementation is the correct reading.

### Live proofs — 2026-07-26 (recorded per Test Plan; run by the orchestrator)

- **FR-6 three-worktree dispatch**: with all three worktrees on disk (`~/code/unimatrix`,
  `~/code/unimatrix-calldev`, `~/code/unimatrix-stable`), from a foreign git repo:
  `~/.local/bin/unimatrix status` (PATH symlink, `UNIMATRIX_HOME` unset) resolved to
  `~/code/unimatrix` (leg 2, symlink-chased); `UNIMATRIX_HOME=<calldev> unimatrix run --help`
  dispatched into the calldev checkout (leg 1 wins); sourcing the router and calling
  `_unimatrix_home` from `/tmp` returned the main checkout. All three named the intended target.
- **FR-1 acceptance (verbatim criterion)**: in a session opened in an unrelated repo (headless
  `claude -p`, work account), `/u:speedwars` expanded from the installed plugin, the executor
  followed the stub's resolution chain and ran the real report over the real ledger — canonical
  fold output (UNJUDGED buckets, per-card units) confirmed live. `claude plugin details
  u@unimatrix` inventories the plugin at 1.1.0 with 5 command stubs + the unimatrix skill,
  discovered from the `./plugin` source.
- **Defect the proof caught (fixed same day)**: the generated stubs' last line named only the
  `git rev-parse` fallback — a foreign repo therefore dead-ended. The generator template now
  names `~/.config/unimatrix/config` (written by `unimatrix install`) as the second leg;
  stubs regenerated, `check.sh`'s drift step keeps them in sync.
