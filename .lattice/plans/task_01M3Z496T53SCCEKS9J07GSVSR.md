# C11-323: Agents never change the operator's visible workspace

## Why
Agents keep switching Atin's visible workspace while he works. On 2026-10-02, between 19:52 and 19:56 UTC, he was pulled to "LAT-365 Runtime Proof" four times and went back after 7 to 14 seconds each time. The cause was the Lattice "Inbox Builder" Codex agent (tab 313, LAT-365). It ran `c11 select-workspace` to put its proof browser (tab 349) on screen, because a browser in a background workspace is hidden and its poller and video pause. He had no way to tell who did it.

Operator rule (Atin, 2026-10-02): **c11 never changes the operator's visible workspace unless the operator asked for it directly** (sidebar, keyboard shortcut, command palette, notification click, jump-to-unread, menu). Agents keep full power over background work. Creating, sending, browser eval/click/snapshot, metadata, and focus changes inside a background workspace all keep working. Only the visible switch is blocked.

## Evidence
Survey of origin/main, 2026-10-02:
- Every switch goes through `TabManager.selectedTabId` `didSet` (`Sources/TabManager.swift:917-1060`).
- The socket gate is `focusIntentV1Commands` / `focusIntentV2Methods` plus `withSocketCommandPolicy` (`Sources/TerminalController.swift:241-267, 480-520`). Any process in a c11 terminal passes it.
- Agent-reachable switches:
  - `workspace.select` (`SH/WorkspaceHandlers.swift:258-296`), which also activates the app. v1 `select_workspace` (`TC:6469-6488`).
  - `workspace.next/previous/last` (`SH/WorkspaceHandlers.swift:631-705`).
  - `surface.focus` (`SH/SurfaceHandlers.swift:253-275`) and `pane.focus` (`SH/PaneHandlers.swift:99-119`), when the target is in another workspace.
  - `browser.focus_webview` (`SH/BrowserQueryHandlers.swift:121-160`).
- CLI side effects:
  - `c11 ssh` always selects (`CLI/c11.swift:5946`); so does `find-window --select` (`:15982`).
  - The tmux shim maps `select-window` / `select-pane` to selection (`:15485-15499`).
  - The tmux target resolver calls `workspace.last` just to resolve `-t !`, `^` or `-` (`:14828-14829`).
  - The global `--window` flag is fixed by C11-283.
- Close fallback: when the visible workspace closes, selection moves to the next workspace by index, not the last one seen (`TM:2651-2657, 2680-2683`).
- Attribution: the `workspace.selected` payload is only `{previous}`. There is no cause and no caller (`Sources/Events/EventEmitter.swift:106-110`). Debug-only trigger labels already exist at `TM:3746-3754`. `flag.raised` already carries a caller surface id.
- Docs drive the behavior:
  - `skills/c11/references/api.md:252` and `:425` tell agents to run `select-workspace … && sleep 2` to start a hidden surface. That advice is stale since C11-114.
  - `events.md:50` calls the event a "sidebar switch".
  - The documented `--no-focus` does nothing anywhere.
- Possible race (unconfirmed, C11-140 §A): the focus-allowance stack is shared across connection threads (`TC:175-176, 470-520`). Worker-thread methods could read "allowed" while another connection's focus command is on the stack.

## Scope
In:
1. **One gate in the selection setter.** A socket-originated change to the selected workspace of any window is refused. Error code `workspace_switch_blocked`; the message tells the agent to raise a flag if it needs the operator. Operator paths are unaffected (sidebar, shortcuts, palette, notification click, jump-to-unread, menu bar, launch restore).
   - `select-workspace`, `next/previous/last-window` and `focus-webview` across workspaces return the error.
   - `focus-area` / `focus-tab` (below) on a target in a background workspace still update that workspace's focused area and tab, and do not select the workspace. Within the visible workspace they work as today. That is allowed and wanted.
   - No setting and no agent override flag. Hard block (Atin's choice).
2. **Remove side-effect switches.** `c11 ssh` stops selecting. The tmux shim's `select-window` stops selecting, and its `select-pane` focuses within its own workspace only. The tmux `-t` resolver resolves without navigating. `find-window --select` follows the gate. App activation is removed from `workspace.select`.
3. **Rename cleanup** (the area/tab rename missed these): `focus-pane` → `focus-area`, `focus-panel` → `focus-tab`. Keep the old names as hidden aliases. Update help, skill and api.md.
4. **Attribution.** `workspace.selected` gains `cause` (`sidebar|shortcut|palette|notification|jump|menu|socket|close_fallback|restore|create`), plus `method` and `caller_tab_id` when the cause is socket. Add `workspace.switch_blocked` `{target, method, caller_tab_id}` for refused attempts. Then `c11 events tail` answers "who did that". Update `events.md`.
5. **Close fallback** selects the most recently seen workspace (focus history), falling back to the index neighbour.
6. **Race.** Confirm or rule out the shared focus-allowance stack race. If it is real, make it per-thread or per-request.
7. **Docs and skill.**
   - Remove the `select-workspace` init advice from api.md. Add a hard rule to SKILL.md: agents never change the operator's workspace; background tabs are fully drivable.
   - Make `--no-focus` real for in-workspace focus, or remove it from the docs.
   - Fix the "Socket focus policy" section of `CLAUDE.md`.
   - Run `scripts/sync-installed-skills.sh c11`.

Out: keeping a background browser running while hidden (separate backlog ticket). The `--window` focus fix (C11-283). The `settings.open` default activation (C11-140).

## Acceptance
- With the operator on workspace A, an agent in workspace B runs, through the CLI and raw socket v1/v2:
  - `select-workspace A2`, `next-window`, `last-window`, `focus-tab`/`focus-area` on a tab in workspace C, `browser <s> focus-webview` in C, `c11 ssh`, and tmux `select-window`.
  - Workspace A stays selected and the app is not activated.
  - The two focus commands update C's focused tab and area.
  - Each refused call returns `workspace_switch_blocked` and logs `workspace.switch_blocked` naming B's calling tab.
- Background work is unchanged: `send`, `browser eval/click/snapshot`, `new-surface`, `launch-agent`, and `set-metadata` against a background workspace all succeed without a switch.
- Sidebar click, Cmd+number, palette and notification click still switch, and their `workspace.selected` events carry the right `cause`.
- Closing the visible workspace lands on the last-seen workspace.
- Runtime proof on a tagged build through the real UI (c11-computer-use): screenshots before and after an agent's blocked `select-workspace`.
