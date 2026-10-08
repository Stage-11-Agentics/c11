import Foundation

enum SendInputGuardStatus: String, Equatable, Sendable {
    case checked
    case unknown
    case refused
    case overridden
}

enum SendInputGuardDecision: Equatable {
    case deliver(SendInputGuardStatus)
    case refuse(reason: String)
    case unavailable
}

enum SendInputGuard {
    static func targetIsCurrent<Workspace: AnyObject, PanelObject: AnyObject>(
        expectedWorkspace: Workspace,
        currentWorkspaces: [Workspace],
        expectedPanel: PanelObject,
        currentPanel: PanelObject?
    ) -> Bool {
        currentWorkspaces.contains { $0 === expectedWorkspace } && currentPanel === expectedPanel
    }

    static func decide(
        state: PromptInputState,
        allowUnguarded: Bool
    ) -> SendInputGuardDecision {
        if allowUnguarded {
            return .deliver(.overridden)
        }
        switch state {
        case .draft:
            return .refuse(reason: "draft")
        case .dialog:
            return .refuse(reason: "dialog")
        case .empty, .suggestion:
            return .deliver(.checked)
        case .unknown, .unavailable:
            return .deliver(.unknown)
        }
    }

    /// Keeps the write behind the same decision seam exercised by unit tests.
    @discardableResult
    static func perform(
        state: PromptInputState,
        allowUnguarded: Bool,
        targetAvailable: Bool = true,
        deliver: () -> Void
    ) -> SendInputGuardDecision {
        guard targetAvailable else { return .unavailable }
        let decision = decide(state: state, allowUnguarded: allowUnguarded)
        if case .deliver = decision { deliver() }
        return decision
    }
}
