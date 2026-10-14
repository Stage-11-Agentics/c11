Task: verify focus-group rows 5108, 5296, 6359, 7278, 13968, 14276, 9754, 10021, 14892, 11349, 6416, 12401, 6073, 5335, 11059 against c11.
---
Start with 5108 (hang).
---
Scope: verify focus-group rows 5108, 5296, 6359, 7278, 13968, 14276, 9754, 10021, 14892, 11349, 6416, 12401, 6073, 5335, 11059.

**(1) Verified table rows**

| bug | PRs | subsystem | c11 status | severity | port | rec | evidence | notes |
|---|---|---|---|---|---|---|---|---|
| Focus broadcast re-enters the focus path synchronously. `applyTabSelectionNow` posts `.ghosttyDidFocusSurface` while `@Published` state is still changing. ContentView's Combine `.onReceive` runs synchronously and calls `focusTab`, which posts again. Upstream saw a 426 s main-thread hang. | 5108 | focus | shared-confirmed | high | S | port | Upstream: `Sources/FocusSurfaceBroadcaster.swift` (new) and `Workspace.swift` post site. c11: synchronous post at `Sources/Workspace.swift:11771-11778`. Synchronous `.onReceive` at `Sources/ContentView.swift:2624-2630`, which calls `attemptCommandPaletteFocusRestoreIfNeeded` → `tabManager.focusTab` (`ContentView.swift:7028-7044`). | The only guard is the per-instance `isApplyingTabSelection`. A cross-workspace cycle can spin main. This is a candidate cause of unexplained main stalls (known problems 2 and 3, inferred). The port is self-contained: defer, coalesce and bound the post. |
| AppKit first responder is on the terminal but Ghostty surface focus is false, so typed text is held until something else reasserts focus. Two holes: (a) `becomeFirstResponder` on a hidden or tiny view suppresses focus and never schedules a retry; (b) printable keys and committed text never reassert Ghostty focus. | 6359, 7278 | focus / input | shared-confirmed | med (could be high) | M | reimplement | Upstream: `GhosttyTerminalView.swift`, which adds `scheduleSuppressedFirstResponderFocusReapply` and `reassertTerminalFocusForInputIfFirstResponder` in `ensureSurfaceReadyForInput`. c11: the hidden/tiny branch only logs (`Sources/GhosttyTerminalView.swift:5310-5318`). `ensureSurfaceReadyForInput` has no focus reassert (`:4919-4928`). `sendTextToSurface` uses a bare `surface` (`:9572-9573`). Only the Ctrl and Option-Backspace fast paths force focus (`:5685`, `:5758`). | Retries fire only on visibility, active, key-window or move-to-window changes (`:7729`, `:7753`, `:8347`, `:8378`). A size change from 0x0 to usable gets no retry. Upstream's reporter saw held input flush after a later `cmux send`. That matches Atin's heavy reparenting and agent `send` traffic (inferred). |
| Closing an unfocused pane steals focus. Bonsplit `closePane` always moves focus to the closed pane's sibling. | 10021 | focus / bonsplit | shared-confirmed | med | S | port | Upstream: bonsplit `SplitViewController.closePane` (manaflow-ai/bonsplit c37440b). c11: `vendor/bonsplit/Sources/Bonsplit/Internal/Controllers/SplitViewController.swift:267-272` sets `focusedPaneId = siblingPaneId` unconditionally. `Sources/Workspace.swift:12325-12329` then applies that focus. | Hits whenever an agent pane exits, or on CLI `close-surface` of a background pane in the operator's current workspace. Fix is about 5 lines in Stage-11-Agentics/bonsplit (push the submodule first). |
| Drag-to-split does not route the moved tab through Workspace's focus owner. Bonsplit, cursor and first responder can disagree after the reparent. | 9754 | focus / layout | shared-confirmed | low | M | watch | Upstream: `Workspace+MovingTabSplit.swift` (new) plus the `didSplitPane` hook. c11: the drag branch in `Sources/Workspace.swift:12414-12491` returns with no activation. | Manual drag only; rare in Atin's agent-driven flow. |
| `goto_split` at a layout edge reports success. `moveSplitFocus` always returns true, so Ghostty `performable:` keybind chains break. | 12401 | keyboard / focus | shared-confirmed | low | S | port | Upstream: `TabManager.moveSplitFocus`, `Workspace+SurfaceNavigation.moveFocus`. c11: `Sources/TabManager.swift:3979-3983`, `Sources/Workspace.swift:10091`. | Trivial to port. Single-setting edge case. |
| Notification jump fails when the notification carries a Bonsplit tab UUID instead of a panel UUID (nested tabs). | 6416 | notifications / focus | shared-probable | low | S | port | Upstream: `TabManager.focusTabFromNotification`. c11: `Sources/TabManager.swift:3612` checks only `tab.panels[surfaceId]`. | Whether any c11 notification source emits a Bonsplit tab id was not pinned (inferred). |
| Unfocused-split dim updates one runloop turn after focus, so a revealed pane flashes dim, then bright. | 14892 | render / focus | shared-probable | low | S | watch | Upstream: `Workspace.reconcileTerminalPortalVisibility...` now sets the dim. c11: dim set only from the host at `Sources/GhosttyTerminalView.swift:10052`. The reconcile at `Sources/Workspace.swift:10949` does not touch it. | Cosmetic. |
| Selection mouse-up or drag is lost when it lands on the Cmd+F find overlay, leaving Ghostty with a stuck left button. | 5335 | input / find | shared-probable | low | S | watch | Upstream: `Sources/Find/TerminalSearchOverlayHostingView.swift` forwards `mouseDragged`/`mouseUp`. c11: plain `NSHostingView<SurfaceSearchOverlay>` at `Sources/GhosttyTerminalView.swift:7000`. `mouseUp` at `:6400` has no pending-release tracking. | Depends on runtime event routing. |
| A stranded first responder (reparented out of its window without resigning) blocks terminal focus recovery. | 5296 | focus | n/a-diverged | n/a | n/a | skip | c11 has no type-only `NSText` / right-sidebar foreign-responder yield. Its only yield is `window.firstResponder is InputTextView` (`Sources/GhosttyTerminalView.swift:8716`, `:8878`). | Same pattern on c11's TextBox `InputTextView`, with no window-membership check. Inferred low risk because the TextBox moves with its panel. |
| Automatic focus reassertion runs after the surface went hidden or 0x0. | 14276 | focus | n/a-diverged | n/a | n/a | skip | c11 checks hidden/tiny geometry before every reassert: `ensureFocus` at `Sources/GhosttyTerminalView.swift:8652`, `applyFirstResponderIfNeeded` at `:8840`, `becomeFirstResponder` at `:5306`. Upstream's bug sits in post-fork `prepareTerminalSurfaceFocusReassertion`. | |
| Focus taken while the runtime surface is still spawning is not mirrored. | 13968 | focus | n/a-diverged | n/a | n/a | skip | c11 sets `desiredFocus = true` before any gate (`Sources/GhosttyTerminalView.swift:5285`). `attachToView` creates the surface synchronously when a window exists (`:3408-3421`). | Upstream bug is in the post-fork `recordExternalFocusState` refactor. |
| SGR mouse press is swallowed on the click that focuses a pane. | 11349 | input | n/a-diverged | n/a | n/a | skip | c11 `mouseDown` always forwards the press to Ghostty (`Sources/GhosttyTerminalView.swift:6372-6397`). There is no focus-only first-click policy. | |
| Minimal UI: top terminal rows are dead inside the titlebar hit-test band. | 6073 | hit-test | n/a-diverged | n/a | n/a | skip | c11 `TerminalWindowPortal.swift` has no titlebar-band pass-through, and neither did the fork point. | Inferred: the band was added upstream after the fork. |

**(2) Triage ledger**

5108 | verify | sync focus broadcast re-entrancy hang; shared-confirmed
5296 | verify | stranded first responder guard; n/a-diverged (c11 lacks the NSText/sidebar yield)
6359 | verify | hidden/tiny becomeFirstResponder has no retry; shared-confirmed (grouped with 7278)
7278 | verify | physical input does not reassert Ghostty focus; shared-confirmed (grouped with 6359)
13968 | verify | focus mirror before runtime exists; n/a-diverged
14276 | verify | reassert focus when hidden or 0x0; n/a-diverged (c11 gates every call site)
9754 | verify | drag-to-split focus reconciliation; shared-confirmed, low
10021 | verify | bonsplit closePane steals focus; shared-confirmed
14892 | verify | unfocused dim lags focus; shared-probable, cosmetic
11349 | verify | SGR focus-click routing; n/a-diverged (c11 always forwards)
6416 | verify | notification focus by bonsplit tab id; shared-probable, low
12401 | verify | goto_split edge result; shared-confirmed, low
6073 | verify | minimal UI titlebar band hit-test; n/a-diverged
5335 | verify | find overlay eats selection mouse-up; shared-probable, low
11059 | na-feature | right-sidebar file drop panel focus; c11 has no right-sidebar file drop

Counts for my rows: 15 total. 14 verify, 1 na-feature. Of verify: 5 confirmed, 3 probable, 0 already-fixed, 6 n/a-diverged, 0 skipped. The 6359/7278 pair is one table row but counts as 2 confirmed rows here.

**(3) Top-finding candidates**

**5108, focus broadcast re-entrancy (high).** c11 still posts `.ghosttyDidFocusSurface` synchronously at the end of `applyTabSelectionNow` (`Workspace.swift:11771`). It does this while selection `@Published` state is still changing. ContentView's synchronous Combine `.onReceive` (`ContentView.swift:2624`) then calls back into `tabManager.focusTab` through command-palette focus restore. The only guard is per-Workspace, so a cycle that crosses workspaces is unbounded. Upstream measured a 426 s main hang from it. With 10-40 agents and heavy socket focus and select traffic, this is a plausible contributor to c11's unexplained long main stalls and the 2026-07-28 deadlock (inferred, not proven). The port is small: a deferred, coalesced, bounded broadcaster replacing one post call.

**6359 + 7278, AppKit and Ghostty focus divergence (med).** c11's `becomeFirstResponder` suppresses Ghostty focus when the view is hidden or tiny and schedules no retry. Printable keys and IME commits also never reassert Ghostty focus. Only the Ctrl and Option-Backspace fast paths call `ghostty_surface_set_focus`. The result: a pane that looks focused but holds typed input until a click, window switch or CLI action reasserts focus. Atin's frequent surface creation and reparenting make this regularly reachable.

**10021, closing an unfocused pane steals focus (med, S).** A one-function fix in `vendor/bonsplit`.
