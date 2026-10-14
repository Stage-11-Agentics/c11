# socket-layout-perf verdicts

Read-only check of upstream cmux bug fixes against c11 main (2026-10-01). Batch file `batches/socket-layout-perf.tsv` (131 PRs) plus `cl_nopr.txt` (40 changelog rows). Round-1 overlaps are ledgered `done-round1` and not re-verified: 12503, 13292, 14673, 14704 (all in `verdicts-lead.md`).

Severity is for one operator, 10 to 40 agents, days-long sessions, heavy `send` / `read-screen` / `set-metadata` / `tree`, and frequent surface create/close. Inferences are marked.

## Verified

| bug (plain English) | PRs | subsystem | c11 status | severity | port | rec | evidence | notes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Large `surface.send` payloads silently drop about 1.6 to 1.8 KB on the first burst per terminal. Ghostty's write-request pool only accepts buffers back in order, so an out-of-order return stalls the ring and later bytes never reach the PTY. | 12842 | ghostty termio | shared-confirmed | high | M | port | upstream ghostty `e0ef934f7` (not an ancestor of c11 ghostty `26c3e499e`); c11 `ghostty/src/termio/Exec.zig:419` still `getGrow`s `write_req_pool`, and `ghostty/src/datastruct/segmented_pool.zig:55-60` `put()` only bumps `available` and requires in-order return | Pool half only. The `GHOSTTY_BIN_DIR` use-after-free half does not match c11: `Exec.zig` copies `exe_dir` off the stack before the frame dies. Does not explain the 2026-08-25 mailbox deadlock (`App.zig:571`, `mailbox.zig:92`). Port is a ghostty cherry-pick of `MemoryPool`, not a Swift edit. |
| Creating many unfocused agent workspaces mounts every one of them. Pending background-load ids raise the mount cap with no constant ceiling, so SwiftUI keeps a live tree per agent workspace. | 7182 | layout | shared-confirmed | high | S | port | upstream `802351c879` (issue 7136); c11 `Sources/ContentView.swift:3030-3052` sets `maxMounted = max(baseMaxMounted, selectedCount + pinnedIds.count)` and `pinnedIds` includes every `pendingBackgroundWorkspaceLoadIds`. `Sources/TabManager.swift:1419-1420` requests that load when `eagerLoadTerminal && !select`. `requestBackgroundWorkspaceLoad` at `TabManager.swift:2216` has no cap. Callers pass `eagerLoadTerminal: !focus` | Known problem 2 (AttributeGraph storms, late `runloop-idle` heartbeats). Base cap is 1 (`ContentView.swift:1331-1335`) but the pending set defeats it. Stop letting pending ids raise `maxMounted` without a small constant. |
| Sidebar layout can recurse. `LazyVStack` plus drag invalidation re-enters layout, and the sidebar body is already on the main-thread hot path. | 2601 | layout | shared-confirmed | high | S | port | upstream `2bf43677` replaced `LazyVStack` in `VerticalTabsSidebar` with `VStack` and made the drop indicator equatable; c11 still uses `LazyVStack` at `Sources/ContentView.swift:8599` | Layout half only. The same PR's socket-deadlock hunks were not line-matched. c11's accept loop is already off main (`TerminalController.swift:1898`, `1941`, `1995`, C11-211). Known problem 2. |
| During `ghostty_app_new`, an action callback can call `GhosttyApp.shared` while that singleton is still initializing, and re-enter it. | 4318, changelog `76ba2bfd` | ghostty startup | shared-confirmed | high | S | port | upstream added an app registry and `initializingRuntimeApp` and stopped calling `.shared` from the callbacks; c11 installs `action_cb` before `ghostty_app_new` and the callback synchronously calls `GhosttyApp.shared.handleAction` at `Sources/GhosttyTerminalView.swift:1074-1075`. `wakeup_cb` is `main.async` (`:1069-1072`) | No `initializingRuntimeApp` in c11. Crash is inferred from the same re-entry, not reproduced here. Nucleo FFI, signing, and smoke-launch hunks in the same commits are upstream-only (those symbols are absent from `Sources`). Not the 2026-07-28 deadlock. |
| A new workspace copies a C `ghostty_surface_config_s` by value. That struct holds pointers (cwd, command, env). The copy can dangle and crash Cmd+N / new workspace. | 2283 | layout | shared-confirmed | high | S | reimplement | upstream replaced the C struct with an owned Swift template after a Nightly Cmd+N crash; c11 `cmuxInheritedSurfaceConfig` returns `ghostty_surface_config_s` at `Sources/Workspace.swift:35-59`. `TabManager.inheritedTerminalConfigForNewWorkspace` returns that struct (`TabManager.swift:2291-2309`). `GhosttyTerminalView` stores `configTemplate: ghostty_surface_config_s?` (`GhosttyTerminalView.swift:2730`) | No `CmuxSurfaceConfigTemplate` in c11. Crash inferred from the struct-copy pattern, not reproduced. Own the strings in Swift. The Zig helper-build half of 2283 is unrelated. |
| A stale or unresolvable `surface_id` on close, clear, read, and split falls through to the focused pane. An agent that closes a dead handle can kill the operator's focused agent. A parsed-but-dead UUID is safe (panel lookup returns not_found). A handle that fails `v2UUID` is not. | 2150, 9422, 6605 | socket | shared-confirmed | high | S | port | upstream `71f0e695` and `42d4f041` fail closed; c11 `v2UUID` returns nil for an unresolvable handle (`TerminalController.swift:2695-2700`) and these call sites use `v2UUID(...) ?? ws.focusedPanelId` without `v2RejectUnresolvedPin`: `SurfaceHandlers.swift:304` (split), `:473` (close), `:1062` (clear), `:1120` (read). The reject helper exists at `TerminalController.swift:2759-2794` and is used for metadata writes only | Send is already fixed (C11-173, `resolveSurfaceSendTargets` at `TerminalController.swift:3153-3187`): an explicit surface that fails is `not_found`, never the focused pane. 14673 (never-shown read) and 14704 (`closePanel` unmapped fallback at `Workspace.swift:9272-9314`) are done-round1. Do not port a second time. |
| Disowned shell watchers survive the shell. They only test `kill -0` on the parent pid, so a reused pid keeps them alive. The zsh git HEAD watch has no parent check at all and loops `sleep 1` forever. Upstream recorded hundreds of orphans and a multi-GB resident set after many days. | 11035 | shell | shared-confirmed | high | S | port | upstream `22eec580` records pid plus `ps -o lstart=`; c11 zsh PR poll `Resources/shell-integration/cmux-zsh-integration.zsh:447-472` loops on `kill -0` only and is started disowned from precmd `:690`. zsh HEAD watch `:482-513` is `while true; sleep 1` with no parent check, `&!` at `:512`, started `:540`. bash PR poll `cmux-bash-integration.bash:328-355` is the same `kill -0` plus `disown` | Days-long, 10 to 40 shells. Record start time, or stop the HEAD watch when the shell dies. Does not by itself explain the 2026-08-25 freeze. |
| A socket command that waits for a callback from the main thread pumps the main run loop until the timeout. While that pump runs, the UI and every other main-actor command are frozen. | 6860 | socket | shared-confirmed | high | M | watch | upstream `fc2c69f2df11` fast-fails when already on main (returns nil, does not start the work); c11 `v2AwaitCallback` at `Sources/SocketHandlers/BrowserHandlers.swift:580-586` calls `v2AwaitCallbackPumpingMainRunLoop` (`CFRunLoopRunInMode`, 50 ms slices) whenever the caller is on main | C11-165 replaced one nested `CFRunLoopRun`+`Stop`. C11-209: the pump still freezes main. Production incident 2026-08-12 lasted 25+ minutes (`docs/c11-browser-await-main-wedge.md`). Do not port the fast-fail as written. It would drop WebKit commands that must finish on main. Known problem 2's main-thread congestion, not the mailbox deadlock. |
| Port scan can deadlock the scanner thread. `readDataToEndOfFile` never sees EOF because the parent keeps the pipe's write end open, and `waitUntilExit` sits after that read. | 2893 | perf | shared-confirmed | med | S | port | upstream `caf193596` closes the parent's write end before reading; c11 `Sources/PortScanner.swift:183-228` (`runPS` and `runLsof`) uses a local `Pipe()`, `readDataToEndOfFile()`, then `waitUntilExit()`, and never closes `fileHandleForWriting` | Off main (`deliverResults` is `main.async`). Ports sidebar stops updating. Not a whole-app hang. Close the write end before the read. |
| Shell integration runs `git branch` and `git status` with no `git rev-parse --git-dir` guard, so non-repo directories (and TCC-protected trees) prompt or fail on every prompt. | 1677 | shell | shared-confirmed | med | S | port | upstream `af45c421` added `git rev-parse --git-dir` before branch queries; c11 bash still runs `git branch --show-current` at `cmux-bash-integration.bash:467`. Neither bash nor zsh script matches `rev-parse --git-dir` | App-side `GitContextResolver` already uses `rev-parse` off main (`Sources/Metadata/GitContextResolver.swift:97`). This bug is the in-shell probe, once per terminal. |
| When zsh's job table is full, cmux's precmd/preexec hooks error on every prompt. | 4959 | shell | shared-confirmed | med | S | port | upstream `7264d29d` adds `_cmux_zsh_job_table_saturated` via `zmodload zsh/parameter` and `${#jobstates}`; c11's zsh integration has no `jobstates` guard | Many long-lived agent shells hit the job table. Return early from the hooks when it is full. |
| Bash's cmux prompt hook is prepended to `PROMPT_COMMAND` and returns 0 from its guards, and it never saves the incoming `$?`. Later hooks (Starship and others) see success. | 15255 | shell | shared-confirmed | med | S | port | upstream `4e0f7d2f`; c11 `_cmux_prompt_command` at `cmux-bash-integration.bash:384-387` returns 0, and the hook is prepended at `:527` | Save `$?` on entry and return it. |
| Ghostty's PWD action writes the directory through the key window's `TabManager`, so a background window's cwd lands on the wrong workspace. Restore then falls back toward `$HOME`. | 2147 | layout | shared-confirmed | med | S | port | upstream routed by `tabId`; c11 `GHOSTTY_ACTION_PWD` at `Sources/GhosttyTerminalView.swift:2236-2245` calls `AppDelegate.shared?.tabManager?.updateSurfaceDirectory`. The notification path just below uses `tabManagerFor(tabId:)` | Same key-window lookup at `GOTO_SPLIT` (`GhosttyTerminalView.swift:2118-2126`). Shell `report_pwd` is a separate, scoped path. Session-restore data loss when more than one window is open. |
| The GUI binary ignores CLI argv. If `c11` resolves to `Contents/MacOS/c11`, a subcommand is dropped and the process is later SIGTERMed (exit 143). | 4679 | socket | shared-confirmed | med | S | watch | upstream `b9f2298d` execs the bundled CLI from `cmuxApp.init` when argv looks like a subcommand; c11 `@main struct cmuxApp` (`Sources/c11App.swift:127`) has no such exec | Inside a c11 terminal this is mostly hidden: PATH is prepended with `Contents/Resources/bin` (`GhosttyTerminalView.swift:3584-3591`). It still bites any shell whose `c11` is the app executable. |
| Main-window frames are still owned by a c11 defaults blob. Upstream moved that job to AppKit frame autosave because the custom writer remapped frames across sleep/wake on multiple monitors. | 3882, 7308 | layout | shared-probable | med | M | reimplement | upstream `d6418685` enrolls main windows in `frameAutosaveName` and stops the competing writer; c11 still has `persistedWindowGeometryDefaultsKey = "cmux.session.lastWindowGeometry.v1"` at `Sources/AppDelegate.swift:2155`, read at `:3486` and written at `:3500` and `:4632`. No `frameAutosaveName` in `Sources`. New windows set a restored or default frame directly (`AppDelegate.swift:7156-7182`) and do not set `collectionBehavior` | Inferred the sleep/wake remap can still happen. 7308 (fit windows after display changes) was not hunk-matched. Do not claim a live repro. |
| Toggling minimal mode can re-enter layout until the main thread hangs. | 7076 | layout | shared-probable | med | M | watch | upstream `0f7e510e` is a large ContentView rewrite plus new presentation-mode files; c11 has `isMinimalMode` | Inferred. The diff was not applied line by line. Do not claim a live loop. |
| The pane tab bar can feedback-loop on layout at scale (bonsplit). | 7997 | layout | shared-probable | med | M | watch | upstream `fb552726` (issue 7975) hardens bonsplit tab geometry; c11 vendors bonsplit and the submodule was not diffed against that bump | Inferred. Distinct from known problem 2's `mouseMoved` hit-test recursion. |
| A new window opened while another window is fullscreen lands in the current Space. | 2345 | layout | shared-probable | med | S | watch | upstream `63dd7281`; c11's main window constructor (`AppDelegate.swift:7156-7182`) sets no `collectionBehavior`. The only `collectionBehavior` hits in `Sources` are a manifest viewer and a transient Ghostty bootstrap window | Inferred from the missing flag. Not line-compared to the upstream Space fix. |
| `equalize` sets every binary divider to 0.5, so an unbalanced tree (pane beside a pair) becomes 50/25/25. | 4381 | layout | shared-confirmed | low | S | watch | upstream `c8f09dec`; c11 `TabManager.equalizeSplits` at `Sources/TabManager.swift:4037` | Keyboard/layout. Agents rarely equalize. |
| `goto_split` previous/next only move left/right, so a vertical neighbor is skipped. | 2639, 9046 | layout | shared-confirmed | low | S | watch | upstream cycles with wrap; c11 `GhosttyTerminalView.focusDirection` at `:1921-1926` maps previous to `.left` and next to `.right`, comment says "reasonable default" | Keyboard. Agents use `surface.focus`. `ghostty/macos/.../Ghostty.App.swift` `gotoSplit` is the embedded Ghostty app, not c11's path. |
| `c11 send-key` keeps only the first key and silently drops the rest. | 15980 | socket | shared-confirmed | low | S | port | upstream `f627d1fb` rejects extras; c11 `CLI/c11.swift:2848` uses `keyArgs.first` and sends that one key. `send-key-panel` does the same near `:2890` | Dropped, not injected into the wrong surface. Reject or loop. |
| `simulate_shortcut` builds an `NSEvent` and can raise `NSException` from `interpretKeyEvents` on a plain character. | 8123 | socket | shared-confirmed | low | S | watch | upstream `d3dbd214` moved key simulation to `CGEvent`; c11 `TerminalController.swift:4546-4616` uses `NSEvent.keyEvent` at `:4576` | Test and debug path (`:4452`). Probe-redaction half is debug tooling. |
| `goto_split` can skip the adjacent column. | 12397 | layout | shared-probable | low | M | watch | upstream `bc174ed2` is a later bonsplit spatial fix on top of 2639/9046; c11's previous/next mapping is the confirmed bug above. The column-skip was not pinned in `vendor/bonsplit` | Inferred remainder. |
| OSC and DCS inside `c11 send` show up as literal text. Socket send goes through `ghostty_surface_text`, which wraps bracketed paste, so OSC 11 never reaches the parser. | 5509 | socket | shared-probable | low | M | watch | upstream `97cf213978` added a PTY parser so OSC/DCS affect terminal state; c11 `sendText` at `GhosttyTerminalView.swift:3938-3950` writes `ghostty_surface_text`. Comment at `:3956-3963` says embedded newlines do not execute | Agents rarely send OSC 11. 3886 added per-pane OSC 11 tint and 5106 reverted it. `osc11` is absent. Not this bug. |
| A broken process pipe can crash an `NSFileHandle` readability handler. | 4800 | socket | shared-probable | low | S | watch | upstream `59ecb48c`; c11 still uses `readabilityHandler` / `availableData` on the VS Code serve-web pipe (`AppDelegate.swift` around `1026-1038`). The remote SSH `runProcess` pipe is a different feature (4568, na-feature) | Not the agent socket loop. |
| Markdown links in a markdown surface do not open. The view renders SwiftUI `Markdown` with text selection and no `OpenURLAction`. | 3558 | layout | shared-probable | low | S | port | upstream `b26f624b` added an explicit `OpenURLAction`; c11 `Sources/Panels/MarkdownPanelView.swift:91` and `:109` | Inferred that click is a no-op. The shown range has no pointer overlay. |

### Verified and not a c11 bug (do not re-port)

- 10558 control socket off main: c11 already accepts on a thread and serves each client on a blocking thread (`TerminalController.swift:1898`, `:1941`, `:1995`).
- 5664 `publishV2` JSON retention: that publisher is gone. C11-211 already drains an autoreleasepool per read.
- 5076 and 12853 zoom cleared too early: bonsplit clears `zoomedPaneId` only when the pane itself is gone (`vendor/bonsplit/Sources/Bonsplit/Internal/Controllers/SplitViewController.swift:274-276`). `closePanel` does not over-clear.
- 13214, 13229, 13292: post-fork `CmuxControlSocket` dispatch-source and inode races. That package is absent. 13292 is done-round1.
- 9333 stale `ControlTerminalSocketBindingState`: symbol and `TerminalSurfaceRegistry` are absent. c11 send targeting is the C11-173 path.
- 14698 close reply minted `surface:N+1`: c11 captures the UUID before `closePanel` (`SurfaceHandlers.swift:473-491`) and `v2EnsureHandleRef` (`TerminalController.swift:2496-2509`) keeps the uuid to ref map. Nothing deletes it on close, so the reply cannot mint a new ordinal. Handle map growth is a separate, unmeasured leak.
- 3036 `view.window != nil` guard: c11 intentionally starts a hidden bootstrap window when the view has no window (`GhosttyTerminalView.swift:4135-4142`). App-side git probes are already off main in `GitContextResolver`.
- 4137 background new-workspace command never starts: c11 already calls `requestBackgroundSurfaceStartIfNeeded` for that case.
- 12842 use-after-free half: n/a, see the pool row.
- 2468 macOS 26 glass: c11 already skips `NSGlassEffectView` when it would blank content (`ContentView.swift:2982-3012`, `WindowGlassEffect.isAvailable`).
- 3173 AppleEvents usage string: `Resources/Info.plist:74` is non-empty.
- 3543 and changelog `5ab642a3` / `b361e9a2`: tagged builds use `/tmp/c11-debug-<tag>.sock`, prod owns Application Support, and `shouldHonorSocketPathOverride` (`SocketControlSettings.swift:445-496`) refuses a foreign `C11_SOCKET_PATH`. C11-105 stopped tests unlinking the stable socket. C11-155 gives other bundles their own path.
- 10959 TextBox Escape: default is `sendEscape` (`TextBoxInput.swift:618`) and the handler sends ESC (`:783-788`).
- 13964 workspace ref without `--window`: `normalizeWorkspaceHandle` scans every window when no window is passed (`CLI/c11.swift:4873-4885`).
- 5131 and 8659 git FSEvents storms: c11 has no git-metadata FSEvents watcher. `GitContextResolver` polls `rev-parse` off main. A TODO notes FSEvents invalidation is not built.
- 11050 `~/.local/state/cmux` mkdir loop: c11's socket is `~/Library/Application Support/c11/c11.sock`.
- 6815 and 9420 noclobber `>|` shim: no `cmux-cli-shims` and no clobber operator in the shell scripts.
- 8966 "disabled cwd inheritance" still inherits: c11 has no such off switch. New workspaces always copy the C config (that is 2283).
- Changelog `a14ca57c` / `227305d5` and the 0.64.4 resume-original-cwd row: `AgentForkSupport`, `FileExplorerStore`, and `SessionIndexStore` are absent from `Sources`.

## Top findings

Socket sends can lose bytes. c11's Ghostty still queues PTY writes through `SegmentedPool` (`Exec.zig:419`, `segmented_pool.zig:55-60`). `put()` does not free a slot unless returns happen in order, so the first large `surface.send_text` on a terminal can drop the middle of the payload. Agents depend on `send` for prompts. This is input corruption, and it is not the 2026-08-25 mailbox deadlock (that one is the read thread blocked on a 64-slot app mailbox that only main drains). The matching upstream change is ghostty `e0ef934f7` (`std.MemoryPool`). c11 ghostty `26c3e499e` does not contain it. The use-after-free half of PR 12842 does not apply.

Unfocused agent workspaces mount without a cap, and the sidebar still lays out with `LazyVStack`. `reconcileMountedWorkspaceIds` (`ContentView.swift:3044`) raises `maxMounted` by the size of `pendingBackgroundWorkspaceLoadIds`, and a background `new-workspace` always inserts itself into that set (`TabManager.swift:1419`). With 10 to 40 agents that is 10 to 40 live SwiftUI trees. `VerticalTabsSidebar` still uses `LazyVStack` (`ContentView.swift:8599`), which upstream replaced because drag invalidation recurses through layout (PR 2601). Together these feed known problem 2: AttributeGraph dirty storms, late runloop heartbeats, and main-thread stalls. A separate, already documented freeze is `v2AwaitCallback` pumping the main run loop for the full browser-command timeout (`BrowserHandlers.swift:580-586`, C11-209). Do not copy upstream's "return nil on main" fast-fail. It would break WebKit calls that have to finish on main.

A stale surface handle still falls through to the focused pane on close, clear-history, read, and split (`SurfaceHandlers.swift:304`, `:473`, `:1062`, `:1120`). Send was fixed in C11-173 and refuses that fallback. Close was not. An agent that closes `surface:999` can destroy the operator's focused agent. A UUID that parses but is already dead is fine, because the panel lookup returns `not_found`. The hole is a ref `v2UUID` cannot resolve. `v2RejectUnresolvedPin` already exists and is only wired for metadata writes. 14673 (read of a never-shown terminal) and 14704 (`closePanel` closing the focused pane's selected tab) were verified in round 1.

Shell integration leaks work across days. The zsh git HEAD watcher is `while true; sleep 1` with no parent check, disowned (`cmux-zsh-integration.zsh:500-512`). The PR pollers in bash and zsh only use `kill -0`, so a recycled pid keeps the loop (PR 11035, upstream saw hundreds of orphans). On top of that, bash prepends a prompt hook that does not preserve `$?` (`cmux-bash-integration.bash:384`), git runs with no repo check (`:467`), and zsh has no job-table guard. At 10 to 40 long-lived shells this is memory, `gh` processes, and prompt noise, not a one-time glitch.

Two crash shapes sit next to the known main-thread freezes, and neither is the July 28 or August 25 deadlock. `action_cb` calls `GhosttyApp.shared.handleAction` synchronously while `ghostty_app_new` is still running (`GhosttyTerminalView.swift:1074-1075`, PR 4318 / `76ba2bfd`). A new workspace copies `ghostty_surface_config_s` by value (`Workspace.swift:35-59`), which is how upstream crashed Cmd+N on dangling cwd and env pointers (PR 2283). Both are small ports. Separately, PWD updates go to the key window's tab manager (`GhosttyTerminalView.swift:2241`), so a second window's cwd is recorded on the wrong workspace and restore drifts toward `$HOME`.

## Triage ledger

`pr | disposition | reason`. Verify rows name the status. Changelog rows use `cl-<sha>`.

1621 | noise | Command palette open-in target list. Human UI, not the agent loop.
1677 | verify | shared-confirmed. Shell git probes have no `rev-parse --git-dir` guard. `cmux-bash-integration.bash:467`.
2147 | verify | shared-confirmed. PWD uses the key-window tab manager. `GhosttyTerminalView.swift:2236-2245`.
2150 | verify | shared-confirmed. Unresolvable surface id falls through to the focused pane. Grouped with 9422 and 6605.
2283 | verify | shared-confirmed. Inherited surface config is a copied C struct. `Workspace.swift:35-59`.
2345 | verify | shared-probable. New main windows set no `collectionBehavior`. `AppDelegate.swift:7156`. Inferred.
2375 | verify | verify-skipped. Minimal-mode tab bar in fullscreen. Guess low cosmetic. c11 has minimal mode. Diff not opened.
2466 | verify | verify-skipped. Shell-integration review regressions on the same scripts as 1677, 4959, 15255, and 11035. Hunks not separated.
2468 | verify | already-fixed. Glass is gated off when `NSGlassEffectView` is available. `ContentView.swift:2982-3012`.
2601 | verify | shared-confirmed. Layout half: `LazyVStack` at `ContentView.swift:8599`. Socket-deadlock half not confirmed.
2639 | verify | shared-confirmed. previous/next map to left/right. `GhosttyTerminalView.swift:1921-1926`. Grouped with 9046.
2740 | verify | verify-skipped. Minimal-mode traffic-light inset. Guess low. Diff not opened.
2893 | verify | shared-confirmed. PortScanner never closes the pipe write end. `PortScanner.swift:183-228`.
2972 | verify | n/a-diverged. `installFileDropOverlay` returns once if `themeFrame` is nil and does not retry. `ContentView.swift:1439-1441`. Upstream's hang was a retry loop.
2979 | noise | CI-only deferral of the 2972 overlay retry.
2986 | na-feature | AX window polling. No `AXUIElement` use in c11.
2989 | verify | verify-skipped. Human Cmd+W close-confirmation bypass. Agent paths already avoid `runModal` (C11-204). Guess low.
3036 | verify | n/a-diverged. c11 starts headless surfaces on purpose (`GhosttyTerminalView.swift:4135-4142`). Git probes are off main in `GitContextResolver`.
3153 | verify | verify-skipped. Multi-workspace close-confirmation modality. Human sheet. Guess low. Socket close is already non-interactive (`SurfaceHandlers.swift:489`).
3173 | verify | already-fixed. `NSAppleEventsUsageDescription` is set. `Resources/Info.plist:74`.
3331 | noise | Bonsplit tab bar height. Cosmetic.
3351 | noise | Selected-tab separator. Cosmetic.
3361 | noise | CLI socket-wait telemetry. No hang fix in the title or the paths already read.
3543 | verify | already-fixed. Tagged sockets, `shouldHonorSocketPathOverride`, C11-105, C11-155. `SocketControlSettings.swift:445-496`. Grouped with changelog `5ab642a3` and `b361e9a2`.
3558 | verify | shared-probable. Markdown view has no `OpenURLAction`. `MarkdownPanelView.swift:91`.
3587 | na-feature | Task Manager RSS. c11 has no Task Manager.
3643 | noise | Main macOS CI fix.
3698 | noise | Command palette arrow keys and no-match flash. Same item as the last changelog row. Human UI.
3804 | noise | Folder proxy-icon drag.
3811 | noise | Notification CLI panel parity. Polish.
3823 | noise | Escape dismisses the command palette.
3847 | verify | verify-skipped. Managed defaults replay from a cmux.json store. Guess n/a-diverged. That store was not found in the paths read.
3882 | verify | shared-probable. Custom window-geometry defaults still own frames. `AppDelegate.swift:2155`. Grouped with 7308. Inferred.
3886 | na-feature | Per-pane OSC 11 background tint. Feature added upstream and reverted by 5106. `osc11` is absent.
4042 | verify | verify-skipped. New-workspace caller-window routing. Guess low. Diff not opened.
4132 | na-feature | Task Manager process accounting.
4137 | verify | already-fixed. Background new-workspace commands call `requestBackgroundSurfaceStartIfNeeded` (`TabManager.swift:1439`, `GhosttyTerminalView.swift:4115`).
4290 | verify | verify-skipped. Minimal-mode pane tab drag routing. Guess low. The hang-class bugs are 7076 and 7997.
4318 | verify | shared-confirmed. `action_cb` calls `GhosttyApp.shared` during init. `GhosttyTerminalView.swift:1074`. Grouped with changelog `76ba2bfd`.
4381 | verify | shared-confirmed. `equalizeSplits` forces 0.5. `TabManager.swift:4037`.
4438 | noise | Pane tab width follow-up to 4290. Cosmetic.
4513 | na-feature | Remote proxy connected state.
4568 | na-feature | SSH `runProcess` pipe teardown.
4679 | verify | shared-confirmed. GUI binary does not exec the bundled CLI. In-terminal PATH already prefers `Resources/bin` (`GhosttyTerminalView.swift:3584`).
4800 | verify | shared-probable. `NSFileHandle` readability handler remains on the VS Code serve-web pipe. Low. Remote SSH path is 4568.
4812 | verify | verify-skipped. Open external path args with no socket. Guess low. Diff not opened.
4873 | noise | Bonsplit tab indicator drift. Cosmetic.
4959 | verify | shared-confirmed. No zsh job-table guard. `jobstates` is absent from the zsh script.
5035 | na-feature | Sidebar Project Worktrees button. `ExtensionWorktreePrototype` is not in c11.
5076 | verify | n/a-diverged. Zoom clears only when the zoomed pane is gone. `SplitViewController.swift:274-276`. Grouped with 12853.
5106 | noise | Revert of 3886. No leftover `osc11` path.
5131 | verify | n/a-diverged. No git-metadata FSEvents watcher. `GitContextResolver` polls `rev-parse` off main.
5509 | verify | shared-probable. Socket send is bracketed paste via `ghostty_surface_text`. `GhosttyTerminalView.swift:3938`. Low.
5541 | na-feature | Pinned workspaces inside groups. No workspace-group model.
5595 | na-feature | Inline VS Code command palette and its WebSocket. Not c11's browser.
5664 | verify | n/a-diverged. No `publishV2`. Related JSON retention was C11-211.
5695 | noise | Shell startup matrix coverage. No separate bug named.
6056 | na-feature | OpenWrt remote probe.
6254 | verify | already-fixed. Sentry CLI broken-pipe overlaps SIGPIPE handling. c11 ignores SIGPIPE in the CLI (`CLI/c11.swift:17639`) and sets `SO_NOSIGPIPE` (`TerminalController.swift:1427`). 12503 is the same class and is done-round1.
6289 | noise | Self-hosted CI compatibility.
6368 | na-feature | Release of closed helper windows (Feed, Task Manager, PDF). Those windows are absent.
6605 | verify | shared-confirmed for read/clear/close fallback (grouped with 2150). Send half already-fixed by C11-173.
6786 | noise | Tab bar modifier-hold layout shift. Cosmetic.
6815 | verify | n/a-diverged. No noclobber shim writer in the shell scripts.
6860 | verify | shared-confirmed. Main-thread callback pump. `BrowserHandlers.swift:580`.
7076 | verify | shared-probable. Minimal-mode toggle relayout hang. Inferred. Diff not line-matched. c11 has minimal mode.
7182 | verify | shared-confirmed. Pending background workspace ids raise the mount cap. `ContentView.swift:3030-3052`.
7308 | verify | shared-probable. Display-topology window fit. Grouped with 3882. Inferred.
7749 | verify | verify-skipped. Typed window handles in CLI window commands. Guess low. Diff not opened.
7997 | verify | shared-probable. Tab bar relayout feedback loop in bonsplit. Inferred. Submodule not diffed.
8123 | verify | shared-confirmed. `simulate_shortcut` uses `NSEvent`. `TerminalController.swift:4576`. Debug only.
8193 | noise | Table border thickness. Cosmetic.
8272 | noise | Intel macOS 14 CI verification.
8437 | na-feature | Mirror workspace CLI ids.
8659 | verify | n/a-diverged. The `.attrib` storm was upstream's git FSEvents watcher. c11 does not have that watcher. CLI socket wait includes `.attrib` only while waiting for the socket file (`CLI/c11.swift:1142`).
8693 | na-feature | Pi extension hook dispatch.
8794 | verify | verify-skipped. Tab drops across the full tab bar. Guess low drag. Diff not opened.
8966 | verify | n/a-diverged. The fix is a disable-inheritance setting (`GhosttyWorkingDirectoryResolver`) c11 does not have. Always-inherit is 2283.
9046 | verify | shared-confirmed. Same previous/next mapping as 2639.
9077 | verify | verify-skipped. Detached shell reports under c11Only. Ancestry check exists (`TerminalController.swift:1946`). Whether disowned watchers fail it was not traced. Guess low.
9187 | verify | verify-skipped. Another subprocess pipe leak. PortScanner is already 2893. Other sites not opened. Guess low.
9233 | noise | Xcode 26.3 warning gate.
9244 | na-feature | `RendererRealizationController` warm workspace switch. Post-fork. Symbol absent.
9288 | na-feature | Pinned workspace grouping. No group model.
9333 | verify | n/a-diverged. `ControlTerminalSocketBindingState` and `TerminalSurfaceRegistry` are absent. Post-fork binding layer.
9398 | verify | verify-skipped. Tab drag reorder to the middle. Guess low. Human drag.
9420 | verify | n/a-diverged. Same as 6815. No clobber shim.
9422 | verify | shared-confirmed. Stale destructive targets. Grouped with 2150.
9765 | noise | Horizontal tab strip insertion. Cosmetic.
10035 | verify | verify-skipped. Wide-tab drag. Guess low.
10038 | verify | verify-skipped. Pane tab drag never starts. Guess low. Not the 7997 hang.
10234 | noise | Nightly Release compile break.
10549 | noise | SF Symbol materialization, reverted by 10584. `RenderableSystemSymbol` is absent.
10558 | verify | n/a-diverged. Socket accept and reads are already off main. `TerminalController.swift:1898`.
10584 | noise | Revert of 10549.
10712 | verify | n/a-diverged. c11 events are an NDJSON file (C11-163), not a socket stream that returns access-denied.
10959 | verify | already-fixed. TextBox Escape defaults to `sendEscape`. `TextBoxInput.swift:618` and `:783-788`.
11035 | verify | shared-confirmed. Disowned watchers. zsh HEAD watch has no parent check. `cmux-zsh-integration.zsh:500-512`.
11050 | verify | n/a-diverged. Socket dir is Application Support, not `~/.local/state/cmux`.
11051 | noise | CLI Sentry fingerprint and timeout throttle.
11442 | noise | Swift warning budget.
11720 | noise | `cmux-cli` compile error, hook event argument order.
11999 | noise | Nightly macOS build repair after a bad squash.
12167 | verify | verify-skipped. Pane tab drag hit-test coordinate space. Guess low.
12277 | na-feature | Nightly Freestyle machine creation.
12397 | verify | shared-probable. Adjacent-column skip on top of the confirmed left/right mapping. Not pinned in bonsplit.
12503 | done-round1 | Already in `verdicts-lead.md`. CLI SIGPIPE. c11 ignores it.
12842 | verify | shared-confirmed. SegmentedPool write reuse. UAF half n/a-diverged.
12853 | verify | n/a-diverged. Grouped with 5076. Zoom already survives a tab close inside a live pane.
13214 | verify | n/a-diverged. Fail-closed aliased RPC selectors in post-fork `CmuxControlSocket`. Package absent. Same class as 13292.
13229 | verify | n/a-diverged. Control-socket inode and chmod race in that same package.
13292 | done-round1 | Already in `verdicts-lead.md`. Dispatch-source cancel race. c11 uses blocking client threads.
13404 | verify | n/a-diverged. `SplitPaneGeometryProjection` / `ProvisionalGeometry` are absent. c11's portal transaction is its own path (C11-132 / C11-133).
13728 | noise | Hook telemetry reports prompt length. No user-visible bug.
13843 | verify | verify-skipped. Unresolved `workspace.reorder` target validation. c11 has reorder. Guess low error quality. Diff not opened.
13877 | na-feature | `workspace.group` color and icon. No group model.
13888 | verify | n/a-diverged. Events replay timeout is a socket stream c11 does not use. `configureReceiveTimeout` exists for the CLI client (`CLI/c11.swift:1101`) but events tail reads a file.
13947 | na-feature | Vercel ignore step.
13961 | noise | Names the workspace `workspace.reorder` missed. Error text. Companion of 13843.
13964 | verify | already-fixed. `normalizeWorkspaceHandle` scans all windows without `--window`. `CLI/c11.swift:4873-4885`.
14045 | noise | Hook event original prompt length. Telemetry.
14334 | noise | Test no longer waits 90 s for an app it never starts.
14522 | na-feature | Pi agent parity.
14661 | noise | Event-stream reconnect lint. Package conventions.
14673 | done-round1 | Already in `verdicts-lead.md`. Never-shown `read_text` / `read_screen`.
14698 | verify | n/a-diverged. Close reply uses the pre-captured UUID and the handle map is not cleared. `SurfaceHandlers.swift:491`, `TerminalController.swift:2496`.
14704 | done-round1 | Already in `verdicts-lead.md`. `closePanel` unmapped fallback.
15121 | verify | verify-skipped. Tab hover lands on the first tab. Guess low. Known problem 2's hover bug is `mouseMoved` recursion, a different mechanism. Bonsplit hover was not diffed.
15255 | verify | shared-confirmed. Bash prompt hook returns 0 and is prepended. `cmux-bash-integration.bash:384` and `:527`.
15957 | verify | verify-skipped. Narrow pane tab close can hit the wrong entry. Guess shared-probable, med, data loss. Guard not line-matched in c11 or bonsplit.
15980 | verify | shared-confirmed. `send-key` keeps `keyArgs.first` only. `CLI/c11.swift:2848`.

### Changelog rows (`cl_nopr.txt`)

cl-pdf-toolbar | na-feature | PDF preview download and print. `PDFPreview` is absent.
cl-6f1ecc9f | verify | verify-skipped. Restored unread sidebar badges. c11 has its own notification store. Guess low. Diff not opened.
cl-5ab642a3 | verify | already-fixed. DEV builds stealing the stable socket. Grouped with 3543.
cl-e7941740 | verify | verify-skipped. Minimal-mode pane tab drag moves the window. Guess low. Pair with cl-36fc880f.
cl-0f67df81 | na-feature | Antigravity presentation and resume. c11 only has an Open In Antigravity menu.
cl-9fa5d1d8 | na-feature | Antigravity Vault resume indexing.
cl-80fe38d6 | na-feature | Antigravity fallback session build.
cl-8bd285a9 | na-feature | Antigravity conversation sanitizer width.
cl-12ae177f | na-feature | Grok agent-scoped Vault filtering. No Vault in `Sources`.
cl-84373476 | na-feature | Grok Vault titles and icon.
cl-9f66dffd | na-feature | Deduplicate Grok Vault sessions.
cl-be8c37c4 | na-feature | Shell Grok homes in Vault. Includes `f95b25b9`.
cl-f0370709 | noise | Compact pane tab width. Cosmetic.
cl-fa623368 | na-feature | Session-search ripgrep cancel crash. No ripgrep session search in `Sources`.
cl-aac80054 | na-feature | Right sidebar remembered mode. c11's sidebar is its own model.
cl-e4856922 | verify | verify-skipped. Restored notification badges. Includes `9ffdb45a`. Guess low. c11 notification restore not compared.
cl-9b1e186d | verify | verify-skipped. Workspace cwd metadata for registered agents. Guess n/a-diverged. c11 cwd is the PWD and metadata path, not that registry.
cl-1ca56296 | verify | verify-skipped. Transparent terminal hosting. c11 already forces transparent hosting for glass and translucent themes (`ContentView.swift:2990-2997`). Guess already-fixed. Commit not line-compared.
cl-40863609 | verify | verify-skipped. Browser URL tied to committed navigation. Includes `e240c302`. Not in the browser verdict file. Guess low. Belongs with the browser sweep if revisited.
cl-452745b6 | verify | verify-skipped. Sidebar overlay contrast. Includes `4223df74`. Guess low cosmetic. c11 sidebar chrome diverged.
cl-228f3abd | verify | verify-skipped. Theme contrast on reload. Includes `b6d34706`. Guess low.
cl-1be9d26c | verify | verify-skipped. Reload themes through the socket. Guess low. Diff not opened.
cl-b0f58e47 | noise | Foreground and reload after the interactive theme picker. Includes `8a4e57cf`. Human UI.
cl-b361e9a2 | verify | already-fixed. Ignore inherited socket from another bundle. Grouped with 3543. `shouldHonorSocketPathOverride`.
cl-d198a962 | verify | verify-skipped. Numbered shortcut stale-menu routing. Includes `f2b257fb`. Guess low.
cl-b24cf548 | verify | verify-skipped. Clear restored unread on resume. Includes `f594d5a8`. Guess low.
cl-36fc880f | verify | verify-skipped. Bonsplit minimal tab drag hit testing. Includes `735dde1d`. Guess low. Pair with cl-e7941740.
cl-a14ca57c | verify | n/a-diverged. Gate process termination until launch succeeds. Includes `227305d5`. `AgentForkSupport`, `FileExplorerStore`, and `SessionIndexStore` are absent.
cl-a21a21c5 | noise | Deduplicate the shell wrapper installer.
cl-274128ec | verify | verify-skipped. Permission notifications after auto-allow. Guess low. Diff not opened.
cl-838ad59f | verify | verify-skipped. Markdown and file-preview session reuse. c11 has markdown panels. Guess low. Diff not opened.
cl-76ba2bfd | verify | shared-confirmed. Nightly startup crash, Ghostty callback re-entry. Grouped with 4318. Nucleo half is na-feature.
cl-webview-taskmgr | na-feature | Shared WebView task manager attribution. No Task Manager.
cl-right-sidebar-search | na-feature | Right sidebar tool panel in search.
cl-imessage | na-feature | Repeated assistant iMessage completions.
cl-claude-agent-view | na-feature | Sanitize Claude Agent View passthrough env. That view is absent.
cl-resume-cwd | verify | n/a-diverged. Resume Claude, Codex, and OpenCode from the session index cwd. `SessionIndex` symbols are absent. Do not treat this as c11's resume bug without a separate pass.
cl-ssh-image-drop | na-feature | SSH image drops through the terminal text path.
cl-cmdw-taskmgr | na-feature | Cmd-W closes Task Manager and auxiliary windows.
cl-palette-arrows | noise | Command palette arrow keys and no-match flash. Same as PR 3698.

## Counts

171 rows (131 PR + 40 changelog). na-feature 36, noise 36, done-round1 4, verify 95 (confirmed 22, probable 9, already-fixed 9, n/a-diverged 21, skipped 34).
