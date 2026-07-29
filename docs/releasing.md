# Releasing

Checklist for cutting a unimatrix release. See `CLAUDE.md` §Versioning for the policy this
implements.

## When

- `[Unreleased]` in `CHANGELOG.md` has accumulated 3-5 user-facing features, or
- the maintainer explicitly asks for a release.

## How

1. Move `[Unreleased]` entries into a new `## [x.y.z] - <date>` section (semver: breaking = major,
   feature = minor, fix-only = patch).
2. At the top of that section, write a "What's new (for humans)" block — 1 line per feature, no
   jargon, written for an end user (BFU terms). This comes before the raw changelog bullets, not
   instead of them.
3. **Version-stamp table.** Every one of these carries the release number and none of them is kept
   in sync automatically — no build step reads the changelog and stamps the rest (verified: nothing
   under `plugin/gen-commands.sh` or `check.sh` touches a `version` field). Update all five by hand,
   in the same commit as the changelog cut:

   | File | Field | Note |
   |---|---|---|
   | `package.json` | `.version` | Drifts silently if skipped — it has lagged the real release before. |
   | `plugin/.claude-plugin/plugin.json` | `.version` | No build-time stamper (spec 17 FR-1); hand-set only. |
   | `.claude-plugin/marketplace.json` | `.plugins[0].version` | Same value as the plugin manifest above — one plugin, two files naming its version. |
   | `.claude/skills/unimatrix/SKILL.md` | frontmatter `version:` | Hand-set alongside the two manifests above. |
   | `docs/versions.md`, `README.md` | any literal version-number citation in prose | Grep the previous release string before tagging (`grep -rn "<old-version>" docs/versions.md README.md`) and fix any hit. Neither file cites one today — this line is a trap for the day one of them does, not a guaranteed edit. |

4. **Run `check.sh` bare.** No `CHECK_SKIP_BATS=1`, no other gate-skipping environment variable, no
   partial invocation of a subset of `tests/`. `CHECK_SKIP_BATS` exists for exactly one purpose —
   `tests/check-gates.bats`'s own recursive self-test — and a run made with it set skips the entire
   bats suite, including the traversal/write-cage security tests, and prints a loud banner saying so
   instead of "check green". A release checklist run with any gate-skipping override set has not
   actually verified anything; treat it as red.
5. `git tag -a vX.Y.Z -m "..."` — annotated tag, not lightweight.

## Publishing — two remotes, two histories

- **`origin`** → `https://github.com/<owner>/unimatrix-private.git`, the private mirror. It carries
  **two** branches: `public` (the single live working trunk this repo's `HEAD` tracks — every commit
  lands here, unfiltered) and a **frozen `main`** (disjoint pre-release history from before this
  project existed in its current form — `AGENTS.md` §Agent rules: never commit to it, ever, and this
  checklist never pushes to it either).
- **`release`** → `https://github.com/<owner>/unimatrix.git`, the actual public-facing repo. It has
  exactly **one** branch, and it is named **`main`** — not `public`. Since the 2026-07-26 repo
  recreation (`docs/ops/history-rewrites.md`), `release/main` carries a **curated lineage that is
  NOT the local `public` history**: the local branch `public-release` (b788dd0 "initial public
  release" → one commit per release). Publishing therefore is NEVER `git push release public:main`
  (that can no longer fast-forward, and `--follow-tags` there would drag the whole private history
  into the public repo). Instead, graft the release's TREE onto the curated lineage and push that:

  ```bash
  tree=$(git rev-parse vX.Y.Z^{tree})
  new=$(git commit-tree "$tree" -p "$(git rev-parse public-release)" -m "release: vX.Y.Z — <headline>")
  git update-ref refs/heads/public-release "$new"
  git push release public-release:main        # fast-forward on the curated lineage
  ```

  `release/main` only ever advances this way at a release cut — never from `origin`'s frozen
  `main`, never a force-push as part of the normal flow, and never with tags from the private
  lineage.
- **Why the remote and branch are named explicitly every time, and "push to main" is never said
  bare:** this repo alone has three different things called `main` (the local dead branch, its
  `origin` mirror, and `release`'s real live branch) plus one `public` (the local trunk and its
  `origin` mirror). A checklist that just says "never push to main" reads as "the branch named
  `main` is universally off-limits" and misses that `release`'s primary branch legitimately **is**
  named `main` — that ambiguity is exactly what let a 2026-07-25 push land dirty history on the
  public repo for a few minutes (`docs/ops/history-rewrites.md`, "Exposure note"). Every step below
  spells out `<remote>/<branch>` so there is nothing to misread.

### First release (a fresh `release` remote, no `main` there yet)

1. Confirm this really is the first push (`git ls-remote release` returns nothing, or you are
   deliberately standing up a brand-new public repo).
2. Run `check.sh` bare (step 4 above) — non-negotiable; this is the one push that can't be walked
   back cheaply once someone else has forked or cloned it.
3. **Grep the full commit range about to become reachable, not just the tree at HEAD.** A clean
   working tree does not un-leak a blob some earlier, since-edited commit already committed — GitHub
   keeps old blobs fetchable by SHA long after a later commit deletes the line. Locally:
   `git log -p <range> | grep -niE "<employer>|<operator-home>"`, substituting your own project's
   forbidden-employer-name and forbidden-home-path patterns for the two placeholders — this repo's
   `check.sh` PII gate is the arbiter of what actually counts as a hit, not this one-line example.
4. If step 3 finds anything, this is **not yet** a clean push. Two remediations, pick the one that
   fits:
   - The dirty range never reached a public remote yet: **squash it** into one commit whose tree
     equals the current scrubbed state, and keep a private, gitignored log of the old→new SHA
     mapping (`docs/ops/history-rewrites.md` is the worked example — table format, verification
     steps, and all).
   - The dirty range **already** reached a public remote (even briefly): a force-push alone is not
     enough — GitHub retains force-push-orphaned objects, fetchable by SHA, until server-side GC.
     Either **delete and recreate** the GitHub repo, or **file a GitHub Support purge request** for
     the orphaned objects, before treating the exposure as closed.
5. `git push release public:main`
6. `git push release vX.Y.Z:vX.Y.Z`
7. Verify: `git ls-remote --heads release` shows `main` at the expected SHA;
   `git ls-remote --tags release | grep vX.Y.Z` returns the tag.

### Every release after

1. `git push origin public` (private mirror — routine, always the full trunk).
2. `git push origin vX.Y.Z`
3. Graft the release tree onto the curated lineage and push THAT (see "Publishing" above —
   never `git push release public:main`; this list previously said exactly that and was the
   stale half of the 2026-07-26 flow change):

   ```bash
   tree=$(git rev-parse vX.Y.Z^{tree})
   new=$(git commit-tree "$tree" -p "$(git rev-parse public-release)" -m "release: vX.Y.Z — <headline>")
   git update-ref refs/heads/public-release "$new"
   git push release public-release:main        # fast-forward on the curated lineage
   ```

   If `public-release:main` is ever rejected as non-fast-forward, stop: `release/main` moved
   outside this flow. Force-pushing over it needs the maintainer's explicit say-so in that
   conversation, never a default.
4. `git push release vX.Y.Z:vX.Y.Z` — only after the range check below has passed for the
   commits the tag makes reachable (v1.2.0/v1.3.0 precedent: annotated release tags do live on
   the public repo).
5. Verify: `git ls-remote --tags release | grep vX.Y.Z` returns the tag; after a `git fetch release`,
   `release/main` matches local `public-release`.

### Before every push — checklist

- [ ] `check.sh` green, run bare (step 4 — no gate-skipping override of any kind).
- [ ] The version-stamp table (step 3) applied in the same commit as the changelog cut.
- [ ] Annotated tag created (`git tag -a`, never lightweight).
- [ ] `git push <remote> <local-branch>:<remote-branch>` — remote and branch named explicitly,
      never a bare `git push` and never an assumed default name.
- [ ] For a `release` push specifically: the commit range about to become reachable from
      `release/main` has never carried a forbidden token in any blob — not just the current tree
      (see "First release" step 3). `check.sh`'s PII gate is the arbiter of what counts; this item
      is "did you check the full range," not a second gate definition.

### Private mirror

`origin` (`unimatrix-private`) is not itself a distribution channel — it exists so a second machine
or a fresh clone always has the full, uncut trunk. Treat pushes there as routine housekeeping, not a
release action; nothing about `origin/public` needs the scrutiny a `release/main` push does.

## What NOT to do

- Never release with `check.sh` red.
- Never run `check.sh` with `CHECK_SKIP_BATS=1` (or any other gate-skipping override) and call the
  result "green" — that variable exists only for `tests/check-gates.bats`'s own recursive self-test.
- Never include gitignored evidence (`docs/ops/llm-runs.md`, `docs/ops/bus-archives/`,
  `docs/ops/history-rewrites.md`, and friends) in a release artifact or tag message — it's
  operator-local, not for distribution.
- Never say "push to main" without naming the remote — say `origin/main` (frozen, never touch) or
  `release/main` (the live public line) explicitly, every time.
- Never force-push `release/main` as part of the normal flow. A dirty range that already reached it
  is the one-time remediation path above, not a routine push, and not something to route around
  quietly.
- Never assume `git push <remote> <branch>` lands on the right remote branch name — `release`'s
  primary branch is `main`, not `public`; a bare `git push release public` creates a stray `public`
  branch on that remote instead of updating `main`.
