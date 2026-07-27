import Foundation

/// Fresh-launch-only strategy for GitHub Copilot CLI. Copilot manages its own
/// session-store.db at `~/.copilot/` and exposes `/resume` for in-session
/// resume, but accepts no `--session-id <id>` at launch — so c11 cannot
/// pre-write or hand back a session id the way the Claude Code strategy does
/// (see `Resources/bin/copilot`, which deliberately skips session capture for
/// this reason). Capture therefore acts only on a hook/manual push or a
/// wrapper-claim placeholder; resume launches fresh, matching Kimi/Opencode.
struct GitHubCopilotStrategy: ConversationStrategy {
    let kind: String = "github-copilot"

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
            // A fresh launch, so it must carry the same auto-approve posture
            // as the manifest's `factoryCommand` — see `AgentAutoApprove`.
            // Unquoted: the text is a command line, not a single argument.
            return .typeCommand(text: withAutoApprove("copilot"), submitWithReturn: true)
        default:
            return .skip(reason: "state=\(ref.state.rawValue) not auto-resumable")
        }
    }
}
