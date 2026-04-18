import AppKit
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
    public let confirmLabel: String
    public let cancelLabel: String
    public let role: ConfirmRole
    public let source: InteractionSource
    public let completion: (ConfirmResult) -> Void

    public enum ConfirmRole {
        case standard
        case destructive
    }

    public init(
        title: String,
        message: String?,
        confirmLabel: String,
        cancelLabel: String,
        role: ConfirmRole,
        source: InteractionSource,
        completion: @escaping (ConfirmResult) -> Void
    ) {
        self.title = title
        self.message = message
        self.confirmLabel = confirmLabel
        self.cancelLabel = cancelLabel
        self.role = role
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
@MainActor
public final class PaneInteractionRuntime: ObservableObject {
    @Published public private(set) var active: [UUID: PaneInteraction] = [:]
    private var queues: [UUID: [PaneInteraction]] = [:]
    private var seenTokens: [UUID: Set<String>] = [:]

    public static let perPanelQueueSoftCap = 4

    public init() {}

    public func present(panelId: UUID, interaction: PaneInteraction, dedupeToken: String? = nil) {
        if let token = dedupeToken {
            var tokens = seenTokens[panelId, default: []]
            if tokens.contains(token) {
                // Duplicate: surface .dismissed to the incoming caller so its
                // continuation resolves instead of hanging. The in-flight
                // interaction is not disturbed.
                dismissEvicted(interaction)
                return
            }
            tokens.insert(token)
            seenTokens[panelId] = tokens
        }
        if active[panelId] == nil {
            active[panelId] = interaction
        } else {
            var queue = queues[panelId, default: []]
            queue.append(interaction)
            // Enforce soft cap: drop OLDEST queued with .dismissed. Never evict the active.
            while queue.count > PaneInteractionRuntime.perPanelQueueSoftCap {
                let evicted = queue.removeFirst()
                dismissEvicted(evicted)
            }
            queues[panelId] = queue
        }
    }

    public func resolveConfirm(panelId: UUID, result: ConfirmResult) {
        guard case .confirm(let c)? = active[panelId] else { return }
        // Advance state BEFORE firing completion. A completion that calls
        // `present()` synchronously must see a correctly-advanced runtime —
        // otherwise `drain`/`advance` would fire after the reentrant present
        // and overwrite its active slot (losing that interaction's
        // continuation) and wipe any dedupe token it just registered.
        _ = drain(panelId: panelId)
        c.completion(result)
    }

    public func resolveTextInput(panelId: UUID, result: TextInputResult) {
        guard case .textInput(let t)? = active[panelId] else { return }
        _ = drain(panelId: panelId)
        t.completion(result)
    }

    /// Generic cancel path (Esc/Cancel) that works across variants.
    public func cancelActive(panelId: UUID) {
        guard let interaction = active[panelId] else { return }
        _ = drain(panelId: panelId)
        switch interaction {
        case .confirm(let c): c.completion(.cancelled)
        case .textInput(let t): t.completion(.cancelled)
        }
    }

    /// Cancel a specific interaction by id. Searches active and queued slots;
    /// if the target is active, fires `.dismissed` on its completion and
    /// promotes the next queued interaction. If queued, removes it from the
    /// queue and fires `.dismissed` on its completion. Returns true on hit.
    @discardableResult
    public func cancelInteraction(panelId: UUID, interactionId: UUID) -> Bool {
        if let current = active[panelId], current.id == interactionId {
            _ = drain(panelId: panelId)
            dismissEvicted(current)
            return true
        }
        if var queue = queues[panelId],
           let idx = queue.firstIndex(where: { $0.id == interactionId }) {
            let removed = queue.remove(at: idx)
            queues[panelId] = queue.isEmpty ? nil : queue
            dismissEvicted(removed)
            return true
        }
        return false
    }

    /// Typed accept for the currently active interaction on a panel. Used by Cmd+D
    /// routing (§4.8): Cmd+D always means "accept", but the accept shape depends
    /// on the variant (confirm → .confirmed, textInput → submit with current value).
    /// Returns true if an active interaction was resolved.
    @discardableResult
    public func acceptActive(panelId: UUID, textInputValue: String? = nil) -> Bool {
        guard let interaction = active[panelId] else { return false }
        switch interaction {
        case .confirm(let c):
            _ = drain(panelId: panelId)
            c.completion(.confirmed)
        case .textInput(let t):
            let value = textInputValue ?? t.defaultValue
            if t.validate(value) != nil { return false }
            _ = drain(panelId: panelId)
            t.completion(.submitted(value))
        }
        return true
    }

    /// Advance runtime state past the currently-active interaction:
    /// null the active slot, promote the queue head if any, and clear
    /// `seenTokens[panelId]` when the panel is fully idle. The previous
    /// active interaction is returned so callers can inspect it; they are
    /// expected to fire its completion AFTER this returns, not before.
    ///
    /// Running advance before firing completions is the invariant that keeps
    /// reentrant `present()` calls from being silently overwritten (and their
    /// dedupe-token registrations from being wiped). Pre-M10 rev this ran
    /// after the completion and dropped reentrant presents on the floor.
    @discardableResult
    private func drain(panelId: UUID) -> PaneInteraction? {
        let previous = active[panelId]
        active[panelId] = nil
        if var queue = queues[panelId], !queue.isEmpty {
            active[panelId] = queue.removeFirst()
            queues[panelId] = queue.isEmpty ? nil : queue
        } else {
            queues[panelId] = nil
        }
        if active[panelId] == nil && queues[panelId] == nil {
            // Fully idle: let the next independent `present` with a
            // previously-seen dedupe token proceed (otherwise a stable
            // per-panel token like `close_surface_cb.<id>` would silently
            // suppress every subsequent close attempt for the life of the
            // panel).
            seenTokens[panelId] = nil
        }
        return previous
    }

    public func hasActive(panelId: UUID) -> Bool { active[panelId] != nil }
    public var hasAnyActive: Bool { !active.isEmpty }
    public var activePanelIds: Set<UUID> { Set(active.keys) }

    /// Panel/workspace teardown: resolve every pending (active + queued) with `.dismissed`.
    public func clear(panelId: UUID) {
        // Snapshot then null state BEFORE firing completions so any reentrant
        // resolve/clear call sees a clean slate.
        let snapshotActive = active[panelId]
        let snapshotQueue = queues[panelId] ?? []
        active[panelId] = nil
        queues[panelId] = nil
        seenTokens[panelId] = nil
        if let interaction = snapshotActive {
            dismissEvicted(interaction)
        }
        for interaction in snapshotQueue {
            dismissEvicted(interaction)
        }
    }

    /// Clear every panel. Called from workspace teardown.
    public func clearAll() {
        for panelId in Array(active.keys) + Array(queues.keys) {
            clear(panelId: panelId)
        }
    }

    private func dismissEvicted(_ interaction: PaneInteraction) {
        switch interaction {
        case .confirm(let c): c.completion(.dismissed)
        case .textInput(let t): t.completion(.dismissed)
        }
    }
}
