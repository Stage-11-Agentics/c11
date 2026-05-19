# Changelog

All notable changes to c11 (and, before the fork, cmux) are documented here.

Note: historical entries below pre-date the `c11mux` → `c11` rename and reference the old binary / cask / artifact / bundle-ID names (`cmux`, `c11mux`, `c11mux-macos.dmg`, `stage-11-agentics/c11mux`, `com.stage11.c11mux`). Those entries are preserved as-is for historical accuracy; see the 0.38.0 section for the rename.

## [Unreleased]

## [0.49.1] - 2026-05-19

Patch release. Two correctness follow-ups to v0.49.0: a SwiftUI render-thread crash from a `Text + Text` concat path in the workspace chrome, and a restored-session execution bug where `c11 restore` typed the resume command into the recipient surface's prompt but never submitted it.

### Fixed

- **`Text + Text` recursion no longer blows the render-thread stack.** A concat path in the workspace chrome (sidebar + pane interaction card) recursed through SwiftUI's `Text + Text` operator deeply enough to overflow the render thread on some configurations, taking the window down. Switched the construction to a flattened form. ([#195](https://github.com/Stage-11-Agentics/c11/pull/195))
- **`c11 restore` now actually executes the resume command on restored surfaces.** `TerminalSurface.sendText` wraps every write in bracketed-paste markers (`ESC[200~ … ESC[201~`), so any embedded `\n` or `\r` is treated as data by zsh ZLE / bash readline / TUI raw-mode handlers and never submits. Session restore was typing the `claude --resume <id>` command into the prompt and then leaving it stranded — every restored Claude Code surface came up showing the resume line waiting for the operator to press Enter. The restart-registry executor now dispatches a real Return outside the bracketed-paste sequence so the command actually runs. ([7cb87a5e6](https://github.com/Stage-11-Agentics/c11/commit/7cb87a5e6))

### Built and shipped by

Stage 11 Agentics. Operator:agent, fused.

## [0.49.0] - 2026-05-19

Stability + ergonomics release. Headline: **worktree and branch chips on every workspace's sidebar row** make git context visible at a glance — the operator running parallel worktrees never has to read `cwd` to know which workspace is on which branch. Underneath, the long-running C11-105 mystery is closed out: the c11 CLI socket no longer goes unreachable while the app is alive. State-directory migration from c11mux gets a per-entry merge so mixed-state homes survive. `c11 send` learns to submit by default — agents that drop the `send-key enter` follow-up no longer leave messages stranded in the recipient's input box. Workspace snapshots now persist browser surface URLs across restore. Terminal links pick up an Opt+click escape hatch to the system browser. Update pill opens its popover on the first click. And the close-workspace confirm overlay actually shows up when the target workspace is off-screen.

### Added

- **Worktree and branch sidebar chips on every workspace.** The sidebar surfaces each workspace's current git branch alongside a worktree indicator, color-hinted so worktrees are visually distinct from the main checkout. The operator running parallel worktrees no longer has to read `cwd` to know which workspace is on which branch. ([#181](https://github.com/Stage-11-Agentics/c11/pull/181))
- **Opt+click on a terminal link forces the system default browser.** Adds an Option/Alt modifier override at the `GHOSTTY_ACTION_OPEN_URL` routing site so a single click can bypass `BrowserLinkOpenSettings` (cmuxBrowser default, host whitelist, regex patterns) and open externally. `Cmd+click` behavior is unchanged. ([e45489764](https://github.com/Stage-11-Agentics/c11/commit/e45489764))

### Changed

- **`c11 send` now submits by default.** The previous behavior typed text into the recipient's PTY but never appended Return — every sender had to follow up with `c11 send-key enter`, and agents missed the second call repeatedly in practice. The text would land in the recipient's input box and sit unsubmitted, blocking the workflow. `send` now types AND submits in one call. Pass `--no-submit` when you genuinely want to type without executing (partial-line construction, staging text before manual Enter). The matching skill examples collapse from two calls to one. ([#185](https://github.com/Stage-11-Agentics/c11/pull/185))
- **State-directory migration is now per-entry, not blanket-copy.** Users with both a legacy `~/.c11mux/` state dir and a partial `~/.c11/` from earlier sessions used to get one or the other; the migration now merges entry-by-entry so neither side overwrites the other. ([#179](https://github.com/Stage-11-Agentics/c11/pull/179))
- **Default agent prompt now orients new sub-agents before the c11 skill loads.** Sub-agents launched into a c11 surface get a brief orientation pass (workspace/surface refs, role context) up front so the first turn isn't spent rediscovering the environment. ([#178](https://github.com/Stage-11-Agentics/c11/pull/178))
- **Update pill opens its popover on the first click for background-detected updates.** Previously a background-detected update required two clicks: one to "wake" the pill, one to actually open. Now opens directly on first click. ([ff2711b6d](https://github.com/Stage-11-Agentics/c11/commit/ff2711b6d))

### Fixed

- **CLI socket no longer goes unreachable while the app is still alive (C11-105).** Root cause: `TerminalControllerSocketSecurityTests.swift` was a member of the `c11LogicTests` target despite living in `c11Tests/` on disk. Its `setUp` calls `TerminalController.shared.stop()`, and `TerminalController.socketPath` was default-initialized to the stable production socket path — so any local `xcodebuild -scheme c11-logic test` run would `unlink()` the prod c11's bind dentry while its FD stayed live in-kernel. Symptom: every `c11 <cmd>` errored with `Socket not found at ~/Library/Application Support/c11/c11.sock` even though the app process was running and the UI / panes / agents were fully interactive. The fix moves the test back into `c11Tests`, empties the field's default, and gates `stop()`'s unlink on a non-empty path. A kqueue diagnostic remains in `tools/socket-watcher/` as a canary for any future unlink source. ([#180](https://github.com/Stage-11-Agentics/c11/pull/180))
- **Workspace snapshots now persist browser surface URLs across restore.** `SurfaceSpec.url` was dropped in `WorkspacePlanCapture` so any browser pane restored from a snapshot landed on a blank new-tab. The capture now round-trips the URL alongside the rest of the surface spec and the previously-disabled `testCaptureAndRestoreBrowserFirstLayout` is re-enabled in CI. ([#184](https://github.com/Stage-11-Agentics/c11/pull/184))
- **Close-workspace confirm overlay actually shows up when the target workspace is off-screen.** Off-screen workspaces are `isHidden=true` (the perf #127 visibility gate); their `AnchorView` does not report a window-coord frame, so the overlay controller bailed silently and the operator saw "I clicked Close, nothing happened." The host-vs-target split now anchors the overlay on the currently-displayed workspace; the dialog message already names the workspace being closed, so the anchor change doesn't lose context.
- **Sidebar first workspace row no longer has its highlight clipped by the top scrim.** The blur-gradient scrim that sits over the traffic-light strip is still ~40% opaque where the first row's rounded-corner highlight used to land, so the corners read as cut off. The first row now begins past the scrim's significant-opacity band; the scrim itself is unchanged.
- **Custom titlebar text now sits symmetrically inside its bar.** The previous frame + asymmetric top padding made "Workspace 1" read bottom-heavy against the 1pt bottom border. The text now centers within `titlebarPadding` so the breathing room above and below is equal.
- **Bonsplit drag-and-drop UTTypes are now declared in `Info.plist`.** Resolves the runtime warning "Type was expected to be declared and exported in the Info.plist" emitted on every Bonsplit `UTType(exportedAs:)` construction. Cheap on Apple Silicon, expensive on shared-tenant CI runners — fix also unblocks a slow test that the warning storm was paging over its timeout. ([#182](https://github.com/Stage-11-Agentics/c11/pull/182))

### Built and shipped by

Stage 11 Agentics. Operator:agent, fused.

## [0.48.0] - 2026-05-18

Feature release. Headline: **default terminal agent** — a workspace-scoped + user-scoped resolver so the A-button on every new terminal opens the right tool for the job (claude, codex, gemini, kimi, raw shell) without the operator picking each time. Alongside it, a second menu-bar pass: the File menu now leads with New Workspace (the real entry point for new work), Open Folder retires, New Window moves to View where it sits with the rest of the chrome toggles, Close Other Tabs lands in Pane where the verb actually applies, and the Browse panel inside New Workspace now offers the New Folder affordance so starting a workspace can include creating its directory. Plus: About c11 inside Help, Full Disk Access auto-detect, faster workspace switching, tab close X moved to the left.

### Added

- **Default terminal agent: workspace-scoped + user-scoped resolver.** Every new terminal launches the right agent without the operator picking each time. User default lives in Settings → Agents; per-project override is discovered from `.c11/default-agent` (or `.cmux/default-agent`) when present, so a repo can declare "use codex here." The resolver threads through the CLI, the Workspace model, the New Surface menu, and the Settings UI. The Agents sidebar page is the single canonical home; the old per-action launcher knobs are gone. ([#168](https://github.com/Stage-11-Agentics/c11/pull/168), [#173](https://github.com/Stage-11-Agentics/c11/pull/173))
- **`C11_DEFAULT_AGENT_LAUNCH` exported in every new shell.** Resolved per-shell at spawn time so the c11 skill can teach a single sub-agent launch pattern (`exec $C11_DEFAULT_AGENT_LAUNCH`) regardless of which agent the operator picked. Preference changes only affect newly-spawned shells. ([#173](https://github.com/Stage-11-Agentics/c11/pull/173))
- **New Workspace in File menu.** The canonical entry point for starting a new work item now sits where users instinctively reach for it. Duplicates the Workspace menu entry so discovery is doubled, shortcut binding unchanged. ([#168](https://github.com/Stage-11-Agentics/c11/pull/168))
- **New Folder affordance inside the Browse panel of New Workspace.** Starting a workspace can now include creating its directory in the same flow — the NSOpenPanel's New Folder button shows up where previously the panel was browse-only. ([#168](https://github.com/Stage-11-Agentics/c11/pull/168))
- **About c11 lives inside the Help menu, in addition to the c11 app menu.** macOS auto-injects a Help menu (with its search field) whenever the slot is empty and SwiftUI can't reliably suppress it; populating the slot with a real action makes the menu earn its space. About c11 still lives in the c11 app menu too. ([#170](https://github.com/Stage-11-Agentics/c11/pull/170))
- **Tab close X has a right-click menu with Close Tab + Close Pane.** Right-click the X to disambiguate "close this tab" from "close this whole pane" without remembering modifier keys. The X itself anchors on the left of the tab to match macOS convention. ([#165](https://github.com/Stage-11-Agentics/c11/pull/165))
- **Full Disk Access grant is now runtime-detected, auto-continuing the TCC primer.** The primer no longer requires the operator to click Continue after granting FDA in System Settings — c11 detects the grant and advances the primer on its own. ([#138](https://github.com/Stage-11-Agentics/c11/pull/138))

### Changed

- **New Window moves from File to View.** Window-level toggles cluster with chrome controls (Toggle Sidebar, Appearance, Titlebar Controls); File is now reserved for new-work verbs. Shortcut binding unchanged. ([#168](https://github.com/Stage-11-Agentics/c11/pull/168))
- **Close Other Tabs in Pane moves from File to Pane.** The verb's "in Pane" now actually lives in the Pane menu, ⌥⌘T preserved. ([#168](https://github.com/Stage-11-Agentics/c11/pull/168))
- **Open Folder retires from the File menu.** New Workspace covers the same flow with the blueprint picker and agent-launch toggle; the Command Palette entry and Keyboard Shortcut Settings row remain intact for muscle-memory carryover. ([#168](https://github.com/Stage-11-Agentics/c11/pull/168))
- **Workspace switching is faster after Phase 4a perf work.** Empty deferred portal-sync passes are now short-circuited so swapping between workspaces feels snappier, especially when the destination workspace's surfaces are already settled. ([#135](https://github.com/Stage-11-Agentics/c11/pull/135))
- **Sidebar "Next Notification" button is taller (2× vertical) for prominence.** Easier to spot, easier to hit when triaging an unread queue.
- **`c11mux` is gone from active code paths.** State directory migration, theme rename, and test fixes complete the c11mux → c11 transition begun in 0.38.0. Anyone still on a c11mux state dir is silently migrated. ([#164](https://github.com/Stage-11-Agentics/c11/pull/164))

### Fixed

- **Close Pane confirmation no longer shows literal "%lld" instead of the pane count.** The body string had an unsubstituted printf token that surfaced when the dialog actually rendered (e.g., "This will close 7 panes" showed up as "%lld panes"). Now formats correctly. ([b03f12592](https://github.com/Stage-11-Agentics/c11/commit/b03f12592))
- **App Hang triggers around the Sparkle probe and persistent flash are now instrumented.** Internal observability lift so hang patterns we'd been chasing in support reports get attributed to the right culprit. ([#169](https://github.com/Stage-11-Agentics/c11/pull/169))

## [0.47.1] - 2026-05-15

Hotfix release. Triggered by a New Workspace dialog regression observed in the 0.47.0 prod build (the dialog opened tiny on first show — only snapped to its intended size after focus moved away and back). The fix went out alongside a batch of operator-facing polish that had stacked up on `main` over the same day: a second-pass on the New Workspace dialog, a macOS menu-bar reorganization, and a few smaller correctness fixes.

### Added

- **Workspace name field on the New Workspace dialog.** The dialog now collects a workspace name alongside the working directory. Empty input falls back to the directory's basename; the placeholder previews the fallback so the operator can see what they'd get without committing. Threads through `WorkspaceSpec.title → Workspace.setCustomTitle` — the existing custom-title plumbing, no new persistence surface. ([#160](https://github.com/Stage-11-Agentics/c11/pull/160))

- **Top-level Workspace, Pane, and Browser menus on the macOS menu bar.** Workspace-scoped actions (New Workspace, Rename, Pin, Move, Hibernate, Mark Read/Unread, Workspace 1–9) live under their own Workspace menu instead of being sprinkled across File / View / Window. Pane-scoped actions (splits, focus moves, zoom, new surface, surface navigation, Rename Tab) move out of Window and into a dedicated Pane menu. Browser actions (Back / Forward / Reload / Zoom / Reopen Closed Browser Pane / DevTools / Import Browser Data) get their own Browser menu. The top bar now reads: 🍎 c11 File Edit View Workspace Pane Browser Notifications Window. ([#161](https://github.com/Stage-11-Agentics/c11/pull/161))

### Changed

- **New Workspace dialog UX pass.** "Layout selection" / "Saved blueprints" headers renamed to **Default layouts** / **Custom blueprints** to clarify the split between starters c11 ships and what the operator (or repo) has saved. The Recent-directories control is now an always-visible bordered menu button labelled `Recent` with a clock icon (was a flat glyph that vanished entirely on fresh installs when the recents list was empty); the empty state shows a single disabled "No recent directories yet" item so the affordance stays discoverable. Browse… upgraded to a bordered button with folder icon at `.controlSize(.large)` so it reads as a primary action next to Recent rather than as inline text. Hint copy under the name field tightened to the c11 register. ([#160](https://github.com/Stage-11-Agentics/c11/pull/160))

- **`agent-room` built-in blueprint reshuffled.** Browser moves to **top-right** and a server-terminal surface moves to **bottom-right** (was: log-tail top-right, browser bottom-right) — the browser is the higher-glance-rate surface and earns the eye-line slot. Browser defaults to `https://www.stage11.ai` instead of a blank new-tab so the workspace has a recognisable orient point on first run. Surface titles renamed to onboarding-friendly placeholders (`example main terminal` / `example browser` / `example server terminal`) — operators rename them once each pane has a purpose; the placeholder names tell newcomers what the layout is *for* without making them read the description. ([#160](https://github.com/Stage-11-Agentics/c11/pull/160))

- **Close-workspace confirm dialog now names the workspace and defaults to Cancel.** The destructive confirm card previously read "This will close the workspace and all of its panes." with the workspace identity supplied only by the surrounding scrim; it now reads "This will close the workspace "Foo" and all of its panes." and the keyboard default is **Cancel** rather than Close — destructive actions stop being a Return-press away.

- **Promoted Appearance Mode picker, Titlebar Controls Style picker, and Always Show Shortcut Hints toggle from the DEBUG-only Debug menu into View.** These are production-relevant — they shouldn't have lived behind a debug-build gate. ([#161](https://github.com/Stage-11-Agentics/c11/pull/161))

### Fixed

- **New Workspace dialog opens at full size on first show. Prod-build-only regression.** The dialog rendered tiny on first show (~200pt tall — only the middle slice of layout rows visible) and only snapped to its intended ~600pt size after focus moved off and back. Two compounding causes: (1) `presentCreateWorkspaceSheet` assigned an `NSHostingView` to `window.contentView`, which pins the window at its initial 600×480 content rect and never propagates SwiftUI's intrinsic size back to the `NSWindow`; (2) `CreateWorkspaceSheet` seeded `@State entries` to `[]` and loaded them in `.onAppear`, so the first SwiftUI layout pass measured an empty layout-options list. Fix switches to `NSHostingController` with `sizingOptions = [.preferredContentSize]` (window content size now tracks SwiftUI's intrinsic size reactively) and seeds entries + recents synchronously in `init` via a new static `computeEntries(forDirectory:)`. The bug only surfaced in the 0.47.0 prod build — dev and staging builds masked it via release-mode timing differences in the hosting-view layout handshake. ([#159](https://github.com/Stage-11-Agentics/c11/pull/159))

- **Mailbox `stdin` delivery actually submits to the recipient.** The `stdin` mailbox handler was writing the framed `<c11-msg>` block via `terminalPanel.sendText`, which Ghostty wraps in bracketed-paste markers — by design suppressing embedded `\n`/`\r` so TUI raw-mode handlers and shell line discipline don't auto-execute pasted content. Result: the block landed in the recipient's input box but was never submitted until a human pressed Return, defeating the point of stdin delivery. The production writer in `startMailboxDispatcher` now uses `TextBoxSubmit.send`, the same helper `scheduleAgentRestart` uses for exactly this reason: it bracketed-pastes the content, waits 200ms (the documented minimum for Claude CLI's paste-processing), then dispatches a synthetic Return. The `skills/c11/SKILL.md` "Opting in to stdin delivery" snippet documents the canonical `mailbox.delivery=stdin` form (comma-separated string, not JSON array — `["stdin"]` silently registers zero handlers). ([#158](https://github.com/Stage-11-Agentics/c11/pull/158))

- **Tab Bar chrome modes (shrunk / hidden) removed; canonical state is Full.** `TabBarChromeState` enum, `TabBarChromeSettings` helper, the `tabBarChromeStateRaw` AppStorage key, `cycleTabBarChromeState()`, the `Action.toggleTabBarChrome` action, the `TabBarChromeHandle` overlay, and the unused `Workspace.setTabBarVisible(_:)` are all deleted. Users on shrunk/hidden are silently migrated to Full. The two non-Full modes were rarely set deliberately and routinely produced "where did my tabs go" support questions. ([#161](https://github.com/Stage-11-Agentics/c11/pull/161))

- **Surface title bar's description region sizes to its content and only scrolls when capped.** Previously, the description's container had an unconditional minimum width that produced a long empty stripe when the description was short or empty, and content that *did* exceed the cap fought layout. Region now collapses to fit its text and only engages the scroll cap when the description's natural width would otherwise overflow.

- **⌘R now reloads the browser surface (was: previously bound to another action).** Frees Reload for its native-app convention while still routing through the c11 keymap.

- **Help menu removed.** The Help menu was empty (no items) and only existed to satisfy AppKit's default menu structure. macOS hides empty Help menus from the menu bar; the explicit `CommandGroup(replacing: .help) { }` makes the absence intentional rather than incidental. ([#161](https://github.com/Stage-11-Agentics/c11/pull/161))

### Built and shipped by

Stage 11 Agentics. Operator:agent, fused.

## [0.47.0] - 2026-05-15

### Added

- **New Workspace dialog with layout blueprints + recents.** ⌘N, File → New Workspace, and the tab-strip / titlebar "+" buttons now open a dialog instead of materializing the legacy auto-quad. Pick a working directory, a layout (One column / Two columns / 2×2 / 3×2 / saved blueprints), and whether to launch the configured coding agent in the initial pane. Recently-used directories persist via UserDefaults and surface via a clock-icon menu beside Browse; cwd pre-fills from the focused workspace's current directory. Routes through the existing `WorkspaceApplyPlan` + `WorkspaceLayoutExecutor.apply` primitive — same path as socket `workspace.apply` and CLI `export-blueprint` — so saved user/repo blueprints surface automatically. `File → Open Folder…` keeps its immediate-create behavior for the power-user quick path. ([#146](https://github.com/Stage-11-Agentics/c11/pull/146))

- **`c11 doctor` CLI subcommand.** Surfaces CLI resolution state so you can diagnose path/launcher issues without spelunking: which `c11` / `cmux` is on PATH, what `CMUX_BUNDLED_CLI_PATH` points at, whether the path-fix has been applied, and an `ok | mismatch | missing | no_bundle` status. Pure-Swift collector with a thin CLI shim; JSON output uses lowercase-snake field names matching `c11 health --json`. The c11 skill's Troubleshooting blurb points at this command. ([#144](https://github.com/Stage-11-Agentics/c11/pull/144))

- **Right-click "Show surface manifest…" on every surface kind.** A new context-menu entry on terminal, browser, and markdown surfaces opens a read-only floating utility window that pretty-prints the surface's manifest JSON. Inspection is no longer CLI-only — one gesture to see what each surface advertises (`role`, `status`, `task`, `model`, `progress`, `terminal_type`, `title`, `description`, plus any third-party keys from Lattice / Mycelium / agents). Live demos, debugging, and post-write verification all collapse to a right-click. ([#143](https://github.com/Stage-11-Agentics/c11/pull/143))

- **Workspace-scoped close-confirmation overlay.** Closing a workspace now presents a near-black scrim covering the entire workspace content area (the sidebar stays visible) with a centered Cancel / "Close Workspace" card. The previous pane-anchored confirmation card was correct for closing a single pane but undersized for tearing down an entire workspace; the new scrim makes the destructive scope unmistakable. 120–180 ms fade in/out, first-responder swallow, hit-test isolated to the overlay. ([#139](https://github.com/Stage-11-Agentics/c11/pull/139))

- **`Resources/bin/c11-spawn-agent` — server-side primitive for Autonomous Connections.** Portable bash script (macOS bash 3.2 / Linux bash 5+) that launches one Claude Code agent in a named tmux window on a dedicated `tmux -L agents` socket, so the agent fleet stays isolated from operator-driven tmux sessions and survives SSH detach on the host. Required flags: `--workspace`, `--window`, exactly one of `--prompt-file` / `--prompt`. Optional: `--cwd` (default `$HOME`), `--model` (default `claude-opus-4-7`), `--socket` (default `agents`). A duplicate-window guard refuses to clobber a live agent — re-running the same invocation errors out rather than racing against the running window. The script handles no credentials; auth is whatever `claude login` already wrote on the target host. Slice 1 of C11-36 (Autonomous Connections). ([#151](https://github.com/Stage-11-Agentics/c11/pull/151))

### Changed

- **High-frequency v1 telemetry sockets moved off the main-sync dispatcher.** Extends the v2 socket-worker pattern from C11-26 to the highest-volume v1 commands — `report_pwd`, `report_shell_state`, `report_git_branch`, `clear_git_branch`, `ports_kick`, and `agent_skills_*` — so they parse off-main and only hop to main for the actual UI mutation. Reduces main-queue contention under heavy concurrent shell-prompt updates from many panes. Part of the C11-4 audit-findings cleanup. ([#144](https://github.com/Stage-11-Agentics/c11/pull/144))

- **`claude` wrapper passes through Agent View subcommands.** Claude Code 2.1.139 (shipped 2026-05-11) introduced **Agent View** — `claude agents` opens a TUI dashboard, and `attach`, `logs`, `stop`, `kill`, `respawn`, and `rm` operate on the per-user supervisor's pool of background sessions by short id. The c11 `claude` wrapper at `Resources/bin/claude` was injecting `--session-id` / `--settings` into these invocations too, wedging the dashboard into spawning a fresh interactive session instead of listing existing background sessions. All seven subcommands now pass through unaltered; regular `claude` / `claude -c` / `claude --resume` still get session-id and hooks injection. ([#150](https://github.com/Stage-11-Agentics/c11/pull/150))

- **Agent-skills onboarding sheet now fires on app activation.** The skill-install prompt was previously reachable only from Help → Welcome — fresh installs took the auto-welcome path which silently bypassed it, so users with `~/.claude` (or any other supported agent installed) never saw the prompt. Now hooked into `applicationDidBecomeActive`, so both first-launch and "installed an agent after c11 was already running" surface the prompt. Idempotent (one prompt per launch; "Don't ask again" honored permanently); skipped under XCTest. ([#148](https://github.com/Stage-11-Agentics/c11/pull/148))

### Fixed

- **Pane-close confirmation overlay no longer mounts on the wrong pane after a sibling-close reflow.** Third bug in the C11-40 chain, caught in v0.47.0 staging validation. After #155 fixed "X click does nothing" by keeping anchors alive through SwiftUI's transient dismantle cycles, a second failure mode emerged: when a sibling pane closed and the survivors reflowed, the existing reportFrame paths fired *during* the reflow — SwiftUI's `updateNSView` and AppKit's `viewDidMoveToWindow` both called `convert(bounds, to: nil)` at moments when the conversion returned transient half-applied coordinates (a 461-wide pane briefly reporting a 923-wide frame; a survivor settling at origin (1124,-545) entirely below the visible window). No post-settle event corrected them, so the controller's `anchors` map stayed stale and the confirmation overlay mounted at whichever stale position the pane *used to be in*. `PaneCloseOverlayController` now keeps a weak hash table of every live AnchorView; after Bonsplit fires its authoritative `didClosePane`, the controller schedules a re-poll of every AnchorView's window-coord frame on the next runloop tick (and again at +60 ms to cover multi-layout-pass reflows). The deferred `convert()` hits settled geometry. ([#157](https://github.com/Stage-11-Agentics/c11/pull/157))

- **Pane close reliability — X click now always opens the confirm dialog, on any pane, in any state.** Three independent bugs converged into "click X, nothing happens" on busy or recently-rearranged panes. (1) The multi-pane close branch in `splitTabBar(_:didRequestClosePane:)` was calling `bonsplitController.closePane(pane)` without pre-loading `forceCloseTabIds`, so Bonsplit's `shouldClosePane` vetoed whenever any terminal in the pane reported `panelNeedsConfirmClose == true` (active PTY) — busy right-side panes (where agents run) silently absorbed the click while idle panes closed normally. Now mirrors the existing single-pane branch's force-close insert loop. (2) `AnchorView.reportFrame` called `removeAnchor` whenever its `NSWindow` transiently went nil during a SwiftUI split-tree reparent — the replacement `AnchorView` for the same `paneId` then settled without re-`reportFrame`, leaving the pane orphaned. (3) `AnchorRepresentable.dismantleNSView` called `removeAnchor` on every SwiftUI dismantle, so after closing a neighbor, the surviving panes' AnchorViews got dismantled as part of the sibling subtree swap and never recovered — every X click for the rest of the session was silently dropped until the user forced a window resize. C11-40, in two PRs: Mode A first, then Mode B once the harder anchor-lifecycle variant was isolated. ([#154](https://github.com/Stage-11-Agentics/c11/pull/154), [#155](https://github.com/Stage-11-Agentics/c11/pull/155))

- **New Workspace dialog now actually runs the agent command.** Same root cause as the close fix above, different surface: `AppDelegate.applyWorkspacePlanInPreferredMainWindow` injected `AgentLauncherSettings.shellCommand` into `SurfaceSpec.command` without a trailing newline; `WorkspaceLayoutExecutor`'s Phase 0 parity rule delivered it verbatim via `sendText`, so the agent command sat literally at the prompt instead of executing. The tab-bar **A** button worked only because `Workspace.launchAgentSurface` appended `"\n"` at its own call site. Layout-plan injection now mirrors that. ([#154](https://github.com/Stage-11-Agentics/c11/pull/154))

- **TCC primer no longer masked on debug bundle ids.** The legacy-preference migration in `AppDelegate.migrateLegacyPreferencesIfNeeded` was copying `cmuxWelcomeShown=1` from `ai.manaflow.cmuxterm` / `com.cmuxterm.app` into the c11 debug bundle (`com.stage11.c11.debug`) on first launch. That flag in turn suppressed the TCC primer on tagged builds — the C11-16 Codex-validation regression. Migration now skips when the bundle id ends with `.debug` (or contains `.debug.` for future tagged-debug forms), and an escape hatch `CMUX_DISABLE_LEGACY_MIGRATION=1` lets release bundles force-skip for CI fixtures and clean-install validation. ([#145](https://github.com/Stage-11-Agentics/c11/pull/145))

### Built and shipped by

Stage 11 Agentics. Operator:agent, fused.

## [0.46.0] - 2026-05-06

### Added

- **Hibernate Workspace + per-surface lifecycle (active / throttled / suspended / hibernated).** A right-click "Hibernate Workspace" / "Resume Workspace" entry on sidebar tabs, mirrored in the App menu's Workspace submenu, aggressively reclaims resources from workspaces you're not using. Browsers in non-focused workspaces detach their NSView so compositor cost drops to ~0%; hibernated workspaces snapshot to an NSImage placeholder and `WKWebView.close()` terminates the WebContent processes (~200 MB freed across two browsers in validation). Terminal renderers in non-focused workspaces drop to <2 Hz via libghostty `setOcclusion(false)` — ~3.3× CPU reduction on a producer pegging the render loop. Per-surface CPU and RSS now show in the sidebar (also exposed in `c11 tree --json` as `metrics.cpu_pct` / `metrics.rss_mb`) so you can see what's expensive at a glance. Hibernated workspaces persist across `c11 restore`; resume fires the URL exactly once. ([#125](https://github.com/Stage-11-Agentics/c11/pull/125))

- **Per-surface tab colors inside panes.** Right-click a tab → **Tab Color** submenu picks a swatch from the palette, opens the system color picker for a custom hex, or clears the color. The color follows the surface across reorder, cross-pane move, detach/reattach, cross-workspace move, and session restore. Programmatic control via `c11 surface-color {set|clear|get|list-palette}` and the `surface.set_custom_color` v2 socket method (non-focus-stealing). All new menu strings localized for ja / uk / ko / zh-Hans / zh-Hant / ru in both c11 and the Bonsplit tab strip. ([#124](https://github.com/Stage-11-Agentics/c11/pull/124))

- **App Chrome UI Scale (Compact / Default / Large / Extra Large).** Settings → Appearance → **App Chrome UI Scale** scales c11-owned chrome — sidebar workspace cards, the Bonsplit tab strip (titles, icons, accessories, item height, padding, close glyph, dirty indicator, notification badge, active-tab underbar), and the surface title bar — without touching Ghostty terminal cells, browser content, or markdown content. Default preset is byte-exact with the previous tab bar shell height (30 pt). Live update on UserDefaults change (Settings UI, `defaults write com.stage11.c11 chromeScalePreset large`, future migrations) via per-Workspace KVO; typing-latency hot paths (`TabItemView`) preserved by routing tokens through precomputed `let` parameters. Picker localized for en / ja / uk / ko / zh-Hans / zh-Hant / ru. ([#123](https://github.com/Stage-11-Agentics/c11/pull/123))

- **Persistent themable surface flash with custom color and duration.** `c11 trigger-flash --persistent` keeps a surface pulsing — sidebar row + pane content + Bonsplit tab strip in unison — until the operator clicks the pane or sidebar row to dismiss, or programmatic `c11 cancel-flash --surface <ref>` cancels it. Default flash color is yellow `#F5C518` with `--color <hex>` per-call override and a forward-compatible `flash.color` theme key. Settings → Notifications → **Flash Duration** slider (500–4000 ms, default 1500 ms) scales pane and sidebar pulses together. Click-cancel hook stays out of the keystroke path; persistent timers invalidate on close + deinit. ([#126](https://github.com/Stage-11-Agentics/c11/pull/126))

### Changed

- **Workspace switch latency: 1–6 s → ~325 ms median, 90 s tail eliminated.** Heavy switches were dominated by `-[NSView _layoutSubtreeWithOldSize:]` recursing ~30 levels deep across every mounted workspace's bonsplit pane tree, even when only one was visible (~64% of main thread time in production samples). Three landed phases attack this:
    - **Phase 0** wires an always-on `WorkspaceSwitchSignpost` (`os_signpost` subsystem `com.stage11.c11`, category `WorkspaceSwitch`) that graphs the switch path in Instruments.app, plus a release-safe `workspace.switch.complete` Sentry breadcrumb with `dt_ms` so production switch latency is observable.
    - **Phase 1** wraps every `WorkspaceContentView` in `AppKitHiddenWrapper` (`NSHostingController` whose `view.isHidden` tracks visibility). `_layoutSubtreeWithOldSize:` short-circuits at hidden subviews; off-screen workspaces' subtrees are skipped entirely. SwiftUI subtree is preserved — surfaces don't dismount, so terminal scrollback and browser state survive switches unchanged.
    - **Phase 2** skips the deferred portal bind when the host frame is zero, eliminating a second AppKit layout cascade triggered by `onDidMoveToWindow` after the first cascade had already settled.

  Real-world numbers, 11 workspaces / ~20 agents loaded, after Phases 0+1+2:

  | Metric | Baseline | After |
  |---|---|---|
  | `handoff.start` (SwiftUI cascade) | ~1,500 ms | 17–77 ms (~30–80×) |
  | `asyncDone` median | ~1,000 ms | ~325 ms (~3×) |
  | `asyncDone` p95 | ~6,000 ms | ~1,200 ms (~5×) |
  | `asyncDone` worst seen | 90,790 ms | 2,426 ms |

  Typing-latency hot paths (`TerminalSurface.forceRefresh()`, `TabItemView` Equatable/`.equatable()`, `WindowTerminalHostView.hitTest()`) verified intact. Phase 3 (split queued `selectedTabId.didSet` async block to defer non-essential work past the visible flip) is in flight on a separate branch and will land in a follow-up release. ([#127](https://github.com/Stage-11-Agentics/c11/pull/127), [#128](https://github.com/Stage-11-Agentics/c11/pull/128))

### Fixed

- **Claude Code session resume across c11 restart.** Two paired bugs broke session resume after the C11-26 socket dispatch refactor: the `claude` PATH wrapper resolution leaked into worktree subdirs, and a SessionEnd shutdown race could lose the final `claude.session_id` write. Restart now records `claude.session_project_dir` paired atomically with `claude.session_id` at SessionStart, validates the path on synthesis, and synthesizes `cd '<path>' && claude --dangerously-skip-permissions --resume <id>` only when the path is present and reachable. Existing surfaces with id-only metadata keep working unchanged. (`cc0f1fc5b`)

### Built and shipped by

Stage 11 Agentics. Operator:agent, fused.

## [0.45.2] - 2026-05-04

### Fixed

- **Silent c11 crashes from socket-handler self-deadlock (4× on 2026-05-04).** After C11-26 ([#112](https://github.com/Stage-11-Agentics/c11/pull/112)), the new socket dispatcher routes default-policy commands through `DispatchQueue.main.sync { MainActor.assumeIsolated { … } }` from the worker thread. About 100 v1 handlers in `TerminalController.swift` and 12 in `ThemeSocketMethods.swift` were written for the *pre*-C11-26 assumption that they were already on the worker, and each did its own `DispatchQueue.main.sync { … }` to hop to main. Post-C11-26 that hop is reentrant: libdispatch's self-deadlock guard (`__DISPATCH_WAIT_FOR_QUEUE__`) trapped with `EXC_BREAKPOINT` and the c11 window vanished silently. Apple's UI never saw it; only ghostty's bundled sentry-native breakpad in `~/.local/state/ghostty/crash/` recorded the dump. Operator hit this 4× on 2026-05-04 alone (builds 95/96/97). The earlier 14:26 IPS hang on 0.44.1 was the same class of bug pre-detection, on an older libdispatch that hung indefinitely (1673 s unresponsive) rather than trapping. Fix swaps the 99+12 bare `DispatchQueue.main.sync` sites for the existing `v2MainSync` helper (which short-circuits when already on main), and adds a parallel `Self.mainSync` to `ThemeSocketMethods`. Both helpers are correct under either dispatcher path. Two intentional bare-sync sites kept (the dispatcher itself and `v2MainSync`'s own implementation). New regression test `tests_v2/test_v1_handler_main_self_deadlock.py` exercises 30 successive `set_progress` calls plus a spread of 7 v1 handlers; all return `OK`. ([#121](https://github.com/Stage-11-Agentics/c11/pull/121))

### Changed

- **CMUX-37 final push: blueprint markdown, `snapshot --all` manifests, CLI ergonomics.** Closes the five gaps from the 2026-05-03 smoke-test of CMUX-37. Workspace blueprints now have a markdown parser/writer and default to `~/.config/c11/blueprints/` (legacy paths still read). `c11 workspace snapshot --all` writes a manifest envelope and `restore <set-id>` is polymorphic on the id, rebuilding all workspaces in one shot. Clean restores no longer emit redundant `failure:` lines (expected restore diagnostics are reclassified as info). `c11 workspace <subcommand> --help` routes through a two-level dispatch instead of dumping the top-level help. The CLI honors `C11_SOCKET` (legacy `CMUX_SOCKET` still works), with auto-discovery logged to stderr. ([#118](https://github.com/Stage-11-Agentics/c11/pull/118))

### Built and shipped by

Stage 11 Agentics. Operator:agent, fused.

## [0.45.1] - 2026-05-04

### Fixed

- **Silent c11 crashes from Metal scheduler abort on surface destruction.** c11 was vanishing without a dialog under heavy multi-pane / multi-workspace use — three identical SIGABRTs on 2026-05-04 alone, including one that hit v0.45.0 within 22 minutes of launch. PC was inside `Metal::MTLSchedulerRequest::release()+84`, dispatched from a block in `MTLSchedulerRequest::generateMonolithicBlock`. Apple's UI never showed because ghostty's bundled sentry-native (breakpad) installs after Sentry-Cocoa, so it caught the signal first, wrote a minidump under `~/.local/state/ghostty/crash/`, and `_exit`ed cleanly. Root cause was in the ghostty Metal renderer: `Metal.deinit` released `MTLCommandQueue` immediately after `SwapChain.deinit`'s frame semaphore returned, but that semaphore only proves Metal completion blocks have *started* on the scheduler thread — not that the surrounding scheduler trampoline has fully unwound. Releasing the queue mid-unwind tripped a defensive abort. Fix detaches the layer's display callback, drains the queue with a synchronous no-op command buffer (`commit` + `waitUntilCompleted`), and reorders release so the layer drops pending presentation before the queue is freed. Sub-millisecond cost per surface destruction, no typing-latency hot paths affected. Investigation log preserved at `notes/metal-crash-investigation.md` so a recurrence has a head start. ([#119](https://github.com/Stage-11-Agentics/c11/pull/119))

## [0.45.0] - 2026-05-04

### Added

- **Force-Quit / unclean-exit detection.** A per-launch JSON sentinel under `~/Library/Caches/<bundle-id>/sessions/`; if the previous launch never reached `applicationWillTerminate`, the marker is archived as `unclean-exit-<ts>.json` on next launch. Catches the failure modes Sentry's in-process handler can't see — Force Quit, SIGKILL, jetsam, watchdog kills, and silent GUI exits where no `.ips` file is written. Telemetry-independent by design: the file never leaves the machine. Foundation for the upcoming `c11 health` CLI. ([#109](https://github.com/Stage-11-Agentics/c11/pull/109))

- **MetricKit crash channel.** `CrashDiagnostics` (an `MXMetricManagerSubscriber`) now persists `MXCrashDiagnostic`, `MXHangDiagnostic`, `MXCPUExceptionDiagnostic`, and `MXDiskWriteExceptionDiagnostic` payloads to `~/Library/Logs/c11/metrickit/` unconditionally; Sentry breadcrumb forwarding stays gated on telemetry consent. Closes the visibility gap between Sentry's in-process crash handler and the OS-level kills it never sees.

### Changed

- **Menu bar icon: c11 mark, surface-aware tooltip, no Integrations submenu.** Replaces the upstream chevron with the c11 "open-center plus" derived from the app icon, retuned to a square `(1.0, 1.0, 11.0, 11.0)` glyph rect so the symmetric plus reads square. Drops the dead "Install Claude Code / Codex / OpenCode / Kimi" submenu (`c11 install <tui>` is explicitly off the table). Hovering the status item with unread notifications now appends deduplicated surface titles below the count on a second line, capped to six with a trailing ellipsis. ([#106](https://github.com/Stage-11-Agentics/c11/pull/106))

- **Sentry routes to a dedicated `stage11-c11` project, with symbolicated traces.** Events were previously going to a generic `demo-project` (python-fastapi) on Sentry, mixed with unrelated Python service errors. dSYM uploads were pointed at `SENTRY_ORG=stage11` (wrong slug) and a project that never existed, so the upload step silently no-op'd on every CI run. `release.yml` and `nightly.yml` now upload to `stage-11-kl` / `stage11-c11` with a real auth token, and the in-app DSN matches.

- **C11-1: post-rebrand stragglers cleaned up.** The About-dialog source-level fallback now reads `c11` (the localized override was already correct in all seven locales). Source-comment links to nonexistent `docs/c11mux-module-*-spec.md` files dropped. Legacy `generate_dark_icon.py` and `generate_nightly_icon.py` had `os.execv` targets pointing at a `generate_c11mux_icon.py` that was never renamed — corrected to the actual `generate_c11_icon.py`. The `docs/c11-charter.md` tap and bundle identifier corrected to what shipped. ([#111](https://github.com/Stage-11-Agentics/c11/pull/111))

### Fixed

- **Main-thread deadlock from blocking v2 socket methods (4×/day → 0).** Under heavy automation, `surface.send_text` / `surface.send_key` / `surface.read_text` / `surface.clear_history` were parking `CFRunLoopRun()` on the main thread inside `v2AwaitCallback`, beach-balling the whole app with no recovery. The four handlers now run on the socket worker thread under a new `socketWorker` execution policy and only hop to `@MainActor` for bounded slices via `Task { @MainActor in ... } + DispatchSemaphore`. New `waitForTerminalSurfaceOffMain` uses observer-then-recheck-then-`DispatchSemaphore` so the main queue stays free, observers fire, and the semaphore signals correctly off-main. Hand-port of upstream cmux [#3340](https://github.com/manaflow-ai/cmux/pull/3340) by [@lawrencecchen](https://github.com/lawrencecchen) plus c11-specific scope expansion to actually cover the `surface.*` methods (upstream's allowlist did not include any of them). Pre-fix main-thread sample under 50× `surface.send_text` load: 7120/7120 ticks parked under `v2AwaitCallback` / `v2MainSync` / `waitForTerminalSurface*`. Post-fix sample under the same load: 0/7120. ([#112](https://github.com/Stage-11-Agentics/c11/pull/112)) — thanks [@lawrencecchen](https://github.com/lawrencecchen) for the upstream fix!

- **Claude Code session resume now works inside worktree subdirs.** `c11 restart` was emitting `claude --resume <id>` from whatever cwd the surface respawned in. Claude Code stores session JSONLs at `~/.claude/projects/<encoded-cwd>/<id>.jsonl` and resolves `--resume` by the *current* shell's cwd, so a session captured inside e.g. `code/c11-worktrees/some-branch/` failed with "No conversation found with session ID" when the surface respawned in `code/`. Restart now records `claude.session_project_dir` at SessionStart (paired atomically with `claude.session_id`), and synthesizes `cd '<path>' && claude --dangerously-skip-permissions --resume <id>` when the path is present and valid. Existing surfaces with id-only metadata keep working unchanged. Validators reject malformed paths at write time and re-validate at synthesis time, with single-quote escaping for paths containing spaces. ([#113](https://github.com/Stage-11-Agentics/c11/pull/113))

### Built and shipped by

Stage 11 Agentics. Operator:agent, fused.

## [0.44.1] - 2026-04-28

### Fixed

- **"What's new" link after auto-update now points at the c11 release page.** When you accepted an update and relaunched, the release-notes link in the Sparkle dialog opened the upstream cmux release page on GitHub instead of the c11 fork. The semver path in `UpdateViewModel.ReleaseNotes` was hand-rolling a URL against `manaflow-ai/cmux`. Same sweep removed an "Upstream" button from the About panel, fixed the About panel "GitHub" and commit links (which pointed at a `c11mux` repo that doesn't exist), corrected the `c11 daemon-status` advisory `gh release download` text, and replaced the splash banner's upstream URL with the c11 repo. Sparkle install itself was always correct, so the only user-visible symptom was the misrouted release-notes link.

### Built and shipped by

Stage 11 Agentics. Operator:agent, fused.

## [0.44.0] - 2026-04-27

### Added

- **Claude Code session resume across c11 restarts.** When you quit and relaunch c11, terminals that were running Claude Code auto-resume the conversation: about 2.5 s after restore, the pane types and submits `claude --dangerously-skip-permissions --resume <session-uuid>` for you. Capture works via a hooks-via-tempfile workaround for Claude Code 2.1.119, which silently ignores hooks loaded from inline `--settings` JSON; restore drives the resume command through `TextBoxSubmit` (paste plus a synthetic Return), since bracketed-paste mode would otherwise swallow the embedded newline. The wrapper falls back to inline JSON with a stderr warning if the tempfile write fails. SessionEnd clears `claude.session_id` from surface metadata so an already-ended session does not auto-resume on next launch. ([#89](https://github.com/Stage-11-Agentics/c11/pull/89))

- **C11-20: CLI hygiene and focus policy sweep (7 upstream picks).** `c11 new-surface --no-focus` (and `surface.create focus:false`) so agents can spawn surfaces without stealing focus. New `tty` field in `surface.list` and `system.tree` responses. `c11 send` and `send-key` now error when `--surface` is omitted and `CMUX_SURFACE_ID` is unset, so silent defaults can no longer deliver to the wrong surface. `surface.send_text` reaches non-focused tabs via `waitForTerminalSurface`. Focus and `workspace select` bring the existing window forward and resolve indices cross-window. `workspace.create --layout` rolls back the orphan workspace on layout failure. SIGABRT on broken pipe is now caught. Reported upstream by @andy5090, @hummer98, @nengqi, @jasonkuhrt, @EtanHey, @austinywang, @shaun0927. ([#84](https://github.com/Stage-11-Agentics/c11/pull/84))

- **C11-22: Stability, render, theme, config (10 upstream picks).** SSH subprocess inherits the full process environment (`SSH_AUTH_SOCK`, agent forwarding). `parseByteCount` understands K/M/G suffixes with overflow and negative guards. Notification authorization now requests `.badge` so the dock badge fires for terminal alerts. `customColor` accepts named palette colors, with unknown names returning a typed `unknown_color_name` failure. Palette index is bounded to `0...15`; a KVO observer reloads config on system-appearance changes. `.safeHelp` removed from high-churn titlebar, sidebar, and new-workspace buttons (UAF risk). Legacy-mode scrollbar gutter is subtracted from terminal width. Idle redraws are gated when the palette overlay is hidden. `applyContrastFallbackIfNeeded` logs the override and palette entries now apply in `TerminalView`. Ghostty submodule bumps to `c649529` for the `SlidingWindow.Meta` page-rows SIGSEGV race fix. ([#87](https://github.com/Stage-11-Agentics/c11/pull/87))

### Changed

- **C11-21: Input handling, keyboard, IME, paste (8 upstream picks).** Tightened `allowANSIKeyCodeFallback` in `matchShortcut` so the physical-keycode fallback only fires when both AppKit and the active layout returned no character; fixes JIS `Cmd+Shift+[` routing to the wrong shortcut. Option+Backspace now does word-deletion in TUI apps (lazygit, vim, Claude Code, Codex) via a fast path before `interpretKeyEvents`. `flagsChanged` tracks per-bit modifier transitions and emits press / release for newly-set or cleared bits, fixing modifier events dropped during IME marked text. `stringContents(from:)` prefers `NSPasteboard.utf8PlainTextType` over `.string` for clean Hangul, Cyrillic, and Qt non-ASCII paste. Disproportionately important for c11's six-locale shipping story. Reported upstream by @wada811, @sldx, @judekim0507, @shouryamaanjain, @pandec, @austinywang, @shaun0927. ([#86](https://github.com/Stage-11-Agentics/c11/pull/86))

### Fixed

- **Orphan portal entries no longer paint stale chrome strokes on launch.** Bonsplit's `_ConditionalContent` flipping between `EmptyPanelView` and `PanelContentView` during launch or workspace remount could leave a portal entry frozen at its initial frame, painting phantom chrome and sometimes the empty-pane SwiftUI subtree on top of the live workspace for the rest of the session. `TerminalWindowPortal` and `BrowserWindowPortal` now reap these orphans during the geometry-sync pass: when the anchor weak ref deallocates or the anchor migrated to another window, the entry is hidden and the chrome overlay is invalidated. A belt-and-suspenders guard in `workspaceFrameSegmentsForChromeOverlay` keeps chrome strokes from outpacing the hide on a single redraw cycle. ([#88](https://github.com/Stage-11-Agentics/c11/pull/88))

### Built and shipped by

Stage 11 Agentics. Operator:agent, fused.

## [0.43.0] - 2026-04-26

### Added

- **Workspace snapshots.** Capture a workspace's full topology (split tree, surface kinds, titles, descriptions, terminal cwds, per-surface metadata) to `~/.c11-snapshots/<ulid>.json`. Replay any of them with `c11 restore <id>`. `c11 list-snapshots` shows what's saved. Surface names round-trip verbatim, so mailbox addressing survives. Claude Code panes pick up where they left off via `--resume` when restored; opt in for one release with `C11_SESSION_RESUME=1`. Codex (`--last`), opencode, and kimi resume too. ([#77](https://github.com/Stage-11-Agentics/c11/pull/77), [#79](https://github.com/Stage-11-Agentics/c11/pull/79))

- **Workspace blueprints.** Layouts you can name, save, and respawn. `c11 workspace new` opens an interactive picker over available blueprints; `c11 workspace new --blueprint <path|name>` builds from a specific one. Three starters ship in the box: `basic-terminal`, `side-by-side`, `agent-room`. `c11 workspace export-blueprint` writes the current workspace to a reusable file, with a `BLUEPRINT_ALREADY_EXISTS` guard and a `--force` override. Per-repo, per-user, and built-in search paths merge, so blueprints can live next to the project they describe. Localized for all 7 locales. ([#79](https://github.com/Stage-11-Agentics/c11/pull/79))

- **`c11 snapshot --all`.** Capture every open workspace in one call. Browser and markdown surfaces round-trip cleanly through capture and restore. ([#79](https://github.com/Stage-11-Agentics/c11/pull/79))

- **Pane-close confirmation, in-pane and destructive.** Closing a pane (the X on the rightmost tab) drops a destructive overlay anchored to the pane: red-bordered, pulsing, listing every tab about to disappear. The action names itself: "Close *Entire* Pane." The X on the only pane in a workspace resets it (closes every tab, drops in a fresh terminal) instead of being a no-op. Replaces the previous window-centered alert. ([#81](https://github.com/Stage-11-Agentics/c11/pull/81))

- **Bounded waits and named timeouts on the automation socket.** Every CLI socket call carries a 10 s deadline by default, env-tunable via `C11_DEFAULT_SOCKET_DEADLINE_MS`. When it fires, the CLI returns non-zero and writes a parseable envelope to stderr: `c11: timeout: method=... workspace=... socket=... elapsed_ms=...`. Long-runners opt out: `pane.confirm`, `browser.wait`, `browser.download.wait`, `workspace.remote.configure`. App-side, the seven Tier 1 creation handlers (`window.create`, `workspace.create`, `surface.create`, `pane.create`, `new_workspace`, `new_split`, `drag_surface_to_split`) run with an 8 s main-thread deadline and return the same envelope when the main thread doesn't answer. Pipelines no longer hang silently. ([#80](https://github.com/Stage-11-Agentics/c11/pull/80))

- **`C11_TRACE=1` / `CMUX_TRACE=1` socket request tracing.** Bracketing `[c11-trace] ->` / `<-` lines on stderr show every CLI socket call, with elapsed time and status. Useful when the pipeline is slow and you need to know where. ([#80](https://github.com/Stage-11-Agentics/c11/pull/80))

### Changed

- **In-place restore: apply, then close.** `c11 restore --in-place <id>` applies the snapshot before closing the existing workspace, so a partial-apply failure can't leave you with no workspace. Single-workspace windows skip the duplicate-then-self-delete dance. The command honours caller-supplied `CMUX_WORKSPACE_ID` / `C11_WORKSPACE_ID` env vars before the operator's currently-focused workspace, so background agents target their own workspace instead of whatever you happen to be looking at. The apply result surfaces a `workspace_uuid_changed` warning so scripted callers know the workspace identity rotated. ([#78](https://github.com/Stage-11-Agentics/c11/pull/78))

- **`c11 list-snapshots --json` is a subcommand-local flag.** Matches the help text and the rest of the CLI's parse model. ([#78](https://github.com/Stage-11-Agentics/c11/pull/78))

- **Telemetry routes to Stage 11.** Sentry now reports to the stage-11-kl org, not the upstream cmux project. PostHog event names, env vars, and platform tags renamed cmux to c11; the embedded project key is now `stage11-c11`.

- **Privacy: cut the remaining upstream-domain references from shipped strings.** A handful of user-facing strings still pointed at upstream cmux URLs and identifiers. They now point at c11 throughout the app.

### Built and shipped by

Stage 11 Agentics. Operator:agent, fused.

## [0.42.0] - 2026-04-24

### Added
- **Tab bar agent launcher + close-pane buttons.** Every pane's tab bar gets two first-class buttons: **A** (leftmost, spawns a new terminal running the operator's configured agent launcher — default Claude Code) and **X** (rightmost, closes the entire pane after a confirmation alert that names how many tabs will be lost; disabled when only one pane exists). Right-click **A** opens a context menu of all agent kinds (Claude Code, Codex, OpenCode, Kimi, Other) with a checkmark on the current default; picking one updates the default AND spawns that agent immediately. Settings → Agents & Automation gains an *Agent Launcher Button* section at the top for the picker and free-form command field. ([#72](https://github.com/Stage-11-Agentics/c11/pull/72)) — thanks @BenevolentFutures!
- **Tab bar chrome states.** View → Tab Bar gains Full / Shrunk / Hidden entries with ⌘⇧B to cycle. Shrunk and Hidden give dense multi-agent workspaces more vertical room; the handle overlay stays available in Shrunk state for drag-to-rearrange. Default remains Full. — thanks @BenevolentFutures!
- **`c11 mailbox` inter-agent messaging primitive.** New CLI surface for sending envelopes between surfaces on the same c11 instance — `c11 mailbox send | recv | trace | tail | outbox-dir | inbox-dir | surface-name`. Envelopes are validated against a v1 schema, written atomically, and delivered through an fsevent watcher. The default `stdin` handler writes the body to the recipient's PTY with a 500 ms timeout; a `silent` no-op handler is available for dry-run routing. Dispatch log is NDJSON at the mailbox layout path. ([#73](https://github.com/Stage-11-Agentics/c11/pull/73)) — thanks @BenevolentFutures!
- **`c11 workspace apply` and the `workspace.apply` socket method.** Build a whole workspace from a single declarative JSON plan — nested split trees, surface kinds (terminal / browser / markdown), titles, descriptions, pane metadata, surface metadata, and terminal cwd — in one call. Foundation for the upcoming Workspace Snapshots and Blueprints flow. ([#75](https://github.com/Stage-11-Agentics/c11/pull/75)) — thanks @BenevolentFutures!
- **`c11 notify` on v2 notification methods.** The CLI now routes through the modern `sidebar.notification.*` methods, bringing richer notification metadata and keeping CLI and sidebar v2 plumbing consistent. ([#66](https://github.com/Stage-11-Agentics/c11/pull/66)) — thanks @BenevolentFutures!

### Changed
- **Jump-to-Unread moved from the bottom status bar to the sidebar footer; the bottom status bar is gone.** The jump button is now larger, labeled, and badge-aware in its new home, and its default keyboard shortcut is ⌃⌘⏎. ([#64](https://github.com/Stage-11-Agentics/c11/pull/64)) — thanks @BenevolentFutures!
- **macOS permissions primer sheet refresh.** Full Disk Access is now the primary CTA, the button order is flipped to match platform conventions, and the body copy is tightened. — thanks @BenevolentFutures!
- **c11 skill requires a title and a description at orientation.** Every agent that reads the c11 skill now names its surface with both a title and a description on startup — unnamed or undescribed surfaces become the exception, not the norm. ([#65](https://github.com/Stage-11-Agentics/c11/pull/65)) — thanks @BenevolentFutures!
- **Claude Code hook runs quietly.** The `claude-hook` subcommand now exits cleanly when the c11 socket is unreachable (no stderr noise in Claude Code transcripts), and its advisory guidance speaks c11 vocabulary instead of the older `cmux` names. Real CLI usage (`c11 identify`, etc.) still surfaces missing-socket errors as before. ([#74](https://github.com/Stage-11-Agentics/c11/pull/74)) — thanks @BenevolentFutures!

### Fixed
- **`c11 set-metadata` / `c11 set-agent` default to the focused surface again.** Omitting the surface argument now resolves to the currently focused surface as documented, rather than targeting the wrong surface in some configurations. ([#63](https://github.com/Stage-11-Agentics/c11/pull/63)) — thanks @BenevolentFutures!

### Thanks to 1 contributor!

[@BenevolentFutures](https://github.com/BenevolentFutures)

## [0.41.0] - 2026-04-23

### Added
- TCC primer onboarding sheet on first run. Explains why macOS is about to ask about Downloads, Documents, Desktop, iCloud Drive, Music, Photos, and other protected resources before the system dialogs fire — following the iTerm2 / Warp / Ghostty pattern. 14 custom `NS*UsageDescription` strings rewrite the native dialog copy in c11's voice, attributing requests to "a program running within c11." Chains after the Agent Skills sheet on fresh installs; existing users are skipped via a one-shot migration. Settings gains a new Permissions section with "Show permissions primer…" re-entry and a direct deep-link to Full Disk Access. Localized into ja / uk / ko / zh-Hans / zh-Hant / ru. ([#55](https://github.com/Stage-11-Agentics/c11/pull/55), [#56](https://github.com/Stage-11-Agentics/c11/pull/56)) — thanks @BenevolentFutures!

### Changed
- New workspaces now default to a balanced 2×2 terminal grid. Previously the grid was gated behind an off-by-default flag and branched on screen resolution (3×3 on 4K, 2×3 on QHD, 2×2 otherwise); a single predictable shape is the better default.
- Agent Skills onboarding sheet adapts to install state: title reads "Teach your agent c11" on fresh install, "Update" when something is installed but stale, and "Nothing to do here" when the detected rows are already current. "Later" and "Don't ask again" buttons are hidden when there's nothing to act on, so the all-set state shows only a single primary button. Transparency note clarified about what gets written and where. ([#54](https://github.com/Stage-11-Agentics/c11/pull/54)) — thanks @BenevolentFutures!
- Notifications empty state and Agent Skills onboarding sheet copy tightened for density and active voice. ([#50](https://github.com/Stage-11-Agentics/c11/pull/50)) — thanks @BenevolentFutures!

### Thanks to 1 contributor!

[@BenevolentFutures](https://github.com/BenevolentFutures)

## [0.40.0] - 2026-04-22

### Added
- Settings sidebar is reorganized into logical pages with a two-column layout, and the Settings window title reads "c11 Settings". — thanks @BenevolentFutures!

### Changed
- User-facing copy tightened across the app — 72 strings rewritten for density and active voice across agent onboarding, confirmation dialogs, the notifications empty state, the Sparkle update flow, the sidebar feedback form, and the browser import wizard. Non-English translations for touched strings are marked `needs_review` for the next translation pass. — thanks @BenevolentFutures!
- About box tagline now reads *"terminal command center for the operator:agent pair. / many surfaces. one workspace. one field of view."* (replacing the previous architecture description). — thanks @BenevolentFutures!
- Agent Skills onboarding dialog: "Agentically use c11" / "Skillify Your Agent" becomes "Teach your agent c11" / "Teach My Agent". Body copy, transparency note, and empty-detection state rewritten for clarity. — thanks @BenevolentFutures!
- User-facing copy normalized from "panel" to "pane" throughout dialogs, menus, and command labels ("Flash Focused Pane", "Reopen Closed Browser Pane", "close the workspace and all of its panes"), matching README and skill vocabulary. Internal Swift type names are unchanged. — thanks @BenevolentFutures!
- Sparkle update flow copy: "Please" filler dropped from error messages, "Update Feed" jargon replaced with "Update Source" / "Update List", and vague error titles rewritten ("App Location Issue" → "c11 isn't in Applications", "Updater Permission Error" → "c11 needs to live in Applications", "Update Signature Error" → "Signature Didn't Verify"). — thanks @BenevolentFutures!
- The c11-markdown skill now teaches agents to consolidate multi-artifact sessions into one pane or one file rather than scattering top-level tabs. — thanks @BenevolentFutures!

### Fixed
- Settings pages keep their scroll position when switching between sections. — thanks @BenevolentFutures!
- Settings two-column layout rendering. — thanks @BenevolentFutures!
- Settings sidebar review findings addressed. — thanks @BenevolentFutures!

### Thanks to 1 contributor!

[@BenevolentFutures](https://github.com/BenevolentFutures)

## [0.39.0] - 2026-04-22

### Added
- Settings now exposes separate Light and Dark c11 theme slots, each with its own preview and picker. — thanks @BenevolentFutures!
- Agent Skills onboarding now detects existing c11 skills, defaults detected agents into the install/update flow, handles shared skill folders safely, offers Finder reveal for exact skill files, and uses a clearer "Skillify Your Agent" flow. ([#46](https://github.com/Stage-11-Agentics/c11/pull/46)) — thanks @BenevolentFutures!

### Changed
- Workspace sidebar cards now keep the workspace name primary, wrap it up to two lines, move agent identity chips below it, and name new default workspaces `Workspace N`. ([#41](https://github.com/Stage-11-Agentics/c11/pull/41)) — thanks @BenevolentFutures!
- The bottom status-bar notification jump control is larger, labeled, and badge-aware; the sidebar help menu now points to c11-owned GitHub, docs, and changelog links. ([#42](https://github.com/Stage-11-Agentics/c11/pull/42)) — thanks @BenevolentFutures!
- Default pane tabs are narrower, giving dense multi-agent workspaces more room. ([#44](https://github.com/Stage-11-Agentics/c11/pull/44)) — thanks @BenevolentFutures!
- Theme CLI naming now distinguishes c11 chrome themes from Ghostty terminal themes: `c11 themes` manages chrome themes, and `c11 terminal-theme` manages terminal themes. ([#47](https://github.com/Stage-11-Agentics/c11/pull/47)) — thanks @BenevolentFutures!
- The bundled Phosphor c11 theme is now a bright day chrome option. — thanks @BenevolentFutures!
- Welcome terminal and license surfaces now use current c11 branding. — thanks @BenevolentFutures!
- Tagged dev launches now default to a single-pane workspace unless the default pane grid is enabled. ([#46](https://github.com/Stage-11-Agentics/c11/pull/46)) — thanks @BenevolentFutures!

### Fixed
- The initial main-window chrome layout now reconciles titlebar, sidebar, and content padding during first layout and resize. — thanks @BenevolentFutures!
- Pane close-confirmation dialogs keep keyboard focus so Return, arrows, and Esc control the dialog instead of leaking into browser or terminal panes. ([#43](https://github.com/Stage-11-Agentics/c11/pull/43)) — thanks @BenevolentFutures!
- Custom workspace color chrome now keeps the sidebar background neutral, refreshes tab indicators when colors change, and keeps the workspace outline continuous around hosted terminal and browser surfaces. ([#45](https://github.com/Stage-11-Agentics/c11/pull/45)) — thanks @BenevolentFutures!
- c11 theme lookup now uses the renamed bundled `c11-themes` directory and `Application Support/c11` user theme directory. — thanks @BenevolentFutures!

### Thanks to 1 contributor!

[@BenevolentFutures](https://github.com/BenevolentFutures)

## [0.38.0] - 2026-04-21

### Changed
- The product rename from `c11mux` to `c11` is now reflected across structural surfaces, including app naming, release artifacts, Homebrew tap references, docs, and automation. ([#37](https://github.com/Stage-11-Agentics/c11/pull/37)) — thanks @BenevolentFutures!
- **c11 ↔ upstream cmux coexistence.** c11 no longer claims the `cmux` name on the user's system. Practical effects:
  - The "Shell Command: Install…" palette action installs `/usr/local/bin/c11` (previous default: `/usr/local/bin/cmux`). No `cmux` alias is installed.
  - The Homebrew cask (`stage-11-agentics/c11/c11`) no longer creates a `cmux` binary alias and no longer declares `conflicts_with cask: "cmux"`. c11 and upstream cmux can be installed in parallel.
  - The bundled shell integration still prepends the bundled `Resources/bin/` to `PATH` inside c11 terminals, but that directory no longer contains a `cmux` symlink — an upstream `cmux` elsewhere on `PATH` stays visible.
  - `CMUX_*` environment variables are still honored alongside the new `C11_*` variants; socket paths, protocol, and shell-integration file names remain unchanged. ([#38](https://github.com/Stage-11-Agentics/c11/pull/38)) — thanks @BenevolentFutures!
- Release DMG is now `c11-macos.dmg` (was `c11mux-macos.dmg`).
- Homebrew cask is `stage-11-agentics/c11/c11` (was `stage-11-agentics/c11mux/c11mux`).

### Fixed
- The "Open c11 app" shell command now runs `open -a c11` (was `open -a cmux`, which failed because the installed bundle is `c11.app`).
- Pane close confirmations no longer leak Return or arrow-key events into embedded browser panes while the confirmation is open. ([#39](https://github.com/Stage-11-Agentics/c11/pull/39)) — thanks @BenevolentFutures!

### Upgrade notes
- **Stale `/usr/local/bin/cmux` symlinks** created by earlier c11 versions are not removed automatically. `c11 uninstall` only touches `/usr/local/bin/c11`. If you want the stale link gone, remove it manually: `ls -l /usr/local/bin/cmux` to confirm it points at c11, then `sudo rm /usr/local/bin/cmux`.
- **Relocated app bundles.** If you move `c11.app` between installs, the in-app uninstall cannot always remove its PATH symlink (the original bundle target is gone). Remove manually with `sudo rm /usr/local/bin/c11` and re-run "Shell Command: Install 'c11' in PATH".
- **Scripts calling `cmux <subcommand>`** keep working only if `cmux` still resolves on PATH via an earlier install or upstream cmux. Update them to `c11 <subcommand>` to rely on c11 alone.

### Thanks to 1 contributor!

[@BenevolentFutures](https://github.com/BenevolentFutures)

## [0.37.0] - 2026-04-20

First substantive release of the Stage 11 fork after the v0.1.0 versioning reset. Version number tracks the highest Lattice ticket (CMUX-37). 61 commits since v0.1.0; highlights below.

### Added
- **C11-1: Stage 11 fork brand pass.** App display name is **c11**, bundle ID is `com.stage11.c11mux`, release artifact is `c11mux-macos.dmg`, Homebrew tap is `stage-11-agentics/c11mux`, and the Sparkle auto-update feed points at the Stage 11 appcast. The `cmux` CLI binary, `CMUX_*` env vars, socket paths/protocol, and shell-integration files are preserved unchanged for backward compatibility. See [NOTICE](./NOTICE) for attribution. ([#36](https://github.com/Stage-11-Agentics/c11mux/pull/36))
- **CMUX-40: Skill installer.** Settings → Agent Skills pane, `cmux skills install` CLI, and a first-launch wizard for distributing the cmux skill into Claude Code / Codex / other agent tenants. ([#33](https://github.com/Stage-11-Agentics/c11mux/pull/33))
- **CMUX-36: Bottom status bar + jump-to-unread.** Per-window status row aggregates per-pane indicators; one-tap jump to the next unread surface. ([#34](https://github.com/Stage-11-Agentics/c11mux/pull/34))
- **CMUX-35: User themes + hot reload.** Drop a `.theme` in the user themes directory and it appears immediately. Settings picker overload, CLI, and socket command included. ([#31](https://github.com/Stage-11-Agentics/c11mux/pull/31))
- **CMUX-32: Workspace color prevalence.** Selected workspace tints frame, dividers, and sidebar — clear visual cue for which workspace owns the foreground. ([#30](https://github.com/Stage-11-Agentics/c11mux/pull/30))
- **CMUX-9 M1: Theme engine foundation.** New theme engine with surface adoption (M1a + M1b), groundwork for the M2+ theming roadmap. ([#28](https://github.com/Stage-11-Agentics/c11mux/pull/28))
- **CMUX-15: Auto-spawn default pane grid.** New workspaces open with a default pane grid sized to the monitor class. ([#24](https://github.com/Stage-11-Agentics/c11mux/pull/24); follow-ups for retina, remote, delay, and diagnostics in [#26](https://github.com/Stage-11-Agentics/c11mux/pull/26))
- **CMUX-11: Pane metadata RPCs + persistence.** Per-pane title and metadata persist across restarts; `cmux pane` CLI for set/get; `--title` flag seeds a launching pane. Phases 1–4. ([#22](https://github.com/Stage-11-Agentics/c11mux/pull/22), [#25](https://github.com/Stage-11-Agentics/c11mux/pull/25), [#27](https://github.com/Stage-11-Agentics/c11mux/pull/27))
- **CMUX-3 (Tier 1 persistence Phase 3): persist `statusEntries`.** Sidebar status entries survive restart. ([#23](https://github.com/Stage-11-Agentics/c11mux/pull/23))
- **Tier 1 persistence Phase 2: SurfaceMetadataStore.** ([#13](https://github.com/Stage-11-Agentics/c11mux/pull/13))
- **M10: Pane-scoped close confirmations + `pane.confirm` socket/CLI.** Tab- and workspace-close confirmations render as a card anchored inside the specific panel instead of a window-centered NSAlert; other splits, tabs, and windows remain interactive. Enter / Cmd+D accept, Esc cancels, Tab cycles. Local agents can request panel-anchored confirmations via `cmux pane-confirm` / the `pane.confirm` socket command (exit 0=ok, 2=cancel, 3=dismissed, 1=error). ([#17](https://github.com/Stage-11-Agentics/c11mux/pull/17))
- **M9: TextBox Input port** from the alumican/cmux-tb fork. ([#14](https://github.com/Stage-11-Agentics/c11mux/pull/14))
- **M8: `cmux tree` overhaul.** New flags `--window`, `--workspace <id>`, `--all`, `--layout`, `--no-layout`, `--canvas-cols <N>`. Pane lines carry `size=W%×H%`, `px=W×H`, and `split=…` badges. JSON output gains a `layout` sub-object on each pane (`percent`, `pixels`, `split_path`) and a `content_area` on each workspace. Single-workspace text output renders an ASCII floor plan above the hierarchical tree by default.
- **Pane toolbar:** Markdown + NewTab buttons with hover highlight (Bonsplit fork). ([#16](https://github.com/Stage-11-Agentics/c11mux/pull/16))
- **Radical theme** (bundled).
- **`scripts/prune-tags.sh`** to clean stale `reload.sh --tag` artifacts in DerivedData and `/tmp` (each tag leaves ~3.5 G behind that nothing auto-cleans).

### Changed
- **App menu reordered.** c11mux Settings sits in the top group; Ghostty Settings moves below Services.
- **Theme picker simplified** + dark appearance forced. ([#35](https://github.com/Stage-11-Agentics/c11mux/pull/35))
- **`cmux tree` defaults to the current workspace.** Use `--window` for the pre-M8 behavior (current window, all workspaces) and `--all` for every window.
- **First-launch defaults:** app fills the screen on first launch; default notification sound is Bottle.
- **Sidebar:** keep custom workspace color when selected. ([#19](https://github.com/Stage-11-Agentics/c11mux/pull/19))
- **README** rewritten in the Stage 11 voice; lineage credits Ghostty and Bonsplit.

### Fixed
- **Pane rename dialog:** button copy is now "Set Tab Title"; arrow / tab / return keyboard nav and contrast in confirm cards.
- **`CMUX_TAB_ID` env var** propagation in c11mux.

## [0.62.2] - 2026-03-14

### Added
- Configurable sidebar tint color with separate light/dark mode support via Settings and config file (`sidebar-background`, `sidebar-tint-opacity`) ([#1465](https://github.com/manaflow-ai/cmux/pull/1465))
- Cmd+P all-surfaces search option ([#1382](https://github.com/manaflow-ai/cmux/pull/1382))
- `cmux themes` command with bundled Ghostty themes ([#1334](https://github.com/manaflow-ai/cmux/pull/1334), [#1314](https://github.com/manaflow-ai/cmux/pull/1314))
- Sidebar can now shrink to smaller widths ([#1420](https://github.com/manaflow-ai/cmux/pull/1420))
- Menu bar visibility setting ([#1330](https://github.com/manaflow-ai/cmux/pull/1330))

### Changed
- CLI Sentry events are now tagged with the app release ([#1408](https://github.com/manaflow-ai/cmux/pull/1408))
- Stable socket listener now falls back to a user-scoped path, and repeated startup failures are throttled ([#1351](https://github.com/manaflow-ai/cmux/pull/1351), [#1415](https://github.com/manaflow-ai/cmux/pull/1415))

### Fixed
- Command palette command-mode shortcut, navigation, and omnibar backspace or arrow-key regressions ([#1417](https://github.com/manaflow-ai/cmux/pull/1417), [#1413](https://github.com/manaflow-ai/cmux/pull/1413))
- Stale Claude sidebar status from missing hooks, OSC suppression, and PID cleanup ([#1306](https://github.com/manaflow-ai/cmux/pull/1306))
- Split cwd inheritance when the shell cwd is stale ([#1403](https://github.com/manaflow-ai/cmux/pull/1403))
- Crashes when creating a new workspace and when inserting a workspace into an orphaned window context ([#1391](https://github.com/manaflow-ai/cmux/pull/1391), [#1380](https://github.com/manaflow-ai/cmux/pull/1380))
- Cmd+W close behavior and close-confirmation shell-state regressions ([#1395](https://github.com/manaflow-ai/cmux/pull/1395), [#1386](https://github.com/manaflow-ai/cmux/pull/1386))
- macOS dictation NSTextInputClient conformance and terminal image-paste fallbacks ([#1410](https://github.com/manaflow-ai/cmux/pull/1410), [#1305](https://github.com/manaflow-ai/cmux/pull/1305), [#1361](https://github.com/manaflow-ai/cmux/pull/1361), [#1358](https://github.com/manaflow-ai/cmux/pull/1358))
- VS Code command palette target resolution, Ghostty Pure prompt redraws, and internal drag regressions ([#1389](https://github.com/manaflow-ai/cmux/pull/1389), [#1363](https://github.com/manaflow-ai/cmux/pull/1363), [#1316](https://github.com/manaflow-ai/cmux/pull/1316), [#1379](https://github.com/manaflow-ai/cmux/pull/1379))

## [0.62.1] - 2026-03-13

### Added
- Cmd+T (New tab) shortcut on the welcome screen ([#1258](https://github.com/manaflow-ai/cmux/pull/1258))

### Fixed
- Cmd+backtick window cycling skipping windows
- Titlebar shortcut hint clipping ([#1259](https://github.com/manaflow-ai/cmux/pull/1259))
- Terminal portals desyncing after sidebar changes ([#1253](https://github.com/manaflow-ai/cmux/pull/1253))
- Background terminal focus retries reordering windows
- Pure-style multiline prompt redraws in Ghostty
- Return key not working on Cmd+Ctrl+W close confirmation ([#1279](https://github.com/manaflow-ai/cmux/pull/1279))
- Concurrent remote daemon RPC calls timing out ([#1281](https://github.com/manaflow-ai/cmux/pull/1281))

### Removed
- SSH remote port proxying (reverted, will return in a future release)

## [0.62.0] - 2026-03-12

### Added
- Markdown viewer panel with live file watching ([#883](https://github.com/manaflow-ai/cmux/pull/883))
- Find-in-page (Cmd+F) for browser panels ([#837](https://github.com/manaflow-ai/cmux/issues/837), [#875](https://github.com/manaflow-ai/cmux/pull/875))
- Keyboard copy mode for terminal scrollback with vi-style navigation ([#792](https://github.com/manaflow-ai/cmux/pull/792))
- Custom notification sounds with file picker support ([#839](https://github.com/manaflow-ai/cmux/pull/839), [#869](https://github.com/manaflow-ai/cmux/pull/869))
- Browser camera and microphone permission support ([#760](https://github.com/manaflow-ai/cmux/issues/760), [#913](https://github.com/manaflow-ai/cmux/pull/913))
- Language setting for per-app locale override ([#886](https://github.com/manaflow-ai/cmux/pull/886))
- Japanese localization ([#819](https://github.com/manaflow-ai/cmux/pull/819))
- 16 new languages added to localization ([#895](https://github.com/manaflow-ai/cmux/pull/895))
- Kagi as a search provider option ([#561](https://github.com/manaflow-ai/cmux/pull/561))
- Open Folder command (Cmd+O) ([#656](https://github.com/manaflow-ai/cmux/pull/656))
- Dark mode app icon for macOS Sequoia ([#702](https://github.com/manaflow-ai/cmux/pull/702))
- Close other pane tabs with confirmation ([#475](https://github.com/manaflow-ai/cmux/pull/475))
- Flash Focused Panel command palette action ([#638](https://github.com/manaflow-ai/cmux/pull/638))
- Zoom/maximize focused pane in splits ([#634](https://github.com/manaflow-ai/cmux/pull/634))
- `cmux tree` command for full CLI hierarchy view ([#592](https://github.com/manaflow-ai/cmux/pull/592))
- Install or uninstall the `cmux` CLI from the command palette ([#626](https://github.com/manaflow-ai/cmux/pull/626))
- Clipboard image paste in terminal with Cmd+V ([#562](https://github.com/manaflow-ai/cmux/pull/562), [#853](https://github.com/manaflow-ai/cmux/pull/853))
- Middle-click X11-style selection paste in terminal ([#369](https://github.com/manaflow-ai/cmux/pull/369))
- Honor Ghostty `background-opacity` across all cmux chrome ([#667](https://github.com/manaflow-ai/cmux/pull/667))
- Setting to hide Cmd-hold shortcut hints ([#765](https://github.com/manaflow-ai/cmux/pull/765))
- Focus-follows-mouse on terminal hover ([#519](https://github.com/manaflow-ai/cmux/pull/519))
- Sidebar help menu in the footer ([#958](https://github.com/manaflow-ai/cmux/pull/958))
- External URL bypass rules for the embedded browser ([#768](https://github.com/manaflow-ai/cmux/pull/768))
- Telemetry opt-out setting ([#610](https://github.com/manaflow-ai/cmux/pull/610))
- Browser automation docs page ([#622](https://github.com/manaflow-ai/cmux/pull/622))
- Vim mode indicator badge on terminal panes ([#1092](https://github.com/manaflow-ai/cmux/pull/1092))
- Sidebar workspace color in CLI sidebar_state output ([#1101](https://github.com/manaflow-ai/cmux/pull/1101))
- Prompt before closing window with Cmd+Ctrl+W ([#1219](https://github.com/manaflow-ai/cmux/pull/1219))
- Jump to Latest button in notifications popover ([#1167](https://github.com/manaflow-ai/cmux/pull/1167))
- Khmer localization ([#1198](https://github.com/manaflow-ai/cmux/pull/1198))
- cmux claude-teams launcher ([#1179](https://github.com/manaflow-ai/cmux/pull/1179))

### Changed
- Command palette search is now async and decoupled from typing for reduced lag
- Fuzzy matching improved with single-edit and omitted-character word matches
- Replaced keychain password storage with file-based storage ([#576](https://github.com/manaflow-ai/cmux/pull/576))
- Fullscreen shortcut changed to Cmd+Ctrl+F, and Cmd+Enter also toggles fullscreen ([#530](https://github.com/manaflow-ai/cmux/pull/530))
- Workspace rename shortcut Cmd+Shift+R now uses the command palette flow
- Renamed tab color to workspace color in user-facing strings ([#637](https://github.com/manaflow-ai/cmux/pull/637))
- Feedback recipient changed to `feedback@manaflow.com` ([#1007](https://github.com/manaflow-ai/cmux/pull/1007))
- Regenerated app icons from Icon Composer ([#1005](https://github.com/manaflow-ai/cmux/pull/1005))
- Moved update logs into the Debug menu ([#1008](https://github.com/manaflow-ai/cmux/pull/1008))
- Updated Ghostty to v1.3.0 ([#1142](https://github.com/manaflow-ai/cmux/pull/1142))
- Welcome screen colors adapted for light mode ([#1214](https://github.com/manaflow-ai/cmux/pull/1214))
- Notification sound picker width constrained ([#1168](https://github.com/manaflow-ai/cmux/pull/1168))

### Fixed
- Frozen blank launch from session restore race condition ([#399](https://github.com/manaflow-ai/cmux/issues/399), [#565](https://github.com/manaflow-ai/cmux/pull/565))
- Crash on launch from an exclusive access violation in drag-handle hit testing ([#490](https://github.com/manaflow-ai/cmux/issues/490))
- Use-after-free in `ghostty_surface_refresh` after sleep/wake ([#432](https://github.com/manaflow-ai/cmux/issues/432), [#619](https://github.com/manaflow-ai/cmux/pull/619))
- Startup SIGSEGV by pre-warming locale before `SentrySDK.start` ([#927](https://github.com/manaflow-ai/cmux/pull/927))
- IME issues: Shift+Space toggle inserting a space ([#641](https://github.com/manaflow-ai/cmux/issues/641), [#670](https://github.com/manaflow-ai/cmux/pull/670)), Ctrl fast path blocking IME events, browser address bar Japanese IME ([#789](https://github.com/manaflow-ai/cmux/issues/789), [#867](https://github.com/manaflow-ai/cmux/pull/867)), and Cmd shortcuts during IME composition
- CLI socket autodiscovery for tagged sockets ([#832](https://github.com/manaflow-ai/cmux/pull/832))
- Flaky CLI socket listener recovery ([#952](https://github.com/manaflow-ai/cmux/issues/952), [#954](https://github.com/manaflow-ai/cmux/pull/954))
- Side-docked dev tools resize ([#712](https://github.com/manaflow-ai/cmux/pull/712))
- Dvorak Cmd+C colliding with the notifications shortcut ([#762](https://github.com/manaflow-ai/cmux/pull/762))
- Terminal drag hover overlay flicker
- Titlebar controls clipped at the bottom edge ([#1016](https://github.com/manaflow-ai/cmux/pull/1016))
- Sidebar git branch recovery after sleep/wake and agent checkout ([#494](https://github.com/manaflow-ai/cmux/issues/494), [#671](https://github.com/manaflow-ai/cmux/pull/671), [#905](https://github.com/manaflow-ai/cmux/pull/905))
- Browser portal routing, uploads, and click focus regressions ([#908](https://github.com/manaflow-ai/cmux/pull/908), [#961](https://github.com/manaflow-ai/cmux/pull/961))
- Notification unread persistence on workspace focus
- Escape propagation when the command palette is visible ([#847](https://github.com/manaflow-ai/cmux/pull/847))
- Cmd+Shift+Enter pane zoom regression in browser focus ([#826](https://github.com/manaflow-ai/cmux/pull/826))
- Cross-window theme background after jump-to-unread ([#861](https://github.com/manaflow-ai/cmux/pull/861))
- `window.open()` and `target=_blank` not opening in a new tab ([#693](https://github.com/manaflow-ai/cmux/pull/693))
- Terminal wrap width for the overlay scrollbar ([#522](https://github.com/manaflow-ai/cmux/pull/522))
- Orphaned child processes when closing workspace tabs ([#889](https://github.com/manaflow-ai/cmux/pull/889))
- Cmd+F Escape passthrough into terminal ([#918](https://github.com/manaflow-ai/cmux/pull/918))
- Terminal link opens staying in the source workspace ([#912](https://github.com/manaflow-ai/cmux/pull/912))
- Ghost terminal surface rebind after close ([#808](https://github.com/manaflow-ai/cmux/pull/808))
- Cmd+plus zoom handling on non-US keyboard layouts ([#680](https://github.com/manaflow-ai/cmux/pull/680))
- Menubar icon invisible in light mode ([#741](https://github.com/manaflow-ai/cmux/pull/741))
- Various drag-handle crash fixes and reentrancy guards
- Background workspace git metadata refresh after external checkout
- Markdown panel text click focus ([#991](https://github.com/manaflow-ai/cmux/pull/991))
- Browser Cmd+F overlay clipping in portal mode ([#916](https://github.com/manaflow-ai/cmux/pull/916))
- Voice dictation text insertion ([#857](https://github.com/manaflow-ai/cmux/pull/857))
- Browser panel lifecycle after WebContent process termination ([#892](https://github.com/manaflow-ai/cmux/pull/892))
- Typing lag reduction by hiding invisible views from the accessibility tree ([#862](https://github.com/manaflow-ai/cmux/pull/862))
- CJK font fallback preventing decorative font rendering for CJK characters ([#1017](https://github.com/manaflow-ai/cmux/pull/1017))
- Inline VS Code serve-web token exposure via argv ([#1033](https://github.com/manaflow-ai/cmux/pull/1033))
- Browser pane portal anchor sizing ([#1094](https://github.com/manaflow-ai/cmux/pull/1094))
- Pinned workspace notification reordering ([#1116](https://github.com/manaflow-ai/cmux/pull/1116))
- cmux --version memory blowup ([#1121](https://github.com/manaflow-ai/cmux/pull/1121))
- Notification ring dismissal on direct terminal clicks ([#1126](https://github.com/manaflow-ai/cmux/pull/1126))
- Browser portal visibility when terminal tab is active ([#1130](https://github.com/manaflow-ai/cmux/pull/1130))
- Browser panes reloading when switching workspaces ([#1136](https://github.com/manaflow-ai/cmux/pull/1136))
- Sidebar PR badge detection ([#1139](https://github.com/manaflow-ai/cmux/pull/1139))
- Browser address bar disappearing during pane zoom ([#1145](https://github.com/manaflow-ai/cmux/pull/1145))
- Ghost terminal surface focus after split close ([#1148](https://github.com/manaflow-ai/cmux/pull/1148))
- Browser DevTools resize loop and layout stability ([#1170](https://github.com/manaflow-ai/cmux/pull/1170), [#1173](https://github.com/manaflow-ai/cmux/pull/1173), [#1189](https://github.com/manaflow-ai/cmux/pull/1189))
- Typing lag from sidebar re-evaluation and hitTest overhead ([#1204](https://github.com/manaflow-ai/cmux/issues/1204))
- Browser pane stale content after drag splits ([#1215](https://github.com/manaflow-ai/cmux/pull/1215))
- Terminal drop overlay misplacement during drag hover ([#1213](https://github.com/manaflow-ai/cmux/pull/1213))
- Hidden browser slot inspector focus crash ([#1211](https://github.com/manaflow-ai/cmux/pull/1211))
- Browser devtools hide fallback ([#1220](https://github.com/manaflow-ai/cmux/pull/1220))
- Browser portal refresh on geometry churn ([#1224](https://github.com/manaflow-ai/cmux/pull/1224))
- Browser tab switch triggering unnecessary reload ([#1228](https://github.com/manaflow-ai/cmux/pull/1228))
- Devtools side dock guard for attached devtools ([#1230](https://github.com/manaflow-ai/cmux/pull/1230))

### Thanks to 24 contributors!
- [@0xble](https://github.com/0xble)
- [@afxjzs](https://github.com/afxjzs)
- [@AI-per](https://github.com/AI-per)
- [@atani](https://github.com/atani)
- [@atmigtnca](https://github.com/atmigtnca)
- [@austinywang](https://github.com/austinywang)
- [@cheulyop](https://github.com/cheulyop)
- [@ConnorCallison](https://github.com/ConnorCallison)
- [@gonzaloserrano](https://github.com/gonzaloserrano)
- [@harukitosa](https://github.com/harukitosa)
- [@homanp](https://github.com/homanp)
- [@JLeeChan](https://github.com/JLeeChan)
- [@josemasri](https://github.com/josemasri)
- [@lawrencecchen](https://github.com/lawrencecchen)
- [@novarii](https://github.com/novarii)
- [@orkhanrz](https://github.com/orkhanrz)
- [@qianwan](https://github.com/qianwan)
- [@rjwittams](https://github.com/rjwittams)
- [@sminamot](https://github.com/sminamot)
- [@tmcarr](https://github.com/tmcarr)
- [@trydis](https://github.com/trydis)
- [@ukoasis](https://github.com/ukoasis)
- [@y-agatsuma](https://github.com/y-agatsuma)
- [@yasunogithub](https://github.com/yasunogithub)

## [0.61.0] - 2026-02-25

### Added
- Command palette (Cmd+Shift+P) with update actions and all-window switcher results ([#358](https://github.com/manaflow-ai/cmux/pull/358), [#361](https://github.com/manaflow-ai/cmux/pull/361))
- Split actions and shortcut hints in terminal context menus
- Cross-window tab and workspace move UI with improved destination focus behavior
- Sidebar pull request metadata rows and workspace PR open actions
- Workspace color schemes and left-rail workspace indicator settings ([#324](https://github.com/manaflow-ai/cmux/pull/324), [#329](https://github.com/manaflow-ai/cmux/pull/329), [#332](https://github.com/manaflow-ai/cmux/pull/332))
- URL open-wrapper routing into the embedded browser ([#332](https://github.com/manaflow-ai/cmux/pull/332))
- Cmd+Q quit warning with suppression toggle ([#295](https://github.com/manaflow-ai/cmux/pull/295))
- `cmux --version` output now includes commit metadata

### Changed
- Added light mode and unified theme refresh across app surfaces ([#258](https://github.com/manaflow-ai/cmux/pull/258)) — thanks @ijpatricio for the report!
- Browser link middle-click handling now uses native WebKit behavior ([#416](https://github.com/manaflow-ai/cmux/pull/416))
- Settings-window actions now route through a single command-palette/settings flow
- Sentry upgraded with tracing, breadcrumbs, and dSYM upload support ([#366](https://github.com/manaflow-ai/cmux/pull/366))
- Session restore scope clarification: cmux restores layout, working directory, scrollback, and browser history, but does not resume live terminal process state yet

### Fixed
- Startup split hang when pressing Cmd+D then Ctrl+D early after launch ([#364](https://github.com/manaflow-ai/cmux/pull/364))
- Browser focus handoff and click-to-focus regressions in mixed terminal/browser workspaces ([#381](https://github.com/manaflow-ai/cmux/pull/381), [#355](https://github.com/manaflow-ai/cmux/pull/355))
- Caps Lock handling in browser omnibar keyboard paths ([#382](https://github.com/manaflow-ai/cmux/pull/382))
- Embedded browser deeplink URL scheme handling ([#392](https://github.com/manaflow-ai/cmux/pull/392))
- Sidebar resize cap regression ([#393](https://github.com/manaflow-ai/cmux/pull/393))
- Terminal zoom inheritance for new splits, surfaces, and workspaces ([#384](https://github.com/manaflow-ai/cmux/pull/384))
- Terminal find overlay layering across split and portal-hosted layouts
- Titlebar drag and double-click zoom handling on browser-side panes
- Stale browser favicon and window-title updates after navigation

### Thanks to 7 contributors!
- [@austinywang](https://github.com/austinywang)
- [@avisser](https://github.com/avisser)
- [@gnguralnick](https://github.com/gnguralnick)
- [@ijpatricio](https://github.com/ijpatricio)
- [@jperkin](https://github.com/jperkin)
- [@jungcome7](https://github.com/jungcome7)
- [@lawrencecchen](https://github.com/lawrencecchen)

## [0.60.0] - 2026-02-21

### Added
- Tab context menu with rename, close, unread, and workspace actions ([#225](https://github.com/manaflow-ai/cmux/pull/225))
- Cmd+Shift+T reopens closed browser panels ([#253](https://github.com/manaflow-ai/cmux/pull/253))
- Vertical sidebar branch layout setting showing git branch and directory per pane
- JavaScript alert/confirm/prompt dialogs in browser panel ([#237](https://github.com/manaflow-ai/cmux/pull/237))
- File drag-and-drop and file input in browser panel ([#214](https://github.com/manaflow-ai/cmux/pull/214))
- tmux-compatible command set with matrix tests ([#221](https://github.com/manaflow-ai/cmux/pull/221))
- Pane resize divider control via CLI ([#223](https://github.com/manaflow-ai/cmux/pull/223))
- Production read-screen capture APIs ([#219](https://github.com/manaflow-ai/cmux/pull/219))
- Notification rings on terminal panes ([#132](https://github.com/manaflow-ai/cmux/pull/132))
- Claude Code integration enabled by default ([#247](https://github.com/manaflow-ai/cmux/pull/247))
- HTTP host allowlist for embedded browser with save and proceed flow ([#206](https://github.com/manaflow-ai/cmux/pull/206), [#203](https://github.com/manaflow-ai/cmux/pull/203))
- Setting to disable workspace auto-reorder on notification ([#215](https://github.com/manaflow-ai/cmux/issues/205))
- Browser panel mouse back/forward buttons and middle-click close ([#139](https://github.com/manaflow-ai/cmux/pull/139))
- Browser DevTools shortcut wiring and persistence ([#117](https://github.com/manaflow-ai/cmux/pull/117))
- CJK IME input support for Korean, Chinese, and Japanese ([#125](https://github.com/manaflow-ai/cmux/pull/125))
- `--help` flag on CLI subcommands ([#128](https://github.com/manaflow-ai/cmux/pull/128))
- `--command` flag for `new-workspace` CLI command ([#121](https://github.com/manaflow-ai/cmux/pull/121))
- `rename-tab` socket command ([#260](https://github.com/manaflow-ai/cmux/pull/260))
- Remap-aware bonsplit tooltips and browser split shortcuts ([#200](https://github.com/manaflow-ai/cmux/pull/200))

### Fixed
- IME preedit anchor sizing ([#266](https://github.com/manaflow-ai/cmux/pull/266))
- Cmd+Shift+T focus against deferred stale callbacks ([#267](https://github.com/manaflow-ai/cmux/pull/267))
- Unknown Bonsplit tab context actions causing crash ([#264](https://github.com/manaflow-ai/cmux/pull/264))
- Socket CLI commands stealing macOS app focus ([#260](https://github.com/manaflow-ai/cmux/pull/260))
- CLI unix socket lag from main-thread blocking ([#259](https://github.com/manaflow-ai/cmux/pull/259))
- Main-thread notification cascade causing hangs ([#232](https://github.com/manaflow-ai/cmux/pull/232))
- Favicon out-of-sync during back/forward navigation ([#233](https://github.com/manaflow-ai/cmux/pull/233))
- Stale sidebar git branch after closing a split
- Browser download UX and crash path ([#235](https://github.com/manaflow-ai/cmux/pull/235))
- Browser reopen focus across workspace switches ([#257](https://github.com/manaflow-ai/cmux/pull/257))
- Mark Tab as Unread no-op on focused tab ([#249](https://github.com/manaflow-ai/cmux/pull/249))
- Split dividers disappearing in tiny panes ([#250](https://github.com/manaflow-ai/cmux/pull/250))
- Flaky browser download activity accounting ([#246](https://github.com/manaflow-ai/cmux/pull/246))
- Drag overlay routing and terminal overlay regressions ([#218](https://github.com/manaflow-ai/cmux/pull/218))
- Initial bonsplit split animation flicker
- Window top inset on new window creation ([#224](https://github.com/manaflow-ai/cmux/pull/224))
- Cmd+Enter being routed as browser reload ([#213](https://github.com/manaflow-ai/cmux/pull/213))
- Child-exit close for last-terminal workspaces ([#254](https://github.com/manaflow-ai/cmux/pull/254))
- Sidebar resizer hitbox and cursor across portals ([#255](https://github.com/manaflow-ai/cmux/pull/255))
- Workspace-scoped tab action resolution
- IDN host allowlist normalization
- `setup.sh` cache rebuild and stale lock timeout ([#217](https://github.com/manaflow-ai/cmux/pull/217))
- Inconsistent Tab/Workspace terminology in settings and menus ([#187](https://github.com/manaflow-ai/cmux/pull/187))

### Changed
- CLI workspace commands now run off the main thread for better responsiveness ([#270](https://github.com/manaflow-ai/cmux/pull/270))
- Remove border below titlebar ([#242](https://github.com/manaflow-ai/cmux/pull/242))
- Slimmer browser omnibar with button hover/press states ([#271](https://github.com/manaflow-ai/cmux/pull/271))
- Browser under-page background refreshes on theme updates ([#272](https://github.com/manaflow-ai/cmux/pull/272))
- Command shortcut hints scoped to active window ([#226](https://github.com/manaflow-ai/cmux/pull/226))
- Nightly and release assets are now immutable (no accidental overwrite) ([#268](https://github.com/manaflow-ai/cmux/pull/268), [#269](https://github.com/manaflow-ai/cmux/pull/269))

## [0.59.0] - 2026-02-19

### Fixed
- Fix panel resize hitbox being too narrow and stale portal frame after panel resize

## [0.58.0] - 2026-02-19

### Fixed
- Fix split blackout race condition and focus handoff when creating or closing splits

## [0.57.0] - 2026-02-19

### Added
- Terminal panes now show an animated drop overlay when dragging tabs

### Fixed
- Fix blue hover not showing when dragging tabs onto terminal panes
- Fix stale drag overlay blocking clicks after tab drag ends

## [0.56.0] - 2026-02-19

_No user-facing changes._

## [0.55.0] - 2026-02-19

### Changed
- Move port scanning from shell to app-side with batching for faster startup

### Fixed
- Fix visual stretch when closing split panes
- Fix omnibar Cmd+L focus races

## [0.54.0] - 2026-02-18

### Fixed
- Fix browser omnibar Cmd+L causing 100% CPU from infinite focus loop

## [0.53.0] - 2026-02-18

### Changed
- CLI commands are now workspace-relative: commands use `CMUX_WORKSPACE_ID` environment variable so background agents target their own workspace instead of the user's focused workspace
- Remove all index-based CLI APIs in favor of short ID refs (`surface:1`, `pane:2`, `workspace:3`)
- CLI `send` and `send-key` support `--workspace` and `--surface` flags for explicit targeting
- CLI escape sequences (`\n`, `\r`, `\t`) in `send` payloads are now handled correctly
- `--id-format` flag is respected in text output for all list commands

### Fixed
- Fix background agents sending input to the wrong workspace
- Fix `close-surface` rejecting cross-workspace surface refs
- Fix malformed surface/pane/workspace/window handles passing through without error
- Fix `--window` flag being overridden by `CMUX_WORKSPACE_ID` environment variable

## [0.52.0] - 2026-02-18

### Changed
- Faster workspace switching with reduced rendering churn

### Fixed
- Fix Finder file drop not reaching portal-hosted terminals
- Fix unfocused pane dimming not showing for portal-hosted terminals
- Fix terminal hit-testing and visual glitches during workspace teardown

## [0.51.0] - 2026-02-18

### Fixed
- Fix menubar and right-click lag on M1 Macs in release builds
- Fix browser panel opening new tabs on link click

## [0.50.0] - 2026-02-18

### Fixed
- Fix crashes and fatal error when dropping files from Finder
- Fix zsh git branch display not refreshing after changing directories
- Fix menubar and right-click lag on M1 Macs

## [0.49.0] - 2026-02-18

### Fixed
- Fix crash (stack overflow) when clicking after a Finder file drag
- Fix titlebar folder icon briefly enlarging on workspace switch

## [0.48.0] - 2026-02-18

### Fixed
- Fix right-click context menu lag in notarized builds by adding missing hardened runtime entitlements
- Fix claude shim conflicting with `--resume`, `--continue`, and `--session-id` flags

## [0.47.0] - 2026-02-18

### Fixed
- Fix sidebar tab drag-and-drop reordering not working

## [0.46.0] - 2026-02-18

### Fixed
- Fix broken mouse click forwarding in terminal views

## [0.45.0] - 2026-02-18

### Changed
- Rebuild with Xcode 26.2 and macOS 26.2 SDK

## [0.44.0] - 2026-02-18

### Fixed
- Crash caused by infinite recursion when clicking in terminal (FileDropOverlayView mouse event forwarding)

## [0.38.1] - 2026-02-18

### Fixed
- Right-click and menubar lag in production builds (rebuilt with macOS 26.2 SDK)

## [0.38.0] - 2026-02-18

### Added
- Double-clicking the sidebar title-bar area now zooms/maximizes the window

### Fixed
- Browser omnibar `Cmd+L` now reliably refreshes/selects-all and supports immediate typing without stale inline text
- Omnibar inline completion no longer replaces typed prefixes with mismatched suggestion text

## [0.37.0] - 2026-02-17

### Added
- "+" button on the tab bar for quickly creating new terminal or browser tabs

## [0.36.0] - 2026-02-17

### Fixed
- App hang when omnibar safety timeout failed to fire (blocked main thread)
- Tab drag/drop not working when multiple workspaces exist
- Clicking in browser WebView not focusing the browser tab

## [0.35.0] - 2026-02-17

### Fixed
- App hang when clicking browser omnibar (NSTextView tracking loop spinning forever)
- White flash when creating new browser panels
- Tab drag/drop broken when dragging over WebView panes
- Stale drag timeout cancelling new drags of the same tab
- 88% idle CPU from infinite makeFirstResponder loop
- Terminal keys (arrows, Ctrl+N/P) swallowed after opening browser
- Cmd+N swallowed by browser omnibar navigation
- Split focus stolen by re-entrant becomeFirstResponder during reparenting

## [0.34.0] - 2026-02-16

### Fixed
- Browser not loading localhost URLs correctly

## [0.33.0] - 2026-02-16

### Fixed
- Menubar and general UI lag in production builds
- Sidebar tabs getting extra left padding when update pill is visible
- Memory leak when middle-clicking to close tabs

## [0.32.0] - 2026-02-16

### Added
- Sidebar metadata: git branch, listening ports, log entries, progress bars, and status pills

### Fixed
- localhost and 127.0.0.1 URLs not resolving correctly in the browser panel

### Changed
- `browser open` now targets the caller's workspace by default via CMUX_WORKSPACE_ID

## [0.31.0] - 2026-02-15

### Added
- Arrow key navigation in browser omnibar suggestions
- Browser zoom shortcuts (Cmd+/-, Cmd+0 to reset)
- "Install Update and Relaunch" menu item when an update is available

### Changed
- Open browser shortcut remapped from Cmd+Shift+B to Cmd+Shift+L
- Flash focused panel shortcut remapped from Cmd+Shift+L to Cmd+Shift+H
- Update pill now shows only in the sidebar footer

### Fixed
- Omnibar inline completion showing partial domain (e.g. "news." instead of "news.ycombinator.com")

## [0.30.0] - 2026-02-15

### Fixed
- Update pill not appearing when sidebar is visible in Release builds

## [0.29.0] - 2026-02-15

### Added
- Cmd+click on links in the browser opens them in a new tab
- Right-click context menu shows "Open Link in New Tab" instead of "Open in New Window"
- Third-party licenses bundled in app with Licenses button in About window
- Update availability pill now visible in Release builds

### Changed
- Cmd+[/] now triggers browser back/forward when a browser panel is focused (no-op on terminal)
- Reload configuration shortcut changed to Cmd+Shift+,
- Improved browser omnibar suggestions and focus behavior

## [0.28.2] - 2026-02-14

### Fixed
- Sparkle updates from `0.27.0` could fail to detect newer releases because release build numbers were behind the latest published appcast build number
- Release GitHub Action failed on repeat runs when `SUPublicEDKey` / `SUFeedURL` already existed in `Info.plist`

## [0.28.1] - 2026-02-14

### Fixed
- Release build failure caused by debug-only helper symbols referenced in non-debug code paths

## [0.28.0] - 2026-02-14

### Added
- Optional nightly update channel in Settings (`Receive Nightly Builds`)
- Automated nightly build and publish workflow for `main` when new commits are available

### Changed
- Settings and About windows now use the updated transparent titlebar styling and aligned controls
- Repository license changed to GNU AGPLv3

### Fixed
- Terminal panes freezing after repeated split churn
- Finder service directory resolution now normalizes paths consistently

## [0.27.0] - 2026-02-11

### Fixed
- Muted traffic lights and toolbar items on macOS 14 (Sonoma) caused by `clipsToBounds` default change
- Toolbar buttons (sidebar, notifications, new tab) disappearing after toggling sidebar with Cmd+B
- Update check pill not appearing in titlebar on macOS 14 (Sonoma)

## [0.26.0] - 2026-02-11

### Fixed
- Muted traffic lights and toolbar items in focused window caused by background blur in themeFrame
- Sidebar showing two different textures near the titlebar on older macOS versions

## [0.25.0] - 2026-02-11

### Fixed
- Blank terminal on macOS 26 (Tahoe) — two additional code paths were still clearing the window background, bypassing the initial fix
- Blank terminal on macOS 15 caused by background blur view covering terminal content

## [0.24.0] - 2026-02-09

### Changed
- Update bundle identifier to `com.cmuxterm.app` for consistency

## [0.23.0] - 2026-02-09

### Changed
- Rename app to cmux — new app name, socket paths, Homebrew tap, and CLI binary name (bundle ID remains `com.cmuxterm.app` for Sparkle update continuity)
- Sidebar now shows tab status as text instead of colored dots, with instant git HEAD change detection

### Fixed
- CLI `set-status` command not properly quoting values or routing `--tab` flag

## [0.22.0] - 2026-02-09

### Fixed
- Xcode and system environment variables (e.g. DYLD, LANGUAGE) leaking into terminal sessions

## [0.21.0] - 2026-02-09

### Fixed
- Zsh autosuggestions not working with shared history across terminal panes

## [0.17.3] - 2025-02-05

### Fixed
- Auto-update not working (Sparkle EdDSA signing was silently failing due to SUPublicEDKey missing from Info.plist)

## [0.17.1] - 2025-02-05

### Fixed
- Auto-update not working (Sparkle public key was missing from release builds)

## [0.17.0] - 2025-02-05

### Fixed
- Traffic lights (close/minimize/zoom) not showing on macOS 13-15
- Titlebar content overlapping traffic lights and toolbar buttons when sidebar is hidden

## [0.16.0] - 2025-02-04

### Added
- Sidebar blur effect with withinWindow blending for a polished look
- `--panel` flag for `new-split` command to control split pane placement

## [0.15.0] - 2025-01-30

### Fixed
- Typing lag caused by redundant render loop

## [0.14.0] - 2025-01-30

### Added
- Setup script for initializing submodules and building dependencies
- Contributing guide for new contributors

### Fixed
- Terminal focus when scrolling with mouse/trackpad

### Changed
- Reload scripts are more robust with better error handling

## [0.13.0] - 2025-01-29

### Added
- Customizable keyboard shortcuts via Settings

### Fixed
- Find panel focus and search alignment with Ghostty behavior

### Changed
- Sentry environment now distinguishes between production and dev builds

## [0.12.0] - 2025-01-29

### Fixed
- Handle display scale changes when moving between monitors

### Changed
- Fix SwiftPM cache handling for release builds

## [0.11.0] - 2025-01-29

### Added
- Notifications documentation for AI agent integrations

### Changed
- App and tooling updates

## [0.10.0] - 2025-01-29

### Added
- Sentry SDK for crash reporting
- Documentation site with Fumadocs
- Homebrew installation support (`brew install --cask cmux`)
- Auto-update Homebrew cask on release

### Fixed
- High CPU usage from notification system
- Release workflow SwiftPM cache issues

### Changed
- New tabs now insert after current tab and inherit working directory

## [0.9.0] - 2025-01-29

### Changed
- Normalized window controls appearance
- Added confirmation panel when closing windows with active processes

## [0.8.0] - 2025-01-29

### Fixed
- Socket key input handling
- OSC 777 notification sequence support

### Changed
- Customized About window
- Restricted titlebar accessories for cleaner appearance

## [0.7.0] - 2025-01-29

### Fixed
- Environment variable and terminfo packaging issues
- XDG defaults handling

## [0.6.0] - 2025-01-28

### Fixed
- Terminfo packaging for proper terminal compatibility

## [0.5.0] - 2025-01-28

### Added
- Sparkle updater cache handling
- Ghostty fork documentation

## [0.4.0] - 2025-01-28

### Added
- cmux CLI with socket control modes
- NSPopover-based notifications

### Fixed
- Notarization and codesigning for embedded CLI
- Release workflow reliability

### Changed
- Refined titlebar controls and variants
- Clear notifications on window close

## [0.3.0] - 2025-01-28

### Added
- Debug scrollback tab with smooth scroll wheel
- Mock update feed UI tests
- Dev build branding and reload scripts

### Fixed
- Notification focus handling and indicators
- Tab focus for key input
- Update UI error details and pill visibility

### Changed
- Renamed app to cmux
- Improved CI UI test stability

## [0.1.0] - 2025-01-28

### Added
- Sparkle auto-update flow
- Titlebar update UI indicator

## [0.0.x] - 2025-01-28

Initial releases with core terminal functionality:
- GPU-accelerated terminal rendering via Ghostty
- Tab management with native macOS UI
- Split pane support
- Keyboard shortcuts
- Socket API for automation
