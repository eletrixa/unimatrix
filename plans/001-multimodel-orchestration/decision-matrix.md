# Decision Matrix — Multi-Model Orchestrator Finalists

Per-criterion scores are the mean of 3 judges (pragmatist, reliability-architect, capability-maximalist), 0–10. **Mean WT** is the mean of the three judges' weighted totals. Ranked by Mean WT.

| # | ID | Architecture | Fit | Simpl | Robust | Monitor | Flex | TtV | Maint | **Mean WT** | Survives | Verdict |
|---|----|--------------|-----|-------|--------|---------|------|-----|-------|-------------|----------|---------|
| 1 | a1 | Headless spawn + JSONL bus + tmux/WezTerm tail cockpit | 9.2 | 8.5 | 7.2 | 7.8 | 7.7 | 8.7 | 8.2 | **8.18** | ✅ | Run-tonight default: ~150 lines reusing everything installed+authed; ship it, but make crash-reclaim/completeness and outer containment non-optional. |
| 2 | a8 | Split-Plane hybrid (unify stateless verify, keep agentic native) | 8.2 | 7.2 | 6.5 | 7.2 | 8.5 | 7.5 | 6.8 | **7.41** | ✅ | Right instinct, inverted premise: cost mass is in native search, not stateless verify — drop LiteLLM for v1 and it's a1 with a curl map. |
| 3 | a9 | Zero-DB SSE local webdash (Glass, +:1337 Bridge fallback) | 7.3 | 7.3 | 6.5 | 8.5 | 7.3 | 7.8 | 7.0 | **7.36** | ✅ | Best cockpit by far over a sound JSONL bus, but a gorgeous monitor on an under-built engine — promote the Ledger + wire the skill. |
| 4 | a2 | Agent SDK orchestrator wrapping deep-research | 8.3 | 6.3 | 6.8 | 8.0 | 8.2 | 6.7 | 6.2 | **7.35** | ✅ | Real Opus in the seat with a typed audit stream, but poll-loop bloats context and the constraint-6 skill auto-load is unverified. |
| 5 | a5 | SQLite poll-and-lease work-queue + SQL board cockpit | 8.2 | 5.0 | 8.0 | 8.0 | 7.8 | 5.8 | 5.8 | **7.16** | ✅ | Only race-free-by-construction design with lease-reclaim + replay, but daemon machinery is overkill at 2–4 branches and a dead daemon stalls a tier invisibly. |
| 6 | a6 | Deep-research search shim (swap the skill's retrieval tool) | 7.8 | 8.3 | 5.2 | 6.5 | 7.2 | 7.5 | 5.5 | **6.81** | ✅ | Tightest, laziest constraint-6 fit — but its whole identity rests on an unverified deny→Bash-redirect; brilliant if a 20-min spike holds, collapses to an explicit orchestrator if not. |
| 7 | a4 | Makefile DAG scheduler (make -jN) | 7.7 | 6.8 | 6.3 | 5.8 | 7.3 | 6.3 | 6.0 | **6.65** | ✅ | Elegant DAG on an installed tool, but make's free resume is unsound for LLM recipes (exit-0 garbage marked done) and the static graph fights adaptive research. |
| 8 | a7 | Gateway unification — uniform claude-shape workers (LiteLLM/CCR) | 7.3 | 5.3 | 5.5 | 7.8 | 8.0 | 5.5 | 5.8 | **6.62** | ✅ | One-line model swaps and a free ledger, but the claude-shape proxy flattens the native capabilities (Gemini grounding/1M ctx, Codex sandbox) you run a fleet FOR, plus a SPOF. |
| 9 | a10 | uzi-as-engine (adopt CLI-first worktree fleet) | 6.5 | 5.7 | 6.7 | 7.3 | 7.2 | 5.8 | 5.7 | **6.48** | ✅ | Worktree isolation is a category mismatch with the read/fetch/verify research core; strip uzi and you're left with the design everything else already recommends — keep only the diff-gate. |
| 10 | a3 | Live tmux tiled send-keys warm-pane cockpit | 4.7 | 5.3 | 3.7 | 7.2 | 5.8 | 6.0 | 4.5 | **5.17** | ❌ | Warm send-keys panes need interactive TUIs but the workers are only reliable headless, and a fixed pane pool caps the wide fan-out — great monitor, wrong delegation core. |

*(Table scrolls horizontally on narrow screens. Fatal-flaw column collapsed into the verdict; a3 is the only non-survivor.)*

---

## Why the winner beat #2 and #3

**a1 wins because it is the only candidate whose core is sound *and* whose remaining gaps are additive, not structural.** Its file-handoff result capture is immune to TUI scraping, injection-safe, non-MCP by construction, and reuses every CLI already installed and authed — so it clears all six hard constraints with ~150 lines of bash and the shortest time-to-value in the field (8.7). All three judges independently ranked its core soundest. The two things standing between it and an overnight run — mandatory crash-reclaim/completeness enforcement and outer containment for unattended workers — are fixups bolted onto a correct spine, not redesigns.

**It beat #2 (a8, 7.41) on a load-bearing premise error.** a8's split-plane instinct is genuinely right (unify only stateless verify, keep agentic loops native), and the capability-maximalist even scored it above a1 on model-flexibility. But its headline justification — "funnel the stateless plane and you capture ~all the cost in one ledger" — is inverted: in a deep-research harness the token mass lives in the *search* fan-out, which is agentic and by a8's own rule stays native. So the LiteLLM daemon it adds captures the minority of spend while adding a new dependency. Drop that daemon and a8 *is* a1 with a curl map — meaning a1 is a8 with the unnecessary part already removed.

**It beat #3 (a9, 7.36) on where the effort went.** a9 shares a1's exact one-writer JSONL delegation core and posts the best monitoring score in the entire field (8.5). But it spends its complexity budget on an 80-line bun/SSE dashboard over the *preferred* tmux tail, while punting the constraints that carry the real intellectual weight — #6 (wrap the fan-out+verify harness) and shared claim/verify state — into a deferred SQLite variant. It is a monitoring architecture wearing a full solution's clothes; a1 built the engine first and left the cockpit deliberately thin.

---

## When you'd pick a different one instead

- **Pick a5** if this is a genuine 6+-worker overnight fleet run unattended for hours. a1's crash-reclaim is a bolted-on fixup; a5 is the only design *race-free by construction* with lease-reclaim and replay, and its SQL board doubles as the run-evidence ledger. The daemon overhead that sinks it at 2–4 branches is exactly what earns its keep at scale — provided you supervise the daemons (a dead one stalls a tier invisibly).
- **Pick a2** if you want a real reasoning model (Opus/Fable) genuinely *in the driver's seat* with a typed, auditable decision stream, and you're willing to eat the poll-loop context bloat for that visibility — worth it when the orchestration logic itself is the hard part, not the fan-out.
- **Pick a9** if a live fleet-view cockpit is the actual deliverable (demo, shared monitoring, watching N workers at a glance) — but only after promoting its Ledger variant and wiring the skill, so you're not shipping the dashboard on an under-built engine.
- **Pick a8** *once GLM is keyed* and you're regularly swapping models at the verify stage — the single stateless endpoint makes cross-model swaps a one-string change. Below that threshold it's strictly more moving parts than a1 for no gain.
- **Reach for a6** only as a 20-minute spike, never as the committed plan: if the deny→Bash-retrieval-redirect behavior is confirmed, it's the tightest, laziest constraint-6 fit in the field. If it isn't, it silently degrades to cross-model parametric hallucination — so it's a bet, not a default.

**Bottom line:** ship a1 tonight with the two fixups made mandatory; keep a5 in your pocket for the day this becomes a true unattended fleet.
