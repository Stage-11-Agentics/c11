# input-b verdicts

Read-only check of 104 upstream cmux bug-fix PRs against c11 main. Round-1 rows are ledger-only (`done-round1`). Severity is for Atin's profile: 10-40 agents, days-long sessions, heavy socket traffic, frequent surface create/close.

## Verified

| bug (plain English) | PRs | subsystem | c11 status | severity | port | rec | evidence | notes |
|---|---|---|---|---|---|---|---|---|
| Scrolling re-arms a full-window layout flush on every AppKit window update, so one scroll tick lays out every window | 6801 | layout | shared-confirmed | high | S | port | Upstream drops `NSWindow.didUpdateNotification` from the layout follow-up (profiled 254-512 ms hangs). c11 still installs it at `Sources/Workspace.swift:10579` and `flushWorkspaceWindowLayouts` lays out every `NSApp.windows` at `:10680` | Known problem 2. The follow-up session stays armed for 2 s (`:10641`) and each tracking event schedules another flush. Drop the didUpdate observer. |
| `send-key ctrl+letter` is keycode plus Ctrl, with codepoint 0 and no key release, so Kitty-protocol TUIs drop the chord | 15928 | input / socket | shared-confirmed | high | S | port | Upstream sets canonical letter text, `unshifted_codepoint`, and a release. c11 `sendKeyEvent` forces `unshifted_codepoint = 0` and press only (`Sources/TerminalController.swift:6502-6523`). Ctrl names carry no text (`:6747-6785`). Comment at `:6716` says ctrl keys encode from the keycode alone | Claude Code and Codex negotiate Kitty. `c11 send-key ctrl-c` then fails to interrupt. C11-173 fixed `space` text and left ctrl on the keycode path. |
| An explicit blank `--workspace` on `close-surface` is dropped, so the command closes the focused workspace's focused surface | 14706 | cli | shared-confirmed | high | S | port | `CLI/c11.swift:2483-2488` passes the flag through `normalizeWorkspaceHandle`, which returns nil on empty (`:4857-4858`) and omits `workspace_id`. `send` / `send-key` already reject a blank flag (`:2806`, `:2837`) | Agents expand `--workspace "$C11_WORKSPACE_ID"`. Empty expansion closes whatever the operator is looking at. 6757's central resolver is already fixed (below); this command does not use it. |
| Restored scrollback replays OSC 10/11 from the old theme, so a theme change comes back white-on-white | 5175 | session | shared-confirmed | med | S | port | Capture is `write_screen_file:copy,vt` (`Sources/TerminalController.swift:3554`). Replay only wraps SGR reset (`Sources/SessionPersistence.swift:613-628`) and does not strip OSC 4/5/10-19 | Days-long sessions plus Light/Dark slot changes. SGR reset does not undo OSC palette writes. Inferred from Ghostty's `copy,vt` export, which is what upstream named. |
| Every precise scroll delta is doubled, including high-resolution mice that are not trackpad gestures | 6449 | input | shared-confirmed | med | S | port | `Sources/GhosttyTerminalView.swift:6613-6616` multiplies x and y by 2 whenever `hasPreciseScrollingDeltas` is set. Upstream gates that on a non-empty `phase` or `momentumPhase` | Trackpads stay correct (they have a gesture phase). A high-res mouse runs away. |
| Claude hook workspace resolution still falls through to the focused workspace when the hook env is not a UUID | 7228 | cli / hooks | shared-confirmed | med | S | port | `resolveWorkspaceIdForClaudeHook` trusts a UUID (`CLI/c11.swift:16732`) then `return try resolveWorkspaceId(nil)` (`:16741`), and nil reads `workspace.current` (`:8153`) | C11-156 stopped the happy path from probing main. The nil fallback is the upstream bug. A hook with a stripped env retargets status and notifications onto the focused workspace. |
| Screenshot paste PNG-encodes on the clipboard callback, up to 10 MB, before the terminal can read again | 8838 | clipboard | shared-confirmed | med | M | reimplement | `read_clipboard_cb` calls `saveClipboardImageIfNeeded` inline (`Sources/GhosttyTerminalView.swift:1077-1093`). TIFF to PNG is synchronous (`:339-343`) | Known problem 2. Upstream built a worker process. A background queue around the encode is enough. Do not port the worker scaffold. |
| Text box `updateNSView` overwrites the live editor whenever the SwiftUI binding lags | 9084 | textbox | shared-confirmed | med | S | port | `Sources/TextBoxInput.swift:990-992` assigns `textView.string = text` whenever marked text is clear and the strings differ. Upstream stopped treating the binding as input | Sidebar and theme refreshes clobber an in-progress draft, selection, and the text box undo stack. 5340 added the sync; 9084 removed it. |
| Paths inserted into the terminal or text box do not escape `~`, so the shell expands a literal tilde | 9734 | clipboard | shared-confirmed | med | S | port | Escape sets omit `~`: `Sources/GhosttyTerminalView.swift:93` and `Sources/TextBoxInput.swift:1119`. Upstream added `~` to the same character set | File drops and pasted paths. A name containing `~` is expanded. |
| Managed PATH is prepended without dropping U+FFFD or control-byte components, so a malformed parent PATH is re-exported into every new pane | 12057 | terminal env | shared-confirmed | med | S | port | `Sources/GhosttyTerminalView.swift:3584-3591` splits on `:` and prepends `Resources/bin`. No malformed-scalar filter | Trigger is an already-corrupt parent PATH (Foundation replacement characters). Once present, every new agent shell inherits it. |
| Unmounting a workspace hides the terminal view but leaves it in the window | 12607 | portal | shared-confirmed | med | S | port | `hideEntry` sets `isHidden` and returns (`Sources/TerminalWindowPortal.swift:1472-1481`). Upstream also `removeFromSuperview` while keeping the portal binding and PTY | WindowServer still tracks one view tree per hidden surface. Scales with workspace count. Known problem 2 (inferred: extra hit-test and gesture work). Five-line port. |
| `Resources/bin/open` `trim()` uses bash bracket-pattern removal with no script-wide `LC_ALL=C`, which SIGSEGVs some bash builds on non-ASCII arguments | 13301 | open shim | shared-confirmed | med | S | port | `Resources/bin/open:37-41`. `LC_ALL=C` exists only inside `to_lower_ascii` (`:46`) and one later helper (`:226`) | Crash is the wrapper, not c11. Japanese filenames and Unicode hosts hit the first `case` scan. `/bin/bash` often does not reproduce it. Inferred from upstream's MacPorts bash 5.3 report. |
| Pane resize applies the latest Ghostty scrollbar packet as the scroll origin, so a review position jumps | 10489 | terminal scroll | shared-probable | med | M | reimplement | `synchronizeScrollView` scrolls to `scrollbar.offset` whenever the user is not live-scrolling (`Sources/GhosttyTerminalView.swift:9471-9514`). `shouldAutoScroll` is also true when the packet says the viewport is at the bottom | Upstream added a viewport intent that layout must not write. Inferred: the buffer itself stays; the place in it does not. Agents resize splits often. |
| SwiftUI `.textSelection(.enabled)` sits on markdown that live-reloads | 12056 | swiftui | shared-probable | med | S | port | `Sources/Panels/MarkdownPanelView.swift:91-93` and `:109-111`. Upstream replaced dynamic `.textSelection(.enabled)` with a copy context menu after SwiftUI field-editor hangs | Not the sidebar AttributeGraph storm (known problem 2), same family. Static feedback copy at `Sources/ContentView.swift:10064` is fine. Inferred the hang needs a selection active while the text identity changes. |
| Cmd-click does not match a URL that soft-wraps across rows | 8110 | ghostty | shared-probable | med | L | watch | cmux ghostty `366c801e06` (URL match across semantic wraps) is not an ancestor of c11 ghostty `26c3e499e`. No soft-wrap match in `ghostty/src/config/url.zig` | Agent output wraps long links. Port is a ghostty fork change. |
| Vim copy-mode Y copies by faking a mouse drag on the visible viewport, and c11 ghostty has no absolute screen-row selection API | 6221 | copy mode / ghostty | shared-probable | med | L | watch | `copyLineAndExit` calls `copyCurrentViewportLinesToClipboard` (`Sources/GhosttyTerminalView.swift:5101-5107`), which presses and drags inside `bounds` (`:5040-5061`). `ghostty_surface_select_screen_rows` is absent. cmux ghostty `49cb510f75` is not in HEAD | Scrollback copy and V/Y drift once the row is outside the viewport. Needs the ghostty C API, then the Swift caller. |
| Ghostty's own keybinds are consulted and can consume the event before c11's shortcut owner | 14508 | keyboard | shared-probable | med | S | port | `ghostty_surface_key_is_binding` then `keyDown` and return (`Sources/GhosttyTerminalView.swift:5479-5504`). No host unbind list. Upstream injects `keybind = super+t=unbind` (and the rest of the host set) before user config | Cmd+T works today, so Ghostty is not currently claiming it (inferred). Clearing a c11 shortcut, or a user Ghostty config, revives Ghostty's bind. Small config inject. |
| Keyboard copy mode stays armed on a pane after focus leaves it | 10363 | copy mode | shared-probable | med | S | port | Cleared only for exit, copy, and copy-line (`Sources/GhosttyTerminalView.swift:5087-5109`). No cancel on resign or surface hide. Upstream `cancelKeyboardCopyMode` runs when the surface deactivates | Selection and mode belong to the view that entered them. A later copy can read the stale pane. Inferred from the missing cancel. |
| Quit has no deadline if AppKit blocks in `applicationWillTerminate` | 6837 | lifecycle | shared-probable | med | S | watch | No `TerminationWatchdog`. `applicationShouldTerminate` returns `.terminateNow` (`Sources/AppDelegate.swift:3045-3057`). `applicationWillTerminate` (`:3060-3077`) snapshots, stops the socket, and flushes PostHog on main | Upstream's concrete trigger is promised pasteboard data vs a clipboard manager. c11 writes pasteboard items but this pass did not prove a promise. The watchdog is still the only bound on a stuck quit before session restore. |
| Cmd+Z can hit the window undo stack after the text box that registered it is gone | 7598, 12570 | textbox / undo | shared-probable | med | M | port | Text box sets `allowsUndo = true` (`Sources/TextBoxInput.swift:912`). No Cmd+Z redirect in `cmux_performKeyEquivalent` (`Sources/AppDelegate.swift:14387`). Upstream routes undo to the live terminal or web view and refuses the shared window stack | Crash is the upstream symptom (`#7272`). Inferred c11 can hit it after closing a text box and pressing Cmd+Z. Not proven with a crash log. |
| `zh-Hant` is stored as a raw `AppleLanguages` string, and choosing System deletes the key | 7698 | localization | shared-probable | low | S | watch | `LanguageSettings.apply` writes `[language.rawValue]` or `removeObject` (`Sources/c11App.swift:4049-4054`) | Upstream's bug was cmux wiping a foreign override and not applying Traditional Chinese at change time. Atin runs English. Real for zh-Hant users. Inferred the raw tag is still the macOS Hans/Hant mix-up. |
| Vim-mode cursor shape is drawn without Ghostty's effective cursor visual state | 8995 | copy mode / ghostty | shared-probable | low | L | watch | cmux ghostty `0b1734f1ee` is not in c11 HEAD. c11 copy mode tracks `keyboardCopyModeVisualActive` locally (`Sources/GhosttyTerminalView.swift:4358`) | Cosmetic cursor. The ghostty bump in that PR also carries unrelated fork history. |
| NFD Hangul is not canonically composed before font selection | 9808 | ghostty | shared-probable | low | L | watch | `3fbdd078df` (`font: resolve NFD Hangul clusters via canonical composition`) is not in c11 ghostty HEAD | Korean input and filenames. Low for Atin's English sessions. c11 ships a ko locale. |
| Shell-integration cursor feature is left on, so prompts can leave the block cursor | 10670 | terminal | shared-probable | low | S | watch | No `shell-integration-features` override in `Sources/`. Upstream clears the cursor bit and spells out the other features so Ghostty does not reset them | Cosmetic. Daily if the prompt cursor is a bar. |
| Menu Copy always calls parameterless `copy_to_clipboard`, ignoring a configured Ghostty flavor | 11515 | clipboard | shared-probable | low | S | watch | `Sources/GhosttyTerminalView.swift:5061` and `:5098`. Upstream maps plain/vt/html/mixed and keeps the parameterless spelling as the mixed default | Only matters when a Ghostty config sets a flavor. c11 has no flavor setting of its own. |
| The Copy menu guard uses `charactersIgnoringModifiers`, which disagrees with AppKit on Command-swapped layouts | 13015 | keyboard | shared-probable | low | S | watch | `Sources/GhosttyTerminalView.swift:5508` switches on `charactersIgnoringModifiers`. Upstream asks the layout for the Command-table character | Dvorak-QWERTY-command. QWERTY is unaffected. |
| Korean fallback glyphs are not sized to the terminal cell | 14653 | ghostty | shared-probable | low | L | watch | `0068ece733` (`fix: size CJK fallback faces to the terminal span`) is not in c11 ghostty HEAD | Extra spacing. Cosmetic. |
| Text box IME `setMarkedText` is not range-clamped, so a stale replacement range raises | 14786 | textbox / ime | shared-probable | low | S | watch | `InputTextView` overrides `insertText` (`Sources/TextBoxInput.swift:1192`) and does not sanitize `setMarkedText` replacement ranges. Upstream clamps to the UTF-16 storage | Japanese IME. Terminal side of the same family is 13581, already verified in round 1. |

## Top findings

**Scroll follow-up is wired to `NSWindow.didUpdateNotification`.** While a layout follow-up is open (up to two seconds, re-armed as it runs), every scroll, drag, and mouse-move posts `didUpdate`. c11's handler schedules `flushWorkspaceWindowLayouts`, and that function calls `layoutSubtreeIfNeeded` and `displayIfNeeded` on every window, not the window being scrolled. Upstream measured 254-512 ms main-thread hangs from this and 0 hangs after removing the observer. With many workspaces and agents, that is a direct feed into the main-queue backlog (known problem 2). The fix is deleting one observer. The structural observers (surface ready, portal visibility, focus) stay.

**`send-key` Ctrl-letters do not satisfy Kitty.** c11 builds a press with the virtual keycode, the Ctrl modifier, `unshifted_codepoint = 0`, and no text, and it never sends the release. Ghostty's Kitty encoder needs the letter to derive both the legacy C0 byte and the CSI-u sequence. Claude Code and Codex turn Kitty on. `c11 send-key ctrl-c` aimed at another agent is then a no-op interrupt, which looks like a stuck agent. C11-173 already fixed the same hole for `space`. Extending that text and adding the release is a small change in `TerminalController.sendKeyEvent`.

**Blank `--workspace` still closes the focused surface.** `send` and `send-key` reject an empty flag (C11-173). `close-surface` does not. `normalizeWorkspaceHandle` turns `""` into nil, the CLI omits `workspace_id`, and the server closes whatever is focused. An agent whose `C11_WORKSPACE_ID` failed to expand, running the skill's `--workspace "$C11_WORKSPACE_ID"` pattern, deletes the operator's current pane. The same nil-on-blank helper is used by other v2 commands. `resolveWorkspaceId` already throws on empty (`CLI/c11.swift:8118`). `close-surface` should use that, or `normalizeWorkspaceHandle` should.

**Hidden terminals stay in the window, and screenshot paste encodes on the clipboard callback.** Unmounting a workspace only sets `isHidden`. The view remains a subview, so WindowServer keeps a live tree per background surface. Upstream's fix removes the view and keeps the PTY. Separately, a screenshot paste runs TIFF-to-PNG inline in Ghostty's clipboard callback, up to 10 MB, on the thread Ghostty calls back on (main, inferred). Both add main-thread and WindowServer work that grows with agent count (known problem 2). The portal change is a few lines. The paste change should be a background encode, not upstream's worker-process split.

**Hook fallback and theme-colored scrollback are the other session-scale bugs.** If a Claude hook arrives without a workspace UUID, c11 still asks for `workspace.current` and writes status onto the focused workspace. The common path is safe because c11 injects `CMUX_WORKSPACE_ID` and C11-156 trusts that UUID. The fallback is the bug 7228 removed. Independently, session restore replays Ghostty's `copy,vt` scrollback, which bakes OSC 10/11 from the theme at capture time. c11 wraps an SGR reset around that text and leaves the OSC sequences in. After a Light/Dark change, restored history can come back in the old colors, including white-on-white. Strip the color OSCs before replay.

## Triage ledger

pr | disposition | one-line reason
---|---|---
5005 | verify-skipped | Titlebar drag vs interactive controls. Guess na-feature: c11 has no right-sidebar titlebar host.
5045 | noise | Clipped shortcut-hint tooltip and a sidebar min width. Cosmetic.
5101 | na-feature | Right-sidebar titlebar buttons. c11 has no right sidebar.
5102 | na-feature | Titlebar band over right-sidebar buttons. Same missing surface.
5108 | done-round1 | Focus broadcast re-entrancy. `verdicts-focus.md`.
5145 | noise | Shortcut-hint pills clipped on macOS 26.5. Cosmetic.
5175 | verify | Restored scrollback keeps OSC theme colors. shared-confirmed.
5182 | na-feature | Right-click sidebar view switcher and built-in views. c11 has no that sidebar.
5196 | verify-skipped | Workspace number shortcut rebind. Guess shared-probable, low. Not pinned.
5292 | verify-skipped | Copy-mode vim keys under CJK input sources. Guess shared-probable, low.
5296 | done-round1 | Stranded first responder. `verdicts-focus.md`, n/a-diverged there.
5317 | verify | Text box dismantle crash. n/a-diverged: c11's text box has no `dismantleNSView` that publishes.
5335 | done-round1 | Find overlay eats selection mouse-up. `verdicts-focus.md`.
5340 | verify-skipped | Text box IME sync. Guess already-fixed for the marked-text guard at `TextBoxInput.swift:990`. Residual low.
5480 | noise | Notification sound preview playback.
5601 | noise | Shift-click range anchor after a no-op drag.
5616 | verify-skipped | Same shortcut-rebind family as 5196. Guess shared-probable, low.
5651 | noise | Honor Focus / Do Not Disturb for the fallback sound.
5760 | noise | Updater error copy and a manual-download link.
5955 | noise | Re-assert overlay scrollers when the scroller style changes.
5956 | na-feature | Find pane for same-directory workspaces. c11 has no file explorer.
6052 | noise | Micro sidebar row cleanups. The livelock is 7117/8211, already verified.
6055 | verify | Cmd+T cwd after restore. n/a-diverged: C11-238 root wins (`Workspace.swift:8893`) and home is not adopted (`:7214`).
6073 | done-round1 | Minimal UI titlebar hit testing. `verdicts-focus.md`, n/a-diverged there.
6200 | verify-skipped | Copy-on-select parity. Guess shared-probable, low. c11 has no `copyOnSelect` symbol.
6221 | verify | Vim copy-mode cursor, V/Y, pasteboard. shared-probable.
6359 | done-round1 | Focus retry after tiny handoff. `verdicts-focus.md`.
6416 | done-round1 | Notification jump for nested tabs. `verdicts-focus.md`.
6449 | verify | Precise scroll doubled for every precise device. shared-confirmed.
6477 | verify-skipped | Cmd+grave global show/hide. Guess na-feature: no grave hotkey in `KeyboardShortcutSettings.swift`.
6591 | noise | Settings search index cached per runtime. Does not scale with agents.
6621 | verify | Spurious home pwd after agent-resume restore. n/a-diverged, same C11-238 root rule as 6055.
6627 | noise | Sidebar selection highlight timing.
6757 | verify | Caller workspace vs focused. already-fixed in `resolveWorkspaceId` (`CLI/c11.swift:8118`). Residual blank flags are 14706.
6801 | verify | Scroll pumps full-window relayout. shared-confirmed.
6812 | noise | Tab bar width shift on focus. Cosmetic bonsplit chrome.
6837 | verify | Termination watchdog. shared-probable.
6923 | verify | Join soft-wrapped rows on copy. n/a-diverged: c11 copies via Ghostty `copy_to_clipboard` (`GhosttyTerminalView.swift:5061`), not a Swift row joiner.
7117 | done-round1 | Sidebar scroll render storm. `verdicts-lead.md`.
7228 | verify | Claude hook falls back to the focused workspace. shared-confirmed.
7278 | done-round1 | Reassert Ghostty focus before input. `verdicts-focus.md`.
7400 | verify | Workspace drag pasteboard deadlock. n/a-diverged: c11 completes the provider synchronously (`ContentView.swift:14582`). The MainActor hop was upstream-only.
7437 | noise | Codex security-scanner findings. Inferred not an operator-facing hang. Diff not read line by line.
7598 | verify | Undo shortcut crash routing. shared-probable, grouped with 12570.
7698 | verify | zh-Hant vs zh-Hans AppleLanguages. shared-probable, low.
7816 | verify-skipped | Divider cursor hit target and occluded-window bleed. Guess shared-probable, low. c11 already has a divider cursor.
7901 | verify-skipped | Notification scroll restoration. Guess shared-probable, low. Diff is huge.
7909 | noise | Command palette outside-click dismissal lifecycle.
8071 | noise | Overflowing tab selection scroll and chrome alignment.
8110 | verify | Cmd-click soft-wrapped URLs. shared-probable, ghostty.
8155 | done-round1 | Title-churn lifetimes. `verdicts-lead.md`.
8190 | na-feature | Unauthenticated GitHub sidebar polling. c11 does not poll GitHub for sidebar rows.
8211 | done-round1 | Sidebar scroll livelock. `verdicts-lead.md`.
8226 | na-feature | GitHub polling lifecycle regressions. Same missing feature as 8190.
8366 | na-feature | Lawrence AppKit sidebar dogfood. c11 has no `Sources/Sidebar/AppKitList`.
8688 | verify-skipped | Text box IME composition rendering. Guess shared-probable, low. c11's text box is a thinner editor.
8699 | verify-skipped | Global Search shortcut foreground scope. Guess low. c11's palette is a different surface.
8838 | verify | Screenshot paste prep on the calling thread. shared-confirmed.
8853 | verify-skipped | Focus-history shortcut rebind. Guess shared-probable, low.
8927 | verify-skipped | Focused-read indicator vs surface mark-read. Guess shared-probable, low.
8995 | verify | Vim-mode cursor rendering. shared-probable, low.
9031 | verify-skipped | Sticky workspace identity into Cmd+N. Guess n/a-diverged under the C11-238 root model.
9084 | verify | Text box binding clobber. shared-confirmed.
9734 | verify | Literal tildes in inserted paths. shared-confirmed.
9754 | done-round1 | Drag-to-split focus. `verdicts-focus.md`.
9781 | verify-skipped | Bundled open shim first on PATH. Guess already-fixed: c11 prepends `Resources/bin` (`GhosttyTerminalView.swift:3584`).
9808 | verify | NFD Hangul font clusters. shared-probable, low, ghostty.
10021 | done-round1 | Close unfocused pane steals focus. `verdicts-focus.md`.
10248 | na-feature | Sidebar empty-area double-click action setting. c11 has no that control.
10363 | verify | Copy-mode selection scope across splits. shared-probable.
10452 | verify-skipped | Option-only arrow and text bindings. Guess shared-probable, low.
10489 | verify | Scrollback position across pane resize. shared-probable.
10670 | verify | Shell-integration prompt cursor. shared-probable, low.
10820 | noise | Nightly CLI compile after a Cursor approvals change.
10835 | verify-skipped | Native resize cursors at window edges. Guess shared-probable, low.
11059 | done-round1 | Right-sidebar file-drop focus. `verdicts-focus.md`, na-feature there.
11254 | noise | No `pr_sha.tsv` row. Title is an upstream compile break (`GhosttySurfaceScrollView` API). Not fetched via `gh`.
11316 | noise | Upstream compile break in a portal-ownership guard c11's scroll view does not share.
11349 | done-round1 | SGR mouse on focus click. `verdicts-focus.md`, n/a-diverged there.
11515 | verify | Native Copy vs Ghostty clipboard flavor. shared-probable, low.
12053 | verify | Window frame repair. already-fixed: `resolvedWindowFrame` clamps and relocates onto a visible display (`Sources/AppDelegate.swift:3771-3980`). The CI half of the PR is noise.
12056 | verify | SwiftUI dynamic text selection hangs. shared-probable.
12057 | verify | Malformed PATH bytes re-exported. shared-confirmed.
12401 | done-round1 | `goto_split` edge result. `verdicts-focus.md`.
12570 | verify | Stale undo target crash. shared-probable, grouped with 7598.
12607 | verify | Inactive portal views stay in the window. shared-confirmed.
12817 | verify-skipped | Mixed copy-mode and app-host bundle, mostly packages c11 does not have. Guess na-feature.
12997 | done-round1 | Option dead-key composition. `verdicts-lead.md`.
13015 | verify | Copy guard vs Command-aware layout. shared-probable, low.
13018 | verify | `terminateLater` skipped when quit starts inside `main.sync`. n/a-diverged: c11 returns `.terminateNow` and never uses `terminateLater` (`AppDelegate.swift:3045`).
13301 | verify | open wrapper SIGSEGV on multibyte args. shared-confirmed.
13581 | done-round1 | Japanese IME Backspace. `verdicts-lead.md`.
13583 | verify-skipped | Quit preference after the last terminal exits. Guess shared-probable, low.
13968 | done-round1 | Focus mirror before the runtime surface exists. `verdicts-focus.md`, n/a-diverged there.
14276 | done-round1 | Focus reassert on unusable geometry. `verdicts-focus.md`, n/a-diverged there.
14508 | verify | Ghostty tab and window keybinds. shared-probable.
14582 | noise | Notifications popover anchor. Cosmetic.
14653 | verify | Korean fallback glyph spacing. shared-probable, low, ghostty.
14706 | verify | Blank `--workspace` on close-surface. shared-confirmed.
14786 | verify | Text box IME replacement range crash. shared-probable, low.
14810 | noise | Welcome text points at a fixed shortcut list. Docs.
14892 | done-round1 | Unfocused-pane dim lags focus. `verdicts-focus.md`.
15565 | na-feature | Feature Flags window traps Cmd-` and ignores Cmd-W. c11 has no `InternalFlagsWindow`.
15928 | verify | send-key Ctrl-letter under Kitty. shared-confirmed.

## Counts

rows 104, done-round1 20, na-feature 9, noise 19, verify 56. Of verify: confirmed 12, probable 17, already-fixed 2, n/a-diverged 6, skipped 19.
