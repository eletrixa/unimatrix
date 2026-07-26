# Skill Symlinks (P0-FR2)

**Date:** 2026-07-25

## Task

Convert every account-side hand-synced copy of the `unimatrix` skill into a symlink pointing at
the canonical repo file `.claude/skills/unimatrix/SKILL.md`, so all copies are one inode.

## Inventory

Canonical repo file: `.claude/skills/unimatrix/SKILL.md` (tracked, HEAD at time of writing).

Hand-synced copies found (8 total — the main account plus 7 sub-accounts, same account set as
`plans/004-plugin-cli-cockpit-fleetops/pre-mortem.md` line 11):

- `~/.claude/skills/unimatrix/SKILL.md`
- `~/.claude-acct/{Gmail,eletrixa,gmail,<work>,post,rob7,soulfire}/skills/unimatrix/SKILL.md`
  (glob form: `~/.claude-acct/*/skills/unimatrix/SKILL.md`)

No siblings found next to `SKILL.md` in any of the 8 directories (`find ... ! -name SKILL.md`
returned empty) — nothing else to leave untouched.

## Result: STOPPED — no conversions performed

All 8 hand-synced copies are byte-identical to each other (one md5), but **all 8 differ from the
canonical repo file** (a second, different md5). Per the "never destroy divergent content" rule,
none were converted to symlinks — converting any of them today would silently drop real content
when the symlink target (canonical) is read instead of the copy.

Diff (canonical vs. the hand-synced copies — identical diff against every one of the 8):

1. The hand-synced copies carry a "Direct call (spec 15)" paragraph (~5 lines, `unimatrix call
   <lane> "<prompt>"` usage) that does **not** exist in the canonical repo file today.
2. One lessons-learned line differs by PII-scrub level only: canonical already carries the
   scrubbed short project label; the hand-synced copies still carry the unscrubbed employer-name
   form of the same label.

Neither difference was resolved here — resolving them means either restoring the missing section
into canonical or accepting its removal, which is a content decision, not a symlink mechanics
one. See `needs_orchestrator` in the P0-FR2 subagent report for the decision needed before
conversion can proceed safely.

## Acceptance check (PRD P0-FR2), run as specified

```
md5sum ~/.claude-acct/*/skills/unimatrix/SKILL.md | awk '{print $1}' | sort -u | wc -l
```

Result: **1** — passes, but only because the 7 account copies already agreed with each other
before this task ran; it does not check them against canonical and would still read "1" even
though none of them are symlinks and none match canonical. Extending the same check to the true
single-inode goal:

```
md5sum .claude/skills/unimatrix/SKILL.md ~/.claude/skills/unimatrix/SKILL.md \
       ~/.claude-acct/*/skills/unimatrix/SKILL.md \
  | awk '{print $1}' | sort -u | wc -l
```

Result: **2** — the real acceptance state. Not met. Do not treat the literal PRD one-liner alone
as proof of P0-FR2; it is silent on drift from canonical, only on drift between the copies.

## Rule

**Accounts symlink, never copy.** Once conversion happens, every account-side skill file must be
a symlink to the canonical repo file — never a hand-maintained copy. `unimatrix doctor`'s
skill-drift row is what enforces this going forward (planting a modified copy in one account
turns the drift table red per P1-FR5).

**Update (same day, post-verification):** the divergence above was confirmed to be pure staleness
(copies missing the newer spec-15 section + one scrub wording fix; nothing unique in any copy).
Conversion authorized and performed: all 8 paths are now symlinks to the canonical repo file.
Acceptance re-run: `md5sum` over all copies **plus the canonical file** = 1 unique hash; every
path passes `readlink -f` into the repo. `unimatrix doctor`'s skill-drift row now enforces this.
