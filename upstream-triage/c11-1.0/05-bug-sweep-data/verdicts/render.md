# Render batch verdicts

Read-only check of upstream cmux render fixes against c11 main. Ghostty HEAD `26c3e499e`. Inferences are marked.

## Verified

| bug (plain English) | PRs | subsystem | c11 status | severity | port | rec | evidence (upstream file + c11 path:line) | notes (incl. link to c11 known problem) |
|---|---|---|---|---|---|---|---|---|
| Switching workspaces calls `ghostty_surface_set_occlusion` on main, and that pushes the renderer mailbox with `.forever`. A full mailbox parks main forever | 8793 | ghostty / render | shared-confirmed | high | S | reimplement | Upstream: nonblocking lifecycle publication. c11 `ghostty/src/Surface.zig:3336-3339` and focus at `:3352-3354`. Called from `Sources/Panels/TerminalPanel.swift:112` | Same 64-slot mailbox as the 2026-08-25 `Surface.deinit` deadlock (`stream_handler.zig:134`, `mailbox.zig:92`). c11 already stopped this for display id only (`ghostty/src/apprt/embedded.zig:2172-2198`, known fix of #403). Copy that `.instant` pattern onto occlusion and focus. The rest of 8793 (remote sidebar worker, keychain autosave, hang sampler) is upstream-only. |
| Ghostty action callbacks still mutate the terminal view off the main thread, so macOS 26 paints a black terminal | 1937 | render | shared-confirmed | high | S | port | Upstream wrapped `SCROLLBAR`, `CELL_SIZE`, `COLOR_CHANGE`, `CONFIG_CHANGE` in `DispatchQueue.main.async`. c11 sets them inline in `Sources/GhosttyTerminalView.swift:2161-2180` and `:2281-2295` (`applySurfaceBackground` on the callback thread) | Agents change titles, bells, and OSC colors all day. Search and title paths in the same switch are already async. Read C strings before hopping threads. |
| An unread-notification ring change rebinds the whole terminal portal, which blanks the focused surface | 3048 | render | shared-confirmed | high | S | port | Upstream stopped treating a ring-only change as a rebind. c11 still does, `Sources/GhosttyTerminalView.swift:10195-10220` (`previousDesiredShowsUnreadNotificationRing != showsUnreadNotificationRing`) | Claude and Codex fire OSC completion notices constantly. Each one rebinds the portal (and can re-enter the layout crash below). |
| `ContentView` stores a `DispatchWorkItem` in `@State` that captures the view value, so tearing the view down recursively releases it and crashes | 9921 | sidebar | shared-confirmed | high | M | reimplement | Upstream moved deferred handles to a reference-owned scheduler. c11 `Sources/ContentView.swift:1492` and the capturing item at `:1882-1893`. Same shape at `:1496` (timer) and `:1517` | Hits window rebuilds and workspace close during long sessions. Do not store closure-bearing objects in `@State` on this view. |
| Portal `bind` runs `layoutSubtreeIfNeeded` inside a SwiftUI layout turn and can abort in the display-link flush | 3885, 4102 | portal | shared-confirmed | high | M | reimplement | Upstream added `deferLayoutSynchronization` so representable updates do not sync layout. c11 `bind` has no such flag: `Sources/TerminalWindowPortal.swift:1512` calls `ensureInstalled` then `synchronizeLayoutHierarchy` at `:1036-1040`, then syncs the hosted view at `:1640` | 4102 is the lag follow-up that keeps this guard. c11 already defers some external geometry (`:1017-1031`) but not bind itself. Adjacent to known problem 2 (main-thread layout storms). |
| A layout follow-up calls `displayIfNeeded` on every window before the current display pass finishes | 2305 | layout | shared-probable | high | S | port | Upstream deferred `attemptEventDrivenLayoutFollowUp`. c11 still calls it immediately at `Sources/Workspace.swift:10569`, and the flush is `:10680-10684` from `:10739` | The original trigger (`splitTabBar` geometry) now only schedules (`:13389-13394`), which is why 12521 is n/a. Focus and split-zoom still enter the sync flush (`:10050`, `:10179`). Inferred: those can still nest inside AppKit display. |
| Hidden terminals keep their Metal swapchains for the life of the process | 8998 | render / memory | shared-confirmed | high | L | reimplement | Upstream reclaims hidden renderers after idle time. c11 only sets occlusion, `Sources/GhosttyTerminalView.swift:3923-3925`. No `RendererRealization` types | Same bug lead already confirmed for 5857, 7050, 10815, 10922. Days-long 40-surface sessions. A port must include the deadlock follow-up lead named (`7b24d1c5d`) or it recreates a teardown hang. 8540 is a bug inside that state machine and does not apply. |
| Live window and divider resize forwards every pixel-size change through `ghostty_surface_set_size`, so each pane SIGWINCHes and repaints over itself | 6386, 8240 | render / pty | shared-confirmed | med | M | reimplement | Upstream coalesces pixel-only changes and flushes grid size at the end of the drag. c11 `updateSize` sends any pixel delta, `Sources/GhosttyTerminalView.swift:3823-3848` | Resize deferral only covers tab drags (lead, on 11528). One resize hits every visible pane. |
| Every printable key calls `forceRefresh` on the typing path | 3986 | render | shared-confirmed | med | S | port | Upstream deleted the per-text `forceRefresh`. c11 still sets it for sent text, `Sources/GhosttyTerminalView.swift:5892-5900`, `:5964-5966`, `:6018-6022` | Operator typing, not agent `send`. This is the path Agents.md calls out as keystroke-hot. Ghostty wakeups already redraw. |
| Every workspace row registers a Bonsplit `onDrop`, so a drag asks every row to validate on the main thread | 10552 | sidebar | shared-confirmed | med | S | port | Upstream moved validation to one parent overlay. c11 rows still attach both drop delegates, `Sources/ContentView.swift:12870-12885` | Scales with workspace count. Drag is less common than typing, but a drag across a 40-workspace sidebar is a main-thread stall. Feeds known problem 2. |
| `NSColor.darken` calls `getHue` without converting to sRGB, which raises on catalog and grayscale colors | 10627 | theme | shared-confirmed | med | S | port | Upstream converts via `usingColorSpace(.sRGB)` first. c11 `Sources/GhosttyConfig.swift:644-655`, called for split dividers at `:59-60` | A thrown ObjC exception aborts the app. Theme and divider colors hit this. |
| A resize that lands before the layer is a `CAMetalLayer` never retries the drawable size, so the first Metal frame stays at the old size | 6057 | render | shared-confirmed | med | S | port | Upstream retries until the metal layer exists. c11 updates `drawableSize` only inside `if let metalLayer`, `Sources/GhosttyTerminalView.swift:4838-4848`. The retry at `:4737` runs only for an active deferral reason | New splits and restores are born at 800x600 (lead). The layer often is not Metal yet. |
| `refreshSurfaceNow` calls `forceRefresh` before AppKit has realized the hosted view, so a new split stays blank | 2840 | render | shared-confirmed | med | S | port | Upstream flushes layout and display on the scroll view and the surface view first. c11 `Sources/GhosttyTerminalView.swift:7470-7471` only force-refreshes | Shows up on split and portal reveal, which agents do constantly. |
| Rebuilding a renderer row reads `shaped_cells[shaper_cells_i]` before checking the index, and traps when the tail is empty | 3916 | ghostty | shared-confirmed | med | S | port | Upstream bounds the cursor. c11 `ghostty/src/renderer/generic.zig:3073` asserts on that index. The following loop at `:3079` does check length | Wide glyphs and preedit. A crash inside the renderer, not every frame. |
| Keys that arrive before the Ghostty runtime exists are passed to `super`, so AppKit beeps or inserts them into the wrong view | 15738 | input | shared-confirmed | med | S | port | Upstream consumes the event. c11 `Sources/GhosttyTerminalView.swift:5602-5607` calls `super.keyDown` | Frequent during surface create, which is the normal agent-spawn path. |
| While command-palette Escape suppression is set, every Escape repeat is consumed and the timeout never runs | 1957 | input | shared-confirmed | med | S | port | Upstream removed the repeat early-return. c11 `Sources/AppDelegate.swift:5665-5672` returns true for `isARepeat` before the 0.35s check | lazygit and vim treat held Escape as a real key. A lost keyUp keeps eating Escape. |
| `ghostty_init` calls `setlocale(LC_ALL)`, which can set a comma `LC_NUMERIC` for the whole process and crash CoreUI symbol rasterization | 12235 | render | shared-confirmed | med | S | port | Upstream pins `LC_NUMERIC` back to `C` after init. c11 `ghostty/src/os/locale.zig:32`. No `GhosttyNumericLocaleController` under `Sources/` | Reported on macOS 27. Process-wide, so every SF Symbol after launch is exposed. |
| After a workspace switch, a portal entry can stay visible because the registry does not know which workspace owns it | 3155, 12414 | portal | shared-probable | med | M | reimplement | Upstream stamps a workspace id and clamps visibility, and hides every entry on retire. c11 hides on handoff (`Sources/ContentView.swift:3482-3489`) but portal entries have no workspace gate (no `portalRenderingEnabled`) | Handoff hide covers the clean switch. Queued callbacks can still resurrect a layer. Inferred from the missing gate. Related to blank-after-switch, partly covered by occlusion (1964, already fixed). |
| The divider overlay sets `needsDisplay` on every portal sync, even when the dividers did not change | 12009 | portal | shared-confirmed | med | S | port | Upstream repaints only when the overlay could have changed. c11 `Sources/TerminalWindowPortal.swift:1185-1188` | Cheap per call, but portal sync runs on resize and workspace churn across every pane. |
| Light themes can paint white text on a white terminal when the host appearance and the surface config disagree | 4278, 4567, 4795, 5826, 6896, 12812 | theme | shared-probable | med | M | watch | Several upstream passes in `GhosttyConfig` and surface reload. c11 still takes the scheme from `effectiveAppearance` at `Sources/GhosttyTerminalView.swift:4893-4898` and darkens the divider from the background at `Sources/GhosttyConfig.swift:54-60` | Inferred grouping. I did not line-check each PR. Real for Light theme slot users. Lower value if the operator stays on Dark. |
| Sidebar PR status keeps being collected when the sidebar is hidden | 4820 | sidebar | shared-probable | med | S | watch | Upstream gates the poll on sidebar visibility. c11 still aggregates PR rows at `Sources/Workspace.swift:5246-5269` and turns shell integration on by default at `Sources/GhosttyTerminalView.swift:3596` | Inferred: I did not find the timer. Cost scales with workspace count, not with keystrokes. |
| Releasing one side of a modifier while the other stays down leaves Ghostty thinking the modifier is stuck, so later input is wrong | 2855 | input | already-fixed | low | - | skip | c11 `Sources/GhosttyTerminalView.swift:6092-6163`, commit `b218dcdabb` (C11-21) | |
| Hidden workspaces do not pause Ghostty occlusion, so coming back shows a stale blank frame | 1964 | render | already-fixed | - | - | skip | c11 lifecycle calls `setOcclusion(target == .active)` at `Sources/Panels/TerminalPanel.swift:107-112` | Distinct from C11-225, which skips `updateFrame` while occluded (CPU, not this blank frame). |
| Retiring a workspace leaves its portals on screen over the new one | 2658 | portal | already-fixed | - | - | skip | c11 `Sources/ContentView.swift:3482-3489` hides terminal and browser portals before unmount | |
| The first frame of a workspace switch omits the selected workspace, then snaps | 12310 | layout | already-fixed | - | - | skip | c11 forces the selected id to the front of the mounted set, `Sources/ContentView.swift:1349-1351` and `:1377-1379` | The bonsplit ratio-init half of 12310 was not line-checked. |
| Exact-slot Metal frame leases reuse one IOSurface, so typing presents a stale frame | 8848 | ghostty | n/a-diverged | - | - | skip | No frame-lease symbols in c11 ghostty. The bump `50ad1963d9` is not an ancestor of `26c3e499e` | The bounded renderer-mailbox half of this PR is lead's `188d31a97` / `2cfe9b349` (drainMailbox livelock). Do not port the lease rotation. |
| Offscreen helper terminals never get a PTY | 4233 | render | n/a-diverged | - | - | skip | Later rewritten. The surviving bug is 9796, already verified in lead | |
| Inherited config treats a non-nil surface pointer as proof the native surface is alive | 8656 | render | n/a-diverged | - | - | skip | Upstream added a registry ownership probe. c11 has no `TerminalSurfaceRegistry`. It nils the pointer before free, `Sources/GhosttyTerminalView.swift:4272-4300` | See 1915 for the older stale-pointer guess. |
| Geometry reconciliation re-enters itself during a workspace switch | 12725 | layout | n/a-diverged | - | - | skip | c11 `splitTabBar(_:didChangeGeometry:)` only schedules, `Sources/Workspace.swift:13389-13394`. Same reason lead gave for 12521 | The other 50 files are mobile diagnostics and Sentry. |
| Every `UserDefaults` write re-evaluates the window root because dotted keys are key paths | 14058 | sidebar | n/a-diverged | - | - | skip | Upstream renamed dotted keys (`titlebarDebug.leftControls…`, extension sidebar provider). c11 has no extension sidebar. Root `@AppStorage` keys inspected are undotted, `Sources/ContentView.swift:2211-2216` | c11's own dotted-key KVO lesson (`c11.tabRailTip.forceOffer`) is a different view and a different symptom. |
| A second surface inherits a font pointer the first surface already freed (Intel crash) | 1915, 2101 | render | shared-probable | low | S | watch | Upstream guarded inheritance. c11 still takes the first non-nil `surface.surface`, `Sources/Workspace.swift:8538-8542` | Intel-only crash in the report. Atin's machines are Apple silicon. 2179 tried a broader fix and 2267 reverted it, so there is no later patch to cherry-pick. |
| `DebugEventLog` calls `seekToEndOfFile` on `NSFileHandle`, which throws an ObjC exception | 3034 | debug | shared-confirmed | low | S | watch | Upstream uses `try? seekToEnd`. c11 `vendor/bonsplit/Sources/Bonsplit/Public/DebugEventLog.swift:68` and `Sources/GhosttyTerminalView.swift:1018` | `dlog` is DEBUG-only, so production `c11.app` does not hit the bonsplit path. Dev builds do. |
| If the bundled shell-integration directory is missing, c11 still exports `ZDOTDIR` at it and zsh skips the user's config | 5773 | shell | shared-confirmed | low | S | watch | Upstream checks the directory exists. c11 sets `ZDOTDIR` whenever the pref is on, `Sources/GhosttyTerminalView.swift:3597-3630`, with no `fileExists` | Only bites a damaged bundle. Normal launches are fine. |
| A malformed `LC_ALL` makes the spawned shell fall back to the `C` locale | 7183 | shell | shared-probable | low | S | watch | Upstream sanitizes `LC_ALL` and `LC_CTYPE`. No sanitizer under `Sources/` | Inferred. Only a broken parent environment triggers it. |
| Shell integration still starts helpers for features the user turned off, before the first prompt | 14847 | shell | shared-probable | low | S | watch | Upstream gates spawns on the feature flags inside the bundled scripts. c11 enables the integration as a block, `Sources/GhosttyTerminalView.swift:3596-3630` | Inferred. I did not diff the zsh script line by line. |
| A coalesced live-resize geometry pass can take the slow path and trail the drag by extra runloop turns | 14297 | portal | shared-probable | low | S | watch | Upstream uses one live-resize predicate for the queued pass. c11 captures the predicate at schedule time, `Sources/TerminalWindowPortal.swift:1017-1031`, and drops a later request while `hasExternalGeometrySyncScheduled` is set | Inferred from that coalesce. Resize lag, not a hang. |

Rows marked verify in the ledger and not in this table were not line-checked. Their guesses are in the ledger.

## Top findings

Workspace switches block the main thread on Ghostty's renderer mailbox. Each terminal's lifecycle calls `ghostty_surface_set_occlusion` when it leaves or enters `.active` (`Sources/Panels/TerminalPanel.swift:112`). That function pushes `.visible` with `.forever` (`ghostty/src/Surface.zig:3336-3339`). Focus does the same (`:3352-3354`). The renderer mailbox is a bounded blocking queue. If the renderer stops draining, main parks in a futex and the app beachballs. c11 already fixed this exact pattern for `ghostty_surface_set_display_id` (`embedded.zig:2172-2198`, the #403 deadlock) and left occlusion and focus on `.forever`. It is the same queue as the 2026-08-25 teardown deadlock, reached here without closing a surface. A switch across a workspace that holds many hidden agent terminals is the trigger upstream reproduced (13 workspaces, 29 surfaces). The patch is the display-id pattern: wake the renderer, push `.instant`, drop the update if the queue is full. Do not take the rest of PR 8793.

Ghostty still delivers scrollbar, cell-size, and background-color actions on a background thread (`Sources/GhosttyTerminalView.swift:2161-2180` and `:2281-2295`). macOS 26 turns those off-main AppKit writes into a black terminal. Search and title in the same callback are already bounced to main. This one is a small, local port. With many agents, OSC color and cell-size traffic is normal, not rare.

Completion notifications blank the terminal the operator is looking at. The SwiftUI representable treats an unread-ring toggle as a reason to rebind the portal (`Sources/GhosttyTerminalView.swift:10200` and the `bind` at `:10213`). Claude Code and Codex emit those OSC notices all day. Rebind is also how the display-link crash in `TerminalWindowPortal.bind` gets re-entered (PR 3885): `bind` calls `layoutSubtreeIfNeeded` with no defer flag (`TerminalWindowPortal.swift:1512` and `:1036-1040`). Fix the ring check first. It is a one-condition change. The portal defer is a larger rewrite of bind.

`ContentView` keeps a `DispatchWorkItem` in `@State` (`Sources/ContentView.swift:1492`) whose closure calls instance methods and therefore captures the whole view value (`:1882-1893`). Releasing that state releases the view, which releases the work item, and upstream saw that chain crash (a 130-field view, a 91 KB destroy). A timer and another work item sit in `@State` beside it (`:1496`, `:1517`). Long sessions rebuild this view. Move those handles to a class the view does not capture.

Hidden terminals never give back their GPU memory, and a window resize tells every pane to change PTY size. c11 has occlusion but no renderer reclaim (`GhosttyTerminalView.swift:3923-3925`). Lead already matched that to upstream's multi-GB IOSurface growth (PRs 8998 and 10922). Separately, `updateSize` forwards every pixel change during a drag (`:3845-3848`), so a resize of a multi-pane workspace is a SIGWINCH storm and overlapping paints (PRs 6386 and 8240). The memory port is large and must include the deadlock follow-up lead named. The resize coalesce is a medium port of an idea c11's size path can hold.

## Triage ledger

pr | disposition | one-line reason
1308 | verify-skipped | Font-family fallback chain. Guess shared-probable, low, watch. Not line-checked.
1826 | na-feature | AppleScript window count. c11 has no AppleScriptSupport.
1837 | verify-skipped | Pane drag/drop handoff delay. Guess shared-probable, low, watch.
1858 | verify-skipped | Background opacity and blur on the terminal view. Guess shared-probable, low, watch.
1915 | verify | Stale font pointer on an inherited second surface. See the verified table.
1937 | verify | Off-main Ghostty callbacks paint a black terminal. Confirmed.
1957 | verify | Escape repeats swallowed during palette suppression. Confirmed.
1964 | verify | Blank terminal after workspace switch. Already fixed via lifecycle occlusion.
2018 | verify-skipped | Wider content-edge hit slop. Guess n/a-diverged, low. Hit testing was rewritten for the typing path.
2101 | verify | Inherited config trusts any non-nil surface pointer. Grouped with 1915.
2179 | noise | Intel inheritance crash fix. Reverted by 2267, so nothing survived upstream.
2241 | verify-skipped | Skip CJK fallback when the family already covers the glyphs. Guess shared-probable, low, watch.
2267 | noise | Revert of 2179.
2305 | verify | Synchronous displayIfNeeded in the layout follow-up. Probable.
2413 | na-feature | Stray C from Speakly dictation. c11 has no Speakly hook.
2613 | verify-skipped | Prompt colors under TERM=xterm-256color, plus a ghostty bump. Guess n/a-diverged, low. Different ghostty line.
2622 | verify-skipped | Sidebar background locale strings and a portal resync. Guess already-fixed, low.
2658 | verify | Hide stale portals while a workspace is torn down. Already fixed.
2813 | verify-skipped | Allow a symlinked Ghostty config file. Guess shared-probable, low, watch.
2840 | verify | Blank split after portal reveal. Confirmed.
2855 | verify | Modifier desync. Already fixed in C11-21.
3034 | verify | DebugEventLog NSFileHandle exception. Confirmed, debug-only.
3048 | verify | Notification ring rebinds the portal and blanks the terminal. Confirmed.
3055 | verify-skipped | Minimal-mode traffic-light inset. Guess shared-probable, low. c11 has minimal mode. Inset math diverged.
3150 | verify-skipped | Minimal-mode routing and portal hit testing. Guess n/a-diverged, low. Hit-test half is 6592 (done-round1).
3152 | verify-skipped | Keep the selected workspace scrolled into view. Guess shared-probable, low.
3155 | verify | Hide portals for unmounted workspaces. Grouped with 12414.
3194 | verify-skipped | Minimal-mode drag pass-through on new windows. Guess shared-probable, low.
3399 | verify-skipped | Minimal-mode pane tab rendering. Guess shared-probable, low.
3525 | verify-skipped | Settings opens the active Ghostty config. Guess shared-probable, low.
3612 | verify-skipped | Keep the Settings window above the main window. Guess shared-probable, low.
3769 | verify-skipped | Multi-image drops onto a terminal. Guess shared-probable, low. Rare here.
3836 | noise | McBopomofo candidate fix. Reverted by 3845.
3845 | noise | Revert of 3836.
3885 | verify | Display-link crash from portal layout reentry. Confirmed. Grouped with 4102.
3916 | verify | Metal row rebuild reads past the shaped-cell cursor. Confirmed.
3956 | verify-skipped | Discover user themes on disk. Guess shared-probable, low.
3986 | verify | Key-repeat forceRefresh. Confirmed.
4083 | verify-skipped | Selected workspace visible after a sidebar reorder. Guess shared-probable, low. Same family as 3152.
4102 | verify | Portal resize lag, keeping the 3885 crash guard. Grouped with 3885.
4121 | verify-skipped | Surface tab bar action buttons clip. Guess shared-probable, low.
4233 | verify | Offscreen helper PTY startup. Superseded by 9796 (done-round1). n/a-diverged.
4278 | verify | Conditional light-theme foreground. Grouped in the theme row.
4359 | verify-skipped | Repeated theme-set reloads. Guess shared-probable, low.
4567 | verify | Split theme appearance resolution. Grouped in the theme row.
4594 | verify-skipped | Markdown names with trailing punctuation open as URLs. Guess shared-probable, low.
4652 | verify-skipped | Theme picker chrome preview sync. Guess n/a-diverged, low. Theme UI diverged.
4728 | verify-skipped | Terminal environment injection. Guess n/a-diverged, low. c11 startup env was rewritten.
4780 | verify-skipped | Match the sidebar to the terminal background. Guess shared-probable, low cosmetic.
4795 | verify | Embedded split theme resolution. Grouped in the theme row.
4820 | verify | PR polling while the sidebar is hidden. Probable.
5474 | verify-skipped | Main window minimum width ratchets up. Guess shared-probable, low.
5488 | verify-skipped | Sidebar close button sits under a wrapped title. Guess shared-probable, low cosmetic.
5773 | verify | ZDOTDIR hijack when the bundle bootstrap is missing. Confirmed, low.
5826 | verify | Light theme white-on-white. Grouped in the theme row.
6057 | verify | Stale Metal drawable after the layer becomes Metal. Confirmed.
6341 | na-feature | 100% CPU from a bundled extension sidebar. c11 has no extension-sidebar provider.
6386 | verify | Terminal content duplicated on window resize. Grouped with 8240.
6396 | na-feature | Blank SF Symbols on macOS 27 via RenderableSystemSymbol, which c11 does not have.
6589 | na-feature | Hidden popover relayout in CmuxAppKitSupportUI. c11 does not have that package.
6592 | done-round1 | Portal hit-test CPU. Already in verdicts-lead.md.
6613 | na-feature | Sidebar lag from per-row cmuxFont modifiers. No cmuxFont in c11 Sources.
6653 | verify-skipped | Surface tabs should hug their title. Guess shared-probable, low. Bonsplit.
6896 | verify | Light-theme host/surface divergence. Grouped in the theme row.
7183 | verify | Malformed LC_ALL collapses the shell locale to C. Probable, low.
7497 | noise | Path fragments opened as HTTPS. Reverted by 7499.
7499 | noise | Revert of 7497.
7637 | verify-skipped | Tab icon shifts during pane resize. Guess shared-probable, low.
7729 | na-feature | macOS 15 blank icons via CmuxResolvedIconRenderer. c11 does not have that type.
7740 | na-feature | Stale terminal agent tab icons. c11 agent chips are metadata, not TerminalTabAgentIcon.
7763 | noise | Custom shaders paint black. Reverted by 7778.
7778 | noise | Revert of 7763.
7815 | noise | CI fix for a ghostty-vt static lib name and a committed rust target.
8115 | na-feature | Popover resize crash in upstream popover and session-index hosts c11 does not ship.
8168 | verify-skipped | Automatic terminal top inset. Guess shared-probable, low.
8195 | na-feature | Update-pill popover resize reentrancy in CmuxUpdaterUI.
8234 | noise | CmuxTerminal package test link stubs.
8240 | verify | Coalesce resizes during divider drags. Grouped with 6386.
8540 | na-feature | Background surfaces marked presented inside the post-fork realization state machine. c11 never got that machine.
8626 | na-feature | Sidebar reopen cutoff in AppKitList. c11 does not use that sidebar.
8656 | verify | Registry no longer owns an inherited surface. n/a-diverged.
8793 | verify | Workspace switch blocks on a renderer mailbox push. Confirmed.
8848 | verify | Frame-lease typing lag. n/a-diverged. Renderer-drain half is already in lead.
8964 | verify-skipped | zsh prompt wrap spacer lines. Guess shared-probable, low.
8967 | na-feature | Blank pane after a skipped layout, inside the presentation state machine c11 does not have.
8998 | verify | Reclaim hidden renderer memory. Confirmed. Same bug as lead's 10922.
9000 | done-round1 | openThread stderr loops. n/a-diverged in verdicts-lead.md.
9063 | verify-skipped | Dim text after an appearance change. Guess shared-probable, low.
9111 | na-feature | Stalled remote PTY attach. c11 has no CmuxRemoteDaemon.
9117 | done-round1 | drainMailbox livelock. Ghostty commit 2258bea96 is already in verdicts-lead.md.
9211 | verify-skipped | Hanging bundled theme picker helper. Guess n/a-diverged, low.
9358 | done-round1 | Sidebar teardown hang in TerminalSurfaceRuntimeTeardownCoordinator. n/a in verdicts-lead.md.
9486 | verify-skipped | Ghostty opener stderr bursts. Guess n/a-diverged, low.
9764 | verify-skipped | Surface-scoped theme reload order. Guess shared-probable, low.
9796 | done-round1 | Cold PTY never attaches. Already in verdicts-lead.md.
9921 | verify | Recursive @State work-item release. Confirmed.
10089 | verify-skipped | Sidebar leading edge clips after resize. Guess shared-probable, low cosmetic.
10133 | na-feature | Unbounded git status watches in CmuxGit. c11 does not have that package.
10223 | verify-skipped | Terminal open event delivered twice. Guess shared-probable, low.
10492 | verify-skipped | White chrome icons on translucent light themes. Guess shared-probable, low cosmetic.
10510 | done-round1 | Title churn into NSWindow.title. Already in verdicts-lead.md.
10552 | verify | Per-row drop validation stalls main. Confirmed.
10569 | noise | SPM target-name collision. CI only.
10627 | verify | NSColor.darken crashes on non-RGB colors. Confirmed.
10661 | na-feature | Idle History menu rebuild. c11 has no HistoryMenuCoordinator.
10856 | verify-skipped | Portal scans every entry to find a pane's tab. Guess shared-probable, low. See synchronizeAllHostedViews at TerminalWindowPortal.swift:1732.
10901 | verify-skipped | Privacy prompts for terminal child processes. Guess shared-probable, low. Entitlement strings.
10922 | done-round1 | Present renderers that never report occlusion visible. Already in verdicts-lead.md (memory reclaim group).
10967 | verify-skipped | Light-mode window-chrome separators. Guess shared-probable, low cosmetic.
11528 | done-round1 | Transient PTY resizes during workspace reveal. Already in verdicts-lead.md.
11530 | noise | Text bleed during live resize. Reverted by 11887.
11887 | noise | Revert of 11530.
11954 | na-feature | Blank-after-completion fix is in CmuxWorkspaces reorder coordinators. The OSC blank is 3048.
12009 | verify | Divider overlay repaints every sync. Confirmed.
12066 | verify-skipped | Honor Ghostty split-divider-color. Guess shared-probable, low. c11 already derives a divider color.
12210 | noise | Terminal colors and pane clipping. Reverted by 12329.
12235 | verify | Pin LC_NUMERIC so CoreUI does not crash. Confirmed.
12310 | verify | Flicker and late layout on workspace switch. Already fixed by the mount policy.
12329 | noise | Revert of 12210.
12343 | verify-skipped | Link routing and Option dead-key. Guess shared-probable, low. English input. Dead-key note is in lead.
12414 | verify | Stale portal layers after a workspace switch. Probable. Grouped with 3155.
12521 | done-round1 | Reentrant geometry publish. n/a-diverged in verdicts-lead.md.
12725 | verify | More reentrant-geometry guards plus diagnostics. n/a-diverged, same reason as 12521.
12783 | na-feature | Checklist remove-button rendering in AppKitList. c11 does not have that sidebar.
12812 | verify | Light terminal defaults when Ghostty settings carry no color. Grouped in the theme row.
13191 | verify-skipped | Ghostty environment-lifetime bump (c5c31ce819) is not in c11. Guess n/a-diverged: Exec.zig:561 already owns an EnvMap. The bump also carries Cloud loopback.
13574 | verify-skipped | Stale zoom intent after an external resize. Guess shared-probable, low.
14058 | verify | Dotted defaults keys re-evaluate chrome. n/a-diverged.
14297 | verify | Coalesced live-resize pass takes an extra hop. Probable, low.
14442 | na-feature | Runs of "?" treated as lost paste text, in the CmuxTerminal paste worker. c11 does not have that worker.
14841 | na-feature | A second sidebar resolves content against its own backdrop. Package c11 does not have. c11 has one sidebar.
14847 | verify | Shell integration spawns helpers for disabled features. Probable, low.
14888 | noise | Test-only teardown of hosted terminals.
15369 | verify-skipped | Keep the terminal visible when side panels do not fit. Guess shared-probable, low.
15520 | noise | Live surfaces that never present a frame. Reverted by 15788.
15550 | verify-skipped | Pane drop target draws in the wrong pane. Guess shared-probable, low.
15738 | verify | Keys fall through to super while the runtime is down. Confirmed.
15788 | noise | Revert of 15520.
15848 | na-feature | Preserve C1 replies in the CmuxTerminal input parser. c11 send is ghostty_surface_text, not that parser.
15849 | na-feature | Preserve SOS replies. Same parser c11 does not have.
16261 | noise | Bonsplit bump that only changes narrow-pane rendering test assumptions.

## Counts

rows 141, na-feature 22, noise 19, verify 91, done-round1 9. Of verify: confirmed 21, probable 15, already-fixed 4, n/a-diverged 5, skipped 46.
