#!/usr/bin/env bash
# speedwars-report.sh — render the per-lane speed table from the speedwars JSONL ledger.
#
# Project: unimatrix
# Module:  src/speedwars-report.sh
# Deps:    bash >=5.1, jq >=1.6
# Tested:  tests/verdict-fold.bats (the canonical fold), tests/swarm-lib.bats (speedwars section)
#
# Key responsibilities:
# - Fold the ledger per the CANONICAL VERDICT SEMANTICS — written down once in
#   tests/fixtures/verdict-fold/README.md and implemented twice: here in jq and in
#   site/cockpit/fold.js for the cockpit. The fixture is the contract; tests/verdict-fold.bats
#   replays it through both, so a divergence between the two renderers turns a test red.
# - Per-lane table: attempts, cards, verified-done, false-done, unjudged, failed, median+p95 wall,
#   median tok/s, $ per verified-done — medians never means (spec 08 FR-7).
# - Second table stratified by complexity bucket (C1-C5) where run-meta rows exist — printed under
#   its COVERAGE DENOMINATOR (plan 004 P2-FR2 / docs/ops/ledger-coverage.md: ledger coverage is
#   under the 80% bar, so no stratified figure may ever render bare again).
# - Text-branch "anthropic share" footer: $/tokens for served_lane=="claude" priced rows vs all
#   priced rows — only the claude lane is Anthropic-billed (glm/kimi ride the CLI but carry their
#   own served_lane + recomputed pricing). Folded over the same attempt set, so --run applies.
# - `--json` emits the canonical per-lane aggregates only (no medians, no formatting) — the shape
#   the fixture pins and `unimatrix mirror --verify` will diff against (plan 004 P3-FR7).
# - `--run <label>` narrows every row to one run BEFORE folding (plan 004 P2-FR1's close-out lane
#   summary shells this) — a pre-filter only: the fold, and the `--json` contract shape, are
#   byte-identical to the unfiltered path.
#
# Design constraints: read-only; no state; ledger is append-only JSONL possibly mixing typed
# side-rows (run-meta / verdict / review) with untyped branch rows. Trust is per CARD (run+id) and
# is credited to the lane of the card's FINAL attempt; an unjudged claim is never verified.
# The `--json` object is a PINNED CONTRACT (tests/fixtures/verdict-fold/expected.json, replayed
# through site/cockpit/fold.js too) — never add a field to it without changing both sides.
set -euo pipefail
shopt -s inherit_errexit

JSON=0
RUN=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) JSON=1; shift ;;
    --run)
      # A missing argument must be usage, not a raw `shift 2` death — and never silently consume
      # a ledger path as the run label (cross-review finding).
      [[ $# -ge 2 && -n "${2:-}" && "${2:0:1}" != "-" ]] || { echo "speedwars-report: --run needs a label" >&2; exit 2; }
      RUN="$2"; shift 2 ;;
    --run=*) RUN="${1#*=}"; shift ;;
    *) break ;;
  esac
done

FILE="${1:-$(dirname "${BASH_SOURCE[0]}")/../docs/ops/speedwars.jsonl}"
[[ -f "$FILE" ]] || { echo "speedwars: no ledger at $FILE" >&2; exit 1; }

report() {
  jq -rs --argjson json "$JSON" --arg runf "$RUN" '
  def median: map(select(. != null)) | sort
    | if length == 0 then null else .[((length - 1) / 2) | floor] end;
  def p95: map(select(. != null)) | sort
    | if length == 0 then null
      else .[([(length * 0.95 | floor), length - 1] | min)] end;
  def fmt: if . == null then "-" else (. * 10 | round / 10 | tostring) end;
  # 6 dp is the contract (jq and JS must land on the same JSON literal); 3 dp is for the table.
  def r6: if . == null then null else (. * 1000000 | round) / 1000000 end;
  def usd3: if . == null then "-" else (. * 1000 | round / 1000 | tostring) end;
  # 2 dp fixed form for the anthropic-share footer dollars (always "0.00"-shaped, never null/"-").
  def usd2: (. * 100 | round | tostring) as $c
    | if ($c | length) <= 2 then "0." + ("0" * (2 - ($c | length))) + $c
      else $c[:-2] + "." + $c[-2:] end;
  # v0 rows encode `verified` as the STRING "pass"/"fail" (case-exact) instead of a boolean
  # (canon rule 11). Normalize both encodings to real booleans before judging; any other value
  # (null, any other string) stays a non-judgment.
  def normverdict: if type == "boolean" then .
                   elif . == "pass" then true
                   elif . == "fail" then false
                   else null end;

  # attempt-level stats: whatever actually ran on this lane, failures included.
  def astats: (map(.cost_usd // empty)) as $c
    | { attempts: length,
        cost_total: (if ($c | length) == 0 then null else ($c | add | r6) end),
        cost_priced: ($c | length),
        med_wall: (map(.wall_secs) | median | fmt),
        p95_wall: (map(.wall_secs) | p95 | fmt),
        med_tok_s: (map(select(.tokens_out != null and .wall_secs != null and .wall_secs > 0)
                    | (.tokens_out / .wall_secs)) | median | fmt) };

  # card-level stats: the four buckets partition `cards` (canon rule 7).
  def cstats: { cards: length,
      verified_done: (map(select(.judged and .verified == true)) | length),
      false_done:    (map(select(.judged and .verified == false)) | length),
      unjudged_done: (map(select((.judged | not) and .final_outcome == "done")) | length),
      failed:        (map(select((.judged | not) and .final_outcome != "done")) | length),
      inconclusive:  (map(select(.has_verdict and (.judged | not))) | length) };

  # $ per verified-done: the lane whole bill / its verified-done CARDS (canon rule 8). A lane with
  # attempts but no cards of its own (every card it touched was retried elsewhere) still shows its
  # spend — with a null rate, never a zero one.
  def merge($A; $C): $A | to_entries | map(
      .key as $k | .value as $a
      | ($C[$k] // {cards:0, verified_done:0, false_done:0, unjudged_done:0, failed:0, inconclusive:0}) as $c
      | {key: $k, value: ($a + $c + {cost_per_verified_done:
          (if $c.verified_done > 0 and $a.cost_total != null
           then ($a.cost_total / $c.verified_done | r6) else null end)})})
    | from_entries;

  def row($k; $v): [$k, $v.attempts, $v.cards, $v.verified_done, $v.false_done, $v.unjudged_done,
                    $v.failed, $v.med_wall, $v.p95_wall, $v.med_tok_s,
                    ($v.cost_per_verified_done | usd3)] | map(tostring) | join("\t");

  # --run narrows the row set BEFORE anything folds — a pre-filter, never a second code path.
  (map(select(type == "object"))
   | if $runf == "" then . else map(select(.run == $runf)) end) as $all
  # Join key is run/id — NEVER lane-scoped: verdict rows are specified as {run,id,verified,reason}
  # (spec 08 FR-5) and v0 rows carry no lane at all. Append-only ledger => the LAST row wins.
  | ($all | map(select(.type == "verdict") | {key: (.run + "/" + .id), value: .verified})
          | from_entries) as $verd
  | ($all | map(select(.type == "run-meta") | . as $m
          # cards is normally an object keyed by card-id (FR-4); tolerate summary-style rows
          # that carry a scalar count instead (append-only ledger mixes schemas) — skip them.
          | (($m.cards // {}) | if type == "object" then . else {} end) | to_entries[]
          | {key: ($m.run + "/" + .key), value: (.value.complexity // null)})
          | from_entries) as $cx
  | ($all | map(select(.type == null) | . + {ckey: (.run + "/" + .id), lane: (.served_lane // "?")})
          | map(.ckey as $k | . + {complexity: (if ($cx | has($k)) then $cx[$k] else null end)})) as $att
  # One row = one ATTEMPT; a card is all attempts sharing run+id, credited to its FINAL lane.
  | ($att | group_by(.ckey) | map(
        (sort_by(.ts) | last) as $f | $f.ckey as $k
        | { lane: $f.lane, complexity: $f.complexity, final_outcome: $f.outcome,
            has_verdict: ($verd | has($k)),
            # verdict values are booleans (or v0 "pass"/"fail" strings, normalized above) — jq `//`
            # treats false as absent, so use has(); a verdict that normalizes to neither true nor
            # false (gate inconclusive, or any other non-boolean) is NOT a judgment.
            judged: (($verd | has($k)) and (($verd[$k] | normverdict) != null)),
            verified: (if ($verd | has($k)) then ($verd[$k] | normverdict) else null end) })) as $cards
  | merge(($att   | group_by(.lane) | map({key: .[0].lane, value: astats}) | from_entries);
          ($cards | group_by(.lane) | map({key: .[0].lane, value: cstats}) | from_entries)) as $L
  | merge(($att   | map(select(.complexity != null)) | group_by([.lane, .complexity])
                  | map({key: (.[0].lane + ":C" + (.[0].complexity | tostring)), value: astats})
                  | from_entries);
          ($cards | map(select(.complexity != null)) | group_by([.lane, .complexity])
                  | map({key: (.[0].lane + ":C" + (.[0].complexity | tostring)), value: cstats})
                  | from_entries)) as $LX
  | if $json == 1 then
      { lanes: ($L | with_entries(.value |= {attempts, cards, verified_done, false_done,
                                             unjudged_done, failed, inconclusive,
                                             cost_total, cost_priced, cost_per_verified_done})) }
    else
      "LANE\tATTEMPTS\tCARDS\tVDONE\tFALSE-DONE\tUNJUDGED\tFAIL\tMED-WALL\tP95-WALL\tMED-TOK/S\t$/VDONE",
      ($L | to_entries | sort_by(.key)[] | row(.key; .value)),
      "\t\t\t\t\t\t\t\t\t\t",
      # P2-FR2: the complexity table is the one STRATIFIED surface here (lane is 100% known;
      # complexity comes only from run-meta rows, which cover a minority of runs). It never
      # renders without this denominator — computed from the rows in hand, never hardcoded.
      (($all | map(.run // empty) | unique | length) as $runs_t
       | ($all | map(select(.type == "run-meta") | .run // empty) | unique | length) as $runs_c
       | ($cards | length) as $cards_t
       | ($cards | map(select(.complexity != null)) | length) as $cards_c
       | "stratified over \($runs_c) of \($runs_t) runs — "
         + (if $runs_t == 0 then "0" else ($runs_c * 100 / $runs_t | round | tostring) end) + "%"
         + " (\($cards_c) of \($cards_t) cards carry a complexity bucket)"),
      "LANE:CX\tATTEMPTS\tCARDS\tVDONE\tFALSE-DONE\tUNJUDGED\tFAIL\tMED-WALL\tP95-WALL\tMED-TOK/S\t$/VDONE",
      ($LX | to_entries | sort_by(.key)[] | row(.key; .value)),
      # anthropic-share footer (tab-less => awk passes it through verbatim, like the coverage
      # caption above). Only served_lane=="claude" rows are Anthropic-billed — glm/kimi ride the
      # claude CLI but carry their own served_lane + recomputed pricing, so they are excluded.
      # Folded over $att (the same attempt set every other figure uses), so --run applies.
      ($att
        | (map(select((.cost_usd | type) == "number"))) as $p
        | ($p | map(select(.served_lane == "claude"))) as $pc
        | (($pc | map(.cost_usd) | add) // 0) as $cc
        | (($p  | map(.cost_usd) | add) // 0) as $tc
        | (($pc | map(((.tokens_in // 0) + (.tokens_out // 0))) | add) // 0) as $ct
        | (($p  | map(((.tokens_in // 0) + (.tokens_out // 0))) | add) // 0) as $tt
        | ($cc | usd2) as $ccs
        | ($tc | usd2) as $tcs
        | (if $tc == 0 then 0 else ($cc * 100 / $tc | round) end) as $pct
        | (if $tt == 0 then 0 else ($ct * 100 / $tt | round) end) as $ttpct
        | "anthropic share: $\($ccs) of $\($tcs) priced cost (\($pct)%) · \($ct) of \($tt) tokens (\($ttpct)%) — claude lane only; fable session + doctor probes not ledgered")
    end
' "$FILE"
}

if [[ "$JSON" == 1 ]]; then
  report
  exit 0
fi

# The P2-FR2 coverage caption is PROSE on its own (tab-less) line, not a table row: fed straight
# into `column -t` it becomes one ~70-char field and pads column 1 of BOTH tables to its width.
# So tabbed lines go through column, tab-less ones are passed through verbatim, and closing the
# co-process at each boundary keeps the two blocks in file order (fflush pairs guard the mixing of
# awk's own writes with the child's when stdout is a pipe).
report | awk -F'\t' -v COL='column -t -s "\t"' '
  NF > 1 { print | COL; next }
  { close(COL); fflush(); print; fflush() }
  END { close(COL) }
'

echo
echo "reviews:"
jq -r --arg runf "$RUN" 'select(.type == "review") | select($runf == "" or .run == $runf)
  | "  \(.ts) \(.run) \(.lane // "-") score \(.score) [\(.tags // [] | join(","))] \(.note // "")"' "$FILE" || true
