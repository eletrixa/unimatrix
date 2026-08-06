#!/usr/bin/env bash
#
# check.sh — the gate. Must be green before anything is considered done.
#
# Project: unimatrix — multi-model agent-swarm orchestrator driven from Claude Code
# Module:  check.sh
# Deps:    bash >=5.1, git; shellcheck & bats (skipped-with-warning if absent)
# Tested:  self (run it); tests/check-gates.bats plants violations against a throwaway copy
#
# Runs, in order: a PII/secret gate over the tracked content dirs (docs/specs/src/rules/plans/
# tests/site/.claude/feedback/plugin/.claude-plugin), a DB-symbol gate over the four engine scripts
# (P0-FR5 — the file-bus is the entire coordination layer; a DB reference in the engine path
# silently invalidates that), a general host-path gate over the same tracked content dirs, a
# generated-commands drift check (P1-FR2 — plugin/commands/ must equal what plugin/gen-commands.sh
# produces right now) plus its duplicate-prose detector (no canonical command body pasted into a
# second file), shellcheck -x on the shell sources, and bats over tests/. The three security gates
# run FIRST, unconditionally: putting shellcheck/bats ahead of them meant a red test suite or a
# lint error short-circuited (via `set -e`) before any security gate ran — exactly when WIP is most
# likely to get committed. Any failure exits non-zero.
#
# CHECK_SKIP_BATS=1 is for tests/check-gates.bats' own planted-line recursion ONLY: that suite runs
# this script against a throwaway copy of the repo to prove the gates fire on a planted violation,
# and without the skip that would recurse the whole bats suite (including itself) through every
# invocation. It skips bats tests/ wholesale — including the traversal/write-cage security tests —
# so the skip prints a loud banner and the final line never claims the plain "check green"; it's
# never a substitute for a real bats run. Never set this for a real check.sh run.
#
# CHECK_JOBS (default 6) fans the bats stage out per test file — each .bats file runs in its own
# bats process, failures aggregate, wall-time collapses to roughly the longest file (the serial
# suite crossed 20 min on 2026-08-01). CHECK_JOBS=1 restores the serial `bats tests/` run — the
# escape hatch when a parallel-only flake is suspected. 6, not nproc: the suite's timing-sensitive
# tests (linger, probe caps, lease races) flake under full-core contention.
set -euo pipefail
shopt -s inherit_errexit
cd "$(dirname "$0")"

if ((BASH_VERSINFO[0] < 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] < 1))); then
  echo "✗ bash >=5.1 required (found ${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]})" >&2
  exit 1
fi

step() { echo "▶ $*"; }
ok()   { echo "✓ $*"; }
fail() { echo "✗ $*" >&2; }

SHELL_SOURCES=(unimatrix swarm-run.sh swarm-loop.sh swarm-mon.sh src/swarm-lib.sh src/swarm-ctl check.sh plugin/gen-commands.sh)

# ── 1. PII / secret gate ──────────────────────────────────────────────────────
# Scan tracked files in the content dirs (git ls-files respects .gitignore, so
# generated caches like .playwright-cli/ and the .bus/ tree never poison the gate).
step "PII / secret gate"
# feedback/ is in scope deliberately: spec 12 FR-4 auto-GENERATES tracked files there at every run
# close, so it is the one content dir where a leak can happen unattended. Leaving it unscanned was
# the gap that let absolute operator paths into committed stubs.
# plugin/ + .claude-plugin/ (cross-review finding): spec 17 claims plugin/** ships host-path-free —
# nothing enforced that until they joined this list. Both gates below (PII/secret here, host-path
# in step 3) read this same DIRS array, so one addition covers both.
DIRS=(docs specs src rules plans tests site .claude feedback plugin .claude-plugin profiles)
gate_failed=0

mapfile -t FILES < <(git ls-files -- "${DIRS[@]}" 2>/dev/null || true)
if ((${#FILES[@]} == 0)); then
  echo "⚠ no tracked files under ${DIRS[*]} — nothing to scan"
else
  # 1a. Emails not on the allowlist.
  EMAIL_RE='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
  mapfile -t ALLOW < <(grep -vE '^[[:space:]]*(#|$)' .pii-allowlist 2>/dev/null || true)
  while IFS= read -r hit; do
    [[ -z $hit ]] && continue
    email=${hit##*:}                       # emails contain no ':', so last field is the address
    if printf '%s\n' "${ALLOW[@]}" | grep -qxF -- "$email"; then
      continue
    fi
    fail "unallowed email: $hit"
    gate_failed=1
  done < <(grep -HnoE "$EMAIL_RE" -- "${FILES[@]}" 2>/dev/null || true)

  # 1b. Forbidden absolute paths, employer names, and API-key prefixes.
  # EVERY sensitive alternative is split via adjacent-string concatenation (same value at runtime):
  # the operator-path one so it can't self-match once check.sh joins the host-path gate's scan list
  # (step 3), and the employer/vault tokens so this file's own committed blob never spells out the
  # very strings the gate exists to keep out of a public history.
  FORBIDDEN_RE='/hom''e/rob|/mnt/f''/s|/mnt/f/Grou''pon|ai-team''-hub|\bgrou''pon\b|sk-''ant-|AI''za|xai''-|gh''p_'
  while IFS= read -r hit; do
    [[ -z $hit ]] && continue
    fail "forbidden token: $hit"
    gate_failed=1
  done < <(grep -HniE "$FORBIDDEN_RE" -- "${FILES[@]}" 2>/dev/null || true)
fi

if ((gate_failed)); then
  fail "PII / secret gate found unallowed content"
  exit 1
fi
ok "PII / secret gate clean"

# ── 2. DB-symbol gate (engine scripts) ────────────────────────────────────────
# P0-FR5 / PRD §7 "honorable mention" risk: bus-discipline.md's entire premise is no DB in the
# execution path. Regex covers every symbol a future mirror importer (phase 3, unbuilt per the
# PRD's phase gate) could plausibly introduce: sqlite3/psql are the CLI binary names, UNI_DB/
# DATABASE_URL/DSN are the plausible env-var shapes, node:sqlite/DatabaseSync/better-sqlite3 are
# the node-native and npm-package DB APIs (`node -e 'require("node:sqlite")'` is DB access with no
# CLI binary name to catch). Verified zero hits on this tree before wiring.
step "DB-symbol gate (engine scripts)"
ENGINE_SCRIPTS=(swarm-run.sh swarm-loop.sh src/swarm-lib.sh src/swarm-ctl)
DB_RE='sqlite3|psql|UNI_DB|DATABASE_URL|\bDSN\b|node:sqlite|DatabaseSync|better-sqlite3'
db_failed=0
while IFS= read -r hit; do
  [[ -z $hit ]] && continue
  fail "DB symbol in engine script: $hit"
  db_failed=1
done < <(grep -HnE "$DB_RE" -- "${ENGINE_SCRIPTS[@]}" 2>/dev/null || true)
if ((db_failed)); then
  fail "DB-symbol gate found a database reference in an engine script"
  exit 1
fi
ok "DB-symbol gate clean"

# ── 3. host-path gate ──────────────────────────────────────────────────────────
# General absolute-home-path leak, over the same tracked content dirs as the PII gate above (whose
# forbidden-token check above only knows one specific operator path — this one is a shape match,
# any user, any case (uppercase as well as lowercase), plus the Windows drive-letter equivalents.
# Also covers the top-level tracked shell entrypoints (TOPLEVEL_SH below): DIRS alone left
# swarm-run.sh/swarm-loop.sh/swarm-mon.sh/check.sh/unimatrix — everything at repo root — exempt,
# so a leak planted there passed clean.
#
# check.sh is itself scanned (it's in TOPLEVEL_SH), so every /home/ or /Users/ example in ITS OWN
# comments below had to be reworded with a non-letter right after the slash (a bracket, a "<...>"
# placeholder) so this file's own documentation doesn't trip its own gate — see the FORBIDDEN_RE
# line above for the one spot where the literal string itself (not just a comment) is load-bearing,
# split via adjacent-string concatenation instead.
#
# Excludes _scratch_home's own <busdir>/home/<lane>[.<id>] worker-cage dirs (src/swarm-lib.sh):
# lane is always one of the fixed six (claude|codex|gemini|glm|grok|kimi — the same closed
# vocabulary _call_lane_ok validates against), never a real OS username, and dozens of bats
# fixtures legitimately assert paths shaped like "$BUS/home/claude". The exclusion strips only the
# matched /home/<lane> SUBSTRING (not the whole line) before re-testing the remainder against
# HOSTPATH_RE — a line can legitimately mix a cage path and a real leak (a cage dir plus a separate
# /home/<user>/ path on the same line), and a blanket per-line skip on the cage match alone would
# hide that leak.
#
# Windows shapes considered: [A-Za-z]:[/\\]Users[/\\] and [A-Za-z]:[/\\]code[/\\] — both verified
# zero hits on this tracked tree, added. Rejected a bare [A-Za-z]:[/\\] (any drive-letter+colon,
# no fixed suffix): false-positives on PATH=...: colon-separated env-var assignments
# (src/swarm-ctl, tests/swarm-ctl.bats) and the literal Windows-path test fixture 'C:\new' in
# tests/swarm-lib.bats — too broad a false-positive surface for this tree.
step "host-path gate"
TOPLEVEL_SH=(unimatrix swarm-run.sh swarm-loop.sh swarm-mon.sh check.sh)
HOSTPATH_RE='/home/[A-Za-z]+|/Users/[A-Za-z]+|[A-Za-z]:[/\\]Users[/\\]|[A-Za-z]:[/\\]code[/\\]'
# Boundary is [^A-Za-z] (not just [^a-z]): lane names are lowercase, but a real username that
# merely starts with a lane name must NOT be swallowed as "claude" + boundary just because the
# next character happens to be uppercase.
HOSTPATH_LANE_STRIP='s#/home/(claude|codex|gemini|glm|grok|kimi)([^A-Za-z]|$)#\2#g'
host_failed=0
if ((${#FILES[@]} == 0)); then
  echo "⚠ no tracked files under ${DIRS[*]} — nothing to scan there"
fi
while IFS= read -r hit; do
  [[ -z $hit ]] && continue
  stripped=$(sed -E "$HOSTPATH_LANE_STRIP" <<<"$hit")
  [[ "$stripped" =~ $HOSTPATH_RE ]] || continue
  fail "host path in tracked content: $hit"
  host_failed=1
done < <(grep -HnE "$HOSTPATH_RE" -- "${FILES[@]}" "${TOPLEVEL_SH[@]}" 2>/dev/null || true)
if ((host_failed)); then
  fail "host-path gate found an absolute host path in tracked content"
  exit 1
fi
ok "host-path gate clean"

# ── 4. generated commands (plugin/commands/ drift) ─────────────────────────────
# P1-FR2: plugin/commands/*.md are GENERATED from .claude/commands/u-*.md by
# plugin/gen-commands.sh — never hand-edited. Regenerate into a throwaway temp dir (never touching
# the committed one) and diff; any difference means a stub went stale — a canonical body changed
# and nobody re-ran the generator, a stub was hand-edited directly, or a canonical source vanished
# — and is a loud, mechanical failure rather than a silent skew. Hermetic: no network, one bash
# script, a handful of small files.
step "generated commands (plugin/commands/ drift)"
GEN_TMP="$(mktemp -d)"
trap 'rm -rf "$GEN_TMP"' EXIT
plugin/gen-commands.sh "$GEN_TMP"
if ! diff -rq "$GEN_TMP" plugin/commands >/dev/null 2>&1; then
  fail "plugin/commands/ is out of date — run: plugin/gen-commands.sh, then commit the result"
  diff -ru "$GEN_TMP" plugin/commands >&2 || true
  exit 1
fi
ok "plugin/commands/ matches the generator"

# ── 4b. duplicate-prose detector (P1-FR2's missing acceptance criterion) ──────
# The drift check above only catches a stub going stale against the generator's OWN output; it
# can't catch a canonical command body copy-pasted into a second file instead of left as a pointer
# — the actual failure mode P1-FR2's "no duplicated 20-word command sentence anywhere in the tree"
# criterion targets. Normalize each command file's BODY (frontmatter stripped — YAML metadata is
# not "a canonical body pasted into a second home") to lowercase word tokens, slide a 20-word
# shingle window over it, and flag any shingle shared by two DIFFERENT files.
#
# plugin/commands/*.md IS scanned (per the criterion's own wording), but its three boilerplate
# lines are filtered out first: by construction (plugin/gen-commands.sh, itself enforcing a hard
# ≤3-line cap) every byte of every file there is that SAME pointer template, parameterized only by
# the target filename — flagging it here would just be the boilerplate against itself, and any
# hand-edit that actually changed it already fails the drift step above. The bare 1-line aliases
# (.claude/commands/{swarm,swarm-loop,setup,speedwars}.md) need no special-casing: each is well
# under 20 body words (verified), so none of them can ever form a full shingle.
step "duplicate-prose detector (command bodies)"
# shellcheck disable=SC2016 # single-quoted regex text (incl. a literal backtick pair), not a shell expansion
BOILERPLATE_RE='^Generated file — do not edit\.|^Read and execute the canonical body at|last resort `git rev-parse --show-toplevel`'
dup_failed=0
pairs=""
for f in .claude/commands/*.md plugin/commands/*.md; do
  [[ -f "$f" ]] || continue
  # plugin/commands/*.md reduces to ZERO bytes here on purpose (every line is the boilerplate
  # BOILERPLATE_RE strips) — `grep -v`'s "no lines selected" exit 1 is a real outcome for that
  # file, not an error, so the whole substitution is `|| true`-guarded against `pipefail`.
  shingles="$(awk 'BEGIN{fm=0} NR==1 && $0=="---"{fm=1; next} fm==1 && $0=="---"{fm=0; next} fm==1{next} {print}' "$f" \
    | grep -vE "$BOILERPLATE_RE" \
    | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' ' ' | tr -s ' ' '\n' | grep -v '^$' \
    | awk -v n=20 '{w[NR]=$0} END{for(i=1;i+n-1<=NR;i++){s="";for(j=0;j<n;j++)s=s w[i+j] " "; print s}}' \
    | sort -u)" || true
  [[ -n "$shingles" ]] || continue
  while IFS= read -r s; do
    pairs+="$s"$'\t'"$f"$'\n'
  done <<< "$shingles"
done

dupes="$(printf '%s' "$pairs" | cut -f1 | sort | uniq -d)"
if [[ -n "$dupes" ]]; then
  while IFS= read -r dupe; do
    [[ -z "$dupe" ]] && continue
    files="$(printf '%s' "$pairs" | awk -F'\t' -v s="$dupe" '$1==s{print $2}' | sort -u | paste -sd, -)"
    fail "duplicated command prose (20-word shingle) shared by: $files"
    dup_failed=1
  done <<< "$dupes"
fi
if ((dup_failed)); then
  fail "duplicate-prose detector found a canonical command body copy-pasted into a second file"
  exit 1
fi
ok "duplicate-prose detector clean"

# ── 5. shellcheck ───────────────────────────────────────────────────────────
step "shellcheck -x"
skip_shellcheck=0
if [[ "${CHECK_SKIP_SHELLCHECK:-0}" == "1" ]]; then
  # Same contract as CHECK_SKIP_BATS: tests/check-gates.bats' fixture copies ONLY. Those tests
  # prove the grep-gates fire on planted violations — re-linting the identical scripts in every
  # copy was ~2 min per test (2026-08-01 profile: check-gates.bats at 20 min WAS the gate's
  # critical path). Never set this for a real check.sh run.
  skip_shellcheck=1
  echo "⚠⚠⚠ CHECK_SKIP_SHELLCHECK=1 — shellcheck SKIPPED ⚠⚠⚠"
  echo "⚠⚠⚠ tests/check-gates.bats fixture-copy path ONLY — never set this for a real run ⚠⚠⚠"
elif command -v shellcheck >/dev/null 2>&1; then
  shellcheck -x "${SHELL_SOURCES[@]}"
  ok "shellcheck clean"
else
  echo "⚠ shellcheck not installed — skipping lint"
fi

# ── 6. bats ─────────────────────────────────────────────────────────────────
step "bats tests/"
skip_bats=0
if [[ "${CHECK_SKIP_BATS:-0}" == "1" ]]; then
  skip_bats=1
  echo "⚠⚠⚠ CHECK_SKIP_BATS=1 — bats tests/ SKIPPED, including traversal/write-cage security tests ⚠⚠⚠"
  echo "⚠⚠⚠ planted-line recursion path ONLY (tests/check-gates.bats) — never set this for a real run ⚠⚠⚠"
elif command -v bats >/dev/null 2>&1; then
  CHECK_JOBS="${CHECK_JOBS:-6}"
  if [[ ! "$CHECK_JOBS" =~ ^[1-9][0-9]*$ ]]; then
    fail "CHECK_JOBS must be a positive integer (got '$CHECK_JOBS')"; exit 1
  fi
  if (( CHECK_JOBS == 1 )); then
    bats tests/
  else
    batslog="$(mktemp -d)"
    bats_rc=0
    for tf in tests/*.bats; do
      while (( $(jobs -rp | wc -l) >= CHECK_JOBS )); do
        wait -n || bats_rc=1
      done
      bats "$tf" > "$batslog/${tf##*/}.log" 2>&1 &
    done
    while (( $(jobs -rp | wc -l) > 0 )); do
      wait -n || bats_rc=1
    done
    if (( bats_rc )); then
      for lf in "$batslog"/*.log; do
        if grep -q '^not ok' "$lf"; then
          echo "── ${lf##*/} ──"
          cat "$lf"
        fi
      done
      rm -rf "$batslog"
      fail "bats failed (CHECK_JOBS=$CHECK_JOBS — rerun with CHECK_JOBS=1 to rule out a parallel-only flake)"
      exit 1
    fi
    echo "$(awk '/^ok /{n++} END{print n+0}' "$batslog"/*.log) tests green across $(find tests -maxdepth 1 -name '*.bats' | wc -l) files (CHECK_JOBS=$CHECK_JOBS)"
    rm -rf "$batslog"
  fi
  ok "tests pass"
else
  echo "⚠ bats not installed — skipping tests"
fi

if ((skip_bats || skip_shellcheck)); then
  skipped=""
  ((skip_bats)) && skipped+="bats+"
  ((skip_shellcheck)) && skipped+="shellcheck+"
  echo "✓ gates green (${skipped%+} SKIPPED — not a full gate)"
else
  echo "✓ check green"
fi
