/**
 * Cockpit boot + chrome: view registry/switching, header + status-strip rendering, FR-20 alert notifications, ADD SPEC dialog, settings-drawer toggle, keyboard map, degrade wiring.
 *
 * Project: unimatrix — multi-model swarm orchestrator driven from Claude Code
 * Module:  site/cockpit/main.js
 * Deps:    data.js (store/ui/bus/start); ctl.js (ctl/armAbort); format.js (PURE helpers);
 *          view modules ops.js/grid.js/flight.js/firehose.js/drawer.js/settings.js
 * Tested:  n/a
 *
 * Key responsibilities:
 * - Boot: init every view + overlay module against its shell container, then start() the store.
 * - Own the header (#hdr-run/#hdr-dot/#hdr-pause/#hdr-add/#hdr-abort/#hdr-gear/#hdr-beep) and the
 *   status strip (#st-counts/#st-chips/#st-gate/#st-budget/#st-burn) — the ONLY module that
 *   touches this DOM (view modules never do, per the module contract).
 * - View switching: tab clicks + 1-4 keys (ignored while typing), unimatrix-view persistence,
 *   bus "nav" jumps. Esc priority: agent drawer -> settings drawer -> native <dialog>.
 * - FR-20: flash document.title + swap favicon on a NEW alert id; optional WebAudio beep.
 * - bus "degrade": hide the shell, show the local-only #notice (legacy wording, unchanged).
 *
 * Design constraints:
 * - Never touch DOM inside #view-ops/#view-grid/#view-flight/#view-fire/#agent-drawer/
 *   #settings-drawer — those are each view/overlay module's own territory.
 * - No fake data (FR-14): every strip/header value traces to store fields; absent → "—"/hidden.
 * - SSE recency for the health dot is inferred from bus "feed:append"/"feed:update"/"feed:reset"
 *   (data.js does not export its private sseLastSeen) — a deliberate proxy, not invented data.
 */

import { store, ui, bus, start, closeDrawer } from './data.js';
import { ctl, armAbort } from './ctl.js';
import { esc, fmtAge, loadJSON, saveJSON, LANES } from './format.js';
import ops from './ops.js';
import grid from './grid.js';
import flight from './flight.js';
import firehose from './firehose.js';
import drawer from './drawer.js';
import settings from './settings.js';
import speed from './speed.js';

// --- view registry + switching ----------------------------------------------------------------

const VIEWS = ['ops', 'grid', 'flight', 'fire', 'speed'];
const VIEW_CONTAINER_ID = {
  ops: 'view-ops', grid: 'view-grid', flight: 'view-flight', fire: 'view-fire', speed: 'view-speed',
};
const KEY_VIEW = { 1: 'ops', 2: 'grid', 3: 'flight', 4: 'fire', 5: 'speed' };

let currentView = 'ops';

function switchView(view) {
  if (!VIEWS.includes(view)) return;
  currentView = view;
  ui.view = view;
  for (const v of VIEWS) document.getElementById(VIEW_CONTAINER_ID[v]).hidden = v !== view;
  document.querySelectorAll('#hdr-tabs .tab').forEach((btn) => {
    btn.classList.toggle('active', btn.getAttribute('data-view') === view);
  });
  // SPEEDWARS reads a historical ledger, not the live bus — it fetches on activation only
  // (spec 09 FR-10), never on the render tick that drives the other views.
  if (view === 'speed') speed.render();
  saveJSON('unimatrix-view', { v: view });
}

// --- settings drawer open/close (main.js owns visibility; settings.js owns its own content) ----

let settingsOpen = false;
function setSettingsOpen(open) {
  settingsOpen = open;
  const el = document.getElementById('settings-drawer');
  el.hidden = !open;
  el.classList.toggle('open', open);
  if (open) settings.render();
}

// --- header: run/loop segment (FR-2, FR-17, FR-22 tooltip) -------------------------------------

function renderHdrRun(now) {
  const el = document.getElementById('hdr-run');
  const loop = store.loop;
  if (!loop || loop.run == null) {
    const elapsed = store.runStartedMs != null ? fmtAge((now - store.runStartedMs) / 1000) : '—';
    el.textContent = `run — · ${elapsed}`;
    el.title = '';
    return;
  }
  const startedMs = loop.started_ms != null ? loop.started_ms : store.runStartedMs;
  const elapsed = startedMs != null ? fmtAge((now - startedMs) / 1000) : '—';
  const iter = loop.iter != null ? loop.iter : '—';
  const max = loop.max != null ? loop.max : '—';
  el.textContent = `run ${loop.run} · loop ${iter}/${max} · ${elapsed}`;

  const stops = [];
  if (loop.max != null) stops.push(`${loop.max} iter max`);
  if (loop.budget_usd != null) stops.push(`$${loop.budget_usd} budget`);
  const stateTxt = loop.halted
    ? `HALTED${loop.halted_reason ? ': ' + loop.halted_reason : ''}`
    : (loop.complete ? 'COMPLETE' : 'running');
  el.title = `stops: ${stops.length ? stops.join(' · ') : '—'} · ${stateTxt} · steering ${loop.steering_bytes || 0}B`;
}

// --- header: SSE-health dot (FR-2) --------------------------------------------------------------
//
// data.js exposes store.sse {state,lastSeen} + emits bus "sse" event with contract:
// state: 'live'/'reconnecting'/'dead'. Dot states: green blinking (live + fresh),
// amber solid (reconnecting), red (dead/degraded).

function renderHdrDot(now) {
  const dot = document.getElementById('hdr-dot');
  dot.classList.remove('live', 'reconnect', 'degraded');
  if (!store.ok) { dot.classList.add('degraded'); return; }
  const sse = store.sse || {};
  if (sse.state === 'live' && sse.lastSeen != null && now - sse.lastSeen < 20000) {
    dot.classList.add('live');
    return;
  }
  if (sse.state === 'reconnecting') { dot.classList.add('reconnect'); return; }
  if (sse.state === 'dead') { dot.classList.add('degraded'); return; }
  dot.classList.add('reconnect');
}

// --- header: PAUSE ALL / RESUME (server-truth label, optimistic flip) --------------------------

function renderHdrPause() {
  const btn = document.getElementById('hdr-pause');
  btn.textContent = store.paused ? '▶ RESUME' : '‖ PAUSE ALL';
  btn.classList.toggle('on', !!store.paused);
}

function onPauseClick() {
  const wasPaused = !!store.paused;
  store.paused = !wasPaused; // optimistic flip; next poll reconciles to server truth
  renderHdrPause();
  ctl(wasPaused ? 'resume' : 'pause', {});
}

function renderHeader(now) {
  renderHdrRun(now);
  renderHdrDot(now);
  renderHdrPause();
}

// --- status strip (plan §5.3) -------------------------------------------------------------------

function fmtMoney(n) {
  return `$${Number(n).toFixed(2)}`;
}

function staleCount() {
  if (store.agentsOk) {
    let n = 0;
    for (const rec of store.agents.values()) if (rec.state === 'stale') n += 1;
    return n;
  }
  return (store.staleLeases && store.staleLeases.length) || 0;
}

function errCount() {
  let n = 0;
  for (const rec of store.agents.values()) if (rec.state === 'err') n += 1;
  return n;
}

function parkedCount() {
  return (store.parked && store.parked.length) || 0;
}

function renderCounts() {
  const c = store.counts || {};
  const chip = (n, label, cls) =>
    `<span class="chip${cls ? ' ' + cls : ''}"><b>${n != null ? esc(String(n)) : '—'}</b> ${esc(label)}</span>`;
  document.getElementById('st-counts').innerHTML =
    chip(c.queued, 'queued') + chip(c.claimed, 'claimed') + chip(c.done, 'done', 'ok') + chip(c.cancelled, 'cancelled');
}

function renderChips() {
  let html = '';
  if (store.paused) html += '<span class="chip blocked">‖ CLAIMS BLOCKED</span>';
  const stale = staleCount();
  const parked = parkedCount();
  if (stale > 0 || parked > 0) {
    html += `<span class="chip warn">⚠ <b>${stale}</b> stale · <b>${parked}</b> parked</span>`;
  }
  const err = errCount();
  if (err > 0) html += `<span class="chip err">✕ <b>${err}</b> erroring</span>`;
  document.getElementById('st-chips').innerHTML = html;
}

function renderGate() {
  const gate = store.gate || {};
  const den = gate.live;
  const el = document.getElementById('st-gate');
  if (den == null || den <= 0) {
    el.innerHTML = 'gate <span class="bar bar-gate"><i style="width:0%"></i><i style="width:0%"></i></span> <span>—</span>';
    return;
  }
  const done = gate.done || 0;
  const parked = gate.parked || 0;
  const donePct = Math.min(100, (done / den) * 100);
  const parkPct = Math.min(100 - donePct, (parked / den) * 100);
  el.innerHTML = `gate <span class="bar bar-gate"><i style="width:${donePct}%;background:var(--accent)"></i><i style="width:${parkPct}%;background:var(--amber)"></i></span> <span>${done + parked}/${den}</span>`;
}

function renderBudget() {
  const el = document.getElementById('st-budget');
  const spent = store.spentUsd;
  if (spent == null) {
    el.innerHTML = 'budget —';
    return;
  }
  const cap = Number(store.budgetUsd);
  if (!Number.isFinite(cap) || cap <= 0) {
    el.innerHTML = `budget <span>${fmtMoney(spent)} spent · no cap</span>`;
    return;
  }
  const pct = Math.min(100, (spent / cap) * 100);
  const color = pct > 80 ? 'var(--red)' : (pct > 60 ? 'var(--amber)' : 'var(--accent)');
  el.innerHTML = `budget <span class="bar bar-budget"><i style="width:${pct}%;background:${color}"></i></span> <span>${fmtMoney(spent)} / $${cap}</span>`;
}

// lane names in EXEC_CHAIN order — parsed directly (execLaneNames() is data.js-internal).
function execLaneNames() {
  const names = [];
  for (const lm of store.execChain || []) {
    const i = lm.indexOf(':');
    const name = i >= 0 ? lm.slice(0, i) : lm;
    if (!names.includes(name)) names.push(name);
  }
  return names;
}

function renderBurn() {
  let total = 0;
  for (const l of store.lanes.values()) total += l.burn || 0;
  let chips = '';
  for (const lane of execLaneNames()) {
    const l = store.lanes.get(lane);
    const info = LANES[lane] || { k: '?', color: 'var(--dim)' };
    chips += `<span class="lane-tag" style="color:${esc(info.color)}">${esc(info.k)} ${fmtMoney(l ? l.burn || 0 : 0)}</span>`;
  }
  document.getElementById('st-burn').innerHTML = `burn <b>${fmtMoney(total)}/min</b> ${chips}`;
}

function renderStrip() {
  renderCounts();
  renderChips();
  renderGate();
  renderBudget();
  renderBurn();
}

// --- FR-20: new-alert notification (title flash + favicon + optional beep) ---------------------

const BASE_TITLE = document.title;
const FAVICON_ALERT = "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'%3E%3Ccircle cx='8' cy='8' r='6' fill='%23e0b34a'/%3E%3C/svg%3E";
let faviconDefault = null;

let knownAlertIds = new Set();
let titleFlashTimer = null;
let beepEnabled = false;
let audioCtx = null;

function renderBeepButton() {
  const btn = document.getElementById('hdr-beep');
  btn.textContent = beepEnabled ? '♪ ON' : '♪ OFF';
  btn.classList.toggle('on', beepEnabled);
}

function loadBeepPref() {
  beepEnabled = !!loadJSON('unimatrix-beep', { v: false }).v;
  renderBeepButton();
}

function playBeep() {
  if (!beepEnabled) return;
  try {
    audioCtx = audioCtx || new (window.AudioContext || window.webkitAudioContext)();
    const osc = audioCtx.createOscillator();
    const gain = audioCtx.createGain();
    osc.type = 'sine';
    osc.frequency.value = 880;
    gain.gain.setValueAtTime(0.0001, audioCtx.currentTime);
    gain.gain.exponentialRampToValueAtTime(0.2, audioCtx.currentTime + 0.01);
    gain.gain.exponentialRampToValueAtTime(0.0001, audioCtx.currentTime + 0.18);
    osc.connect(gain).connect(audioCtx.destination);
    osc.start();
    osc.stop(audioCtx.currentTime + 0.2);
  } catch { /* WebAudio unavailable — non-fatal */ }
}

// flash document.title ⚠N↔normal 3 full cycles (6 toggles), then settle back to normal.
function flashTitle(n) {
  if (titleFlashTimer) return;
  const alertTitle = `⚠ ${n} — UNIMATRIX`;
  let toggles = 0;
  titleFlashTimer = setInterval(() => {
    document.title = document.title === alertTitle ? BASE_TITLE : alertTitle;
    toggles += 1;
    if (toggles >= 6) {
      clearInterval(titleFlashTimer);
      titleFlashTimer = null;
      document.title = BASE_TITLE;
    }
  }, 500);
}

function checkAlertNotifications() {
  const alerts = store.alerts || [];
  const ids = new Set(alerts.map((a) => a.id));
  let hasNew = false;
  for (const id of ids) if (!knownAlertIds.has(id)) hasNew = true;
  knownAlertIds = ids;

  const fav = document.getElementById('fav');
  if (fav) fav.href = alerts.length > 0 ? FAVICON_ALERT : faviconDefault;

  if (hasNew) {
    flashTitle(alerts.length);
    playBeep();
  }
}

// --- ADD SPEC dialog (FR-2 base + FR-22 lane pin / write grant) --------------------------------

function populateAddLaneOptions() {
  const sel = document.getElementById('add-lane');
  sel.innerHTML = '<option value="default">default (EXEC_CHAIN)</option>';
  for (const lm of store.execChain || []) {
    const i = lm.indexOf(':');
    const lane = i >= 0 ? lm.slice(0, i) : lm;
    if (lane === 'gemini') continue; // read-only lane — server refuses a gemini pin (FR-22)
    const opt = document.createElement('option');
    opt.value = lm;
    opt.textContent = lm;
    sel.appendChild(opt);
  }
}

function openAddDialog() {
  const form = document.getElementById('add-form');
  form.reset();
  populateAddLaneOptions();
  document.getElementById('add-dialog').showModal();
}

function onAddSubmit(e) {
  e.preventDefault();
  const id = document.getElementById('add-id').value.trim();
  const prompt = document.getElementById('add-prompt').value;
  const lane = document.getElementById('add-lane').value;
  const write = document.getElementById('add-write').value.trim();
  const payload = { id, prompt };
  if (lane && lane !== 'default') payload.lane = lane;
  if (write) payload.write = write;
  ctl('add', payload);
  document.getElementById('add-dialog').close();
}

// --- keyboard map + Esc priority (agent drawer -> settings drawer -> native <dialog>) -----------
// main.js is the SOLE document-level key handler. All keys early-return when focus is in a form
// element or any dialog/drawer is open (except for Esc, which always processes for drawer/dialog closing).

function onKeydown(e) {
  const tag = document.activeElement && document.activeElement.tagName;
  const inField = tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT';
  const addDialogOpen = document.getElementById('add-dialog').open;

  // View keys (1-4): only when not in a field and no drawer/dialog open
  if (!inField && !addDialogOpen && !ui.sel && !settingsOpen && KEY_VIEW[e.key]) {
    switchView(KEY_VIEW[e.key]);
    e.preventDefault();
    return;
  }

  // Esc handling: priority order agent-drawer -> settings-drawer -> add-dialog
  if (e.key === 'Escape') {
    if (ui.sel) { closeDrawer(); e.preventDefault(); return; }
    if (settingsOpen) { setSettingsOpen(false); e.preventDefault(); return; }
    if (addDialogOpen) { document.getElementById('add-dialog').close(); e.preventDefault(); return; }
    return;
  }

  // All other keys: suppress when in a form field or dialog/drawer open
  if (inField || addDialogOpen || ui.sel || settingsOpen) return;
}

// --- degrade (local-only notice; legacy wording unchanged) --------------------------------------

function onDegrade() {
  const shell = document.querySelector('.shell');
  if (shell) shell.hidden = true;
  const notice = document.getElementById('notice');
  if (notice) notice.hidden = false;
}

// --- bus "nav" (FR-18 pipeline click-filters land on the same bus grid.js already listens on) ----

function onNav(e) {
  if (e.detail && e.detail.view) switchView(e.detail.view);
}

// --- boot ----------------------------------------------------------------------------------------

function renderAll() {
  const now = Date.now();
  renderHeader(now);
  renderStrip();
  checkAlertNotifications();
}

function boot() {
  const fav = document.getElementById('fav');
  faviconDefault = fav ? fav.href : null;

  ops.init(document.getElementById('view-ops'));
  grid.init(document.getElementById('view-grid'));
  flight.init(document.getElementById('view-flight'));
  firehose.init(document.getElementById('view-fire'));
  speed.init(document.getElementById('view-speed'));
  drawer.init(document.getElementById('agent-drawer'));
  settings.init(document.getElementById('settings-drawer'));

  document.getElementById('hdr-tabs').addEventListener('click', (e) => {
    const btn = e.target.closest('.tab');
    if (btn) switchView(btn.getAttribute('data-view'));
  });
  document.addEventListener('keydown', onKeydown);

  document.getElementById('hdr-pause').addEventListener('click', onPauseClick);
  document.getElementById('hdr-add').addEventListener('click', openAddDialog);
  document.getElementById('add-cancel').addEventListener('click', () => document.getElementById('add-dialog').close());
  document.getElementById('add-form').addEventListener('submit', onAddSubmit);
  document.getElementById('hdr-gear').addEventListener('click', () => setSettingsOpen(!settingsOpen));
  document.getElementById('hdr-beep').addEventListener('click', () => {
    beepEnabled = !beepEnabled;
    saveJSON('unimatrix-beep', { v: beepEnabled });
    renderBeepButton();
  });
  armAbort(document.getElementById('hdr-abort'));
  loadBeepPref();

  bus.addEventListener('data', renderAll);
  bus.addEventListener('tick', renderAll);
  bus.addEventListener('nav', onNav);
  bus.addEventListener('degrade', onDegrade);

  const savedView = loadJSON('unimatrix-view', { v: 'ops' });
  switchView(VIEWS.includes(savedView.v) ? savedView.v : 'ops');

  renderAll(); // paint header/strip once before the first poll lands
  start();
}

boot();
