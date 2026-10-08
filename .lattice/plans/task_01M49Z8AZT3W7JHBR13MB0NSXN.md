# C11-350: Workspace lifecycle events, and every created panel gets a closed event

## Why
Post-hoc analysis of a 5.5-day session found 56 workspaces used but only 5 still open. The other 51 lost their names, because the event log has no workspace lifecycle events and `workspace.selected` carries only UUIDs. It also found 3 terminals restored at launch whose workspace disappeared seconds later without any `surface.closed` / `panel.closed`. Replaying the log therefore leaves ghost tabs "open" forever (32 open by replay versus 29 live).

## Deliverable
1. New taxonomy events: `workspace.created {title, root_directory, window_id, cause}`, `workspace.renamed {title, prior}`, `workspace.closed {title, root_directory, tab_count, lifetime_s}`, `workspace.root_changed {root_directory, prior}`.
2. Fix the restore or teardown path so every panel that emitted `panel.created` emits `panel.closed`, including panels torn down with their workspace during restore. Then add an invariant test: after create, restore and close churn, replaying the log yields exactly the live tab set.
3. Update the schema, events reference and skill, then sync.

## Performance constraint (hard)
These are emitted at existing lifecycle points that are already off the typing path, and they reuse the EventLog serial queue. No new main-thread work beyond reading the title and root the call site already holds.

## Acceptance
Replaying a churned tagged session's log reproduces `c11 tree --all` exactly (tabs and workspace names), with no ghosts.
