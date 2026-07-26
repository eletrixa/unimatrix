<!--
Cross-repo feedback drop-box for unimatrix — how agents in OTHER repos report back.

Project: unimatrix — multi-model swarm orchestrator driven from Claude Code
Module:  feedback/README.md (drop-box contract; the box itself is this directory)
Deps:    docs/research-backlog.md (triage destination), .claude/skills/unimatrix (points here)
Tested:  n/a (process doc)

Key responsibilities:
- One-file-per-item format any agent can write without reading unimatrix internals
- Triage protocol: feedback -> research backlog -> archive, with attribution preserved
-->

# unimatrix feedback drop-box

Any agent (or human) using unimatrix from another repo files feedback **here**:

**`feedback/`**

One markdown file per item. Don't edit unimatrix code or docs from outside — drop a file; the
unimatrix orchestrator triages it.

## Format

Filename: `YYYY-MM-DD-<source-repo>-<slug>.md` (e.g. `2026-07-24-brain-glm-timeout-flood.md`)

```markdown
---
source: brain        # repo the run was driven from
date: 2026-07-24
run: cal056                            # swarm run label, if any
type: bug                              # bug | friction | idea
severity: major                        # crit | major | minor
---

What happened, what you expected, and evidence paths (bus dir, res files, speedwars rows).
Keep it self-contained — the triager may not have your repo's context.
```

**Hard rules:** no secrets, no `.env` content, no fetched web content in the file body
(this directory is committed). Evidence stays as *paths*, not pasted dumps — and those paths must be
**repo-relative**, never absolute (`/home/<you>/…`): the trunk is public, and `check.sh`'s PII gate
scans this directory precisely because stubs here are machine-generated at every run close.
`source:` is the repo NAME, not its path. **No employer/client names anywhere — filename,
`source:`, or body; use the repo's public shorthand** (e.g. `grpn`, not the company name): the
gate greps content, but a filename enters git history where no later scrub can reach it — three
batches have now needed rename-and-rewrite because of this.

## Triage protocol

At unimatrix session start (or on request), the orchestrator:
1. sweeps `feedback/*.md` (newest first),
2. logs each item into `docs/research-backlog.md` with attribution (`source`, `date`, filename),
3. **before** the `mv`, adds a `triaged-to:` key to the file's frontmatter recording where it
   landed — one of:
   - `backlog#NN` (one or more ids, space-separated, if an item splits into several backlog rows)
   - `skill-ledger <YYYY-MM-DD>` (folded straight into the unimatrix skill's lessons ledger, no
     standalone backlog row)
   - `dismissed (<one-line why>)` (triaged and consciously not actioned)
4. moves the file to `feedback/archive/` — the archive is the audit trail, never deleted.

A feedback file is *pending* until it carries `triaged-to:` and lands in `archive/`.

## Draft stubs (machine-drafted)

Files named `*-auto-<class>.md` with `status: draft` frontmatter are auto-seeded at run close by
`feedback_stubs` (spec 12 FR-4) — a nudge, not a finished report. The triager either:

- **Confirms** the draft: delete the `status:` line, adjust `severity`/`type` as needed, add `triaged-to:`,
  triage normally to backlog or ledger.
- **Deletes** it: the draft was off-base or redundant with existing feedback.

Drafts never count as pending. Never archive a file with `status: draft` intact — a draft without
triager confirmation is unfinished and offers no signal value once archived.
