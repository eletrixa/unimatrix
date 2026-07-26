/**
 * SPEEDWARS view — the run-evidence ledger as a cross-run comparison board.
 *
 * Project: unimatrix — multi-model swarm orchestrator driven from Claude Code
 * Module:  site/cockpit/speed.js
 * Deps:    format.js (esc, fmtTok, loadJSON, saveJSON, laneLetter, laneColor); fold.js
 *          (canonicalFold — the shared verdict semantics); GET /api/speedwars
 * Tested:  tests/speedwars-api.bats (the route); tests/verdict-fold.bats (the fold);
 *          playwright Lane-A QA (spec 09 acceptance)
 *
 * Key responsibilities:
 * - Render ONLY inside #view-speed: panel header, sub-tab bar (TOTAL first, then one tab per field
 *   dimension — spec 09 FR-4), and the active sub-tab's body.
 * - Fetch docs/ops/speedwars.jsonl via /api/speedwars once per activation (FR-10), fold it
 *   client-side (FR-2), and persist the selected sub-tab (FR-5).
 * - Show every derived rate with its denominator (FR-8) and every absence as absence (FR-7).
 *
 * Design constraints:
 * - This is the only HISTORICAL view in a live-bus cockpit: it never listens to the render tick
 *   and never reads `store`. Its data changes once per run, not once per second.
 * - No chart library, no SVG: bars and distributions are positioned divs + gradients, the same
 *   technique flight.js uses for its tracks.
 * - Never invent a number. A lane that emits no cost (codex bills to a subscription) renders
 *   "not billed", never $0; an unjudged card is "unjudged", never "verified" (FR-14 / FR-7).
 * - Verdict/trust/$-per-verified-done numbers come from fold.js and are NEVER recomputed here:
 *   the report (src/speedwars-report.sh) is the other implementation of the same contract, and
 *   tests/fixtures/verdict-fold/ is what keeps the two from drifting apart.
 * - Lane identity comes from laneColor()/laneLetter() verbatim — no local palette.
 */

import { esc, fmtTok, loadJSON, saveJSON, laneLetter, laneColor } from './format.js';
import { canonicalFold, normVerdict } from './fold.js';

// --- module state ------------------------------------------------------------------------------

let root = null;
let bound = false;
let loading = false;
let loaded = false;
let error = null;
let data = null; // the /api/speedwars payload
let agg = null; // folded aggregates, rebuilt whenever data changes

const TABS = [
  { id: 'total', label: 'TOTAL', hint: 'everything, rolled up' },
  { id: 'speed', label: 'SPEED', hint: 'wall-clock per card' },
  { id: 'cost', label: 'COST', hint: 'dollars per card' },
  { id: 'trust', label: 'RELIABILITY', hint: 'claimed vs verified' },
  { id: 'tokens', label: 'TOKENS', hint: 'in / out / cached' },
  { id: 'runs', label: 'RUNS', hint: 'run over run' },
];

let tab = 'total';

// --- small math (order statistics only — spec 08 ruled out ratings at these sample sizes) -------

function median(nums) {
  if (!nums.length) return null;
  const s = [...nums].sort((a, b) => a - b);
  const mid = s.length >> 1;
  return s.length % 2 ? s[mid] : Math.round((s[mid - 1] + s[mid]) / 2);
}

// Nearest-rank quantile: with 21 samples "p90" must name a real observation, not an interpolation
// between two cards that never existed.
function quantile(nums, q) {
  if (!nums.length) return null;
  const s = [...nums].sort((a, b) => a - b);
  return s[Math.min(s.length - 1, Math.ceil(q * s.length) - 1)];
}

function sum(nums) {
  return nums.reduce((a, b) => a + b, 0);
}

function num(v) {
  return typeof v === 'number' && Number.isFinite(v) ? v : null;
}

// --- formatting ---------------------------------------------------------------------------------

function fmtSecs(s) {
  if (s == null) return '—';
  if (s < 60) return `${Math.round(s)}s`;
  const m = Math.floor(s / 60);
  const r = Math.round(s % 60);
  if (m < 60) return r ? `${m}m ${r}s` : `${m}m`;
  const h = Math.floor(m / 60);
  return `${h}h ${m % 60}m`;
}

function fmtUsd(v) {
  if (v == null) return '—';
  if (v === 0) return '$0';
  if (v < 0.01) return `$${v.toFixed(4)}`;
  if (v < 10) return `$${v.toFixed(2)}`;
  return `$${Math.round(v)}`;
}

function pct(n, d) {
  if (!d) return '—';
  return `${Math.round((n / d) * 100)}%`;
}

function fmtDay(ts) {
  if (!ts) return '—';
  return String(ts).slice(0, 10);
}

// --- folding ------------------------------------------------------------------------------------

// Card rows carry the finalize timestamp; a card's interval is [ts - wall_secs, ts]. That is the
// only start signal the ledger has (spec 08 explicitly does not record queue-wait).
function endMs(card) {
  const t = Date.parse(card.ts);
  return Number.isFinite(t) ? t : null;
}

function startMs(card) {
  const e = endMs(card);
  const w = num(card.wall_secs);
  return e == null ? null : e - (w || 0) * 1000;
}

// Peak concurrency by sweep line over [start,end] — the honest answer to "how many workers were
// actually in flight", which no single ledger field records (fanout is on exactly one run-meta row).
function peakConcurrency(cards) {
  const events = [];
  for (const c of cards) {
    const s = startMs(c);
    const e = endMs(c);
    if (s == null || e == null) continue;
    events.push([s, 1], [e, -1]);
  }
  if (!events.length) return null;
  events.sort((a, b) => a[0] - b[0] || a[1] - b[1]); // ends before starts at the same instant
  let cur = 0;
  let peak = 0;
  for (const [, d] of events) {
    cur += d;
    if (cur > peak) peak = cur;
  }
  return peak;
}

// `canon` is this lane's record from canonicalFold — trust and $/verified-done are read from it,
// never recomputed here (see the header). Speed/token columns stay local: they are per ATTEMPT and
// nobody disputes them.
function foldLane(cards, canon) {
  const walls = cards.map((c) => num(c.wall_secs)).filter((v) => v != null);
  const outs = cards.map((c) => num(c.tokens_out)).filter((v) => v != null);
  return {
    attempts: canon.attempts,
    cards: canon.cards,
    retries: canon.attempts - canon.cards,
    done: cards.filter((c) => c.outcome === 'done').length,
    timeout: cards.filter((c) => c.outcome === 'timeout').length,
    errored: cards.filter((c) => c.is_error === true).length,
    wallMedian: median(walls),
    wallP90: quantile(walls, 0.9),
    wallMax: walls.length ? Math.max(...walls) : null,
    wallSum: sum(walls),
    // costPriced is the denominator that keeps codex honest: it emits no cost_usd at all, so
    // "total cost" over its 56 cards is not $0 — it is unpriced.
    costTotal: canon.cost_total,
    costPriced: canon.cost_priced,
    costPerCard: canon.cost_priced ? canon.cost_total / canon.cost_priced : null,
    costPerVerified: canon.cost_per_verified_done,
    tokensIn: sum(cards.map((c) => num(c.tokens_in) || 0)),
    tokensOut: sum(cards.map((c) => num(c.tokens_out) || 0)),
    tokensCached: sum(cards.map((c) => num(c.tokens_cached) || 0)),
    tokensReasoning: sum(cards.map((c) => num(c.tokens_reasoning) || 0)),
    tokensOutMedian: median(outs),
    judged: canon.verified_done + canon.false_done,
    verifiedTrue: canon.verified_done,
    verifiedFalse: canon.false_done,
    inconclusive: canon.inconclusive,
  };
}

function fold(payload) {
  const cards = payload.cards || [];
  const verdicts = payload.verdicts || [];
  const reviews = payload.reviews || [];
  const runMeta = payload.run_meta || [];
  const runReviews = payload.run_reviews || [];

  // The card model (attempts collapsed on run + id), the verdict join and every trust/cost-per-
  // verified-done number come from the shared canonical fold — see tests/fixtures/verdict-fold/.
  const canon = canonicalFold([...cards, ...verdicts]);
  const { cardList, verdictOf, laneNames } = canon;

  const lanes = laneNames.map((lane) => ({
    lane,
    ...foldLane(cards.filter((c) => (c.served_lane == null ? '?' : c.served_lane) === lane), canon.lanes[lane]),
  }));

  const runNames = [...new Set(cards.map((c) => c.run).filter(Boolean))];
  const runs = runNames.map((run) => {
    const rc = cards.filter((c) => c.run === run);
    const starts = rc.map(startMs).filter((v) => v != null);
    const ends = rc.map(endMs).filter((v) => v != null);
    const spanSec = starts.length && ends.length
      ? Math.max(1, Math.round((Math.max(...ends) - Math.min(...starts)) / 1000))
      : null;
    const wallSum = sum(rc.map((c) => num(c.wall_secs) || 0));
    const laneMix = {};
    for (const c of rc) laneMix[c.served_lane] = (laneMix[c.served_lane] || 0) + 1;
    const rCards = cardList.filter((c) => c.run === run);
    const judged = rCards.filter((c) => c.judged); // canonical: a non-boolean verdict is not a judgment
    return {
      run,
      firstTs: rc.map((c) => c.ts).sort()[0] || null,
      attempts: rc.length,
      cards: rCards.length,
      laneMix,
      spanSec,
      wallSum,
      // Effective parallelism: work performed ÷ wall-clock elapsed. Not a speedup claim against a
      // human baseline — just how much of the fan-out actually overlapped.
      parallelism: spanSec ? wallSum / spanSec : null,
      peak: peakConcurrency(rc),
      costTotal: rc.some((c) => num(c.cost_usd) != null)
        ? sum(rc.map((c) => num(c.cost_usd) || 0))
        : null,
      costPriced: rc.filter((c) => num(c.cost_usd) != null).length,
      timeout: rc.filter((c) => c.outcome === 'timeout').length,
      judged: judged.length,
      verifiedFalse: judged.filter((c) => c.verified === false).length,
      reviews: reviews.filter((r) => r.run === run && r.lane),
      overallReview: reviews.find((r) => r.run === run && !r.lane) || null,
      meta: runMeta.filter((m) => m.run === run),
      runReview: runReviews.find((r) => r.run === run) || null,
    };
  }).sort((a, b) => String(a.firstTs).localeCompare(String(b.firstTs)));

  const walls = cards.map((c) => num(c.wall_secs)).filter((v) => v != null);
  const priced = cards.map((c) => num(c.cost_usd)).filter((v) => v != null);
  const judgedAll = cardList.filter((c) => c.judged);

  return {
    lanes,
    runs,
    cards,
    cardList,
    verdicts,
    verdictOf,
    totals: {
      runs: runs.length,
      attempts: cards.length,
      cards: cardList.length,
      retried: cardList.filter((c) => c.attempts.length > 1).length,
      lanes: laneNames.length,
      wallSum: sum(walls),
      wallMedian: median(walls),
      costTotal: priced.length ? sum(priced) : null,
      costPriced: priced.length,
      costUnpriced: cards.length - priced.length,
      done: cards.filter((c) => c.outcome === 'done').length,
      timeout: cards.filter((c) => c.outcome === 'timeout').length,
      judged: judgedAll.length,
      verifiedTrue: judgedAll.filter((c) => c.verified === true).length,
      verifiedFalse: judgedAll.filter((c) => c.verified === false).length,
      inconclusive: cardList.filter((c) => c.verdict && !c.judged).length,
      tokensOut: sum(cards.map((c) => num(c.tokens_out) || 0)),
      firstDay: fmtDay(cards.map((c) => c.ts).sort()[0]),
      lastDay: fmtDay(cards.map((c) => c.ts).sort().slice(-1)[0]),
    },
  };
}

// --- shared render atoms -------------------------------------------------------------------------

// Review rows name their lane as "glm:glm-5.2"; the qa-3x run names agents ("sonnet"/"haiku") that
// are not swarm lanes at all. Resolve to the bare lane before asking format.js for a colour — an
// unknown name falls through to laneColor()'s grey, never to a semantic red/amber that would read
// as an error state.
function laneChip(lane) {
  const bare = String(lane == null ? '' : lane).split(':')[0];
  return `<span class="sw-lane" style="--lane:${esc(laneColor(bare))}">`
    + `<b>${esc(laneLetter(bare))}</b>${esc(bare)}</span>`;
}

// ★ marks the best cell in a column. Never marked when only one lane qualifies (a winner of one is
// not a winner) — the caller passes the qualifying set.
function best(isBest, n) {
  return isBest && n > 1 ? `<span class="sw-best" title="best of ${n} lanes">★</span>` : '';
}

// A bar whose fill is a share of `max`. `title` carries the exact value for hover — the bar is the
// shape, the number beside it is the truth.
function bar(value, max, color) {
  const wPct = max && value != null ? Math.max(1.5, (value / max) * 100) : 0;
  return `<span class="sw-bar"><i style="width:${wPct.toFixed(1)}%;--c:${esc(color)}"></i></span>`;
}

function statCell(label, value, sub) {
  return `<div class="sw-stat">
    <div class="sw-stat-v">${value}</div>
    <div class="sw-stat-l">${esc(label)}</div>
    ${sub ? `<div class="sw-stat-s">${sub}</div>` : ''}
  </div>`;
}

function emptyNote(text) {
  return `<div class="sw-empty">${esc(text)}</div>`;
}

// --- sub-tab bodies --------------------------------------------------------------------------------

function renderTotal() {
  const t = agg.totals;
  const maxWall = Math.max(...agg.lanes.map((l) => l.wallSum), 1);

  const unjudged = t.cards - t.judged - t.inconclusive;
  const stats = [
    statCell('runs', String(t.runs), esc(`${t.firstDay} → ${t.lastDay}`)),
    statCell('cards', String(t.cards), `${t.attempts} attempts · ${t.retried} retried`),
    statCell('lanes', String(t.lanes), agg.lanes.map((l) => laneChip(l.lane)).join('')),
    statCell('work performed', fmtSecs(t.wallSum), `median attempt ${fmtSecs(t.wallMedian)}`),
    statCell(
      'metered spend',
      fmtUsd(t.costTotal),
      `${t.costPriced}/${t.attempts} attempts priced`,
    ),
    statCell(
      'verified',
      t.judged ? `${t.verifiedTrue}/${t.judged}` : '—',
      t.judged
        ? `${t.verifiedFalse} refuted · ${unjudged} unjudged${t.inconclusive ? ` · ${t.inconclusive} inconclusive` : ''}`
        : 'nothing judged yet',
    ),
  ].join('');

  // Best-in-column, with the sample-size guard: a verified ratio only competes once at least 3
  // cards on that lane were actually judged. MIN_JUDGED is the whole reason a 10/10 over two cards
  // never outranks a 30/34.
  const MIN_JUDGED = 3;
  const withMedian = agg.lanes.filter((l) => l.wallMedian != null);
  const withP90 = agg.lanes.filter((l) => l.wallP90 != null);
  const withCost = agg.lanes.filter((l) => l.costPriced > 0);
  const withJudged = agg.lanes.filter((l) => l.judged >= MIN_JUDGED);
  const minBy = (arr, f) => (arr.length ? arr.reduce((a, b) => (f(b) < f(a) ? b : a)) : null);
  const maxBy = (arr, f) => (arr.length ? arr.reduce((a, b) => (f(b) > f(a) ? b : a)) : null);
  const bestMedian = minBy(withMedian, (l) => l.wallMedian);
  const bestP90 = minBy(withP90, (l) => l.wallP90);
  const bestCost = minBy(withCost, (l) => l.costPerCard);
  const bestTrust = maxBy(withJudged, (l) => l.verifiedTrue / l.judged);

  const rows = agg.lanes
    .slice()
    .sort((a, b) => (a.wallMedian ?? 1e9) - (b.wallMedian ?? 1e9))
    .map((l) => `
      <tr>
        <td>${laneChip(l.lane)}</td>
        <td class="n">${l.attempts}</td>
        <td class="n">${fmtSecs(l.wallMedian)}${best(l === bestMedian, withMedian.length)}</td>
        <td class="n dim">${fmtSecs(l.wallP90)}${best(l === bestP90, withP90.length)}</td>
        <td class="w"><span class="sw-cell">${bar(l.wallSum, maxWall, laneColor(l.lane))}<span class="n">${fmtSecs(l.wallSum)}</span></span></td>
        <td class="n">${l.costPriced ? fmtUsd(l.costPerCard) + best(l === bestCost, withCost.length) : '<span class="dim">not billed</span>'}</td>
        <td class="n${l.judged && l.judged < MIN_JUDGED ? ' dim' : ''}"
            title="${l.judged} of ${l.cards} cards delivered by this lane were judged">${
          l.judged ? `${l.verifiedTrue}/${l.judged}${best(l === bestTrust, withJudged.length)}` : '<span class="dim">unjudged</span>'
        }</td>
        <td class="n">${l.verifiedFalse ? `<span class="bad">${l.verifiedFalse}</span>` : '<span class="dim">0</span>'}</td>
      </tr>`).join('');

  // The 3-second answer, built from the SAME folded values the table renders — one computation
  // path, so the sentence can never drift from the numbers beneath it.
  const clause = (label, l, val) => (l
    ? `${label} <b style="color:${esc(laneColor(l.lane))}">${esc(l.lane)}</b> ${val}`
    : null);
  const worstTrust = withJudged.length > 1
    ? withJudged.reduce((a, b) => (b.verifiedFalse / b.judged > a.verifiedFalse / a.judged ? b : a))
    : null;
  const verdict = agg.lanes.length < 2 ? '' : `<div class="sw-verdict">${[
    clause('fastest', bestMedian, fmtSecs(bestMedian && bestMedian.wallMedian)),
    clause('steadiest tail', bestP90, fmtSecs(bestP90 && bestP90.wallP90)),
    clause('cheapest metered', bestCost, fmtUsd(bestCost && bestCost.costPerCard)),
    worstTrust && worstTrust.verifiedFalse
      ? clause('most refuted', worstTrust, `<span class="bad">${worstTrust.verifiedFalse} of ${worstTrust.judged} judged</span>`)
      : null,
  ].filter(Boolean).join('<span class="dim"> · </span>')}</div>`;

  return `
    <div class="sw-stats">${stats}</div>
    ${verdict}
    <div class="sw-panel">
      <div class="sw-panel-h">lane scoreboard<span class="dim"> — sorted by median attempt wall-clock; verified counts CARDS whose final attempt ran here</span></div>
      <table class="sw-table">
        <thead><tr>
          <th>lane</th><th class="n">attempts</th><th class="n">median</th><th class="n">p90</th>
          <th class="w">work performed</th><th class="n">$/attempt</th><th class="n">verified</th><th class="n">refuted</th>
        </tr></thead>
        <tbody>${rows}</tbody>
      </table>
    </div>`;
}

function renderSpeed() {
  const maxP90 = Math.max(...agg.lanes.map((l) => l.wallP90 ?? 0), 1);
  const rows = agg.lanes
    .slice()
    .sort((a, b) => (a.wallMedian ?? 1e9) - (b.wallMedian ?? 1e9))
    .map((l) => `
      <tr>
        <td>${laneChip(l.lane)}</td>
        <td class="n">${l.attempts}</td>
        <td class="w"><span class="sw-cell">${bar(l.wallMedian, maxP90, laneColor(l.lane))}<span class="n">${fmtSecs(l.wallMedian)}</span></span></td>
        <td class="w"><span class="sw-cell">${bar(l.wallP90, maxP90, laneColor(l.lane))}<span class="n">${fmtSecs(l.wallP90)}</span></span></td>
        <td class="n dim">${fmtSecs(l.wallMax)}</td>
      </tr>`).join('');

  // The distribution strip: every card as a dot on a shared log-ish scale, per lane. The long tail
  // is the point — averages hide the 900s card that owns the critical path.
  const allWalls = agg.cards.map((c) => num(c.wall_secs)).filter((v) => v != null && v > 0);
  const maxW = allWalls.length ? Math.max(...allWalls) : 1;
  const span = Math.log10(Math.max(10, maxW));
  const posOf = (w) => (Math.log10(Math.max(1, w)) / span) * 100;

  // Decade ticks at their TRUE offsets. An evenly-spaced axis under a log scale would put the "10s"
  // label somewhere 10s does not live — the one lie a distribution chart must never tell.
  const decades = [];
  for (let d = 0; Math.pow(10, d) <= maxW; d += 1) decades.push(Math.pow(10, d));
  const ticks = decades
    .map((d) => `<span style="left:${posOf(d).toFixed(2)}%">${esc(fmtSecs(d))}</span>`)
    .concat([`<span style="left:100%">${esc(fmtSecs(maxW))}</span>`])
    .join('');
  const gridMarks = decades
    .map((d) => `<i class="sw-grid" style="left:${posOf(d).toFixed(2)}%"></i>`)
    .join('');
  const strips = agg.lanes.map((l) => {
    const dots = agg.cards
      .filter((c) => c.served_lane === l.lane && num(c.wall_secs) != null)
      .map((c) => {
        const w = num(c.wall_secs) || 0;
        const bad = c.outcome === 'timeout';
        // Route through normVerdict — v0 rows encode verified as the string "pass"/"fail", and a
        // raw `.verified === false` check misses them (canon rule 11).
        const v = agg.verdictOf(c);
        const suspicious = v != null && normVerdict(v.verified) === false;
        const cls = bad ? ' is-timeout' : suspicious ? ' is-refuted' : '';
        const pos = `left:${posOf(w).toFixed(2)}%;--c:${esc(laneColor(l.lane))}`;
        const label = `${esc(c.id)} · ${esc(c.run)} · ${fmtSecs(w)}${bad ? ' · TIMEOUT' : ''}${suspicious ? ' · refuted' : ''}`;
        // Only the refuted dots are interactive — they are the ones with somewhere to go.
        if (suspicious) {
          return `<button type="button" class="sw-dot is-refuted" style="${pos}"
            data-key="${esc(c.run)}--${esc(c.id)}" title="${label} — open its reason"
            aria-label="refuted card ${esc(c.id)} in ${esc(c.run)} — open its reason"></button>`;
        }
        return `<i class="sw-dot${cls}" style="${pos}" title="${label}"></i>`;
      }).join('');
    return `<div class="sw-strip-row">
      <div class="sw-strip-l">${laneChip(l.lane)}</div>
      <div class="sw-strip">${gridMarks}${dots}</div>
    </div>`;
  }).join('');

  const slowest = agg.cards
    .filter((c) => num(c.wall_secs) != null)
    .sort((a, b) => b.wall_secs - a.wall_secs)
    .slice(0, 8)
    .map((c) => `<tr>
      <td class="mono">${esc(c.id)}</td>
      <td>${laneChip(c.served_lane)}</td>
      <td class="dim">${esc(c.run)}</td>
      <td class="n">${fmtSecs(c.wall_secs)}</td>
      <td class="n ${c.outcome === 'timeout' ? 'bad' : 'dim'}">${esc(c.outcome || '—')}</td>
    </tr>`).join('');

  return `
    <div class="sw-panel">
      <div class="sw-panel-h">wall-clock per card<span class="dim"> — median vs p90 (nearest-rank, real observations)</span></div>
      <table class="sw-table">
        <thead><tr><th>lane</th><th class="n">attempts</th><th class="w">median</th><th class="w">p90</th><th class="n">slowest</th></tr></thead>
        <tbody>${rows}</tbody>
      </table>
    </div>
    <div class="sw-panel">
      <div class="sw-panel-h">distribution<span class="dim"> — one dot per attempt, log scale; red = timeout, hollow = refuted</span></div>
      <div class="sw-strips">${strips}</div>
      <div class="sw-axis">${ticks}</div>
    </div>
    <div class="sw-panel">
      <div class="sw-panel-h">critical path<span class="dim"> — the 8 slowest attempts ever recorded</span></div>
      <table class="sw-table">
        <thead><tr><th>card</th><th>lane</th><th>run</th><th class="n">wall</th><th class="n">outcome</th></tr></thead>
        <tbody>${slowest}</tbody>
      </table>
    </div>`;
}

function renderCost() {
  const t = agg.totals;
  const maxCost = Math.max(...agg.lanes.map((l) => l.costTotal ?? 0), 0.0001);
  const rows = agg.lanes
    .slice()
    .sort((a, b) => (b.costTotal ?? -1) - (a.costTotal ?? -1))
    .map((l) => `
      <tr>
        <td>${laneChip(l.lane)}</td>
        <td class="n">${l.attempts}</td>
        <td class="n">${l.costPriced ? `${l.costPriced}/${l.attempts}` : '<span class="dim">0/' + l.attempts + '</span>'}</td>
        <td class="w"><span class="sw-cell">${l.costPriced ? bar(l.costTotal, maxCost, laneColor(l.lane)) + `<span class="n">${fmtUsd(l.costTotal)}</span>` : '<span class="dim">not billed — subscription lane</span>'}</span></td>
        <td class="n">${l.costPriced ? fmtUsd(l.costPerCard) : '—'}</td>
        <td class="n">${l.costPerVerified != null ? fmtUsd(l.costPerVerified) : '<span class="dim">—</span>'}</td>
      </tr>`).join('');

  const runRows = agg.runs
    .filter((r) => r.costTotal != null)
    .sort((a, b) => b.costTotal - a.costTotal)
    .map((r) => `<tr>
      <td class="mono">${esc(r.run)}</td>
      <td class="n">${r.attempts}</td>
      <td class="n">${fmtUsd(r.costTotal)}</td>
      <td class="n dim">${r.costPriced}/${r.attempts} priced</td>
    </tr>`).join('');

  return `
    <div class="sw-stats">
      ${statCell('metered spend', fmtUsd(t.costTotal), `across ${t.costPriced} priced cards`)}
      ${statCell('unpriced cards', String(t.costUnpriced), 'subscription lanes emit no cost')}
      ${statCell('$ per priced card', t.costPriced ? fmtUsd(t.costTotal / t.costPriced) : '—', 'metered lanes only')}
    </div>
    <div class="sw-panel">
      <div class="sw-panel-h">spend by lane<span class="dim"> — "not billed" is not $0: codex bills to a ChatGPT subscription and emits no cost field</span></div>
      <table class="sw-table">
        <thead><tr><th>lane</th><th class="n">attempts</th><th class="n">priced</th><th class="w">total</th><th class="n">$/attempt</th><th class="n">$/verified card</th></tr></thead>
        <tbody>${rows}</tbody>
      </table>
    </div>
    <div class="sw-panel">
      <div class="sw-panel-h">spend by run</div>
      ${runRows
        ? `<table class="sw-table"><thead><tr><th>run</th><th class="n">attempts</th><th class="n">metered</th><th class="n">coverage</th></tr></thead><tbody>${runRows}</tbody></table>`
        : emptyNote('no run has a priced card yet')}
    </div>`;
}

function renderTrust() {
  const t = agg.totals;
  const rows = agg.lanes
    .slice()
    .sort((a, b) => b.verifiedFalse - a.verifiedFalse)
    .map((l) => {
      const judged = l.judged;
      const truePct = judged ? (l.verifiedTrue / judged) * 100 : 0;
      return `<tr>
        <td>${laneChip(l.lane)}</td>
        <td class="n">${l.done}</td>
        <td class="n">${judged || '<span class="dim">0</span>'}</td>
        <td class="w"><span class="sw-cell">${judged
          ? `<span class="sw-split"><i class="ok" style="width:${truePct.toFixed(1)}%"></i><i class="bad" style="width:${(100 - truePct).toFixed(1)}%"></i></span><span class="n">${pct(l.verifiedTrue, judged)}</span>`
          : '<span class="dim">unjudged — no verify wave ran on this lane</span>'}</span></td>
        <td class="n">${l.verifiedFalse ? `<span class="bad">${l.verifiedFalse}</span>` : '<span class="dim">0</span>'}</td>
        <td class="n">${l.timeout ? `<span class="warn">${l.timeout}</span>` : '<span class="dim">0</span>'}</td>
        <td class="n">${l.errored ? `<span class="warn">${l.errored}</span>` : '<span class="dim">0</span>'}</td>
        <td class="n">${l.inconclusive ? `<span class="dim">${l.inconclusive}</span>` : '<span class="dim">0</span>'}</td>
      </tr>`;
    }).join('');


  // backlog-14: the same card finalizing "done" on two different lanes means a rescue attempt and
  // its original BOTH wrote a terminal row. fold() collapses attempts into one card, so without
  // this panel the double-write is invisible.
  const crossLane = agg.cardList.filter((c) => {
    const doneLanes = new Set(
      c.attempts.filter((a) => a.outcome === 'done').map((a) => a.served_lane),
    );
    return doneLanes.size > 1;
  });
  const dedupRows = crossLane.map((c) => `<tr>
    <td class="mono">${esc(c.id)}</td>
    <td class="dim">${esc(c.run)}</td>
    <td>${c.attempts.filter((a) => a.outcome === 'done').map((a) => laneChip(a.served_lane)).join(' ')}</td>
    <td class="n dim">${c.attempts.map((a) => fmtSecs(num(a.wall_secs))).join(' · ')}</td>
  </tr>`).join('');

  // The canonical (last-verdict) state per card, not a raw row filter — a card that was refuted
  // and later corrected true must not still show up here (rule 4: last verdict wins).
  const refuted = agg.cardList
    .filter((c) => c.judged && c.verified === false)
    .map((c) => `<div class="sw-refute" id="fx-${esc(c.run)}--${esc(c.id)}">
      <div class="sw-refute-h">
        <span class="mono">${esc(c.id)}</span>
        <span class="dim">${esc(c.run)}</span>
        ${c.verdict.lane ? laneChip(c.verdict.lane) : ''}
      </div>
      <div class="sw-refute-r">${esc(c.verdict.reason || 'no reason recorded')}</div>
    </div>`).join('');

  return `
    <div class="sw-stats">
      ${statCell('cards judged', t.judged ? `${t.judged}/${t.cards}` : '—', `a verify wave reached this many${t.inconclusive ? ` · ${t.inconclusive} inconclusive` : ''}`)}
      ${statCell('held up', t.judged ? `${t.verifiedTrue}` : '—', t.judged ? pct(t.verifiedTrue, t.judged) + ' of judged' : '')}
      ${statCell('refuted', String(t.verifiedFalse), t.judged ? pct(t.verifiedFalse, t.judged) + ' of judged' : '')}
      ${statCell('retried cards', String(t.retried), `${t.attempts - t.cards} extra attempts spent`)}
      ${statCell('timeouts', String(t.timeout), 'watchdog killed the attempt')}
    </div>
    <div class="sw-panel">
      <div class="sw-panel-h">claimed done vs verified<span class="dim"> — an unjudged card is unjudged, never "verified" (a lane with no verify wave shows no score)</span></div>
      <table class="sw-table">
        <thead><tr><th>lane</th><th class="n">done attempts</th><th class="n">cards judged</th><th class="w">held up</th><th class="n">refuted</th><th class="n">timeout</th><th class="n">errored</th><th class="n">inconclusive</th></tr></thead>
        <tbody>${rows}</tbody>
      </table>
    </div>
    <div class="sw-panel">
      <div class="sw-panel-h">refutation wall<span class="dim"> — every card a judge caught lying, with the reason</span></div>
      ${refuted ? `<div class="sw-refutes">${refuted}</div>` : emptyNote('no refutations recorded')}
    </div>
    <div class="sw-panel">
      <div class="sw-panel-h">dedup watch<span class="dim"> — the same card finalized "done" on two lanes; a rescue and its original both wrote a row (backlog-14)</span></div>
      ${dedupRows
        ? `<table class="sw-table"><thead><tr><th>card</th><th>run</th><th>lanes that finalized done</th><th class="n">attempt walls</th></tr></thead><tbody>${dedupRows}</tbody></table>`
        : emptyNote('no card has finalized on two lanes')}
    </div>`;
}

function renderTokens() {
  const maxTot = Math.max(...agg.lanes.map((l) => l.tokensIn + l.tokensOut + l.tokensCached), 1);
  const rows = agg.lanes
    .slice()
    .sort((a, b) => b.tokensOut - a.tokensOut)
    .map((l) => {
      const tot = l.tokensIn + l.tokensOut + l.tokensCached;
      const w = (v) => ((v / Math.max(1, tot)) * 100).toFixed(1);
      return `<tr>
        <td>${laneChip(l.lane)}</td>
        <td class="n">${l.attempts}</td>
        <td class="w"><span class="sw-cell">
          <span class="sw-stack" style="width:${((tot / maxTot) * 100).toFixed(1)}%">
            <i class="t-cached" style="width:${w(l.tokensCached)}%" title="cached ${fmtTok(l.tokensCached)}"></i>
            <i class="t-in" style="width:${w(l.tokensIn)}%" title="input ${fmtTok(l.tokensIn)}"></i>
            <i class="t-out" style="width:${w(l.tokensOut)}%" title="output ${fmtTok(l.tokensOut)}"></i>
          </span>
        </span></td>
        <td class="n">${fmtTok(l.tokensOut)}</td>
        <td class="n dim">${fmtTok(l.tokensIn)}</td>
        <td class="n dim">${fmtTok(l.tokensCached)}</td>
        <td class="n dim">${l.tokensReasoning ? fmtTok(l.tokensReasoning) : '—'}</td>
        <td class="n">${l.tokensOutMedian != null ? fmtTok(l.tokensOutMedian) : '—'}</td>
      </tr>`;
    }).join('');

  return `
    <div class="sw-panel">
      <div class="sw-panel-h">tokens by lane
        <span class="dim"> — bar is total volume; segments are </span>
        <span class="k-cached">cached</span><span class="dim"> / </span><span class="k-in">input</span><span class="dim"> / </span><span class="k-out">output</span>
      </div>
      <table class="sw-table">
        <thead><tr><th>lane</th><th class="n">attempts</th><th class="w">volume</th><th class="n">output</th><th class="n">input</th><th class="n">cached</th><th class="n">reasoning</th><th class="n">median out</th></tr></thead>
        <tbody>${rows}</tbody>
      </table>
      <div class="sw-note">Output tokens are the honest work signal: a near-zero output row with zero
        tool calls is the false-done signature the refutation wall records.</div>
    </div>`;
}

// One trend chart: a tick per run, oldest to newest. A run that never recorded the metric renders a
// dim 2px gap-tick on the same baseline as the real bars — a measured zero and a missing measurement
// must never look alike (FR-14 made literal).
function trendChart(title, runs, valueOf, fmt, color) {
  const vals = runs.map((r) => ({ run: r.run, v: valueOf(r) }));
  const plotted = vals.filter((x) => x.v != null);
  const peak = plotted.length ? Math.max(...plotted.map((x) => x.v)) : 0;
  const ticks = vals.map(({ run, v }) => {
    if (v == null) {
      return `<button type="button" class="sw-tick sw-tick-gap" data-run="${esc(run)}"
        title="${esc(run)} · not recorded" aria-label="${esc(run)}: not recorded"></button>`;
    }
    // peak 0 with real zeros: every bar is a floor-height bar, never a gap
    const h = peak > 0 ? Math.max(2, (v / peak) * 100) : 2;
    return `<button type="button" class="sw-tick" data-run="${esc(run)}"
      style="height:${h.toFixed(1)}%;--c:${esc(color)}"
      title="${esc(run)} · ${esc(fmt(v))}" aria-label="${esc(run)}: ${esc(fmt(v))}"></button>`;
  }).join('');
  const missing = vals.length - plotted.length;
  return `<div class="sw-trend">
    <div class="sw-trend-t">${esc(title)}</div>
    <div class="sw-trend-bars">${ticks}</div>
    <div class="sw-trend-c">${plotted.length} of ${vals.length} runs recorded this${
      missing ? ` · ${missing} dim = not recorded` : ''
    }</div>
  </div>`;
}

function renderRuns() {
  const maxPar = Math.max(...agg.runs.map((r) => r.parallelism ?? 0), 1);
  const rows = agg.runs.map((r) => {
    const mix = Object.entries(r.laneMix)
      .sort((a, b) => b[1] - a[1])
      .map(([lane, n]) => `<span class="sw-mix" style="--lane:${esc(laneColor(lane))}" title="${esc(lane)} ${n}">${esc(laneLetter(lane))}${n}</span>`)
      .join('');
    const rr = r.runReview;
    return `<tr data-run="${esc(r.run)}">
      <td class="mono">${esc(r.run)}</td>
      <td class="dim">${esc(fmtDay(r.firstTs))}</td>
      <td class="n">${r.cards}${r.attempts > r.cards ? `<span class="dim"> +${r.attempts - r.cards}r</span>` : ''}</td>
      <td>${mix}</td>
      <td class="n">${r.peak != null ? r.peak : '—'}</td>
      <td class="n">${fmtSecs(r.spanSec)}</td>
      <td class="w"><span class="sw-cell">${bar(r.parallelism, maxPar, 'var(--accent)')}<span class="n">${r.parallelism ? r.parallelism.toFixed(2) + '×' : '—'}</span></span></td>
      <td class="n">${r.costTotal != null ? fmtUsd(r.costTotal) : '<span class="dim">—</span>'}</td>
      <td class="n">${r.verifiedFalse ? `<span class="bad">${r.verifiedFalse}</span>` : '<span class="dim">0</span>'}</td>
      <td class="n">${r.timeout ? `<span class="warn">${r.timeout}</span>` : '<span class="dim">0</span>'}</td>
      <td class="n">${rr && rr.speedup ? `${rr.speedup}×` : '<span class="dim">no review</span>'}</td>
    </tr>`;
  }).join('');

  const reviewed = agg.runs.filter((r) => r.reviews.length || r.overallReview || r.runReview);
  const cards = reviewed.map((r) => {
    const lanes = r.reviews.map((rv) => `<div class="sw-rev-lane">
      <div class="sw-rev-head">${laneChip(rv.lane)}<span class="sw-score">${'●'.repeat(rv.score || 0)}<span class="dim">${'○'.repeat(Math.max(0, 5 - (rv.score || 0)))}</span></span></div>
      ${(rv.tags || []).map((t) => `<span class="sw-tag">${esc(t)}</span>`).join('')}
      <div class="sw-rev-note">${esc(rv.note || '')}</div>
    </div>`).join('');
    return `<div class="sw-runcard">
      <div class="sw-runcard-h"><span class="mono">${esc(r.run)}</span><span class="dim">${esc(fmtDay(r.firstTs))} · ${r.cards} cards</span></div>
      ${r.overallReview ? `<div class="sw-rev-overall">${esc(r.overallReview.note || '')}</div>` : ''}
      ${lanes || emptyNote('no per-lane review recorded')}
    </div>`;
  }).join('');

  const trends = `
    <div class="sw-panel">
      <div class="sw-panel-h">trend<span class="dim"> — oldest → newest; a dim tick means the run never recorded that metric</span></div>
      <div class="sw-trends">
        ${trendChart('REFUTED · % of judged', agg.runs,
          (r) => (r.judged ? (r.verifiedFalse / r.judged) * 100 : null),
          (v) => `${Math.round(v)}% refuted`, 'var(--red)')}
        ${trendChart('METERED SPEND · $', agg.runs, (r) => r.costTotal, fmtUsd, 'var(--accent)')}
        ${trendChart('PARALLELISM · ×', agg.runs, (r) => r.parallelism,
          (v) => `${v.toFixed(2)}×`, 'var(--blue)')}
      </div>
    </div>`;

  return `
    ${trends}
    <div class="sw-panel">
      <div class="sw-panel-h">run over run
        <span class="dim"> — parallelism = work performed ÷ wall-clock elapsed; peak = concurrent workers by sweep line</span>
      </div>
      <table class="sw-table">
        <thead><tr>
          <th>run</th><th>day</th><th class="n">cards</th><th>lanes</th><th class="n">peak</th>
          <th class="n">span</th><th class="w">parallelism</th><th class="n">metered</th>
          <th class="n">refuted</th><th class="n">timeout</th><th class="n">reviewed speedup</th>
        </tr></thead>
        <tbody>${rows}</tbody>
      </table>
    </div>
    <div class="sw-panel">
      <div class="sw-panel-h">operator reviews<span class="dim"> — the subjective column, beside the numbers and never averaged into them</span></div>
      ${cards ? `<div class="sw-runcards">${cards}</div>` : emptyNote('no run has a review row yet')}
    </div>`;
}

const BODY = {
  total: renderTotal,
  speed: renderSpeed,
  cost: renderCost,
  trust: renderTrust,
  tokens: renderTokens,
  runs: renderRuns,
};

// --- shell -----------------------------------------------------------------------------------------

function header() {
  const meta = agg
    ? `<span class="dim">${agg.totals.cards} cards · ${agg.totals.runs} runs · ${agg.totals.lanes} lanes</span>`
    : '';
  const stamp = data && data.mtime
    ? `<span class="dim">ledger ${esc(String(data.mtime).replace('T', ' ').slice(0, 16))}Z</span>`
    : '';
  return `<div class="sw-hdr">
    <div class="sw-title">SPEEDWARS<span class="sw-sub">run evidence · docs/ops/speedwars.jsonl · history, not live</span></div>
    <div class="sw-hdr-r">${meta}${stamp}
      <button type="button" class="btn-ctl" id="sw-refresh" title="the ledger changes once per run, not per second" ${loading ? 'disabled' : ''}>${loading ? '· loading' : '⟳ refresh'}</button>
    </div>
  </div>`;
}

function tabBar() {
  const btns = TABS.map((t) => `<button type="button" role="tab" class="sw-tab${t.id === tab ? ' active' : ''}"
      data-tab="${t.id}" aria-selected="${t.id === tab}" title="${esc(t.hint)}">${esc(t.label)}</button>`).join('');
  return `<div class="sw-tabs" role="tablist" aria-label="Speedwars dimensions">${btns}</div>`;
}

function body() {
  if (error) {
    return `<div class="sw-body">${emptyNote(`could not read the ledger — ${error}`)}</div>`;
  }
  if (loading && !agg) return `<div class="sw-body">${emptyNote('reading docs/ops/speedwars.jsonl …')}</div>`;
  if (!agg) return `<div class="sw-body">${emptyNote('no ledger loaded')}</div>`;
  if (!agg.totals.cards) {
    return `<div class="sw-body">${emptyNote(
      data && data.available === false
        ? 'no ledger yet — docs/ops/speedwars.jsonl appears after the first swarm run'
        : 'the ledger has no card rows yet',
    )}</div>`;
  }
  return `<div class="sw-body" role="tabpanel">${(BODY[tab] || renderTotal)()}</div>`;
}

function paint() {
  if (!root) return;
  root.innerHTML = header() + tabBar() + body();
}

async function load() {
  if (loading) return;
  loading = true;
  error = null;
  paint();
  try {
    const res = await fetch('/api/speedwars', { cache: 'no-store' });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    data = await res.json();
    agg = fold(data);
    loaded = true;
  } catch (e) {
    error = (e && e.message) || 'fetch failed';
  } finally {
    loading = false;
    paint();
  }
}

// flash(el) — a transient highlight after a jump. Deliberately not persisted: a filter an operator
// could return to and mistake for the whole ledger is worse than no filter at all.
function flash(el) {
  if (!el) return;
  el.classList.add('is-flash');
  setTimeout(() => el.classList.remove('is-flash'), 1200);
}

function onClick(e) {
  const t = e.target.closest('.sw-tab');
  if (t) {
    tab = t.getAttribute('data-tab');
    saveJSON('unimatrix-sw-tab', { v: tab });
    paint();
    return;
  }
  if (e.target.closest('#sw-refresh')) {
    load();
    return;
  }

  const tick = e.target.closest('.sw-tick');
  if (tick) {
    const row = root.querySelector(`tr[data-run="${CSS.escape(tick.getAttribute('data-run'))}"]`);
    if (row) {
      row.scrollIntoView({ block: 'nearest' });
      flash(row);
    }
    return;
  }

  const dot = e.target.closest('.sw-dot.is-refuted');
  if (dot) {
    const key = dot.getAttribute('data-key');
    tab = 'trust';
    saveJSON('unimatrix-sw-tab', { v: tab });
    paint();
    // paint() replaced the DOM — resolve the target after it exists.
    requestAnimationFrame(() => {
      const card = root.querySelector(`#fx-${CSS.escape(key)}`);
      if (!card) return; // unmatched jump no-ops silently, never a dead scroll
      card.scrollIntoView({ block: 'center' });
      flash(card);
    });
  }
}

function init(rootEl) {
  root = rootEl;
  const saved = loadJSON('unimatrix-sw-tab', { v: 'total' });
  if (TABS.some((t) => t.id === saved.v)) tab = saved.v;
  if (!bound && root) {
    root.addEventListener('click', onClick);
    bound = true;
  }
  paint();
}

// render() is called by main.js on activation only (spec 09 FR-10) — the first call fetches, later
// ones just repaint. Refresh is an explicit operator action.
function render() {
  if (!loaded && !loading) {
    load();
    return;
  }
  paint();
}

export { init, render };
export default { init, render };
