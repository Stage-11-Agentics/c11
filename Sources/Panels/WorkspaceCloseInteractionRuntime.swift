import Combine
import Foundation

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
    /// Highlighted button on the live card. Defaults to `.cancel` on every
    /// present — the destructive action requires a deliberate move to confirm.
    @Published public internal(set) var selection: ConfirmSelectionField = .cancel
    private var dedupeToken: String?

    public init() {}

    public func present(content: ConfirmContent, dedupeToken: String? = nil) {
        if let token = dedupeToken,
           self.dedupeToken == token,
           active != nil {
            // Dedupe collision: a workspace-close prompt with this token is
            // already live. Resolve the new one with `.dismissed` so any caller
            // awaiting `withCheckedContinuation` unblocks.
            content.completion(.dismissed)
            return
        }
        if let existing = active {
            existing.completion(.dismissed)
        }
        active = content
        selection = .cancel
        self.dedupeToken = dedupeToken
    }

    public func resolve(result: ConfirmResult, ifInteractionId interactionId: UUID? = nil) {
        guard let content = active else { return }
        if let interactionId, content.id != interactionId { return }
        active = nil
        selection = .cancel
        dedupeToken = nil
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
            acceptSelected()
        case 53: // escape
            cancel()
        default:
            return false
        }
        return true
    }
}
