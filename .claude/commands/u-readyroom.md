---
description: Prepare and route ready-room research and decision swarms
argument-hint: "<research|decision|ceo> \"<subject>\" [--run <label>]"
---

# /u:readyroom
**Deprecated** — The bare `/u-readyroom` alias is deprecated in favor of `/u:readyroom` under spec 17 FR-8 naming.

The session model (`fable`) orchestrates only. Skills in the refactor lead repo own all three pipelines. This command establishes the environment, enforces gates and cost posture, then follows the owning skill.

## Modes

| Mode | Pipeline | Owner |
|---|---|---|
| `research` | Deep research sweep through tracks and evidence phases | `rfg-dxx-research` |
| `decision` | Domain decision using two 4-candidate weighted matrices and an adversarial court | `rfg-dxx-research`, section 4d |
| `ceo` | CEO decision with M1/M2 scoring against the frozen rubric and a two-pager | `rfg-ceo-decision` |

## Launch preamble

```bash
export UNIMATRIX_HOME=~/code/unimatrix
export CONF="$UNIMATRIX_HOME/profiles/readyroom.conf"
export ENV_MASTER_FILE=~/s/.env.master
export READYROOM_JUDGE=opus   # or codex
export DOCTOR_LANES="glm grok codex claude"
```

Export the preamble before launch. Select the requested mode, pass the subject and optional run label, then execute the owning skill's procedure.

## Doctor gate

Run `unimatrix doctor --live`. A nonzero exit stops the launch: identify the failing lane and report it. Never improvise around a dead lane.

## Judge switch

Set `READYROOM_JUDGE=opus` for the default quality posture. Set it to `codex` for thrifty-grade cost. Export the choice before launch.

The switch flips the profile's review seat and Codex's verify judge. It also selects the `.lane` pin for judge-seat cards: matrix scorers, M1/M2, refute, and triangulation. Bulk cards always verify on Codex.

## Web cards

Grok carries `web_search` and `web_fetch`. Read-only Grok cards receive both through the profile's `GROK_TOOLS`. Every web-card prompt must demand deep-link citations.

Seed one tricorder card per run. Pin it to read-only Grok and have it spot-check sampled citations live.

## Internal evidence

Worker cages cannot use `curl` and cannot reach WARP- or CA-gated hosts. The orchestrator fetches evidence from GHE, Jira, Confluence, agnes, and gws with the fetch scripts in the refactor repository. Workers only ANALYZE the resulting dumps.

## Token diet

Observe runs only through `swarm-ctl status`, `swarm-ctl timeline`, and `swarm-ctl postmortem`. Never read run logs or card bodies. Prose deliverables belong on worker cards; never write them in-session.

## Close-out

Run:

```bash
unimatrix report --run rr-<slug>
```

Read the Anthropic share footer. Target no more than 50% in Opus mode, with 30–45% expected; target below 10% in Codex mode. Report a miss plainly. Never massage ledger data.
