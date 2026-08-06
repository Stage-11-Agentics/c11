# C11-194 plan (rev 2 — operator sequencing decision, 2026-08-06)

C11-194 lands first and owns the shared launch-cwd resolver. C11-193 consumes
that value and adds warning policy; C11-195 consumes the same value for project
configuration lookup.

1. Keep one provenance-carrying resolution ordered as explicit `--cwd` →
   workspace root → launching-surface cwd. The exact resolved path must drive
   surface creation and downstream consumers; rootless workspaces retain the
   launching-surface fallback.
2. Persist an optional normalized workspace root with backward-compatible
   decoding. Make it settable at creation, editable/clearable later without
   focus changes, and expose it in `list-workspaces --json` and
   `identify --json`.
3. Define intent at the resolver boundary: `.explicit` and `.workspaceRoot`
   are explicit intent; `.launchingSurface` is inherited. This distinction is
   consumed by C11-193's warning copy but does not change cwd precedence.
4. Test all three precedence levels, rootless fallback, root persistence, and
   legacy snapshots. Validate creation/edit/clear and JSON exposure in a
   tagged app.
5. Update the c11 API reference and launch documentation. Sync the installed
   c11 skill after the committed source change.

Non-goals: requiring roots on old workspaces, removing the surface-cwd fallback,
or deciding linked-worktree policy inside the workspace model.
