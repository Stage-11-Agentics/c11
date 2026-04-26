import AppKit
import Bonsplit
import Foundation
import SwiftUI

/// A pane-scoped interaction. Rendered as a card hosted inside a specific panel,
/// with a scrim bounded to that panel's bounds. This is the substrate that replaces
/// the two app-level NSAlert close confirmations with anchored, panel-local UI.
///
/// Day-one variants: `.confirm` and `.textInput`. Future variants (`.picker`,
/// `.banner`, `.progress`) are reserved — the enum and the presenter are sized to
/// accept them without a rewrite.
public enum PaneInteraction: Identifiable {
    case confirm(ConfirmContent)
    case textInput(TextInputContent)

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
        /// Scrim + focus capture + key suppression on the target panel.
        case modal
        /// Reserved for future banners/toasts. No scrim, no focus capture.
        case nonModal
    }
}

public struct ConfirmContent: Identifiable {
    public let id = UUID()
    public let title: String
    public let message: String?
    /// Optional list of items the action will affect, rendered as a bullet
    /// list under the message. Use for high-stakes destructive flows where
    /// the user needs to see exactly what's about to be removed (e.g.
    /// pane-close listing each tab being closed).
    public let detailLines: [String]
    public let confirmLabel: String
    public let cancelLabel: String
    public let role: ConfirmRole
    public let style: ConfirmStyle
    public let source: InteractionSource
    public let completion: (ConfirmResult) -> Void

    public enum ConfirmRole {
        case standard
        case destructive
    }

    /// Visual treatment of the card. `.standard` is the default look used by
    /// every existing call site. `.criticalDestructive` is the emphasised
    /// treatment used when an irreversible multi-item action is at stake —
    /// red glow on the card, pulsing destructive button, larger title — so
    /// the operator can't fat-finger their way through it.
    public enum ConfirmStyle {
        case standard
        case criticalDestructive
    }

    public init(
        title: String,
        message: String?,
        detailLines: [String] = [],
        confirmLabel: String,
        cancelLabel: String,
        role: ConfirmRole,
        style: ConfirmStyle = .standard,
        source: InteractionSource,
        completion: @escaping (ConfirmResult) -> Void
    ) {
        self.title = title
        self.message = message
        self.detailLines = detailLines
        self.confirmLabel = confirmLabel
        self.cancelLabel = cancelLabel
        self.role = role
        self.style = style
        self.source = source
        self.completion = completion
    }
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

    public init(
        title: String,
        message: String?,
        placeholder: String?,
        defaultValue: String,
        confirmLabel: String,
        cancelLabel: String,
        validate: @escaping (String) -> String?,
        source: InteractionSource,
        completion: @escaping (TextInputResult) -> Void
    ) {
        self.title = title
        self.message = message
        self.placeholder = placeholder
        self.defaultValue = defaultValue
        self.confirmLabel = confirmLabel
        self.cancelLabel = cancelLabel
        self.validate = validate
        self.source = source
        self.completion = completion
    }
}

public enum ConfirmResult: Equatable {
    case confirmed
    /// Explicit user cancel (Cancel button, Esc, etc.).
    case cancelled
    /// Panel closed, workspace closed, or runtime cleared. Distinguished from user cancel.
    case dismissed
}

/// Which button is currently highlighted in a `.confirm` card. Moved by
/// arrow/tab keys routed through `PaneInteractionOverlayHost.keyDown` (AppKit
/// host path) or SwiftUI `onKeyPress` (overlay paths with no AppKit host).
public enum ConfirmSelectionField: Hashable {
    case cancel
    case confirm
}

public enum ConfirmMoveDirection {
    case left
    case right
    case toggle
}

/// Which element is highlighted in a `.textInput` card. `.field` means the
/// text field owns first responder and arrow keys move the cursor; `.cancel`
/// and `.confirm` are the two buttons that draw a white outline when active.
/// Tab cycles between the buttons; click-out on the scrim/card-background
/// moves selection off `.field` (default lands on `.confirm`).
public enum TextInputSelectionField: Hashable {
    case field
    case cancel
    case confirm
}

public enum TextInputResult: Equatable {
    case submitted(String)
    case cancelled
    case dismissed
}

public enum InteractionSource {
    /// Triggered by in-app code (menu action, context menu, keyboard).
    case local
    /// Triggered by a socket command. `clientId` is captured for audit — ACL
    /// enforcement is inherited from the existing socket gate.
    case socket(clientId: String)
}

/// Feature-flag gate for the pane-interaction primitive. When disabled, all
/// routes fall back to the pre-M10 NSAlert path. Default is enabled.
///
/// Rollback story (plan §3.7):
/// - UserDefaults key `cmux.paneDialog.enabled` — set false to disable.
/// - Environment variable `CMUX_PANE_DIALOG_DISABLED=1` — overrides UserDefaults
///   to off. Set for UI tests / CI runs that predate the overlay detectors.
public enum PaneInteractionFeatureFlag {
    public static let userDefaultsKey = "cmux.paneDialog.enabled"
    public static let disableEnvVar = "CMUX_PANE_DIALOG_DISABLED"

    public static var isEnabled: Bool {
        if let raw = ProcessInfo.processInfo.environment[disableEnvVar],
           let value = Int(raw), value != 0 {
            return false
        }
        // UserDefaults default is true — key-missing means enabled.
        let defaults = UserDefaults.standard
        if defaults.object(forKey: userDefaultsKey) == nil {
            return true
        }
        return defaults.bool(forKey: userDefaultsKey)
    }
}

/// Per-workspace presenter. Each `Workspace` owns one runtime; this sidesteps the
/// "every `Panel` conformer needs a new property" problem.
///
/// Per-panel FIFO queue: a second trigger on the same panel queues; triggers on
/// different panels show concurrently. Soft cap is `perPanelQueueSoftCap` — any
/// queued entry past that cap is evicted with `.dismissed` (oldest first). The
/// currently-active interaction is never preempted by overflow.
///
/// Resolve/cancel/accept APIs take an optional `interactionId` guard so racing
/// callers (socket timeout vs. user click, double-click, queued-advance) can
/// verify they are acting on the interaction they originally saw, not whatever
/// happens to be active right now.
@MainActor
public final class PaneInteractionRuntime: ObservableObject {
    @Published public private(set) var active: [UUID: PaneInteraction] = [:]
    private var queues: [UUID: [PaneInteraction]] = [:]
    /// Dedupe tokens for currently-in-flight interactions (active + queued),
    /// keyed by panel. When the last interaction for a token resolves/cancels
    /// the token is cleared so future `present()` with the same token is
    /// allowed. This prevents the "cancel a close-confirm and can never close
    /// the tab again" lockout (synthesis-critical §1.2).
    private var tokenToInteractionIds: [UUID: [String: Set<UUID>]] = [:]
    private var interactionIdToToken: [UUID: String] = [:]
    /// Live text-input values keyed by the interaction's id. Bridged from
    /// `TextInputCard` so `acceptActive` (Cmd+D) can submit the edited value
    /// instead of the default (synthesis-critical §1.1).
    @Published public private(set) var pendingTextInputValues: [UUID: String] = [:]
    /// Which button is highlighted per panel for an active `.confirm` card.
    /// Driven by arrow / tab keys; Return resolves the selected option.
    /// Reset to `.confirm` on `present` / queue advance / clear.
    @Published public private(set) var confirmSelection: [UUID: ConfirmSelectionField] = [:]
    /// Focus pivot per panel for an active `.textInput` card. `.field` is the
    /// default on present (text field owns first responder). Tab cycles
    /// `.field → .cancel → .confirm → .field`; clicking outside the field on
    /// the scrim or card background moves to `.confirm`. Reset to `.field` on
    /// queue advance / clear.
    @Published public private(set) var textInputSelection: [UUID: TextInputSelectionField] = [:]

    public static let perPanelQueueSoftCap = 4

    public init() {}

    public func present(panelId: UUID, interaction: PaneInteraction, dedupeToken: String? = nil) {
        if let token = dedupeToken {
            var byToken = tokenToInteractionIds[panelId, default: [:]]
            if let existing = byToken[token], !existing.isEmpty {
                // Dedupe collision: an interaction with this token is already
                // live on this panel. Resolve the new interaction with
                // `.dismissed` so any caller awaiting a `withCheckedContinuation`
                // unblocks — dropping on the floor leaks continuations.
                dismissEvicted(interaction)
                return
            }
            byToken[token, default: []].insert(interaction.id)
            tokenToInteractionIds[panelId] = byToken
            interactionIdToToken[interaction.id] = token
        }
#if DEBUG
        dlog("pane.interaction.present panel=\(panelId.uuidString.prefix(5)) id=\(interaction.id.uuidString.prefix(5)) src=\(describeSource(interaction))")
#endif
        if active[panelId] == nil {
            active[panelId] = interaction
            if case .confirm = interaction { confirmSelection[panelId] = .confirm }
            if case .textInput = interaction { textInputSelection[panelId] = .field }
        } else {
            var queue = queues[panelId, default: []]
            queue.append(interaction)
            // Enforce soft cap: drop OLDEST queued with .dismissed. Never evict the active.
            while queue.count > PaneInteractionRuntime.perPanelQueueSoftCap {
                let evicted = queue.removeFirst()
                retireToken(forInteractionId: evicted.id, panelId: panelId)
                dismissEvicted(evicted)
            }
            queues[panelId] = queue
        }
    }

    /// Resolve the active confirm. When `interactionId` is provided the call is
    /// a no-op unless the currently-active interaction has that id — prevents a
    /// late socket timeout/cancel from resolving a newly-advanced successor.
    public func resolveConfirm(panelId: UUID, result: ConfirmResult, ifInteractionId interactionId: UUID? = nil) {
        guard case .confirm(let c)? = active[panelId] else { return }
        if let interactionId, c.id != interactionId { return }
#if DEBUG
        dlog("pane.interaction.resolve panel=\(panelId.uuidString.prefix(5)) id=\(c.id.uuidString.prefix(5)) kind=confirm result=\(result)")
#endif
        retireToken(forInteractionId: c.id, panelId: panelId)
        c.completion(result)
        advance(panelId: panelId)
    }

    public func resolveTextInput(panelId: UUID, result: TextInputResult, ifInteractionId interactionId: UUID? = nil) {
        guard case .textInput(let t)? = active[panelId] else { return }
        if let interactionId, t.id != interactionId { return }
#if DEBUG
        dlog("pane.interaction.resolve panel=\(panelId.uuidString.prefix(5)) id=\(t.id.uuidString.prefix(5)) kind=textInput")
#endif
        retireToken(forInteractionId: t.id, panelId: panelId)
        pendingTextInputValues.removeValue(forKey: t.id)
        t.completion(result)
        advance(panelId: panelId)
    }

    /// Generic cancel path (Esc/Cancel) that works across variants. `interactionId`
    /// guards against canceling a successor interaction that advanced into view
    /// between the caller reading `active` and this call.
    public func cancelActive(panelId: UUID, ifInteractionId interactionId: UUID? = nil) {
        guard let interaction = active[panelId] else { return }
        if let interactionId, interaction.id != interactionId { return }
#if DEBUG
        dlog("pane.interaction.cancel panel=\(panelId.uuidString.prefix(5)) id=\(interaction.id.uuidString.prefix(5))")
#endif
        retireToken(forInteractionId: interaction.id, panelId: panelId)
        switch interaction {
        case .confirm(let c): c.completion(.cancelled)
        case .textInput(let t):
            pendingTextInputValues.removeValue(forKey: t.id)
            t.completion(.cancelled)
        }
        advance(panelId: panelId)
    }

    /// Typed accept for the currently active interaction on a panel. Used by Cmd+D
    /// routing (§4.8): Cmd+D always means "accept", but the accept shape depends
    /// on the variant (confirm → .confirmed, textInput → submit with current value).
    ///
    /// For `.textInput`, the value submitted is the bridge value in
    /// `pendingTextInputValues[interaction.id]` when present (the live text in
    /// `TextInputCard`), falling back to `textInputValue` or the content's
    /// `defaultValue`. Returns true if an active interaction was resolved.
    @discardableResult
    public func acceptActive(
        panelId: UUID,
        textInputValue: String? = nil,
        ifInteractionId interactionId: UUID? = nil
    ) -> Bool {
        guard let interaction = active[panelId] else { return false }
        if let interactionId, interaction.id != interactionId { return false }
        switch interaction {
        case .confirm(let c):
#if DEBUG
            dlog("pane.interaction.accept panel=\(panelId.uuidString.prefix(5)) id=\(c.id.uuidString.prefix(5)) kind=confirm")
#endif
            retireToken(forInteractionId: c.id, panelId: panelId)
            c.completion(.confirmed)
        case .textInput(let t):
            // Priority: live bridge value > explicit argument > content default.
            let value = pendingTextInputValues[t.id] ?? textInputValue ?? t.defaultValue
            if t.validate(value) != nil { return false }
#if DEBUG
            dlog("pane.interaction.accept panel=\(panelId.uuidString.prefix(5)) id=\(t.id.uuidString.prefix(5)) kind=textInput")
#endif
            retireToken(forInteractionId: t.id, panelId: panelId)
            pendingTextInputValues.removeValue(forKey: t.id)
            t.completion(.submitted(value))
        }
        advance(panelId: panelId)
        return true
    }

    /// Write the live text from `TextInputCard` so Cmd+D accept can submit the
    /// edited value instead of the default. Keyed by the interaction's id, not
    /// the panel, so queue-advance across duplicate panels doesn't cross streams.
    public func updatePendingTextInputValue(interactionId: UUID, value: String) {
        pendingTextInputValues[interactionId] = value
    }

    private func advance(panelId: UUID) {
        if var queue = queues[panelId], !queue.isEmpty {
            let next = queue.removeFirst()
            active[panelId] = next
            queues[panelId] = queue
            switch next {
            case .confirm:
                confirmSelection[panelId] = .confirm
                textInputSelection[panelId] = nil
            case .textInput:
                confirmSelection[panelId] = nil
                textInputSelection[panelId] = .field
            }
        } else {
            active[panelId] = nil
            queues[panelId] = nil
            confirmSelection[panelId] = nil
            textInputSelection[panelId] = nil
        }
    }

    /// Move the highlighted button for the active `.confirm` card. No-op if the
    /// active interaction isn't a `.confirm` variant.
    public func moveConfirmSelection(panelId: UUID, direction: ConfirmMoveDirection) {
        guard case .confirm? = active[panelId] else { return }
        let current = confirmSelection[panelId] ?? .confirm
        let next: ConfirmSelectionField
        switch direction {
        case .left: next = .cancel
        case .right: next = .confirm
        case .toggle: next = (current == .confirm) ? .cancel : .confirm
        }
        confirmSelection[panelId] = next
    }

    /// Route non-text dialog control keys to the active interaction. This is used
    /// both by the AppKit overlay host and by the app-level fallback when AppKit
    /// leaves first responder on the window instead of the overlay.
    @discardableResult
    public func handleKeyDown(panelId: UUID, keyCode: Int, shift: Bool = false) -> Bool {
        guard let interaction = active[panelId] else { return false }
        switch interaction {
        case .confirm:
            switch keyCode {
            case 123, 126: // left / up
                moveConfirmSelection(panelId: panelId, direction: .left)
            case 124, 125: // right / down
                moveConfirmSelection(panelId: panelId, direction: .right)
            case 48:
                moveConfirmSelection(panelId: panelId, direction: .toggle)
            case 36, 76, 49: // return / numpad enter / space
                acceptSelectedConfirm(panelId: panelId)
            case 53:
                cancelActive(panelId: panelId)
            default:
                return false
            }
            return true
        case .textInput:
            // When the field is selected, typed keys, Return, Tab, and IME
            // composition must continue through NSTextField/NSTextView.
            let selection = textInputSelection[panelId] ?? .field
            guard selection != .field else { return false }
            switch keyCode {
            case 123, 126: // left / up
                moveTextInputSelection(panelId: panelId, direction: .left)
            case 124, 125: // right / down
                moveTextInputSelection(panelId: panelId, direction: .right)
            case 48:
                cycleTextInputSelection(panelId: panelId, backward: shift)
            case 36, 76, 49: // return / numpad enter / space
                return acceptSelectedTextInput(panelId: panelId)
            case 53:
                cancelActive(panelId: panelId)
            default:
                return false
            }
            return true
        }
    }

    /// Set the active `.textInput` selection directly. No-op if the active
    /// interaction isn't a `.textInput` variant. Used by click-to-defocus
    /// (scrim / card background) and by the field delegate to report that
    /// AppKit has restored editing focus.
    public func setTextInputSelection(panelId: UUID, _ selection: TextInputSelectionField) {
        guard case .textInput? = active[panelId] else { return }
        textInputSelection[panelId] = selection
    }

    /// Move the textInput selection via an arrow key. No-op when the field
    /// owns focus (arrows move the cursor in that case).
    public func moveTextInputSelection(panelId: UUID, direction: ConfirmMoveDirection) {
        guard case .textInput? = active[panelId] else { return }
        let current = textInputSelection[panelId] ?? .field
        guard current != .field else { return }
        let next: TextInputSelectionField
        switch direction {
        case .left: next = .cancel
        case .right: next = .confirm
        case .toggle: next = (current == .confirm) ? .cancel : .confirm
        }
        textInputSelection[panelId] = next
    }

    /// Cycle textInput selection with Tab (`backward` == Shift+Tab).
    /// `.field → .cancel → .confirm → .field` forward; reverse otherwise.
    public func cycleTextInputSelection(panelId: UUID, backward: Bool) {
        guard case .textInput? = active[panelId] else { return }
        let current = textInputSelection[panelId] ?? .field
        let next: TextInputSelectionField
        if backward {
            switch current {
            case .field: next = .confirm
            case .cancel: next = .field
            case .confirm: next = .cancel
            }
        } else {
            switch current {
            case .field: next = .cancel
            case .cancel: next = .confirm
            case .confirm: next = .field
            }
        }
        textInputSelection[panelId] = next
    }

    /// Resolve the active `.textInput` using whichever target is currently
    /// highlighted. `.cancel` cancels; `.field` and `.confirm` submit the
    /// live (bridged) value — validation is honored, so a failed submit
    /// leaves the card in place for the field's inline error.
    /// Returns true if the interaction was resolved.
    @discardableResult
    public func acceptSelectedTextInput(panelId: UUID) -> Bool {
        guard case .textInput(let t)? = active[panelId] else { return false }
        let selection = textInputSelection[panelId] ?? .field
        if selection == .cancel {
            retireToken(forInteractionId: t.id, panelId: panelId)
            pendingTextInputValues.removeValue(forKey: t.id)
            t.completion(.cancelled)
            advance(panelId: panelId)
            return true
        }
        let value = pendingTextInputValues[t.id] ?? t.defaultValue
        if t.validate(value) != nil { return false }
        retireToken(forInteractionId: t.id, panelId: panelId)
        pendingTextInputValues.removeValue(forKey: t.id)
        t.completion(.submitted(value))
        advance(panelId: panelId)
        return true
    }

    /// Resolve the active `.confirm` using whichever button is currently
    /// highlighted. Used by Return key routing.
    public func acceptSelectedConfirm(panelId: UUID) {
        guard case .confirm(let c)? = active[panelId] else { return }
        let selection = confirmSelection[panelId] ?? .confirm
        let result: ConfirmResult = (selection == .cancel) ? .cancelled : .confirmed
        resolveConfirm(panelId: panelId, result: result, ifInteractionId: c.id)
    }

    public func hasActive(panelId: UUID) -> Bool { active[panelId] != nil }
    public var hasAnyActive: Bool { !active.isEmpty }
    public var activePanelIds: Set<UUID> { Set(active.keys) }

    /// Panel/workspace teardown: resolve every pending (active + queued) with `.dismissed`.
    public func clear(panelId: UUID) {
        if let interaction = active[panelId] {
            pendingTextInputValues.removeValue(forKey: interaction.id)
            dismissEvicted(interaction)
        }
        active[panelId] = nil
        if let queue = queues[panelId] {
            for interaction in queue {
                pendingTextInputValues.removeValue(forKey: interaction.id)
                dismissEvicted(interaction)
            }
        }
        queues[panelId] = nil
        confirmSelection[panelId] = nil
        textInputSelection[panelId] = nil
        // Clear every token-bookkeeping entry for interactions on this panel.
        if let byToken = tokenToInteractionIds[panelId] {
            for (_, ids) in byToken {
                for id in ids { interactionIdToToken.removeValue(forKey: id) }
            }
        }
        tokenToInteractionIds[panelId] = nil
    }

    /// Clear every panel. Called from workspace teardown.
    public func clearAll() {
        let panelIds = Set(active.keys).union(queues.keys).union(tokenToInteractionIds.keys)
        for panelId in panelIds {
            clear(panelId: panelId)
        }
    }

    private func dismissEvicted(_ interaction: PaneInteraction) {
        switch interaction {
        case .confirm(let c): c.completion(.dismissed)
        case .textInput(let t): t.completion(.dismissed)
        }
    }

    private func retireToken(forInteractionId interactionId: UUID, panelId: UUID) {
        guard let token = interactionIdToToken.removeValue(forKey: interactionId) else { return }
        var byToken = tokenToInteractionIds[panelId] ?? [:]
        if var ids = byToken[token] {
            ids.remove(interactionId)
            if ids.isEmpty {
                byToken.removeValue(forKey: token)
            } else {
                byToken[token] = ids
            }
        }
        if byToken.isEmpty {
            tokenToInteractionIds[panelId] = nil
        } else {
            tokenToInteractionIds[panelId] = byToken
        }
    }

#if DEBUG
    private func describeSource(_ interaction: PaneInteraction) -> String {
        let source: InteractionSource
        switch interaction {
        case .confirm(let c): source = c.source
        case .textInput(let t): source = t.source
        }
        switch source {
        case .local: return "local"
        case .socket(let clientId): return "socket(\(clientId))"
        }
    }
#endif
}
