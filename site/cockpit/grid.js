/**
 * MISSION CONTROL view — attention rail, filter chips, and agent tile grid.
 *
 * Project: unimatrix — multi-model swarm orchestrator driven from Claude Code
 * Module:  site/cockpit/grid.js
 * Deps:    format.js (PURE helpers + STATE_RANK/tileStyle/LANES), data.js (store/ui/bus/select),
 *          ctl.js (ctl); browser DOM only inside #view-grid
 * Tested:  tests/cockpit.bats (logic mirror); playwright Lane-A QA (plan §5.5)
 *
 * Key responsibilities:
 * - Render the left attention rail from store.alerts (all alerts; verb + inspect buttons).
 * - State filter chips (ALL / ATTN / RUN / QUEUED / FINISHED) + per-EXEC_CHAIN lane chips that
 *   compose with the state filter (FR-10, FR-18, FR-22).
 * - Agent tile grid sorted trouble-first (STATE_RANK then age desc); click → select(id).
 * - Apply bus "nav" detail.filter / detail.lane for cross-view jumps from OPS WALL.
 *
 * Design constraints:
 * - Owns ONLY #view-grid. Never touches header/strip/drawer DOM.
 * - No fake data (FR-14): absent ages/tokens/lanes render as "—"; lane chips come from
 *   store.execChain only (never a hardcoded lane list).
 * - Alert verbs map to real ctl() payloads (or inspect-only for starved); never invent verbs.
 * - Pixel truth = design/cockpit.dc.html mission-control markup + plan §1.2 D / §5.3 tiles.
 */

import {
  esc, fmtTok, fmtAge, pulseStr, STATE_RANK,
  tileStyle, laneLetter, laneColor, ageSecOf,
} from './format.js';
import { store, ui, bus, select } from './data.js';
import { ctl } from './ctl.js';

// --- module state ---------------------------------------------------------------------------

let root = null;
let bound = false;

// Canonical state-filter keys stored on ui.mcFilter.
const FILTER_ALIASES = {
  all: 'all',
  attention: 'attention',
  attn: 'attention',
  run: 'run',
  active: 'run',
  queued: 'queued',
  q: 'queued',
  finished: 'finished',
  done: 'finished',
};

// --- pure helpers ------------------------------------------------------------------------

// data.js deriveState may pass through server names "parked"/"queued"; tileStyle + STATE_RANK
// use the design short forms "park"/"q". Normalize at the view boundary so either wins.
function tileState(rec) {
  const s = rec && rec.state;
  if (s === 'parked') return 'park';
  if (s === 'queued') return 'q';
  return s || 'unknown';
}

function normalizeFilter(raw) {
  if (raw == null || raw === '') return 'all';
  const k = String(raw).toLowerCase();
  return FILTER_ALIASES[k] || 'all';
}

// EXEC_CHAIN lane names in config order — never invent a fallback list.
function execLaneNames() {
  const names = [];
  const seen = new Set();
  for (const lm of store.execChain || []) {
    const i = String(lm).indexOf(':');
    const lane = i >= 0 ? String(lm).slice(0, i) : String(lm);
    if (!lane || seen.has(lane)) continue;
    seen.add(lane);
    names.push(lane);
  }
  return names;
}

// One-line activity per plan §5.3 (real lastSummary text only; no invented captions).
function activityLine(st, rec) {
  const sum = rec.lastSummary && rec.lastSummary.text ? String(rec.lastSummary.text) : null;
  switch (st) {
    case 'run': return sum || 'working…';
    case 'q': return 'waiting for claim';
    case 'done': return 'handoff written ✓';
    case 'park': return 'parked (.limited)';
    case 'err': return sum || 'error — retrying';
    case 'stale': return 'no events — nudge?';
    case 'cancelled': return 'cancelled';
    case 'paused': return 'frozen (SIGSTOP)';
    default: return rec.lastActivity || '—';
  }
}

// Age/status tail next to the state glyph (design stTile + FR-22 cancelled).
function ageLabel(st, age) {
  if (st === 'done' || st === 'cancelled') return '';
  if (st === 'q') return 'queued';
  if (st === 'park') return 'parked';
  return fmtAge(age);
}

function tokLabel(rec) {
  if (rec.tokens == null) return '—';
  return fmtTok(rec.tokens);
}

function matchesFilter(st, filt) {
  switch (filt) {
    case 'attention': return st === 'err' || st === 'stale' || st === 'park';
    case 'run': return st === 'run';
    case 'queued': return st === 'q';
    case 'finished': return st === 'done' || st === 'cancelled';
    case 'all':
    default: return true;
  }
}

function matchesLane(rec, lane) {
  if (!lane) return true;
  return rec.lane === lane;
}

// --- event handlers -------------------------------------------------------------------------

function onNav(e) {
  const d = (e && e.detail) || {};
  // Cross-view jumps (FR-18): apply filter/lane even when the view switch is owned by main.js.
  if (d.filter != null) ui.mcFilter = normalizeFilter(d.filter);
  if (Object.prototype.hasOwnProperty.call(d, 'lane')) {
    ui.laneFilter = d.lane ? String(d.lane) : null;
  }
  render();
}

function onClick(e) {
  const t = e.target;
  if (!t || !root || !root.contains(t)) return;

  // State filter chip
  const filt = t.closest('[data-mc-filter]');
  if (filt && root.contains(filt)) {
    ui.mcFilter = normalizeFilter(filt.getAttribute('data-mc-filter'));
    render();
    return;
  }

  // Lane filter chip (toggle: re-click clears)
  const laneChip = t.closest('[data-mc-lane]');
  if (laneChip && root.contains(laneChip)) {
    const lane = laneChip.getAttribute('data-mc-lane') || '';
    ui.laneFilter = (ui.laneFilter === lane) ? null : (lane || null);
    render();
    return;
  }

  // Alert verb button → ctl (or inspect-only when no ctl payload)
  const verbBtn = t.closest('[data-alert-verb]');
  if (verbBtn && root.contains(verbBtn)) {
    const idx = Number(verbBtn.getAttribute('data-alert-verb'));
    const al = store.alerts[idx];
    if (!al) return;
    if (al.ctl && al.ctl.verb) {
      ctl(al.ctl.verb, al.ctl.payload || {});
    } else if (al.pick) {
      select(al.pick);
    } else if (al.nav) {
      bus.dispatchEvent(new CustomEvent('nav', { detail: al.nav }));
    }
    return;
  }

  // Alert inspect → select(id) or nav target (budget/starved have no agent id)
  const inspBtn = t.closest('[data-alert-inspect]');
  if (inspBtn && root.contains(inspBtn)) {
    const idx = Number(inspBtn.getAttribute('data-alert-inspect'));
    const al = store.alerts[idx];
    if (!al) return;
    if (al.pick) select(al.pick);
    else if (al.nav) bus.dispatchEvent(new CustomEvent('nav', { detail: al.nav }));
    return;
  }

  // Tile → drawer
  const tile = t.closest('[data-agent-id]');
  if (tile && root.contains(tile)) {
    const id = tile.getAttribute('data-agent-id');
    if (id) select(id);
  }
}

// --- render pieces --------------------------------------------------------------------------

function renderRail(alerts) {
  const n = alerts.length;
  const titleC = n ? '#e0b34a' : '#34d399';
  let cards = '';
  if (n === 0) {
    cards = `<div class="mc-empty">nothing needs you.</div>`;
  } else {
    cards = alerts.map((al, i) => {
      const id = esc(al.id || '—');
      const title = esc(al.title || '');
      const sub = esc(al.sub || '');
      const verb = esc(al.verb || 'inspect');
      const c = al.c || '#e0b34a';
      const bc = al.bc || 'rgba(224,179,74,.5)';
      // Starved is inspect-only (ctl null); still show the verb label from the alert record.
      const verbBtn = `<button type="button" class="mc-alert-verb" data-alert-verb="${i}" style="color:${c};border-color:${bc}">${verb}</button>`;
      const inspBtn = `<button type="button" class="mc-alert-insp" data-alert-inspect="${i}">inspect →</button>`;
      return `<div class="mc-alert" style="border-color:${bc}">
  <div class="mc-alert-head">${id} <span style="color:${c}">${title}</span></div>
  <div class="mc-alert-sub">${sub}</div>
  <div class="mc-alert-acts">${verbBtn}${inspBtn}</div>
</div>`;
    }).join('');
  }

  return `<aside class="mc-rail">
  <div class="mc-rail-title" style="color:${titleC}">needs attention (${n})</div>
  ${cards}
  <div class="mc-rail-foot">alert rules — age &gt; LEASE_MIN/2 · retries ≥ 2 · budget &gt; 80% · queue starved while a lane idles. Thresholds from swarm.conf.</div>
</aside>`;
}

function chipHtml(key, label, active) {
  const cls = active ? 'mc-chip on' : 'mc-chip';
  return `<button type="button" class="${cls}" data-mc-filter="${esc(key)}">${esc(label)}</button>`;
}

function laneChipHtml(lane, active) {
  const letter = laneLetter(lane);
  const color = laneColor(lane);
  // Active uses the shared green selection; inactive keeps the lane color border/text.
  if (active) {
    return `<button type="button" class="mc-chip on mc-lane-chip" data-mc-lane="${esc(lane)}" title="${esc(lane)}">${esc(letter)}</button>`;
  }
  return `<button type="button" class="mc-chip mc-lane-chip" data-mc-lane="${esc(lane)}" title="${esc(lane)}" style="color:${color};border-color:${color}">${esc(letter)}</button>`;
}

function renderFilters(counts, filt, laneFilt) {
  const stateChips = [
    chipHtml('all', `ALL ${counts.all}`, filt === 'all'),
    chipHtml('attention', `ATTN ${counts.attention}`, filt === 'attention'),
    chipHtml('run', `RUN ${counts.run}`, filt === 'run'),
    chipHtml('queued', `QUEUED ${counts.queued}`, filt === 'queued'),
    chipHtml('finished', `FINISHED ${counts.finished}`, filt === 'finished'),
  ].join('');

  const lanes = execLaneNames();
  const laneChips = lanes.length
    ? `<span class="mc-chip-sep" aria-hidden="true"></span>${lanes.map((l) => laneChipHtml(l, laneFilt === l)).join('')}`
    : '';

  return `<div class="mc-filters">${stateChips}${laneChips}</div>`;
}

function renderTile(rec, now, sel) {
  const st = tileState(rec);
  const style = tileStyle(st);
  const age = ageSecOf(rec, now);
  const pulse = pulseStr(rec.buckets);
  const act = esc(activityLine(st, rec));
  const ageTxt = esc(ageLabel(st, age));
  const tok = esc(tokLabel(rec));
  const id = esc(rec.id);
  const lane = rec.lane;
  const lc = laneColor(lane);
  const letter = lane ? laneLetter(lane) : '?';
  const laneChip = lane
    ? `<span class="mc-tile-lane" style="color:${lc};border-color:${lc}">${esc(letter)}</span>`
    : `<span class="mc-tile-lane mc-tile-lane-none">—</span>`;
  const ring = sel === rec.id ? '0 0 0 2px #34d399' : 'none';
  const selected = sel === rec.id ? ' is-sel' : '';

  return `<div class="mc-tile${selected}" data-agent-id="${id}" style="border-color:${style.bc};opacity:${style.op};box-shadow:${ring}" role="button" tabindex="0">
  <div class="mc-tile-top"><span class="mc-tile-id">${id}</span>${laneChip}</div>
  <div class="mc-tile-pulse">${esc(pulse)}</div>
  <div class="mc-tile-act">${act}</div>
  <div class="mc-tile-bot"><span style="color:${style.gc}">${style.glyph}${ageTxt ? ' ' + ageTxt : ''}</span><span class="mc-tile-tok">${tok}</span></div>
</div>`;
}

// --- public API -----------------------------------------------------------------------------

function render() {
  if (!root) return;

  const now = Date.now();
  const filt = normalizeFilter(ui.mcFilter);
  // Keep ui.mcFilter canonical so other modules (and nav) see a stable key.
  ui.mcFilter = filt;
  const laneFilt = ui.laneFilter || null;
  const sel = ui.sel;
  const alerts = store.alerts || [];

  // Count against ALL agents (lane filter does not shrink the state-chip tallies).
  const counts = { all: 0, attention: 0, run: 0, queued: 0, finished: 0 };
  const list = [];
  for (const rec of store.agents.values()) {
    const st = tileState(rec);
    counts.all += 1;
    if (st === 'err' || st === 'stale' || st === 'park') counts.attention += 1;
    if (st === 'run') counts.run += 1;
    if (st === 'q') counts.queued += 1;
    if (st === 'done' || st === 'cancelled') counts.finished += 1;
    list.push(rec);
  }

  // Trouble-first: STATE_RANK then age desc (older = more urgent within a rank).
  list.sort((a, b) => {
    const sa = tileState(a);
    const sb = tileState(b);
    const ra = STATE_RANK[sa] != null ? STATE_RANK[sa] : 99;
    const rb = STATE_RANK[sb] != null ? STATE_RANK[sb] : 99;
    if (ra !== rb) return ra - rb;
    const aa = ageSecOf(a, now);
    const ab = ageSecOf(b, now);
    // null ages sink within the rank (treat as 0 for sort, never invent a display value).
    return (ab == null ? 0 : ab) - (aa == null ? 0 : aa);
  });

  const tiles = list
    .filter((rec) => matchesFilter(tileState(rec), filt) && matchesLane(rec, laneFilt))
    .map((rec) => renderTile(rec, now, sel))
    .join('');

  const gridBody = tiles || `<div class="mc-grid-empty">no agents match · filter ${esc(filt)}${laneFilt ? ' · lane ' + esc(laneFilt) : ''}</div>`;

  root.innerHTML = `<div class="mc">
  ${renderRail(alerts)}
  <div class="mc-main">
    <div class="mc-main-head">
      <span class="mc-main-title">agents · trouble first, done sinks</span>
      <span class="mc-main-legend">border = state · number = age since last event · <span class="mc-pulse-leg">▂▅▃</span> = tool-call pulse</span>
    </div>
    ${renderFilters(counts, filt, laneFilt)}
    <div class="mc-grid">${gridBody}</div>
  </div>
</div>`;
}

function init(rootEl) {
  root = rootEl;
  if (!bound) {
    bound = true;
    bus.addEventListener('data', render);
    bus.addEventListener('tick', render);
    bus.addEventListener('nav', onNav);
    bus.addEventListener('sel', render);
    // Delegation on the view root survives full innerHTML re-renders.
    root.addEventListener('click', onClick);
    root.addEventListener('keydown', (e) => {
      if (e.key !== 'Enter' && e.key !== ' ') return;
      const tile = e.target && e.target.closest && e.target.closest('[data-agent-id]');
      if (tile && root.contains(tile)) {
        e.preventDefault();
        const id = tile.getAttribute('data-agent-id');
        if (id) select(id);
      }
    });
  }
  render();
}

export default { init, render };
export { init, render };
