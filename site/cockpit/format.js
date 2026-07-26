/**
 * PURE formatting + classification helpers for the cockpit. No DOM, no fetch, no timers.
 *
 * Project: unimatrix — multi-model swarm orchestrator driven from Claude Code
 * Module:  site/cockpit/format.js
 * Deps:    none (stdlib-free; runs in browser and node --check)
 * Tested:  tests/ground-control.bats (server-side mirrors); tests/cockpit.bats (logic mirror)
 *
 * Key responsibilities:
 * - Port the legacy cockpit's per-lane event summarizers VERBATIM (summarize/summarizeBlocks/
 *   classifyBlock/toolUseText/looksFailed/usageStr/kindFromBadge) — every JSONL schema the three
 *   worker CLIs emit maps to one humanized one-liner here.
 * - Mirror server.mjs's normalizeModel/modelOf/MODEL_COLORS (spec 06) so client + server never
 *   disagree on a model family.
 * - Port the coalescing key tables (NEVER_COALESCE_TYPES/ACCUMULATE_TYPES/coalesceKeyOf) so the
 *   buffer-level coalescer in data.js matches the legacy DOM-level one byte-for-byte.
 * - Expose the cockpit-wide constants the views build against: LANES (letter+color per lane,
 *   config-driven rendering keys them off EXEC_CHAIN), STATE_RANK (trouble-first sort order),
 *   and the tile/heat style recipes (design §1.2 + plan §5.3).
 * - NEW pure helpers: fmtAge (12s/4m/1h4m), pulseStr (▁–▇ sparkline from a Uint8Array), ageSecOf
 *   (§5.2 rule-2 displayed-age formula — the single copy every view + data.js import from).
 *
 * Design constraints:
 * - PURE: no side effects, no globals, no DOM, no fetch, no timers. Anything that touches the
 *   outside world lives in data.js / ctl.js.
 * - summarize/classifyBlock/toolUseText/looksFailed/usageStr/kindFromBadge/normalizeModel/modelOf/
 *   MODEL_COLORS/colorFor/esc/fmtTok/fmtTime/loadJSON/saveJSON/NEVER_COALESCE_TYPES/
 *   ACCUMULATE_TYPES/coalesceKeyOf are byte-compatible ports of legacy-cockpit.html — do not
 *   "improve" them, the firehose + drawer must read identically to the old page.
 * - LANES/STATE_RANK are pinned by the wave-3 module contract; every view imports them.
 */

// --- HTML escaping + small string/number format helpers (ported verbatim) -------------------

export function esc(s) {
  return String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
}

// fmtTok: 999 -> "999", 1200 -> "1.2k". Ported verbatim from legacy renderCost.
export function fmtTok(n) {
  return n >= 1000 ? (n / 1000).toFixed(1) + 'k' : String(n);
}

// fmtTime: epoch-ms/Date -> "HH:MM:SS", else "--:--:--". Ported verbatim.
export function fmtTime(ts) {
  const d = ts ? new Date(ts) : null;
  return d && !isNaN(d) ? d.toTimeString().slice(0, 8) : '--:--:--';
}

// fmtAge: seconds -> compact "12s" / "4m" / "1h4m". NEW (design renderVals uses s/m only; this adds
// the hour tier so long stale leases don't render "90m"). <1s rounds up to "0s"; never invented.
export function fmtAge(sec) {
  if (sec == null || !Number.isFinite(sec) || sec < 0) return '—';
  const s = Math.floor(sec);
  if (s < 60) return `${s}s`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m`;
  const h = Math.floor(m / 60);
  return `${h}h${m % 60}m`;
}

// ageSecOf: displayed age = min(server-seeded age (grows from srvAgeSec as the client clock
// advances), client-observed age since the last LIVE event). null when neither signal exists.
// §5.2 rule 2 — the single copy every view (+ data.js) imports from; do not re-fork it locally.
export function ageSecOf(rec, now) {
  if (!rec) return null;
  const srv = rec.srvAgeSec != null && rec.srvAgeAt != null
    ? rec.srvAgeSec + (now - rec.srvAgeAt) / 1000
    : Infinity;
  const cli = rec.lastEvtClient != null ? (now - rec.lastEvtClient) / 1000 : Infinity;
  const m = Math.min(srv, cli);
  return Number.isFinite(m) ? m : null;
}

// pulseStr: render a Uint8Array of 10s pulse buckets as a ▁–▇ sparkline (7 block heights). Each
// bucket is a 0–255 tool-call count; 0 → ▁, max → ▇, scaled to the row's own peak so a quiet lane
// still shows shape. Empty/all-zero → flat low line (the design's stale shape). NEW.
const PULSE_BLOCKS = ['▁', '▂', '▃', '▄', '▅', '▆', '▇'];
export function pulseStr(buckets) {
  if (!buckets || buckets.length === 0) return PULSE_BLOCKS[0].repeat(6);
  let peak = 0;
  for (let i = 0; i < buckets.length; i++) if (buckets[i] > peak) peak = buckets[i];
  let out = '';
  for (let i = 0; i < buckets.length; i++) {
    const v = buckets[i];
    // peak===0 (no activity at all) renders the lowest block, matching the mock's flat stale line.
    const idx = peak === 0 ? 0 : Math.min(PULSE_BLOCKS.length - 1, Math.round((v / peak) * (PULSE_BLOCKS.length - 1)));
    out += PULSE_BLOCKS[idx];
  }
  return out;
}

// --- localStorage JSON helpers (ported verbatim — byte-identical keys rely on this shape) -------

export function loadJSON(key, fallback) {
  try {
    return { ...fallback, ...JSON.parse(localStorage.getItem(key)) };
  } catch {
    return { ...fallback };
  }
}

export function saveJSON(key, val) {
  try {
    localStorage.setItem(key, JSON.stringify(val));
  } catch {
    /* private mode / quota — non-fatal */
  }
}

// --- model normalization (MUST match server.mjs normalizeModel/modelOf — spec 06) -------------

export function normalizeModel(raw) {
  if (!raw) return null;
  const m = String(raw).toLowerCase();
  if (m.includes('fable')) return 'claude-fable';
  if (m.includes('opus')) return 'claude-opus';
  if (m.includes('sonnet')) return 'claude-sonnet';
  if (m.includes('haiku')) return 'claude-haiku';
  if (m.includes('glm')) return 'glm';
  if (m.includes('gemini')) return 'gemini';
  if (m.includes('grok')) return 'grok';
  if (m.includes('kimi')) return 'kimi';
  if (m.includes('gpt') || m.includes('codex')) return 'codex';
  return m;
}

export const MODEL_COLORS = {
  'claude-fable': '#f0abfc',
  'claude-opus': '#c084fc',
  'claude-sonnet': '#7dd3fc',
  'claude-haiku': '#93a89c',
  glm: '#34d399',
  kimi: '#fb923c',
  gemini: '#e0b34a',
  codex: '#4ae0a8',
  grok: '#f97066',
  unknown: '#93a89c',
};

export function modelColor(fam) {
  return MODEL_COLORS[fam] || '#93a89c';
}

// modelOf: the model string can sit on the record, its message envelope, or — grok's streaming
// events carry no model field — as the first KEY of an `end` event's modelUsage object. Ported
// verbatim; MUST stay in sync with server.mjs.
export function modelOf(o) {
  if (!o || typeof o !== 'object') return null;
  if (typeof o.model === 'string') return o.model;
  if (o.message && typeof o.message.model === 'string') return o.message.model;
  if (o.modelUsage && typeof o.modelUsage === 'object') {
    const k = Object.keys(o.modelUsage)[0];
    if (k) return k;
  }
  return null;
}

// colorFor: deterministic hash -> palette for a branch/worker id. Ported verbatim (no cache — an
// unbounded Map of ids would be dead weight over a long-running cockpit).
const PALETTE = ['#34d399', '#7dd3fc', '#e0b34a', '#f97066', '#c084fc', '#4ae0a8'];
export function colorFor(id) {
  let h = 0;
  for (const ch of id) h = (h * 31 + ch.charCodeAt(0)) | 0;
  return PALETTE[Math.abs(h) % PALETTE.length];
}

// --- lane + state constants (pinned by the wave-3 module contract) ---------------------------
//
// LANES: letter + color per lane. Config-driven views key off these by lane NAME (from EXEC_CHAIN),
// so the set of lanes shown is always derived from config — this map is just the rendering key.
// grok is the new 5th lane (letter K, color #f0abfc), distinct from semantic red/amber.
export const LANES = {
  claude: { k: 'C', color: '#7dd3fc' },
  codex: { k: 'X', color: '#c084fc' },
  gemini: { k: 'G', color: '#e0b34a' },
  glm: { k: 'Z', color: '#34d399' },
  grok: { k: 'K', color: '#f0abfc' },
  kimi: { k: 'M', color: '#fb923c' }, // kimi = 6th lane — M for Moonshot (K taken by grok)
};

// STATE_RANK: trouble-first sort order for tiles + flightpaths. err worst, cancelled/done sink.
// `paused` (a frozen worker, §4.6b) ranks between park and run.
export const STATE_RANK = { err: 0, stale: 1, park: 2, paused: 3, run: 4, q: 5, done: 6, cancelled: 7 };

// laneOf(record): the letter + color for an agent's lane, falling back to "?" when the lane is
// absent (queued/parked before any claim) — never throws on an unknown lane name.
export function laneLetter(lane) {
  const l = LANES[lane];
  return l ? l.k : '?';
}
export function laneColor(lane) {
  const l = LANES[lane];
  return l ? l.color : '#93a89c';
}

// --- tile + heat style recipes (design §1.2 stTile/heat + plan §5.3) -------------------------
//
// These turn a derived state (+ age, for the heat's fresh/aging split) into the exact border/
// bg/glyph/opacity the design paints. Kept here so every view that renders a state-colored chip
// agrees, and so the recipes are grep-able in one place. No invented data — every input is a real
// derived state from data.js.

// Tile (mission-control grid cell) style. Opacity matches the design: done .4, queued .5.
export function tileStyle(state) {
  switch (state) {
    case 'run': return { bc: 'rgba(94,234,166,.2)', op: '1', glyph: '●', gc: '#34d399' };
    case 'q': return { bc: 'rgba(94,234,166,.13)', op: '0.5', glyph: '◌', gc: '#93a89c' };
    case 'done': return { bc: 'rgba(94,234,166,.1)', op: '0.4', glyph: '✓', gc: '#1d8a63' };
    case 'cancelled': return { bc: 'rgba(147,168,156,.13)', op: '0.4', glyph: '⊘', gc: '#93a89c' };
    case 'stale': return { bc: '#e0b34a', op: '1', glyph: '⚠', gc: '#e0b34a' };
    case 'paused': return { bc: 'rgba(224,179,74,.4)', op: '0.85', glyph: '‖', gc: '#e0b34a' };
    case 'err': return { bc: '#f97066', op: '1', glyph: '✕', gc: '#f97066' };
    case 'park': return { bc: 'rgba(224,179,74,.5)', op: '0.75', glyph: '▣', gc: '#e0b34a' };
    default: return { bc: 'rgba(94,234,166,.13)', op: '1', glyph: '?', gc: '#93a89c' };
  }
}

// Heat-cell (ops wall strip) style. run splits on 30s: fresh #34d399, aging #1d8a63 (plan §5.3).
// ageSec may be null (queued/unknown) — only the run branch reads it.
export function heatStyle(state, ageSec) {
  switch (state) {
    case 'done': return { bg: '#101812', bd: 'rgba(94,234,166,.13)' };
    case 'cancelled': return { bg: '#101812', bd: 'rgba(147,168,156,.2)' };
    case 'q': return { bg: 'transparent', bd: 'rgba(147,168,156,.4)' };
    case 'err': return { bg: '#f97066', bd: 'transparent' };
    case 'stale': return { bg: '#e0b34a', bd: 'transparent' };
    case 'paused': return { bg: 'rgba(224,179,74,.35)', bd: 'rgba(224,179,74,.5)' };
    case 'park': return { bg: 'rgba(224,179,74,.35)', bd: 'transparent' };
    case 'run':
      return ageSec != null && ageSec > 30
        ? { bg: '#1d8a63', bd: 'transparent' }
        : { bg: '#34d399', bd: 'transparent' };
    default: return { bg: 'transparent', bd: 'rgba(147,168,156,.4)' };
  }
}

// --- per-lane event summarizers (ported VERBATIM from legacy-cockpit.html) -------------------
//
// The three worker CLIs (claude/glm, codex, gemini) each emit a different JSONL schema. These map
// every shape seen on the bus to {badge, cls, text}; anything else falls through to a compact
// "type · keys" line. Do not refactor — the firehose + drawer events tab must match the old page.

function paramStr(p) {
  if (p == null) return '';
  return typeof p === 'string' ? p : (() => {
    try { return JSON.stringify(p); } catch { return String(p); }
  })();
}

function contentToText(c) {
  if (c == null) return '';
  if (typeof c === 'string') return c;
  if (Array.isArray(c)) return c.map((x) => (typeof x === 'string' ? x : (x.text ?? JSON.stringify(x)))).join(' ');
  return JSON.stringify(c);
}

// "first meaningful line" — a tool result is often a multi-line dump; the summary row only needs
// the first line, the full text is still one click away via click-to-expand.
function firstLine(s) {
  s = String(s ?? '');
  const nl = s.indexOf('\n');
  return nl === -1 ? s : s.slice(0, nl) + ' …';
}

// tool_use is generic (name + full param JSON) except Bash, where the command IS the summary —
// showing the wrapping JSON just to say "Bash" is exactly the raw-JSON noise this exists to kill.
export function toolUseText(name, input) {
  if (name === 'Bash' && input && typeof input.command === 'string') return input.command;
  return `${name || 'tool'} ${paramStr(input)}`;
}

// A "success"-shaped type (result, item.completed) can still carry a failure — check the usual
// signal fields before defaulting to the green badge.
export function looksFailed(...targets) {
  for (const t of targets) {
    if (!t || typeof t !== 'object') continue;
    if (t.is_error) return true;
    if (typeof t.subtype === 'string' && /error|fail/i.test(t.subtype)) return true;
    if (typeof t.status === 'string' && /error|fail/i.test(t.status)) return true;
    if (typeof t.exit_code === 'number' && t.exit_code !== 0) return true;
  }
  return false;
}

// claude: assistant/user envelopes carry the real event(s) nested in message.content[] blocks —
// a turn can mix thinking/text/tool_use/tool_result in one record. Classify every block, lead
// with the first one that has real content, and note how many others rode along.
export function classifyBlock(b, envType) {
  if (b.type === 'tool_use') return { kind: 'tool_use', badge: 'tool_use', cls: 'b-blue', text: toolUseText(b.name, b.input) };
  if (b.type === 'tool_result') return { kind: 'tool_result', badge: 'tool_result', cls: b.is_error ? 'b-red' : 'b-dim', text: firstLine(contentToText(b.content)) };
  if (b.type === 'text' && b.text) return { kind: 'text', badge: envType === 'assistant' ? 'agent_message' : 'user', cls: 'b-green', text: b.text };
  if (b.type === 'thinking' && b.thinking) return { kind: 'thinking', badge: 'thinking', cls: 'b-dim', text: b.thinking };
  return null; // empty thinking block, or a block type we don't render — skip
}

export function summarizeBlocks(blocks, envType) {
  const items = blocks.map((b) => classifyBlock(b, envType)).filter(Boolean);
  if (!items.length) return { badge: envType, cls: 'b-dim', text: '(no text content)' };
  const [primary, ...rest] = items;
  if (!rest.length) return primary;
  const counts = {};
  for (const r of rest) counts[r.kind] = (counts[r.kind] || 0) + 1;
  const suffix = Object.entries(counts).map(([k, n]) => `+${n} ${k}`).join(', ');
  return { ...primary, text: `${primary.text} (${suffix})` };
}

export function summarize(o) {
  const type = o.type || 'unknown';

  if ((type === 'assistant' || type === 'user') && o.message && Array.isArray(o.message.content)) {
    return summarizeBlocks(o.message.content, type);
  }

  switch (type) {
    case 'tool_use':
      return { badge: 'tool_use', cls: 'b-blue', text: toolUseText(o.tool_name || o.name, o.parameters ?? o.input) };
    case 'tool_result':
      return { badge: 'tool_result', cls: looksFailed(o) ? 'b-red' : 'b-dim', text: firstLine(contentToText(o.output ?? o.content ?? o.result)) };
    case 'tool_progress':
      return { badge: 'progress', cls: 'b-dim', text: `${o.tool_name || o.name || 'tool'} running…` };
    case 'system': {
      // thinking_tokens is the noisiest system subtype by far — give it its own line so the
      // coalesced row reads as a token count, not a JSON blob.
      if (o.subtype === 'thinking_tokens') {
        const n = o.estimated_tokens ?? o.tokens ?? 0;
        return { badge: 'thinking_tokens', cls: 'b-dim', text: `~${Number(n).toLocaleString()} tokens estimated` };
      }
      const numKey = Object.keys(o).find((k) => k !== 'type' && k !== 'subtype' && typeof o[k] === 'number');
      const salient = numKey ? ` ${numKey}=${Number(o[numKey]).toLocaleString()}` : '';
      return { badge: o.subtype || 'system', cls: 'b-dim', text: `${o.subtype || 'system'}${salient}` };
    }
    case 'result':
      return { badge: 'result', cls: looksFailed(o) ? 'b-red' : 'b-green', text: firstLine(o.result ?? o.summary ?? JSON.stringify(o)) };
    case 'turn.completed':
      return { badge: 'turn.completed', cls: 'b-green', text: `usage: ${usageStr(o.usage)}` };
    case 'error':
    case 'turn.failed':
      return { badge: type, cls: 'b-red', text: firstLine(o.message ?? o.error ?? JSON.stringify(o)) };
    case 'thought':
    case 'text':
      return { badge: type, cls: type === 'text' ? 'b-green' : 'b-dim', text: o.data };
    case 'end':
      return { badge: 'end', cls: 'b-dim', text: `session ended${o.result ? ': ' + paramStr(o.result) : ''}` };
    case 'message':
      return { badge: 'message', cls: 'b-green', text: firstLine(contentToText(o.content)) };
    case 'item.completed': {
      const item = o.item ?? o.content;
      return { badge: 'item.completed', cls: looksFailed(o, item) ? 'b-red' : 'b-green', text: firstLine(contentToText(item)) };
    }
    default:
      // never the raw JSON body — a compact "type · keys" line instead.
      return { badge: type, cls: 'b-dim', text: `${type} · ${Object.keys(o).filter((k) => k !== 'type').join(',')}` };
  }
}

// Compact humanized usage line for turn.completed — same fields costSummary() sums server-side.
export function usageStr(u) {
  if (!u || typeof u !== 'object') return '(none)';
  const inTok = u.input_tokens ?? u.prompt_tokens ?? 0;
  const outTok = u.output_tokens ?? u.completion_tokens ?? 0;
  return `${fmtTok(inTok)} in / ${fmtTok(outTok)} out`;
}

// Coarse category for the firehose filter chips — derived from the fine-grained badge (not the
// raw `type`) so an assistant envelope whose PRIMARY block is e.g. a tool_use still files under
// "tools", matching what the row actually shows.
export function kindFromBadge(badge) {
  if (badge === 'tool_use' || badge === 'tool_result') return 'tools';
  if (badge === 'progress') return 'progress';
  if (badge === 'thinking' || badge === 'thinking_tokens') return 'thinking';
  if (badge === 'agent_message' || badge === 'user' || badge === 'result' || badge === 'message' || badge === 'item.completed') return 'text';
  return 'system'; // turn.completed, end, error, turn.failed, other system subtypes, unknown
}

// --- coalescing key tables (ported verbatim — data.js coalesces at BUFFER level with these) ----
//
// Rule of thumb: consecutive events, same worker, same raw `type` (+ same tool_use_id/subtype
// where present) = one row that updates in place with a spinner, instead of one row each. Covers
// system/thinking_tokens and tool_progress pings, and grok's thought/text delta-stream fragments.
// Excluded: types that are already one discrete, meaningful item, never a heartbeat/delta.
export const NEVER_COALESCE_TYPES = new Set([
  'assistant', 'user', 'result', 'turn.completed', 'error', 'turn.failed',
  'end', 'item.completed', 'message', 'tool_result', 'tool_use',
]);

// Delta-fragment types whose text should ACCUMULATE across the streak (grok's token-by-token
// thought/text stream); everything else (thinking_tokens, tool_progress, …) shows the latest
// value in place — concatenating those would just repeat the same status line.
export const ACCUMULATE_TYPES = new Set(['thought', 'text']);

export function coalesceKeyOf(worker, obj) {
  const type = obj.type || 'unknown';
  if (NEVER_COALESCE_TYPES.has(type)) return null;
  const scope = obj.tool_use_id ? `:${obj.tool_use_id}` : (obj.subtype ? `:${obj.subtype}` : '');
  return `${worker}:${type}${scope}`;
}
