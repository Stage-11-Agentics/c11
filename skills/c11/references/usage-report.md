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
minutes, hours, or days (`30m`, `12h`, `7d`). `--until` accepts an ISO-8601 timestamp
and bounds both transcript usage and replay state, inclusively. An end before the
start is rejected. Report selects the newest **production** instance when no
selector is supplied. `--since` alone includes retained production instances;
`--instance <id>` explicitly selects a tagged or production process, and
`--all-instances` includes tagged builds too. Production IDs use the exact
`com.stage11.c11-<pid>` prefix. Rolled positive `.ndjson.N` generations are
included and sorted by sequence within each instance. Both v1 surface names and
v2 panel names are accepted. Timestamps may race; replay never reorders sequence
numbers to make them look chronological. Daily and hour-of-day buckets use the
local timezone and its calendar boundaries, including daylight saving changes;
`--utc` selects UTC. JSON exposes `timezone`, `daily`, `hour_of_day_events`, and
`instance_scope`.

Usage reads `~/.claude/projects/**/*.jsonl` and `~/.codex/sessions/**/*.jsonl`.
It joins native session IDs to the read-only lifecycle journal's `session_id`,
`tab_id` (the persisted panel UUID), `agent_kind`, `workspace_id`, and
`committed_at_ms` columns. Panel grouping considers distinct panel IDs, so a
workspace move cannot make a known panel ambiguous. A unique panel link survives
asynchronous journal registration after a usage timestamp, while its earlier
workspace stays unknown. Pruned history cannot establish earlier panel ownership.
Workspace ownership follows
the last journal mapping committed at or before the usage timestamp. Missing
mapping time, missing usage time, tied mappings or pruned journal history remain
visible gaps. No cwd or title heuristic guesses ownership. Missing/ambiguous
links preserve all tokens. `unattributed_basis` states the aggregate's meaning:
on panel, model and harness axes it counts tokens with no unique panel link;
on the workspace axis it also includes unknown workspace ownership. Other
harness transcripts are not yet parsed.

Claude streaming snapshots are deduplicated globally by message ID and request
ID, retaining the most complete token snapshot across files and copied/forked
sessions. Ownership follows the earliest transcript occurrence; equal copied
timestamps use the earliest journal registration when all source sessions have
one. Tied or absent provenance remains unattributed, independent of filename
order. Missing message identity is
counted rather than collapsing unrelated requests and is marked as a coverage
gap. Explicit 5-minute and 1-hour cache creation are separate categories. A cache
creation total without the TTL split stays `cache_write_unknown_ttl_tokens`;
its price is unknown. Codex cumulative `total_token_usage` samples become deltas,
including the baseline before `--since`. Cached input is a subset of input and
reasoning output is a subset of output, so neither is double counted. Identical
snapshots are ignored. A reset uses `last_token_usage` and marks the lost interval
as uncertain; if that field is missing the reset interval's usage is unknown.

JSON has `schema_version: 1`, `totals`, `unattributed`, `groups`, `coverage_gaps`
and `skipped_counts`. Missing transcript timestamps are included with an explicit
gap because their time window cannot be proven. Malformed candidate lines,
oversized lines and unreadable files are visible gaps. Bad-line counts are
reported by kind. An oversized line is discarded through its newline, then the
reader continues. Raw byte filters skip irrelevant lines before JSON decoding;
Foundation temporaries drain per bounded chunk. Claude files with mtime before
`--since` are skipped and counted, with `claude_file_mtime_filter_applied`:
mtime filtering assumes native append-only transcripts, so imported files whose
mtime predates their message timestamps can be omitted. Codex files always
retain their pre-window counter baseline; samples sort by timestamp, file and
line, including equal or unknown timestamps. Retention and unrecorded harness usage can never be proven
complete by this command.

Report derives span, panel creation, per-instance peak open/working counts,
observed agent hours, closed-panel lifetime percentiles, workspace names and
explicit panel-title topics, daily activity and hour-of-day event rhythm. Quiet intervals are split at
calendar midnight in the selected timezone, so days without events retain their observed exposure, concurrency
peaks, agent-hours and foreground lower bounds. Hang rates reproduce open-panel
load buckets (under40, 40–79, 80+) with exposure hours and precursor counts.
Working-panel buckets (0–9, 10–24, 25–49, 50+) are also included.
A known instance start requires sequence 1 to be `log.opened`; sequence 1
`log.policy` after logging was enabled late is not a panel census and records
`instance_start_missing`. Truncated initial history, a sequence gap, dropped events or a full log kill
makes the instance's load unknown permanently for the retained replay. Presence
snapshots and later panel edges are not a full panel census. Subsequent edges
can establish observed lower-bound peaks/agent-hours, but never definite load
bucket exposure or hang attribution. `load_unknown_hours` and
`hangs_with_unknown_load` preserve those intervals and hangs; both load tables
include an `unknown` row with a null rate. Each daily row makes `peak_open` and
`peak_working` null if any load in that day is unknown, including unknown events
at a day boundary. `observed_peak_open`, `observed_peak_working` and
`observed_agent_hours` retain observed lower bounds; `load_unknown_hours` counts
unknown exposure. Quiet days inherit the persistent uncertainty. Daily observed
agent-hours sum to the aggregate observed lower bound, independent of exact
bucket knowledge.
`kinds_created` counts observed creations by panel kind. `peak_open_kinds` is the
kind composition at the first overall per-instance peak; `peak_open_by_kind`
tracks each kind's independent maximum. Gapped replay makes the exact peak maps
null and retains `observed_peak_open_kinds` / `observed_peak_open_by_kind` as
supported lower bounds.

Workspace rows include selection counts, `selected_dwell_hours`, waits entered,
and attributed observed agent-hours. Selection dwell follows the last selected
workspace in each process until another selection or close; it includes time
while c11 is in the background and is not foreground attention. An initial
unknown selection, a disabled history span or a sequence gap adds to
`workspace_selection_unknown_hours`. Waits and working time without a known
workspace remain `waiting_entered_unattributed` and
`workspace_agent_hours_unattributed`. These are derived from edges only.

Coordination summaries count observed `mailbox.accepted` / `mailbox.delivered`
events, accepted messages by sender (`mail_from`), and raised/lowered/suppressed/
unsuppressed flag edges (`flag_events`). They count events, not unique people or
still-pending messages. `hang_causes` counts precursor causes, preserving an
`unknown` cause. `hang_durations_ms` includes sample count, observed sum and max,
and unknown precursor count. Missing/invalid samples, reported counts exceeding
available samples, or event-history gaps make exact duration totals/max null;
known recorded samples remain visible. Historical event counts are observations
within retention, with coverage gaps, not complete lifetime totals.

`host_usage` covers transcripts within the observed report span across the host;
it is explicitly **not exclusive instance usage**. Without an observed event
span (including a missing requested instance), `host_usage` is null and
`usage_span_unavailable` is reported. Transcripts and journals are not scanned
for such a report, and Markdown labels usage as unknown. Inspect `usage --by panel`
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
the state root's `model-costs.json`. Eleven bundled rows are verified against
first-party documentation on 2026-10-08; `spec/model-costs-current.json` records
the same importable snapshot. Reading defaults never writes a catalog file. It adds Opus
5.5 and 4.8, Sonnet 5.5, Fable 5.1, Haiku 4.5, GPT-5.6 Sol/Luna,
GPT-6 Sol/Luna/Astra and GPT-6.1 Sol. A persisted entry overrides its entire bundled row, including missing cache
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
GPT-6 deltas above 272K input tokens have an unknown context unless the full
delta equals `last_token_usage`: cumulative Codex deltas may combine several
small requests, so their sum alone does not establish a per-request premium. Token counts stay visible;
`codex_per_request_context_unknown` records the pricing gap. Estimates
exclude tool charges and any billing category not present in transcripts.
Rates are current standard API comparisons, not historical invoices or
subscription spend; custom provider, residency, batch and speed pricing require
an appropriate separately verified catalog. A group with any unknown price has
an unknown whole-group estimate, rather than a misleading partial total.

Primary price sources: [Anthropic pricing](https://platform.claude.com/docs/en/about-claude/pricing),
[OpenAI pricing](https://developers.openai.com/api/docs/pricing).
Model context and feature references: [GPT-6 Luna](https://developers.openai.com/api/docs/models/gpt-6-luna),
[GPT-6 Sol](https://developers.openai.com/api/docs/models/gpt-6-sol),
[GPT-6.1 Sol](https://developers.openai.com/api/docs/models/gpt-6.1-sol),
[GPT-6 Astra](https://developers.openai.com/api/docs/models/gpt-6-astra).

`foreground_hours` is exact only when presence is known for the entire span.
`foreground_hours_range.minimum` is observed active/unlocked/awake time; its
maximum also includes every unknown interval. The app writes `log.opened` with
`pid`, then separate initial presence snapshot edges after startup. The launch
preamble therefore remains unknown instead of being silently treated as active.
A `log.retention` degraded episode adds informational
`retention_reconciliation_degraded`; it does not invalidate load or presence,
because coordination degradation does not itself imply event loss.

Totals and every group expose `estimated_api_usd` (null if any row is uncertain),
`known_api_usd_subtotal` (exactly priced rows only), `unknown_cost_tokens` and
`unknown_cost_calls` (whole uncertain rows), plus
`estimated_api_usd_lower_bound` / `estimated_api_usd_upper_bound`.
The lower bound includes only supported charges; an unsupported row contributes
zero to the lower bound and makes the upper bound null. These are current
standard API list-rate bounds, not subscription charges or historical bills.
`input_tokens` means fresh input for Claude and uncached input for Codex.
Codex does not separate cache writes from uncached input: any such input makes
the exact estimate unknown. Where a published write rate is available, bounds
range between all-fresh input and all-cache-write input. GPT-6 deltas above 272K
retain unknown context unless every token category equals `last_token_usage`,
which establishes a single request and permits the documented context premium.
Missing cache rates in a whole-entry operator override produce
`model_cache_rate_unavailable`; absent model prices produce
`model_price_unavailable`. Defaults include verified Opus 4.8, Haiku 4.5 and
GPT-5.6 rows. Exact, case/provider-normalized and dated model IDs are supported;
explicit dated overrides take priority over their undated default.
