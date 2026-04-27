# C11-19 — Pane X button still unresponsive on some panes

**Type:** Investigation + repair brief for the next agent.
**Linked work:** PR #81 (origin), Lattice ticket C11-19, neighbor C11-18.
**Mission:** Find why some panes' close (×) buttons swallow clicks even after the `.overlay → .background` fix in `vendor/bonsplit/Sources/Bonsplit/Internal/Views/PaneContainerView.swift`, and fix it. Validate the fix end-to-end **without** asking the operator to manually click around — see "Automation plan" below.

---

## What you're walking into (you don't need the original chat)

PR #81 added a pane-close confirmation overlay. The overlay needed to render *above* the `WindowTerminalPortal` AppKit layer (which floats above the workspace's SwiftUI tree). The shipped architecture:

1. **Anchor in SwiftUI** — `Sources/Panels/PaneInteractionOverlayHostView.swift` is an invisible `NSViewRepresentable` rendered inside each Bonsplit pane via the new `paneOverlayBuilder` SwiftUI environment value (defined in `vendor/bonsplit/Sources/Bonsplit/Internal/Views/PaneContainerView.swift`). Its `AnchorView` overrides `hitTest` to return `nil` and reports its `convert(bounds, to: nil)` to the workspace controller.
2. **Workspace controller** — `Sources/Panels/PaneCloseOverlayController.swift` owns a per-workspace `PaneInteractionRuntime` (`Workspace.paneCloseInteractionRuntime`). It subscribes to `runtime.$active`. When an interaction is active for a pane, it mounts an `PaneInteractionOverlayHost` (NSView) into `window.contentView?.superview` (the themeFrame), positioned *above* the portal's host view, sized to the anchor's reported window-coord frame. When inactive, the host is removed.
3. **Confirmation card** — reuses the existing `PaneInteractionOverlayHost` + `PaneInteractionCardView` infrastructure (the same code path used for tab-close). New `ConfirmContent.style = .criticalDestructive` opts into red emphasis; `detailLines` renders a tab list.
4. **Trigger** — `Workspace.splitTabBar(_:didRequestClosePane:)` builds the `ConfirmContent`, presents on the runtime, awaits the result, then either calls `bonsplitController.closePane(pane)` (multi-pane) or force-closes every tab + `newTerminalSurface(inPane:)` (only-pane reset).
5. **Bonsplit only-pane support** — `vendor/bonsplit/Sources/Bonsplit/Internal/Views/TabBarView.swift` was changed so `canClosePane` honours `BonsplitConfiguration.allowCloseLastPane`; the c11 config opts in.

### Click-passthrough regression and partial fix

The original mount used `.overlay { paneOverlayBuilder(pane.id) }`. SwiftUI's overlay container intercepted clicks across the entire pane (tab bar included) even with `.allowsHitTesting(false)` on the inner content. Switched to `.background { ... .allowsHitTesting(false) }` in `PaneContainerView`. That fixed *most* panes — but in dense / deeply-split workspaces, **some panes' ×s still swallow clicks**. That's C11-19, your job.

Before-state confirmed by debug log instrumentation (since removed): `splitTabBar(_:didRequestClosePane:)` is **never invoked** for the bad panes — the click never reaches Bonsplit's button action handler. So the fault is somewhere between the cursor and Bonsplit's `SplitToolbarButton`, not in the c11 handler.

---

## Hypotheses, ranked

### H1 — `.background` is still capturing clicks in some layout configurations
The `.background` modifier in SwiftUI is layout-sized to the modified view (the `VStack { tab bar; content }`). Even with `.allowsHitTesting(false)` on the contained `NSViewRepresentable`, the `NSHostingView` SwiftUI wraps it in might not propagate the hit-test ban in every nesting depth. Worth verifying with a hit-test trace.

**How to test:** add an `NSLog` to `PaneInteractionOverlayHostView.AnchorView.hitTest(_:)` and to its surrounding `NSHostingView` chain. Click a "bad" pane's ×. If `AnchorView.hitTest` is invoked and a parent of it ends up consuming the click, this is your bug. If `AnchorView.hitTest` is *never* invoked, move to H2.

**Likely fix path:** drop the SwiftUI mount entirely and switch the anchor strategy to a Bonsplit-internal API that exposes the pane's NSView directly, OR walk the responder chain in `PaneContainerView` to attach the anchor to the existing `PaneDragContainerView` AppKit container (see `vendor/bonsplit/Sources/Bonsplit/Internal/Views/SplitNodeView.swift`).

### H2 — `WindowTerminalPortal` is the click thief on some panes
The portal's host view (`Sources/TerminalWindowPortal.swift`) is added to the themeFrame above the SwiftUI content view and constraint-pinned to fill the contentView. Its subviews are terminal scroll views frame-positioned to match each pane's content area. If the portal's hit-test computation ever extends a hosted scroll view's frame to *include the tab bar region* of a particular pane (during reparenting, live resize, or after a same-frame churn like the only-pane reset path — also see C11-18), the portal will absorb the click before it reaches the SwiftUI tab bar underneath.

**Why this is plausible despite predating PR #81:** the portal layer has always sat above SwiftUI; the new c11 config (`allowCloseLastPane: true`) just unblocks a code path that *exposes* the symptom more often. Note the related C11-18 ("Ghostty surface duplicated/overdraws above pane bounds during portal sync").

**How to test:** before clicking the bad pane's ×, log the portal entry frames for that pane (call `WindowTerminalPortal` internals via a debug hook, or grep its existing `dlog(...)` calls — see `portal.hostFrame.update`, `portal.detach`, `portal.attach`). Compare each entry's frame in window coords against the tab bar's frame in window coords. Overlap = the portal absorbs the click.

**Likely fix path:** if confirmed, this becomes part of C11-18 work — make the portal honour the tab-bar exclusion zone or move the entry to the correct content-area frame on every layout pass.

### H3 — `paneInteractionRuntime` per-panel overlays are leaking
`Workspace.paneInteractionRuntime` is the *per-panel* (tab) runtime, separate from `paneCloseInteractionRuntime`. Per-panel overlays mount inside `GhosttySurfaceScrollView` via `attachPaneInteraction(...)` (see `Sources/GhosttyTerminalView.swift:7110-7124`). If a per-panel `PaneInteractionOverlayHost` ever stays mounted with `isHidden = false` after its content was dismissed, it would absorb clicks anywhere in its bounds — including the tab bar region above it (the host is sized to the scroll view, but if the pane's tab bar happens to render directly above an unhidden host that's been re-anchored to a different frame, you could see partial absorption).

**How to test:** instrument `PaneInteractionOverlayHost.apply(interaction:)` with a log of `isHidden` transitions and the host's `convert(bounds, to: nil)`. Also assert `runtime.active.isEmpty == hosts.isEmpty` in `PaneCloseOverlayController.synchronize()`. If you see hosts lingering after `runtime.active` is empty, this is the bug.

**Likely fix path:** tighten the runtime → mount lifecycle. The `PaneCloseOverlayController.synchronize()` dictionary cleanup is straightforward, but the per-panel mount in `GhosttyTerminalView` is harder to audit — it never tears down (comment at `Sources/GhosttyTerminalView.swift:7113`).

### H4 — TabItemView equatable bypass interacts with focus/responder routing
`TabItemView` in `Sources/ContentView.swift` uses `Equatable` conformance + `.equatable()` to skip body re-evaluation during typing. The `==` function is hand-written. If a recent change added new state to `TabItemView` (or a parent component) without updating the comparator, SwiftUI may stop updating the X button's hit region after the first render in certain split configurations. Less likely but worth a 30-second check.

**How to test:** verify `TabItemView` `==` includes every property the body reads. Tune up the comparator if anything is missing.

---

## Diagnostic plan (do this first, before changing code)

1. **Reproduce in tagged build.** `./scripts/reload.sh --tag c11-19-investigation`. Build a workspace with at least 4 panes split both horizontally and vertically (matches the operator's screenshot in PR #81 thread). Identify which panes' ×s fail. Log their pane IDs.
2. **Layered hit-test trace.** Temporarily add `NSLog` to:
   - `PaneInteractionOverlayHostView.AnchorView.hitTest(_:)` — log paneId + rect when called.
   - `PaneInteractionOverlayHost.hitTest(_:)` — log paneId + isHidden + frame when called.
   - `WindowTerminalPortal.WindowTerminalHostView.hitTest(_:)` (`Sources/TerminalWindowPortal.swift`) — already heavily instrumented in DEBUG, add a one-shot per click log of the resolved hit.
   - Bonsplit's `SplitToolbarButton` action closure (in `vendor/bonsplit/Sources/Bonsplit/Internal/Views/TabBarView.swift` around line 1004) — log when the closure fires.
3. Click a "bad" pane's ×. Tail `/tmp/c11-debug-c11-19-investigation.sock` debug events (or `console`) and walk the chain: cursor → which `hitTest` returned non-nil → did the button fire? The first link in the chain that returns the wrong view is where to fix.

---

## Automation plan — make this validatable without manual clicks

The operator does not want to manually test. There are two layers to automate.

### Layer A — handler validation (easy)
The pane-close handler logic is testable in isolation. Already covered by:
- `Sources/Panels/PaneInteraction.swift` runtime is unit-testable.
- Existing tests in `tests/PaneInteractionRuntimeTests.swift` (referenced in `GhosttyTabs.xcodeproj/project.pbxproj`).

Add tests for:
- `PaneCloseOverlayController.synchronize()` — assert `hosts.isEmpty` after `runtime.cancelActive(panelId:)`.
- `Workspace.splitTabBar(_:didRequestClosePane:)` only-pane branch — given a stubbed `BonsplitController` with one pane and N tabs, after the user confirms the close, assert all tabs were closed AND a new terminal surface was created.

These run under `xcodebuild -scheme c11-unit` (safe per CLAUDE.md "Testing policy").

### Layer B — UI hit-test validation (the hard part — and what the operator actually wants)
The bug is in click delivery. To validate without manual clicking, you need to drive the OS pointer programmatically. Three viable paths, in order of how I'd recommend them:

**B1 (recommended) — Python socket harness + `cliclick`.** `cliclick` (https://github.com/BlueM/cliclick) is a well-behaved CLI for synthesising real macOS pointer events. Approach:
1. Write a Python script in `tests_v2/test_pane_close_clicks.py` that:
   1. Launches a tagged `c11 DEV` build with a fresh socket path.
   2. Connects via `CMUX_SOCKET=/tmp/c11-debug-<tag>.sock`.
   3. Programmatically builds a complex split layout via existing socket commands (`c11 new-split`, etc. — see `c11 --help` for the full list, also `Sources/SocketControlSettings.swift` and the socket dispatcher in `Sources/AppDelegate.swift`).
   4. Queries pane geometry via `c11 layout-snapshot` (or adds a new `c11 pane-x-frame --pane <id>` command that reads the tab bar's pane-X button screen-coord rect — small Bonsplit shim).
   5. For each pane, invokes `cliclick c:<x>,<y>` at the X button's screen coordinates.
   6. Asserts the confirmation overlay appeared by polling a new `c11 pane-overlay-state` socket query that returns the active interaction IDs (read directly from `paneCloseInteractionRuntime.active`).
   7. Cancels the overlay (Esc) and moves on.
2. Add a CI workflow that runs this against a pre-built tagged binary on the macOS runner.

You'll need two small additions to the c11 socket: (a) a query for a pane's X-button screen rect, (b) a query for the active pane-close runtime entries. Both are pure read-only and ~20 lines of code each. Worth it — once landed, click-routing regressions become impossible to ship.

**B2 — XCTest UI tests.** The c11 codebase has UI test infrastructure (`Sources/UITestRecorder.swift` exists). `XCUIApplication.windows.firstMatch.buttons.matching(...)` can locate accessibility-tagged X buttons by their localised tooltip ("Close Pane"). Less flexible than B1 but stays inside the Apple toolchain. Trigger via `gh workflow run test-e2e.yml` per the c11 CLAUDE.md.

**B3 — Accessibility API directly.** AXUIElement traversal + `AXUIElementPerformAction(button, kAXPressAction)` to click without moving the cursor. Most invasive; least useful here because the bug is specifically about *cursor hit-testing*, which `AXPress` bypasses (you'd never see the regression). Listed for completeness.

**Pick B1.** It exercises the actual hit-test path — exactly the layer the bug lives in — and the Python harness gives you something the operator (and future agents) can re-run without thinking.

---

## Definition of done

- [ ] You can articulate which view in the responder chain currently absorbs clicks on the failing panes (with a log trace to back it up).
- [ ] Fix lands either in c11 (`PaneCloseOverlayController` / `PaneInteractionOverlayHostView`) or in Bonsplit (mounting strategy in `PaneContainerView`) — pushed to the appropriate fork main and submodule pointer bumped if Bonsplit changes.
- [ ] `tests_v2/test_pane_close_clicks.py` (or an existing equivalent you extend) drives the failing layout via socket + `cliclick`, asserts every pane's × triggers the confirmation overlay, and runs green in CI.
- [ ] C11-19 closed with a one-paragraph post-mortem in the ticket: which hypothesis was right, what the fix was, and why the test didn't already catch it.
- [ ] If you confirm H2 (portal layer is the absorber), fold the work into C11-18 and close C11-19 as a duplicate.

---

## Files you will almost certainly touch

- `vendor/bonsplit/Sources/Bonsplit/Internal/Views/PaneContainerView.swift` — the mount point for the host overlay.
- `Sources/Panels/PaneInteractionOverlayHostView.swift` — the SwiftUI/NSViewRepresentable anchor.
- `Sources/Panels/PaneCloseOverlayController.swift` — the AppKit overlay manager.
- `Sources/AppDelegate.swift` (or wherever the socket dispatcher lives) — for the new read-only socket queries.
- `tests_v2/test_pane_close_clicks.py` (new) — the automation harness.

## Files to read but probably not touch

- `Sources/TerminalWindowPortal.swift` — only if you confirm H2; otherwise leave it alone.
- `Sources/GhosttyTerminalView.swift:7100-7150` — the per-panel mount path; reference for the lifecycle pattern, not a target.
- `Sources/Workspace.swift` — `splitTabBar(_:didRequestClosePane:)` is well-tested already; the bug is upstream of it.

## Operating notes

- Per CLAUDE.md: never `open` an untagged `c11 DEV.app`; always build with `./scripts/reload.sh --tag <slug>`. Use `C11_SOCKET=/tmp/c11-debug-<tag>.sock` for socket access.
- Submodule discipline: any Bonsplit fix must be committed and pushed to `Stage-11-Agentics/bonsplit` `main` BEFORE bumping the c11 submodule pointer.
- Don't run tests locally except the safe unit scheme; CI handles e2e per `skills/c11/SKILL.md` and the testing policy.
