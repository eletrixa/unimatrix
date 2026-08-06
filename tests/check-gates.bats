#!/usr/bin/env bats
# P0-FR5 planted-line proof: check.sh's DB-symbol gate and host-path gate actually fire on a
# planted violation, and stay clean on an untouched copy of the tree. Every test runs check.sh
# against a throwaway git repo under $BATS_TEST_TMPDIR built from THIS repo's currently tracked
# files (working-tree bytes, so uncommitted edits to check.sh/the engine scripts are covered) —
# never the real checkout, and never the huge gitignored .bus*/plans-worktree trees a raw
# `cp -r .` would drag in.
#
# Also covers P1-FR2 (plugin/commands/ generation): check.sh's regenerate-into-temp-dir-and-diff
# step against the same fixture-copy pattern, plus standalone unit cases for
# plugin/gen-commands.sh's own PRD-stub enforcement (≤3 lines, canonical source must exist).
#
# Project: unimatrix — multi-model swarm orchestrator driven from Claude Code
# Module:  tests/check-gates.bats
# Deps:    bats-core, git; runs the copy's own check.sh (shellcheck if installed there too)
# Tested:  n/a — this is the test file
#
# Design constraints:
# - CHECK_SKIP_BATS=1 on every check.sh invocation here — without it, each of these tests would
#   recurse the whole bats suite (including this very file) through the copy's own check.sh run.
# - CHECK_SKIP_SHELLCHECK=1 alongside it (2026-08-01): these tests prove the grep-gates and
#   gen-commands steps, not shellcheck — re-linting the identical scripts in every fixture copy
#   was ~2 min PER TEST and made this file the whole gate's critical path (20 of the gate's
#   16 min). The real run's own shellcheck leg still lints the actual repo.
# - The planted violation is written straight to disk in the copy; git ls-files only needs the
#   PATH already tracked (from the fixture commit) — check.sh's grep reads live file bytes, not
#   the git blob, so no `git add` is needed after planting.

REPO="$BATS_TEST_DIRNAME/.."

# _fixture_copy — sets $COPY to a fresh git repo under $BATS_TEST_TMPDIR containing exactly this
# repo's tracked files (`git ls-files` from $REPO, respecting .gitignore), re-committed so the
# copy's own `git ls-files` (which check.sh's gates depend on) works standalone.
#
# `git ls-files` reads the INDEX, not the working tree — a path staged/committed at HEAD but
# since removed from disk with a plain `rm`/`mv` (never `git rm`, e.g. a restructure mid-flight
# with nothing staged yet) still shows up here with nothing left to `cp`. Skip it rather than
# aborting the whole fixture build: the copy correctly ends up without that path either, which
# matches on-disk reality, and no current test depends on any specific tracked-but-deleted file.
_fixture_copy() {
  COPY="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$COPY"
  local f
  while IFS= read -r -d '' f; do
    [[ -f "$REPO/$f" ]] || continue
    mkdir -p "$COPY/$(dirname "$f")"
    cp "$REPO/$f" "$COPY/$f"
  done < <(git -C "$REPO" ls-files -z)
  git -C "$COPY" init -q
  # user@example.com: the one .pii-allowlist address free for throwaway git-identity use — this
  # file lives under tests/, which check.sh's OWN (pre-existing) email gate scans.
  git -C "$COPY" -c user.email=user@example.com -c user.name=test add -A
  git -C "$COPY" -c user.email=user@example.com -c user.name=test commit -q -m fixture
}

setup() {
  _fixture_copy
}

@test "clean copy: DB-symbol gate and host-path gate both pass" {
  run env CHECK_SKIP_BATS=1 CHECK_SKIP_SHELLCHECK=1 "$COPY/check.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DB-symbol gate clean"* ]]
  [[ "$output" == *"host-path gate clean"* ]]
  # CHECK_SKIP_BATS=1 is always set here (this suite's own recursion guard) — the plain "check
  # green" line must never appear under it; only the qualified skip line, behind a loud banner.
  [[ "$output" == *"CHECK_SKIP_BATS=1"* ]]
  [[ "$output" == *"gates green (bats+shellcheck SKIPPED — not a full gate)"* ]]
  [[ "$output" != *"✓ check green"* ]]
}

@test "planted DB symbol in an engine script fails check.sh and names the file" {
  printf '\n# UNI_DB=x\n' >> "$COPY/swarm-run.sh"
  run env CHECK_SKIP_BATS=1 CHECK_SKIP_SHELLCHECK=1 "$COPY/check.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"DB symbol in engine script"* ]]
  [[ "$output" == *"swarm-run.sh"* ]]
  [[ "$output" == *"UNI_DB"* ]]
}

@test "planted node:sqlite usage in an engine script fails the DB-symbol gate" {
  # DB_RE originally only knew CLI binary names / env-var shapes — node's built-in DB module and
  # its DatabaseSync class had no matching symbol, so this passed clean pre-fix.
  printf '\nconst {DatabaseSync} = require("node:sqlite");\n' >> "$COPY/swarm-run.sh"
  run env CHECK_SKIP_BATS=1 CHECK_SKIP_SHELLCHECK=1 "$COPY/check.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"DB symbol in engine script"* ]]
  [[ "$output" == *"swarm-run.sh"* ]]
}

@test "planted DB symbol in a NON-engine tracked file does not trip the DB-symbol gate" {
  # control: the gate is scoped to the four engine scripts only — a DB symbol anywhere else in the
  # tree (e.g. a doc discussing the phase-3 mirror design) must not be mistaken for the real thing.
  printf '\nsee UNI_DB in the phase-3 design\n' >> "$COPY/docs/versions.md"
  run env CHECK_SKIP_BATS=1 CHECK_SKIP_SHELLCHECK=1 "$COPY/check.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DB-symbol gate clean"* ]]
}

@test "planted absolute host path in a tracked doc fails check.sh" {
  # Built via concatenation, never a literal: this file lives under tests/, one of check.sh's own
  # DIRS — writing the fully-joined fixture path as one contiguous literal here would trip the
  # very gate this test proves exists.
  local frag1="/home" frag2="/alice/notes.md"
  printf '\nsee %s%s for details\n' "$frag1" "$frag2" >> "$COPY/docs/versions.md"
  run env CHECK_SKIP_BATS=1 CHECK_SKIP_SHELLCHECK=1 "$COPY/check.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"host path in tracked content"* ]]
  [[ "$output" == *"$frag1$frag2"* ]]
}

@test "planted /Users/ host path in a tracked doc fails check.sh" {
  local frag1="/Users" frag2="/bob/Desktop/notes.txt"
  printf '\nsee %s%s for details\n' "$frag1" "$frag2" >> "$COPY/docs/versions.md"
  run env CHECK_SKIP_BATS=1 CHECK_SKIP_SHELLCHECK=1 "$COPY/check.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"host path in tracked content"* ]]
  [[ "$output" == *"$frag1$frag2"* ]]
}

@test "control: the six-lane scratch-HOME shape (e.g. \$BUS/home/claude) is not flagged by the host-path gate" {
  # This exact shape already occurs throughout tests/swarm-lib.bats and tests/swarm-run.bats
  # (src/swarm-lib.sh's _scratch_home cage dirs) — the gate must stay green on it or the two new
  # steps would fail on this repo's own real, legitimate content.
  printf '\nHOME=$BUS/home/claude.c1 is the per-worker cage dir\n' >> "$COPY/docs/versions.md"
  run env CHECK_SKIP_BATS=1 CHECK_SKIP_SHELLCHECK=1 "$COPY/check.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"host-path gate clean"* ]]
}

@test "planted absolute host path in a top-level tracked script fails check.sh" {
  # DIRS never covered repo-root scripts (swarm-run.sh, swarm-loop.sh, swarm-mon.sh, check.sh,
  # unimatrix) — a leak planted there passed clean pre-fix. swarm-run.sh stands in for the class.
  local frag1="/home" frag2="/alice/private"
  printf '\n# see %s%s\n' "$frag1" "$frag2" >> "$COPY/swarm-run.sh"
  run env CHECK_SKIP_BATS=1 CHECK_SKIP_SHELLCHECK=1 "$COPY/check.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"host path in tracked content"* ]]
  [[ "$output" == *"swarm-run.sh"* ]]
  [[ "$output" == *"$frag1$frag2"* ]]
}

@test "F9: a line mixing a cage path and a real leak still fails (exclusion is substring-scoped, not line-scoped)" {
  # Pre-fix, the lane exclusion matched anywhere in the LINE and skipped the whole line — this
  # exact shape ("cage $BUS/home/claude and leak <user-home>/secrets") was a proven leak that
  # silently passed. Built via concatenation for the same self-reference reason as the tests above.
  local frag1="/home" frag2="/alice/secrets"
  printf '\ncage $BUS/home/claude and leak %s%s\n' "$frag1" "$frag2" >> "$COPY/docs/versions.md"
  run env CHECK_SKIP_BATS=1 CHECK_SKIP_SHELLCHECK=1 "$COPY/check.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"host path in tracked content"* ]]
  [[ "$output" == *"$frag1$frag2"* ]]
}

@test "F9: planted uppercase Users-dir host path fails check.sh (HOSTPATH_RE case extension)" {
  local frag1="/Users" frag2="/Bob/Desktop/notes.txt"
  printf '\nsee %s%s for details\n' "$frag1" "$frag2" >> "$COPY/docs/versions.md"
  run env CHECK_SKIP_BATS=1 CHECK_SKIP_SHELLCHECK=1 "$COPY/check.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"host path in tracked content"* ]]
  [[ "$output" == *"$frag1$frag2"* ]]
}

@test "P1-FR2: clean copy passes the generated-commands drift step" {
  run env CHECK_SKIP_BATS=1 CHECK_SKIP_SHELLCHECK=1 "$COPY/check.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"plugin/commands/ matches the generator"* ]]
}

@test "P1-FR2: a hand-edited committed stub fails check.sh; regenerating fixes it" {
  # mutate one committed stub directly, exactly the "hand-copied instead of generated" failure
  # mode FR-2 exists to catch
  printf 'HAND EDITED — NOT GENERATED\n' > "$COPY/plugin/commands/call.md"
  run env CHECK_SKIP_BATS=1 CHECK_SKIP_SHELLCHECK=1 "$COPY/check.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"plugin/commands/ is out of date"* ]]
  [[ "$output" == *"plugin/gen-commands.sh"* ]]

  "$COPY/plugin/gen-commands.sh"
  run env CHECK_SKIP_BATS=1 CHECK_SKIP_SHELLCHECK=1 "$COPY/check.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"plugin/commands/ matches the generator"* ]]
}

@test "P1-FR2: a stale extra file in plugin/commands/ (source removed, stub not regenerated) fails check.sh" {
  # Simulates a canonical u-*.md having been deleted without re-running the generator: the stub
  # goes stale (an extra file the fresh regeneration no longer produces) rather than disappearing.
  cp "$COPY/plugin/commands/call.md" "$COPY/plugin/commands/orphan.md"
  run env CHECK_SKIP_BATS=1 CHECK_SKIP_SHELLCHECK=1 "$COPY/check.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"plugin/commands/ is out of date"* ]]
}

@test "P1-FR2 dup-prose: clean copy has no duplicated 20-word command shingle (covers plugin/commands boilerplate + the bare 1-line aliases — neither false-positives)" {
  run env CHECK_SKIP_BATS=1 CHECK_SKIP_SHELLCHECK=1 "$COPY/check.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"duplicate-prose detector clean"* ]]
}

@test "P1-FR2 dup-prose: a canonical body pasted into a second command file fails check.sh, naming both files" {
  # 25 words lifted verbatim from u-call.md's body, pasted into a DIFFERENT command file — the
  # copy-paste-instead-of-a-pointer failure mode the detector exists to catch.
  local words25
  words25="$(awk 'BEGIN{fm=0} NR==1 && $0=="---"{fm=1; next} fm==1 && $0=="---"{fm=0; next} fm==1{next} {print}' \
    "$COPY/.claude/commands/u-call.md" | tr -s ' \n' ' ' | cut -d' ' -f1-25)"
  printf '\n%s\n' "$words25" >> "$COPY/.claude/commands/u-swarm.md"

  run env CHECK_SKIP_BATS=1 CHECK_SKIP_SHELLCHECK=1 "$COPY/check.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"duplicated command prose"* ]]
  [[ "$output" == *"u-call.md"* ]]
  [[ "$output" == *"u-swarm.md"* ]]
}

# --- cross-review finding: plugin/ + .claude-plugin/ join the PII/host-path scan --------------
# Previously unscanned: spec 17 claims plugin/** is host-path-free but nothing enforced it. Both
# gates read the same DIRS-derived $FILES array (step 1's PII/secret gate and step 3's host-path
# gate), so proving the join on one gate proves DIRS itself now covers these two directories.

@test "F-plugin: control — clean plugin/ and .claude-plugin/ pass the PII/host-path gates" {
  run env CHECK_SKIP_BATS=1 CHECK_SKIP_SHELLCHECK=1 "$COPY/check.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PII / secret gate clean"* ]]
  [[ "$output" == *"host-path gate clean"* ]]
}

@test "F-plugin: a planted absolute host path in plugin/README.md fails check.sh" {
  local frag1="/home" frag2="/alice/notes"
  printf '\nsee %s%s for details\n' "$frag1" "$frag2" >> "$COPY/plugin/README.md"
  run env CHECK_SKIP_BATS=1 CHECK_SKIP_SHELLCHECK=1 "$COPY/check.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"host path in tracked content"* ]]
  [[ "$output" == *"$frag1$frag2"* ]]
}

@test "F-plugin: a planted absolute host path in .claude-plugin/marketplace.json fails check.sh" {
  local frag1="/home" frag2="/bob/secrets"
  printf '\n// see %s%s\n' "$frag1" "$frag2" >> "$COPY/.claude-plugin/marketplace.json"
  run env CHECK_SKIP_BATS=1 CHECK_SKIP_SHELLCHECK=1 "$COPY/check.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"host path in tracked content"* ]]
  [[ "$output" == *"$frag1$frag2"* ]]
}

@test "gen-commands.sh: a new u-*.md source produces a new stub" {
  printf '# /u-widget\ntest fixture command\n' > "$COPY/.claude/commands/u-widget.md"
  run "$COPY/plugin/gen-commands.sh"
  [ "$status" -eq 0 ]
  [ -f "$COPY/plugin/commands/widget.md" ]
  [[ "$(wc -l < "$COPY/plugin/commands/widget.md")" -le 3 ]]
}

@test "gen-commands.sh: removing a canonical source with a live stub fails loudly" {
  rm "$COPY/.claude/commands/u-call.md"
  run "$COPY/plugin/gen-commands.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"canonical source missing"* ]]
  [[ "$output" == *"call.md"* ]]
}

@test "gen-commands.sh: regeneration is idempotent (second run is byte-identical)" {
  "$COPY/plugin/gen-commands.sh"
  local tmp1="$BATS_TEST_TMPDIR/gen1" tmp2="$BATS_TEST_TMPDIR/gen2"
  "$COPY/plugin/gen-commands.sh" "$tmp1"
  "$COPY/plugin/gen-commands.sh" "$tmp2"
  diff -rq "$tmp1" "$tmp2"
}

@test "F10: host-path gate on an empty tracked tree warns and does not hang or false-green" {
  # A fresh git repo with check.sh's own sources copied onto disk but never `git add`-ed: git
  # ls-files returns nothing, exactly the tarball/non-git-export case. Pre-fix, the host-path gate
  # passed an empty "${FILES[@]}" to grep, which then blocked reading stdin. `timeout` proves it
  # doesn't hang; the warning proves it doesn't silently claim a real scan happened.
  local empty="$BATS_TEST_TMPDIR/empty-repo"
  mkdir -p "$empty/src" "$empty/plugin/commands" "$empty/.claude/commands"
  local f
  for f in unimatrix swarm-run.sh swarm-loop.sh swarm-mon.sh src/swarm-lib.sh src/swarm-ctl check.sh plugin/gen-commands.sh; do
    cp "$REPO/$f" "$empty/$f"
  done
  git -C "$empty" init -q
  # 60s, not a tight bound (shellcheck is skipped here like every fixture invocation, so the
  # copy's run is grep-gates + gen-commands only) — the point is proving no INDEFINITE stdin
  # block, not benchmarking.
  run timeout 60 env CHECK_SKIP_BATS=1 CHECK_SKIP_SHELLCHECK=1 "$empty/check.sh"
  [ "$status" -ne 124 ]
  [[ "$output" == *"no tracked files under"* ]]
  [[ "$output" == *"host-path gate clean"* ]]
}

# --- release blocker: every version-stamp surface must agree ----------------------------------
# Runs against $REPO directly (the real checkout), not $COPY — this asserts a property of the
# ACTUAL repo's committed state, not a check.sh gate reacting to a planted fixture violation.
#
# NOTE FOR THE ORCHESTRATOR (release-cut wave): this case is RED right now BY DESIGN.
# package.json is still stamped 0.1.0 while plugin.json/marketplace.json/CHANGELOG.md's newest
# heading/SKILL.md's frontmatter already carry 1.1.0 (the pre-stamp for this release). The
# expected value is read FROM the CHANGELOG heading — the stamp target — so this only fails while
# a surface genuinely disagrees with it; it goes green the moment the release commit stamps
# 1.2.0 everywhere (docs/releasing.md's stamp-and-install loop).
@test "release: plugin.json, marketplace.json, package.json, and SKILL.md frontmatter all stamp the CHANGELOG's newest version" {
  local want
  want="$(grep -m1 -oE '^## \[[0-9]+\.[0-9]+\.[0-9]+\]' "$REPO/CHANGELOG.md" | sed -E 's/^## \[(.*)\]$/\1/')"
  [ -n "$want" ]

  local pj mj pkg sk
  pj="$(jq -r '.version // empty' "$REPO/plugin/.claude-plugin/plugin.json")"
  mj="$(jq -r '.plugins[0].version // empty' "$REPO/.claude-plugin/marketplace.json")"
  pkg="$(jq -r '.version // empty' "$REPO/package.json")"
  sk="$(sed -n '/^---$/,/^---$/{/^version:/p}' "$REPO/.claude/skills/unimatrix/SKILL.md" \
        | head -1 | sed -E 's/^version:[[:space:]]*//')"

  [ "$pj" = "$want" ]
  [ "$mj" = "$want" ]
  [ "$pkg" = "$want" ]
  [ "$sk" = "$want" ]
}

# --- P1-FR8: /u-* deprecation-line + bare-alias shape ------------------------------------------
# Runs against $REPO directly — a real-content invariant, not a planted-fixture gate reaction.

@test "P1-FR8: every .claude/commands/u-*.md has exactly one Deprecated line naming its /u:<name> replacement" {
  local f base name n
  for f in "$REPO"/.claude/commands/u-*.md; do
    base="$(basename "$f" .md)"     # e.g. u-call
    name="${base#u-}"               # e.g. call
    n="$(grep -c '\*\*Deprecated\*\*' "$f")"
    [ "$n" -eq 1 ]
    grep -q "/u:$name" "$f"
  done
}

@test "P1-FR8: each bare alias (swarm/swarm-loop/setup/speedwars.md) stays <= 6 lines and names a live target" {
  local f target
  for f in swarm.md swarm-loop.md setup.md speedwars.md; do
    [ -f "$REPO/.claude/commands/$f" ]
    [ "$(wc -l < "$REPO/.claude/commands/$f")" -le 6 ]
    target="$(grep -oE '\.claude/commands/u-[a-zA-Z-]+\.md' "$REPO/.claude/commands/$f" | head -1)"
    [ -n "$target" ]
    [ -f "$REPO/$target" ]
  done
}
