/**
 * FLIGHTPATHS view — time × agents; silence is literally visible.
 *
 * Project: unimatrix — multi-model swarm orchestrator driven from Claude Code
 * Module:  site/cockpit/flight.js
 * Deps:    format.js (esc, fmtAge, fmtTime, LANES, STATE_RANK, loadJSON, saveJSON, ageSecOf,
 *          laneLetter, laneColor); data.js (store, ui, bus, select, ringArr)
 * Tested:  n/a
 *
 * Key responsibilities:
 * - Render ONLY inside #view-flight: header (sort / zoom / follow / legend), time axis + NOW,
 *   per-agent segment rows (seed + live-window policy), done toggle, 2 mini charts.
 * - Maintain per-agent span history (seed from /api/agents ages; live SSE extends exec; gap>60s
 *   → silent; lane change → red-dashed retry + new exec). Dots come from rec.dots (live-only).
 * - Persist ui.fpSort / ui.fpShowDone / ui.fpZoom via unimatrix-fp-* localStorage keys.
 *
 * Design constraints:
 * - Never touch DOM outside #view-flight. All actions via select()/ui + saveJSON.
 * - No fake data (FR-14): absent ages → no invented takeoff; done → 2% stub only; spent_usd
 *   unknown → client-integrated bars labeled "$ since page load"; budget line only when
 *   config.BUDGET_USD > 0.
 * - Pixel truth = design cockpit.dc.html flightpaths section; formulas from plan §5.3/§5.3b·6.
 */

import {
  esc, fmtAge, fmtTime, LANES, STATE_RANK, loadJSON, saveJSON, ageSecOf, laneLetter, laneColor,
} from './format.js';
import { store, ui, bus, select, ringArr } from './data.js';

// --- module state ----------------------------------------------------------------------------

let root = null;
let bound = false;

// Per-agent span bookkeeping (lives across re-renders; keyed by agent id).
// spans: [{start, end, kind, lane, open?}]  times in epoch-ms; open = still extending.
const spanBook = new Map();

// When follow-NOW is off, freeze the window end at the uncheck instant.
let frozenEndMs = null;

// Zoom cycle order (FR-21)
const ZOOM_PRESETS = [5, 20, 60];

// NOW sits at 86% of the track when the window end === now (plan §5.3).
const NOW_FRAC = 0.86;

// --- pure helpers ----------------------------------------------------------------------------

function hexA(h, a) {
  if (!h || h[0] !== '#' || (h.length !== 7 && h.length !== 4)) {
    return `rgba(147,168,156,${a})`;
  }
  let r, g, b;
  if (h.length === 4) {
    r = parseInt(h[1] + h[1], 16);
    g = parseInt(h[2] + h[2], 16);
    b = parseInt(h[3] + h[3], 16);
  } else {
    const n = parseInt(h.slice(1), 16);
    r = (n >> 16) & 255;
    g = (n >> 8) & 255;
    b = n & 255;
  }
  return `rgba(${r},${g},${b},${a})`;
}

// Normalize server/derived state names onto STATE_RANK keys.
function stateKey(st) {
  if (st === 'parked') return 'park';
  if (st === 'queued') return 'q';
  return st || 'unknown';
}

function isDoneLike(sk) {
  return sk === 'done' || sk === 'cancelled';
}

function isLiveActive(sk) {
  return sk === 'run' || sk === 'err' || sk === 'paused' || sk === 'stale';
}

function rankOf(sk) {
  return STATE_RANK[sk] != null ? STATE_RANK[sk] : 99;
}

// HH:MM for axis ticks from epoch-ms (no invented clock — real wall time).
function tickLabel(ms) {
  const d = new Date(ms);
  if (isNaN(d.getTime())) return '—';
  return d.toTimeString().slice(0, 5);
}

// --- window / x mapping (plan §5.3 + FR-21) --------------------------------------------------

function windowMs() {
  const z = [5, 20, 60].includes(ui.fpZoom) ? ui.fpZoom : 20;
  return z * 60 * 1000;
}

function windowEnd(now) {
  if (ui.fpFollow !== false) return now;
  return frozenEndMs != null ? frozenEndMs : now;
}

function windowStart(now) {
  return windowEnd(now) - windowMs();
}

// Map absolute time → left% of the track. Following: now → 86%. Unfollow: now can pass 86%.
function xPct(tMs, winStart, winMs, clampToNowFrac) {
  if (tMs == null || !Number.isFinite(tMs) || !winMs) return null;
  const r = (tMs - winStart) / winMs;
  if (clampToNowFrac) {
    const c = Math.max(0, Math.min(1, r));
    return c * NOW_FRAC * 100;
  }
  // open scale: r=1 → 86%, r>1 continues toward 100%
  return Math.max(0, Math.min(100, r * NOW_FRAC * 100));
}

// Segment geometry: clip to [winStart, winEnd], return {l, w} percents or null if fully outside.
function segGeom(start, end, winStart, winMs, now) {
  if (start == null && end == null) return null;
  const wEnd = winStart + winMs;
  let s = start != null ? start : winStart;
  let e = end != null ? end : now;
  if (e < winStart || s > wEnd) return null;
  if (s < winStart) s = winStart;
  if (e > wEnd) e = wEnd;
  if (e < s) e = s;
  const l = xPct(s, winStart, winMs, true);
  const r = xPct(e, winStart, winMs, true);
  if (l == null || r == null) return null;
  const w = Math.max(r - l, 0.4); // design: Math.max(w, 0.4)
  return { l, w };
}

// --- span bookkeeping (live-window policy) ---------------------------------------------------

function bookOf(id) {
  let b = spanBook.get(id);
  if (!b) {
    b = {
      seeded: false,
      lastLane: null,
      lastEvtSeen: null, // last lastEvtClient we reacted to
      spans: [],
    };
    spanBook.set(id, b);
  }
  return b;
}

function closeOpen(b, atMs) {
  for (const sp of b.spans) {
    if (sp.open) {
      sp.end = atMs;
      sp.open = false;
    }
  }
}

function lastSpan(b) {
  return b.spans.length ? b.spans[b.spans.length - 1] : null;
}

function pushSpan(b, start, end, kind, lane, open) {
  b.spans.push({
    start,
    end: end != null ? end : start,
    kind,
    lane: lane || null,
    open: !!open,
  });
}

// SEED from /api/agents ages — only once per agent (plan §5.3).
function seedSpans(rec, b, now) {
  const sk = stateKey(rec.state);
  const age = ageSecOf(rec, now);
  const claimAge = rec.claimAgeSec;

  if (isDoneLike(sk)) {
    // Done: no fabricated span history — render path draws a 2% stub only.
    b.seeded = true;
    b.lastLane = rec.lane;
    b.lastEvtSeen = rec.lastEvtClient;
    return;
  }

  if (rec.verify || (rec.id && rec.id.startsWith('v-'))) {
    // Purple hatch for the known claimed window; no invent when ages absent.
    if (claimAge != null) {
      const s = now - claimAge * 1000;
      pushSpan(b, s, now, 'verify', rec.lane, isLiveActive(sk));
    } else if (age != null) {
      pushSpan(b, now - age * 1000, now, 'verify', rec.lane, isLiveActive(sk));
    }
    b.seeded = true;
    b.lastLane = rec.lane;
    b.lastEvtSeen = rec.lastEvtClient;
    return;
  }

  if (sk === 'q') {
    // Queued: gray-dashed from window start (no invented takeoff) — special marker.
    pushSpan(b, null, null, 'queued', null, true);
    b.seeded = true;
    b.lastLane = rec.lane;
    b.lastEvtSeen = rec.lastEvtClient;
    return;
  }

  if (sk === 'park') {
    // Amber stub. Prefer claim age when known; else a point stub at "now" (position known,
    // duration not claimed — rendered as small fixed % width).
    if (claimAge != null) {
      const s = now - claimAge * 1000;
      pushSpan(b, s, Math.min(s + 7000, now), 'park', rec.lane, false);
    } else {
      pushSpan(b, now, now, 'park', rec.lane, false);
      b.spans[b.spans.length - 1].stubPct = 2;
    }
    b.seeded = true;
    b.lastLane = rec.lane;
    b.lastEvtSeen = rec.lastEvtClient;
    return;
  }

  // run / stale / err / paused: exec span [now−claimAge, now−last_event_age]
  if (claimAge != null) {
    const execStart = now - claimAge * 1000;
    const execEnd = age != null ? now - age * 1000 : now;
    const ee = Math.max(execStart, execEnd);
    const openExec = sk === 'run' || sk === 'err' || sk === 'paused';
    pushSpan(b, execStart, ee, 'exec', rec.lane, openExec);
    if (sk === 'stale' && ee < now) {
      pushSpan(b, ee, now, 'silent', null, true);
    }
  } else if (age != null) {
    // No claim age → do not invent takeoff; show only from last-known event.
    if (sk === 'stale') {
      pushSpan(b, now - age * 1000, now, 'silent', null, true);
    } else {
      pushSpan(b, now - age * 1000, now, 'exec', rec.lane, true);
    }
  }
  // no ages at all → empty track (honest)

  b.seeded = true;
  b.lastLane = rec.lane;
  b.lastEvtSeen = rec.lastEvtClient;
}

// LIVE updates after seed (plan §5.3).
function updateSpans(rec, b, now) {
  const sk = stateKey(rec.state);

  if (!b.seeded) {
    seedSpans(rec, b, now);
    return;
  }

  // Transition into done/cancelled: freeze history; render uses stub only.
  if (isDoneLike(sk)) {
    closeOpen(b, now);
    return;
  }

  // Transition into parked: close and leave/park stub.
  if (sk === 'park') {
    const last = lastSpan(b);
    if (!last || last.kind !== 'park') {
      closeOpen(b, now);
      pushSpan(b, now, now, 'park', rec.lane, false);
      b.spans[b.spans.length - 1].stubPct = 2;
    }
    b.lastLane = rec.lane;
    return;
  }

  // Transition into queued.
  if (sk === 'q') {
    const last = lastSpan(b);
    if (!last || last.kind !== 'queued') {
      closeOpen(b, now);
      pushSpan(b, null, null, 'queued', null, true);
    }
    b.lastLane = rec.lane;
    return;
  }

  // Lane change between polls → red-dashed retry gap + new solid exec (plan §5.3).
  if (
    rec.lane &&
    b.lastLane &&
    rec.lane !== b.lastLane &&
    isLiveActive(sk)
  ) {
    closeOpen(b, now);
    // Short red-dashed gap (~3s visual, clipped by window) then new exec.
    const gapStart = now - 3000;
    pushSpan(b, gapStart, now, 'retry', null, false);
    pushSpan(b, now, now, rec.verify ? 'verify' : 'exec', rec.lane, true);
    b.lastLane = rec.lane;
    b.lastEvtSeen = rec.lastEvtClient != null ? rec.lastEvtClient : b.lastEvtSeen;
    return;
  }
  if (rec.lane) b.lastLane = rec.lane;

  // LIVE SSE arrival extends the exec span; gap >60s opens a silent span.
  if (rec.lastEvtClient != null && rec.lastEvtClient !== b.lastEvtSeen) {
    const t = rec.lastEvtClient;
    if (b.lastEvtSeen != null && t - b.lastEvtSeen > 60000) {
      closeOpen(b, b.lastEvtSeen);
      pushSpan(b, b.lastEvtSeen, t, 'silent', null, false);
      pushSpan(b, t, t, rec.verify ? 'verify' : 'exec', rec.lane, true);
    } else {
      // Extend or open exec to the live event time.
      let last = lastSpan(b);
      if (last && (last.kind === 'exec' || last.kind === 'verify') && last.open) {
        last.end = t;
      } else {
        closeOpen(b, t);
        pushSpan(b, t, t, rec.verify ? 'verify' : 'exec', rec.lane, true);
      }
    }
    b.lastEvtSeen = t;
  }

  // State tails for active agents.
  if (sk === 'stale') {
    // Amber-dashed silent tail to NOW.
    let last = lastSpan(b);
    if (last && last.kind === 'silent' && last.open) {
      last.end = now;
    } else if (last && (last.kind === 'exec' || last.kind === 'verify')) {
      const cut = last.end != null ? last.end : now;
      last.open = false;
      if (cut < now) pushSpan(b, cut, now, 'silent', null, true);
    } else if (!last) {
      // Stale with no prior span — silent from last-known age if any.
      const age = ageSecOf(rec, now);
      if (age != null) pushSpan(b, now - age * 1000, now, 'silent', null, true);
    } else {
      last.end = now;
      last.open = true;
    }
  } else if (sk === 'run' || sk === 'err' || sk === 'paused') {
    // Keep open exec extended to NOW (live activity window).
    let last = lastSpan(b);
    const kind = rec.verify ? 'verify' : 'exec';
    if (last && last.kind === 'silent' && last.open) {
      // Came back from silence without a new lastEvtClient yet — keep silent until an event.
      last.end = now;
    } else if (last && (last.kind === 'exec' || last.kind === 'verify')) {
      last.end = now;
      last.open = true;
      last.kind = kind;
      if (rec.lane) last.lane = rec.lane;
    } else if (last && last.kind === 'queued') {
      // Claimed: convert queue marker into exec from now (no invented past takeoff).
      last.open = false;
      pushSpan(b, now, now, kind, rec.lane, true);
    } else if (!last) {
      pushSpan(b, now, now, kind, rec.lane, true);
    } else {
      closeOpen(b, now);
      pushSpan(b, now, now, kind, rec.lane, true);
    }
  }

  // Mirror onto the agent record so other modules can inspect if needed.
  rec.spans = b.spans;
}

// Evict span books for agents that have left the store.
function gcSpanBook() {
  for (const id of spanBook.keys()) {
    if (!store.agents.has(id)) spanBook.delete(id);
  }
}

// --- verify label from VERIFY_MAP (config-driven, FR-16) -------------------------------------

function verifyLabel(rec) {
  const pairs = store.verifyPairs || [];
  if (!pairs.length) return null;

  // The base agent's own record knows which lane actually generated the answer being verified
  // (v-<id> → <id>) — picking the first VERIFY_MAP pair that merely MENTIONS the verifier's lane
  // is wrong once a lane verifies more than one generator (e.g. codex verifying claude/glm/grok
  // all read "C⊢X"). doneLane wins once the base agent finished; its live lane is the fallback.
  const baseId = rec.id && rec.id.startsWith('v-') ? rec.id.slice(2) : null;
  const baseRec = baseId ? store.agents.get(baseId) : null;
  if (baseRec) {
    const generator = baseRec.doneLane ?? baseRec.lane;
    if (generator && rec.lane) return `${laneLetter(generator)}⊢${laneLetter(rec.lane)}`;
  }

  // Base agent unknown — fall back to the previous behavior: prefer a pair that mentions the
  // agent's lane; else index among verify agents.
  if (rec.lane) {
    for (const [a, b] of pairs) {
      if (a === rec.lane || b === rec.lane) {
        return `${laneLetter(a)}⊢${laneLetter(b)}`;
      }
    }
  }
  // Fall back: order verify agents and zip with pairs (honest when pair exists).
  const vIds = [];
  for (const r of store.agents.values()) {
    if (r.verify || (r.id && r.id.startsWith('v-'))) vIds.push(r.id);
  }
  const ix = vIds.indexOf(rec.id);
  if (ix >= 0 && ix < pairs.length) {
    const [a, b] = pairs[ix];
    return `${laneLetter(a)}⊢${laneLetter(b)}`;
  }
  if (pairs[0]) {
    const [a, b] = pairs[0];
    return `${laneLetter(a)}⊢${laneLetter(b)}`;
  }
  return null;
}

// --- age cell text ---------------------------------------------------------------------------

function ageCell(rec, sk, age) {
  if (sk === 'done' || sk === 'cancelled') {
    return { text: '✓', cls: 'is-done' };
  }
  if (sk === 'q') {
    return { text: '—', cls: '' };
  }
  if (sk === 'park') {
    return { text: 'parked', cls: 'is-stale' };
  }
  if (age == null) {
    return { text: '—', cls: '' };
  }
  if (sk === 'stale') {
    return { text: `${fmtAge(age)}!`, cls: 'is-stale' };
  }
  if (sk === 'err') {
    return { text: fmtAge(age), cls: 'is-err' };
  }
  return { text: fmtAge(age), cls: '' };
}

// --- segment → DOM style ---------------------------------------------------------------------

function segStyle(sp, geom) {
  const left = geom.l.toFixed(2) + '%';
  const width = geom.w.toFixed(2) + '%';
  if (sp.kind === 'exec') {
    const c = laneColor(sp.lane);
    return {
      className: 'fp-seg kind-exec',
      style: `left:${left};width:${width};background:${hexA(c, 0.2)};border:1px solid ${hexA(c, 0.55)}`,
    };
  }
  if (sp.kind === 'verify') {
    return {
      className: 'fp-seg kind-verify',
      style: `left:${left};width:${width}`,
    };
  }
  if (sp.kind === 'queued') {
    return { className: 'fp-seg kind-queued', style: `left:${left};width:${width}` };
  }
  if (sp.kind === 'silent') {
    return { className: 'fp-seg kind-silent', style: `left:${left};width:${width}` };
  }
  if (sp.kind === 'retry') {
    return { className: 'fp-seg kind-retry', style: `left:${left};width:${width}` };
  }
  if (sp.kind === 'park') {
    return { className: 'fp-seg kind-park', style: `left:${left};width:${width}` };
  }
  if (sp.kind === 'done') {
    return { className: 'fp-seg kind-done', style: `left:${left};width:${width}` };
  }
  return { className: 'fp-seg', style: `left:${left};width:${width}` };
}

// --- row list assembly -----------------------------------------------------------------------

function collectRows(now) {
  const live = [];
  const done = [];
  for (const rec of store.agents.values()) {
    const sk = stateKey(rec.state);
    if (isDoneLike(sk)) done.push(rec);
    else live.push(rec);
  }

  if (ui.fpSort === 'quiet') {
    live.sort((a, b) => {
      const ra = rankOf(stateKey(a.state));
      const rb = rankOf(stateKey(b.state));
      if (ra !== rb) return ra - rb;
      const aa = ageSecOf(a, now);
      const ba = ageSecOf(b, now);
      // age desc (older/quieter first); nulls sink
      const av = aa == null ? -1 : aa;
      const bv = ba == null ? -1 : ba;
      if (bv !== av) return bv - av;
      return String(a.id).localeCompare(String(b.id));
    });
  }
  // bus order = Map insertion order (already)

  // Update span books for every visible agent.
  for (const rec of live) updateSpans(rec, bookOf(rec.id), now);
  if (ui.fpShowDone) {
    for (const rec of done) updateSpans(rec, bookOf(rec.id), now);
  }
  gcSpanBook();

  const rows = live.slice();
  if (ui.fpShowDone) {
    // Done after live (design concat); keep bus-ish id order within done.
    done.sort((a, b) => String(a.id).localeCompare(String(b.id)));
    for (const r of done) rows.push(r);
  }
  return { rows, doneCount: done.length };
}

// --- charts ----------------------------------------------------------------------------------

function countErrInWindow(t0, t1) {
  let n = 0;
  for (const rec of store.agents.values()) {
    if (!rec.dots) continue;
    for (const d of rec.dots) {
      // live error dots are red (#f97066)
      if (d.c === '#f97066' && d.t >= t0 && d.t < t1) n += 1;
    }
  }
  return n;
}

function buildBurnChart(now) {
  const spentKnown = store.spentUsd != null && Number.isFinite(store.spentUsd);
  const cum = ringArr(store.series.spentCum);
  const burns = ringArr(store.series.burnPerBucket);
  const n = cum.length;

  let values;
  let labelSuffix;
  if (spentKnown) {
    values = cum.slice();
    labelSuffix = '';
  } else {
    // Client-integrate $/min × 0.5 min per bucket → labeled "$ since page load".
    values = [];
    let s = 0;
    for (let i = 0; i < burns.length; i++) {
      s += (burns[i] || 0) * 0.5;
      values.push(s);
    }
    labelSuffix = 'since-load';
  }

  // Has any real signal yet?
  let peak = 0;
  for (const v of values) if (v > peak) peak = v;
  const budgetCap = Number(store.config && store.config.BUDGET_USD != null
    ? store.config.BUDGET_USD
    : store.budgetUsd);
  const hasBudget = Number.isFinite(budgetCap) && budgetCap > 0;
  if (hasBudget && budgetCap > peak) peak = budgetCap;

  const allZero = peak <= 0;
  const bars = values.map((v) => {
    const h = allZero ? 0 : Math.max(0, Math.min(100, (v / peak) * 100));
    return { h };
  });

  let budgetTop = null;
  if (hasBudget && peak > 0) {
    budgetTop = 100 - (budgetCap / peak) * 100; // CSS top%
  }

  return {
    bars,
    empty: allZero && !spentKnown,
    labelSuffix,
    budgetTop,
    budgetCap: hasBudget ? budgetCap : null,
    spentKnown,
  };
}

function buildEvtChart(now) {
  const arr = ringArr(store.series.evtPerBucket);
  const n = arr.length;
  let peak = 0;
  for (const v of arr) if (v > peak) peak = v;

  // Map each ring slot to a wall-time window (oldest → newest; newest = current 30s).
  const bars = [];
  for (let i = 0; i < n; i++) {
    const ageFromNow = (n - 1 - i) * 30000;
    const t1 = now - ageFromNow;
    const t0 = t1 - 30000;
    const errN = countErrInWindow(t0, t1);
    const v = arr[i] || 0;
    const h = peak > 0 ? Math.max(0, Math.min(100, (v / peak) * 100)) : 0;
    bars.push({ h, spike: errN >= 3 });
  }
  return { bars, empty: peak <= 0 };
}

// --- render ----------------------------------------------------------------------------------

function renderHeader(doneCount) {
  const sortLabel = ui.fpSort === 'quiet' ? 'quietest first' : 'bus order';
  const zoom = [5, 20, 60].includes(ui.fpZoom) ? ui.fpZoom : 20;
  const followOn = ui.fpFollow !== false;
  const doneTxt = (ui.fpShowDone ? '▾ hide' : '▸ show') + ` ${doneCount} done branches`;

  return `
    <div class="fp-hdr">
      <span class="fp-title">flightpaths · a flat line is a stuck agent</span>
      <button type="button" class="fp-ctrl" data-act="sort">sort: ${esc(sortLabel)} ⇅</button>
      <button type="button" class="fp-ctrl fp-zoom" data-act="zoom" title="cycle window 5m / 20m / 60m">zoom: ${zoom}m</button>
      <label class="fp-follow"><input type="checkbox" data-act="follow" ${followOn ? 'checked' : ''}/> follow NOW</label>
      <span class="fp-legend">solid = executing · dashed = queued · <span class="leg-amber">amber dash = silent</span> · bar tint = lane · <span class="leg-purple">hatch = verify</span> · dots = <span class="leg-blue">tool</span>/<span class="leg-red">error</span> since page load · click row → inspect</span>
    </div>
  `;
}

function renderAxis(now) {
  const winMs = windowMs();
  const wEnd = windowEnd(now);
  const wStart = wEnd - winMs;
  // 5 ticks across 0..80% of the track (design: 0/20/40/60/80), NOW label fixed at 86%.
  const ticks = [];
  for (let i = 0; i < 5; i++) {
    const frac = i / 4; // 0..1 across the data window
    const tMs = wStart + frac * winMs;
    const left = frac * NOW_FRAC * 100;
    ticks.push(`<span class="fp-tick" style="left:${left.toFixed(1)}%">${esc(tickLabel(tMs))}</span>`);
  }
  return `
    <div class="fp-axis">
      ${ticks.join('')}
      <span class="fp-now-label">NOW ▾</span>
    </div>
  `;
}

function renderRow(rec, now, winStart, winMs) {
  const sk = stateKey(rec.state);
  const age = ageSecOf(rec, now);
  const b = bookOf(rec.id);
  const isVerify = !!(rec.verify || (rec.id && rec.id.startsWith('v-')));
  const vLab = isVerify ? verifyLabel(rec) : null;
  const laneTxt = isVerify && vLab
    ? vLab
    : laneLetter(rec.lane);
  const lc = isVerify ? '#c084fc' : laneColor(rec.lane);
  const ac = ageCell(rec, sk, age);

  let rowCls = 'fp-row';
  if (sk === 'stale') rowCls += ' is-stale';
  else if (sk === 'err') rowCls += ' is-err';
  if (ui.sel === rec.id) rowCls += ' is-sel';

  // Segments
  const segsHtml = [];
  if (isDoneLike(sk)) {
    // 2%-wide stub at NOW − done age — no fabricated span (plan §5.3).
    let stubT = now;
    if (rec.doneMs != null && Number.isFinite(rec.doneMs)) {
      stubT = rec.doneMs;
    } else if (age != null) {
      stubT = now - age * 1000;
    }
    const left = xPct(stubT, winStart, winMs, true);
    if (left != null) {
      const l = Math.min(left, NOW_FRAC * 100 - 2);
      segsHtml.push(
        `<div class="fp-seg kind-done" style="left:${l.toFixed(2)}%;width:2%"></div>`,
      );
    }
  } else {
    for (const sp of b.spans) {
      let geom;
      if (sp.kind === 'queued') {
        // From window start to NOW (no invented takeoff).
        const nowX = xPct(Math.min(now, winStart + winMs), winStart, winMs, true);
        if (nowX == null || nowX <= 0) continue;
        geom = { l: 0, w: Math.max(nowX, 0.4) };
      } else if (sp.stubPct) {
        const left = xPct(sp.start != null ? sp.start : now, winStart, winMs, true);
        if (left == null) continue;
        geom = { l: Math.min(left, NOW_FRAC * 100 - sp.stubPct), w: sp.stubPct };
      } else {
        const end = sp.open ? now : sp.end;
        geom = segGeom(sp.start, end, winStart, winMs, now);
      }
      if (!geom) continue;
      const st = segStyle(sp, geom);
      segsHtml.push(`<div class="${st.className}" style="${st.style}"></div>`);
    }
  }

  // Dots — LIVE only (already enforced by data.js; we just place them). Cap already 24.
  const dotsHtml = [];
  if (!isDoneLike(sk) && rec.dots && rec.dots.length) {
    for (const d of rec.dots) {
      if (d.t == null) continue;
      const left = xPct(d.t, winStart, winMs, true);
      if (left == null || left <= 0 || left > NOW_FRAC * 100) continue;
      dotsHtml.push(
        `<span class="fp-dot" style="left:${left.toFixed(2)}%;background:${esc(d.c || '#7dd3fc')}"></span>`,
      );
    }
  }

  return `
    <div class="${rowCls}" data-id="${esc(rec.id)}" role="button" tabindex="0">
      <span class="fp-id">${esc(rec.id)} <span class="fp-lane" style="color:${esc(lc)}">${esc(laneTxt)}</span></span>
      <div class="fp-track">${segsHtml.join('')}${dotsHtml.join('')}</div>
      <span class="fp-age ${ac.cls}">${esc(ac.text)}</span>
    </div>
  `;
}

function renderCharts(now) {
  const burn = buildBurnChart(now);
  const evt = buildEvtChart(now);

  let burnLabel = '$ burn (cumulative)';
  if (burn.labelSuffix === 'since-load') {
    burnLabel += ' — <span class="since-load">$ since page load</span>';
  } else if (burn.budgetCap != null) {
    burnLabel += ` — budget line $${burn.budgetCap}`;
  }

  let burnBody;
  if (burn.empty) {
    burnBody = `<div class="fp-chart-empty">collecting… (needs ~1 min)</div>`;
  } else {
    const budgetLine = burn.budgetTop != null
      ? `<div class="fp-budget-line" style="top:${burn.budgetTop.toFixed(1)}%"></div>`
      : '';
    const bars = burn.bars.map((b) =>
      `<div class="fp-bar" style="height:${Math.max(b.h, b.h > 0 ? 2 : 0).toFixed(0)}%"></div>`,
    ).join('');
    burnBody = `<div class="fp-chart-bars">${budgetLine}${bars}</div>`;
  }

  let evtBody;
  if (evt.empty) {
    evtBody = `<div class="fp-chart-empty">collecting… (needs ~1 min)</div>`;
  } else {
    const bars = evt.bars.map((b) =>
      `<div class="fp-bar${b.spike ? ' spike' : ''}" style="height:${Math.max(b.h, b.h > 0 ? 2 : 0).toFixed(0)}%"></div>`,
    ).join('');
    evtBody = `<div class="fp-chart-bars evt">${bars}</div>`;
  }

  return `
    <div class="fp-charts">
      <div class="fp-chart">
        <div class="fp-chart-label">${burnLabel}</div>
        ${burnBody}
      </div>
      <div class="fp-chart">
        <div class="fp-chart-label">events / min — <span class="spike">spike = ≥3 errors/30s</span></div>
        ${evtBody}
      </div>
    </div>
  `;
}

function render() {
  if (!root) return;
  const now = Date.now();
  const winMs = windowMs();
  const wEnd = windowEnd(now);
  const wStart = wEnd - winMs;

  const { rows, doneCount } = collectRows(now);

  // NOW line position: when following, fixed at 86% of track; when not, tracks real now.
  const nowLeftPct = xPct(now, wStart, winMs, false);
  const nowLineLeft = nowLeftPct != null
    ? `calc(104px + (100% - 162px) * ${(nowLeftPct / 100).toFixed(4)})`
    : `calc(104px + (100% - 162px) * ${NOW_FRAC})`;

  const rowsHtml = rows.length
    ? rows.map((r) => renderRow(r, now, wStart, winMs)).join('')
    : `<div class="fp-empty">no agents on the bus — waiting for /api/agents</div>`;

  const doneTxt = (ui.fpShowDone ? '▾ hide' : '▸ show') + ` ${doneCount} done branches`;

  root.innerHTML = `
    ${renderHeader(doneCount)}
    ${renderAxis(now)}
    <div class="fp-body">
      <div class="fp-now-line" style="left:${nowLineLeft}"></div>
      ${rowsHtml}
      <div class="fp-done-tog" data-act="done">${esc(doneTxt)}</div>
    </div>
    ${renderCharts(now)}
  `;
}

// --- interactions ----------------------------------------------------------------------------

function cycleZoom() {
  const cur = [5, 20, 60].includes(ui.fpZoom) ? ui.fpZoom : 20;
  const ix = ZOOM_PRESETS.indexOf(cur);
  ui.fpZoom = ZOOM_PRESETS[(ix + 1) % ZOOM_PRESETS.length];
  saveJSON('unimatrix-fp-zoom', { v: ui.fpZoom });
}

function toggleSort() {
  ui.fpSort = ui.fpSort === 'quiet' ? 'bus' : 'quiet';
  saveJSON('unimatrix-fp-sort', { v: ui.fpSort });
}

function toggleDone() {
  ui.fpShowDone = !ui.fpShowDone;
  saveJSON('unimatrix-fp-done', { v: ui.fpShowDone });
}

function setFollow(on) {
  ui.fpFollow = !!on;
  if (!ui.fpFollow) {
    frozenEndMs = Date.now();
  } else {
    frozenEndMs = null;
  }
}

function onClick(ev) {
  const t = ev.target;
  if (!t || !root) return;

  // follow checkbox
  if (t.matches && t.matches('input[data-act="follow"]')) {
    setFollow(t.checked);
    render();
    return;
  }

  const actEl = t.closest ? t.closest('[data-act]') : null;
  if (actEl && root.contains(actEl)) {
    const act = actEl.getAttribute('data-act');
    if (act === 'sort') { toggleSort(); render(); return; }
    if (act === 'zoom') { cycleZoom(); render(); return; }
    if (act === 'done') { toggleDone(); render(); return; }
  }

  const row = t.closest ? t.closest('.fp-row[data-id]') : null;
  if (row && root.contains(row)) {
    const id = row.getAttribute('data-id');
    if (id) select(id);
  }
}

function onKey(ev) {
  if (ev.key !== 'Enter' && ev.key !== ' ') return;
  const row = ev.target && ev.target.closest ? ev.target.closest('.fp-row[data-id]') : null;
  if (!row || !root.contains(row)) return;
  ev.preventDefault();
  const id = row.getAttribute('data-id');
  if (id) select(id);
}

// --- public API ------------------------------------------------------------------------------

function init(rootEl) {
  root = rootEl;
  if (!root) return;

  // Re-sync prefs from ui (data.js already loaded localStorage into ui).
  if (!['quiet', 'bus'].includes(ui.fpSort)) ui.fpSort = 'quiet';
  if (![5, 20, 60].includes(ui.fpZoom)) ui.fpZoom = 20;
  if (ui.fpFollow == null) ui.fpFollow = true;

  if (!bound) {
    bound = true;
    root.addEventListener('click', onClick);
    root.addEventListener('keydown', onKey);
    bus.addEventListener('data', () => { if (root) render(); });
    bus.addEventListener('tick', () => { if (root) render(); });
    bus.addEventListener('sel', () => { if (root) render(); });
  }
  render();
}

export { init, render };
export default { init, render };
