# Offline local activity analysis

`c11 usage` and `c11 report` read local files in the CLI process, with no socket,
network access, transcript writes, or app-side transcript scanning. They work
with the app stopped. Output may contain private workspace titles or model IDs;
keep reports local unless the operator asks to share them.

```sh
c11 usage --since 7d --by panel --json
c11 usage --since 2026-10-01T00:00:00Z --by workspace
c11 usage --by model
c11 usage --by harness
c11 report --instance <instance-id> --format md
c11 report --since 14d --format json
```

`--since` accepts an ISO-8601 timestamp with timezone or a positive duration in
minutes, hours, or days (`30m`, `12h`, `7d`). Report selects the newest instance
when neither selector is supplied. `--since` alone reads all retained instances;
combine it with `--instance` to limit one process. Rolled `.ndjson.N` files are
included and sorted by sequence within each instance. Both v1 surface names and
v2 panel names are accepted. Timestamps may race; replay never reorders sequence
numbers to make them look chronological.

Usage reads `~/.claude/projects/**/*.jsonl` and `~/.codex/sessions/**/*.jsonl`.
It joins native session IDs to the read-only lifecycle journal's `session_id`,
`tab_id` (the persisted panel UUID), `agent_kind`, and `workspace_id` columns.
No cwd or title heuristic guesses ownership. Multiple panel/workspace mappings
for one harness/session remain `unattributed`; missing links remain visible in
totals. The unattributed aggregate refers to the requested grouping axis, so
workspace grouping also includes linked panels with unknown workspace IDs.
Other harness transcripts are not yet parsed.

Claude streaming snapshots are deduplicated globally by message ID and request
ID, retaining the most complete token snapshot across files and copied/forked
sessions. Conflicting journal links across those sessions remain unattributed. Missing message identity is
counted rather than collapsing unrelated requests and is marked as a coverage
gap. Explicit 5-minute and 1-hour cache creation are separate categories. A cache
creation total without the TTL split stays `cache_write_unknown_ttl_tokens`;
its price is unknown. Codex cumulative `total_token_usage` samples become deltas,
including the baseline before `--since`. Cached input is a subset of input and
reasoning output is a subset of output, so neither is double counted. Identical
snapshots are ignored. A reset uses `last_token_usage` and marks the lost interval
as uncertain; if that field is missing the reset interval's usage is unknown.

JSON has `schema_version: 1`, `totals`, `unattributed`, `groups` and
`coverage_gaps`. Missing transcript timestamps are included with an explicit gap
because their time window cannot be proven. Malformed lines and unreadable files
are visible gaps. Retention and unrecorded harness usage can never be proven
complete by this command.

Report derives span, panel creation, per-instance peak open/working counts,
observed agent hours, closed-panel lifetime percentiles, workspace names and
explicit panel-title topics, UTC daily activity and hour-of-day event rhythm. Quiet intervals are split at
UTC midnight, so days without events retain their observed exposure, concurrency
peaks, agent-hours and foreground lower bounds. Hang rates reproduce open-panel
load buckets (under40, 40–79, 80+) with exposure hours and precursor counts.
Working-panel buckets (0–9, 10–24, 25–49, 50+) are also included.
`host_usage` covers transcripts within the observed report span across the host;
it is explicitly **not exclusive instance usage**. Inspect `usage --by panel`
for panel-level attribution.

Foreground time requires known app-active, screen-lock and sleep states. An
initial snapshot or subsequent edges establish each state. Unknown presence,
sequence gaps, `log.dropped`, and disabled analytics stay visible. `log.policy`
disabled spans are unknown. `foreground_hours` is null if any observed interval
has unknown presence; `observed_foreground_hours` is its supported lower bound.
Panel counts and agent-hours are observations within retained history, not a
claim about panels restored before it or work hidden by missing events.
Open/censored panel lifetimes are counted separately from completed lifetimes.

For synthetic fixtures or alternate stores, use `--state-root <directory>`,
`--claude-root <directory>`, `--codex-root <directory>`, and repeatable
`--journal <lifecycle.sqlite3>`. These do not modify the selected stores.
The shared event-directory override, where supported by the app build, also
applies to report. No server is started and no app focus changes.

## Prices and their limits

The catalog resolves bundled standard rates plus agent-maintained overrides in
the state root's `model-costs.json`. Seven bundled rows are verified against
first-party documentation on 2026-10-08; `spec/model-costs-current.json` records
the same importable snapshot. Reading defaults never writes a catalog file. It adds Opus
5.5, Sonnet 5.5, Fable 5.1, GPT-6 Sol/Luna/Astra and GPT-6.1 Sol. A persisted entry overrides its entire bundled row, including missing cache
rates. Removing that stored override reveals the bundled row again. Unknown
models remain unknown. No network refresh happens automatically:

```sh
c11 model-costs list --json
# Optional: persist this snapshot as explicit operator overrides.
c11 model-costs import spec/model-costs-current.json
c11 model-costs set example-model --in 2 --out 10 --cache-read 0.1 \
  --cache-write 2.5 --cache-write-1h 4 --source <verified-url>
c11 model-costs get example-model --json
```

All fields are USD per million tokens. `cache_read_usd`, `cache_write_usd`
(Claude 5-minute write), and `cache_write_1h_usd` are optional. Existing input and
output catalogs remain compatible. Missing cache rates never become zero.
Unknown models, missing required rates, unknown Claude cache-write TTL or
nonstandard speed yield a null `estimated_api_usd`, displayed as `unknown`.
Current reference GPT-6 prices account for the documented >272K prompt premium
when the native transcript exposes a per-request delta at that size. Estimates
exclude tool charges and any billing category not present in transcripts.
Rates are current standard API comparisons, not historical invoices or
subscription spend; custom provider, residency, batch and speed pricing require
an appropriate separately verified catalog. A group with any unknown price has
an unknown whole-group estimate, rather than a misleading partial total.

Primary sources: [Anthropic pricing](https://platform.claude.com/docs/en/about-claude/pricing),
[GPT-6 Luna](https://developers.openai.com/api/docs/models/gpt-6-luna),
[GPT-6 Sol](https://developers.openai.com/api/docs/models/gpt-6-sol),
[GPT-6.1 Sol](https://developers.openai.com/api/docs/models/gpt-6.1-sol),
[GPT-6 Astra](https://developers.openai.com/api/docs/models/gpt-6-astra).
