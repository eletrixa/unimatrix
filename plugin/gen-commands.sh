#!/usr/bin/env bash
# Generates plugin/commands/<name>.md pointer stubs from .claude/commands/u-*.md canonical bodies.
#
# Project: unimatrix — multi-model agent-swarm orchestrator driven from Claude Code
# Module:  plugin/gen-commands.sh
# Deps:    bash >=5.1, coreutils (find, sort, basename, wc)
# Tested:  tests/check-gates.bats (check.sh's "generated commands" step regenerates into a temp
#          dir and diffs against plugin/commands/; separate cases exercise new-source-produces-stub
#          and missing-source-fails-loudly)
#
# Key responsibilities:
# - P1-FR2: one canonical command body per verb lives in .claude/commands/u-<name>.md; this script
#   is the only producer of plugin/commands/<name>.md, a generated pointer, never hand-edited
# - Deterministic output: stable (sorted) source ordering, no timestamps, no host paths, so
#   check.sh's regenerate-and-diff step is meaningful and re-running never produces spurious churn
# - Enforces the PRD stub rules itself rather than trusting a caller: every emitted stub is ≤3
#   lines (checked after writing), and a stub whose canonical source has vanished since the last
#   generation is a loud failure, not a silent drop (P1-FR2 acceptance criterion)
#
# Design constraints:
# - Must be idempotent: running twice with no source changes leaves plugin/commands/ byte-identical
# - Stub bodies are frontmatter-free and contain no absolute /home path — only $UNIMATRIX_HOME and
#   $ARGUMENTS as literal placeholder text for the reading agent to resolve at invocation time
# - Optional $1 overrides the output dir (check.sh passes a throwaway temp dir to diff against the
#   committed one without touching it); default is the in-place plugin/commands/ a maintainer runs
set -euo pipefail
shopt -s inherit_errexit

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC_DIR="$REPO_ROOT/.claude/commands"
OUT_DIR="${1:-$SCRIPT_DIR/commands}"

mkdir -p "$OUT_DIR"

# A stub already sitting in OUT_DIR whose canonical u-*.md has been renamed or deleted must not be
# silently dropped on regeneration — that is data loss disguised as a no-op. Only bites on an
# in-place run against a populated OUT_DIR; a fresh temp dir (check.sh's usage) has nothing yet.
while IFS= read -r -d '' existing; do
  name="$(basename "$existing" .md)"
  target="$SRC_DIR/u-$name.md"
  if [[ ! -f "$target" ]]; then
    echo "gen-commands.sh: canonical source missing for existing stub '$existing' (expected $target) — a u-*.md was renamed or deleted; fix the source or remove the stale stub" >&2
    exit 1
  fi
done < <(find "$OUT_DIR" -maxdepth 1 -type f -name '*.md' -print0 2>/dev/null)

while IFS= read -r -d '' src; do
  base="$(basename "$src" .md)"   # e.g. u-call
  name="${base#u-}"               # e.g. call
  out="$OUT_DIR/$name.md"
  {
    printf 'Generated file — do not edit. Regenerate with plugin/gen-commands.sh.\n'
    # shellcheck disable=SC2016 # literal $UNIMATRIX_HOME/$ARGUMENTS placeholders for the reading agent
    printf 'Read and execute the canonical body at $UNIMATRIX_HOME/.claude/commands/%s.md with arguments $ARGUMENTS.\n' "$base"
    # shellcheck disable=SC2016 # literal $UNIMATRIX_HOME placeholder, not a shell expansion
    printf 'If $UNIMATRIX_HOME is unset: source ~/.config/unimatrix/config (written by `unimatrix install`); last resort `git rev-parse --show-toplevel`.\n'
  } >"$out"
  lines="$(wc -l < "$out")"
  if ((lines > 3)); then
    echo "gen-commands.sh: emitted stub '$out' has $lines lines, exceeds the 3-line PRD bound" >&2
    exit 1
  fi
done < <(find "$SRC_DIR" -maxdepth 1 -type f -name 'u-*.md' -print0 | sort -z)
