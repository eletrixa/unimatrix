/**
 * Canonical verdict fold — the ONE definition of "$ per verified-done" (plan 004 P0-FR7).
 *
 * Project: unimatrix — multi-model swarm orchestrator driven from Claude Code
 * Module:  site/cockpit/fold.js
 * Deps:    none (pure data; importable from the browser AND from `node -e` with no DOM)
 * Tested:  tests/verdict-fold.bats (replays tests/fixtures/verdict-fold/ledger.jsonl)
 *
 * Key responsibilities:
 * - Collapse speedwars ledger ATTEMPT rows into CARDS (run + id) and attach each card's verdict.
 * - Emit the per-lane canonical counts every renderer must agree on: verified_done, false_done,
 *   unjudged_done, failed, inconclusive, cost_total, cost_priced, cost_per_verified_done.
 *
 * Design constraints:
 * - The canonical semantics are written down ONCE, in tests/fixtures/verdict-fold/README.md.
 *   This file and src/speedwars-report.sh are two implementations of that one contract; the
 *   fixture is the contract, and tests/verdict-fold.bats replays it through both. Change the
 *   semantics here and the shell side goes red (and vice versa) — that is the point.
 * - No DOM, no imports, no formatting: numbers only. Rendering ("—" vs "-") stays in the callers.
 * - Never invent a number: a lane that emits no cost_usd is `cost_total: null`, never 0; a card
 *   with no boolean (or v0 "pass"/"fail" string) verdict is unjudged, never verified (spec 09
 *   FR-7).
 */

// Rounding is part of the contract: the shell and JS folds must land on the same JSON literal,
// and IEEE754 sums (0.30 + 0.05 + 0.20) do not. 6 dp is far below any real cost resolution.
function r6(v) {
  return v == null ? null : Math.round(v * 1e6) / 1e6;
}

function num(v) {
  return typeof v === 'number' && Number.isFinite(v) ? v : null;
}

// v0 rows encode `verified` as the STRING "pass"/"fail" (case-exact) instead of a boolean (canon
// rule 11). Normalize both encodings to real booleans before judging; any other value (null, any
// other string) stays a non-judgment (null).
export function normVerdict(v) {
  if (typeof v === 'boolean') return v;
  if (v === 'pass') return true;
  if (v === 'fail') return false;
  return null;
}

// Rule 12: an attempt with a missing/null `ts` always loses the final-attempt tie-break to any
// ts-carrying attempt, regardless of file order. Among ts-less attempts, the later row (input
// order) wins, same as any other tie.
function isLaterAttempt(candidate, current) {
  const cHas = candidate.ts != null;
  const curHas = current.ts != null;
  if (cHas && curHas) return String(candidate.ts) >= String(current.ts);
  if (cHas !== curHas) return cHas;
  return true;
}

/**
 * canonicalFold(rows) — rows is the raw ledger as objects (typed side-rows mixed with untyped
 * card rows), exactly what one JSONL line parses to. Card rows are the ones with no `type`
 * (spec 08 FR-1); everything else is ignored here except `type:"verdict"`.
 *
 * Returns { cardList, verdictOf, laneNames, lanes } where `lanes` is the canonical per-lane
 * record — the object the fixture pins and the shell's `--json` mode must reproduce byte-for-byte.
 */
export function canonicalFold(rows) {
  const attempts = [];
  const verdicts = [];
  for (const r of rows || []) {
    if (!r || typeof r !== 'object') continue;
    if (r.type == null) attempts.push(r);
    else if (r.type === 'verdict') verdicts.push(r);
  }

  // Join key is run + "/" + id — NOT the lane. Verdict rows are specified as {run,id,verified,
  // reason} (spec 08 FR-5) and the v0 rows in the live ledger carry no lane at all; ids are
  // unique only within a run (spec 09 data contract).
  const keyOf = (r) => `${r.run}/${r.id}`;

  // Append-only ledger ⇒ file order is chronological ⇒ the LAST verdict for a key is the standing
  // correction. Verdict rows are not required to carry `ts`, so ts cannot be the tie-break.
  const vIndex = new Map();
  for (const v of verdicts) vIndex.set(keyOf(v), v);
  const verdictOf = (r) => vIndex.get(keyOf(r)) || null;

  const cardIndex = new Map();
  for (const a of attempts) {
    const k = keyOf(a);
    let entry = cardIndex.get(k);
    if (!entry) {
      entry = { key: k, run: a.run, id: a.id, attempts: [], final: a, verdict: vIndex.get(k) || null };
      cardIndex.set(k, entry);
    }
    entry.attempts.push(a);
    // "final" = the latest attempt by ts (ties → the later row; ts-less always loses — rule 12).
    // That is the answer the verdict judged, and its lane is the lane the card's outcome is
    // credited to.
    if (isLaterAttempt(a, entry.final)) entry.final = a;
  }
  const cardList = [...cardIndex.values()];
  for (const c of cardList) {
    c.lane = c.final.served_lane == null ? '?' : c.final.served_lane;
    c.judged = c.verdict != null && normVerdict(c.verdict.verified) !== null;
    c.verified = c.judged ? normVerdict(c.verdict.verified) : null;
  }

  const laneNames = [...new Set(attempts.map((a) => (a.served_lane == null ? '?' : a.served_lane)))].sort();
  const lanes = {};
  for (const lane of laneNames) {
    const la = attempts.filter((a) => (a.served_lane == null ? '?' : a.served_lane) === lane);
    const lc = cardList.filter((c) => c.lane === lane);
    const costs = la.map((a) => num(a.cost_usd)).filter((v) => v != null);
    const verifiedDone = lc.filter((c) => c.judged && c.verified === true).length;
    const costTotal = costs.length ? r6(costs.reduce((x, y) => x + y, 0)) : null;
    lanes[lane] = {
      attempts: la.length,
      cards: lc.length,
      verified_done: verifiedDone,
      false_done: lc.filter((c) => c.judged && c.verified === false).length,
      unjudged_done: lc.filter((c) => !c.judged && c.final.outcome === 'done').length,
      failed: lc.filter((c) => !c.judged && c.final.outcome !== 'done').length,
      inconclusive: lc.filter((c) => c.verdict != null && !c.judged).length,
      cost_total: costTotal,
      cost_priced: costs.length,
      // Denominator is verified-done CARDS, never done-claims (spec 08 FR-7). Numerator is the
      // lane's whole bill including the attempts that failed — SWE-Effi "expensive failures":
      // spend that produced nothing verified still has to land on somebody's line.
      cost_per_verified_done: verifiedDone > 0 && costTotal != null ? r6(costTotal / verifiedDone) : null,
    };
  }

  return { cardList, verdictOf, laneNames, lanes };
}
