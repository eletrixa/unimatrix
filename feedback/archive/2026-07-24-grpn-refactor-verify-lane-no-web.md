---
source: refactor
date: 2026-07-24
run: grpnrev (.bus-grpnrev, verify wave over 6 gemini research cards)
type: design-gap
severity: medium
triaged-to: backlog#37
---

# Verify lane for web-research cards has no web access — citation checks are impossible by construction

**What happened:** `swarm-run.sh verify` mapped gemini→claude (VERIFY_MAP) and all 6 verify
workers reported the same limitation up front: `WebSearch`/`WebFetch`/`curl` denied inside the
caged `claude -p` worker. Verification degraded to internal-consistency + parametric-knowledge
audit. It still caught 5 real errors (wrong BP endpoint, inflated schema.org type list, FTC §
off-by-one, WCAG mislabel, bare-domain-root citations) — but the cards' PRIMARY contract
("every claim carries a source URL") is unverifiable: no verifier could fetch a single cited URL.

**Expected:** research-class verify cards need a web-capable judge. Options:
1. Verify research cards on the gemini lane itself with judge≠executor enforced via a different
   model pin (e.g. executor gemini-3-flash, verifier gemini-3-pro) — same lane, different brain.
2. A `VERIFY_TOOLS=web` mode that relaxes the cage for read-only web (still env -i, still no repo
   mounts, GEMINI_SANDBOX-style container preferred).
3. At minimum: docs note in model-lanes.md that gemini→claude verify is knowledge-only, so
   operators treat citation integrity as UNCHECKED and gate on it separately.

**Also observed (worth one line in docs, not a bug):** gemini lane produced bare-domain-root
citations on 1 of 6 cards (g6) — the post-hoc-citation signature. A card-prompt rule
("citations must be deep links; bare domains = failed card") would make this self-policing.

**Evidence:** `.bus-grpnrev/res-v-g*.txt` (all 6 open with the
no-web-access disclaimer); run label grpnrev, 2026-07-24.
