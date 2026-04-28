# Flash Extension Plan — Tab strip + Sidebar workspace

Branch: `c11-flash-tab-and-workspace` (off `origin/main`).
Worktree: `/Users/atin/Projects/Stage11/code/c11-worktrees/c11-flash-tab-and-workspace`.

## Confirmed setup notes

- `vendor/bonsplit/` is a **git submodule** (`Stage-11-Agentics/bonsplit`). It was empty in this fresh worktree until `git submodule update --init vendor/bonsplit` ran. Bonsplit changes must follow CLAUDE.md "Submodule safety": commit + push the submodule HEAD to `bonsplit/main` BEFORE committing the parent pointer bump.
- `typealias Tab = Workspace` (`Sources/TabManager.swift:10`). The sidebar's `TabItemView` parameter named `tab: Tab` is a `Workspace`. Adding `@Published var sidebarFlashToken: Int = 0` to `Workspace` is exactly the right hook.
- `PaneState` is `@Observable` (Swift's new observation, not `ObservableObject`). Adding `var flashTabId: UUID?` and `var flashTabGeneration: Int = 0` is sufficient — observation is automatic.
- `BonsplitController.findTabInternal(_:)` at `vendor/bonsplit/Sources/Bonsplit/Public/BonsplitController.swift:822` is the right helper to reuse for the new `flashTab(_:)` API.
- `FocusFlashPattern` lives at `Sources/Panels/Panel.swift:41` and is module-internal — accessible from `ContentView.swift` without re-export.
- `cmuxAccentColor()` at `Sources/ContentView.swift:61` is the host accent color.

## 1. Architecture summary

Single fan-out point stays `Workspace.triggerFocusFlash(panelId:)` (`Sources/Workspace.swift:8918`). Today:

```swift
panels[panelId]?.triggerFlash()       // (a) pane content flash
```

Extend to three channels:

```swift
panels[panelId]?.triggerFlash()                                    // (a) pane content
if let tabId = surfaceIdFromPanelId(panelId) {                     // (b) bonsplit tab
    bonsplitController.flashTab(tabId)
}
sidebarFlashToken &+= 1                                            // (c) sidebar row
```

All four existing trigger paths (keyboard shortcut, right-click "Trigger Flash" via `triggerDebugFlash`, v2 socket `surface.trigger_flash`, notification routing via `triggerNotificationFocusFlash`) collapse onto this one fan-out by changing `triggerNotificationFocusFlash` to call `triggerFocusFlash(panelId:)` instead of `terminalPanel.triggerFlash()` directly.

Per channel:

- **(a) Pane content (unchanged).** Existing `Panel.triggerFlash()` impl: `CAKeyframeAnimation` for terminal, segmented `withAnimation` for SwiftUI panels.
- **(b) Bonsplit tab strip.** New public Bonsplit API `BonsplitController.flashTab(_:)` writes `flashTabId` + `flashTabGeneration` on `PaneState`. `TabBarView`'s `ScrollViewReader` listens via `.onChange(of: pane.flashTabGeneration)` and calls `proxy.scrollTo(flashId, anchor: .center)`. `TabItemView` reads the matching generation and runs a SwiftUI segment animation against a fill overlay.
- **(c) Sidebar row.** `Workspace.sidebarFlashToken` increments. The c11 sidebar `TabItemView` receives the token as a precomputed `let` parameter from the parent `ForEach`, fires `.onChange(of:)`, runs a single-pulse segment animation. The `==` comparator gets one new `Int` field.

Both new flashes are intentionally **non-selecting**.

## 2. Public seam in Bonsplit

Add to `vendor/bonsplit/Sources/Bonsplit/Public/BonsplitController.swift` after `selectTab(_:)` (line 290):

```swift
/// Trigger a transient visual flash on the tab matching `tabId`.
/// Visual-only: does NOT change selection or focus.
/// Composes with the tab strip's existing scroll-into-view machinery.
public func flashTab(_ tabId: TabID) {
    guard let (pane, _) = findTabInternal(tabId) else { return }
    pane.flashTabId = tabId.id
    pane.flashTabGeneration &+= 1
}
```

Add to `vendor/bonsplit/Sources/Bonsplit/Internal/Models/PaneState.swift` near `selectedTabId`:

```swift
/// Last-flashed tab id (visual-only signal, does not affect selection).
var flashTabId: UUID?
/// Monotonic generation that increments on every flash request.
/// Observers key animations off changes to this counter so back-to-back
/// flash calls cleanly restart the animation rather than stacking.
var flashTabGeneration: Int = 0
```

**Why this seam.** Composes with `TabBarView`'s existing `ScrollViewReader` and `proxy.scrollTo(tabId, anchor: .center)` machinery. Same conceptual layer as `selectTab(_:)`, `togglePaneZoom()`, etc. on the public controller. No new delegate calls. Self-contained — generic enough to upstream to `almonk/bonsplit` later.

**Alternative considered:** put the token on `TabItem`. Rejected — `TabItem` is `Codable` and round-trips via drag/drop pasteboards; transient UI flags do not belong there. Pane-keyed approach also lets us flash a non-selected tab without touching `selectedTabId`.

## 3. File-by-file change list

### Bonsplit submodule

1. **`vendor/bonsplit/Sources/Bonsplit/Internal/Models/PaneState.swift`** — add `flashTabId`, `flashTabGeneration` properties (~5 lines).

2. **`vendor/bonsplit/Sources/Bonsplit/Public/BonsplitController.swift`** — add `flashTab(_:)` after `selectTab(_:)` (~8 lines).

3. **`vendor/bonsplit/Sources/Bonsplit/Internal/Views/TabBarView.swift`**
   - Inside `ScrollViewReader { proxy in ... }` block (line 471), add a new `.onChange(of: pane.flashTabGeneration)` after the four existing `scrollToPreferredTarget` change handlers (after line 548):
     ```swift
     .onChange(of: pane.flashTabGeneration) { _, _ in
         guard let flashId = pane.flashTabId else { return }
         withTransaction(Transaction(animation: nil)) {
             proxy.scrollTo(flashId, anchor: .center)
         }
     }
     ```
   - In `tabItem(for:at:)` (around line 677), thread the flash signal:
     ```swift
     TabItemView(
         tab: tab,
         isSelected: pane.selectedTabId == tab.id,
         flashGeneration: (pane.flashTabId == tab.id) ? pane.flashTabGeneration : 0,
         ...
     )
     ```
     Only the matching tab sees a non-zero generation; others stay at 0 and ignore.

4. **`vendor/bonsplit/Sources/Bonsplit/Internal/Views/TabItemView.swift`**
   - Add `let flashGeneration: Int` (default 0).
   - Add `@State private var flashOpacity: Double = 0` and `@State private var lastObservedFlashGen: Int = 0`.
   - Add a fill overlay on the tab background:
     ```swift
     .overlay {
         RoundedRectangle(cornerRadius: tabCornerRadius)
             .fill(appearance.activeIndicatorColor.opacity(flashOpacity))
             .allowsHitTesting(false)
     }
     ```
     Tint with the host's accent (`appearance.activeIndicatorColor` already used for selected-tab styling — keeps Bonsplit standalone).
   - Add `.onChange(of: flashGeneration) { _, newGen in if newGen > lastObservedFlashGen { lastObservedFlashGen = newGen; runFlashAnimation() } }`.
   - Define a Bonsplit-internal `FlashPattern` mirroring `FocusFlashPattern`'s constants verbatim (peak 0.55, two pulses, 0.9s) — keeps Bonsplit self-contained for upstream-friendly diffs.

### c11 sources

5. **`Sources/Workspace.swift`**
   - Add property near other published state: `@Published private(set) var sidebarFlashToken: Int = 0`
   - Modify `triggerFocusFlash(panelId:)` (line 8918):
     ```swift
     func triggerFocusFlash(panelId: UUID) {
         guard NotificationPaneFlashSettings.isEnabled() else { return }
         panels[panelId]?.triggerFlash()                                  // (a)
         if let tabId = surfaceIdFromPanelId(panelId) {                   // (b)
             bonsplitController.flashTab(tabId)
         }
         sidebarFlashToken &+= 1                                          // (c)
     }
     ```
     (Verify `NotificationPaneFlashSettings.isEnabled()` exists; if it's only `@AppStorage`, read `UserDefaults.standard.bool(forKey: NotificationPaneFlashSettings.enabledKey)` directly — see step 9.)
   - Modify `triggerNotificationFocusFlash(panelId:requiresSplit:shouldFocus:)` (line 8922) to delegate through the fan-out:
     ```swift
     // was: terminalPanel.triggerFlash()
     triggerFocusFlash(panelId: panelId)
     ```
   - `triggerDebugFlash(panelId:)` (line 8938) already calls `triggerNotificationFocusFlash`; no change needed.

6. **`Sources/ContentView.swift`** — sidebar `TabItemView` (line 10908)
   - Add `let sidebarFlashToken: Int` to the struct.
   - Add to `==` comparator (line 10911) — **critical, otherwise unrelated parent re-evals replay the animation**:
     ```swift
     lhs.sidebarFlashToken == rhs.sidebarFlashToken &&
     ```
     Update the warning comment block at line 10902 to mention the new field.
   - Add `@State private var lastObservedSidebarFlash: Int = 0` and `@State private var sidebarFlashOpacity: Double = 0`.
   - Add a fill overlay in the row body (sized to the row container, low corner radius matching existing row chrome):
     ```swift
     .overlay {
         RoundedRectangle(cornerRadius: 8)
             .fill(cmuxAccentColor().opacity(sidebarFlashOpacity))
             .allowsHitTesting(false)
     }
     .onChange(of: sidebarFlashToken) { _, newValue in
         guard newValue != lastObservedSidebarFlash else { return }
         lastObservedSidebarFlash = newValue
         runSidebarFlashAnimation()
     }
     ```
   - `runSidebarFlashAnimation()` is a `@MainActor` helper using a single-pulse pattern (see §4) and a generation guard mirroring `MarkdownPanelView.triggerFocusFlashAnimation`.
   - At the parent ForEach call site (line 8453), pass `sidebarFlashToken: tab.sidebarFlashToken` as a constructor parameter. The parent already re-evaluates because `tab` is `@ObservedObject`; updating the field triggers the `==` mismatch and body runs.

7. **No changes to** `Sources/Panels/MarkdownPanelView.swift`, `Sources/Panels/BrowserPanelView.swift`, `Sources/AppDelegate.swift`, `Sources/TabManager.swift`, `Sources/TerminalController.swift`, `Sources/c11App.swift`. They all reach the new fan-out via `triggerFocusFlash`/`triggerNotificationFocusFlash`.

## 4. Animation reuse — exact values

Use `FocusFlashPattern` (`Sources/Panels/Panel.swift:41`) as the c11-side source of truth. Bonsplit gets a self-contained mirror with identical numeric constants so visuals match by construction.

| Channel | Envelope source | Peak opacity | Pulses | Duration |
|---|---|---|---|---|
| (a) Pane content | `FocusFlashPattern` (existing) | 1.0 (stroke at full) | 2 | 0.9s |
| (b) Bonsplit tab fill | mirrored pattern in Bonsplit | 0.55 (accent fill) | 2 | 0.9s |
| (c) Sidebar row fill | new `SidebarFlashPattern` in c11 | 0.18 (accent fill) | **1** | 0.6s |

**Why fill not stroke** for (b) and (c): the pane content stroke is ring-inset by 6pt at 10pt corner radius — fine for a content-area-sized rect with internal padding. The Bonsplit tab strip applies `mask(combinedMask)` (line 552) to fade tabs at the bar's leading/trailing edges. A stroke would clip oddly under the mask; a fill fades naturally with the tab. The sidebar row is similarly small/rounded — a fill reads as "polite glow" instead of "alert ring."

**Sidebar single-pulse pattern (defined adjacent to `FocusFlashPattern` in `Panel.swift` for discoverability):**

```swift
enum SidebarFlashPattern {
    static let values: [Double] = [0, 0.18, 0]
    static let keyTimes: [Double] = [0, 0.5, 1]
    static let duration: TimeInterval = 0.6
    static let curves: [FocusFlashCurve] = [.easeOut, .easeIn]
    static var segments: [FocusFlashSegment] {
        let stepCount = min(curves.count, values.count - 1, keyTimes.count - 1)
        return (0..<stepCount).map { index in
            let startTime = keyTimes[index]
            let endTime = keyTimes[index + 1]
            return FocusFlashSegment(
                delay: startTime * duration,
                duration: (endTime - startTime) * duration,
                targetOpacity: values[index + 1],
                curve: curves[index]
            )
        }
    }
}
```

## 5. Equatability preservation (sidebar `TabItemView`)

The c11 sidebar `TabItemView` is `Equatable` because every `TabManager`/`NotificationStore` publish would otherwise re-evaluate every row's body (~18% of main thread per the in-source comment at line 10902).

**Mechanism — same pattern as the existing `unreadCount`, `latestNotificationText`, `agentChip`, etc.:**

1. `Workspace.sidebarFlashToken` (`@Published`) increments on each fan-out call.
2. The parent `ForEach` at `ContentView.swift:8425` is already re-evaluated whenever any `tab`'s published state changes (because `tab` is `@ObservedObject`).
3. The new ForEach iteration constructs `TabItemView(..., sidebarFlashToken: tab.sidebarFlashToken)`.
4. SwiftUI invokes `==`. The new `lhs.sidebarFlashToken == rhs.sidebarFlashToken` line fails for the targeted row; body runs.
5. Inside the body, `.onChange(of: sidebarFlashToken)` fires once and runs `runSidebarFlashAnimation`.
6. **Other** ForEach iterations (other workspaces) get the same `sidebarFlashToken` they had before; `==` still holds; body skipped. Typing-latency invariant preserved.

**Anti-patterns to avoid** (each would silently break the contract):
- `@ObservedObject` on a separate flash store — every store change touches every row.
- `@EnvironmentObject` — bypasses the `==` short-circuit.
- Closures that capture flash state — closures are excluded from `==`.

The `==` update is one line, but call it out in the patch with a comment because the warning at line 10902 is load-bearing.

## 6. Edge cases

1. **Surface in a closed/hidden pane.** `panels[panelId]` is nil ⇒ (a) no-ops. `surfaceIdFromPanelId(panelId)` returns nil ⇒ (b) no-ops. Workspace still exists ⇒ (c) fires. Correct: "you asked for a flash on something gone, but the workspace highlights so you know where it was."

2. **Non-active tab in pane.** This is the load-bearing new affordance. `proxy.scrollTo(flashId, anchor: .center)` brings the tab into view, the tab pulses, **selection does NOT change**. Operator can click to actually switch.

3. **`notificationPaneFlashEnabled` disabled.** Single guard at top of `triggerFocusFlash` — disables all three channels consistently. Keeps the per-panel internal guards for defense-in-depth (harmless redundancy).

4. **Multiple flashes within animation window.** Generation counters at every layer:
   - Bonsplit `pane.flashTabGeneration` increments → animation in `TabItemView` cleanly restarts via `lastObservedFlashGen` guard.
   - c11 `sidebarFlashToken` increments → `lastObservedSidebarFlash` guard restarts the row animation cleanly.
   - Pane content uses existing `focusFlashAnimationGeneration` machinery.

5. **Workspace switch during animation.** Sidebar row lives in `LazyVStack` outside any per-workspace tree — animation continues through switches. Bonsplit tab strip lives inside the workspace view tree; SwiftUI may throttle offscreen work but resumes on return. Not a correctness issue.

6. **Sidebar scroll-into-view for workspace row.** The sidebar's outer `ScrollView` (line 8418) lacks a `ScrollViewReader`. **Out of scope** for this change — adds complexity, sidebar typically shows all workspaces. Leave as documented follow-up.

## 7. Validation plan

Tagged build + relaunch (per `skills/c11-hotload/SKILL.md`):

```bash
./scripts/reload.sh --tag flash
```

Manual checks (operator must eyeball — no UI automation can validate a 0.9s opacity pulse):

1. **Keyboard shortcut "Flash Focused Pane".** Verify pane ring flashes (existing), top-bar tab flashes with accent tint, sidebar row gets a faint accent pulse. Selection unchanged.
2. **Right-click → Trigger Flash** on a terminal surface. Same expected behavior. Verifies the `triggerNotificationFocusFlash` → `triggerFocusFlash` collapse.
3. **CLI / v2 socket.** `c11 v2 surface.trigger_flash --workspace_ref … --surface_ref …` (or via Python `tests_v2/`). Eyeball the same three flashes. The existing `flash_count` (debug.flash.count) still increments for the pane channel — tests_v2/test_trigger_flash.py should still pass.
4. **Non-active tab in pane.** Split a pane, two tabs, focus a different pane. Trigger flash via v2 with the non-selected tab's surface_id. Tab strip scrolls inactive tab into view, tab pulses, **selection does NOT change**. (Most important new behavior.)
5. **Different workspace.** Trigger flash on a surface in a workspace other than the active one. That workspace's sidebar row pulses; active workspace's row does not.
6. **Setting toggled off.** Settings → Notifications → "Pane Flash" off. Trigger via any path. Nothing visible.
7. **Rapid repeated triggers.** Fire shortcut 5x fast. Animations restart cleanly without stacking — generation guards do their job.

**No new headless tests.** Per CLAUDE.md "Test quality policy", source-text/assertion-only tests are discouraged. The new channels are visual-only; existing pane-flash regression coverage (`tests_v2/test_trigger_flash.py`) suffices.

## 8. Risks

1. **Typing-latency hot path.** Sidebar `TabItemView`'s `==` is load-bearing (CLAUDE.md). The change adds exactly one `Int` comparison and one `Int` parameter. Validation: type rapidly into a focused terminal while flashing repeatedly; if latency degrades, suspect comparator is mis-coded.

2. **Bonsplit submodule push order.** Per CLAUDE.md "Submodule safety": commit + push the submodule HEAD to `bonsplit/main` BEFORE committing the parent pointer bump. Workflow:
   1. In `vendor/bonsplit/`: branch, commit, push to `Stage-11-Agentics/bonsplit` `main` (or PR + merge).
   2. Verify: `cd vendor/bonsplit && git merge-base --is-ancestor HEAD origin/main`.
   3. In c11 root: `git add vendor/bonsplit && git commit -m "..."`.

3. **Upstream-friendly diff.** Keep Bonsplit changes self-contained (~80 LoC), one public API, no host coupling. Standalone enough to PR to `almonk/bonsplit` later as "Add public `flashTab(_:)` for transient tab attention."

4. **Bonsplit tab strip mask.** `mask(combinedMask)` (line 552) fades tabs at edges. Fill overlay (chosen) fades naturally with the tab. Stroke would clip — confirms §4 choice.

5. **Portal layering.** Tab strip lives above pane content in SwiftUI tree, but pane content is portal-hosted by AppKit. Tab strip overlay does not intersect portal layer (tabs sit above panes, not over them). Verify by triggering a flash while a browser surface occupies most of the workspace.

6. **Dead per-panel guards.** Adding the `NotificationPaneFlashSettings.isEnabled()` early-return at fan-out makes the per-panel `triggerFlash` setting checks redundant. Leave them — defense-in-depth, zero cost.

## 9. Open verification before coding

- [ ] Confirm `NotificationPaneFlashSettings` has an `isEnabled()` static method or expose one (otherwise read `UserDefaults.standard.bool(forKey: NotificationPaneFlashSettings.enabledKey)` in `Workspace`).
- [ ] Confirm `appearance.activeIndicatorColor` exists in Bonsplit (sample existing usage in `TabItemView.swift` for selected-tab styling).
- [ ] Confirm sidebar row body has a stable corner-radius / clip shape we can match in the overlay (visually inspect existing `themedSidebarTabColors` background).

## Critical files for implementation

- `Sources/Workspace.swift`
- `Sources/ContentView.swift`
- `Sources/Panels/Panel.swift` (for `SidebarFlashPattern` definition)
- `vendor/bonsplit/Sources/Bonsplit/Public/BonsplitController.swift`
- `vendor/bonsplit/Sources/Bonsplit/Internal/Models/PaneState.swift`
- `vendor/bonsplit/Sources/Bonsplit/Internal/Views/TabBarView.swift`
- `vendor/bonsplit/Sources/Bonsplit/Internal/Views/TabItemView.swift`
