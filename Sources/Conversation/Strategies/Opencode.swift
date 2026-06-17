import Foundation

/// Fresh-launch-only strategy for Opencode. v1 does not map opencode's
/// session storage; if a real id ever appears (via wrapper-claim with a
/// non-placeholder id, or a future scraper) the strategy launches the
/// process — but resume defaults to `.skip` for placeholders.
struct OpencodeStrategy: ConversationStrategy {
    let kind: String = "opencode"

    init() {}

    func capture(inputs: ConversationStrategyInputs) -> ConversationRef? {
        if let push = inputs.push, !push.placeholder {
            return push
        }
        return inputs.wrapperClaim
    }

    func resume(ref: ConversationRef) -> ResumeAction {
        if ref.placeholder {
            return .skip(reason: "fresh-launch-only")
        }
        switch ref.state {
        case .alive, .suspended:
            // Match the launch command's auto-approve mode so a resumed
            // opencode surface doesn't start asking for per-tool confirmation.
            return .typeCommand(text: conversationShellQuote("opencode --dangerously-skip-permissions"), submitWithReturn: true)
        default:
            return .skip(reason: "state=\(ref.state.rawValue) not auto-resumable")
        }
    }
}
