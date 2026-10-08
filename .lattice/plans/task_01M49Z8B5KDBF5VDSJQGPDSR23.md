# C11-352: Attribute agent tokens to tabs: tab ids in launch records, conversation.bound event, offline c11 usage

## Why
A 5.5-day session ran 901 agent launches and processed about 32.7B tokens (about 98M output) across Claude Code and Codex on the host. None of it can be attributed to a tab, workspace, or role. `agent-launches.jsonl` records harness and model but no tab UUID. The event log never records a conversation or session id, even though c11 captures it for resume (`conversation capture-runtime`, the Claude wrapper). Today the only join is cwd plus time-window guessing.

Related: C11-230 (agent identity and task id on every envelope). This ticket is the token-accounting slice, and it should land on whichever identity fields C11-230 defines.

## Deliverable
1. `LaunchRecord` in `agent-launches.jsonl` gains `tab_id`, `workspace_id`, and the resolved launch cwd.
2. A `conversation.bound {kind, conversation_id, model}` event when c11 learns or changes a tab's conversation id. It uses the existing capture paths, so no new probing.
3. `c11 usage [--since …] [--by tab|workspace|model|harness] [--json]`: a CLI-side command that reads transcripts and session logs **in the CLI process, never in the app**. It dedupes Claude by message and request id, takes Codex `total_token_usage` deltas, joins through `conversation.bound`, and reports input, cache-read, cache-write and output per group.
4. Skill and docs updated, then synced.

## Performance constraint (hard)
The app's only new work is one JSONL field set at launch and one event per conversation bind. All transcript reading happens offline in the CLI, on demand. The app never tails transcripts for this feature.

## Acceptance
For a tagged test session with at least one Claude and one Codex tab, `c11 usage --by tab --json` returns per-tab totals that match the transcripts' own counts.
