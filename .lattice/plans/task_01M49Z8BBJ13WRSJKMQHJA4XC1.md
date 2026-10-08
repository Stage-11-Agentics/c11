# C11-354: c11 report: offline session analytics from the event log

## Why
On 2026-10-06 an agent spent a session hand-writing Python to replay a 5.5-day event log, join the agent-launch log, and scan Claude and Codex transcripts. The output was a session report: tabs created and peak open, agent-hours, tab lifetimes and roles, workspace topics, an hour-of-day rhythm, hang rate by load, and token totals by model and project. Operators will want this at every milestone, and agents should be able to get it in one call.

## Deliverable
`c11 report [--instance <id>|--since <dur>] [--format md|json] [--out <path>]`, which runs entirely in the CLI process with no socket required, like `events tail`. Sections:
- Session: span, tabs created by kind, peak open and peak working (with timestamps), agent-hours, tab lifetime percentiles, workspaces used
- Daily table and hour-of-day rhythm
- Workspaces: tabs, agent-hours, operator dwell, top final titles
- Stability: hang precursors by cause and load bucket, longest stall
- Foreground time (once the presence events exist), with a labeled proxy before then
- Tokens via `c11 usage` (once the attribution ticket exists), else host-wide in-window totals clearly labeled as unattributed
- Coverage: gaps, `log.dropped`, rotation loss, unknown versus zero

It should honor the journal's honesty rules: unknown is not zero, and censored or missing coverage stays visible.

## Performance constraint (hard)
Offline only. The app does no work for this command.

## Acceptance
`c11 report --format md` on a real multi-day instance log reproduces the hand analysis, and the skill teaches it.
