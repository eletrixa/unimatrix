---
description: Run a swarm in the thrifty profile — fable orchestrates only; codex plans + reviews; glm/grok execute
argument-hint: "<task description>" [--run <label>]
---

# /u:thrifty

**Deprecated** (spec 17 FR-8 naming convention): the bare `/u-thrifty` alias is deprecated in
favor of `/u:thrifty`; this body stays canonical here.

## Role + goal

Run `$ARGUMENTS` through the thrifty swarm profile.

You (fable) are the orchestrator ONLY for this run.
Codex plans and reviews; glm/grok execute.
Never author plans or card bodies during the normal path.
Validate artifacts, enforce gates, route work, and adjudicate outcomes.
Use the terminal fallbacks below only when their stated conditions are met.

Keep Anthropic spend below 10% of priced ledger cost.
The measurement is the `anthropic share:` footer in
`unimatrix report --run <label>`, which is authoritative.

Resolve `<label>` from `--run <label>`; otherwise choose a short unique label.
Treat the remaining arguments as the TASK text.

## Launch preamble

Export exactly this environment before operating the run:

```bash
export UNIMATRIX_HOME=~/code/unimatrix
export CONF="$UNIMATRIX_HOME/profiles/thrifty.conf"
export ENV_MASTER_FILE=~/s/.env.master
export DOCTOR_LANES="glm grok codex claude"
```

## Doctor gate

Run `unimatrix doctor --live` before anything else.
It must exit 0.

On a nonzero exit, STOP immediately.
Report the failing lane probe and do no planning, card writing, or launch.
Do not improvise around a dead lane.

## Delegated plan protocol

1. Stage the bus and planning context.

   Run `mkdir -p .bus-<label>/specs` from the target repository.
   Write task-relevant repository file paths, such as specs and source files
   the task touches, one path per line, to
   `/tmp/plan-ctx-<label>.list`.

2. Delegate the read-only plan to Codex.

   Append the TASK text to the plan template at call time, then run:
   `unimatrix call codex:default @"$UNIMATRIX_HOME/profiles/thrifty/plan-request.md" --files /tmp/plan-ctx-<label>.list --id plan0`

   Require exactly one JSON object whose `waves` contain `cards`.
   Every card must define `id`, `chain`, `write`, `files`, `timeout_sec`,
   and `prompt`.

3. Delegate card generation to glm.

   Build a manifest containing the `plan0` answer file and
   `$UNIMATRIX_HOME/profiles/thrifty/card-writer.md`.
   Then run:
   `unimatrix call glm:glm-5.2 @"$UNIMATRIX_HOME/profiles/thrifty/card-writer.md" --files <manifest> --write .bus-<label>/specs --id cards0`

   Keep wave 1 cards runnable; name wave 2 or later `*.prompt.waveN`.
   Those cards remain invisible until their wave is promoted.

4. Perform the ONLY token-bearing step.

   Run `swarm-ctl lint-specs .bus-<label>`.
   Trust its return code.
   Eyeball only card IDs and cages; never read card bodies.

5. Launch the preseeded run.

   Run exactly:
   `cd <target repo> && $UNIMATRIX_HOME/swarm-run.sh --run <label> ""`

   The empty question is intentional: it drains the preseeded cards.

6. Gate and promote each later wave.

   At each barrier, strip `.waveN` from that wave's card filenames.
   Enqueue the promoted cards with `swarm-ctl add`.
   Run the applicable tests and lint yourself before continuing.
   Promote only after the prior wave and its barrier are green.
   Continue through all planned waves using the same discipline.

## Failure ladder

Apply these responses in order and do not invent additional recovery paths.

- If spec lint fails, allow ONE `claude:haiku` card-writer retry.
  Append the exact lint errors to that retry request.
  If lint still fails, fable may handwrite ONLY the failing cards.
  Do not rewrite passing cards or broaden the repair.
- If the Codex plan fails or times out, retry it once.
  If the retry also fails, fable may use the planning terminal fallback.
  Record that fallback explicitly in the ledger.
- If a lane dies mid-run, let configured chains absorb the failure.
  Never relogin or swap authentication during the run.

## Fable token diet

Observe status ONLY with `swarm-ctl status`, `swarm-ctl timeline`, and
`swarm-ctl postmortem`.
NEVER read `run-*.jsonl`, `res-*.txt`, or card bodies.
Trust the spec-lint return code and the engine verify wave.
`VERIFY_MAP` judges every done card; do not duplicate its reviews.

All prose deliverables, including docs, summaries, and reports, are glm cards.
Never write prose deliverables in-session.
Do not absorb worker outputs into the orchestrator context for convenience.
Use terse routing decisions and gate results.

Close by running `unimatrix report --run <label>`.
Read ONLY its footer and totals.
Do not inspect the underlying ledger events to reconstruct the report.

## Close-out

Confirm the engine verify wave is green.
Run repository gates: `./check.sh` for unimatrix, or the target repository's
declared test command for another repository.
Do not declare success while either verification layer is red.

Generate the final report with `unimatrix report --run <label>`.
Confirm `anthropic share:` is `<10%`, the target.
If it is not `<10%`, report the miss plainly; do not alter ledger data.
Update the ledger and required close-out records according to repository rules.
Finish with the run label, verification result, repository-gate result,
priced totals, Anthropic share, and any terminal fallback used.
