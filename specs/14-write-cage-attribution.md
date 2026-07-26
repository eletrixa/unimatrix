# Spec 14 — Per-card write attribution, read-denial classification, and lane-limit fidelity

**Status:** Active (maintainer approved 2026-07-25, Robert — the approval covers FR-5/6/7 as well
as FR-1…4; originally drafted as round-4 triage of cockpit057b feedback)
**Date:** 2026-07-25
**Related specs:** 01 (spawn/finalize/enqueue; its own *Amendment 2026-07-25 — claim-lifecycle
guards* shares FR-6's claim-parse/freshness helper), 04 (conf keys — **amended** 2026-07-25 with
per-lane `TIMEOUT_<LANE>`), 10 (FR-R2 chain seed — **amended** by FR-3; FR-R8 `limit_error` lane
arms — **amended** by FR-4 and FR-6; FR-R11 write-diff gate — **amended** by FR-2, and by spec 10's
own 2026-07-25 gate-`find` alignment), 12 (failure-class vocabulary — **extended** by FR-1,
**reused** as FR-7's reason-token set; feedback stubs; **amended** 2026-07-25 with run-log
rotation), 13 (FR-3 `.broken` marker — **amended** by FR-4, FR-6 and FR-7)

---

## Overview

The cockpit057b run (24 write cards into `<target-repo>`, evidence in `.bus-cockpit057b`)
exposed three blind spots that share one root: the bus knows *that* a card failed but not *what
environment fact* caused it, and it attributes work at cage granularity rather than card
granularity.

- Three cards were **denied every `Read` they attempted** by the scratch-home permission cage and
  still finalized through the generic classifiers — the answer was "unusable", so the card walked
  its whole fallback chain re-hitting the identical cage on every rung. Nothing in the bus recorded
  that the fault was environmental, not model-side.
- The write-diff gate and the verify-wave diff section both operate on the **whole `.write`
  target**: any concurrently-running card's edit satisfies another card's gate, and the verify
  prompt shows a diff no single card authored.
- Two cards died on a `claude`-binary **session-limit envelope** that `limit_error` cannot see
  (`type:"result"`, `is_error:true`, `modelUsage:{}` — no `error`/`turn.failed` event anywhere in
  the run log). The lane stayed unflagged, so every following card queued straight back onto the
  exhausted lane, walked its chain to exhaustion, and parked with an empty `.chain-<id>` file that
  no operator verb clears.

Spec 14 closes all three: a `cage-denied` failure class that parks instead of walking, an optional
per-card deliverable manifest that scopes both diff consumers, chain-position hygiene at park, and
a `limit_error` fallback that sees the session-limit envelope.

**Scope extension, 2026-07-25 (backlog 51/52/54).** The next feedback batch — grpn-refactor runs
`atlas013`/`parity012`, grpn-gtm-studio run `refinery-01` — landed three more findings that share
the same root and therefore belong in the same spec rather than a new number: a card whose `.write`
target did not exist got its **lane** blamed and flagged `.broken` (FR-5); a lane was flagged
`.dead` while a sibling worker on that same lane was visibly still streaming (FR-6); and every
marker in `limits/` records only *that* something happened, never *why*, so recovery is guesswork
from adjacent stderr (FR-7). FR-7 is the enabler for the other two — a named class is worth nothing
if it never reaches the operator — so it lands first, then FR-5, then FR-5's zero-byte-log
companion.

## Goals

- Environment faults are named as such and cost **one** spawn, not one spawn per chain rung.
- A write card's evidence (gate + verify diff) covers **that card's** files, not its neighbours'.
- A parked card is recoverable through an operator verb, never through hand-`rm` of `limits/`.
- A lane that has genuinely run out of session capacity is flagged on the **first** card that
  proves it — no silent re-spend on a known-exhausted lane.
- **Card faults never masquerade as lane faults.** A bad write target, a missing directory, or a
  zero-byte run log is card-shaped evidence; only lane-shaped evidence may cool a lane.
- **Positive liveness evidence outranks a failure counter.** A lane with a provably-live worker on
  it is not dead, whatever the card that just died reported.
- **Every marker in `limits/` answers "why" in one line**, in a fixed format, with no answer text.

## Non-Goals

- **No `.read` sidecar** (backlog 48). No fleet CLI supports a read-only root, and the
  scratch-home `settings.json` deny-rule idea needs a live probe before it earns a spec.
- **No text-signature cage detection** — see FR-1's rationale; the structured field is available
  and the text alternative measured worse.
- **No removal of the whole-directory mtime gate** — the absent-manifest path (FR-2) keeps today's
  behavior byte-for-byte, and it stays the default.
- **No `Card-Id` commit trailers** (FR-2 rationale) — they depend on worker compliance, and the
  failure this spec targets *is* a non-compliant worker.
- No change to `answer_unusable`'s existing three classes, its ≤600-char text bound, or its rc
  contract.
- **No `mkdir -p` of a missing `.write` target** (FR-5 rationale) — the bus never manifests a
  directory a card merely names.
- **No per-*class* timeout mechanism** (backlog 49). The per-lane `TIMEOUT_<LANE>` keys added to
  spec 04 on the same date, plus FR-7's reason token on the timeout marker, cover the observed
  need; a card-class timeout ladder is a new mechanism for a problem config already solves.
- **No grok `Cancelled`+zero-tool-call false-done detector.** Proposed during backlog-53 triage and
  **cut at adversarial review**: it false-positives on legitimate zero-tool read cards, is redundant
  for write cards (the FR-R11 diff gate already rejects them), and would break spec 01 FR-12's
  timeout salvage. Backlog 53 is closed by FR-2 plus spec 10's gate-`find` alignment instead. Any
  revival must be scoped to non-salvage write paths only — see `specs/10-role-classes.md`
  §*Amendment 2026-07-25*.

## FR-1 — `cage-denied` failure class (backlog 44)

New swarm-lib helper beside `answer_unusable`:

```
cage_denials <busdir> <id>   # echoes a count; rc 0 always
```

One jq pass over `run-<id>.jsonl`'s **last** `type:"result"` event, counting
`permission_denials[]` entries whose `tool_name` matches `^(Read|Glob|Grep|NotebookRead)$`. An
absent `permission_denials` field is `0` — `codex`, `gemini` and `grok` silently no-op on a denied
tool and emit no such field, so those lanes are never gated by this FR (documented behavior, not a
gap to patch here).

**Bash denials are deliberately excluded from the count.** A write cage denies `Bash` **by
design**; 8 of the 21 healthy cockpit057b cards carry Bash-only denials and every one of them
produced good work by routing around the denial. Only the read-class tools indicate a cage that
cannot be worked around.

New failure class `cage-denied`, extending spec 12 FR-1's vocabulary:

| class | detected by | site |
|---|---|---|
| `cage-denied` | `cage_denials > CAGE_DENY_MAX` | swarm-run `_finalize_worker` gate block |

**Ordering.** The check runs **first** in `_finalize_worker`'s `extract_answer` success branch —
ahead of both the write-diff gate and `answer_unusable`. A read-denied worker typically also wrote
nothing and also produced an error-shaped answer, so leaving it to the existing gates classifies
the run as `false-done` or `api-error` and **chain-advances**, which is precisely the futile walk
this FR exists to stop.

**Config.** New key `CAGE_DENY_MAX` (default `0`), added to `conf_load`'s key array + defaults and
to `swarm.conf.example`. `CAGE_DENY_MAX` is a ceiling, not a toggle — a run that knowingly cages
out a few reads can raise it; setting it absurdly high is the opt-out.

**On trip:**

- **PARK** — regardless of pinned/unpinned. Never `chain_advance`: every chain rung shares the same
  cage, so the walk is guaranteed futile and every rung is metered spend.
  **Deviation from the literal text above (recorded 2026-07-25):** the park is performed by
  `_park_card "$id" "$lane" "$pinned" cage-denied` (`swarm-run.sh:219-224`), **not** by a bare
  `touch limits/<id>.parked`. A park is terminal for the gate and must therefore also be the
  branch's *last* speedwars row — `run_summary` keeps the last row per id (spec 12 FR-3), and
  `_park_card` is the one transition that guarantees it. A bare `touch` would leave the preceding
  attempt row as the branch's fate and make `parked_n` disagree with the bus, which is the exact
  defect `_park_card` was extracted to fix. FR-7 additionally gives the call a reason argument.
- Loud stderr naming the denied paths (deduped, from each denial's
  `tool_input.file_path // .path // .pattern`), capped at the first 5 plus `(+N more)`.
- Evidence marker `limits/<id>.cage-denied` — the count and the deduped denied paths, one per
  line. Paths and counts only; never answer text, prompt text, or stderr content (spec 12's
  scrub-by-construction doctrine).
- `speed_row … "parked" … "cage-denied"` — the parked row carries the class like every other
  non-done branch (spec 12 FR-1).
- `feedback_stubs` gains `cage-denied` to its detected-class list, from the durable
  `limits/*.cage-denied` glob (severity `major` — an env fault that voided real spend), with a body
  listing affected ids and denied paths.
- **Recorded at implementation (2026-07-25), two additions the list above omits:** the gate also
  (a) removes `res-<id>.txt` — every other rejection gate does, and `extract_answer codex` trusts
  any non-empty pre-existing res file, so a later `nudge` onto codex would inherit the cage's
  explanation as its own answer; and (b) writes a `ledger_failed_row … cage-denied` — the worker
  ran and billed before the cage stopped it (no-silent-spend, `rules/unimatrix/model-lanes.md`).
- **Amended at cross-review (2026-07-25):** the **timeout branch** runs the same check — a
  watchdog-killed card whose salvage failed is tested for `cage_denials > CAGE_DENY_MAX` before
  the timeout failover, else a cage-denied card that also hit the wall clock walks every rung
  anyway. And `limits/<id>.cage-denied` is cleared by `_archive_and_release` and
  `_reset_card_state` — a card that is nudged and then *succeeds* must not leave a stale marker
  for `feedback_stubs` to draft a major-severity stub from.

### Rationale: why not text-signature detection

The obvious cheap alternative — sniffing the answer for a denial phrase, the way `answer_unusable`
sniffs auth-death — was measured and rejected. `answer_unusable`'s text signatures are bounded to
answers ≤600 chars precisely because a long healthy answer legitimately quotes error strings
(live false positive, 2026-07-24). The cockpit057b cage-denied answers run to **2315 chars** —
they are articulate explanations of what the model could not read, sitting far outside that guard,
and widening the guard to reach them would re-open the false-positive class the guard exists to
close. The structured field needs no guard at all: counting read-class `permission_denials`
scored **3/3 precision** (a-api 10 read-denials, a-mon 11, a-llm 3) and **21/21 true negatives**
across the rest of the run, including every Bash-only-denial card.

## FR-2 — Per-card deliverable manifest (backlog 45)

Optional sidecar `queue/<id>.files`: newline-separated paths **relative to the card's `.write`
target**. Its lifecycle mirrors `.lane` / `.write` / `.chain` byte-for-byte — every site that
handles those three handles this one, in the same order:

- `_enqueue_pending_specs` moves `specs/<id>.files` → `queue/` **before** the prompt (sidecars
  first, prompt last — the pool only claims `*.prompt`).
- `swarm-ctl add` gains `--files <listfile>`, written in the existing sidecars-before-prompt block
  alongside `--lane` / `--write`.
- `_finalize_worker` archives it to `files-<id>.txt` beside `write-<id>.txt` on success (the
  verify wave needs it after `queue/` is cleared) and includes `queue/<id>.files` in the same `rm`
  list as the other sidecars.
- `nudge` keeps it (requeue semantics); `cancel` drops it — identical to `.write`.

**Trust boundary.** An entry that is absolute, or that escapes the write target once resolved with
`realpath -m`, is refused at publish time by `swarm-ctl add` (nonzero, loud) and ignored at consume
time with a loud stderr line. A manifest is a scoping aid, never a way to widen the cage.

**Two consumers:**

1. `_finalize_worker`'s write-diff gate (spec 10 FR-R11) runs its `find … -newermt` over the
   explicit list instead of the whole target, so a neighbouring card's concurrent edit can no
   longer satisfy this card's gate.
2. `_write_card_diff_section` enumerates the manifest instead of its `find` sweep and scopes
   `git diff <base_ref> -- <list>` to it, so the verify prompt shows only what this card was asked
   to produce.

**Absent sidecar = today's behavior, unchanged** — the whole-cage `find` sweep and the whole-cage
diff remain the default for every card without a manifest.

**Recorded at implementation (2026-07-25):** a manifest that is present but yields *no usable
entries* at the gate (empty file, or every entry refused by the trust boundary) makes the diff
gate **reject** — it never falls back to the whole-cage scan, which would silently restore the
exact blind spot the manifest exists to close. The verify-side diff section reads the archived
`files-<id>.txt` first and falls back to a still-live `queue/<id>.files`; a bad entry there is
loud-ignored per entry (a single bad line must not blank the whole card's evidence).

**Amended at cross-review (2026-07-25):** manifest entries are **regular files**, consistently at
all three surfaces — `swarm-ctl add --files` refuses an entry resolving to an existing directory
(and refuses a manifest with zero usable entries: it would publish a card guaranteed to
false-done on every lane), while the gate and the verify section loud-ignore directory entries at
consume time (the gate treated entries as `find` roots, so a directory entry passed recursively
on a neighbour's bytes — the verifier never saw it). Entries naming not-yet-existing paths stay
valid (a card may create its deliverable). Verify-side presence is `-f`, not `-s`: an **empty
archived manifest stays authoritative** (empty evidence section), never a fallback to the
whole-cage sweep the gate already refused.

### Rationale: why not `Card-Id` commit trailers

A trailer-based attribution scheme reads cleanly but depends on the worker writing the trailer.
The failure mode this FR addresses **is** a worker that does not do what the prompt says; an
attribution mechanism that a non-compliant worker can skip attributes nothing in exactly the case
that matters. The manifest is written by the orchestrator before the worker exists.

## FR-3 — Chain-position reset at park (backlog 46, amends spec 10 FR-R2)

`chain_reset "$BUSDIR" "$id"` is called immediately after **every** park-touch in
`_try_claim_one`'s chain-exhausted branch. This is **behavior-neutral in-run**: `limits/<id>.parked`
remains the terminal gate, checked at the top of the claim loop before any chain resolution. What
it fixes is the *afterlife* — today a parked card leaves a zero-byte `limits/.chain-<id>` behind
(three of them survive in `.bus-cockpit057b`: `.chain-a-asm`, `.chain-a-llm2`,
`.chain-a-port-lenses`), so any later re-publish of that id resolves to an already-exhausted walk
and parks again on the first poll.

`swarm-ctl add` clears the same per-id state for the id it publishes:
`limits/<id>.parked`, `limits/.chain-<id>`, `limits/.retries-<id>` — the wipe `cmd_nudge` step (e)
already performs. Extract that wipe into one shared `_reset_card_state <busdir> <id>` with the two
callers rather than duplicating the list (nudge additionally clears `.timedout` / `.frozen`, which
`add` cannot have by construction — it refuses an id already present in `queue/`; keeping them in
the shared helper is harmless and keeps one list).

**Amended at cross-review (2026-07-25):** the shared list also clears `limits/<id>.waiting`,
`limits/<id>.waiting-write` (FR-5 — a stale wait marker ages the next publish's bounded wait
against the OLD mtime and insta-parks it, reproduced) and `limits/<id>.cage-denied` (FR-1). And
**`cmd_cancel` calls `_reset_card_state` too**: a cancelled parked card otherwise leaves a
phantom `.parked` that inflates `parked_n` while the id leaves `live_n` — one phantom lets the
pool gate (`done_n + parked_n >= live_n`) close EARLY and abandon still-pending work.

The `unimatrix` skill's troubleshooting rows (`rm limits/*.parked`, `rm .chain-*` + relaunch) are
rewritten to point at `swarm-ctl nudge <id>` — a manual `rm` under `limits/` stops being the
documented recovery.

**Explicit constraint.** `_chain_tokens`' guard must stay `[[ -f "$cf" ]]` and must **never**
become `[[ -s "$cf" ]]`. An exhausted walk is represented by an *empty* `.chain-<id>` file; under
`-s` that file would read as absent, the resolver would fall through to `queue/<id>.chain` or
`$EXEC_CHAIN`, and the card would walk its chain forever. A bats regression guard pins this.

## FR-4 — Session-limit 429 visibility (backlog 47, amends spec 10 FR-R8 + spec 13 FR-3)

A `claude`-binary session limit does not arrive as an `error` or `turn.failed` event. It arrives as
an ordinary result envelope (verbatim, `.bus-cockpit057b/run-a-asm.jsonl`, also
`run-a-llm2.jsonl`):

```json
{"type":"result","subtype":"success","is_error":true,"result":"You've hit your session limit · resets 2:50am (Europe/Prague)","modelUsage":{}}
```

`limit_error`'s extraction (`select(.type == "error" or .type == "turn.failed") | last`) finds
nothing, so it returns rc 0 — "no limit signal". The card is still rejected downstream
(`answer_unusable` sees `is_error:true` and echoes `api-error`), but **the lane is never flagged**:
the next card queues straight back onto the exhausted lane, and the run burns its way through
every chain rung, card by card.

Changes, all inside `limit_error`'s existing no-hit fallback:

- The `claude | gemini` no-hit result-text arm extends from **auth-death-only** to
  **auth-death, then rate-limit**: after `_auth_death_signature` misses, the same `last_text` is
  tested against the rate-limit signature and, on a hit with `is_error == true`, flips
  `limit_flag` and returns rc 1.
- **The rate-limit regex must be extended, not merely reused.** The `claude` envelope arm's
  current pattern (`usage limit|rate.?limit|too many requests|(^|[^0-9])429([^0-9]|$)`) does **not**
  match `"You've hit your session limit"` — no substring of the observed envelope hits any
  alternative. Extract that pattern into one shared `_rate_limit_signature <text>` helper (mirroring
  `_auth_death_signature`), **add `session limit`** to it, and use the one helper from both the
  envelope arm and this fallback. One list, two callers — a future signature lands in one place.
- The fallback `case` arm extends from `claude | gemini` to `claude | gemini | glm | kimi`: GLM and
  Kimi are the same `claude` binary under a child-env swap and emit the identical envelope.
- **TTL** is parsed from the reset clause `resets <h:mm><am|pm> (<TZ>)` — precedent: the glm arm's
  `next_flush_time` handling. Resolve via `date -d "TZ=\"<TZ>\" <h:mm><am|pm>"`; if the result is
  in the past, add a day. Fallback `18000` when the clause is absent, unparseable, or yields a
  nonpositive TTL (same nonpositive guard the glm arm already applies).
- **Single strike** — no `.strikes` counter. `is_error:true` **plus** the literal session-limit text
  is unambiguous (contrast the codex/kimi rate arms, whose 2-strike rule exists because a bare rate
  message can be transient). The triggering envelope is written to
  `limits/<lane>.limited.evidence`, matching the glm/kimi precedent.

**Interplay — FR-3 and FR-4 ship together or not at all.** Spec 13 FR-3's `.broken` marker becomes
the *second* line of defense here (a lane that runs but serves nothing still gets marked); FR-4 is
the *first*, catching the case where the lane answers coherently that it is out of capacity. And
FR-3's `chain_reset` is what makes the blocked-lane walk **recoverable**: without it, the cards
that a limited lane pushed to chain exhaustion stay unrecoverable-by-verb even after the lane's TTL
expires. Landing FR-4 alone converts a visible-but-expensive failure into a fast park that no
operator verb can undo.

## FR-5 — Write-target existence check (backlog 51)

A `.write` card naming a directory that does not exist spawns a worker that cannot possibly
succeed, and then blames the wrong thing for it. `env -C <missing>` exits **125 before the CLI
emits a byte**, so `tee` leaves a **zero-byte** `run-<id>.jsonl`; the retries-exhausted arm at
`swarm-run.sh:770-774` sees a run log that *exists* (`[[ -f ]]`) with an empty `served_model`,
concludes `lane-down`, and calls `broken_flag` — every later card is now routed away from a lane
that was never actually asked to run. The fault is card-shaped; the flag it sets is lane-shaped.

**Claim-time check with a bounded wait.** The check lives in `_try_claim_one`'s existing `.write`
refusal block (`swarm-run.sh:246-259`), reusing that block's `realpath -m` canonicalization and its
`_park_card` idiom, and runs ahead of pinned/chain resolution for the same reason the `.claude/`
refusal does: the refusal is a property of the target, not of the lane that would have served it.

A missing target does **not** park on sight. It reuses the FR-R6 bounded-wait *pattern* already in
this function (marker + `PIN_WAIT_SEC`, `swarm-run.sh:268-287`): the target is
re-checked on **every poll**, and the card parks with class `write-target-missing` only when the
wait expires. Instant park would permanently kill the wave-1-creates-the-directory /
wave-2-writes-into-it card dependency that limps through today — a shape that currently works by
accident and must keep working. The bounded wait keeps it while still failing loudly rather than
spending a spawn. One stderr notice at marker creation, then silent re-polls, exactly as FR-R6
does. A target that appears mid-wait clears the marker and the card claims normally.

**Amended at cross-review (2026-07-25, CRITICAL):** the FR-5 wait marker is
**`limits/<id>.waiting-write`**, a *distinct* file — the first cut shared FR-R6's
`limits/<id>.waiting`, and the target-exists `rm` then reset the pinned-lane wait's timer on
every poll: a pinned write card on a blocked lane never accumulated wait time, never parked, and
hung the pool gate forever (reproduced). Same pattern, separate clocks. Both markers are cleared
by `_archive_and_release`, the finalize cleanup, and `_reset_card_state` (a stale wait marker
otherwise insta-parks the next re-publish of the id against its old mtime).

**Publish-time check.** `swarm-ctl add --write <dir>` (`src/swarm-ctl:206-208`) **hard refuses** a
nonexistent target: rc 1, loud message, nothing written — the sidecar never reaches `queue/`. This
is the single reporting surface for the typo case; the claim-time wait exists for the legitimate
not-yet-created case, which by construction cannot be published through `add`.

**Never `mkdir`.** Not at publish time, not at claim time. A typo'd target that the bus itself
manifests becomes a real, empty directory — and the FR-R11 diff gate then happily "passes" against
whatever lands in it, converting a loud card fault into a silent wrong-directory success. Refusal
and bounded wait are the only two behaviors.

**Companion — a zero-byte run log is never lane evidence.** The `[[ -f "$BUSDIR/run-$id.jsonl" ]]`
test at `swarm-run.sh:771` becomes `[[ -s … ]]`, **grouped with** `|| (( wrc == 126 || wrc == 127 ))`
so the rest of the conjunction still applies. The `-s` alone would be wrong: a missing or
non-executable lane binary also dies with zero stdout, and that genuinely **is** a lane fault
deserving `.broken`; without the 126/127 arm it would degrade into per-card retry churn against a
binary that will never run. Every other zero-byte log is a card fault and must leave the lane
untouched.

**Class token:** `write-target-missing` (FR-7's vocabulary; also a spec 12 FR-1 class, since it is
passed through `_park_card` to `speed_row`).

**Ordering.** FR-7 lands first (FR-5 needs the named class to be readable), then FR-5, then the
`-s` change — FR-5 removes the dominant *legitimate* producer of zero-byte run logs, so tightening
the test after it is a narrowing, not a behavior gamble.

## FR-6 — Sibling-liveness guard on lane-level flags (backlog 54)

A single card's death currently condemns its whole lane. In `refinery-01` a card died on an
auth-blip envelope and `limit_error` flagged `<lane>.dead` while **another worker on that same
lane was still streaming** — the surviving sibling proved the lane was fine, and nothing consulted
it. Every card queued afterwards routed around a working lane until that sibling happened to
finalize.

New swarm-lib helper beside `lane_blocked` (`src/swarm-lib.sh:426-438`):

```
lane_has_live_worker <busdir> <lane>   # rc 0 = lane provably alive
```

rc 0 iff **some other** claimed card on that lane has a `run-<id>.jsonl` whose mtime is fresher
than `LEASE_MIN` (minutes — the same units `reap` takes). Three details are load-bearing:

- **Lane match keys on the claim filename's lane token** (`claimed/<id>.<lane>:<model>`), parsed
  with the anchored suffix regex `reap` (`swarm-lib.sh:314`) and `_claim_of` (`:339`) already
  share. `glm` and `kimi` are both the `claude` binary under a child-env swap — the filename token
  is the *only* thing that distinguishes those three lanes, and a live glm worker says nothing
  about kimi's credentials.
- **Freshness threshold is `LEASE_MIN`**, the same clock `reap` uses. "Provably alive" then means
  exactly "not reapable" — one definition of liveness on the bus, not two that can disagree.
- **Excludes the dying card itself.** A card is not evidence of its own lane's health.

**Call sites** — before every `dead_flag` in `limit_error` (`src/swarm-lib.sh:981`, `1093`, `1118`)
and before the retries-exhausted `broken_flag` (`swarm-run.sh:774`). Each `dead_flag` site is
preceded one line earlier by its `limits/<lane>.dead.evidence` write; the guard must divert **both**
— a `.dead.evidence` file with no `.dead` flag reads to an operator as an auth death that someone
hand-cleared.

**On a hit the flag is downgraded, not skipped.** The card still failed and that still deserves a
record. Skipping outright would lose the signal; a full-length flag would punish a lane
the bus can see working. Envoy's outlier-detection doctrine, in one line: positive liveness
evidence overrides a failure counter.

**Amended at cross-review (2026-07-25, MAJOR — downgrade marker is `.broken`, not `.limited`):**
the first cut downgraded to a short-TTL `.limited`, but `.limited` is cleared by **nothing** in
the tree except its TTL — while `.broken` (and `.dead`) are cleared by the lane's next successful
finalize (`_archive_and_release`). The guard's precondition is *a live sibling on the lane*, i.e.
a successful finalize is imminent and would clear `.broken` within seconds — so the `.limited`
form cooled a working lane for the full window, the exact harm backlog 54 was filed about. The
downgrade therefore writes **`broken_flag <lane> 600` with the reason token the site would have
used** (`auth-death` at the `limit_error` sites, `lane-down` at the retries-exhausted site) and
the triggering envelope goes to `limits/<lane>.broken.evidence` — never `.dead.evidence`.
Class/fbreason fidelity: the failover classifier keys `auth-death` on `lane_dead` **or** the
`auth-death` token greppable in `limits/<lane>.broken`, so a downgraded credential death is never
recorded as a rate limit, and `feedback_stubs`' `lane-down` glob (`limits/*.broken`) still drafts
its stub.

The downgrade **self-corrects against a genuine revocation**: with real siblings live, a truly dead
lane costs one failed spawn per short TTL window until the siblings drain; once none are live the
guard stops firing and `.dead` sticks with its normal semantics.

**Scope note — refinement, not hole-plug.** `_archive_and_release` (`swarm-run.sh:506-508`) already
clears `.dead`/`.broken` when any card on the lane finalizes successfully. FR-6 narrows the
**mid-flight** window between one card's death and the next card's finalize; it does not introduce
the recovery, it shortens the outage.

**Shared primitive (binding).** FR-6 and spec 01's *Amendment 2026-07-25* FR-A reap guard both need
(a) claim-filename → `<id>`/`<lane>` parsing and (b) run-log freshness. **Exactly one** helper
beside `_claim_of` provides both, and both features call it. A third copy of the anchored
lane-suffix regex is how `_claim_of`'s "keep both in lockstep" comment becomes a lie.

## FR-7 — Reason lines on every marker (backlog 52)

Every marker under `limits/` records *that* something happened and nothing about *why*. Recovery is
archaeology: correlate the marker's mtime against `run-*.jsonl.stderr` and guess. One line per
marker closes it.

**Format — one line, always:**

```
<ISO8601> | <reason-token> | retryable=<0|1> | ttl=<sec> | <text>
```

Written by one shared helper, `_marker_line <reason-token> <retryable> <ttl> <text>` (swarm-lib),
used by **every** writer: `_park_card` (`swarm-run.sh:219-224`), `limit_flag`
(`swarm-lib.sh:366-371`), `dead_flag` (`:385-392`), `broken_flag` (`:402-411`). One producer, so
the format cannot drift between the driver and the library.

### Backward compatibility — the marker content *is* the TTL today

This is the part that regresses silently if it is got wrong. `limits/<lane>.limited` and
`limits/<lane>.broken` currently contain **nothing but the TTL in seconds**, and three separate
parsers read it that way:

| parser | site | default when unparseable |
|---|---|---|
| `limit_active` | `src/swarm-lib.sh:373-383` | `18000` |
| `lane_broken` | `src/swarm-lib.sh:413-424` | `1800` |
| cockpit TTL countdown | `site/server.mjs:900-912` (`Number(...)`, `Number.isFinite` fallback) | `18000` |
| lane-health preflight `_flag_mins_left` | `swarm-run.sh:132-144` (found at implementation — a raw `$(<file)` read feeding arithmetic, which **crashes** on a reason line under errexit rather than failing quietly) | caller's per-flag default (`18000`/`1800`) |

All four gain the **same** parse rule — implemented once as `_marker_ttl <file> <default>`
(swarm-lib), which the three bash readers call and `site/server.mjs`'s `parseMarkerTtl` mirrors in
lockstep — in this order:

1. content is **all digits** → legacy TTL (an in-flight bus written by the previous build);
2. otherwise the value of the line's `ttl=<sec>` field;
3. otherwise the reader's own baked default (above).

The cockpit parser is easy to miss — it is not in the bash tree and it fails *quietly*, showing
every new-format lane a flat 5-hour countdown instead of erroring. It is in scope for this FR.

**`.dead` stays existence-only.** `dead_flag` writes a reason line, but `lane_dead`
(`swarm-lib.sh:394-400`) must **not** learn to parse it — an auth death does not self-heal on a
clock (that is the whole reason it has no TTL), and giving it one via the back door would let a
revoked credential silently come back into rotation. `.dead` reason lines carry `ttl=0`,
`retryable=0`.

`.parked` has no existing content contract — every consumer keys on the filename
(`swarm-mon.sh:91-94`, `site/server.mjs:268`, `swarm-loop.sh:534`, `feedback_stubs`
`swarm-lib.sh:2186/2234`) except the watchdog bus-state printout (`_watchdog_bus_state`,
`src/swarm-ctl:598-606` — there is no literal `swarm-ctl state` verb; corrected at
implementation), which already prints non-empty `.parked` content into the parked: section of
`loop/handoff-prompt.md`. The reader for FR-7 therefore already exists; it needs no change.

### Reason tokens — reuse the taxonomy, never mint a second one

The token set is spec 12 FR-1's failure-class vocabulary (`auth-death`, `api-error`,
`server-error`, `rate-limit`, `timeout-watchdog`, `spawn-fail`, `false-done`, `no-answer`,
`lane-down`, `parked-env`), which this spec already extends with `cage-denied` (FR-1) and
`write-target-missing` (FR-5), plus **three marker-only tokens** — sites that describe a marker but
carry no distinct speedwars class:

| token | written at |
|---|---|
| `chain-exhausted` | `swarm-run.sh:332-344` — the exec chain ran out of lanes |
| `pinned-lane-blocked` | `swarm-run.sh:268-287` — a hard `.lane` pin still blocked after `PIN_WAIT_SEC` |
| `session-limit` | FR-4's `limit_error` fallback, on the session-limit envelope |

No token outside this set is ever written. A new failure shape extends spec 12 FR-1's table first,
and inherits a token from it.

**Lane-flag writers take a token with a per-writer default**, so the ~15 existing `limit_flag` call
sites need no edit: `limit_flag` defaults to `rate-limit`, `dead_flag` to `auth-death`,
`broken_flag` to `lane-down` — exactly the mapping spec 12 FR-1 already assigns to those sites.
Only the sites with something sharper to say pass a token explicitly: FR-4's session-limit
envelope (`session-limit`) and FR-6's downgrade path (the class that *would* have been flagged).
Widening those three signatures is not licence to revisit their call sites.

### `_park_card` gains a reason argument, not a new class

`_park_card <id> <lane> <pinned> [class] [reason-token]` — the **fifth** positional. Its default is
the `class` argument, so a call site with nothing sharper to say is unchanged in behavior.

**This is deliberately not a change to the `class` argument.** Three of the seven call sites
(`swarm-run.sh:256`, `:284`, `:343`) currently pass no class and fall through to `parked-env`, and
spec 12 FR-1 documents `parked-env` as the class for exactly those blocked-pin/park paths — with a
bats guard pinning it (`tests/swarm-run.bats:1770`). Sharpening the *marker* must not change the
*speedwars class* those rows carry. The reason argument gives the marker its sharper token while
`speed_row` output stays byte-identical:

| call site | class (unchanged) | reason token |
|---|---|---|
| `:256` `.claude/` surface refusal | `parked-env` | `parked-env` |
| `:284` pinned lane blocked past `PIN_WAIT_SEC` | `parked-env` | `pinned-lane-blocked` |
| `:343` chain exhausted | `parked-env` | `chain-exhausted` |
| `:657` timeout, pinned | `timeout-watchdog` | `timeout-watchdog` |
| `:666` `lane_cmd` refused, pinned | `spawn-fail` | `spawn-fail` |
| `:787` mid-flight limit/dead, pinned | `$class` | `$class` |
| `:802` retries exhausted, pinned | `$class` | `$class` |
| FR-1 cage-denied park | `cage-denied` | `cage-denied` |
| FR-5 missing write target | `write-target-missing` | `write-target-missing` |

Each site already holds its reason in a local — `wreason` at `:284`, the refused `wtarget` at
`:256`, `orig_bare` at `:343` — so the free text costs no new plumbing.

### `retryable` and `ttl`

`retryable=1` means a TTL expiry or an operator verb (`swarm-ctl nudge <id>`) can plausibly make
this work again with nothing outside the bus changing: `rate-limit`, `session-limit`,
`timeout-watchdog`, `chain-exhausted`, `pinned-lane-blocked`, `api-error`, `server-error`,
`no-answer`, `false-done`. `retryable=0` means something outside the bus must be fixed first:
`auth-death`, `spawn-fail`, `cage-denied`, `write-target-missing`, `parked-env`, `lane-down`.
`ttl=<sec>` carries the marker's own TTL, `0` where the marker has none (`.parked`, `.dead`).

**One deliberate exception (recorded at implementation):** the FR-6 downgrade marker — a
short-TTL `.limited` whose reason token is `auth-death` — carries `retryable=1`, not the token's
table value. A `.limited` marker is TTL'd by construction, and the downgrade only fires because a
sibling worker is *provably serving that lane right now*; deriving `retryable` from the token
would make that one marker assert the opposite of what FR-6 just proved. The field belongs to the
marker's situation, not the token: `limit_flag` always writes `retryable=1`.

### PII rule

The free text carries **repo-relative paths, ids, lane names, counts and tokens only** — never
answer text, prompt text, or stderr content. These lines get quoted into feedback stubs, postmortem
output and succession handoff prompts, all of which are tracked files in a public repo; spec 12's
scrub-by-construction doctrine applies unchanged, and `check.sh`'s PII gate is the guard. One line
always: a multi-line marker breaks both the legacy-digit parse and every `$(<file)` reader.

**Out of scope:** `limits/takeover.parked` (`src/swarm-ctl:797/808/826`) is spec 11's succession
seat marker, not a card park — it is not written by `_park_card` and this FR does not touch it.

## Acceptance criteria

1. **FR-1** — `cage_denials` returns `10` for a fixture run log carrying the a-api denial array,
   `0` for a Bash-only-denial log, and `0` for a log with no `permission_denials` field. A fixture
   card whose last result event carries ≥1 read-class denial finalizes to `limits/<id>.parked` +
   `limits/<id>.cage-denied`, emits a `parked` speedwars row with `class:"cage-denied"`, never
   calls `chain_advance` (asserted: `limits/.chain-<id>` unchanged), and logs the denied paths to
   stderr. With `CAGE_DENY_MAX=20` the same fixture finalizes through the existing gates unchanged.
   A canary planted in `res-<id>.txt` appears in neither the marker nor the feedback stub.
2. **FR-2** — With `queue/<id>.files` listing `a.ts`, a fixture where only `b.ts` changed under the
   write target is **rejected** by the diff gate (today it passes); with `a.ts` changed it passes.
   `_write_card_diff_section` output for the same card contains `a.ts`'s diff and not `b.ts`'s.
   Deleting the sidecar restores byte-identical whole-cage behavior in both consumers.
   `swarm-ctl add --files` publishes the sidecar before the prompt (asserted by mtime ordering) and
   refuses a manifest containing `/etc/passwd` or `../escape.ts` with nonzero rc.
3. **FR-3** — After a chain-exhausted park, `limits/.chain-<id>` does not exist (today: a zero-byte
   file remains); the run's rc via `_check_parked` is unchanged. `swarm-ctl add` on a previously
   parked id clears `.parked` / `.chain-<id>` / `.retries-<id>` and the card is claimed on the next
   poll. Regression guard: with `limits/.chain-<id>` present and **empty**, `chain_current` echoes
   empty (not the `EXEC_CHAIN` head) — the `[[ -f ]]` → `[[ -s ]]` mutation fails this case.
4. **FR-4** — A fixture `run-<id>.jsonl` containing only the verbatim session-limit result line
   (below) makes `limit_error` return rc 1 for lanes `claude`, `glm` and `kimi`, writes
   `limits/<lane>.limited` with a TTL derived from `2:50am (Europe/Prague)` (bounded assertion:
   `0 < ttl <= 86400`), writes `limits/<lane>.limited.evidence`, and requires **no** second strike
   (`limits/<lane>.strikes` is never created). The same envelope with the reset clause stripped
   yields TTL `18000`. An unrelated `is_error:true` result with no rate-limit signature still
   returns rc 0. Existing `_auth_death_signature` fallback cases for `claude`/`gemini` stay green.
5. **Pairing constraint** — FR-3 and FR-4 land in the same change. A combined bats case: a limited
   lane flagged via FR-4 pushes a card to chain exhaustion and park; after the marker is cleared,
   `swarm-ctl add` re-publishes the id and it is claimed on the seed chain's head (not on the
   exhausted walk). This case fails if either FR ships alone.
6. **Regression fixtures** — Both fixtures are inlined in the bats files as heredocs from the real
   envelopes below, **not** read from `.bus-cockpit057b` (the bus tree is gitignored):

   ```json
   {"type":"result","subtype":"success","is_error":true,"result":"You've hit your session limit · resets 2:50am (Europe/Prague)","modelUsage":{}}
   ```

   ```json
   {"type":"result","subtype":"success","is_error":false,"permission_denials":[{"tool_name":"Read","tool_use_id":"toolu_018UWfSK5fYukadEDY6x2aXu","tool_input":{"file_path":"<target-repo>/apps/brain-api/src/cockpit/contract.ts"}},{"tool_name":"Bash","tool_use_id":"toolu_011aErW9MfVNg2mAP8heiLtf","tool_input":{"command":"grep -r \"MartCockpitBetWideRowSchema\" <target-repo>/packages/shared","description":"Search shared package"}}]}
   ```

   The second fixture is deliberately mixed (one read-class, one Bash) — it must count `1`, proving
   the Bash exclusion.
7. **FR-5** — A card whose `.write` sidecar names a nonexistent directory is **not** spawned: the
   fake CLI is never invoked. It waits — `limits/<id>.waiting` exists, no `.parked` — and with the
   marker's mtime aged past `PIN_WAIT_SEC` it parks with `limits/<id>.parked` and a
   `write-target-missing` reason token; the same fixture with the target **created mid-wait** clears
   `limits/<id>.waiting` and claims and runs normally. `swarm-ctl add --write <nonexistent>` exits
   nonzero and leaves no `queue/<id>.write` and no `queue/<id>.prompt`. Neither path ever creates
   the target directory (asserted: it still does not exist after the park).
   Companion: a card finishing its last attempt with a **zero-byte** `run-<id>.jsonl` does **not**
   produce `limits/<lane>.broken`; the same fixture with `wrc` 126 and with `wrc` 127 **does**.
   Existing fixtures all emit bytes and cannot catch this — the zero-byte case is a new bats case,
   not a mutation of an old one.
8. **FR-6** — Truth table for `lane_has_live_worker`: another claimed card on the lane with a
   run-log mtime inside `LEASE_MIN` → rc 0; same claim with the run-log mtime aged past `LEASE_MIN`
   → rc 1; no other claim on the lane → rc 1; a claim on a *different* lane with a fresh run log →
   rc 1 (asserted specifically for `glm` vs `kimi` vs `claude`, which share a binary); only the
   dying card's own claim present → rc 1.
   End to end: an auth-death envelope processed by `limit_error` while a sibling on the lane is live
   writes `limits/<lane>.limited` with a TTL in `[300,600]` plus `limits/<lane>.limited.evidence`,
   and creates **neither** `limits/<lane>.dead` **nor** `limits/<lane>.dead.evidence`; with no live
   sibling the same envelope produces today's `.dead` + `.dead.evidence` unchanged. The
   retries-exhausted path at `swarm-run.sh:774` likewise writes no `.broken` while a sibling is
   live.
9. **FR-7** — Every marker written by a fixture run (`.parked`, `.limited`, `.broken`, `.dead`)
   matches `^[0-9]{4}-[0-9]{2}-[0-9]{2}T[^ ]* \| [a-z-]+ \| retryable=[01] \| ttl=[0-9]+ \| .*$`,
   and its reason token is a member of FR-7's fixed set (asserted against an inlined list, so a
   newly minted token fails the test).
   Compatibility: a new-format `limits/<lane>.limited` still satisfies `limit_active`'s TTL math
   (fresh → rc 0; aged past its `ttl=` → rc 1), and the same for `lane_broken`; a **legacy**
   bare-digits `.limited`/`.broken` still parses (rc identical to the pre-change build);
   `lane_dead` is unchanged by a `.dead` file that now has content. The watchdog bus-state
   printout (`_watchdog_bus_state` → `loop/handoff-prompt.md` parked: section) renders each
   `.parked` reason line, and the lane-health preflight (`_flag_mins_left`) renders a new-format
   marker's remaining minutes without crashing. `speed_row`'s `class` output is byte-identical to the pre-change build for
   all three `parked-env` call sites (`swarm-run.sh:256/284/343`) — the existing
   `tests/swarm-run.bats:1770` guard passes unmodified. A canary planted in `res-<id>.txt` appears
   in no marker.
10. `check.sh` green (shellcheck, full bats, PII gate).

## Open questions

- **`CAGE_DENY_MAX` default.** `0` (any read-class denial parks) is the conservative reading of the
  evidence — all 3 cockpit057b hits were total read lockouts, not partial. If a live run surfaces a
  card that is denied one incidental read and still delivers, the default becomes a small positive
  integer rather than a new mechanism. [NEEDS CLARIFICATION at first counter-example, not before.]
- **Manifest authorship.** FR-2 defines the sidecar and its consumers; whether the orchestrator
  writes it for every write card by default, or only where cards share a target, is a skill-level
  policy question deferred to the `unimatrix` skill's lane-assignment step.

---

## Amendment — 2026-07-26 (per-card write-journal for shared cages)

The 2026-07-25 shared-cage findings ratify the following:
- **Blind spot:** the per-card diff gate checks "did the cage change since spawn" — in a SHARED cage, sibling cards' writes satisfy the check for a card that wrote NOTHING. Confirmed false-dones through this exact hole: W3D1 (claude:haiku, full before/after edit report, zero bytes written — backlog 49/reviews 2026-07-25) and 5 grok narration false-dones in one evening (backlog 59, MAJOR).
- **FR-8 (new):** the engine records a per-card write-journal — the set of paths THIS card's worker actually wrote (from the worker stream's Write/Edit tool records, which the engine already archives as `run-<id>.jsonl`) — and the diff gate for a shared cage MUST require this card's OWN journal to be non-empty and its paths to show real change, sibling writes no longer sufficing. Journal replay must respect subsequent rm/mv records in the same stream (the 2026-07-25 salvage-doctrine lesson: Write records alone resurrect deliberately-deleted files). *(Shipped 2026-07-26: `_write_journal` in `src/swarm-lib.sh` (post-hoc jq over the archived stream; claude-binary lanes only — grok/codex/gemini streams carry no tool_use records, so those keep the whole-cage sweep), journal arm + `_cage_is_shared` in `_write_target_changed`. Sharing counts live `queue/*.write` sidecars AND finished siblings' `write-*.txt` archives — a fast writer finalizing before the narrator would otherwise re-open the exact W3D1 window. rm/mv awareness at the gate: a journal path that no longer exists on disk contributes no change evidence.)*
- **Out of scope:** no change to single-card cages (current gate remains sufficient); no filesystem watchers or daemons — the journal derives from the already-captured stream, post-hoc at finalize.
- **Acceptance:** bats — two cards share a cage, card A writes a file, card B writes nothing but narrates: gate passes A, fails B with the W3D1 signature named in the failure reason.
