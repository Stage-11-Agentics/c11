# C11-194 plan

1. Trace workspace creation, editing, persistence, socket serialization, `list-workspaces --json`, `identify --json`, and launch-agent cwd resolution.
2. Add an optional workspace root directory with backwards-compatible decode/default behavior.
3. Make the root settable at creation and editable afterward without stealing focus; expose it in the required JSON payloads and update the c11 skill contract for any CLI/socket changes.
4. Centralize and test cwd precedence: explicit `--cwd`, workspace root, then launching-surface cwd.
5. Run narrowed `c11-logic` tests, validate any changed skill JSON/docs as applicable, sync installed skills if edited, and run the proportionate broader safe logic gate.

Non-goals: requiring roots on existing workspaces or removing the current surface-cwd fallback.
