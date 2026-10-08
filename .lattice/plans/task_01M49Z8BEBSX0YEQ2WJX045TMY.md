# C11-355: Model cost catalog: current models and cache pricing

## Why
`~/Library/Application Support/c11/model-costs.json` (written by ModelCostCatalog) has no rows for the models actually in use: Opus 5.5, Sonnet 5.5, Fable 5.1, and the gpt-6 family (luna, astra, sol, 6.1-sol). It also carries no cache-read or cache-write pricing. In a 5.5-day session, 98% of Claude input and 97% of Codex input were cache reads, so any cost estimate built on input and output prices alone is badly wrong. Cost for this session could only be estimated by assuming predecessor prices.

## Deliverable
Refresh the catalog source to include the current models, and extend the schema with `cache_read_usd` and `cache_write_usd` (null when unknown). Consumers (tab sheet, `c11 usage`, `c11 report`) report "price unknown" rather than zero for a missing model.

## Performance constraint
The catalog refresh path is unchanged (background fetch, cached file). No new runtime work.
