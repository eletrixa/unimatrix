# LLM Run Evidence

Optional run-evidence ledger. Copy to `docs/ops/llm-runs.md` (gitignored) and append one row per
manual/offline/batch/spawned LLM run so there is no silent spend — each row records when, what ran,
the lane (provider + endpoint, i.e. whether a discount applied), the workload, and the actual billed cost.

| When | What ran | Lane | Workload | Billed cost (USD) |
|------|----------|------|----------|-------------------|
