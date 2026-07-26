/**
 * Legacy event firehose as cockpit view 4. Renders ONLY inside #view-fire from data.js's buffer.
 *
 * Project: unimatrix — multi-model swarm orchestrator driven from Claude Code
 * Module:  site/cockpit/firehose.js
 * Deps:    format.js (esc, fmtTime, colorFor, loadJSON, saveJSON); data.js (store, bus)
 * Tested:  n/a
 *
 * Key responsibilities:
 * - Port the legacy firehose UI byte-compatible: kind chips, worker chips, #feed rows, live
 *   spinner coalesce display, click-to-expand raw JSON (32 KiB), hover-pause auto-scroll,
 *   500-row cap, localStorage unimatrix-fh-kinds / unimatrix-fh-workers (same defaults/shape).
 * - Subscribe to bus feed:append / feed:update / feed:reset — never open EventSource (data.js
 *   owns SSE + coalescing). Paint from store.feed entry objects.
 * - Keep the feed DOM mounted across view switches so scroll position and expanded detail rows
 *   survive (main.js only toggles display:none on #view-fire).
 *
 * Design constraints:
 * - NEVER touch DOM outside rootEl (#view-fire). No fetch, no SSE, no timers of our own.
 * - No fake data (spec 07 FR-14): workers/rows come only from store.feed / store.agents.
 * - Backfill entries (entry.backfill) render dimmer with title "time = replay receipt".
 * - localStorage keys and defaults must stay byte-identical to legacy (thinking+progress OFF).
 */

import { esc, fmtTime, colorFor, loadJSON, saveJSON } from './format.js';
import { store, bus } from './data.js';

// --- constants (legacy-compatible) -----------------------------------------------------------

const FH_KINDS = ['tools', 'text', 'thinking', 'system', 'progress'];
// thinking/progress start OFF — coalesced heartbeat rows, opt-in (legacy defaults).
const KIND_DEFAULTS = { tools: true, text: true, thinking: false, system: true, progress: false };
const FEED_CAP = 500;
const SUM_TRUNCATE = 140;
const RAW_TEXT_TRUNCATE = 300;

// --- module state ----------------------------------------------------------------------------

let root = null;
let feedEl = null;
let kindChipsEl = null;
let workerChipsEl = null;
let paused = false;
let inited = false;

/** @type {Map<object, HTMLElement>} entry object identity → row/raw DOM node */
const entryEl = new Map();

/** Workers we have shown a chip for (insertion order). */
const seenWorkers = new Set();

const kindState = loadJSON('unimatrix-fh-kinds', KIND_DEFAULTS);
const workerState = loadJSON('unimatrix-fh-workers', {});

// --- pure helpers ----------------------------------------------------------------------------

function truncate(s, n) {
  s = String(s);
  return s.length > n ? s.slice(0, n) + '…' : s;
}

function rowVisible(kind, worker) {
  return kindState[kind] !== false && workerState[worker] !== false;
}

// --- shell DOM -------------------------------------------------------------------------------

function buildShell() {
  root.innerHTML = `
    <h2>Firehose</h2>
    <div class="fh-filters" aria-label="Firehose filters">
      <div id="fh-kind-chips"></div>
      <span class="fh-sep" aria-hidden="true"></span>
      <div id="fh-worker-chips"></div>
    </div>
    <p class="hint">Hover to pause auto-scroll · click a row for the raw event · capped at 500 lines.</p>
    <div id="feed" role="log" aria-live="off" aria-relevant="additions"></div>
  `;
  kindChipsEl = root.querySelector('#fh-kind-chips');
  workerChipsEl = root.querySelector('#fh-worker-chips');
  feedEl = root.querySelector('#feed');
}

// --- filter chips ----------------------------------------------------------------------------

function renderKindChips() {
  if (!kindChipsEl) return;
  kindChipsEl.innerHTML = FH_KINDS.map((k) =>
    `<button type="button" class="fh-chip ${kindState[k] !== false ? 'on' : ''}" data-kind="${k}">${k.toUpperCase()}</button>`
  ).join('');
}

function renderWorkerChips() {
  if (!workerChipsEl) return;
  workerChipsEl.innerHTML = [...seenWorkers].map((w) =>
    `<button type="button" class="fh-chip ${workerState[w] !== false ? 'on' : ''}" data-worker="${esc(w)}" style="border-color:${colorFor(w)}">${esc(w)}</button>`
  ).join('');
}

function registerWorker(worker) {
  if (!worker || seenWorkers.has(worker)) return;
  seenWorkers.add(worker);
  renderWorkerChips();
}

/** Harvest worker ids already known from store (no invented names). */
function harvestWorkersFromStore() {
  let added = false;
  for (const entry of store.feed) {
    if (entry.worker && !seenWorkers.has(entry.worker)) {
      seenWorkers.add(entry.worker);
      added = true;
    }
  }
  for (const id of store.agents.keys()) {
    if (id && !seenWorkers.has(id)) {
      seenWorkers.add(id);
      added = true;
    }
  }
  if (added) renderWorkerChips();
}

function applyRowVisibility(el) {
  const visible = rowVisible(el.dataset.kind, el.dataset.worker);
  el.style.display = visible ? '' : 'none';
  if (!visible) {
    const next = el.nextElementSibling;
    if (next && next.classList.contains('fh-detail')) next.remove();
  }
}

function applyAllRowVisibility() {
  if (!feedEl) return;
  feedEl.querySelectorAll('.fh-row, .fh-raw').forEach(applyRowVisibility);
}

// --- row paint -------------------------------------------------------------------------------

/**
 * Inner HTML for a structured feed row — mirrors legacy rowInnerHtml, fed by data.js entry fields
 * (badge/cls/text/fam/mc/ts/live already resolved; no re-summarize here).
 */
function rowInnerHtml(entry) {
  const worker = entry.worker || '?';
  const timeStr = fmtTime(entry.ts);
  const fam = entry.fam;
  const mc = entry.mc || '#93a89c';
  const chip = fam
    ? `<span class="mchip" style="color:${esc(mc)}">${esc(fam)}</span>`
    : '<span class="mchip" style="visibility:hidden">·</span>';
  const spin = entry.live ? '<span class="fh-spin" aria-label="streaming">●</span>' : '';
  const cls = entry.cls || 'b-dim';
  const badge = entry.badge || 'unknown';
  const text = truncate(entry.text ?? '', SUM_TRUNCATE);
  return `
      <span class="fh-time">${esc(timeStr)}</span>
      <span class="fh-branch" style="color:${colorFor(worker)}">${esc(worker)}</span>
      ${chip}
      <span class="fh-badge ${esc(cls)}">${esc(badge)}</span>
      <span class="fh-sum">${esc(text)}${spin}</span>`;
}

function paintRow(el, entry) {
  const isRaw = entry.badge === 'raw' || entry.raw == null;
  if (isRaw) {
    el.className = 'fh-raw' + (entry.backfill ? ' fh-backfill' : '');
    el.dataset.kind = entry.kind || 'system';
    el.dataset.worker = entry.worker || '';
    el.textContent = truncate(entry.text ?? '', RAW_TEXT_TRUNCATE);
    if (entry.backfill) el.title = 'time = replay receipt';
    else el.removeAttribute('title');
    delete el.dataset.raw;
    delete el.dataset.truncated;
  } else {
    el.className = 'fh-row' + (entry.backfill ? ' fh-backfill' : '');
    el.dataset.kind = entry.kind || 'system';
    el.dataset.worker = entry.worker || '';
    el.innerHTML = rowInnerHtml(entry);
    if (entry.raw != null) el.dataset.raw = entry.raw;
    else delete el.dataset.raw;
    if (entry.truncated) el.dataset.truncated = '1';
    else delete el.dataset.truncated;
    if (entry.backfill) el.title = 'time = replay receipt';
    else el.removeAttribute('title');
  }
  applyRowVisibility(el);
}

function scrollToBottomIfNeeded() {
  if (!paused && feedEl) feedEl.scrollTop = feedEl.scrollHeight;
}

function capFeed() {
  if (!feedEl) return;
  let rows = feedEl.querySelectorAll('.fh-row, .fh-raw');
  while (rows.length > FEED_CAP) {
    const first = rows[0];
    for (const [entry, el] of entryEl) {
      if (el === first) {
        entryEl.delete(entry);
        break;
      }
    }
    const next = first.nextElementSibling;
    if (next && next.classList.contains('fh-detail')) next.remove();
    first.remove();
    rows = feedEl.querySelectorAll('.fh-row, .fh-raw');
  }
}

/**
 * data.js finalizeCoalesce sets entry.live = false without emitting feed:update. After any
 * append/update, re-paint rows whose live spinner state drifted from the entry.
 */
function syncLiveSpinners() {
  for (const entry of store.feed) {
    const el = entryEl.get(entry);
    if (!el || !el.classList.contains('fh-row')) continue;
    const hasSpin = !!el.querySelector('.fh-spin');
    if (!!entry.live !== hasSpin) paintRow(el, entry);
  }
}

// --- feed event handlers ---------------------------------------------------------------------

function onFeedAppend(ev) {
  const entry = ev.detail;
  if (!entry || !feedEl) return;
  registerWorker(entry.worker);

  // If we already mapped this object (shouldn't on append), re-paint in place.
  let el = entryEl.get(entry);
  if (!el) {
    el = document.createElement('div');
    entryEl.set(entry, el);
    feedEl.appendChild(el);
  }
  paintRow(el, entry);
  syncLiveSpinners();
  capFeed();
  scrollToBottomIfNeeded();
}

function onFeedUpdate(ev) {
  const entry = ev.detail;
  if (!entry || !feedEl) return;
  registerWorker(entry.worker);
  let el = entryEl.get(entry);
  if (!el) {
    // Update arrived before append mapping (or after cap eviction) — create at end.
    el = document.createElement('div');
    entryEl.set(entry, el);
    feedEl.appendChild(el);
  }
  paintRow(el, entry);
  // Collapse any open detail under this row — raw payload changed.
  const next = el.nextElementSibling;
  if (next && next.classList.contains('fh-detail')) next.remove();
  syncLiveSpinners();
  scrollToBottomIfNeeded();
}

function onFeedReset() {
  if (!feedEl) return;
  feedEl.innerHTML = '';
  entryEl.clear();
  // Keep seenWorkers (legacy reconnect did not wipe chips); re-harvest agents still present.
  harvestWorkersFromStore();
}

// --- expand raw JSON (legacy toggleExpand) ---------------------------------------------------

function toggleExpand(row) {
  const next = row.nextElementSibling;
  if (next && next.classList.contains('fh-detail')) {
    next.remove();
    return;
  }
  const raw = row.dataset.raw || '';
  let pretty = raw;
  if (row.dataset.truncated) {
    pretty = raw + '\n… (truncated, raw JSON not shown in full)';
  } else {
    try {
      pretty = JSON.stringify(JSON.parse(raw), null, 2);
    } catch {
      /* show as-is */
    }
  }
  const pre = document.createElement('pre');
  pre.className = 'fh-detail';
  pre.textContent = pretty;
  row.after(pre);
}

// --- bind interactions -----------------------------------------------------------------------

function bindEvents() {
  feedEl.addEventListener('mouseenter', () => {
    paused = true;
  });
  feedEl.addEventListener('mouseleave', () => {
    paused = false;
    feedEl.scrollTop = feedEl.scrollHeight;
  });

  // One delegated listener — no per-row closure pinning pretty-printed raw (legacy note).
  feedEl.addEventListener('click', (ev) => {
    const row = ev.target.closest('.fh-row');
    if (row && feedEl.contains(row)) toggleExpand(row);
  });

  kindChipsEl.addEventListener('click', (ev) => {
    const btn = ev.target.closest('.fh-chip');
    if (!btn) return;
    const k = btn.dataset.kind;
    kindState[k] = kindState[k] === false;
    saveJSON('unimatrix-fh-kinds', kindState);
    renderKindChips();
    applyAllRowVisibility();
  });

  workerChipsEl.addEventListener('click', (ev) => {
    const btn = ev.target.closest('.fh-chip');
    if (!btn) return;
    const w = btn.dataset.worker;
    workerState[w] = workerState[w] === false;
    saveJSON('unimatrix-fh-workers', workerState);
    renderWorkerChips();
    applyAllRowVisibility();
  });

  bus.addEventListener('feed:append', onFeedAppend);
  bus.addEventListener('feed:update', onFeedUpdate);
  bus.addEventListener('feed:reset', onFeedReset);
  // Agents can appear from /api/agents before any feed line — refresh worker chips.
  bus.addEventListener('data', () => {
    harvestWorkersFromStore();
  });
}

/**
 * Seed the DOM from store.feed already present at init (events that arrived before this module
 * subscribed). Object identity matches future feed:update mutations.
 */
function seedFromStore() {
  for (const entry of store.feed) {
    registerWorker(entry.worker);
    const el = document.createElement('div');
    entryEl.set(entry, el);
    feedEl.appendChild(el);
    paintRow(el, entry);
  }
  harvestWorkersFromStore();
  capFeed();
  // Seed is historical — do not force-scroll; leave at top unless empty was already bottom.
  if (store.feed.length) scrollToBottomIfNeeded();
}

// --- public API ------------------------------------------------------------------------------

/**
 * Mount the firehose into rootEl (#view-fire). Idempotent. Subscribes to bus feed:* and builds
 * chips + #feed once. Feed stays mounted for the life of the page.
 */
function init(rootEl) {
  if (!rootEl) return;
  if (inited && root === rootEl) return;
  root = rootEl;
  inited = true;
  buildShell();
  renderKindChips();
  renderWorkerChips();
  bindEvents();
  seedFromStore();
}

/**
 * Light refresh when main.js activates the view. Does NOT rebuild the feed DOM (scroll + expanded
 * rows must survive view switches). Only re-harvests worker chips from the current store.
 */
function render() {
  if (!root) return;
  harvestWorkersFromStore();
}

export { init, render };
export default { init, render };
