import Foundation

/// Pure Claude hook → journal draft. No owner lookup, no transcript read, no payload copy.
enum ClaudeHookMapping {
    static func map(subcommand: String, object: [String: Any]) -> JournalDraft? {
        let tool = object["tool_name"] as? String
        let parentSession = opaque(object["session_id"] as? String)
        let kind: JournalKind
        let native: String
        var session = parentSession
        var isChild = false
        var request = requestID(subcommand, object)
        switch subcommand {
        case "session-start", "active":
            kind = .sessionStarted
            native = "SessionStart"
        case "session-end":
            kind = .sessionEnded
            native = "SessionEnd"
        case "prompt-submit":
            kind = .turnStarted
            native = "UserPromptSubmit"
            request = nil
        case "stop", "idle":
            kind = .turnCompleted
            native = "Stop"
        case "pre-tool-use":
            kind = tool == "AskUserQuestion" ? .questionRequested : (tool == "ExitPlanMode" ? .planReviewRequested : .stateChanged)
            native = "PreToolUse"
        case "post-tool-use":
            native = "PostToolUse"
            if tool == "AskUserQuestion" || tool == "ExitPlanMode" {
                guard request != nil else { return nil }
                kind = .attentionResolved
            } else {
                kind = .stateChanged
            }
        case "notification", "notify":
            kind = (object["notification_type"] as? String) == "permission_prompt" ? .approvalRequested : .stateChanged
            native = "Notification"
        case "stop-failure":
            kind = .errorReported
            native = "StopFailure"
        case "permission-request":
            if tool == "AskUserQuestion" || tool == "ExitPlanMode" { return nil }
            kind = .approvalRequested
            native = "PermissionRequest"
        case "subagent-start", "subagent-stop":
            kind = subcommand == "subagent-start" ? .childSpawned : .childCompleted
            native = "other"
            isChild = true
            session = opaque(object["agent_id"] as? String)
        case "pre-compact":
            kind = .stateChanged
            native = "other"
        default:
            return nil
        }
        var draft = JournalDraft(
            kind: kind,
            emittedAtMs: Int64(Date().timeIntervalSince1970 * 1000),
            sessionID: session,
            agentKind: "claude-code",
            isChild: isChild,
            parentSessionID: isChild ? parentSession : nil,
            source: .hook,
            adapter: .claudeHook,
            nativeEvent: native
        )
        draft.turnID = opaque(object["prompt_id"] as? String)
        draft.requestID = request
        if kind == .attentionResolved { draft.resolution = .resumed }
        if kind == .errorReported { draft.reasonCode = .sessionFailure }
        if kind == .stateChanged {
            draft.signal = native == "PreToolUse" || native == "PostToolUse" ? .toolActivity : .observation
        }
        if native == "PreToolUse" || native == "PostToolUse" || native == "PermissionRequest" {
            draft.toolClass = tool == "AskUserQuestion" ? .askUserQuestion : (tool == "ExitPlanMode" ? .exitPlanMode : .other)
        }
        do {
            try draft.validate()
            return draft
        } catch {
            return nil
        }
    }

    /// Ask continuation emits nothing without a usable id. Other hooks keep the event and leave the id null.
    private static func requestID(_ subcommand: String, _ object: [String: Any]) -> String? {
        switch subcommand {
        case "pre-tool-use", "post-tool-use", "permission-request":
            return opaque(object["tool_use_id"] as? String)
        default:
            return nil
        }
    }

    /// Same opaque rule JournalDraft.validate uses. Over-long or non-structural text becomes absent.
    private static func opaque(_ value: String?, limit: Int = 128) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= limit,
              value.utf8.allSatisfy({ $0 >= 33 && $0 <= 126 && $0 != 47 && $0 != 92 }) else { return nil }
        return value
    }
}
