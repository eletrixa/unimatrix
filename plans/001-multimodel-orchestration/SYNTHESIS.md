# Synthesis — UNIMATRIX plan review (2026-07-08)

One-page digest of the whole research + an independent re-review of the winner. Verdict first.

## Verdict: a1 is the right choice — confirmed, with 3 adjustments

a1 wins not because it scored highest (8.18) but because of a structural fact the adversarial
passes exposed: **every stronger-looking alternative collapses into a1 when you fix its flaws.**
- a8 minus its LiteLLM gateway (built on an inverted cost premise) = a1 with a curl map.
- a5 minus its standing daemons (whose death is invisible on its own board) = a1's spawn-per-subtask.
- a9's delegation engine IS a1's core; it only adds a browser cockpit the constraints didn't ask for.
- a2 wraps deep-research only nominally and pays SDK + poll-loop bloat for it.

a1 is what remains when the over-build is deleted. Zero new dependencies, all six constraints
verified live on this box, injection-safe by construction. Given the locked decisions
(attended v1, 2–4 branch fan-out, Fable brain), no rival configuration beats it.

**The one rule that carries everything:** read the answer from each CLI's structured handoff file
(`codex --output-last-message`, `stream-json` result envelope) — never the terminal. Everything
else is plumbing around that rule.

## The system in one paragraph

`/swarm "<Q>"` → Fable plans and decomposes in-session → one prompt file per branch into
`.bus/specs/` → headless workers spawn per lane (`codex exec` / `gemini -p` / `claude -p` /
GLM via child-only `ANTHROPIC_BASE_URL` swap) → stdout streams to per-worker JSONL on ext4,
answers land in handoff `.txt` files → atomic `mv queue→claimed→done` is the whole scheduler →
synthesis blocked until all N done-markers exist → cross-model verify wave (verifier ≠ generator)
→ Fable adjudicates and writes the cited report. Watched from `tmux -L swarm` (separate window),
optionally fronted read-only by `wezterm.exe` from Windows. No MCP, no daemon, no DB, ~150 lines bash.

## Review adjustments (deltas over PRD, adopted)

1. **Demote deep-research from decomposer to worker tool.** The softest joint in the PRD:
   deep-research is a bundled Workflow with Claude-only fan-out and Scope→Search→Fetch→Verify
   phases — invoking it "just to decompose" is unverified and risks it running its whole
   search pipeline (token burn) before the swarm even fans out. Fix: **Fable decomposes
   directly in-session** (it is the orchestrator brain — that is its job); deep-research runs
   *inside* research-heavy workers as a nested `claude -p` pass (already sanctioned in PRD §8).
   Constraint 6 stays honestly satisfied; one unverified behavior leaves the critical path.
2. **GLM is now the critical path AND the only never-tested lane.** The 4-lane day-one decision
   put the one lane with no key and no live test on the critical path. First action when the key
   lands: a PONG smoke over `https://api.z.ai/api/anthropic` *before* wiring it into Phase 1.
   Add the GLM lane to the re-smoke ritual on every `claude` CLI upgrade — third-party
   Anthropic-compat is the most drift-prone seam in the design.
3. **Robustness is a1's weakest judged score (7.2) — acceptable only because v1 is attended.**
   The trigger to revisit a5 (SQLite lease queue): regular unattended runs with 6+ branches.
   Until then the mailbox + reaper (Phase 2) covers crash-reclaim.

## Proven vs assumed

| Proven live on this box | Still assumed |
|---|---|
| All 3 CLIs run headless with structured output (receipts in `docs/01-feasibility-tests.md`) | GLM lane end-to-end (no key yet) |
| WezTerm cli spawn/get-text round-trip from WSL | deep-research invocable as a scoped sub-step *(now moot — demoted per adjustment 1)* |
| tmux file-bus with worker-as-pane-command | `xargs -P` + mailbox behavior under real N-way fan-out |
| ext4 bus, atomic rename, `jq` firehose | stream-json schema stability across upgrades (pinned as mitigation) |

## Top 3 risks (of 8 in PRD §10)

1. **Silent lost subtask** → done-marker gate, no synthesis from partial set (Phase 2, mandatory before AFK).
2. **Secret exfil via web-facing worker** → env scrub + docker sandbox (Phase 2, mandatory before AFK).
3. **GLM quota economics** — prompts-per-5h metering, GLM-5.2 burns ~3× → pin `glm-4.7`, size fan-out to tier.

## State

Decisions locked (DECISIONS.md): 4-lane day-one · attended v1 · Fable brain.
**Blocking:** you buy the Z.ai key (~$18 Lite) → `Z_AI_CODING_KEY` in `$ENV_MASTER_FILE`.
Phase 0 scaffold can start on greenlight; Phase 1 runs 3-lane until the key exists.
