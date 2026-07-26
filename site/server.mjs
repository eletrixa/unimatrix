#!/usr/bin/env node
/**
 * Zero-dependency local web server: serves the public site plus /api/* views of the swarm's file-bus, and the two guarded POST mutation routes (spec 07 §4.5, specs/05-ground-control.md).
 *
 * Project: unimatrix — multi-model swarm orchestrator driven from Claude Code
 * Module:  site/server.mjs
 * Deps:    node:http, node:fs, node:path, node:url, node:child_process (execFile, execFileSync),
 *          node:os (tmpdir) — stdlib only, zero npm deps, no build
 * Tested:  tests/ground-control.bats, tests/cockpit-api.bats, tests/cockpit-ctl.bats
 *
 * Key responsibilities:
 * - GET /health ({ok, root, branch, head, busdir} — P0-FR4, matches swarm-run.sh's run-start
 *   banner), /api/bus (counts + stale leases + limits + parked + done list), /api/cost
 *   (per-lane token sums, ported from swarm-mon.sh _cost_summary), /api/models (live per-model
 *   usage + notional $/hr), /api/stream (SSE tail of run-*.jsonl; named events `replay-done`
 *   once per connection when the initial backfill is complete, and `ping` every 15s), GET/POST /api/config
 *   (swarm.conf lane settings, ALLOWLISTED keys only)
 * - GET /api/agents (per-agent grid snapshot derived from bus files + run logs), /api/loop
 *   (newest loop run state), /api/agent?id= (drawer bodies, size-capped + id-validated),
 *   POST /api/ctl (control verbs delegated to src/swarm-ctl via a fixed execFile argv table)
 * - Static file serving of site/ with path-traversal protection, for everything else
 * - Security headers (nosniff/frame-deny/referrer/permissions-policy + CSP on HTML/static) on
 *   every response, an audit log line per mutation outcome, and a combined 60-req/10s rate
 *   limit across the two POST routes
 *
 * Design constraints:
 * - Read-only on BUSDIR except bus mutations delegated to src/swarm-ctl as an execFile child
 *   with a fixed argv table; the server process itself owns exactly one append-only file under
 *   BUSDIR, audit.jsonl (auditLog), and never writes anything else there. swarm.conf (CONF_FILE)
 *   is the other write surface, only via POST /api/config against the fixed ALLOWLIST in
 *   CONFIG_VALIDATORS.
 * - No handler may crash the process — every request path is wrapped and errors become HTTP 500
 * - 500 bodies are always the fixed {"error":"internal error"} — exception detail goes to
 *   console.error only, never to the client
 * - Excluded from the Cloudflare Pages asset upload via .assetsignore (never ships publicly)
 */
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { execFile, execFileSync } from "node:child_process";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const SITE_ROOT = __dirname;
const REPO_ROOT = path.dirname(SITE_ROOT);
const PORT = Number(process.env.PORT) || 4747;
const BUSDIR = process.env.BUSDIR || path.join(REPO_ROOT, ".bus");
const CONF_FILE = process.env.SWARM_CONF || path.join(REPO_ROOT, "swarm.conf");

// P0-FR4: /health's {root, branch, head} mirror swarm-run.sh's _print_banner exactly — same git
// plumbing commands. Resolved per REQUEST, not once at boot: mon_web_ensure (src/swarm-lib.sh)
// compares the served `head` against the checkout's current HEAD to spot a cockpit left running at
// an older commit, and a boot-time cache would report the value it started with forever, so the
// stale server would keep vouching for itself. Three execFileSync calls per /health is nothing at
// cockpit traffic. Falls back to REPO_ROOT/"unknown" rather than crashing if git is unavailable.
function gitField(args, fallback) {
  try {
    return execFileSync("git", args, { cwd: REPO_ROOT, encoding: "utf8" }).trim();
  } catch {
    return fallback;
  }
}

function gitState() {
  return {
    root: gitField(["rev-parse", "--show-toplevel"], REPO_ROOT),
    branch: gitField(["rev-parse", "--abbrev-ref", "HEAD"], "unknown"),
    head: gitField(["rev-parse", "--short", "HEAD"], "unknown"),
  };
}

// --- swarm.conf tolerant KEY=VALUE parser (mirrors src/swarm-lib.sh conf_load's leniency) -----

function readConfigText() {
  try {
    return fs.readFileSync(CONF_FILE, "utf8");
  } catch {
    return "";
  }
}

function parseConfigText(text) {
  const values = {};
  for (const raw of text.split("\n")) {
    const line = raw.replace(/#.*$/, "").trim();
    const m = line.match(/^([A-Z_]+)=(.*)$/);
    if (!m) continue;
    values[m[1]] = m[2].trim().replace(/^"(.*)"$/, "$1");
  }
  return values;
}

function readLeaseMin() {
  const v = Number(parseConfigText(readConfigText()).LEASE_MIN);
  return Number.isFinite(v) ? v : 15;
}

// --- /api/config: GET the allowlisted swarm.conf lane settings, POST to change one -------------

const LANES = "claude|codex|gemini|glm|grok|kimi";
const LANE_MODEL = `(?:${LANES}):[A-Za-z0-9._-]+`;
const LANE_PAIR = `(?:${LANES}):(?:${LANES})`;
// No leading zeros (a bare "0" is the only zero form); POSITIVE excludes zero for the counters
// that make no sense at 0 (fanout, timeouts, retries), DECIMAL allows "0"/"0.5" for a dollar cap.
const NUMERIC_POSITIVE = /^[1-9][0-9]*$/;
const NUMERIC_DECIMAL = /^(?:0|[1-9][0-9]*)(?:\.[0-9]+)?$/;

// Also doubles as the allowlist: only these keys are ever exposed or accepted.
const CONFIG_VALIDATORS = {
  FANOUT: NUMERIC_POSITIVE,
  MAX_ITERATIONS: NUMERIC_POSITIVE,
  WORKER_TIMEOUT_SEC: NUMERIC_POSITIVE,
  LEASE_MIN: NUMERIC_POSITIVE,
  MAX_LANE_RETRIES: NUMERIC_POSITIVE,
  BUDGET_USD: NUMERIC_DECIMAL,
  EXEC_CHAIN: new RegExp(`^${LANE_MODEL}( ${LANE_MODEL})*$`),
  REVIEW: new RegExp(`^${LANE_MODEL}$`),
  VERIFY_MAP: new RegExp(`^${LANE_PAIR}( ${LANE_PAIR})*$`),
};

function configSnapshot() {
  const values = parseConfigText(readConfigText());
  const out = {};
  for (const key of Object.keys(CONFIG_VALIDATORS)) {
    if (values[key] !== undefined) out[key] = values[key];
  }
  return out;
}

// Rewrites every `KEY=...` line (bash sourcing takes the LAST assignment on a duplicate key, so
// a single-line replace would leave the written value disagreeing with the effective one),
// preserving every other line and each match's trailing ` #` inline comment verbatim. Quotes the
// value when it contains whitespace (EXEC_CHAIN / VERIFY_MAP today). Atomic write: tmp file +
// rename in CONF_FILE's own directory.
function writeConfigValue(key, value) {
  const text = readConfigText();
  const quoted = /\s/.test(value) ? `"${value}"` : value;
  const keyRe = new RegExp(`^${key}=`);
  let found = false;
  const lines = text.split("\n").map((line) => {
    if (!keyRe.test(line)) return line;
    found = true;
    const commentAt = line.indexOf(" #");
    const comment = commentAt !== -1 ? line.slice(commentAt) : "";
    return `${key}=${quoted}${comment}`;
  });
  if (!found) throw new Error(`${key} not present in swarm.conf`);
  const tmp = path.join(path.dirname(CONF_FILE), `.swarm.conf.tmp-${process.pid}-${Date.now()}`);
  fs.writeFileSync(tmp, lines.join("\n"), "utf8");
  fs.renameSync(tmp, CONF_FILE);
}

// Reads the request body up to maxBytes, parses JSON; cb(err) on oversize/malformed/stream error.
// On oversize, stops accumulating and reports the error immediately WITHOUT destroying the
// socket — the caller still needs it alive to write the 400 response; later chunks are drained
// harmlessly by the `settled` guard below.
function readJsonBody(req, maxBytes, cb) {
  let size = 0;
  const chunks = [];
  let settled = false;
  const finish = (err, body) => {
    if (settled) return;
    settled = true;
    cb(err, body);
  };
  req.on("data", (chunk) => {
    if (settled) return;
    size += chunk.length;
    if (size > maxBytes) {
      finish(new Error("body too large"));
      return;
    }
    chunks.push(chunk);
  });
  req.on("end", () => {
    try {
      finish(null, JSON.parse(Buffer.concat(chunks).toString("utf8") || "{}"));
    } catch (err) {
      finish(err);
    }
  });
  req.on("error", (err) => finish(err));
}

// Fixed-window rate limit shared by both write routes: max 60 requests per 10s window, combined.
// Module-level counter, no deps — the window resets lazily on the first request after it elapses.
const RATE_LIMIT_MAX = 60;
const RATE_LIMIT_WINDOW_MS = 10000;
let rateLimitWindowStart = 0;
let rateLimitCount = 0;
function rateLimited() {
  const now = Date.now();
  if (now - rateLimitWindowStart >= RATE_LIMIT_WINDOW_MS) {
    rateLimitWindowStart = now;
    rateLimitCount = 0;
  }
  rateLimitCount += 1;
  return rateLimitCount > RATE_LIMIT_MAX;
}

// Shared guard for the two POST routes (/api/config, /api/ctl): rate limit → Origin loopback
// check → 10s request timeout (caps a half-sent body so the route can't hang) → readJsonBody(cap)
// → handler. The handler returns {status, body} synchronously OR a Promise of one (ctl shells out
// async); either way a throw becomes a 500, matching the original /api/config POST's try/catch
// shape. No locking for concurrent ctl calls — the underlying verbs are mv/rm-based, race-tolerant.
function guardedPost(req, res, maxBytes, handler) {
  if (rateLimited()) {
    jsonResponse(res, 429, { error: "rate limited" });
    return;
  }
  if (!originAllowed(req)) {
    jsonResponse(res, 403, { error: "forbidden origin" });
    return;
  }
  req.setTimeout(10000, () => req.destroy());
  readJsonBody(req, maxBytes, (err, body) => {
    const fail500 = (e) => {
      console.error(e);
      try {
        jsonResponse(res, 500, { error: "internal error" });
      } catch {
        // response already sent — nothing more we can do
      }
    };
    try {
      if (err) {
        jsonResponse(res, 400, { error: "bad request body" });
        return;
      }
      const result = handler(body);
      if (result && typeof result.then === "function") {
        result.then((r) => {
          if (r) jsonResponse(res, r.status, r.body);
        }, fail500);
      } else if (result) {
        jsonResponse(res, result.status, result.body);
      }
    } catch (e) {
      fail500(e);
    }
  });
}

// --- fs helpers, all read-only -------------------------------------------------------------

function listNames(dir) {
  try {
    return fs.readdirSync(dir);
  } catch {
    return [];
  }
}

function staleLeases(dir, leaseMin) {
  const cutoff = Date.now() - leaseMin * 60 * 1000;
  const out = [];
  for (const name of listNames(dir)) {
    try {
      const st = fs.statSync(path.join(dir, name));
      if (st.isFile() && st.mtimeMs < cutoff) out.push(name);
    } catch {
      // file disappeared between readdir and stat — ignore
    }
  }
  return out;
}

function busSnapshot() {
  const leaseMin = readLeaseMin();
  const doneDir = path.join(BUSDIR, "done");
  const doneEntries = listNames(doneDir)
    .map((name) => {
      try {
        return { name, mtimeMs: fs.statSync(path.join(doneDir, name)).mtimeMs };
      } catch {
        return null;
      }
    })
    .filter(Boolean)
    .sort((a, b) => b.mtimeMs - a.mtimeMs)
    .slice(0, 50)
    .map((e) => e.name);

  const limitsDir = path.join(BUSDIR, "limits");
  const limitsNames = listNames(limitsDir);
  const active_limits = limitsNames
    .filter((n) => n.endsWith(".limited"))
    .map((n) => n.slice(0, -".limited".length));
  const parked = limitsNames
    .filter((n) => n.endsWith(".parked"))
    .map((n) => n.slice(0, -".parked".length));

  return {
    counts: {
      // only *.prompt is a unit of work — a pinned/write branch's <id>.lane/<id>.write sidecars
      // share queue/ but are not separate branches (matches gate_count / the tmux board).
      queued: listNames(path.join(BUSDIR, "queue")).filter((n) => n.endsWith(".prompt")).length,
      claimed: listNames(path.join(BUSDIR, "claimed")).length,
      done: listNames(doneDir).length,
      cancelled: listNames(path.join(BUSDIR, "cancelled")).length,
    },
    lease_min: leaseMin,
    stale_leases: staleLeases(path.join(BUSDIR, "claimed"), leaseMin),
    active_limits,
    parked,
    done: doneEntries,
  };
}

// --- /api/cost: port of swarm-mon.sh _cost_summary's envelope heuristics -----------------------

function sumNumbers(v) {
  if (typeof v === "number") return v;
  if (Array.isArray(v)) return v.reduce((s, x) => s + sumNumbers(x), 0);
  if (v && typeof v === "object") {
    return Object.values(v).reduce((s, x) => s + sumNumbers(x), 0);
  }
  return 0;
}

// swarm-mon.sh _cost_summary sums only the TOP-LEVEL numeric fields of .usage
// (`[.usage[]?] | map(select(type=="number"))`). Match it exactly for the codex/claude/glm usage
// buckets so the web COST panel and the tmux cost pane never disagree (specs/05 says this ports
// _cost_summary's heuristics). Gemini's stats.models is summed recursively in both (see below).
function sumUsageTopLevel(u) {
  if (!u || typeof u !== "object") return 0;
  return Object.values(u).reduce((s, x) => s + (typeof x === "number" ? x : 0), 0);
}

function costSummary() {
  const totals = new Map(); // lane -> tokens
  const bump = (lane, tokens) => totals.set(lane, (totals.get(lane) || 0) + tokens);

  for (const name of listNames(BUSDIR)) {
    if (!/^run-.*\.jsonl$/.test(name)) continue;
    let text;
    try {
      text = fs.readFileSync(path.join(BUSDIR, name), "utf8");
    } catch {
      continue;
    }
    for (const raw of text.split("\n")) {
      if (!raw.trim()) continue;
      let obj;
      try {
        obj = JSON.parse(raw);
      } catch {
        continue; // malformed line — skip, never crash
      }
      if (obj && obj.type === "turn.completed" && obj.usage != null) {
        bump("codex", sumUsageTopLevel(obj.usage));
      } else if (obj && obj.type === "result" && obj.usage != null) {
        bump("claude/glm", sumUsageTopLevel(obj.usage));
      } else if (obj && obj.type === "result" && obj.stats && obj.stats.models != null) {
        for (const [model, stats] of Object.entries(obj.stats.models)) {
          bump(`gemini:${model}`, sumNumbers(stats));
        }
      }
    }
  }

  return [...totals.entries()].map(([lane, tokens]) => ({ lane, tokens }));
}

// --- /api/models: live per-MODEL usage + NOTIONAL $/hour (spec 06) ------------------------------

// Public list prices, USD per MILLION tokens. NOTIONAL — a labeled usage proxy, NEVER a bill (most
// lanes are subscription/OAuth pools that bill $0 real). `cache` = cache-read rate; defaults to
// in*0.1 when omitted. Tune freely; a family with no row prices at $0 and is flagged `unpriced`.
const PRICES = {
  "claude-fable": { in: 10, out: 50 },
  "claude-opus": { in: 5, out: 25 },
  "claude-sonnet": { in: 3, out: 15 },
  "claude-haiku": { in: 1, out: 5 },
  glm: { in: 0.6, out: 2.2 },
  gemini: { in: 0.3, out: 2.5 },
  codex: { in: 1.25, out: 10 },
  grok: { in: 3, out: 15 },
  kimi: { in: 3, out: 15 }, // cache-hit rate 0.3 = 3*0.1, matches Moonshot's $0.30/M cache list price
};

// Normalize a raw provider model string to a stable family key (spec 06 §A).
function normalizeModel(raw) {
  if (!raw) return null;
  const m = String(raw).toLowerCase();
  if (m.includes("fable")) return "claude-fable";
  if (m.includes("opus")) return "claude-opus";
  if (m.includes("sonnet")) return "claude-sonnet";
  if (m.includes("haiku")) return "claude-haiku";
  if (m.includes("glm")) return "glm";
  if (m.includes("gemini")) return "gemini";
  if (m.includes("grok")) return "grok";
  if (m.includes("kimi")) return "kimi";
  if (m.includes("gpt") || m.includes("codex")) return "codex";
  return m;
}

// The model string can sit on the record (`model`), its `message` envelope (claude), or — grok's
// streaming events carry no model field at all — as the sole/first KEY of its `end` event's
// `modelUsage` object (e.g. `{"type":"end","modelUsage":{"grok-4.5-build":{...}}}`).
function modelOf(obj) {
  if (!obj || typeof obj !== "object") return null;
  if (typeof obj.model === "string") return obj.model;
  if (obj.message && typeof obj.message.model === "string") return obj.message.model;
  if (obj.modelUsage && typeof obj.modelUsage === "object") {
    const k = Object.keys(obj.modelUsage)[0];
    if (k) return k;
  }
  return null;
}

// Pull the priced token buckets out of a `.usage` object, tolerating the three lane schemas
// (claude result/end vs codex turn.completed — spec 06 §A). cache-read is named differently per
// provider; input_tokens is non-cache on claude but includes cache on codex, so subtract there.
function usageBuckets(u) {
  if (!u || typeof u !== "object") return null;
  const num = (v) => (typeof v === "number" ? v : 0);
  const cacheRead = num(u.cache_read_input_tokens) + num(u.cached_input_tokens);
  const cacheCreate = num(u.cache_creation_input_tokens);
  const inputRaw = num(u.input_tokens);
  // codex (cached_input_tokens key, no cache_creation) folds cache into input_tokens; claude does not.
  const codexShape = u.cached_input_tokens != null && u.cache_creation_input_tokens == null;
  const inputNonCache = codexShape ? Math.max(0, inputRaw - cacheRead) : inputRaw;
  // reasoning is billed as output; add only the explicitly-separate reasoning line items.
  const output = num(u.output_tokens) + num(u.reasoning_tokens) + num(u.reasoning_output_tokens);
  const total = inputNonCache + cacheRead + cacheCreate + output;
  if (total === 0) return null; // not a real usage event
  return { inputNonCache, cacheRead, cacheCreate, output, total };
}

// NOTIONAL dollars for one event's buckets (spec 06 §B). Unknown family ⇒ 0 + unpriced flag.
function priceBuckets(family, b) {
  const p = PRICES[family];
  if (!p) return { dollars: 0, unpriced: true };
  const cacheRate = p.cache ?? p.in * 0.1;
  const dollars =
    (b.inputNonCache * p.in + b.cacheRead * cacheRate + b.cacheCreate * p.in + b.output * p.out) /
    1e6;
  return { dollars, unpriced: false };
}

// Parse `ts` (ISO-8601 or epoch-ms) to epoch ms, or null.
function parseTs(ts) {
  if (typeof ts === "number") return ts;
  if (typeof ts === "string") {
    const v = Date.parse(ts);
    if (Number.isFinite(v)) return v;
  }
  return null;
}

// Speedwars evidence ledger (spec 09 FR-1). Historical, NOT live-bus: reads the append-only
// docs/ops/speedwars.jsonl and splits it by row type. Card rows are the ones with no `type` field
// — that absence is the discriminator (spec 08 FR-1). Aggregation happens in the client fold
// (site/cockpit/speed.js) — a SECOND implementation exists in src/speedwars-report.sh, and the two
// are held identical by the shared contract fixture tests/fixtures/verdict-fold/ (P0-FR7): both
// replay the same fixture to the same expected aggregates, so divergence turns a test red.
// Never throws: a malformed line is skipped, a missing file is `available:false`.
const SPEEDWARS_FILE =
  process.env.SPEEDWARS_FILE || path.join(REPO_ROOT, "docs", "ops", "speedwars.jsonl");
const SPEEDWARS_MAX_BYTES = 8 * 1024 * 1024;

function speedwarsSnapshot() {
  const empty = {
    available: false,
    generated_at: new Date().toISOString(),
    cards: [],
    verdicts: [],
    run_meta: [],
    reviews: [],
    run_reviews: [],
  };

  let stat;
  try {
    stat = fs.statSync(SPEEDWARS_FILE);
  } catch {
    return empty; // no ledger yet — a fresh clone that has never run a swarm
  }
  if (!stat.isFile() || stat.size > SPEEDWARS_MAX_BYTES) return empty;

  let text;
  try {
    text = fs.readFileSync(SPEEDWARS_FILE, "utf8");
  } catch {
    return empty;
  }

  const out = { ...empty, available: true, mtime: stat.mtime.toISOString() };
  const BY_TYPE = {
    verdict: out.verdicts,
    "run-meta": out.run_meta,
    review: out.reviews,
    "run-review": out.run_reviews,
  };
  for (const raw of text.split("\n")) {
    if (!raw.trim()) continue;
    let obj;
    try {
      obj = JSON.parse(raw);
    } catch {
      continue; // malformed line — skip, never crash (same policy as costSummary)
    }
    if (!obj || typeof obj !== "object") continue;
    const bucket = obj.type == null ? out.cards : BY_TYPE[obj.type];
    if (bucket) bucket.push(obj); // unknown future row types are dropped, not guessed at
  }
  return out;
}

// Best-effort per-model live view. Carries the last-seen model + timestamp forward within each run
// and attributes each token event to them; buckets by normalized family; a trailing 5-min window
// drives $/hour (spec 06 §A–C). Never throws — a bad line/file is skipped.
function modelsSummary(now = Date.now()) {
  const WINDOW_MS = 5 * 60 * 1000;
  const RUNNING_MS = 30 * 1000;
  const acc = new Map(); // family -> {tokens_total, tokens_5m, input_5m, output_5m, dollars_5m, last_ms, unpriced}

  for (const name of listNames(BUSDIR)) {
    if (!/^run-.*\.jsonl$/.test(name)) continue;
    let text;
    try {
      text = fs.readFileSync(path.join(BUSDIR, name), "utf8");
    } catch {
      continue;
    }
    let curModel = null;
    let curTs = null;
    // A run with no timestamped line at all still gets a coarse time from the file's mtime, so its
    // usage can land in (or out of) the window rather than silently never counting.
    let fileTs = null;
    try {
      fileTs = fs.statSync(path.join(BUSDIR, name)).mtimeMs;
    } catch {
      /* keep null */
    }
    for (const raw of text.split("\n")) {
      if (!raw.trim()) continue;
      let obj;
      try {
        obj = JSON.parse(raw);
      } catch {
        continue;
      }
      const m = modelOf(obj);
      if (m) curModel = m;
      const t = parseTs(obj.timestamp);
      if (t != null) curTs = t;

      const b = usageBuckets(obj.usage);
      if (!b) continue;
      const family =
        normalizeModel(curModel) || (obj.type === "turn.completed" ? "codex" : "unknown");
      const when = curTs ?? fileTs ?? now;
      const { dollars, unpriced } = priceBuckets(family, b);

      const a = acc.get(family) || {
        tokens_total: 0,
        tokens_5m: 0,
        input_5m: 0,
        output_5m: 0,
        dollars_5m: 0,
        last_ms: 0,
        unpriced: false,
      };
      a.tokens_total += b.total;
      if (when >= now - WINDOW_MS) {
        a.tokens_5m += b.total;
        a.input_5m += b.inputNonCache + b.cacheRead + b.cacheCreate;
        a.output_5m += b.output;
        a.dollars_5m += dollars;
      }
      if (when > a.last_ms) a.last_ms = when;
      if (unpriced) a.unpriced = true;
      acc.set(family, a);
    }
  }

  return [...acc.entries()]
    .map(([model, a]) => ({
      model,
      tokens_total: a.tokens_total,
      tokens_5m: a.tokens_5m,
      input_5m: a.input_5m,
      output_5m: a.output_5m,
      dollars_5m: a.dollars_5m,
      dollars_per_hour: a.dollars_5m * 12,
      running: a.last_ms >= now - RUNNING_MS,
      unpriced: a.unpriced,
    }))
    .sort((x, y) => y.dollars_per_hour - x.dollars_per_hour || y.tokens_5m - x.tokens_5m);
}

// --- /api/stream: SSE tail of BUSDIR/run-*.jsonl ------------------------------------------------

function startStream(res) {
  res.writeHead(200, {
    "Content-Type": "text/event-stream",
    "Cache-Control": "no-cache",
    Connection: "keep-alive",
    ...baseSecurityHeaders(),
  });

  const offsets = new Map(); // filename -> bytes already sent

  const poll = () => {
    for (const name of listNames(BUSDIR)) {
      if (!/^run-.*\.jsonl$/.test(name)) continue;
      const full = path.join(BUSDIR, name);
      let st;
      try {
        st = fs.statSync(full);
      } catch {
        continue;
      }
      let sent = offsets.get(name) || 0;
      // truncation = rewrite: tee (no -a) truncates run-<id>.jsonl when a failover re-runs the
      // same id — a shrunken file is new content, restart from 0 (tail -F's rotation handling).
      if (st.size < sent) sent = 0;
      if (st.size <= sent) continue;

      let buf;
      try {
        const fd = fs.openSync(full, "r");
        buf = Buffer.alloc(st.size - sent);
        fs.readSync(fd, buf, 0, buf.length, sent);
        fs.closeSync(fd);
      } catch {
        continue;
      }
      // Advance only past the last COMPLETE line: tee flushes partial lines constantly, so a
      // 500ms poll routinely lands mid-record — consuming the fragment would emit the record as
      // two garbage halves, permanently (the tmux firehose never had this bug: jq -R blocks on
      // the newline). Bytes after the last \n stay unconsumed for the next poll. Byte-indexed on
      // the buffer, not the decoded string, so a split multibyte char can't skew the offset.
      const nl = buf.lastIndexOf(0x0a);
      if (nl === -1) {
        offsets.set(name, sent); // keep any truncation reset, but consume nothing yet
        continue;
      }
      offsets.set(name, sent + nl + 1);
      const chunk = buf.toString("utf8", 0, nl);

      const worker = name.replace(/^run-/, "").replace(/\.jsonl$/, "");
      for (const line of chunk.split("\n")) {
        if (!line.trim()) continue;
        // `ts` = server receive time, so the firehose can show a real clock even for the token
        // summary events that carry no `timestamp` of their own (spec 06 §D).
        let payload;
        try {
          payload = { worker, ts: Date.now(), line: JSON.parse(line) };
        } catch {
          payload = { worker, ts: Date.now(), line }; // malformed line — forward raw, never crash
        }
        res.write(`data: ${JSON.stringify(payload)}\n\n`);
      }
    }
  };

  poll(); // pick up anything already on disk before the first tick
  // End-of-replay sentinel (backlog 24): everything written above is backfill from disk,
  // everything after is live. The cockpit used to guess this with a 2s wall clock, which a big bus
  // outran — the tail of a long replay crossed the mark, got counted as live, and stamped
  // lastEvtClient=now on agents that finished hours ago, silencing their stale/silent alerts.
  // Emitted unconditionally (an empty bus still gets it) and exactly once per connection;
  // EventSource auto-reconnect opens a NEW connection, which replays from byte 0 and gets its own.
  res.write("event: replay-done\ndata: {}\n\n");
  const pollTimer = setInterval(poll, 500);
  // Named event, not an SSE comment: EventSource never surfaces comments, and the cockpit's
  // zombie-socket watchdog needs an observable liveness signal to detect a dead connection.
  const heartbeat = setInterval(() => res.write("event: ping\ndata: {}\n\n"), 15000);

  const cleanup = () => {
    clearInterval(pollTimer);
    clearInterval(heartbeat);
  };
  res.on("close", cleanup);
  res.req.on("close", cleanup);
}

// --- cockpit API: shared primitives (spec 07 §4.1) -------------------------------------------
//
// ID_RE validates EVERY id before any fs access or spawn. First char is alnum, so an id can
// never parse as a `-`-option (no argv injection) and never contains `/` or a leading dot (no
// path traversal: `..`, `.hidden`, `-flag` all rejected).
const ID_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;

// Parses claimed/<id>.<lane:model>. The lane:model suffix is anchored by its single `:`, so dots
// inside the id (s4r.api) and inside the model (glm-5.2) both survive — group1 = id, group2 =
// "lane:model". reap()/swarm-ctl split on the first dot; this regex matches that contract.
const CLAIM_RE = /^(.+)\.((?:claude|codex|gemini|glm|grok|kimi):[A-Za-z0-9._-]+)$/;

// Lane:model pin for the add verb's --lane sidecar. gemini is deliberately ABSENT: it is a
// read-only lane (refuses to write files), so a write-granting spec pinned to it is nonsense and
// is refused before swarm-ctl is ever invoked (mirrors src/swarm-ctl lane_cmd's refusal).
const LANE_PIN_RE = /^(claude|codex|glm|grok|kimi):[A-Za-z0-9._-]+$/;

// readCapped — reads up to capBytes of a file; tail=true returns the LAST capBytes (stderr tail),
// head (default) the FIRST (spec/res bodies). Returns {text,size,truncated} (size = full file size)
// or null if absent. Never throws — a missing/unreadable file is a normal "not present" signal.
function readCapped(file, capBytes, { tail = false } = {}) {
  let st;
  try {
    st = fs.statSync(file);
  } catch {
    return null;
  }
  if (!st.isFile()) return null;
  const size = st.size;
  const truncated = size > capBytes;
  const readAll = () => {
    const fd = fs.openSync(file, "r");
    try {
      const buf = Buffer.alloc(size);
      fs.readSync(fd, buf, 0, size, 0);
      return buf.toString("utf8");
    } finally {
      fs.closeSync(fd);
    }
  };
  const readSlice = () => {
    const fd = fs.openSync(file, "r");
    try {
      const start = tail ? size - capBytes : 0;
      const buf = Buffer.alloc(capBytes);
      fs.readSync(fd, buf, 0, capBytes, start);
      return buf.toString("utf8");
    } finally {
      fs.closeSync(fd);
    }
  };
  try {
    const text = truncated ? readSlice() : readAll();
    return { text, size, truncated };
  } catch {
    return null;
  }
}

// run-<id>.jsonl is append-only (a failover truncate-rewrites it, changing size), so (size,
// mtimeMs) is a sound cache key — the 2s /api/agents poll stays cheap at 50+ agents. A vanished
// file is evicted. Parses the log ONCE per change into the summary fields the grid + drawer need.
const RUN_CACHE = new Map(); // filename -> {size, mtimeMs, summary}

function runSummary(name) {
  const full = path.join(BUSDIR, name);
  let st;
  try {
    st = fs.statSync(full);
  } catch {
    RUN_CACHE.delete(name); // evict vanished/rotated file
    return null;
  }
  if (!st.isFile()) return null;
  const cached = RUN_CACHE.get(name);
  if (cached && cached.size === st.size && cached.mtimeMs === st.mtimeMs) {
    return cached.summary;
  }
  const summary = parseRunSummary(full, st);
  RUN_CACHE.set(name, { size: st.size, mtimeMs: st.mtimeMs, summary });
  return summary;
}

function parseRunSummary(full, st) {
  const s = {
    tokens: 0,
    dollars: 0,
    cost_usd: 0,
    errors: 0,
    model: null,
    first_ts: null,
    last_type: null,
    last_excerpt: "",
  };
  let text;
  try {
    text = fs.readFileSync(full, "utf8");
  } catch {
    return s;
  }
  let curModel = null;
  for (const raw of text.split("\n")) {
    if (!raw.trim()) continue;
    let obj;
    try {
      obj = JSON.parse(raw);
    } catch {
      continue; // malformed line — skip, never crash
    }
    if (!obj || typeof obj !== "object") continue;
    const t = typeof obj.type === "string" ? obj.type : null;

    const m = modelOf(obj);
    if (m) {
      curModel = m;
      s.model = m;
    }
    const ts = parseTs(obj.timestamp);
    if (ts != null && s.first_ts == null) s.first_ts = ts;

    if (t === "error" || t === "turn.failed") s.errors += 1;

    if (obj.usage) {
      const b = usageBuckets(obj.usage);
      if (b) {
        s.tokens += b.total;
        const family = normalizeModel(curModel) || (t === "turn.completed" ? "codex" : "unknown");
        s.dollars += priceBuckets(family, b).dollars;
      }
    }
    if (typeof obj.total_cost_usd === "number") s.cost_usd += obj.total_cost_usd;

    if (t) {
      s.last_type = t;
      s.last_excerpt = excerptOf(obj, t);
    }
  }
  // No timestamped line at all → fall back to the file's own birth/mtime so ages still resolve.
  if (s.first_ts == null) {
    s.first_ts = Number.isFinite(st.birthtimeMs) && st.birthtimeMs > 0 ? st.birthtimeMs : st.mtimeMs;
  }
  return s;
}

// ≤120-char humanized one-liner for an agent's last event, mirroring the firehose summarize()
// priority so /api/agents last_activity agrees with the drawer's events tab. message content |
// grok .data | .result | codex .item.text | .error | .text | the type itself (never empty).
function excerptOf(obj, type) {
  let text = null;
  if (obj.message && Array.isArray(obj.message.content)) {
    text = obj.message.content
      .map((c) =>
        typeof c === "string" ? c : c && typeof c.text === "string" ? c.text : ""
      )
      .join(" ");
  }
  if (!text && typeof obj.data === "string") text = obj.data;
  if (!text && typeof obj.result === "string") text = obj.result;
  if (!text && obj.item && typeof obj.item.text === "string") text = obj.item.text;
  if (!text && typeof obj.error === "string") text = obj.error;
  if (!text && typeof obj.text === "string") text = obj.text;
  if (!text) text = type;
  const one = String(text).replace(/\s+/g, " ").trim();
  return one.length > 120 ? one.slice(0, 120) : one;
}

// parseMarkerTtl(text, dflt) — spec 14 FR-7 backward-compat parse for a limits/ marker's TTL:
// (1) all-digits content is the legacy bare-TTL format (a marker written by the previous build);
// (2) otherwise pull the `ttl=<sec>` field out of a reason-line marker
// (`<ISO8601> | <reason-token> | retryable=<0|1> | ttl=<sec> | <text>`); (3) otherwise the
// caller's own baked default. Shared by every TTL-bearing limits/ reader so the rule can't drift
// between them — the cockpit is the one non-bash reader of this format (FR-7 calls it out by name:
// it fails quietly, showing every new-format lane a flat default countdown instead of erroring).
function parseMarkerTtl(text, dflt) {
  const trimmed = text.trim();
  if (/^\d+$/.test(trimmed)) return Number(trimmed);
  const m = trimmed.match(/\bttl=(\d+)\b/);
  return m ? Number(m[1]) : dflt;
}

// Small read helpers for the limits/ tree. readLimitFile returns the raw string (null if absent);
// readLimitInt parses to a truncated int (0 default). Used for .retries-<id>, .chain-<id>.
function readLimitFile(name) {
  try {
    const t = fs.readFileSync(path.join(BUSDIR, "limits", name), "utf8");
    return t && t.length ? t : null;
  } catch {
    return null;
  }
}
function readLimitInt(name) {
  const t = readLimitFile(name);
  if (t == null) return 0;
  const v = Number(t.trim());
  return Number.isFinite(v) ? Math.trunc(v) : 0;
}

// done/<id> is a one-line JSON provenance marker {"id","code","lane"}; tolerate garbage → {} so
// downstream done_lane/done_code fall back to null (never throw on a corrupt marker).
function readDoneMarker(name) {
  try {
    const obj = JSON.parse(fs.readFileSync(path.join(BUSDIR, "done", name), "utf8"));
    return obj && typeof obj === "object" ? obj : {};
  } catch {
    return {};
  }
}

// run.pgid present AND its process group is live (kill -0). EPERM = alive (running, not ours to
// signal); ESRCH or absent file = not running. Mirrors swarm-ctl abort's liveness guard.
function runActiveNow() {
  let pgid;
  try {
    pgid = Number(fs.readFileSync(path.join(BUSDIR, "run.pgid"), "utf8").trim());
  } catch {
    return false;
  }
  if (!Number.isFinite(pgid) || pgid <= 0) return false;
  try {
    process.kill(-pgid, 0);
    return true;
  } catch (e) {
    return e.code === "EPERM";
  }
}

// --- GET /api/agents (spec 07 §4.2) — the 2s grid snapshot -----------------------------------

function agentsSummary() {
  const now = Date.now();
  const leaseMin = readLeaseMin();
  const leaseMs = leaseMin * 60 * 1000;

  const conf = parseConfigText(readConfigText());
  const budget_usd = conf.BUDGET_USD != null ? String(conf.BUDGET_USD) : "0";
  const execChain = (conf.EXEC_CHAIN || "").split(/\s+/).filter(Boolean);

  const queueNames = listNames(path.join(BUSDIR, "queue")).filter((n) => n.endsWith(".prompt"));
  const claimedNames = listNames(path.join(BUSDIR, "claimed"));
  const doneNames = listNames(path.join(BUSDIR, "done"));
  const cancelledNames = listNames(path.join(BUSDIR, "cancelled")).filter((n) =>
    n.endsWith(".prompt")
  );
  const limitsNames = listNames(path.join(BUSDIR, "limits"));
  const parkedSet = new Set(
    limitsNames.filter((n) => n.endsWith(".parked")).map((n) => n.slice(0, -".parked".length))
  );
  const frozenSet = new Set(
    limitsNames.filter((n) => n.endsWith(".frozen")).map((n) => n.slice(0, -".frozen".length))
  );

  const doneN = doneNames.length;
  const liveN = queueNames.length + claimedNames.length + doneN;

  // limits envelope: lane-level *.limited flags with a live TTL countdown (content = TTL secs, or
  // spec 14 FR-7's reason line carrying a `ttl=<sec>` field — parseMarkerTtl above handles both;
  // expiry = mtime + TTL − now; §5.3b item 4). Expired ones still list (client may grey them).
  const limits = [];
  for (const n of limitsNames) {
    if (!n.endsWith(".limited")) continue;
    const lane = n.slice(0, -".limited".length);
    let st, ttl;
    try {
      st = fs.statSync(path.join(BUSDIR, "limits", n));
      ttl = parseMarkerTtl(fs.readFileSync(path.join(BUSDIR, "limits", n), "utf8"), 18000);
    } catch {
      continue;
    }
    const expires_in_sec = Math.max(0, Math.floor((st.mtimeMs + ttl * 1000 - now) / 1000));
    limits.push({ lane, expires_in_sec });
  }

  // Agent universe = union of ids across the bus dirs. A later dir in precedence wins the crumb,
  // but state precedence (done→cancelled→claimed→parked→queued) is resolved per-agent below.
  // Every id is ID_RE-checked before see()/buildAgent() so a path-ish name never drives fs reads
  // derived from the id. Claimed entries that fail CLAIM_RE are discarded (no split-on-dot
  // fallback — a bare or non-lane:model claim is not a valid agent crumb).
  const ids = new Map(); // id -> breadcrumbs {queue,claim,done,cancelled}
  const see = (id) => {
    if (!ids.has(id)) ids.set(id, {});
    return ids.get(id);
  };
  for (const n of queueNames) {
    const id = n.slice(0, -".prompt".length);
    if (!ID_RE.test(id)) continue;
    see(id).queue = n;
  }
  for (const n of claimedNames) {
    const m = n.match(CLAIM_RE);
    if (!m) continue;
    const id = m[1];
    if (!ID_RE.test(id)) continue;
    see(id).claim = n;
  }
  for (const n of doneNames) {
    if (!ID_RE.test(n)) continue;
    see(n).done = n;
  }
  for (const n of cancelledNames) {
    const id = n.slice(0, -".prompt".length);
    if (!ID_RE.test(id)) continue;
    see(id).cancelled = n;
  }
  for (const id of parkedSet) {
    if (!ID_RE.test(id)) continue;
    see(id).parked = true;
  }

  // spent_usd + run_started_ms iterate ALL run logs (not just universe agents) — the literal Σ
  // cost_usd / min first_ts, robust to an orphan run log whose agent already left the bus.
  let spent_usd = 0;
  let run_started_ms = null;
  for (const name of listNames(BUSDIR)) {
    if (!/^run-.*\.jsonl$/.test(name)) continue;
    const s = runSummary(name);
    if (!s) continue;
    spent_usd += s.cost_usd || 0;
    if (s.first_ts != null) {
      run_started_ms = run_started_ms == null ? s.first_ts : Math.min(run_started_ms, s.first_ts);
    }
  }

  const ctx = { now, leaseMs, leaseMin, execChain, frozenSet };
  const agents = [];
  for (const [id, crumb] of ids) agents.push(buildAgent(id, crumb, ctx));
  agents.sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));

  return {
    now,
    lease_min: leaseMin,
    paused: fs.existsSync(path.join(BUSDIR, "PAUSE")),
    run_active: runActiveNow(),
    budget_usd,
    spent_usd,
    gate: { done: doneN, parked: parkedSet.size, live: liveN },
    run_started_ms,
    limits,
    agents,
  };
}

function buildAgent(id, crumb, ctx) {
  const { now, leaseMs, frozenSet } = ctx;

  const claimName = crumb.claim || null;
  const claimMatch = claimName ? claimName.match(CLAIM_RE) : null;
  const claimLaneModel = claimMatch ? claimMatch[2] : null;
  const claimColon = claimLaneModel ? claimLaneModel.indexOf(":") : -1;
  const claimLane = claimColon >= 0 ? claimLaneModel.slice(0, claimColon) : null;
  const claimModel = claimColon >= 0 ? claimLaneModel.slice(claimColon + 1) : null;

  const doneMarker = crumb.done ? readDoneMarker(crumb.done) : null;

  // state precedence: done → cancelled → claimed → parked → queued. `frozen` is a SEPARATE
  // boolean field (a frozen worker is still claimed on the bus); the client maps frozen→"paused"
  // for display, so the server never emits "frozen" as a state value (§4.6b).
  let state;
  if (crumb.done) state = "done";
  else if (crumb.cancelled) state = "cancelled";
  else if (claimName) state = "claimed";
  else if (crumb.parked) state = "parked";
  else state = "queued";

  // lane/model/pinned provenance: claimed (CLAIM_RE) → done marker → .lane sidecar (pinned) →
  // .chain-<id> head → EXEC_CHAIN head.
  let lane = null;
  let model = null;
  let pinned = false;
  if (claimLaneModel) {
    lane = claimLane;
    model = claimModel;
    pinned = true;
  } else if (doneMarker && doneMarker.lane != null) {
    lane = String(doneMarker.lane);
  } else {
    const headLane = resolveLaneHead(id, ctx);
    if (headLane) {
      const ci = headLane.indexOf(":");
      lane = ci >= 0 ? headLane.slice(0, ci) : headLane;
      model = ci >= 0 ? headLane.slice(ci + 1) : null;
      pinned = true;
    }
  }

  // run-log summary (cached). tokens/dollars/cost_usd/errors + the last-event one-liner.
  const run = runSummary(`run-${id}.jsonl`);
  const tokens = run ? run.tokens : 0;
  const dollars = run ? run.dollars : 0;
  const cost_usd = run ? run.cost_usd : 0;
  const errors = run ? run.errors : 0;
  const last_type = run ? run.last_type : null;
  const last_excerpt = run ? run.last_excerpt : "";
  const last_activity = last_type ? `${last_type} · ${last_excerpt}`.trim() : "";

  // lease / heartbeat / ages. heartbeat_age + lease_remaining come from the claim file's mtime
  // (the 30s touch refreshes it). claim_age uses runSummary.first_ts (NOT claim mtime — the
  // heartbeat refresh would otherwise reset the true claim age to ~0).
  let stale = false;
  let heartbeat_age_sec = null;
  let lease_remaining_sec = null;
  let claim_age_sec = null;
  let last_event_age_sec = null;
  let claimMtime = null;
  if (claimName) {
    try {
      claimMtime = fs.statSync(path.join(BUSDIR, "claimed", claimName)).mtimeMs;
    } catch {
      claimMtime = null;
    }
    if (claimMtime != null) {
      heartbeat_age_sec = Math.max(0, Math.floor((now - claimMtime) / 1000));
      lease_remaining_sec = Math.max(0, Math.floor((claimMtime + leaseMs - now) / 1000));
      stale = claimMtime < now - leaseMs;
    }
    const claimBase =
      run && run.first_ts != null ? run.first_ts : claimMtime != null ? claimMtime : null;
    if (claimBase != null) claim_age_sec = Math.max(0, Math.floor((now - claimBase) / 1000));
  }
  try {
    const runMtime = fs.statSync(path.join(BUSDIR, `run-${id}.jsonl`)).mtimeMs;
    last_event_age_sec = Math.max(0, Math.floor((now - runMtime) / 1000));
  } catch {
    last_event_age_sec = null;
  }

  const chainText = readLimitFile(`.chain-${id}`);
  const chain_left = chainText != null ? chainText.split(/\s+/).filter(Boolean).length : null;

  let done_ms = null;
  if (crumb.done) {
    try {
      done_ms = fs.statSync(path.join(BUSDIR, "done", crumb.done)).mtimeMs;
    } catch {
      done_ms = null;
    }
  }

  return {
    id,
    state,
    verify: id.startsWith("v-"),
    stale,
    lane,
    model,
    pinned,
    frozen: frozenSet.has(id),
    heartbeat_age_sec,
    lease_remaining_sec,
    claim_age_sec,
    last_event_age_sec,
    last_activity,
    tokens,
    dollars,
    cost_usd,
    errors,
    retries: readLimitInt(`.retries-${id}`),
    timedout: fs.existsSync(path.join(BUSDIR, "limits", `${id}.timedout`)),
    chain_left,
    done_lane: doneMarker && doneMarker.lane != null ? doneMarker.lane : null,
    done_code: doneMarker && doneMarker.code != null ? doneMarker.code : null,
    done_ms,
  };
}

// queued/parked lane provenance fallback chain: queue/<id>.lane sidecar → .chain-<id> head →
// EXEC_CHAIN head. Returns the first "lane:model" (or bare lane) found, else null.
function resolveLaneHead(id, ctx) {
  let sidecar;
  try {
    sidecar = fs.readFileSync(path.join(BUSDIR, "queue", `${id}.lane`), "utf8").trim();
  } catch {
    sidecar = "";
  }
  if (sidecar) return sidecar;
  const chainText = readLimitFile(`.chain-${id}`);
  if (chainText) {
    const head = chainText.split(/\s+/).filter(Boolean)[0];
    if (head) return head;
  }
  return ctx.execChain.length ? ctx.execChain[0] : null;
}

// --- GET /api/loop (spec 07 §4.3) — newest loop run state -----------------------------------

function loopSummary() {
  const loopRoot = path.join(BUSDIR, "loop");
  let newest = null;
  let newestMtime = -1;
  for (const d of listNames(loopRoot)) {
    try {
      const m = fs.statSync(path.join(loopRoot, d, "state.jsonl")).mtimeMs;
      if (m > newestMtime) {
        newestMtime = m;
        newest = d;
      }
    } catch {
      /* no state.jsonl — not a run dir */
    }
  }
  if (newest == null) return { run: null };

  const dir = path.join(loopRoot, newest);
  const criteriaPath = path.join(dir, "criteria.md");
  const statePath = path.join(dir, "state.jsonl");

  let criteriaText = "";
  try {
    criteriaText = fs.readFileSync(criteriaPath, "utf8");
  } catch {
    criteriaText = "";
  }
  // max_iterations / budget_usd live under the two-space-indented `stops:` block (per
  // swarm-loop.sh _criteria_stop); capture the first \S+ after `  key:`.
  const max_iterations = matchStop(criteriaText, "max_iterations");
  const budget_usd = matchStop(criteriaText, "budget_usd");

  // iter = non-empty line count; cost_total = Σ .cost; last = last parseable state line.
  let iter = 0;
  let cost_total = 0;
  let last = null;
  let stateText = "";
  try {
    stateText = fs.readFileSync(statePath, "utf8");
  } catch {
    stateText = "";
  }
  for (const raw of stateText.split("\n")) {
    if (!raw.trim()) continue;
    iter += 1;
    let obj;
    try {
      obj = JSON.parse(raw);
    } catch {
      continue;
    }
    last = obj;
    if (obj && typeof obj.cost === "number") cost_total += obj.cost;
  }

  let halted = false;
  let halted_reason = null;
  try {
    const h = fs.readFileSync(path.join(dir, "HALTED.md"), "utf8");
    halted = true;
    const firstLine = h.split("\n", 1)[0];
    halted_reason = firstLine.length > 200 ? firstLine.slice(0, 200) : firstLine;
  } catch {
    halted = false;
  }
  let complete = false;
  try {
    fs.statSync(path.join(dir, "COMPLETE.md"));
    complete = true;
  } catch {
    complete = false;
  }

  let started_ms = null;
  try {
    started_ms = fs.statSync(criteriaPath).mtimeMs; // criteria.md is written once at init
  } catch {
    started_ms = null;
  }
  let steering_bytes = 0;
  try {
    steering_bytes = fs.statSync(path.join(dir, "steering.md")).size;
  } catch {
    steering_bytes = 0;
  }

  return {
    run: newest,
    iter,
    max_iterations,
    budget_usd,
    cost_total,
    last,
    halted,
    halted_reason,
    complete,
    started_ms,
    steering_bytes,
  };
}

// matchStop — read a two-space-indented `key: value` child of the criteria.md `stops:` block
// only. Isolates the block first (from a line that is exactly `stops:` to the next non-indented
// non-empty line) so a stray `  max_iterations:` elsewhere in the file cannot win. Mirrors
// swarm-loop.sh `_criteria_stop` intent (children of stops:) with an explicit block bound.
function matchStop(text, key) {
  const lines = text.split("\n");
  let i = 0;
  for (; i < lines.length; i++) {
    if (lines[i] === "stops:") break;
  }
  if (i >= lines.length) return null;
  const children = [];
  for (i = i + 1; i < lines.length; i++) {
    const line = lines[i];
    // non-empty and not indented → end of the stops: block
    if (line.length > 0 && !/^[ \t]/.test(line)) break;
    children.push(line);
  }
  const block = children.join("\n");
  const m = block.match(new RegExp(`^ {2}${key}:\\s*(\\S+)`, "m"));
  return m ? m[1] : null;
}

// --- GET /api/agent?id= (spec 07 §4.4) — drawer bodies --------------------------------------

function claimedFilesFor(id) {
  const dir = path.join(BUSDIR, "claimed");
  const out = [];
  for (const n of listNames(dir)) {
    const m = n.match(CLAIM_RE);
    if (m && m[1] === id) out.push(path.join(dir, n));
  }
  return out;
}

// spec @32KiB head: first present of queue/<id>.prompt → claimed/<id>.* → prompt-<id>.txt →
// specs/<id>.prompt → cancelled/<id>.prompt. res @64KiB head: res-<id>.txt. stderr: last 8KiB of
// run-<id>.jsonl.stderr. All three null → null (caller 404s). id is ID_RE-validated upstream.
function agentDetail(id) {
  const specCandidates = [
    ["queue", path.join(BUSDIR, "queue", `${id}.prompt`)],
    ...claimedFilesFor(id).map((f) => ["claimed", f]),
    ["prompt", path.join(BUSDIR, `prompt-${id}.txt`)],
    ["specs", path.join(BUSDIR, "specs", `${id}.prompt`)],
    ["cancelled", path.join(BUSDIR, "cancelled", `${id}.prompt`)],
  ];
  let spec = null;
  for (const [source, f] of specCandidates) {
    const r = readCapped(f, 32 * 1024);
    if (r) {
      spec = { text: r.text, size: r.size, truncated: r.truncated, source };
      break;
    }
  }
  const resR = readCapped(path.join(BUSDIR, `res-${id}.txt`), 64 * 1024);
  const res = resR ? { text: resR.text, size: resR.size, truncated: resR.truncated } : null;
  const errR = readCapped(path.join(BUSDIR, `run-${id}.jsonl.stderr`), 8 * 1024, { tail: true });
  const stderr = errR
    ? { text: errR.text, size: errR.size, truncated: errR.truncated }
    : null;
  if (!spec && !res && !stderr) return null;
  return { id, spec, res, stderr };
}

// --- POST /api/ctl (spec 07 §4.5) — control verbs delegated to src/swarm-ctl ----------------

// Frozen verb table. Object.hasOwn (not `in`) defeats prototype-pollution: {"verb":"__proto__"}
// can never resolve to Object.prototype via this lookup.
const CTL_VERBS = Object.freeze({
  pause: true,
  resume: true,
  cancel: true,
  kill: true,
  nudge: true,
  "pause-worker": true,
  "resume-worker": true,
  add: true,
  abort: true,
});

// execFile swarm-ctl with a LITERAL argv array — never a shell. The ID_RE first-char-alnum rule
// means an id can never parse as a `-`-option, so argv injection is structurally impossible.
// timeout=15s bounds a wedged ctl; maxBuffer caps runaway stdout/stderr. `successBody(out, errout)`
// builds the 200 body (runCtl/runAdd each shape it differently); `finish` receives the final
// {status, body} — runCtl's is `resolve` directly, runAdd's also cleans up its mkdtemp staging
// dir. Real nonzero exit → 409 (ctl/bus refused); spawn error or timeout/signal → 500 (infra
// problem, not a refusal). Synchronous to the client — no 202.
function execCtl(argv, successBody, finish) {
  execFile(
    path.join(REPO_ROOT, "src", "swarm-ctl"),
    argv,
    { cwd: REPO_ROOT, env: { ...process.env, BUSDIR }, timeout: 15000, maxBuffer: 256 * 1024 },
    (err, stdout, stderr) => {
      const out = stdout == null ? "" : String(stdout);
      const errout = stderr == null ? "" : String(stderr);
      if (!err) {
        finish({ status: 200, body: successBody(out, errout) });
        return;
      }
      if (typeof err.code === "number") {
        // a real nonzero exit code — the verb ran but the bus/ctl refused it
        finish({
          status: 409,
          body: { ok: false, error: "swarm-ctl failed", code: err.code, stderr: errout },
        });
        return;
      }
      // spawn failure (ENOENT) or timeout/signal — a server-side problem
      console.error(err);
      finish({ status: 500, body: { error: "internal error" } });
    }
  );
}

function runCtl(verb, argv, id) {
  return new Promise((resolve) => {
    execCtl(
      argv,
      (out, errout) => ({
        ok: true,
        verb,
        ...(id != null ? { id } : {}),
        stdout: out,
        stderr: errout,
      }),
      resolve
    );
  });
}

// ADD-SPEC flow: the server NEVER writes under BUSDIR — swarm-ctl stays the sole bus writer. The
// prompt is staged in a private mkdtemp under os.tmpdir(), then `swarm-ctl add <tmpfile>
// [--lane ..] [--write ..]` copies it onto the bus. The staging dir is removed unconditionally
// (success or failure) so no temp ever lingers.
function runAdd({ id, prompt, lane, write }) {
  return new Promise((resolve) => {
    let dir;
    try {
      dir = fs.mkdtempSync(path.join(tmpdir(), "swarm-add-"));
    } catch (e) {
      console.error(e);
      resolve({ status: 500, body: { error: "internal error" } });
      return;
    }
    const tmpfile = path.join(dir, `${id}.prompt`);
    const argv = ["add", tmpfile];
    if (lane) argv.push("--lane", lane);
    if (write) argv.push("--write", write);
    const finish = (result) => {
      try {
        fs.rmSync(dir, { recursive: true, force: true });
      } catch {
        /* best-effort cleanup */
      }
      resolve(result);
    };
    try {
      fs.writeFileSync(tmpfile, prompt, "utf8");
    } catch (e) {
      console.error(e);
      finish({ status: 500, body: { error: "internal error" } });
      return;
    }
    execCtl(argv, (out, errout) => ({ ok: true, verb: "add", id, stdout: out, stderr: errout }), finish);
  });
}

// True if <id> has ANY footprint on the bus — checked BEFORE swarm-ctl runs so an `add` of an
// existing id is refused (409) without overwriting anything. id is ID_RE-validated upstream.
function hasBusFootprint(id) {
  const checks = [
    path.join(BUSDIR, "queue", `${id}.prompt`),
    path.join(BUSDIR, "queue", `${id}.lane`),
    path.join(BUSDIR, "queue", `${id}.write`),
    path.join(BUSDIR, "queue", `${id}.files`),
    path.join(BUSDIR, "specs", `${id}.prompt`),
    path.join(BUSDIR, "specs", `${id}.lane`),
    path.join(BUSDIR, "specs", `${id}.write`),
    path.join(BUSDIR, "done", id),
    path.join(BUSDIR, "cancelled", `${id}.prompt`),
    path.join(BUSDIR, `prompt-${id}.txt`),
    path.join(BUSDIR, `res-${id}.txt`),
    path.join(BUSDIR, `run-${id}.jsonl`),
    path.join(BUSDIR, "limits", `${id}.parked`),
    path.join(BUSDIR, "limits", `${id}.frozen`),
    path.join(BUSDIR, "limits", `.chain-${id}`),
    path.join(BUSDIR, "limits", `.retries-${id}`),
    path.join(BUSDIR, "limits", `${id}.timedout`),
    path.join(BUSDIR, "pids", id),
  ];
  for (const f of checks) if (fs.existsSync(f)) return true;
  for (const n of listNames(path.join(BUSDIR, "claimed"))) {
    const m = n.match(CLAIM_RE);
    if (m && m[1] === id) return true;
  }
  return false;
}

// Validates the parsed body and returns either an immediate {status, body} (validation failure)
// or a directive: {exec:true, verb, argv, id} / {add:true, verb, id, prompt, lane, write}. The
// route turns the directive into the runCtl/runAdd call. All id validation happens here, BEFORE
// any spawn — a malformed id never reaches swarm-ctl.
function handleCtlBody(body) {
  const verb = body && body.verb;
  if (typeof verb !== "string" || !Object.hasOwn(CTL_VERBS, verb)) {
    return { status: 400, body: { error: "unknown verb" } };
  }
  const id = body.id;
  const idOk = (v) => typeof v === "string" && ID_RE.test(v);

  if (verb === "pause" || verb === "resume") {
    return { exec: true, verb, argv: [verb], id: null };
  }

  if (verb === "abort") {
    if (body.confirm !== true) {
      return { status: 400, body: { error: "abort requires confirm" } };
    }
    return { exec: true, verb, argv: ["abort"], id: null };
  }

  if (verb === "cancel" || verb === "pause-worker" || verb === "resume-worker") {
    if (!idOk(id)) return { status: 400, body: { error: "invalid id" } };
    return { exec: true, verb, argv: [verb, id], id };
  }

  if (verb === "kill") {
    if (!idOk(id)) return { status: 400, body: { error: "invalid id" } };
    // cancel is optional; when present it must be a boolean (string "yes"/1 silently became
    // false before — refuse non-boolean so the client cannot think --cancel was applied).
    if (body.cancel !== undefined && typeof body.cancel !== "boolean") {
      return { status: 400, body: { error: "cancel must be boolean" } };
    }
    const argv = ["kill", id];
    if (body.cancel === true) argv.push("--cancel");
    return { exec: true, verb, argv, id };
  }

  if (verb === "nudge") {
    if (!idOk(id)) return { status: 400, body: { error: "invalid id" } };
    const argv = ["nudge", id];
    const hint = body.hint;
    if (hint != null) {
      if (typeof hint !== "string" || hint.includes("\0") || hint.length > 16 * 1024) {
        return { status: 400, body: { error: "invalid hint" } };
      }
      argv.push(hint);
    }
    return { exec: true, verb, argv, id };
  }

  // add
  if (!idOk(id)) return { status: 400, body: { error: "invalid id" } };
  const prompt = body.prompt;
  if (typeof prompt !== "string" || prompt.length === 0) {
    return { status: 400, body: { error: "prompt required" } };
  }
  if (prompt.length > 60000) {
    return { status: 400, body: { error: "prompt too large" } };
  }
  let lane = body.lane;
  if (lane != null && (typeof lane !== "string" || !LANE_PIN_RE.test(lane))) {
    return { status: 400, body: { error: "invalid lane" } };
  }
  const write = body.write;
  if (write != null) {
    if (typeof write !== "string") {
      return { status: 400, body: { error: "invalid write dir" } };
    }
    try {
      if (!fs.statSync(write).isDirectory()) {
        return { status: 400, body: { error: "write must be a directory" } };
      }
    } catch {
      return { status: 400, body: { error: "write dir does not exist" } };
    }
  }
  // 409 if the id already has ANY bus footprint — refuse before swarm-ctl ever runs, so an
  // existing prompt can never be overwritten by a fresh `add`.
  if (hasBusFootprint(id)) {
    return { status: 409, body: { ok: false, error: "id already exists on the bus" } };
  }
  return { add: true, verb, id, prompt, lane: lane != null ? lane : null, write: write != null ? write : null };
}

// --- static file serving, path-traversal safe ---------------------------------------------------

const CONTENT_TYPES = {
  ".html": "text/html; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".png": "image/png",
  ".txt": "text/plain; charset=utf-8",
  ".woff2": "font/woff2",
};

function serveStatic(req, res) {
  const urlPath = decodeURIComponent(new URL(req.url, "http://localhost").pathname);
  const rel = urlPath === "/" ? "index.html" : urlPath.replace(/^\/+/, "");
  const resolved = path.resolve(SITE_ROOT, rel);

  if (resolved !== SITE_ROOT && !resolved.startsWith(SITE_ROOT + path.sep)) {
    res.writeHead(403, { "Content-Type": "text/plain", ...staticSecurityHeaders() });
    res.end("forbidden");
    return;
  }
  // lexical check above can't see symlinks — re-check the realpath so a symlink under site/
  // pointing outside (bad merge, tooling mishap) can never become an arbitrary-file read.
  let real;
  try {
    real = fs.realpathSync(resolved);
  } catch {
    res.writeHead(404, { "Content-Type": "text/plain", ...staticSecurityHeaders() });
    res.end("not found");
    return;
  }
  const realRoot = fs.realpathSync(SITE_ROOT);
  if (real !== realRoot && !real.startsWith(realRoot + path.sep)) {
    res.writeHead(403, { "Content-Type": "text/plain", ...staticSecurityHeaders() });
    res.end("forbidden");
    return;
  }
  // never serve server.mjs itself over the wire, even locally
  if (path.basename(resolved) === "server.mjs") {
    res.writeHead(404, { "Content-Type": "text/plain", ...staticSecurityHeaders() });
    res.end("not found");
    return;
  }

  fs.readFile(resolved, (err, data) => {
    if (err) {
      res.writeHead(404, { "Content-Type": "text/plain", ...staticSecurityHeaders() });
      res.end("not found");
      return;
    }
    const type = CONTENT_TYPES[path.extname(resolved).toLowerCase()] || "application/octet-stream";
    res.writeHead(200, { "Content-Type": type, ...staticSecurityHeaders() });
    res.end(data);
  });
}

// --- security headers: applied on every response path -----------------------------------------
// No HSTS: this is a plain-HTTP loopback server (never TLS), so Strict-Transport-Security would
// be meaningless here.
function baseSecurityHeaders() {
  return {
    "X-Content-Type-Options": "nosniff",
    "X-Frame-Options": "DENY",
    "Referrer-Policy": "no-referrer",
    "Permissions-Policy": "camera=(), microphone=(), geolocation=()",
  };
}

// index.html/guide.html/cockpit-legacy.html carry pre-existing inline <script>/<style> blocks
// (copy-button UX) that are outside this task's scope to edit — 'unsafe-inline' on
// script-src/style-src keeps them working under this CSP; cockpit.html itself has no inline
// script/style and is unaffected by the relaxation.
const STATIC_CSP =
  "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; " +
  "script-src 'self' 'unsafe-inline'; connect-src 'self'";

function staticSecurityHeaders() {
  return { ...baseSecurityHeaders(), "Content-Security-Policy": STATIC_CSP };
}

// Audit trail for the two mutation routes: one line per outcome, names only (key/verb) — never
// value/hint/prompt/body content. Returns `result` unchanged so callers can wrap a return in it.
function auditLog(route, req, fields, result) {
  const line = JSON.stringify({
    audit: true,
    ts: new Date().toISOString(),
    route,
    ...fields,
    origin: req.headers.origin || null,
    status: result && result.status,
  });
  console.log(line);
  // Durable copy: the server's one owned append-only file under BUSDIR (spec 12 FR-6). Best-effort
  // — an audit-write failure (e.g. BUSDIR missing) must never fail the ctl request it's logging.
  try {
    fs.appendFileSync(path.join(BUSDIR, "audit.jsonl"), line + "\n");
  } catch {
    // swallow — audit is a durability nice-to-have, not a request dependency
  }
  return result;
}

// --- routing --------------------------------------------------------------------------------

function jsonResponse(res, status, body) {
  res.writeHead(status, { "Content-Type": "application/json", ...baseSecurityHeaders() });
  res.end(JSON.stringify(body));
}

// DNS-rebinding guard: the server binds 127.0.0.1, but a page the operator visits could rebind its
// own hostname to 127.0.0.1 and read /api/* (swarm run content) cross-origin — the browser would
// send the attacker's Host. Accept only loopback Host values (the hostname the operator's own
// browser uses for the cockpit); anything else is refused before any handler runs.
function hostAllowed(req) {
  const host = (req.headers.host || "").toLowerCase();
  if (!host) return true; // HTTP/1.0 / no Host — not a rebinding vector
  const name = host.replace(/:\d+$/, ""); // strip :port
  return name === "localhost" || name === "127.0.0.1" || name === "[::1]" || name === "::1";
}

// CSRF guard for the one write route: a page on any origin can fire a CORS-safelisted
// (no-preflight) POST at 127.0.0.1:4747 — the browser sets Host to the target so hostAllowed
// alone doesn't catch it, but it still sends the ATTACKER'S Origin. Require a loopback Origin
// when one is present; absent Origin (curl, same-origin requests on older browsers) stays
// allowed since it isn't a cross-site request.
function originAllowed(req) {
  const origin = req.headers.origin;
  if (!origin) return true;
  return origin === `http://localhost:${PORT}` || origin === `http://127.0.0.1:${PORT}`;
}

const server = http.createServer((req, res) => {
  try {
    if (!hostAllowed(req)) {
      jsonResponse(res, 403, { error: "forbidden host" });
      return;
    }
    const { pathname } = new URL(req.url, "http://localhost");

    if (pathname === "/health") {
      // P0-FR4: {root, branch, head, busdir} — byte-identical field set to swarm-run.sh's
      // run-start banner (_print_banner), so the terminal and the cockpit never disagree.
      jsonResponse(res, 200, { ok: true, busdir: BUSDIR, ...gitState() });
      return;
    }
    if (pathname === "/api/bus") {
      jsonResponse(res, 200, busSnapshot());
      return;
    }
    if (pathname === "/api/cost") {
      jsonResponse(res, 200, { lanes: costSummary() });
      return;
    }
    if (pathname === "/api/models") {
      jsonResponse(res, 200, { models: modelsSummary(), window_min: 5, notional: true });
      return;
    }
    if (pathname === "/api/speedwars") {
      jsonResponse(res, 200, speedwarsSnapshot());
      return;
    }
    if (pathname === "/api/stream") {
      startStream(res);
      return;
    }
    if (pathname === "/api/config") {
      if (req.method === "GET") {
        jsonResponse(res, 200, configSnapshot());
        return;
      }
      if (req.method === "POST") {
        guardedPost(req, res, 8 * 1024, (body) => {
          const key = body && body.key;
          const value = body && body.value;
          const audit = (result) =>
            auditLog("/api/config", req, { key: typeof key === "string" ? key : null }, result);
          if (typeof key !== "string" || !Object.hasOwn(CONFIG_VALIDATORS, key)) {
            return audit({ status: 400, body: { error: "invalid key or value" } });
          }
          const validator = CONFIG_VALIDATORS[key];
          if (typeof value !== "string" || !validator.test(value)) {
            return audit({ status: 400, body: { error: "invalid key or value" } });
          }
          try {
            writeConfigValue(key, value);
          } catch (e) {
            audit({ status: 500 });
            throw e; // guardedPost turns it into a 500
          }
          return audit({ status: 200, body: configSnapshot() });
        });
        return;
      }
      jsonResponse(res, 405, { error: "method not allowed" });
      return;
    }
    if (pathname === "/api/agents") {
      jsonResponse(res, 200, agentsSummary());
      return;
    }
    if (pathname === "/api/loop") {
      jsonResponse(res, 200, loopSummary());
      return;
    }
    if (pathname === "/api/agent") {
      const id = new URL(req.url, "http://localhost").searchParams.get("id");
      // ID_RE BEFORE any fs access — a traversal id (`../x`, `.hidden`) is rejected without ever
      // touching the bus, so no file content can leak through a path-joined id.
      if (typeof id !== "string" || !ID_RE.test(id)) {
        jsonResponse(res, 400, { error: "invalid id" });
        return;
      }
      const detail = agentDetail(id);
      if (!detail) {
        jsonResponse(res, 404, { error: "no such agent" });
        return;
      }
      jsonResponse(res, 200, detail);
      return;
    }
    if (pathname === "/api/ctl") {
      if (req.method !== "POST") {
        jsonResponse(res, 405, { error: "method not allowed" });
        return;
      }
      // /api/ctl delegates bus mutations to src/swarm-ctl via a fixed execFile argv table — the
      // server process itself never writes under BUSDIR (swarm-ctl is the sole bus writer). No
      // locking for concurrent calls: the verbs are mv/rm-based and race-tolerant by construction.
      guardedPost(req, res, 64 * 1024, (body) => {
        const p = handleCtlBody(body);
        const verb = typeof (body && body.verb) === "string" ? body.verb : null;
        const audit = (result) => auditLog("/api/ctl", req, { verb }, result);
        if (p.status) return audit(p); // immediate validation response
        if (p.exec) return runCtl(p.verb, p.argv, p.id).then(audit);
        if (p.add) return runAdd(p).then(audit);
        return audit({ status: 400, body: { error: "unknown verb" } });
      });
      return;
    }
    if (pathname.startsWith("/api/")) {
      jsonResponse(res, 404, { error: "not found" });
      return;
    }
    serveStatic(req, res);
  } catch (err) {
    console.error(err);
    try {
      jsonResponse(res, 500, { error: "internal error" });
    } catch {
      // response already sent — nothing more we can do
    }
  }
});

server.listen(PORT, "127.0.0.1", () => {
  // eslint-disable-next-line no-console
  console.log(`unimatrix server.mjs listening on http://127.0.0.1:${PORT} (busdir=${BUSDIR})`);
});
