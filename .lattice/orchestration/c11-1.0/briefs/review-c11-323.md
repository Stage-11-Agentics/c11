# Review: C11-323 (agents never change the operator's visible workspace; TOP PRIORITY), cycle 1

Follow `reviewer-common.md` in this directory (mailbox tab:210). Title `C11-323 Review Astra`. Actor `agent:astra-review-323`. Owner: Claude Sonnet (rolled over from Codex Sol).

- PR https://github.com/Stage-11-Agentics/c11/pull/564, head `6ccc2a81212ec84fc3af6eb581407f04bae0308a`, base = merge-base with origin/main.
- Spec: the ticket (`lattice show C11-323`), scope items 1-7 and the acceptance list. Validation: the Lattice validation comment (Atlas tests; guest replay with CLI and raw v1/v2 refused and attributed; background work OK; operator UI paths shortcut, sidebar, palette, notification, jump, menu and close_fallback proven; not proven: the restore-cause UI and timing).
- Focus: one gate in the selection setter that refuses every socket-originated workspace switch in any window, with no setting and no override; every operator path still switches (check each by code path, not only the replay); in-workspace focus and background work stay allowed; `focus-area` / `focus-tab` on a background target update that workspace without selecting it; the side-effect switches are removed (c11 ssh, tmux shim select-window/select-pane, the tmux -t resolver, find-window --select, app activation in workspace.select); attribution fields on `workspace.selected` and the `workspace.switch_blocked` event; close fallback to most-recently-seen; the shared focus-allowance stack race confirmed or ruled out with evidence; skill, api.md, events.md and CLAUDE.md updated.
- Typing paths untouched (CLAUDE.md). Socket focus policy respected.
- This fleet drives c11 through the socket: confirm nothing in skills/ or scripts/ relies on agent workspace switching.
- Break the gate and confirm a test goes red.
- Reply `VERDICT C11-323 PASS|FAIL <head> <artifact>` to tab:210.
