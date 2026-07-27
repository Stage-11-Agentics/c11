import Foundation

/// Exact resume strategy for durable Grok Build sessions. The c11 PATH wrapper
/// injects a UUID for new sessions but pushes it only after Grok creates that
/// UUID's session directory (the first real message). Empty sessions remain
/// uncaptured. Restore always names the exact UUID, never "most recent".
struct GrokStrategy: ConversationStrategy {
    let kind: String = "grok"
    static let sessionDirectoryPayloadKey = "session_directory_path"

    init() {}

    func capture(inputs: ConversationStrategyInputs) -> ConversationRef? {
        if let push = inputs.push,
           !push.placeholder,
           push.capturedVia.isCausal,
           isValidConversationUUID(push.id) {
            return push
        }
        return inputs.wrapperClaim
    }

    func resume(ref: ConversationRef) -> ResumeAction {
        if ref.placeholder {
            return .skip(reason: "fresh-launch-only")
        }
        guard ref.state == .alive || ref.state == .suspended else {
            return .skip(reason: "state=\(ref.state.rawValue) not auto-resumable")
        }
        guard isValidConversationUUID(ref.id) else {
            return .skip(reason: "invalid id grammar")
        }
        return .typeCommand(
            text: "\(withAutoApprove("grok")) --resume \(conversationShellQuote(ref.id))",
            submitWithReturn: true
        )
    }

    func isValidId(_ id: String) -> Bool {
        isValidConversationUUID(id)
    }

    func transcriptExists(
        for ref: ConversationRef,
        filesystem: ConversationFilesystem
    ) -> Bool? {
        guard isValidConversationUUID(ref.id) else { return false }
        guard case .string(let path)? = ref.payload?[Self.sessionDirectoryPayloadKey],
              !path.isEmpty else { return nil }
        return filesystem.fileExists(atPath: path)
    }
}
