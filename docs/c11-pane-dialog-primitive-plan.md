# c11 — Pane Interaction Primitive Plan

**Date**: 2026-04-18
**Status**: Draft v2 — revised post-Trident plan review (see `docs/c11mux-pane-dialog-primitive-plan-review-pack-2026-04-18T1408/`)
**Target branch**: feature branch off `main` (e.g. `m10-pane-interaction`), worked in a git worktree

## Revision history

- **v1 (2026-04-18)** — Initial draft. Captured the design dialogue: scope limited to single-tab / single-surface close; card-over-pane; pane-local modality; per-pane FIFO queue; panel-anchored; confirm-only, textInput API-reserved.
- **v3 (2026-04-18)** — Locked in 7 open questions (per-panel queue cap = 4; M10 module number; debug-only telemetry; `cmux pane confirm` CLI; validate scrim against brand in Phase 2; honor existing socket ACL; **bundle rename**). Material scope change: `.textInput` variant is now day-one, not reserved. Rename-tab, rename-workspace, and custom-color NSAlerts convert in the same PR. Move-tab stays on NSAlert (picker-style, not text input). Queue cap dropped from 8 to 4 per user decision.
- **v2 (2026-04-18)** — Post-Trident-review rewrite. 7 reviews landed (Gemini Standard and Evolutionary failed on `gemini-3-pro-preview` capacity; Adversarial got through). Unanimous adversarial verdict: v1 not ready. Material changes:
  1. **Primary seam corrected.** v1 targeted `TabManager.confirmClose` only; the user-facing close dialog actually flows through `Workspace.confirmClosePanel(for:)` (`Sources/Workspace.swift:8931-8958`, called from the bonsplit `shouldCloseTab` delegate at `9321-9394`). v2 treats that as the primary target, with `TabManager.confirmClose` and the Ghostty `close_surface_cb` path as sibling consumers.
  2. **Layer flipped for terminals (and WebView-backed browsers).** `CLAUDE.md:143` says overlays above the terminal must mount from `GhosttySurfaceScrollView` (AppKit portal), not from SwiftUI panel containers. v1 violated this. v2 hosts the terminal and WebView-backed-browser overlays in the AppKit portal; SwiftUI-only mount is used for markdown panels and for the empty-new-tab browser state where no portal is present.
  3. **Primitive widened from `PaneDialog` to `PaneInteraction`.** Both evolutionary reviews (Claude + Codex) independently flagged this as a one-way door. v2 keeps a tight day-one API but sizes the enum and presenter so non-modal banners, progress, and multi-step flows fit without a rewrite.
  4. **Presenter ownership moved off the `Panel` protocol** into a workspace-scoped `PaneInteractionRuntime` keyed by `panelId`. This removes the need for every conformer (including `MarkdownPanel`, which v1 missed — see `Sources/Panels/MarkdownPanel.swift:21`) to hold new state, and naturally handles lifecycle + multi-window cases.
  5. **Cmd+D and `NSApp.modalWindow` preserved.** v1 silently broke both. v2 adds a `TabManager.hasActivePaneInteraction` signal, updates `AppDelegate.swift:9054` and the Cmd+D dispatcher at `9018-9051` to detect pane-hosted dialogs, and routes Cmd+D accept through the runtime.
  6. **`notificationStore.clearNotifications` preserved.** v1's §4.6 rewrite dropped this side effect at `TabManager.swift:2490`. v2 keeps it.
  7. **Socket addressability included day one** per user decision. Agents can trigger `pane.confirm` on a specific panel UUID — turns c11 into the pane-scoped agent-consent substrate no other multiplexer offers.
  8. **Styling contradiction resolved.** v1 simultaneously said gold-accent (§3.3) and destructive red (§8 Q4). v2 uses the system destructive red with a gold focus ring.
  9. **9-callsite audit list corrected.** v1 listed 9 callsites; 5 were calls to functions that stay on NSAlert. v2 enumerates the actual in-scope surface.
  10. **Feature flag + rollback path added.** `cmux.paneDialogEnabled` UserDefaults key (DEBUG/CI toggle); fallback to NSAlert when disabled.

---

## 1. Summary

Replace c11's two app-level `NSAlert`-based close confirmations with a **pane-scoped interaction primitive** — a card hosted *inside* the specific panel the prompt belongs to, with a scrim bounded to that panel's bounds. Build it as a general-purpose pane-interaction substrate, not a one-off dialog: day-one callers are close-confirmation and socket-triggered agent consent; rename-tab / rename-workspace land in a short follow-up PR; banners, progress, and undo are API-accommodated.

**Why the rewrite from v1.** v1 was not code-walked — factual-error count across the adversarial reviews was ten. Most consequentially, v1 refactored the wrong seam: the primary dialog the user sees comes from `Workspace.confirmClosePanel` (the bonsplit ✕ path), not `TabManager.confirmClose`. v2 rebuilds against the actual code layout.

**Out of scope (still on NSAlert):**
- Bulk multi-workspace close (`Cmd+Shift+W` with sidebar multi-select). No single panel to anchor on.
- "Close other tabs in this pane." Ambiguous target.
- Move-tab NSAlert (`Workspace.swift:8796`). Picker-style — destination selector — not text input. Belongs to a future `.picker` variant, not this PR.
- Settings-sheet `.confirmationDialog` / `.alert` in `cmuxApp.swift` (already panel-contextual).

---

## 2. What the feature is

### User-facing behavior

- **Triggers (day one):**
  - **Bonsplit ✕ / `Cmd+W` tab close** → `Workspace.splitTabBar(_:shouldCloseTab:inPane:)` at `Sources/Workspace.swift:9321` calls `confirmClosePanel(for:)` when `panelNeedsConfirmClose` returns true.
  - **Ghostty `close_surface_cb` with `needs_confirm = true`** → `TabManager.closeRuntimeSurfaceWithConfirmation(tabId:surfaceId:)` at `TabManager.swift:2476`, invoked from `GhosttyTerminalView.swift:1129`.
  - **`closeCurrentWorkspaceWithConfirmation` → `closeWorkspaceIfRunningProcess`** at `TabManager.swift:2394` (workspace close when the focused panel has a running process).
  - **`pane.confirm` socket command** (new) — any local agent with socket access can trigger a pane dialog on a specific panel UUID.

- **Appearance.** Rounded card (12pt radius) centered in the panel bounds. Scrim (`Color.black.opacity(0.55)`) covers only the panel rect. Tab bar, sidebar, other splits, and other windows unaffected.
- **Card contents.** Title, optional message, one or two buttons. Default button uses the system `.destructive` role (red tint for close-confirmations) with a BrandColor gold focus ring.
- **Keyboard.** Card grabs first responder while visible: `Return` accepts, `Escape` cancels, `Tab` / `Shift+Tab` cycle buttons. `Cmd+D` accepts (preserves the existing XCUITest-level contract — see §4.7). Terminal/browser key input to the affected panel is suppressed; other panels are unaffected.
- **Dismissal.** Only the buttons (or `Esc`, `Return`, `Cmd+D`) dismiss. Scrim click does NOT dismiss — prevents accidental cancel.
- **Concurrency.** FIFO queue per panel. A second trigger on the same panel queues. Triggers on different panels show concurrently.
- **Acceptance-time revalidation.** When the user accepts, the caller re-checks preconditions (panel still exists, still needs confirm, workspace still present). If state drifted during the prompt, the action is skipped silently. This is explicit in v2 because the flip from `runModal` (synchronous) to `async` opens a window where state can change.

### Day-one consumers

1. **Close-confirmation** (`.confirm` variant) — three trigger paths above.
2. **Rename / custom-color** (`.textInput` variant) — three callsites convert in this PR:
   - **Rename Tab** — `Sources/Workspace.swift:8751` (NSAlert with text accessory view). Anchored on the panel being renamed.
   - **Rename Workspace** — `Sources/ContentView.swift:12009` (`promptRename()`). Anchored on the workspace's focused panel.
   - **Custom Color** — `Sources/ContentView.swift:11966` (`promptCustomColor(targetIds:)`; validates `#RRGGBB`). Anchored on the focused panel of the first target workspace.
3. **Socket-triggered confirmation** (`.confirm` via socket) — `cmux pane confirm --panel <uuid> --title "..." --message "..." [--destructive]`. Exit 0 on accept, non-zero on cancel / dismissed / error.

### What does NOT exist day one (but the primitive accommodates it)

- `.picker` variant — move-tab (`Sources/Workspace.swift:8796`) would use this. Reserved for a later PR.
- `.banner` / `.progress` non-modal variants — no immediate consumer; the `modality` attribute is present in the enum so these slot in.
- Socket-triggered `.textInput` — add once the shape has shaken out locally.
- Multi-step flows. The presenter's `present(_:)` already handles queueing.

---

## 3. Architecture

### 3.1 Model — new file `Sources/Panels/PaneInteraction.swift`

```swift
import Foundation
import SwiftUI

public enum PaneInteraction: Identifiable {
    case confirm(ConfirmContent)
    case textInput(TextInputContent)

    // Reserved (not wired day one):
    // case picker(PickerContent)
    // case banner(BannerContent)

    public var id: UUID {
        switch self {
        case .confirm(let c): return c.id
        case .textInput(let t): return t.id
        }
    }

    public var modality: Modality {
        switch self {
        case .confirm, .textInput: return .modal
        }
    }

    public enum Modality {
        case modal        // Scrim + focus capture + key suppression on the target panel.
        case nonModal     // Reserved for future banners/toasts; no scrim, no focus capture.
    }
}

public struct ConfirmContent: Identifiable {
    public let id = UUID()
    public let title: String
    public let message: String?
    public let confirmLabel: String
    public let cancelLabel: String
    public let role: ConfirmRole
    public let source: InteractionSource
    public let completion: (ConfirmResult) -> Void

    public enum ConfirmRole { case standard, destructive }
}

public struct TextInputContent: Identifiable {
    public let id = UUID()
    public let title: String
    public let message: String?
    public let placeholder: String?
    public let defaultValue: String
    public let confirmLabel: String
    public let cancelLabel: String
    /// Return nil if the value is valid, or a localized error to show inline.
    public let validate: (String) -> String?
    public let source: InteractionSource
    public let completion: (TextInputResult) -> Void
}

public enum ConfirmResult {
    case confirmed
    case cancelled
    case dismissed   // Panel closed, workspace closed, or clear() called. Distinguished from user cancel.
}

public enum TextInputResult {
    case submitted(String)
    case cancelled
    case dismissed
}

public enum InteractionSource {
    case local                       // Triggered by in-app code.
    case socket(clientId: String)    // Triggered by a socket command (not wired for textInput day one).
}
```

### 3.2 Presenter — workspace-scoped, not panel-scoped

```swift
@MainActor
final class PaneInteractionRuntime: ObservableObject {
    /// All currently-presented interactions, keyed by panelId. Each panel has its own FIFO queue.
    @Published private(set) var active: [UUID: PaneInteraction] = [:]
    private var queues: [UUID: [PaneInteraction]] = [:]

    /// Dedupe token — callers can pass a stable key to collapse duplicate presents
    /// (e.g., Ghostty's close_surface_cb that can fire twice in rapid succession).
    private var seenTokens: [UUID: Set<String>] = [:]

    func present(panelId: UUID, interaction: PaneInteraction, dedupeToken: String? = nil) {
        if let token = dedupeToken {
            var tokens = seenTokens[panelId, default: []]
            guard !tokens.contains(token) else { return }
            tokens.insert(token)
            seenTokens[panelId] = tokens
        }
        if active[panelId] == nil {
            active[panelId] = interaction
        } else {
            queues[panelId, default: []].append(interaction)
        }
    }

    /// Typed resolver for confirm interactions.
    func resolveConfirm(panelId: UUID, result: ConfirmResult) {
        guard case .confirm(let c)? = active[panelId] else { return }
        c.completion(result)
        advance(panelId: panelId)
    }

    /// Typed resolver for text-input interactions.
    func resolveTextInput(panelId: UUID, result: TextInputResult) {
        guard case .textInput(let t)? = active[panelId] else { return }
        t.completion(result)
        advance(panelId: panelId)
    }

    /// Generic cancel (Esc / scrim-dismiss-equivalent path for either variant).
    func cancelActive(panelId: UUID) {
        guard let interaction = active[panelId] else { return }
        switch interaction {
        case .confirm(let c): c.completion(.cancelled)
        case .textInput(let t): t.completion(.cancelled)
        }
        advance(panelId: panelId)
    }

    private func advance(panelId: UUID) {
        if var queue = queues[panelId], !queue.isEmpty {
            active[panelId] = queue.removeFirst()
            queues[panelId] = queue
        } else {
            active[panelId] = nil
            queues[panelId] = nil
        }
    }

    func hasActive(panelId: UUID) -> Bool { active[panelId] != nil }
    var hasAnyActive: Bool { !active.isEmpty }
    var activePanelIds: Set<UUID> { Set(active.keys) }

    /// Called when a panel closes or the workspace tears down. Resolves all pending with .dismissed.
    func clear(panelId: UUID) {
        while let interaction = active[panelId] {
            switch interaction {
            case .confirm(let c): c.completion(.dismissed)
            case .textInput(let t): t.completion(.dismissed)
            }
            if var queue = queues[panelId], !queue.isEmpty {
                active[panelId] = queue.removeFirst()
                queues[panelId] = queue
            } else {
                active[panelId] = nil
                queues[panelId] = nil
            }
        }
        seenTokens[panelId] = nil
    }

    /// Soft cap per-panel queue depth (per user decision, v3). Overflow drops the OLDEST pending
    /// (not the active) with .dismissed. 4 queued dialogs on one panel is already absurd.
    static let perPanelQueueSoftCap = 4
}
```

**Ownership.** One `PaneInteractionRuntime` per `Workspace` (stored on `Workspace`). This sidesteps the "every `Panel` conformer needs a new property" problem — `MarkdownPanel`, any future panel type, and multi-window cases work without protocol changes. The runtime is observable from any view by passing it down, or by looking it up via `workspace.paneInteractionRuntime`.

**Lifecycle hooks:**
- `Workspace.closePanel(_:force:)` — call `paneInteractionRuntime.clear(panelId:)` before tearing down the panel.
- `Workspace.deinit` or workspace-close path — iterate and clear all active.
- Panel view unmount — call `resolve(panelId:, .dismissed)` IF the panel is being destroyed (not just bonsplit reparenting — that's why `clear` is on the close path, not the view side).

### 3.3 Overlay views — mount-layer depends on panel type

Per `CLAUDE.md:143`, overlays above the Ghostty portal must be hosted in AppKit (from `GhosttySurfaceScrollView`), not in the SwiftUI panel container. Similarly, `BrowserPanelView.swift:445-456` documents that WebView-backed browser content is AppKit portal-hosted, so a SwiftUI overlay there is hidden beneath the portal.

| Panel type | Host layer | File |
|---|---|---|
| `TerminalPanel` | AppKit — mounted inside `GhosttySurfaceScrollView` as a child NSView wrapping `NSHostingView<PaneInteractionCardView>` | `Sources/GhosttyTerminalView.swift` |
| `BrowserPanel` (WebView-backed) | AppKit — mounted by `WindowBrowserPortal` alongside the WKWebView | `Sources/Panels/BrowserPanel.swift` / `BrowserPanelView.swift` |
| `BrowserPanel` (empty new-tab state, `!shouldRenderWebView`) | SwiftUI — ZStack overlay in `BrowserPanelView` | `Sources/Panels/BrowserPanelView.swift` |
| `MarkdownPanel` | SwiftUI — ZStack overlay in `MarkdownPanelView` | `Sources/Panels/MarkdownPanelView.swift` |

This is not a v1-style "fallback" — this IS the architecture. The SwiftUI ZStack path is for panels that don't use the AppKit portal at all (markdown, empty browser). Shared rendering lives in `PaneInteractionCardView` (a SwiftUI view); the per-host difference is only the mount point.

**`PaneInteractionCardView` (SwiftUI, shared):**
- `ZStack` with scrim (`Color.black.opacity(0.55)`) + card.
- Card: rounded rect, void-palette background, 24pt padding, min-width 260pt, max-width 420pt.
- Title, optional message, HStack of buttons (Cancel trailing-left, Confirm trailing-right). Confirm uses `.destructive` role (system red) with a gold focus ring via `.focusable(true)` + custom overlay.
- `.focusable(true)` with an internal `@FocusState` anchor — grabs first responder on appear.
- `.onKeyPress(.return) { .handled }` + local IME-safe handling, same for `.escape`.
- `.accessibilityAddTraits(.isModal)` and `.accessibilityElement(children: .contain)`.

**Keyboard suppression.** `.allowsHitTesting(false)` on the underlying panel content blocks mouse only. For keyboard:
- **Terminal:** the AppKit overlay view returns `true` from `acceptsFirstResponder` and becomes first responder when mounted; Ghostty key routing stops because the surface view is no longer first responder. The focus-restore choke point in §4.7 enforces this invariant.
- **Browser (WebView):** same — AppKit overlay steals first responder, so WKWebView doesn't receive keyDown.
- **Markdown:** the SwiftUI ZStack overlay takes focus; no competing input routing.

### 3.4 TabManager / Workspace surface

**New on `Workspace`:**
```swift
let paneInteractionRuntime: PaneInteractionRuntime

/// Replaces confirmClosePanel(for:) — same shape, routes through the runtime.
@MainActor
func confirmClosePanel(for tabId: TabID) async -> Bool
```

Implementation shape:
```swift
private func confirmClosePanel(for tabId: TabID) async -> Bool {
    guard let panelId = panelIdFromSurfaceId(tabId) else { return false }
    return await presentConfirmClose(
        panelId: panelId,
        title: String(localized: "dialog.closeTab.title", ...),
        message: String(localized: "dialog.closeTab.message", ...),
        source: .local
    )
}

@MainActor
private func presentConfirmClose(
    panelId: UUID,
    title: String,
    message: String,
    source: InteractionSource,
    dedupeToken: String? = nil
) async -> Bool {
    await withCheckedContinuation { cont in
        let content = ConfirmContent(
            title: title,
            message: message.isEmpty ? nil : message,
            confirmLabel: String(localized: "dialog.pane.confirm.close", defaultValue: "Close"),
            cancelLabel: String(localized: "dialog.pane.confirm.cancel", defaultValue: "Cancel"),
            role: .destructive,
            source: source,
            completion: { result in
                cont.resume(returning: result == .confirmed)
            }
        )
        paneInteractionRuntime.present(
            panelId: panelId,
            interaction: .confirm(content),
            dedupeToken: dedupeToken
        )
    }
}
```

**New on `TabManager`:**
```swift
/// Any pane-scoped interaction is currently visible across any workspace.
/// Used by AppDelegate to gate app-level shortcuts (see §4.7).
var hasActivePaneInteraction: Bool {
    tabs.contains { $0.paneInteractionRuntime.hasAnyActive }
}

/// Confirm-accept for the topmost pane interaction in the focused workspace (Cmd+D path).
/// Returns true if an interaction was found and accepted.
@discardableResult
func acceptActivePaneInteractionInKeyWorkspace() -> Bool
```

**Rewriting `TabManager.closeRuntimeSurfaceWithConfirmation`:**
```swift
func closeRuntimeSurfaceWithConfirmation(tabId: UUID, surfaceId: UUID) {
    guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
    guard tab.panels[surfaceId] != nil else { return }

    let needsConfirm = tab.terminalPanel(for: surfaceId).map { terminalPanel in
        tab.panelNeedsConfirmClose(panelId: surfaceId,
                                   fallbackNeedsConfirmClose: terminalPanel.needsConfirmClose())
    } ?? false

    guard needsConfirm else {
        performClosePanel(tab: tab, surfaceId: surfaceId)
        return
    }

    Task { @MainActor in
        let accepted = await tab.presentConfirmClose(
            panelId: surfaceId,
            title: String(localized: "dialog.closeTab.title", defaultValue: "Close tab?"),
            message: String(localized: "dialog.closeTab.message",
                            defaultValue: "This will close the current tab."),
            source: .local,
            dedupeToken: "ghostty.close_surface_cb.\(surfaceId)"
        )
        guard accepted else { return }
        // Acceptance-time revalidation:
        guard let tab = self.tabs.first(where: { $0.id == tabId }),
              tab.panels[surfaceId] != nil else { return }
        performClosePanel(tab: tab, surfaceId: surfaceId)
    }
}

@MainActor
private func performClosePanel(tab: Workspace, surfaceId: UUID) {
    _ = tab.closePanel(surfaceId, force: true)
    AppDelegate.shared?.notificationStore?.clearNotifications(forTabId: tab.id, surfaceId: surfaceId)
}
```

The `dedupeToken` guards against Ghostty firing `close_surface_cb` twice during a close race (documented hazard — `probeCloseSurfaceNeedsConfirm` metadata exists for observability).

**Rewriting `TabManager.closeWorkspaceIfRunningProcess`** uses the same pattern, with the workspace's `focusedPanelId` as the anchor and an NSAlert fallback when no focused panel is resolvable.

**`TabManager.confirmClose` stays** for `closeOtherTabsInFocusedPaneWithConfirmation` and `closeWorkspacesWithConfirmation` — unchanged, uses NSAlert.

### 3.5 Routing diagram

```
Trigger                                            Anchor           Runtime call
-------------------------------------------        -------          ---------------------------------
Bonsplit ✕ / Cmd+W on tab                          panelId from     Workspace.confirmClosePanel(for:)
  → Workspace.shouldCloseTab                       tabId            → runtime.present on that Workspace
  → Workspace.confirmClosePanel(for:)                                  NEW: was NSAlert sheet

Ghostty close_surface_cb (needs_confirm=true)      surfaceId        TabManager.closeRuntimeSurface…
  → TabManager.closeRuntimeSurfaceWithConfirmation                   → workspace.presentConfirmClose
                                                                     with dedupe token

Cmd+W on workspace (last surface)                  ws.focused-      TabManager.closeCurrent…
  → TabManager.closeWorkspaceIfRunningProcess      PanelId          → workspace.presentConfirmClose
                                                   (or NSAlert
                                                    fallback)

pane.confirm socket command (new)                  panelId arg      TerminalController dispatch
                                                                    → workspace.presentConfirmClose
                                                                    source: .socket(clientId)

Rename Tab context menu                            panelId          Workspace.promptRenameTab(panelId:)
  (Workspace.swift:8751 → .textInput)                                → runtime.present

Rename Workspace / commandPalette / menu           workspace's      ContentView.promptRename()
  (ContentView.swift:12009 → .textInput)           focusedPanelId   → runtime.present

Custom Color context menu / palette                workspace's      ContentView.promptCustomColor
  (ContentView.swift:11966 → .textInput)           focusedPanelId   → runtime.present (with #RRGGBB
                                                                       validator)

closeWorkspacesWithConfirmation (bulk)             n/a              TabManager.confirmClose (NSAlert)
closeOtherTabsInFocusedPaneWithConfirmation        n/a              TabManager.confirmClose (NSAlert)
Move Tab picker (Workspace.swift:8796)             n/a              NSAlert (out of scope)
```

### 3.6 Socket command: `pane.confirm`

Added to the socket dispatcher alongside the existing `surface.focus`, `workspace.select`, etc. (lives in `Sources/TerminalController.swift` — `case "surface.focus":` at line 2109 is the pattern).

**Wire format (matches existing commands):**
```
pane.confirm panel=<uuid> title=<urlencoded> [message=<urlencoded>] [role=destructive|standard] [timeout=<seconds>]
```

**Response:**
- `ok` on accept
- `cancel` on user cancel
- `dismissed` on timeout or panel closure
- `error <reason>` on bad args or unknown panel

**Threading.** Per `CLAUDE.md`'s socket threading policy: argument parsing happens off-main; the `DispatchQueue.main.async { presentConfirmClose(...) }` is the only main-thread hop, triggered after validation. This command IS focus-steering in a sense (it shows UI in a specific panel) so per the focus-policy section of CLAUDE.md it's an explicit focus-intent command — OK to mutate pane state.

**ACL (day-one shape, minimal):** honor the existing cmux socket access controls (same as `surface.focus` etc.). No new ACL plumbing. Include the `clientId` in the `InteractionSource` for future audit/ACL work.

**CLI wrapper** (c11d side, follow-up commit in the same PR): `c11 pane confirm --panel <uuid> --title ... [--message ...] [--destructive] [--timeout 30]`. Exit codes map to the response.

**Tests:** a Python integration test in `tests_v2/` (or the Swift-side equivalent) exercises:
1. `pane.confirm` on a known panel → overlay appears → accept → `ok` returned.
2. Invalid panel UUID → `error unknown_panel`.
3. Timeout → `dismissed`.

### 3.7 Feature flag

`UserDefaults` key `cmux.paneDialog.enabled` (default `true` in release, env-var override `CMUX_PANE_DIALOG_DISABLED=1` for UI tests / rollback). When disabled, all routes fall back to the pre-v2 NSAlert path. Reviewed as a rollback story — if the feature regresses somehow, flip the default to `false` in a point release; code paths stay.

---

## 4. Integration surface — per-file plan

### 4.1 New files

| File | Purpose |
|---|---|
| `Sources/Panels/PaneInteraction.swift` | `PaneInteraction` enum, `ConfirmContent`, `ConfirmResult`, `InteractionSource`, `PaneInteractionRuntime`. |
| `Sources/Panels/PaneInteractionCardView.swift` | SwiftUI card + scrim used by all mount layers. |
| `Sources/Panels/PaneInteractionOverlayHost.swift` | AppKit NSView wrapper (`NSHostingView<PaneInteractionCardView>` + acceptsFirstResponder = true). Used by the terminal and WebView-backed-browser mount paths. |
| `cmuxTests/PaneInteractionRuntimeTests.swift` | Unit tests: present, resolve, queue, clear, dedupe token, result-type distinction (cancelled vs dismissed). |
| `tests_v2/test_pane_confirm_socket.py` (or Swift equivalent) | Integration test for `pane.confirm` socket command. |

### 4.2 `Sources/Panels/Panel.swift`

**No new protocol requirements.** State lives on `Workspace`, not on `Panel`. This is the key architectural correction from v1.

### 4.3 `Sources/Workspace.swift`

- Add stored property: `let paneInteractionRuntime = PaneInteractionRuntime()`.
- Rewrite `confirmClosePanel(for:)` at `:8931` to route through the runtime (see §3.4 snippet).
- Keep the `pendingCloseConfirmTabIds` / `forceCloseTabIds` state machine at `:9376-9394` — it orchestrates bonsplit's "close the tab after async confirmation" dance and is orthogonal to how the confirmation is rendered.
- In `closePanel(_:force:)`, call `paneInteractionRuntime.clear(panelId:)` before the tear-down.

**c11 risk**: medium. The `pendingCloseConfirmTabIds` mechanism depends on `confirmClosePanel` resolving (either via the sheet callback or now the runtime callback). The `defer { pendingCloseConfirmTabIds.remove(tabId) }` at `:9385` keeps working because `confirmClosePanel` still returns before the next runloop iteration — just via continuation instead of sheet.

### 4.4 `Sources/TabManager.swift`

- `confirmClose(title:message:acceptCmdD:)` at `:2257` unchanged (still used by bulk paths).
- `closeRuntimeSurfaceWithConfirmation` at `:2476` rewritten per §3.4 snippet (preserves `notificationStore.clearNotifications` at `:2490`).
- `closeWorkspaceIfRunningProcess` at `:2394` rewritten analogously; NSAlert fallback when `focusedPanelId` is nil.
- Add `var hasActivePaneInteraction: Bool` and `func acceptActivePaneInteractionInKeyWorkspace() -> Bool`.

**c11 risk**: medium. The sync→async flip for two callers (`closeRuntimeSurfaceWithConfirmation`, `closeWorkspaceIfRunningProcess`) is a real behavioral change. See §4.9 for the corrected callsite audit.

### 4.5 `Sources/GhosttyTerminalView.swift` — AppKit overlay mount

This is the v2 architectural pivot. Per `CLAUDE.md:143`, the overlay is hosted inside `GhosttySurfaceScrollView`, NOT in `TerminalPanelView`.

- Add a child `PaneInteractionOverlayHost` NSView to `GhosttySurfaceScrollView`, positioned to fill the surface bounds.
- Subscribe to `workspace.paneInteractionRuntime.$active` (via Combine) to show/hide + update content.
- The overlay's `acceptsFirstResponder = true` and `becomeFirstResponder` is called when `active[panelId] != nil`. This suppresses terminal key routing (the Ghostty surface view is no longer first responder).
- `forceRefresh()` is NOT touched — per `CLAUDE.md:142` this is a typing-latency hot path.
- The `TerminalSurface.close_surface_cb` handler at `:1104-1129` passes a stable `dedupeToken` (`"ghostty.close_surface_cb.\(surfaceId)"`) so duplicate fires collapse.

**c11 risk**: medium-high. This file has the typing-latency contract and the focus-restore constellation. Need strict discipline about what runs on key paths.

### 4.6 `Sources/Panels/TerminalPanelView.swift`

**Unchanged in v2.** The overlay is not mounted from this SwiftUI view. Revert the v1 plan's ZStack wrap.

### 4.7 Focus-restore choke point (`Sources/GhosttyTerminalView.swift`)

v1 said "grep every `makeFirstResponder` callsite and add a guard." v2 rejects that — too fragile. Instead:

- Add a single choke point: `TerminalSurface.requestFirstResponder()` or `GhosttySurfaceScrollView.safeMakeTerminalFirstResponder()`.
- All existing callers (`reassertTerminalSurfaceFocus`, `scheduleAutomaticFirstResponderApply`, etc.) route through it.
- The choke point checks the workspace's `paneInteractionRuntime.hasActive(panelId:)` before granting focus.

Grep + refactor pass lists the call sites; the pass is mechanical but the discipline is enforced at one gate.

**c11 risk**: medium. Same constellation as v1 but with a single correct pattern.

### 4.8 `Sources/AppDelegate.swift` — Cmd+D + modalWindow gate

Two edits to preserve load-bearing behavior v1 broke:

**Edit 1 — Cmd+D dispatcher at `:9018-9051`.** Extend the NSPanel-based close-confirmation detector to also detect an active pane interaction. `TabManager` is the source of truth — AppDelegate already has it in scope via `tabManager` (used at `:9506-9558` etc.):

```swift
// Existing NSPanel detector kept for the NSAlert-fallback paths
let closeConfirmationPanel = NSApp.windows.compactMap { $0 as? NSPanel }.first { ... }

// New: any workspace in the current TabManager has an active pane interaction
let hasPaneInteraction = tabManager?.hasActivePaneInteraction ?? false

if matchShortcut(event: event, shortcut: StoredShortcut(key: "d", command: true, ...)) {
    if let closeConfirmationPanel, let closeButton = ... {
        closeButton.performClick(nil); return true
    }
    if hasPaneInteraction,
       tabManager?.acceptActivePaneInteractionInKeyWorkspace() == true {
        return true
    }
}

if closeConfirmationPanel != nil || hasPaneInteraction { return false }
```

`acceptActivePaneInteractionInKeyWorkspace` resolves the active interaction in the workspace that owns the current key window (use `NSApp.keyWindow` → look up owning `TabManager`'s focused `Workspace` → call `paneInteractionRuntime.resolve(panelId:, result: .confirmed)` for the topmost active panel). Implementation detail for the PR; the API shape is stable.

**Edit 2 — `NSApp.modalWindow` gate at `:9054`.**
```swift
if NSApp.modalWindow != nil
   || NSApp.keyWindow?.attachedSheet != nil
   || tabManager?.hasActivePaneInteraction == true {
    return false
}
```

This preserves the existing `CloseWorkspaceCmdDUITests` assertion and the dozens of shortcuts that depend on the modal gate.

**c11 risk**: medium. AppDelegate shortcut routing is guarded by `AppDelegateShortcutRoutingTests`. The new branches need assertions in that suite.

### 4.9 Callsite audit (corrected)

v1's list was mostly wrong. The actual in-scope refactor surface:

| Callsite | Function called | In-scope? | Change |
|---|---|---|---|
| `Workspace.swift:9390` | `Workspace.confirmClosePanel(for:)` | **Yes (primary)** | Route through runtime |
| `GhosttyTerminalView.swift:1129` | `TabManager.closeRuntimeSurfaceWithConfirmation` | **Yes** | Sync→async refactor inside the function |
| `TabManager.swift:2213` | `closeWorkspaceIfRunningProcess` (internal) | **Yes** | Sync→async refactor inside the function |
| `TabManager.swift:2243` | `closeWorkspaceIfRunningProcess(requiresConfirmation: false)` | No (no confirmation) | unchanged |
| `ContentView.swift:5694` | `closeCurrentWorkspaceWithConfirmation` | No | unchanged — internal call goes to `closeWorkspaceIfRunningProcess` or bulk path |
| `cmuxApp.swift:1163` | `closeCurrentWorkspaceWithConfirmation` | No | unchanged — same reason |
| `AppDelegate.swift:9558` | `closeCurrentWorkspaceWithConfirmation` | No | unchanged — same reason |
| `ContentView.swift:6863` / `11536`, `cmuxApp.swift:1055` | `closeWorkspacesWithConfirmation` | No | unchanged (bulk, NSAlert) |
| `cmuxApp.swift:1215`, `AppDelegate.swift:9506/9508` | `closeOtherTabsInFocusedPaneWithConfirmation` | No | unchanged (NSAlert) |

Net real behavioral change: **3 functions** internally (`Workspace.confirmClosePanel`, `TabManager.closeRuntimeSurfaceWithConfirmation`, `TabManager.closeWorkspaceIfRunningProcess`). All their external callsites are fire-and-forget menu actions — no callers read post-close state synchronously.

### 4.10 `Sources/Panels/BrowserPanelView.swift` / `BrowserPanel.swift`

For WebView-backed browsers, mount the overlay from the AppKit side (`WindowBrowserPortal` or the equivalent portal host), not from SwiftUI. For the empty-new-tab state (`!shouldRenderWebView`), mount a SwiftUI ZStack overlay in `BrowserPanelView` — analogous to how `BrowserSearchOverlay` is gated in that file (`:457-`).

**c11 risk**: medium. Needs the browser portal host to get the overlay mount; need to verify layering against the search overlay that lives in the same portal.

### 4.11 `Sources/Panels/MarkdownPanelView.swift`

SwiftUI ZStack overlay — simplest case, no portal involved.

### 4.12 Rename / custom-color conversions (v3 bundle)

Three NSAlerts convert to `.textInput` pane interactions. All share the same helper:

```swift
@MainActor
private func presentTextInput(
    panelId: UUID,
    title: String,
    message: String?,
    defaultValue: String,
    placeholder: String?,
    validate: @escaping (String) -> String?,
    source: InteractionSource = .local
) async -> String? {
    await withCheckedContinuation { cont in
        let content = TextInputContent(
            title: title,
            message: message,
            placeholder: placeholder,
            defaultValue: defaultValue,
            confirmLabel: String(localized: "dialog.pane.textInput.submit", defaultValue: "OK"),
            cancelLabel: String(localized: "dialog.pane.confirm.cancel", defaultValue: "Cancel"),
            validate: validate,
            source: source,
            completion: { result in
                switch result {
                case .submitted(let value): cont.resume(returning: value)
                case .cancelled, .dismissed: cont.resume(returning: nil)
                }
            }
        )
        paneInteractionRuntime.present(panelId: panelId, interaction: .textInput(content))
    }
}
```

**Rename Tab** (`Sources/Workspace.swift:8751`, inside `renameTab(panelId:)`):
- Anchor: `panelId` itself.
- Default value: current tab title.
- Validator: non-empty after trimming.
- On submit: apply the rename; if cancelled/nil, no-op.

**Rename Workspace** (`Sources/ContentView.swift:12009`, `promptRename()`):
- Anchor: the workspace's `focusedPanelId`. Fallback to NSAlert if nil (defensive; should not happen for a workspace being renamed).
- Default value: current workspace name.
- Validator: non-empty after trimming.

**Custom Color** (`Sources/ContentView.swift:11966`, `promptCustomColor(targetIds:)`):
- Anchor: the focused panel of the first target workspace. Fallback to NSAlert if none resolvable.
- Default value: empty or current color (if all targets share one).
- Validator: match `^#[0-9A-Fa-f]{6}$`; return localized `alert.invalidColor.message` text on fail.
- The inline validation error replaces the existing second-alert flow at `showInvalidColorAlert(_:)` at `ContentView.swift:11996` — cleaner UX.

**c11 risk**: low. All three are fire-and-forget menu/palette actions. Acceptance-time revalidation: before applying, re-confirm the workspace(s)/panel still exist.

### 4.13 Localization additions (v3)

Three new xcstrings keys (en/ja):
- `dialog.pane.textInput.submit` — "OK" / 「OK」
- `dialog.pane.textInput.rename.title` — reuse existing `alert.renameWorkspace.title` / the current tab-rename title where possible.
- `alert.invalidColor.message` already exists; reuse as the validator error.

The existing `dialog.closeTab.*` / `dialog.closeWorkspace.*` keys continue to serve the `.confirm` variant.

### 4.12 Localization — `Resources/Localizable.xcstrings`

Two new keys (en + ja):
- `dialog.pane.confirm.close` — "Close" / 「閉じる」
- `dialog.pane.confirm.cancel` — "Cancel" / 「キャンセル」

Reuse existing `dialog.closeTab.title` / `.message` / `dialog.closeWorkspace.title` / `.message`.

### 4.13 Xcode project

Add file refs for the 3 new source files + 2 new test files via Xcode (avoid hand-editing `project.pbxproj`).

---

## 5. What we do NOT change

| Artifact | Reason |
|---|---|
| `TabManager.confirmClose` + its bulk callers | Stays on NSAlert; no anchor for bulk close / close-others. |
| Settings-sheet `.confirmationDialog` / `.alert` in `cmuxApp.swift` | Already panel-contextual. |
| Move-tab NSAlert (`Workspace.swift:8796`) | Picker-style; belongs to a future `.picker` variant. |
| `TerminalSurface.forceRefresh()` | Typing-latency hot path per `CLAUDE.md:142`. |
| Bonsplit `pendingCloseConfirmTabIds` / `forceCloseTabIds` | Orthogonal to rendering; kept as-is. |
| Sparkle / release plumbing | n/a. |

---

## 6. Phased execution (worktree off `main`)

### Worktree setup
```
git worktree add ../cmux-m10-pane-interaction -b m10-pane-interaction
cd ../cmux-m10-pane-interaction
./scripts/setup.sh
```

### Phase 1 — Primitive + runtime + tests
- `Sources/Panels/PaneInteraction.swift` (enum + types + `PaneInteractionRuntime`).
- `Sources/Panels/PaneInteractionCardView.swift` (SwiftUI card).
- `cmuxTests/PaneInteractionRuntimeTests.swift` — queue, resolve, clear, dedupe, result type.
- Build check.

### Phase 2 — Workspace ownership + overlay hosts
- Add `paneInteractionRuntime` to `Workspace`.
- `Sources/Panels/PaneInteractionOverlayHost.swift` (AppKit wrapper).
- Mount overlay host in `GhosttySurfaceScrollView` (terminal).
- Mount SwiftUI ZStack in `MarkdownPanelView` and empty-browser `BrowserPanelView`.
- Mount AppKit overlay in the WebView browser portal host.
- Build check.

### Phase 3 — Focus choke point + key suppression
- Add `TerminalSurface.safeMakeFirstResponder…` choke point in `GhosttyTerminalView.swift`.
- Route all existing `makeFirstResponder(surfaceView)` callers through it.
- Tagged reload: `./scripts/reload.sh --tag m10-pane-interaction`. Smoke test: programmatically present a dialog on a terminal panel; confirm terminal does NOT receive keystrokes while card is visible.

### Phase 4 — Wire the three close paths
- Rewrite `Workspace.confirmClosePanel(for:)` to route through runtime.
- Rewrite `TabManager.closeRuntimeSurfaceWithConfirmation` — preserve `notificationStore.clearNotifications`, add dedupe token.
- Rewrite `TabManager.closeWorkspaceIfRunningProcess` with `focusedPanelId` anchor + NSAlert fallback.
- Reload + matrix test: ✕ button on tab with running `claude`; `Cmd+W` on tab; `Cmd+W` on workspace; Ghostty child-exit with `needs_confirm`.

### Phase 5 — AppDelegate preservation (Cmd+D + modalWindow)
- Extend Cmd+D dispatcher at `AppDelegate.swift:9018-9051`.
- Extend `modalWindow` gate at `:9054`.
- Add `TabManager.hasActivePaneInteraction` and `acceptActivePaneInteractionInKeyWorkspace`.
- Verify `CloseWorkspaceCmdDUITests` passes against the pane-overlay path.

### Phase 6 — Socket command `pane.confirm`
- Add to dispatcher in `TerminalController.swift` (alongside the existing `pane.*` cases at `:2148-2159`).
- `c11d` CLI wrapper: `c11 pane confirm --panel <uuid> ...`.
- `tests_v2/test_pane_confirm_socket.py` integration test.
- Manual: `cmux pane confirm --panel <uuid> --title test --message hello` from a sibling pane.

### Phase 6b — `.textInput` variant + rename / custom-color conversions (v3 bundle)
- Extend `PaneInteraction` with the `.textInput` case (built from Phase 1 — just uncomment).
- Add `PaneInteractionCardView` rendering branch for text-input (NSTextField-backed for IME safety; mirrors `InputTextView` IME pattern from the textbox-port).
- Convert `Workspace.renameTab` (`:8751`), `ContentView.promptRename` (`:12009`), `ContentView.promptCustomColor` (`:11966`).
- Add `PaneInteractionRuntimeTests` cases for text-input resolve / cancel / dismiss / validate-error.
- Reload + manual: rename a tab via right-click; rename a workspace via command palette; set a custom color via context menu; verify IME (Japanese) works in the input; verify validation error shows inline and doesn't dismiss.

### Phase 7 — Feature flag + acceptance-time revalidation audit
- `cmux.paneDialog.enabled` UserDefaults + env override.
- Each call site wraps its action in "re-check preconditions after `await`".
- Reload + test: disable flag, verify NSAlert fallback; enable, verify overlay.

### Phase 8 — UI tests
- Extend `cmuxUITests/CloseWorkspaceConfirmDialogUITests.swift` detectors to cover overlay.
- Extend `CloseWorkspaceCmdDUITests.swift` — Cmd+D against overlay.
- New `CloseTabPaneOverlayUITests.swift` — ✕ button path.
- New `RenameTabPaneOverlayUITests.swift` — rename via context menu, submit + cancel + validation error.
- 4×4 acceptance test: split workspace into 2×2, trigger close on one, verify overlay appears on exactly that pane and the other three remain interactive (this is the stated motivation — test it).

### Phase 9 — Localization + CHANGELOG
- Two new xcstrings entries (en/ja).
- CHANGELOG: "Tab-close confirmations now appear anchored to the specific tab instead of a window-centered dialog. New `pane.confirm` socket command lets local agents request confirmation in a specific panel."

### Phase 10 — Validation + Trident re-review
- Full matrix test including multi-window + bonsplit split/merge while dialog visible.
- IME sanity check (Japanese input in overlay).
- VoiceOver pass on the overlay.
- Typing-latency log baseline vs. overlay-mounted-idle — confirm no regression.
- `/trident-plan-review` on the v2 diff.

### Phase 11 — PR
- Single PR. Size is medium; the textbox-port two-PR split doesn't apply because these files don't overlap with m9.

---

## 7. Risk register

| Risk | Likelihood | Mitigation |
|---|---|---|
| Terminal portal z-order hides a SwiftUI overlay | N/A | v2 hosts overlay from `GhosttySurfaceScrollView` (AppKit) per `CLAUDE.md:143` — not a risk, an architecture choice. |
| WKWebView z-order hides a SwiftUI overlay | N/A | Same — AppKit mount in the browser portal host for WebView-backed. |
| Focus-restore path steals first responder from card | Medium | Single choke point in §4.7 enforces invariant; all existing callsites route through it. |
| Cmd+D no longer works against overlay | Blocked | §4.8 edit 1 preserves — plus `CloseWorkspaceCmdDUITests` gates merge. |
| `NSApp.modalWindow` gate bypassed → shortcuts fire during dialog | Blocked | §4.8 edit 2 preserves — plus `AppDelegateShortcutRoutingTests`. |
| Ghostty `close_surface_cb` double-fire queues two dialogs | Blocked | Dedupe token on `present(_:dedupeToken:)` collapses duplicates. |
| State drifts between dialog show and user accept (panel gone, process re-exited) | Medium | Acceptance-time revalidation at every call site (§3.4 snippet pattern). |
| `MarkdownPanel` / future panel types have no dialog support | Blocked | Runtime is on `Workspace`, not `Panel`. Every panel type inherits. |
| Sync→async flip breaks a caller that read post-close state | Low | Corrected callsite audit (§4.9) — all external callers are fire-and-forget. |
| Rename / move / color NSAlerts feel inconsistent until follow-up | Accepted | Day-two follow-up PR lands the `.textInput` variant. |
| Socket command creates a denial-of-service by flooding a panel with dialogs | Medium | Runtime's per-panel FIFO queue has a soft cap of 4; over-cap drops the oldest queued (not the active) with `.dismissed`. |
| IME in `.textInput` card (JA/ZH) loses composition | Medium | Card uses `NSTextField` inside `NSHostingView`; respect `hasMarkedText()` during keypress handling — mirror the textbox-port pattern in `Sources/TextBoxInput.swift` (from m9). Phase 6b manual test: Kotoeri + Pinyin. |
| Rename-tab validation error obscures the card | Low | Inline error text below the input, not a new overlay or alert. Replaces the existing two-alert custom-color pattern. |
| ACL on `pane.confirm` lets any local client steer the user | Low | Honors existing cmux socket ACL; `InteractionSource.socket(clientId)` recorded for audit. |
| Feature flag proliferation | Low | One flag only (`cmux.paneDialog.enabled`), removed after one release cycle if stable. |
| Typing-latency regression from AppKit overlay host | Low | No additions to `forceRefresh()` / `hitTest()` hot paths. Phase 10 baseline test gates merge. |
| VoiceOver modal trap not honored | Medium | `.accessibilityAddTraits(.isModal)` on SwiftUI card + AppKit overlay returns `true` from `accessibilityPerformShowMenu` etc. Manual VoiceOver pass. |
| Textbox-port plan (m9) touches `TerminalPanelView` | Low | v2 does NOT edit `TerminalPanelView` (overlay lives in AppKit host). No collision. |

---

## 8. Open questions

**All seven questions resolved in v3** (2026-04-18). Kept here as decision log:

1. **Rename-tab follow-up timing.** ✅ **Bundled into this PR.** `.textInput` variant is day-one; rename-tab, rename-workspace, custom-color convert in this PR. Move-tab (picker-style) stays out. See §2, §4.12.
2. **Socket ACL depth.** ✅ **Honor existing cmux socket ACL** (same gate as `pane.focus`, `surface.send_text`, etc.). `InteractionSource.socket(clientId)` records provenance for future audit.
3. **Per-panel queue soft cap.** ✅ **4.** Overflow drops oldest queued with `.dismissed`; active interaction never preempted. See `PaneInteractionRuntime.perPanelQueueSoftCap` in §3.2.
4. **CLI subcommand naming.** ✅ **`cmux pane confirm --panel <uuid> ...`.** Matches existing `pane.*` command family.
5. **Scrim opacity.** ✅ **0.55 starting point, validate against `company/brand/visual-aesthetic.md` in Phase 2** before locking.
6. **Module numbering.** ✅ **M10.** Branch `m10-pane-interaction`.
7. **Telemetry.** ✅ **DEBUG-only `dlog`, unconditional.** `pane.interaction.present panel=<5char> source=<local|socket> kind=<confirm|textInput>` and `pane.interaction.resolve panel=<5char> result=<confirmed|cancelled|dismissed|submitted>`. Zero release cost.

---

## 9. Acceptance criteria

- Closing a tab via ✕ or `Cmd+W` with a running process shows a card overlaid on that tab's panel, not a window-centered NSAlert. `Workspace.confirmClosePanel(for:)` routes through the runtime.
- Closing a surface inside a split (via Ghostty `close_surface_cb`) shows a card on that surface only. Other splits in the same workspace stay interactive.
- Closing a workspace (last-surface path) shows a card on the workspace's focused panel.
- Bulk close (`Cmd+Shift+W` multi-select) and "Close other tabs in this pane" continue to show NSAlert.
- `Enter` accepts, `Escape` cancels, `Tab` cycles, `Cmd+D` accepts. Terminal/browser input in the affected panel is suppressed while overlay is visible; other panels/tabs/windows remain interactive.
- A second trigger on the same panel queues; a trigger on a different panel shows concurrently.
- `cmux pane confirm --panel <uuid> --title X` shows an overlay on that panel; `--destructive` styles it; exit code reflects outcome.
- `pane.confirm` with an unknown panel UUID returns `error unknown_panel` without side effects.
- The 4×4 acceptance test (Phase 8) passes: overlay visible on target pane only, other three interactive.
- `CloseWorkspaceConfirmDialogUITests`, `CloseWorkspacesConfirmDialogUITests`, `CloseWorkspaceCmdDUITests`, `CloseWindowConfirmDialogUITests`, new `CloseTabPaneOverlayUITests`, new `RenameTabPaneOverlayUITests` all pass.
- `PaneInteractionRuntimeTests` passes (confirm + textInput paths, queue cap = 4 enforced).
- Rename-tab via context menu shows an inline text-input card on that tab's panel; submit applies, cancel is a no-op. IME (Japanese) composes correctly in the input.
- Custom-color invalid hex shows inline validation error; valid hex applies.
- Feature flag `CMUX_PANE_DIALOG_DISABLED=1` disables the overlay; NSAlert fallback works.
- No typing-latency regression vs. a baseline build with the feature flag off.
- Japanese translations for `dialog.pane.confirm.close` / `dialog.pane.confirm.cancel` shipped.
- Tagged reload (`./scripts/reload.sh --tag m10-pane-interaction`) launches cleanly.
