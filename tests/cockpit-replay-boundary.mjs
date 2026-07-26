/**
 * Client-level replay->live boundary check for site/cockpit/data.js (round-4 MAJ).
 *
 * Project: unimatrix — multi-model swarm orchestrator driven from Claude Code
 * Module:  tests/cockpit-replay-boundary.mjs
 * Deps:    node >= 20 (ESM); stubs EventSource/fetch/localStorage — no browser, no server
 * Tested:  self (run it: `node tests/cockpit-replay-boundary.mjs`, wired from tests/cockpit.bats)
 *
 * Guards the one ordering bug a server-side test cannot see: a coalesced streak opened during the
 * BACKFILL must be finalized at the 'replay-done' sentinel, or the first live event on the same key
 * takes the coalesce fast path (mutate-in-place + early return) and never stamps lastEvtClient /
 * dots / evtPerBucket — the agent renders permanently stale while it is in fact talking.
 */

import assert from 'node:assert/strict';

// --- minimal browser surface (data.js touches these three at import/boot) ---------------------

const handlers = new Map();
let esInstance = null;
globalThis.EventSource = class {
  constructor() {
    this.onopen = null; this.onmessage = null; this.onerror = null;
    esInstance = this;
  }
  addEventListener(type, fn) { handlers.set(type, fn); }
  close() {}
};
globalThis.fetch = () => Promise.reject(new Error('offline in this harness'));
globalThis.localStorage = { getItem: () => null, setItem: () => {} };

const { store, start } = await import('../site/cockpit/data.js');

// --- drive one connection: replay a streak, sentinel, then the SAME key live ------------------

start();
esInstance.onopen();

// 'thought' is a coalescing delta type (format.js NEVER_COALESCE_TYPES excludes it), so every one
// of these lands on the SAME streak key — which is exactly the situation the bug needs.
const evt = (text) => ({
  data: JSON.stringify({ worker: 'c1', line: { type: 'thought', data: text } }),
});
esInstance.onmessage(evt('replayed-1'));
esInstance.onmessage(evt('replayed-2'));

const rec = store.agents.get('c1');
assert.ok(rec, 'replay must create the agent record');
assert.equal(rec.lastEvtClient, null, 'replay arrivals must not stamp live signals');

handlers.get('replay-done')();
esInstance.onmessage(evt('live-1'));

assert.notEqual(
  rec.lastEvtClient, null,
  'the first LIVE event after replay-done must stamp lastEvtClient — an unfinalized backfill '
  + 'coalesce swallowed it via the fast path',
);

console.log('ok — replay->live boundary finalizes backfill coalesces');
process.exit(0);
