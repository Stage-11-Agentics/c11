import Foundation

enum JournalCommand {
    enum Delivery { case committed([String: Any]), spooled, unsupported, lost, rejected(String) }

    static var defaultDeliveryWindow: TimeInterval { testTimeBudget(default: 0.250) }

    /// Test seam: with `C11_CLI_TEST_TIME_BUDGET_MS` set, the CLI's short wall-clock budgets (the quarter-second
    /// socket windows of a journal append and a Claude hook, and the offline spool write's 25 ms) are that many
    /// milliseconds instead (it only ever widens one), so a host test under load sees the fake app's answer and the spool's result rather
    /// than a budget running out (C11H-402). Unset, every budget is its default.
    static func testTimeBudget(default budget: TimeInterval) -> TimeInterval {
        guard let raw = ProcessInfo.processInfo.environment["C11_CLI_TEST_TIME_BUDGET_MS"],
              let ms = Double(raw), ms > 0 else { return budget }
        return max(ms / 1000, budget)
    }

    static func deliver(_ draft: JournalDraft, socketPath: String,
                        authenticatedClient: SocketClient? = nil, explicitPassword: String? = nil,
                        window: TimeInterval = defaultDeliveryWindow) -> Delivery {
        guard let data = try? draft.canonicalData(),
              let params = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .lost }
        if C11RelayCLI.isActive { return deliverRelayed(params) }
        let previousDeadline = SocketClient.processDeadline
        SocketClient.processDeadline = min(previousDeadline ?? .distantFuture, Date().addingTimeInterval(window))
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
            return .committed(try client.sendV2(method: "agent.event.append", params: envelope, deadline: .custom(window)))
        } catch let error as CLIError where error.message.hasPrefix("method_not_found:") {
            return .unsupported
        } catch let error as CLIError where [JournalError.invalidEvent, .conflict, .expired, .unsupportedVersion]
            .contains(where: { error.message.hasPrefix($0.rawValue + ":") }) {
            return .rejected(String(error.message.prefix(while: { $0 != ":" })))
        } catch { return JournalDeliveryFailure.afterSocketError(error) == .spool ? spool(draft) : .rejected(String(describing: error)) }
    }

    /// C11H-16: through the relay. A link that is down queues the append in
    /// the relay spool on this machine; this machine's own journal spool is
    /// never written, since it belongs to whatever app runs here.
    static func deliverRelayed(_ event: [String: Any], timeout: TimeInterval = 5) -> Delivery {
        var envelope: [String: Any] = ["event": event]
        if let raw = ProcessInfo.processInfo.environment["C11_AGENT_INTERACTIVE_PID"], let pid = Int32(raw), pid > 1 {
            envelope["interactive_pid"] = pid
        }
        let request: [String: Any] = ["id": UUID().uuidString, "method": "agent.event.append", "params": envelope]
        guard let line = (try? JSONSerialization.data(withJSONObject: request)).map({ String(decoding: $0, as: UTF8.self) }),
              let client = try? C11RelayCLI.makeClient() else { return .lost }
        do {
            var timeout = timeout
            if let deadline = SocketClient.processDeadline {
                timeout = min(timeout, max(0.1, deadline.timeIntervalSinceNow))
            }
            let reply = try client.call(line: line, framing: .json, timeout: timeout)
            guard let object = (try? JSONSerialization.jsonObject(with: Data(reply.utf8))) as? [String: Any] else { return .lost }
            if object["ok"] as? Bool == true { return .committed(object["result"] as? [String: Any] ?? [:]) }
            let code = (object["error"] as? [String: Any])?["code"] as? String ?? "error"
            if code == "method_not_found" { return .unsupported }
            if [JournalError.invalidEvent, .conflict, .expired, .unsupportedVersion].map(\.rawValue).contains(code) {
                return .rejected(code)
            }
            return .lost
        } catch C11RelayCallError.unreachable(let spooled, _, _) {
            return spooled ? .spooled : .lost
        } catch {
            return .lost
        }
    }

    static func spool(_ draft: JournalDraft) -> Delivery {
        if C11RelayCLI.isActive { return .lost }
        let env = ProcessInfo.processInfo.environment
        let bundleID = env["CMUX_BUNDLE_ID"] ?? enclosingBundleID()
        guard let layout = try? JournalStorageLayout.resolve(bundleID: bundleID) else { return .lost }
        var spool = JournalSpool(layout: layout)
        let writeBudget = testTimeBudget(default: TimeInterval(spool.budgets.spoolWriteNanos) / 1_000_000_000)
        spool.budgets.spoolWriteNanos = UInt64(writeBudget * 1_000_000_000)
        guard spool.write(draft) else { return .lost }
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

    /// Extract only the known fields from hook input. Never store a copied payload.
    static func claudeDraft(subcommand: String, input: [String: Any], panelID: UUID?, workspaceID: UUID?) -> JournalDraft? {
        guard var draft = ClaudeHookMapping.map(subcommand: subcommand, object: input) else { return nil }
        if let panelID, let workspaceID {
            draft.panelID = panelID
            draft.workspaceID = workspaceID
        }
        return (try? draft.validate()) != nil ? draft : nil
    }
}
