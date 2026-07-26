# Lane economics — subscription vs metered API for swarm workloads

Purpose: which auth/billing shape to run per lane, and why the ledger words dollar figures
differently depending on the answer. A swarm fan-out is a burst of many short, parallel,
tool-heavy calls — a shape that stresses billing models built around a human typing one message
at a time. Picking the wrong shape either burns real money at list price for something a flat fee
already covers, or throttles a run against a metering rule that was never designed for agentic
concurrency. This doc is the reasoning; `rules/unimatrix/model-lanes.md` is the spawn contract and
failover mechanics per lane.

## The three billing shapes

- **Session/OAuth subscription pools.** A flat recurring fee buys a metered *window* — weekly or
  rolling — shared across however many surfaces the vendor lets the same login touch. The
  marginal cost of one more call inside the window is zero until the pool empties; the cost that
  matters is the flat fee itself, paid whether the swarm runs once or a thousand times that
  period.
- **Coding-plan quotas.** Also a subscription, but metered per *prompt* or per *request* in a
  rolling window rather than per token. The billing unit is coarser than raw usage — this is the
  detail that makes or breaks a swarm's economics on a given plan, covered below.
- **Raw pay-as-you-go API.** Real dollars per token, no pool to draw down. Every call is priced
  independently at the provider's list rate; concurrency doesn't change the unit price, only the
  total.

## Rule of thumb

Swarm fan-outs are bursty and parallel by construction — dozens of short-lived workers, each
making one or a handful of tool-augmented turns, all in a tight time window. That shape is
naturally **API-shaped**: PAYG bills exactly what was used, with no window to blow through and no
quota to protect. Subscriptions only win in two situations: the plan's metering unit happens to
*ignore* what an agentic turn actually costs (a metering rule built around "one prompt = one
message" doesn't notice that a single card burned ten tool calls to satisfy it), or the plan is
already paid for regardless of how it's used, in which case running the swarm against it is free
at the margin. Everywhere else, treat the subscription's flat fee as a budget cap to watch, not a
reason to avoid PAYG.

## Lane by lane

**Anthropic (claude lane).** Session auth. The result envelope's cost field reflects real
Anthropic list pricing — it is accurate for this lane, unlike the swapped-endpoint lanes below.
Recommendation: subscription for the orchestrator and the primary exec lane (steady, predictable
volume), API key only as burst overflow once the subscription window is exhausted mid-run.

**Z.ai coding plan (glm lane).** Per-query metering: one card that fires many tool turns inside a
single agentic conversation still counts as roughly one prompt against quota, because the plan
meters at the query boundary, not the tool-call boundary. That makes swarm cards nearly free
against the plan once purchased — the metering unit is blind to exactly the thing that makes a
swarm expensive elsewhere. The catch is observed concurrency: in-flight parallelism on this lane
has stayed in the single digits in practice, so the lever to pull is capping how many workers run
at once on this lane, not fanning it out wide and hoping the pool absorbs it. Subscription is
strongly dominant here; the ledger reports prompts consumed, never a dollar figure, because the
underlying billing unit isn't dollars.

**SuperGrok pool (grok lane).** A weekly credit pool shared jointly across the vendor's chat, IDE,
and API surfaces under one account. Any dollar figure logged for this lane is a cost-equivalent
estimate against that shared pool, not a billed line item — and the estimate being unavailable on
a given call never means the call was free; the pool still drew down, only the server hadn't
stamped a figure yet. Observed concurrency on this lane has no low ceiling the way glm does, which
makes it a good high-volume lane while a subscription is active. The same CLI also accepts a
metered PAYG key as a fallback, so the subscription-to-API path is a same-binary swap, not a
migration, whenever the pool is exhausted or a subscription lapses.

**OpenAI (codex lane).** Session auth, no cost field in the envelope at all — this lane reports
tokens only. Treat the provider's own usage dashboard as the source of truth for spend; nothing in
the swarm's own logs can substitute for it on this lane.

**Gemini.** Key-based auth against AI Studio, and likewise no cost field in the result. Note
whether the key is riding a free tier or a paid tier before reading any absence-of-cost as
evidence the lane is free — free-tier keys have their own separate rate ceilings that a swarm can
hit well before any billing question comes up.

**Moonshot (kimi lane).** The one lane in real dollars end to end. PAYG only — the ledger
recomputes cost from the envelope's raw usage counts at Moonshot's own list price (roughly $3.00
per million input tokens, $0.30 per million cache-hit tokens, $15.00 per million output tokens for
the flagship model), because the envelope's own cost field is computed at the wrong provider's
price list and is simply incorrect for this lane if taken at face value. Burst concurrency on this
lane has held up well at modest cumulative top-up levels. A subscription variant exists on paper
but doesn't fit swarm traffic even where available: it meters every individual request inside a
short rolling window, and a single headless card can easily generate fifty to a hundred requests
on its own — the wrong billing granularity for a fan-out by a wide margin. Signups for that
subscription are paused as of this writing regardless. Recommendation: stay on PAYG for swarm
traffic, and only re-run this comparison if the subscription becomes purchasable again *and*
observed monthly PAYG spend on this lane exceeds what the plan would cost flat.

## Rate-limit economics

The two billing shapes fail differently under load, and the failure mode should drive how long a
lane parks once it trips a limit. Subscription lanes tend to park *long* — a blown weekly or
session-scale pool doesn't refill until the window rolls over, so a limit signal here should set a
TTL on that scale. PAYG lanes tend to park *short* — most rate limits on metered APIs are
requests-per-minute windows that clear in roughly a minute, so parking a PAYG lane for hours after
a transient 429 is pure self-inflicted downtime. See the failover section of
`rules/unimatrix/model-lanes.md` for the exact per-lane signal matching and TTL values; the point
here is only that the *shape* of the billing model predicts the *shape* of the correct park
duration before looking at a single error code.

## Cache-hit discipline

On subscription and pool lanes, cache hits are invisible to the economics — the flat fee doesn't
care whether a prefix was reused. On PAYG lanes, they are not: a cache-read token typically prices
around an order of magnitude cheaper than a fresh input token. That makes long shared prompt
prefixes (a plan document, a shared spec, repeated system context across many cards on the same
lane) materially cheaper in a way that never shows up as a lever on the pool-metered lanes, because
there's nothing to save against a flat fee. Kimi is the lane where this actually matters — design
shared-prefix cards with that in mind if that lane is carrying real volume.

## Ledger doctrine

No silent spend: every manual, offline, or spawned-agent run gets one row, and the wording of the
dollar figure in that row must match the billing shape it came from, not be flattened to a single
generic "$X spent." Three wordings, never interchanged:

- **Real dollars** — the figure is recomputed from actual usage against a provider's list price
  and is a genuine invoice line item (the kimi lane, end to end).
- **Notional pool dollars** — the figure is a cost-equivalent estimate against a shared
  subscription pool, not a bill (the grok lane; occasionally others when a provider's own envelope
  supplies an estimate against a flat-fee plan).
- **Prompts consumed** — there is no dollar figure at all because the plan doesn't meter in
  dollars; report the metering unit the plan actually uses (the glm lane).

Absence of a cost field is never evidence of zero cost — it usually means the metering happens
somewhere the log can't see (a provider dashboard, a pool balance), not that the call was free.

## Decision table

| Lane | Recommended auth today | Ledger wording | Rate-limit park TTL class |
|------|------------------------|-----------------|----------------------------|
| Anthropic (claude) | Subscription for steady orchestrator/exec load; API key for burst overflow | Real dollars (envelope is accurate) | No dedicated failover arm today — falls through to bounded retry, never parks |
| Z.ai (glm) | Subscription — dominant, cap concurrency instead of fanning wide | Prompts consumed | Long (subscription window) |
| SuperGrok (grok) | Subscription while pool is funded; PAYG key as post-subscription fallback | Notional pool dollars | Long (weekly pool), short once on PAYG |
| OpenAI (codex) | Subscription; check provider dashboard for real spend | No cost field — tokens only, dashboard is source of truth | Long (subscription window), 2-strike before flip |
| Gemini | API key; confirm free vs. paid tier before assuming zero cost | No cost field — track tier separately | No dedicated failover arm today — falls through to bounded retry, never parks |
| Moonshot (kimi) | PAYG only — subscription variant wrong shape for fan-outs, and paused anyway | Real dollars (recomputed at provider list price, never the envelope's own figure) | Short (per-minute RPM windows); long only on a quota/balance signal |
