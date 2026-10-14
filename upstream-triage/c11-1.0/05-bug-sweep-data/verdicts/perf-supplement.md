# perf-supplement verdicts

Read-only check of upstream cmux performance PRs against c11 `main` (2026-10-01). Round-1 files checked before each verify: `verdicts-lead.md`, `verdicts-browser.md`, `verdicts-focus.md`. A PR number that only appeared as a line citation was not treated as done.

## Verified

| bug (plain English) | PRs | subsystem | c11 status | severity | port | rec | evidence | notes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Every Ghostty wakeup enqueues its own `tick()` on main, and every scrollbar action posts immediately, so bulk agent output floods the main queue | 2116 | terminal / main thread | shared-confirmed | high | S | port | Upstream `Sources/GhosttyTerminalView.swift` (`scheduleTick`, `enqueueScrollbarUpdate`). c11 `wakeup_cb` is an uncoalesced `DispatchQueue.main.async { tick() }` at `Sources/GhosttyTerminalView.swift:1069-1072`. Scrollbar is applied and posted inline at `:2161-2168`, with no coalesce. | Direct feed for known problem 2 (main queue minutes deep, late `runloop-idle` heartbeats). Inferred: a main thread stuck draining ticks also delays the mailbox drain in the 2026-08-25 `Surface.deinit` deadlock. Upstream measured `seq 1 10000` dropping from 0.052s at 26% CPU to 0.016s. |
| Each Claude hook event launches the full c11 CLI | 14931, 14834 | claude wrapper / hooks | shared-confirmed | high | M | reimplement | Upstream spool: one forwarder per session, hook commands are shell builtins. c11 still generates per-event CLI hooks at `Resources/bin/claude:205` (`c11 claude-hook pre-tool-use` and the other lifecycle hooks). | Upstream measured about 61 ms CPU and 104 ms wall per event before the spool. PreToolUse fires on every tool call. With 10-40 Claude agents this is steady process churn. C11-156 already async-acks some v1 status commands (`Sources/TerminalController.swift:2126-2144`) so the main-thread half is partly fixed. The process spawn is not. 14931 is the confirmed half. 14834 (the 2 s watchdog) is probable: the enqueue wall clock was not proven unbounded in c11. Port the spool idea. Do not cherry-pick the cmux wrapper. |
| Cmd+N workspace creation can use-after-free the previous workspace array | 2176, 2183 | workspace create | shared-confirmed | high | S | port | Upstream holds `tabs` in `withExtendedLifetime` for the whole create path (`gh pr diff 2183`, `Sources/TabManager.swift`). The local squash SHAs in `pr_sha.tsv` are empty trees. The GitHub diff is the source. c11 snapshots once (`Sources/TabManager.swift:1387-1389`) but never extends the array's lifetime, and inserts `snapshot.tabs` at `:1422-1428`. | Crash (`swift_retain`) while creating workspaces. Atin creates them constantly. The snapshot comment is only the Combine half of the upstream fix. |
| There is no app-wide memory-pressure response that discards hidden renderers or web views | 7496 | memory | shared-probable | high | L | reimplement | 7496 adds the pressure dispatcher (files under `Sources/App` plus `PaneMemoryGuardrail`). c11 has no equivalent type. Round 1 already confirmed the renderer half is missing. | Same bug family as round-1 PRs 5857, 7050, 10815. Do not port 7496 alone. A reclaim port has to include upstream ghostty `7b24d1c5d` or it reintroduces a teardown deadlock (round-1 note). Ties to days-long 40-surface sessions. |
| Shell prompt pays a process-tree `ps` and a fork/exec for every socket send | 2109 | shell integration | shared-confirmed | med | S | port | c11 zsh send still forks `ncat`/`socat`/`nc` at `Resources/shell-integration/cmux-zsh-integration.zsh:4-25`. PR-poll stop still calls `_cmux_kill_process_tree` at `:442` (definition `:392`). Bash matches (`cmux-bash-integration.bash:273`, `:323`). No `zsocket`. | Upstream: tree-kill is 5-13 ms of `/bin/ps -ax` per command, and each telemetry send is another fork (about 3 ms, several per prompt). Forty agent shells make this constant. |
| Listening-port scans still spawn `lsof`, which walks every fd slot up to `kern.maxfilesperproc` | 10277 | ports | shared-confirmed | med | S | reimplement | Upstream `ListeningPortLookup` uses `PROC_PIDLISTFDS` + `PROC_PIDFDSOCKETINFO` (about 200 ms to under 7 ms for 483 PIDs) and stops scans when the ports detail is hidden. c11 `Sources/PortScanner.swift:3-7` and `:151-153` still run `ps` + `lsof` for every registered TTY, on a 6-scan burst after each kick (`:40`, `:124-153`). | Off the main thread, so it pegs a core rather than beachballing by itself. Kicks come from every shell `ports_kick`. Also publish empty ports when the detail is hidden, or the CLI keeps a stale list (upstream's second commit). |
| Sidebar PR status runs `gh pr view` and `gh pr checks` per workspace, and git probes rerun without a cheap unchanged skip | 2662, 6260 | sidebar git/PR | shared-confirmed | med | M | reimplement | c11 `Sources/TabManager.swift:1850-1867` (`gh pr view`) and `:1965-1978` (`gh pr checks`). Branch publish is already equality-guarded at `Sources/Workspace.swift:7402-7407`. Focused `gitBranch` is still assigned at `:7415-7417`. | 2662 drops the checks fetch and coalesces per repo. 6260 also skips duplicate PR refreshes and unchanged git probe reruns. Checks fetch is the confirmed half. Unchanged probe skip is probable (inferred from no fingerprint short-circuit at the schedule site). Scales with workspace count. Feeds known problem 2 when results republish into the sidebar. |
| Background workspace prime starts a Ghostty surface for every terminal pane, including idle ones with nothing to run | 4184 | surface lifecycle | shared-confirmed | med | S | port | Upstream starts a surface only when the pane has a command, input, or queued socket bytes. c11 `Workspace.requestBackgroundTerminalSurfaceStartIfNeeded` loops every terminal panel at `Sources/Workspace.swift:7046-7049`. Prime is requested for eager unselected creates at `Sources/TabManager.swift:1419-1420` and run from `Sources/ContentView.swift:3092-3135`. | Each idle background pane gets a Ghostty IO thread and, later, an IOSurface (round-1 memory bug). Restored agent panes that have a command should still start. |
| Sidebar resize tracking runs on every mouse-move, including when the window is occluded, and arms a 16 ms main-queue timer | 7765 | sidebar hover | shared-confirmed | med | S | port | Upstream `SidebarResizerOcclusionResolver.bandMayActivate` refuses occluded windows. c11 local monitor includes `.mouseMoved` at `Sources/ContentView.swift:1956-1972` and calls `updateSidebarResizerBandState` (`:1903-1928`), which starts a 16 ms timer at `:1935-1948`. No occlusion check. | Narrower than the known 2-minute `mouseMoved → HoverEventDispatcher → containsGlobalPoints` stall, but it is the same hover class and it holds main while the pointer moves over a covered window. |
| An accepted socket client that stops reading blocks `write()` on that connection thread forever | 3355 | socket | shared-confirmed | med | S | port | Upstream sets `SO_SNDTIMEO` (5 s) and `SO_NOSIGPIPE` on the accepted fd. c11 sets those only on the outbound probe (`Sources/TerminalController.swift:1070-1088`, call at `:1419`). `accept` at `:1758` does not. `writeSocketResponse` is a bare `write` at `:1563-1567`. | One thread per connection (C11-211). A stuck client pins that thread, not the accept loop. Long-lived `read-screen` clients are normal here. |
| Session autosave writes window geometry to UserDefaults even when the bytes did not change, so every save posts `didChangeNotification` | 14822 | session / UserDefaults | shared-confirmed | med | S | port | Upstream skips no-op `set`/`remove`. c11 `persistWindowGeometry` always `defaults.set` at `Sources/AppDelegate.swift:3492-3500`. Autosave persist does the same at `:4629-4633`. Key is still `cmux.session.lastWindowGeometry.v1` (`:2155`). | `@AppStorage` in `VerticalTabsSidebar.body` (`Sources/ContentView.swift:8477-8493`) wakes on those notifications. Contributor to known problem 2, not a separate deadlock. Autosave is periodic for days-long sessions. |
| Hidden browser panes keep their WKWebViews for the life of the workspace | 4244, 6585, 15154 | browser memory | shared-confirmed (absent feature) | med | M | watch | Upstream discards hidden web views under memory pressure and, in 15154, restores WebKit `interactionState`, scroll, and form values. c11 has no discard manager. `BrowserPanel` keeps a shared `WKProcessPool` at `Sources/Panels/BrowserPanel.swift:1968-1969`. | Real RSS growth if many browser panes stay mounted. Atin's main load is terminals, so this is behind the IOSurface work. 15154 only matters after discard exists. |
| Key events still hit-test the browser portal | 4863 | browser input | shared-probable | med | S | port | Upstream skips web view hit testing during key dispatch. c11 gates divider work to pointer events but the non-pointer branch still calls `super.hitTest` at `Sources/BrowserWindowPortal.swift:493-512`. | Matters when a browser pane is focused. Terminal typing uses `WindowTerminalHostView`, which already has the pointer guard. Inferred: the remaining `super.hitTest` still walks WKWebView on keys. |
| Ghostty creates and destroys an `os_log` object on every log line | 9368 | ghostty / CPU | shared-confirmed | med | M | port | The cmux PR only bumps GhosttyKit checksums. The bug is in c11's submodule: `ghostty/src/main_ghostty.zig:143-146` calls `Log.create` per `logFn`, and `ghostty/src/global.zig:46-48` enables macOS unified logging by default. | Upstream called this idle CPU burn. Cost scales with how chatty each surface is. Port needs a ghostty submodule commit and a GhosttyKit rebuild, not a Swift edit. |
| Sparkle is 2.8.1, older than the 2.9.5 bump that mitigates updater-agent timeouts under endpoint security | 9763 | updater | shared-probable | low | S | watch | Upstream `Package.resolved` moves Sparkle 2.9.3 to 2.9.5 and adds a retry message. c11 resolves Sparkle 2.8.1 at `GhosttyTabs.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved:32-38`. | The code change is a version bump plus copy. Inferred it matters only on machines whose endpoint security delays `Autoupdate`. Not Atin's normal hang. |
| Opt-in background log does synchronous open/seek/write/close under a lock | 6823 | diagnostics | shared-confirmed | low | S | watch | c11 `GhosttyApp.logBackground` at `Sources/GhosttyTerminalView.swift:2506-2527`. Enabled only for `C11_DEBUG_BG`, `C11_DEBUG_LOG`, or the old defaults (`:898-912`). | Off unless someone is tracing. Do not port for production. |
| Socket timeout `timeval` microseconds are not clamped, so some fractional timeouts are rejected by `setsockopt` | 5416 | socket | shared-probable | low | S | watch | Upstream clamps `tv_usec` to 999999. c11 `makeSocketTimeout` rounds and stores at `Sources/TerminalController.swift:1063-1068` with no clamp. | Hits values like 0.9999996 s. Ordinary 0.25 s probe timeouts are fine. |
| Decomposed Hangul filenames shape with the wrong font | 12826 | ghostty text | shared-probable | low | M | watch | Upstream ghostty `3869e81a0` keeps the composed syllable with the font it resolved. c11 `ghostty/src/font/shaper/coretext.zig` has no NFD/Hangul compose path (searched). | Korean filenames only. GhosttyKit bump. |
| Blocking v2 socket methods were moved off the main actor | 3340 | socket | already-fixed |  |  | skip | c11 `socketWorkerV2Methods` and the C11-26 comment at `Sources/TerminalController.swift:2025-2095`. Later tickets (C11-156, C11-165, C11-180, C11-217) widened the off-main set past upstream's auth/feed/vm list. | `surface.read_text` is in the worker set, but round 1 already found the format step still hops to main (5243, 7357). Not re-litigated here. |
| PostHog flush on activate can stall quit if it runs on main | 6417 | analytics | already-fixed |  |  | skip | The upstream PR is a regression test. The behavior is already in c11: `trackActive` flushes on `com.stage11.c11.posthog.analytics` at `Sources/PostHogAnalytics.swift:52-61`. | `flush()` itself is synchronous on that queue (`:77-82`). Callers that are not main are fine. |
| Bundled CLI crashed at launch because it linked Sentry-Dynamic | 3565 | CLI launch | already-fixed |  |  | skip | c11 links the static `Sentry` product, not `Sentry-Dynamic` (`GhosttyTabs.xcodeproj/project.pbxproj:191`, `:308`). | The v0.64.1 dyld abort does not apply. |
| `surface.resume.set` ran `NSAlert.runModal()` inside a main-actor socket job and wedged every main hop | 13397 | socket | already-fixed |  |  | skip | c11 has no `surface.resume.set`. Agent-path `runModal` is the C11-204 fix. `v2MainSyncWithDeadline` exists at `Sources/TerminalController.swift:2429`. | Remaining `runModal` sites are file panels and operator alerts (`Sources/ContentView.swift:13741`, `Sources/AppDelegate.swift:6005`). Those match the allowed menu/button case. |
| Settings `AsyncStream` observers leaked a NotificationCenter task per subscriber | 5403 | settings | n/a-diverged |  |  | skip | Upstream bug is `NotificationCenter.notifications(named:)` inside `UserDefaultsSettingsStore.values`. c11 has no that store. | Sidebar `@AppStorage` churn is a different path (see 14822). |
| Agent port scans kept running while the app was inactive | 6583 | ports | n/a-diverged |  |  | skip | Upstream pauses `trackedAgentWorkspaces` on resign-active. c11 `PortScanner` is kick-driven only (`Sources/PortScanner.swift:65-76`). No agent scan timer. | The `lsof` cost that remains is 10277. |
| Sidebar observation publisher rebuilt every workspace snapshot on each agent title | 6807, 8247 | sidebar | n/a-diverged |  |  | skip | Upstream throttles `sidebarObservationPublisher` / `CoalesceLatestPublisher`. c11 has neither. Rows are built in `VerticalTabsSidebar.body` (`Sources/ContentView.swift:8574-8635`). | The symptom matches known problem 2. This PR's mechanism does not. 7863 tried a broader typing-latency pass and 8138 reverted it the next day. Do not port 7863. |
| Sidebar LazyVStack livelock from a custom layout measuring every row | 6870, 7221 | sidebar | n/a-diverged |  |  | skip | Upstream's `SidebarRowsFillLayout` / per-row `GeometryReader` → `@State` height loop. 6870 is the CI guard. c11 has no that layout. `LazyVStack` is at `Sources/ContentView.swift:8599`. Pulse `GeometryReader`s (`:12283`, `:12345`) have fixed frames and do not write row height. | Known problem 2 is AttributeGraph cost in `body`, not this livelock. |
| Sidebar scroll mask remeasured geometry every pass | 7527 | sidebar | n/a-diverged |  |  | skip | Upstream replaces `safeAreaInset` plus a fade mask with `onGeometryChange` that writes only on height change. c11 has no `workspaceScrollContentMinHeight` / `onGeometryChange`. | Different sidebar scroll structure. |
| Long-uptime sidebar observers accumulated terminated `AsyncStream` continuations | 7954 | sidebar | n/a-diverged |  |  | skip | Upstream models `WorkspaceSidebarAgentRuntimeObservationModel` and `WorkspaceSidebarProcessTitleObservationModel` are absent in c11. | Days-long sessions do not hit this leak. |
| Durable event-log writes were not coalesced | 13010 | events | n/a-diverged |  |  | skip | c11 `EventLog.append` is async on a utility queue, keeps one `FileHandle`, and does not fsync per line (`Sources/Events/EventLog.swift:72-89`, `:139-165`). | One `write` per event remains. That is not the upstream fsync storm. |
| Popover dismiss wrote its binding during SwiftUI `updateNSView` | 13442 | sidebar popover | n/a-diverged |  |  | skip | Upstream `dismiss()` reset `isPresented` on the already-false branch. c11 `dismiss` only closes the popover (`Sources/ContentView.swift:10923-10994`). `popoverDidClose` writes only if `isPresented` is still true (`:10996-11000`). | No "modifying state during view update" on workspace switch from this path. |
| Predicted-echo engine drew into an already-open alternate screen | 14686 | input | n/a-diverged |  |  | skip | c11 has no predicted-echo types (searched `PredictedEcho`, `consumePrintable`). | Feature c11 never took. |
| Claude wrapper re-validated hook settings through Node and re-read MDM on every launch | 14872 | claude wrapper | n/a-diverged |  |  | skip | c11 `Resources/bin/claude` has no Node validation and no `inject-settings` (searched). | The spawn cost is 14931, not this validation. |
| A late tool result or reminder flips a finished agent back to busy | 15173, 16257 | agent status | n/a-diverged |  |  | skip | Upstream turn reducer. c11 status is metadata and the skill (`set-status` / `set-metadata`), not that reducer. | Inferred. Fleet "stuck working" would be a c11 metadata bug, not this PR. |
| A process exiting mid-census marked every Claude session unrestorable | 15467 | session restore | n/a-diverged |  |  | skip | Upstream drops ESRCH from a full-process census instead of failing the census. c11 resume is the session snapshot plus the `claude` wrapper, not that census. | `TerminalPIDResolver` is a different scan. |
| Versioned geometry plus a deferred `displayIfNeeded` stopped a re-entrant layout crash | 2308 | window geometry | n/a-diverged |  |  | skip | The mapped squash diff is test waiters only. c11 `displayIfNeeded` is the debug-stress helper at `Sources/AppDelegate.swift:8599-8609`, not a SwiftUI geometry callback. Geometry key is still v1 (`:2155`). | The product fix described in the PR body is not in this commit. Inferred it landed in another upstream commit c11 did not need. |

## Top findings

Bulk terminal output from many agents floods the main queue. Ghostty's wakeup callback schedules a separate `DispatchQueue.main.async { tick() }` every time (`Sources/GhosttyTerminalView.swift:1069-1072`), and each scrollbar action updates the scroll view and posts a notification immediately (`:2161-2168`). Upstream PR 2116 collapses both to one pending main-queue block. They measured `seq 1 10000` going from slower than standalone Ghostty to faster. This is a concrete source of known problem 2: the main queue goes minutes deep and `runloop-idle` heartbeats land late. Inferred, it also starves the main-thread drain of ghostty's 64-slot mailbox, which is the wait in the 2026-08-25 `Surface.deinit` deadlock. The patch is local to `GhosttyTerminalView.swift`.

Every Claude Code tool call starts the c11 CLI. The wrapper writes hooks as `c11 claude-hook …` (`Resources/bin/claude:205`). Upstream measured about 61 ms of CPU and 104 ms of wall per event, then replaced that with one forwarder process and shell-builtin publishes (14931). 14834 is the companion: the enqueue command must answer inside Claude's hook timeout. C11-156 already stops some of those commands from blocking main, which is why a fleet does not immediately deadlock. The processes are still spawned. At 10-40 Claude agents this is the largest steady CPU cost in this batch. Reimplement the spool in c11's wrapper. Do not drop in the cmux script.

Creating a workspace can crash. Upstream 2183 (and 2176, same bug) keeps the existing workspace array alive for the whole Cmd+N path, because ARC was dropping it and `swift_retain` faulted mid-create. c11 snapshots the array once (`Sources/TabManager.swift:1387-1389`) but does not extend its lifetime, and it inserts that snapshot rather than the live array (`:1422`). The local `pr_sha.tsv` commits for both PRs have empty trees. The GitHub diff is the one that shows the fix. This is a small port and it hits the operator who opens workspaces all day.

Two background pollers tax a machine full of agents even when nobody is typing. Port scans still shell out to `lsof` (`Sources/PortScanner.swift:151-153`). Upstream 10277 replaced that with libproc and stopped scanning when the ports row is hidden. `lsof` closes every descriptor up to the process fd limit before it answers. Separately, each GitHub workspace runs `gh pr view` and `gh pr checks` (`Sources/TabManager.swift:1850-1867`, `:1965-1978`). Upstream 2662 drops the checks fetch and coalesces by repo. 6260 skips unchanged git probes. The branch dictionary write is already guarded (`Sources/Workspace.swift:7406`). The process spawns are not. Both sit off main, so they show up as CPU and fan noise, then as sidebar republishes (known problem 2) when a result changes.

Prompt latency and idle Ghostty logging are the other per-agent taxes. The zsh and bash integrations still fork `nc` for every telemetry send and still walk the process table to kill the PR poller (`Resources/shell-integration/cmux-zsh-integration.zsh:4-25`, `:442`). Upstream 2109 switches zsh to `zsocket` and uses a process-group kill. Ghostty's macOS logger allocates an `os_log` object on every line (`ghostty/src/main_ghostty.zig:143-146`) with unified logging on by default (`ghostty/src/global.zig:48`). Upstream 9368 caches that. The code change is small. Shipping it means a GhosttyKit rebuild. Also worth a small port, not in this paragraph's mechanism: autosave writes the same window geometry into UserDefaults on every tick (`Sources/AppDelegate.swift:3492-3500`), which wakes the sidebar's `@AppStorage` keys.

## Triage ledger

pr | disposition | one-line reason
--- | --- | ---
1741 | na-feature | Web SEO canonicals and sitemap only.
1743 | noise | Test-target wiring and a test timeout.
2109 | verify | Shell prompt still forks nc and ps on every command.
2116 | verify | Ghostty wakeup and scrollbar still enqueue unbounded main-queue work.
2655 | noise | Settings-row review guardrail, not a runtime fix.
2662 | verify | Sidebar still runs gh pr view and gh pr checks per workspace.
3078 | noise | Idle overlay log change, reverted by 3086, net zero.
3086 | noise | Revert of 3078.
3207 | noise | Activation benchmark and tests.
3340 | verify | Blocking v2 dispatch. c11 already routes a wider set off main.
3355 | verify | Accepted socket writes have no send timeout.
3429 | verify | Live-surface route recovery. Skipped: low confidence, c11 already has locateSurface fallbacks. Guess already covered.
4184 | verify | Background prime starts every terminal surface, idle or not.
4244 | verify | No hidden-WKWebView discard.
4323 | na-feature | Remote websocket PTY daemon.
4437 | noise | Task Manager memory-attribution diagnostics, not a runtime fix.
4491 | noise | Update-progress timeouts, reverted by 4655.
4655 | noise | Revert of 4491.
4706 | noise | GhosttyKit Zig version guard in setup scripts.
4732 | na-feature | Eternal Terminal option parsing.
4837 | noise | DerivedData cleanup script.
4863 | verify | Browser portal still hit-tests on non-pointer events.
4944 | noise | E2E runner identity guard.
5218 | na-feature | Shared transcript-tail cache for upstream agent hooks c11 does not run.
5243 | done-round1 | read-text off main, verdicts-lead.md.
5334 | na-feature | Web security headers.
5365 | noise | Extract socket transport into a package, no behavior fix by itself.
5403 | verify | Settings AsyncStream observer leak. c11 does not have that store.
5416 | verify | timeval usec clamp on socket timeouts.
5857 | done-round1 | IOSurface reclaim, verdicts-lead.md.
5870 | na-feature | Browser-action beforeinput and focus-mode side effects.
5969 | noise | CI notarize timeout.
6260 | verify | Git and PR probe churn bundled with settings and browser notification skips.
6529 | noise | Hot-path latency probe and XCUITest baseline.
6583 | verify | Pause agent port scans when inactive. c11 has no such scanner.
6585 | verify | Evict hidden web views under memory pressure. Same gap as 4244.
6619 | na-feature | Removes upstream's high-memory pane warning UI.
6765 | na-feature | Web waitlist email timeouts.
6807 | verify | Sidebar observation throttle. c11 has no that publisher.
6823 | verify | Opt-in background log still does sync file I/O.
6870 | verify | CI guard for a LazyVStack livelock c11's sidebar does not implement.
7050 | done-round1 | Hidden renderer reclaim, verdicts-lead.md.
7221 | verify | Row-view half of the LazyVStack livelock guard.
7357 | done-round1 | Socket command tranches off main, verdicts-lead.md.
7496 | verify | Memory-pressure dispatcher. Same family as the round-1 renderer reclaim.
7527 | verify | Sidebar scroll geometry churn in a layout c11 does not have.
7757 | na-feature | Web oRPC and OpenAPI client.
7765 | verify | Sidebar resize hover ignores window occlusion.
7794 | na-feature | Blank icon renders in upstream's icon pipeline.
7863 | noise | Typing-latency pass, reverted the next day by 8138.
7954 | verify | Terminated sidebar AsyncStream leak. Those models are absent.
7972 | noise | App Store Connect request timeout in CI.
8138 | noise | Revert of 7863.
8246 | noise | Nightly CI false-green guard.
8247 | verify | Coalescer drain bug in the publisher 6807 added. c11 has neither.
8347 | noise | Docs deployment auth and CI.
8390 | na-feature | AppKit sidebar round 2. c11's sidebar is still SwiftUI VerticalTabsSidebar.
8576 | na-feature | Remote reconnect, iroh cooldowns, device rate limits.
8778 | na-feature | iOS deleted-Mac recovery.
9026 | done-round1 | Reentrant focus storms, verdicts-lead.md.
9366 | na-feature | cmux-tui resource SDK lifecycle.
9402 | na-feature | Route-content equivalence for upstream routing.
9575 | na-feature | Remote tmux pane seed retention.
9763 | verify | Sparkle 2.8.1 vs upstream 2.9.5 updater-agent timeout mitigation.
9791 | na-feature | Web install analytics privacy.
9993 | noise | cmux-tui route timeout tests.
10059 | noise | Stale dev-socket fallback for the ambient CLI. Not the fleet runtime path.
10277 | verify | Port scans still spawn lsof.
10490 | na-feature | New journal-backed sidebar lifecycle. c11 did not take that architecture.
10815 | done-round1 | Occluded-window renderer reclaim, verdicts-lead.md.
11162 | na-feature | cmux-tui ThreadOutput backlog.
11313 | na-feature | Web billing recovery.
11425 | na-feature | cmux-tui PTY child guard.
11432 | na-feature | cmux-tui pairing channel bound.
11435 | na-feature | cmux-tui workspace HTTP token reads.
11588 | na-feature | Managed enrollment file reads.
11662 | na-feature | Web admin roster.
11746 | na-feature | cmux-tui occluder cloning.
11837 | na-feature | Extension sidebar snapshot index. c11 has no extension sidebar snapshot.
11857 | na-feature | cmux-remote invitation state.
11933 | na-feature | Web dashboard Stack user reads.
11943 | na-feature | Provider and local security boundaries c11 does not ship.
12241 | na-feature | Web health-probe statement timeout.
12352 | noise | setup.sh Metal preflight.
12699 | na-feature | Production deploy rollback guards.
13010 | verify | Event-log batching. c11's writer is already async and un-fsynced.
13014 | na-feature | Coalesce of upstream diagnostics and restore process snapshots.
13130 | noise | BrowserPanelView type-check split. Compile time only.
13134 | noise | reload.sh skip unchanged post-build work.
13209 | noise | Skip unchanged bundled resource builds.
13241 | noise | APFS clone in reload.sh.
13273 | noise | CI artifact upload skip.
13285 | na-feature | Web provider error classifier.
13397 | verify | Socket runModal wedge and bounded main hops. C11-204 plus v2MainSyncWithDeadline.
13442 | verify | Popover binding write during SwiftUI update. c11 dismiss does not write.
13466 | noise | CI history guard.
13496 | noise | Parallel CI guard contracts.
13497 | noise | Parallel source-lint guards.
13500 | noise | Split quality-guard CI path.
13501 | noise | Split app-host guard CI path.
13502 | noise | Split release guard CI path.
13530 | na-feature | Dev-fleet warm-slot disk scans.
13580 | na-feature | Dev-fleet warm-slot telemetry.
13585 | noise | Linux guard routing in CI.
13589 | na-feature | Dev-fleet cold-task cleanup.
13862 | na-feature | Settings as a workspace pane plus a SettingsRuntime reference.
13910 | na-feature | Web dev-app diagnostics collector.
14210 | noise | Shortens app-host unit test timeouts.
14686 | verify | Predicted echo. Feature c11 does not have.
14764 | noise | merge-main.sh CI helper.
14813 | noise | Info.plist duplicate-key guard.
14822 | verify | Autosave writes unchanged window geometry to UserDefaults.
14834 | verify | Hook enqueue must answer inside Claude's timeout. Same cost center as 14931.
14870 | na-feature | Journal replay of agent sessions after unclean exit. Depends on 10490.
14872 | verify | Wrapper Node settings validation. c11's wrapper does not do that.
14931 | verify | One c11 CLI process per Claude hook event.
14951 | na-feature | New confirm-unsafe-paste setting.
14953 | na-feature | Paste-failure notice.
14991 | na-feature | Differentiate Without Color, contrast, and transparency. New accessibility behavior.
15016 | noise | merge-main local-guard flag.
15057 | noise | pbxproj source-wiring tool.
15083 | na-feature | Mac pairing team-scope recovery.
15125 | na-feature | Pane focus memory and New Pane auto layout.
15154 | verify | Keep page state across memory-saver discard. Depends on 4244.
15173 | verify | Late tool result marks a finished turn busy. c11 status model differs.
15298 | na-feature | Task Manager agent rows.
15324 | na-feature | Journaled Claude restore. Depends on 10490.
15467 | verify | Process-census ESRCH fails session restore. c11 does not use that census.
15613 | na-feature | Guarded Close Tab UX.
15697 | na-feature | Agent recovery workspaces.
15802 | na-feature | cmux-next terminal attach machine.
15993 | noise | CLI verb contract docs and a guard.
16045 | na-feature | agent-chat transcript file replacement.
16257 | verify | Delayed reminders flip finished Claude sessions busy. Same reducer as 15173.
2176 | verify | Cmd+N snapshot lifetime crash. Same fix as 2183.
2183 | verify | withExtendedLifetime around workspace creation. c11 does not have it.
2308 | verify | Re-entrant layout crash. Mapped diff is tests. c11 displayIfNeeded is debug-only.
3469 | noise | CircleCI Bun prefix.
3565 | verify | Sentry-Dynamic CLI launch crash. c11 links static Sentry.
5551 | na-feature | Web changelog PNG height.
6412 | noise | CI test teardown crash guard.
6417 | verify | PostHog flush off main. c11 already flushes on a utility queue.
6425 | na-feature | Web changelog title clipping.
6624 | noise | CI xcode-select alignment.
8851 | done-round1 | Test-host crash. The idle-CPU bug it was mis-cited for is n/a-diverged in verdicts-lead.md.
9368 | verify | Ghostty os_log create on every log line.
9436 | verify | Ghostty native Sentry init crash on Intel. Skipped detail: sentry.zig still calls sentry_init. Atin is Apple Silicon. Guess low, watch.
9799 | na-feature | Web install-analytics test.
10741 | noise | Un-deadlock a Swift package test.
10972 | na-feature | Web serverless Sentry flush.
12425 | noise | CI Metal toolchain install.
12800 | noise | Post-update hang investigation notes, no product fix.
12826 | verify | NFD Hangul filename shaping.
13180 | noise | CI RemoteTmux crash diagnostics.
13250 | na-feature | cmux-settings skill paths. c11's skill is a different contract.
14055 | noise | CI hung-test watchdog.
14296 | na-feature | Web APNs sandbox flag.
14307 | noise | CI changed-suite accounting.
14424 | noise | Homebrew depends_on macos deprecation.
14768 | noise | CI guard attribution.
14886 | noise | Test-host terminal leak cleanup.
15811 | noise | Cross-surface input test hang.

## Counts

rows 162, na-feature 57, noise 53, verify 45, done-round1 7. verify: confirmed 16, probable 7, already-fixed 4, n/a-diverged 16, skipped 2.

Skipped: 3429 (guess c11 locateSurface already covers live-surface routing), 9436 (Ghostty Sentry init, Intel-only, Atin is Apple Silicon, watch).
