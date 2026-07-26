/**
 * OPS WALL view — verdict, alerts, THE BUS pipeline, heat strip, burn chart, MODELS strip.
 *
 * Project: unimatrix — multi-model swarm orchestrator driven from Claude Code
 * Module:  site/cockpit/ops.js
 * Deps:    format.js (PURE helpers + LANES/MODEL_COLORS/heatStyle); data.js (store/ui/bus/select/
 *          ringArr); ctl.js (ctl)
 * Tested:  tests/cockpit.bats (logic mirror); playwright Lane-A QA (plan §5.5)
 *
 * Key responsibilities:
 * - Render view 1 (OPS WALL) exclusively inside #view-ops: row1 verdict+alerts, row2 bus pipeline,
 *   row3 heat+burn, row4 MODELS strip (ported legacy .mcell).
 * - Feed every cell from real store data (FR-14); absent → "—" / hide / labeled empty — never invent.
 * - Wire FR-18 click-filters (QUEUE/DONE/PARKED/lane → bus "nav") and alert/ctl actions.
 * - Re-render on bus "data" + "tick" (live ages, pulses, TTL countdowns).
 *
 * Design constraints:
 * - Pixel truth = plans/002-cockpit-redesign/design/cockpit.dc.html ops main; no sc-if/sc-for DSL.
 * - NEVER touch DOM outside #view-ops. All actions via ctl()/select()/bus "nav".
 * - Lane rows + VERIFY letters from EXEC_CHAIN / VERIFY_MAP only (FR-16) — never hardcoded lanes.
 * - Verdict ETA only when trailing-10min done rate > 0 (FR-17). Alert cards max 3 + "+N more →".
 */

import {
  esc, fmtTok, fmtAge, pulseStr, MODEL_COLORS, modelColor, heatStyle, LANES, ageSecOf,
} from './format.js';
import { store, bus, select, ringArr } from './data.js';
import { ctl } from './ctl.js';

// --- module state ---------------------------------------------------------------------------

let root = null;
let bound = false;

// heatStyle/tileStyle use short keys (q/park); deriveState returns server names (queued/parked).
function heatKey(state) {
  if (state === 'queued') return 'q';
  if (state === 'parked') return 'park';
  return state;
}

function isClaimedState(st) {
  return st === 'run' || st === 'stale' || st === 'err' || st === 'paused';
}

function isParkedState(st) {
  return st === 'park' || st === 'parked';
}

function isQueuedState(st) {
  return st === 'q' || st === 'queued';
}

// family → lane (same fold as data.js) for per-lane $/min from store.models.
function familyToLane(fam) {
  if (!fam) return null;
  if (fam === 'codex' || fam === 'glm' || fam === 'gemini' || fam === 'grok' || fam === 'kimi') return fam;
  if (String(fam).startsWith('claude')) return 'claude';
  return null;
}

// EXEC_CHAIN lane names in order (+ REVIEW if present and not already listed). Never invent.
function pipelineLaneNames() {
  const names = [];
  for (const lm of store.execChain || []) {
    const s = String(lm);
    const i = s.indexOf(':');
    const lane = i >= 0 ? s.slice(0, i) : s;
    if (lane && !names.includes(lane)) names.push(lane);
  }
  const rev = String(store.config.REVIEW || '');
  if (rev) {
    const i = rev.indexOf(':');
    const lane = i >= 0 ? rev.slice(0, i) : rev;
    if (lane && !names.includes(lane)) names.push(lane);
  }
  return names;
}

// The REVIEW-config lane name, but ONLY when it's the "+1" row pipelineLaneNames() appended
// beyond EXEC_CHAIN (never hardcode which lane plays REVIEW — config-driven, FR-16). A lane that
// is both an EXEC_CHAIN entry and REVIEW renders as an ordinary pipeline row — nothing extra.
function reviewOnlyLaneName() {
  const execNames = new Set();
  for (const lm of store.execChain || []) {
    const s = String(lm);
    const i = s.indexOf(':');
    const lane = i >= 0 ? s.slice(0, i) : s;
    if (lane) execNames.add(lane);
  }
  const rev = String(store.config.REVIEW || '');
  if (!rev) return null;
  const i = rev.indexOf(':');
  const lane = i >= 0 ? rev.slice(0, i) : rev;
  return lane && !execNames.has(lane) ? lane : null;
}

// VERIFY letters from store.verifyPairs / VERIFY_MAP — never hardcoded (FR-16).
function verifyLetters() {
  const pairs = store.verifyPairs || [];
  if (!pairs.length) return '—';
  return pairs.map(([a, b]) => {
    const ka = (LANES[a] && LANES[a].k) || a || '?';
    const kb = (LANES[b] && LANES[b].k) || b || '?';
    return `${ka}→${kb}`;
  }).join(' ');
}

// Queue trend from queueLen ring. Flat "···" until any real sample history exists.
function queueTrendText() {
  const arr = ringArr(store.series.queueLen);
  const hasHistory = arr.some((v) => v > 0) || (store.counts.queued != null && store.counts.queued > 0);
  // Still all-zero with a known-empty queue after rotations is real flat; until the ring has
  // ever held a non-zero OR counts.queued is a number, show ··· (absent data).
  if (store.counts.queued == null && !arr.some((v) => v > 0)) return '···';
  const recent = arr.slice(-6);
  const u8 = new Uint8Array(6);
  let peak = 0;
  for (let i = 0; i < recent.length; i++) if (recent[i] > peak) peak = recent[i];
  for (let i = 0; i < 6; i++) {
    const v = recent[i] != null ? recent[i] : 0;
    u8[i] = peak > 0 ? Math.min(255, Math.round((v / peak) * 255)) : 0;
  }
  if (!hasHistory && peak === 0) return '···';
  return `${pulseStr(u8)} trend`;
}

// FR-17: rate = dones with done_ms in trailing 10 min; eta only when rate > 0.
function etaSegment(now, remaining) {
  if (remaining == null || remaining <= 0) return '';
  const windowMs = 10 * 60 * 1000;
  let dones = 0;
  for (const rec of store.agents.values()) {
    if (rec.doneMs != null && now - rec.doneMs <= windowMs) dones += 1;
  }
  if (dones <= 0) return '';
  const ratePerMin = dones / 10;
  if (!(ratePerMin > 0)) return '';
  const mins = Math.max(1, Math.ceil(remaining / ratePerMin));
  return ` · est ~${mins}m left`;
}

function fmtUsd(n) {
  if (n == null || !Number.isFinite(n)) return '—';
  return n >= 100 ? `$${Math.round(n)}` : `$${Number(n).toFixed(2)}`;
}

function fmtBurnMin(n) {
  if (n == null || !Number.isFinite(n)) return '—';
  return `$${Number(n).toFixed(2)}/min`;
}

// Per-lane burn $/min from store.models families (normalize via family fold).
function laneBurns() {
  const map = new Map();
  for (const m of store.models || []) {
    const lane = familyToLane(m.model);
    if (!lane) continue;
    map.set(lane, (map.get(lane) || 0) + (m.dollars_per_hour || 0) / 60);
  }
  return map;
}

// Aggregate per-lane claimed/parked/pulse/silent from agents (real state names).
function laneAgg(lane) {
  const pulse = new Uint8Array(6);
  let claimed = 0;
  let parked = 0;
  const silent = []; // {id, age}
  for (const rec of store.agents.values()) {
    if (rec.lane !== lane) continue;
    const st = rec.state;
    if (isClaimedState(st)) claimed += 1;
    if (isParkedState(st)) parked += 1;
    if (st === 'stale') {
      const age = ageSecOf(rec, Date.now());
      silent.push({ id: rec.id, age: age != null ? age : -1 });
    }
    for (let i = 0; i < 6; i++) pulse[i] = Math.min(255, pulse[i] + (rec.buckets[i] || 0));
  }
  silent.sort((a, b) => b.age - a.age);
  return { claimed, parked, pulse, silent };
}

function limitTtl(lane) {
  for (const lim of store.limits || []) {
    if (lim.lane === lane && lim.expires_in_sec != null) return lim.expires_in_sec;
  }
  return null;
}

// Lane extra status: .limited / silent / parked / gemini read-only / REVIEW-only row — never
// invent ids.
function laneExtra(lane, agg, isReviewOnly) {
  const parts = [];
  let color = '#93a89c';
  const ttl = limitTtl(lane);
  if (ttl != null) {
    parts.push(`.limited · ${fmtAge(ttl)} left`);
    color = '#f97066';
  }
  if (agg.silent.length) {
    parts.push(`⚠ ${agg.silent[0].id} silent`);
    if (color !== '#f97066') color = '#e0b34a';
  }
  if (agg.parked > 0) {
    parts.push(`${agg.parked} parked`);
    if (color !== '#f97066') color = '#e0b34a';
  }
  if (lane === 'gemini' && !parts.length) {
    parts.push('read-only lane');
    color = '#93a89c';
  }
  // The REVIEW-only pipeline row (plan §5.3): distinguish it from a regular EXEC_CHAIN row so it
  // doesn't read as just another generator lane.
  if (isReviewOnly && !parts.length) {
    parts.push('review · read-only');
    color = '#93a89c';
  }
  return { text: parts.join(' · '), color };
}

// --- render pieces --------------------------------------------------------------------------

function renderVerdict(now) {
  const alerts = store.alerts || [];
  const clear = alerts.length === 0;
  let cRun = 0;
  let cQ = 0;
  let cDone = 0;
  let cPark = 0;
  for (const rec of store.agents.values()) {
    const st = rec.state;
    // WORKING / running = derived "run" only — not stale/err/paused (claimed-but-not-working).
    if (st === 'run') cRun += 1;
    else if (isQueuedState(st)) cQ += 1;
    else if (st === 'done') cDone += 1;
    else if (isParkedState(st)) cPark += 1;
  }
  // Prefer live counts from the bus when agents map is empty/incomplete.
  const queued = store.counts.queued != null ? store.counts.queued : cQ;
  const done = store.counts.done != null ? store.counts.done : cDone;
  const total = store.gate && store.gate.live != null ? store.gate.live : null;
  const totalTxt = total != null ? String(total) : '—';
  const remaining = total != null ? Math.max(0, total - done - (store.counts.parked != null ? store.counts.parked : cPark)) : null;
  const eta = etaSegment(now, remaining);

  const verdictTxt = clear
    ? `ALL CLEAR — ${cRun} WORKING`
    : `⚠ ${alerts.length} NEED ATTENTION`;
  const verdictC = clear ? '#34d399' : '#e0b34a';

  return `<div class="ops-verdict">
    <div class="ops-label dim">swarm status</div>
    <div class="ops-verdict-txt" style="color:${verdictC}">${esc(verdictTxt)}</div>
    <div class="ops-verdict-sub">${cRun} running · ${queued} queued · <span class="ops-done-frac">${done}/${totalTxt} done</span>${esc(eta)}</div>
  </div>`;
}

function renderAlerts() {
  const alerts = store.alerts || [];
  if (!alerts.length) {
    return `<div class="ops-alerts">
      <div class="ops-alerts-empty">no alerts — swarm humming, go make coffee</div>
    </div>`;
  }
  const show = alerts.slice(0, 3);
  const more = alerts.length - 3;
  let html = '<div class="ops-alerts">';
  for (const al of show) {
    const hasVerb = al.ctl && al.ctl.verb;
    const verbBtn = hasVerb
      ? `<button type="button" class="ops-al-verb" data-act="alert-ctl" data-id="${esc(al.id)}" style="color:${esc(al.c)};border-color:${esc(al.bc)}">${esc(al.verb || 'act')}</button>`
      : (al.nav
        ? `<button type="button" class="ops-al-verb" data-act="alert-nav" data-id="${esc(al.id)}" style="color:${esc(al.c)};border-color:${esc(al.bc)}">${esc(al.verb || 'inspect')}</button>`
        : '');
    const inspect = al.pick
      ? `<button type="button" class="ops-al-inspect" data-act="select" data-id="${esc(al.pick)}">inspect →</button>`
      : (al.nav
        ? `<button type="button" class="ops-al-inspect" data-act="alert-nav" data-id="${esc(al.id)}">inspect →</button>`
        : '');
    html += `<div class="ops-alert" style="border-color:${esc(al.bc)}">
      <div class="ops-alert-head">${esc(al.id)} <span style="color:${esc(al.c)}">${esc(al.title)}</span></div>
      <div class="ops-alert-sub">${esc(al.sub || '')}</div>
      <div class="ops-alert-actions">${verbBtn}${inspect}</div>
    </div>`;
  }
  if (more > 0) {
    html += `<button type="button" class="ops-more-chip" data-act="nav-attn">+${more} more →</button>`;
  }
  html += '</div>';
  return html;
}

function renderPipeline(now) {
  const specs = store.gate && store.gate.live != null ? store.gate.live : '—';
  const queued = store.counts.queued != null ? store.counts.queued : '—';
  const done = store.counts.done != null ? store.counts.done : '—';
  const cancelled = store.counts.cancelled != null ? store.counts.cancelled : 0;
  const parkedN = store.counts.parked != null
    ? store.counts.parked
    : (store.parked && store.parked.length) || 0;

  const paused = !!store.paused;
  const valveTxt = paused ? '‖ PAUSED — claims blocked' : '‖ pause valve';
  const valveC = paused ? '#e0b34a' : '#93a89c';
  const trend = queueTrendText();

  // DONE newest
  let newestLine = '—';
  const newestId = (store.doneRecent && store.doneRecent[0]) || null;
  if (newestId) {
    const rec = store.agents.get(newestId);
    if (rec && rec.doneMs != null) {
      newestLine = `${newestId} · ${fmtAge((now - rec.doneMs) / 1000)}`;
    } else {
      newestLine = String(newestId);
    }
  }

  // GATE num/den
  const den = store.gate && store.gate.live != null ? store.gate.live : null;
  const gDone = store.gate && store.gate.done != null ? store.gate.done : (store.counts.done || 0);
  const gPark = store.gate && store.gate.parked != null ? store.gate.parked : parkedN;
  const num = (Number(gDone) || 0) + (Number(gPark) || 0);
  let gateTxt = '—';
  let gateStatus = '';
  if (den != null) {
    gateTxt = `${num}/${den}`;
    gateStatus = num >= den ? 'open' : 'holding';
  }

  const burns = laneBurns();
  const laneNames = pipelineLaneNames();
  const reviewOnly = reviewOnlyLaneName();
  let laneHtml = '';
  if (!laneNames.length) {
    laneHtml = '<div class="ops-lane-empty">— no EXEC_CHAIN</div>';
  } else {
    for (const lane of laneNames) {
      const info = LANES[lane] || { k: '?', color: '#93a89c' };
      const agg = laneAgg(lane);
      // Burn: prefer store.lanes (same family fold); claimed/parked/silent from our scan
      // (store.lanes uses short state keys that miss server 'parked'/'queued' names).
      const laneRec = store.lanes && store.lanes.get(lane);
      const burnVal = (laneRec && laneRec.burn) || burns.get(lane) || 0;
      const pulse = laneRec && laneRec.pulse ? pulseStr(laneRec.pulse) : pulseStr(agg.pulse);
      const claimed = agg.claimed;
      const extra = laneExtra(lane, { parked: agg.parked, silent: agg.silent }, lane === reviewOnly);
      laneHtml += `<div class="ops-lane" data-act="nav-lane" data-lane="${esc(lane)}" style="border-left-color:${esc(info.color)}" title="filter grid by ${esc(lane)}">
        <span class="ops-lane-name" style="color:${esc(info.color)}">${esc(lane)}</span>
        <span class="ops-lane-n">×${claimed}</span>
        <span class="ops-lane-pulse">${esc(pulse)}</span>
        <span class="ops-lane-burn">${esc(fmtBurnMin(burnVal))}</span>
        <span class="ops-lane-extra" style="color:${esc(extra.color)}">${esc(extra.text)}</span>
      </div>`;
    }
  }

  const verify = verifyLetters();

  return `<div class="ops-bus">
    <div class="ops-section-title">the bus — specs/ → queue/ → claimed/ → done/</div>
    <div class="ops-pipe">
      <div class="ops-node">
        <div class="ops-node-lbl">SPECS</div>
        <div class="ops-node-n">${esc(String(specs))}</div>
        <div class="ops-node-sub">by Fable</div>
      </div>
      <span class="ops-arrow">──▶</span>
      <div class="ops-node-wrap">
        <div class="ops-node ops-clickable" data-act="nav-filter" data-filter="QUEUED" title="Mission Control · QUEUED">
          <div class="ops-node-lbl">QUEUE</div>
          <div class="ops-node-n">${esc(String(queued))}</div>
          <div class="ops-node-sub ops-trend">${esc(trend)}</div>
        </div>
        <div class="ops-valve" data-act="pause-toggle" style="color:${valveC};border-color:${valveC}">${esc(valveTxt)}</div>
      </div>
      <div class="ops-arrow-stack"><span class="ops-atomic">atomic<br>rename</span><span class="ops-arrow">──▶</span></div>
      <div class="ops-lanes">${laneHtml}</div>
      <span class="ops-arrow">──▶</span>
      <div class="ops-node ops-node-dash">
        <div class="ops-node-lbl">HANDOFF</div>
        <div class="ops-node-mid">res-*.txt</div>
        <div class="ops-node-sub">never scraped</div>
      </div>
      <span class="ops-arrow">──▶</span>
      <div class="ops-node ops-node-done ops-clickable" data-act="nav-filter" data-filter="DONE" title="Mission Control · DONE">
        <div class="ops-node-lbl">DONE</div>
        <div class="ops-node-n ops-n-green">${esc(String(done))}</div>
        <div class="ops-node-sub">newest ${esc(newestLine)}</div>
      </div>
      <span class="ops-arrow">──▶</span>
      <div class="ops-node ops-node-gate">
        <div class="ops-node-lbl">GATE</div>
        <div class="ops-node-mid">done+parked ≥ live</div>
        <div class="ops-node-sub ops-gate-status">${esc(gateTxt)}${gateStatus ? ` — ${gateStatus}` : ''}</div>
      </div>
      <span class="ops-arrow">──▶</span>
      <div class="ops-node ops-node-verify">
        <div class="ops-node-lbl">VERIFY</div>
        <div class="ops-node-mid">${esc(verify)}</div>
        <div class="ops-node-sub">judge ≠ executor</div>
      </div>
      <span class="ops-arrow">──▶</span>
      <div class="ops-node">
        <div class="ops-node-lbl">SYNTH</div>
        <div class="ops-node-mid">Fable</div>
        <div class="ops-node-sub">adjudicates</div>
      </div>
    </div>
    <div class="ops-pipe-chips">
      <button type="button" class="ops-pchip ops-pchip-park" data-act="nav-filter" data-filter="ATTN">▣ PARKED ${parkedN} (lane caps)</button>
      <span class="ops-pchip">⊘ CANCELLED ${cancelled}</span>
      <span class="ops-pchip">↻ reaper requeues dead leases</span>
    </div>
  </div>`;
}

function renderHeat(now) {
  const agents = [...store.agents.values()].sort((a, b) => String(a.id).localeCompare(String(b.id)));
  const n = agents.length;
  let cells = '';
  if (!n) {
    cells = '<span class="ops-heat-empty">— no agents yet</span>';
  } else {
    for (const rec of agents) {
      const age = ageSecOf(rec, now);
      const st = heatKey(rec.state);
      const style = heatStyle(st, age);
      const ageTxt = age != null ? fmtAge(age) : '—';
      const act = (rec.lastSummary && rec.lastSummary.text)
        || rec.lastActivity
        || rec.state
        || '—';
      const tip = `${rec.id} · ${ageTxt} · ${act}`;
      cells += `<span class="ops-heat-cell" data-act="select" data-id="${esc(rec.id)}" title="${esc(tip)}" style="background:${style.bg};border-color:${style.bd || 'transparent'}"></span>`;
    }
  }
  const title = n ? `all ${n} agents · age since last event` : 'agents · age since last event';
  return `<div class="ops-heat">
    <div class="ops-section-title">${esc(title)}</div>
    <div class="ops-heat-grid">${cells}</div>
    <div class="ops-heat-legend"><span class="ops-lg-fresh">■ fresh</span> → <span class="ops-lg-aging">■ aging</span> → <span class="ops-lg-stale">■ stale</span> → <span class="ops-lg-stuck">■ stuck</span> · ■ done(dim) · □ queued — click a cell to inspect</div>
  </div>`;
}

function renderBurn(now) {
  const burns = ringArr(store.series.burnPerBucket);
  const N = burns.length;
  const BUCKET_MS = 30000;
  // errN per bucket from LIVE red dots (real observations since page load — never invent).
  const errN = new Array(N).fill(0);
  for (const rec of store.agents.values()) {
    for (const d of rec.dots || []) {
      if (d.c !== '#f97066' || d.t == null) continue;
      const age = now - d.t;
      if (age < 0 || age >= N * BUCKET_MS) continue;
      const idx = N - 1 - Math.floor(age / BUCKET_MS);
      if (idx >= 0 && idx < N) errN[idx] += 1;
    }
  }
  let peak = 0;
  for (const v of burns) if (v > peak) peak = v;
  // Empty / still filling: all zeros → collecting message (needs ~1 min of samples).
  if (!(peak > 0)) {
    return `<div class="ops-burn">
      <div class="ops-section-title">burn · $/min</div>
      <div class="ops-burn-empty">collecting… (needs ~1 min)</div>
      <div class="ops-burn-legend"><span></span><span class="ops-burn-red-leg">red bucket = ≥3 errors/30s</span><span>now</span></div>
    </div>`;
  }
  let bars = '';
  for (let i = 0; i < N; i++) {
    const v = burns[i] || 0;
    const h = Math.max(v > 0 ? 4 : 0, Math.round((v / peak) * 100));
    const c = errN[i] >= 3 ? '#f97066' : 'rgba(52,211,153,.55)';
    bars += `<div class="ops-burn-bar" style="height:${h}%;background:${c}" title="${fmtBurnMin(v)}"></div>`;
  }
  return `<div class="ops-burn">
    <div class="ops-section-title">burn · $/min</div>
    <div class="ops-burn-bars">${bars}</div>
    <div class="ops-burn-legend"><span>−20m</span><span class="ops-burn-red-leg">red bucket = ≥3 errors/30s</span><span>now</span></div>
  </div>`;
}

// MODELS strip — port of legacy-cockpit.html .mcell row (real store.models only).
function renderModels() {
  const models = store.models || [];
  let cells;
  if (!models.length) {
    cells = '<span class="ops-m-empty">no model usage yet</span>';
  } else {
    cells = models.map((m) => {
      const fam = m.model || 'unknown';
      const live = m.running || (m.dollars_per_hour != null && m.dollars_per_hour > 0);
      // null tokens/dollars (absent server fields) → "—", never invent 0 (FR-14).
      const tok5 = m.tokens_5m != null && Number.isFinite(m.tokens_5m) ? fmtTok(m.tokens_5m) : '—';
      const tok5Tip = m.tokens_5m != null && Number.isFinite(m.tokens_5m)
        ? Number(m.tokens_5m).toLocaleString()
        : '—';
      const tokTotTip = m.tokens_total != null && Number.isFinite(m.tokens_total)
        ? Number(m.tokens_total).toLocaleString()
        : '—';
      const rate = m.unpriced
        ? '<span class="ops-m-unpriced" title="no notional price for this model">unpriced</span>'
        : `<b class="ops-m-rate">${esc(fmtUsd(m.dollars_per_hour))}/hr</b>`;
      const col = MODEL_COLORS[fam] || modelColor(fam) || '#93a89c';
      const tip = `${fam}: ${tok5Tip} tok in last 5m · ${tokTotTip} tok total · notional`;
      return `<span class="ops-mcell ${live ? 'live' : 'idle'}" title="${esc(tip)}">
        <span class="ops-m-dot"></span>
        <span class="ops-m-name" style="color:${esc(col)}">${esc(fam)}</span>
        ${rate}
        <span class="ops-m-tok">${esc(tok5)}/5m</span>
      </span>`;
    }).join('');
  }
  return `<div class="ops-models" aria-label="Live per-model usage and notional cost">
    <span class="ops-m-lbl" title="Rolling 5-minute rate, extrapolated. Dollars are a NOTIONAL proxy, never a bill.">models · $/hr notional</span>
    <div class="ops-m-cells">${cells}</div>
  </div>`;
}

// --- public API -----------------------------------------------------------------------------

function render() {
  if (!root) return;
  const now = Date.now();
  root.innerHTML = `
    <div class="ops-row ops-row-top">
      ${renderVerdict(now)}
      ${renderAlerts()}
    </div>
    ${renderPipeline(now)}
    <div class="ops-row ops-row-mid">
      ${renderHeat(now)}
      ${renderBurn(now)}
    </div>
    ${renderModels()}
  `;
}

function findAlert(id) {
  return (store.alerts || []).find((a) => a.id === id) || null;
}

function emitNav(detail) {
  bus.dispatchEvent(new CustomEvent('nav', { detail }));
}

function onClick(ev) {
  const t = ev.target.closest('[data-act]');
  if (!t || !root.contains(t)) return;
  const act = t.getAttribute('data-act');
  if (act === 'select') {
    const id = t.getAttribute('data-id');
    if (id) select(id);
    return;
  }
  if (act === 'alert-ctl') {
    const al = findAlert(t.getAttribute('data-id'));
    if (al && al.ctl && al.ctl.verb) ctl(al.ctl.verb, al.ctl.payload || {});
    return;
  }
  if (act === 'alert-nav') {
    const al = findAlert(t.getAttribute('data-id'));
    if (al && al.pick) select(al.pick);
    else if (al && al.nav) emitNav(al.nav);
    return;
  }
  if (act === 'nav-attn') {
    emitNav({ view: 'grid', filter: 'ATTN' });
    return;
  }
  if (act === 'nav-filter') {
    emitNav({ view: 'grid', filter: t.getAttribute('data-filter') });
    return;
  }
  if (act === 'nav-lane') {
    const lane = t.getAttribute('data-lane');
    if (lane) emitNav({ view: 'grid', lane });
    return;
  }
  if (act === 'pause-toggle') {
    ctl(store.paused ? 'resume' : 'pause', {});
  }
}

function init(rootEl) {
  root = rootEl;
  if (!bound) {
    bound = true;
    root.addEventListener('click', onClick);
    bus.addEventListener('data', render);
    bus.addEventListener('tick', render);
  }
  render();
}

export { init, render };
export default { init, render };
