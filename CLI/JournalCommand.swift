import Foundation

enum JournalCommand {
    enum Delivery { case committed([String: Any]), spooled, unsupported, lost }

    static func deliver(_ draft: JournalDraft, socketPath: String) -> Delivery {
        guard let data = try? draft.canonicalData(),
              let params = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .lost }
        let previousDeadline = SocketClient.processDeadline
        SocketClient.processDeadline = min(previousDeadline ?? .distantFuture, Date().addingTimeInterval(0.250))
        defer { SocketClient.processDeadline = previousDeadline }
        let client = SocketClient(path: socketPath)
        defer { client.close() }
        do {
            try client.connect()
            return .committed(try client.sendV2(method: "agent.event.append", params: ["event": params], deadline: .custom(0.250)))
        } catch let error as CLIError where error.message.hasPrefix("method_not_found:") {
            return .unsupported
        } catch {
            let env = ProcessInfo.processInfo.environment
            let bundleID = env["CMUX_BUNDLE_ID"] ?? enclosingBundleID()
            guard let layout = try? JournalStorageLayout.resolve(bundleID: bundleID), JournalSpool(layout: layout).write(draft) else { return .lost }
            return .spooled
        }
    }

    static func run(_ arguments: [String], socketPath: String) throws {
        if arguments.isEmpty || arguments.contains("--help") || arguments.contains("-h") {
            print("c11 agent-event append --stdin\nAppend one structural lifecycle event; returns a committed receipt or {\"spooled\":true}. Maximum input: 4096 bytes.")
            return
        }
        guard arguments == ["append", "--stdin"] else { throw CLIError(message: "usage: c11 agent-event append --stdin") }
        let data = FileHandle.standardInput.readData(ofLength: 4097)
        let draft: JournalDraft
        do { draft = try JournalDraft.decode(data) } catch { throw CLIError(message: "invalid_event") }
        switch deliver(draft, socketPath: socketPath) {
        case .committed(let result):
            let bytes = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            print(String(decoding: bytes, as: UTF8.self))
        case .spooled: print("{\"spooled\":true}")
        case .unsupported: throw CLIError(message: "method_not_found")
        case .lost: throw CLIError(message: "storage_unavailable")
        }
    }

    private static func enclosingBundleID() -> String? {
        var url = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        while url.path != "/" {
            if url.pathExtension == "app" { return Bundle(url: url)?.bundleIdentifier }
            url.deleteLastPathComponent()
        }
        return nil
    }

    /// Extract only the known fields from existing hook input. Never store a copied payload.
    static func claudeDraft(subcommand: String, input: [String: Any], tabID: UUID?, workspaceID: UUID?) -> JournalDraft? {
        let kind: JournalKind
        let tool = input["tool_name"] as? String
        switch subcommand {
        case "session-start", "active": kind = .sessionStarted
        case "session-end": kind = .sessionEnded
        case "prompt-submit": kind = .turnStarted
        case "stop", "idle": kind = .turnCompleted
        case "pre-tool-use": kind = tool == "AskUserQuestion" ? .questionRequested : (tool == "ExitPlanMode" ? .planReviewRequested : .stateChanged)
        case "notification", "notify":
            kind = (input["notification_type"] as? String) == "permission_prompt" ? .approvalRequested : .stateChanged
        default: return nil
        }
        let native: String
        switch subcommand {
        case "session-start", "active": native = "SessionStart"
        case "session-end": native = "SessionEnd"
        case "prompt-submit": native = "UserPromptSubmit"
        case "stop", "idle": native = "Stop"
        case "pre-tool-use": native = "PreToolUse"
        default: native = "Notification"
        }
        var draft = JournalDraft(kind: kind, emittedAtMs: Int64(Date().timeIntervalSince1970 * 1000),
            tabID: tabID != nil && workspaceID != nil ? tabID : nil,
            workspaceID: tabID != nil && workspaceID != nil ? workspaceID : nil,
            sessionID: input["session_id"] as? String, agentKind: "claude-code", source: .hook,
            adapter: .claudeHook, nativeEvent: native)
        draft.turnID = input["prompt_id"] as? String
        draft.requestID = input["tool_use_id"] as? String
        if subcommand == "pre-tool-use" {
            draft.toolClass = tool == "AskUserQuestion" ? .askUserQuestion : (tool == "ExitPlanMode" ? .exitPlanMode : .other)
        }
        if kind == .stateChanged { draft.signal = subcommand == "pre-tool-use" ? .toolActivity : .observation }
        return (try? draft.validate()) != nil ? draft : nil
    }
}
