# Session-b upstream verification

Read-only source review on 2026-10-01 against c11 main `d63b937f6580f362a19dcfe1b2a11fa45a09e765` and its working-tree files. Upstream main is `920ff39ff7cd6166434c12b9c2f167d4284fe6b2`. No builds, tests, runtime probes, fetches, or source edits. PR diffs follow the supplied squash/merge map. Relevant c11 path history since 2026-03-18 was checked, including C11-20, C11-21, C11-22, stable-ID persistence, C11-156, and the exact Codex resume repair. Runtime-dependent conclusions are marked inferred.

## Verified

| bug (plain English) | PRs | subsystem | c11 status | severity | port | rec | evidence (upstream file + c11 path:line) | notes (incl. link to c11 known problem) |
|---|---|---|---|---|---|---|---|---|
| Cancelled work items retain a recursive view capture chain and can overflow the stack | 8615 | SwiftUI / scheduling | shared-confirmed | high | S | reimplement | Upstream `Sources/ContentView.swift`, `Sources/Sidebar/SidebarResizerOcclusionResolver.swift`; c11 `Sources/ContentView.swift:1882`, `:7016` | Both cursor release and palette timeout still capture the value view in stored work items. Upstream replaces these with a reference coordinator and bounded restore attempts. Related to known problem 2, but not proof of its recorded hover stack. |
| Closing a workspace through the wrong manager tears down live terminals | 8753 | workspace lifecycle | shared-confirmed | high | S | port | Upstream `Sources/TabManager.swift` at `a76deb63e0`; c11 `Sources/TabManager.swift:2636` | Root cause: teardown runs before membership is checked at line 2648. A stale cross-window caller can kill another manager's agents. Frequent move and close makes this important. No direct match to the recorded deadlocks. |
| Duplicate panel IDs in a saved session crash restoration | 16182 | session restore | shared-confirmed | high | S | port | Upstream `Sources/Workspace.swift`, `Sources/DockSplitStore+SessionRestore.swift`; c11 `Sources/Workspace.swift:275`, `:1026` | Root cause: Dictionary(uniqueKeysWithValues:) traps on duplicate keys, and pane lists are not deduplicated. Trigger requires a malformed or duplicated snapshot. Can prevent recovery of the entire fleet. |
| Duplicate-instance enforcement can terminate unrelated helper processes | 13845 | app lifecycle | shared-confirmed | high | S | port | Upstream `Sources/AppDelegate.swift` at `f873b5a66b`; c11 `Sources/AppDelegate.swift:12749`, `:12776` | Root cause: bundle identifier is treated as executable identity. The launch observer exempts only the bundled CLI; startup exempts no helpers. Helper inheritance trigger is inferred. |
| Background JSON encoding can overflow the worker stack for deeply nested splits | 14787 | session persistence | shared-confirmed | high | S | reimplement | Upstream `Packages/macOS/CmuxWorkspaces/Sources/CmuxWorkspaces/Session/SessionSnapshotCodingStack.swift`; c11 `Sources/AppDelegate.swift:4646`, `Sources/SessionPersistence.swift:556` | Root cause: recursive layout encoding runs on an ordinary dispatch worker stack. Upstream reports roughly 150 nested splits as the trigger. Unusual for 10 to 40 agents, but a crash if reached. Separate from known mailbox deadlocks. |
| A new copy of the app force-kills the running fleet before it can save | 14831 | app lifecycle | shared-confirmed | high | S | reimplement | Upstream `Sources/AppDelegate.swift`, `Packages/macOS/CmuxWindowing/Sources/CmuxWindowing/SingleInstance/SingleInstanceConflictPolicy.swift`; c11 `Sources/AppDelegate.swift:12745`, `:12784` | Root cause: every matching bundle ID is terminated and immediately force-terminated, without checking bundle path or allowing graceful exit. Tagged builds have separate IDs, but a copied Release app can still trigger this. Related to restart data loss, not the recorded mailbox deadlock. |
| Short socket references silently target different objects after restart | 13633 | socket / session identity | shared-confirmed | high | S | reimplement | Upstream `Packages/macOS/CmuxControlSocket/Sources/CmuxControlSocket/Wire/ControlHandleRegistry.swift`, `Sources/TerminalController+ControlReadSnapshots.swift`; c11 `Sources/TerminalController.swift:279`, `:2496`, `:2512` | Root cause: ordinal counters restart at 1 and refs have no generation. A cached tab:N can send input to or close the wrong restored agent. Stable workspace and panel UUIDs do not make sequential refs durable. |
| Closed windows can retain terminal owners and allow late PTY creation | 8567 | window lifecycle | shared-probable | high | M | reimplement | Upstream `Sources/AppDelegate.swift` and `Sources/TabManager.swift` add finalizeAllWorkspacesForWindowClose; c11 `Sources/AppDelegate.swift:12919`, `Sources/TabManager.swift:1390`, `Sources/Panels/TerminalPanel.swift:245` | Root cause: window unregister drops routing references without permanently retiring its manager or tearing down all panels. A retained view or delayed callback can keep owners alive. Retention and respawn trigger inferred. Adjacent to known problem 1 teardown, but this does not fix its mailbox lock cycle. |
| Duplicate restored panels launch the same agent session twice | 8619 | agent resume | already-fixed | high | - | skip | Upstream `Sources/AgentResumeLaunchGuard.swift`, `Sources/Workspace.swift`; c11 `Sources/Conversation/Store.swift:804`, `Sources/Workspace.swift:566`; commit `58a8be5ba9` | c11 audits global conversation identity and quarantines duplicate owners before resume. This covers duplicate persisted ownership. It does not prove the separate live-process admission issue in 11358 and 12822 is fixed. |
| Recoverable window routes disappear from session snapshots | 9749 | window persistence | n/a-diverged | high | - | skip | Upstream `Sources/AppDelegate.swift`, `Sources/MainWindowLifecycleCoordinator.swift`; c11 `Sources/AppDelegate.swift:4655`, `:4690` | The upstream bug excludes routes held outside its registered context map. c11 has no separate recoverable-route ledger and snapshots every registered context even if its NSWindow is nil. |
| Session capture sends a binding action through a released runtime surface | 12623 | terminal lifecycle | n/a-diverged | high | - | skip | Upstream `Packages/macOS/CmuxTerminal/Sources/CmuxTerminal/Surface/TerminalSurface+CopyMode.swift`; c11 `Sources/GhosttyTerminalView.swift:4203`, `:3279`, `:4272` | c11 nils its published surface pointer before both explicit teardown and deinit free. Its guard therefore rejects actions after release; upstream needs a separate runtime-liveness guard. This does not clear known problem 1. |
| Restored listening ports remain visible after their processes have died | 12436 | session / ports | shared-confirmed | med | S | port | Upstream `Sources/Workspace.swift` at `5ccac534ee`; c11 `Sources/Workspace.swift:1162` | Root cause: transient listeningPorts are restored as current facts. Agent TUIs may never trigger a correcting shell scan. |
| Screen changes synthesize an extra backing-geometry update and can flicker terminals | 14116 | display / terminal | shared-probable | med | S | port | Upstream `Sources/GhosttyTerminalView.swift` at `fb1759a7b6`; c11 `Sources/GhosttyTerminalView.swift:6701`, `:6710` | Same extra asynchronous viewDidChangeBackingProperties call. Visible flicker is inferred because c11 geometry handling differs. C11-191 fixed the separate display-ID deadlock, not this duplicate callback. |
| Workspace IDs are replaced at restart | 8695 | session identity | already-fixed | med | - | skip | Upstream `Sources/TabManager.swift`, `Sources/Workspace.swift`; c11 `Sources/TabManager.swift:5693`; commit `8e1502ebe9` | c11 passes workspaceSnapshot.id into Workspace. Tier 1 persistence independently fixed normal restart identity. |
| Duplicate exported-type plist keys break LaunchServices registration | 12990 | bundle metadata | n/a-diverged | med | - | skip | Upstream `Resources/Info.plist` at `fbaf2392c1`; c11 `Resources/Info.plist:139` | c11 has exactly one UTExportedTypeDeclarations key. The upstream duplicate declaration is absent. |
| Same-display restoration leaves saved windows partly offscreen | 8675 | window restoration | shared-confirmed | med | S | reimplement | Upstream `Sources/AppDelegate.swift` at `5955bdeea0`; c11 `Sources/AppDelegate.swift:3798`, `:4009` | Root cause: matching display geometry returns the saved frame unchanged; it checks finite coordinates and minimum size, not visible bounds. |
| Restore startup titles replace persisted automatic surface names | 8687, 9621 | session / titles | shared-confirmed | med | M | reimplement | Upstream `Sources/Workspace+TitleOwnership.swift`, `Sources/Workspace+RestoredPanelTitleBoundary.swift`; c11 `Sources/Workspace.swift:313`, `:7563`, `Sources/TabManager.swift:3534` | Root cause: startup OSC titles are admitted immediately and focused title propagation uses raw panel titles. Explicit custom titles and c11 stable default workspace names remain protected at `Sources/Workspace.swift:7161`; the exposure is automatic names and legacy workspaces. |
| Titlebar buttons can act on the previously active window | 9282 | window routing | shared-probable | med | M | reimplement | Upstream `Sources/AppDelegate+ShortcutRoutingWindow.swift`, `Sources/Update/UpdateTitlebarAccessory.swift`; c11 `Sources/Update/UpdateTitlebarAccessory.swift:793`, `Sources/AppDelegate.swift:6552` | Root cause: closures use process-global active state instead of the window that received the click. First-mouse ordering trigger is inferred; especially relevant with several restored windows. |
| Visual terminal bells can raise background windows in Stage Manager | 9776 | attention / windows | shared-probable | med | M | reimplement | Upstream `Sources/GhosttyTerminalView.swift` and `Packages/macOS/CmuxTerminal/Sources/CmuxTerminal/Services/Bell/TerminalBellService.swift`; c11 `Sources/GhosttyTerminalView.swift:1813` | Root cause: visual bell invokes NSApp.requestUserAttention instead of marking only the source surface. Stage Manager raising is inferred. Take only the source-scoped attention idea, not upstream notification model replacement. |
| Subagent completions can mark a still-working Claude pane as needing input | 10335, 10343 | Claude hooks / attention | shared-confirmed | med | S | reimplement | Upstream `CLI/CMUXCLI+AgentHookPayload.swift`, `CLI/cmux.swift`; c11 `CLI/c11.swift:16286`, `:16403`, `:16433`, `Resources/bin/claude:205` | Root cause: Stop trusts command dispatch without validating hook_event_name, and every Notification reports idle plus Needs input without excluding agent_completed. The Notification trigger is wired today; SubagentStop through Stop additionally requires stale or custom hook dispatch. This is attention misreporting, not known problem 2's lockup. |
| Notification attribution falls back to the focused pane when identity is missing | 11224 | notifications / CLI | shared-confirmed | med | S | reimplement | Upstream `Sources/TerminalNotificationCallerResolver.swift`, `CLI/cmux.swift`; c11 `CLI/c11.swift:16744`, `:16403` | Root cause: unresolved or absent surface identity falls back to resolveSurfaceId(nil), which uses mutable focus. UUID workspace arguments are already protected by C11-156 at `CLI/c11.swift:16722`. Missing surface attribution still risks reporting another agent's state. |
| Resume does not check whether a surviving process already owns the session writer | 11358, 12822 | agent resume | shared-probable | med | M | reimplement | Upstream `Sources/LiveAgentSessionOwnerIndex.swift`, `CLI/CMUXCLI+RestoreAdmission.swift`, `CLI/CMUXCLI+CodexWriterFinalGuard.swift`; c11 `Sources/Workspace.swift:522`, `:567`, `:669` | Root cause: c11's ownership gate checks ConversationStore records, then types the resume command without a live process or writer-lock check. Inferred risk after an orphan survives quit or when the same session is active outside the restored store. Duplicate stored refs are separately quarantined. Codex can start read-only instead of resuming useful work. |
| Automatic terminal titles are stored and persisted without an application bound | 13009 | titles / persistence | shared-confirmed | med | S | reimplement | Upstream `Packages/macOS/CmuxTerminalCore/Sources/CmuxTerminalCore/TitleChurn/AutomaticTerminalTitle.swift`; c11 `Sources/Workspace.swift:7563`, `:799`, `:247`, `Sources/GhosttyTerminalView.swift:2218` | Root cause: trim-only admission retains arbitrary title contents in observed state and session snapshots. Upstream bounds titles and rejects unsafe controls. This can amplify known problem 2's title invalidation costs; no unbounded-growth claim is made for Ghostty's parser. |
| Restored shell identify loses its location because UUIDs change | 8549 | caller identity | n/a-diverged | med | - | skip | Upstream `CLI/cmux.swift`, `Sources/TerminalNotificationCallerResolver.swift`; c11 `Sources/TabManager.swift:5694`, `Sources/Workspace.swift:1077`, `Sources/SocketHandlers/SystemHandlers.swift:326` | c11 preserves both workspace and panel UUIDs on normal restore. The upstream recovery handles changed spawn identities and TTY binding freshness. c11 has no TTY fallback, so this verdict is limited to the restored-ID trigger, not all stale environments. |
| Claude attach is incorrectly treated as a new interactive session | 10117 | Claude wrapper | already-fixed | med | - | skip | Upstream `Resources/bin/cmux-claude-wrapper`; c11 `Resources/bin/claude:135`; commit `6479fa5c34` | c11 already passes attach and the related Agent View commands through unchanged. |
| Claude SessionStart after clear incorrectly reports running | 13586 | Claude lifecycle | already-fixed | med | - | skip | Upstream `CLI/cmux.swift` at `9e98277396`; c11 `CLI/c11.swift:16203`, `:16257`; commit `26a872e8c9` | SessionStart reports idle, records ownership, and leaves Running to prompt-submit or tool activity. |
| Claude subcommands outside the wrapper allowlist receive inappropriate session flags | 13826 | Claude wrapper | shared-probable | low | S | reimplement | Upstream `Resources/bin/cmux-claude-wrapper`; c11 `Resources/bin/claude:134`, `:230` | Root cause: the static allowlist misses advertised subcommands such as auth, doctor, and update; these enter session/settings injection. Exact behavior depends on Claude version, inferred. Extend the allowlist or use bounded discovery. |

## Top findings

PR 13633 is a direct risk for agent-driven control. c11 restarts every short-ref counter at 1. A restored conversation or script that retains tab:7 can address a different terminal after the new process assigns refs. The same resolution path serves input and close commands. Preserve generation separation for short refs while continuing to use UUIDs for durable identity.

PRs 8753 and 14831 expose destructive lifecycle ordering. closeWorkspace tears down the supplied workspace before checking whether the manager owns it. Single-instance startup asks an existing app to quit and immediately force-kills it without checking which bundle launched it. Both can destroy active sessions. PR 13845 adds a related executable-identity check so helper processes sharing the bundle identifier are not killed.

PR 8615 leaves the same stored DispatchWorkItem closures in c11's value-type ContentView. Repeated scheduling and cancellation can accumulate a recursive capture/release chain. Upstream replaces that ownership shape and bounds focus-restore attempts. This is relevant to known main-thread and hover instability, but the source review does not establish that it caused the recorded AttributeGraph or HoverEventDispatcher stalls.

PR 8567 suggests another lifecycle gap: c11 unregisters a window without explicitly retiring its retained tab manager and all terminal owners. A surviving view or delayed callback can keep resources alive or create another PTY, inferred. PR 16182 is more direct: duplicate panel IDs in the saved array trap during dictionary construction and can prevent restoring the whole fleet. PR 14787 also matches the background recursive encoder, although its roughly 150-deep split trigger is unusual for the stated profile.

Do not lose the round-1 result for PR 14784 while prioritizing this batch. The [lead verdict](../verdicts-lead.md) already ties autosave's needs-confirm-quit call to the shared-mailbox lock cycle in the [2026-08-25 teardown note](../../../../notes/2026-08-25-freeze-surface-deinit-deadlock.md). It is intentionally not reverified here. None of the new findings above establishes a fix for that deadlock. c11's display-ID, free-text ABI, occlusion, autorelease-pool, runModal, and test-unlink fixes remain separate.

## Triage ledger

| pr | disposition | one-line reason |
|---|---|---|
| 8549 | verify | Restored shell identify loses its location because UUIDs change. |
| 8567 | verify | Closed windows can retain terminal owners and allow late PTY creation. |
| 8615 | verify | Cancelled work items retain a recursive view capture chain and can overflow the stack. |
| 8619 | verify | Duplicate restored panels launch the same agent session twice. |
| 8675 | verify | Same-display restoration leaves saved windows partly offscreen. |
| 8687 | verify | Restore startup titles replace persisted automatic surface names. |
| 8695 | verify | Workspace IDs are replaced at restart. |
| 8753 | verify | Closing a workspace through the wrong manager tears down live terminals. |
| 9185 | na-feature | Fixes upstream Codex transcript-monitor or hook-channel machinery absent from c11's conversation capture rail. |
| 9282 | verify | Titlebar buttons can act on the previously active window. |
| 9370 | na-feature | Fixes upstream structured resume bindings, generations, or fork machinery absent from c11's ConversationStore restore implementation. |
| 9397 | na-feature | Fixes upstream structured resume bindings, generations, or fork machinery absent from c11's ConversationStore restore implementation. |
| 9399 | na-feature | Fixes upstream structured resume bindings, generations, or fork machinery absent from c11's ConversationStore restore implementation. |
| 9452 | na-feature | Fixes upstream agent hook title propagation absent from c11. |
| 9477 | na-feature | c11 has no surface.resume.set command or its approval UI. |
| 9549 | na-feature | Fixes upstream structured resume bindings, generations, or fork machinery absent from c11's ConversationStore restore implementation. |
| 9621 | verify | Restore startup titles replace persisted automatic surface names. |
| 9627 | done-round1 | Already covered in verdicts-lead.md. |
| 9631 | done-round1 | Already covered in verdicts-lead.md. |
| 9749 | verify | Recoverable window routes disappear from session snapshots. |
| 9776 | verify | Visual terminal bells can raise background windows in Stage Manager. |
| 9777 | na-feature | The retaining AccessibilityWindowCache snapshot and file-preview sharing presenter are absent from c11. |
| 9780 | na-feature | Fixes upstream Codex transcript-monitor or hook-channel machinery absent from c11's conversation capture rail. |
| 10018 | na-feature | Removes upstream post-fork portal hierarchy swizzles; c11 never added that tracker. |
| 10058 | done-round1 | Already covered in verdicts-lead.md. |
| 10100 | na-feature | Upstream structured Codex resume-binding verifier and publication provenance do not exist in c11; c11 uses causal conversation capture. |
| 10117 | verify | Claude attach is incorrectly treated as a new interactive session. |
| 10175 | na-feature | Fixes upstream fork-parent process scanner and managed agent-hook identity; c11 does not run that scanner. |
| 10293 | na-feature | Fixes upstream managed-settings re-exec and CLI-shim recursion; c11 has neither that re-exec rail nor managed restore settings. |
| 10335 | verify | Subagent completions can mark a still-working Claude pane as needing input. |
| 10343 | verify | Subagent completions can mark a still-working Claude pane as needing input. |
| 10347 | na-feature | Diagnostics for upstream AgentLaunchCommand capture and restore records, which c11 does not implement. |
| 10440 | na-feature | Diagnostics for upstream AgentLaunchCommand capture and restore records, which c11 does not implement. |
| 10773 | na-feature | Fixes upstream aggregate memory-pressure and agent-hibernation policy absent from c11; no shared faulty sampler. |
| 10804 | na-feature | Fixes the post-fork native drag registry and capability lifecycle; c11 uses SwiftUI item-provider drags without those native session owners. |
| 10823 | na-feature | Fixes upstream structured resume bindings, generations, or fork machinery absent from c11's ConversationStore restore implementation. |
| 10838 | na-feature | Fixes upstream Codex transcript-monitor or hook-channel machinery absent from c11's conversation capture rail. |
| 10846 | na-feature | Fixes upstream primary/previous crash-snapshot cache and pruning rail; c11 has no previous-generation cache. Snapshot rotation was already addressed by round-1 PR 14824. |
| 11186 | na-feature | Fixes native AppKit sidebar/file-preview/cloud drag-source ownership introduced after the fork; those owners are absent from c11. |
| 11224 | verify | Notification attribution falls back to the focused pane when identity is missing. |
| 11358 | verify | Resume does not check whether a surviving process already owns the session writer. |
| 11527 | na-feature | Extends upstream raw terminal-report input routing; c11 lacks that report-sequence parser and input rewrite path. |
| 11529 | na-feature | Fixes upstream hook event journal, semantic replay, or blocked-Stop reentry machinery absent from c11. |
| 11972 | na-feature | Changes upstream computer-use onboarding and automatic provider skill installation, absent from c11. |
| 11976 | na-feature | Fixes upstream hook event journal, semantic replay, or blocked-Stop reentry machinery absent from c11. |
| 12062 | na-feature | Fixes upstream agent hook title propagation absent from c11. |
| 12115 | na-feature | Fixes upstream structured resume bindings, generations, or fork machinery absent from c11's ConversationStore restore implementation. |
| 12178 | na-feature | Fixes post-fork monitor-memory and visible-frame-fit retry policy excluding fullscreen; c11 never received that policy. |
| 12436 | verify | Restored listening ports remain visible after their processes have died. |
| 12623 | verify | Session capture sends a binding action through a released runtime surface. |
| 12659 | na-feature | Fixes upstream structured resume bindings, generations, or fork machinery absent from c11's ConversationStore restore implementation. |
| 12697 | na-feature | Fixes upstream structured resume bindings, generations, or fork machinery absent from c11's ConversationStore restore implementation. |
| 12796 | done-round1 | Already covered in verdicts-lead.md. |
| 12822 | verify | Resume does not check whether a surviving process already owns the session writer. |
| 12990 | verify | Duplicate exported-type plist keys break LaunchServices registration. |
| 13009 | verify | Automatic terminal titles are stored and persisted without an application bound. |
| 13057 | na-feature | Fixes upstream Codex transcript-monitor or hook-channel machinery absent from c11's conversation capture rail. |
| 13586 | verify | Claude SessionStart after clear incorrectly reports running. |
| 13590 | na-feature | Fixes upstream integration-toggle-controlled generated command shims; c11 uses its own bundle wrapper policy. |
| 13606 | na-feature | Fixes upstream Codex transcript-monitor or hook-channel machinery absent from c11's conversation capture rail. |
| 13633 | verify | Short socket references silently target different objects after restart. |
| 13704 | na-feature | c11 has no surface.resume.set command or its approval UI. |
| 13826 | verify | Claude subcommands outside the wrapper allowlist receive inappropriate session flags. |
| 13845 | verify | Duplicate-instance enforcement can terminate unrelated helper processes. |
| 13891 | na-feature | Fixes upstream structured resume bindings, generations, or fork machinery absent from c11's ConversationStore restore implementation. |
| 14062 | na-feature | Fixes restoredAgentSnapshotsByPanelId icon fallback and resume states absent from c11's tab lifecycle model. |
| 14116 | verify | Screen changes synthesize an extra backing-geometry update and can flicker terminals. |
| 14130 | noise | Repairs upstream merge/build compatibility or dependency pin, not a shared behavioral defect. |
| 14412 | na-feature | Subrouter proxy routing and structured launcher preservation are upstream-only. |
| 14419 | na-feature | Fixes upstream structured resume bindings, generations, or fork machinery absent from c11's ConversationStore restore implementation. |
| 14784 | done-round1 | Already covered in verdicts-lead.md. |
| 14787 | verify | Background JSON encoding can overflow the worker stack for deeply nested splits. |
| 14812 | na-feature | c11's Claude wrapper does not inject the NODE_OPTIONS restore preload that leaks upstream. |
| 14824 | done-round1 | Already covered in verdicts-lead.md. |
| 14831 | verify | A new copy of the app force-kills the running fleet before it can save. |
| 14860 | na-feature | Prediction echo scanner, browser streaming, and pinned workspace-group crash policy are upstream-only. |
| 14971 | na-feature | Fixes upstream structured resume bindings, generations, or fork machinery absent from c11's ConversationStore restore implementation. |
| 15133 | na-feature | Fixes upstream structured resume bindings, generations, or fork machinery absent from c11's ConversationStore restore implementation. |
| 15567 | na-feature | Fixes upstream Codex transcript-monitor or hook-channel machinery absent from c11's conversation capture rail. |
| 15603 | na-feature | Fixes upstream hook event journal, semantic replay, or blocked-Stop reentry machinery absent from c11. |
| 15612 | na-feature | Fixes upstream Codex transcript-monitor or hook-channel machinery absent from c11's conversation capture rail. |
| 15764 | na-feature | Persistent remote PTY reattach and configured remote command recovery are outside this local session implementation. |
| 15913 | na-feature | Fixes upstream Codex transcript-monitor or hook-channel machinery absent from c11's conversation capture rail. |
| 15930 | noise | Repairs upstream merge/build compatibility or dependency pin, not a shared behavioral defect. |
| 16182 | verify | Duplicate panel IDs in a saved session crash restoration. |
| 16260 | noise | Repairs upstream merge/build compatibility or dependency pin, not a shared behavioral defect. |
| 16371 | na-feature | c11 does not edit Codex TOML hook configuration or contain CmuxCodexConfigEditor. |
| 16378 | na-feature | Follow-up to upstream Codex TOML hook editor, which c11 does not contain. |

## Counts

88 rows; done-round1 6; na-feature 49; noise 3; verify 30: confirmed 15, probable 7, already-fixed 4, n/a-diverged 4, skipped 0.

Counts are PR rows, not grouped bugs. The Verified table contains 27 grouped bugs covering 30 PR rows. Round-1 rows are excluded from verify counts.
