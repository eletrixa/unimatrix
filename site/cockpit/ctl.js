/**
 * Control surface: POST /api/ctl wrapper + toast singleton + ABORT two-step confirm.
 *
 * Project: unimatrix — multi-model swarm orchestrator driven from Claude Code
 * Module:  site/cockpit/ctl.js
 * Deps:    browser fetch + DOM (renders into the shell's #toast element); format.js (esc)
 * Tested:  tests/ground-control.bats (server-side /api/ctl); tests/cockpit.bats (logic mirror)
 *
 * Key responsibilities:
 * - ctl(verb, payload): the ONE write path every view calls. POSTs {verb, ...payload} JSON to
 *   /api/ctl, shows a pending toast, then a green ok toast (2.6s) or a red fail toast (6s).
 * - toast(msg, kind): singleton renderer into #toast — later toasts replace the in-flight one.
 * - armAbort(btn): two-step confirm (button → solid-red CONFIRM ABORT, 5s window → ctl abort).
 *
 * Design constraints:
 * - Only ctl() ever POSTs /api/ctl; views never fetch directly. The server validates verbs/ids
 *   (FR-7), so the client sends the literal body and interprets {ok, stderr, error}.
 * - No fake data in toasts: ok text is the real verb+id; fail text is the real server stderr or
 *   the network error string — never invented.
 * - armAbort matches FR-2's two-step (never fires abort on the first click).
 */

import { esc } from './format.js';

// --- toast singleton (renders into the shell #toast element) ---------------------------------
//
// One element, one timer. A toast while another is showing replaces it (the ctl flow relies on
// this: pending → ok/fail). kind ∈ {ok, fail, pending}; absent = neutral. CSS classes toast-ok /
// toast-fail / toast-pending are owned by base.css.

let toastTimer = null;

export function toast(msg, kind) {
  const el = document.getElementById('toast');
  if (!el) return; // shell not ready yet — silent (no crash on early calls)
  el.className = 'toast' + (kind ? ' toast-' + kind : '');
  el.innerHTML = `<span class="toast-glyph">$</span> ${esc(msg)}`;
  el.hidden = false;
  if (toastTimer) clearTimeout(toastTimer);
  // ok/pending are short-lived (2.6s); failures stay up 6s so the operator can read the stderr.
  const ms = kind === 'fail' ? 6000 : 2600;
  toastTimer = setTimeout(() => {
    el.hidden = true;
    toastTimer = null;
  }, ms);
}

// --- ctl(verb, payload) -> Promise ----------------------------------------------------------
//
// POSTs {verb, ...payload} to /api/ctl. Server responses (FR-7): 200 {ok,verb,id?,stdout,stderr}
// on exit 0; 409 {ok:false,error,code,stderr} on a nonzero swarm-ctl exit (bus refused); 400/403/
// 405/500 otherwise. We treat anything that isn't ok:true as a failure and surface stderr (or the
// network error) in a red toast. Returns the parsed body so callers (e.g. settings refresh) can
// react; never rejects — a network blow-up becomes a fail toast + null resolve.

export function ctl(verb, payload = {}) {
  const id = payload.id != null ? String(payload.id) : '';
  const label = `swarm-ctl ${verb}${id ? ' ' + id : ''}`;
  toast(`${label} · …`, 'pending');

  return fetch('/api/ctl', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ verb, ...payload }),
  })
    .then(async (r) => {
      let body = null;
      try { body = await r.json(); } catch { /* non-JSON (500 text) — body stays null */ }
      if (r.ok && body && body.ok) {
        toast(`${label} · ok`, 'ok');
        return body;
      }
      // 409 carries the real swarm-ctl stderr ("id not found", "refused", …); fall back through
      // the server's error string, then the HTTP status, then a generic network label.
      const why = (body && body.stderr && body.stderr.trim()) ||
        (body && body.error) ||
        `http ${r.status}`;
      toast(`✕ ${verb} failed: ${why}`, 'fail');
      return body;
    })
    .catch((e) => {
      // fetch rejects only on a network failure / aborted request — surface the raw message.
      toast(`✕ ${verb} failed: ${e && e.message ? e.message : 'network'}`, 'fail');
      return null;
    });
}

// --- armAbort(btn): two-step confirm (FR-2) --------------------------------------------------
//
// First click arms a 5s window: the button flips to a solid-red CONFIRM ABORT label. A second
// click inside that window fires ctl abort{confirm:true}; outside it (or a fresh mount) the next
// click just re-arms. Re-arming while armed resets the window. Never fires abort on the first click.

export function armAbort(btn) {
  if (!btn) return;
  let armed = false;
  let timer = null;

  const reset = () => {
    armed = false;
    if (timer) { clearTimeout(timer); timer = null; }
    btn.classList.remove('armed');
    btn.textContent = 'ABORT';
  };

  btn.addEventListener('click', () => {
    if (!armed) {
      armed = true;
      btn.classList.add('armed');
      btn.textContent = 'CONFIRM ABORT';
      timer = setTimeout(reset, 5000);
      return;
    }
    // confirmed within the window — fire and disarm.
    reset();
    ctl('abort', { confirm: true });
  });
}
