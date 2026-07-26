/**
 * Per-agent drill-in drawer: header/meta, stale alarm, 4 tabs, ctl footer buttons.
 *
 * Project: unimatrix — multi-model swarm orchestrator driven from Claude Code
 * Module:  site/cockpit/drawer.js
 * Deps:    format.js (esc, fmtTok, fmtTime, fmtAge, LANES, ageSecOf); data.js (store, ui, bus, select,
 *          closeDrawer, fetchAgentBodies); ctl.js (ctl)
 * Tested:  n/a
 *
 * Key responsibilities:
 * - Render ONLY inside #agent-drawer. Visible when ui.sel is set; hidden otherwise.
 * - Header: id + lane chip + meta segments (claimed age / tokens / notional $) — only when real.
 * - Amber alarm strip when derived state is stale (age + lease remaining).
 * - Tabs: events (per-agent buffer + silence divider), transcript (assembled), handoff/spec
 *   (GET /api/agent?id= cached per selection).
 * - Footer ctl verbs via ctl(): NUDGE / PAUSE↔RESUME / KILL / KILL+CANCEL / CANCEL.
 * - Re-render on bus "sel" / "data" / "tick"; ✕ → closeDrawer() (Esc is owned by main.js).
 *
 * Design constraints:
 * - No fake data (FR-14): absent ages/tokens/dollars/bodies omit or label — never invent.
 * - Never touch DOM outside #agent-drawer. All actions via ctl() / closeDrawer() / ui.dtab.
 * - Pixel truth = design/cockpit.dc.html drawer block; formulas from renderVals, real data.
 * - PAUSE/RESUME only while claimed (FR-8); CANCEL disabled while claimed; all disabled when
 *   done/cancelled (FR-12). Notional $ from rec.dollars only when >0 (FR-22).
 */

import { esc, fmtTok, fmtTime, fmtAge, LANES, ageSecOf } from './format.js';
import { store, ui, bus, closeDrawer, fetchAgentBodies } from './data.js';
import { ctl } from './ctl.js';

// --- module state ---------------------------------------------------------------------------

let root = null;
let bound = false;

// Cache of GET /api/agent bodies, keyed by selection id. Cleared when selection changes.
// Shape: { id, status: 'idle'|'loading'|'ok'|'err'|'empty', data: null|{spec,res,stderr}, err? }
let agentCache = { id: null, status: 'idle', data: null, err: null };
// Tabs that have already triggered a fetch for the current selection (fetch-on-open).
let fetchedFor = { id: null, handoff: false, spec: false };

const TABS = ['events', 'transcript', 'handoff', 'spec'];

// Transcript badges: client-assembled assistant prose (plan §5.3 drawer recipe).
const TRANSCRIPT_BADGES = new Set(['agent_message', 'text', 'thinking', 'message']);

// Text color dim for claim / tool_result style rows (design tc='#93a89c').
const DIM_TEXT_BADGES = new Set(['claim', 'tool_result', 'raw', 'system', 'progress', 'thinking', 'thinking_tokens', 'end']);

// --- age helpers -----------------------------------------------------------------------------

// claim age advances from the poll snapshot using the same srvAgeAt clock when available.
function claimAgeDisplay(rec, now) {
  if (rec.claimAgeSec == null) return null;
  if (rec.srvAgeAt != null) {
    return Math.max(0, rec.claimAgeSec + (now - rec.srvAgeAt) / 1000);
  }
  return rec.claimAgeSec;
}

// lease remaining ticks down between polls (never below 0).
function leaseRemainDisplay(rec, now) {
  if (rec.leaseRemainSec == null) return null;
  if (rec.srvAgeAt != null) {
    return Math.max(0, rec.leaseRemainSec - (now - rec.srvAgeAt) / 1000);
  }
  return Math.max(0, rec.leaseRemainSec);
}

function isClaimed(rec) {
  // Server state "claimed" = present under claimed/; derived state may be run/stale/err/paused.
  return rec.srvState === 'claimed';
}

function isTerminal(rec) {
  return rec.srvState === 'done' || rec.srvState === 'cancelled'
    || rec.state === 'done' || rec.state === 'cancelled';
}

// --- /api/agent cache -----------------------------------------------------------------------

function resetCache(id) {
  agentCache = { id: id || null, status: 'idle', data: null, err: null };
  fetchedFor = { id: id || null, handoff: false, spec: false };
}

function ensureAgentBodies(tab) {
  const id = ui.sel;
  if (!id) return;
  if (tab !== 'handoff' && tab !== 'spec') return;
  if (fetchedFor.id !== id) resetCache(id);
  if (tab === 'handoff' && fetchedFor.handoff) return;
  if (tab === 'spec' && fetchedFor.spec) return;

  // Mark both body tabs as "requested" once we fetch — one response covers both.
  fetchedFor.id = id;
  fetchedFor.handoff = true;
  fetchedFor.spec = true;

  if (agentCache.id === id && (agentCache.status === 'ok' || agentCache.status === 'err' || agentCache.status === 'loading')) {
    return;
  }

  agentCache = { id, status: 'loading', data: null, err: null };
  // Re-render to show loading placeholder if needed.
  render();

  fetchAgentBodies(id)
    .then((data) => {
      if (ui.sel !== id) return; // selection moved on
      agentCache = { id, status: 'ok', data, err: null };
      render();
    })
    .catch((e) => {
      if (ui.sel !== id) return;
      agentCache = {
        id,
        status: 'err',
        data: null,
        err: e && e.message ? e.message : 'network',
      };
      render();
    });
}

// --- meta line (only real segments) ---------------------------------------------------------

function buildMeta(rec, now) {
  const parts = [];
  const claimAge = claimAgeDisplay(rec, now);
  if (claimAge != null) {
    parts.push('claimed ' + fmtAge(claimAge));
  }
  // tokens: real count when shipped, else an explicit "—" (never omitted — plan §5.3 recipe).
  if (rec.tokens != null && Number.isFinite(rec.tokens) && rec.tokens > 0) {
    parts.push(fmtTok(rec.tokens) + ' tok');
  } else {
    parts.push('— tok');
  }
  // notional $ (FR-22): only when dollars > 0 — never invent a $0.00 line.
  if (rec.dollars != null && Number.isFinite(rec.dollars) && rec.dollars > 0) {
    parts.push('$' + rec.dollars.toFixed(2) + ' notional');
  }
  return parts.join(' · ');
}

// --- events tab -----------------------------------------------------------------------------

function badgeCls(entry) {
  if (entry && entry.cls) return entry.cls;
  const b = entry && entry.badge;
  if (b === 'tool_use') return 'b-blue';
  if (b === 'error' || b === 'turn.failed') return 'b-red';
  if (b === 'agent_message' || b === 'result' || b === 'message' || b === 'item.completed') return 'b-green';
  if (b === 'claim') return 'b-dim';
  return 'b-dim';
}

function renderEventsHtml(rec, now) {
  const events = Array.isArray(rec.events) ? rec.events : [];
  const age = ageSecOf(rec, now);
  let html = '';

  if (events.length === 0 && !(age != null && age > 60)) {
    html += '<div class="ad-empty">no events yet</div>';
  }

  for (const e of events) {
    const t = fmtTime(e.ts);
    const badge = e.badge || 'event';
    const cls = badgeCls(e);
    const dimTxt = DIM_TEXT_BADGES.has(badge) || cls === 'b-dim';
    const backfill = e.backfill ? ' backfill' : '';
    const title = e.backfill ? ' title="time = replay receipt"' : '';
    const rowCls = 'ad-ev' + backfill + (dimTxt ? ' dim-txt' : '');
    html += `<div class="${rowCls}"${title}>`
      + `<span class="ad-ev-t">${esc(t)}</span>`
      + `<span class="ad-ev-badge ${esc(cls)}">${esc(badge)}</span>`
      + `<span class="ad-ev-txt">${esc(e.text || '')}</span>`
      + `</div>`;
  }

  // Synthetic silence divider when age > 60s (plan §5.3 + design renderVals).
  if (age != null && age > 60) {
    const a = fmtAge(age);
    html += `<div class="ad-ev silence">`
      + `<span class="ad-ev-t"></span>`
      + `<span class="ad-ev-badge b-amber">silence</span>`
      + `<span class="ad-ev-txt">— no events for ${esc(a)} —</span>`
      + `</div>`;
  }

  return html;
}

// --- transcript tab -------------------------------------------------------------------------

function renderTranscriptHtml(rec) {
  const events = Array.isArray(rec.events) ? rec.events : [];
  const parts = [];
  for (const e of events) {
    if (!e || !TRANSCRIPT_BADGES.has(e.badge)) continue;
    const t = fmtTime(e.ts);
    const label = e.badge === 'thinking' ? 'THINKING' : 'ASSISTANT';
    const body = e.text || '';
    if (!body) continue;
    parts.push(label + ' · ' + t + '\n\n' + body);
  }
  if (parts.length === 0) {
    return '<div class="ad-empty">no transcript yet</div>';
  }
  return `<pre class="ad-pre present">${esc(parts.join('\n\n—\n\n'))}</pre>`;
}

// --- handoff / spec tabs --------------------------------------------------------------------

function renderBodyTab(kind) {
  // kind = 'handoff' | 'spec'
  const id = ui.sel;
  if (!id) return '';

  if (agentCache.id !== id || agentCache.status === 'idle' || agentCache.status === 'loading') {
    return '<div class="ad-empty">loading…</div>';
  }
  if (agentCache.status === 'err') {
    return `<div class="ad-empty">failed to load: ${esc(agentCache.err || 'error')}</div>`;
  }

  // ok with missing field (spec/res absent)
  const data = agentCache.data;
  if (kind === 'handoff') {
    const res = data && data.res;
    if (!res || res.text == null || res.text === '') {
      return '<div class="ad-empty">no handoff yet — written on finalize</div>';
    }
    const trunc = res.truncated
      ? '<span class="ad-trunc">(truncated)</span>'
      : '';
    return trunc + `<pre class="ad-pre present">${esc(res.text)}</pre>`;
  }

  // spec
  const spec = data && data.spec;
  if (!spec || spec.text == null || spec.text === '') {
    return '<div class="ad-empty">spec body unavailable</div>';
  }
  const trunc = spec.truncated
    ? '<span class="ad-trunc">(truncated)</span>'
    : '';
  return trunc + `<pre class="ad-pre present">${esc(spec.text)}</pre>`;
}

// --- footer button enablement ---------------------------------------------------------------

function footerFlags(rec) {
  const terminal = isTerminal(rec);
  const claimed = isClaimed(rec);
  return {
    // all disabled when done/cancelled
    allOff: terminal,
    // PAUSE/RESUME only while claimed (and not terminal)
    pauseOk: !terminal && claimed,
    // CANCEL is a queue/spec verb — disabled while claimed
    cancelOk: !terminal && !claimed,
    // NUDGE / KILL / KILL+CANCEL work on live agents (claimed/parked/queued) but not terminal
    actionOk: !terminal,
    frozen: !!rec.frozen,
  };
}

// --- render ---------------------------------------------------------------------------------

function render() {
  if (!root) return;

  const id = ui.sel;
  if (!id) {
    root.hidden = true;
    root.innerHTML = '';
    return;
  }

  root.hidden = false;
  const now = Date.now();
  const rec = store.agents.get(id);

  // Selection points at an id that vanished from the store — still show header + empty body so
  // the operator can close, never invent a record.
  if (!rec) {
    root.innerHTML = `
      <div class="ad-hdr">
        <span class="ad-id">${esc(id)}</span>
        <span class="ad-meta">—</span>
        <button type="button" class="ad-close" data-act="close" aria-label="Close">✕</button>
      </div>
      <div class="ad-body"><div class="ad-empty">agent not in current snapshot</div></div>
      <div class="ad-note">controls → POST /api/ctl → swarm-ctl · bus-only, never touches the worker pane · NUDGE = kill + requeue with hint · pause: frozen time still counts toward WORKER_TIMEOUT_SEC (long pause may time out on resume)</div>
    `;
    return;
  }

  const dtab = TABS.includes(ui.dtab) ? ui.dtab : 'events';
  if (ui.dtab !== dtab) ui.dtab = dtab;

  // Trigger body fetch when handoff/spec is the active tab.
  if (dtab === 'handoff' || dtab === 'spec') {
    // schedule after paint path — ensureAgentBodies may call render() again on resolve
    ensureAgentBodies(dtab);
  }

  const lane = rec.lane || null;
  const laneInfo = lane && LANES[lane] ? LANES[lane] : null;
  const laneColor = laneInfo ? laneInfo.color : '#93a89c';
  const laneHtml = lane
    ? `<span class="ad-lane" style="color:${esc(laneColor)};border-color:${esc(laneColor)}">${esc(lane)}</span>`
    : '';

  const meta = buildMeta(rec, now);
  const metaHtml = meta
    ? `<span class="ad-meta">${esc(meta)}</span>`
    : `<span class="ad-meta"></span>`;

  // Alarm strip: derived-stale only.
  let alarmHtml = '';
  if (rec.state === 'stale') {
    const age = ageSecOf(rec, now);
    const lease = leaseRemainDisplay(rec, now);
    const ageStr = age != null ? fmtAge(age) : '—';
    let sub = '';
    if (lease != null) {
      sub = `<div class="ad-alarm-sub">lease expires in ${esc(fmtAge(lease))} → reaper requeues</div>`;
    }
    alarmHtml = `<div class="ad-alarm">`
      + `<div class="ad-alarm-title">last event ${esc(ageStr)} ago</div>`
      + sub
      + `</div>`;
  }

  // Tabs
  let tabsHtml = '<div class="ad-tabs" role="tablist">';
  for (const t of TABS) {
    const active = t === dtab ? ' active' : '';
    tabsHtml += `<button type="button" class="ad-tab${active}" data-tab="${t}" role="tab" aria-selected="${t === dtab}">${t}</button>`;
  }
  tabsHtml += '</div>';

  // Body by tab
  let bodyInner = '';
  if (dtab === 'events') bodyInner = renderEventsHtml(rec, now);
  else if (dtab === 'transcript') bodyInner = renderTranscriptHtml(rec);
  else if (dtab === 'handoff') bodyInner = renderBodyTab('handoff');
  else if (dtab === 'spec') bodyInner = renderBodyTab('spec');

  const f = footerFlags(rec);
  const pauseLabel = f.frozen ? 'RESUME' : 'PAUSE';
  const dis = (ok) => (f.allOff || !ok) ? ' disabled' : '';

  const footHtml = `
    <div class="ad-foot">
      <button type="button" class="ad-btn nudge" data-act="nudge"${dis(f.actionOk)}>NUDGE</button>
      <button type="button" class="ad-btn pause" data-act="pause"${dis(f.pauseOk)}>${pauseLabel}</button>
      <button type="button" class="ad-btn kill" data-act="kill"${dis(f.actionOk)}>KILL</button>
      <button type="button" class="ad-btn kill" data-act="kill-cancel"${dis(f.actionOk)}>KILL+CANCEL</button>
      <button type="button" class="ad-btn cancel" data-act="cancel"${dis(f.cancelOk)}>CANCEL</button>
    </div>
    <div class="ad-note">controls → POST /api/ctl → swarm-ctl · bus-only, never touches the worker pane · NUDGE = kill + requeue with hint · pause: frozen time still counts toward WORKER_TIMEOUT_SEC (long pause may time out on resume)</div>
  `;

  root.innerHTML = `
    <div class="ad-hdr">
      <span class="ad-id">${esc(rec.id)}</span>
      ${laneHtml}
      ${metaHtml}
      <button type="button" class="ad-close" data-act="close" aria-label="Close">✕</button>
    </div>
    ${alarmHtml}
    ${tabsHtml}
    <div class="ad-body" role="tabpanel">${bodyInner}</div>
    ${footHtml}
  `;
}

// --- events / actions -----------------------------------------------------------------------

function onClick(ev) {
  const t = ev.target;
  if (!(t instanceof Element)) return;
  const closeBtn = t.closest('[data-act="close"]');
  if (closeBtn && root.contains(closeBtn)) {
    closeDrawer();
    return;
  }
  const tabBtn = t.closest('[data-tab]');
  if (tabBtn && root.contains(tabBtn)) {
    const tab = tabBtn.getAttribute('data-tab');
    if (TABS.includes(tab)) {
      ui.dtab = tab;
      render();
    }
    return;
  }
  const actBtn = t.closest('[data-act]');
  if (!actBtn || !root.contains(actBtn) || actBtn.disabled) return;
  const act = actBtn.getAttribute('data-act');
  const id = ui.sel;
  if (!id || act === 'close') return;

  if (act === 'nudge') {
    ctl('nudge', { id });
  } else if (act === 'pause') {
    const rec = store.agents.get(id);
    if (rec && rec.frozen) ctl('resume-worker', { id });
    else ctl('pause-worker', { id });
  } else if (act === 'kill') {
    ctl('kill', { id });
  } else if (act === 'kill-cancel') {
    ctl('kill', { id, cancel: true });
  } else if (act === 'cancel') {
    ctl('cancel', { id });
  }
}

function onSel() {
  const id = ui.sel;
  if (!id) {
    resetCache(null);
    render();
    return;
  }
  // Fresh selection → reset body cache + default tab is set by select() in data.js.
  if (agentCache.id !== id) resetCache(id);
  render();
}

// --- public API -----------------------------------------------------------------------------

function init(rootEl) {
  root = rootEl;
  if (!root) return;
  if (!bound) {
    bound = true;
    root.addEventListener('click', onClick);
    bus.addEventListener('sel', onSel);
    bus.addEventListener('data', () => render());
    bus.addEventListener('tick', () => {
      if (ui.sel) render();
    });
  }
  render();
}

export default { init, render };
export { init, render };
