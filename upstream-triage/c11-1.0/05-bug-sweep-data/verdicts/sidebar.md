# Sidebar batch verdicts

Read-only check of upstream cmux sidebar fixes against c11 `main` (2026-10-01). Batch file: `upstream-triage/c11-1.0/05-bug-sweep-data/batches/sidebar.tsv` (105 PRs). Round 1 already covered 6033, 6188, 8084, and 9630.

## Verified

| bug (plain English) | PRs | subsystem | c11 status | severity | port | rec | evidence (upstream file + c11 path:line) | notes (incl. link to c11 known problem) |
|---|---|---|---|---|---|---|---|---|
| Each sidebar row measures itself with a GeometryReader and writes that height into `@State`, which is fed back into the drop delegate. Layout and state chase each other. | 6111, 6558 | sidebar | shared-confirmed | high | S | reimplement | Upstream removed `rowHeightProbe` from `TabItemView` in `Sources/ContentView.swift`. c11 still has it at `Sources/ContentView.swift:12831-12841`, consumed as `targetRowHeight: rowHeight` at `:12876`. | Distinct from 6033/6188 (done in round 1): those measure the whole list with a PreferenceKey c11 never got. This probe was already in the row. It scales with workspace count and feeds known problem 2 (AttributeGraph storms in the sidebar). |
| Sidebar settings are `@AppStorage` on every row, and each row scans the full workspace list to build context-menu targets. A defaults write or a selection change rebuilds the list. | 2328 | sidebar | shared-confirmed | high | M | reimplement | Upstream `SidebarTabItemSettingsSnapshot` plus hoisted ForEach context in `Sources/ContentView.swift` (commit `9e75355525de`). c11 parent loop `Sources/ContentView.swift:8600-8607`; per-row `@AppStorage` `:11890-11908`. | Same view as known problem 2. `.equatable()` on `TabItemView` (`:11805`) does not stop the parent pass or the row's own `@AppStorage` subscriptions. |
| Process-title and metadata ticks rebuild sidebar projections on the main thread, including a synchronous metadata-store read per agent. | 7754 | sidebar | shared-probable | high | L | reimplement | Upstream memoized `workspaceSnapshot` and deferred `contextMenu` in `TabItemView` (`8443096de175`). c11 has no `SidebarWorkspaceSnapshotBuilder`. The cost is the parent body: `Sources/ContentView.swift:8651-8704` calls `surfaceTitleBarState` (`Sources/Workspace.swift:7795-7803`), which `queue.sync`s `SurfaceMetadataStore.getMetadata` (`Sources/SurfaceMetadataStore.swift:496-515`). Row `contextMenu` is still built in body at `Sources/ContentView.swift:12905`. `sidebarOrderedPanelIds()` walks the bonsplit tree per workspace (`Sources/Workspace.swift:7987-8002`). | This is known problem 2, including the 62-minute stall through `surfaceTitleBarState`. Upstream's snapshot type is not portable. Take the idea: do not recompute per-agent metadata inside `body`. |
| Claude/Codex spinner frames are real title changes. Each frame is published, written into metadata, and can retitle the window. | 10351 | titles | shared-confirmed | high | S | reimplement | Upstream `TerminalTitleChurnFilter` strips standalone spinner glyphs before sidebar/titlebar publish (`Packages/macOS/CmuxTerminalCore/.../TerminalTitleChurnFilter.swift`). c11 posts every `GHOSTTY_ACTION_SET_TITLE` on main (`Sources/GhosttyTerminalView.swift:2218-2232`). `TabManager` coalesces at 30 Hz (`Sources/TabManager.swift:1076`, `:3470-3527`) but still applies each distinct string, including metadata `setMetadata` (`:3507-3515`) and `window.title` (`:3549-3552`). No spinner filter in c11. | Known problem 2 runloop-idle backlog. Round 1 already covered window-title dedupe (8084). This is the missing filter: coalescing still forwards a new title several times a second per agent. Forty agents means steady main-queue metadata writes. |
| Every shell reports git dirty state with `git status --porcelain`, which takes `index.lock`, while agents are also running git. | 2797 | git / shell | shared-confirmed | high | S | port | Upstream removed `git status --porcelain` from the branch reporter (commit `e53b9794e993`, `Resources/shell-integration/cmux-zsh-integration.zsh`). c11 still runs it in `_cmux_report_git_branch_for_path` at `Resources/shell-integration/cmux-zsh-integration.zsh:251-254`. The HEAD watch calls that reporter (`:509`). | App-side probes use `git rev-parse` only (`Sources/Metadata/GitContextResolver.swift:97`, `:330`). The lock comes from the shell integration, once per branch report, in every terminal. At 10-40 agents that contends with the agents' own git. |
| Dev servers started by an agent (not on the shell TTY) never become sidebar ports, and a transient empty `ps` wipes every port badge. | 2562, 7952, 10633 | ports | shared-confirmed | med | M | reimplement | 2562 added an agent-PID scan beside the TTY scan (`Sources/PortScanner.swift`). 7952/10633 keep the last good snapshot when a scan is empty or incomplete. c11 `PortScanner.runScan` is TTY-only and clears all ports when `ps` returns nothing (`Sources/PortScanner.swift:124-148`). `Workspace.agentPIDs` exists (`Sources/Workspace.swift:5573`) and is not passed to the scanner. | Agents run servers as children of Claude/Codex, often off the shell TTY. Badges then either never appear or flicker off on a missed scan. |
| A port badge can stick after the owning process is a zombie, privileged, or the TTY is gone, because scans only update panels still in the TTY map. | 9324 | ports | shared-probable | med | M | reimplement | Upstream `Sources/PortScanner.swift` plus `PIDPresence` retire badges when the owner cannot be proved alive. c11 only rewrites ports for panels in `ttyNames` (`Sources/PortScanner.swift:124-169`) and unions per-surface lists in `recomputeListeningPorts` (`Sources/Workspace.swift:7979-7984`). Inferred: a panel that drops out of the snapshot keeps its last `surfaceListeningPorts` entry. | Pair with the empty-scan wipe above. The two bugs are opposite failure modes of the same scanner. |
| After `cd` out of a repo, the HEAD watcher still reports the old repo's branch, so the sidebar chip stays. | 5279 | git / shell | shared-confirmed | med | S | port | Upstream gates reports with `_cmux_git_report_path_is_active` (commit `6604cc8dc537`). c11's watch loop captures `watch_pwd` at start and keeps calling `_cmux_report_git_branch_for_path "$watch_pwd"` (`Resources/shell-integration/cmux-zsh-integration.zsh:487-509`). No active-cwd guard. | Visible on the worktree chip (C11-104) whenever an agent leaves the repo. Bash integration has the same report command (`Resources/shell-integration/cmux-bash-integration.bash:472`). |
| Each shell polls `gh` for PR status on its own 45 second loop. | 2585 | git / shell | shared-confirmed | med | M | reimplement | Upstream rate-limit fix is in `Sources/TabManager.swift` and the shell scripts (commit `5422a4bd30ac`). c11 still starts `_cmux_start_pr_poll_loop` with `_CMUX_PR_POLL_INTERVAL` default 45 (`Resources/shell-integration/cmux-zsh-integration.zsh:447-468`). | Forty shells is about one `gh` per second, sustained, for days. App-side `GitContextResolver` does not replace this poll. |
| Sparkle 2.8.1's update helper is built with the macOS 15.5 SDK. On macOS 26 the kernel rejects it, so auto-update fails with Sparkle 4005. | 6678 | updater | shared-confirmed | med | S | port | Upstream bump to Sparkle 2.9.3, commit message on `96221935ca6f`: Autoupdate agent "connection was never initiated". c11 pin is still 2.8.1 in `GhosttyTabs.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` (`identity: sparkle`, `version: 2.8.1`). | The "agent" in the title is Sparkle's helper, not a Claude/Codex process. c11 already turns 4005 into a manual-download error (`Sources/Update/UpdateViewModel.swift:394-407`, commit `e0fe228575`). Install still cannot finish until the pin moves. |
| Clicking update can abandon the install when a transient idle arrives before `.updateAvailable`. | 2168, 7174 | updater | shared-confirmed (2168); shared-probable (7174) | med | S | reimplement | 2168: `attemptUpdate` confirms only `.updateAvailable`, then stops after progress if the state is not installable (`Sources/Update/UpdateController.swift:187-210`). `dismissUpdateInstallation` forces idle (`Sources/Update/UpdateDriver.swift:153-167`) while `setStateAfterMinimumCheckDelay` may still be waiting (`:184`). 7174's double-idle abort lives in `Packages/macOS/CmuxUpdater`, which c11 does not have. The same idle sink is still in `installUpdate` (`UpdateController.swift:176-183`). | Not a hang. The pill refreshes and nothing installs. 7174 was filed against NIGHTLY. The state machine it trips is the one c11 still ships. |
| Reload configuration walks every terminal and calls `forceRefresh` on the main thread. | 10564 | terminal | shared-confirmed | med | M | reimplement | Upstream incremental apply scheduler is in `Packages/macOS/CmuxTerminalCore/.../TerminalConfigurationApplyScheduler.swift` (c11 has no `Packages/`). c11 `refreshTerminalSurfacesAfterGhosttyConfigReload` loops every panel (`Sources/AppDelegate.swift:5924-5948`) and calls `reconcileGeometryNow` plus `forceRefresh`. Triggered from `GhosttyTerminalView.reloadConfiguration` (`Sources/GhosttyTerminalView.swift:1601`, `:1630-1633`). | Appearance and Cmd-Shift-Comma reloads pay this. At 40 surfaces it is a main-thread stall, not a per-keystroke cost. `forceRefresh` on the keystroke path is a separate hot path. Do not copy the package. Schedule the refresh. |
| Workspace switches still flush AppKit layout for the terminal portal hierarchy. | 9854 | portal | shared-probable | med | M | watch | Upstream stopped `layoutSubtreeIfNeeded` inside the move-to-window callback (`Sources/GhosttyTerminalView.swift`, commit `4704a5b43ec0`) because it reentered layout on macOS 15. c11 defers external geometry to the next main turn (`Sources/TerminalWindowPortal.swift:1017-1032`) and then still lays out the host and its ancestors (`:1036-1041`, called at `:1080`). | Related to known problem 2 and to the browser portal flush called out in round 1. The exact in-callback reentry looks already deferred. The remaining flush is real. Inferred it still contributes when many surfaces resize together (sidebar toggle). |
| Sidebar toggle can flash the desktop through the terminal for a few frames because the GPU background lags the view resize. | 2378 | ghostty | shared-probable | med | L | watch | Upstream moved the terminal background to a CALayer and added Ghostty config `macos-background-from-layer` (commit `543481ce1299`, includes a `ghostty` submodule bump). That flag is absent from c11's `ghostty` tree. | Visual, every sidebar toggle. A Ghostty fork change, not a Swift patch. |
| Settings can open off the visible screen, and the open path does not pull the window back. | 5806 | settings | shared-probable | med | S | reimplement | Upstream `SettingsWindowPresenter.clampedFrame` / `targetVisibleFrame` (commit `cd4db0212759`). c11 `presentPreferencesWindow` orders the existing window front (`Sources/AppDelegate.swift:7817-7837`) with no screen clamp on that path. Main-window restore does clamp (`:3706-3713`). Inferred the Settings window does not share that helper. | Operator-facing, not an agent hang. Confirm `SettingsWindowController.show` before porting. |
| "Mark Workspace as Unread" stays disabled once the read notification objects are gone. | 3727 | notifications | shared-confirmed | low | S | reimplement | Upstream creates unread state without a retained notification. c11 disables the item unless a read notification exists (`Sources/ContentView.swift:13190-13193`) and `markUnread` only flips existing rows (`Sources/TerminalNotificationStore.swift:1169-1180`). | `manualUnreadPanelIds` exists on `Workspace` but this menu does not set it. |
| Panel title updates are already coalesced. Redundant per-OSC work was the 6552 bug. | 6552 | titles | already-fixed | low | S | skip | c11 `enqueuePanelTitleUpdate` keeps one pending title per panel and flushes on a 30 Hz coalescer (`Sources/TabManager.swift:1076`, `:3470-3486`). | Window-title writes are still undeduped (`:3549-3552`). That part is round 1 PR 8084, not this PR. |
| Closed panes clear their surface notifications. | 3744 | notifications | already-fixed | low | S | skip | c11 clears on workspace close (`Sources/TabManager.swift:1234`, `:2642`) and on surface close (`:3134`, `:3161`). |  |
| Menu-bar-only activation no longer demotes the app to `.accessory`. | 6068 | app lifecycle | already-fixed | med | S | skip | `AppPresentationPolicy.activationPolicy` always returns `.regular`, with a comment that `.accessory` blanked terminals (`Sources/AppDelegate.swift:13828-13838`). C11-196 also caches the policy so `UserDefaults` churn does not XPC `launchservicesd` (`:13854-13863`). | The upstream bug was an accidental `.accessory` write. c11 fixed the same class independently. |
| Update pill opens on the first click for a background-detected update. | 2142 | updater | already-fixed | low | S | skip | c11 commit `ff2711b6d7` "Update pill: open popover on first click for background-detected updates". | Not re-diffed line by line. The commit message matches the upstream bug. |
| Sidebar git branch and PR rows refresh from the workspace probe instead of a stale cache. | 2046, 2331, 2405, 2563, 5402 | git | already-fixed | med | M | skip | c11 applies probe snapshots onto published panel state (`Sources/TabManager.swift:1721-1758`) and caches `git rev-parse` off main (`Sources/Metadata/GitContextResolver.swift`, C11-104 / C11-106). Probe generations drop stale replies (`TabManager.swift:1687-1696`). | Shell-side `git status` and `gh` polling are separate bugs (2797, 2585, 5279). |
| Sparkle's own update dialog needed two presses. c11 does not present that dialog. | 1908 | updater | n/a-diverged | low | S | skip | `UpdateDriver.showUpdateInFocus` is a no-op: "cmux never shows Sparkle dialogs" (`Sources/Update/UpdateDriver.swift:149-151`). |  |
| Locale formatters turned sidebar port and PR numbers into grouped digits. | 3269 | sidebar | n/a-diverged | low | S | skip | c11 interpolates ports (`Sources/ContentView.swift:12809`) and PR numbers (`:12790`). No `NumberFormatter` in `ContentView.swift`. |  |
| ASCII `...` truncation was reparsed as a shorter GitHub issue number. | 15893 | sidebar | n/a-diverged | low | S | skip | c11 truncates with SwiftUI `truncationMode` (`Sources/ContentView.swift:12753`, `:12810`). It does not pre-cut the reference string with `...`. |  |
| Settings appearance used `dispatch_once` and reentered. | 4415 | settings | n/a-diverged | low | S | skip | c11 has no `AppearanceSettings.swift`. Appearance is assigned directly (`Sources/c11App.swift:1108-1110`). |  |
| LazyVStack row-frame preferences forced every sidebar row to mount during drag. | 5325 | sidebar | n/a-diverged | med | M | skip | c11 has no `SidebarWorkspaceRowFramePreferenceKey`. Drops are per-row `onDrop` (`Sources/ContentView.swift:12870-12879`). | The row-height GeometryReader (6111) is the feedback loop c11 still has. This preference overlay is a later upstream design. |
| New-workspace from the sidebar went to the key window, not the window that owns the sidebar. | 13228 | windows | n/a-diverged | med | S | skip | Upstream added `createWorkspaceAtEndFromSidebar(windowId:)` (commit `58ab2e282ad5`). c11's empty-area double-click calls the environment `tabManager` (`Sources/ContentView.swift:11219-11220`), which is that window's manager. |  |
| An answered agent notification ring stays up until something else marks the notification read. | 15974 | notifications | shared-probable | med | M | reimplement | Upstream clears Claude and Codex rings when the answer arrives (commit `6606ca2cf768`, `Sources/TerminalNotificationStore.swift` and feed ingress). c11 marks read on focus and on explicit mark-read (`Sources/TabManager.swift:3456-3467`, `Sources/ContentView.swift:13317`). No answer/hook path found that clears the ring while the agent keeps running. Inferred. | Atin answers agents in place and leaves the workspace. The ring is the attention signal. Easy to over-clear if ported onto c11's focus rules. |

## Top findings

The sidebar still does its expensive work on the main thread, inside SwiftUI `body`. `VerticalTabsSidebar` walks every workspace and every agent panel on each pass (`Sources/ContentView.swift:8600-8704`). For each agent it calls `Workspace.surfaceTitleBarState`, which synchronously reads `SurfaceMetadataStore` (`Sources/Workspace.swift:7795-7803`, `Sources/SurfaceMetadataStore.swift:496-515`). That is the stack behind known problem 2, including the 62-minute stall. Upstream's later fix (7754) was to memoize a row snapshot and stop rebuilding the context menu every pass. c11 never grew that snapshot type. The same body also still has two older feedback loops upstream removed: a per-row GeometryReader that writes `@State rowHeight` (6111, 6558, `Sources/ContentView.swift:12831-12876`) and per-row `@AppStorage` plus an all-workspaces scan inside the `ForEach` (2328, `:8600-8607` and `:11890-11908`). With 10-40 workspaces, any metadata tick, defaults write, or hover can dirty the whole list. Round 1 already recorded the LazyVStack measurement livelock (6033, 6188) as not present in c11. These three are present.

Spinner titles make that storm continuous. Claude Code and Codex animate a glyph beside a stable label. c11 treats every glyph frame as a new OSC title (`Sources/GhosttyTerminalView.swift:2218-2232`). A 30 Hz coalescer (`Sources/TabManager.swift:1076`) keeps only the latest string per panel, then still writes metadata and, for the focused surface, `window.title` (`:3507-3552`). Upstream 10351 publishes the stable label and lets only the tab glyph animate. Round 1's 8084 finding (no window-title dedupe) is the same pipe. The filter is the part c11 does not have. Forty agents spinning is a permanent main-queue tax, which is the runloop-idle backlog in known problem 2.

Shell integration fights the agents for git. `_cmux_report_git_branch_for_path` runs `git status --porcelain` (`Resources/shell-integration/cmux-zsh-integration.zsh:251-254`). That takes `index.lock`. The HEAD watch invokes it whenever HEAD changes (`:509`). Upstream 2797 stopped using `git status` for this. c11's in-app resolver already uses `git rev-parse` only, so the lock is not in Swift. It is in every terminal's shell. The same scripts keep reporting the old repo after `cd` (5279, no active-cwd guard at `:487-509`) and poll `gh` every 45 seconds per shell (2585, `:455`). That is visible chip staleness plus GitHub rate limits, on top of the lock contention.

Port badges are wrong in both directions. The scanner only sees processes on the panel TTY, so a server started by the agent itself often never appears (2562). If `ps` returns empty for one burst, every badge is cleared (7952, 10633, `Sources/PortScanner.swift:144-148`). If a panel falls out of the TTY map, the last ports can stick (9324, inferred from `recomputeListeningPorts` at `Sources/Workspace.swift:7979-7984`). `Workspace.agentPIDs` is already tracked and is not an input to the scanner.

Two updater bugs block "it updated" without hanging the agents. Sparkle is still 2.8.1. Upstream 6678 moved to 2.9.3 because the 2.8.1 helper is rejected on macOS 26 (Sparkle 4005, "agent connection was never initiated"). c11 already explains that error and offers a manual download (`Sources/Update/UpdateViewModel.swift:394-407`). It does not install. Separately, `attemptUpdate` gives up if state returns to idle before `.updateAvailable` is published (`Sources/Update/UpdateController.swift:187-210`, `UpdateDriver.swift:153-167`). The pill can look busy and then do nothing. Config reload is the other main-thread bill: one reload `forceRefresh`es every terminal (`Sources/AppDelegate.swift:5924-5928`). That is 10564, and it matters when appearance or the reload shortcut runs with dozens of live surfaces.

## Triage ledger

pr | disposition | one-line reason
1754 | noise | Titlebar update-icon alignment with the traffic lights. Cosmetic.
1800 | na-feature | Remote sidebar directory canonicalization. c11 has no remote-workspace path model of that kind.
1859 | verify-skipped | Guess n/a-diverged, low. Workspace title truncation. c11 rows use SwiftUI line limits. Not pinned.
1908 | n/a-diverged | Sparkle dialog two-press. c11 never shows Sparkle dialogs (`UpdateDriver.swift:149`).
2046 | already-fixed | Badge refresh. Later git probe writes published branch/PR state (`TabManager.swift:1721`).
2142 | already-fixed | Cached update-pill popover. c11 `ff2711b6d7` opens the popover on first click.
2168 | shared-confirmed | Update attempt drops the install on a transient idle. See table.
2218 | verify-skipped | Guess shared-probable, low. Minimal-mode titlebar state not refreshed. c11 has minimal mode. Not pinned.
2328 | shared-confirmed | In-loop scans and per-row `@AppStorage` still in `ContentView.swift`. See table.
2331 | already-fixed | Live branch/PR refresh. Covered by the C11-104 probe apply path.
2359 | verify-skipped | Guess shared-probable, low. Update error text can overflow the popover. Not pinned.
2378 | shared-probable | Desktop flash on sidebar toggle. Ghostty layer-background flag is absent. See table.
2405 | already-fixed | Duplicate git publishes. Probe generation drops stale applies (`TabManager.swift:1687`).
2562 | shared-confirmed | Agent-owned ports are not scanned. See table.
2563 | already-fixed | Missing branch metadata. Panel git branch is filled by the probe (`TabManager.swift:1722`).
2566 | noise | Color-picker context menu blink. Too small.
2585 | shared-confirmed | Per-shell `gh` poll every 45s. See table.
2797 | shared-confirmed | `git status --porcelain` takes `index.lock` in shell integration. See table.
3028 | na-feature | ContentView/file-explorer directory feedback loop. c11 has no `SessionIndexStore` or right sidebar.
3138 | na-feature | tmux `ecosystemd` idle overlay. c11 has no `TmuxWorkspacePaneOverlayView`.
3179 | verify-skipped | Guess shared-probable, low. Transparent titlebar backdrop mismatch. Not pinned.
3269 | n/a-diverged | Locale digit separators. c11 prints raw integers.
3382 | verify-skipped | Guess n/a-diverged, low. Sidebar tint backdrop ownership. c11 has no `WindowBackdropController`.
3436 | verify-skipped | Guess shared-probable, low. Settings window can sit on the display edge. Not pinned.
3546 | na-feature | Close-button hover gated by a menu-freeze tracker c11 never added.
3727 | shared-confirmed | Mark-unread stays disabled without a stored notification. See table.
3744 | already-fixed | Pane teardown already clears surface notifications (`TabManager.swift:3134`).
3833 | verify-skipped | Guess shared-probable, low. Update pill can stick on the first appcast version. Not pinned.
3874 | na-feature | Sidebar row frozen after the color menu. Same post-fork hover-freeze model as 3546.
3924 | na-feature | Feed permission banners after auto-allow. c11 has no Feed.
3946 | na-feature | ripgrep lookup for the file explorer. c11 has no file explorer.
4084 | na-feature | Unread badge frozen by the sidebar menu-freeze flag. That flag is not in c11.
4296 | verify-skipped | Guess na-feature, low. Open crash diagnostics from a notification. Not pinned.
4334 | na-feature | Suppress nested agent-hook notifications. That hook/feed pipeline is upstream-only. c11's hook flood fix is C11-156, a different bug.
4353 | na-feature | NIGHTLY bundle icon metadata.
4415 | n/a-diverged | `dispatch_once` in appearance settings. That type is not in c11.
4456 | verify-skipped | Guess shared-probable, low. Notification click fails to open Settings. Not pinned.
4481 | verify-skipped | Guess shared-probable, low. Minimal-mode titlebar icon alignment. Cosmetic.
4534 | verify-skipped | Guess already-fixed, low. Reload Configuration menu. c11 reloads from the shortcut (`AppDelegate.swift:11128`). Menu item not pinned.
4610 | noise | Sidebar edge-fade color. Cosmetic, and c11's scrims are its own.
4687 | na-feature | PDF preview toolbar. Those browser PDF types are not in c11.
4934 | na-feature | Bash job-done notification spam. c11's bash integration does not emit those notifications.
5104 | verify-skipped | Guess shared-probable, low. Sidebar-toggle animation vs titlebar inset. Cosmetic.
5127 | na-feature | Extension sidebar provider stuck when extensions are off. c11 has no extension sidebars.
5253 | na-feature | Workspace-group Delete is a no-op. c11 has no workspace groups.
5279 | shared-confirmed | Stale branch after leaving a repo. See table.
5325 | n/a-diverged | Frame-preference virtualization. c11 has no row-frame PreferenceKey.
5402 | already-fixed | App-side git probe storm. Generations plus the rev-parse cache (C11-106).
5662 | na-feature | Status pills on brand-new workspaces. Depends on `WorkspaceSidebarObservation`, which c11 does not have.
5707 | verify-skipped | Guess shared-probable, low. Titlebar shifts when the sidebar toggles. Cosmetic.
5806 | shared-probable | Settings open does not clamp an offscreen frame. See table.
5855 | noise | Status/metadata cap. Reverted the same day by 5884. Upstream `main` has no `maxSidebarStatusEntries`. Not a fix to port.
5884 | noise | Revert of 5855.
6000 | na-feature | Native notification fallback identity is wired through Feed. c11 has no Feed.
6003 | noise | Top-right titlebar drag chrome. Cosmetic.
6033 | done-round1 | LazyVStack rows-height livelock. Round 1 lead verdict: n/a-diverged.
6068 | already-fixed | Menu-bar-only activation. c11 forces `.regular` (`AppDelegate.swift:13836`).
6111 | shared-confirmed | Row-height GeometryReader feedback. Grouped with 6558.
6188 | done-round1 | Removes the rows measurement from 6033. Round 1 lead verdict.
6460 | na-feature | Title-churn beachball is mobile transcript adoption (`AgentChatTranscriptService`). c11 has no that service. Row selection is already an `Equatable` field (`ContentView.swift:11808`).
6552 | already-fixed | Panel title coalescing already exists at 30 Hz.
6558 | shared-confirmed | Same row-height feedback as 6111, re-fixed after a regression.
6678 | shared-confirmed | Sparkle 2.8.1 helper rejected on macOS 26. See table.
6804 | na-feature | Stale agent status from `WorkspaceSidebarAgentRuntimeObservationModel`. c11 pulse is PTY plus metadata, not that model.
6960 | verify-skipped | Guess n/a-diverged, low. Desktop-notification permission row stuck. Settings UI was rewritten upstream into packages c11 does not have.
7174 | shared-probable | Second idle aborts install. Same family as 2168. Package code is upstream-only. See table.
7545 | na-feature | Per-row hover reconciler. File is not in c11.
7551 | na-feature | Stale delete-group confirmation. No workspace groups.
7754 | shared-probable | Title-churn sidebar hang. c11's shape is the parent body plus `surfaceTitleBarState`. See table. Known problem 2.
7946 | na-feature | Notification retarget at delivery. Lives in notification/cloud/iOS packages c11 does not have.
7952 | shared-confirmed | Transient empty port scan clears badges. Grouped with 10633.
8067 | na-feature | Single pointer owner replacing per-row hover reconcilers. Those reconcilers are not in c11. c11's bonsplit hover stall (known problem 2) is a different path.
8084 | done-round1 | Title-churn typing latency. Round 1 lead verdict: shared-probable.
8296 | verify-skipped | Guess shared-probable, low. Confirmation dialogs do not scroll long content. Not pinned.
8513 | verify-skipped | Guess shared-probable, low. Closed windows leak under AeroSpace. Single window manager. Not pinned.
8631 | na-feature | Settings load writes unchanged UserDefaults. The store is `KeyboardShortcutSettingsFileStore`, which c11 does not have.
8892 | na-feature | CI compile fix in the AppKit sidebar list. c11 has no `Sources/Sidebar/AppKitList`.
9037 | na-feature | Fork Conversation menu enablement. c11 has no that command.
9324 | shared-probable | Stale port badges after vanished TTYs and zombies. See table.
9613 | na-feature | AppKit `SidebarRowTextView` link colors. No AppKit sidebar list.
9630 | done-round1 | `UNUserNotificationCenter` beachball. Round 1 lead verdict: shared-probable.
9854 | shared-probable | Workspace-switch layout reentry. c11 still flushes portal layout, but on a later turn. See table.
10074 | na-feature | AppKit sidebar row ownership during layout. No AppKit list.
10169 | na-feature | Collapsed sidebar group pops open when the workspace below closes. No groups.
10351 | shared-confirmed | Spinner frames published as titles. See table.
10564 | shared-confirmed | Reload fans `forceRefresh` to every surface. See table.
10591 | na-feature | SF Symbol raster helper `RenderableSystemSymbol` is not in c11.
10633 | shared-confirmed | Same empty-scan port wipe as 7952.
10822 | verify-skipped | Guess shared-probable, low. Notification cleanup can drop the wrong in-flight item. `TerminalNotificationStore` exists. Not pinned.
11476 | na-feature | Terminal file-upload failure UI. Those upload types are not in c11.
12283 | verify-skipped | Guess shared-probable, low. Sparkle callbacks after cancel. Not pinned.
12298 | verify-skipped | Guess n/a-diverged, low. Main windows enter fullscreen tiling. c11 has no `CmuxMainWindow`. Not pinned.
12455 | noise | Agent-notification CI reliability only.
12473 | na-feature | NIGHTLY update-pill UI test.
12594 | noise | Compile fix, including cloud tree UI c11 does not have.
12929 | na-feature | Non-glass overlay host in `CmuxAppKitSupportUI`. That package is not in c11.
13228 | n/a-diverged | Sidebar creates workspaces on the environment tab manager (`ContentView.swift:11220`).
13688 | na-feature | Reorder crash on a pinned group's anchor. c11 pins are a boolean, not a group anchor.
14406 | noise | Test harness. Product change in `GhosttyTerminalView` is a DEBUG-only config swap.
15422 | na-feature | Split-space admission for cloud/sidebar panes. c11 has no split-space types.
15756 | verify-skipped | Guess shared-probable, low. Updater badge icon draws blank. Cosmetic.
15887 | na-feature | Hook activity keeps agent status "running". That work-state model is in packages c11 does not have.
15893 | n/a-diverged | Ellipsis reparse. c11 does not pre-cut references with `...`.
15974 | shared-probable | Notification ring not cleared when the agent is answered. See table.
16408 | na-feature | CI compile unblock for custom sidebars and bonsplit tests. No product bug in c11.

## Counts

rows 105, na-feature 36, noise 9, done-round1 4, verify 56 (confirmed 14, probable 7, already-fixed 9, n/a-diverged 6, skipped 20)
