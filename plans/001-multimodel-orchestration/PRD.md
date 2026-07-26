# UNIMATRIX — PRD & Winning Solution

**Status: SHIPPED (historical).** Built as specs 01-09; this folder is the original research record
— do not implement from it.

**Multi-model orchestration + live monitoring, driven from a Claude Code slash command.**
Repo: `<repo>` · Host: WSL2 on Windows · Date: 2026-07-08

**Winner: `a1` — "Headless spawn + JSONL bus + tmux/WezTerm tail cockpit"** (score 8.18, verify verdict *strong*, all six hard constraints satisfied, no fatal flaw). Command name: **`/swarm`**.

---

## 1. Executive summary (the winning solution in 5 sentences)

A Claude Code slash command `/swarm "<question>"` runs Opus/Fable as the orchestrator, uses the built-in **deep-research** workflow to decompose the question into branches, drops one prompt file per branch into a file bus, and spawns each branch as a **headless worker CLI** (`codex exec` / `gemini -p` / `claude -p`) whose stdout is redirected to a per-run JSONL on ext4. The single load-bearing insight — verified real against the installed flags — is that the **answer is read from each CLI's own structured handoff file** (`codex --output-last-message`, the `stream-json` result envelope), **never from the terminal buffer**, which sidesteps the entire send-keys / ANSI-scrape failure class that sinks every tmux-orchestrator clone. Delegation is therefore **CLI/file/pipe only (no MCP)** and injection-safe, because prompts travel as files and never as shell strings or keystrokes. A **separate tmux window on an isolated socket** (`tmux -L swarm`) tails those JSONL files through `jq` and watches `ccusage` for cross-lane cost, optionally fronted read-only by `wezterm.exe` from Windows. It is ~150 lines of bash reusing everything already installed and authed (three keyed lanes today; GLM is a keyed enhancement), with **two additions made mandatory before any unattended run**: crash-completeness (block synthesis until every branch reports) and outer containment (scrub secrets from worker env, sandbox the web-facing worker).

---

## 2. Why it won vs the runners-up

| # | Candidate | Score | Verdict | Why it lost to a1 |
|---|-----------|------:|---------|-------------------|
| **a1** | **Headless spawn + JSONL bus + tail cockpit** | **8.18** | **strong · all constraints · no fatal flaw** | **Winner.** |
| a8 | Split-Plane hybrid (LiteLLM gateway for stateless verify) | 7.41 | strong, not winner-grade | Its distinguishing feature — the LiteLLM gateway — rests on an **inverted cost premise** (the token mass is in the *native* search fan-out, not the stateless verify plane) and adds a load-bearing daemon (not installed) to save a curl over lanes already keyed. Its own verifier says "the feature that distinguishes it is the feature you should defer" — i.e. the best version of a8 collapses *toward a1*. |
| a9 | Zero-DB SSE web dashboard (Glass) | 7.36 | `satisfies_all_constraints: FALSE` | Same sound JSONL delegation core as a1, but pays for an 80-line bun/SSE dashboard **nobody asked for** over the *preferred* tmux cockpit, and **defers constraint 6** (fan-out/verify coordination) to a variant. "A gorgeous cockpit over an under-built engine." Fails constraint 2 (browser ≠ preferred wezterm/tmux/starship) and 6 as written. |
| a2 | Agent SDK orchestrator wrapping deep-research | 7.35 | `satisfies_all_constraints: FALSE` | Real Opus-in-the-driver's-seat via the SDK, but the **poll-loop bloats context**, it needs `bun add` of the SDK, and its headline claim ("wraps the deep-research skill") is only **nominal** — deep-research is a bundled Workflow compiled into the claude binary with **Claude-only** internal fan-out, so cross-model diversity lives entirely *outside* the skill anyway. Heavier than a1 for thin marginal value. |
| a5 | SQLite poll-and-lease work-queue | 7.16 | strong · all constraints | Race-free *by construction* and the board doubles as the run ledger — genuinely the right answer **for wide 6+ overnight fleets** — but it centres **long-lived unsupervised daemons + reaper** whose worst failure (a dead daemon → a tier stuck `queued`) is **invisible on the very SQL board meant to catch it**. Over-built for your likely 2-4-branch reality; its own fixups delete the daemons and converge on a1's spawn-per-subtask shape. |

**The through-line:** every design above a1 in ambition either (a) adds a not-installed daemon that becomes a fleet-wide SPOF (a8, a5), (b) optimizes a surface the user didn't ask for (a9), or (c) buys a heavier runtime for marginal value (a2) — and in **each case the adversarial + verify passes concluded the best version regresses toward a1's file-bus core.** a1 is the "build-thin, don't-buy" conclusion executed: zero new dependencies, all six constraints met with primitives already on the machine, and its correctness insight mechanically verified against the installed CLI flags.

---

## 3. Architecture

```
                              /swarm "<question>"
                                      │
                                      ▼
                ┌──────────────────────────────────────────┐
                │  ORCHESTRATOR  —  Claude Code session      │
                │  Opus / Fable                              │
                │   1. deep-research workflow → decompose    │
                │   2. write .bus/specs/<id>.prompt (files)  │
                │   3. swarm-run.sh: spawn headless workers  │
                │   4. GATE: block until all N report        │
                │   5. verify wave (cross-model) → synthesize│
                └───────────────────┬──────────────────────┘
        spawn (xargs -P / atomic-rename mailbox) — prompts as FILES, no keystrokes
        ┌────────────────┬──────────┴───────┬────────────────────┐
        ▼                ▼                   ▼                    ▼
  ┌───────────┐    ┌───────────┐      ┌───────────┐        ┌───────────┐
  │ codex exec│    │ gemini -p │      │ claude -p │        │ claude -p │
  │ code /    │    │ web /     │      │ GLM*      │        │ Opus/Sonnet│
  │ extract / │    │ long-ctx /│      │ cheap     │        │ VERIFY    │
  │ sandbox   │    │ grounding │      │ grind     │        │ (≠gen)    │
  └─────┬─────┘    └─────┬─────┘      └─────┬─────┘        └─────┬─────┘
        │  stdout → per-worker JSONL  +  last-message .txt (ONE writer each)
        ▼                ▼                   ▼                    ▼
  ╔══════════════════════════════════════════════════════════════════════╗
  ║  FILE BUS   ./.bus   (local POSIX fs ONLY — never a 9p/drvfs mount) ║
  ║   specs/<id>.prompt   run-<id>.jsonl   res-<id>.txt                   ║
  ║   queue/ ──mv──▶ claimed/ ──mv──▶ done/   (atomic rename = race-free  ║
  ║                                            lease + crash reclaim)      ║
  ╚══════════════════════════════════════════════════════════════════════╝
        │  append-only · tail -F                          ▲
        ▼                                                 │ done-markers gate synthesis
  ┌────────────────────────────────────────────┐         │
  │  MONITOR WINDOW  (separate, isolated socket)│─────────┘
  │  tmux -L swarm                              │
  │   ┌──────────────┬───────────┬───────────┐ │
  │   │ board:       │ firehose: │ cost:     │ │
  │   │ ls queue/    │ tail -F   │ watch     │ │
  │   │ claimed/done │ *.jsonl|jq│ ccusage   │ │
  │   └──────────────┴───────────┴───────────┘ │
  │  WezTerm.exe (Windows) attaches READ-ONLY: │
  │   wezterm.exe cli spawn --new-window --     │
  │     wsl.exe -- tmux -L swarm attach -r -t mon│
  │  starship prompt in each pane               │
  └────────────────────────────────────────────┘

  * GLM lane gated on a Z.ai key — child-only ANTHROPIC_BASE_URL swap on the spawned
    claude subprocess. Pipeline is fully functional on the 3 keyed lanes without it.
```

**Data-plane vs control-plane:** the JSONL firehose is glance-only human overlay; the **result** always comes from the handoff file. The mailbox (`queue/→claimed/→done/`) is the control plane — an atomic directory-entry rename on ext4 gives race-free claiming and lease-based crash reclaim with **no SQLite, no daemon, no socket, no MCP.**

---

## 4. The `/swarm` command UX — step by step

**Entry point:** `./.claude/commands/swarm.md` (a project slash command — *does not exist yet, Phase 0 creates it*). Invocation:

```
/swarm "research the GLM-5.2 vs Gemini-3 pricing cliff and draft a routing table"
```

**Two invocation modes** (the orchestrator is *this* Claude Code session — Fable runs in it, there is no separate orchestrator process):

- **One-shot:** `/swarm "<Q>"` — plan + fan-out in one turn (the step list below).
- **Plan-first (default for attended use):** plan interactively in Claude Code as long as needed — normal conversation or plan mode, iterate until the decomposition is agreed — then bare `/swarm` means "swarm the plan we just built": Fable converts the agreed branches into specs and starts at step 2. Mid-run the same session stays the brain: while the gate blocks, interrupt (Esc) and steer — Fable edits the bus (cancel / re-queue / add) and re-enters the gate. See runbook §8 for the full control story.

Step by step, what the command does:

1. **Plan (Opus/Fable, in-session).** The orchestrator reads the question and invokes the **deep-research** workflow to *scope and decompose* it into N independent branches. It runs an **independence check** — no two branches may write the same file / claim the same sub-question — so fan-out is safe to parallelize.
2. **Emit specs (files, not strings).** One prompt file per branch: `.bus/specs/<id>.prompt`. Each carries the branch's sub-question, the target model/lane, and the output contract. Prompts *never* get interpolated into a `send-keys` or `sh -c` string — this is the injection-safety guarantee.
3. **Enqueue.** Each spec is `mv`'d into `.bus/queue/`. (Atomic rename = the whole scheduler primitive.)
4. **Spawn headless workers.** `swarm-run.sh` claims each queued spec (`mv queue/<id> claimed/<id>`) and spawns the **mapped CLI headless** with stdout → `.bus/run-<id>.jsonl` and the structured answer → `.bus/res-<id>.txt`. Concurrency is `xargs -P<N>` bounded to the fan-out ceiling. (Exact invocations: §5.)
5. **Generate wave completes.** On exit, each worker's spec moves `claimed/<id> → done/<id>` (the done-marker). A lease reaper re-queues any `claimed/` entry older than the timeout (crash reclaim).
6. **GATE (mandatory).** The orchestrator **blocks synthesis until all N done-markers exist.** A killed / OOMed / rate-limited worker leaves a stale lease → re-queued, not silently dropped. **No synthesis from a partial set — ever.**
7. **Verify wave (cross-model).** Each falsifiable claim from the generate wave is re-checked by a **model different from the one that generated it** (the one place heterogeneous models measurably cut correlated hallucination). Same file-bus mechanics, one more `xargs -P` pass.
8. **Adjudicate + synthesize (Opus/Fable).** The orchestrator reads the `.bus/res-*.txt` handoffs + verify verdicts and writes the **cited report** to `docs/` (or stdout).
9. **Ledger.** Each spawned run is logged per-lane to the unimatrix LLM-run-evidence surface with cost **re-summed from `ccusage` / the result envelope** (never per-`stream_event`, which is inflated 3-8× — claude-code #6805).

**What the operator sees:** the orchestrator session prints the plan and the final report; the *separate* monitor window (§7) shows the live per-worker firehose and running cost. The operator never has to read a TUI to get the answer.

---

## 5. Delegation — which model does what, and the exact invocations

**Model map (concrete to installed + keyed lanes):**

| Lane | Role | CLI | Keyed today? |
|------|------|-----|:---:|
| **Opus / Fable** | Plan · independence-check · adjudicate · synthesize | in-session (Claude Code) | ✅ authed |
| **Gemini** | Web search · grounding · >200K / long-context branches | `gemini -p` | ✅ `GEMINI_API_KEY` |
| **Codex** | Code · structured extraction · sandboxed edits · a verifier lane | `codex exec` | ✅ `OPENAI_API_KEY` |
| **Claude (verify)** | Cross-model verifier (≠ generator) | `claude -p` | ✅ authed |
| **GLM** | Cheap parallel grind · source summarization | `claude -p` + env swap | ❌ **no key — gated** |

**Concrete headless invocations** (all write JSONL to the bus and the answer to a `.txt` handoff — never the pane):

```bash
# CODEX — code / extraction / sandboxed. Answer from --output-last-message.
codex exec --json \
  --output-last-message .bus/res-<id>.txt \
  -s workspace-write --skip-git-repo-check \
  -C <worktree> -m <codex-model> \
  "$(cat .bus/specs/<id>.prompt)"  | tee .bus/run-<id>.jsonl

# GEMINI — web / long-context / grounding. 2>/dev/null is mandatory (stderr banner corrupts jq).
gemini -m gemini-2.5-flash -o stream-json \
  -p "$(cat .bus/specs/<id>.prompt)"  2>/dev/null | tee .bus/run-<id>.jsonl
#   final answer reassembled from the result envelope, or:  gemini ... -o json | jq -r .response

# CLAUDE (native verify lane) — cross-model check, model ≠ the generator.
claude -p --output-format stream-json --verbose \
  --model <claude-model> \
  "$(cat .bus/specs/<id>.prompt)"  | tee .bus/run-<id>.jsonl
```

**GLM access path + prerequisite key (the one hard external dependency).** No Z.ai / Zhipu / BigModel key exists in `$ENV_MASTER_FILE` (verified: 0 matches). To light the GLM lane:

1. **Buy the key.** Z.ai **Coding Plan** (Lite tier, ~$18 per the decision context) → mint a key, store as `Z_AI_CODING_KEY` in `$ENV_MASTER_FILE`. *(BigModel/Zhipu open-platform is the mainland alternative with a different account + billing.)*
2. **Wire it via the Anthropic-compatible swap — child env ONLY** (never global, or it hijacks the Opus/Fable orchestrator's real Anthropic auth):

```bash
# GLM — reuses the already-installed claude binary. child-only env.
env ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic \
    ANTHROPIC_AUTH_TOKEN="$Z_AI_CODING_KEY" \
  claude -p --output-format stream-json --verbose \
    "$(cat .bus/specs/<id>.prompt)"  | tee .bus/run-<id>.jsonl
```

- **Endpoint discipline:** the Anthropic-compat base is `…/api/anthropic`. The OpenAI-compat coding endpoint is `…/api/coding/paas/v4` (chat-completions, `wire_api=chat`) — used only if you route GLM through `codex`/curl instead. **The two are NOT interchangeable** — the wrong one 404s/rejects the key.
- **Economics:** pin cheap subtasks to **`glm-4.7`** (GLM-5.2 burns ~3× quota at peak); metering is **prompts-per-5h** (Lite ~80 / Pro ~400), so **size fan-out to the tier** and route non-interactive grind/verify to **Batch APIs (−50%)** rather than a subscription window.

**Scheduler** = `xargs -P<N>` (or the atomic-rename mailbox for lease-based reclaim). That is the *entire* scheduler — no queue framework, no daemon.

**Why no `--output-schema`:** codex silently ignores `--output-schema` when built-in tools are active (#15451); the design reads `--output-last-message` instead, which is not affected.

---

## 6. Non-MCP comms substrate

Delegation and coordination are **CLI / file / pipe only** — constraint 3 holds *by construction*, no MCP anywhere:

- **Transport:** append-only **JSONL, one file per worker**, under `./.bus`. One-writer-per-file makes `O_APPEND` interleave a non-issue at fleet size 3-6 — no DB needed.
- **ext4 ONLY.** The bus lives on the Linux-native fs (project root is ext-family, verified). **Never** point it at `/mnt/c` or `/mnt/f` — 9p breaks `inotify`, `O_APPEND` atomicity, and `flock`. This is a hard rule, easy to violate accidentally.
- **Result handoff:** each CLI's own structured file — `codex --output-last-message`, the `stream-json` result envelope. The answer is *never* scraped from the terminal.
- **Coordination / claiming:** atomic directory-entry **rename** (`mv queue/<id> → claimed/<id> → done/<id>`). Rename is atomic on ext4 → race-free claim + lease-based crash reclaim, **with no SQLite and no daemon.** Done-marker files (entries in `done/`) signal completion and gate synthesis.
- **No sockets, no FIFOs, no MCP, no keystroke injection.** Prompts are files; that is also the injection-safety property.

---

## 7. Monitoring window design (tmux / WezTerm / starship, concrete)

A **separate window on an isolated tmux socket** (`-L swarm`) so it never collides with your working tmux. Rich structured state comes from the JSONL, so there is **zero capture-pane / ANSI screen-scraping.**

**Cockpit bootstrap** (from `swarm-run.sh` or a `/swarm-mon` helper — milestone Phase 3):

```bash
cd "$REPO"   # repo root
tmux -L swarm new-session -d -s mon -n unimatrix

# pane 1 — mailbox board (queue / claimed / done at a glance)
tmux -L swarm send-keys -t mon \
  "watch -n2 'printf \"Q:%s C:%s D:%s\\n\" \$(ls .bus/queue|wc -l) \$(ls .bus/claimed|wc -l) \$(ls .bus/done|wc -l); ls -1 .bus/claimed'" C-m

# pane 2 — per-worker firehose (DEFENSIVE jq: tolerate non-JSON + unknown types)
tmux -L swarm split-window -h -t mon \
  "tail -F .bus/run-*.jsonl 2>/dev/null | jq -rc 'fromjson? | select(.type==\"tool_result\" or .type==\"error\" or .type==\"result\")' 2>/dev/null"

# pane 3 — cross-lane cost (reads canonical session logs; dodges stream-json inflation #6805)
tmux -L swarm split-window -v -t mon "watch -n5 ccusage"

tmux -L swarm select-layout -t mon tiled
```

**WezTerm outer window (read-only), from Windows or via the full `/mnt/c` path in WSL** (`wezterm.exe` is Windows-side — confirmed at `/mnt/c/Program Files/WezTerm/wezterm.exe`, **not** on the WSL PATH):

```bash
"/mnt/c/Program Files/WezTerm/wezterm.exe" cli spawn --new-window -- \
  wsl.exe -- tmux -L swarm attach -r -t mon
```

- `-r` = **read-only** attach (a monitor, not a second driver).
- **starship** is already the global prompt (1.26.0); optionally set a distinct `STARSHIP_CONFIG` in the monitor panes to show the active `run-id` in the right-prompt. *ponytail: cosmetic — don't over-configure.*

**Cautions (bake into the monitor code):**
- Always `2>/dev/null` on `gemini` **before** piping to `jq` (the stderr banner corrupts the JSON stream). Never `2>&1`.
- `stream-json` schema is **undocumented and version-drifts** across all three CLIs — the `jq` filter must tolerate unknown `type` values (`fromjson? | select(...)`). Pin `claude 2.1.203 / codex 0.142.5 / gemini 0.28.2` and re-smoke on every upgrade.
- If the orchestrator Bash runs **inside Claude Code's own sandbox**, launching the `/mnt/c` `wezterm.exe` may be blocked (crosses a denied socket); `WEZTERM_PANE` also isn't forwarded into WSL (any `wezterm cli` follow-up needs an explicit `--pane-id`). **`tmux -L swarm` alone satisfies constraint 2** — WezTerm is just the outer chrome; attach the session in any existing WezTerm pane if the spawn is blocked.

---

## 8. Deep-research integration (constraint 6, honestly)

**What deep-research actually is** (verified in a2's pass): not a `SKILL.md`, but a **bundled Workflow compiled into the `claude` binary** (`initBundledWorkflows` / `WorkflowTool`), phases **Scope → Search (parallel WebSearch agents) → Fetch (WebFetch) → Verify (3-vote) → Synthesize**. Its internal fan-out is **Claude-only** — it has no cross-model dimension. This is a Workflow harness, **not** an MCP tool, so wrapping it honors constraint 3.

**How `/swarm` wraps it** — two roles, no reimplementation:

1. **Decomposition engine.** `/swarm` invokes the deep-research workflow to **scope and split** the question into independent branches (step 1 of the UX). The Workflow's own Scope/Search/Verify logic is the reasoning core; the swarm does **not** rebuild it in bash.
2. **Cross-model layer the Workflow lacks.** The swarm maps deep-research's fan-out → verify onto **heterogeneous CLI lanes** — the generate wave routes each branch to its mapped model, and the **verify wave routes each claim to a *different* model than generated it.** This is the one thing the built-in (single-model) Workflow structurally cannot do, and it is exactly where model diversity pays off.

So constraint 6 is satisfied *literally*: the core reasoning **is** the deep-research fan-out+verify harness (non-MCP), and the swarm adds the cross-model adversarial verify around it. A branch that needs full-fidelity research can itself run a nested `claude -p` deep-research pass inside its worker process — the fan-out stays inside that one CLI process, one bus file, one done-marker.

---

## 9. Build phases (milestones, not code)

**~4-5 days, front-loaded value. Everything reuses installed tooling — no new dependency.**

| Phase | Milestone (done = observable) | Effort |
|------|-------------------------------|:------:|
| **0 — Scaffold & decide** | `.claude/commands/swarm.md` + `swarm-run.sh` skeleton exist; `mkdir -p .bus/{specs,queue,claimed,done}`; CLI versions pinned; the defensive `jq` filter written once. **Decision made on GLM** (buy key vs ship 3-lane — Q1). `/swarm` echoes a plan and creates the bus tree; no workers yet. | ½ d |
| **1 — 3-lane MVP** | `swarm-run.sh` spawns the 3 **keyed** lanes headless (codex/gemini/claude), stdout→JSONL, **answer read from the handoff file**. `xargs -P` scheduler; single `tail` pane. `/swarm "<Q>"` fans out 3 branches and Opus synthesizes from the `.txt` handoffs, **attended, end-to-end.** | 1 d |
| **2 — Completeness & containment (MANDATORY before any unattended run)** | Atomic-rename mailbox + lease reaper; orchestrator **blocks synthesis until all N done-markers exist** and re-queues stale leases. Worker env **scrubbed** of `$ENV_MASTER_FILE` + `~/.aws` + `~/.ssh`; web-facing worker **network-restricted, secrets-free, write-scoped to a scratch worktree** (docker 29.6.1 present → sandbox or `@anthropic-ai/sandbox-runtime`; prefer `codex` network-off `workspace-write`; **never bare `gemini --yolo`**). *Test:* kill a worker mid-run → orchestrator detects the gap, re-queues, refuses partial synthesis. | 1 d |
| **3 — Monitor cockpit** | `tmux -L swarm` multi-pane (board + firehose + `ccusage`), starship, WezTerm read-only attach. Separate window shows live per-worker events + cross-lane cost without touching the orchestrator session. | ½ d |
| **4 — Deep-research wrap + cross-model verify wave + ledger** | `/swarm` invokes the deep-research Workflow to decompose; **verify wave routes each claim to a model ≠ its generator**; Opus adjudicates. Every spawned run logged per-lane to the unimatrix **LLM-run-evidence** surface with cost re-summed from `ccusage`/result envelope. A real run yields a **cited report whose claims each carry a cross-model verifier and a cost line.** | 1 d |
| **5 — GLM lane (gated, optional, after key)** | 4th lane via **child-only `ANTHROPIC_BASE_URL` swap** on spawned `claude -p`; cheap subtasks pinned to `glm-4.7`; fan-out sized to metered ceilings; grind routed to Batch (−50%). GLM branch appears in the fan-out and logs prompt-quota consumption. | ½ d |

---

## 10. Prerequisites, risks & mitigations

**Prerequisites (must be true before a run):**

1. **Create the entry point** — `./.claude/commands/swarm.md` + `swarm-run.sh`. *Nothing exists today* (repo has only `.git/ docs/ plans/`). Trivial, but nothing runs until written.
2. **Bus tree on a local POSIX fs** — `mkdir -p ./.bus/{specs,queue,claimed,done}`. **Never** on a 9p/drvfs mount (`/mnt/c`, `/mnt/f`).
3. **GLM key (the one hard external prereq)** — buy a Z.ai Coding Plan (~$18 Lite), store `Z_AI_CODING_KEY` in `$ENV_MASTER_FILE`. Until then: honest **3-lane** operation (Anthropic/OpenAI/Gemini all confirmed keyed).
4. **Validate model IDs against key tiers** before hardcoding (`gemini-2.5-*` vs `gemini-3-*` depends on the AI-Studio tier; pick the codex model available on `OPENAI_API_KEY`).
5. **Pin CLI versions** (2.1.203 / 0.142.5 / 0.28.2) + defensive `jq`; re-smoke `stream-json` on upgrade.

**Risks & mitigations:**

| Risk | Sev | Mitigation |
|------|:---:|-----------|
| **Silent lost subtask** — crashed/OOMed/rate-limited worker writes no result; orchestrator synthesizes a confident report from N−1 branches. | **High** | **Make completeness mandatory (Phase 2):** done-marker gating + lease reaper; **block synthesis until all N report.** No synthesis from a partial set. |
| **Secret exfil / prompt-injection** — deep-research fetches untrusted web; workers inherit an env that can read `$ENV_MASTER_FILE`; bare `gemini --yolo` is unsandboxed. | **High** | **Containment (Phase 2):** scrub `$ENV_MASTER_FILE` + `~/.aws` + `~/.ssh` from worker env; sandbox the web worker (**docker 29.6.1 IS installed** — containment is *easier* than the adversary assumed); prefer `codex` network-off; never bare `--yolo`. |
| **GLM lane vaporware** until a key is bought; and once bought, GLM-5.2 burns ~3× quota, metered prompts/5h → wide fan-out can drain it mid-wave. | Med | Buy the Z.ai key **or** document honest 3-lane; pin `glm-4.7`; size fan-out to the tier; route grind to Batch (−50%). |
| **Subscription/rate-window throttling** — Codex 5h windows / GLM prompts/5h choke on wide dispatch. | Med | Route non-interactive verify/grind to **metered API keys / Batch**, not subscription plans; cap fan-out width to the ceiling. |
| **Monitor rot on CLI upgrade** — undocumented, drifting `stream-json` schema; gemini stderr banner. | Med | Pin versions; defensive per-line parser (`fromjson? | select`); always `2>/dev/null` before `jq`; re-smoke on upgrade. |
| **WezTerm monitor no-ops** under sandboxed Bash / missing `--pane-id`. | Med | Non-fatal: **`tmux -L swarm` alone covers constraint 2**; call wezterm by full `/mnt/c` path; attach in an existing WezTerm pane if spawn is blocked. |
| **gemini fixed per-call overhead** (~7900 input tokens on a trivial prompt) — cheap fan-out isn't as cheap as it looks. | Low | Batch small tasks per gemini call; log actual `.stats`, not estimates. |
| **Wave-shaped latency / no live "thinking"** stream — you see emitted events, not reasoning. | Low | Acknowledged UX weakness, not a correctness risk; pipeline waves if throughput matters. |

---

## 11. Open questions for the operator

1. **GLM now or later?** Buy the ~$18 Z.ai Lite key this week (lights the 4th lane via the child-env swap), or ship honest **3-lane** v1 and add GLM in Phase 5? *(Default recommendation: ship 3-lane now, buy the key in parallel — it's off the critical path.)*
2. **Autonomy level for v1** — attended-only, or true **overnight unattended**? This decides whether Phase 2 containment is a v1 blocker (it is, the moment a run is unattended).
3. **Orchestrator brain** — **Fable or Opus** for plan + adjudicate + synthesize? (Fable = your persona/output-style over the same Anthropic auth; Opus = raw.) Any budget ceiling on the orchestrator turns?
4. **Monitor scope for v1** — is **tmux-only** acceptable, or is the WezTerm read-only outer window required day one? (tmux satisfies the constraint; WezTerm is chrome.)
5. **Default fan-out width `N`** — 2-4 (your likely reality) or do you want headroom to 6+? This sets the `xargs -P` ceiling and the GLM tier sizing.
6. **Worktree strategy** — run each code branch in a **scratch git worktree** (isolation + easy cleanup) or in the repo root? Research branches probably don't need a worktree; code/edit branches do.
7. **Batch API for verify/grind** — acceptable to route the non-interactive verify wave to **Batch (−50%)** and eat the added latency, or keep everything sync for speed?
8. **LLM-run-evidence surface for unimatrix** — new ledger file in this repo, or fold into an existing evidence surface? Your CLAUDE.md mandates per-lane cost logging for spawned runs; Phase 4 needs a target.

---

*Winner selected per the stated rule — highest score that passes verification, no fatal unmitigated flaw. a1 at 8.18 with verify verdict "strong" and `satisfies_all_constraints: true` is the unambiguous pick; the two conditions (mandatory completeness + containment) are additive Phase-2 fixups on a sound core, not structural defects. All ground-truth facts re-confirmed on the box 2026-07-08.*
