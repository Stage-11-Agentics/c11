import Combine
import Foundation
import OSLog

/// Workspace-scoped presenter for a single close-confirmation interaction.
///
/// Distinct from `PaneInteractionRuntime` so the keyspace doesn't conflate
/// pane-scoped interactions (close-tab, rename, close-pane) with the
/// workspace-scoped close-workspace overlay. Only `.confirm` is supported
/// — the workspace overlay never carries text-input or other variants.
///
/// At most one interaction is active per workspace. `present` while another
/// is live resolves the existing one with `.dismissed` and shows the new one
/// (last-write-wins). This mirrors the "single anchor per workspace" model:
/// re-triggering Cmd+Shift+W while the overlay is up rebinds to the latest
/// trigger so a stale dialog can't strand a continuation.
@MainActor
public final class WorkspaceCloseInteractionRuntime: ObservableObject {
    @Published public private(set) var active: ConfirmContent?
    /// Highlighted button on the live card. Each present starts on the card's
    /// `defaultSelection`, else `.cancel`, so closing a workspace of several
    /// tabs takes a deliberate move to confirm.
    @Published public internal(set) var selection: ConfirmSelectionField = .cancel
    private var dedupeToken: String?
    /// Unknown until a host reports. Return accepts only `.visible`. An
    /// `.unmounted` card does not keep the dedupe token.
    private var confirmVisibility: ConfirmVisibility = .unknown

    private enum ConfirmVisibility {
        case unknown
        case visible
        case unmounted
    }

    public init() {}

    public func present(content: ConfirmContent, dedupeToken: String? = nil) {
        if let token = dedupeToken,
           self.dedupeToken == token,
           active != nil {
            if confirmVisibility == .unmounted {
                // The live card was reported unmounted. Drop it and show this
                // request so a missing anchor cannot lock the X.
                let previous = active
                active = nil
                self.dedupeToken = nil
                confirmVisibility = .unknown
                previous?.completion(.dismissed)
            } else {
                // Dedupe collision: a workspace-close prompt with this token is
                // already live. Resolve the new one with `.dismissed` so any caller
                // awaiting `withCheckedContinuation` unblocks.
                content.completion(.dismissed)
                return
            }
        }
        if let existing = active {
            existing.completion(.dismissed)
        }
        active = content
        selection = content.defaultSelection ?? .cancel
        self.dedupeToken = dedupeToken
        confirmVisibility = .unknown
    }

    /// Hosts call this once they know whether the card is on screen.
    public func noteConfirmVisible(_ visible: Bool) {
        guard active != nil else {
            confirmVisibility = .unknown
            return
        }
        confirmVisibility = visible ? .visible : .unmounted
    }

    public var isConfirmCardVisible: Bool { confirmVisibility == .visible }

    /// Resume the waiter with `.dismissed` and clear the dedupe token.
    /// Used when a panel confirm cannot be shown, so the pending-close guard
    /// does not outlive the missing card.
    public func releaseUnmounted() {
        guard let content = active else { return }
        active = nil
        selection = .cancel
        dedupeToken = nil
        confirmVisibility = .unknown
        content.completion(.dismissed)
    }

    public func resolve(result: ConfirmResult, ifInteractionId interactionId: UUID? = nil) {
        guard let content = active else { return }
        if let interactionId, content.id != interactionId { return }
        active = nil
        selection = .cancel
        dedupeToken = nil
        confirmVisibility = .unknown
        content.completion(result)
    }

    public func cancel(ifInteractionId interactionId: UUID? = nil) {
        resolve(result: .cancelled, ifInteractionId: interactionId)
    }

    @discardableResult
    public func accept(ifInteractionId interactionId: UUID? = nil) -> Bool {
        guard let content = active else { return false }
        if let interactionId, content.id != interactionId { return false }
        active = nil
        selection = .cancel
        dedupeToken = nil
        confirmVisibility = .unknown
        content.completion(.confirmed)
        return true
    }

    public func clear() {
        if let existing = active {
            existing.completion(.dismissed)
        }
        active = nil
        selection = .cancel
        dedupeToken = nil
        confirmVisibility = .unknown
    }

    public var hasActive: Bool { active != nil }

    /// Move the highlighted button. No-op when no card is active.
    public func moveSelection(_ direction: ConfirmMoveDirection) {
        guard active != nil else { return }
        switch direction {
        case .left: selection = .cancel
        case .right: selection = .confirm
        case .toggle: selection = (selection == .confirm) ? .cancel : .confirm
        }
    }

    /// Resolve the active card using whichever button is currently highlighted.
    /// Used by Return / Space routing.
    public func acceptSelected() {
        guard active != nil else { return }
        switch selection {
        case .cancel: cancel()
        case .confirm: _ = accept()
        }
    }

    /// Route arrow / Tab / Return / Esc keys against the active selection.
    /// Returns true if the key was consumed.
    @discardableResult
    public func handleKeyDown(keyCode: Int, shift: Bool = false) -> Bool {
        _ = shift
        guard active != nil else { return false }
        switch keyCode {
        case 123, 126: // left / up
            moveSelection(.left)
        case 124, 125: // right / down
            moveSelection(.right)
        case 48: // tab
            moveSelection(.toggle)
        case 36, 76, 49: // return / numpad enter / space
            // A card that is not on screen must not close anything.
            guard isConfirmCardVisible else { return false }
            acceptSelected()
        case 53: // escape
            cancel()
        default:
            return false
        }
        return true
    }
}

/// Production close diagnostics. `dlog` is DEBUG-only; this logger is notice
/// level so a Release build still records the lines `log show` reads.
enum CloseLog {
    private static let logger = Logger(subsystem: "com.stage11.c11", category: "close")

    static func request(
        panel: UUID?,
        workspace: UUID,
        explicit: Bool,
        lastSurface: Bool,
        needsConfirm: Bool,
        route: String
    ) {
        logger.notice(
            "close.request panel=\(panel?.uuidString ?? "-", privacy: .public) ws=\(workspace.uuidString, privacy: .public) explicit=\(explicit ? "1" : "0", privacy: .public) lastSurface=\(lastSurface ? "1" : "0", privacy: .public) needsConfirm=\(needsConfirm ? "1" : "0", privacy: .public) route=\(route, privacy: .public)"
        )
    }

    static func overlayUnmounted(scope: String, workspace: UUID?, reason: String) {
        logger.notice(
            "close.overlay.unmounted scope=\(scope, privacy: .public) ws=\(workspace?.uuidString ?? "-", privacy: .public) reason=\(reason, privacy: .public)"
        )
    }

    static func fallback(scope: String, workspace: UUID?) {
        logger.notice(
            "close.overlay.fallback scope=\(scope, privacy: .public) ws=\(workspace?.uuidString ?? "-", privacy: .public)"
        )
    }
}
