# Topic 06: The grab list (hardening, workspaces, navigation, browser)

**Report path:** `~/Projects/Stage11/code/c11/upstream-triage/c11-1.0/06-grab-list.md`

Atin wants these pulled into c11 1.0 without a separate debate on each: "We should just grab anything we want here." Scope each one concretely, in this order:

1. **CLI and socket hardening:** strict socket arguments (#13214), stable IDs and stale short refs (#13247, #13633), `--command` on `new-split`/`new-pane`/`new-surface` (#9614), `paste --submit` with a delivered or queued result (#14837, #13849), `read-selection` (#10022), `resize-window` (#9826), `--window` routing (#4211), batch `reorder-workspaces --dry-run` (#4507), `capabilities`/`guide`/`--skill`/`rpc`, and `config doctor` with a JSON schema. c11 has already done some of this, for example rejecting empty or missing tab refs. Mark each item as already-done, partial or missing.
2. **Restore hardening:** `agents.launchers` (wrapper launchers such as multi-account routers resume through the wrapper) and `launch_rejection_reason`. Relate this to c11's restart registry and conversation store, and to Atin's real case: per-call-sign Claude wrappers and accounts.
3. **Workspace groups** (0.64.11): collapsible, colored, iconed sidebar groups with unread badges, plus the `workspace-group` CLI. Atin likes this one.
4. **Navigation:** focus history (back and forward), Recently Closed, and Cmd+Shift+T to reopen. Atin is "very interested in maintaining focus history."
5. **Basic browser updates:** profiles, import from other browsers, passkeys, a URL allowlist, and a WebKit process per pane. Flag Design Mode and the standalone cmux Browser build as beyond basic, and leave them out of scope.
6. **AI naming of workspaces:** Atin thinks c11 already has this. Verify, and note any gap against cmux's version (0.64.16).

For each item: what cmux did (with PR and code), what c11 has today (with file references), the proposed c11 shape, effort (S/M/L), and dependencies between items.

Out of scope, skipped by Atin: the diff viewer, file tools, iOS Simulator panes, computer use, saved layouts, the automations engine, `cmux events`, `cmux current`, Vault and Fork Conversation.
