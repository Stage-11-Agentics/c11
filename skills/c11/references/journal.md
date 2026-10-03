# Agent lifecycle journal

The lifecycle journal is c11-owned, bounded history of structural observations for an exact tab, agent kind, and session owner. It stores no prompts, tool bodies, answers, or transcript text. These observations are optional: a terminal remains usable when a provider does not expose them, and c11 does not write tenant configuration or make an agent wait for an observation.

The journal phase and unread attention are separate. A blocked ask can remain blocked after its unread notification is cleared. A completed turn is a lifecycle fact; it does not prove that a particular question was answered. See [journal semantics](conversation.md#lifecycle-journal) for ownership, restart confirmation, and retention, and the [append API](api.md#structural-lifecycle-append) for the adapter contract.

## Commands

Read the live roster without focusing, launching, or resuming a tab:

```bash
c11 agents --json
```

The schema version 1 document has `live_identity`, `coverage`, `tabs`, and `restore_candidates`. `live_identity` is `available` or `unavailable`; `coverage.health` is `ok` or `degraded`, `coverage.storage` is `ok` or `unavailable`, and `coverage.unattributed` counts events with no tab or session. With c11 down, `tabs` is empty and `live_identity` is `unavailable`. Journal fields are null for a live tab without a journal row; its flag, suppression, and last-seen values can still be present. For blocked, completed, and restart cases, read the fields this way:

| Situation | Roster fields |
|---|---|
| Blocked question | `state: "blocked"`, `reason: "question"`, plus the evidence `source`, `freshness`, and `confirmation`. |
| Working turn | `state: "working"`; `turn_started_at` is present only when its start is retained and attributable. |
| Completed turn | `state: "idle"`, `turn_outcome: "completed"`. |
| Prior owner after restart | A `restore_candidates` row with `confirmation: "unconfirmed"`, a `historical_candidate`, `ended`, or `unknown` label, and `disconnected` or `unknown` connection. It is not a currently working tab; do not charge time across the restart gap. |

Use the journal query for lifecycle analytics. Time bounds accept epoch milliseconds or ISO 8601 and form a half-open `[from,to)` window:

```bash
c11 journal query --agent codex --model synthetic-model \
  --workspace 11111111-1111-4111-8111-111111111111 \
  --from 2026-10-02T00:00:00Z --to 2026-10-03T00:00:00Z \
  --stall-ms 900000 --json
```

The report separates time in state, blocked time, operator response, turns, errors, and stalls, with per-agent, per-model, and per-workspace breakdowns. Durations are milliseconds and rates are per covered hour. An absent response is not zero: `operator_response.status` is `"unavailable"` and its latency values are null when there is no joined response evidence. Preserve `coverage.incomplete`, `uncertain_count`, and `censored_count`; an available aggregate can still omit unsupported asks.

Export the body-free journal as NDJSON:

```bash
c11 journal export
```

Rows begin with a manifest and end with a coverage summary; event, current-state, or gap rows appear when applicable. The export contains no prompt, command, argument, cwd, output, or answer text. See the [API reference](api.md#journal-analytics-and-export) for filtering, offline bundle selection, the optional output path, and the mutating clear verb.

Structural ingestion is for registered adapters. Ordinary agents should keep using the skill's status primitives; do not append your own lifecycle phase. See [structural lifecycle append](api.md#structural-lifecycle-append) for the accepted event shape, ownership checks, receipt, and spool behavior.

## Reading state

The roster lists live tabs, with journal state where present, plus retained restart candidates. A tab can have no journal row and still appear with its ordinary attention fields. Journal state, source, reason, freshness, and confirmation remain explicit; missing evidence is unknown or unavailable, not an inferred working or completed state. The command does not focus, launch, or resume a tab. The [API reference](api.md#agent-roster) gives the full schema.

After restart, a prior row is a restore candidate with `confirmation: "unconfirmed"` and a disconnected or unknown connection. It is not proof that the process is still live. Do not carry a working clock through the restart gap. Retained evidence may classify the row as a historical candidate, ended, or unknown; coverage loss remains visible.

`lifecycle.changed` reports an applied journal phase transition. `waiting.entered` and `waiting.left` remain unread-notification edges and carry no journal reason. Do not treat unread clearing as ask resolution or reconstruct the current roster by replaying the per-instance events file.

## Provider limits

- **Claude Code:** the per-process hooks attach only lifecycle facts the journal accepts. `PermissionRequest` is observe-only and returns no decision. Ordinary `PostToolUse` activity does not clear a blocked ask; only `PostToolUse` for the same AskUserQuestion or ExitPlanMode `tool_use_id` resolves that ask. c11 does not observe the selected answer from Claude's AskUserQuestion picker. It records no answer content; picker response latency remains censored or unavailable rather than zero. See [operator-response coverage](api.md#journal-analytics-and-export).
- **Codex:** the trust probe found the per-session hook ran only when trust bypass was enabled. The shipped fallback is notify-only: c11 does not enable hooks, inject hook configuration, or bypass trust. A matching root completion can close a turn; hook start and permission observations are unavailable, so an exact owner's hook coverage is degraded. A sessionless diagnostic cannot establish that live profile. `adapter_gap` is health evidence only and does not change phase or blocked state.
- **Codex and Grok transcript observations:** turn edges are advisory. They may describe a start or completion when the bounded transcript source covers it, but they do not set or clear a blocked ask. Gaps in retained or incremental source coverage stay visible; do not invent turns across them.

For analytics, distinguish `unavailable`, `degraded`, `unconfirmed`, advisory evidence, incomplete coverage, and censored intervals from zero. A healthy result from one producer does not imply every producer is covered. See [analytics and export](api.md#journal-analytics-and-export) for metric definitions, response coverage, and the body-free export format.
