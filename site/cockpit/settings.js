/**
 * AGENTS settings drawer — GET/POST /api/config (the page's one config write surface).
 *
 * Project: unimatrix — multi-model swarm orchestrator driven from Claude Code
 * Module:  site/cockpit/settings.js
 * Deps:    format.js (esc, LANES); data.js (getConfigData, postConfigData); DOM
 * Tested:  tests/ground-control.bats (/api/config); tests/cockpit.bats (logic mirror)
 *
 * Key responsibilities:
 * - Render the exec-chain slot editor, review-lane select, and run-limit inputs inside
 *   #settings-drawer only (opened/closed by main.js via #hdr-gear).
 * - POST /api/config with the same {key,value} contract as the legacy cockpit; re-apply the
 *   full allowlisted snapshot from every response so sections never go stale.
 * - postConfigData() already refreshes the shared store on success (store.execChain / limits
 *   update app-wide) — this module never calls refreshConfig() itself.
 *
 * Design constraints:
 * - Port of legacy-cockpit.html AGENTS drawer logic — same fields, validation UX, and status
 *   messages. No fake data (FR-14): absent config fields render empty / blank inputs.
 * - Lane dropdown options come from format.LANES (supported-lane registry), never a hard-coded
 *   separate list and never inventing EXEC_CHAIN entries.
 * - Visibility / Esc-close owned by main.js; this module never binds global keys or toggles
 *   open/close itself. No DOM outside #settings-drawer.
 * - Prefer base.css atoms; scoped styles injected once under #settings-drawer (no settings.css).
 */

import { esc, LANES } from './format.js';
import { getConfigData, postConfigData } from './data.js';

// Supported lane registry for the dropdowns (same six lanes as LANES; order is stable for UX).
const AGENT_LANES = Object.keys(LANES);

let root = null;
let execSlots = []; // [{lane, model}] — mirrors the EXEC_CHAIN input rows
let stylesInjected = false;
let bound = false;

// --- scoped styles (plan allocates no settings.css) ----------------------------------------

function injectStyles() {
  if (stylesInjected) return;
  stylesInjected = true;
  const s = document.createElement('style');
  s.setAttribute('data-settings', '1');
  // Scoped under #settings-drawer only. Tokens match base.css / design §1.1.
  s.textContent = `
#settings-drawer{
  flex:none;display:none;flex-direction:column;gap:12px;
  padding:12px 16px;margin-bottom:10px;
  background:var(--surface,#0c120e);border:1px solid var(--line-strong,rgba(94,234,166,.28));
  border-radius:var(--radius,6px);
  font-family:var(--mono,"Share Tech Mono",ui-monospace,monospace);font-size:.8rem;
  color:var(--text,#e6f1ea);
}
#settings-drawer.open{display:flex}
#settings-drawer .drawer-section{border-top:1px solid var(--line,rgba(94,234,166,.13))}
#settings-drawer .drawer-section:first-child{border-top:none}
#settings-drawer .drawer-summary{
  cursor:pointer;list-style:none;padding:6px 0;
  font-size:.7rem;text-transform:uppercase;letter-spacing:.1em;color:var(--accent,#34d399);
  display:flex;align-items:center;gap:6px;
}
#settings-drawer .drawer-summary::-webkit-details-marker{display:none}
#settings-drawer .drawer-summary .chevron{display:inline-block;transition:transform .12s;font-size:.65rem}
#settings-drawer .drawer-section[open] .chevron{transform:rotate(90deg)}
#settings-drawer .drawer-body{display:flex;flex-direction:column;gap:6px;padding:6px 0 10px}
#settings-drawer .chain-row{display:flex;gap:6px;align-items:center}
#settings-drawer .chain-row select,
#settings-drawer .chain-row input,
#settings-drawer .num-field input{
  font-family:var(--mono,"Share Tech Mono",ui-monospace,monospace);font-size:.78rem;
  background:var(--surface-2,#101812);color:var(--text,#e6f1ea);
  border:1px solid var(--line,rgba(94,234,166,.13));border-radius:3px;padding:3px 6px;
}
#settings-drawer .chain-row select{min-width:88px}
#settings-drawer .chain-row input[type=text]{width:150px}
#settings-drawer .chain-row button,
#settings-drawer .drawer-btn{
  font-family:var(--mono,"Share Tech Mono",ui-monospace,monospace);font-size:.72rem;
  background:var(--surface-2,#101812);color:var(--muted,#93a89c);
  border:1px solid var(--line,rgba(94,234,166,.13));border-radius:3px;padding:3px 9px;cursor:pointer;
}
#settings-drawer .chain-row button:hover,
#settings-drawer .drawer-btn:hover{color:var(--text,#e6f1ea);border-color:var(--line-strong,rgba(94,234,166,.28))}
#settings-drawer .drawer-btn.save{
  color:var(--accent-ink,#052e1e);background:var(--accent,#34d399);border-color:var(--accent,#34d399)
}
#settings-drawer .drawer-row{display:flex;gap:8px;align-items:center;flex-wrap:wrap}
#settings-drawer .drawer-status{font-size:.72rem;color:var(--muted,#93a89c)}
#settings-drawer .drawer-status.ok{color:var(--accent,#34d399)}
#settings-drawer .drawer-status.err{color:#f97066}
#settings-drawer .num-field{display:flex;flex-direction:column;gap:3px}
#settings-drawer .num-field label{
  font-size:.66rem;color:var(--muted,#93a89c);text-transform:uppercase;letter-spacing:.06em
}
#settings-drawer .num-field input{width:90px}
#settings-drawer select#review-lane{
  font-family:var(--mono,"Share Tech Mono",ui-monospace,monospace);font-size:.78rem;
  background:var(--surface-2,#101812);color:var(--text,#e6f1ea);
  border:1px solid var(--line,rgba(94,234,166,.13));border-radius:3px;padding:3px 6px;min-width:88px;
}
#settings-drawer input#review-model{
  font-family:var(--mono,"Share Tech Mono",ui-monospace,monospace);font-size:.78rem;
  background:var(--surface-2,#101812);color:var(--text,#e6f1ea);
  border:1px solid var(--line,rgba(94,234,166,.13));border-radius:3px;padding:3px 6px;width:150px;
}
`;
  document.head.appendChild(s);
}

// --- pure helpers (ported verbatim) --------------------------------------------------------

function parseLaneModel(s) {
  const i = String(s).indexOf(':');
  return i === -1
    ? { lane: 'claude', model: String(s) }
    : { lane: String(s).slice(0, i), model: String(s).slice(i + 1) };
}

function laneOptions(selected) {
  return AGENT_LANES.map(
    (l) => `<option value="${esc(l)}"${l === selected ? ' selected' : ''}>${esc(l)}</option>`,
  ).join('');
}

function $(sel) {
  return root ? root.querySelector(sel) : null;
}

function setDrawerStatus(section, msg, isErr) {
  const el = $(`#${section}-status`);
  if (!el) return;
  el.textContent = msg || '';
  el.className = 'drawer-status' + (msg ? (isErr ? ' err' : ' ok') : '');
}

// --- DOM build -----------------------------------------------------------------------------

function buildShell() {
  const reviewOpts = AGENT_LANES.map(
    (l) => `<option value="${esc(l)}">${esc(l)}</option>`,
  ).join('');

  root.innerHTML = `
    <details class="drawer-section">
      <summary class="drawer-summary"><span class="chevron">▸</span>Exec chain (fallback order, left → right)</summary>
      <div class="drawer-body">
        <div id="exec-chain-slots"></div>
        <div class="drawer-row">
          <button type="button" class="drawer-btn" id="exec-chain-add">+ add lane</button>
          <button type="button" class="drawer-btn save" id="exec-chain-save">save</button>
          <span class="drawer-status" id="exec-status"></span>
        </div>
      </div>
    </details>

    <details class="drawer-section">
      <summary class="drawer-summary"><span class="chevron">▸</span>Review lane</summary>
      <div class="drawer-body">
        <div class="drawer-row">
          <select id="review-lane">${reviewOpts}</select>
          <input type="text" id="review-model" placeholder="model">
          <button type="button" class="drawer-btn save" id="review-save">save</button>
          <span class="drawer-status" id="review-status"></span>
        </div>
      </div>
    </details>

    <details class="drawer-section">
      <summary class="drawer-summary"><span class="chevron">▸</span>Run limits</summary>
      <div class="drawer-body">
        <div class="drawer-row">
          <div class="num-field"><label for="num-fanout">fanout</label><input type="number" min="0" id="num-fanout"></div>
          <div class="num-field"><label for="num-iterations">max iterations</label><input type="number" min="0" id="num-iterations"></div>
          <div class="num-field"><label for="num-timeout">worker timeout (s)</label><input type="number" min="0" id="num-timeout"></div>
          <div class="num-field"><label for="num-budget">budget (usd)</label><input type="number" min="0" id="num-budget"></div>
          <button type="button" class="drawer-btn save" id="nums-save">save</button>
          <span class="drawer-status" id="nums-status"></span>
        </div>
      </div>
    </details>
  `;
  root.setAttribute('aria-label', 'Agent lane settings');
}

function renderExecChain() {
  const slots = $('#exec-chain-slots');
  if (!slots) return;
  slots.innerHTML = execSlots.map((s, i) => `
      <div class="chain-row" data-i="${i}">
        <select class="lane-sel">${laneOptions(s.lane)}</select>
        <input type="text" class="model-in" value="${esc(s.model)}" placeholder="model">
        <button type="button" class="rm-btn" aria-label="remove lane">×</button>
      </div>`).join('');
}

// Capture current DOM edits back into execSlots before add/remove re-renders (so in-progress
// edits in other rows survive), and is also how save reads the values to POST.
function captureExecSlots() {
  const rows = root ? root.querySelectorAll('#exec-chain-slots .chain-row') : [];
  execSlots = [...rows].map((row) => ({
    lane: row.querySelector('.lane-sel').value,
    model: row.querySelector('.model-in').value,
  }));
}

// Every /api/config response (GET or POST) is the FULL allowlisted snapshot — apply it to all
// three sections every time so a save in one section never leaves the others stale.
function applyDrawerConfig(cfg) {
  cfg = cfg || {};
  execSlots = String(cfg.EXEC_CHAIN || '').split(/\s+/).filter(Boolean).map(parseLaneModel);
  renderExecChain();
  const rv = parseLaneModel(cfg.REVIEW || '');
  const reviewLane = $('#review-lane');
  const reviewModel = $('#review-model');
  if (reviewLane) {
    // If the saved lane isn't in the registry, leave the control as-is rather than inventing
    // an option — operator can pick a known lane. Prefer matching option when present.
    if (AGENT_LANES.includes(rv.lane)) reviewLane.value = rv.lane;
    else if (AGENT_LANES.length) reviewLane.value = AGENT_LANES[0];
  }
  if (reviewModel) reviewModel.value = rv.model;
  const fanout = $('#num-fanout');
  const iters = $('#num-iterations');
  const timeout = $('#num-timeout');
  const budget = $('#num-budget');
  // nullish → blank (FR-14: never invent numbers)
  if (fanout) fanout.value = cfg.FANOUT != null && cfg.FANOUT !== '' ? cfg.FANOUT : '';
  if (iters) iters.value = cfg.MAX_ITERATIONS != null && cfg.MAX_ITERATIONS !== '' ? cfg.MAX_ITERATIONS : '';
  if (timeout) timeout.value = cfg.WORKER_TIMEOUT_SEC != null && cfg.WORKER_TIMEOUT_SEC !== '' ? cfg.WORKER_TIMEOUT_SEC : '';
  if (budget) budget.value = cfg.BUDGET_USD != null && cfg.BUDGET_USD !== '' ? cfg.BUDGET_USD : '';
}

// postConfigData already POSTs {key,value} and refreshes the shared store on success.
function postConfig(key, value) {
  return postConfigData({ key, value });
}

async function loadDrawerConfig() {
  try {
    applyDrawerConfig(await getConfigData());
  } catch {
    setDrawerStatus('exec', 'failed to load config', true);
  }
}

// After a successful POST, push the snapshot into the form. postConfigData() already refreshed
// the shared store so OPS / grid / flight re-derive EXEC_CHAIN rows and limits.
function afterSave(cfg) {
  applyDrawerConfig(cfg);
}

function bindEvents() {
  if (bound || !root) return;
  bound = true;

  const addBtn = $('#exec-chain-add');
  if (addBtn) {
    addBtn.addEventListener('click', () => {
      captureExecSlots();
      execSlots.push({ lane: 'claude', model: '' });
      renderExecChain();
    });
  }

  const slots = $('#exec-chain-slots');
  if (slots) {
    slots.addEventListener('click', (ev) => {
      if (!ev.target.classList.contains('rm-btn')) return;
      captureExecSlots();
      const row = ev.target.closest('.chain-row');
      if (!row) return;
      execSlots.splice(Number(row.dataset.i), 1);
      renderExecChain();
    });
  }

  const execSave = $('#exec-chain-save');
  if (execSave) {
    execSave.addEventListener('click', async () => {
      captureExecSlots();
      const value = execSlots
        .filter((s) => s.model.trim())
        .map((s) => `${s.lane}:${s.model.trim()}`)
        .join(' ');
      try {
        await afterSave(await postConfig('EXEC_CHAIN', value));
        setDrawerStatus('exec', 'saved');
      } catch (e) {
        setDrawerStatus('exec', e.message || 'save failed', true);
      }
    });
  }

  const reviewSave = $('#review-save');
  if (reviewSave) {
    reviewSave.addEventListener('click', async () => {
      const lane = ($('#review-lane') && $('#review-lane').value) || 'claude';
      const model = ($('#review-model') && $('#review-model').value.trim()) || '';
      const value = `${lane}:${model}`;
      try {
        await afterSave(await postConfig('REVIEW', value));
        setDrawerStatus('review', 'saved');
      } catch (e) {
        setDrawerStatus('review', e.message || 'save failed', true);
      }
    });
  }

  const numsSave = $('#nums-save');
  if (numsSave) {
    numsSave.addEventListener('click', async () => {
      const fields = [
        ['FANOUT', '#num-fanout'],
        ['MAX_ITERATIONS', '#num-iterations'],
        ['WORKER_TIMEOUT_SEC', '#num-timeout'],
        ['BUDGET_USD', '#num-budget'],
      ];
      // Capture every field's value up front, before any await — applyDrawerConfig() below resets
      // these same inputs after each save, so reading mid-loop could pick up an already-reset value.
      const toSave = fields
        .map(([key, sel]) => {
          const el = $(sel);
          return [key, el ? el.value.trim() : ''];
        })
        .filter(([, v]) => v !== '');
      try {
        let cfg = null;
        for (const [key, v] of toSave) cfg = await postConfig(key, v);
        if (cfg) await afterSave(cfg);
        setDrawerStatus('nums', 'saved');
      } catch (e) {
        setDrawerStatus('nums', e.message || 'save failed', true);
      }
    });
  }
}

// --- public API ----------------------------------------------------------------------------

/**
 * Mount the settings form into rootEl (#settings-drawer). Idempotent.
 * main.js owns open/close (class .open) and Esc; call render() when opening so config reloads.
 */
function init(rootEl) {
  if (!rootEl) return;
  root = rootEl;
  injectStyles();
  buildShell();
  bindEvents();
}

/**
 * Reload config from GET /api/config and collapse all accordion sections.
 * Intended to be called by main.js when the drawer is opened (⚙ / #hdr-gear).
 * Does not toggle visibility — main.js owns that.
 */
function render() {
  if (!root) return;
  // Clear prior section statuses so a previous "saved"/"failed" doesn't linger across opens.
  setDrawerStatus('exec', '');
  setDrawerStatus('review', '');
  setDrawerStatus('nums', '');
  // All three accordion sections start collapsed every time the drawer opens (legacy UX).
  root.querySelectorAll('details.drawer-section').forEach((d) => { d.open = false; });
  loadDrawerConfig();
}

export default { init, render };
export { init, render };
