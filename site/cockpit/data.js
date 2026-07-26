/**
 * The cockpit's store + ALL I/O. The single fetcher; every view reads `store`/`ui` and subscribes to `bus`. No DOM outside its own hidden state, no rendering — views render.
 *
 * Project: unimatrix — multi-model swarm orchestrator driven from Claude Code
 * Module:  site/cockpit/data.js
 * Deps:    browser fetch + EventSource; format.js (PURE ports + constants)
 * Tested:  tests/ground-control.bats (server shapes); tests/cockpit.bats (logic mirror)
 *
 * Key responsibilities:
 * - Hold the store (plan §5.2 verbatim): counts, agents Map, lanes Map, models, costLanes, alerts,
 *   loop, config, and the series ring buffers (evt/burn/spent/queue). Plus `ui` (selection, view
 *   prefs) and `bus` (EventTarget: data/tick/feed:append/feed:update/feed:reset/degrade/sel/nav/sse).
 * - Pollers: /api/bus 2s, /api/agents 2s, /api/models 5s, /api/cost 10s, /api/loop 5s, /api/config
 *   on load + after save (cached via getConfigData(), written via postConfigData()). SSE on
 *   /api/stream with the zombie watchdog (ping listener, 45s silence) and the server's
 *   'replay-done' sentinel (end of backfill, per connection) — health surfaced as
 *   store.sse {state, lastSeen} + bus 'sse' on every state transition. Drawer bodies fetched
 *   on demand via fetchAgentBodies(id), one cached promise per selection.
 * - Reconciliation (§5.2 rules 1-6): server snapshot wins; displayed age = min(server-seeded,
 *   client-observed); derived state for claimed (err/stale/run/paused); replay-vs-live; buffer-level
 *   coalescing; graceful 404 fallback for old servers; degrade() on first /api/bus failure.
 * - Alert derivation (FR-13/FR-19): error / silent / budget / starved / parked, severity-sorted.
 *
 * Design constraints:
 * - ONLY this module fetches. Views import store/ui/bus and call ctl()/select()/bus 'nav'.
 * - No fake data (FR-14): absent server fields render as null → views show "—"/hide. Never invent.
 * - Replay events populate feed/events/lastSummary/model carry-forward but NEVER buckets/dots/
 *   evtPerBucket/lastEvtClient (replay arrival time is meaningless). Live events drive the pulses.
 * - Server field names win (§5.4): lease_remaining_sec, done_lane, run_started_ms, spent_usd, etc.
 */

import {
  summarize, kindFromBadge, coalesceKeyOf, ACCUMULATE_TYPES,
  modelOf, normalizeModel, modelColor,
  LANES, loadJSON, ageSecOf, fmtAge,
} from './format.js';

// --- the store + ui + bus (module singletons) ------------------------------------------------
//
// store shape is plan §5.2 verbatim. agents is a Map<id,rec> so reconcile mutates in place and
// views see stable object identity (pulse buckets, dots, spans survive across polls). ui holds the
// selection + the persisted view prefs (loaded once here; main.js owns the active view + persists
// 'unimatrix-view' itself, since only main.js touches the header).

const bus = new EventTarget();
function emit(type, detail) {
  bus.dispatchEvent(detail !== undefined ? new CustomEvent(type, { detail }) : new Event(type));
}

function ring(n) {
  return { buf: new Array(n).fill(0), idx: 0, n };
}
// most-recent slot (where live increments land before the next rotation)
function ringCur(r) {
  return (r.idx - 1 + r.n) % r.n;
}
function ringIncr(r, by = 1) {
  r.buf[ringCur(r)] += by;
}
// push a fresh sample as the new current slot (rotates)
function ringPush(r, v) {
  r.buf[r.idx] = v;
  r.idx = (r.idx + 1) % r.n;
}
// oldest→newest view for charting
export function ringArr(r) {
  return r.buf.slice(r.idx).concat(r.buf.slice(0, r.idx));
}

const store = {
  ok: true,
  paused: false,
  runActive: false,
  budgetUsd: null,      // config.BUDGET_USD string ("0" = no cap), from /api/agents envelope
  spentUsd: null,       // Σ total_cost_usd across run logs, from /api/agents
  gate: { done: 0, parked: 0, live: 0 },
  runStartedMs: null,   // min runSummary.first_ts across run logs (FR-17)
  leaseMin: null,       // from config / /api/bus / /api/agents — null until the server supplies it
  limits: [],           // [{lane, expires_in_sec}] from /api/agents (FR-19)
  config: {},           // /api/config snapshot (raw allowlisted keys)
  execChain: [],        // parsed EXEC_CHAIN lane:model entries (config-driven; never hardcoded)
  verifyPairs: [],      // parsed VERIFY_MAP lane:lane pairs
  loop: { run: null, iter: null, max: null, budget_usd: null, cost_total: null, last: null, halted: false, halted_reason: null, complete: false, started_ms: null, steering_bytes: 0 },
  counts: {},
  staleLeases: [],
  parked: [],
  activeLimits: [],
  doneRecent: [],
  agents: new Map(),
  lanes: new Map(),
  models: [],
  costLanes: [],
  alerts: [],
  agentsOk: false,      // false until a real /api/agents 200 (gates the 404 fallback + eviction)
  sse: { state: 'reconnecting', lastSeen: null }, // EventSource health (main.js blink dot)
  series: {
    evtPerBucket: ring(40),  // 40 × 30s = 20min events/min histogram (red bucket = ≥3 errors/30s)
    burnPerBucket: ring(40), // 40 × 30s $/min samples
    spentCum: ring(40),      // 40 × 30s cumulative spend samples
    queueLen: ring(30),      // 30 × 30s queue-length samples (QUEUE trend)
  },
  feed: [],
};

const ui = {
  view: 'ops',
  sel: null,
  dtab: 'events',
  mcFilter: 'all',
  laneFilter: null,
  fpSort: 'quiet',      // 'quiet' (quietest-first) ↔ 'bus'
  fpShowDone: false,
  fpZoom: 20,           // window minutes: 5 / 20 / 60
  fpFollow: true,
  armAbort: false,
};

// load the persisted view prefs (byte-compatible with the legacy loadJSON/saveJSON pair)
const _fpSort = loadJSON('unimatrix-fp-sort', { v: 'quiet' });
if (_fpSort.v) ui.fpSort = _fpSort.v === 'bus' ? 'bus' : 'quiet';
const _fpDone = loadJSON('unimatrix-fp-done', { v: false });
if (_fpDone.v != null) ui.fpShowDone = !!_fpDone.v;
const _fpZoom = loadJSON('unimatrix-fp-zoom', { v: 20 });
if ([5, 20, 60].includes(_fpZoom.v)) ui.fpZoom = _fpZoom.v;

// --- per-agent record -----------------------------------------------------------------------

function newRecord(id) {
  return {
    id,
    // server snapshot fields (re-asserted every poll; server wins — rule 1)
    lane: null,
    model: null,
    pinned: false,
    frozen: false,
    verify: id.startsWith('v-'),
    srvState: 'unknown',
    state: 'unknown',
    stale: false,
    heartbeatAgeSec: null,
    claimAgeSec: null,
    leaseRemainSec: null,
    lastActivity: '',
    tokens: null,
    dollars: null,
    costUsd: null,
    errors: 0,
    retries: 0,
    timedout: false,
    chainLeft: null,
    doneLane: null,
    doneCode: null,
    doneMs: null,
    // client-only fields
    srvAgeSec: null,       // server last_event_age_sec as measured at srvAgeAt
    srvAgeAt: null,        // ms — the poll receipt time for srvAgeSec
    lastEvtClient: null,   // ms of the most recent LIVE SSE event (null until one arrives)
    lastSummary: null,     // {badge, cls, text} of the most recent event (drawer activity line)
    fam: null,             // normalized model family (carry-forward, spec 06 §D)
    errorStreak: 0,        // consecutive error/turn.failed events (feeds err derivation)
    buckets: new Uint8Array(6),  // 10s tool-call pulse buckets
    bucketEpoch: null,     // floor(now/10s) of the last bucket advance (ages stale buckets to 0)
    dots: [],              // [{t, c}] cap 24 — LIVE tool_use (blue) / error (red)
    spans: [],             // flightpath segments [{start,end,kind,lane}] (flight.js refines)
    events: [],            // per-agent feed entries (cap 200) — drawer events tab + transcript
  };
}

// family → lane name (claude-* collapses to claude). Used to attribute /api/models burn to lanes.
function familyToLane(fam) {
  if (!fam) return null;
  if (fam === 'codex') return 'codex';
  if (fam === 'glm') return 'glm';
  if (fam === 'gemini') return 'gemini';
  if (fam === 'grok') return 'grok';
  if (fam === 'kimi') return 'kimi';
  if (fam.startsWith('claude')) return 'claude';
  return null;
}

// --- derived state (§5.2 rule 3) ------------------------------------------------------------
//
// ageSecOf (§5.2 rule 2) now lives in format.js — imported above, shared with every view.

// claimed → paused (frozen) / err / stale / run; everything else passes srvState through.
function deriveState(rec, ageSec) {
  const s = rec.srvState;
  if (s === 'done' || s === 'cancelled' || s === 'parked' || s === 'queued') return s;
  if (rec.frozen) return 'paused';
  if (rec.retries >= 2 || rec.errorStreak >= 2 || (rec.errors > 0 && rec.timedout)) return 'err';
  // leaseMin null (no /api/agents or /api/config supplied it yet) → suppress stale derivation
  // rather than derive against a guessed threshold (also suppresses the silent alert until then).
  if (store.leaseMin != null && ageSec != null && ageSec > (store.leaseMin / 2) * 60) return 'stale';
  return 'run';
}

// --- reconciliation: apply a server agent snapshot onto its persistent record ----------------

function applyServerSnapshot(rec, a, now) {
  rec.srvState = a.state || 'unknown';
  // snapshot wins EXACTLY (rule 1) — a requeued/vanished-then-reappeared agent never keeps a
  // stale lane/model from its previous record; absent means unknown (null), not "whatever it was".
  rec.lane = a.lane ?? null;
  rec.model = a.model ?? null;
  rec.pinned = !!a.pinned;
  rec.frozen = !!a.frozen;
  rec.verify = !!a.verify;
  rec.stale = !!a.stale;
  rec.heartbeatAgeSec = a.heartbeat_age_sec ?? null;
  rec.claimAgeSec = a.claim_age_sec ?? null;
  rec.leaseRemainSec = a.lease_remaining_sec ?? null;
  rec.lastActivity = a.last_activity || '';
  rec.tokens = a.tokens ?? null;
  rec.dollars = a.dollars ?? null;
  rec.costUsd = a.cost_usd ?? null;
  rec.errors = a.errors || 0;
  rec.retries = a.retries || 0;
  rec.timedout = !!a.timedout;
  // authoritative snapshot shows no trouble → clear the live-only error streak (it would
  // otherwise never reset once >=2, permanently pinning the agent's derived state to 'err').
  if (!rec.errors && !rec.retries && !rec.timedout) rec.errorStreak = 0;
  rec.chainLeft = a.chain_left != null ? a.chain_left : null;
  rec.doneLane = a.done_lane != null ? a.done_lane : null;
  rec.doneCode = a.done_code != null ? a.done_code : null;
  rec.doneMs = a.done_ms != null ? a.done_ms : null;
  // server-seeded age: the run-log mtime age as of this poll (rule 2's server term).
  rec.srvAgeSec = a.last_event_age_sec != null ? a.last_event_age_sec : rec.srvAgeSec;
  rec.srvAgeAt = (rec.srvAgeSec != null) ? now : rec.srvAgeAt;
  // recompute derived state immediately so a poll fresh off the wire is consistent.
  rec.state = deriveState(rec, ageSecOf(rec, now));
  advanceBuckets(rec, now);
}

// --- pulse buckets: 10s tool-call windows that age to 0 -------------------------------------------------
//
// 6 buckets × 10s = 60s pulse window. `bucketEpoch` = floor(now/10s); when time has advanced past
// one or more windows, those slots are zeroed (a quiet stretch goes flat, matching the mock). cap 255.
function advanceBuckets(rec, now) {
  const epoch = Math.floor(now / 10000);
  if (rec.bucketEpoch == null) { rec.bucketEpoch = epoch; return; }
  const diff = epoch - rec.bucketEpoch;
  if (diff <= 0) return;
  if (diff >= 6) rec.buckets.fill(0);
  else for (let i = 1; i <= diff; i++) rec.buckets[(rec.bucketEpoch + i) % 6] = 0;
  rec.bucketEpoch = epoch;
}

function bumpPulse(rec, now) {
  advanceBuckets(rec, now);
  const idx = Math.floor(now / 10000) % 6;
  if (rec.buckets[idx] < 255) rec.buckets[idx] += 1;
}

// --- lane aggregate rebuild (pipeline lane rows + starved-lane tracking) --------------------------------

function execLaneNames() {
  const names = [];
  for (const lm of store.execChain) {
    const i = lm.indexOf(':');
    names.push(i >= 0 ? lm.slice(0, i) : lm);
  }
  return names;
}

function rebuildLanes(now) {
  const prev = store.lanes;
  const lanes = new Map();
  const make = (lane) => ({
    lane, k: LANES[lane] ? LANES[lane].k : '?', color: LANES[lane] ? LANES[lane].color : '#93a89c',
    claimed: 0, parked: 0, burn: 0, pulse: new Uint8Array(6), limited: null, silent: [], idleSince: null,
  });
  for (const lane of execLaneNames()) if (!lanes.has(lane)) lanes.set(lane, make(lane));

  for (const rec of store.agents.values()) {
    if (!rec.lane) continue;
    let l = lanes.get(rec.lane);
    if (!l) { l = make(rec.lane); lanes.set(rec.lane, l); }
    const st = rec.state;
    if (st === 'run' || st === 'stale' || st === 'err' || st === 'paused') l.claimed += 1;
    if (st === 'parked') l.parked += 1;
    if (st === 'stale') l.silent.push(rec.id);
    for (let i = 0; i < 6; i++) l.pulse[i] = Math.min(255, l.pulse[i] + (rec.buckets[i] || 0));
  }
  // per-lane $/min from /api/models (family → lane), summed across families that fold into a lane.
  for (const m of store.models) {
    const lane = familyToLane(m.model);
    const l = lane && lanes.get(lane);
    if (l) l.burn += (m.dollars_per_hour || 0) / 60;
  }
  // lane-level .limited TTL (FR-19) + idle-since tracking for the starved alert. idleSince MUST
  // persist across rebuilds (this runs every tick) — carry it forward from the previous lane entry,
  // else it'd reset to `now` every second and the >60s starved threshold could never fire.
  const paused = store.paused;
  const queued = store.counts.queued || 0;
  for (const lim of store.limits) {
    const l = lanes.get(lim.lane);
    if (l) l.limited = lim.expires_in_sec;
  }
  for (const l of lanes.values()) {
    if (!execLaneNames().includes(l.lane)) continue;
    const stillIdle = l.claimed === 0 && queued > 0 && !paused;
    const oldIdle = prev && prev.get(l.lane) ? prev.get(l.lane).idleSince : null;
    l.idleSince = stillIdle ? (oldIdle != null ? oldIdle : now) : null;
  }
  store.lanes = lanes;
}

// --- alert derivation (FR-13 + FR-19) -------------------------------------------------------
//
// severity: err(0) > silent(1) > budget(2) > starved(3) > parked(4). Thresholds come from config
// (LEASE_MIN via store.leaseMin, BUDGET_USD via store.budgetUsd) — never magic numbers. The list is
// sorted by severity; views cap display (3 on OPS WALL, all in MISSION CONTROL's rail).
const ALERT_SEV = { err: 0, silent: 1, budget: 2, starved: 3, parked: 4 };
const ALERT_COLOR = {
  err: { c: '#f97066', bc: 'rgba(249,112,102,.5)' },
  silent: { c: '#e0b34a', bc: 'rgba(224,179,74,.5)' },
  budget: { c: '#e0b34a', bc: 'rgba(224,179,74,.5)' },
  starved: { c: '#e0b34a', bc: 'rgba(224,179,74,.5)' },
  parked: { c: '#e0b34a', bc: 'rgba(224,179,74,.5)' },
};

function deriveAlerts(now) {
  const out = [];
  const seen = new Set();
  const add = (a) => {
    if (seen.has(a.id)) return;
    seen.add(a.id);
    a.sev = ALERT_SEV[a.type];
    const col = ALERT_COLOR[a.type];
    a.c = col.c; a.bc = col.bc;
    out.push(a);
  };

  for (const rec of store.agents.values()) {
    if (rec.state === 'err') {
      add({
        id: rec.id, type: 'err',
        title: `✕ error ×${Math.max(rec.retries, rec.errors, 1)}`,
        sub: rec.lastActivity || `${rec.lane || '?'} lane · retrying`,
        verb: 'KILL + CANCEL', ctl: { verb: 'kill', payload: { id: rec.id, cancel: true } },
        pick: rec.id, nav: null,
      });
    } else if (rec.state === 'stale') {
      const age = ageSecOf(rec, now);
      const lease = rec.leaseRemainSec != null ? fmtAge(rec.leaseRemainSec) : null;
      add({
        id: rec.id, type: 'silent',
        title: `silent ${fmtAge(age)}`,
        sub: lease != null ? `${rec.lane || '?'} · lease dies in ${lease}` : `${rec.lane || '?'} · no events`,
        verb: 'NUDGE NOW', ctl: { verb: 'nudge', payload: { id: rec.id } },
        pick: rec.id, nav: null,
      });
    } else if (rec.state === 'parked') {
      // parked alert (FR-19): .limited TTL reuse; nudge resets the chain = requeue onto EXEC_CHAIN head.
      // A parked agent's rec.lane is only the CHAIN-HEAD guess (sidecar/chain files die with the
      // park) — naming it beside ".limited" misattributes the cap to an innocent lane (FR-14
      // honesty; observed in wave-8 QA: card read "claude lane .limited" while glm held the
      // flag). Name a lane only when it is actually limit-flagged; else say what we know.
      const lim = store.limits.find((x) => x.lane === rec.lane) || null;
      const ttl = lim ? fmtAge(lim.expires_in_sec) : null;
      const firstLim = store.limits[0] || null;
      const sub = lim
        ? `${rec.lane} lane .limited${ttl ? ` (${ttl} left)` : ''}`
        : firstLim
          ? `parked · ${firstLim.lane} .limited (${fmtAge(firstLim.expires_in_sec)} left)`
          : 'parked (lane caps)';
      add({
        id: rec.id, type: 'parked',
        title: '▣ parked',
        sub,
        verb: 'NUDGE (requeue)', ctl: { verb: 'nudge', payload: { id: rec.id } },
        pick: rec.id, nav: null,
      });
    }
  }

  // budget (cap>0 && spent > 80% cap)
  const cap = Number(store.budgetUsd);
  if (Number.isFinite(cap) && cap > 0 && store.spentUsd != null && store.spentUsd > 0.8 * cap) {
    const pct = Math.round((store.spentUsd / cap) * 100);
    add({
      id: 'BUDGET', type: 'budget',
      title: `${pct}% burned`,
      sub: `$${store.spentUsd.toFixed(2)} of $${cap} · on pace to cap`,
      verb: 'PAUSE QUEUE', ctl: { verb: 'pause', payload: {} },
      pick: null, nav: { view: 'flight' },
    });
  }

  // starved (queued>0 && !paused && an EXEC_CHAIN lane idle >60s) — inspect-only, no ctl verb.
  if (!store.paused && (store.counts.queued || 0) > 0) {
    for (const l of store.lanes.values()) {
      if (l.idleSince != null && now - l.idleSince > 60000) {
        add({
          id: `STARVED-${l.lane}`, type: 'starved',
          title: `${l.k} lane starved`,
          sub: `queue has work · ${l.lane} idle ${fmtAge((now - l.idleSince) / 1000)}`,
          verb: 'inspect', ctl: null,
          pick: null, nav: { view: 'grid', filter: 'queued', lane: l.lane },
        });
      }
    }
  }

  out.sort((a, b) => (a.sev - b.sev) || String(a.id).localeCompare(String(b.id)));
  store.alerts = out;
}

// --- pollers ---------------------------------------------------------------------------------

let busTimer = null;
let agentsTimer = null;
let modelsTimer = null;
let costTimer = null;
let loopTimer = null;
let tickTimer = null;
let watchdogTimer = null;
let firstBusOk = null; // null = unknown, true/false after first /api/bus attempt
let es = null;
let replayDone = false; // false until the server's 'replay-done' sentinel for THIS connection
let replayDeadline = 0;  // fallback: treat as live past this even if the sentinel never lands
let sseConnected = false;
let sseLastSeen = 0;
const seenWorkers = new Set();
const activeCoalesce = new Map(); // worker -> {key, idx, buffer} (idx into store.feed)
const lastModelByWorker = {}; // carry-forward model per worker (spec 06 §D)
const RAW_CAP = 32 * 1024;

function clearTimers() {
  for (const t of [busTimer, agentsTimer, modelsTimer, costTimer, loopTimer, tickTimer, watchdogTimer]) {
    if (t) clearInterval(t);
  }
  busTimer = agentsTimer = modelsTimer = costTimer = loopTimer = tickTimer = watchdogTimer = null;
}

function degrade() {
  // port of legacy degrade(): stop polling + streaming, flip ok off, hand the chrome to main.js.
  store.ok = false;
  clearTimers();
  if (es) { try { es.close(); } catch { /* already dead */ } es = null; }
  emit('degrade');
}

// /api/bus — counts + stale/parked/limits + done list. The degrade trigger: first failure flips
// the page to the local-only notice (matches legacy firstBusOk behavior exactly).
function pollBus() {
  if (firstBusOk === false) return;
  fetch('/api/bus')
    .then((r) => { if (!r.ok) throw new Error('bad status'); return r.json(); })
    .then((d) => {
      store.counts = d.counts || {};
      store.staleLeases = d.stale_leases || [];
      store.parked = d.parked || [];
      store.activeLimits = d.active_limits || [];
      store.doneRecent = d.done || [];
      if (d.lease_min != null) store.leaseMin = Number(d.lease_min) || store.leaseMin;
      if (firstBusOk === null) firstBusOk = true;
      emit('data');
    })
    .catch(() => {
      if (firstBusOk === null) { firstBusOk = false; degrade(); }
      // later failures after a good first fetch: keep last-known state (legacy behavior).
    });
}

// /api/agents — the authoritative per-agent snapshot. Server wins (rule 1); derived state recomputed.
function pollAgents() {
  if (firstBusOk === false) return;
  fetch('/api/agents')
    .then(async (r) => {
      if (r.status === 404) {
        // old server: build agents from SSE worker names, srvState 'unknown', ages "—" (rule 6).
        store.agentsOk = false;
        fallbackAgents();
        return null;
      }
      if (!r.ok) throw new Error('bad status');
      store.agentsOk = true;
      return r.json();
    })
    .then((env) => {
      if (!env) { emit('data'); return; }
      reconcileAgents(env);
    })
    .catch(() => { /* keep last-known state */ });
}

function reconcileAgents(env) {
  const now = Date.now();
  store.paused = !!env.paused;
  store.runActive = !!env.run_active;
  store.budgetUsd = env.budget_usd != null ? env.budget_usd : store.budgetUsd;
  store.spentUsd = typeof env.spent_usd === 'number' ? env.spent_usd : store.spentUsd;
  store.gate = env.gate || { done: 0, parked: 0, live: 0 };
  store.runStartedMs = env.run_started_ms != null ? env.run_started_ms : store.runStartedMs;
  store.limits = Array.isArray(env.limits) ? env.limits : [];
  if (env.lease_min != null) store.leaseMin = Number(env.lease_min) || store.leaseMin;

  const seen = new Set();
  for (const a of (env.agents || [])) {
    if (!a || a.id == null) continue;
    seen.add(a.id);
    let rec = store.agents.get(a.id);
    if (!rec) { rec = newRecord(a.id); store.agents.set(a.id, rec); }
    applyServerSnapshot(rec, a, now);
  }
  // server snapshot is authoritative → evict agents no longer present (a vanished agent is gone).
  for (const id of [...store.agents.keys()]) {
    if (!seen.has(id)) store.agents.delete(id);
  }
  rebuildLanes(now);
  deriveAlerts(now);
  emit('data');
}

// 404 fallback (rule 6): synthesize unknown-state records from the workers SSE has named, so the
// page still renders against an old server that lacks /api/agents.
function fallbackAgents() {
  const now = Date.now();
  for (const id of seenWorkers) {
    let rec = store.agents.get(id);
    if (!rec) { rec = newRecord(id); store.agents.set(id, rec); }
    rec.srvState = 'unknown';
    rec.state = 'unknown';
  }
  rebuildLanes(now);
  deriveAlerts(now);
  emit('data');
}

function pollModels() {
  if (firstBusOk === false) return;
  fetch('/api/models')
    .then((r) => { if (!r.ok) throw new Error('bad status'); return r.json(); })
    .then((d) => { store.models = (d && d.models) || []; emit('data'); })
    .catch(() => { /* keep last-known cells */ });
}

function pollCost() {
  if (firstBusOk === false) return;
  fetch('/api/cost')
    .then((r) => { if (!r.ok) throw new Error('bad status'); return r.json(); })
    .then((d) => { store.costLanes = (d && d.lanes) || []; emit('data'); })
    .catch(() => { /* keep last-known */ });
}

function pollLoop() {
  if (firstBusOk === false) return;
  fetch('/api/loop')
    .then((r) => { if (r.status === 404) return null; if (!r.ok) throw new Error('bad status'); return r.json(); })
    .then((d) => {
      if (!d) { emit('data'); return; }
      store.loop = {
        run: d.run, iter: d.iter, max: d.max_iterations, budget_usd: d.budget_usd,
        cost_total: d.cost_total, last: d.last, halted: !!d.halted, halted_reason: d.halted_reason,
        complete: !!d.complete, started_ms: d.started_ms, steering_bytes: d.steering_bytes || 0,
      };
      emit('data');
    })
    .catch(() => { /* keep last-known */ });
}

let configFetchPromise = null; // cache for getConfigData(); invalidated by refreshConfig()

function loadConfig() {
  configFetchPromise = fetch('/api/config')
    .then((r) => { if (!r.ok) throw new Error('bad status'); return r.json(); })
    .then(applyConfig)
    .catch((e) => {
      // don't cache a failed fetch forever — clear it so the next getConfigData() retries.
      configFetchPromise = null;
      throw e;
    });
  return configFetchPromise;
}

// cached /api/config GET — reuses the in-flight/boot fetch; refreshConfig()/postConfigData()
// invalidate the cache by re-running loadConfig() themselves.
export function getConfigData() {
  return (configFetchPromise || loadConfig()).then(() => store.config);
}

// POST /api/config ({key, value} per the server's fixed contract), then refresh the shared
// store so every view re-derives from the saved snapshot (mirrors settings.js's own postConfig).
export function postConfigData(payload) {
  return fetch('/api/config', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload),
  })
    .then(async (r) => {
      const body = await r.json().catch(() => ({}));
      if (!r.ok) throw new Error(body.error || `save failed (${r.status})`);
      return body;
    })
    .then((body) => refreshConfig().then(() => body));
}

function applyConfig(cfg) {
  store.config = cfg || {};
  store.execChain = String(store.config.EXEC_CHAIN || '').split(/\s+/).filter(Boolean);
  store.verifyPairs = String(store.config.VERIFY_MAP || '').split(/\s+/).filter(Boolean).map((p) => {
    const i = p.indexOf(':');
    return i >= 0 ? [p.slice(0, i), p.slice(i + 1)] : [p, ''];
  });
  if (store.config.LEASE_MIN) store.leaseMin = Number(store.config.LEASE_MIN) || store.leaseMin;
  emit('data');
}

// re-fetch config after a settings save (settings.js calls this).
export function refreshConfig() {
  return loadConfig();
}

// --- series ring rotation (30s buckets) + 1s tick --------------------------------------------
//
// evtPerBucket counts live arrivals into the current bucket; burnPerBucket/spentCum/queueLen
// snapshot their current polled value at each 30s boundary. The 1s tick advances pulse buckets
// (so a quiet stretch goes flat) and re-derives state (so a stale transition fires between polls).

let lastBucketMs = 0;
function burnPerMin() {
  let sum = 0;
  for (const l of store.lanes.values()) sum += l.burn || 0;
  return sum;
}
function maybeRotateSeries(now) {
  if (lastBucketMs === 0) { lastBucketMs = now; return; }
  if (now - lastBucketMs < 30000) return;
  const steps = Math.floor((now - lastBucketMs) / 30000);
  for (let i = 0; i < steps; i++) {
    ringPush(store.series.evtPerBucket, 0); // fresh current bucket for live increments
    ringPush(store.series.burnPerBucket, burnPerMin());
    ringPush(store.series.spentCum, store.spentUsd != null ? store.spentUsd : 0);
    ringPush(store.series.queueLen, store.counts.queued != null ? store.counts.queued : 0);
  }
  lastBucketMs += steps * 30000;
}

function tick() {
  const now = Date.now();
  // age out pulse buckets + recompute derived state between polls (stale transitions feel live).
  for (const rec of store.agents.values()) {
    advanceBuckets(rec, now);
    rec.state = deriveState(rec, ageSecOf(rec, now));
  }
  maybeRotateSeries(now);
  rebuildLanes(now);
  deriveAlerts(now);
  emit('tick');
}

// --- SSE health (store.sse) --------------------------------------------------------------------
//
// main.js's blink dot reads store.sse instead of inferring recency from feed events. Transitions
// only (not every open/message/ping) emit bus 'sse' — a message every 15s at steady 'live' would
// otherwise spam the bus for no UI benefit.

function setSse(state, seen) {
  if (seen) store.sse.lastSeen = Date.now();
  if (store.sse.state !== state) {
    store.sse.state = state;
    emit('sse', { state, lastSeen: store.sse.lastSeen });
  }
}

// --- SSE client + zombie watchdog (ported from legacy) --------------------------------------

function startStream() {
  es = new EventSource('/api/stream');
  es.onopen = () => {
    // server.mjs tails every run-*.jsonl from byte 0 on each connect — a reconnect (drop, tab
    // sleep, server restart) replays the whole bus. Clear feed + per-agent events + coalesce state
    // so the firehose + drawer don't double up every pre-drop record (rule 4).
    if (sseConnected) {
      store.feed.length = 0;
      activeCoalesce.clear();
      for (const rec of store.agents.values()) {
        rec.events.length = 0;
        rec.errorStreak = 0; // replay must not preserve a stale streak from before the drop
      }
      emit('feed:reset');
    }
    sseConnected = true;
    replayDone = false; // every connection replays from byte 0 again
    // Belt-and-braces deadline: if the sentinel never arrives (cached older data.js vs a newer
    // server, a response-buffering proxy), replayDone would stay false for the life of the
    // connection and EVERY live signal would be dead. 30s is far longer than any real replay.
    replayDeadline = Date.now() + 30000;
    sseLastSeen = Date.now();
    setSse('live', true);
  };
  es.onmessage = (ev) => { sseLastSeen = Date.now(); setSse('live', true); appendLine(ev.data); };
  // server heartbeats arrive as a named 'ping' event every 15s (SSE comments are invisible to
  // EventSource, so the watchdog needs a real event to observe liveness).
  es.addEventListener('ping', () => { sseLastSeen = Date.now(); setSse('live', true); });
  // end-of-replay sentinel (backlog 24): the server emits it after its first full glob pass, so
  // replay-vs-live is server-authoritative instead of a wall-clock guess that a big bus outruns.
  es.addEventListener('replay-done', () => {
    replayDone = true;
    // Close out every streak the BACKFILL opened. Without this the first live event on a still-open
    // key takes the coalesce fast path — mutating a backfill row and returning early — so
    // lastEvtClient, dots, pulses and errorStreak are never touched and the agent looks dead.
    for (const w of [...activeCoalesce.keys()]) finalizeCoalesce(w);
    sseLastSeen = Date.now();
    setSse('live', true);
  });
  es.onerror = () => {
    replayDone = false; // the next connection re-replays; onopen resets too, this is belt+braces
    setSse('reconnecting', false); /* EventSource auto-reconnects */
  };
}

// zombie watchdog: over WSL mirrored loopback a killed server can vanish without an RST — the
// EventSource never errors, never reconnects, the firehose silently freezes. Heartbeats come every
// 15s; >45s of silence means the socket is dead → tear it down and reconnect.
function startWatchdog() {
  watchdogTimer = setInterval(() => {
    if (es && Date.now() - sseLastSeen > 45000) {
      setSse('dead', false);
      try { es.close(); } catch { /* already dead */ }
      startStream();
    }
  }, 10000);
}

// --- the buffer-level event processor (coalescing moved out of the DOM) ----------------------
//
// One pass per SSE record: parse the {worker, ts, line} envelope, summarize the line, coalesce a
// live streak in place, then (for LIVE arrivals only) drive pulses/dots/events-per-min. Feed +
// per-agent events render from the same store.feed entries; replay populates history but never
// touches the live signals (rule 4).

function appendLine(raw) {
  let worker = '';
  let lineVal = raw;
  let recvTs = null;
  try {
    const envelope = JSON.parse(raw);
    worker = envelope.worker || '';
    lineVal = envelope.line;
    recvTs = envelope.ts != null ? envelope.ts : null;
  } catch { /* not an envelope — treat raw as the line itself */ }

  const now = Date.now();
  const live = replayDone || (replayDeadline > 0 && Date.now() > replayDeadline);
  if (worker) seenWorkers.add(worker);

  let obj = typeof lineVal === 'object' && lineVal !== null ? lineVal : null;
  if (!obj && typeof lineVal === 'string') {
    try { obj = JSON.parse(lineVal); } catch { /* genuinely not JSON */ }
  }

  if (!obj) {
    // raw/malformed line — a system-kind row, no coalescing, no model chip.
    finalizeCoalesce(worker);
    const text = typeof lineVal === 'string' ? lineVal : String(lineVal);
    pushEntry({
      worker, ts: recvTs, recvTs: now, badge: 'raw', cls: 'b-dim', kind: 'system',
      text: text.length > 300 ? text.slice(0, 300) : text, raw: null, truncated: false,
      live: false, backfill: !live, fam: null, mc: '#93a89c',
    });
    return;
  }

  const { badge, cls, text } = summarize(obj);
  const kind = kindFromBadge(badge);
  let rawStr;
  try { rawStr = JSON.stringify(obj); } catch { rawStr = String(obj); }
  const truncated = rawStr.length > RAW_CAP;
  const rawStored = truncated ? rawStr.slice(0, RAW_CAP) : rawStr;

  // model carry-forward: this line's own model, else the last one seen for this worker (spec 06 §D).
  const rawModel = modelOf(obj);
  if (rawModel) lastModelByWorker[worker] = rawModel;
  const fam = normalizeModel(rawModel || lastModelByWorker[worker]) || null;
  const mc = fam ? modelColor(fam) : '#93a89c';

  // coalescing (rule 5): same key as the worker's active streak → mutate in place + feed:update.
  const ckey = coalesceKeyOf(worker, obj);
  const prev = activeCoalesce.get(worker);
  if (ckey && prev && prev.key === ckey) {
    const entry = store.feed[prev.idx];
    if (entry) {
      entry.text = ACCUMULATE_TYPES.has(obj.type) ? prev.buffer + text : text;
      entry.badge = badge; entry.cls = cls; entry.fam = fam; entry.mc = mc;
      entry.ts = obj.timestamp != null ? obj.timestamp : recvTs; entry.recvTs = now;
      entry.raw = rawStored; entry.truncated = truncated; entry.live = true;
      prev.buffer = entry.text;
      if (live) ringIncr(store.series.evtPerBucket);
      bus.dispatchEvent(new CustomEvent('feed:update', { detail: entry }));
      return;
    }
  }

  // not a continuation — the worker's previous streak (if any) is done; freeze it.
  finalizeCoalesce(worker);

  const entry = pushEntry({
    worker, ts: obj.timestamp != null ? obj.timestamp : recvTs, recvTs: now,
    badge, cls, kind, text, raw: rawStored, truncated, live: !!ckey, backfill: !live, fam, mc,
  });

  if (ckey) activeCoalesce.set(worker, { key: ckey, idx: store.feed.indexOf(entry), buffer: text });

  // history carry-forward (rule 4): replay + live both populate lastSummary + per-agent events.
  if (worker) {
    const rec = ensureRec(worker);
    rec.lastSummary = { badge, cls, text };
    if (fam) rec.fam = fam;
    rec.events.push(entry);
    if (rec.events.length > 200) rec.events.shift();
  }

  if (!live) return; // replay arrival time is meaningless → never touch live signals (rule 4)

  // LIVE: drive pulses, dots, events-per-min, lastEvtClient.
  if (worker) {
    const rec = ensureRec(worker);
    rec.lastEvtClient = now;
    // error streak feeds the err derivation between polls.
    if (obj.type === 'error' || obj.type === 'turn.failed') {
      rec.errorStreak += 1;
      rec.dots.push({ t: now, c: '#f97066' });
    } else {
      rec.errorStreak = 0;
      if (badge === 'tool_use') {
        bumpPulse(rec, now); // pulse = tool-calls observed
        rec.dots.push({ t: now, c: '#7dd3fc' });
      } else if (badge === 'result' || badge === 'item.completed') {
        if (cls === 'b-red') rec.dots.push({ t: now, c: '#f97066' });
      }
    }
    if (rec.dots.length > 24) rec.dots.shift();
  }
  ringIncr(store.series.evtPerBucket);
}

function ensureRec(worker) {
  let rec = store.agents.get(worker);
  if (!rec) {
    rec = newRecord(worker);
    // a worker only seen via SSE (no /api/agents yet, or not yet claimed) is unknown until a poll
    // says otherwise — never fabricate a lane/state.
    rec.srvState = 'unknown';
    store.agents.set(worker, rec);
  }
  return rec;
}

// finalize a worker's active streak: the row stays, but it's no longer "live" (spinner drops).
function finalizeCoalesce(worker) {
  const prev = activeCoalesce.get(worker);
  if (prev) {
    const entry = store.feed[prev.idx];
    if (entry) entry.live = false;
    activeCoalesce.delete(worker);
  }
}

// append + cap (rule 5: break finalizes a streak → feed:append). Returns the stored entry. When the
// 500-row cap evicts the head, every active coalesce index shifts down by one (the rows they point
// at moved); a streak whose row scrolled off (idx < 0) is dropped — its next arrival starts fresh.
function pushEntry(entry) {
  store.feed.push(entry);
  if (store.feed.length > 500) {
    store.feed.shift();
    for (const [w, v] of activeCoalesce) {
      v.idx -= 1;
      if (v.idx < 0) activeCoalesce.delete(w);
    }
  }
  bus.dispatchEvent(new CustomEvent('feed:append', { detail: entry }));
  return entry;
}

// --- drawer body fetch (GET /api/agent?id=) ---------------------------------------------------
//
// per-selection cache: one in-flight/resolved promise for the current selection, cleared whenever
// the selection changes so switching agents (or re-opening the same one later) always re-fetches.

let agentBodyCache = null; // { id, promise }

export function fetchAgentBodies(id) {
  if (agentBodyCache && agentBodyCache.id === id) return agentBodyCache.promise;
  const promise = fetch(`/api/agent?id=${encodeURIComponent(id)}`)
    .then((r) => { if (!r.ok) throw new Error('bad status'); return r.json(); });
  agentBodyCache = { id, promise };
  return promise;
}

// --- selection -------------------------------------------------------------------------------

export function select(id) {
  ui.sel = id || null;
  if (id) ui.dtab = 'events';
  agentBodyCache = null;
  emit('sel', { id: ui.sel });
}

export function closeDrawer() {
  ui.sel = null;
  agentBodyCache = null;
  emit('sel', { id: null });
}

// --- boot ------------------------------------------------------------------------------------

export function start() {
  sseLastSeen = Date.now(); // guard the watchdog until the first open/message/ping lands
  pollBus();
  pollAgents();
  pollModels();
  pollCost();
  pollLoop();
  loadConfig().catch(() => { /* config optional at boot — views fall back to "—" */ });
  startStream();
  startWatchdog();
  tick(); // seed derived state + first tick immediately
  busTimer = setInterval(pollBus, 2000);
  agentsTimer = setInterval(pollAgents, 2000);
  modelsTimer = setInterval(pollModels, 5000);
  costTimer = setInterval(pollCost, 10000);
  loopTimer = setInterval(pollLoop, 5000);
  tickTimer = setInterval(tick, 1000);
}

export { store, ui, bus };
