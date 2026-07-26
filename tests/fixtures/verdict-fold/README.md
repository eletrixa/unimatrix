# Canonical verdict fold — the contract

Project: unimatrix · Module: `tests/fixtures/verdict-fold/` · Deps: none (data only)
Tested: `tests/verdict-fold.bats` (replays `ledger.jsonl` through both renderers)

`ledger.jsonl` + `expected.json` are **the contract** for "$ per verified-done". Two renderers fold
the speedwars ledger and must agree:

| renderer | language | entry point |
|---|---|---|
| `/speedwars` report | jq | `src/speedwars-report.sh --json <ledger>` |
| cockpit SPEEDWARS panel | JS | `canonicalFold(rows).lanes` in `site/cockpit/fold.js` |

They stay in two languages on purpose — the fixture, not a shared library, is what keeps them
honest. Any future divergence turns `tests/verdict-fold.bats` red.

---

## CANONICAL SEMANTICS

**Derived from** `specs/08-speedwars.md` FR-5 (line 49), FR-7 (line 51) and its Boundaries block
(lines 80-83); `specs/09-speedwars-panel.md` FR-7 (line 50) and the data contract (line 72);
`specs/12-failure-evidence.md` line 38 (judge ≠ executor — verdicts are orchestrator-written, so a
missing verdict means *nobody judged*, not *it was fine*).

1. **Unit.** A ledger row with no `type` is one **attempt**, not one card (a card retried after a
   false-done appends another row). A **card** is all attempts sharing `run + "/" + id`. Speed,
   tokens and cost are per attempt; **trust is per card**.

2. **Join key = `run + "/" + id`.** Never lane-scoped. Spec 08 FR-5 specifies verdict rows as
   `{run,id,verified,reason}` — there is no lane field in the schema, and the v0 rows in the live
   ledger have none. Spec 09 line 72: *"The join key between a card and its verdict is
   `run + "/" + id`; ids are only unique within a run."* A `lane`/`verify_lane` field on a verdict
   row (spec 10 FR-R9) names the **verifier**, not the executor, and is never part of the key.

3. **v0 lane-less verdict rows are honored,** identically to lane-carrying ones. They are the
   spec'd shape; dropping them silently un-refutes real false-dones.

4. **Precedence: the LAST verdict row for a key wins.** The ledger is append-only and corrections
   are appended, never edited (spec 08 FR-5 + Boundaries), so file order is chronological. Verdict
   rows are not required to carry `ts`, so ts cannot be the tie-break.

5. **A card's lane is the `served_lane` of its FINAL attempt** (latest `ts`; ties → the later row).
   A card retried onto another lane must not credit or blame the lane that gave up on it. Attempt-
   level counts (`attempts`, `cost_total`, medians) stay on the lane that actually ran the attempt.

6. **Judged vs unjudged.** A card is *judged* only if its standing verdict has a **boolean**
   `verified`. `verified: null` (gate inconclusive) is **not** a judgment — it counts as unjudged
   and is additionally reported as `inconclusive`. Spec 09 FR-7: *"a card with no verdict is
   'unjudged', never 'verified'"*.

7. **Per-lane card partition** (the four buckets sum to `cards`):
   - `verified_done` — judged, `verified === true`
   - `false_done` — judged, `verified === false` (**the** false-done definition: an explicit
     refutation. It does not additionally require `outcome == "done"` — a refuted claim is refuted)
   - `unjudged_done` — not judged, final attempt's `outcome == "done"` (a claim nobody checked)
   - `failed` — not judged, final attempt's `outcome != "done"`

8. **`cost_per_verified_done`.** Numerator = sum of `cost_usd` over **all** the lane's attempts
   (priced rows only) — including the ones that failed, per spec 08 FR-7's "split every average by
   verified-pass vs fail (SWE-Effi *expensive failures*)": spend that produced nothing verified
   still lands on somebody's line. Denominator = **`verified_done`** — verified-done cards, never
   done-claims, never attempts.

9. **Division by zero / absence is absence.** `verified_done == 0` or no priced attempt →
   `cost_per_verified_done: null`. A lane that emits no `cost_usd` at all (codex bills to a
   subscription) → `cost_total: null` with `cost_priced: 0` — **never `0`** (spec 09 FR-7).
   Renderers print their own placeholder (`-` in the report, `—` in the cockpit); `null` is the
   contract.

10. **Rounding.** `cost_total` and `cost_per_verified_done` are rounded to 6 dp so an IEEE754 sum
    (`0.30 + 0.05 + 0.20`) yields the same JSON literal in jq and JS. Medians never means
    (spec 08 FR-7) — the report's median/p95 columns are outside this contract.

11. **v0 string verdicts.** Some live ledger rows (agentbench-008/cal056 era) encode `verified` as
    the string `"pass"` or `"fail"` instead of a boolean, alongside `claimed`/`class`/`evidence`
    fields the fold ignores. These fold exactly like their boolean counterparts — case-exact, only
    those two spellings: string `"pass"` is a judgment of `true` (counts toward `verified_done`),
    string `"fail"` is a judgment of `false` (counts toward `false_done`). Any other non-boolean
    `verified` value, including `null` and any other string, stays a non-judgment per rule 6.

12. **Final-attempt tie-break when `ts` is missing.** Rule 5 picks the FINAL attempt by latest
    `ts`. An attempt with a missing/null `ts` always LOSES that comparison to any attempt that
    carries a `ts` — a ts-less attempt is never presumed "latest", regardless of file order. Among
    two or more ts-less attempts for the same card, the later row (file/input order) wins, same as
    any other tie. Zero rows in the live ledger lack `ts` (spec 08 FR-2 mandates it), but the fold
    must not silently invert lane credit if one ever does.

13. **Display consumers never re-filter raw rows.** A UI surface that shows per-card or per-attempt
    verdict state (a dot marker, a "refutation wall", any refuted/verified badge) must read the
    card's canonical `judged`/`verified` from `canonicalFold`'s `cardList` (or run a raw `verified`
    value through the exported `normVerdict` before comparing it) — never filter the ledger's raw
    `verdict` rows directly by `.verified === false`. A raw filter shows every historical row a key
    ever had, not the standing (last) one (rule 4), and silently misses v0 string encodings (rule 11).

---

## What each fixture row is for

| ledger case | pins |
|---|---|
| `r1/c1` verdict `true` then `false` | precedence — last row wins (rule 4); a false-done flip |
| `r1/c2` grok `retry` → glm `done`, **lane-less** verdict `false` | v0 row honored (3); card credited to the final lane, glm (5) |
| `r1/c3` verdict `verified: null` | inconclusive ≠ refuted; counts as unjudged (6) |
| `r1/c4` done, **no verdict** | `unjudged_done` — never `verified_done` (6) |
| `r1/c5` timeout, no verdict | `failed` |
| `r1/c6` verdict `true` | the only priced+verified card — makes `$/verified-done` a real number |
| `r2/c1` same id as `r1/c1`, verdict `true` | the join key includes `run` (2) |
| lane `grok` | zero verified but priced → `cost_per_verified_done: null` (9) |
| lane `codex` | no `cost_usd` anywhere → `cost_total: null`, not `0` (9) |
| `r1/c9` kimi attempt (ts) + gemini attempt (no ts) | final-attempt tie-break: the ts-carrying kimi attempt wins credit over the ts-less gemini one, regardless of file order (12) |
| `r1/c10` kimi, verdict string `"pass"` | v0 string encoding folds as `true` → `verified_done` (11) |
| `r1/c11` gemini, verdict string `"fail"` | v0 string encoding folds as `false` → `false_done`, an explicit refutation that must not silently un-refute (11) |
