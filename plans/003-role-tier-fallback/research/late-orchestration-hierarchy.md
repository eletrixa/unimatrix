# Late research — multi-agent orchestration hierarchies (replacement agent, 2026-07-24)

The workflow's original orchestration-hierarchy agent died on structured-output retries; this
replacement ran as a plain-text sonnet agent. Findings validated the PRD's §3.1 apex rationale
(Anthropic lead-never-delegates, +90.2% eval figure) and the judge≠executor family-bias grounding.

SUMMARY: Anthropic's own multi-agent research system (lead Opus 4 + Sonnet 4 subagents) is the closest real-world analog to unimatrix's proposed tiering and validates the core split — the lead/orchestrator model retains query analysis, task decomposition, resource allocation, and final synthesis, while cheap/parallel subagents do search and gathering, and a separate CitationAgent does the final verification pass rather than the executor grading itself. Planner-executor-critic patterns, supervisor-worker frameworks, and LLM-as-judge bias research converge: judgment must run in a separate context from the executor, ideally on a different (or at least equally strong) model. arXiv 2508.06709 ("Play Favorites") empirically confirms self-preference and family-preference bias (self-enhancement bias alone worth 10-25 preference points). Delegation-failure studies show weak/under-specified task decomposition — not raw model capability — is the dominant failure mode (~48% delegation accuracy in one benchmark under ambiguous routing); mixing a frontier planner with cheap executors is Pareto-optimal on cost/latency but never beats a single top-tier model on raw quality — tiering is a cost play, not a quality play. Framework production experience warns orchestration layers have real overhead (supervisor patterns ≈3x token cost of a flat agent) and need explicit iteration limits/cost ceilings.

KEY POINTS:
- Anthropic's lead agent (strongest model) NEVER delegates: query analysis, strategy/decomposition, subagent resource allocation, mid-run direction changes, final synthesis all stay on the lead; only search/gather/tool-use parallelizes.
- Anthropic uses a dedicated CitationAgent as a distinct final verification stage — evaluation-of-output architecturally separated from production-of-output.
- Anthropic coordination failures pre-scaling-rules: uncontrolled spawning (50+ subagents for simple queries), duplicate work from vague task descriptions, overlapping/gapped coverage — all traced to under-specified delegation instructions, not model weakness.
- Anthropic's fix: explicit scaling rules in the orchestrator prompt (1 agent + 3-10 tool calls for simple fact-finding; 2-4 subagents for comparisons; 10+ only for genuinely broad research).
- Token/cost tradeoff: ~15x tokens of a single chat turn; token usage explained ~80% of performance variance — most gain came from spending more compute in parallel, not the hierarchy itself.
- Performance: lead-Opus + Sonnet subagents beat single-agent Opus by 90.2% on internal research eval, ~90% wall-clock cut on complex queries; multi-agent only wins when the task actually decomposes into independent parallel threads.
- arXiv 2508.06709: LLM judges (incl. Claude and GPT) show self-bias AND family-bias; Llama/Mistral judges did not in their dataset — same-family judge over same-family executor is a specific named risk.
- Broader judge-bias numbers: position bias up to ~75% preference swing for first-listed answer; verbosity bias 15-30 points; self-enhancement 10-25 points; mitigations (order randomization, identity masking, multi-judge ensembles) reduce but never eliminate.
- "Judge ≠ executor" as architectural law in production agent harnesses: delegate-permission agents stripped of edit permissions and vice versa; same-agent-grades-itself judgment "runs on the same reasoning patterns that produced the errors."
- Delegation-failure research (arXiv 2605.08761 "Beyond the All-in-One Agent"): dominant failure mode is mis-routing/under-specified delegation (~48% delegation accuracy measured), not executor weakness.
- "Think Big, Search Small" (arXiv 2607.07548): role factorization (plan/retrieve/synthesize) helps most when one model can't jointly hold all three — separation has value independent of model scale.
- Frontier-plans/cheap-executes economics: −65% cost / −53% latency vs all-frontier in one study, but essentially never beats a single top-tier model on raw output quality.
- Supervisor overhead: ≈3x token cost vs flat; teams adding a supervisor to a simple 2-agent pipeline saw costs triple for little reliability gain.
- Iteration limits, cost ceilings, explicit termination conditions are non-optional once delegation is autonomous — runaway spawning/looping is the most common production incident.
- Planner-executor-critic three-way tension is a design feature: conflicting incentives create "consensus boundaries"; one production financial-analysis deployment reported error reduction from 75% baseline to 7.9% residual across 522 sessions.

RECOMMENDATIONS for unimatrix:
1. Keep planning, adjudication, and final synthesis strictly on Fable — matches Anthropic's architecture and the mis-specified-delegation failure literature.
2. Never let a review lane grade same-family output in the same run; generalize the codex↔kimi cross-pairing as lanes are added, never relax it.
3. Write explicit scaling/scope rules for the review tier (simple card → no escalation; multi-file/ambiguous → mandatory cross-model review) rather than leaving escalation to model judgment.
4. Treat the tier as a cost/latency lever, not a quality upgrade for judgment-heavy steps — don't route final adjudication or plan-critique to Kimi/Codex expecting it to exceed Fable.
5. Add iteration/cost ceilings and termination conditions to any new review/verification loop before it ships.
6. Frame Kimi/Codex "spec critique" as a narrow critic role (correctness/standards friction against executor pragmatism), not general-purpose review — narrow role definition prevents mis-routing.
