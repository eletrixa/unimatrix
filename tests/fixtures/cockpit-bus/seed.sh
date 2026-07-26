#!/usr/bin/env bash
# seed.sh <target-busdir> — materialize the spec-07 §5.5 QA fixture bus with live mtimes.
#
# Project: unimatrix
# Module:  tests/fixtures/cockpit-bus/seed.sh
# Deps:    bash >=5.1, coreutils (touch -d)
# Tested:  driven by the wave-8 QA checklist (plans/002-cockpit-redesign/PLAN.md §5.5); not a bats fixture
#
# Key responsibilities:
# - Build every visual state the cockpit must render: queued, running, stale, erroring,
#   verify row, done (+drawer bodies), cancelled, parked + lane-limited, loop header.
# Design constraints: mtimes are runtime-relative (stale = -10min vs LEASE_MIN=15) so the
# tree cannot be a static checkout — always seed into a THROWAWAY dir, never a real bus.
set -euo pipefail
TARGET="${1:?usage: seed.sh <target-busdir>}"
mkdir -p "$TARGET"/{specs,queue,claimed,done,cancelled,limits,pids,loop/r-t}

# queued
printf 'fixture spec b-44\n' > "$TARGET/queue/b-44.prompt"
printf 'fixture spec b-45\n' > "$TARGET/queue/b-45.prompt"

# running: fresh claim + live-ish run log (system init w/ model, tool_use Bash, tool_result, text)
printf 'fixture spec b-03\n' > "$TARGET/claimed/b-03.claude:sonnet"
{
  printf '{"type":"system","subtype":"init","model":"claude-sonnet-5","timestamp":"%s"}\n' "$(date -u +%FT%TZ)"
  printf '{"type":"assistant","timestamp":"%s","message":{"model":"claude-sonnet-5","content":[{"type":"tool_use","name":"Bash","input":{"command":"ls tests/"}}]}}\n' "$(date -u +%FT%TZ)"
  printf '{"type":"user","timestamp":"%s","message":{"content":[{"type":"tool_result","content":"cockpit-api.bats"}]}}\n' "$(date -u +%FT%TZ)"
  printf '{"type":"assistant","timestamp":"%s","message":{"model":"claude-sonnet-5","content":[{"type":"text","text":"running the suite next"}]}}\n' "$(date -u +%FT%TZ)"
} > "$TARGET/run-b-03.jsonl"

# stale: claim + run log both 10 min old (LEASE_MIN=15 -> stale threshold 7.5m)
printf 'fixture spec b-17\n' > "$TARGET/claimed/b-17.codex:default"
printf '{"type":"thread.started","thread_id":"fx"}\n' > "$TARGET/run-b-17.jsonl"
touch -d '10 minutes ago' "$TARGET/claimed/b-17.codex:default" "$TARGET/run-b-17.jsonl"

# erroring: 3 error events + retries flag
printf 'fixture spec b-23\n' > "$TARGET/claimed/b-23.glm:glm-5.2"
{
  printf '{"type":"error","message":"ETIMEDOUT api.z.ai"}\n'
  printf '{"type":"error","message":"ETIMEDOUT api.z.ai"}\n'
  printf '{"type":"error","message":"ETIMEDOUT api.z.ai"}\n'
} > "$TARGET/run-b-23.jsonl"
printf '2' > "$TARGET/limits/.retries-b-23"

# verify row: v-b-01 queued (pinned per post-wave-7 bundle discipline) + its target done
printf 'verify fixture for b-01\n' > "$TARGET/queue/v-b-01.prompt"
printf 'codex:default' > "$TARGET/queue/v-b-01.lane"

# done ×2 (staggered) + drawer bodies for b-35
printf '{"id":"b-01","code":0,"lane":"glm"}\n' > "$TARGET/done/b-01"
printf '{"id":"b-35","code":0,"lane":"grok"}\n' > "$TARGET/done/b-35"
printf 'the b-35 handoff answer body\n' > "$TARGET/res-b-35.txt"
printf 'the b-35 original spec text\n' > "$TARGET/prompt-b-35.txt"
touch -d '25 minutes ago' "$TARGET/done/b-01"
touch -d '3 minutes ago'  "$TARGET/done/b-35"

# cancelled
printf 'fixture spec b-09\n' > "$TARGET/cancelled/b-09.prompt"

# parked + lane-limited (glm .limited TTL 18000s)
printf '18000' > "$TARGET/limits/glm.limited"
printf 'fixture spec b-41\n' > "$TARGET/queue/b-41.prompt"
touch "$TARGET/limits/b-41.parked"

# loop header: r-t 3/12
cat > "$TARGET/loop/r-t/criteria.md" << 'CRIT'
# loop criteria (fixture)
stops:
  max_iterations: 12
  budget_usd: 10
CRIT
{
  printf '{"iter":1,"tried":1,"oracle_rc":1,"cost":0.1,"ts":"t1"}\n'
  printf '{"iter":2,"tried":1,"oracle_rc":1,"cost":0.2,"ts":"t2"}\n'
  printf '{"iter":3,"tried":1,"oracle_rc":0,"cost":0.1,"ts":"t3"}\n'
} > "$TARGET/loop/r-t/state.jsonl"

echo "seeded: $TARGET"
