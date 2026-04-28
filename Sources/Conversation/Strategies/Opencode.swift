import Foundation

/// Fresh-launch-only strategy for Opencode. v1 does not map opencode's
/// session storage; if a real id ever appears (via wrapper-claim with a
/// non-placeholder id, or a future scraper) the strategy launches the
/// process — but resume defaults to `.skip` for placeholders.
public struct OpencodeStrategy: ConversationStrategy {
    public let kind: String = "opencode"

    public init() {}

    public func capture(inputs: ConversationStrategyInputs) -> ConversationRef? {
        if let push = inputs.push, !push.placeholder {
            return push
        }
        return inputs.wrapperClaim
    }

    public func resume(ref: ConversationRef) -> ResumeAction {
        if ref.placeholder {
            return .skip(reason: "fresh-launch-only")
        }
        switch ref.state {
        case .alive, .suspended:
            return .typeCommand(text: conversationShellQuote("opencode"), submitWithReturn: true)
        default:
            return .skip(reason: "state=\(ref.state.rawValue) not auto-resumable")
        }
    }
}
