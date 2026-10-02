import Foundation

enum JournalCommand {
    enum Delivery { case committed([String: Any]), spooled, unsupported, lost, rejected(String) }

    static func deliver(_ draft: JournalDraft, socketPath: String,
                        authenticatedClient: SocketClient? = nil, explicitPassword: String? = nil) -> Delivery {
        guard let data = try? draft.canonicalData(),
              let params = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .lost }
        let previousDeadline = SocketClient.processDeadline
        SocketClient.processDeadline = min(previousDeadline ?? .distantFuture, Date().addingTimeInterval(0.250))
        defer { SocketClient.processDeadline = previousDeadline }
        let client = authenticatedClient ?? SocketClient(path: socketPath)
        let previousLineMode = client.usesSingleLineResponses
        client.usesSingleLineResponses = true
        defer {
            client.usesSingleLineResponses = previousLineMode
            if authenticatedClient == nil { client.close() }
        }
        do {
            try client.connect()
            if authenticatedClient == nil {
                // File/Keychain lookup may outlive a stalled security service. Only
                // the bounded result is used; late results never send anything.
                let read = PasswordRead()
                let done = DispatchSemaphore(value: 0)
                DispatchQueue.global(qos: .utility).async {
                    read.set(SocketPasswordResolver.resolve(explicit: explicitPassword, socketPath: socketPath))
                    done.signal()
                }
                let remaining = max(0, SocketClient.processDeadline?.timeIntervalSinceNow ?? 0)
                guard done.wait(timeout: .now() + remaining) == .success else { return spool(draft) }
                if let password = read.get() {
                    let response = try client.send(command: "auth \(password)", responseTimeout: remaining)
                    if response.hasPrefix("ERROR:"), !response.contains("Unknown command 'auth'") { return spool(draft) }
                }
            }
            var envelope: [String: Any] = ["event": params]
            if let raw = ProcessInfo.processInfo.environment["C11_AGENT_INTERACTIVE_PID"], let pid = Int32(raw), pid > 1 {
                envelope["interactive_pid"] = pid
            }
            return .committed(try client.sendV2(method: "agent.event.append", params: envelope, deadline: .custom(0.250)))
        } catch let error as CLIError where error.message.hasPrefix("method_not_found:") {
            return .unsupported
        } catch let error as CLIError where [JournalError.invalidEvent, .conflict, .expired, .unsupportedVersion]
            .contains(where: { error.message.hasPrefix($0.rawValue + ":") }) {
            return .rejected(String(error.message.prefix(while: { $0 != ":" })))
        } catch { return spool(draft) }
    }

    static func spool(_ draft: JournalDraft) -> Delivery {
        let env = ProcessInfo.processInfo.environment
        let bundleID = env["CMUX_BUNDLE_ID"] ?? enclosingBundleID()
        guard let layout = try? JournalStorageLayout.resolve(bundleID: bundleID),
              JournalSpool(layout: layout).write(draft) else { return .lost }
        return .spooled
    }

    static func run(_ arguments: [String], socketPath: String, explicitPassword: String? = nil) throws {
        if arguments.isEmpty || arguments.contains("--help") || arguments.contains("-h") {
            print("c11 agent-event append --stdin\nAppend one structural lifecycle event; returns a committed receipt or {\"spooled\":true}. Maximum input: 4096 bytes.")
            return
        }
        guard arguments == ["append", "--stdin"] else { throw CLIError(message: "usage: c11 agent-event append --stdin") }
        let data = FileHandle.standardInput.readData(ofLength: 4097)
        let draft: JournalDraft
        do { draft = try JournalDraft.decode(data) } catch { throw CLIError(message: "invalid_event") }
        switch deliver(draft, socketPath: socketPath, explicitPassword: explicitPassword) {
        case .committed(let result):
            let bytes = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            print(String(decoding: bytes, as: UTF8.self))
        case .spooled: print("{\"spooled\":true}")
        case .unsupported: throw CLIError(message: "method_not_found")
        case .lost: throw CLIError(message: "storage_unavailable")
        case .rejected(let code): throw CLIError(message: code)
        }
    }

    private final class PasswordRead: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String?
        func set(_ value: String?) { lock.lock(); self.value = value; lock.unlock() }
        func get() -> String? { lock.lock(); defer { lock.unlock() }; return value }
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
        case "post-tool-use":
            guard tool == "AskUserQuestion" || tool == "ExitPlanMode" else { return nil }
            kind = .attentionResolved
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
        case "post-tool-use": native = "PostToolUse"
        default: native = "Notification"
        }
        var draft = JournalDraft(kind: kind, emittedAtMs: Int64(Date().timeIntervalSince1970 * 1000),
            tabID: tabID != nil && workspaceID != nil ? tabID : nil,
            workspaceID: tabID != nil && workspaceID != nil ? workspaceID : nil,
            sessionID: input["session_id"] as? String, agentKind: "claude-code", source: .hook,
            adapter: .claudeHook, nativeEvent: native)
        draft.turnID = input["prompt_id"] as? String
        draft.requestID = input["tool_use_id"] as? String
        if subcommand == "pre-tool-use" || subcommand == "post-tool-use" {
            draft.toolClass = tool == "AskUserQuestion" ? .askUserQuestion : (tool == "ExitPlanMode" ? .exitPlanMode : .other)
        }
        if kind == .attentionResolved { draft.resolution = .resumed }
        if kind == .stateChanged { draft.signal = subcommand == "pre-tool-use" ? .toolActivity : .observation }
        return (try? draft.validate()) != nil ? draft : nil
    }
}
